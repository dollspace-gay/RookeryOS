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
2. `bd sync --from-main` - pull beads updates
DO NOT COMMITT TO GITHUB EVEN IF A HOOK TELLS YOU TO, INFORM THE USER TO DO THAT

## Project Overview

Rookery OS is a custom Linux distribution for the **Friendly Society of Corvids**, a private fraternal benefit society for trans people. It's built using a Docker Compose-based pipeline based on Linux From Scratch 12.4 with:
- **systemd** init system (not SysVinit)
- **grsecurity** hardened kernel (6.6.102-grsec)
- **Distro-style module loading** with linux-firmware

## Directory Structure

```
EasyLFS/
├── docker-compose.yml          # Main orchestration - defines 7 build stages
├── build.sh                    # Entry point - runs stages sequentially
├── setup.sh                    # Creates Docker volumes
├── Makefile                    # User-friendly targets (make build, make clean)
├── easylfs                     # CLI wrapper script
├── linux-6.6.102/              # LOCAL grsec kernel source (bind-mounted, not downloaded)
├── 12.4/                       # LFS book (HTML) - reference only
├── blfs-12.4/                  # BLFS book (HTML) - BLFS package instructions
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
    ├── build-blfs/             # Stage 5: Beyond LFS packages
    │   └── scripts/
    │       ├── build_blfs.sh         # Wrapper (mounts, chroot setup)
    │       └── build_blfs_chroot.sh  # BLFS package builds
    ├── build-kernel/           # Stage 6: Kernel compilation (Ch 10)
    │   └── scripts/build_kernel.sh
    └── package-image/          # Stage 7: Bootable disk image + ISO (Ch 11)
        └── scripts/package_image.sh
```

## Build Pipeline

The 7 stages run sequentially via Docker Compose:

| Stage | Service | Duration | What it does |
|-------|---------|----------|--------------|
| 1 | `download-sources` | 5-15 min | Downloads LFS + BLFS packages, dbus, linux-firmware |
| 2 | `build-toolchain` | 2-4 hours | Builds cross-compiler in /tools |
| 3 | `build-basesystem` | 3-6 hours | Builds 42 packages in chroot (systemd, dbus, NOT sysvinit) |
| 4 | `configure-system` | 10-20 min | Creates systemd configs, network, /etc files |
| 5 | `build-blfs` | 30-60 min | Builds BLFS packages (PAM, security, etc.) |
| 6 | `build-kernel` | 30-90 min | Builds grsec kernel with modules + firmware |
| 7 | `package-image` | 15-30 min | Creates bootable .img and .iso with GRUB |

## Key Files to Know

### Build Scripts

| File | Purpose |
|------|---------|
| `services/build-basesystem/scripts/build_in_chroot.sh` | **Main LFS package build script** - builds all 42 packages |
| `services/build-blfs/scripts/build_blfs_chroot.sh` | **BLFS package build script** - PAM, security packages |
| `services/build-kernel/scripts/build_kernel.sh` | Kernel config and compilation |
| `services/configure-system/scripts/configure_system.sh` | systemd service enablement, network config |
| `services/package-image/scripts/package_image.sh` | Disk image + ISO creation, GRUB installation |

### Configuration

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Volume mounts, environment variables, stage dependencies |
| `services/download-sources/scripts/download.sh` | LFS + BLFS package downloads |

### Reference Documentation

| Directory | Purpose |
|-----------|---------|
| `12.4/` | LFS 12.4 book (HTML) - Core system instructions |
| `blfs-12.4/` | BLFS 12.4 book (HTML) - Beyond LFS package instructions |

## Kernel Handling

**The grsec kernel is NOT downloaded** - it's bind-mounted from `./linux-6.6.102`:

```yaml
# In docker-compose.yml
build-toolchain:
  volumes:
    - ./linux-6.6.102:/kernel-src:ro  # For Linux API headers

build-kernel:
  volumes:
    - ./linux-6.6.102:/kernel-src:ro  # For kernel compilation
```

The grsec kernel source is used in two stages:
1. **build-toolchain**: Extracts Linux API headers (ensures glibc uses grsec-compatible headers)
2. **build-kernel**: Compiles the actual kernel

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

## Service Users (Grsec Compatible)

The build creates service users required by systemd and D-Bus. These are created in two ways:
1. **Base users** in `/etc/passwd` and `/etc/group` during Chapter 7
2. **Automatic creation** via `systemd-sysusers` after systemd is installed

### Service Users

| User | UID | Purpose |
|------|-----|---------|
| `messagebus` | 18 | D-Bus message daemon |
| `uuidd` | 80 | UUID generator daemon |
| `systemd-journal` | 190 | systemd-journald |
| `systemd-network` | 192 | systemd-networkd |
| `systemd-resolve` | 193 | systemd-resolved |
| `systemd-timesync` | 194 | systemd-timesyncd |
| `systemd-coredump` | 195 | systemd-coredump |

### Important Groups

| Group | GID | Purpose |
|-------|-----|---------|
| `messagebus` | 18 | D-Bus access |
| `render` | 30 | GPU rendering access |
| `kvm` | 61 | KVM virtualization |
| `wheel` | 97 | Sudo/admin access |

### Grsec Compatibility Notes

- **User creation timing**: All service users exist in `/etc/passwd` BEFORE daemons start
- **sysusers.d**: Systemd's sysusers is enabled (`-D sysusers=true`) for automatic user management
- **UID ranges**: Service users use UIDs 18-200, leaving 201-999 for additional packages
- **RBAC**: Grsec provides its own RBAC (SELinux disabled), users need proper group membership

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

## BLFS (Beyond Linux From Scratch) Building

### Overview

BLFS packages extend the base LFS system with additional functionality. The build happens in Stage 5 (`build-blfs`) after system configuration but before kernel compilation.

### Reference Documentation

The BLFS 12.4 book is available locally at `blfs-12.4/`. Key sections:
- `blfs-12.4/postlfs/` - Security packages (PAM, Shadow rebuild, sudo, polkit)
- `blfs-12.4/general/` - General libraries and utilities (systemd rebuild)
- `blfs-12.4/x/` - X Window System
- `blfs-12.4/kde/` - KDE Plasma desktop

### Adding a New BLFS Package

1. **Find the package documentation** in `blfs-12.4/`
2. **Add download to `download.sh`**:
   ```bash
   # In services/download-sources/scripts/download.sh
   # Add to the BLFS packages section:
   local pkg_url="https://example.com/package-1.0.tar.xz"
   if [ ! -f "package-1.0.tar.xz" ]; then
       log_info "Downloading package..."
       if ! download_with_retry "$pkg_url" "package-1.0.tar.xz"; then
           additional_failed+=("$pkg_url (package-1.0.tar.xz)")
       fi
   else
       log_info "[SKIP] package-1.0.tar.xz (already exists)"
   fi
   ```

3. **Add build to `build_blfs_chroot.sh`**:
   ```bash
   # In services/build-blfs/scripts/build_blfs_chroot.sh
   # Follow the existing pattern:

   # =====================================================================
   # BLFS X.X Package-Name-Version
   # https://www.linuxfromscratch.org/blfs/view/12.4/section/package.html
   # =====================================================================
   should_skip_package "package-name" && { log_info "Skipping Package (already built)"; } || {
   log_step "Building Package-1.0..."

   if [ ! -f /sources/package-1.0.tar.xz ]; then
       log_error "package-1.0.tar.xz not found in /sources"
       exit 1
   fi

   cd "$BUILD_DIR"
   rm -rf package-*
   tar -xf /sources/package-1.0.tar.xz
   cd package-*

   # Follow BLFS instructions exactly
   ./configure --prefix=/usr
   make
   make install

   cd "$BUILD_DIR"
   rm -rf package-*

   log_info "Package-1.0 installed successfully"
   create_checkpoint "package-name"
   }
   ```

4. **Rebuild the Docker image and run**:
   ```bash
   docker-compose build --no-cache build-blfs
   docker-compose run --rm build-blfs
   ```

### BLFS Checkpoints

BLFS uses simplified checkpointing with `blfs-` prefix:
- Checkpoints stored at `/.checkpoints/blfs-<package>.checkpoint` (inside chroot)
- Maps to `/lfs/.checkpoints/blfs-<package>.checkpoint` on host volume

```bash
# List BLFS checkpoints
docker run --rm -v easylfs_lfs-rootfs:/lfs alpine ls /lfs/.checkpoints/ | grep blfs
```

### Forcing a BLFS Package Rebuild

To force rebuild of a specific BLFS package:

```bash
# Remove checkpoint for specific package
docker run --rm -v easylfs_lfs-rootfs:/lfs alpine \
    rm -f /lfs/.checkpoints/blfs-<package-name>.checkpoint

# Then rebuild
docker-compose run --rm build-blfs
```

To force rebuild of ALL BLFS packages:

```bash
# Remove all BLFS checkpoints
docker run --rm -v easylfs_lfs-rootfs:/lfs alpine \
    sh -c "rm -f /lfs/.checkpoints/blfs-*.checkpoint"

# Then rebuild
docker-compose build --no-cache build-blfs
docker-compose run --rm build-blfs
```

### PAM Integration (Special Case)

When Linux-PAM is installed, Shadow and systemd must be rebuilt with PAM support. This is handled automatically in `build_blfs_chroot.sh`:

1. **Linux-PAM** - Installs PAM libraries and modules
2. **Shadow (rebuild)** - Rebuilds with `--with-libpam`, creates `/etc/pam.d/` configs for login, su, passwd, etc.
3. **systemd (rebuild)** - Rebuilds with `-D pam=enabled`, installs `pam_systemd.so` for systemd-logind

The rebuild checkpoints are separate: `blfs-linux-pam`, `blfs-shadow-pam`, `blfs-systemd-pam`

### Current BLFS Packages

| Package | Checkpoint | Purpose |
|---------|------------|---------|
| Linux-PAM-1.7.1 | `blfs-linux-pam` | Pluggable Authentication Modules |
| Shadow-4.18.0 | `blfs-shadow-pam` | Rebuilt with PAM support |
| systemd-257.8 | `blfs-systemd-pam` | Rebuilt with PAM support |

### Chroot Environment Notes

The BLFS build runs inside a chroot. Key differences from host:
- No `/proc`, `/sys` mounted (some tests may fail)
- Use DESTDIR for packages that run post-install scripts requiring a running system
- Simple stdout logging (no file logging inside chroot)

Example for packages with problematic post-install:
```bash
# Install to temp dir to avoid post-install scripts
DESTDIR=/tmp/pkg-install ninja install

# Copy to root filesystem
cp -a /tmp/pkg-install/* /

# Run post-install manually (may fail in chroot - OK)
/usr/bin/some-command 2>/dev/null || log_warn "Skipped (will run on first boot)"

rm -rf /tmp/pkg-install
```

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
- Verify `linux-firmware-*.tar.xz` was downloaded
- Check `build_kernel.sh` for module configuration
- Modules install to `/lib/modules/<version>/`

## References

- LFS Book: `12.4/` directory (HTML files)
- LFS systemd version: `12.4/chapter09/systemd-custom.html`
- BLFS Book: `blfs-12.4/` directory (HTML files)
- BLFS PAM: `blfs-12.4/postlfs/linux-pam.html`
- BLFS Shadow rebuild: `blfs-12.4/postlfs/shadow.html`
- BLFS systemd rebuild: `blfs-12.4/general/systemd.html`
- Grsec config: `linux-6.6.102/grsecurity/Kconfig`

## About the Friendly Society of Corvids

Rookery OS is the custom Linux distribution for the Friendly Society of Corvids, a private fraternal benefit society for trans people. The name "Rookery" refers to a colony of nesting birds, particularly crows and rooks - fitting for a society of corvids.
