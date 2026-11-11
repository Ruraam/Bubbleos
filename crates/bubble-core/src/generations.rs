//! Read-only Btrfs generation discovery and validation.

use crate::BubblePaths;
use std::io;
use std::path::{Path, PathBuf};

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

        names.sort_by(|left, right| {
            match (left.parse::<u64>(), right.parse::<u64>()) {
                (Ok(left_number), Ok(right_number)) => {
                    left_number.cmp(&right_number).then_with(|| left.cmp(right))
                }
                _ => left.cmp(right),
            }
        });

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
        let values: HashMap<String, OsString> = [(
            "BUBBLEOS_GENERATIONS_DIR".to_owned(),
            root.join("generations").into_os_string(),
        )]
        .into_iter()
        .collect();

        BubblePaths::from_lookup(|key| values.get(key).cloned())
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

        std::fs::create_dir_all(root).unwrap();
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
