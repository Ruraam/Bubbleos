//! Read-only discovery and validation for BubbleOS restore points.

use crate::BubblePaths;
use std::io;
use std::path::PathBuf;

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
