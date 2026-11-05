# bubbleOS QEMU integration tests

These tests boot the built disk image under QEMU (UEFI/OVMF) and drive the
serial console with `pexpect`. They validate the parts that cannot be checked
from the build tree alone: the initramfs selection logic, the Limine menu, the
Btrfs layout and the systemd state.

Each suite copies `out/bubbleos.img` to a temporary directory and mutates the
copy, so `out/` is never modified.

## Requirements

- a built disk image (`out/bubbleos.img`);
- `qemu-system-x86_64`, OVMF and `python3-pexpect`;
- passwordless `sudo` (QEMU/KVM and loop-mounting the ESP), or run as root.

## Usage

```bash
./tests/qemu/run.sh                 # all suites
./tests/qemu/run.sh boot            # boot smoke test
./tests/qemu/run.sh generations     # create/activate/rollback + explicit entries
./tests/qemu/run.sh fallback        # broken current link + missing subvolume
./tests/qemu/run.sh snapshots       # /var restore + pruning
./tests/qemu/run.sh ulpm            # ULPM diagnostics + LPK lifecycle
```

Serial logs are written to `out/test-logs/` (one file per boot). A failed
assertion prints the captured command output; the full boot log is in the log
file.

## Suites

### `test_boot.py`

- kernel release matches `out/kernel/kernel.env`;
- `selinux=0` on the command line, no SELinux policy error;
- ESP mounted at `/boot`, RootFS mounted with `compress=zstd:1`;
- generation `000001` selected and recorded;
- `/var`, `/snapshots`, `@rootfs` mounted;
- initial restore point is read-only;
- module tree, firmware tree and `modprobe autofs4`;
- APT absent, systemd `running`, no failed unit.

### `test_generations.py`

1. Boot, create `000002`, activate it, check the Limine menu after each step.
   Verify that each generation carries its kernel/initramfs, that a clone
   reuses the shared ESP pair, and that a generation with modified assets gets
   private staged copies.
2. Patch the ESP so Limine boots entry 2 (explicit
   `rootflags=subvol=@rootfs/generations/000001`) while `current` selects
   `000002`; verify the explicit entry wins and boots its private assets.
3. Run `bubble rollback`, check the menu and the staged/pruned asset
   directories, then reboot and verify the default entry follows `current`
   again.

### `test_fallback.py`

1. Point `@rootfs/current` at a missing generation; reboot and verify the
   initramfs falls back to the newest generation.
2. Repair the link, boot with `rootflags=subvol=.../999999` and verify the
   fallback to `current` with the `generation fallback` message.
3. Check that systemd reaches `running` with no failed unit in both cases.

### `test_snapshots.py`

1. Boot, create a file in `/var`, create and activate generation `000002`, then
   prune two fabricated old snapshots while the pre-activation snapshot and the
   initial snapshot survive.
2. Create/activate `000003` with `BUBBLEOS_SNAPSHOT_KEEP=1` to verify automatic
   pruning, schedule `bubble snapshots restore <snapshot>`, and verify a pending
   request survives an aggressive prune.
3. Reboot and verify the file from the snapshot is back, later changes are gone,
   the request is consumed, a `pre-restore` safety snapshot exists, and the
   `bubbleos-var-restore.service` unit completed before `/var` was mounted.

### `test_ulpm.py`

1. Check `ulpm --version`, `ulpm doctor`, the critical CLI tools and the
   Bubblewrap sandbox.
2. Build a minimal `hello` LPK with `ulpm pack`, inspect its manifest, install
   it and run it (with and without application arguments).
3. Remove it, verify it disappears from `ulpm list` and can no longer run, and
   confirm systemd has no failed unit.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `DISK_IMAGE` | `out/bubbleos.img` | disk image under test |
| `TEST_LOG_DIR` | `out/test-logs` | serial console logs |
| `TEST_TMPDIR` | system temp | temporary image copies |
| `BOOT_TIMEOUT` | `420` | seconds to wait for the login prompt |
| `CMD_TIMEOUT` | `120` | seconds per guest command |
| `ESP_OFFSET` | `1048576` | ESP offset used by the explicit-entry test |
| `ESP_SIZE` | `128M` | ESP size used by the explicit-entry test |

The full suite runs ten QEMU boots and takes a few minutes on KVM.
