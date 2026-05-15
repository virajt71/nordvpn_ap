# Project: NordVPN Access Point (NordVPN-AP)

A multi-profile Dockerized solution to turn a Linux machine into a NordVPN-protected WiFi Access Point using Gluetun, hostapd, and dnsmasq.

## Project Overview

The project manages multiple VPN hotspots simultaneously by isolating each country profile into its own network stack, physical WiFi interface, and policy routing table. It uses **Gluetun** for VPN connectivity (WireGuard/OpenVPN) and a custom **WiFi-AP** container for managing the wireless hotspot.

### Core Technologies
- **Docker & Docker Compose**: Orchestration of VPN and AP services.
- **Gluetun**: VPN client with built-in kill-switch.
- **hostapd**: WiFi access point management.
- **dnsmasq**: DHCP and DNS services for connected clients.
- **Bash**: Automation and management scripts.

## Building and Running

The primary entry point for all operations is `startup.sh`.

### Key Commands

| Command | Description |
| :--- | :--- |
| `./startup.sh` | Launch the interactive setup wizard. |
| `./startup.sh list` | List all country profiles and their status. |
| `./startup.sh create <name>` | Create a new country profile. |
| `./startup.sh start <name>` | Build and start a specific profile. |
| `./startup.sh stop <name>` | Stop a specific profile. |
| `./startup.sh restart <name>` | Restart a specific profile. |
| `./startup.sh logs <name>` | View combined logs for Gluetun and WiFi-AP. |
| `./startup.sh health` | Verify VPN connectivity and routing rules. |
| `./startup.sh check-conflicts` | Detect IP, Subnet, or Interface conflicts across profiles. |

## Key Files

- **`startup.sh`**: The master script for the interactive wizard and CLI management. It handles profile creation, startup, and conflict detection.
- **`docker-compose.template.yaml`**: Defines the two-service stack (gluetun + wifi-ap) deployed for each country.
- **`access_point/wifi-ap-entrypoint.sh`**: The core shell logic that configures hostapd, dnsmasq, and host routing rules.
- **`.env.credentials`**: Stores shared VPN credentials (WireGuard private key or OpenVPN user/pass).
- **`country/`**: Directory containing per-profile subdirectories with their specific `.env` configurations.

## Development Conventions

### Environment Variable Isolation
To prevent cross-talk between profiles, `startup.sh` **unsets** all global VPN and AP-related environment variables in the shell before executing `docker compose`. Always ensure new configuration variables are added to the `unset` loop in `startup.sh`.

### VPN Tunnel Detection
The `wifi-ap` container identifies its corresponding `gluetun` tunnel by reading `/proc/PID/environ` to find the process with the matching `PROFILE_NAME`. Do not rely on simple `tun0` detection as it is ambiguous in multi-profile setups.

### Networking
- **Host Network Mode**: The `wifi-ap` container runs in `network_mode: host` to manage physical wireless interfaces.
- **Policy Routing**: Each profile must have a unique `ROUTING_TABLE` ID.
- **IP Ranges**: Ensure `AP_IP` and `AP_SUBNET` do not overlap across profiles.

### Security
- **Permissions**: `.env` and `.env.credentials` files are created with `600` permissions.
- **Privileged Mode**: The `wifi-ap` container requires `privileged: true` for network and hardware management.
