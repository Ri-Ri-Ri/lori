#!/usr/bin/env python3
import fcntl
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

# Самое раннее логирование — до всего остального
_EARLY_LOG = Path(__file__).parent / "voice-input.log"
try:
    with open(_EARLY_LOG, "a") as _f:
        _f.write(f"[{time.strftime('%H:%M:%S')}] === START (pid={os.getpid()}) ===\n")
except Exception:
    pass

os.environ["HF_HOME"] = str(Path(__file__).parent / "models")

import numpy as np
import soundfile as sf
import sounddevice as sd
import mlx_whisper

CONFIG_PATH = Path(__file__).parent / "config.json"
LOG_PATH = Path(__file__).parent / "voice-input.log"
CLIPS_DIR = Path(__file__).parent / "voice-clips"
MLX_WHISPER_MODEL = "mlx-community/whisper-medium-mlx"

DEFAULT_CONFIG = {
    "language": "ru",
    "sample_rate": 16000,
    "min_volume": 0.02,
    "debounce_seconds": 1.0,
}

STATE_IDLE = "idle"
STATE_RECORDING = "recording"
STATE_TRANSCRIBING = "transcribing"

TOGGLE_FILE = "/tmp/voice-input-toggle"


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_config():
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return {**DEFAULT_CONFIG, **json.load(f)}
    return DEFAULT_CONFIG


def _focus_mode_status():
    try:
        import plistlib
        with open(os.path.expanduser("~/Library/Preferences/com.apple.ncprefs.plist"), "rb") as f:
            outer = plistlib.load(f)
        prefs = plistlib.loads(bytes(outer.get("dnd_prefs", b"")))
        now_min = time.localtime().tm_hour * 60 + time.localtime().tm_min
        sched = prefs.get("scheduledTime", {})
        if sched.get("enabled"):
            start, end = int(sched["start"]), int(sched["end"])
            active = (now_min >= start or now_min < end) if start > end else (start <= now_min < end)
            if active:
                return f"⛔ расписание DND ({start//60:02d}:{start%60:02d}–{end//60:02d}:{end%60:02d})"
        return "✅ Focus/DND выкл"
    except Exception:
        return "?"


def notify(title, message=""):
    log(f"notify: {title} | {message} | {_focus_mode_status()}")
    try:
        import UserNotifications as UN
        c = UN.UNUserNotificationCenter.currentNotificationCenter()
        content = UN.UNMutableNotificationContent.alloc().init()
        content.setTitle_(title)
        content.setBody_(message or " ")
        content.setInterruptionLevel_(2)  # timeSensitive — пробивает Focus если Python в разрешённых
        uid = f"vi{int(time.time()*1000)%99999}"
        req = UN.UNNotificationRequest.requestWithIdentifier_content_trigger_(uid, content, None)
        c.addNotificationRequest_withCompletionHandler_(req, None)
    except Exception:
        pass


CHUNK_SIZE = 400  # Cursor/xterm.js зависает на больших clipboard paste


def _split_chunks(text, size):
    if len(text) <= size:
        return [text]
    chunks = []
    while text:
        if len(text) <= size:
            chunks.append(text)
            break
        cut = text.rfind(" ", 0, size)
        if cut == -1:
            cut = size
        chunks.append(text[:cut])
        text = text[cut:].lstrip(" ")
    return chunks


def _cmd_v():
    import Quartz
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for down in (True, False):
        e = Quartz.CGEventCreateKeyboardEvent(src, 9, down)
        Quartz.CGEventSetFlags(e, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, e)
        time.sleep(0.05)


def paste_text(text):
    # join lines (each \n in terminal = Enter → shell executes line)
    text = " ".join(text.splitlines()).strip()
    # strip all ASCII control chars (0x00–0x1F incl. Ctrl+S=0x13, ESC=0x1B) and DEL (0x7F)
    text = "".join(ch for ch in text if ord(ch) >= 0x20 and ord(ch) != 0x7F)
    if not text:
        log("Paste: пустой текст после sanitize")
        return

    chunks = _split_chunks(text, CHUNK_SIZE)
    log(f"Paste ({len(text)} chars, {len(text.encode('utf-8'))} bytes, {len(chunks)} chunk(s)): {repr(text[:120])}")

    try:
        from AppKit import NSPasteboard
        pb = NSPasteboard.generalPasteboard()

        for i, chunk in enumerate(chunks):
            pb.clearContents()
            pb.setString_forType_(chunk, "public.utf8-plain-text")
            time.sleep(0.2)
            _cmd_v()
            if i < len(chunks) - 1:
                time.sleep(0.15)

        log("Paste: OK")
    except Exception as ex:
        log(f"Paste error: {ex}")
        try:
            subprocess.run(["pbcopy"], input=text.encode("utf-8"), capture_output=True)
            time.sleep(0.3)
            _cmd_v()
            log("Paste: OK (pbcopy fallback)")
        except Exception as ex2:
            log(f"Paste fallback error: {ex2}")


class VoiceInput:
    def __init__(self, config):
        self.config = config
        self.state = STATE_IDLE
        self.audio_data = []
        self._lock = threading.Lock()
        self._stream = None
        self._last_tap = 0.0

        try:
            dev = sd.query_devices(kind='input')
            log(f"Микрофон: {dev['name']}")
        except Exception as e:
            log(f"Микрофон: {e}")

        self._cleanup_old_clips()

        log(f"Прогреваю модель {MLX_WHISPER_MODEL}...")
        mlx_whisper.transcribe(
            np.zeros(16000, dtype=np.float32),
            path_or_hf_repo=MLX_WHISPER_MODEL,
            language=config["language"],
        )
        log("Готово. Жду триггера.")

    def _cleanup_old_clips(self):
        import datetime
        CLIPS_DIR.mkdir(parents=True, exist_ok=True)
        cutoff = time.time() - 7 * 24 * 3600
        for f in CLIPS_DIR.glob("voice-clipped-*.wav"):
            if f.stat().st_mtime < cutoff:
                try:
                    f.unlink()
                    log(f"Удалён старый клип: {f.name}")
                except Exception:
                    pass

    def toggle(self):
        now = time.time()
        if now - self._last_tap < self.config["debounce_seconds"]:
            return
        self._last_tap = now

        with self._lock:
            if self.state == STATE_TRANSCRIBING:
                return
            elif self.state == STATE_RECORDING:
                self.state = STATE_TRANSCRIBING
                stream_to_stop = self._stream
                audio_to_transcribe = list(self.audio_data)
                action = "stop"
            else:
                action = "start"

        if action == "stop":
            log("→ стоп")
            # notify("⏹", "Расшифровываю...")  # отключено: индикатора достаточно
            try:
                stream_to_stop.stop()
                stream_to_stop.close()
            except Exception as e:
                log(f"Ошибка остановки: {e}")
            if audio_to_transcribe:
                threading.Thread(
                    target=self._transcribe, args=(audio_to_transcribe,), daemon=True
                ).start()
            else:
                with self._lock:
                    self.state = STATE_IDLE

        elif action == "start":
            log("→ старт")
            with self._lock:
                self._start_recording()

    def _start_recording(self):
        self.state = STATE_RECORDING
        self.audio_data = []

        def callback(indata, frames, time_info, status):
            with self._lock:
                if self.state == STATE_RECORDING:
                    self.audio_data.append(indata.copy())

        try:
            self._stream = sd.InputStream(
                samplerate=self.config["sample_rate"],
                channels=1,
                dtype="float32",
                callback=callback,
            )
            self._stream.start()
            log("Запись началась")
            # notify("🎙 Запись", "Говори. Нажми кнопку чтобы остановить")  # отключено: индикатора достаточно
        except Exception as e:
            log(f"Ошибка записи: {e}")
            self.state = STATE_IDLE

    def _transcribe(self, audio_data):
        log("Расшифровываю...")
        try:
            audio = np.concatenate(audio_data, axis=0).flatten()
            duration = len(audio) / self.config["sample_rate"]
            log(f"Аудио: {duration:.1f}с")
            max_vol = float(np.abs(audio).max())
            log(f"Громкость: max={max_vol:.3f}")
            if max_vol < self.config.get("min_volume", 0.02):
                log("Слишком тихо")
                # notify("Voice Input", "Слишком тихо")  # отключено: индикатора достаточно
                return
            # normalize audio to [-1, 1] to protect against clipping/overload
            if max_vol > 1.0:
                import datetime
                # Нормализуем по 99й перцентили, а не по пику — иначе один удар/клик
                # делает всю речь неслышимой после нормализации
                p99 = float(np.percentile(np.abs(audio), 99))
                scale = p99 * 3 if p99 > 0 else max_vol
                audio = np.clip(audio, -scale, scale) / scale
                save_path = CLIPS_DIR / f"voice-clipped-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.wav"
                sf.write(save_path, audio, self.config["sample_rate"])
                log(f"Аномальная громкость ({max_vol:.1f}) — нормализовал, сохранил: {save_path}")

            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=MLX_WHISPER_MODEL,
                language=self.config["language"],
            )
            text = result["text"].strip()
            log(f"Текст: '{text}'")
            if text:
                paste_text(text)
                # notify("✅", text[:70])  # отключено: индикатора достаточно
            else:
                pass  # notify("Voice Input", "Тишина")  # отключено: индикатора достаточно
        except Exception as e:
            log(f"Ошибка расшифровки: {e}")
            # notify("❌ Ошибка", str(e)[:100])  # отключено: индикатора достаточно
        finally:
            with self._lock:
                self.state = STATE_IDLE
            log("Готово, жду триггера...")


_lock_fh = None


def acquire_lock():
    global _lock_fh
    _lock_fh = open("/tmp/voice-input.lock", "w")
    try:
        fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError:
        sys.exit(0)


def watch_toggle_file(vi):
    while True:
        if os.path.exists(TOGGLE_FILE):
            try:
                os.remove(TOGGLE_FILE)
            except Exception:
                pass
            vi.toggle()
        time.sleep(0.1)


def main():
    acquire_lock()
    try:
        import AppKit
        app = AppKit.NSApplication.sharedApplication()
        app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)
        log("NSApp: OK")
    except Exception as e:
        log(f"NSApp: недоступен ({e}), продолжаем без него")
        app = None

    config = load_config()

    while True:
        try:
            vi = VoiceInput(config)
            break
        except Exception as e:
            log(f"Ошибка загрузки: {e}, повтор через 5с")
            time.sleep(5)

    threading.Thread(target=watch_toggle_file, args=(vi,), daemon=True).start()

    if app is not None:
        try:
            app.run()
        except Exception as e:
            log(f"NSApp.run() упал: {e}, держу процесс через sleep")

    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
