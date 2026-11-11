#!/usr/bin/env python3
"""bubble-settings: control center, privileged user helper and polkit policy."""

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
    "bubble-settings lxpolkit nm-connection-editor pkexec "
    "useradd usermod userdel chpasswd pkaction"
).split()

FILES = (
    "/usr/bin/bubble-settings",
    "/usr/libexec/bubbleos/bubble-settings-helper",
    "/usr/share/polkit-1/actions/org.bubbleos.settings.policy",
    "/usr/share/bubbleos/settings/bubble-settings.css",
    "/usr/share/applications/bubble-settings.desktop",
    "/usr/share/icons/hicolor/scalable/apps/bubbleos-settings.svg",
)

HELPER_SCRIPT = textwrap.dedent(
    r"""
    #!/bin/sh
    set -u
    HELPER=/usr/libexec/bubbleos/bubble-settings-helper
    PASS=testpass123

    cleanup() {
        gpasswd -a bubble sudo >/dev/null 2>&1 || true
        for user in bubbletest bubbleadmin bubbleself bubblelast bubblebad bubblehome; do
            "$HELPER" delete "$user" 1 >/dev/null 2>&1 || true
        done
        rm -f /tmp/bubble-settings-*.out /tmp/bubble-settings-*.err
    }
    trap cleanup EXIT INT TERM

    "$HELPER" --version || echo VERSION_FAIL

    # A non-root caller must be rejected before any account operation.
    if su -s /bin/sh bubble -c "$HELPER delete root 0" >/dev/null 2>&1; then
        echo NONROOT_FAIL
    else
        echo NONROOT_OK
    fi

    # Invalid identifiers and short passwords never create an account.
    if printf 'longpass123\n' | "$HELPER" add 'Bad/Name' 'Bad' 0 1 \
        >/dev/null 2>&1; then
        echo INVALID_USER_FAIL
    else
        echo INVALID_USER_OK
    fi
    if printf 'short\n' | "$HELPER" add bubblebad 'Bad' 0 1 >/dev/null 2>&1; then
        echo SHORT_PASSWORD_FAIL
    else
        echo SHORT_PASSWORD_OK
    fi
    if getent passwd bubblebad >/dev/null 2>&1; then
        echo SHORT_PASSWORD_CREATED
    else
        echo SHORT_PASSWORD_CLEAN
    fi

    # Standard account, home directory, bash shell and password.
    if printf '%s\n' "$PASS" | "$HELPER" add bubbletest 'Test User' 0 1 \
        >/tmp/bubble-settings-add.out 2>/tmp/bubble-settings-add.err; then
        echo ADD_OK
    else
        echo ADD_FAIL
        cat /tmp/bubble-settings-add.err
    fi
    getent passwd bubbletest | awk -F: '{print "PASSWD=" $6 "|" $7}'
    if [ -d /home/bubbletest ]; then echo HOME_OK; else echo HOME_FAIL; fi
    id -Gn bubbletest | tr ' ' '\n' | grep -qx sudo && echo ADDED_SUDO_FAIL || true
    passwd -S bubbletest | awk '{print "PW_STATUS=" $2}'

    # Changing and expiring a password updates the shadow database.
    before=$(awk -F: '$1 == "bubbletest" {print $2}' /etc/shadow)
    printf 'newpass456\n' | "$HELPER" passwd bubbletest 0 >/dev/null 2>&1
    after=$(awk -F: '$1 == "bubbletest" {print $2}' /etc/shadow)
    if [ "$before" != "$after" ]; then echo PASSWORD_CHANGED; else echo PASSWORD_CHANGE_FAIL; fi
    printf 'forcedpass789\n' | "$HELPER" passwd bubbletest 1 >/dev/null 2>&1
    last_change=$(awk -F: '$1 == "bubbletest" {print $3}' /etc/shadow)
    if [ "$last_change" = 0 ]; then echo FORCE_CHANGE_OK; else echo FORCE_CHANGE_FAIL; fi

    # Administrator account and sudo group.
    if printf 'adminpass123\n' | "$HELPER" add bubbleadmin 'Admin User' 1 1 \
        >/dev/null 2>&1; then
        echo ADMIN_ADD_OK
    else
        echo ADMIN_ADD_FAIL
    fi
    if id -Gn bubbleadmin | tr ' ' '\n' | grep -qx sudo; then
        echo ADMIN_GROUP_OK
    else
        echo ADMIN_GROUP_FAIL
    fi

    # Deleting an account also removes its home directory.
    if "$HELPER" delete bubbletest 1 >/dev/null 2>&1 &&
        ! getent passwd bubbletest >/dev/null 2>&1 &&
        [ ! -e /home/bubbletest ]; then
        echo DELETE_HOME_OK
    else
        echo DELETE_HOME_FAIL
    fi
    if "$HELPER" delete bubbleadmin 1 >/dev/null 2>&1 &&
        ! getent passwd bubbleadmin >/dev/null 2>&1; then
        echo ADMIN_DELETE_OK
    else
        echo ADMIN_DELETE_FAIL
    fi

    # No-home accounts are supported.
    if printf 'nohomepass123\n' | "$HELPER" add bubblehome 'No Home' 0 0 \
        >/dev/null 2>&1 && [ ! -d /home/bubblehome ]; then
        echo NOHOME_OK
    else
        echo NOHOME_FAIL
    fi
    "$HELPER" delete bubblehome 0 >/dev/null 2>&1

    # The caller cannot delete their own account.
    printf 'selfpass123\n' | "$HELPER" add bubbleself 'Self' 0 1 >/dev/null 2>&1
    self_uid=$(id -u bubbleself)
    if PKEXEC_UID="$self_uid" "$HELPER" delete bubbleself 0 </dev/null >/dev/null 2>&1; then
        echo SELF_DELETE_FAIL
    else
        echo SELF_DELETE_OK
    fi
    if getent passwd bubbleself >/dev/null 2>&1; then
        echo SELF_STILL_EXISTS
    else
        echo SELF_MISSING
    fi
    "$HELPER" delete bubbleself 1 >/dev/null 2>&1

    # Root and system accounts are never removable.
    if "$HELPER" delete root 0 </dev/null >/dev/null 2>&1; then
        echo ROOT_DELETE_FAIL
    else
        echo ROOT_DELETE_OK
    fi
    if getent passwd root >/dev/null 2>&1; then
        echo ROOT_STILL_EXISTS
    else
        echo ROOT_MISSING
    fi

    # The last administrator cannot be deleted. Temporarily remove bubble from
    # sudo so bubblelast is the only remaining human administrator.
    gpasswd -d bubble sudo >/dev/null 2>&1
    printf 'lastpass123\n' | "$HELPER" add bubblelast 'Last Admin' 1 1 >/dev/null 2>&1
    if "$HELPER" delete bubblelast 0 </dev/null >/dev/null 2>&1; then
        echo LAST_ADMIN_FAIL
    else
        echo LAST_ADMIN_OK
    fi
    gpasswd -a bubble sudo >/dev/null 2>&1
    if id -Gn bubble | tr ' ' '\n' | grep -qx sudo; then
        echo SUDO_RESTORED
    else
        echo SUDO_RESTORE_FAIL
    fi
    if "$HELPER" delete bubblelast 1 >/dev/null 2>&1 &&
        ! getent passwd bubblelast >/dev/null 2>&1; then
        echo LAST_DELETE_OK
    else
        echo LAST_DELETE_FAIL
    fi

    # Explicit clean state for the checks that follow.
    for user in bubbletest bubbleadmin bubbleself bubblelast bubblebad bubblehome; do
        getent passwd "$user" >/dev/null 2>&1 && echo "LEFTOVER=$user"
    done
    echo HELPER_SCRIPT_DONE
    """
).strip()


def run_as_bubble(vm, command: str, timeout: int = CMD_TIMEOUT) -> str:
    inner = (
        'export HOME="/home/$(id -un)" '
        'PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" '
        'XDG_RUNTIME_DIR="/run/user/$(id -u)"; ' + command
    )
    return vm.run(f"su -s /bin/sh bubble -c {shlex.quote(inner)}", timeout=timeout)


def parse_values(text: str) -> dict[str, str]:
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
        with boot(name="settings", disk_image=disk) as vm:
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
                    "bubble-settings applications and account tools are installed",
                    missing.strip() == "missing:none",
                    missing,
                )
            )

            absent = vm.run(
                'missing=; for f in '
                + " ".join(FILES)
                + '; do [ -s "$f" ] || missing="$missing $f"; done; '
                'printf \'missing:%s\\n\' "${missing:-none}"'
            )
            checks.append(
                (
                    "bubble-settings files, helper, policy and icon are installed",
                    absent.strip() == "missing:none",
                    absent,
                )
            )

            elf = vm.run(
                "file -b /usr/bin/bubble-settings; "
                "ldd /usr/bin/bubble-settings 2>&1 | grep 'not found' || echo libs-ok"
            )
            checks.append(
                (
                    "the control center is a native binary with resolvable libraries",
                    "ELF 64-bit" in elf and "libs-ok" in elf,
                    elf,
                )
            )

            toolchain = vm.run(
                "for c in gcc cc make pkg-config; do "
                'command -v "$c" >/dev/null 2>&1 && echo "left:$c"; done; echo done'
            )
            checks.append(
                (
                    "the temporary build toolchain was removed from the image",
                    toolchain.strip() == "done",
                    toolchain,
                )
            )

            policy = vm.run(
                "grep -q 'org.bubbleos.settings.users' "
                "/usr/share/polkit-1/actions/org.bubbleos.settings.policy && "
                "grep -q '/usr/libexec/bubbleos/bubble-settings-helper' "
                "/usr/share/polkit-1/actions/org.bubbleos.settings.policy && "
                "pkaction --action-id org.bubbleos.settings.users --verbose 2>&1"
            )
            checks.append(
                (
                    "polkit exposes the user-management action for the helper",
                    "org.bubbleos.settings.users" in policy
                    and "org.freedesktop.policykit.exec.path" in policy
                    and "/usr/libexec/bubbleos/bubble-settings-helper" in policy,
                    policy,
                )
            )

            doctor = run_as_bubble(vm, "bubble-settings --doctor 2>&1")
            checks.append(
                (
                    "bubble-settings doctor passes inside the guest",
                    "doctor: all checks passed" in doctor,
                    doctor,
                )
            )

            encoded = base64.b64encode(HELPER_SCRIPT.encode("utf-8")).decode("ascii")
            vm.run(
                f"printf '%s' '{encoded}' | base64 -d > /tmp/bubble-settings-helper-test.sh && "
                "chmod 0755 /tmp/bubble-settings-helper-test.sh && echo ok"
            )
            helper = vm.run(
                "sh /tmp/bubble-settings-helper-test.sh 2>&1",
                timeout=CMD_TIMEOUT + 60,
            )
            helper_values = parse_values(helper)
            helper_tokens = set(
                re.findall(r"^([A-Z][A-Z0-9_]*)$", helper, re.MULTILINE)
            )
            required_tokens = {
                "NONROOT_OK",
                "INVALID_USER_OK",
                "SHORT_PASSWORD_OK",
                "SHORT_PASSWORD_CLEAN",
                "ADD_OK",
                "HOME_OK",
                "PASSWORD_CHANGED",
                "FORCE_CHANGE_OK",
                "ADMIN_ADD_OK",
                "ADMIN_GROUP_OK",
                "DELETE_HOME_OK",
                "ADMIN_DELETE_OK",
                "NOHOME_OK",
                "SELF_DELETE_OK",
                "SELF_STILL_EXISTS",
                "ROOT_DELETE_OK",
                "ROOT_STILL_EXISTS",
                "LAST_ADMIN_OK",
                "SUDO_RESTORED",
                "LAST_DELETE_OK",
                "HELPER_SCRIPT_DONE",
            }
            checks.append(
                (
                    "the helper creates, updates and deletes accounts with all guards",
                    required_tokens.issubset(helper_tokens)
                    and helper_values.get("PW_STATUS") == "P"
                    and "LEFTOVER=" not in helper
                    and "SHORT_PASSWORD_CREATED" not in helper,
                    helper,
                )
            )

            # The bundled helper uses the expected passwd fields.
            checks.append(
                (
                    "created users get a home directory and a bash shell",
                    helper_values.get("PASSWD", "").endswith("|/bin/bash"),
                    helper,
                )
            )

            # pam_systemd creates the per-user runtime directory at login; the
            # tests reach the console through `su`, so create it explicitly.
            vm.run(
                "uid=$(id -u bubble); "
                'install -d -m 0700 -o bubble -g bubble "/run/user/$uid"'
            )

            empty = run_as_bubble(
                vm,
                "bubble-desktop config set DESKTOP_WAYBAR_LEFT '' 2>&1 && "
                "bubble-desktop config set DESKTOP_SCREENSHOT_DIR '' 2>&1 && "
                "bubble-desktop prepare >/dev/null 2>&1 && "
                "jq -r '.\"modules-left\" | length' "
                '"$XDG_RUNTIME_DIR/bubbleos/waybar/config.jsonc"',
            )
            rejected = run_as_bubble(
                vm,
                "bubble-desktop config set DESKTOP_TERMINAL '' 2>&1; "
                "echo rc=$?",
            )
            checks.append(
                (
                    "empty Waybar and screenshot values are accepted, other keys are not",
                    empty.strip().splitlines()[-1] == "0"
                    and "rc=1" in rejected,
                    empty + "\n" + rejected,
                )
            )

            applied = run_as_bubble(vm, "bubble-desktop apply 2>&1")
            checks.append(
                (
                    "bubble-desktop apply is safe outside a Wayland session",
                    "no Wayland session is running" in applied,
                    applied,
                )
            )

            run_as_bubble(vm, "bubble-desktop config reset >/dev/null 2>&1 || true")
    finally:
        cleanup(work)

    report("QEMU bubble-settings integration test", checks)


if __name__ == "__main__":
    main()
