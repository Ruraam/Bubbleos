# bubbleOS Bootstrap

`build/bootstrap.sh` creates the first development RootFS for bubbleOS.
`build/build-disk-image.sh` assembles the bootable UEFI disk image.

## Important design rule

Debian/debootstrap is used **only on the build machine to solve the chicken-and-egg bootstrap problem**. It is not the intended runtime package manager of bubbleOS.

The long-term target is:

- ULPM is the package engine.
- LPK is the package format.
- System state is composed into atomic generations.
- APT/dpkg are not exposed as the package-management interface of the installed OS.

## Build requirements

On a Debian build host:

```bash
sudo apt install debootstrap busybox-static cpio gzip xz-utils zstd kmod \
                 dosfstools mtools fdisk ovmf qemu-system-x86
```

`build/build-kernel.sh` downloads Debian kernel packages with `apt-get`, so a
working APT configuration is still required **on the build host**.

## Full build

```bash
# 1. Kernel and modules (no compilation)
./build/build-kernel.sh

# 2. Initramfs: picks up out/kernel/kernel.env automatically
./build/build-initramfs.sh

# 3. RootFS (debootstrap) and ext4 image
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

`build/build-kernel.sh` downloads and extracts:

- `linux-binary-7.2.12+deb14-amd64`
- `linux-modules-7.2.12+deb14-amd64`

The result is written to `out/kernel/`:

```text
out/kernel/
├── debs/                 # cached .deb files
├── root/usr/lib/modules/7.2.12+deb14-amd64/
│   ├── vmlinuz
│   └── kernel/...
├── vmlinuz -> root/usr/lib/modules/.../vmlinuz
├── modules -> root/usr/lib/modules/...
└── kernel.env            # KERNEL_RELEASE, KERNEL_IMAGE, MODULE_ROOT
```

No kernel compilation is performed. To use another Debian kernel:

```bash
KERNEL_RELEASE=7.3.1+deb14-amd64 ./build/build-kernel.sh
```

The initramfs also embeds the modules required to mount the RootFS (`ext4`,
`virtio_blk`, `ata_piix`, `ahci`, `sd_mod`) plus their dependencies.

## Disk layout

`out/bubbleos.img` uses GPT:

| Partition | Offset | Size | Type | Content |
|---|---|---|---|---|
| 1 | 1 MiB | 128 MiB | EFI System | FAT32: Limine, kernel, initramfs, config |
| 2 | 129 MiB | 2 GiB | Linux | ext4 RootFS |

ESP contents:

```text
/EFI/BOOT/BOOTX64.EFI
/EFI/BOOT/limine.conf
/limine.conf
/boot/vmlinuz
/boot/initramfs.cpio.gz
```

Limine boots `boot():/boot/vmlinuz` with
`root=/dev/vda2 rootfstype=ext4 rw`. The root device is the second GPT
partition because the disk is attached through virtio.

## Init and services

By default the RootFS is bootstrapped with **systemd 257**, `udev`, D-Bus and
PAM session integration. The following units are enabled:

| Unit | Role |
|---|---|
| `multi-user.target` | default boot target |
| `getty@tty1.service` | local console login |
| `serial-getty@ttyS0.service` | QEMU serial login |
| `bubbleos-boot.service` | validates the active generation at boot |

`bubbleos-boot.service` runs `/usr/local/bin/bubble boot`. That command:

1. creates the runtime/state directories;
2. reads the `current` generation symlink;
3. writes `/run/bubbleos/current-generation`;
4. records the boot details in `/var/lib/bubbleos/boot/last`;
5. logs the generation, kernel and root device to the journal and console.

The development root password is `bubble`. Override it at build time:

```bash
sudo ROOT_PASSWORD='change-me' FORCE=1 ./build/bootstrap.sh
```

The old shell-only init is still available for debugging:

```bash
sudo SYSTEMD=0 FORCE=1 ./build/bootstrap.sh
```

## Current status

The complete chain is functional:

```text
UEFI (OVMF) -> ESP -> Limine -> Linux 7.2.12
     -> initramfs -> /dev/vda2 (ext4) -> switch_root
     -> systemd -> bubbleos-boot.service -> multi-user.target -> login
```

Observed in QEMU:

```text
bubbleOS boot: generation 000001, kernel 7.2.12+deb14-amd64, root /dev/vda2
[  OK  ] Reached target multi-user.target - Multi-User System.
bubbleos login:
```

After login:

```bash
bubble status
systemctl is-system-running
systemctl status bubbleos-boot.service
journalctl -b
```

Remaining work:

1. package-driven generation activation and rollback;
2. generation-specific kernel/initramfs selection in Limine;
3. install/update flow through ULPM/LPK.

## Testing in QEMU

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
systemctl is-system-running
systemctl status bubbleos-boot.service
systemctl --failed
journalctl -b
```

Shut down cleanly with `poweroff`, or quit QEMU with `Ctrl-A`, then `X`.
The disk image is writable: changes made inside the guest persist in
`out/bubbleos.img` unless it is rebuilt.

## Useful overrides

```bash
sudo FORCE=1 SUITE=stable ./build/bootstrap.sh
sudo ROOT_PASSWORD='change-me' FORCE=1 ./build/bootstrap.sh
sudo SYSTEMD=0 FORCE=1 ./build/bootstrap.sh
sudo KEEP_APT=1 ./build/bootstrap.sh
sudo ROOTFS=/tmp/bubble-rootfs ./build/bootstrap.sh
sudo SIZE=4G FORCE=1 ./build/build-image.sh
ESP_SIZE=256M ./build/build-disk-image.sh
KERNEL_RELEASE=... MODULE_ROOT=... ./build/build-initramfs.sh
KERNEL=... ROOT_IMAGE=... ./build/run-qemu.sh
```

The RootFS is written by default to `out/rootfs/`, the RootFS image to
`out/bubbleos-root.img`, and the bootable disk to `out/bubbleos.img`.
