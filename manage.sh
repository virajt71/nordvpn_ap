#!/usr/bin/env bash
# manage.sh — multi-instance VPN AP manager
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_TEMPLATE="${ROOT_DIR}/docker-compose.template.yaml"
INSTANCES_DIR="${ROOT_DIR}/country"

# ─── Colors ───────────────────────────────────────────────────────────────────
C_RST=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    C_RST="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim 2>/dev/null||echo)"
    C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"; C_GREEN="$(tput setaf 2)"
    C_YELLOW="$(tput setaf 3)"; C_RED="$(tput setaf 1)"
fi
ok()   { echo "${C_GREEN}  ✔  $*${C_RST}"; }
err()  { echo "${C_RED}  ✖  $*${C_RST}"; }
warn() { echo "${C_YELLOW}  ⚠  $*${C_RST}"; }
info() { echo "${C_CYAN}  ℹ  $*${C_RST}"; }
hdr()  { echo; echo "${C_BOLD}${C_BLUE}$*${C_RST}"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

list_instances() {
    [[ -d "$INSTANCES_DIR" ]] || { echo; return; }
    find "$INSTANCES_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort
}

env_file() { echo "${INSTANCES_DIR}/$1/.env"; }

load_instance_env() {
    local inst="$1"
    local ef; ef="$(env_file "$inst")"
    [[ -f "$ef" ]] || { err "No .env for instance '$inst' at $ef"; exit 1; }
    set -a; source "$ef"; set +a
}

compose_cmd() {
    local inst="$1"; shift
    local ef; ef="$(env_file "$inst")"
    INSTANCE="$inst" docker compose \
        --project-name "$inst" \
        --project-directory "$ROOT_DIR" \
        -f "$COMPOSE_TEMPLATE" \
        --env-file "$ef" \
        --env-file "${ROOT_DIR}/.env.credentials" \
        "$@"
}

container_running() {
    docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_list() {
    hdr "Instances"
    local instances; mapfile -t instances < <(list_instances)
    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No instances. Create one: $0 create <name>"
        return
    fi

    printf "\n  ${C_BOLD}%-12s %-12s %-16s %-16s %-20s${C_RST}\n" \
        "INSTANCE" "VPN" "GLUETUN" "WIFI-AP" "SSID"
    printf "  %s\n" "$(printf '%.0s─' {1..80})"

    for inst in "${instances[@]}"; do
        local ef; ef="$(env_file "$inst")"
        local vpn ssid gluetun_st wifiap_st
        vpn="$(grep -E '^VPN_TYPE=' "$ef" 2>/dev/null | cut -d= -f2 || echo '?')"
        ssid="$(grep -E '^AP_SSID=' "$ef" 2>/dev/null | cut -d= -f2 || echo '?')"

        if container_running "gluetun-${inst}"; then
            gluetun_st="${C_GREEN}running${C_RST}"
        else
            gluetun_st="${C_RED}stopped${C_RST}"
        fi

        if container_running "wifi-ap-${inst}"; then
            wifiap_st="${C_GREEN}running${C_RST}"
        else
            wifiap_st="${C_RED}stopped${C_RST}"
        fi

        printf "  %-12s %-12s %-25b %-25b %-20s\n" \
            "$inst" "$vpn" "$gluetun_st" "$wifiap_st" "$ssid"
    done
    echo
}

cmd_create() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 create <instance-name>"; exit 1; }
    [[ "$inst" =~ ^[a-z0-9_-]+$ ]] || { err "Instance name: lowercase alphanum/dash/underscore only"; exit 1; }

    local dir="${INSTANCES_DIR}/${inst}"
    local ef="${dir}/.env"

    if [[ -d "$dir" ]]; then
        warn "Instance '$inst' already exists at $dir"
        return
    fi

    mkdir -p "$dir/gluetun-state"

    # Auto-assign routing table — find next free ID starting at 100
    local used_tables=()
    mapfile -t used_tables < <(
        for i_dir in "${INSTANCES_DIR}"/*/; do
            local i_env="${i_dir}.env"
            [[ -f "$i_env" ]] && grep -E '^ROUTING_TABLE=' "$i_env" | cut -d= -f2 || true
        done
    )
    local rt=100
    while [[ " ${used_tables[*]} " =~ " $rt " ]]; do (( rt++ )); done

    # Auto-assign subnet — 192.168.N.0/24 starting at 60
    local used_octets=()
    mapfile -t used_octets < <(
        for i_dir in "${INSTANCES_DIR}"/*/; do
            local i_env="${i_dir}.env"
            [[ -f "$i_env" ]] && grep -E '^AP_IP=' "$i_env" | grep -oP '192\.168\.\K\d+' || true
        done
    )
    local octet=60
    while [[ " ${used_octets[*]} " =~ " $octet " ]]; do (( octet++ )); done

    cp "${ROOT_DIR}/.env.example" "$ef"
    # Capitalize first letter for country default
    local default_country="${inst^}"

    sed -i \
        -e "s/^INSTANCE=.*/INSTANCE=${inst}/" \
        -e "s/^ROUTING_TABLE=.*/ROUTING_TABLE=${rt}/" \
        -e "s/^AP_IP=.*/AP_IP=192.168.${octet}.1/" \
        -e "s/^AP_SUBNET=.*/AP_SUBNET=192.168.${octet}.0\/24/" \
        -e "s/^AP_SSID=.*/AP_SSID=ap_${inst}/" \
        -e "s/^SERVER_COUNTRIES=.*/SERVER_COUNTRIES=${default_country}/" \
        "$ef"
    chmod 600 "$ef"

    ok "Created instance '${inst}'"
    info "  Dir           : $dir"
    info "  .env          : $ef"
    info "  Routing table : $rt"
    info "  Subnet        : 192.168.${octet}.0/24"
    echo
    info "Then: $0 start $inst"
}

cmd_start() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 start <instance>"; exit 1; }
    _assert_instance "$inst"

    info "Starting instance '$inst'..."
    compose_cmd "$inst" up -d --build
    ok "Instance '$inst' started."
    info "Logs: $0 logs $inst"
}

cmd_stop() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 stop <instance>"; exit 1; }
    _assert_instance "$inst"

    info "Stopping instance '$inst'..."
    compose_cmd "$inst" stop
    ok "Instance '$inst' stopped."
}

cmd_down() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 down <instance>"; exit 1; }
    _assert_instance "$inst"

    info "Tearing down instance '$inst' (removing containers + images)..."
    compose_cmd "$inst" down --rmi local --remove-orphans
    ok "Instance '$inst' torn down."
}

cmd_restart() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 restart <instance>"; exit 1; }
    _assert_instance "$inst"
    compose_cmd "$inst" restart
    ok "Instance '$inst' restarted."
}

cmd_start_all() {
    local instances; mapfile -t instances < <(list_instances)
    [[ ${#instances[@]} -eq 0 ]] && { warn "No instances."; return; }
    for inst in "${instances[@]}"; do
        info "Starting '$inst'..."
        compose_cmd "$inst" up -d --build && ok "$inst up" || err "$inst failed"
    done
}

cmd_stop_all() {
    local instances; mapfile -t instances < <(list_instances)
    [[ ${#instances[@]} -eq 0 ]] && { warn "No instances."; return; }
    for inst in "${instances[@]}"; do
        info "Stopping '$inst'..."
        compose_cmd "$inst" down && ok "$inst down" || err "$inst failed"
    done
}

cmd_logs() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 logs <instance> [gluetun|wifi-ap]"; exit 1; }
    _assert_instance "$inst"
    local svc="${2:-}"
    if [[ -n "$svc" ]]; then
        docker logs "${svc}-${inst}" -f
    else
        docker logs "gluetun-${inst}" -f &
        docker logs "wifi-ap-${inst}" -f &
        wait
    fi
}

cmd_status() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 status <instance>"; exit 1; }
    _assert_instance "$inst"
    compose_cmd "$inst" ps
}

cmd_health() {
    hdr "Health Check — All Instances"
    local instances; mapfile -t instances < <(list_instances)
    [[ ${#instances[@]} -eq 0 ]] && { warn "No instances."; return; }

    for inst in "${instances[@]}"; do
        echo
        echo "  ${C_BOLD}${inst}${C_RST}"

        # Gluetun running?
        if container_running "gluetun-${inst}"; then
            ok "    gluetun-${inst}: running"
            # Check tun0 inside gluetun
            if docker exec "gluetun-${inst}" ip link show tun0 &>/dev/null; then
                ok "    tun0: up"
            else
                err "    tun0: missing — VPN not connected"
            fi
            # Check public IP via gluetun
            local pub_ip
            pub_ip="$(docker exec "gluetun-${inst}" \
                wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || echo 'unreachable')"
            info "    Public IP (via VPN): ${pub_ip}"
        else
            err "    gluetun-${inst}: stopped"
        fi

        # wifi-ap running?
        if container_running "wifi-ap-${inst}"; then
            ok "    wifi-ap-${inst}: running"
            # Check routing table
            local ef; ef="$(env_file "$inst")"
            local rt ap_sub
            rt="$(grep -E '^ROUTING_TABLE=' "$ef" | cut -d= -f2 || echo '?')"
            ap_sub="$(grep -E '^AP_SUBNET=' "$ef" | cut -d= -f2 || echo '?')"
            if ip rule show | grep -q "lookup ${rt}"; then
                ok "    Routing table ${rt}: present"
            else
                warn "    Routing table ${rt}: missing (wifi-ap may still be starting)"
            fi
            info "    AP subnet: ${ap_sub}"
        else
            err "    wifi-ap-${inst}: stopped"
        fi
    done
    echo
}

cmd_delete() {
    local inst="${1:-}"
    [[ -z "$inst" ]] && { err "Usage: $0 delete <instance>"; exit 1; }
    _assert_instance "$inst"

    warn "This will stop and DELETE instance '${inst}' and all its config."
    read -r -p "  Type 'delete' to confirm: " confirm
    [[ "$confirm" != "delete" ]] && { info "Aborted."; return; }

    compose_cmd "$inst" down --remove-orphans --rmi local 2>/dev/null || true
    rm -rf "${INSTANCES_DIR}/${inst}"
    ok "Instance '${inst}' deleted."
}

_assert_instance() {
    local inst="$1"
    [[ -d "${INSTANCES_DIR}/${inst}" ]] || { err "Instance '$inst' not found. List: $0 list"; exit 1; }
}

# ─── Conflict checker ─────────────────────────────────────────────────────────

cmd_check_conflicts() {
    hdr "Conflict Check — All Instances"
    local instances; mapfile -t instances < <(list_instances)
    [[ ${#instances[@]} -eq 0 ]] && { warn "No instances."; return; }

    declare -A seen_iface seen_rt seen_subnet seen_ssid
    local conflicts=0

    for inst in "${instances[@]}"; do
        local ef; ef="$(env_file "$inst")"

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
                err "CONFLICT: ${key}='${val}' shared by '${_seen[$val]}' and '${inst}'"
                (( conflicts++ ))
            else
                _seen[$val]="$inst"
            fi
        done
    done

    if (( conflicts == 0 )); then
        ok "No conflicts detected."
    else
        err "${conflicts} conflict(s) found. Fix .env files before starting."
    fi
    echo
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo
    echo "${C_BOLD}Usage:${C_RST} $0 <command> [args]"
    echo
    echo "${C_BOLD}Instance management:${C_RST}"
    printf "  %-28s %s\n" "list" "List all instances + status"
    printf "  %-28s %s\n" "create <name>" "Create new instance (auto-assigns subnet + RT)"
    printf "  %-28s %s\n" "delete <name>" "Stop + remove instance"
    echo
    echo "${C_BOLD}Stack control:${C_RST}"
    printf "  %-28s %s\n" "start <name>" "Build + start instance"
    printf "  %-28s %s\n" "stop <name>" "Stop instance (keeps containers)"
    printf "  %-28s %s\n" "down <name>" "Down instance (removes containers + images)"
    printf "  %-28s %s\n" "restart <name>" "Restart instance"
    printf "  %-28s %s\n" "start-all" "Start all instances"
    printf "  %-28s %s\n" "stop-all" "Stop all instances"
    echo
    echo "${C_BOLD}Monitoring:${C_RST}"
    printf "  %-28s %s\n" "status <name>" "Docker compose ps for instance"
    printf "  %-28s %s\n" "logs <name> [svc]" "Follow logs (svc: gluetun|wifi-ap)"
    printf "  %-28s %s\n" "health" "VPN connectivity + routing check all instances"
    printf "  %-28s %s\n" "check-conflicts" "Detect duplicate iface/subnet/RT across instances"
    echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

cmd="${1:-}"
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
    *)               usage; exit 1 ;;
esac
