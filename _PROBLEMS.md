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

## 7. Browser still fails for heavy sites (YouTube, Instagram) — IN PROGRESS

**Symptom**: Pool proxy (1081) works perfectly with `curl` — all requests
succeed with proper rate-limiting.  But when Firefox connects through the pool,
Russian sites work while YouTube/Instagram time out.

**Hypothesis** (untested): Browsers open connections to 6–12 different hosts
simultaneously (youtube.com, googlevideo.com, googleapis.com, …).  The pool
has only 2 concurrent slots.  By the time the 3rd host gets a slot (11s later),
browser-side timeouts have already fired, and the page load is aborted.

**Possible fixes to try next**:
1. **Test per-host connection limit**: does the server count 2 connections per
   *target host* or 2 per *client IP total*?  If per-host, increase pool max_conn.
2. **HTTP/1.1 keep-alive**: ensure Firefox reuses SOCKS5 connections for
   multiple requests to the same host (should already work with HTTPS CONNECT).
3. **Increase pool burst**: try burst=4, cooldown=5s to see if server tolerates
   more connections.
4. **Alternative transport**: try `v2ray`/`xray` with mux.cool (connection
   multiplexing) which can send multiple streams over a single TCP connection.
5. **SSH `-D`**: if the Outline server supports SSH tunneling (unlikely), use
   SSH's SOCKS5 which multiplexes natively.

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
