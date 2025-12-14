# Rookery OS Quick Start Guide

**Build a custom Linux distribution in 3 commands!**

## Prerequisites

- Docker 24.0+
- Docker Compose 2.20+
- 20GB free disk space
- 6-12 hours of build time

## Build Your Rookery OS System

```bash
# 1. Clone the repository
git clone <repository-url>
cd RookeryOS

# 2. Build the complete system (auto-setup included)
./rookery build

# 3. Export the bootable image
./rookery export
```

That's it! You now have a bootable Rookery OS system.

## Boot Your System

### Option 1: Local QEMU

```bash
# Boot with QEMU
qemu-system-x86_64 -m 2G -drive file=rookery-os-1.0.img,format=raw -nographic -serial mon:stdio
```

### Option 2: Web Browser (No Export Needed!)

Access your Rookery OS system directly from your browser:

```bash
# Start web interfaces
make web

# Access in browser:
# Terminal: http://localhost:7681
# Screen:   http://localhost:6080/vnc.html
```

**Benefits**:
- No need to export the image
- No QEMU installation required on host
- Access from any device on your network
- Perfect for demos and teaching

See [WEB_INTERFACE.md](WEB_INTERFACE.md) for complete documentation.

## Common Commands

```bash
./rookery status     # Check build progress
./rookery logs       # View build logs
./rookery shell      # Explore Rookery filesystem
./rookery clean      # Remove containers
./rookery reset      # Start fresh
./rookery help       # Show all commands
```

## Alternative: Using Make

```bash
make setup        # Initialize environment
make build        # Build Rookery OS system
make status       # Check progress
make export       # Export image
make help         # Show all targets
```

## Build Stages

The build process runs 7 sequential stages:

1. **download-sources** (5-15 min) - Download Rookery Core packages
2. **build-toolchain** (2-4 hours) - Build cross-compilation toolchain
3. **build-basesystem** (3-6 hours) - Build Rookery Core (base system)
4. **configure-system** (10-20 min) - Configure system files
5. **build-extended** (1-3 hours) - Build Rookery Extended packages
6. **build-kernel** (20-60 min) - Compile Linux kernel
7. **package-image** (15-30 min) - Create bootable image

**Total time: 6-12 hours** (depending on hardware)

## Run Individual Stages

```bash
./rookery download     # Just download sources
./rookery toolchain    # Just build toolchain
./rookery basesystem   # Just build base system
./rookery configure    # Just configure system
./rookery extended     # Just build extended packages
./rookery kernel       # Just build kernel
./rookery package      # Just create image
```

## Troubleshooting

**Build fails mid-process?**
```bash
./rookery logs         # Check what went wrong
./rookery <stage>      # Re-run failed stage
```

**Want to start over?**
```bash
./rookery reset        # Complete reset
./rookery build        # Start fresh
```

**Need help?**
```bash
./rookery help         # Show all commands
cat README.md          # Full documentation
```

## What Makes This Special?

- Automatic setup - No manual volume creation
- Resume capability - Failed builds can be resumed
- Portable - Works identically everywhere
- Educational - Learn Docker + Linux build concepts
- Transparent - All scripts are readable
- Security-focused - Grsecurity kernel hardening

## Next Steps

- Read `README.md` for advanced usage
- Check `CLAUDE.md` for build system details

---

**Questions?** Check the full `README.md` or open an issue!
