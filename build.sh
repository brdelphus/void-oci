#!/bin/bash
# build.sh — reproducible Void Linux OCI QCOW2 image builder
# Usage: sudo ./build.sh [x86_64|aarch64]
# Requires: qemu-img qemu-nbd sgdisk partx mkfs.vfat mkfs.ext4 blkid curl tar
#           meson ninja gcc (for OpenRC compile inside chroot)
#           For aarch64: qemu-aarch64-static (qemu-user-static package)
set -euo pipefail

# ─── Global build lock (prevent concurrent runs) ──────────────────────────────
LOCKFILE="/tmp/void-oci-build-${1:-x86_64}.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo "ERROR: Another build is already running (lock: $LOCKFILE). PID $(cat "$LOCKFILE/pid" 2>/dev/null)"
    exit 1
fi
echo $$ > "$LOCKFILE/pid"
# ─── Configuration ────────────────────────────────────────────────────────────
ARCH="${1:-x86_64}"
VOID_DATE="20250202"
IMAGE_SIZE="8G"
OPENRC_SRC="$VOID_OCI_DIR/openrc"
VOID_OCI_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$VOID_OCI_DIR/void-oci-${ARCH}.qcow2"
CLOUDINIT_TAG="26.1"
ROOTFS="$(mktemp -d /tmp/void-oci-rootfs.XXXXXX)"

# ─── Validation ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "ERROR: ARCH must be x86_64 or aarch64"; exit 1 ;;
esac

for cmd in qemu-img qemu-nbd parted partx mkfs.vfat mkfs.ext4 blkid curl tar meson ninja; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

if [ "$ARCH" = "aarch64" ]; then
    QEMU_STATIC="$(command -v qemu-aarch64-static 2>/dev/null || true)"
    [ -n "$QEMU_STATIC" ] || { echo "ERROR: qemu-aarch64-static not found (install qemu-user-static)"; exit 1; }
fi

[ -d "$OPENRC_SRC" ] || { echo "ERROR: OPENRC_SRC=$OPENRC_SRC not found"; exit 1; }

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
NBD=""
cleanup() {
    echo "--- cleanup ---"
    umount "$ROOTFS/boot/efi"    2>/dev/null || true
    umount "$ROOTFS/openrc-src"  2>/dev/null || true
    umount "$ROOTFS/proc"        2>/dev/null || true
    umount "$ROOTFS/sys"         2>/dev/null || true
    umount "$ROOTFS/dev/pts"     2>/dev/null || true
    umount "$ROOTFS/dev"         2>/dev/null || true
    umount "$ROOTFS"             2>/dev/null || true
    [ -n "$NBD" ] && qemu-nbd --disconnect "$NBD" 2>/dev/null || true
    rmdir "$ROOTFS" 2>/dev/null || true
    rm -rf "$LOCKFILE" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Find a free nbd device ───────────────────────────────────────────────────
modprobe nbd max_part=8
for i in $(seq 0 15); do
    if ! [ -e "/sys/block/nbd${i}/pid" ]; then
        NBD="/dev/nbd${i}"
        break
    fi
done
[ -n "$NBD" ] || { echo "ERROR: no free nbd device"; exit 1; }

echo "==> Building void-oci-${ARCH}.qcow2 -> $OUTPUT"
echo "==> NBD device: $NBD, rootfs: $ROOTFS"

# ─── Step 1: Create and partition image ───────────────────────────────────────
echo "==> Creating QCOW2 image ($IMAGE_SIZE)"
qemu-img create -f qcow2 "$OUTPUT" "$IMAGE_SIZE"
qemu-nbd --connect="$NBD" "$OUTPUT"
sleep 1  # give kernel time to register partitions

echo "==> Partitioning (GPT: 256M EFI + rest ext4)"
parted -s "$NBD" mklabel gpt
parted -s "$NBD" mkpart EFI  fat32 1MiB   257MiB
parted -s "$NBD" set 1 esp on
parted -s "$NBD" mkpart Linux ext4 257MiB 100%
partx -u "$NBD"
sleep 0.5

echo "==> Formatting"
mkfs.vfat -F32 -n EFI  "${NBD}p1"
mkfs.ext4 -L void-oci -q "${NBD}p2"

EFI_UUID="$(blkid -s UUID -o value "${NBD}p1")"
ROOT_UUID="$(blkid -s UUID -o value "${NBD}p2")"
echo "==> EFI UUID=$EFI_UUID  ROOT UUID=$ROOT_UUID"

echo "==> Mounting"
mount "${NBD}p2" "$ROOTFS"
mkdir -p "$ROOTFS/boot/efi"
mount "${NBD}p1" "$ROOTFS/boot/efi"

# ─── Step 2: Bootstrap rootfs ─────────────────────────────────────────────────
TARBALL="void-${ARCH}-ROOTFS-${VOID_DATE}.tar.xz"
if [ ! -f "$VOID_OCI_DIR/$TARBALL" ]; then
    echo "==> Downloading $TARBALL"
    curl -L "https://repo-default.voidlinux.org/live/current/$TARBALL" \
         -o "$VOID_OCI_DIR/$TARBALL"
else
    echo "==> Using cached $TARBALL"
fi

echo "==> Extracting rootfs"
tar -xJpf "$VOID_OCI_DIR/$TARBALL" -C "$ROOTFS"

# ─── Step 3: QEMU static binary for arm64 ─────────────────────────────────────
if [ "$ARCH" = "aarch64" ]; then
    echo "==> Installing qemu-aarch64-static for arm64 chroot"
    cp "$QEMU_STATIC" "$ROOTFS/usr/bin/"
    # Ensure binfmt_misc is mounted, then register qemu-aarch64
    mount | grep -q binfmt_misc || mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' \
            > /proc/sys/fs/binfmt_misc/register
    fi
fi

# ─── Step 4: chroot helper ────────────────────────────────────────────────────
mount --bind /proc   "$ROOTFS/proc"
mount --bind /sys    "$ROOTFS/sys"
mount --bind /dev    "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"

xchroot() {
    chroot "$ROOTFS" /bin/sh -c "$*"
}

# ─── Step 5: xbps repo + update ───────────────────────────────────────────────
echo "==> Configuring xbps repo"
cp /etc/resolv.conf "$ROOTFS/etc/"
mkdir -p "$ROOTFS/etc/xbps.d"

if [ "$ARCH" = "aarch64" ]; then
    echo "repository=https://repo-default.voidlinux.org/current/aarch64" \
        > "$ROOTFS/etc/xbps.d/00-repo.conf"
else
    echo "repository=https://repo-default.voidlinux.org/current" \
        > "$ROOTFS/etc/xbps.d/00-repo.conf"
fi

echo "==> Updating xbps"
xchroot "xbps-install -Syu xbps"
xchroot "xbps-install -Syu"

# ─── Step 6: Package installation ─────────────────────────────────────────────
COMMON_PKGS="base-minimal dracut openssh dhcpcd iproute2 grub python3 python3-pip python3-setuptools libcap-devel meson ninja pkg-config gcc make git curl wget"

if [ "$ARCH" = "x86_64" ]; then
    ARCH_PKGS="linux6.12 linux6.18 linux-firmware-amd linux-firmware-intel grub-x86_64-efi"
else
    ARCH_PKGS="linux6.12 grub-arm64-efi"
fi

echo "==> Installing packages"
# xbps exits non-zero if some packages are already installed; that's fine
# shellcheck disable=SC2086
xchroot "xbps-install -y $COMMON_PKGS $ARCH_PKGS" || true

# ─── Step 7: Build OpenRC from source ─────────────────────────────────────────
echo "==> Building OpenRC from source"
mkdir -p "$ROOTFS/openrc-src"
mount --bind "$OPENRC_SRC" "$ROOTFS/openrc-src"

xchroot "
    cd /openrc-src
    rm -rf /tmp/openrc-build
    meson setup /tmp/openrc-build \
        --prefix=/usr \
        -Dpkg_prefix=/usr \
        -Dpam=false \
        -Daudit=disabled \
        -Dselinux=disabled
    ninja -C /tmp/openrc-build
    meson install -C /tmp/openrc-build
"

# Run meson_final.sh if it exists (sets up /etc/runlevels, /etc/init.d symlinks)
if chroot "$ROOTFS" test -x /usr/libexec/rc/bin/meson_final.sh 2>/dev/null; then
    xchroot "DESTDIR='' /usr/libexec/rc/bin/meson_final.sh /usr/libexec/rc linux"
fi

umount "$ROOTFS/openrc-src"

# ─── Step 8: cloud-init installation ──────────────────────────────────────────
echo "==> Installing cloud-init $CLOUDINIT_TAG"
CLOUDINIT_SRC="/tmp/cloud-init-src-$$"
if [ ! -d "$CLOUDINIT_SRC" ]; then
    git clone --depth=1 --branch "$CLOUDINIT_TAG" \
        https://github.com/canonical/cloud-init.git "$CLOUDINIT_SRC"
fi

PYVER="$(xchroot "python3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")'  2>/dev/null")"
PYSITE="$ROOTFS/usr/lib/python${PYVER}/site-packages"
mkdir -p "$PYSITE"

cp -r "$CLOUDINIT_SRC/cloudinit" "$PYSITE/"

for bin in bin/cloud-init bin/cloud-id; do
    [ -f "$CLOUDINIT_SRC/$bin" ] && \
        install -m 755 "$CLOUDINIT_SRC/$bin" "$ROOTFS/usr/bin/"
done
[ -f "$CLOUDINIT_SRC/tools/cloud-init-per" ] && \
    install -m 755 "$CLOUDINIT_SRC/tools/cloud-init-per" "$ROOTFS/usr/bin/"

# Install OpenRC init scripts from cloud-init source
if [ -d "$CLOUDINIT_SRC/sysvinit/openrc" ]; then
    install -m 755 "$CLOUDINIT_SRC/sysvinit/openrc/"* "$ROOTFS/etc/init.d/"
fi

# Python deps via pip (--break-system-packages needed for PEP 668 on Void Linux)
xchroot "pip3 install --break-system-packages --no-build-isolation --no-deps \
    Jinja2 oauthlib configobj jsonschema PyYAML requests jsonpatch netifaces2"

rm -rf "$CLOUDINIT_SRC"

# ─── Step 9: System configuration ─────────────────────────────────────────────
echo "==> Configuring system"

# fstab (NO cgroup entry)
cat > "$ROOTFS/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0  1
UUID=${EFI_UUID}   /boot/efi  vfat  defaults          0  2
EOF

# hostname
echo "void-oci" > "$ROOTFS/etc/hostname"

# GRUB
install -m 644 "$VOID_OCI_DIR/files/grub" "$ROOTFS/etc/default/grub"

# dracut — bake cgroup_no_v1=all into initramfs cmdline
mkdir -p "$ROOTFS/etc/dracut.conf.d"
echo 'kernel_cmdline+=" cgroup_no_v1=all"' > "$ROOTFS/etc/dracut.conf.d/20-cgroup.conf"

# openrc config (NOTE: openrc.conf, NOT rc.conf — rc.conf belongs to runit/Void)
install -m 644 "$VOID_OCI_DIR/files/openrc.conf" "$ROOTFS/etc/openrc.conf"

# SSH
install -m 600 "$VOID_OCI_DIR/files/sshd_config" "$ROOTFS/etc/ssh/sshd_config"

# sudoers
mkdir -p "$ROOTFS/etc/sudoers.d"
install -m 440 "$VOID_OCI_DIR/files/sudoers-void" "$ROOTFS/etc/sudoers.d/void"

# dhcpcd init script
install -m 755 "$VOID_OCI_DIR/files/dhcpcd" "$ROOTFS/etc/init.d/dhcpcd"

# cloud-init config
mkdir -p "$ROOTFS/etc/cloud"
install -m 644 "$VOID_OCI_DIR/files/cloud.cfg" "$ROOTFS/etc/cloud/cloud.cfg"

# void user
xchroot "useradd -m -u 1000 -G wheel,adm -s /bin/bash void 2>/dev/null || true"
xchroot "passwd -l void"
xchroot "passwd -l root"

# ─── Step 10: GRUB installation ───────────────────────────────────────────────
echo "==> Installing GRUB"
if [ "$ARCH" = "x86_64" ]; then
    xchroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable"
else
    xchroot "grub-install --target=arm64-efi --efi-directory=/boot/efi --removable"
fi
xchroot "update-grub"

# ─── Step 11: Initramfs ───────────────────────────────────────────────────────
echo "==> Generating initramfs"
for kver in "$ROOTFS/usr/lib/modules/"*/; do
    kver="$(basename "$kver")"
    echo "    dracut for kernel $kver"
    xchroot "dracut --force --kver '$kver'"
done

# ─── Step 12: OpenRC runlevels ────────────────────────────────────────────────
echo "==> Configuring OpenRC runlevels"
mkdir -p "$ROOTFS/etc/runlevels/sysinit" \
         "$ROOTFS/etc/runlevels/boot" \
         "$ROOTFS/etc/runlevels/default" \
         "$ROOTFS/etc/runlevels/shutdown"

# sysinit: devfs dmesg sysfs only — NO cgroups (runit owns cgroup2 mounting)
for svc in devfs dmesg sysfs; do
    ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/sysinit/$svc"
done
rm -f "$ROOTFS/etc/runlevels/sysinit/cgroups"

# boot: cloud-init chain + dhcpcd
for svc in cloud-init-local dhcpcd cloud-init cloud-config cloud-final; do
    ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/boot/$svc"
done

# default: sshd
ln -sf "/etc/init.d/sshd" "$ROOTFS/etc/runlevels/default/sshd"

# ─── Step 13: Image sealing ───────────────────────────────────────────────────
echo "==> Sealing image"
echo "" > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/etc/ssh/ssh_host_"*
rm -rf "$ROOTFS/var/cache/xbps/"*
rm -rf "$ROOTFS/var/log/"*
rm -f  "$ROOTFS/etc/resolv.conf"
[ "$ARCH" = "aarch64" ] && rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# ─── Step 14: Sync and unmount ────────────────────────────────────────────────
echo "==> Syncing"
sync

umount "$ROOTFS/dev/pts"
umount "$ROOTFS/dev"
umount "$ROOTFS/sys"
umount "$ROOTFS/proc"
umount "$ROOTFS/boot/efi"
umount "$ROOTFS"
rmdir "$ROOTFS"
ROOTFS=""

qemu-nbd --disconnect "$NBD"
NBD=""

echo "==> Done: $OUTPUT"
echo ""
echo "Verify:"
echo "  sudo modprobe nbd; sudo qemu-nbd --connect=/dev/nbd0 $OUTPUT"
echo "  sudo mount /dev/nbd0p2 /tmp/v"
echo "  grep cgroup /tmp/v/etc/fstab   # should be empty"
echo "  cat /tmp/v/etc/hostname        # void-oci"
echo "  cat /tmp/v/etc/default/grub    # check cmdline"
echo "  ls /tmp/v/etc/runlevels/sysinit/  # NO cgroups"
echo "  sudo umount /tmp/v; sudo qemu-nbd --disconnect /dev/nbd0"
