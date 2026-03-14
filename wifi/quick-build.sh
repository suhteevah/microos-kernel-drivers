#!/bin/bash
# =============================================================================
# Quick Build Script — RTL8821AU on openSUSE Leap Micro 6.2
#
# Prerequisites: gcc, make, flex, bison, openssl-devel, libelf headers
# See 01-environment-setup.md for installing these.
#
# Run as root on the Leap Micro machine.
# =============================================================================
set -e

WORKDIR=/root/wifi-build
KVER=$(uname -r)

echo "=== RTL8821AU WiFi Driver Build ==="
echo "Kernel: ${KVER}"
echo "Working directory: ${WORKDIR}"
echo ""

# Step 1: Create working directory
mkdir -p ${WORKDIR}
cd ${WORKDIR}

# Step 2: Download vanilla kernel source (if not already present)
if [ ! -d linux-6.12 ]; then
    echo ">>> Downloading Linux 6.12 source..."
    wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz
    echo ">>> Extracting..."
    tar xf linux-6.12.tar.xz
fi

# Step 3: Prepare kernel source
cd linux-6.12

echo ">>> Copying running kernel config..."
zcat /proc/config.gz > .config

echo ">>> Copying Module.symvers..."
zcat /usr/lib/modules/${KVER}/symvers.gz > Module.symvers

echo ">>> Setting EXTRAVERSION..."
EXTRA=$(echo ${KVER} | sed 's/^[0-9]*\.[0-9]*\.[0-9]*//')
sed -i "s/^EXTRAVERSION =.*/EXTRAVERSION = ${EXTRA}/" Makefile

echo ">>> Patching struct module for SUSE compatibility..."
# Add 64 bytes of padding to match SUSE's CONFIG_LIVEPATCH_IPA_CLONES
if ! grep -q 'klp_ipa_clones_padding' include/linux/module.h; then
    sed -i '/struct klp_modinfo \*klp_info;/a\\n\t/* SUSE compatibility: CONFIG_LIVEPATCH_IPA_CLONES fields */\n\tvoid *klp_ipa_clones_padding[8]; /* 64 bytes to match SUSE struct module size */' \
        include/linux/module.h
    echo "    Patch applied."
else
    echo "    Already patched."
fi

echo ">>> Running olddefconfig..."
make olddefconfig 2>&1 | tail -3

echo ">>> Building module infrastructure..."
make modules_prepare 2>&1 | tail -5

# Step 4: Clone and build driver
cd ${WORKDIR}
if [ ! -d 8821au-20210708 ]; then
    echo ">>> Cloning driver source..."
    git clone https://github.com/morrownr/8821au-20210708.git
fi

cd 8821au-20210708

echo ">>> Disabling NAPI (SUSE kernel incompatibility)..."
sed -i 's/CONFIG_RTW_NAPI = y/CONFIG_RTW_NAPI = n/' Makefile
sed -i 's/CONFIG_RTW_GRO = y/CONFIG_RTW_GRO = n/' Makefile

echo ">>> Building driver..."
make clean 2>/dev/null || true
make ARCH=x86_64 KSRC="${WORKDIR}/linux-6.12" 2>&1 | tail -10

# Step 5: Verify
if [ -f 8821au.ko ]; then
    echo ""
    echo "=== BUILD SUCCESSFUL ==="
    ls -lh 8821au.ko
    echo ""

    # Check struct size
    OUR_SIZE=$(objdump -h 8821au.ko | grep this_module | awk '{print $3}')
    echo "struct module size: 0x${OUR_SIZE}"

    # Compare with reference
    if [ -f /usr/lib/modules/${KVER}/kernel/drivers/net/usb/r8152.ko.zst ]; then
        zstd -d /usr/lib/modules/${KVER}/kernel/drivers/net/usb/r8152.ko.zst -o /tmp/r8152.ko -f 2>/dev/null
        REF_SIZE=$(objdump -h /tmp/r8152.ko | grep this_module | awk '{print $3}')
        echo "Reference size:     0x${REF_SIZE}"
        if [ "${OUR_SIZE}" = "${REF_SIZE}" ]; then
            echo "SIZE MATCH: Module is compatible with running kernel!"
        else
            echo "WARNING: Size mismatch! Module may not load."
        fi
    fi

    echo ""
    echo "To load (test):"
    echo "  modprobe cfg80211"
    echo "  insmod ${WORKDIR}/8821au-20210708/8821au.ko"
    echo ""
    echo "To install permanently:"
    echo "  transactional-update shell"
    echo "  cp ${WORKDIR}/8821au-20210708/8821au.ko /usr/lib/modules/${KVER}/updates/"
    echo "  echo '8821au' > /etc/modules-load.d/8821au.conf"
    echo "  depmod -a"
    echo "  exit"
    echo "  reboot"
else
    echo ""
    echo "=== BUILD FAILED ==="
    echo "Check the output above for errors."
    exit 1
fi
