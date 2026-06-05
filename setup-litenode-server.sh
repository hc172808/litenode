#!/usr/bin/env bash

set -Eeuo pipefail

############################################
# CONFIG — edit these before running
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

# Swap size in MB (0 = skip swap creation)
SWAP_SIZE_MB=2048

# Disk usage warning threshold (percent)
DISK_WARN_PCT=80

# Optional: set your domain for SSL (leave empty to skip Certbot)
# DOMAIN="rpc.yourdomain.com"
DOMAIN="${DOMAIN:-}"

# Optional: bootstrap peer address (leave empty to skip)
# GYDS_BOOTSTRAP_NODES="tcp://node1.gydschain.io:30303"
GYDS_BOOTSTRAP_NODES="${GYDS_BOOTSTRAP_NODES:-}"

############################################
# COLORS
############################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC}  $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
step() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }

############################################
# ROOT CHECK
############################################

if [[ "$EUID" -ne 0 ]]; then
  err "Run as root: sudo bash setup-litenode-server.sh"
  exit 1
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    GYDS Litenode — Ubuntu 22.04 Setup        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

############################################
# SYSTEM UPDATE
############################################

step "System update"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
log "System packages updated."

############################################
# BASE PACKAGES
############################################

step "Base packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl wget unzip nginx ufw fail2ban \
  build-essential jq htop ca-certificates gnupg \
  software-properties-common apt-transport-https \
  lsb-release logrotate chrony \
  unattended-upgrades apt-listchanges \
  certbot python3-certbot-nginx
log "Base packages installed."

############################################
# NTP / TIME SYNC (critical for blockchain)
############################################

step "Time synchronisation (chrony)"
systemctl enable chrony
systemctl restart chrony
sleep 2
chronyc tracking | grep -E "Reference|Offset|RMS" || true
log "Chrony running — system clock is synchronised."

############################################
# UNATTENDED SECURITY UPGRADES
############################################

step "Automatic security upgrades"
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "Unattended security upgrades enabled."

############################################
# SWAP SPACE
############################################

step "Swap space (${SWAP_SIZE_MB} MB)"
if [[ "$SWAP_SIZE_MB" -gt 0 ]]; then
  if swapon --show | grep -q /swapfile; then
    warn "Swap already exists — skipping."
  else
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Reduce swappiness — only use swap under real memory pressure
    echo 'vm.swappiness=10'        >> /etc/sysctl.d/99-gyds.conf
    echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.d/99-gyds.conf
    log "Swap created: ${SWAP_SIZE_MB} MB at /swapfile"
  fi
else
  info "Swap creation skipped (SWAP_SIZE_MB=0)."
fi

############################################
# KERNEL / SYSCTL TUNING
############################################

step "Kernel tuning for P2P networking"
cat > /etc/sysctl.d/99-gyds.conf <<'EOF'
# ── File descriptors ──────────────────────────────────
fs.file-max = 1000000

# ── Network — connection backlog & buffers ────────────
net.core.somaxconn          = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# ── TCP buffer sizes (P2P-optimised) ─────────────────
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max     = 16777216
net.core.wmem_max     = 16777216
net.ipv4.tcp_rmem     = 4096 262144 16777216
net.ipv4.tcp_wmem     = 4096 262144 16777216

# ── BBR congestion control ───────────────────────────
net.core.default_qdisc    = fq
net.ipv4.tcp_congestion_control = bbr

# ── Reduce TIME_WAIT accumulation ────────────────────
net.ipv4.tcp_tw_reuse     = 1
net.ipv4.ip_local_port_range = 10240 65535

# ── Swappiness (set again here for persistence) ───────
vm.swappiness          = 10
vm.vfs_cache_pressure  = 50
EOF

sysctl --system -q
log "Sysctl tuning applied (BBR, large buffers, high fd limit)."

# Raise open-file limits for the app user
cat >> /etc/security/limits.conf <<EOF

# GYDS Litenode
${APP_USER}   soft  nofile  65536
${APP_USER}   hard  nofile  131072
root          soft  nofile  65536
root          hard  nofile  131072
EOF
log "Open-file limits raised for ${APP_USER}."

############################################
# JOURNALD SIZE CAP
############################################

step "journald log size cap"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/gyds.conf <<'EOF'
[Journal]
SystemMaxUse=512M
SystemKeepFree=256M
MaxRetentionSec=2week
EOF
systemctl restart systemd-journald
log "journald capped at 512 MB / 2 weeks."

############################################
# SSH HARDENING
############################################

step "SSH hardening"
SSHD_CFG="/etc/ssh/sshd_config"

# Only harden if at least one authorized_keys exists
# (prevents locking yourself out on password-only setups)
HAS_KEY=false
for home in /root /home/*; do
  [[ -f "${home}/.ssh/authorized_keys" ]] && HAS_KEY=true && break
done

if [[ "$HAS_KEY" == "true" ]]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CFG"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'  "$SSHD_CFG"
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CFG"
  sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'   "$SSHD_CFG"
  sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'       "$SSHD_CFG"

  # Add hardening options if not already present
  grep -q "^ClientAliveInterval" "$SSHD_CFG" \
    || echo "ClientAliveInterval 300" >> "$SSHD_CFG"
  grep -q "^ClientAliveCountMax" "$SSHD_CFG" \
    || echo "ClientAliveCountMax 2"   >> "$SSHD_CFG"

  sshd -t && systemctl restart sshd
  log "SSH hardened: root password login disabled, key-only auth enforced."
else
  warn "No SSH authorized_keys found — SSH hardening SKIPPED to avoid lockout."
  warn "Add your public key to ~/.ssh/authorized_keys then re-run to harden SSH."
fi

############################################
# FAIL2BAN (with SSH rate limiting)
############################################

step "Fail2Ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5
destemail = root@localhost
action = %(action_mwl)s

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 24h

[nginx-http-auth]
enabled  = true

[nginx-botsearch]
enabled  = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2Ban configured (SSH: ban 24h after 3 failures)."

############################################
# UFW FIREWALL (with SSH rate limit)
############################################

step "UFW firewall"
ufw default deny incoming
ufw default allow outgoing
ufw limit  "${SSH_PORT}"/tcp   comment "SSH (rate-limited)"
ufw allow  80/tcp              comment "HTTP"
ufw allow  443/tcp             comment "HTTPS"
ufw allow  "${RPC_PORT}"/tcp   comment "GYDS RPC"
ufw allow  "${WS_PORT}"/tcp    comment "GYDS WebSocket"
ufw allow  "${P2P_PORT}"/tcp   comment "GYDS P2P"
ufw allow  "${P2P_PORT}"/udp   comment "GYDS P2P UDP"
ufw --force enable
log "Firewall active — SSH rate-limited, P2P (TCP+UDP) open."

############################################
# GO
############################################

step "Go ${GO_VERSION}"
ARCH="$(dpkg --print-architecture)"
GO_TAR="go${GO_VERSION}.linux-${ARCH}.tar.gz"
wget -q "https://go.dev/dl/${GO_TAR}" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

export PATH="/usr/local/go/bin:$PATH"
cat > /etc/profile.d/go.sh <<'GOPATH'
export PATH="/usr/local/go/bin:$PATH"
GOPATH
chmod +x /etc/profile.d/go.sh
go version || { err "Go installation failed"; exit 1; }
log "Go $(go version) installed."

############################################
# DOCKER (with daemon config)
############################################

step "Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Daemon config: cap log size, use overlay2, enable live-restore
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 131072,
      "Soft": 65536
    }
  }
}
EOF

systemctl enable docker
systemctl restart docker
log "Docker installed with log limits and live-restore enabled."

############################################
# USER
############################################

step "App user: ${APP_USER}"
id "$APP_USER" &>/dev/null \
  || adduser --disabled-password --gecos "" "$APP_USER"
usermod -aG docker "$APP_USER"
log "User ${APP_USER} ready."

############################################
# CLONE OR UPDATE REPO
############################################

step "Application source"
mkdir -p "$APP_DIR"

if [ ! -d "${APP_DIR}/.git" ]; then
  git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
  log "Repository cloned from ${REPO_URL}."
else
  git -C "$APP_DIR" config --global --add safe.directory "$APP_DIR"
  git -C "$APP_DIR" fetch origin
  git -C "$APP_DIR" reset --hard "origin/${BRANCH}"
  log "Repository updated to latest ${BRANCH}."
fi

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

############################################
# ENV FILE
############################################

step "Environment configuration"
ENV_FILE="${APP_DIR}/.env"

cat > "$ENV_FILE" <<EOF
# ─────────────────────────────────────────────
# GYDS Litenode — Runtime Configuration
# Generated by setup-litenode-server.sh
# ─────────────────────────────────────────────

# Chain
GYDS_CHAIN_ID=13370
GYDS_NODE_MODE=lite

# Networking
GYDS_RPC_PORT=${RPC_PORT}
GYDS_RPC_HOST=0.0.0.0
GYDS_P2P_PORT=${P2P_PORT}

# Bootstrap peers (comma-separated tcp addresses)
$([ -n "$GYDS_BOOTSTRAP_NODES" ] && echo "GYDS_BOOTSTRAP_NODES=${GYDS_BOOTSTRAP_NODES}" || echo "# GYDS_BOOTSTRAP_NODES=tcp://node1.gydschain.io:30303")

# Storage
GYDS_DATA_DIR=/app/data

# Logging  (trace|debug|info|warn|error)
GYDS_LOG_LEVEL=info
EOF

chown "${APP_USER}:${APP_USER}" "$ENV_FILE"
chmod 600 "$ENV_FILE"
log ".env written to ${ENV_FILE}"

############################################
# BUILD NATIVE BINARY
############################################

step "Build native binary"
export PATH="/usr/local/go/bin:$PATH"
cd "$APP_DIR"

if ! make build 2>/dev/null; then
  go build -ldflags="-s -w -X main.version=1.0.0" -o bin/gyds-litenode .
fi

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/bin"
log "Binary: $(file "${APP_DIR}/bin/gyds-litenode")"

############################################
# DOCKER BUILD + START
############################################

step "Docker container"
cd "$APP_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker compose build --no-cache
docker compose up -d

info "Waiting for container to become healthy (up to 60s)..."
for i in $(seq 1 12); do
  HEALTH=$(docker inspect --format='{{.State.Health.Status}}' gyds-litenode 2>/dev/null || echo "none")
  if [[ "$HEALTH" == "healthy" ]]; then
    log "Container is healthy."
    break
  fi
  [[ $i -eq 12 ]] && warn "Container health timeout — check: docker compose logs"
  sleep 5
done

############################################
# NGINX — RATE-LIMITED REVERSE PROXY
############################################

step "Nginx reverse proxy + rate limiting"
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/gyds-litenode <<NGINX
# ── Rate limiting zones ─────────────────────────────
# RPC: 30 req/s per IP, burst 60
limit_req_zone  \$binary_remote_addr zone=rpc_limit:10m rate=30r/s;
# WebSocket: 5 connections per IP
limit_conn_zone \$binary_remote_addr zone=ws_conn:10m;

# ── HTTP server ─────────────────────────────────────
server {
    listen 80;
    server_name ${DOMAIN:-_};

    # Shared proxy settings
    proxy_http_version 1.1;
    proxy_read_timeout  300s;
    proxy_send_timeout  300s;
    proxy_connect_timeout 10s;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # JSON-RPC (rate-limited)
    location / {
        limit_req  zone=rpc_limit burst=60 nodelay;
        proxy_pass http://127.0.0.1:${RPC_PORT};
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # REST API (rate-limited)
    location /api/ {
        limit_req zone=rpc_limit burst=30 nodelay;
        proxy_pass http://127.0.0.1:${RPC_PORT};
    }

    # WebSocket endpoint (connection-limited)
    location /api/ws {
        limit_conn ws_conn 10;
        proxy_pass         http://127.0.0.1:${RPC_PORT};
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    # Health (no rate limit — used by load balancers)
    location /health {
        proxy_pass http://127.0.0.1:${RPC_PORT}/health;
        access_log off;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/gyds-litenode \
       /etc/nginx/sites-enabled/gyds-litenode

nginx -t
systemctl enable nginx
systemctl restart nginx
log "Nginx configured with rate limiting (30 req/s RPC, 10 WS connections/IP)."

############################################
# SSL / TLS (Certbot — only if DOMAIN set)
############################################

step "SSL / TLS"
if [[ -n "$DOMAIN" ]]; then
  info "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN"
  # Auto-renew cron
  (crontab -l 2>/dev/null | grep -v certbot; \
   echo "0 3 * * * certbot renew --quiet --nginx") | crontab -
  log "SSL certificate issued for ${DOMAIN}. Auto-renewal scheduled at 03:00."
else
  warn "DOMAIN not set — SSL skipped. To enable HTTPS:"
  warn "  DOMAIN=rpc.yourdomain.com sudo bash setup-litenode-server.sh"
fi

############################################
# SYSTEMD SERVICE (native binary — optional)
############################################

step "Systemd service (native binary)"
DATA_DIR="${APP_DIR}/data"
mkdir -p "$DATA_DIR"
chown "${APP_USER}:${APP_USER}" "$DATA_DIR"

cat > /etc/systemd/system/gyds-litenode.service <<EOF
[Unit]
Description=GYDS Litenode (native binary)
Documentation=https://github.com/hc172808/litenode
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="GYDS_CHAIN_ID=13370"
Environment="GYDS_NODE_MODE=lite"
Environment="GYDS_RPC_PORT=${RPC_PORT}"
Environment="GYDS_RPC_HOST=0.0.0.0"
Environment="GYDS_P2P_PORT=${P2P_PORT}"
Environment="GYDS_DATA_DIR=${DATA_DIR}"
Environment="GYDS_LOG_LEVEL=info"
$([ -n "$GYDS_BOOTSTRAP_NODES" ] && echo "Environment=\"GYDS_BOOTSTRAP_NODES=${GYDS_BOOTSTRAP_NODES}\"")

ExecStart=${APP_DIR}/bin/gyds-litenode start
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
log "Systemd service installed (not started — Docker is the default runner)."
log "To switch: docker compose down && systemctl enable --now gyds-litenode"

############################################
# LOGROTATE
############################################

step "Log rotation"
cat > /etc/logrotate.d/gyds-health <<'LOGROTATE'
/var/log/gyds-health.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 root root
}
LOGROTATE
log "Logrotate configured for /var/log/gyds-health.log (14 days)."

############################################
# HEALTH CHECK SCRIPT (with disk alert)
############################################

step "Health check script"

cat > /usr/local/bin/gyds-health <<HEALTHSCRIPT
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR}"
RPC_PORT="${RPC_PORT}"
DISK_WARN_PCT="${DISK_WARN_PCT}"

TS="\$(date '+%Y-%m-%dT%H:%M:%S')"

cd "\$APP_DIR"

# ── Disk space check ──────────────────────────────────────────────────────────
DISK_USED=\$(df --output=pcent "\$APP_DIR" | tail -1 | tr -d ' %')
if [[ "\$DISK_USED" -ge "\$DISK_WARN_PCT" ]]; then
  echo "\$TS [WARN] Disk at \${DISK_USED}% — clean old data or expand volume"
fi

# ── Container check ───────────────────────────────────────────────────────────
RUNNING=\$(docker compose ps --status running --quiet 2>/dev/null | wc -l)

if [[ "\$RUNNING" -eq 0 ]]; then
  echo "\$TS [WARN] Container not running — restarting..."
  docker compose up -d
  exit 0
fi

# ── RPC ping ──────────────────────────────────────────────────────────────────
RESP=\$(curl -sf --max-time 5 -X POST "http://localhost:\${RPC_PORT}" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  2>/dev/null || true)

if [[ -n "\$RESP" ]]; then
  BLOCK=\$(echo "\$RESP" | grep -o '"result":"[^"]*"' | head -1 || echo "unknown")
  echo "\$TS [OK]   RPC up | \$BLOCK | disk \${DISK_USED}%"
else
  echo "\$TS [WARN] RPC not responding — restarting container..."
  docker compose restart gyds-litenode
fi
HEALTHSCRIPT

chmod +x /usr/local/bin/gyds-health

# Cron: every 5 minutes
(crontab -l 2>/dev/null | grep -v "gyds-health"; \
 echo "*/5 * * * * /usr/local/bin/gyds-health >> /var/log/gyds-health.log 2>&1") \
  | crontab -

log "Health check installed (every 5 min → /var/log/gyds-health.log, disk alert at ${DISK_WARN_PCT}%)."

############################################
# UPDATE SCRIPT
############################################

step "Update script"

cat > /usr/local/bin/gyds-update <<UPDATESCRIPT
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR}"
APP_USER="${APP_USER}"
BRANCH="${BRANCH}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "\${GREEN}[OK]\${NC}   \$1"; }
info() { echo -e "\${CYAN}[INFO]\${NC} \$1"; }

if [[ "\$EUID" -ne 0 ]]; then
  echo "Run as root: sudo gyds-update"
  exit 1
fi

info "Pulling latest code from ${BRANCH}..."
git -C "\$APP_DIR" fetch origin
git -C "\$APP_DIR" reset --hard "origin/${BRANCH}"
chown -R "\${APP_USER}:\${APP_USER}" "\$APP_DIR"
log "Code updated."

info "Rebuilding Docker image..."
cd "\$APP_DIR"
docker compose down
docker compose build --no-cache
docker compose up -d
log "Container restarted with new image."

info "Verifying RPC..."
sleep 5
if curl -sf --max-time 5 -X POST "http://localhost:${RPC_PORT}" \
   -H "Content-Type: application/json" \
   --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
   | grep -q '"result"'; then
  log "Node is up and responding."
else
  echo "[WARN] Node did not respond yet — check: docker compose logs -f"
fi

echo ""
echo "Update complete. Run 'gyds-health' to check status."
UPDATESCRIPT

chmod +x /usr/local/bin/gyds-update
log "gyds-update installed — run: sudo gyds-update"

############################################
# POST-SETUP VERIFICATION
############################################

step "Post-setup verification"
sleep 3

RPC_OK=false
HTTP_OK=false

if curl -sf --max-time 5 -X POST "http://localhost:${RPC_PORT}" \
   -H "Content-Type: application/json" \
   --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
   | grep -q '"result"'; then
  log "Direct RPC (port ${RPC_PORT}): OK"
  RPC_OK=true
else
  warn "Direct RPC (port ${RPC_PORT}): not responding yet"
fi

if curl -sf --max-time 5 http://localhost/health | grep -q '"status"'; then
  log "Nginx proxy (port 80 → /health): OK"
  HTTP_OK=true
else
  warn "Nginx proxy (port 80): not responding yet"
fi

[[ "$RPC_OK" == "false" && "$HTTP_OK" == "false" ]] \
  && warn "Node may still be starting — check: cd ${APP_DIR} && docker compose logs -f"

############################################
# FINAL SUMMARY
############################################

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          GYDS LITENODE — DEPLOYED                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Chain ID:    13370 (GYDS Chain) | mode: lite"
echo ""
if [[ -n "$DOMAIN" ]]; then
echo "  JSON-RPC:    https://${DOMAIN}             (HTTPS)"
echo "  WebSocket:   wss://${DOMAIN}/api/ws        (WSS)"
fi
echo "  JSON-RPC:    http://${SERVER_IP}:${RPC_PORT}"
echo "  WebSocket:   ws://${SERVER_IP}:${WS_PORT}"
echo "  P2P:         tcp://${SERVER_IP}:${P2P_PORT}"
echo "  Via Nginx:   http://${SERVER_IP}   (port 80)"
echo ""
echo "  ── Node management ──────────────────────────────"
echo "  Logs:        cd ${APP_DIR} && docker compose logs -f"
echo "  Status:      docker compose ps"
echo "  Health:      gyds-health"
echo "  Update:      sudo gyds-update"
echo "  Restart:     cd ${APP_DIR} && docker compose restart"
echo ""
echo "  ── Security ─────────────────────────────────────"
echo "  Firewall:    ufw status"
echo "  Fail2Ban:    fail2ban-client status"
echo "  Auth log:    journalctl -u fail2ban -f"
echo ""
echo "  ── Quick RPC test ───────────────────────────────"
echo "  curl -X POST http://${SERVER_IP}:${RPC_PORT} \\"
echo '    -H "Content-Type: application/json" \'
echo '    --data '"'"'{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'"'"
echo ""
echo "  ── Switch to native binary (no Docker) ──────────"
echo "  cd ${APP_DIR} && docker compose down"
echo "  systemctl enable --now gyds-litenode"
echo "  journalctl -u gyds-litenode -f"
echo ""
