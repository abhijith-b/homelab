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
| Filebrowser | `https://files.abhijithb.org` | Web file manager for browsing and managing files on the laptop |

## Setting up from scratch

### 0. Clone the repo

Clone this repo wherever you like. All Quadlet volume mounts assume `~/git/homelab` — if you use a different path, update the `Volume=` lines in the `.container` files accordingly.

### 1. Run the bootstrap script

```bash
bash scripts/bootstrap.sh
```

The script handles: user lingering, unprivileged ports (80/443), Cockpit install, firewall config, Quadlet symlinks, data directories, and starting all services.

You will be prompted to pause at two points:
- **Tailscale auth** — run `sudo tailscale up` and complete browser login
- **Cloudflare API token** — create a token with `Zone → DNS → Edit` permission in the Cloudflare dashboard, then set `CF_API_TOKEN` in `services/caddy/.env`

### 2. DNS records (Cloudflare)

After the script completes it prints your Tailscale IP. Add an A record for each service in the Cloudflare dashboard pointing to that IP. Cloudflare automatically sets these to DNS-only since `100.x.x.x` is a private IP range:

```
cockpit.abhijithb.org  →  <tailscale-ip>
sync.abhijithb.org     →  <tailscale-ip>
files.abhijithb.org    →  <tailscale-ip>
```

Access Cockpit at `https://cockpit.abhijithb.org:9090` — accept the self-signed cert warning once and log in with your Fedora username and password.

> **Note:** `systemctl --user enable` fails for Quadlet-generated units — this is expected. Autostart on boot is already handled by `WantedBy=default.target` in the `.container` file.

### Manual setup (reference)

The steps below document what the bootstrap script does, useful if you need to re-run a single step or debug a failure.

#### Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up
tailscale ip -4
```

#### Firewall

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload
```

#### User lingering

```bash
loginctl enable-linger $USER
```

#### Cockpit

```bash
sudo dnf install cockpit
sudo systemctl enable --now cockpit.socket
```

> **Note:** Cockpit cannot be reverse proxied through Caddy — it causes a redirect loop due to how Cockpit handles the Host header. Access it directly on port 9090.

#### Caddy

```bash
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80

mkdir -p ~/.local/share/containers/homelab/caddy/{data,config}
mkdir -p ~/.config/containers/systemd

cp services/caddy/.env.example services/caddy/.env
# Edit .env and set CF_API_TOKEN

ln -sf "$PWD/quadlet/homelab.network" ~/.config/containers/systemd/homelab.network
ln -sf "$PWD/quadlet/caddy.container" ~/.config/containers/systemd/caddy.container
systemctl --user daemon-reload
systemctl --user start caddy
```

> **Note:** The Caddyfile volume is mounted as a **directory** (`services/caddy/` → `/etc/caddy/`), not as a single file. Mounting individual files breaks after edits because most editors save by creating a new file (new inode), leaving the container's bind mount pointing at the old inode.

#### Syncthing

```bash
mkdir -p ~/.local/share/containers/homelab/syncthing/data
ln -sf ~/git/homelab/quadlet/syncthing.container ~/.config/containers/systemd/syncthing.container
systemctl --user daemon-reload
systemctl --user start syncthing
```

#### Filebrowser

```bash
mkdir -p ~/.local/share/containers/homelab/filebrowser/db
ln -sf ~/git/homelab/quadlet/filebrowser.container ~/.config/containers/systemd/filebrowser.container
systemctl --user daemon-reload
systemctl --user start filebrowser
```

> **Note:** If the `db` directory was previously created by the container (owned by a remapped UID), fix ownership before starting: `sudo chown -R $USER: ~/.local/share/containers/homelab/filebrowser/`

On first start, Filebrowser creates an admin account with a randomly generated password. Find it in the logs:

```bash
podman logs filebrowser | grep password
```

To disable auth instead (safe since it's Tailscale-only):

```bash
systemctl --user stop filebrowser
podman run --rm --userns=keep-id --security-opt label=disable \
  -v ~/.local/share/containers/homelab/filebrowser/db:/database \
  docker.io/filebrowser/filebrowser:v2.63.5 \
  config set --auth.method=noauth --database /database/filebrowser.db
systemctl --user start filebrowser
```

> **Note:** `UserNS=keep-id` is required in the Quadlet file. Without it, the container process runs as a remapped UID (~525287) that cannot read the home directory.

## Tailscale features

### Subnet router

Advertises your home LAN to the tailnet so you can reach any device on it (router admin, NAS, printer, etc.) without installing Tailscale on each one.

**Setup:**

```bash
# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

# Allow masquerading (required for firewalld)
sudo firewall-cmd --permanent --add-masquerade
sudo firewall-cmd --reload

# Advertise your home LAN subnet (check yours with: ip route)
sudo tailscale set --advertise-routes=192.168.1.0/24
```

Then approve the route in the Tailscale admin console: Machines → your laptop → three-dot menu → **Edit route settings** → enable the subnet.

**On Linux client devices** (Android/iOS/macOS/Windows pick it up automatically):
```bash
sudo tailscale set --accept-routes
```

### Exit node

Routes all internet traffic from your other devices through the laptop. Useful on untrusted networks (coffee shops, hotels) or when you need your home IP abroad.

**Setup:**

```bash
sudo tailscale set --advertise-exit-node
```

Then approve in the admin console: Machines → your laptop → three-dot menu → **Edit route settings** → enable **Use as exit node**.

Also disable key expiry on the laptop (same three-dot menu) — prevents the exit node from silently going unreachable when the key expires.

**Using the exit node from another device:**

- **Android/iOS:** Tailscale app → Exit Node → select the laptop
- **Linux:**
  ```bash
  sudo tailscale set --exit-node=<laptop-tailscale-ip>
  # To stop:
  sudo tailscale set --exit-node=
  ```

Verify it's working by checking your public IP — it should show your home IP.

> **Note:** Exit node only works when the laptop is on. Tailscale fails open — if the exit node is unreachable, client devices fall back to direct internet rather than dropping traffic.

## Day-to-day operations

**Reload Caddy after editing the Caddyfile:**
```bash
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

**Restart a service after editing its Quadlet file** (the symlink means systemd already sees the updated file):
```bash
systemctl --user daemon-reload && systemctl --user restart <service>
```

### DNS records (Cloudflare)

Add an A record for each service pointing to your Tailscale IP. Cloudflare automatically sets these to DNS-only since `100.x.x.x` is a private IP range:

```
cockpit.abhijithb.org  →  <tailscale-ip>
sync.abhijithb.org     →  <tailscale-ip>
files.abhijithb.org    →  <tailscale-ip>
```
