#!/usr/bin/env bash
set -euo pipefail

AP_IFACE="${AP_IFACE:-wlan0}"
AP_IP="${AP_IP:-192.168.60.1}"
AP_SUBNET="${AP_SUBNET:-192.168.60.0/24}"
AP_SSID="${AP_SSID:-MyHotspot}"
AP_PASSWORD="${AP_PASSWORD:-ChangeMe123!}"
AP_CHANNEL="${AP_CHANNEL:-6}"
ROUTING_TABLE=100

find_vpn_pid() {
    for pid in /proc/[0-9]*/net/dev; do
        grep -q "tun0" "$pid" 2>/dev/null && echo "${pid%%/net/*}" | tr -d '/proc/' && return 0
    done
    return 1
}

write_hostapd_conf() {
    cat > /tmp/hostapd.conf <<EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${AP_SSID}
channel=${AP_CHANNEL}
hw_mode=g
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${AP_PASSWORD}
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF
}

write_dnsmasq_conf() {
    local dhcp_base
    dhcp_base="$(echo "$AP_IP" | awk -F. '{print $1"."$2"."$3}')"
    cat > /tmp/dnsmasq.conf <<EOF
interface=${AP_IFACE}
bind-interfaces
no-daemon
dhcp-range=${dhcp_base}.10,${dhcp_base}.100,12h
dhcp-option=3,${AP_IP}
dhcp-option=6,103.86.96.100,103.86.99.100
no-resolv
server=103.86.96.100
server=103.86.99.100
dhcp-leasefile=/tmp/dnsmasq-ap.leases
EOF
}

setup_routing() {
    local gpid=$1
    local gip gw bridge

    gip=$(nsenter -t "$gpid" -n -- ip addr show eth0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1)
    gw=$(nsenter -t "$gpid" -n -- ip route show default 2>/dev/null | awk '{print $3}')
    bridge=$(ip -o -4 addr show | awk -v gw="$gw" '$4 ~ "^"gw"/" {print $2}')
    if [ -z "$bridge" ]; then
        bridge=$(ip link | sed -n 's/.*\(br-[a-f0-9]\+\).*/\1/p' | head -1)
    fi

    echo "  Gluetun IP : $gip  |  Bridge GW : $gw  |  Bridge dev : $bridge"

    sysctl -qw net.ipv4.ip_forward=1
    ip rule del from "$AP_SUBNET" lookup $ROUTING_TABLE 2>/dev/null || true
    ip route flush table $ROUTING_TABLE 2>/dev/null || true
    ip rule add from "$AP_SUBNET" lookup $ROUTING_TABLE priority 100
    ip route add default via "$gip" dev "$bridge" table $ROUTING_TABLE

    iptables -D FORWARD -i "$AP_IFACE" -o "$bridge" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$bridge" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -i "$AP_IFACE" -o "$bridge" -j ACCEPT
    iptables -I FORWARD 2 -i "$bridge" -o "$AP_IFACE" -j ACCEPT

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
}

cleanup() {
    echo "==> [wifi-ap] Shutting down..."
    pkill -f "hostapd /tmp/hostapd.conf" 2>/dev/null || true
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

echo "==> [wifi-ap] Waiting for VPN tunnel (tun0)..."
GLUETUN_PID=""
for i in $(seq 1 30); do
    GLUETUN_PID=$(find_vpn_pid 2>/dev/null || true)
    [[ -n "$GLUETUN_PID" ]] && echo "  Found at PID $GLUETUN_PID" && break
    echo "  [$i/30] Not ready yet, waiting 2s..."
    sleep 2
done
[[ -z "$GLUETUN_PID" ]] && { echo "ERROR: VPN tun0 not found after 60s. Is gluetun connected?"; exit 1; }

write_hostapd_conf
write_dnsmasq_conf

echo "==> [wifi-ap] Configuring $AP_IFACE..."
ip link set "$AP_IFACE" down 2>/dev/null || true
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "$AP_IP/24" dev "$AP_IFACE"
ip link set "$AP_IFACE" up

echo "==> [wifi-ap] Starting hostapd..."
hostapd /tmp/hostapd.conf &
HOSTAPD_PID=$!
sleep 2

echo "==> [wifi-ap] Starting dnsmasq..."
dnsmasq --conf-file=/tmp/dnsmasq.conf --no-daemon &
sleep 1

echo "==> [wifi-ap] Setting up VPN routing..."
setup_routing "$GLUETUN_PID"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   NordVPN WiFi AP is LIVE (Docker)       ║"
echo "║   SSID    : ${AP_SSID}"
echo "║   Password: ${AP_PASSWORD}"
echo "║   Gateway : ${AP_IP}"
echo "╚═══════════════════════════════════════════╝"

while true; do
    sleep 15

    if ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        echo "WARN: hostapd died, restarting..."
        hostapd /tmp/hostapd.conf &
        HOSTAPD_PID=$!
        sleep 2
    fi

    CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
    if [[ -z "$CURRENT_PID" ]]; then
        echo "WARN: tun0 gone (VPN reconnecting)..."
        for _ in $(seq 1 15); do
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
