# outline-plasmoid

A KDE Plasma 6 plasmoid for managing Outline VPN / Shadowsocks connections
with one click from your panel.

![KDE Plasma 6](https://img.shields.io/badge/Plasma-6-blue)
![Fedora](https://img.shields.io/badge/Fedora-ready-green)

## Overview

Click to connect. Click to disconnect. That's it.

The plasmoid talks to a local [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
client managed by **systemd user services**, so disconnection is graceful and
the proxy survives logout if needed. It also configures your KDE system proxy
and Firefox profiles automatically.

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
          │ writes config to ~/.config/systemd/user/
          ▼
┌──────────────────────┐
│  systemd --user      │  ← outline-ss@profile.service
└─────────┬────────────┘
          │ runs
          ▼
┌──────────────────────┐
│  sslocal             │  ← shadowsocks-rust, SOCKS5 on 127.0.0.1:1080
└──────────────────────┘
```

## Requirements

| Package                | Fedora                  | Purpose                          |
|------------------------|-------------------------|----------------------------------|
| shadowsocks-rust       | `cargo install shadowsocks-rust` (or [RPM](https://copr.fedorainfracloud.org/coprs/atim/shadowsocks-rust/)) | SOCKS5 proxy client              |
| python3                | `python3` (base)        | CLI script runtime               |
| systemd                | included                | Process lifecycle management     |
| KDE Plasma 6           | `plasma-workspace`      | Plasmoid host                    |
| kwriteconfig6 / kded6  | `kf6-kded`              | KDE proxy configuration          |

## Install

```bash
git clone https://github.com/arkhivar/outline-plasmoid.git
cd outline-plasmoid
./install.sh
```

Then add the **Outline SS** widget to your panel (right-click panel →
Add Widgets → search "Outline").

### What install.sh does

1. Copies `outline-ss` and `configure-firefox-proxy` to `~/.local/bin/`
2. Installs the `outline-ss@.service` systemd user unit
3. Reloads systemd user daemon
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
```

## Files

```
outline-plasmoid/
├── install.sh                          # One-command installation
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
│   ├── outline-ss                      # Python CLI (connect/disconnect/status)
│   └── configure-firefox-proxy         # Firefox SOCKS5 configuration
└── systemd/
    └── outline-ss@.service             # systemd user unit template
```

**Runtime files** (after install, not in repo):

| Path | Purpose |
|------|---------|
| `~/.config/systemd/user/outline-ss@profile.conf` | sslocal JSON config (0600, contains password) |
| `~/.config/systemd/user/outline-ss@profile.service` | systemd unit (symlink to installed template) |
| `$XDG_RUNTIME_DIR/outline-ss/status-profile.json` | Connection status cache |
| `~/.config/outline-ss/ca-bundle.crt` | Optional custom CA cert for Outline server |

## Security

- The Shadowsocks password is stored in `~/.config/systemd/user/` with `0600`
  permissions and is never committed to this repo.
- If your Outline server uses a self-signed cert, place your CA bundle at
  `~/.config/outline-ss/ca-bundle.crt` and TLS verification will be enabled.
  Otherwise `sslocal` handles its own certificate pinning via the config hash.

## Platform

Built for **Fedora Asahi Linux** (ARM64, KDE Plasma 6), but works on any
Linux distro with Plasma 6 and systemd.

## License

MIT — see [LICENSE](LICENSE).
