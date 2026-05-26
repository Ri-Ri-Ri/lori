# Voice Input — голосовой ввод с Whisper для macOS

Нажимаешь кнопку — говоришь — нажимаешь снова. Текст сам вставляется туда, где стоит курсор.

**Расшифровка полностью локальная.** Ничего не уходит в сеть, не нужен API-ключ.

---

## Что это

- Записывает голос с микрофона
- Расшифровывает через [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (модель medium, ~1.5 GB)
- Вставляет текст через буфер обмена (⌘V) в любое приложение
- Работает в фоне, запускается автоматически при входе

**Требования:** macOS 13+, Python 3.11–3.13 (рекомендуется установить с [python.org](https://python.org/downloads/)), ~2 ГБ свободного места (модель Whisper).

---

## Установка

```bash
cd voice-input-kit
bash install.sh
```

Скрипт сам:
- найдёт Python
- установит зависимости
- скомпилирует вспомогательный .app
- создаст launchd-агент (автозапуск)
- скачает модель Whisper (~1.5 ГБ, один раз)

После установки нужно вручную выдать разрешения и настроить горячую клавишу — install.sh выведет инструкцию.

---

## Разрешения macOS (обязательно)

Без этих разрешений система не запустится.

### 1. Accessibility — чтобы вставлять текст

`System Settings → Privacy & Security → Accessibility`

Добавить `Python.app`. Путь обычно:
```
/Library/Frameworks/Python.framework/Versions/3.XX/Resources/Python.app
```
(версию замените на свою, install.sh покажет точный путь)

### 2. Microphone — чтобы записывать голос

`System Settings → Privacy & Security → Microphone`

Добавить `VoiceInput.app` (лежит в `~/Applications/`).

Если его нет в списке — откройте вручную:
```bash
open ~/Applications/VoiceInput.app
```
macOS попросит разрешение на микрофон.

### 3. Notifications — чтобы видеть уведомления

`System Settings → Notifications → Python` → включить.

Если уведомления не пробивают режим «Не беспокоить»:
`System Settings → Focus → Сон → Разрешённые уведомления → Программы → Python`

---

## Горячая клавиша

Откройте **Shortcuts.app** (Быстрые команды):

1. Нажмите **+** → «Новая команда»
2. Добавьте действие **«Выполнить сценарий оболочки»**
3. Текст:
   ```
   bash ~/.voice-input/toggle.sh
   ```
   (замените путь если устанавливали в другое место)
4. Назначьте клавишу: ⌥Space, Fn, или любую удобную
5. Сохраните

Первое нажатие — начало записи (уведомление 🎙 Запись).
Второе нажатие — стоп + расшифровка + вставка.

---

## Файлы

После установки:

```
~/.voice-input/
├── voice_input.py       — основной скрипт
├── config.json          — настройки
└── toggle.sh            — триггер (вызывается из Shortcuts)

~/Applications/
└── VoiceInput.app       — нужен только для разрешения на микрофон

~/Library/LaunchAgents/
└── com.ri.voice.agent.plist  — автозапуск

~/Library/Logs/
└── voice-input.log      — все события
```

---

## Конфиг

`~/.voice-input/config.json`:

```json
{
  "model": "medium",
  "language": "ru",
  "sample_rate": 16000,
  "debounce_seconds": 0.3,
  "min_volume": 0.005
}
```

| Параметр | Значение | Описание |
|---|---|---|
| `model` | `"medium"` | Размер модели Whisper. `"small"` — быстрее, хуже. `"large-v2"` — точнее, медленнее. |
| `language` | `"ru"` | Язык. `"en"`, `"uk"`, `"de"` и др. Или `null` — авто-определение. |
| `min_volume` | `0.005` | Порог тишины. Если не расшифровывает тихую речь — уменьшить. |
| `debounce_seconds` | `0.3` | Защита от двойного срабатывания клавиши. |

После изменения конфига — перезапустить агент.

---

## Управление агентом

```bash
# Посмотреть статус
launchctl list | grep voice.agent

# Перезапустить
launchctl kill SIGTERM gui/$(id -u)/com.ri.voice.agent

# Остановить совсем
launchctl unload ~/Library/LaunchAgents/com.ri.voice.agent.plist

# Запустить снова
launchctl load ~/Library/LaunchAgents/com.ri.voice.agent.plist

# Логи в реальном времени
tail -f ~/Library/Logs/voice-input.log
```

---

## Проблемы

### Текст не вставляется

Не выдано разрешение Accessibility для Python.app. Смотри раздел выше.

### Микрофон не работает (нет записи)

Не выдано разрешение Microphone для VoiceInput.app. Откройте вручную:
```bash
open ~/Applications/VoiceInput.app
```

### Уведомления не появляются

1. `System Settings → Notifications → Python` → включить
2. Если Sleep/DND — добавить Python в разрешённые приложения для нужного режима Focus

### Агент стартует, но сразу падает

Смотрите `/tmp/voice-input-launchd.log` и `~/Library/Logs/voice-input.log`.

Частые причины:
- numpy не установлен или сломан → `pip3 install numpy --force-reinstall`
- Python 3.13 + старый numpy → обновить все пакеты
- Нет Xcode CLI tools → `xcode-select --install`

### Зависает длинный текст в терминале

Это известная особенность некоторых терминалов (Cursor/xterm.js). Текст автоматически разбивается на куски по 400 символов — должно помогать. Если нет — уменьшите в `voice_input.py` константу `CHUNK_SIZE = 400`.

### Homebrew Python и микрофон

Если Python установлен через Homebrew (не с python.org), macOS может не давать ему разрешение на микрофон через VoiceInput.app, потому что TCC привязывается к bundle ID приложения. Рекомендуется установить Python с [python.org](https://python.org/downloads/).

---

## Как это работает

```
Shortcuts (горячая клавиша)
        ↓
toggle.sh → touch /tmp/voice-input-toggle
        ↓
file watcher в voice_input.py (проверяет каждые 0.1с)
        ↓
sounddevice записывает микрофон в RAM
        ↓ (второе нажатие)
faster-whisper расшифровывает аудио
        ↓
CGEventPost (⌘V) вставляет текст
```

**Почему VoiceInput.app:** launchd-процессы не получают TCC-разрешение на микрофон напрямую.
VoiceInput.app (bundle ID `com.ri.voice-input`) держит разрешение через GUI-регистрацию.
`fork()` в launcher.c оставляет VoiceInput.app родителем — TCC видит правильный bundle.

---

## Зависимости

| Пакет | Зачем |
|---|---|
| `faster-whisper` | расшифровка |
| `sounddevice` | запись с микрофона |
| `numpy` | обработка аудио |
| `pyobjc-framework-Quartz` | вставка текста через CGEventPost |
| `pyobjc-framework-Cocoa` | буфер обмена NSPasteboard |
| `pyobjc-framework-UserNotifications` | уведомления |
| `pyobjc-framework-AVFoundation` | (резерв) |
| `soundfile` | сохранение аномальных записей |

---

## Удаление

```bash
# Остановить и удалить агент
launchctl unload ~/Library/LaunchAgents/com.ri.voice.agent.plist
rm ~/Library/LaunchAgents/com.ri.voice.agent.plist

# Удалить файлы
rm -rf ~/.voice-input
rm -rf ~/Applications/VoiceInput.app
```

Разрешения удалите вручную в System Settings → Privacy & Security.
