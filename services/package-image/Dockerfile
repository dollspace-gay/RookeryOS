FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install image creation tools
RUN apt-get update && apt-get install -y \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-common \
    grub2-common \
    isolinux \
    syslinux \
    syslinux-common \
    xorriso \
    mtools \
    dosfstools \
    parted \
    e2fsprogs \
    rsync \
    squashfs-tools \
    udev \
    cpio \
    gzip \
    xz-utils \
    binutils \
    file \
    findutils \
    && rm -rf /var/lib/apt/lists/*

# Copy packaging script
# Copy common utilities
COPY common /usr/local/lib/rookery-common

COPY package-image/scripts/package_image.sh /usr/local/bin/package_image.sh
RUN chmod +x /usr/local/bin/package_image.sh

WORKDIR /

ENTRYPOINT ["/usr/local/bin/package_image.sh"]
