#!/usr/bin/env bash
# verify-webhook-setup.sh
# End-to-end verifier for Node + PM2 + Nginx + SSL (certbot) + Telegram webhook
# Recommended to run with sudo.
set -euo pipefail

# ========== Colors ==========
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
info(){ printf "${CYAN}%s${NC}\n" "$1"; }
ok(){ printf "${GREEN}✔ %s${NC}\n" "$1"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$1"; }
fail(){ printf "${RED}✖ %s${NC}\n" "$1"; }

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

check_cmd(){
  local cmd="$1"
  if has_cmd "$cmd"; then
    ok "Command '${cmd}' is installed (path: $(command -v "$cmd"))"
  else
    fail "Command '${cmd}' is NOT installed"
    case "$cmd" in
      node)  echo "  Hint: curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR:-18}.x | sudo -E bash - && sudo apt install -y nodejs";;
      npm)   echo "  Hint: npm comes with Node.js";;
      pm2)   echo "  Hint: sudo npm i -g pm2";;
      nginx) echo "  Hint: sudo apt install -y nginx";;
      certbot) echo "  Hint: sudo apt install -y certbot python3-certbot-nginx";;
      jq)    echo "  Hint (optional): sudo apt install -y jq";;
      curl)  echo "  Hint: sudo apt install -y curl";;
      ss)    echo "  Hint: sudo apt install -y iproute2";;
      netstat) echo "  Hint: sudo apt install -y net-tools";;
    esac
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  warn "Not running as root. Some checks (ports, nginx) may require sudo privileges."
fi

echo
info "=== Webhook stack verification: Node / PM2 / Nginx / SSL / Webhook ==="
echo

# 1) Basic commands
info "1) CLI availability"
for cmd in node npm pm2 nginx certbot ufw curl ss jq; do
  check_cmd "$cmd"
done
# Optional fallback note for netstat
has_cmd ss || check_cmd netstat
echo

# 2) Versions
info "2) Versions"
has_cmd node  && node -v | xargs -I{} ok "Node: {}"
has_cmd npm   && npm -v  | xargs -I{} ok "npm: {}"
has_cmd pm2   && pm2 -v  | xargs -I{} ok "PM2: {}"
has_cmd nginx && nginx -v 2>&1 | head -n1 | xargs -I{} ok "Nginx: {}"
echo

# 3) Services
info "3) Service status"
if has_cmd systemctl; then
  if systemctl list-units --type=service | grep -q nginx; then
    if systemctl is-active --quiet nginx; then ok "Nginx: active"
    else warn "Nginx: inactive (check 'sudo systemctl status nginx')"
    fi
  else
    warn "Nginx service not registered with systemd"
  fi
else
  warn "systemctl not available; use your init system to check nginx"
fi
echo

# 4) Ports
info "4) Listening ports (80, 443, and app port)"
if has_cmd ss; then
  ss -tulpn | grep -E ':(80|443)\b' || true
elif has_cmd netstat; then
  netstat -tulpn 2>/dev/null | grep -E ':(80|443)\b' || true
else
  warn "Neither 'ss' nor 'netstat' found"
fi
echo

# 5) Nginx config test
info "5) Nginx configuration test"
if has_cmd nginx; then
  if nginx -t 2>&1 | tee /tmp/nginx_test_out >/dev/null; then
    ok "nginx -t returned OK"
  else
    fail "nginx -t failed. Output:"
    sed -n '1,200p' /tmp/nginx_test_out
    echo
  fi
  echo "Enabled sites:"
  ls -la /etc/nginx/sites-enabled 2>/dev/null || echo "  (no access or not found)"
else
  warn "nginx is not installed"
fi
echo

# 6) Vhost presence (optional)
info "6) Check a vhost file"
read -r -p "  Enter nginx site name (e.g. 'webhook') [webhook]: " SITE_FILE
SITE_FILE="${SITE_FILE:-webhook}"
VPATH_A="/etc/nginx/sites-available/${SITE_FILE}"
VPATH_E="/etc/nginx/sites-enabled/${SITE_FILE}"
if [ -f "${VPATH_A}" ]; then
  ok "Found: ${VPATH_A}"
  echo "  First 30 lines:"
  sed -n '1,30p' "${VPATH_A}" | sed -e 's/^/    /'
else
  warn "Missing: ${VPATH_A}"
fi
if [ -L "${VPATH_E}" ] || [ -f "${VPATH_E}" ]; then
  ok "Enabled: ${VPATH_E}"
else
  warn "Not enabled: ${VPATH_E} (you may need: ln -s ... && nginx -t && systemctl reload nginx)"
fi
echo

# 7) App directory & .env (masked output)
info "7) App directory and .env"
read -r -p "  Enter app directory (e.g. /var/www/webhook) [/var/www/webhook]: " APP_DIR
APP_DIR="${APP_DIR:-/var/www/webhook}"
if [ -d "${APP_DIR}" ]; then
  ok "App directory exists: ${APP_DIR}"
  if [ -f "${APP_DIR}/.env" ]; then
    ok "Found .env at ${APP_DIR}/.env"
    echo "  Showing masked .env (first 200 lines):"
    awk -F'=' '{
      if (NF>1) {
        key=$1; val=substr($0,length($1)+2);
        n=length(val);
        if (n>6) printf "    %s=%s****%s\n", key, substr(val,1,2), substr(val,n-1,2);
        else if (n>0) printf "    %s=****\n", key;
        else printf "    %s=\n", key;
      } else {
        print "    "$0;
      }
    }' "${APP_DIR}/.env" | sed -n '1,200p'
  else
    warn "No .env found at ${APP_DIR}"
  fi

  if [ -f "${APP_DIR}/package.json" ]; then ok "Found package.json"
  else warn "Missing package.json (did you copy the project?)"
  fi

  if [ -f "${APP_DIR}/index.js" ]; then ok "Found index.js"
  else warn "Missing index.js (check your entry file)"
  fi
else
  warn "App directory not found: ${APP_DIR}"
fi
echo

# 8) PM2 status
info "8) PM2 status"
if has_cmd pm2; then
  echo "PM2 list (summary):"
  pm2 list || warn "Failed to run 'pm2 list'"
  read -r -p "  Enter PM2 process name to inspect (optional): " PM2_NAME
  if [ -n "${PM2_NAME}" ]; then
    if pm2 pid "${PM2_NAME}" >/dev/null 2>&1; then
      ok "PM2 process '${PM2_NAME}' is running"
      pm2 show "${PM2_NAME}" | sed -n '1,60p'
    else
      warn "PM2 process '${PM2_NAME}' not found"
    fi
  fi
else
  warn "pm2 is not installed"
fi
echo

# 9) Logs
info "9) Logs (nginx error + pm2)"
echo "  nginx error.log (last 30 lines):"
sudo tail -n 30 /var/log/nginx/error.log 2>/dev/null || echo "  (not found or no permission)"
echo
if has_cmd pm2 && [ -n "${PM2_NAME:-}" ]; then
  echo "  pm2 logs ${PM2_NAME} (last 30 lines):"
  pm2 logs "${PM2_NAME}" --lines 30 || true
else
  echo "  Tip: provide a PM2 process name above to see its logs."
fi
echo

# 10) SSL (Let’s Encrypt)
info "10) SSL / Let’s Encrypt status"
read -r -p "  Enter domain to inspect SSL (optional): " CHECK_DOMAIN
if [ -n "${CHECK_DOMAIN}" ]; then
  if has_cmd certbot; then
    echo "  certbot certificates (filtered):"
    sudo certbot certificates 2>/dev/null | sed -n "/${CHECK_DOMAIN}/,/----/p" || warn "No certbot info."
    if [ -d "/etc/letsencrypt/live/${CHECK_DOMAIN}" ]; then
      ok "Live directory exists: /etc/letsencrypt/live/${CHECK_DOMAIN}"
      ls -l "/etc/letsencrypt/live/${CHECK_DOMAIN}"
    else
      warn "No live cert directory at /etc/letsencrypt/live/${CHECK_DOMAIN}"
    fi
  else
    warn "certbot not installed"
  fi
fi
echo

# 11) Telegram webhook
info "11) Telegram webhook"
read -r -p "  Enter TELEGRAM_TOKEN (optional): " TG_TOKEN
if [ -n "${TG_TOKEN}" ]; then
  if has_cmd curl; then
    echo "  Fetching getWebhookInfo..."
    set +e
    OUT="$(curl -sS "https://api.telegram.org/bot${TG_TOKEN}/getWebhookInfo" || true)"
    set -e
    if [ -z "${OUT}" ]; then
      warn "Telegram API returned empty/failed. Check internet connectivity or token validity."
    else
      if has_cmd jq; then echo "${OUT}" | jq .; else echo "${OUT}"; fi
      ok "getWebhookInfo returned output (see above)."
    fi
  else
    warn "curl not installed"
  fi
else
  warn "No TELEGRAM_TOKEN provided — skipping webhook check."
fi
echo

# 12) Supabase connectivity (optional)
info "12) Supabase connectivity (optional)"
read -r -p "  Enter SUPABASE_URL (optional): " SB_URL
if [ -n "${SB_URL}" ]; then
  if has_cmd curl; then
    echo "  HEAD request to ${SB_URL}:"
    curl -I -sS "${SB_URL}" | sed -n '1,20p' || warn "Connection failed"
  else
    warn "curl not installed"
  fi
fi
echo

# 13) UFW
info "13) UFW firewall"
if has_cmd ufw; then
  sudo ufw status verbose 2>/dev/null | sed -n '1,200p' || warn "ufw status not available"
else
  warn "ufw not installed"
fi
echo

# Final summary
info "=== Final notes ==="
echo "• Fix any missing commands (Node/npm/PM2/nginx/certbot/curl/jq)."
echo "• Ensure 'nginx -t' is clean, then reload: sudo systemctl reload nginx."
echo "• Make sure your vhost exists in sites-available and is symlinked in sites-enabled."
echo "• Ensure your app .env contains required keys (TELEGRAM_TOKEN, WEBHOOK_URL, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)."
echo "• PM2 process should be running and saved (pm2 start index.js --name <name> && pm2 save)."
echo "• If webhook is not set: curl \"https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://YOUR_DOMAIN/webhook\""
echo
ok "Verification finished."
