# 03 -- Fixing SUSE Kernel ABI Mismatches

The SUSE-patched kernel `6.12.0-160000.x-default` has **two** struct size mismatches compared to vanilla Linux 6.12. Both must be fixed in the vanilla kernel source tree before building any out-of-tree modules.

## Fix 1: `struct module` Padding (64 bytes)

### Symptom

```
module rtw_core: .gnu.linkonce.this_module section size must match
the kernel's built struct module size at run time
```

### Root Cause

The SUSE kernel enables `CONFIG_LIVEPATCH_IPA_CLONES=y`, a SUSE-specific config option that adds fields to `struct module`. This option does not exist in the vanilla kernel source.

```bash
# Running SUSE kernel config:
zcat /proc/config.gz | grep LIVEPATCH_IPA
# CONFIG_LIVEPATCH_IPA_CLONES=y    <-- SUSE-specific, not in vanilla

# Size difference:
# Vanilla struct module: 0x540 (1344 bytes)
# SUSE struct module:    0x580 (1408 bytes)
# Difference: 64 bytes (0x40)
```

### The Fix

Edit `include/linux/module.h` in the kernel source tree. Find the `#ifdef CONFIG_LIVEPATCH` section inside `struct module` (around line 558) and add 64 bytes of padding after `klp_info`:

```c
#ifdef CONFIG_LIVEPATCH
    bool klp; /* Is this a livepatch module? */
    bool klp_alive;

    /* ELF information */
    struct klp_modinfo *klp_info;

    /* SUSE compatibility: CONFIG_LIVEPATCH_IPA_CLONES fields */
    void *klp_ipa_clones_padding[8]; /* 64 bytes to match SUSE struct module size */
#endif
```

**Automated:**
```bash
cd /root/wifi-build/linux-6.12
sed -i '/struct klp_modinfo \*klp_info;/a\\n\t/* SUSE compatibility: CONFIG_LIVEPATCH_IPA_CLONES fields */\n\tvoid *klp_ipa_clones_padding[8]; /* 64 bytes to match SUSE struct module size */' \
    include/linux/module.h
```

### Why This Works

The padding fields are placed inside the `CONFIG_LIVEPATCH` block where the SUSE kernel expects its IPA clones fields. The struct layout is deterministic because `__randomize_layout` uses a per-build seed derived from the kernel config -- since we use the same config (from `/proc/config.gz`), the randomization matches.

The padding is zeroed (NULL pointers). The IPA clones feature only activates for livepatch modules, so these fields are never accessed for our WiFi driver.

---

## Fix 2: `struct usb_host_endpoint` Padding (8 bytes)

### Symptom

After loading the USB WiFi driver, the kernel creates the network interface but **USB endpoint parsing is corrupted**. The driver reads wrong endpoint addresses, wrong max packet sizes, and may fail to communicate with the hardware. Symptoms include:

- Firmware upload failures
- `rtw_8821au 3-9:1.0: failed to get tx report from firmware` errors
- Garbled endpoint descriptors in debug output
- Random USB communication errors

### Root Cause

The SUSE 6.12.0-160000.x kernel backported the `eusb2_isoc_ep_comp` descriptor field from a newer kernel. This adds a `struct usb_ss_ep_comp_descriptor` (8 bytes) to `struct usb_host_endpoint`.

The vanilla 6.12 kernel source does NOT have this field. When our module is compiled against vanilla headers, it sees `struct usb_host_endpoint` as **80 bytes**, but the running SUSE kernel uses **88 bytes**. Any code that walks arrays of `usb_host_endpoint` structs (or accesses fields after the missing one) reads from the wrong offsets.

```c
// Vanilla Linux 6.12: struct usb_host_endpoint is 80 bytes
struct usb_host_endpoint {
    struct usb_endpoint_descriptor    desc;         // 7 bytes + padding
    struct usb_ss_ep_comp_descriptor  ss_ep_comp;   // 6 bytes + padding
    // NO eusb2 field
    struct list_head                  urb_list;
    // ...
};

// SUSE 6.12.0-160000.x: struct usb_host_endpoint is 88 bytes
struct usb_host_endpoint {
    struct usb_endpoint_descriptor    desc;
    struct usb_ss_ep_comp_descriptor  ss_ep_comp;
    struct usb_ss_ep_comp_descriptor  eusb2_isoc_ep_comp;  // +8 bytes!
    struct list_head                  urb_list;
    // ...
};
```

### The Fix

Edit `include/linux/usb.h` in the kernel source tree. Find `struct usb_host_endpoint` and add the `eusb2_isoc_ep_comp` field after `ss_ep_comp`:

```c
struct usb_host_endpoint {
    struct usb_endpoint_descriptor      desc;
    struct usb_ss_ep_comp_descriptor    ss_ep_comp;
    struct usb_ss_ep_comp_descriptor    eusb2_isoc_ep_comp; /* SUSE backport */
    struct list_head                    urb_list;
    void                                *hcpriv;
    struct ep_device                    *ep_dev;    /* For sysfs info */
    // ...
};
```

**Automated:**
```bash
cd /root/wifi-build/linux-6.12
sed -i '/struct usb_ss_ep_comp_descriptor\s*ss_ep_comp;/a\\tstruct usb_ss_ep_comp_descriptor\teusb2_isoc_ep_comp; /* SUSE backport compat */' \
    include/linux/usb.h
```

### How to Verify

Compare the struct size in our build against a reference kernel module:

```bash
# Check sizeof(struct usb_host_endpoint) in a SUSE-built module
zstd -d /usr/lib/modules/$(uname -r)/kernel/drivers/usb/core/usbcore.ko.zst -o /tmp/usbcore.ko -f
objdump -t /tmp/usbcore.ko | grep usb_host_endpoint

# The simplest verification: after fixing and rebuilding, the driver should
# correctly read endpoint descriptors when loaded
```

### Why This Is Critical for USB Drivers

The rtw88 USB driver iterates over endpoint arrays returned by the kernel's USB subsystem. Each `usb_host_endpoint` element is 88 bytes in the running kernel. If the driver was compiled thinking each element is 80 bytes, accessing `endpoints[1]` actually reads into the middle of the real `endpoints[1]` struct, getting garbage data for all fields.

This affects any code that does:
```c
struct usb_host_interface *iface = intf->cur_altsetting;
for (i = 0; i < iface->desc.bNumEndpoints; i++) {
    struct usb_endpoint_descriptor *ep = &iface->endpoint[i].desc;
    // ep->bEndpointAddress is WRONG if struct size doesn't match!
}
```

---

## After Both Fixes: Rebuild

After applying both patches, rebuild the module infrastructure:

```bash
cd /root/wifi-build/linux-6.12
make clean
zcat /proc/config.gz > .config
make olddefconfig
make modules_prepare
```

Then proceed to building the driver in [04-rtw88-driver-build.md](04-rtw88-driver-build.md).

## Quick Verification

Check that the `.gnu.linkonce.this_module` section of your built module matches a SUSE reference module:

```bash
# Your module (after building)
objdump -h rtw_core.ko | grep this_module
# Should show 0x580

# SUSE reference
zstd -d /usr/lib/modules/$(uname -r)/kernel/drivers/net/usb/r8152.ko.zst -o /tmp/r8152.ko -f
objdump -h /tmp/r8152.ko | grep this_module
# Should also show 0x580
```
