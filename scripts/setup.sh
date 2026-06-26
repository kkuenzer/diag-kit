#!/bin/bash
# diag-kit setup.sh — first-boot installer for the Raspberry Pi 4B diagnostics station
#
# Run on the Pi (after first boot, with screen + keyboard or via SSH)
# Idempotent: safe to re-run after pulling changes.
#
# What it does:
#   1. apt update + upgrade (full system updates)
#   2. Install diagnostic toolset (nmap, iperf3, speedtest-cli, dnsutils, etc.)
#   3. Install Tailscale (and authenticate with the diag-kit auth key)
#   4. Install report-generation deps (jq, python3 with jinja2, etc.)
#   5. Enable SSH server (default in Pi OS but verify)
#   6. Print the assigned Tailscale IP + instructions for next steps

set -euo pipefail

log() { echo "[$(date -u +%FT%TZ)] $*"; }
fail() { echo "[$(date -u +%FT%TZ)] FAIL: $*" >&2; exit 1; }

# --- 1. Pre-flight ---
log "1/6: Pre-flight checks"
command -v apt >/dev/null 2>&1 || fail "apt not found (is this Pi OS / Debian?)"
command -v sudo >/dev/null 2>&1 || fail "sudo not found"
[ "$(id -u)" -ne 0 ] && fail "Run as root or with sudo: sudo bash $0"

# --- 2. System update ---
log "2/6: apt update + upgrade"
apt update
apt upgrade -y

# --- 3. Diagnostic toolset ---
log "3/6: Install diagnostic tools"
apt install -y \
    nmap \
    iperf3 \
    dnsutils \
    traceroute \
    mtr \
    tcpdump \
    ngrep \
    iw \
    wavemon \
    arp-scan \
    net-tools \
    jq \
    python3 \
    python3-pip \
    python3-jinja2 \
    speedtest-cli \
    || fail "apt install failed"

# Official Ookla speedtest (replaces speedtest-cli if you want; OK to have both)
# https://www.speedtest.net/apps/cli
if ! command -v speedtest >/dev/null 2>&1; then
  log "  installing official Ookla speedtest CLI"
  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
  apt install -y speedtest
fi

# dnsleaktest-cli (for DNS leak testing from the command line)
# pip install dnsleaktest-cli
pip3 install --break-system-packages dnsleaktest-cli || \
    log "  WARN: dnsleaktest-cli pip install failed (non-fatal; check python3-pip setup)"

# --- 4. Tailscale ---
log "4/6: Install + authenticate Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Auth with the diag-kit auth key
# (set DIAGKIT_AUTHKEY in /etc/diag-kit.env, mode 0600, owner root)
ENVFILE=/etc/diag-kit.env
if [ -r "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

if [ -z "${DIAGKIT_AUTHKEY:-}" ]; then
  fail "DIAGKIT_AUTHKEY not set. Create /etc/diag-kit.env with:
  DIAGKIT_AUTHKEY=\"tskey-auth-XXXXX\"
  Then re-run."
fi

if ! tailscale status >/dev/null 2>&1; then
  tailscale up --authkey="$DIAGKIT_AUTHKEY" --hostname=diag-kit --advertise-tags=tag:diag-kit
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "not yet assigned")
log "  Tailscale IP: $TS_IP"

# --- 5. SSH ---
log "5/6: Enable SSH server"
systemctl enable ssh
systemctl restart ssh

# --- 6. Print instructions ---
log "6/6: Done"
cat <<EOF

============================================
Diag-Kit setup COMPLETE
============================================

Hostname:     $(hostname)
Tailscale IP: $TS_IP
Tag:          tag:diag-kit

From the main system, you should now be able to:
  ssh user@$TS_IP
or:
  ssh user@diag-kit

Next steps:
  1. Run a test scan on your own LAN:
     sudo /opt/diag-kit/scripts/diagnose.sh --quick
  2. Generate a test report:
     sudo /opt/diag-kit/scripts/report.sh --input /tmp/diag-output.json --output /tmp/test-report.html
  3. Open the report in a browser on the touchscreen (Chromium):
     chromium /tmp/test-report.html
  4. When ready, take to a customer site.

The kit is reachable from the main system at any time via SSH.
If I get stuck on a customer site, message the assistant on Telegram
and the assistant can SSH in and help.

============================================

EOF