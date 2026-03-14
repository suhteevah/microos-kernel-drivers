# 02 — Kernel Source Preparation

## Why Vanilla Kernel Source?

Leap Micro 6.2 runs kernel `6.12.0-160000.x-default`, but **kernel-default-devel is not available** in any public repo for this kernel version. The SUSE/SLFO (SUSE Linux Framework One) kernel-default-devel package is only available through SUSE Customer Center (SCC), which requires a paid subscription.

Instead, we download the vanilla Linux 6.12 kernel source from kernel.org and adapt it to match the running SUSE kernel's configuration.

## Step 1: Create Working Directory

```bash
mkdir -p /root/wifi-build
cd /root/wifi-build
```

> **Important:** Use `/root/wifi-build/` instead of `/tmp/`. The `/tmp/` directory is cleared on reboot, which is frequent on Leap Micro due to transactional-update snapshot activations.

## Step 2: Download Vanilla Kernel Source

```bash
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz
tar xf linux-6.12.tar.xz
cd linux-6.12
```

## Step 3: Copy Running Kernel Configuration

The running kernel's config and Module.symvers are available at:

```bash
# Copy the running kernel's config
cp /usr/lib/modules/$(uname -r)/config .config

# Or from /proc/config.gz (same content)
# zcat /proc/config.gz > .config

# Copy Module.symvers (needed for symbol resolution during modpost)
zcat /usr/lib/modules/$(uname -r)/symvers.gz > Module.symvers
```

## Step 4: Update Config for Vanilla Source

```bash
# Accept defaults for any new config options
make olddefconfig
```

This will set any options present in the SUSE config but missing from vanilla 6.12 to their defaults. Some SUSE-specific options (like `CONFIG_LIVEPATCH_IPA_CLONES`) will be silently dropped since the vanilla source doesn't have them.

## Step 5: Set EXTRAVERSION

Match the running kernel's version string:

```bash
# Check running kernel version
uname -r
# Output: 6.12.0-160000.5-default

# Set EXTRAVERSION in Makefile
sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION = -160000.5-default/' Makefile
```

## Step 6: Prepare Module Build Infrastructure

```bash
make modules_prepare
```

This builds essential tools:
- `scripts/sign-file` (module signing)
- `scripts/mod/modpost` (module post-processing)
- `tools/objtool/objtool` (object validation)
- `include/generated/autoconf.h` (config defines)
- `include/config/auto.conf` (config state)

Expected output (last lines):
```
  CC      scripts/mod/modpost.o
  LD      scripts/mod/modpost
  CC      tools/objtool/objtool.o
  LINK    tools/objtool/objtool
  LDS     scripts/module.lds
```

## Important Notes

- The `/lib/modules/` directory is a symlink to `/usr/lib/modules/` on Leap Micro
- The root filesystem is read-only, so you can't create `build` or `source` symlinks in `/lib/modules/`. Instead, use the `KSRC=` parameter when building drivers.
- The vanilla 6.12 source won't have SUSE-specific struct definitions. This causes **two** ABI mismatches that must be fixed before modules will load correctly. See [03-suse-abi-fixes.md](03-suse-abi-fixes.md).
