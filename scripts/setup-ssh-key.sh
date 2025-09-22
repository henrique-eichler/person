#!/usr/bin/env bash
set -eo pipefail
source "$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f6)/Projects/tools/functions.sh"

# --- Require not root privileges --------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Variables ---------------------------------------------------------------
NAME="Henrique Eichler"
LOGIN=82386951120
DOMAINS=("eichler.com.br" "gmail.com" "senado.leg.br" "outros")
HOSTS=("server" "github.com" "bitbucket.com" "git.senado.leg.br" "outros")
GPG_DIR=$HOME/.gnupg
SSH_DIR=$HOME/.ssh
SSH_CONFIG=$SSH_DIR/config

# Removing existing GPG configurations
pkill gpg-agent || true
rm -rf $GPG_DIR

while true; do
  clear

  # Present domain choices to the user
  log Please, select a domain for your email:
  select DOMAIN in ${DOMAINS[@]}; do
    if [[ -n $DOMAIN ]]; then
      break
    else
      log Invalid selection. Please choose a valid domain.
    fi
  done

  if [[ "$DOMAIN" == "outros" ]]; then
    read -p "Informe o domínio: " DOMAIN
  fi

  read -p "Please, write your login ($USER@$DOMAIN): " LOGIN
  if [[ -z "$LOGIN" ]]; then
    LOGIN=$USER
  fi

  # Present host choices to the user
  log Please, select a target host:
  select HOST in ${HOSTS[@]}; do
    if [[ -n $HOST ]]; then
      break
    else
      log Invalid selection. Please choose a valid host.
    fi
  done

  if [[ "$HOST" == "outros" ]]; then
    read -p "Please, write the target host: " HOST
  fi

  EMAIL=$LOGIN@$DOMAIN
  SSH_FILE=$SSH_DIR/$DOMAIN/$HOST

  # Generate SSH key if not exists
  log Generating SSH key for $EMAIL...
  mkdir -p $(dirname $SSH_FILE)
  ssh-keygen -t rsa -b 4096 -C $EMAIL -f $SSH_FILE -N "" || exit 1

  # Generate SSH config for selected host
  log Generating SSH config file
  cat <<EOL >> $SSH_CONFIG
# Private $HOST instance
Host $HOST
  PreferredAuthentications publickey
  IdentityFile $SSH_FILE
EOL
  chmod 600 $SSH_CONFIG

  # Check if GPG key exists
  GPG_KEY_EXISTS=$(gpg --list-secret-keys --keyid-format LONG $EMAIL 2>/dev/null | grep '^sec' || true)
  if [[ -z $GPG_KEY_EXISTS ]]; then
    log Generating GPG key for $EMAIL...
    cat <<EOF > gpg-script
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
%no-protection%
%commit%
EOF

    gpg --batch --gen-key gpg-script
    rm -f gpg-script
  else
    log GPG key for $EMAIL already exists. Skipping generation.
  fi

  # Set git global parameters
  GPG_KEY=$(gpg --list-secret-keys --keyid-format LONG $EMAIL | grep '^sec' | awk '{print $2}' | cut -d'/' -f2)
  git config --global user.signingkey $GPG_KEY
  git config --global commit.gpgsign true
  git config --global gpg.program $(which gpg)

  clear
  log ------------------------------------------------------------------------------------
  log Chave SSH
  log ------------------------------------------------------------------------------------
  log
  cat $SSH_FILE.pub
  log
  log ------------------------------------------------------------------------------------
  log Chave GPG
  log ------------------------------------------------------------------------------------
  log
  gpg --armor --export $GPG_KEY
  log
  log ------------------------------------------------------------------------------------

  # Ask if the user wants to configure another domain and host
  read -p "Do you want to configure another domain and host? (y/n): " choice
  case "$choice" in
    y|Y ) continue;;
    n|N ) break;;
    * ) log "Invalid input. Exiting..."; break;;
  esac

done
