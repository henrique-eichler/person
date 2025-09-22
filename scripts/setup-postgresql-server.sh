#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 4 ]]; then
  error "Usage: $0 <domain> <database> <user> <password>"
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
DB_NAME="$2"
DB_USER="$3"
DB_PASS="$4"
NETWORK_NAME="internal_net"

COMPOSE_DIR="$HOME/Projects/projects/postgres"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

# --- Create docker-compose.yml ---------------------------------------------
log "Writing $COMPOSE_FILE..."
write "$COMPOSE_FILE" "
  services:
    postgres:
      image: postgres:16
      container_name: postgres
      restart: unless-stopped
      environment:
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgrespwd
      volumes:
        - postgres-data:/var/lib/postgresql/data
      ports:
        - '5432:5432'
      networks:
        - $NETWORK_NAME

  volumes:
    postgres-data:

  networks:
    $NETWORK_NAME:
      external: true"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Jenkins ----------------------------------------------------------
log "Starting Jenkins container"
cd "$COMPOSE_DIR"
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 5432)"
sudo ufw allow 5432/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Wait for PostgreSQL container to become healthy -------------------------
info "Waiting for PostgreSQL container to be healthy..."
RETRIES=30
until docker exec postgres pg_isready -U postgres >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  info "Waiting... ($RETRIES retries left)"
  sleep 1
  ((RETRIES--))
done

if [ $RETRIES -eq 0 ]; then
  error "PostgreSQL container did not become ready in time."
fi
info "PostgreSQL is ready."

# --- Ensure user exists -----------------------------------------------------
log "Ensuring user '$DB_USER' exists"
docker exec -u postgres postgres psql -v ON_ERROR_STOP=1 -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS'; END IF; END \$\$;"

# --- Ensure database exists -------------------------------------------------
log "Checking if database '$DB_NAME' exists"
DB_EXISTS=$(docker exec -u postgres postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" postgres)
if [[ "$DB_EXISTS" != "1" ]]; then
  log "Creating database '$DB_NAME' owned by '$DB_USER'"
  docker exec -u postgres postgres psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
fi

# --- Summary ----------------------------------------------------------------
info
info "[done] PostgreSQL setup complete"
info
info " • Container name  : postgres"
info " • Database name   : $DB_NAME"
info " • Username        : $DB_USER"
info " • Password        : $DB_PASS"
info " • Port            : 5432"
info " • Connection URL  : postgres://$DB_USER:$DB_PASS@postgres.infra.$DOMAIN:5432/$DB_NAME"
