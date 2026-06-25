#!/bin/bash
# ============================================================
# Lori — installer
# macOS 13+, arm64 / x86_64, Python 3.11–3.13
# ============================================================
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*"; exit 1; }
step() { echo -e "\n${YELLOW}▶${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Python ────────────────────────────────────────────────
step "Looking for Python 3..."

PYTHON_BIN=""
PYTHON_APP=""

for ver in 3.13 3.12 3.11; do
    candidate="/Library/Frameworks/Python.framework/Versions/$ver/bin/python3"
    app_candidate="/Library/Frameworks/Python.framework/Versions/$ver/Resources/Python.app/Contents/MacOS/Python"
    if [ -x "$candidate" ]; then
        PYTHON_BIN="$candidate"
        PYTHON_APP="$app_candidate"
        ok "Python $ver: $PYTHON_BIN"
        break
    fi
done

# Homebrew Python won't work: TCC binds to Python.app bundle ID,
# which Homebrew Python doesn't have — microphone access will fail.
if [ -z "$PYTHON_BIN" ]; then
    for hb_py in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$hb_py" ]; then
            err "Only Homebrew Python found ($hb_py) — microphone access won't work (no bundle ID for TCC).
   Install Python from python.org/downloads/ (version 3.11–3.13) and run install.sh again."
        fi
    done
fi

[ -z "$PYTHON_BIN" ] && err "Python 3 not found. Install from python.org/downloads/ and run install.sh again."

# ── 2. Install directory ──────────────────────────────────────
step "Where to install?"
DEFAULT_INSTALL="$HOME/.lori"
echo    "  Default: $DEFAULT_INSTALL"
echo -n "  Enter path (Enter = default): "
read INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL}"
mkdir -p "$INSTALL_DIR"
ok "Directory: $INSTALL_DIR"

# ── 3. Python dependencies ────────────────────────────────────
step "Installing Python dependencies..."
"$PYTHON_BIN" -m pip install --quiet --upgrade pip
"$PYTHON_BIN" -m pip install --quiet \
    sounddevice \
    numpy \
    pyobjc-framework-AVFoundation \
    pyobjc-framework-Cocoa \
    pyobjc-framework-Quartz \
    pyobjc-framework-UserNotifications \
    soundfile \
    mlx-whisper
ok "Dependencies installed."

# ── 4. mlx-whisper model ──────────────────────────────────────
step "mlx-whisper model..."
echo "   mlx-community/whisper-medium-mlx (~1.4 GB) will download automatically"
echo "   on first run and be cached in models/ (HF_HOME) — only once."
ok "Ready for first run."

# ── 5. Copy files ─────────────────────────────────────────────
step "Copying files to $INSTALL_DIR..."
cp "$SCRIPT_DIR/lori.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/toggle.sh"      "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/toggle.sh"

# config.json — copy only if it doesn't exist (don't overwrite user settings)
if [ ! -f "$INSTALL_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$INSTALL_DIR/"
    ok "config.json created (adjust as needed)."
else
    ok "config.json already exists — leaving it as is."
fi

ok "Files copied."

# ── 6. Build Lori.app ─────────────────────────────────────────
step "Building Lori.app..."

APP_DEST="$HOME/Applications/Lori.app"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$SCRIPT_DIR/Lori.app/Contents/Info.plist" "$APP_DEST/Contents/"
cp "$SCRIPT_DIR/assets/Lori.icns" "$APP_DEST/Contents/Resources/icon.icns"

# Substitute actual paths into launcher.c
LAUNCHER_TMP="/tmp/lori_launcher_$$.c"
sed \
    -e "s|PLACEHOLDER_PYTHON_BIN|${PYTHON_BIN}|g" \
    -e "s|PLACEHOLDER_SCRIPT_PATH|${INSTALL_DIR}/lori.py|g" \
    "$SCRIPT_DIR/launcher.c" > "$LAUNCHER_TMP"

clang -o "$APP_DEST/Contents/MacOS/Lori" "$LAUNCHER_TMP" \
    || err "Failed to compile launcher.c. Are Xcode Command Line Tools installed? (xcode-select --install)"
rm -f "$LAUNCHER_TMP"

# ad-hoc signature (required on arm64)
codesign --force --sign - "$APP_DEST/Contents/MacOS/Lori" 2>/dev/null \
    && ok "Binary signed (ad-hoc)." \
    || warn "codesign failed — try manually: codesign --force --sign - $APP_DEST/Contents/MacOS/Lori"

ok "Lori.app ready: $APP_DEST"

# ── 7. Request microphone permission ──────────────────────────
step "Opening Lori.app to register TCC permissions..."
echo "   macOS will ask for microphone access — click Allow."
open "$APP_DEST" || warn "Could not open Lori.app — open it manually."
sleep 3

# ── 8. launchd plist ─────────────────────────────────────────
step "Creating launchd agent..."

PLIST_DEST="$HOME/Library/LaunchAgents/com.ri.lori.agent.plist"

# Use Python.app if available (for correct TCC)
if [ -n "$PYTHON_APP" ] && [ -x "$PYTHON_APP" ]; then
    LAUNCHD_PYTHON="$PYTHON_APP"
else
    LAUNCHD_PYTHON="$PYTHON_BIN"
fi

cat > "$PLIST_DEST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ri.lori.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LAUNCHD_PYTHON}</string>
        <string>${INSTALL_DIR}/lori.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(dirname "$PYTHON_BIN"):/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

ok "plist created: $PLIST_DEST"

# ── 9. Load agent ─────────────────────────────────────────────
step "Loading launchd agent..."
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load   "$PLIST_DEST"
sleep 2

if launchctl list | grep -q "com.ri.lori.agent"; then
    ok "Agent running."
else
    warn "Agent not found in launchctl list — check logs: ~/Library/Logs/lori.log"
fi

# ── 10. Done ──────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo -e "${GREEN}✅ Lori installed!${NC}"
echo "══════════════════════════════════════════════════════"
echo ""
echo "One-time manual steps required:"
echo ""
echo "  1. macOS permissions (System Settings → Privacy & Security):"
echo "     • Accessibility  → add Python.app"
echo "       Path: $(find /Library/Frameworks/Python.framework -name "Python.app" -maxdepth 5 2>/dev/null | head -1)/Contents/MacOS/Python"
echo "     • Microphone     → Lori.app (should appear after step 7)"
echo "     • Notifications  → allow notifications for Python"
echo ""
echo "  2. Keyboard shortcut (macOS Shortcuts app):"
echo "     • Open Shortcuts.app"
echo "     • Create a new shortcut: add action 'Run Shell Script'"
echo "       Script: bash $INSTALL_DIR/toggle.sh"
echo "     • Assign a key (e.g. ⌥Space or Fn)"
echo ""
echo "  3. If notifications don't break through Do Not Disturb:"
echo "     System Settings → Focus → Sleep → Allowed Notifications → Apps → add Python"
echo ""
echo "Logs: tail -f ~/Library/Logs/lori.log"
echo "Restart agent:"
echo "  launchctl kill SIGTERM gui/\$(id -u)/com.ri.lori.agent"
echo ""
echo "See README.md for details."
echo ""
