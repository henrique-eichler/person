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

COMPOSE_DIR="$HOME/Projects/projects/rancher"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/rancher.infra.$DOMAIN.conf"
APPS_MODEL="$HOME/Projects/projects/nginx/subdomains/app.$DOMAIN.conf.model"
DNS_SH="$HOME/Projects/projects/dns/dns.sh"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/fullchain.pem" "$COMPOSE_DIR/certs/"
cp "$COMPOSE_DIR/../certs/privkey.pem" "$COMPOSE_DIR/certs/"
cp "$COMPOSE_DIR/../certs/cacerts.pem" "$COMPOSE_DIR/certs/"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM rancher/rancher:latest

  USER root

  # Copy your *root* CA (PEM). Keep your compose build context at the project root so this path exists.
  COPY certs/root-ca.crt /usr/local/share/ca-certificates/nginx-root.crt

  # Make sure OS certs are updated (not strictly required for Java, but good hygiene)
  RUN apt-get update && \
      apt-get install -y --no-install-recommends ca-certificates && \
      update-ca-certificates && \
      rm -rf /var/lib/apt/lists/*

  # Import the CA into Java's truststore used by Jenkins.
  # -cacerts targets the default JVM cacerts file; 'changeit' is the default password.
  RUN keytool -importcert -trustcacerts \
      -alias nginx-root \
      -file /usr/local/share/ca-certificates/nginx-root.crt \
      -cacerts -storepass changeit -noprompt || true

  USER rancher"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    rancher:
      container_name: rancher
      image: rancher/rancher:latest
      restart: unless-stopped
      privileged: true
      environment:
        - CATTLE_SERVER_URL=https://rancher.infra.$DOMAIN
        - SSL_CERT_DIR=/etc/rancher/ssl
      volumes:
        - rancher-data:/var/lib/rancher
        - /var/run/docker.sock:/var/run/docker.sock
        - ./certs/fullchain.pem:/etc/rancher/ssl/cert.pem:ro
        - ./certs/privkey.pem:/etc/rancher/ssl/key.pem:ro
        - ./certs/cacerts.pem:/etc/rancher/ssl/cacerts.pem:ro
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  volumes:
    rancher-data:

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
    server_name rancher.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Rancher
  server {
    listen 443 ssl http2;
    server_name rancher.infra.$DOMAIN;

    include /etc/nginx/conf.d/ssl.inc;

    client_max_body_size 0;
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;

    location / {
      proxy_http_version 1.1;

      # keep original host/proto for Rancher and kubectl
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  443;

      # websockets/exec
      proxy_set_header Upgrade           \$http_upgrade;
      proxy_set_header Connection        \$connection_upgrade;

      proxy_buffering         off;
      proxy_request_buffering off;

      # If Rancher uses your own CA/cert, disable verify while we test
      proxy_ssl_verify off;

      proxy_pass https://rancher:443;
    }
  }"

# --- Create generic apps nginx configuration ---------------------------------
log "Creating $APPS_MODEL"
write "$APPS_MODEL" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name <app-name>.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Rancher
  server {
    listen 443 ssl http2;
    server_name <app-name>.$DOMAIN;

    include /etc/nginx/conf.d/ssl.inc;

    client_max_body_size 0;
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;

    location / {
      proxy_http_version 1.1;

      # keep original host/proto for Rancher and kubectl
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  443;

      # websockets/exec
      proxy_set_header Upgrade           \$http_upgrade;
      proxy_set_header Connection        \$connection_upgrade;

      proxy_buffering         off;
      proxy_request_buffering off;

      # If Rancher uses your own CA/cert, disable verify while we test
      proxy_ssl_verify off;

      proxy_pass http://rancher:<node-port>;
    }
  }"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Rancher ----------------------------------------------------------
log "Starting Rancher container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null || true
fi

# --- Looks for bootstrap password (wait briefly if needed) --------------------
log "Fetching bootstrap password"
PASSWORD=""
for i in {1..20}; do
  PASSWORD="$(docker logs rancher 2>&1 | awk -F': ' '/Bootstrap Password:/ {print $2; exit}' || true)"
  [[ -n "$PASSWORD" ]] && break
  sleep 3
done

# --- Summary -----------------------------------------------------------------
info
info "Rancher setup completed."
info "  • Web UI        : https://rancher.infra.$DOMAIN"
info "  • Admin user    : admin"
info "  • Admin password: $PASSWORD"
