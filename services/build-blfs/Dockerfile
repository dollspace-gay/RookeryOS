FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    bash \
    binutils \
    bison \
    coreutils \
    diffutils \
    findutils \
    gawk \
    gcc \
    g++ \
    grep \
    gzip \
    m4 \
    make \
    patch \
    perl \
    python3 \
    sed \
    tar \
    texinfo \
    xz-utils \
    file \
    util-linux \
    meson \
    ninja-build \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Copy common utilities
COPY common /usr/local/lib/rookery-common

# Copy build scripts
COPY build-blfs/scripts/build_blfs.sh /usr/local/bin/build_blfs.sh
COPY build-blfs/scripts/build_blfs_chroot.sh /usr/local/bin/build_blfs_chroot.sh
RUN chmod +x /usr/local/bin/build_blfs.sh /usr/local/bin/build_blfs_chroot.sh

WORKDIR /

ENTRYPOINT ["/usr/local/bin/build_blfs.sh"]
