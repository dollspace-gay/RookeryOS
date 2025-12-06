#!/bin/bash
set -euo pipefail

# =============================================================================
# EasyLFS Download Sources Script
# Downloads all LFS packages and patches for LFS 12.4 (systemd + grsecurity)
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
LFS_MIRROR="${LFS_MIRROR:-https://www.linuxfromscratch.org}"
SOURCES_DIR="/sources"
MAX_RETRIES=3
RETRY_DELAY=5
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS:-6}"  # Number of parallel downloads
DOWNLOAD_TIMEOUT=60  # Timeout for slow connections (seconds)
MIN_SPEED=50000     # Minimum speed: 50KB/s (will retry if slower)

# Note: LFS for download-sources points to /sources since we don't have /lfs yet
export LFS="${LFS:-/lfs}"

# Track failed downloads
FAILED_DOWNLOADS_FILE="/tmp/failed_downloads.$$"
: > "$FAILED_DOWNLOADS_FILE"  # Create/truncate file

# Setup logging trap to ensure finalize_logging is called
trap 'finalize_logging $?; rm -f "$FAILED_DOWNLOADS_FILE"' EXIT

# Download with retry and speed monitoring
download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading $output (attempt $attempt/$MAX_RETRIES)..."

        # Use wget with aggressive timeouts and resume support
        # --read-timeout: abort if no data received for 30 seconds
        # --dns-timeout: DNS lookup timeout
        # --continue: resume partial downloads
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

    log_error "Failed to download $url after $MAX_RETRIES attempts"
    return 1
}

# Download a single package (used by parallel jobs)
download_package() {
    local url="$1"
    local filename=$(basename "$url")
    local sources_dir="$2"

    cd "$sources_dir"

    # Optimize URL: use geographic mirror redirector for GNU FTP
    # ftpmirror.gnu.org redirects to closest mirror automatically
    url="${url//ftp.gnu.org/ftpmirror.gnu.org}"

    # Check if file already exists and is valid
    if [ -f "$filename" ]; then
        # Extract expected checksum for THIS file only (not all files)
        expected_checksum=$(grep " $filename\$" md5sums 2>/dev/null | cut -d' ' -f1)
        if [ -n "$expected_checksum" ]; then
            actual_checksum=$(md5sum "$filename" 2>/dev/null | cut -d' ' -f1)
            if [ "$expected_checksum" = "$actual_checksum" ]; then
                echo "[SKIP] $filename (already verified)"
                return 0
            fi
        fi
        # File exists but is invalid or has no expected checksum - remove and re-download
        rm -f "$filename"
    fi

    # Download the package
    if download_with_retry "$url" "$filename"; then
        echo "[OK] $filename"
        return 0
    else
        echo "[FAIL] $filename"
        # Record failure for later reporting
        echo "$url" >> /tmp/failed_downloads.$$
        return 1
    fi
}

# Main function
main() {
    # Initialize logging
    init_logging

    log_info "Starting LFS $LFS_VERSION sources download"
    log_info "Target directory: $SOURCES_DIR"

    # Create sources directory if it doesn't exist
    mkdir -p "$SOURCES_DIR"
    cd "$SOURCES_DIR"

    # Initialize checkpoint system (use SOURCES_DIR as LFS root for this service)
    export CHECKPOINT_DIR="$SOURCES_DIR/.checkpoints"
    init_checkpointing

    # Check if download was already completed successfully
    # But still check for missing BLFS packages that may have been added later
    if should_skip_global_checkpoint "download-complete"; then
        log_info "Base sources already downloaded, checking for missing BLFS packages..."

        # List of required BLFS packages that might be missing
        local missing_blfs=()
        local blfs_packages=(
            "icu4c-77_1-src.tgz"
            "gobject-introspection-1.84.0.tar.xz"
            "vala-0.56.18.tar.xz"
        )

        for pkg in "${blfs_packages[@]}"; do
            if [ ! -f "$pkg" ]; then
                missing_blfs+=("$pkg")
            fi
        done

        if [ ${#missing_blfs[@]} -eq 0 ]; then
            log_info "========================================="
            log_info "All sources already downloaded and verified"
            log_info "========================================="
            exit 0
        else
            log_info "Missing BLFS packages: ${missing_blfs[*]}"
            log_info "Continuing to download missing packages..."
        fi
    fi

    # Download wget-list
    log_info "Downloading package list..."
    local wget_list_url="${LFS_MIRROR}/lfs/downloads/${LFS_VERSION}/wget-list"

    if ! download_with_retry "$wget_list_url" "wget-list"; then
        log_error "Failed to download wget-list"
        exit 1
    fi

    # Download md5sums
    log_info "Downloading MD5 checksums..."
    local md5sums_url="${LFS_MIRROR}/lfs/downloads/${LFS_VERSION}/md5sums"

    if ! download_with_retry "$md5sums_url" "md5sums"; then
        log_error "Failed to download md5sums"
        exit 1
    fi

    # Count total packages
    local total_packages=$(grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | wc -l)
    log_info "Found $total_packages packages to download"
    log_info "Using $PARALLEL_DOWNLOADS parallel downloads"
    log_info "Using ftpmirror.gnu.org for automatic geographic mirror selection"

    # Export functions for parallel execution
    export -f download_with_retry
    export -f download_package
    export -f log_info
    export -f log_warn
    export -f log_error
    export SOURCES_DIR MAX_RETRIES RETRY_DELAY DOWNLOAD_TIMEOUT MIN_SPEED
    export RED GREEN YELLOW NC

    # Download all packages in parallel
    echo ""
    log_info "Starting parallel downloads..."

    # Filter out comments and empty lines, then download in parallel
    # Note: We don't fail immediately here - we collect failures and report at end
    if command -v parallel >/dev/null 2>&1; then
        # Use GNU parallel if available (better progress tracking)
        log_info "Using GNU parallel for downloads"
        grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | \
            parallel -j "$PARALLEL_DOWNLOADS" --line-buffer --tag \
                download_package {} "$SOURCES_DIR" || true
    else
        # Fallback to xargs -P
        log_info "Using xargs for parallel downloads"
        grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | \
            xargs -P "$PARALLEL_DOWNLOADS" -I {} bash -c 'download_package "$@"' _ {} "$SOURCES_DIR" || true
    fi

    echo ""
    log_info "Download phase completed"
    log_info "Total packages: $total_packages"

    # Check for any failures from parallel downloads
    if [ -s "$FAILED_DOWNLOADS_FILE" ]; then
        log_error "========================================="
        log_error "DOWNLOAD FAILED - The following packages could not be downloaded:"
        log_error "========================================="
        while IFS= read -r failed_url; do
            log_error "  - $failed_url"
        done < "$FAILED_DOWNLOADS_FILE"
        log_error "========================================="
        log_error "Please check your network connection and try again."
        log_error "You may need to find alternative mirrors for these packages."
        exit 1
    fi

    # =========================================================================
    # Download additional packages for systemd build
    # =========================================================================
    log_info "Downloading additional packages for systemd..."

    # Track additional package failures
    local additional_failed=()

    # D-Bus (required for systemd)
    # Note: Using Debian mirror as dbus.freedesktop.org is unreliable
    local dbus_url="http://deb.debian.org/debian/pool/main/d/dbus/dbus_1.16.2.orig.tar.xz"
    if [ ! -f "dbus-1.16.2.tar.xz" ]; then
        if ! download_with_retry "$dbus_url" "dbus-1.16.2.tar.xz"; then
            additional_failed+=("$dbus_url (dbus-1.16.2.tar.xz)")
        fi
    else
        log_info "[SKIP] dbus-1.16.2.tar.xz (already exists)"
    fi

    # Linux-firmware (for hardware driver support)
    local firmware_url="https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-20251125.tar.xz"
    if [ ! -f "linux-firmware-20251125.tar.xz" ]; then
        log_info "Downloading linux-firmware (this may take a while, ~600MB)..."
        if ! download_with_retry "$firmware_url" "linux-firmware-20251125.tar.xz"; then
            additional_failed+=("$firmware_url (linux-firmware-20251125.tar.xz)")
        fi
    else
        log_info "[SKIP] linux-firmware-20251125.tar.xz (already exists)"
    fi

    # Nano text editor (user preference over vim)
    local nano_url="https://www.nano-editor.org/dist/v8/nano-8.3.tar.xz"
    if [ ! -f "nano-8.3.tar.xz" ]; then
        log_info "Downloading nano text editor..."
        if ! download_with_retry "$nano_url" "nano-8.3.tar.xz"; then
            additional_failed+=("$nano_url (nano-8.3.tar.xz)")
        fi
    else
        log_info "[SKIP] nano-8.3.tar.xz (already exists)"
    fi

    # =========================================================================
    # Download BLFS packages (Tier 1: Security & Core Utilities)
    # =========================================================================
    log_info "Downloading BLFS packages..."

    # Linux-PAM-1.7.1 (Pluggable Authentication Modules)
    local pam_url="https://github.com/linux-pam/linux-pam/releases/download/v1.7.1/Linux-PAM-1.7.1.tar.xz"
    if [ ! -f "Linux-PAM-1.7.1.tar.xz" ]; then
        log_info "Downloading Linux-PAM..."
        if ! download_with_retry "$pam_url" "Linux-PAM-1.7.1.tar.xz"; then
            additional_failed+=("$pam_url (Linux-PAM-1.7.1.tar.xz)")
        fi
    else
        log_info "[SKIP] Linux-PAM-1.7.1.tar.xz (already exists)"
    fi

    # libgpg-error-1.55 (GnuPG error library - required by libgcrypt)
    local gpgerror_url="https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.55.tar.bz2"
    if [ ! -f "libgpg-error-1.55.tar.bz2" ]; then
        log_info "Downloading libgpg-error..."
        if ! download_with_retry "$gpgerror_url" "libgpg-error-1.55.tar.bz2"; then
            additional_failed+=("$gpgerror_url (libgpg-error-1.55.tar.bz2)")
        fi
    else
        log_info "[SKIP] libgpg-error-1.55.tar.bz2 (already exists)"
    fi

    # libgcrypt-1.11.2 (Cryptography library - required by KDE Frameworks)
    local gcrypt_url="https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.2.tar.bz2"
    if [ ! -f "libgcrypt-1.11.2.tar.bz2" ]; then
        log_info "Downloading libgcrypt..."
        if ! download_with_retry "$gcrypt_url" "libgcrypt-1.11.2.tar.bz2"; then
            additional_failed+=("$gcrypt_url (libgcrypt-1.11.2.tar.bz2)")
        fi
    else
        log_info "[SKIP] libgcrypt-1.11.2.tar.bz2 (already exists)"
    fi

    # sudo-1.9.17p2 (Privilege escalation for authorized users)
    local sudo_url="https://www.sudo.ws/dist/sudo-1.9.17p2.tar.gz"
    if [ ! -f "sudo-1.9.17p2.tar.gz" ]; then
        log_info "Downloading sudo..."
        if ! download_with_retry "$sudo_url" "sudo-1.9.17p2.tar.gz"; then
            additional_failed+=("$sudo_url (sudo-1.9.17p2.tar.gz)")
        fi
    else
        log_info "[SKIP] sudo-1.9.17p2.tar.gz (already exists)"
    fi

    # =========================================================================
    # Polkit dependency chain: pcre2 -> glib2 -> polkit (+ duktape)
    # =========================================================================

    # pcre2-10.45 (required by glib2)
    local pcre2_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.bz2"
    if [ ! -f "pcre2-10.45.tar.bz2" ]; then
        log_info "Downloading pcre2..."
        if ! download_with_retry "$pcre2_url" "pcre2-10.45.tar.bz2"; then
            additional_failed+=("$pcre2_url (pcre2-10.45.tar.bz2)")
        fi
    else
        log_info "[SKIP] pcre2-10.45.tar.bz2 (already exists)"
    fi

    # duktape-2.7.0 (required by polkit)
    local duktape_url="https://duktape.org/duktape-2.7.0.tar.xz"
    if [ ! -f "duktape-2.7.0.tar.xz" ]; then
        log_info "Downloading duktape..."
        if ! download_with_retry "$duktape_url" "duktape-2.7.0.tar.xz"; then
            additional_failed+=("$duktape_url (duktape-2.7.0.tar.xz)")
        fi
    else
        log_info "[SKIP] duktape-2.7.0.tar.xz (already exists)"
    fi

    # ICU-77.1 (recommended for libxml2, required for proper Unicode support)
    local icu_url="https://github.com/unicode-org/icu/releases/download/release-77-1/icu4c-77_1-src.tgz"
    if [ ! -f "icu4c-77_1-src.tgz" ]; then
        log_info "Downloading ICU..."
        if ! download_with_retry "$icu_url" "icu4c-77_1-src.tgz"; then
            additional_failed+=("$icu_url (icu4c-77_1-src.tgz)")
        fi
    else
        log_info "[SKIP] icu4c-77_1-src.tgz (already exists)"
    fi

    # glib-2.84.4 (required by polkit)
    local glib_url="https://download.gnome.org/sources/glib/2.84/glib-2.84.4.tar.xz"
    if [ ! -f "glib-2.84.4.tar.xz" ]; then
        log_info "Downloading glib..."
        if ! download_with_retry "$glib_url" "glib-2.84.4.tar.xz"; then
            additional_failed+=("$glib_url (glib-2.84.4.tar.xz)")
        fi
    else
        log_info "[SKIP] glib-2.84.4.tar.xz (already exists)"
    fi

    # gobject-introspection-1.84.0 (recommended for glib2/polkit)
    local gi_url="https://download.gnome.org/sources/gobject-introspection/1.84/gobject-introspection-1.84.0.tar.xz"
    if [ ! -f "gobject-introspection-1.84.0.tar.xz" ]; then
        log_info "Downloading gobject-introspection..."
        if ! download_with_retry "$gi_url" "gobject-introspection-1.84.0.tar.xz"; then
            additional_failed+=("$gi_url (gobject-introspection-1.84.0.tar.xz)")
        fi
    else
        log_info "[SKIP] gobject-introspection-1.84.0.tar.xz (already exists)"
    fi

    # polkit-126 (privilege authorization)
    local polkit_url="https://github.com/polkit-org/polkit/archive/126/polkit-126.tar.gz"
    if [ ! -f "polkit-126.tar.gz" ]; then
        log_info "Downloading polkit..."
        if ! download_with_retry "$polkit_url" "polkit-126.tar.gz"; then
            additional_failed+=("$polkit_url (polkit-126.tar.gz)")
        fi
    else
        log_info "[SKIP] polkit-126.tar.gz (already exists)"
    fi

    # CMake-4.1.0 (build tool - needed by c-ares, libproxy, etc.)
    local cmake_url="https://cmake.org/files/v4.1/cmake-4.1.0.tar.gz"
    if [ ! -f "cmake-4.1.0.tar.gz" ]; then
        log_info "Downloading cmake..."
        if ! download_with_retry "$cmake_url" "cmake-4.1.0.tar.gz"; then
            additional_failed+=("$cmake_url (cmake-4.1.0.tar.gz)")
        fi
    else
        log_info "[SKIP] cmake-4.1.0.tar.gz (already exists)"
    fi

    # =========================================================================
    # BLFS Tier 2: Networking & Protocols
    # =========================================================================
    log_info "Downloading BLFS Tier 2 packages (Networking)..."

    # --- Foundation packages (no dependencies) ---

    # libmnl-1.0.5 (Netfilter minimalistic library)
    local libmnl_url="https://netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2"
    if [ ! -f "libmnl-1.0.5.tar.bz2" ]; then
        log_info "Downloading libmnl..."
        if ! download_with_retry "$libmnl_url" "libmnl-1.0.5.tar.bz2"; then
            additional_failed+=("$libmnl_url (libmnl-1.0.5.tar.bz2)")
        fi
    else
        log_info "[SKIP] libmnl-1.0.5.tar.bz2 (already exists)"
    fi

    # libndp-1.9 (Neighbor Discovery Protocol library)
    # Note: libndp is from github releases
    local libndp_url="https://github.com/jpirko/libndp/archive/v1.9/libndp-1.9.tar.gz"
    if [ ! -f "libndp-1.9.tar.gz" ]; then
        log_info "Downloading libndp..."
        if ! download_with_retry "$libndp_url" "libndp-1.9.tar.gz"; then
            additional_failed+=("$libndp_url (libndp-1.9.tar.gz)")
        fi
    else
        log_info "[SKIP] libndp-1.9.tar.gz (already exists)"
    fi

    # libevent-2.1.12 (Event notification library)
    local libevent_url="https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"
    if [ ! -f "libevent-2.1.12-stable.tar.gz" ]; then
        log_info "Downloading libevent..."
        if ! download_with_retry "$libevent_url" "libevent-2.1.12-stable.tar.gz"; then
            additional_failed+=("$libevent_url (libevent-2.1.12-stable.tar.gz)")
        fi
    else
        log_info "[SKIP] libevent-2.1.12-stable.tar.gz (already exists)"
    fi

    # c-ares-1.34.5 (Async DNS resolver)
    local cares_url="https://github.com/c-ares/c-ares/releases/download/v1.34.5/c-ares-1.34.5.tar.gz"
    if [ ! -f "c-ares-1.34.5.tar.gz" ]; then
        log_info "Downloading c-ares..."
        if ! download_with_retry "$cares_url" "c-ares-1.34.5.tar.gz"; then
            additional_failed+=("$cares_url (c-ares-1.34.5.tar.gz)")
        fi
    else
        log_info "[SKIP] c-ares-1.34.5.tar.gz (already exists)"
    fi

    # libdaemon-0.14 (Unix daemon library)
    local libdaemon_url="https://0pointer.de/lennart/projects/libdaemon/libdaemon-0.14.tar.gz"
    if [ ! -f "libdaemon-0.14.tar.gz" ]; then
        log_info "Downloading libdaemon..."
        if ! download_with_retry "$libdaemon_url" "libdaemon-0.14.tar.gz"; then
            additional_failed+=("$libdaemon_url (libdaemon-0.14.tar.gz)")
        fi
    else
        log_info "[SKIP] libdaemon-0.14.tar.gz (already exists)"
    fi

    # libpcap-1.10.5 (Packet capture library)
    local libpcap_url="https://www.tcpdump.org/release/libpcap-1.10.5.tar.gz"
    if [ ! -f "libpcap-1.10.5.tar.gz" ]; then
        log_info "Downloading libpcap..."
        if ! download_with_retry "$libpcap_url" "libpcap-1.10.5.tar.gz"; then
            additional_failed+=("$libpcap_url (libpcap-1.10.5.tar.gz)")
        fi
    else
        log_info "[SKIP] libpcap-1.10.5.tar.gz (already exists)"
    fi

    # libunistring-1.3 (Unicode string library - needed by libidn2)
    # Use ftpmirror for geographic mirror selection (ftp.gnu.org often times out)
    local libunistring_url="https://ftpmirror.gnu.org/gnu/libunistring/libunistring-1.3.tar.xz"
    if [ ! -f "libunistring-1.3.tar.xz" ]; then
        log_info "Downloading libunistring..."
        if ! download_with_retry "$libunistring_url" "libunistring-1.3.tar.xz"; then
            additional_failed+=("$libunistring_url (libunistring-1.3.tar.xz)")
        fi
    else
        log_info "[SKIP] libunistring-1.3.tar.xz (already exists)"
    fi

    # libnl-3.11.0 (Netlink library - needed by wpa_supplicant, NetworkManager)
    local libnl_url="https://github.com/thom311/libnl/releases/download/libnl3_11_0/libnl-3.11.0.tar.gz"
    if [ ! -f "libnl-3.11.0.tar.gz" ]; then
        log_info "Downloading libnl..."
        if ! download_with_retry "$libnl_url" "libnl-3.11.0.tar.gz"; then
            additional_failed+=("$libnl_url (libnl-3.11.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libnl-3.11.0.tar.gz (already exists)"
    fi

    # libxml2-2.14.5 (XML parser library - required by libxslt)
    local libxml2_url="https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.5.tar.xz"
    if [ ! -f "libxml2-2.14.5.tar.xz" ]; then
        log_info "Downloading libxml2..."
        if ! download_with_retry "$libxml2_url" "libxml2-2.14.5.tar.xz"; then
            additional_failed+=("$libxml2_url (libxml2-2.14.5.tar.xz)")
        fi
    else
        log_info "[SKIP] libxml2-2.14.5.tar.xz (already exists)"
    fi

    # libxslt-1.1.43 (XSLT processor)
    local libxslt_url="https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz"
    if [ ! -f "libxslt-1.1.43.tar.xz" ]; then
        log_info "Downloading libxslt..."
        if ! download_with_retry "$libxslt_url" "libxslt-1.1.43.tar.xz"; then
            additional_failed+=("$libxslt_url (libxslt-1.1.43.tar.xz)")
        fi
    else
        log_info "[SKIP] libxslt-1.1.43.tar.xz (already exists)"
    fi

    # dhcpcd-10.2.4 (DHCP client)
    local dhcpcd_url="https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.2.4/dhcpcd-10.2.4.tar.xz"
    if [ ! -f "dhcpcd-10.2.4.tar.xz" ]; then
        log_info "Downloading dhcpcd..."
        if ! download_with_retry "$dhcpcd_url" "dhcpcd-10.2.4.tar.xz"; then
            additional_failed+=("$dhcpcd_url (dhcpcd-10.2.4.tar.xz)")
        fi
    else
        log_info "[SKIP] dhcpcd-10.2.4.tar.xz (already exists)"
    fi

    # --- SSL/TLS stack ---

    # libtasn1-4.20.0 (ASN.1 library - needed by GnuTLS)
    local libtasn1_url="https://ftpmirror.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
    if [ ! -f "libtasn1-4.20.0.tar.gz" ]; then
        log_info "Downloading libtasn1..."
        if ! download_with_retry "$libtasn1_url" "libtasn1-4.20.0.tar.gz"; then
            additional_failed+=("$libtasn1_url (libtasn1-4.20.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libtasn1-4.20.0.tar.gz (already exists)"
    fi

    # nettle-3.10.2 (Crypto library - needed by GnuTLS)
    local nettle_url="https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz"
    if [ ! -f "nettle-3.10.2.tar.gz" ]; then
        log_info "Downloading nettle..."
        if ! download_with_retry "$nettle_url" "nettle-3.10.2.tar.gz"; then
            additional_failed+=("$nettle_url (nettle-3.10.2.tar.gz)")
        fi
    else
        log_info "[SKIP] nettle-3.10.2.tar.gz (already exists)"
    fi

    # make-ca-1.16.1 (CA certificates management)
    local makeca_url="https://github.com/lfs-book/make-ca/archive/v1.16.1/make-ca-1.16.1.tar.gz"
    if [ ! -f "make-ca-1.16.1.tar.gz" ]; then
        log_info "Downloading make-ca..."
        if ! download_with_retry "$makeca_url" "make-ca-1.16.1.tar.gz"; then
            additional_failed+=("$makeca_url (make-ca-1.16.1.tar.gz)")
        fi
    else
        log_info "[SKIP] make-ca-1.16.1.tar.gz (already exists)"
    fi

    # p11-kit-0.25.5 (PKCS#11 library - needed by GnuTLS)
    local p11kit_url="https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
    if [ ! -f "p11-kit-0.25.5.tar.xz" ]; then
        log_info "Downloading p11-kit..."
        if ! download_with_retry "$p11kit_url" "p11-kit-0.25.5.tar.xz"; then
            additional_failed+=("$p11kit_url (p11-kit-0.25.5.tar.xz)")
        fi
    else
        log_info "[SKIP] p11-kit-0.25.5.tar.xz (already exists)"
    fi

    # GnuTLS-3.8.10 (TLS library)
    local gnutls_url="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.10.tar.xz"
    if [ ! -f "gnutls-3.8.10.tar.xz" ]; then
        log_info "Downloading GnuTLS..."
        if ! download_with_retry "$gnutls_url" "gnutls-3.8.10.tar.xz"; then
            additional_failed+=("$gnutls_url (gnutls-3.8.10.tar.xz)")
        fi
    else
        log_info "[SKIP] gnutls-3.8.10.tar.xz (already exists)"
    fi

    # --- Internationalization ---

    # libidn2-2.3.8 (IDN library - needed by libpsl, wget)
    local libidn2_url="https://ftpmirror.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz"
    if [ ! -f "libidn2-2.3.8.tar.gz" ]; then
        log_info "Downloading libidn2..."
        if ! download_with_retry "$libidn2_url" "libidn2-2.3.8.tar.gz"; then
            additional_failed+=("$libidn2_url (libidn2-2.3.8.tar.gz)")
        fi
    else
        log_info "[SKIP] libidn2-2.3.8.tar.gz (already exists)"
    fi

    # libpsl-0.21.5 (Public Suffix List library - needed by curl, wget)
    local libpsl_url="https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz"
    if [ ! -f "libpsl-0.21.5.tar.gz" ]; then
        log_info "Downloading libpsl..."
        if ! download_with_retry "$libpsl_url" "libpsl-0.21.5.tar.gz"; then
            additional_failed+=("$libpsl_url (libpsl-0.21.5.tar.gz)")
        fi
    else
        log_info "[SKIP] libpsl-0.21.5.tar.gz (already exists)"
    fi

    # --- Network services ---

    # iptables-1.8.11 (Firewall)
    local iptables_url="https://www.netfilter.org/projects/iptables/files/iptables-1.8.11.tar.xz"
    if [ ! -f "iptables-1.8.11.tar.xz" ]; then
        log_info "Downloading iptables..."
        if ! download_with_retry "$iptables_url" "iptables-1.8.11.tar.xz"; then
            additional_failed+=("$iptables_url (iptables-1.8.11.tar.xz)")
        fi
    else
        log_info "[SKIP] iptables-1.8.11.tar.xz (already exists)"
    fi

    # avahi-0.8 (mDNS/DNS-SD)
    local avahi_url="https://github.com/lathiat/avahi/releases/download/v0.8/avahi-0.8.tar.gz"
    if [ ! -f "avahi-0.8.tar.gz" ]; then
        log_info "Downloading avahi..."
        if ! download_with_retry "$avahi_url" "avahi-0.8.tar.gz"; then
            additional_failed+=("$avahi_url (avahi-0.8.tar.gz)")
        fi
    else
        log_info "[SKIP] avahi-0.8.tar.gz (already exists)"
    fi

    # avahi IPv6 race condition fix patch
    local avahi_patch_url="https://www.linuxfromscratch.org/patches/blfs/12.4/avahi-0.8-ipv6_race_condition_fix-1.patch"
    if [ ! -f "avahi-0.8-ipv6_race_condition_fix-1.patch" ]; then
        log_info "Downloading avahi patch..."
        if ! download_with_retry "$avahi_patch_url" "avahi-0.8-ipv6_race_condition_fix-1.patch"; then
            additional_failed+=("$avahi_patch_url (avahi-0.8-ipv6_race_condition_fix-1.patch)")
        fi
    else
        log_info "[SKIP] avahi-0.8-ipv6_race_condition_fix-1.patch (already exists)"
    fi

    # wpa_supplicant-2.11 (WiFi client)
    local wpasupplicant_url="https://w1.fi/releases/wpa_supplicant-2.11.tar.gz"
    if [ ! -f "wpa_supplicant-2.11.tar.gz" ]; then
        log_info "Downloading wpa_supplicant..."
        if ! download_with_retry "$wpasupplicant_url" "wpa_supplicant-2.11.tar.gz"; then
            additional_failed+=("$wpasupplicant_url (wpa_supplicant-2.11.tar.gz)")
        fi
    else
        log_info "[SKIP] wpa_supplicant-2.11.tar.gz (already exists)"
    fi

    # --- HTTP clients ---

    # curl-8.15.0 (HTTP client library)
    local curl_url="https://curl.se/download/curl-8.15.0.tar.xz"
    if [ ! -f "curl-8.15.0.tar.xz" ]; then
        log_info "Downloading curl..."
        if ! download_with_retry "$curl_url" "curl-8.15.0.tar.xz"; then
            additional_failed+=("$curl_url (curl-8.15.0.tar.xz)")
        fi
    else
        log_info "[SKIP] curl-8.15.0.tar.xz (already exists)"
    fi

    # --- libproxy and dependencies ---

    # Vala-0.56.18 (Vala compiler - optional for libproxy)
    local vala_url="https://download.gnome.org/sources/vala/0.56/vala-0.56.18.tar.xz"
    if [ ! -f "vala-0.56.18.tar.xz" ]; then
        log_info "Downloading Vala..."
        if ! download_with_retry "$vala_url" "vala-0.56.18.tar.xz"; then
            additional_failed+=("$vala_url (vala-0.56.18.tar.xz)")
        fi
    else
        log_info "[SKIP] vala-0.56.18.tar.xz (already exists)"
    fi

    # gsettings-desktop-schemas-48.0 (GNOME settings schemas)
    local gsettings_url="https://download.gnome.org/sources/gsettings-desktop-schemas/48/gsettings-desktop-schemas-48.0.tar.xz"
    if [ ! -f "gsettings-desktop-schemas-48.0.tar.xz" ]; then
        log_info "Downloading gsettings-desktop-schemas..."
        if ! download_with_retry "$gsettings_url" "gsettings-desktop-schemas-48.0.tar.xz"; then
            additional_failed+=("$gsettings_url (gsettings-desktop-schemas-48.0.tar.xz)")
        fi
    else
        log_info "[SKIP] gsettings-desktop-schemas-48.0.tar.xz (already exists)"
    fi

    # libproxy-0.5.10 (Proxy configuration library)
    local libproxy_url="https://github.com/libproxy/libproxy/archive/0.5.10/libproxy-0.5.10.tar.gz"
    if [ ! -f "libproxy-0.5.10.tar.gz" ]; then
        log_info "Downloading libproxy..."
        if ! download_with_retry "$libproxy_url" "libproxy-0.5.10.tar.gz"; then
            additional_failed+=("$libproxy_url (libproxy-0.5.10.tar.gz)")
        fi
    else
        log_info "[SKIP] libproxy-0.5.10.tar.gz (already exists)"
    fi

    # --- High-level network tools ---

    # wget-1.25.0 (HTTP/FTP downloader)
    local wget_url="https://ftpmirror.gnu.org/gnu/wget/wget-1.25.0.tar.gz"
    if [ ! -f "wget-1.25.0.tar.gz" ]; then
        log_info "Downloading wget..."
        if ! download_with_retry "$wget_url" "wget-1.25.0.tar.gz"; then
            additional_failed+=("$wget_url (wget-1.25.0.tar.gz)")
        fi
    else
        log_info "[SKIP] wget-1.25.0.tar.gz (already exists)"
    fi

    # NetworkManager-1.54.0 (Network management)
    local nm_url="https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.54.0/downloads/NetworkManager-1.54.0.tar.xz"
    if [ ! -f "NetworkManager-1.54.0.tar.xz" ]; then
        log_info "Downloading NetworkManager..."
        if ! download_with_retry "$nm_url" "NetworkManager-1.54.0.tar.xz"; then
            additional_failed+=("$nm_url (NetworkManager-1.54.0.tar.xz)")
        fi
    else
        log_info "[SKIP] NetworkManager-1.54.0.tar.xz (already exists)"
    fi

    # #####################################################################
    # BLFS Tier 3: Graphics Foundation (X11/Wayland)
    # #####################################################################
    log_info "Downloading BLFS Tier 3 packages (Graphics Foundation)..."

    # --- Xorg Build Environment ---

    # util-macros-1.20.2 (Xorg build macros)
    local utilmacros_url="https://www.x.org/pub/individual/util/util-macros-1.20.2.tar.xz"
    if [ ! -f "util-macros-1.20.2.tar.xz" ]; then
        log_info "Downloading util-macros..."
        if ! download_with_retry "$utilmacros_url" "util-macros-1.20.2.tar.xz"; then
            additional_failed+=("$utilmacros_url (util-macros-1.20.2.tar.xz)")
        fi
    else
        log_info "[SKIP] util-macros-1.20.2.tar.xz (already exists)"
    fi

    # xorgproto-2024.1 (Xorg protocol headers)
    local xorgproto_url="https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2024.1.tar.xz"
    if [ ! -f "xorgproto-2024.1.tar.xz" ]; then
        log_info "Downloading xorgproto..."
        if ! download_with_retry "$xorgproto_url" "xorgproto-2024.1.tar.xz"; then
            additional_failed+=("$xorgproto_url (xorgproto-2024.1.tar.xz)")
        fi
    else
        log_info "[SKIP] xorgproto-2024.1.tar.xz (already exists)"
    fi

    # --- Wayland ---

    # Wayland-1.24.0
    local wayland_url="https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.24.0/downloads/wayland-1.24.0.tar.xz"
    if [ ! -f "wayland-1.24.0.tar.xz" ]; then
        log_info "Downloading Wayland..."
        if ! download_with_retry "$wayland_url" "wayland-1.24.0.tar.xz"; then
            additional_failed+=("$wayland_url (wayland-1.24.0.tar.xz)")
        fi
    else
        log_info "[SKIP] wayland-1.24.0.tar.xz (already exists)"
    fi

    # Wayland-Protocols-1.45
    local wayland_protocols_url="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.45/downloads/wayland-protocols-1.45.tar.xz"
    if [ ! -f "wayland-protocols-1.45.tar.xz" ]; then
        log_info "Downloading Wayland-Protocols..."
        if ! download_with_retry "$wayland_protocols_url" "wayland-protocols-1.45.tar.xz"; then
            additional_failed+=("$wayland_protocols_url (wayland-protocols-1.45.tar.xz)")
        fi
    else
        log_info "[SKIP] wayland-protocols-1.45.tar.xz (already exists)"
    fi

    # --- XCB Libraries ---

    # libXau-1.0.12 (X Authorization)
    local libxau_url="https://www.x.org/pub/individual/lib/libXau-1.0.12.tar.xz"
    if [ ! -f "libXau-1.0.12.tar.xz" ]; then
        log_info "Downloading libXau..."
        if ! download_with_retry "$libxau_url" "libXau-1.0.12.tar.xz"; then
            additional_failed+=("$libxau_url (libXau-1.0.12.tar.xz)")
        fi
    else
        log_info "[SKIP] libXau-1.0.12.tar.xz (already exists)"
    fi

    # libXdmcp-1.1.5 (X Display Manager Control Protocol)
    local libxdmcp_url="https://www.x.org/pub/individual/lib/libXdmcp-1.1.5.tar.xz"
    if [ ! -f "libXdmcp-1.1.5.tar.xz" ]; then
        log_info "Downloading libXdmcp..."
        if ! download_with_retry "$libxdmcp_url" "libXdmcp-1.1.5.tar.xz"; then
            additional_failed+=("$libxdmcp_url (libXdmcp-1.1.5.tar.xz)")
        fi
    else
        log_info "[SKIP] libXdmcp-1.1.5.tar.xz (already exists)"
    fi

    # xcb-proto-1.17.0 (XCB protocol descriptions)
    local xcbproto_url="https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.17.0.tar.xz"
    if [ ! -f "xcb-proto-1.17.0.tar.xz" ]; then
        log_info "Downloading xcb-proto..."
        if ! download_with_retry "$xcbproto_url" "xcb-proto-1.17.0.tar.xz"; then
            additional_failed+=("$xcbproto_url (xcb-proto-1.17.0.tar.xz)")
        fi
    else
        log_info "[SKIP] xcb-proto-1.17.0.tar.xz (already exists)"
    fi

    # libxcb-1.17.0 (X C Binding)
    local libxcb_url="https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz"
    if [ ! -f "libxcb-1.17.0.tar.xz" ]; then
        log_info "Downloading libxcb..."
        if ! download_with_retry "$libxcb_url" "libxcb-1.17.0.tar.xz"; then
            additional_failed+=("$libxcb_url (libxcb-1.17.0.tar.xz)")
        fi
    else
        log_info "[SKIP] libxcb-1.17.0.tar.xz (already exists)"
    fi

    # --- Graphics Libraries ---

    # FreeType-2.13.3 (TrueType font rendering - required by libXfont2)
    local freetype_url="https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz"
    if [ ! -f "freetype-2.13.3.tar.xz" ]; then
        log_info "Downloading FreeType..."
        if ! download_with_retry "$freetype_url" "freetype-2.13.3.tar.xz"; then
            additional_failed+=("$freetype_url (freetype-2.13.3.tar.xz)")
        fi
    else
        log_info "[SKIP] freetype-2.13.3.tar.xz (already exists)"
    fi

    # Fontconfig-2.17.1 (font configuration - required by libXft)
    local fontconfig_url="https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.17.1/fontconfig-2.17.1.tar.xz"
    if [ ! -f "fontconfig-2.17.1.tar.xz" ]; then
        log_info "Downloading Fontconfig..."
        if ! download_with_retry "$fontconfig_url" "fontconfig-2.17.1.tar.xz"; then
            additional_failed+=("$fontconfig_url (fontconfig-2.17.1.tar.xz)")
        fi
    else
        log_info "[SKIP] fontconfig-2.17.1.tar.xz (already exists)"
    fi

    # Pixman-0.46.4 (Pixel manipulation library)
    local pixman_url="https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
    if [ ! -f "pixman-0.46.4.tar.gz" ]; then
        log_info "Downloading Pixman..."
        if ! download_with_retry "$pixman_url" "pixman-0.46.4.tar.gz"; then
            additional_failed+=("$pixman_url (pixman-0.46.4.tar.gz)")
        fi
    else
        log_info "[SKIP] pixman-0.46.4.tar.gz (already exists)"
    fi

    # libdrm-2.4.125 (Direct Rendering Manager)
    local libdrm_url="https://dri.freedesktop.org/libdrm/libdrm-2.4.125.tar.xz"
    if [ ! -f "libdrm-2.4.125.tar.xz" ]; then
        log_info "Downloading libdrm..."
        if ! download_with_retry "$libdrm_url" "libdrm-2.4.125.tar.xz"; then
            additional_failed+=("$libdrm_url (libdrm-2.4.125.tar.xz)")
        fi
    else
        log_info "[SKIP] libdrm-2.4.125.tar.xz (already exists)"
    fi

    # libxcvt-0.1.3 (VESA CVT standard timing modelines)
    local libxcvt_url="https://www.x.org/pub/individual/lib/libxcvt-0.1.3.tar.xz"
    if [ ! -f "libxcvt-0.1.3.tar.xz" ]; then
        log_info "Downloading libxcvt..."
        if ! download_with_retry "$libxcvt_url" "libxcvt-0.1.3.tar.xz"; then
            additional_failed+=("$libxcvt_url (libxcvt-0.1.3.tar.xz)")
        fi
    else
        log_info "[SKIP] libxcvt-0.1.3.tar.xz (already exists)"
    fi

    # --- Vulkan ---

    # Vulkan-Headers-1.4.321
    local vulkan_headers_url="https://github.com/KhronosGroup/Vulkan-Headers/archive/v1.4.321/Vulkan-Headers-1.4.321.tar.gz"
    if [ ! -f "Vulkan-Headers-1.4.321.tar.gz" ]; then
        log_info "Downloading Vulkan-Headers..."
        if ! download_with_retry "$vulkan_headers_url" "Vulkan-Headers-1.4.321.tar.gz"; then
            additional_failed+=("$vulkan_headers_url (Vulkan-Headers-1.4.321.tar.gz)")
        fi
    else
        log_info "[SKIP] Vulkan-Headers-1.4.321.tar.gz (already exists)"
    fi

    # SPIRV-Headers (required by SPIRV-Tools)
    local spirv_headers_url="https://github.com/KhronosGroup/SPIRV-Headers/archive/vulkan-sdk-1.4.321.0/SPIRV-Headers-1.4.321.0.tar.gz"
    if [ ! -f "SPIRV-Headers-1.4.321.0.tar.gz" ]; then
        log_info "Downloading SPIRV-Headers..."
        if ! download_with_retry "$spirv_headers_url" "SPIRV-Headers-1.4.321.0.tar.gz"; then
            additional_failed+=("$spirv_headers_url (SPIRV-Headers-1.4.321.0.tar.gz)")
        fi
    else
        log_info "[SKIP] SPIRV-Headers-1.4.321.0.tar.gz (already exists)"
    fi

    # SPIRV-Tools-1.4.321.0
    local spirv_tools_url="https://github.com/KhronosGroup/SPIRV-Tools/archive/vulkan-sdk-1.4.321.0/SPIRV-Tools-1.4.321.0.tar.gz"
    if [ ! -f "SPIRV-Tools-1.4.321.0.tar.gz" ]; then
        log_info "Downloading SPIRV-Tools..."
        if ! download_with_retry "$spirv_tools_url" "SPIRV-Tools-1.4.321.0.tar.gz"; then
            additional_failed+=("$spirv_tools_url (SPIRV-Tools-1.4.321.0.tar.gz)")
        fi
    else
        log_info "[SKIP] SPIRV-Tools-1.4.321.0.tar.gz (already exists)"
    fi

    # glslang-15.4.0 (GLSL compiler)
    local glslang_url="https://github.com/KhronosGroup/glslang/archive/15.4.0/glslang-15.4.0.tar.gz"
    if [ ! -f "glslang-15.4.0.tar.gz" ]; then
        log_info "Downloading glslang..."
        if ! download_with_retry "$glslang_url" "glslang-15.4.0.tar.gz"; then
            additional_failed+=("$glslang_url (glslang-15.4.0.tar.gz)")
        fi
    else
        log_info "[SKIP] glslang-15.4.0.tar.gz (already exists)"
    fi

    # Vulkan-Loader-1.4.321
    local vulkan_loader_url="https://github.com/KhronosGroup/Vulkan-Loader/archive/v1.4.321/Vulkan-Loader-1.4.321.tar.gz"
    if [ ! -f "Vulkan-Loader-1.4.321.tar.gz" ]; then
        log_info "Downloading Vulkan-Loader..."
        if ! download_with_retry "$vulkan_loader_url" "Vulkan-Loader-1.4.321.tar.gz"; then
            additional_failed+=("$vulkan_loader_url (Vulkan-Loader-1.4.321.tar.gz)")
        fi
    else
        log_info "[SKIP] Vulkan-Loader-1.4.321.tar.gz (already exists)"
    fi

    # --- Xorg Libraries (32 packages) ---
    log_info "Downloading Xorg Libraries..."

    # Define all Xorg Library packages (from BLFS lib-7.md5)
    # Most packages available on Void Linux mirror
    # Special packages (xtrans, libFS, libXpresent) use GitLab as .tar.gz
    local xorg_lib_packages=(
        "libX11-1.8.12.tar.xz"
        "libXext-1.3.6.tar.xz"
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
    )

    # Use Void Linux sources mirror (xorg.freedesktop.org is unreliable)
    # URL pattern: https://sources.voidlinux.org/<package-name>/<filename>
    for pkg in "${xorg_lib_packages[@]}"; do
        if [ ! -f "$pkg" ] || [ ! -s "$pkg" ]; then
            rm -f "$pkg"  # Remove 0-byte files
            # Extract package name without extension (e.g., "libX11-1.8.12" from "libX11-1.8.12.tar.xz")
            local pkg_name="${pkg%.tar.*}"
            local void_url="https://sources.voidlinux.org/${pkg_name}/${pkg}"
            log_info "Downloading $pkg..."
            if ! download_with_retry "$void_url" "$pkg"; then
                additional_failed+=("$void_url ($pkg)")
            fi
        else
            log_info "[SKIP] $pkg (already exists)"
        fi
    done

    # Download special packages from GitLab (not available on Void Linux mirror)
    # These need autoreconf during build as they come from git archives
    log_info "Downloading special Xorg packages from GitLab..."

    # xtrans - from GitLab freedesktop
    if [ ! -f "xtrans-1.6.0.tar.gz" ] || [ ! -s "xtrans-1.6.0.tar.gz" ]; then
        rm -f "xtrans-1.6.0.tar.gz" "xtrans-1.6.0.tar.xz"
        log_info "Downloading xtrans-1.6.0.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libxtrans/-/archive/xtrans-1.6.0/libxtrans-xtrans-1.6.0.tar.gz" "xtrans-1.6.0.tar.gz"; then
            additional_failed+=("xtrans-1.6.0.tar.gz")
        fi
    else
        log_info "[SKIP] xtrans-1.6.0.tar.gz (already exists)"
    fi

    # libFS - from GitLab freedesktop
    if [ ! -f "libFS-1.0.10.tar.gz" ] || [ ! -s "libFS-1.0.10.tar.gz" ]; then
        rm -f "libFS-1.0.10.tar.gz" "libFS-1.0.10.tar.xz"
        log_info "Downloading libFS-1.0.10.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libfs/-/archive/libFS-1.0.10/libfs-libFS-1.0.10.tar.gz" "libFS-1.0.10.tar.gz"; then
            additional_failed+=("libFS-1.0.10.tar.gz")
        fi
    else
        log_info "[SKIP] libFS-1.0.10.tar.gz (already exists)"
    fi

    # libXpresent - from GitLab freedesktop
    if [ ! -f "libXpresent-1.0.1.tar.gz" ] || [ ! -s "libXpresent-1.0.1.tar.gz" ]; then
        rm -f "libXpresent-1.0.1.tar.gz" "libXpresent-1.0.1.tar.xz"
        log_info "Downloading libXpresent-1.0.1.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libxpresent/-/archive/libXpresent-1.0.1/libxpresent-libXpresent-1.0.1.tar.gz" "libXpresent-1.0.1.tar.gz"; then
            additional_failed+=("libXpresent-1.0.1.tar.gz")
        fi
    else
        log_info "[SKIP] libXpresent-1.0.1.tar.gz (already exists)"
    fi

    # Check for additional package failures
    if [ ${#additional_failed[@]} -gt 0 ]; then
        log_error "========================================="
        log_error "DOWNLOAD FAILED - The following additional packages could not be downloaded:"
        log_error "========================================="
        for failed in "${additional_failed[@]}"; do
            log_error "  - $failed"
        done
        log_error "========================================="
        log_error "These packages are required for the systemd build."
        log_error "Please check your network connection and try again."
        exit 1
    fi

    # Verify checksums (only for LFS packages, not additional ones)
    log_info "Verifying MD5 checksums for LFS packages..."

    if md5sum -c md5sums 2>&1 | tee checksum-verify.log; then
        log_info "All LFS package checksums verified successfully!"
    else
        log_error "Some checksums failed verification!"
        log_error "Check checksum-verify.log for details"
        exit 1
    fi

    # Summary
    # Count all downloaded files (tarballs and patches)
    local downloaded_files=$(ls -1 *.tar.* *.tgz *.patch 2>/dev/null | wc -l)
    local total_size=$(du -sh . | cut -f1)

    echo ""
    log_info "========================================="
    log_info "Download Summary"
    log_info "========================================="
    log_info "LFS Version: $LFS_VERSION"
    log_info "Files downloaded: $downloaded_files/$total_packages"
    log_info "Total size: $total_size"
    log_info "Checksum verification: PASSED"
    log_info "========================================="

    # Check if all files were downloaded
    if [ "$downloaded_files" -lt "$total_packages" ]; then
        local missing=$((total_packages - downloaded_files))
        log_warn "Warning: $missing packages failed to download"
        exit 1
    fi

    log_info "All sources downloaded successfully!"

    # Create a global checkpoint using md5sums file hash
    # This ensures if the LFS version changes, downloads will re-run
    local md5sums_hash=$(md5sum md5sums | cut -d' ' -f1)
    create_global_checkpoint "download-complete" "download" "$md5sums_hash"

    exit 0
}

# Run main function
main "$@"
