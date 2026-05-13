#!/usr/bin/env bash
# check_wifi.sh — WiFi configuration suggestor

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
C_RST=$(tput sgr0 2>/dev/null || echo "")
C_BOLD=$(tput bold 2>/dev/null || echo "")
C_DIM=$(tput dim 2>/dev/null || echo "")
C_BLUE=$(tput setaf 4 2>/dev/null || echo "")
C_CYAN=$(tput setaf 6 2>/dev/null || echo "")
C_GREEN=$(tput setaf 2 2>/dev/null || echo "")
C_YELLOW=$(tput setaf 3 2>/dev/null || echo "")
C_RED=$(tput setaf 1 2>/dev/null || echo "")

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "${C_BOLD}${C_BLUE}┌────────────────────────────────────────────────────┐${C_RST}"
echo "${C_BOLD}${C_BLUE}│           WiFi Interface Configuration             │${C_RST}"
echo "${C_BOLD}${C_BLUE}└────────────────────────────────────────────────────┘${C_RST}"
echo

if ! command -v iw >/dev/null 2>&1; then
    echo "${C_RED}✖ Error: 'iw' command not found.${C_RST}"
    exit 1
fi

# Get list of wireless interfaces
interfaces=()
for p in /sys/class/net/*; do
    iface=$(basename "$p")
    [[ -d "/sys/class/net/${iface}/wireless" ]] && interfaces+=("$iface")
done

if [[ ${#interfaces[@]} -eq 0 ]]; then
    echo "${C_YELLOW}⚠ No wireless interfaces detected.${C_RST}"
    exit 0
fi

for iface in "${interfaces[@]}"; do
    echo "${C_BOLD}${C_CYAN}Interface: ${iface}${C_RST}"
    
    # Robust phy determination
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
    if [[ -z "$phy" && -f "/sys/class/net/${iface}/phy80211/index" ]]; then
        phy="phy$(cat "/sys/class/net/${iface}/phy80211/index")"
    fi

    if [[ -z "$phy" ]]; then
        echo "  ${C_RED}✖ Could not determine physical device for ${iface}${C_RST}"
        echo
        continue
    fi

    # Device description
    if command -v udevadm >/dev/null 2>&1; then
        vendor=$(udevadm info -q property -p "/sys/class/net/${iface}" | grep "ID_VENDOR_FROM_DATABASE" | cut -d= -f2 || true)
        model=$(udevadm info -q property -p "/sys/class/net/${iface}" | grep "ID_MODEL_FROM_DATABASE" | cut -d= -f2 || true)
        [[ -n "$vendor" || -n "$model" ]] && echo "  ${C_DIM}Device: ${vendor} ${model}${C_RST}"
    fi

    # Capability query
    if ! iw_list=$(iw phy "$phy" info 2>/dev/null); then
        echo "  ${C_RED}✖ Failed to query capabilities for ${iface} (device busy)${C_RST}"
        echo
        continue
    fi
    
    # AP mode check
    if echo "$iw_list" | grep -A 25 "Supported interface modes:" | grep -q "^\s*\* AP$"; then
        echo "  ${C_GREEN}✔ AP (Access Point) mode: SUPPORTED${C_RST}"
    else
        echo "  ${C_RED}✖ AP (Access Point) mode: NOT SUPPORTED${C_RST}"
        echo
        continue
    fi

    # Detection logic for recommendation
    has_5=0; has_ac=0; has_n=0
    [[ "$iw_list" =~ "Band 2" ]] && has_5=1
    [[ "$iw_list" =~ "HT20/HT40" ]] && has_n=1
    [[ "$iw_list" =~ "VHT Capabilities" ]] && has_ac=1

    r_chan="6"; r_hw="g"; r_width="20"

    if [[ $has_5 -eq 1 ]]; then
        r_chan="36"; r_hw="a"
        [[ $has_ac -eq 1 ]] && r_width="80" || { [[ $has_n -eq 1 ]] && r_width="40"; }
    elif [[ $has_n -eq 1 ]]; then
        r_chan="1"; r_hw="g"; r_width="20"
    fi

    # Suggested configuration
    echo
    echo "  ${C_BOLD}${C_YELLOW}Suggested configuration for your .env:${C_RST}"
    echo "    ${C_GREEN}AP_CHANNEL=${r_chan}${C_RST}"
    echo "    ${C_GREEN}AP_HW_MODE=${r_hw}${C_RST}"
    echo "    ${C_GREEN}AP_CHANNEL_WIDTH=${r_width}${C_RST}"
    echo "    ${C_GREEN}AP_SECURITY=wpa2${C_RST}"

    if [[ $has_ac -eq 1 && $has_5 -eq 1 ]]; then
        echo "    ${C_DIM}# Note: WiFi 5 (AC) on 5GHz recommended for best performance.${C_RST}"
    fi
    echo
done

echo "${C_DIM}Set regulatory domain if needed: 'sudo iw reg set <COUNTRY_CODE>'${C_RST}"
echo
