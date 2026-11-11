//! Shared, dependency-free system primitives for BubbleOS.
//!
//! This crate deliberately starts with path configuration only. The existing
//! shell implementation remains authoritative until parity and integration
//! tests prove that a Rust replacement is safe.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

/// Centralized BubbleOS filesystem layout.
///
/// Values are read from the same environment variables used by the legacy
/// shell implementation. Derived paths are calculated from their parent
/// settings, while every individual path can still be overridden.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BubblePaths {
    pub name: OsString,
    pub version: OsString,
    pub channel: OsString,
    pub state_dir: PathBuf,
    pub config_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub run_dir: PathBuf,
    pub ulpm_dir: PathBuf,
    pub ulpm_config_dir: PathBuf,
    pub ulpm_cache_dir: PathBuf,
    pub rootfs_mount: PathBuf,
    pub store_dir: PathBuf,
    pub store_objects_dir: PathBuf,
    pub store_packages_dir: PathBuf,
    pub boot_assets_dir: PathBuf,
    pub snapshots_dir: PathBuf,
    pub generations_dir: PathBuf,
    pub current_link: PathBuf,
    pub previous_link: PathBuf,
}

impl Default for BubblePaths {
    fn default() -> Self {
        Self::from_lookup(|key| std::env::var_os(key))
    }
}

impl BubblePaths {
    /// Build the filesystem layout from process environment variables.
    pub fn from_env() -> Self {
        Self::default()
    }

    /// Build the layout using a caller-provided environment lookup.
    ///
    /// This keeps configuration deterministic and makes it possible to test
    /// overrides without mutating the process-global environment.
    pub fn from_lookup<F>(mut lookup: F) -> Self
    where
        F: FnMut(&str) -> Option<OsString>,
    {
        fn get<F>(lookup: &mut F, key: &str, fallback: &str) -> OsString
        where
            F: FnMut(&str) -> Option<OsString>,
        {
            lookup(key).unwrap_or_else(|| OsString::from(fallback))
        }

        fn derived<F>(lookup: &mut F, key: &str, fallback: PathBuf) -> PathBuf
        where
            F: FnMut(&str) -> Option<OsString>,
        {
            lookup(key).map(PathBuf::from).unwrap_or(fallback)
        }

        let name = get(&mut lookup, "BUBBLEOS_NAME", "bubbleOS");
        let version = get(&mut lookup, "BUBBLEOS_VERSION", "0.0.1-dev");
        let channel = get(&mut lookup, "BUBBLEOS_CHANNEL", "development");

        let state_dir = derived(
            &mut lookup,
            "BUBBLEOS_STATE_DIR",
            PathBuf::from("/var/lib/bubbleos"),
        );
        let config_dir = derived(
            &mut lookup,
            "BUBBLEOS_CONFIG_DIR",
            PathBuf::from("/etc/bubbleos"),
        );
        let cache_dir = derived(
            &mut lookup,
            "BUBBLEOS_CACHE_DIR",
            PathBuf::from("/var/cache/bubbleos"),
        );
        let run_dir = derived(
            &mut lookup,
            "BUBBLEOS_RUN_DIR",
            PathBuf::from("/run/bubbleos"),
        );
        let ulpm_dir = derived(
            &mut lookup,
            "BUBBLEOS_ULPM_DIR",
            PathBuf::from("/opt/bubbleos/ulpm"),
        );
        let ulpm_config_dir = derived(
            &mut lookup,
            "BUBBLEOS_ULPM_CONFIG_DIR",
            state_dir.join("ulpm"),
        );
        let ulpm_cache_dir = derived(
            &mut lookup,
            "BUBBLEOS_ULPM_CACHE_DIR",
            cache_dir.join("ulpm"),
        );
        let rootfs_mount = derived(
            &mut lookup,
            "BUBBLEOS_ROOTFS_MOUNT",
            state_dir.join("rootfs"),
        );
        let store_dir = derived(
            &mut lookup,
            "BUBBLEOS_STORE_DIR",
            state_dir.join("store"),
        );
        let store_objects_dir = derived(
            &mut lookup,
            "BUBBLEOS_STORE_OBJECTS_DIR",
            store_dir.join("objects"),
        );
        let store_packages_dir = derived(
            &mut lookup,
            "BUBBLEOS_STORE_PACKAGES_DIR",
            store_dir.join("packages"),
        );
        let boot_assets_dir = derived(
            &mut lookup,
            "BUBBLEOS_BOOT_ASSETS_DIR",
            PathBuf::from("/usr/lib/bubbleos/boot"),
        );
        let snapshots_dir = derived(
            &mut lookup,
            "BUBBLEOS_SNAPSHOTS_DIR",
            PathBuf::from("/snapshots"),
        );
        let generations_dir = derived(
            &mut lookup,
            "BUBBLEOS_GENERATIONS_DIR",
            rootfs_mount.join("generations"),
        );
        let current_link = derived(
            &mut lookup,
            "BUBBLEOS_CURRENT_LINK",
            rootfs_mount.join("current"),
        );
        let previous_link = derived(
            &mut lookup,
            "BUBBLEOS_PREVIOUS_LINK",
            rootfs_mount.join("previous"),
        );

        Self {
            name,
            version,
            channel,
            state_dir,
            config_dir,
            cache_dir,
            run_dir,
            ulpm_dir,
            ulpm_config_dir,
            ulpm_cache_dir,
            rootfs_mount,
            store_dir,
            store_objects_dir,
            store_packages_dir,
            boot_assets_dir,
            snapshots_dir,
            generations_dir,
            current_link,
            previous_link,
        }
    }

    /// Directories created by the legacy bubble_init_paths function.
    pub fn initialization_directories(&self) -> Vec<PathBuf> {
        vec![
            self.state_dir.clone(),
            self.rootfs_mount.clone(),
            self.state_dir.join("transactions"),
            // Match bubble_init_paths exactly: these two directories are
            // rooted directly under STATE_DIR, even when their derived
            // configuration paths have explicit overrides.
            self.state_dir.join("store"),
            self.state_dir.join("ulpm"),
            self.state_dir.join("wal"),
            self.config_dir.clone(),
            self.cache_dir.clone(),
            self.ulpm_cache_dir.clone(),
            self.run_dir.clone(),
        ]
    }

    /// Create the directories required by the BubbleOS state layout.
    ///
    /// Existing directories are accepted. Filesystem errors are returned to
    /// the caller; this function never silently ignores a failed mkdir.
    pub fn initialize(&self) -> io::Result<()> {
        for directory in self.initialization_directories() {
            std::fs::create_dir_all(&directory)?;
        }
        Ok(())
    }

    /// Return true when the configured rootfs mount path is a directory.
    ///
    /// This is intentionally not a mountpoint check. A future migration must
    /// preserve the legacy mountpoint and Btrfs validation semantics rather
    /// than confusing directory existence with a mounted filesystem.
    pub fn rootfs_directory_exists(&self) -> bool {
        self.rootfs_mount.is_dir()
    }

    /// Return true when the configured generations directory exists.
    pub fn generations_directory_exists(&self) -> bool {
        self.generations_dir.is_dir()
    }

    /// Check whether a path is contained lexically below a root.
    ///
    /// This helper does not resolve symlinks and must not be used as a
    /// security boundary for privileged filesystem operations.
    pub fn is_lexically_below(path: &Path, root: &Path) -> bool {
        path.strip_prefix(root).is_ok()
    }
}

/// Errors returned by privileged BubbleOS layout preflight checks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BubbleSystemError {
    RootRequired,
    MissingBtrfs,
    RootfsNotMounted(PathBuf),
    GenerationDirectoryMissing(PathBuf),
    SnapshotsNotMounted(PathBuf),
}

impl std::fmt::Display for BubbleSystemError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RootRequired => {
                write!(formatter, "bubble: this operation requires root privileges")
            }
            Self::MissingBtrfs => write!(
                formatter,
                "bubble: the btrfs command is unavailable (install btrfs-progs)"
            ),
            Self::RootfsNotMounted(path) => write!(
                formatter,
                "bubble: {} is not mounted (is the @rootfs subvolume available?)",
                path.display()
            ),
            Self::GenerationDirectoryMissing(path) => write!(
                formatter,
                "bubble: generation directory is missing: {}",
                path.display()
            ),
            Self::SnapshotsNotMounted(path) => write!(
                formatter,
                "bubble: {} is not mounted (is the @snapshots subvolume available?)",
                path.display()
            ),
        }
    }
}

impl std::error::Error for BubbleSystemError {}

#[cfg(target_os = "linux")]
extern "C" {
    fn geteuid() -> u32;
}

/// Check the effective UID using the operating system, not environment data.
pub fn require_root() -> Result<(), BubbleSystemError> {
    #[cfg(target_os = "linux")]
    let is_root = unsafe { geteuid() == 0 };

    #[cfg(not(target_os = "linux"))]
    let is_root = false;

    if is_root {
        Ok(())
    } else {
        Err(BubbleSystemError::RootRequired)
    }
}

fn executable_in_path(program: &str) -> bool {
    let Some(path_value) = std::env::var_os("PATH") else {
        return false;
    };

    std::env::split_paths(&path_value).any(|directory| {
        let candidate = directory.join(program);
        if !candidate.is_file() {
            return false;
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            candidate
                .metadata()
                .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        }

        #[cfg(not(unix))]
        {
            true
        }
    })
}

fn is_mountpoint(path: &Path) -> bool {
    std::process::Command::new("mountpoint")
        .arg("-q")
        .arg("--")
        .arg(path)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

impl BubblePaths {
    fn validate_generation_layout_with<C, M>(
        &self,
        mut command_available: C,
        mut mountpoint_check: M,
    ) -> Result<(), BubbleSystemError>
    where
        C: FnMut(&str) -> bool,
        M: FnMut(&Path) -> bool,
    {
        if !command_available("btrfs") {
            return Err(BubbleSystemError::MissingBtrfs);
        }
        if !mountpoint_check(&self.rootfs_mount) {
            return Err(BubbleSystemError::RootfsNotMounted(
                self.rootfs_mount.clone(),
            ));
        }
        if !self.generations_dir.is_dir() {
            return Err(BubbleSystemError::GenerationDirectoryMissing(
                self.generations_dir.clone(),
            ));
        }
        Ok(())
    }

    /// Preserve the checks performed by the legacy bubble_require_generation_layout.
    pub fn require_generation_layout(&self) -> Result<(), BubbleSystemError> {
        self.validate_generation_layout_with(executable_in_path, is_mountpoint)
    }

    fn validate_snapshots_layout_with<M>(
        &self,
        mut mountpoint_check: M,
    ) -> Result<(), BubbleSystemError>
    where
        M: FnMut(&Path) -> bool,
    {
        if !mountpoint_check(&self.snapshots_dir) {
            return Err(BubbleSystemError::SnapshotsNotMounted(
                self.snapshots_dir.clone(),
            ));
        }
        Ok(())
    }

    /// Preserve the mountpoint check performed by the legacy snapshots guard.
    pub fn require_snapshots_layout(&self) -> Result<(), BubbleSystemError> {
        self.validate_snapshots_layout_with(is_mountpoint)
    }
}

#[cfg(test)]
mod tests {
    use super::BubblePaths;
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::path::PathBuf;

    fn paths_with(values: &[(&str, &str)]) -> BubblePaths {
        let vars: HashMap<String, OsString> = values
            .iter()
            .map(|(key, value)| ((*key).to_owned(), OsString::from(value)))
            .collect();

        BubblePaths::from_lookup(|key| vars.get(key).cloned())
    }

    #[test]
    fn defaults_match_legacy_shell_paths() {
        let paths = paths_with(&[]);

        assert_eq!(paths.name, "bubbleOS");
        assert_eq!(paths.version, "0.0.1-dev");
        assert_eq!(paths.channel, "development");
        assert_eq!(paths.state_dir, PathBuf::from("/var/lib/bubbleos"));
        assert_eq!(paths.config_dir, PathBuf::from("/etc/bubbleos"));
        assert_eq!(paths.cache_dir, PathBuf::from("/var/cache/bubbleos"));
        assert_eq!(paths.run_dir, PathBuf::from("/run/bubbleos"));
        assert_eq!(paths.ulpm_dir, PathBuf::from("/opt/bubbleos/ulpm"));
        assert_eq!(
            paths.ulpm_config_dir,
            PathBuf::from("/var/lib/bubbleos/ulpm")
        );
        assert_eq!(
            paths.ulpm_cache_dir,
            PathBuf::from("/var/cache/bubbleos/ulpm")
        );
        assert_eq!(
            paths.rootfs_mount,
            PathBuf::from("/var/lib/bubbleos/rootfs")
        );
        assert_eq!(
            paths.generations_dir,
            PathBuf::from("/var/lib/bubbleos/rootfs/generations")
        );
        assert_eq!(
            paths.current_link,
            PathBuf::from("/var/lib/bubbleos/rootfs/current")
        );
        assert_eq!(
            paths.previous_link,
            PathBuf::from("/var/lib/bubbleos/rootfs/previous")
        );
    }

    #[test]
    fn parent_overrides_update_derived_paths() {
        let paths = paths_with(&[("BUBBLEOS_STATE_DIR", "/srv/bubble/state")]);

        assert_eq!(paths.state_dir, PathBuf::from("/srv/bubble/state"));
        assert_eq!(
            paths.ulpm_config_dir,
            PathBuf::from("/srv/bubble/state/ulpm")
        );
        assert_eq!(
            paths.rootfs_mount,
            PathBuf::from("/srv/bubble/state/rootfs")
        );
        assert_eq!(
            paths.store_dir,
            PathBuf::from("/srv/bubble/state/store")
        );
        assert_eq!(
            paths.generations_dir,
            PathBuf::from("/srv/bubble/state/rootfs/generations")
        );
    }

    #[test]
    fn explicit_child_override_takes_precedence() {
        let paths = paths_with(&[
            ("BUBBLEOS_STATE_DIR", "/srv/bubble/state"),
            ("BUBBLEOS_ROOTFS_MOUNT", "/mnt/custom-rootfs"),
            ("BUBBLEOS_GENERATIONS_DIR", "/mnt/custom-generations"),
        ]);

        assert_eq!(paths.rootfs_mount, PathBuf::from("/mnt/custom-rootfs"));
        assert_eq!(
            paths.generations_dir,
            PathBuf::from("/mnt/custom-generations")
        );
    }

    #[test]
    fn store_subdirectories_follow_store_override() {
        let paths = paths_with(&[("BUBBLEOS_STORE_DIR", "/srv/bubble/store")]);

        assert_eq!(
            paths.store_objects_dir,
            PathBuf::from("/srv/bubble/store/objects")
        );
        assert_eq!(
            paths.store_packages_dir,
            PathBuf::from("/srv/bubble/store/packages")
        );
    }

    #[test]
    fn lexical_containment_rejects_sibling_prefixes() {
        assert!(BubblePaths::is_lexically_below(
            Path::new("/srv/bubble/rootfs/current"),
            Path::new("/srv/bubble/rootfs")
        ));
        assert!(!BubblePaths::is_lexically_below(
            Path::new("/srv/bubble/rootfs-old/current"),
            Path::new("/srv/bubble/rootfs")
        ));
    }

    #[test]
    fn initialization_directories_match_legacy_shell_even_with_child_overrides() {
        let paths = paths_with(&[
            ("BUBBLEOS_STATE_DIR", "/srv/bubble/state"),
            ("BUBBLEOS_STORE_DIR", "/srv/custom/store"),
            ("BUBBLEOS_ULPM_CONFIG_DIR", "/srv/custom/ulpm-config"),
        ]);
        let directories = paths.initialization_directories();

        assert!(directories.contains(&PathBuf::from("/srv/bubble/state/store")));
        assert!(directories.contains(&PathBuf::from("/srv/bubble/state/ulpm")));
        assert!(!directories.contains(&PathBuf::from("/srv/custom/store")));
        assert!(!directories.contains(&PathBuf::from("/srv/custom/ulpm-config")));
    }

    #[test]
    fn generation_layout_checks_btrfs_before_mountpoint() {
        let paths = paths_with(&[]);
        let result = paths.validate_generation_layout_with(
            |_| false,
            |_| panic!("mountpoint must not be checked when btrfs is unavailable"),
        );

        assert_eq!(result, Err(BubbleSystemError::MissingBtrfs));
    }

    #[test]
    fn generation_layout_rejects_an_unmounted_rootfs() {
        let paths = paths_with(&[]);
        let result = paths.validate_generation_layout_with(
            |_| true,
            |_| false,
        );

        assert_eq!(
            result,
            Err(BubbleSystemError::RootfsNotMounted(
                paths.rootfs_mount.clone()
            ))
        );
    }

    #[test]
    fn generation_layout_rejects_a_missing_generations_directory() {
        let paths = paths_with(&[(
            "BUBBLEOS_GENERATIONS_DIR",
            "/__bubbleos_test__/missing-generations",
        )]);
        let result = paths.validate_generation_layout_with(
            |_| true,
            |_| true,
        );

        assert_eq!(
            result,
            Err(BubbleSystemError::GenerationDirectoryMissing(
                PathBuf::from("/__bubbleos_test__/missing-generations")
            ))
        );
    }

    #[test]
    fn snapshots_layout_rejects_an_unmounted_snapshots_path() {
        let paths = paths_with(&[]);
        let result = paths.validate_snapshots_layout_with(|_| false);

        assert_eq!(
            result,
            Err(BubbleSystemError::SnapshotsNotMounted(
                paths.snapshots_dir.clone()
            ))
        );
    }

    use std::path::Path;
}
