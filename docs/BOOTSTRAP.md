# bubbleOS Bootstrap

`build/bootstrap.sh` creates the first development RootFS for bubbleOS.
`build/build-disk-image.sh` assembles a bootable UEFI and legacy BIOS disk
image.

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

The current milestone already implements the store/composition split: ULPM
verifies and imports signed system LPKs into a content-addressed store, and
`bubble` composes their payloads into a new generation from a package lock.

## Build requirements

On the build host:

```bash
sudo apt install debootstrap busybox-static cpio gzip xz-utils zstd kmod \
                 btrfs-progs dosfstools mtools fdisk ovmf qemu-system-x86 gcc
```

The disk builder expects the Limine 12.9.6 `limine-binary` release in
`out/tools/limine-binary/` (`BOOTX64.EFI`, `limine-bios.sys`, `limine.c`).
It compiles the host `limine` tool automatically when it is missing.

`bubble-settings` is compiled inside the target chroot; the GTK development
packages (`gcc`, `make`, `libc6-dev`, `libgtk-3-dev`, `pkg-config`) are
installed temporarily by `build/bootstrap.sh` and purged before the image is
packed. They do not need to be installed on the build host. By default
`build/build-kernel.sh` imports the locally built kernel from
`boot/vmlinuz-bubbleos` and `../bubble-modules/`; no host APT access is needed
for that path. The Debian package fallback (`KERNEL_SOURCE=debian`) still uses
`apt-get` and therefore requires a working APT configuration **on the build
host only**.

Firmware blobs are read from `../firmware/<package>/usr/lib/firmware/`;
`FIRMWARE_DIR` can point at another drop. The hardware userspace packages
(`bolt`, `libdrm-*`, `libwacom9`/`libwacom-common`, `libtypec0`, `libusb3380`,
`intel-media-va-driver`) are installed by debootstrap from the target suite,
not copied from the drop. `HARDWARE_USERSPACE=0` skips them while keeping the
firmware merge.

## Full build

```bash
# 1. Kernel and modules (local 7.2.15-zen1-rt5 import, no compilation)
./build/build-kernel.sh

# 2. Initramfs: storage modules + early microcode
./build/build-initramfs.sh

# 3. RootFS (debootstrap), complete module tree, firmware and Btrfs image
sudo ./build/bootstrap.sh
sudo ./build/build-image.sh

# 4. Bootable GPT disk: BIOS boot + ESP + RootFS
./build/build-disk-image.sh

# 5. Boot it under UEFI (OVMF) or legacy BIOS (SeaBIOS)
sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
sudo UEFI=0 DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
```

Direct-kernel boot remains available for debugging. `run-qemu.sh` uses
`out/kernel/vmlinuz` automatically when it exists (override with `KERNEL=...`):

```bash
sudo ROOT_IMAGE=out/bubbleos-root.img ./build/run-qemu.sh
./build/run-qemu.sh                    # initramfs rescue shell, no disk
```

## Kernel

By default `build/build-kernel.sh` imports the locally built bubbleOS kernel:

- `boot/vmlinuz-bubbleos` — bzImage, release **7.2.15-zen1-rt5**;
- `../bubble-modules/lib/modules/7.2.15-zen1-rt5` — matching module tree.

`build/import-kernel.sh` validates the image and checks that the boot-critical
drivers (`btrfs`, `ext4`, `virtio_blk`, `virtio_pci`, `ahci`, `ata_piix`,
`sd_mod`, `autofs4`) are either built in or present as modules. The result is:

```text
out/kernel/
├── vmlinuz                         # copy of boot/vmlinuz-bubbleos
├── root/usr/lib/modules/7.2.15-zen1-rt5/ # complete tree + indexes
└── kernel.env                      # KERNEL_RELEASE, KERNEL_IMAGE, MODULE_ROOT
```

The 7.2.15 configuration keeps `btrfs`, `ext4`, `virtio_blk`, `virtio_pci`,
`ahci`, `ata_piix`, `sd_mod`, `autofs4`, `loop`, `overlay` and `binfmt_misc`
built in, so the initramfs needs no loadable storage module. Loadable drivers
are installed as zstd-compressed modules (106 `.ko.zst` files). The kernel is
built with the ZEN patch set and PREEMPT_RT, `HZ=1000`, `NO_HZ_FULL` and clang
ThinLTO.

The Debian package path is only a bootstrap fallback for a host that does not
have the local kernel:

```bash
KERNEL_SOURCE=debian ./build/build-kernel.sh
```

`build/bootstrap.sh` copies the complete 7.2.15 module tree into the target's
`/lib/modules/7.2.15-zen1-rt5` and runs `depmod` inside the RootFS. The generated
`modules.dep.bin` and `modules.builtin.bin` are required for libkmod/systemd to
recognize built-in modules; without them systemd reports
`Failed to find module 'autofs4'` and the binfmt_misc automount is unsupported.
The module tree also provides the loadable graphics, Wi-Fi, audio, Bluetooth,
game controller and other drivers built by the local kernel. The reference
machine's Ralink RT2790 needs `CONFIG_RT2800PCI=m`; the driver stack is then
`rt2800pci`/`rt2800mmio`/`rt2800lib`/`rt2x00pci` plus `rt2x00mmio` and
`rt2x00lib`.

Controller support uses the mainline HID drivers: `xpad` for Xbox 360 and
Xbox One/Series over USB, `hid-microsoft` for Xbox controllers over Bluetooth,
`hid-sony` for the PS3, `hid-playstation` for the PS4/PS5 (with
`led-class-multicolor`), `hid-nintendo` for the Switch Pro/Joy-Con and
`hid-steam`. `uinput` and `uhid` are enabled for Steam Input and user-space
remappers. The `bubble` user is already in the `input` group and logind grants
the active seat access to event and joystick devices; an additional udev rule
(`60-uinput.rules`) makes `/dev/uinput` group `input`, mode `0660`.

## Firmware and early microcode

`build/bootstrap.sh` merges every `firmware/*/usr/lib/firmware` payload into
`/usr/lib/firmware` (3000+ files in the current drop): AMD, Intel and NVIDIA
graphics, Intel Wi-Fi, MediaTek, Realtek, Cirrus, SOF audio, plus `amd-ucode`
and `intel-ucode`. Ownership is normalized to `root:root` and regular files to
mode `0644`.

The NVIDIA payload in the drop comes from Debian's
`firmware-nvidia-graphics` package and provides the `acr`, `gr`, `sec2`,
`nvdec` and GSP firmware used by nouveau across the GP10x, Turing, Ampere and
Ada families; `gp107` is the GeForce GTX 1050 Ti used by the reference
machine.

The MediaTek payload also ships the legacy Ralink firmware, including
`rt2860.bin` for the reference machine's RT2790 PCI card.

The hardware userspace packages (`bolt`, `libdrm-*`,
`libwacom9`/`libwacom-common`, `libtypec0`, `libusb3380`,
`intel-media-va-driver`) are resolved by the same debootstrap transaction, so
dpkg installs their libraries, data files and maintainer scripts from the
target suite. Only `/usr/lib/firmware` is taken from the drop: its `/usr/lib`
binaries are never copied, because the drop can be extracted from a newer
Debian and would shadow the suite's glib, systemd and DRM libraries. Set
`HARDWARE_USERSPACE=0` to install only firmware.

NVK (Mesa's Vulkan driver) needs Mesa 25.1 or newer to support Pascal GPUs
such as the GP107. Debian 13 ships Mesa 25.0, so `build/bootstrap.sh` installs
only `mesa-vulkan-drivers` from `trixie-backports`, pinned, while the GL/EGL
stack stays on the stable suite. Set `MESA_VULKAN_SUITE` to another backports
suite, or to `none`, to override this.

`build/build-initramfs.sh` creates an **uncompressed** cpio archive containing:

```text
kernel/x86/microcode/AuthenticAMD.bin
kernel/x86/microcode/GenuineIntel.bin
```

It concatenates the vendor microcode files in sorted order and prepends the
archive to the compressed main initramfs, as documented by the kernel. The
kernel loads the matching patch before the root filesystem is mounted. Set
`MICROCODE=0` to skip this step.

When the guest runs under a hypervisor, the 7.2.15 kernel deliberately disables
microcode loading (unless built with `CONFIG_MICROCODE_DBG`). A QEMU/KVM boot
with `-cpu host,-hypervisor` bypasses that check and logs
`microcode: Current revision: 0x...` while exposing
`/sys/devices/system/cpu/microcode`, confirming that the early archive path is
active. Whether a patch is applied still depends on the host CPU model being
present in the vendor file; on bare metal the matching patch is applied before
the root filesystem is mounted.

## bubble-settings

`settings/` contains the native GTK3 control center, its privileged helper,
the polkit action, the stylesheet, the desktop entry and the icon. The target
image does not ship a compiler, so `build/bootstrap.sh` builds the sources
inside the target chroot, with a temporary toolchain, before APT is removed:

1. copy `settings/` to `/usr/src/bubbleos/settings` and delete any host-built
   binary or object file;
2. mark every installed package manual, then install `gcc`, `make`,
   `libc6-dev`, `libgtk-3-dev` and `pkg-config` from the target suite;
3. run `make` and `make install` in the chroot, then update the icon cache and
   the desktop database;
4. purge the build packages, run `apt-get autoremove --purge`, and fail the
   build if `gcc` or either installed binary is still present.

`BUILD_SETTINGS` follows `DESKTOP` by default and can be set to `0` to skip the
control center (only valid when `DESKTOP=0`). The installed paths are:

| Path | Content |
|---|---|
| `/usr/bin/bubble-settings` | GTK3 frontend |
| `/usr/libexec/bubbleos/bubble-settings-helper` | root helper, called through `pkexec` |
| `/usr/share/polkit-1/actions/org.bubbleos.settings.policy` | `org.bubbleos.settings.users` action |
| `/usr/share/bubbleos/settings/bubble-settings.css` | cyber-punk stylesheet |
| `/usr/share/applications/bubble-settings.desktop` | application entry |
| `/usr/share/icons/hicolor/scalable/apps/bubbleos-settings.svg` | icon |

`lxpolkit` provides the graphical polkit authentication agent; it is started
by `bubble-desktop session`. `bubble-settings --doctor` and
`bubble-desktop doctor` check the installed files, the polkit helper path and
the account-management commands (`useradd`, `usermod`, `userdel`, `chpasswd`,
`pkexec`, `lxpolkit`).

## Disk layout

`out/bubbleos.img` uses GPT:

| Partition | Offset | Size | Type | Content |
|---|---|---|---|---|
| 1 | 1 MiB | 1 MiB | BIOS boot | Limine BIOS stage 2 |
| 2 | 2 MiB | 128 MiB | EFI System | FAT32: Limine, kernel, initramfs, config |
| 3 | 130 MiB | 3 GiB | Linux | Btrfs RootFS with generation subvolumes |

ESP contents:

```text
/EFI/BOOT/BOOTX64.EFI
/EFI/BOOT/limine.conf
/limine.conf
/limine-bios.sys
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

## System package store and generation composition

The bootstrap generation (`000001`) has an empty package lock and no store
packages. A system package is imported at runtime with:

```bash
ulpm store add ./package.lpk
ulpm store list
ulpm store verify io.bubbleos.example=1.0.0
```

`ulpm store add` verifies the LPK signature, extracts the payload, writes the
content-addressed object under `/var/lib/bubbleos/store/objects/<sha256>/` and
links it as `packages/<id>/<version>`. Importing the same LPK twice is a no-op.
Application LPKs are rejected: only manifests describing a system tree
(`rootfs`/`os`/`distro`/`system`, or no type with `etc/` and `usr/`) are
accepted by the system store.

`bubble` builds generations from the stored set:

```bash
bubble install ./package.lpk             # compose + activate (reboot required)
bubble install io.bubbleos.example       # newest stored version
bubble install ./dep.lpk ./app.lpk       # closed dependency set
bubble remove io.bubbleos.example        # compose without the package
bubble packages                          # show the current package lock
bubble generation compose --activate     # recompose the same lock
```

Each generation records its set in `/etc/bubbleos/packages.json`:

```json
{
  "format": 1,
  "base_generation": "000001",
  "packages": [
    {"id": "...", "version": "...", "digest": "...", "type": "rootfs",
     "name": "..."}
  ]
}
```

Composition snapshots the package-free base generation, overlays every pinned
payload in package-ID order, rewrites the lock and generation metadata, and
validates `/etc/os-release`, a shell and the generation's boot assets. The
result is activated only after validation. Starting from the clean base means
an upgrade or removal cannot leave files from the previous version behind.

Local installs remain closed-set: `bubble install` accepts the LPKs given on
the command line and rejects the operation if a manifest dependency is absent
or if the selected version does not satisfy its constraint. The store lives on
`@var`, so store contents and `/var` snapshots stay consistent.
`ulpm store remove --gc` and `bubble store gc` scan every retained
generation's `/etc/bubbleos/packages.json` before deleting an object, so a
package pinned by a generation survives even when its store link is removed.
An unreadable generation lock aborts the collection. Run
`bubble generation delete` or `bubble generation prune` first when an object
should become collectable.

## Signed system repositories

Repository state is split from the user ULPM environment so it is available
before login and survives generations and rollbacks:

| Path | Purpose |
|---|---|
| `/var/lib/bubbleos/ulpm/repos/` | repository configs and pinned publisher keys |
| `/var/lib/bubbleos/ulpm/trusted_keys/` | trusted LPK signing keys |
| `/var/cache/bubbleos/ulpm/repos/` | verified index and signature caches |
| `/var/cache/bubbleos/ulpm/downloads.*/` | temporary payload staging |

```bash
bubble repo add main https://packages.example.org/bubbleos ./publisher.pub
bubble repo update
bubble repo verify
bubble repo packages [--json]
bubble repo search [--all] <query>
bubble install io.bubbleos.example
bubble update [--json]
bubble upgrade [--dry-run] [package...]
```

The repository index uses the `ulpm-repository-v1` format and carries a
`type` field per package. It is signed with Ed25519 and verified against the
fingerprint pinned by `repo add`; a cached index that does not verify is
ignored by the catalogue. Only packages typed `rootfs`, `os`, `distro` or
`system` are eligible for system composition (`--all` also searches
application packages).

`bubble update` refreshes the indexes and prints the resolved upgrade plan
without composing. `bubble upgrade` runs the same resolver, downloads each
payload, checks its SHA-256 against the signed index and its Ed25519 signature
against the system trust store, imports it into `/var/lib/bubbleos/store`,
verifies the complete dependency closure and composes exactly one generation.
A failure at any step leaves the current generation untouched. The system ULPM
environment is used for repository installs; local LPKs keep using the caller's
ULPM environment for backward compatibility.

The QEMU `store` suite validates import, clean composition, upgrade, removal,
dependency rejection, signed-package rejection and rollback across reboots.
The QEMU `repo` suite validates pinned repository keys, catalogue filtering,
dependency resolution, `update`/`upgrade`, checksum and trust rejection,
idempotent upgrades and persistence across reboots.

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
| `graphical.target` | default boot target when `DESKTOP=1` |
| `multi-user.target` | default boot target when `DESKTOP=0` |
| `getty@tty1.service` | local console login |
| `serial-getty@ttyS0.service` | QEMU serial login |
| `greetd.service` | login manager on VT7, aliased as `display-manager.service` |
| `NetworkManager.service` | Wi-Fi, Ethernet and VPN management |
| `bluetooth.service` | BlueZ daemon |
| `bubbleos-boot.service` | records the booted generation and subvolume |
| `pipewire.socket` / `pipewire-pulse.socket` / `wireplumber.service` | globally enabled user audio units |

`lxpolkit` is not a system service: `bubble-desktop session` starts it as a
child of the graphical session so polkit prompts appear on the user's display.
`bubble-desktop apply` restarts it if it is missing.

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

### Desktop session

The default build (`DESKTOP=1`) adds a complete Wayfire desktop. The bootstrap
installs the compositor and companion applications with the same debootstrap
transaction as the base system, before APT is removed:

- `wayfire`, the `winshadows` and `wstroke` plugins, `waybar`, `fuzzel`,
  `mako-notifier`, `swaybg`, `foot`, `swaylock`, `swayidle`, `grim`, `slurp`,
  `wlopm`, `wcm`, `wlr-randr` and `kanshi`;
- `greetd` + `tuigreet`, NetworkManager, BlueZ, Polkit, PipeWire/WirePlumber,
  the wlr desktop portal and Xwayland;
- Inter, JetBrains Mono, Font Awesome, Noto Color Emoji and the vendored
  Orbitron font, Papirus icons, Bibata cursors and the GTK/Adwaita themes;
- `evtest`, `jstest`/`fftest`, `lsusb`, `lspci`, the SDL2/SDL3 runtimes and
  the SDL `testgamecontroller`/`testjoystick` tools for controller and
  hardware diagnostics.

`dbus-user-session` and `libspdlog1.15` are listed explicitly because
debootstrap does not resolve the virtual `default-dbus-session-bus` and
`libspdlog1.15-fmt10` dependencies of `xdg-desktop-portal` and `waybar`.
Likewise, `libva2` is listed with the hardware userspace packages because
debootstrap does not resolve the `libva-driver-abi-1.22` virtual dependency of
`intel-media-va-driver`.

The build creates the desktop user `bubble` (password `bubble`) with the
`audio`, `video`, `input`, `render`, `lp`, `plugdev`, `sudo` and `bluetooth`
groups. `_greetd` is created by the greetd package's sysusers file and checked
by the build. `/usr/share/wayland-sessions/bubbleos.desktop` starts
`/usr/local/bin/bubble-desktop session`; greetd runs `tuigreet` on VT 7 with
that session preselected and a user menu limited to regular accounts
(UID 1000+). Wayfire refuses to run as root, and `/etc/pam.d/greetd` rejects
root as well; the serial console and tty1 remain the root recovery logins.

Desktop defaults live in `/etc/bubbleos/desktop.conf` and
`/usr/share/bubbleos/desktop/` (Wayfire, Waybar, Fuzzel, Mako, foot, swaylock,
wallpaper). Users override keys in `~/.config/bubbleos/desktop.conf` with
`bubble-desktop config`. The build validates the desktop configuration with
`bubble-desktop doctor` in the QEMU test suite. Set `DESKTOP=0` to build the
previous console-only image without the desktop packages, user or greetd.

`build/prune-rootfs.sh` runs at the end of the bootstrap and again before
`build-image.sh` packs the RootFS. It removes the unused Papirus/Bibata
variants, translations other than French and English, `man`/`info` pages when
no reader is installed, `gprofng` and non-French GTK emoji data. Firmware,
kernel modules and the configured icon/cursor themes are kept. Use
`sudo DRY_RUN=1 ./build/prune-rootfs.sh` to preview the removals.

### Generations and snapshots

```bash
bubble generations                     # list generation subvolumes
bubble generation create               # clone current -> next number
bubble generation create --from 000001 --description "test"
bubble generation activate 000002      # select for next boot
bubble generation current              # print selected generation
bubble generation delete 000003        # remove an unused generation
bubble generation prune --keep 3       # keep newest 3 + protected generations
bubble generation prune --dry-run      # show what would be deleted
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

`bubble generation delete <gen>` refuses the current, previous and running
generations, as well as any generation used as the `base_generation` of
another generation's package lock. `bubble generation prune --keep N` keeps
the newest N generations (default: 3), the protected generations, and every
base generation required by a survivor; it deletes the rest. Both commands
refresh the Limine menu, and the sync pass removes private ESP assets for the
deleted generations.

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

The local kernel is imported with the release `7.2.15-zen1-rt5`.
`/proc/version` reports the local build identity (`romain@debian`, `#1 ZEN
SMP PREEMPT_RT`) without changing the running release.

## Current status

The complete chain is functional with real Btrfs generations:

```text
UEFI (OVMF) -> ESP -> Limine --------------------------------+
BIOS (SeaBIOS) -> MBR (stage 1) -> BIOS boot (stage 2) -----+
     -> Linux 7.2.15-zen1-rt5
     -> initramfs (early microcode + BusyBox) -> root=UUID=...
     -> Btrfs top-level -> @rootfs/current
     -> @rootfs/generations/000001
     -> switch_root -> systemd -> bubbleos-boot.service
     -> graphical.target -> greetd/tuigreet (VT7)
     -> bubble-desktop session -> Wayfire
```

Observed in QEMU:

```text
bubbleOS: resolving root UUID=b0bb1e05-4a2d-4f00-9000-000000000001
bubbleOS: waiting for root device /dev/vda3
bubbleOS: reading @rootfs/current from /dev/vda3
bubbleOS: mounting subvolume @rootfs/generations/000001 on /newroot
bubbleOS boot: generation 000001, root /dev/vda3 (btrfs, subvol @rootfs/generations/000001)
bubbleOS bubbleos ttyS0
bubbleos login:
```

`bubble boot` reports the mounted device and Btrfs subvolume; the stable UUID
is carried by the kernel command line. The firmware entry uses `quiet`; the
full boot log remains available through `journalctl -b` and `dmesg`.
Direct-kernel boot stays verbose for debugging.

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
uname -r                  # 7.2.15-zen1-rt5
find /lib/modules/7.2.15-zen1-rt5 -name '*.ko*' | wc -l    # 106
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
- `uname -r` reports `7.2.15-zen1-rt5`, `systemctl --failed` lists no failed units and
  `systemctl is-system-running` reports `running`;
- `/lib/modules/7.2.15-zen1-rt5` contains 106 loadable modules plus the `modules.dep.bin`
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

1. full package-driven base composition, replacing build-time merges with
   repository packages;
2. mirror policy hardening (key rotation, revocation and multi-mirror failover);
3. the installer/ISO path.

## Testing in QEMU

The integration suite automates the checks below:

```bash
./tests/qemu/run.sh                 # all suites
./tests/qemu/run.sh boot            # boot smoke test
./tests/qemu/run.sh bios            # legacy BIOS/SeaBIOS through Limine MBR
./tests/qemu/run.sh generations     # create/activate/rollback + Limine entries
./tests/qemu/run.sh fallback        # broken current + missing subvolume
./tests/qemu/run.sh snapshots       # /var restore + pruning
./tests/qemu/run.sh store           # store, composition, upgrade/remove/rollback
./tests/qemu/run.sh repo            # signed repositories + update/upgrade
./tests/qemu/run.sh ulpm            # diagnostics + LPK pack/install/run
./tests/qemu/run.sh desktop         # Wayfire, Waybar, Fuzzel, Mako, greetd
```

It requires `python3-pexpect`, QEMU (with OVMF and SeaBIOS) and passwordless
`sudo`, and works on a temporary copy of `out/bubbleos.img`. See
`tests/qemu/README.md` for details.

For a manual boot:

```bash
sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh          # UEFI/OVMF
sudo UEFI=0 DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh   # legacy BIOS
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
sudo DESKTOP=0 FORCE=1 ./build/bootstrap.sh
sudo DESKTOP_USER=alice DESKTOP_USER_PASSWORD='change-me' FORCE=1 ./build/bootstrap.sh
sudo DESKTOP_PACKAGES='wayfire waybar' FORCE=1 ./build/bootstrap.sh
sudo MESA_VULKAN_SUITE=none FORCE=1 ./build/bootstrap.sh
sudo MESA_VULKAN_SUITE=trixie-backports FORCE=1 ./build/bootstrap.sh
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
