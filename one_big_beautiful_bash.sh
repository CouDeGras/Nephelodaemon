#!/usr/bin/env bash
#
# One-time installer:  ttyd • FileBrowser • nginx • Wi-Fi-or-AP captive portal
# Run as root:   sudo ./setup_portal.sh [wlan-iface]
# After it finishes →  sudo reboot
#
set -euo pipefail

# ────────────────────────── 0) must be root ──────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "⚠️  Please run this script as root (e.g. with sudo)."
  exit 1
fi

# ----------------------------------------------------------------------
# 1) PARAMETERS  (you may tweak here)
# ----------------------------------------------------------------------
WIFI_IFACE="${1:-wlan0}"

# STA (client) network to try first
SSID_STA="Oneirodyne"
PSK_STA="Oneirodyne"

# AP (fallback) settings
SSID_AP="Thymoeidolon"
CHANNEL=6
STATIC_NET="192.168.50.1/24"
STATIC_IP="${STATIC_NET%%/*}"

# Portal root = folder where *this* script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_DIR="$SCRIPT_DIR"

# ----------------------------------------------------------------------
# 2) helper functions
# ----------------------------------------------------------------------
need_cmd()   { command -v "$1" &>/dev/null; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

echo "🔧  Interface            : $WIFI_IFACE"
echo "📶  STA target SSID      : $SSID_STA"
echo "📡  AP fallback SSID     : $SSID_AP"
echo "🌐  Portal served from   : $PORTAL_DIR"
echo

# ----------------------------------------------------------------------
# 3) base repo & CLI prerequisites
# ----------------------------------------------------------------------
apt-get update -qq
apt_install software-properties-common curl gnupg2 ca-certificates lsb-release ubuntu-keyring build-essential git libmicrohttpd-dev libssl-dev

# enable universe (hostapd/wpacli) + nginx mainline repo
add-apt-repository -y universe
curl -fsSL https://nginx.org/keys/nginx_signing.key \
  | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
  >/etc/apt/sources.list.d/nginx.list
apt-get update -qq

# ----------------------------------------------------------------------
# 4) snapd / ttyd / filebrowser
# ----------------------------------------------------------------------
if ! need_cmd snap; then
  echo "🔧 Installing snapd …";           apt_install snapd
fi
if ! need_cmd ttyd; then
  echo "🔧 Installing ttyd (snap) …";     snap install ttyd --classic
fi
if ! need_cmd filebrowser; then
  echo "🔧 Installing File Browser …";    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# ----------------------------------------------------------------------
# 5) network & web packages
# ----------------------------------------------------------------------
apt_install wpasupplicant hostapd nginx iptables-persistent

# ----------------------------------------------------------------------
# 6) build & install Nodogsplash (captive portal daemon)
# ----------------------------------------------------------------------
echo "🔧 Building Nodogsplash …"
git clone --depth 1 https://github.com/nodogsplash/nodogsplash.git /tmp/nodogsplash
make -C /tmp/nodogsplash
make -C /tmp/nodogsplash install      # → /usr/local/sbin/nodogsplash
rm -rf /tmp/nodogsplash

# ----------------------------------------------------------------------
# 7) nginx site: serve portal dir  (nginx.org uses /etc/nginx/conf.d)
# ----------------------------------------------------------------------
cat >/etc/nginx/conf.d/portal.conf <<EOF
server {
    listen 80;
    server_name _;
    root $PORTAL_DIR;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
nginx -t
systemctl enable --now nginx

# ----------------------------------------------------------------------
# 8) nodogsplash default config (do not start yet)
# ----------------------------------------------------------------------
cat >/etc/nodogsplash/nodogsplash.conf <<EOF
GatewayInterface $WIFI_IFACE
MaxClients 50
ClientTimeout 300
RedirectURL http://$STATIC_IP
EOF

# ----------------------------------------------------------------------
# 9) hostapd config for fallback AP
# ----------------------------------------------------------------------
cat >/etc/hostapd/hostapd.conf <<EOF
interface=$WIFI_IFACE
driver=nl80211
ssid=$SSID_AP
hw_mode=g
channel=$CHANNEL
auth_algs=1
wmm_enabled=0
EOF
sed -i 's|^#DAEMON_CONF.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl disable hostapd

# ----------------------------------------------------------------------
# 10) wpa_supplicant config for STA
# ----------------------------------------------------------------------
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-$WIFI_IFACE.conf"
cat >"$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$SSID_STA"
    psk="$PSK_STA"
    key_mgmt=WPA-PSK
}
EOF
systemctl enable wpa_supplicant@"$WIFI_IFACE"

# ----------------------------------------------------------------------
# 11) systemd units: ttyd & File Browser  (non-root user)
# ----------------------------------------------------------------------
USER_NAME=${SUDO_USER:-$USER}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
TTYD_BIN=$(command -v ttyd)
FB_BIN=$(command -v filebrowser)

cat >/etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd – Terminal over Web (port 7681)
After=network.target
[Service]
User=$USER_NAME
ExecStart=$TTYD_BIN --writable --port 7681 /bin/bash -l
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser ($HOME_DIR on :8080)
After=network.target
[Service]
User=$USER_NAME
WorkingDirectory=$HOME_DIR
ExecStart=$FB_BIN -r $HOME_DIR --address 0.0.0.0 --port 8080 --database $HOME_DIR/.config/filebrowser.db
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------
# 12) fallback logic script (runs every boot)
# ----------------------------------------------------------------------
FALLBACK_SCRIPT=/usr/local/bin/wifi_or_ap.sh
cat >"$FALLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
IFACE="$WIFI_IFACE"
STA_SSID="$SSID_STA"
STATIC_NET="$STATIC_NET"

# Wait up to 60 s for STA
for i in {1..60}; do
  if iw dev \$IFACE link | grep -q "\$STA_SSID"; then
    echo "✅ Joined \$STA_SSID"
    exit 0
  fi
  sleep 1
done

echo "⚠️  Unable to join \$STA_SSID – switching to AP."

# Stop STA
systemctl stop wpa_supplicant@\${IFACE} || true

# Reset interface & assign static IP
ip link set \$IFACE down
ip addr flush dev \$IFACE
ip link set \$IFACE up
ip addr add \$STATIC_NET dev \$IFACE

# Start hostapd + Nodogsplash
systemctl start hostapd
systemctl start nodogsplash
EOF
chmod +x "$FALLBACK_SCRIPT"

# ----------------------------------------------------------------------
# 13) systemd service that calls the fallback script
# ----------------------------------------------------------------------
cat >/etc/systemd/system/fallback-ap.service <<EOF
[Unit]
Description=Fallback to AP if STA fails
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$FALLBACK_SCRIPT
[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------
# 14) iptables DNAT → portal  (persist)
# ----------------------------------------------------------------------
iptables -t nat -A PREROUTING -i "$WIFI_IFACE" -p tcp --dport 80 \
         -j DNAT --to-destination $STATIC_IP:80
iptables -t nat -A POSTROUTING -j MASQUERADE
netfilter-persistent save

# ----------------------------------------------------------------------
# 15) enable / start everything
# ----------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now ttyd.service filebrowser.service fallback-ap.service
echo -e "\n✅  Installation complete.  Reboot now to put it into action:"
echo "   sudo reboot"
