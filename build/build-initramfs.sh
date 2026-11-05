#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - initramfs builder (Phase 1.3)
# ==============================================================================
# Builds a minimal BusyBox-based initramfs (cpio.gz). Storage modules needed to
# mount the RootFS are included when the host kernel provides them.
# ==============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/out}"
STAGE="${STAGE:-$OUT/initramfs}"
ARCHIVE="${ARCHIVE:-$OUT/initramfs.cpio.gz}"
BUSYBOX="${BUSYBOX:-/bin/busybox}"
KERNEL_ENV="${KERNEL_ENV:-$OUT/kernel/kernel.env}"
if [[ -z "${KERNEL_RELEASE:-}" && -r "$KERNEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$KERNEL_ENV"
fi
KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
MODULE_ROOT="${MODULE_ROOT:-/}"
MODULE_DIR="${MODULE_DIR:-${MODULE_ROOT%/}/lib/modules/${KERNEL_RELEASE}}"
MODULES="${MODULES:-btrfs ext4 virtio_blk ata_piix ahci sd_mod}"
MODPROBE="${MODPROBE:-/usr/sbin/modprobe}"
DEPMOD="${DEPMOD:-/usr/sbin/depmod}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$ROOT/../firmware}"
MICROCODE="${MICROCODE:-1}"
KERNEL_OUT="$STAGE/lib/modules/${KERNEL_RELEASE}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "$BUSYBOX" ]] || die "BusyBox not found: $BUSYBOX (install busybox-static)"
command -v cpio >/dev/null 2>&1 || die "Missing required command: cpio"
command -v gzip >/dev/null 2>&1 || die "Missing required command: gzip"
[[ -f "$ROOT/initramfs/init" ]] || die "Missing initramfs/init"

log "Staging initramfs in $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,sbin,etc,proc,sys,dev,tmp,run,root,newroot,mnt}

log "Installing BusyBox applets"
cp "$BUSYBOX" "$STAGE/bin/busybox"
while IFS= read -r applet; do
    [[ -n "$applet" && "$applet" != "busybox" ]] || continue
    ln -sf busybox "$STAGE/bin/$applet"
done < <("$BUSYBOX" --list)

log "Installing /init"
install -m 0755 "$ROOT/initramfs/init" "$STAGE/init"

printf 'bubbleOS initramfs\n' > "$STAGE/etc/bubbleos-release"
printf 'bubbleos\n' > "$STAGE/etc/hostname"
cat > "$STAGE/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
PASSWD
cat > "$STAGE/etc/group" <<'GROUP'
root:x:0:
GROUP

if [[ -d "$MODULE_DIR" && -x "$MODPROBE" ]]; then
    log "Installing storage modules for kernel $KERNEL_RELEASE"
    if [[ ! -f "$MODULE_DIR/modules.dep" && -x "$DEPMOD" && "$MODULE_ROOT" != "/" ]]; then
        log "Generating modules.dep in $MODULE_DIR"
        "$DEPMOD" -b "$MODULE_ROOT" "$KERNEL_RELEASE" >/dev/null 2>&1 || true
    fi

    for module in $MODULES; do
        while read -r action path _; do
            [[ "$action" == "insmod" ]] || continue
            rel="${path#"$MODULE_DIR"}"
            dest="$KERNEL_OUT$rel"
            install -d -m 0755 "$(dirname -- "$dest")"
            case "$path" in
                *.ko.xz)
                    command -v xz >/dev/null 2>&1 || die "Missing required command: xz"
                    xz -dc -- "$path" > "${dest%.xz}"
                    dest="${dest%.xz}"
                    ;;
                *.ko.zst)
                    command -v zstd >/dev/null 2>&1 || die "Missing required command: zstd"
                    zstd -dc -- "$path" > "${dest%.zst}"
                    dest="${dest%.zst}"
                    ;;
                *)
                    cp -- "$path" "$dest"
                    ;;
            esac
            chmod 0644 "$dest"
        done < <("$MODPROBE" -d "$MODULE_ROOT" -S "$KERNEL_RELEASE" --show-depends "$module" 2>/dev/null || true)
    done

    # BusyBox modprobe reads the text dependency and alias files. Decompressed
    # modules are referenced without their .xz/.zst suffix.
    install -d -m 0755 "$KERNEL_OUT"
    for metadata in modules.dep modules.alias modules.builtin; do
        [[ -f "$MODULE_DIR/$metadata" ]] || continue
        sed -e 's/\.ko\.xz/.ko/g' -e 's/\.ko\.zst/.ko/g' \
            "$MODULE_DIR/$metadata" > "$KERNEL_OUT/$metadata"
    done
else
    log "No kernel modules for $KERNEL_RELEASE, building initramfs without storage drivers"
fi

log "Creating $ARCHIVE"
( cd "$STAGE" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) > "$ARCHIVE"

# ------------------------------------------------------------------------------
# Early microcode
# ------------------------------------------------------------------------------
# The kernel reads an uncompressed cpio archive prepended to the initramfs and
# looks for kernel/x86/microcode/{GenuineIntel,AuthenticAMD}.bin. Concatenating
# the vendor files is the format documented by the kernel. The main initramfs
# stays compressed and follows the early archive.
if [[ "$MICROCODE" == "1" ]]; then
    amd_ucode_dir="$(find "$FIRMWARE_DIR" -type d -path '*/usr/lib/firmware/amd-ucode' -print -quit 2>/dev/null || true)"
    intel_ucode_dir="$(find "$FIRMWARE_DIR" -type d -path '*/usr/lib/firmware/intel-ucode' -print -quit 2>/dev/null || true)"
    amd_ucode_files=()
    intel_ucode_files=()
    if [[ -d "$amd_ucode_dir" ]]; then
        mapfile -d '' amd_ucode_files < <(
            find "$amd_ucode_dir" -maxdepth 1 -type f -name 'microcode_amd*.bin' -print0 | sort -z
        )
    fi
    if [[ -d "$intel_ucode_dir" ]]; then
        mapfile -d '' intel_ucode_files < <(
            find "$intel_ucode_dir" -maxdepth 1 -type f -print0 | sort -z
        )
    fi

    if (( ${#amd_ucode_files[@]} > 0 || ${#intel_ucode_files[@]} > 0 )); then
        log "Prepending early microcode (${#amd_ucode_files[@]} AMD, ${#intel_ucode_files[@]} Intel files)"
        ucode_stage="$(mktemp -d "${TMPDIR:-/tmp}/bubbleos-ucode.XXXXXXXX")"
        trap 'rm -rf -- "$ucode_stage"' EXIT
        install -d -m 0755 "$ucode_stage/kernel/x86/microcode"
        if (( ${#amd_ucode_files[@]} > 0 )); then
            cat -- "${amd_ucode_files[@]}" > "$ucode_stage/kernel/x86/microcode/AuthenticAMD.bin"
        fi
        if (( ${#intel_ucode_files[@]} > 0 )); then
            cat -- "${intel_ucode_files[@]}" > "$ucode_stage/kernel/x86/microcode/GenuineIntel.bin"
        fi
        ( cd "$ucode_stage" && find . -print0 |
            cpio --null -o --format=newc --owner 0:0 --quiet ) > "$OUT/microcode.cpio"
        cat -- "$OUT/microcode.cpio" "$ARCHIVE" > "$ARCHIVE.microcode"
        mv -- "$ARCHIVE.microcode" "$ARCHIVE"
        rm -f -- "$OUT/microcode.cpio"
        rm -rf -- "$ucode_stage"
        trap - EXIT
        log "Early microcode prepended"
    else
        log "No microcode files found in $FIRMWARE_DIR; skipping early microcode"
    fi
fi

log "Done"
printf 'Initramfs: %s (%s)\n' "$ARCHIVE" "$(du -h "$ARCHIVE" | cut -f1)"
