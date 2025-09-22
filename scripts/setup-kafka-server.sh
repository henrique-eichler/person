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

COMPOSE_DIR="$HOME/Projects/projects/kafka"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    zookeeper:
      image: bitnami/zookeeper:3.8
      container_name: zookeeper
      # ports:
        # - '2181:2181'
      environment:
        - ALLOW_ANONYMOUS_LOGIN=yes
      restart: unless-stopped
      volumes:
        - zookeeper-data:/bitnami
      networks:
        - $NETWORK_NAME

    kafka:
      image: bitnami/kafka:3.4
      container_name: kafka
      ports:
        - '9092:9092'
      environment:
        - KAFKA_CFG_ZOOKEEPER_CONNECT=zookeeper:2181
        - KAFKA_CFG_LISTENERS=PLAINTEXT://0.0.0.0:9092
        - KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://kafka.$DOMAIN:9092
        - KAFKA_CFG_BROKER_ID=1
        - ALLOW_PLAINTEXT_LISTENER=yes
      depends_on:
        - zookeeper
      restart: unless-stopped
      volumes:
        - kafka-data:/bitnami
      networks:
        - $NETWORK_NAME

  volumes:
    zookeeper-data:
    kafka-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Kafka ------------------------------------------------------------
log "Starting Kafka container"
cd "$COMPOSE_DIR"
docker compose up -d

# --- UFW rules (safe) --------------------------------------------------------
log "Configuring UFW (allow 9092)"
sudo ufw allow 9092/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info
info "[done] Kafka and Zookeeper setup complete"
info "  • Kafka      : PLAINTEXT://kafka.$DOMAIN:9092"
