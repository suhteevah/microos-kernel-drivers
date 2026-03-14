# 07 -- WiFi Configuration with wpa_supplicant and dhcpcd

## Overview

The rtw88 driver creates a mac80211-compliant wireless interface (typically `wlp0s20u9`). For boot persistence, we use `wpa_supplicant` for WPA2 authentication and `dhcpcd` for DHCP -- both managed by systemd services (see [06-boot-persistence.md](06-boot-persistence.md)).

## Prerequisites

- rtw88 modules loaded (all 5 -- check with `lsmod | grep rtw`)
- Wireless interface exists (check with `ip link show | grep wl`)
- `wpa_supplicant` and `dhcpcd` installed

Install if needed:
```bash
transactional-update --non-interactive pkg install wpa_supplicant dhcpcd
reboot
```

## Configure wpa_supplicant

### Create Configuration File

```bash
cat > /etc/wpa_supplicant/wpa_supplicant.conf << 'EOF'
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1

network={
    ssid="YourSSID"
    psk="YourPassword"
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP
    group=CCMP
}
EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
```

### Multiple Networks

You can add multiple `network={}` blocks. wpa_supplicant will connect to the strongest available:

```
network={
    ssid="HomeNetwork"
    psk="password1"
    priority=10
}

network={
    ssid="OfficeNetwork"
    psk="password2"
    priority=5
}
```

Higher `priority` values are preferred.

## Manual Testing

Before relying on boot services, test manually:

```bash
# Find interface name
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
echo "Interface: $WLAN"

# Bring interface up
ip link set $WLAN up

# Start wpa_supplicant
wpa_supplicant -i $WLAN -c /etc/wpa_supplicant/wpa_supplicant.conf -B

# Wait for association
sleep 10
wpa_cli -i $WLAN status

# Request DHCP lease
dhcpcd $WLAN

# Verify
ip addr show $WLAN
ping -c 3 8.8.8.8
```

## wpa_cli Interactive Commands

`wpa_cli` is useful for debugging:

```bash
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)

# Check connection status
wpa_cli -i $WLAN status

# List visible networks
wpa_cli -i $WLAN scan
wpa_cli -i $WLAN scan_results

# Check signal strength
wpa_cli -i $WLAN signal_poll

# Reconnect
wpa_cli -i $WLAN reassociate
```

Key status fields:
- `wpa_state=COMPLETED` -- connected and authenticated
- `wpa_state=SCANNING` -- looking for networks
- `wpa_state=DISCONNECTED` -- not connected
- `ssid=YourSSID` -- connected network name
- `ip_address=10.0.0.x` -- assigned IP (after DHCP)

## Why wpa_supplicant + dhcpcd Instead of NetworkManager?

Leap Micro ships with NetworkManager, but for headless server boot persistence:

1. **Simpler debugging** -- wpa_supplicant logs are straightforward, nmcli adds abstraction
2. **Predictable boot timing** -- systemd service chain gives explicit control over the boot sequence
3. **No D-Bus dependency** -- wpa_supplicant works without a running D-Bus session
4. **Easier to script** -- the standalone boot scripts in [06-boot-persistence.md](06-boot-persistence.md) control the exact timing

NetworkManager can coexist but may conflict if it tries to manage the same interface. If using wpa_supplicant directly, either:
- Disable NetworkManager for the WiFi interface: `nmcli dev set $WLAN managed no`
- Or stop NetworkManager entirely if not needed for other interfaces

## DNS Configuration

dhcpcd should automatically configure `/etc/resolv.conf` with DNS servers from the DHCP lease. If DNS resolution fails but IP connectivity works (`ping 8.8.8.8` works but `ping google.com` fails):

```bash
# Check current resolver config
cat /etc/resolv.conf

# Manual fix
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
```

For a persistent fix, configure dhcpcd to set DNS:
```bash
# In /etc/dhcpcd.conf, ensure these lines exist:
option domain_name_servers
option domain_name
option domain_search
```

## Firewall Considerations

If `firewalld` is running, the WiFi interface should be added to a trusted zone if it's on a private network:

```bash
# Add WiFi interface to trusted zone
WLAN=$(ip link show | grep -oP 'wl\w+' | head -1)
firewall-cmd --zone=trusted --add-interface=$WLAN --permanent
firewall-cmd --reload
```
