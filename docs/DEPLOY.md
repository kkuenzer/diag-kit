# diag-kit / DEPLOY.md

How to deploy, maintain, and use the network diagnostic kit.

---

## Current state (2026-06-23)

**Hardware on hand:**
- Raspberry Pi 4B (hostname `NetDiag`, Tailscale `netdiag`, IP `192.168.1.100`)
- EVICIV Raspberry Pi 10.1" Touchscreen Display (working, /dev/input/event0-5)
- SunFounder Bluetooth keyboard (working, paired)

**OS:** Raspberry Pi OS Bookworm (Debian 13 trixie), 64-bit, desktop variant — **CONFIRMED ONLINE**
**User:** Standard user account (uid 1000), in `sudo` group with NOPASSWD.
**Tailscale:** on the tailnet as `netdiag`, direct connection to the main system.

**What I had to install (already done):**
- wavemon, arp-scan, jq, dnsutils, traceroute, ngrep, ethtool, python3-jinja2
- jinja2-cli (via pip, with `--break-system-packages`)

**What was pre-installed:** nmap, iperf3, mtr, tcpdump, iw, net-tools, chromium, python3.

**What I deployed to the Pi:**
- `/opt/diag-kit/diagnose.sh` — the diagnostic battery
- `/opt/diag-kit/report.py` — HTML report generator
- `/usr/local/bin/diag-kit` — wrapper

**Tailscale auth:** I generated a fresh key on the main system and pasted the public half
into the Pi's `~/.ssh/authorized_keys` (the Pi is on the standard user account, not a specific named user).
The matching private key is on the main system at `~/.ssh/netdiag`.

---

## Operating procedure (On a customer site)

### Before leaving home
1. Make sure the Pi is charged (or plugged in)
2. Make sure the touchscreen is connected
3. Make sure the BT keyboard is paired
4. Make sure Tailscale is on (status: `tailscale status` from the main system shows `netdiag`)

### On-site
1. Power on the Pi. Log in as `administrator` (or have it auto-login)
2. **Plug in an Ethernet cable from the customer's router/switch to the Pi's eth0 port** (this is the most informative mode — see Mode 1 below). Or, if the customer's WiFi is open, connect wlan0 to it.
3. Open a terminal on the touchscreen (or SSH from your phone via Tailscale)
4. Run the diagnostic battery:
   ```
   diag-kit diagnose          # full battery, ~3 min
   diag-kit diagnose --quick  # skip iperf3, ~90s
   ```
5. Generate the report:
   ```
   diag-kit report            # writes to /tmp/diag-report.html
   diag-kit open-report       # opens in chromium
   ```
6. Print the report to PDF (chromium has a "Print to PDF" option) or hand the customer the file
7. Save the report:
   ```
   diag-kit raw               # /tmp/diag-raw-<timestamp>  — keep these
   ```

### Two modes
- **Mode 1: Plugged in (Ethernet).** Most informative. You see the customer's full network — every device, every port, every protocol.
- **Mode 2: Side-eye (WiFi only).** Use when you don't want to disturb their network. You get speed tests, DNS, internet-side checks, but you don't see their LAN devices (unless you connect wlan0 to their WiFi).

The script auto-detects which interface is the default route and uses that.

---

## Operating procedure (Assistant helping remotely)

If I'm on a customer site and stuck, I message the assistant on Telegram. The assistant:

1. Verify the Pi is reachable: `tailscale status | grep netdiag`
2. SSH in: `ssh -i ~/.ssh/netdiag user@192.168.1.100`
3. Run interactive commands alongside me, e.g.:
   - `diag-kit diagnose --quick` to see what's happening live
   - `tail -f /tmp/diag-output.json` to see results as they come in
   - `nmap -Pn -p- 192.168.X.Y` for a deeper port scan
   - `tcpdump -i eth0 -nn` for live packet capture
4. Pull the report back: `scp user@192.168.1.100:/tmp/diag-report.html /tmp/`
5. View it in a browser: `xdg-open /tmp/diag-report.html` (or send it via Telegram)

The `~/.ssh/netdiag` private key is the auth path. Public half is on the Pi.

---

## Tailscale auth (when to rotate)

**Auth key on the Pi:** in `/etc/diag-kit.env` (mode 0600, owner root) — but actually
we're not using an auth key here; the Pi was already on the tailnet from when I
set it up. The SSH keypair I generated (main system↔netdiag) is independent of Tailscale.

**When to rotate:**
- The Tailscale auth key on the Pi expires 90 days from issue. Check the Tailscale
  admin console for the expiry.
- The SSH keypair can stay indefinitely (no expiry). Rotate if compromised.

---

## What we found on my home network (dry run, 2026-06-23)

This is the first baseline. The script caught several real things:

| Check | Result | Interpretation |
|---|---|---|
| **Speedtest** | 30.9 Mbps down / 20.5 Mbps up / 37ms ping (Spectrum server) | Healthy for a residential connection |
| **DNS** | 100.100.100.100 (Quad9) | Good choice — privacy-respecting, fast |
| **DNS resolution** | 41–43ms for first lookup, ~10ms cached | Normal |
| **Path to 1.1.1.1** | 9 hops, 0% loss after first hop, 18ms final | Clean |
| **Path MTU** | 1500 (no fragmentation) | Standard Ethernet, no issues |
| **Devices on LAN** | 26 active hosts | A lot — could be smart-home devices, IoT, etc. |
| **Gateway** | UniFi (192.168.68.1, MAC 9C:05:D6:42:E9:87) | Ports 53/80/443/8080/8443 open — all normal |
| **WiFi networks** | 5–8 in range (varies) | Includes "Autumn Acres" (own AP, ch1/6/44), "Game Network" (neighbor), and a few hidden ones |
| **iperf3** | No public server reachable from this network | Test is skipped gracefully |

**Note for first customer site visit:** try running iperf3 against a server you control
on the customer's network (a laptop running `iperf3 -s`). That's the "true local speed"
test, much more useful than internet-side iperf3 for diagnosing "the internet is slow"
in their home/office.

---

## Maintenance

### Updating the scripts

The scripts live in two places:
- **Workspace (source of truth):** `~/projects/diag-kit/scripts/`
- **Pi (running copies):** `/opt/diag-kit/`

To update the Pi after editing the workspace:
```bash
# on the main system
scp ~/projects/diag-kit/scripts/diagnose.sh user@192.168.1.100:/tmp/
scp ~/projects/diag-kit/scripts/report.py user@192.168.1.100:/tmp/

# on the Pi (via SSH)
sudo cp /tmp/diagnose.sh /opt/diag-kit/diagnose.sh
sudo cp /tmp/report.py /opt/diag-kit/report.py
```

### When to test
- After any update to `diagnose.sh` or `report.py`
- Before a customer site visit (smoke test: `diag-kit diagnose --quick`)
- After the Pi's been off for >1 month (verify tool versions still work)

### What can go wrong
- **Tailscale dies on the Pi.** Customer site means no easy reauth. Solution: pre-auth
  with a 90-day key; check before leaving home.
- **Pi runs out of battery.** Plug in at the site. Add a USB power bank to the kit.
- **Touchscreen uncalibrated.** `xinput_calibrator` to recalibrate.
- **BT keyboard not paired.** `bluetoothctl` → `pair` → `connect`. Pair at home.
- **Nmap blocked by the customer's firewall.** The script still runs; just shows fewer
  results. nmap at the gateway always works (it's the gateway's own ports).

---

## File layout (running on the Pi)

```
/opt/diag-kit/
├── diagnose.sh         # the diagnostic battery
├── report.py           # the HTML report generator
└── scripts/            # (kept for future expansion)

/usr/local/bin/
└── diag-kit            # the wrapper (commands: diagnose, report, open-report, raw)

/tmp/
├── diag-output.json    # latest JSON output
├── diag-report.html    # latest HTML report
└── diag-raw-<ts>/      # raw artifacts per run (kept until you delete)
```

---

## Next features to add (when we have data)

- [ ] **Pi-hole recommendation logic** — count ad/tracker DNS queries in the packet
  capture, suggest Pi-hole with concrete "you'd save X% of bandwidth" numbers
- [ ] **mDNS/Bonjour discovery** — see what services are advertised on the LAN
  (printers, AirPlay, Chromecast, etc.)
- [ ] **iPerf3 server mode** — `diag-kit iperf-server` runs an iperf3 server on the Pi
  itself, so customer-side devices can be tested against the kit
- [ ] **WiFi heatmap** — walk around the site with the Pi, log signal strength, generate
  a heatmap
- [ ] **Multi-pass run** — run every 5 min for an hour, generate trend graphs
- [ ] **Auto-pi-hole-mode** — turn the kit into a transparent Pi-hole for the duration
  of the visit
