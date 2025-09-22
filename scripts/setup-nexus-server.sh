#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 1 ]]; then
  error "Usage: $0 <domain>"
fi

# --- Require not root privileges --------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker "docker compose" ufw; do
  if ! $cmd version &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
NETWORK_NAME="internal_net"

COMPOSE_DIR="$HOME/Projects/projects/nexus"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
NEXUS_PROP="$COMPOSE_DIR/nexus.properties"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/nexus.infra.$DOMAIN.conf"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/$DOMAIN.root-ca.crt"

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM sonatype/nexus3:3.78.3

  USER root

  COPY certs/$DOMAIN.root-ca.crt /tmp/nginx-root.crt
  RUN keytool -importcert -trustcacerts \
      -alias nginx-root \
      -file /tmp/nginx-root.crt \
      -cacerts -storepass changeit -noprompt || true

  USER nexus"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE..."
write "$COMPOSE_FILE" "
  services:
    nexus:
      build: .
      container_name: nexus
      restart: unless-stopped
      volumes:
        - nexus-data:/nexus-data
        - ./nexus.properties:/nexus-data/etc/nexus.properties:ro
      networks:
        - $NETWORK_NAME

  volumes:
    nexus-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Generate nexus.properties -----------------------------------------------
log "Creating $NEXUS_PROP..."
write "$NEXUS_PROP" "
  nexus.prometheus.enabled=true"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name nexus.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Nexus
  server {
    listen 443 ssl http2;
    server_name nexus.infra.$DOMAIN;

    # Using your existing self-signed bundle for $DOMAIN (SAN includes nexus.infra.$DOMAIN)
    include /etc/nginx/conf.d/ssl.inc;

    # Large artifacts/uploads
    client_max_body_size 2G;
    proxy_request_buffering off;
    proxy_read_timeout 900;
    proxy_connect_timeout 60;
    proxy_send_timeout 900;

    # --- Everything else (UI/REST/etc.) ---
    location / {
      proxy_http_version 1.1;
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  \$server_port;

      # Authorization header (safe pass-through)
      proxy_set_header Authorization     \$http_authorization;
      proxy_pass http://nexus:8081;
    }
  }"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Jenkins ----------------------------------------------------------
log "Starting Jenkins container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 5001)"
sudo ufw allow 5001/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Obtain password from inside container -----------------------------------
PASSWORD="$(while ! docker exec -it nexus cat /nexus-data/admin.password &> /dev/null; do sleep 1; done; docker exec -it nexus cat /nexus-data/admin.password)"

# --- Summary -----------------------------------------------------------------
info
info "Nexus setup complete"
info "  • Web UI        : https://nexus.infra.$DOMAIN"
info "  • Username      : admin"
info "  • Password      : $PASSWORD"
