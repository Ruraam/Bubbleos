#!/usr/bin/env python3
"""Desktop session: Wayfire, Waybar, Fuzzel, Mako, greetd and the bubble CLI."""

from __future__ import annotations

import base64
import re
import shlex
import textwrap

from common import (
    CMD_TIMEOUT,
    DISK_IMAGE,
    boot,
    check_sudo,
    cleanup,
    copy_image,
    report,
    require_artifacts,
    require_commands,
    workdir,
)

BINARIES = (
    "wayfire waybar fuzzel mako foot swaybg swaylock swayidle greetd tuigreet "
    "grim slurp wlopm wcm nmcli bluetoothctl wpctl dbus-run-session "
    "bubble-settings lxpolkit nm-connection-editor pkexec vulkaninfo"
).split()

CONFIG_FILES = (
    "/etc/bubbleos/desktop.conf",
    "/usr/share/bubbleos/desktop/wayfire.ini",
    "/usr/share/bubbleos/desktop/waybar/config.jsonc",
    "/usr/share/bubbleos/desktop/waybar/style.css",
    "/etc/xdg/fuzzel/fuzzel.ini",
    "/etc/xdg/mako/config",
    "/etc/xdg/foot/foot.ini",
    "/etc/swaylock/config",
    "/etc/greetd/config.toml",
    "/etc/pam.d/greetd",
    "/etc/environment.d/90-bubbleos-desktop.conf",
    "/etc/gtk-3.0/settings.ini",
    "/etc/xdg/xdg-desktop-portal-wlr/config",
    "/usr/share/wayland-sessions/bubbleos.desktop",
    "/usr/share/backgrounds/bubbleos/bubbleos-wallpaper.png",
    "/usr/share/fonts/truetype/orbitron/Orbitron-VariableFont_wght.ttf",
    "/usr/bin/bubble-settings",
    "/usr/libexec/bubbleos/bubble-settings-helper",
    "/usr/share/polkit-1/actions/org.bubbleos.settings.policy",
    "/usr/share/bubbleos/settings/bubble-settings.css",
    "/usr/share/applications/bubble-settings.desktop",
    "/usr/share/icons/hicolor/scalable/apps/bubbleos-settings.svg",
)

WAYBAR_DEFAULT = (
    "top|36|custom/logo,network,bluetooth|clock|"
    "battery,pulseaudio,tray,custom/power"
)
WAYBAR_OVERRIDE = (
    "bottom|44|clock,battery|clock|battery,pulseaudio,tray,custom/power"
)

SESSION_SCRIPT = textwrap.dedent(
    r"""
    #!/bin/sh
    set -u
    uid=$(id -u bubble)
    runtime=/run/user/$uid
    install -d -m 0700 -o bubble -g bubble "$runtime" || exit 0
    out=/tmp/bubble-desktop-session.log
    rm -f "$out"

    # run-qemu.sh exposes a virtio GPU with a connected Virtual-1 output.
    # Using the real DRM backend (instead of headless) exercises the same
    # path as the greetd session and lets wlroots allocate scanout buffers,
    # which the headless backend cannot do through a render node.
    su -s /bin/sh bubble -c "HOME=/home/bubble XDG_RUNTIME_DIR=$runtime PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin WLR_BACKENDS=drm WLR_RENDERER=gles2 LIBGL_ALWAYS_SOFTWARE=1 bubble-desktop session" >"$out" 2>&1 &
    pid=$!

    i=0
    ready=0
    while [ "$i" -lt 150 ]; do
        if grep -q 'Wayfire is ready on' "$out" 2>/dev/null; then
            ready=1
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "SESSION_READY=$ready"

    if [ "$ready" -ne 1 ]; then
        echo "--- wrapper log ---"
        tail -n 80 "$out" 2>/dev/null
        echo "--- compositor log ---"
        tail -n 80 "$runtime/bubbleos/session.log" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null || true
        pkill -TERM -u bubble -x wayfire 2>/dev/null || true
        exit 0
    fi

    socket=$(sed -n 's/.*Wayfire is ready on \(wayland-[0-9][0-9]*\).*/\1/p' "$out" 2>/dev/null | tail -n 1)
    if [ -z "$socket" ]; then
        socket=$(sed -n 's/.*Using socket name \(wayland-[0-9][0-9]*\).*/\1/p' "$runtime/bubbleos/session.log" 2>/dev/null | tail -n 1)
    fi
    echo "SOCKET=$socket"
    if [ -n "$socket" ] && [ -S "$runtime/$socket" ]; then
        echo "SOCKET_OK=1"
    else
        echo "SOCKET_OK=0"
    fi

    if [ -n "$socket" ]; then
        rm -f /tmp/bubble-settings-gui.log
        if su -s /bin/sh bubble -c "HOME=/home/bubble XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$socket PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin GDK_BACKEND=wayland dbus-run-session -- bubble-settings --smoke-test --page users" >/tmp/bubble-settings-gui.log 2>&1; then
            echo "SETTINGS_GUI=1"
        else
            echo "SETTINGS_GUI=0"
            tail -n 40 /tmp/bubble-settings-gui.log 2>/dev/null
        fi
    else
        echo "SETTINGS_GUI=0"
    fi

    i=0
    while [ "$i" -lt 75 ]; do
        missing=0
        for p in wayfire waybar mako swaybg swayidle; do
            pgrep -u bubble -x "$p" >/dev/null 2>&1 || missing=1
        done
        [ "$missing" -eq 0 ] && break
        sleep 0.2
        i=$((i + 1))
    done
    for p in wayfire waybar mako swaybg swayidle; do
        if pgrep -u bubble -x "$p" >/dev/null 2>&1; then
            echo "PROC_$p=1"
        else
            echo "PROC_$p=0"
        fi
    done

    if [ -n "$socket" ]; then
        rm -f /tmp/bubble-desktop.png
        if su -s /bin/sh bubble -c "HOME=/home/bubble XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$socket grim /tmp/bubble-desktop.png" >/dev/null 2>&1; then
            stat -c 'GRIM_SIZE=%s' /tmp/bubble-desktop.png 2>/dev/null || echo "GRIM_SIZE=0"
        else
            echo "GRIM_SIZE=0"
        fi
    else
        echo "GRIM_SIZE=0"
    fi

    if [ -f /home/bubble/.config/wayfire.ini ]; then
        echo "USER_WAYFIRE=1"
    else
        echo "USER_WAYFIRE=0"
    fi
    if [ -s "$runtime/bubbleos/waybar/config.jsonc" ]; then
        echo "WAYBAR_CONFIG=1"
    else
        echo "WAYBAR_CONFIG=0"
    fi

    pkill -TERM -u bubble -x wayfire 2>/dev/null || true
    i=0
    leftover=1
    while [ "$i" -lt 100 ]; do
        leftover=0
        for p in wayfire waybar mako swaybg swayidle; do
            pgrep -u bubble -x "$p" >/dev/null 2>&1 && leftover=$((leftover + 1))
        done
        [ "$leftover" -eq 0 ] && break
        sleep 0.2
        i=$((i + 1))
    done
    if [ "$leftover" -eq 0 ]; then
        echo "CLEANUP_OK=1"
    else
        echo "CLEANUP_OK=0"
        for p in wayfire waybar mako swaybg swayidle; do
            pgrep -a -u bubble -x "$p" 2>/dev/null || true
        done
    fi

    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
    echo "--- wrapper log ---"
    tail -n 25 "$out" 2>/dev/null
    """
).strip()


def run_as_bubble(vm, command: str, timeout: int = CMD_TIMEOUT) -> str:
    inner = (
        'export HOME="/home/$(id -un)" '
        'PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" '
        'XDG_RUNTIME_DIR="/run/user/$(id -u)"; ' + command
    )
    return vm.run(f"su -s /bin/sh bubble -c {shlex.quote(inner)}", timeout=timeout)


def waybar_summary(vm) -> str:
    query = """jq -r '[.position, (.height|tostring), (."modules-left"|join(",")), (."modules-center"|join(",")), (."modules-right"|join(","))] | join("|")' "$XDG_RUNTIME_DIR/bubbleos/waybar/config.jsonc" """
    return run_as_bubble(vm, query).strip().splitlines()[-1]


def parse_key_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^([A-Za-z0-9_]+)=(.*)$", line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def main() -> None:
    require_commands("qemu-system-x86_64", "cp")
    require_artifacts(DISK_IMAGE)
    check_sudo()

    work = workdir()
    checks: list[tuple[str, bool, str]] = []
    try:
        disk = copy_image(DISK_IMAGE, work / "disk.img")
        with boot(name="desktop", disk_image=disk) as vm:
            vm.login()

            missing = vm.run(
                'missing=; for c in '
                + " ".join(BINARIES)
                + '; do command -v "$c" >/dev/null 2>&1 || '
                'missing="$missing $c"; done; '
                'printf \'missing:%s\\n\' "${missing:-none}"'
            )
            checks.append(
                (
                    "desktop applications are installed",
                    missing.strip() == "missing:none",
                    missing,
                )
            )

            absent = vm.run(
                'missing=; for f in '
                + " ".join(CONFIG_FILES)
                + '; do [ -s "$f" ] || missing="$missing $f"; done; '
                'printf \'missing:%s\\n\' "${missing:-none}"'
            )
            checks.append(
                (
                    "desktop configuration files are installed",
                    absent.strip() == "missing:none",
                    absent,
                )
            )

            graphics = vm.run(
                "missing=; "
                "for p in /usr/lib/x86_64-linux-gnu/dri/nouveau_dri.so "
                "/usr/lib/x86_64-linux-gnu/dri/zink_dri.so "
                "/usr/lib/x86_64-linux-gnu/libvulkan_nouveau.so "
                "/usr/share/vulkan/icd.d/nouveau_icd.json "
                "/usr/share/vulkan/icd.d/lvp_icd.json; do "
                '[ -s "$p" ] || missing="$missing $p"; done; '
                "find /usr/lib/firmware/nvidia -path '*/acr/ucode_load.bin' "
                "-print -quit 2>/dev/null | grep -q . || "
                'missing="$missing nvidia-firmware"; '
                "v=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers "
                "2>/dev/null); "
                'dpkg --compare-versions "$v" ge 25.1 2>/dev/null || '
                'missing="$missing mesa-vulkan>=25.1"; '
                "printf 'missing:%s\\n' \"${missing:-none}\""
            )
            checks.append(
                (
                    "nouveau firmware, NVK and zink drivers are installed",
                    graphics.strip() == "missing:none",
                    graphics,
                )
            )

            wifi = vm.run(
                "missing=; "
                "find /usr/lib/modules -path '*/ralink/rt2x00/rt2800pci.ko*' "
                "-print -quit 2>/dev/null | grep -q . || "
                'missing="$missing rt2800pci"; '
                "[ -s /usr/lib/firmware/rt2860.bin ] || "
                'missing="$missing rt2860.bin"; '
                "[ -x /usr/sbin/wpa_supplicant ] || "
                'missing="$missing wpa_supplicant"; '
                "modprobe rt2800pci 2>/dev/null; "
                "grep -q '^rt2800pci ' /proc/modules || "
                'missing="$missing rt2800pci-load"; '
                "printf 'missing:%s\\n' \"${missing:-none}\""
            )
            checks.append(
                (
                    "the reference Wi-Fi driver, firmware and module load work",
                    wifi.strip() == "missing:none",
                    wifi,
                )
            )

            gamepad = vm.run(
                "missing=; "
                "for m in xpad hid-sony hid-nintendo hid-steam "
                "hid-playstation hid-microsoft uinput uhid; do "
                'find /usr/lib/modules -name "$m.ko*" -print -quit '
                '2>/dev/null | grep -q . || missing="$missing $m"; done; '
                "for m in hid-playstation hid-microsoft uinput; do "
                'modprobe "$m" 2>/dev/null; done; '
                "udevadm settle 2>/dev/null; "
                "for m in hid_playstation hid_microsoft uinput; do "
                'grep -q "^$m " /proc/modules || '
                'missing="$missing $m-load"; done; '
                '[ -c /dev/uinput ] || missing="$missing /dev/uinput"; '
                "[ \"$(stat -c '%G %a' /dev/uinput 2>/dev/null)\" = 'input 660' ] || "
                'missing="$missing uinput-perms"; '
                "printf 'missing:%s\\n' \"${missing:-none}\""
            )
            checks.append(
                (
                    "game controller drivers and uinput are available",
                    gamepad.strip() == "missing:none",
                    gamepad,
                )
            )

            controller_tools = vm.run(
                "missing=; "
                "for b in evtest jstest fftest lsusb lspci; do "
                'command -v "$b" >/dev/null 2>&1 || missing="$missing $b"; '
                "done; "
                "for f in /usr/libexec/installed-tests/SDL2/testgamecontroller "
                "/usr/libexec/installed-tests/SDL2/testjoystick; do "
                '[ -x "$f" ] || missing="$missing ${f##*/}"; done; '
                "ldconfig -p | grep -q 'libSDL2-2.0.so.0' || "
                'missing="$missing libSDL2"; '
                "ldconfig -p | grep -q 'libSDL3.so.0' || "
                'missing="$missing libSDL3"; '
                "printf 'missing:%s\\n' \"${missing:-none}\""
            )
            checks.append(
                (
                    "controller diagnostics and SDL runtimes are installed",
                    controller_tools.strip() == "missing:none",
                    controller_tools,
                )
            )

            vulkan = vm.run(
                "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json "
                "vulkaninfo --summary 2>/dev/null | "
                "sed -n 's/.*deviceName *= *//p' | head -n 1"
            )
            checks.append(
                (
                    "the Vulkan loader enumerates Mesa ICDs",
                    bool(vulkan.strip()),
                    vulkan.strip() or "no Vulkan device",
                )
            )

            gl_driver = vm.run(
                "grep -q '^DESKTOP_GL_DRIVER=auto$' "
                "/etc/bubbleos/desktop.conf && "
                "grep -q 'MESA_LOADER_DRIVER_OVERRIDE=zink' "
                "/usr/local/bin/bubble-desktop && "
                "grep -q 'nouveau_icd.json' "
                "/usr/local/bin/bubble-desktop && echo ok || echo fail"
            )
            checks.append(
                (
                    "zink is selectable and pinned to the display GPU ICD",
                    gl_driver.strip() == "ok",
                    gl_driver,
                )
            )

            wayfire = vm.run(
                "for token in blur winshadows session-lock idle; do "
                "grep -q \"$token\" /usr/share/bubbleos/desktop/wayfire.ini || "
                'echo "missing:$token"; done; '
                "grep -q '^screensaver_timeout = -1$' "
                "/usr/share/bubbleos/desktop/wayfire.ini || echo missing:idle-timeout; "
                "grep -q '^binding_files' "
                "/usr/share/bubbleos/desktop/wayfire.ini && echo conflict:binding_files; "
                "echo done"
            )
            checks.append(
                (
                    "Wayfire loads the cyber-punk plugins and disables its own idle timeouts",
                    wayfire.strip() == "done",
                    wayfire,
                )
            )

            placeholders = vm.run(
                "for p in @MODULES_LEFT@ @MODULES_CENTER@ @MODULES_RIGHT@ "
                "@BAR_POSITION@ @BAR_HEIGHT@ @MARGIN_TOP@ @MARGIN_BOTTOM@; do "
                'n=$(grep -c -- "$p" '
                "/usr/share/bubbleos/desktop/waybar/config.jsonc); "
                '[ "$n" = 1 ] || echo "bad:$p=$n"; done; echo done'
            )
            checks.append(
                (
                    "Waybar template exposes every configurable placeholder",
                    placeholders.strip() == "done",
                    placeholders,
                )
            )

            theme = vm.run(
                "grep -q '#22d3ee' /usr/share/bubbleos/desktop/waybar/style.css && "
                "grep -q '#0c2340' /usr/share/bubbleos/desktop/waybar/style.css && "
                "grep -q 'FontAwesome' "
                "/usr/share/bubbleos/desktop/waybar/style.css && echo ok || echo fail"
            )
            checks.append(
                (
                    "Waybar stylesheet uses the bubbleOS palette and icon fonts",
                    theme.strip() == "ok",
                    theme,
                )
            )

            wallpaper = vm.run(
                "file -b /usr/share/backgrounds/bubbleos/bubbleos-wallpaper.png; "
                "stat -c 'size=%s' "
                "/usr/share/backgrounds/bubbleos/bubbleos-wallpaper.png"
            )
            checks.append(
                (
                    "bubbleOS wallpaper is a high-resolution PNG",
                    "PNG image data, 2560 x 1440" in wallpaper
                    and re.search(r"size=(\d+)", wallpaper) is not None
                    and int(re.search(r"size=(\d+)", wallpaper).group(1)) > 500_000,
                    wallpaper,
                )
            )

            fonts = vm.run(
                "for spec in 'Orbitron:Orbitron' 'Inter:Inter' "
                "'JetBrains Mono:JetBrains Mono' "
                "'FontAwesome:FontAwesome' "
                "'Noto Color Emoji:Noto Color Emoji'; do "
                "name=${spec%%:*}; want=${spec#*:}; "
                "got=$(fc-match -f '%{family}' \"$name\" 2>/dev/null | head -n 1); "
                "case \"$got\" in *\"$want\"*) ;; "
                "*) echo \"bad:$name=$got\" ;; esac; done; echo done"
            )
            checks.append(
                (
                    "theme, UI, monospace, icon and emoji fonts resolve",
                    fonts.strip() == "done",
                    fonts,
                )
            )

            pruned = vm.run(
                "for p in /usr/share/icons/Papirus-Dark "
                "/usr/share/icons/Bibata-Modern-Ice /usr/share/locale/fr; do "
                '[ -e "$p" ] || echo "missing:$p"; done; '
                "for p in /usr/share/icons/Papirus "
                "/usr/share/icons/Papirus-Light "
                "/usr/share/icons/Bibata-Modern-Amber "
                "/usr/share/locale/de /usr/share/man /usr/share/info "
                "/usr/bin/gprofng; do "
                '[ -e "$p" ] && echo "kept:$p"; done; echo done'
            )
            checks.append(
                (
                    "configured themes and French locale stay, unused payloads stay pruned",
                    pruned.strip() == "done",
                    pruned,
                )
            )

            user = vm.run(
                "id -u bubble; getent passwd bubble | cut -d: -f7; id -Gn bubble; "
                "passwd -S bubble"
            )
            user_lines = user.splitlines()
            uid = user_lines[0].strip() if user_lines else ""
            shell = user_lines[1].strip() if len(user_lines) > 1 else ""
            groups = user_lines[2].split() if len(user_lines) > 2 else []
            password = user_lines[3] if len(user_lines) > 3 else ""
            expected_groups = {
                "audio",
                "video",
                "input",
                "render",
                "lp",
                "plugdev",
                "sudo",
                "bluetooth",
            }
            checks.append(
                (
                    "desktop user bubble has a home, a password and device groups",
                    uid.isdigit()
                    and shell == "/bin/bash"
                    and expected_groups.issubset(set(groups))
                    and re.match(r"^bubble\s+P\b", password) is not None,
                    user,
                )
            )

            services = vm.run(
                "printf 'default=%s\\n' \"$(systemctl get-default)\"; "
                "printf 'greetd_enabled=%s\\n' "
                "\"$(systemctl is-enabled greetd.service 2>/dev/null)\"; "
                "printf 'greetd_active=%s\\n' "
                "\"$(systemctl is-active greetd.service 2>/dev/null)\"; "
                "printf 'nm_active=%s\\n' "
                "\"$(systemctl is-active NetworkManager.service 2>/dev/null)\"; "
                "printf 'bt_active=%s\\n' "
                "\"$(systemctl is-active bluetooth.service 2>/dev/null)\"; "
                "printf 'bt_enabled=%s\\n' "
                "\"$(systemctl is-enabled bluetooth.service 2>/dev/null)\"; "
                "printf 'bt_sysfs=%s\\n' "
                "\"$([ -d /sys/class/bluetooth ] && echo 1 || echo 0)\"; "
                "printf 'tuigreet_pid=%s\\n' "
                "\"$(pgrep -x tuigreet | head -n 1)\""
            )
            service_values = parse_key_values(services)
            checks.append(
                (
                    "graphical target, greetd, NetworkManager and BlueZ are running",
                    service_values.get("default") == "graphical.target"
                    and service_values.get("greetd_enabled") == "enabled"
                    and service_values.get("greetd_active") == "active"
                    and service_values.get("nm_active") == "active"
                    and service_values.get("bt_enabled") == "enabled"
                    and (
                        service_values.get("bt_active") == "active"
                        or service_values.get("bt_sysfs") == "0"
                    )
                    and service_values.get("tuigreet_pid", "").isdigit(),
                    services,
                )
            )

            user_units = vm.run(
                "systemctl --global is-enabled pipewire.socket "
                "pipewire-pulse.socket wireplumber.service"
            )
            checks.append(
                (
                    "PipeWire and WirePlumber are enabled for user sessions",
                    user_units.splitlines() == ["enabled"] * 3,
                    user_units,
                )
            )

            greetd = vm.run(
                "grep -q '^vt = 7$' /etc/greetd/config.toml && "
                "grep -q 'tuigreet' /etc/greetd/config.toml && "
                "grep -q 'bubble-desktop session' /etc/greetd/config.toml && "
                "grep -q -- '--sessions /usr/share/wayland-sessions' "
                "/etc/greetd/config.toml && "
                "grep -q -- '--user-menu' /etc/greetd/config.toml && "
                "grep -q -- '--user-menu-min-uid 1000' "
                "/etc/greetd/config.toml && echo ok || echo fail"
            )
            checks.append(
                (
                    "greetd starts tuigreet on VT7 with the bubbleOS session",
                    greetd.strip() == "ok",
                    greetd,
                )
            )

            pam = vm.run(
                "grep -Eq '^auth[[:space:]]+requisite[[:space:]]+"
                "pam_succeed_if.so user != root$' /etc/pam.d/greetd && "
                "echo ok || echo fail"
            )
            checks.append(
                (
                    "the greetd PAM stack rejects root (Wayfire cannot run as root)",
                    pam.strip() == "ok",
                    pam,
                )
            )

            session_entry = vm.run(
                "grep -q '^Exec=/usr/local/bin/bubble-desktop session$' "
                "/usr/share/wayland-sessions/bubbleos.desktop && "
                "test -x /usr/local/bin/bubble-desktop && "
                "bash -n /usr/local/bin/bubble-desktop && echo ok || echo fail"
            )
            checks.append(
                (
                    "Wayland session entry and bubble-desktop wrapper are valid",
                    session_entry.strip() == "ok",
                    session_entry,
                )
            )

            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed with the graphical target",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )

            runtime = vm.run(
                "uid=$(id -u bubble); "
                'install -d -m 0700 -o bubble -g bubble "/run/user/$uid"; '
                'stat -c \'%U %a\' "/run/user/$uid"'
            )
            checks.append(
                (
                    "the desktop user runtime directory is private",
                    runtime.strip() == "bubble 700",
                    runtime,
                )
            )

            defaults = run_as_bubble(vm, "bubble-desktop config show | sed 's/  */ /g'")
            checks.append(
                (
                    "desktop defaults expose Waybar, Mako, wallpaper, idle and GL settings",
                    "DESKTOP_WAYBAR 1" in defaults
                    and "DESKTOP_MAKO 1" in defaults
                    and "DESKTOP_WALLPAPER 1" in defaults
                    and "DESKTOP_IDLE 1" in defaults
                    and "DESKTOP_WAYBAR_POSITION top" in defaults
                    and "DESKTOP_IDLE_DPMS 300" in defaults
                    and "DESKTOP_IDLE_LOCK 600" in defaults
                    and "DESKTOP_GL_DRIVER auto" in defaults,
                    defaults,
                )
            )

            doctor = run_as_bubble(vm, "bubble-desktop doctor 2>&1")
            checks.append(
                (
                    "bubble-desktop doctor passes inside the guest",
                    "doctor: all checks passed" in doctor,
                    doctor,
                )
            )

            vm.run(
                "rm -f /home/bubble/.config/wayfire.ini "
                "/home/bubble/.config/bubbleos/desktop.conf; "
                "rm -rf /run/user/$(id -u bubble)/bubbleos; echo ok"
            )
            prepared = run_as_bubble(vm, "bubble-desktop prepare 2>&1")
            copied = vm.run(
                "cmp -s /home/bubble/.config/wayfire.ini "
                "/usr/share/bubbleos/desktop/wayfire.ini && echo same || echo different; "
                "find /home/bubble -maxdepth 3 -type d -name Screenshots"
            )
            checks.append(
                (
                    "first login copies the Wayfire defaults and creates the screenshot directory",
                    "same" in copied and "Screenshots" in copied,
                    prepared + "\n" + copied,
                )
            )

            summary = waybar_summary(vm)
            checks.append(
                (
                    "Waybar JSON is generated from the default modules",
                    summary == WAYBAR_DEFAULT,
                    f"expected {WAYBAR_DEFAULT!r}, got {summary!r}",
                )
            )

            run_as_bubble(
                vm,
                "bubble-desktop config set DESKTOP_WAYBAR_POSITION bottom 2>/dev/null && "
                "bubble-desktop config set DESKTOP_WAYBAR_HEIGHT 44 2>/dev/null && "
                'bubble-desktop config set DESKTOP_WAYBAR_LEFT "clock battery" 2>/dev/null && '
                "bubble-desktop prepare 2>/dev/null",
            )
            overridden = waybar_summary(vm)
            checks.append(
                (
                    "user overrides reconfigure Waybar without editing system files",
                    overridden == WAYBAR_OVERRIDE,
                    f"expected {WAYBAR_OVERRIDE!r}, got {overridden!r}",
                )
            )

            run_as_bubble(
                vm,
                "bubble-desktop config reset 2>/dev/null && "
                "bubble-desktop prepare 2>/dev/null",
            )
            reset = waybar_summary(vm)
            checks.append(
                (
                    "config reset restores the system Waybar defaults",
                    reset == WAYBAR_DEFAULT,
                    f"expected {WAYBAR_DEFAULT!r}, got {reset!r}",
                )
            )

            encoded = base64.b64encode(SESSION_SCRIPT.encode("utf-8")).decode("ascii")
            vm.run(
                f"printf '%s' '{encoded}' | base64 -d > /tmp/bubble-desktop-test.sh && "
                "chmod 0755 /tmp/bubble-desktop-test.sh && echo ok"
            )
            session = vm.run(
                "timeout 180 sh /tmp/bubble-desktop-test.sh 2>&1",
                timeout=CMD_TIMEOUT + 90,
            )
            values = parse_key_values(session)
            checks.append(
                (
                    "Wayfire starts on the DRM output and exposes a Wayland socket",
                    values.get("SESSION_READY") == "1"
                    and values.get("SOCKET_OK") == "1"
                    and values.get("SOCKET", "").startswith("wayland-"),
                    session,
                )
            )
            missing_processes = [
                name
                for name in ("wayfire", "waybar", "mako", "swaybg", "swayidle")
                if values.get(f"PROC_{name}") != "1"
            ]
            checks.append(
                (
                    "the session starts Waybar, Mako, swaybg and swayidle",
                    not missing_processes,
                    session,
                )
            )
            checks.append(
                (
                    "a Wayland client can capture the DRM output",
                    values.get("GRIM_SIZE", "0").isdigit()
                    and int(values.get("GRIM_SIZE", "0")) > 1_000,
                    session,
                )
            )
            checks.append(
                (
                    "bubble-settings opens all of its GTK pages in the session",
                    values.get("SETTINGS_GUI") == "1",
                    session,
                )
            )
            checks.append(
                (
                    "session shutdown removes the compositor and its companions",
                    values.get("CLEANUP_OK") == "1"
                    and values.get("USER_WAYFIRE") == "1"
                    and values.get("WAYBAR_CONFIG") == "1",
                    session,
                )
            )
    finally:
        cleanup(work)

    report("QEMU desktop integration test", checks)


if __name__ == "__main__":
    main()
