#!/usr/bin/env bash
# startup.sh — interactive wizard, instance-aware
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORD_CACHE="${ROOT_DIR}/.nord_locations.json"
NORD_CACHE_TTL=86400
CREDENTIALS_FILE="${ROOT_DIR}/.env.credentials"
COUNTRY=""
COUNTRIES_DIR="${ROOT_DIR}/country"
COMPOSE_TEMPLATE="${ROOT_DIR}/docker-compose.template.yaml"

RC_ESC=2
AUDIT_RESULT=""

# ─── Colors ───────────────────────────────────────────────────────────────────
COLOR_RESET="" COLOR_BOLD="" COLOR_DIM=""
COLOR_BLUE=""  COLOR_CYAN="" COLOR_GREEN=""
COLOR_YELLOW="" COLOR_RED="" COLOR_WHITE=""

setup_colors() {
    [[ -t 2 ]] && command -v tput >/dev/null 2>&1 || return 0
    COLOR_RESET="$(tput sgr0 2>/dev/null || echo "")"
    COLOR_BOLD="$(tput bold 2>/dev/null || echo "")"
    COLOR_DIM="$(tput dim 2>/dev/null || echo "")"
    COLOR_BLUE="$(tput setaf 4 2>/dev/null || echo "")"
    COLOR_CYAN="$(tput setaf 6 2>/dev/null || echo "")"
    COLOR_GREEN="$(tput setaf 2 2>/dev/null || echo "")"
    COLOR_YELLOW="$(tput setaf 3 2>/dev/null || echo "")"
    COLOR_RED="$(tput setaf 1 2>/dev/null || echo "")"
    COLOR_WHITE="$(tput setaf 7 2>/dev/null || echo "")"
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

# ─── Management Helpers ────────────────────────────────────────────────────────

list_countries() {
    [[ -d "$COUNTRIES_DIR" ]] || { echo; return; }
    find "$COUNTRIES_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort
}

env_file() { echo "${COUNTRIES_DIR}/$1/.env"; }

load_country_env() {
    local country="$1"
    local ef; ef="$(env_file "$country")"
    [[ -f "$ef" ]] || { print_error "No .env for country '$country' at $ef"; exit 1; }
    set -a; source "$ef"; set +a
    load_credentials
}

compose_cmd() {
    local country="$1"; shift
    local ef; ef="$(env_file "$country")"
    COUNTRY="$country" docker compose \
        --project-name "$country" \
        --project-directory "$ROOT_DIR" \
        -f "$COMPOSE_TEMPLATE" \
        --env-file "$ef" \
        --env-file "${ROOT_DIR}/.env.credentials" \
        "$@"
}

container_running() {
    docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

_assert_country() {
    local country="$1"
    [[ -d "${COUNTRIES_DIR}/${country}" ]] || { print_error "Country '$country' not found."; exit 1; }
}

# ─── Shared purge helper ───────────────────────────────────────────────────────
# Removes containers (running OR stopped) and the wifi-ap image for a profile.
# Safe to call regardless of current container state.
_purge_country() {
    local country="$1"

    print_info "Purging containers and images for '${country}'..."

    # compose down handles running + stopped containers within the project
    compose_cmd "$country" down --remove-orphans --rmi all 2>/dev/null || true

    # Belt-and-suspenders: remove by explicit name in case compose project
    # mapping is stale or containers were created outside compose
    for cname in "gluetun-${country}" "wifi-ap-${country}"; do
        if docker inspect "$cname" &>/dev/null; then
            docker rm -f "$cname" 2>/dev/null && \
                print_info "Removed container: ${cname}" || true
        fi
    done

    # Explicitly remove the wifi-ap image — compose --rmi all is unreliable
    # for images built in prior sessions with a different compose invocation
    if docker image inspect "wifi-ap-image-${country}" &>/dev/null; then
        docker image rm -f "wifi-ap-image-${country}" 2>/dev/null && \
            print_info "Removed image: wifi-ap-image-${country}" || true
    fi
}

# ─── Management Commands ───────────────────────────────────────────────────────

cmd_list() {
    print_step "Countries"
    local countries; mapfile -t countries < <(list_countries)
    if [[ ${#countries[@]} -eq 0 ]]; then
        print_warn "No countries found."
        return
    fi

    printf "\n  ${COLOR_BOLD}%-12s %-12s %-16s %-16s %-20s${COLOR_RESET}\n" \
        "COUNTRY" "VPN" "GLUETUN" "WIFI-AP" "SSID"
    printf "  %s\n" "$(printf '%.0s─' {1..80})"

    for country in "${countries[@]}"; do
        local ef; ef="$(env_file "$country")"
        local vpn ssid gluetun_st wifiap_st
        vpn="$(grep -E '^VPN_TYPE=' "$ef" 2>/dev/null | cut -d= -f2 || echo '?')"
        ssid="$(grep -E '^AP_SSID=' "$ef" 2>/dev/null | cut -d= -f2 || echo '?')"

        if container_running "gluetun-${country}"; then
            gluetun_st="${COLOR_GREEN}running${COLOR_RESET}"
        else
            gluetun_st="${COLOR_RED}stopped${COLOR_RESET}"
        fi

        if container_running "wifi-ap-${country}"; then
            wifiap_st="${COLOR_GREEN}running${COLOR_RESET}"
        else
            wifiap_st="${COLOR_RED}stopped${COLOR_RESET}"
        fi

        printf "  %-12s %-12s %-25b %-25b %-20s\n" \
            "$country" "$vpn" "$gluetun_st" "$wifiap_st" "$ssid"
    done
    echo
}

cmd_create() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: create <country-name>"; exit 1; }
    [[ "$country" =~ ^[a-z0-9_-]+$ ]] || { print_error "Country name: lowercase alphanum/dash/underscore only"; exit 1; }

    local dir="${COUNTRIES_DIR}/${country}"
    local ef="${dir}/.env"

    if [[ -d "$dir" ]]; then
        print_warn "Country '$country' already exists at $dir"
        return
    fi

    mkdir -p "$dir/gluetun-state"

    # Auto-assign routing table — find next free ID starting at 100
    local used_tables=()
    mapfile -t used_tables < <(
        for i_dir in "${COUNTRIES_DIR}"/*/; do
            local i_env="${i_dir}.env"
            [[ -f "$i_env" ]] && grep -E '^ROUTING_TABLE=' "$i_env" | cut -d= -f2 || true
        done
    )
    local rt=100
    while [[ " ${used_tables[*]} " =~ " $rt " ]]; do (( rt++ )); done

    # Auto-assign subnet — 192.168.N.0/24 starting at 60
    local used_octets=()
    mapfile -t used_octets < <(
        for i_dir in "${COUNTRIES_DIR}"/*/; do
            local i_env="${i_dir}.env"
            [[ -f "$i_env" ]] && grep -E '^AP_IP=' "$i_env" | grep -oP '192\.168\.\K\d+' || true
        done
    )
    local octet=60
    while [[ " ${used_octets[*]} " =~ " $octet " ]]; do (( octet++ )); done

    cp "${ROOT_DIR}/.env.example" "$ef"
    local default_country="${country^}"

    sed -i \
        -e "s/^COUNTRY=.*/COUNTRY=${country}/" \
        -e "s/^ROUTING_TABLE=.*/ROUTING_TABLE=${rt}/" \
        -e "s/^AP_IP=.*/AP_IP=192.168.${octet}.1/" \
        -e "s/^AP_SUBNET=.*/AP_SUBNET=192.168.${octet}.0\/24/" \
        -e "s/^AP_SSID=.*/AP_SSID=ap_${country}/" \
        -e "s/^SERVER_COUNTRIES=.*/SERVER_COUNTRIES=${default_country}/" \
        "$ef"
    chmod 600 "$ef"

    print_success "Created country profile '${country}'"
    echo
}

cmd_start() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: start <country>"; exit 1; }
    _assert_country "$country"

    print_info "Starting country profile '$country'..."
    compose_cmd "$country" up -d --build
    print_success "Country profile '$country' started."
}

cmd_stop() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: stop <country>"; exit 1; }
    _assert_country "$country"

    print_info "Stopping country profile '$country'..."
    compose_cmd "$country" stop
    print_success "Country profile '$country' stopped."
}

cmd_down() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: down <country>"; exit 1; }
    _assert_country "$country"

    print_info "Tearing down country profile '$country' (removing containers + images)..."
    compose_cmd "$country" down --rmi all --remove-orphans || true
    # Explicit image removal — compose --rmi all may miss images from prior sessions
    docker image rm -f "wifi-ap-image-${country}" 2>/dev/null || true
    print_success "Country profile '$country' torn down."
}

cmd_restart() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: restart <country>"; exit 1; }
    _assert_country "$country"
    compose_cmd "$country" restart
    print_success "Country profile '$country' restarted."
}

cmd_start_all() {
    local countries; mapfile -t countries < <(list_countries)
    [[ ${#countries[@]} -eq 0 ]] && { print_warn "No country profiles."; return; }
    for country in "${countries[@]}"; do
        print_info "Starting '$country'..."
        compose_cmd "$country" up -d --build && print_success "$country up" || print_error "$country failed"
    done
}

cmd_stop_all() {
    local countries; mapfile -t countries < <(list_countries)
    [[ ${#countries[@]} -eq 0 ]] && { print_warn "No country profiles."; return; }
    for country in "${countries[@]}"; do
        print_info "Stopping '$country'..."
        compose_cmd "$country" down && print_success "$country down" || print_error "$country failed"
    done
}

cmd_logs() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: logs <country> [gluetun|wifi-ap]"; exit 1; }
    _assert_country "$country"
    local svc="${2:-}"
    if [[ -n "$svc" ]]; then
        docker logs "${svc}-${country}" -f
    else
        docker logs "gluetun-${country}" -f &
        docker logs "wifi-ap-${country}" -f &
        wait
    fi
}

cmd_status() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: status <country>"; exit 1; }
    _assert_country "$country"
    compose_cmd "$country" ps
}

cmd_health() {
    print_step "Health Check — All Countries"
    local countries; mapfile -t countries < <(list_countries)
    [[ ${#countries[@]} -eq 0 ]] && { print_warn "No country profiles."; return; }

    for country in "${countries[@]}"; do
        echo
        echo "  ${COLOR_BOLD}${country}${COLOR_RESET}"

        if container_running "gluetun-${country}"; then
            print_success "    gluetun-${country}: running"
            if docker exec "gluetun-${country}" ip link show tun0 &>/dev/null; then
                print_success "    tun0: up"
            else
                print_error "    tun0: missing — VPN not connected"
            fi
            local pub_ip
            pub_ip="$(docker exec "gluetun-${country}" \
                wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || echo 'unreachable')"
            print_info "    Public IP (via VPN): ${pub_ip}"
        else
            print_error "    gluetun-${country}: stopped"
        fi

        if container_running "wifi-ap-${country}"; then
            print_success "    wifi-ap-${country}: running"
            local ef; ef="$(env_file "$country")"
            local rt ap_sub
            rt="$(grep -E '^ROUTING_TABLE=' "$ef" | cut -d= -f2 || echo '?')"
            ap_sub="$(grep -E '^AP_SUBNET=' "$ef" | cut -d= -f2 || echo '?')"
            if ip rule show | grep -q "lookup ${rt}"; then
                print_success "    Routing table ${rt}: present"
            else
                print_warn "    Routing table ${rt}: missing (wifi-ap may still be starting)"
            fi
            print_info "    AP subnet: ${ap_sub}"
        else
            print_error "    wifi-ap-${country}: stopped"
        fi
    done
    echo
}

cmd_check_conflicts() {
    print_step "Conflict Check — All Countries"
    local countries; mapfile -t countries < <(list_countries)
    [[ ${#countries[@]} -eq 0 ]] && { print_warn "No country profiles."; return; }

    declare -A seen_iface seen_rt seen_subnet seen_ssid
    local conflicts=0

    for country in "${countries[@]}"; do
        local ef; ef="$(env_file "$country")"

        local iface rt subnet ssid
        iface="$(grep -E '^AP_IFACE=' "$ef" | cut -d= -f2)"
        rt="$(grep -E '^ROUTING_TABLE=' "$ef" | cut -d= -f2)"
        subnet="$(grep -E '^AP_SUBNET=' "$ef" | cut -d= -f2)"
        ssid="$(grep -E '^AP_SSID=' "$ef" | cut -d= -f2)"

        for key in iface rt subnet ssid; do
            local val="${!key}"
            local seen_var="seen_${key}"
            declare -n _seen="$seen_var"
            if [[ -n "${_seen[$val]+_}" ]]; then
                print_error "CONFLICT: ${key}='${val}' shared by '${_seen[$val]}' and '${country}'"
                (( conflicts++ ))
            else
                _seen[$val]="$country"
            fi
        done
    done

    if (( conflicts == 0 )); then
        print_success "No conflicts detected."
    else
        print_error "${conflicts} conflict(s) found. Fix .env files before starting."
    fi
    echo
}

cmd_delete() {
    local country="${1:-}"
    [[ -z "$country" ]] && { print_error "Usage: delete <country>"; exit 1; }
    _assert_country "$country"

    print_warn "This will stop and DELETE country profile '${country}' and all its config."
    read -r -p "  Type 'delete' to confirm: " confirm
    [[ "$confirm" != "delete" ]] && { print_info "Aborted."; return; }

    _purge_country "$country"
    rm -rf "${COUNTRIES_DIR}/${country}"
    print_success "Country profile '${country}' deleted."
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
    if [[ "${1:-}" == "fail" ]]; then
        print_error "Failed."
    fi
}

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
_TMPFILES=()

_cleanup() {
    spinner_stop 2>/dev/null || true
    if [[ ${#_TMPFILES[@]} -gt 0 ]]; then
        for f in "${_TMPFILES[@]}"; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done
    fi
    true
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
                *) KEY_SEQ="UNKNOWN" ;;
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

usage() {
    echo
    echo "${COLOR_BOLD}Usage:${COLOR_RESET} $0 [command] [args]"
    echo
    echo "${COLOR_BOLD}Wizard mode:${COLOR_RESET}"
    echo "  (no arguments)               Start interactive setup wizard"
    echo
    echo "${COLOR_BOLD}Management commands:${COLOR_RESET}"
    printf "  %-28s %s\n" "list" "List all country profiles + status"
    printf "  %-28s %s\n" "create <name>" "Create new country profile"
    printf "  %-28s %s\n" "delete <name>" "Stop + remove country profile"
    printf "  %-28s %s\n" "start <name>" "Build + start country profile"
    printf "  %-28s %s\n" "stop <name>" "Stop country profile"
    printf "  %-28s %s\n" "down <name>" "Tear down country profile"
    printf "  %-28s %s\n" "restart <name>" "Restart country profile"
    printf "  %-28s %s\n" "start-all" "Start all country profiles"
    printf "  %-28s %s\n" "stop-all" "Stop all country profiles"
    printf "  %-28s %s\n" "status <name>" "Docker compose ps for country profile"
    printf "  %-28s %s\n" "logs <name> [svc]" "Follow logs"
    printf "  %-28s %s\n" "health" "VPN connectivity + routing check all profiles"
    printf "  %-28s %s\n" "check-conflicts" "Detect duplicate iface/subnet/RT across profiles"
    echo
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
                desc=$(echo $label)
            fi
            echo "${iface}|${desc}"
        fi
    done
}

# ─── WiFi Audit ───────────────────────────────────────────────────────────────

audit_wifi_interface() {
    local iface="$1"

    if ! command -v iw >/dev/null 2>&1; then
        echo "6|g|20|wpa2"
        return
    fi

    local phy
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    if [[ -z "$phy" && -f "/sys/class/net/${iface}/phy80211/index" ]]; then
        phy="phy$(cat "/sys/class/net/${iface}/phy80211/index")"
    fi

    if [[ -z "$phy" ]]; then
        echo "6|g|20|wpa2"
        return
    fi

    local iw_list
    if ! iw_list=$(iw phy "$phy" info 2>/dev/null); then
        echo "6|g|20|wpa2"
        return
    fi

    if ! echo "$iw_list" | grep -A 25 "Supported interface modes:" | grep -q "^\s*\* AP$"; then
        echo "6|g|20|wpa2"
        return
    fi

    local has_24=0 has_5=0 has_ac=0 has_n=0
    [[ "$iw_list" =~ "Band 1" ]] && has_24=1
    [[ "$iw_list" =~ "Band 2" ]] && has_5=1
    [[ "$iw_list" =~ "HT20/HT40" ]] && has_n=1
    [[ "$iw_list" =~ "VHT Capabilities" ]] && has_ac=1

    local r_chan="6" r_hw="g" r_width="20"

    if [[ $has_5 -eq 1 ]]; then
        r_chan="36"; r_hw="a"
        [[ $has_ac -eq 1 ]] && r_width="80" || { [[ $has_n -eq 1 ]] && r_width="40"; }
    elif [[ $has_n -eq 1 ]]; then
        r_chan="1"; r_hw="g"; r_width="20"
    fi

    echo "${r_chan}|${r_hw}|${r_width}|wpa2|${has_24}|${has_5}|${has_ac}|${has_n}"
}

choose_wifi_interface() {
    local raw_data=()
    mapfile -t raw_data < <(list_wifi_interfaces)

    local used_ifaces=()
    mapfile -t used_ifaces < <(
        find "${COUNTRIES_DIR}" -name '.env' \
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

    AP_SSID="$(prompt_default            "Hotspot SSID"       "${AP_SSID:-ap_${COUNTRY}}")"
    AP_PASSWORD="$(prompt_default        "Hotspot Password"   "${AP_PASSWORD:-ChangeMe123!}")"

    if [[ -n "${AUDIT_RESULT:-}" ]]; then
        local audit="$AUDIT_RESULT"
        local s_chan="${audit%%|*}"
        local rest="${audit#*|}"
        local s_hw="${rest%%|*}"
        rest="${rest#*|}"
        local s_width="${rest%%|*}"
        rest="${rest#*|}"
        local s_sec="${rest%%|*}"
        rest="${rest#*|}"
        local has_24="${rest%%|*}"
        rest="${rest#*|}"
        local has_5="${rest%%|*}"
        rest="${rest#*|}"
        local has_ac="${rest%%|*}"
        rest="${rest#*|}"
        local has_n="${rest%%|*}"

        if [[ "$has_24" == "1" && "$has_5" == "1" ]]; then
            local b_opts=("2.4" "5")
            local b_lbls=("2.4 GHz (Longer range, slower)" "5 GHz (Shorter range, faster) (recommended)")
            local b_idx=1
            [[ "${AP_HW_MODE:-}" == "g" ]] && b_idx=0
            local b_val
            b_val=$(select_menu "Select WiFi Band" b_opts b_lbls "$b_idx") || return "$RC_ESC"
            if [[ "$b_val" == "5" ]]; then
                AP_HW_MODE="a"
                AP_CHANNEL="36"
                if [[ "$has_ac" == "1" ]]; then AP_CHANNEL_WIDTH="80"
                elif [[ "$has_n" == "1" ]]; then AP_CHANNEL_WIDTH="40"
                else AP_CHANNEL_WIDTH="20"; fi
            else
                AP_HW_MODE="g"
                AP_CHANNEL="6"
                AP_CHANNEL_WIDTH="20"
            fi
        else
            AP_CHANNEL="$s_chan"
            AP_HW_MODE="$s_hw"
            AP_CHANNEL_WIDTH="$s_width"
        fi
        AP_SECURITY="${AP_SECURITY:-$s_sec}"
    fi

    if [[ -n "${AP_CHANNEL:-}" && -n "${AP_HW_MODE:-}" && -n "${AP_CHANNEL_WIDTH:-}" ]]; then
        print_info "WiFi: Channel ${AP_CHANNEL}, Mode ${AP_HW_MODE}, Width ${AP_CHANNEL_WIDTH}"
    else
        AP_CHANNEL="${AP_CHANNEL:-6}"
        AP_HW_MODE="${AP_HW_MODE:-g}"
        AP_CHANNEL_WIDTH="${AP_CHANNEL_WIDTH:-20}"
        print_info "WiFi: Using default g/20MHz/Ch6"
    fi

    AP_IP="$(prompt_default            "Gateway IP"         "${AP_IP:-192.168.60.1}")"
    AP_SUBNET="$(prompt_default        "Subnet CIDR"        "${AP_SUBNET:-192.168.60.0/24}")"
}

_step_security() {
    print_step "WiFi Security"
    local opts=("wpa2" "wpa3" "mixed")
    local lbls=("WPA2-PSK (recommended)" "WPA3-SAE" "WPA2/WPA3 Mixed")
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

    spinner_start "Auditing WiFi hardware capabilities…"
    AUDIT_RESULT="$(audit_wifi_interface "$AP_IFACE")"
    spinner_stop
}

# ─── Full sequential wizard with back-navigation ──────────────────────────────
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
                    local abort_opts=("continue" "cancel")
                    local abort_lbls=("Continue from start" "Cancel setup")
                    local choice
                    choice="$(select_menu "First step — what now?" abort_opts abort_lbls 0)" || return "$RC_ESC"
                    [[ "$choice" == "cancel" ]] && return "$RC_ESC"
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

# ─── Per-country env ──────────────────────────────────────────────────────────
save_env() {
    local old_umask; old_umask=$(umask)
    umask 077
    cat > "$ENV_FILE" <<EOF
COUNTRY=${COUNTRY}

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

reset_country_vars() {
    COUNTRY="" ENV_FILE=""
    VPN_TYPE="" OPENVPN_USER="" OPENVPN_PASSWORD="" WIREGUARD_PRIVATE_KEY=""
    SERVER_COUNTRIES="" SERVER_CITIES=""
    FIREWALL_OUTBOUND_SUBNETS=""
    AP_IFACE="" AP_SSID="" AP_PASSWORD=""
    AP_CHANNEL="" AP_HW_MODE="" AP_CHANNEL_WIDTH=""
    AP_IP="" AP_SUBNET="" AP_SECURITY=""
    ROUTING_TABLE="" AUDIT_RESULT=""
    load_credentials
}

is_country_running() {
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
    print_step "Create New Country Profile"
    reset_country_vars

    local SELECTED_COUNTRY=""
    local SELECTED_CITY=""

    choose_nord_location || return 0
    [[ -z "$SELECTED_COUNTRY" ]] && return 0

    SERVER_COUNTRIES="$SELECTED_COUNTRY"
    SERVER_CITIES="$SELECTED_CITY"

    COUNTRY="$(echo "$SERVER_COUNTRIES" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    [[ -z "$COUNTRY" ]] && COUNTRY="vpn0"

    local country_dir="${COUNTRIES_DIR}/${COUNTRY}"
    if [[ -d "$country_dir" ]]; then
        print_warn "Profile '${COUNTRY}' already exists. Use 'Edit existing profile' instead."
        return 0
    fi

    cmd_create "$COUNTRY"
    load_country_env "$COUNTRY"
    ENV_FILE="$(env_file "$COUNTRY")"

    if configure_env_full; then
        cmd_check_conflicts
        echo >&2
        local go
        read -r -p "  Start profile '${COUNTRY}' now? [Y/n]: " go
        if [[ ! "${go:-Y}" =~ ^[Nn]$ ]]; then
            cmd_start "$COUNTRY"
        else
            print_info "Run later: ./startup.sh start ${COUNTRY}"
        fi
    fi
}

action_existing() {
    local existing=()
    mapfile -t existing < <(
        find "${COUNTRIES_DIR}" -maxdepth 1 -mindepth 1 -type d \
            -exec basename {} \; 2>/dev/null | sort || true
    )
    if [[ ${#existing[@]} -eq 0 ]]; then
        print_warn "No existing profiles found."
        return 0
    fi

    local stack_choice
    stack_choice="$(select_menu "Select profile" existing existing 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → Main Menu")" || return 0

    reset_country_vars
    COUNTRY="$stack_choice"
    ENV_FILE="${COUNTRIES_DIR}/${COUNTRY}/.env"
    load_country_env "$COUNTRY"

    local edit_opts=("reuse" "selective" "full")
    local edit_lbls=(
        "Use existing config as-is"
        "Edit selected values"
        "Full reconfiguration"
    )
    local mode
    mode="$(select_menu "Config: ${COUNTRY}" edit_opts edit_lbls 0 \
        "↑↓ navigate  ·  Enter select  ·  Esc → profile list")" || return 0

    case "$mode" in
        reuse)
            if is_country_running "$COUNTRY"; then
                local go
                read -r -p "  Profile '${COUNTRY}' is already running. Restart it? [y/N]: " go
                if [[ "${go:-N}" =~ ^[Yy]$ ]]; then
                    cmd_restart "$COUNTRY"
                else
                    print_info "Leaving '${COUNTRY}' running."
                fi
            else
                print_info "Starting '${COUNTRY}'..."
                cmd_start "$COUNTRY"
            fi
            ;;
        selective)
            if configure_env_selective; then
                cmd_check_conflicts
                print_info "Configuration updated. Return to main menu."
            fi
            ;;
        full)
            if configure_env_full; then
                cmd_check_conflicts
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
        find "${COUNTRIES_DIR}" -maxdepth 1 -mindepth 1 -type d \
            -exec basename {} \; 2>/dev/null | sort || true
    )

    local filtered=()
    local p
    for p in "${all_profiles[@]}"; do
        local is_running=0
        is_country_running "$p" && is_running=1

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
               cmd_start "$stack_choice" ;;
        stop)  print_info "Stopping ${stack_choice}..."
               cmd_stop "$stack_choice" ;;
        down)  print_info "Tearing down ${stack_choice}..."
               cmd_down "$stack_choice" ;;
    esac
}

action_delete() {
    local profiles=()
    mapfile -t profiles < <(
        find "${COUNTRIES_DIR}" -maxdepth 1 -mindepth 1 -type d \
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

    # _purge_country handles running containers, stopped containers, and the
    # wifi-ap image — no need to check is_country_running first
    _purge_country "${del_choice}"
    rm -rf "${COUNTRIES_DIR}/${del_choice}"
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

    local cmd="${1:-}"
    if [[ -n "$cmd" ]]; then
        shift || true
        case "$cmd" in
            list)            cmd_list ;;
            create)          cmd_create "$@" ;;
            start)           cmd_start "$@" ;;
            stop)            cmd_stop "$@" ;;
            down)            cmd_down "$@" ;;
            restart)         cmd_restart "$@" ;;
            start-all)       cmd_start_all ;;
            stop-all)        cmd_stop_all ;;
            logs)            cmd_logs "$@" ;;
            status)          cmd_status "$@" ;;
            health)          cmd_health ;;
            check-conflicts) cmd_check_conflicts ;;
            delete)          cmd_delete "$@" ;;
            help|--help|-h)  usage; exit 0 ;;
            *)               print_error "Unknown command: $cmd"; usage; exit 1 ;;
        esac
        return 0
    fi

    # Interactive mode
    check_dependencies
    print_banner
    load_credentials

    local top_opts=("new" "existing" "manage" "delete" "credentials" "quit")
    local top_lbls=(
        "🌍 Create new VPN profile"
        "✎  Edit existing profile"
        "⏹  Manage Activity"
        "🗑  Delete profile"
        "🔑 Update VPN credentials"
        "✖  Quit"
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
            quit)        print_info "Exiting."; exit 0 ;;
            *)           print_warn "Unknown option: ${top_choice}" ;;
        esac
    done
}

main "$@"
