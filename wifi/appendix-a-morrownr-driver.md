# Appendix A -- morrownr/8821au Driver (Archived)

> **Status: NOT RECOMMENDED for kernel 6.12+**
>
> This driver causes a kernel crash (`device_links_driver_bound` NULL pointer dereference) on SUSE kernel 6.12.0-160000.x. Use the lwfinger/rtw88 driver instead (see main guide).

## Overview

The [morrownr/8821au-20210708](https://github.com/morrownr/8821au-20210708) driver is a widely-used out-of-tree driver for RTL8821AU chipsets. It produces a single `8821au.ko` module.

## Build Process

```bash
cd /root/wifi-build
git clone https://github.com/morrownr/8821au-20210708.git
cd 8821au-20210708

# Disable NAPI (SUSE exports _locked variants of NAPI functions)
sed -i 's/CONFIG_RTW_NAPI = y/CONFIG_RTW_NAPI = n/' Makefile
sed -i 's/CONFIG_RTW_GRO = y/CONFIG_RTW_GRO = n/' Makefile

# Build against patched kernel source (with struct module padding)
make clean
make ARCH=x86_64 KSRC="/root/wifi-build/linux-6.12"
```

## SUSE-Specific Issues

### NAPI Symbol Mismatch

The SUSE kernel exports `_locked` variants of NAPI functions:

| Vanilla Symbol | SUSE Symbol |
|---------------|-------------|
| `netif_napi_add_weight` | `netif_napi_add_weight_locked` |
| `__netif_napi_del` | `__netif_napi_del_locked` |

**Fix:** Disable NAPI in the driver Makefile (see above). This is not needed for USB WiFi adapters where NAPI provides negligible benefit.

### struct module Size Mismatch

Same as the rtw88 driver -- requires the 64-byte padding fix in `include/linux/module.h`. See [03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 1.

## The Fatal Crash

After the module loads and appears in `lsmod`, the driver's `probe()` function binds to the USB device. This triggers a kernel crash:

```
BUG: unable to handle page fault for address: 000000000001448a
RIP: 0010:device_links_driver_bound+0x163/0x2d0

Call Trace:
 driver_bound+0x76/0xe0
 bus_probe_device+0x9a/0xb0
 device_driver_attach+0xb2/0xd0
 ...
 usb_probe_interface+0x10e/0x2d0
```

### Analysis

- The faulting address `0x1448a` is NOT zero -- it's a misaligned offset deep in a structure
- The crash is in `device_links_driver_bound()`, which walks `dev->links.consumers` and `dev->links.suppliers` list_heads
- The morrownr driver creates a `struct device` with fields incompatible with kernel 6.12's device link management
- **This crash kills sshd** and makes the server unreachable. A physical reboot is required.

### What Was Tried

1. Loading module without USB adapter plugged in, then hot-plugging -- same crash on bind
2. Disabling USB autosuspend -- no effect
3. Different Makefile options -- no effect
4. The crash is in core kernel code, not in the driver itself, suggesting a fundamental ABI incompatibility

### Conclusion

The morrownr driver has not been updated for kernel 6.12's device link management changes. Since the in-kernel rtw88 driver (backported via lwfinger/rtw88) works correctly and is heading into mainline, there is no reason to continue debugging the morrownr driver.

## Why This Is Documented

This appendix exists because:
1. The morrownr driver is the most commonly recommended RTL8821AU driver in online guides
2. It **does compile** successfully, giving a false sense of progress
3. The crash is not obvious from the build -- it only manifests when the driver tries to bind to hardware
4. The crash is catastrophic (kills sshd, requires physical reboot) making remote debugging impossible
5. Future users searching for "RTL8821AU openSUSE Leap Micro" should know to skip this driver
