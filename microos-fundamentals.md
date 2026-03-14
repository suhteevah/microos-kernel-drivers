# MicroOS Kernel Module Building Fundamentals

Everything you need to know about building out-of-tree kernel modules on openSUSE Leap Micro 6.2 (and SLE Micro / MicroOS).

This guide covers the **universal concepts** that apply to ANY kernel module, regardless of hardware. The hardware-specific guides ([nvidia/](nvidia/) and [wifi/](wifi/)) build on these fundamentals.

---

## Understanding the Immutable Root

Leap Micro uses a read-only btrfs root with transactional updates. Changes to the system go through `transactional-update`, which:

1. Creates a new btrfs snapshot from the current default
2. Applies changes inside that snapshot (package installs, config changes)
3. Sets the new snapshot as the default boot target
4. Requires a **reboot** to activate

```bash
# Install a package (creates snapshot, requires reboot)
transactional-update -n pkg install gcc make

# Or run arbitrary commands in a writable snapshot
transactional-update run bash -c "echo hello > /etc/myconfig"

# Check pending snapshots
snapper list | tail -10

# Reboot to activate
reboot
```

### The `-n` Flag

`transactional-update -n` means "non-interactive" — it won't prompt for confirmation. Always use this for scripted/remote installs.

---

## The Subvolume Map

This is the most important thing to understand. Leap Micro has **separate btrfs subvolumes** for several directories:

| Path | Subvolume? | Writable? | Visible in snapshots? |
|------|-----------|-----------|----------------------|
| `/` (root) | Root subvol | **Read-only** (live) | Yes |
| `/var/` | Separate | Writable | **No** |
| `/var/tmp/` | Separate | Writable | **No** |
| `/usr/local/` | Separate | Writable | **No** |
| `/opt/` | Separate | Writable | **No** |
| `/root/` | Separate | Writable | **No** |
| `/etc/` | Overlay | Writable | Partially |
| `/home/` | Separate | Writable | **No** |

### What This Means in Practice

1. **Files in `/var/tmp/` are NOT visible** inside `transactional-update run` or `tukit call` chroots. If you download a file to `/var/tmp/` and try to access it inside a snapshot operation, it won't exist.

2. **To get files into a snapshot**, copy them into the snapshot filesystem directly:
   ```bash
   # Get the snapshot number
   tukit open  # Returns snapshot number, e.g., 30

   # Copy files INTO the snapshot
   cp /var/tmp/installer.run /.snapshots/30/snapshot/usr/share/

   # Now it's accessible inside the snapshot
   tukit call 30 ls /usr/share/installer.run
   ```

3. **Packages installing to `/usr/local/`** during `transactional-update` write to `/.snapshots/N/snapshot/usr/local/`, NOT your live `/usr/local/`. After reboot, the snapshot becomes the new root, but `/usr/local/` is still the separate subvolume. You may need to manually copy:
   ```bash
   cp -a /.snapshots/N/snapshot/usr/local/cuda-12.8 /usr/local/
   ```

---

## Getting Kernel Source

The SUSE-patched kernel `6.12.0-160000.x-default` requires matching source to build modules. You have two paths:

### Path A: Leap 16.0 kernel-source Package (Recommended)

Leap Micro 6.2 shares the same kernel as Leap 16.0. The `kernel-source` package is available:

```bash
# Add Leap 16.0 OSS repo
zypper ar -f 'https://download.opensuse.org/distribution/leap/16.0/repo/oss/' repo-leap16-oss

# Install kernel-source (matches running kernel exactly)
transactional-update -n pkg install kernel-source kernel-default-devel
reboot

# Verify
ls /usr/src/linux-$(uname -r | sed 's/-default//')/include/linux/kernel.h
```

This provides a complete SUSE-patched kernel source tree, including all struct modifications and build infrastructure. Use this path when:
- The build system expects standard kernel-source layout (e.g., NVIDIA `.run` installer)
- You want guaranteed ABI compatibility

### Path B: Vanilla Source + ABI Patches

Download vanilla kernel source from kernel.org and patch it to match the SUSE kernel:

```bash
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz
tar xf linux-6.12.tar.xz && cd linux-6.12

# Copy running kernel's config and symbols
cp /usr/lib/modules/$(uname -r)/config .config
zcat /usr/lib/modules/$(uname -r)/symvers.gz > Module.symvers

# Match kernel version string exactly
sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION = -160000.6-default/' Makefile

# Prepare build infrastructure
make olddefconfig
make modules_prepare
```

Then apply the SUSE ABI patches (see next section). Use this path when:
- The Leap 16.0 package isn't available
- You need more control over the source tree
- The module build system uses a simple Makefile with `KSRC=` parameter

---

## SUSE Kernel ABI Patches

The SUSE-patched kernel has struct modifications that don't exist in vanilla source. Building modules without these patches causes crashes, data corruption, or load failures.

### Fix 1: `struct module` — 64 Bytes of Padding

**Symptom**: `module: .gnu.linkonce.this_module section size must match the kernel's built struct module size`

The SUSE kernel enables `CONFIG_LIVEPATCH_IPA_CLONES=y`, which adds fields to `struct module`:

```c
// In include/linux/module.h
// After the line: struct klp_modinfo *klp_info;
// Add:
    /* SUSE compatibility: CONFIG_LIVEPATCH_IPA_CLONES fields */
    void *klp_ipa_clones_padding[8]; /* 64 bytes to match SUSE struct module */
```

### Fix 2: `struct usb_host_endpoint` — 8 Bytes for eUSB2 (USB Drivers Only)

**Symptom**: USB endpoint parsing corruption, garbled descriptors, firmware upload failures

SUSE backported `eusb2_isoc_ep_comp` from a newer kernel:

```c
// In include/linux/usb.h
// After the line: struct usb_ss_ep_comp_descriptor ss_ep_comp;
// Add:
    struct usb_ss_ep_comp_descriptor eusb2_isoc_ep_comp; /* SUSE backport */
```

After both patches:
```bash
make clean && make olddefconfig && make modules_prepare
```

**Note**: If using Path A (kernel-source package), these patches are already applied.

---

## DKMS on MicroOS

DKMS (Dynamic Kernel Module Support) automatically rebuilds kernel modules when the kernel is updated. On MicroOS, it works differently:

### Setup

```bash
transactional-update -n pkg install dkms
reboot
```

### Registration

```bash
# Register module source (must exist at /usr/src/<name>-<version>/)
dkms add -m <name> -v <version>

# Build for current kernel (works on live system)
dkms build -m <name> -v <version> -k $(uname -r)
```

### The `dkms install` Gotcha

On MicroOS, `dkms install` **will fail** on the live system because `/lib/modules/` is read-only. This is expected behavior, not a bug.

DKMS modules get installed automatically during `transactional-update` kernel updates via the kernel-install hook at `/usr/lib/kernel/install.d/40-dkms.install`. Inside a transactional-update snapshot, the root is writable, so `dkms install` succeeds.

### Verify

```bash
dkms status
# nvidia/580.126.09, 6.12.0-160000.6-default, x86_64: built
```

---

## SELinux and Kernel Modules

Leap Micro 6.2 runs SELinux in enforcing mode by default. Out-of-tree kernel modules aren't signed, which affects how they can be loaded.

### The Problem

- Loading modules via SSH (interactive session) works — you're in the `unconfined_t` domain
- Loading modules from systemd services fails — they run in the `init_t` domain, which is restricted

### Solutions

**Option 1: Permissive mode** (simplest)

```bash
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

**Option 2: Targeted SELinux policy** (more secure, more work)

Create a policy module that allows `init_t` to load unsigned kernel modules.

---

## systemd Service Patterns for Module Loading

### The `${var}` Expansion Trap

systemd expands `${var}` in `ExecStart` lines **before** bash processes them, even inside single quotes. This breaks shell loops and variable references.

**Wrong** (systemd eats the variables):
```ini
ExecStart=/bin/bash -c 'for mod in ${MODULES}; do insmod $mod; done'
```

**Right** (move logic to a standalone script):
```ini
ExecStart=/usr/local/bin/load-my-modules.sh
```

```bash
#!/bin/bash
# /usr/local/bin/load-my-modules.sh
MODULES="module1.ko module2.ko module3.ko"
for mod in $MODULES; do
    insmod /path/to/$mod
done
```

### Service Ordering

For hardware that needs multiple steps (load modules → configure → start daemon):

```ini
# load-modules.service
[Unit]
Description=Load kernel modules
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/load-modules.sh

[Install]
WantedBy=multi-user.target
```

```ini
# configure-hardware.service
[Unit]
Description=Configure hardware
After=load-modules.service
Requires=load-modules.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/configure-hardware.sh

[Install]
WantedBy=multi-user.target
```

---

## Snapshot Management Tips

### Checking Snapshot Lineage

```bash
# List all snapshots with details
snapper list

# Check which snapshot is currently booted
cat /etc/snapper/configs/root  # or check grub menu
```

### Avoiding Snapshot Conflicts

`transactional-update` creates new snapshots from the **current default**. If you have multiple pending (unrebooted) snapshots:

- Warning: `"Created from a different base"` — changes in one branch won't appear in the other
- **Best practice**: Reboot between `transactional-update` operations to keep lineage clean

### Accessing Files from Unrebooted Snapshots

Packages installed in snapshot N but not yet rebooted into:

```bash
# Files are at:
ls /.snapshots/N/snapshot/usr/bin/new-binary

# You can copy them to writable paths:
cp /.snapshots/N/snapshot/usr/bin/new-binary /usr/local/bin/

# Or run binaries directly from the snapshot path:
/.snapshots/N/snapshot/usr/bin/new-binary --version
```

### Using tukit for Manual Snapshot Operations

```bash
# Open a new writable snapshot
tukit open
# Returns: New snapshot 42 created

# Run commands inside the snapshot
tukit call 42 bash -c "echo 'hello' > /etc/myconfig"

# Copy files into the snapshot
cp /var/tmp/myfile /.snapshots/42/snapshot/usr/share/

# Close the snapshot (sets it as next boot default)
tukit close 42

# Or abort if something went wrong
tukit abort 42
```

---

## Complete MicroOS Gotchas List

1. **`/var/tmp/` not visible in chroots** — Copy files into `/.snapshots/N/snapshot/usr/share/` instead

2. **`/usr/local/` is a separate subvolume** — Packages installing to `/usr/local/` during `transactional-update` write to the snapshot, not the live filesystem

3. **Snapshot lineage matters** — Reboot between `transactional-update` operations to avoid divergent snapshot branches

4. **`kernel-source` not in Leap Micro repos** — Add the Leap 16.0 OSS repo (same kernel version)

5. **`dkms install` fails on live system** — Expected. DKMS install runs inside writable snapshots during kernel updates via the kernel-install hook

6. **SELinux blocks `insmod` from systemd** — SSH context is `unconfined_t`, systemd services are `init_t`. Use permissive mode or targeted policy

7. **systemd expands `${var}` before bash** — Move all shell logic to standalone scripts in `/usr/local/bin/`

8. **Two GCC versions may be needed** — Default GCC may be too old for C++17 code. Install `gcc13`/`g++-13` alongside the default and specify compilers explicitly

9. **`libelf-devel` version conflicts** — Leap 15.6's `libelf-devel` requires `libelf1 >= 0.185` but Micro ships 0.192; extract headers from RPM manually if needed

10. **Nouveau must be blacklisted for NVIDIA** — The `.run` installer handles this, but if installing manually: `echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf`

---

*This guide is part of the [microos-kernel-drivers](https://github.com/suhteevah/microos-kernel-drivers) project.*
