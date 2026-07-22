# NordVPN Dockerized Access Point (NordVPN-AP)

A powerful, multi-profile Dockerized solution to turn your Linux machine into a NordVPN-protected WiFi Access Point. This project features a sleek, networked **Rust API Orchestrator & Web Dashboard** for managing and monitoring your access point stacks remotely, supporting both **NordLynx (WireGuard)** and **OpenVPN** protocols.

---

## 🚀 Features

-   **Rust API Orchestrator**: A lightweight Axum backend that programmatically manages access point stacks via Docker.
-   **Web Dashboard UI**: A premium, responsive dark-mode dashboard (HTML/CSS/JS with glassmorphism aesthetics) served directly by the orchestrator.
-   **Multi-Profile Support**: Run multiple hotspots simultaneously on different WiFi interfaces (e.g., one for US, one for UK).
-   **Built-in Kill-Switch**: Powered by [Gluetun](https://github.com/qdm12/gluetun), ensuring no data leaks if the VPN connection drops.
-   **DNS Ad-Blocking**: Integrated per-stack AdGuard Home intercepts DNS queries to block ads while tunneling requests securely through the VPN.
-   **WiFi Security**: Supports WPA2-PSK, WPA3-SAE, and Mixed mode.
-   **Auto-Auditing**: Automatically probes WiFi hardware to suggest optimal channels, modes, and channel widths.
-   **Bearer Token Security**: Access to the API and web dashboard is secured using a customizable Bearer Token authorization scheme.
-   **Conflict Prevention**: Automatically allocates non-overlapping subnets (starting at `192.168.60.0/24`) and routing tables (starting at `100`) to prevent collisions between profiles.

---

## 🏗 Architecture

### Single Profile Flow
Each profile consists of three primary services: **Gluetun** (VPN), **WiFi-AP** (Hotspot), and **AdGuard** (DNS Ad-Blocking). Traffic is routed through dedicated policy routing tables on the host to ensure all connected clients are protected, while DNS requests are silently intercepted and filtered.

```mermaid
graph TD
    subgraph "Client Layer"
        C[WiFi Client Device]
    end

    subgraph "Docker Host (Linux)"
        subgraph "Country Profile (e.g., 'afghanistan')"
            AP["WiFi-AP Service<br/>(hostapd / dnsmasq)"]
            AGH["AdGuard Home<br/>(DNS Filter)"]
            GT["Gluetun Service<br/>(NordVPN / Kill-switch)"]
        end
        
        WIFI["Physical WiFi Interface<br/>(e.g., wlan0)"]
        RT["Policy Routing Table<br/>(e.g., Table 100)"]
        TUN["Virtual Tunnel<br/>(tun0)"]
    end

    C -- Connects to SSID --> WIFI
    WIFI -- Managed by --> AP
    AP -- "DNS Port 53 Intercept" --> AGH
    AP -- "Marks & Routes" --> RT
    RT -- "Forwards to" --> GT
    AGH -- "Upstream Queries" --> GT
    GT -- "Encrypts & Tunnels" --> TUN
    TUN -- "NordVPN Exit Node" --> Internet((Internet))

    style GT fill:#4a90d9,stroke:#333,stroke-width:2px,color:#fff
    style AP fill:#00c896,stroke:#333,stroke-width:2px,color:#fff
    style AGH fill:#ff5c5c,stroke:#333,stroke-width:2px,color:#fff
```

### Multi-Country Scalability
The architecture supports running multiple stacks concurrently by isolating each profile with its own physical interface, subnet, and routing table. Each stack runs a fully isolated AdGuard Home instance.

```mermaid
graph LR
    subgraph "Profile: US"
        AP1[WiFi-AP] --> AGH1[AdGuard] --> RT1[RT 100] --> GT1[Gluetun]
    end

    subgraph "Profile: UK"
        AP2[WiFi-AP] --> AGH2[AdGuard] --> RT2[RT 101] --> GT2[Gluetun]
    end

    W1[wlan0] -.-> AP1
    W2[wlan1] -.-> AP2

    GT1 --> I((Internet))
    GT2 --> I

    classDef vpnStyle fill:#4a90d9,stroke:#333,stroke-width:2px,color:#fff;
    classDef apStyle fill:#00c896,stroke:#333,stroke-width:2px,color:#fff;
    classDef aghStyle fill:#ff5c5c,stroke:#333,stroke-width:2px,color:#fff;
    class GT1,GT2 vpnStyle;
    class AP1,AP2 apStyle;
    class AGH1,AGH2 aghStyle;
```

---

## 🚦 Getting Started (Rust Web Orchestrator)

The Rust Orchestrator is the recommended way to deploy and manage your Access Points. It runs as a Docker container with host privilege capability and controls the other stacks via the Docker socket.

### 1. Setup VPN Credentials
Create a `.env.credentials` file in the project root directory containing your NordVPN service credentials:
```env
OPENVPN_USER="your-nordvpn-service-username"
OPENVPN_PASSWORD="your-nordvpn-service-password"
WIREGUARD_PRIVATE_KEY="your-wireguard-private-key"
```

### 2. Launch the Orchestrator
Export the project directory on your host and run `docker compose` to start the orchestrator:
```bash
export HOST_PROJECT_DIR=$(pwd)
docker compose up -d --build
```

### 3. Open the Dashboard
Navigate your browser to `http://localhost:8080/`.
- The dashboard automatically detects and lists your WiFi interfaces and audits their capabilities.
- You can create, edit, start, stop, restart, delete, and view logs of all access point profiles directly from the Web UI.
- On first run, a secure API Bearer Token is generated (displayed in the sidebar). Copy it to authenticate your API client or UI session if required.

---

## 🔌 API Endpoints Reference

The `ap-manager` exposes a REST API for remote management:

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/stacks` | List all AP profiles, active status, and VPN IPs |
| `POST` | `/api/stacks` | Create a new AP stack (auto-allocates subnet/routing table) |
| `GET` | `/api/stacks/:id` | Get detailed status of a specific AP stack |
| `PATCH` | `/api/stacks/:id` | Update an existing stack configuration |
| `DELETE` | `/api/stacks/:id` | Remove a stack and tear down its containers |
| `POST` | `/api/stacks/:id/start` | Start containers for a specific stack |
| `POST` | `/api/stacks/:id/stop` | Stop containers for a specific stack |
| `POST` | `/api/stacks/:id/restart` | Restart containers for a specific stack |
| `GET` | `/api/stacks/:id/logs` | Query container logs for Gluetun, WiFi-AP, and AdGuard |
| `GET` | `/api/credentials` | Query configured credentials configuration presence |
| `PATCH` | `/api/credentials` | Update OpenVPN, WireGuard, or API Bearer Token credentials |
| `GET` | `/api/wifi/interfaces` | List host WiFi interfaces and audited capabilities |
| `GET` | `/api/vpn/locations` | Query available NordVPN exit node locations |
| `GET` | `/api/health` | Get health check status of the orchestrator and Docker daemon |

*Note: All API requests require the header `Authorization: Bearer <API_TOKEN>`.*

---

## 📂 Project Structure

-   `src/`: The Rust orchestrator backend source code.
-   `static/`: The frontend web dashboard assets (HTML, CSS, JS).
-   `access_point/`: Docker build context for the physical WiFi Access Point container (`hostapd`/`dnsmasq`).
-   `country/`: Contains per-profile runtime state generated by the orchestrator (e.g., `country/us_ap/`).
-   `legacy/`: Contains legacy scripts and templates (`startup.sh`, `docker-compose.template.yaml`, etc.).

---

## 🛠 Prerequisites

-   **OS**: Linux (with a kernel that supports hostapd/policy routing).
-   **Docker & Docker Compose**: Installed and running.
-   **Hardware**: A WiFi network card that supports **AP (Access Point) mode**. Run `iw list` and look for `AP` in "Supported interface modes".

---

## 🔧 Legacy CLI Wizard Usage

If you prefer terminal-only operation, you can still run the legacy setup script:
```bash
./startup.sh
```
Follow the interactive prompts to create, edit, or launch country profiles from your terminal shell. Refer to `startup.sh usage` by running `./startup.sh --help`.

understanding wifi Standards 802.11 
https://www.netia.pl/pl/blog/standardy-wi-fi-802-11-a-b-g-n-ac-ax
