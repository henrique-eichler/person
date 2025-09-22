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

COMPOSE_DIR="$HOME/Projects/projects/grafana"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

PROVISIONING_DIR="$COMPOSE_DIR/provisioning"
PROMETHEUS_YML="$PROVISIONING_DIR/prometheus.yml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/grafana.infra.$DOMAIN.conf"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    grafana:
      image: grafana/grafana:latest
      container_name: grafana
      restart: unless-stopped
      environment:
        GF_SECURITY_ADMIN_USER: grafana
        GF_SECURITY_ADMIN_PASSWORD: grafanapwd
        GF_USERS_ALLOW_SIGN_UP: 'false'
        GF_SERVER_ROOT_URL: https://grafana.infra.$DOMAIN
        GF_SERVER_SERVE_FROM_SUB_PATH: 'true'
      volumes:
        - grafana-data:/var/lib/grafana
        - ./provisioning:/etc/grafana/provisioning
      networks:
        - $NETWORK_NAME

  volumes:
    grafana-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Create Prometheus datasource --------------------------------------------
log "Provisioning Prometheus datasource"
append "$PROMETHEUS_YML" "
  apiVersion: 1
  deleteDatasources:
    - name: Prometheus
      orgId: 1
  datasources:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus.infra.$DOMAIN:9090
      isDefault: true
      editable: false"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name grafana.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Grafana
  server {
    listen 443 ssl http2;
    server_name grafana.infra.$DOMAIN;

    # Certs & common TLS settings
    include /etc/nginx/conf.d/ssl.inc;

    # Grafana defaults to 3000 in the container
    location / {
      proxy_http_version 1.1;

      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  \$server_port;

      # keep auth headers for auth proxies if ever used
      proxy_set_header Authorization     \$http_authorization;

      # do not downgrade connection semantics
      proxy_set_header Connection \"\";

      proxy_pass http://grafana:3000;
    }
  }"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '${NETWORK_NAME}'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Grafana ----------------------------------------------------------
log "Starting Grafana container"
cd "$COMPOSE_DIR"
docker compose up -d

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi
# --- Summary ------------------------------------------------------------------
info
info "Grafana setup complete"
info "  • URL      : https://grafana.infra.$DOMAIN"
info "  • Username : grafana"
info "  • Password : grafanapwd"
