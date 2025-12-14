FROM alpine:3.19

# Install ttyd, QEMU, and required tools
RUN apk add --no-cache \
    ttyd \
    qemu-system-x86_64 \
    bash \
    coreutils

# Create directory for Rookery image
RUN mkdir -p /rookery-dist

# Copy startup script
COPY rookery-web-terminal/scripts/start-web-terminal.sh /usr/local/bin/start-web-terminal.sh
RUN chmod +x /usr/local/bin/start-web-terminal.sh

# Expose ttyd default port
EXPOSE 7681

# Set working directory
WORKDIR /rookery-dist

# Start ttyd server
CMD ["/usr/local/bin/start-web-terminal.sh"]
