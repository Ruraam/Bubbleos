#!/usr/bin/env python3
"""ULPM MVP: diagnostics, LPK pack/inspect/install/run/remove."""

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

        with boot(name="ulpm", disk_image=disk) as vm:
            vm.login()

            version = vm.run("ulpm --version")
            checks.append(
                ("ulpm reports its version", "6.0.0" in version, version)
            )

            doctor = vm.run("ulpm doctor")
            checks.append(
                (
                    "all critical ULPM tools are present",
                    "All critical tools present" in doctor,
                    doctor,
                )
            )
            bwrap_line = next(
                (
                    line
                    for line in doctor.splitlines()
                    if "Bubblewrap Sandbox Engine" in line
                ),
                "",
            )
            checks.append(
                (
                    "bubblewrap sandbox is usable",
                    bool(bwrap_line) and "FAIL" not in bwrap_line,
                    bwrap_line or doctor,
                )
            )

            vm.run(
                "mkdir -p /tmp/hello && "
                "printf '%s\\n' '#!/usr/bin/env bash' "
                "'echo \"Hello from ULPM!\"' 'echo \"Args: $*\"' "
                "> /tmp/hello/AppRun && chmod +x /tmp/hello/AppRun"
            )
            packed = vm.run(
                "ulpm pack /tmp/hello hello /tmp/hello.lpk 1.0.0 2>&1; echo rc=$?"
            )
            checks.append(
                ("ulpm pack builds an LPK", "rc=0" in packed, packed)
            )
            package = vm.run(
                "test -s /tmp/hello.lpk && echo present || echo missing"
            )
            checks.append(
                ("the LPK file exists", package == "present", package)
            )

            inspected = vm.run("ulpm inspect /tmp/hello.lpk")
            checks.append(
                (
                    "the manifest exposes the package identity",
                    '"id": "io.lpk.hello"' in inspected
                    and '"version": "1.0.0"' in inspected,
                    inspected,
                )
            )

            installed = vm.run(
                "ulpm install /tmp/hello.lpk 2>&1; echo rc=$?"
            )
            checks.append(
                ("ulpm install succeeds", "rc=0" in installed, installed)
            )
            listing = vm.run("ulpm list")
            checks.append(
                (
                    "the installed application is listed",
                    "hello" in listing and "1.0.0" in listing,
                    listing,
                )
            )

            run = vm.run("ulpm run hello 2>&1; echo rc=$?")
            checks.append(
                (
                    "the sandboxed application runs",
                    "Hello from ULPM!" in run and "rc=0" in run,
                    run,
                )
            )
            arguments = vm.run("ulpm run hello -- one two 2>&1; echo rc=$?")
            checks.append(
                (
                    "arguments reach the application",
                    "Args: one two" in arguments,
                    arguments,
                )
            )

            removed = vm.run("ulpm remove hello 2>&1; echo rc=$?")
            checks.append(
                ("ulpm remove succeeds", "rc=0" in removed, removed)
            )
            listing = vm.run("ulpm list")
            checks.append(
                (
                    "the removed application is gone",
                    "hello" not in listing,
                    listing,
                )
            )

            missing = vm.run("ulpm run hello 2>&1; echo rc=$?")
            checks.append(
                (
                    "a removed application cannot run",
                    "rc=0" not in missing,
                    missing,
                )
            )

            failed = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed after ULPM use",
                    "0 loaded units listed" in failed,
                    failed,
                )
            )
            state = vm.run("systemctl is-system-running")
            checks.append(
                ("systemd is still running", state == "running", state)
            )
    finally:
        cleanup(work)

    report("QEMU ULPM MVP test", checks)


if __name__ == "__main__":
    main()
