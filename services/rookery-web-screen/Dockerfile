FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install QEMU, VNC server, noVNC and dependencies
RUN apt-get update && apt-get install -y \
    qemu-system-x86 \
    tigervnc-standalone-server \
    tigervnc-common \
    novnc \
    websockify \
    python3 \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

# Create directory for Rookery image
RUN mkdir -p /rookery-dist

# Copy startup script
COPY rookery-web-screen/scripts/start-web-screen.sh /usr/local/bin/start-web-screen.sh
RUN chmod +x /usr/local/bin/start-web-screen.sh

# Expose noVNC port
EXPOSE 6080

# Set working directory
WORKDIR /rookery-dist

# Start web screen service
CMD ["/usr/local/bin/start-web-screen.sh"]
