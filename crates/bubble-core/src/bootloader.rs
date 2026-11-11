//! Pure Limine boot-menu rendering for BubbleOS.
//!
//! Files are inspected, but no ESP files are written by this module. Staging,
//! atomic replacement and pruning remain in the shell synchronizer.

use std::fs::{self, File};
use std::io::{self, copy};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Formatting and path settings used by the legacy Limine renderer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LimineRenderOptions {
    pub cmdline: String,
    pub kernel_path: String,
    pub initramfs_path: String,
    pub timeout: String,
    pub boot_assets_dir: PathBuf,
    pub esp_generations_dir: String,
}

impl Default for LimineRenderOptions {
    fn default() -> Self {
        fn env_or(key: &str, fallback: &str) -> String {
            std::env::var(key)
                .ok()
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| fallback.to_owned())
        }

        Self {
            cmdline: env_or(
                "BUBBLEOS_LIMINE_CMDLINE",
                "console=ttyS0,115200 quiet selinux=0",
            ),
            kernel_path: env_or("BUBBLEOS_LIMINE_KERNEL", "boot():/vmlinuz"),
            initramfs_path: env_or("BUBBLEOS_LIMINE_INITRAMFS", "boot():/initramfs.cpio.gz"),
            timeout: env_or("BUBBLEOS_LIMINE_TIMEOUT", "0"),
            boot_assets_dir: PathBuf::from(env_or(
                "BUBBLEOS_BOOT_ASSETS_DIR",
                "/usr/lib/bubbleos/boot",
            )),
            esp_generations_dir: env_or("BUBBLEOS_ESP_GENERATIONS_DIR", "generations"),
        }
    }
}

fn is_generation_id(value: &str) -> bool {
    value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn generations(directory: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };

    let mut result = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if is_generation_id(name) && entry.path().is_dir() {
            result.push(name.to_owned());
        }
    }

    // All accepted names have six ASCII digits, so reverse byte ordering
    // matches the C-locale reverse sort used by the shell implementation.
    result.sort_unstable_by(|left, right| right.cmp(left));
    result
}

fn generation_description(generations_dir: &Path, generation: &str) -> String {
    let metadata = generations_dir
        .join(generation)
        .join("etc/bubbleos/generation");
    let contents = fs::read(metadata).unwrap_or_default();

    let value = contents
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"DESCRIPTION="))
        .and_then(|value| String::from_utf8(value.to_vec()).ok())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("bubbleOS generation {generation}"));

    sanitize_title(&value)
}

fn sanitize_title(value: &str) -> String {
    value
        .chars()
        .map(|character| match character {
            '\n' | '\r' => ' ',
            '/' => '-',
            other => other,
        })
        .take(72)
        .collect()
}

fn command_line(options: &LimineRenderOptions, root_uuid: &str, extra: &str) -> String {
    let mut result = format!(
        "{} root=UUID={} rootfstype=btrfs rw",
        options.cmdline, root_uuid
    );
    if !extra.is_empty() {
        result.push(' ');
        result.push_str(extra);
    }
    result
}

/// Hash the concatenated kernel and initramfs streams, matching the shell
/// pipeline that feeds both files to sha256sum without a separator.
fn generation_asset_digest(
    generations_dir: &Path,
    generation: &str,
    options: &LimineRenderOptions,
) -> Option<String> {
    // The shell concatenates GENERATIONS_DIR/ID with the absolute-looking
    // asset path; strip its leading slash rather than letting Path::join
    // reset the path to the host filesystem root.
    let assets_relative = PathBuf::from(
        options
            .boot_assets_dir
            .to_string_lossy()
            .trim_start_matches('/'),
    );
    let assets = generations_dir.join(generation).join(assets_relative);
    let kernel = assets.join("vmlinuz");
    let initramfs = assets.join("initramfs.cpio.gz");

    if !kernel.is_file() || !initramfs.is_file() {
        return None;
    }

    let mut child = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let write_result = (|| -> io::Result<()> {
        let mut input = child.stdin.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::BrokenPipe, "sha256sum stdin is unavailable")
        })?;
        let mut kernel_file = File::open(kernel)?;
        let mut initramfs_file = File::open(initramfs)?;
        copy(&mut kernel_file, &mut input)?;
        copy(&mut initramfs_file, &mut input)?;
        Ok(())
    })();

    let output = child.wait_with_output().ok()?;
    if write_result.is_err() || !output.status.success() {
        return None;
    }

    String::from_utf8(output.stdout)
        .ok()?
        .split_ascii_whitespace()
        .next()
        .map(str::to_owned)
}

fn generation_boot_paths(
    generations_dir: &Path,
    generation: &str,
    current: &str,
    options: &LimineRenderOptions,
) -> (String, String) {
    let mut kernel_path = options.kernel_path.clone();
    let mut module_path = options.initramfs_path.clone();

    if !current.is_empty() && generation != current {
        if let Some(digest) = generation_asset_digest(generations_dir, generation, options) {
            let current_digest =
                generation_asset_digest(generations_dir, current, options).unwrap_or_default();

            if current_digest.is_empty() || digest != current_digest {
                kernel_path = format!(
                    "boot():/{}/{}/vmlinuz",
                    options.esp_generations_dir, generation
                );
                module_path = format!(
                    "boot():/{}/{}/initramfs.cpio.gz",
                    options.esp_generations_dir, generation
                );
            }
        }
    }

    (kernel_path, module_path)
}

fn resolve_root_uuid<F, G>(mut findmnt: F, mut blkid: G) -> Option<String>
where
    F: FnMut(&str) -> Option<String>,
    G: FnMut(&str) -> Option<String>,
{
    if let Some(uuid) = findmnt("UUID").filter(|value| !value.is_empty()) {
        return Some(uuid);
    }

    let source = findmnt("SOURCE")?;
    let source = source.split('[').next().unwrap_or_default();
    if source.is_empty() {
        return None;
    }

    blkid(source).filter(|value| !value.is_empty())
}

/// Resolve the filesystem UUID of the configured RootFS mountpoint.
///
/// This follows the legacy order: findmnt UUID first, then its source device
/// stripped of any subvolume suffix and queried through blkid.
pub fn root_uuid(rootfs_mount: &Path) -> Option<String> {
    let findmnt = |field: &str| {
        let output = Command::new("findmnt")
            .args(["-no", field, "-T"])
            .arg(rootfs_mount)
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        Some(
            String::from_utf8_lossy(&output.stdout)
                .trim_end_matches('\n')
                .to_owned(),
        )
    };

    resolve_root_uuid(findmnt, |source| {
        let output = Command::new("blkid")
            .args(["-s", "UUID", "-o", "value", source])
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        Some(
            String::from_utf8_lossy(&output.stdout)
                .trim_end_matches('\n')
                .to_owned(),
        )
    })
}

/// Render the exact Limine menu used by the legacy shell renderer.
///
/// Current and previous may be empty, matching the shell function's optional
/// arguments.
pub fn render_config(
    generations_dir: &Path,
    root_uuid: &str,
    current: &str,
    previous: &str,
    options: &LimineRenderOptions,
) -> String {
    use std::fmt::Write as _;

    let mut output = String::new();
    output.push_str("# Generated by bubbleOS - do not edit by hand.\n");
    output.push_str("# Regenerate with: bubble bootloader sync\n\n");
    let _ = writeln!(output, "timeout: {}", options.timeout);
    output.push_str("default_entry: 1\n");
    output.push_str("serial: yes\n");

    let current_label = if current.is_empty() {
        "bubbleOS (current)".to_owned()
    } else {
        format!("bubbleOS (current: generation {current})")
    };

    let _ = writeln!(output, "\n/{current_label}");
    output.push_str("    protocol: linux\n");
    let _ = writeln!(output, "    kernel_path: {}", options.kernel_path);
    let _ = writeln!(output, "    module_path: {}", options.initramfs_path);
    let _ = writeln!(
        output,
        "    cmdline: {}",
        command_line(options, root_uuid, "")
    );

    for generation in generations(generations_dir) {
        if generation == current {
            continue;
        }

        let description = generation_description(generations_dir, &generation);
        let suffix = if generation == previous {
            ", previous"
        } else {
            ""
        };
        let label = format!("bubbleOS generation {generation}{suffix} - {description}");
        let (kernel_path, module_path) =
            generation_boot_paths(generations_dir, &generation, current, options);

        let _ = writeln!(output, "\n/{label}");
        output.push_str("    protocol: linux\n");
        let _ = writeln!(output, "    kernel_path: {kernel_path}");
        let _ = writeln!(output, "    module_path: {module_path}");
        let _ = writeln!(
            output,
            "    cmdline: {}",
            command_line(
                options,
                root_uuid,
                &format!("rootflags=subvol=@rootfs/generations/{generation}")
            )
        );
    }

    output
}

#[cfg(test)]
mod tests {
    use super::{render_config, LimineRenderOptions};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "bubble-core-limine-test-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn options() -> LimineRenderOptions {
        LimineRenderOptions {
            cmdline: "console=ttyS0,115200 quiet selinux=0".to_owned(),
            kernel_path: "boot():/vmlinuz".to_owned(),
            initramfs_path: "boot():/initramfs.cpio.gz".to_owned(),
            timeout: "0".to_owned(),
            boot_assets_dir: PathBuf::from("/usr/lib/bubbleos/boot"),
            esp_generations_dir: "generations".to_owned(),
        }
    }

    fn write_generation(root: &Path, id: &str, description: &str) {
        let generation = root.join(id);
        std::fs::create_dir_all(generation.join("etc/bubbleos")).unwrap();
        std::fs::write(
            generation.join("etc/bubbleos/generation"),
            format!("GENERATION={id}\nDESCRIPTION={description}\n"),
        )
        .unwrap();
    }

    #[test]
    fn root_uuid_prefers_findmnt_uuid() {
        let mut blkid_called = false;
        let uuid = super::resolve_root_uuid(
            |field| (field == "UUID").then(|| "uuid-findmnt".to_owned()),
            |_| {
                blkid_called = true;
                Some("uuid-blkid".to_owned())
            },
        );

        assert_eq!(uuid, Some("uuid-findmnt".to_owned()));
        assert!(!blkid_called);
    }

    #[test]
    fn root_uuid_falls_back_to_blkid_after_stripping_subvolume_suffix() {
        let mut queried_source = String::new();
        let uuid = super::resolve_root_uuid(
            |field| match field {
                "UUID" => Some(String::new()),
                "SOURCE" => Some("/dev/mapper/bubble-root[/@rootfs]".to_owned()),
                _ => None,
            },
            |source| {
                queried_source = source.to_owned();
                Some("uuid-blkid".to_owned())
            },
        );

        assert_eq!(uuid, Some("uuid-blkid".to_owned()));
        assert_eq!(queried_source, "/dev/mapper/bubble-root");
    }

    #[test]
    fn root_uuid_fails_when_findmnt_has_no_device_source() {
        let mut blkid_called = false;
        let uuid = super::resolve_root_uuid(
            |field| match field {
                "UUID" => Some(String::new()),
                "SOURCE" => Some(String::new()),
                _ => None,
            },
            |_| {
                blkid_called = true;
                Some("unexpected".to_owned())
            },
        );

        assert_eq!(uuid, None);
        assert!(!blkid_called);
    }

    #[test]
    fn empty_layout_renders_the_legacy_current_entry_byte_for_byte() {
        let root = temp_root();
        std::fs::create_dir_all(&root).unwrap();

        let expected = concat!(
            "# Generated by bubbleOS - do not edit by hand.\n",
            "# Regenerate with: bubble bootloader sync\n",
            "\n",
            "timeout: 0\n",
            "default_entry: 1\n",
            "serial: yes\n",
            "\n",
            "/bubbleOS (current)\n",
            "    protocol: linux\n",
            "    kernel_path: boot():/vmlinuz\n",
            "    module_path: boot():/initramfs.cpio.gz\n",
            "    cmdline: console=ttyS0,115200 quiet selinux=0 root=UUID=uuid-test rootfstype=btrfs rw\n"
        );

        assert_eq!(
            render_config(&root, "uuid-test", "", "", &options()),
            expected
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn generation_menu_keeps_order_titles_and_private_boot_assets() {
        let root = temp_root();
        write_generation(&root, "000010", "Current kernel");
        write_generation(&root, "000009", "Shared kernel");
        write_generation(&root, "000002", "Old/system\rrevision");
        write_generation(&root, ".hidden", "hidden");
        write_generation(&root, "invalid", "invalid");

        for id in ["000010", "000009", "000002"] {
            let assets = root.join(id).join("usr/lib/bubbleos/boot");
            std::fs::create_dir_all(&assets).unwrap();
            let (kernel, initramfs): (&[u8], &[u8]) = if id == "000002" {
                (&b"old-kernel"[..], &b"old-initramfs"[..])
            } else {
                (&b"kernel"[..], &b"initramfs"[..])
            };
            std::fs::write(assets.join("vmlinuz"), kernel).unwrap();
            std::fs::write(assets.join("initramfs.cpio.gz"), initramfs).unwrap();
        }

        let rendered = render_config(&root, "uuid-test", "000010", "000002", &options());
        let current = rendered
            .find("/bubbleOS (current: generation 000010)")
            .unwrap();
        let shared = rendered
            .find("/bubbleOS generation 000009 - Shared kernel")
            .unwrap();
        let previous = rendered
            .find("/bubbleOS generation 000002, previous - Old-system revision")
            .unwrap();

        assert!(current < shared && shared < previous);
        assert!(rendered.contains("kernel_path: boot():/vmlinuz"));
        assert!(rendered.contains("kernel_path: boot():/generations/000002/vmlinuz"));
        assert!(rendered.contains("module_path: boot():/generations/000002/initramfs.cpio.gz"));
        assert!(rendered.contains(
            "cmdline: console=ttyS0,115200 quiet selinux=0 root=UUID=uuid-test rootfstype=btrfs rw rootflags=subvol=@rootfs/generations/000002"
        ));
        assert!(!rendered.contains("hidden"));
        assert!(!rendered.contains("invalid"));

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_current_assets_make_other_generation_assets_private() {
        let root = temp_root();
        write_generation(&root, "000010", "Current");
        write_generation(&root, "000002", "Older");

        let assets = root.join("000002/usr/lib/bubbleos/boot");
        std::fs::create_dir_all(&assets).unwrap();
        std::fs::write(assets.join("vmlinuz"), b"kernel").unwrap();
        std::fs::write(assets.join("initramfs.cpio.gz"), b"initramfs").unwrap();

        let rendered = render_config(&root, "uuid-test", "000010", "", &options());
        assert!(rendered.contains("kernel_path: boot():/generations/000002/vmlinuz"));

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_generation_assets_retain_shared_boot_paths() {
        let root = temp_root();
        write_generation(&root, "000010", "Current");
        write_generation(&root, "000002", "Older");

        let rendered = render_config(&root, "uuid-test", "000010", "", &options());
        assert!(rendered.contains("kernel_path: boot():/vmlinuz"));
        assert!(!rendered.contains("boot():/generations/000002/vmlinuz"));

        std::fs::remove_dir_all(root).unwrap();
    }
}
