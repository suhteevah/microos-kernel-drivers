# 08 -- Troubleshooting Guide

## Build Errors

### "flex: not found" during modules_prepare

```bash
transactional-update --non-interactive pkg install flex bison m4
reboot
```

### "gelf.h: No such file or directory"

See the libelf-devel manual extraction in [01-environment-setup.md](01-environment-setup.md).

### "cannot find -lelf"

```bash
transactional-update shell
ln -sf libelf.so.1 /usr/lib64/libelf.so
exit
reboot
```

### `/lib/modules/` is read-only

Leap Micro's immutable root filesystem. Use `KSRC=` when building:
```bash
make ARCH=x86_64 KSRC="/root/wifi-build/linux-6.12"
```

---

## Module Loading Errors

### ".gnu.linkonce.this_module section size must match"

**Cause:** The compiled module's `struct module` size doesn't match the running SUSE kernel.

**Fix:** Apply the 64-byte struct module padding patch. See [03-suse-abi-fixes.md](03-suse-abi-fixes.md) Fix 1.

### "insmod: ERROR: could not insert module: Permission denied"

**Cause:** SELinux in Enforcing mode blocking insmod from a systemd service context.

**Diagnosis:**
```bash
# Verify SELinux is the issue
getenforce
# If "Enforcing", that's the problem

# Confirm manual insmod works (SSH is unconfined)
cd /root/wifi-build/rtw88
insmod ./rtw_core.ko   # Works via SSH
rmmod rtw_core
```

**Fix:**
```bash
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

See [06-boot-persistence.md](06-boot-persistence.md) for full details.

### "Unknown symbol cfg80211_*" or "Unknown symbol mac80211_*"

**Cause:** Wireless subsystem not loaded.

**Fix:**
```bash
modprobe cfg80211
modprobe mac80211
# Then retry insmod
```

### "Unknown symbol in module" (generic)

**Cause:** rtw88 modules must be loaded in dependency order.

**Fix:** Load in this exact order:
```bash
insmod ./rtw_core.ko
insmod ./rtw_usb.ko
insmod ./rtw_88xxa.ko
insmod ./rtw_8821a.ko
insmod ./rtw_8821au.ko
```

---

## WiFi Connection Issues

### No wireless interface after modules load

1. Check USB adapter: `lsusb | grep 2357`
2. Check dmesg: `dmesg | grep -i 'rtw\|firmware\|wlan'`
3. Check if interface has different name: `ip link show` (look for `wlp*` or `wlan*`)
4. Check firmware: The rtw88 driver loads firmware from `/lib/firmware/rtw88/`. If firmware files are missing, the interface won't be created.

### "CTRL-EVENT-SCAN-FAILED ret=-16"

**Cause:** wpa_supplicant started too soon after module loading. The driver needs ~5 seconds to initialize before scanning.

**Symptom in journalctl:**
```
wlp0s20u9: CTRL-EVENT-SCAN-FAILED ret=-16 retry=1
wlp0s20u9: SME: Authentication request to the driver failed
```

**Fix:** Add a 5-second warmup delay before starting wpa_supplicant. This is already built into the boot scripts in [06-boot-persistence.md](06-boot-persistence.md).

### WiFi connects but no IP address

**Diagnosis:**
```bash
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
wpa_cli -i $WLAN status   # Should show wpa_state=COMPLETED
ip addr show $WLAN         # Check for inet address
```

**Causes:**
- dhcpcd not running: `systemctl status dhcpcd-wifi`
- dhcpcd started before WPA association completed: restart `dhcpcd-wifi`
- DHCP server not responding: check router

### WiFi has IP but DNS fails

**Symptom:** `ping 8.8.8.8` works but `ping google.com` fails.

**Fix:**
```bash
# Quick fix
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Check if dhcpcd is supposed to set DNS
grep 'domain_name_servers' /etc/dhcpcd.conf
```

### WiFi disconnects frequently

Check signal strength:
```bash
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
wpa_cli -i $WLAN signal_poll
```

If signal is weak, try:
- Moving the USB adapter to a USB extension cable for better antenna positioning
- Disabling USB autosuspend: `echo -1 > /sys/module/usbcore/parameters/autosuspend`

---

## systemd Service Issues

### "Referenced but unset environment variable evaluates to an empty string: mod"

**Cause:** systemd expands `${mod}` in `ExecStart` before bash sees it, even inside single-quoted `bash -c '...'` strings.

**Fix:** Move all shell logic to standalone scripts. See [06-boot-persistence.md](06-boot-persistence.md).

### Service stuck in "activating" state

**Diagnosis:**
```bash
systemctl status rtw88-wifi    # Check which step is stuck
journalctl -u rtw88-wifi -n 50 # Check service logs
```

**Common causes:**
- USB adapter not plugged in (30s timeout in start script)
- SELinux blocking insmod (service fails but may restart)
- Modules already loaded from a previous attempt

**Fix:**
```bash
# Reset everything
systemctl stop dhcpcd-wifi wpa-wifi rtw88-wifi
for mod in rtw_8821au rtw_8821a rtw_88xxa rtw_usb rtw_core; do
    rmmod $mod 2>/dev/null
done
systemctl reset-failed rtw88-wifi wpa-wifi dhcpcd-wifi
systemctl start rtw88-wifi
```

### Services start but WiFi not working after reboot

Check the boot log:
```bash
journalctl -b -u rtw88-wifi -u wpa-wifi -u dhcpcd-wifi --no-pager
```

Look for:
- "USB WiFi adapter not found after 30s" -- USB enumeration timing issue, increase wait
- "Permission denied" -- SELinux still enforcing
- "No WiFi interface found" -- modules failed to load

---

## Kernel Crash (morrownr/8821au driver only)

### BUG: unable to handle page fault for address: 000000000001448a

This crash occurs with the **morrownr/8821au** driver (NOT rtw88). The faulting address is a misaligned offset in `device_links_driver_bound()`, triggered by the driver's `probe()` function creating a `struct device` with incompatible fields for kernel 6.12.

**This crash kills sshd and requires a physical reboot.**

**Solution:** Use the lwfinger/rtw88 driver instead. See [appendix-a-morrownr-driver.md](appendix-a-morrownr-driver.md).

---

## Useful Diagnostic Commands

```bash
# System
uname -r                          # Kernel version
getenforce                        # SELinux mode
cat /sys/kernel/security/lockdown # Kernel lockdown state

# Modules
lsmod | grep rtw                  # rtw88 modules
lsmod | grep cfg80211             # Wireless subsystem
modinfo rtw_core.ko               # Module info

# USB
lsusb | grep 2357                 # WiFi adapter detection
lsusb -v -d 2357:0120 2>/dev/null # Detailed USB info

# Wireless
ip link show                      # All interfaces
iw dev                            # Wireless devices
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
wpa_cli -i $WLAN status           # WPA status
wpa_cli -i $WLAN scan_results     # Visible networks
wpa_cli -i $WLAN signal_poll      # Signal strength

# Network
ip addr show $WLAN                # IP address
ip route                          # Routing table
cat /etc/resolv.conf              # DNS config
ping -c 1 8.8.8.8                 # Internet connectivity

# Services
systemctl status rtw88-wifi wpa-wifi dhcpcd-wifi
journalctl -u rtw88-wifi -n 30 --no-pager
journalctl -u wpa-wifi -n 30 --no-pager
journalctl -u dhcpcd-wifi -n 30 --no-pager

# SELinux
getenforce
id -Z                             # Current SELinux context
cat /etc/selinux/config           # Persistent config

# dmesg
dmesg | grep -i 'rtw\|firmware\|wlan\|selinux\|denied'
```
