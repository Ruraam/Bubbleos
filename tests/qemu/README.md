# bubbleOS QEMU integration tests

These tests boot the built disk image under QEMU (UEFI/OVMF by default, legacy
BIOS/SeaBIOS for the `bios` suite) and drive the serial console with
`pexpect`. They validate the parts that cannot be checked
from the build tree alone: the initramfs selection logic, the Limine menu, the
Btrfs layout and the systemd state.

Each suite copies `out/bubbleos.img` to a temporary directory and mutates the
copy, so `out/` is never modified.

## Requirements

- a built disk image (`out/bubbleos.img`);
- `qemu-system-x86_64`, OVMF (SeaBIOS is bundled with QEMU) and
  `python3-pexpect`;
- passwordless `sudo` (QEMU/KVM and loop-mounting the ESP), or run as root.

## Usage

```bash
./tests/qemu/run.sh                 # all suites
./tests/qemu/run.sh boot            # boot smoke test
./tests/qemu/run.sh bios            # legacy BIOS/SeaBIOS boot
./tests/qemu/run.sh generations     # lifecycle, delete/prune + explicit entries
./tests/qemu/run.sh fallback        # broken current link + missing subvolume
./tests/qemu/run.sh snapshots       # /var restore + pruning
./tests/qemu/run.sh store           # store, composition, upgrade/remove/rollback
./tests/qemu/run.sh repo            # signed repositories, resolution, update/upgrade
./tests/qemu/run.sh ulpm            # ULPM diagnostics + LPK lifecycle
./tests/qemu/run.sh desktop         # Wayfire, Waybar, Fuzzel, Mako, greetd
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

### `test_bios.py`

- boot the same disk image with QEMU's legacy BIOS (SeaBIOS), without OVMF;
- verify the Limine MBR signature and stage 1 code, the BIOS boot partition
  payload and `limine-bios.sys` on the ESP;
- verify that the kernel, the Btrfs generation subvolume, the UUID root and
  the tty task manager are identical to the UEFI path.

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
4. Reject deleting the current, previous and running generations. Delete an
   unused generation and verify its subvolume, Limine entry and private ESP
   assets disappear. Exercise `bubble generation prune --keep N`, first with
   `--dry-run`, and verify it keeps the current, previous and newest
   generations while removing the old one and its staged assets.

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

### `test_store.py`

1. Verify that the bootstrap generation has an empty system store and package
   lock, pack a rootfs LPK with `ulpm pack`, and install it with `bubble
   install`. Check that generation `000002` is created, activated and visible
   in Limine, and that its payload runs.
2. Pack `2.0.0`, upgrade the package, and verify that files from `1.0.0` do not
   linger. Pack a dependent and a consumer LPK; reject the consumer alone, then
   install both as a closed set. Reject removing a still-required dependency,
   remove the consumer, then the dependency.
3. Reject deleting the package-free base generation, remove a package link
   with `--gc` and verify the object survives while a generation lock pins it,
   delete the old composed generation, then verify GC collects the object and
   keeps the version still in use. Reject an application LPK and a tampered
   signed LPK, and verify `bubble store add/show/remove --gc` without
   composing.
4. Reboot into the composed generation, verify the payload and lock survive,
   then roll back to the previous package generation and verify that the
   payload state and package lock match that generation after another reboot.

### `test_repo.py`

1. Verify that a fresh system has no repository, pack four rootfs LPKs with
   dependencies, build a signed index with the test publisher key, and add the
   repository with `bubble repo add`. Check the pinned key, enabled repository,
   verified catalogue, JSON metadata (`repository`, `base_url`, `type`) and
   search. Confirm that the system repository state is isolated from `/root`'s
   ULPM environment.
2. Install a package by ID and verify that its dependency is resolved from the
   repository into generation `000002`. Reject an orphan package whose
   dependency is missing, and reject a payload after removing the publisher key
   from the system trust store. Restore the trust anchor with `bubble trust`.
3. Publish `2.0.0` versions with a stronger dependency constraint, refresh the
   index, and verify `bubble update`, `update --json`, `upgrade --dry-run` and
   `bubble upgrade`. Check the composed payloads and lock, idempotent upgrades,
   and SHA-256 rejection for a tampered payload.
4. Reboot into the upgraded generation and verify the payload, repository
   configuration, pinned key, verified catalogue and up-to-date status survive.

### `test_ulpm.py`

1. Check `ulpm --version`, `ulpm doctor`, the critical CLI tools and the
   Bubblewrap sandbox.
2. Build a minimal `hello` LPK with `ulpm pack`, inspect its manifest, install
   it and run it (with and without application arguments).
3. Remove it, verify it disappears from `ulpm list` and can no longer run, and
   confirm systemd has no failed unit.

### `test_desktop.py`

1. Verify the Wayfire/Waybar/Fuzzel/Mako/greetd binaries, the system
   configuration files, the cyber-punk stylesheet and the Orbitron/Inter/
   JetBrains Mono/Font Awesome fonts.
2. Check the `bubble` desktop user, its device groups and password, the
   graphical target, greetd/tuigreet on VT7, NetworkManager, BlueZ (enabled;
   active only when a controller exposes `/sys/class/bluetooth`) and the
   globally enabled PipeWire user units.
3. Run `bubble-desktop doctor`, then exercise `bubble-desktop prepare`,
   `config set`, `config unset`, `config reset` and the generated Waybar JSON.
4. Start a Wayfire session as `bubble` on the virtio GPU DRM output with the
   systemd user bus (or a private D-Bus fallback), verify the Wayland socket,
   Waybar/Mako/swaybg/swayidle processes, capture the output with `grim`, and
   check that shutdown removes the compositor and its companions.
5. Launch `bubble-settings --smoke-test --page users` inside the running
   Wayfire session and verify that every control-center page can be built.

### `test_settings.py`

1. Verify the control-center binary, helper, polkit policy, stylesheet,
   desktop entry and icon, check that the ELF has no unresolved libraries and
   that the temporary build toolchain was removed from the image.
2. Validate the polkit action with `pkaction` and run `bubble-settings
   --doctor` inside the guest.
3. Exercise the helper as root and as an unprivileged user: reject invalid
   names and short passwords, create standard, administrator and no-home
   accounts, check the home directory, bash shell, sudo membership and shadow
   status, change and force-expire passwords, delete accounts with and without
   their home directory, and reject deleting root, the caller's own account or
   the last administrator.
4. Check that empty Waybar and screenshot values are accepted while other
   empty values are rejected, and that `bubble-desktop apply` is safe outside
   a Wayland session.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `DISK_IMAGE` | `out/bubbleos.img` | disk image under test |
| `TEST_LOG_DIR` | `out/test-logs` | serial console logs |
| `TEST_TMPDIR` | system temp | temporary image copies |
| `BOOT_TIMEOUT` | `420` | seconds to wait for the login prompt |
| `CMD_TIMEOUT` | `120` | seconds per guest command |
| `ESP_OFFSET` | `2097152` | ESP offset used by the explicit-entry test |
| `ESP_SIZE` | `128M` | ESP size used by the explicit-entry test |

The full suite runs eighteen QEMU boots and takes a few minutes on KVM.
