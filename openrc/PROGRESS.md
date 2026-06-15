# OpenRC + k3s on Void Linux — Progress Log

## Goal

Run k3s on a local Void Linux machine using OpenRC as the service manager,
while keeping runit as PID 1 (the Void default). This also lays the groundwork
for running Void Linux nodes on Oracle Cloud (OCI) where cloud-init requires
OpenRC.

---

## System

- OS: Void Linux (glibc, x86_64)
- Kernel: 6.18.35_1
- Init: runit (PID 1)
- Bootloader: GRUB (LUKS + LVM setup)

> **WARNING — Void Linux uses runit as PID 1.**
> Void's runit stage 1 (`/etc/runit/1`) sources `/etc/rc.conf` at early boot.
> **`/etc/rc.conf` belongs to runit/Void — do NOT let OpenRC overwrite it.**
> OpenRC has been patched to use `/etc/openrc.conf` instead (see Step 5).
> Any `meson install` or rebuild must be followed by verifying `/etc/rc.conf`
> is still the original Void file (small, ~1.3KB) and not the OpenRC template.

---

## Step 1 — Build OpenRC from source

OpenRC is not in the Void xbps repositories. Built from source.

### Install build dependencies

```sh
sudo xbps-install -y meson libcap-devel
# gcc, ninja, pkg-config already present
```

### Clone and configure

```sh
cd /home/delphus/projects/openrc
git clone --depth=1 https://github.com/OpenRC/openrc.git .

meson setup build \
  --prefix=/usr \
  -Dpkg_prefix=/usr \
  -Dpam=false \
  -Daudit=disabled \
  -Dselinux=disabled
```

Configured cleanly: OpenRC 0.63, gcc 14.2.1, libcap 2.78.

### Compile

```sh
ninja -C build
# 159/159 targets — zero errors
```

### Install

`ninja install` fails due to a missing `MESON_BUILD_ROOT` env when run via
sudo. Workaround: run `meson install` from the build dir, then manually
complete the final step.

```sh
cd build && sudo meson install
# Fails on meson_final.sh — run manually:
sudo sh -c 'MESON_BUILD_ROOT=/home/delphus/projects/openrc/build DESTDIR="" \
  /home/delphus/projects/openrc/tools/meson_final.sh /usr/libexec/rc linux'
```

### Verify

```sh
which rc-service rc-update openrc
rc-service --version
# rc-service (OpenRC) 1afc058
```

---

## Step 2 — Install k3s

k3s installer detects OpenRC via the presence of `rc-service` and automatically
creates an OpenRC init script. Use `INSTALL_K3S_SKIP_ENABLE=true` to prevent
the installer from trying to start the service before the runlevel is ready.

```sh
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_ENABLE=true sh -
```

Installer output confirms:
```
openrc: Creating service file /etc/init.d/k3s
```

The generated `/etc/init.d/k3s` uses OpenRC's `supervise-daemon` (built-in
process supervisor — handles restarts without runit involvement):

```sh
supervisor=supervise-daemon
name=k3s
command="/usr/local/bin/k3s"
command_args="server >>/ var/log/k3s.log 2>&1"
respawn_delay=5
respawn_max=0
depend() {
    after network-online
    want cgroups
}
```

---

## Step 3 — Wire OpenRC into runit (Option B)

### Architecture

```
runit (PID 1)
  └── /var/service/openrc  (runit service)
        └── openrc k3s     (enters custom OpenRC runlevel)
              └── k3s      (managed by supervise-daemon)
```

runit stays untouched as PID 1. OpenRC only manages services in the `k3s`
runlevel. Network and system services remain under runit.

### Why a custom runlevel?

Running `openrc default` caused OpenRC to take over network services,
conflicting with runit's dhcpcd. A dedicated runlevel containing only k3s
avoids all conflicts.

### Create the custom runlevel

```sh
sudo mkdir -p /etc/runlevels/k3s
sudo ln -s /etc/init.d/k3s /etc/runlevels/k3s/k3s
```

### Create the runit service

```sh
sudo mkdir -p /etc/sv/openrc
sudo tee /etc/sv/openrc/run << 'EOF'
#!/bin/sh
openrc k3s
exec sleep infinity
EOF
sudo chmod +x /etc/sv/openrc/run
```

`openrc k3s` runs once to start services in the runlevel, then `sleep infinity`
keeps the runit process alive so runit doesn't restart it in a loop.

### Enable the service

```sh
sudo ln -s /etc/sv/openrc /var/service/openrc
```

### Verify

```sh
sv status openrc        # run: openrc: (pid XXXXX) Xs
rc-status k3s           # k3s  [ started ]
rc-service k3s status   # status: started
```

---

## Step 4 — Fix cgroup v2 (required by k3s v1.35+)

k3s failed with:
```
Error: failed to find cpu cgroup (v2)
```

### Root cause

Two separate components control cgroup mounting on this system:

1. **void-runit** (`/etc/runit/core-services/00-pseudofs.sh`) — runs at early
   boot (stage 1). Reads `CGROUP_MODE` from `/etc/rc.conf`. Defaults to
   `unified` (cgroup v2 only) when unset.

2. **OpenRC** — runs later when `openrc k3s` is invoked. Has its own cgroup
   mounting code, controlled by `rc_cgroup_mode` in `/etc/openrc.conf`
   (patched in Step 5 — originally also read from `/etc/rc.conf`).

The failure mode: void-runit correctly mounts cgroup2 at `/sys/fs/cgroup`.
Then OpenRC starts and, with `rc_cgroup_mode` unset, mounts **cgroup v1 with
all controllers on top of the same path**. This takes the cpu (and other)
controllers away from the v2 hierarchy, leaving
`/sys/fs/cgroup/cgroup.controllers` empty. k3s can't find the cpu controller.

Confirmed via `mount | grep cgroup` — three overlapping mounts on
`/sys/fs/cgroup`: two cgroup2 and one cgroup (v1 with all controllers).

**Dead ends along the way:**
- `systemd.unified_cgroup_hierarchy=1` in GRUB — systemd-only parameter,
  ignored by the kernel on runit systems.
- `kernel_cmdline+=" cgroup_no_v1=all"` in dracut.conf.d — embeds the param
  inside the initramfs only; GRUB still needs to pass it on the kernel cmdline.
- Neither fix addressed the real problem: OpenRC remounting v1 after boot.

### Fix

**1. Tell OpenRC to use cgroup v2 only** (the actual fix):

```sh
# In /etc/openrc.conf, uncomment:
rc_cgroup_mode="unified"
```

This prevents OpenRC from mounting v1 cgroup controllers when it starts.
Note: OpenRC reads `/etc/openrc.conf`, not `/etc/rc.conf` — see Step 5.

**2. Add `cgroup_no_v1=all` to the GRUB kernel cmdline** (belt-and-suspenders):

Edit `/etc/default/grub`, replace `systemd.unified_cgroup_hierarchy=1` with
`cgroup_no_v1=all` in `GRUB_CMDLINE_LINUX_DEFAULT`, then:

```sh
sudo update-grub
```

`cgroup_no_v1=all` is a true kernel parameter that prevents any v1 cgroup
mount from succeeding, regardless of what userspace tries.

**Note:** the dracut.conf.d entry (`/etc/dracut.conf.d/20-cgroup.conf`) embeds
`cgroup_no_v1=all` in the initramfs but this alone does not affect the kernel
cmdline seen by GRUB. The GRUB edit is required.

### Step 4b — Fix boot crash: bad cgroup entry in /etc/fstab

**Symptom:** boot drops to emergency shell with:

```
=> Mounting all non-network filesystems...
mount: /sys/fs/cgroup: fsconfig() failed: cgroup: Need name or subsystem set.
Cannot continue due to errors above, starting emergency shell.
```

**Root cause:** `/etc/fstab` contained:

```
cgroup /sys/fs/cgroup cgroup defaults 0 0
```

runit's `03-filesystems.sh` runs `mount -a` which hits this entry. The bare
`cgroup` type with only `defaults` (no subsystem, no `name=`) is rejected by
the kernel. With `cgroup_no_v1=all` on the kernel cmdline, this also fails
because all v1 controllers are disabled. Additionally, runit's `00-pseudofs.sh`
already mounted cgroup2 at `/sys/fs/cgroup` in stage 1 — this entry is
entirely redundant.

**Fix:**

```sh
sudo sed -i 's|^cgroup /sys/fs/cgroup cgroup defaults 0 0|# removed: runit 00-pseudofs.sh mounts cgroup2 (unified). cgroup_no_v1=all makes this fail.|' /etc/fstab
```

> **WARNING:** Never add a `cgroup` or `cgroup2` entry to `/etc/fstab` on this
> system. runit owns cgroup mounting via `00-pseudofs.sh` (stage 1).

Also removed OpenRC's `cgroups` service from sysinit (redundant — runit handles it):

```sh
sudo rc-update del cgroups sysinit
```

### Verify after reboot

```sh
cat /sys/fs/cgroup/cgroup.controllers   # must be non-empty: cpu memory io pids ...
mount | grep cgroup                     # should show exactly one cgroup2 mount
sudo k3s kubectl get nodes
```

---

## Step 5 — Decouple OpenRC config from void-runit

### Problem

`meson install` drops OpenRC's 12KB config template at `/etc/rc.conf`,
overwriting void-runit's 1.3KB file. Since runit stage 1 (`/etc/runit/1`)
sources `/etc/rc.conf` at boot, this broke boot with a runit error.

### Fix: patch OpenRC source to use `openrc.conf`

Renamed the config file throughout the OpenRC source so it never touches
`/etc/rc.conf`. Changed files:

- `src/librc/rc.h.in` — `RC_CONF` / `RC_CONF_D` macros
- `src/librc/librc-misc.c` — `"rc.conf"` / `"rc.conf.d"` string literals
- `src/librc/librc-depend.c` — `"rc.conf"` / `"rc.conf.d"` string literals
- `sh/init.sh.Linux.in`
- `sh/gendepends.sh.in`
- `sh/openrc-run.sh.in`
- `sh/openrc-user.sh.in`
- `etc/rc.conf` → renamed to `etc/openrc.conf` (source template)
- `etc/meson.build` — updated install list

Rebuilt and reinstalled:

```sh
ninja -C build
cd build && sudo meson install
# meson_final.sh fails as before — run manually:
sudo sh -c 'MESON_BUILD_ROOT=/home/delphus/projects/openrc/build DESTDIR="" \
  /home/delphus/projects/openrc/tools/meson_final.sh /usr/libexec/rc linux'
```

### Restore void-runit config and create OpenRC config

```sh
# Restore the original void-runit /etc/rc.conf
sudo cp /etc/rc.conf.new-20250212_1 /etc/rc.conf

# meson install already dropped /etc/openrc.conf (the OpenRC template)
# Uncomment the cgroup setting:
sudo sed -i 's/^#rc_cgroup_mode="unified"/rc_cgroup_mode="unified"/' /etc/openrc.conf
```

Result: `/etc/rc.conf` is runit's (1.3KB, void format). `/etc/openrc.conf` is
OpenRC's (12.5KB, with `rc_cgroup_mode="unified"` active).

---

## Status at last save

- [x] OpenRC 0.63 compiled and installed on Void Linux
- [x] k3s installed and OpenRC service file created at `/etc/init.d/k3s`
- [x] Custom `k3s` OpenRC runlevel created (network-safe)
- [x] runit service `/etc/sv/openrc` wiring OpenRC into boot
- [x] `cgroup_no_v1=all` in GRUB cmdline (`/etc/default/grub` + `update-grub`)
- [x] OpenRC patched to read `/etc/openrc.conf` instead of `/etc/rc.conf`
- [x] OpenRC `cgroups` service removed from sysinit — runit owns cgroup mounting
- [x] `rc_cgroup_mode="unified"` set in `/etc/openrc.conf`
- [x] `/etc/rc.conf` restored to original void-runit version
- [x] Rebooted — cgroup v2 fix verified
- [x] k3s comes up cleanly (`kubectl get nodes` → Ready, v1.35.5+k3s1)
- [x] Cilium/Flannel kernel prerequisites verified (all present)
- [x] `clang 21`, `llvm21` (includes `llvm-objcopy`), `bpftool` installed
- [ ] Install CNI (Cilium or Flannel)
- [ ] Test node joins (if expanding to multi-node)
- [ ] Migrate network from `/etc/rc.local` to OpenRC (see TODO below)

---

## Key files

| Path | Purpose |
|------|---------|
| `/home/delphus/projects/openrc/` | OpenRC source + build (patched) |
| `/etc/rc.conf` | void-runit config (restored original) |
| `/etc/openrc.conf` | OpenRC config (`rc_cgroup_mode="unified"`) |
| `/etc/init.d/k3s` | k3s OpenRC service script |
| `/etc/init.d/net.local` | (TODO) network OpenRC service replacing rc.local |
| `/etc/init.d/cloud-init-local` | (TODO) cloud-init local stage |
| `/etc/init.d/cloud-init` | (TODO) cloud-init network stage |
| `/etc/init.d/cloud-config` | (TODO) cloud-init config stage |
| `/etc/init.d/cloud-final` | (TODO) cloud-init final stage |
| `/etc/runlevels/k3s/` | Custom OpenRC runlevel (k3s only) |
| `/etc/sv/openrc/run` | runit service that triggers `openrc k3s` |
| `/etc/rc.local` | legacy network setup (to be commented out) |
| `/etc/dracut.conf.d/20-cgroup.conf` | embeds `cgroup_no_v1=all` in initramfs |
| `/var/log/k3s.log` | k3s runtime log |

---

## Known issues / gotchas

- `meson install` via sudo drops `MESON_BUILD_ROOT` — run `meson_final.sh`
  manually with both `MESON_BUILD_ROOT` and `DESTDIR=""` set.
- OpenRC's `default` runlevel conflicts with runit's network services — always
  use a custom runlevel.
- `kubectl` without sudo uses the wrong kubeconfig — use
  `sudo k3s kubectl` or copy `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config`.
- `kernel_cmdline` in dracut.conf.d embeds parameters inside the initramfs —
  it does NOT add them to the GRUB kernel cmdline. Edit `/etc/default/grub`
  directly and run `update-grub` to affect the actual boot cmdline.

### Path ownership — why we are NOT moving /etc/init.d

Investigated moving all OpenRC paths under `/etc/openrc/` to cleanly separate
from runit. Rejected for two reasons:

1. **cloud-init hardcodes `/etc/init.d/`** in its `meson.build`:
   `install_dir: '/etc/init.d'` — not configurable, always installs there.
   Moving OpenRC's init.d would silently break cloud-init.

2. **The collision never existed for init.d.** runit uses `/etc/sv/` and
   `/var/service/` — it never touches `/etc/init.d/`. The directories are
   already exclusive to OpenRC with no overlap.

The only genuine collision was `/etc/rc.conf`, which is resolved in Step 5.
cloud-init does **not** read `/etc/rc.conf` on Linux — that file is only
touched by cloud-init on BSD systems (FreeBSD, NetBSD).

**Current ownership is already clean:**

| Path | Owner |
|---|---|
| `/etc/sv/`, `/var/service/` | runit |
| `/etc/rc.conf` | void-runit (restored) |
| `/etc/init.d/`, `/etc/runlevels/`, `/etc/conf.d/` | OpenRC only |
| `/etc/openrc.conf` | OpenRC only |

---

## Step 6 — CNI prerequisites (Cilium / Flannel)

### Kernel check

All required kernel configs present on 6.18.35_1:
- BPF: `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`
- cgroup: `CONFIG_CGROUP_BPF=y`, `CONFIG_SOCK_CGROUP_DATA=y`
- BTF / CO-RE: `CONFIG_DEBUG_INFO_BTF=y`
- tc/cls: `CONFIG_NET_SCH_INGRESS=m`, `CONFIG_NET_CLS_BPF=m`, `CONFIG_NET_CLS_ACT=y`
- Tunnel: `CONFIG_VXLAN=m`, `CONFIG_GENEVE=m`
- LB: `CONFIG_IP_VS=m`
- BPF filesystem: mounted at `/sys/fs/bpf` ✓

Flannel: all requirements met out of the box (vxlan, bridge, nf_conntrack loaded).

### Install missing userspace tools

```sh
sudo xbps-install -y clang llvm21 bpftool
# clang 21.1.7 / llvm-objcopy (LLVM 21) / bpftool v7.3.0
```

### Notes

- iptables is `v1.8.11 (legacy)` — fine for both CNIs; Cilium in full eBPF
  mode bypasses iptables entirely.
- To use Cilium instead of Flannel, k3s must be started with:
  `--flannel-backend=none --disable-network-policy`

---

## Step 7 — OCI Image Build

### Image location

`/home/delphus/projects/void-oci/void-oci-final.qcow2`

### Image details

- Disk: 8GB QCOW2, GPT partition table
  - p1: 256MB FAT32 EFI (`/boot/efi`) UUID `F230-5BE2`
  - p2: 7.8GB ext4 root UUID `3bf150b0-1d2c-4924-a3c7-4df344dcd9a2`
- Base: Void Linux x86_64 glibc rootfs (2025-02-02)
- Kernels: 6.18.35_1 (default) and 6.12.93_1 (LTS, in advanced menu)
- Bootloader: GRUB 2.12 EFI, installed with `--removable`
  - Serial console: `console=ttyS0,115200`
  - cgroup v2: `cgroup_no_v1=all`
  - Predictable interface names disabled: `net.ifnames=0 biosdevname=0`
- Initramfs: built with dracut for both kernels (~52–55MB each)

### Packages installed

| Package | Purpose |
|---|---|
| openssh | SSH server |
| dhcpcd | DHCP client, provides `net` OpenRC virtual |
| grub + grub-x86_64-efi | Bootloader |
| python3 + pip | Runtime for cloud-init |
| cloud-init 26.1 | Provisioning (installed from GitHub source) |
| linux6.12, linux6.18 | Kernels |
| dracut | initramfs generator |

### OpenRC installed

Copied compiled OpenRC binaries from host (`openrc 1afc058+` — our custom build
with `openrc.conf` rename patch):
- Binaries: `/usr/bin/{openrc,openrc-run,rc-service,rc-update,supervise-daemon,...}`
- Libraries: `/usr/lib/{librc.so.1,libeinfo.so.1}`
- Libexec: `/usr/libexec/rc/`

### cloud-init installed (manual, from GitHub source)

cloud-init is not in Void's xbps repos and is not on PyPI (distro-only package).
Its meson build system requires OpenRC's pkg-config files which aren't available.
Manual installation:
1. Copied `cloudinit/` Python package to `/usr/lib/python3.14/site-packages/cloudinit/`
2. Copied `scripts/cloud-init`, `scripts/cloud-id`, `tools/cloud-init-per` to `/usr/bin/`
3. Copied `sysvinit/openrc/*` to `/etc/init.d/`
4. pip-installed Python deps: `Jinja2 oauthlib configobj jsonschema PyYAML requests jsonpatch netifaces2`

Config at `/etc/cloud/cloud.cfg`:
- datasource: Oracle only
- network config: disabled (dhcpcd handles it)
- default user: `void` (wheel, sudoers NOPASSWD)

### OpenRC runlevels in image

| Runlevel | Services |
|---|---|
| boot | `cloud-init-local`, `dhcpcd`, `cloud-init`, `cloud-config`, `cloud-final` |
| default | `sshd` |

OpenRC depend() ordering ensures: `cloud-init-local` → `dhcpcd (net)` → `cloud-init` → `cloud-config` → `cloud-final`

### dhcpcd init script

Written to `/etc/init.d/dhcpcd` (not shipped by Void's dhcpcd package):
```sh
depend() { need localmount; after modules; provide net network-online; }
```
Config at `/etc/dhcpcd.conf`: DHCP on `eth0` (IPv4 only), `net.ifnames=0` renames to eth0.

### Image sealing

- root: password locked (`passwd -l root`)
- void user: created, wheel group, sudoers NOPASSWD, password locked
- SSH: `PasswordAuthentication no`, `PermitRootLogin no`
- machine-id: cleared (cloud-init regenerates)
- SSH host keys: deleted (regenerated on first boot)
- xbps cache: cleared

### Convert for OCI upload

```sh
# Final image: ~1.5GB QCOW2 (compressed from 3.8GB sparse)
# Upload to OCI Object Storage, then use "Import image" from QCOW2
```

### Remaining TODO (OCI)

- [ ] Install k3s binary in image and create OpenRC init script
- [ ] Test image boot in QEMU before uploading to OCI
- [ ] Upload to OCI Object Storage
- [ ] Import as Custom Image in OCI Console (QCOW2 → paravirtualized)

---

## TODO — Migrate network to OpenRC + cloud-init integration (OCI)

### Background

Network is currently set up in `/etc/rc.local` (bridge br0 over eno2, static
IPs, default route, iptables NAT, IPv6 masquerade, WiFi fallback, WireGuard).
This must move to OpenRC for cloud-init to integrate properly on OCI nodes.

### How cloud-init and OpenRC network together

cloud-init ships four ready-made OpenRC init scripts
(`sysvinit/openrc/` in the cloud-init source). The boot chain is:

```
localmount
  └─ cloud-init-local   (before net — writes network config from datasource)
       └─ [net service] (brings interface up using what cloud-init-local wrote)
            └─ cloud-init        (after net — fetches userdata, applies config)
                 └─ cloud-config (modules --mode config)
                      └─ cloud-final (modules --mode final)
                           └─ k3s
```

The pivot is the `net` service. Any OpenRC service that declares
`provide net` in its `depend()` function slots into this chain automatically.

### Plan

**Local machine** — no changes needed. rc.local keeps handling networking.
WireGuard stays in rc.local on both local and OCI.

**OCI image only:**

1. Write `/etc/init.d/net.local` — runs `dhcpcd` on the ethernet interface:
   - `depend()`: `after localmount`, `provide net network-online`
   - `start()`: `dhcpcd -b -q "${iface}"` (auto-detects first non-loopback,
     or override via `/etc/conf.d/net.local`)
   - `stop()`: `dhcpcd -x`
   - OCI uses DHCP for primary NIC. cloud-init-local reads instance metadata
     (hostname, SSH keys, user-data) without writing network config files.
     dhcpcd handles IP acquisition — no cloud-init renderer needed.
2. Install cloud-init (build from source — not in xbps). Its four OpenRC init
   scripts install to `/etc/init.d/` via cloud-init's own meson build.
3. Add `net.local` + cloud-init services to the OCI OpenRC runlevel.
