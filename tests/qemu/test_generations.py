#!/usr/bin/env python3
"""Generation lifecycle: create, activate, explicit Limine entry and rollback."""

from common import (
    DISK_IMAGE,
    boot,
    check_sudo,
    cleanup,
    copy_image,
    report,
    require_artifacts,
    require_commands,
    set_limine_default,
    workdir,
)

GEN_ROOT = "/var/lib/bubbleos/rootfs/generations"


def run_rc(vm, command):
    """Run a guest command and return (output, exit status line)."""
    output = vm.run(f"{command} 2>&1; echo rc=$?")
    lines = output.splitlines()
    status = lines[-1] if lines else ""
    return output, status


def main() -> None:
    require_commands("qemu-system-x86_64", "cp")
    require_artifacts(DISK_IMAGE)
    check_sudo()

    work = workdir()
    checks: list[tuple[str, bool, str]] = []
    try:
        disk = copy_image(DISK_IMAGE, work / "disk.img")

        with boot(name="generations-1", disk_image=disk) as vm:
            vm.login()

            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "fresh image exposes the current generation",
                    len(menu.splitlines()) == 1
                    and "current: generation 000001" in menu,
                    menu,
                )
            )

            assets = vm.run(
                "for f in vmlinuz initramfs.cpio.gz; do "
                "test -s /var/lib/bubbleos/rootfs/generations/000001"
                "/usr/lib/bubbleos/boot/$f && echo $f:ok || echo $f:missing; "
                "done"
            )
            checks.append(
                (
                    "the generation carries its kernel and initramfs",
                    "vmlinuz:ok" in assets
                    and "initramfs.cpio.gz:ok" in assets,
                    assets,
                )
            )

            entry = vm.run(
                "grep -A4 '^/bubbleOS (current' /boot/limine.conf"
            )
            checks.append(
                (
                    "the current entry uses the shared boot pair",
                    "kernel_path: boot():/vmlinuz" in entry
                    and "module_path: boot():/initramfs.cpio.gz" in entry,
                    entry,
                )
            )

            created = vm.run(
                "bubble generation create --description 'integration test'"
            )
            checks.append(
                (
                    "create builds generation 000002",
                    "Created generation 000002" in created,
                    created,
                )
            )

            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "menu lists the new generation",
                    "current: generation 000001" in menu
                    and "generation 000002 - integration test" in menu,
                    menu,
                )
            )

            entry = vm.run(
                "grep -A4 'generation 000002 - integration test' "
                "/boot/limine.conf"
            )
            checks.append(
                (
                    "a cloned generation reuses the shared boot assets",
                    "kernel_path: boot():/vmlinuz" in entry
                    and "module_path: boot():/initramfs.cpio.gz" in entry
                    and "kernel_path: boot():/generations" not in entry
                    and "module_path: boot():/generations" not in entry,
                    entry,
                )
            )

            # Make generation 000002 carry a different initramfs so the next
            # activation has to stage private assets for generation 000001.
            vm.run(
                "printf 'distinct-initramfs\\n' >> "
                "/var/lib/bubbleos/rootfs/generations/000002"
                "/usr/lib/bubbleos/boot/initramfs.cpio.gz"
            )

            activated = vm.run("bubble generation activate 000002")
            checks.append(
                (
                    "activate selects generation 000002",
                    "Activated generation 000002" in activated,
                    activated,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                ("current is 000002 after activation", current == "000002", current)
            )

            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "menu marks 000001 as previous",
                    "current: generation 000002" in menu
                    and "generation 000001, previous" in menu,
                    menu,
                )
            )

            entry = vm.run(
                "grep -A4 'generation 000001, previous' /boot/limine.conf"
            )
            checks.append(
                (
                    "a differing generation gets private Limine assets",
                    "kernel_path: boot():/generations/000001/vmlinuz"
                    in entry
                    and "module_path: "
                    "boot():/generations/000001/initramfs.cpio.gz" in entry,
                    entry,
                )
            )

            staged = vm.run(
                "cmp -s /boot/generations/000001/vmlinuz "
                "/var/lib/bubbleos/rootfs/generations/000001"
                "/usr/lib/bubbleos/boot/vmlinuz && echo kernel-ok; "
                "cmp -s /boot/generations/000001/initramfs.cpio.gz "
                "/var/lib/bubbleos/rootfs/generations/000001"
                "/usr/lib/bubbleos/boot/initramfs.cpio.gz && echo initramfs-ok"
            )
            checks.append(
                (
                    "the staged assets match the generation",
                    "kernel-ok" in staged and "initramfs-ok" in staged,
                    staged,
                )
            )

            shared = vm.run(
                "cmp -s /boot/initramfs.cpio.gz "
                "/var/lib/bubbleos/rootfs/generations/000002"
                "/usr/lib/bubbleos/boot/initramfs.cpio.gz && echo current-ok"
            )
            checks.append(
                (
                    "the shared pair follows the current generation",
                    shared == "current-ok",
                    shared,
                )
            )

        # The next boot must use entry 2, which pins generation 000001 through
        # rootflags=subvol=..., while @rootfs/current still selects 000002.
        set_limine_default(disk, 2)

        with boot(name="generations-2", disk_image=disk) as vm:
            vm.login()

            checks.append(
                (
                    "explicit entry passed rootflags to the initramfs",
                    "trying requested subvolume @rootfs/generations/000001"
                    in vm.boot_log,
                    vm.boot_log,
                )
            )
            generation = vm.run("sed -n 's/^GENERATION=//p' /etc/bubbleos/generation")
            checks.append(
                (
                    "explicit entry boots generation 000001",
                    generation == "000001",
                    generation,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                (
                    "current still selects 000002 while 000001 is booted",
                    current == "000002",
                    current,
                )
            )

            rolled_back = vm.run("bubble rollback")
            checks.append(
                (
                    "rollback selects generation 000001",
                    "Activated generation 000001" in rolled_back,
                    rolled_back,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                ("current is 000001 after rollback", current == "000001", current)
            )

            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "menu marks 000002 as previous after rollback",
                    "current: generation 000001" in menu
                    and "generation 000002, previous" in menu,
                    menu,
                )
            )

            entry = vm.run(
                "grep -A4 'generation 000002, previous' /boot/limine.conf"
            )
            checks.append(
                (
                    "rollback points the old generation at its own assets",
                    "kernel_path: boot():/generations/000002/vmlinuz"
                    in entry
                    and "module_path: "
                    "boot():/generations/000002/initramfs.cpio.gz" in entry,
                    entry,
                )
            )

            shared = vm.run(
                "cmp -s /boot/initramfs.cpio.gz "
                "/var/lib/bubbleos/rootfs/generations/000001"
                "/usr/lib/bubbleos/boot/initramfs.cpio.gz && echo current-ok"
            )
            checks.append(
                (
                    "rollback refreshes the shared pair from the new current",
                    shared == "current-ok",
                    shared,
                )
            )

            staged = vm.run(
                "test -s /boot/generations/000002/initramfs.cpio.gz "
                "&& echo staged; "
                "test ! -d /boot/generations/000001 && echo pruned"
            )
            checks.append(
                (
                    "staged assets follow the generation switches",
                    "staged" in staged and "pruned" in staged,
                    staged,
                )
            )

        with boot(name="generations-3", disk_image=disk) as vm:
            vm.login()

            generation = vm.run("sed -n 's/^GENERATION=//p' /etc/bubbleos/generation")
            checks.append(
                (
                    "default entry follows current after rollback",
                    generation == "000001",
                    generation,
                )
            )
            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed across generation switches",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )

            protected, status = run_rc(
                vm, "bubble generation delete 000001"
            )
            checks.append(
                (
                    "the current and running generation cannot be deleted",
                    status == "rc=1"
                    and "current generation" in protected
                    and "running generation" in protected,
                    protected,
                )
            )
            protected, status = run_rc(
                vm, "bubble generation delete 000002"
            )
            checks.append(
                (
                    "the previous generation cannot be deleted",
                    status == "rc=1" and "previous generation" in protected,
                    protected,
                )
            )

            created = vm.run(
                "bubble generation create --description 'delete test'"
            )
            checks.append(
                (
                    "delete test creates generation 000003",
                    "Created generation 000003" in created,
                    created,
                )
            )
            vm.run(
                "printf 'delete-test-initramfs\\n' >> "
                f"{GEN_ROOT}/000003/usr/lib/bubbleos/boot/initramfs.cpio.gz && "
                "bubble bootloader sync"
            )
            staged = vm.run(
                "test -s /boot/generations/000003/initramfs.cpio.gz "
                "&& echo staged"
            )
            checks.append(
                (
                    "the delete candidate has private ESP assets",
                    staged == "staged",
                    staged,
                )
            )

            deleted, status = run_rc(vm, "bubble generation delete 000003")
            cleaned = vm.run(
                f"test ! -d {GEN_ROOT}/000003 && echo subvol-gone; "
                "test ! -d /boot/generations/000003 && echo esp-clean; "
                "grep -q 'generation 000003' /boot/limine.conf "
                "&& echo menu-stale || echo menu-clean"
            )
            checks.append(
                (
                    "delete removes the generation, its ESP assets and menu entry",
                    "Deleted generation 000003" in deleted
                    and status == "rc=0"
                    and "subvol-gone" in cleaned
                    and "esp-clean" in cleaned
                    and "menu-clean" in cleaned,
                    deleted + "\n" + cleaned,
                )
            )

            # Deleting the newest generation lets the numbering reuse 000003.
            vm.run(
                "bubble generation create --description 'prune three' && "
                "printf 'prune-three-initramfs\\n' >> "
                f"{GEN_ROOT}/000003/usr/lib/bubbleos/boot/initramfs.cpio.gz && "
                "bubble bootloader sync"
            )
            staged = vm.run(
                "test -s /boot/generations/000003/initramfs.cpio.gz "
                "&& echo staged"
            )
            checks.append(
                (
                    "the prune candidate has private ESP assets",
                    staged == "staged",
                    staged,
                )
            )
            vm.run("bubble generation create --description 'prune four'")
            vm.run("bubble generation create --description 'prune five'")

            dry_run, status = run_rc(
                vm, "bubble generation prune --keep 2 --dry-run"
            )
            kept = vm.run(
                f"test -d {GEN_ROOT}/000003 && echo kept"
            )
            checks.append(
                (
                    "prune dry-run reports the old generation and deletes nothing",
                    status == "rc=0"
                    and "would delete generation 000003" in dry_run
                    and "would delete generation 000004" not in dry_run
                    and "would delete generation 000005" not in dry_run
                    and kept == "kept",
                    dry_run + "\n" + kept,
                )
            )

            pruned, status = run_rc(
                vm, "bubble generation prune --keep 2"
            )
            state = vm.run(
                f"test ! -d {GEN_ROOT}/000003 && echo three-gone; "
                f"test -d {GEN_ROOT}/000004 && echo four-kept; "
                f"test -d {GEN_ROOT}/000005 && echo five-kept; "
                f"test -d {GEN_ROOT}/000001 && echo current-kept; "
                f"test -d {GEN_ROOT}/000002 && echo previous-kept; "
                "test ! -d /boot/generations/000003 && echo esp-clean"
            )
            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "prune deletes old generations and their ESP assets",
                    status == "rc=0"
                    and "Deleted generation 000003" in pruned
                    and "Deleted generation 000004" not in pruned
                    and "three-gone" in state
                    and "four-kept" in state
                    and "five-kept" in state
                    and "current-kept" in state
                    and "previous-kept" in state
                    and "esp-clean" in state
                    and "generation 000003" not in menu,
                    pruned + "\n" + state + "\n" + menu,
                )
            )
    finally:
        cleanup(work)

    report("QEMU generation lifecycle test", checks)


if __name__ == "__main__":
    main()
