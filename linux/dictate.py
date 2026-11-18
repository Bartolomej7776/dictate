#!/usr/bin/env python3
"""Push-to-talk dictation: hold a key, talk, release; text is pasted into the focused window."""
import io
import json
import math
import os
import selectors
import shutil
import struct
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import wave
from pathlib import Path

import evdev
from evdev import UInput, ecodes as e

CONFIG_PATH = Path(os.environ.get("DICTATE_CONFIG", Path.home() / ".config/dictate/config.json"))
DEFAULTS = {
    "server": "http://localhost:8000",
    "keys": {"KEY_RIGHTCTRL": {"model": "whisper-1", "language": None, "prompt": None}},
    "min_hold": 0.3,
    "tail": 0.4,
    "paste_combo": ["KEY_LEFTCTRL", "KEY_V"],
    "restore_clipboard": True,
    "beep": True,
}
RATE = 16000
VKBD_NAME = "dictate-vkbd"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    return cfg


def tone(freq, ms=70, vol=0.25):
    n = int(RATE * ms / 1000)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(vol * 32767 * math.sin(2 * math.pi * freq * i / RATE) * min(1, (n - i) / 200)))
            for i in range(n)))
    return buf.getvalue()


class Beeper:
    def __init__(self, enabled):
        self.player = shutil.which("pw-play") or shutil.which("paplay") if enabled else None
        self.files = {}
        if self.player:
            d = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "dictate"
            d.mkdir(exist_ok=True)
            for name, f in (("start", 880), ("stop", 660), ("error", 220)):
                p = d / f"{name}.wav"
                p.write_bytes(tone(f, 150 if name == "error" else 70))
                self.files[name] = str(p)

    def __call__(self, name):
        if self.player:
            subprocess.Popen([self.player, self.files[name]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Recorder:
    def __init__(self):
        self.proc = None
        self.chunks = []
        self.thread = None

    def start(self):
        self.chunks = []
        self.proc = subprocess.Popen(
            ["parec", "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1", "--latency-msec=20"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    def _pump(self):
        while chunk := self.proc.stdout.read(3200):
            self.chunks.append(chunk)

    def stop(self):
        self.proc.terminate()
        self.proc.wait()
        self.thread.join(1)
        pcm = b"".join(self.chunks)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm)
        return buf.getvalue(), len(pcm) / (2 * RATE)

    def cancel(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait()


def transcribe(server, wav, opts):
    boundary = uuid.uuid4().hex
    fields = {"model": opts.get("model") or "whisper-1", "response_format": "json"}
    for k in ("language", "prompt"):
        if opts.get(k):
            fields[k] = opts[k]
    body = io.BytesIO()
    for k, v in fields.items():
        body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    body.write(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
               f"Content-Type: audio/wav\r\n\r\n".encode())
    body.write(wav)
    body.write(f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request(server.rstrip("/") + "/v1/audio/transcriptions", data=body.getvalue(),
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["text"].strip()


class Clipboard:
    def __init__(self):
        # KDE X11 sessions can export a stale WAYLAND_DISPLAY, so the session type decides.
        session = os.environ.get("XDG_SESSION_TYPE") or ("wayland" if os.environ.get("WAYLAND_DISPLAY") else "x11")
        if session == "wayland":
            self.copy, self.paste = ["wl-copy"], ["wl-paste", "--no-newline"]
        else:
            self.copy, self.paste = ["xclip", "-selection", "clipboard"], ["xclip", "-selection", "clipboard", "-o"]

    def get(self):
        try:
            return subprocess.run(self.paste, capture_output=True, timeout=1).stdout
        except Exception:
            return None

    def set(self, data: bytes):
        subprocess.run(self.copy, input=data, timeout=2)


def keyboards():
    out = []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except OSError:
            continue
        keys = d.capabilities().get(e.EV_KEY, [])
        if d.name != VKBD_NAME and e.KEY_A in keys and e.KEY_SPACE in keys:
            out.append(d)
        else:
            d.close()
    return out


def main():
    cfg = load_config()
    hotkeys = {e.ecodes[name]: opts for name, opts in cfg["keys"].items()}
    combo = [e.ecodes[k] for k in cfg["paste_combo"]]
    beep = Beeper(cfg["beep"])
    clip = Clipboard()
    rec = Recorder()
    ui = UInput({e.EV_KEY: list(set(combo))}, name=VKBD_NAME)

    def paste(text):
        old = clip.get() if cfg["restore_clipboard"] else None
        clip.set(text.encode())
        time.sleep(0.08)
        for k in combo:
            ui.write(e.EV_KEY, k, 1)
            ui.syn()
        for k in reversed(combo):
            ui.write(e.EV_KEY, k, 0)
            ui.syn()
        if old is not None:
            time.sleep(0.4)
            clip.set(old)

    def finish(opts):
        time.sleep(cfg["tail"])
        wav, secs = rec.stop()
        beep("stop")
        if secs < cfg["min_hold"]:
            log(f"only {secs:.2f}s of audio captured; is a microphone the default source?")
            beep("error")
            return
        t0 = time.time()
        try:
            text = transcribe(cfg["server"], wav, opts)
        except Exception as ex:
            log("transcribe failed:", ex)
            beep("error")
            return
        log(f"{secs:.1f}s audio -> {time.time() - t0:.2f}s: {text!r}")
        if text:
            paste(text + " ")

    sel = selectors.DefaultSelector()
    devs = {}

    def rescan():
        for d in keyboards():
            if d.path in devs:
                d.close()
                continue
            devs[d.path] = d
            sel.register(d, selectors.EVENT_READ)
            log("watching", d.path, d.name)

    rescan()
    held = None
    pressed_at = 0.0
    busy = threading.Lock()
    last_scan = time.time()
    log("ready; hotkeys:", ", ".join(cfg["keys"]), "server:", cfg["server"])

    while True:
        for key, _ in sel.select(timeout=2):
            dev = key.fileobj
            try:
                events = list(dev.read())
            except OSError:
                sel.unregister(dev)
                devs.pop(dev.path, None)
                continue
            for ev in events:
                if ev.type != e.EV_KEY:
                    continue
                if held is None and ev.value == 1 and ev.code in hotkeys and not busy.locked():
                    held = ev.code
                    pressed_at = time.time()
                    rec.start()
                    beep("start")
                elif held is not None and ev.value == 1 and ev.code != held:
                    rec.cancel()
                    held = None
                elif held is not None and ev.value == 0 and ev.code == held:
                    opts = hotkeys[held]
                    held = None
                    if time.time() - pressed_at < cfg["min_hold"]:
                        rec.cancel()
                        continue

                    def run(o=opts):
                        with busy:
                            finish(o)
                    threading.Thread(target=run, daemon=True).start()
        if time.time() - last_scan > 5:
            rescan()
            last_scan = time.time()


if __name__ == "__main__":
    sys.exit(main())
