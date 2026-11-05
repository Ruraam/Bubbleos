#!/usr/bin/env python3
"""Initramfs fallback: broken current link and missing explicit subvolume."""

from common import (
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


def main() -> None:
    require_commands("qemu-system-x86_64", "cp")
    require_artifacts(DISK_IMAGE)
    check_sudo()

    work = workdir()
    checks: list[tuple[str, bool, str]] = []
    try:
        disk = copy_image(DISK_IMAGE, work / "disk.img")

        with boot(name="fallback-break", disk_image=disk) as vm:
            vm.login()
            vm.run(
                "ln -sfn generations/999999 "
                "/var/lib/bubbleos/rootfs/current"
            )
            link = vm.run("readlink /var/lib/bubbleos/rootfs/current")
            checks.append(
                (
                    "current link points to a missing generation",
                    link == "generations/999999",
                    link,
                )
            )

        with boot(name="fallback-newest", disk_image=disk) as vm:
            vm.login()
            checks.append(
                (
                    "broken current falls back to the newest generation",
                    "trying fallback subvolume "
                    "@rootfs/generations/000001" in vm.boot_log,
                    vm.boot_log,
                )
            )
            generation = vm.run("sed -n 's/^GENERATION=//p' /etc/bubbleos/generation")
            checks.append(
                (
                    "system boots generation 000001 after the broken link",
                    generation == "000001",
                    generation,
                )
            )
            vm.run(
                "ln -sfn generations/000001 /var/lib/bubbleos/rootfs/current"
            )
            link = vm.run("readlink /var/lib/bubbleos/rootfs/current")
            checks.append(
                (
                    "current link can be repaired from the booted system",
                    link == "generations/000001",
                    link,
                )
            )

        with boot(
            name="fallback-missing",
            root_image=disk,
            root_device="/dev/vda2",
            append_extra="rootflags=subvol=@rootfs/generations/999999",
        ) as vm:
            vm.login()
            checks.append(
                (
                    "missing rootflags subvolume is reported",
                    "trying requested subvolume "
                    "@rootfs/generations/999999" in vm.boot_log,
                    vm.boot_log,
                )
            )
            checks.append(
                (
                    "missing rootflags subvolume falls back to current",
                    "generation fallback: @rootfs/generations/000001"
                    in vm.boot_log,
                    vm.boot_log,
                )
            )
            generation = vm.run("sed -n 's/^GENERATION=//p' /etc/bubbleos/generation")
            checks.append(
                (
                    "fallback boot reaches generation 000001",
                    generation == "000001",
                    generation,
                )
            )
            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed after fallback",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )
            state = vm.run("systemctl is-system-running")
            checks.append(("systemd is running after fallback", state == "running", state))
    finally:
        cleanup(work)

    report("QEMU initramfs fallback test", checks)


if __name__ == "__main__":
    main()
