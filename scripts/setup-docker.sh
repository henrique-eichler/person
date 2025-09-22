#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 0 ]]; then
  error "Usage: $0"
fi

# --- Pre-checks ----------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Try: sudo $0"
fi

for cmd in curl gpg apt-get; do
  command -v "$cmd" >/dev/null 2>&1 \
    || error "Required command '$cmd' not found in PATH."
done

# --- Detect Ubuntu version -----------------------------------------------------
. /etc/os-release
CODENAME=${UBUNTU_CODENAME:-}

if [[ -z "$CODENAME" ]]; then
  warn "Could not detect UBUNTU_CODENAME; defaulting to 'focal'."
  CODENAME="focal"
fi

ARCH=$(dpkg --print-architecture)

# --- Install dependencies & configure APT repo ---------------------------------
log "Updating package index..."
apt-get update -qq

log "Installing prerequisites..."
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release >/dev/null

log "Adding Docker GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

log "Creating Docker APT repository for $CODENAME..."
echo \
  "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
   https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

log "Refreshing package index with Docker packages..."
apt-get update -qq

log "Installing Docker Engine, CLI, containerd, Buildx, and Compose..."
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  docker-compose >/dev/null

info "Docker packages installed."

# --- Group & user setup --------------------------------------------------------
DOCKER_GROUP_EXISTS=$(getent group docker || true)
if [[ -z "$DOCKER_GROUP_EXISTS" ]]; then
  log "Creating 'docker' group..."
  groupadd docker
else
  info "'docker' group already exists."
fi

TARGET_USER=${SUDO_USER:-${USER:-root}}
if id -nG "$TARGET_USER" | grep -qw docker; then
  info "User '$TARGET_USER' is already in 'docker' group."
else
  log "Adding user '$TARGET_USER' to 'docker' group..."
  usermod -aG docker "$TARGET_USER"
  info "User '$TARGET_USER' added to 'docker' group."
fi

# --- Enable service and configure context --------------------------------------
log "Enabling and restarting Docker service..."
systemctl enable docker
systemctl restart docker

if docker context ls --format '{{.Name}}' | grep -qx default; then
  docker context use default >/dev/null
  info "Docker context set to 'default'."
else
  warn "Default Docker context not found; skipping context switch."
fi

# --- Summary -------------------------------------------------------------------
info
info "Docker setup complete"
info " • Docker version  : $(docker --version)"
info " • Current context : $(docker context show)"
info " • Group added     : $TARGET_USER → docker"
info
info "You may need to log out and log in again to apply group membership."
info
info "Verify Docker works with:"
info "  docker run --rm hello-world"
