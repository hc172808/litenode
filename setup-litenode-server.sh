#!/usr/bin/env bash

set -Eeuo pipefail

############################################
# CONFIG
############################################

APP_NAME="gyds-litenode"
APP_USER="gyds"
APP_DIR="/opt/gyds-litenode"
REPO_URL="https://github.com/hc172808/litenode.git"
BRANCH="main"

RPC_PORT="8545"
WS_PORT="8546"
P2P_PORT="30303"
SSH_PORT="22"

GO_VERSION="1.22.4"

############################################
# COLORS
############################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERR]${NC} $1"; }

############################################
# ROOT CHECK
############################################

if [[ "$EUID" -ne 0 ]]; then
  err "Run as root (sudo ./setup-litenode-server.sh)"
  exit 1
fi

############################################
# SYSTEM UPDATE
############################################

log "Updating system..."
apt update && apt upgrade -y

############################################
# BASE PACKAGES
############################################

log "Installing base packages..."
apt install -y \
  git curl wget unzip nginx ufw fail2ban \
  build-essential jq htop ca-certificates gnupg \
  software-properties-common apt-transport-https

############################################
# GO
############################################

log "Installing Go ${GO_VERSION}..."

GO_TAR="go${GO_VERSION}.linux-$(dpkg --print-architecture | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz"
wget -q "https://go.dev/dl/${GO_TAR}" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

export PATH="/usr/local/go/bin:$PATH"
echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile.d/go.sh
chmod +x /etc/profile.d/go.sh

go version || { err "Go installation failed"; exit 1; }

############################################
# DOCKER
############################################

log "Installing Docker..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl restart docker

############################################
# USER
############################################

id "$APP_USER" &>/dev/null || \
  adduser --disabled-password --gecos "" "$APP_USER"

usermod -aG docker "$APP_USER"

############################################
# FIREWALL
############################################

log "Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "$RPC_PORT"/tcp
ufw allow "$WS_PORT"/tcp
ufw allow "$P2P_PORT"/tcp
ufw --force enable

############################################
# FAIL2BAN
############################################

log "Setting up Fail2Ban..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = $SSH_PORT
EOF

systemctl restart fail2ban
systemctl enable fail2ban

############################################
# CLONE OR UPDATE REPO
############################################

log "Setting up app directory..."

mkdir -p "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  git clone "$REPO_URL" "$APP_DIR"
else
  git -C "$APP_DIR" config --global --add safe.directory "$APP_DIR"
  git -C "$APP_DIR" fetch origin
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
fi

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

############################################
# ENV FILE
############################################

log "Setting up .env..."

if [ -f "$APP_DIR/.env.example" ]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
else
  err ".env.example not found in repo"
  exit 1
fi

chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

# Append runtime overrides
cat >> "$APP_DIR/.env" <<EOF

# ─── Runtime overrides (set by setup script) ───
GYDS_RPC_PORT=$RPC_PORT
GYDS_P2P_PORT=$P2P_PORT
GYDS_DATA_DIR=/app/data
EOF

############################################
# BUILD BINARY (NATIVE — OPTIONAL)
############################################

log "Building GYDS litenode binary..."

export PATH="/usr/local/go/bin:$PATH"
cd "$APP_DIR"
make build || go build -ldflags="-s -w" -o bin/gyds-litenode .

log "Binary: $(file "$APP_DIR/bin/gyds-litenode")"

############################################
# DOCKER BUILD + START
############################################

log "Building Docker image..."

cd "$APP_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose build --no-cache
docker compose up -d

############################################
# NGINX
############################################

log "Configuring Nginx reverse proxy..."

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/gyds-litenode <<EOF
# JSON-RPC
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$RPC_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/gyds-litenode \
       /etc/nginx/sites-enabled/gyds-litenode

nginx -t
systemctl restart nginx
systemctl enable nginx

############################################
# HEALTH CHECK SCRIPT
############################################

log "Installing health-check helper..."

cat > /usr/local/bin/gyds-health.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/gyds-litenode"
cd "$APP_DIR"

if ! docker compose ps | grep -q "Up"; then
  echo "[WARN] gyds-litenode container not running — restarting..."
  docker compose up -d
else
  # Quick JSON-RPC ping
  RESP=$(curl -sf -X POST http://localhost:8545 \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' || true)
  if [ -n "$RESP" ]; then
    echo "[OK] RPC responding — $(echo "$RESP" | grep -o '"result":"[^"]*"')"
  else
    echo "[WARN] RPC not responding"
  fi
fi
EOF

chmod +x /usr/local/bin/gyds-health.sh

# Cron: run health check every 5 minutes
(crontab -l 2>/dev/null | grep -v gyds-health; echo "*/5 * * * * /usr/local/bin/gyds-health.sh >> /var/log/gyds-health.log 2>&1") \
  | crontab -

############################################
# SYSTEMD SERVICE (NATIVE BINARY FALLBACK)
############################################

log "Creating systemd service (native binary)..."

cat > /etc/systemd/system/gyds-litenode.service <<EOF
[Unit]
Description=GYDS Litenode
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/bin/gyds-litenode start
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

StandardOutput=journal
StandardError=journal
SyslogIdentifier=gyds-litenode

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Note: systemd service is available but Docker is the default runner.
# To switch: systemctl enable --now gyds-litenode

############################################
# FINAL STATUS
############################################

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       GYDS LITENODE DEPLOYED         ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  JSON-RPC:   http://YOUR_SERVER_IP:$RPC_PORT"
echo "  WebSocket:  ws://YOUR_SERVER_IP:$WS_PORT"
echo "  P2P:        tcp://YOUR_SERVER_IP:$P2P_PORT"
echo ""
echo "  Via Nginx:  http://YOUR_SERVER_IP"
echo ""
echo "  Logs:       cd $APP_DIR && docker compose logs -f"
echo "  Health:     gyds-health.sh"
echo "  Re-run:     sudo ./setup-litenode-server.sh"
echo ""
echo "  Quick RPC test:"
echo '  curl -X POST http://YOUR_SERVER_IP:8545 \'
echo '    -H "Content-Type: application/json" \'
echo '    --data '"'"'{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'"'"
echo ""
