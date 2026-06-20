#!/usr/bin/env bash
set -euo pipefail

# outline-plasmoid installer
# Run from the repo root: ./install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.outline-ss"
OUTLINE_CONF_DIR="$HOME/.config/outline-ss"

echo "==> outline-plasmoid installer"
echo "    Target: $PLASMOID_DIR"
echo ""

# ── 0. Safety pre-flight ───────────────────────────────────────────────
# Check for stale Outline/Shadowsocks artifacts that can break the system.
# See _SAFETY.md for details.
WARNINGS=0

if sudo -n nft list tables 2>/dev/null | grep -qi outline; then
    echo "⚠ WARNING: Stale nftables 'outline' table — can redirect ALL TCP"
    echo "  Fix: sudo nft delete table inet outline"
    WARNINGS=$((WARNINGS + 1))
fi

for svc in outline-nftables outline-ss shadowsocks-libev; do
    if systemctl list-units --all 2>/dev/null | grep -qi "$svc"; then
        echo "⚠ WARNING: Stale service '$svc' found"
        echo "  Fix: systemctl --user disable --now $svc"
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

for script in outline-ss configure-firefox-proxy; do
    cp "$SCRIPT_DIR/cli/$script" "$BIN_DIR/$script"
    chmod +x "$BIN_DIR/$script"
    echo "   ✓ $script"
done

# Ensure ~/.local/bin in PATH for this session
export PATH="$BIN_DIR:$PATH"

# ── 2. Install systemd user unit ────────────────────────────────────────
echo ""
echo "── Installing systemd user unit"
mkdir -p "$SYSTEMD_USER_DIR" "$OUTLINE_CONF_DIR"
cp "$SCRIPT_DIR/systemd/outline-ss@.service" "$SYSTEMD_USER_DIR/outline-ss@.service"
systemctl --user daemon-reload
echo "   ✓ outline-ss@.service (daemon-reloaded)"

echo "── Checking outline-go-proxy"
BACKEND="${OUTLINE_SS_BACKEND:-$HOME/.local/bin/outline-go-proxy}"
if [ -x "$BACKEND" ]; then
    echo "   ✓ $BACKEND"
elif command -v outline-go-proxy >/dev/null 2>&1; then
    BACKEND="$(command -v outline-go-proxy)"
    echo "   ✓ $BACKEND"
else
    echo "   ⚠ outline-go-proxy not found — run: cd go-proxy && go build -o outline-go-proxy . && cp outline-go-proxy ~/.local/bin/"
fi

# ── 2.5. Clean up stale proxy state from previous broken sessions ────────
echo ""
echo "── Cleaning up stale proxy state..."
"$BIN_DIR/configure-firefox-proxy" clear 2>/dev/null || true

# Nuke any stray user.js files Outline may have left behind
for userjs in "$HOME/.config/mozilla/firefox"/*/user.js "$HOME/.mozilla/firefox"/*/user.js; do
    if [ -f "$userjs" ]; then
        grep -q "Auto-configured by Outline" "$userjs" 2>/dev/null && rm -f "$userjs"
    fi
done 2>/dev/null || true

# Reset KDE proxy to direct if it got stuck
if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kioslaverc --group "Proxy Settings" --key ProxyType --type int 0 2>/dev/null || true
elif command -v kwriteconfig5 >/dev/null 2>&1; then
    kwriteconfig5 --file kioslaverc --group "Proxy Settings" --key ProxyType --type int 0 2>/dev/null || true
elif [ -f "$HOME/.config/kioslaverc" ]; then
    sed -i 's/ProxyType=.*/ProxyType=0/' "$HOME/.config/kioslaverc" 2>/dev/null || true
    sed -i '/socks5/d' "$HOME/.config/kioslaverc" 2>/dev/null || true
fi
echo "   ✓ stale state cleaned"

# ── 3. Install plasmoid ─────────────────────────────────────────────────
echo ""
echo "── Installing plasmoid"

if [ -d "$PLASMOID_DIR" ]; then
    rm -rf "$PLASMOID_DIR"
fi
mkdir -p "$PLASMOID_DIR"
cp -r "$SCRIPT_DIR/plasmoid/"* "$PLASMOID_DIR/"
echo "   ✓ $PLASMOID_DIR"

# ── 4. Restart Plasma shell ─────────────────────────────────────────────
echo ""
echo "── Restarting Plasma shell..."

if command -v plasmashell &>/dev/null; then
    # Check if plasmashell is running
    if pgrep -u "$USER" plasmashell >/dev/null 2>&1; then
        kquitapp6 plasmashell 2>/dev/null || killall plasmashell 2>/dev/null || true
        sleep 1
        plasmashell --replace &>/dev/null &
        echo "   ✓ plasmashell restarted"
    else
        echo "   ⚠ plasmashell not running (not on Plasma? skip)"
    fi
else
    echo "   ⚠ plasmashell not found (not on Plasma?)"
fi

# ── Done ─────────────────────────────────────────────────────────────────
echo ""
echo "==> Done!"
echo ""
echo "    Add the widget: right-click panel → Add Widgets → search 'Outline'"
echo "    Then right-click the widget → Configure → paste your ssconf:// URL"
echo "    Backend override: export OUTLINE_SS_BACKEND=~/.local/bin/outline-go-proxy"
echo "                      or set it in ~/.config/outline-ss/backend.env"
echo ""
