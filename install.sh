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

# ── 1. Install CLI scripts ──────────────────────────────────────────────
echo "── Installing CLI scripts to $BIN_DIR"
mkdir -p "$BIN_DIR"

for script in outline-ss configure-firefox-proxy outline-ss-pool; do
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

echo "── Detecting backend"
BACKEND="${OUTLINE_SS_BACKEND:-}"
if [ -z "$BACKEND" ]; then
    for cand in \
        "$HOME/.local/lib/outline/outline-local" \
        "$HOME/.local/bin/outline-local" \
        /usr/local/libexec/outline-local \
        /usr/local/bin/outline-local \
        /usr/bin/outline-local \
        /opt/outline/resources/outline-local \
        /opt/Outline/outline-local \
        /usr/local/bin/sslocal
    do
        if [ -x "$cand" ]; then
            BACKEND="$cand"
            break
        fi
    done
fi
if [ -z "$BACKEND" ] && command -v outline-local >/dev/null 2>&1; then
    BACKEND="$(command -v outline-local)"
fi
if [ -z "$BACKEND" ] && command -v sslocal >/dev/null 2>&1; then
    BACKEND="$(command -v sslocal)"
fi
if [ -n "$BACKEND" ]; then
    printf 'OUTLINE_SS_BACKEND=%s\n' "$BACKEND" > "$OUTLINE_CONF_DIR/backend.env"
    chmod 600 "$OUTLINE_CONF_DIR/backend.env"
    echo "   ✓ backend: $BACKEND"
else
    echo "   ⚠ no backend detected; set OUTLINE_SS_BACKEND manually before first connect"
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
echo "    Backend override: export OUTLINE_SS_BACKEND=/path/to/outline-local"
echo "                      or set it in ~/.config/outline-ss/backend.env"
echo ""
