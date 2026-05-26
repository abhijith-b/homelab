# homelab

Personal homelab running on a Fedora laptop. The idea is simple — the laptop sits at home, gets turned on when needed, and all services come up automatically. I can then reach everything securely from anywhere over Tailscale VPN without opening a single port on the router.

## How it works

When the laptop boots, systemd starts all configured services via Podman Quadlet units. Tailscale also starts automatically and connects the laptop to my private VPN. From any device on the same Tailscale network (phone, work laptop, etc.) I can access services using clean subdomains of `abhijithb.org`.

DNS records for private services point to the Tailscale IP (`100.x.x.x`). Since this is a private IP range, Cloudflare automatically sets these records to DNS-only — nothing is reachable from the open internet, only over Tailscale.

## Why Quadlet over Docker Compose

This laptop is not a dedicated server — it gets turned on on-demand and needs services to start automatically on boot without anyone logging in. Quadlet runs containers as systemd units, which means boot ordering, crash recovery, and autostart are all handled natively by systemd. No daemon to babysit, no extra tooling.

Compose is the more common choice and has better documentation online, but it isn't designed for this kind of always-on, boot-time reliability on a single machine. Quadlet is.

## Stack

- **OS**: Fedora — Podman is native here, no Docker daemon needed
- **Containers**: Rootless Podman with Quadlet for systemd-managed services
- **VPN**: Tailscale — zero-config, no port forwarding, works behind any NAT
- **Reverse proxy**: Caddy — automatic HTTPS via Cloudflare DNS challenge
- **DNS / Domain**: `abhijithb.org` managed on Cloudflare

## Services

| Service | URL | Purpose |
|---|---|---|
| Cockpit | `https://cockpit.abhijithb.org:9090` | System dashboard — CPU, memory, storage, running services. Accessed directly on port 9090, not proxied through Caddy. |
| Caddy | internal | Reverse proxy for all containerised services. Handles TLS automatically. |
| Syncthing | `https://sync.abhijithb.org` | Continuous file sync between devices |

## Setting up from scratch

### 1. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled

# Authenticate — opens a browser URL to link the device to your Tailscale account
sudo tailscale up

# Note your Tailscale IP, used for all DNS records
tailscale ip -4
```

### 2. Firewall

Fedora's firewalld doesn't automatically trust the Tailscale interface. Add it to the trusted zone so services are reachable over VPN:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload
```

### 3. Enable user lingering

Ensures Quadlet services start on boot even when no user is logged in — critical for the "laptop turns on, everything just works" flow:

```bash
loginctl enable-linger $USER
```

### 4. Cockpit

Cockpit ships in the Fedora repos. It gives a full system dashboard accessible from any browser:

```bash
sudo dnf install cockpit
sudo systemctl enable --now cockpit.socket
```

Access at `https://cockpit.abhijithb.org:9090`. Accept the self-signed cert warning once (Cockpit generates its own cert for the machine hostname), then log in with your Fedora username and password.

> **Note:** Cockpit cannot be reverse proxied through Caddy — it causes a redirect loop due to how Cockpit handles the Host header. Access it directly on port 9090.

### 5. Caddy (reverse proxy)

Caddy handles TLS for all containerised services using the Cloudflare DNS-01 challenge — no public access required.

**5a. Cloudflare API token**

In Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom Token:
- Permissions: `Zone → DNS → Edit`

**5b. Allow rootless Podman to bind ports 80 and 443**

```bash
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
```

**5c. Create data directories**

```bash
mkdir -p ~/.local/share/containers/homelab/caddy/{data,config}
mkdir -p ~/.config/containers/systemd
```

**5d. Environment file**

```bash
cp services/caddy/.env.example services/caddy/.env
# Edit .env and set CF_API_TOKEN to your Cloudflare API token
```

**5e. Symlink Quadlet files and start**

Run from the repo root:
```bash
ln -sf "$PWD/quadlet/homelab.network" ~/.config/containers/systemd/homelab.network
ln -sf "$PWD/quadlet/caddy.container" ~/.config/containers/systemd/caddy.container
systemctl --user daemon-reload
systemctl --user start caddy
```

> **Note:** `systemctl --user enable` fails for Quadlet-generated units — this is expected. Autostart on boot is already handled by `WantedBy=default.target` in the `.container` file.

> **Note:** The Caddyfile volume is mounted as a **directory** (`services/caddy/` → `/etc/caddy/`), not as a single file. Mounting individual files breaks after edits because most editors save by creating a new file (new inode), leaving the container's bind mount pointing at the old inode.

After editing the Caddyfile, reload Caddy without restarting:
```bash
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

After editing a Quadlet `.container` file, just reload and restart — the symlink means systemd already sees the updated file:
```bash
systemctl --user daemon-reload && systemctl --user restart <service>
```

### 6. Syncthing

```bash
mkdir -p ~/.local/share/containers/homelab/syncthing/data
ln -sf ~/git/homelab/quadlet/syncthing.container ~/.config/containers/systemd/syncthing.container
systemctl --user daemon-reload
systemctl --user start syncthing
```

Then add the Caddyfile entry and reload:
```bash
# Add to services/caddy/Caddyfile:
# sync.abhijithb.org {
#     reverse_proxy syncthing:8384
# }
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Access the Syncthing UI at `https://sync.abhijithb.org` to configure folders and devices.

### DNS records (Cloudflare)

Add an A record for each service pointing to your Tailscale IP. Cloudflare automatically sets these to DNS-only since `100.x.x.x` is a private IP range:

```
cockpit.abhijithb.org  →  <tailscale-ip>
sync.abhijithb.org     →  <tailscale-ip>
```
