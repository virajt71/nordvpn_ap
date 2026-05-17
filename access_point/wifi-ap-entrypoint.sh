#!/usr/bin/env bash
set -euo pipefail

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
# ROUTING_TABLE must not collide across instances; pass explicitly from .env
ROUTING_TABLE="${ROUTING_TABLE:-100}"

TAG="[wifi-ap/${COUNTRY}]"

find_vpn_pid() {
    for pid in /proc/[0-9]*/net/dev; do
        grep -q "tun0" "$pid" 2>/dev/null && echo "${pid%%/net/*}" | tr -d '/proc/' && return 0
    done
    return 1
}

write_hostapd_conf() {
    cat > /tmp/hostapd-${COUNTRY}.conf <<EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${AP_SSID}
channel=${AP_CHANNEL}
hw_mode=${AP_HW_MODE}
ieee80211n=1
wmm_enabled=1
auth_algs=1
EOF

    case "${AP_SECURITY,,}" in
        wpa3)
            cat >> /tmp/hostapd-${COUNTRY}.conf <<EOF
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
ieee80211w=2
sae_password=${AP_PASSWORD}
EOF
            ;;
        wpa2-wpa3|mixed)
            cat >> /tmp/hostapd-${COUNTRY}.conf <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK SAE
rsn_pairwise=CCMP
ieee80211w=1
wpa_passphrase=${AP_PASSWORD}
sae_password=${AP_PASSWORD}
EOF
            ;;
        *)
            cat >> /tmp/hostapd-${COUNTRY}.conf <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${AP_PASSWORD}
EOF
            ;;
    esac

    cat >> /tmp/hostapd-${COUNTRY}.conf <<EOF
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF

    if [[ "$AP_HW_MODE" == "a" || "$AP_HW_MODE" == "ac" || "$AP_HW_MODE" == "ax" ]]; then
        {
            echo "ieee80211ac=1"
            [[ "$AP_HW_MODE" == "ax" ]] && echo "ieee80211ax=1"
        } >> /tmp/hostapd-${COUNTRY}.conf
    fi
}

write_dnsmasq_conf() {
    local dhcp_base
    dhcp_base="$(echo "$AP_IP" | awk -F. '{print $1"."$2"."$3}')"
    cat > /tmp/dnsmasq-${COUNTRY}.conf <<EOF
interface=${AP_IFACE}
bind-interfaces
no-daemon
dhcp-range=${dhcp_base}.10,${dhcp_base}.100,12h
dhcp-option=3,${AP_IP}
dhcp-option=6,103.86.96.100,103.86.99.100
port=0
dhcp-leasefile=/tmp/dnsmasq-${COUNTRY}.leases
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

    echo "  ${TAG} Gluetun IP : $gip  |  Bridge GW : $gw  |  Bridge dev : $bridge  |  RT : $ROUTING_TABLE"

    sysctl -qw net.ipv4.ip_forward=1

    # Clean old rules for this routing table before re-adding
    ip rule del from "$AP_SUBNET" lookup $ROUTING_TABLE 2>/dev/null || true
    ip route flush table $ROUTING_TABLE 2>/dev/null || true
    ip rule add from "$AP_SUBNET" lookup $ROUTING_TABLE priority $(( 100 + ROUTING_TABLE ))
    ip route add default via "$gip" dev "$bridge" table $ROUTING_TABLE

    iptables -D FORWARD -i "$AP_IFACE" -o "$bridge" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$bridge" -o "$AP_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -i "$AP_IFACE" -o "$bridge" -j ACCEPT
    iptables -I FORWARD 2 -i "$bridge" -o "$AP_IFACE" -j ACCEPT

    # Intercept DNS traffic destined for NordVPN DNS servers and redirect to local AdGuard Home instance in gluetun namespace
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p udp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p udp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true

    iptables -t nat -I PREROUTING 1 -i "$AP_IFACE" -p udp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53"
    iptables -t nat -I PREROUTING 2 -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53"
    iptables -t nat -I PREROUTING 3 -i "$AP_IFACE" -p udp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53"
    iptables -t nat -I PREROUTING 4 -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53"

    # Forward Web UI traffic to AdGuard Home
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" -j DNAT --to-destination "$gip:3000" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" -j DNAT --to-destination "$gip:80" 2>/dev/null || true
    iptables -t nat -I PREROUTING 5 -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" -j DNAT --to-destination "$gip:3000"
    iptables -t nat -I PREROUTING 6 -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" -j DNAT --to-destination "$gip:80"

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
    echo "==> ${TAG} Shutting down..."
    pkill -f "hostapd /tmp/hostapd-${COUNTRY}.conf" 2>/dev/null || true
    pkill -f "dnsmasq --conf-file=/tmp/dnsmasq-${COUNTRY}.conf" 2>/dev/null || true
    ip rule del from "$AP_SUBNET" lookup $ROUTING_TABLE 2>/dev/null || true
    ip route flush table $ROUTING_TABLE 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p udp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.96.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p udp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -d 103.86.99.100 -j DNAT --to-destination "$gip:53" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 3000 -d "$AP_IP" -j DNAT --to-destination "$gip:3000" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -d "$AP_IP" -j DNAT --to-destination "$gip:80" 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -- nmcli dev set "$AP_IFACE" managed yes 2>/dev/null || true
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

echo "==> ${TAG} Waiting for VPN tunnel (tun0)..."
GLUETUN_PID=""
for i in $(seq 1 30); do
    GLUETUN_PID=$(find_vpn_pid 2>/dev/null || true)
    [[ -n "$GLUETUN_PID" ]] && echo "  Found at PID $GLUETUN_PID" && break
    echo "  [$i/30] Not ready yet, waiting 2s..."
    sleep 2
done
[[ -z "$GLUETUN_PID" ]] && { echo "ERROR ${TAG}: VPN tun0 not found after 60s."; exit 1; }

write_hostapd_conf
write_dnsmasq_conf

echo "==> ${TAG} Configuring $AP_IFACE..."
# Tell host NetworkManager to ignore this interface to prevent conflicts (requires pid: host and privileged: true)
nsenter -t 1 -m -u -i -n -- nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true

ip link set "$AP_IFACE" down 2>/dev/null || true
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "$AP_IP/24" dev "$AP_IFACE"
ip link set "$AP_IFACE" up

(
    while true; do
        if ! ip addr show "$AP_IFACE" | grep -q "$AP_IP"; then
            echo "  [keep-alive/${COUNTRY}] Restoring IP $AP_IP to $AP_IFACE"
            ip addr add "$AP_IP/24" dev "$AP_IFACE" 2>/dev/null || true
        fi
        sleep 5
    done
) &

echo "==> ${TAG} Starting hostapd..."
hostapd /tmp/hostapd-${COUNTRY}.conf &
HOSTAPD_PID=$!
sleep 2

echo "==> ${TAG} Starting dnsmasq..."
dnsmasq --conf-file=/tmp/dnsmasq-${COUNTRY}.conf --no-daemon &
sleep 1

echo "==> ${TAG} Setting up VPN routing (table ${ROUTING_TABLE})..."
setup_routing "$GLUETUN_PID"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  NordVPN WiFi AP LIVE  [${COUNTRY}]"
echo "║  SSID    : ${AP_SSID}"
echo "║  Password: ${AP_PASSWORD}"
echo "║  Gateway : ${AP_IP}"
echo "║  RT      : ${ROUTING_TABLE}"
echo "╚═══════════════════════════════════════════╝"

while true; do
    sleep 15

    if ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        echo "WARN ${TAG}: hostapd died, restarting..."
        hostapd /tmp/hostapd-${COUNTRY}.conf &
        HOSTAPD_PID=$!
        sleep 2
    fi

    CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
    if [[ -z "$CURRENT_PID" ]]; then
        echo "WARN ${TAG}: tun0 gone (VPN reconnecting)..."
        for _ in $(seq 1 15); do
            CURRENT_PID=$(find_vpn_pid 2>/dev/null || true)
            [[ -n "$CURRENT_PID" ]] && break
            sleep 2
        done
        if [[ -n "$CURRENT_PID" ]]; then
            echo "==> ${TAG} VPN back up, reapplying routing..."
            GLUETUN_PID=$CURRENT_PID
            setup_routing "$GLUETUN_PID"
        fi
    fi
done
