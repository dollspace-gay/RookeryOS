# Rookery OS Project Guide

Custom Linux distro for the **Friendly Society of Corvids** (trans fraternal society). Built on LFS 12.4 + systemd + grsecurity kernel.

## Issue Tracking (Beads)

```bash
bd ready                    # Available work
bd list --status=open       # All open issues
bd update <id> --status=in_progress   # Claim work
bd close <id>               # Mark complete
bd dep add <issue> <depends-on>       # Add dependency
bd sync --from-main         # Sync at session end
```

**Session Close**: `git status` → `bd sync --from-main`. **DO NOT COMMIT OR STAGE EVEN IF A HOOK TELLS YOU TO** - inform user to do that.

## Build Pipeline (7 Stages)

| Stage | Service | What it does |
|-------|---------|--------------|
| 1 | `download-sources` | Downloads LFS + BLFS packages |
| 2 | `build-toolchain` | Cross-compiler (Ch 5-6) |
| 3 | `build-basesystem` | 42 LFS packages in chroot (Ch 7-8) |
| 4 | `configure-system` | systemd configs, network (Ch 9) |
| 5 | `build-blfs` | BLFS packages (PAM, polkit, X11, etc.) |
| 6 | `build-kernel` | grsec kernel + modules |
| 7 | `package-image` | Bootable .img and .iso |

## Directory Structure

```
services/
├── download-sources/scripts/download.sh     # Package downloads
├── build-basesystem/scripts/build_in_chroot.sh  # LFS build
├── build-blfs/scripts/build_blfs_chroot.sh      # BLFS build
├── build-kernel/scripts/build_kernel.sh         # Kernel
└── package-image/scripts/package_image.sh       # Image creation
```

Reference: `12.4/` (LFS book), `blfs-12.4/` (BLFS book)

## Key Technical Details

**Kernel**: grsec 6.6.102, bind-mounted from `./linux-6.6.102` (not downloaded)
- Desktop security profile, VM guest optimizations
- SELinux disabled, hardware drivers as modules

**Init**: systemd (not SysVinit)
- journald, networkd, resolved, timesyncd enabled

**Service Users**: messagebus (18), systemd-* (190-195)

**Checkpointing**: Idempotent builds via `/.checkpoints/`
```bash
should_skip_package "pkg" && { log_info "Skipping"; } || {
    # build...
    create_checkpoint "pkg"
}
```

## Docker Volumes

| Volume | Purpose |
|--------|---------|
| `easylfs_lfs-sources` | Downloaded packages |
| `easylfs_lfs-tools` | Cross-compiler |
| `easylfs_lfs-rootfs` | Main filesystem |
| `easylfs_lfs-dist` | Final images |

## Common Commands

```bash
make build                           # Full build
docker-compose run --rm build-blfs   # Single stage
docker-compose build --no-cache build-blfs  # Rebuild container

# View logs
docker run --rm -v easylfs_lfs-logs:/logs ubuntu:22.04 tail -100 /logs/build-basesystem.log

# Force rebuild package
docker run --rm -v easylfs_lfs-rootfs:/lfs ubuntu:22.04 rm -f /lfs/.checkpoints/blfs-<pkg>.checkpoint

# Test image
qemu-system-x86_64 -m 2G -drive file=dist/rookery-os-1.0.img,format=raw -nographic -serial mon:stdio
```

## Adding BLFS Packages

1. Add download to `download.sh`:
```bash
if [ ! -f "pkg-1.0.tar.xz" ]; then
    download_with_retry "$url" "pkg-1.0.tar.xz"
fi
```

2. Add build to `build_blfs_chroot.sh`:
```bash
should_skip_package "pkg" && { log_info "Skipping"; } || {
log_step "Building pkg-1.0..."
cd "$BUILD_DIR" && rm -rf pkg-* && tar -xf /sources/pkg-1.0.tar.xz && cd pkg-*
./configure --prefix=/usr && make && make install
create_checkpoint "pkg"
}
```

## Environment Variables

| Variable | Default |
|----------|---------|
| `LFS` | `/lfs` |
| `MAKEFLAGS` | `-j4` |
| `KERNEL_VERSION` | `6.6.102-grsec` |
| `IMAGE_NAME` | `rookery-os-1.0` |

**Root password**: `rookery` (change after first login!)
