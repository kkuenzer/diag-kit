#!/bin/bash
# Customer-Facing Network Report — runs the diagnostic battery + report.py,
# opens the polished color-coded HTML in chromium.
set -e

# Use the symlink path (e.g. ~/tools/run-customer-report.sh)
# so we end up in the right directory even though the real file is in
# /opt/diag-kit/scripts/.
DESKTOP_DIR="$HOME/Desktop"

# Capture current SSID for filename
get_ssid() {
    /usr/sbin/iw dev wlan0 link 2>/dev/null \
        | awk -F': ' '/SSID/ {print $2; exit}'
}
SSID="$(get_ssid)"
[[ -z "$SSID" ]] && SSID="unknown_network"
TS="$(date +%Y%m%d-%H%M)"
REPORT="$DESKTOP_DIR/${SSID}_customer_${TS}.html"
LATEST="$DESKTOP_DIR/${SSID}_customer_latest.html"

# Open a terminal so the user sees progress (and so they can close it when done).
TITLE="Customer Report — $SSID"
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

DIAG_AND_REPORT='
echo "=== '"$TITLE"' ===";
echo;
diag-kit diagnose --quick 2>&1;
echo;
echo "=== Building customer report ===";
sudo /opt/diag-kit/report.py --input /tmp/diag-output.json --output "'"$REPORT"'";
sudo chown "$USER" "'"$REPORT"'";
echo;
echo "=== Report ready ===";
echo "File: '"$REPORT"'";
touch "'"$DIAG_DONE"'";
read -p "Press Enter to close...";
'

case "$TERMINAL" in
    gnome-terminal*)
        gnome-terminal --title="$TITLE" -- bash -c "$DIAG_AND_REPORT" &
        ;;
    x-terminal-emulator*)
        x-terminal-emulator -T "$TITLE" -e bash -c "$DIAG_AND_REPORT" &
        ;;
    xterm*)
        xterm -T "$TITLE" -e bash -c "$DIAG_AND_REPORT" &
        ;;
    *)
        bash -c "$DIAG_AND_REPORT"
        ;;
esac

# Wait for the terminal to finish (poll for the flag the script touches)
for _ in $(seq 1 300); do
    if [[ -f "$DIAG_DONE" ]]; then break; fi
    sleep 1
done

# Verify success
if [[ ! -f "$REPORT" ]]; then
    zenity --error --title="Customer Report" \
        --text="The diagnostic didn't complete successfully.\nCheck the terminal output for details." \
        --width=420 2>/dev/null
    exit 1
fi

# Maintain a "latest" symlink
cp "$REPORT" "$LATEST"

# Open in default browser
xdg-open "$REPORT" >/dev/null 2>&1 &
exit 0
