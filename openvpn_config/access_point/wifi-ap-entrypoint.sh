#!/usr/bin/env bash
# ============================================================
# wifi-ap-entrypoint.sh
# Runs inside wifi-ap container (host network + host PID).
# Waits for gluetun VPN tun0, sets up AP, routes all
# client traffic through gluetun's network namespace → VPN.
# ============================================================
set -euo pipefail

AP_IFACE="wlxac15a2e2f47e"
AP_IP="192.168.60.1"
AP_SUBNET="192.168.60.0/24"
ROUTING_TABLE=100

# ── Helpers ───────────────────────────────────────────────

# Find a PID whose network namespace contains tun0
find_vpn_pid() {
    for pid in /proc/[0-9]*/net/dev; do
        grep -q "tun0" "$pid" 2>/dev/null && echo "${pid%%/net/*}" | tr -d '/proc/' && return 0
    done
    return 1
}

# Reapply all routing rules (called on start and VPN reconnect)
setup_routing() {
    local gpid=$1

    # Gluetun's own IP and its gateway (host bridge IP)
    local gip gw bridge
    gip=$(nsenter -t "$gpid" -n -- ip addr show eth0 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    gw=$(nsenter -t "$gpid" -n -- ip route show default 2>/dev/null \
        | awk '{print $3}')
    # Find the docker bridge interface that owns the gateway IP
    bridge=$(ip -o -4 addr show | awk -v gw="$gw" '$4 ~ "^"gw"/" {print $2}')
    if [ -z "$bridge" ]; then
        bridge=$(ip link | grep -o 'br-[a-f0-9]*' | head -1)
    fi

    echo "  Gluetun IP : $gip  |  Bridge GW : $gw  |  Bridge dev : $bridge"

    # ── Host: policy routing ──────────────────────────────
    sysctl -qw net.ipv4.ip_forward=1
    ip rule del from "$AP_SUBNET" lookup $ROUTING_TABLE 2>/dev/null || true
    ip route flush table $ROUTING_TABLE 2>/dev/null || true
    ip rule add from "$AP_SUBNET" lookup $ROUTING_TABLE priority 100
    ip route add default via "$gip" dev "$bridge" table $ROUTING_TABLE

    # ── Host: allow FORWARD host ↔ gluetun bridge ────────
    iptables -D FORWARD -i "$AP_IFACE" -o "$bridge" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$bridge" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -i "$AP_IFACE" -o "$bridge" -j ACCEPT
    iptables -I FORWARD 2 -i "$bridge" -o "$AP_IFACE" -j ACCEPT

    # ── Inside gluetun netns: FORWARD + MASQUERADE via tun0
    nsenter -t "$gpid" -n -- bash -s <<EOF
sysctl -qw net.ipv4.ip_forward=1

# Route back: gluetun → AP subnet via docker bridge
ip route del ${AP_SUBNET} 2>/dev/null || true
ip route add ${AP_SUBNET} via ${gw}

# Force VPN to route return traffic using main table instead of intercepting
ip rule add to ${AP_SUBNET} lookup main priority 90 2>/dev/null || true

# Accept forwarded AP traffic
iptables -D FORWARD -s ${AP_SUBNET} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d ${AP_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -s ${AP_SUBNET} -j ACCEPT
iptables -I FORWARD 2 -d ${AP_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Masquerade AP traffic through VPN tunnel
iptables -t nat -D POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE
echo "  ✓ gluetun netns rules applied"
EOF
}

cleanup() {
    echo "==> [wifi-ap] Shutting down..."
    pkill -f "hostapd /etc/hostapd/hostapd.conf" 2>/dev/null || true
    pkill dnsmasq 2>/dev/null || true
    ip rule del from "$AP_SUBNET" lookup $ROUTING_TABLE 2>/dev/null || true
    ip route flush table $ROUTING_TABLE 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    GPID=$(find_vpn_pid 2>/dev/null || true)
    if [[ -n "$GPID" ]]; then
        nsenter -t "$GPID" -n -- bash -c "
            iptables -t nat -D POSTROUTING -s ${AP_SUBNET} -o tun0 -j MASQUERADE 2>/dev/null || true
            iptables -D FORWARD -s ${AP_SUBNET} -j ACCEPT 2>/dev/null || true
            ip route del ${AP_SUBNET} 2>/dev/null || true
            ip rule del to ${AP_SUBNET} lookup main priority 90 2>/dev/null || true
        " 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ── MAIN ──────────────────────────────────────────────────
echo "==> [wifi-ap] Waiting for VPN tunnel (tun0)..."
GLUETUN_PID=""
for i in $(seq 1 30); do
    GLUETUN_PID=$(find_vpn_pid 2>/dev/null || true)
    [[ -n "$GLUETUN_PID" ]] && echo "  Found at PID $GLUETUN_PID" && break
    echo "  [$i/30] Not ready yet, waiting 2s..."
    sleep 2
done
[[ -z "$GLUETUN_PID" ]] && { echo "ERROR: VPN tun0 not found after 60s. Is gluetun connected?"; exit 1; }

# Configure AP interface
echo "==> [wifi-ap] Configuring $AP_IFACE..."
ip link set "$AP_IFACE" down 2>/dev/null || true
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "$AP_IP/24" dev "$AP_IFACE"
ip link set "$AP_IFACE" up

# Start hostapd
echo "==> [wifi-ap] Starting hostapd..."
hostapd /etc/hostapd/hostapd.conf &
HOSTAPD_PID=$!
sleep 2

# Start dnsmasq
echo "==> [wifi-ap] Starting dnsmasq..."
dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon &
DNSMASQ_PID=$!
sleep 1

# Setup routing through gluetun VPN
echo "==> [wifi-ap] Setting up VPN routing..."
setup_routing "$GLUETUN_PID"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   ✅  NordVPN WiFi AP is LIVE (Docker)    ║"
echo "║   SSID    : MyHotspot                     ║"
echo "║   Password: ChangeMe123!                  ║"
echo "║   Gateway : $AP_IP                   ║"
echo "╚═══════════════════════════════════════════╝"

# Monitor: reapply rules on VPN reconnect
while true; do
    sleep 15

    # Restart hostapd if dead
    if ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        echo "WARN: hostapd died, restarting..."
        hostapd /etc/hostapd/hostapd.conf &
        HOSTAPD_PID=$!
        sleep 2
    fi

    # Reapply routing if tun0 disappeared (VPN reconnect)
    CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
    if [[ -z "$CURRENT_PID" ]]; then
        echo "WARN: tun0 gone (VPN reconnecting)..."
        for i in $(seq 1 15); do
            CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
            [[ -n "$CURRENT_PID" ]] && break
            sleep 2
        done
        if [[ -n "$CURRENT_PID" ]]; then
            echo "==> VPN back up, reapplying routing..."
            GLUETUN_PID=$CURRENT_PID
            setup_routing "$GLUETUN_PID"
        fi
    fi
done
