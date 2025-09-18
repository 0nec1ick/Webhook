#!/usr/bin/env bash
# Minimal bootstrap for Ubuntu (Node.js + Nginx + PM2 + SSL tools + troubleshooting)
set -euo pipefail

: "${NODE_MAJOR:=18}"         # Node.js LTS (18/20/22)
: "${INSTALL_SSL:=yes}"       # yes|no (install certbot)
: "${INSTALL_EXTRA_NET:=yes}" # yes|no (tcpdump, nmap, traceroute, ...)
: "${INSTALL_DEVTOOLS:=yes}"  # yes|no (build-essential, python3, etc.)

echo "==> Updating system..."
sudo apt update && sudo apt -y upgrade

echo "==> Installing essentials..."
sudo apt -y install \
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

if [ "${INSTALL_EXTRA_NET}" = "yes" ]; then
  sudo apt -y install tcpdump nmap traceroute mtr socat
fi

if [ "${INSTALL_DEVTOOLS}" = "yes" ]; then
  sudo apt -y install build-essential python3 python3-pip python3-venv pkg-config make gcc g++
fi

echo "==> Installing Node.js ${NODE_MAJOR}.x..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
sudo apt -y install nodejs
node -v && npm -v

echo "==> Installing PM2..."
sudo npm i -g pm2
pm2 -v

RUN_USER="$(logname 2>/dev/null || echo "$SUDO_USER" || whoami)"
RUN_HOME="$(eval echo "~${RUN_USER}")"
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u "${RUN_USER}" --hp "${RUN_HOME}" || true

echo "==> Configuring UFW..."
sudo ufw allow OpenSSH || true
sudo ufw allow 80 || true
sudo ufw allow 443 || true
if ! sudo ufw status | grep -q "Status: active"; then
  yes | sudo ufw enable
fi

if [ "${INSTALL_SSL}" = "yes" ]; then
  sudo apt -y install certbot python3-certbot-nginx
  echo "==> Certbot installed (no certificate issued)."
fi

echo "==> Enabling Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

cat <<'EOF'

────────────────────────────────────────────
✅ Bootstrap finished.
────────────────────────────────────────────
EOF

