log()        { echo "[log]  $*"; }
info()       { echo "[info] $*"; }
warn()       { echo "[warn] $*"; }
error()      { echo "[error] $*"; exit 1; }

home()       { getent passwd ${SUDO_USER:-$USER} | cut -d: -f6; }

currentip()  { docker logs vpn |& grep -i "local" | awk '{print $4}'; }

contains() {
  local needle=${1,,}; shift || return 1
  local s; for s in "$@"; do [[ ${s,,} == "$needle" ]] && return 0; done
  return 1
}

is_running() { docker ps --filter "name=^$1\$" --format '{{.Names}}' | grep -q "^$1\$"; }

dedent() {
  awk 'BEGIN{m=-1;n=0} {l=$0; if(l~/[^[:space:]]/){match(l,/^[[:space:]]*/);i=RLENGTH; if(m==-1||i<m)m=i} a[n++]=l}
       END{for(i=0;i<n;i++){l=a[i]; if(l~/^[[:space:]]*$/)print ""; else print substr(l,m+1)}}'
}

write() {
  local fileName="$1"
  local dirName; dirName="$(dirname "$fileName")"
  local content="$2"
  mkdir -p "$dirName"
  printf "%s" "$content" | dedent >"$fileName"
}

append() {
  local fileName="$1"
  local dirName; dirName="$(dirname "$fileName")"
  local content="$2"
  mkdir -p "$dirName"
  printf "%s" "$content" | dedent >>"$fileName"
}

sudo_write()  { local f="$1" c="$2"; sudo bash -c "$(declare -f dedent); printf %s \"$c\" | dedent >\"$f\""; }
sudo_append() { local f="$1" c="$2"; sudo bash -c "$(declare -f dedent); printf %s \"$c\" | dedent >>\"$f\""; }

sync() {
  local origin="$1"; shift;
  local sshKey="$1"; shift;
  local machines=()
  local paths=()
  local delimiter=0

  # Identify machines and paths
  while [[ $# -gt 0 ]]; do
    local arg="$1"; shift;
    if [[ "$arg" == "--" ]]; then delimiter=1; continue; fi
    if [[ $delimiter -eq 0 ]]; then machines+=("$arg"); else paths+=("$arg"); fi
  done

  # Loop over each target machine
  for machine in "${machines[@]}"; do
    if [[ "$machine" != "$origin" ]]; then
      log "----------------------------------------------------------------"
      if ssh -o BatchMode=yes -o ConnectTimeout=5 -i $sshKey "$machine" exit &>/dev/null; then
        log "To: $machine"
        for path in "${paths[@]}"; do
          localPath="$HOME/$path"
          remotePath="/home/${machine%%@*}/$path"
          if [[ -e "$localPath" ]]; then
            remoteDir=$([[ $path == */ ]] && echo "$remotePath" || dirname "$remotePath")
            log "  -> Syncing $localPath to $machine:$remotePath"
            ssh -i "$sshKey" "$machine" "mkdir -p '$remoteDir'"
            if compgen -G "$localPath" > /dev/null; then
              FILES=($localPath)
              rsync -azu --delete --info=progress2 -e "ssh -i $sshKey" "${FILES[@]}" "$machine:$remoteDir"
            else
              rsync -azu --delete --info=progress2 --inplace -e "ssh -i $sshKey" $localPath "$machine:$remoteDir"
            fi
            if [[ $? -ne 0 ]]; then
              warn "    ❌ Sync of '$path' to $machine failed."
            fi
          fi
        done
      else
        warn "Failed to connect: $machine"
        warn "  ❌ Try to run first? ssh-copy-id $machine"
      fi
    fi
  done
}