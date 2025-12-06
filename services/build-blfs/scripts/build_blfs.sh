#!/bin/bash
set -euo pipefail

# =============================================================================
# EasyLFS Build BLFS Packages Script
# Builds Beyond LFS packages in chroot (Security, Desktop, etc.)
# =============================================================================

# Environment
export LFS="${LFS:-/lfs}"
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

SOURCES_DIR="/sources"

# Load common utilities
COMMON_DIR="/usr/local/lib/easylfs-common"
if [ -d "$COMMON_DIR" ]; then
    source "$COMMON_DIR/logging.sh" 2>/dev/null || true
    source "$COMMON_DIR/checkpointing.sh" 2>/dev/null || true
else
    # Fallback for development/local testing
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../../common/logging.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/../../common/checkpointing.sh" 2>/dev/null || true
fi

# Fallback logging if common module not available
if ! type log_info &>/dev/null; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
    log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
fi

# Verify prerequisites
verify_prerequisites() {
    log_info "Verifying prerequisites..."

    if [ ! -d "$LFS" ]; then
        log_error "LFS directory not found: $LFS"
        exit 1
    fi

    if [ ! -f "$LFS/usr/bin/gcc" ]; then
        log_error "GCC not found in LFS. Run build-basesystem first!"
        exit 1
    fi

    if [ ! -f "$LFS/usr/lib/systemd/systemd" ]; then
        log_error "Systemd not found in LFS. Run build-basesystem first!"
        exit 1
    fi

    log_info "Prerequisites OK"
}

# Prepare chroot environment
prepare_chroot() {
    log_info "Preparing chroot environment..."

    # Create essential directories
    mkdir -pv $LFS/{dev,proc,sys,run,tmp}

    # Mount virtual filesystems
    log_info "Mounting virtual filesystems..."
    mount --bind /dev $LFS/dev || log_warn "Failed to mount /dev"
    mount -t devpts devpts $LFS/dev/pts -o gid=5,mode=620 || log_warn "Failed to mount /dev/pts"
    mount -t proc proc $LFS/proc || log_warn "Failed to mount /proc"
    mount -t sysfs sysfs $LFS/sys || log_warn "Failed to mount /sys"
    mount -t tmpfs tmpfs $LFS/run || log_warn "Failed to mount /run"

    # Create /dev/fd symlink for bash process substitution (requires /proc)
    # This is needed for NetworkManager's build scripts that use <(...) syntax
    if [ ! -e "$LFS/dev/fd" ]; then
        ln -sv /proc/self/fd $LFS/dev/fd || log_warn "Failed to create /dev/fd symlink"
    fi

    # Bind mount sources
    mkdir -p $LFS/sources
    if [ -d "$SOURCES_DIR" ]; then
        mount --bind $SOURCES_DIR $LFS/sources || log_warn "Failed to mount sources"
    fi

    # Copy common utilities into chroot
    log_info "Copying common utilities into chroot..."
    mkdir -p $LFS/tmp/easylfs-common

    # Copy checkpointing module
    if [ -f "/usr/local/lib/easylfs-common/checkpointing.sh" ]; then
        cp "/usr/local/lib/easylfs-common/checkpointing.sh" $LFS/tmp/easylfs-common/
    fi

    # Copy logging module
    if [ -f "/usr/local/lib/easylfs-common/logging.sh" ]; then
        cp "/usr/local/lib/easylfs-common/logging.sh" $LFS/tmp/easylfs-common/
    fi

    # Initialize checkpoint system
    init_checkpointing
    log_info "Chroot environment ready"
}

# Cleanup chroot mounts
cleanup_chroot() {
    log_info "Cleaning up chroot mounts..."

    umount -l $LFS/sources 2>/dev/null || true
    umount -l $LFS/dev/pts 2>/dev/null || true
    umount -l $LFS/dev 2>/dev/null || true
    umount -l $LFS/proc 2>/dev/null || true
    umount -l $LFS/sys 2>/dev/null || true
    umount -l $LFS/run 2>/dev/null || true

    log_info "Cleanup complete"
}

# Trap to ensure cleanup on exit
trap cleanup_chroot EXIT INT TERM

# Enter chroot and build BLFS packages
build_in_chroot() {
    log_info "Entering chroot environment..."

    # Copy the chroot build script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "/usr/local/bin/build_blfs_chroot.sh" ]; then
        cp "/usr/local/bin/build_blfs_chroot.sh" $LFS/tmp/build_blfs_chroot.sh
    else
        cp "$SCRIPT_DIR/build_blfs_chroot.sh" $LFS/tmp/build_blfs_chroot.sh
    fi

    chmod +x $LFS/tmp/build_blfs_chroot.sh

    # Execute chroot with unbuffered output
    log_info "Executing BLFS chroot build script..."

    # Create log file
    touch $LFS/tmp/blfs_build.log
    chmod 666 $LFS/tmp/blfs_build.log

    set +e

    stdbuf -oL -eL chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        MAKEFLAGS="$MAKEFLAGS" \
        LC_ALL=POSIX \
        /bin/bash /tmp/build_blfs_chroot.sh 2>&1 | stdbuf -oL -eL tee $LFS/tmp/blfs_build.log

    CHROOT_EXIT_CODE=${PIPESTATUS[0]}
    set -e

    echo ""
    log_info "Chroot script exited with code: $CHROOT_EXIT_CODE"

    rm -f $LFS/tmp/build_blfs_chroot.sh

    if [ $CHROOT_EXIT_CODE -ne 0 ]; then
        log_error "BLFS build failed!"
        exit $CHROOT_EXIT_CODE
    fi
}

# Main
main() {
    log_info "=========================================="
    log_info "EasyLFS BLFS Package Build Starting"
    log_info "=========================================="

    verify_prerequisites
    prepare_chroot
    build_in_chroot

    log_info ""
    log_info "=========================================="
    log_info "BLFS Package Build Finished!"
    log_info "=========================================="

    exit 0
}

main "$@"
