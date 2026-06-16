# AGENTS.md — outline-plasmoid

Project context for AI coding assistants.

## Project

A KDE Plasma 6 plasmoid + Python CLI for managing one-click Outline VPN /
Shadowsocks connections on Linux, using systemd user services for lifecycle.

**Stack**: QML (Plasma 6), Python 3, systemd, bash
**Target**: Fedora Asahi Linux ARM64 / KDE Plasma 6 (portable to any systemd+Plasma 6 distro)
**License**: MIT

## File layout

```
outline-plasmoid/
├── install.sh                  # bash installer — copies files, reloads plasma
├── uninstall.sh
├── README.md
├── AGENTS.md                   # This file
├── _PROBLEMS.md                # Diagnostic log: every hurdle + fix, session knowledge
├── plasmoid/                   # KDE Plasma widget
│   ├── metadata.json           # Plasma plugin metadata
│   └── contents/
│       ├── ui/
│       │   ├── main.qml        # Full representation: compact icon + expanded panel
│       │   └── config/
│       │       └── ConfigConnection.qml  # Right-click → Configure dialog
│       └── config/
│           ├── config.qml      # Config category loaded by plasma
│           └── main.xml        # Persistent config schema (ssconf_url, local_port)
├── cli/
│   ├── outline-ss              # Python CLI: connect/disconnect/status/cleanup/recover
│   ├── outline-ss-pool         # Connection-pooling SOCKS5 proxy (token-bucket rate limiter)
│   └── configure-firefox-proxy # Python: sets/clears Firefox SOCKS5 on ALL profiles
└── systemd/
│   └── outline-ss@.service     # systemd user unit (ExecStopPost → outline-ss cleanup)
```

## Key rules

1. **No secrets in the repo.** The Shadowsocks config files (`*.conf`) contain
   passwords and are `.gitignore`'d. Never commit or hardcode credentials.

2. **Hardcoded paths are forbidden.** The CLI uses `shutil.which()` or standard
   paths (`~/.config/`, `XDG_RUNTIME_DIR`). No absolute `/home/ds/...` paths.

3. **Plasmoid communicates via CLI only.** The QML never shells out to systemd
   directly — it calls `outline-ss connect/disconnect/status` via
   `PlasmaCore.DataSource` with `engine: "executable"`.

4. **PID files are the source of truth for connection state.** The plasmoid
   polls `outline-ss status` which checks PID files in `XDG_RUNTIME_DIR`.

5. **Fedora/ARM64 first.** Paths, package names, and assumptions should
   target Fedora Linux on aarch64. Add guards for other distros if needed.

## QML architecture

- `main.qml` has two representations:
  - **Compact (panel icon)**: just the icon button with status indicator
  - **Full (expanded)**: icon + action buttons + connection stats
- Uses `PlasmaCore.DataSource` with `engine: "executable"` to run
  `outline-ss status --profile <profile>`
- Polls every 2 seconds when connecting, every 5 seconds when stable
- Status states: `disconnected`, `connecting`, `connected`, `error`

## CLI architecture

`outline-ss` is a single-file Python 3 script (zero dependencies beyond stdlib):

- `connect` → resolve `ssconf://` URL over HTTPS, parse JSON config,
  write config to `~/.config/outline-ss/outline-ss@<profile>.conf` with `0600`,
  start `sslocal` directly (PID-file managed, no systemd),
  start `outline-ss-pool` on port 1081 (token-bucket rate limiter),
  configure KDE + Firefox to use 127.0.0.1:1081
- `disconnect` → stop pool, stop sslocal, clear KDE + Firefox proxy via `configure-firefox-proxy`
- `recover` → emergency: stop pool+sslocal, purge ALL proxy residues (KDE, Firefox)
- `status` → JSON output: `{"status": "connected", "server": "...", "pool_running": true, ...}`

`outline-ss-pool` is a separate Python 3 script (also zero deps beyond stdlib):

- SOCKS5 proxy listening on 127.0.0.1:1081, forwarding to sslocal on 127.0.0.1:1080
- Token-bucket rate limiting (burst=2, refill=1/11s) + semaphore (max 2 concurrent upstream connections)
- Prevents the browser from overwhelming the Outline server's 2-connection TCP limit
- See `_PROBLEMS.md` §6–7 for rationale and limitations


## Build / deploy

No build step. The plasmoid is interpreted QML. Installation is file copies:

```bash
./install.sh
```

The installer:
1. Copies CLI scripts to `~/.local/bin/`
2. Installs systemd user unit to `~/.config/systemd/user/` and runs `daemon-reload`
3. Copies plasmoid to `~/.local/share/plasma/plasmoids/<id>/`
4. Optionally restarts plasmashell (`plasmashell --replace &` or `kquitapp6 plasmashell`)

## Testing

Manual testing workflow:
1. `install.sh` on a test machine
2. Add the widget to a panel
3. Right-click → Configure → paste a real `ssconf://` URL
4. Click to connect, verify `ss -tlnp | grep 1080` shows SOCKS5 listener
5. Click to disconnect, verify port is freed
6. Test `outline-ss status` from terminal

**Recovery / safety flow:**
7. Connect, then `pkill -9 sslocal` (simulate crash)
8. Verify browsers break (they will — proxy settings point to dead port)
9. Run `outline-ss recover`
10. If still broken: `systemctl --user restart xdg-desktop-portal.service`
11. Verify browsers work again

**Proxy configurator:**
12. `configure-firefox-proxy status` — should list all Firefox profiles
13. `configure-firefox-proxy` — sets SOCKS5 on all profiles via prefs.js
14. `configure-firefox-proxy clear` — disables proxy on all profiles

## Common issues

- **sslocal not found**: install shadowsocks-rust (`cargo install shadowsocks-rust` or COPR)
- **Plasmoid doesn't load**: check `journalctl --user -f -u plasma-plasmashell` for QML errors
- **systemd unit fails**: `systemctl --user status outline-ss@default.service`
- **Firefox proxy not applying**: Firefox must be restarted if it was running
  when the proxy was configured. The script sets proxy in `prefs.js` directly
  (after nuking any stale `user.js` override files).
- **KDE proxy not taking effect**: `kded6` sometimes needs `kquitapp5 kded5 && kded6 &`
