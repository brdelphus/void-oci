# void-oci

Reproducible QCOW2 image builder for Void Linux OCI instances (Oracle Cloud).

Generates bootable images for x86_64 and aarch64 with:
- Void Linux (runit as PID 1) + OpenRC layered on top (for k3s / service management)
- cgroup v2 unified hierarchy (`cgroup_no_v1=all`)
- cloud-init 26.1 (Oracle datasource)
- GRUB with serial console
- OpenRC built from source (embedded in this repo under `openrc/`)

## Requirements

```
qemu-img  qemu-nbd  parted  partx  mkfs.vfat  mkfs.ext4  blkid  curl  tar
meson  ninja  gcc                  # for OpenRC build inside chroot
```

For aarch64 cross-builds:
```
qemu-aarch64-static    # Void: xbps-install qemu-user-static
```

## Usage

```sh
sudo ./build.sh x86_64
sudo ./build.sh aarch64
```

Output: `void-oci-x86_64.qcow2` / `void-oci-aarch64.qcow2` (~2GB)

Build takes 15–25 min per arch (dominated by package download + OpenRC compile).
The rootfs tarballs are cached locally after the first download.

## What gets built

| Component | Detail |
|---|---|
| Base | Void Linux ROOTFS 20250202 |
| Kernel (x86_64) | linux6.12 + linux6.18 |
| Kernel (aarch64) | linux6.12 |
| Bootloader | GRUB EFI (removable) |
| Init | runit (PID 1) → OpenRC (services) |
| Network | dhcpcd on eth0 |
| Cloud init | cloud-init 26.1, Oracle datasource |
| Default user | `void` (UID 1000, wheel, SSH keys via cloud-init) |

## Disk layout

```
GPT, 8G image
  p1  256M  EFI (vfat)
  p2  rest  Linux root (ext4, label: void-oci)
```

## OpenRC runlevels

| Runlevel | Services |
|---|---|
| sysinit | devfs, dmesg, sysfs |
| boot | cloud-init-local, cloud-init, cloud-config, cloud-final, dhcpcd |
| default | sshd |

No cgroups service in sysinit — runit mounts cgroup2 in stage 1.

## Configuration files

| File | Destination |
|---|---|
| `files/grub` | `/etc/default/grub` |
| `files/openrc.conf` | `/etc/openrc.conf` |
| `files/cloud.cfg` | `/etc/cloud/cloud.cfg` |
| `files/sshd_config` | `/etc/ssh/sshd_config` |
| `files/dhcpcd` | `/etc/init.d/dhcpcd` |
| `files/sudoers-void` | `/etc/sudoers.d/void` |

## OpenRC source

The `openrc/` directory contains the OpenRC source with patches for Void Linux:

- `tools/meson_final.sh` — supports both `MESON_BUILDDIR` (meson ≥1.5) and `MESON_BUILD_ROOT` (meson <1.5)
- `etc/openrc.conf` — replaces `etc/rc.conf` (which conflicts with Void's runit config)
- `sh/init.sh.Linux.in` — cgroup v2 unified hierarchy support
