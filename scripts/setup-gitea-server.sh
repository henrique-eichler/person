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

COMPOSE_DIR="$HOME/Projects/projects/gitea"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/gitea.infra.$DOMAIN.conf"
DNS_SH="$HOME/Projects/projects/dns/dns.sh"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/nginx-root.crt"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM gitea/gitea:1.24.5

  USER root

  # Copy your Root CA (PEM). Keep your compose build context at the *project root*.
  COPY certs/nginx-root.crt /usr/local/share/ca-certificates/nginx-root.crt

  # Install CA bundle and update system trust store used by Go, curl, git, etc.
  RUN apk add --no-cache ca-certificates && update-ca-certificates"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating docker-compose.yml"
write "$COMPOSE_FILE" "
  services:
    gitea:
      build: .
      container_name: gitea
      restart: unless-stopped
      environment:
        - TZ=UTC
        # Server / URLs
        - GITEA__server__ROOT_URL=https://gitea.infra.${DOMAIN}/
        - GITEA__server__DOMAIN=gitea.infra.${DOMAIN}
        - GITEA__server__HTTP_PORT=3000
        - GITEA__server__START_SSH_SERVER=true
        - GITEA__server__SSH_LISTEN_PORT=222
        - GITEA__server__SSH_PORT=222
        - GITEA__server__SSH_DOMAIN=gitea.infra.${DOMAIN}

        # Database (external Postgres container, aliased as 'postgres')
        - GITEA__database__DB_TYPE=postgres
        - GITEA__database__HOST=postgres:5432
        - GITEA__database__NAME=giteadb
        - GITEA__database__USER=gitea
        - GITEA__database__PASSWD=giteapwd

        # Metrics (optional)
        - GITEA__metrics__ENABLED=true
        - GITEA__metrics__TOKEN=0fe83b89-8131-47b3-86d3-b4f1ad25b3b9

        # Webhooks (allow Docker bridge subnet; adjust if needed)
        - GITEA__webhook__ALLOWED_HOST_LIST=*

        # File owner inside container
        - USER_UID=1000
        - USER_GID=1000
      # Publish SSH on host :222, keep HTTP internal (reverse-proxied by Nginx)
      ports:
        - '222:222'
      volumes:
        - gitea-data:/data
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  volumes:
    gitea-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Create Nginx configuration for gitea.infra.$DOMAIN ----------------------------
log "Creating Nginx vhost: $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS for gitea.infra.$DOMAIN
  server {
    listen 80;
    listen [::]:80;
    server_name gitea.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for gitea.infra.$DOMAIN
  server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name gitea.infra.$DOMAIN;

    # Using the SAN self-signed cert from your nginx setup (includes gitea.infra.$DOMAIN)
    ssl_certificate     /etc/nginx/certs/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/certs/$DOMAIN.key;

    client_max_body_size 512M;

    location / {
      proxy_http_version 1.1;
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header Upgrade           \$http_upgrade;
      proxy_set_header Connection        \"upgrade\";
      proxy_pass http://gitea:3000;
    }
  }"

# --- Ensure Docker network exists ---------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Gitea -------------------------------------------------------------
log "Starting Gitea container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 222)"
sudo ufw allow 222/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Summary ------------------------------------------------------------------
info
info "Gitea setup completed."
info "  • Web UI : https://gitea.infra.$DOMAIN"
info "  • SSH    : ssh://git@gitea.infra.$DOMAIN:222"
info "  • Compose: $COMPOSE_FILE"
