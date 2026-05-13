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

# ─── Colors ───────────────────────────────────────────────────────────────────
COLOR_RESET="" COLOR_BOLD="" COLOR_DIM=""
COLOR_BLUE=""  COLOR_CYAN="" COLOR_GREEN=""
COLOR_YELLOW="" COLOR_RED="" COLOR_WHITE=""

setup_colors() {
    [[ -t 2 ]] && command -v tput >/dev/null 2>&1 || return 0
    COLOR_RESET="$(tput sgr0)"
    COLOR_BOLD="$(tput bold)"
    COLOR_DIM="$(tput dim 2>/dev/null || true)"
    COLOR_BLUE="$(tput setaf 4)"
    COLOR_CYAN="$(tput setaf 6)"
    COLOR_GREEN="$(tput setaf 2)"
    COLOR_YELLOW="$(tput setaf 3)"
    COLOR_RED="$(tput setaf 1)"
    COLOR_WHITE="$(tput setaf 7)"
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
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r\033[2K" >&2
    [[ "${1:-}" == "fail" ]] && print_error "Failed."
}

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
_TMPFILES=()

_cleanup() {
    spinner_stop 2>/dev/null || true
    for f in "${_TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}
trap _cleanup EXIT

tmpfile_new() {
    local f; f="$(mktemp /tmp/.nordap.XXXXXX)"
    _TMPFILES+=("$f")
    echo "$f"
}

# ─── Key reading ──────────────────────────────────────────────────────────────
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

# ─── Menu ─────────────────────────────────────────────────────────────────────
_render_menu() {
    local prompt="$1" idx="$2" hint="$3"
    local -n _rm_items="$4"
    local count=${#_rm_items[@]} i
    printf "  ${COLOR_BOLD}%s${COLOR_RESET}\n" "$prompt" >&2
    printf "  ${COLOR_DIM}%s${COLOR_RESET}\n"  "$hint"   >&2
    for (( i=0; i<count; i++ )); do
        if (( i == idx )); then
            printf "    ${COLOR_GREEN}▶ ${COLOR_BOLD}%s${COLOR_RESET}\n" "${_rm_items[$i]}" >&2
        else
            printf "      ${COLOR_DIM}%s${COLOR_RESET}\n" "${_rm_items[$i]}" >&2
        fi
    done
}

# select_menu <prompt> <values_nameref> <labels_nameref> [initial_idx] [hint]
# prints selected value to stdout; returns RC_ESC on Escape
select_menu() {
    local prompt="$1"
    local -n _sm_vals="$2"
    local -n _sm_lbls="$3"
    local idx="${4:-0}"
    local hint="${5:-↑↓ navigate  ·  Enter select  ·  Esc back}"
    local count=${#_sm_vals[@]}

    [[ $count -eq 0 ]] && return 1

    # Non-interactive fallback
    if [[ ! -t 0 || ! -t 2 ]] || ! command -v tput >/dev/null 2>&1; then
        local fb
        while true; do
            printf "  %s [1-%d]: " "$prompt" "$count" >&2
            read -r fb
            if [[ "$fb" =~ ^[0-9]+$ ]] && (( fb >= 1 && fb <= count )); then
                printf '%s' "${_sm_vals[$((fb-1))]}"; return 0
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
                (( idx-- )) || true
                (( idx < 0 )) && idx=$(( count - 1 ))
                tput cuu "$lines" >&2
                _render_menu "$prompt" "$idx" "$hint" "$3"
                ;;
            DOWN)
                (( idx++ )) || true
                (( idx >= count )) && idx=0
                tput cuu "$lines" >&2
                _render_menu "$prompt" "$idx" "$hint" "$3"
                ;;
            ENTER)
                echo >&2
                printf '%s' "${_sm_vals[$idx]}"; return 0
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
    local val="$1"; local -n _fi_arr="$2"
    local i
    for i in "${!_fi_arr[@]}"; do
        [[ "${_fi_arr[$i]}" == "$val" ]] && { echo "$i"; return; }
    done
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
        value=""
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
            value="$default"; break
        elif [[ -n "$value" ]]; then
            break
        else
            print_warn "Value cannot be empty."
        fi
    done
    printf '%s' "$value"
}

# ─── WiFi interface ───────────────────────────────────────────────────────────
list_wifi_interfaces() {
    for p in /sys/class/net/*; do
        local iface; iface="$(basename "$p")"
        if [[ -d "/sys/class/net/${iface}/wireless" ]]; then
            local desc=""
            if command -v udevadm >/dev/null 2>&1; then
                local vendor model bus
                vendor=$(udevadm info -q property -p "/sys/class/net/${iface}" | grep "ID_VENDOR_FROM_DATABASE" | cut -d= -f2 || true)
                model=$(udevadm info -q property -p "/sys/class/net/${iface}" | grep "ID_MODEL_FROM_DATABASE" | cut -d= -f2 || true)
                bus=$(udevadm info -q property -p "/sys/class/net/${iface}" | grep "ID_BUS" | cut -d= -f2 || true)
                
                local label=""
                [[ -n "$vendor" ]] && label+="$vendor "
                [[ -n "$model" ]] && label+="$model "
                case "$bus" in
                    pci) label+="(Built-in)" ;;
                    usb) label+="(External)" ;;
                esac
                desc=$(echo $label) # trim
            fi
            echo "${iface}|${desc}"
        fi
    done
}

choose_wifi_interface() {
    local raw_data=()
    mapfile -t raw_data < <(list_wifi_interfaces)

    # Collect interfaces already claimed by other instances
    local used_ifaces=()
    mapfile -t used_ifaces < <(
        find "${ROOT_DIR}/country" -name '.env' \
            -exec grep -h '^AP_IFACE=' {} \; 2>/dev/null | cut -d= -f2 || true
    )

    local vals=()
    local lbls=()
    for line in "${raw_data[@]}"; do
        local iface="${line%%|*}"
        local desc="${line#*|}"
        
        local skip=0
        for used in "${used_ifaces[@]}"; do
            if [[ "$iface" == "$used" && "$iface" != "${AP_IFACE:-}" ]]; then
                skip=1; break
            fi
        done
        (( skip )) && continue
        
        vals+=("$iface")
        if [[ -n "$desc" ]]; then
            lbls+=("${iface} (${desc})")
        else
            lbls+=("${iface}")
        fi
    done

    if [[ ${#vals[@]} -eq 0 ]]; then
        print_warn "No free WiFi interfaces found."
        printf '%s' "${AP_IFACE:-wlan0}"
        return 0
    fi

    local idx; idx=$(find_index "${AP_IFACE:-wlan0}" vals)
    select_menu "Select WiFi interface" vals lbls "$idx"
}

# ─── NordVPN location picker ──────────────────────────────────────────────────
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
        spinner_stop
        return 0
    else
        spinner_stop fail
        return 1
    fi
}

# Sets SELECTED_COUNTRY and SELECTED_CITY (globals); returns RC_ESC on cancel
choose_nord_location() {
    SELECTED_COUNTRY=""
    SELECTED_CITY=""

    if ! ensure_nord_cache; then
        SELECTED_COUNTRY="$(prompt_default "VPN country" "")"
        return 0
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        local names=()
        mapfile -t names < <(jq -r '.[].name' "$NORD_CACHE" | sort)
        local r
        r="$(select_menu "Select Country" names names 0)" || return "$RC_ESC"
        SELECTED_COUNTRY="$r"
        return 0
    fi

    print_info "Type to search. Enter to confirm. Esc to cancel."
    local country
    country="$(
        jq -r '.[].name' "$NORD_CACHE" | sort \
        | fzf --prompt "  🌍 Country ❯ " --height=40% --border=rounded \
              --pointer="▶" \
              --color="border:#4a90d9,prompt:#7ec8e3,pointer:#00c896" 2>/dev/tty
    )" || return "$RC_ESC"

    SELECTED_COUNTRY="$country"

    local cities_json city_count
    cities_json="$(jq -r --arg c "$country" \
        '.[] | select(.name==$c) | .cities[].name' "$NORD_CACHE" 2>/dev/null || true)"
    city_count="$(echo "$cities_json" | grep -c '[^[:space:]]' 2>/dev/null || echo 0)"

    if (( city_count > 1 )); then
        local city
        city="$(
            { echo "(Any — country only)"; echo "$cities_json"; } \
            | fzf --prompt "  🏙  City ❯ " --height=40% --border=rounded \
                  --pointer="▶" \
                  --color="border:#4a90d9,prompt:#7ec8e3,pointer:#00c896" 2>/dev/tty
        )" || city="(Any — country only)"
        [[ "$city" != "(Any — country only)" && -n "$city" ]] && SELECTED_CITY="$city"
    fi
}

# ─── Wizard steps ─────────────────────────────────────────────────────────────
_step_vpn_protocol() {
    print_step "VPN Protocol"
    local opts=("wireguard" "openvpn")
    local lbls=("WireGuard / NordLynx (recommended)" "OpenVPN")
    local idx; idx=$(find_index "${VPN_TYPE:-wireguard}" opts)
    local r
    r="$(select_menu "Select VPN protocol" opts lbls "$idx")" || return "$RC_ESC"
    VPN_TYPE="$r"
    print_success "Protocol: ${VPN_TYPE}"
}

_step_vpn_credentials() {
    local force="${1:-false}"
    if [[ "$force" != "true" ]]; then
        if [[ "${VPN_TYPE:-wireguard}" == "openvpn" ]]; then
            [[ -n "${OPENVPN_USER:-}" && -n "${OPENVPN_PASSWORD:-}" ]] && return 0
        else
            [[ -n "${WIREGUARD_PRIVATE_KEY:-}" && ${#WIREGUARD_PRIVATE_KEY} -ge 44 ]] && return 0
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
}

_step_firewall() {
    print_step "Firewall"
    FIREWALL_OUTBOUND_SUBNETS="$(prompt_default \
        "Host LAN CIDR (kill-switch bypass)" \
        "${FIREWALL_OUTBOUND_SUBNETS:-192.168.50.10/32}")"
}

_step_hotspot() {
    print_step "Hotspot Settings"
    AP_SSID="$(prompt_default "SSID" "${AP_SSID:-ap_${INSTANCE}}")"
    [[ "${AP_PASSWORD:-}" == "ChangeMe123!" ]] && AP_PASSWORD=""
    while true; do
        AP_PASSWORD="$(prompt_secret "Password (min 8 chars)" "${AP_PASSWORD:-}")"
        [[ ${#AP_PASSWORD} -ge 8 ]] && break
        print_warn "Password must be ≥ 8 chars."
    done
    AP_CHANNEL="$(prompt_default "WiFi channel"  "${AP_CHANNEL:-6}")"
    AP_IP="$(prompt_default     "Gateway IP"     "${AP_IP:-192.168.60.1}")"
    AP_SUBNET="$(prompt_default "Subnet CIDR"    "${AP_SUBNET:-192.168.60.0/24}")"
}

_step_security() {
    print_step "WiFi Security"
    local opts=("wpa2" "wpa3" "mixed")
    local lbls=("WPA2-PSK" "WPA3-SAE" "WPA2/WPA3 Mixed")
    local idx; idx=$(find_index "${AP_SECURITY:-wpa2}" opts)
    local r
    r="$(select_menu "Security mode" opts lbls "$idx")" || return "$RC_ESC"
    AP_SECURITY="$r"
    print_success "Security: ${AP_SECURITY}"
}

_step_network_interface() {
    print_step "Network Interface"
    local r
    r="$(choose_wifi_interface)" || return "$RC_ESC"
    AP_IFACE="$r"
    print_success "Interface: ${AP_IFACE}"
}

# ─── Full sequential wizard with proper back-navigation ───────────────────────
configure_env_full() {
    local step_fns=(
        _step_vpn_protocol
        _step_vpn_credentials
        _step_network_interface
        _step_firewall
        _step_hotspot
        _step_security
    )
    local total=${#step_fns[@]}
    local i=0

    while (( i < total )); do
        if "${step_fns[$i]}"; then
            (( i++ ))
        else
            local rc=$?
            if (( rc == RC_ESC )); then
                if (( i > 0 )); then
                    (( i-- ))
                    print_info "Back to previous step."
                else
                    print_warn "Already at first step. Esc again to cancel."
                    # Give user a moment, then check if they want to abort entirely
                    local abort_opts=("continue" "cancel")
                    local abort_lbls=("Continue from start" "Cancel setup")
                    local choice
                    choice="$(select_menu "First step — what now?" abort_opts abort_lbls 0)" || return "$RC_ESC"
                    [[ "$choice" == "cancel" ]] && return "$RC_ESC"
                    # stay at i=0
                fi
            else
                return "$rc"
            fi
        fi
    done

    save_env
}

# ─── Selective edit menu ──────────────────────────────────────────────────────
configure_env_selective() {
    local opts=("protocol" "credentials" "network" "firewall" "hotspot" "security" "done")

    while true; do
        # Labels rebuilt each iteration so current values reflect edits
        local lbls=(
            "VPN Protocol         [${VPN_TYPE:-not set}]"
            "VPN Credentials      [***]"
            "Network Interface    [${AP_IFACE:-not set}]"
            "Firewall Settings    [${FIREWALL_OUTBOUND_SUBNETS:-not set}]"
            "Hotspot / SSID       [${AP_SSID:-not set}]"
            "WiFi Security        [${AP_SECURITY:-not set}]"
            "✔  Save and back to main menu"
        )
        local choice
        choice="$(select_menu "Edit configuration" opts lbls 0 \
            "↑↓ navigate  ·  Enter edit  ·  Esc → back")" || return "$RC_ESC"

        case "$choice" in
            done)        save_env; return 0 ;;
            protocol)    _step_vpn_protocol           || true ;;
            credentials) _step_vpn_credentials "true" || true ;;
            network)     _step_network_interface      || true ;;
            firewall)    _step_firewall                || true ;;
            hotspot)     _step_hotspot                 || true ;;
            security)    _step_security                || true ;;
        esac
    done
}

# ─── Credentials ──────────────────────────────────────────────────────────────
save_credentials() {
    local old_umask; old_umask=$(umask)
    umask 077
    cat > "$CREDENTIALS_FILE" <<EOF
OPENVPN_USER="${OPENVPN_USER:-}"
OPENVPN_PASSWORD="${OPENVPN_PASSWORD:-}"
WIREGUARD_PRIVATE_KEY="${WIREGUARD_PRIVATE_KEY:-}"
EOF
    umask "$old_umask"
    chmod 600 "$CREDENTIALS_FILE"
    print_success "Credentials saved."
}

load_credentials() {
    [[ -f "$CREDENTIALS_FILE" ]] || return 0
    set -a; source "$CREDENTIALS_FILE"; set +a
}

# ─── Per-instance env ─────────────────────────────────────────────────────────
save_env() {
    local old_umask; old_umask=$(umask)
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
    print_success "Config saved: $ENV_FILE"
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return 0
    set -a; source "$ENV_FILE"; set +a
    load_credentials
}

# Reset all instance-scoped vars to avoid cross-iteration bleed
reset_instance_vars() {
    INSTANCE="" ENV_FILE=""
    VPN_TYPE="" OPENVPN_USER="" OPENVPN_PASSWORD="" WIREGUARD_PRIVATE_KEY=""
    SERVER_COUNTRIES="" SERVER_CITIES=""
    FIREWALL_OUTBOUND_SUBNETS=""
    AP_IFACE="" AP_SSID="" AP_PASSWORD=""
    AP_CHANNEL="" AP_HW_MODE="" AP_CHANNEL_WIDTH=""
    AP_IP="" AP_SUBNET="" AP_SECURITY=""
    ROUTING_TABLE=""
    load_credentials   # re-apply global creds
}

is_instance_running() {
    local name="$1"
    local ap_st; ap_st="$(docker inspect -f '{{.State.Status}}' "wifi-ap-${name}" 2>/dev/null || true)"
    local gt_st; gt_st="$(docker inspect -f '{{.State.Status}}' "gluetun-${name}" 2>/dev/null || true)"
    [[ "$ap_st" == "running" || "$gt_st" == "running" ]]
}

# ─── Dependency check ─────────────────────────────────────────────────────────
check_dependencies() {
    local missing=() d
    for d in curl jq fzf docker; do
        command -v "$d" >/dev/null 2>&1 || missing+=("$d")
    done

    if ! docker compose version >/dev/null 2>&1 && \
       ! command -v docker-compose >/dev/null 2>&1; then
        missing+=("docker-compose")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    print_error "Missing dependencies: ${missing[*]}"
    echo >&2

    local os_id="unknown"
    [[ -f /etc/os-release ]] && \
        os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"

    case "$os_id" in
        ubuntu|debian|raspberrypi|pop|mint)
            print_info "Install on $os_id:"
            echo "  sudo apt update && sudo apt install -y ${missing[*]}" >&2 ;;
        fedora)
            print_info "Install on Fedora:"
            echo "  sudo dnf install -y ${missing[*]}" >&2 ;;
        arch|manjaro)
            print_info "Install on Arch:"
            echo "  sudo pacman -S ${missing[*]}" >&2 ;;
        *)
            print_info "Install with your package manager: ${missing[*]}" ;;
    esac
    echo >&2
    exit 1
}

# ─── Action handlers ──────────────────────────────────────────────────────────

action_new() {
    reset_instance_vars

    choose_nord_location || return 0   # ESC → back to main menu
    [[ -z "$SELECTED_COUNTRY" ]] && return 0

    SERVER_COUNTRIES="$SELECTED_COUNTRY"
    SERVER_CITIES="$SELECTED_CITY"

    # Derive instance name from country
    INSTANCE="$(echo "$SERVER_COUNTRIES" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9_ -' \
        | tr ' ' '_')"
    [[ -z "$INSTANCE" ]] && INSTANCE="vpn0"

    local inst_dir="${ROOT_DIR}/country/${INSTANCE}"
    ENV_FILE="${inst_dir}/.env"

    if [[ -d "$inst_dir" ]]; then
        print_warn "Profile '${INSTANCE}' already exists. Use 'Edit existing profile' instead."
        return 0
    fi

    bash "$MANAGE" create "$INSTANCE"

    # Load the generated .env but preserve our location selections
    load_env
    SERVER_COUNTRIES="$SELECTED_COUNTRY"
    SERVER_CITIES="$SELECTED_CITY"

    if configure_env_full; then
        bash "$MANAGE" check-conflicts
        echo >&2
        local go
        read -r -p "  Start profile '${INSTANCE}' now? [Y/n]: " go
        if [[ ! "${go:-Y}" =~ ^[Nn]$ ]]; then
            bash "$MANAGE" start "$INSTANCE"
        else
            print_info "Run later: ./manage.sh start ${INSTANCE}"
        fi
    fi
}

action_existing() {
    local existing=()
    mapfile -t existing < <(
        find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d \
            -exec basename {} \; 2>/dev/null | sort || true
    )
    if [[ ${#existing[@]} -eq 0 ]]; then
        print_warn "No existing profiles found."
        return 0
    fi

    local stack_choice
    stack_choice="$(select_menu "Select profile" existing existing 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || return 0

    reset_instance_vars
    INSTANCE="$stack_choice"
    ENV_FILE="${ROOT_DIR}/country/${INSTANCE}/.env"
    load_env

    local edit_opts=("reuse" "selective" "full")
    local edit_lbls=(
        "Use existing config as-is"
        "Edit selected values"
        "Full reconfiguration"
    )
    local mode
    mode="$(select_menu "Config: ${INSTANCE}" edit_opts edit_lbls 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → profile list")" || return 0

    case "$mode" in
        reuse)
            if is_instance_running "$INSTANCE"; then
                local go
                read -r -p "  Profile '${INSTANCE}' is already running. Restart it? [y/N]: " go
                if [[ "${go:-N}" =~ ^[Yy]$ ]]; then
                    bash "$MANAGE" restart "$INSTANCE"
                else
                    print_info "Leaving '${INSTANCE}' running."
                fi
            else
                print_info "Starting '${INSTANCE}'..."
                bash "$MANAGE" start "$INSTANCE"
            fi
            ;;
        selective)
            if configure_env_selective; then
                bash "$MANAGE" check-conflicts
                print_info "Configuration updated. Return to main menu."
            fi
            ;;
        full)
            if configure_env_full; then
                bash "$MANAGE" check-conflicts
                print_info "Configuration updated. Return to main menu."
            fi
            ;;
    esac
}

action_manage() {
    local manage_opts=("start" "stop" "down")
    local manage_lbls=(
        "▶  Start a profile"
        "⏸  Stop  (keeps containers)"
        "⏹  Down  (removes containers + image)"
    )
    local manage_action
    manage_action="$(select_menu "Manage Activity" manage_opts manage_lbls 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || return 0

    local all_profiles=()
    mapfile -t all_profiles < <(
        find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d \
            -exec basename {} \; 2>/dev/null | sort || true
    )

    # Filter by running state
    local filtered=()
    local p
    for p in "${all_profiles[@]}"; do
        local is_running=0
        is_instance_running "$p" && is_running=1

        case "$manage_action" in
            start) (( is_running == 0 )) && filtered+=("$p") ;;
            stop|down) (( is_running == 1 )) && filtered+=("$p") ;;
        esac
    done

    if [[ ${#filtered[@]} -eq 0 ]]; then
        case "$manage_action" in
            start) print_warn "All profiles already running." ;;
            *)     print_warn "No active profiles running." ;;
        esac
        return 0
    fi

    local stack_choice
    stack_choice="$(select_menu "Select profile to ${manage_action}" filtered filtered 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → action menu")" || return 0

    case "$manage_action" in
        start) print_info "Starting ${stack_choice}..."
               bash "$MANAGE" start "$stack_choice" ;;
        stop)  print_info "Stopping ${stack_choice}..."
               bash "$MANAGE" stop "$stack_choice" ;;
        down)  print_info "Tearing down ${stack_choice}..."
               bash "$MANAGE" down "$stack_choice" ;;
    esac
}

action_delete() {
    local profiles=()
    mapfile -t profiles < <(
        find "${ROOT_DIR}/country" -maxdepth 1 -mindepth 1 -type d \
            -exec basename {} \; 2>/dev/null | sort || true
    )
    if [[ ${#profiles[@]} -eq 0 ]]; then
        print_warn "No profiles to delete."
        return 0
    fi

    local del_choice
    del_choice="$(select_menu "Select profile to delete" profiles profiles 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || return 0

    echo >&2
    print_warn "Permanently delete profile '${del_choice}' and all its config."
    local confirm
    read -r -p "  Type 'delete' to confirm: " confirm
    if [[ "$confirm" != "delete" ]]; then
        print_info "Aborted."
        return 0
    fi

    if is_instance_running "${del_choice}"; then
        print_info "Stopping running containers first..."
        bash "$MANAGE" down "$del_choice" 2>/dev/null || true
    fi

    rm -rf "${ROOT_DIR}/country/${del_choice}"
    print_success "Profile '${del_choice}' deleted."
}

action_credentials() {
    local cred_opts=("wireguard" "openvpn")
    local cred_lbls=("WireGuard / NordLynx" "OpenVPN")
    local c
    c="$(select_menu "Select credentials to update" cred_opts cred_lbls 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || return 0

    local old_vpn="${VPN_TYPE:-wireguard}"
    VPN_TYPE="$c"
    _step_vpn_credentials "true" || true
    VPN_TYPE="$old_vpn"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    cd "$ROOT_DIR"
    setup_colors
    check_dependencies
    print_banner
    load_credentials

    local top_opts=("new" "existing" "manage" "delete" "credentials")
    local top_lbls=(
        "🌍 Create new VPN profile"
        "✎  Edit existing profile"
        "⏹  Manage Activity"
        "🗑  Delete profile"
        "🔑 Update VPN credentials"
    )

    while true; do
        local top_choice
        top_choice="$(select_menu "Main Menu" top_opts top_lbls 0 \
            "↑↓ navigate  ·  Enter select  ·  Esc quit")" || {
            print_info "Exiting."
            exit 0
        }

        case "$top_choice" in
            new)         action_new         ;;
            existing)    action_existing    ;;
            manage)      action_manage      ;;
            delete)      action_delete      ;;
            credentials) action_credentials ;;
            *)           print_warn "Unknown option: ${top_choice}" ;;
        esac
    done
}

main "$@"