#!/usr/bin/env bash
#
# Fully-idempotent media-server bootstrapper
#   – ttyd (snap)
#   – File Browser
#   – NGINX from official repo
#   – Samba shares for $HOME and DCIM
#
# Run once with sudo on Ubuntu **or Linux Mint**.

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO – exiting.";' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ───────────────────────────────────
# 0) pre-flight checks
# ───────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "⚠️  please run with sudo."; exit 1; }

# shellcheck disable=SC1091
. /etc/os-release
case $ID in
  ubuntu|linuxmint) : ;;
  *) echo "⚠️  Supported on Ubuntu only."; exit 1 ;;
esac

# Underlying Ubuntu codename (works for Mint too)
CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
[[ -z $CODENAME ]] && CODENAME=$(lsb_release -cs)

# Ensure /snap/bin is discoverable for command -v
export PATH="$PATH:/snap/bin"

# ───────────────────────────────────
# 1) resolve real non-root user + impersonate them
# ───────────────────────────────────
USER_NAME=${SUDO_USER:-$USER}                     # who invoked sudo
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

# Make all child-processes think they’re that user
export HOME="$USER_HOME"
export USER="$USER_NAME"

BASE_DIR="$USER_HOME/DCIM"

# Create DCIM structure (idempotent) and hand ownership back
for sub in original processed meta; do
  dir="$BASE_DIR/$sub"
  if [[ -d $dir ]]; then
    echo "⚠️  Already exists: $dir"
  else
    mkdir -p "$dir"
    chown "$USER_NAME":"$USER_NAME" "$dir"
    echo "✅ Created: $dir"
  fi
done
echo "📁 DCIM folder ready at $BASE_DIR"

# ───────────────────────────────────
# 2) helper wrappers
# ───────────────────────────────────
need_cmd()  { command -v "$1" &>/dev/null; }
need_snap() { snap list "$1" &>/dev/null; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

# ───────────────────────────────────
# 3) installers (all idempotent)
# ───────────────────────────────────
install_snapd() {
  echo "🔧 Installing snapd…"
  # Linux Mint blocks snap via nosnap.pref – rename it if present
  local nosnap=/etc/apt/preferences.d/nosnap.pref
  if [[ -f $nosnap ]]; then
    echo "👉 Unblocking snap (renaming $nosnap)"
    mv "$nosnap" "${nosnap}.bak"
  fi
  apt_install snapd
}

install_ttyd() {
  echo "🔧 Ensuring ttyd snap…"
  need_snap ttyd || snap install ttyd --classic || [[ $? -eq 10 ]]
}

install_filebrowser() {
  echo "🔧 Ensuring File Browser…"
  if ! need_cmd filebrowser; then
    # Run the official installer as the real user so its cache & DB land
    # in ~/.config instead of /root/.config
    sudo -u "$USER_NAME" -E bash -c \
      'curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash'
  fi
}

install_cli_prereqs() {
  echo "🔧 Installing CLI prereqs…"
  apt_install curl gnupg2 ca-certificates lsb-release ubuntu-keyring
}

install_nginx() {
  echo "🔧 Ensuring NGINX (distro package)…"
  # Refresh package index once per run
  apt-get update -qq
  # Install only if the binary is missing
  need_cmd nginx || apt_install nginx
}

# ───────────────────────────────────
# 4) dependency resolution
# ───────────────────────────────────
echo "🔍 Checking dependencies…"
apt-get update -qq

need_cmd snap        || install_snapd
need_cmd curl || need_cmd gpg || install_cli_prereqs
need_snap ttyd       || install_ttyd
need_cmd filebrowser || install_filebrowser
need_cmd nginx       || install_nginx

TTYD_BIN=$(command -v ttyd)
FB_BIN=$(command -v filebrowser)

# ───────────────────────────────────
# 5) systemd units (overwrite-safe)
# ───────────────────────────────────
cat > /etc/systemd/system/ttyd.service <<EOF
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

cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser (serving $USER_HOME on port 8080)
After=network.target

[Service]
User=$USER_NAME
WorkingDirectory=$USER_HOME
ExecStart=$FB_BIN \\
  -r $USER_HOME \\
  --address 0.0.0.0 \\
  --port 8080 \\
  --database $USER_HOME/.config/filebrowser.db
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ───────────────────────────────────
# 6) Samba share setup
# ───────────────────────────────────
SMB_CONF=/etc/samba/smb.conf
echo "🔧 Ensuring Samba…"
need_cmd smbd || apt_install samba

echo "📂 Setting guest-read permissions on $USER_HOME…"
chmod o+rx "$USER_HOME"

# one-time smb.conf backup
[[ -f ${SMB_CONF}.orig ]] || cp "$SMB_CONF" "${SMB_CONF}.orig"

echo "🧹 Refreshing DCIM & Thymoeidolon blocks…"
awk '
  BEGIN {skip=0}
  /^\[(DCIM|Thymoeidolon)\]/{skip=1;next}
  /^\[.*\]/{skip=0}
  !skip
' "$SMB_CONF" > "${SMB_CONF}.tmp"
mv "${SMB_CONF}.tmp" "$SMB_CONF"

cat >> "$SMB_CONF" <<EOF
[global]
   security = user
   map to guest = Bad User
   guest account = nobody
   null passwords = yes   # allow blank passwords

[DCIM]
   path = $BASE_DIR
   browsable = yes
   read only = no
   guest ok = yes
   force user = $USER_NAME
   guest only = yes
   create mask = 0777
   directory mask = 0777
   force group = nogroup

[Thymoeidolon]
   path = $USER_HOME
   browsable = yes
   read only = no
   guest ok = yes
   force user = $USER_NAME
   guest only = yes
   create mask = 0777
   directory mask = 0777
   force group = nogroup
EOF
systemctl restart smbd nmbd nginx

# ───────────────────────────────────
# 7) enable + start services
# ───────────────────────────────────
systemctl daemon-reload
systemctl enable --now ttyd.service filebrowser.service

IP_ADDR=$(hostname -I | awk '{print $1}')

# ─────────────────────────────────────────────────────────────
#  A) Python backend (server.py) as a systemd service
# ─────────────────────────────────────────────────────────────
configure_backend_service() {
  local SERVICE=/etc/systemd/system/thymoeidolon-backend.service
  local WORKDIR="$SCRIPT_DIR"
  local PY=$(command -v python3 || true)

  if [[ -z $PY ]]; then
    echo "🔧 Installing python3 …"
    apt_install python3
    PY=$(command -v python3)
  fi

  cat > "$SERVICE" <<EOF
[Unit]
Description=Thymoeidolon backend (server.py on port 8000)
After=network.target

[Service]
User=$USER_NAME
WorkingDirectory=$WORKDIR
ExecStart=$PY -u server.py --port 8000
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now thymoeidolon-backend.service
  echo "🟢 server.py active on http://127.0.0.1:8000"
}

# ─────────────────────────────────────────────────────────────
#  B) NGINX vhost that fronts the backend and static assets
# ─────────────────────────────────────────────────────────────
configure_nginx_front() {
  local REPO_STATIC="$SCRIPT_DIR/nginx"   # must contain index.html
  local VHOST="/etc/nginx/conf.d/thymoeidolon.conf"

  [[ -d $REPO_STATIC ]] || {
    echo "❌ $REPO_STATIC not found (needs index.html)"; exit 1; }

  # Disable any shipped “default” site on Ubuntu/Mint
  for f in \
      /etc/nginx/conf.d/default.conf \
      /etc/nginx/sites-enabled/default \
      /etc/nginx/sites-enabled/default.conf; do
    [[ -e $f ]] && { echo "👉 Removing vendor default site: $f"; rm -f "$f"; }
  done

  cat > "$VHOST" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    # ---------- static assets ----------
    root __STATIC_ROOT__;
    index index.html;

    location / {
        try_files $uri $uri/ @backend;
    }

    # ---------- Python backend ----------
    location @backend {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    client_max_body_size 20m;
    add_header X-Frame-Options DENY;
}
EOF

  sed -i "s|__STATIC_ROOT__|$REPO_STATIC|" "$VHOST"

  nginx -t && systemctl reload nginx
}

configure_backend_service
configure_nginx_front

# ───────────────────────────────────
# 8) final ownership sweep
# ───────────────────────────────────
echo "🧹 Restoring ownership of user files…"
chown -R "$USER_NAME":"$USER_NAME" "$BASE_DIR" "$USER_HOME/.config" 2>/dev/null || true

echo
echo "🌐 NGINX now serves:"
echo "      • static  → http://$IP_ADDR/index.html"
echo "      • backend → http://$IP_ADDR/   (via proxy to :8000)"
echo
echo "✅ All set!"
echo "   – ttyd         → http://$IP_ADDR:7681"
echo "   – File Browser → http://$IP_ADDR:8080  (serves $USER_HOME)"
echo "   – Samba shares live on $IP_ADDR"
