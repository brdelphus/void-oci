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
                    ├─ openrc boot     →  dhcpcd, cloud-init chain, chronyd, sshd
                    └─ openrc default  →  rsyslogd, k3s (when installed)
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

## Local QEMU testing

The images use GRUB-EFI (GPT disk, no BIOS boot partition). SeaBIOS cannot boot
them — OVMF is required (`xbps-install edk2-ovmf`).

**Prerequisite: disable cloud-init** — without an IMDS endpoint at 169.254.169.254
the Oracle datasource hangs during the boot runlevel, so sshd never starts. Add
`cloud-init=disabled` to the GRUB cmdline before booting:

```sh
sudo qemu-nbd --connect=/dev/nbd0 void-oracle-x86_64.qcow2
sudo partx -u /dev/nbd0
sudo mount /dev/nbd0p2 /mnt
sudo sed -i 's| console=tty0| cloud-init=disabled console=tty0|g' /mnt/boot/grub/grub.cfg
sudo umount /mnt && sudo qemu-nbd --disconnect /dev/nbd0
```

### x86_64

```sh
cp /usr/share/edk2/x64/OVMF_VARS.fd /tmp/ovmf-vars.fd

qemu-system-x86_64 \
    -enable-kvm -cpu host -m 2G \
    -drive if=pflash,format=raw,unit=0,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=/tmp/ovmf-vars.fd \
    -drive file=void-oracle-x86_64.qcow2,if=virtio,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::2223-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial file:/tmp/void-qemu.serial \
    -display none &

ssh -o StrictHostKeyChecking=no -p 2223 void@localhost  # password: voidlinux
```

Boots in ~20s with KVM. Serial output goes to `/tmp/void-qemu.serial`.

### aarch64

```sh
cp /usr/share/edk2/aarch64/QEMU_VARS.fd /tmp/qemu-aarch64-vars.fd

qemu-system-aarch64 \
    -M virt -cpu cortex-a57 -m 2G \
    -drive if=pflash,format=raw,unit=0,file=/usr/share/edk2/aarch64/QEMU_CODE.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=/tmp/qemu-aarch64-vars.fd \
    -drive file=void-oracle-aarch64.qcow2,if=virtio,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::2224-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial file:/tmp/void-qemu.serial \
    -display none &

ssh -o StrictHostKeyChecking=no -p 2224 void@localhost  # password: voidlinux
```

**No KVM** — aarch64 emulation on an x86 host is software-only. Expect ~2min to
reach the login prompt. GRUB prints `serial port 'com0' isn't found` because
`-M virt` uses a PL011 UART (`ttyAMA0`) rather than a 16550 COM port; this is
harmless — the boot continues and the kernel still comes up.

### Install k3s

```sh
curl -sfL https://get.k3s.io | sudo sh -
sudo k3s kubectl get nodes
```

k3s detects OpenRC and installs its init script to `/etc/init.d/k3s`, enables it
in the default runlevel, and starts it immediately. The node goes Ready within
~15s on x86_64 (longer on emulated aarch64).

### Verified

| Arch | Kernel | k3s | containerd | Result |
|---|---|---|---|---|
| x86_64 | 6.18.35_1 | v1.35.5+k3s1 | 2.2.3-k3s1 | Ready |
| aarch64 | 6.12.93_1 | v1.35.5+k3s1 | 2.2.3-k3s1 | Ready |

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
| OCI agent | oracle-cloud-agent 1.59.0-12 *(oracle builds only)* |
| Default user | `void` (UID 1000, wheel) |
| Passwords | `void` / `root` → `voidlinux` (change on first login) |
| SSH | Password auth enabled; cloud-init injects your SSH key on first boot; sshd in boot runlevel (ready before cloud-init completes) |

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
| boot | cloud-init-local, dhcpcd, cloud-init, cloud-config, cloud-final, chronyd, **sshd** |
| default | rsyslogd, oracle-cloud-agent *(oracle builds only)* |

sshd is in the boot runlevel (not default) so it becomes available as soon as
networking is up, without waiting for the cloud-init chain to complete. On OCI,
cloud-init-local can be slow on first boot (downloading instance metadata); if
sshd were in default, SSH would be unreachable until cloud-init finished.

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

## Oracle Cloud Agent

Oracle images include [Oracle Cloud Agent](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/manage-plugins.htm),
the lightweight Go daemon that enables OCI console features: monitoring, bastion
sessions, run command, OS management, and HPC plugins.

The agent is packaged as a Void xbps package built from the official snap
(statically linked Go binaries — no snapd required at runtime).

### Package location

```
srcpkgs/oracle-cloud-agent/
  template                          # xbps-src build template
  files/etc/oracle-cloud-agent/
    agent.yml                       # plugin config with corrected paths
  files/etc/init.d/
    oracle-cloud-agent              # OpenRC init script (supervise-daemon)
```

### Build

The package is built automatically during `./build.sh aarch64 oracle` if
`/usr/src/void-packages` (or `$VOID_PACKAGES`) exists and contains the template.
To pre-build it manually:

```sh
# x86_64
cd /usr/src/void-packages && ./xbps-src pkg oracle-cloud-agent

# aarch64
cd /usr/src/void-packages && ./xbps-src -a aarch64 pkg oracle-cloud-agent
```

Cached packages in `hostdir/binpkgs/` are reused on subsequent image builds.
If `$VOID_PACKAGES` is absent or the build fails, the image is built without
the agent and a warning is printed.

### Runtime

```
/usr/lib/oracle-cloud-agent/agent          # main daemon
/usr/lib/oracle-cloud-agent/plugins/       # gomon, bastions, oci-osmh, ...
/etc/oracle-cloud-agent/agent.yml          # plugin configuration
/var/log/oracle-cloud-agent/agent.log      # log (created at first start)
```

Manage with standard OpenRC commands:
```sh
rc-service oracle-cloud-agent start|stop|status
```

## OpenRC source

The `openrc/` directory contains the OpenRC source with patches for Void Linux:

- `tools/meson_final.sh` — supports both `MESON_BUILDDIR` (meson ≥1.5) and `MESON_BUILD_ROOT` (meson <1.5)
- `etc/openrc.conf` — replaces `etc/rc.conf` (which conflicts with Void's runit config)
- `sh/init.sh.Linux.in` — cgroup v2 unified hierarchy support
