#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - QEMU launcher (Phase 1.3)
# ==============================================================================
# Direct kernel boot (ROOT_IMAGE) or firmware boot of the full disk image
# (DISK_IMAGE, UEFI/OVMF by default, legacy BIOS with UEFI=0).
# ==============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-$ROOT/config/rootfs.env}"
# shellcheck disable=SC1090
source "$CONFIG"
if [[ -z "${KERNEL:-}" && -r "$ROOT/out/kernel/vmlinuz" ]]; then
    KERNEL="$ROOT/out/kernel/vmlinuz"
fi
KERNEL="${KERNEL:-/boot/vmlinuz-$(uname -r)}"
INITRAMFS="${INITRAMFS:-$ROOT/out/initramfs.cpio.gz}"
ROOT_IMAGE="${ROOT_IMAGE:-}"
DISK_IMAGE="${DISK_IMAGE:-}"
ROOT_DEVICE="${ROOT_DEVICE:-UUID=$ROOTFS_UUID}"
UEFI="${UEFI:-1}"
MEMORY="${MEMORY:-2048}"
CPUS="${CPUS:-2}"
APPEND_EXTRA="${APPEND_EXTRA:-}"
# nographic (default) keeps the serial console in the terminal, which is what
# the automated suites expect.  Set QEMU_DISPLAY=gtk (or sdl) to open a window
# on the host and reach the Wayfire session running on VT7.
QEMU_DISPLAY="${QEMU_DISPLAY:-nographic}"

die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not installed"

cmd=(
    qemu-system-x86_64
    -m "$MEMORY"
    -smp "$CPUS"
    -no-reboot
    # Expose a virtio GPU so Wayfire has a real DRM output (Virtual-1) for
    # its GLES2 renderer and for screencopy; the serial console remains the
    # primary interface.
    -vga none
    -device virtio-gpu-pci
)

if [[ "$QEMU_DISPLAY" == "nographic" ]]; then
    cmd+=(-nographic)
else
    # Show the guest desktop in its own window while the kernel and systemd
    # logs stay in this terminal.  virtio input gives the session a keyboard
    # and an absolute pointer without relying on the PS/2 emulation.
    cmd+=(
        -display "$QEMU_DISPLAY"
        -serial mon:stdio
        -device virtio-keyboard-pci
        -device virtio-tablet-pci
    )
fi

if [[ -n "$DISK_IMAGE" ]]; then
    [[ -r "$DISK_IMAGE" ]] || die "Disk image not found: $DISK_IMAGE"
    [[ "$UEFI" == "0" || "$UEFI" == "1" ]] ||
        die "UEFI must be 0 (legacy BIOS) or 1 (UEFI/OVMF)"

    cmd+=(-machine q35)

    if [[ "$UEFI" == "1" ]]; then
        ovmf_code=""
        ovmf_vars_src=""
        for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
            [[ -r "$candidate" ]] && { ovmf_code="$candidate"; break; }
        done
        for candidate in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
            [[ -r "$candidate" ]] && { ovmf_vars_src="$candidate"; break; }
        done
        [[ -n "$ovmf_code" && -n "$ovmf_vars_src" ]] ||
            die "OVMF firmware not found (install the ovmf package)"

        ovmf_vars="$ROOT/out/OVMF_VARS.fd"
        [[ -f "$ovmf_vars" ]] || cp "$ovmf_vars_src" "$ovmf_vars"

        cmd+=(
            -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
            -drive "if=pflash,format=raw,file=$ovmf_vars"
        )
        printf '[bubbleOS] Firmware:  UEFI (%s)\n' "$(basename "$ovmf_code")"
    else
        printf '[bubbleOS] Firmware:  legacy BIOS (SeaBIOS)\n'
    fi

    cmd+=(-drive "file=$DISK_IMAGE,format=raw,if=virtio")
    printf '[bubbleOS] Disk:      %s\n' "$DISK_IMAGE"
else
    [[ -r "$KERNEL" ]] || die "Kernel not found: $KERNEL (set KERNEL=...)"
    [[ -r "$INITRAMFS" ]] || die "Initramfs not found: $INITRAMFS (run build/build-initramfs.sh first)"

    append="console=ttyS0,115200 selinux=0 rdinit=/init panic=1"
    [[ -z "$APPEND_EXTRA" ]] || append+=" $APPEND_EXTRA"
    cmd+=(
        -kernel "$KERNEL"
        -initrd "$INITRAMFS"
    )

    if [[ -n "$ROOT_IMAGE" ]]; then
        [[ -r "$ROOT_IMAGE" ]] || die "RootFS image not found: $ROOT_IMAGE"
        cmd+=(-drive "file=$ROOT_IMAGE,format=raw,if=virtio")
        append+=" root=$ROOT_DEVICE rootfstype=btrfs rw"
    fi

    cmd+=(-append "$append")
    printf '[bubbleOS] Kernel:    %s\n' "$KERNEL"
    printf '[bubbleOS] Initramfs: %s\n' "$INITRAMFS"
    if [[ -n "$ROOT_IMAGE" ]]; then
        printf '[bubbleOS] RootFS:    %s (%s)\n' "$ROOT_IMAGE" "$ROOT_DEVICE"
    fi
fi

if [[ -w /dev/kvm ]]; then
    cmd+=(-enable-kvm -cpu host)
else
    printf '[bubbleOS] /dev/kvm unavailable, running without hardware acceleration\n' >&2
fi

printf '[bubbleOS] Quit QEMU: Ctrl-A then X\n\n'

exec "${cmd[@]}" "$@"
