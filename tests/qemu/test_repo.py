#!/usr/bin/env python3
"""Signed system repositories: pinned keys, dependency resolution and upgrades."""

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
REPO = "/repo"
PRIV = "/root/.config/ulpm/keys/default.priv"
PUB = "/root/.config/ulpm/keys/default.pub"


def pack(vm, name, version, marker, dependency=""):
    dep = f"--dependency '{dependency}' " if dependency else ""
    return vm.run(
        f"rm -rf /tmp/{name}-{version} /tmp/{name}-{version}.lpk && "
        f"mkdir -p /tmp/{name}-{version}/etc /tmp/{name}-{version}/usr/bin && "
        f"printf 'NAME={name}\\n' > /tmp/{name}-{version}/etc/{name}.conf && "
        f"printf '#!/bin/sh\\necho {marker}\\n' "
        f"> /tmp/{name}-{version}/usr/bin/{name} && "
        f"chmod 755 /tmp/{name}-{version}/usr/bin/{name} && "
        f"ulpm pack {dep}/tmp/{name}-{version} {name} "
        f"/tmp/{name}-{version}.lpk {version} 2>&1; echo rc=$?"
    )


def publish(vm, packages):
    """Copy package archives into the repository and sign a fresh index."""
    copies = " && ".join(
        f"cp /tmp/{name}-{version}.lpk {REPO}/" for name, version in packages
    )
    return vm.run(
        f"rm -rf {REPO} && mkdir -p {REPO} && {copies} && "
        f"ulpm repo index {REPO} {PRIV} 2>&1; echo rc=$?"
    )


def main() -> None:
    require_commands("qemu-system-x86_64", "cp")
    require_artifacts(DISK_IMAGE)
    check_sudo()

    work = workdir()
    checks: list[tuple[str, bool, str]] = []
    try:
        disk = copy_image(DISK_IMAGE, work / "disk.img")

        with boot(name="repo-1", disk_image=disk) as vm:
            vm.login()

            empty = vm.run("bubble repo list")
            checks.append(
                (
                    "no repository is configured on a fresh system",
                    "No repositories configured" in empty,
                    empty,
                )
            )
            catalog = vm.run("bubble repo packages --json")
            checks.append(
                (
                    "the verified catalogue starts empty",
                    catalog.strip() == "[]",
                    catalog,
                )
            )

            packed = []
            packed.append(pack(vm, "sys-lib", "1.0.0", "sys-lib-v1"))
            packed.append(
                pack(
                    vm,
                    "sys-app",
                    "1.0.0",
                    "sys-app-v1",
                    dependency="io.lpk.sys-lib>=1.0.0",
                )
            )
            packed.append(pack(vm, "sys-extra", "1.0.0", "sys-extra-v1"))
            packed.append(
                pack(
                    vm,
                    "sys-orphan",
                    "1.0.0",
                    "sys-orphan-v1",
                    dependency="io.lpk.sys-missing>=1.0.0",
                )
            )
            checks.append(
                (
                    "the system packages are packed for the repository",
                    all("rc=0" in output for output in packed)
                    and all("RootFS payload detected" in output for output in packed),
                    "\n".join(packed),
                )
            )

            indexed = publish(
                vm,
                [
                    ("sys-lib", "1.0.0"),
                    ("sys-app", "1.0.0"),
                    ("sys-extra", "1.0.0"),
                    ("sys-orphan", "1.0.0"),
                ],
            )
            checks.append(
                (
                    "the repository index is signed with the publisher key",
                    "Signed deterministic repository index created" in indexed
                    and "4 packages" in indexed
                    and "rc=0" in indexed,
                    indexed,
                )
            )

            added, status = run_rc(
                vm, f"bubble repo add testing {REPO} {PUB}"
            )
            checks.append(
                (
                    "the repository and pinned key are added",
                    "Repository 'testing' configured" in added
                    and "Updated 'testing'" in added
                    and status == "rc=0",
                    added,
                )
            )

            listing = vm.run("bubble repo list")
            checks.append(
                (
                    "the repository is listed as enabled",
                    "testing" in listing and "enabled" in listing,
                    listing,
                )
            )
            user_env = vm.run("ulpm repo list")
            checks.append(
                (
                    "the system repository state is isolated from the user env",
                    "testing" not in user_env,
                    user_env,
                )
            )

            verified, status = run_rc(vm, "bubble repo verify")
            checks.append(
                (
                    "the cached index verifies against the pinned key",
                    "Verified repository 'testing' (4 packages)" in verified
                    and status == "rc=0",
                    verified,
                )
            )

            packages = vm.run("bubble repo packages")
            checks.append(
                (
                    "the catalogue lists the signed packages",
                    "io.lpk.sys-app" in packages
                    and "io.lpk.sys-lib" in packages
                    and "testing" in packages,
                    packages,
                )
            )

            raw = vm.run("bubble repo packages --json")
            checks.append(
                (
                    "the JSON catalogue exposes repository metadata",
                    '"repository": "testing"' in raw
                    and '"base_url": "/repo"' in raw
                    and '"type": "rootfs"' in raw
                    and '"dependencies"' in raw,
                    raw,
                )
            )

            search = vm.run("bubble repo search sys-lib")
            checks.append(
                (
                    "repository search finds system packages",
                    "io.lpk.sys-lib" in search and "1.0.0" in search,
                    search,
                )
            )

            installed, status = run_rc(vm, "bubble install io.lpk.sys-app")
            checks.append(
                (
                    "installing a repository package resolves its dependency",
                    "Installed packages in generation 000002; activated"
                    in installed
                    and status == "rc=0",
                    installed,
                )
            )
            current = vm.run("bubble generation current")
            checks.append(
                (
                    "the repository install activates generation 000002",
                    current == "000002",
                    current,
                )
            )
            payload = vm.run(
                f"{GEN_ROOT}/000002/usr/bin/sys-app; "
                f"{GEN_ROOT}/000002/usr/bin/sys-lib"
            )
            checks.append(
                (
                    "both the package and its dependency are composed",
                    payload.splitlines() == ["sys-app-v1", "sys-lib-v1"],
                    payload,
                )
            )
            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the generation lock records the resolved set",
                    "io.lpk.sys-app" in packages
                    and "io.lpk.sys-lib" in packages
                    and "1.0.0" in packages,
                    packages,
                )
            )

            orphaned, status = run_rc(
                vm, "bubble install io.lpk.sys-orphan"
            )
            current = vm.run("bubble generation current")
            generations = vm.run("bubble generations")
            checks.append(
                (
                    "a package with a missing dependency is rejected",
                    "io.lpk.sys-missing" in orphaned
                    and status != "rc=0"
                    and current == "000002"
                    and len(generations.splitlines()) == 2,
                    orphaned,
                )
            )

            trusted = vm.run(
                "mv /var/lib/bubbleos/ulpm/trusted_keys/default.pub "
                "/tmp/default.pub.trusted"
            )
            checks.append(
                (
                    "the publisher key can be removed from the system trust store",
                    trusted == "",
                    trusted,
                )
            )
            untrusted, status = run_rc(
                vm, "bubble install io.lpk.sys-extra"
            )
            current = vm.run("bubble generation current")
            checks.append(
                (
                    "an untrusted repository payload cannot be installed",
                    status != "rc=0"
                    and ("untrusted" in untrusted.lower()
                         or "signature" in untrusted.lower())
                    and current == "000002",
                    untrusted,
                )
            )
            restored, status = run_rc(vm, f"bubble trust {PUB}")
            checks.append(
                (
                    "the publisher key can be trusted again",
                    "registered and trusted" in restored.lower()
                    or "already trusted" in restored.lower(),
                    restored,
                )
            )

            packed = []
            for name, marker in (
                ("sys-lib", "sys-lib-v2"),
                ("sys-app", "sys-app-v2"),
            ):
                packed.append(
                    pack(
                        vm,
                        name,
                        "2.0.0",
                        marker,
                        dependency=(
                            "io.lpk.sys-lib>=2.0.0" if name == "sys-app" else ""
                        ),
                    )
                )
            checks.append(
                (
                    "the upgraded packages are packed",
                    all("rc=0" in output for output in packed),
                    "\n".join(packed),
                )
            )

            indexed = publish(
                vm,
                [
                    ("sys-lib", "2.0.0"),
                    ("sys-app", "2.0.0"),
                    ("sys-extra", "1.0.0"),
                    ("sys-orphan", "1.0.0"),
                ],
            )
            checks.append(
                (
                    "the repository publishes the upgraded versions",
                    "4 packages" in indexed and "rc=0" in indexed,
                    indexed,
                )
            )

            updated, status = run_rc(vm, "bubble repo update")
            checks.append(
                (
                    "the cached index is refreshed and verified",
                    "Updated 'testing'" in updated and status == "rc=0",
                    updated,
                )
            )

            updates, status = run_rc(vm, "bubble update --no-refresh")
            checks.append(
                (
                    "update lists both available upgrades",
                    "Available updates (2)" in updates
                    and "io.lpk.sys-app 1.0.0 -> 2.0.0" in updates
                    and "io.lpk.sys-lib 1.0.0 -> 2.0.0" in updates
                    and status == "rc=0",
                    updates,
                )
            )
            updates_json = vm.run("bubble update --no-refresh --json")
            checks.append(
                (
                    "update --json reports the exact plan",
                    updates_json.strip().startswith("[")
                    and '"id":"io.lpk.sys-app"' in updates_json
                    and '"version":"2.0.0"' in updates_json,
                    updates_json,
                )
            )

            dry, status = run_rc(vm, "bubble upgrade --no-refresh --dry-run")
            current = vm.run("bubble generation current")
            checks.append(
                (
                    "upgrade --dry-run does not create a generation",
                    "Dry run: no generation created" in dry
                    and status == "rc=0"
                    and current == "000002",
                    dry,
                )
            )

            upgraded, status = run_rc(vm, "bubble upgrade --no-refresh")
            checks.append(
                (
                    "upgrade composes and activates generation 000003",
                    "Upgraded 2 package(s) in generation 000003; activated"
                    in upgraded
                    and status == "rc=0",
                    upgraded,
                )
            )
            current = vm.run("bubble generation current")
            payload = vm.run(
                f"{GEN_ROOT}/000003/usr/bin/sys-app; "
                f"{GEN_ROOT}/000003/usr/bin/sys-lib"
            )
            checks.append(
                (
                    "the upgraded dependency closure is composed",
                    current == "000003"
                    and payload.splitlines() == ["sys-app-v2", "sys-lib-v2"],
                    current + "\n" + payload,
                )
            )
            packages = vm.run("bubble packages")
            checks.append(
                (
                    "the new lock pins both upgraded versions",
                    packages.count("2.0.0") >= 2 and "1.0.0" not in packages,
                    packages,
                )
            )

            again, status = run_rc(vm, "bubble upgrade --no-refresh")
            current = vm.run("bubble generation current")
            generations = vm.run("bubble generations")
            checks.append(
                (
                    "upgrading an up-to-date system is idempotent",
                    "All system packages are up to date" in again
                    and status == "rc=0"
                    and current == "000003"
                    and len(generations.splitlines()) == 3,
                    again,
                )
            )

            tampered = vm.run(
                f"cp {REPO}/sys-extra-1.0.0.lpk /tmp/sys-extra-original.lpk && "
                f"printf 'X' >> {REPO}/sys-extra-1.0.0.lpk && "
                f"bubble install io.lpk.sys-extra 2>&1; echo rc=$?"
            )
            current = vm.run("bubble generation current")
            checks.append(
                (
                    "a payload with an invalid checksum is rejected",
                    "SHA-256 mismatch" in tampered
                    and tampered.splitlines()[-1] != "rc=0"
                    and current == "000003",
                    tampered,
                )
            )
            vm.run(
                f"cp /tmp/sys-extra-original.lpk {REPO}/sys-extra-1.0.0.lpk"
            )

            failed_units = vm.run("systemctl --failed --no-pager")
            checks.append(
                (
                    "no systemd unit failed during repository operations",
                    "0 loaded units listed" in failed_units,
                    failed_units,
                )
            )

        with boot(name="repo-2", disk_image=disk) as vm:
            vm.login()

            generation = vm.run(
                "sed -n 's/^GENERATION=//p' /etc/bubbleos/generation"
            )
            checks.append(
                (
                    "the upgraded repository generation boots",
                    generation == "000003",
                    generation,
                )
            )
            payload = vm.run("/usr/bin/sys-app; /usr/bin/sys-lib")
            checks.append(
                (
                    "the repository package payload survives a reboot",
                    payload.splitlines() == ["sys-app-v2", "sys-lib-v2"],
                    payload,
                )
            )

            listing = vm.run("bubble repo list")
            verified, status = run_rc(vm, "bubble repo verify")
            checks.append(
                (
                    "repository configuration and pinned key survive a reboot",
                    "testing" in listing
                    and "Verified repository 'testing'" in verified
                    and status == "rc=0",
                    listing + "\n" + verified,
                )
            )

            packages = vm.run("bubble repo packages")
            checks.append(
                (
                    "the verified catalogue survives a reboot",
                    "io.lpk.sys-app" in packages and "2.0.0" in packages,
                    packages,
                )
            )

            updates, status = run_rc(vm, "bubble update --no-refresh")
            checks.append(
                (
                    "the upgraded system remains up to date after reboot",
                    "System is up to date" in updates and status == "rc=0",
                    updates,
                )
            )

    finally:
        cleanup(work)

    report("QEMU signed repository test", checks)


if __name__ == "__main__":
    main()
