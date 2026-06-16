# outline-plasmoid

A KDE Plasma 6 plasmoid for managing Outline VPN connections with one click
from your panel. Uses the **official [outline-go-tun2socks](https://github.com/Jigsaw-Code/outline-go-tun2socks)**
Go library (same code as Outline Windows/Android clients) for maximum
compatibility with Outline servers.

![KDE Plasma 6](https://img.shields.io/badge/Plasma-6-blue)
![Fedora](https://img.shields.io/badge/Fedora-ready-green)

## Overview

Click to connect. Click to disconnect. That's it.

The plasmoid talks to **outline-go-proxy**, a Go SOCKS5 proxy built on
`outline-go-tun2socks` — the exact same library that powers the official
Outline Windows and Android clients. Native support for Outline's TLS
ClientHello prefix obfuscation (no base64 conversion needed).

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
          │ starts outline-go-proxy (or sslocal fallback)
          ▼
┌──────────────────────┐
│  outline-go-proxy    │  ← Go SOCKS5 on 127.0.0.1:1080
│  (outline-go-tun2socks)│    same library as Windows/Android
└─────────┬────────────┘
          │ shadowsocks tunnel + prefix obfuscation
          ▼
┌──────────────────────┐
│  Outline Server      │
└──────────────────────┘
```

## Requirements

| Package                | Fedora                  | Purpose                          |
|------------------------|-------------------------|----------------------------------|
| Go                     | `golang`                | Build outline-go-proxy           |
| python3                | `python3` (base)        | CLI script runtime               |
| KDE Plasma 6           | `plasma-workspace`      | Plasmoid host                    |
| kwriteconfig6 / kded6  | `kf6-kded`              | KDE proxy configuration          |
| Firefox or Vivaldi     | `firefox` / `vivaldi`   | Browser (prefs auto-configured)  |

## Install

```bash
# 1. Clone
git clone https://github.com/arkhivar/outline-plasmoid.git
cd outline-plasmoid

# 2. Build the Go proxy (needs internet for Go dependencies)
cd go-proxy
go build -o outline-go-proxy .
cp outline-go-proxy ~/.local/bin/
cd ..

# 3. Install CLI scripts + plasmoid
./install.sh

# 4. Restart Plasma
killall plasmashell && kstart6 plasmashell
```

Then add the **Outline SS** widget to your panel (right-click panel →
Add Widgets → search "Outline").

### Automatic install

Point any AI coding agent (Goose, Claude Code, etc.) at this repo:

> Install outline-plasmoid from https://github.com/arkhivar/outline-plasmoid on my machine

The `AGENTS.md` file contains all the rules and gotchas.

## Usage

### From the panel

Click the icon → connects. Click again → disconnects.
Right-click → Configure → paste your Outline key (starts with `ssconf://`).

### From the terminal

```bash
# Connect
outline-ss connect 'ssconf://your-server:443/access-key'

# Check status
outline-ss status

# Disconnect
outline-ss disconnect

# Emergency: purge ALL proxy residues if internet breaks
outline-ss recover
```

## Safety

| Layer | Mechanism | Trigger |
|-------|-----------|---------|
| **1. Disconnect cleanup** | `outline-ss disconnect` stops proxy, clears KDE + Firefox proxy | Every disconnect |
| **2. PID-file tracking** | `$XDG_RUNTIME_DIR/outline-ss/` | Crash recovery |
| **3. Emergency recovery** | `outline-ss recover` | Manual — if browsers break |

**If your browsers break:**
```bash
outline-ss recover
```

## Backend preference

`outline-ss` auto-detects the backend in this order:
1. `~/.local/bin/outline-go-proxy` — Go Outline SDK (preferred)
2. `~/.local/bin/outline-local` — Official Outline local client
3. `~/.local/bin/sslocal` — shadowsocks-rust (fallback)

Set `OUTLINE_SS_BACKEND` env var to override.

## Platform

Built for **Fedora Asahi Linux** (ARM64, KDE Plasma 6), but works on any
Linux distro with Plasma 6 and Go.

## License

MIT — see [LICENSE](LICENSE).
