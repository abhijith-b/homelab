# homelab

Personal homelab running on a Fedora laptop. The idea is simple — the laptop sits at home, gets turned on when needed, and all services come up automatically. I can then reach everything securely from anywhere over Tailscale VPN without opening a single port on the router.

## How it works

When the laptop boots, systemd starts all configured services via Podman Quadlet units. Tailscale also starts automatically and connects the laptop to my private VPN. From any device on the same Tailscale network (phone, work laptop, etc.) I can access services using clean subdomains of `abhijithb.org`.

DNS records for private services point to the Tailscale IP (`100.x.x.x`). Since this is a private IP range, Cloudflare automatically sets these records to DNS-only — nothing is reachable from the open internet, only over Tailscale.

## Stack

- **OS**: Fedora — Podman is native here, no Docker daemon needed
- **Containers**: Rootless Podman with Quadlet for systemd-managed services
- **VPN**: Tailscale — zero-config, no port forwarding, works behind any NAT
- **DNS / Domain**: `abhijithb.org` managed on Cloudflare

## Services

| Service | URL | Purpose |
|---|---|---|
| Cockpit | `https://cockpit.abhijithb.org:9090` | Web-based system dashboard — monitors CPU, memory, storage, and running services remotely |

## Setting up from scratch

### 1. Tailscale

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled

# Authenticate — opens a browser URL to link the device to your Tailscale account
sudo tailscale up

# Note your Tailscale IP, you'll use it for DNS records
tailscale ip -4
```

### 2. Firewall

Fedora's firewalld doesn't automatically trust the Tailscale interface. Add it to the trusted zone so services are reachable over VPN:

```bash
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload
```

### 3. Enable user lingering

This ensures Quadlet services start on boot even when no user is logged in — critical for the "laptop turns on, everything just works" flow:

```bash
loginctl enable-linger $USER
```

### 4. Cockpit

Cockpit ships in the Fedora repos. It gives a full system dashboard accessible from any browser — useful for checking on the machine remotely without SSH:

```bash
sudo dnf install cockpit
sudo systemctl enable --now cockpit.socket
```

Access it at `https://<tailscale-ip>:9090`. You'll get a self-signed cert warning — accept it, then log in with your Fedora username and password.

### DNS records (Cloudflare)

Add an A record for each service pointing to your Tailscale IP. Cloudflare automatically sets these to DNS-only since `100.x.x.x` is a private IP range:

```
cockpit.abhijithb.org  →  <tailscale-ip>
```
