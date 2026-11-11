#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - QEMU integration test runner
# ==============================================================================
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
cd "$REPO"

usage() {
    cat <<'USAGE'
Usage: tests/qemu/run.sh [suite ...]

Suites:
  boot          Boot smoke test (kernel, Btrfs, /boot, systemd, packages)
  bios          Legacy BIOS/SeaBIOS boot through the Limine MBR stages
  generations   Create/activate/rollback and explicit Limine entries
  fallback      Broken @rootfs/current and missing rootflags subvolume
  snapshots     /var restore across reboot and snapshot pruning
  store         System store, generation composition, upgrade/remove/rollback
  repo          Signed repositories, dependency resolution, update/upgrade
  ulpm          ULPM diagnostics and LPK pack/install/run/remove
  desktop       Wayfire session, desktop configuration and DRM smoke test
  settings      bubble-settings control center, users helper and polkit policy
  all           Run every suite (default)

Environment:
  DISK_IMAGE     Disk image (default: out/bubbleos.img)
  TEST_LOG_DIR   Serial logs (default: out/test-logs)
  TEST_TMPDIR    Temporary image copies (default: system temp directory)
  BOOT_TIMEOUT   Seconds to wait for the login prompt (default: 420)
USAGE
}

resolve_suite() {
    case "$1" in
        boot|test_boot|test_boot.py) printf 'test_boot.py\n' ;;
        bios|test_bios|test_bios.py) printf 'test_bios.py\n' ;;
        generations|test_generations|test_generations.py) printf 'test_generations.py\n' ;;
        fallback|test_fallback|test_fallback.py) printf 'test_fallback.py\n' ;;
        snapshots|test_snapshots|test_snapshots.py) printf 'test_snapshots.py\n' ;;
        store|test_store|test_store.py) printf 'test_store.py\n' ;;
        repo|test_repo|test_repo.py) printf 'test_repo.py\n' ;;
        ulpm|test_ulpm|test_ulpm.py) printf 'test_ulpm.py\n' ;;
        desktop|test_desktop|test_desktop.py) printf 'test_desktop.py\n' ;;
        settings|test_settings|test_settings.py) printf 'test_settings.py\n' ;;
        all) printf 'test_boot.py\ntest_bios.py\ntest_generations.py\ntest_fallback.py\ntest_snapshots.py\ntest_store.py\ntest_repo.py\ntest_ulpm.py\ntest_desktop.py\ntest_settings.py\n' ;;
        *)
            printf 'unknown suite: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

suites=()
if (( $# == 0 )); then
    resolved="$(resolve_suite all)"
    while IFS= read -r suite; do
        suites+=("$suite")
    done <<< "$resolved"
else
    for name in "$@"; do
        resolved="$(resolve_suite "$name")"
        while IFS= read -r suite; do
            suites+=("$suite")
        done <<< "$resolved"
    done
fi

command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: python3 is required\n' >&2
    exit 1
}
python3 -c 'import pexpect' >/dev/null 2>&1 || {
    printf 'ERROR: python3-pexpect is required\n' >&2
    exit 1
}
[[ -r "${DISK_IMAGE:-out/bubbleos.img}" ]] || {
    printf 'ERROR: missing disk image: %s\n' "${DISK_IMAGE:-out/bubbleos.img}" >&2
    printf 'Build it with: sudo ./build/build-image.sh && ./build/build-disk-image.sh\n' >&2
    exit 1
}

failed=()
for suite in "${suites[@]}"; do
    printf '\n########## %s ##########\n' "$suite"
    if python3 "tests/qemu/$suite"; then
        :
    else
        failed+=("$suite")
    fi
done

printf '\n========================================\n'
if (( ${#failed[@]} != 0 )); then
    printf 'FAILED: %s\n' "${failed[*]}"
    printf 'Logs: %s\n' "${TEST_LOG_DIR:-out/test-logs}"
    exit 1
fi
printf 'All QEMU integration tests passed.\n'
printf 'Logs: %s\n' "${TEST_LOG_DIR:-out/test-logs}"
