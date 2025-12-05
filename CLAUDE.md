# Rookery OS Project Guide

This document helps Claude (and developers) understand and navigate the Rookery OS build system.

## Issue Tracking with Beads

This project uses **beads** (`bd`) for issue tracking. Track ALL work in beads - do not use TodoWrite or markdown TODOs.

### Essential Commands

```bash
# Finding work
bd ready                    # Show issues ready to work (no blockers)
bd list --status=open       # All open issues
bd show <id>                # Detailed issue view

# Creating & updating
bd create --title="Fix X" --type=task|bug|feature
bd update <id> --status=in_progress   # Claim work
bd close <id>               # Mark complete
bd close <id1> <id2> ...    # Close multiple at once

# Dependencies
bd dep add <issue> <depends-on>   # Add dependency
bd blocked                  # Show blocked issues

# Sync (run at session end)
bd sync --from-main         # Pull beads updates from main
```

### Session Close Protocol

Before ending work, run:
1. `git status` - check changes
2. `git add <files>` - stage code
3. `bd sync --from-main` - pull beads updates
4. `git commit -m "..."` - commit changes

## Project Overview

Rookery OS is a custom Linux distribution for the **Friendly Society of Corvids**, a private fraternal benefit society for trans people. It's built using a Docker Compose-based pipeline based on Linux From Scratch 12.4 with:
- **systemd** init system (not SysVinit)
- **grsecurity** hardened kernel (6.6.102-grsec)
- **Distro-style module loading** with linux-firmware

## Directory Structure

```
EasyLFS/
├── docker-compose.yml          # Main orchestration - defines 6 build stages
├── build.sh                    # Entry point - runs stages sequentially
├── setup.sh                    # Creates Docker volumes
├── Makefile                    # User-friendly targets (make build, make clean)
├── easylfs                     # CLI wrapper script
├── linux-6.6.102/              # LOCAL grsec kernel source (bind-mounted, not downloaded)
├── 12.4/                       # LFS book (HTML) - reference only
└── services/                   # Per-stage Docker services
    ├── common/                 # Shared utilities
    │   ├── logging.sh          # log_info, log_step, log_error functions
    │   └── checkpointing.sh    # Idempotent build tracking
    ├── download-sources/       # Stage 1: Download packages
    │   └── scripts/download.sh
    ├── build-toolchain/        # Stage 2: Cross-compiler (Ch 5-6)
    │   └── scripts/build_toolchain.sh
    ├── build-basesystem/       # Stage 3: Core system in chroot (Ch 7-8)
    │   └── scripts/
    │       ├── build_system.sh
    │       └── build_in_chroot.sh  # THE MAIN BUILD SCRIPT
    ├── configure-system/       # Stage 4: System config (Ch 9)
    │   └── scripts/configure_system.sh
    ├── build-kernel/           # Stage 5: Kernel compilation (Ch 10)
    │   └── scripts/build_kernel.sh
    └── package-image/          # Stage 6: Bootable disk image + ISO (Ch 11)
        └── scripts/package_image.sh
```

## Build Pipeline

The 6 stages run sequentially via Docker Compose:

| Stage | Service | Duration | What it does |
|-------|---------|----------|--------------|
| 1 | `download-sources` | 5-15 min | Downloads LFS packages + dbus + linux-firmware |
| 2 | `build-toolchain` | 2-4 hours | Builds cross-compiler in /tools |
| 3 | `build-basesystem` | 3-6 hours | Builds 42 packages in chroot (systemd, dbus, NOT sysvinit) |
| 4 | `configure-system` | 10-20 min | Creates systemd configs, network, /etc files |
| 5 | `build-kernel` | 30-90 min | Builds grsec kernel with modules + firmware |
| 6 | `package-image` | 15-30 min | Creates bootable .img and .iso with GRUB |

## Key Files to Know

### Build Scripts

| File | Purpose |
|------|---------|
| `services/build-basesystem/scripts/build_in_chroot.sh` | **Main package build script** - builds all 42 packages |
| `services/build-kernel/scripts/build_kernel.sh` | Kernel config and compilation |
| `services/configure-system/scripts/configure_system.sh` | systemd service enablement, network config |
| `services/package-image/scripts/package_image.sh` | Disk image + ISO creation, GRUB installation |

### Configuration

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Volume mounts, environment variables, stage dependencies |
| `services/download-sources/wget-list` | LFS package URLs |
| `services/download-sources/md5sums` | Package checksums |

## Kernel Handling

**The grsec kernel is NOT downloaded** - it's bind-mounted from `./linux-6.6.102`:

```yaml
# In docker-compose.yml
build-kernel:
  volumes:
    - ./linux-6.6.102:/kernel-src:ro  # Local grsec source
```

The kernel build script (`build_kernel.sh`) configures:
- `GRKERNSEC_CONFIG_DESKTOP` - Desktop security profile
- `GRKERNSEC_CONFIG_VIRT_GUEST` - VM guest optimizations
- `CONFIG_SECURITY_SELINUX=n` - SELinux disabled
- Hardware drivers as modules (distro-style)
- linux-firmware installed to `/lib/firmware`

## Init System: systemd

This build uses **systemd**, not SysVinit. Key differences from standard LFS:

| Removed | Added |
|---------|-------|
| sysvinit | systemd (full) |
| sysklogd | systemd-journald |
| lfs-bootscripts | systemd services |
| /etc/inittab | /etc/systemd/system/default.target |
| /etc/sysconfig/ifconfig.* | /etc/systemd/network/*.network |

## Checkpointing System

Builds are idempotent via checkpoints in `/.checkpoints/`:

```bash
# Check if package already built
should_skip_package "systemd" "/sources" && { log_info "Skipping..."; } || {
    # Build package...
    create_checkpoint "systemd" "/sources" "chapter8"
}
```

To force rebuild: delete checkpoints from the Docker volume.

## Docker Volumes

| Volume | Purpose |
|--------|---------|
| `easylfs_lfs-sources` | Downloaded packages (~1GB) |
| `easylfs_lfs-tools` | Cross-compiler toolchain |
| `easylfs_lfs-rootfs` | Main LFS filesystem (~4GB) |
| `easylfs_lfs-dist` | Final bootable images (img, iso, tarball) |
| `easylfs_lfs-logs` | Build logs |

## Common Tasks

### Run full build
```bash
make build
# or
./build.sh
```

### Run single stage
```bash
docker-compose run --rm build-kernel
```

### View logs
```bash
docker run --rm -v easylfs_lfs-logs:/logs alpine cat /logs/build-basesystem.log
```

### Clean and rebuild
```bash
make clean   # Removes volumes
make setup   # Recreates volumes
make build   # Full build
```

### Test the image
```bash
# Serial console (QEMU) - disk image
qemu-system-x86_64 -m 2G -smp 2 \
    -drive file=dist/rookery-os-1.0.img,format=raw \
    -nographic -serial mon:stdio

# Or boot from ISO
qemu-system-x86_64 -m 2G -smp 2 \
    -cdrom dist/rookery-os-1.0.iso \
    -boot d -nographic -serial mon:stdio
```

## Environment Variables

Set in `docker-compose.yml`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LFS` | `/lfs` | LFS root directory |
| `MAKEFLAGS` | `-j4` | Parallel compilation |
| `KERNEL_VERSION` | `6.6.102-grsec` | Kernel version string |
| `IMAGE_NAME` | `rookery-os-1.0` | Output image name |
| `IMAGE_SIZE` | `6144` | Disk image size in MB |
| `HOSTNAME` | `rookery` | Default system hostname |

## Default Credentials

- **Root password**: `rookery` (CHANGE AFTER FIRST LOGIN!)

## Troubleshooting

### Build fails at package X
1. Check logs: `docker run --rm -v easylfs_lfs-logs:/logs alpine tail -100 /logs/build-basesystem.log`
2. Package builds are in `build_in_chroot.sh` - search for the package name
3. Delete checkpoint to retry: find the `.checkpoint` file in the volume

### Kernel doesn't boot
- Check GRUB config in `package_image.sh`
- Verify `init=/usr/lib/systemd/systemd` is on kernel command line
- Check serial console output with verbose boot option

### Missing firmware/modules
- Verify `linux-firmware-*.tar.gz` was downloaded
- Check `build_kernel.sh` for module configuration
- Modules install to `/lib/modules/<version>/`

## References

- LFS Book: `12.4/` directory (HTML files)
- LFS systemd version: `12.4/chapter09/systemd-custom.html`
- Grsec config: `linux-6.6.102/grsecurity/Kconfig`

## About the Friendly Society of Corvids

Rookery OS is the custom Linux distribution for the Friendly Society of Corvids, a private fraternal benefit society for trans people. The name "Rookery" refers to a colony of nesting birds, particularly crows and rooks - fitting for a society of corvids.
