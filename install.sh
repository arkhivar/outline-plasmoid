#!/usr/bin/env bash
set -euo pipefail

# outline-plasmoid installer (system-wide)
# Run from the repo root: sudo ./install.sh
# Installs to /usr/local/bin, /usr/share/plasma, /usr/lib/systemd/user, /etc/outline-ss

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SYSTEMD_USER_DIR="/usr/lib/systemd/user"
PLASMOID_DIR="/usr/share/plasma/plasmoids/org.kde.plasma.outline-ss"
OUTLINE_CONF_DIR="/etc/outline-ss"

# ── Root check ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "==> This installer installs system-wide and needs root."
    echo "    Re-run as: sudo $0"
    exit 1
fi

# Detect the real user (for plasma restart, KDE config, etc.)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_UID=$(id -u "$REAL_USER")

echo "==> outline-plasmoid installer (system-wide)"
echo "    Target:  $PLASMOID_DIR"
echo "    User:    $REAL_USER ($REAL_HOME)"
echo ""

# ── 0. Safety pre-flight ───────────────────────────────────────────────
# Check for stale Outline/Shadowsocks artifacts that can break the system.
# See _SAFETY.md for details.
WARNINGS=0

if nft list tables 2>/dev/null | grep -qi outline; then
    echo "⚠ WARNING: Stale nftables 'outline' table — can redirect ALL TCP"
    echo "  Fix: nft delete table inet outline"
    WARNINGS=$((WARNINGS + 1))
fi

for svc in outline-nftables outline-ss shadowsocks-libev; do
    if systemctl list-units --all 2>/dev/null | grep -qi "$svc"; then
        echo "⚠ WARNING: Stale service '$svc' found"
        echo "  Fix: systemctl disable --now $svc && rm /etc/systemd/system/$svc.service"
        WARNINGS=$((WARNINGS + 1))
    fi
done

for f in /etc/systemd/system/outline-nftables.service /etc/systemd/system/outline-ss.service /etc/nftables-outline.conf; do
    if [ -f "$f" ]; then
        echo "⚠ WARNING: Stale file: $f"
        WARNINGS=$((WARNINGS + 1))
    fi
done

[ "$WARNINGS" -gt 0 ] && echo "(Read _SAFETY.md — continuing anyway)"
echo ""

# ── 1. Install CLI scripts ──────────────────────────────────────────────
echo "── Installing CLI scripts to $BIN_DIR"
mkdir -p "$BIN_DIR"

for script in outline-ss configure-firefox-proxy outline-ss-pool outline-ss-runner; do
    if [ -f "$SCRIPT_DIR/cli/$script" ]; then
        cp "$SCRIPT_DIR/cli/$script" "$BIN_DIR/$script"
        chmod +x "$BIN_DIR/$script"
        echo "   ✓ $script"
    fi
done

# ── 2. Build & install outline-go-proxy ─────────────────────────────────
echo ""
echo "── Building outline-go-proxy"
if [ -d "$SCRIPT_DIR/go-proxy" ]; then
    if command -v go >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR/go-proxy" && CGO_ENABLED=0 go build -o "$BIN_DIR/outline-go-proxy" . 2>&1)
        chmod +x "$BIN_DIR/outline-go-proxy"
        echo "   ✓ outline-go-proxy built and installed"
    elif [ -x "$BIN_DIR/outline-go-proxy" ]; then
        echo "   ✓ outline-go-proxy already installed (Go not found, skipping build)"
    else
        echo "   ⚠ Go not found and outline-go-proxy not installed"
        echo "     Install Go (golang-go) then re-run, or build manually:"
        echo "     cd go-proxy && CGO_ENABLED=0 go build -o $BIN_DIR/outline-go-proxy ."
    fi
else
    echo "   ⚠ go-proxy/ directory not found — skipping backend build"
fi

# ── 3. Install systemd user unit ────────────────────────────────────────
echo ""
echo "── Installing systemd user unit"
mkdir -p "$SYSTEMD_USER_DIR" "$OUTLINE_CONF_DIR"
cp "$SCRIPT_DIR/systemd/outline-ss@.service" "$SYSTEMD_USER_DIR/outline-ss@.service"
systemctl daemon-reload
echo "   ✓ outline-ss@.service"

# ── 4. Write backend config ─────────────────────────────────────────────
echo ""
echo "── Writing system-wide backend config"
if [ -x "$BIN_DIR/outline-go-proxy" ]; then
    echo "OUTLINE_SS_BACKEND=$BIN_DIR/outline-go-proxy" > "$OUTLINE_CONF_DIR/backend.env"
    echo "   ✓ $OUTLINE_CONF_DIR/backend.env → $BIN_DIR/outline-go-proxy"
else
    echo "   ⚠ outline-go-proxy not installed — backend.env not written"
fi

# ── 5. Clean up stale proxy state ───────────────────────────────────────
echo ""
echo "── Cleaning up stale proxy state..."

# Firefox proxy
if [ -x "$BIN_DIR/configure-firefox-proxy" ]; then
    sudo -u "$REAL_USER" "$BIN_DIR/configure-firefox-proxy" clear 2>/dev/null || true
fi

# Nuke any stray user.js files Outline may have left behind
for userjs in "$REAL_HOME/.config/mozilla/firefox"/*/user.js "$REAL_HOME/.mozilla/firefox"/*/user.js; do
    if [ -f "$userjs" ]; then
        grep -q "Auto-configured by Outline" "$userjs" 2>/dev/null && rm -f "$userjs"
    fi
done 2>/dev/null || true

# Reset KDE proxy to direct
if command -v kwriteconfig6 >/dev/null 2>&1; then
    sudo -u "$REAL_USER" kwriteconfig6 --file kioslaverc --group "Proxy Settings" --key ProxyType --type int 0 2>/dev/null || true
fi
echo "   ✓ stale state cleaned"

# ── 6. Install plasmoid ─────────────────────────────────────────────────
echo ""
echo "── Installing plasmoid"

if [ -d "$PLASMOID_DIR" ]; then
    rm -rf "$PLASMOID_DIR"
fi
mkdir -p "$PLASMOID_DIR"
cp -r "$SCRIPT_DIR/plasmoid/"* "$PLASMOID_DIR/"
echo "   ✓ $PLASMOID_DIR"

# ── 7. Restart Plasma shell (for the real user) ─────────────────────────
echo ""
echo "── Restarting Plasma shell..."

if command -v plasmashell >/dev/null 2>&1; then
    if pgrep -u "$REAL_UID" plasmashell >/dev/null 2>&1; then
        sudo -u "$REAL_USER" DISPLAY="${DISPLAY:-:0}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
            kquitapp6 plasmashell 2>/dev/null || true
        sleep 1
        sudo -u "$REAL_USER" DISPLAY="${DISPLAY:-:0}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
            plasmashell --replace &>/dev/null &
        echo "   ✓ plasmashell restarted"
    else
        echo "   ⚠ plasmashell not running (will appear after next login)"
    fi
else
    echo "   ⚠ plasmashell not found (not on Plasma?)"
fi

# ── Done ─────────────────────────────────────────────────────────────────
echo ""
echo "==> Done! System-wide install complete."
echo ""
echo "    Any user can now:"
echo "      1. Right-click panel → Add Widgets → search 'Outline'"
echo "      2. Right-click widget → Configure → paste your ssconf:// URL"
echo ""
echo "    CLI usage:"
echo "      outline-ss connect 'ssconf://...'"
echo "      outline-ss status"
echo "      outline-ss disconnect"
echo "      outline-ss recover    # emergency cleanup"
echo ""
echo "    Backend: $(cat "$OUTLINE_CONF_DIR/backend.env" 2>/dev/null || echo 'NOT SET')"
echo ""
