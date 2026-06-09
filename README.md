# outline-plasmoid

A KDE Plasma 6 plasmoid for managing Outline VPN / Shadowsocks connections
with one click from your panel.

![KDE Plasma 6](https://img.shields.io/badge/Plasma-6-blue)
![Fedora](https://img.shields.io/badge/Fedora-ready-green)

## Overview

Click to connect. Click to disconnect. That's it.

The plasmoid talks to a local [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
client with direct process management (PID files), so disconnection is graceful.
It also configures your KDE system proxy and Firefox profiles automatically.

### Architecture

```
┌──────────────────────┐
│  KDE Panel Plasmoid  │  ← QML, one button
└─────────┬────────────┘
          │ calls outline-ss connect/disconnect
          ▼
┌──────────────────────┐
│  outline-ss (CLI)    │  ← Python, resolves ssconf:// URLs
└─────────┬────────────┘
          │ starts sslocal + pool proxy, writes config
          ▼
┌──────────────────────┐
│  outline-ss-pool     │  ← token-bucket SOCKS5 on 127.0.0.1:1081
│  (connection pool)   │     rate-limits to 2 concurrent upstream conns
└─────────┬────────────┘
          │ forwards (throttled)
          ▼
┌──────────────────────┐
│  sslocal             │  ← shadowsocks-rust, SOCKS5 on 127.0.0.1:1080
└─────────┬────────────┘
          │ shadowsocks tunnel
          ▼
┌──────────────────────┐
│  Outline Server      │  ← max 2 concurrent TCP connections per IP
└──────────────────────┘
```

## Requirements

| Package                | Fedora                  | Purpose                          |
|------------------------|-------------------------|----------------------------------|
| shadowsocks-rust       | `cargo install shadowsocks-rust` (or [RPM](https://copr.fedorainfracloud.org/coprs/atim/shadowsocks-rust/)) | SOCKS5 proxy client              |
| python3                | `python3` (base)        | CLI script runtime               |
| KDE Plasma 6           | `plasma-workspace`      | Plasmoid host                    |
| kwriteconfig6 / kded6  | `kf6-kded`              | KDE proxy configuration          |
| Firefox or Vivaldi     | `firefox` / `vivaldi`   | Browser (prefs auto-configured)  |

## Install

```bash
git clone https://github.com/arkhivar/outline-plasmoid.git
cd outline-plasmoid
./install.sh
```

Then add the **Outline SS** widget to your panel (right-click panel →
Add Widgets → search "Outline").

### What install.sh does

1. Copies `outline-ss`, `outline-ss-pool`, and `configure-firefox-proxy` to `~/.local/bin/`
2. Installs the `outline-ss@.service` systemd user unit + reloads daemon
3. Cleans up any stale proxy state from previous installations
4. Installs the plasmoid to `~/.local/share/plasma/plasmoids/`
5. Restarts the Plasma shell (if running)

## Usage

### From the panel

Click the icon → connects. Click again → disconnects.
Right-click → Configure → paste your Outline key (starts with `ssconf://`).

### From the terminal

```bash
# Connect
outline-ss connect 'ssconf://your-server:443/access-key'

# Use a named profile
outline-ss connect 'ssconf://...' --profile work

# Check status
outline-ss status
outline-ss status --profile work

# Disconnect
outline-ss disconnect

# Emergency: purge ALL proxy residues if internet breaks
outline-ss recover
```

## Safety — Preventing broken internet

The plasmoid now has three layers of defense against orphaned proxy settings:

| Layer | Mechanism | Trigger |
|-------|-----------|---------|
| **1. Disconnect cleanup** | `outline-ss disconnect` stops pool + sslocal, clears KDE + Firefox proxy | Every manual disconnect |
| **2. PID-file safety** | Pool and sslocal are tracked by PID files in `XDG_RUNTIME_DIR`; stale processes are killed on connect/disconnect | Re-connect or crash recovery |
| **3. Emergency recovery** | `outline-ss recover` | Manual — run if browsers can't reach internet |

**If your browsers break** (can't reach internet but `curl google.com` works):
```bash
outline-ss recover
systemctl --user restart xdg-desktop-portal.service
```

**Why this can happen:** Firefox's `user.js` (written by the old code) overrides
proxy preferences on every launch, and KDE's `kioslaverc` feeds
`xdg-desktop-portal`, which both Firefox and Chromium-based browsers query for
proxy settings. If the sslocal proxy dies unexpectedly, these settings point to
a dead `127.0.0.1:1080` and browsers break.

## Files

```
outline-plasmoid/
├── install.sh                          # One-command installation
├── uninstall.sh
├── README.md
├── AGENTS.md                           # Agent instructions
├── _PROBLEMS.md                        # Diagnostic log: every hurdle + fix
├── plasmoid/                           # KDE Plasma widget
│   ├── metadata.json
│   └── contents/
│       ├── ui/
│       │   ├── main.qml                # Panel button UI
│       │   └── config/
│       │       └── ConfigConnection.qml # Configuration dialog
│       └── config/
│           ├── config.qml
│           └── main.xml                # Plasmoid config schema
├── cli/
│   ├── outline-ss                      # Python CLI (connect/disconnect/status/recover)
│   ├── outline-ss-pool                 # Connection-pooling SOCKS5 proxy (token-bucket)
│   └── configure-firefox-proxy         # Firefox SOCKS5 (set/clear/status for ALL profiles)
└── systemd/
    └── outline-ss@.service             # systemd user unit template
```

**Runtime files** (after install, not in repo):

| Path | Purpose |
|------|---------|
| `~/.config/outline-ss/outline-ss@default.json` | sslocal JSON config (0600, contains password + base64 prefix) |
| `$XDG_RUNTIME_DIR/outline-ss/sslocal-default.pid` | sslocal PID file |
| `$XDG_RUNTIME_DIR/outline-ss/pool-default.pid` | Connection pool PID file |

## Backend

`outline-ss` uses `sslocal` (shadowsocks-rust) in JSON config mode (`-c` flag).
The `ssconf://` URL is resolved over HTTPS, the config is parsed, and a
JSON config file is written for sslocal.

**Prefix handling**: Outline servers may return a `prefix` field (TLS ClientHello
bytes for DPI obfuscation). The prefix is converted to base64 before being
placed in the JSON config, because `json.dumps` Unicode escaping corrupts
multi-byte prefix bytes (see `_PROBLEMS.md` §3).

## Known limitations

### 2-connection server limit

The Outline server at 194.247.182.162:24631 allows only 2 concurrent TCP
connections per client IP. Browsers open 6–12 parallel connections, so most
are silently dropped. A connection-pooling proxy (`outline-ss-pool`) serializes
upstream connections with a token bucket (burst=2, refill=1/11s). This works
for sequential `curl` requests but is **too slow for comfortable browsing** —
sites like YouTube that pull resources from 6+ hosts time out before all slots
are served. See `_PROBLEMS.md` §7 and §10 for the proposed long-term fix
(v2ray/Xray with `mux.cool` connection multiplexing).

### Prefix obfuscation

The Outline API returns a `prefix` field (TLS ClientHello header bytes) for DPI
obfuscation. Base64-encoding resolves a Python→JSON→Rust re-encoding corruption
(see `_PROBLEMS.md` §3).

### UDP not enabled

The generated config uses `mode: "tcp_only"`. Shadowsocks UDP relay caused
connection instability in testing. Most web traffic (HTTP/HTTPS) works fine
over TCP.

## Security

- The Shadowsocks password is stored in `~/.config/outline-ss/outline-ss@default.json`
  with `0600` permissions and is never committed to this repo.
- If your Outline server uses a self-signed cert, place your CA bundle at
  `~/.config/outline-ss/ca-bundle.crt` and TLS verification will be enabled.
  Otherwise certificate verification is skipped by default.

## Platform

Built for **Fedora Asahi Linux** (ARM64, KDE Plasma 6), but works on any
Linux distro with Plasma 6.

## License

MIT — see [LICENSE](LICENSE).
