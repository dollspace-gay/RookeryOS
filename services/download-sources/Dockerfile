FROM alpine:3.19

# Install download tools
RUN apk add --no-cache \
    wget \
    curl \
    ca-certificates \
    gnupg \
    coreutils \
    bash \
    grep \
    sed \
    findutils \
    parallel

WORKDIR /sources

# Copy common utilities
COPY common /usr/local/lib/rookery-common

# Copy download script
COPY download-sources/scripts/download.sh /usr/local/bin/download.sh
RUN chmod +x /usr/local/bin/download.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/download.sh"]
