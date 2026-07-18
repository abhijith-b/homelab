# homelab

Personal homelab running on a Fedora laptop. The idea is simple — the laptop sits at home, gets turned on when needed, and all services come up automatically. I can then reach everything securely from anywhere over Tailscale VPN without opening a single port on the router.

See [diagram.md](diagram.md) for a visual overview of the architecture.

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
| Jellyfin | `https://media.abhijithb.org` | Media streaming — movies, TV shows, anime |
| Ente Photos | `https://photos.abhijithb.org` | E2EE photo backup and gallery (Google Photos replacement) |
| Cloudflare Tunnel | public hostnames | Exposes public services without opening ports. `cloudflared` dials out to Cloudflare — no port forwarding needed. |

## Setting up from scratch

### 0. Clone the repo

Clone this repo wherever you like. All Quadlet volume mounts assume `~/git/homelab` — if you use a different path, update the `Volume=` lines in the `.container` files accordingly.

### 1. Run the bootstrap script

```bash
bash scripts/bootstrap.sh
```

Run with `--dry-run` first to see every command without executing anything:

```bash
bash scripts/bootstrap.sh --dry-run
```

The script handles: user lingering, unprivileged ports (80/443), Cockpit install, firewall config, Quadlet symlinks, data directories, and starting all services.

You will be prompted to pause at three points:
- **Tailscale auth** — run `sudo tailscale up` and complete browser login
- **Cloudflare API token** — create a token with `Zone → DNS → Edit` permission in the Cloudflare dashboard, then set `CF_API_TOKEN` in `services/caddy/.env`
- **Cloudflare Tunnel token** — create a tunnel in Zero Trust → Networks → Tunnels, copy the token, and set `TUNNEL_TOKEN` in `services/cloudflared/.env`

### 2. DNS records (Cloudflare)

After the script completes it prints your Tailscale IP. Add an A record for each service in the Cloudflare dashboard pointing to that IP. Cloudflare automatically sets these to DNS-only since `100.x.x.x` is a private IP range:

```
cockpit.abhijithb.org     →  <tailscale-ip>
sync.abhijithb.org        →  <tailscale-ip>
files.abhijithb.org       →  <tailscale-ip>
media.abhijithb.org       →  <tailscale-ip>
```

Access Cockpit at `https://cockpit.abhijithb.org:9090` — accept the self-signed cert warning once and log in with your Fedora username and password.

> **Note:** `systemctl --user enable` fails for Quadlet-generated units — this is expected. Autostart on boot is already handled by `WantedBy=default.target` in the `.container` file.

### 3. Ente Photos (optional)

For self-hosted photo backup, Ente has its own setup script. See [Ente Photos](#ente-photos) for the config steps to complete first, then run:

```bash
bash scripts/ente-bootstrap.sh
```

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

> **Note:** i couldn't make Cockpit reverse proxied through Caddy so i left it for now — it causes a redirect loop due to how Cockpit handles the Host header. Access it directly on port 9090.

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

#### Jellyfin

```bash
mkdir -p ~/.local/share/containers/homelab/jellyfin/{config,cache}
ln -sf ~/git/homelab/quadlet/jellyfin.container ~/.config/containers/systemd/jellyfin.container
systemctl --user daemon-reload
systemctl --user start jellyfin
```

Update the `Volume=` line in `quadlet/jellyfin.container` to point to your media directory before starting.

**Hardware acceleration:**

Jellyfin can offload transcoding to the GPU via Intel QSV, VAAPI, NVENC, etc. First allow the container to access the render device:

```bash
# For container-selinux 2.226+
sudo setsebool -P container_use_dri_devices 1
```

Add `AddDevice=/dev/dri/:/dev/dri/` to the `[Container]` section of the Quadlet file, then in Jellyfin:

> Dashboard → Playback → Transcoding → Hardware Acceleration → select your GPU type

Enable only the codecs your GPU actually supports — enabling unsupported ones (e.g. AV1 on older Intel iGPUs) causes ffmpeg to crash-loop at high CPU whenever that codec is encountered. Check your GPU's hardware decode capabilities before ticking boxes.

**Adding a media library:**

Jellyfin does not auto-discover media. After first start, go to:

> Dashboard → Libraries → Add Media Library → set the folder to the path inside the container (e.g. `/media`)

**External HDD setup (auto-mount at boot):**

The external drive must be mounted at a fixed system path — not the udisks2 automount path (`/run/media/fedora/Elements`) which only appears after a desktop login. Jellyfin starts at boot before any login, so it needs the drive available at a stable path.

```bash
# 1. Create the mount point
sudo mkdir -p /mnt/elements

# 2. Add to /etc/fstab (use your drive's UUID from: lsblk -o NAME,UUID,LABEL)
#    ntfs3 = fast kernel NTFS driver; nofail = boot normally if drive is absent
#    context= sets the SELinux label at mount time (NTFS can't store xattr labels itself)
echo 'UUID=<your-uuid> /mnt/elements ntfs3 uid=1000,gid=1000,nofail,context=system_u:object_r:container_file_t:s0 0 0' | sudo tee -a /etc/fstab

# 3. Test without rebooting (must unmount first if already mounted — context= can't be applied via remount)
sudo systemctl daemon-reload
sudo umount /mnt/elements 2>/dev/null; sudo mount /mnt/elements

# 4. Update quadlet/jellyfin.container:
#    - Volume=/mnt/elements:/external:ro   (no :Z — NTFS can't store SELinux xattrs)
#    - SecurityLabelDisable=true           (required: NTFS xattr limitation causes silent SELinux deny otherwise)
#    - After=network-online.target mnt-elements.mount
systemctl --user daemon-reload && systemctl --user restart jellyfin

# 5. Create a system service so Jellyfin restarts automatically when the drive is hot-plugged
#    Background: a container's mount namespace is frozen at start time. If the drive wasn't
#    present at boot, /external inside the container stays empty even after the drive mounts
#    later — Jellyfin won't see it without a restart. This service handles that automatically.
sudo tee /etc/systemd/system/jellyfin-drive-restart.service << 'EOF'
[Unit]
Description=Restart Jellyfin container when external drive mounts
After=mnt-elements.mount
BindsTo=mnt-elements.mount

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --machine=fedora@.host --user restart jellyfin
RemainAfterExit=no

[Install]
WantedBy=mnt-elements.mount
EOF
sudo systemctl daemon-reload
sudo systemctl enable jellyfin-drive-restart.service
```

Add the path as a library in the UI (Dashboard → Libraries → Add Media Library → `/external`). Turn off **"Delete media from library when files are removed from disk"** in library settings to keep metadata when the drive is unplugged.

**Unplugging / re-attaching the drive:** Jellyfin marks those items unavailable when the drive is gone and restores them on re-attach. The `nofail` fstab option ensures the laptop boots normally even if the drive is absent — Jellyfin starts with an empty `/external` and continues working for local media. When the drive is plugged back in, `mnt-elements.mount` activates and `jellyfin-drive-restart.service` automatically restarts the container so it picks up the new mount.

#### Cloudflare Tunnel

See the [Cloudflare Tunnel](#cloudflare-tunnel) section below for setup instructions.

## Ente Photos

End-to-end encrypted photo backup — a self-hosted Google Photos alternative. Photos are encrypted on-device before upload; the server stores only ciphertext. The backend is [Garage](https://garagehq.deuxfleurs.fr/) (a lightweight S3-compatible object store) instead of MinIO, which was abandoned as open source in 2025.

**Architecture:**
```
Mobile/browser → photos.abhijithb.org → ente-web (web UI)
Mobile/browser → photos-api.abhijithb.org → ente-museum (API)
Browser upload → storage.abhijithb.org → Caddy → Garage (S3)
ente-museum → ente-postgres (metadata)
```

Uploads go directly from the browser to Garage via pre-signed S3 URLs (museum generates the URL, browser puts to it). This requires `storage.abhijithb.org` to be reachable over Tailscale.

### Setup

#### 1. Create config files

```bash
cp services/ente/garage.toml.example services/ente/garage.toml
# Edit: set rpc_secret to $(openssl rand -hex 32)

cp services/ente/museum.yaml.example services/ente/museum.yaml
# Leave placeholders for now — credentials come from the bootstrap script (step 2)

cp services/ente/.env.example services/ente/.env
# Edit: set POSTGRES_PASSWORD and GARAGE_RPC_SECRET
```

#### 2. Run the bootstrap script

Handles data directories, Quadlet symlinks, starting the storage layer (Garage + Postgres), and configuring Garage (layout, access key, S3 buckets):

```bash
bash scripts/ente-bootstrap.sh
```

Run with `--dry-run` first to see every command without executing anything:

```bash
bash scripts/ente-bootstrap.sh --dry-run
```

The script prints a **Key ID** and **Secret key** at the end.

#### 3. Fill in museum.yaml

Paste the Garage credentials from the script output into `services/ente/museum.yaml` under all three S3 bucket sections. Also generate and fill in the crypto secrets:

```bash
echo "encryption: $(head -c 32 /dev/urandom | base64 | tr -d '\n'; echo)"
echo "hash:       $(head -c 64 /dev/urandom | base64 | tr -d '\n'; echo)"
echo "jwt:        $(head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_'; echo)"
```

> **Note:** The `; echo` inside each subshell ensures the value ends with a newline. Without it, zsh prints a `%` after the value and copy-pasting it into museum.yaml causes `illegal base64 data` on startup.

#### 4. Start museum and web

```bash
systemctl --user start ente-museum ente-web
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

#### 5. DNS records (Cloudflare)

Add three A records pointing to your Tailscale IP:
```
photos.abhijithb.org     →  <tailscale-ip>
photos-api.abhijithb.org →  <tailscale-ip>
storage.abhijithb.org    →  <tailscale-ip>
```

#### 6. First login

Open `https://photos.abhijithb.org` and sign up with any email address. Since no SMTP is configured, the OTP verification code is printed in the museum logs:

```bash
podman logs ente-museum 2>&1 | grep -i "otp\|verif\|code"
```

#### 7. Give yourself unlimited storage

Ente's default free plan is 10 GB. Update it directly in the database:

```bash
# Replace USER_ID with the number from museum logs: user_id=XXXXXXXXX
podman exec ente-postgres psql -U pguser -d ente_db -c \
  "UPDATE subscriptions SET storage = 10995116277760 WHERE user_id = <USER_ID>;"
```

No restart needed — Ente reads storage from the DB per request.

### Notes

- **Authentication cannot be disabled** — Ente is E2EE; the encryption key is derived from your password. Without logging in, the browser has no key to decrypt photos. Sessions are long-lived so you won't be prompted often.
- **`internal.admins` takes user IDs, not email addresses** — the ID is the number shown as `user_id=` in museum logs.
- **Disable registration** — set `internal.disable-registration: true` in museum.yaml so nobody else can sign up on your instance.

## Cloudflare Tunnel

Exposes public services without opening any ports on the router. `cloudflared` dials out to Cloudflare and keeps a persistent tunnel alive — Cloudflare proxies inbound public traffic through it to Caddy.

```
Internet → Cloudflare edge → tunnel (outbound) → cloudflared → Caddy → service
```

Private services (Filebrowser, Jellyfin, etc.) are never routed through the tunnel — they remain Tailscale-only.

**Setup:**

1. Go to [Cloudflare dashboard](https://dash.cloudflare.com) → Networking → Tunnels → Create tunnel
2. Copy the token and set it in `services/cloudflared/.env`:
   ```bash
   TUNNEL_TOKEN=<your-token>
   ```
3. Start the service:
   ```bash
   systemctl --user daemon-reload && systemctl --user start cloudflared
   podman logs cloudflared  # should show: Connection established
   ```

**Adding a public hostname:**

In the tunnel dashboard -> your tunnel -> Routes -> Add route :
- Subdomain: `<name>`, Domain: `abhijithb.org`
- Service: `HTTP` → `caddy:80`

Then add a matching block in the Caddyfile:
```
http://name.abhijithb.org {
    reverse_proxy <container>:<port>
}
```

Reload Caddy: `podman exec caddy caddy reload --config /etc/caddy/Caddyfile`
Cloudflare automatically creates the DNS record — no manual DNS step needed for tunnel hostnames. Also, TLS certs are handled by cloudflare.

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

### Sharing your machine with a friend

If you share this laptop with someone outside your tailnet (Tailscale admin console → Machines → Share), Tailscale can assign the shared machine a *different* IP scoped to their tailnet — not the same IP it has on your own tailnet. `*.abhijithb.org` records point to your machine's IP as seen from your own tailnet, so your friend's client won't route to that IP, and those hostnames won't resolve to anything reachable on their end.

**Fix:** have your friend find the IP *their* client sees for your shared laptop (not their own device's IP, and not the IP you see on your own tailnet) and map it in their hosts file:
```bash
tailscale status   # run on their machine — find your laptop's hostname in the peer list, e.g. 100.107.154.18
```
```
100.107.154.18   files.abhijithb.org sync.abhijithb.org photos.abhijithb.org media.abhijithb.org
```
Keep the real hostnames (don't browse the bare IP) — Caddy's TLS cert is issued for `abhijithb.org` subdomains, so the Host header/SNI must still match for the handshake to succeed.

## Day-to-day operations

**Reload Caddy after editing the Caddyfile:**
```bash
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

**Restart a service after editing its Quadlet file** (the symlink means systemd already sees the updated file):
```bash
systemctl --user daemon-reload && systemctl --user restart <service>
```

#TODO

i want to add more services in future but too busy
