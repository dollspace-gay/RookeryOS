# Rookery OS

> A custom Linux distribution for the Friendly Society of Corvids

[![Based on LFS](https://img.shields.io/badge/Based%20on-LFS%2012.4-blue)](https://www.linuxfromscratch.org/)
[![Kernel](https://img.shields.io/badge/Kernel-grsecurity%206.6.102-green)](https://grsecurity.net/)
[![Init](https://img.shields.io/badge/Init-systemd-orange)](https://systemd.io/)

## Overview

Rookery OS is a security-hardened Linux distribution built for the **Friendly Society of Corvids**, a private fraternal benefit society for trans people. Built from scratch using Linux From Scratch 12.4 as a base, it features:

- **Grsecurity kernel** (6.6.102-grsec) with desktop security profile
- **systemd** init system with journald logging
- **Distro-style module loading** with linux-firmware for hardware support
- **Docker Compose pipeline** for reproducible builds

## Quick Start

```bash
# Clone and enter the project
git clone <repository-url>
cd RookeryOS

# Build the complete system (6-11 hours)
./rookery build

# Output files in dist/:
# - rookery-os-1.0.img.xz  (bootable disk image)
# - rookery-os-1.0.iso     (bootable ISO)
# - rookery-os-1.0.tar.gz  (system tarball)
```

## Requirements

- **Docker**: 24.0 or higher
- **Docker Compose**: 2.20 or higher
- **Disk Space**: 20GB minimum (30GB recommended)
- **RAM**: 4GB minimum (8GB recommended)
- **Local grsec kernel**: `linux-6.6.102/` directory with grsecurity patches

## Build Pipeline

| Stage | Duration | Description |
|-------|----------|-------------|
| download-sources | 5-15 min | Download Rookery Core packages + dbus + linux-firmware |
| build-toolchain | 2-4 hours | Cross-compiler in /tools |
| build-basesystem | 3-6 hours | 42 packages in chroot (systemd, NOT sysvinit) |
| configure-system | 10-20 min | systemd configs, network, /etc files |
| build-extended | 1-3 hours | Rookery Extended packages (security, desktop, etc.) |
| build-kernel | 30-90 min | Grsec kernel with modules + firmware |
| package-image | 15-30 min | Bootable .img and .iso with GRUB |

## Booting the System

### QEMU (Serial Console)
```bash
# From disk image
unxz dist/rookery-os-1.0.img.xz
qemu-system-x86_64 -m 2G -smp 2 \
    -drive file=dist/rookery-os-1.0.img,format=raw \
    -nographic -serial mon:stdio

# From ISO
qemu-system-x86_64 -m 2G -smp 2 \
    -cdrom dist/rookery-os-1.0.iso \
    -boot d -nographic -serial mon:stdio
```

### USB Boot
```bash
# Write to USB drive (CAREFUL: replaces all data!)
dd if=dist/rookery-os-1.0.img of=/dev/sdX bs=4M status=progress
```

## Default Credentials

- **Hostname**: `rookery`
- **Root password**: `rookery` (CHANGE AFTER FIRST LOGIN!)
- **Network**: Static IP 10.0.2.15/24 (QEMU default)

## Useful Commands

```bash
./rookery status     # Check build progress
./rookery logs       # View build logs
./rookery export     # Export disk image to current directory
./rookery shell      # Open shell in rootfs
./rookery clean      # Remove containers (keep volumes)
./rookery reset      # Complete reset
```

## Project Structure

```
RookeryOS/
├── docker-compose.yml      # Build orchestration
├── linux-6.6.102/          # Grsec kernel source (local, not downloaded)
├── services/
│   ├── download-sources/   # Package downloads
│   ├── build-toolchain/    # Cross-compiler
│   ├── build-basesystem/   # Rookery Core (base system)
│   ├── configure-system/   # System configuration
│   ├── build-blfs/         # Rookery Extended packages
│   ├── build-kernel/       # Kernel compilation
│   └── package-image/      # Image creation
└── dist/                   # Output images
```

## Key Features

### Grsecurity Kernel
- `GRKERNSEC_CONFIG_DESKTOP` - Desktop security profile
- `GRKERNSEC_CONFIG_VIRT_GUEST` - VM guest optimizations
- SELinux disabled (grsec provides its own RBAC)
- All hardware drivers as loadable modules

### systemd Init
- Full systemd (not udev-only)
- systemd-journald for logging
- systemd-networkd for networking
- Serial console on ttyS0

### Reproducible Builds
- Checkpoint-based idempotent builds
- Resume from any failure point
- Hash-verified package downloads

## Troubleshooting

### View build logs
```bash
docker run --rm -v rookery_logs:/logs ubuntu:22.04 tail -100 /logs/build-basesystem.log
```

### Force rebuild of a stage
Delete the checkpoint file from the Docker volume, then re-run the stage.

### Kernel doesn't boot
- Verify GRUB config uses `init=/usr/lib/systemd/systemd`
- Try verbose boot option in GRUB menu
- Check serial console output

## About

Rookery OS is the official operating system of the **Friendly Society of Corvids**, a private fraternal benefit society for trans people. The name "Rookery" refers to a colony of nesting birds, particularly crows and rooks - fitting for a society of corvids.

Built with the wisdom of the Linux From Scratch community.

## License

See [CREDITS.md](CREDITS.md) for attribution and third-party licenses.

## References

- [Linux From Scratch 12.4](https://www.linuxfromscratch.org/lfs/view/12.4/)
- [Grsecurity](https://grsecurity.net/)
- [systemd](https://systemd.io/)
