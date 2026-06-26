#!/bin/bash
# Run Both Reports — runs the diagnostic once, then produces BOTH the
# field-tech and customer reports, opens both in chromium (two tabs).
set -e

# Use the symlink path (e.g. ~/tools/run-both-reports.sh)
# so we end up in the right directory even though the real file is in
# /opt/diag-kit/scripts/.
DESKTOP_DIR="$HOME/Desktop"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
NETWORK_REPORT_SH="$TOOLS_DIR/network-report.sh"

# Capture current SSID for filename
get_ssid() {
    /usr/sbin/iw dev wlan0 link 2>/dev/null \
        | awk -F': ' '/SSID/ {print $2; exit}'
}
SSID="$(get_ssid)"
[[ -z "$SSID" ]] && SSID="unknown_network"
TS="$(date +%Y%m%d-%H%M)"
FIELD_REPORT="$DESKTOP_DIR/${SSID}_field_${TS}.html"
CUSTOMER_REPORT="$DESKTOP_DIR/${SSID}_customer_${TS}.html"
LATEST_FIELD="$DESKTOP_DIR/${SSID}_field_latest.html"
LATEST_CUSTOMER="$DESKTOP_DIR/${SSID}_customer_latest.html"

TITLE="Both Reports — $SSID"
TERMINAL=""
if command -v gnome-terminal >/dev/null; then
    TERMINAL="gnome-terminal"
elif command -v x-terminal-emulator >/dev/null; then
    TERMINAL="x-terminal-emulator"
elif command -v xterm >/dev/null; then
    TERMINAL="xterm"
fi

DIAG_DONE="$(mktemp)"
trap "rm -f '$DIAG_DONE'" EXIT

# Single terminal run: diagnostic → customer report → field report
SCRIPT='
echo "=== '"$TITLE"' ===";
echo;
echo "[1/3] Running diagnostic battery...";
diag-kit diagnose --quick 2>&1;
echo;
echo "[2/3] Building customer report...";
sudo /opt/diag-kit/report.py --input /tmp/diag-output.json --output "'"$CUSTOMER_REPORT"'";
sudo chown "$USER" "'"$CUSTOMER_REPORT"'";
echo;
echo "[3/3] Building field-tech report...";
OUTPUT_PREFIX="'"$SSID"'" "'"$NETWORK_REPORT_SH"'" >/dev/null 2>&1 || true;
LATEST_FIELD="$(ls -t "'"$DESKTOP_DIR"'"/'"$SSID"'_report_*.html "'"$DESKTOP_DIR"'"/'"$SSID"'_field*.html 2>/dev/null | head -1)";
if [[ -n "$LATEST_FIELD" ]]; then
    cp "$LATEST_FIELD" "'"$FIELD_REPORT"'";
fi;
echo;
echo "=== Both reports ready ===";
echo "Field:    '"$FIELD_REPORT"'";
echo "Customer: '"$CUSTOMER_REPORT"'";
touch "'"$DIAG_DONE"'";
read -p "Press Enter to close...";
'

case "$TERMINAL" in
    gnome-terminal*)
        gnome-terminal --title="$TITLE" -- bash -c "$SCRIPT" &
        ;;
    x-terminal-emulator*)
        x-terminal-emulator -T "$TITLE" -e bash -c "$SCRIPT" &
        ;;
    xterm*)
        xterm -T "$TITLE" -e bash -c "$SCRIPT" &
        ;;
    *)
        bash -c "$SCRIPT"
        ;;
esac

# Wait for terminal to finish
for _ in $(seq 1 300); do
    if [[ -f "$DIAG_DONE" ]]; then break; fi
    sleep 1
done

# Verify
if [[ ! -f "$CUSTOMER_REPORT" ]]; then
    zenity --error --title="Both Reports" \
        --text="The diagnostic didn't complete successfully.\nCheck the terminal output for details." \
        --width=420 2>/dev/null
    exit 1
fi

# Maintain "latest" copies
cp "$CUSTOMER_REPORT" "$LATEST_CUSTOMER"
[[ -f "$FIELD_REPORT" ]] && cp "$FIELD_REPORT" "$LATEST_FIELD"

# Open both — chromium will put them in two tabs
xdg-open "$CUSTOMER_REPORT" >/dev/null 2>&1 &
sleep 1
[[ -f "$FIELD_REPORT" ]] && xdg-open "$FIELD_REPORT" >/dev/null 2>&1 &

exit 0
