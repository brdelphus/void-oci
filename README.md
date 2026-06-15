# void-oci

Reproducible QCOW2 image builder for Void Linux OCI instances (Oracle Cloud),
purpose-built for running k3s clusters.

## Why

Oracle Cloud has no official Void Linux images. Running k3s on mainstream distro
images (Ubuntu, Oracle Linux) means fighting systemd's cgroup management, which
conflicts with containerd's resource isolation. Void solves this cleanly:

- **No systemd** — runit as PID 1 stays out of cgroup management entirely
- **cgroup v2 unified hierarchy** (`cgroup_no_v1=all`) — required by containerd;
  eliminates the v1/v2 hybrid that breaks k3s on most cloud images
- **OpenRC as the service manager** — both cloud-init and k3s expect an
  OpenRC/SysV-compatible service interface (`rc-service`, `rc-update`, init
  scripts in `/etc/init.d/`). This image runs OpenRC for all service management;
  runit is kept as PID 1 purely for its boot stage handling and process
  supervision, but it supervises only one thing: the OpenRC service itself
- **Reproducible image** — OCI requires uploading a custom image; without a build
  script, every new cluster node would need manual setup

## Init architecture

runit is Void's native PID 1 but in these images it acts purely as a bootloader:

```
runit (PID 1)
  stage 1 — mounts /proc, /sys, sets up the environment
  stage 2 — runsvdir /var/service/
               └─ openrc (only runit-supervised service)
                    ├─ openrc sysinit  →  devfs, dmesg, sysfs
                    ├─ openrc boot     →  dhcpcd, cloud-init chain, chronyd
                    └─ openrc default  →  sshd, k3s (when installed)
  stage 3 — openrc shutdown → system halt
```

**runit does not manage any application services directly.** It hands off to
OpenRC as soon as stage 2 starts. All services — networking, cloud-init,
SSH, NTP, and k3s — are OpenRC services managed with the standard
`rc-service` / `rc-update` commands.

This matters because:
- cloud-init's OpenRC init scripts call `rc-service` to start/stop services
  during provisioning; they expect OpenRC, not runit's `sv` command
- k3s ships an OpenRC init script and registers itself with `rc-update`; on a
  pure runit system this would silently do nothing
- operators familiar with Alpine or Gentoo can manage services the same way

Generates bootable images for x86_64 and aarch64 with:
- Void Linux (runit as PID 1) + OpenRC layered on top
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
sudo ./build.sh [x86_64|aarch64] [oracle|aws|azure|gcp|auto]
```

The second argument selects the cloud target (default: `oracle`):

| Target | cloud-init datasource |
|---|---|
| `oracle` | Oracle |
| `aws` | Ec2 |
| `azure` | Azure |
| `gcp` | GCE |
| `auto` | Oracle, Ec2, Azure, GCE (auto-detect) |

Examples:
```sh
sudo ./build.sh x86_64 oracle    # → void-oracle-x86_64.qcow2
sudo ./build.sh x86_64 aws       # → void-aws-x86_64.qcow2
sudo ./build.sh aarch64 gcp      # → void-gcp-aarch64.qcow2
sudo ./build.sh x86_64 auto      # → void-auto-x86_64.qcow2 (any cloud)
```

Output images are ~2GB. Build takes 15–25 min per arch (dominated by package
download + OpenRC compile). The rootfs tarballs are cached locally after the
first download.

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
| Default user | `void` (UID 1000, wheel) |
| Passwords | `void` / `root` → `voidlinux` (change on first login) |
| SSH | Password auth enabled; cloud-init injects your SSH key on first boot |

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
