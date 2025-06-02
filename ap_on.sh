#!/usr/bin/env bash
# ap_on.sh ─ Switch Orange Pi into hotspot mode
#   • Removes wlan0 from NetworkManager
#   • Unmasks/starts dnsmasq, restarts hostapd + extras
#   • Idempotent

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "⚠️  Run with sudo/root"; exit 1; }

AP_IP="192.168.4.1/24"
NM_CONF=/etc/NetworkManager/NetworkManager.conf
SLEEP=4
SERVICES=(ttyd smbd nmbd filebrowser nginx)

echo "⛔  Detaching wlan0 from NetworkManager…"

# 1) Make NM ignore wlan0 persistently
grep -q '^unmanaged-devices=interface-name:wlan0' "$NM_CONF" || \
  printf '\n[keyfile]\nunmanaged-devices=interface-name:wlan0\n' >> "$NM_CONF"

# 2) Ensure [ifupdown] managed=false (opposite of client mode)
if grep -q '^\[ifupdown\]' "$NM_CONF"; then
  sed -i '/^\[ifupdown\]/,/^\[/{s/^managed=.*/managed=false/}' "$NM_CONF"
else
  printf '\n[ifupdown]\nmanaged=false\n' >> "$NM_CONF"
fi

nmcli dev set wlan0 managed no 2>/dev/null || true
systemctl restart NetworkManager
sleep 2

echo "🔄 Resetting wlan0 interface…"
ip addr flush dev wlan0 2>/dev/null || true
ip link set  wlan0 down            2>/dev/null || true

echo "🚀 (Re)starting hostapd…"
systemctl restart hostapd
sleep "$SLEEP"

echo "📡 Assigning static IP $AP_IP"
ip addr add "$AP_IP" dev wlan0 2>/dev/null || true

echo "🔧 Unmask + restart dnsmasq…"
systemctl unmask   dnsmasq.service   2>/dev/null || true
systemctl enable   dnsmasq.service   2>/dev/null || true
systemctl restart  dnsmasq.service

echo "🔄 Restarting extra services…"
for svc in "${SERVICES[@]}"; do
  systemctl restart "$svc" 2>/dev/null || true
done

echo "✅ Hotspot is live → http://192.168.4.1"
