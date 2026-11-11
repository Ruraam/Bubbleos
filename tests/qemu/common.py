#!/usr/bin/env python3
"""Shared helpers for bubbleOS QEMU integration tests."""

from __future__ import annotations

import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pexpect

REPO = Path(__file__).resolve().parents[2]
DISK_IMAGE = Path(os.environ.get("DISK_IMAGE", REPO / "out" / "bubbleos.img"))
ROOT_IMAGE = Path(os.environ.get("ROOT_IMAGE", REPO / "out" / "bubbleos-root.img"))
LOG_DIR = Path(os.environ.get("TEST_LOG_DIR", REPO / "out" / "test-logs"))

BOOT_TIMEOUT = int(os.environ.get("BOOT_TIMEOUT", "420"))
CMD_TIMEOUT = int(os.environ.get("CMD_TIMEOUT", "120"))
POWEROFF_TIMEOUT = int(os.environ.get("POWEROFF_TIMEOUT", "120"))

# Partition 1 is the 1 MiB BIOS boot partition, so the ESP starts at 2 MiB.
ESP_OFFSET = int(os.environ.get("ESP_OFFSET", str(2 * 1024 * 1024)))
ESP_SIZE = os.environ.get("ESP_SIZE", "128M")

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07")


def sudo_prefix() -> list[str]:
    if os.geteuid() == 0:
        return []
    return ["sudo", "-n"]


SUDO = sudo_prefix()


def require_artifacts(*paths: Path) -> None:
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        sys.exit(f"missing build artifact(s): {', '.join(missing)}")


def require_commands(*names: str) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        sys.exit(f"missing required command(s): {', '.join(missing)}")


def check_sudo() -> None:
    if not SUDO:
        return
    result = subprocess.run(SUDO + ["true"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("passwordless sudo is required to run QEMU and mount the ESP (or run as root)")


def workdir(prefix: str = "bubbleos-qemu-") -> Path:
    base = os.environ.get("TEST_TMPDIR") or None
    if base is not None:
        Path(base).mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=prefix, dir=base))


def cleanup(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


def copy_image(source: Path, destination: Path) -> Path:
    subprocess.run(["cp", "--sparse=always", str(source), str(destination)], check=True)
    return destination


def kernel_release() -> str | None:
    env_file = REPO / "out" / "kernel" / "kernel.env"
    if not env_file.is_file():
        return None
    for line in env_file.read_text().splitlines():
        if line.startswith("KERNEL_RELEASE="):
            return line.split("=", 1)[1].strip().strip('"')
    return None


def _parse_size(value: str) -> int:
    units = {"K": 1024, "M": 1024**2, "G": 1024**3}
    suffix = value[-1:].upper()
    if suffix in units:
        return int(value[:-1]) * units[suffix]
    return int(value)


def clean_output(text: str) -> str:
    return ANSI_RE.sub("", text).replace("\r", "")


def normalize_boot_log(text: str) -> str:
    """Strip ANSI and kernel-log fragments that interleave with initramfs output."""
    text = clean_output(text)
    text = re.sub(r"\[\s*\d+\.\d+\][^\n]*\n*", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n+", " ", text).strip()


class VM:
    """An interactive bubbleOS guest driven over the serial console."""

    prompt = "bubbleos-test#"

    def __init__(self, child: pexpect.spawn, log_path: Path):
        self.child = child
        self.log_path = log_path
        self.log_file = None
        self.counter = 0
        self.logged_in = False
        self.boot_log = ""

    def __enter__(self) -> "VM":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.close()
        return False

    def login(self, password: str = "bubble") -> "VM":
        child = self.child
        child.expect_exact("bubbleos login:", timeout=BOOT_TIMEOUT)
        self.boot_log = normalize_boot_log(child.before)
        child.sendline("root")
        child.expect_exact("Password:")
        child.sendline(password)
        child.expect_exact("root@bubbleos:~#")
        # Disable terminal echo before changing PS1: the assignment must not be
        # echoed, otherwise its text is indistinguishable from the real prompt.
        child.sendline("stty -echo")
        child.expect_exact("root@bubbleos:~#")
        child.sendline(f'PS1="{self.prompt}"')
        child.expect_exact(self.prompt)
        self.logged_in = True
        return self

    def run(self, command: str, timeout: int = CMD_TIMEOUT) -> str:
        self.counter += 1
        marker = f"__BUBBLEOS_{secrets.token_hex(4)}_{self.counter}__"
        self.child.sendline(f"{command}; printf '\\n%s\\n' {marker}")
        try:
            # Terminal echo is disabled in login(), so the only occurrence of
            # the marker is the line printed after the command completes.
            self.child.expect_exact(marker, timeout=timeout)
            raw = self.child.before
            self.child.expect_exact(self.prompt, timeout=timeout)
        except pexpect.TIMEOUT as error:
            raise RuntimeError(
                f"timeout while running {command!r}; see {self.log_path}"
            ) from error

        lines = clean_output(raw).split("\n")
        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        if lines and lines[-1].strip() == marker:
            lines.pop()
        return "\n".join(lines).strip()

    def close(self) -> None:
        if self.logged_in and self.child.isalive():
            try:
                self.child.sendline("sync; poweroff")
                self.child.expect(pexpect.EOF, timeout=POWEROFF_TIMEOUT)
            except Exception:
                pass
        self.child.close(force=True)
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None


def boot(
    *,
    name: str,
    disk_image: Path | None = None,
    root_image: Path | None = None,
    root_device: str = "UUID=b0bb1e05-4a2d-4f00-9000-000000000001",
    append_extra: str = "",
    uefi: bool = True,
) -> VM:
    if disk_image is not None and root_image is not None:
        raise ValueError("use either disk_image or root_image, not both")
    if disk_image is None and root_image is None:
        raise ValueError("disk_image or root_image is required")

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"{name}.log"
    env_items = []
    if disk_image is not None:
        env_items.extend([f"DISK_IMAGE={disk_image}", f"UEFI={1 if uefi else 0}"])
    if root_image is not None:
        env_items.extend(
            [
                f"ROOT_IMAGE={root_image}",
                f"ROOT_DEVICE={root_device}",
            ]
        )
    if append_extra:
        env_items.append(f"APPEND_EXTRA={append_extra}")

    argv = SUDO + ["env", *env_items, "./build/run-qemu.sh"]
    child = pexpect.spawn(
        argv[0],
        argv[1:],
        cwd=str(REPO),
        encoding="utf-8",
        codec_errors="replace",
        timeout=BOOT_TIMEOUT,
        dimensions=(40, 200),
    )
    log_file = open(log_path, "w", encoding="utf-8")
    child.logfile = log_file
    vm = VM(child, log_path)
    vm.log_file = log_file
    return vm


def set_limine_default(disk: Path, entry: int) -> None:
    """Patch default_entry in both Limine config copies on the ESP."""
    mountpoint = Path(tempfile.mkdtemp(prefix="bubbleos-esp-"))
    mounted = False
    try:
        subprocess.run(
            SUDO
            + [
                "mount",
                "-o",
                f"loop,offset={ESP_OFFSET},sizelimit={_parse_size(ESP_SIZE)}",
                str(disk),
                str(mountpoint),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        mounted = True
        for relative in ("limine.conf", "EFI/BOOT/limine.conf"):
            path = mountpoint / relative
            text = path.read_text()
            updated = re.sub(
                r"(?m)^default_entry: \d+$", f"default_entry: {entry}", text
            )
            if updated == text:
                raise RuntimeError(f"default_entry not found in {path}")
            temporary_fd, temporary_name = tempfile.mkstemp(
                prefix="limine-", suffix=".conf"
            )
            os.close(temporary_fd)
            temporary = Path(temporary_name)
            try:
                temporary.write_text(updated)
                subprocess.run(SUDO + ["cp", str(temporary), str(path)], check=True)
            finally:
                temporary.unlink()
        subprocess.run(SUDO + ["sync"], check=True)
    finally:
        if mounted:
            subprocess.run(SUDO + ["umount", str(mountpoint)], check=True)
        mountpoint.rmdir()


def report(title: str, checks: list[tuple[str, bool, str]]) -> None:
    print(f"\n===== {title} =====")
    failures = 0
    for label, ok, detail in checks:
        print(f"[{'PASS' if ok else 'FAIL'}] {label}")
        if not ok:
            failures += 1
            if detail:
                for line in detail.splitlines():
                    print(f"       {line}")
    passed = len(checks) - failures
    print(f"----- {passed}/{len(checks)} checks passed -----")
    if failures:
        raise SystemExit(1)
