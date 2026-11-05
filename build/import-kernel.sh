#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - local kernel import
# ==============================================================================
# Imports a locally built bubbleOS kernel and its module tree into out/kernel.
# The build scripts expect the same layout as the legacy Debian download path:
#
#   out/kernel/vmlinuz
#   out/kernel/root/usr/lib/modules/<release>/
#   out/kernel/kernel.env
#
# Defaults:
#   KERNEL_IMAGE  = boot/vmlinuz-bubbleos
#   MODULE_ROOT   = ../bubble-modules  (sibling of the repository)
#
# The module root may point either to a directory containing lib/modules or
# directly to lib/modules.
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/out/kernel}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT/boot/vmlinuz-bubbleos}"
MODULE_ROOT="${MODULE_ROOT:-$ROOT/../bubble-modules}"
KERNEL_RELEASE="${KERNEL_RELEASE:-}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$KERNEL_IMAGE" ]] || die "Kernel image not found: $KERNEL_IMAGE"
command -v file >/dev/null 2>&1 || die "Missing required command: file"
command -v depmod >/dev/null 2>&1 || die "Missing required command: depmod"

# Accept both /path/bubble-modules and /path/bubble-modules/lib/modules.
if [[ -d "$MODULE_ROOT/lib/modules" ]]; then
    modules_parent="$MODULE_ROOT/lib/modules"
elif [[ -d "$MODULE_ROOT" && "$(basename -- "$MODULE_ROOT")" == "modules" ]]; then
    modules_parent="$MODULE_ROOT"
    MODULE_ROOT="$(dirname -- "$(dirname -- "$MODULE_ROOT")")"
else
    die "Kernel module root not found: $MODULE_ROOT"
fi

if [[ -z "$KERNEL_RELEASE" ]]; then
    mapfile -t releases < <(
        find "$modules_parent" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
    )
    (( ${#releases[@]} == 1 )) ||
        die "Cannot infer a single kernel release from $modules_parent; set KERNEL_RELEASE"
    KERNEL_RELEASE="${releases[0]}"
fi
MODULE_DIR="$modules_parent/$KERNEL_RELEASE"
[[ -d "$MODULE_DIR" ]] || die "Module directory not found: $MODULE_DIR"

image_info="$(file -b -- "$KERNEL_IMAGE")"
case "$image_info" in
    *"Linux kernel x86 boot executable"*|*bzImage*)
        ;;
    *)
        die "Not an x86 bzImage: $KERNEL_IMAGE ($image_info)"
        ;;
esac

version_hit="$(strings -a -- "$KERNEL_IMAGE" | grep -m1 -F -- "$KERNEL_RELEASE" || true)"
if [[ -z "$version_hit" ]]; then
    log "WARNING: kernel image does not advertise release $KERNEL_RELEASE"
fi

log "Importing kernel $KERNEL_RELEASE"
log "Image:   $KERNEL_IMAGE"
log "Modules: $MODULE_DIR"

# Boot-critical drivers must be either a module or built into the kernel.
missing=()
for driver in btrfs ext4 virtio_blk virtio_pci ata_piix ahci sd_mod autofs4; do
    if find "$MODULE_DIR" -type f -name "$driver.ko*" -print -quit | grep -q .; then
        continue
    fi
    if grep -qE "(^|/)$driver\.ko$" "$MODULE_DIR/modules.builtin" 2>/dev/null; then
        continue
    fi
    missing+=("$driver")
done
if (( ${#missing[@]} > 0 )); then
    die "Kernel $KERNEL_RELEASE lacks required storage drivers: ${missing[*]}"
fi

log "Preparing $OUT"
rm -rf -- "$OUT"
mkdir -p "$OUT/root/usr/lib/modules"

install -D -m 0644 -- "$KERNEL_IMAGE" "$OUT/vmlinuz"
cp -a --reflink=auto -- "$MODULE_DIR" "$OUT/root/usr/lib/modules/"
# Do not keep build-tree links that point at the host source checkout.
rm -f "$OUT/root/usr/lib/modules/$KERNEL_RELEASE/build" \
    "$OUT/root/usr/lib/modules/$KERNEL_RELEASE/source"

if [[ ! -f "$OUT/root/usr/lib/modules/$KERNEL_RELEASE/modules.dep" ]]; then
    log "Generating modules.dep"
    depmod -b "$OUT/root/usr" "$KERNEL_RELEASE" >/dev/null 2>&1 ||
        die "depmod failed for kernel $KERNEL_RELEASE"
fi

cat > "$OUT/kernel.env" <<ENV
KERNEL_RELEASE=$KERNEL_RELEASE
KERNEL_IMAGE=$OUT/vmlinuz
MODULE_ROOT=$OUT/root/usr
MODULE_DIR=$OUT/root/usr/lib/modules/$KERNEL_RELEASE
ENV

log "Kernel imported"
printf 'Kernel:     %s\n' "$OUT/vmlinuz"
printf 'Modules:    %s\n' "$OUT/root/usr/lib/modules/$KERNEL_RELEASE"
printf 'Release:    %s\n' "$KERNEL_RELEASE"
printf '\nBuild the initramfs with:\n'
printf '  ./build/build-initramfs.sh\n'
