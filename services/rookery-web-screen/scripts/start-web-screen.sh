#!/bin/bash
set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
IMAGE_PATH="/rookery-dist/${IMAGE_NAME}.img"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_SCREEN_PORT:-6080}"
DISPLAY=":0"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                       Rookery OS                               ║"
echo "║                    Web Screen Interface                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if Rookery OS image exists
if [ ! -f "$IMAGE_PATH" ]; then
    echo "ERROR: Rookery OS system image not found at: $IMAGE_PATH"
    echo ""
    echo "The Rookery OS system image has not been built yet."
    echo ""
    echo "To build the Rookery OS system, run:"
    echo "  make build"
    echo ""
    echo "Waiting for image to be created..."
    echo "Access this web interface at: http://localhost:$WEB_PORT"
    echo ""

    # Keep container running and check periodically for image
    while [ ! -f "$IMAGE_PATH" ]; do
        sleep 30
    done

    echo "Image found! Starting Rookery OS system..."
fi

# Start QEMU with VNC output in background
echo "Starting Rookery OS system in QEMU with VNC on port $VNC_PORT..."
qemu-system-x86_64 \
    -m 2G \
    -smp 2 \
    -drive file="$IMAGE_PATH",format=raw \
    -boot c \
    -vga virtio \
    -display vnc=0.0.0.0:0 \
    -global virtio-vga.xres=1920 \
    -global virtio-vga.yres=1080 &
QEMU_PID=$!

# Wait for QEMU VNC server to be ready
echo "Waiting for VNC server to start..."
sleep 3

# Start noVNC/websockify
echo "Starting noVNC web server on port $WEB_PORT..."
websockify --web=/usr/share/novnc $WEB_PORT localhost:$VNC_PORT &
NOVNC_PID=$!

# Wait for noVNC to be ready
sleep 2

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "Web Screen Interface Ready!"
echo "══════════════════════════════════════════════════════════════════"
echo "Access at: http://localhost:$WEB_PORT/vnc.html"
echo "Image: $IMAGE_PATH"
echo "VNC Port: $VNC_PORT"
echo "══════════════════════════════════════════════════════════════════"
echo ""

# Wait for QEMU process
wait $QEMU_PID
