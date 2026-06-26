#!/bin/bash
# diag-kit / diagnose.sh — run the network diagnostic battery
#
# Run as root (most checks need raw socket access / ARP / etc.)
# Usage:
#   sudo /opt/diag-kit/diagnose.sh [options]
#
# Options:
#   --output FILE    Write raw JSON output to FILE (default: /tmp/diag-output.json)
#   --quiet          Suppress progress output
#   --quick          Skip slow tests (iperf3, full nmap)
#   --target HOST    Specific target host for ping/mtr (default: 1.1.1.1)
#   --help           Show this help
#
# What it does:
#   1. Identifies active network interfaces (eth0 / wlan0) and IPs
#   2. Runs speed test (download/upload/ping via speedtest-cli)
#   3. Tests DNS resolution + leak (via dig + dnsleaktest.com)
#   4. Pings + MTR to target (default 1.1.1.1)
#   5. Discovers devices on the local subnet (arp-scan)
#   6. nmap scan of gateway (top 100 ports)
#   7. WiFi survey (if wlan0 is up) — channels, signal, neighbors
#   8. Path MTU discovery
#   9. iperf3 throughput test (against a public iperf3 server) — unless --quick
#  10. Captures a 10-second packet sample (tcpdump)
#
# Output: a single JSON file with sections for each check, plus a copy of
# the raw output in /tmp/diag-raw/ for drill-down if a report looks weird.

set -uo pipefail

# --- defaults ---
OUTPUT="/tmp/diag-output.json"
QUIET=0
QUICK=0
TARGET="1.1.1.1"
RAW_DIR="/tmp/diag-raw-$(date +%Y%m%d-%H%M%S)"
LOGFILE="$RAW_DIR/diagnose.log"

# --- helpers ---
log() { [ "$QUIET" -eq 0 ] && echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }
section() { log "═══ $* ═══"; }

# --- arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --output)  OUTPUT="$2"; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    --quick)   QUICK=1; shift ;;
    --target)  TARGET="$2"; shift 2 ;;
    --help|-h) grep -E "^# " "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *)         die "Unknown arg: $1" ;;
  esac
done

# --- preflight ---
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"
mkdir -p "$RAW_DIR" || die "Cannot create $RAW_DIR"
log "Output: $OUTPUT"
log "Raw artifacts: $RAW_DIR"
exec > >(tee -a "$LOGFILE") 2>&1

# --- JSON helpers (write to $OUTPUT) ---
# We assemble the whole JSON object in memory, then dump at the end.
declare -A JSON_SECTIONS
section_start() {
  local name="$1"
  log "  → $name"
  CURRENT_SECTION="$name"
  JSON_SECTIONS[$name]=""
}

# append raw text to current section
section_append() {
  if [ -n "${JSON_SECTIONS[$CURRENT_SECTION]:-}" ]; then
    JSON_SECTIONS[$CURRENT_SECTION]+=$'\n'
  fi
  JSON_SECTIONS[$CURRENT_SECTION]+="$*"
}

# append a key:value JSON-ish line
section_kv() {
  local k="$1" v="$2"
  section_append "  \"$k\": $(printf '%s' "$v" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

# --- 1. Network interfaces ---
section "1. Network interfaces"
section_start "interfaces"
ip -j addr show 2>/dev/null > "$RAW_DIR/interfaces.json" || true
cat "$RAW_DIR/interfaces.json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for iface in data:
    name = iface.get("ifname", "?")
    state = iface.get("operstate", "?")
    mac = iface.get("address", "")
    addrs = [a.get("addr","") for a in iface.get("addr_info", []) if a.get("family") == "inet"]
    print(f"  - {name} [{state}] mac={mac} ips={addrs}")
' 2>/dev/null | tee -a "$LOGFILE"

# Active interface (first one with an IP that's not lo/tailscale)
ACTIVE_IFACE=$(ip -j route show default 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get("dev") and r["dev"] not in ("lo", "tailscale0"):
        print(r["dev"])
        break
' 2>/dev/null)
[ -z "$ACTIVE_IFACE" ] && ACTIVE_IFACE="wlan0"
log "Active interface: $ACTIVE_IFACE"

# Sanity check: the diagnostic must run on the customer's LAN, not Tailscale.
# If tailscale0 is the default route, every test below would route through our
# own VPN instead of the customer's network — which would be useless for them.
DEFAULT_DEV=$(ip route | awk '/^default/ {print $5; exit}')
if [[ "$DEFAULT_DEV" == "tailscale0" ]]; then
    log ""
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║ FATAL: default route is via Tailscale ($DEFAULT_DEV)              ║"
    log "║ The diagnostic must run on the customer's LAN, not our VPN.    ║"
    log "║ Disconnect from Tailscale exit-node mode and re-run.            ║"
    log "╚═══════════════════════════════════════════════════════════════╝"
    log ""
    die "Default route is via Tailscale — refusing to run."
fi

# Warn (but don't fail) if Tailscale is reachable. We *want* the kit to stay
# on Tailscale for SSH access — but we want to make sure we're routing our
# tests out the LAN, not the VPN.
if ip route show table 52 2>/dev/null | grep -q "100.100.100.100 dev tailscale0"; then
    log "Note: Tailscale DNS override detected (100.100.100.100 routes via tailscale0)."
    log "      The DNS test below will use the customer's gateway DNS to avoid this."
fi

LOCAL_IP=$(ip -j addr show dev "$ACTIVE_IFACE" 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for iface in data:
    for a in iface.get("addr_info", []):
        if a.get("family") == "inet":
            # newer ip uses "local"; older uses "addr"
            print(a.get("local") or a.get("addr") or "")
            break
' 2>/dev/null)
log "Local IP: $LOCAL_IP"

# Gateway
GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
log "Gateway: $GATEWAY"

# Local subnet
SUBNET=$(ip -j route show 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get("dst","").endswith(".0/24") and r.get("dev","").startswith(("eth","wlan","enp","wlp")):
        print(r["dst"])
        break
' 2>/dev/null)
[ -z "$SUBNET" ] && SUBNET="192.168.1.0/24"
log "Subnet: $SUBNET"

section_kv "active_interface" "$ACTIVE_IFACE"
section_kv "local_ip" "$LOCAL_IP"
section_kv "gateway" "$GATEWAY"
section_kv "subnet" "$SUBNET"

# --- 2. Speed test ---
section "2. Speed test"
section_start "speedtest"
# Use --json for machine-readable output, --simple for human fallback
speedtest-cli --json 2>/dev/null > "$RAW_DIR/speedtest.json" || speedtest-cli --simple > "$RAW_DIR/speedtest.txt" 2>&1 || true
if [ -s "$RAW_DIR/speedtest.json" ]; then
  python3 - "$RAW_DIR/speedtest.json" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
print(f"  Download: {d.get('download', 0)/1e6:.2f} Mbps")
print(f"  Upload:   {d.get('upload', 0)/1e6:.2f} Mbps")
print(f"  Ping:     {d.get('ping', 0):.1f} ms")
print(f"  Server:   {d.get('server', {}).get('host', '?')} ({d.get('server', {}).get('sponsor', '?')})")
PYEOF
elif [ -s "$RAW_DIR/speedtest.txt" ]; then
  cat "$RAW_DIR/speedtest.txt" | sed 's/^/  /'
else
  log "  speedtest failed"
  section_kv "error" "speedtest failed"
fi

# --- 3. DNS ---
section "3. DNS resolution + leak test"
section_start "dns"
# What DNS server is in use? (could be Tailscale-overwritten — we report both)
USED_DNS=$(cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ {print $2; exit}')
log "System DNS (may be Tailscale-overridden): $USED_DNS"

# The DNS test must use the CUSTOMER's DNS, not ours. Otherwise:
#   - On our own network, Tailscale's 100.100.100.100 routes through our VPN
#   - On a customer site, Tailscale's DNS may not even reach our Quad9
# Strategy: probe the gateway on port 53 first (most home routers run DNS).
# If the gateway isn't running DNS, fall back to a public resolver (8.8.8.8)
# routed via the LAN default route — NOT via Tailscale.
TEST_DNS=""
if [[ -n "$GATEWAY" ]] && timeout 3 bash -c "echo > /dev/udp/$GATEWAY/53" 2>/dev/null; then
    TEST_DNS="$GATEWAY"
    log "DNS test server: $TEST_DNS (customer's gateway)"
elif timeout 3 bash -c "echo > /dev/udp/8.8.8.8/53" 2>/dev/null; then
    TEST_DNS="8.8.8.8"
    log "DNS test server: $TEST_DNS (Google, public — gateway doesn't run DNS)"
else
    log "WARNING: no DNS server reachable on the LAN; falling back to system DNS"
    TEST_DNS="$USED_DNS"
fi

# Resolution test — always against $TEST_DNS to avoid Tailscale leak
for domain in google.com amazon.com microsoft.com github.com; do
  start=$(date +%s%N)
  result=$(dig +short +time=3 "@$TEST_DNS" "$domain" A 2>/dev/null | head -1)
  end=$(date +%s%N)
  elapsed_ms=$(( (end - start) / 1000000 ))
  log "  $domain: ${result:-FAIL} (${elapsed_ms}ms via $TEST_DNS)"
  section_append "  resolve_${domain}_ms: $elapsed_ms"
  section_append "  resolve_${domain}_ip: ${result:-null}"
done

# DNS leak sanity check: resolve a "what's my IP"-style domain via TEST_DNS
# and via system DNS. If they disagree (different resolvers, different paths),
# that's actually expected on our own network because Tailscale-overridden DNS
# uses Quad9. We just record both for visibility.
# (Use opendns.com's "myip" endpoint which is reliable and has both A and TXT.)
LEAK_IP_CUSTOMER=$(dig +short +time=3 "@$TEST_DNS" myip.opendns.com 2>/dev/null | head -1)
[[ -z "$LEAK_IP_CUSTOMER" ]] && LEAK_IP_CUSTOMER=$(dig +short +time=3 "@$TEST_DNS" whoami.akamai.net 2>/dev/null | head -1)
LEAK_IP_SYSTEM=$(dig +short +time=3 "$USED_DNS" myip.opendns.com 2>/dev/null | head -1)
[[ -z "$LEAK_IP_SYSTEM" ]] && LEAK_IP_SYSTEM=$(dig +short +time=3 "$USED_DNS" whoami.akamai.net 2>/dev/null | head -1)
log "  Source IP seen by DNS (customer DNS):  ${LEAK_IP_CUSTOMER:-?}"
log "  Source IP seen by DNS (system DNS):     ${LEAK_IP_SYSTEM:-?}"
if [[ -n "$LEAK_IP_CUSTOMER" && -n "$LEAK_IP_SYSTEM" && "$LEAK_IP_CUSTOMER" != "$LEAK_IP_SYSTEM" ]]; then
    log "  NOTE: customer DNS and system DNS see different source IPs —"
    log "        system DNS is likely routed via Tailscale, not the LAN."
fi

section_kv "active_dns" "$USED_DNS"
section_kv "dns_test_server" "$TEST_DNS"
section_kv "dns_leak_customer_ip" "$LEAK_IP_CUSTOMER"
section_kv "dns_leak_system_ip" "$LEAK_IP_SYSTEM"

# --- 4. Ping + MTR to target ---
section "4. Ping + MTR to $TARGET"
section_start "path"
ping -c 5 -W 3 "$TARGET" 2>&1 | tail -5 | tee -a "$LOGFILE" > "$RAW_DIR/ping.txt"

# MTR (10 cycles)
mtr -n -c 10 -r "$TARGET" 2>/dev/null > "$RAW_DIR/mtr.txt" || true
if [ -s "$RAW_DIR/mtr.txt" ]; then
  log "  MTR summary:"
  tail -n +2 "$RAW_DIR/mtr.txt" | head -10 | while IFS= read -r line; do
    log "    $line"
  done
  # Loss% on last hop
  loss=$(tail -1 "$RAW_DIR/mtr.txt" | awk '{print $6}')
  avg=$(tail -1 "$RAW_DIR/mtr.txt" | awk '{print $7}')
  section_kv "final_hop_loss_pct" "${loss%.*}"
  section_kv "final_hop_avg_ms" "${avg}"
fi

# --- 5. ARP scan of subnet ---
section "5. Device discovery (arp-scan $SUBNET)"
section_start "devices"
# arp-scan needs the interface flag to bind to the right network
timeout 30 arp-scan --interface="$ACTIVE_IFACE" --localnet --quiet 2>/dev/null > "$RAW_DIR/arp.txt" || true
if [ -s "$RAW_DIR/arp.txt" ]; then
  # arp-scan binds to the LAN interface, so it physically can't see Tailscale
  # peers. But we still classify: a 100.x.x.x address would mean arp-scan
  # somehow leaked (e.g. via a bridge). Sanity-check.
  total=$(wc -l < "$RAW_DIR/arp.txt")
  tailscale_in_arp=$(grep -cE '\s100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.' "$RAW_DIR/arp.txt" 2>/dev/null | head -1)
  # grep -c with no matches returns 0; ensure it's an integer
  [[ -z "$tailscale_in_arp" ]] && tailscale_in_arp=0
  if [[ "$tailscale_in_arp" -gt 0 ]] 2>/dev/null; then
    log "  WARNING: $tailscale_in_arp Tailscale IPs found in ARP scan — likely a bridge leak"
  fi
  log "  Found $total devices on $ACTIVE_IFACE:"
  head -20 "$RAW_DIR/arp.txt" | while IFS=$'\t' read -r ip mac vendor _; do
    [ -n "$ip" ] && log "    $ip  $mac  ${vendor:-?}"
  done
  section_kv "device_count" "$total"
  section_kv "raw_arp_file" "$RAW_DIR/arp.txt"
fi

# --- 6. nmap gateway (top 100 ports) ---
section "6. nmap gateway (top 100 ports)"
section_start "gateway_scan"
if [ -n "$GATEWAY" ]; then
  timeout 60 nmap -Pn --top-ports 100 -T4 "$GATEWAY" 2>/dev/null > "$RAW_DIR/nmap-gw.txt" || true
  if [ -s "$RAW_DIR/nmap-gw.txt" ]; then
    log "  Gateway open ports:"
    grep -E "^[0-9]+/(tcp|udp).*open" "$RAW_DIR/nmap-gw.txt" | head -10 | while read -r line; do
      log "    $line"
    done
    open_count=$(grep -cE "^[0-9]+/(tcp|udp).*open" "$RAW_DIR/nmap-gw.txt" 2>/dev/null || echo 0)
    section_kv "gateway_open_ports" "$open_count"
    section_kv "raw_nmap_gw_file" "$RAW_DIR/nmap-gw.txt"
  fi
fi

# --- 7. WiFi survey ---
section "7. WiFi survey"
section_start "wifi"
if [ "$ACTIVE_IFACE" = "wlan0" ] || ip link show wlan0 2>/dev/null | grep -q "UP"; then
  iw dev wlan0 scan 2>/dev/null > "$RAW_DIR/wifi-scan.txt" || true
  if [ -s "$RAW_DIR/wifi-scan.txt" ]; then
    networks=$(grep -c "^BSS " "$RAW_DIR/wifi-scan.txt" 2>/dev/null || echo 0)
    log "  Found $networks WiFi networks in range"
    # Extract: SSID, signal, channel
    python3 << 'PYEOF' > "$RAW_DIR/wifi-summary.txt" 2>/dev/null
import re
with open("/tmp/wifi-scan.txt".replace("tmp", RAW_DIR)) as f: pass  # placeholder
PYEOF
    # Simpler: use a small Python helper
    python3 - "$RAW_DIR/wifi-scan.txt" > "$RAW_DIR/wifi-summary.txt" << 'PYEOF' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f: data = f.read()
networks = re.split(r'^BSS ', data, flags=re.MULTILINE)[1:]
for n in networks:
    ssid = re.search(r'SSID: (\S.*?)\n', n)
    signal = re.search(r'signal: ([-\d.]+) dBm', n)
    chan = re.search(r'channel (\d+)', n)
    freq = re.search(r'frequency: (\d+)', n)
    ssid_s = ssid.group(1) if ssid else "<hidden>"
    sig_s = signal.group(1) if signal else "?"
    chan_s = chan.group(1) if chan else "?"
    freq_s = freq.group(1) if freq else "?"
    print(f"  {ssid_s:32s} ch={chan_s:>2s} freq={freq_s:>4s}MHz sig={sig_s:>5s}dBm")
PYEOF
    if [ -s "$RAW_DIR/wifi-summary.txt" ]; then
      cat "$RAW_DIR/wifi-summary.txt" | head -15 | while IFS= read -r line; do log "$line"; done
      section_kv "wifi_network_count" "$networks"
      section_kv "raw_wifi_summary_file" "$RAW_DIR/wifi-summary.txt"
    fi
  fi
else
  log "  wlan0 not up; skipping WiFi survey"
  section_kv "skipped" "wlan0 not up"
fi

# --- 8. Path MTU discovery ---
section "8. Path MTU discovery"
section_start "mtu"
mtu_size=1500
mtu_ok=1
while [ $mtu_size -gt 576 ]; do
  if ping -c 1 -W 2 -M do -s $((mtu_size - 28)) "$TARGET" >/dev/null 2>&1; then
    break
  else
    mtu_ok=0
    mtu_size=$((mtu_size - 100))
  fi
done
if [ $mtu_ok -eq 1 ]; then
  log "  Path MTU: ${mtu_size} (clean)"
else
  log "  Path MTU: ${mtu_size} (fragmentation observed above this size)"
fi
section_kv "path_mtu" "$mtu_size"
section_kv "mtu_clean" "$mtu_ok"

# --- 9. iperf3 (skip if --quick) ---
section_start "iperf"
if [ $QUICK -eq 0 ]; then
  log "9. iperf3 throughput test"
  # Try several public iperf3 servers. If none reachable, try the LAN gateway.
  IPERF_SERVERS=("iperf.scottlinux.com" "speedtest.rit.edu" "ping.online.net" "iperf.he.net")
  iperf_success=0
  for srv in "${IPERF_SERVERS[@]}"; do
    log "  trying $srv..."
    if timeout 12 iperf3 -c "$srv" -P 2 -t 6 -J 2>/dev/null > "$RAW_DIR/iperf-$srv.json"; then
      if [ -s "$RAW_DIR/iperf-$srv.json" ]; then
        bps=$(python3 -c "import json; d=json.load(open('$RAW_DIR/iperf-$srv.json')); print(d['end']['sum_received']['bits_per_second'])" 2>/dev/null)
        if [ -n "$bps" ] && [ "$bps" != "0" ]; then
          mbps=$(python3 -c "print(round($bps / 1e6, 2))" 2>/dev/null)
          log "    $srv: ${mbps} Mbps"
          section_kv "iperf_server" "$srv"
          section_kv "iperf_mbps" "$mbps"
          iperf_success=1
          break
        fi
      fi
    fi
  done

  if [ $iperf_success -eq 0 ] && [ -n "$GATEWAY" ]; then
    # Fall back to LAN iperf. We can't assume a server is running on the gateway,
    # so this is a "if there's one, this finds it" check.
    log "  no public iperf3 server reachable; skipping"
    log "  (for a real LAN test, run 'iperf3 -s' on a known machine, then re-run with --target <ip>)"
    section_kv "skipped" "no public iperf3 server reachable"
  fi
else
  log "9. iperf3 (skipped, --quick)"
  section_kv "skipped" "quick mode"
fi

# --- 10. Packet capture (10 sec) ---
section "10. Packet capture (10 sec sample)"
section_start "pcap"
timeout 10 tcpdump -i "$ACTIVE_IFACE" -nn -c 100 -w "$RAW_DIR/sample.pcap" 2>/dev/null > "$RAW_DIR/tcpdump.txt" || true
if [ -s "$RAW_DIR/sample.pcap" ]; then
  pcap_size=$(ls -l "$RAW_DIR/sample.pcap" | awk '{print $5}')
  log "  Captured $pcap_size bytes to $RAW_DIR/sample.pcap"
  section_kv "pcap_file" "$RAW_DIR/sample.pcap"
  section_kv "pcap_size_bytes" "$pcap_size"
fi

# --- assemble JSON output ---
log "═══ Writing JSON output to $OUTPUT ═══"

# Use Python to assemble the final JSON properly. This avoids the heredoc/
# escape issues with embedding raw tool output inside JSON.
RAW_DIR="$RAW_DIR" QUICK="$QUICK" TARGET="$TARGET" OUTPUT="$OUTPUT" HOSTNAME_VAL="$(hostname)" \
ACTIVE_IFACE_VAL="$ACTIVE_IFACE" LOCAL_IP_VAL="$LOCAL_IP" GATEWAY_VAL="$GATEWAY" SUBNET_VAL="$SUBNET" \
USED_DNS_VAL="$USED_DNS" TEST_DNS_VAL="$TEST_DNS" \
LEAK_IP_CUSTOMER_VAL="$LEAK_IP_CUSTOMER" LEAK_IP_SYSTEM_VAL="$LEAK_IP_SYSTEM" \
python3 - <<'PYEOF'
import json, os, sys
raw_dir = os.environ['RAW_DIR']
out_path = os.environ['OUTPUT']

def safe_read(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            content = f.read()
        if not content.strip():
            return None
        return content
    except Exception as e:
        return f"<read error: {e}>"

def safe_json(path):
    content = safe_read(path)
    if content is None:
        return None
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        return None

def safe_jsonl(path):
    """Parse a text file as a list of dicts from non-JSON lines (best-effort)."""
    content = safe_read(path)
    if content is None:
        return None
    return content

out = {
    "timestamp": __import__('datetime').datetime.now().astimezone().isoformat(timespec='seconds'),
    "host": os.environ['HOSTNAME_VAL'],
    "raw_dir": raw_dir,
    "target": os.environ['TARGET'],
    "quick_mode": bool(int(os.environ['QUICK'])),
    "interfaces": safe_json(f"{raw_dir}/interfaces.json"),
    "speedtest_raw": safe_json(f"{raw_dir}/speedtest.json"),
    "devices_arp": safe_jsonl(f"{raw_dir}/arp.txt"),
    "nmap_gateway_raw": safe_jsonl(f"{raw_dir}/nmap-gw.txt"),
    "wifi_summary": safe_jsonl(f"{raw_dir}/wifi-summary.txt"),
    "ping_raw": safe_jsonl(f"{raw_dir}/ping.txt"),
    "mtr_raw": safe_jsonl(f"{raw_dir}/mtr.txt"),
    "iperf_raw": safe_jsonl(f"{raw_dir}/iperf.txt"),
    "pcap_file": f"{raw_dir}/sample.pcap" if os.path.exists(f"{raw_dir}/sample.pcap") else None,
    # Network path: how the kit is actually reaching the internet.
    # Surfaced in the report so we can prove the test ran on the customer's LAN,
    # not our Tailscale VPN.
    "network_path": {
        "active_interface": os.environ.get("ACTIVE_IFACE_VAL", ""),
        "local_ip":         os.environ.get("LOCAL_IP_VAL", ""),
        "gateway":          os.environ.get("GATEWAY_VAL", ""),
        "subnet":           os.environ.get("SUBNET_VAL", ""),
        "system_dns":       os.environ.get("USED_DNS_VAL", ""),
        "dns_test_server":  os.environ.get("TEST_DNS_VAL", ""),
        "dns_leak_customer":os.environ.get("LEAK_IP_CUSTOMER_VAL", ""),
        "dns_leak_system":  os.environ.get("LEAK_IP_SYSTEM_VAL", ""),
        "tailscale_active": os.path.exists("/var/lib/tailscale"),
    },
}

# Extract a "summary" with the key numbers
st = out.get("speedtest_raw")
if st and isinstance(st, dict):
    out["speedtest_summary"] = {
        "download_mbps": round(st.get("download", 0) / 1e6, 2),
        "upload_mbps":   round(st.get("upload", 0) / 1e6, 2),
        "ping_ms":       round(st.get("ping", 0), 1),
        "server":        st.get("server", {}).get("sponsor", "?"),
    }

# Count devices
arp = out.get("devices_arp")
if arp:
    lines = [l for l in arp.splitlines() if l.strip() and not l.startswith(("Interface:", "Starting"))]
    out["device_count"] = len(lines)

# Write the JSON
with open(out_path, 'w') as f:
    json.dump(out, f, indent=2, default=str)
print(f"[{__import__('datetime').datetime.now().strftime('%H:%M:%S')}] wrote {out_path} ({os.path.getsize(out_path)} bytes, valid JSON)")
PYEOF

log "═══ Done. Output: $OUTPUT ═══"
log "Next: sudo /opt/diag-kit/report.sh --input $OUTPUT"