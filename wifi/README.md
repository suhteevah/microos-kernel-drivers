# RTL8821AU WiFi Driver on openSUSE Leap Micro 6.2

Building out-of-tree WiFi drivers on an immutable Linux distribution with a SUSE-patched kernel.

## The Problem

openSUSE Leap Micro 6.2 (and SLE Micro) ships a SUSE-patched kernel `6.12.0-160000.x-default` but **does not include `kernel-default-devel`** in its repositories. This means you cannot build kernel modules the normal way.

The TP-Link Archer T2U PLUS (RTL8821AU chipset, USB ID `2357:0120`) has no in-tree driver on kernel 6.12, requiring an out-of-tree build.

## Solution: lwfinger/rtw88 Backport

The recommended driver is the **lwfinger/rtw88** mac80211 backport from [lwfinger/rtw88](https://github.com/lwfinger/rtw88). This is a backport of the in-kernel driver that was merged into Linux 6.13 mainline.

**Why rtw88 over morrownr/8821au:**
- Standards-compliant (mac80211) with proper Linux WiFi stack integration
- Actively maintained, heading into mainline kernel
- No NAPI symbol mismatch issues
- No `device_links_driver_bound` kernel crash (see [Appendix A](appendix-a-morrownr-driver.md))

## What Makes This Hard

1. **Immutable root filesystem** -- packages install via `transactional-update` into btrfs snapshots, requiring reboots
2. **No kernel-default-devel** -- the Leap Micro 6.2 repos don't ship it for the 6.12.0 kernel
3. **SUSE struct module padding** -- `CONFIG_LIVEPATCH_IPA_CLONES=y` adds 64 bytes to `struct module`, breaking modules built against vanilla source
4. **SUSE struct usb_host_endpoint padding** -- backported `eusb2_isoc_ep_comp` field adds 8 bytes to `struct usb_host_endpoint`, causing USB endpoint parsing corruption
5. **SELinux Enforcing** -- blocks `insmod` from systemd service context at boot time
6. **systemd variable expansion** -- `${var}` in `ExecStart` is expanded by systemd before bash sees it, breaking shell loops
7. **USB enumeration timing** -- USB WiFi adapter may not be ready when services start during boot
8. **Driver warmup delay** -- rtw88 needs ~5 seconds after module loading before wpa_supplicant can reliably scan

## Documentation

| Document | Description |
|----------|-------------|
| [01-environment-setup.md](01-environment-setup.md) | Setting up the build toolchain on Leap Micro |
| [02-kernel-source-preparation.md](02-kernel-source-preparation.md) | Preparing vanilla kernel source for module building |
| [03-suse-abi-fixes.md](03-suse-abi-fixes.md) | Fixing SUSE struct padding mismatches (struct module + struct usb_host_endpoint) |
| [04-rtw88-driver-build.md](04-rtw88-driver-build.md) | Cloning and compiling the lwfinger/rtw88 driver |
| [05-rtw88-driver-patches.md](05-rtw88-driver-patches.md) | Required patches to usb.c and mac.c for SUSE compatibility |
| [06-boot-persistence.md](06-boot-persistence.md) | SELinux, systemd services, and standalone boot scripts |
| [07-wifi-configuration.md](07-wifi-configuration.md) | Configuring WiFi with wpa_supplicant and dhcpcd |
| [08-troubleshooting.md](08-troubleshooting.md) | Common issues and solutions |
| [appendix-a-morrownr-driver.md](appendix-a-morrownr-driver.md) | Archived: morrownr/8821au approach (kernel crashes on 6.12) |

## Hardware

- **WiFi Adapter:** TP-Link Archer T2U PLUS (RTL8821AU)
- **USB ID:** `2357:0120`
- **Driver Source:** https://github.com/lwfinger/rtw88
- **Host OS:** openSUSE Leap Micro 6.2
- **Kernel:** 6.12.0-160000.6-default (SUSE-patched)
- **Build GCC:** 7.5.0 (from Leap 15.6 OSS repo)

## Module Architecture

The lwfinger/rtw88 driver produces 5 kernel modules that must be loaded in order:

```
rtw_core    -- core driver framework
rtw_usb     -- USB transport layer
rtw_88xxa   -- RTL88xx family A common code
rtw_8821a   -- RTL8821A specific code
rtw_8821au  -- RTL8821AU USB binding (loads firmware, creates wlp0s20u9 interface)
```

Plus kernel dependencies `cfg80211` and `mac80211` (loaded via `modprobe`).

## Working Boot Service Chain

```
rtw88-wifi.service    -- waits for USB device, loads all 5 modules
    |
    v
wpa-wifi.service      -- waits for wlXXX interface, 5s warmup, starts wpa_supplicant
    |
    v
dhcpcd-wifi.service   -- waits for WPA COMPLETED state, starts DHCP client
```

All service logic lives in standalone `/usr/local/bin/*.sh` scripts to avoid systemd `${var}` expansion issues.

## Quick Verification

After a successful setup, a clean reboot should show:

```bash
# All services active
systemctl is-active rtw88-wifi wpa-wifi dhcpcd-wifi
# active / active / active

# 8 modules loaded (5 rtw + cfg80211 + mac80211 + rfkill)
lsmod | grep rtw | wc -l
# 5

# WiFi connected
wpa_cli -i wlp0s20u9 status | grep wpa_state
# wpa_state=COMPLETED

# Internet working
ping -c 1 8.8.8.8
# 64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=22.4 ms
```

## License

This guide is released under MIT. The rtw88 driver is GPL-2.0.
