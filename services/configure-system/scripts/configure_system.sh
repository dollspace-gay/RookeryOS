#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Configure System Script
# Creates essential system configuration files (based on LFS Chapter 9 - systemd)
# A custom Linux distribution for the Friendly Society of Corvids
# Duration: 10-20 minutes
# =============================================================================

export ROOKERY="${ROOKERY:-/rookery}"
export HOSTNAME="${HOSTNAME:-rookery}"
export TIMEZONE="${TIMEZONE:-Europe/Rome}"

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load common utilities
COMMON_DIR="/usr/local/lib/rookery-common"
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
    log_info "Configuring Rookery OS System (systemd)"
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

    cat > $ROOKERY/etc/hostname << EOF
$HOSTNAME
EOF

    cat > $ROOKERY/etc/hosts << EOF
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
    mkdir -p $ROOKERY/etc/systemd/network

    # Static IP configuration for QEMU default network
    cat > $ROOKERY/etc/systemd/network/10-eth-static.network << "EOF"
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
    cat > $ROOKERY/etc/resolv.conf << "EOF"
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

    cat > $ROOKERY/etc/fstab << "EOF"
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

    cat > $ROOKERY/etc/os-release << "EOF"
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
    mkdir -p $ROOKERY/etc/systemd/system
    ln -sfv /usr/lib/systemd/system/multi-user.target $ROOKERY/etc/systemd/system/default.target

    # =========================================================================
    # Enable essential systemd services
    # =========================================================================
    log_step "Enabling systemd services..."

    # Enable networkd and resolved
    mkdir -p $ROOKERY/etc/systemd/system/multi-user.target.wants
    mkdir -p $ROOKERY/etc/systemd/system/sockets.target.wants
    mkdir -p $ROOKERY/etc/systemd/system/network-online.target.wants

    # systemd-networkd
    ln -sf /usr/lib/systemd/system/systemd-networkd.service \
        $ROOKERY/etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
    ln -sf /usr/lib/systemd/system/systemd-networkd.socket \
        $ROOKERY/etc/systemd/system/sockets.target.wants/systemd-networkd.socket 2>/dev/null || true
    ln -sf /usr/lib/systemd/system/systemd-networkd-wait-online.service \
        $ROOKERY/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service 2>/dev/null || true

    # systemd-resolved
    ln -sf /usr/lib/systemd/system/systemd-resolved.service \
        $ROOKERY/etc/systemd/system/multi-user.target.wants/systemd-resolved.service 2>/dev/null || true

    log_info "Enabled: systemd-networkd, systemd-resolved"

    # =========================================================================
    # Serial console for QEMU -nographic mode
    # =========================================================================
    log_step "Enabling serial console (ttyS0)..."
    mkdir -p $ROOKERY/etc/systemd/system/getty.target.wants
    ln -sf /usr/lib/systemd/system/serial-getty@.service \
        $ROOKERY/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service

    log_info "Serial console enabled on ttyS0 (for QEMU -nographic)"

    # =========================================================================
    # journald configuration (persistent logging)
    # =========================================================================
    log_step "Configuring systemd-journald..."
    mkdir -p $ROOKERY/etc/systemd/journald.conf.d
    mkdir -p $ROOKERY/var/log/journal

    cat > $ROOKERY/etc/systemd/journald.conf.d/storage.conf << "EOF"
[Journal]
Storage=persistent
SystemMaxUse=100M
EOF

    log_info "journald configured for persistent storage (max 100M)"

    # =========================================================================
    # Shell configuration
    # =========================================================================
    log_step "Configuring shell..."

    mkdir -p $ROOKERY/root

    cat > $ROOKERY/etc/profile << "EOF"
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

    cat > $ROOKERY/root/.bash_profile << "EOF"
# ~/.bash_profile - Personal environment variables

if [ -f "$HOME/.bashrc" ] ; then
    source $HOME/.bashrc
fi
EOF

    cat > $ROOKERY/root/.bashrc << "EOF"
# ~/.bashrc - Personal aliases and functions

alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
alias systemctl='systemctl --no-pager'
alias journalctl='journalctl --no-pager'

PS1='\u@\h:\w\$ '
EOF

    cat > $ROOKERY/etc/inputrc << "EOF"
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
    # Path helper functions (BLFS)
    # =========================================================================
    log_step "Creating path helper functions..."

    cat > $ROOKERY/etc/profile.d/00-pathfuncs.sh << 'EOF'
# Path manipulation functions from BLFS
pathappend() {
    if [ -d "$1" ] && [[ ":$PATH:" != *":$1:"* ]]; then
        PATH="${PATH:+$PATH:}$1"
    fi
}

pathprepend() {
    if [ -d "$1" ] && [[ ":$PATH:" != *":$1:"* ]]; then
        PATH="$1${PATH:+:$PATH}"
    fi
}

export -f pathappend pathprepend
EOF

    # =========================================================================
    # Valid shells
    # =========================================================================
    log_step "Configuring valid shells..."

    cat > $ROOKERY/etc/shells << "EOF"
/bin/sh
/bin/bash
/usr/bin/sh
/usr/bin/bash
EOF

    # =========================================================================
    # Locale configuration
    # =========================================================================
    log_step "Configuring locale..."

    cat > $ROOKERY/etc/locale.conf << "EOF"
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

    # =========================================================================
    # Timezone
    # =========================================================================
    log_step "Setting timezone to $TIMEZONE..."
    ln -sf /usr/share/zoneinfo/$TIMEZONE $ROOKERY/etc/localtime

    # =========================================================================
    # Root password configuration
    # =========================================================================
    log_step "Setting root password..."

    # Enable SHA-512 password hashing in login.defs
    if [ -f "$ROOKERY/etc/login.defs" ]; then
        sed -i 's/^#ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' $ROOKERY/etc/login.defs
        log_info "Enabled SHA-512 password encryption"
    fi

    # Default password: "rookery" (SHA-512 hash)
    # Users should change this after first login with: passwd root
    # Generated with: openssl passwd -6 'rookery'
    ROOT_PASSWORD_HASH='$6$QXaN15FVkQQxEKuN$3FWcNgAo2CrAOd/7aq58XHIufWyw/NcysZRcg8Jl9pi2vcAIxbOziV9Tv4FyG80Cl/LYt0hJt.zbVCD6LFw3l/'

    if [ -f "$ROOKERY/etc/shadow" ]; then
        # Replace root's password hash in existing shadow file
        sed -i "s|^root:[^:]*:|root:$ROOT_PASSWORD_HASH:|" $ROOKERY/etc/shadow
        log_info "Root password set (default: 'rookery')"
    else
        log_info "Warning: /etc/shadow not found - password not set"
        log_info "  Run: echo 'root:rookery' | chpasswd inside the system"
    fi

    # =========================================================================
    # Create non-root user 'rookery'
    # =========================================================================
    log_step "Creating user 'rookery'..."

    # Add rookery user (UID 1000, GID 1000)
    if ! grep -q "^rookery:" "$ROOKERY/etc/passwd" 2>/dev/null; then
        echo "rookery:x:1000:1000:Rookery User:/home/rookery:/bin/bash" >> $ROOKERY/etc/passwd
    fi

    # Add rookery group
    if ! grep -q "^rookery:" "$ROOKERY/etc/group" 2>/dev/null; then
        echo "rookery:x:1000:" >> $ROOKERY/etc/group
    fi

    # Add rookery to useful groups (wheel, audio, video, input, users)
    for grp in wheel audio video input users; do
        if grep -q "^${grp}:" "$ROOKERY/etc/group" 2>/dev/null; then
            if ! grep "^${grp}:" "$ROOKERY/etc/group" | grep -q "rookery"; then
                sed -i "s/^${grp}:\([^:]*\):\([^:]*\):$/&rookery/" $ROOKERY/etc/group
                sed -i "s/^${grp}:\([^:]*\):\([^:]*\):\([^,]\)/${grp}:\1:\2:\3,rookery/" $ROOKERY/etc/group
            fi
        fi
    done

    # Add rookery to shadow with same password as root
    if [ -f "$ROOKERY/etc/shadow" ]; then
        if ! grep -q "^rookery:" "$ROOKERY/etc/shadow" 2>/dev/null; then
            echo "rookery:$ROOT_PASSWORD_HASH:19500:0:99999:7:::" >> $ROOKERY/etc/shadow
        else
            sed -i "s|^rookery:[^:]*:|rookery:$ROOT_PASSWORD_HASH:|" $ROOKERY/etc/shadow
        fi
    fi

    # Create home directory with proper shell configs
    mkdir -p $ROOKERY/home/rookery
    cp $ROOKERY/root/.bash_profile $ROOKERY/home/rookery/.bash_profile
    cp $ROOKERY/root/.bashrc $ROOKERY/home/rookery/.bashrc
    chown -R 1000:1000 $ROOKERY/home/rookery

    log_info "User 'rookery' created (password: 'rookery')"

    # =========================================================================
    # Create init symlink for systemd
    # =========================================================================
    log_step "Creating /sbin/init symlink to systemd..."
    mkdir -p $ROOKERY/sbin
    ln -sfv /usr/lib/systemd/systemd $ROOKERY/sbin/init

    # =========================================================================
    # Fix ownership (UID 1000 from build container -> root)
    # =========================================================================
    log_step "Fixing file ownership..."

    # Fix root directory
    chown root:root $ROOKERY 2>/dev/null || true

    # Fix root-level directories and symlinks
    chown -h root:root $ROOKERY/bin $ROOKERY/lib $ROOKERY/sbin 2>/dev/null || true
    chown root:root $ROOKERY/lib64 $ROOKERY/home 2>/dev/null || true

    # Fix major trees recursively
    chown -R root:root $ROOKERY/usr $ROOKERY/etc $ROOKERY/var 2>/dev/null || true

    # Fix any remaining UID 1000 files (except rookery's home)
    find $ROOKERY -uid 1000 -not -path "$ROOKERY/home/rookery/*" -not -path "$ROOKERY/home/rookery" -exec chown root:root {} \; 2>/dev/null || true

    # Ensure rookery's home is properly owned
    chown -R 1000:1000 $ROOKERY/home/rookery 2>/dev/null || true

    log_info "Ownership fixed for system directories"

    # =========================================================================
    # WSL Configuration (for Windows Subsystem for Linux compatibility)
    # =========================================================================
    log_step "Adding WSL configuration files..."

    cat > $ROOKERY/etc/wsl.conf << 'EOF'
[boot]
systemd=true

[user]
default = rookery
EOF

    cat > $ROOKERY/etc/wsl-distribution.conf << 'EOF'
[oobe]
command = /usr/libexec/wsl/oobe.sh
defaultUid = 1000
defaultName = RookeryOS

[shortcut]
enabled = true
EOF

    mkdir -p $ROOKERY/usr/libexec/wsl
    cat > $ROOKERY/usr/libexec/wsl/oobe.sh << 'EOF'
#!/bin/bash
# RookeryOS WSL Out-of-Box Experience
# This script runs on first launch to set up the user environment

echo "Welcome to RookeryOS!"
echo "====================="
echo ""

# Check if rookery user already exists
if id "rookery" &>/dev/null; then
    echo "User 'rookery' is ready."
    echo "Default password is 'rookery' - please change it with: passwd"
else
    echo "Setting up user 'rookery'..."
    useradd -m -G wheel,audio,video -s /bin/bash rookery
    echo "rookery:rookery" | chpasswd
    echo "User 'rookery' created with password 'rookery'"
    echo "Please change your password with: passwd"
fi

echo ""
echo "Enjoy RookeryOS!"
EOF
    chmod 755 $ROOKERY/usr/libexec/wsl/oobe.sh

    log_info "WSL configuration files added"

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
