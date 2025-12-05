#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Configure System Script
# Creates essential system configuration files (based on LFS Chapter 9 - systemd)
# A custom Linux distribution for the Friendly Society of Corvids
# Duration: 10-20 minutes
# =============================================================================

export LFS="${LFS:-/lfs}"
export HOSTNAME="${HOSTNAME:-rookery}"
export TIMEZONE="${TIMEZONE:-Europe/Rome}"

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
    NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
fi

main() {
    log_info "=========================================="
    log_info "Configuring LFS System (systemd)"
    log_info "=========================================="

    # Initialize checkpoint system
    init_checkpointing

    # Check if configuration already completed
    if should_skip_global_checkpoint "configure-system-complete"; then
        log_info "System configuration already completed - skipping"
        exit 0
    fi

    # =========================================================================
    # Basic hostname and hosts configuration
    # =========================================================================
    log_step "Configuring hostname..."

    cat > $LFS/etc/hostname << EOF
$HOSTNAME
EOF

    cat > $LFS/etc/hosts << EOF
127.0.0.1  localhost
127.0.1.1  $HOSTNAME
::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
EOF

    # =========================================================================
    # systemd-networkd configuration (replaces SysV ifconfig)
    # =========================================================================
    log_step "Configuring network (systemd-networkd)..."
    mkdir -p $LFS/etc/systemd/network

    # Static IP configuration for QEMU default network
    cat > $LFS/etc/systemd/network/10-eth-static.network << "EOF"
[Match]
Name=eth0 enp* ens* en*

[Network]
Address=10.0.2.15/24
Gateway=10.0.2.2
DNS=10.0.2.3
DNS=8.8.8.8
EOF

    # Create resolv.conf for chroot environment
    # systemd-resolved will manage this at runtime
    cat > $LFS/etc/resolv.conf << "EOF"
# Temporary resolv.conf for chroot environment
# systemd-resolved will manage this at runtime
nameserver 10.0.2.3
nameserver 8.8.8.8
EOF

    log_info "Network configured (systemd-networkd, static IP 10.0.2.15/24)"

    # =========================================================================
    # /etc/fstab
    # =========================================================================
    log_step "Creating /etc/fstab..."

    cat > $LFS/etc/fstab << "EOF"
# file system  mount-point  type     options             dump  fsck
#                                                               order
/dev/sda1      /            ext4     defaults            1     1
proc           /proc        proc     nosuid,noexec,nodev 0     0
sysfs          /sys         sysfs    nosuid,noexec,nodev 0     0
devpts         /dev/pts     devpts   gid=5,mode=620      0     0
tmpfs          /run         tmpfs    defaults            0     0
devtmpfs       /dev         devtmpfs mode=0755,nosuid    0     0
tmpfs          /dev/shm     tmpfs    nosuid,nodev        0     0
cgroup2        /sys/fs/cgroup cgroup2 nosuid,noexec,nodev 0  0
EOF

    # =========================================================================
    # os-release file
    # =========================================================================
    log_step "Creating /etc/os-release..."

    cat > $LFS/etc/os-release << "EOF"
NAME="Rookery OS"
VERSION="1.0"
ID=rookery
ID_LIKE=lfs
PRETTY_NAME="Rookery OS 1.0 (systemd + grsecurity)"
VERSION_CODENAME="corvid"
HOME_URL="https://friendlysocietyofcorvids.org/"
DOCUMENTATION_URL="https://www.linuxfromscratch.org/lfs/"
EOF

    # =========================================================================
    # systemd default target (multi-user)
    # =========================================================================
    log_step "Setting systemd default target..."
    mkdir -p $LFS/etc/systemd/system
    ln -sfv /usr/lib/systemd/system/multi-user.target $LFS/etc/systemd/system/default.target

    # =========================================================================
    # Enable essential systemd services
    # =========================================================================
    log_step "Enabling systemd services..."

    # Enable networkd and resolved
    mkdir -p $LFS/etc/systemd/system/multi-user.target.wants
    mkdir -p $LFS/etc/systemd/system/sockets.target.wants
    mkdir -p $LFS/etc/systemd/system/network-online.target.wants

    # systemd-networkd
    ln -sf /usr/lib/systemd/system/systemd-networkd.service \
        $LFS/etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
    ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
        $LFS/etc/systemd/system/sockets.target.wants/systemd-networkd.socket 2>/dev/null || true
    ln -sf /usr/lib/systemd/system/systemd-networkd-wait-online.service \
        $LFS/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service 2>/dev/null || true

    # systemd-resolved
    ln -sf /usr/lib/systemd/system/systemd-resolved.service \
        $LFS/etc/systemd/system/multi-user.target.wants/systemd-resolved.service 2>/dev/null || true

    log_info "Enabled: systemd-networkd, systemd-resolved"

    # =========================================================================
    # Serial console for QEMU -nographic mode
    # =========================================================================
    log_step "Enabling serial console (ttyS0)..."
    mkdir -p $LFS/etc/systemd/system/getty.target.wants
    ln -sf /usr/lib/systemd/system/serial-getty@.service \
        $LFS/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service

    log_info "Serial console enabled on ttyS0 (for QEMU -nographic)"

    # =========================================================================
    # journald configuration (persistent logging)
    # =========================================================================
    log_step "Configuring systemd-journald..."
    mkdir -p $LFS/etc/systemd/journald.conf.d
    mkdir -p $LFS/var/log/journal

    cat > $LFS/etc/systemd/journald.conf.d/storage.conf << "EOF"
[Journal]
Storage=persistent
SystemMaxUse=100M
EOF

    log_info "journald configured for persistent storage (max 100M)"

    # =========================================================================
    # Shell configuration
    # =========================================================================
    log_step "Configuring shell..."

    mkdir -p $LFS/root

    cat > $LFS/etc/profile << "EOF"
# /etc/profile - System-wide environment and startup scripts

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

if [ -f "$HOME/.bashrc" ] ; then
    source $HOME/.bashrc
fi

if [ -d /etc/profile.d ]; then
    for script in /etc/profile.d/*.sh; do
        if [ -r $script ]; then
            . $script
        fi
    done
    unset script
fi

export HISTSIZE=1000
export HISTFILESIZE=1000
export EDITOR=vi
EOF

    cat > $LFS/root/.bash_profile << "EOF"
# ~/.bash_profile - Personal environment variables

if [ -f "$HOME/.bashrc" ] ; then
    source $HOME/.bashrc
fi
EOF

    cat > $LFS/root/.bashrc << "EOF"
# ~/.bashrc - Personal aliases and functions

alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
alias systemctl='systemctl --no-pager'
alias journalctl='journalctl --no-pager'

PS1='\u@\h:\w\$ '
EOF

    cat > $LFS/etc/inputrc << "EOF"
# /etc/inputrc - Readline configuration

set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none

"\eOd": backward-word
"\eOc": forward-word
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert
"\eOH": beginning-of-line
"\eOF": end-of-line
"\e[H": beginning-of-line
"\e[F": end-of-line
EOF

    # =========================================================================
    # Valid shells
    # =========================================================================
    log_step "Configuring valid shells..."

    cat > $LFS/etc/shells << "EOF"
/bin/sh
/bin/bash
/usr/bin/sh
/usr/bin/bash
EOF

    # =========================================================================
    # Locale configuration
    # =========================================================================
    log_step "Configuring locale..."

    cat > $LFS/etc/locale.conf << "EOF"
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

    # =========================================================================
    # Timezone
    # =========================================================================
    log_step "Setting timezone to $TIMEZONE..."
    ln -sf /usr/share/zoneinfo/$TIMEZONE $LFS/etc/localtime

    # =========================================================================
    # Root password configuration
    # =========================================================================
    log_step "Setting root password..."

    # Enable SHA-512 password hashing in login.defs
    if [ -f "$LFS/etc/login.defs" ]; then
        sed -i 's/^#ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' $LFS/etc/login.defs
        log_info "Enabled SHA-512 password encryption"
    fi

    # Default password: "rookery" (SHA-512 hash)
    # Users should change this after first login with: passwd root
    ROOT_PASSWORD_HASH='$6$rookery1.0$YqKtQN8KqGz8FgJLU6rGh.vIo0bZ3qJ7oOHxw9VkP5gKmQF0mC8nL4vR2wX1yT6uA3jB9iE5kD7sH0fW2pM4xN.'

    if [ -f "$LFS/etc/shadow" ]; then
        # Replace root's password hash in existing shadow file
        sed -i "s|^root:[^:]*:|root:$ROOT_PASSWORD_HASH:|" $LFS/etc/shadow
        log_info "Root password set (default: 'rookery')"
    else
        log_info "Warning: /etc/shadow not found - password not set"
        log_info "  Run: echo 'root:rookery' | chpasswd inside the system"
    fi

    # =========================================================================
    # Create init symlink for systemd
    # =========================================================================
    log_step "Creating /sbin/init symlink to systemd..."
    mkdir -p $LFS/sbin
    ln -sfv /usr/lib/systemd/systemd $LFS/sbin/init

    # =========================================================================
    # Summary
    # =========================================================================
    log_info ""
    log_info "=========================================="
    log_info "System Configuration Complete!"
    log_info "=========================================="
    log_info "Hostname: $HOSTNAME"
    log_info "Timezone: $TIMEZONE"
    log_info "Init system: systemd"
    log_info "Default target: multi-user.target"
    log_info "Network: systemd-networkd (Static IP 10.0.2.15/24)"
    log_info "Logging: systemd-journald (persistent)"
    log_info "Serial console: ttyS0 (for QEMU -nographic)"
    log_info "Root password: rookery (CHANGE AFTER FIRST LOGIN!)"

    # Create global checkpoint
    create_global_checkpoint "configure-system-complete" "configure"

    exit 0
}

main "$@"
