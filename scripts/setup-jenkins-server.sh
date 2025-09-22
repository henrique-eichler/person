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

COMPOSE_DIR="$HOME/Projects/projects/jenkins"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

CASC_DIR="$COMPOSE_DIR/casc"
JENKINS_YML="$CASC_DIR/jenkins.yaml"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/jenkins.infra.$DOMAIN.conf"
DNS_SH="$HOME/Projects/projects/dns/dns.sh"

DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/nginx-root-ca.crt"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" "
  FROM jenkins/jenkins:2.528

  USER root

  # Copy your *root* CA (PEM). Keep your compose build context at the project root so this path exists.
  COPY certs/nginx-root-ca.crt /usr/local/share/ca-certificates/nginx-root.crt

  # Make sure OS certs are updated (not strictly required for Java, but good hygiene)
  RUN apt-get update && \
      apt-get install -y --no-install-recommends ca-certificates && \
      update-ca-certificates && \
      rm -rf /var/lib/apt/lists/*

  # Install Docker CLI
  RUN curl -fsSL https://get.docker.com | sh

  # Ensure docker group exists and has the correct GID
  RUN if getent group docker; then \
          groupmod -g ${DOCKER_GID} docker; \
      else \
          groupadd -g ${DOCKER_GID} docker; \
      fi \
      && usermod -aG docker jenkins

  # Import the CA into Java's truststore used by Jenkins.
  # -cacerts targets the default JVM cacerts file; 'changeit' is the default password.
  RUN keytool -importcert -trustcacerts \
      -alias nginx-root \
      -file /usr/local/share/ca-certificates/nginx-root.crt \
      -cacerts -storepass changeit -noprompt || true

  RUN jenkins-plugin-cli --plugins \"prometheus configuration-as-code\"

  USER jenkins"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating $COMPOSE_FILE"
write "$COMPOSE_FILE" "
  services:
    jenkins:
      build: .
      container_name: jenkins
      restart: unless-stopped
      volumes:
        - jenkins-data:/var/jenkins_home
        - /var/run/docker.sock:/var/run/docker.sock
        - ./casc:/var/jenkins_home/casc
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  volumes:
    jenkins-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Create casc/jenkins.yaml ----------------------------------------------
log "Creating $JENKINS_YML"
write "$JENKINS_YML" "
  unclassified:
    prometheusConfiguration:
      path: \"prometheus\"
      useAuthenticatedEndpoint: true
      collectingMetricsPeriodInSeconds: 120
      collectDiskUsage: true
      fetchTestResults: true
      perBuildMetrics: false"

# --- Create nginx configuration ----------------------------------------------
log "Creating $SUBDOMAIN_CONF"
write "$SUBDOMAIN_CONF" "
  # HTTP -> HTTPS
  server {
    listen 80;
    listen [::]:80;
    server_name jenkins.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS vhost for Jenkins
  server {
    listen 443 ssl http2;
    server_name jenkins.infra.$DOMAIN;

    # Certs & common TLS settings
    include /etc/nginx/conf.d/ssl.inc;

    # Large uploads + CI logs/streams
    client_max_body_size    2G;
    proxy_request_buffering off;
    proxy_buffering         off;
    proxy_read_timeout      1d;
    proxy_send_timeout      1d;
    proxy_connect_timeout   60s;

    # Main Jenkins app
    location / {
      proxy_http_version 1.1;

      # Forward original host/scheme so Jenkins generates correct URLs
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  \$server_port;

      # If you ever run Jenkins behind a path (e.g., /jenkins), also add:
      # proxy_set_header X-Forwarded-Prefix /jenkins;

      # Keep auth headers for webhooks / API tokens
      proxy_set_header Authorization     \$http_authorization;

      # Don’t let proxies downgrade connection semantics
      proxy_set_header Connection \"\";

      proxy_pass http://jenkins:8080;
    }

    # WebSocket upgrade (e.g., Blue Ocean, SSE / /ws/)
    location /ws/ {
      proxy_http_version 1.1;
      proxy_set_header Upgrade           \$http_upgrade;
      proxy_set_header Connection        \"upgrade\";
      proxy_set_header Host              \$host;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_read_timeout 1d;
      proxy_pass http://jenkins:8080;
    }

    # Optional: cache Jenkins static assets to reduce load
    location ~* ^/(static|adjuncts|assets)/ {
      expires 1h;
      add_header Cache-Control \"public\";
      proxy_pass http://jenkins:8080;
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

# --- Reload Nginx if running --------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx nginx; then
  log "Reloading Nginx"
  docker exec nginx nginx -s reload &> /dev/null
fi

# --- Obtain initial admin password -------------------------------------------
PASSWORD="$(while ! docker exec -it jenkins cat /var/jenkins_home/secrets/initialAdminPassword &> /dev/null; do sleep 1; done; docker exec -it jenkins cat /var/jenkins_home/secrets/initialAdminPassword)"

# --- Summary -----------------------------------------------------------------
info
info "Jenkins setup complete"
info "  • Web UI : https://jenkins.infra.$DOMAIN/"
info "  • Config password: $PASSWORD"
