#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Orange Pi Stand-Alone Wi-Fi AP + ttyd + Samba
#   * Sets up wlan0 @ 192.168.4.1/24
#   * WPA2 SSID/PW   : Oneirodyne / Oneirodyne
#   * DHCP via       : dnsmasq
#   * Web shell      : http://192.168.4.1:7681 (ttyd)
#   * Idempotent: safe to re-run          (2025-05-31)
# ─────────────────────────────────────────────────────────────
set -Eeuo pipefail

die() { echo "❌ $*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Please run with sudo"; }
need_root


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────
write_if_changed() {
  local target="$1" tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if ! cmp -s "$tmp" "$target" 2>/dev/null; then
    echo "📝 Updating $target"
    install -m "${2:-644}" -o root -g root "$tmp" "$target"
  fi
  rm -f "$tmp"
}

enable_service() {
  systemctl daemon-reload
  systemctl enable --now "$1"
}

# ─────────────────────────────────────────────────────────────
# 0) packages
# ─────────────────────────────────────────────────────────────
echo "🔧 Ensuring packages…"
apt-get update -qq
apt-get install -y --no-install-recommends hostapd dnsmasq rfkill iproute2 \
                                          samba ttyd >/dev/null

# ─────────────────────────────────────────────────────────────
# 1) disable NetworkManager (+ RaspAP if present)
# ─────────────────────────────────────────────────────────────
nm_conf=/etc/NetworkManager/NetworkManager.conf
mkdir -p /etc/NetworkManager
write_if_changed "$nm_conf" 644 <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=false

[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
systemctl restart NetworkManager || true

# RaspAP (if bundled) gets masked so it never interferes
if systemctl list-unit-files | grep -q raspapd.service; then
  echo "⛔ Disabling RaspAP"
  systemctl disable --now raspapd.service || true
fi

# ─────────────────────────────────────────────────────────────
# 2) wlan0 static IP (ifupdown fallback)
# ─────────────────────────────────────────────────────────────
write_if_changed /etc/network/interfaces.d/wlan0 644 <<'EOF'
auto wlan0
iface wlan0 inet static
    address 192.168.4.1
    netmask 255.255.255.0
EOF

# ─────────────────────────────────────────────────────────────
# 3) hostapd
# ─────────────────────────────────────────────────────────────
write_if_changed /etc/hostapd/hostapd.conf 600 <<'EOF'
interface=wlan0
driver=nl80211
ssid=Oneirodyne
hw_mode=g
channel=7
wpa=2
wpa_passphrase=Oneirodyne
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

write_if_changed /etc/default/hostapd 644 <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
enable_service hostapd.service

# ─────────────────────────────────────────────────────────────
# 4) dnsmasq (DHCP) with port 53 conflict check
# ─────────────────────────────────────────────────────────────
write_if_changed /etc/dnsmasq.conf 644 <<'EOF'
interface=wlan0
bind-interfaces
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,24h
log-queries
log-dhcp
EOF

# Kill rogue dnsmasq instances (e.g. from RaspAP or NM)
echo "🔍 Checking for existing dnsmasq on port 53…"
if ss -ltnup | grep -q ':53'; then
  echo "⚠️  Port 53 in use — killing rogue dnsmasq (if any)…"
  PIDS=$(ss -ltnup | awk '/:53/ && /dnsmasq/ {print $NF}' | grep -oP 'pid=\K[0-9]+')
  for pid in $PIDS; do
    echo "🔪 Killing dnsmasq PID $pid"
    kill "$pid" || true
  done
  sleep 1
fi
systemctl unmask dnsmasq.service 2>/dev/null || true

enable_service dnsmasq.service

# ─────────────────────────────────────────────────────────────
# 5) ttyd (web terminal)
# ─────────────────────────────────────────────────────────────
ttyd_service=/etc/systemd/system/ttyd.service
write_if_changed "$ttyd_service" 644 <<'EOF'
[Unit]
Description=WebTTY (ttyd)
After=network.target hostapd.service

[Service]
ExecStart=/usr/bin/ttyd -p 7681 -i 0.0.0.0 bash
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
enable_service ttyd.service

# ─────────────────────────────────────────────────────────────
# 6) Write the manual AP-start helper (no boot unit)
# ─────────────────────────────────────────────────────────────
bootstrap="$SCRIPT_DIR/ap_on.sh"
write_if_changed "$bootstrap" 755 <<'EOS'
#!/usr/bin/env bash
set -e
ip addr flush dev wlan0 || true
ip link set wlan0 down || true
systemctl restart hostapd
sleep 4
ip addr add 192.168.4.1/24 dev wlan0 || true
systemctl restart dnsmasq
systemctl restart ttyd.service
systemctl restart smbd nmbd || true
EOS


# ─────────────────────────────────────────────────────────────
# 7) Final tweaks & test hints
# ─────────────────────────────────────────────────────────────
rfkill unblock wifi           # persist unblocked state
echo "✅ Installation/upgrade complete."
echo "→ Run:  sudo $bootstrap"
echo "→ Then connect and visit:  http://192.168.4.1:7681"
