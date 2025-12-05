#!/bin/bash
# =============================================================================
# Rookery OS Boot Test Script
# Tests the bootable disk image and ISO with QEMU
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# Configuration
IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
IMAGE_PATH="${1:-/workspace/${IMAGE_NAME}.img}"
ISO_PATH="${2:-/workspace/${IMAGE_NAME}.iso}"
TEST_TIMEOUT=120
QEMU_MEMORY="2G"
QEMU_CPUS="2"

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run test
run_test() {
    local test_name="$1"
    local test_command="$2"

    ((TESTS_TOTAL++))
    log_test "$test_name"

    if eval "$test_command" >/dev/null 2>&1; then
        log_pass "$test_name"
        ((TESTS_PASSED++))
        return 0
    else
        log_fail "$test_name"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Pre-Boot Tests
# =============================================================================

log_info "===== PRE-BOOT TESTS ====="

# Test 1: QEMU is available
run_test "QEMU is installed" "command -v qemu-system-x86_64"

# Test 2: Disk image file exists and is valid
if [ -f "$IMAGE_PATH" ]; then
    run_test "Disk image file exists" "test -f '$IMAGE_PATH'"
    run_test "Disk image is not empty" "test -s '$IMAGE_PATH'"
    run_test "Disk image size > 500MB" "[ \$(stat -c %s '$IMAGE_PATH') -gt 524288000 ]"
else
    log_warn "Disk image not found at $IMAGE_PATH - skipping disk image tests"
fi

# Test 3: ISO image file exists and is valid
if [ -f "$ISO_PATH" ]; then
    run_test "ISO image file exists" "test -f '$ISO_PATH'"
    run_test "ISO image is not empty" "test -s '$ISO_PATH'"
    run_test "ISO image size > 100MB" "[ \$(stat -c %s '$ISO_PATH') -gt 104857600 ]"
else
    log_warn "ISO image not found at $ISO_PATH - skipping ISO tests"
fi

# =============================================================================
# Boot Test - Disk Image
# =============================================================================

if [ -f "$IMAGE_PATH" ]; then
    log_info "===== DISK IMAGE BOOT TEST ====="

    log_info "Attempting to boot disk image with QEMU..."
    log_info "Image: $IMAGE_PATH"
    log_info "Memory: $QEMU_MEMORY, CPUs: $QEMU_CPUS"

    # Create expect script for automated testing
    cat > /tmp/qemu_boot_test.exp << 'EOF'
#!/usr/bin/expect -f

set timeout 120
set image_path [lindex $argv 0]
set boot_type [lindex $argv 1]

# Start QEMU based on boot type
if {$boot_type eq "iso"} {
    spawn qemu-system-x86_64 \
        -m 2G \
        -smp 2 \
        -cdrom $image_path \
        -boot d \
        -nographic \
        -serial mon:stdio
} else {
    spawn qemu-system-x86_64 \
        -m 2G \
        -smp 2 \
        -drive file=$image_path,format=raw \
        -boot c \
        -nographic \
        -serial mon:stdio
}

# Wait for GRUB or boot messages
expect {
    "Rookery OS" {
        send_user "\n[BOOT] GRUB menu detected\n"
    }
    "Loading Linux" {
        send_user "\n[BOOT] Kernel loading\n"
    }
    "Kernel panic" {
        send_user "\n[BOOT ERROR] Kernel panic detected\n"
        exit 1
    }
    timeout {
        send_user "\n[BOOT ERROR] Boot timeout waiting for GRUB/kernel\n"
        exit 1
    }
}

# Wait for systemd or login prompt
expect {
    "Welcome to" {
        send_user "\n[BOOT] systemd welcome message\n"
    }
    "Reached target" {
        send_user "\n[BOOT] systemd targets reached\n"
    }
    "login:" {
        send_user "\n[BOOT] Login prompt reached\n"
        send "root\r"
    }
    "Kernel panic" {
        send_user "\n[BOOT ERROR] Kernel panic detected\n"
        exit 1
    }
    timeout {
        send_user "\n[BOOT ERROR] Boot timeout waiting for init\n"
        exit 1
    }
}

# Wait for login prompt if not already there
expect {
    "login:" {
        send_user "\n[BOOT] Login prompt reached\n"
        send "root\r"
    }
    "#" {
        send_user "\n[BOOT] Already at shell\n"
    }
    timeout {
        send_user "\n[BOOT ERROR] No login prompt\n"
        exit 1
    }
}

# Handle password prompt if needed
expect {
    "Password:" {
        send_user "\n[BOOT] Password prompt\n"
        send "rookery\r"
    }
    "#" {
        send_user "\n[BOOT] Shell prompt reached\n"
    }
    timeout {
        send_user "\n[BOOT] Timeout waiting for prompt\n"
    }
}

# Wait for shell prompt
expect {
    "#" {
        send_user "\n[BOOT] Shell prompt reached\n"
    }
    "\\$" {
        send_user "\n[BOOT] User shell prompt reached\n"
    }
    timeout {
        send_user "\n[BOOT ERROR] No shell prompt\n"
        exit 1
    }
}

# Run basic system tests
send "uname -a\r"
expect "#"

send "cat /etc/os-release\r"
expect "#"

send "systemctl --no-pager status || true\r"
expect "#"

send "ls -la /bin /usr/bin 2>/dev/null | head -10\r"
expect "#"

# Shutdown
send "sync; echo o > /proc/sysrq-trigger\r"
expect eof

send_user "\n[BOOT] All boot tests passed\n"
exit 0
EOF

    chmod +x /tmp/qemu_boot_test.exp

    # Run boot test if expect is available
    if command -v expect >/dev/null 2>&1; then
        if timeout 180 /tmp/qemu_boot_test.exp "$IMAGE_PATH" "disk"; then
            log_pass "Disk image QEMU boot test"
            ((TESTS_PASSED++))
        else
            log_fail "Disk image QEMU boot test"
            ((TESTS_FAILED++))
        fi
        ((TESTS_TOTAL++))
    else
        log_warn "Expect not installed - skipping automated boot test"
        log_info "Manual boot test command:"
        log_info "  qemu-system-x86_64 -m 2G -smp 2 -drive file=$IMAGE_PATH,format=raw -boot c -nographic -serial mon:stdio"
    fi
fi

# =============================================================================
# Boot Test - ISO Image
# =============================================================================

if [ -f "$ISO_PATH" ]; then
    log_info "===== ISO IMAGE BOOT TEST ====="

    log_info "Attempting to boot ISO with QEMU..."
    log_info "ISO: $ISO_PATH"
    log_info "Memory: $QEMU_MEMORY, CPUs: $QEMU_CPUS"

    if command -v expect >/dev/null 2>&1; then
        if timeout 180 /tmp/qemu_boot_test.exp "$ISO_PATH" "iso"; then
            log_pass "ISO QEMU boot test"
            ((TESTS_PASSED++))
        else
            log_fail "ISO QEMU boot test"
            ((TESTS_FAILED++))
        fi
        ((TESTS_TOTAL++))
    else
        log_warn "Expect not installed - skipping automated ISO boot test"
        log_info "Manual ISO boot test command:"
        log_info "  qemu-system-x86_64 -m 2G -smp 2 -cdrom $ISO_PATH -boot d -nographic -serial mon:stdio"
    fi
fi

# Cleanup
rm -f /tmp/qemu_boot_test.exp

# =============================================================================
# Summary
# =============================================================================

log_info ""
log_info "=========================================="
log_info "BOOT TEST SUMMARY"
log_info "=========================================="
log_info "Total Tests:  $TESTS_TOTAL"
log_pass "Passed:       $TESTS_PASSED"
log_fail "Failed:       $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
    log_info "=========================================="
    log_pass "ALL TESTS PASSED"
    log_info "=========================================="
    exit 0
else
    log_info "=========================================="
    log_fail "SOME TESTS FAILED"
    log_info "=========================================="
    exit 1
fi
