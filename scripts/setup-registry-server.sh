#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

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
USERNAME="henrique"
PASSWORD="secret"

COMPOSE_DIR="$HOME/Projects/projects/registry"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
REGISTRY_CONFIG="$COMPOSE_DIR/config.yml"
REALM_BCRYPT="$COMPOSE_DIR/auth/htpasswd"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/registry.infra.$DOMAIN.conf"
DNS_SH="$HOME/Projects/projects/dns/dns.sh"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/nginx-root-ca.crt"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM registry:2"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    registry:
      build: .
      container_name: registry
      restart: unless-stopped
      environment:
        - REGISTRY_LOG_LEVEL=info
      volumes:
        - registry-data:/var/lib/registry
        - ./config.yml:/etc/docker/registry/config.yml:ro
        - ./auth:/auth:ro
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  volumes:
    registry-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Create realm password -------------------------------------------------------
log "Creating $REALM_BCRYPT..."
mkdir -p "$COMPOSE_DIR/auth/" 
docker run --rm --entrypoint htpasswd httpd:2 -Bbn "$USERNAME" "$PASSWORD" > "$REALM_BCRYPT"

# --- Create config file -------------------------------------------------------
log "Creating $REGISTRY_CONFIG..."
write "$REGISTRY_CONFIG" "
  version: 0.1

  log:
    fields:
      service: registry

  storage:
    filesystem:
      rootdirectory: /var/lib/registry
    delete:
      enabled: true

  http:
    addr: :5000
    headers:
      X-Content-Type-Options: [nosniff]
    debug:
      addr: :5001

  prometheus:
    enabled: true
    path: /metrics

  auth:
    htpasswd:
      realm: 'Registry Realm'
      path: auth/htpasswd"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name registry.infra.$DOMAIN;

    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Docker Registry v2
  server {
    listen 443 ssl http2;
    server_name registry.infra.$DOMAIN;

    include /etc/nginx/conf.d/ssl.inc;

    client_max_body_size    0;
    proxy_request_buffering off;
    proxy_buffering         off;
    proxy_read_timeout      900;
    proxy_send_timeout      900;
    proxy_connect_timeout   60s;

    location = / { return 301 /v2/; }

    location /v2/ {
      proxy_http_version 1.1;

      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;

      add_header Docker-Distribution-Api-Version \"registry/2.0\" always;

      # helps with large layer uploads on some setups
      chunked_transfer_encoding on;

      proxy_pass http://registry:5000;
    }
  }"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Registry ---------------------------------------------------------
log "Starting Registry container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- Configure Docker on host to recognize this registry ---------------------
sudo mkdir -p "/etc/docker/certs.d/registry.infra.$DOMAIN"
sudo cp "$COMPOSE_DIR/certs/nginx-root-ca.crt" "/etc/docker/certs.d/registry.infra.$DOMAIN/ca.crt"
sudo chmod 0644 "/etc/docker/certs.d/registry.infra.$DOMAIN/ca.crt"
sudo systemctl restart docker

# --- Reload Nginx if running -------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Summary -----------------------------------------------------------------
info
info "Docker Registry setup complete"
info
info "  • Service name     : registry"
info "  • Access locally   : https://registry.infra.$DOMAIN/v2/_catalog"
