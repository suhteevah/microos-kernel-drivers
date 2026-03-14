# 05 -- Required Driver Patches for SUSE Compatibility

The lwfinger/rtw88 driver needs patches to work correctly on SUSE kernel 6.12. These address issues caused by the `struct usb_host_endpoint` size mismatch (see [03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 2), missing kernel API functions, and USB timing.

## Patch 1: USB Endpoint Parsing Fix (`usb.c`)

### The Problem

The driver's `rtw_usb_parse()` function iterates over USB endpoint descriptors to find bulk IN, bulk OUT, and interrupt endpoints. When `struct usb_host_endpoint` is 88 bytes (SUSE) but the driver was compiled expecting 80 bytes (vanilla), the endpoint iteration reads corrupted data.

Even after applying the kernel header fix (adding `eusb2_isoc_ep_comp` to `usb.h`), the driver source code in `usb.c` has hardcoded logic that may incorrectly match endpoints. The fix ensures the endpoint matching conditions are strict.

### The Fix

In `usb.c`, find the `rtw_usb_parse()` function. The endpoint matching loop needs to use strict equality checks and handle the endpoint descriptor values correctly.

The key change is in the endpoint detection conditions. The original code uses loose matching that can pick up garbage values from the struct offset mismatch. The fix tightens the conditions:

```c
// In rtw_usb_parse(), for each endpoint:
// BEFORE (loose matching, vulnerable to struct offset corruption):
if (usb_endpoint_dir_in(ep_desc) && usb_endpoint_xfer_bulk(ep_desc))
    // ...bulk IN...
if (usb_endpoint_dir_out(ep_desc) && usb_endpoint_xfer_bulk(ep_desc))
    // ...bulk OUT...
if (usb_endpoint_dir_in(ep_desc) && usb_endpoint_xfer_int(ep_desc))
    // ...interrupt IN...

// AFTER (strict matching with address validation):
if (usb_endpoint_dir_in(ep_desc) &&
    usb_endpoint_xfer_bulk(ep_desc) &&
    (ep_desc->bEndpointAddress & USB_ENDPOINT_NUMBER_MASK) != 0)
    // ...bulk IN...
if (usb_endpoint_dir_out(ep_desc) &&
    usb_endpoint_xfer_bulk(ep_desc) &&
    (ep_desc->bEndpointAddress & USB_ENDPOINT_NUMBER_MASK) != 0)
    // ...bulk OUT...
if (usb_endpoint_dir_in(ep_desc) &&
    usb_endpoint_xfer_int(ep_desc) &&
    (ep_desc->bEndpointAddress & USB_ENDPOINT_NUMBER_MASK) != 0)
    // ...interrupt IN...
```

The additional `bEndpointAddress` check filters out zeroed-out endpoint descriptors that result from struct alignment reads landing on padding bytes.

### Rebuild After Patching

```bash
cd /root/wifi-build/rtw88
make clean
make KSRC="/root/wifi-build/linux-6.12"
```

---

## Patch 2: `devm_kmemdup_array` Backport (`main.c`)

### The Problem

The lwfinger/rtw88 source uses `devm_kmemdup_array()`, a helper function introduced in kernel 6.13. On kernel 6.12, this function doesn't exist and the build fails:

```
error: implicit declaration of function 'devm_kmemdup_array'
```

### The Fix

Replace `devm_kmemdup_array(dev, src, count, size, flags)` with `devm_kmemdup(dev, src, count * size, flags)` -- manually multiplying the count and element size into a single length argument.

In `main.c`, find the `rtw_sband_dup()` function (around line 1769):

```c
// BEFORE (kernel 6.13+ API):
dup->channels = devm_kmemdup_array(rtwdev->dev, sband->channels,
                                    sband->n_channels,
                                    sizeof(*sband->channels),
                                    GFP_KERNEL);

dup->bitrates = devm_kmemdup_array(rtwdev->dev, sband->bitrates,
                                    sband->n_bitrates,
                                    sizeof(*sband->bitrates),
                                    GFP_KERNEL);

// AFTER (kernel 6.12 compatible):
dup->channels = devm_kmemdup(rtwdev->dev, sband->channels,
                              sband->n_channels * sizeof(*sband->channels),
                              GFP_KERNEL);

dup->bitrates = devm_kmemdup(rtwdev->dev, sband->bitrates,
                              sband->n_bitrates * sizeof(*sband->bitrates),
                              GFP_KERNEL);
```

**Automated:**
```bash
cd /root/wifi-build/rtw88
sed -i 's/devm_kmemdup_array(\([^,]*\), \([^,]*\),\s*\([^,]*\),\s*\([^,]*\),/devm_kmemdup(\1, \2, \3 * \4,/g' main.c
```

> **Note:** An alternative is to add a compat macro at the top of `main.c`:
> ```c
> #ifndef devm_kmemdup_array
> #define devm_kmemdup_array(dev, src, cnt, sz, gfp) \
>     devm_kmemdup(dev, src, (cnt) * (sz), gfp)
> #endif
> ```

---

## Patch 3: Power-On Sequence Fix (`mac.c`)

### The Problem

The RTL8821AU requires a specific power-on sequence during initialization. The `rtw_mac_power_on()` function in `mac.c` may fail during boot when the USB device has just been enumerated and internal registers are not yet stable.

The symptom is a failure during firmware upload:
```
rtw_8821au 3-9:1.0: failed to get tx report from firmware
rtw_8821au 3-9:1.0: firmware download failed: -110
```

### The Fix

In `mac.c`, the `rtw_mac_power_on()` function has polling loops that wait for hardware registers to reach expected values. The fix increases the retry counts and adds small delays between polls to give the hardware time to stabilize after USB enumeration:

Key areas to check:
1. **Power state polling** -- increase timeout from the default to allow for USB initialization delay
2. **Firmware download retry** -- add retry logic around the firmware transfer sequence
3. **Register read validation** -- ensure register reads return sensible values before proceeding

The specific changes depend on the version of lwfinger/rtw88 you cloned. Check for `rtw_mac_power_on` and ensure any tight polling loops have adequate timeouts.

---

## Patch Summary

| Patch | File | Issue | Fix |
|-------|------|-------|-----|
| 1 | `usb.c` | Endpoint parsing reads corrupted data from struct offset mismatch | Strict endpoint validation with address mask checks |
| 2 | `main.c` | `devm_kmemdup_array` doesn't exist in kernel 6.12 | Replace with `devm_kmemdup` using manual `count * size` |
| 3 | `mac.c` | Power-on polling too aggressive for USB boot timing | Increased timeouts and retry delays |

## Verification

After patching and rebuilding, test:

```bash
# Unload any existing modules
for mod in rtw_8821au rtw_8821a rtw_88xxa rtw_usb rtw_core; do
    rmmod $mod 2>/dev/null
done

# Reload
modprobe cfg80211
modprobe mac80211
cd /root/wifi-build/rtw88
insmod ./rtw_core.ko
insmod ./rtw_usb.ko
insmod ./rtw_88xxa.ko
insmod ./rtw_8821a.ko
insmod ./rtw_8821au.ko

# Check dmesg for clean initialization
dmesg | tail -20
# Should show firmware load success and interface creation
# Should NOT show "failed to get tx report" or endpoint errors

# Verify interface exists
ip link show | grep wl
```

## Note

If you applied the `struct usb_host_endpoint` fix in the kernel headers ([03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 2), the `usb.c` patch may be less critical since the struct sizes now match. However, it's still recommended as a defense-in-depth measure against any residual alignment issues.
