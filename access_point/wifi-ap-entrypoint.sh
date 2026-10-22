#!/usr/bin/env bash
# =============================================================================
# wifi-ap-entrypoint.sh
# Multi-mode access point orchestrator for nordvpn_ap:
#   - AP Mode: hotspot routed through NordVPN (gluetun) or direct
#   - Repeater Mode: WiFi uplink (STA) + AP broadcast
#   - AdGuard Home DNS redirection with port 853 DoT blocking
# =============================================================================
set -eu

# ─── Configurable variables ───────────────────────────────────────────────────
AP_IFACE="${AP_IFACE:-wlan0}"
AP_IP="${AP_IP:-192.168.60.1}"
AP_SUBNET="${AP_SUBNET:-192.168.60.0/24}"
AP_SSID="${AP_SSID:-MyHotspot}"
AP_PASSWORD="${AP_PASSWORD:-ChangeMe123!}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_HW_MODE="${AP_HW_MODE:-g}"
AP_CHANNEL_WIDTH="${AP_CHANNEL_WIDTH:-20}"
AP_SECURITY="${AP_SECURITY:-wpa2}"
COUNTRY="${COUNTRY:-vpn0}"
ROUTING_TABLE="${ROUTING_TABLE:-100}"

# Mode: "ap" (single radio), "repeater" (WiFi STA + AP)
MODE="${MODE:-ap}"
UPLINK_IFACE="${UPLINK_IFACE:-}"
UPLINK_SSID="${UPLINK_SSID:-}"
UPLINK_PASSWORD="${UPLINK_PASSWORD:-}"

# VPN toggle: true = tunnel through gluetun; false = plain NAT bridge via uplink/host
VPN_ENABLED="${VPN_ENABLED:-${NORDVPN_ENABLED:-true}}"

# AdGuard Home DNS: optional IP (e.g. 192.168.50.145) for external AGH instance
ADGUARD_DNS="${ADGUARD_DNS:-}"
ADGUARD_DNS_PORT="${ADGUARD_DNS_PORT:-53}"

DHCP_LEASE="${DHCP_LEASE:-12h}"

GLUETUN_PID=""
HOSTAPD_PID=""

TAG="[wifi-ap/${COUNTRY}]"
log()  { echo "==> ${TAG} $*"; }
warn() { echo "WARN ${TAG} $*"; }
die()  { echo "ERROR ${TAG} $*"; exit 1; }

# ─── Find gluetun PID for VPN mode ───────────────────────────────────────────
find_vpn_pid() {
    for pid_path in /proc/[0-9]*/mountinfo; do
        if grep -q "country/${COUNTRY}/gluetun-state" "$pid_path" 2>/dev/null; then
            local pid
            pid="$(echo "$pid_path" | cut -d/ -f3)"
            if grep -q "tun0" "/proc/${pid}/net/dev" 2>/dev/null; then
                echo "$pid"
                return 0
            fi
        fi
    done
    return 1
}

# ─── Write hostapd config ────────────────────────────────────────────────────
write_hostapd_conf() {
    local ch="${1:-$AP_CHANNEL}"
    local hw="${2:-$AP_HW_MODE}"
    local width="${3:-$AP_CHANNEL_WIDTH}"

    # Auto-resolve hw_mode based on channel frequency to prevent frequency calculation failure
    local hostapd_hw_mode="g"
    if [[ "$ch" -gt 14 ]] 2>/dev/null; then
        # Channel > 14 is in the 5 GHz band (must be hw_mode=a)
        hostapd_hw_mode="a"
    elif [[ "${hw,,}" == "b" ]]; then
        hostapd_hw_mode="b"
    else
        # Channel 1..14 is in the 2.4 GHz band (must be hw_mode=g or b)
        hostapd_hw_mode="g"
    fi

    local conf="/tmp/hostapd-${COUNTRY}.conf"
    cat > "$conf" <<EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${AP_SSID}
channel=${ch}
hw_mode=${hostapd_hw_mode}
ieee80211n=1
wmm_enabled=1
auth_algs=1
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF

    case "${AP_SECURITY,,}" in
        none|open)
            ;;
        wpa)
            cat >> "$conf" <<EOF
wpa=1
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
wpa_passphrase=${AP_PASSWORD}
EOF
            ;;
        wpa3)
            cat >> "$conf" <<EOF
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
ieee80211w=2
sae_password=${AP_PASSWORD}
EOF
            ;;
        wpa2-wpa3|mixed)
            cat >> "$conf" <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK SAE
rsn_pairwise=CCMP
ieee80211w=1
wpa_passphrase=${AP_PASSWORD}
sae_password=${AP_PASSWORD}
EOF
            ;;
        wpa2|*)
            cat >> "$conf" <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${AP_PASSWORD}
EOF
            ;;
    esac

    if [[ "$hostapd_hw_mode" == "a" ]]; then
        if [[ "${hw,,}" == "a" || "${hw,,}" == "ac" || "${hw,,}" == "ax" ]]; then
            echo "ieee80211ac=1" >> "$conf"
            # Auto-calculate 80MHz VHT center frequency index if width >= 80
            if [[ "$width" -ge 80 ]] 2>/dev/null; then
                local centr_idx=""
                case "$ch" in
                    36|40|44|48) centr_idx="42" ;;
                    52|56|60|64) centr_idx="58" ;;
                    100|104|108|112) centr_idx="106" ;;
                    116|120|124|128) centr_idx="122" ;;
                    132|136|140|144) centr_idx="138" ;;
                    149|153|157|161) centr_idx="155" ;;
                esac
                if [[ -n "$centr_idx" ]]; then
                    echo "vht_oper_chwidth=1" >> "$conf"
                    echo "vht_oper_centr_freq_seg0_idx=${centr_idx}" >> "$conf"
                fi
            elif [[ "$width" -ge 40 ]] 2>/dev/null; then
                case "$ch" in
                    36|44|52|60|100|108|116|124|132|140|149|157)
                        echo "ht_capab=[HT40+]" >> "$conf"
                        ;;
                    40|48|56|64|104|112|120|128|136|144|153|161)
                        echo "ht_capab=[HT40-]" >> "$conf"
                        ;;
                esac
            fi
            if [[ "${hw,,}" == "ax" ]]; then
                echo "ieee80211ax=1" >> "$conf"
            fi
        fi
    else
        # 2.4 GHz band
        if [[ "$width" -ge 40 ]] 2>/dev/null; then
            if [[ "$ch" -le 7 ]] 2>/dev/null; then
                echo "ht_capab=[HT40+]" >> "$conf"
            else
                echo "ht_capab=[HT40-]" >> "$conf"
            fi
        fi
        if [[ "${hw,,}" == "ax" ]]; then
            echo "ieee80211ax=1" >> "$conf"
        fi
    fi
}

# ─── Write dnsmasq config ────────────────────────────────────────────────────
write_dnsmasq_conf() {
    local dhcp_base
    dhcp_base="$(echo "$AP_IP" | awk -F. '{print $1"."$2"."$3}')"

    local dns_opt
    if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
        # Directed to AP gateway IP; iptables DNAT redirects to external AdGuard Home
        dns_opt="dhcp-option=6,${AP_IP}"
    elif [[ "${VPN_ENABLED,,}" == "true" ]]; then
        # Standard NordVPN AP mode: NordVPN public DNS intercepted by iptables to local AdGuard
        dns_opt="dhcp-option=6,103.86.96.100,103.86.99.100"
    else
        # Direct bridge mode without AdGuard: hand out upstream/public DNS
        local uplink_dns=""
        uplink_dns=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)
        dns_opt="dhcp-option=6,${uplink_dns:-1.1.1.1},1.1.1.1,8.8.8.8"
    fi

    cat > "/tmp/dnsmasq-${COUNTRY}.conf" <<EOF
interface=${AP_IFACE}
bind-dynamic
no-daemon
port=0
dhcp-authoritative
dhcp-range=${dhcp_base}.10,${dhcp_base}.100,${DHCP_LEASE}
dhcp-option=3,${AP_IP}
${dns_opt}
dhcp-leasefile=/tmp/dnsmasq-${COUNTRY}.leases
EOF
}

# ─── Uplink Connectivity ──────────────────────────────────────────────────────
uplink_ready() {
    [[ -n "$UPLINK_IFACE" ]] && ip -o -4 addr show "$UPLINK_IFACE" 2>/dev/null | grep "inet " >/dev/null 2>&1
}

# Connect UPLINK_IFACE in repeater mode (wpa_supplicant STA) or validate in bridge mode
connect_uplink() {
    [[ -n "$UPLINK_IFACE" ]] || return 0

    if [[ "${MODE,,}" == "repeater" ]]; then
        log "Associating uplink ${UPLINK_IFACE} to SSID '${UPLINK_SSID}' (repeater mode)..."
        nsenter -t 1 -m -u -i -n -- nmcli dev set "$UPLINK_IFACE" managed no 2>/dev/null || true
        rfkill unblock wifi 2>/dev/null || true
        nsenter -t 1 -m -u -i -n -- rfkill unblock wifi 2>/dev/null || true

        ip link set "$UPLINK_IFACE" down 2>/dev/null || true
        ip addr flush dev "$UPLINK_IFACE" 2>/dev/null || true
        mkdir -p /var/run/wpa_supplicant

        if [[ -n "$UPLINK_PASSWORD" ]]; then
            wpa_passphrase "$UPLINK_SSID" "$UPLINK_PASSWORD" > "/tmp/uplink-${COUNTRY}.conf"
            pkill -f "wpa_supplicant -i $UPLINK_IFACE" 2>/dev/null || true
            wpa_supplicant -B -i "$UPLINK_IFACE" -c "/tmp/uplink-${COUNTRY}.conf" -f "/tmp/wpa-${COUNTRY}.log"
        else
            pkill -f "wpa_supplicant -i $UPLINK_IFACE" 2>/dev/null || true
            cat > "/tmp/uplink-${COUNTRY}.conf" <<EOF
network={
    ssid="${UPLINK_SSID}"
    key_mgmt=NONE
}
EOF
            wpa_supplicant -B -i "$UPLINK_IFACE" -c "/tmp/uplink-${COUNTRY}.conf" -f "/tmp/wpa-${COUNTRY}.log"
        fi

        log "Requesting DHCP lease on ${UPLINK_IFACE}..."
        local resolv_backup=""
        if [[ -f /etc/resolv.conf ]]; then
            resolv_backup="$(cat /etc/resolv.conf)"
        fi

        cat > "/tmp/dhclient-${COUNTRY}.conf" <<EOF
request subnet-mask, broadcast-address, time-offset, routers, domain-name, domain-name-servers;
EOF
        dhclient -v -cf "/tmp/dhclient-${COUNTRY}.conf" "$UPLINK_IFACE" 2>/dev/null || udhcpc -i "$UPLINK_IFACE" -b -R 2>/dev/null || true

        # Protect host DNS from being overwritten by uplink Wi-Fi lease
        if [[ -n "$resolv_backup" ]]; then
            echo "$resolv_backup" > /etc/resolv.conf 2>/dev/null || true
        fi

        # If primary host ethernet (eno1/eth0) default route exists, remove redundant default route in main table
        # (Table $ROUTING_TABLE manages the AP client traffic through $UPLINK_IFACE)
        local primary_dev
        primary_dev=$(ip route show default 2>/dev/null | grep -v "$UPLINK_IFACE" | awk 'NR==1{print $5}' || true)
        if [[ -n "$primary_dev" ]]; then
            ip route del default dev "$UPLINK_IFACE" 2>/dev/null || true
        fi

        for i in $(seq 1 30); do
            if uplink_ready; then
                local ul_ip
                ul_ip=$(ip -o -4 addr show "$UPLINK_IFACE" 2>/dev/null | awk 'NR==1{print $4}' || true)
                log "Uplink up: ${ul_ip} dev ${UPLINK_IFACE}"
                return 0
            fi
            sleep 1
        done
        warn "Uplink ${UPLINK_IFACE} has no IPv4 lease yet."
        return 1
    fi
}

# ─── Setup Plain NAT Bridge Routing (No VPN) ─────────────────────────────────
setup_routing_plain() {
    local target_uplink="${UPLINK_IFACE}"
    if [[ -z "$target_uplink" ]]; then
        target_uplink=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}' || true)
    fi

    log "Setting up plain bridge routing: ${AP_IFACE} → ${target_uplink:-default uplink}"

    sysctl -qw net.ipv4.ip_forward=1

    # Clean previous rules
    ip rule del to "$AP_SUBNET" lookup main 2>/dev/null || true
    ip rule del to "$ADGUARD_DNS" lookup main 2>/dev/null || true
    ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
    ip route flush table "$ROUTING_TABLE" 2>/dev/null || true

    local uplink_gw=""
    if [[ -n "$target_uplink" ]]; then
        # 1. Check dhclient leases file for router IP on this interface
        if [[ -f /var/lib/dhcp/dhclient.leases ]]; then
            uplink_gw=$(awk -v iface="$target_uplink" '
                $1 == "interface" && $2 ~ iface { in_iface=1 }
                in_iface && $1 == "option" && $2 == "routers" { sub(/;/, "", $3); gw=$3 }
                in_iface && $1 == "}" { in_iface=0 }
                END { if (gw) print gw }
            ' /var/lib/dhcp/dhclient.leases 2>/dev/null || true)
        fi
        # 2. Check route for target uplink
        if [[ -z "$uplink_gw" ]]; then
            uplink_gw=$(ip route show default dev "$target_uplink" 2>/dev/null | awk 'NR==1{print $3}' || true)
        fi
        # 3. Derive standard gateway from interface subnet (.1)
        if [[ -z "$uplink_gw" ]]; then
            local dev_ip
            dev_ip=$(ip -o -4 addr show "$target_uplink" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1 || true)
            if [[ -n "$dev_ip" ]]; then
                uplink_gw=$(echo "$dev_ip" | awk -F. '{print $1"."$2"."$3".1"}')
            fi
        fi
    fi
    if [[ -z "$uplink_gw" ]]; then
        uplink_gw=$(ip route show default 2>/dev/null | awk 'NR==1{print $3}' || true)
    fi

    # 1) Keep traffic destined to local AP subnet in main table
    ip rule add to "$AP_SUBNET" lookup main priority $((100 + ROUTING_TABLE - 2)) 2>/dev/null || true

    # 2) Keep traffic destined to AdGuard DNS in main table
    if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
        ip rule add to "$ADGUARD_DNS" lookup main priority $((100 + ROUTING_TABLE - 1)) 2>/dev/null || true
    fi

    # 3) Route AP client traffic via custom table
    ip rule add from "$AP_SUBNET" lookup "$ROUTING_TABLE" priority $((100 + ROUTING_TABLE)) 2>/dev/null || true

    # Populate table with connected/link routes
    while read -r route; do
        [[ "$route" =~ ^default ]] && continue
        ip route replace $route table "$ROUTING_TABLE" 2>/dev/null || true
    done < <(ip route show scope link 2>/dev/null)

    # Ensure target uplink subnet is explicitly in custom table
    if [[ -n "$target_uplink" ]]; then
        local tgt_subnet
        tgt_subnet=$(ip -o -4 addr show "$target_uplink" 2>/dev/null | awk 'NR==1{print $4}' || true)
        if [[ -n "$tgt_subnet" ]]; then
            ip route replace "$tgt_subnet" dev "$target_uplink" table "$ROUTING_TABLE" 2>/dev/null || true
        fi
    fi

    # Add default route in custom table with onlink to prevent nexthop validation failures
    if [[ -n "$uplink_gw" && -n "$target_uplink" ]]; then
        ip route replace default via "$uplink_gw" dev "$target_uplink" table "$ROUTING_TABLE" onlink 2>/dev/null \
            || ip route replace default dev "$target_uplink" table "$ROUTING_TABLE" onlink 2>/dev/null \
            || true
    elif [[ -n "$target_uplink" ]]; then
        ip route replace default dev "$target_uplink" table "$ROUTING_TABLE" onlink 2>/dev/null || true
    elif [[ -n "$uplink_gw" ]]; then
        ip route replace default via "$uplink_gw" table "$ROUTING_TABLE" onlink 2>/dev/null || true
    fi

    # FORWARD rules
    iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    if [[ -n "$target_uplink" ]]; then
        iptables -D FORWARD -i "$AP_IFACE" -o "$target_uplink" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$target_uplink" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 2 -i "$AP_IFACE" -o "$target_uplink" -j ACCEPT
        iptables -I FORWARD 3 -i "$target_uplink" -o "$AP_IFACE" -j ACCEPT

        iptables -t nat -D POSTROUTING -s "$AP_SUBNET" -o "$target_uplink" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "$AP_SUBNET" -o "$target_uplink" -j MASQUERADE
    else
        iptables -D FORWARD -i "$AP_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 2 -i "$AP_IFACE" -j ACCEPT
        iptables -t nat -D POSTROUTING -s "$AP_SUBNET" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s "$AP_SUBNET" -j MASQUERADE
    fi

    log "Plain bridge routing active (GW: ${uplink_gw:-direct}, dev: ${target_uplink:-default})"
}

# ─── Setup VPN Routing (via gluetun container) ───────────────────────────────
setup_routing_vpn() {
    local gpid="$1"
    log "Setting up VPN routing via gluetun PID ${gpid}..."

    local gip gw bridge
    gip=$(nsenter -t "$gpid" -n -- ip addr show eth0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1)
    gw=$(nsenter -t "$gpid" -n -- ip route show default 2>/dev/null | awk '{print $3}')
    bridge=$(ip -o -4 addr show | awk -v gw="$gw" '$4 ~ "^"gw"/" {print $2}')
    if [[ -z "$bridge" ]]; then
        bridge=$(ip link | sed -n 's/.*\(br-[a-f0-9]\+\).*/\1/p' | head -1)
    fi

    log "  Gluetun IP: ${gip} | Bridge GW: ${gw} | Bridge dev: ${bridge} | RT: ${ROUTING_TABLE}"

    sysctl -qw net.ipv4.ip_forward=1

    ip rule del to "$AP_SUBNET" lookup main 2>/dev/null || true
    ip rule del to "$ADGUARD_DNS" lookup main 2>/dev/null || true
    ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
    ip route flush table "$ROUTING_TABLE" 2>/dev/null || true

    ip rule add to "$AP_SUBNET" lookup main priority $((100 + ROUTING_TABLE - 2))
    if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
        ip rule add to "$ADGUARD_DNS" lookup main priority $((100 + ROUTING_TABLE - 1))
    fi
    ip rule add from "$AP_SUBNET" lookup "$ROUTING_TABLE" priority $((100 + ROUTING_TABLE))

    while read -r route; do
        [[ "$route" =~ ^default ]] && continue
        ip route replace $route table "$ROUTING_TABLE" 2>/dev/null || true
    done < <(ip route show scope link)

    ip route replace default via "$gip" dev "$bridge" table "$ROUTING_TABLE"

    iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -D FORWARD -i "$AP_IFACE" -o "$bridge" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$bridge" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 2 -i "$AP_IFACE" -o "$bridge" -j ACCEPT
    iptables -I FORWARD 3 -i "$bridge" -o "$AP_IFACE" -j ACCEPT

    # VPN-side: route and masquerade inside gluetun netns
    nsenter -t "$gpid" -n -- bash -s <<EOF
sysctl -qw net.ipv4.ip_forward=1
ip route del ${AP_SUBNET} 2>/dev/null || true
ip route add ${AP_SUBNET} via ${gw}
ip rule add to ${AP_SUBNET} lookup main priority 90 2>/dev/null || true
iptables -D FORWARD -s ${AP_SUBNET} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d ${AP_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s ${AP_SUBNET} -j ACCEPT
iptables -I FORWARD 2 -d ${AP_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -D POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE
EOF

    log "VPN overlay routing active"
}

# ─── Heal local AdGuard Home shim connectivity ───────────────────────────────
heal_adguard_upstream() {
    local shim_iface=""
    if ip link show adguard-shim &>/dev/null; then
        shim_iface="adguard-shim"
    fi

    local target_uplink="${UPLINK_IFACE}"
    if [[ -z "$target_uplink" ]]; then
        target_uplink=$(ip route show default | awk '{print $5}' | head -1)
    fi

    if [[ -n "$shim_iface" && -n "$target_uplink" ]]; then
        iptables -D FORWARD -i "$shim_iface" -o "$target_uplink" -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i "$shim_iface" -o "$target_uplink" -j ACCEPT
        if [[ -n "${ADGUARD_DNS:-}" ]]; then
            iptables -t nat -D POSTROUTING -s "$ADGUARD_DNS" -o "$target_uplink" -j MASQUERADE 2>/dev/null || true
            iptables -t nat -A POSTROUTING -s "$ADGUARD_DNS" -o "$target_uplink" -j MASQUERADE
        fi

        local shim_ip
        shim_ip=$(ip -o -4 addr show dev "$shim_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)

        local agh_running
        agh_running=$(nsenter -t 1 -m -u -i -n -- docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^adguardhome$' || true)
        if [[ -n "$agh_running" && -n "$shim_ip" ]]; then
            if ! nsenter -t 1 -m -u -i -n -- docker exec adguardhome ping -c 1 -w 2 1.1.1.1 &>/dev/null; then
                log "AdGuard Home cannot reach internet — adjusting route via ${shim_iface} (${shim_ip})..."
                nsenter -t 1 -m -u -i -n -- docker exec adguardhome ip route replace default via "$shim_ip" dev eth0 2>/dev/null || true
            fi
        fi
    fi
}

# ─── Setup DNS redirection ───────────────────────────────────────────────────
setup_dns_redirect() {
    local gpid="${1:-}"

    # Clean old port 53 DNAT rules on AP_IFACE
    while true; do
        local rnum
        rnum=$(iptables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null \
            | awk -v dev="$AP_IFACE" '$0 ~ dev && $0 ~ /dpt:53/ && $0 ~ /to:/ && !found {found=$1} END {if (found) print found}' || true)
        [[ -z "$rnum" ]] && break
        iptables -t nat -D PREROUTING "$rnum" 2>/dev/null || break
    done

    # Clean old Web UI DNAT rules
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" -j DNAT 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" -j DNAT 2>/dev/null || true

    if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
        log "Redirecting DNS → external AdGuard Home at ${ADGUARD_DNS}:${ADGUARD_DNS_PORT}..."

        iptables -t nat -I PREROUTING 1 -i "$AP_IFACE" -p udp --dport 53 \
            -j DNAT --to-destination "${ADGUARD_DNS}:${ADGUARD_DNS_PORT}"
        iptables -t nat -I PREROUTING 2 -i "$AP_IFACE" -p tcp --dport 53 \
            -j DNAT --to-destination "${ADGUARD_DNS}:${ADGUARD_DNS_PORT}"

        iptables -t nat -D POSTROUTING -d "$ADGUARD_DNS" -p udp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -d "$ADGUARD_DNS" -p tcp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -d "$ADGUARD_DNS" -p udp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE
        iptables -t nat -A POSTROUTING -d "$ADGUARD_DNS" -p tcp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE

        iptables -D FORWARD -i "$AP_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$AP_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i "$AP_IFACE" -p udp --dport 53 -j ACCEPT
        iptables -I FORWARD 2 -i "$AP_IFACE" -p tcp --dport 53 -j ACCEPT

        # Block DNS-over-TLS (port 853) with RST so devices cannot bypass AdGuard
        iptables -D FORWARD -i "$AP_IFACE" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -I FORWARD 1 -i "$AP_IFACE" -p tcp --dport 853 -j REJECT --reject-with tcp-reset

        heal_adguard_upstream
    elif [[ "${VPN_ENABLED,,}" == "true" && -n "$gpid" ]]; then
        local gip
        gip=$(nsenter -t "$gpid" -n -- ip addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

        log "Redirecting DNS → built-in AdGuard Home at ${gip}:53..."
        iptables -t nat -I PREROUTING 1 -i "$AP_IFACE" -p udp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53"
        iptables -t nat -I PREROUTING 2 -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53"
        iptables -t nat -I PREROUTING 3 -i "$AP_IFACE" -p udp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53"
        iptables -t nat -I PREROUTING 4 -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53"

        # Web UI forwarding to AdGuard Home
        iptables -t nat -I PREROUTING 5 -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" -j DNAT --to-destination "$gip:3000"
        iptables -t nat -I PREROUTING 6 -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" -j DNAT --to-destination "$gip:80"

        # Block DNS-over-TLS (port 853)
        iptables -D FORWARD -i "$AP_IFACE" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -I FORWARD 1 -i "$AP_IFACE" -p tcp --dport 853 -j REJECT --reject-with tcp-reset
    else
        log "Direct DNS mode (no AdGuard interception)"
    fi
}

# ─── Cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down access point..."
    pkill -f "hostapd /tmp/hostapd-${COUNTRY}.conf" 2>/dev/null || true
    pkill -f "dnsmasq --conf-file=/tmp/dnsmasq-${COUNTRY}.conf" 2>/dev/null || true
    pkill -f "wpa_supplicant -i $UPLINK_IFACE" 2>/dev/null || true

    ip rule del to "$AP_SUBNET" lookup main 2>/dev/null || true
    ip rule del to "$ADGUARD_DNS" lookup main 2>/dev/null || true
    ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
    ip route flush table "$ROUTING_TABLE" 2>/dev/null || true

    # Clean DNAT rules on AP_IFACE
    while true; do
        local rnum
        rnum=$(iptables -t nat -L PREROUTING -v -n --line-numbers 2>/dev/null \
            | awk -v dev="$AP_IFACE" '$0 ~ dev && $0 ~ /dpt:53/ && $0 ~ /to:/ && !found {found=$1} END {if (found) print found}' || true)
        [[ -z "$rnum" ]] && break
        iptables -t nat -D PREROUTING "$rnum" 2>/dev/null || break
    done

    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" 2>/dev/null || true

    if [[ -n "${ADGUARD_DNS:-}" ]]; then
        iptables -t nat -D POSTROUTING -d "$ADGUARD_DNS" -p udp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -d "$ADGUARD_DNS" -p tcp --dport "$ADGUARD_DNS_PORT" -j MASQUERADE 2>/dev/null || true
    fi

    if [[ -n "${UPLINK_IFACE:-}" ]]; then
        iptables -t nat -D POSTROUTING -s "$AP_SUBNET" -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "$AP_IFACE" -o "$UPLINK_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$UPLINK_IFACE" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
    fi

    iptables -D FORWARD -i "$AP_IFACE" -p tcp --dport 853 -j REJECT --reject-with tcp-reset 2>/dev/null || true

    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- nmcli dev set "$AP_IFACE" managed yes 2>/dev/null || true

    # VPN overlay cleanup
    if [[ "${VPN_ENABLED,,}" == "true" ]]; then
        local gpid
        gpid=$(find_vpn_pid 2>/dev/null || true)
        if [[ -n "$gpid" ]]; then
            nsenter -t "$gpid" -n -- bash -c "
                iptables -t nat -D POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE 2>/dev/null || true
                iptables -D FORWARD -s ${AP_SUBNET} -j ACCEPT 2>/dev/null || true
                ip route del ${AP_SUBNET} 2>/dev/null || true
                ip rule del to ${AP_SUBNET} lookup main priority 90 2>/dev/null || true
            " 2>/dev/null || true
        fi
    fi

    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

log "Starting Access Point Stack [${COUNTRY}]"
log "  Mode        : ${MODE}"
log "  AP iface    : ${AP_IFACE}"
log "  SSID        : ${AP_SSID}"
log "  Subnet      : ${AP_SUBNET}"
log "  VPN Enabled : ${VPN_ENABLED}"
log "  Uplink iface: ${UPLINK_IFACE:-none}"
if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
    log "  DNS         : External AdGuard Home @ ${ADGUARD_DNS}:${ADGUARD_DNS_PORT}"
elif [[ "${VPN_ENABLED,,}" == "true" ]]; then
    log "  DNS         : Built-in AdGuard Home (gluetun)"
else
    log "  DNS         : Upstream / Public DNS"
fi

# 1. Connect or validate uplink if in repeater or bridge mode
connect_uplink

# 2. If VPN mode, wait for gluetun tun0
GLUETUN_PID=""
if [[ "${VPN_ENABLED,,}" == "true" ]]; then
    log "Waiting for VPN tunnel (tun0)..."
    for i in $(seq 1 30); do
        GLUETUN_PID=$(find_vpn_pid 2>/dev/null || true)
        [[ -n "$GLUETUN_PID" ]] && log "  Found gluetun at PID ${GLUETUN_PID}" && break
        echo "  [$i/30] Not ready yet, waiting 2s..."
        sleep 2
    done
    [[ -z "$GLUETUN_PID" ]] && die "gluetun tun0 not found after 60s."
fi

# ─── AP Interface Hardware Preparation & Safe Hostapd Starter ───────────────
configure_ap_interface() {
    log "Configuring AP interface ${AP_IFACE}..."
    nsenter -t 1 -m -u -i -n -- nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true

    # Terminate any competing/stale hostapd or wpa_supplicant bound to this adapter
    pkill -f "hostapd.*${AP_IFACE}" 2>/dev/null || true
    pkill -f "wpa_supplicant.*${AP_IFACE}" 2>/dev/null || true

    rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- rfkill unblock wifi 2>/dev/null || nsenter -t 1 -m -u -i -n -- rfkill unblock all 2>/dev/null || true

    ip link set "$AP_IFACE" down 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true

    # Remove duplicate assignment of AP_IP/subnet from any other interface to avoid routing conflicts
    for stale_dev in $(ip -o -4 addr show 2>/dev/null | awk -v ip="$AP_IP" '$4 ~ "^"ip"/" {print $2}'); do
        if [[ "$stale_dev" != "$AP_IFACE" ]]; then
            warn "Flushing duplicate IP ${AP_IP} from stale interface ${stale_dev}..."
            ip addr flush dev "$stale_dev" 2>/dev/null || true
        fi
    done

    # Reset wireless mode to AP
    iw dev "$AP_IFACE" set type managed 2>/dev/null || true
    iw dev "$AP_IFACE" set type __ap 2>/dev/null || true
    ip addr add "${AP_IP}/24" dev "$AP_IFACE" 2>/dev/null || true

    for attempt in $(seq 1 5); do
        if ip link set "$AP_IFACE" up 2>/dev/null; then
            break
        fi
        warn "Failed to set ${AP_IFACE} up (attempt ${attempt}/5), retrying..."
        rfkill unblock wifi 2>/dev/null || rfkill unblock all 2>/dev/null || true
        nsenter -t 1 -m -u -i -n -- rfkill unblock wifi 2>/dev/null || true
        sleep 1
    done
    ip link set "$AP_IFACE" up 2>/dev/null || true
}

start_hostapd_safe() {
    # 1. Terminate any previous hostapd instance
    if [[ -n "${HOSTAPD_PID:-}" ]] && kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        kill "$HOSTAPD_PID" 2>/dev/null || true
        wait "$HOSTAPD_PID" 2>/dev/null || true
    fi
    pkill -f "hostapd.*${AP_IFACE}" 2>/dev/null || true
    pkill -f "hostapd.*${COUNTRY}" 2>/dev/null || true

    # 2. Pre-flight check on physical hardware capabilities
    local phy_name=""
    phy_name=$(iw dev "$AP_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    local supports_5g=0
    local supports_2g=0
    if [[ -n "$phy_name" ]]; then
        if iw phy "$phy_name" info 2>/dev/null | grep -E "5[0-9]{3}\.0 MHz" >/dev/null 2>&1; then
            supports_5g=1
        fi
        if iw phy "$phy_name" info 2>/dev/null | grep -E "24[0-9]{2}\.0 MHz" >/dev/null 2>&1; then
            supports_2g=1
        fi
    else
        supports_5g=1
        supports_2g=1
    fi

    # Auto-adjust if requested channel contradicts hardware capabilities
    if [[ "$AP_CHANNEL" -gt 14 && "$supports_5g" -eq 0 ]]; then
        warn "AP interface ${AP_IFACE} does not support 5 GHz! Auto-switching to Channel 6 (2.4 GHz, 20MHz)..."
        AP_CHANNEL=6
        AP_HW_MODE="g"
        AP_CHANNEL_WIDTH=20
    elif [[ "$AP_CHANNEL" -le 14 && "$supports_2g" -eq 0 && "$supports_5g" -eq 1 ]]; then
        warn "AP interface ${AP_IFACE} does not support 2.4 GHz! Auto-switching to Channel 36 (5 GHz)..."
        AP_CHANNEL=36
        AP_HW_MODE="a"
        AP_CHANNEL_WIDTH=20
    fi

    # 3. Configure interface link & unblock rfkill
    configure_ap_interface

    # 4. Write hostapd configuration and launch
    write_hostapd_conf "$AP_CHANNEL" "$AP_HW_MODE" "$AP_CHANNEL_WIDTH"
    log "Starting hostapd on ${AP_IFACE} (ch ${AP_CHANNEL}, hw_mode ${AP_HW_MODE:-auto}, width ${AP_CHANNEL_WIDTH}MHz)..."
    hostapd "/tmp/hostapd-${COUNTRY}.conf" &
    HOSTAPD_PID=$!
    sleep 2

    if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        log "hostapd started successfully (PID: ${HOSTAPD_PID})"
        return 0
    fi

    # ── Fallback 1: Driver/frequency issue recovery ──────────────────────────
    warn "hostapd failed to start on ${AP_IFACE} (ch ${AP_CHANNEL}). Initiating automated unblock & recovery..."
    
    rfkill unblock all 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- rfkill unblock all 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true
    pkill -f "hostapd.*${AP_IFACE}" 2>/dev/null || true
    pkill -f "wpa_supplicant.*${AP_IFACE}" 2>/dev/null || true

    ip link set "$AP_IFACE" down 2>/dev/null || true
    iw dev "$AP_IFACE" set type managed 2>/dev/null || true
    sleep 1
    iw dev "$AP_IFACE" set type __ap 2>/dev/null || true
    ip link set "$AP_IFACE" up 2>/dev/null || true

    if [[ "$AP_CHANNEL" -gt 14 ]]; then
        warn "Auto-recovery: switching from 5GHz (ch ${AP_CHANNEL}) to standard 2.4GHz Channel 6 (20MHz)..."
        AP_CHANNEL=6
        AP_HW_MODE="g"
        AP_CHANNEL_WIDTH=20
    else
        warn "Auto-recovery: retrying on alternate 2.4GHz Channel 1 (20MHz)..."
        AP_CHANNEL=1
        AP_HW_MODE="g"
        AP_CHANNEL_WIDTH=20
    fi

    write_hostapd_conf "$AP_CHANNEL" "$AP_HW_MODE" "$AP_CHANNEL_WIDTH"
    log "Retrying hostapd with auto-resolved settings (ch ${AP_CHANNEL}, hw_mode ${AP_HW_MODE})..."
    hostapd "/tmp/hostapd-${COUNTRY}.conf" &
    HOSTAPD_PID=$!
    sleep 2

    if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        log "hostapd recovered and started successfully (PID: ${HOSTAPD_PID})"
        return 0
    fi

    # ── Fallback 2: Universal baseline ───────────────────────────────────────
    warn "Fallback attempt failed. Applying universal baseline recovery (Channel 1, 20MHz)..."
    AP_CHANNEL=1
    AP_HW_MODE="g"
    AP_CHANNEL_WIDTH=20

    ip link set "$AP_IFACE" down 2>/dev/null || true
    rfkill unblock all 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- rfkill unblock all 2>/dev/null || true
    iw dev "$AP_IFACE" set type __ap 2>/dev/null || true
    ip link set "$AP_IFACE" up 2>/dev/null || true

    write_hostapd_conf 1 "g" 20
    hostapd "/tmp/hostapd-${COUNTRY}.conf" &
    HOSTAPD_PID=$!
    sleep 2

    if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        log "hostapd recovered on universal baseline (PID: ${HOSTAPD_PID})"
        return 0
    fi

    warn "Automated recovery could not start hostapd on ${AP_IFACE}. Monitor loop will continue healing."
    return 1
}

# 3. Build configurations
write_hostapd_conf
write_dnsmasq_conf

# 4. Configure AP interface
configure_ap_interface

# 5. IP keep-alive watchdog
(
    while true; do
        if ! ip -o -4 addr show "$AP_IFACE" 2>/dev/null | grep "$AP_IP" >/dev/null 2>&1; then
            warn "Restoring IP ${AP_IP} to ${AP_IFACE}"
            ip addr add "${AP_IP}/24" dev "$AP_IFACE" 2>/dev/null || true
        fi
        sleep 5
    done
) &

# 6. Start hostapd with automated self-healing & unblock mechanism
start_hostapd_safe || true

# 7. Start dnsmasq
log "Starting dnsmasq..."
dnsmasq --conf-file="/tmp/dnsmasq-${COUNTRY}.conf" --no-daemon &
sleep 1

# 8. Setup DNS redirection
setup_dns_redirect "${GLUETUN_PID:-}"

# 9. Setup Routing
if [[ "${VPN_ENABLED,,}" == "true" && -n "${GLUETUN_PID:-}" ]]; then
    setup_routing_vpn "$GLUETUN_PID"
else
    setup_routing_plain
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Access Point Stack LIVE  [${COUNTRY}]"
echo "║  Mode    : ${MODE}"
echo "║  SSID    : ${AP_SSID}"
echo "║  Password: ${AP_PASSWORD}"
echo "║  Gateway : ${AP_IP}"
echo "║  RT      : ${ROUTING_TABLE}"
echo "║  VPN     : ${VPN_ENABLED}"
if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
echo "║  DNS     : AdGuard Home @ ${ADGUARD_DNS}:${ADGUARD_DNS_PORT}"
elif [[ "${VPN_ENABLED,,}" == "true" ]]; then
echo "║  DNS     : Built-in AdGuard Home (gluetun)"
else
echo "║  DNS     : Upstream / Public DNS"
fi
echo "╚═══════════════════════════════════════════════════════════╝"

# 10. Monitor loop
while true; do
    sleep 15

    # 1. Restart hostapd if it died with automated self-healing & unblocking
    if [[ -z "${HOSTAPD_PID:-}" ]] || ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        warn "hostapd died, performing automated recovery..."
        start_hostapd_safe || true
    fi

    # 2. Verify and heal default routing in table
    if ! ip route show table "$ROUTING_TABLE" 2>/dev/null | grep "default" >/dev/null 2>&1; then
        warn "Table ${ROUTING_TABLE} missing default route — re-applying routing..."
        if [[ "${VPN_ENABLED,,}" == "true" && -n "${GLUETUN_PID:-}" ]]; then
            setup_routing_vpn "$GLUETUN_PID" || true
        else
            setup_routing_plain || true
        fi
    fi

    # 3. Heal AdGuard routes if configured
    if [[ -n "${ADGUARD_DNS:-}" && "${ADGUARD_DNS,,}" != "none" && "${ADGUARD_DNS,,}" != "false" ]]; then
        heal_adguard_upstream || true
    fi

    # 4. If VPN enabled, check if gluetun reconnected
    if [[ "${VPN_ENABLED,,}" == "true" ]]; then
        CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
        if [[ -z "$CURRENT_PID" ]]; then
            warn "gluetun tun0 gone (VPN reconnecting)..."
            for _ in $(seq 1 15); do
                CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
                [[ -n "$CURRENT_PID" ]] && break
                sleep 2
            done
            if [[ -n "$CURRENT_PID" ]]; then
                log "VPN back up, reapplying routing..."
                GLUETUN_PID="$CURRENT_PID"
                setup_routing_vpn "$GLUETUN_PID"
                setup_dns_redirect "$GLUETUN_PID"
            fi
        fi
    fi
done
