<div align="center">
<img src="https://raw.githubusercontent.com/Ruraam/Bubbleos/5a6cc5b1f9812674dcfc11f04e8ee0af17e24ed6/assets/bubbleos-logo.svg" width="460" />
<h1>BubbleOS is an experimental Linux operating system built around the Linux kernel and the ULPM/LPK ecosystem.</h1>

![Status](https://img.shields.io/badge/status-pre--alpha-blue?style=flat-square)
![Kernel](https://img.shields.io/badge/kernel-7.2.12-cyan?style=flat-square)
![Bootloader](https://img.shields.io/badge/bootloader-Limine-brightgreen?style=flat-square)
![Package%20Format](https://img.shields.io/badge/format-LPK-indigo?style=flat-square)

</div>

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
- `packages/` — BubbleOS package definitions
- `docs/` — architecture and development documentation

## Current status

The current image provides a **bootable UEFI system with systemd**:

- Linux **7.2.12** (`7.2.12+deb14-amd64`), extracted from Debian packages;
- BusyBox initramfs with the storage modules needed to mount the RootFS;
- GPT disk with a FAT32 EFI System Partition and an ext4 RootFS;
- Limine 12.9.6 as the UEFI bootloader;
- systemd 257 as PID 1, serial console login and `bubbleos-boot.service`;
- generation `000001` initialized by the bubbleOS core.

Package-driven generation activation, rollback at boot and the ULPM install
flow are not integrated yet.

| Feature | Status |
|---|---|
| Boot to login (UEFI + systemd) | ✅ Working |
| Generation tracking (`bubble status`) | ✅ Working |
| Multiple generations (A/B boot) | ❌ Not yet |
| Rollback at boot | ❌ Not yet |
| ULPM install flow | ❌ Not yet |
| Immutable `/usr` | ❌ Not yet (Debian rootfs) |

## How it differs

- **NixOS** uses Nix expressions for the whole system; BubbleOS uses imperative LPK packages with declarative generations.
- **Fedora Silverblue** uses OSTree + rpm-ostree; BubbleOS uses plain ext4 + ULPM, without an image-based update daemon.
- **Vanilla OS** uses Distrobox for app isolation; BubbleOS uses ULPM's native rootless model when available.

---

## Quick start

### Prerequisites

**Host OS:** Debian 12+ or Ubuntu 22.04+ (other distros may work but are untested).

**Required packages:**
```bash
sudo apt install build-essential bc bison flex \
    libssl-dev libelf-dev libncurses-dev \
    debootstrap qemu-system-x86 qemu-utils \
    dosfstools mtools parted ovmf
```
Disk space: ~10 GB for a full build (kernel + rootfs + image).
RAM: ≥ 2 GB (kernel build needs ~1.5 GB with -j$(nproc)).

```bash
./build/build-kernel.sh          # kernel + modules -> out/kernel/
./build/build-initramfs.sh       # initramfs -> out/initramfs.cpio.gz

sudo ./build/bootstrap.sh         # Debian RootFS + systemd -> out/rootfs/
sudo ./build/build-image.sh       # ext4 RootFS -> out/bubbleos-root.img
./build/build-disk-image.sh       # GPT + ESP + RootFS -> out/bubbleos.img

sudo DISK_IMAGE=out/bubbleos.img ./build/run-qemu.sh
```

The UEFI boot chain reaches a systemd login prompt:

```text
UEFI -> ESP (Limine) -> Linux 7.2.12 -> initramfs
     -> /dev/vda2 -> switch_root -> systemd -> bubbleos-boot.service
```

Development login: **root / `bubble`** (override with `ROOT_PASSWORD=...` when
running `build/bootstrap.sh`). Quit QEMU with `Ctrl-A`, then `X`.

For a direct-kernel boot without firmware:

```bash
sudo ROOT_IMAGE=out/bubbleos-root.img ./build/run-qemu.sh
```

## Contributing

BubbleOS is early-stage and evolving quickly. Contributions are welcome:
- **Bug reports**: [open an issue](https://github.com/Ruraam/Bubbleos/issues/new)
- **Discussions**: [GitHub Discussions](https://github.com/Ruraam/Bubbleos/discussions)
- **Code**: fork, create a topic branch, open a PR against `main`

Before contributing, read [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) to understand the build pipeline.

## License

BubbleOS is licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

Components:
- `ulpm/` — GPL-3.0 (inherits from ULPM upstream)
- `bubble/` — GPL-3.0
- `build/`, `initramfs/`, `boot/` — GPL-3.0

---

## 🛠️ Related Projects

* [**ULPM (Universal Linux Package Manager)**](https://github.com/Ruraam/ulpm)
[![GitHub stars](https://img.shields.io/github/stars/Ruraam/ulpm?style=flat-square&color=yellow)](https://github.com/Ruraam/ulpm/stargazers)
Lightweight, rootless, zero-daemon, sandboxed application/read-only OS runtime for any Linux distribution. Lighter than Flatpak or Snap.

* [**debup — Hybrid Package Manager**](https://github.com/Ruraam/debup)
[![GitHub stars](https://img.shields.io/github/stars/Ruraam/debup?style=flat-square&color=yellow)](https://github.com/Ruraam/debup/stargazers)
The missing bridge between GitHub &APT for Debian/Ubuntu-based distributions, WSL, and Android Linux Terminal. Discover, search, track, install, and upgrade `.deb` packages directly from APT & GitHub Releases on all architectures simultaneously.

* [**URAAM (Universal Ruvomain ADB AppManager)**](https://github.com/Ruraam/uraam)
[![GitHub stars](https://img.shields.io/github/stars/Ruraam/uraam?style=flat-square&color=yellow)](https://github.com/Ruraam/uraam/stargazers)
An all-in-one shell toolkit for Android debloating. Uninstall/disable your apps, backup your debloat apps JSON file & revert/restore, install apk.Works with Termux WirelessADB, Shizuku, Root, Linux Debian, Arch, Fedora, macOS & WSL. Compatible with Canta/UAD JSON lists.
