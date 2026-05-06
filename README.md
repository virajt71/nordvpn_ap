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
- A physical WiFi adapter capable of AP (Access Point) mode. (Update `AP_IFACE` in the `wifi-ap-entrypoint.sh` scripts if your interface name differs from `wlxac15a2e2f47e`).

### 2. Configure Environment Variables
Copy the `.env` file template and fill in your credentials. We use a centralized `.env` file in the root directory so you can seamlessly switch between OpenVPN and WireGuard without duplicating secrets.

Create a `.env` file in the root of the repository:
```env
# NordVPN Credentials (for OpenVPN)
OPENVPN_USER=your_nordvpn_service_user
OPENVPN_PASSWORD=your_nordvpn_service_password

# WireGuard Credentials (for NordLynx)
WIREGUARD_PRIVATE_KEY=your_wireguard_private_key

# Shared VPN Settings
SERVER_COUNTRIES=India
FIREWALL_OUTBOUND_SUBNETS=192.168.50.145/32 # Your host's local LAN IP to bypass the killswitch
```

> **Note on WireGuard Keys:** NordVPN does not provide WireGuard private keys directly in their dashboard. To obtain yours:
> 1. Generate an Access Token from the NordVPN Dashboard (Manual Setup).
> 2. Run: `curl -s -u token:<YOUR_TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key`

### 3. Customize Hotspot Settings (Optional)
Edit `access_point/hostapd.conf` inside either the `openvpn_config` or `wireguard_config` folder to change your WiFi name and password.
* Default SSID: `MyHotspot`
* Default Password: `ChangeMe123!`

---

## 🚀 Usage

Navigate to the directory of the protocol you wish to use and start the Docker Compose stack.

**For WireGuard (Recommended for speed):**
```bash
cd wireguard_config
sudo docker compose up -d
```

**For OpenVPN:**
```bash
cd openvpn_config
sudo docker compose up -d
```

### Checking Logs
To view the status of your VPN connection:
```bash
sudo docker logs gluetun -f
```
To view the status of the WiFi Hotspot, connected devices, and DHCP leases:
```bash
sudo docker logs wifi-ap -f
```

---

## 🛠 Troubleshooting

**Clients connect but have "No Internet"**
1. Check if Gluetun successfully established a connection (`docker logs gluetun`).
2. Ensure your `FIREWALL_OUTBOUND_SUBNETS` variable accurately reflects your host machine's LAN IP.
3. Restart the AP container to force it to re-inject the namespace routing rules: `sudo docker compose restart wifi-ap`

**Streaming Apps (like JioHotstar) detect the VPN**
Streaming services aggressively block VPN IP addresses.
1. Force the VPN to grab a new server IP: `sudo docker compose restart gluetun`
2. **Mobile Users:** Go to your phone's App Settings and explicitly **Deny** "Location" permissions for the streaming app, then clear the app's cache. Streaming apps often compare your VPN IP against your phone's physical GPS location.

---
*Built with ❤️ utilizing Gluetun and Hostapd.*
