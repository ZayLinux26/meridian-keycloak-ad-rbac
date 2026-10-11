#!/usr/bin/env bash
# Builds the sample OIDC app once and runs it twice (SWIFT and Actimize).
# Prereqs: ~/apps/certs holds apps.key, apps.crt (SAN: swift + aml) and meridian-root-ca.pem,
# and the four app secrets exist: swift_client_secret, aml_client_secret,
# swift_session_secret, aml_session_secret.
set -euo pipefail

sudo firewall-cmd --permanent --add-port=8444/tcp --add-port=8445/tcp && sudo firewall-cmd --reload

# UBI Python runs as uid 1001
podman unshare chown 1001:0 ~/apps/certs/apps.key ~/apps/certs/apps.crt ~/apps/certs/meridian-root-ca.pem

podman build -t meridian-oidc-app:1.2 "$(dirname "$0")/../apps/oidc-app"

# Lowercase z: the cert folder is SHARED by two containers. Uppercase Z would relabel it
# private to whichever container started last and lock the other one out.
# slirp4netns: lets each app reach Keycloak at the host's own IP (idp.meridianfg.internal).

podman run -d --name swift-app --network slirp4netns -p 8444:8444 \
  -e APP_NAME="SWIFT Wire Release Console" -e PORT=8444 \
  -e BASE_URL=https://swift.meridianfg.internal:8444 \
  -e OIDC_ISSUER=https://idp.meridianfg.internal:8443/realms/meridian \
  -e CLIENT_ID=swift-release \
  --secret swift_client_secret,type=env,target=CLIENT_SECRET \
  --secret swift_session_secret,type=env,target=SESSION_SECRET \
  -e REQUESTS_CA_BUNDLE=/certs/meridian-root-ca.pem \
  -e APP_ACTIONS='{"view":{"label":"View wire queue","role":"view"},"release":{"label":"Release wire","role":"release","acr":"gold"},"admin":{"label":"Configure release limits","role":"admin"}}' \
  -v ~/apps/certs:/certs:ro,z \
  localhost/meridian-oidc-app:1.2

podman run -d --name aml-app --network slirp4netns -p 8445:8445 \
  -e APP_NAME="Actimize AML Case Manager" -e PORT=8445 \
  -e BASE_URL=https://aml.meridianfg.internal:8445 \
  -e OIDC_ISSUER=https://idp.meridianfg.internal:8443/realms/meridian \
  -e CLIENT_ID=actimize-cases \
  --secret aml_client_secret,type=env,target=CLIENT_SECRET \
  --secret aml_session_secret,type=env,target=SESSION_SECRET \
  -e REQUESTS_CA_BUNDLE=/certs/meridian-root-ca.pem \
  -e APP_ACTIONS='{"view":{"label":"View AML alerts","role":"view"},"cases":{"label":"Work AML case","role":"cases"},"admin":{"label":"Tune detection rules","role":"admin"}}' \
  -v ~/apps/certs:/certs:ro,z \
  localhost/meridian-oidc-app:1.2
