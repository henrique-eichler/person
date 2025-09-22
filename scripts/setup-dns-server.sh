#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 2 ]]; then
  error "Usage: $0 <domain> <dns-ip>"
fi

# --- Require not root privileges --------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0 <domain> <dns-ip>"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker "docker compose" ufw; do
  if ! $cmd version &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
HOST_IP="$2"
NETWORK_NAME="internal_net"
COMPOSE_DIR="$HOME/Projects/projects/dns"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
COREFILE="$COMPOSE_DIR/Corefile"
DNS_SH="$COMPOSE_DIR/dns.sh"

# --- Create dns.sh script to be used by others scripts ----------------------
log "Creating $DNS_SH"
write "$DNS_SH" "
  export DNS_IP=$HOST_IP
  export DOMAIN=$DOMAIN"

# --- Create docker-compose.yml ----------------------------------------------
log "Creating docker-compose.yml"
write "$COMPOSE_FILE" "
  services:
    dns:
      image: coredns/coredns:1.12.3
      container_name: dns
      command: -conf /etc/coredns/Corefile
      networks:
        - $NETWORK_NAME
      restart: unless-stopped
      volumes:
        - ./Corefile:/etc/coredns/Corefile:ro
      ports:
        - '$HOST_IP:53:53/udp'
        - '$HOST_IP:53:53/tcp'

  networks:
    $NETWORK_NAME:
      external: true"

# --- Write CoreDNS Corefile --------------------------------------------------
log "Writing CoreDNS config at $COREFILE"
write "$COREFILE" "
.:53 {
  # Apex and any explicitly pinned names
  hosts {
    $HOST_IP $DOMAIN
    ttl 60
    fallthrough
  }

  # All names under infra.$DOMAIN go to the VM
  template IN A infra.$DOMAIN {
    match ^(.+)\.
    answer \"{{ .Name }} 60 IN A $HOST_IP\"
  }

  # App names under $DOMAIN go to the Ingress LB
  template IN A $DOMAIN {
    match ^([^.]+)\.
    answer \"{{ .Name }} 60 IN A $HOST_IP\"
  }

  forward . 1.1.1.1 8.8.8.8
  cache 30
  log
  errors
  health :8080
  prometheus :9153
  reload 10s
}"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Bring up dns -----------------------------------------------------------
log "Validating docker-compose.yml"
docker compose -f "$COMPOSE_FILE" config >/dev/null

log "Starting container"
( cd "$COMPOSE_DIR" && docker compose up -d )

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 53/tcp and 53/udp)"
sudo ufw allow 53/tcp  || true
sudo ufw allow 53/udp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Make host resolve with this dns service ---------------------------------
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo_write "/etc/systemd/resolved.conf.d/coredns.conf" "
  [Resolve]
  DNS=$HOST_IP
  Domains=~$DOMAIN"
sudo systemctl restart systemd-resolved

# --- Summary -----------------------------------------------------------------
info
info "DNS server is up"
info "  • Address      : $HOST_IP:53 (UDP/TCP)"
info "  • Domain zone  : ${DOMAIN} (via hosts plugin)"
info
info "Records served (A):"
info "  • ${DOMAIN}            -> $HOST_IP"
info "  • *.${DOMAIN}          -> $HOST_IP"
info
info "Use it from clients/containers:"
info "  • On your PC / router    : set DNS server to $HOST_IP"
info "  • In Docker containers   : add 'dns: [\"$HOST_IP\"]' to your service in docker-compose"
info
info "Logs: docker logs -f dns"
