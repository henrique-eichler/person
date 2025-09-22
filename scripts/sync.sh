#!/usr/bin/env bash
set -eo pipefail
source $HOME/Projects/tools/functions.sh

clear

origin="$(whoami)@$(hostname -s)"
sshKey="~/.ssh/id"

# Define machines to sync with (excluding current machine later)
machines=()

# Define $HOME-relative paths to sync
paths=(
  "$(pwd)"
)

read -p "Write the user and machine name (user@machine): " machine
machines=("$machine")

if [[ ! -e ~/.ssh/id ]]; then
  ssh-keygen -t rsa -N "" -f ~/.ssh/id
fi

for machine in "${machines[@]}"; do
  if [[ "$machine" != "$origin" ]]; then
    log "  -> $machine"
    ssh-copy-id -i ~/.ssh/id "$machine"
  fi
done

log "From: $origin"
sync $origin $sshKey ${machines[@]} -- ${paths[@]}

log "----------------------------------------------------------------"
log "✅ All sync operations complete."
