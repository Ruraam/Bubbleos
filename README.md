BubbleOS is an experimental Linux operating system built around the Linux kernel and the ULPM/LPK ecosystem.

## Project principles

- Linux kernel
- ULPM as the package engine
- LPK as the native package format
- System generations and rollback
- Immutable system composition where practical
- Rootless/sandboxed applications where supported by ULPM
- No APT, DNF, RPM or Pacman in the final installed operating system

## Repository layout

- `ulpm/` — BubbleOS-maintained copy of ULPM
- `bubble/` — BubbleOS system core and CLI
- `build/` — bootstrap and image build tooling
- `boot/` — boot integration
- `initramfs/` — early userspace
- `config/` — system and image configuration (including the RootFS UUID)
- `packages/` — BubbleOS package definitions
- `docs/` — architecture and development documentation

## Current status

The current image provides a **bootable UEFI and legacy BIOS system with
systemd**:

- Linux **7.2.15-zen1-rt5**, built locally (ZEN patches, PREEMPT_RT, clang
  ThinLTO) and imported from `boot/vmlinuz-bubbleos` with the matching
  `bubble-modules/` tree;
- BusyBox initramfs with the module metadata needed to mount the RootFS
  (Btrfs, VirtIO, AHCI and SD support are built into this kernel) and an early
  microcode archive for Intel and AMD CPUs;
- complete kernel module tree installed in the RootFS
  (`/lib/modules/7.2.15-zen1-rt5`, 112 zstd-compressed modules) with `depmod`
  indexes, so loadable graphics, Wi-Fi, audio, Bluetooth and other drivers are
  available;
- firmware merged from the local `firmware/` drop (AMD/Intel/NVIDIA graphics,
  Intel Wi-Fi, MediaTek, Realtek, Cirrus, SOF and both CPU microcode packages),
  plus the matching DRM/VA-API, libwacom, Thunderbolt and USB Type-C userspace
  payloads;
- GPT disk with a 1 MiB BIOS boot partition, a FAT32 EFI System Partition and
  a **Btrfs** RootFS, compressed with **zstd level 1** and protected by data
  checksums;
- Limine 12.9.6 as the UEFI and legacy BIOS bootloader;
- systemd 257 as PID 1, serial console login and `bubbleos-boot.service`;
- a Wayfire 0.9 desktop session with Waybar, Fuzzel, Mako, foot, swaybg,
  swaylock and swayidle, started by greetd/tuigreet on VT 7 with
  `graphical.target` and the `bubble` desktop user;
- the open-source NVIDIA stack: kernel **nouveau** with GP107 firmware, Mesa
  **NVK** Vulkan drivers and **zink** selectable through `DESKTOP_GL_DRIVER`;
- Wi-Fi on the reference machine through the Ralink RT2790 (`rt2800pci`) with
  the `rt2860.bin` firmware, managed by NetworkManager and `wpa_supplicant`;
- game controllers through the mainline HID stack: `xpad` (Xbox 360, Xbox
  One/Series over USB), `hid-microsoft` (Xbox over Bluetooth), `hid-sony`
  (PS3), `hid-playstation` (PS4/PS5), `hid-nintendo` (Switch Pro/Joy-Con),
  `hid-steam`, plus `uinput` (group `input`, mode `0660`) for Steam Input and
  button remappers;
- controller diagnostics and SDL runtimes: `evtest`, `jstest`/`fftest`, SDL2
  and SDL3 with the `testgamecontroller`/`testjoystick` tools, plus `lsusb`
  and `lspci`;
- `bubble-settings`, a native GTK3 control center for appearance, wallpaper,
  Waybar, session, users, date/time and system information, with a privileged
  account helper behind polkit and `pkexec`;
- real generation subvolumes: `@rootfs/generations/000001`,
  `@rootfs/current -> generations/000001`, plus `@home`, `@var`, `@logs` and
  `@snapshots`;
- stable RootFS identification by filesystem UUID (`root=UUID=...`) instead of
  a kernel device name, with a fixed GPT partition UUID;
- read-only restoration snapshots of the initial generation and of `/var`,
  with a `/var` restore workflow and automatic pruning;
- a Limine menu regenerated from the live generation list, with one explicit
  `rootflags=subvol=...` entry per generation, and an initramfs fallback chain
  (`rootflags` → `current` → `previous` → newest generation);
- bubbleOS console branding, package documentation and bug metadata removed,
  and **no APT** in the target: ULPM/LPK is the package layer;
- ULPM 6.0.0 installed in `/opt/bubbleos/ulpm` with its runtime toolchain
  (`bubblewrap`, `squashfs-tools`, `squashfuse`, `fuse-overlayfs`, `jq`,
  `curl`, `openssl`, `xdg-dbus-proxy`), validated in QEMU for LPK
  pack/inspect/install/run/remove workflows;
- a content-addressed system package store under `/var/lib/bubbleos/store`,
  and generation composition from a package lock: `bubble install`,
  `bubble remove`, `bubble packages` and `bubble generation compose`;
- SELinux is built into the kernel but disabled at boot (`selinux=0`) because
  no policy is shipped; enabling it later requires a policy package.

`bubble generation create` clones the active generation into the next Btrfs
subvolume. `bubble generation activate` snapshots the outgoing generation and
`/var`, then switches `@rootfs/current`; the new generation is used on the next
boot. `bubble rollback` selects the previous generation. `bubble bootloader
sync` rewrites `/boot/limine.conf` on the ESP so every generation has its own
menu entry; `create`, `activate`, `delete`, `prune` and `rollback` call it
automatically. Each generation carries the kernel and initramfs it was built
with in
`/usr/lib/bubbleos/boot`. The shared ESP pair (`/boot/vmlinuz` and
`/boot/initramfs.cpio.gz`) follows the current generation; generations whose
assets differ get private copies under `/boot/generations/<gen>/`, and stale
copies are pruned on every sync. If the selected subvolume is missing or fails
to mount, the initramfs falls back to `current`, then `previous`, then the
newest generation instead of dropping to a rescue shell.

`bubble generation delete <gen>` removes an unused generation subvolume. The
current, previous and running generations are protected, and so is any
generation used as the `base_generation` of another generation's package lock.
`bubble generation prune` keeps the newest generations (default: 3) plus those
protected generations and deletes the rest; `--keep N` and `--dry-run` are
available. Both commands refresh the Limine menu and remove private ESP assets
that no longer back a generation.

`bubble snapshots restore <name>` schedules a `/var` restore for the next boot;
`bubbleos-var-restore.service` performs the swap before `/var` is mounted and
keeps a read-only `pre-restore` safety snapshot of the replaced subvolume.
`bubble snapshots prune` removes old automatic snapshots while always keeping
the `*-initial` restore points; activation prunes automatically with
`BUBBLEOS_SNAPSHOT_KEEP` (default: 10).

System packages use the same generation model. ULPM verifies and imports an LPK
into the system store; `bubble` then composes a new generation from the
package-free base generation and the package lock. Because every composition
starts from that clean base, an upgrade or removal cannot leave files from the
previous package version behind. The dependency set is checked as a closed,
version-compatible set before a generation is created. Store garbage collection
consults every retained generation lock, so an object stays available even if
its `packages/<id>/<version>` link was removed; only objects pinned by no lock
and no link are deleted.

## Desktop

The image boots to **greetd/tuigreet on VT 7** and starts a Wayfire 0.9 session
from `bubble-desktop session`. The greeter lists regular desktop accounts
(UID 1000+); Wayfire drops privileges at startup and refuses to run as root,
so root is reserved for the serial console and tty1 recovery logins. The
desktop is styled from the `bubbleos-logo.svg` palette (cyan `#22d3ee`, sky
`#38bdf8`, blue `#60a5fa`, indigo `#818cf8`, navy `#0c2340`):

- **Wayfire** with blur, wobbly windows, animations, window shadows/glow, expo,
  grid, scale, session-lock and the usual move/resize/switcher plugins;
- **Waybar** with a bubbleOS logo, Wi-Fi, Bluetooth, clock, battery, sound,
  tray and power modules;
- **Fuzzel** as the launcher, **Mako** for notifications, **foot** as the
  terminal, **swaybg** for the generated 2560×1440 cyber-punk wallpaper,
  **swaylock** + **swayidle** for locking and DPMS;
- Inter, JetBrains Mono, Orbitron and Font Awesome fonts, Papirus icons and
  the Bibata Ice cursor.

The system defaults live in `/etc/bubbleos/desktop.conf` and are copied to
`~/.config/wayfire.ini` on first login. User overrides go to
`~/.config/bubbleos/desktop.conf`:

```bash
bubble-desktop config show                  # effective values
bubble-desktop config set DESKTOP_WAYBAR_POSITION bottom
bubble-desktop config unset DESKTOP_WAYBAR_POSITION
bubble-desktop config reset                 # back to system defaults
bubble-desktop doctor                       # commands, files, fonts, services
```

The open-source NVIDIA stack is included: the kernel **nouveau** driver with
the GP107 (and other GPU family) firmware, Mesa's **NVK** Vulkan driver, and
**zink** for OpenGL/GLES on top of Vulkan. NVK comes from the Debian 13
backports (Mesa 26.x) because Mesa 25.0 in trixie predates Pascal support; the
GL/EGL stack stays on the stable suite. Wayfire keeps the native nouveau
driver by default; to switch the whole session to zink:

```bash
bubble-desktop config set DESKTOP_GL_DRIVER zink
# log out and back in
```

`DESKTOP_GL_DRIVER` accepts `auto`, `native`, `zink` or `software`.
Zink pins the session to the Vulkan ICD of the GPU driving the display, so
Xwayland also stays on NVK instead of falling back to lavapipe.
`vulkaninfo --summary` lists the active Vulkan device.

Set `DESKTOP_WAYBAR`, `DESKTOP_MAKO`, `DESKTOP_WALLPAPER` or `DESKTOP_IDLE` to
`0` to disable a component, and edit `DESKTOP_WAYBAR_LEFT/CENTER/RIGHT` to
choose the modules. Idle delays are `DESKTOP_IDLE_DPMS` and
`DESKTOP_IDLE_LOCK` (seconds, `0` disables the action). Session actions are
available through `bubble-desktop menu|wifi|bluetooth|power|lock|logout|
screenshot|apply|reload|reset-wayfire`.

### Control center

`bubble-settings` is the bubbleOS control center. It is a native GTK3
application, not a web view or a Python wrapper, and follows the same
cyan/navy palette as the rest of the desktop. It is available from Fuzzel, the
desktop menu and the `bubble-settings` command, and covers:

- **Appearance** — GTK, icon and cursor themes, cursor size, font and size;
- **Wallpaper** — preview, file selection, fill/fit/stretch/center/tile mode;
- **Bar & notifications** — Waybar enable/position/height/modules, Mako and the
  idle DPMS/lock delays;
- **Session** — terminal, launcher, screenshot directory and session actions;
- **Users** — list local accounts, create standard or administrator accounts,
  remove users and set passwords;
- **Date & time** — timezone and NTP through `timedatectl`;
- **System** — network, Bluetooth, audio, display, power and Wayfire
  configuration through the official tools, plus diagnostics;
- **About** — kernel, generation, model and bubbleOS version.

Desktop values are written through `bubble-desktop config set` into
`~/.config/bubbleos/desktop.conf`; **Apply** runs `bubble-desktop apply`, which
restarts Waybar, swaybg, Mako and swayidle and refreshes the live GSettings
values without restarting Wayfire. Specialized settings delegate to the
system tools: NetworkManager editor, `pavucontrol`, `wcm`, `timedatectl` and
`localectl`.

Account operations never run in the GTK process. The frontend calls
`pkexec /usr/libexec/bubbleos/bubble-settings-helper`, which is authorized by
the `org.bubbleos.settings.users` polkit action, validates every argument
again and uses `useradd`, `userdel`, `chpasswd` and `chage`. `lxpolkit` is
started with the session to display the authentication prompt. The helper
refuses system accounts, deleting the caller's own account and deleting the
last administrator; passwords must contain at least eight characters.
`bubble-settings --doctor` and `bubble-desktop doctor` verify the binary,
helper, policy, stylesheet, icon and required commands.

Useful bindings: `Super+Enter` terminal, `Super+Space`/`Super+D` launcher,
`Super+S` bubbleOS settings, `Super+Q` close, `Super+F` fullscreen, `Super+E`
expo, `Super+Ctrl+arrows` switch workspace and `Print`/`Shift+Print` for
full-screen/region screenshots. The Waybar Wi-Fi, Bluetooth, battery and power
icons open the matching `bubble-desktop` action.

`htop` is the lightweight task manager: it is part of the base system, so it
works on the serial console and tty1 even without the desktop. It ships with
the black-night colour scheme (cyan on black) in
`/etc/skel/.config/htop/htoprc`; root and the desktop user receive a copy at
build time, and Fuzzel exposes the same entry through `foot`.

Before packing, `build/prune-rootfs.sh` removes payloads that the image does
not use: extra Papirus/Bibata variants, translations other than French and
English, `man`/`info` pages when no reader is installed, `gprofng` and
non-French GTK emoji data. It runs from both `bootstrap.sh` and
`build-image.sh`, is idempotent, and can be previewed with
`sudo DRY_RUN=1 ./build/prune-rootfs.sh`. Firmware, kernel modules, recovery
tools and the configured `DESKTOP_ICON_THEME`/`DESKTOP_CURSOR_THEME` variants
are kept; changing either theme requires installing the matching theme first.

## Package management

The target boots without APT. ULPM provides the application-level package
workflow:

```bash
ulpm --version
ulpm doctor
ulpm pack ./hello hello hello_amd64.lpk 1.0.0
ulpm inspect hello_amd64.lpk
ulpm install hello_amd64.lpk
ulpm run hello
ulpm remove hello
```

LPKs are SquashFS images with an Ed25519 signature trailer. Applications run
in a Bubblewrap sandbox and fall back to temporary extraction when FUSE is not
available.

System packages are restricted to LPKs whose manifest describes a system tree
(`type: rootfs`, or `etc/` + `usr/` with no application type). ULPM owns the
store:

```bash
ulpm store add ./base-tools.lpk          # verify, extract and index
ulpm store list
ulpm store show io.bubbleos.base-tools
ulpm store verify io.bubbleos.base-tools=1.0.0
ulpm store remove io.bubbleos.base-tools=1.0.0 --gc
```

`bubble` composes the store contents into generations:

```bash
bubble install ./base-tools.lpk          # compose + activate (reboot required)
bubble install io.bubbleos.base-tools    # select the newest stored version
bubble remove io.bubbleos.base-tools
bubble packages                          # package lock of the current generation
bubble generation compose --activate     # recompose the same lock
```

`bubble install` imports local LPKs through ULPM, so the package signature is
checked before anything is composed. The package lock is stored in
`/etc/bubbleos/packages.json`. Local installs keep the historical behaviour:
dependencies must be installed together (for example `bubble install dep.lpk
app.lpk`); the set is rejected if a dependency is missing or if the requested
versions do not satisfy the manifest constraints.

## Signed system repositories

System packages can also be installed from Ed25519-signed repositories. The
repository state is persistent under `/var/lib/bubbleos/ulpm` (pinned keys,
trust anchors, ULPM state) and `/var/cache/bubbleos/ulpm` (verified indexes and
download staging), so it survives generations and rollbacks:

```bash
bubble repo add main https://packages.example.org/bubbleos ./publisher.pub
bubble repo list
bubble repo update
bubble repo verify
bubble repo packages
bubble repo search base-tools
bubble repo search --all util          # include application packages
bubble install io.bubbleos.base-tools  # resolve + compose + activate
bubble update                          # refresh indexes and list upgrades
bubble upgrade                         # compose + activate the upgrades
bubble upgrade --dry-run               # show the plan only
bubble trust ./another-publisher.pub   # trust an LPK signing key
```

`bubble repo add` pins the publisher key fingerprint; every cached index is
re-verified against it before its packages are exposed. `bubble update` does
not compose anything, while `bubble upgrade` downloads every payload, checks
its SHA-256 and Ed25519 signature against the system trust store, imports it
into the store, verifies the full dependency closure and composes exactly one
new generation. A failed download, checksum, signature or dependency leaves
the current generation untouched.

## Quick start

```bash
./build/build-kernel.sh          # local 7.2.15 kernel + modules -> out/kernel/
./build/build-initramfs.sh       # initramfs + early microcode -> out/initramfs.cpio.gz

sudo ./build/bootstrap.sh         # base RootFS + systemd + modules + firmware
sudo ./build/build-image.sh       # Btrfs RootFS -> out/bubbleos-root.img
./build/build-disk-image.sh       # BIOS + ESP + RootFS -> out/bubbleos.img

sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh          # UEFI/OVMF
sudo UEFI=0 DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh   # legacy BIOS
```

The launcher is headless by default (`-nographic`, serial console only).
To see the Wayfire desktop in a QEMU window on the host:

```bash
QEMU_DISPLAY=gtk DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
```

Run it as your user, not through `sudo`: the window must inherit your X11 or
Wayland credentials. The kernel and systemd logs stay in the terminal, and
`/dev/kvm` is used when it is accessible. Log in through tuigreet as
`bubble` / `bubble`; `QEMU_DISPLAY=sdl` selects the SDL backend instead.

`build/build-kernel.sh` imports the local kernel automatically when
`boot/vmlinuz-bubbleos` and `../bubble-modules/` are present. A Debian package
fallback remains available for a host without those files:

```bash
KERNEL_SOURCE=debian ./build/build-kernel.sh
```

`build/bootstrap.sh` merges every `firmware/*/usr/lib/firmware` payload into
`/usr/lib/firmware`. The hardware userspace packages (`bolt`, `libdrm-*`,
`libwacom9`/`libwacom-common`, `libtypec0`, `libusb3380`,
`intel-media-va-driver`) are installed
from the target suite by debootstrap, never copied from the drop. Disable them
with `HARDWARE_USERSPACE=0`.

The disk boots through UEFI (ESP) or legacy BIOS (MBR + BIOS boot partition);
both paths share the same Limine menu and reach a systemd login prompt:

```text
UEFI -> ESP (Limine) ----------------------------------------+
BIOS -> MBR (Limine stage 1) -> BIOS boot -> ESP (Limine) ---+
     -> Linux 7.2.15-zen1-rt5 -> initramfs (microcode + Btrfs)
     -> Btrfs UUID -> @rootfs/current (fallback: previous/newest)
     -> generation subvolume -> switch_root -> systemd
     -> bubbleos-boot.service
     -> greetd/tuigreet (VT7) -> bubble-desktop session -> Wayfire
```

Generations and snapshots:

```bash
bubble status
bubble generations
bubble generation create --description "test generation"
bubble generation activate 000002   # reboot required
bubble generation delete 000003     # remove an unused generation
bubble generation prune --keep 3    # keep the newest 3, current and previous
bubble rollback                     # reboot required
bubble bootloader sync              # rewrite the Limine menu
bubble snapshots
bubble snapshots restore var/<name> # /var restored at the next boot
bubble snapshots prune --keep 10    # keep the newest 10 automatic snapshots
bubble packages                     # packages pinned in the current generation
bubble install ./package.lpk        # compose + activate a new generation
bubble remove <package-id>          # compose without the package
```

Serial development login: **root / `bubble`** (override with
`ROOT_PASSWORD=...` when running `build/bootstrap.sh`). Desktop login:
**`bubble` / `bubble`** (override with `DESKTOP_USER` and
`DESKTOP_USER_PASSWORD`). The greeter shows a user menu with the regular
desktop accounts; **Wayfire refuses to run as root**, so `root` is limited to
the serial and tty1 rescue logins. Quit QEMU with `Ctrl-A`, then `X`.

For a direct-kernel boot without UEFI firmware:

```bash
sudo ROOT_IMAGE=out/bubbleos-root.img ./build/run-qemu.sh

# Boot an explicit generation (missing ones fall back to current/previous)
sudo ROOT_IMAGE=out/bubbleos-root.img \
    APPEND_EXTRA='rootflags=subvol=@rootfs/generations/000001' \
    ./build/run-qemu.sh
```

See `docs/BOOTSTRAP.md` for details and overrides.

## Tests

The QEMU integration suite boots the image and drives the serial console:

```bash
./tests/qemu/run.sh                 # all suites
./tests/qemu/run.sh boot            # kernel, Btrfs, /boot, systemd, packages
./tests/qemu/run.sh bios            # legacy BIOS/SeaBIOS through Limine MBR
./tests/qemu/run.sh generations     # lifecycle, delete/prune, Limine entries
./tests/qemu/run.sh fallback        # broken current + missing subvolume
./tests/qemu/run.sh snapshots       # /var restore + pruning
./tests/qemu/run.sh store           # store, composition, upgrade/remove/rollback
./tests/qemu/run.sh repo            # signed repositories, dependency resolution
./tests/qemu/run.sh ulpm            # diagnostics + LPK pack/install/run
./tests/qemu/run.sh desktop         # Wayfire session, Waybar, Fuzzel, Mako
./tests/qemu/run.sh settings        # control center, users helper, polkit
```

It requires `python3-pexpect`, QEMU/OVMF and passwordless `sudo`. Each suite
works on a temporary copy of `out/bubbleos.img`; see `tests/qemu/README.md`.
