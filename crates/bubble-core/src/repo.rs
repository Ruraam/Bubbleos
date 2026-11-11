//! Architecture normalization and package-version comparison shared by BubbleOS.
//!
//! Debian's dpkg comparator is preferred when available, matching the legacy
//! shell implementation. The dependency-free fallback preserves its existing
//! comparison rules for minimal systems without dpkg.

use std::cmp::Ordering;
use std::process::{Command, Stdio};

/// Normalize common kernel machine names to ULPM's package architecture names.
pub fn architecture_from_machine(machine: &str) -> &str {
    match machine {
        "x86_64" | "amd64" => "amd64",
        "aarch64" | "arm64" => "arm64",
        "armv7l" | "armv7" | "armhf" => "armhf",
        "i386" | "i686" => "i386",
        other => other,
    }
}

/// Return the host architecture using the same uname source as the shell code.
pub fn architecture() -> String {
    Command::new("uname")
        .arg("-m")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| {
            architecture_from_machine(
                String::from_utf8_lossy(&output.stdout)
                    .trim()
            )
            .to_owned()
        })
        .unwrap_or_else(|| "unknown".to_owned())
}

fn strip_epoch(version: &str) -> &str {
    version
        .split_once(':')
        .map(|(_, remainder)| remainder)
        .unwrap_or(version)
}

fn compare_fallback(left: &str, right: &str) -> Ordering {
    if left == right {
        return Ordering::Equal;
    }

    let left_parts: Vec<&str> = left.split(['.', '-', '+']).collect();
    let right_parts: Vec<&str> = right.split(['.', '-', '+']).collect();
    let max_parts = left_parts.len().max(right_parts.len());

    for index in 0..max_parts {
        let left_part = left_parts.get(index).copied().unwrap_or("0");
        let right_part = right_parts.get(index).copied().unwrap_or("0");
        if left_part == right_part {
            continue;
        }

        let left_numeric = !left_part.is_empty()
            && left_part.bytes().all(|byte| byte.is_ascii_digit());
        let right_numeric = !right_part.is_empty()
            && right_part.bytes().all(|byte| byte.is_ascii_digit());

        if left_numeric && right_numeric {
            match left_part.len().cmp(&right_part.len()) {
                Ordering::Equal => {}
                ordering => return ordering,
            }
            match left_part.as_bytes().cmp(right_part.as_bytes()) {
                Ordering::Equal => continue,
                ordering => return ordering,
            }
        }

        return left_part.as_bytes().cmp(right_part.as_bytes());
    }

    Ordering::Equal
}

fn compare_with_dpkg(left: &str, right: &str) -> Option<Ordering> {
    let equal = Command::new("dpkg")
        .args(["--compare-versions", left, "eq", right])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()?;
    if equal.success() {
        return Some(Ordering::Equal);
    }

    let greater = Command::new("dpkg")
        .args(["--compare-versions", left, "gt", right])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()?;
    if greater.success() {
        Some(Ordering::Greater)
    } else {
        // This intentionally preserves the Bash contract: if dpkg exists and
        // neither "eq" nor "gt" succeeds, the result is the "lower" code.
        Some(Ordering::Less)
    }
}

/// Compare versions and preserve BubbleOS's 0=equal, 1=greater, 2=lower model.
pub fn compare_versions(left: &str, right: &str) -> Ordering {
    if left == right {
        return Ordering::Equal;
    }

    let left = strip_epoch(left);
    let right = strip_epoch(right);

    compare_with_dpkg(left, right).unwrap_or_else(|| compare_fallback(left, right))
}

/// Evaluate the constraint operators accepted by bubble_version_matches.
pub fn version_matches(version: &str, constraint: &str) -> bool {
    if constraint.is_empty() || constraint == "all" || constraint == "*" {
        return true;
    }

    let operator_len = constraint
        .bytes()
        .take_while(|byte| matches!(byte, b'>' | b'=' | b'<'))
        .count();
    let (operator, wanted) = if operator_len == 0 {
        ("=", constraint)
    } else {
        (&constraint[..operator_len], &constraint[operator_len..])
    };

    let ordering = compare_versions(version, wanted);
    match operator {
        "=" | "==" => ordering == Ordering::Equal,
        ">=" => ordering != Ordering::Less,
        "<=" => ordering != Ordering::Greater,
        ">" => ordering == Ordering::Greater,
        "<" => ordering == Ordering::Less,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        architecture_from_machine, compare_fallback, compare_versions, strip_epoch,
        version_matches,
    };
    use std::cmp::Ordering;

    #[test]
    fn architecture_names_match_the_legacy_mapping() {
        for (machine, expected) in [
            ("x86_64", "amd64"),
            ("amd64", "amd64"),
            ("aarch64", "arm64"),
            ("arm64", "arm64"),
            ("armv7l", "armhf"),
            ("armv7", "armhf"),
            ("armhf", "armhf"),
            ("i386", "i386"),
            ("i686", "i386"),
            ("riscv64", "riscv64"),
        ] {
            assert_eq!(architecture_from_machine(machine), expected);
        }
    }

    #[test]
    fn fallback_comparison_preserves_legacy_segment_rules() {
        assert_eq!(compare_fallback("1.2.10", "1.2.9"), Ordering::Greater);
        assert_eq!(compare_fallback("1.0-2", "1.0-1"), Ordering::Greater);
        assert_eq!(compare_fallback("1.0+git2", "1.0+git1"), Ordering::Greater);
        assert_eq!(compare_fallback("1.0", "1.0.0"), Ordering::Equal);
        // The old fallback compares numeric segment width before digit value.
        assert_eq!(compare_fallback("1.01", "1.1"), Ordering::Greater);
        assert_eq!(compare_fallback("1.alpha", "1.beta"), Ordering::Less);
    }

    #[test]
    fn epoch_prefix_is_stripped_before_comparison_like_the_shell() {
        assert_eq!(strip_epoch("2:1.2.3-4"), "1.2.3-4");
        assert_eq!(strip_epoch("1.2.3"), "1.2.3");
        assert_eq!(compare_versions("2:1.0", "1:1.0"), Ordering::Equal);
    }

    #[test]
    fn constraints_support_all_legacy_operators() {
        assert!(version_matches("1.2.0", ""));
        assert!(version_matches("1.2.0", "all"));
        assert!(version_matches("1.2.0", "*"));
        assert!(version_matches("1.2.0", "1.2.0"));
        assert!(version_matches("1.2.0", "==1.2.0"));
        assert!(version_matches("1.2.0", ">=1.1.0"));
        assert!(version_matches("1.2.0", "<=1.2.0"));
        assert!(version_matches("1.2.0", ">1.1.0"));
        assert!(version_matches("1.2.0", "<1.3.0"));
        assert!(!version_matches("1.2.0", "1.2.1"));
        assert!(!version_matches("1.2.0", ">>1.0"));
        assert!(!version_matches("1.2.0", ">= "));
    }

    #[test]
    fn public_comparison_returns_consistent_ordering() {
        assert_eq!(compare_versions("1.0", "1.0"), Ordering::Equal);
        assert_eq!(compare_versions("1.1", "1.0"), Ordering::Greater);
        assert_eq!(compare_versions("1.0", "1.1"), Ordering::Less);
    }
}
