#!/bin/bash
# =============================================================================
# Build Toolchain Entrypoint
# Fixes volume permissions and drops to lfs user
# =============================================================================

set -e

ROOKERY="${ROOKERY:-/rookery}"
TOOLS_DIR="${TOOLS:-/tools}"

# Fix ownership of mounted volumes (they come in as root from Docker)
echo "[INIT] Fixing volume permissions..."

# Ensure rookery volume is owned by lfs user
if [ -d "$ROOKERY" ]; then
    chown -R lfs:lfs "$ROOKERY" 2>/dev/null || true
fi

# Ensure tools volume is owned by lfs user
if [ -d "$TOOLS_DIR" ]; then
    chown -R lfs:lfs "$TOOLS_DIR" 2>/dev/null || true
fi

echo "[INIT] Volume permissions fixed, starting build as lfs user..."

# Drop privileges and run the actual build script
exec gosu lfs /usr/local/bin/build_toolchain.sh "$@"
