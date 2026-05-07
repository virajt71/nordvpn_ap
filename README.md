# NordVPN Containerized WiFi Access Point

Transform your Linux machine into a robust, dedicated VPN WiFi router. This project uses a containerized architecture to broadcast a secure WiFi hotspot that automatically routes 100% of its connected clients' traffic through an encrypted NordVPN tunnel.

## 🌟 Features
- **Dual Protocols:** Choose between **OpenVPN** or **WireGuard** (NordLynx) depending on your speed and stability needs.
- **Containerized Architecture:** Uses [Gluetun](https://github.com/qdm12/gluetun) for the VPN connection and a custom Debian `wifi-ap` container (running `hostapd` and `dnsmasq`) for the hotspot.
- **Zero DNS Leaks:** Configured to push NordVPN's official DNS servers directly to hotspot clients, circumventing geo-blocks and streaming restrictions.
- **Strict Kill-Switch:** Network traffic is physically bound to the VPN container's namespace. If the VPN drops, hotspot internet drops. No leaks, ever.
- **Hot-reloadable Configs:** Modifying your SSID or passwords doesn't require rebuilding containers.

---

## 🏗 Architecture
1. **`gluetun`**: Connects to NordVPN. Exposes a local network namespace containing the `tun0` interface.
2. **`wifi-ap`**: Runs on the host network to manage the physical WiFi adapter. It automatically discovers `gluetun`'s network namespace and dynamically injects `iptables` and policy routing rules (`ip rule`) to bridge physical AP clients directly into the VPN tunnel.

---

## ⚙️ Setup & Installation

### 1. Prerequisites
- A Linux machine (tested on Ubuntu/Garuda).
- Docker and Docker Compose installed.
- A physical WiFi adapter capable of AP (Access Point) mode.

### 2. First-time Interactive Setup
Run the startup wizard once from the repository root:
```bash
chmod +x startup.sh
./startup.sh
```

The script asks for:
- WiFi interface (`AP_IFACE`)
- VPN type (`VPN_TYPE`: `wireguard` or `openvpn`)
- Required NordVPN credentials for the selected VPN type
- Hotspot SSID/password and network settings

It saves all values to a root `.env` file, so next runs can reuse the same configuration.

> **Note on WireGuard Keys:** NordVPN does not provide WireGuard private keys directly in their dashboard. To obtain yours:
> 1. Generate an Access Token from the NordVPN Dashboard (Manual Setup).
> 2. Run: `curl -s -u token:<YOUR_TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key`

### 3. Manual Config (Optional)
If you prefer manual setup:
```bash
cp .env.example .env
```
Then edit `.env` directly.

---

## 🚀 Usage

Use the single root compose file:
```bash
docker compose up -d --build
```

To reconfigure settings later, run:
```bash
./startup.sh
```

### Checking Logs
To view the status of your VPN connection:
```bash
docker logs gluetun -f
```
To view the status of the WiFi Hotspot, connected devices, and DHCP leases:
```bash
docker logs wifi-ap -f
```

---

## 🛠 Troubleshooting

**Clients connect but have "No Internet"**
1. Check if Gluetun successfully established a connection (`docker logs gluetun`).
2. Ensure your `FIREWALL_OUTBOUND_SUBNETS` variable accurately reflects your host machine's LAN IP.
3. Restart the AP container to force it to re-inject the namespace routing rules: `docker compose restart wifi-ap`

**Streaming Apps (like JioHotstar) detect the VPN**
Streaming services aggressively block VPN IP addresses.
1. Force the VPN to grab a new server IP: `docker compose restart gluetun`
2. **Mobile Users:** Go to your phone's App Settings and explicitly **Deny** "Location" permissions for the streaming app, then clear the app's cache. Streaming apps often compare your VPN IP against your phone's physical GPS location.

---
*Built with ❤️ utilizing Gluetun and Hostapd.*
