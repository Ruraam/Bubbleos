#!/usr/bin/env bash
# Compare the Rust repo helpers against the legacy Bash implementation.
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

BUBBLEOS_STATE_DIR="$TMP_DIR/state"
BUBBLEOS_CACHE_DIR="$TMP_DIR/cache"
BUBBLEOS_RUST_PATHS_BIN="$TMP_DIR/not-installed"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/repo.sh"

shell_compare_code() {
    local result=0
    bubble_version_compare "$1" "$2" || result=$?
    printf '%s' "$result"
}

shell_match_result() {
    if bubble_version_matches "$1" "$2"; then
        printf 'true'
    else
        printf 'false'
    fi
}

assert_compare_parity() {
    local left="$1" right="$2" expected actual
    expected="$(shell_compare_code "$left" "$right")"
    actual="$("$BINARY" version-compare "$left" "$right")"
    [[ "$actual" == "$expected" ]] || {
        printf 'version compare mismatch: %s vs %s (Bash=%s Rust=%s)\n' \
            "$left" "$right" "$expected" "$actual" >&2
        return 1
    }
}

assert_match_parity() {
    local version="$1" constraint="$2" expected actual
    expected="$(shell_match_result "$version" "$constraint")"
    actual="$("$BINARY" version-matches "$version" "$constraint")"
    [[ "$actual" == "$expected" ]] || {
        printf 'version match mismatch: %s against %s (Bash=%s Rust=%s)\n' \
            "$version" "$constraint" "$expected" "$actual" >&2
        return 1
    }
}

# Check normalized architecture names from the same kernel uname result.
shell_arch="$(bubble_arch)"
rust_arch="$("$BINARY" arch)"
[[ "$shell_arch" == "$rust_arch" ]] || {
    printf 'architecture mismatch: Bash=%s Rust=%s\n' "$shell_arch" "$rust_arch" >&2
    exit 1
}

versions=(
    "1.0 1.0"
    "1.2.10 1.2.9"
    "1.0-2 1.0-1"
    "1.0+git2 1.0+git1"
    "1.0~rc1 1.0"
    "2:1.0 1:1.0"
    "1.0-1 1.0-2"
    "1.01 1.1"
    "1.alpha 1.beta"
)
for pair in "${versions[@]}"; do
    read -r left right <<< "$pair"
    assert_compare_parity "$left" "$right"
done

constraints=(
    "1.2.0 =1.2.0"
    "1.2.0 ==1.2.0"
    "1.2.0 >=1.1.0"
    "1.2.0 <=1.2.0"
    "1.2.0 >1.1.0"
    "1.2.0 <1.3.0"
    "1.2.0 1.2.1"
    "1.2.0 all"
    "1.2.0 '*"
)
for pair in "${constraints[@]}"; do
    read -r version constraint <<< "$pair"
    constraint="${constraint#\\'}"
    assert_match_parity "$version" "$constraint"
done

# Test the dependency-free fallback explicitly. Only env remains in PATH, so
# neither side can accidentally use dpkg even on Debian/Ubuntu CI runners.
MINIMAL_PATH="$TMP_DIR/minimal-path"
mkdir -p "$MINIMAL_PATH"
ln -s "$(command -v env)" "$MINIMAL_PATH/env"
ORIGINAL_PATH="$PATH"
PATH="$MINIMAL_PATH"
export PATH
for pair in "${versions[@]}"; do
    read -r left right <<< "$pair"
    assert_compare_parity "$left" "$right"
done
for pair in "${constraints[@]}"; do
    read -r version constraint <<< "$pair"
    constraint="${constraint#\\'}"
    assert_match_parity "$version" "$constraint"
done
PATH="$ORIGINAL_PATH"
export PATH

printf 'Rust repository helper parity: OK\n'
