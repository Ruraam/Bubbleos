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

bubble_require_root() {
    if (( EUID != 0 )); then
        printf 'bubble: this operation requires root privileges\n' >&2
        return 1
    fi
}

bubble_require_generation_layout() {
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
    mountpoint -q "$BUBBLEOS_SNAPSHOTS_DIR" || {
        printf 'bubble: %s is not mounted (is the @snapshots subvolume available?)\n' \
            "$BUBBLEOS_SNAPSHOTS_DIR" >&2
        return 1
    }
}

bubble_init_paths() {
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
