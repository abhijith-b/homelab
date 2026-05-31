#!/bin/bash
# One-time bootstrap for Ente Photos.
# Handles: data directories, Quadlet symlinks, starting the storage layer,
# and configuring Garage (layout, access key, S3 buckets).
#
# Run AFTER filling in services/ente/garage.toml and services/ente/.env.
# Usage: bash scripts/ente-bootstrap.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ $DRY_RUN -eq 1 ]] && echo "==> Dry-run mode: no changes will be made"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEMD_DIR="$HOME/.config/containers/systemd"

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

step() {
  echo ""
  echo "==> $*"
}

check_files() {
  local missing=0
  if [[ ! -f "$REPO/services/ente/garage.toml" ]]; then
    echo "ERROR: services/ente/garage.toml not found."
    echo "       cp $REPO/services/ente/garage.toml.example $REPO/services/ente/garage.toml"
    echo "       # then set rpc_secret to: \$(openssl rand -hex 32)"
    missing=1
  fi
  if grep -q "REPLACE_WITH_HEX_SECRET" "$REPO/services/ente/garage.toml" 2>/dev/null; then
    echo "ERROR: garage.toml still has placeholder rpc_secret. Set it before running this script."
    missing=1
  fi
  if [[ ! -f "$REPO/services/ente/.env" ]]; then
    echo "ERROR: services/ente/.env not found."
    echo "       cp $REPO/services/ente/.env.example $REPO/services/ente/.env"
    echo "       # then set POSTGRES_PASSWORD and GARAGE_RPC_SECRET"
    missing=1
  fi
  if [[ $missing -eq 1 ]]; then exit 1; fi
}

setup_dirs_and_units() {
  step "Data directories"
  run mkdir -p ~/.local/share/containers/homelab/garage/{meta,data}
  echo "  garage data directories ready"

  step "Quadlet symlinks"
  run mkdir -p "$SYSTEMD_DIR"
  for unit in garage.container ente-postgres.container ente-postgres-data.volume ente-museum.container ente-web.container; do
    run ln -sf "$REPO/quadlet/$unit" "$SYSTEMD_DIR/$unit"
    echo "  linked $unit"
  done
  run systemctl --user daemon-reload
  echo "  daemon reloaded"
}

start_storage() {
  step "Starting storage layer (garage + ente-postgres)"
  run systemctl --user start garage ente-postgres

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] wait for Garage readiness"
    echo "  [dry-run] wait for Postgres readiness"
    return
  fi

  echo "Waiting for Garage to be ready..."
  local attempts=0
  until podman exec garage /garage status >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 30 ]]; then
      echo "ERROR: Garage did not become ready after 30 seconds."
      echo "       Check logs: podman logs garage"
      exit 1
    fi
    sleep 1
  done
  echo "  Garage is ready."

  echo "Waiting for Postgres to be ready..."
  attempts=0
  until podman exec ente-postgres pg_isready -U pguser >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 30 ]]; then
      echo "ERROR: Postgres did not become ready after 30 seconds."
      echo "       Check logs: podman logs ente-postgres"
      exit 1
    fi
    sleep 1
  done
  echo "  Postgres is ready."
}

configure_layout() {
  step "Configuring single-node Garage layout"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] podman exec garage /garage node id"
    echo "  [dry-run] podman exec garage /garage layout assign -z dc1 -c 100G <node-id>"
    echo "  [dry-run] podman exec garage /garage layout apply --version 1"
    return
  fi
  local node_id
  node_id=$(podman exec garage /garage node id 2>/dev/null | cut -d@ -f1 | head -1)
  if [[ -z "$node_id" ]]; then
    echo "ERROR: Could not get Garage node ID."
    exit 1
  fi
  echo "  Node ID: $node_id"
  podman exec garage /garage layout assign -z dc1 -c 100G "$node_id"
  podman exec garage /garage layout apply --version 1
  echo "  Layout applied."
}

create_key_and_buckets() {
  step "Creating access key and S3 buckets"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] podman exec garage /garage key create ente-key"
    for bucket in b2-eu-cen wasabi-eu-central-2-v3 scw-eu-fr-v3; do
      echo "  [dry-run] podman exec garage /garage bucket create $bucket"
      echo "  [dry-run] podman exec garage /garage bucket allow --read --write --owner $bucket --key ente-key"
    done
    echo ""
    echo "  [dry-run] (Key ID and Secret key would be printed here)"
    return
  fi

  local key_info key_id secret_key
  key_info=$(podman exec garage /garage key create ente-key)
  key_id=$(echo "$key_info" | grep -i "key id" | awk '{print $NF}')
  secret_key=$(echo "$key_info" | grep -i "secret" | awk '{print $NF}')

  for bucket in b2-eu-cen wasabi-eu-central-2-v3 scw-eu-fr-v3; do
    podman exec garage /garage bucket create "$bucket"
    podman exec garage /garage bucket allow --read --write --owner "$bucket" --key ente-key
    echo "  $bucket: done"
  done

  echo ""
  echo "================================================================"
  echo " Garage credentials — paste into services/ente/museum.yaml"
  echo "================================================================"
  echo " Key ID:     $key_id"
  echo " Secret key: $secret_key"
  echo "================================================================"
  echo ""
  echo "Also generate the remaining museum.yaml secrets ('; echo' prevents zsh % contamination):"
  echo "  Encryption key: \$(head -c 32 /dev/urandom | base64 | tr -d '\\n'; echo)"
  echo "  Hash key:       \$(head -c 64 /dev/urandom | base64 | tr -d '\\n'; echo)"
  echo "  JWT secret:     \$(head -c 32 /dev/urandom | base64 | tr -d '\\n' | tr '+/' '-_'; echo)"
}

check_files
setup_dirs_and_units
start_storage
configure_layout
create_key_and_buckets

echo ""
echo "================================================================"
echo " Next steps"
echo "================================================================"
echo "  1. Fill in services/ente/museum.yaml with the credentials above"
echo "     (also fill in the generated crypto secrets)"
echo "  2. Start museum and web:"
echo "       systemctl --user start ente-museum ente-web"
echo "       podman exec caddy caddy reload --config /etc/caddy/Caddyfile"
echo "  3. Sign up at https://photos.abhijithb.org"
echo "     OTP is in logs: podman logs ente-museum 2>&1 | grep -i otp"
echo "================================================================"
