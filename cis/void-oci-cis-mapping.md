# CIS Control Mapping for Void OCI Image
## Baseline: CIS Ubuntu 24.04 LTS Level 1 Server → Void Linux OCI (oracle, x86_64/arm64)

---

## How to use this document
| Symbol | Meaning |
|---|---|
| `[APPLIES]` | Control is relevant to this image; list the Void-specific check or remediation |
| `[N/A]` | Not applicable to this image/Architecture |
| `[CUSTOM]` | Image already implements a stronger/different default |
| `[VOID-GAP]` | Applicable, but not automatically satisfied; action needed |

For every `[APPLIES]` / `[VOID-GAP]`, the recommended audit is:
```sh
# inside image chroot or on a running VM
oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis_level1_server \
  --results /tmp/cis-results.xml \
  --report /tmp/cis-report.html \
  <datastream>
```
Or run the manual check/command listed inline.

---

## 1. Filesystem Configuration
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 1.1 | Disable unused filesystems | `[APPLIES]` | CIS checks `/tmp`, `/dev/shm`, `/home`, `/var`, `/var/tmp` mount options. Image uses standard ext4 (no separate /tmp). Verify that GRUB `fstab` has no bindings to tmpfs. `/tmp` is not nodev/noexec/nosuid. |
| 1.2 | Ensure /tmp is on separate partition | `[N/A]` | 8G disk image; single ext4 root partition. |
| 1.3 | Ensure /dev/shm configured | `[APPLIES]` | `mount | grep shm` → should NOT be mounted since no tmpfs. If it is, enforce `nodev,noexec,nosuid`. |
| 1.4 | Set sticky bit on /tmp | `[APPLIES]` | `stat -c %a /tmp` → should be `1777`. |
| 1.5 | Disable mounting of rare filesystems | `[APPLIES]` | `cramfs`, `freevxfs`, `hfs`, `hfsplus`, `jffs2`. Void kernel likely has modules; blacklist them in `/etc/modprobe.d/`. |

**Manual check 1.x:**
```sh
mount | grep -E "tmpfs|devtmpfs"
find /lib/modules/$(uname -r)/kernel/fs -name "*.ko*" | grep -E "cramfs|hfs|jffs2"
```

---

## 2. Software Updates
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 2.1 | Periodic package updates | `[APPLIES]` | No auto-updater by default. Void convention: `xbps-install -Syu` manually or via cron. Add a cron job or ensure an image-pipeline updates the base image. No `/etc/apt/autoremove` equivalent. |

**Manual check:**
```sh
xbps-query -C /etc/xbps.d -S
xbps-query -L | wc -l  # count held packages
```

---

## 3. Filesystem Integrity Checking (AIDE)
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 3.1 | Install AIDE | `[VOID-GAP]` | `xbps-install aide` (not in image by default). Initialize DB: `aideinit`, move `/var/lib/aide/aide.db.new` to `aide.db`. |
| 3.2 | Periodic AIDE check | `[VOID-GAP]` | Add OpenRC script `/etc/init.d/aide` or cron. |

---

## 4. Secure Boot Settings
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 4.1 | Set GRUB password | `[CUSTOM]` | `files/grub` sets serial console for OCI, but no GRUB superuser password. **Add GRUB password** for local console attacks. |
| 4.2 | Require authentication for single-user mode | `[APPLIES]` | Void OpenRC does not ship `sulogin` with password requirement by default. Add `--force` to `sulogin` in `files/init.d/`. |
| 4.3 | Disable interactive boot | `[APPLIES]` | Run `rc-update del bootmisc default` or set quiet kernel cmdline. |

---

## 5. Process Hardening
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 5.1 | Restrict core dumps | `[APPLIES]` | `/proc/sys/fs/suid_dumpable = 0` and `* hard core 0` in `/etc/security/limits.conf` (or equivalent pam_limits). |
| 5.2 | Enable randomized VA space | `[APPLIES]` | `kernel.randomize_va_space = 2` (Void kernel already defaults to this; verify in `/etc/sysctl.d/`). |
| 5.3 | Enable Yama ptrace_scope | `[APPLIES]` | `kernel.yama.ptrace_scope = 1` or `2`. |
| 5.4 | sysctl: enforce cgroup_no_v1=all | `[CUSTOM]` | **Already baked into dracut initramfs** by `build.sh`. ✓ |

---

## 6. Mandatory Access Control (SELinux/AppArmor) — SKIPPED
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| All MAC controls | SELinux/AppArmor | `[N/A]` | Void has no SELinux policy and no AppArmor. Not applicable. |

**Note:** Void hardening relies on mount namespaces + sysctl + OpenRC confinement, not MAC.

---

## 7. Boot Services (OpenRC mappings)
| # | Ubuntu service | Void equivalent | Status |
|---|---|---|---|
| 7.1 | rsyslog | `rsyslogd` (sysinit/boot) | `[APPLIES]` |
| 7.2 | chrony | `chronyd` (boot runlevel) | `[APPLIES]` |
| 7.3 | ssh | `sshd` (boot) | `[APPLIES]` |
| 7.4 | cloud-init | `cloud-init-local`, `cloud-init`, `cloud-config`, `cloud-final` | `[APPLIES]` |
| 7.5 | auditd | Not installed | `[VOID-GAP]` |
| 7.6 | systemd-journald | N/A | `[N/A]` |
| 7.7 | cron | `crond` via `cronie` (not installed by default) | `[VOID-GAP]` |

**Manual check:**
```sh
rc-status
rc-update show
```

---

## 8. Network Configuration and Firewalls
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 8.1 | Single firewall active | `[VOID-GAP]` | Image has **no firewall** by default. Add `iptables`/`nftables` rules or install `firewalld` (but firewalld not in Void repos easily). |
| 8.2 | Default iptables INPUT policy DROP | `[VOID-GAP]` | Add rule chain during `build.sh` or via cloud-init runcmd. |
| 8.3 | Loopback rules | `[APPLIES]` | `iptables -A INPUT -i lo -j ACCEPT` and `-A INPUT ! -i lo -j DROP` as standard. |
| 8.4 | Disable IPv6 (optional) | `[VOID-GAP]` | OCI typically uses IPv4 for metadata; disable via sysctl if desired. |

---

## 9. Logging and Auditing
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 9.1 | rsyslog installed | `[CUSTOM]` | **Already installed and enabled** by `build.sh`. |
| 9.2 | Log files owned by root | `[APPLIES]` | `rsyslog.conf` uses default permissions; verify in `/var/log/` after boot. |
| 9.3 | Auditd installed+active | `[VOID-GAP]` | Install via Void repo (`xbps-install audit`). Configure `/etc/audit/auditd.conf`, then add OpenRC init script. |
| 9.4 | Log rotation | `[CUSTOM]` | **Already installed** `logrotate` package. |

---

## 10. Access, Authentication and Authorization
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 10.1 | Password hashing SHA-512 | `[CUSTOM]` | **Already using** `openssl passwd -6` for shadow hash in `build.sh`. |
| 10.2 | No empty passwords | `[APPLIES]` | Void sets default passwords; `grep ':$' /etc/shadow` should return nothing. |
| 10.3 | Shadow passwords enabled | `[APPLIES]` | Ensure `PASS_ALWAYS_WARN` pam_unix.so not disabled. |
| 10.4 | SSH protocol 2 only | `[APPLIES]` | `/etc/ssh/sshd_config` has `Protocol 2` by default in OpenSSH ≥7. |
| 10.5 | SSH root login disabled | `[CUSTOM]` | `build.sh` does NOT disable `PermitRootLogin`. **Add** `PermitRootLogin no` to `sshd_config.d/`. |
| 10.6 | SSH password auth | `[CUSTOM]` | **Enabled** via `00-void-oci.conf` drop-in. **Re-evaluate if you want passwordless OCI-ssh only.** |
| 10.7 | SSH ciphers/MACs/Kex | `[APPLIES]` | Add recommended `Ciphers`, `MACs`, `KexAlgorithms` to `sshd_config.d/00-void-oci.conf`. |
| 10.8 | Limit password reuse | `[APPLIES]` | PAM: add `pam_unix.so remember=5` to `/etc/pam.d/login` and sshd PAM config. |
| 10.9 | Password expiration | `[APPLIES]` | `chage -M 90 -m 7 void`, set defaults in `/etc/login.defs`. |
| 10.10 | Lock accounts after N failed logins | `[APPLIES]` | PAM `pam_faillock.so` needs to be configured. Void ships `libpam` with faillock support. |
| 10.11 | Sudo timeout / use_pty | `[APPLIES]` | Edit `/etc/sudoers`: `Defaults !authenticate`, `Defaults timestamp_timeout=0`, `Defaults use_pty`. **NOTE:** `files/sudoers-void` currently sets ALL=NOPASSWD — remove if security required. |
| 10.12 | Unique UIDs/GIDs | `[APPLIES]` | `pwck` and `grpck`. |
| 10.13 | Set umask | `[APPLIES]` | Add `umask 027` to `/etc/profile` and `/etc/bashrc`. |

---

## 11. SSH Configuration
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 11.1 | SSH WarningBanner | `[APPLIES]` | Add `Banner /etc/issue.net` to sshd config. |
| 11.2 | SSH ClientAlive / LoginGraceTime | `[APPLIES]` | `ClientAliveInterval 300`, `ClientAliveCountMax 3`, `LoginGraceTime 30`. |
| 11.3 | SSH PermitUserEnvironment | `[APPLIES]` | `PermitUserEnvironment no`. |
| 11.4 | SSH StrictModes | `[APPLIES]` | `StrictModes yes` (default). |
| 11.5 | SSH AuthorizedKeysFile | `[APPLIES]` | Ensure `.ssh` dirs have proper perms. |
| 11.6 | SSH subsystem sftp internal-sftp | `[APPLIES]` | `Subsystem sftp internal-sftp`. |

---

## 12. User Accounts and Environment
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 12.1 | Default umask for all users | `[APPLIES]` | Set `umask 027` in `/etc/profile`, `/etc/bashrc`, `/etc/csh.cshrc`. |
| 12.2 | TMOUT for idle sessions | `[APPLIES]` | Add `TMOUT=600` to `/etc/profile`. |
| 12.3 | Disable `.forward` files | `[APPLIES]` | Add `ForwardPath=/dev/null` in `/etc/aliases` or remove `forward` capability. |
| 12.4 | Restrict `at` / `cron` | `[APPLIES]` | Create `/etc/cron.allow` and `/etc/at.allow` with allowed users only. |

---

## 13. Logging and Auditing (cont.)
Most `notapplicable` because paths like `/var/log/auth.log`, `/var/log/syslog`, `/var/log/cloud-init.log` are Ubuntu-specific.
- Void rsyslog writes to `/var/log/messages`, `/var/log/secure` (or `/var/log/auth.log` depending on template).
- **Action:** Verify actual logfile paths in `/etc/rsyslog.conf` and `/etc/logrotate.d/`.

---

## 14. System Maintenance (Ubuntu-specific)
- `dpkg` checks, `apt`, Ubuntu release files, AppArmor, Cloud-init runcmd stage.
- **All skippable on Void.**

---

## 15. CIS-Ubuntu customizations
| Control | Status | Void/OCI Note |
|---|---|---|
| `sshd_config.d` permissions | `[CUSTOM]` | Image writes `00-void-oci.conf` as mode 600 ✓. Verify in build. |
| `oracle-cloud-agent` socket | `[CUSTOM]` | Added `oracle-cloud-agent` system group in image — already addressed. |
| `mount-shared` (rshared /) | `[CUSTOM]` | **Already in sysinit** by `build.sh`. ✓ |

---

## 16. Kernel Parameters — sysctl
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 16.1 | ASLR | `[CUSTOM]` | Already on by default on Void kernel. Verify: `cat /proc/sys/kernel/randomize_va_space` = `2`. |
| 16.2 | Restrict ptrace | `[APPLIES]` | `kernel.yama.ptrace_scope = 2` for stricter; image currently does NOT set this. |
| 16.3 | Execute-protected /dev/shm | `[APPLIES]` | `vm.mmap_min_addr = 65536` (good default, unlikely changed). |
| 16.4 | TCP SYN cookies | `[APPLIES]` | `net.ipv4.tcp_syncookies = 1`. |
| 16.5 | Ignore broadcast pings | `[APPLIES]` | `net.ipv4.icmp_echo_ignore_broadcasts = 1`. |
| 16.6 | Disable source routing | `[APPLIES]` | `net.ipv4.conf.all.accept_source_route = 0`. |
| 16.7 | Disable IP forwarding | `[APPLIES]` | `net.ipv4.ip_forward = 0` unless routing (OCI VM should not forward). |
| 16.8 | Disable ICMP redirects | `[APPLIES]` | `net.ipv4.conf.all.accept_redirects = 0`. |
| 16.9 | Disable secure ICMP redirects | `[APPLIES]` | `net.ipv4.conf.all.secure_redirects = 0`. |
| 16.10 | Log martians | `[APPLIES]` | `net.ipv4.conf.all.log_martians = 1`. |
| 16.11 | Ignore ICMP redirects | `[APPLIES]` | `net.ipv4.conf.all.send_redirects = 0` and `.default.send_redirects = 0`. |
| 16.12 | Reverse path filtering | `[APPLIES]` | `net.ipv4.conf.all.rp_filter = 1`. |
| 16.13 | Disable IPv6 if not used | `[VOID-GAP]` | If IPv6 is unnecessary on OCI. |
| 16.14 | Disable IPv6 DAD / accept_ra | `[APPLIES]` | `net.ipv6.conf.all.accept_ra = 0` etc. if IPv6 is disabled. |

---

## 17. CIS-Ubuntu added services (most skippable on Void)
| Control | Status | Void/OCI Note |
|---|---|---|
| apt, dpkg, apparmor | `[N/A]` | Not applicable to Void. |
| ufw / firewalld | `[VOID-GAP]` | Image has no default firewall. **Critical gap** for OCI security groups. |

---

## 18. CIS-Ubuntu added package rules (selected applicable)
| Control | Status | Void/OCI Note |
|---|---|---|
| audit package | `[VOID-GAP]` | `xbps-install audit`, configure `/etc/audit/auditd.conf`, `/etc/audit/rules.d/*`. |
| tcpd / libwrap | `[N/A]` | Deprecated; not in Void. |
| aide | `[VOID-GAP]` | `xbps-install aide`. |
| rsyslog filecreatemode | `[APPLIES]` | `/etc/rsyslog.conf` default is usually `0640` or `0600`. Verify. |
| chronyd run as dedicated user | `[VOID-GAP]` | Void chronyd defaults: check `man chronyd` for `-x` option. Usually runs as root on minimal configs. |

---

## 19. SUID/SGID executables
| # | Control | Status | Void/OCI Note |
|---|---|---|---|
| 19.1 | Minimize SUID/SGID | `[APPLIES]` | `dfind -g+s -perm -2000 /` and `-perm-4000`. Verify no unnecessary suids. |
| 19.2 | Set nosuid on /home, /dev/shm, /tmp | `[APPLIES]` | Check via mount options. |

---

## Proposal: Prioritized remediation for this image
1. **Add firewall baseline** (`nftables` or `iptables`) to image — OCI VCN security groups complement but don’t replace host-based policy
2. **Disable PermitRootLogin** in `files/sshd_config` → add `PermitRootLogin no`
3. **Set sysctls** in `/etc/sysctl.d/99-void-oci.conf` with hardened defaults (list in §16 above)
4. **Restrict SSH ciphers/MACs/Kex** in `files/sshd_config` and remove any defaults
5. **Add GRUB password** to `files/grub` with `GRUB_CMDLINE_LINUX` superuser config
6. **Add aide** and cron job; initialize with `/var/lib/aide/aide.db.new`
7. **Set restrictive umask** for all users in `/etc/profile`
8. **Remove NOPASSWD from sudoers** if password auth is required
9. **Add `/etc/cron.allow` and `/etc/at.allow`** with allowed users only
10. **Set TMOUT=600** for idle session timeout

---

## Proposed artifacts to create in repo
- `cis/void-oci-mapping.md` ← this doc
- `cis/99-void-oci.conf` → hardened sysctls to drop into image
- `cis/sshd-hardened.conf` → drop-in for sshd
- `files/sysctl.d/99-void-oci.conf` → integrated into image
- Optional xbps template: `srcpkgs/audit/` for auditd (if desired)

