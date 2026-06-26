#!/bin/bash
# Field-Tech Network Report — runs network-report.sh, opens the HTML.
# Same behavior as the existing one-tap Network-Report.desktop, just with
# error handling via zenity instead of silent failure.
set -e

# $0 is the symlink path (e.g. ~/tools/run-field-report.sh),
# so its dirname is where network-report.sh actually lives. Don't resolve the
# symlink — that would put us in /opt/diag-kit/scripts/.
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
NETWORK_REPORT_SH="$TOOLS_DIR/network-report.sh"

if [[ ! -x "$NETWORK_REPORT_SH" ]]; then
    zenity --error --title="Field Report" \
        --text="network-report.sh not found or not executable at:\n$NETWORK_REPORT_SH" \
        --width=420 2>/dev/null
    exit 1
fi

# Run it. The script itself writes the HTML to ~/Desktop and opens it.
"$NETWORK_REPORT_SH"
