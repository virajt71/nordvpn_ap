#!/usr/bin/env bash
# configure_wifi_ap.sh — Detect WiFi adapter capabilities, scan for congestion,
# recommend best band/channel/hw_mode, write AP_* vars to .env
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

# ─── Color helpers ──────────────────────────────────────────────────────────
COLOR_RESET=""; COLOR_BOLD=""; COLOR_BLUE=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_RED=""
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
    COLOR_RESET="$(tput sgr0)"; COLOR_BOLD="$(tput bold)"
    COLOR_BLUE="$(tput setaf 4)"; COLOR_GREEN="$(tput setaf 2)"
    COLOR_YELLOW="$(tput setaf 3)"; COLOR_RED="$(tput setaf 1)"
fi
info()    { echo "${COLOR_BLUE}$*${COLOR_RESET}" >&2; }
success() { echo "${COLOR_GREEN}$*${COLOR_RESET}" >&2; }
warn()    { echo "${COLOR_YELLOW}$*${COLOR_RESET}" >&2; }
error()   { echo "${COLOR_RED}$*${COLOR_RESET}" >&2; }
section() { echo; echo "${COLOR_BOLD}${COLOR_BLUE}[$*]${COLOR_RESET}" >&2; }
banner()  {
    echo >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}==========================================${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}  WiFi AP Capability Advisor${COLOR_RESET}" >&2
    echo "${COLOR_BOLD}${COLOR_BLUE}==========================================${COLOR_RESET}" >&2
}

# ─── Dependency check ───────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in iw iwlist awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}"
        error "Install: sudo apt-get install -y wireless-tools iw"
        exit 1
    fi
}

# ─── Interface enumeration ──────────────────────────────────────────────────
list_wifi_interfaces() {
    local ifaces=()
    for path in /sys/class/net/*; do
        local iface
        iface="$(basename "$path")"
        [[ -d "/sys/class/net/${iface}/wireless" ]] && ifaces+=("$iface")
    done
    echo "${ifaces[@]:-}"
}

choose_interface() {
    local ifaces=()
    mapfile -t ifaces < <(list_wifi_interfaces | tr ' ' '\n')

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        error "No WiFi interfaces found."
        exit 1
    fi

    if [[ ${#ifaces[@]} -eq 1 ]]; then
        info "Single interface found: ${ifaces[0]}"
        echo "${ifaces[0]}"
        return
    fi

    echo >&2
    info "Available WiFi interfaces:"
    local i
    for i in "${!ifaces[@]}"; do
        echo "  $((i+1))) ${ifaces[$i]}" >&2
    done

    local sel
    while true; do
        read -r -p "Select interface [1-${#ifaces[@]}]: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#ifaces[@]} )); then
            echo "${ifaces[$((sel-1))]}"
            return
        fi
        warn "Invalid. Enter number 1-${#ifaces[@]}."
    done
}

# ─── Adapter capability probe ───────────────────────────────────────────────
# Returns lines: band|modes|ht_caps|vht_caps
probe_capabilities() {
    local iface="$1"
    local phy
    phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')"

    if [[ -z "$phy" ]]; then
        error "Cannot determine phy for $iface."
        exit 1
    fi

    local phy_info
    phy_info="$(iw phy "$phy" info 2>/dev/null)"

    # ── Band detection ──────────────────────────────────────────────────
    # iw phy output: "* 2412 MHz [1]" or "\t\t\t* 5180 MHz [36]"
    local has_2g=0 has_5g=0 has_6g=0

    while IFS= read -r line; do
        # Extract numeric freq from lines containing "MHz" — use awk for portability
        if [[ "$line" =~ MHz ]]; then
            local freq
            freq="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="MHz" && (i-1)>=1) {print $(i-1); exit}}')"
            if [[ "$freq" =~ ^[0-9]+$ ]]; then
                (( freq >= 2412 && freq <= 2484 )) && has_2g=1
                (( freq >= 5160 && freq <= 5885 )) && has_5g=1
                (( freq >= 5955 && freq <= 7115 )) && has_6g=1
            fi
        fi
    done <<< "$phy_info"

    # ── AP mode support ─────────────────────────────────────────────────
    local ap_mode=0
    echo "$phy_info" | grep -q "AP$\|AP " && ap_mode=1

    # ── HT/VHT/HE caps ──────────────────────────────────────────────────
    local has_ht=0 has_vht=0 has_he=0
    echo "$phy_info" | grep -q "HT20\|HT40"   && has_ht=1
    echo "$phy_info" | grep -q "VHT Capabilit" && has_vht=1
    echo "$phy_info" | grep -q "HE Iftypes\|HE MAC"  && has_he=1

    # ── Channel widths available ─────────────────────────────────────────
    local max_width="20"
    echo "$phy_info" | grep -q "HT40"                     && max_width="40"
    echo "$phy_info" | grep -q "80 MHz\|VHT80\|short GI" && max_width="80"
    echo "$phy_info" | grep -q "160 MHz\|VHT160"          && max_width="160"

    # ── Max TX power ─────────────────────────────────────────────────────
    local max_txpower
    max_txpower="$(echo "$phy_info" | grep -oP '\d+ dBm' | sort -rn | head -1 || echo "unknown")"

    # Output structured
    echo "has_2g=${has_2g}"
    echo "has_5g=${has_5g}"
    echo "has_6g=${has_6g}"
    echo "ap_mode=${ap_mode}"
    echo "has_ht=${has_ht}"
    echo "has_vht=${has_vht}"
    echo "has_he=${has_he}"
    echo "max_width=${max_width}"
    echo "max_txpower=${max_txpower}"
    echo "phy=${phy}"
}

# ─── Channel scan & congestion analysis ─────────────────────────────────────
scan_channels() {
    local iface="$1"
    local band="$2"   # "2g" or "5g"

    section "Scanning for nearby networks on ${band}..."

    # Bring interface up for scan
    ip link set "$iface" up 2>/dev/null || true

    # Attempt passive scan; require root
    local scan_out=""
    if [[ $EUID -eq 0 ]]; then
        scan_out="$(iwlist "$iface" scan 2>/dev/null || iw dev "$iface" scan 2>/dev/null || true)"
    else
        warn "Not root — skipping live scan. Channel recommendation uses defaults."
        if [[ "$band" == "2g" ]]; then echo "best_channel=6"
        else echo "best_channel=36"; fi
        return
    fi

    if [[ -z "$scan_out" ]]; then
        warn "Scan returned no results. Channel recommendation uses defaults."
        if [[ "$band" == "2g" ]]; then echo "best_channel=6"
        else echo "best_channel=36"; fi
        return
    fi

    # Count networks per channel
    declare -A chan_count
    local channels_seen=()

    while IFS= read -r line; do
        local ch
        ch="$(echo "$line" | grep -oP '(?<=Channel )\d+' || true)"
        [[ -z "$ch" ]] && continue

        # Filter by band
        if [[ "$band" == "2g" ]] && (( ch > 14 )); then continue; fi
        if [[ "$band" == "5g" ]] && (( ch <= 14 )); then continue; fi

        if [[ -z "${chan_count[$ch]+_}" ]]; then
            chan_count[$ch]=0
            channels_seen+=("$ch")
        fi
        (( chan_count[$ch]++ ))
    done <<< "$scan_out"

    if [[ ${#channels_seen[@]} -eq 0 ]]; then
        if [[ "$band" == "2g" ]]; then echo "best_channel=6"
        else echo "best_channel=36"; fi
        return
    fi

    # Print congestion table
    info "Channel congestion (networks detected per channel):"
    for ch in $(echo "${channels_seen[@]}" | tr ' ' '\n' | sort -n); do
        printf "  Channel %3d : %d network(s)\n" "$ch" "${chan_count[$ch]}" >&2
    done

    # Pick channel with fewest networks
    # 2.4GHz: prefer non-overlapping set {1,6,11}; 5GHz: prefer UNII-1 {36,40,44,48}
    local best_ch="" best_count=9999

    if [[ "$band" == "2g" ]]; then
        local preferred=(1 6 11)
        for ch in "${preferred[@]}"; do
            local count="${chan_count[$ch]:-0}"
            if (( count < best_count )); then
                best_count=$count
                best_ch=$ch
            fi
        done
        # Fallback: any 2.4 channel
        if [[ -z "$best_ch" ]]; then
            for ch in 1 6 11 2 3 4 5 7 8 9 10 13; do
                local count="${chan_count[$ch]:-0}"
                if (( count < best_count )); then
                    best_count=$count
                    best_ch=$ch
                fi
            done
        fi
    else
        local preferred=(36 40 44 48 149 153 157 161)
        for ch in "${preferred[@]}"; do
            local count="${chan_count[$ch]:-0}"
            if (( count < best_count )); then
                best_count=$count
                best_ch=$ch
            fi
        done
    fi

    echo "best_channel=${best_ch:-6}"
    echo "channel_congestion=${best_count}"
}

# ─── Band + mode recommendation ─────────────────────────────────────────────
recommend_config() {
    local has_2g="$1"
    local has_5g="$2"
    local has_ht="$3"
    local has_vht="$4"
    local has_he="$5"
    local max_width="$6"
    local best_ch_2g="${7:-6}"
    local best_ch_5g="${8:-36}"

    local rec_band rec_channel rec_hw_mode rec_width rec_reason

    section "Recommendation"

    # Decision logic
    if [[ "$has_5g" == "1" ]]; then
        rec_band="5GHz"
        rec_channel="$best_ch_5g"

        if [[ "$has_he" == "1" ]]; then
            rec_hw_mode="ax"
            rec_width="80"
            rec_reason="Adapter supports WiFi 6 (802.11ax). Less congestion + wider channels on 5GHz."
        elif [[ "$has_vht" == "1" ]]; then
            rec_hw_mode="ac"
            rec_width="80"
            rec_reason="Adapter supports WiFi 5 (802.11ac/VHT). Higher throughput + wide channels on 5GHz."
        elif [[ "$has_ht" == "1" ]]; then
            rec_hw_mode="a"
            rec_width="40"
            rec_reason="Adapter supports 5GHz + HT40. Better throughput, less 2.4GHz congestion."
        else
            rec_hw_mode="a"
            rec_width="20"
            rec_reason="Adapter supports 5GHz legacy (802.11a). Less congested than 2.4GHz."
        fi
    elif [[ "$has_2g" == "1" ]]; then
        rec_band="2.4GHz"
        rec_channel="$best_ch_2g"

        if [[ "$has_ht" == "1" ]]; then
            rec_hw_mode="g"
            rec_width="40"
            rec_reason="5GHz not available. Using 2.4GHz with HT40 for improved throughput."
        else
            rec_hw_mode="g"
            rec_width="20"
            rec_reason="5GHz not available. Standard 2.4GHz 802.11g/n."
        fi
    else
        error "No usable band detected. Cannot recommend config."
        exit 1
    fi

    # Cap width to adapter max
    if [[ "$rec_width" -gt "$max_width" ]]; then
        rec_width="$max_width"
        rec_reason="${rec_reason} (width capped to adapter max ${max_width}MHz)"
    fi

    echo >&2
    success "  Recommended band    : ${rec_band}"
    success "  Recommended channel : ${rec_channel}"
    success "  hw_mode             : ${rec_hw_mode}"
    success "  Channel width       : ${rec_width}MHz"
    info    "  Reason: ${rec_reason}"

    # Return values for env write
    echo "rec_band=${rec_band}"
    echo "rec_channel=${rec_channel}"
    echo "rec_hw_mode=${rec_hw_mode}"
    echo "rec_width=${rec_width}"
}

# ─── .env update ────────────────────────────────────────────────────────────
update_env() {
    local iface="$1" channel="$2" hw_mode="$3" width="$4"

    if [[ ! -f "$ENV_FILE" ]]; then
        warn ".env not found at ${ENV_FILE}. Skipping write."
        return
    fi

    local confirm
    read -r -p "Write AP_IFACE/AP_CHANNEL/AP_HW_MODE/AP_CHANNEL_WIDTH to .env? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    [[ "$confirm" =~ ^[Nn]$ ]] && info "Skipped .env update." && return

    # Update or append each key
    for kv in "AP_IFACE=${iface}" "AP_CHANNEL=${channel}" "AP_HW_MODE=${hw_mode}" "AP_CHANNEL_WIDTH=${width}"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        if grep -q "^${key}=" "$ENV_FILE"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
        else
            echo "${key}=${val}" >> "$ENV_FILE"
        fi
    done

    success ".env updated."
    info "Note: AP_HW_MODE and AP_CHANNEL_WIDTH are advisory — apply them in hostapd config if not already parameterized."
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    banner
    check_deps

    section "Interface Selection"
    IFACE="$(choose_interface)"
    info "Using: ${IFACE}"

    section "Probing Adapter Capabilities"
    # Uncomment next line to dump raw iw phy output for debugging:
    # iw phy "$(iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')" info 2>/dev/null | head -80 >&2
    declare -A CAP
    while IFS='=' read -r k v; do CAP["$k"]="$v"; done < <(probe_capabilities "$IFACE")

    echo >&2
    info "  2.4GHz support : ${CAP[has_2g]}"
    info "  5GHz support   : ${CAP[has_5g]}"
    info "  6GHz support   : ${CAP[has_6g]}"
    info "  AP mode        : ${CAP[ap_mode]}"
    info "  HT (n)         : ${CAP[has_ht]}"
    info "  VHT (ac)       : ${CAP[has_vht]}"
    info "  HE (ax/WiFi6)  : ${CAP[has_he]}"
    info "  Max width      : ${CAP[max_width]}MHz"
    info "  Max TX power   : ${CAP[max_txpower]}"

    if [[ "${CAP[ap_mode]}" == "0" ]]; then
        warn "Adapter may not support AP mode. hostapd might fail. Proceed anyway."
    fi

    # Fallback: if driver didn't expose freq list (common on some Arch/in-kernel drivers),
    # let user declare band manually so rest of script can proceed.
    if [[ "${CAP[has_2g]}" == "0" && "${CAP[has_5g]}" == "0" ]]; then
        warn "Band auto-detect returned 0/0 — driver may restrict freq listing."
        warn "To debug: run 'iw phy \$(iw dev ${IFACE} info | awk '/wiphy/{print \"phy\"\$2}') info | grep MHz'"
        local manual_band_fallback
        read -r -p "Manually declare adapter band [2g/5g]: " manual_band_fallback
        case "$manual_band_fallback" in
            5g|5G) CAP[has_5g]=1 ;;
            *)     CAP[has_2g]=1 ;;
        esac
        info "Proceeding with manually declared band: ${manual_band_fallback}"
    fi

    # Scan both available bands
    BEST_CH_2G="6"
    BEST_CH_5G="36"

    if [[ "${CAP[has_2g]}" == "1" ]]; then
        declare -A SCAN_2G
        while IFS='=' read -r k v; do SCAN_2G["$k"]="$v"; done < <(scan_channels "$IFACE" "2g")
        BEST_CH_2G="${SCAN_2G[best_channel]:-6}"
        info "Least congested 2.4GHz channel: ${BEST_CH_2G}"
    fi

    if [[ "${CAP[has_5g]}" == "1" ]]; then
        declare -A SCAN_5G
        while IFS='=' read -r k v; do SCAN_5G["$k"]="$v"; done < <(scan_channels "$IFACE" "5g")
        BEST_CH_5G="${SCAN_5G[best_channel]:-36}"
        info "Least congested 5GHz channel: ${BEST_CH_5G}"
    fi

    # Generate recommendation — capture to var first to avoid empty-key subscript on failure
    local rec_raw
    rec_raw="$(recommend_config \
        "${CAP[has_2g]}" "${CAP[has_5g]}" \
        "${CAP[has_ht]}" "${CAP[has_vht]}" "${CAP[has_he]}" \
        "${CAP[max_width]}" \
        "$BEST_CH_2G" "$BEST_CH_5G")" || {
            error "recommend_config failed. Check adapter band detection above."
            exit 1
        }
    declare -A REC
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && REC["$k"]="$v"
    done <<< "$rec_raw"

    # Allow manual override
    echo >&2
    read -r -p "Accept recommendation? [Y/n]: " accept
    accept="${accept:-Y}"

    FINAL_CHANNEL="${REC[rec_channel]}"
    FINAL_HW_MODE="${REC[rec_hw_mode]}"
    FINAL_WIDTH="${REC[rec_width]}"

    if [[ "$accept" =~ ^[Nn]$ ]]; then
        section "Manual Override"
        read -r -p "Enter band [2g/5g]: " manual_band
        if [[ "$manual_band" == "5g" ]]; then
            read -r -p "Enter 5GHz channel (e.g. 36,40,44,48,149): " FINAL_CHANNEL
            read -r -p "Enter hw_mode [a/ac/ax]: " FINAL_HW_MODE
        else
            read -r -p "Enter 2.4GHz channel (1/6/11 recommended): " FINAL_CHANNEL
            read -r -p "Enter hw_mode [b/g/n — use 'g']: " FINAL_HW_MODE
        fi
        read -r -p "Enter channel width [20/40/80]: " FINAL_WIDTH
    fi

    # Print final summary
    section "Final Config"
    echo >&2
    printf "  %-20s %s\n" "AP_IFACE"           "$IFACE" >&2
    printf "  %-20s %s\n" "AP_CHANNEL"         "$FINAL_CHANNEL" >&2
    printf "  %-20s %s\n" "AP_HW_MODE"         "$FINAL_HW_MODE" >&2
    printf "  %-20s %s\n" "AP_CHANNEL_WIDTH"   "${FINAL_WIDTH}MHz" >&2

    # Write to .env
    update_env "$IFACE" "$FINAL_CHANNEL" "$FINAL_HW_MODE" "$FINAL_WIDTH"

    echo >&2
    success "Done. Run startup.sh (or docker compose up -d --build) to apply."
    echo >&2
}

main "$@"