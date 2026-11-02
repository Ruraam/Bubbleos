#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - RootFS Bootstrap
# ==============================================================================
# Build-time bootstrap only. The base userspace is assembled from prebuilt
# packages, then stripped of its bootstrap identity and package manager. The
# resulting bubbleOS target must not expose APT as its package-management
# interface; ULPM/LPK will take over progressively.
# ==============================================================================
set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/out}"
ROOTFS="${ROOTFS:-$BUILD_DIR/rootfs}"
ARCH="${ARCH:-amd64}"
# Build-time implementation details: package source and suite used to assemble
# the initial userspace. They are never written to the target configuration.
SUITE="${SUITE:-stable}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
KEEP_APT="${KEEP_APT:-0}"
SYSTEMD="${SYSTEMD:-1}"
ROOT_PASSWORD="${ROOT_PASSWORD:-bubble}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this build step as root (or via sudo)."
[[ "$SYSTEMD" == "0" || "$SYSTEMD" == "1" ]] || die "SYSTEMD must be 0 or 1"
[[ "$SYSTEMD" == "0" || -n "$ROOT_PASSWORD" ]] || die "ROOT_PASSWORD must not be empty"
if [[ "$SYSTEMD" == "1" ]]; then
    INIT_NAME="systemd"
else
    INIT_NAME="development"
fi
need debootstrap
need install
need rm

mkdir -p "$BUILD_DIR"

if [[ -e "$ROOTFS" ]]; then
    if [[ "${FORCE:-0}" != "1" ]]; then
        die "RootFS already exists: $ROOTFS (use FORCE=1 to replace it)"
    fi
    log "Removing previous RootFS"
    rm -rf --one-file-system "$ROOTFS"
fi

log "Bootstrapping base userspace (build-time only)"
log "Suite=$SUITE Arch=$ARCH Init=$INIT_NAME"
bootstrap_args=(--arch="$ARCH" --variant=minbase)
if [[ "$SYSTEMD" == "1" ]]; then
    # One debootstrap argument: a comma-separated package list.
    # shellcheck disable=SC2054
    bootstrap_args+=(--include=systemd-sysv,udev,kmod,dbus,libpam-systemd)
fi
debootstrap "${bootstrap_args[@]}" "$SUITE" "$ROOTFS" "$MIRROR"

# systemctl and other maintainer tools expect /proc, /sys and /dev to be
# available inside the target chroot.
chroot_mounts=()
cleanup_chroot_mounts() {
    local mountpoint
    for mountpoint in "${chroot_mounts[@]}"; do
        umount "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null || true
    done
}
trap cleanup_chroot_mounts EXIT
for fs in proc sys dev; do
    mkdir -p "$ROOTFS/$fs"
    if ! mountpoint -q "$ROOTFS/$fs"; then
        mount --bind "/$fs" "$ROOTFS/$fs"
        chroot_mounts+=("$ROOTFS/$fs")
    fi
done

log "Creating bubbleOS filesystem layout"
install -d -m 0755 \
    "$ROOTFS/var/lib/bubbleos/store" \
    "$ROOTFS/var/lib/bubbleos/generations" \
    "$ROOTFS/var/lib/bubbleos/transactions" \
    "$ROOTFS/var/lib/bubbleos/wal" \
    "$ROOTFS/var/lib/bubbleos/cache" \
    "$ROOTFS/etc/bubbleos" \
    "$ROOTFS/opt/bubbleos"

log "Installing BubbleOS Core"
install -d -m 0755 "$ROOTFS/opt/bubbleos/bubble"
cp -a "$ROOT/bubble/." "$ROOTFS/opt/bubbleos/bubble/"
install -d -m 0755 "$ROOTFS/usr/local/bin"
ln -sf /opt/bubbleos/bubble/bin/bubble "$ROOTFS/usr/local/bin/bubble"

if [[ "$SYSTEMD" == "1" ]]; then
    log "Installing systemd configuration overlay"
    cp -a "$ROOT/rootfs/overlay/etc/." "$ROOTFS/etc/"
else
    log "Installing bubbleOS development init"
    install -D -m 0755 "$ROOT/rootfs/overlay/sbin/init" "$ROOTFS/sbin/init"
fi

log "Installing ULPM tree (development integration)"
cp -a "$ROOT/ulpm" "$ROOTFS/opt/bubbleos/ulpm"
if [[ -f "$ROOTFS/opt/bubbleos/ulpm/bin/ulpm" ]]; then
    ln -sf /opt/bubbleos/ulpm/bin/ulpm "$ROOTFS/usr/local/bin/ulpm"
fi
if [[ -f "$ROOTFS/opt/bubbleos/ulpm/bin/ulrm" ]]; then
    ln -sf /opt/bubbleos/ulpm/bin/ulrm "$ROOTFS/usr/local/bin/ulrm"
fi

log "Writing bubbleOS identity"
cat > "$ROOTFS/etc/os-release" <<'OS_RELEASE'
NAME="bubbleOS"
PRETTY_NAME="bubbleOS (development)"
ID=bubbleos
ID_LIKE=linux
VERSION_ID="0.0.1"
VERSION="0.0.1 (bootstrap)"
HOME_URL="https://github.com/Ruraam/bubbleOS"
OS_RELEASE

cat > "$ROOTFS/etc/hostname" <<'HOSTNAME'
bubbleos
HOSTNAME

cat > "$ROOTFS/etc/bubbleos/bubble.conf" <<CONF
BUBBLEOS_VERSION=0.0.1
BUBBLEOS_CHANNEL=development
BUBBLEOS_INIT=${INIT_NAME}
BUBBLEOS_PACKAGE_ENGINE=ULPM
BUBBLEOS_PACKAGE_FORMAT=LPK
CONF

log "Initializing bubbleOS state (generation 000001)"
chroot "$ROOTFS" /usr/local/bin/bubble bootstrap

if [[ "$SYSTEMD" == "1" ]]; then
    log "Enabling systemd services"
    chroot "$ROOTFS" systemctl enable bubbleos-boot.service
    chroot "$ROOTFS" systemctl enable getty@tty1.service
    chroot "$ROOTFS" systemctl enable serial-getty@ttyS0.service
    chroot "$ROOTFS" systemctl set-default multi-user.target

    log "Setting development root password"
    printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$ROOTFS" chpasswd

    log "Generating machine-id"
    if ! chroot "$ROOTFS" systemd-machine-id-setup >/dev/null 2>&1; then
        tr -d '-' < /proc/sys/kernel/random/uuid > "$ROOTFS/etc/machine-id"
    fi
fi

# ------------------------------------------------------------------------------
# bubbleOS identity
# ------------------------------------------------------------------------------
log "Removing bootstrap distribution identity"

# The base userspace is only a build-time bootstrap. Drop the distribution
# version file and origin metadata, then use the bubbleOS origin installed by
# the overlay.
rm -f "$ROOTFS/etc/debian_version"
rm -f "$ROOTFS/etc/dpkg/origins/debian"

# The dynamic MOTD helper prints the kernel build string; the static bubbleOS
# MOTD is used instead.
rm -rf "$ROOTFS/etc/update-motd.d"

# Rename distribution-named configuration files. Their content is generic;
# only the package-provided file names carry the bootstrap distribution name.
for base in \
    "$ROOTFS/etc" \
    "$ROOTFS/usr/lib/systemd" \
    "$ROOTFS/usr/lib/udev" \
    "$ROOTFS/usr/lib/tmpfiles.d" \
    "$ROOTFS/usr/lib/sysusers.d" \
    "$ROOTFS/usr/lib/sysctl.d"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' conf; do
        renamed="$(dirname -- "$conf")/$(basename -- "$conf" | sed 's/[Dd]ebian/bubbleos/g')"
        mv -- "$conf" "$renamed"
    done < <(find "$base" -type f -iname '*debian*' -print0 2>/dev/null)
done

# Drop distribution bug-tracker URLs before replacing the remaining names.
for conf in \
    "$ROOTFS/usr/lib/systemd/system/systemd-logind.service.d/dbus.conf" \
    "$ROOTFS/usr/lib/systemd/system/systemd-udevd.service.d/syscall-architecture.conf" \
    "$ROOTFS/usr/lib/udev/rules.d/80-bubbleos-compat.rules"; do
    [[ -f "$conf" ]] || continue
    sed -i '/bugs\.debian\.org/d' "$conf"
done

# Replace the remaining names in package-provided configuration comments.
for conf in \
    "$ROOTFS/etc/default/useradd" \
    "$ROOTFS/etc/login.defs" \
    "$ROOTFS/etc/pam.d/common-password" \
    "$ROOTFS/etc/security/limits.conf" \
    "$ROOTFS/etc/bash.bashrc" \
    "$ROOTFS/etc/skel/.bashrc" \
    "$ROOTFS/usr/share/base-files/dot.bashrc" \
    "$ROOTFS/usr/share/base-files/info.dir" \
    "$ROOTFS/usr/lib/systemd/system/rc-local.service.d/bubbleos.conf"; do
    [[ -f "$conf" ]] || continue
    sed -i \
        -e 's#/etc/debian_chroot#/etc/bubbleos_chroot#g' \
        -e 's/debian_chroot/bubbleos_chroot/g' \
        -e 's/Debian/bubbleOS/g' \
        -e 's/debian/bubbleos/g' \
        "$conf"
done

# Keep the yescrypt explanation readable after the generic replacement.
sed -i \
    -e 's/#hashed passwords using the yescrypt algorithm, introduced in bubbleOS/#hashed passwords using the yescrypt algorithm (the default)./' \
    -e 's/^#11\.  Without this option/# Without this option/' \
    -e 's/#between bubbleOS 11 and older releases replace/#between newer and older releases replace/' \
    "$ROOTFS/etc/pam.d/common-password"

sed -i \
    -e 's/in bubbleOS, entirely the/in the base system, entirely the/' \
    -e '/^# bubbleOS\.$/d' \
    "$ROOTFS/etc/login.defs"

if [[ -f "$ROOTFS/usr/lib/tmpfiles.d/bubbleos.conf" ]]; then
    sed -i \
        's/This file is part of the debianisation of systemd\./This file is part of the bubbleOS system configuration./' \
        "$ROOTFS/usr/lib/tmpfiles.d/bubbleos.conf"
fi

# systemd catalog support links point at the bootstrap distribution's tracker.
if [[ -d "$ROOTFS/usr/lib/systemd/catalog" ]]; then
    find "$ROOTFS/usr/lib/systemd/catalog" -type f -name '*.catalog' -print0 |
        xargs -0 -r sed -i \
            's#https://www.debian.org/support#https://github.com/Ruraam/bubbleOS/issues#g'
fi

cat > "$ROOTFS/usr/share/base-files/motd" <<'MOTD'

Welcome to bubbleOS.

The programs included with this system are free software; the exact
distribution terms are described in the individual files in
/usr/share/doc/*/copyright.

bubbleOS comes with ABSOLUTELY NO WARRANTY, to the extent permitted by
applicable law.
MOTD

# D-Bus is managed by systemd; the SysV compatibility script is not needed.
rm -f "$ROOTFS"/etc/rc[2-5].d/S01dbus "$ROOTFS/etc/init.d/dbus"

# ------------------------------------------------------------------------------
# Package manager
# ------------------------------------------------------------------------------
if [[ "$KEEP_APT" == "1" ]]; then
    log "Keeping APT in the target RootFS (KEEP_APT=1)"
else
    log "Removing APT from the target RootFS"

    # Remove APT and the packages that only exist to support it. Deriving the
    # names keeps this working when the bootstrap suite changes sonames.
    apt_purge=(apt)
    while IFS= read -r pkg; do
        [[ -n "$pkg" && "$pkg" != "apt" ]] || continue
        apt_purge+=("$pkg")
    done < <(
        chroot "$ROOTFS" dpkg-query -W -f='${Package}\n' 2>/dev/null |
            grep -E '^(libapt-pkg[0-9]+|sqv|debian-archive-keyring)$' || true
    )

    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y --allow-remove-essential "${apt_purge[@]}"

    # apt's postrm removes its state directories, but make the cleanup explicit
    # and drop units/cron jobs that could survive a partial purge.
    rm -rf \
        "$ROOTFS/etc/apt" \
        "$ROOTFS/var/lib/apt" \
        "$ROOTFS/var/cache/apt" \
        "$ROOTFS/var/log/apt"
    rm -f "$ROOTFS"/etc/systemd/system/timers.target.wants/apt-daily*.timer
    rm -f "$ROOTFS"/usr/lib/systemd/system/apt-daily*.service
    rm -f "$ROOTFS"/usr/lib/systemd/system/apt-daily*.timer
    rm -f "$ROOTFS/etc/cron.daily/apt-compat" "$ROOTFS/etc/logrotate.d/apt"

    if chroot "$ROOTFS" sh -c 'command -v apt-get >/dev/null 2>&1'; then
        die "APT is still present in the target RootFS"
    fi
fi

log "RootFS created successfully"
printf '\nRootFS: %s\n' "$ROOTFS"
printf 'Next phase: package the rootfs into an initramfs and boot it with a Linux kernel.\n'
