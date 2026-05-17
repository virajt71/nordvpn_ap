# NordVPN Dockerized Access Point (NordVPN-AP)

A powerful, multi-profile Dockerized solution to turn your Linux machine into a NordVPN-protected WiFi Access Point. It features a sleek interactive wizard for setup and management, supporting both **NordLynx (WireGuard)** and **OpenVPN** protocols.

## 🚀 Features

-   **Interactive Wizard & CLI**: A single entry point (`startup.sh`) for both interactive setup and scriptable management.
-   **Multi-Profile Support**: Run multiple hotspots simultaneously on different WiFi interfaces (e.g., one for US, one for UK).
-   **NordLynx & OpenVPN**: Native support for high-performance NordLynx (WireGuard) or traditional OpenVPN.
-   **Built-in Kill-Switch**: Powered by [Gluetun](https://github.com/qdm12/gluetun), ensuring no data leaks if the VPN connection drops.
-   **DNS Ad-Blocking**: Integrated per-stack AdGuard Home intercepts DNS queries to block ads while tunneling requests securely through the VPN.
-   **WiFi Security**: Supports WPA2-PSK, WPA3-SAE, and Mixed mode.
-   **Auto-Audit**: Automatically probes WiFi hardware to select optimal Channel, Mode, and Width.
-   **Health Monitoring**: Integrated health checks for VPN connectivity, public IP verification, and routing rules.
-   **Conflict Detection**: Automatically prevents IP, Subnet, and Interface conflicts between multiple country profiles.

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
The architecture supports running multiple stacks concurrently by isolating each profile with its own physical interface, subnet, and routing table.

```mermaid
graph LR
    subgraph "Profile: US"
        AP1[WiFi-AP] --> RT1[RT 100] --> GT1[Gluetun]
    end

    subgraph "Profile: UK"
        AP2[WiFi-AP] --> RT2[RT 101] --> GT2[Gluetun]
    end

    W1[wlan0] -.-> AP1
    W2[wlan1] -.-> AP2

    GT1 --> I((Internet))
    GT2 --> I

    classDef vpnStyle fill:#4a90d9,stroke:#333,stroke-width:2px,color:#fff;
    classDef apStyle fill:#00c896,stroke:#333,stroke-width:2px,color:#fff;
    class GT1,GT2 vpnStyle;
    class AP1,AP2 apStyle;
```

---

## 🛠 Prerequisites

-   **OS**: Linux (tested on Ubuntu/Debian/Garuda).
-   **Docker & Docker Compose**: Installed and running.
-   **Hardware**: A WiFi network card that supports **AP (Access Point) mode**.
-   **Tools**: `curl`, `jq`, `iw`, and `fzf` (required for wizard).

---

## 🚦 Usage

### 1. Launch the Setup Wizard
```bash
./startup.sh
```
Follow the interactive prompts to create or edit country profiles.

### 2. Access the AdGuard Home Web UI
Once connected to the AP (e.g., `ap_us`), open a browser and navigate to the gateway IP on port 3000:
```
http://192.168.60.1:3000
```
*(The exact IP depends on the AP_IP configured during the setup wizard for that profile).*

### 3. CLI Management
`startup.sh` also acts as a CLI for management tasks.

| Command | Description |
| :--- | :--- |
| `./startup.sh list` | List all profiles and their current status. |
| `./startup.sh start <name>` | Build and start a specific country profile. |
| `./startup.sh stop <name>` | Stop a profile (keeps containers). |
| `./startup.sh health` | Check VPN connectivity and routing for all profiles. |
| `./startup.sh logs <name>` | Follow logs for a specific profile. |
| `./startup.sh delete <name>` | Completely remove a profile and its config. |

---

## 📂 Project Structure

-   `startup.sh`: Unified interactive wizard and CLI management tool.
-   `country/`: Contains per-profile configurations (e.g., `country/afghanistan/.env`).
-   `access_point/`: Docker build context for the WiFi Access Point service.
-   `docker-compose.template.yaml`: Template used to generate instance stacks.
-   `.env.credentials`: Secure storage for your NordVPN keys/passwords.

---

## 🔧 Configuration

Each profile has its own `.env` file located in `country/<name>/.env`. Key variables include:

-   `COUNTRY`: Profile identifier.
-   `VPN_TYPE`: `wireguard` or `openvpn`.
-   `SERVER_COUNTRIES`: Target country for the VPN connection.
-   `AP_IFACE`: The WiFi interface to use.
-   `AP_SSID` / `AP_PASSWORD`: WiFi credentials.
-   `ROUTING_TABLE`: Unique ID for the policy routing table (auto-assigned).

---

## 🚑 Troubleshooting

-   **WiFi Interface Errors**: Ensure your card supports AP mode. Run `iw list` and look for `AP` in "Supported interface modes".
-   **VPN Connection Issues**: Run `./startup.sh health` to check if `tun0` is up and if the public IP is correctly masked.
-   **Logs**: Use `./startup.sh logs <name>` to see detailed output.

---

## 🔒 Security Note

This project stores credentials in `.env.credentials` and per-profile `.env` files with `600` permissions. Ensure your host system is secure and do not commit your `.env` files to public repositories.