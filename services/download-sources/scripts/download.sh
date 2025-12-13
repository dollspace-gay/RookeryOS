#!/bin/bash
set -euo pipefail

# =============================================================================
# RookeryOS Download Sources Script
# Downloads all LFS and BLFS packages from Corvidae mirror
# =============================================================================

# Load common utilities
COMMON_DIR="/usr/local/lib/easylfs-common"
if [ -d "$COMMON_DIR" ]; then
    source "$COMMON_DIR/logging.sh"
    source "$COMMON_DIR/checkpointing.sh"
else
    # Fallback for development/local testing
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../../common/logging.sh"
    source "$SCRIPT_DIR/../../common/checkpointing.sh"
fi

# Configuration
SOURCES_DIR="/sources"
MAX_RETRIES=3
RETRY_DELAY=5
DOWNLOAD_TIMEOUT=120

# Corvidae Mirror - single source for all packages
MIRROR="http://corvidae.social/RookerySource"

# Note: LFS for download-sources points to /sources since we don't have /lfs yet
export LFS="${LFS:-/lfs}"

# Setup logging trap
trap 'finalize_logging $?' EXIT

# =============================================================================
# Download with retry
# =============================================================================
download_with_retry() {
    local filename="$1"
    local output="$SOURCES_DIR/$filename"
    local url="$MIRROR/$filename"
    local attempt=1

    # Skip if already exists
    if [ -f "$output" ]; then
        log_info "[SKIP] $filename (already exists)"
        return 0
    fi

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading $filename (attempt $attempt/$MAX_RETRIES)..."

        if wget --continue \
                --progress=dot:giga \
                --timeout=$DOWNLOAD_TIMEOUT \
                --read-timeout=60 \
                --dns-timeout=20 \
                --tries=2 \
                -O "$output" \
                "$url" 2>&1; then
            log_info "[OK] $filename"
            return 0
        fi

        log_warn "Download failed, retrying in $RETRY_DELAY seconds..."
        rm -f "$output"  # Remove partial download
        sleep $RETRY_DELAY
        ((attempt++))
    done

    log_error "FAILED: $filename after $MAX_RETRIES attempts"
    return 1
}

# =============================================================================
# Package Lists
# =============================================================================

# LFS Base System Packages (Chapter 5-8)
LFS_PACKAGES=(
    # Chapter 5-6: Cross-compilation toolchain
    "binutils-2.45.tar.xz"
    "gcc-15.2.0.tar.xz"
    # Note: Kernel not downloaded - using local grsec kernel (linux-6.6.102) via bind mount
    "glibc-2.42.tar.xz"
    "mpfr-4.2.2.tar.xz"
    "gmp-6.3.0.tar.xz"
    "mpc-1.3.1.tar.gz"

    # Chapter 7-8: Base system
    "m4-1.4.20.tar.xz"
    "ncurses-6.5-20250809.tgz"
    "bash-5.3.tar.gz"
    "coreutils-9.7.tar.xz"
    "diffutils-3.12.tar.xz"
    "file-5.46.tar.gz"
    "findutils-4.10.0.tar.xz"
    "gawk-5.3.2.tar.xz"
    "grep-3.12.tar.xz"
    "gzip-1.14.tar.xz"
    "make-4.4.1.tar.gz"
    "patch-2.8.tar.xz"
    "sed-4.9.tar.xz"
    "tar-1.35.tar.xz"
    "xz-5.8.1.tar.xz"
    "gettext-0.26.tar.xz"
    "bison-3.8.2.tar.xz"
    "perl-5.42.0.tar.xz"
    "Python-3.13.7.tar.xz"
    "texinfo-7.2.tar.xz"
    "util-linux-2.41.1.tar.xz"

    # Additional Chapter 8 packages
    "acl-2.3.2.tar.xz"
    "attr-2.5.2.tar.gz"
    "autoconf-2.72.tar.xz"
    "automake-1.18.1.tar.xz"
    "bc-7.0.3.tar.xz"
    "bzip2-1.0.8.tar.gz"
    "e2fsprogs-1.47.3.tar.gz"
    "elfutils-0.193.tar.bz2"
    "expat-2.7.1.tar.xz"
    "flex-2.6.4.tar.gz"
    "flit_core-3.12.0.tar.gz"
    "gdbm-1.26.tar.gz"
    "gperf-3.0.4.tar.gz"
    "groff-1.23.0.tar.gz"
    "grub-2.12.tar.xz"
    "iana-etc-20250807.tar.gz"
    "inetutils-2.6.tar.xz"
    "intltool-0.51.0.tar.gz"
    "iproute2-6.16.0.tar.xz"
    "jinja2-3.1.6.tar.gz"
    "kbd-2.8.0.tar.xz"
    "kmod-34.2.tar.xz"
    "less-679.tar.gz"
    "libcap-2.76.tar.xz"
    "libffi-3.5.2.tar.gz"
    "libpipeline-1.5.8.tar.gz"
    "libtool-2.5.4.tar.xz"
    "libxcrypt-4.4.38.tar.xz"
    "lz4-1.10.0.tar.gz"
    "man-db-2.13.1.tar.xz"
    "man-pages-6.15.tar.xz"
    "markupsafe-3.0.2.tar.gz"
    "meson-1.8.3.tar.gz"
    "nano-8.6.tar.xz"
    "ninja-1.13.1.tar.gz"
    "openssl-3.5.2.tar.gz"
    "packaging-24.2.tar.gz"
    "pkgconf-2.5.1.tar.xz"
    "procps-ng-4.0.5.tar.xz"
    "psmisc-23.7.tar.xz"
    "readline-8.3.tar.gz"
    "setuptools-80.9.0.tar.gz"
    "shadow-4.18.0.tar.xz"
    "sysklogd-2.7.2.tar.gz"
    "systemd-257.8.tar.gz"
    "tzdata2025b.tar.gz"
    "wheel-0.46.1.tar.gz"
    "XML-Parser-2.47.tar.gz"
    "zlib-1.3.1.tar.gz"
    "zstd-1.5.7.tar.gz"
    "dbus-1.16.2.tar.xz"
)

# LFS Patches
LFS_PATCHES=(
    "glibc-2.42-fhs-1.patch"
    "bzip2-1.0.8-install_docs-1.patch"
    "coreutils-9.7-i18n-1.patch"
    "kbd-2.8.0-backspace-1.patch"
    "sysvinit-3.14-consolidated-1.patch"
)

# BLFS Packages - Security & Authentication
BLFS_SECURITY=(
    "Linux-PAM-1.7.1.tar.xz"
    "Linux-PAM-1.7.1-docs.tar.xz"
    "shadow-4.18.0.tar.xz"
    "sudo-1.9.17p2.tar.gz"
    "polkit-126.tar.gz"
    "make-ca-1.16.1.tar.gz"
    "p11-kit-0.25.5.tar.xz"
    "libtasn1-4.20.0.tar.gz"
    "nss-3.115.tar.gz"
    "nspr-4.37.tar.gz"
)

# BLFS Packages - GnuPG PQC Stack (Post-Quantum Cryptography)
BLFS_GNUPG=(
    "libgpg-error-1.58.tar.bz2"
    "libgcrypt-1.11.2.tar.bz2"
    "libassuan-3.0.2.tar.bz2"
    "libksba-1.6.7.tar.bz2"
    "npth-1.8.tar.bz2"
    "pinentry-1.3.2.tar.bz2"
    "gnupg-2.5.14.tar.bz2"
    "gpgme-2.0.0.tar.bz2"
)

# BLFS Packages - Networking
BLFS_NETWORKING=(
    "curl-8.15.0.tar.xz"
    "wget-1.25.0.tar.gz"
    "libevent-2.1.12-stable.tar.gz"
    "nghttp2-1.67.0.tar.xz"
    "c-ares-1.34.5.tar.gz"
    "avahi-0.8.tar.gz"
    "bluez-5.83.tar.xz"
    "dhcpcd-10.2.4.tar.xz"
    "wpa_supplicant-2.11.tar.gz"
    "iw-6.9.tar.xz"
    "wireless-regdb-2025.07.10.tar.xz"
)

# BLFS Packages - Libraries
BLFS_LIBRARIES=(
    "boost-1.89.0-b2-nodocs.tar.xz"
    "icu-78.1-src.tgz"
    "libxml2-2.14.5.tar.xz"
    "libxslt-1.1.43.tar.xz"
    "pcre2-10.45.tar.bz2"
    "sqlite-autoconf-3500400.tar.gz"
    "json-c-0.18.tar.gz"
    "jansson-2.14.tar.gz"
    "libyaml-0.2.5.tar.gz"
    "double-conversion-3.3.1.tar.gz"
    "libpng-1.6.50.tar.xz"
    "libjpeg-turbo-3.1.1.tar.gz"
    "tiff-4.7.0.tar.xz"
    "libwebp-1.5.0.tar.gz"
    "giflib-5.2.2.tar.gz"
    "freetype-2.13.3.tar.xz"
    "fontconfig-2.17.1.tar.xz"
    "harfbuzz-11.4.1.tar.xz"
    "fribidi-1.0.16.tar.xz"
    "graphite2-1.3.14.tgz"
    "cairo-1.18.4.tar.xz"
    "pango-1.56.4.tar.xz"
    "gdk-pixbuf-2.42.12.tar.xz"
    "librsvg-2.61.0.tar.xz"
    "shared-mime-info-2.4.tar.gz"
    "duktape-2.7.0.tar.xz"
    "libical-3.0.20.tar.gz"
)

# BLFS Packages - X11/Wayland
BLFS_DISPLAY=(
    "xorg-server-21.1.18.tar.xz"
    "xwayland-24.1.8.tar.xz"
    "wayland-1.24.0.tar.xz"
    "wayland-protocols-1.45.tar.xz"
    "mesa-25.1.8.tar.xz"
    "libdrm-2.4.125.tar.xz"
    "libinput-1.29.0.tar.gz"
    "libevdev-1.13.4.tar.xz"
    "mtdev-1.1.7.tar.bz2"
    "pixman-0.46.4.tar.gz"
    "xcb-proto-1.17.0.tar.xz"
    "libxcb-1.17.0.tar.xz"
    "xorgproto-2024.1.tar.xz"
    "libX11-1.8.12.tar.xz"
    "libXext-1.3.6.tar.xz"
    "libXrender-0.9.12.tar.xz"
    "libXft-2.3.9.tar.xz"
    "libXi-1.8.2.tar.xz"
    "libXrandr-1.5.4.tar.xz"
    "libXinerama-1.1.5.tar.xz"
    "libXcursor-1.2.3.tar.xz"
    "libXcomposite-0.4.6.tar.xz"
    "libXdamage-1.1.6.tar.xz"
    "libXfixes-6.0.1.tar.xz"
    "libXtst-1.2.5.tar.xz"
    "libXxf86vm-1.1.6.tar.xz"
    "libxkbcommon-1.9.0.tar.xz"
    "libxkbfile-1.1.3.tar.xz"
    "xkeyboard-config-2.44.tar.xz"
    "libwacom-2.17.0.tar.xz"
    "libdisplay-info-0.3.0.tar.xz"
)

# BLFS Packages - Qt6
BLFS_QT6=(
    "qt-everywhere-src-6.9.2.tar.xz"
    "qtwebengine-everywhere-src-6.9.2.tar.xz"
)

# BLFS Packages - Audio/Video
BLFS_MULTIMEDIA=(
    "alsa-lib-1.2.14.tar.bz2"
    "alsa-plugins-1.2.12.tar.bz2"
    "alsa-utils-1.2.14.tar.bz2"
    "alsa-ucm-conf-1.2.14.tar.bz2"
    "pulseaudio-17.0.tar.xz"
    "pipewire-1.4.7.tar.bz2"
    "wireplumber-0.5.10.tar.xz"
    "ffmpeg-7.1.1.tar.xz"
    "gstreamer-1.26.5.tar.xz"
    "gst-plugins-base-1.26.5.tar.xz"
    "gst-plugins-good-1.26.5.tar.xz"
    "gst-plugins-bad-1.26.5.tar.xz"
    "gst-plugins-ugly-1.26.5.tar.xz"
    "libmad-0.15.1b.tar.gz"
    "libvorbis-1.3.7.tar.xz"
    "libogg-1.3.5.tar.xz"
    "flac-1.5.0.tar.xz"
    "opus-1.5.2.tar.gz"
    "libsndfile-1.2.2.tar.xz"
    "speex-1.2.1.tar.gz"
    "speexdsp-1.2.1.tar.gz"
    "lame-3.100.tar.gz"
    "libcanberra-0.30.tar.xz"
    "libass-0.17.3.tar.xz"
    "fdk-aac-2.0.3.tar.gz"
    "x264-20241227.tar.xz"
    "x265-4.1.tar.gz"
    "dav1d-1.5.1.tar.xz"
    "libva-2.22.0.tar.bz2"
    "libvdpau-1.5.tar.bz2"
    "v4l-utils-1.28.1.tar.xz"
)

# BLFS Packages - KDE Frameworks 6
BLFS_KDE_FRAMEWORKS=(
    "extra-cmake-modules-6.17.0.tar.xz"
    "karchive-6.17.0.tar.xz"
    "kcodecs-6.17.0.tar.xz"
    "kconfig-6.17.0.tar.xz"
    "kcoreaddons-6.17.0.tar.xz"
    "kdbusaddons-6.17.0.tar.xz"
    "kdnssd-6.17.0.tar.xz"
    "kguiaddons-6.17.0.tar.xz"
    "ki18n-6.17.0.tar.xz"
    "kidletime-6.17.0.tar.xz"
    "kimageformats-6.17.0.tar.xz"
    "kitemmodels-6.17.0.tar.xz"
    "kitemviews-6.17.0.tar.xz"
    "kplotting-6.17.0.tar.xz"
    "kwidgetsaddons-6.17.0.tar.xz"
    "kwindowsystem-6.17.0.tar.xz"
    "networkmanager-qt-6.17.0.tar.xz"
    "solid-6.17.0.tar.xz"
    "sonnet-6.17.0.tar.xz"
    "threadweaver-6.17.0.tar.xz"
    "kauth-6.17.0.tar.xz"
    "kcompletion-6.17.0.tar.xz"
    "kcrash-6.17.0.tar.xz"
    "kdoctools-6.17.0.tar.xz"
    "kpty-6.17.0.tar.xz"
    "kunitconversion-6.17.0.tar.xz"
    "kconfigwidgets-6.17.0.tar.xz"
    "kservice-6.17.0.tar.xz"
    "kglobalaccel-6.17.0.tar.xz"
    "kpackage-6.17.0.tar.xz"
    "attica-6.17.0.tar.xz"
    "kiconthemes-6.17.0.tar.xz"
    "kjobwidgets-6.17.0.tar.xz"
    "knotifications-6.17.0.tar.xz"
    "ktextwidgets-6.17.0.tar.xz"
    "kxmlgui-6.17.0.tar.xz"
    "kbookmarks-6.17.0.tar.xz"
    "kwallet-6.17.0.tar.xz"
    "kio-6.17.0.tar.xz"
    "kdeclarative-6.17.0.tar.xz"
    "kcmutils-6.17.0.tar.xz"
    "kirigami-6.17.0.tar.xz"
    "syndication-6.17.0.tar.xz"
    "knewstuff-6.17.0.tar.xz"
    "frameworkintegration-6.17.0.tar.xz"
    "kinit-6.17.0.tar.xz"
    "kparts-6.17.0.tar.xz"
    "syntax-highlighting-6.17.0.tar.xz"
    "ktexteditor-6.17.0.tar.xz"
    "kded-6.17.0.tar.xz"
    "ksvg-6.17.0.tar.xz"
    "knotifyconfig-6.17.0.tar.xz"
    "purpose-6.17.0.tar.xz"
    "qqc2-desktop-style-6.17.0.tar.xz"
    "baloo-6.17.0.tar.xz"
    "kfilemetadata-6.17.0.tar.xz"
    "krunner-6.17.0.tar.xz"
    "modemmanager-qt-6.17.0.tar.xz"
    "bluez-qt-6.17.0.tar.xz"
    "prison-6.17.0.tar.xz"
    "kholidays-6.17.0.tar.xz"
    "kcontacts-6.17.0.tar.xz"
    "kpeople-6.17.0.tar.xz"
    "kquickcharts-6.17.0.tar.xz"
    "kstatusnotifieritem-6.17.0.tar.xz"
    "kuserfeedback-6.17.0.tar.xz"
)

# BLFS Packages - KDE Plasma 6
BLFS_KDE_PLASMA=(
    "libplasma-6.4.4.tar.xz"
    "kscreenlocker-6.4.4.tar.xz"
    "kinfocenter-6.4.4.tar.xz"
    "kglobalacceld-6.4.4.tar.xz"
    "kwayland-6.4.4.tar.xz"
    "aurorae-6.4.4.tar.xz"
    "breeze-6.4.4.tar.xz"
    "breeze-gtk-6.4.4.tar.xz"
    "breeze-icons-6.17.0.tar.xz"
    "drkonqi-6.4.4.tar.xz"
    "kactivitymanagerd-6.4.4.tar.xz"
    "kde-cli-tools-6.4.4.tar.xz"
    "kdecoration-6.4.4.tar.xz"
    "kdeplasma-addons-6.4.4.tar.xz"
    "kgamma-6.4.4.tar.xz"
    "kmenuedit-6.4.4.tar.xz"
    "kpipewire-6.4.4.tar.xz"
    "kscreen-6.4.4.tar.xz"
    "kscreenlocker-6.4.4.tar.xz"
    "ksshaskpass-6.4.4.tar.xz"
    "ksystemstats-6.4.4.tar.xz"
    "kwallet-pam-6.4.4.tar.xz"
    "kwayland-integration-6.4.4.tar.xz"
    "kwin-6.4.4.tar.xz"
    "kwrited-6.4.4.tar.xz"
    "layer-shell-qt-6.4.4.tar.xz"
    "libkscreen-6.4.4.tar.xz"
    "libksysguard-6.4.4.tar.xz"
    "milou-6.4.4.tar.xz"
    "ocean-sound-theme-6.4.4.tar.xz"
    "oxygen-6.4.4.tar.xz"
    "oxygen-sounds-6.4.4.tar.xz"
    "plasma-activities-6.4.4.tar.xz"
    "plasma-activities-stats-6.4.4.tar.xz"
    "plasma-browser-integration-6.4.4.tar.xz"
    "plasma-desktop-6.4.4.tar.xz"
    "plasma-disks-6.4.4.tar.xz"
    "plasma-integration-6.4.4.tar.xz"
    "plasma-nm-6.4.4.tar.xz"
    "plasma-pa-6.4.4.tar.xz"
    "plasma-sdk-6.4.4.tar.xz"
    "plasma-systemmonitor-6.4.4.tar.xz"
    "plasma-thunderbolt-6.4.4.tar.xz"
    "plasma-vault-6.4.4.tar.xz"
    "plasma-welcome-6.4.4.tar.xz"
    "plasma-workspace-6.4.4.tar.xz"
    "plasma-workspace-wallpapers-6.4.4.tar.xz"
    "plasma5support-6.4.4.tar.xz"
    "polkit-kde-agent-1-6.4.4.tar.xz"
    "powerdevil-6.4.4.tar.xz"
    "qqc2-breeze-style-6.4.4.tar.xz"
    "sddm-kcm-6.4.4.tar.xz"
    "systemsettings-6.4.4.tar.xz"
    "xdg-desktop-portal-kde-6.4.4.tar.xz"
    "bluedevil-6.4.4.tar.xz"
    "discover-6.4.4.tar.xz"
    "print-manager-6.4.4.tar.xz"
    "spectacle-6.4.4.tar.xz"
    "dolphin-25.08.0.tar.xz"
    "konsole-25.08.0.tar.xz"
    "kate-25.08.0.tar.xz"
    "ark-25.08.0.tar.xz"
    "okular-25.08.0.tar.xz"
    "gwenview-25.08.0.tar.xz"
)

# BLFS Packages - Display Manager
BLFS_SDDM=(
    "sddm-0.21.0.tar.gz"
)

# BLFS Packages - Storage/Filesystem
BLFS_STORAGE=(
    "LVM2.2.03.34.tgz"
    "cryptsetup-2.8.1.tar.xz"
    "mdadm-4.4.tar.xz"
    "parted-3.6.tar.xz"
    "dosfstools-4.2.tar.gz"
    "ntfs-3g-2022.10.3.tar.gz"
    "exfatprogs-1.2.7.tar.xz"
    "libaio-0.3.113.tar.gz"
    "udisks-2.10.2.tar.bz2"
    "libblockdev-3.3.1.tar.gz"
    "libbytesize-2.11.tar.gz"
)

# BLFS Packages - Development Tools
BLFS_DEVEL=(
    "cmake-4.1.0.tar.gz"
    "git-2.50.1.tar.xz"
    "llvm-20.1.8.src.tar.xz"
    "clang-20.1.8.src.tar.xz"
    "rustc-1.89.0-src.tar.xz"
    "rust-bindgen-0.72.0.tar.gz"
    "cargo-c-0.10.11.tar.gz"
    "cbindgen-0.29.0.tar.gz"
    "nasm-2.16.03.tar.xz"
    "yasm-1.3.0.tar.gz"
    "swig-4.3.0.tar.gz"
    "doxygen-1.14.0.src.tar.gz"
)

# BLFS Packages - Python Modules
BLFS_PYTHON=(
    "Cython-3.1.3.tar.gz"
    "numpy-2.3.0.tar.gz"
    "mako-1.3.10.tar.gz"
    "PyYAML-6.0.2.tar.gz"
    "six-1.17.0.tar.gz"
    "certifi-2025.4.26.tar.gz"
    "charset-normalizer-3.4.2.tar.gz"
    "idna-3.10.tar.gz"
    "urllib3-2.3.0.tar.gz"
    "requests-2.32.3.tar.gz"
    "pygobject-3.50.0.tar.xz"
    "pycairo-1.28.0.tar.gz"
    "dbus-python-1.3.2.tar.gz"
    "psutil-7.0.0.tar.gz"
)

# BLFS Packages - Misc Libraries
BLFS_MISC=(
    "docbook-xml_4.5.orig.tar.gz"
    "docbook-xsl-nons-1.79.2.tar.bz2"
    "itstool-2.0.7.tar.bz2"
    "xmlto-0.0.29.tar.gz"
    "glib-2.84.0.tar.xz"
    "gobject-introspection-1.84.0.tar.xz"
    "vala-0.58.0.tar.xz"
    "libgudev-238.tar.xz"
    "upower-1.90.8.tar.xz"
    "at-spi2-core-2.56.4.tar.xz"
    "aspell-0.60.8.1.tar.gz"
    "aspell6-en-2020.12.07-0.tar.bz2"
    "enchant-2.8.3.tar.gz"
    "hunspell-1.7.2.tar.gz"
    "hwdata-0.398.tar.gz"
    "libusb-1.0.27.tar.bz2"
    "libgusb-0.4.9.tar.xz"
    "gpgmepp-2.0.0.tar.xz"
    "qca-2.3.10.tar.xz"
    "poppler-25.05.0.tar.xz"
    "poppler-data-0.4.12.tar.gz"
    "opencv-4.11.0.tar.gz"
    "zxing-cpp-2.3.0.tar.gz"
    "libatasmart-0.19.tar.xz"
    "volume_key-0.3.12.tar.bz2"
    "keyutils-1.6.3.tar.gz"
    "cups-2.4.12-source.tar.gz"
    "cups-filters-1.28.18.tar.xz"
    "hplip-3.25.5.tar.gz"
    "sane-backends-1.4.0.tar.gz"
    "xdg-utils-1.2.1.tar.gz"
    "xdg-user-dirs-0.18.tar.gz"
    "desktop-file-utils-0.28.tar.xz"
    "hicolor-icon-theme-0.18.tar.xz"
    "adwaita-icon-theme-48.1.tar.xz"
    "pulseaudio-qt-1.7.0.tar.xz"
    "xf86-input-wacom-1.2.3.tar.bz2"
    "wacomtablet-6.4.4.tar.xz"
    "kirigami-addons-1.9.0.tar.xz"
    "kdsoap-2.2.0.tar.gz"
    "kdsoap-ws-discovery-client-0.4.0.tar.xz"
    "kio-extras-25.08.0.tar.xz"
    "oxygen-icons-6.1.0.tar.xz"
)

# BLFS Patches
BLFS_PATCHES=(
    "avahi-0.8-ipv6_race_condition_fix-1.patch"
    "coreutils-9.7-upstream_fix-1.patch"
    "docbook-xsl-nons-1.79.2-stack_fix-1.patch"
    "extra-cmake-modules-6.17.0-upstream_fix-1.patch"
    "libcanberra-0.30-wayland-1.patch"
    "libmad-0.15.1b-fixes-1.patch"
    "lua-5.4.8-shared_library-1.patch"
    "nss-standalone-1.patch"
    "vlc-3.0.21-fedora_ffmpeg7-1.patch"
    "vlc-3.0.21-taglib-1.patch"
)

# =============================================================================
# Download Functions
# =============================================================================

download_category() {
    local name="$1"
    shift
    local packages=("$@")

    log_info "=========================================="
    log_info "Downloading: $name"
    log_info "=========================================="

    local failed=0
    for pkg in "${packages[@]}"; do
        if ! download_with_retry "$pkg"; then
            failed=$((failed + 1))
        fi
    done

    if [ $failed -gt 0 ]; then
        log_error "$failed packages failed in $name"
        return 1
    fi

    log_info "$name complete"
    return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
    log_info "=========================================="
    log_info "RookeryOS Source Download"
    log_info "=========================================="
    log_info "Mirror: $MIRROR"
    log_info "Target: $SOURCES_DIR"
    log_info "=========================================="

    # Create sources directory
    mkdir -p "$SOURCES_DIR"

    # Download all categories
    download_category "LFS Base System" "${LFS_PACKAGES[@]}"
    download_category "LFS Patches" "${LFS_PATCHES[@]}"
    download_category "Security & Authentication" "${BLFS_SECURITY[@]}"
    download_category "GnuPG PQC Stack" "${BLFS_GNUPG[@]}"
    download_category "Networking" "${BLFS_NETWORKING[@]}"
    download_category "Libraries" "${BLFS_LIBRARIES[@]}"
    download_category "X11/Wayland" "${BLFS_DISPLAY[@]}"
    download_category "Qt6" "${BLFS_QT6[@]}"
    download_category "Multimedia" "${BLFS_MULTIMEDIA[@]}"
    download_category "KDE Frameworks" "${BLFS_KDE_FRAMEWORKS[@]}"
    download_category "KDE Plasma" "${BLFS_KDE_PLASMA[@]}"
    download_category "SDDM" "${BLFS_SDDM[@]}"
    download_category "Storage" "${BLFS_STORAGE[@]}"
    download_category "Development Tools" "${BLFS_DEVEL[@]}"
    download_category "Python Modules" "${BLFS_PYTHON[@]}"
    download_category "Miscellaneous" "${BLFS_MISC[@]}"
    download_category "BLFS Patches" "${BLFS_PATCHES[@]}"

    log_info "=========================================="
    log_info "Download Complete!"
    log_info "=========================================="
    log_info "All packages downloaded to: $SOURCES_DIR"
    log_info "=========================================="
}

main "$@"
