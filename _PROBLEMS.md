# _PROBLEMS.md — Outline Plasmoid Troubleshooting Chronicle

> Every major hurdle encountered, root cause identified, and what we tried.
> Updated 2026-06-09. Treat this as a living diagnostic log.

---

## 1. YouTube unreachable, Russian sites work intermittently

**Symptom**: Outline widget connects, Russian sites load (but slowly), YouTube and
Instagram time out completely. Same Outline key works perfectly on Windows and Android.

**Root cause**: The Outline server enforces a **2-concurrent-TCP-connection limit**
per client IP address, counting ALL states (ESTABLISHED + CLOSE-WAIT + FIN-WAIT-1
+ TIME-WAIT). Modern browsers open 6–8 parallel connections per host — only 2
succeed, the rest are silently dropped by the server (no RST, no ACK — just
silence). YouTube needs many parallel connections (video, thumbnails, APIs), so
it never fully loads.

**Diagnostic**: `curl -x socks5h://127.0.0.1:1080 https://www.youtube.com` → HTTP
200 on a fresh sslocal start. After 2 requests: connection #3 times out.  On the
wire: FIN-WAIT-1 connections with non-zero Send-Q → server stopped ACKing our
packets.

**Solution**: Connection-pooling SOCKS5 proxy (`cli/outline-ss-pool`) — token
bucket (burst=2, rate=1 per 11s → matches server FIN-WAIT-1 expiry).  Browsers
→ pool (1081) → sslocal (1080) → server.

**Status**: ✅ Pool works with curl (all requests succeed).  ⚠️ Browser still
fails for heavy sites — likely because browsers open connections to *multiple
hosts* (youtube.com, googlevideo.com, googleapis.com, …) and 2 slots can't
satisfy them all.  See #7 for next investigation.

---

## 2. Prefix obfuscation: TLS ClientHello bytes corrupted

**Symptom**: Outline API returns a `prefix` field (the TLS ClientHello bytes
`16 03 01 00 c2 a8 01 01`).  sslocal prepends these bytes to every connection
for DPI evasion.  After deploy, ALL connections fail silently.

**Root cause**: Python's `json.dumps` serialises Unicode codepoints as `\uXXXX`
escapes.  sslocal (Rust) interprets these as UTF-8 strings and re-encodes them.
A codepoint like `\u00c2` (byte `0xC2`) becomes the 2-byte UTF-8 sequence
`0xC3 0x82`.  The server receives garbage prefix bytes and drops the connection.

**Fix**: `_generate_backend_config()` converts the prefix Unicode string to raw
bytes via `bytes(ord(c) for c in prefix)`, then base64-encodes it.  sslocal
expects base64-encoded prefix in the config JSON.

**Key code** (`cli/outline-ss`, `_generate_backend_config`):
```python
raw_prefix = bytes(ord(c) for c in prefix)
config["prefix"] = base64.b64encode(raw_prefix).decode()
```

**Verified**: `FgMBAMKoAQE=` decodes to `16 03 01 00 c2 a8 01 01` — correct.

---

## 3. Firefox `proxy_over_tls` set to `true` by mistake

**Symptom**: Firefox can't connect through proxy after prefix fix.

**Root cause**: Firefox pref `network.proxy.proxy_over_tls` was set to `true`,
but sslocal provides **plain SOCKS5** (no TLS wrapper).

**Fix**: Changed to `false` in `cli/configure-firefox-proxy`.

---

## 4. Firefox DNS leak — missing `socks_remote_dns`

**Symptom**: DNS queries resolved locally, bypassing the tunnel.  Russian ISPs
can block YouTube DNS.

**Fix**: Added `network.proxy.socks_remote_dns = true` in
`cli/configure-firefox-proxy`.  All DNS now goes through the SOCKS5 tunnel.

---

## 5. `qdbus` not found on Fedora KDE 6

**Symptom**: `FileNotFoundError: qdbus`.

**Root cause**: Fedora ships Qt6 tools as `qdbus-qt6`, not `qdbus`.

**Fix**: `cli/outline-ss` uses `shutil.which("qdbus-qt6") or "qdbus"`.

---

## 6. systemd ExecStart unreliable → direct process management

**Symptom**: `systemctl --user start outline-ss@default` sometimes starts,
sometimes doesn't.  `/bin/sh -c` wrapper + systemd environment caused
intermittent failures.

**Fix**: Removed `ExecStart` from systemd unit.  `cmd_connect()` now launches
sslocal as a direct subprocess with `start_new_session=True` and manages it via
PID file (`/run/user/$UID/outline-ss/pid-default`).  systemd unit kept for
`ExecStopPost` cleanup on logout/reboot.

---

## 7. Browser still fails for heavy sites (YouTube, Instagram) — KNOWN LIMITATION

**Symptom**: Pool proxy (1081) works perfectly with `curl` — all requests
succeed with proper rate-limiting.  But when Firefox connects through the pool,
Russian sites work while YouTube/Instagram time out.

**Root cause confirmed**: Browsers open connections to 6–12 different hosts
simultaneously (youtube.com, googlevideo.com, googleapis.com, …).  The pool
has only 2 concurrent slots with 11s token refill.  By the time the 3rd host
gets a slot, browser-side timeouts have already fired, and the page load is
aborted.  Firefox connection-limiting prefs (`max-connections-per-server=2`,
`max-persistent-connections-per-proxy=4`) help but can't overcome the
fundamental 2-slot bottleneck.

**Short-term mitigations tested**:
- Firefox `max-connections-per-server=2`, `max-persistent-connections-per-proxy=4` — partial improvement, not sufficient
- Token bucket tuning (burst=4, cooldown=2s) — might work for lighter sites, still fragile

**Proper fix → see #10 below**.

---

## 8. sslocal `--timeout` / `--tcp-keep-alive` flags incompatible with `-c` config mode

**Symptom**: `sslocal -c config.json --timeout 60` prints usage error:
"the following required arguments were not provided: --encrypt-method, --server-addr".

**Root cause**: sslocal 1.24.0's argument parser treats `--timeout` and similar
CLI flags as triggers for a "manual" mode that requires all server parameters
explicitly.  When `-c` (config) is used, these flags are incompatible.

**Fix**: Set `"timeout": 60` in the JSON config instead.  sslocal reads it from
the config file.  Removed all `--timeout` / `--tcp-keep-alive` / `--nofile` /
`--tcp-no-delay` flags from `_start_backend()` and the runner script.

---

## 9. Excessive testing triggered IP rate-limiting

**Symptom**: After many curl tests in quick succession, the server stops
responding entirely — even fresh sslocal starts fail.

**Root cause**: We opened ~96 connections during testing.  The server silently
dropped them all (no RST), leaving 96 FIN-WAIT-1 orphans on the client.  The
kernel's `tcp_fin_timeout=60` + `tcp_orphan_retries=0` kept them alive for
60 seconds.  Meanwhile the server rate-limited our IP.

**Recovery**: Wait 120 seconds for all FIN-WAIT-1 to expire + server cooldown.
Then fresh sslocal works again.

---

## Architecture notes

```
  Firefox / Vivaldi
        │
        ▼
  outline-ss-pool  (127.0.0.1:1081)    ← token bucket: burst=2, rate=1/11s
        │
        ▼
  sslocal          (127.0.0.1:1080)    ← Shadowsocks + prefix obfuscation
        │
        ▼
  Outline server   (194.247.182.162:24631)  ← 2 conn/IP limit
```

### File locations (deployed)
| File | Purpose |
|------|---------|
| `~/.local/bin/outline-ss` | Main CLI (connect/disconnect/status) |
| `~/.local/bin/outline-ss-pool` | Connection-pooling SOCKS5 proxy |
| `~/.local/bin/configure-firefox-proxy` | Firefox proxy prefs manager |
| `~/.config/outline-ss/outline-ss@default.json` | Generated sslocal config |
| `~/.config/outline-ss/outline-ss@default.log` | Backend + pool logs |
| `~/.config/outline-ss/backend.env` | `OUTLINE_SS_BACKEND` path |
| `/run/user/$UID/outline-ss/pid-default` | sslocal PID |
| `/run/user/$UID/outline-ss/pool-pid-default` | pool PID |

### Quick diagnostics
```bash
# Check everything
outline-ss status

# Test through pool
curl -x socks5h://127.0.0.1:1081 -s -o /dev/null -w "%{http_code}\n" \
  --connect-timeout 10 --max-time 15 https://www.youtube.com

# See pool log
tail -20 ~/.config/outline-ss/outline-ss@default.log

# Connection state to server
ss -tnp | grep sslocal | grep 194.247 | awk '{print $1}' | sort | uniq -c

# Emergency recovery
outline-ss disconnect
pkill -9 sslocal outline-ss-pool
```

---

## 10. v2ray/Xray with mux.cool — REJECTED

**Why**: The 2-connection server limit is fundamental — no amount of client-side
pool tuning can make modern web browsing comfortable when the browser needs to
connect to 6+ hosts simultaneously. We need **connection multiplexing**: all
traffic multiplexed over a single TCP connection to the server.

**Approach**: Replace `sslocal` with `v2ray` or `xray` configured with Shadowsocks
inbound and `mux.cool` multiplexing.  Xray is preferred (active fork, better
performance, actively maintained).

**Investigation results (2026-06-10)**:

### 10.1 Xray availability on Fedora ARM64
- ✅ **Available**: GitHub releases provide `linux-arm64` binaries
- ❌ **Not in Fedora repos**: No `dnf install xray` or COPR available
- Binary works fine: `/tmp/xray-test/xray version` → Xray 26.3.27 (go1.26.1 linux/arm64)

### 10.2 Xray prefix obfuscation support
- ❌ **NOT supported**: Xray/v2ray's Shadowsocks outbound has **no mechanism**
  for prepending raw prefix bytes to the initial TCP payload. The Outline server
  requires a specific ClientHello prefix (`0x16030100c2a80101`) to bypass DPI.
  - Xray supports "tcpSettings.header" with HTTP camouflage, but this changes
    the protocol entirely — the server expects raw Shadowsocks, not HTTP.
  - No equivalent to shadowsocks-rust's `prefix` field exists in Xray.

### 10.3 mux.cool with Outline Shadowsocks server
- ❌ **Does NOT work**: mux.cool requires **server-side support**.
  - When xray is configured with `"mux": {"enabled": true}` and a Shadowsocks
    outbound, it attempts to connect to `v1.mux.cool:9527` **through** the
    Shadowsocks tunnel.
  - The Outline server receives mux frames and tries to forward them to
    `v1.mux.cool:9527`, which fails because the server is a standard
    Shadowsocks relay, not a mux endpoint.
  - Log evidence: `proxy/shadowsocks: tunneling request to tcp:v1.mux.cool:9527`
  - **mux.cool is a client-server protocol** — both ends must speak it.

### 10.4 Alternative tools tested
| Tool | Multiplexing | Works with Outline? | Notes |
|------|-------------|---------------------|-------|
| **gost** | `mws` (multiplex WebSocket) | ❌ No | Adds WebSocket framing; server expects raw Shadowsocks |
| **glider** | `smux` (yamux) | ❌ No | Transport-layer only; requires server-side smux listener |
| **v2ray/xray** | `mux.cool` | ❌ No | Requires server-side mux endpoint |

### 10.5 Key finding: the 2-connection limit may be overstated
- Direct sslocal connections (no pool proxy) passed **10/10 parallel tests**
  to different hosts, suggesting the server's connection limit may be more
  lenient than initially observed, or the limit applies only under sustained
  load (not burst).
- The pool proxy's 11-second cooldown may be overly conservative.
- **Further investigation needed**: test direct sslocal with sustained load
  (10+ connections per second for 10+ seconds) to determine actual limits.

### 10.6 Conclusion
**The v2ray/Xray + mux.cool approach is fundamentally incompatible with
standard Outline Shadowsocks servers.** Connection multiplexing over a single
TCP connection requires **both client and server to support the multiplexing
protocol**. Since Outline servers only speak plain Shadowsocks, no client-side
mux solution can work.

**Next directions to explore**:
1. **Optimize the pool proxy**: Test if the 2-connection limit is real under
   sustained load; if not, reduce/remove the cooldown.
2. **HTTP/2 browser optimization**: Configure Firefox to aggressively reuse
   connections via HTTP/2, reducing the number of simultaneous TCP connections.
3. **Local caching proxy**: Add a caching layer (e.g., squid, privoxy) to
   reduce redundant connections to static resources.
4. **Connection coalescing**: Run a local HTTP proxy that coalesces multiple
   browser requests into fewer upstream connections.

**Priority**: Medium. The pool proxy remains the best available solution;
optimization and testing are the next steps.

---

## 11. `ss-local` / `shadowsocks-libev` destroys the host system — PHASED OUT

**Symptom**: After a previous installation of the standalone Outline CLI,
the host machine (KDE Neon 24.04, x86_64) experienced recurring total
internet loss.  `ss-local` kept respawning via `outline-ss.service`
(`Restart=always`), and `outline-nftables.service` recreated a kernel
`nftables` table that redirected **all TCP traffic** (ports 1–65535) to
a local proxy on port 12345.  When `ss-local` wasn't running, every
network request silently timed out.

**Root cause**: The standalone Outline CLI (a different tool from this
plasmoid) installed two persistent systemd services that survived its
removal:

| Service | Damage |
|---------|--------|
| `outline-nftables.service` | Creates `table inet outline` in nftables — redirects ALL TCP to port 12345, excluding only RFC-1918 ranges |
| `outline-ss.service` | Runs `ss-local` with `Restart=always` — respawns within milliseconds of being killed |

Neither service was stopped or disabled by the Outline CLI uninstaller.
They persisted across reboots and kept the nftables rules alive.

**The cascading disaster**: Attempting to remove `shadowsocks-libev`
(the package providing `ss-local`) via `apt-get remove shadowsocks-libev`
triggered a **massive partial system upgrade** on KDE Neon:

- Qt6 base: 6.8.2 → 6.11.1
- KDE Frameworks 6: 6.11.0 → 6.26.0
- Ubuntu base: 24.04.1 → 24.04.2
- **929 packages** upgraded in an uncontrolled chain

This left the system with incompatible library versions — `plasmashell`,
`krunner`, and `kwin_wayland` all failed with `symbol lookup error:
undefined symbol _ZN14QObjectPrivateC2Ei, version Qt_6_PRIVATE_API`.
The desktop was completely broken (login loop → black screen → SDDM
fallback).  Recovery required a full `apt-get dist-upgrade` + reinstall
of `kde-plasma-desktop` with three Neon-specific base packages
(`libeis1`, `liblcms2-2`, `libpoppler-qt6-3t64`) pinned to Neon versions.

**Why `ss-local` is the wrong backend for this project**:

1. **No TLS ClientHello prefix obfuscation support.**  The Outline server
   requires a specific prefix (`0x16030100c2a80101`) for DPI evasion.
   `ss-local` from `shadowsocks-libev` has no mechanism for this — it
   silently corrupts or drops the prefix bytes (see §2 for the encoding
   saga even when it was attempted via config).

2. **`shadowsocks-libev` is a system package** — removing or upgrading it
   via `apt` can cascade into unrelated system upgrades on rolling distros
   like KDE Neon.

3. **Stale systemd services from prior CLI installs** survive uninstall
   and hijack the entire network stack via `nftables`.

**Fix**: `ss-local` has been **phased out entirely**.  The widget now uses
**`outline-go-proxy`** — a Go-based SOCKS5 proxy built from the official
`outline-go-tun2socks` library, which handles Outline's TLS prefix
obfuscation natively.  No other backend is needed or recommended.

**Recovery steps for affected systems**:

```bash
# 1. Stop and permanently disable stale services
sudo systemctl stop outline-ss.service outline-nftables.service
sudo systemctl disable outline-ss.service outline-nftables.service
sudo rm /etc/systemd/system/outline-ss.service
sudo rm /etc/systemd/system/outline-nftables.service
sudo rm /etc/nftables-outline.conf
sudo systemctl daemon-reload

# 2. Delete the nftables table
sudo nft delete table inet outline

# 3. Kill any lingering ss-local
sudo killall ss-local 2>/dev/null

# 4. Set the correct backend
echo 'OUTLINE_SS_BACKEND=/usr/local/bin/outline-go-proxy' | \
  sudo tee /etc/outline-ss/backend.env
```

> ⚠️ **Do NOT** `apt-get remove shadowsocks-libev` without first running
> `sudo apt-get dist-upgrade` to stabilise the system.  See `_SAFETY.md`
> §1 for the full warning.

**Status**: ✅ `outline-go-proxy` deployed system-wide at
`/usr/local/bin/outline-go-proxy`.  `ss-local` is no longer referenced
anywhere in the project.  All stale systemd services removed.
