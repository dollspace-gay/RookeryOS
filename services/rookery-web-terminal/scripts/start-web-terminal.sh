#!/bin/bash
set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
IMAGE_PATH="/rookery-dist/${IMAGE_NAME}.img"
PORT="${WEB_TERMINAL_PORT:-7681}"

# Check if Rookery OS image exists
if [ ! -f "$IMAGE_PATH" ]; then
    # Show helpful message if image doesn't exist
    cat > /tmp/no-image-message.sh << 'EOF'
#!/bin/bash
clear
cat << 'BANNER'
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║              Rookery OS System Image Not Found                 ║
║                                                                ║
║  The Rookery OS system image has not been built yet.           ║
║                                                                ║
║  To build the Rookery OS system, run:                          ║
║    make build                                                  ║
║                                                                ║
║  Then access this web terminal at:                             ║
║    http://localhost:7681                                       ║
║                                                                ║
║  For more information:                                         ║
║    cat README.md                                               ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

Press Ctrl+D to exit this terminal.

BANNER
/bin/bash --noprofile --norc
EOF
    chmod +x /tmp/no-image-message.sh

    echo "Starting ttyd (image not found - showing help message)..."
    exec ttyd -p "$PORT" /tmp/no-image-message.sh
fi

# Create run script for QEMU
cat > /tmp/run-rookery.sh << 'EOF'
#!/bin/bash
set -e

IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
IMAGE_PATH="/rookery-dist/${IMAGE_NAME}.img"

cat << EOF
╔════════════════════════════════════════════════════════════════╗
║                       Rookery OS                               ║
║                    Web Terminal Interface                      ║
╚════════════════════════════════════════════════════════════════╝

Starting Rookery OS system from: $IMAGE_PATH
Serial console mode (text only)

Press Ctrl+A then X to exit QEMU
══════════════════════════════════════════════════════════════════

EOF

# Run QEMU in serial console mode
exec qemu-system-x86_64 \
    -m 2G \
    -smp 2 \
    -drive file="$IMAGE_PATH",format=raw \
    -boot c \
    -nographic \
    -serial mon:stdio
EOF

chmod +x /tmp/run-rookery.sh

# Start ttyd server with QEMU
echo "Starting ttyd web terminal on port $PORT..."
echo "Image: $IMAGE_PATH"
echo "Access at: http://localhost:$PORT"

exec ttyd -p "$PORT" /tmp/run-rookery.sh
