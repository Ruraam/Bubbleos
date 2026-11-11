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
    "$BUBBLEOS_PREVIOUS_LINK" > "$BUBBLEOS_STUB_CONFIG_FILE"
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

# Ensure the values above are not being inherited by the helper by accident.
export -n BUBBLEOS_NAME BUBBLEOS_VERSION BUBBLEOS_CHANNEL
export -n BUBBLEOS_STATE_DIR BUBBLEOS_CONFIG_DIR BUBBLEOS_CACHE_DIR BUBBLEOS_RUN_DIR
export -n BUBBLEOS_ROOTFS_MOUNT BUBBLEOS_ULPM_DIR BUBBLEOS_ULPM_CONFIG_DIR
export -n BUBBLEOS_ULPM_CACHE_DIR BUBBLEOS_STORE_DIR BUBBLEOS_STORE_OBJECTS_DIR
export -n BUBBLEOS_STORE_PACKAGES_DIR BUBBLEOS_BOOT_ASSETS_DIR BUBBLEOS_SNAPSHOTS_DIR
export -n BUBBLEOS_GENERATIONS_DIR BUBBLEOS_CURRENT_LINK BUBBLEOS_PREVIOUS_LINK

# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/system.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/generation.sh"

EXPECTED_CONFIG="$(printf '%s\n' \
    "$BUBBLEOS_NAME" "$BUBBLEOS_VERSION" "$BUBBLEOS_CHANNEL" \
    "$BUBBLEOS_STATE_DIR" "$BUBBLEOS_CONFIG_DIR" "$BUBBLEOS_CACHE_DIR" \
    "$BUBBLEOS_RUN_DIR" "$BUBBLEOS_ROOTFS_MOUNT" "$BUBBLEOS_ULPM_DIR" \
    "$BUBBLEOS_ULPM_CONFIG_DIR" "$BUBBLEOS_ULPM_CACHE_DIR" \
    "$BUBBLEOS_STORE_DIR" "$BUBBLEOS_STORE_OBJECTS_DIR" \
    "$BUBBLEOS_STORE_PACKAGES_DIR" "$BUBBLEOS_BOOT_ASSETS_DIR" \
    "$BUBBLEOS_SNAPSHOTS_DIR" "$BUBBLEOS_GENERATIONS_DIR" \
    "$BUBBLEOS_CURRENT_LINK" "$BUBBLEOS_PREVIOUS_LINK")"

assert_rust_call() {
    local expected_command="$1"
    shift
    "$@"
    [[ "$(cat "$BUBBLEOS_STUB_ARGS_FILE")" == "$expected_command" ]]
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
assert_rust_call generation-current bubble_generation_current
assert_rust_call generation-previous bubble_generation_previous
assert_rust_call status bubble_system_status

printf 'Rust path bridge: OK\n'
