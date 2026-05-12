#!/usr/bin/env bash
# startup.sh — interactive wizard, instance-aware
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE="${ROOT_DIR}/manage.sh"
NORD_CACHE="${ROOT_DIR}/.nord_locations.json"
NORD_CACHE_TTL=86400
CREDENTIALS_FILE="${ROOT_DIR}/.env.credentials"
ENV_FILE=""

RC_ESC=2

# Colors
COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_WHITE=""

setup_colors() {
    if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
        COLOR_RESET="$(tput sgr0)"; COLOR_BOLD="$(tput bold)"
        COLOR_DIM="$(tput dim 2>/dev/null||echo)"
        COLOR_BLUE="$(tput setaf 4)"; COLOR_CYAN="$(tput setaf 6)"
        COLOR_GREEN="$(tput setaf 2)"; COLOR_YELLOW="$(tput setaf 3)"
        COLOR_RED="$(tput setaf 1)"; COLOR_WHITE="$(tput setaf 7)"
    fi
}

print_info()    { echo "${COLOR_CYAN}  ℹ  $1${COLOR_RESET}" >&2; }
print_success() { echo "${COLOR_GREEN}  ✔  $1${COLOR_RESET}" >&2; }
print_warn()    { echo "${COLOR_YELLOW}  ⚠  $1${COLOR_RESET}" >&2; }
print_error()   { echo "${COLOR_RED}  ✖  $1${COLOR_RESET}" >&2; }
print_step()    { echo; echo "${COLOR_BOLD}${COLOR_CYAN}  $1${COLOR_RESET}" >&2; }

print_banner() {
    local width=52 title="  NordVPN AP Setup Wizard  "
    local pad=$(( (width - ${#title}) / 2 ))
    local line; printf -v line '%*s' "$width" '' && line="${line// /─}"
    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}┌${line}┐${COLOR_RESET}" >&2
    printf "${COLOR_BOLD}${COLOR_BLUE}│%${pad}s${COLOR_WHITE}%s${COLOR_BLUE}%${pad}s│${COLOR_RESET}\n" "" "$title" "" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}└${line}┘${COLOR_RESET}" >&2
    echo >&2
}

SPINNER_PID=""

spinner_start() {
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          printf "\r${COLOR_CYAN}  %s  %s${COLOR_RESET}" "${frames[$i]}" "$msg" >&2
          (( i = (i + 1) % ${#frames[@]} ))
          sleep 0.08
      done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    [[ -n "$SPINNER_PID" ]] && { kill "$SPINNER_PID" 2>/dev/null||true; wait "$SPINNER_PID" 2>/dev/null||true; SPINNER_PID=""; }
    printf "\r\033[2K" >&2
    [[ "${1:-}" == "fail" ]] && print_error "Failed."
}

# ─── Key Reading ──────────────────────────────────────────────────────────────
KEY_SEQ=""
read_key() {
    local k1 k2 k3
    IFS= read -r -s -n1 k1
    KEY_SEQ="$k1"
    if [[ "$k1" == $'\x1b' ]]; then
        IFS= read -r -s -n1 -t 0.1 k2 2>/dev/null || { KEY_SEQ="ESC"; return; }
        if [[ "$k2" == "[" ]]; then
            IFS= read -r -s -n1 -t 0.1 k3 2>/dev/null || { KEY_SEQ="ESC"; return; }
            case "$k3" in
                A) KEY_SEQ="UP"   ;;
                B) KEY_SEQ="DOWN" ;;
                *) KEY_SEQ="ESC"  ;;
            esac
        else
            KEY_SEQ="ESC"
        fi
    elif [[ -z "$k1" || "$k1" == $'\n' || "$k1" == $'\r' ]]; then
        KEY_SEQ="ENTER"
    fi
}

_render_menu() {
    local prompt="$1" idx="$2" hint="$3"
    local -n _rm="$4"
    local count=${#_rm[@]} i
    printf "  ${COLOR_BOLD}%s${COLOR_RESET}\n" "$prompt" >&2
    printf "  ${COLOR_DIM}%s${COLOR_RESET}\n"  "$hint"   >&2
    for (( i=0; i<count; i++ )); do
        if (( i == idx )); then
            printf "    ${COLOR_GREEN}▶ ${COLOR_BOLD}%s${COLOR_RESET}\n" "${_rm[$i]}" >&2
        else
            printf "      ${COLOR_DIM}%s${COLOR_RESET}\n" "${_rm[$i]}" >&2
        fi
    done
}

select_menu() {
    local prompt="$1"
    local -n _sm_o="$2"
    local -n _sm_l="$3"
    local idx="${4:-0}"
    local hint="${5:-↑↓ navigate  ·  Enter select  ·  Esc back}"
    local count=${#_sm_o[@]}
    [[ $count -eq 0 ]] && return 1

    if [[ ! -t 0 || ! -t 2 ]] || ! command -v tput >/dev/null 2>&1; then
        local fb
        while true; do
            printf "  %s [1-%d]: " "$prompt" "$count" >&2
            read -r fb
            if [[ "$fb" =~ ^[0-9]+$ ]] && (( fb >= 1 && fb <= count )); then
                printf '%s' "${_sm_o[$((fb-1))]}"; return 0
            fi
            print_warn "Enter a number 1–$count."
        done
    fi

    local lines=$(( count + 2 ))
    _render_menu "$prompt" "$idx" "$hint" "$3"

    while true; do
        read_key
        case "$KEY_SEQ" in
            UP)
                (( idx-- )) || true; (( idx < 0 )) && idx=$(( count - 1 ))
                tput cuu "$lines" >&2
                _render_menu "$prompt" "$idx" "$hint" "$3"
                ;;
            DOWN)
                (( idx++ )) || true; (( idx >= count )) && idx=0
                tput cuu "$lines" >&2
                _render_menu "$prompt" "$idx" "$hint" "$3"
                ;;
            ENTER)
                echo >&2
                printf '%s' "${_sm_o[$idx]}"; return 0
                ;;
            ESC)
                local j
                for (( j=0; j<lines; j++ )); do tput cuu 1 >&2; tput el >&2; done
                return "$RC_ESC"
                ;;
        esac
    done
}

find_index() {
    local val="$1"; local -n _fi="$2"
    local i; for i in "${!_fi[@]}"; do [[ "${_fi[$i]}" == "$val" ]] && { echo "$i"; return; }; done
    echo 0
}

prompt_default() {
    local prompt="$1" default="$2" value
    printf "  ${COLOR_BOLD}%s${COLOR_RESET} ${COLOR_DIM}[%s]${COLOR_RESET}: " "$prompt" "$default" >&2
    read -r value
    printf '%s' "${value:-$default}"
}

prompt_secret() {
    local prompt="$1" default="${2:-}" value="" char
    while true; do
        if [[ -n "$default" ]]; then
            printf "  ${COLOR_BOLD}%s${COLOR_RESET} ${COLOR_DIM}[***]${COLOR_RESET}: " "$prompt" >&2
        else
            printf "  ${COLOR_BOLD}%s${COLOR_RESET}: " "$prompt" >&2
        fi
        while IFS= read -r -s -n1 char; do
            case "$char" in
                ''|$'\n'|$'\r') break ;;
                $'\177'|$'\b')
                    if [[ -n "$value" ]]; then value="${value%?}"; printf "\b \b" >&2; fi ;;
                *) value+="$char"; printf "*" >&2 ;;
            esac
        done
        printf "\n" >&2
        if [[ -z "$value" && -n "$default" ]]; then
            value="$default"
            break
        elif [[ -n "$value" ]]; then
            break
        else
            print_warn "Value cannot be empty."
        fi
    done
    printf '%s' "$value"
}

list_wifi_interfaces() {
    for p in /sys/class/net/*; do
        local iface; iface="$(basename "$p")"
        [[ -d "/sys/class/net/${iface}/wireless" ]] && echo "$iface"
    done
}

choose_wifi_interface() {
    local interfaces=() labels=()
    mapfile -t interfaces < <(list_wifi_interfaces)

    local used_ifaces=()
    mapfile -t used_ifaces < <(
        find "${ROOT_DIR}/country" -name '.env' -exec grep -h '^AP_IFACE=' {} \; 2>/dev/null | cut -d= -f2 || true
    )

    local available=()
    for iface in "${interfaces[@]}"; do
        local skip=0
        for used in "${used_ifaces[@]}"; do
            if [[ "$iface" == "$used" ]]; then
                if [[ "$iface" != "${AP_IFACE:-}" ]]; then
                    skip=1
                fi
                break
            fi
        done
        (( skip )) && continue
        available+=("$iface")
    done

    if [[ ${#available[@]} -eq 0 ]]; then
        print_warn "No free WiFi interfaces."
        printf '%s' "wlan1"
        return 0
    fi

    for iface in "${available[@]}"; do labels+=("$iface"); done
    local idx; idx=$(find_index "${AP_IFACE:-wlan1}" available)
    select_menu "Select WiFi interface" available labels "$idx"
}

ensure_nord_cache() {
    local now; now="$(date +%s)"
    if [[ -f "$NORD_CACHE" ]]; then
        local mtime
        mtime="$(stat -c %Y "$NORD_CACHE" 2>/dev/null || stat -f %m "$NORD_CACHE" 2>/dev/null || echo 0)"
        (( now - mtime < NORD_CACHE_TTL )) && return 0
    fi
    command -v curl >/dev/null 2>&1 || { print_warn "curl missing."; return 1; }
    command -v jq   >/dev/null 2>&1 || { print_warn "jq missing.";   return 1; }
    spinner_start "Fetching NordVPN server locations…"
    local raw
    if raw="$(curl -sf --max-time 15 "https://api.nordvpn.com/v1/servers/countries")"; then
        echo "$raw" > "$NORD_CACHE"
        spinner_stop done
        return 0
    else
        spinner_stop fail
        return 1
    fi
}

SELECTED_CITY=""
_CITY_TMP=""

_city_tmp_init()  { _CITY_TMP="$(mktemp /tmp/.nord_city.XXXXXX)"; : > "$_CITY_TMP"; }
_city_tmp_set()   { echo "$1" > "$_CITY_TMP"; }
_city_tmp_read()  { SELECTED_CITY=""; [[ -f "$_CITY_TMP" ]] && SELECTED_CITY="$(cat "$_CITY_TMP")"; rm -f "$_CITY_TMP"; _CITY_TMP=""; }

choose_nord_location() {
    if ! ensure_nord_cache; then
        prompt_default "VPN country" ""
        return 0
    fi
    if ! command -v fzf >/dev/null 2>&1; then
        local names=()
        mapfile -t names < <(jq -r '.[].name' "$NORD_CACHE" | sort)
        select_menu "Select Country" names names 0
        return
    fi
    local country city cities_json city_count
    print_info "Use ↑/↓ arrows or type to search. Enter to confirm. Esc to cancel."
    country="$(
        jq -r '.[].name' "$NORD_CACHE" | sort \
        | fzf --prompt "  🌍 Country ❯ " --height=40% --border=rounded \
              --pointer="▶" \
              --color="border:#4a90d9,prompt:#7ec8e3,pointer:#00c896" 2>/dev/tty
    )" || return "$RC_ESC"
    
    cities_json="$(jq -r --arg c "$country" '.[] | select(.name==$c) | .cities[].name' "$NORD_CACHE" 2>/dev/null)"
    city_count="$(echo "$cities_json" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"

    if (( city_count > 1 )); then
        city="$(
            { echo "(Any — country only)"; echo "$cities_json"; } \
            | fzf --prompt "  🏙  City ❯ " --height=40% --border=rounded \
                  --pointer="▶" \
                  --color="border:#4a90d9,prompt:#7ec8e3,pointer:#00c896" 2>/dev/tty
        )" || city="(Any — country only)"
        [[ "$city" != "(Any — country only)" && -n "$city" ]] && _city_tmp_set "$city"
    fi
    printf '%s' "$country"
}

# ─── Wizard Steps ─────────────────────────────────────────────────────────────

_step_network_interface() {
    print_step "Network Interface"
    local r
    r="$(choose_wifi_interface)" || return "$RC_ESC"
    AP_IFACE="$r"
    print_success "Interface: ${AP_IFACE}"
}

_step_vpn_protocol() {
    print_step "VPN Protocol"
    local opts=("wireguard" "openvpn")
    local lbls=("WireGuard / NordLynx (recommended)" "OpenVPN")
    local idx; idx=$(find_index "${VPN_TYPE:-wireguard}" opts)
    local r
    r="$(select_menu "Select VPN protocol" opts lbls "$idx")" || return "$RC_ESC"
    VPN_TYPE="$r"
    print_success "Protocol: ${VPN_TYPE}"
    return 0
}

_step_vpn_credentials() {
    local force="${1:-false}"
    # Check if we already have credentials for the selected type
    if [[ "$force" != "true" ]]; then
        if [[ "${VPN_TYPE:-wireguard}" == "openvpn" ]]; then
            if [[ -n "${OPENVPN_USER:-}" && -n "${OPENVPN_PASSWORD:-}" ]]; then
                return 0
            fi
        else
            if [[ -n "${WIREGUARD_PRIVATE_KEY:-}" && ${#WIREGUARD_PRIVATE_KEY} -ge 44 ]]; then
                return 0
            fi
        fi
    fi

    print_step "VPN Credentials"
    if [[ "${VPN_TYPE:-wireguard}" == "openvpn" ]]; then
        print_info "Use NordVPN service credentials (not account password)"
        OPENVPN_USER="$(prompt_secret "Service username" "${OPENVPN_USER:-}")"
        OPENVPN_PASSWORD="$(prompt_secret "Service password" "${OPENVPN_PASSWORD:-}")"
    else
        print_info "Get key: curl -s -u token:<TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key"
        while true; do
            WIREGUARD_PRIVATE_KEY="$(prompt_secret "NordLynx private key" "${WIREGUARD_PRIVATE_KEY:-}")"
            [[ ${#WIREGUARD_PRIVATE_KEY} -ge 44 ]] && break
            print_warn "Key too short (${#WIREGUARD_PRIVATE_KEY} chars). Must be ≥ 44."
        done
    fi
    save_credentials
    return 0
}

_step_firewall() {
    print_step "Firewall"
    FIREWALL_OUTBOUND_SUBNETS="$(prompt_default "Host LAN CIDR (kill-switch bypass)" "${FIREWALL_OUTBOUND_SUBNETS:-192.168.50.10/32}")"
    return 0
}

_step_hotspot_settings() {
    print_step "Hotspot Settings"
    AP_SSID="$(prompt_default "SSID" "${AP_SSID:-ap_${INSTANCE}}")"
    [[ "${AP_PASSWORD:-}" == "ChangeMe123!" ]] && AP_PASSWORD=""
    while true; do
        AP_PASSWORD="$(prompt_secret "Password (min 8 chars)" "${AP_PASSWORD:-}")"
        [[ ${#AP_PASSWORD} -ge 8 ]] && break
        print_warn "Password must be ≥ 8 chars."
    done
    AP_CHANNEL="$(prompt_default "WiFi channel" "${AP_CHANNEL:-6}")"
    AP_IP="$(prompt_default "Gateway IP" "${AP_IP:-192.168.60.1}")"
    AP_SUBNET="$(prompt_default "Subnet CIDR" "${AP_SUBNET:-192.168.60.0/24}")"
    return 0
}

_step_security_settings() {
    print_step "WiFi Security"
    local opts=("wpa2" "wpa3" "mixed")
    local lbls=("WPA2-PSK" "WPA3-SAE" "WPA2/WPA3 Mixed")
    local idx; idx=$(find_index "${AP_SECURITY:-wpa2}" opts)
    local r
    r="$(select_menu "Security mode" opts lbls "$idx")" || return "$RC_ESC"
    AP_SECURITY="$r"
    print_success "Security: ${AP_SECURITY}"
}

# ─── Credentials (Global) ─────────────────────────────────────────────────────
save_credentials() {
    local old_umask=$(umask)
    umask 077
    cat > "$CREDENTIALS_FILE" <<EOF
OPENVPN_USER="${OPENVPN_USER:-}"
OPENVPN_PASSWORD="${OPENVPN_PASSWORD:-}"
WIREGUARD_PRIVATE_KEY="${WIREGUARD_PRIVATE_KEY:-}"
EOF
    umask "$old_umask"
    chmod 600 "$CREDENTIALS_FILE"
    print_success "Credentials saved globally."
}

load_credentials() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    set -a
    source "$CREDENTIALS_FILE"
    set +a
}

# ─── Env (Per-instance) ───────────────────────────────────────────────────────
save_env() {
    local old_umask=$(umask)
    umask 077
    cat > "$ENV_FILE" <<EOF
INSTANCE=${INSTANCE}
ROUTING_TABLE=${ROUTING_TABLE:-100}
VPN_TYPE=${VPN_TYPE:-wireguard}
SERVER_COUNTRIES=${SERVER_COUNTRIES:-}
SERVER_CITIES=${SERVER_CITIES:-}
FIREWALL_OUTBOUND_SUBNETS=${FIREWALL_OUTBOUND_SUBNETS:-192.168.50.10/32}
AP_IFACE=${AP_IFACE:-}
AP_SSID=${AP_SSID:-}
AP_PASSWORD=${AP_PASSWORD:-}
AP_CHANNEL=${AP_CHANNEL:-6}
AP_HW_MODE=${AP_HW_MODE:-g}
AP_CHANNEL_WIDTH=${AP_CHANNEL_WIDTH:-20}
AP_IP=${AP_IP:-192.168.60.1}
AP_SUBNET=${AP_SUBNET:-192.168.60.0/24}
AP_SECURITY=${AP_SECURITY:-wpa2}
EOF
    umask "$old_umask"
    chmod 600 "$ENV_FILE"
    
    # We inject global credentials dynamically in manage.sh or docker-compose, 
    print_success "Config saved: $ENV_FILE"
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return 0
    set -a
    source "$ENV_FILE"
    set +a
    load_credentials
}

configure_env_full() {
    local -a step_fns=(
        _step_vpn_protocol
        _step_vpn_credentials
        _step_network_interface
        _step_firewall
        _step_hotspot_settings
        _step_security_settings
    )
    local i=0
    while (( i < ${#step_fns[@]} )); do
        if "${step_fns[$i]}"; then
            (( i++ )) || true
        else
            local rc=$?
            if (( rc == RC_ESC )); then
                if (( i > 0 )); then
                    (( i-- )) || true
                else
                    print_warn "Already at first step."
                fi
            else
                return "$rc"
            fi
        fi
    done
    save_env
}

configure_env_selective() {
    local opts=("protocol" "credentials" "network" "firewall" "hotspot" "security" "done")
    while true; do
        local lbls=(
            "VPN Protocol         ${COLOR_DIM}[${VPN_TYPE:-not set}]${COLOR_RESET}"
            "VPN Credentials      ${COLOR_DIM}[***]${COLOR_RESET}"
            "Network Interface    ${COLOR_DIM}[${AP_IFACE:-not set}]${COLOR_RESET}"
            "Firewall Settings    ${COLOR_DIM}[${FIREWALL_OUTBOUND_SUBNETS:-not set}]${COLOR_RESET}"
            "Hotspot / SSID       ${COLOR_DIM}[${AP_SSID:-not set}]${COLOR_RESET}"
            "WiFi Security        ${COLOR_DIM}[${AP_SECURITY:-not set}]${COLOR_RESET}"
            "${COLOR_GREEN}${COLOR_BOLD}✔  Save and continue${COLOR_RESET}"
        )
        local choice
        choice="$(select_menu "Edit configuration" opts lbls 0 \
            "↑↓ navigate  ·  Enter edit  ·  Esc → Back")" || return "$RC_ESC"
        case "$choice" in
            done)        save_env; return 0 ;;
            protocol)    _step_vpn_protocol || true ;;
            credentials) _step_vpn_credentials "true" || true ;;
            network)     _step_network_interface || true ;;
            firewall)    _step_firewall || true ;;
            hotspot)     _step_hotspot_settings || true ;;
            security)    _step_security_settings  || true ;;
        esac
    done
}

# ─── Dependency Check ─────────────────────────────────────────────────────────

check_dependencies() {
    local dep_file="${ROOT_DIR}/.deps_ok"
    [[ -f "$dep_file" ]] && return 0

    local missing=()
    local deps=("curl" "jq" "fzf" "docker")
    
    for d in "${deps[@]}"; do
        if ! command -v "$d" >/dev/null 2>&1; then
            missing+=("$d")
        fi
    done

    # Check for docker compose (v2) or docker-compose (v1)
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        missing+=("docker-compose")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        touch "$dep_file"
        return 0
    fi

    print_error "Missing required dependencies: ${missing[*]}"
    
    local os_id="unknown"
    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    echo >&2
    case "$os_id" in
        ubuntu|debian|raspberrypi|pop|mint)
            print_info "To install on $os_id:"
            echo "  sudo apt update && sudo apt install -y ${missing[*]}" >&2
            ;;
        fedora)
            print_info "To install on Fedora:"
            echo "  sudo dnf install -y ${missing[*]}" >&2
            ;;
        arch|manjaro)
            print_info "To install on Arch:"
            echo "  sudo pacman -S ${missing[*]}" >&2
            ;;
        *)
            print_info "Please install the following packages using your package manager: ${missing[*]}"
            ;;
    esac
    echo >&2
    exit 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    cd "$ROOT_DIR"
    setup_colors
    check_dependencies
    print_banner

    load_credentials

    while true; do
        local top_opts=("new" "existing" "manage" "delete" "credentials")
        local top_lbls=(
            "🌍 Create new VPN profile"
            "✎  Edit existing profile"
            "⏹  Manage Activity"
            "🗑  Delete profile"
            "🔑 Update VPN credentials"
        )
        local top_choice
        while true; do
            top_choice="$(select_menu "Main Menu" top_opts top_lbls 0 \
                "↑↓ navigate  ·  Enter select  ·  Esc quit")" || { print_info "Exiting."; exit 0; }
            [[ -n "$top_choice" ]] && break
        done

        if [[ "$top_choice" == "credentials" ]]; then
            local cred_opts=("wireguard" "openvpn")
            local cred_lbls=("WireGuard / NordLynx" "OpenVPN")
            local c
            while true; do
                c="$(select_menu "Select credentials to update" cred_opts cred_lbls 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || break
                break
            done
            [[ -z "$c" ]] && continue
            
            local old_vpn="${VPN_TYPE:-wireguard}"
            VPN_TYPE="$c"
            _step_vpn_credentials "true"
            VPN_TYPE="$old_vpn"
            continue
        fi

        if [[ "$top_choice" == "delete" ]]; then
            local del_profiles=()
            mapfile -t del_profiles < <(find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort || true)
            if [[ ${#del_profiles[@]} -eq 0 ]]; then
                print_warn "No profiles to delete."
                continue
            fi

            local del_choice
            while true; do
                del_choice="$(select_menu "Select profile to delete" del_profiles del_profiles 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || break
                break
            done
            [[ -z "${del_choice:-}" ]] && continue

            echo >&2
            print_warn "This will permanently delete profile '${del_choice}' and all its config."
            local confirm
            read -r -p "  Type 'delete' to confirm: " confirm
            if [[ "$confirm" != "delete" ]]; then
                print_info "Aborted."
                continue
            fi

            # Stop containers if running
            if [[ "$(docker inspect -f '{{.State.Status}}' "wifi-ap-${del_choice}" 2>/dev/null || true)" == "running" ]] || \
               [[ "$(docker inspect -f '{{.State.Status}}' "gluetun-${del_choice}" 2>/dev/null || true)" == "running" ]]; then
                print_info "Stopping running containers first..."
                bash "$MANAGE" down "$del_choice" 2>/dev/null || true
            fi

            rm -rf "${ROOT_DIR}/country/${del_choice}"
            print_success "Profile '${del_choice}' deleted."
            continue
        fi

        if [[ "$top_choice" == "manage" ]]; then
            # Step 1: pick the action
            local manage_opts=("start" "stop" "down")
            local manage_lbls=(
                "▶  Start a profile"
                "⏸  Stop  (keeps containers, can restart quickly)"
                "⏹  Down  (removes containers + wifi-ap image)"
            )
            local manage_action
            while true; do
                manage_action="$(select_menu "Manage Activity" manage_opts manage_lbls 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || break
                break
            done
            [[ -z "${manage_action:-}" ]] && continue

            # Step 2: build a filtered list of profiles relevant to the chosen action
            local all_profiles=() filtered=()
            mapfile -t all_profiles < <(find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort || true)

            for p in "${all_profiles[@]}"; do
                local is_running=0
                if [[ "$(docker inspect -f '{{.State.Status}}' "wifi-ap-$p" 2>/dev/null || true)" == "running" ]] || \
                   [[ "$(docker inspect -f '{{.State.Status}}' "gluetun-$p" 2>/dev/null || true)" == "running" ]]; then
                    is_running=1
                fi
                case "$manage_action" in
                    start) (( is_running == 0 )) && filtered+=("$p") ;;
                    stop|down) (( is_running == 1 )) && filtered+=("$p") ;;
                esac
            done

            if [[ ${#filtered[@]} -eq 0 ]]; then
                case "$manage_action" in
                    start) print_warn "All profiles are already running." ;;
                    *)     print_warn "No active profiles running." ;;
                esac
                continue
            fi

            # Step 3: pick the profile
            local stack_choice
            while true; do
                stack_choice="$(select_menu "Select profile to ${manage_action}" filtered filtered 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → Action menu")" || break
                break
            done
            [[ -z "${stack_choice:-}" ]] && continue

            case "$manage_action" in
                start)
                    print_info "Starting ${stack_choice}..."
                    bash "$MANAGE" start "$stack_choice"
                    ;;
                stop)
                    print_info "Stopping ${stack_choice}..."
                    bash "$MANAGE" stop "$stack_choice"
                    ;;
                down)
                    print_info "Tearing down ${stack_choice}..."
                    bash "$MANAGE" down "$stack_choice"
                    ;;
            esac
            continue
        fi

        if [[ "$top_choice" == "new" ]]; then
            _city_tmp_init
            SERVER_COUNTRIES="$(choose_nord_location)" || continue
            _city_tmp_read
            SERVER_CITIES="${SELECTED_CITY:-}"
            [[ -z "$SERVER_COUNTRIES" ]] && continue

            INSTANCE="$(echo "$SERVER_COUNTRIES" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_ -' | tr ' ' '_')"
            [[ -z "$INSTANCE" ]] && INSTANCE="vpn0"

            local inst_dir="${ROOT_DIR}/country/${INSTANCE}"
            ENV_FILE="${inst_dir}/.env"

            if [[ -d "$inst_dir" ]]; then
                print_warn "Profile '${INSTANCE}' already exists. Use 'Edit existing profile' instead."
                continue
            fi

            bash "$MANAGE" create "$INSTANCE"
            
            local _tmp_country="$SERVER_COUNTRIES"
            local _tmp_city="$SERVER_CITIES"
            load_env
            SERVER_COUNTRIES="${_tmp_country:-${SERVER_COUNTRIES:-}}"
            SERVER_CITIES="${_tmp_city:-${SERVER_CITIES:-}}"
            
            # Final fallback: if still empty or Netherlands, use Instance name
            if [[ -z "${SERVER_COUNTRIES:-}" || "$SERVER_COUNTRIES" == "Netherlands" ]]; then
                SERVER_COUNTRIES="${INSTANCE^}"
            fi

            if configure_env_full; then
                bash "$MANAGE" check-conflicts
                echo >&2
                read -r -p "  Start country profile '${INSTANCE}' now? [Y/n]: " go
                go="${go:-Y}"
                if [[ ! "$go" =~ ^[Nn]$ ]]; then
                    bash "$MANAGE" start "$INSTANCE"
                else
                    print_info "Run later: ./manage.sh start ${INSTANCE}"
                fi
            fi
            continue
        fi

        if [[ "$top_choice" == "existing" ]]; then
            local existing=()
            mapfile -t existing < <(find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort || true)
            if [[ ${#existing[@]} -eq 0 ]]; then
                print_warn "No existing profiles found."
                continue
            fi

            local stack_choice
            while true; do
                stack_choice="$(select_menu "Select profile" existing existing 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || break
                break
            done
            [[ -z "${stack_choice:-}" ]] && continue

            INSTANCE="$stack_choice"
            local inst_dir="${ROOT_DIR}/country/${INSTANCE}"
            ENV_FILE="${inst_dir}/.env"
            load_env
            if [[ -z "${SERVER_COUNTRIES:-}" || "$SERVER_COUNTRIES" == "Netherlands" ]]; then
                SERVER_COUNTRIES="${INSTANCE^}"
            fi

            local edit_opts=("reuse" "selective" "full")
            local edit_lbls=(
                "Use existing config as-is"
                "Edit selected values"
                "Full reconfiguration"
            )
            local mode
            while true; do
                mode="$(select_menu "Config: ${INSTANCE}" edit_opts edit_lbls 0 \
                    "↑↓ navigate  ·  Enter select  ·  Esc → stack list")" || break
                break
            done
            [[ -z "${mode:-}" ]] && continue

            case "$mode" in
                reuse)     
                    print_info "Using existing config."
                    bash "$MANAGE" start "$INSTANCE"
                    ;;
                selective) 
                    if configure_env_selective; then
                        bash "$MANAGE" check-conflicts
                        read -r -p "  Restart profile '${INSTANCE}' now? [Y/n]: " go
                        if [[ ! "${go:-Y}" =~ ^[Nn]$ ]]; then
                            bash "$MANAGE" restart "$INSTANCE"
                        fi
                    fi
                    ;;
                full)      
                    if configure_env_full; then
                        bash "$MANAGE" check-conflicts
                        read -r -p "  Restart profile '${INSTANCE}' now? [Y/n]: " go
                        if [[ ! "${go:-Y}" =~ ^[Nn]$ ]]; then
                            bash "$MANAGE" restart "$INSTANCE"
                        fi
                    fi
                    ;;
            esac
        fi

    done
}

main "$@"
