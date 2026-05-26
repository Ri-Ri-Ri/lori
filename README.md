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

## Диагностика

Перед тем как разбираться вручную — посмотрите лог:
```bash
tail -40 ~/Library/Logs/voice-input.log
```

### Дерево проблем

```
Нажал горячую клавишу — ничего не происходит
├── Нет уведомления "🎙 Запись" и нет строки в логе
│   └── Агент не запущен → launchctl list | grep voice.agent
│       ├── Не появляется → launchctl load ~/Library/LaunchAgents/com.ri.voice.agent.plist
│       └── Есть, но падает → см. "Агент падает при старте" ниже
│
└── Лог есть, уведомлений нет
    └── Уведомления заблокированы → см. "Уведомления не появляются" ниже

Запись идёт (уведомление "🎙 Запись") — нажал снова — текст не вставился
├── В логе: "Слишком тихо"
│   └── Уменьшить min_volume в config.json (попробовать 0.001)
│
├── В логе: "Тишина" (Whisper ничего не распознал)
│   └── Проверить: говорили ли вы после уведомления о начале записи
│
├── В логе: "Paste: OK" — но текст не появился в приложении
│   └── Не выдано Accessibility для Python.app → см. "Текст не вставляется" ниже
│
└── В логе: ошибка "Operation not permitted" или нет строки Paste вообще
    └── Python.app не имеет Full Disk Access или Accessibility → перепроверить разрешения
```

---

### Агент падает при старте

```bash
# Смотреть оба лога
cat /tmp/voice-input-launchd.log
tail -20 ~/Library/Logs/voice-input.log
```

| Ошибка в логе | Причина | Решение |
|---|---|---|
| `No module named 'faster_whisper'` | Зависимости не установлены | `pip3 install faster-whisper sounddevice numpy pyobjc-framework-Quartz pyobjc-framework-Cocoa pyobjc-framework-UserNotifications pyobjc-framework-AVFoundation soundfile` |
| `No module named 'numpy'` или numpy crash | Сломан numpy (часто на Python 3.13) | `pip3 install numpy --force-reinstall` |
| `clang: error` при install.sh | Нет Xcode CLI Tools | `xcode-select --install` |
| `exit code 78` в launchctl | StandardOutPath в недоступной папке | Убрать StandardOutPath из plist или изменить на `/tmp/` |
| Два экземпляра → throttle | Предыдущий процесс завис | `pkill -f voice_input.py` затем перезапустить агент |

### Текст не вставляется

Разрешение Accessibility не выдано Python.app.

1. Открыть `System Settings → Privacy & Security → Accessibility`
2. Нажать `+`, найти Python.app по пути:
   ```
   /Library/Frameworks/Python.framework/Versions/3.XX/Resources/Python.app
   ```
   (замените XX на вашу версию — 13, 12 или 11)
3. Перезапустить агент:
   ```bash
   launchctl kill SIGTERM gui/$(id -u)/com.ri.voice.agent
   ```

Если путь не находится через диалог — перетащите файл прямо из Finder.

### Микрофон не работает

В логе появится: `[Errno -9999] Unanticipated host error` или запись стартует, но аудио пустое.

1. Открыть VoiceInput.app вручную: `open ~/Applications/VoiceInput.app`
2. macOS должен показать запрос на микрофон — нажать «Разрешить»
3. Если запрос не появился: `System Settings → Privacy & Security → Microphone` → добавить VoiceInput.app вручную

Если используется Homebrew Python (не с python.org) — микрофон может не работать вообще, потому что TCC привязывается к bundle ID. Решение: установить Python с [python.org](https://python.org/downloads/) и запустить `install.sh` снова.

### Уведомления не появляются

1. `System Settings → Notifications → Python` → включить уведомления
2. Если включены, но не пробивают режим «Не беспокоить» / Sleep:
   `System Settings → Focus → [ваш режим] → Разрешённые уведомления → Программы → добавить Python`

Проверить что DND не блокирует — в логе каждое уведомление пишет статус:
```
[10:15:03] notify: 🎙 Запись | ... | ✅ Focus/DND выкл     ← уведомление должно было прийти
[22:41:07] notify: 🎙 Запись | ... | ⛔ расписание DND (22:00–07:00)  ← заблокировано расписанием
```

### Зависает длинный текст в терминале

Известная особенность Cursor и некоторых других терминалов (xterm.js). Текст автоматически режется на куски по 400 символов — обычно помогает. Если нет:
- Уменьшить `CHUNK_SIZE = 400` в `voice_input.py` до 200
- Или вставлять не в терминал, а в текстовый редактор

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
