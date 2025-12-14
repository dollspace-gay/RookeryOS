#!/bin/bash
set -euo pipefail

# =============================================================================
# RookeryOS Download Sources Script
# Downloads ALL packages from Corvidae mirror (PARALLEL)
# =============================================================================

# Load common utilities
COMMON_DIR="/usr/local/lib/rookery-common"
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
RETRY_DELAY=2

# Parallel download settings - tune for your connection
# Starlink/fast connections can handle 8-16 parallel downloads
PARALLEL_JOBS="${PARALLEL_JOBS:-10}"

# Corvidae Mirror - single source for all packages
MIRROR="http://corvidae.social/RookerySource"

# Note: ROOKERY for download-sources points to /sources since we don't have /rookery yet
export ROOKERY="${ROOKERY:-/rookery}"

# Export for use in subprocesses
export SOURCES_DIR MIRROR MAX_RETRIES RETRY_DELAY

# Setup logging trap
trap 'finalize_logging $?' EXIT

# =============================================================================
# Download single file (called in parallel)
# =============================================================================
download_single() {
    local filename="$1"
    local output="$SOURCES_DIR/$filename"
    local url="$MIRROR/$filename"
    local attempt=1

    # Skip if already exists
    if [ -f "$output" ]; then
        echo "[SKIP] $filename"
        return 0
    fi

    while [ $attempt -le $MAX_RETRIES ]; do
        # Use curl for better performance (connection reuse)
        # No --max-time to allow large files to download fully
        if curl -fSL \
                --connect-timeout 30 \
                --retry 2 \
                --retry-delay 1 \
                -o "$output" \
                "$url" 2>/dev/null; then
            echo "[OK] $filename"
            return 0
        fi

        rm -f "$output"  # Remove partial download
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done

    echo "[FAIL] $filename"
    return 1
}
export -f download_single

# =============================================================================
# Main
# =============================================================================
main() {
    log_info "=========================================="
    log_info "RookeryOS Source Download (PARALLEL)"
    log_info "=========================================="
    log_info "Mirror: $MIRROR"
    log_info "Target: $SOURCES_DIR"
    log_info "Parallel jobs: $PARALLEL_JOBS"
    log_info "=========================================="

    # Create sources directory
    mkdir -p "$SOURCES_DIR"

    # Fetch directory listing from mirror
    log_info "Fetching file list from mirror..."

    # Fetch HTML and extract filenames
    FILE_LIST=$(curl -sfL "$MIRROR/" | \
        grep -oE 'href="[^"]+\.(tar\.gz|tar\.xz|tar\.bz2|tar\.lz|tgz|patch|zip)"' | \
        sed 's/href="//;s/"$//' | \
        sort -u)

    if [ -z "$FILE_LIST" ]; then
        log_error "Failed to fetch file list from mirror"
        exit 1
    fi

    TOTAL_FILES=$(echo "$FILE_LIST" | wc -l)
    log_info "Found $TOTAL_FILES files on mirror"

    # Count already downloaded
    local existing=0
    while IFS= read -r f; do
        [ -f "$SOURCES_DIR/$f" ] && existing=$((existing + 1))
    done <<< "$FILE_LIST"

    local to_download=$((TOTAL_FILES - existing))
    log_info "Already downloaded: $existing"
    log_info "To download: $to_download"
    log_info ""
    log_info "Starting parallel downloads ($PARALLEL_JOBS at a time)..."
    log_info "=========================================="

    # Create temp file for results
    RESULTS_FILE=$(mktemp)
    trap "rm -f $RESULTS_FILE; finalize_logging \$?" EXIT

    # Run parallel downloads using xargs
    # -P = parallel jobs, -I = replacement string
    echo "$FILE_LIST" | xargs -P "$PARALLEL_JOBS" -I {} bash -c 'download_single "$@"' _ {} 2>&1 | tee "$RESULTS_FILE"

    # Count results
    local ok_count=$(grep -c '^\[OK\]' "$RESULTS_FILE" 2>/dev/null || echo 0)
    local skip_count=$(grep -c '^\[SKIP\]' "$RESULTS_FILE" 2>/dev/null || echo 0)
    local fail_count=$(grep -c '^\[FAIL\]' "$RESULTS_FILE" 2>/dev/null || echo 0)

    log_info ""
    log_info "=========================================="
    log_info "Download Complete!"
    log_info "=========================================="
    log_info "Total files: $TOTAL_FILES"
    log_info "Downloaded: $ok_count"
    log_info "Skipped (existing): $skip_count"
    log_info "Failed: $fail_count"
    log_info "=========================================="

    # Show failed files if any
    if [ "$fail_count" -gt 0 ]; then
        log_warn "Failed downloads:"
        grep '^\[FAIL\]' "$RESULTS_FILE" | sed 's/\[FAIL\] /  - /'
        exit 1
    fi
}

main "$@"
