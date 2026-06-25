# Lori — голосовой ввод для macOS

![Lori](assets/lori-github-banner-1280x640.png)

Нажимаешь кнопку — говоришь — нажимаешь снова. Текст сам вставляется туда, где стоит курсор.

**Расшифровка полностью локальная.** Ничего не уходит в сеть, не нужен API-ключ.

---

## Что это

- Записывает голос с микрофона
- Расшифровывает через [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (модель `mlx-community/whisper-medium-mlx`) — Whisper medium, ускоренный на Apple Neural Engine через MLX
- Вставляет текст через буфер обмена (⌘V) в любое приложение
- Работает в фоне, запускается автоматически при входе

**Требования:** macOS 13+ (на Apple Silicon работает на Neural Engine, на Intel будет заметно медленнее), Python 3.11–3.13 (рекомендуется установить с [python.org](https://python.org/downloads/)), ~1.5 ГБ свободного места (модель mlx-whisper medium, кэшируется один раз).

---

## Установка

```bash
git clone https://github.com/Ri-Ri-Ri/lori.git
cd lori
bash install.sh
```

Скрипт сам:
- найдёт Python
- установит зависимости (Python-пакеты, включая `mlx-whisper`)
- скомпилирует вспомогательный .app
- создаст launchd-агент (автозапуск)

Модель mlx-whisper medium (~1.4 ГБ) скачается автоматически при первом запуске и закэшируется локально — один раз.

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

Добавить `Lori.app` (лежит в `~/Applications/`).

Если его нет в списке — откройте вручную:
```bash
open ~/Applications/Lori.app
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
   bash ~/.lori/toggle.sh
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
~/.lori/
├── lori.py       — основной скрипт
├── config.json          — настройки
├── toggle.sh            — триггер (вызывается из Shortcuts)
└── models/              — кэш модели mlx-whisper (HF_HOME), ~1.4 ГБ, скачивается один раз

~/Applications/
└── Lori.app       — нужен только для разрешения на микрофон

~/Library/LaunchAgents/
└── com.ri.lori.agent.plist  — автозапуск

~/Library/Logs/
└── lori.log      — все события
```

---

## Конфиг

`~/.lori/config.json`:

```json
{
  "language": "ru",
  "sample_rate": 16000,
  "debounce_seconds": 0.3,
  "min_volume": 0.005
}
```

| Параметр | Значение | Описание |
|---|---|---|
| `language` | `"ru"` | Язык. `"en"`, `"uk"`, `"de"` и др. — Whisper поддерживает [~100 языков](https://github.com/openai/whisper#available-models-and-languages). |
| `min_volume` | `0.005` | Порог тишины. Если не расшифровывает тихую речь — уменьшить. |
| `debounce_seconds` | `0.3` | Защита от двойного срабатывания клавиши. |

После изменения конфига — перезапустить агент.

---

## Управление агентом

```bash
# Посмотреть статус
launchctl list | grep lori.agent

# Перезапустить
launchctl kill SIGTERM gui/$(id -u)/com.ri.lori.agent

# Остановить совсем
launchctl unload ~/Library/LaunchAgents/com.ri.lori.agent.plist

# Запустить снова
launchctl load ~/Library/LaunchAgents/com.ri.lori.agent.plist

# Логи в реальном времени
tail -f ~/Library/Logs/lori.log
```

---

## Диагностика

Перед тем как разбираться вручную — посмотрите лог:
```bash
tail -40 ~/Library/Logs/lori.log
```

### Дерево проблем

```
Нажал горячую клавишу — ничего не происходит
├── Нет уведомления "🎙 Запись" и нет строки в логе
│   └── Агент не запущен → launchctl list | grep lori.agent
│       ├── Не появляется → launchctl load ~/Library/LaunchAgents/com.ri.lori.agent.plist
│       └── Есть, но падает → см. "Агент падает при старте" ниже
│
└── Лог есть, уведомлений нет
    └── Уведомления заблокированы → см. "Уведомления не появляются" ниже

Запись идёт (уведомление "🎙 Запись") — нажал снова — текст не вставился
├── В логе: "Слишком тихо"
│   └── Уменьшить min_volume в config.json (попробовать 0.001)
│
├── В логе: "Тишина" (mlx-whisper ничего не распознал)
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
cat /tmp/lori-launchd.log
tail -20 ~/Library/Logs/lori.log
```

| Ошибка в логе | Причина | Решение |
|---|---|---|
| `No module named 'mlx_whisper'` | mlx-whisper не установлен | `pip3 install mlx-whisper` |
| `No module named 'sounddevice'` (или другой пакет) | Python-зависимости не установлены | `pip3 install sounddevice numpy pyobjc-framework-Quartz pyobjc-framework-Cocoa pyobjc-framework-UserNotifications pyobjc-framework-AVFoundation soundfile mlx-whisper` |
| `No module named 'numpy'` или numpy crash | Сломан numpy (часто на Python 3.13) | `pip3 install numpy --force-reinstall` |
| `clang: error` при install.sh | Нет Xcode CLI Tools | `xcode-select --install` |
| `exit code 78` в launchctl | StandardOutPath в недоступной папке | Убрать StandardOutPath из plist или изменить на `/tmp/` |
| Два экземпляра → throttle | Предыдущий процесс завис | `pkill -f lori.py` затем перезапустить агент |

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
   launchctl kill SIGTERM gui/$(id -u)/com.ri.lori.agent
   ```

Если путь не находится через диалог — перетащите файл прямо из Finder.

### Микрофон не работает

В логе появится: `[Errno -9999] Unanticipated host error` или запись стартует, но аудио пустое.

1. Открыть Lori.app вручную: `open ~/Applications/Lori.app`
2. macOS должен показать запрос на микрофон — нажать «Разрешить»
3. Если запрос не появился: `System Settings → Privacy & Security → Microphone` → добавить Lori.app вручную

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
- Уменьшить `CHUNK_SIZE = 400` в `lori.py` до 200
- Или вставлять не в терминал, а в текстовый редактор

---

## Как это работает

```
Shortcuts (горячая клавиша)
        ↓
toggle.sh → touch /tmp/lori-toggle
        ↓
file watcher в lori.py (проверяет каждые 0.1с)
        ↓
sounddevice записывает микрофон в RAM
        ↓ (второе нажатие)
mlx-whisper (Apple Neural Engine через MLX) расшифровывает аудио
        ↓
CGEventPost (⌘V) вставляет текст
```

**Почему Lori.app:** launchd-процессы не получают TCC-разрешение на микрофон напрямую.
Lori.app (bundle ID `com.ri.lori`) держит разрешение через GUI-регистрацию.
`fork()` в launcher.c оставляет Lori.app родителем — TCC видит правильный bundle.

---

## Зависимости

| Пакет | Зачем |
|---|---|
| [`mlx-whisper`](https://pypi.org/project/mlx-whisper/) | расшифровка речи (Whisper medium на Apple Neural Engine через MLX) |
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
launchctl unload ~/Library/LaunchAgents/com.ri.lori.agent.plist
rm ~/Library/LaunchAgents/com.ri.lori.agent.plist

# Удалить файлы (включая закэшированную модель mlx-whisper в models/)
rm -rf ~/.lori
rm -rf ~/Applications/Lori.app
```

Разрешения удалите вручную в System Settings → Privacy & Security.

---

## Лицензия

[MIT](LICENSE)
