#!/usr/bin/env bash
set -euo pipefail
source "$(pwd)/functions.sh"

info "Installing virtualization stack (KVM, libvirt, virt-manager)..."
sudo apt-get update -y
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf cpu-checker dmidecode
sudo systemctl enable --now libvirtd || sudo systemctl enable --now libvirt-daemon || true
