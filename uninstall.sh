#!/usr/bin/env bash
# Stops and removes smart-power. Your config is kept unless you pass --purge.
set -u

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/smart-power"

systemctl --user disable --now smart-power.service 2>/dev/null || true
rm -f "$UNIT_DIR/smart-power.service" "$HOME/.local/bin/smart-power.sh"
systemctl --user daemon-reload

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONF_DIR"
  echo "removed config too"
fi

command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set balanced 2>/dev/null
echo "uninstalled. Profile set back to balanced."
