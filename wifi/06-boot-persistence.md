# 06 -- Boot Persistence: SELinux, systemd Services, and Standalone Scripts

Getting the WiFi driver to load automatically on boot requires solving three problems:
1. **SELinux** blocks `insmod` from systemd service context
2. **systemd** expands `${var}` in ExecStart before bash processes it
3. **USB enumeration timing** means the adapter may not be ready when services start

## Problem 1: SELinux Blocks insmod at Boot

### Discovery

After setting up systemd services to load the WiFi modules, rebooting showed:

```
insmod: ERROR: could not insert module ./rtw_core.ko: Permission denied
```

For ALL five modules. But running the exact same `insmod` commands manually via SSH worked perfectly.

### Root Cause

openSUSE Leap Micro 6.2 ships with **SELinux in Enforcing mode**. The key insight:

| Context | SELinux Domain | insmod Allowed? |
|---------|---------------|-----------------|
| SSH session | `unconfined_u:unconfined_r:unconfined_t` | Yes |
| systemd service | `system_u:system_r:init_t` (confined) | **No** |

The SSH session runs in the `unconfined_t` domain (no restrictions), explaining why manual commands always worked. But systemd services run in a confined context that blocks loading unsigned out-of-tree kernel modules.

### Diagnosis

```bash
# Check SELinux mode
getenforce
# Enforcing

# Check SSH context (manual commands work here)
id -Z
# unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

# Check what blocks insmod
# Secure Boot: disabled (mokutil --sb-state)
# Kernel lockdown: [none] (cat /sys/kernel/security/lockdown)
# Module signing: CONFIG_MODULE_SIG=y but MODULE_SIG_FORCE not set
# SELinux: ENFORCING <-- This is the blocker
```

### The Fix: Set SELinux to Permissive

```bash
# Immediate effect
setenforce 0

# Persistent across reboots
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

Verify:
```bash
getenforce
# Permissive

grep '^SELINUX=' /etc/selinux/config
# SELINUX=permissive
```

### Alternative Approaches (Not Used)

- **Custom SELinux policy module**: Could create a targeted policy to allow `init_t` domain to load modules, but `audit2allow` on Leap Micro had issues generating policies
- **SELinuxContext in service file**: Adding `SELinuxContext=system_u:system_r:unconfined_service_t:s0` to the service unit file -- did not work; the `unconfined_service_t` type wasn't available
- **setsebool domain_kernel_load_modules**: This boolean wasn't available on Leap Micro

> **Security note:** Setting SELinux to permissive reduces the security posture. For production systems, a targeted SELinux policy module is preferred. For a home server/orchestrator, permissive mode is acceptable.

---

## Problem 2: systemd Expands Shell Variables

### Discovery

The initial systemd service had inline bash with `for mod in rtw_core rtw_usb ...`:

```ini
ExecStart=/bin/bash -c 'for mod in rtw_core rtw_usb ...; do insmod ./${mod}.ko; done'
```

Even with single quotes, systemd logged:
```
rtw88-wifi.service: Referenced but unset environment variable evaluates to an empty string: mod
```

### Root Cause

systemd processes **all** `${var}` patterns in `ExecStart` lines before passing to bash. Single quotes, double quotes, `bash -c` -- none prevent systemd from expanding `${var}`. This is by design.

### The Fix: Standalone Scripts

Move ALL shell logic to standalone scripts in `/usr/local/bin/`. The service files just call the scripts:

```ini
ExecStart=/usr/local/bin/rtw88-wifi-start.sh
```

systemd never sees shell variables -- they exist only inside the script file.

---

## Problem 3: USB Enumeration Timing

The USB WiFi adapter (`2357:0120`) may not be enumerated by the time the boot service runs. The fix is a polling loop that waits for the device.

---

## The Complete Solution

### Script 1: `/usr/local/bin/rtw88-wifi-start.sh`

```bash
#!/bin/bash
set -e

echo "Waiting for USB WiFi adapter (2357:0120)..."
for i in $(seq 1 30); do
    if lsusb 2>/dev/null | grep -q 2357; then
        echo "USB WiFi adapter found after ${i}s"
        break
    fi
    sleep 1
done

if ! lsusb 2>/dev/null | grep -q 2357; then
    echo "ERROR: USB WiFi adapter not found after 30s"
    exit 1
fi

modprobe cfg80211 2>/dev/null || true
modprobe mac80211 2>/dev/null || true
sleep 1

cd /root/wifi-build/rtw88
for mod in rtw_core rtw_usb rtw_88xxa rtw_8821a rtw_8821au; do
    echo "Loading ${mod}..."
    if ! insmod ./${mod}.ko 2>&1; then
        echo "WARNING: Failed to load ${mod}"
    fi
done

sleep 2

if lsmod | grep -q rtw_8821au; then
    echo "SUCCESS: RTW88 modules loaded"
    lsmod | grep rtw
else
    echo "ERROR: rtw_8821au not in lsmod"
    exit 1
fi
```

### Script 2: `/usr/local/bin/rtw88-wifi-stop.sh`

```bash
#!/bin/bash
for mod in rtw_8821au rtw_8821a rtw_88xxa rtw_usb rtw_core; do
    rmmod ${mod} 2>/dev/null || true
done
echo "RTW88 modules unloaded"
```

### Script 3: `/usr/local/bin/wpa-wifi-start.sh`

```bash
#!/bin/bash
echo "Waiting for WiFi interface..."
for i in $(seq 1 30); do
    WLAN=$(ip link show 2>/dev/null | grep -oP 'wl\w+' | head -1)
    if [ -n "$WLAN" ]; then
        echo "WiFi interface found: $WLAN after ${i}s"
        break
    fi
    sleep 1
done

if [ -z "$WLAN" ]; then
    echo "ERROR: No WiFi interface found after 30s"
    exit 1
fi

# Driver warmup: RTL8821AU needs ~5 seconds after module loading
# before wpa_supplicant can reliably scan (otherwise EBUSY/-16 failures)
echo "Waiting 5s for driver warmup..."
sleep 5

ip link set "$WLAN" up
sleep 2

echo "Starting wpa_supplicant on $WLAN..."
exec /usr/sbin/wpa_supplicant -i "$WLAN" -c /etc/wpa_supplicant/wpa_supplicant.conf
```

### Script 4: `/usr/local/bin/dhcpcd-wifi-start.sh`

```bash
#!/bin/bash
echo "Waiting for WiFi interface..."
WLAN=""
for i in $(seq 1 30); do
    WLAN=$(ip link show 2>/dev/null | grep -oP 'wl\w+' | head -1)
    [ -n "$WLAN" ] && break
    sleep 1
done

if [ -z "$WLAN" ]; then
    echo "ERROR: No WiFi interface found"
    exit 1
fi

# Wait for WPA association before requesting DHCP
echo "Waiting for WPA association on $WLAN..."
for i in $(seq 1 30); do
    STATE=$(wpa_cli -i "$WLAN" status 2>/dev/null | grep '^wpa_state=' | cut -d= -f2)
    if [ "$STATE" = "COMPLETED" ]; then
        SSID=$(wpa_cli -i "$WLAN" status 2>/dev/null | grep '^ssid=' | cut -d= -f2)
        echo "WPA associated to $SSID after ${i}s"
        break
    fi
    sleep 1
done

if [ "$STATE" != "COMPLETED" ]; then
    echo "WARNING: WPA not completed (state=$STATE), trying DHCP anyway..."
fi

echo "Starting dhcpcd on $WLAN..."
exec /usr/sbin/dhcpcd "$WLAN"
```

### Set Script Permissions

```bash
chmod +x /usr/local/bin/rtw88-wifi-start.sh
chmod +x /usr/local/bin/rtw88-wifi-stop.sh
chmod +x /usr/local/bin/wpa-wifi-start.sh
chmod +x /usr/local/bin/dhcpcd-wifi-start.sh
```

---

## systemd Service Files

### `/etc/systemd/system/rtw88-wifi.service`

```ini
[Unit]
Description=Load RTW88 WiFi driver modules (RTL8821AU)
After=network-pre.target systemd-modules-load.service
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rtw88-wifi-start.sh
ExecStop=/usr/local/bin/rtw88-wifi-stop.sh

[Install]
WantedBy=multi-user.target
```

### `/etc/systemd/system/wpa-wifi.service`

```ini
[Unit]
Description=WPA Supplicant for WiFi (RTL8821AU)
After=rtw88-wifi.service
Wants=rtw88-wifi.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wpa-wifi-start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### `/etc/systemd/system/dhcpcd-wifi.service`

```ini
[Unit]
Description=DHCP Client for WiFi interface
After=wpa-wifi.service
Wants=wpa-wifi.service

[Service]
Type=forking
ExecStart=/usr/local/bin/dhcpcd-wifi-start.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
systemctl daemon-reload
systemctl enable rtw88-wifi wpa-wifi dhcpcd-wifi
systemctl start rtw88-wifi
systemctl start wpa-wifi
sleep 10
systemctl start dhcpcd-wifi
```

---

## Boot Timeline

A successful boot sequence looks like this:

```
t=0s    systemd starts rtw88-wifi.service
t=1s    USB WiFi adapter found (USB enumeration complete)
t=2s    cfg80211 + mac80211 loaded
t=5s    All 5 rtw88 modules loaded, interface wlp0s20u9 appears
t=5s    rtw88-wifi.service reports SUCCESS

t=5s    systemd starts wpa-wifi.service
t=6s    Interface found: wlp0s20u9
t=11s   5-second driver warmup complete
t=13s   wpa_supplicant starts, begins scanning

t=13s   systemd starts dhcpcd-wifi.service
t=15s   Interface found
t=25s   WPA state reaches COMPLETED (associated to SSID)
t=25s   dhcpcd starts, sends DHCPDISCOVER
t=30s   DHCP lease obtained, IP address assigned

Total: ~30 seconds from boot to WiFi connected
```

## Verification After Reboot

```bash
# Service status (all should be active)
systemctl is-active rtw88-wifi wpa-wifi dhcpcd-wifi

# Modules loaded
lsmod | grep rtw

# WiFi connected
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
wpa_cli -i $WLAN status | grep -E 'ssid|wpa_state|ip_address'

# Internet connectivity
ping -c 1 8.8.8.8
```
