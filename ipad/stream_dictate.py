#!/usr/bin/env python3
"""Dictation into a game streamed to an iPad (Moonlight/Sunshine).

Moonlight does not forward the iPad's microphone, so this is a side channel: an iOS
Shortcut records audio and POSTs it here, the Whisper server transcribes it, and the
text is pasted into whatever has focus on the streamed Wayland desktop.
"""
import hmac
import json
import os
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DICTATE_PORT", "8650"))
WHISPER_URL = os.environ.get("WHISPER_URL", "http://localhost:8000/v1/audio/transcriptions")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "whisper-1")
TOKEN_FILE = os.path.expanduser(os.environ.get("DICTATE_TOKEN_FILE", "~/.config/dictate/ipad-token"))
TOKEN = open(TOKEN_FILE).read().strip()
MAX_BODY = 25 * 1024 * 1024
WAYLAND_ENV = {
    **os.environ,
    "WAYLAND_DISPLAY": os.environ.get("STREAM_WAYLAND_DISPLAY", os.environ.get("WAYLAND_DISPLAY", "wayland-1")),
    "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}",
}

type_lock = threading.Lock()


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def transcribe(audio: bytes, lang: str | None) -> str:
    boundary = uuid.uuid4().hex
    fields = {"model": WHISPER_MODEL, "response_format": "json"}
    if lang:
        fields["language"] = lang
    body = b""
    for k, v in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.m4a"\r\n'
             "Content-Type: application/octet-stream\r\n\r\n").encode() + audio + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(WHISPER_URL, data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r).get("text", "").strip()


def wtype(*args):
    subprocess.run(["wtype", "-d", "6", *args], env=WAYLAND_ENV, check=True, timeout=60)


def paste(text: str):
    prev = subprocess.run(["wl-paste", "-n"], env=WAYLAND_ENV, capture_output=True, timeout=5)
    subprocess.run(["wl-copy", "--", text], env=WAYLAND_ENV, check=True, timeout=5)
    # Wine reads the clipboard through XWayland, which picks up the new selection asynchronously.
    time.sleep(0.15)
    # Wine misses a bare modifier flag sent in the same instant as the key (the game sees plain "v"),
    # so hold a real Control_L and pause around the V.
    wtype("-P", "Control_L", "-s", "80", "-M", "ctrl", "-s", "80", "-k", "v", "-s", "80", "-m", "ctrl", "-p", "Control_L")
    time.sleep(0.3)
    if prev.returncode == 0:
        subprocess.run(["wl-copy"], input=prev.stdout, env=WAYLAND_ENV, timeout=5)


def type_text(text: str, mode: str):
    # Games under Wine drop keys sent faster than their input loop polls, hence the delays.
    with type_lock:
        if mode == "chat":
            wtype("-k", "Return")
            time.sleep(0.25)
        paste(text)
        if mode in ("chat", "send"):
            time.sleep(0.1)
            wtype("-k", "Return")


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if not hmac.compare_digest(self.headers.get("X-Token", ""), TOKEN):
            return self.reply(401, {"error": "bad token"})
        url = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        mode = q.get("mode", "chat")
        if mode not in ("chat", "send", "type"):
            return self.reply(400, {"error": "mode must be chat, send or type"})
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= MAX_BODY:
            return self.reply(400, {"error": "empty or too large body"})
        body = self.rfile.read(n)
        try:
            if url.path == "/dictate":
                t0 = time.time()
                text = transcribe(body, q.get("lang", "en") or None)
                log(f"transcribed {n}B in {time.time() - t0:.1f}s: {text!r}")
            elif url.path == "/type":
                text = body.decode("utf-8").strip()
            else:
                return self.reply(404, {"error": "not found"})
            if not text:
                return self.reply(200, {"text": "", "typed": False})
            type_text(text, mode)
            self.reply(200, {"text": text, "typed": True})
        except Exception as e:
            log(f"error: {e!r}")
            self.reply(502, {"error": str(e)})

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")


if __name__ == "__main__":
    log(f"listening on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
