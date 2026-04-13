#!/bin/bash
# test_nmap_v1: Minimal Single Device Launcher

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE_DIR" || exit 1

DEV_ID=$1
shift

if [ -z "$DEV_ID" ]; then
    echo "Usage: ./run_single.sh <DEVICE_ID> [--reset] [--id TARGET_ID]"
    exit 1
fi

RESET_MODE=false
AGREE_MODE=false
TARGET_ID=""
NO_FILTER="false"
PKG_NAME="com.nhn.android.nmap"
GPS_PKG="com.rosteam.gpsemulator"

while [[ $# -gt 0 ]]; do
    case $1 in
        --reset) RESET_MODE=true; shift ;;
        --original) NO_FILTER="true"; shift ;;
        --id) TARGET_ID="$2"; shift 2 ;;
        --agree) AGREE_MODE=true; shift ;;
        *) shift ;;
    esac
done

CYAN="\e[1;36m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
MAGENTA="\e[1;35m"
NC="\e[0m"

# 1. Fetch Configuration from devices.json
CONFIG_FILE="api/devices.json"
DEV_JSON=$(jq -c ".devices[] | select(.id == \"$DEV_ID\")" "$CONFIG_FILE")

if [ -z "$DEV_JSON" ]; then
    echo "[-] Device $DEV_ID not found in $CONFIG_FILE!"
    exit 1
fi

ALIAS=$(echo "$DEV_JSON" | jq -r '.alias')
MITM_PORT=$(echo "$DEV_JSON" | jq -r '.mitm_port')
FRIDA_PORT=$(echo "$DEV_JSON" | jq -r '.frida_port')
ORIG_MODEL=$(echo "$DEV_JSON" | jq -r '.baseline.model')
ORIG_SSAID=$(echo "$DEV_JSON" | jq -r '.baseline.ssaid')
ORIG_ADID=$(echo "$DEV_JSON" | jq -r '.baseline.adid')
ORIG_IDFV=$(echo "$DEV_JSON" | jq -r '.baseline.idfv')
ORIG_NI=$(echo "$DEV_JSON" | jq -r '.baseline.ni')
ORIG_TOKEN=$(echo "$DEV_JSON" | jq -r '.baseline.token')
ORIG_OSVER=$(echo "$DEV_JSON" | jq -r '.baseline.osver')

# 2. Generate Random Identity to bypass detection
echo -e "${CYAN}[$ALIAS]${NC} Generating Randomized Identities..."
export NMAP_ORIG_SSAID="$ORIG_SSAID"
export NMAP_ORIG_ADID="$ORIG_ADID"
export NMAP_ORIG_IDFV="$ORIG_IDFV"
export NMAP_ORIG_NI="$ORIG_NI"
export NMAP_ORIG_TOKEN="$ORIG_TOKEN"
export NMAP_ORIG_OSVER="$ORIG_OSVER"

export NMAP_SPOOFED_MODEL="$ORIG_MODEL"
export NMAP_SPOOFED_SSAID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 16 | head -n 1)
export NMAP_SPOOFED_ADID=$(cat /proc/sys/kernel/random/uuid)
export NMAP_SPOOFED_IDFV=$(cat /proc/sys/kernel/random/uuid)
export NMAP_SPOOFED_NI=$(echo -n "$NMAP_SPOOFED_SSAID" | md5sum | awk '{print $1}')
export NMAP_SPOOFED_NLOG_TOKEN=$(python3 -c "import string, random; print(''.join(random.choices(string.ascii_letters + string.digits, k=16)))")

export NMAP_NO_FILTER="$NO_FILTER"

echo "============================================================"
echo "   NMAP V1 MINIMAL: $ALIAS ($DEV_ID)"
echo "   MITM:$MITM_PORT | FRIDA:$FRIDA_PORT"
echo "   TARGET_ID : ${TARGET_ID:-None} | RESET: $RESET_MODE | FILTER: $NO_FILTER"
if [ "$NO_FILTER" != "true" ]; then
    echo "------------------------------------------------------------"
    echo "   [SPOOFING MAPPINGS (Values will be replaced in Proxy)]"
    echo "        \"ssaid\": \"$ORIG_SSAID\" -> \"$NMAP_SPOOFED_SSAID\"," 
    echo "        \"adid\": \"$ORIG_ADID\" -> \"$NMAP_SPOOFED_ADID\"," 
    echo "        \"idfv\": \"$ORIG_IDFV\" -> \"$NMAP_SPOOFED_IDFV\"," 
    echo "        \"ni\": \"$ORIG_NI\" -> \"$NMAP_SPOOFED_NI\"," 
    echo "        \"token\": \"$ORIG_TOKEN\" -> \"$NMAP_SPOOFED_NLOG_TOKEN\"" 
fi
echo "============================================================"

# 3. Setup Logs
DATE_STR=$(date +%Y%m%d)
TIME_STR=$(date +%H%M%S)
LOG_DIR="logs/${DEV_ID}/${DATE_STR}_${TIME_STR}"
mkdir -p "$LOG_DIR"
export CAPTURE_LOG_DIR="$(realpath "$LOG_DIR")"

# Start background Logcat recording
LOGCAT_FILE="$CAPTURE_LOG_DIR/crash_debug.log"
adb -s "$DEV_ID" logcat -c
nohup adb -s "$DEV_ID" logcat *:E > "$LOGCAT_FILE" 2>&1 &
LOGCAT_PID=$!

# 4. ADBKeyboard Verification & Activation
echo -e "${CYAN}[$ALIAS]${NC} Verifying ADBKeyboard..."
ADB_KB_PKG="com.android.adbkeyboard"
if ! adb -s "$DEV_ID" shell pm list packages | grep -q "$ADB_KB_PKG"; then
    echo -e "\e[1;31m[!] CRITICAL: ADBKeyboard ($ADB_KB_PKG) is NOT installed on $ALIAS!\e[0m"
    echo -e "\e[1;31m    Please install it first: adb -s $DEV_ID install ADBKeyboard.apk\e[0m"
    exit 1
fi
adb -s "$DEV_ID" shell ime enable $ADB_KB_PKG/.AdbIME >/dev/null 2>&1
adb -s "$DEV_ID" shell ime set $ADB_KB_PKG/.AdbIME >/dev/null 2>&1

# 5. Cleanup & Purge
echo -e "${CYAN}[$ALIAS]${NC} Cleaning up existing sessions..."
adb -s "$DEV_ID" shell am force-stop $PKG_NAME
adb -s "$DEV_ID" shell am force-stop $GPS_PKG
adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
adb -s "$DEV_ID" reverse --remove-all 2>/dev/null
pkill -f "mitmdump.*$MITM_PORT" 2>/dev/null

if [ "$RESET_MODE" = true ]; then
    echo -e "${CYAN}[$ALIAS]${NC} Performing Absolute Data Purge (--reset)..."
    # Use find to preserve native libs on Android 15
    adb -s "$DEV_ID" shell su -c "find /data/data/$PKG_NAME -mindepth 1 -maxdepth 1 ! -name 'lib' -exec rm -rf {} +"
    echo -e "${GREEN}[✓] [$ALIAS] App Data Nuked.${NC}"
fi

if [ "$AGREE_MODE" = true ]; then
    echo -e "${CYAN}[$ALIAS]${NC} Injecting App Preferences (Clova, Navigation tab, High-pass)..."
    APP_UID=$(adb -s "$DEV_ID" shell "su -c 'stat -c %U /data/data/$PKG_NAME'")
    APP_UID=$(echo "$APP_UID" | tr -d '\r\n')
    cat <<EOF > tmp_prefs_$$_$DEV_ID.xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="HIPASS_POPUP_SHOWN" value="true" />
    <boolean name="INTERNAL_NAVI_UUID_PERSONAL_ROUTE_TERMS_AGREED" value="true" />
    <int name="PREF_ROUTE_TYPE" value="2" />
</map>
EOF
    cat <<EOF > tmp_navi_$$_$DEV_ID.xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="NaviUseHipassKey" value="true" />
    <boolean name="NaviAutoChangeRoute" value="true" />
</map>
EOF
    cat <<EOF > tmp_consent_$$_$DEV_ID.xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="PREF_CONSENT_CLOVA_CHECKED" value="true" />
    <boolean name="PREF_CONSENT_CLOVA_AGREED" value="true" />
</map>
EOF

    adb -s "$DEV_ID" push tmp_prefs_$$_$DEV_ID.xml /data/local/tmp/com.nhn.android.nmap_preferences.xml >/dev/null 2>&1
    adb -s "$DEV_ID" push tmp_navi_$$_$DEV_ID.xml /data/local/tmp/NativeNaviDefaults.xml >/dev/null 2>&1
    adb -s "$DEV_ID" push tmp_consent_$$_$DEV_ID.xml /data/local/tmp/ConsentInfo.xml >/dev/null 2>&1
    
    adb -s "$DEV_ID" shell "su -c 'mkdir -p /data/data/$PKG_NAME/shared_prefs'"
    adb -s "$DEV_ID" shell "su -c 'cp /data/local/tmp/com.nhn.android.nmap_preferences.xml /data/data/$PKG_NAME/shared_prefs/'"
    adb -s "$DEV_ID" shell "su -c 'cp /data/local/tmp/NativeNaviDefaults.xml /data/data/$PKG_NAME/shared_prefs/'"
    adb -s "$DEV_ID" shell "su -c 'cp /data/local/tmp/ConsentInfo.xml /data/data/$PKG_NAME/shared_prefs/'"
    
    adb -s "$DEV_ID" shell "su -c 'chown -R $APP_UID:$APP_UID /data/data/$PKG_NAME/shared_prefs'"
    adb -s "$DEV_ID" shell "su -c 'chmod -R 777 /data/data/$PKG_NAME/shared_prefs'"
    adb -s "$DEV_ID" shell "su -c 'restorecon -R /data/data/$PKG_NAME/shared_prefs'"
    
    rm -f tmp_prefs_$$_$DEV_ID.xml tmp_navi_$$_$DEV_ID.xml tmp_consent_$$_$DEV_ID.xml
fi

# 6. MITM Network proxy
echo -e "${CYAN}[$ALIAS]${NC} Setting up Proxy Tunnel (localhost:$MITM_PORT)..."
adb -s "$DEV_ID" reverse tcp:"$MITM_PORT" tcp:"$MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" shell settings put global http_proxy localhost:"$MITM_PORT"
adb -s "$DEV_ID" shell su -c 'iptables -I OUTPUT -p udp --dport 443 -j DROP'

MITM_LOG="$CAPTURE_LOG_DIR/mitm.log"
PYTHONWARNINGS=ignore nohup mitmdump -p "$MITM_PORT" \
    -s lib/mitm_addon.py \
    --ssl-insecure --listen-host 0.0.0.0 --set flow_detail=0 \
    > "$MITM_LOG" 2>&1 &
MITM_PID=$!

# 7. GPS Setup (If target ID provided)
GPS_PID=""
if [ -n "$TARGET_ID" ]; then
    echo -e "${YELLOW}[$ALIAS] Initializing GPS Simulation for Target: $TARGET_ID${NC}"
    chmod +x utils/run_gps_multi.sh
    # Start GPS emulator script
    ./utils/run_gps_multi.sh "$DEV_ID" "$TARGET_ID" &
    GPS_PID=$!
    sleep 2
fi

# 8. Start App and Minimal Frida survival
echo -e "${CYAN}[$ALIAS]${NC} Starting Frida Server..."
adb -s "$DEV_ID" shell "su -c 'killall -9 frida-server 2>/dev/null'"
adb -s "$DEV_ID" shell "su -c '( /data/local/tmp/frida-server -D >/dev/null 2>&1 & )'"
sleep 2
adb -s "$DEV_ID" forward tcp:$FRIDA_PORT tcp:27042 >/dev/null 2>&1

echo -e "${CYAN}[$ALIAS]${NC} Selecting hooks based on chipset for system stability..."
if [[ "$ORIG_MODEL" =~ ^SM-[SGN] ]]; then
    HOOK_OPTS="-l lib/hooks/_core_survival.js -l lib/hooks/network_hook.js"
else
    HOOK_OPTS="-l lib/hooks/survival_light.js -l lib/hooks/network_hook.js"
fi

FRIDA_LOG="$CAPTURE_LOG_DIR/frida.log"
nohup frida -H 127.0.0.1:$FRIDA_PORT --runtime=v8 -f "$PKG_NAME" $HOOK_OPTS --no-auto-reload > "$FRIDA_LOG" 2>&1 &
FRIDA_PID=$!

(sleep 3; adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1) &

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} [✓] [$ALIAS] SYSTEM READY. Manual driving enabled.${NC}"
echo -e " [!] Log Directory: $CAPTURE_LOG_DIR"
echo -e " [!] Press Ctrl+C to STOP"
echo -e "${GREEN}============================================================${NC}"

cleanup() {
    echo -e "\n${YELLOW}[$ALIAS] Stopping processes and restoring network...${NC}"
    
    # Suppress bash job termination messages ("죽었음")
    disown $LOGCAT_PID $MITM_PID $FRIDA_PID $GPS_PID 2>/dev/null
    kill -9 $MITM_PID $FRIDA_PID $LOGCAT_PID $GPS_PID 2>/dev/null
    
    adb -s "$DEV_ID" shell am force-stop $PKG_NAME
    adb -s "$DEV_ID" shell am force-stop $GPS_PKG
    adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
    adb -s "$DEV_ID" reverse --remove-all 2>/dev/null
    adb -s "$DEV_ID" forward --remove-all 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# Wait for manual cancellation
wait
