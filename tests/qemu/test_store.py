#!/usr/bin/env python3
"""System package store: import, generation composition, upgrade/remove/rollback."""

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


def run_rc(vm, command):
    """Run a guest command and return (output, exit status line)."""
    output = vm.run(f"{command} 2>&1; echo rc=$?")
    lines = output.splitlines()
    status = lines[-1] if lines else ""
    return output, status


GEN_ROOT = "/var/lib/bubbleos/rootfs/generations"


def main() -> None:
    require_commands("qemu-system-x86_64", "cp")
    require_artifacts(DISK_IMAGE)
    check_sudo()

    work = workdir()
    checks: list[tuple[str, bool, str]] = []
    try:
        disk = copy_image(DISK_IMAGE, work / "disk.img")

        with boot(name="store-1", disk_image=disk) as vm:
            vm.login()

            listing = vm.run("ulpm store list")
            checks.append(
                (
                    "the system store starts empty",
                    "System store is empty" in listing,
                    listing,
                )
            )
            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the bootstrap generation has no store packages",
                    "No store packages in generation 000001" in packages,
                    packages,
                )
            )

            packed = vm.run(
                "rm -rf /tmp/pkg-store-v1 /tmp/pkg-store-v1.lpk && "
                "mkdir -p /tmp/pkg-store-v1/etc "
                "/tmp/pkg-store-v1/usr/bin "
                "/tmp/pkg-store-v1/usr/share/bubbleos/store && "
                "printf 'NAME=bubble-store-test\\n' "
                "> /tmp/pkg-store-v1/etc/bubble-store-v1.conf && "
                "printf '#!/bin/sh\\necho store-v1\\n' "
                "> /tmp/pkg-store-v1/usr/bin/bubble-store-test && "
                "chmod 755 /tmp/pkg-store-v1/usr/bin/bubble-store-test && "
                "printf 'v1-only\\n' "
                "> /tmp/pkg-store-v1/usr/share/bubbleos/store/v1-only && "
                "ulpm pack /tmp/pkg-store-v1 bubble-store-test "
                "/tmp/pkg-store-v1.lpk 1.0.0 2>&1; echo rc=$?"
            )
            checks.append(
                (
                    "a rootfs LPK is packed as a system package",
                    "RootFS payload detected" in packed
                    and "rc=0" in packed,
                    packed,
                )
            )

            installed, status = run_rc(
                vm, "bubble install /tmp/pkg-store-v1.lpk"
            )
            checks.append(
                (
                    "install composes and activates generation 000002",
                    "Installed packages in generation 000002; activated"
                    in installed
                    and status == "rc=0",
                    installed,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                ("generation 000002 is selected", current == "000002", current)
            )

            binary = vm.run(
                f"{GEN_ROOT}/000002/usr/bin/bubble-store-test"
            )
            checks.append(
                (
                    "the package payload is present in the composed generation",
                    binary == "store-v1",
                    binary,
                )
            )
            payload = vm.run(
                f"test -f {GEN_ROOT}/000002/usr/share/bubbleos/store/v1-only "
                "&& echo present"
            )
            checks.append(
                ("the package data file is staged", payload == "present", payload)
            )

            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the package lock lists the installed version",
                    "io.lpk.bubble-store-test" in packages
                    and "1.0.0" in packages
                    and "rootfs" in packages,
                    packages,
                )
            )

            lock = vm.run(
                "jq -r '.base_generation + \" \" + "
                "((.packages | length) | tostring)' "
                "/var/lib/bubbleos/rootfs/generations/000002"
                "/etc/bubbleos/packages.json"
            )
            checks.append(
                (
                    "the generation is based on package-free generation 000001",
                    lock == "000001 1",
                    lock,
                )
            )

            store = vm.run("ulpm store list")
            checks.append(
                (
                    "the store indexes the package digest",
                    "io.lpk.bubble-store-test" in store
                    and "1.0.0" in store
                    and "rootfs" in store,
                    store,
                )
            )

            menu = vm.run("grep '^/bubbleOS' /boot/limine.conf")
            checks.append(
                (
                    "Limine lists the composed generation",
                    "current: generation 000002" in menu
                    and "generation 000001" in menu,
                    menu,
                )
            )

            packed = vm.run(
                "rm -rf /tmp/pkg-store-v2 /tmp/pkg-store-v2.lpk && "
                "mkdir -p /tmp/pkg-store-v2/etc "
                "/tmp/pkg-store-v2/usr/bin "
                "/tmp/pkg-store-v2/usr/share/bubbleos/store && "
                "printf 'NAME=bubble-store-test\\n' "
                "> /tmp/pkg-store-v2/etc/bubble-store-v2.conf && "
                "printf '#!/bin/sh\\necho store-v2\\n' "
                "> /tmp/pkg-store-v2/usr/bin/bubble-store-test && "
                "chmod 755 /tmp/pkg-store-v2/usr/bin/bubble-store-test && "
                "printf 'v2-only\\n' "
                "> /tmp/pkg-store-v2/usr/share/bubbleos/store/v2-only && "
                "ulpm pack /tmp/pkg-store-v2 bubble-store-test "
                "/tmp/pkg-store-v2.lpk 2.0.0 2>&1; echo rc=$?"
            )
            checks.append(
                ("the second package version is packed", "rc=0" in packed, packed)
            )

            upgraded, status = run_rc(
                vm, "bubble install /tmp/pkg-store-v2.lpk"
            )
            checks.append(
                (
                    "upgrading builds a new generation from the base",
                    "Installed packages in generation 000003; activated"
                    in upgraded
                    and status == "rc=0",
                    upgraded,
                )
            )
            binary = vm.run(
                f"{GEN_ROOT}/000003/usr/bin/bubble-store-test"
            )
            checks.append(
                ("the upgraded payload replaces the old files", binary == "store-v2", binary)
            )
            stale = vm.run(
                f"test -e {GEN_ROOT}/000003/usr/share/bubbleos/store/v1-only "
                "&& echo stale || echo clean"
            )
            checks.append(
                (
                    "files removed from the new package version do not linger",
                    stale == "clean",
                    stale,
                )
            )
            fresh = vm.run(
                f"test -f {GEN_ROOT}/000003/usr/share/bubbleos/store/v2-only "
                "&& echo present"
            )
            checks.append(
                ("the new package data file is staged", fresh == "present", fresh)
            )
            packages = vm.run("bubble packages --generation 000003")
            checks.append(
                (
                    "the lock pins the upgraded version",
                    "2.0.0" in packages and "1.0.0" not in packages,
                    packages,
                )
            )

            dep_packed = vm.run(
                "rm -rf /tmp/pkg-store-dep /tmp/pkg-store-dep.lpk && "
                "mkdir -p /tmp/pkg-store-dep/etc "
                "/tmp/pkg-store-dep/usr/bin && "
                "printf 'NAME=bubble-store-dep\\n' "
                "> /tmp/pkg-store-dep/etc/bubble-store-dep.conf && "
                "printf '#!/bin/sh\\necho store-dep\\n' "
                "> /tmp/pkg-store-dep/usr/bin/bubble-store-dep && "
                "chmod 755 /tmp/pkg-store-dep/usr/bin/bubble-store-dep && "
                "ulpm pack /tmp/pkg-store-dep bubble-store-dep "
                "/tmp/pkg-store-dep.lpk 1.0.0 2>&1; echo rc=$?"
            )
            consumer_packed = vm.run(
                "rm -rf /tmp/pkg-store-consumer "
                "/tmp/pkg-store-consumer.lpk && "
                "mkdir -p /tmp/pkg-store-consumer/etc "
                "/tmp/pkg-store-consumer/usr/bin && "
                "printf 'NAME=bubble-store-consumer\\n' "
                "> /tmp/pkg-store-consumer/etc/bubble-store-consumer.conf && "
                "printf '#!/bin/sh\\necho store-consumer\\n' "
                "> /tmp/pkg-store-consumer/usr/bin/bubble-store-consumer && "
                "chmod 755 /tmp/pkg-store-consumer/usr/bin/bubble-store-consumer && "
                "ulpm pack --dependency io.lpk.bubble-store-dep "
                "/tmp/pkg-store-consumer bubble-store-consumer "
                "/tmp/pkg-store-consumer.lpk 1.0.0 2>&1; echo rc=$?"
            )
            checks.append(
                (
                    "the dependency test packages are packed",
                    "rc=0" in dep_packed and "rc=0" in consumer_packed,
                    dep_packed + "\n" + consumer_packed,
                )
            )

            failed, status = run_rc(
                vm, "bubble install /tmp/pkg-store-consumer.lpk"
            )
            checks.append(
                (
                    "a package with an unsatisfied dependency is rejected",
                    "Missing dependency" in failed and status != "rc=0",
                    failed,
                )
            )
            current = vm.run("bubble generation current")
            generations = vm.run("bubble generations")
            checks.append(
                (
                    "the rejected install does not create a generation",
                    current == "000003" and len(generations.splitlines()) == 3,
                    current + "\n" + generations,
                )
            )

            installed, status = run_rc(
                vm,
                "bubble install /tmp/pkg-store-dep.lpk "
                "/tmp/pkg-store-consumer.lpk",
            )
            checks.append(
                (
                    "installing a closed dependency set succeeds",
                    "Installed packages in generation 000004; activated"
                    in installed
                    and status == "rc=0",
                    installed,
                )
            )
            both = vm.run(
                f"test -x {GEN_ROOT}/000004/usr/bin/bubble-store-dep "
                "&& echo dep-ok; "
                f"test -x {GEN_ROOT}/000004/usr/bin/bubble-store-consumer "
                "&& echo consumer-ok"
            )
            checks.append(
                (
                    "both dependency packages are composed",
                    "dep-ok" in both and "consumer-ok" in both,
                    both,
                )
            )

            blocked, status = run_rc(
                vm, "bubble remove io.lpk.bubble-store-dep"
            )
            checks.append(
                (
                    "removing a required dependency is rejected",
                    "Missing dependency" in blocked and status != "rc=0",
                    blocked,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                ("the rejected removal leaves the generation selected", current == "000004", current)
            )

            removed, status = run_rc(
                vm, "bubble remove io.lpk.bubble-store-consumer"
            )
            checks.append(
                (
                    "removing a package composes a new generation",
                    "Removed package in generation 000005; activated"
                    in removed
                    and status == "rc=0",
                    removed,
                )
            )
            gone = vm.run(
                f"test -e {GEN_ROOT}/000005/usr/bin/bubble-store-consumer "
                "&& echo present || echo removed; "
                f"test -x {GEN_ROOT}/000005/usr/bin/bubble-store-dep "
                "&& echo dep-present"
            )
            checks.append(
                (
                    "the removed package files are gone and dependencies remain",
                    "removed" in gone and "dep-present" in gone,
                    gone,
                )
            )

            removed, status = run_rc(
                vm, "bubble remove io.lpk.bubble-store-dep"
            )
            checks.append(
                (
                    "the last dependency can be removed",
                    "Removed package in generation 000006; activated"
                    in removed
                    and status == "rc=0",
                    removed,
                )
            )
            final_packages = vm.run("bubble packages")
            checks.append(
                (
                    "only the unrelated package remains installed",
                    "io.lpk.bubble-store-test" in final_packages
                    and "2.0.0" in final_packages
                    and "bubble-store-dep" not in final_packages
                    and "bubble-store-consumer" not in final_packages,
                    final_packages,
                )
            )

            protected, status = run_rc(
                vm, "bubble generation delete 000001"
            )
            checks.append(
                (
                    "a generation used as the composition base cannot be deleted",
                    status == "rc=1" and "base generation" in protected,
                    protected,
                )
            )

            v1_digest = vm.run(
                "basename \"$(readlink "
                "/var/lib/bubbleos/store/packages/"
                "io.lpk.bubble-store-test/1.0.0)\""
            )
            v2_digest = vm.run(
                "basename \"$(readlink "
                "/var/lib/bubbleos/store/packages/"
                "io.lpk.bubble-store-test/2.0.0)\""
            )
            checks.append(
                (
                    "the store exposes digests for both package versions",
                    len(v1_digest) == 64
                    and len(v2_digest) == 64
                    and v1_digest != v2_digest,
                    v1_digest + "\n" + v2_digest,
                )
            )

            removed, status = run_rc(
                vm,
                "bubble store remove io.lpk.bubble-store-test=1.0.0 --gc",
            )
            kept = vm.run(
                f"test -d /var/lib/bubbleos/store/objects/{v1_digest} "
                "&& echo kept || echo missing"
            )
            checks.append(
                (
                    "gc keeps an object pinned by a generation lock",
                    status == "rc=0"
                    and "Removed store package" in removed
                    and kept == "kept",
                    removed + "\n" + kept,
                )
            )

            deleted, status = run_rc(
                vm, "bubble generation delete 000002"
            )
            checks.append(
                (
                    "an old composed generation can be deleted",
                    status == "rc=0"
                    and "Deleted generation 000002" in deleted,
                    deleted,
                )
            )

            collected = vm.run(
                f"bubble store gc; "
                f"test ! -d /var/lib/bubbleos/store/objects/{v1_digest} "
                "&& echo collected || echo retained; "
                f"test -d /var/lib/bubbleos/store/objects/{v2_digest} "
                "&& echo v2-kept"
            )
            checks.append(
                (
                    "gc drops the object once its last generation is deleted",
                    "collected" in collected
                    and "retained" not in collected
                    and "v2-kept" in collected,
                    collected,
                )
            )

            app_packed = vm.run(
                "rm -rf /tmp/pkg-store-app /tmp/pkg-store-app.lpk && "
                "mkdir -p /tmp/pkg-store-app && "
                "printf '#!/bin/sh\\necho app\\n' > /tmp/pkg-store-app/AppRun && "
                "chmod 755 /tmp/pkg-store-app/AppRun && "
                "ulpm pack /tmp/pkg-store-app bubble-store-app "
                "/tmp/pkg-store-app.lpk 1.0.0 2>&1; echo rc=$?"
            )
            app_failed, status = run_rc(
                vm, "bubble install /tmp/pkg-store-app.lpk"
            )
            checks.append(
                (
                    "an application LPK is rejected by the system store",
                    "not a system package" in app_failed
                    and status != "rc=0",
                    app_failed,
                )
            )

            tampered = vm.run(
                "cp /tmp/pkg-store-v2.lpk /tmp/pkg-store-tampered.lpk && "
                "size=$(stat -c %s /tmp/pkg-store-tampered.lpk) && "
                "printf 'X' | dd of=/tmp/pkg-store-tampered.lpk bs=1 "
                "seek=$((size / 2)) conv=notrunc status=none && "
                "bubble install /tmp/pkg-store-tampered.lpk 2>&1; echo rc=$?"
            )
            checks.append(
                (
                    "a tampered package is rejected by the signature check",
                    "rc=0" not in tampered.splitlines()[-1]
                    and ("tampered" in tampered.lower() or "signature" in tampered.lower()),
                    tampered,
                )
            )

            unused_packed = vm.run(
                "rm -rf /tmp/pkg-store-unused /tmp/pkg-store-unused.lpk && "
                "mkdir -p /tmp/pkg-store-unused/etc "
                "/tmp/pkg-store-unused/usr/bin && "
                "printf 'NAME=bubble-store-unused\\n' "
                "> /tmp/pkg-store-unused/etc/bubble-store-unused.conf && "
                "printf '#!/bin/sh\\necho unused\\n' "
                "> /tmp/pkg-store-unused/usr/bin/bubble-store-unused && "
                "chmod 755 /tmp/pkg-store-unused/usr/bin/bubble-store-unused && "
                "ulpm pack /tmp/pkg-store-unused bubble-store-unused "
                "/tmp/pkg-store-unused.lpk 1.0.0 2>&1; echo rc=$?"
            )
            stored, status = run_rc(
                vm, "bubble store add /tmp/pkg-store-unused.lpk"
            )
            checks.append(
                (
                    "store add imports a package without composing",
                    "available in the system store" in stored
                    and status == "rc=0",
                    stored,
                )
            )
            shown = vm.run(
                "bubble store show io.lpk.bubble-store-unused=1.0.0 | "
                "jq -r '.id + \" \" + .version'"
            )
            checks.append(
                (
                    "store show exposes the stored manifest",
                    shown == "io.lpk.bubble-store-unused 1.0.0",
                    shown,
                )
            )
            store_removed, status = run_rc(
                vm,
                "bubble store remove io.lpk.bubble-store-unused=1.0.0 --gc",
            )
            store_list = vm.run("ulpm store list")
            checks.append(
                (
                    "store remove and gc drop the unused package",
                    "Removed store package" in store_removed
                    and status == "rc=0"
                    and "bubble-store-unused" not in store_list,
                    store_removed + "\n" + store_list,
                )
            )

            failed_units = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed during store composition",
                    "0 loaded units listed" in failed_units,
                    failed_units,
                )
            )

        with boot(name="store-2", disk_image=disk) as vm:
            vm.login()

            generation = vm.run(
                "sed -n 's/^GENERATION=//p' /etc/bubbleos/generation"
            )
            checks.append(
                (
                    "the composed generation boots",
                    generation == "000006",
                    generation,
                )
            )
            binary = vm.run("/usr/bin/bubble-store-test")
            checks.append(
                (
                    "the package payload survives a reboot",
                    binary == "store-v2",
                    binary,
                )
            )
            stale = vm.run(
                "test -e /usr/share/bubbleos/store/v1-only && echo stale || echo clean"
            )
            checks.append(
                (
                    "the upgraded generation stays free of stale files",
                    stale == "clean",
                    stale,
                )
            )
            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the package lock survives a reboot",
                    "io.lpk.bubble-store-test" in packages
                    and "2.0.0" in packages,
                    packages,
                )
            )
            dep_gone = vm.run(
                "test -e /usr/bin/bubble-store-dep && echo present || echo absent"
            )
            checks.append(
                (
                    "removed dependency files stay removed",
                    dep_gone == "absent",
                    dep_gone,
                )
            )

            rolled = vm.run("bubble rollback")
            checks.append(
                (
                    "rollback selects the previous package generation",
                    "Activated generation 000005" in rolled,
                    rolled,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                ("current is 000005 after rollback", current == "000005", current)
            )

        with boot(name="store-3", disk_image=disk) as vm:
            vm.login()

            generation = vm.run(
                "sed -n 's/^GENERATION=//p' /etc/bubbleos/generation"
            )
            checks.append(
                (
                    "the rolled-back generation boots",
                    generation == "000005",
                    generation,
                )
            )
            dep = vm.run(
                "test -x /usr/bin/bubble-store-dep && echo dep-ok; "
                "test -e /usr/bin/bubble-store-consumer && echo consumer || echo no-consumer"
            )
            checks.append(
                (
                    "rollback restores the dependency package state",
                    "dep-ok" in dep and "no-consumer" in dep,
                    dep,
                )
            )
            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the rolled-back generation exposes its package lock",
                    "io.lpk.bubble-store-dep" in packages
                    and "io.lpk.bubble-store-consumer" not in packages,
                    packages,
                )
            )
            failed_units = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "systemd is healthy after store rollback",
                    "0 loaded units listed" in failed_units,
                    failed_units,
                )
            )
    finally:
        cleanup(work)

    report("QEMU system store test", checks)


if __name__ == "__main__":
    main()
