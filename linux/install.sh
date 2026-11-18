#!/usr/bin/env bash
# Installs the dictation client for the current user. Run from the repo's linux/ dir.
# Root-only steps (packages, input/uinput access) are printed instead of run when sudo needs a password.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
server="${1:-http://localhost:8000}"

need_pkgs=()
python3 -c 'import evdev' 2>/dev/null || need_pkgs+=(evdev)
command -v parec >/dev/null || need_pkgs+=(parec)
wayland=0
for s in $(loginctl list-sessions --no-legend | awk -v u="$USER" '$3==u{print $1}'); do
  loginctl show-session "$s" -p Type --value | grep -q wayland && wayland=1
done
if [ $wayland = 1 ]; then
  command -v wl-copy >/dev/null || need_pkgs+=(wl-clipboard)
else
  command -v xclip >/dev/null || need_pkgs+=(xclip)
fi

root_cmds=()
if [ ${#need_pkgs[@]} -gt 0 ]; then
  pk=()
  for p in "${need_pkgs[@]}"; do case $p in evdev) pk+=(python3-evdev);; parec) pk+=(pulseaudio-utils);; *) pk+=("$p");; esac; done
  if command -v dnf >/dev/null; then root_cmds+=("dnf install -y ${pk[*]}"); else root_cmds+=("apt-get install -y ${pk[*]}"); fi
fi
id -nG | grep -qw input || root_cmds+=("usermod -aG input $USER")
if [ ! -f /etc/udev/rules.d/60-dictate-uinput.rules ]; then
  root_cmds+=("install -m644 $here/60-dictate-uinput.rules /etc/udev/rules.d/ && echo uinput > /etc/modules-load.d/dictate-uinput.conf && udevadm control --reload && udevadm trigger --name-match=uinput")
fi

if [ ${#root_cmds[@]} -gt 0 ]; then
  if sudo -n true 2>/dev/null; then
    for c in "${root_cmds[@]}"; do sudo -n bash -c "$c"; done
  else
    echo "Run these as root, then log out and back in, then re-run this script:"
    for c in "${root_cmds[@]}"; do echo "  sudo bash -c '$c'"; done
    exit 2
  fi
fi

install -Dm755 "$here/dictate.py" "$HOME/.local/bin/dictate"
mkdir -p "$HOME/.config/dictate"
if [ ! -f "$HOME/.config/dictate/config.json" ]; then
  sed "s|__SERVER__|$server|" "$here/config.example.json" > "$HOME/.config/dictate/config.json"
fi
install -Dm644 "$here/dictate.service" "$HOME/.config/systemd/user/dictate.service"
systemctl --user daemon-reload
systemctl --user enable dictate.service
systemctl --user restart dictate.service || true
echo "Installed. Logs: journalctl --user -u dictate -f"
if ! id -nG "$USER" | grep -qw input || ! [ -w /dev/uinput ]; then
  echo "Group/uinput access changed: log out and back in for it to take effect."
fi
