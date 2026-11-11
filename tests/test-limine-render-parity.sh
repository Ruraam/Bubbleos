#!/usr/bin/env bash
# Compare the legacy shell Limine renderer with the Rust implementation byte-for-byte.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_HELPER="${1:-$ROOT/target/debug/bubble-paths}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

[[ -x "$RUST_HELPER" ]] || {
    printf 'Limine parity: Rust helper is not executable: %s\n' "$RUST_HELPER" >&2
    exit 1
}

GENERATIONS="$TMP_DIR/generations"
mkdir -p "$GENERATIONS"

write_generation() {
    local generation="$1" description="$2"
    mkdir -p "$GENERATIONS/$generation/etc/bubbleos"
    printf 'GENERATION=%s\nDESCRIPTION=%s\n' "$generation" "$description" \
        > "$GENERATIONS/$generation/etc/bubbleos/generation"
}

write_generation 000010 "Current kernel"
write_generation 000009 "Shared kernel"
mkdir -p "$GENERATIONS/000002/etc/bubbleos"
printf 'GENERATION=000002\nDESCRIPTION=Old/system\rrevision\n' \
    > "$GENERATIONS/000002/etc/bubbleos/generation"

for generation in 000010 000009; do
    assets="$GENERATIONS/$generation/usr/lib/bubbleos/boot"
    mkdir -p "$assets"
    printf 'shared-kernel-image\n' > "$assets/vmlinuz"
    printf 'shared-initramfs-image\n' > "$assets/initramfs.cpio.gz"
done

assets="$GENERATIONS/000002/usr/lib/bubbleos/boot"
mkdir -p "$assets"
printf 'older-kernel-image\n' > "$assets/vmlinuz"
printf 'older-initramfs-image\n' > "$assets/initramfs.cpio.gz"

# Deliberately non-exported shell variables: the Rust adapter must receive
# these sourced configuration values explicitly.
BUBBLEOS_RUST_PATHS_BIN="$TMP_DIR/no-rust-helper"
BUBBLEOS_BOOT_ASSETS_DIR="/usr/lib/bubbleos/boot"
BUBBLEOS_LIMINE_CMDLINE="console=ttyS1,9600 quiet test-mode=1"
BUBBLEOS_LIMINE_KERNEL="boot():/custom-vmlinuz"
BUBBLEOS_LIMINE_INITRAMFS="boot():/custom-initramfs.cpio.gz"
BUBBLEOS_LIMINE_TIMEOUT="5"
BUBBLEOS_ESP_GENERATIONS_DIR="custom-generations"

# shellcheck disable=SC1091
source "$ROOT/bubble/lib/paths.sh"
# shellcheck disable=SC1091
source "$ROOT/bubble/lib/bootloader.sh"

EXPECTED="$TMP_DIR/limine-shell.conf"
ACTUAL="$TMP_DIR/limine-rust.conf"
bubble_bootloader_render_config "$GENERATIONS" "uuid-parity-test" \
    "000010" "000002" > "$EXPECTED"

BUBBLEOS_RUST_PATHS_BIN="$RUST_HELPER"
bubble_bootloader_render_config "$GENERATIONS" "uuid-parity-test" \
    "000010" "000002" > "$ACTUAL"

if ! cmp -s -- "$EXPECTED" "$ACTUAL"; then
    printf 'Limine renderer parity: FAILED (shell and Rust outputs differ)\n' >&2
    diff -u -- "$EXPECTED" "$ACTUAL" >&2 || true
    exit 1
fi

printf 'Limine renderer parity: OK\n'
