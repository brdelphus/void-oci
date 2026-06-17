#!/bin/bash
# build.sh — reproducible Void Linux cloud QCOW2 image builder
# Usage: sudo ./build.sh [x86_64|aarch64] [oracle|aws|azure|gcp|auto]
# Requires: qemu-img qemu-nbd parted partx mkfs.vfat mkfs.ext4 blkid curl tar
#           meson ninja gcc (for OpenRC compile inside chroot)
#           For aarch64: qemu-aarch64-static (qemu-user-static package)
set -euo pipefail

# ─── Global build lock (prevent concurrent runs) ──────────────────────────────
LOCKFILE="/tmp/void-oci-build-${1:-x86_64}-${2:-oracle}.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo "ERROR: Another build is already running (lock: $LOCKFILE). PID $(cat "$LOCKFILE/pid" 2>/dev/null)"
    exit 1
fi
echo $$ > "$LOCKFILE/pid"
# ─── Configuration ────────────────────────────────────────────────────────────
ARCH="${1:-x86_64}"
CLOUD="${2:-oracle}"
VOID_DATE="20250202"
IMAGE_SIZE="8G"
VOID_OCI_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENRC_SRC="$VOID_OCI_DIR/openrc"
OUTPUT="$VOID_OCI_DIR/void-${CLOUD}-${ARCH}.qcow2"
CLOUDINIT_TAG="26.1"
ROOTFS="$(mktemp -d /tmp/void-oci-rootfs.XXXXXX)"
OCI_BUCKET="${OCI_BUCKET:-void-images}"
VOID_PACKAGES="${VOID_PACKAGES:-/usr/src/void-packages}"

# ─── Validation ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "ERROR: ARCH must be x86_64 or aarch64"; exit 1 ;;
esac

case "$CLOUD" in
    oracle) DATASOURCE="Oracle" ;;
    aws)    DATASOURCE="Ec2" ;;
    azure)  DATASOURCE="Azure" ;;
    gcp)    DATASOURCE="GCE" ;;
    auto)   DATASOURCE="Oracle, Ec2, Azure, GCE" ;;
    *) echo "ERROR: CLOUD must be oracle, aws, azure, gcp, or auto"; exit 1 ;;
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
    umount "$ROOTFS/tmp/oca-repo" 2>/dev/null || true
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

echo "==> Building void-${CLOUD}-${ARCH}.qcow2 -> $OUTPUT"
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

if [ "$ARCH" = "aarch64" ]; then
    xchroot() { chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/sh -c "$*"; }
else
    xchroot() { chroot "$ROOTFS" /bin/sh -c "$*"; }
fi

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
COMMON_PKGS="base-minimal dracut openssh dhcpcd iproute2 grub python3 python3-pip python3-setuptools libcap-devel meson ninja pkg-config gcc make git curl wget ca-certificates e2fsprogs parted chrony kbd logrotate rsyslog cloud-guest-utils wireguard-tools"

if [ "$ARCH" = "x86_64" ]; then
    ARCH_PKGS="linux6.12 linux6.18 linux-firmware-amd linux-firmware-intel grub-x86_64-efi"
else
    ARCH_PKGS="linux6.12 grub-arm64-efi"
fi

echo "==> Installing packages"
# xbps exits non-zero if some packages are already installed; that's fine
# shellcheck disable=SC2086
xchroot "xbps-install -y $COMMON_PKGS $ARCH_PKGS" || true
xchroot "xbps-remove -yoO" || true
xchroot "vkpurge rm all" 2>/dev/null || true

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

[ -f "$CLOUDINIT_SRC/tools/cloud-init-per" ] && \
    install -m 755 "$CLOUDINIT_SRC/tools/cloud-init-per" "$ROOTFS/usr/bin/"

# cloud-init and cloud-id are generated as entry points by setuptools in newer
# versions and may not exist as source files — write the wrappers explicitly.
cat > "$ROOTFS/usr/bin/cloud-init" << 'SCRIPT'
#!/usr/bin/python3
import sys
from cloudinit.cmd.main import main
sys.exit(main())
SCRIPT
chmod 755 "$ROOTFS/usr/bin/cloud-init"

cat > "$ROOTFS/usr/bin/cloud-id" << 'SCRIPT'
#!/usr/bin/python3
import sys
from cloudinit.cmd.cloud_id import main
sys.exit(main())
SCRIPT
chmod 755 "$ROOTFS/usr/bin/cloud-id"

# Install OpenRC init scripts from cloud-init source
if [ -d "$CLOUDINIT_SRC/sysvinit/openrc" ]; then
    install -m 755 "$CLOUDINIT_SRC/sysvinit/openrc/"* "$ROOTFS/etc/init.d/"
fi

# Python deps via pip (--break-system-packages needed for PEP 668 on Void Linux)
xchroot "pip3 install --break-system-packages --no-build-isolation \
    Jinja2 oauthlib configobj jsonschema PyYAML requests jsonpatch netifaces2"

rm -rf "$CLOUDINIT_SRC"

# ─── Step 8b: oracle-cloud-agent ──────────────────────────────────────────────
if [ "$CLOUD" = "oracle" ] && [ -d "$VOID_PACKAGES" ] && \
   [ -f "$VOID_OCI_DIR/srcpkgs/oracle-cloud-agent/template" ]; then
    echo "==> oracle-cloud-agent: syncing template to void-packages"
    cp -r "$VOID_OCI_DIR/srcpkgs/oracle-cloud-agent" "$VOID_PACKAGES/srcpkgs/"
    echo "==> oracle-cloud-agent: locating package for $ARCH"
    OCA_PKG=$(find "$VOID_PACKAGES/hostdir/binpkgs" \
        -name "oracle-cloud-agent-*.${ARCH}.xbps" 2>/dev/null | sort -V | tail -1)

    if [ -z "$OCA_PKG" ]; then
        echo "==> oracle-cloud-agent: building for $ARCH (downloads ~100MB snap)"
        if [ "$ARCH" = "aarch64" ]; then
            ( cd "$VOID_PACKAGES" && ./xbps-src -a aarch64 pkg oracle-cloud-agent ) || true
        else
            ( cd "$VOID_PACKAGES" && ./xbps-src pkg oracle-cloud-agent ) || true
        fi
        OCA_PKG=$(find "$VOID_PACKAGES/hostdir/binpkgs" \
            -name "oracle-cloud-agent-*.${ARCH}.xbps" 2>/dev/null | sort -V | tail -1)
    fi

    if [ -n "$OCA_PKG" ]; then
        echo "==> oracle-cloud-agent: installing $(basename "$OCA_PKG")"
        OCA_REPO="$ROOTFS/tmp/oca-repo"
        mkdir -p "$OCA_REPO"
        cp "$OCA_PKG" "$OCA_REPO/"
        XBPS_ARCH="$ARCH" xbps-rindex -a "$OCA_REPO/"*.xbps
        xchroot "XBPS_ALLOW_UNSIGNED_PKGS=1 xbps-install -y --repository=/tmp/oca-repo oracle-cloud-agent" || \
            echo "WARNING: oracle-cloud-agent install failed — skipping"
        rm -rf "$OCA_REPO"
    else
        echo "WARNING: oracle-cloud-agent build failed or not found for $ARCH — skipping"
    fi
fi

# ─── Step 9: System configuration ─────────────────────────────────────────────
echo "==> Configuring system"

# fstab (NO cgroup entry)
cat > "$ROOTFS/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0  1
UUID=${EFI_UUID}   /boot/efi  vfat  defaults          0  2
EOF

# hostname
echo "void-oci" > "$ROOTFS/etc/hostname"

# GRUB — files/grub includes hvc0 + ttyAMA0 + ttyS0 + earlycon for max compatibility
install -m 644 "$VOID_OCI_DIR/files/grub" "$ROOTFS/etc/default/grub"

# dracut — bake cgroup_no_v1=all into initramfs cmdline
mkdir -p "$ROOTFS/etc/dracut.conf.d"
echo 'kernel_cmdline+=" cgroup_no_v1=all"' > "$ROOTFS/etc/dracut.conf.d/20-cgroup.conf"

# Ensure virtio_net is loaded by the modules service before dhcpcd starts.
# OpenRC's modules service reads /etc/modules-load.d/ (not /etc/modules).
mkdir -p "$ROOTFS/etc/modules-load.d"
echo "virtio_net" > "$ROOTFS/etc/modules-load.d/virtio.conf"

# openrc config (NOTE: openrc.conf, NOT rc.conf — rc.conf belongs to runit/Void)
install -m 644 "$VOID_OCI_DIR/files/openrc.conf" "$ROOTFS/etc/openrc.conf"

# SSH
install -m 600 "$VOID_OCI_DIR/files/sshd_config" "$ROOTFS/etc/ssh/sshd_config"
# drop-in: ensure PasswordAuthentication yes wins regardless of what cloud-init writes
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
printf 'PasswordAuthentication yes\n' > "$ROOTFS/etc/ssh/sshd_config.d/00-void-oci.conf"
chmod 600 "$ROOTFS/etc/ssh/sshd_config.d/00-void-oci.conf"

# sudoers
mkdir -p "$ROOTFS/etc/sudoers.d"
install -m 440 "$VOID_OCI_DIR/files/sudoers-void" "$ROOTFS/etc/sudoers.d/void"

# OpenRC init scripts for services not provided by Void packages
install -m 755 "$VOID_OCI_DIR/files/dhcpcd"        "$ROOTFS/etc/init.d/dhcpcd"
install -m 755 "$VOID_OCI_DIR/files/sshd"          "$ROOTFS/etc/init.d/sshd"
install -m 755 "$VOID_OCI_DIR/files/chrony"        "$ROOTFS/etc/init.d/chronyd"
install -m 755 "$VOID_OCI_DIR/files/mount-shared"  "$ROOTFS/etc/init.d/mount-shared"
install -m 755 "$VOID_OCI_DIR/files/rsyslogd"     "$ROOTFS/etc/init.d/rsyslogd"
install -m 644 "$VOID_OCI_DIR/files/chrony.conf" "$ROOTFS/etc/chrony.conf"

# cloud-init config — inject datasource for target cloud
mkdir -p "$ROOTFS/etc/cloud"
sed "s|@@DATASOURCE@@|$DATASOURCE|g" "$VOID_OCI_DIR/files/cloud.cfg" \
    > "$ROOTFS/etc/cloud/cloud.cfg"
chmod 644 "$ROOTFS/etc/cloud/cloud.cfg"

# void user
xchroot "useradd -m -u 1000 -G wheel,adm -s /bin/bash void 2>/dev/null || true"
# oracle-cloud-agent system group (required by oci-osmh plugin for Unix socket)
xchroot "groupadd -r oracle-cloud-agent 2>/dev/null || true"
# chpasswd can silently fail in a minimal chroot; write the hash directly instead
VOIDHASH=$(openssl passwd -6 "voidlinux")
sed -i "s|^void:[^:]*:|void:${VOIDHASH}:|" "$ROOTFS/etc/shadow"
sed -i "s|^root:[^:]*:|root:${VOIDHASH}:|" "$ROOTFS/etc/shadow"

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

# sysinit: devfs dmesg sysfs + mount-shared (required for container runtimes)
# mount-shared runs mount --make-rshared / — OpenRC (unlike systemd) does not
# set MS_SHARED on the root mount, so containers with Bidirectional/HostToContainer
# mount propagation (CSI drivers, node-exporter) fail without it.
for svc in devfs dmesg sysfs mount-shared; do
    ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/sysinit/$svc"
done
rm -f "$ROOTFS/etc/runlevels/sysinit/cgroups"

# boot: cloud-init chain + dhcpcd + chrony
for svc in cloud-init-local dhcpcd cloud-init cloud-config cloud-final chronyd; do
    ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/boot/$svc"
done

# boot: sshd — must be here, not default, so it starts independently of cloud-init.
# If sshd is in default, the entire default runlevel waits for boot (cloud-init chain)
# to finish. On OCI, cloud-init-local is slow on first boot so SSH would be unreachable
# until cloud-init completes. Moving to boot lets sshd start as soon as dhcpcd is up.
ln -sf "/etc/init.d/sshd" "$ROOTFS/etc/runlevels/boot/sshd"

# default: rsyslog
ln -sf "/etc/init.d/rsyslogd" "$ROOTFS/etc/runlevels/default/rsyslogd" 2>/dev/null || true

# default: oracle-cloud-agent (OCI only — installed by step 8b)
if [ "$CLOUD" = "oracle" ] && [ -f "$ROOTFS/etc/init.d/oracle-cloud-agent" ]; then
    ln -sf "/etc/init.d/oracle-cloud-agent" \
        "$ROOTFS/etc/runlevels/default/oracle-cloud-agent"
fi

# Serial console agetty — enables OCI "Launch serial console" browser terminal
SERIAL_DEV=$( [ "$ARCH" = "aarch64" ] && echo "ttyAMA0" || echo "ttyS0" )
if [ -d "$ROOTFS/etc/sv/agetty-${SERIAL_DEV}" ]; then
    ln -sf "/etc/sv/agetty-${SERIAL_DEV}" \
           "$ROOTFS/etc/runit/runsvdir/default/agetty-${SERIAL_DEV}"
fi

# Runit service that drives OpenRC — this is what actually invokes OpenRC at boot.
# /var/service is a runtime symlink; the correct build-time location is
# /etc/runit/runsvdir/default/ (Void's stage 1 populates /run/runit/runsvdir/default
# from here, and /var/service -> ../run/runit/runsvdir/current -> default).
mkdir -p "$ROOTFS/etc/sv/openrc"
install -m 755 "$VOID_OCI_DIR/files/sv-openrc-run"    "$ROOTFS/etc/sv/openrc/run"
install -m 755 "$VOID_OCI_DIR/files/sv-openrc-finish" "$ROOTFS/etc/sv/openrc/finish"
ln -sf /etc/sv/openrc "$ROOTFS/etc/runit/runsvdir/default/openrc"

# Remove unused agetty virtual consoles (no physical terminals in a cloud VM)
rm -f "$ROOTFS/etc/runit/runsvdir/default/agetty-tty"*

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

if [ "$CLOUD" = "oracle" ]; then
    NS=$(oci os ns get --query 'data' --raw-output 2>/dev/null || true)
    COMPARTMENT=$(oci iam compartment list --query 'data[0].id' --raw-output 2>/dev/null || true)
    REGION=$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null || true)

    if [ -n "$NS" ] && [ -n "$COMPARTMENT" ] && [ -n "$REGION" ]; then
        OBJNAME="$(basename "$OUTPUT")"
        DISPLAY="void-oci-${ARCH}-$(date +%Y%m%d)"

        echo ""
        echo "==> OCI: uploading $OBJNAME to object storage"
        oci os object put \
            --namespace "$NS" \
            --bucket-name "${OCI_BUCKET:-void-images}" \
            --name "$OBJNAME" \
            --file "$OUTPUT" \
            --force

        echo "==> OCI: importing image (CUSTOM / UEFI_64 / PARAVIRTUALIZED)"
        IMAGE_ID=$(oci raw-request --http-method POST \
            --target-uri "https://iaas.${REGION}.oraclecloud.com/20160918/images" \
            --request-body "{
              \"compartmentId\": \"$COMPARTMENT\",
              \"displayName\": \"$DISPLAY\",
              \"launchMode\": \"CUSTOM\",
              \"launchOptions\": {
                \"bootVolumeType\": \"PARAVIRTUALIZED\",
                \"firmware\": \"UEFI_64\",
                \"networkType\": \"PARAVIRTUALIZED\",
                \"remoteDataVolumeType\": \"PARAVIRTUALIZED\"
              },
              \"imageSourceDetails\": {
                \"sourceType\": \"objectStorageTuple\",
                \"objectName\": \"$OBJNAME\",
                \"bucketName\": \"${OCI_BUCKET:-void-images}\",
                \"namespaceName\": \"$NS\",
                \"sourceImageType\": \"QCOW2\"
              }
            }" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || true)

        if [ -n "$IMAGE_ID" ]; then
            echo "==> OCI: image $IMAGE_ID (importing, may take ~10 min)"
            oci compute image-shape-compatibility-entry add \
                --image-id "$IMAGE_ID" \
                --shape-name "VM.Standard.A1.Flex" 2>/dev/null || true
        fi
    else
        echo ""
        echo "Note: oci CLI not configured — skipping OCI upload/import."
        echo "      Set up ~/.oci/config or run: oci setup config"
    fi
fi
