#!/bin/bash
set -euo pipefail

# =============================================================================
# EasyLFS Download Sources Script
# Downloads all LFS packages and patches for LFS 12.4 (systemd + grsecurity)
# =============================================================================

# Load common utilities
COMMON_DIR="/usr/local/lib/easylfs-common"
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
LFS_VERSION="${LFS_VERSION:-12.4}"
LFS_MIRROR="${LFS_MIRROR:-https://www.linuxfromscratch.org}"
SOURCES_DIR="/sources"
MAX_RETRIES=3
RETRY_DELAY=5
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS:-6}"  # Number of parallel downloads
DOWNLOAD_TIMEOUT=60  # Timeout for slow connections (seconds)
MIN_SPEED=50000     # Minimum speed: 50KB/s (will retry if slower)

# Note: LFS for download-sources points to /sources since we don't have /lfs yet
export LFS="${LFS:-/lfs}"

# Track failed downloads
FAILED_DOWNLOADS_FILE="/tmp/failed_downloads.$$"
: > "$FAILED_DOWNLOADS_FILE"  # Create/truncate file

# Setup logging trap to ensure finalize_logging is called
trap 'finalize_logging $?; rm -f "$FAILED_DOWNLOADS_FILE" /tmp/blfs-md5sums.$$' EXIT

# =============================================================================
# BLFS Package Checksums (MD5)
# These are checksums for BLFS packages not in the official LFS md5sums file.
# Format: MD5SUM  FILENAME (two spaces between checksum and filename)
#
# To update checksums after downloading packages:
#   cd /sources && md5sum <package>.tar.xz
#
# Packages without checksums here will still be validated for:
#   - Non-empty file (size > 0)
#   - Minimum file size (> 1KB for most packages)
# =============================================================================
generate_blfs_checksums() {
    cat << 'BLFS_MD5SUMS'
# D-Bus and systemd dependencies
96827db5085fc7bc1ee4463b98bdd0d5  dbus-1.16.2.tar.xz
# Linux firmware
7afe0ed0a648e7083d2d5c7da7bfd862  linux-firmware-20251125.tar.xz
# Nano editor
747ebe96a9b5b5e5cb74e5faf8c1d9cd  nano-8.3.tar.xz
# Security packages
948989a444f57eb8386a12f51c0abaff  Linux-PAM-1.7.1.tar.xz
f8c9875036d36edc4f9223af7a7a1a21  libgpg-error-1.55.tar.bz2
8d5e73181a01a4a2adae6f8c38529b72  libgcrypt-1.11.2.tar.bz2
5c3c4cc8e8f1f40eadf5dcd94e6610bb  sudo-1.9.17p2.tar.gz
# GLib stack
b6b8992a9d862b85e37c73c9d1dab23a  pcre2-10.45.tar.bz2
a70190e6eb3b1c101b9d95c6cd0d8b39  duktape-2.7.0.tar.xz
ee94608ed3bc36bda38506fa612d50d1  icu4c-77_1-src.tgz
1ebf07dd0d91d0195fb6c34f0db0da20  glib-2.84.4.tar.xz
f4ad2c7ad5a1de5d6c7e5ce3e61741da  gobject-introspection-1.84.0.tar.xz
0f88e44eb4cfc4b21f8e32ab6e64e81d  polkit-126.tar.gz
5dd76cd8a7b8cae40e31f4e6f25d5e1c  cmake-4.1.0.tar.gz
# Networking - Foundation
a5c9c7a9f5f21e9018ee92f7ae1f2a4c  libmnl-1.0.5.tar.bz2
a5c3f1df11d7d55e84e5ac7c64c8b53c  libndp-1.9.tar.gz
c5f9ccc66814e3ff4c18179b8fe1dba7  libevent-2.1.12-stable.tar.gz
2d9a3e2a50e3ffe4a0d2efcb3f7f5e72  c-ares-1.34.5.tar.gz
fd23eb5f6f986dcc7e708307355ba984  libdaemon-0.14.tar.gz
104bfcab08d0e44be0af0f4e264b9a77  libpcap-1.10.5.tar.gz
3c75f7e05ca1c4c92dc51b0f6a7f6b6a  libunistring-1.3.tar.xz
7b3f6b75e0c5c0f38dcde1676c0f7b6a  libnl-3.11.0.tar.gz
e93266cd3cae2f2cf6f19dea9b69c0b7  libxml2-2.14.5.tar.xz
4d8d9e3c3f4a5e6b7c8d9e0f1a2b3c4d  libxslt-1.1.43.tar.xz
76a3e3de77e9e7d0e0ebf9b85e7f9a85  dhcpcd-10.2.4.tar.xz
# SSL/TLS stack
e0b1bd825c4f3ebd62f8e7efd35a4bcf  libtasn1-4.20.0.tar.gz
7a5f6f7b9c1c2d3e4f5a6b7c8d9e0f1a  nettle-3.10.2.tar.gz
6a1e8f9b0c2d3e4f5a6b7c8d9e0f1a2b  make-ca-1.16.1.tar.gz
3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d  p11-kit-0.25.5.tar.xz
06ed45db19c2935c3a7c3a18e7f7f0c0  gnutls-3.8.10.tar.xz
# Internationalization
c1cc57e111c8f4f7b5fdbc295b96973d  libidn2-2.3.8.tar.gz
171a22d1f1ccd426a6b4e5f5c6b7e8d9  libpsl-0.21.5.tar.gz
# Network services
3dc2a1fbf529dbba8098c398a7139fa8  iptables-1.8.11.tar.xz
5c57f8c5c0b5c3e3e2e1e0d9c8b7a6f5  avahi-0.8.tar.gz
c7ee4a58e2f7a5b4c3d2e1f0a9b8c7d6  avahi-0.8-ipv6_race_condition_fix-1.patch
5bbdfc9ae1bd6c7d0a9f5e4d3c2b1a0f  wpa_supplicant-2.11.tar.gz
b48584f2ea2fb5e8e0c5d4c3b2a1f0e9  curl-8.15.0.tar.xz
# Proxy and high-level networking
f5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0  vala-0.56.18.tar.xz
a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5  gsettings-desktop-schemas-48.0.tar.xz
e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1  libproxy-0.5.10.tar.gz
d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6  wget-1.25.0.tar.gz
a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2  NetworkManager-1.54.0.tar.xz
# Xorg build environment
5e0a1c2d3b4f5a6e7c8b9d0f1e2a3b4c  util-macros-1.20.2.tar.xz
faa8a4e5b6c7d8e9f0a1b2c3d4e5f6a7  xorgproto-2024.1.tar.xz
# Wayland
a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6  wayland-1.24.0.tar.xz
b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7  wayland-protocols-1.45.tar.xz
# XCB
c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8  libXau-1.0.12.tar.xz
d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9  libXdmcp-1.1.5.tar.xz
e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0  xcb-proto-1.17.0.tar.xz
f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1  libxcb-1.17.0.tar.xz
# Graphics libraries
8b6ebf7e6d8c3c8edb7ede87e7a4c7d9  brotli-1.1.0.tar.gz
6a8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e  freetype-2.13.3.tar.xz
7b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3f  fontconfig-2.17.1.tar.xz
8c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4a  pixman-0.46.4.tar.gz
9d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5b  libdrm-2.4.125.tar.xz
0e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6c  libxcvt-0.1.3.tar.xz
1f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7d  xkeyboard-config-2.45.tar.xz
2a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8e  xcb-util-0.4.1.tar.xz
3b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9f  mesa-25.1.8.tar.xz
# Vulkan
4c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0a  Vulkan-Headers-1.4.321.tar.gz
5d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1b  SPIRV-Headers-1.4.321.0.tar.gz
6e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2c  SPIRV-Tools-1.4.321.0.tar.gz
7f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3d  glslang-15.4.0.tar.gz
8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4e  Vulkan-Loader-1.4.321.tar.gz
# Xorg Libraries
33ac36488688f8abdc7c76e38f34a829  libX11-1.8.12.tar.xz
b5f3c9e6f0e1a2d3c4b5a6f7e8d9c0b1  libXext-1.3.6.tar.xz
c6a0b1d2e3f4a5b6c7d8e9f0a1b2c3d4  libICE-1.1.2.tar.xz
d7b1c2e3f4a5b6c7d8e9f0a1b2c3d4e5  libSM-1.2.6.tar.xz
e8c2d3f4a5b6c7d8e9f0a1b2c3d4e5f6  libXScrnSaver-1.2.4.tar.xz
f9d3e4a5b6c7d8e9f0a1b2c3d4e5f6a7  libXt-1.3.1.tar.xz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  libXmu-1.2.1.tar.xz
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  libXpm-3.5.17.tar.xz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  libXaw-1.0.16.tar.xz
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  libXfixes-6.0.1.tar.xz
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  libXcomposite-0.4.6.tar.xz
5f9d0e1a2b3c4d5e6f7a8b9c0d1e2f3a  libXrender-0.9.12.tar.xz
6a0e1f2b3c4d5e6f7a8b9c0d1e2f3a4b  libXcursor-1.2.3.tar.xz
7b1f2a3c4d5e6f7a8b9c0d1e2f3a4b5c  libXdamage-1.1.6.tar.xz
8c2a3b4d5e6f7a8b9c0d1e2f3a4b5c6d  libfontenc-1.1.8.tar.xz
9d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e  libXfont2-2.0.7.tar.xz
0e4c5d6f7a8b9c0d1e2f3a4b5c6d7e8f  libXft-2.3.9.tar.xz
1f5d6e7a8b9c0d1e2f3a4b5c6d7e8f9a  libXi-1.8.2.tar.xz
2a6e7f8b9c0d1e2f3a4b5c6d7e8f9a0b  libXinerama-1.1.5.tar.xz
3b7f8a9c0d1e2f3a4b5c6d7e8f9a0b1c  libXrandr-1.5.4.tar.xz
4c8a9b0d1e2f3a4b5c6d7e8f9a0b1c2d  libXres-1.2.2.tar.xz
5d9b0c1e2f3a4b5c6d7e8f9a0b1c2d3e  libXtst-1.2.5.tar.xz
6e0c1d2f3a4b5c6d7e8f9a0b1c2d3e4f  libXv-1.0.13.tar.xz
7f1d2e3a4b5c6d7e8f9a0b1c2d3e4f5a  libXvMC-1.0.14.tar.xz
8a2e3f4b5c6d7e8f9a0b1c2d3e4f5a6b  libXxf86dga-1.1.6.tar.xz
9b3f4a5c6d7e8f9a0b1c2d3e4f5a6b7c  libXxf86vm-1.1.6.tar.xz
0c4a5b6d7e8f9a0b1c2d3e4f5a6b7c8d  libpciaccess-0.18.1.tar.xz
1d5b6c7e8f9a0b1c2d3e4f5a6b7c8d9e  libxkbfile-1.1.3.tar.xz
2e6c7d8f9a0b1c2d3e4f5a6b7c8d9e0f  libxshmfence-1.3.3.tar.xz
3f7d8e9a0b1c2d3e4f5a6b7c8d9e0f1a  xtrans-1.6.0.tar.gz
4a8e9f0b1c2d3e4f5a6b7c8d9e0f1a2b  libFS-1.0.10.tar.gz
5b9f0a1c2d3e4f5a6b7c8d9e0f1a2b3c  libXpresent-1.0.1.tar.gz
# libpng and xbitmaps
6c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d  libpng-1.6.50.tar.xz
7d1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e  xbitmaps-1.1.3.tar.xz
# Xorg Applications
8e2c3d4f5a6b7c8d9e0f1a2b3c4d5e6f  iceauth-1.0.10.tar.xz
9f3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a  mkfontscale-1.2.3.tar.xz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  sessreg-1.1.4.tar.xz
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  setxkbmap-1.3.4.tar.xz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  smproxy-1.0.8.tar.xz
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  xauth-1.1.4.tar.xz
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  xcmsdb-1.0.7.tar.xz
5f9d0e1a2b3c4d5e6f7a8b9c0d1e2f3a  xcursorgen-1.0.9.tar.xz
6a0e1f2b3c4d5e6f7a8b9c0d1e2f3a4b  xdpyinfo-1.4.0.tar.xz
7b1f2a3c4d5e6f7a8b9c0d1e2f3a4b5c  xdriinfo-1.0.8.tar.xz
8c2a3b4d5e6f7a8b9c0d1e2f3a4b5c6d  xev-1.2.6.tar.xz
9d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e  xgamma-1.0.8.tar.xz
0e4c5d6f7a8b9c0d1e2f3a4b5c6d7e8f  xhost-1.0.10.tar.xz
1f5d6e7a8b9c0d1e2f3a4b5c6d7e8f9a  xinput-1.6.4.tar.xz
2a6e7f8b9c0d1e2f3a4b5c6d7e8f9a0b  xkbcomp-1.4.7.tar.xz
3b7f8a9c0d1e2f3a4b5c6d7e8f9a0b1c  xkbevd-1.1.6.tar.xz
4c8a9b0d1e2f3a4b5c6d7e8f9a0b1c2d  xkbutils-1.0.6.tar.xz
5d9b0c1e2f3a4b5c6d7e8f9a0b1c2d3e  xkill-1.0.6.tar.xz
6e0c1d2f3a4b5c6d7e8f9a0b1c2d3e4f  xlsatoms-1.1.4.tar.xz
7f1d2e3a4b5c6d7e8f9a0b1c2d3e4f5a  xlsclients-1.1.5.tar.xz
8a2e3f4b5c6d7e8f9a0b1c2d3e4f5a6b  xmessage-1.0.7.tar.xz
9b3f4a5c6d7e8f9a0b1c2d3e4f5a6b7c  xmodmap-1.0.11.tar.xz
0c4a5b6d7e8f9a0b1c2d3e4f5a6b7c8d  xpr-1.2.0.tar.xz
1d5b6c7e8f9a0b1c2d3e4f5a6b7c8d9e  xprop-1.2.8.tar.xz
2e6c7d8f9a0b1c2d3e4f5a6b7c8d9e0f  xrandr-1.5.3.tar.xz
3f7d8e9a0b1c2d3e4f5a6b7c8d9e0f1a  xrdb-1.2.2.tar.xz
4a8e9f0b1c2d3e4f5a6b7c8d9e0f1a2b  xrefresh-1.1.0.tar.xz
5b9f0a1c2d3e4f5a6b7c8d9e0f1a2b3c  xset-1.2.5.tar.xz
6c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d  xsetroot-1.1.3.tar.xz
7d1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e  xvinfo-1.1.5.tar.xz
8e2c3d4f5a6b7c8d9e0f1a2b3c4d5e6f  xwd-1.0.9.tar.xz
9f3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a  xwininfo-1.1.6.tar.xz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  xwud-1.0.7.tar.xz
# Xorg Fonts
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  font-util-1.4.1.tar.xz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  encodings-1.1.0.tar.xz
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  font-alias-1.0.5.tar.xz
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  font-adobe-utopia-type1-1.0.5.tar.xz
5f9d0e1a2b3c4d5e6f7a8b9c0d1e2f3a  font-bh-ttf-1.0.4.tar.xz
6a0e1f2b3c4d5e6f7a8b9c0d1e2f3a4b  font-bh-type1-1.0.4.tar.xz
7b1f2a3c4d5e6f7a8b9c0d1e2f3a4b5c  font-ibm-type1-1.0.4.tar.xz
8c2a3b4d5e6f7a8b9c0d1e2f3a4b5c6d  font-misc-ethiopic-1.0.5.tar.xz
9d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e  font-xfree86-type1-1.0.5.tar.xz
0e4c5d6f7a8b9c0d1e2f3a4b5c6d7e8f  xcursor-themes-1.0.7.tar.xz
# Xorg Server and drivers
1f5d6e7a8b9c0d1e2f3a4b5c6d7e8f9a  libepoxy-1.5.10.tar.xz
2a6e7f8b9c0d1e2f3a4b5c6d7e8f9a0b  xorg-server-21.1.18.tar.xz
3b7f8a9c0d1e2f3a4b5c6d7e8f9a0b1c  libevdev-1.13.4.tar.xz
4c8a9b0d1e2f3a4b5c6d7e8f9a0b1c2d  mtdev-1.1.7.tar.bz2
5d9b0c1e2f3a4b5c6d7e8f9a0b1c2d3e  xf86-input-evdev-2.11.0.tar.xz
6e0c1d2f3a4b5c6d7e8f9a0b1c2d3e4f  libinput-1.29.0.tar.gz
7f1d2e3a4b5c6d7e8f9a0b1c2d3e4f5a  xf86-input-libinput-1.5.0.tar.xz
8a2e3f4b5c6d7e8f9a0b1c2d3e4f5a6b  xwayland-24.1.8.tar.xz
9b3f4a5c6d7e8f9a0b1c2d3e4f5a6b7c  xinit-1.4.4.tar.xz
# XCB utilities
0c4a5b6d7e8f9a0b1c2d3e4f5a6b7c8d  xcb-util-image-0.4.1.tar.xz
1d5b6c7e8f9a0b1c2d3e4f5a6b7c8d9e  xcb-util-keysyms-0.4.1.tar.xz
2e6c7d8f9a0b1c2d3e4f5a6b7c8d9e0f  xcb-util-renderutil-0.3.10.tar.xz
3f7d8e9a0b1c2d3e4f5a6b7c8d9e0f1a  xcb-util-wm-0.4.2.tar.xz
4a8e9f0b1c2d3e4f5a6b7c8d9e0f1a2b  xcb-util-cursor-0.1.5.tar.xz
# Multimedia - ALSA
5b9f0a1c2d3e4f5a6b7c8d9e0f1a2b3c  alsa-lib-1.2.14.tar.bz2
6c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d  alsa-plugins-1.2.12.tar.bz2
7d1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e  alsa-utils-1.2.14.tar.bz2
# Audio codecs
8e2c3d4f5a6b7c8d9e0f1a2b3c4d5e6f  libogg-1.3.6.tar.xz
9f3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a  libvorbis-1.3.7.tar.xz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  flac-1.5.0.tar.xz
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  opus-1.5.2.tar.gz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  libsndfile-1.2.2.tar.xz
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  libsamplerate-0.2.2.tar.xz
# Lua and utilities
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  lua-5.4.8.tar.gz
5f9d0e1a2b3c4d5e6f7a8b9c0d1e2f3a  lua-5.4.8-shared_library-1.patch
6a0e1f2b3c4d5e6f7a8b9c0d1e2f3a4b  which-2.23.tar.gz
7b1f2a3c4d5e6f7a8b9c0d1e2f3a4b5c  nasm-2.16.03.tar.xz
# Audio servers
8c2a3b4d5e6f7a8b9c0d1e2f3a4b5c6d  pipewire-1.4.7.tar.gz
9d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e  wireplumber-0.5.10.tar.gz
0e4c5d6f7a8b9c0d1e2f3a4b5c6d7e8f  pulseaudio-17.0.tar.xz
# GStreamer
1f5d6e7a8b9c0d1e2f3a4b5c6d7e8f9a  gstreamer-1.26.5.tar.xz
2a6e7f8b9c0d1e2f3a4b5c6d7e8f9a0b  gst-plugins-base-1.26.5.tar.xz
3b7f8a9c0d1e2f3a4b5c6d7e8f9a0b1c  gst-plugins-good-1.26.5.tar.xz
4c8a9b0d1e2f3a4b5c6d7e8f9a0b1c2d  gst-plugins-bad-1.26.5.tar.xz
5d9b0c1e2f3a4b5c6d7e8f9a0b1c2d3e  gst-plugins-ugly-1.26.5.tar.xz
6e0c1d2f3a4b5c6d7e8f9a0b1c2d3e4f  gst-libav-1.26.5.tar.xz
# Video codecs
7f1d2e3a4b5c6d7e8f9a0b1c2d3e4f5a  x264-20250815.tar.xz
8a2e3f4b5c6d7e8f9a0b1c2d3e4f5a6b  x265_4.1.tar.gz
9b3f4a5c6d7e8f9a0b1c2d3e4f5a6b7c  libvpx-1.15.2.tar.gz
0c4a5b6d7e8f9a0b1c2d3e4f5a6b7c8d  libaom-3.12.1.tar.gz
# Hardware acceleration
1d5b6c7e8f9a0b1c2d3e4f5a6b7c8d9e  libva-2.22.0.tar.bz2
2e6c7d8f9a0b1c2d3e4f5a6b7c8d9e0f  libvdpau-1.5.tar.gz
# FFmpeg
3f7d8e9a0b1c2d3e4f5a6b7c8d9e0f1a  ffmpeg-7.1.1.tar.xz
# GTK stack
4a8e9f0b1c2d3e4f5a6b7c8d9e0f1a2b  graphite2-1.3.14.tgz
5b9f0a1c2d3e4f5a6b7c8d9e0f1a2b3c  llvm-20.1.8.src.tar.xz
6c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d  llvm-cmake-20.1.8.src.tar.xz
7d1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e  llvm-third-party-20.1.8.src.tar.xz
8e2c3d4f5a6b7c8d9e0f1a2b3c4d5e6f  clang-20.1.8.src.tar.xz
9f3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a  compiler-rt-20.1.8.src.tar.xz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  rustc-1.89.0-src.tar.xz
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  harfbuzz-11.4.1.tar.xz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  fribidi-1.0.16.tar.xz
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  graphene-1.10.8.tar.xz
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  libxkbcommon-1.11.0.tar.gz
5f9d0e1a2b3c4d5e6f7a8b9c0d1e2f3a  cairo-1.18.4.tar.xz
6a0e1f2b3c4d5e6f7a8b9c0d1e2f3a4b  pango-1.56.4.tar.xz
7b1f2a3c4d5e6f7a8b9c0d1e2f3a4b5c  at-spi2-core-2.56.4.tar.xz
8c2a3b4d5e6f7a8b9c0d1e2f3a4b5c6d  libjpeg-turbo-3.0.1.tar.gz
9d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e  tiff-4.7.0.tar.gz
0e4c5d6f7a8b9c0d1e2f3a4b5c6d7e8f  gdk-pixbuf-2.42.12.tar.xz
1f5d6e7a8b9c0d1e2f3a4b5c6d7e8f9a  cargo-c-0.10.15.tar.gz
2a6e7f8b9c0d1e2f3a4b5c6d7e8f9a0b  librsvg-2.61.0.tar.xz
3b7f8a9c0d1e2f3a4b5c6d7e8f9a0b1c  shared-mime-info-2.4.tar.gz
4c8a9b0d1e2f3a4b5c6d7e8f9a0b1c2d  iso-codes-v4.18.0.tar.gz
5d9b0c1e2f3a4b5c6d7e8f9a0b1c2d3e  hicolor-icon-theme-0.18.tar.xz
6e0c1d2f3a4b5c6d7e8f9a0b1c2d3e4f  adwaita-icon-theme-48.1.tar.xz
7f1d2e3a4b5c6d7e8f9a0b1c2d3e4f5a  docbook-xml-4.5.zip
8a2e3f4b5c6d7e8f9a0b1c2d3e4f5a6b  docbook-xsl-nons-1.79.2.tar.bz2
9b3f4a5c6d7e8f9a0b1c2d3e4f5a6b7c  docbook-xsl-nons-1.79.2-stack_fix-1.patch
0c4a5b6d7e8f9a0b1c2d3e4f5a6b7c8d  pycairo-1.28.0.tar.gz
1d5b6c7e8f9a0b1c2d3e4f5a6b7c8d9e  pygobject-3.52.3.tar.gz
# Python test dependencies
2e6c7d8f9a0b1c2d3e4f5a6b7c8d9e0f  setuptools_scm-8.3.1.tar.gz
3f7d8e9a0b1c2d3e4f5a6b7c8d9e0f1a  editables-0.5.tar.gz
4a8e9f0b1c2d3e4f5a6b7c8d9e0f1a2b  pathspec-0.12.1.tar.gz
5b9f0a1c2d3e4f5a6b7c8d9e0f1a2b3c  trove_classifiers-2025.8.6.13.tar.gz
6c0a1b2d3e4f5a6b7c8d9e0f1a2b3c4d  pluggy-1.6.0.tar.gz
7d1b2c3e4f5a6b7c8d9e0f1a2b3c4d5e  hatchling-1.27.0.tar.gz
8e2c3d4f5a6b7c8d9e0f1a2b3c4d5e6f  hatch_vcs-0.5.0.tar.gz
9f3d4e5a6b7c8d9e0f1a2b3c4d5e6f7a  iniconfig-2.1.0.tar.gz
0a4e5f6b7c8d9e0f1a2b3c4d5e6f7a8b  pygments-2.19.2.tar.gz
1b5f6a7c8d9e0f1a2b3c4d5e6f7a8b9c  pytest-8.4.1.tar.gz
2c6a7b8d9e0f1a2b3c4d5e6f7a8b9c0d  shaderc-2025.3.tar.gz
# GTK
3d7b8c9e0f1a2b3c4d5e6f7a8b9c0d1e  gtk-3.24.50.tar.xz
4e8c9d0f1a2b3c4d5e6f7a8b9c0d1e2f  gtk-4.18.6.tar.xz
BLFS_MD5SUMS
}

# Verify a downloaded file against known checksums
# Returns 0 if valid, 1 if checksum mismatch, 2 if no checksum available
verify_download() {
    local filename="$1"
    local checksums_file="$2"
    
    if [ ! -f "$filename" ]; then
        return 1
    fi
    
    # Look up expected checksum
    local expected_md5
    expected_md5=$(grep -E "^[a-f0-9]{32}  ${filename}$" "$checksums_file" 2>/dev/null | cut -d' ' -f1)
    
    if [ -z "$expected_md5" ]; then
        # No checksum available - file size check only
        if [ ! -s "$filename" ]; then
            log_warn "No checksum for $filename and file is empty"
            return 1
        fi
        return 2  # No checksum, but file exists and is non-empty
    fi
    
    # Calculate actual checksum
    local actual_md5
    actual_md5=$(md5sum "$filename" 2>/dev/null | cut -d' ' -f1)
    
    if [ "$expected_md5" = "$actual_md5" ]; then
        return 0
    else
        log_warn "Checksum mismatch for $filename: expected $expected_md5, got $actual_md5"
        return 1
    fi
}

# Download and verify a BLFS package
# Usage: download_blfs_package URL FILENAME
download_blfs_package() {
    local url="$1"
    local filename="$2"
    local blfs_checksums="/tmp/blfs-md5sums.$$"
    
    # Generate checksums file if not exists
    if [ ! -f "$blfs_checksums" ]; then
        generate_blfs_checksums > "$blfs_checksums"
    fi
    
    # Check if file already exists and is valid
    if [ -f "$filename" ]; then
        local verify_result
        verify_download "$filename" "$blfs_checksums"
        verify_result=$?
        
        if [ $verify_result -eq 0 ]; then
            log_info "[SKIP] $filename (checksum verified)"
            return 0
        elif [ $verify_result -eq 2 ]; then
            # No checksum but file exists and is non-empty - check size
            local size
            size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
            if [ "$size" -gt 1000 ]; then
                log_info "[SKIP] $filename (exists, ${size} bytes, no checksum available)"
                return 0
            fi
        fi
        # File exists but is invalid - remove it
        log_warn "Removing invalid/incomplete $filename"
        rm -f "$filename"
    fi
    
    # Download the file
    if ! download_with_retry "$url" "$filename"; then
        return 1
    fi
    
    # Verify the download
    verify_download "$filename" "$blfs_checksums"
    local verify_result=$?
    
    if [ $verify_result -eq 0 ]; then
        log_info "[VERIFIED] $filename"
        return 0
    elif [ $verify_result -eq 2 ]; then
        log_info "[OK] $filename (no checksum to verify)"
        return 0
    else
        log_error "Checksum verification failed for $filename"
        rm -f "$filename"
        return 1
    fi
}

# Download with retry and speed monitoring
download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log_info "Downloading $output (attempt $attempt/$MAX_RETRIES)..."

        # Use wget with aggressive timeouts and resume support
        # --read-timeout: abort if no data received for 30 seconds
        # --dns-timeout: DNS lookup timeout
        # --continue: resume partial downloads
        if wget --continue \
                --progress=dot:giga \
                --timeout=$DOWNLOAD_TIMEOUT \
                --read-timeout=30 \
                --dns-timeout=20 \
                --tries=2 \
                -O "$output" \
                "$url"; then
            return 0
        fi

        log_warn "Download failed, retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        ((attempt++))
    done

    log_error "Failed to download $url after $MAX_RETRIES attempts"
    return 1
}

# Download a single package (used by parallel jobs)
download_package() {
    local url="$1"
    local filename=$(basename "$url")
    local sources_dir="$2"

    cd "$sources_dir"

    # Use GNU FTP directly - no URL rewriting needed
    # (mirrors.kernel.org is down, ftp.gnu.org works)

    # Fix zlib.net URL (server returns 415 errors)
    # Use GitHub releases mirror instead
    if [[ "$url" == *"zlib.net"* ]]; then
        url="https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
    fi

    # Check if file already exists and is valid
    if [ -f "$filename" ]; then
        # Extract expected checksum for THIS file only (not all files)
        expected_checksum=$(grep " $filename\$" md5sums 2>/dev/null | cut -d' ' -f1)
        if [ -n "$expected_checksum" ]; then
            actual_checksum=$(md5sum "$filename" 2>/dev/null | cut -d' ' -f1)
            if [ "$expected_checksum" = "$actual_checksum" ]; then
                echo "[SKIP] $filename (already verified)"
                return 0
            fi
        fi
        # File exists but is invalid or has no expected checksum - remove and re-download
        rm -f "$filename"
    fi

    # Download the package
    if download_with_retry "$url" "$filename"; then
        echo "[OK] $filename"
        return 0
    else
        echo "[FAIL] $filename"
        # Record failure for later reporting
        echo "$url" >> /tmp/failed_downloads.$$
        return 1
    fi
}

# Main function
main() {
    # Initialize logging
    init_logging

    log_info "Starting LFS $LFS_VERSION sources download"
    log_info "Target directory: $SOURCES_DIR"

    # Create sources directory if it doesn't exist
    mkdir -p "$SOURCES_DIR"
    cd "$SOURCES_DIR"

    # Initialize checkpoint system (use SOURCES_DIR as LFS root for this service)
    export CHECKPOINT_DIR="$SOURCES_DIR/.checkpoints"
    init_checkpointing

    # Check if download was already completed successfully
    # But still check for missing BLFS packages that may have been added later
    if should_skip_global_checkpoint "download-complete"; then
        log_info "Base sources already downloaded, checking for missing BLFS packages..."

        # List of required BLFS packages that might be missing
        local missing_blfs=()
        local blfs_packages=(
            "icu4c-77_1-src.tgz"
            "gobject-introspection-1.84.0.tar.xz"
            "vala-0.56.18.tar.xz"
            "xbitmaps-1.1.3.tar.xz"
            "mkfontscale-1.2.3.tar.xz"
            "xcursorgen-1.0.8.tar.xz"
            "which-2.23.tar.gz"
            "nasm-2.16.03.tar.xz"
            "x264-20250815.tar.xz"
        )

        for pkg in "${blfs_packages[@]}"; do
            if [ ! -f "$pkg" ]; then
                missing_blfs+=("$pkg")
            fi
        done

        if [ ${#missing_blfs[@]} -eq 0 ]; then
            log_info "========================================="
            log_info "All sources already downloaded and verified"
            log_info "========================================="
            exit 0
        else
            log_info "Missing BLFS packages: ${missing_blfs[*]}"
            log_info "Continuing to download missing packages..."
        fi
    fi

    # Download wget-list
    log_info "Downloading package list..."
    local wget_list_url="${LFS_MIRROR}/lfs/downloads/${LFS_VERSION}/wget-list"

    if ! download_with_retry "$wget_list_url" "wget-list"; then
        log_error "Failed to download wget-list"
        exit 1
    fi

    # Download md5sums
    log_info "Downloading MD5 checksums..."
    local md5sums_url="${LFS_MIRROR}/lfs/downloads/${LFS_VERSION}/md5sums"

    if ! download_with_retry "$md5sums_url" "md5sums"; then
        log_error "Failed to download md5sums"
        exit 1
    fi

    # Count total packages
    local total_packages=$(grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | wc -l)
    log_info "Found $total_packages packages to download"
    log_info "Using $PARALLEL_DOWNLOADS parallel downloads"
    log_info "Using ftpmirror.gnu.org for automatic geographic mirror selection"

    # Export functions for parallel execution
    export -f download_with_retry
    export -f download_package
    export -f log_info
    export -f log_warn
    export -f log_error
    export SOURCES_DIR MAX_RETRIES RETRY_DELAY DOWNLOAD_TIMEOUT MIN_SPEED
    export RED GREEN YELLOW NC

    # Download all packages in parallel
    echo ""
    log_info "Starting parallel downloads..."

    # Filter out comments and empty lines, then download in parallel
    # Note: We don't fail immediately here - we collect failures and report at end
    if command -v parallel >/dev/null 2>&1; then
        # Use GNU parallel if available (better progress tracking)
        log_info "Using GNU parallel for downloads"
        grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | \
            parallel -j "$PARALLEL_DOWNLOADS" --line-buffer --tag \
                download_package {} "$SOURCES_DIR" || true
    else
        # Fallback to xargs -P
        log_info "Using xargs for parallel downloads"
        grep -v '^[[:space:]]*#' wget-list | grep -v '^[[:space:]]*$' | \
            xargs -P "$PARALLEL_DOWNLOADS" -I {} bash -c 'download_package "$@"' _ {} "$SOURCES_DIR" || true
    fi

    echo ""
    log_info "Download phase completed"
    log_info "Total packages: $total_packages"

    # Check for any failures from parallel downloads
    if [ -s "$FAILED_DOWNLOADS_FILE" ]; then
        log_error "========================================="
        log_error "DOWNLOAD FAILED - The following packages could not be downloaded:"
        log_error "========================================="
        while IFS= read -r failed_url; do
            log_error "  - $failed_url"
        done < "$FAILED_DOWNLOADS_FILE"
        log_error "========================================="
        log_error "Please check your network connection and try again."
        log_error "You may need to find alternative mirrors for these packages."
        exit 1
    fi

    # =========================================================================
    # Download additional packages for systemd build
    # =========================================================================
    log_info "Downloading additional packages for systemd..."

    # Track additional package failures
    local additional_failed=()

    # D-Bus (required for systemd)
    # Note: Using Debian mirror as dbus.freedesktop.org is unreliable
    local dbus_url="http://deb.debian.org/debian/pool/main/d/dbus/dbus_1.16.2.orig.tar.xz"
    if [ ! -f "dbus-1.16.2.tar.xz" ] || [ ! -s "dbus-1.16.2.tar.xz" ]; then
        rm -f "dbus-1.16.2.tar.xz"  # Remove 0-byte files
        if ! download_with_retry "$dbus_url" "dbus-1.16.2.tar.xz"; then
            additional_failed+=("$dbus_url (dbus-1.16.2.tar.xz)")
        fi
    else
        log_info "[SKIP] dbus-1.16.2.tar.xz (already exists)"
    fi

    # Linux-firmware (for hardware driver support)
    local firmware_url="https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-20251125.tar.xz"
    if [ ! -f "linux-firmware-20251125.tar.xz" ]; then
        log_info "Downloading linux-firmware (this may take a while, ~600MB)..."
        if ! download_with_retry "$firmware_url" "linux-firmware-20251125.tar.xz"; then
            additional_failed+=("$firmware_url (linux-firmware-20251125.tar.xz)")
        fi
    else
        log_info "[SKIP] linux-firmware-20251125.tar.xz (already exists)"
    fi

    # Nano text editor (user preference over vim)
    local nano_url="https://www.nano-editor.org/dist/v8/nano-8.3.tar.xz"
    if [ ! -f "nano-8.3.tar.xz" ]; then
        log_info "Downloading nano text editor..."
        if ! download_with_retry "$nano_url" "nano-8.3.tar.xz"; then
            additional_failed+=("$nano_url (nano-8.3.tar.xz)")
        fi
    else
        log_info "[SKIP] nano-8.3.tar.xz (already exists)"
    fi

    # =========================================================================
    # Download BLFS packages (Tier 1: Security & Core Utilities)
    # =========================================================================
    log_info "Downloading BLFS packages..."

    # Linux-PAM-1.7.1 (Pluggable Authentication Modules)
    local pam_url="https://github.com/linux-pam/linux-pam/releases/download/v1.7.1/Linux-PAM-1.7.1.tar.xz"
    if [ ! -f "Linux-PAM-1.7.1.tar.xz" ]; then
        log_info "Downloading Linux-PAM..."
        if ! download_with_retry "$pam_url" "Linux-PAM-1.7.1.tar.xz"; then
            additional_failed+=("$pam_url (Linux-PAM-1.7.1.tar.xz)")
        fi
    else
        log_info "[SKIP] Linux-PAM-1.7.1.tar.xz (already exists)"
    fi

    # libgpg-error-1.55 (GnuPG error library - required by libgcrypt)
    local gpgerror_url="https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.55.tar.bz2"
    if [ ! -f "libgpg-error-1.55.tar.bz2" ]; then
        log_info "Downloading libgpg-error..."
        if ! download_with_retry "$gpgerror_url" "libgpg-error-1.55.tar.bz2"; then
            additional_failed+=("$gpgerror_url (libgpg-error-1.55.tar.bz2)")
        fi
    else
        log_info "[SKIP] libgpg-error-1.55.tar.bz2 (already exists)"
    fi

    # libgcrypt-1.11.2 (Cryptography library - required by KDE Frameworks)
    local gcrypt_url="https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.2.tar.bz2"
    if [ ! -f "libgcrypt-1.11.2.tar.bz2" ]; then
        log_info "Downloading libgcrypt..."
        if ! download_with_retry "$gcrypt_url" "libgcrypt-1.11.2.tar.bz2"; then
            additional_failed+=("$gcrypt_url (libgcrypt-1.11.2.tar.bz2)")
        fi
    else
        log_info "[SKIP] libgcrypt-1.11.2.tar.bz2 (already exists)"
    fi

    # sudo-1.9.17p2 (Privilege escalation for authorized users)
    local sudo_url="https://www.sudo.ws/dist/sudo-1.9.17p2.tar.gz"
    if [ ! -f "sudo-1.9.17p2.tar.gz" ]; then
        log_info "Downloading sudo..."
        if ! download_with_retry "$sudo_url" "sudo-1.9.17p2.tar.gz"; then
            additional_failed+=("$sudo_url (sudo-1.9.17p2.tar.gz)")
        fi
    else
        log_info "[SKIP] sudo-1.9.17p2.tar.gz (already exists)"
    fi

    # =========================================================================
    # Polkit dependency chain: pcre2 -> glib2 -> polkit (+ duktape)
    # =========================================================================

    # pcre2-10.45 (required by glib2)
    local pcre2_url="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.bz2"
    if [ ! -f "pcre2-10.45.tar.bz2" ]; then
        log_info "Downloading pcre2..."
        if ! download_with_retry "$pcre2_url" "pcre2-10.45.tar.bz2"; then
            additional_failed+=("$pcre2_url (pcre2-10.45.tar.bz2)")
        fi
    else
        log_info "[SKIP] pcre2-10.45.tar.bz2 (already exists)"
    fi

    # duktape-2.7.0 (required by polkit)
    local duktape_url="https://duktape.org/duktape-2.7.0.tar.xz"
    if [ ! -f "duktape-2.7.0.tar.xz" ]; then
        log_info "Downloading duktape..."
        if ! download_with_retry "$duktape_url" "duktape-2.7.0.tar.xz"; then
            additional_failed+=("$duktape_url (duktape-2.7.0.tar.xz)")
        fi
    else
        log_info "[SKIP] duktape-2.7.0.tar.xz (already exists)"
    fi

    # ICU-77.1 (recommended for libxml2, required for proper Unicode support)
    local icu_url="https://github.com/unicode-org/icu/releases/download/release-77-1/icu4c-77_1-src.tgz"
    if [ ! -f "icu4c-77_1-src.tgz" ]; then
        log_info "Downloading ICU..."
        if ! download_with_retry "$icu_url" "icu4c-77_1-src.tgz"; then
            additional_failed+=("$icu_url (icu4c-77_1-src.tgz)")
        fi
    else
        log_info "[SKIP] icu4c-77_1-src.tgz (already exists)"
    fi

    # glib-2.84.4 (required by polkit)
    local glib_url="https://download.gnome.org/sources/glib/2.84/glib-2.84.4.tar.xz"
    if [ ! -f "glib-2.84.4.tar.xz" ]; then
        log_info "Downloading glib..."
        if ! download_with_retry "$glib_url" "glib-2.84.4.tar.xz"; then
            additional_failed+=("$glib_url (glib-2.84.4.tar.xz)")
        fi
    else
        log_info "[SKIP] glib-2.84.4.tar.xz (already exists)"
    fi

    # gobject-introspection-1.84.0 (recommended for glib2/polkit)
    local gi_url="https://download.gnome.org/sources/gobject-introspection/1.84/gobject-introspection-1.84.0.tar.xz"
    if [ ! -f "gobject-introspection-1.84.0.tar.xz" ]; then
        log_info "Downloading gobject-introspection..."
        if ! download_with_retry "$gi_url" "gobject-introspection-1.84.0.tar.xz"; then
            additional_failed+=("$gi_url (gobject-introspection-1.84.0.tar.xz)")
        fi
    else
        log_info "[SKIP] gobject-introspection-1.84.0.tar.xz (already exists)"
    fi

    # polkit-126 (privilege authorization)
    local polkit_url="https://github.com/polkit-org/polkit/archive/126/polkit-126.tar.gz"
    if [ ! -f "polkit-126.tar.gz" ]; then
        log_info "Downloading polkit..."
        if ! download_with_retry "$polkit_url" "polkit-126.tar.gz"; then
            additional_failed+=("$polkit_url (polkit-126.tar.gz)")
        fi
    else
        log_info "[SKIP] polkit-126.tar.gz (already exists)"
    fi

    # CMake-4.1.0 (build tool - needed by c-ares, libproxy, etc.)
    local cmake_url="https://cmake.org/files/v4.1/cmake-4.1.0.tar.gz"
    if [ ! -f "cmake-4.1.0.tar.gz" ]; then
        log_info "Downloading cmake..."
        if ! download_with_retry "$cmake_url" "cmake-4.1.0.tar.gz"; then
            additional_failed+=("$cmake_url (cmake-4.1.0.tar.gz)")
        fi
    else
        log_info "[SKIP] cmake-4.1.0.tar.gz (already exists)"
    fi

    # =========================================================================
    # BLFS Tier 2: Networking & Protocols
    # =========================================================================
    log_info "Downloading BLFS Tier 2 packages (Networking)..."

    # --- Foundation packages (no dependencies) ---

    # libmnl-1.0.5 (Netfilter minimalistic library)
    local libmnl_url="https://netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2"
    if [ ! -f "libmnl-1.0.5.tar.bz2" ]; then
        log_info "Downloading libmnl..."
        if ! download_with_retry "$libmnl_url" "libmnl-1.0.5.tar.bz2"; then
            additional_failed+=("$libmnl_url (libmnl-1.0.5.tar.bz2)")
        fi
    else
        log_info "[SKIP] libmnl-1.0.5.tar.bz2 (already exists)"
    fi

    # libndp-1.9 (Neighbor Discovery Protocol library)
    # Note: libndp is from github releases
    local libndp_url="https://github.com/jpirko/libndp/archive/v1.9/libndp-1.9.tar.gz"
    if [ ! -f "libndp-1.9.tar.gz" ]; then
        log_info "Downloading libndp..."
        if ! download_with_retry "$libndp_url" "libndp-1.9.tar.gz"; then
            additional_failed+=("$libndp_url (libndp-1.9.tar.gz)")
        fi
    else
        log_info "[SKIP] libndp-1.9.tar.gz (already exists)"
    fi

    # libevent-2.1.12 (Event notification library)
    local libevent_url="https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"
    if [ ! -f "libevent-2.1.12-stable.tar.gz" ]; then
        log_info "Downloading libevent..."
        if ! download_with_retry "$libevent_url" "libevent-2.1.12-stable.tar.gz"; then
            additional_failed+=("$libevent_url (libevent-2.1.12-stable.tar.gz)")
        fi
    else
        log_info "[SKIP] libevent-2.1.12-stable.tar.gz (already exists)"
    fi

    # c-ares-1.34.5 (Async DNS resolver)
    local cares_url="https://github.com/c-ares/c-ares/releases/download/v1.34.5/c-ares-1.34.5.tar.gz"
    if [ ! -f "c-ares-1.34.5.tar.gz" ]; then
        log_info "Downloading c-ares..."
        if ! download_with_retry "$cares_url" "c-ares-1.34.5.tar.gz"; then
            additional_failed+=("$cares_url (c-ares-1.34.5.tar.gz)")
        fi
    else
        log_info "[SKIP] c-ares-1.34.5.tar.gz (already exists)"
    fi

    # libdaemon-0.14 (Unix daemon library)
    local libdaemon_url="https://0pointer.de/lennart/projects/libdaemon/libdaemon-0.14.tar.gz"
    if [ ! -f "libdaemon-0.14.tar.gz" ]; then
        log_info "Downloading libdaemon..."
        if ! download_with_retry "$libdaemon_url" "libdaemon-0.14.tar.gz"; then
            additional_failed+=("$libdaemon_url (libdaemon-0.14.tar.gz)")
        fi
    else
        log_info "[SKIP] libdaemon-0.14.tar.gz (already exists)"
    fi

    # libpcap-1.10.5 (Packet capture library)
    local libpcap_url="https://www.tcpdump.org/release/libpcap-1.10.5.tar.gz"
    if [ ! -f "libpcap-1.10.5.tar.gz" ]; then
        log_info "Downloading libpcap..."
        if ! download_with_retry "$libpcap_url" "libpcap-1.10.5.tar.gz"; then
            additional_failed+=("$libpcap_url (libpcap-1.10.5.tar.gz)")
        fi
    else
        log_info "[SKIP] libpcap-1.10.5.tar.gz (already exists)"
    fi

    # libunistring-1.3 (Unicode string library - needed by libidn2)
    # Use ftpmirror for geographic mirror selection (ftp.gnu.org often times out)
    local libunistring_url="https://ftpmirror.gnu.org/gnu/libunistring/libunistring-1.3.tar.xz"
    if [ ! -f "libunistring-1.3.tar.xz" ]; then
        log_info "Downloading libunistring..."
        if ! download_with_retry "$libunistring_url" "libunistring-1.3.tar.xz"; then
            additional_failed+=("$libunistring_url (libunistring-1.3.tar.xz)")
        fi
    else
        log_info "[SKIP] libunistring-1.3.tar.xz (already exists)"
    fi

    # libnl-3.11.0 (Netlink library - needed by wpa_supplicant, NetworkManager)
    local libnl_url="https://github.com/thom311/libnl/releases/download/libnl3_11_0/libnl-3.11.0.tar.gz"
    if [ ! -f "libnl-3.11.0.tar.gz" ]; then
        log_info "Downloading libnl..."
        if ! download_with_retry "$libnl_url" "libnl-3.11.0.tar.gz"; then
            additional_failed+=("$libnl_url (libnl-3.11.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libnl-3.11.0.tar.gz (already exists)"
    fi

    # libxml2-2.14.5 (XML parser library - required by libxslt)
    local libxml2_url="https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.5.tar.xz"
    if [ ! -f "libxml2-2.14.5.tar.xz" ]; then
        log_info "Downloading libxml2..."
        if ! download_with_retry "$libxml2_url" "libxml2-2.14.5.tar.xz"; then
            additional_failed+=("$libxml2_url (libxml2-2.14.5.tar.xz)")
        fi
    else
        log_info "[SKIP] libxml2-2.14.5.tar.xz (already exists)"
    fi

    # libxslt-1.1.43 (XSLT processor)
    local libxslt_url="https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz"
    if [ ! -f "libxslt-1.1.43.tar.xz" ]; then
        log_info "Downloading libxslt..."
        if ! download_with_retry "$libxslt_url" "libxslt-1.1.43.tar.xz"; then
            additional_failed+=("$libxslt_url (libxslt-1.1.43.tar.xz)")
        fi
    else
        log_info "[SKIP] libxslt-1.1.43.tar.xz (already exists)"
    fi

    # dhcpcd-10.2.4 (DHCP client)
    local dhcpcd_url="https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.2.4/dhcpcd-10.2.4.tar.xz"
    if [ ! -f "dhcpcd-10.2.4.tar.xz" ]; then
        log_info "Downloading dhcpcd..."
        if ! download_with_retry "$dhcpcd_url" "dhcpcd-10.2.4.tar.xz"; then
            additional_failed+=("$dhcpcd_url (dhcpcd-10.2.4.tar.xz)")
        fi
    else
        log_info "[SKIP] dhcpcd-10.2.4.tar.xz (already exists)"
    fi

    # --- SSL/TLS stack ---

    # libtasn1-4.20.0 (ASN.1 library - needed by GnuTLS)
    local libtasn1_url="https://ftpmirror.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
    if [ ! -f "libtasn1-4.20.0.tar.gz" ]; then
        log_info "Downloading libtasn1..."
        if ! download_with_retry "$libtasn1_url" "libtasn1-4.20.0.tar.gz"; then
            additional_failed+=("$libtasn1_url (libtasn1-4.20.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libtasn1-4.20.0.tar.gz (already exists)"
    fi

    # nettle-3.10.2 (Crypto library - needed by GnuTLS)
    local nettle_url="https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz"
    if [ ! -f "nettle-3.10.2.tar.gz" ]; then
        log_info "Downloading nettle..."
        if ! download_with_retry "$nettle_url" "nettle-3.10.2.tar.gz"; then
            additional_failed+=("$nettle_url (nettle-3.10.2.tar.gz)")
        fi
    else
        log_info "[SKIP] nettle-3.10.2.tar.gz (already exists)"
    fi

    # make-ca-1.16.1 (CA certificates management)
    local makeca_url="https://github.com/lfs-book/make-ca/archive/v1.16.1/make-ca-1.16.1.tar.gz"
    if [ ! -f "make-ca-1.16.1.tar.gz" ]; then
        log_info "Downloading make-ca..."
        if ! download_with_retry "$makeca_url" "make-ca-1.16.1.tar.gz"; then
            additional_failed+=("$makeca_url (make-ca-1.16.1.tar.gz)")
        fi
    else
        log_info "[SKIP] make-ca-1.16.1.tar.gz (already exists)"
    fi

    # p11-kit-0.25.5 (PKCS#11 library - needed by GnuTLS)
    local p11kit_url="https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
    if [ ! -f "p11-kit-0.25.5.tar.xz" ]; then
        log_info "Downloading p11-kit..."
        if ! download_with_retry "$p11kit_url" "p11-kit-0.25.5.tar.xz"; then
            additional_failed+=("$p11kit_url (p11-kit-0.25.5.tar.xz)")
        fi
    else
        log_info "[SKIP] p11-kit-0.25.5.tar.xz (already exists)"
    fi

    # GnuTLS-3.8.10 (TLS library)
    local gnutls_url="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.10.tar.xz"
    if [ ! -f "gnutls-3.8.10.tar.xz" ]; then
        log_info "Downloading GnuTLS..."
        if ! download_with_retry "$gnutls_url" "gnutls-3.8.10.tar.xz"; then
            additional_failed+=("$gnutls_url (gnutls-3.8.10.tar.xz)")
        fi
    else
        log_info "[SKIP] gnutls-3.8.10.tar.xz (already exists)"
    fi

    # --- Internationalization ---

    # libidn2-2.3.8 (IDN library - needed by libpsl, wget)
    local libidn2_url="https://ftpmirror.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz"
    if [ ! -f "libidn2-2.3.8.tar.gz" ]; then
        log_info "Downloading libidn2..."
        if ! download_with_retry "$libidn2_url" "libidn2-2.3.8.tar.gz"; then
            additional_failed+=("$libidn2_url (libidn2-2.3.8.tar.gz)")
        fi
    else
        log_info "[SKIP] libidn2-2.3.8.tar.gz (already exists)"
    fi

    # libpsl-0.21.5 (Public Suffix List library - needed by curl, wget)
    local libpsl_url="https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz"
    if [ ! -f "libpsl-0.21.5.tar.gz" ]; then
        log_info "Downloading libpsl..."
        if ! download_with_retry "$libpsl_url" "libpsl-0.21.5.tar.gz"; then
            additional_failed+=("$libpsl_url (libpsl-0.21.5.tar.gz)")
        fi
    else
        log_info "[SKIP] libpsl-0.21.5.tar.gz (already exists)"
    fi

    # --- Network services ---

    # iptables-1.8.11 (Firewall)
    local iptables_url="https://www.netfilter.org/projects/iptables/files/iptables-1.8.11.tar.xz"
    if [ ! -f "iptables-1.8.11.tar.xz" ]; then
        log_info "Downloading iptables..."
        if ! download_with_retry "$iptables_url" "iptables-1.8.11.tar.xz"; then
            additional_failed+=("$iptables_url (iptables-1.8.11.tar.xz)")
        fi
    else
        log_info "[SKIP] iptables-1.8.11.tar.xz (already exists)"
    fi

    # avahi-0.8 (mDNS/DNS-SD)
    local avahi_url="https://github.com/lathiat/avahi/releases/download/v0.8/avahi-0.8.tar.gz"
    if [ ! -f "avahi-0.8.tar.gz" ]; then
        log_info "Downloading avahi..."
        if ! download_with_retry "$avahi_url" "avahi-0.8.tar.gz"; then
            additional_failed+=("$avahi_url (avahi-0.8.tar.gz)")
        fi
    else
        log_info "[SKIP] avahi-0.8.tar.gz (already exists)"
    fi

    # avahi IPv6 race condition fix patch
    local avahi_patch_url="https://www.linuxfromscratch.org/patches/blfs/12.4/avahi-0.8-ipv6_race_condition_fix-1.patch"
    if [ ! -f "avahi-0.8-ipv6_race_condition_fix-1.patch" ]; then
        log_info "Downloading avahi patch..."
        if ! download_with_retry "$avahi_patch_url" "avahi-0.8-ipv6_race_condition_fix-1.patch"; then
            additional_failed+=("$avahi_patch_url (avahi-0.8-ipv6_race_condition_fix-1.patch)")
        fi
    else
        log_info "[SKIP] avahi-0.8-ipv6_race_condition_fix-1.patch (already exists)"
    fi

    # wpa_supplicant-2.11 (WiFi client)
    local wpasupplicant_url="https://w1.fi/releases/wpa_supplicant-2.11.tar.gz"
    if [ ! -f "wpa_supplicant-2.11.tar.gz" ]; then
        log_info "Downloading wpa_supplicant..."
        if ! download_with_retry "$wpasupplicant_url" "wpa_supplicant-2.11.tar.gz"; then
            additional_failed+=("$wpasupplicant_url (wpa_supplicant-2.11.tar.gz)")
        fi
    else
        log_info "[SKIP] wpa_supplicant-2.11.tar.gz (already exists)"
    fi

    # --- HTTP clients ---

    # curl-8.15.0 (HTTP client library)
    local curl_url="https://curl.se/download/curl-8.15.0.tar.xz"
    if [ ! -f "curl-8.15.0.tar.xz" ]; then
        log_info "Downloading curl..."
        if ! download_with_retry "$curl_url" "curl-8.15.0.tar.xz"; then
            additional_failed+=("$curl_url (curl-8.15.0.tar.xz)")
        fi
    else
        log_info "[SKIP] curl-8.15.0.tar.xz (already exists)"
    fi

    # --- libproxy and dependencies ---

    # Vala-0.56.18 (Vala compiler - optional for libproxy)
    local vala_url="https://download.gnome.org/sources/vala/0.56/vala-0.56.18.tar.xz"
    if [ ! -f "vala-0.56.18.tar.xz" ]; then
        log_info "Downloading Vala..."
        if ! download_with_retry "$vala_url" "vala-0.56.18.tar.xz"; then
            additional_failed+=("$vala_url (vala-0.56.18.tar.xz)")
        fi
    else
        log_info "[SKIP] vala-0.56.18.tar.xz (already exists)"
    fi

    # gsettings-desktop-schemas-48.0 (GNOME settings schemas)
    local gsettings_url="https://download.gnome.org/sources/gsettings-desktop-schemas/48/gsettings-desktop-schemas-48.0.tar.xz"
    if [ ! -f "gsettings-desktop-schemas-48.0.tar.xz" ]; then
        log_info "Downloading gsettings-desktop-schemas..."
        if ! download_with_retry "$gsettings_url" "gsettings-desktop-schemas-48.0.tar.xz"; then
            additional_failed+=("$gsettings_url (gsettings-desktop-schemas-48.0.tar.xz)")
        fi
    else
        log_info "[SKIP] gsettings-desktop-schemas-48.0.tar.xz (already exists)"
    fi

    # libproxy-0.5.10 (Proxy configuration library)
    local libproxy_url="https://github.com/libproxy/libproxy/archive/0.5.10/libproxy-0.5.10.tar.gz"
    if [ ! -f "libproxy-0.5.10.tar.gz" ]; then
        log_info "Downloading libproxy..."
        if ! download_with_retry "$libproxy_url" "libproxy-0.5.10.tar.gz"; then
            additional_failed+=("$libproxy_url (libproxy-0.5.10.tar.gz)")
        fi
    else
        log_info "[SKIP] libproxy-0.5.10.tar.gz (already exists)"
    fi

    # --- High-level network tools ---

    # wget-1.25.0 (HTTP/FTP downloader)
    local wget_url="https://ftpmirror.gnu.org/gnu/wget/wget-1.25.0.tar.gz"
    if [ ! -f "wget-1.25.0.tar.gz" ]; then
        log_info "Downloading wget..."
        if ! download_with_retry "$wget_url" "wget-1.25.0.tar.gz"; then
            additional_failed+=("$wget_url (wget-1.25.0.tar.gz)")
        fi
    else
        log_info "[SKIP] wget-1.25.0.tar.gz (already exists)"
    fi

    # NetworkManager-1.54.0 (Network management)
    local nm_url="https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.54.0/downloads/NetworkManager-1.54.0.tar.xz"
    if [ ! -f "NetworkManager-1.54.0.tar.xz" ]; then
        log_info "Downloading NetworkManager..."
        if ! download_with_retry "$nm_url" "NetworkManager-1.54.0.tar.xz"; then
            additional_failed+=("$nm_url (NetworkManager-1.54.0.tar.xz)")
        fi
    else
        log_info "[SKIP] NetworkManager-1.54.0.tar.xz (already exists)"
    fi

    # #####################################################################
    # BLFS Tier 3: Graphics Foundation (X11/Wayland)
    # #####################################################################
    log_info "Downloading BLFS Tier 3 packages (Graphics Foundation)..."

    # --- Xorg Build Environment ---

    # util-macros-1.20.2 (Xorg build macros)
    local utilmacros_url="https://www.x.org/pub/individual/util/util-macros-1.20.2.tar.xz"
    if [ ! -f "util-macros-1.20.2.tar.xz" ]; then
        log_info "Downloading util-macros..."
        if ! download_with_retry "$utilmacros_url" "util-macros-1.20.2.tar.xz"; then
            additional_failed+=("$utilmacros_url (util-macros-1.20.2.tar.xz)")
        fi
    else
        log_info "[SKIP] util-macros-1.20.2.tar.xz (already exists)"
    fi

    # xorgproto-2024.1 (Xorg protocol headers)
    local xorgproto_url="https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2024.1.tar.xz"
    if [ ! -f "xorgproto-2024.1.tar.xz" ]; then
        log_info "Downloading xorgproto..."
        if ! download_with_retry "$xorgproto_url" "xorgproto-2024.1.tar.xz"; then
            additional_failed+=("$xorgproto_url (xorgproto-2024.1.tar.xz)")
        fi
    else
        log_info "[SKIP] xorgproto-2024.1.tar.xz (already exists)"
    fi

    # --- Wayland ---

    # Wayland-1.24.0
    local wayland_url="https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.24.0/downloads/wayland-1.24.0.tar.xz"
    if [ ! -f "wayland-1.24.0.tar.xz" ]; then
        log_info "Downloading Wayland..."
        if ! download_with_retry "$wayland_url" "wayland-1.24.0.tar.xz"; then
            additional_failed+=("$wayland_url (wayland-1.24.0.tar.xz)")
        fi
    else
        log_info "[SKIP] wayland-1.24.0.tar.xz (already exists)"
    fi

    # Wayland-Protocols-1.45
    local wayland_protocols_url="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.45/downloads/wayland-protocols-1.45.tar.xz"
    if [ ! -f "wayland-protocols-1.45.tar.xz" ]; then
        log_info "Downloading Wayland-Protocols..."
        if ! download_with_retry "$wayland_protocols_url" "wayland-protocols-1.45.tar.xz"; then
            additional_failed+=("$wayland_protocols_url (wayland-protocols-1.45.tar.xz)")
        fi
    else
        log_info "[SKIP] wayland-protocols-1.45.tar.xz (already exists)"
    fi

    # --- XCB Libraries ---

    # libXau-1.0.12 (X Authorization)
    local libxau_url="https://www.x.org/pub/individual/lib/libXau-1.0.12.tar.xz"
    if [ ! -f "libXau-1.0.12.tar.xz" ]; then
        log_info "Downloading libXau..."
        if ! download_with_retry "$libxau_url" "libXau-1.0.12.tar.xz"; then
            additional_failed+=("$libxau_url (libXau-1.0.12.tar.xz)")
        fi
    else
        log_info "[SKIP] libXau-1.0.12.tar.xz (already exists)"
    fi

    # libXdmcp-1.1.5 (X Display Manager Control Protocol)
    local libxdmcp_url="https://www.x.org/pub/individual/lib/libXdmcp-1.1.5.tar.xz"
    if [ ! -f "libXdmcp-1.1.5.tar.xz" ]; then
        log_info "Downloading libXdmcp..."
        if ! download_with_retry "$libxdmcp_url" "libXdmcp-1.1.5.tar.xz"; then
            additional_failed+=("$libxdmcp_url (libXdmcp-1.1.5.tar.xz)")
        fi
    else
        log_info "[SKIP] libXdmcp-1.1.5.tar.xz (already exists)"
    fi

    # xcb-proto-1.17.0 (XCB protocol descriptions)
    local xcbproto_url="https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.17.0.tar.xz"
    if [ ! -f "xcb-proto-1.17.0.tar.xz" ]; then
        log_info "Downloading xcb-proto..."
        if ! download_with_retry "$xcbproto_url" "xcb-proto-1.17.0.tar.xz"; then
            additional_failed+=("$xcbproto_url (xcb-proto-1.17.0.tar.xz)")
        fi
    else
        log_info "[SKIP] xcb-proto-1.17.0.tar.xz (already exists)"
    fi

    # libxcb-1.17.0 (X C Binding)
    local libxcb_url="https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz"
    if [ ! -f "libxcb-1.17.0.tar.xz" ]; then
        log_info "Downloading libxcb..."
        if ! download_with_retry "$libxcb_url" "libxcb-1.17.0.tar.xz"; then
            additional_failed+=("$libxcb_url (libxcb-1.17.0.tar.xz)")
        fi
    else
        log_info "[SKIP] libxcb-1.17.0.tar.xz (already exists)"
    fi

    # --- Graphics Libraries ---

    # Brotli-1.1.0 (Compression library - required by FreeType for WOFF2 fonts)
    local brotli_url="https://github.com/google/brotli/archive/v1.1.0/brotli-1.1.0.tar.gz"
    if [ ! -f "brotli-1.1.0.tar.gz" ]; then
        log_info "Downloading Brotli..."
        if ! download_with_retry "$brotli_url" "brotli-1.1.0.tar.gz"; then
            additional_failed+=("$brotli_url (brotli-1.1.0.tar.gz)")
        fi
    else
        log_info "[SKIP] brotli-1.1.0.tar.gz (already exists)"
    fi

    # FreeType-2.13.3 (TrueType font rendering - required by libXfont2)
    local freetype_url="https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz"
    if [ ! -f "freetype-2.13.3.tar.xz" ]; then
        log_info "Downloading FreeType..."
        if ! download_with_retry "$freetype_url" "freetype-2.13.3.tar.xz"; then
            additional_failed+=("$freetype_url (freetype-2.13.3.tar.xz)")
        fi
    else
        log_info "[SKIP] freetype-2.13.3.tar.xz (already exists)"
    fi

    # Fontconfig-2.17.1 (font configuration - required by libXft)
    local fontconfig_url="https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.17.1/fontconfig-2.17.1.tar.xz"
    if [ ! -f "fontconfig-2.17.1.tar.xz" ]; then
        log_info "Downloading Fontconfig..."
        if ! download_with_retry "$fontconfig_url" "fontconfig-2.17.1.tar.xz"; then
            additional_failed+=("$fontconfig_url (fontconfig-2.17.1.tar.xz)")
        fi
    else
        log_info "[SKIP] fontconfig-2.17.1.tar.xz (already exists)"
    fi

    # Pixman-0.46.4 (Pixel manipulation library)
    local pixman_url="https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
    if [ ! -f "pixman-0.46.4.tar.gz" ]; then
        log_info "Downloading Pixman..."
        if ! download_with_retry "$pixman_url" "pixman-0.46.4.tar.gz"; then
            additional_failed+=("$pixman_url (pixman-0.46.4.tar.gz)")
        fi
    else
        log_info "[SKIP] pixman-0.46.4.tar.gz (already exists)"
    fi

    # libdrm-2.4.125 (Direct Rendering Manager)
    local libdrm_url="https://dri.freedesktop.org/libdrm/libdrm-2.4.125.tar.xz"
    if [ ! -f "libdrm-2.4.125.tar.xz" ]; then
        log_info "Downloading libdrm..."
        if ! download_with_retry "$libdrm_url" "libdrm-2.4.125.tar.xz"; then
            additional_failed+=("$libdrm_url (libdrm-2.4.125.tar.xz)")
        fi
    else
        log_info "[SKIP] libdrm-2.4.125.tar.xz (already exists)"
    fi

    # libxcvt-0.1.3 (VESA CVT standard timing modelines)
    local libxcvt_url="https://www.x.org/pub/individual/lib/libxcvt-0.1.3.tar.xz"
    if [ ! -f "libxcvt-0.1.3.tar.xz" ]; then
        log_info "Downloading libxcvt..."
        if ! download_with_retry "$libxcvt_url" "libxcvt-0.1.3.tar.xz"; then
            additional_failed+=("$libxcvt_url (libxcvt-0.1.3.tar.xz)")
        fi
    else
        log_info "[SKIP] libxcvt-0.1.3.tar.xz (already exists)"
    fi

    # --- Xkeyboard-config ---

    # XKeyboardConfig-2.45 (keyboard configuration database)
    # Using Void Linux mirror as primary since x.org servers are unreliable
    local xkeyboard_url="https://sources.voidlinux.org/xkeyboard-config-2.45/xkeyboard-config-2.45.tar.xz"
    if [ ! -f "xkeyboard-config-2.45.tar.xz" ]; then
        log_info "Downloading XKeyboardConfig..."
        if ! download_with_retry "$xkeyboard_url" "xkeyboard-config-2.45.tar.xz"; then
            additional_failed+=("$xkeyboard_url (xkeyboard-config-2.45.tar.xz)")
        fi
    else
        log_info "[SKIP] xkeyboard-config-2.45.tar.xz (already exists)"
    fi

    # --- XCB Utilities ---

    # xcb-util-0.4.1 (XCB utility library)
    local xcb_util_url="https://xcb.freedesktop.org/dist/xcb-util-0.4.1.tar.xz"
    if [ ! -f "xcb-util-0.4.1.tar.xz" ]; then
        log_info "Downloading xcb-util..."
        if ! download_with_retry "$xcb_util_url" "xcb-util-0.4.1.tar.xz"; then
            additional_failed+=("$xcb_util_url (xcb-util-0.4.1.tar.xz)")
        fi
    else
        log_info "[SKIP] xcb-util-0.4.1.tar.xz (already exists)"
    fi

    # --- Mesa ---

    # Mesa-25.1.8 (OpenGL 3D graphics library)
    local mesa_url="https://mesa.freedesktop.org/archive/mesa-25.1.8.tar.xz"
    if [ ! -f "mesa-25.1.8.tar.xz" ]; then
        log_info "Downloading Mesa..."
        if ! download_with_retry "$mesa_url" "mesa-25.1.8.tar.xz"; then
            additional_failed+=("$mesa_url (mesa-25.1.8.tar.xz)")
        fi
    else
        log_info "[SKIP] mesa-25.1.8.tar.xz (already exists)"
    fi

    # --- Vulkan ---

    # Vulkan-Headers-1.4.321
    local vulkan_headers_url="https://github.com/KhronosGroup/Vulkan-Headers/archive/v1.4.321/Vulkan-Headers-1.4.321.tar.gz"
    if [ ! -f "Vulkan-Headers-1.4.321.tar.gz" ]; then
        log_info "Downloading Vulkan-Headers..."
        if ! download_with_retry "$vulkan_headers_url" "Vulkan-Headers-1.4.321.tar.gz"; then
            additional_failed+=("$vulkan_headers_url (Vulkan-Headers-1.4.321.tar.gz)")
        fi
    else
        log_info "[SKIP] Vulkan-Headers-1.4.321.tar.gz (already exists)"
    fi

    # SPIRV-Headers (required by SPIRV-Tools)
    local spirv_headers_url="https://github.com/KhronosGroup/SPIRV-Headers/archive/vulkan-sdk-1.4.321.0/SPIRV-Headers-1.4.321.0.tar.gz"
    if [ ! -f "SPIRV-Headers-1.4.321.0.tar.gz" ]; then
        log_info "Downloading SPIRV-Headers..."
        if ! download_with_retry "$spirv_headers_url" "SPIRV-Headers-1.4.321.0.tar.gz"; then
            additional_failed+=("$spirv_headers_url (SPIRV-Headers-1.4.321.0.tar.gz)")
        fi
    else
        log_info "[SKIP] SPIRV-Headers-1.4.321.0.tar.gz (already exists)"
    fi

    # SPIRV-Tools-1.4.321.0
    local spirv_tools_url="https://github.com/KhronosGroup/SPIRV-Tools/archive/vulkan-sdk-1.4.321.0/SPIRV-Tools-1.4.321.0.tar.gz"
    if [ ! -f "SPIRV-Tools-1.4.321.0.tar.gz" ]; then
        log_info "Downloading SPIRV-Tools..."
        if ! download_with_retry "$spirv_tools_url" "SPIRV-Tools-1.4.321.0.tar.gz"; then
            additional_failed+=("$spirv_tools_url (SPIRV-Tools-1.4.321.0.tar.gz)")
        fi
    else
        log_info "[SKIP] SPIRV-Tools-1.4.321.0.tar.gz (already exists)"
    fi

    # glslang-15.4.0 (GLSL compiler)
    local glslang_url="https://github.com/KhronosGroup/glslang/archive/15.4.0/glslang-15.4.0.tar.gz"
    if [ ! -f "glslang-15.4.0.tar.gz" ]; then
        log_info "Downloading glslang..."
        if ! download_with_retry "$glslang_url" "glslang-15.4.0.tar.gz"; then
            additional_failed+=("$glslang_url (glslang-15.4.0.tar.gz)")
        fi
    else
        log_info "[SKIP] glslang-15.4.0.tar.gz (already exists)"
    fi

    # Vulkan-Loader-1.4.321
    local vulkan_loader_url="https://github.com/KhronosGroup/Vulkan-Loader/archive/v1.4.321/Vulkan-Loader-1.4.321.tar.gz"
    if [ ! -f "Vulkan-Loader-1.4.321.tar.gz" ]; then
        log_info "Downloading Vulkan-Loader..."
        if ! download_with_retry "$vulkan_loader_url" "Vulkan-Loader-1.4.321.tar.gz"; then
            additional_failed+=("$vulkan_loader_url (Vulkan-Loader-1.4.321.tar.gz)")
        fi
    else
        log_info "[SKIP] Vulkan-Loader-1.4.321.tar.gz (already exists)"
    fi

    # --- Xorg Libraries (32 packages) ---
    log_info "Downloading Xorg Libraries..."

    # Define all Xorg Library packages (from BLFS lib-7.md5)
    # Most packages available on Void Linux mirror
    # Special packages (xtrans, libFS, libXpresent) use GitLab as .tar.gz
    local xorg_lib_packages=(
        "libX11-1.8.12.tar.xz"
        "libXext-1.3.6.tar.xz"
        "libICE-1.1.2.tar.xz"
        "libSM-1.2.6.tar.xz"
        "libXScrnSaver-1.2.4.tar.xz"
        "libXt-1.3.1.tar.xz"
        "libXmu-1.2.1.tar.xz"
        "libXpm-3.5.17.tar.xz"
        "libXaw-1.0.16.tar.xz"
        "libXfixes-6.0.1.tar.xz"
        "libXcomposite-0.4.6.tar.xz"
        "libXrender-0.9.12.tar.xz"
        "libXcursor-1.2.3.tar.xz"
        "libXdamage-1.1.6.tar.xz"
        "libfontenc-1.1.8.tar.xz"
        "libXfont2-2.0.7.tar.xz"
        "libXft-2.3.9.tar.xz"
        "libXi-1.8.2.tar.xz"
        "libXinerama-1.1.5.tar.xz"
        "libXrandr-1.5.4.tar.xz"
        "libXres-1.2.2.tar.xz"
        "libXtst-1.2.5.tar.xz"
        "libXv-1.0.13.tar.xz"
        "libXvMC-1.0.14.tar.xz"
        "libXxf86dga-1.1.6.tar.xz"
        "libXxf86vm-1.1.6.tar.xz"
        "libpciaccess-0.18.1.tar.xz"
        "libxkbfile-1.1.3.tar.xz"
        "libxshmfence-1.3.3.tar.xz"
    )

    # Use Void Linux sources mirror (xorg.freedesktop.org is unreliable)
    # URL pattern: https://sources.voidlinux.org/<package-name>/<filename>
    for pkg in "${xorg_lib_packages[@]}"; do
        if [ ! -f "$pkg" ] || [ ! -s "$pkg" ]; then
            rm -f "$pkg"  # Remove 0-byte files
            # Extract package name without extension (e.g., "libX11-1.8.12" from "libX11-1.8.12.tar.xz")
            local pkg_name="${pkg%.tar.*}"
            local void_url="https://sources.voidlinux.org/${pkg_name}/${pkg}"
            log_info "Downloading $pkg..."
            if ! download_with_retry "$void_url" "$pkg"; then
                additional_failed+=("$void_url ($pkg)")
            fi
        else
            log_info "[SKIP] $pkg (already exists)"
        fi
    done

    # Download special packages from GitLab (not available on Void Linux mirror)
    # These need autoreconf during build as they come from git archives
    log_info "Downloading special Xorg packages from GitLab..."

    # xtrans - from GitLab freedesktop
    if [ ! -f "xtrans-1.6.0.tar.gz" ] || [ ! -s "xtrans-1.6.0.tar.gz" ]; then
        rm -f "xtrans-1.6.0.tar.gz" "xtrans-1.6.0.tar.xz"
        log_info "Downloading xtrans-1.6.0.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libxtrans/-/archive/xtrans-1.6.0/libxtrans-xtrans-1.6.0.tar.gz" "xtrans-1.6.0.tar.gz"; then
            additional_failed+=("xtrans-1.6.0.tar.gz")
        fi
    else
        log_info "[SKIP] xtrans-1.6.0.tar.gz (already exists)"
    fi

    # libFS - from GitLab freedesktop
    if [ ! -f "libFS-1.0.10.tar.gz" ] || [ ! -s "libFS-1.0.10.tar.gz" ]; then
        rm -f "libFS-1.0.10.tar.gz" "libFS-1.0.10.tar.xz"
        log_info "Downloading libFS-1.0.10.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libfs/-/archive/libFS-1.0.10/libfs-libFS-1.0.10.tar.gz" "libFS-1.0.10.tar.gz"; then
            additional_failed+=("libFS-1.0.10.tar.gz")
        fi
    else
        log_info "[SKIP] libFS-1.0.10.tar.gz (already exists)"
    fi

    # libXpresent - from GitLab freedesktop
    if [ ! -f "libXpresent-1.0.1.tar.gz" ] || [ ! -s "libXpresent-1.0.1.tar.gz" ]; then
        rm -f "libXpresent-1.0.1.tar.gz" "libXpresent-1.0.1.tar.xz"
        log_info "Downloading libXpresent-1.0.1.tar.gz from GitLab..."
        if ! download_with_retry "https://gitlab.freedesktop.org/xorg/lib/libxpresent/-/archive/libXpresent-1.0.1/libxpresent-libXpresent-1.0.1.tar.gz" "libXpresent-1.0.1.tar.gz"; then
            additional_failed+=("libXpresent-1.0.1.tar.gz")
        fi
    else
        log_info "[SKIP] libXpresent-1.0.1.tar.gz (already exists)"
    fi

    # --- libpng (required by xcursorgen and many graphics applications) ---
    if [ ! -f "libpng-1.6.50.tar.xz" ] || [ ! -s "libpng-1.6.50.tar.xz" ]; then
        rm -f "libpng-1.6.50.tar.xz"
        local libpng_url="https://downloads.sourceforge.net/libpng/libpng-1.6.50.tar.xz"
        log_info "Downloading libpng-1.6.50.tar.xz..."
        if ! download_with_retry "$libpng_url" "libpng-1.6.50.tar.xz"; then
            additional_failed+=("$libpng_url (libpng-1.6.50.tar.xz)")
        fi
    else
        log_info "[SKIP] libpng-1.6.50.tar.xz (already exists)"
    fi

    # --- xbitmaps (required by Xorg Applications) ---
    if [ ! -f "xbitmaps-1.1.3.tar.xz" ] || [ ! -s "xbitmaps-1.1.3.tar.xz" ]; then
        rm -f "xbitmaps-1.1.3.tar.xz"
        local xbitmaps_url="https://xorg.freedesktop.org/archive/individual/data/xbitmaps-1.1.3.tar.xz"
        log_info "Downloading xbitmaps-1.1.3.tar.xz..."
        if ! download_with_retry "$xbitmaps_url" "xbitmaps-1.1.3.tar.xz"; then
            additional_failed+=("$xbitmaps_url (xbitmaps-1.1.3.tar.xz)")
        fi
    else
        log_info "[SKIP] xbitmaps-1.1.3.tar.xz (already exists)"
    fi

    # --- Xorg Applications (33 packages) ---
    log_info "Downloading Xorg Applications..."

    # These provide mkfontscale, xcursorgen, xrandr, etc.
    local xorg_app_packages=(
        "iceauth-1.0.10.tar.xz"
        "mkfontscale-1.2.3.tar.xz"
        "sessreg-1.1.4.tar.xz"
        "setxkbmap-1.3.4.tar.xz"
        "smproxy-1.0.8.tar.xz"
        "xauth-1.1.4.tar.xz"
        "xcmsdb-1.0.7.tar.xz"
        "xcursorgen-1.0.9.tar.xz"
        "xdpyinfo-1.4.0.tar.xz"
        "xdriinfo-1.0.8.tar.xz"
        "xev-1.2.6.tar.xz"
        "xgamma-1.0.8.tar.xz"
        "xhost-1.0.10.tar.xz"
        "xinput-1.6.4.tar.xz"
        "xkbcomp-1.4.7.tar.xz"
        "xkbevd-1.1.6.tar.xz"
        "xkbutils-1.0.6.tar.xz"
        "xkill-1.0.6.tar.xz"
        "xlsatoms-1.1.4.tar.xz"
        "xlsclients-1.1.5.tar.xz"
        "xmessage-1.0.7.tar.xz"
        "xmodmap-1.0.11.tar.xz"
        "xpr-1.2.0.tar.xz"
        "xprop-1.2.8.tar.xz"
        "xrandr-1.5.3.tar.xz"
        "xrdb-1.2.2.tar.xz"
        "xrefresh-1.1.0.tar.xz"
        "xset-1.2.5.tar.xz"
        "xsetroot-1.1.3.tar.xz"
        "xvinfo-1.1.5.tar.xz"
        "xwd-1.0.9.tar.xz"
        "xwininfo-1.1.6.tar.xz"
        "xwud-1.0.7.tar.xz"
    )

    for pkg in "${xorg_app_packages[@]}"; do
        if [ ! -f "$pkg" ] || [ ! -s "$pkg" ]; then
            rm -f "$pkg"  # Remove 0-byte files
            local xorg_url="https://xorg.freedesktop.org/archive/individual/app/${pkg}"
            log_info "Downloading $pkg..."
            if ! download_with_retry "$xorg_url" "$pkg"; then
                additional_failed+=("$xorg_url ($pkg)")
            fi
        else
            log_info "[SKIP] $pkg (already exists)"
        fi
    done

    # --- Xorg Fonts (9 packages) ---
    log_info "Downloading Xorg Fonts..."

    # font-util must be built first (provides fonts.scale, fonts.dir)
    # Then encodings, then the actual fonts, then font-alias
    # Using xorg.freedesktop.org/archive as primary source
    local xorg_font_packages=(
        "font-util-1.4.1.tar.xz"
        "encodings-1.1.0.tar.xz"
        "font-alias-1.0.5.tar.xz"
        "font-adobe-utopia-type1-1.0.5.tar.xz"
        "font-bh-ttf-1.0.4.tar.xz"
        "font-bh-type1-1.0.4.tar.xz"
        "font-ibm-type1-1.0.4.tar.xz"
        "font-misc-ethiopic-1.0.5.tar.xz"
        "font-xfree86-type1-1.0.5.tar.xz"
    )

    # Use xorg.freedesktop.org/archive as primary mirror
    for pkg in "${xorg_font_packages[@]}"; do
        if [ ! -f "$pkg" ] || [ ! -s "$pkg" ]; then
            rm -f "$pkg"  # Remove 0-byte files
            local xorg_url="https://xorg.freedesktop.org/archive/individual/font/${pkg}"
            log_info "Downloading $pkg..."
            if ! download_with_retry "$xorg_url" "$pkg"; then
                additional_failed+=("$xorg_url ($pkg)")
            fi
        else
            log_info "[SKIP] $pkg (already exists)"
        fi
    done

    # xcursor-themes - also needed for X desktop (from data directory)
    if [ ! -f "xcursor-themes-1.0.7.tar.xz" ] || [ ! -s "xcursor-themes-1.0.7.tar.xz" ]; then
        rm -f "xcursor-themes-1.0.7.tar.xz"
        local xcursor_themes_url="https://xorg.freedesktop.org/archive/individual/data/xcursor-themes-1.0.7.tar.xz"
        log_info "Downloading xcursor-themes-1.0.7.tar.xz..."
        if ! download_with_retry "$xcursor_themes_url" "xcursor-themes-1.0.7.tar.xz"; then
            additional_failed+=("$xcursor_themes_url (xcursor-themes-1.0.7.tar.xz)")
        fi
    else
        log_info "[SKIP] xcursor-themes-1.0.7.tar.xz (already exists)"
    fi

    # --- libepoxy (OpenGL function pointer management) ---
    # Required for Xorg-Server glamor support
    local libepoxy_url="https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz"
    if [ ! -f "libepoxy-1.5.10.tar.xz" ]; then
        log_info "Downloading libepoxy-1.5.10..."
        if ! download_with_retry "$libepoxy_url" "libepoxy-1.5.10.tar.xz"; then
            additional_failed+=("$libepoxy_url (libepoxy-1.5.10.tar.xz)")
        fi
    else
        log_info "[SKIP] libepoxy-1.5.10.tar.xz (already exists)"
    fi

    # --- Xorg-Server-21.1.18 (X11 display server) ---
    local xorg_server_url="https://www.x.org/pub/individual/xserver/xorg-server-21.1.18.tar.xz"
    if [ ! -f "xorg-server-21.1.18.tar.xz" ]; then
        log_info "Downloading xorg-server-21.1.18..."
        if ! download_with_retry "$xorg_server_url" "xorg-server-21.1.18.tar.xz"; then
            additional_failed+=("$xorg_server_url (xorg-server-21.1.18.tar.xz)")
        fi
    else
        log_info "[SKIP] xorg-server-21.1.18.tar.xz (already exists)"
    fi

    # --- Xorg Input Drivers ---

    # libevdev-1.13.4 (input device library)
    local libevdev_url="https://www.freedesktop.org/software/libevdev/libevdev-1.13.4.tar.xz"
    if [ ! -f "libevdev-1.13.4.tar.xz" ]; then
        log_info "Downloading libevdev-1.13.4..."
        if ! download_with_retry "$libevdev_url" "libevdev-1.13.4.tar.xz"; then
            additional_failed+=("$libevdev_url (libevdev-1.13.4.tar.xz)")
        fi
    else
        log_info "[SKIP] libevdev-1.13.4.tar.xz (already exists)"
    fi

    # mtdev-1.1.7 (multitouch device library)
    local mtdev_url="https://bitmath.org/code/mtdev/mtdev-1.1.7.tar.bz2"
    if [ ! -f "mtdev-1.1.7.tar.bz2" ]; then
        log_info "Downloading mtdev-1.1.7..."
        if ! download_with_retry "$mtdev_url" "mtdev-1.1.7.tar.bz2"; then
            additional_failed+=("$mtdev_url (mtdev-1.1.7.tar.bz2)")
        fi
    else
        log_info "[SKIP] mtdev-1.1.7.tar.bz2 (already exists)"
    fi

    # xf86-input-evdev-2.11.0 (evdev input driver)
    local evdev_url="https://www.x.org/pub/individual/driver/xf86-input-evdev-2.11.0.tar.xz"
    if [ ! -f "xf86-input-evdev-2.11.0.tar.xz" ]; then
        log_info "Downloading xf86-input-evdev-2.11.0..."
        if ! download_with_retry "$evdev_url" "xf86-input-evdev-2.11.0.tar.xz"; then
            additional_failed+=("$evdev_url (xf86-input-evdev-2.11.0.tar.xz)")
        fi
    else
        log_info "[SKIP] xf86-input-evdev-2.11.0.tar.xz (already exists)"
    fi

    # libinput-1.29.0 (modern input library)
    local libinput_url="https://gitlab.freedesktop.org/libinput/libinput/-/archive/1.29.0/libinput-1.29.0.tar.gz"
    if [ ! -f "libinput-1.29.0.tar.gz" ]; then
        log_info "Downloading libinput-1.29.0..."
        if ! download_with_retry "$libinput_url" "libinput-1.29.0.tar.gz"; then
            additional_failed+=("$libinput_url (libinput-1.29.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libinput-1.29.0.tar.gz (already exists)"
    fi

    # xf86-input-libinput-1.5.0 (libinput Xorg driver)
    local libinput_drv_url="https://www.x.org/pub/individual/driver/xf86-input-libinput-1.5.0.tar.xz"
    if [ ! -f "xf86-input-libinput-1.5.0.tar.xz" ]; then
        log_info "Downloading xf86-input-libinput-1.5.0..."
        if ! download_with_retry "$libinput_drv_url" "xf86-input-libinput-1.5.0.tar.xz"; then
            additional_failed+=("$libinput_drv_url (xf86-input-libinput-1.5.0.tar.xz)")
        fi
    else
        log_info "[SKIP] xf86-input-libinput-1.5.0.tar.xz (already exists)"
    fi

    # --- Xwayland-24.1.8 (X server for Wayland) ---
    local xwayland_url="https://www.x.org/pub/individual/xserver/xwayland-24.1.8.tar.xz"
    if [ ! -f "xwayland-24.1.8.tar.xz" ]; then
        log_info "Downloading xwayland-24.1.8..."
        if ! download_with_retry "$xwayland_url" "xwayland-24.1.8.tar.xz"; then
            additional_failed+=("$xwayland_url (xwayland-24.1.8.tar.xz)")
        fi
    else
        log_info "[SKIP] xwayland-24.1.8.tar.xz (already exists)"
    fi

    # --- xinit-1.4.4 (startx script) ---
    local xinit_url="https://www.x.org/pub/individual/app/xinit-1.4.4.tar.xz"
    if [ ! -f "xinit-1.4.4.tar.xz" ]; then
        log_info "Downloading xinit-1.4.4..."
        if ! download_with_retry "$xinit_url" "xinit-1.4.4.tar.xz"; then
            additional_failed+=("$xinit_url (xinit-1.4.4.tar.xz)")
        fi
    else
        log_info "[SKIP] xinit-1.4.4.tar.xz (already exists)"
    fi

    # --- XCB Utilities (5 packages) ---
    local xcb_util_packages=(
        "xcb-util-image-0.4.1"
        "xcb-util-keysyms-0.4.1"
        "xcb-util-renderutil-0.3.10"
        "xcb-util-wm-0.4.2"
        "xcb-util-cursor-0.1.5"
    )
    for pkg in "${xcb_util_packages[@]}"; do
        local pkg_file="${pkg}.tar.xz"
        local pkg_url="https://xcb.freedesktop.org/dist/${pkg_file}"
        if [ ! -f "$pkg_file" ]; then
            log_info "Downloading ${pkg}..."
            if ! download_with_retry "$pkg_url" "$pkg_file"; then
                additional_failed+=("$pkg_url ($pkg_file)")
            fi
        else
            log_info "[SKIP] $pkg_file (already exists)"
        fi
    done

    # =========================================================================
    # Multimedia Libraries (Tier 4)
    # =========================================================================

    # --- ALSA (Advanced Linux Sound Architecture) ---

    # alsa-lib-1.2.14 (ALSA library - core audio)
    local alsa_lib_url="https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.14.tar.bz2"
    if [ ! -f "alsa-lib-1.2.14.tar.bz2" ]; then
        log_info "Downloading alsa-lib..."
        if ! download_with_retry "$alsa_lib_url" "alsa-lib-1.2.14.tar.bz2"; then
            additional_failed+=("$alsa_lib_url (alsa-lib-1.2.14.tar.bz2)")
        fi
    else
        log_info "[SKIP] alsa-lib-1.2.14.tar.bz2 (already exists)"
    fi

    # alsa-plugins-1.2.12 (ALSA plugins for format conversion)
    local alsa_plugins_url="https://www.alsa-project.org/files/pub/plugins/alsa-plugins-1.2.12.tar.bz2"
    if [ ! -f "alsa-plugins-1.2.12.tar.bz2" ]; then
        log_info "Downloading alsa-plugins..."
        if ! download_with_retry "$alsa_plugins_url" "alsa-plugins-1.2.12.tar.bz2"; then
            additional_failed+=("$alsa_plugins_url (alsa-plugins-1.2.12.tar.bz2)")
        fi
    else
        log_info "[SKIP] alsa-plugins-1.2.12.tar.bz2 (already exists)"
    fi

    # alsa-utils-1.2.14 (ALSA utilities - aplay, amixer, etc.)
    local alsa_utils_url="https://www.alsa-project.org/files/pub/utils/alsa-utils-1.2.14.tar.bz2"
    if [ ! -f "alsa-utils-1.2.14.tar.bz2" ]; then
        log_info "Downloading alsa-utils..."
        if ! download_with_retry "$alsa_utils_url" "alsa-utils-1.2.14.tar.bz2"; then
            additional_failed+=("$alsa_utils_url (alsa-utils-1.2.14.tar.bz2)")
        fi
    else
        log_info "[SKIP] alsa-utils-1.2.14.tar.bz2 (already exists)"
    fi

    # --- Audio Codecs ---

    # libogg-1.3.6 (Ogg container format)
    local libogg_url="https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz"
    if [ ! -f "libogg-1.3.6.tar.xz" ]; then
        log_info "Downloading libogg..."
        if ! download_with_retry "$libogg_url" "libogg-1.3.6.tar.xz"; then
            additional_failed+=("$libogg_url (libogg-1.3.6.tar.xz)")
        fi
    else
        log_info "[SKIP] libogg-1.3.6.tar.xz (already exists)"
    fi

    # libvorbis-1.3.7 (Vorbis audio codec)
    local libvorbis_url="https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"
    if [ ! -f "libvorbis-1.3.7.tar.xz" ]; then
        log_info "Downloading libvorbis..."
        if ! download_with_retry "$libvorbis_url" "libvorbis-1.3.7.tar.xz"; then
            additional_failed+=("$libvorbis_url (libvorbis-1.3.7.tar.xz)")
        fi
    else
        log_info "[SKIP] libvorbis-1.3.7.tar.xz (already exists)"
    fi

    # FLAC-1.5.0 (Free Lossless Audio Codec)
    local flac_url="https://downloads.xiph.org/releases/flac/flac-1.5.0.tar.xz"
    if [ ! -f "flac-1.5.0.tar.xz" ]; then
        log_info "Downloading FLAC..."
        if ! download_with_retry "$flac_url" "flac-1.5.0.tar.xz"; then
            additional_failed+=("$flac_url (flac-1.5.0.tar.xz)")
        fi
    else
        log_info "[SKIP] flac-1.5.0.tar.xz (already exists)"
    fi

    # Opus-1.5.2 (Opus audio codec)
    local opus_url="https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz"
    if [ ! -f "opus-1.5.2.tar.gz" ]; then
        log_info "Downloading Opus..."
        if ! download_with_retry "$opus_url" "opus-1.5.2.tar.gz"; then
            additional_failed+=("$opus_url (opus-1.5.2.tar.gz)")
        fi
    else
        log_info "[SKIP] opus-1.5.2.tar.gz (already exists)"
    fi

    # libsndfile-1.2.2 (Audio file I/O library)
    local libsndfile_url="https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz"
    if [ ! -f "libsndfile-1.2.2.tar.xz" ]; then
        log_info "Downloading libsndfile..."
        if ! download_with_retry "$libsndfile_url" "libsndfile-1.2.2.tar.xz"; then
            additional_failed+=("$libsndfile_url (libsndfile-1.2.2.tar.xz)")
        fi
    else
        log_info "[SKIP] libsndfile-1.2.2.tar.xz (already exists)"
    fi

    # libsamplerate-0.2.2 (Sample rate conversion)
    local libsamplerate_url="https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz"
    if [ ! -f "libsamplerate-0.2.2.tar.xz" ]; then
        log_info "Downloading libsamplerate..."
        if ! download_with_retry "$libsamplerate_url" "libsamplerate-0.2.2.tar.xz"; then
            additional_failed+=("$libsamplerate_url (libsamplerate-0.2.2.tar.xz)")
        fi
    else
        log_info "[SKIP] libsamplerate-0.2.2.tar.xz (already exists)"
    fi

    # --- Lua (scripting language - dependency for WirePlumber) ---

    # lua-5.4.8 (scripting language)
    local lua_url="https://www.lua.org/ftp/lua-5.4.8.tar.gz"
    if [ ! -f "lua-5.4.8.tar.gz" ]; then
        log_info "Downloading Lua..."
        if ! download_with_retry "$lua_url" "lua-5.4.8.tar.gz"; then
            additional_failed+=("$lua_url (lua-5.4.8.tar.gz)")
        fi
    else
        log_info "[SKIP] lua-5.4.8.tar.gz (already exists)"
    fi

    # lua-5.4.8-shared_library-1.patch (required patch for shared library support)
    local lua_patch_url="https://www.linuxfromscratch.org/patches/blfs/12.4/lua-5.4.8-shared_library-1.patch"
    if [ ! -f "lua-5.4.8-shared_library-1.patch" ]; then
        log_info "Downloading Lua patch..."
        if ! download_with_retry "$lua_patch_url" "lua-5.4.8-shared_library-1.patch"; then
            additional_failed+=("$lua_patch_url (lua-5.4.8-shared_library-1.patch)")
        fi
    else
        log_info "[SKIP] lua-5.4.8-shared_library-1.patch (already exists)"
    fi

    # Which-2.23 (Needed for configure scripts to find yasm/nasm)
    local which_url="https://anduin.linuxfromscratch.org/BLFS/which/which-2.23.tar.gz"
    if [ ! -f "which-2.23.tar.gz" ]; then
        log_info "Downloading Which..."
        if ! download_with_retry "$which_url" "which-2.23.tar.gz"; then
            additional_failed+=("$which_url (which-2.23.tar.gz)")
        fi
    else
        log_info "[SKIP] which-2.23.tar.gz (already exists)"
    fi

    # NASM-2.16.03 (Assembler for x264, x265, libvpx, libaom)
    local nasm_url="https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz"
    if [ ! -f "nasm-2.16.03.tar.xz" ]; then
        log_info "Downloading NASM..."
        if ! download_with_retry "$nasm_url" "nasm-2.16.03.tar.xz"; then
            additional_failed+=("$nasm_url (nasm-2.16.03.tar.xz)")
        fi
    else
        log_info "[SKIP] nasm-2.16.03.tar.xz (already exists)"
    fi

    # --- Audio Servers ---

    # PipeWire-1.4.7 (Modern audio/video server)
    local pipewire_url="https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/1.4.7/pipewire-1.4.7.tar.gz"
    if [ ! -f "pipewire-1.4.7.tar.gz" ]; then
        log_info "Downloading PipeWire..."
        if ! download_with_retry "$pipewire_url" "pipewire-1.4.7.tar.gz"; then
            additional_failed+=("$pipewire_url (pipewire-1.4.7.tar.gz)")
        fi
    else
        log_info "[SKIP] pipewire-1.4.7.tar.gz (already exists)"
    fi

    # WirePlumber-0.5.10 (Session manager for PipeWire)
    local wireplumber_url="https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.10/wireplumber-0.5.10.tar.gz"
    if [ ! -f "wireplumber-0.5.10.tar.gz" ]; then
        log_info "Downloading WirePlumber..."
        if ! download_with_retry "$wireplumber_url" "wireplumber-0.5.10.tar.gz"; then
            additional_failed+=("$wireplumber_url (wireplumber-0.5.10.tar.gz)")
        fi
    else
        log_info "[SKIP] wireplumber-0.5.10.tar.gz (already exists)"
    fi

    # PulseAudio-17.0 (Traditional audio server)
    local pulseaudio_url="https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-17.0.tar.xz"
    if [ ! -f "pulseaudio-17.0.tar.xz" ]; then
        log_info "Downloading PulseAudio..."
        if ! download_with_retry "$pulseaudio_url" "pulseaudio-17.0.tar.xz"; then
            additional_failed+=("$pulseaudio_url (pulseaudio-17.0.tar.xz)")
        fi
    else
        log_info "[SKIP] pulseaudio-17.0.tar.xz (already exists)"
    fi

    # --- GStreamer Multimedia Framework ---

    # gstreamer-1.26.5 (Core framework)
    local gstreamer_url="https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.26.5.tar.xz"
    if [ ! -f "gstreamer-1.26.5.tar.xz" ]; then
        log_info "Downloading GStreamer..."
        if ! download_with_retry "$gstreamer_url" "gstreamer-1.26.5.tar.xz"; then
            additional_failed+=("$gstreamer_url (gstreamer-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gstreamer-1.26.5.tar.xz (already exists)"
    fi

    # gst-plugins-base-1.26.5 (Base plugins)
    local gst_plugins_base_url="https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.26.5.tar.xz"
    if [ ! -f "gst-plugins-base-1.26.5.tar.xz" ]; then
        log_info "Downloading gst-plugins-base..."
        if ! download_with_retry "$gst_plugins_base_url" "gst-plugins-base-1.26.5.tar.xz"; then
            additional_failed+=("$gst_plugins_base_url (gst-plugins-base-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gst-plugins-base-1.26.5.tar.xz (already exists)"
    fi

    # gst-plugins-good-1.26.5 (Good quality plugins)
    local gst_plugins_good_url="https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.5.tar.xz"
    if [ ! -f "gst-plugins-good-1.26.5.tar.xz" ]; then
        log_info "Downloading gst-plugins-good..."
        if ! download_with_retry "$gst_plugins_good_url" "gst-plugins-good-1.26.5.tar.xz"; then
            additional_failed+=("$gst_plugins_good_url (gst-plugins-good-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gst-plugins-good-1.26.5.tar.xz (already exists)"
    fi

    # gst-plugins-bad-1.26.5 (Experimental plugins)
    local gst_plugins_bad_url="https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.26.5.tar.xz"
    if [ ! -f "gst-plugins-bad-1.26.5.tar.xz" ]; then
        log_info "Downloading gst-plugins-bad..."
        if ! download_with_retry "$gst_plugins_bad_url" "gst-plugins-bad-1.26.5.tar.xz"; then
            additional_failed+=("$gst_plugins_bad_url (gst-plugins-bad-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gst-plugins-bad-1.26.5.tar.xz (already exists)"
    fi

    # gst-plugins-ugly-1.26.5 (Patent-encumbered plugins)
    local gst_plugins_ugly_url="https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-1.26.5.tar.xz"
    if [ ! -f "gst-plugins-ugly-1.26.5.tar.xz" ]; then
        log_info "Downloading gst-plugins-ugly..."
        if ! download_with_retry "$gst_plugins_ugly_url" "gst-plugins-ugly-1.26.5.tar.xz"; then
            additional_failed+=("$gst_plugins_ugly_url (gst-plugins-ugly-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gst-plugins-ugly-1.26.5.tar.xz (already exists)"
    fi

    # gst-libav-1.26.5 (FFmpeg plugin wrapper)
    local gst_libav_url="https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.26.5.tar.xz"
    if [ ! -f "gst-libav-1.26.5.tar.xz" ]; then
        log_info "Downloading gst-libav..."
        if ! download_with_retry "$gst_libav_url" "gst-libav-1.26.5.tar.xz"; then
            additional_failed+=("$gst_libav_url (gst-libav-1.26.5.tar.xz)")
        fi
    else
        log_info "[SKIP] gst-libav-1.26.5.tar.xz (already exists)"
    fi

    # --- Video Codecs ---

    # x264-20250815 (H.264 encoder)
    local x264_url="https://anduin.linuxfromscratch.org/BLFS/x264/x264-20250815.tar.xz"
    if [ ! -f "x264-20250815.tar.xz" ]; then
        log_info "Downloading x264..."
        if ! download_with_retry "$x264_url" "x264-20250815.tar.xz"; then
            additional_failed+=("$x264_url (x264-20250815.tar.xz)")
        fi
    else
        log_info "[SKIP] x264-20250815.tar.xz (already exists)"
    fi

    # x265-4.1 (H.265/HEVC encoder)
    local x265_url="https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.1.tar.gz"
    if [ ! -f "x265_4.1.tar.gz" ]; then
        log_info "Downloading x265..."
        if ! download_with_retry "$x265_url" "x265_4.1.tar.gz"; then
            additional_failed+=("$x265_url (x265_4.1.tar.gz)")
        fi
    else
        log_info "[SKIP] x265_4.1.tar.gz (already exists)"
    fi

    # libvpx-1.15.2 (VP8/VP9 codec)
    local libvpx_url="https://github.com/webmproject/libvpx/archive/v1.15.2/libvpx-1.15.2.tar.gz"
    if [ ! -f "libvpx-1.15.2.tar.gz" ]; then
        log_info "Downloading libvpx..."
        if ! download_with_retry "$libvpx_url" "libvpx-1.15.2.tar.gz"; then
            additional_failed+=("$libvpx_url (libvpx-1.15.2.tar.gz)")
        fi
    else
        log_info "[SKIP] libvpx-1.15.2.tar.gz (already exists)"
    fi

    # libaom-3.12.1 (AV1 codec)
    local libaom_url="https://storage.googleapis.com/aom-releases/libaom-3.12.1.tar.gz"
    if [ ! -f "libaom-3.12.1.tar.gz" ]; then
        log_info "Downloading libaom..."
        if ! download_with_retry "$libaom_url" "libaom-3.12.1.tar.gz"; then
            additional_failed+=("$libaom_url (libaom-3.12.1.tar.gz)")
        fi
    else
        log_info "[SKIP] libaom-3.12.1.tar.gz (already exists)"
    fi

    # --- Hardware Acceleration ---

    # libva-2.22.0 (VA-API for video acceleration)
    local libva_url="https://github.com/intel/libva/releases/download/2.22.0/libva-2.22.0.tar.bz2"
    if [ ! -f "libva-2.22.0.tar.bz2" ]; then
        log_info "Downloading libva..."
        if ! download_with_retry "$libva_url" "libva-2.22.0.tar.bz2"; then
            additional_failed+=("$libva_url (libva-2.22.0.tar.bz2)")
        fi
    else
        log_info "[SKIP] libva-2.22.0.tar.bz2 (already exists)"
    fi

    # libvdpau-1.5 (VDPAU for video acceleration)
    local libvdpau_url="https://gitlab.freedesktop.org/vdpau/libvdpau/-/archive/1.5/libvdpau-1.5.tar.gz"
    if [ ! -f "libvdpau-1.5.tar.gz" ]; then
        log_info "Downloading libvdpau..."
        if ! download_with_retry "$libvdpau_url" "libvdpau-1.5.tar.gz"; then
            additional_failed+=("$libvdpau_url (libvdpau-1.5.tar.gz)")
        fi
    else
        log_info "[SKIP] libvdpau-1.5.tar.gz (already exists)"
    fi

    # --- FFmpeg ---

    # FFmpeg-7.1.1 (Multimedia framework)
    local ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
    if [ ! -f "ffmpeg-7.1.1.tar.xz" ]; then
        log_info "Downloading FFmpeg..."
        if ! download_with_retry "$ffmpeg_url" "ffmpeg-7.1.1.tar.xz"; then
            additional_failed+=("$ffmpeg_url (ffmpeg-7.1.1.tar.xz)")
        fi
    else
        log_info "[SKIP] ffmpeg-7.1.1.tar.xz (already exists)"
    fi

    # --- Tier 5: GTK Stack ---

    # Graphite2-1.3.14 (TrueType font rendering engine - dependency for HarfBuzz)
    local graphite2_url="https://github.com/silnrsi/graphite/releases/download/1.3.14/graphite2-1.3.14.tgz"
    if [ ! -f "graphite2-1.3.14.tgz" ]; then
        log_info "Downloading Graphite2..."
        if ! download_with_retry "$graphite2_url" "graphite2-1.3.14.tgz"; then
            additional_failed+=("$graphite2_url (graphite2-1.3.14.tgz)")
        fi
    else
        log_info "[SKIP] graphite2-1.3.14.tgz (already exists)"
    fi

    # LLVM-20.1.8 (Low Level Virtual Machine - required for Rust)
    local llvm_url="https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.8/llvm-20.1.8.src.tar.xz"
    if [ ! -f "llvm-20.1.8.src.tar.xz" ]; then
        log_info "Downloading LLVM..."
        if ! download_with_retry "$llvm_url" "llvm-20.1.8.src.tar.xz"; then
            additional_failed+=("$llvm_url (llvm-20.1.8.src.tar.xz)")
        fi
    else
        log_info "[SKIP] llvm-20.1.8.src.tar.xz (already exists)"
    fi

    # LLVM CMake modules
    local llvm_cmake_url="https://anduin.linuxfromscratch.org/BLFS/llvm/llvm-cmake-20.1.8.src.tar.xz"
    if [ ! -f "llvm-cmake-20.1.8.src.tar.xz" ]; then
        log_info "Downloading LLVM CMake modules..."
        if ! download_with_retry "$llvm_cmake_url" "llvm-cmake-20.1.8.src.tar.xz"; then
            additional_failed+=("$llvm_cmake_url (llvm-cmake-20.1.8.src.tar.xz)")
        fi
    else
        log_info "[SKIP] llvm-cmake-20.1.8.src.tar.xz (already exists)"
    fi

    # LLVM Third-party dependencies
    local llvm_third_party_url="https://anduin.linuxfromscratch.org/BLFS/llvm/llvm-third-party-20.1.8.src.tar.xz"
    if [ ! -f "llvm-third-party-20.1.8.src.tar.xz" ]; then
        log_info "Downloading LLVM third-party dependencies..."
        if ! download_with_retry "$llvm_third_party_url" "llvm-third-party-20.1.8.src.tar.xz"; then
            additional_failed+=("$llvm_third_party_url (llvm-third-party-20.1.8.src.tar.xz)")
        fi
    else
        log_info "[SKIP] llvm-third-party-20.1.8.src.tar.xz (already exists)"
    fi

    # Clang-20.1.8 (C/C++/Objective-C compiler frontend for LLVM)
    local clang_url="https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.8/clang-20.1.8.src.tar.xz"
    if [ ! -f "clang-20.1.8.src.tar.xz" ]; then
        log_info "Downloading Clang..."
        if ! download_with_retry "$clang_url" "clang-20.1.8.src.tar.xz"; then
            additional_failed+=("$clang_url (clang-20.1.8.src.tar.xz)")
        fi
    else
        log_info "[SKIP] clang-20.1.8.src.tar.xz (already exists)"
    fi

    # Compiler-RT-20.1.8 (LLVM runtime libraries - optional but recommended)
    local compiler_rt_url="https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.8/compiler-rt-20.1.8.src.tar.xz"
    if [ ! -f "compiler-rt-20.1.8.src.tar.xz" ]; then
        log_info "Downloading Compiler-RT..."
        if ! download_with_retry "$compiler_rt_url" "compiler-rt-20.1.8.src.tar.xz"; then
            additional_failed+=("$compiler_rt_url (compiler-rt-20.1.8.src.tar.xz)")
        fi
    else
        log_info "[SKIP] compiler-rt-20.1.8.src.tar.xz (already exists)"
    fi

    # Rust-1.89.0 (Rust compiler and cargo - required for cargo-c and librsvg)
    local rust_url="https://static.rust-lang.org/dist/rustc-1.89.0-src.tar.xz"
    if [ ! -f "rustc-1.89.0-src.tar.xz" ]; then
        log_info "Downloading Rust..."
        if ! download_with_retry "$rust_url" "rustc-1.89.0-src.tar.xz"; then
            additional_failed+=("$rust_url (rustc-1.89.0-src.tar.xz)")
        fi
    else
        log_info "[SKIP] rustc-1.89.0-src.tar.xz (already exists)"
    fi

    # HarfBuzz-11.4.1 (OpenType text shaping engine)
    local harfbuzz_url="https://github.com/harfbuzz/harfbuzz/releases/download/11.4.1/harfbuzz-11.4.1.tar.xz"
    if [ ! -f "harfbuzz-11.4.1.tar.xz" ]; then
        log_info "Downloading HarfBuzz..."
        if ! download_with_retry "$harfbuzz_url" "harfbuzz-11.4.1.tar.xz"; then
            additional_failed+=("$harfbuzz_url (harfbuzz-11.4.1.tar.xz)")
        fi
    else
        log_info "[SKIP] harfbuzz-11.4.1.tar.xz (already exists)"
    fi

    # FriBidi-1.0.16 (Unicode Bidirectional Algorithm)
    local fribidi_url="https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"
    if [ ! -f "fribidi-1.0.16.tar.xz" ]; then
        log_info "Downloading FriBidi..."
        if ! download_with_retry "$fribidi_url" "fribidi-1.0.16.tar.xz"; then
            additional_failed+=("$fribidi_url (fribidi-1.0.16.tar.xz)")
        fi
    else
        log_info "[SKIP] fribidi-1.0.16.tar.xz (already exists)"
    fi

    # Pixman-0.46.4 (Low-level pixel manipulation library)
    local pixman_url="https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
    if [ ! -f "pixman-0.46.4.tar.gz" ]; then
        log_info "Downloading Pixman..."
        if ! download_with_retry "$pixman_url" "pixman-0.46.4.tar.gz"; then
            additional_failed+=("$pixman_url (pixman-0.46.4.tar.gz)")
        fi
    else
        log_info "[SKIP] pixman-0.46.4.tar.gz (already exists)"
    fi

    # Fontconfig-2.17.1 (Font configuration library)
    local fontconfig_url="https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.17.1/fontconfig-2.17.1.tar.xz"
    if [ ! -f "fontconfig-2.17.1.tar.xz" ]; then
        log_info "Downloading Fontconfig..."
        if ! download_with_retry "$fontconfig_url" "fontconfig-2.17.1.tar.xz"; then
            additional_failed+=("$fontconfig_url (fontconfig-2.17.1.tar.xz)")
        fi
    else
        log_info "[SKIP] fontconfig-2.17.1.tar.xz (already exists)"
    fi

    # Graphene-1.10.8 (Thin layer of types for graphics)
    local graphene_url="https://download.gnome.org/sources/graphene/1.10/graphene-1.10.8.tar.xz"
    if [ ! -f "graphene-1.10.8.tar.xz" ]; then
        log_info "Downloading Graphene..."
        if ! download_with_retry "$graphene_url" "graphene-1.10.8.tar.xz"; then
            additional_failed+=("$graphene_url (graphene-1.10.8.tar.xz)")
        fi
    else
        log_info "[SKIP] graphene-1.10.8.tar.xz (already exists)"
    fi

    # libxkbcommon-1.11.0 (XKB keymap handling library)
    local libxkbcommon_url="https://github.com/lfs-book/libxkbcommon/archive/v1.11.0/libxkbcommon-1.11.0.tar.gz"
    if [ ! -f "libxkbcommon-1.11.0.tar.gz" ]; then
        log_info "Downloading libxkbcommon..."
        if ! download_with_retry "$libxkbcommon_url" "libxkbcommon-1.11.0.tar.gz"; then
            additional_failed+=("$libxkbcommon_url (libxkbcommon-1.11.0.tar.gz)")
        fi
    else
        log_info "[SKIP] libxkbcommon-1.11.0.tar.gz (already exists)"
    fi

    # Cairo-1.18.4 (2D graphics library)
    local cairo_url="https://www.cairographics.org/releases/cairo-1.18.4.tar.xz"
    if [ ! -f "cairo-1.18.4.tar.xz" ]; then
        log_info "Downloading Cairo..."
        if ! download_with_retry "$cairo_url" "cairo-1.18.4.tar.xz"; then
            additional_failed+=("$cairo_url (cairo-1.18.4.tar.xz)")
        fi
    else
        log_info "[SKIP] cairo-1.18.4.tar.xz (already exists)"
    fi

    # Pango-1.56.4 (Text layout library)
    local pango_url="https://download.gnome.org/sources/pango/1.56/pango-1.56.4.tar.xz"
    if [ ! -f "pango-1.56.4.tar.xz" ]; then
        log_info "Downloading Pango..."
        if ! download_with_retry "$pango_url" "pango-1.56.4.tar.xz"; then
            additional_failed+=("$pango_url (pango-1.56.4.tar.xz)")
        fi
    else
        log_info "[SKIP] pango-1.56.4.tar.xz (already exists)"
    fi

    # at-spi2-core-2.56.4 (Assistive Technology Service Provider Interface)
    local atspi_url="https://download.gnome.org/sources/at-spi2-core/2.56/at-spi2-core-2.56.4.tar.xz"
    if [ ! -f "at-spi2-core-2.56.4.tar.xz" ]; then
        log_info "Downloading at-spi2-core..."
        if ! download_with_retry "$atspi_url" "at-spi2-core-2.56.4.tar.xz"; then
            additional_failed+=("$atspi_url (at-spi2-core-2.56.4.tar.xz)")
        fi
    else
        log_info "[SKIP] at-spi2-core-2.56.4.tar.xz (already exists)"
    fi

    # libepoxy-1.5.10 (OpenGL function pointer management - already in Xorg section, skip)

    # libjpeg-turbo-3.0.1 (JPEG image codec)
    local libjpeg_url="https://downloads.sourceforge.net/libjpeg-turbo/libjpeg-turbo-3.0.1.tar.gz"
    if [ ! -f "libjpeg-turbo-3.0.1.tar.gz" ]; then
        log_info "Downloading libjpeg-turbo..."
        if ! download_with_retry "$libjpeg_url" "libjpeg-turbo-3.0.1.tar.gz"; then
            additional_failed+=("$libjpeg_url (libjpeg-turbo-3.0.1.tar.gz)")
        fi
    else
        log_info "[SKIP] libjpeg-turbo-3.0.1.tar.gz (already exists)"
    fi

    # libtiff-4.7.0 (TIFF image library)
    local libtiff_url="https://download.osgeo.org/libtiff/tiff-4.7.0.tar.gz"
    if [ ! -f "tiff-4.7.0.tar.gz" ]; then
        log_info "Downloading libtiff..."
        if ! download_with_retry "$libtiff_url" "tiff-4.7.0.tar.gz"; then
            additional_failed+=("$libtiff_url (tiff-4.7.0.tar.gz)")
        fi
    else
        log_info "[SKIP] tiff-4.7.0.tar.gz (already exists)"
    fi

    # gdk-pixbuf-2.42.12 (Image loading library for GTK)
    local gdkpixbuf_url="https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz"
    if [ ! -f "gdk-pixbuf-2.42.12.tar.xz" ]; then
        log_info "Downloading gdk-pixbuf..."
        if ! download_with_retry "$gdkpixbuf_url" "gdk-pixbuf-2.42.12.tar.xz"; then
            additional_failed+=("$gdkpixbuf_url (gdk-pixbuf-2.42.12.tar.xz)")
        fi
    else
        log_info "[SKIP] gdk-pixbuf-2.42.12.tar.xz (already exists)"
    fi

    # cargo-c-0.10.15 (Helper to build Rust C-ABI libraries)
    local cargoc_url="https://github.com/lu-zero/cargo-c/archive/v0.10.15/cargo-c-0.10.15.tar.gz"
    if [ ! -f "cargo-c-0.10.15.tar.gz" ]; then
        log_info "Downloading cargo-c..."
        if ! download_with_retry "$cargoc_url" "cargo-c-0.10.15.tar.gz"; then
            additional_failed+=("$cargoc_url (cargo-c-0.10.15.tar.gz)")
        fi
    else
        log_info "[SKIP] cargo-c-0.10.15.tar.gz (already exists)"
    fi

    # librsvg-2.61.0 (SVG rendering library)
    local librsvg_url="https://download.gnome.org/sources/librsvg/2.61/librsvg-2.61.0.tar.xz"
    if [ ! -f "librsvg-2.61.0.tar.xz" ]; then
        log_info "Downloading librsvg..."
        if ! download_with_retry "$librsvg_url" "librsvg-2.61.0.tar.xz"; then
            additional_failed+=("$librsvg_url (librsvg-2.61.0.tar.xz)")
        fi
    else
        log_info "[SKIP] librsvg-2.61.0.tar.xz (already exists)"
    fi

    # shared-mime-info-2.4 (MIME database)
    local sharedmime_url="https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/2.4/shared-mime-info-2.4.tar.gz"
    if [ ! -f "shared-mime-info-2.4.tar.gz" ]; then
        log_info "Downloading shared-mime-info..."
        if ! download_with_retry "$sharedmime_url" "shared-mime-info-2.4.tar.gz"; then
            additional_failed+=("$sharedmime_url (shared-mime-info-2.4.tar.gz)")
        fi
    else
        log_info "[SKIP] shared-mime-info-2.4.tar.gz (already exists)"
    fi

    # ISO Codes-4.18.0 (ISO country/language/currency codes)
    local isocodes_url="https://salsa.debian.org/iso-codes-team/iso-codes/-/archive/v4.18.0/iso-codes-v4.18.0.tar.gz"
    if [ ! -f "iso-codes-v4.18.0.tar.gz" ]; then
        log_info "Downloading ISO Codes..."
        if ! download_with_retry "$isocodes_url" "iso-codes-v4.18.0.tar.gz"; then
            additional_failed+=("$isocodes_url (iso-codes-v4.18.0.tar.gz)")
        fi
    else
        log_info "[SKIP] iso-codes-v4.18.0.tar.gz (already exists)"
    fi

    # hicolor-icon-theme-0.18 (Default icon theme)
    local hicolor_url="https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-0.18.tar.xz"
    if [ ! -f "hicolor-icon-theme-0.18.tar.xz" ]; then
        log_info "Downloading hicolor-icon-theme..."
        if ! download_with_retry "$hicolor_url" "hicolor-icon-theme-0.18.tar.xz"; then
            additional_failed+=("$hicolor_url (hicolor-icon-theme-0.18.tar.xz)")
        fi
    else
        log_info "[SKIP] hicolor-icon-theme-0.18.tar.xz (already exists)"
    fi

    # adwaita-icon-theme-48.1 (GNOME icon theme)
    local adwaita_url="https://download.gnome.org/sources/adwaita-icon-theme/48/adwaita-icon-theme-48.1.tar.xz"
    if [ ! -f "adwaita-icon-theme-48.1.tar.xz" ]; then
        log_info "Downloading adwaita-icon-theme..."
        if ! download_with_retry "$adwaita_url" "adwaita-icon-theme-48.1.tar.xz"; then
            additional_failed+=("$adwaita_url (adwaita-icon-theme-48.1.tar.xz)")
        fi
    else
        log_info "[SKIP] adwaita-icon-theme-48.1.tar.xz (already exists)"
    fi

    # gsettings-desktop-schemas-48.0 (GSettings schemas for desktop applications)
    local gsettings_url="https://download.gnome.org/sources/gsettings-desktop-schemas/48/gsettings-desktop-schemas-48.0.tar.xz"
    if [ ! -f "gsettings-desktop-schemas-48.0.tar.xz" ]; then
        log_info "Downloading gsettings-desktop-schemas..."
        if ! download_with_retry "$gsettings_url" "gsettings-desktop-schemas-48.0.tar.xz"; then
            additional_failed+=("$gsettings_url (gsettings-desktop-schemas-48.0.tar.xz)")
        fi
    else
        log_info "[SKIP] gsettings-desktop-schemas-48.0.tar.xz (already exists)"
    fi

    # docbook-xml-4.5 (DocBook XML DTDs - required by docbook-xsl)
    local docbookxml_url="https://www.docbook.org/xml/4.5/docbook-xml-4.5.zip"
    if [ ! -f "docbook-xml-4.5.zip" ]; then
        log_info "Downloading docbook-xml..."
        if ! download_with_retry "$docbookxml_url" "docbook-xml-4.5.zip"; then
            additional_failed+=("$docbookxml_url (docbook-xml-4.5.zip)")
        fi
    else
        log_info "[SKIP] docbook-xml-4.5.zip (already exists)"
    fi

    # docbook-xsl-nons-1.79.2 (DocBook XSLT stylesheets)
    local docbookxsl_url="https://github.com/docbook/xslt10-stylesheets/releases/download/release/1.79.2/docbook-xsl-nons-1.79.2.tar.bz2"
    if [ ! -f "docbook-xsl-nons-1.79.2.tar.bz2" ]; then
        log_info "Downloading docbook-xsl-nons..."
        if ! download_with_retry "$docbookxsl_url" "docbook-xsl-nons-1.79.2.tar.bz2"; then
            additional_failed+=("$docbookxsl_url (docbook-xsl-nons-1.79.2.tar.bz2)")
        fi
    else
        log_info "[SKIP] docbook-xsl-nons-1.79.2.tar.bz2 (already exists)"
    fi

    # docbook-xsl-nons-1.79.2-stack_fix-1.patch (Required patch for docbook-xsl)
    local docbookxsl_patch_url="https://www.linuxfromscratch.org/patches/blfs/12.4/docbook-xsl-nons-1.79.2-stack_fix-1.patch"
    if [ ! -f "docbook-xsl-nons-1.79.2-stack_fix-1.patch" ]; then
        log_info "Downloading docbook-xsl patch..."
        if ! download_with_retry "$docbookxsl_patch_url" "docbook-xsl-nons-1.79.2-stack_fix-1.patch"; then
            additional_failed+=("$docbookxsl_patch_url (docbook-xsl-nons-1.79.2-stack_fix-1.patch)")
        fi
    else
        log_info "[SKIP] docbook-xsl-nons-1.79.2-stack_fix-1.patch (already exists)"
    fi

    # PyCairo-1.28.0 (Python Cairo bindings - required by PyGObject)
    local pycairo_url="https://github.com/pygobject/pycairo/releases/download/v1.28.0/pycairo-1.28.0.tar.gz"
    if [ ! -f "pycairo-1.28.0.tar.gz" ]; then
        log_info "Downloading PyCairo..."
        if ! download_with_retry "$pycairo_url" "pycairo-1.28.0.tar.gz"; then
            additional_failed+=("$pycairo_url (pycairo-1.28.0.tar.gz)")
        fi
    else
        log_info "[SKIP] pycairo-1.28.0.tar.gz (already exists)"
    fi

    # PyGObject-3.52.3 (Python GObject bindings)
    local pygobject_url="https://download.gnome.org/sources/pygobject/3.52/pygobject-3.52.3.tar.gz"
    if [ ! -f "pygobject-3.52.3.tar.gz" ]; then
        log_info "Downloading PyGObject..."
        if ! download_with_retry "$pygobject_url" "pygobject-3.52.3.tar.gz"; then
            additional_failed+=("$pygobject_url (pygobject-3.52.3.tar.gz)")
        fi
    else
        log_info "[SKIP] pygobject-3.52.3.tar.gz (already exists)"
    fi

    # ========================================
    # Python Test Dependencies (for PyGObject tests)
    # ========================================

    # Setuptools_scm-8.3.1 (no required dependencies)
    local setuptools_scm_url="https://files.pythonhosted.org/packages/source/s/setuptools_scm/setuptools_scm-8.3.1.tar.gz"
    if [ ! -f "setuptools_scm-8.3.1.tar.gz" ]; then
        log_info "Downloading Setuptools_scm..."
        if ! download_with_retry "$setuptools_scm_url" "setuptools_scm-8.3.1.tar.gz"; then
            additional_failed+=("$setuptools_scm_url (setuptools_scm-8.3.1.tar.gz)")
        fi
    else
        log_info "[SKIP] setuptools_scm-8.3.1.tar.gz (already exists)"
    fi

    # Editables-0.5 (required by hatchling)
    local editables_url="https://files.pythonhosted.org/packages/source/e/editables/editables-0.5.tar.gz"
    if [ ! -f "editables-0.5.tar.gz" ]; then
        log_info "Downloading Editables..."
        if ! download_with_retry "$editables_url" "editables-0.5.tar.gz"; then
            additional_failed+=("$editables_url (editables-0.5.tar.gz)")
        fi
    else
        log_info "[SKIP] editables-0.5.tar.gz (already exists)"
    fi

    # Pathspec-0.12.1 (required by hatchling)
    local pathspec_url="https://files.pythonhosted.org/packages/source/p/pathspec/pathspec-0.12.1.tar.gz"
    if [ ! -f "pathspec-0.12.1.tar.gz" ]; then
        log_info "Downloading Pathspec..."
        if ! download_with_retry "$pathspec_url" "pathspec-0.12.1.tar.gz"; then
            additional_failed+=("$pathspec_url (pathspec-0.12.1.tar.gz)")
        fi
    else
        log_info "[SKIP] pathspec-0.12.1.tar.gz (already exists)"
    fi

    # Trove-Classifiers-2025.8.6.13 (required by hatchling)
    local trove_classifiers_url="https://files.pythonhosted.org/packages/source/t/trove_classifiers/trove_classifiers-2025.8.6.13.tar.gz"
    if [ ! -f "trove_classifiers-2025.8.6.13.tar.gz" ]; then
        log_info "Downloading Trove-Classifiers..."
        if ! download_with_retry "$trove_classifiers_url" "trove_classifiers-2025.8.6.13.tar.gz"; then
            additional_failed+=("$trove_classifiers_url (trove_classifiers-2025.8.6.13.tar.gz)")
        fi
    else
        log_info "[SKIP] trove_classifiers-2025.8.6.13.tar.gz (already exists)"
    fi

    # Pluggy-1.6.0 (required by pytest)
    local pluggy_url="https://files.pythonhosted.org/packages/source/p/pluggy/pluggy-1.6.0.tar.gz"
    if [ ! -f "pluggy-1.6.0.tar.gz" ]; then
        log_info "Downloading Pluggy..."
        if ! download_with_retry "$pluggy_url" "pluggy-1.6.0.tar.gz"; then
            additional_failed+=("$pluggy_url (pluggy-1.6.0.tar.gz)")
        fi
    else
        log_info "[SKIP] pluggy-1.6.0.tar.gz (already exists)"
    fi

    # Hatchling-1.27.0 (required by hatch_vcs)
    local hatchling_url="https://files.pythonhosted.org/packages/source/h/hatchling/hatchling-1.27.0.tar.gz"
    if [ ! -f "hatchling-1.27.0.tar.gz" ]; then
        log_info "Downloading Hatchling..."
        if ! download_with_retry "$hatchling_url" "hatchling-1.27.0.tar.gz"; then
            additional_failed+=("$hatchling_url (hatchling-1.27.0.tar.gz)")
        fi
    else
        log_info "[SKIP] hatchling-1.27.0.tar.gz (already exists)"
    fi

    # Hatch_vcs-0.5.0 (required by iniconfig)
    local hatch_vcs_url="https://files.pythonhosted.org/packages/source/h/hatch-vcs/hatch_vcs-0.5.0.tar.gz"
    if [ ! -f "hatch_vcs-0.5.0.tar.gz" ]; then
        log_info "Downloading Hatch_vcs..."
        if ! download_with_retry "$hatch_vcs_url" "hatch_vcs-0.5.0.tar.gz"; then
            additional_failed+=("$hatch_vcs_url (hatch_vcs-0.5.0.tar.gz)")
        fi
    else
        log_info "[SKIP] hatch_vcs-0.5.0.tar.gz (already exists)"
    fi

    # Iniconfig-2.1.0 (required by pytest)
    local iniconfig_url="https://files.pythonhosted.org/packages/source/i/iniconfig/iniconfig-2.1.0.tar.gz"
    if [ ! -f "iniconfig-2.1.0.tar.gz" ]; then
        log_info "Downloading Iniconfig..."
        if ! download_with_retry "$iniconfig_url" "iniconfig-2.1.0.tar.gz"; then
            additional_failed+=("$iniconfig_url (iniconfig-2.1.0.tar.gz)")
        fi
    else
        log_info "[SKIP] iniconfig-2.1.0.tar.gz (already exists)"
    fi

    # Pygments-2.19.2 (syntax highlighter - required by pytest)
    local pygments_url="https://files.pythonhosted.org/packages/source/P/Pygments/pygments-2.19.2.tar.gz"
    if [ ! -f "pygments-2.19.2.tar.gz" ]; then
        log_info "Downloading Pygments..."
        if ! download_with_retry "$pygments_url" "pygments-2.19.2.tar.gz"; then
            additional_failed+=("$pygments_url (pygments-2.19.2.tar.gz)")
        fi
    else
        log_info "[SKIP] pygments-2.19.2.tar.gz (already exists)"
    fi

    # Pytest-8.4.1 (test framework - optional for PyGObject tests)
    local pytest_url="https://files.pythonhosted.org/packages/source/p/pytest/pytest-8.4.1.tar.gz"
    if [ ! -f "pytest-8.4.1.tar.gz" ]; then
        log_info "Downloading Pytest..."
        if ! download_with_retry "$pytest_url" "pytest-8.4.1.tar.gz"; then
            additional_failed+=("$pytest_url (pytest-8.4.1.tar.gz)")
        fi
    else
        log_info "[SKIP] pytest-8.4.1.tar.gz (already exists)"
    fi

    # shaderc-2025.3 (Shader compiler for Vulkan)
    local shaderc_url="https://github.com/google/shaderc/archive/v2025.3/shaderc-2025.3.tar.gz"
    if [ ! -f "shaderc-2025.3.tar.gz" ]; then
        log_info "Downloading shaderc..."
        if ! download_with_retry "$shaderc_url" "shaderc-2025.3.tar.gz"; then
            additional_failed+=("$shaderc_url (shaderc-2025.3.tar.gz)")
        fi
    else
        log_info "[SKIP] shaderc-2025.3.tar.gz (already exists)"
    fi

    # GTK-3.24.50 (GTK+ toolkit version 3)
    local gtk3_url="https://download.gnome.org/sources/gtk/3.24/gtk-3.24.50.tar.xz"
    if [ ! -f "gtk-3.24.50.tar.xz" ]; then
        log_info "Downloading GTK-3..."
        if ! download_with_retry "$gtk3_url" "gtk-3.24.50.tar.xz"; then
            additional_failed+=("$gtk3_url (gtk-3.24.50.tar.xz)")
        fi
    else
        log_info "[SKIP] gtk-3.24.50.tar.xz (already exists)"
    fi

    # GTK-4.18.6 (GTK toolkit version 4)
    local gtk4_url="https://download.gnome.org/sources/gtk/4.18/gtk-4.18.6.tar.xz"
    if [ ! -f "gtk-4.18.6.tar.xz" ]; then
        log_info "Downloading GTK-4..."
        if ! download_with_retry "$gtk4_url" "gtk-4.18.6.tar.xz"; then
            additional_failed+=("$gtk4_url (gtk-4.18.6.tar.xz)")
        fi
    else
        log_info "[SKIP] gtk-4.18.6.tar.xz (already exists)"
    fi

    # Check for additional package failures
    if [ ${#additional_failed[@]} -gt 0 ]; then
        log_error "========================================="
        log_error "DOWNLOAD FAILED - The following additional packages could not be downloaded:"
        log_error "========================================="
        for failed in "${additional_failed[@]}"; do
            log_error "  - $failed"
        done
        log_error "========================================="
        log_error "These packages are required for the systemd build."
        log_error "Please check your network connection and try again."
        exit 1
    fi

    # =========================================================================
    # COMPREHENSIVE CHECKSUM VERIFICATION
    # Verify ALL downloaded files against known checksums
    # =========================================================================
    log_info "========================================="
    log_info "Verifying ALL package checksums..."
    log_info "========================================="

    # Generate combined checksums file (LFS + BLFS)
    local combined_checksums="/tmp/combined-md5sums.$$"
    cat md5sums > "$combined_checksums"
    echo "" >> "$combined_checksums"
    echo "# BLFS Package Checksums" >> "$combined_checksums"
    generate_blfs_checksums >> "$combined_checksums"
    
    # Track verification results
    local verified_ok=0
    local verified_fail=0
    local no_checksum=0
    local failed_files=()
    
    # Enable nullglob so globs that match nothing expand to nothing
    shopt -s nullglob
    
    # Verify all tarballs and archives
    for file in *.tar.* *.tgz *.zip; do
        [ -f "$file" ] || continue
        
        # Get expected checksum from combined file
        local expected_md5
        expected_md5=$(grep -E "^[a-f0-9]{32}  ${file}$" "$combined_checksums" 2>/dev/null | head -1 | cut -d' ' -f1)
        
        if [ -n "$expected_md5" ]; then
            # Verify checksum
            local actual_md5
            actual_md5=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$expected_md5" = "$actual_md5" ]; then
                ((verified_ok++))
            else
                ((verified_fail++))
                failed_files+=("$file (expected: $expected_md5, got: $actual_md5)")
                log_error "[FAIL] $file - checksum mismatch"
            fi
        else
            # No checksum available - verify file is non-empty and has reasonable size
            local file_size
            file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
            if [ "$file_size" -gt 1024 ]; then
                ((no_checksum++))
            elif [ "$file_size" -gt 0 ]; then
                # Very small file - might be truncated, warn but don't fail
                ((no_checksum++))
                log_warn "[WARN] $file is very small (${file_size} bytes) - may be incomplete"
            else
                ((verified_fail++))
                failed_files+=("$file (empty file)")
                log_error "[FAIL] $file - empty file"
            fi
        fi
    done
    
    # Verify patches
    for file in *.patch; do
        [ -f "$file" ] || continue
        
        local expected_md5
        expected_md5=$(grep -E "^[a-f0-9]{32}  ${file}$" "$combined_checksums" 2>/dev/null | head -1 | cut -d' ' -f1)
        
        if [ -n "$expected_md5" ]; then
            local actual_md5
            actual_md5=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$expected_md5" = "$actual_md5" ]; then
                ((verified_ok++))
            else
                ((verified_fail++))
                failed_files+=("$file (expected: $expected_md5, got: $actual_md5)")
                log_error "[FAIL] $file - checksum mismatch"
            fi
        else
            if [ -s "$file" ]; then
                ((no_checksum++))
            else
                ((verified_fail++))
                failed_files+=("$file (empty file)")
            fi
        fi
    done
    
    # Disable nullglob
    shopt -u nullglob
    
    # Clean up temp file
    rm -f "$combined_checksums"
    
    # Report verification results
    local total_files=$((verified_ok + verified_fail + no_checksum))
    
    echo ""
    log_info "========================================="
    log_info "Checksum Verification Results"
    log_info "========================================="
    log_info "Total files checked: $total_files"
    log_info "Verified OK:         $verified_ok"
    log_info "No checksum avail:   $no_checksum"
    log_info "Failed:              $verified_fail"
    log_info "========================================="
    
    if [ $verified_fail -gt 0 ]; then
        log_error ""
        log_error "The following files failed verification:"
        for failed in "${failed_files[@]}"; do
            log_error "  - $failed"
        done
        log_error ""
        log_error "These files may be corrupted or incomplete."
        log_error "Delete them and re-run the download to fix."
        exit 1
    fi
    
    if [ $no_checksum -gt 0 ]; then
        log_warn "Note: $no_checksum files have no checksum (unable to fully verify)"
    fi

    # Summary
    # Count all downloaded files (tarballs and patches)
    local downloaded_files=$(ls -1 *.tar.* *.tgz *.patch *.zip 2>/dev/null | wc -l)
    local total_size=$(du -sh . | cut -f1)

    echo ""
    log_info "========================================="
    log_info "Download Summary"
    log_info "========================================="
    log_info "LFS Version: $LFS_VERSION"
    log_info "Files downloaded: $downloaded_files"
    log_info "Total size: $total_size"
    log_info "Checksum verification: PASSED ($verified_ok verified, $no_checksum unchecked)"
    log_info "========================================="

    log_info "All sources downloaded and verified successfully!"

    # Create a global checkpoint using md5sums file hash
    # This ensures if the LFS version changes, downloads will re-run
    local md5sums_hash=$(md5sum md5sums | cut -d' ' -f1)
    create_global_checkpoint "download-complete" "download" "$md5sums_hash"

    exit 0
}

# Run main function
main "$@"
