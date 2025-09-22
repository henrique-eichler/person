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

COMPOSE_DIR="$HOME/Projects/projects/prometheus"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
PROMETHEUS_YML="$COMPOSE_DIR/prometheus.yml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/prometheus.infra.$DOMAIN.conf"
DNS_SH="$HOME/Projects/projects/dns/dns.sh"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/nginx-root.crt"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE..."
write "$COMPOSE_FILE" "
  services:
    prometheus:
      image: prom/prometheus:v3.5.0
      container_name: prometheus
      restart: unless-stopped
      command:
        - --config.file=/etc/prometheus/prometheus.yml
        - --web.external-url=https://prometheus.infra.$DOMAIN/
        - --web.route-prefix=/
      volumes:
        - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
        - ./certs/nginx-root.crt:/etc/prometheus/ca/root-ca.crt:ro
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  networks:
    $NETWORK_NAME:
      external: true"

# --- Create prometheus.yml --------------------------------------------------
log "Creating $PROMETHEUS_YML..."
write "$PROMETHEUS_YML" "
  global:
    scrape_interval: 15s

  scrape_configs:
    - job_name: 'prometheus'
      static_configs:
        - targets: ['prometheus:9090']

    - job_name: 'node-exporter'
      static_configs:
        - targets:
            - 'avell:9100'
            - 'senado:9100'
            - 'saneago:9100'
            - 'treinamento:9100'
            - 'thinkpad:9100'
            - 'vaio:9100'

    - job_name: 'registry'
      static_configs:
        - targets: ['registry:5001']
      metrics_path: /metrics

    - job_name: 'nexus'
      scheme: https
      metrics_path: /service/metrics/prometheus
      static_configs:
        - targets: ['nexus.infra.$DOMAIN:443']
      tls_config:
        ca_file: /etc/prometheus/ca/root-ca.crt
        server_name: nexus.infra.$DOMAIN
      basic_auth:
        username: prometheus
        password: prometheuspwd

    - job_name: 'gitea'
      scheme: https
      metrics_path: /metrics
      bearer_token: 0fe83b89-8131-47b3-86d3-b4f1ad25b3b9
      static_configs:
        - targets: ['gitea.infra.$DOMAIN:443']
      tls_config:
        ca_file: /etc/prometheus/ca/root-ca.crt
        server_name: gitea.infra.$DOMAIN

    - job_name: 'jenkins'
      scheme: https
      metrics_path: /prometheus/
      static_configs:
        - targets: ['jenkins.infra.$DOMAIN:443']
      tls_config:
        ca_file: /etc/prometheus/ca/root-ca.crt
        server_name: jenkins.infra.$DOMAIN

    - job_name: 'keycloak'
      metrics_path: /metrics
      static_configs:
        - targets: ['keycloak:9000']
      tls_config:
        ca_file: /etc/prometheus/ca/root-ca.crt
        server_name: keycloak.infra.$DOMAIN"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name prometheus.infra.$DOMAIN;
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Prometheus UI
  server {
    listen 443 ssl http2;
    server_name prometheus.infra.$DOMAIN;

    include /etc/nginx/conf.d/ssl.inc;

    # Proxy Prometheus
    location / {
      proxy_http_version 1.1;
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;

      proxy_pass http://prometheus:9090;
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
docker compose up -d

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Final message ----------------------------------------------------------
info
info "Prometheus setup completed."
info "  • Web UI        : https://prometheus.infra.$DOMAIN"
