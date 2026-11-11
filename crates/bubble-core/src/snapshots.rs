//! Read-only discovery and validation for BubbleOS restore points.

use crate::BubblePaths;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

/// Validate a snapshot name using the same character policy as the legacy shell.
pub fn snapshot_valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

impl BubblePaths {
    /// Return the path of the pending /var restore marker.
    pub fn snapshot_pending_path(&self) -> PathBuf {
        self.snapshots_dir.join("var-restore.request")
    }

    /// Read the first SNAPSHOT= entry from a marker file.
    ///
    /// Lines are split only on LF. Unlike str::lines, this intentionally
    /// preserves a trailing CR so CRLF input does not silently pass validation
    /// when the shell implementation would reject it.
    pub fn snapshot_pending_from_file(&self, marker: &std::path::Path) -> Option<String> {
        let contents = std::fs::read(marker).ok()?;
        for complete_line in contents.split_inclusive(|byte| *byte == b'\n') {
            let Some(line) = complete_line.strip_suffix(b"\n") else {
                // Bash's "while read" loop does not process an unterminated
                // final line because read returns failure at EOF.
                continue;
            };
            if let Some(name) = line.strip_prefix(b"SNAPSHOT=") {
                let name = std::str::from_utf8(name).ok()?;
                return snapshot_valid_name(name).then(|| name.to_owned());
            }
        }
        None
    }

    /// Read the configured pending /var restore marker.
    pub fn snapshot_pending(&self) -> Option<String> {
        self.snapshot_pending_from_file(&self.snapshot_pending_path())
    }

    /// List second-level snapshot directories as category/name.
    ///
    /// This matches the legacy find command: symlinked directories are not
    /// followed, hidden entries are included, and the final list is sorted.
    pub fn snapshot_list(&self) -> io::Result<Vec<String>> {
        let categories = std::fs::read_dir(&self.snapshots_dir)?;

        let mut snapshots = Vec::new();
        for category in categories {
            let category = category?;
            if !category.file_type()?.is_dir() {
                continue;
            }

            let category_name = category.file_name();
            let Some(category_name) = category_name.to_str() else {
                continue;
            };

            let entries = match std::fs::read_dir(category.path()) {
                Ok(entries) => entries,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };

            for entry in entries {
                let entry = entry?;
                if !entry.file_type()?.is_dir() {
                    continue;
                }
                let name = entry.file_name();
                let Some(name) = name.to_str() else {
                    continue;
                };
                snapshots.push(format!("{category_name}/{name}"));
            }
        }

        snapshots.sort();
        Ok(snapshots)
    }
}



static RESTORE_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn command_success(program: &str, arguments: &[&str]) -> io::Result<bool> {
    Ok(Command::new(program)
        .args(arguments)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?
        .success())
}

fn utc_timestamp(format: &str) -> io::Result<String> {
    let output = Command::new("date")
        .args(["-u", format])
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "could not obtain a UTC timestamp",
        ));
    }

    let value = String::from_utf8(output.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let value = value.trim_end_matches('\n');
    if value.is_empty()
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b':' | b'T' | b'Z')
        })
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "date returned an invalid timestamp",
        ));
    }

    Ok(value.to_owned())
}

fn ensure_real_directory(path: &Path, create: bool) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "refusing to use a symlink as a snapshot directory: {}",
                    path.display()
                ),
            ));
        }
        Ok(metadata) if !metadata.is_dir() => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("snapshot path is not a directory: {}", path.display()),
            ));
        }
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound && !create => return Err(error),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    fs::create_dir_all(path)?;
    ensure_real_directory(path, false)
}

fn ensure_snapshot_category(paths: &BubblePaths, category: &str) -> io::Result<PathBuf> {
    ensure_real_directory(&paths.snapshots_dir, false)?;
    let directory = paths.snapshots_dir.join(category);
    ensure_real_directory(&directory, true)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755))?;
    }

    Ok(directory)
}

fn unique_snapshot_destination(directory: &Path, base: &str) -> io::Result<PathBuf> {
    for suffix in 1_u64..=u64::MAX {
        let name = if suffix == 1 {
            base.to_owned()
        } else {
            format!("{base}-{suffix}")
        };
        let candidate = directory.join(name);
        match fs::symlink_metadata(&candidate) {
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(candidate),
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique snapshot name",
    ))
}

fn run_btrfs_snapshot(source: &Path, destination: &Path) -> io::Result<()> {
    let status = Command::new("btrfs")
        .args(["subvolume", "snapshot", "-r"])
        .arg(source)
        .arg(destination)
        .stdout(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!(
                "Btrfs snapshot creation failed: {} -> {}",
                source.display(),
                destination.display()
            ),
        ));
    }

    Ok(())
}

fn is_mountpoint(path: &Path) -> bool {
    Command::new("mountpoint")
        .arg("-q")
        .arg("--")
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn is_read_only_btrfs_subvolume(path: &Path) -> io::Result<bool> {
    let output = Command::new("btrfs")
        .args(["property", "get", "-ts"])
        .arg(path)
        .arg("ro")
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Ok(false);
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim() == "ro=true")
}

fn valid_snapshot_label(label: &str) -> bool {
    !label.is_empty()
        && !label.starts_with('.')
        && label.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')
        })
}

fn create_restore_temp(parent: &Path) -> io::Result<(PathBuf, File)> {
    for _ in 0..128 {
        let sequence = RESTORE_TEMP_SEQUENCE.fetch_add(1, AtomicOrdering::Relaxed);
        let temporary = parent.join(format!(
            ".var-restore.request.{}.{}.tmp",
            std::process::id(),
            sequence
        ));

        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }

        match options.open(&temporary) {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique restore marker temporary file",
    ))
}

impl BubblePaths {
    /// Create a read-only snapshot of a generation using the legacy naming scheme.
    pub fn snapshot_create_generation(
        &self,
        generation: &str,
        label: &str,
    ) -> io::Result<PathBuf> {
        if !Self::is_generation_number(generation) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot generation must be a six-digit number",
            ));
        }
        if !valid_snapshot_label(label) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot label contains unsafe characters",
            ));
        }

        let source = self.generations_dir.join(generation);
        let metadata = fs::symlink_metadata(&source)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("generation is not a real directory: {}", source.display()),
            ));
        }

        let directory = ensure_snapshot_category(self, "rootfs")?;
        let base = format!(
            "{}-{generation}-{label}",
            utc_timestamp("+%Y%m%dT%H%M%SZ")?
        );
        let destination = unique_snapshot_destination(&directory, &base)?;
        run_btrfs_snapshot(&source, &destination)?;
        Ok(destination)
    }

    /// Create a read-only snapshot of the mounted /var Btrfs subvolume.
    pub fn snapshot_create_var(&self, label: &str) -> io::Result<PathBuf> {
        if !valid_snapshot_label(label) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot label contains unsafe characters",
            ));
        }

        let source = Path::new("/var");
        if !is_mountpoint(source) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "/var is not a mount point; cannot snapshot it",
            ));
        }
        if !command_success("btrfs", &["subvolume", "show", "/var"])? {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "/var is not a Btrfs subvolume; cannot snapshot it",
            ));
        }

        let directory = ensure_snapshot_category(self, "var")?;
        let base = format!("{}-{label}", utc_timestamp("+%Y%m%dT%H%M%SZ")?);
        let destination = unique_snapshot_destination(&directory, &base)?;
        run_btrfs_snapshot(source, &destination)?;
        Ok(destination)
    }

    /// Atomically schedule a verified read-only /var snapshot for the next boot.
    pub fn snapshot_schedule_restore(&self, requested_name: &str) -> io::Result<String> {
        let name = requested_name.strip_prefix("var/").unwrap_or(requested_name);
        if !snapshot_valid_name(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid snapshot name: {name}"),
            ));
        }

        ensure_real_directory(&self.snapshots_dir, false)?;
        let var_directory = self.snapshots_dir.join("var");
        ensure_real_directory(&var_directory, false)?;
        let snapshot = var_directory.join(name);
        let metadata = fs::symlink_metadata(&snapshot).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("/var snapshot does not exist: {name}"),
                )
            } else {
                error
            }
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("/var snapshot is not a real directory: {name}"),
            ));
        }
        if !is_read_only_btrfs_subvolume(&snapshot)? {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{name} is not a read-only snapshot"),
            ));
        }

        let timestamp = utc_timestamp("+%Y-%m-%dT%H:%M:%SZ")?;
        let from = self
            .current_generation()
            .unwrap_or_else(|| "unknown".to_owned());
        let marker = self.snapshot_pending_path();
        let parent = marker.parent().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "restore marker has no parent directory",
            )
        })?;
        let (temporary, mut file) = create_restore_temp(parent)?;

        let write_result = (|| -> io::Result<()> {
            writeln!(file, "SNAPSHOT={name}")?;
            writeln!(file, "REQUESTED_AT={timestamp}")?;
            writeln!(file, "REQUESTED_FROM={from}")?;
            file.sync_all()?;
            fs::rename(&temporary, &marker)?;
            File::open(parent)?.sync_all()?;
            Ok(())
        })();

        if let Err(error) = write_result {
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }

        Ok(format!(
            "bubble: /var restore from {name} scheduled for the next boot"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::snapshot_valid_name;
    use crate::BubblePaths;
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "bubble-core-snapshots-test-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn paths_for_test(root: &Path) -> BubblePaths {
        let values: HashMap<String, OsString> = [(
            "BUBBLEOS_SNAPSHOTS_DIR".to_owned(),
            root.join("snapshots").into_os_string(),
        )]
        .into_iter()
        .collect();

        BubblePaths::from_lookup(|key| values.get(key).cloned())
    }

    #[test]
    fn snapshot_name_policy_matches_shell_case_patterns() {
        for valid in ["initial", "000123-initial", "before_restore.2", "a_b-c.d"] {
            assert!(snapshot_valid_name(valid), "{valid}");
        }
        for invalid in [
            "",
            ".",
            "..",
            ".hidden",
            "contains/slash",
            "has space",
            "has:semicolon",
            "has\nnewline",
            "non-ascii-é",
        ] {
            assert!(!snapshot_valid_name(invalid), "{invalid:?}");
        }
    }

    #[test]
    fn pending_marker_reads_the_first_valid_snapshot_entry() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let marker = root.join("request");
        std::fs::write(
            &marker,
            "REQUESTED_AT=2026-11-11T00:00:00Z\nSNAPSHOT=before-restore\nSNAPSHOT=ignored\n",
        )
        .unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(
            paths.snapshot_pending_from_file(&marker),
            Some("before-restore".to_owned())
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_first_snapshot_entry_is_not_skipped_for_a_later_entry() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let marker = root.join("request");
        std::fs::write(&marker, "SNAPSHOT=../escape\nSNAPSHOT=valid\n").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.snapshot_pending_from_file(&marker), None);

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_marker_skips_non_utf8_unrelated_lines_like_bash() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let marker = root.join("request");
        std::fs::write(&marker, b"COMMENT=\xff\nSNAPSHOT=valid-name\n").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(
            paths.snapshot_pending_from_file(&marker),
            Some("valid-name".to_owned())
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_marker_ignores_an_unterminated_final_line_like_bash() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let marker = root.join("request");
        std::fs::write(&marker, "SNAPSHOT=valid-name").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.snapshot_pending_from_file(&marker), None);

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pending_marker_rejects_crlf_snapshot_lines_like_shell() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let marker = root.join("request");
        std::fs::write(&marker, "SNAPSHOT=valid-name\r\n").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.snapshot_pending_from_file(&marker), None);

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn snapshot_list_matches_second_level_directory_listing() {
        let root = temp_root();
        let snapshots = root.join("snapshots");
        std::fs::create_dir_all(snapshots.join("rootfs/000123-initial")).unwrap();
        std::fs::create_dir_all(snapshots.join("var/000123-initial")).unwrap();
        std::fs::create_dir_all(snapshots.join("var/.hidden")).unwrap();
        std::fs::create_dir_all(snapshots.join("too-deep/a/b")).unwrap();
        std::fs::write(snapshots.join("var/not-a-directory"), b"file").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(
            paths.snapshot_list().unwrap(),
            vec![
                "rootfs/000123-initial".to_owned(),
                "too-deep/a".to_owned(),
                "var/.hidden".to_owned(),
                "var/000123-initial".to_owned(),
            ]
        );

        std::fs::remove_dir_all(root).unwrap();
    }
}
