//! Read-only Btrfs generation discovery and validation.

use crate::{require_root, BubblePaths};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

static METADATA_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static LINK_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn is_generation_number(value: &str) -> bool {
    value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn generation_number(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    if !is_generation_number(name) {
        return None;
    }
    name.parse().ok()
}

fn parse_running_generation(contents: &[u8]) -> Option<String> {
    for line in contents.split(|byte| *byte == b'\n') {
        if let Some(generation) = line.strip_prefix(b"GENERATION=") {
            if generation.len() != 6 || !generation.iter().all(u8::is_ascii_digit) {
                return None;
            }
            return String::from_utf8(generation.to_vec()).ok();
        }
    }
    None
}

/// Read the generation metadata written for the currently mounted rootfs.
pub fn running_generation() -> Option<String> {
    let contents = std::fs::read("/etc/bubbleos/generation").ok()?;
    parse_running_generation(&contents)
}

impl BubblePaths {
    /// Match the legacy generation existence check, including directory symlinks.
    pub fn generation_exists(&self, generation: &str) -> bool {
        is_generation_number(generation) && self.generations_dir.join(generation).is_dir()
    }

    /// List visible directories under the generations directory.
    ///
    /// The legacy shell function lists every visible directory, not only names
    /// with six digits. Retaining that behaviour makes the Rust adapter safe
    /// for existing system layouts while sorting numeric generation names
    /// numerically.
    pub fn generation_list(&self) -> io::Result<Vec<String>> {
        let entries = match std::fs::read_dir(&self.generations_dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Vec::new());
            }
            Err(error) => return Err(error),
        };

        let mut names = Vec::new();
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if name.starts_with('.') || !entry.path().is_dir() {
                continue;
            }
            names.push(name.to_owned());
        }

        names.sort_by(
            |left, right| match (left.parse::<u64>(), right.parse::<u64>()) {
                (Ok(left_number), Ok(right_number)) => {
                    left_number.cmp(&right_number).then_with(|| left.cmp(right))
                }
                _ => left.cmp(right),
            },
        );

        Ok(names)
    }

    /// Return the next six-digit generation number, starting at 000001.
    pub fn generation_next(&self) -> io::Result<String> {
        let entries = match std::fs::read_dir(&self.generations_dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok("000001".to_owned());
            }
            Err(error) => return Err(error),
        };

        let mut last = 0_u64;
        for entry in entries {
            let entry = entry?;
            if !entry.path().is_dir() {
                continue;
            }
            if let Some(number) = generation_number(&entry.path()) {
                last = last.max(number);
            }
        }

        Ok(format!("{:06}", last + 1))
    }

    /// Parse a generation directory name without accepting signs or prefixes.
    pub fn is_generation_number(value: &str) -> bool {
        is_generation_number(value)
    }
}

fn replace_symlink_atomically(link: &Path, target: &str) -> io::Result<()> {
    let parent = link.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("link has no parent directory: {}", link.display()),
        )
    })?;
    fs::create_dir_all(parent)?;

    let sequence = LINK_TEMP_SEQUENCE.fetch_add(1, AtomicOrdering::Relaxed);
    let temporary = parent.join(format!(
        ".{}.{}.{}.tmp",
        link.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("bubble-link"),
        std::process::id(),
        sequence
    ));

    #[cfg(unix)]
    std::os::unix::fs::symlink(target, &temporary)?;

    #[cfg(not(unix))]
    {
        let _ = target;
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "BubbleOS generation links require Unix symbolic links",
        ));
    }

    if let Err(error) = fs::rename(&temporary, link) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }

    File::open(parent)?.sync_all()?;
    Ok(())
}

fn remove_symlink_if_present(link: &Path) -> io::Result<()> {
    match fs::remove_file(link) {
        Ok(()) => {
            if let Some(parent) = link.parent() {
                File::open(parent)?.sync_all()?;
            }
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn ensure_real_directory_or_missing(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "refusing to write generation metadata through symlink {}",
                path.display()
            ),
        )),
        Ok(metadata) if !metadata.is_dir() => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "generation metadata parent is not a directory: {}",
                path.display()
            ),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn write_generation_metadata(
    paths: &BubblePaths,
    generation: &str,
    description: &str,
) -> io::Result<()> {
    if !is_generation_number(generation) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "generation number must contain exactly six ASCII digits",
        ));
    }

    let generation_dir = paths.generations_dir.join(generation);
    let etc_dir = generation_dir.join("etc");
    let metadata_dir = etc_dir.join("bubbleos");

    // Match the shell guard while refusing symlinked metadata parents.
    ensure_real_directory_or_missing(&etc_dir)?;
    ensure_real_directory_or_missing(&metadata_dir)?;
    fs::create_dir_all(&metadata_dir)?;
    ensure_real_directory_or_missing(&etc_dir)?;
    ensure_real_directory_or_missing(&metadata_dir)?;

    let created_at = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .stderr(Stdio::null())
        .output()?;
    if !created_at.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "could not obtain the UTC timestamp for generation metadata",
        ));
    }
    let created_at = String::from_utf8_lossy(&created_at.stdout)
        .trim()
        .to_owned();
    if created_at.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "date returned an empty UTC timestamp",
        ));
    }

    let description = if description.is_empty() {
        format!("bubbleOS generation {generation}")
    } else {
        description.replace('\n', " ")
    };
    let metadata =
        format!("GENERATION={generation}\nCREATED_AT={created_at}\nDESCRIPTION={description}\n");
    let metadata_file = metadata_dir.join("generation");
    let sequence = METADATA_TEMP_SEQUENCE.fetch_add(1, AtomicOrdering::Relaxed);
    let temporary_file = metadata_dir.join(format!(
        ".generation.{}.{}.tmp",
        std::process::id(),
        sequence
    ));

    let write_result = (|| -> io::Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);

        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o644);
        }

        let mut file = options.open(&temporary_file)?;
        file.write_all(metadata.as_bytes())?;
        file.sync_all()?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o644))?;
        }

        fs::rename(&temporary_file, &metadata_file)?;
        File::open(&metadata_dir)?.sync_all()?;
        Ok(())
    })();

    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_file);
    }

    write_result
}

impl BubblePaths {
    /// Write generation metadata using a synced temporary file and atomic rename.
    pub fn generation_write_metadata(&self, generation: &str, description: &str) -> io::Result<()> {
        write_generation_metadata(self, generation, description)
    }

    /// Atomically switch the previous and current generation links.
    ///
    /// Snapshot creation and automatic pruning are intentionally orchestrated
    /// by the legacy shell wrapper. This method performs only the final link
    /// switch after those operations have succeeded.
    pub fn generation_switch_links(
        &self,
        generation: &str,
        expected_current: &str,
    ) -> io::Result<()> {
        if !is_generation_number(generation) || !self.generation_exists(generation) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("generation {generation} does not exist"),
            ));
        }

        let actual_current = self.current_generation().unwrap_or_default();
        if actual_current != expected_current {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "current generation changed while activation was being prepared",
            ));
        }

        if !expected_current.is_empty() {
            if !is_generation_number(expected_current) || !self.generation_exists(expected_current)
            {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("current generation {expected_current} is no longer available"),
                ));
            }
            replace_symlink_atomically(
                &self.previous_link,
                &format!("generations/{expected_current}"),
            )?;
        } else {
            remove_symlink_if_present(&self.previous_link)?;
        }

        replace_symlink_atomically(&self.current_link, &format!("generations/{generation}"))?;

        let status = Command::new("sync").status()?;
        if !status.success() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "sync failed after switching the generation links",
            ));
        }

        Ok(())
    }

    /// Clone a generation using Btrfs and atomically write its metadata.
    ///
    /// The destination is selected with the same six-digit sequence as the
    /// legacy shell function. A failed metadata write leaves the new snapshot
    /// in place, matching the existing shell behavior.
    pub fn generation_create(&self, from: Option<&str>, description: &str) -> io::Result<String> {
        require_root().map_err(|error| io::Error::new(io::ErrorKind::PermissionDenied, error))?;
        self.require_generation_layout()
            .map_err(|error| io::Error::new(io::ErrorKind::NotFound, error))?;

        let source_generation = match from.filter(|generation| !generation.is_empty()) {
            Some(generation) => generation.to_owned(),
            None => self.current_generation().ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "no active generation to clone")
            })?,
        };

        if !self.generation_exists(&source_generation) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("generation {source_generation} does not exist"),
            ));
        }

        let next_generation = self.generation_next()?;
        let source = self.generations_dir.join(&source_generation);
        let destination = self.generations_dir.join(&next_generation);

        match fs::symlink_metadata(&destination) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!("generation path already exists: {}", destination.display()),
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }

        let status = Command::new("btrfs")
            .args(["subvolume", "snapshot"])
            .arg(&source)
            .arg(&destination)
            .stdout(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("failed to snapshot generation {source_generation}"),
            ));
        }

        self.generation_write_metadata(&next_generation, description)?;
        Ok(next_generation)
    }
}

#[cfg(test)]
mod tests {
    use crate::BubblePaths;
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "bubble-core-generations-test-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn paths_for_test(root: &Path) -> BubblePaths {
        let values: HashMap<String, OsString> = [
            (
                "BUBBLEOS_GENERATIONS_DIR".to_owned(),
                root.join("generations").into_os_string(),
            ),
            (
                "BUBBLEOS_CURRENT_LINK".to_owned(),
                root.join("current").into_os_string(),
            ),
            (
                "BUBBLEOS_PREVIOUS_LINK".to_owned(),
                root.join("previous").into_os_string(),
            ),
        ]
        .into_iter()
        .collect();

        BubblePaths::from_lookup(|key| values.get(key).cloned())
    }

    #[test]
    fn generation_metadata_is_written_atomically_with_newlines_flattened() {
        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        let paths = paths_for_test(&root);

        super::write_generation_metadata(&paths, "000123", "first line\nsecond line").unwrap();

        let metadata =
            std::fs::read_to_string(generations.join("000123/etc/bubbleos/generation")).unwrap();
        assert!(metadata.starts_with("GENERATION=000123\nCREATED_AT="));
        assert!(metadata.contains("DESCRIPTION=first line second line\n"));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let permissions = std::fs::metadata(generations.join("000123/etc/bubbleos/generation"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(permissions, 0o644);
        }

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_metadata_refuses_a_symlinked_etc_directory() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        let outside = root.join("outside");
        std::fs::create_dir_all(&generations).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        symlink(&outside, generations.join("000123/etc")).unwrap();

        let paths = paths_for_test(&root);
        let error = super::write_generation_metadata(&paths, "000123", "blocked").unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(!outside.join("bubbleos/generation").exists());

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_switch_updates_previous_and_current_links_atomically() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        std::fs::create_dir_all(generations.join("000124")).unwrap();
        symlink("generations/000123", root.join("current")).unwrap();

        let paths = paths_for_test(&root);
        paths.generation_switch_links("000124", "000123").unwrap();

        assert_eq!(
            std::fs::read_link(root.join("previous")).unwrap(),
            Path::new("generations/000123")
        );
        assert_eq!(
            std::fs::read_link(root.join("current")).unwrap(),
            Path::new("generations/000124")
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_switch_refuses_a_stale_expected_current_link() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        std::fs::create_dir_all(generations.join("000124")).unwrap();
        std::fs::create_dir_all(generations.join("000125")).unwrap();
        symlink("generations/000125", root.join("current")).unwrap();

        let paths = paths_for_test(&root);
        let error = paths
            .generation_switch_links("000124", "000123")
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        assert!(!root.join("previous").exists());
        assert_eq!(
            std::fs::read_link(root.join("current")).unwrap(),
            Path::new("generations/000125")
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_switch_removes_previous_when_there_is_no_current_generation() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        symlink("generations/old", root.join("previous")).unwrap();

        let paths = paths_for_test(&root);
        paths.generation_switch_links("000123", "").unwrap();

        assert!(!root.join("previous").exists());
        assert_eq!(
            std::fs::read_link(root.join("current")).unwrap(),
            Path::new("generations/000123")
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn running_generation_reads_the_first_matching_metadata_line() {
        assert_eq!(
            super::parse_running_generation(
                b"CREATED_AT=2026-11-11T00:00:00Z\nGENERATION=000123\nGENERATION=000124\n"
            ),
            Some("000123".to_owned())
        );
    }

    #[test]
    fn running_generation_rejects_the_first_invalid_match_without_skipping_it() {
        assert_eq!(
            super::parse_running_generation(b"GENERATION=123\nGENERATION=000124\n"),
            None
        );
        assert_eq!(
            super::parse_running_generation(b"GENERATION=000123\r\n"),
            None
        );
    }

    #[test]
    fn running_generation_accepts_an_unterminated_final_metadata_line() {
        assert_eq!(
            super::parse_running_generation(b"GENERATION=000123"),
            Some("000123".to_owned())
        );
    }

    #[test]
    fn generation_numbers_require_exactly_six_ascii_digits() {
        assert!(BubblePaths::is_generation_number("000001"));
        assert!(BubblePaths::is_generation_number("123456"));
        assert!(!BubblePaths::is_generation_number(""));
        assert!(!BubblePaths::is_generation_number("1"));
        assert!(!BubblePaths::is_generation_number("0000010"));
        assert!(!BubblePaths::is_generation_number("+00001"));
        assert!(!BubblePaths::is_generation_number("１２３４５６"));
        assert!(!BubblePaths::is_generation_number("12345a"));
    }

    #[test]
    fn missing_generations_directory_is_an_empty_list_and_starts_at_one() {
        let root = temp_root();
        let paths = paths_for_test(&root);

        assert!(paths.generation_list().unwrap().is_empty());
        assert_eq!(paths.generation_next().unwrap(), "000001");
        assert!(!paths.generation_exists("000001"));

        std::fs::create_dir_all(&root).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn generation_list_is_numeric_and_excludes_hidden_entries_and_files() {
        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000010")).unwrap();
        std::fs::create_dir_all(generations.join("000002")).unwrap();
        std::fs::create_dir_all(generations.join(".hidden")).unwrap();
        std::fs::write(generations.join("000003-file"), b"not a directory").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(
            paths.generation_list().unwrap(),
            vec!["000002".to_owned(), "000010".to_owned()]
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn generation_next_uses_the_largest_valid_generation_directory() {
        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        std::fs::create_dir_all(generations.join("000009")).unwrap();
        std::fs::create_dir_all(generations.join("999999-extra")).unwrap();
        std::fs::create_dir_all(generations.join("not-a-generation")).unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.generation_next().unwrap(), "000124");
        assert!(paths.generation_exists("000123"));
        assert!(!paths.generation_exists("../000123"));
        assert!(!paths.generation_exists("999999-extra"));

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_exists_matches_directory_symlink_semantics() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("real")).unwrap();
        symlink("real", generations.join("000123")).unwrap();

        let paths = paths_for_test(&root);
        assert!(paths.generation_exists("000123"));

        std::fs::remove_dir_all(root).unwrap();
    }
}
