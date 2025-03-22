# wifi-kickout-universal  
Automatically kick weak-signal Wi-Fi clients off your OpenWrt device, no matter which driver or interface naming scheme is at play. Because who needs freeloaders with a cringe-worthy signal anyway? 🚀🦶

---

## Table of Contents
- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Overview
**wifi-kickout-universal** is a **one-stop script** for OpenWrt that tries every known Wi-Fi management method (like `wlanconfig`, `iw`, `hostapd_cli`, `ubus`) to:
1. Discover your Wi-Fi interfaces.
2. Gather connected station info.
3. Inspect their signal/RSSI.
4. Kick anyone who falls below your **threshold** (a.k.a. *The Line of Shame* 😏).

In short: *It’s your Wi-Fi bouncer.* And it’s not afraid to show clients the door (disassociation) if they don’t meet your signal standards. 🔥

---

## Features
- **Auto-detect** Wi-Fi interfaces named `athX`, `wifiX`, or `wlanX`.
- **Tries multiple station-listing methods** until one works:
  - `wlanconfig` (old Atheros/Madwifi),
  - `iw dev <iface> station dump` (mac80211),
  - `hostapd_cli -i <iface> all_sta`,
  - `ubus call hostapd.<iface> get_clients`.
- **Auto-kick** clients below your specified signal threshold:
  - Uses `wlanconfig ... kickmac` if available,
  - Falls back to `iw dev <iface> station del`,
  - or `hostapd_cli disassociate`,
  - or… *whatever it can find*.
- **Extensive logging** in `/tmp/autokick.log`.
- **Cron-friendly** – set it and forget it, letting it run every N minutes.

---

## Installation

1. **Copy** the script to your router, e.g. `/usr/bin/wifi-kickout-universal.sh`.
2. **Convert to Unix line endings** if needed (often required if you copy from Windows):
   ```bash
   opkg update
   opkg install dos2unix
   dos2unix /usr/bin/wifi-kickout-universal.sh
   ```
3. **Make it executable**:
   ```bash
   chmod +x /usr/bin/wifi-kickout-universal.sh
   ```

---

## Usage

Run it manually:
```bash
/usr/bin/wifi-kickout-universal.sh
```
Check logs to see if it kicked out any unsuspecting devices:
```bash
cat /tmp/autokick.log  | grep Kick
```

### Cron Setup

If you’d like to keep the Wi-Fi realm free of moochers 24/7, schedule it:
```bash
echo "*/5 * * * * /usr/bin/wifi-kickout-universal.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```
That’ll run it every 5 minutes. Feel free to adjust as you see fit.

---

## Configuration

By default, the script uses:
```bash
THRESHOLD=-70
```
This means: “Kick any station with a signal weaker than **-70 dBm**.” If your device gives **positive** RSSI values (e.g., `40` for strong, `15` for weak), **change** that line to a positive threshold (e.g., `THRESHOLD=30`).

---

## How It Works

1. **Collect Interfaces**  
   It scans `/sys/class/net/` for anything that starts with `ath`, `wifi`, or `wlan`.
   
2. **Try Methods in Order**  
   - **`wlanconfig`:** Looks for a station list containing “ADDR.”  
   - **`iw`:** Checks if output from `station dump` is non-empty.  
   - **`hostapd_cli`:** Checks if it can connect to the socket.  
   - **`ubus`:** Checks if `hostapd.<iface>` is listed in `ubus`.  

   If one method successfully returns station data, it’s used to parse MAC + signal. 

3. **Kick**  
   If a station’s signal is below `$THRESHOLD`, the script logs and forcibly boots them:
   - `wlanconfig <iface> kickmac <MAC>`  
   - or `iw dev <iface> station del <MAC>`  
   - or `hostapd_cli -i <iface> disassociate <MAC>`  
   - depending on which method was successful.

4. **Logs**  
   Everything gets recorded to `/tmp/autokick.log`, so you can read your triumphant war stories whenever you please.

---

## Troubleshooting

1. **Syntax Errors**  
   - Possibly caused by Windows line endings. Use `dos2unix` or `sed -i 's/\r//g' wifi-kickout-universal.sh`.

2. **No Stations Kicked**  
   - Maybe no device is below your threshold. Lower your threshold to something ridiculous like `-30` just to test.  
   - Or check you’re referencing the correct columns if `wlanconfig` has a weird output format.

3. **All Clients Kicked**  
   - If your device uses negative dBm (like `-60`) but your threshold is a positive integer (like `30`), you’ll forcibly punt everyone (since `-60 < 30`). Switch to a negative threshold (e.g. `-70`).

4. **Method Not Found**  
   - Not all drivers support all commands. The script tries to guess. Trim out methods you don’t need if they cause confusion or errors.

---

## License

This project is licensed under the [MIT License](LICENSE). In short: do whatever you want with it, just don’t blame us if you banish your entire Wi-Fi neighborhood. 😇

---

## Acknowledgments

- The OpenWrt community for making Wi-Fi wizardry possible.
- Past, present, and future freeloaders—your tenuous signals have inspired this script’s creation.

---

**Now go forth and banish those subpar signals from your glorious Wi-Fi kingdom!**  
May your logs be ever full and your SSIDs remain *snarkily* unburdened by weak devices. 🏰⚔️✨