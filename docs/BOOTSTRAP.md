# bubbleOS Bootstrap

`build/bootstrap.sh` creates the first development RootFS for bubbleOS.
`build/build-disk-image.sh` assembles the bootable UEFI disk image.

## Important design rule

The initial RootFS is assembled **at build time** with `debootstrap` from
prebuilt base packages. This solves the chicken-and-egg bootstrap problem; it
is not the runtime package manager of bubbleOS.

The long-term target is:

- ULPM is the package engine.
- LPK is the package format.
- System state is composed into atomic generations.
- APT is not present in the installed OS and dpkg is not exposed as the
  package-management interface.

## Build requirements

On the build host:

```bash
sudo apt install debootstrap busybox-static cpio gzip xz-utils zstd kmod \
                 btrfs-progs dosfstools mtools fdisk ovmf qemu-system-x86
```

By default `build/build-kernel.sh` imports the locally built kernel from
`boot/vmlinuz-bubbleos` and `../bubble-modules/`; no host APT access is needed
for that path. The Debian package fallback (`KERNEL_SOURCE=debian`) still uses
`apt-get` and therefore requires a working APT configuration **on the build
host only**.

The firmware and hardware userspace payloads are read from
`../firmware/<package>/usr/`. `FIRMWARE_DIR` can point at another drop, and
`HARDWARE_USERSPACE=0` skips the non-firmware packages while keeping the
firmware merge.

## Full build

```bash
# 1. Kernel and modules (local 7.3.1 import, no compilation)
./build/build-kernel.sh

# 2. Initramfs: storage modules + early microcode
./build/build-initramfs.sh

# 3. RootFS (debootstrap), complete module tree, firmware and Btrfs image
sudo ./build/bootstrap.sh
sudo ./build/build-image.sh

# 4. Bootable GPT disk: ESP + RootFS
./build/build-disk-image.sh

# 5. Boot it under UEFI (OVMF)
sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
```

Direct-kernel boot remains available for debugging. `run-qemu.sh` uses
`out/kernel/vmlinuz` automatically when it exists (override with `KERNEL=...`):

```bash
sudo ROOT_IMAGE=out/bubbleos-root.img ./build/run-qemu.sh
./build/run-qemu.sh                    # initramfs rescue shell, no disk
```

## Kernel

By default `build/build-kernel.sh` imports the locally built bubbleOS kernel:

- `boot/vmlinuz-bubbleos` — bzImage, release **7.3.1**;
- `../bubble-modules/lib/modules/7.3.1` — matching module tree.

`build/import-kernel.sh` validates the image and checks that the boot-critical
drivers (`btrfs`, `ext4`, `virtio_blk`, `virtio_pci`, `ahci`, `ata_piix`,
`sd_mod`, `autofs4`) are either built in or present as modules. The result is:

```text
out/kernel/
├── vmlinuz                         # copy of boot/vmlinuz-bubbleos
├── root/usr/lib/modules/7.3.1/     # complete module tree + indexes
└── kernel.env                      # KERNEL_RELEASE, KERNEL_IMAGE, MODULE_ROOT
```

The 7.3.1 configuration keeps `btrfs`, `virtio_blk`, `virtio_pci`, `ahci`,
`sd_mod`, `autofs4`, `loop`, `overlay` and `binfmt_misc` built in; `ext4` and
`ata_piix` remain modules. The initramfs embeds the loadable storage modules
(`ext4`, `ata_piix` and dependencies) and does not need to load the built-ins.

The Debian package path is only a bootstrap fallback for a host that does not
have the local kernel:

```bash
KERNEL_SOURCE=debian ./build/build-kernel.sh
```

`build/bootstrap.sh` copies the complete 7.3.1 module tree into the target's
`/lib/modules/7.3.1` and runs `depmod` inside the RootFS. The generated
`modules.dep.bin` and `modules.builtin.bin` are required for libkmod/systemd to
recognize built-in modules; without them systemd reports
`Failed to find module 'autofs4'` and the binfmt_misc automount is unsupported.
The module tree also provides the loadable graphics, audio, Bluetooth and
other drivers built by the local kernel.

## Firmware and early microcode

`build/bootstrap.sh` merges every `firmware/*/usr/lib/firmware` payload into
`/usr/lib/firmware` (2636 files in the current drop): AMD and Intel graphics,
Intel Wi-Fi, MediaTek, Realtek, Cirrus, SOF audio, plus `amd-ucode` and
`intel-ucode`. Ownership is normalized to `root:root` and regular files to
mode `0644`.

The same drop contains the hardware userspace packages (`bolt`, `libdrm-*`,
`libwacom`, `libtypec0`, `libusb3380`, `intel-media-va-driver`). They are merged
into the target with no-clobber semantics, so base-package files keep their
packaged versions, and `ldconfig` is refreshed. Set `HARDWARE_USERSPACE=0` to
install only firmware.

`build/build-initramfs.sh` creates an **uncompressed** cpio archive containing:

```text
kernel/x86/microcode/AuthenticAMD.bin
kernel/x86/microcode/GenuineIntel.bin
```

It concatenates the vendor microcode files in sorted order and prepends the
archive to the compressed main initramfs, as documented by the kernel. The
kernel loads the matching patch before the root filesystem is mounted. Set
`MICROCODE=0` to skip this step.

When the guest runs under a hypervisor, the 7.3.1 kernel deliberately disables
microcode loading (unless built with `CONFIG_MICROCODE_DBG`). A QEMU/KVM boot
with `-cpu host,-hypervisor` bypasses that check and logs
`microcode: Current revision: 0x...` while exposing
`/sys/devices/system/cpu/microcode`, confirming that the early archive path is
active. Whether a patch is applied still depends on the host CPU model being
present in the vendor file; on bare metal the matching patch is applied before
the root filesystem is mounted.

## Disk layout

`out/bubbleos.img` uses GPT:

| Partition | Offset | Size | Type | Content |
|---|---|---|---|---|
| 1 | 1 MiB | 128 MiB | EFI System | FAT32: Limine, kernel, initramfs, config |
| 2 | 129 MiB | 2 GiB | Linux | Btrfs RootFS with generation subvolumes |

ESP contents:

```text
/EFI/BOOT/BOOTX64.EFI
/EFI/BOOT/limine.conf
/limine.conf
/vmlinuz
/initramfs.cpio.gz
```

The ESP is mounted at `/boot` in the guest, so Limine's `boot():/vmlinuz`
is visible as `/boot/vmlinuz`. The shared pair follows the current
generation; generations whose kernel or initramfs differ get private copies
under `/generations/<gen>/` on the ESP.

Limine boots `boot():/vmlinuz` with
`selinux=0 root=UUID=<fixed-uuid> rootfstype=btrfs rw`. The initramfs resolves
the UUID with BusyBox `findfs`, so the RootFS does not depend on virtio
enumeration order.

`build/build-image.sh` renders the initial menu to `out/limine.conf` from the
generation subvolumes it just created; `build/build-disk-image.sh` copies it to
the ESP when it matches `config/rootfs.env`, otherwise it falls back to
`boot/limine.conf`. At runtime the ESP is mounted at `/boot` (fstab, `nofail`)
and `bubble bootloader sync` regenerates `/boot/limine.conf`:

- entry 1 has no `rootflags` and follows `@rootfs/current`;
- every other generation gets an explicit
  `rootflags=subvol=@rootfs/generations/<gen>` entry;
- `generation create`, `activate` and `rollback` refresh the menu
  automatically.

A missing `/boot` mount is a no-op, so direct-kernel test images without an ESP
still boot.

SELinux is built into the supplied kernel and enabled by default
(`CONFIG_DEFAULT_SECURITY_SELINUX=y`), but bubbleOS does not ship an SELinux
policy. Without `selinux=0`, the kernel logs
`Could not open policy file <= /etc/selinux/default/policy/policy.35` at boot.
The boot command line disables the LSM explicitly; enabling SELinux later
requires a policy package and a deliberate permissive/enforcing design.

### Btrfs subvolume layout

`build/build-image.sh` creates a compressed Btrfs filesystem (`compress=zstd:1`,
`noatime`) with data checksums (`crc32c`) and this layout:

```text
@rootfs/                          mounted at /var/lib/bubbleos/rootfs
├── generations/
│   ├── 000001/                   mounted as / by the initramfs
│   └── 000002/
├── current -> generations/000001
└── previous -> generations/000001 (after a generation switch)

@home                             mounted at /home
@var                              mounted at /var
@logs                             mounted at /var/log
@snapshots                        mounted at /snapshots
├── rootfs/000001-initial/        read-only
└── var/000001-initial/           read-only
```

`@rootfs/current` is a relative symlink. The initramfs mounts the Btrfs
top-level (`subvolid=5`), reads `current` and `previous`, then tries, in order:
the explicit `rootflags=subvol=...` value, `current`, `previous`, and the
newest generation. The first subvolume that mounts becomes `/newroot`; the
rescue shell is only reached when every candidate fails. The fstab inside the
generation mounts the persistent subvolumes by filesystem UUID; it deliberately
has no `/` entry because the initramfs already mounted the selected generation.

Snapshots are created with `btrfs subvolume snapshot -r`, so restore points are
read-only. `@home` is preserved across rollbacks, `@var` is shared and
snapshotted before each generation activation, and `@logs` stays outside the
`/var` snapshot.

## Stable RootFS identity

`config/rootfs.env` defines the RootFS label and UUIDs:

```text
ROOTFS_LABEL=bubbleos-root
ROOTFS_UUID=b0bb1e05-4a2d-4f00-9000-000000000001
ROOTFS_PARTUUID=b0bb1e05-4a2d-4f00-9000-000000000002
ESP_UUID=B0BB-1E05
```

The Btrfs filesystem UUID is used for `root=`. `PARTUUID=` is also fixed on the
GPT RootFS partition, but it is not used for boot because BusyBox `findfs`
supports `UUID=` and `LABEL=` only, and the direct-kernel path boots the same
image as a bare filesystem without a partition table.

The ESP volume ID is fixed so `/etc/fstab` can mount the boot partition on
`/boot` by UUID; `build/build-disk-image.sh` passes it to `mkfs.vfat -i` and
verifies the result with `blkid`.

The UUID is fixed for reproducible development images. A production installer
must generate a unique filesystem UUID per installation so that multiple
bubbleOS disks on the same machine cannot be confused.

## Init and services

By default the RootFS is bootstrapped with **systemd 257**, `udev`, D-Bus and
PAM session integration. The following units are enabled:

| Unit | Role |
|---|---|
| `multi-user.target` | default boot target |
| `getty@tty1.service` | local console login |
| `serial-getty@ttyS0.service` | QEMU serial login |
| `bubbleos-boot.service` | records the booted generation and subvolume |

`bubbleos-boot.service` has
`RequiresMountsFor=/var /var/lib/bubbleos/rootfs`, so it only runs once the
persistent state and generation container are mounted. It runs
`/usr/local/bin/bubble boot`, which:

1. creates the runtime/state directories;
2. reads `@rootfs/current` and the mounted `/etc/bubbleos/generation` marker;
3. writes `/run/bubbleos/current-generation` and
   `/run/bubbleos/selected-generation`;
4. records the generation, kernel, root device, filesystem type and subvolume
   in `/var/lib/bubbleos/boot/last`;
5. logs the generation and root subvolume to the journal and console.

If `current` selects a different generation than the one mounted, a warning is
logged; the mounted generation is always the one recorded as booted.

### Generations and snapshots

```bash
bubble generations                     # list generation subvolumes
bubble generation create               # clone current -> next number
bubble generation create --from 000001 --description "test"
bubble generation activate 000002      # select for next boot
bubble generation current              # print selected generation
bubble rollback                        # select previous generation
bubble bootloader sync                 # rewrite /boot/limine.conf
bubble snapshots                       # list read-only restore points
bubble snapshots prune --keep 10       # keep the newest automatic snapshots
bubble snapshots restore var/<name>    # /var restored at the next boot
```

`bubble generation create` runs `btrfs subvolume snapshot` from the active
generation into `@rootfs/generations/<next>` and writes
`/etc/bubbleos/generation` inside the new subvolume. It does not switch the
system.

`bubble generation activate <gen>` creates a read-only snapshot of the outgoing
generation under `/snapshots/rootfs/`, creates a read-only snapshot of `/var`
under `/snapshots/var/`, then updates `@rootfs/previous` and
`@rootfs/current`. **A reboot is required** to boot the selected generation.
Set `BUBBLEOS_SKIP_SNAPSHOTS=1` only for development when `/snapshots` is not
available.

`/home` and `/var` are separate subvolumes, so they are not replaced when the
root generation changes. `/home` is never rolled back. `/var` remains shared
and its pre-activation state is preserved as a read-only snapshot.

To restore `/var`, select a point from `bubble snapshots`:

```bash
bubble snapshots restore var/<timestamp>-before-000002
systemctl reboot
```

The request is written to `@snapshots/var-restore.request`.
`bubbleos-var-restore.service` runs before `var.mount` on the next boot,
replaces `@var` with a writable copy of the selected snapshot, removes the
request and records the previous `/var` as a read-only `pre-restore` safety
snapshot. The restore is aborted (and the request removed) if the snapshot is
missing or no longer read-only.

Old automatic snapshots are pruned on each activation with
`BUBBLEOS_SNAPSHOT_KEEP` (default: 10). The command can also be run manually;
`*-initial` restore points are never pruned, and a pending restore point is
always kept:

```bash
bubble snapshots prune --keep 5
bubble snapshots prune --keep 5 --dry-run
```

A read-only generation snapshot can be turned back into an activatable
generation:

```bash
btrfs subvolume snapshot /snapshots/rootfs/<name> \
    /var/lib/bubbleos/rootfs/generations/000004
bubble generation activate 000004
```

The development root password is `bubble`. Override it at build time:

```bash
sudo ROOT_PASSWORD='change-me' FORCE=1 ./build/bootstrap.sh
```

The old shell-only init is still available for debugging:

```bash
sudo SYSTEMD=0 FORCE=1 ./build/bootstrap.sh
```

## Target identity and package manager

`build/bootstrap.sh` removes the bootstrap identity from the target RootFS:

- `/etc/issue` and `/etc/issue.net` show `bubbleOS`;
- `/etc/os-release` is written by the build, not by a package;
- the bootstrap distribution version file and origin metadata are removed;
- `/etc/dpkg/origins/default` points to `bubbleOS`;
- package-provided configuration files carrying the bootstrap distribution name
  are renamed;
- distribution URLs and MOTD text are replaced;
- `/usr/share/doc` and `/usr/share/bug` are emptied. The empty directories are
  kept because some tools expect them to exist.

APT is then purged from the target together with the packages that only support
it (APT support libraries, signature verification tooling and the archive
keyring). Its configuration, state, cache, logs and daily timers are removed.

The target still contains the dpkg database because it is the package database
used during bootstrap. It is not exposed as the user-facing package manager:
ULPM/LPK owns that role.

ULPM 6.0.0 is installed from the vendored `ulpm/` tree into
`/opt/bubbleos/ulpm`, with `/usr/local/bin/ulpm` and `/usr/local/bin/ulrm`
symlinks. The build also installs the engine's runtime toolchain
(`bubblewrap`, `squashfs-tools`, `squashfuse`, `fuse-overlayfs`, `fuse3`,
`jq`, `curl`, `openssl`, `xdg-dbus-proxy`, `file`, `binutils`) so LPK
packaging, installation and sandboxed execution work without APT. Override the
package list with `ULPM_PACKAGES` when building a leaner image.

```bash
ulpm --version
ulpm doctor                    # runtime, sandbox and tool diagnostics
ulpm pack ./hello hello hello_amd64.lpk 1.0.0
ulpm install hello_amd64.lpk
ulpm run hello
ulpm remove hello
```

Installed applications live in the user's XDG data directory, so they are not
part of the system generation. Package-driven generation composition is still
on the roadmap.

To keep APT temporarily for development, use `KEEP_APT=1`. That mode is not a
release image:

```bash
sudo KEEP_APT=1 FORCE=1 ./build/bootstrap.sh
```

The local 7.3.1 kernel is imported with a clean `uname -r` release (`7.3.1`).
`/proc/version` still names the original build host (`romain@debian`); a later
rebuild with `KBUILD_BUILD_USER=bubbleos KBUILD_BUILD_HOST=bubbleos` will make
that string fully bubbleOS-branded without changing the running release.

## Current status

The complete chain is functional with real Btrfs generations:

```text
UEFI (OVMF) -> ESP -> Limine -> Linux 7.3.1
     -> initramfs (early microcode + BusyBox) -> root=UUID=...
     -> Btrfs top-level -> @rootfs/current
     -> @rootfs/generations/000001
     -> switch_root -> systemd -> bubbleos-boot.service -> multi-user.target
```

Observed in QEMU:

```text
bubbleOS: resolving root UUID=b0bb1e05-4a2d-4f00-9000-000000000001
bubbleOS: waiting for root device /dev/vda2
bubbleOS: reading @rootfs/current from /dev/vda2
bubbleOS: mounting subvolume @rootfs/generations/000001 on /newroot
bubbleOS boot: generation 000001, root /dev/vda2 (btrfs, subvol @rootfs/generations/000001)
bubbleOS bubbleos ttyS0
bubbleos login:
```

`bubble boot` reports the mounted device and Btrfs subvolume; the stable UUID
is carried by the kernel command line. The UEFI entry uses `quiet`; the full
boot log remains available through `journalctl -b` and `dmesg`. Direct-kernel
boot stays verbose for debugging.

After login:

```bash
bubble status
bubble generations
bubble snapshots
systemctl is-system-running
systemctl status bubbleos-boot.service
journalctl -b

findmnt -no FSTYPE,OPTIONS /                      # btrfs, compress=zstd:1
findmnt -t btrfs                                  # @rootfs, @home, @var, @logs…
btrfs subvolume list /
btrfs property get -ts /snapshots/rootfs/000001-initial ro   # ro=true
cat /etc/issue
command -v apt-get        # should print nothing
cat /etc/dpkg/origins/default
cat /proc/cmdline         # root=UUID=... rootfstype=btrfs
uname -r                  # 7.3.1
find /lib/modules/7.3.1 -name '*.ko*' | wc -l    # 260
modprobe autofs4; echo $? # 0, autofs4 is built in
find /lib/firmware -type f | wc -l               # 2636
test -f /lib/firmware/amdgpu/aldebaran_mec2.bin && echo firmware-ok
ldconfig -p | grep -E 'libdrm_amdgpu|libwacom|libva'   # hardware userspace
find /usr/share/doc /usr/share/bug -mindepth 1   # no output
```

Generation workflow:

```bash
bubble generation create --description "smoke test"
bubble generation activate 000002
reboot
# after reboot: bubble status shows generation 000002
bubble rollback
reboot
# after reboot: generation 000001 is active again; /home and /var persisted
```

Final delivered image state (validated in QEMU on a copy):

- only generation `000001`, with `current -> generations/000001` and no
  `previous` link;
- `@snapshots/rootfs/000001-initial` and `@snapshots/var/000001-initial` are
  `ro=true`;
- `btrfs check --readonly out/bubbleos-root.img` reports `no error found`;
- the root partition of `out/bubbleos.img` is byte-identical to
  `out/bubbleos-root.img`;
- `uname -r` reports `7.3.1`, `systemctl --failed` lists no failed units and
  `systemctl is-system-running` reports `running`;
- `/lib/modules/7.3.1` contains 260 loadable modules plus the `modules.dep.bin`
  and `modules.builtin.bin` indexes; `modprobe autofs4` succeeds as a built-in;
- `/lib/firmware` contains 2636 files from the local drop, and the matching DRM,
  VA-API, libwacom, Thunderbolt and USB Type-C userspace libraries are present;
- `apt-get` is absent and `/etc/issue` shows the bubbleOS branding;
- root and persistent subvolumes are mounted with `compress=zstd:1`; the Btrfs
  image uses about 439 MiB of physical space for a 746 MiB RootFS tree.

A full workflow (create `000002`, activate, reboot, rollback to `000001`) was
also re-validated: `/home` and `/var` persisted, a file created only in
`000002` disappeared after rollback, and each activation produced read-only
generation and `/var` snapshots.

Remaining work:

1. package-driven generation composition through ULPM/LPK, including firmware
   and hardware userspace packages as LPK packages instead of build-time merges;
2. generation-specific kernel/initramfs entries in Limine for recovery;
3. kernel rebuild with bubbleOS build identity so `/proc/version` no longer
   names the original Debian build host.

## Testing in QEMU

The integration suite automates the checks below:

```bash
./tests/qemu/run.sh                 # all suites
./tests/qemu/run.sh boot            # boot smoke test
./tests/qemu/run.sh generations     # create/activate/rollback + Limine entries
./tests/qemu/run.sh fallback        # broken current + missing subvolume
./tests/qemu/run.sh snapshots       # /var restore + pruning
./tests/qemu/run.sh ulpm            # diagnostics + LPK pack/install/run
```

It requires `python3-pexpect`, QEMU/OVMF and passwordless `sudo`, and works on
a temporary copy of `out/bubbleos.img`. See `tests/qemu/README.md` for details.

For a manual boot:

```bash
sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
```

At the serial console:

```text
bubbleos login: root
Password:       bubble
```

Useful checks:

```bash
uname -r
bubble status
bubble generations
bubble snapshots
findmnt -no FSTYPE,SOURCE,OPTIONS /
btrfs subvolume list /
btrfs property get -ts /snapshots/rootfs/000001-initial ro
systemctl is-system-running
systemctl status bubbleos-boot.service
systemctl --failed
journalctl -b
```

On the build host, the image can also be inspected without booting:

```bash
sudo btrfs check --readonly out/bubbleos-root.img
sudo mount -o loop,ro out/bubbleos-root.img /mnt
sudo btrfs subvolume list /mnt
sudo btrfs property get -ts /mnt/@snapshots/rootfs/000001-initial ro
sudo umount /mnt
```

The target does not ship `filefrag` (it belongs to e2fsprogs), so compression
is verified from the build host. A compressible file written in the guest
reports `encoded` extents when the image is inspected with `filefrag -v`.

The RootFS partition of `out/bubbleos.img` is a byte-for-byte copy of
`out/bubbleos-root.img`:

```bash
dd if=out/bubbleos.img bs=1M skip=129 count=2048 status=none | sha256sum
sha256sum out/bubbleos-root.img
```

To keep the delivered image clean, boot a copy when testing (the automated
suite does this for every run):

```bash
cp --sparse=always out/bubbleos.img /tmp/bubble-test.img
sudo DISK_IMAGE=/tmp/bubble-test.img ./build/run-qemu.sh
```

Shut down cleanly with `poweroff`, or quit QEMU with `Ctrl-A`, then `X`.
The disk image is writable: changes made inside the guest persist in the image
unless it is rebuilt.

## Useful overrides

```bash
sudo FORCE=1 SUITE=stable ./build/bootstrap.sh
sudo ROOT_PASSWORD='change-me' FORCE=1 ./build/bootstrap.sh
sudo SYSTEMD=0 FORCE=1 ./build/bootstrap.sh
sudo KEEP_APT=1 ./build/bootstrap.sh
sudo ROOTFS=/tmp/bubble-rootfs ./build/bootstrap.sh
sudo SIZE=4G FORCE=1 ./build/build-image.sh
sudo GENERATION=000002 FORCE=1 ./build/build-image.sh
MOUNT_DIR=/tmp/bubble-mnt sudo -E ./build/build-image.sh
ESP_SIZE=256M ./build/build-disk-image.sh
KERNEL_RELEASE=... MODULE_ROOT=... ./build/build-initramfs.sh
KERNEL=... ROOT_IMAGE=... ./build/run-qemu.sh
```

The RootFS is written by default to `out/rootfs/`, the RootFS image to
`out/bubbleos-root.img`, and the bootable disk to `out/bubbleos.img`.
