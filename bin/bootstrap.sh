#!/bin/sh
set -e

ROOTFS="${1:-$HOME/Documents/zerene-new}"
OLD="${2:-$HOME/Documents/zerene_older}"
ZETA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST_ZETA="lua $ZETA_DIR/zeta.lua"

echo "=== Zerene OS Rootfs Bootstrap ==="
echo "Target: $ROOTFS"
echo "Source: $OLD"

if [ ! -d "$OLD" ]; then
    echo "FATAL: source rootfs $OLD does not exist"
    exit 1
fi

# Phase A: Create minimal base (NOT tracked by zeta)
echo ""
echo "[1/5] Creating minimal base..."
mkdir -p "$ROOTFS"/{boot,dev,proc,sys,run,tmp,root}
mkdir -p "$ROOTFS"/{bin,sbin,usr/bin,usr/sbin,usr/lib,usr/share,lib64}
mkdir -p "$ROOTFS"/{etc/init.d,etc/conf.d,etc/zerene,etc/ssl}
mkdir -p "$ROOTFS"/{home,mnt,opt,srv,var}

echo "  Copying kernel and boot files..."
cp "$OLD"/boot/vmlinuz-6.16.1-gen "$ROOTFS/boot/"
cp "$OLD"/boot/initramfs-installed.img "$ROOTFS/boot/initramfs.img"
cp "$OLD"/boot/config-6.16.1-gen "$ROOTFS/boot/"
cp "$OLD"/boot/image.png "$ROOTFS/boot/"

echo "  Copying system configuration..."
# Only copy identity files, NOT the full etc/ (packages will ship their own)
cp "$OLD"/etc/passwd "$ROOTFS/etc/passwd" 2>/dev/null || true
cp "$OLD"/etc/shadow "$ROOTFS/etc/shadow" 2>/dev/null || true
cp "$OLD"/etc/group "$ROOTFS/etc/group" 2>/dev/null || true
cp "$OLD"/etc/gshadow "$ROOTFS/etc/gshadow" 2>/dev/null || true
cp "$OLD"/etc/hostname "$ROOTFS/etc/hostname" 2>/dev/null || true
cp "$OLD"/etc/hosts "$ROOTFS/etc/hosts" 2>/dev/null || true
cp "$OLD"/etc/fstab "$ROOTFS/etc/fstab" 2>/dev/null || true
cp "$OLD"/etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
cp "$OLD"/etc/os-release "$ROOTFS/etc/os-release" 2>/dev/null || true
cp -a "$OLD"/etc/zerene/ "$ROOTFS/etc/zerene/" 2>/dev/null || true
cp "$OLD"/etc/ssl/ "$ROOTFS/etc/ssl/" 2>/dev/null || true

# Remove generated/cache files that packages will regenerate
echo "  Cleaning generated files..."
rm -f "$ROOTFS"/etc/ld.so.cache
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
# Remove binaries from zerene_older that will be replaced by tracked packages
rm -rf "$ROOTFS"/bin/*
rm -rf "$ROOTFS"/sbin/*
rm -rf "$ROOTFS"/usr/bin/*
rm -rf "$ROOTFS"/usr/sbin/*
rm -rf "$ROOTFS"/usr/lib/*
rm -rf "$ROOTFS"/lib64/*
rm -rf "$ROOTFS"/lib/*

# Phase B: Initialize zeta state
echo ""
echo "[2/5] Initializing package database..."
mkdir -p "$ROOTFS"/var/db/zeta/packages
mkdir -p "$ROOTFS"/var/db/zeta/dependencies
mkdir -p "$ROOTFS"/var/cache/zeta
mkdir -p "$ROOTFS"/var/tmp/zeta

# Phase C: Install packages
echo ""
echo "[3/5] Installing packages..."

install_pkg() {
    local pkg="$1"
    echo "  -> $pkg"
    if ! ZETA_ROOT="$ROOTFS" $HOST_ZETA -Provide "$pkg" --pass; then
        echo "  FATAL: $pkg failed to install"
        exit 1
    fi
}

# Core system
install_pkg glibc

# Set up dynamic linker after glibc is installed
echo "  Setting up dynamic linker config..."
mkdir -p "$ROOTFS/etc/ld.so.conf.d"
cat > "$ROOTFS/etc/ld.so.conf" << 'EOF'
/usr/lib
/lib
/usr/lib64
/lib64
/usr/local/lib
EOF
echo "  NOTE: Run 'sudo ldconfig' inside the rootfs on first boot to generate ld.so.cache"

install_pkg ncurses
install_pkg busybox

# Utilities
install_pkg coreutils
install_pkg bash
install_pkg shadow
install_pkg util-linux
install_pkg kmod
install_pkg kbd
install_pkg e2fsprogs
install_pkg dosfstools
install_pkg btrfs-progs
install_pkg findutils

# Libraries
install_pkg zlib
install_pkg gzip
install_pkg zip
install_pkg zstd
install_pkg lzo
install_pkg squashfs-tools

# Interpreter + package manager
install_pkg lua
install_pkg zeta

# Init system + IPC
install_pkg openrc
install_pkg dbus
install_pkg elogind

# Bootloader
install_pkg limine

# Networking
install_pkg iproute2
install_pkg iputils
install_pkg networkmanager
install_pkg curl

# Remote access + editor
install_pkg openssh
install_pkg micro

# Firmware
install_pkg linux-firmware

# Debugging
install_pkg procps-ng
install_pkg strace
install_pkg usbutils
install_pkg pciutils

# Sandboxing
install_pkg bubblewrap

# Note: ld.so.cache will be generated on first boot with 'sudo ldconfig'

# Fix busybox symlinks (busybox installs to /usr/bin, symlinks need /usr/sbin)
echo "  Fixing busybox symlinks in /usr/sbin..."
for applet in addgroup adduser chpasswd delgroup deluser getty halt \
    ip link route hostname ifconfig loadfont login losetup mount \
    poweroff reboot switch_root swapon swapoff umount; do
    ln -sf "../bin/busybox" "$ROOTFS/usr/sbin/$applet" 2>/dev/null || true
done

# Phase D: Verify tracking
echo ""
echo "[4/5] Verifying tracking..."
UNTRACKED=0
for dir in usr/bin usr/sbin usr/lib lib64; do
    [ -d "$ROOTFS/$dir" ] || continue
    find "$ROOTFS/$dir" -type f 2>/dev/null | while read f; do
        rel="${f#$ROOTFS/}"
        if ! grep -rq "^${rel}$" "$ROOTFS"/var/db/zeta/*/files 2>/dev/null; then
            echo "  UNTRACKED: $rel"
        fi
    done
done

# Phase E: Build ISO
echo ""
echo "[5/5] Building ISO..."
~/zerene-iso-regen

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "First boot steps:"
echo "  1. Boot the ISO or chroot into the rootfs"
echo "  2. Run: sudo ldconfig"
echo "  3. All shared libraries will then be indexed"
