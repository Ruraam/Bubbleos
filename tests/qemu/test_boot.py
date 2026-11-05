#!/usr/bin/env python3
"""Boot smoke test: kernel, Btrfs root, /boot, systemd and package baseline."""

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
        with boot(name="boot-smoke", disk_image=disk) as vm:
            vm.login()

            release = vm.run("uname -r")
            expected_release = kernel_release()
            checks.append(
                (
                    "kernel release matches the build",
                    expected_release is None or release == expected_release,
                    f"expected {expected_release!r}, got {release!r}",
                )
            )

            cmdline = vm.run("cat /proc/cmdline")
            checks.append(
                (
                    "cmdline disables SELinux and selects root by UUID",
                    "selinux=0" in cmdline and "root=UUID=" in cmdline,
                    cmdline,
                )
            )

            boot_mount = vm.run("findmnt -no TARGET,FSTYPE,UUID /boot")
            checks.append(
                (
                    "ESP is mounted on /boot as vfat",
                    boot_mount.startswith("/boot vfat"),
                    boot_mount,
                )
            )

            generation = vm.run("sed -n 's/^GENERATION=//p' /etc/bubbleos/generation")
            checks.append(
                ("generation marker is 000001", generation == "000001", generation)
            )

            current = vm.run("bubble generation current")
            checks.append(
                ("current generation is 000001", current == "000001", current)
            )

            root_fsroot = vm.run("findmnt -no FSROOT /")
            checks.append(
                (
                    "root is a generation subvolume",
                    root_fsroot.startswith("/@rootfs/generations/"),
                    root_fsroot,
                )
            )

            root_options = vm.run("findmnt -no OPTIONS /")
            checks.append(
                (
                    "root uses zstd level 1",
                    "compress=zstd:1" in root_options,
                    root_options,
                )
            )

            snapshot_property = vm.run(
                "btrfs property get -ts /snapshots/rootfs/000001-initial ro"
            )
            checks.append(
                (
                    "initial root snapshot is read-only",
                    snapshot_property.strip() == "ro=true",
                    snapshot_property,
                )
            )

            menu_entries = vm.run("grep -c '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "Limine menu has one entry for one generation",
                    menu_entries == "1",
                    menu_entries,
                )
            )

            packets = vm.run(
                "for p in /var /snapshots /var/lib/bubbleos/rootfs; do "
                "mountpoint -q \"$p\" || echo missing:$p; done"
            )
            checks.append(
                (
                    "persistent subvolumes are mounted",
                    packets == "",
                    packets or "all mounted",
                )
            )

            apt = vm.run("test -e /usr/bin/apt && echo present || echo absent")
            checks.append(("APT is absent from the target", apt == "absent", apt))

            selinux_fs = vm.run(
                "test -e /sys/fs/selinux && echo present || echo absent"
            )
            checks.append(
                ("SELinux filesystem is not mounted", selinux_fs == "absent", selinux_fs)
            )

            policy_errors = vm.run(
                "dmesg | grep -c 'Could not open policy file' || true"
            )
            checks.append(
                (
                    "no SELinux policy error at boot",
                    policy_errors.strip() == "0",
                    policy_errors,
                )
            )

            modules = vm.run("find /lib/modules/$(uname -r) -name '*.ko*' | wc -l")
            checks.append(
                (
                    "kernel module tree is installed",
                    modules.isdigit() and int(modules) >= 100,
                    f"{modules} modules",
                )
            )

            firmware = vm.run("find /usr/lib/firmware -type f | wc -l")
            checks.append(
                (
                    "firmware tree is installed",
                    firmware.isdigit() and int(firmware) >= 1000,
                    f"{firmware} files",
                )
            )

            modprobe = vm.run("modprobe autofs4; echo rc=$?")
            checks.append(
                ("modprobe autofs4 succeeds", "rc=0" in modprobe, modprobe)
            )

            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )

            state = vm.run("systemctl is-system-running")
            checks.append(("systemd is running", state == "running", state))
    finally:
        cleanup(work)

    report("QEMU boot smoke test", checks)


if __name__ == "__main__":
    main()
