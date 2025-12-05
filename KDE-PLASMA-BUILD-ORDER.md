# KDE Plasma 6.4.4 Complete Build Order for Rookery OS

This document provides the complete dependency chain and build order for KDE Plasma 6.4.4 on top of LFS 12.4 (systemd). Dependencies are organized from lowest level to highest, ensuring each package is built only after its requirements are satisfied.

## Build Tiers Overview

| Tier | Category | Package Count |
|------|----------|---------------|
| 0 | LFS Base System | (already built) |
| 1 | Post-LFS Security & Utilities | ~15 |
| 2 | Networking & Protocols | ~10 |
| 3 | Graphics Foundation (X11/Wayland) | ~25 |
| 4 | Multimedia Libraries | ~20 |
| 5 | Qt6 Framework | 1 (large) |
| 6 | KDE Frameworks Pre-requisites | ~15 |
| 7 | KDE Frameworks 6.17.0 | 56 packages |
| 8 | Plasma Pre-requisites | ~15 |
| 9 | KDE Plasma 6.4.4 | 56 packages |

---

## TIER 1: Post-LFS Security & Core Utilities

These packages extend the base LFS system with essential functionality.

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 1.1 | Linux-PAM | 1.7.1 | Shadow, polkit, many others |
| 1.2 | libpwquality | 1.4.5 | Plasma (password quality) |
| 1.3 | Shadow (rebuild) | 4.18.0 | PAM support |
| 1.4 | sudo | 1.9.17p2 | User privilege escalation |
| 1.5 | Which | 2.23 | Many build scripts |
| 1.6 | libgpg-error | 1.55 | libgcrypt |
| 1.7 | libgcrypt | 1.11.2 | KDE Frameworks |
| 1.8 | make-ca | 1.16 | SSL certificates |
| 1.9 | libtasn1 | 4.20.0 | p11-kit |
| 1.10 | p11-kit | 0.25.5 | Certificate handling |
| 1.11 | nspr | 4.36 | nss |
| 1.12 | nss | 3.112 | Certificate/crypto |
| 1.13 | polkit | 126 | System authorization |
| 1.14 | accountsservice | 23.13.9 | User account management |
| 1.15 | smartmontools | 7.5 | Disk health monitoring |

---

## TIER 2: Networking & Protocols

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 2.1 | libnl | 3.11.0 | Plasma, NetworkManager |
| 2.2 | libpcap | 1.10.5 | Network capture |
| 2.3 | Wget | 1.25.0 | KDE Frameworks build |
| 2.4 | cURL | 8.14.1 | Many packages |
| 2.5 | Avahi | 0.8 | KDE Frameworks (KDNSSD) |
| 2.6 | NetworkManager | 1.54.0 | KDE Frameworks |
| 2.7 | ModemManager | 1.24.2 | KDE Frameworks |
| 2.8 | dbus (rebuild if needed) | 1.16.2 | IPC foundation |
| 2.9 | libsoup3 | 3.6.5 | GLib networking |

---

## TIER 3: Graphics Foundation

### 3A: Base Graphics Libraries

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 3.1 | hwdata | 0.398 | libdisplay-info |
| 3.2 | libdisplay-info | 0.3.0 | Plasma |
| 3.3 | Pixman | 0.46.4 | cairo, X server |
| 3.4 | libpng | 1.6.48 | Many graphics libs |
| 3.5 | libjpeg-turbo | 3.1.0 | Image handling |
| 3.6 | giflib | 5.2.2 | Image handling |
| 3.7 | libwebp | 1.5.0 | Image handling |
| 3.8 | libtiff | 4.7.0 | Image handling |
| 3.9 | FreeType | 2.13.3 | Font rendering |
| 3.10 | HarfBuzz | 11.2.1 | Text shaping |
| 3.11 | Fontconfig | 2.16.2 | Font configuration |

### 3B: X11 Foundation

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 3.12 | Xorg Protocol Headers | (multiple) | X libraries |
| 3.13 | libXau | 1.0.12 | X authentication |
| 3.14 | libXdmcp | 1.1.5 | X display manager |
| 3.15 | xcb-proto | 1.17.0 | libxcb |
| 3.16 | libxcb | 1.17.0 | X C bindings |
| 3.17 | Xorg Libraries | (multiple) | X11 support |
| 3.18 | libxkbcommon | 1.11.0 | Keyboard handling |
| 3.19 | xkeyboard-config | 2.45 | Keyboard layouts |
| 3.20 | libxcvt | 0.1.3 | X server |
| 3.21 | libdrm | 2.4.125 | Mesa |

### 3C: Mesa & GL

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 3.22 | Mako | 1.3.10 | Mesa |
| 3.23 | PyYAML | 6.0.2 | Mesa, KDE Frameworks |
| 3.24 | glslang | (latest) | Mesa (recommended) |
| 3.25 | Vulkan-Headers | 1.4.321 | Vulkan support |
| 3.26 | Vulkan-Loader | 1.4.321 | Vulkan support |
| 3.27 | Mesa | 25.1.8 | OpenGL/Vulkan |
| 3.28 | GLU | 9.0.3 | OpenGL utilities |
| 3.29 | libepoxy | 1.5.10 | GTK3 |

### 3D: X Server

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 3.30 | Xorg Fonts | (util + base) | X server |
| 3.31 | Xorg Server | 21.1.16 | X11 display |
| 3.32 | Xorg Evdev Driver | 2.11.0 | Plasma |
| 3.33 | libinput | 1.29.0 | Input handling |
| 3.34 | Xorg Wacom Driver | 1.2.3 | Tablet support |
| 3.35 | xinit | 1.4.4 | X startup |

### 3E: Wayland

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 3.36 | Wayland | 1.24.0 | Wayland display |
| 3.37 | wayland-protocols | 1.45 | Wayland extensions |
| 3.38 | plasma-wayland-protocols | 1.18.0 | KDE Frameworks |
| 3.39 | Xwayland | 24.1.8 | X apps on Wayland |
| 3.40 | xdg-desktop-portal | 1.20.3 | Flatpak/sandboxing |

---

## TIER 4: Multimedia & Supporting Libraries

### 4A: Audio Foundation

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 4.1 | ALSA-lib | 1.2.14 | Audio foundation |
| 4.2 | ALSA-plugins | 1.2.14 | Audio plugins |
| 4.3 | ALSA-utils | 1.2.14 | Audio utilities |
| 4.4 | libsndfile | 1.2.2 | Audio file I/O |
| 4.5 | PulseAudio | 17.0 | Audio server |
| 4.6 | libcanberra | 0.30 | KDE Frameworks, event sounds |
| 4.7 | SBC | 2.1 | Bluetooth audio |

### 4B: Video/Codec Libraries

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 4.8 | libvorbis | 1.3.7 | Ogg audio |
| 4.9 | libtheora | 1.1.1 | Theora video |
| 4.10 | LAME | 3.100 | MP3 encoding |
| 4.11 | libvpx | 1.15.1 | VP8/VP9 video |
| 4.12 | opus | 1.5.2 | Opus audio |
| 4.13 | x264 | (snapshot) | H.264 encoding |
| 4.14 | x265 | 4.1 | H.265 encoding |
| 4.15 | libass | 0.17.3 | Subtitle rendering |
| 4.16 | libva | 2.23.0 | VA-API |
| 4.17 | libvdpau | 1.5 | VDPAU |
| 4.18 | FFmpeg | 7.1.1 | Plasma |

### 4C: GStreamer (Recommended for Phonon)

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 4.19 | GStreamer | 1.26.2 | Multimedia framework |
| 4.20 | gst-plugins-base | 1.26.2 | Base plugins |
| 4.21 | gst-plugins-good | 1.26.2 | Good plugins |

### 4D: PipeWire

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 4.22 | Wireplumber | 0.5.9 | PipeWire session manager |
| 4.23 | PipeWire | 1.4.7 | Plasma (audio/video routing) |

### 4E: Additional Media

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 4.24 | TagLib | 2.1.1 | Plasma (media metadata) |
| 4.25 | libcdio | 2.2.0 | CD support |

---

## TIER 5: GTK Stack (for GTK3 dependency)

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 5.1 | GLib | 2.84.2 | GTK foundation |
| 5.2 | ATK | 2.38.0 | Accessibility |
| 5.3 | at-spi2-core | 2.56.4 | GTK3 |
| 5.4 | gdk-pixbuf | 2.42.12 | GTK3 |
| 5.5 | Pango | 1.56.4 | GTK3 |
| 5.6 | cairo | 1.18.4 | 2D graphics |
| 5.7 | GTK3 | 3.24.50 | Plasma |
| 5.8 | gsettings-desktop-schemas | 48.0 | Plasma (recommended) |

---

## TIER 6: Qt6 and Pre-KDE Dependencies

### 6A: Qt6 Foundation

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 6.1 | double-conversion | 3.3.1 | Qt6 |
| 6.2 | PCRE2 | 10.45 | Qt6 |
| 6.3 | ICU | 77.1 | Qt6 internationalization |
| 6.4 | Qt | 6.9.2 | KDE Frameworks |

### 6B: KDE Prerequisites

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 6.5 | extra-cmake-modules | 6.17.0 | KDE Frameworks |
| 6.6 | Boost | 1.89.0 | Plasma |
| 6.7 | libarchive | 3.8.1 | OpenCV |
| 6.8 | OpenCV | 4.12.0 | Plasma |
| 6.9 | qca | 2.3.10 | KDE Frameworks |
| 6.10 | qcoro | 0.12.0 | Plasma |
| 6.11 | polkit-qt | 0.200.0 | KDE Frameworks |
| 6.12 | Phonon | 4.12.0 | KDE Frameworks |
| 6.13 | phonon-backend-vlc | 0.12.0 | OR phonon-backend-gstreamer |
| 6.14 | pulseaudio-qt | 1.7.0 | Plasma |
| 6.15 | libsass | 3.6.6 | sassc |
| 6.16 | sassc | 3.6.2 | Plasma |
| 6.17 | xdotool | 3.20211022.1 | Plasma |

### 6C: Documentation & Data

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 6.18 | docbook-xml | 4.5 | KDE Frameworks |
| 6.19 | docbook-xsl-nons | 1.79.2 | KDE Frameworks |
| 6.20 | libxslt | 1.1.43 | KDE Frameworks |
| 6.21 | shared-mime-info | 2.4 | KDE Frameworks |
| 6.22 | libical | 3.0.20 | KDE Frameworks |
| 6.23 | lmdb | 0.9.33 | KDE Frameworks |
| 6.24 | libqrencode | 4.1.1 | KDE Frameworks |
| 6.25 | URI (Perl) | 5.32 | KDE Frameworks |

### 6D: Sensors & Hardware

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 6.26 | lm-sensors | 3.6.2 | Plasma (hardware monitoring) |
| 6.27 | pciutils | 3.14.0 | Plasma |
| 6.28 | libwacom | 2.16.1 | Plasma (tablet) |
| 6.29 | power-profiles-daemon | 0.30 | Plasma |
| 6.30 | libqalculate | 5.7.0 | Plasma (calculator) |

---

## TIER 7: KDE Frameworks 6.17.0

Build in this exact order (56 packages):

| # | Package | Notes |
|---|---------|-------|
| 7.1 | attica | OAuth |
| 7.2 | kapidox | Python documentation |
| 7.3 | karchive | Archive handling |
| 7.4 | kcodecs | Character encoding |
| 7.5 | kconfig | Configuration |
| 7.6 | kcoreaddons | Core utilities |
| 7.7 | kdbusaddons | D-Bus utilities |
| 7.8 | kdnssd | DNS-SD |
| 7.9 | kguiaddons | GUI utilities |
| 7.10 | ki18n | Internationalization |
| 7.11 | kidletime | Idle detection |
| 7.12 | kimageformats | Image formats |
| 7.13 | kitemmodels | Item models |
| 7.14 | kitemviews | Item views |
| 7.15 | kplotting | Plotting |
| 7.16 | kwidgetsaddons | Widget utilities |
| 7.17 | kwindowsystem | Window system |
| 7.18 | networkmanager-qt | NetworkManager bindings |
| 7.19 | solid | Hardware abstraction |
| 7.20 | sonnet | Spell checking |
| 7.21 | threadweaver | Threading |
| 7.22 | kauth | Authorization |
| 7.23 | kcompletion | Completion |
| 7.24 | kcrash | Crash handling |
| 7.25 | kdoctools | Documentation |
| 7.26 | kpty | PTY handling |
| 7.27 | kunitconversion | Unit conversion |
| 7.28 | kcolorscheme | Color schemes |
| 7.29 | kconfigwidgets | Config widgets |
| 7.30 | kservice | Services |
| 7.31 | kglobalaccel | Global accelerators |
| 7.32 | kpackage | Package handling |
| 7.33 | kdesu | Privilege escalation |
| 7.34 | kiconthemes | Icon themes |
| 7.35 | knotifications | Notifications |
| 7.36 | kjobwidgets | Job widgets |
| 7.37 | ktextwidgets | Text widgets |
| 7.38 | kxmlgui | XML GUI |
| 7.39 | kbookmarks | Bookmarks |
| 7.40 | kwallet | Wallet |
| 7.41 | kded | KDE daemon |
| 7.42 | kio | I/O framework |
| 7.43 | kdeclarative | QML integration |
| 7.44 | kcmutils | KCM utilities |
| 7.45 | kirigami | Mobile UI framework |
| 7.46 | syndication | RSS/Atom |
| 7.47 | knewstuff | Content download |
| 7.48 | frameworkintegration | Framework integration |
| 7.49 | kparts | Part framework |
| 7.50 | syntax-highlighting | Syntax highlighting |
| 7.51 | ktexteditor | Text editor |
| 7.52 | modemmanager-qt | ModemManager bindings |
| 7.53 | kcontacts | Contacts |
| 7.54 | kpeople | People |
| 7.55 | bluez-qt | Bluetooth (optional) |
| 7.56 | kfilemetadata | File metadata |
| 7.57 | baloo | File indexing |
| 7.58 | krunner | Runner framework |
| 7.59 | prison | Barcode |
| 7.60 | qqc2-desktop-style | QQC2 style |
| 7.61 | kholidays | Holidays |
| 7.62 | purpose | Sharing |
| 7.63 | kcalendarcore | Calendar |
| 7.64 | kquickcharts | Charts |
| 7.65 | knotifyconfig | Notification config |
| 7.66 | kdav | DAV |
| 7.67 | kstatusnotifieritem | Status notifier |
| 7.68 | ksvg | SVG |
| 7.69 | ktexttemplate | Text templates |
| 7.70 | kuserfeedback | User feedback |

---

## TIER 8: Plasma Prerequisites

| # | Package | Version | Required By |
|---|---------|---------|-------------|
| 8.1 | breeze-icons | 6.17.0 | KDE Frameworks, Plasma |
| 8.2 | oxygen-icons | 6.0.0 | Plasma (recommended) |
| 8.3 | kirigami-addons | 1.9.0 | Plasma |
| 8.4 | kio-extras | 25.08.0 | Plasma (runtime) |
| 8.5 | aspell | 0.60.8.1 | Spell checking |
| 8.6 | zxing-cpp | 2.3.0 | KDE Frameworks (spectacle) |

---

## TIER 9: KDE Plasma 6.4.4

Build in this exact order (56 packages):

| # | Package | Notes |
|---|---------|-------|
| 9.1 | kdecoration | Window decorations |
| 9.2 | libkscreen | Screen management |
| 9.3 | libksysguard | System monitoring |
| 9.4 | breeze | Breeze theme |
| 9.5 | breeze-gtk | GTK Breeze theme |
| 9.6 | layer-shell-qt | Wayland layer shell |
| 9.7 | plasma-activities | Activities |
| 9.8 | libplasma | Plasma library |
| 9.9 | kscreenlocker | Screen locker |
| 9.10 | kinfocenter | System info |
| 9.11 | kglobalacceld | Global accelerators daemon |
| 9.12 | kwayland | Wayland integration |
| 9.13 | aurorae | Window decoration engine |
| 9.14 | kwin-x11 | X11 compositor config |
| 9.15 | kwin | Window manager |
| 9.16 | plasma5support | Plasma 5 compatibility |
| 9.17 | plasma-activities-stats | Activity statistics |
| 9.18 | kpipewire | PipeWire integration |
| 9.19 | plasma-workspace | Workspace |
| 9.20 | plasma-disks | Disk management |
| 9.21 | bluedevil | Bluetooth |
| 9.22 | kde-gtk-config | GTK configuration |
| 9.23 | kmenuedit | Menu editor |
| 9.24 | kscreen | Screen configuration |
| 9.25 | kwallet-pam | Wallet PAM |
| 9.26 | kwrited | Write daemon |
| 9.27 | milou | Search |
| 9.28 | plasma-nm | Network management |
| 9.29 | plasma-pa | PulseAudio control |
| 9.30 | plasma-workspace-wallpapers | Wallpapers |
| 9.31 | polkit-kde-agent-1 | PolicyKit agent |
| 9.32 | powerdevil | Power management |
| 9.33 | plasma-desktop | Desktop shell |
| 9.34 | kgamma | Gamma correction |
| 9.35 | ksshaskpass | SSH askpass |
| 9.36 | sddm-kcm | SDDM configuration |
| 9.37 | kactivitymanagerd | Activity manager |
| 9.38 | plasma-integration | Desktop integration |
| 9.39 | xdg-desktop-portal-kde | XDG portal |
| 9.40 | drkonqi | Crash reporter |
| 9.41 | plasma-vault | Encrypted vaults |
| 9.42 | kde-cli-tools | CLI tools |
| 9.43 | systemsettings | System settings |
| 9.44 | plasma-thunderbolt | Thunderbolt |
| 9.45 | plasma-firewall | Firewall |
| 9.46 | plasma-systemmonitor | System monitor |
| 9.47 | qqc2-breeze-style | QQC2 Breeze style |
| 9.48 | ksystemstats | System statistics |
| 9.49 | oxygen-sounds | Sound theme |
| 9.50 | kdeplasma-addons | Plasma addons |
| 9.51 | plasma-welcome | Welcome app |
| 9.52 | ocean-sound-theme | Ocean sounds |
| 9.53 | print-manager | Printing |
| 9.54 | wacomtablet | Wacom support |
| 9.55 | oxygen | Oxygen theme |
| 9.56 | spectacle | Screenshot |

---

## Display Manager: SDDM

After Plasma, install SDDM for graphical login:

| # | Package | Version | Notes |
|---|---------|---------|-------|
| 10.1 | SDDM | 0.21.0 | Display manager |

---

## Summary Statistics

- **Total unique packages**: ~250+
- **Estimated build time**: 40-60 SBU (Standard Build Units)
- **Estimated disk space**: 15-20 GB during build
- **Final install size**: ~3-4 GB

---

## Notes

1. **Version numbers** are from BLFS 12.4 and may need updating
2. **Optional dependencies** are not listed but can enhance functionality
3. **Build parallelism** (`-j$(nproc)`) significantly reduces build time
4. **Qt6** is the largest single build (~2 hours on modern hardware)
5. **KDE Frameworks** and **Plasma** use batch build scripts from BLFS

---

## References

- [BLFS 12.4 Book](https://www.linuxfromscratch.org/blfs/view/12.4-systemd/)
- [KDE Plasma Installation](https://www.linuxfromscratch.org/blfs/view/12.4-systemd/kde/plasma-all.html)
- [KDE Frameworks Installation](https://www.linuxfromscratch.org/blfs/view/12.4-systemd/kde/frameworks6.html)
