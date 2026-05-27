#!/usr/bin/env bash
set -euo pipefail

step() {
	echo ""
	echo "==> $*"
}

step "1. System prerequisites"

loginctl enable-linger "$USER"

echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80

sudo dnf install -y cockpit
sudo systemctl enable --now cockpit.socket

# Allow containers to access DRI devices (required for Jellyfin hardware acceleration)
sudo setsebool -P container_use_dri_devices 1

step "2. Tailscale"

if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo systemctl enable --now tailscaled
fi

echo ""
echo "  Run: sudo tailscale up"
echo "  Complete browser auth, then press Enter to continue."
read -r _

step "3. Firewall"

sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload

step "4. Quadlet symlinks"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEMD_DIR="$HOME/.config/containers/systemd"

mkdir -p "$SYSTEMD_DIR"

for unit in "$REPO_DIR"/quadlet/*; do
    ln -sf "$unit" "$SYSTEMD_DIR/$(basename "$unit")"
done

step "5. Data directories"

mkdir -p \
    ~/.local/share/containers/homelab/caddy/data \
    ~/.local/share/containers/homelab/caddy/config \
    ~/.local/share/containers/homelab/syncthing/data \
    ~/.local/share/containers/homelab/filebrowser/db \
    ~/.local/share/containers/homelab/jellyfin/config \
    ~/.local/share/containers/homelab/jellyfin/cache


step "6. Environment files"

if [ ! -f "$REPO_DIR/services/caddy/.env" ]; then
    cp "$REPO_DIR/services/caddy/.env.example" "$REPO_DIR/services/caddy/.env"
    echo ""
    echo "  Edit services/caddy/.env and set CF_API_TOKEN, then press Enter."
    read -r _
fi

step "7. Start services"

systemctl --user daemon-reload

for service in caddy syncthing filebrowser jellyfin; do
    systemctl --user start "$service"
    echo "  started $service"
done


echo ""
echo "All done. Remaining manual steps:"
echo "  1. Add DNS A records in Cloudflare pointing to: $(tailscale ip -4)"
echo "     cockpit.abhijithb.org, sync.abhijithb.org, files.abhijithb.org, media.abhijithb.org"
echo "  2. Jellyfin: update the Volume= media path in quadlet/jellyfin.container if needed"
echo "  3. Jellyfin: add your media library at Dashboard → Libraries after first login"
echo "  4. Check service logs: podman logs <service>"
