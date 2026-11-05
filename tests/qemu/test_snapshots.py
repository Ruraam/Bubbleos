#!/usr/bin/env python3
"""Snapshot lifecycle: /var restore across reboot and snapshot pruning."""

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

        with boot(name="snapshots-1", disk_image=disk) as vm:
            vm.login()

            vm.run(
                "mkdir -p /var/lib/bubbleos && "
                "printf 'restored\\n' > /var/lib/bubbleos/var-restore-test"
            )
            created = vm.run(
                "bubble generation create --description 'snapshot test'"
            )
            checks.append(
                (
                    "create builds generation 000002",
                    "Created generation 000002" in created,
                    created,
                )
            )
            activated = vm.run("bubble generation activate 000002")
            checks.append(
                (
                    "activate selects generation 000002",
                    "Activated generation 000002" in activated,
                    activated,
                )
            )

            snapshots = vm.run("bubble snapshots")
            before_two = ""
            for line in snapshots.splitlines():
                if line.startswith("var/") and line.endswith("-before-000002"):
                    before_two = line.split("/", 1)[1]
            checks.append(
                (
                    "activation snapshots /var before the switch",
                    bool(before_two),
                    snapshots,
                )
            )

            # Fabricate two old restore points to exercise pruning. The real
            # pre-activation snapshot must be the newest one and must survive.
            vm.run(
                "btrfs subvolume snapshot -r /var "
                "/snapshots/var/20200101T000000Z-before-000001"
            )
            vm.run(
                "btrfs subvolume snapshot -r /var "
                "/snapshots/var/20200102T000000Z-before-000001"
            )
            pruned = vm.run("bubble snapshots prune --keep 1")
            checks.append(
                (
                    "prune deletes the oldest automatic snapshots",
                    "deleted var/20200101T000000Z-before-000001" in pruned
                    and "deleted var/20200102T000000Z-before-000001" in pruned,
                    pruned,
                )
            )
            kept = vm.run(
                "for p in "
                "/snapshots/var/000001-initial "
                f"/snapshots/var/{before_two}; do "
                "test -d \"$p\" && echo kept:$p || echo missing:$p; done"
            )
            checks.append(
                (
                    "prune keeps the initial and newest snapshots",
                    f"kept:/snapshots/var/{before_two}" in kept
                    and "kept:/snapshots/var/000001-initial" in kept,
                    kept,
                )
            )

            # Creating and activating another generation must prune the older
            # automatic snapshot without touching the initial restore point.
            created = vm.run(
                "bubble generation create --description 'auto prune test'"
            )
            checks.append(
                (
                    "create builds generation 000003",
                    "Created generation 000003" in created,
                    created,
                )
            )
            activated = vm.run(
                "BUBBLEOS_SNAPSHOT_KEEP=1 bubble generation activate 000003"
            )
            checks.append(
                (
                    "activation with keep=1 succeeds",
                    "Activated generation 000003" in activated,
                    activated,
                )
            )
            snapshots = vm.run("bubble snapshots")
            snapshot = ""
            for line in snapshots.splitlines():
                if line.startswith("var/") and line.endswith("-before-000003"):
                    snapshot = line.split("/", 1)[1]
            checks.append(
                (
                    "automatic prune keeps only the newest snapshot",
                    bool(snapshot)
                    and f"var/{before_two}" not in snapshots
                    and "var/000001-initial" in snapshots,
                    snapshots,
                )
            )

            rejected = vm.run(
                "bubble snapshots restore 999999-missing 2>&1; echo rc=$?"
            )
            checks.append(
                (
                    "unknown snapshot is rejected",
                    "rc=1" in rejected
                    and "snapshot does not exist" in rejected,
                    rejected,
                )
            )
            marker = vm.run(
                "test -e /snapshots/var-restore.request && echo present || echo absent"
            )
            checks.append(
                (
                    "rejected restore writes no request",
                    marker == "absent",
                    marker,
                )
            )

            scheduled = vm.run(f"bubble snapshots restore var/{snapshot}")
            checks.append(
                (
                    "restore is scheduled for the next boot",
                    "scheduled for the next boot" in scheduled,
                    scheduled,
                )
            )
            request = vm.run("cat /snapshots/var-restore.request")
            checks.append(
                (
                    "restore request records the snapshot",
                    f"SNAPSHOT={snapshot}" in request,
                    request,
                )
            )

            protected = vm.run("bubble snapshots prune --keep 0 2>&1")
            checks.append(
                (
                    "prune keeps the pending restore point",
                    "keeping pending restore point" in protected,
                    protected,
                )
            )
            still_there = vm.run(
                f"test -d /snapshots/var/{snapshot} && echo kept || echo missing"
            )
            checks.append(
                (
                    "pending snapshot survives an aggressive prune",
                    still_there == "kept",
                    still_there,
                )
            )

            vm.run(
                "rm -f /var/lib/bubbleos/var-restore-test && "
                "printf 'after\\n' > /var/lib/bubbleos/var-restore-after"
            )

        with boot(name="snapshots-2", disk_image=disk) as vm:
            vm.login()

            marker = vm.run(
                "test -e /snapshots/var-restore.request && echo present || echo absent"
            )
            checks.append(
                (
                    "restore request is consumed at boot",
                    marker == "absent",
                    marker,
                )
            )

            content = vm.run(
                "cat /var/lib/bubbleos/var-restore-test 2>/dev/null || echo missing"
            )
            checks.append(
                (
                    "restored /var contains the snapshotted file",
                    content == "restored",
                    content,
                )
            )
            after = vm.run(
                "test -e /var/lib/bubbleos/var-restore-after && echo present || echo absent"
            )
            checks.append(
                (
                    "post-snapshot changes are discarded",
                    after == "absent",
                    after,
                )
            )

            safety = vm.run(
                "find /snapshots/var -mindepth 1 -maxdepth 1 -type d "
                "-name '*-pre-restore*' -printf '%f\\n' | LC_ALL=C sort | tail -1"
            )
            checks.append(
                (
                    "a safety snapshot of the replaced /var exists",
                    bool(safety),
                    safety,
                )
            )

            service = vm.run(
                "systemctl is-active bubbleos-var-restore.service"
            )
            checks.append(
                (
                    "restore unit completed successfully",
                    service == "active",
                    service,
                )
            )
            logs = vm.run(
                "journalctl -b -u bubbleos-var-restore.service --no-pager"
            )
            checks.append(
                (
                    "journal records the /var restore",
                    "restored /var from" in logs,
                    logs,
                )
            )

            writable = vm.run(
                "touch /var/lib/bubbleos/var-restore-writable && echo writable"
            )
            checks.append(
                (
                    "restored /var is writable",
                    writable == "writable",
                    writable,
                )
            )

            leftover = vm.run(
                "mountpoint -q /run/bubbleos/var-restore "
                "&& echo mounted || echo unmounted"
            )
            checks.append(
                (
                    "the temporary top-level mount is released",
                    leftover == "unmounted",
                    leftover,
                )
            )

            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed after the restore",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )
            state = vm.run("systemctl is-system-running")
            checks.append(
                ("systemd is running after the restore", state == "running", state)
            )
    finally:
        cleanup(work)

    report("QEMU snapshot restore test", checks)


if __name__ == "__main__":
    main()
