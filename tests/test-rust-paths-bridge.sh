#!/usr/bin/env bash
# Verify that paths.sh forwards sourced configuration to the optional Rust helper.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

BUBBLEOS_RUST_PATHS_BIN="$TMP_DIR/bubble-paths"
BUBBLEOS_STUB_ARGS_FILE="$TMP_DIR/args"
BUBBLEOS_STUB_CONFIG_FILE="$TMP_DIR/config"
export BUBBLEOS_STUB_ARGS_FILE BUBBLEOS_STUB_CONFIG_FILE

cat > "$BUBBLEOS_RUST_PATHS_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$BUBBLEOS_STUB_ARGS_FILE"
printf '%s\n' \
    "$BUBBLEOS_NAME" \
    "$BUBBLEOS_VERSION" \
    "$BUBBLEOS_CHANNEL" \
    "$BUBBLEOS_STATE_DIR" \
    "$BUBBLEOS_CONFIG_DIR" \
    "$BUBBLEOS_CACHE_DIR" \
    "$BUBBLEOS_RUN_DIR" \
    "$BUBBLEOS_ROOTFS_MOUNT" \
    "$BUBBLEOS_ULPM_DIR" \
    "$BUBBLEOS_ULPM_CONFIG_DIR" \
    "$BUBBLEOS_ULPM_CACHE_DIR" \
    "$BUBBLEOS_STORE_DIR" \
    "$BUBBLEOS_STORE_OBJECTS_DIR" \
    "$BUBBLEOS_STORE_PACKAGES_DIR" \
    "$BUBBLEOS_BOOT_ASSETS_DIR" \
    "$BUBBLEOS_SNAPSHOTS_DIR" \
    "$BUBBLEOS_GENERATIONS_DIR" \
    "$BUBBLEOS_CURRENT_LINK" \
    "$BUBBLEOS_PREVIOUS_LINK" \
    "$BUBBLEOS_LIMINE_CMDLINE" \
    "$BUBBLEOS_LIMINE_KERNEL" \
    "$BUBBLEOS_LIMINE_INITRAMFS" \
    "$BUBBLEOS_LIMINE_TIMEOUT" \
    "$BUBBLEOS_ESP_GENERATIONS_DIR" > "$BUBBLEOS_STUB_CONFIG_FILE"

case "${1:-}" in
    arch) printf 'amd64\n' ;;
    version-compare) printf '0\n' ;;
    version-matches) printf 'true\n' ;;
    generation-create) printf '000124\n' ;;
    generation-switch-links) : ;;
    generation-write-metadata) : ;;
esac
STUB
chmod 0755 "$BUBBLEOS_RUST_PATHS_BIN"

# Keep these as shell variables, just like values sourced from bubble.conf.
BUBBLEOS_NAME="bridge-test"
BUBBLEOS_VERSION="9.8.7"
BUBBLEOS_CHANNEL="ci"
BUBBLEOS_STATE_DIR="$TMP_DIR/state"
BUBBLEOS_CONFIG_DIR="$TMP_DIR/config-dir"
BUBBLEOS_CACHE_DIR="$TMP_DIR/cache"
BUBBLEOS_RUN_DIR="$TMP_DIR/run"
BUBBLEOS_ROOTFS_MOUNT="$TMP_DIR/rootfs"
BUBBLEOS_ULPM_DIR="$TMP_DIR/ulpm"
BUBBLEOS_ULPM_CONFIG_DIR="$TMP_DIR/ulpm-config"
BUBBLEOS_ULPM_CACHE_DIR="$TMP_DIR/ulpm-cache"
BUBBLEOS_STORE_DIR="$TMP_DIR/store"
BUBBLEOS_STORE_OBJECTS_DIR="$TMP_DIR/store/objects"
BUBBLEOS_STORE_PACKAGES_DIR="$TMP_DIR/store/packages"
BUBBLEOS_BOOT_ASSETS_DIR="$TMP_DIR/boot"
BUBBLEOS_SNAPSHOTS_DIR="$TMP_DIR/snapshots"
BUBBLEOS_GENERATIONS_DIR="$TMP_DIR/generations"
BUBBLEOS_CURRENT_LINK="$TMP_DIR/rootfs/current"
BUBBLEOS_PREVIOUS_LINK="$TMP_DIR/rootfs/previous"
BUBBLEOS_LIMINE_CMDLINE="bridge-console quiet"
BUBBLEOS_LIMINE_KERNEL="boot():/bridge-vmlinuz"
BUBBLEOS_LIMINE_INITRAMFS="boot():/bridge-initramfs.cpio.gz"
BUBBLEOS_LIMINE_TIMEOUT="3"
BUBBLEOS_ESP_GENERATIONS_DIR="esp-generations"

# Ensure the values above are not being inherited by the helper by accident.
export -n BUBBLEOS_NAME BUBBLEOS_VERSION BUBBLEOS_CHANNEL
export -n BUBBLEOS_STATE_DIR BUBBLEOS_CONFIG_DIR BUBBLEOS_CACHE_DIR BUBBLEOS_RUN_DIR
export -n BUBBLEOS_ROOTFS_MOUNT BUBBLEOS_ULPM_DIR BUBBLEOS_ULPM_CONFIG_DIR
export -n BUBBLEOS_ULPM_CACHE_DIR BUBBLEOS_STORE_DIR BUBBLEOS_STORE_OBJECTS_DIR
export -n BUBBLEOS_STORE_PACKAGES_DIR BUBBLEOS_BOOT_ASSETS_DIR BUBBLEOS_SNAPSHOTS_DIR
export -n BUBBLEOS_GENERATIONS_DIR BUBBLEOS_CURRENT_LINK BUBBLEOS_PREVIOUS_LINK
export -n BUBBLEOS_LIMINE_CMDLINE BUBBLEOS_LIMINE_KERNEL BUBBLEOS_LIMINE_INITRAMFS
export -n BUBBLEOS_LIMINE_TIMEOUT BUBBLEOS_ESP_GENERATIONS_DIR

# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/system.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/repo.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/generation.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/bootloader.sh"

EXPECTED_CONFIG="$(printf '%s\n' \
    "$BUBBLEOS_NAME" "$BUBBLEOS_VERSION" "$BUBBLEOS_CHANNEL" \
    "$BUBBLEOS_STATE_DIR" "$BUBBLEOS_CONFIG_DIR" "$BUBBLEOS_CACHE_DIR" \
    "$BUBBLEOS_RUN_DIR" "$BUBBLEOS_ROOTFS_MOUNT" "$BUBBLEOS_ULPM_DIR" \
    "$BUBBLEOS_ULPM_CONFIG_DIR" "$BUBBLEOS_ULPM_CACHE_DIR" \
    "$BUBBLEOS_STORE_DIR" "$BUBBLEOS_STORE_OBJECTS_DIR" \
    "$BUBBLEOS_STORE_PACKAGES_DIR" "$BUBBLEOS_BOOT_ASSETS_DIR" \
    "$BUBBLEOS_SNAPSHOTS_DIR" "$BUBBLEOS_GENERATIONS_DIR" \
    "$BUBBLEOS_CURRENT_LINK" "$BUBBLEOS_PREVIOUS_LINK" \
    "$BUBBLEOS_LIMINE_CMDLINE" "$BUBBLEOS_LIMINE_KERNEL" \
    "$BUBBLEOS_LIMINE_INITRAMFS" "$BUBBLEOS_LIMINE_TIMEOUT" \
    "$BUBBLEOS_ESP_GENERATIONS_DIR")"

assert_rust_call() {
    local expected_args="$1" function_name="$2" argument
    shift 2
    "$function_name" "$@"
    for argument in "$@"; do
        expected_args+=$'\n'"$argument"
    done
    [[ "$(cat "$BUBBLEOS_STUB_ARGS_FILE")" == "$expected_args" ]]
    [[ "$(cat "$BUBBLEOS_STUB_CONFIG_FILE")" == "$EXPECTED_CONFIG" ]]
}

assert_rust_call require-root bubble_require_root
assert_rust_call require-generation bubble_require_generation_layout
assert_rust_call require-snapshots bubble_require_snapshots_layout
assert_rust_call init bubble_init_paths
assert_rust_call system-init bubble_system_init
assert_rust_call root-subvol bubble_system_root_subvol
assert_rust_call root-fstype bubble_system_root_fstype
assert_rust_call ulpm-version bubble_ulpm_version
assert_rust_call lpk-format-version bubble_lpk_format_version
assert_rust_call arch bubble_arch
assert_rust_call version-compare bubble_version_compare 1.0 1.0
assert_rust_call version-matches bubble_version_matches 1.0 '*'
assert_rust_call generation-current bubble_generation_current
assert_rust_call generation-previous bubble_generation_previous
assert_rust_call generation-running bubble_generation_running
assert_rust_call status bubble_system_status
assert_rust_call generation-list bubble_generation_list
assert_rust_call generation-next bubble_generation_next
bubble_generation_create --from 000123 --description bridge-test >/dev/null
[[ "$(cat "$BUBBLEOS_STUB_ARGS_FILE")" == "$(printf '%s\n' generation-create 000123 bridge-test)" ]]
[[ "$(cat "$BUBBLEOS_STUB_CONFIG_FILE")" == "$EXPECTED_CONFIG" ]]
BUBBLEOS_SKIP_SNAPSHOTS=1 bubble_generation_activate 000123 >/dev/null
[[ "$(cat "$BUBBLEOS_STUB_ARGS_FILE")" == "$(printf '%s\n' generation-switch-links 000123 '')" ]]
[[ "$(cat "$BUBBLEOS_STUB_CONFIG_FILE")" == "$EXPECTED_CONFIG" ]]
assert_rust_call generation-write-metadata bubble_generation_write_metadata 000123 bridge-metadata
assert_rust_call generation-exists bubble_generation_exists 000123
assert_rust_call snapshot-valid-name bubble_snapshot_valid_name restore.001
assert_rust_call snapshot-pending-path bubble_snapshot_pending_path
assert_rust_call snapshot-pending-from-file bubble_snapshot_pending_from_file "$TMP_DIR/marker"
assert_rust_call snapshot-pending bubble_snapshot_pending
assert_rust_call snapshot-list bubble_snapshot_list
assert_rust_call bootloader-root-uuid bubble_bootloader_root_uuid
assert_rust_call bootloader-render bubble_bootloader_render_config \
    "$TMP_DIR/generations" uuid-test 000010 000009

printf 'Rust path bridge: OK\n'
