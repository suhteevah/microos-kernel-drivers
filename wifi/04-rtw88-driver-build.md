# 04 -- Building the lwfinger/rtw88 Driver

## Prerequisites

- Build environment set up per [01-environment-setup.md](01-environment-setup.md)
- Kernel source prepared per [02-kernel-source-preparation.md](02-kernel-source-preparation.md)
- Both SUSE ABI fixes applied per [03-suse-abi-fixes.md](03-suse-abi-fixes.md)
- `modules_prepare` completed on the patched kernel source

## Clone the Driver Source

```bash
cd /root/wifi-build
git clone https://github.com/lwfinger/rtw88.git
cd rtw88
```

## Build the Driver

```bash
make KSRC="/root/wifi-build/linux-6.12"
```

The `KSRC=` parameter tells the Makefile where the kernel source tree is, since the standard `/lib/modules/$(uname -r)/build` symlink doesn't exist on Leap Micro.

**Expected output (last lines):**
```
  LD [M]  /root/wifi-build/rtw88/rtw_8821au.ko
  LD [M]  /root/wifi-build/rtw88/rtw_8821a.ko
  ...
```

## Verify the Build

The build produces multiple `.ko` files. The five needed for RTL8821AU:

```bash
ls -la rtw_core.ko rtw_usb.ko rtw_88xxa.ko rtw_8821a.ko rtw_8821au.ko
```

| Module | Size (approx) | Purpose |
|--------|--------------|---------|
| `rtw_core.ko` | ~750 KB | Core driver framework |
| `rtw_usb.ko` | ~85 KB | USB transport layer |
| `rtw_88xxa.ko` | ~180 KB | RTL88xx family A common code |
| `rtw_8821a.ko` | ~55 KB | RTL8821A specific code |
| `rtw_8821au.ko` | ~12 KB | RTL8821AU USB device binding |

Check the struct module section size:
```bash
objdump -h rtw_core.ko | grep this_module
# Should show 00000580 (matching SUSE kernel's struct module)
```

## Apply Driver Patches (Required)

Before the driver will work correctly, you must apply patches to fix USB endpoint parsing and power-on sequencing. See [05-rtw88-driver-patches.md](05-rtw88-driver-patches.md).

After patching, rebuild:
```bash
make clean
make KSRC="/root/wifi-build/linux-6.12"
```

## Test the Modules

Load modules in dependency order:

```bash
# Load kernel wireless stack prerequisites
modprobe cfg80211
modprobe mac80211

# Load rtw88 modules in order
cd /root/wifi-build/rtw88
insmod ./rtw_core.ko
insmod ./rtw_usb.ko
insmod ./rtw_88xxa.ko
insmod ./rtw_8821a.ko
insmod ./rtw_8821au.ko
```

Verify:
```bash
# Check modules loaded
lsmod | grep rtw
# Should show 5 rtw modules

# Check for WiFi interface
ip link show | grep wl
# Should show wlp0s20u9 or similar

# Check dmesg for successful init
dmesg | grep -i 'rtw\|firmware\|wlan' | tail -10
# Should show firmware loading and interface creation
```

## Unloading (Reverse Order)

```bash
rmmod rtw_8821au
rmmod rtw_8821a
rmmod rtw_88xxa
rmmod rtw_usb
rmmod rtw_core
```

## What Can Go Wrong

| Error | Cause | Fix |
|-------|-------|-----|
| `.gnu.linkonce.this_module section size must match` | struct module padding not applied | See [03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 1 |
| `insmod: ERROR: could not insert module: Permission denied` | SELinux enforcing (boot context) | See [06-boot-persistence.md](06-boot-persistence.md) |
| `Unknown symbol cfg80211_*` | cfg80211 not loaded | Run `modprobe cfg80211` first |
| `Unknown symbol mac80211_*` | mac80211 not loaded | Run `modprobe mac80211` first |
| `failed to get tx report from firmware` | USB endpoint struct mismatch | See [03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 2 |
| `insmod: ERROR: could not insert module: Unknown symbol` | Dependency not loaded | Load modules in exact order shown above |
| USB device not detected | Adapter not plugged in or powered | Check `lsusb | grep 2357` |

## Note on Other RTL88xx Chipsets

The lwfinger/rtw88 build also produces modules for other chipsets (RTL8822B, RTL8822C, RTL8723D, etc.). Only the five modules listed above are needed for the RTL8821AU. The same SUSE ABI fixes apply to all of them.
