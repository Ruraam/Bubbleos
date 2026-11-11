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
APT. Application installs stay in the user's XDG directories and do not modify
the system generation.

ULPM also owns the system package store (`ulpm store`): it verifies the LPK
signature, extracts the payload, indexes its files and metadata, and exposes it
by package ID and version. ULPM does not create or activate generations; that
remains the bubbleOS core's responsibility.

### BubbleOS Core

The `bubble/` layer owns operating-system concerns:

- system state paths;
- generations;
- activation;
- rollback orchestration;
- boot integration (generation validation and boot records);
- package locks and store-backed generation composition.

## Generation model

A generation is a writable Btrfs subvolume containing a complete system root.
The previous generation remains available for rollback. `bubble install`,
`bubble remove` and `bubble generation compose` build a new generation from a
package-free base and the package lock before activation.

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

`bubble generation delete <gen>` removes a generation that is not current,
previous or running, and refuses any generation named as the
`base_generation` of another generation's package lock. `bubble generation
prune` keeps the newest generations (default: 3), the protected generations and
the transitive set of their base generations, then deletes the rest. Both
commands refresh the Limine menu; private ESP assets are pruned by the same
`bubble bootloader sync` pass.

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

## System package store

System packages are not unpacked over the running root. They are imported into
a content-addressed store and composed into the next generation. ULPM owns
verification and import; `bubble` owns the lock and the composition:

```text
/var/lib/bubbleos/store/
├── objects/<sha256>/
│   ├── package.lpk        sealed LPK, retained for verification
│   ├── manifest.json      canonical JSON manifest
│   ├── meta.json          source, digest and import time
│   ├── files.tsv          file inventory
│   └── payload/           system tree overlaid on a generation
└── packages/<id>/<version> -> ../../objects/<sha256>
```

Since objects are addressed by the LPK SHA-256, importing the same package twice
is idempotent and a generation can pin the exact bytes it was composed from.
`ulpm store add` rejects application LPKs and payloads containing special files;
`ulpm store list`, `show`, `remove`, `gc` and `verify` manage the index.
`ulpm store verify` checks a **closed** set: every declared dependency must be
part of the requested set and its version must satisfy the manifest constraint.
Repository-backed installs additionally resolve open sets from verified
indexes before composing.

`bubble install` imports local LPKs through ULPM (so the Ed25519 signature is
checked first), adds them to a package lock, verifies the dependency set, then
composes a generation. The lock lives in `/etc/bubbleos/packages.json`:

```json
{
  "format": 1,
  "base_generation": "000001",
  "packages": [
    {
      "id": "io.bubbleos.example",
      "version": "1.0.0",
      "digest": "<sha256>",
      "type": "rootfs",
      "name": "example"
    }
  ]
}
```

Composition always starts from the source generation's package-free
`base_generation`, snapshots it into the next number, overlays each pinned
payload in package-ID order with `cp -a --reflink=auto`, writes the new lock and
metadata, then checks that the result still has `/etc/os-release`, a shell and
the per-generation boot assets before it can be activated. Starting from the
clean base is what makes upgrades and removals exact: files that disappear from
a newer package version, or from a removed package, cannot linger in the new
generation. The generation is activated only after the complete compose and
validation succeed.

`/var/lib/bubbleos/store` is on the persistent `@var` subvolume, so the store
and `/var` snapshots travel together. Garbage collection scans every retained
generation lock under `ULPM_GENERATIONS_DIR` in addition to the store links:
an object pinned by a generation survives `ulpm store remove --gc` even after
its `packages/<id>/<version>` link is gone. A lock that cannot be parsed aborts
the collection instead of risking deletion of live objects.

## Signed system repositories

ULPM's `repo` commands are also used for operating-system packages, but with a
persistent system environment instead of the user's `$HOME`:

```text
/var/lib/bubbleos/ulpm/
├── repos/<name>.json          repository URL and pinned-key metadata
├── repos/<name>.pub           pinned Ed25519 publisher key
├── trusted_keys/<name>.pub    trusted LPK signing keys
├── keys/                      system ULPM key directory
└── state/, data/              ULPM state for the system environment

/var/cache/bubbleos/ulpm/
├── repos/<name>/index.json    verified cached index
├── repos/<name>/index.json.sig
└── downloads.*/               temporary payload staging
```

The `ulpm-repository-v1` index lists package IDs, versions, architecture, type,
dependencies, payload filename and payload SHA-256, and is signed with Ed25519.
`bubble repo add` pins the publisher public key; every catalogue read re-verifies
the cached index and signature against that key, so a modified index is ignored
rather than used for resolution. `bubble repo packages --json` is the machine
interface (`repository` and `base_url` are added to every entry).

`lib/repo.sh` implements the system policy:

- `bubble_repo_catalog_json` keeps only host-architecture packages whose type is
  `rootfs`, `os`, `distro` or `system`;
- `bubble_resolve_plan` starts from a generation lock (or an intermediate lock
  built by `bubble install`), keeps installed packages unless a constraint
  requires a change, resolves repository dependencies to a fixed point and
  rejects unclosed or conflicting sets;
- `bubble update` refreshes the indexes and prints the resolved changes without
  composing;
- `bubble_repo_apply_plan` downloads every selected payload, verifies SHA-256
  and the Ed25519 signature through the system trust store, imports it into the
  content-addressed store, verifies the complete dependency closure and composes
  exactly one generation. Any failure occurs before the generation is created.

Local LPKs keep the historical ULPM environment and closed-set behavior;
repository packages use the system environment so their publisher keys are
available before login and persist on `@var` across generations and rollbacks.

## Desktop session

bubbleOS uses Wayfire 0.9 as its Wayland compositor. The session is not
started directly by systemd: `greetd` runs `tuigreet` on VT 7, and the
`bubbleos.desktop` session entry runs `/usr/local/bin/bubble-desktop session`
after authentication. This keeps the login screen and the user session under
the normal PAM/logind lifecycle, so `pam_systemd` creates the user manager,
`XDG_RUNTIME_DIR`, device ACLs and the session bus.

`bubble-desktop session`:

1. prepares the per-user Wayfire configuration from the system default;
2. reuses `$XDG_RUNTIME_DIR/bus` when `pam_systemd` created it, otherwise
   starts a private `dbus-run-session` bus for the session;
3. starts Wayfire with `stdbuf` so its Wayland socket name is visible, waits
   for the socket, then exports `WAYLAND_DISPLAY`;
4. starts `swaybg`, `mako`, `waybar` and optionally `swayidle`, and kills them
   when Wayfire exits.

The Wayfire idle plugin is loaded to expose the idle-notify protocol, but its
own timeouts are disabled (`-1`): `swayidle` owns the configurable DPMS and
lock timeouts. Locking uses `swaylock` (ext-session-lock-v1 is provided by the
Wayfire `session-lock` plugin) and DPMS uses `wlopm` through the wlroots output
power-management protocol.

Wayfire's configuration parser treats an unescaped `#` as the start of a
comment, so hexadecimal colors in `wayfire.ini` are written `\#RRGGBBAA` (the
parser strips the backslash before handing the value to `libwf-config`). When
the only display adapter is `virtio-pci`, the session exports
`MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` and `LIBGL_ALWAYS_SOFTWARE=1`:
Mesa's virtio GL driver crashes in `driCreateNewScreen3` in that environment.
Real GPUs keep hardware rendering. `DESKTOP_GL_DRIVER` can select `zink`
(OpenGL/GLES over Vulkan, using NVK on NVIDIA) or `software`; an explicit
`MESA_LOADER_DRIVER_OVERRIDE` value always wins. In zink mode the session also
sets `VK_DRIVER_FILES` to the ICD matching the DRM driver that owns the
display, so Mesa never picks the CPU lavapipe device (Xwayland bypasses the
device-select layer).

The default components and their settings are in
`/etc/bubbleos/desktop.conf`. Users override individual keys in
`~/.config/bubbleos/desktop.conf`; `bubble-desktop config` edits that file and
`bubble-desktop doctor` validates commands, configuration, fonts and services.
Waybar's JSON is rendered from
`/usr/share/bubbleos/desktop/waybar/config.jsonc` into
`$XDG_RUNTIME_DIR/bubbleos/waybar/config.jsonc` at session start, so module
lists, bar position, height and margins can change without `jq` at runtime.
The systemd user units for PipeWire/WirePlumber are enabled globally, and
`xdg-desktop-portal` + `xdg-desktop-portal-wlr` provide screenshot and
screencast portals.

## Control center: bubble-settings

`bubble-settings` is a native GTK3 control center written in C. It is built
from `settings/` and installed as `/usr/bin/bubble-settings`; the sources are
split into `main.c` (application, configuration loading, process execution,
doctor), `pages.c` (desktop pages) and `users.c` (account management). The
stylesheet lives in `/usr/share/bubbleos/settings/bubble-settings.css` and the
desktop entry/icon make it available from Fuzzel and the application menu.

The window is a searchable sidebar with eight pages:

| Page | Backend |
|---|---|
| Appearance | `DESKTOP_GTK_THEME`, `DESKTOP_ICON_THEME`, `DESKTOP_CURSOR_THEME`, `DESKTOP_CURSOR_SIZE`, `DESKTOP_FONT` |
| Wallpaper | `DESKTOP_WALLPAPER`, `DESKTOP_WALLPAPER_FILE`, `DESKTOP_WALLPAPER_MODE` |
| Bar & notifications | `DESKTOP_WAYBAR*`, `DESKTOP_MAKO`, `DESKTOP_IDLE_DPMS`, `DESKTOP_IDLE_LOCK` |
| Session | `DESKTOP_TERMINAL`, `DESKTOP_LAUNCHER`, `DESKTOP_SCREENSHOT_DIR`, session actions |
| Users | `pkexec /usr/libexec/bubbleos/bubble-settings-helper` |
| Date & time | `timedatectl` |
| System | `nm-connection-editor`, `pavucontrol`, `bubble-desktop bluetooth`, `wcm`, `wlr-randr`, `upower`, diagnostics |
| About | kernel, generation and `os-release` data |

The desktop pages do not rewrite the configuration file directly. They read
the effective values from `bubble-desktop config show`, write changes through
`bubble-desktop config set/unset` and apply them with `bubble-desktop apply`.
This keeps one implementation of the configuration format and of the
default/user merge. `apply` refreshes the GSettings values when the backend is
available, restarts Waybar, swaybg, Mako and swayidle in the running session,
and is a no-op with a clear message outside Wayland.

### Privilege boundary

Account operations are the only privileged part. `bubble-settings` calls
`pkexec` with the fixed helper path; it never runs setuid and never executes a
shell. The polkit action is:

```text
action id:   org.bubbleos.settings.users
exec.path:   /usr/libexec/bubbleos/bubble-settings-helper
defaults:    auth_admin (any/inactive/active)
```

`lxpolkit` is started by `bubble-desktop session` (and restarted by `apply`) so
the authentication agent is registered in the graphical session. The helper
re-validates everything it receives: user names match `[a-z_][a-z0-9_-]*`,
the GECOS field rejects `:` and control characters, passwords are read from
stdin, must contain at least eight characters and are passed to `chpasswd`
through a pipe, not on the command line. It refuses to modify system accounts,
to delete the account identified by `PKEXEC_UID`, and to delete the last human
member of the `sudo` group. `useradd` failures and password failures are
rolled back so a half-created account is not left behind.

The GTK frontend has no root capability: even if it is compromised, the worst
it can request is one of the validated `add`, `passwd` or `delete` operations,
subject to polkit authentication. The helper can also be exercised directly
for diagnostics (`bubble-settings-helper --version`), but account commands
require effective UID 0.

### Build integration

`build/bootstrap.sh` builds the control center inside the target chroot before
APT is removed, because the host glibc/GTK are newer than the target suite.
`BUILD_SETTINGS` follows `DESKTOP` by default. The script copies `settings/`
to `/usr/src/bubbleos/settings`, removes any host-built binary or object,
installs `gcc`, `make`, `libc6-dev`, `libgtk-3-dev` and `pkg-config`, builds and
installs, then purges the toolchain and runs `apt-get autoremove`. The build
fails if `gcc` is still present or if either binary is missing. `lxpolkit` and
`nm-connection-editor` are part of `DESKTOP_PACKAGES`.

## Boot chain (current milestone)

```text
UEFI firmware (OVMF in QEMU)        legacy BIOS (SeaBIOS in QEMU)
 └── GPT disk                       └── MBR (Limine 12.9.6 stage 1)
      ├── partition 1: BIOS boot         └── stage 2
      ├── partition 2: FAT32 ESP
      │    ├── /EFI/BOOT/BOOTX64.EFI   (Limine 12.9.6 UEFI)
      │    ├── /limine-bios.sys        (BIOS stage 2 payload)
      │    ├── /limine.conf            (menu rendered from generations)
      │    ├── /vmlinuz                (Linux 7.2.15-zen1-rt5, guest /boot/vmlinuz)
      │    ├── /initramfs.cpio.gz      (early microcode + BusyBox)
      │    └── /generations/<gen>/     (private assets for older kernels)
      └── partition 3: Btrfs RootFS
           └── Linux 7.2.15-zen1-rt5
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
                                    ├── bubbleos-boot.service
                                    │    └── bubble boot
                                    │         └── records the booted
                                    │             generation and subvolume
                                    └── graphical.target
                                         └── greetd (VT7)
                                              └── tuigreet
                                                   └── bubble-desktop session
                                                        └── Wayfire
```

Both firmware paths converge on the same ESP and menu. Limine's BIOS stage 1
is written to the protective MBR, its stage 2 lives in the 1 MiB BIOS boot
partition, and stage 2 reads `/limine-bios.sys` from the ESP. The GPT entries
and the UEFI entry point remain unchanged.

`build/build-kernel.sh` imports the locally built 7.2.15-zen1-rt5 kernel
(`boot/vmlinuz-bubbleos` and `bubble-modules/`) into `out/kernel/`; a Debian
package download remains available as a host bootstrap fallback
(`KERNEL_SOURCE=debian`). `build/build-initramfs.sh` builds the early userspace
and prepends an uncompressed microcode cpio archive,
`build/build-image.sh` packs the RootFS into a Btrfs image, and
`build/build-disk-image.sh` assembles the bootable GPT disk (BIOS boot
partition, ESP and RootFS) consumed by `build/run-qemu.sh`.

The bootloader and kernel live in the ESP, which is mounted read-write at
`/boot` so `bubble bootloader sync` can regenerate the Limine menu. The RootFS
carries systemd and the generation subvolumes. `bubbleos-var-restore.service`
applies a pending `/var` restore before the fstab mounts, then
`bubbleos-boot.service` records the booted generation and Btrfs subvolume in
`/run/bubbleos` and `/var/lib/bubbleos/boot/last`.

The RootFS identity is defined once in `config/rootfs.env`: a fixed Btrfs UUID
is written by `build/build-image.sh` and rendered into the Limine command line
by `build/build-disk-image.sh`. The initramfs resolves `root=UUID=...` with
BusyBox `findfs`, so boot does not depend on the device being `/dev/vda3`.
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
7.2.15 module tree into `/lib/modules/7.2.15-zen1-rt5`, then runs `depmod` in the
target.
The resulting `modules.dep.bin` and `modules.builtin.bin` let libkmod/systemd
handle both loadable drivers and built-ins (`btrfs`, `virtio_blk`, `autofs4`,
`loop`, `overlay`, `binfmt_misc`). The initramfs only copies the loadable
storage modules; in the 7.2.15 configuration the storage drivers are built in,
so libkmod reports them as `builtin` and the initramfs carries only their
metadata.

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
`7.2.15-zen1-rt5` release and `/proc/version` carries the local build identity
(`romain@debian`, `#1 ZEN SMP PREEMPT_RT`).

### Boot activation roadmap

1. **Current** — real Btrfs generations: `@rootfs/current` selects the root
   subvolume; activation creates read-only generation and `/var` snapshots.
   The 7.2.15-zen1-rt5 kernel, complete module tree, firmware and early microcode are
   integrated. `bubble bootloader sync` writes one Limine entry per generation
   and the initramfs falls back across current/previous/newest.
   `/var` can be restored from a snapshot before `var.mount`, and old automatic
   snapshots are pruned. ULPM runs without APT and its LPK
   pack/inspect/install/run/remove workflow is validated in QEMU. Every
   generation carries its own kernel/initramfs pair; the ESP keeps private
   copies only for generations whose assets differ from the current one. The
   kernel comes from the local 7.2.15-zen1-rt5 build. System LPKs are imported into
   the ULPM store and composed into generations from a package lock; upgrades,
   removals and rollback are validated in QEMU. Unused generations can be
   deleted or pruned safely, and store GC preserves objects pinned by
   generation locks. Signed system repositories are pinned by Ed25519 key,
   resolved with dependencies, refreshed with `bubble update`, and applied
   atomically with `bubble upgrade`; checksum, signature and closure failures
   leave the current generation untouched.
2. **Next** — full package-driven base composition and remote mirror policy
   hardening (rotation, revocation and multi-mirror failover).
3. **Later** — the installer/ISO path.
