#!/bin/bash
set -euo pipefail

# =============================================================================
# RookeryOS Download Sources Script
# Downloads ALL packages from Corvidae mirror
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
DOWNLOAD_TIMEOUT=300

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

    # Fetch directory listing from mirror
    log_info "Fetching file list from mirror..."

    # Fetch HTML and extract filenames
    # Uses GNU grep (-oE for extended regex with -o output)
    FILE_LIST=$(wget -q -O - "$MIRROR/" | \
        grep -oE 'href="[^"]+\.(tar\.gz|tar\.xz|tar\.bz2|tar\.lz|tgz|patch|zip)"' | \
        sed 's/href="//;s/"$//' | \
        sort -u)

    if [ -z "$FILE_LIST" ]; then
        log_error "Failed to fetch file list from mirror"
        exit 1
    fi

    TOTAL_FILES=$(echo "$FILE_LIST" | wc -l)
    log_info "Found $TOTAL_FILES files on mirror"

    # Download all files
    local failed=0
    local downloaded=0
    local skipped=0
    local current=0

    while IFS= read -r filename; do
        ((current++))
        log_info "[$current/$TOTAL_FILES] Processing: $filename"

        if [ -f "$SOURCES_DIR/$filename" ]; then
            log_info "[SKIP] $filename (already exists)"
            ((skipped++))
        elif download_with_retry "$filename"; then
            ((downloaded++))
        else
            ((failed++))
        fi
    done <<< "$FILE_LIST"

    log_info "=========================================="
    log_info "Download Complete!"
    log_info "=========================================="
    log_info "Total files: $TOTAL_FILES"
    log_info "Downloaded: $downloaded"
    log_info "Skipped (existing): $skipped"
    log_info "Failed: $failed"
    log_info "=========================================="

    if [ $failed -gt 0 ]; then
        log_warn "$failed files failed to download"
        exit 1
    fi
}

main "$@"
