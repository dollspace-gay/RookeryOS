#!/bin/bash
set -euo pipefail

# =============================================================================
# EasyLFS Download Sources Script
# Downloads all LFS and BLFS packages from Corvidae mirrors for LFS 12.4
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
LFS_VERSION="${LFS_VERSION:-12.4}"
SOURCES_DIR="/sources"
MAX_RETRIES=3
RETRY_DELAY=5
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS:-6}"
DOWNLOAD_TIMEOUT=60

# Mirror URLs
LFS_MIRROR="http://corvidae.social/lfs/12.4"
BLFS_MIRROR="http://corvidae.social/blfs/12.4"

# Note: LFS for download-sources points to /sources since we don't have /lfs yet
export LFS="${LFS:-/lfs}"

# Track failed downloads
FAILED_DOWNLOADS_FILE="/tmp/failed_downloads.$$"
: > "$FAILED_DOWNLOADS_FILE"

# Setup logging trap
trap 'finalize_logging $?; rm -f "$FAILED_DOWNLOADS_FILE"' EXIT

# =============================================================================
# Halt on Download Failure
# =============================================================================
halt_on_download_failure() {
    local url="$1"
    local filename="${2:-$(basename "$url")}"
    
    log_error "========================================="
    log_error "FATAL: Download failed - halting build"
    log_error "========================================="
    log_error "URL:      $url"
    log_error "Filename: $filename"
    log_error "========================================="
    log_error "The download failed after $MAX_RETRIES attempts."
    log_error "Please check:"
    log_error "  - Your network connection"
    log_error "  - If the mirror is available"
    log_error "========================================="
    
    exit 1
}

# =============================================================================
# Download with retry
# =============================================================================
download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading $output (attempt $attempt/$MAX_RETRIES)..."

        if wget --continue \
                --progress=dot:giga \
                --timeout=$DOWNLOAD_TIMEOUT \
                --read-timeout=30 \
                --dns-timeout=20 \
                --tries=2 \
                -O "$output" \
                "$url"; then
            return 0
        fi

        log_warn "Download failed, retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        ((attempt++))
    done

    halt_on_download_failure "$url" "$output"
}

# =============================================================================
# Download a single file (for parallel execution)
# =============================================================================
download_file() {
    local url="$1"
    local filename=$(basename "$url")
    local sources_dir="$2"

    cd "$sources_dir"

    # Skip if file already exists and is non-empty
    if [ -f "$filename" ] && [ -s "$filename" ]; then
        echo "[SKIP] $filename (already exists)"
        return 0
    fi

    # Remove empty/partial files
    rm -f "$filename"

    # Download the file
    if download_with_retry "$url" "$filename"; then
        echo "[OK] $filename"
        return 0
    else
        echo "[FAIL] $filename"
        echo "$url" >> /tmp/failed_downloads.$$
        exit 1
    fi
}

# =============================================================================
# Get file list from mirror directory
# =============================================================================
get_mirror_files() {
    local mirror_url="$1"
    
    # Fetch the directory listing and extract file links
    # The mirror should return an HTML directory listing
    wget -q -O - "$mirror_url/" 2>/dev/null | \
        grep -oE 'href="[^"]+\.(tar\.(xz|gz|bz2)|tgz|patch|zip)"' | \
        sed 's/href="//g; s/"//g' | \
        sort -u
}

# =============================================================================
# Download all files from a mirror
# =============================================================================
download_from_mirror() {
    local mirror_url="$1"
    local mirror_name="$2"
    
    log_info "========================================="
    log_info "Downloading from $mirror_name mirror..."
    log_info "URL: $mirror_url"
    log_info "========================================="
    
    # Get list of files from mirror
    local files
    files=$(get_mirror_files "$mirror_url")
    
    if [ -z "$files" ]; then
        log_error "Failed to get file list from $mirror_url"
        log_error "Make sure the mirror is accessible and contains files."
        exit 1
    fi
    
    local file_count=$(echo "$files" | wc -l)
    log_info "Found $file_count files to download from $mirror_name"
    
    # Create URL list for parallel download
    local url_list="/tmp/${mirror_name}_urls.$$"
    echo "$files" | while read -r filename; do
        echo "${mirror_url}/${filename}"
    done > "$url_list"
    
    # Download files in parallel
    if command -v parallel >/dev/null 2>&1; then
        log_info "Using GNU parallel for downloads"
        cat "$url_list" | \
            parallel -j "$PARALLEL_DOWNLOADS" --line-buffer --tag --halt now,fail=1 \
                download_file {} "$SOURCES_DIR"
    else
        log_info "Using xargs for parallel downloads"
        cat "$url_list" | \
            xargs -P "$PARALLEL_DOWNLOADS" -I {} bash -c 'download_file "$@"' _ {} "$SOURCES_DIR"
    fi
    
    rm -f "$url_list"
    
    log_info "Completed downloads from $mirror_name"
}

# =============================================================================
# Main function
# =============================================================================
main() {
    # Initialize logging
    init_logging

    log_info "========================================="
    log_info "EasyLFS Source Download - Mirror Edition"
    log_info "========================================="
    log_info "LFS Version: $LFS_VERSION"
    log_info "Target directory: $SOURCES_DIR"
    log_info "LFS Mirror: $LFS_MIRROR"
    log_info "BLFS Mirror: $BLFS_MIRROR"
    log_info "========================================="

    # Create sources directory
    mkdir -p "$SOURCES_DIR"
    cd "$SOURCES_DIR"

    # Initialize checkpoint system
    export CHECKPOINT_DIR="$SOURCES_DIR/.checkpoints"
    init_checkpointing

    # Check if download was already completed
    if should_skip_global_checkpoint "download-complete"; then
        log_info "========================================="
        log_info "All sources already downloaded"
        log_info "========================================="
        exit 0
    fi

    # Export functions for parallel execution
    export -f download_with_retry
    export -f download_file
    export -f halt_on_download_failure
    export -f log_info
    export -f log_warn
    export -f log_error
    export SOURCES_DIR MAX_RETRIES RETRY_DELAY DOWNLOAD_TIMEOUT
    export RED GREEN YELLOW NC

    log_info ""
    log_info "NOTE: Build will halt immediately if any download fails"
    log_info ""

    # Download from LFS mirror
    download_from_mirror "$LFS_MIRROR" "LFS"
    
    # Download from BLFS mirror
    download_from_mirror "$BLFS_MIRROR" "BLFS"

    # =============================================================================
    # Download packages not on mirror (Tier 7: Qt6 and Pre-KDE dependencies)
    # These packages are required for Qt6/KDE but aren't on the corvidae mirror yet
    # =============================================================================
    log_info "========================================="
    log_info "Downloading additional Tier 7 packages..."
    log_info "========================================="

    # libuv-1.51.0 (required by Node.js)
    if [ ! -f "$SOURCES_DIR/libuv-v1.51.0.tar.gz" ]; then
        download_with_retry "https://dist.libuv.org/dist/v1.51.0/libuv-v1.51.0.tar.gz" \
            "$SOURCES_DIR/libuv-v1.51.0.tar.gz"
    else
        log_info "[SKIP] libuv-v1.51.0.tar.gz (already exists)"
    fi

    # nghttp2-1.66.0 (required by Node.js with --shared-nghttp2)
    if [ ! -f "$SOURCES_DIR/nghttp2-1.66.0.tar.xz" ]; then
        download_with_retry "https://github.com/nghttp2/nghttp2/releases/download/v1.66.0/nghttp2-1.66.0.tar.xz" \
            "$SOURCES_DIR/nghttp2-1.66.0.tar.xz"
    else
        log_info "[SKIP] nghttp2-1.66.0.tar.xz (already exists)"
    fi

    # Node.js v22.18.0 (required by QtWebEngine)
    if [ ! -f "$SOURCES_DIR/node-v22.18.0.tar.xz" ]; then
        download_with_retry "https://nodejs.org/dist/v22.18.0/node-v22.18.0.tar.xz" \
            "$SOURCES_DIR/node-v22.18.0.tar.xz"
    else
        log_info "[SKIP] node-v22.18.0.tar.xz (already exists)"
    fi

    # CUPS 2.4.12 (printing support)
    if [ ! -f "$SOURCES_DIR/cups-2.4.12-source.tar.gz" ]; then
        download_with_retry "https://github.com/OpenPrinting/cups/releases/download/v2.4.12/cups-2.4.12-source.tar.gz" \
            "$SOURCES_DIR/cups-2.4.12-source.tar.gz"
    else
        log_info "[SKIP] cups-2.4.12-source.tar.gz (already exists)"
    fi

    log_info "Tier 7 additional downloads complete"

    # =============================================================================
    # Tier 8: KDE Frameworks 6 Dependencies
    # These packages are required by KF6 but aren't on the corvidae mirror
    # =============================================================================
    log_info "========================================="
    log_info "Downloading Tier 8: KDE Frameworks 6 Dependencies..."
    log_info "========================================="

    # intltool-0.51.0 (required by sound-theme-freedesktop)
    if [ ! -f "$SOURCES_DIR/intltool-0.51.0.tar.gz" ]; then
        download_with_retry "https://launchpad.net/intltool/trunk/0.51.0/+download/intltool-0.51.0.tar.gz" \
            "$SOURCES_DIR/intltool-0.51.0.tar.gz"
    else
        log_info "[SKIP] intltool-0.51.0.tar.gz (already exists)"
    fi

    # libcanberra-0.30 (XDG Sound Theme implementation)
    if [ ! -f "$SOURCES_DIR/libcanberra-0.30.tar.xz" ]; then
        download_with_retry "https://0pointer.de/lennart/projects/libcanberra/libcanberra-0.30.tar.xz" \
            "$SOURCES_DIR/libcanberra-0.30.tar.xz"
    else
        log_info "[SKIP] libcanberra-0.30.tar.xz (already exists)"
    fi

    # libcanberra wayland patch
    if [ ! -f "$SOURCES_DIR/libcanberra-0.30-wayland-1.patch" ]; then
        download_with_retry "https://www.linuxfromscratch.org/patches/blfs/12.4/libcanberra-0.30-wayland-1.patch" \
            "$SOURCES_DIR/libcanberra-0.30-wayland-1.patch"
    else
        log_info "[SKIP] libcanberra-0.30-wayland-1.patch (already exists)"
    fi

    # libical-3.0.20 (iCalendar protocols)
    if [ ! -f "$SOURCES_DIR/libical-3.0.20.tar.gz" ]; then
        download_with_retry "https://github.com/libical/libical/releases/download/v3.0.20/libical-3.0.20.tar.gz" \
            "$SOURCES_DIR/libical-3.0.20.tar.gz"
    else
        log_info "[SKIP] libical-3.0.20.tar.gz (already exists)"
    fi

    # lmdb-0.9.33 (Lightning Memory-Mapped Database)
    if [ ! -f "$SOURCES_DIR/LMDB_0.9.33.tar.bz2" ]; then
        download_with_retry "https://git.openldap.org/openldap/openldap/-/archive/LMDB_0.9.33.tar.bz2" \
            "$SOURCES_DIR/LMDB_0.9.33.tar.bz2"
    else
        log_info "[SKIP] LMDB_0.9.33.tar.bz2 (already exists)"
    fi

    # libqrencode-4.1.1 (QR code library)
    if [ ! -f "$SOURCES_DIR/libqrencode-4.1.1.tar.gz" ]; then
        download_with_retry "https://github.com/fukuchi/libqrencode/archive/v4.1.1/libqrencode-4.1.1.tar.gz" \
            "$SOURCES_DIR/libqrencode-4.1.1.tar.gz"
    else
        log_info "[SKIP] libqrencode-4.1.1.tar.gz (already exists)"
    fi

    # Aspell-0.60.8.1 (Spell checker)
    if [ ! -f "$SOURCES_DIR/aspell-0.60.8.1.tar.gz" ]; then
        download_with_retry "https://ftp.gnu.org/gnu/aspell/aspell-0.60.8.1.tar.gz" \
            "$SOURCES_DIR/aspell-0.60.8.1.tar.gz"
    else
        log_info "[SKIP] aspell-0.60.8.1.tar.gz (already exists)"
    fi

    # Aspell English dictionary
    if [ ! -f "$SOURCES_DIR/aspell6-en-2020.12.07-0.tar.bz2" ]; then
        download_with_retry "https://ftp.gnu.org/gnu/aspell/dict/en/aspell6-en-2020.12.07-0.tar.bz2" \
            "$SOURCES_DIR/aspell6-en-2020.12.07-0.tar.bz2"
    else
        log_info "[SKIP] aspell6-en-2020.12.07-0.tar.bz2 (already exists)"
    fi

    # BlueZ-5.83 (Bluetooth stack)
    if [ ! -f "$SOURCES_DIR/bluez-5.83.tar.xz" ]; then
        download_with_retry "https://www.kernel.org/pub/linux/bluetooth/bluez-5.83.tar.xz" \
            "$SOURCES_DIR/bluez-5.83.tar.xz"
    else
        log_info "[SKIP] bluez-5.83.tar.xz (already exists)"
    fi

    # ModemManager-1.24.2 (Mobile broadband modem management)
    if [ ! -f "$SOURCES_DIR/ModemManager-1.24.2.tar.gz" ]; then
        download_with_retry "https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/archive/1.24.2/ModemManager-1.24.2.tar.gz" \
            "$SOURCES_DIR/ModemManager-1.24.2.tar.gz"
    else
        log_info "[SKIP] ModemManager-1.24.2.tar.gz (already exists)"
    fi

    # UPower-1.90.9 (Power management)
    if [ ! -f "$SOURCES_DIR/upower-v1.90.9.tar.bz2" ]; then
        download_with_retry "https://gitlab.freedesktop.org/upower/upower/-/archive/v1.90.9/upower-v1.90.9.tar.bz2" \
            "$SOURCES_DIR/upower-v1.90.9.tar.bz2"
    else
        log_info "[SKIP] upower-v1.90.9.tar.bz2 (already exists)"
    fi

    # sound-theme-freedesktop-0.8 (XDG sound theme)
    if [ ! -f "$SOURCES_DIR/sound-theme-freedesktop-0.8.tar.bz2" ]; then
        download_with_retry "https://people.freedesktop.org/~mccann/dist/sound-theme-freedesktop-0.8.tar.bz2" \
            "$SOURCES_DIR/sound-theme-freedesktop-0.8.tar.bz2"
    else
        log_info "[SKIP] sound-theme-freedesktop-0.8.tar.bz2 (already exists)"
    fi

    # breeze-icons-6.17.0 (KDE icon theme)
    if [ ! -f "$SOURCES_DIR/breeze-icons-6.17.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/frameworks/6.17/breeze-icons-6.17.0.tar.xz" \
            "$SOURCES_DIR/breeze-icons-6.17.0.tar.xz"
    else
        log_info "[SKIP] breeze-icons-6.17.0.tar.xz (already exists)"
    fi

    # libgudev-238 (GObject bindings for libudev - required by ModemManager, UPower, UDisks)
    if [ ! -f "$SOURCES_DIR/libgudev-238.tar.xz" ]; then
        download_with_retry "https://download.gnome.org/sources/libgudev/238/libgudev-238.tar.xz" \
            "$SOURCES_DIR/libgudev-238.tar.xz"
    else
        log_info "[SKIP] libgudev-238.tar.xz (already exists)"
    fi

    # libusb-1.0.29 (USB access library - required by UPower)
    if [ ! -f "$SOURCES_DIR/libusb-1.0.29.tar.bz2" ]; then
        download_with_retry "https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2" \
            "$SOURCES_DIR/libusb-1.0.29.tar.bz2"
    else
        log_info "[SKIP] libusb-1.0.29.tar.bz2 (already exists)"
    fi

    # libmbim-1.32.0 (MBIM protocol library - required by ModemManager)
    if [ ! -f "$SOURCES_DIR/libmbim-1.32.0.tar.gz" ]; then
        download_with_retry "https://gitlab.freedesktop.org/mobile-broadband/libmbim/-/archive/1.32.0/libmbim-1.32.0.tar.gz" \
            "$SOURCES_DIR/libmbim-1.32.0.tar.gz"
    else
        log_info "[SKIP] libmbim-1.32.0.tar.gz (already exists)"
    fi

    # libqmi-1.36.0 (QMI protocol library - required by ModemManager)
    if [ ! -f "$SOURCES_DIR/libqmi-1.36.0.tar.gz" ]; then
        download_with_retry "https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/archive/1.36.0/libqmi-1.36.0.tar.gz" \
            "$SOURCES_DIR/libqmi-1.36.0.tar.gz"
    else
        log_info "[SKIP] libqmi-1.36.0.tar.gz (already exists)"
    fi

    # libatasmart-0.19 (ATA SMART library - required by UDisks/libblockdev)
    if [ ! -f "$SOURCES_DIR/libatasmart-0.19.tar.xz" ]; then
        download_with_retry "https://0pointer.de/public/libatasmart-0.19.tar.xz" \
            "$SOURCES_DIR/libatasmart-0.19.tar.xz"
    else
        log_info "[SKIP] libatasmart-0.19.tar.xz (already exists)"
    fi

    # libbytesize-2.11 (byte size library - required by libblockdev)
    if [ ! -f "$SOURCES_DIR/libbytesize-2.11.tar.gz" ]; then
        download_with_retry "https://github.com/storaged-project/libbytesize/releases/download/2.11/libbytesize-2.11.tar.gz" \
            "$SOURCES_DIR/libbytesize-2.11.tar.gz"
    else
        log_info "[SKIP] libbytesize-2.11.tar.gz (already exists)"
    fi

    # keyutils-1.6.3 (kernel key management - required by libnvme)
    if [ ! -f "$SOURCES_DIR/keyutils-1.6.3.tar.gz" ]; then
        download_with_retry "https://git.kernel.org/pub/scm/linux/kernel/git/dhowells/keyutils.git/snapshot/keyutils-1.6.3.tar.gz" \
            "$SOURCES_DIR/keyutils-1.6.3.tar.gz"
    else
        log_info "[SKIP] keyutils-1.6.3.tar.gz (already exists)"
    fi

    # libaio-0.3.113 (async I/O library - required by LVM2)
    if [ ! -f "$SOURCES_DIR/libaio-0.3.113.tar.gz" ]; then
        download_with_retry "https://pagure.io/libaio/archive/libaio-0.3.113/libaio-0.3.113.tar.gz" \
            "$SOURCES_DIR/libaio-0.3.113.tar.gz"
    else
        log_info "[SKIP] libaio-0.3.113.tar.gz (already exists)"
    fi

    # popt-1.19 (command-line parsing - required by cryptsetup)
    if [ ! -f "$SOURCES_DIR/popt-1.19.tar.gz" ]; then
        download_with_retry "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz" \
            "$SOURCES_DIR/popt-1.19.tar.gz"
    else
        log_info "[SKIP] popt-1.19.tar.gz (already exists)"
    fi

    # json-c-0.18 (JSON C library - required by cryptsetup)
    if [ ! -f "$SOURCES_DIR/json-c-0.18.tar.gz" ]; then
        download_with_retry "https://s3.amazonaws.com/json-c_releases/releases/json-c-0.18.tar.gz" \
            "$SOURCES_DIR/json-c-0.18.tar.gz"
    else
        log_info "[SKIP] json-c-0.18.tar.gz (already exists)"
    fi

    # LVM2-2.03.34 (Logical Volume Manager - provides device-mapper)
    if [ ! -f "$SOURCES_DIR/LVM2.2.03.34.tgz" ]; then
        download_with_retry "https://sourceware.org/ftp/lvm2/LVM2.2.03.34.tgz" \
            "$SOURCES_DIR/LVM2.2.03.34.tgz"
    else
        log_info "[SKIP] LVM2.2.03.34.tgz (already exists)"
    fi

    # cryptsetup-2.8.1 (disk encryption - required by libblockdev)
    if [ ! -f "$SOURCES_DIR/cryptsetup-2.8.1.tar.xz" ]; then
        download_with_retry "https://www.kernel.org/pub/linux/utils/cryptsetup/v2.8/cryptsetup-2.8.1.tar.xz" \
            "$SOURCES_DIR/cryptsetup-2.8.1.tar.xz"
    else
        log_info "[SKIP] cryptsetup-2.8.1.tar.xz (already exists)"
    fi

    # libnvme-1.15 (NVMe library - required by libblockdev)
    if [ ! -f "$SOURCES_DIR/libnvme-1.15.tar.gz" ]; then
        download_with_retry "https://github.com/linux-nvme/libnvme/archive/v1.15/libnvme-1.15.tar.gz" \
            "$SOURCES_DIR/libnvme-1.15.tar.gz"
    else
        log_info "[SKIP] libnvme-1.15.tar.gz (already exists)"
    fi

    # libblockdev-3.3.1 (block device library - required by UDisks)
    if [ ! -f "$SOURCES_DIR/libblockdev-3.3.1.tar.gz" ]; then
        download_with_retry "https://github.com/storaged-project/libblockdev/releases/download/3.3.1/libblockdev-3.3.1.tar.gz" \
            "$SOURCES_DIR/libblockdev-3.3.1.tar.gz"
    else
        log_info "[SKIP] libblockdev-3.3.1.tar.gz (already exists)"
    fi

    # UDisks-2.10.2 (disk management daemon)
    if [ ! -f "$SOURCES_DIR/udisks-2.10.2.tar.bz2" ]; then
        download_with_retry "https://github.com/storaged-project/udisks/releases/download/udisks-2.10.2/udisks-2.10.2.tar.bz2" \
            "$SOURCES_DIR/udisks-2.10.2.tar.bz2"
    else
        log_info "[SKIP] udisks-2.10.2.tar.bz2 (already exists)"
    fi

    # =========================================================================
    # GnuPG Cryptography Stack (for gpgmepp -> KDE Frameworks)
    # =========================================================================

    # npth-1.8 (portable threading library for GnuPG)
    if [ ! -f "$SOURCES_DIR/npth-1.8.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/npth/npth-1.8.tar.bz2" \
            "$SOURCES_DIR/npth-1.8.tar.bz2"
    else
        log_info "[SKIP] npth-1.8.tar.bz2 (already exists)"
    fi

    # libassuan-3.0.2 (IPC library for GnuPG)
    if [ ! -f "$SOURCES_DIR/libassuan-3.0.2.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/libassuan/libassuan-3.0.2.tar.bz2" \
            "$SOURCES_DIR/libassuan-3.0.2.tar.bz2"
    else
        log_info "[SKIP] libassuan-3.0.2.tar.bz2 (already exists)"
    fi

    # libksba-1.6.7 (X.509 library for GnuPG)
    if [ ! -f "$SOURCES_DIR/libksba-1.6.7.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/libksba/libksba-1.6.7.tar.bz2" \
            "$SOURCES_DIR/libksba-1.6.7.tar.bz2"
    else
        log_info "[SKIP] libksba-1.6.7.tar.bz2 (already exists)"
    fi

    # pinentry-1.3.2 (PIN entry dialog)
    if [ ! -f "$SOURCES_DIR/pinentry-1.3.2.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/pinentry/pinentry-1.3.2.tar.bz2" \
            "$SOURCES_DIR/pinentry-1.3.2.tar.bz2"
    else
        log_info "[SKIP] pinentry-1.3.2.tar.bz2 (already exists)"
    fi

    # gnupg-2.4.8 (GNU Privacy Guard)
    if [ ! -f "$SOURCES_DIR/gnupg-2.4.8.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/gnupg/gnupg-2.4.8.tar.bz2" \
            "$SOURCES_DIR/gnupg-2.4.8.tar.bz2"
    else
        log_info "[SKIP] gnupg-2.4.8.tar.bz2 (already exists)"
    fi

    # gpgme-2.0.0 (GnuPG Made Easy)
    if [ ! -f "$SOURCES_DIR/gpgme-2.0.0.tar.bz2" ]; then
        download_with_retry "https://www.gnupg.org/ftp/gcrypt/gpgme/gpgme-2.0.0.tar.bz2" \
            "$SOURCES_DIR/gpgme-2.0.0.tar.bz2"
    else
        log_info "[SKIP] gpgme-2.0.0.tar.bz2 (already exists)"
    fi

    # gpgmepp-2.0.0 (C++ bindings for GPGME - from KDE)
    if [ ! -f "$SOURCES_DIR/gpgmepp-2.0.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/gpgmepp/gpgmepp-2.0.0.tar.xz" \
            "$SOURCES_DIR/gpgmepp-2.0.0.tar.xz"
    else
        log_info "[SKIP] gpgmepp-2.0.0.tar.xz (already exists)"
    fi

    log_info "Tier 8: KDE Frameworks 6 Dependencies complete"

    # =========================================================================
    # zxing-cpp (barcode/QR code library - needed for KF6 Prison)
    # =========================================================================

    # zxing-cpp-2.3.0
    if [ ! -f "$SOURCES_DIR/zxing-cpp-2.3.0.tar.gz" ]; then
        download_with_retry "https://github.com/zxing-cpp/zxing-cpp/archive/v2.3.0/zxing-cpp-2.3.0.tar.gz" \
            "$SOURCES_DIR/zxing-cpp-2.3.0.tar.gz"
    else
        log_info "[SKIP] zxing-cpp-2.3.0.tar.gz (already exists)"
    fi

    # libsecret-0.21.7 (GNOME secret storage library - required by kwallet)
    if [ ! -f "$SOURCES_DIR/libsecret-0.21.7.tar.xz" ]; then
        download_with_retry "https://download.gnome.org/sources/libsecret/0.21/libsecret-0.21.7.tar.xz" \
            "$SOURCES_DIR/libsecret-0.21.7.tar.xz"
    else
        log_info "[SKIP] libsecret-0.21.7.tar.xz (already exists)"
    fi

    # =========================================================================
    # Perl modules required for KDE Frameworks
    # =========================================================================

    # MIME-Base32-1.303 (dependency of URI)
    if [ ! -f "$SOURCES_DIR/MIME-Base32-1.303.tar.gz" ]; then
        download_with_retry "https://cpan.metacpan.org/authors/id/R/RE/REHSACK/MIME-Base32-1.303.tar.gz" \
            "$SOURCES_DIR/MIME-Base32-1.303.tar.gz"
    else
        log_info "[SKIP] MIME-Base32-1.303.tar.gz (already exists)"
    fi

    # URI-5.32 (required for KDE Frameworks)
    if [ ! -f "$SOURCES_DIR/URI-5.32.tar.gz" ]; then
        download_with_retry "https://www.cpan.org/authors/id/O/OA/OALDERS/URI-5.32.tar.gz" \
            "$SOURCES_DIR/URI-5.32.tar.gz"
    else
        log_info "[SKIP] URI-5.32.tar.gz (already exists)"
    fi

    log_info "Perl modules for KDE complete"

    # =========================================================================
    # KDE Frameworks 6.17.0 (49 packages)
    # https://www.linuxfromscratch.org/blfs/view/12.4/kde/frameworks6.html
    # =========================================================================

    log_info "Downloading KDE Frameworks 6.17.0..."
    local KF6_URL="https://download.kde.org/stable/frameworks/6.17"

    # Tier 1: Foundation Frameworks (no KF6 dependencies)
    for pkg in attica kapidox karchive kcodecs kconfig kcoreaddons kdbusaddons \
               kdnssd kguiaddons ki18n kidletime kimageformats kitemmodels \
               kitemviews kplotting kwidgetsaddons kwindowsystem networkmanager-qt \
               solid sonnet threadweaver; do
        if [ ! -f "$SOURCES_DIR/${pkg}-6.17.0.tar.xz" ]; then
            download_with_retry "${KF6_URL}/${pkg}-6.17.0.tar.xz" \
                "$SOURCES_DIR/${pkg}-6.17.0.tar.xz"
        else
            log_info "[SKIP] ${pkg}-6.17.0.tar.xz (already exists)"
        fi
    done

    log_info "KF6 Tier 1 downloads complete"

    # Tier 2: Core Frameworks (depend on Tier 1)
    for pkg in kauth kcompletion kcrash kdoctools kpty kunitconversion \
               kcolorscheme kconfigwidgets kservice kglobalaccel kpackage \
               kdesu kiconthemes knotifications kjobwidgets ktextwidgets \
               kxmlgui kbookmarks kwallet kded kio kdeclarative kcmutils; do
        if [ ! -f "$SOURCES_DIR/${pkg}-6.17.0.tar.xz" ]; then
            download_with_retry "${KF6_URL}/${pkg}-6.17.0.tar.xz" \
                "$SOURCES_DIR/${pkg}-6.17.0.tar.xz"
        else
            log_info "[SKIP] ${pkg}-6.17.0.tar.xz (already exists)"
        fi
    done

    log_info "KF6 Tier 2 downloads complete"

    # Tier 3: Integration Frameworks (depend on Tier 2)
    for pkg in kirigami syndication knewstuff frameworkintegration kparts \
               syntax-highlighting ktexteditor modemmanager-qt kcontacts kpeople; do
        if [ ! -f "$SOURCES_DIR/${pkg}-6.17.0.tar.xz" ]; then
            download_with_retry "${KF6_URL}/${pkg}-6.17.0.tar.xz" \
                "$SOURCES_DIR/${pkg}-6.17.0.tar.xz"
        else
            log_info "[SKIP] ${pkg}-6.17.0.tar.xz (already exists)"
        fi
    done

    log_info "KF6 Tier 3 downloads complete"

    # Tier 4: Extended Frameworks (depend on Tier 3)
    for pkg in bluez-qt kfilemetadata baloo krunner prison qqc2-desktop-style \
               kholidays purpose kcalendarcore kquickcharts knotifyconfig kdav \
               kstatusnotifieritem ksvg ktexttemplate kuserfeedback; do
        if [ ! -f "$SOURCES_DIR/${pkg}-6.17.0.tar.xz" ]; then
            download_with_retry "${KF6_URL}/${pkg}-6.17.0.tar.xz" \
                "$SOURCES_DIR/${pkg}-6.17.0.tar.xz"
        else
            log_info "[SKIP] ${pkg}-6.17.0.tar.xz (already exists)"
        fi
    done

    log_info "KF6 Tier 4 downloads complete"
    log_info "KDE Frameworks 6.17.0 downloads complete (49 packages)"

    # =========================================================================
    # Tier 9: Plasma Prerequisites (required before KDE Plasma)
    # =========================================================================
    log_info "========================================="
    log_info "Downloading Tier 9: Plasma Prerequisites..."
    log_info "========================================="

    # oxygen-icons-6.0.0 (alternative icon theme)
    if [ ! -f "$SOURCES_DIR/oxygen-icons-6.0.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/oxygen-icons/oxygen-icons-6.0.0.tar.xz" \
            "$SOURCES_DIR/oxygen-icons-6.0.0.tar.xz"
    else
        log_info "[SKIP] oxygen-icons-6.0.0.tar.xz (already exists)"
    fi

    # kirigami-addons-1.9.0 (Kirigami UI addons)
    if [ ! -f "$SOURCES_DIR/kirigami-addons-1.9.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/kirigami-addons/kirigami-addons-1.9.0.tar.xz" \
            "$SOURCES_DIR/kirigami-addons-1.9.0.tar.xz"
    else
        log_info "[SKIP] kirigami-addons-1.9.0.tar.xz (already exists)"
    fi

    # duktape-2.7.0 (JavaScript engine - required by libproxy)
    if [ ! -f "$SOURCES_DIR/duktape-2.7.0.tar.xz" ]; then
        download_with_retry "https://duktape.org/duktape-2.7.0.tar.xz" \
            "$SOURCES_DIR/duktape-2.7.0.tar.xz"
    else
        log_info "[SKIP] duktape-2.7.0.tar.xz (already exists)"
    fi

    # libproxy-0.5.10 (proxy configuration library - required by kio-extras)
    if [ ! -f "$SOURCES_DIR/libproxy-0.5.10.tar.gz" ]; then
        download_with_retry "https://github.com/libproxy/libproxy/archive/0.5.10/libproxy-0.5.10.tar.gz" \
            "$SOURCES_DIR/libproxy-0.5.10.tar.gz"
    else
        log_info "[SKIP] libproxy-0.5.10.tar.gz (already exists)"
    fi

    # kdsoap-2.2.0 (Qt SOAP library)
    if [ ! -f "$SOURCES_DIR/kdsoap-2.2.0.tar.gz" ]; then
        download_with_retry "https://github.com/KDAB/KDSoap/releases/download/kdsoap-2.2.0/kdsoap-2.2.0.tar.gz" \
            "$SOURCES_DIR/kdsoap-2.2.0.tar.gz"
    else
        log_info "[SKIP] kdsoap-2.2.0.tar.gz (already exists)"
    fi

    # kdsoap-ws-discovery-client-0.4.0 (WS-Discovery protocol - required by kio-extras)
    if [ ! -f "$SOURCES_DIR/kdsoap-ws-discovery-client-0.4.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/kdsoap-ws-discovery-client/kdsoap-ws-discovery-client-0.4.0.tar.xz" \
            "$SOURCES_DIR/kdsoap-ws-discovery-client-0.4.0.tar.xz"
    else
        log_info "[SKIP] kdsoap-ws-discovery-client-0.4.0.tar.xz (already exists)"
    fi

    # plasma-activities-6.4.4 (KDE Activities core)
    if [ ! -f "$SOURCES_DIR/plasma-activities-6.4.4.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/plasma/6.4.4/plasma-activities-6.4.4.tar.xz" \
            "$SOURCES_DIR/plasma-activities-6.4.4.tar.xz"
    else
        log_info "[SKIP] plasma-activities-6.4.4.tar.xz (already exists)"
    fi

    # plasma-activities-stats-6.4.4 (Activity usage stats - required by kio-extras)
    if [ ! -f "$SOURCES_DIR/plasma-activities-stats-6.4.4.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/plasma/6.4.4/plasma-activities-stats-6.4.4.tar.xz" \
            "$SOURCES_DIR/plasma-activities-stats-6.4.4.tar.xz"
    else
        log_info "[SKIP] plasma-activities-stats-6.4.4.tar.xz (already exists)"
    fi

    # kio-extras-25.08.0 (Extra KIO protocols)
    if [ ! -f "$SOURCES_DIR/kio-extras-25.08.0.tar.xz" ]; then
        download_with_retry "https://download.kde.org/stable/release-service/25.08.0/src/kio-extras-25.08.0.tar.xz" \
            "$SOURCES_DIR/kio-extras-25.08.0.tar.xz"
    else
        log_info "[SKIP] kio-extras-25.08.0.tar.xz (already exists)"
    fi

    log_info "Tier 9: Plasma Prerequisites downloads complete"

    # Check for any failures
    if [ -s "$FAILED_DOWNLOADS_FILE" ]; then
        log_error "========================================="
        log_error "DOWNLOAD FAILED - The following files could not be downloaded:"
        log_error "========================================="
        while IFS= read -r failed_url; do
            log_error "  - $failed_url"
        done < "$FAILED_DOWNLOADS_FILE"
        log_error "========================================="
        exit 1
    fi

    # Summary
    local downloaded_files=$(ls -1 *.tar.* *.tgz *.patch *.zip 2>/dev/null | wc -l)
    local total_size=$(du -sh . 2>/dev/null | cut -f1)

    echo ""
    log_info "========================================="
    log_info "Download Summary"
    log_info "========================================="
    log_info "LFS Version: $LFS_VERSION"
    log_info "Files downloaded: $downloaded_files"
    log_info "Total size: $total_size"
    log_info "========================================="

    log_info "All sources downloaded successfully!"

    # Create completion checkpoint
    create_global_checkpoint "download-complete" "download" "corvidae-mirrors"

    exit 0
}

# Run main function
main "$@"
