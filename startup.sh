#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
NORD_CACHE="${ROOT_DIR}/.nord_locations.json"
NORD_CACHE_TTL=86400   # 24 h
SELECTED_VPN_TYPE=""


COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_WHITE=""
COLOR_BG_BLUE=""

setup_colors() {
    if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
        COLOR_RESET="$(tput sgr0)"
        COLOR_BOLD="$(tput bold)"
        COLOR_DIM="$(tput dim 2>/dev/null || echo "")"
        COLOR_BLUE="$(tput setaf 4)"
        COLOR_CYAN="$(tput setaf 6)"
        COLOR_GREEN="$(tput setaf 2)"
        COLOR_YELLOW="$(tput setaf 3)"
        COLOR_RED="$(tput setaf 1)"
        COLOR_WHITE="$(tput setaf 7)"
        COLOR_BG_BLUE="$(tput setab 4 2>/dev/null || echo "")"
    fi
}

# ─── Primitive printers ───────────────────────────────────────────────────────

print_info()    { echo "${COLOR_CYAN}  ℹ  $1${COLOR_RESET}" >&2; }
print_success() { echo "${COLOR_GREEN}  ✔  $1${COLOR_RESET}" >&2; }
print_warn()    { echo "${COLOR_YELLOW}  ⚠  $1${COLOR_RESET}" >&2; }
print_error()   { echo "${COLOR_RED}  ✖  $1${COLOR_RESET}" >&2; }

# ─── Banner ───────────────────────────────────────────────────────────────────

print_banner() {
    local width=50
    local title="  NordVPN AP Setup Wizard  "
    local pad=$(( (width - ${#title}) / 2 ))
    local line
    printf -v line '%*s' "$width" '' && line="${line// /─}"

    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}┌${line}┐${COLOR_RESET}" >&2
    printf "${COLOR_BOLD}${COLOR_BLUE}│%${pad}s${COLOR_WHITE}%s${COLOR_BLUE}%${pad}s│${COLOR_RESET}\n" \
        "" "$title" "" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}└${line}┘${COLOR_RESET}" >&2
    echo >&2
}

# ─── Step counter ─────────────────────────────────────────────────────────────

print_step() {
    local label="$1"
    echo >&2
    echo "${COLOR_BOLD}${COLOR_CYAN}  $label${COLOR_RESET}" >&2
}

# ─── Spinner ──────────────────────────────────────────────────────────────────

SPINNER_PID=""

spinner_start() {
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
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
    local result="${1:-done}"
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r\033[2K" >&2
    if [[ "$result" == "fail" ]]; then
        print_error "Failed."
    fi
}

# ─── Summary table ────────────────────────────────────────────────────────────

print_summary() {
    local iface="$1" vpn="$2" ssid="$3" gw="$4" country="$5" city="${6:-any}"
    local line="──────────────────────────────────────────────"

    echo >&2
    echo "${COLOR_BOLD}${COLOR_GREEN}  ╔${line}╗${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_GREEN}  ║     Configuration Summary               ║${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_GREEN}  ╠${line}╣${COLOR_RESET}" >&2

    _summary_row() {
        printf "${COLOR_BOLD}${COLOR_GREEN}  ║  ${COLOR_WHITE}%-18s${COLOR_RESET}  ${COLOR_CYAN}%-22s${COLOR_GREEN}  ║${COLOR_RESET}\n" "$1" "$2" >&2
    }

    _summary_row "Interface"   "$iface"
    _summary_row "VPN Type"    "$vpn"
    _summary_row "Country"     "$country"
    _summary_row "City"        "$city"
    _summary_row "SSID"        "$ssid"
    _summary_row "Gateway IP"  "$gw"

    echo "${COLOR_BOLD}${COLOR_GREEN}  ╚${line}╝${COLOR_RESET}" >&2
    echo >&2
}

# ─── WiFi helpers ─────────────────────────────────────────────────────────────

get_wifi_label() {
    local iface="$1"
    local label=""
    local sys_device="/sys/class/net/${iface}/device"

    if command -v udevadm >/dev/null 2>&1; then
        label="$(udevadm info -q property -p "$sys_device" 2>/dev/null | awk -F= '
            $1=="ID_MODEL_FROM_DATABASE"{print $2; found=1; exit}
            $1=="ID_MODEL" && !found {print $2; found=1; exit}
        ')"
    fi

    if [[ -z "$label" && -r "${sys_device}/vendor" && -r "${sys_device}/device" ]]; then
        local vid did
        vid="$(tr -d '\n' < "${sys_device}/vendor" | sed 's/^0x//')"
        did="$(tr -d '\n' < "${sys_device}/device" | sed 's/^0x//')"
        label="vendor:${vid} device:${did}"
    fi

    echo "${label:-unknown adapter}"
}

prompt_default() {
    local prompt="$1" default="$2" value
    read -r -p "  ${COLOR_BOLD}${prompt}${COLOR_RESET} ${COLOR_DIM}[${default}]${COLOR_RESET}: " value >&2
    echo "${value:-$default}"
}

prompt_secret() {
    local prompt="$1"
    local value="" char=""
    while [[ -z "$value" ]]; do
        printf "  ${COLOR_BOLD}%s${COLOR_RESET}: " "${prompt}" >&2
        while IFS= read -r -s -n1 char; do
            if [[ -z "$char" || "$char" == $'\n' ]]; then break; fi
            if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
                if [[ -n "$value" ]]; then value="${value%?}"; printf "\b \b" >&2; fi
            else
                value+="$char"; printf "*" >&2
            fi
        done
        echo >&2
        [[ -z "$value" ]] && print_warn "Value cannot be empty."
    done
    echo "$value"
}

# ─── Arrow menu ───────────────────────────────────────────────────────────────

render_arrow_menu() {
    local prompt="$1" selected_idx="$2"
    local labels_ref="$3"
    local -n _rl="$labels_ref"
    local i

    echo "  ${COLOR_BOLD}${prompt}${COLOR_RESET}" >&2
    for i in "${!_rl[@]}"; do
        if (( i == selected_idx )); then
            printf "    ${COLOR_GREEN}▶ ${COLOR_BOLD}%s${COLOR_RESET}\n" "${_rl[$i]}" >&2
        else
            printf "      ${COLOR_DIM}%s${COLOR_RESET}\n" "${_rl[$i]}" >&2
        fi
    done
}

select_with_arrows() {
    local prompt="$1" options_ref="$2" labels_ref="$3" default_idx="${4:-0}"
    local key selected_idx="$default_idx" line_count fallback
    local -n _so="$options_ref"
    local -n _sl="$labels_ref"

    [[ ${#_so[@]} -eq 0 ]] && return 1

    if [[ ! -t 0 || ! -t 2 ]] || ! command -v tput >/dev/null 2>&1; then
        while true; do
            read -r -p "  ${prompt} [1-${#_so[@]}]: " fallback
            if [[ "$fallback" =~ ^[0-9]+$ ]] && (( fallback >= 1 && fallback <= ${#_so[@]} )); then
                echo "${_so[$((fallback - 1))]}"; return 0
            fi
            print_warn "Invalid. Enter 1–${#_so[@]}."
        done
    fi

    line_count=$(( ${#_so[@]} + 1 ))
    render_arrow_menu "$prompt" "$selected_idx" "$labels_ref"

    while true; do
        IFS= read -r -s -n1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n2 key
            case "$key" in
                "[A") (( selected_idx-- )); (( selected_idx < 0 )) && selected_idx=$(( ${#_so[@]} - 1 )) ;;
                "[B") (( selected_idx++ )); (( selected_idx >= ${#_so[@]} )) && selected_idx=0 ;;
            esac
            tput cuu "$line_count" >&2
            render_arrow_menu "$prompt" "$selected_idx" "$labels_ref"
        elif [[ -z "$key" || "$key" == $'\n' ]]; then
            echo "${_so[$selected_idx]}"; return 0
        fi
    done
}

find_index() {
    local val="$1"
    local -n _arr="$2"
    local i
    for i in "${!_arr[@]}"; do
        if [[ "${_arr[$i]}" == "$val" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo 0
}

# ─── Interface / VPN selectors ────────────────────────────────────────────────

list_wifi_interfaces() {
    local iface
    for p in /sys/class/net/*; do
        iface="$(basename "$p")"
        [[ -d "/sys/class/net/${iface}/wireless" ]] && echo "$iface"
    done
}

detect_default_iface() {
    if command -v iw >/dev/null 2>&1; then
        iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}'
    else
        echo "wlan0"
    fi
}

choose_wifi_interface() {
    local interfaces=() labels=() idx label

    mapfile -t interfaces < <(list_wifi_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        print_warn "No WiFi interfaces auto-detected."
        prompt_default "WiFi interface for AP" "$(detect_default_iface)"
        return
    fi

    for idx in "${!interfaces[@]}"; do
        label="$(get_wifi_label "${interfaces[$idx]}")"
        labels+=("${interfaces[$idx]}  ${COLOR_DIM}[${label}]${COLOR_RESET}")
    done

    select_with_arrows "Select WiFi interface (↑↓ + Enter)" interfaces labels 0
}

step_vpn_protocol() {
    print_step "VPN Protocol"
    local options=("wireguard" "openvpn")
    local labels=("WireGuard  (NordLynx — recommended)" "OpenVPN")
    local idx
    idx=$(find_index "${VPN_TYPE:-wireguard}" options)
    VPN_TYPE="$(select_with_arrows "Select VPN protocol (↑↓ + Enter)" options labels "$idx")"
    print_success "Protocol: ${VPN_TYPE}"
}

# ─── NordVPN location data ────────────────────────────────────────────────────

ensure_nord_cache() {
    local now
    now="$(date +%s)"

    if [[ -f "$NORD_CACHE" ]]; then
        local mtime
        mtime="$(stat -c %Y "$NORD_CACHE" 2>/dev/null || stat -f %m "$NORD_CACHE" 2>/dev/null || echo 0)"
        if (( now - mtime < NORD_CACHE_TTL )); then
            return 0
        fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
        print_warn "curl not found — cannot fetch NordVPN locations."
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found — cannot parse NordVPN locations."
        return 1
    fi

    spinner_start "Fetching NordVPN server locations…"
    local raw
    if raw="$(curl -sf --max-time 15 "https://api.nordvpn.com/v1/servers/countries")"; then
        echo "$raw" > "$NORD_CACHE"
        spinner_stop done
        local count
        count="$(jq 'length' "$NORD_CACHE" 2>/dev/null || echo '?')"
        print_success "Cached ${count} countries."
        return 0
    else
        spinner_stop fail
        print_warn "Failed to fetch locations — falling back to manual entry."
        return 1
    fi
}

# ─── City tmpfile helpers (cross-subshell state) ──────────────────────────────
# SELECTED_CITY cannot be set inside $() subshells — use a tmpfile as IPC.

SELECTED_CITY=""
_CITY_TMPFILE=""

_city_tmp_init() {
    _CITY_TMPFILE="$(mktemp /tmp/.nord_city.XXXXXX)"
    : > "$_CITY_TMPFILE"
}

_city_tmp_set() {
    echo "$1" > "$_CITY_TMPFILE"
}

_city_tmp_read() {
    SELECTED_CITY=""
    [[ -f "$_CITY_TMPFILE" ]] && SELECTED_CITY="$(cat "$_CITY_TMPFILE")"
    rm -f "$_CITY_TMPFILE"
    _CITY_TMPFILE=""
}

# ─── Location picker ──────────────────────────────────────────────────────────

choose_nord_location() {
    if ! ensure_nord_cache; then
        prompt_default "VPN country (SERVER_COUNTRIES)" "India"
        return
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        print_warn "fzf not found — using numbered fallback."
        _choose_nord_location_fallback
        return
    fi

    _choose_nord_location_fzf
}

_choose_nord_location_fzf() {
    local country city cities_json city_count

    print_info "Type to search. Enter to confirm."
    country="$(
        jq -r '.[].name' "$NORD_CACHE" \
        | sort \
        | fzf \
            --prompt "  🌍 Country ❯ " \
            --height=40% \
            --border=rounded \
            --border-label=" NordVPN Country " \
            --border-label-pos=3 \
            --info=inline \
            --pointer="▶" \
            --highlight-line \
            --color="border:#4a90d9,label:#4a90d9,prompt:#7ec8e3,pointer:#00c896,hl:#00c896,hl+:#00c896" \
            2>/dev/tty
    )" || { print_warn "No country selected."; return 1; }

    print_success "Country: ${country}"

    cities_json="$(jq -r --arg c "$country" '.[] | select(.name==$c) | .cities[].name' "$NORD_CACHE" 2>/dev/null)"
    city_count="$(echo "$cities_json" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"

    if (( city_count > 1 )); then
        print_info "${city_count} cities available — pick one, or Esc for country-level."
        city="$(
            { echo "(Any — use country only)"; echo "$cities_json"; } \
            | fzf \
                --prompt "  🏙  City    ❯ " \
                --height=40% \
                --border=rounded \
                --border-label=" NordVPN City " \
                --border-label-pos=3 \
                --info=inline \
                --pointer="▶" \
                --highlight-line \
                --color="border:#4a90d9,label:#4a90d9,prompt:#7ec8e3,pointer:#00c896,hl:#00c896,hl+:#00c896" \
                2>/dev/tty
        )" || city="(Any — use country only)"

        if [[ "$city" != "(Any — use country only)" && -n "$city" ]]; then
            _city_tmp_set "$city"
            print_success "City: ${city}"
        else
            print_info "No city pin — best server in ${country}."
        fi
    elif (( city_count == 1 )); then
        local solo
        solo="$(echo "$cities_json" | head -1)"
        _city_tmp_set "$solo"
        print_info "Single city available: ${solo} (auto-selected)."
    fi

    echo "$country"
}

_choose_nord_location_fallback() {
    local names=() i choice country cities_json city_count city_arr=()

    mapfile -t names < <(jq -r '.[].name' "$NORD_CACHE" | sort)

    echo >&2
    for i in "${!names[@]}"; do
        printf "  ${COLOR_DIM}%3d)${COLOR_RESET} %s\n" "$(( i+1 ))" "${names[$i]}" >&2
    done
    echo >&2

    while true; do
        read -r -p "  Select country [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            country="${names[$((choice-1))]}"; break
        fi
        print_warn "Invalid — enter 1–${#names[@]}."
    done
    print_success "Country: ${country}"

    cities_json="$(jq -r --arg c "$country" '.[] | select(.name==$c) | .cities[].name' "$NORD_CACHE" 2>/dev/null)"
    city_count="$(echo "$cities_json" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"

    if (( city_count > 1 )); then
        mapfile -t city_arr <<< "$cities_json"
        echo >&2
        for i in "${!city_arr[@]}"; do
            printf "  ${COLOR_DIM}%3d)${COLOR_RESET} %s\n" "$(( i+1 ))" "${city_arr[$i]}" >&2
        done
        echo >&2
        read -r -p "  Select city [1-${#city_arr[@]}, Enter=any]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#city_arr[@]} )); then
            _city_tmp_set "${city_arr[$((choice-1))]}"
            print_success "City: ${city_arr[$((choice-1))]}"
        fi
    fi

    echo "$country"
}

# ─── Running container check ──────────────────────────────────────────────────

check_running_containers() {
    if [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
        return
    fi

    echo >&2
    echo "${COLOR_BOLD}${COLOR_YELLOW}  ┌─ Running stack detected ───────────────────┐${COLOR_RESET}" >&2
    echo "${COLOR_YELLOW}  │  The existing Docker Compose stack is running.  │${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_YELLOW}  └────────────────────────────────────────────┘${COLOR_RESET}" >&2
    echo >&2

    while true; do
        read -r -p "  Down the stack and continue, or exit? [Y/e]: " choice
        choice="${choice:-Y}"
        case "$choice" in
            Y|y)
                spinner_start "Taking stack down…"
                docker compose down >/dev/null 2>&1
                spinner_stop done
                print_success "Stack taken down."
                return
                ;;
            E|e)
                print_info "Exiting without changes."
                exit 0
                ;;
            *) print_warn "Enter Y to continue or e to exit." ;;
        esac
    done
}

# ─── .env writer ──────────────────────────────────────────────────────────────

# ─── Configuration Steps ──────────────────────────────────────────────────────

step_network_interface() {
    print_step "Network Interface"
    AP_IFACE="$(choose_wifi_interface)"
    print_success "Interface: ${AP_IFACE}"
}


step_vpn_credentials() {
    if [[ "$VPN_TYPE" == "openvpn" ]]; then
        print_step "NordVPN OpenVPN Credentials"
        print_info "Requires service credentials (not account password)."
        print_info "Get them: https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/service-credentials/"
        OPENVPN_USER="$(prompt_secret "NordVPN service username")"
        OPENVPN_PASSWORD="$(prompt_secret "NordVPN service password")"
    else
        print_step "NordLynx Private Key"
        print_info "Get key via: curl -s -u token:<YOUR_TOKEN> https://api.nordvpn.com/v1/users/services/credentials | jq -r .nordlynx_private_key"
        while true; do
            WIREGUARD_PRIVATE_KEY="$(prompt_secret "NordLynx private key")"
            local klen=${#WIREGUARD_PRIVATE_KEY}
            local stars
            printf -v stars '%*s' "$klen" '' && stars="${stars// /\*}"
            printf "  ${COLOR_DIM}%s${COLOR_RESET} ${COLOR_CYAN}(%d chars)${COLOR_RESET}\n" "$stars" "$klen" >&2
            [[ $klen -ge 44 ]] && break
            print_warn "Key too short (${klen} chars). NordLynx key must be ≥ 44 chars."
        done
    fi
}

step_vpn_location() {
    print_step "VPN Location"
    _city_tmp_init
    SERVER_COUNTRIES="$(choose_nord_location)"
    _city_tmp_read
    SERVER_CITIES="${SELECTED_CITY:-}"
    FIREWALL_OUTBOUND_SUBNETS="$(prompt_default "Host LAN CIDR for kill-switch bypass (FIREWALL_OUTBOUND_SUBNETS)" "${FIREWALL_OUTBOUND_SUBNETS:-192.168.50.145/32}")"
}

step_hotspot_settings() {
    print_step "Hotspot Settings"
    AP_SSID="$(prompt_default "SSID" "${AP_SSID:-NordVPN AP}")"
    while true; do
        AP_PASSWORD="$(prompt_secret "Password (min 8 chars)")"
        [[ ${#AP_PASSWORD} -ge 8 ]] && break
        print_warn "Password must be ≥ 8 chars."
    done
    AP_CHANNEL="$(prompt_default "WiFi channel" "${AP_CHANNEL:-6}")"
    AP_IP="$(prompt_default "Gateway IP" "${AP_IP:-192.168.60.1}")"
    AP_SUBNET="$(prompt_default "Subnet CIDR" "${AP_SUBNET:-192.168.60.0/24}")"
}

step_security_settings() {
    print_step "WiFi Security"
    local sec_options=("wpa2" "wpa3" "mixed")
    local sec_labels=("WPA2-PSK (Default)" "WPA3-SAE (Modern, requires newer devices)" "WPA2/WPA3 Mixed Mode")
    local idx
    idx=$(find_index "${AP_SECURITY:-wpa2}" sec_options)
    AP_SECURITY="$(select_with_arrows "Select security mode (↑↓ + Enter)" sec_options sec_labels "$idx")"
}

save_env() {
    cat > "$ENV_FILE" <<EOF
# Runtime profile
VPN_TYPE=${VPN_TYPE}

# NordVPN Credentials (OpenVPN)
OPENVPN_USER=${OPENVPN_USER:-}
OPENVPN_PASSWORD=${OPENVPN_PASSWORD:-}

# NordVPN Credentials (WireGuard / NordLynx)
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY:-}

# Shared VPN Settings
SERVER_COUNTRIES=${SERVER_COUNTRIES}
SERVER_CITIES=${SERVER_CITIES}
FIREWALL_OUTBOUND_SUBNETS=${FIREWALL_OUTBOUND_SUBNETS}

# Access Point Settings
AP_IFACE=${AP_IFACE}
AP_SSID=${AP_SSID}
AP_PASSWORD=${AP_PASSWORD}
AP_CHANNEL=${AP_CHANNEL}
AP_IP=${AP_IP}
AP_SUBNET=${AP_SUBNET}
AP_SECURITY=${AP_SECURITY}
EOF
    chmod 600 "$ENV_FILE"
    print_success "Configuration saved to .env"
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # Use a subshell to avoid polluting current shell if we only want to read, 
        # but here we actually want to load them.
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
}

configure_env_full() {
    # Initialize variables if not set
    VPN_TYPE="${VPN_TYPE:-wireguard}"
    OPENVPN_USER="${OPENVPN_USER:-}"
    OPENVPN_PASSWORD="${OPENVPN_PASSWORD:-}"
    WIREGUARD_PRIVATE_KEY="${WIREGUARD_PRIVATE_KEY:-}"
    SERVER_COUNTRIES="${SERVER_COUNTRIES:-}"
    SERVER_CITIES="${SERVER_CITIES:-}"
    FIREWALL_OUTBOUND_SUBNETS="${FIREWALL_OUTBOUND_SUBNETS:-}"
    AP_IFACE="${AP_IFACE:-}"
    AP_SSID="${AP_SSID:-}"
    AP_PASSWORD="${AP_PASSWORD:-}"
    AP_CHANNEL="${AP_CHANNEL:-}"
    AP_IP="${AP_IP:-}"
    AP_SUBNET="${AP_SUBNET:-}"
    AP_SECURITY="${AP_SECURITY:-}"

    step_network_interface
    step_vpn_protocol
    step_vpn_credentials
    step_vpn_location
    step_hotspot_settings
    step_security_settings

    save_env
    SELECTED_VPN_TYPE="${VPN_TYPE}"
    print_summary "$AP_IFACE" "$VPN_TYPE" "$AP_SSID" "$AP_IP" "$SERVER_COUNTRIES" "${SERVER_CITIES:-any}"
}

configure_env_selective() {
    load_env
    
    local options=("network" "vpn_type" "vpn_creds" "location" "hotspot" "security" "save_exit")
    local labels=(
        "Network Interface       [${AP_IFACE:-not set}]"
        "VPN Protocol            [${VPN_TYPE:-not set}]"
        "VPN Credentials         [********]"
        "VPN Location            [${SERVER_COUNTRIES:-any} / ${SERVER_CITIES:-any}]"
        "Hotspot (SSID/IP)       [${AP_SSID:-not set}]"
        "WiFi Security           [${AP_SECURITY:-not set}]"
        "${COLOR_GREEN}Save and Continue${COLOR_RESET}"
    )

    while true; do
        local choice
        choice=$(select_with_arrows "Select section to update (↑↓ + Enter):" options labels 0)

        case "$choice" in
            network)  step_network_interface ;;
            vpn_type) step_vpn_protocol ;;
            vpn_creds) step_vpn_credentials ;;
            location) step_vpn_location ;;
            hotspot)  step_hotspot_settings ;;
            security) step_security_settings ;;
            save_exit) 
                save_env
                SELECTED_VPN_TYPE="${VPN_TYPE}"
                print_summary "$AP_IFACE" "$VPN_TYPE" "$AP_SSID" "$AP_IP" "$SERVER_COUNTRIES" "${SERVER_CITIES:-any}"
                return 0 
                ;;
        esac
        
        # Update labels after change
        labels=(
            "Network Interface       [${AP_IFACE:-not set}]"
            "VPN Protocol            [${VPN_TYPE:-not set}]"
            "VPN Credentials         [********]"
            "VPN Location            [${SERVER_COUNTRIES:-any} / ${SERVER_CITIES:-any}]"
            "Hotspot (SSID/IP)       [${AP_SSID:-not set}]"
            "WiFi Security           [${AP_SECURITY:-not set}]"
            "${COLOR_GREEN}Save and Continue${COLOR_RESET}"
        )
    done
}

# ─── VPN type change cleanup ──────────────────────────────────────────────────

handle_vpn_type_change_cleanup() {
    local prev="$1" new="$2"
    [[ -z "$prev" || -z "$new" || "$prev" == "$new" ]] && return

    print_warn "VPN type changed: ${prev} → ${new}"
    print_info "Removing old containers + local images before rebuild…"

    spinner_start "Cleaning up old stack…"
    docker compose down --remove-orphans --rmi local >/dev/null 2>&1 || true
    docker rm -f gluetun wifi-ap >/dev/null 2>&1 || true
    spinner_stop done
    print_success "Cleanup done."
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
    cd "$ROOT_DIR"
    setup_colors
    print_banner
    check_running_containers

    local previous_vpn_type=""

    if [[ -f "$ENV_FILE" ]]; then
        load_env
        previous_vpn_type="${VPN_TYPE:-}"
        
        local menu_options=("reuse" "selective" "full")
        local menu_labels=("Reuse existing .env as-is" "Edit selected values" "Full reconfiguration (overwrite)")
        
        local mode
        mode=$(select_with_arrows "Existing .env found. How to proceed?" menu_options menu_labels 0)
        
        case "$mode" in
            reuse)
                SELECTED_VPN_TYPE="$previous_vpn_type"
                print_info "Using existing .env (VPN: ${SELECTED_VPN_TYPE})"
                ;;
            selective)
                configure_env_selective
                ;;
            full)
                configure_env_full
                ;;
        esac
    else
        print_info "No .env found — running first-time setup…"
        configure_env_full
    fi

    handle_vpn_type_change_cleanup "$previous_vpn_type" "$SELECTED_VPN_TYPE"

    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}  Launching stack…${COLOR_RESET}" >&2
    echo >&2

    spinner_start "Building images…"
    if docker compose up -d --build 2>&1; then
        spinner_stop done
        print_success "Stack is up."
    else
        spinner_stop fail
        print_error "docker compose up failed. Run: docker compose logs"
        exit 1
    fi

    echo >&2
    echo "${COLOR_BOLD}${COLOR_GREEN}  ✔ Done!${COLOR_RESET}" >&2
    echo "${COLOR_DIM}  Monitor: docker compose logs -f gluetun wifi-ap${COLOR_RESET}" >&2
    echo >&2
}

main "$@"
