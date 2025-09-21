#!/usr/bin/env bash
# Minimal bootstrap for Ubuntu/Debian (Node.js + Nginx + PM2 + SSL tools + troubleshooting)
# Usage examples:
#   sudo -E NODE_MAJOR=20 INSTALL_SSL=no bash Bootstrap-Webhook.sh
#   sudo -E bash Bootstrap-Webhook.sh

set -euo pipefail

# --------------------
# Config (overridable)
# --------------------
: "${NODE_MAJOR:=18}"          # Node.js LTS major version: 18 | 20 | 22
: "${INSTALL_SSL:=yes}"        # yes|no : install certbot + nginx plugin
: "${INSTALL_EXTRA_NET:=yes}"  # yes|no : tcpdump, nmap, traceroute, mtr, socat
: "${INSTALL_DEVTOOLS:=yes}"   # yes|no : build-essential, python3, etc.

# --------------------
# Pre-flight checks
# --------------------
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required. Please install sudo and rerun." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script supports Linux only." >&2
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  source /etc/os-release
  OS_ID="${ID:-}"
else
  OS_ID=""
fi

case "$OS_ID" in
  ubuntu|debian) ;;
  *)
    echo "Warning: Detected OS '$OS_ID'. Proceeding as Debian-based, but apt may fail." >&2
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
APT_GET="sudo apt-get -y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef"

RUN_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"

# --------------------
# Update & essentials
# --------------------
echo "==> Updating system..."
sudo apt-get update -y
$APT_GET upgrade

echo "==> Installing essentials..."
$APT_GET install \
  ca-certificates gnupg apt-transport-https \
  curl wget git unzip zip tar xz-utils \
  nano vim tmux \
  jq \
  htop iotop iftop nload \
  lsof strace \
  net-tools iproute2 dnsutils \
  rsync \
  ufw \
  nginx

if [[ "${INSTALL_EXTRA_NET}" == "yes" ]]; then
  echo "==> Installing extra networking tools..."
  $APT_GET install tcpdump nmap traceroute mtr-tiny socat
fi

if [[ "${INSTALL_DEVTOOLS}" == "yes" ]]; then
  echo "==> Installing developer toolchain..."
  $APT_GET install build-essential python3 python3-pip python3-venv pkg-config make gcc g++
fi

# --------------------
# Node.js + npm + PM2
# --------------------
echo "==> Installing Node.js ${NODE_MAJOR}.x..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
$APT_GET install nodejs

echo "==> Node & npm versions:"
node -v
npm -v

echo "==> Installing PM2 (global)..."
sudo npm i -g pm2
pm2 -v

echo "==> Enabling PM2 startup for user: ${RUN_USER}"
sudo env PATH="$PATH:/usr/bin" pm2 startup systemd -u "${RUN_USER}" --hp "${RUN_HOME}" || true

# --------------------
# UFW firewall
# --------------------
echo "==> Configuring UFW..."
sudo ufw allow OpenSSH || true
sudo ufw allow 80 || true
sudo ufw allow 443 || true

if ! sudo ufw status | grep -q "Status: active"; then
  echo "y" | sudo ufw enable || true
fi

# --------------------
# Nginx + optional SSL tools
# --------------------
if [[ "${INSTALL_SSL}" == "yes" ]]; then
  echo "==> Installing Certbot (no certificates issued by this script)..."
  $APT_GET install certbot python3-certbot-nginx
fi

echo "==> Enabling & restarting Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

# --------------------
# Done
# --------------------
cat <<'EOF'
------------------------------------------------------------
✅ Bootstrap finished.

Installed:
- Essentials: curl, git, unzip/zip, jq, htop, net-tools, dnsutils, ufw, nginx
- Node.js + npm (Nodesource) and PM2 (global)
- Extra (optional): tcpdump, nmap, traceroute, mtr, socat
- Dev tools (optional): build-essential, python3, pip, venv

Next steps (optional):
1) Deploy your Node app and manage it with PM2:
   pm2 start app.js --name myapp
   pm2 save

2) If using Nginx as a reverse proxy, create a server block in:
   /etc/nginx/sites-available/<your-site>
   and symlink to /etc/nginx/sites-enabled/

3) If you need SSL (INSTALL_SSL=yes), obtain a certificate:
   sudo certbot --nginx -d your.domain

Have fun 🚀
------------------------------------------------------------
EOF
