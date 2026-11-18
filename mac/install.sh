#!/usr/bin/env bash
# Builds HermesVoice.app into ~/Applications and starts it at login via a LaunchAgent.
#
# First install (writes the config):
#   WHISPER_URL=http://my-server:8000 HERMES_URL=http://my-hermes:8644/webhooks/voice \
#   HERMES_SECRET=<route secret> ./install.sh
# Optional: WHISPER_FALLBACK, HERMES_FALLBACK (tried when the primary can't be reached),
#           SOURCE (shown to Hermes, default "Mac"), BUNDLE_ID (default local.hermesvoice).
# Later runs only rebuild; the config and bundle id are kept.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/HermesVoice.app"
support="$HOME/Library/Application Support/HermesVoice"
cfg="$support/config.json"
identity="HermesVoice Local Signing"

mkdir -p "$app/Contents/MacOS" "$support"

if [ ! -f "$cfg" ]; then
  : "${WHISPER_URL:?set WHISPER_URL for the first install}" "${HERMES_URL:?set HERMES_URL}" "${HERMES_SECRET:?set HERMES_SECRET}"
  umask 077
  WHISPER_URL="$WHISPER_URL" HERMES_URL="$HERMES_URL" HERMES_SECRET="$HERMES_SECRET" \
  WHISPER_FALLBACK="${WHISPER_FALLBACK:-}" HERMES_FALLBACK="${HERMES_FALLBACK:-}" \
  SOURCE="${SOURCE:-Mac}" BUNDLE_ID="${BUNDLE_ID:-local.hermesvoice}" python3 - "$cfg" <<'PY'
import json, os, sys
e = os.environ
c = {"whisper": e["WHISPER_URL"], "model": "whisper-1", "hermes_url": e["HERMES_URL"],
     "hermes_secret": e["HERMES_SECRET"], "source": e["SOURCE"], "min_hold": 0.3, "tail": 0.2,
     "bundle_id": e["BUNDLE_ID"]}
for k, v in (("whisper_fallback", e["WHISPER_FALLBACK"]), ("hermes_fallback", e["HERMES_FALLBACK"])):
    if v:
        c[k] = v
open(sys.argv[1], "w").write(json.dumps(c, indent=2) + "\n")
PY
fi
bundle_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("bundle_id", "local.hermesvoice"))' "$cfg")"
agent="$HOME/Library/LaunchAgents/$bundle_id.plist"

swiftc -O -o "$app/Contents/MacOS/HermesVoice" "$here/HermesVoice.swift"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>HermesVoice</string>
  <key>CFBundleExecutable</key><string>HermesVoice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSMicrophoneUsageDescription</key><string>Records your voice while you hold Right Option, to send to Hermes.</string>
</dict></plist>
PLIST

# Input Monitoring grants are tied to the code signature. An ad-hoc signature changes with every build,
# so sign with a long-lived self-signed identity (created once in the login keychain) to keep the grant.
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  (umask 077
   openssl req -x509 -newkey rsa:2048 -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 7300 -nodes \
     -subj "/CN=$identity" -addext "extendedKeyUsage=critical,codeSigning" \
     -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false" 2>/dev/null
   openssl pkcs12 -export -legacy -out "$tmp/id.p12" -inkey "$tmp/k.pem" -in "$tmp/c.pem" -passout pass:hv 2>/dev/null \
     || openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/k.pem" -in "$tmp/c.pem" -passout pass:hv
   security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P hv -T /usr/bin/codesign >/dev/null) \
    || echo "could not create the signing identity; signing ad hoc (re-grant Input Monitoring after each rebuild)"
  rm -rf "$tmp"
fi
codesign --force --sign "$identity" "$app" 2>/dev/null || codesign --force --sign - "$app"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$bundle_id</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/HermesVoice</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "Installed. Log: $support/hermesvoice.log"
echo "First time: drag $app into System Settings > Privacy & Security > Input Monitoring, then:"
echo "  launchctl kickstart -k gui/\$(id -u)/$bundle_id"
