# ⚠️ SAFETY NOTICE — Read Before Installing

This widget is safe, but the **system you install it on** may have latent
issues from previous tools.  The following precautions will save you hours of
recovery time.

---

## 1. 🔴 NEVER blindly run `apt-get remove shadowsocks-libev`

`shadowsocks-libev` is listed as a fallback backend, but **removing it with
`apt-get` can trigger a massive partial system upgrade** on KDE Neon (and
similar rolling distros).  In one real-world case, `apt-get remove
shadowsocks-libev` cascaded into:

- Qt6        6.8.2  → 6.11.1
- KDE Frameworks 6.11.0 → 6.26.0
- Ubuntu base 24.04.1 → 24.04.2
- **929 packages** upgraded in an uncontrolled chain

The result: a broken KDE desktop (login loop, black screen, corrupted SDDM).

**If you want to remove `shadowsocks-libev`**, do it **separately**, on a
**fully updated** system, and be prepared for a large upgrade:

```bash
sudo apt-get update
sudo apt-get dist-upgrade     # ← do this FIRST
sudo apt-get remove shadowsocks-libev   # ← then this
```

---

## 2. 🧹 Check for old Outline / Shadowsocks systemd services

Previous Outline CLI installations may have left behind **persistent systemd
services** that corrupt your firewall and network:

| Service | What it does | Risk |
|---------|-------------|------|
| `outline-nftables.service` | Creates `nftables` rule that **redirects ALL TCP to a local proxy** | 🔴 Breaks all internet |
| `outline-ss.service` | Runs `ss-local` with `Restart=always` | 🟡 Keeps old backend alive |
| `shadowsocks-libev.service` | Runs `ss-server` on boot | 🟡 Unnecessary |

**Before installing this widget, check for stale services:**

```bash
systemctl list-units --all | grep -iE "outline|shadow"
ls /etc/systemd/system/*outline* /etc/systemd/system/*shadow*
```

If you find them, **disable and remove them permanently:**

```bash
sudo systemctl stop outline-nftables.service outline-ss.service
sudo systemctl disable outline-nftables.service outline-ss.service
sudo rm /etc/systemd/system/outline-nftables.service
sudo rm /etc/systemd/system/outline-ss.service
sudo systemctl daemon-reload
```

---

## 3. 🔥 Check for leftover nftables rules

Old Outline installations can leave a **kernel-level firewall table** that
redirects all your TCP traffic into oblivion:

```bash
sudo nft list tables
```

If you see `table inet outline`, **delete it immediately:**

```bash
sudo nft delete table inet outline
```

Also check for and remove stale config files:

```bash
sudo rm -f /etc/nftables-outline.conf
```

---

## 4. 🪦 Kill stale `ss-local` processes

```bash
pgrep -a ss-local
# If anything shows up:
sudo killall ss-local
```

---

## 5. ✅ The recommended install workflow

```bash
# 1. Make sure the system is fully updated and consistent
sudo apt-get update
sudo apt-get dist-upgrade -y
sudo apt-get --fix-broken install -y

# 2. Remove stale Outline artifacts (see sections 2–4 above)

# 3. Clone and install this widget
git clone https://github.com/arkhivar/outline-plasmoid
cd outline-plasmoid
chmod +x install.sh
./install.sh
```

---

## 6. 🆘 Emergency recovery

If you lose KDE Plasma (login loop / black screen / broken SDDM), the
quickest recovery is:

```bash
# Switch to a TTY with Ctrl+Alt+F3 and log in, then:

sudo apt-get update
sudo apt-get dist-upgrade -y
sudo apt-get install -y kde-plasma-desktop
sudo systemctl restart sddm
```

---

## 7. 🔧 This widget uses `outline-go-proxy`, not `ss-local`

The installed backend is **`outline-go-proxy`** (a Go-based SOCKS5 proxy
that handles Outline's TLS ClientHello prefix obfuscation natively).
`ss-local` is listed only as an **absolute last-resort fallback** —
you should never need it.

---

*Last updated: 2026-06-16 — lessons learned from a real recovery session.*
