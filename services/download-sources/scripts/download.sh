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
