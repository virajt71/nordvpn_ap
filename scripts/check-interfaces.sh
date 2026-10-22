#!/usr/bin/env bash
# =============================================================================
# check-interfaces.sh
# Pre-flight check: verifies WiFi interfaces and Docker environment are ready
# for nordvpn_ap (AP Manager).
# =============================================================================
set -euo pipefail

UPLINK="${1:-wlo1}"
AP="${2:-wlp0s20u6}"

ok()   { echo -e "\033[32m✔\033[0m  $*"; }
warn() { echo -e "\033[33m⚠\033[0m  $*"; }
fail() { echo -e "\033[31m✘\033[0m  $*"; ERRORS=$((ERRORS+1)); }

ERRORS=0

echo "═════════════════════════════════════════════════════════════"
echo "  nordvpn_ap / AP Manager — Interface & System Pre-flight"
echo "  Target Uplink : ${UPLINK}"
echo "  Target AP     : ${AP}"
echo "═════════════════════════════════════════════════════════════"

# ── Available Wireless Interfaces ─────────────────────────────────────────────
echo ""
echo "▸ Scanning available wireless interfaces..."
if command -v iw &>/dev/null; then
    WLAN_DEVS=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
    if [[ -n "$WLAN_DEVS" ]]; then
        ok "Detected wireless interfaces: $(echo $WLAN_DEVS | tr '\n' ' ')"
    else
        warn "No wireless interfaces reported by 'iw dev'"
    fi
else
    warn "'iw' not found on host — interface scanning skipped"
fi

# ── Check Uplink Interface ───────────────────────────────────────────────────
echo ""
echo "▸ Checking uplink interface (${UPLINK})..."
if ip link show "$UPLINK" &>/dev/null; then
    ok "${UPLINK} exists"
    if ip link show "$UPLINK" | grep -q "state UP"; then
        ok "${UPLINK} is UP"
        if ip addr show "$UPLINK" | grep -q "inet "; then
            UPLINK_IP=$(ip addr show "$UPLINK" | awk '/inet /{print $2}' | head -1)
            ok "${UPLINK} has IP: ${UPLINK_IP}"
        else
            warn "${UPLINK} is UP but has no IPv4 lease yet"
        fi
        if ip route show dev "$UPLINK" | grep -q "default\|via"; then
            GW=$(ip route show dev "$UPLINK" | awk '/default/{print $3}' | head -1)
            ok "${UPLINK} default gateway: ${GW:-detected}"
        fi
    else
        warn "${UPLINK} is currently DOWN (will be managed/associated by stack orchestrator)"
    fi
else
    warn "${UPLINK} not found on host — verify adapter name with: ip link"
fi

# ── Check AP Interface ───────────────────────────────────────────────────────
echo ""
echo "▸ Checking AP interface (${AP})..."
if ip link show "$AP" &>/dev/null; then
    ok "${AP} exists"
    if command -v iw &>/dev/null; then
        PHY=$(iw dev "$AP" info 2>/dev/null | awk '/wiphy/{print "phy"$2}' || true)
        if [[ -n "$PHY" ]]; then
            if iw phy "$PHY" info 2>/dev/null | grep -q "* AP$\|AP "; then
                ok "${AP} (${PHY}) supports AP mode"
            else
                fail "${AP} does NOT support AP mode — adapter cannot run hostapd"
            fi

            # Check supported bands
            HAS_2G=false
            HAS_5G=false
            iw phy "$PHY" info 2>/dev/null | grep -E "24[0-9]{2}\.0 MHz" >/dev/null 2>&1 && HAS_2G=true
            iw phy "$PHY" info 2>/dev/null | grep -E "5[0-9]{3}\.0 MHz" >/dev/null 2>&1 && HAS_5G=true
            ok "${AP} frequency bands: 2.4GHz: ${HAS_2G}, 5GHz: ${HAS_5G}"
        fi
    fi
else
    warn "${AP} not found — is your Wi-Fi dongle attached? Check: ip link"
fi

# ── Check rfkill ─────────────────────────────────────────────────────────────
echo ""
echo "▸ Checking rfkill state..."
if command -v rfkill &>/dev/null; then
    BLOCKED=$(rfkill list wifi 2>/dev/null | grep "Soft blocked: yes" || true)
    if [[ -n "$BLOCKED" ]]; then
        warn "WiFi is soft-blocked by rfkill — run: sudo rfkill unblock wifi"
    else
        ok "WiFi rfkill: unblocked"
    fi
fi

# ── Check Docker & Docker Compose ────────────────────────────────────────────
echo ""
echo "▸ Checking Docker environment..."
if command -v docker &>/dev/null; then
    if docker info &>/dev/null; then
        ok "Docker daemon is running"
        if docker compose version &>/dev/null; then
            ok "Docker Compose v2 is available ($(docker compose version --short 2>/dev/null || true))"
        else
            fail "Docker Compose v2 not found — install docker-compose-plugin"
        fi
    else
        fail "Docker daemon is not accessible"
    fi
else
    fail "Docker is not installed"
fi

# ── Check AdGuard Home (External Detection) ──────────────────────────────────
echo ""
echo "▸ Checking AdGuard Home connectivity..."
ADGUARD_CANDIDATE="192.168.50.145"
if ip link show adguard-shim &>/dev/null; then
    ok "adguard-shim interface detected on host"
fi
if ip route get "$ADGUARD_CANDIDATE" &>/dev/null; then
    ok "Route to AdGuard Home (${ADGUARD_CANDIDATE}) is reachable"
else
    warn "Route to ${ADGUARD_CANDIDATE} not directly reachable (configure if using external AdGuard)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═════════════════════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "\033[32m✔  All critical pre-flight checks passed!\033[0m"
    echo "   Start the orchestrator: docker compose up -d"
    echo "   Access dashboard:       http://localhost:42918/"
else
    echo -e "\033[31m✘  ${ERRORS} issue(s) detected — review the above output.\033[0m"
fi
echo "═════════════════════════════════════════════════════════════"
exit $ERRORS
