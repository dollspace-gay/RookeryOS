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
rm -rf build && mkdir build
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
rm -rf build && mkdir build
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
# BLFS 9.x ICU-77.1 (International Components for Unicode)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/icu.html
# Recommended for libxml2, required for proper Unicode support
# =====================================================================
should_skip_package "icu" && { log_info "Skipping ICU (already built)"; } || {
log_step "Building ICU-77.1..."

if [ ! -f /sources/icu4c-77_1-src.tgz ]; then
    log_error "icu4c-77_1-src.tgz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf icu
tar -xf /sources/icu4c-77_1-src.tgz
cd icu/source

./configure --prefix=/usr

make

log_info "Installing ICU..."
make install

cd "$BUILD_DIR"
rm -rf icu

log_info "ICU-77.1 installed successfully"
create_checkpoint "icu"
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
# BLFS 9.4 GLib-2.84.4 + GObject Introspection-1.84.0
# https://www.linuxfromscratch.org/blfs/view/12.4/general/glib2.html
# Low-level core library for GNOME - required by polkit
#
# This follows the BLFS approach of building gobject-introspection
# as a subdirectory within glib's build, which avoids library path
# issues that occur when building g-i as a standalone package.
# =====================================================================
should_skip_package "glib2-introspection" && { log_info "Skipping glib2 with introspection (already built)"; } || {
log_step "Building glib-2.84.4 with GObject Introspection (BLFS method)..."

if [ ! -f /sources/glib-2.84.4.tar.xz ]; then
    log_error "glib-2.84.4.tar.xz not found in /sources"
    exit 1
fi

if [ ! -f /sources/gobject-introspection-1.84.0.tar.xz ]; then
    log_error "gobject-introspection-1.84.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf glib-*
tar -xf /sources/glib-2.84.4.tar.xz
cd glib-*

# Create build directory
mkdir build
cd build

# Step 1: Configure glib WITHOUT introspection first
log_info "Step 1: Configuring glib without introspection..."
meson setup ..                  \
      --prefix=/usr             \
      --buildtype=release       \
      -D introspection=disabled \
      -D glib_debug=disabled    \
      -D man-pages=disabled     \
      -D sysprof=disabled       \
      -D tests=false

# Step 2: Build and install glib (needed before g-i can build)
log_info "Step 2: Building and installing glib..."
ninja
ninja install
ldconfig

# Step 3: Extract gobject-introspection INSIDE the glib build directory
# This is the key BLFS technique - g-i is built as a subdirectory
log_info "Step 3: Extracting gobject-introspection inside glib build..."
tar xf /sources/gobject-introspection-1.84.0.tar.xz

# Step 4: Configure gobject-introspection as a subdirectory
log_info "Step 4: Configuring gobject-introspection..."
meson setup gobject-introspection-1.84.0 gi-build \
            --prefix=/usr --buildtype=release

# Step 4a: Build the library first
log_info "Step 4a: Building libgirepository-1.0..."
ninja -C gi-build girepository/libgirepository-1.0.so.1.0.0

# Step 4b: Install libgirepository-1.0 to system before running tools
log_info "Step 4b: Installing libgirepository-1.0 to /usr/lib..."
cp gi-build/girepository/libgirepository-1.0.so.1.0.0 /usr/lib/
ln -sf libgirepository-1.0.so.1.0.0 /usr/lib/libgirepository-1.0.so.1
ln -sf libgirepository-1.0.so.1 /usr/lib/libgirepository-1.0.so
ldconfig

# Step 4c: Complete the build (g-ir-compiler will now find the library)
log_info "Step 4c: Completing gobject-introspection build..."
ninja -C gi-build

# Step 5: Install gobject-introspection
log_info "Step 5: Installing gobject-introspection..."
ninja -C gi-build install
ldconfig

# Step 6: Re-enable introspection in glib and rebuild
log_info "Step 6: Rebuilding glib with introspection enabled..."
meson configure -D introspection=enabled
ninja

# Step 7: Install glib with introspection data
log_info "Step 7: Installing glib with introspection data..."
ninja install
ldconfig

cd "$BUILD_DIR"
rm -rf glib-*

log_info "glib-2.84.4 with gobject-introspection-1.84.0 installed successfully"
create_checkpoint "glib2-introspection"
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
rm -rf build && mkdir build
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
# CMake-4.1.0 (build system - required by c-ares, libproxy, etc.)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/cmake.html
# Uses bootstrap (no cmake required to build)
# =====================================================================
should_skip_package "cmake" && { log_info "Skipping cmake (already built)"; } || {
log_step "Building cmake-4.1.0..."

if [ ! -f /sources/cmake-4.1.0.tar.gz ]; then
    log_error "cmake-4.1.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"

# Clean any previous cmake build attempt
rm -rf cmake-*

tar -xf /sources/cmake-4.1.0.tar.gz
cd cmake-4.1.0

# Fix lib64 path
sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake

# Bootstrap and build CMake
# Using bundled versions for all optional dependencies to minimize build issues
# --no-system-form disables curses form library requirement
./bootstrap --prefix=/usr        \
            --mandir=/share/man  \
            --no-system-jsoncpp  \
            --no-system-cppdap   \
            --no-system-librhash \
            --no-system-curl     \
            --no-system-libarchive \
            --no-system-libuv    \
            --no-system-nghttp2  \
            --no-qt-gui          \
            --docdir=/share/doc/cmake-4.1.0 \
            --parallel=4         \
            -- -DCMAKE_USE_OPENSSL=ON -DBUILD_CursesDialog=OFF

make

# Install
log_info "Installing cmake..."
make install

cd "$BUILD_DIR"
rm -rf cmake-*

log_info "cmake-4.1.0 installed successfully"
create_checkpoint "cmake"
}

# #####################################################################
# TIER 2: NETWORKING & PROTOCOLS
# #####################################################################

# =====================================================================
# libmnl-1.0.5 (Netfilter minimalistic library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libmnl.html
# Required by: iptables
# =====================================================================
should_skip_package "libmnl" && { log_info "Skipping libmnl (already built)"; } || {
log_step "Building libmnl-1.0.5..."

if [ ! -f /sources/libmnl-1.0.5.tar.bz2 ]; then
    log_error "libmnl-1.0.5.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libmnl-*
tar -xf /sources/libmnl-1.0.5.tar.bz2
cd libmnl-*

./configure --prefix=/usr

make

log_info "Installing libmnl..."
make install

cd "$BUILD_DIR"
rm -rf libmnl-*

log_info "libmnl-1.0.5 installed successfully"
create_checkpoint "libmnl"
}

# =====================================================================
# libevent-2.1.12 (Event notification library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libevent.html
# =====================================================================
should_skip_package "libevent" && { log_info "Skipping libevent (already built)"; } || {
log_step "Building libevent-2.1.12..."

if [ ! -f /sources/libevent-2.1.12-stable.tar.gz ]; then
    log_error "libevent-2.1.12-stable.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libevent-*
tar -xf /sources/libevent-2.1.12-stable.tar.gz
cd libevent-*

# Disable building of doxygen docs
sed -i 's/python/python3/' event_rpcgen.py

./configure --prefix=/usr --disable-static

make

log_info "Installing libevent..."
make install

cd "$BUILD_DIR"
rm -rf libevent-*

log_info "libevent-2.1.12 installed successfully"
create_checkpoint "libevent"
}

# =====================================================================
# c-ares-1.34.5 (Async DNS resolver)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/c-ares.html
# Required by: curl (optional)
# =====================================================================
should_skip_package "c-ares" && { log_info "Skipping c-ares (already built)"; } || {
log_step "Building c-ares-1.34.5..."

if [ ! -f /sources/c-ares-1.34.5.tar.gz ]; then
    log_error "c-ares-1.34.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf c-ares-*
tar -xf /sources/c-ares-1.34.5.tar.gz
cd c-ares-*

rm -rf build && mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release  \
      ..

make

log_info "Installing c-ares..."
make install

cd "$BUILD_DIR"
rm -rf c-ares-*

log_info "c-ares-1.34.5 installed successfully"
create_checkpoint "c-ares"
}

# =====================================================================
# libdaemon-0.14 (Unix daemon library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libdaemon.html
# Required by: avahi
# =====================================================================
should_skip_package "libdaemon" && { log_info "Skipping libdaemon (already built)"; } || {
log_step "Building libdaemon-0.14..."

if [ ! -f /sources/libdaemon-0.14.tar.gz ]; then
    log_error "libdaemon-0.14.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libdaemon-*
tar -xf /sources/libdaemon-0.14.tar.gz
cd libdaemon-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libdaemon..."
make install

cd "$BUILD_DIR"
rm -rf libdaemon-*

log_info "libdaemon-0.14 installed successfully"
create_checkpoint "libdaemon"
}

# =====================================================================
# Avahi-0.8 (mDNS/DNS-SD service discovery)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/avahi.html
# Depends on: glib2, libdaemon (we have both)
# =====================================================================
should_skip_package "avahi" && { log_info "Skipping Avahi (already built)"; } || {
log_step "Building Avahi-0.8..."

if [ ! -f /sources/avahi-0.8.tar.gz ]; then
    log_error "avahi-0.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf avahi-*
tar -xf /sources/avahi-0.8.tar.gz
cd avahi-*

# Create avahi user and group
groupadd -fg 84 avahi 2>/dev/null || true
useradd -c "Avahi Daemon Owner" -d /run/avahi-daemon -u 84 \
        -g avahi -s /bin/false avahi 2>/dev/null || true

# Create netdev group for privileged access (may already exist from NetworkManager)
groupadd -fg 86 netdev 2>/dev/null || true

# Apply IPv6 race condition fix patch
if [ -f /sources/avahi-0.8-ipv6_race_condition_fix-1.patch ]; then
    log_info "Applying IPv6 race condition fix patch..."
    patch -Np1 -i /sources/avahi-0.8-ipv6_race_condition_fix-1.patch
fi

# Fix security vulnerability in avahi-daemon
sed -i '426a if (events & AVAHI_WATCH_HUP) { \
client_free(c); \
return; \
}' avahi-daemon/simple-protocol.c

# Configure - disable GTK (we don't have it yet), enable libevent (we have it)
./configure \
    --prefix=/usr        \
    --sysconfdir=/etc    \
    --localstatedir=/var \
    --disable-static     \
    --disable-mono       \
    --disable-monodoc    \
    --disable-python     \
    --disable-qt3        \
    --disable-qt4        \
    --disable-qt5        \
    --disable-gtk        \
    --disable-gtk3       \
    --enable-core-docs   \
    --with-distro=none   \
    --with-dbus-system-address='unix:path=/run/dbus/system_bus_socket'

make

log_info "Installing Avahi..."
make install

# Enable systemd services
systemctl enable avahi-daemon 2>/dev/null || true

cd "$BUILD_DIR"
rm -rf avahi-*

log_info "Avahi-0.8 installed successfully"
create_checkpoint "avahi"
}

# =====================================================================
# libpcap-1.10.5 (Packet capture library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libpcap.html
# =====================================================================
should_skip_package "libpcap" && { log_info "Skipping libpcap (already built)"; } || {
log_step "Building libpcap-1.10.5..."

if [ ! -f /sources/libpcap-1.10.5.tar.gz ]; then
    log_error "libpcap-1.10.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libpcap-*
tar -xf /sources/libpcap-1.10.5.tar.gz
cd libpcap-*

./configure --prefix=/usr

make

log_info "Installing libpcap..."
make install

cd "$BUILD_DIR"
rm -rf libpcap-*

log_info "libpcap-1.10.5 installed successfully"
create_checkpoint "libpcap"
}

# =====================================================================
# libunistring-1.3 (Unicode string library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libunistring.html
# Required by: libidn2
# =====================================================================
should_skip_package "libunistring" && { log_info "Skipping libunistring (already built)"; } || {
log_step "Building libunistring-1.3..."

if [ ! -f /sources/libunistring-1.3.tar.xz ]; then
    log_error "libunistring-1.3.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libunistring-*
tar -xf /sources/libunistring-1.3.tar.xz
cd libunistring-*

./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/libunistring-1.3

make

log_info "Installing libunistring..."
make install

cd "$BUILD_DIR"
rm -rf libunistring-*

log_info "libunistring-1.3 installed successfully"
create_checkpoint "libunistring"
}

# =====================================================================
# libnl-3.11.0 (Netlink library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libnl.html
# Required by: wpa_supplicant, NetworkManager
# =====================================================================
should_skip_package "libnl" && { log_info "Skipping libnl (already built)"; } || {
log_step "Building libnl-3.11.0..."

if [ ! -f /sources/libnl-3.11.0.tar.gz ]; then
    log_error "libnl-3.11.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libnl-*
tar -xf /sources/libnl-3.11.0.tar.gz
cd libnl-*

./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-static

make

log_info "Installing libnl..."
make install

cd "$BUILD_DIR"
rm -rf libnl-*

log_info "libnl-3.11.0 installed successfully"
create_checkpoint "libnl"
}

# =====================================================================
# libxml2-2.14.5 (XML parser library - required by libxslt)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libxml2.html
# =====================================================================
should_skip_package "libxml2" && { log_info "Skipping libxml2 (already built)"; } || {
log_step "Building libxml2-2.14.5..."

if [ ! -f /sources/libxml2-2.14.5.tar.xz ]; then
    log_error "libxml2-2.14.5.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libxml2-*
tar -xf /sources/libxml2-2.14.5.tar.xz
cd libxml2-*

# Build with ICU for proper Unicode support (per BLFS 12.4 recommendation)
./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-static  \
            --with-history    \
            --with-icu        \
            PYTHON=/usr/bin/python3 \
            --docdir=/usr/share/doc/libxml2-2.14.5

make

log_info "Installing libxml2..."
make install

# Remove .la file and fix xml2-config to prevent unnecessary ICU linking
rm -vf /usr/lib/libxml2.la
sed '/libs=/s/xml2.*/xml2"/' -i /usr/bin/xml2-config

cd "$BUILD_DIR"
rm -rf libxml2-*

log_info "libxml2-2.14.5 installed successfully"
create_checkpoint "libxml2"
}

# =====================================================================
# libxslt-1.1.43 (XSLT processor)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libxslt.html
# =====================================================================
should_skip_package "libxslt" && { log_info "Skipping libxslt (already built)"; } || {
log_step "Building libxslt-1.1.43..."

if [ ! -f /sources/libxslt-1.1.43.tar.xz ]; then
    log_error "libxslt-1.1.43.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libxslt-*
tar -xf /sources/libxslt-1.1.43.tar.xz
cd libxslt-*

./configure --prefix=/usr                          \
            --disable-static                       \
            --docdir=/usr/share/doc/libxslt-1.1.43 \
            PYTHON=/usr/bin/python3

make

log_info "Installing libxslt..."
make install

cd "$BUILD_DIR"
rm -rf libxslt-*

log_info "libxslt-1.1.43 installed successfully"
create_checkpoint "libxslt"
}

# =====================================================================
# dhcpcd-10.2.4 (DHCP client)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/dhcpcd.html
# =====================================================================
should_skip_package "dhcpcd" && { log_info "Skipping dhcpcd (already built)"; } || {
log_step "Building dhcpcd-10.2.4..."

if [ ! -f /sources/dhcpcd-10.2.4.tar.xz ]; then
    log_error "dhcpcd-10.2.4.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf dhcpcd-*
tar -xf /sources/dhcpcd-10.2.4.tar.xz
cd dhcpcd-*

# Create dhcpcd user
groupadd -g 52 dhcpcd 2>/dev/null || true
useradd -c "dhcpcd Privilege Separation" -g dhcpcd -s /bin/false \
        -u 52 dhcpcd 2>/dev/null || true

./configure --prefix=/usr                \
            --sysconfdir=/etc            \
            --libexecdir=/usr/lib/dhcpcd \
            --dbdir=/var/lib/dhcpcd      \
            --runstatedir=/run           \
            --privsepuser=dhcpcd

make

log_info "Installing dhcpcd..."
make install

cd "$BUILD_DIR"
rm -rf dhcpcd-*

log_info "dhcpcd-10.2.4 installed successfully"
create_checkpoint "dhcpcd"
}

# =====================================================================
# libtasn1-4.20.0 (ASN.1 library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libtasn1.html
# Required by: p11-kit, GnuTLS
# =====================================================================
should_skip_package "libtasn1" && { log_info "Skipping libtasn1 (already built)"; } || {
log_step "Building libtasn1-4.20.0..."

if [ ! -f /sources/libtasn1-4.20.0.tar.gz ]; then
    log_error "libtasn1-4.20.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libtasn1-*
tar -xf /sources/libtasn1-4.20.0.tar.gz
cd libtasn1-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libtasn1..."
make install

cd "$BUILD_DIR"
rm -rf libtasn1-*

log_info "libtasn1-4.20.0 installed successfully"
create_checkpoint "libtasn1"
}

# =====================================================================
# nettle-3.10.2 (Crypto library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/nettle.html
# Required by: GnuTLS
# =====================================================================
should_skip_package "nettle" && { log_info "Skipping nettle (already built)"; } || {
log_step "Building nettle-3.10.2..."

if [ ! -f /sources/nettle-3.10.2.tar.gz ]; then
    log_error "nettle-3.10.2.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf nettle-*
tar -xf /sources/nettle-3.10.2.tar.gz
cd nettle-*

./configure --prefix=/usr --disable-static

make

log_info "Installing nettle..."
make install
chmod -v 755 /usr/lib/lib{hogweed,nettle}.so

cd "$BUILD_DIR"
rm -rf nettle-*

log_info "nettle-3.10.2 installed successfully"
create_checkpoint "nettle"
}

# =====================================================================
# make-ca-1.16.1 (CA certificates management)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/make-ca.html
# Required by: GnuTLS, OpenSSL for proper TLS verification
# =====================================================================
should_skip_package "make-ca" && { log_info "Skipping make-ca (already built)"; } || {
log_step "Installing make-ca-1.16.1..."

if [ ! -f /sources/make-ca-1.16.1.tar.gz ]; then
    log_error "make-ca-1.16.1.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf make-ca-*
tar -xf /sources/make-ca-1.16.1.tar.gz
cd make-ca-*

make install
install -vdm755 /etc/ssl/local

log_info "Running make-ca to install CA certificates..."
/usr/sbin/make-ca -g || log_warn "make-ca -g failed (may need network access)"

cd "$BUILD_DIR"
rm -rf make-ca-*

log_info "make-ca-1.16.1 installed successfully"
create_checkpoint "make-ca"
}

# =====================================================================
# p11-kit-0.25.5 (PKCS#11 library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/p11-kit.html
# Required by: GnuTLS
# Depends on: libtasn1
# =====================================================================
should_skip_package "p11-kit" && { log_info "Skipping p11-kit (already built)"; } || {
log_step "Building p11-kit-0.25.5..."

if [ ! -f /sources/p11-kit-0.25.5.tar.xz ]; then
    log_error "p11-kit-0.25.5.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf p11-kit-*
tar -xf /sources/p11-kit-0.25.5.tar.xz
cd p11-kit-*

# Prepare the distribution specific anchor hook (per BLFS 12.4)
sed '20,$ d' -i trust/trust-extract-compat

cat >> trust/trust-extract-compat << "EOF"
# Copy existing anchor modifications to /etc/ssl/local
/usr/libexec/make-ca/copy-trust-modifications

# Update trust stores
/usr/sbin/make-ca -r
EOF

rm -rf p11-build && mkdir p11-build
cd p11-build

meson setup ..            \
      --prefix=/usr       \
      --buildtype=release \
      -D trust_paths=/etc/pki/anchors

ninja

log_info "Installing p11-kit..."
ninja install

# Create symlink for SSL
ln -sfv /usr/libexec/p11-kit/trust-extract-compat \
        /usr/bin/update-ca-certificates

# Create libnssckbi.so symlink for NSS
ln -sfv ./pkcs11/p11-kit-trust.so /usr/lib/libnssckbi.so

cd "$BUILD_DIR"
rm -rf p11-kit-*

log_info "p11-kit-0.25.5 installed successfully"
create_checkpoint "p11-kit"
}

# =====================================================================
# GnuTLS-3.8.10 (TLS library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/gnutls.html
# Required by: wget (optional), NetworkManager (optional)
# Depends on: libtasn1, nettle, p11-kit
# =====================================================================
should_skip_package "gnutls" && { log_info "Skipping GnuTLS (already built)"; } || {
log_step "Building GnuTLS-3.8.10..."

if [ ! -f /sources/gnutls-3.8.10.tar.xz ]; then
    log_error "gnutls-3.8.10.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf gnutls-*
tar -xf /sources/gnutls-3.8.10.tar.xz
cd gnutls-*

./configure --prefix=/usr \
            --docdir=/usr/share/doc/gnutls-3.8.10 \
            --disable-guile \
            --disable-rpath \
            --with-default-trust-store-pkcs11="pkcs11:"

make

log_info "Installing GnuTLS..."
make install

cd "$BUILD_DIR"
rm -rf gnutls-*

log_info "GnuTLS-3.8.10 installed successfully"
create_checkpoint "gnutls"
}

# =====================================================================
# libidn2-2.3.8 (IDN library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libidn2.html
# Required by: libpsl, wget
# Depends on: libunistring
# =====================================================================
should_skip_package "libidn2" && { log_info "Skipping libidn2 (already built)"; } || {
log_step "Building libidn2-2.3.8..."

if [ ! -f /sources/libidn2-2.3.8.tar.gz ]; then
    log_error "libidn2-2.3.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libidn2-*
tar -xf /sources/libidn2-2.3.8.tar.gz
cd libidn2-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libidn2..."
make install

cd "$BUILD_DIR"
rm -rf libidn2-*

log_info "libidn2-2.3.8 installed successfully"
create_checkpoint "libidn2"
}

# =====================================================================
# libpsl-0.21.5 (Public Suffix List library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libpsl.html
# Required by: curl, wget
# Depends on: libidn2, libunistring
# =====================================================================
should_skip_package "libpsl" && { log_info "Skipping libpsl (already built)"; } || {
log_step "Building libpsl-0.21.5..."

if [ ! -f /sources/libpsl-0.21.5.tar.gz ]; then
    log_error "libpsl-0.21.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libpsl-*
tar -xf /sources/libpsl-0.21.5.tar.gz
cd libpsl-*

rm -rf build && mkdir build
cd build

meson setup --prefix=/usr --buildtype=release ..

ninja

log_info "Installing libpsl..."
ninja install

cd "$BUILD_DIR"
rm -rf libpsl-*

log_info "libpsl-0.21.5 installed successfully"
create_checkpoint "libpsl"
}

# =====================================================================
# iptables-1.8.11 (Firewall)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/iptables.html
# Required by: NetworkManager (optional)
# Depends on: libmnl
# =====================================================================
should_skip_package "iptables" && { log_info "Skipping iptables (already built)"; } || {
log_step "Building iptables-1.8.11..."

if [ ! -f /sources/iptables-1.8.11.tar.xz ]; then
    log_error "iptables-1.8.11.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf iptables-*
tar -xf /sources/iptables-1.8.11.tar.xz
cd iptables-*

./configure --prefix=/usr      \
            --disable-nftables \
            --enable-libipq

make

log_info "Installing iptables..."
make install

cd "$BUILD_DIR"
rm -rf iptables-*

log_info "iptables-1.8.11 installed successfully"
create_checkpoint "iptables"
}

# =====================================================================
# wpa_supplicant-2.11 (WiFi client)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/wpa_supplicant.html
# Depends on: libnl
# =====================================================================
should_skip_package "wpa_supplicant" && { log_info "Skipping wpa_supplicant (already built)"; } || {
log_step "Building wpa_supplicant-2.11..."

if [ ! -f /sources/wpa_supplicant-2.11.tar.gz ]; then
    log_error "wpa_supplicant-2.11.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf wpa_supplicant-*
tar -xf /sources/wpa_supplicant-2.11.tar.gz
cd wpa_supplicant-*/wpa_supplicant

# Create configuration file
cat > .config << "EOF"
CONFIG_BACKEND=file
CONFIG_CTRL_IFACE=y
CONFIG_DEBUG_FILE=y
CONFIG_DEBUG_SYSLOG=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_DRIVER_WIRED=y
CONFIG_EAP_GTC=y
CONFIG_EAP_LEAP=y
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_OTP=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TLS=y
CONFIG_EAP_TTLS=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_IPV6=y
CONFIG_LIBNL32=y
CONFIG_PEERKEY=y
CONFIG_PKCS12=y
CONFIG_READLINE=y
CONFIG_SMARTCARD=y
CONFIG_WPS=y
CFLAGS += -I/usr/include/libnl3
EOF

make BINDIR=/usr/sbin LIBDIR=/usr/lib

log_info "Installing wpa_supplicant..."
install -v -m755 wpa_{cli,passphrase,supplicant} /usr/sbin/

# Install systemd unit
install -v -m644 systemd/*.service /usr/lib/systemd/system/

cd "$BUILD_DIR"
rm -rf wpa_supplicant-*

log_info "wpa_supplicant-2.11 installed successfully"
create_checkpoint "wpa_supplicant"
}

# =====================================================================
# curl-8.15.0 (HTTP client library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/curl.html
# Required by: libproxy
# Depends on: c-ares (optional), libpsl
# =====================================================================
should_skip_package "curl" && { log_info "Skipping curl (already built)"; } || {
log_step "Building curl-8.15.0..."

if [ ! -f /sources/curl-8.15.0.tar.xz ]; then
    log_error "curl-8.15.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf curl-*
tar -xf /sources/curl-8.15.0.tar.xz
cd curl-*

./configure --prefix=/usr                           \
            --disable-static                        \
            --with-openssl                          \
            --enable-threaded-resolver              \
            --with-ca-path=/etc/ssl/certs

make

log_info "Installing curl..."
make install

cd "$BUILD_DIR"
rm -rf curl-*

log_info "curl-8.15.0 installed successfully"
create_checkpoint "curl"
}

# =====================================================================
# Vala-0.56.18 (Vala compiler)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/vala.html
# Required by: many GNOME applications, libproxy (optional)
# Depends on: GLib with GObject Introspection
# =====================================================================
should_skip_package "vala" && { log_info "Skipping Vala (already built)"; } || {
log_step "Building Vala-0.56.18..."

if [ ! -f /sources/vala-0.56.18.tar.xz ]; then
    log_error "vala-0.56.18.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf vala-*
tar -xf /sources/vala-0.56.18.tar.xz
cd vala-*

# Configure without valadoc (requires Graphviz which we don't have yet)
./configure --prefix=/usr --disable-valadoc

make

log_info "Installing Vala..."
make install

cd "$BUILD_DIR"
rm -rf vala-*

log_info "Vala-0.56.18 installed successfully"
create_checkpoint "vala"
}

# =====================================================================
# gsettings-desktop-schemas-48.0 (GNOME settings schemas)
# https://www.linuxfromscratch.org/blfs/view/12.4/gnome/gsettings-desktop-schemas.html
# Required for libproxy GNOME integration
# =====================================================================
should_skip_package "gsettings-desktop-schemas" && { log_info "Skipping gsettings-desktop-schemas (already built)"; } || {
log_step "Building gsettings-desktop-schemas-48.0..."

if [ ! -f /sources/gsettings-desktop-schemas-48.0.tar.xz ]; then
    log_error "gsettings-desktop-schemas-48.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf gsettings-desktop-schemas-*
tar -xf /sources/gsettings-desktop-schemas-48.0.tar.xz
cd gsettings-desktop-schemas-*

# Fix deprecated entries in schema templates (from BLFS)
sed -i -r 's:"(/system):"/org/gnome\1:g' schemas/*.in

rm -rf build && mkdir build
cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            ..

ninja

log_info "Installing gsettings-desktop-schemas..."
ninja install

# Compile schemas
glib-compile-schemas /usr/share/glib-2.0/schemas

cd "$BUILD_DIR"
rm -rf gsettings-desktop-schemas-*

log_info "gsettings-desktop-schemas-48.0 installed successfully"
create_checkpoint "gsettings-desktop-schemas"
}

# =====================================================================
# libproxy-0.5.10 (Proxy configuration library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libproxy.html
# Optional for wget
# =====================================================================
should_skip_package "libproxy" && { log_info "Skipping libproxy (already built)"; } || {
log_step "Building libproxy-0.5.10..."

if [ ! -f /sources/libproxy-0.5.10.tar.gz ]; then
    log_error "libproxy-0.5.10.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libproxy-*
tar -xf /sources/libproxy-0.5.10.tar.gz
cd libproxy-*

rm -rf build && mkdir build
cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            -D docs=false       \
            -D tests=false      \
            -D introspection=false ..

ninja

log_info "Installing libproxy..."
ninja install

cd "$BUILD_DIR"
rm -rf libproxy-*

log_info "libproxy-0.5.10 installed successfully"
create_checkpoint "libproxy"
}

# =====================================================================
# wget-1.25.0 (HTTP/FTP downloader)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/wget.html
# Depends on: libpsl (recommended), libidn2 (optional), libproxy (optional)
# =====================================================================
should_skip_package "wget" && { log_info "Skipping wget (already built)"; } || {
log_step "Building wget-1.25.0..."

if [ ! -f /sources/wget-1.25.0.tar.gz ]; then
    log_error "wget-1.25.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf wget-*
tar -xf /sources/wget-1.25.0.tar.gz
cd wget-*

./configure --prefix=/usr      \
            --sysconfdir=/etc  \
            --with-ssl=openssl \
            --enable-libproxy

make

log_info "Installing wget..."
make install

cd "$BUILD_DIR"
rm -rf wget-*

log_info "wget-1.25.0 installed successfully"
create_checkpoint "wget"
}

# =====================================================================
# libndp-1.9 (Neighbor Discovery Protocol library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libndp.html
# Required by: NetworkManager
# =====================================================================
should_skip_package "libndp" && { log_info "Skipping libndp (already built)"; } || {
log_step "Building libndp-1.9..."

if [ ! -f /sources/libndp-1.9.tar.gz ]; then
    log_error "libndp-1.9.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libndp-*
tar -xf /sources/libndp-1.9.tar.gz
cd libndp-*

# libndp from github needs autoreconf
autoreconf -fiv

./configure --prefix=/usr        \
            --sysconfdir=/etc    \
            --localstatedir=/var \
            --disable-static

make

log_info "Installing libndp..."
make install

cd "$BUILD_DIR"
rm -rf libndp-*

log_info "libndp-1.9 installed successfully"
create_checkpoint "libndp"
}

# =====================================================================
# NetworkManager-1.54.0 (Network management)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/networkmanager.html
# Depends on: curl, dhcpcd, libndp, libnl, libpsl, polkit, wpa_supplicant
# =====================================================================
should_skip_package "networkmanager" && { log_info "Skipping NetworkManager (already built)"; } || {
log_step "Building NetworkManager-1.54.0..."

if [ ! -f /sources/NetworkManager-1.54.0.tar.xz ]; then
    log_error "NetworkManager-1.54.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf NetworkManager-*
tar -xf /sources/NetworkManager-1.54.0.tar.xz
cd NetworkManager-*

# Create networkmanager group
groupadd -fg 86 netdev 2>/dev/null || true

rm -rf build && mkdir build
cd build

# Following BLFS configuration exactly
meson setup ..                        \
      --prefix=/usr                   \
      --buildtype=release             \
      -D libaudit=no                  \
      -D nmtui=false                  \
      -D ovs=false                    \
      -D ppp=false                    \
      -D nbft=false                   \
      -D selinux=false                \
      -D qt=false                     \
      -D session_tracking=systemd     \
      -D nm_cloud_setup=false         \
      -D modem_manager=false          \
      -D crypto=gnutls                \
      -D introspection=false          \
      -D docs=false

ninja

log_info "Installing NetworkManager..."
ninja install

# Create /etc/NetworkManager
install -vdm755 /etc/NetworkManager

# Create basic configuration
cat > /etc/NetworkManager/NetworkManager.conf << "EOF"
[main]
plugins=keyfile
EOF

cd "$BUILD_DIR"
rm -rf NetworkManager-*

log_info "NetworkManager-1.54.0 installed successfully"
create_checkpoint "networkmanager"
}

# #####################################################################
# TIER 3: Graphics Foundation (X11/Wayland)
# #####################################################################

# =====================================================================
# Xorg Build Environment Setup
# =====================================================================
setup_xorg_env() {
    log_step "Setting up Xorg build environment"

    # Set XORG_PREFIX - using /usr for system integration
    export XORG_PREFIX="/usr"
    export XORG_CONFIG="--prefix=$XORG_PREFIX --sysconfdir=/etc \
        --localstatedir=/var --disable-static"

    # Create font directories
    mkdir -pv /usr/share/fonts/{X11-OTF,X11-TTF}

    log_info "Xorg environment configured with XORG_PREFIX=$XORG_PREFIX"
}

# =====================================================================
# util-macros-1.20.2 (Xorg build macros)
# =====================================================================
build_util_macros() {
    should_skip_package "util-macros" && { log_info "util-macros already built, skipping..."; return 0; }

    log_step "Building util-macros-1.20.2"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/util-macros-1.20.2.tar.xz
    cd util-macros-1.20.2

    ./configure $XORG_CONFIG

    make install

    cd "$BUILD_DIR"
    rm -rf util-macros-1.20.2

    log_info "util-macros-1.20.2 installed successfully"
    create_checkpoint "util-macros"
}

# =====================================================================
# xorgproto-2024.1 (Xorg protocol headers)
# =====================================================================
build_xorgproto() {
    should_skip_package "xorgproto" && { log_info "xorgproto already built, skipping..."; return 0; }

    log_step "Building xorgproto-2024.1"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/xorgproto-2024.1.tar.xz
    cd xorgproto-2024.1

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX ..

    ninja install

    cd "$BUILD_DIR"
    rm -rf xorgproto-2024.1

    log_info "xorgproto-2024.1 installed successfully"
    create_checkpoint "xorgproto"
}

# =====================================================================
# Wayland-1.24.0 (Wayland compositor protocol)
# =====================================================================
build_wayland() {
    should_skip_package "wayland" && { log_info "wayland already built, skipping..."; return 0; }

    log_step "Building Wayland-1.24.0"
    cd "$BUILD_DIR"

    tar -xf /sources/wayland-1.24.0.tar.xz
    cd wayland-1.24.0

    mkdir build && cd build

    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D documentation=false

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf wayland-1.24.0

    log_info "Wayland-1.24.0 installed successfully"
    create_checkpoint "wayland"
}

# =====================================================================
# Wayland-Protocols-1.45
# =====================================================================
build_wayland_protocols() {
    if should_skip_package "wayland-protocols"; then
        log_info "wayland-protocols already built, skipping..."
        return 0
    fi

    log_step "Building Wayland-Protocols-1.45"
    cd "$BUILD_DIR"

    tar -xf /sources/wayland-protocols-1.45.tar.xz
    cd wayland-protocols-1.45

    mkdir build && cd build

    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf wayland-protocols-1.45

    log_info "Wayland-Protocols-1.45 installed successfully"
    create_checkpoint "wayland-protocols"
}

# =====================================================================
# libXau-1.0.12 (X11 Authorization Library)
# =====================================================================
build_libXau() {
    if should_skip_package "libXau"; then
        log_info "libXau already built, skipping..."
        return 0
    fi

    log_step "Building libXau-1.0.12"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libXau-1.0.12.tar.xz
    cd libXau-1.0.12

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libXau-1.0.12

    log_info "libXau-1.0.12 installed successfully"
    create_checkpoint "libXau"
}

# =====================================================================
# libXdmcp-1.1.5 (X11 Display Manager Control Protocol Library)
# =====================================================================
build_libXdmcp() {
    if should_skip_package "libXdmcp"; then
        log_info "libXdmcp already built, skipping..."
        return 0
    fi

    log_step "Building libXdmcp-1.1.5"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libXdmcp-1.1.5.tar.xz
    cd libXdmcp-1.1.5

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libXdmcp-1.1.5

    log_info "libXdmcp-1.1.5 installed successfully"
    create_checkpoint "libXdmcp"
}

# =====================================================================
# xcb-proto-1.17.0 (XCB Protocol Descriptions)
# =====================================================================
build_xcb_proto() {
    if should_skip_package "xcb-proto"; then
        log_info "xcb-proto already built, skipping..."
        return 0
    fi

    log_step "Building xcb-proto-1.17.0"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/xcb-proto-1.17.0.tar.xz
    cd xcb-proto-1.17.0

    PYTHON=python3 ./configure $XORG_CONFIG

    make install

    # Remove old pkgconfig file if exists
    rm -f $XORG_PREFIX/lib/pkgconfig/xcb-proto.pc

    cd "$BUILD_DIR"
    rm -rf xcb-proto-1.17.0

    log_info "xcb-proto-1.17.0 installed successfully"
    create_checkpoint "xcb-proto"
}

# =====================================================================
# libxcb-1.17.0 (X C Binding Library)
# =====================================================================
build_libxcb() {
    if should_skip_package "libxcb"; then
        log_info "libxcb already built, skipping..."
        return 0
    fi

    log_step "Building libxcb-1.17.0"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libxcb-1.17.0.tar.xz
    cd libxcb-1.17.0

    ./configure $XORG_CONFIG    \
        --without-doxygen

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libxcb-1.17.0

    log_info "libxcb-1.17.0 installed successfully"
    create_checkpoint "libxcb"
}

# =====================================================================
# Pixman-0.46.4 (Low-level pixel manipulation library)
# =====================================================================
build_pixman() {
    if should_skip_package "pixman"; then
        log_info "pixman already built, skipping..."
        return 0
    fi

    log_step "Building Pixman-0.46.4"
    cd "$BUILD_DIR"

    tar -xf /sources/pixman-0.46.4.tar.gz
    cd pixman-0.46.4

    mkdir build && cd build

    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf pixman-0.46.4

    log_info "Pixman-0.46.4 installed successfully"
    create_checkpoint "pixman"
}

# =====================================================================
# libdrm-2.4.125 (Direct Rendering Manager Library)
# =====================================================================
build_libdrm() {
    if should_skip_package "libdrm"; then
        log_info "libdrm already built, skipping..."
        return 0
    fi

    log_step "Building libdrm-2.4.125"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libdrm-2.4.125.tar.xz
    cd libdrm-2.4.125

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX \
                --buildtype=release   \
                -D udev=true          \
                -D valgrind=disabled  ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libdrm-2.4.125

    log_info "libdrm-2.4.125 installed successfully"
    create_checkpoint "libdrm"
}

# =====================================================================
# libxcvt-0.1.3 (VESA CVT Standard Timing Modelines Generator)
# =====================================================================
build_libxcvt() {
    if should_skip_package "libxcvt"; then
        log_info "libxcvt already built, skipping..."
        return 0
    fi

    log_step "Building libxcvt-0.1.3"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libxcvt-0.1.3.tar.xz
    cd libxcvt-0.1.3

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libxcvt-0.1.3

    log_info "libxcvt-0.1.3 installed successfully"
    create_checkpoint "libxcvt"
}

# =====================================================================
# SPIRV-Headers-1.4.321.0 (SPIR-V Headers)
# =====================================================================
build_spirv_headers() {
    if should_skip_package "spirv-headers"; then
        log_info "spirv-headers already built, skipping..."
        return 0
    fi

    log_step "Building SPIRV-Headers-1.4.321.0"
    cd "$BUILD_DIR"

    tar -xf /sources/SPIRV-Headers-1.4.321.0.tar.gz
    cd SPIRV-Headers-vulkan-sdk-1.4.321.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf SPIRV-Headers-vulkan-sdk-1.4.321.0

    log_info "SPIRV-Headers-1.4.321.0 installed successfully"
    create_checkpoint "spirv-headers"
}

# =====================================================================
# SPIRV-Tools-1.4.321.0 (SPIR-V Tools)
# =====================================================================
build_spirv_tools() {
    if should_skip_package "spirv-tools"; then
        log_info "spirv-tools already built, skipping..."
        return 0
    fi

    log_step "Building SPIRV-Tools-1.4.321.0"
    cd "$BUILD_DIR"

    tar -xf /sources/SPIRV-Tools-1.4.321.0.tar.gz
    cd SPIRV-Tools-vulkan-sdk-1.4.321.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr     \
          -D CMAKE_BUILD_TYPE=Release      \
          -D SPIRV_WERROR=OFF              \
          -D BUILD_SHARED_LIBS=ON          \
          -D SPIRV_TOOLS_BUILD_STATIC=OFF  \
          -D SPIRV-Headers_SOURCE_DIR=/usr \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf SPIRV-Tools-vulkan-sdk-1.4.321.0

    log_info "SPIRV-Tools-1.4.321.0 installed successfully"
    create_checkpoint "spirv-tools"
}

# =====================================================================
# Vulkan-Headers-1.4.321 (Vulkan Header Files)
# =====================================================================
build_vulkan_headers() {
    if should_skip_package "vulkan-headers"; then
        log_info "vulkan-headers already built, skipping..."
        return 0
    fi

    log_step "Building Vulkan-Headers-1.4.321"
    cd "$BUILD_DIR"

    tar -xf /sources/Vulkan-Headers-1.4.321.tar.gz
    cd Vulkan-Headers-1.4.321

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf Vulkan-Headers-1.4.321

    log_info "Vulkan-Headers-1.4.321 installed successfully"
    create_checkpoint "vulkan-headers"
}

# =====================================================================
# glslang-15.4.0 (GLSL Shader Frontend)
# =====================================================================
build_glslang() {
    if should_skip_package "glslang"; then
        log_info "glslang already built, skipping..."
        return 0
    fi

    log_step "Building glslang-15.4.0"
    cd "$BUILD_DIR"

    tar -xf /sources/glslang-15.4.0.tar.gz
    cd glslang-15.4.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr     \
          -D CMAKE_BUILD_TYPE=Release      \
          -D ALLOW_EXTERNAL_SPIRV_TOOLS=ON \
          -D BUILD_SHARED_LIBS=ON          \
          -D GLSLANG_TESTS=OFF             \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf glslang-15.4.0

    log_info "glslang-15.4.0 installed successfully"
    create_checkpoint "glslang"
}

# =====================================================================
# Vulkan-Loader-1.4.321 (Vulkan ICD Loader)
# =====================================================================
build_vulkan_loader() {
    if should_skip_package "vulkan-loader"; then
        log_info "vulkan-loader already built, skipping..."
        return 0
    fi

    log_step "Building Vulkan-Loader-1.4.321"
    cd "$BUILD_DIR"

    tar -xf /sources/Vulkan-Loader-1.4.321.tar.gz
    cd Vulkan-Loader-1.4.321

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr       \
          -D CMAKE_BUILD_TYPE=Release        \
          -D CMAKE_SKIP_RPATH=ON             \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf Vulkan-Loader-1.4.321

    log_info "Vulkan-Loader-1.4.321 installed successfully"
    create_checkpoint "vulkan-loader"
}

# =====================================================================
# Xorg Libraries (32 packages) - BLFS Chapter 24
# =====================================================================
build_xorg_libraries() {
    if should_skip_package "xorg-libraries"; then
        log_info "xorg-libraries already built, skipping..."
        return 0
    fi

    log_step "Building Xorg Libraries (32 packages)"
    cd "$BUILD_DIR"
    setup_xorg_env

    # Package list in correct build order (from BLFS lib-7.md5)
    # Note: xtrans, libFS, libXpresent use .tar.gz from GitLab with different dir names
    local xorg_lib_packages=(
        "xtrans-1.6.0.tar.gz"
        "libX11-1.8.12.tar.xz"
        "libXext-1.3.6.tar.xz"
        "libFS-1.0.10.tar.gz"
        "libICE-1.1.2.tar.xz"
        "libSM-1.2.6.tar.xz"
        "libXScrnSaver-1.2.4.tar.xz"
        "libXt-1.3.1.tar.xz"
        "libXmu-1.2.1.tar.xz"
        "libXpm-3.5.17.tar.xz"
        "libXaw-1.0.16.tar.xz"
        "libXfixes-6.0.1.tar.xz"
        "libXcomposite-0.4.6.tar.xz"
        "libXrender-0.9.12.tar.xz"
        "libXcursor-1.2.3.tar.xz"
        "libXdamage-1.1.6.tar.xz"
        "libfontenc-1.1.8.tar.xz"
        "libXfont2-2.0.7.tar.xz"
        "libXft-2.3.9.tar.xz"
        "libXi-1.8.2.tar.xz"
        "libXinerama-1.1.5.tar.xz"
        "libXrandr-1.5.4.tar.xz"
        "libXres-1.2.2.tar.xz"
        "libXtst-1.2.5.tar.xz"
        "libXv-1.0.13.tar.xz"
        "libXvMC-1.0.14.tar.xz"
        "libXxf86dga-1.1.6.tar.xz"
        "libXxf86vm-1.1.6.tar.xz"
        "libpciaccess-0.18.1.tar.xz"
        "libxkbfile-1.1.3.tar.xz"
        "libxshmfence-1.3.3.tar.xz"
        "libXpresent-1.0.1.tar.gz"
    )

    local pkg_count=0
    local pkg_total=${#xorg_lib_packages[@]}

    for package in "${xorg_lib_packages[@]}"; do
        ((pkg_count++))
        # Strip extension to get base package name
        local packagedir="${package%.tar.*}"
        log_info "Building $packagedir ($pkg_count/$pkg_total)..."

        tar -xf /sources/$package

        # Handle GitLab tarballs which have different directory names
        # GitLab format: libxtrans-xtrans-1.6.0, libfs-libFS-1.0.10, etc.
        local actual_dir=""
        case $packagedir in
            xtrans-* )
                actual_dir="libxtrans-$packagedir"
                ;;
            libFS-* )
                actual_dir="libfs-$packagedir"
                ;;
            libXpresent-* )
                actual_dir="libxpresent-$packagedir"
                ;;
            * )
                actual_dir="$packagedir"
                ;;
        esac

        if [ ! -d "$actual_dir" ]; then
            log_error "Directory $actual_dir not found after extraction"
            ls -la
            exit 1
        fi

        pushd "$actual_dir" > /dev/null

        local docdir="--docdir=$XORG_PREFIX/share/doc/$packagedir"

        case $packagedir in
            xtrans-* )
                # xtrans from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for xtrans..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libFS-* )
                # libFS from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for libFS..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libXpresent-* )
                # libXpresent from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for libXpresent..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libXfont2-[0-9]* )
                ./configure $XORG_CONFIG $docdir --disable-devel-docs
                ;;

            libXt-[0-9]* )
                ./configure $XORG_CONFIG $docdir \
                            --with-appdefaultdir=/etc/X11/app-defaults
                ;;

            libXpm-[0-9]* )
                ./configure $XORG_CONFIG $docdir --disable-open-zfile
                ;;

            libpciaccess* )
                mkdir -p build
                cd build
                meson setup --prefix=$XORG_PREFIX --buildtype=release ..
                ninja
                ninja install
                popd > /dev/null
                rm -rf "$actual_dir"
                ldconfig
                continue
                ;;

            * )
                ./configure $XORG_CONFIG $docdir
                ;;
        esac

        make
        make install
        popd > /dev/null
        rm -rf "$actual_dir"
        ldconfig
    done

    log_info "Xorg Libraries - All 32 packages installed successfully"
    create_checkpoint "xorg-libraries"
}

# =====================================================================
# Build Tier 3 Foundation packages
# =====================================================================
log_info ""
log_info "#####################################################################"
log_info "# TIER 3: Graphics Foundation (X11/Wayland)"
log_info "#####################################################################"
log_info ""

# Setup Xorg environment
setup_xorg_env

# Build Xorg base packages (no dependencies)
build_util_macros
build_xorgproto

# Build Wayland (no Xorg dependencies)
build_wayland
build_wayland_protocols

# Build X11 protocol libraries
build_libXau
build_libXdmcp
build_xcb_proto
build_libxcb

# Build graphics libraries
build_pixman
build_libdrm
build_libxcvt

# Build Vulkan/SPIR-V stack (Phase 1 - before Xorg Libraries)
build_spirv_headers
build_spirv_tools
build_vulkan_headers
build_glslang

# Build Xorg Libraries (32 packages) - enables Vulkan-Loader
build_xorg_libraries

# Build Vulkan-Loader (now that libX11 is available)
build_vulkan_loader

log_info ""
log_info "Tier 3 Graphics Foundation (Phase 2) completed!"
log_info "  - Xorg Libraries: 32 packages (libX11, libXext, etc.)"
log_info "  - Vulkan-Loader: Now functional with X11 support"
log_info ""

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
log_info "Tier 1 - Security & Core:"
log_info "  - Linux-PAM: Pluggable authentication"
log_info "  - Shadow: Rebuilt with PAM support"
log_info "  - systemd: Rebuilt with PAM support"
log_info "  - libgpg-error, libgcrypt: Cryptography"
log_info "  - sudo, polkit: Privilege management"
log_info "  - pcre2, duktape, glib2: Core libraries"
log_info "  - cmake: Build system"
log_info ""
log_info "Tier 2 - Networking & Protocols:"
log_info "  - libmnl, libnl: Netlink libraries"
log_info "  - libevent, c-ares: Event/DNS libraries"
log_info "  - libtasn1, nettle, p11-kit, GnuTLS: TLS stack"
log_info "  - libunistring, libidn2, libpsl: Unicode/IDN"
log_info "  - iptables: Firewall"
log_info "  - dhcpcd: DHCP client"
log_info "  - wpa_supplicant: WiFi client"
log_info "  - curl, wget: HTTP clients"
log_info "  - libproxy: Proxy configuration"
log_info "  - NetworkManager: Network management"
log_info ""
log_info "Tier 3 - Graphics Foundation (X11/Wayland):"
log_info "  - util-macros, xorgproto: Xorg build infrastructure"
log_info "  - Wayland, Wayland-Protocols: Wayland compositor"
log_info "  - libXau, libXdmcp: X11 auth libraries"
log_info "  - xcb-proto, libxcb: XCB protocol"
log_info "  - Pixman: Pixel manipulation"
log_info "  - libdrm, libxcvt: DRM and CVT libraries"
log_info "  - SPIRV-Headers, SPIRV-Tools: SPIR-V support"
log_info "  - Vulkan-Headers, glslang: Vulkan/GLSL"
log_info "  - Xorg Libraries (32 packages): libX11, libXext, libXt, etc."
log_info "  - Vulkan-Loader: Vulkan ICD loader"
log_info "=========================================="

exit 0
