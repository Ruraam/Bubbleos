#!/usr/bin/env bash
# Compare Rust store inspection against the legacy Bash implementation.
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
command -v jq >/dev/null 2>&1 || {
    printf 'jq is required for the store parity test\n' >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
export BUBBLEOS_STATE_DIR="$TMP_DIR/state"
export BUBBLEOS_CACHE_DIR="$TMP_DIR/cache"
export BUBBLEOS_STORE_DIR="$TMP_DIR/store"
export BUBBLEOS_STORE_OBJECTS_DIR="$BUBBLEOS_STORE_DIR/objects"
export BUBBLEOS_STORE_PACKAGES_DIR="$BUBBLEOS_STORE_DIR/packages"
BUBBLEOS_RUST_PATHS_BIN="$TMP_DIR/not-installed"

# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/store.sh"

DIGEST_19="$(printf 'a%.0s' {1..64})"
DIGEST_110="$(printf 'b%.0s' {1..64})"
mkdir -p \
    "$BUBBLEOS_STORE_OBJECTS_DIR/$DIGEST_19/payload" \
    "$BUBBLEOS_STORE_OBJECTS_DIR/$DIGEST_110/payload" \
    "$BUBBLEOS_STORE_PACKAGES_DIR/demo"

printf '{"id":"demo","version":"1.9","kind":"system","name":"Demo 1.9"}\n' \
    > "$BUBBLEOS_STORE_OBJECTS_DIR/$DIGEST_19/manifest.json"
printf '{"id":"demo","version":"1.10","type":"system","name":"Demo 1.10"}\n' \
    > "$BUBBLEOS_STORE_OBJECTS_DIR/$DIGEST_110/manifest.json"
ln -s "../../objects/$DIGEST_19" "$BUBBLEOS_STORE_PACKAGES_DIR/demo/1.9"
ln -s "../../objects/$DIGEST_110" "$BUBBLEOS_STORE_PACKAGES_DIR/demo/1.10"

compare_output() {
    local description="$1" expected="$2" actual="$3"
    [[ "$expected" == "$actual" ]] || {
        printf '%s mismatch:\nBash: %s\nRust: %s\n' \
            "$description" "$expected" "$actual" >&2
        return 1
    }
}

compare_output "object directory" \
    "$(bubble_store_object_dir "$DIGEST_19")" \
    "$("$BINARY" store-object-dir "$DIGEST_19")"

compare_output "object manifest" \
    "$(bubble_store_object_manifest "$DIGEST_19")" \
    "$("$BINARY" store-object-manifest "$DIGEST_19")"

compare_output "latest package version" \
    "$(bubble_store_latest_version demo)" \
    "$("$BINARY" store-latest-version demo)"

compare_output "package info by explicit version" \
    "$(bubble_store_info_for_id demo=1.9)" \
    "$("$BINARY" store-info-id demo=1.9)"

compare_output "package info by latest version" \
    "$(bubble_store_info_for_id demo)" \
    "$("$BINARY" store-info-id demo)"

# A present but empty package directory returns a successful empty version.
mkdir -p "$BUBBLEOS_STORE_PACKAGES_DIR/empty"
compare_output "empty latest package version" \
    "$(bubble_store_latest_version empty)" \
    "$("$BINARY" store-latest-version empty)"

# Inspect a local LPK whose SHA-256 object has already been imported.
LPK="$TMP_DIR/local-package.lpk"
printf 'bubbleOS local LPK test payload\n' > "$LPK"
FILE_DIGEST="$(sha256sum -- "$LPK" | awk '{print $1}')"
mkdir -p "$BUBBLEOS_STORE_OBJECTS_DIR/$FILE_DIGEST/payload"
printf '{"id":"local-package","version":"2.0","type":"system","name":"Local package"}\n' \
    > "$BUBBLEOS_STORE_OBJECTS_DIR/$FILE_DIGEST/manifest.json"
compare_output "package info by local file" \
    "$(bubble_store_info_for_file "$LPK")" \
    "$("$BINARY" store-info-file "$LPK")"

# Both implementations must reject path-like selectors and invalid digests.
if bubble_store_object_dir ../outside >/dev/null 2>&1; then
    printf 'Bash accepted an invalid digest\n' >&2
    exit 1
fi
if "$BINARY" store-object-dir ../outside >/dev/null 2>&1; then
    printf 'Rust accepted an invalid digest\n' >&2
    exit 1
fi
if bubble_store_info_for_id ../outside >/dev/null 2>&1; then
    printf 'Bash accepted a traversal package ID\n' >&2
    exit 1
fi
if "$BINARY" store-info-id ../outside >/dev/null 2>&1; then
    printf 'Rust accepted a traversal package ID\n' >&2
    exit 1
fi

printf 'Rust package store parity: OK\n'
