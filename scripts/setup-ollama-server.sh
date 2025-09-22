#!/usr/bin/env bash
set -eo pipefail
source "$HOME/Projects/tools/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 2 ]]; then
  error "Usage: $0 <domain> <model>" 
fi

# --- Require not root privileges ---------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker ufw curl nvidia-smi; do
  if ! command -v $cmd &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
MODEL="$2"

COMPOSE_DIR="$HOME/Projects/projects/ollama"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
SERVICE_FILE="$COMPOSE_DIR/ollama-keepalive.service"
TIMER_FILE="$COMPOSE_DIR/ollama-keepalive.timer"

CONFIG_DIR="/etc/systemd/system"
OLLAMA_SERVICE="${CONFIG_DIR}/ollama.service"
SERVICE_LINK="${CONFIG_DIR}/ollama-keepalive.service"
TIMER_LINK="${CONFIG_DIR}/ollama-keepalive.timer"

# --- Validate ollama installation --------------------------------------------
if command -v ollama &>/dev/null; then
  info "Ollama is already installed. Skipping installation."
else
  info "Downloading and installing Ollama (with CUDA support)..."
  curl -fsSL https://ollama.com/install.sh | sh || error "Failed to install Ollama."
fi
OLLAMA_CLI="$(command -v ollama || true)"

# --- Removing any previous keepalive scripts ---------------------------------
info "Removing any previous keepalive scripts, units, timers, and logs for old model."
sudo systemctl stop ollama-keepalive.timer ollama-keepalive.service    2>/dev/null || true
sudo systemctl disable ollama-keepalive.timer ollama-keepalive.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SERVICE_LINK" "$TIMER_LINK"

# --- Pulling model -----------------------------------------------------------
info "Pulling model: $MODEL"
$OLLAMA_CLI pull "$MODEL" || error "Failed to pull model $MODEL"

# --- Insert or update Environment=OLLAMA_HOST --------------------------------
if grep -q "^Environment=OLLAMA_HOST=" "$OLLAMA_SERVICE"; then
    sudo sed -i 's|^Environment=OLLAMA_HOST=.*|Environment=OLLAMA_HOST=0.0.0.0|' "$OLLAMA_SERVICE"
else
    sudo sed -i '/^\[Service\]/a Environment=OLLAMA_HOST=0.0.0.0' "$OLLAMA_SERVICE"
fi

# --- Reload systemd and restart Ollama ---------------------------------------
sudo systemctl daemon-reload
sudo systemctl restart ollama

# --- Generating service ------------------------------------------------------
info "Generating $SERVICE_FILE..."
write "$SERVICE_FILE" "
  [Unit]
  Description=Ollama Model Keepalive Service ($MODEL)

  [Service]
  Type=oneshot
  ExecStart=$OLLAMA_CLI run $MODEL hello
  User=ollama
  Group=ollama
  Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin\""

info "Generating $TIMER_FILE..."
append "$TIMER_FILE" "
  [Unit]
  Description=Run ollama-keepalive every minute for model ${MODEL}

  [Timer]
  OnBootSec=3min
  OnUnitActiveSec=1min
  Unit=ollama-keepalive.service

  [Install]
  WantedBy=timers.target"

# --- Linking service and timer -----------------------------------------------
sudo ln -sf "$SERVICE_FILE" "$SERVICE_LINK"
sudo ln -sf "$TIMER_FILE"   "$TIMER_LINK"

# --- Starting service and timer -----------------------------------------------
sudo systemctl start ollama-keepalive.timer
sudo systemctl enable ollama-keepalive.timer
sudo systemctl daemon-reload

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 11434)"
sudo ufw allow 11434/tcp  || true
sudo ufw reload || true
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info
info "Ollama with CUDA is installed and ready."
info "  • Pinned model: $MODEL"
info "  • Systemd user service: $SERVICE_LINK"
info "  • Systemd user timer:   $TIMER_LINK"
info "You can check the pinned model with: ollama list"
info "You can test ollama with:
    curl http://ollama.$DOMAIN:11434/api/generate \
      -d '{
        \"model\": \"$MODEL\",
        \"prompt\": \"Tell me a lithe bit about you.\",
        \"stream\": false
      }'"
