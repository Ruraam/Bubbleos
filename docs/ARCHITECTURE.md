# bubbleOS Architecture

## Core principle

bubbleOS uses the Linux kernel and ULPM/LPK as its native package ecosystem.

The repository contains a BubbleOS-maintained copy of ULPM in `ulpm/`. This copy may be adapted for operating-system requirements without changing the independent ULPM upstream repository.

## Responsibilities

### ULPM

ULPM remains the package engine responsible for package acquisition, verification, dependency handling, transactions and LPK operations.

The vendored ULPM 6.0.0 is installed in `/opt/bubbleos/ulpm` and exposed as
`/usr/local/bin/ulpm` and `/usr/local/bin/ulrm`. The build installs its runtime
toolchain (`bubblewrap`, `squashfs-tools`, `squashfuse`, `fuse-overlayfs`,
`fuse3`, `jq`, `curl`, `openssl`, `xdg-dbus-proxy`, `file`, `binutils`), so the
target can build, inspect, install, run and remove LPK applications without
APT. Application installs stay in the user's XDG directories; the system
generation is not modified. Generation composition through ULPM is the next
integration step.

### BubbleOS Core

The `bubble/` layer owns operating-system concerns:

- system state paths;
- generations;
- activation;
- rollback orchestration;
- boot integration (generation validation and boot records).

## Generation model

A generation is a writable Btrfs subvolume containing a complete system root.
The previous generation remains available for rollback. ULPM will eventually
compose packages into a new generation before activation; the Btrfs layout and
the activation mechanics are already in place.

```text
Btrfs filesystem (UUID b0bb1e05-…-000000000001)
├── @rootfs/                          -> /var/lib/bubbleos/rootfs
│   ├── generations/
│   │   ├── 000001/                   -> / (active generation)
│   │   └── 000002/
│   ├── current -> generations/000001
│   └── previous -> generations/000001 (after a switch)
├── @home                             -> /home
├── @var                              -> /var
├── @logs                             -> /var/log
└── @snapshots                        -> /snapshots
    ├── rootfs/000001-initial/        read-only restore point
    └── var/000001-initial/           read-only restore point
```

All writes use **zstd level 1** compression and the filesystem keeps data
checksums (`crc32c` by default). Snapshots are created with `btrfs subvolume
snapshot -r`, so restore points cannot be modified.

`bubble generation create` snapshots the active generation subvolume into the
next numbered subvolume (`000002`, `000003`, …). `bubble generation activate`
first creates read-only snapshots of the outgoing generation and of `/var`,
then updates `@rootfs/previous` and `@rootfs/current`. The running system keeps
using its root until reboot; the initramfs selects the new generation on the
next boot. `bubble rollback` activates the previous generation.

Each generation stores the kernel and initramfs it was built with in
`/usr/lib/bubbleos/boot/`. `bubble bootloader sync` keeps the shared ESP pair
(`/boot/vmlinuz`, `/boot/initramfs.cpio.gz`) aligned with the current
generation. A generation whose assets differ from the current one gets private
copies under `/boot/generations/<gen>/`, which are pruned when the generation
is removed or starts sharing the current assets. Cloned generations therefore
do not duplicate the ~34 MiB kernel/initramfs pair on the 128 MiB ESP.

`/home` is never rolled back. `/var` is shared between generations and
snapshotted on each activation so its state at the switch is preserved.
`/var/log` is a separate subvolume and is therefore not part of `/var`
snapshots.

A `/var` restore is staged in `@snapshots/var-restore.request`. On the next
boot, `bubbleos-var-restore.service` runs before `var.mount`, replaces `@var`
with a writable copy of the selected read-only snapshot, and keeps the previous
`@var` as a `pre-restore` snapshot. Automatic pruning keeps the newest
`BUBBLEOS_SNAPSHOT_KEEP` snapshots (default: 10); `*-initial` points and a
pending restore point are never pruned.

The legacy metadata layout under `/var/lib/bubbleos/{generations,current}` is
no longer used. `/var/lib/bubbleos/rootfs` is the runtime mount point of the
`@rootfs` generation container.

## Boot chain (current milestone)

```text
UEFI firmware (OVMF in QEMU)
 └── GPT disk
      ├── partition 1: FAT32 ESP
      │    ├── /EFI/BOOT/BOOTX64.EFI   (Limine 12.9.6)
      │    ├── /limine.conf            (menu rendered from generations)
      │    ├── /vmlinuz                (Linux 7.3.1, guest /boot/vmlinuz)
      │    ├── /initramfs.cpio.gz      (early microcode + BusyBox)
      │    └── /generations/<gen>/     (private assets for older kernels)
      └── partition 2: Btrfs RootFS
           └── Linux 7.3.1
                └── initramfs (BusyBox + storage modules + microcode)
                     └── /init
                          ├── resolves root=UUID=... to the RootFS device
                          ├── reads @rootfs/current and @rootfs/previous
                          ├── tries rootflags, current, previous, newest
                          ├── mounts the first usable generation as /newroot
                          └── switch_root /newroot
                               └── systemd (PID 1)
                                    ├── udev, D-Bus, PAM sessions
                                    ├── bubbleos-var-restore.service
                                    │   └── restores @var before var.mount
                                    ├── fstab mounts @home, @var, @logs,
                                    │   @snapshots, @rootfs and the ESP on /boot
                                    ├── serial/getty login prompts
                                    └── bubbleos-boot.service
                                         └── bubble boot
                                              └── records the booted
                                                  generation and subvolume
```

`build/build-kernel.sh` imports the locally built 7.3.1 kernel
(`boot/vmlinuz-bubbleos` and `bubble-modules/`) into `out/kernel/`; a Debian
package download remains available as a host bootstrap fallback
(`KERNEL_SOURCE=debian`). `build/build-initramfs.sh` builds the early userspace
and prepends an uncompressed microcode cpio archive,
`build/build-image.sh` packs the RootFS into a Btrfs image, and
`build/build-disk-image.sh` assembles the GPT/ESP disk consumed by
`build/run-qemu.sh`.

The bootloader and kernel live in the ESP, which is mounted read-write at
`/boot` so `bubble bootloader sync` can regenerate the Limine menu. The RootFS
carries systemd and the generation subvolumes. `bubbleos-var-restore.service`
applies a pending `/var` restore before the fstab mounts, then
`bubbleos-boot.service` records the booted generation and Btrfs subvolume in
`/run/bubbleos` and `/var/lib/bubbleos/boot/last`.

The RootFS identity is defined once in `config/rootfs.env`: a fixed Btrfs UUID
is written by `build/build-image.sh` and rendered into the Limine command line
by `build/build-disk-image.sh`. The initramfs resolves `root=UUID=...` with
BusyBox `findfs`, so boot does not depend on the device being `/dev/vda2`.
The GPT partition UUID is fixed as well. `PARTUUID=` is not used for `root=`
because BusyBox `findfs` cannot resolve it and direct-kernel boot exposes the
RootFS as a bare image without a partition table.

`bubble bootloader sync` regenerates `/boot/limine.conf` from
`@rootfs/generations/*`. The first entry omits `rootflags` and follows
`@rootfs/current`; every other generation gets an explicit
`rootflags=subvol=@rootfs/generations/<gen>` entry. `generation create`,
`activate` and `rollback` call the generator automatically. The ESP is mounted
at `/boot` with `nofail`, so a direct-kernel boot without an ESP still works;
the sync becomes a no-op when `/boot` is not a mount point.

The initramfs accepts the same explicit `rootflags=...` override. With or
without it, a missing or unmountable subvolume triggers the fallback chain:
`current`, `previous`, then the newest generation. Only when every candidate
fails does the initramfs drop to its rescue shell.

The fstab inside each generation is rendered from `config/rootfs.env` by
`build/bootstrap.sh` and mounts the persistent subvolumes by filesystem UUID.
The root entry is deliberately absent: the initramfs already mounted the
selected generation before systemd starts.

`build/bootstrap.sh` installs `btrfs-progs` in the target and copies the complete
7.3.1 module tree into `/lib/modules/7.3.1`, then runs `depmod` in the target.
The resulting `modules.dep.bin` and `modules.builtin.bin` let libkmod/systemd
handle both loadable drivers and built-ins (`btrfs`, `virtio_blk`, `autofs4`,
`loop`, `overlay`, `binfmt_misc`). The initramfs only copies the loadable
storage modules (`ext4`, `ata_piix` and their dependencies); built-in drivers
are reported as `builtin` by libkmod and need no initramfs copy.

Firmware is not compiled into the kernel. `build/bootstrap.sh` merges every
`firmware/*/usr/lib/firmware` payload from the local drop into
`/usr/lib/firmware` and normalizes ownership and modes. The same drop provides
the userspace consumers of that firmware (`libdrm-*`, `intel-media-va-driver`,
`libwacom`, `bolt`, `libtypec0`, `libusb3380`); they are merged without
replacing base-package files. `build/build-initramfs.sh` uses the Intel and AMD
microcode directories to build the early `kernel/x86/microcode/*.bin` cpio
archive required by the kernel's early loader.

SELinux is present in the supplied kernel configuration but bubbleOS does not
ship a policy. The boot command line sets `selinux=0` so the kernel does not try
to load `/etc/selinux/default/policy/policy.35`; adding SELinux later requires a
policy package and an explicit permissive/enforcing decision.

The RootFS exposes the bubbleOS identity (`/etc/os-release`, `/etc/issue`,
`/etc/dpkg/origins/default`). APT is not installed in the target; ULPM/LPK is
the package layer. The dpkg database is kept only as build-time package
metadata and is not the user-facing package manager. `uname -r` reports the
clean `7.3.1` release; `/proc/version` still carries the build host used to
produce the current image and can be rebuilt with `KBUILD_BUILD_USER`/
`KBUILD_BUILD_HOST` set to bubbleOS values.

### Boot activation roadmap

1. **Current** — real Btrfs generations: `@rootfs/current` selects the root
   subvolume; activation creates read-only generation and `/var` snapshots.
   The 7.3.1 kernel, complete module tree, firmware and early microcode are
   integrated. `bubble bootloader sync` writes one Limine entry per generation
   and the initramfs falls back across current/previous/newest.
   `/var` can be restored from a snapshot before `var.mount`, and old automatic
   snapshots are pruned. ULPM runs without APT and its LPK
   pack/inspect/install/run/remove workflow is validated in QEMU. Every
   generation carries its own kernel/initramfs pair; the ESP keeps private
   copies only for generations whose assets differ from the current one.
2. **Next** — compose generations in ULPM's store.
3. **Later** — rebuild the kernel with bubbleOS build identity
   (`KBUILD_BUILD_USER=bubbleos`, `KBUILD_BUILD_HOST=bubbleos`) so
   `/proc/version` no longer mentions the original Debian build host.
