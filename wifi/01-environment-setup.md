# 01 — Build Environment Setup on openSUSE Leap Micro 6.2

## The Challenge

Leap Micro is an **immutable OS** — the root filesystem is read-only. All package installations go through `transactional-update`, which creates a new btrfs snapshot. Each snapshot requires a **reboot** to activate.

The base Leap Micro repos are minimal and don't include a compiler. We need to add the Leap 15.6 OSS repo for gcc/g++.

## Step 1: Add the Leap 15.6 OSS Repository

Leap Micro 6.2's `repo-main` has limited packages. The Leap 15.6 OSS repo has the build toolchain:

```bash
zypper ar -f -c 'https://download.opensuse.org/distribution/leap/15.6/repo/oss/' 'leap-oss'
zypper --gpg-auto-import-keys ref
```

## Step 2: Install Core Build Tools

Each `transactional-update` creates a new btrfs snapshot. Use `--continue` to chain changes into the same snapshot:

```bash
# Snapshot 1: Core toolchain
transactional-update --non-interactive pkg install \
    gcc gcc-c++ make git wget curl unzip tar gzip bzip2 xz htop tmux

# REBOOT to activate snapshot
reboot
```

**Verify after reboot:**
```bash
gcc --version    # Should show gcc 7.5.0
g++ --version    # Should show g++ 7.5.0
make --version   # Should show GNU Make 4.4.1
```

## Step 3: Install Additional Build Dependencies

The kernel module build (`modules_prepare`) requires flex, bison, openssl headers, and libelf:

```bash
# Snapshot 2: flex + bison
transactional-update --non-interactive pkg install flex bison m4
reboot

# Snapshot 3: openssl headers
transactional-update --non-interactive pkg install libopenssl-3-devel zlib-devel
reboot
```

## Step 4: Install libelf-devel (Manual Method)

`libelf-devel` from Leap 15.6 requires `libelf1 >= 0.185`, but Leap Micro ships `libelf1 0.192`. The version strings are incompatible, so zypper refuses the install. Workaround: extract headers from the RPM manually.

```bash
# Download the RPM without installing
cd /tmp
zypper download libelf-devel

# Extract headers from RPM
rpm2cpio /var/cache/zypp/packages/leap-oss/x86_64/libelf-devel-*.rpm | cpio -idmv

# Copy headers to system (via transactional-update shell)
transactional-update shell <<'EOF'
cp /tmp/usr/include/gelf.h /usr/include/
cp /tmp/usr/include/libelf.h /usr/include/
cp /tmp/usr/include/nlist.h /usr/include/
mkdir -p /usr/include/elfutils
cp /tmp/usr/include/elfutils/*.h /usr/include/elfutils/
# Create the linker symlink
ln -sf libelf.so.1 /usr/lib64/libelf.so
EOF
reboot
```

## Final Build Environment

After all snapshots, you should have:

| Tool | Version | Source |
|------|---------|--------|
| gcc | 7.5.0 | Leap 15.6 OSS |
| g++ | 7.5.0 | Leap 15.6 OSS |
| make | 4.4.1 | Leap Micro repo-main |
| git | 2.51.0 | Leap Micro repo-main |
| flex | 2.6.4 | Leap 15.6 OSS |
| bison | 3.0.4 | Leap 15.6 OSS |
| openssl headers | 3.5.0 | Leap Micro repo-main |
| libelf headers | 0.185 (extracted) | Leap 15.6 OSS (manual) |

## Additional Tools for WiFi Stack

If you plan to use `wpa_supplicant` + `dhcpcd` (recommended for boot persistence, see [06-boot-persistence.md](06-boot-persistence.md)):

```bash
transactional-update --non-interactive pkg install wpa_supplicant dhcpcd
reboot
```

## Notes

- Each `transactional-update` + reboot cycle takes ~2-3 minutes
- The total setup requires **4-5 reboots** (depending on how you batch packages)
- All changes persist across reboots in their respective snapshots
- Use `snapper list` to see all snapshots
- Use `snapper rollback N` to rollback to snapshot N if something breaks
- The `/root/` directory is writable and persists across snapshots -- use it for build artifacts
