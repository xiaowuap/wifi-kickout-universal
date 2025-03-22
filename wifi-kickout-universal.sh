#!/bin/sh
#
# wifi-kickout-universal.sh
# 
# Tries multiple methods (wlanconfig, iw, hostapd_cli, ubus) to find connected
# stations, parse their signal or RSSI, and kick the ones below a given threshold.
#
# Default threshold is -70, meaning any station weaker (more negative) than -70 dBm
# will be kicked off.

LOGFILE="/tmp/autokick.log"
THRESHOLD=-70   # Adjust for your environment (e.g. -70 for negative dBm, or 30 if positive RSSI)
DATE_NOW=$(date)

echo "=== wifi-kickout-universal started on $DATE_NOW ===" >> "$LOGFILE"

##############################################
# HELPER FUNCTIONS
##############################################

# Kick using wlanconfig
kick_wlanconfig() {
    local ifc="$1"
    local mac="$2"
    echo "Using 'wlanconfig $ifc kickmac $mac' to kick." >> "$LOGFILE"
    wlanconfig "$ifc" kickmac "$mac" 2>&1 | tee -a "$LOGFILE"
}

# Kick using iw station del (works on mac80211)
kick_iw() {
    local ifc="$1"
    local mac="$2"
    echo "Using 'iw dev $ifc station del $mac' to kick." >> "$LOGFILE"
    iw dev "$ifc" station del "$mac" 2>&1 | tee -a "$LOGFILE"
}

# Kick using hostapd_cli
kick_hostapd() {
    local ifc="$1"
    local mac="$2"
    echo "Using 'hostapd_cli -i $ifc disassociate $mac' to kick." >> "$LOGFILE"
    hostapd_cli -i "$ifc" disassociate "$mac" 2>&1 | tee -a "$LOGFILE"
}

##############################################
# METHOD 1: wlanconfig (Madwifi / old Atheros)
##############################################
try_wlanconfig() {
    local ifc="$1"
    local out
    out="$(wlanconfig "$ifc" list sta 2>/dev/null)"

    # If it doesn't contain header "ADDR", we assume it failed or is empty
    if ! echo "$out" | grep -q "ADDR"; then
        return 1  # signal "didn't work"
    fi

    echo "Detected 'wlanconfig' support on $ifc" >> "$LOGFILE"

    # For debugging, log the entire station list:
    echo ">>> wlanconfig $ifc list sta output:" >> "$LOGFILE"
    echo "$out" >> "$LOGFILE"

    # Parse skipping the header line
    echo "$out" | tail -n +2 | while read -r line; do
        # Example line:
        # 00:11:22:33:44:55   1   0   44  54M  -60   45   65535  1234 EPS  00:01:23
        #   ^ MAC                                      ^ RSSI

        MAC=$(echo "$line" | awk '{print $1}')
        RSSI=$(echo "$line" | awk '{print $6}')  # adapt if columns differ

        # Validate MAC
        if echo "$MAC" | grep -Eq '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'; then
            # Numeric comparison
            if [ "$RSSI" -lt "$THRESHOLD" ]; then
                echo "[$(date)] Kicking $MAC on $ifc (RSSI: $RSSI < $THRESHOLD)" >> "$LOGFILE"
                kick_wlanconfig "$ifc" "$MAC"
            else
                echo "DEBUG: $MAC on $ifc => $RSSI (no kick)" >> "$LOGFILE"
            fi
        fi
    done

    return 0
}

##############################################
# METHOD 2: iw dev <iface> station dump
# (mac80211 driver)
##############################################
try_iw() {
    local ifc="$1"
    local out
    out="$(iw dev "$ifc" station dump 2>/dev/null)"

    # If empty, bail
    if [ -z "$out" ]; then
        return 1
    fi

    echo "Detected 'iw station dump' support on $ifc" >> "$LOGFILE"
    echo ">>> iw dev $ifc station dump output:" >> "$LOGFILE"
    echo "$out" >> "$LOGFILE"

    # We'll keep track of MAC and signal from consecutive lines
    local mac=""
    while IFS= read -r line; do
        # If line has 'Station', extract MAC
        if echo "$line" | grep -q "Station"; then
            mac=$(echo "$line" | awk '{print $2}')
        fi

        # If line has 'signal:', extract the numeric part
        if echo "$line" | grep -q "signal:"; then
            signal=$(echo "$line" | awk -F'signal: ' '{print $2}' | awk '{print $1}')
            # Compare
            if [ -n "$mac" ] && [ "$signal" -lt "$THRESHOLD" ]; then
                echo "[$(date)] Kicking $mac on $ifc (signal: $signal < $THRESHOLD)" >> "$LOGFILE"
                kick_iw "$ifc" "$mac"
            else
                echo "DEBUG: $mac on $ifc => signal $signal (no kick)" >> "$LOGFILE"
            fi
        fi
    done <<EOF
$out
EOF

    return 0
}

##############################################
# METHOD 3: hostapd_cli -i <iface> all_sta
##############################################
try_hostapd_cli() {
    local ifc="$1"
    local out
    out="$(hostapd_cli -i "$ifc" all_sta 2>&1)"

    # If "Failed to connect" is in output, we bail
    if echo "$out" | grep -q "Failed to connect"; then
        return 1
    fi

    echo "Detected 'hostapd_cli' support on $ifc" >> "$LOGFILE"
    echo ">>> hostapd_cli -i $ifc all_sta output:" >> "$LOGFILE"
    echo "$out" >> "$LOGFILE"

    # We'll parse lines that are MAC addresses and lines with "signal="
    # The typical format is something like:
    # aa:bb:cc:dd:ee:ff
    #   flags=[ASSOC][AUTHORIZED]
    #   aid=1
    #   capability=0x1431
    #   listen_interval=10
    #   signal=-65
    # ...
    local current_mac=""
    while IFS= read -r line; do
        # Check if line is a MAC
        if echo "$line" | grep -Eq '^[0-9a-fA-F:]{17}$'; then
            current_mac="$line"
            continue
        fi

        # Check if line has "signal="
        if echo "$line" | grep -q 'signal='; then
            signal=$(echo "$line" | sed 's/.*signal=\(-*[0-9]*\).*/\1/')
            if [ -n "$current_mac" ] && [ "$signal" -lt "$THRESHOLD" ]; then
                echo "[$(date)] Kicking $current_mac on $ifc (signal: $signal < $THRESHOLD)" >> "$LOGFILE"
                kick_hostapd "$ifc" "$current_mac"
            else
                echo "DEBUG: $current_mac on $ifc => signal $signal (no kick)" >> "$LOGFILE"
            fi
        fi
    done <<EOF
$out
EOF

    return 0
}

##############################################
# METHOD 4: ubus call hostapd.<iface> get_clients
##############################################
try_ubus() {
    local ifc="$1"

    # First, see if hostapd.<iface> exists
    # e.g. "ubus list" might show "hostapd.ath0" or "hostapd.wlan0"
    ubus list 2>/dev/null | grep -q "hostapd.$ifc" || return 1

    # If we have a match, call it
    local json
    json="$(ubus call "hostapd.$ifc" get_clients 2>/dev/null)"
    if [ -z "$json" ] || echo "$json" | grep -q 'Not found'; then
        return 1
    fi

    echo "Detected 'ubus hostapd.$ifc' for $ifc" >> "$LOGFILE"
    echo ">>> ubus call hostapd.$ifc get_clients output:" >> "$LOGFILE"
    echo "$json" >> "$LOGFILE"

    # A quick hacky parse of JSON for "signal" and MAC addresses:
    # The JSON format might look like:
    # {
    #   "sta_mac:aa:bb:cc:dd:ee:ff": {
    #       "signal": -65,
    #       ...
    #   },
    #   "sta_mac:11:22:33:44:55:66": {
    #       ...
    #   }
    # }
    #
    # We'll parse lines with "sta_mac" for MAC, and "signal" for the value.

    # No jq? Then let's do a quick sed/awk approach:
    echo "$json" | sed 's/[{},""]/ /g' | while read -r chunk; do
        # chunk might be sta_mac:aa:bb:cc:dd:ee:ff or signal:-65
        if echo "$chunk" | grep -Eq '^sta_mac:'; then
            current_mac=$(echo "$chunk" | cut -d':' -f2-)
        elif echo "$chunk" | grep -Eq '^signal:-?[0-9]'; then
            signal=$(echo "$chunk" | cut -d':' -f2)
            if [ -n "$current_mac" ] && [ "$signal" -lt "$THRESHOLD" ]; then
                echo "[$(date)] Kicking $current_mac on $ifc (signal: $signal < $THRESHOLD)" >> "$LOGFILE"
                # We'll assume we can do standard hostapd_cli to disassoc
                kick_hostapd "$ifc" "$current_mac"
            else
                echo "DEBUG: $current_mac on $ifc => signal $signal (no kick)" >> "$LOGFILE"
            fi
            current_mac=""
        fi
    done

    return 0
}

##############################################
# MAIN LOGIC: For each interface, try methods
##############################################
IFACES=$(ls /sys/class/net/ | grep -E '^ath|^wifi|^wlan')

if [ -z "$IFACES" ]; then
  echo "No ath/wifi/wlan interfaces found. Exiting." >> "$LOGFILE"
  echo "=== universal-autokick finished on $DATE_NOW ===" >> "$LOGFILE"
  exit 0
fi

for IFACE in $IFACES; do
    echo ">>> Checking interface: $IFACE" >> "$LOGFILE"

    # 1) Attempt wlanconfig
    if try_wlanconfig "$IFACE"; then
        continue
    fi

    # 2) Attempt iw station dump
    if try_iw "$IFACE"; then
        continue
    fi

    # 3) Attempt hostapd_cli all_sta
    if try_hostapd_cli "$IFACE"; then
        continue
    fi

    # 4) Attempt ubus call
    if try_ubus "$IFACE"; then
        continue
    fi

    # If we get here, no method succeeded
    echo "No known method for $IFACE produced station data. Skipping." >> "$LOGFILE"
done

echo "=== wifi-kickout-universal finished on $DATE_NOW ===" >> "$LOGFILE"
