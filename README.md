# Webhook Server Bootstrap & Management Scripts

This repository contains helper scripts to quickly **bootstrap**, **configure**, and **verify** a Telegram webhook server on Ubuntu.

---

## 🚀 Quick Start

Run the following one-liners to download and execute each script.

### 1. Bootstrap the Server
```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/0nec1ick/Webhook/refs/heads/main/Bootstrap-Webhook.sh" && chmod 700 /root/Bootstrap-Webhook.sh && /root/Bootstrap-Webhook.sh
```

**What it does:**
- Updates the system and installs essential packages (curl, git, nano, ufw, etc.).
- Installs Node.js (LTS), npm, and PM2.
- Installs and enables Nginx.
- Installs troubleshooting tools (htop, lsof, tcpdump, etc.).
- Prepares UFW firewall rules (OpenSSH, HTTP, HTTPS).
- Installs Certbot for SSL (optional).
- At the end, it prints a checklist of what you need to configure manually (vhost, `.env`, etc.).

---

### 2. Provision Helper (Interactive Setup)
```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/0nec1ick/Webhook/refs/heads/main/provision-webhook-helper.sh" && chmod 700 /root/provision-webhook-helper.sh && /root/provision-webhook-helper.sh
```

**What it does:**
- Asks you for input (domain, email, app path, process name, etc.).
- Creates a sample **Nginx reverse proxy config** for your webhook app.
- Helps you issue/renew SSL certificates using Certbot.
- Reminds you to place your app code and `.env` file in the right path.
- Guides you through starting your app with PM2 and saving the process.

---

### 3. Verify Setup
```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/0nec1ick/Webhook/refs/heads/main/verify-webhook-setup.sh" && chmod 700 /root/verify-webhook-setup.sh && /root/verify-webhook-setup.sh
```

**What it does:**
- Checks if required commands are installed (`node`, `npm`, `pm2`, `nginx`, `certbot`, `ufw`, etc.).
- Shows current versions of Node.js, PM2, and Nginx.
- Validates Nginx configuration (`nginx -t`) and lists enabled sites.
- Verifies app directory, `.env`, and entry file (`index.js`).
- Shows PM2 processes and logs.
- Displays Nginx error logs (last 30 lines).
- Optionally checks your SSL certificate for the domain.
- Optionally queries Telegram API (`getWebhookInfo`) with your bot token.
- Optionally checks Supabase URL connectivity.
- Prints firewall (UFW) rules.

---

## 🛠 Typical Workflow
1. **Bootstrap** the new server:
   ```bash
   ./Bootstrap-Webhook.sh
   ```

2. **Provision** the reverse proxy, SSL, and app setup:
   ```bash
   ./provision-webhook-helper.sh
   ```

3. **Verify** that everything is running correctly:
   ```bash
   ./verify-webhook-setup.sh
   ```

---

## ⚠️ Notes
- Always run these scripts with `sudo -E` to preserve environment variables.
- Update `.env` with your own `TELEGRAM_TOKEN`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, etc.
- After configuration, don’t forget to **set your webhook** with Telegram:
  ```bash
  curl "https://api.telegram.org/bot<TELEGRAM_TOKEN>/setWebhook?url=https://YOUR_DOMAIN/webhook"
  ```
- Logs:
  - Nginx: `/var/log/nginx/error.log`
  - PM2: `pm2 logs <process-name>`

---

## 📄 License
MIT – free to use and adapt.
