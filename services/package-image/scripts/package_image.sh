#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Package Image Script
# Creates bootable disk image and ISO (systemd + grsecurity)
# A custom Linux distribution for the Friendly Society of Corvids
# Duration: 15-30 minutes
# =============================================================================

export LFS="${LFS:-/lfs}"
export IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
export IMAGE_SIZE="${IMAGE_SIZE:-6144}"  # Size in MB (6GB for firmware + modules)

DIST_DIR="/dist"

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Fallback logging functions if not loaded
if ! type log_info &>/dev/null; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
fi

# Create disk image
create_disk_image() {
    log_info "=========================================="
    log_info "Creating Bootable Disk Image"
    log_info "=========================================="

    # Create loop devices if they don't exist (Docker containers often lack them)
    log_step "Ensuring loop devices exist..."
    for i in $(seq 0 7); do
        if [ ! -b /dev/loop$i ]; then
            mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null || true
        fi
    done

    local image_file="$DIST_DIR/${IMAGE_NAME}.img"

    log_step "Creating disk image file (${IMAGE_SIZE}MB)..."
    dd if=/dev/zero of="$image_file" bs=1M count=$IMAGE_SIZE status=progress

    log_step "Partitioning disk image..."

    # Create partition table
    # Note: Suppress udevadm warnings from parted (not available in containers)
    parted -s "$image_file" mklabel msdos 2>/dev/null
    parted -s "$image_file" mkpart primary ext4 1MiB 100% 2>/dev/null
    parted -s "$image_file" set 1 boot on 2>/dev/null

    log_step "Setting up loop device with offset..."

    # In containers, partition devices often don't work properly
    # Use offset-based mounting instead (partition starts at 1MiB)
    local partition_offset=$((1024 * 1024))  # 1MiB in bytes

    # Format the partition area directly in the image file
    log_step "Formatting partition..."
    # Create a loop device for the partition area only
    local loop_dev=$(losetup -f)
    losetup -o $partition_offset "$loop_dev" "$image_file"

    mkfs.ext4 -L "ROOKERY" "$loop_dev"

    # Detach all loop devices to avoid conflicts
    losetup -d "$loop_dev"
    losetup -D 2>/dev/null || true  # Detach all loop devices
    sleep 2  # Give kernel time to release devices

    # Mount the partition
    log_step "Mounting partition..."
    local mount_point="/tmp/lfs-mount"
    mkdir -p "$mount_point"
    mount -o loop,offset=$partition_offset "$image_file" "$mount_point"

    # Copy LFS system
    log_step "Copying LFS system to image..."
    rsync -aAX \
        --exclude=/dev/* \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/run/* \
        --exclude=/tmp/* \
        --exclude=/sources/* \
        --exclude=/build/* \
        --exclude=/tools/* \
        --exclude=/.checkpoints \
        --exclude='*.log' \
        --exclude='*.a' \
        --exclude=/usr/share/doc/* \
        --exclude=/usr/share/man/man3/* \
        "$LFS/" "$mount_point/"

    # Create essential directories
    mkdir -p $mount_point/{dev,proc,sys,run,tmp}
    chmod 1777 $mount_point/tmp

    # Verify systemd init system is present in the mounted image
    log_step "Verifying systemd init system in image..."

    if [ -f "$mount_point/usr/lib/systemd/systemd" ]; then
        log_info "Found /usr/lib/systemd/systemd binary"

        # Verify it's executable
        if [ -x "$mount_point/usr/lib/systemd/systemd" ]; then
            log_info "✓ systemd is executable"
        else
            log_warn "ERROR: /usr/lib/systemd/systemd exists but is not executable"
            exit 1
        fi

        # Verify /sbin/init symlink exists and points to systemd
        if [ -L "$mount_point/sbin/init" ]; then
            local init_target=$(readlink "$mount_point/sbin/init")
            log_info "✓ /sbin/init symlink found -> $init_target"
        else
            log_warn "WARNING: /sbin/init symlink missing, creating..."
            ln -sf /usr/lib/systemd/systemd "$mount_point/sbin/init"
        fi

        # Verify default.target exists
        if [ -L "$mount_point/etc/systemd/system/default.target" ]; then
            log_info "✓ default.target configured"
        else
            log_warn "WARNING: default.target missing (created by configure-system)"
        fi

        # Verify systemd-networkd configuration
        if [ -f "$mount_point/etc/systemd/network/10-eth-static.network" ]; then
            log_info "✓ systemd-networkd configured"
        else
            log_warn "WARNING: network configuration missing"
        fi

        log_info "✓ systemd verified in disk image"
    else
        log_warn "ERROR: /usr/lib/systemd/systemd does not exist in disk image"
        log_warn "This should have been created during systemd installation (build-basesystem)"
        exit 1
    fi

    # Verify grsec kernel and modules
    log_step "Verifying grsec kernel..."
    if ls "$mount_point/boot/vmlinuz-"*grsec* 1>/dev/null 2>&1; then
        local kernel_file=$(ls "$mount_point/boot/vmlinuz-"*grsec* | head -1)
        log_info "✓ Grsec kernel found: $(basename $kernel_file)"
    else
        log_warn "WARNING: Grsec kernel not found, checking for any kernel..."
        if [ -f "$mount_point/boot/vmlinuz" ]; then
            log_info "✓ Kernel symlink found"
        else
            log_warn "ERROR: No kernel found!"
        fi
    fi

    # Verify modules directory
    if ls -d "$mount_point/lib/modules/"* 1>/dev/null 2>&1; then
        local modules_dir=$(ls -d "$mount_point/lib/modules/"* | head -1)
        local modules_size=$(du -sh "$modules_dir" 2>/dev/null | cut -f1)
        log_info "✓ Kernel modules found: $(basename $modules_dir) ($modules_size)"
    else
        log_warn "WARNING: Kernel modules not found"
    fi

    # Verify firmware
    if [ -d "$mount_point/lib/firmware" ] && [ "$(ls -A $mount_point/lib/firmware 2>/dev/null)" ]; then
        local firmware_size=$(du -sh "$mount_point/lib/firmware" 2>/dev/null | cut -f1)
        log_info "✓ Firmware installed ($firmware_size)"
    else
        log_warn "WARNING: Firmware not found"
    fi

    # Create poweroff/reboot utilities using SysRq
    log_step "Creating poweroff/reboot utilities..."

    cat > $mount_point/usr/sbin/poweroff << 'EOF'
#!/bin/sh
echo "System is going down for power off..."
sync
echo o > /proc/sysrq-trigger
EOF

    cat > $mount_point/usr/sbin/reboot << 'EOF'
#!/bin/sh
echo "System is going down for reboot..."
sync
echo b > /proc/sysrq-trigger
EOF

    chmod +x $mount_point/usr/sbin/poweroff
    chmod +x $mount_point/usr/sbin/reboot
    log_info "Power management utilities created"

    # Install GRUB
    log_step "Installing GRUB bootloader..."

    # Create a loop device for the ENTIRE disk image (needed for GRUB MBR installation)
    log_info "Creating loop device for full disk image..."
    local grub_loop_dev=$(losetup -f --show "$image_file")
    log_info "Loop device created: $grub_loop_dev"

    # Mount virtual filesystems for GRUB
    mount --bind /dev $mount_point/dev
    mount -t devpts devpts $mount_point/dev/pts
    mount -t proc proc $mount_point/proc
    mount -t sysfs sysfs $mount_point/sys

    # Install GRUB to MBR using chroot (LFS method)
    log_info "Installing GRUB to disk MBR via chroot..."

    # Remove load.cfg if it exists (prevents UUID search issues)
    rm -f $mount_point/boot/grub/i386-pc/load.cfg

    # Install GRUB from within the LFS system using chroot
    chroot $mount_point /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        PATH=/usr/bin:/usr/sbin \
        /usr/sbin/grub-install --target=i386-pc \
                               --boot-directory=/boot \
                               --modules="part_msdos ext2 biosdisk search" \
                               --no-floppy \
                               --recheck \
                               "$grub_loop_dev" || log_warn "GRUB installation completed with warnings"

    # Remove the problematic load.cfg that grub-install creates
    # This file causes UUID search issues during boot
    rm -f $mount_point/boot/grub/i386-pc/load.cfg
    log_info "Removed load.cfg to prevent UUID search issues"

    # Create GRUB configuration with serial console support
    log_info "Creating GRUB configuration with serial console support..."
    mkdir -p $mount_point/boot/grub

    cat > $mount_point/boot/grub/grub.cfg << 'EOF'
# GRUB configuration for Rookery OS 1.0
# A custom Linux distribution for the Friendly Society of Corvids
# Serial console compatible (QEMU -nographic)

# Configure serial port (115200 baud, 8N1)
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1

# Use both serial and console terminals for compatibility
terminal_input serial console
terminal_output serial console

set default=0
set timeout=5
set timeout_style=menu

insmod ext2
set root=(hd0,1)

menuentry "Rookery OS 1.0" {
    linux /boot/vmlinuz root=/dev/sda1 ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}

menuentry "Rookery OS 1.0 (Verbose Boot)" {
    linux /boot/vmlinuz root=/dev/sda1 ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug systemd.log_target=console loglevel=7
}

menuentry "Rookery OS 1.0 (Recovery)" {
    linux /boot/vmlinuz root=/dev/sda1 rw init=/usr/lib/systemd/systemd systemd.unit=rescue.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}

menuentry "Rookery OS 1.0 (Emergency Shell)" {
    linux /boot/vmlinuz root=/dev/sda1 rw init=/usr/lib/systemd/systemd systemd.unit=emergency.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}
EOF

    log_info "GRUB installation complete"

    # Cleanup mounts
    log_step "Cleaning up..."
    umount $mount_point/dev/pts 2>/dev/null || true
    umount $mount_point/dev 2>/dev/null || true
    umount $mount_point/proc 2>/dev/null || true
    umount $mount_point/sys 2>/dev/null || true
    umount $mount_point

    # Detach loop devices
    log_info "Detaching loop device for GRUB: $grub_loop_dev"
    losetup -d "$grub_loop_dev" 2>/dev/null || log_warn "Failed to detach $grub_loop_dev"

    log_info "Disk image created: $image_file"
    log_info "Image size: $(du -h $image_file | cut -f1)"

    # Compress image
    log_step "Compressing image..."
    gzip -c "$image_file" > "${image_file}.gz"
    log_info "Compressed image: ${image_file}.gz ($(du -h ${image_file}.gz | cut -f1))"
}

# Create simple tarball (alternative method)
create_tarball() {
    log_step "Creating system tarball..."

    local tarball="$DIST_DIR/${IMAGE_NAME}.tar.gz"

    tar -czf "$tarball" \
        --exclude=$LFS/dev/* \
        --exclude=$LFS/proc/* \
        --exclude=$LFS/sys/* \
        --exclude=$LFS/run/* \
        --exclude=$LFS/tmp/* \
        --exclude=$LFS/sources/* \
        --exclude=$LFS/build/* \
        --exclude=$LFS/tools/* \
        -C "$LFS" .

    log_info "Tarball created: $tarball"
    log_info "Size: $(du -h $tarball | cut -f1)"
}

# Create bootable ISO image
create_iso() {
    log_info "=========================================="
    log_info "Creating Bootable ISO Image"
    log_info "=========================================="

    local iso_file="$DIST_DIR/${IMAGE_NAME}.iso"
    local iso_root="/tmp/iso-root"
    local iso_boot="$iso_root/boot"

    # Check for required tools
    if ! command -v xorriso &>/dev/null; then
        log_warn "xorriso not found - skipping ISO creation"
        log_warn "Install xorriso to enable ISO creation"
        return 0
    fi

    # Clean up any previous ISO build
    rm -rf "$iso_root"
    mkdir -p "$iso_boot/grub"

    # Copy kernel and create initramfs structure
    log_step "Setting up ISO boot files..."

    # Copy kernel
    if [ -f "$LFS/boot/vmlinuz" ]; then
        cp "$LFS/boot/vmlinuz" "$iso_boot/"
        log_info "Copied kernel to ISO"
    else
        log_warn "No kernel found at $LFS/boot/vmlinuz"
        return 1
    fi

    # Create a minimal initramfs for ISO boot
    log_step "Creating initramfs for ISO boot..."
    local initramfs_dir="/tmp/initramfs-iso"
    rm -rf "$initramfs_dir"
    mkdir -p "$initramfs_dir"/{bin,sbin,etc,proc,sys,dev,newroot,lib,lib64,usr/lib,usr/bin,usr/sbin}

    # Copy essential binaries from LFS system
    cp -a "$LFS/bin/busybox" "$initramfs_dir/bin/" 2>/dev/null || true
    cp -a "$LFS/bin/bash" "$initramfs_dir/bin/" 2>/dev/null || true
    cp -a "$LFS/bin/sh" "$initramfs_dir/bin/" 2>/dev/null || true
    cp -a "$LFS/sbin/switch_root" "$initramfs_dir/sbin/" 2>/dev/null || true
    cp -a "$LFS/bin/mount" "$initramfs_dir/bin/" 2>/dev/null || true
    cp -a "$LFS/bin/umount" "$initramfs_dir/bin/" 2>/dev/null || true

    # Copy required libraries
    for lib in ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libpthread.so.0 libm.so.6; do
        if [ -f "$LFS/lib64/$lib" ]; then
            cp -a "$LFS/lib64/$lib" "$initramfs_dir/lib64/" 2>/dev/null || true
        elif [ -f "$LFS/lib/$lib" ]; then
            cp -a "$LFS/lib/$lib" "$initramfs_dir/lib/" 2>/dev/null || true
        fi
    done

    # Copy additional required libs
    cp -a "$LFS"/lib/x86_64-linux-gnu/*.so* "$initramfs_dir/lib/" 2>/dev/null || true
    cp -a "$LFS"/usr/lib/*.so* "$initramfs_dir/usr/lib/" 2>/dev/null || true

    # Create init script for initramfs
    cat > "$initramfs_dir/init" << 'INITEOF'
#!/bin/sh
# Minimal init for ISO boot

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "Rookery OS 1.0 - Friendly Society of Corvids"
echo "Searching for root filesystem..."

# Try to find and mount the squashfs or the disk image
# For now, drop to shell for manual boot
echo ""
echo "ISO boot environment ready."
echo "To continue booting, mount your root filesystem to /newroot"
echo "and exec switch_root /newroot /sbin/init"
echo ""

exec /bin/sh
INITEOF
    chmod +x "$initramfs_dir/init"

    # Create initramfs cpio archive
    (cd "$initramfs_dir" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$iso_boot/initrd.img")
    log_info "Created initramfs for ISO"

    # Include the disk image in the ISO for full system installation
    log_step "Including disk image in ISO..."
    mkdir -p "$iso_root/images"
    local img_file="$DIST_DIR/${IMAGE_NAME}.img"
    if [ -f "$img_file" ]; then
        # Compress and include the disk image
        gzip -c "$img_file" > "$iso_root/images/${IMAGE_NAME}.img.gz"
        log_info "Included compressed disk image in ISO"
    elif [ -f "${img_file}.gz" ]; then
        cp "${img_file}.gz" "$iso_root/images/"
        log_info "Included compressed disk image in ISO"
    fi

    # Create GRUB configuration for ISO
    log_step "Creating GRUB configuration for ISO..."
    cat > "$iso_boot/grub/grub.cfg" << 'EOF'
# GRUB configuration for Rookery OS 1.0 ISO
# A custom Linux distribution for the Friendly Society of Corvids

set default=0
set timeout=10
set timeout_style=menu

# Serial console support
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

insmod all_video
insmod gfxterm

menuentry "Rookery OS 1.0 (Live Environment)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 (Install to Disk)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rookery_install=1
    initrd /boot/initrd.img
}

menuentry "Boot from first hard disk" {
    set root=(hd0)
    chainloader +1
}
EOF

    # Create the ISO using xorriso (supports both BIOS and UEFI)
    log_step "Building hybrid ISO image..."

    # First, we need to create the El Torito boot image for BIOS
    # Use grub-mkrescue approach or manual xorriso

    # Check if grub-mkrescue is available (preferred method)
    if command -v grub-mkrescue &>/dev/null; then
        log_info "Using grub-mkrescue for ISO creation..."

        # Create proper grub directory structure
        mkdir -p "$iso_root/boot/grub/i386-pc"

        # Copy GRUB modules if available
        if [ -d "/usr/lib/grub/i386-pc" ]; then
            cp -a /usr/lib/grub/i386-pc/* "$iso_root/boot/grub/i386-pc/" 2>/dev/null || true
        elif [ -d "$LFS/usr/lib/grub/i386-pc" ]; then
            cp -a "$LFS/usr/lib/grub/i386-pc/"* "$iso_root/boot/grub/i386-pc/" 2>/dev/null || true
        fi

        grub-mkrescue -o "$iso_file" "$iso_root" -- \
            -volid "ROOKERY_OS_1" \
            2>/dev/null || {
            log_warn "grub-mkrescue failed, trying xorriso directly..."
            # Fallback to xorriso
            create_iso_xorriso "$iso_file" "$iso_root"
        }
    else
        # Use xorriso directly
        create_iso_xorriso "$iso_file" "$iso_root"
    fi

    # Cleanup
    rm -rf "$iso_root" "$initramfs_dir"

    if [ -f "$iso_file" ]; then
        log_info "ISO image created: $iso_file"
        log_info "ISO size: $(du -h $iso_file | cut -f1)"
    else
        log_warn "ISO creation may have failed"
    fi
}

# Helper function to create ISO with xorriso directly
create_iso_xorriso() {
    local iso_file="$1"
    local iso_root="$2"

    log_info "Creating ISO with xorriso..."

    # Create a basic bootable ISO using xorriso
    # This creates a hybrid ISO bootable from CD/DVD and USB

    # First create the El Torito boot catalog
    mkdir -p "$iso_root/boot/grub"

    # Create embedded GRUB image for BIOS boot
    if command -v grub-mkimage &>/dev/null; then
        grub-mkimage -O i386-pc -o "$iso_root/boot/grub/core.img" \
            -p /boot/grub \
            biosdisk iso9660 part_msdos ext2 linux normal search \
            2>/dev/null || true
    fi

    # Create the ISO
    xorriso -as mkisofs \
        -r -J \
        -V "ROOKERY_OS_1" \
        -b boot/grub/core.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -isohybrid-mbr /usr/lib/grub/i386-pc/boot_hybrid.img 2>/dev/null \
        -o "$iso_file" \
        "$iso_root" 2>/dev/null || {

        # Simplest fallback - just create a data ISO with the image
        log_warn "Full bootable ISO creation failed, creating data ISO..."
        xorriso -as mkisofs \
            -r -J \
            -V "ROOKERY_OS_1" \
            -o "$iso_file" \
            "$iso_root" 2>/dev/null || log_warn "ISO creation failed"
    }
}

# Main
main() {
    log_info "=========================================="
    log_info "Rookery OS Package Image"
    log_info "=========================================="

    # Initialize checkpoint system
    init_checkpointing

    # Check if image already created
    if should_skip_global_checkpoint "image-${IMAGE_NAME}"; then
        log_info "Image ${IMAGE_NAME} already created - skipping"
        exit 0
    fi

    # Verify LFS system exists
    if [ ! -d "$LFS" ] || [ ! -f "$LFS/boot/vmlinuz" ]; then
        log_warn "LFS system incomplete!"
        log_warn "Boot kernel not found: $LFS/boot/vmlinuz"
    fi

    # Create output directory
    mkdir -p "$DIST_DIR"

    # Create disk image
    create_disk_image

    # Also create tarball for convenience
    create_tarball

    # Create bootable ISO
    create_iso

    # Create README
    cat > "$DIST_DIR/README.txt" << EOF
Rookery OS 1.0
A custom Linux distribution for the Friendly Society of Corvids
Generated: $(date)

Files:
- ${IMAGE_NAME}.img.gz: Bootable disk image (gzip compressed)
- ${IMAGE_NAME}.iso: Bootable ISO image (hybrid - works on CD/DVD and USB)
- ${IMAGE_NAME}.tar.gz: System tarball

Usage:

== Disk Image (Recommended for VMs) ==
1. Decompress the image:
   gunzip ${IMAGE_NAME}.img.gz

2. Boot with QEMU (serial console):
   qemu-system-x86_64 -m 2G -smp 2 \\
       -drive file=${IMAGE_NAME}.img,format=raw \\
       -boot c \\
       -nographic \\
       -serial mon:stdio

   Or with graphical display:
   qemu-system-x86_64 -m 2G -smp 2 -drive file=${IMAGE_NAME}.img,format=raw

3. Or write to USB drive:
   dd if=${IMAGE_NAME}.img of=/dev/sdX bs=4M status=progress
   (Replace /dev/sdX with your USB device)

== ISO Image (For CD/DVD or USB boot) ==
1. Boot with QEMU from ISO:
   qemu-system-x86_64 -m 2G -smp 2 \\
       -cdrom ${IMAGE_NAME}.iso \\
       -boot d \\
       -nographic \\
       -serial mon:stdio

2. Write to USB (hybrid ISO):
   dd if=${IMAGE_NAME}.iso of=/dev/sdX bs=4M status=progress

3. Burn to CD/DVD using your preferred burning software

   The ISO includes the compressed disk image in /images/ for installation.

== Tarball (For manual installation) ==
Extract tarball:
   tar -xzf ${IMAGE_NAME}.tar.gz -C /path/to/rootfs

System Info:
- Rookery OS Version: 1.0 (based on LFS 12.4)
- Init System: systemd
- Kernel: grsecurity-hardened ($(ls $LFS/boot/vmlinuz-* 2>/dev/null | head -1 | xargs basename || echo "Unknown"))
- Root Password: rookery (CHANGE AFTER FIRST LOGIN!)

Features:
- systemd init system with journald logging
- Grsecurity kernel hardening (desktop profile, VM guest)
- All hardware drivers as loadable modules
- Linux-firmware for hardware support
- systemd-networkd for network configuration

Default Network:
- Static IP: 10.0.2.15/24 (QEMU default)
- Gateway: 10.0.2.2
- DNS: 10.0.2.3, 8.8.8.8

Useful Commands:
- systemctl status              # Check system status
- journalctl -b                 # View boot log
- systemctl list-units --failed # Check failed units
- lsmod                         # List loaded kernel modules

Built with love for the Friendly Society of Corvids
Based on Linux From Scratch: https://www.linuxfromscratch.org
EOF

    log_info ""
    log_info "=========================================="
    log_info "Packaging Complete!"
    log_info "=========================================="
    log_info "Output directory: $DIST_DIR"
    log_info ""
    log_info "Files created:"
    ls -lh "$DIST_DIR"

    # Create global checkpoint
    # Use DIST_DIR as checkpoint location since image is the final output
    export CHECKPOINT_DIR="$DIST_DIR/.checkpoints"
    create_global_checkpoint "image-${IMAGE_NAME}" "package"

    exit 0
}

main "$@"
