#!/usr/bin/env bash
# Exercise privileged Rust snapshot operations with isolated fake Btrfs tools.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd)"
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
(( EUID == 0 )) || {
    printf 'Run this test as root (CI uses sudo).\n' >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/generations/000001" "$TMP_DIR/rootfs" "$TMP_DIR/snapshots"
ln -s ../generations/000001 "$TMP_DIR/rootfs/current"

export BUBBLEOS_SNAPSHOTS_DIR="$TMP_DIR/snapshots"
export BUBBLEOS_GENERATIONS_DIR="$TMP_DIR/generations"
export BUBBLEOS_CURRENT_LINK="$TMP_DIR/rootfs/current"
export BUBBLEOS_PREVIOUS_LINK="$TMP_DIR/rootfs/previous"
export BUBBLEOS_ROOTFS_MOUNT="$TMP_DIR/rootfs"
export BUBBLEOS_TEST_BTRFS_LOG="$TMP_DIR/btrfs.log"
export PATH="$FAKE_BIN:$PATH"
export BUBBLEOS_RUST_PATHS_BIN="$BINARY"

cat > "$FAKE_BIN/mountpoint" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target=""
for argument in "$@"; do target="$argument"; done
[[ "$target" == "/var" || "$target" == "$BUBBLEOS_SNAPSHOTS_DIR" ]]
MOCK

cat > "$FAKE_BIN/btrfs" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$BUBBLEOS_TEST_BTRFS_LOG"
printf '\n' >> "$BUBBLEOS_TEST_BTRFS_LOG"
case "$1 $2" in
    "subvolume show")
        [[ "$3" == "/var" ]]
        ;;
    "subvolume snapshot")
        [[ "$3" == "-r" && $# -eq 5 ]]
        mkdir -p -- "$5"
        ;;
    "property get")
        [[ "$5" == "ro" ]]
        printf '%s\n' "$BUBBLEOS_TEST_RO"
        ;;
    *)
        printf 'Unexpected fake btrfs invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
MOCK
chmod 0755 "$FAKE_BIN/mountpoint" "$FAKE_BIN/btrfs"
export BUBBLEOS_TEST_RO=ro=true

# Load the production shell adapter: all three operations must delegate to Rust.
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/generation.sh"

ROOTFS_SNAPSHOT="$(bubble_snapshot_generation 000001 before-000002)"
[[ -d "$ROOTFS_SNAPSHOT" ]]
[[ "$ROOTFS_SNAPSHOT" == "$BUBBLEOS_SNAPSHOTS_DIR/rootfs/"* ]]

VAR_SNAPSHOT="$(bubble_snapshot_var before-000002)"
[[ -d "$VAR_SNAPSHOT" ]]
[[ "$VAR_SNAPSHOT" == "$BUBBLEOS_SNAPSHOTS_DIR/var/"* ]]

SNAPSHOT_NAME="$(basename -- "$VAR_SNAPSHOT")"
RESTORE_OUTPUT="$(bubble_var_restore_schedule "var/$SNAPSHOT_NAME")"
[[ "$RESTORE_OUTPUT" == *"scheduled for the next boot"* ]]
MARKER="$BUBBLEOS_SNAPSHOTS_DIR/var-restore.request"
[[ -f "$MARKER" ]]
grep -Fxq "SNAPSHOT=$SNAPSHOT_NAME" "$MARKER"
grep -Fxq "REQUESTED_FROM=000001" "$MARKER"
grep -Eq '^REQUESTED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$MARKER"
[[ "$(stat -c '%a' "$MARKER")" == "600" ]]
! find "$BUBBLEOS_SNAPSHOTS_DIR" -maxdepth 1 -name '.var-restore.request.*.tmp' -print -quit | grep -q .

if bubble_snapshot_generation 000001 '../escape' >/dev/null 2>&1; then
    printf 'Rust accepted an unsafe snapshot label\n' >&2
    exit 1
fi
if bubble_var_restore_schedule '../escape' >/dev/null 2>&1; then
    printf 'Rust accepted an unsafe restore snapshot name\n' >&2
    exit 1
fi
MARKER_BEFORE="$(sha256sum "$MARKER")"
export BUBBLEOS_TEST_RO=ro=false
if bubble_var_restore_schedule "$SNAPSHOT_NAME" >/dev/null 2>&1; then
    printf 'Rust accepted a writable restore point\n' >&2
    exit 1
fi
[[ "$(sha256sum "$MARKER")" == "$MARKER_BEFORE" ]]

grep -q 'subvolume snapshot -r' "$BUBBLEOS_TEST_BTRFS_LOG"
printf 'Rust snapshot operation bridge: OK\n'
