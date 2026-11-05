#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - kernel acquisition (Phase 1.3, step 3)
# ==============================================================================
# Imports the locally built bubbleOS kernel (boot/vmlinuz-bubbleos and the
# sibling bubble-modules/ tree) into out/kernel/.
#
# A Debian package download remains available as a bootstrap fallback:
#   KERNEL_SOURCE=debian ./build/build-kernel.sh
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/out/kernel}"
KERNEL_RELEASE="${KERNEL_RELEASE:-7.2.12+deb14-amd64}"
DEBS="$OUT/debs"
EXTRACT="$OUT/root"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

KERNEL_SOURCE="${KERNEL_SOURCE:-auto}"
LOCAL_KERNEL_IMAGE="${LOCAL_KERNEL_IMAGE:-$ROOT/boot/vmlinuz-bubbleos}"
LOCAL_MODULE_ROOT="${LOCAL_MODULE_ROOT:-$ROOT/../bubble-modules}"

if [[ "$KERNEL_SOURCE" != "debian" ]]; then
    if [[ -f "$LOCAL_KERNEL_IMAGE" && -d "$LOCAL_MODULE_ROOT" ]]; then
        log "Local bubbleOS kernel detected; importing it"
        OUT="$OUT" KERNEL_IMAGE="$LOCAL_KERNEL_IMAGE" MODULE_ROOT="$LOCAL_MODULE_ROOT" \
            exec "$ROOT/build/import-kernel.sh"
    fi
    log "No local bubbleOS kernel found; falling back to the Debian bootstrap kernel"
fi

command -v apt-get >/dev/null 2>&1 || die "Missing required command: apt-get"
command -v dpkg-deb >/dev/null 2>&1 || die "Missing required command: dpkg-deb"
command -v depmod >/dev/null 2>&1 || die "Missing required command: depmod"

mkdir -p "$DEBS"

packages=(
    "linux-binary-${KERNEL_RELEASE}"
    "linux-modules-${KERNEL_RELEASE}"
)

shopt -s nullglob
for package in "${packages[@]}"; do
    files=("$DEBS/${package}"_*.deb)
    if (( ${#files[@]} == 0 )); then
        log "Downloading $package"
        ( cd "$DEBS" && apt-get download "$package" )
    else
        log "Using cached $package"
    fi
done

log "Extracting kernel packages"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
for deb in "$DEBS"/linux-{binary,modules}-"${KERNEL_RELEASE}"_*.deb; do
    dpkg-deb -x "$deb" "$EXTRACT"
done

VMLINUZ="$EXTRACT/usr/lib/modules/${KERNEL_RELEASE}/vmlinuz"
[[ -f "$VMLINUZ" ]] || VMLINUZ="$EXTRACT/boot/vmlinuz-${KERNEL_RELEASE}"
[[ -f "$VMLINUZ" ]] || die "Kernel image not found in the downloaded packages"

MODULE_ROOT="$EXTRACT/usr"
MODULE_DIR="$MODULE_ROOT/lib/modules/${KERNEL_RELEASE}"
[[ -d "$MODULE_DIR" ]] || die "Kernel modules not found: $MODULE_DIR"

if [[ ! -f "$MODULE_DIR/modules.dep" ]]; then
    log "Generating modules.dep"
    depmod -b "$MODULE_ROOT" "$KERNEL_RELEASE" >/dev/null 2>&1 || true
fi

vmlinuz_rel="${VMLINUZ#"$OUT"/}"
ln -sfn "$vmlinuz_rel" "$OUT/vmlinuz"
ln -sfn "usr/lib/modules/${KERNEL_RELEASE}" "$OUT/modules"

cat > "$OUT/kernel.env" <<ENV
KERNEL_RELEASE=$KERNEL_RELEASE
KERNEL_IMAGE=$OUT/vmlinuz
MODULE_ROOT=$MODULE_ROOT
MODULE_DIR=$MODULE_DIR
ENV

log "Kernel ready"
printf 'Kernel:     %s\n' "$OUT/vmlinuz"
printf 'Modules:    %s\n' "$MODULE_DIR"
printf 'Release:    %s\n' "$KERNEL_RELEASE"
printf '\nBuild the initramfs with:\n'
printf '  KERNEL_RELEASE=%s MODULE_ROOT=%s ./build/build-initramfs.sh\n' "$KERNEL_RELEASE" "$MODULE_ROOT"
