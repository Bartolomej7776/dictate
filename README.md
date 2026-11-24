# dictate

Hold a key, talk, let go. The speech is transcribed by your own Whisper server. Depending on the key, the text either:

- is **pasted where your cursor is** (dictation, Linux and Windows), or
- is sent as a **voice request to a [Hermes Agent](https://github.com/NousResearch/hermes-agent)** webhook (Windows and macOS), which delivers the reply to your chat, e.g. a Telegram topic.

No cloud STT is involved. Any OpenAI-compatible transcription server works (`POST /v1/audio/transcriptions`), for example [speaches](https://github.com/speaches-ai/speaches) running `faster-whisper-large-v3-turbo` on a GPU. On an RTX 3080 that takes about 0.5 s per utterance.

| Platform | Default key | Action | Source |
|---|---|---|---|
| Linux (X11 or Wayland) | Right Ctrl | dictation | `linux/` |
| Windows 10/11 | Right Ctrl (configurable, incl. Win and the Copilot key) | dictation or Hermes | `windows/` |
| macOS | Right Option | Hermes | `mac/` |
| iPad, into a game streamed with Moonlight | iOS Shortcut button | dictation | `ipad/` |

## Server

Any OpenAI-compatible Whisper endpoint. With speaches:

```bash
docker run -d --gpus all -p 8000:8000 -e WHISPER__TTL=-1 ghcr.io/speaches-ai/speaches:latest-cuda
```

`WHISPER__TTL=-1` keeps the model loaded, so the first request after idle isn't slow. The clients send `model: whisper-1`. Map that name to the model you want with speaches' model aliases, or set `model` per key in the client config.

## Linux

```bash
cd linux && ./install.sh http://your-server:8000
```

- **Install:** sets up a systemd user service, `dictate.service`.
- **Packages:** needs `python3-evdev`, `pulseaudio-utils` (parec), and `xclip` (X11) or `wl-clipboard` (Wayland).
- **Root steps:** a udev rule for `/dev/uinput` and adding you to the `input` group. These are run with sudo, or printed for you to run.
- **Paste:** a virtual keyboard sends Ctrl+V.
- **Logs:** `journalctl --user -u dictate`.

## Windows

Copy `windows/` to the PC and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Server http://your-server:8000
```

- **Build:** compiles with the C# compiler built into Windows (.NET Framework), so nothing to install.
- **Startup:** registers a scheduled task that starts at logon and restarts if it crashes.
- **Admin:** runs elevated, so dictation also works in elevated windows.
- **Config:** `%APPDATA%\dictate\config.json`. Keys use .NET `Keys` names, e.g. `RControlKey`, `LWin`, `F24`.
- **Copilot key:** the key sends Win+Shift+F23, so use the key name `F23`.
- **Hermes keys:** give a key `"action": "hermes"`, and add a `"hermes": {"url": ..., "secret": ..., "source": "PC"}` block.

Notes from real use:

- **Win as a key:** Windows 11 opens Start on a lone Win release, so the client hides Win from Windows while held. Taps and Win+key shortcuts still work.
- **Keyboards that withhold key-ups:** some wireless keyboards delay the key-up until the next key press. A stalled auto-repeat stream is treated as the release.
- **Dropped hooks:** Windows silently removes slow keyboard hooks. The client notices input it missed and reinstalls its hook.

## macOS (voice to Hermes)

```bash
cd mac
WHISPER_URL=http://your-server:8000 \
HERMES_URL=http://your-hermes:8644/webhooks/voice \
HERMES_SECRET=<route secret> ./install.sh
```

- **Build:** builds `~/Applications/HermesVoice.app` and a LaunchAgent that starts it at login.
- **Fallbacks (optional):** `WHISPER_FALLBACK` and `HERMES_FALLBACK` are tried when the primary URL is unreachable, e.g. LAN addresses for when the VPN is down.
- **Input Monitoring:** after the first install, drag the app into System Settings › Privacy & Security › Input Monitoring. It doesn't appear there on its own. Then restart it with the command the installer prints.
- **Signing:** the app is signed with a self-signed identity the installer creates in your login keychain, so rebuilds keep the Input Monitoring grant.

## iPad (dictation into a streamed game)

For playing a PC game on an iPad through [Moonlight](https://moonlight-stream.org/) and [Sunshine](https://github.com/LizardByte/Sunshine). Moonlight doesn't forward the iPad's microphone or clipboard, so the iPad's own dictation can't reach the game. Instead, an iOS Shortcut records your voice and posts it to a small server on the streaming PC. The server has Whisper transcribe it, then pastes the text into the game, for example straight into chat.

The server side assumes Sunshine captures a Wayland session (for example headless sway), and the game runs under Wine or Proton.

```bash
cd ipad && ./install.sh http://your-server:8000 wayland-1
```

- **Install:** sets up a systemd user service, `stream-dictate.service`, on port 8650. It prints a random token for the Shortcut.
- **Display:** the second argument is the `WAYLAND_DISPLAY` of the session Sunshine streams.
- **Packages:** needs `wtype` and `wl-clipboard`.
- **Network:** the iPad must reach port 8650. Open it to your LAN or VPN only. Anyone with the token can type on that desktop.
- **Logs:** `journalctl --user -u stream-dictate`.

### The iOS Shortcut

1. In the **Shortcuts** app, create a shortcut, for example "Game Dictate".
2. Add **Record Audio**. Set Start Recording to **Immediately** and Finish Recording to **On Tap**.
3. Add **Get Contents of URL**:
   - URL: `http://<streaming-pc>:8650/dictate?mode=chat`
   - Method: **POST**
   - Header: `X-Token` set to the token the installer printed
   - Request Body: **File**, set to **Recorded Audio**
4. For a floating button, go to Settings › Accessibility › Touch › AssistiveTouch, turn it on, and set **Single-Tap** to the shortcut.

To use it in game, tap the button, speak, and tap stop.

### Modes

Set by the end of the URL:

- `mode=chat`: presses Enter, pastes the text, presses Enter. The chat box must be closed first, or the first Enter sends whatever is already in it.
- `mode=send`: pastes and presses Enter. Use it when the chat box is already open.
- `mode=type`: pastes only.
- `&lang=uk` or similar sets the language. The default is English.

`POST /type` takes plain text instead of audio, which is handy for testing.

Notes from real use:

- **Pasting, not typing:** games under Wine drop characters sent faster than their input loop polls. Pasting one block is reliable.
- **Ctrl+V under Wine:** a bare modifier flag sent with the key arrives as a plain `v`. The server holds a real Left Ctrl with short pauses around the V.
- **Clipboard:** your previous clipboard is restored after each paste.

## Hermes setup

See `hermes/webhook-route.example.yaml` for the webhook route. The clients sign requests with Hermes' generic HMAC scheme: `X-Webhook-Signature-V2` = hex HMAC-SHA256 of `"<timestamp>.<body>"`.

If Hermes' `voice.auto_tts` is on, it would also speak every webhook reply. Copy `hermes/webhook_text_only/` into Hermes' plugins dir and enable it to keep these replies as text.

## License

MIT
