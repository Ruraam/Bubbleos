#!/usr/bin/env bash
# Exercise generation creation through the Rust binary with isolated Btrfs stubs.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || {
    printf 'Usage: %s <bubble-paths-binary>\n' "$0" >&2
    exit 2
}
case "$1" in
    /*) BINARY="$1" ;;
    *) BINARY="$ROOT/$1" ;;
esac
[[ -x "$BINARY" ]] || {
    printf 'Rust helper is not executable: %s\n' "$BINARY" >&2
    exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bubble generation test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT
ROOTFS="$TMP_DIR/rootfs"
GENERATIONS="$ROOTFS/generations"
FAKE_BIN="$TMP_DIR/bin"
OUTSIDE="$TMP_DIR/outside"
mkdir -p "$GENERATIONS/000123/etc/bubbleos" "$FAKE_BIN" "$OUTSIDE"
printf 'GENERATION=000123\n' > "$GENERATIONS/000123/etc/bubbleos/generation"
ln -s "generations/000123" "$ROOTFS/current"

cat > "$FAKE_BIN/mountpoint" <<'MOUNTPOINT'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 3 && "$1" == "-q" && "$2" == "--" && "$3" == "$TEST_ROOTFS" ]]
MOUNTPOINT

cat > "$FAKE_BIN/btrfs" <<'BTRFS'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 4 && "$1" == "subvolume" && "$2" == "snapshot" ]]
source="$3"
destination="$4"
[[ -d "$source" && ! -e "$destination" ]]
mkdir -p "$destination"
cp -a "$source/." "$destination/"
BTRFS
chmod 0755 "$FAKE_BIN/mountpoint" "$FAKE_BIN/btrfs"

export TEST_ROOTFS="$ROOTFS"
export PATH="$FAKE_BIN:/usr/bin:/bin"
export BUBBLEOS_STATE_DIR="$TMP_DIR/state"
export BUBBLEOS_CONFIG_DIR="$TMP_DIR/config"
export BUBBLEOS_CACHE_DIR="$TMP_DIR/cache"
export BUBBLEOS_RUN_DIR="$TMP_DIR/run"
export BUBBLEOS_ROOTFS_MOUNT="$ROOTFS"
export BUBBLEOS_GENERATIONS_DIR="$GENERATIONS"
export BUBBLEOS_CURRENT_LINK="$ROOTFS/current"
export BUBBLEOS_PREVIOUS_LINK="$ROOTFS/previous"
export BUBBLEOS_SNAPSHOTS_DIR="$TMP_DIR/snapshots"

created="$("$BINARY" generation-create "" $'integration test\nsecond line')"
[[ "$created" == "000124" ]]
metadata="$GENERATIONS/000124/etc/bubbleos/generation"
[[ -f "$metadata" ]]
grep -Fxq 'GENERATION=000124' "$metadata"
grep -Fxq 'DESCRIPTION=integration test second line' "$metadata"
grep -Eq '^CREATED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$metadata"

# The Rust activation command atomically records the former and selected roots.
"$BINARY" generation-switch-links 000124 000123
[[ "$(readlink "$ROOTFS/previous")" == "generations/000123" ]]
[[ "$(readlink "$ROOTFS/current")" == "generations/000124" ]]

# A source generation with a symlinked /etc must not redirect metadata writes.
rm -rf -- "$GENERATIONS/000124/etc"
ln -s "$OUTSIDE" "$GENERATIONS/000124/etc"
ln -sfn "generations/000124" "$ROOTFS/current"

if "$BINARY" generation-create "" "must not escape" >/dev/null 2>&1; then
    printf 'generation creation unexpectedly accepted a symlinked /etc\n' >&2
    exit 1
fi
[[ ! -e "$OUTSIDE/bubbleos/generation" ]]
[[ -L "$GENERATIONS/000125/etc" ]]
[[ ! -e "$GENERATIONS/000125/etc/bubbleos/generation" ]]

printf 'Rust Btrfs generation creation: OK\n'
