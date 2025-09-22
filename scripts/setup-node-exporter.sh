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

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
VERSION="1.8.1"
ARCHIVE="node_exporter-${VERSION}.linux-amd64.tar.gz"
EXTRACTED_DIR="node_exporter-${VERSION}.linux-amd64"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${ARCHIVE}"
BIN_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/node-exporter.service"

# --- Functions ---------------------------------------------------------------
cleanup() {
  log "→ Running cleanup"

  # Stop and disable systemd service
  sudo systemctl disable --now "node-exporter.service" &>/dev/null || true

  # Remove binary, unit file, system user, and download leftovers
  sudo rm -f "${BIN_DIR}/node-exporter"
  sudo rm -f "${SERVICE_FILE}"
  sudo userdel --force "node-exporter" &>/dev/null || true
  sudo rm -rf "/var/lib/node-exporter"
  rm -f "${ARCHIVE}"
  rm -rf "${EXTRACTED_DIR}"

  # Remove firewall rule
  if command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --remove-port=9100/tcp &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null || true
  elif command -v ufw &>/dev/null; then
    sudo ufw --force delete allow 9100/tcp &>/dev/null || true
  fi

  log "→ Cleanup complete"
}

# --- Main Execution Flow -----------------------------------------------------

# Uninstall mode
if [[ "${1-}" == "uninstall" ]]; then
  cleanup
  exit 0
fi

# Fresh install: start with cleanup
cleanup

# --- Download and extract binary ---------------------------------------------
log "→ Downloading node_exporter v${VERSION}"
wget -q "${URL}"
tar xzf "${ARCHIVE}"

# --- Move binary to system path ----------------------------------------------
log "→ Installing binary to ${BIN_DIR}/node-exporter"
sudo mv "${EXTRACTED_DIR}/node_exporter" "${BIN_DIR}/node-exporter"
rm -rf "${EXTRACTED_DIR}" "${ARCHIVE}"

# --- Create system user if needed --------------------------------------------
log "→ Creating system user 'node-exporter'"
if ! id "node-exporter" &>/dev/null; then
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin "node-exporter"
fi

# --- Create systemd unit file ------------------------------------------------
log "→ Creating systemd unit file"
sudo_append "${SERVICE_FILE}" "
  [Unit]
  Description=Prometheus Node Exporter
  After=network.target

  [Service]
  User=node-exporter
  ExecStart=${BIN_DIR}/node-exporter
  Restart=always

  [Install]
  WantedBy=multi-user.target"

# --- Enable and start the service --------------------------------------------
log "→ Enabling and starting systemd service"
sudo systemctl daemon-reload
sudo systemctl enable --now "node-exporter.service"

# --- Open firewall port ------------------------------------------------------
log "→ Allowing TCP port 9100 via UFW"
sudo ufw allow 9100/tcp
sudo ufw reload
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info
info "node-exporter installation complete"
info
info "  • Service name     : node-exporter"
info "  • Check status     : sudo systemctl status node-exporter.service"
info "  • Metrics endpoint : http://$DOMAIN:9100/metrics"
info
info "Add the following to your Prometheus scrape_configs:"
info
info "scrape_configs:
        - job_name: 'node-exporter'
          metrics_path: '/metrics'
          static_configs:
            - targets:
                - '$DOMAIN:9100'"
