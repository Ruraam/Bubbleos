//! Read-only inspection of the content-addressed BubbleOS package store.

use crate::BubblePaths;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_package_id(value: &str) -> bool {
    !value.is_empty() && !value.contains('/') && !value.contains("..")
}

fn valid_package_version(value: &str) -> bool {
    !value.is_empty() && !value.contains('/')
}

/// Run jq using the same TSV projection as the legacy Bash helper.
fn manifest_info(manifest: &Path, digest: &str) -> io::Result<String> {
    let output = Command::new("jq")
        .args([
            "-r",
            "--arg",
            "digest",
            digest,
            "[.id, .version, (.type // .kind // \"system\"), (.name // .id), $digest] | @tsv",
        ])
        .arg(manifest)
        .stderr(Stdio::inherit())
        .output()?;

    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("could not read package manifest {}", manifest.display()),
        ));
    }

    String::from_utf8(output.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn digest_for_file(file: &Path) -> io::Result<String> {
    let output = Command::new("sha256sum")
        .arg("--")
        .arg(file)
        .stderr(Stdio::inherit())
        .output()?;

    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("could not hash package file {}", file.display()),
        ));
    }

    let line = String::from_utf8_lossy(&output.stdout);
    let digest = line.split_whitespace().next().unwrap_or_default();
    if !is_digest(digest) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("sha256sum returned an invalid digest for {}", file.display()),
        ));
    }
    Ok(digest.to_owned())
}

fn version_sort_last(values: &[String]) -> io::Result<Option<String>> {
    if values.is_empty() {
        return Ok(None);
    }

    let mut child = Command::new("sort")
        .arg("-V")
        .env("LC_ALL", "C")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;

    {
        let mut input = child.stdin.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::BrokenPipe, "sort stdin is unavailable")
        })?;
        for value in values {
            input.write_all(value.as_bytes())?;
            input.write_all(b"\n")?;
        }
    }

    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "version sorting failed",
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .last()
        .map(str::to_owned))
}

impl BubblePaths {
    /// Return the store object directory for a lowercase SHA-256 digest.
    pub fn store_object_dir(&self, digest: &str) -> io::Result<PathBuf> {
        if !is_digest(digest) {
            return Err(invalid_input(
                "store digest must be 64 lowercase hexadecimal characters",
            ));
        }
        Ok(self.store_objects_dir.join(digest))
    }

    /// Return the manifest path for a complete digest directory.
    pub fn store_object_manifest(&self, digest: &str) -> io::Result<PathBuf> {
        let object = self.store_object_dir(digest)?;
        let manifest = object.join("manifest.json");
        if !manifest.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("store object manifest is missing: {}", manifest.display()),
            ));
        }
        Ok(manifest)
    }

    /// Return the highest version according to GNU sort -V among version links.
    pub fn store_latest_version(&self, package_id: &str) -> io::Result<String> {
        if !valid_package_id(package_id) {
            return Err(invalid_input(format!("invalid package id: {package_id}")));
        }

        let directory = self.store_packages_dir.join(package_id);
        let metadata = fs::symlink_metadata(&directory).map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("package is not in the system store: {package_id}"),
            )
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("package is not in the system store: {package_id}"),
            ));
        }

        let entries = fs::read_dir(&directory)?;
        let mut versions = Vec::new();
        for entry in entries {
            let entry = entry?;
            if !entry.file_type()?.is_symlink() {
                continue;
            }
            if let Some(version) = entry.file_name().to_str() {
                versions.push(version.to_owned());
            }
        }

        version_sort_last(&versions)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("package has no stored versions: {package_id}"),
            )
        })
    }

    /// Inspect an installed package selector (ID or ID=version).
    pub fn store_info_for_id(&self, selector: &str) -> io::Result<String> {
        if selector.is_empty() {
            return Err(invalid_input("package selector is empty"));
        }

        let (package_id, version) = match selector.split_once('=') {
            Some((package_id, version)) => (package_id, version.to_owned()),
            None => (selector, self.store_latest_version(selector)?),
        };

        if !valid_package_id(package_id) {
            return Err(invalid_input(format!("invalid package id: {package_id}")));
        }
        if !valid_package_version(&version) {
            return Err(invalid_input(format!("invalid package version: {version}")));
        }

        let link = self.store_packages_dir.join(package_id).join(&version);
        let link_metadata = fs::symlink_metadata(&link).map_err(|_| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("package is not in the system store: {package_id} {version}"),
            )
        })?;
        if !link_metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("package is not in the system store: {package_id} {version}"),
            ));
        }

        let target = fs::read_link(&link)?;
        let digest = target
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| invalid_input("store object link has an invalid target"))?;

        let object = self.store_object_dir(digest).map_err(|_| {
            invalid_input(format!("invalid store object for {package_id} {version}"))
        })?;
        let manifest = object.join("manifest.json");
        let payload = object.join("payload");
        if !manifest.is_file() || !payload.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("store object is incomplete: {}", object.display()),
            ));
        }

        manifest_info(&manifest, digest)
    }

    /// Hash and inspect a local LPK file already imported into the store.
    pub fn store_info_for_file(&self, file: &Path) -> io::Result<String> {
        let metadata = fs::symlink_metadata(file)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(invalid_input(format!(
                "package file must be a regular non-symlink file: {}",
                file.display()
            )));
        }

        File::open(file)?;
        let digest = digest_for_file(file)?;
        let object = self.store_object_dir(&digest)?;
        let manifest = object.join("manifest.json");
        let payload = object.join("payload");
        if !manifest.is_file() || !payload.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "package was not imported into the store: {}",
                    file.display()
                ),
            ));
        }

        manifest_info(&manifest, &digest)
    }
}

#[cfg(test)]
mod tests {
    use crate::BubblePaths;
    use std::collections::HashMap;
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "bubble-core-store-test-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn paths_for_test(root: &Path) -> BubblePaths {
        let values: HashMap<String, OsString> = [
            (
                "BUBBLEOS_STORE_OBJECTS_DIR".to_owned(),
                root.join("objects").into_os_string(),
            ),
            (
                "BUBBLEOS_STORE_PACKAGES_DIR".to_owned(),
                root.join("packages").into_os_string(),
            ),
        ]
        .into_iter()
        .collect();

        BubblePaths::from_lookup(|key| values.get(key).cloned())
    }

    #[test]
    fn digest_policy_requires_lowercase_sha256_hex() {
        assert!(super::is_digest(&"a".repeat(64)));
        assert!(super::is_digest(&"0123456789abcdef".repeat(4)));
        assert!(!super::is_digest(&"A".repeat(64)));
        assert!(!super::is_digest(&"a".repeat(63)));
        assert!(!super::is_digest(&"g".repeat(64)));
    }

    #[test]
    fn package_identifiers_and_versions_reject_path_traversal() {
        assert!(super::valid_package_id("bubble-base"));
        assert!(super::valid_package_id("lib_foo.2"));
        assert!(!super::valid_package_id(""));
        assert!(!super::valid_package_id("../outside"));
        assert!(!super::valid_package_id("bad..id"));
        assert!(!super::valid_package_id("nested/package"));
        assert!(!super::valid_package_version(""));
        assert!(!super::valid_package_version("../outside"));
        assert!(super::valid_package_version("1.2.3+build"));
    }

    #[test]
    fn object_paths_validate_digest_before_joining() {
        let root = temp_root();
        let paths = paths_for_test(&root);
        assert_eq!(
            paths.store_object_dir(&"a".repeat(64)).unwrap(),
            root.join("objects").join("a".repeat(64))
        );
        assert!(paths.store_object_dir("../outside").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn latest_version_uses_version_sort_and_only_symbolic_links() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let package = root.join("packages/demo");
        std::fs::create_dir_all(&package).unwrap();
        symlink("../../objects/one", package.join("1.9")).unwrap();
        symlink("../../objects/two", package.join("1.10")).unwrap();
        std::fs::create_dir_all(package.join("99.0-directory")).unwrap();
        std::fs::write(package.join("100.0-file"), b"not a version link").unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(paths.store_latest_version("demo").unwrap(), "1.10");
        assert!(paths.store_latest_version("../demo").is_err());

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn object_manifest_requires_a_manifest_file() {
        let root = temp_root();
        let digest = "b".repeat(64);
        let paths = paths_for_test(&root);
        std::fs::create_dir_all(root.join("objects").join(&digest)).unwrap();

        assert!(paths.store_object_manifest(&digest).is_err());
        std::fs::write(
            root.join("objects").join(&digest).join("manifest.json"),
            "{}",
        )
        .unwrap();
        assert_eq!(
            paths.store_object_manifest(&digest).unwrap(),
            root.join("objects").join(&digest).join("manifest.json")
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn object_info_for_id_projects_the_manifest_fields() {
        if Command::new("jq").arg("--version").output().is_err() {
            return;
        }

        use std::os::unix::fs::symlink;

        let root = temp_root();
        let digest = "c".repeat(64);
        let object = root.join("objects").join(&digest);
        std::fs::create_dir_all(object.join("payload")).unwrap();
        std::fs::write(
            object.join("manifest.json"),
            r#"{"id":"demo","version":"1.0","kind":"system","name":"Demo"}"#,
        )
        .unwrap();
        let package = root.join("packages/demo");
        std::fs::create_dir_all(&package).unwrap();
        symlink(format!("../../objects/{digest}"), package.join("1.0")).unwrap();

        let paths = paths_for_test(&root);
        assert_eq!(
            paths.store_info_for_id("demo=1.0").unwrap(),
            format!("demo\t1.0\tsystem\tDemo\t{digest}\n")
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn info_for_file_rejects_symlinks() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();
        let actual = root.join("package.lpk");
        std::fs::write(&actual, b"payload").unwrap();
        let link = root.join("package-link.lpk");
        symlink(&actual, &link).unwrap();

        let paths = paths_for_test(&root);
        assert!(paths.store_info_for_file(&link).is_err());

        std::fs::remove_dir_all(root).unwrap();
    }
}
