#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - bootable disk image builder (Phase 1.3, step 3)
# ==============================================================================
# Assembles a GPT disk with:
#   partition 1: FAT32 EFI System Partition (Limine + kernel + initramfs)
#   partition 2: ext4 bubbleOS RootFS
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

ESP_OFFSET_BYTES=$((1024 * 1024))
SECTOR_SIZE=512

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

for file in "$ROOT_IMAGE" "$KERNEL_IMAGE" "$INITRAMFS" "$LIMINE_BOOTX64" "$LIMINE_CONFIG"; do
    [[ -r "$file" ]] || die "Missing file: $file"
done
for command in sfdisk mkfs.vfat mmd mcopy truncate dd; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
done

esp_bytes="$(numfmt --from=iec "$ESP_SIZE")"
root_bytes="$(stat -c %s "$ROOT_IMAGE")"
esp_sectors=$((esp_bytes / SECTOR_SIZE))
root_sectors=$((root_bytes / SECTOR_SIZE))
esp_start=$((ESP_OFFSET_BYTES / SECTOR_SIZE))
root_start=$((esp_start + esp_sectors))

if (( esp_bytes % SECTOR_SIZE != 0 || root_bytes % SECTOR_SIZE != 0 )); then
    die "ESP and RootFS sizes must be multiples of $SECTOR_SIZE bytes"
fi

log "Building EFI System Partition ($ESP_SIZE)"
rm -f "$ESP_IMAGE"
truncate -s "$esp_bytes" "$ESP_IMAGE"
mkfs.vfat -F 32 -n BUBBLEOSESP "$ESP_IMAGE" >/dev/null
mmd -i "$ESP_IMAGE" ::/EFI ::/EFI/BOOT ::/boot
mcopy -i "$ESP_IMAGE" "$LIMINE_BOOTX64" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMAGE" "$KERNEL_IMAGE" ::/boot/vmlinuz
mcopy -i "$ESP_IMAGE" "$INITRAMFS" ::/boot/initramfs.cpio.gz
mcopy -i "$ESP_IMAGE" "$LIMINE_CONFIG" ::/limine.conf
mcopy -i "$ESP_IMAGE" "$LIMINE_CONFIG" ::/EFI/BOOT/limine.conf

# Leave room for the backup GPT header and its partition array at the end.
disk_bytes=$(((root_start + root_sectors + 2048) * SECTOR_SIZE))
log "Assembling GPT disk image: $DISK_IMAGE"
rm -f "$DISK_IMAGE"
truncate -s "$disk_bytes" "$DISK_IMAGE"

sfdisk --quiet "$DISK_IMAGE" <<EOF
label: gpt
start=$esp_start, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="bubbleOS ESP"
start=$root_start, size=$root_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="bubbleOS Root"
EOF

dd if="$ESP_IMAGE" of="$DISK_IMAGE" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$ROOT_IMAGE" of="$DISK_IMAGE" bs="$SECTOR_SIZE" seek="$root_start" conv=notrunc,sparse status=none

log "Disk image created successfully"
printf '\nDisk:   %s (%s, apparent size)\n' "$DISK_IMAGE" "$(du -h --apparent-size "$DISK_IMAGE" | cut -f1)"
printf 'Boot it with: sudo DISK_IMAGE=%s ./build/run-qemu.sh\n' "$DISK_IMAGE"
printf '\nPartitions:\n'
sfdisk --quiet -l "$DISK_IMAGE"
