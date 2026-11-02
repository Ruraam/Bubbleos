<div align="center">
<img src="https://raw.githubusercontent.com/Ruraam/Bubbleos/5a6cc5b1f9812674dcfc11f04e8ee0af17e24ed6/assets/bubbleos-logo.svg" width="460" />
<h1>BubbleOS is an experimental Linux operating system built around the Linux kernel and the ULPM/LPK ecosystem.</h1>

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

## Quick start

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

See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for details and overrides.
