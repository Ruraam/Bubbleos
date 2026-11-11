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
CONFIG="${CONFIG:-$ROOT/config/rootfs.env}"
[[ -r "$CONFIG" ]] || {
    printf '[bubbleOS] ERROR: missing RootFS identity file: %s\n' "$CONFIG" >&2
    exit 1
}
# shellcheck disable=SC1090
source "$CONFIG"
: "${ROOTFS_UUID:?ROOTFS_UUID must be set}"
: "${ESP_UUID:?ESP_UUID must be set}"
# Build-time implementation details: package source and suite used to assemble
# the initial userspace. They are never written to the target configuration.
SUITE="${SUITE:-stable}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
# NVK only recognises Pascal (GP107) starting with Mesa 25.1, while Debian 13
# ships Mesa 25.0.  Pull just the Vulkan drivers from the matching backports
# suite; the GL/EGL stack stays on the stable suite.  Set to "none" to skip.
MESA_VULKAN_SUITE="${MESA_VULKAN_SUITE:-auto}"
KEEP_APT="${KEEP_APT:-0}"
SYSTEMD="${SYSTEMD:-1}"
ROOT_PASSWORD="${ROOT_PASSWORD:-bubble}"
# Desktop integration ---------------------------------------------------------
# DESKTOP=1 installs the Wayfire session, graphical greeter and companion
# applications, creates a normal desktop user, and boots to graphical.target.
# Set DESKTOP=0 for the previous console-only image.
DESKTOP="${DESKTOP:-1}"
DESKTOP_USER="${DESKTOP_USER:-bubble}"
DESKTOP_USER_PASSWORD="${DESKTOP_USER_PASSWORD:-bubble}"
DESKTOP_USER_GROUPS="${DESKTOP_USER_GROUPS:-audio video input render lp plugdev sudo bluetooth}"
DESKTOP_PACKAGES="${DESKTOP_PACKAGES:-wayfire wayfire-plugin-winshadows wstroke waybar fuzzel mako-notifier swaybg foot swaylock swayidle greetd tuigreet xdg-desktop-portal xdg-desktop-portal-wlr xdg-utils xwayland network-manager wpasupplicant wireless-regdb polkitd pkexec sudo bluez dbus-user-session libspdlog1.15 rfkill pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth pavucontrol fonts-inter fonts-jetbrains-mono fonts-noto-color-emoji fonts-font-awesome hicolor-icon-theme papirus-icon-theme bibata-cursor-theme gnome-themes-extra adwaita-icon-theme libgl1-mesa-dri mesa-utils mesa-vulkan-drivers vulkan-tools desktop-file-utils shared-mime-info xdg-user-dirs brightnessctl playerctl libnotify-bin wl-clipboard grim slurp wcm wlopm wlr-randr kanshi upower lxpolkit nm-connection-editor usbutils pciutils evtest joystick libsdl2-2.0-0 libsdl3-0 libsdl2-tests}"
# bubble-settings is a native GTK3 control center built inside the target
# chroot before APT is removed. BUILD_SETTINGS follows DESKTOP by default.
BUILD_SETTINGS="${BUILD_SETTINGS:-$DESKTOP}"
# Compile the dependency-free Rust core for the target RootFS.
BUILD_RUST_CORE="${BUILD_RUST_CORE:-1}"
KERNEL_ENV="${KERNEL_ENV:-$BUILD_DIR/kernel/kernel.env}"
if [[ -r "$KERNEL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$KERNEL_ENV"
fi
KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
KERNEL_MODULE_DIR="${KERNEL_MODULE_DIR:-${MODULE_DIR:-$BUILD_DIR/kernel/root/usr/lib/modules/$KERNEL_RELEASE}}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$ROOT/../firmware}"
HARDWARE_USERSPACE="${HARDWARE_USERSPACE:-1}"
HARDWARE_PACKAGES="${HARDWARE_PACKAGES:-bolt libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2 libtypec0 libusb3380-0t64 libwacom9 libwacom-common libva2 intel-media-va-driver}"
# ULPM runtime and LPK packaging tools (engine modules are installed from the
# vendored ulpm/ tree below). Kept as a variable so a leaner image can override
# the list at build time.
ULPM_PACKAGES="${ULPM_PACKAGES:-bubblewrap squashfs-tools squashfuse fuse-overlayfs fuse3 jq curl xdg-dbus-proxy file binutils diffutils ca-certificates}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this build step as root (or via sudo)."
[[ "$SYSTEMD" == "0" || "$SYSTEMD" == "1" ]] || die "SYSTEMD must be 0 or 1"
[[ "$SYSTEMD" == "0" || -n "$ROOT_PASSWORD" ]] || die "ROOT_PASSWORD must not be empty"
[[ "$DESKTOP" == "0" || "$DESKTOP" == "1" ]] || die "DESKTOP must be 0 or 1"
[[ "$BUILD_SETTINGS" == "0" || "$BUILD_SETTINGS" == "1" ]] ||
    die "BUILD_SETTINGS must be 0 or 1"
[[ "$BUILD_RUST_CORE" == "0" || "$BUILD_RUST_CORE" == "1" ]] ||
    die "BUILD_RUST_CORE must be 0 or 1"
[[ "$BUILD_SETTINGS" == "0" || "$DESKTOP" == "1" ]] ||
    die "BUILD_SETTINGS=1 requires DESKTOP=1"
[[ "$HARDWARE_USERSPACE" == "0" || "$HARDWARE_USERSPACE" == "1" ]] ||
    die "HARDWARE_USERSPACE must be 0 or 1"
[[ "$DESKTOP" == "0" || "$SYSTEMD" == "1" ]] ||
    die "DESKTOP=1 requires SYSTEMD=1"
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
# htop is the lightweight task manager for the serial console and tty1, so it
# is part of the base system and stays available with DESKTOP=0.
include_pkgs=(btrfs-progs htop)
if [[ "$SYSTEMD" == "1" ]]; then
    # One debootstrap argument: a comma-separated package list.
    include_pkgs+=(systemd-sysv udev kmod dbus libpam-systemd)
fi
read -r -a ulpm_pkgs <<< "$ULPM_PACKAGES"
include_pkgs+=("${ulpm_pkgs[@]}")
if [[ "$HARDWARE_USERSPACE" == "1" ]]; then
    # Hardware userspace (Thunderbolt, DRM, Wacom, VA-API) comes from the
    # target suite.  Copying it from the external firmware drop is unsafe:
    # that drop is extracted from a newer Debian and would replace the
    # suite's glib/systemd/drm libraries with ABI-incompatible builds.
    read -r -a hardware_pkgs <<< "$HARDWARE_PACKAGES"
    include_pkgs+=("${hardware_pkgs[@]}")
fi
if [[ "$DESKTOP" == "1" ]]; then
    read -r -a desktop_pkgs <<< "$DESKTOP_PACKAGES"
    include_pkgs+=("${desktop_pkgs[@]}")
fi
bootstrap_args+=(--include="$(IFS=,; echo "${include_pkgs[*]}")")
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

# ------------------------------------------------------------------------------
# Mesa Vulkan drivers (NVK)
# ------------------------------------------------------------------------------
# Debian 13 ships Mesa 25.0, whose NVK does not know about Pascal (GP107).
# NVK gained Maxwell/Pascal/Volta support in Mesa 25.1, so install only
# mesa-vulkan-drivers from trixie-backports and pin it there.  Dependencies
# are satisfied by the stable suite, so the GL/EGL stack is not upgraded.
if [[ "$MESA_VULKAN_SUITE" == "auto" ]]; then
    case "$SUITE" in
        stable|trixie)
            debian_codename="$(chroot "$ROOTFS" sh -c \
                '. /etc/os-release; printf %s "${VERSION_CODENAME:-}"')"
            [[ -n "$debian_codename" ]] ||
                die "cannot determine the Debian codename"
            MESA_VULKAN_SUITE="${debian_codename}-backports"
            ;;
        *)
            MESA_VULKAN_SUITE="none"
            ;;
    esac
fi
if [[ "$MESA_VULKAN_SUITE" != "none" ]]; then
    log "Installing mesa-vulkan-drivers from $MESA_VULKAN_SUITE"
    install -d -m 0755 \
        "$ROOTFS/etc/apt/sources.list.d" \
        "$ROOTFS/etc/apt/preferences.d"
    printf 'deb %s %s main\n' "$MIRROR" "$MESA_VULKAN_SUITE" \
        > "$ROOTFS/etc/apt/sources.list.d/bubbleos-backports.list"
    cat > "$ROOTFS/etc/apt/preferences.d/bubbleos-mesa-vulkan" <<EOF
Package: mesa-vulkan-drivers
Pin: release l=Debian Backports
Pin-Priority: 990
EOF
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get update -qq
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers
    rm -f "$ROOTFS/etc/apt/sources.list.d/bubbleos-backports.list" \
        "$ROOTFS/etc/apt/preferences.d/bubbleos-mesa-vulkan"
    mesa_version="$(chroot "$ROOTFS" \
        dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"
    chroot "$ROOTFS" dpkg --compare-versions "$mesa_version" ge "25.1" ||
        die "Mesa $mesa_version is too old for NVK on Pascal (need >= 25.1)"
    log "Mesa Vulkan drivers: $mesa_version"
fi

log "Creating bubbleOS filesystem layout"
install -d -m 0755 \
    "$ROOTFS/var/lib/bubbleos/store" \
    "$ROOTFS/var/lib/bubbleos/rootfs" \
    "$ROOTFS/var/lib/bubbleos/transactions" \
    "$ROOTFS/var/lib/bubbleos/wal" \
    "$ROOTFS/var/lib/bubbleos/cache" \
    "$ROOTFS/snapshots" \
    "$ROOTFS/etc/bubbleos" \
    "$ROOTFS/opt/bubbleos"

log "Installing BubbleOS Core"
install -d -m 0755 "$ROOTFS/opt/bubbleos/bubble"
cp -a "$ROOT/bubble/." "$ROOTFS/opt/bubbleos/bubble/"
install -d -m 0755 "$ROOTFS/usr/local/bin"
ln -sf /opt/bubbleos/bubble/bin/bubble "$ROOTFS/usr/local/bin/bubble"

log "Installing bubbleOS configuration overlay"
cp -a "$ROOT/rootfs/overlay/etc/." "$ROOTFS/etc/"
cp -a "$ROOT/rootfs/overlay/usr/." "$ROOTFS/usr/"

# Root uses the same themed htop defaults as users created from /etc/skel.
if [[ -f "$ROOTFS/etc/skel/.config/htop/htoprc" ]]; then
    install -D -m 0644 "$ROOTFS/etc/skel/.config/htop/htoprc" \
        "$ROOTFS/root/.config/htop/htoprc"
fi

# The fstab template carries the RootFS and ESP UUIDs as placeholders so the
# boot subvolume and bootloader mounts cannot drift from config/rootfs.env.
sed -i "s|@ROOTFS_UUID@|${ROOTFS_UUID}|g" "$ROOTFS/etc/fstab"
sed -i "s|@ESP_UUID@|${ESP_UUID}|g" "$ROOTFS/etc/fstab"
grep -q '@ROOTFS_UUID@' "$ROOTFS/etc/fstab" &&
    die "Unrendered @ROOTFS_UUID@ placeholder in $ROOTFS/etc/fstab"
grep -q '@ESP_UUID@' "$ROOTFS/etc/fstab" &&
    die "Unrendered @ESP_UUID@ placeholder in $ROOTFS/etc/fstab"
grep -q "UUID=$ROOTFS_UUID" "$ROOTFS/etc/fstab" ||
    die "fstab does not reference RootFS UUID $ROOTFS_UUID"
grep -q "UUID=${ESP_UUID}[[:space:]]*/boot" "$ROOTFS/etc/fstab" ||
    die "fstab does not mount the ESP ($ESP_UUID) on /boot"

if [[ "$SYSTEMD" != "1" ]]; then
    log "Installing bubbleOS development init"
    install -D -m 0755 "$ROOT/rootfs/overlay/sbin/init" "$ROOTFS/sbin/init"
fi

# The overlay is stored in the source tree; system files must be root-owned.
chown root:root \
    "$ROOTFS/etc/fstab" \
    "$ROOTFS/etc/hosts" \
    "$ROOTFS/etc/issue" \
    "$ROOTFS/etc/issue.net" \
    "$ROOTFS/etc/motd" \
    "$ROOTFS/etc/systemd/system/bubbleos-boot.service" \
    "$ROOTFS/etc/systemd/system/bubbleos-var-restore.service"
chmod 0644 \
    "$ROOTFS/etc/fstab" \
    "$ROOTFS/etc/hosts" \
    "$ROOTFS/etc/issue" \
    "$ROOTFS/etc/issue.net" \
    "$ROOTFS/etc/motd" \
    "$ROOTFS/etc/systemd/system/bubbleos-boot.service" \
    "$ROOTFS/etc/systemd/system/bubbleos-var-restore.service"
chown -R root:root "$ROOTFS/etc/dpkg/origins"
chmod 0755 "$ROOTFS/etc/dpkg/origins"
chmod 0644 "$ROOTFS/etc/dpkg/origins/bubbleos"

# Desktop configuration, fonts and session files come from the same overlay.
chown -R root:root \
    "$ROOTFS/etc/bubbleos" \
    "$ROOTFS/etc/environment.d" \
    "$ROOTFS/etc/greetd" \
    "$ROOTFS/etc/gtk-2.0" \
    "$ROOTFS/etc/gtk-3.0" \
    "$ROOTFS/etc/gtk-4.0" \
    "$ROOTFS/etc/pam.d" \
    "$ROOTFS/etc/swaylock" \
    "$ROOTFS/etc/xdg" \
    "$ROOTFS/usr/local/bin/bubble-desktop" \
    "$ROOTFS/usr/share/backgrounds/bubbleos" \
    "$ROOTFS/usr/share/bubbleos" \
    "$ROOTFS/usr/share/fonts/truetype/orbitron" \
    "$ROOTFS/usr/share/wayland-sessions" \
    "$ROOTFS/usr/lib/udev/rules.d/60-uinput.rules"
chmod 0755 "$ROOTFS/usr/local/bin/bubble-desktop"
chmod -R go-w \
    "$ROOTFS/etc/bubbleos" \
    "$ROOTFS/etc/environment.d" \
    "$ROOTFS/etc/greetd" \
    "$ROOTFS/etc/gtk-2.0" \
    "$ROOTFS/etc/gtk-3.0" \
    "$ROOTFS/etc/gtk-4.0" \
    "$ROOTFS/etc/pam.d" \
    "$ROOTFS/etc/swaylock" \
    "$ROOTFS/etc/xdg" \
    "$ROOTFS/usr/share/bubbleos" \
    "$ROOTFS/usr/share/fonts/truetype/orbitron" \
    "$ROOTFS/usr/lib/udev/rules.d/60-uinput.rules"
find "$ROOTFS/usr/share/backgrounds/bubbleos" -type f -exec chmod 0644 {} +
find "$ROOTFS/usr/share/bubbleos" -type f -exec chmod 0644 {} +
find "$ROOTFS/usr/share/fonts/truetype/orbitron" -type f -exec chmod 0644 {} +
find "$ROOTFS/usr/share/wayland-sessions" -type f -exec chmod 0644 {} +

# ------------------------------------------------------------------------------
# bubble-core (Rust system path helper)
# ------------------------------------------------------------------------------
# Build on the target RootFS, not on the host. This keeps the binary compatible
# with the target architecture and glibc. Cargo and rustc are temporary
# build-dependencies and are removed before APT itself is purged.
if [[ "$BUILD_RUST_CORE" == "1" ]]; then
    log "Building bubble-paths in the target RootFS"
    rust_src="$ROOTFS/usr/src/bubbleos/rust"
    install -d -m 0755 "$rust_src"
    cp -a "$ROOT/Cargo.toml" "$ROOT/crates" "$rust_src/"
    if [[ -f "$ROOT/Cargo.lock" ]]; then
        cp -a "$ROOT/Cargo.lock" "$rust_src/Cargo.lock"
    fi
    rm -rf "$rust_src/target"
    chown -R root:root "$rust_src"

    chroot "$ROOTFS" sh -c \
        'apt-mark showauto 2>/dev/null | xargs -r apt-mark manual >/dev/null 2>&1 || true'
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get update -qq
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends rustc cargo

    chroot "$ROOTFS" cargo build --offline --release \
        --manifest-path /usr/src/bubbleos/rust/Cargo.toml \
        --bin bubble-paths

    install -d -m 0755 "$ROOTFS/usr/lib/bubbleos/bin"
    install -m 0755 \
        "$rust_src/target/release/bubble-paths" \
        "$ROOTFS/usr/lib/bubbleos/bin/bubble-paths"
    rm -rf "$rust_src"

    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y -qq rustc cargo
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get autoremove -y -qq --purge

    if chroot "$ROOTFS" sh -c \
        'command -v rustc >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1'; then
        die "the Rust build toolchain is still present in the target RootFS"
    fi
    chroot "$ROOTFS" /usr/lib/bubbleos/bin/bubble-paths require-root ||
        die "the installed bubble-paths binary cannot run in the target RootFS"
    log "bubble-paths installed (Rust toolchain removed)"
fi

# ------------------------------------------------------------------------------
# bubble-settings (native GTK3 control center)
# ------------------------------------------------------------------------------
# The target has no compiler and APT is removed at the end of this script, so
# the control center is built inside the target chroot with a temporary
# toolchain. Mark every pre-existing package manual first: autoremove can then
# remove only the build dependencies without touching the runtime userspace.
if [[ "$BUILD_SETTINGS" == "1" ]]; then
    log "Building bubble-settings in the target RootFS"
    settings_src="$ROOTFS/usr/src/bubbleos/settings"
    install -d -m 0755 "$settings_src"
    cp -a "$ROOT/settings/." "$settings_src/"
    # Never reuse host-built objects: the host glibc/GTK are newer than the
    # target suite and would produce binaries that cannot start in the image.
    rm -f "$settings_src"/bubble-settings \
        "$settings_src"/bubble-settings-helper "$settings_src"/*.o
    chown -R root:root "$settings_src"

    chroot "$ROOTFS" sh -c \
        'apt-mark showauto 2>/dev/null | xargs -r apt-mark manual >/dev/null 2>&1 || true'
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get update -qq
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends \
        gcc make libc6-dev libgtk-3-dev pkg-config
    chroot "$ROOTFS" make -C /usr/src/bubbleos/settings
    chroot "$ROOTFS" make -C /usr/src/bubbleos/settings install
    chroot "$ROOTFS" gtk-update-icon-cache -f -t /usr/share/icons/hicolor \
        >/dev/null 2>&1 || true
    chroot "$ROOTFS" update-desktop-database /usr/share/applications \
        >/dev/null 2>&1 || true
    rm -rf "$settings_src"

    chroot "$ROOTFS" test -x /usr/bin/bubble-settings ||
        die "bubble-settings was not installed"
    chroot "$ROOTFS" test -x /usr/libexec/bubbleos/bubble-settings-helper ||
        die "bubble-settings-helper was not installed"

    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y -qq gcc make libc6-dev libgtk-3-dev pkg-config
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
        apt-get autoremove -y -qq --purge
    chroot "$ROOTFS" ldconfig >/dev/null 2>&1 || true

    if chroot "$ROOTFS" sh -c 'command -v gcc >/dev/null 2>&1'; then
        die "the C toolchain is still present in the target RootFS"
    fi
    log "bubble-settings installed"
fi

log "Installing ULPM tree (development integration)"
cp -a "$ROOT/ulpm" "$ROOTFS/opt/bubbleos/ulpm"
if [[ -f "$ROOTFS/opt/bubbleos/ulpm/bin/ulpm" ]]; then
    ln -sf /opt/bubbleos/ulpm/bin/ulpm "$ROOTFS/usr/local/bin/ulpm"
fi
if [[ -f "$ROOTFS/opt/bubbleos/ulpm/bin/ulrm" ]]; then
    ln -sf /opt/bubbleos/ulpm/bin/ulrm "$ROOTFS/usr/local/bin/ulrm"
fi
chown -R root:root "$ROOTFS/opt/bubbleos"
chmod -R go-w "$ROOTFS/opt/bubbleos"

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
BUBBLEOS_ROOTFS_MOUNT=/var/lib/bubbleos/rootfs
BUBBLEOS_SNAPSHOTS_DIR=/snapshots
BUBBLEOS_SNAPSHOT_KEEP=\${BUBBLEOS_SNAPSHOT_KEEP:-10}
CONF

log "Initializing bubbleOS state template"
chroot "$ROOTFS" /usr/local/bin/bubble bootstrap

if [[ "$DESKTOP" == "1" ]]; then
    log "Preparing desktop user and caches"
    chroot "$ROOTFS" systemd-sysusers >/dev/null 2>&1 ||
        log "WARNING: systemd-sysusers failed"
    chroot "$ROOTFS" systemd-tmpfiles --create >/dev/null 2>&1 ||
        log "WARNING: systemd-tmpfiles failed"

    if [[ -n "$DESKTOP_USER" && "$DESKTOP_USER" != "root" ]]; then
        if chroot "$ROOTFS" id -u "$DESKTOP_USER" >/dev/null 2>&1; then
            log "Desktop user $DESKTOP_USER already exists"
        else
            desktop_groups=()
            for group in $DESKTOP_USER_GROUPS; do
                if chroot "$ROOTFS" getent group "$group" >/dev/null 2>&1; then
                    desktop_groups+=("$group")
                fi
            done
            group_list=""
            if (( ${#desktop_groups[@]} > 0 )); then
                group_list="$(IFS=,; echo "${desktop_groups[*]}")"
            fi
            if [[ -n "$group_list" ]]; then
                chroot "$ROOTFS" useradd -m -s /bin/bash \
                    -G "$group_list" "$DESKTOP_USER"
            else
                chroot "$ROOTFS" useradd -m -s /bin/bash "$DESKTOP_USER"
            fi
            if [[ -n "$DESKTOP_USER_PASSWORD" ]]; then
                printf '%s:%s\n' "$DESKTOP_USER" "$DESKTOP_USER_PASSWORD" |
                    chroot "$ROOTFS" chpasswd
            fi
            log "Created desktop user $DESKTOP_USER"
        fi
        chroot "$ROOTFS" id -u "$DESKTOP_USER" >/dev/null 2>&1 ||
            die "desktop user $DESKTOP_USER was not created"

        # Refresh the themed htop defaults when the user already existed and
        # has no configuration of their own yet.  Create the config
        # directories explicitly: install -D creates leading directories as
        # root, which would block the user session from chmod'ing ~/.config.
        desktop_config="$ROOTFS/home/$DESKTOP_USER/.config"
        if [[ -f "$ROOTFS/etc/skel/.config/htop/htoprc" &&
            ! -e "$desktop_config/htop/htoprc" ]]; then
            install -d -m 0755 "$desktop_config" "$desktop_config/htop"
            chown "$DESKTOP_USER:$DESKTOP_USER" "$desktop_config" \
                "$desktop_config/htop"
            chmod 0700 "$desktop_config"
            install -m 0644 -o "$DESKTOP_USER" -g "$DESKTOP_USER" \
                "$ROOTFS/etc/skel/.config/htop/htoprc" \
                "$desktop_config/htop/htoprc"
        fi
    fi

    # greetd runs the greeter as _greetd.  systemd-sysusers created it above;
    # fail the build instead of producing an image with a broken login screen.
    chroot "$ROOTFS" id -u _greetd >/dev/null 2>&1 ||
        die "greetd user _greetd is missing"

    chroot "$ROOTFS" fc-cache -f >/dev/null 2>&1 ||
        log "WARNING: fc-cache failed"
fi

if [[ "$SYSTEMD" == "1" ]]; then
    log "Enabling systemd services"
    chroot "$ROOTFS" systemctl enable bubbleos-boot.service
    chroot "$ROOTFS" systemctl enable bubbleos-var-restore.service
    chroot "$ROOTFS" systemctl enable getty@tty1.service
    chroot "$ROOTFS" systemctl enable serial-getty@ttyS0.service

    if [[ "$DESKTOP" == "1" ]]; then
        chroot "$ROOTFS" systemctl enable NetworkManager.service
        chroot "$ROOTFS" systemctl enable bluetooth.service
        chroot "$ROOTFS" systemctl enable greetd.service
        chroot "$ROOTFS" systemctl --global enable \
            pipewire.socket pipewire-pulse.socket wireplumber.service
        chroot "$ROOTFS" systemctl set-default graphical.target
    else
        chroot "$ROOTFS" systemctl set-default multi-user.target
    fi

    log "Setting development root password"
    printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$ROOTFS" chpasswd

    log "Generating machine-id"
    if ! chroot "$ROOTFS" systemd-machine-id-setup >/dev/null 2>&1; then
        tr -d '-' < /proc/sys/kernel/random/uuid > "$ROOTFS/etc/machine-id"
    fi

fi

# ------------------------------------------------------------------------------
# Kernel modules
# ------------------------------------------------------------------------------
# Install the complete module tree, not only autofs4: the supplied 7.2.15 kernel
# keeps storage and virtio support built in, but graphics, Wi-Fi, audio and
# other hardware drivers remain loadable modules. depmod builds the binary
# indexes used by libkmod/systemd, including modules.builtin.bin so built-in
# drivers such as btrfs and autofs4 are recognized.
if [[ -d "$KERNEL_MODULE_DIR" ]]; then
    log "Installing kernel modules for $KERNEL_RELEASE"
    module_target="$ROOTFS/usr/lib/modules/$KERNEL_RELEASE"
    install -d -m 0755 "$module_target"
    cp -a --reflink=auto -- "$KERNEL_MODULE_DIR/." "$module_target/"
    # Build-tree links point at the host source tree and must not leak into
    # the target image.
    rm -f "$module_target/build" "$module_target/source"
    chown -R root:root "$module_target"
    find "$module_target" -type d -exec chmod 0755 {} +
    find "$module_target" -type f -exec chmod 0644 {} +
    chroot "$ROOTFS" depmod "$KERNEL_RELEASE" >/dev/null 2>&1 ||
        die "depmod failed for kernel $KERNEL_RELEASE"
else
    log "WARNING: kernel modules not found for $KERNEL_RELEASE ($KERNEL_MODULE_DIR)"
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
    "$ROOTFS/usr/lib/udev/rules.d/80-bubbleos-compat.rules" \
    "$ROOTFS/usr/share/base-files/staff-group-for-usr-local"; do
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
    "$ROOTFS/usr/share/debconf/confmodule" \
    "$ROOTFS/usr/share/debconf/confmodule.sh" \
    "$ROOTFS/usr/share/dbus-1/system.d/systemd-localed-read-only.conf" \
    "$ROOTFS/usr/lib/systemd/system/rc-local.service.d/bubbleos.conf" \
    "$ROOTFS/usr/lib/udev/rules.d/80-bubbleos-compat.rules"; do
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

sed -i 's#In bubbleOS GNU/Linux#In bubbleOS#' \
    "$ROOTFS/usr/share/base-files/info.dir"

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
distribution terms are described in the package metadata.

bubbleOS comes with ABSOLUTELY NO WARRANTY, to the extent permitted by
applicable law.
MOTD

# Keep the /usr/local group policy marker, but drop the bootstrap
# distribution's release history from its content.
cat > "$ROOTFS/usr/share/base-files/staff-group-for-usr-local" <<'POLICY'
Current policy mandates that directories in /usr/local should be owned
by group staff and mode 2775.

This file marks that policy for the system. If it is removed, directories
in /usr/local are reset to mode 755 and owned by group root.

bubbleOS keeps the staff-group policy for /usr/local.
POLICY

# Lintian profiles are development-only metadata for the bootstrap packages.
rm -rf "$ROOTFS/usr/share/lintian"

# Package documentation and bug-report scripts are not part of the runtime
# image. Keep empty directories for tooling that expects them to exist.
log "Removing package documentation and bug metadata"
rm -rf "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/bug"
install -d -m 0755 "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/bug"

# systemd's legacy tmpfiles rules create /var/log/README as a symlink into the
# documentation tree. Drop that rule and any existing link so the image does
# not ship a dangling symlink.
if [[ -f "$ROOTFS/usr/lib/tmpfiles.d/legacy.conf" ]]; then
    sed -i '/^L\$ \/var\/log\/README /d' "$ROOTFS/usr/lib/tmpfiles.d/legacy.conf"
fi
rm -f "$ROOTFS/var/log/README"

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
            grep -E '^(libapt-pkg.*|sqv|debian-archive-keyring)$' || true
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

if ! chroot "$ROOTFS" sh -c 'command -v btrfs >/dev/null 2>&1'; then
    die "btrfs-progs is missing from the target RootFS"
fi

# ------------------------------------------------------------------------------
# Firmware
# ------------------------------------------------------------------------------
# The local firmware drop contains extracted Debian packages. Only their
# /usr/lib/firmware payloads are merged: the rest of those trees also contains
# package-manager dependencies and is not part of the firmware runtime.
if [[ -d "$FIRMWARE_DIR" ]]; then
    log "Installing firmware from $FIRMWARE_DIR"
    install -d -m 0755 "$ROOTFS/usr/lib/firmware"
    shopt -s nullglob
    firmware_payloads=("$FIRMWARE_DIR"/*/usr/lib/firmware)
    shopt -u nullglob
    if (( ${#firmware_payloads[@]} == 0 )); then
        log "WARNING: no */usr/lib/firmware payload found in $FIRMWARE_DIR"
    else
        for payload in "${firmware_payloads[@]}"; do
            log "  merging ${payload#"$FIRMWARE_DIR"/}"
            cp -a --reflink=auto -- "$payload/." "$ROOTFS/usr/lib/firmware/"
        done
        chown -R root:root "$ROOTFS/usr/lib/firmware"
        find "$ROOTFS/usr/lib/firmware" -type d -exec chmod 0755 {} +
        find "$ROOTFS/usr/lib/firmware" -type f -exec chmod 0644 {} +
    fi
else
    log "No firmware drop found at $FIRMWARE_DIR; skipping firmware"
fi

# ------------------------------------------------------------------------------
# Hardware userspace
# ------------------------------------------------------------------------------
# HARDWARE_PACKAGES are part of the debootstrap transaction above, so their
# libraries, data files and maintainer scripts are installed by dpkg from the
# target suite.  The external firmware drop is only used for /usr/lib/firmware:
# never copy its /usr/lib binaries, because it can be extracted from a newer
# Debian and would shadow the suite's glib/systemd/drm libraries.
if [[ "$HARDWARE_USERSPACE" == "1" ]]; then
    missing_hardware=()
    for package in $HARDWARE_PACKAGES; do
        if ! chroot "$ROOTFS" dpkg -s "$package" >/dev/null 2>&1; then
            missing_hardware+=("$package")
        fi
    done
    if (( ${#missing_hardware[@]} > 0 )); then
        die "hardware userspace packages were not installed: ${missing_hardware[*]}"
    fi
    log "Hardware userspace installed from the target suite"
fi

# ------------------------------------------------------------------------------
# Runtime pruning
# ------------------------------------------------------------------------------
# Drop the unused theme variants, translations and documentation payloads that
# Debian installs by default.  build-image.sh runs the same idempotent step so
# images built from an existing RootFS stay lean.
log "Pruning unused runtime data"
"$ROOT/build/prune-rootfs.sh" "$ROOTFS"

log "RootFS created successfully"
printf '\nRootFS: %s\n' "$ROOTFS"
printf 'Next phase: build the Btrfs image with build/build-image.sh.\n'
