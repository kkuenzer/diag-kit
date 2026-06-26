#!/usr/bin/env python3
# diag-kit / report.py — generate a customer-presentable HTML report from diagnose.sh output
#
# Usage:
#   python3 /opt/diag-kit/report.py --input /tmp/dryrun-out.json --output /tmp/report.html
#   python3 /opt/diag-kit/report.py --input /tmp/dryrun-out.json           # stdout
#
# What it does:
#   - Reads the JSON output from diagnose.sh
#   - Builds an HTML report with: summary, device list, WiFi survey,
#     speed test, gateway scan, recommendations
#   - Self-contained: inline CSS, no external assets, print-friendly
#   - Color-coded status (green/yellow/red) for at-a-glance health
#
# The report is intentionally not jargon-heavy. The raw JSON + raw artifacts
# (nmap output, wifi scan, pcap) are linked for the technical follow-up.

import argparse
import json
import os
import sys
from datetime import datetime
from html import escape

# Status thresholds (tweak as we learn what "good" looks like)
SPEED_DOWN_OK = 50.0     # Mbps — below this is "yellow"
SPEED_DOWN_BAD = 10.0    # Mbps — below this is "red"
PING_OK = 50.0           # ms
PING_BAD = 100.0
DEVICE_COUNT_OK = 15
DEVICE_COUNT_BAD = 30
WIFI_OVERLAP_OK = 4
WIFI_OVERLAP_BAD = 8

# ---------- HTML primitives ----------

def status_color(value, ok_threshold, bad_threshold, lower_is_worse=True):
    """Return green/yellow/red class based on value vs thresholds."""
    if value is None:
        return "gray"
    if lower_is_worse:
        if value <= ok_threshold:
            return "green"
        elif value <= bad_threshold:
            return "yellow"
        return "red"
    else:
        if value >= ok_threshold:
            return "green"
        elif value >= bad_threshold:
            return "yellow"
        return "red"

CSS = """
:root {
  --green: #2e7d32;
  --yellow: #f9a825;
  --red: #c62828;
  --gray: #757575;
  --bg: #fafafa;
  --fg: #212121;
  --muted: #616161;
  --card: #ffffff;
  --border: #e0e0e0;
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: var(--bg);
  color: var(--fg);
  margin: 0;
  padding: 0;
  line-height: 1.5;
}
.container { max-width: 1100px; margin: 0 auto; padding: 24px; }
header {
  background: linear-gradient(135deg, #1a237e 0%, #283593 100%);
  color: white;
  padding: 32px 24px;
  margin-bottom: 24px;
}
header h1 { margin: 0 0 4px 0; font-size: 1.8em; }
header .subtitle { opacity: 0.9; font-size: 0.95em; }
.summary-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 16px;
  margin-bottom: 24px;
}
.card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 16px 20px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.05);
}
.card h2 {
  font-size: 0.85em;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--muted);
  margin: 0 0 8px 0;
  font-weight: 600;
}
.metric {
  font-size: 2em;
  font-weight: 700;
  line-height: 1.1;
}
.metric .unit { font-size: 0.5em; font-weight: 500; color: var(--muted); margin-left: 4px; }
.metric.green { color: var(--green); }
.metric.yellow { color: var(--yellow); }
.metric.red { color: var(--red); }
.metric.gray { color: var(--gray); }
.section {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 20px 24px;
  margin-bottom: 20px;
}
.section h2 {
  font-size: 1.3em;
  margin: 0 0 12px 0;
  border-bottom: 2px solid #e8eaf6;
  padding-bottom: 8px;
}
.section h3 { font-size: 1.05em; margin: 16px 0 8px 0; color: var(--muted); }
table { width: 100%; border-collapse: collapse; font-size: 0.92em; }
th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); }
th { background: #f5f5f5; font-weight: 600; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.03em; }
tr:hover { background: #f9f9f9; }
.signal-bar {
  display: inline-block;
  width: 80px;
  height: 8px;
  background: #e0e0e0;
  border-radius: 4px;
  overflow: hidden;
  vertical-align: middle;
}
.signal-bar > div { height: 100%; }
.badge {
  display: inline-block;
  padding: 2px 10px;
  border-radius: 12px;
  font-size: 0.8em;
  font-weight: 600;
}
.badge.green { background: #c8e6c9; color: var(--green); }
.badge.yellow { background: #fff9c4; color: #f57f17; }
.badge.red { background: #ffcdd2; color: var(--red); }
.badge.gray { background: #eeeeee; color: var(--gray); }
.recommendation {
  background: #fffde7;
  border-left: 4px solid var(--yellow);
  padding: 12px 16px;
  margin: 12px 0;
  border-radius: 4px;
}
.recommendation.high { background: #ffebee; border-left-color: var(--red); }
.recommendation.low { background: #e8f5e9; border-left-color: var(--green); }
.recommendation strong { display: block; margin-bottom: 4px; }
footer {
  text-align: center;
  color: var(--muted);
  font-size: 0.85em;
  margin-top: 32px;
  padding: 20px;
  border-top: 1px solid var(--border);
}
details { margin: 8px 0; }
details summary { cursor: pointer; color: var(--muted); font-size: 0.9em; padding: 4px 0; }
details pre {
  background: #263238;
  color: #eceff1;
  padding: 12px;
  border-radius: 4px;
  overflow-x: auto;
  font-size: 0.8em;
  line-height: 1.4;
}
@media print {
  body { background: white; }
  header { background: white !important; color: black; border-bottom: 2px solid black; }
  .card, .section { box-shadow: none; border: 1px solid #ccc; page-break-inside: avoid; }
  details { display: block; }
  details[open] summary ~ * { display: block; }
}
"""


def render_summary_cards(d):
    """Top-of-page summary cards: speed, ping, devices, WiFi neighbors."""
    st = d.get("speedtest_summary", {})
    down = st.get("download_mbps")
    up = st.get("upload_mbps")
    ping = st.get("ping_ms")
    device_count = d.get("device_count")
    wifi_count = parse_wifi_count(d.get("wifi_summary", ""))

    down_class = status_color(down, SPEED_DOWN_OK, SPEED_DOWN_BAD)
    up_class = status_color(up, SPEED_DOWN_OK / 2, SPEED_DOWN_BAD / 2)
    ping_class = status_color(ping, PING_OK, PING_BAD)
    dev_class = status_color(device_count, DEVICE_COUNT_OK, DEVICE_COUNT_BAD)
    wifi_class = status_color(wifi_count, WIFI_OVERLAP_OK, WIFI_OVERLAP_BAD)

    cards = f"""
    <div class="summary-grid">
      <div class="card">
        <h2>Download</h2>
        <div class="metric {down_class}">{down if down is not None else '—'}<span class="unit">Mbps</span></div>
      </div>
      <div class="card">
        <h2>Upload</h2>
        <div class="metric {up_class}">{up if up is not None else '—'}<span class="unit">Mbps</span></div>
      </div>
      <div class="card">
        <h2>Latency</h2>
        <div class="metric {ping_class}">{ping if ping is not None else '—'}<span class="unit">ms</span></div>
      </div>
      <div class="card">
        <h2>Devices on LAN</h2>
        <div class="metric {dev_class}">{device_count if device_count is not None else '—'}</div>
      </div>
      <div class="card">
        <h2>WiFi Neighbors</h2>
        <div class="metric {wifi_class}">{wifi_count if wifi_count is not None else '—'}</div>
      </div>
    </div>
    """
    return cards


def parse_wifi_count(wifi_text):
    if not wifi_text:
        return None
    # count lines that look like WiFi entries (have dBm)
    return sum(1 for line in wifi_text.splitlines() if "dBm" in line)


def signal_to_pct(dbm_str):
    """Convert dBm to a 0-100 percent bar (rough mapping)."""
    try:
        dbm = float(dbm_str.replace("dBm", "").strip())
    except (ValueError, AttributeError):
        return 0
    # -30 dBm = 100%, -90 dBm = 0%
    pct = max(0, min(100, (dbm + 90) * 100 / 60))
    return int(pct)


def signal_color(dbm_str):
    try:
        dbm = float(dbm_str.replace("dBm", "").strip())
    except (ValueError, AttributeError):
        return "gray"
    if dbm >= -60:
        return "green"
    if dbm >= -75:
        return "yellow"
    return "red"


def render_wifi_table(d):
    wifi = d.get("wifi_summary", "")
    if not wifi:
        return "<p class='muted'>No WiFi data.</p>"
    import re
    rows = []
    # The wifi summary lines are fixed-width: 2 leading spaces, then SSID padded
    # to ~32 chars, then "ch=N freq=...MHz sig=...dBm". SSIDs may contain spaces
    # (e.g. "Game Network"), so we can't use split() — anchor on the trailing
    # sig=...dBm instead. Note: there's a SPACE between "ch=" and the channel
    # number (it's fixed-width output), so we use ch=\s* not ch=(\S+).
    wifi_re = re.compile(
        r"^\s{2}(.+?)\s+ch=\s*(\S+)\s+freq=\s*(\S+)\s+sig=(-?\d+\.?\d*)\s*dBm\s*$"
    )
    for line in wifi.splitlines():
        m = wifi_re.match(line)
        if not m:
            continue
        ssid, chan, _freq, sig = m.group(1).strip(), m.group(2), m.group(3), m.group(4)
        # Treat empty SSID (hidden network) as "<hidden>"
        if not ssid:
            ssid = "<hidden>"
        sig_pct = signal_to_pct(sig)
        sig_cls = signal_color(sig)
        rows.append(f"""
        <tr>
          <td><strong>{escape(ssid)}</strong></td>
          <td>{escape(chan)}</td>
          <td>
            <span class="signal-bar"><div style="width:{sig_pct}%; background:var(--{sig_cls});"></div></span>
            {escape(sig)}
          </td>
        </tr>
        """)
    if not rows:
        return "<p class='muted'>No WiFi networks in range.</p>"
    return f"""
    <table>
      <thead>
        <tr><th>Network</th><th>Channel</th><th>Signal</th></tr>
      </thead>
      <tbody>{''.join(rows)}</tbody>
    </table>
    """


def render_devices_table(d):
    arp = d.get("devices_arp", "")
    if not arp:
        return "<p class='muted'>No device scan data.</p>"
    rows = []
    for line in arp.splitlines():
        if not line.strip() or line.startswith(("Interface:", "Starting", "WARNING")):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        ip = parts[0].strip()
        mac = parts[1].strip() if len(parts) > 1 else ""
        vendor = parts[2].strip() if len(parts) > 2 else "?"
        if not ip or not mac:
            continue
        rows.append(f"<tr><td>{escape(ip)}</td><td><code>{escape(mac)}</code></td><td>{escape(vendor)}</td></tr>")
    if not rows:
        return "<p class='muted'>No devices found.</p>"
    return f"""
    <table>
      <thead><tr><th>IP</th><th>MAC</th><th>Vendor (OUI)</th></tr></thead>
      <tbody>{''.join(rows)}</tbody>
    </table>
    <p class='muted' style='font-size: 0.85em; margin-top: 8px;'>
      {len(rows)} devices discovered via ARP scan. <strong>Anything you don't recognize?</strong>
      That's the smoking gun for a "where is my bandwidth going?" investigation.
    </p>
    """


def render_nmap(d):
    raw = d.get("nmap_gateway_raw", "")
    if not raw:
        return "<p class='muted'>No nmap data.</p>"
    open_ports = []
    for line in raw.splitlines():
        if "open" in line and "/tcp" in line:
            parts = line.split()
            if len(parts) >= 3:
                port = parts[0]
                service = parts[2]
                open_ports.append((port, service))
    if not open_ports:
        return "<p>Gateway has no unexpectedly open ports.</p>"
    rows = "".join(
        f"<tr><td><code>{escape(p)}</code></td><td>{escape(s)}</td></tr>"
        for p, s in open_ports
    )
    return f"""
    <table>
      <thead><tr><th>Port</th><th>Service</th></tr></thead>
      <tbody>{rows}</tbody>
    </table>
    <p class='muted' style='font-size: 0.85em; margin-top: 8px;'>
      Ports 80/443/8080/8443 on a gateway are normal (router admin UI).
      Anything else warrants a follow-up conversation.
    </p>
    """


def render_recommendations(d):
    """Generate actionable recommendations based on the data."""
    recs = []
    st = d.get("speedtest_summary", {})
    down = st.get("download_mbps")
    up = st.get("upload_mbps")
    ping = st.get("ping_ms")
    device_count = d.get("device_count")
    wifi_count = parse_wifi_count(d.get("wifi_summary", ""))

    if down is not None and down < SPEED_DOWN_BAD:
        recs.append(("high", "Internet speed is well below the plan",
                    f"Download is {down} Mbps. If the plan promises 100+ Mbps, the issue is real and worth a call to the ISP. "
                    "If the plan is 25 Mbps, you're at the ceiling — not an ISP problem."))
    if down is not None and SPEED_DOWN_BAD <= down < SPEED_DOWN_OK:
        recs.append(("medium", "Internet speed is moderate",
                    f"Download is {down} Mbps — usable but not great. Pi-hole below often helps with perceived speed "
                    "(ads and trackers take 20-40% of typical web traffic)."))

    if up is not None and up < 5:
        recs.append(("medium", "Upload is very low",
                    f"Upload is {up} Mbps. This is usually the bottleneck for video calls. "
                    "Check whether your plan is asymmetric (most residential plans are 10-20x slower up than down)."))

    if ping is not None and ping > PING_BAD:
        recs.append(("high", "Latency is high",
                    f"Ping to 1.1.1.1 is {ping} ms. Normal is 10-30 ms. "
                    "Causes: WiFi distance, ISP routing, double NAT, congestion."))

    if device_count is not None and device_count > DEVICE_COUNT_BAD:
        recs.append(("medium", "Lots of devices on the network",
                    f"{device_count} devices on the LAN. Could be: every smart bulb is a device, "
                    "old phones in a drawer, IoT gadgets that never get updates. "
                    "Audit the list above — anything you don't recognize is a candidate for removal."))

    if wifi_count is not None and wifi_count > WIFI_OVERLAP_BAD:
        recs.append(("medium", "WiFi neighborhood is congested",
                    f"{wifi_count} networks in range. If your router is on a default channel (1, 6, or 11), "
                    "switch to the least-crowded one of those three. Anything else creates interference."))

    # Check WiFi signal strength
    wifi = d.get("wifi_summary", "")
    own_signals = []
    for line in wifi.splitlines():
        if "Autumn Acres" in line and "dBm" in line:
            # extract dBm
            try:
                sig = float(line.split("sig=")[1].replace("dBm", ""))
                own_signals.append(sig)
            except (ValueError, IndexError):
                pass
    if own_signals:
        weakest = max(own_signals)  # max dBm = weakest (least negative)
        if weakest < -75:
            recs.append(("medium", "Your WiFi signal is weak in this location",
                        f"Weakest signal from your access point: {weakest} dBm. "
                        "Consider a mesh system, additional AP, or moving the existing AP to a more central location."))

    if not recs:
        recs.append(("low", "No major issues detected",
                    "Network looks healthy. The findings above are the baseline — re-run this check after any changes."))

    html = ""
    for prio, title, body in recs:
        html += f"""
        <div class="recommendation {prio}">
          <strong>{escape(title)}</strong>
          {escape(body)}
        </div>
        """
    return html


def render_raw_artifacts(d):
    """Collapsible raw output for the technical person."""
    raw_dir = d.get("raw_dir", "")
    return f"""
    <div class="section">
      <h2>Raw artifacts (for the technical follow-up)</h2>
      <p>All the raw data is preserved in <code>{escape(raw_dir)}</code> on the diag-kit:</p>
      <ul style="font-size: 0.92em;">
        <li><code>speedtest.json</code> — raw speedtest output (machine-readable)</li>
        <li><code>arp.txt</code> — full ARP table dump with every device</li>
        <li><code>nmap-gw.txt</code> — full nmap gateway scan output</li>
        <li><code>wifi-scan.txt</code> — raw <code>iw</code> scan output (all networks, all details)</li>
        <li><code>mtr.txt</code> — full MTR report (every hop, every loss%)</li>
        <li><code>sample.pcap</code> — 10-second packet capture, viewable in Wireshark</li>
        <li><code>ping.txt</code> — full ping output</li>
        <li><code>iperf.txt</code> — full iperf3 client output (throughput test)</li>
      </ul>
    </div>
    """


def render_network_path(d):
    """Surface the network routing setup so we can prove the diagnostic
    really ran on the customer's LAN, not via our Tailscale VPN."""
    np = d.get("network_path", {})
    if not np:
        return ""
    active = escape(np.get("active_interface", "?"))
    local_ip = escape(np.get("local_ip", "?"))
    gateway = escape(np.get("gateway", "?"))
    subnet = escape(np.get("subnet", "?"))
    system_dns = escape(np.get("system_dns", "?"))
    test_dns = escape(np.get("dns_test_server", "?"))
    leak_cust = escape(np.get("dns_leak_customer", "?"))
    leak_sys = escape(np.get("dns_leak_system", "?"))
    ts_active = np.get("tailscale_active", False)

    # DNS leak indicator
    leak_class = ""
    leak_msg = ""
    if leak_cust and leak_sys and leak_cust != "?" and leak_sys != "?" and leak_cust != leak_sys:
        leak_class = "high"
        leak_msg = (f"<strong>DNS routing note:</strong> "
                    f"system DNS sees the kit coming from <code>{leak_sys}</code>, "
                    f"customer DNS sees <code>{leak_cust}</code>. "
                    f"They differ \u2014 system DNS is likely routed via Tailscale. "
                    f"This report's DNS test uses the customer's DNS (<code>{test_dns}</code>), "
                    f"so the resolution times reflect the LAN, not the VPN.")
    elif leak_cust and leak_cust != "?":
        leak_msg = f"DNS lookups in this report were tested against <code>{test_dns}</code> (your gateway) to avoid any VPN interference."

    ts_badge = ""
    if ts_active:
        ts_badge = (' <span class="badge gray" title="Tailscale is up on the kit for SSH access; '
                    'but the diagnostic ran on the LAN, not via Tailscale.">Tailscale on</span>')

    return f"""
  <div class="section">
    <h2>How This Was Measured{ts_badge}</h2>
    <table>
      <tbody>
        <tr><th>Active interface</th><td><code>{active}</code></td></tr>
        <tr><th>Kit IP address</th><td><code>{local_ip}</code></td></tr>
        <tr><th>Gateway (router)</th><td><code>{gateway}</code></td></tr>
        <tr><th>Local subnet</th><td><code>{subnet}</code></td></tr>
        <tr><th>System DNS (resolv.conf)</th><td><code>{system_dns}</code></td></tr>
        <tr><th>DNS test server (used in this report)</th><td><code>{test_dns}</code></td></tr>
      </tbody>
    </table>
    {f'<div class="recommendation {leak_class}">{leak_msg}</div>' if leak_msg else ''}
  </div>
  """

def render(d):
    """Build the full HTML report."""
    ts = d.get("timestamp", datetime.now().isoformat())
    host = d.get("host", "diag-kit")
    target = d.get("target", "1.1.1.1")
    st = d.get("speedtest_summary", {})

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Network Diagnostic Report — {escape(host)} — {escape(ts)}</title>
  <style>{CSS}</style>
</head>
<body>
<header>
  <div class="container">
    <h1>Network Diagnostic Report</h1>
    <div class="subtitle">
      Host: <code>{escape(host)}</code> &middot;
      Generated: {escape(ts)} &middot;
      Target: {escape(target)}
    </div>
  </div>
</header>

<div class="container">
  {render_summary_cards(d)}

  {render_network_path(d)}

  <div class="section">
    <h2>Recommendations</h2>
    {render_recommendations(d)}
  </div>

  <div class="section">
    <h2>WiFi Neighborhood</h2>
    <p>Every WiFi network visible from the kit, with channel and signal strength.
    Channel overlap is a top cause of "WiFi is slow."</p>
    {render_wifi_table(d)}
  </div>

  <div class="section">
    <h2>Devices on the Network</h2>
    <p>Every device the kit saw during the ARP scan. If there are more devices than you
    expect, that's the start of the conversation.</p>
    {render_devices_table(d)}
  </div>

  <div class="section">
    <h2>Gateway (Router) Open Ports</h2>
    <p>A quick scan of your router's listening services.</p>
    {render_nmap(d)}
  </div>

  <div class="section">
    <h2>What We Tested</h2>
    <h3>Speed</h3>
    <p>Tested against {escape(st.get('server', 'a public speedtest server'))} using <code>speedtest-cli</code>.
    Result: {st.get('download_mbps', '?')} Mbps down, {st.get('upload_mbps', '?')} Mbps up, {st.get('ping_ms', '?')} ms ping.</p>

    <h3>Path</h3>
    <p>Traced the route to {escape(target)} with MTR (10 packets per hop). Full trace in the raw artifacts.</p>

    <h3>DNS</h3>
    <p>Tested resolution of four major domains and recorded the time each took. Looked at which DNS server is in use.</p>

    <h3>Devices</h3>
    <p>ARP-scanned the local subnet to find every device with an IP. This is the list of "what's on my network."</p>

    <h3>WiFi</h3>
    <p>Scanned all visible WiFi networks with <code>iw</code> to map out the channel landscape and signal strength.</p>

    <h3>Gateway</h3>
    <p>nmap-scanned the top 100 TCP ports on the router to flag anything that shouldn't be exposed.</p>
  </div>

  {render_raw_artifacts(d)}
</div>

<footer>
  Generated by diag-kit. Raw data preserved for the technical follow-up conversation.
</footer>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description="Generate HTML report from diagnose.sh JSON output")
    ap.add_argument("--input", "-i", required=True, help="JSON output from diagnose.sh")
    ap.add_argument("--output", "-o", default=None, help="Output HTML file (default: stdout)")
    args = ap.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    html = render(data)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(html)
        size = os.path.getsize(args.output)
        print(f"wrote {args.output} ({size:,} bytes)", file=sys.stderr)
    else:
        print(html)


if __name__ == "__main__":
    main()