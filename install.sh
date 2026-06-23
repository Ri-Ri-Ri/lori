#!/bin/bash
# ============================================================
# Voice Input — установщик
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
step "Ищу Python 3..."

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

# Homebrew fallback
if [ -z "$PYTHON_BIN" ]; then
    for hb_py in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$hb_py" ]; then
            PYTHON_BIN="$hb_py"
            PYTHON_APP=""
            warn "Используется Homebrew Python: $PYTHON_BIN"
            warn "Микрофон может не работать без Apple Python.framework (см. README раздел «Проблемы»)."
            break
        fi
    done
fi

[ -z "$PYTHON_BIN" ] && err "Python 3 не найден. Установите с python.org/downloads/ и запустите install.sh снова."

# ── 2. Папка установки ───────────────────────────────────────
step "Куда установить скрипты?"
DEFAULT_INSTALL="$HOME/.voice-input"
echo    "  По умолчанию: $DEFAULT_INSTALL"
echo -n "  Введите путь (Enter = по умолчанию): "
read INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL}"
mkdir -p "$INSTALL_DIR"
ok "Папка: $INSTALL_DIR"

# ── 3. Зависимости Python ─────────────────────────────────────
step "Устанавливаю Python-зависимости..."
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
ok "Зависимости установлены."

# ── 4. Модель mlx-whisper (распознавание речи) ─────────────────
step "Модель mlx-whisper..."
echo "   Модель mlx-community/whisper-medium-mlx (~1.4 GB) скачается автоматически"
echo "   при первом запуске и закэшируется в models/ (HF_HOME) — разово."
ok "Готово к первому запуску."

# ── 5. Копирую файлы ─────────────────────────────────────────
step "Копирую файлы в $INSTALL_DIR..."
cp "$SCRIPT_DIR/voice_input.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/toggle.sh"      "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/toggle.sh"

# config.json — копирую только если не существует (не затираю пользовательские настройки)
if [ ! -f "$INSTALL_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$INSTALL_DIR/"
    ok "config.json создан (настройте при необходимости)."
else
    ok "config.json уже есть — не трогаю."
fi

ok "Файлы скопированы."

# ── 6. Собираю VoiceInput.app ────────────────────────────────
step "Собираю VoiceInput.app..."

APP_DEST="$HOME/Applications/VoiceInput.app"
mkdir -p "$APP_DEST/Contents/MacOS"
cp "$SCRIPT_DIR/VoiceInput.app/Contents/Info.plist" "$APP_DEST/Contents/"

# Подставляю реальные пути в launcher.c
LAUNCHER_TMP="/tmp/voice_launcher_$$.c"
sed \
    -e "s|PLACEHOLDER_PYTHON_BIN|${PYTHON_BIN}|g" \
    -e "s|PLACEHOLDER_SCRIPT_PATH|${INSTALL_DIR}/voice_input.py|g" \
    "$SCRIPT_DIR/launcher.c" > "$LAUNCHER_TMP"

clang -o "$APP_DEST/Contents/MacOS/VoiceInput" "$LAUNCHER_TMP" \
    || err "Не удалось скомпилировать launcher.c. Установлен ли Xcode Command Line Tools? (xcode-select --install)"
rm -f "$LAUNCHER_TMP"

# ad-hoc подпись (нужна на arm64)
codesign --force --sign - "$APP_DEST/Contents/MacOS/VoiceInput" 2>/dev/null \
    && ok "Бинарник подписан (ad-hoc)." \
    || warn "codesign не удался — попробуйте вручную: codesign --force --sign - $APP_DEST/Contents/MacOS/VoiceInput"

ok "VoiceInput.app готов: $APP_DEST"

# ── 7. Прошу разрешение macOS на микрофон ─────────────────────
step "Открываю VoiceInput.app для регистрации TCC-разрешений..."
echo "   macOS покажет запрос на доступ к микрофону — нажмите «Разрешить»."
open "$APP_DEST" || warn "Не удалось открыть VoiceInput.app — откройте вручную."
sleep 3

# ── 8. launchd plist ─────────────────────────────────────────
step "Создаю launchd-агент..."

PLIST_DEST="$HOME/Library/LaunchAgents/com.ri.voice.agent.plist"

# Используем Python.app если доступен (для корректного TCC)
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
    <string>com.ri.voice.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LAUNCHD_PYTHON}</string>
        <string>${INSTALL_DIR}/voice_input.py</string>
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

ok "plist создан: $PLIST_DEST"

# ── 9. Загружаю агент ────────────────────────────────────────
step "Загружаю launchd-агент..."
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load   "$PLIST_DEST"
sleep 2

if launchctl list | grep -q "com.ri.voice.agent"; then
    ok "Агент запущен."
else
    warn "Агент не появился в launchctl list — проверьте логи: ~/Library/Logs/voice-input.log"
fi

# ── 10. Итог ─────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo -e "${GREEN}✅ Voice Input установлен!${NC}"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Осталось сделать вручную (один раз):"
echo ""
echo "  1. Разрешения macOS (System Settings → Privacy & Security):"
echo "     • Accessibility  → добавить Python.app"
echo "       Путь: $(find /Library/Frameworks/Python.framework -name "Python.app" -maxdepth 5 2>/dev/null | head -1)/Contents/MacOS/Python"
echo "     • Microphone     → VoiceInput.app (должно появиться после шага 7)"
echo "     • Notifications  → разрешить уведомления для Python"
echo ""
echo "  2. Горячая клавиша (macOS Shortcuts):"
echo "     • Откройте приложение «Быстрые команды» (Shortcuts.app)"
echo "     • Создайте новую команду: «Выполнить сценарий оболочки»"
echo "       Текст: bash $INSTALL_DIR/toggle.sh"
echo "     • Назначьте сочетание клавиш (например, ⌥Space или Fn)"
echo ""
echo "  3. Если уведомления не пробивают режим «Не беспокоить»:"
echo "     System Settings → Focus → Сон → Разрешённые уведомления → Программы → Python"
echo ""
echo "Логи: tail -f ~/Library/Logs/voice-input.log"
echo "Перезапуск агента:"
echo "  launchctl kill SIGTERM gui/\$(id -u)/com.ri.voice.agent"
echo ""
echo "Подробности — README.md"
echo ""
