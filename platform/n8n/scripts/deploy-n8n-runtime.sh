#!/usr/bin/env bash
set -euo pipefail

log() { printf '[deploy-n8n-runtime][%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || fatal "Missing required environment variable: ${name}"
}

require_env N8N_DOMAIN
require_env TLS_EMAIL
require_env N8N_ENCRYPTION_KEY
require_env POSTGRES_PASSWORD

N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.8-alpine}"
N8N_TIMEZONE="${N8N_TIMEZONE:-Europe/Budapest}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
POSTGRES_USER="${POSTGRES_USER:-n8n}"
RUNTIME_DIR="${RUNTIME_DIR:-/srv/n8n}"
N8N_CONTAINER_UID="${N8N_CONTAINER_UID:-1000}"
N8N_CONTAINER_GID="${N8N_CONTAINER_GID:-1000}"
SOURCE_DIR="${SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

[[ "$N8N_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "N8N_DOMAIN contains unsupported characters"
[[ "$TLS_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fatal "TLS_EMAIL does not look like an email address"
[ -f "${SOURCE_DIR}/templates/docker-compose.yml.tpl" ] || fatal "Missing docker-compose template under ${SOURCE_DIR}"
[ -f "${SOURCE_DIR}/templates/Caddyfile.tpl" ] || fatal "Missing Caddyfile template under ${SOURCE_DIR}"

log "Deploying standalone n8n runtime domain=${N8N_DOMAIN} runtime_dir=${RUNTIME_DIR}"

export DEBIAN_FRONTEND=noninteractive

apt_has_package() {
  local package_name="$1"
  apt-cache show "$package_name" >/dev/null 2>&1
}

install_docker_official_repository() {
  local arch
  local codename

  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"

  log "Adding Docker official apt repository for ${codename}/${arch}"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.list <<EOF
# Managed by PlatformInit n8n runtime bootstrap
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

  apt-get update
}

install_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose already installed: $(docker compose version)"
    return 0
  fi

  log "Installing Docker Compose v2"
  apt-get update

  if apt_has_package docker-compose-v2; then
    apt-get install -y docker-compose-v2
  elif apt_has_package docker-compose-plugin; then
    apt-get install -y docker-compose-plugin
  else
    install_docker_official_repository
    apt-get install -y docker-compose-plugin
  fi

  docker compose version >/dev/null 2>&1 || fatal "docker compose plugin is not available after installation"
}

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine from Ubuntu packages"
  apt-get update
  apt-get install -y ca-certificates curl gnupg docker.io
else
  log "Docker already installed: $(docker --version)"
  apt-get update
  apt-get install -y ca-certificates curl gnupg
fi

install_compose_v2
systemctl enable --now docker

install -d -m 0750 "${RUNTIME_DIR}"
install -d -m 0750 "${RUNTIME_DIR}/data" "${RUNTIME_DIR}/postgres" "${RUNTIME_DIR}/caddy-data" "${RUNTIME_DIR}/caddy-config"

# The official n8n image runs the application as the non-root node user
# (UID/GID 1000). The bind-mounted data directory must be writable by that
# user; otherwise the container enters a restart loop before port 5678 opens.
log "Ensuring n8n data directory ownership uid=${N8N_CONTAINER_UID} gid=${N8N_CONTAINER_GID}"
chown -R "${N8N_CONTAINER_UID}:${N8N_CONTAINER_GID}" "${RUNTIME_DIR}/data"
chmod 0700 "${RUNTIME_DIR}/data"

umask 077
cat > "${RUNTIME_DIR}/.env" <<ENVEOF
N8N_DOMAIN=${N8N_DOMAIN}
N8N_TIMEZONE=${N8N_TIMEZONE}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ENVEOF

sed \
  -e "s#__N8N_IMAGE__#${N8N_IMAGE}#g" \
  -e "s#__POSTGRES_IMAGE__#${POSTGRES_IMAGE}#g" \
  -e "s#__CADDY_IMAGE__#${CADDY_IMAGE}#g" \
  "${SOURCE_DIR}/templates/docker-compose.yml.tpl" > "${RUNTIME_DIR}/docker-compose.yml"

sed \
  -e "s#__N8N_DOMAIN__#${N8N_DOMAIN}#g" \
  -e "s#__TLS_EMAIL__#${TLS_EMAIL}#g" \
  "${SOURCE_DIR}/templates/Caddyfile.tpl" > "${RUNTIME_DIR}/Caddyfile"

chmod 0600 "${RUNTIME_DIR}/.env"
chmod 0640 "${RUNTIME_DIR}/docker-compose.yml" "${RUNTIME_DIR}/Caddyfile"

cat > /etc/systemd/system/platforminit-n8n-runtime.service <<SERVICEEOF
[Unit]
Description=PlatformInit standalone n8n runtime
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${RUNTIME_DIR}
ExecStart=/usr/bin/docker compose --env-file ${RUNTIME_DIR}/.env -f ${RUNTIME_DIR}/docker-compose.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose --env-file ${RUNTIME_DIR}/.env -f ${RUNTIME_DIR}/docker-compose.yml down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable platforminit-n8n-runtime.service

if command -v ufw >/dev/null 2>&1; then
  log "Ensuring UFW allows HTTP/HTTPS"
  ufw allow 80/tcp comment 'PlatformInit n8n Caddy HTTP' >/dev/null || true
  ufw allow 443/tcp comment 'PlatformInit n8n Caddy HTTPS' >/dev/null || true
fi

log "Pulling and starting containers"
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" pull
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" up -d --remove-orphans

log "Runtime status"
docker compose --env-file "${RUNTIME_DIR}/.env" -f "${RUNTIME_DIR}/docker-compose.yml" ps

log "n8n deployment completed. First login/owner setup is handled by n8n WebUI at https://${N8N_DOMAIN}/"
