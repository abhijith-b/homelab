#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ $DRY_RUN -eq 1 ]] && echo "==> Dry-run mode: no changes will be made"

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

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEMD_DIR="$HOME/.config/containers/systemd"

step "1. System prerequisites"

run loginctl enable-linger "$USER"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "  [dry-run] write /etc/sysctl.d/99-unprivileged-ports.conf"
  echo "  [dry-run] sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80"
else
  echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
fi

run sudo dnf install -y cockpit
run sudo systemctl enable --now cockpit.socket

# Allow containers to access DRI devices (required for Jellyfin hardware acceleration)
run sudo setsebool -P container_use_dri_devices 1

step "2. Tailscale"

if ! command -v tailscale &>/dev/null; then
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] curl -fsSL https://tailscale.com/install.sh | sh"
    echo "  [dry-run] sudo systemctl enable --now tailscaled"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo systemctl enable --now tailscaled
  fi
fi

echo ""
echo "  Run: sudo tailscale up"
echo "  Complete browser auth, then press Enter to continue."
if [[ $DRY_RUN -eq 0 ]]; then
  read -r _
fi

step "3. Firewall"

run sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
run sudo firewall-cmd --reload

step "4. External drive hot-plug (Jellyfin)"

# When Jellyfin starts before the external drive is mounted, its container mount namespace
# is frozen with an empty /external. Plugging the drive in later doesn't help — the container
# needs a restart to pick up the new mount. This system service restarts Jellyfin automatically
# whenever mnt-elements.mount activates (boot with drive present, or hot-plug after boot).
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  [dry-run] write /etc/systemd/system/jellyfin-drive-restart.service"
  echo "  [dry-run] sudo systemctl daemon-reload"
  echo "  [dry-run] sudo systemctl enable jellyfin-drive-restart.service"
else
  sudo tee /etc/systemd/system/jellyfin-drive-restart.service > /dev/null << EOF
[Unit]
Description=Restart Jellyfin container when external drive mounts
After=mnt-elements.mount
BindsTo=mnt-elements.mount

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --machine=${USER}@.host --user restart jellyfin
RemainAfterExit=no

[Install]
WantedBy=mnt-elements.mount
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable jellyfin-drive-restart.service
  echo "  jellyfin-drive-restart.service enabled"
fi

step "5. Quadlet symlinks"

run mkdir -p "$SYSTEMD_DIR"

for unit in "$REPO_DIR"/quadlet/*; do
  run ln -sf "$unit" "$SYSTEMD_DIR/$(basename "$unit")"
done

step "6. Data directories"

run mkdir -p \
    ~/.local/share/containers/homelab/caddy/data \
    ~/.local/share/containers/homelab/caddy/config \
    ~/.local/share/containers/homelab/syncthing/data \
    ~/.local/share/containers/homelab/filebrowser/db \
    ~/.local/share/containers/homelab/jellyfin/config \
    ~/.local/share/containers/homelab/jellyfin/cache

step "7. Environment files"

if [[ ! -f "$REPO_DIR/services/caddy/.env" ]]; then
  run cp "$REPO_DIR/services/caddy/.env.example" "$REPO_DIR/services/caddy/.env"
  echo ""
  echo "  Edit services/caddy/.env and set CF_API_TOKEN, then press Enter."
  if [[ $DRY_RUN -eq 0 ]]; then
    read -r _
  fi
fi

if [[ ! -f "$REPO_DIR/services/cloudflared/.env" ]]; then
  run cp "$REPO_DIR/services/cloudflared/.env.example" "$REPO_DIR/services/cloudflared/.env"
  echo ""
  echo "  Create a tunnel at Networking → Tunnels, then set TUNNEL_TOKEN in services/cloudflared/.env and press Enter."
  if [[ $DRY_RUN -eq 0 ]]; then
    read -r _
  fi
fi

step "8. Start services"

run systemctl --user daemon-reload

for service in caddy syncthing filebrowser jellyfin cloudflared; do
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] systemctl --user start $service"
  else
    systemctl --user start "$service"
    if systemctl --user is-active --quiet "$service"; then
      echo "  started $service"
    else
      echo "  WARNING: $service failed to start — check: podman logs $service"
    fi
  fi
done

echo ""
echo "All done. Remaining manual steps:"
echo "  1. Add DNS A records in Cloudflare pointing to: $(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')"
echo "     cockpit.abhijithb.org, sync.abhijithb.org, files.abhijithb.org, media.abhijithb.org"
echo "  2. External drive: create /mnt/elements and add an fstab entry for your drive UUID"
echo "     See README → Jellyfin → External HDD setup for the exact fstab line"
echo "  3. Jellyfin: update the Volume= media path in quadlet/jellyfin.container if needed"
echo "  4. Jellyfin: add your media library at Dashboard → Libraries after first login"
echo "  5. Check service logs: podman logs <service>"
echo ""
echo "Optional services:"
echo "  Ente Photos (self-hosted photo backup): bash scripts/ente-bootstrap.sh"
echo "  See README → Ente Photos for config steps to run first."
