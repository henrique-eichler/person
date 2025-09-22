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

COMPOSE_DIR="$HOME/Projects/projects/keycloak"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/keycloak.infra.$DOMAIN.conf"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/$DOMAIN.root-ca.crt"

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM quay.io/keycloak/keycloak:latest

  USER root
  COPY certs/$DOMAIN.root-ca.crt /tmp/nginx-root.crt

  # Import the CA into Java's default truststore (used by Keycloak)
  RUN keytool -importcert -trustcacerts \
      -alias nginx-root \
      -file /tmp/nginx-root.crt \
      -cacerts -storepass changeit -noprompt || true

  USER keycloak"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
services:
  keycloak:
    build: .
    container_name: keycloak
    restart: unless-stopped
    environment:
      - KC_BOOTSTRAP_ADMIN_USERNAME=keycloak
      - KC_BOOTSTRAP_ADMIN_PASSWORD=keycloakpwd
      - KC_HOSTNAME=https://keycloak.infra.${DOMAIN}
      - KC_HTTP_ENABLED=true
      - KC_PROXY_HEADERS=xforwarded
      # Observability  
      - KC_METRICS_ENABLED=true
      - KC_HEALTH_ENABLED=true
      - KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true
      - KC_HTTP_MANAGEMENT_PORT=9000
    command:
      - start-dev
      - '--metrics-enabled=true'
    volumes:
      - keycloak-data:/opt/keycloak/data
    networks:
      - $NETWORK_NAME

volumes:
  keycloak-data:

networks:
  $NETWORK_NAME:
    external: true"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name keycloak.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Keycloak
  server {
    listen 443 ssl;
    http2 on;
    server_name keycloak.infra.${DOMAIN};

    # Certs & common TLS settings
    include /etc/nginx/conf.d/ssl.inc;

    client_max_body_size    2G;
    proxy_request_buffering off;
    proxy_buffering         off;
    proxy_read_timeout      1d;
    proxy_send_timeout      1d;
    proxy_connect_timeout   60s;

    location / {
      proxy_http_version 1.1;
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  443;
      proxy_set_header Connection        \"\";
      proxy_pass http://keycloak:8080;
    }
  }"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Keycloak ----------------------------------------------------------
log "Starting Keycloak container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Summary -----------------------------------------------------------------
info
info "Keycloak setup complete"
info "  • Admin console : https://keycloak.infra.$DOMAIN"
info "  • Admin user    : keycloak"
info "  • Admin password: keycloakpwd"