#!/usr/bin/env bash
# Installs smart-power for the current user and starts it at every login.
# Run from the folder that contains smart-power.sh. No sudo needed.
set -eu

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/smart-power"

for f in smart-power.sh smart-power.service config.example; do
  [ -f "$SRC_DIR/$f" ] || { echo "missing $f next to install.sh" >&2; exit 1; }
done

command -v powerprofilesctl >/dev/null 2>&1 || {
  echo "powerprofilesctl not found. Install power-profiles-daemon first:" >&2
  echo "  sudo apt install power-profiles-daemon" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

install -m 755 "$SRC_DIR/smart-power.sh" "$BIN_DIR/smart-power.sh"
install -m 644 "$SRC_DIR/smart-power.service" "$UNIT_DIR/smart-power.service"

# never overwrite a config the user already has
if [ ! -f "$CONF_DIR/config" ]; then
  install -m 644 "$SRC_DIR/config.example" "$CONF_DIR/config"
  echo "created $CONF_DIR/config"
else
  echo "kept existing $CONF_DIR/config"
fi

systemctl --user daemon-reload
systemctl --user enable smart-power.service
systemctl --user restart smart-power.service

echo
echo "installed. It will start automatically at login."
echo "  status: systemctl --user status smart-power"
echo "  logs:   journalctl --user -u smart-power -f"
