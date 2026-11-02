# bubbleOS Architecture

## Core principle

bubbleOS uses the Linux kernel and ULPM/LPK as its native package ecosystem.

The repository contains a BubbleOS-maintained copy of ULPM in `ulpm/`. This copy may be adapted for operating-system requirements without changing the independent ULPM upstream repository.

## Responsibilities

### ULPM

ULPM remains the package engine responsible for package acquisition, verification, dependency handling, transactions and LPK operations.

### BubbleOS Core

The `bubble/` layer owns operating-system concerns:

- system state paths;
- generations;
- activation;
- rollback orchestration;
- boot integration (generation validation and boot records).

## Generation model

System packages will eventually be resolved by ULPM and composed into a new generation before activation. The previous generation remains available for rollback.

Initial scaffold:

```text
/var/lib/bubbleos/
├── generations/
├── current -> generations/000001
├── previous
├── store/
├── transactions/
└── wal/
```

The current implementation establishes this metadata structure and validates the
active generation at boot. It does not yet compose generation-specific
userspace trees.

## Boot chain (current milestone)

```text
UEFI firmware (OVMF in QEMU)
 └── GPT disk
      ├── partition 1: FAT32 ESP
      │    ├── /EFI/BOOT/BOOTX64.EFI   (Limine 12.9.6)
      │    ├── /boot/vmlinuz           (Linux 7.2.12)
      │    └── /boot/initramfs.cpio.gz
      └── partition 2: ext4 RootFS
           └── Linux 7.2.12
                └── initramfs (BusyBox + storage modules)
                     └── /init
                          ├── mounts /dev/vda2 (ext4)
                          └── switch_root /newroot
                               └── systemd (PID 1)
                                    ├── udev, D-Bus, PAM sessions
                                    ├── serial/getty login prompts
                                    └── bubbleos-boot.service
                                         └── bubble boot
                                              └── activates generation metadata
```

The kernel is extracted from Debian packages by `build/build-kernel.sh`;
`build/build-initramfs.sh` builds the early userspace,
`build/build-image.sh` packs the RootFS into an ext4 image, and
`build/build-disk-image.sh` assembles the GPT/ESP disk consumed by
`build/run-qemu.sh`.

The bootloader and kernel live in the ESP so that a generation can later
reference its own kernel/initramfs pair. The RootFS carries systemd and the
generation metadata (`/var/lib/bubbleos`). `bubbleos-boot.service` currently
validates the active generation and records boot information; it does not yet
switch the root filesystem to a generation-specific tree.

### Boot activation roadmap

1. **Current** — metadata activation: validate `current`, record boot info.
2. **Next** — select a generation-specific kernel/initramfs in Limine.
3. **Later** — compose generations in ULPM's store and activate them at boot,
   with rollback through the previous generation link.
