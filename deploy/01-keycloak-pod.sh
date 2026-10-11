#!/usr/bin/env bash
# Keycloak 26.7 in production mode on PostgreSQL 16, rootless Podman on RHEL 9 (MFG-IDP01).
# Prereqs: ~/keycloak/certs holds idp.key, idp.crt (from Meridian-Root-CA) and meridian-root-ca.pem.
set -euo pipefail

sudo firewall-cmd --permanent --add-port=8443/tcp && sudo firewall-cmd --reload
sudo loginctl enable-linger "$USER"     # rootless services start at boot without a login

# Secrets: never typed on a command line, never in a file in the repo
openssl rand -base64 32 | tr -d '\n' | podman secret create kc_db_password -
read -s -p "Keycloak bootstrap admin password: " P; echo
printf '%s' "$P" | podman secret create kc_admin_password -; unset P

# Keycloak's image runs as uid 1000; rootless Podman maps your user to root in the container
podman unshare chown 1000:1000 ~/keycloak/certs/idp.key ~/keycloak/certs/idp.crt ~/keycloak/certs/meridian-root-ca.pem

podman pod create --name keycloak -p 8443:8443
podman volume create kc-pgdata

podman run -d --pod keycloak --name kc-postgres \
  -e POSTGRES_DB=keycloak -e POSTGRES_USER=keycloak \
  --secret kc_db_password,type=env,target=POSTGRES_PASSWORD \
  -v kc-pgdata:/var/lib/postgresql/data \
  docker.io/library/postgres:16

podman run -d --pod keycloak --name kc-server \
  -e KC_DB=postgres \
  -e KC_DB_URL=jdbc:postgresql://localhost:5432/keycloak \
  -e KC_DB_USERNAME=keycloak \
  --secret kc_db_password,type=env,target=KC_DB_PASSWORD \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=kc-bootstrap-admin \
  --secret kc_admin_password,type=env,target=KC_BOOTSTRAP_ADMIN_PASSWORD \
  -e KC_HOSTNAME=https://idp.meridianfg.internal:8443 \
  -e KC_HTTPS_CERTIFICATE_FILE=/opt/keycloak/conf/certs/idp.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/keycloak/conf/certs/idp.key \
  -e KC_TRUSTSTORE_PATHS=/opt/keycloak/conf/certs/meridian-root-ca.pem \
  -v ~/keycloak/certs:/opt/keycloak/conf/certs:ro,Z \
  quay.io/keycloak/keycloak:26.7.0 start
