# NordVPN-AP: Dockerized WiFi Access Point Manager

> Turn any Linux machine into a privacy-first VPN router - no expensive hardware required.

This project broadcasts a WiFi hotspot that routes **100% of connected client traffic** through an encrypted NordVPN tunnel. Smart TVs, projectors, gaming consoles, or any device that can't run a VPN app natively gets full VPN coverage simply by connecting to the hotspot.


## Why This Project Exists

The frustration of trying to watch region-locked content like Netflix India on a Smart TV or projector sparked this project. These devices don't support VPN clients natively, and dedicated VPN routers are either expensive or underpowered for the task.

The insight is straightforward: a VPN router is essentially just a device with a VPN client in its firmware and enough compute to handle routing. This project takes that idea and runs with it, using Docker and NordVPN to turn any standard Linux machine into a fully functional VPN Access Point. Once a device is connected to the hotspot, it is automatically routed through an encrypted tunnel—bypassing geo-restrictions and keeping all traffic private without requiring a VPN app on the end device.

A lightweight, premium Rust Orchestrator & Web Dashboard to turn your Linux machine into multiple NordVPN-protected WiFi Access Point gateways.

---

## 🚀 Features

- **Automated WireGuard Key Fetcher**: Enter your NordVPN Access Token in the dashboard and click **"Fetch Key"** to automatically retrieve and save your `nordlynx_private_key` directly from the NordVPN API.
- **Full Stack Editing**: Modify existing access point parameters (SSID, Password, Security, Channel, Channel Width, Hardware Mode, 12h Reconnect) while maintaining immutable VPN Location & Profile ID integrity.
- **12-Hour Auto-Reconnect**: Toggleable background scheduler per stack that periodically disconnects and reconnects the VPN tunnel every 12 hours for optimal performance.
- **Telemetry Overview Bar**: Real-time stats bar showcasing active/total stacks, tunneled gateways, and discovered system wireless interfaces.
- **Zero-Config Setup**: Dynamic host path auto-detection on startup via container self-inspection; no shell variables to export.
- **Interface Auditing**: Scans adapter standards (802.11a/b/g/n/ac/ax) and filters compatibility options dynamically.
- **WiFi Security Selection**: Supports WPA2, WPA3 (SAE), Mixed, WPA Legacy, and Open (None) networks.
- **Interactive Toggles**: Bypasses password validation and hides password rows for open systems.
- **DNS Ad-Blocking & Kill-Switch**: Integrated per-stack AdGuard Home and Gluetun VPN tunnel with kill-switch safety.
- **Activity Feed**: Sleek notification bell header component displaying system events in a glassmorphic dropdown history.

---

## 🚦 Getting Started

### 1. Launch the Orchestrator
Run Docker Compose to build and start the orchestrator service:
```bash
docker compose up -d --build
```

### 2. Open the Web Dashboard
Navigate your browser to: `http://localhost:42918/`

### 3. Configure VPN Credentials
1. Go to the **Settings → NordVPN Credentials** section.
2. If using **WireGuard (NordLynx)**: Paste your NordVPN Access Token and click **"Fetch Key"**. The dashboard will automatically extract and save your WireGuard Private Key.
3. If using **OpenVPN**: Enter your OpenVPN Service Username and Password obtained from your NordVPN dashboard.

> [!TIP]
> **Getting your NordVPN Access Token**: Log into your NordVPN Dashboard → find Access Token section under Advanced settings → Get Access Token.

---

## 🔌 API Endpoints

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/stacks` | List all AP profiles, active status, and VPN IPs |
| `POST` | `/api/stacks` | Create a new AP stack (auto-allocates subnet/routing table) |
| `GET` | `/api/stacks/:id` | Get detailed status of a specific AP stack |
| `PATCH` | `/api/stacks/:id` | Update an existing stack configuration |
| `DELETE` | `/api/stacks/:id` | Remove a stack and tear down its containers |
| `POST` | `/api/stacks/:id/start` | Start containers for a specific stack |
| `POST` | `/api/stacks/:id/stop` | Stop containers for a specific stack |
| `POST` | `/api/stacks/:id/restart` | Restart containers for a specific stack (stop/start chain) |
| `GET` | `/api/stacks/:id/logs` | Query container logs for Gluetun, WiFi-AP, and AdGuard |
| `GET` | `/api/credentials` | Query configured credentials presence |
| `PATCH` | `/api/credentials` | Update OpenVPN credentials or fetch WireGuard key via Access Token |
| `GET` | `/api/wifi/interfaces` | List host WiFi interfaces and audited capabilities |
| `GET` | `/api/vpn/locations` | Query available NordVPN exit node locations |
| `GET` | `/api/health` | Get health check status of the orchestrator and Docker daemon |
| `WS` | `/ws/stacks` | Real-time status streaming endpoint |

---

## 📂 Project Structure

- `src/`: The Rust orchestrator backend source code (`Axum`, `Tokio`, `DockerManager`).
- `static/`: The frontend web dashboard assets (HTML, CSS, JS with Technical Glassmorphic design).
- `access_point/`: Docker build context for the physical WiFi Access Point container (`hostapd`/`dnsmasq`).
- `country/`: Contains per-profile runtime state generated by the orchestrator (e.g. `country/us_ap/`).
- `data/`: Persistent application JSON stores (`stacks.json`, `credentials.json`).

---

## 🛠 Prerequisites

- **OS**: Linux (with a kernel supporting `hostapd` and policy routing).
- **Docker & Docker Compose**: Installed and running with access to `/var/run/docker.sock`.
- **Hardware**: A WiFi network card supporting **AP (Access Point) mode**.

---

## 📚 References

- **Understanding WiFi Standards (802.11a/b/g/n/ac/ax)**: [Standardy Wi-Fi](https://www.netia.pl/pl/blog/standardy-wi-fi-802-11-a-b-g-n-ac-ax)
- **hostapd documentation**: [w1.fi/hostapd](https://w1.fi/hostapd/)
- **Gluetun VPN client**: [GitHub - qdm12/gluetun](https://github.com/qdm12/gluetun)

---

## Credits

Inspired by [dannypv05261](https://github.com/dannypv05261/docker-vpn-ap) for demonstrating the foundational logic of sharing a tunneled network over a WiFi Access Point.

---

*Built with ❤️ using [Gluetun](https://github.com/qdm12/gluetun) and [hostapd](https://w1.fi/hostapd/).*
