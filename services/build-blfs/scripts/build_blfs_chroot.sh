#!/bin/bash
set -e

# =============================================================================
# EasyLFS BLFS Chroot Build Script
# Builds Beyond LFS packages inside the chroot environment
# =============================================================================

# Simple logging for chroot environment (no file logging - stdout only)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Load checkpointing (doesn't need file logging)
if [ -f /tmp/easylfs-common/checkpointing.sh ]; then
    source /tmp/easylfs-common/checkpointing.sh
fi

# Checkpointing for BLFS (always use these, simpler than LFS checkpointing)
should_skip_package() {
    local pkg="$1"
    [ -f "/.checkpoints/blfs-${pkg}.checkpoint" ]
}
create_checkpoint() {
    local pkg="$1"
    mkdir -p /.checkpoints
    echo "Built on $(date)" > "/.checkpoints/blfs-${pkg}.checkpoint"
    log_info "Checkpoint created for $pkg"
}

# Environment
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

# Build directory
BUILD_DIR="/build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log_info "=========================================="
log_info "BLFS Package Build - Chroot Environment"
log_info "=========================================="
log_info "Build directory: $BUILD_DIR"
log_info "MAKEFLAGS: $MAKEFLAGS"

# =====================================================================
# BLFS 4.1 Linux-PAM-1.7.1
# =====================================================================
should_skip_package "linux-pam" && { log_info "Skipping Linux-PAM (already built)"; } || {
log_step "Building Linux-PAM-1.7.1..."

# Check if source exists
if [ ! -f /sources/Linux-PAM-1.7.1.tar.xz ]; then
    log_error "Linux-PAM-1.7.1.tar.xz not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf Linux-PAM-*
tar -xf /sources/Linux-PAM-1.7.1.tar.xz
cd Linux-PAM-*

# Create build directory (meson build)
mkdir build
cd build

# Configure with meson
# Following BLFS 12.4 instructions exactly
meson setup ..            \
    --prefix=/usr         \
    --buildtype=release   \
    -D docdir=/usr/share/doc/Linux-PAM-1.7.1

# Build
ninja

# Create /etc/pam.d for tests (first-time installation)
log_info "Creating initial PAM configuration for tests..."
install -v -m755 -d /etc/pam.d

cat > /etc/pam.d/other << "EOF"
auth     required       pam_deny.so
account  required       pam_deny.so
password required       pam_deny.so
session  required       pam_deny.so
EOF

# Run tests (optional but recommended)
log_info "Running Linux-PAM tests..."
ninja test || log_warn "Some tests failed (may be expected without full PAM config)"

# Remove temporary test config
rm -fv /etc/pam.d/other

# Install
log_info "Installing Linux-PAM..."
ninja install

# Set SUID bit on unix_chkpwd (required for non-root password verification)
chmod -v 4755 /usr/sbin/unix_chkpwd

# Create PAM configuration files (BLFS recommended setup)
log_info "Creating PAM configuration files..."

install -vdm755 /etc/pam.d

# system-account
cat > /etc/pam.d/system-account << "EOF"
# Begin /etc/pam.d/system-account

account   required    pam_unix.so

# End /etc/pam.d/system-account
EOF

# system-auth
cat > /etc/pam.d/system-auth << "EOF"
# Begin /etc/pam.d/system-auth

auth      required    pam_unix.so

# End /etc/pam.d/system-auth
EOF

# system-session
cat > /etc/pam.d/system-session << "EOF"
# Begin /etc/pam.d/system-session

session   required    pam_unix.so

# End /etc/pam.d/system-session
EOF

# system-password
cat > /etc/pam.d/system-password << "EOF"
# Begin /etc/pam.d/system-password

# use yescrypt hash for encryption, use shadow, and try to use any
# previously defined authentication token (chosen password) set by any
# prior module.
password  required    pam_unix.so       yescrypt shadow try_first_pass

# End /etc/pam.d/system-password
EOF

# Restrictive /etc/pam.d/other (denies access for unconfigured apps)
cat > /etc/pam.d/other << "EOF"
# Begin /etc/pam.d/other

auth        required        pam_warn.so
auth        required        pam_deny.so
account     required        pam_warn.so
account     required        pam_deny.so
password    required        pam_warn.so
password    required        pam_deny.so
session     required        pam_warn.so
session     required        pam_deny.so

# End /etc/pam.d/other
EOF

# Clean up
cd "$BUILD_DIR"
rm -rf Linux-PAM-*

log_info "Linux-PAM-1.7.1 installed successfully"
create_checkpoint "linux-pam"
}

# =====================================================================
# BLFS 4.2 Shadow-4.18.0 (Rebuild with PAM support)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/shadow.html
# =====================================================================
should_skip_package "shadow-pam" && { log_info "Skipping Shadow rebuild (already built with PAM)"; } || {
log_step "Rebuilding Shadow-4.18.0 with PAM support..."

# Check if source exists
if [ ! -f /sources/shadow-4.18.0.tar.xz ]; then
    log_error "shadow-4.18.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf shadow-*
tar -xf /sources/shadow-4.18.0.tar.xz
cd shadow-*

# Apply BLFS modifications
# Remove groups program (Coreutils version preferred)
sed -i 's/groups$(EXEEXT) //' src/Makefile.in

# Remove conflicting man pages
find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;

# Configure login.defs for YESCRYPT and proper paths
sed -e 's@#ENCRYPT_METHOD DES@ENCRYPT_METHOD YESCRYPT@' \
    -e 's@/var/spool/mail@/var/mail@'                   \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                  \
    -i etc/login.defs

# Configure with PAM support
./configure --sysconfdir=/etc   \
            --disable-static    \
            --without-libbsd    \
            --with-{b,yes}crypt

# Build
make

# Install (pamddir= prevents installing shipped PAM configs)
log_info "Installing Shadow with PAM support..."
make exec_prefix=/usr pamddir= install

# Install man pages
make -C man install-man

# Configure /etc/login.defs for PAM (comment out functions now handled by PAM)
log_info "Configuring /etc/login.defs for PAM..."
install -v -m644 /etc/login.defs /etc/login.defs.orig
for FUNCTION in FAIL_DELAY               \
                FAILLOG_ENAB             \
                LASTLOG_ENAB             \
                MAIL_CHECK_ENAB          \
                OBSCURE_CHECKS_ENAB      \
                PORTTIME_CHECKS_ENAB     \
                QUOTAS_ENAB              \
                CONSOLE MOTD_FILE        \
                FTMP_FILE NOLOGINS_FILE  \
                ENV_HZ PASS_MIN_LEN      \
                SU_WHEEL_ONLY            \
                PASS_CHANGE_TRIES        \
                PASS_ALWAYS_WARN         \
                CHFN_AUTH ENCRYPT_METHOD \
                ENVIRON_FILE
do
    sed -i "s/^${FUNCTION}/# &/" /etc/login.defs
done

# Create PAM configuration files for Shadow utilities
log_info "Creating PAM configuration files for Shadow..."

# login
cat > /etc/pam.d/login << "EOF"
# Begin /etc/pam.d/login

# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that the user is allowed to login
auth      requisite   pam_nologin.so

# Check to make sure that root is allowed to login
# Disabled by default. You will need to create /etc/securetty
# file for this module to function. See man 5 securetty.
#auth      required    pam_securetty.so

# Additional group memberships - disabled by default
#auth      optional    pam_group.so

# include system auth settings
auth      include     system-auth

# check access for the user
account   required    pam_access.so

# include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# Display the message of the day - Disabled by default
#session   optional    pam_motd.so

# Check user's mail - Disabled by default
#session   optional    pam_mail.so      standard quiet

# include system session and password settings
session   include     system-session
password  include     system-password

# End /etc/pam.d/login
EOF

# passwd
cat > /etc/pam.d/passwd << "EOF"
# Begin /etc/pam.d/passwd

password  include     system-password

# End /etc/pam.d/passwd
EOF

# su
cat > /etc/pam.d/su << "EOF"
# Begin /etc/pam.d/su

# always allow root
auth      sufficient  pam_rootok.so

# Allow users in the wheel group to execute su without a password
# disabled by default
#auth      sufficient  pam_wheel.so trust use_uid

# include system auth settings
auth      include     system-auth

# limit su to users in the wheel group
# disabled by default
#auth      required    pam_wheel.so use_uid

# include system account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session settings
session   include     system-session

# End /etc/pam.d/su
EOF

# chpasswd and newusers
cat > /etc/pam.d/chpasswd << "EOF"
# Begin /etc/pam.d/chpasswd

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account
password  include     system-password

# End /etc/pam.d/chpasswd
EOF
sed -e s/chpasswd/newusers/ /etc/pam.d/chpasswd > /etc/pam.d/newusers

# chage
cat > /etc/pam.d/chage << "EOF"
# Begin /etc/pam.d/chage

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account

# End /etc/pam.d/chage
EOF

# Other shadow utilities (chfn, chgpasswd, chsh, groupadd, etc.)
for PROGRAM in chfn chgpasswd chsh groupadd groupdel \
               groupmems groupmod useradd userdel usermod
do
    install -v -m644 /etc/pam.d/chage /etc/pam.d/${PROGRAM}
    sed -i "s/chage/$PROGRAM/" /etc/pam.d/${PROGRAM}
done

# Rename /etc/login.access if it exists
if [ -f /etc/login.access ]; then
    mv -v /etc/login.access /etc/login.access.NOUSE
fi

# Rename /etc/limits if it exists
if [ -f /etc/limits ]; then
    mv -v /etc/limits /etc/limits.NOUSE
fi

# Clean up
cd "$BUILD_DIR"
rm -rf shadow-*

log_info "Shadow-4.18.0 rebuilt with PAM support"
create_checkpoint "shadow-pam"
}

# =====================================================================
# BLFS 12.1 Systemd-257.8 (Rebuild with PAM support)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/systemd.html
# =====================================================================
should_skip_package "systemd-pam" && { log_info "Skipping systemd rebuild (already built with PAM)"; } || {
log_step "Rebuilding systemd-257.8 with PAM support..."

# Check if source exists
if [ ! -f /sources/systemd-257.8.tar.gz ]; then
    log_error "systemd-257.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf systemd-*
tar -xf /sources/systemd-257.8.tar.gz
cd systemd-*

# Remove unneeded groups from udev rules (BLFS modification)
sed -i -e 's/GROUP="render"/GROUP="video"/' \
       -e 's/GROUP="sgx", //' rules.d/50-udev-default.rules.in

# Create build directory
mkdir build
cd build

# Configure with PAM support enabled
# Following BLFS 12.4 instructions exactly
meson setup ..                 \
      --prefix=/usr            \
      --buildtype=release      \
      -D default-dnssec=no     \
      -D firstboot=false       \
      -D install-tests=false   \
      -D ldconfig=false        \
      -D man=auto              \
      -D sysusers=false        \
      -D rpmmacrosdir=no       \
      -D homed=disabled        \
      -D userdb=false          \
      -D mode=release          \
      -D pam=enabled           \
      -D pamconfdir=/etc/pam.d \
      -D dev-kvm-mode=0660     \
      -D nobody-group=nogroup  \
      -D sysupdate=disabled    \
      -D ukify=disabled        \
      -D docdir=/usr/share/doc/systemd-257.8

# Build
ninja

# Install using DESTDIR to avoid post-install scripts that fail in chroot
# (systemd-hwdb update, journalctl --update-catalog, etc. require running system)
log_info "Installing systemd with PAM support..."
DESTDIR=/tmp/systemd-install ninja install

# Copy installed files to root filesystem
log_info "Copying systemd files to filesystem..."
cp -a /tmp/systemd-install/* /

# Update hwdb and catalog manually (these may fail in chroot but that's OK)
/usr/bin/systemd-hwdb update 2>/dev/null || log_warn "hwdb update skipped (will run on first boot)"
/usr/bin/journalctl --update-catalog 2>/dev/null || log_warn "catalog update skipped (will run on first boot)"

# Clean up temp install
rm -rf /tmp/systemd-install

# Configure PAM for systemd-logind
log_info "Configuring PAM for systemd-logind..."

# Add systemd session support to system-session
grep 'pam_systemd' /etc/pam.d/system-session || \
cat >> /etc/pam.d/system-session << "EOF"
# Begin Systemd addition

session  required    pam_loginuid.so
session  optional    pam_systemd.so

# End Systemd addition
EOF

# Create systemd-user PAM config
cat > /etc/pam.d/systemd-user << "EOF"
# Begin /etc/pam.d/systemd-user

account  required    pam_access.so
account  include     system-account

session  required    pam_env.so
session  required    pam_limits.so
session  required    pam_loginuid.so
session  optional    pam_keyinit.so force revoke
session  optional    pam_systemd.so

auth     required    pam_deny.so
password required    pam_deny.so

# End /etc/pam.d/systemd-user
EOF

# Clean up
cd "$BUILD_DIR"
rm -rf systemd-*

log_info "systemd-257.8 rebuilt with PAM support"
create_checkpoint "systemd-pam"
}

# =====================================================================
# BLFS 9.2 libgpg-error-1.55
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libgpg-error.html
# Required by: libgcrypt (and subsequently by many GNOME/KDE components)
# =====================================================================
should_skip_package "libgpg-error" && { log_info "Skipping libgpg-error (already built)"; } || {
log_step "Building libgpg-error-1.55..."

# Check if source exists
if [ ! -f /sources/libgpg-error-1.55.tar.bz2 ]; then
    log_error "libgpg-error-1.55.tar.bz2 not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libgpg-error-*
tar -xf /sources/libgpg-error-1.55.tar.bz2
cd libgpg-error-*

# Configure
./configure --prefix=/usr

# Build
make

# Run tests (optional but recommended)
log_info "Running libgpg-error tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing libgpg-error..."
make install

# Install documentation
install -v -m644 -D README /usr/share/doc/libgpg-error-1.55/README

# Clean up
cd "$BUILD_DIR"
rm -rf libgpg-error-*

log_info "libgpg-error-1.55 installed successfully"
create_checkpoint "libgpg-error"
}

# =====================================================================
# BLFS 9.1 libgcrypt-1.11.2
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libgcrypt.html
# Required by: many GNOME/KDE components, GnuPG, systemd-homed
# Depends on: libgpg-error
# =====================================================================
should_skip_package "libgcrypt" && { log_info "Skipping libgcrypt (already built)"; } || {
log_step "Building libgcrypt-1.11.2..."

# Check if source exists
if [ ! -f /sources/libgcrypt-1.11.2.tar.bz2 ]; then
    log_error "libgcrypt-1.11.2.tar.bz2 not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libgcrypt-*
tar -xf /sources/libgcrypt-1.11.2.tar.bz2
cd libgcrypt-*

# Configure
./configure --prefix=/usr

# Build
make

# Build documentation (optional - skip if texinfo not available)
if command -v makeinfo >/dev/null 2>&1; then
    log_info "Building libgcrypt documentation..."
    make -C doc html || log_warn "HTML docs failed (optional)"
    makeinfo --html --no-split -o doc/gcrypt_nochunks.html doc/gcrypt.texi 2>/dev/null || true
    makeinfo --plaintext -o doc/gcrypt.txt doc/gcrypt.texi 2>/dev/null || true
fi

# Run tests (optional but recommended)
log_info "Running libgcrypt tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing libgcrypt..."
make install

# Install documentation
install -v -dm755 /usr/share/doc/libgcrypt-1.11.2
install -v -m644 README doc/README.apichanges /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true

# Install HTML docs if they were built
if [ -d doc/gcrypt.html ]; then
    install -v -dm755 /usr/share/doc/libgcrypt-1.11.2/html
    install -v -m644 doc/gcrypt.html/* /usr/share/doc/libgcrypt-1.11.2/html/ 2>/dev/null || true
fi
if [ -f doc/gcrypt_nochunks.html ]; then
    install -v -m644 doc/gcrypt_nochunks.html /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true
fi
if [ -f doc/gcrypt.txt ]; then
    install -v -m644 doc/gcrypt.txt /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true
fi

# Clean up
cd "$BUILD_DIR"
rm -rf libgcrypt-*

log_info "libgcrypt-1.11.2 installed successfully"
create_checkpoint "libgcrypt"
}

# =====================================================================
# BLFS 4.4 Sudo-1.9.17p2
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/sudo.html
# Privilege escalation for authorized users
# Optional dependency: Linux-PAM (we have it installed)
# =====================================================================
should_skip_package "sudo" && { log_info "Skipping sudo (already built)"; } || {
log_step "Building sudo-1.9.17p2..."

# Check if source exists
if [ ! -f /sources/sudo-1.9.17p2.tar.gz ]; then
    log_error "sudo-1.9.17p2.tar.gz not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf sudo-*
tar -xf /sources/sudo-1.9.17p2.tar.gz
cd sudo-*

# Configure with PAM support (since we have Linux-PAM installed)
# Following BLFS 12.4 instructions exactly
./configure --prefix=/usr         \
            --libexecdir=/usr/lib \
            --with-secure-path    \
            --with-env-editor     \
            --docdir=/usr/share/doc/sudo-1.9.17p2 \
            --with-passprompt="[sudo] password for %p: "

# Build
make

# Run tests (optional)
log_info "Running sudo tests..."
env LC_ALL=C make check 2>&1 | tee make-check.log || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing sudo..."
make install

# Create sudoers.d directory
install -v -dm755 /etc/sudoers.d

# Create default sudo configuration for wheel group
log_info "Creating default sudo configuration..."
cat > /etc/sudoers.d/00-sudo << "EOF"
# Allow wheel group members to execute any command
Defaults secure_path="/usr/sbin:/usr/bin"
%wheel ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/00-sudo

# Create PAM configuration for sudo (since we have Linux-PAM)
log_info "Creating PAM configuration for sudo..."
cat > /etc/pam.d/sudo << "EOF"
# Begin /etc/pam.d/sudo

# include the default auth settings
auth      include     system-auth

# include the default account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session defaults
session   include     system-session

# End /etc/pam.d/sudo
EOF
chmod 644 /etc/pam.d/sudo

# Clean up
cd "$BUILD_DIR"
rm -rf sudo-*

log_info "sudo-1.9.17p2 installed successfully"
create_checkpoint "sudo"
}

# =====================================================================
# BLFS 9.6 PCRE2-10.45
# https://www.linuxfromscratch.org/blfs/view/12.4/general/pcre2.html
# Perl Compatible Regular Expressions - required by GLib
# =====================================================================
should_skip_package "pcre2" && { log_info "Skipping pcre2 (already built)"; } || {
log_step "Building pcre2-10.45..."

if [ ! -f /sources/pcre2-10.45.tar.bz2 ]; then
    log_error "pcre2-10.45.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf pcre2-*
tar -xf /sources/pcre2-10.45.tar.bz2
cd pcre2-*

# Configure with full Unicode support and JIT compilation
./configure --prefix=/usr                       \
            --docdir=/usr/share/doc/pcre2-10.45 \
            --enable-unicode                    \
            --enable-jit                        \
            --enable-pcre2-16                   \
            --enable-pcre2-32                   \
            --enable-pcre2grep-libz             \
            --enable-pcre2grep-libbz2           \
            --enable-pcre2test-libreadline      \
            --disable-static

make

# Run tests
log_info "Running pcre2 tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing pcre2..."
make install

cd "$BUILD_DIR"
rm -rf pcre2-*

log_info "pcre2-10.45 installed successfully"
create_checkpoint "pcre2"
}

# =====================================================================
# BLFS 9.3 duktape-2.7.0
# https://www.linuxfromscratch.org/blfs/view/12.4/general/duktape.html
# Embeddable JavaScript engine - required by polkit
# =====================================================================
should_skip_package "duktape" && { log_info "Skipping duktape (already built)"; } || {
log_step "Building duktape-2.7.0..."

if [ ! -f /sources/duktape-2.7.0.tar.xz ]; then
    log_error "duktape-2.7.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf duktape-*
tar -xf /sources/duktape-2.7.0.tar.xz
cd duktape-*

# Use -O2 instead of -Os for better performance
sed -i 's/-Os/-O2/' Makefile.sharedlibrary

# Build
make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr

# Install
log_info "Installing duktape..."
make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr install

cd "$BUILD_DIR"
rm -rf duktape-*

log_info "duktape-2.7.0 installed successfully"
create_checkpoint "duktape"
}

# =====================================================================
# BLFS 9.4 GLib-2.84.4
# https://www.linuxfromscratch.org/blfs/view/12.4/general/glib2.html
# Low-level core library for GNOME - required by polkit
# =====================================================================
should_skip_package "glib2" && { log_info "Skipping glib2 (already built)"; } || {
log_step "Building glib-2.84.4..."

if [ ! -f /sources/glib-2.84.4.tar.xz ]; then
    log_error "glib-2.84.4.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf glib-*
tar -xf /sources/glib-2.84.4.tar.xz
cd glib-*

# Create build directory
mkdir build
cd build

# Configure without introspection first (will be added later if needed)
# Disable sysprof to avoid downloading it, disable tests to avoid build issues
meson setup ..                  \
      --prefix=/usr             \
      --buildtype=release       \
      -D introspection=disabled \
      -D glib_debug=disabled    \
      -D man-pages=disabled     \
      -D sysprof=disabled       \
      -D tests=false

# Install first - this builds and installs the core libraries
# glib-compile-resources needs libgio installed before tests can be built
ninja install

# Update library cache
ldconfig

cd "$BUILD_DIR"
rm -rf glib-*

log_info "glib-2.84.4 installed successfully"
create_checkpoint "glib2"
}

# =====================================================================
# BLFS 4.5 Polkit-126
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/polkit.html
# Authorization toolkit for controlling system-wide privileges
# Depends on: duktape, glib2, Linux-PAM (we have all of these)
# =====================================================================
should_skip_package "polkit" && { log_info "Skipping polkit (already built)"; } || {
log_step "Building polkit-126..."

if [ ! -f /sources/polkit-126.tar.gz ]; then
    log_error "polkit-126.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf polkit-*
tar -xf /sources/polkit-126.tar.gz
cd polkit-*

# Create polkitd user and group
log_info "Creating polkitd user and group..."
groupadd -fg 27 polkitd 2>/dev/null || true
useradd -c "PolicyKit Daemon Owner" -d /etc/polkit-1 -u 27 \
        -g polkitd -s /bin/false polkitd 2>/dev/null || true

# Create build directory
mkdir build
cd build

# Configure with PAM and systemd-logind session tracking
# Disable man pages (requires libxslt/docbook)
# Use os_type=lfs since we don't have /etc/lfs-release
meson setup ..                   \
      --prefix=/usr              \
      --buildtype=release        \
      -D man=false               \
      -D session_tracking=logind \
      -D os_type=lfs             \
      -D introspection=false     \
      -D tests=false

# Build
ninja

# Install
log_info "Installing polkit..."
ninja install

cd "$BUILD_DIR"
rm -rf polkit-*

log_info "polkit-126 installed successfully"
create_checkpoint "polkit"
}

# =====================================================================
# Summary
# =====================================================================
log_info ""
log_info "=========================================="
log_info "BLFS Build Complete!"
log_info "=========================================="
log_info ""
log_info "Installed packages:"

# List installed BLFS packages
for checkpoint in /.checkpoints/blfs-*.checkpoint; do
    if [ -f "$checkpoint" ]; then
        pkg=$(basename "$checkpoint" .checkpoint | sed 's/^blfs-//')
        log_info "  - $pkg"
    fi
done

log_info ""
log_info "PAM integration complete:"
log_info "  - Linux-PAM provides pluggable authentication"
log_info "  - Shadow rebuilt with PAM support (login, su, passwd, etc.)"
log_info "  - systemd rebuilt with PAM support (systemd-logind, pam_systemd.so)"
log_info ""
log_info "Cryptography libraries installed:"
log_info "  - libgpg-error: GnuPG error library"
log_info "  - libgcrypt: General purpose cryptography library"
log_info ""
log_info "Security utilities installed:"
log_info "  - sudo: Privilege escalation for authorized users (wheel group)"
log_info "  - polkit: Authorization for system-wide privileges"
log_info ""
log_info "Core libraries installed:"
log_info "  - pcre2: Perl Compatible Regular Expressions"
log_info "  - duktape: Embeddable JavaScript engine"
log_info "  - glib2: Low-level core library for GNOME"
log_info "=========================================="

exit 0
