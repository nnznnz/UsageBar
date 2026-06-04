#!/usr/bin/env bash
#
# Optional: start UsageBar automatically at login via a per-user LaunchAgent.
# Run AFTER ./build.sh has produced UsageBar.app.
#
#   scripts/install-login-item.sh           # install + start now
#   scripts/install-login-item.sh --remove  # stop + uninstall
#
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="ai.usagebar.personal"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_BIN="$(pwd)/UsageBar.app/Contents/MacOS/UsageBar"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed login item."
  exit 0
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Build first:  ./build.sh   (couldn't find $APP_BIN)" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>$LABEL</string>
  <key>ProgramArguments</key> <array><string>$APP_BIN</string></array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <false/>
  <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. UsageBar will start at login and is running now."
echo "Remove with:  scripts/install-login-item.sh --remove"
