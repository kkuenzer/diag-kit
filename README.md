# Network Diagnostics Kit (`diag-kit`)

**Purpose:** A portable Raspberry Pi 4-based network diagnostics station. Plug into a customer's network (or connect via WiFi), run a battery of checks, generate a customer-presentable HTML report.

**Owner:** Kyle Kuenzer
**Hardware:**
- Raspberry Pi 4B (target: 4GB or 8GB RAM)
- EVICIV Raspberry Pi 10.1" Touchscreen Display
- SunFounder Bluetooth Keyboard

**Architecture:** Pi boots Pi OS, joins the kuenzer tailnet via Tailscale (tag: `diag-kit`), reachable from openclaw by SSH. When Kyle is on-site and needs help, he messages Moth on Telegram; Moth SSHes in from openclaw and helps interactively.

**OS:** Raspberry Pi OS Bookworm (target — to confirm when Pi is online)

---

## The thesis (Kyle's, not mine)

> "95% of the time, customer internet complaints aren't the ISP. They're black-hole WiFi devices, misconfigured systems, bad DNS, junk installed on their PC, zombie devices they forgot were on. The customer can't see any of this without help."

The diag-kit is the tool that **shows them what's actually wrong** — with a paper-trail HTML report they can keep.

---

## Status (2026-06-23)

- [x] Workspace project folder created (`projects/diag-kit/`)
- [x] Pi on tailnet as `netdiag` (100.87.170.11) — Kyle already had it
- [x] SSH key from openclaw installed on Pi (`~/.ssh/netdiag` private, public on Pi)
- [x] Diagnostic toolset installed (apt + pip)
- [x] `diagnose.sh` (run-all script) — written, validated on Kyle's LAN
- [x] `report.py` (HTML report generator) — written, validated
- [x] `diag-kit` wrapper installed at `/usr/local/bin/diag-kit` on the Pi
- [x] First dry-run on Kyle's home network (26 devices, 5–8 WiFi neighbors, UniFi gateway, Spectrum ISP, 30Mbps down)
- [ ] First customer-site visit using the kit

---

## Operating modes

### Mode 1: Plugged-in (Ethernet to customer router/switch)
Most thorough. Get the full network view — every device, every DNS query, every WiFi neighbor.

### Mode 2: Side-eye (WiFi-only, sitting on Kyle's desk)
Doesn't disturb customer network. Speed tests, DNS checks, internet-side diagnostics. Less thorough.

The diagnostic script auto-detects which mode based on whether Ethernet has a DHCP lease.

---

## Target checks (planned)

| Category | Tool | What it catches |
|---|---|---|
| Speed test | `iperf3` + `speedtest-cli` | Actual throughput vs. ISP-claimed |
| Latency / bufferbloat | `ping`, `flent`, `wavefront` | Bufferbloat kills video calls |
| DNS | `dig`, `dnsleaktest-cli`, response-time samples | Bad DNS = 100–500 ms/page load |
| DNS provider | which servers are in use? | Customer using ISP DNS? Suggest alternatives |
| WiFi survey | `iwlist scan`, channel overlap analysis | Why is WiFi slow in the kitchen |
| Connected devices | `nmap`, `arp-scan`, `netdiscover` | Zombie devices, rogue devices |
| Per-device bandwidth | (requires mirror port or router SNMP) | The black-hole device smoking gun |
| DHCP / IP conflicts | `arp-scan` + DHCP snooping | Two devices same IP, APIPA addresses |
| Open ports (LAN) | `nmap` gateway + known devices | Security — open ports on IoT devices |
| Router firmware check | nmap OS fingerprint + version probe | Outdated firmware, known CVEs |
| MTU discovery | `ping -M do` + `tracepath` | MTU mismatches cause weird slowness |
| UPnP / external exposure | (limited from inside; use shodan-style checks if any) | UPnP letting things in |
| Traceroute | `mtr`, `traceroute` to common destinations | Routing weirdness, CDN issues |

---

## HTML report requirements

- Color-coded status (green/yellow/red)
- Customer-facing language (no jargon in the report body; raw output in an appendix)
- Actionable recommendations with priority (High/Medium/Low)
- Visual WiFi channel map (channels 1/6/11 occupancy)
- Device list table with friendly names where possible
- Before/after section for repeat visits
- Print-friendly CSS (Kyle hands the customer a paper copy)
- "Pi-hole would help here" section with concrete numbers

---

## Open questions

1. **Tailscale tag** — confirmed: node is just on `kkuenzer@` user, not tagged `tag:diag-kit`. Adding the tag is a 30-second admin console change but isn't blocking anything.
2. **OS** — Pi OS Bookworm, desktop variant (Debian 13 trixie). Pre-installed with most tools.
3. **Storage** — 64 GB SD card, 48 GB free. SD wear is real for a reboot-heavy tool; a $20–30 USB SSD is the upgrade if you see I/O slowdowns.
4. **RAM** — 4 GB, currently 3.3 GB available. Plenty for this workload.
5. **Customer-data privacy** — the report HTML contains info about their network (device names, IPs, MAC addresses). Gitignored from openclaw-memory; the `reports/` folder is local-only.

---

## File layout

```
projects/diag-kit/
├── README.md             (this file)
├── docs/
│   └── OPENCLAW-DEPLOY.md (operating procedure, what we found, maintenance)
├── scripts/
│   ├── setup.sh          (first-boot installer — apt installs + Tailscale)
│   ├── diagnose.sh       (runs the diagnostic battery)
│   ├── report.py         (generates HTML report from JSON)
│   └── diag-kit-wrapper.sh (becomes /usr/local/bin/diag-kit on the Pi)
└── reports/              (output — gitignored, customer-specific)
```

**On the Pi:**
- `/opt/diag-kit/diagnose.sh` (installed)
- `/opt/diag-kit/report.py` (installed)
- `/usr/local/bin/diag-kit` (the wrapper, installed)
- `/tmp/diag-output.json` (latest)
- `/tmp/diag-report.html` (latest)
- `/tmp/diag-raw-<timestamp>/` (raw artifacts per run)

---

## Cross-references

- Hardware inventory: `~/.openclaw/workspace/TOOLS.md` (to add)
- Tailnet inventory: `~/.openclaw/workspace/MEMORY.md` (added)
- Tailscale auth key: `~/.openclaw/workspace/MEMORY.md` (Tailscale rotation schedule)
- OpenClaw deploy procedure: `docs/OPENCLAW-DEPLOY.md`
- First dry-run report: `reports/dryrun-v3-2026-06-23.html`