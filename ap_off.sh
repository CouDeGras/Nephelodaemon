#!/usr/bin/env bash
# ap_off.sh ─ Switch Orange Pi from AP → client mode
#   • Stops AP + services
#   • Masks dnsmasq so NM uses its own DNS
#   • Restores NetworkManager control of wlan0
#   • Reloads Wi-Fi driver once to guarantee STA scan
#   • Idempotent, lean

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "⚠️  Run as root (sudo)."; exit 1; }

NM_CONF=/etc/NetworkManager/NetworkManager.conf
SERVICES=(hostapd ttyd smbd nmbd filebrowser nginx)

echo "⛔  Stopping hotspot & auxiliary services…"
for svc in "${SERVICES[@]}"; do
  systemctl stop "${svc}.service" 2>/dev/null || true
done

echo "🚫  Masking dnsmasq to free port 53…"
systemctl stop dnsmasq.service  || true
systemctl disable dnsmasq.service || true
systemctl mask dnsmasq.service    || true

echo "📴  Resetting wlan0…"
ip addr flush dev wlan0 2>/dev/null || true
ip link set  wlan0 down            2>/dev/null || true

echo "🛠  Re-enabling NetworkManager control…"
# Comment unmanaged line if present
sed -i 's/^unmanaged-devices=interface-name:wlan0/#&/' "$NM_CONF" 2>/dev/null || true
# Ensure [ifupdown] managed=true
if grep -q '^\[ifupdown\]' "$NM_CONF"; then
  sed -i '/^\[ifupdown\]/,/^\[/{s/^managed=.*/managed=true/}' "$NM_CONF"
else
  printf '\n[ifupdown]\nmanaged=true\n' >> "$NM_CONF"
fi

nmcli dev set wlan0 managed yes 2>/dev/null || true
systemctl restart NetworkManager
nmcli radio wifi on 2>/dev/null || true

echo "🔁  Reloading Wi-Fi driver for clean STA scan…"
if [[ -e /sys/class/net/wlan0 ]]; then
  DRIVER=$(basename "$(readlink -f /sys/class/net/wlan0/device/driver/module)")
  modprobe -r "$DRIVER" || true
  sleep 1
  modprobe   "$DRIVER"
fi

# 1) Kill anything that keeps wlan0 in AP mode
pkill hostapd          # ignore errors if nothing running

# 2) Flip the interface type from AP → managed
ip link set wlan0 down
iw dev wlan0 set type managed
ip link set wlan0 up

# 3) Hand it to NetworkManager and unblock radio
nmcli dev set wlan0 managed yes
rfkill unblock wifi

echo "🔍  Scanning…"
nmcli dev wifi rescan
nmcli dev wifi list || true

echo "✅  wlan0 back under NetworkManager."
echo "    Connect with:"
echo "      nmcli dev wifi connect \"<SSID>\" password \"<PASS>\""
