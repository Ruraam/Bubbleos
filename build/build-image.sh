#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - RootFS disk image builder
# ==============================================================================
# Packs out/rootfs into a Btrfs image with the bubbleOS subvolume layout:
#
#   @rootfs/generations/000001   current system generation (writable)
#   @rootfs/current -> generations/000001
#   @home                        persistent user data
#   @var                         persistent system state
#   @logs                        persistent logs
#   @snapshots                   read-only restore points
#
# The image is exposed to QEMU as /dev/vda2 (UEFI) or /dev/vda (direct boot).
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$ROOT/out/rootfs}"
IMAGE="${IMAGE:-$ROOT/out/bubbleos-root.img}"
SIZE="${SIZE:-2G}"
CONFIG="${CONFIG:-$ROOT/config/rootfs.env}"
MOUNT_DIR="${MOUNT_DIR:-$ROOT/out/mnt-rootfs}"
GENERATION="${GENERATION:-000001}"
MOUNT_OPTIONS="${MOUNT_OPTIONS:-compress=zstd:1,noatime}"
LIMINE_RENDERED="${LIMINE_RENDERED:-$ROOT/out/limine.conf}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT/out/kernel/vmlinuz}"
INITRAMFS="${INITRAMFS:-$ROOT/out/initramfs.cpio.gz}"
BUBBLE_LIB="${BUBBLE_LIB:-$ROOT/bubble/lib}"

# shellcheck disable=SC1091
source "$BUBBLE_LIB/bootloader.sh"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -r "$CONFIG" ]] || die "Missing RootFS identity file: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"
: "${ROOTFS_LABEL:?ROOTFS_LABEL must be set}"
: "${ROOTFS_UUID:?ROOTFS_UUID must be set}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this build step as root (or via sudo)."
[[ -d "$ROOTFS" ]] || die "RootFS not found: $ROOTFS (run build/bootstrap.sh first)"
[[ "$GENERATION" =~ ^[0-9]{6}$ ]] || die "GENERATION must be six digits (got: $GENERATION)"
for file in "$KERNEL_IMAGE" "$INITRAMFS"; do
    [[ -r "$file" ]] || die "Missing boot asset: $file"
done

for command in mkfs.btrfs btrfs mount umount blkid truncate; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command (btrfs-progs)"
done

if [[ -e "$IMAGE" ]]; then
    if [[ "${FORCE:-0}" != "1" ]]; then
        die "Image already exists: $IMAGE (use FORCE=1 to replace it)"
    fi
    rm -f -- "$IMAGE"
fi

mkdir -p "$MOUNT_DIR"
if mountpoint -q "$MOUNT_DIR"; then
    die "Mount point is already in use: $MOUNT_DIR"
fi

mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        sync
        umount "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "Creating empty image: $IMAGE ($SIZE)"
truncate -s "$SIZE" "$IMAGE"

log "Creating Btrfs filesystem"
log "Label: $ROOTFS_LABEL, UUID: $ROOTFS_UUID, compression: zstd:1, checksums: crc32c"
mkfs.btrfs -q -f \
    -L "$ROOTFS_LABEL" \
    -U "$ROOTFS_UUID" \
    --csum crc32c \
    "$IMAGE"

log "Mounting image on $MOUNT_DIR"
mount -o "loop,${MOUNT_OPTIONS}" "$IMAGE" "$MOUNT_DIR"
mounted=1

create_subvolume() {
    local path="$1"
    install -d -m 0755 "$(dirname -- "$path")"
    btrfs subvolume create "$path" >/dev/null
}

log "Creating bubbleOS subvolume layout"
create_subvolume "$MOUNT_DIR/@rootfs"
install -d -m 0755 "$MOUNT_DIR/@rootfs/generations"
create_subvolume "$MOUNT_DIR/@rootfs/generations/$GENERATION"
create_subvolume "$MOUNT_DIR/@home"
create_subvolume "$MOUNT_DIR/@var"
create_subvolume "$MOUNT_DIR/@snapshots"
create_subvolume "$MOUNT_DIR/@logs"

generation_dir="$MOUNT_DIR/@rootfs/generations/$GENERATION"
log "Populating generation $GENERATION from $ROOTFS"
cp -a "$ROOTFS/." "$generation_dir/"

# /home, /var and /var/log are separate subvolumes. Seed them from the
# bootstrap RootFS so the first boot keeps the package and system state built
# at image creation time.
log "Seeding persistent subvolumes"
cp -a "$ROOTFS/home/." "$MOUNT_DIR/@home/"
cp -a "$ROOTFS/var/." "$MOUNT_DIR/@var/"
cp -a "$ROOTFS/var/log/." "$MOUNT_DIR/@logs/"
find "$MOUNT_DIR/@var/log" -mindepth 1 -delete 2>/dev/null || true

# The legacy metadata layout kept generation links under /var. Real
# generations now live in @rootfs, so drop any stale bootstrap copy.
rm -rf \
    "$generation_dir/var/lib/bubbleos/generations" \
    "$generation_dir/var/lib/bubbleos/current" \
    "$generation_dir/var/lib/bubbleos/previous" \
    "$MOUNT_DIR/@var/lib/bubbleos/generations" \
    "$MOUNT_DIR/@var/lib/bubbleos/current" \
    "$MOUNT_DIR/@var/lib/bubbleos/previous"

install -d -m 0755 \
    "$generation_dir/home" \
    "$generation_dir/var/log" \
    "$generation_dir/snapshots" \
    "$generation_dir/var/lib/bubbleos/rootfs" \
    "$MOUNT_DIR/@var/lib/bubbleos/rootfs"

log "Writing generation metadata"
cat > "$generation_dir/etc/bubbleos/generation" <<GENERATION_METADATA
GENERATION=$GENERATION
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DESCRIPTION=bubbleOS bootstrap generation
GENERATION_METADATA
chmod 0644 "$generation_dir/etc/bubbleos/generation"
chown root:root "$generation_dir/etc/bubbleos/generation"

# Each generation carries the kernel/initramfs it was built with, so booting
# an older generation keeps the matching userspace modules. The ESP receives
# copies only when a generation's assets differ from the current generation.
log "Installing per-generation boot assets in $BUBBLEOS_BOOT_ASSETS_DIR"
boot_assets_dir="$generation_dir$BUBBLEOS_BOOT_ASSETS_DIR"
install -d -m 0755 "$boot_assets_dir"
install -m 0644 "$KERNEL_IMAGE" "$boot_assets_dir/vmlinuz"
install -m 0644 "$INITRAMFS" "$boot_assets_dir/initramfs.cpio.gz"
chown root:root "$boot_assets_dir/vmlinuz" "$boot_assets_dir/initramfs.cpio.gz"

if grep -q '@ROOTFS_UUID@' "$generation_dir/etc/fstab"; then
    die "Unrendered @ROOTFS_UUID@ placeholder in $generation_dir/etc/fstab"
fi
if grep -q '@ESP_UUID@' "$generation_dir/etc/fstab"; then
    die "Unrendered @ESP_UUID@ placeholder in $generation_dir/etc/fstab"
fi
grep -q "UUID=$ROOTFS_UUID" "$generation_dir/etc/fstab" ||
    die "Generation fstab does not reference RootFS UUID $ROOTFS_UUID"

log "Selecting generation $GENERATION"
ln -s "generations/$GENERATION" "$MOUNT_DIR/@rootfs/current"

log "Rendering Limine boot menu"
mkdir -p "$(dirname -- "$LIMINE_RENDERED")"
rendered_tmp="$LIMINE_RENDERED.tmp"
bubble_bootloader_render_config \
    "$MOUNT_DIR/@rootfs/generations" "$ROOTFS_UUID" "$GENERATION" "" > "$rendered_tmp"
grep -q "root=UUID=$ROOTFS_UUID" "$rendered_tmp" ||
    die "Rendered Limine configuration has no root=UUID=$ROOTFS_UUID"
mv -f "$rendered_tmp" "$LIMINE_RENDERED"

log "Creating initial read-only restore points"
install -d -m 0755 "$MOUNT_DIR/@snapshots/rootfs" "$MOUNT_DIR/@snapshots/var"
btrfs subvolume snapshot -r \
    "$generation_dir" \
    "$MOUNT_DIR/@snapshots/rootfs/$GENERATION-initial" >/dev/null
btrfs subvolume snapshot -r \
    "$MOUNT_DIR/@var" \
    "$MOUNT_DIR/@snapshots/var/$GENERATION-initial" >/dev/null

btrfs filesystem sync "$MOUNT_DIR"
sync

log "Btrfs subvolumes:"
btrfs subvolume list "$MOUNT_DIR" | sed 's/^/  /'

umount "$MOUNT_DIR"
mounted=0

image_type="$(blkid -p -o value -s TYPE "$IMAGE" 2>/dev/null || true)"
image_uuid="$(blkid -p -o value -s UUID "$IMAGE" 2>/dev/null || true)"
[[ "$image_type" == "btrfs" ]] ||
    die "Image filesystem type is '$image_type', expected btrfs"
[[ "$image_uuid" == "$ROOTFS_UUID" ]] ||
    die "Image UUID '$image_uuid' does not match config ($ROOTFS_UUID)"

log "Image created successfully"
printf '\nImage: %s (%s, apparent size)\n' "$IMAGE" "$(du -h --apparent-size "$IMAGE" | cut -f1)"
printf 'Filesystem: btrfs, UUID %s\n' "$ROOTFS_UUID"
printf 'Generation: %s\n' "$GENERATION"
printf 'Boot it with: sudo ROOT_IMAGE=%s ./build/run-qemu.sh\n' "$IMAGE"
