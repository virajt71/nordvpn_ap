#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SELECTED_VPN_TYPE=""

COLOR_RESET=""
COLOR_BOLD=""
COLOR_BLUE=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""

setup_colors() {
    if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
        COLOR_RESET="$(tput sgr0)"
        COLOR_BOLD="$(tput bold)"
        COLOR_BLUE="$(tput setaf 4)"
        COLOR_GREEN="$(tput setaf 2)"
        COLOR_YELLOW="$(tput setaf 3)"
        COLOR_RED="$(tput setaf 1)"
    fi
}

print_info() {
    echo "${COLOR_BLUE}$1${COLOR_RESET}" >&2
}

print_success() {
    echo "${COLOR_GREEN}$1${COLOR_RESET}" >&2
}

print_warn() {
    echo "${COLOR_YELLOW}$1${COLOR_RESET}" >&2
}

print_error() {
    echo "${COLOR_RED}$1${COLOR_RESET}" >&2
}

print_banner() {
    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}==========================================${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}  NordVPN AP Setup Wizard${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}==========================================${COLOR_RESET}" >&2
}

print_section() {
    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}[$1]${COLOR_RESET}" >&2
}

get_wifi_label() {
    local iface="$1"
    local label=""
    local sys_device="/sys/class/net/${iface}/device"
    local vendor_id=""
    local device_id=""

    if command -v udevadm >/dev/null 2>&1; then
        label="$(udevadm info -q property -p "$sys_device" 2>/dev/null | awk -F= '
            $1=="ID_MODEL_FROM_DATABASE"{print $2; found=1; exit}
            $1=="ID_MODEL" && !found {print $2; found=1; exit}
        ')"
    fi

    if [[ -z "$label" && -r "${sys_device}/vendor" && -r "${sys_device}/device" ]]; then
        vendor_id="$(tr -d '\n' < "${sys_device}/vendor" | sed 's/^0x//')"
        device_id="$(tr -d '\n' < "${sys_device}/device" | sed 's/^0x//')"
        label="vendor:${vendor_id} device:${device_id}"
    fi

    if [[ -z "$label" ]]; then
        label="unknown adapter"
    fi

    echo "$label"
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "${prompt} [${default}]: " value
    echo "${value:-$default}"
}

prompt_secret() {
    local prompt="$1"
    local value=""
    local char=""
    while [[ -z "$value" ]]; do
        printf "%s: " "${prompt}" >&2
        value=""
        while IFS= read -r -s -n1 char; do
            if [[ -z "$char" || "$char" == $'\n' ]]; then
                break
            fi
            if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    printf "\b \b" >&2
                fi
            else
                value+="$char"
                printf "*" >&2
            fi
        done
        echo >&2
        [[ -z "$value" ]] && print_warn "Value cannot be empty."
    done
    echo "$value"
}

render_arrow_menu() {
    local prompt="$1"
    local selected_idx="$2"
    local labels_ref="$3"
    local -n menu_labels="$labels_ref"
    local i

    echo "${prompt}" >&2
    for i in "${!menu_labels[@]}"; do
        if (( i == selected_idx )); then
            printf "  ${COLOR_GREEN}> %s${COLOR_RESET}\n" "${menu_labels[$i]}" >&2
        else
            printf "    %s\n" "${menu_labels[$i]}" >&2
        fi
    done
}

select_with_arrows() {
    local prompt="$1"
    local options_ref="$2"
    local labels_ref="$3"
    local default_idx="${4:-0}"
    local key
    local selected_idx="$default_idx"
    local line_count
    local fallback
    local -n menu_options="$options_ref"
    local -n menu_labels="$labels_ref"

    if [[ ${#menu_options[@]} -eq 0 ]]; then
        return 1
    fi

    if [[ ! -t 0 || ! -t 2 ]] || ! command -v tput >/dev/null 2>&1; then
        while true; do
            read -r -p "${prompt} [1-${#menu_options[@]}]: " fallback >&2
            if [[ "$fallback" =~ ^[0-9]+$ ]] && (( fallback >= 1 && fallback <= ${#menu_options[@]} )); then
                echo "${menu_options[$((fallback - 1))]}"
                return 0
            fi
            print_warn "Invalid selection. Enter a number between 1 and ${#menu_options[@]}."
        done
    fi

    line_count=$(( ${#menu_options[@]} + 1 ))
    render_arrow_menu "$prompt" "$selected_idx" "$labels_ref"

    while true; do
        IFS= read -r -s -n1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n2 key
            case "$key" in
                "[A")
                    ((selected_idx--))
                    (( selected_idx < 0 )) && selected_idx=$((${#menu_options[@]} - 1))
                    ;;
                "[B")
                    ((selected_idx++))
                    (( selected_idx >= ${#menu_options[@]} )) && selected_idx=0
                    ;;
                *)
                    ;;
            esac
            tput cuu "$line_count" >&2
            render_arrow_menu "$prompt" "$selected_idx" "$labels_ref"
        elif [[ -z "$key" || "$key" == $'\n' ]]; then
            echo "${menu_options[$selected_idx]}"
            return 0
        fi
    done
}

choose_vpn_type() {
    local vpn_type
    local options=("wireguard" "openvpn")
    local labels=("wireguard" "openvpn")

    vpn_type="$(select_with_arrows "Select VPN type (Use Up/Down + Enter)" options labels 0)"
    echo "$vpn_type"
}

detect_default_iface() {
    if command -v iw >/dev/null 2>&1; then
        iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}'
    else
        echo "wlan0"
    fi
}

list_wifi_interfaces() {
    local iface
    for iface_path in /sys/class/net/*; do
        iface="$(basename "$iface_path")"
        if [[ -d "/sys/class/net/${iface}/wireless" ]]; then
            echo "$iface"
        fi
    done
}

choose_wifi_interface() {
    local interfaces=()
    local labels=()
    local idx
    local label

    mapfile -t interfaces < <(list_wifi_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        print_warn "No WiFi interfaces auto-detected."
        prompt_default "WiFi interface for AP" "$(detect_default_iface)"
        return
    fi

    for idx in "${!interfaces[@]}"; do
        label="$(get_wifi_label "${interfaces[$idx]}")"
        labels+=("${interfaces[$idx]} [${label}]")
    done

    select_with_arrows "Select WiFi interface for access point (Use Up/Down + Enter)" interfaces labels 0
}

check_running_named_containers() {
    local running=()
    local choice
    local name

    for name in gluetun wifi-ap; do
        if docker ps --format '{{.Names}}' | awk -v n="$name" '$0==n{found=1} END{exit !found}'; then
            running+=("$name")
        fi
    done

    if [[ ${#running[@]} -eq 0 ]]; then
        return
    fi

    print_section "Running Containers Detected"
    print_warn "These containers are already running: ${running[*]}"

    while true; do
        read -r -p "Stop them and continue, or exit? [Y/e]: " choice >&2
        choice="${choice:-Y}"
        case "$choice" in
            Y|y)
                print_info "Stopping: ${running[*]}"
                docker stop "${running[@]}" >/dev/null
                echo >&2
                return
                ;;
            E|e)
                print_info "Exiting without changes."
                exit 0
                ;;
            *)
                print_warn "Invalid choice. Enter Y to stop, or e to exit."
                ;;
        esac
    done
}

configure_env() {
    local ap_iface vpn_type server_countries firewall_subnets ap_ssid ap_password ap_channel ap_ip ap_subnet
    local openvpn_user="" openvpn_password="" wireguard_private_key=""

    print_section "Network Interface"
    ap_iface="$(choose_wifi_interface)"

    print_section "VPN Protocol"
    vpn_type="$(choose_vpn_type)"

    if [[ "$vpn_type" == "openvpn" ]]; then
        print_section "NordVPN OpenVPN Credentials"
        # OpenVPN uses NordVPN service credentials (not your regular account password).
        # Steps:
        # 1) Open https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/service-credentials/
        # 2) Copy "Service credentials" username and password.
        print_info "OpenVPN requires NordVPN service credentials (not your account login password)."
        echo "To get them:" >&2
        echo "1) Open: https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/service-credentials/" >&2
        echo "2) Copy the Service credentials username/password." >&2
        openvpn_user="$(prompt_secret "NordVPN service username (OpenVPN)")"
        openvpn_password="$(prompt_secret "NordVPN service password (OpenVPN)")"
    else
        print_section "NordLynx Key Setup"
        # You need to provide your NordLynx (WireGuard) Private Key here.
        # To get it, generate a manual setup access token from NordVPN dashboard and run:
        # curl -s -u token:<YOUR_TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key
        print_info "You need to provide your NordLynx (WireGuard) Private Key."
        echo "Generate a manual setup access token from NordVPN dashboard and run:" >&2
        echo "curl -s -u token:<YOUR_TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key" >&2
        wireguard_private_key="$(prompt_secret "NordLynx private key (WireGuard)")"
    fi

    print_section "VPN and Hotspot Settings"
    server_countries="$(prompt_default "VPN country (SERVER_COUNTRIES)" "India")"
    firewall_subnets="$(prompt_default "Host LAN CIDR to bypass kill-switch (FIREWALL_OUTBOUND_SUBNETS)" "192.168.50.145/32")"
    ap_ssid="$(prompt_default "Hotspot SSID" "NordVPN AP")"

    while true; do
        ap_password="$(prompt_secret "Hotspot password (min 8 chars)")"
        [[ ${#ap_password} -ge 8 ]] && break
        print_warn "Password must be at least 8 characters."
    done

    ap_channel="$(prompt_default "WiFi channel" "6")"
    ap_ip="$(prompt_default "Hotspot gateway IP" "192.168.60.1")"
    ap_subnet="$(prompt_default "Hotspot subnet CIDR" "192.168.60.0/24")"

    cat > "$ENV_FILE" <<EOF
# Runtime profile
VPN_TYPE=${vpn_type}

# NordVPN Credentials (OpenVPN)
OPENVPN_USER=${openvpn_user}
OPENVPN_PASSWORD=${openvpn_password}

# NordVPN Credentials (WireGuard / NordLynx)
WIREGUARD_PRIVATE_KEY=${wireguard_private_key}

# Shared VPN Settings
SERVER_COUNTRIES=${server_countries}
FIREWALL_OUTBOUND_SUBNETS=${firewall_subnets}

# Access Point Settings
AP_IFACE=${ap_iface}
AP_SSID=${ap_ssid}
AP_PASSWORD=${ap_password}
AP_CHANNEL=${ap_channel}
AP_IP=${ap_ip}
AP_SUBNET=${ap_subnet}
EOF

    chmod 600 "$ENV_FILE"
    print_section "Configuration Saved"
    print_success "Saved configuration to ${ENV_FILE}"
    echo "Selected interface : ${ap_iface}" >&2
    echo "Selected VPN type  : ${vpn_type}" >&2
    echo "Hotspot SSID       : ${ap_ssid}" >&2
    SELECTED_VPN_TYPE="${vpn_type}"
}

get_vpn_type_from_env_file() {
    local env_path="$1"
    awk -F= '/^VPN_TYPE=/{print $2; exit}' "$env_path" 2>/dev/null || true
}

handle_vpn_type_change_cleanup() {
    local previous_vpn_type="$1"
    local new_vpn_type="$2"

    if [[ -z "$previous_vpn_type" || -z "$new_vpn_type" || "$previous_vpn_type" == "$new_vpn_type" ]]; then
        return
    fi

    print_section "VPN Type Changed"
    print_warn "VPN type changed from '${previous_vpn_type}' to '${new_vpn_type}'."
    print_info "Removing old containers and local images before rebuild..."

    docker compose down --remove-orphans --rmi local >/dev/null 2>&1 || true
    docker rm -f gluetun wifi-ap >/dev/null 2>&1 || true
}

main() {
    cd "$ROOT_DIR"
    setup_colors
    print_banner
    check_running_named_containers
    local previous_vpn_type=""

    if [[ -f "$ENV_FILE" ]]; then
        local reuse
        previous_vpn_type="$(get_vpn_type_from_env_file "$ENV_FILE")"
        read -r -p "Existing .env found. Reuse it? [Y/n]: " reuse
        reuse="${reuse:-Y}"
        if [[ "$reuse" =~ ^[Nn]$ ]]; then
            configure_env
        else
            SELECTED_VPN_TYPE="$previous_vpn_type"
        fi
    else
        print_info "No .env found. Running first-time setup..."
        configure_env
    fi

    handle_vpn_type_change_cleanup "$previous_vpn_type" "$SELECTED_VPN_TYPE"

    print_section "Launching Services"
    print_info "Starting stack with unified docker-compose.yaml..."
    docker compose up -d --build
    print_success "Done. Use 'docker compose logs -f gluetun wifi-ap' to monitor." 
    echo ""
}

main "$@"
