#!/usr/bin/env python3
"""Legacy BIOS boot: Limine MBR stages, SeaBIOS and the same RootFS."""

from common import (
    DISK_IMAGE,
    boot,
    check_sudo,
    cleanup,
    copy_image,
    kernel_release,
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
        with boot(name="bios", disk_image=disk, uefi=False) as vm:
            vm.login()

            release = vm.run("uname -r")
            expected_release = kernel_release()
            checks.append(
                (
                    "legacy BIOS boots the same kernel",
                    expected_release is None or release == expected_release,
                    f"expected {expected_release!r}, got {release!r}",
                )
            )

            cmdline = vm.run("cat /proc/cmdline")
            checks.append(
                (
                    "BIOS boot resolves the root by UUID",
                    "root=UUID=" in cmdline and "selinux=0" in cmdline,
                    cmdline,
                )
            )

            root = vm.run("findmnt -no FSTYPE,FSROOT /")
            checks.append(
                (
                    "BIOS boot mounts the Btrfs generation subvolume",
                    root.startswith("btrfs")
                    and "/@rootfs/generations/000001" in root,
                    root,
                )
            )

            generation = vm.run("bubble generation current")
            checks.append(
                ("generation marker is 000001", generation == "000001", generation)
            )

            signature = vm.run(
                "dd if=/dev/vda bs=1 skip=510 count=2 2>/dev/null "
                "| od -An -tx1 | tr -d ' \\n'"
            )
            checks.append(
                (
                    "disk MBR carries the Limine boot signature",
                    signature.strip() == "55aa",
                    signature,
                )
            )

            mbr_code = vm.run(
                "dd if=/dev/vda bs=1 count=16 2>/dev/null "
                "| od -An -tx1 | tr -d ' \\n'"
            )
            checks.append(
                (
                    "the MBR boots through Limine BIOS stage 1",
                    mbr_code.strip() not in ("", "0" * 32),
                    mbr_code,
                )
            )

            bios_sys = vm.run(
                "test -s /boot/limine-bios.sys && echo ok || echo missing"
            )
            checks.append(
                (
                    "limine-bios.sys is on the ESP",
                    bios_sys.strip() == "ok",
                    bios_sys,
                )
            )

            htop = vm.run("command -v htop >/dev/null 2>&1 && echo ok || echo missing")
            checks.append(
                ("tty task manager works after BIOS boot", htop.strip() == "ok", htop)
            )
    finally:
        cleanup(work)

    report("QEMU legacy BIOS boot test", checks)


if __name__ == "__main__":
    main()
