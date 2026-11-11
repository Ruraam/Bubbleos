#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS system paths

: "${BUBBLEOS_NAME:=bubbleOS}"
: "${BUBBLEOS_VERSION:=0.0.1-dev}"
: "${BUBBLEOS_STATE_DIR:=/var/lib/bubbleos}"
: "${BUBBLEOS_CONFIG_DIR:=/etc/bubbleos}"
: "${BUBBLEOS_CACHE_DIR:=/var/cache/bubbleos}"
: "${BUBBLEOS_RUN_DIR:=/run/bubbleos}"
: "${BUBBLEOS_CHANNEL:=development}"
: "${BUBBLEOS_ULPM_DIR:=/opt/bubbleos/ulpm}"
: "${BUBBLEOS_RUST_PATHS_BIN:=/usr/lib/bubbleos/bin/bubble-paths}"
: "${BUBBLEOS_ULPM_CONFIG_DIR:=${BUBBLEOS_STATE_DIR}/ulpm}"
: "${BUBBLEOS_ULPM_CACHE_DIR:=${BUBBLEOS_CACHE_DIR}/ulpm}"
: "${BUBBLEOS_ROOTFS_MOUNT:=${BUBBLEOS_STATE_DIR}/rootfs}"
: "${BUBBLEOS_STORE_DIR:=${BUBBLEOS_STATE_DIR}/store}"
: "${BUBBLEOS_STORE_OBJECTS_DIR:=${BUBBLEOS_STORE_DIR}/objects}"
: "${BUBBLEOS_STORE_PACKAGES_DIR:=${BUBBLEOS_STORE_DIR}/packages}"
: "${BUBBLEOS_BOOT_ASSETS_DIR:=/usr/lib/bubbleos/boot}"
: "${BUBBLEOS_SNAPSHOTS_DIR:=/snapshots}"
: "${BUBBLEOS_GENERATIONS_DIR:=${BUBBLEOS_ROOTFS_MOUNT}/generations}"
: "${BUBBLEOS_CURRENT_LINK:=${BUBBLEOS_ROOTFS_MOUNT}/current}"
: "${BUBBLEOS_PREVIOUS_LINK:=${BUBBLEOS_ROOTFS_MOUNT}/previous}"

# Pass shell configuration explicitly: bubble.conf is sourced, not exported.
bubble_rust_paths() {
    env \
        BUBBLEOS_NAME="$BUBBLEOS_NAME" \
        BUBBLEOS_VERSION="$BUBBLEOS_VERSION" \
        BUBBLEOS_CHANNEL="$BUBBLEOS_CHANNEL" \
        BUBBLEOS_STATE_DIR="$BUBBLEOS_STATE_DIR" \
        BUBBLEOS_CONFIG_DIR="$BUBBLEOS_CONFIG_DIR" \
        BUBBLEOS_CACHE_DIR="$BUBBLEOS_CACHE_DIR" \
        BUBBLEOS_RUN_DIR="$BUBBLEOS_RUN_DIR" \
        BUBBLEOS_ULPM_DIR="$BUBBLEOS_ULPM_DIR" \
        BUBBLEOS_ULPM_CONFIG_DIR="$BUBBLEOS_ULPM_CONFIG_DIR" \
        BUBBLEOS_ULPM_CACHE_DIR="$BUBBLEOS_ULPM_CACHE_DIR" \
        BUBBLEOS_ROOTFS_MOUNT="$BUBBLEOS_ROOTFS_MOUNT" \
        BUBBLEOS_STORE_DIR="$BUBBLEOS_STORE_DIR" \
        BUBBLEOS_STORE_OBJECTS_DIR="$BUBBLEOS_STORE_OBJECTS_DIR" \
        BUBBLEOS_STORE_PACKAGES_DIR="$BUBBLEOS_STORE_PACKAGES_DIR" \
        BUBBLEOS_BOOT_ASSETS_DIR="$BUBBLEOS_BOOT_ASSETS_DIR" \
        BUBBLEOS_SNAPSHOTS_DIR="$BUBBLEOS_SNAPSHOTS_DIR" \
        BUBBLEOS_GENERATIONS_DIR="$BUBBLEOS_GENERATIONS_DIR" \
        BUBBLEOS_CURRENT_LINK="$BUBBLEOS_CURRENT_LINK" \
        BUBBLEOS_PREVIOUS_LINK="$BUBBLEOS_PREVIOUS_LINK" \
        BUBBLEOS_LIMINE_CMDLINE="${BUBBLEOS_LIMINE_CMDLINE:-console=ttyS0,115200 quiet selinux=0}" \
        BUBBLEOS_LIMINE_KERNEL="${BUBBLEOS_LIMINE_KERNEL:-boot():/vmlinuz}" \
        BUBBLEOS_LIMINE_INITRAMFS="${BUBBLEOS_LIMINE_INITRAMFS:-boot():/initramfs.cpio.gz}" \
        BUBBLEOS_LIMINE_TIMEOUT="${BUBBLEOS_LIMINE_TIMEOUT:-0}" \
        BUBBLEOS_ESP_GENERATIONS_DIR="${BUBBLEOS_ESP_GENERATIONS_DIR:-generations}" \
        "$BUBBLEOS_RUST_PATHS_BIN" "$@"
}

bubble_require_root() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths require-root
        return $?
    fi

    if (( EUID != 0 )); then
        printf 'bubble: this operation requires root privileges\n' >&2
        return 1
    fi
}

bubble_require_generation_layout() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths require-generation
        return $?
    fi

    command -v btrfs >/dev/null 2>&1 || {
        printf 'bubble: the btrfs command is unavailable (install btrfs-progs)\n' >&2
        return 1
    }
    mountpoint -q "$BUBBLEOS_ROOTFS_MOUNT" || {
        printf 'bubble: %s is not mounted (is the @rootfs subvolume available?)\n' \
            "$BUBBLEOS_ROOTFS_MOUNT" >&2
        return 1
    }
    [[ -d "$BUBBLEOS_GENERATIONS_DIR" ]] || {
        printf 'bubble: generation directory is missing: %s\n' \
            "$BUBBLEOS_GENERATIONS_DIR" >&2
        return 1
    }
}

bubble_require_snapshots_layout() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths require-snapshots
        return $?
    fi

    mountpoint -q "$BUBBLEOS_SNAPSHOTS_DIR" || {
        printf 'bubble: %s is not mounted (is the @snapshots subvolume available?)\n' \
            "$BUBBLEOS_SNAPSHOTS_DIR" >&2
        return 1
    }
}

bubble_init_paths() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths init
        return $?
    fi

    mkdir -p \
        "$BUBBLEOS_STATE_DIR" \
        "$BUBBLEOS_ROOTFS_MOUNT" \
        "${BUBBLEOS_STATE_DIR}/transactions" \
        "${BUBBLEOS_STATE_DIR}/store" \
        "${BUBBLEOS_STATE_DIR}/ulpm" \
        "${BUBBLEOS_STATE_DIR}/wal" \
        "$BUBBLEOS_CONFIG_DIR" \
        "$BUBBLEOS_CACHE_DIR" \
        "$BUBBLEOS_ULPM_CACHE_DIR" \
        "$BUBBLEOS_RUN_DIR"
}
