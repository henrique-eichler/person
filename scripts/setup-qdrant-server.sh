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

COMPOSE_DIR="$HOME/Projects/projects/qdrant"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
services:
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    ports:
      - '6333:6333'
    volumes:
      - qdrant-data:/qdrant/storage
    networks:
      - $NETWORK_NAME

volumes:
  qdrant-data:

networks:
  $NETWORK_NAME:
    external: true"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch qDrant ----------------------------------------------------------
log "Starting qDrant container"
cd "$COMPOSE_DIR"
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 6333)"
sudo ufw allow 6333/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info "Qdrant server (docker-compose) is ready."
info "  • Service: qdrant.$DOMAIN"
info "  • Port: 6333"
