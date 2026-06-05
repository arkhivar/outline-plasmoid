#!/usr/bin/env bash
set -euo pipefail

# outline-plasmoid installer
# Run from the repo root: ./install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/org.kde.plasma.outline-ss"

echo "==> outline-plasmoid installer"
echo "    Target: $PLASMOID_DIR"
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
mkdir -p "$SYSTEMD_USER_DIR"
cp "$SCRIPT_DIR/systemd/outline-ss@.service" "$SYSTEMD_USER_DIR/outline-ss@.service"
systemctl --user daemon-reload
echo "   ✓ outline-ss@.service (daemon-reloaded)"

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
echo ""
