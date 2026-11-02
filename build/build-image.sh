#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - RootFS disk image builder (Phase 1.3, step 2)
# ==============================================================================
# Packs out/rootfs into an ext4 image that QEMU exposes as /dev/vda.
# ==============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$ROOT/out/rootfs}"
IMAGE="${IMAGE:-$ROOT/out/bubbleos-root.img}"
SIZE="${SIZE:-2G}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this build step as root (or via sudo)."
[[ -d "$ROOTFS" ]] || die "RootFS not found: $ROOTFS (run build/bootstrap.sh first)"
command -v mke2fs >/dev/null 2>&1 || die "Missing required command: mke2fs (e2fsprogs)"

if [[ -e "$IMAGE" ]]; then
    if [[ "${FORCE:-0}" != "1" ]]; then
        die "Image already exists: $IMAGE (use FORCE=1 to replace it)"
    fi
    rm -f -- "$IMAGE"
fi

log "Creating empty image: $IMAGE ($SIZE)"
truncate -s "$SIZE" "$IMAGE"

log "Populating ext4 filesystem from $ROOTFS"
mke2fs -q -t ext4 -F -L bubbleos-root -d "$ROOTFS" "$IMAGE"

log "Image created successfully"
printf '\nImage: %s (%s)\n' "$IMAGE" "$(du -h --apparent-size "$IMAGE" | cut -f1)"
printf 'Boot it with: sudo ROOT_IMAGE=%s ./build/run-qemu.sh\n' "$IMAGE"
