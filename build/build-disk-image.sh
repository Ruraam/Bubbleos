#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - bootable disk image builder (Phase 1.3, step 3)
# ==============================================================================
# Assembles a GPT disk with:
#   partition 1: FAT32 EFI System Partition (Limine + kernel + initramfs)
#   partition 2: Btrfs bubbleOS RootFS (@rootfs generation container)
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_IMAGE="${ROOT_IMAGE:-$ROOT/out/bubbleos-root.img}"
ESP_IMAGE="${ESP_IMAGE:-$ROOT/out/esp.img}"
DISK_IMAGE="${DISK_IMAGE:-$ROOT/out/bubbleos.img}"
ESP_SIZE="${ESP_SIZE:-128M}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT/out/kernel/vmlinuz}"
INITRAMFS="${INITRAMFS:-$ROOT/out/initramfs.cpio.gz}"
LIMINE_BOOTX64="${LIMINE_BOOTX64:-$ROOT/out/tools/limine-binary/BOOTX64.EFI}"
LIMINE_CONFIG="${LIMINE_CONFIG:-$ROOT/boot/limine.conf}"
CONFIG="${CONFIG:-$ROOT/config/rootfs.env}"
RENDERED_CONFIG="${RENDERED_CONFIG:-$ROOT/out/limine.conf}"
BUBBLE_LIB="${BUBBLE_LIB:-$ROOT/bubble/lib}"

# shellcheck disable=SC1091
source "$BUBBLE_LIB/bootloader.sh"

ESP_OFFSET_BYTES=$((1024 * 1024))
SECTOR_SIZE=512

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

for file in "$ROOT_IMAGE" "$KERNEL_IMAGE" "$INITRAMFS" "$LIMINE_BOOTX64" "$LIMINE_CONFIG" "$CONFIG"; do
    [[ -r "$file" ]] || die "Missing file: $file"
done
for command in sfdisk mkfs.vfat mmd mcopy truncate dd blkid; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
done

# shellcheck disable=SC1090
source "$CONFIG"
: "${ROOTFS_UUID:?ROOTFS_UUID must be set}"
: "${ROOTFS_PARTUUID:?ROOTFS_PARTUUID must be set}"
: "${ESP_UUID:?ESP_UUID must be set}"
: "${ESP_VOLUME_ID:?ESP_VOLUME_ID must be set}"
[[ "$ESP_VOLUME_ID" =~ ^[0-9A-Fa-f]{8}$ ]] ||
    die "ESP_VOLUME_ID must be eight hex digits (got: $ESP_VOLUME_ID)"

image_type="$(blkid -p -o value -s TYPE "$ROOT_IMAGE" 2>/dev/null || true)"
[[ "$image_type" == "btrfs" ]] ||
    die "RootFS image type '$image_type' does not match the expected Btrfs layout"

image_uuid="$(blkid -p -o value -s UUID "$ROOT_IMAGE" 2>/dev/null || true)"
[[ "$image_uuid" == "$ROOTFS_UUID" ]] ||
    die "RootFS image UUID '$image_uuid' does not match config ($ROOTFS_UUID)"

# The committed boot/limine.conf is the fallback template. Its base command
# line must match the renderer used by build/build-image.sh, otherwise the two
# code paths would diverge silently.
limine_cmdline="$(sed -n 's/^[[:space:]]*cmdline:[[:space:]]*//p' "$LIMINE_CONFIG" | head -n1)"
limine_cmdline="${limine_cmdline%% root=*}"
[[ "$limine_cmdline" == "$BUBBLEOS_LIMINE_CMDLINE" ]] ||
    die "Limine cmdline drift: template='$limine_cmdline' renderer='$BUBBLEOS_LIMINE_CMDLINE'"

mkdir -p "$(dirname -- "$RENDERED_CONFIG")"
if [[ -r "$RENDERED_CONFIG" ]] && grep -q "root=UUID=${ROOTFS_UUID}" "$RENDERED_CONFIG"; then
    log "Using the Limine menu rendered from the generation layout"
else
    log "Rendering fallback Limine configuration with root UUID $ROOTFS_UUID"
    sed -E "s|root=[^[:space:]]+|root=UUID=${ROOTFS_UUID}|" \
        "$LIMINE_CONFIG" > "$RENDERED_CONFIG"
fi
grep -q "root=UUID=${ROOTFS_UUID}" "$RENDERED_CONFIG" ||
    die "Limine configuration has no root= cmdline parameter"
grep -q '^default_entry: 1$' "$RENDERED_CONFIG" ||
    die "Limine configuration has no default_entry"

esp_bytes="$(numfmt --from=iec "$ESP_SIZE")"
root_bytes="$(stat -c %s "$ROOT_IMAGE")"
esp_sectors=$((esp_bytes / SECTOR_SIZE))
root_sectors=$((root_bytes / SECTOR_SIZE))
esp_start=$((ESP_OFFSET_BYTES / SECTOR_SIZE))
root_start=$((esp_start + esp_sectors))

if (( esp_bytes % SECTOR_SIZE != 0 || root_bytes % SECTOR_SIZE != 0 )); then
    die "ESP and RootFS sizes must be multiples of $SECTOR_SIZE bytes"
fi

log "Building EFI System Partition ($ESP_SIZE, UUID $ESP_UUID)"
rm -f "$ESP_IMAGE"
truncate -s "$esp_bytes" "$ESP_IMAGE"
mkfs.vfat -F 32 -i "$ESP_VOLUME_ID" -n BUBBLEOSESP "$ESP_IMAGE" >/dev/null
esp_image_uuid="$(blkid -p -o value -s UUID "$ESP_IMAGE" 2>/dev/null || true)"
[[ "$esp_image_uuid" == "$ESP_UUID" ]] ||
    die "ESP UUID '$esp_image_uuid' does not match config ($ESP_UUID)"
mmd -i "$ESP_IMAGE" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP_IMAGE" "$LIMINE_BOOTX64" ::/EFI/BOOT/BOOTX64.EFI
# Limine reads boot(): paths from the ESP root; the guest mounts the ESP at
# /boot, so these files appear as /boot/vmlinuz and /boot/initramfs.cpio.gz.
mcopy -i "$ESP_IMAGE" "$KERNEL_IMAGE" ::/vmlinuz
mcopy -i "$ESP_IMAGE" "$INITRAMFS" ::/initramfs.cpio.gz
mcopy -i "$ESP_IMAGE" "$RENDERED_CONFIG" ::/limine.conf
mcopy -i "$ESP_IMAGE" "$RENDERED_CONFIG" ::/EFI/BOOT/limine.conf

# Leave room for the backup GPT header and its partition array at the end.
disk_bytes=$(((root_start + root_sectors + 2048) * SECTOR_SIZE))
log "Assembling GPT disk image: $DISK_IMAGE"
rm -f "$DISK_IMAGE"
truncate -s "$disk_bytes" "$DISK_IMAGE"

sfdisk --quiet "$DISK_IMAGE" <<EOF
label: gpt
start=$esp_start, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="bubbleOS ESP"
start=$root_start, size=$root_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$ROOTFS_PARTUUID, name="bubbleOS Root"
EOF

dd if="$ESP_IMAGE" of="$DISK_IMAGE" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$ROOT_IMAGE" of="$DISK_IMAGE" bs="$SECTOR_SIZE" seek="$root_start" conv=notrunc,sparse status=none

log "Disk image created successfully"
printf '\nDisk:   %s (%s, apparent size)\n' "$DISK_IMAGE" "$(du -h --apparent-size "$DISK_IMAGE" | cut -f1)"
printf 'Boot it with: sudo DISK_IMAGE=%s ./build/run-qemu.sh\n' "$DISK_IMAGE"
printf '\nPartitions:\n'
sfdisk --quiet -l "$DISK_IMAGE"
