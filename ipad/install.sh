#!/usr/bin/env bash
# Installs the iPad stream-dictation server for the current user. Run from the repo's ipad/ dir.
# Usage: ./install.sh http://your-server:8000 [wayland-display]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
server="${1:-http://localhost:8000}"
display="${2:-wayland-1}"

for c in wtype wl-copy wl-paste; do
  command -v "$c" >/dev/null || { echo "missing $c: install wtype and wl-clipboard" >&2; exit 1; }
done

install -Dm755 "$here/stream_dictate.py" ~/.local/bin/stream-dictate
install -Dm644 "$here/stream-dictate.service" ~/.config/systemd/user/stream-dictate.service

mkdir -p ~/.config/dictate
if [ ! -s ~/.config/dictate/ipad-token ]; then
  (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > ~/.config/dictate/ipad-token)
fi
cat > ~/.config/dictate/ipad.env <<EOF
WHISPER_URL=${server%/}/v1/audio/transcriptions
STREAM_WAYLAND_DISPLAY=$display
EOF

systemctl --user daemon-reload
systemctl --user enable --now stream-dictate.service
echo "Running on port 8650. Token for the iOS Shortcut (X-Token header):"
cat ~/.config/dictate/ipad-token
