#!/usr/bin/env bash
# Hands the pod and both apps to systemd so they start at boot, and makes the journal
# persistent so the apps' authorization audit log survives a reboot.
set -euo pipefail

# Azure's RHEL image keeps the journal in memory. Without this, every authz log is lost on reboot.
sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald

mkdir -p ~/.config/systemd/user && cd ~/.config/systemd/user
# Deprecated in favor of Quadlet, but Quadlet pod support needs Podman 5; RHEL 9 ships 4.9.
podman generate systemd --name keycloak --files
podman generate systemd --name swift-app --files
podman generate systemd --name aml-app --files

systemctl --user daemon-reload
systemctl --user enable pod-keycloak.service container-swift-app.service container-aml-app.service
