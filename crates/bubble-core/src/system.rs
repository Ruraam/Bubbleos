//! Read-only BubbleOS system information shared by the CLI and shell adapter.

use crate::BubblePaths;
use std::path::Path;
use std::process::{Command, Stdio};

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }

    #[cfg(not(unix))]
    {
        true
    }
}

fn command_output(program: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(program)
        .args(arguments)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn parse_root_subvolume(options: &str) -> String {
    options
        .split([',', '\n'])
        .find_map(|option| option.strip_prefix("subvol="))
        .map(|path| path.trim_start_matches('/').to_owned())
        .unwrap_or_default()
}

/// Return the init-system label used by the legacy system status command.
pub fn system_init_label() -> String {
    if is_executable(Path::new("/usr/bin/systemctl")) {
        let version = command_output("/usr/bin/systemctl", &["--version"])
            .and_then(|output| output.lines().next().map(str::to_owned))
            .and_then(|line| line.split_whitespace().nth(1).map(str::to_owned))
            .filter(|version| !version.is_empty())
            .unwrap_or_else(|| "unknown".to_owned());
        return format!("systemd {version}");
    }

    if is_executable(Path::new("/sbin/init")) {
        "development init".to_owned()
    } else {
        "unknown".to_owned()
    }
}

/// Return the root subvolume name from findmnt, without leading slashes.
pub fn root_subvolume() -> String {
    command_output("findmnt", &["-no", "OPTIONS", "/"])
        .map(|options| parse_root_subvolume(&options))
        .unwrap_or_default()
}

/// Return the root filesystem type, or an empty string when unavailable.
pub fn root_filesystem_type() -> String {
    command_output("findmnt", &["-no", "FSTYPE", "/"])
        .and_then(|output| output.lines().next().map(str::trim).map(str::to_owned))
        .unwrap_or_default()
}

fn parse_exported_value(contents: &str, variable: &str) -> Option<String> {
    let prefix = format!("export {variable}=\"");
    contents.lines().find_map(|line| {
        let value = line.strip_prefix(&prefix)?.strip_suffix('"')?;
        (!value.is_empty()).then(|| value.to_owned())
    })
}

fn ulpm_variable(paths: &BubblePaths, variable: &str) -> Option<String> {
    let contents = std::fs::read_to_string(paths.ulpm_dir.join("bin/ulpm")).ok()?;
    parse_exported_value(&contents, variable)
}

/// Read the ULPM engine version from the installed ULPM entry point.
pub fn ulpm_version(paths: &BubblePaths) -> Option<String> {
    ulpm_variable(paths, "ULPM_VERSION")
}

/// Read the LPK format version from the installed ULPM entry point.
pub fn lpk_format_version(paths: &BubblePaths) -> Option<String> {
    ulpm_variable(paths, "ULPM_FORMAT_VERSION")
}

impl BubblePaths {
    fn generation_from_link(&self, link: &Path) -> Option<String> {
        let metadata = std::fs::symlink_metadata(link).ok()?;
        if !metadata.file_type().is_symlink() {
            return None;
        }

        let target = std::fs::read_link(link).ok()?;
        let name = target.file_name()?.to_str()?;
        if name.len() != 6 || !name.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        if !self.generations_dir.join(name).is_dir() {
            return None;
        }
        Some(name.to_owned())
    }

    /// Return the current generation only when its link and directory are valid.
    pub fn current_generation(&self) -> Option<String> {
        self.generation_from_link(&self.current_link)
    }

    /// Return the previous generation only when its link and directory are valid.
    pub fn previous_generation(&self) -> Option<String> {
        self.generation_from_link(&self.previous_link)
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_exported_value, parse_root_subvolume};
    use crate::BubblePaths;
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::path::Path;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "bubble-core-system-test-{}-{}",
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
    fn root_subvolume_parser_handles_mount_options() {
        assert_eq!(
            parse_root_subvolume("rw,relatime,subvol=//@rootfs/generations/000123,compress=zstd"),
            "@rootfs/generations/000123"
        );
        assert_eq!(parse_root_subvolume("rw,relatime"), "");
        assert_eq!(parse_root_subvolume("subvol=,subvol=/ignored"), "");
    }

    #[test]
    fn ulpm_version_parser_requires_exact_export_syntax() {
        let contents = concat!(
            "export OTHER=ignored\n",
            "export ULPM_VERSION=\"5.3.0\"\n",
            "export ULPM_FORMAT_VERSION=\"2\"\n",
            "export ULPM_VERSION=\"later\"\n"
        );

        assert_eq!(
            parse_exported_value(contents, "ULPM_VERSION"),
            Some("5.3.0".to_owned())
        );
        assert_eq!(
            parse_exported_value(contents, "ULPM_FORMAT_VERSION"),
            Some("2".to_owned())
        );
        assert_eq!(
            parse_exported_value("export ULPM_VERSION=5.3\n", "ULPM_VERSION"),
            None
        );
    }

    #[cfg(unix)]
    #[test]
    fn generation_links_require_six_digits_and_existing_directories() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let generations = root.join("generations");
        std::fs::create_dir_all(generations.join("000123")).unwrap();
        symlink("generations/000123", root.join("current")).unwrap();
        symlink("generations/not-a-generation", root.join("previous")).unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.current_generation(), Some("000123".to_owned()));
        assert_eq!(paths.previous_generation(), None);

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn generation_link_without_an_existing_directory_is_rejected() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        std::fs::create_dir_all(root.join("generations")).unwrap();
        symlink("generations/000123", root.join("current")).unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.current_generation(), None);

        std::fs::remove_dir_all(root).unwrap();
    }
}
