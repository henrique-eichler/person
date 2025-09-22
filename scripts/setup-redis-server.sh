#!/usr/bin/env bash
set -eo pipefail
source "$HOME/Projects/tools/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 1 ]]; then
  error "Usage: $0 <domain>"
fi

# --- Require not root privileges ---------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker "docker compose" ufw openssl; do
  if ! $cmd version &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
NETWORK_NAME="internal_net"

COMPOSE_DIR="$HOME/Projects/projects/redis"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    redis:
      image: redis:7.2
      container_name: redis
      ports:
        - '6379:6379'
      restart: unless-stopped
      volumes:
        - redis-data:/data
      command: [ 'redis-server', '--appendonly', 'yes' ]
      networks:
        - $NETWORK_NAME

  volumes:
    redis-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Redis -----------------------------------------------------------
log "Starting Redis container"
cd "$COMPOSE_DIR"
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 6379)"
sudo ufw allow 6379/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info
info "Redis setup complete"
info "  • Service      : redis.$DOMAIN"
info "  • Port         : 6379"
