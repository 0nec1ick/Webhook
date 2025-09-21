#!/usr/bin/env bash
# Interactive provisioner for a Telegram webhook Node app behind Nginx.
# Steps covered:
# 1) Nginx reverse proxy vhost
# 2) SSL (certbot) [optional]
# 3) App setup (.env, npm install, PM2)
# 4) Telegram webhook set/get
# 5) Quick debug helpers

set -euo pipefail

# ------------ UI helpers ------------
c() { printf "\033[%sm" "$1"; }
ok() { echo -e "$(c 32m)[OK]$(c 0m) $*"; }
warn() { echo -e "$(c 33m)[WARN]$(c 0m) $*"; }
err() { echo -e "$(c 31m)[ERR]$(c 0m) $*" >&2; }
ask() { # $1=prompt, $2=var, $3=default (optional)
  local p="$1" v="$2" d="${3:-}" _ans
  if [ -n "$d" ]; then
    read -r -p "$p [$d]: " _ans || true
    export "$v"="${_ans:-$d}"
  else
    read -r -p "$p: " _ans || true
    export "$v"="${_ans:-}"
  fi
}
ask_secret() { # $1=prompt, $2=var
  local p="$1" v="$2" _ans
  read -r -s -p "$p: " _ans || true; echo
  export "$v"="${_ans:-}"
}
yesno() { # $1=prompt, return 0=yes 1=no
  local p="$1" a
  read -r -p "$p [y/N]: " a || true
  [[ "$a" =~ ^[Yy]$ ]]
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }

# ------------ preflight ------------
need_cmd nginx
need_cmd pm2
need_cmd node
need_cmd npm
need_cmd curl
command -v jq >/dev/null 2>&1 || warn "jq not found (optional for pretty JSON)"

if [ "$(id -u)" -ne 0 ]; then
  warn "It's recommended to run with sudo for Nginx/certbot steps."
  if ! yesno "Continue anyway? (you may be asked for sudo password)"; then exit 1; fi
fi

# ------------ gather inputs ------------
echo "== General settings =="
ask "Your domain (FQDN)" DOMAIN "bot.shahrmeeting.ir"
ask "Nginx upstream app port" APP_PORT "3000"
ask "Nginx site name (filename)" SITE_NAME "webhook"
ask "App directory (where index.js lives)" APP_DIR "/var/www/webhook"
ask "PM2 process name" PM2_NAME "telegram-webhook"

echo
echo "== SSL =="
ENABLE_SSL="no"
if yesno "Issue/renew Let's Encrypt certificate via certbot for ${DOMAIN}?"; then
  ENABLE_SSL="yes"
  ask "Admin email for Let's Encrypt" LE_EMAIL "admin@example.com"
fi

echo
echo "== App (.env) keys =="
ask "WEBHOOK_URL (usually https://DOMAIN/webhook)" WEBHOOK_URL "https://${DOMAIN}/webhook"
ask_secret "TELEGRAM_TOKEN" TELEGRAM_TOKEN
ask "SUPABASE_URL" SUPABASE_URL "https://YOUR-PROJECT.supabase.co"
ask_secret "SUPABASE_SERVICE_ROLE_KEY" SUPABASE_SERVICE_ROLE_KEY

echo
echo "== Telegram webhook ops =="
DO_SET_WEBHOOK="no"
if yesno "Set Telegram webhook now?"; then DO_SET_WEBHOOK="yes"; fi

echo
echo "Summary:"
echo "  Domain:           $DOMAIN"
echo "  App port:         $APP_PORT"
echo "  Nginx site:       $SITE_NAME"
echo "  App dir:          $APP_DIR"
echo "  PM2 name:         $PM2_NAME"
echo "  SSL via certbot:  $ENABLE_SSL"
echo "  WEBHOOK_URL:      $WEBHOOK_URL"
echo "  Set webhook now:  $DO_SET_WEBHOOK"
if ! yesno "Proceed with these settings?"; then
  err "Aborted by user."
  exit 1
fi

# ------------ Step 1: Nginx reverse proxy ------------
echo "==> Writing Nginx site: /etc/nginx/sites-available/${SITE_NAME}"
sudo tee "/etc/nginx/sites-available/${SITE_NAME}" >/dev/null <<'NGINX'
server {
    server_name __DOMAIN__;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        proxy_pass http://localhost:__APP_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    listen 80;
    listen [::]:80;
}
NGINX

# Replace placeholders safely
sudo sed -i "s/__DOMAIN__/${DOMAIN//\//\\/}/g; s/__APP_PORT__/${APP_PORT}/g" "/etc/nginx/sites-available/${SITE_NAME}"

sudo ln -sf "/etc/nginx/sites-available/${SITE_NAME}" "/etc/nginx/sites-enabled/${SITE_NAME}"
sudo nginx -t
sudo systemctl reload nginx
ok "Nginx site enabled and reloaded (HTTP on :80)."

# ------------ Step 2: SSL certificate (optional) ------------
if [ "$ENABLE_SSL" = "yes" ]; then
  if ! command -v certbot >/dev/null 2>&1; then
    err "certbot missing. Install it with: sudo apt-get install -y certbot python3-certbot-nginx"
    exit 1
  fi
  echo "==> Requesting/renewing certificate for ${DOMAIN}..."
  if ! sudo certbot --nginx -d "${DOMAIN}" -m "${LE_EMAIL}" --agree-tos --non-interactive; then
    warn "Certbot failed; keeping HTTP-only vhost."
  fi
  sudo certbot renew --dry-run || warn "Certbot dry-run renewal failed."
  ok "SSL step finished."
fi

# ------------ Step 3: App setup ------------
echo "==> Preparing app at ${APP_DIR}"
if [ ! -d "$APP_DIR" ]; then
  if yesno "Create app directory ${APP_DIR}?"; then
    sudo mkdir -p "$APP_DIR"
    OWNER="$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")"
    sudo chown -R "$OWNER:$OWNER" "$APP_DIR"
    ok "Created ${APP_DIR}"
  else
    warn "App directory not found. You can place code later and rerun only app section."
  fi
fi

# .env
if [ -d "$APP_DIR" ]; then
  tmp_env="${APP_DIR}/.env.tmp.$$"
  {
    echo "PORT=${APP_PORT}"
    echo "TELEGRAM_TOKEN=${TELEGRAM_TOKEN}"
    echo "WEBHOOK_URL=${WEBHOOK_URL}"
    echo "SUPABASE_URL=${SUPABASE_URL}"
    echo "SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY}"
  } > "$tmp_env"

  if [ -f "${APP_DIR}/.env" ]; then
    if yesno ".env exists. Overwrite it?"; then
      mv "$tmp_env" "${APP_DIR}/.env"
    else
      rm -f "$tmp_env"
    fi
  else
    mv "$tmp_env" "${APP_DIR}/.env"
  fi
  [ -f "${APP_DIR}/.env" ] && chmod 600 "${APP_DIR}/.env" && ok ".env written"
fi

# npm install
if [ -d "$APP_DIR" ] && [ -f "${APP_DIR}/package.json" ]; then
  echo "==> Running npm install in ${APP_DIR}"
  (cd "$APP_DIR" && npm install)
else
  warn "package.json not found in ${APP_DIR}. Skipping npm install."
fi

# PM2
if [ -d "$APP_DIR" ] && [ -f "${APP_DIR}/index.js" ]; then
  echo "==> Starting app with PM2"
  (
    cd "$APP_DIR"
    pm2 start index.js --name "${PM2_NAME}" || pm2 restart "${PM2_NAME}"
  )
  pm2 save || true
  ok "PM2 process: ${PM2_NAME}"
else
  warn "index.js not found in ${APP_DIR}. Skipping PM2 start."
fi

# ------------ Step 4: Telegram webhook ------------
if [ "$DO_SET_WEBHOOK" = "yes" ]; then
  if [ -z "${TELEGRAM_TOKEN}" ]; then
    warn "TELEGRAM_TOKEN empty. Skipping webhook set."
  else
    echo "==> Setting webhook to ${WEBHOOK_URL}"
    curl -fsS "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook" \
      --get --data-urlencode "url=${WEBHOOK_URL}" -o /tmp/setwebhook.json || true
    if command -v jq >/dev/null; then jq . /tmp/setwebhook.json || cat /tmp/setwebhook.json; else cat /tmp/setwebhook.json; fi

    echo "==> Webhook info:"
    curl -fsS "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getWebhookInfo" -o /tmp/getwebhook.json || true
    if command -v jq >/dev/null; then jq . /tmp/getwebhook.json || cat /tmp/getwebhook.json; else cat /tmp/getwebhook.json; fi
  fi
fi

# ------------ Step 5: Quick debug helpers ------------
echo
echo "== Quick checks =="
echo "• Nginx status:   sudo systemctl status nginx --no-pager"
echo "• PM2 list:       pm2 list"
echo "• PM2 logs:       pm2 logs ${PM2_NAME}"
echo "• Ports:          sudo ss -tulpn | grep -E ':80|:443|:${APP_PORT}' || true"
echo "• App health:     curl -I http://127.0.0.1:${APP_PORT} || true"
if [ "$ENABLE_SSL" = "yes" ]; then
  echo "• HTTPS head:     curl -I https://${DOMAIN} -k || true"
fi
ok "All done."
