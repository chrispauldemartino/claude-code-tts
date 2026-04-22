#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="$PLUGIN_ROOT/bin/SkipListener.app"
EXE="$APP/Contents/MacOS/skip-listener"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.elle.skip-listener.plist"
DOMAIN="gui/$(id -u)"
LABEL="$DOMAIN/com.elle.skip-listener"
RESTART_SCRIPT="$PLUGIN_ROOT/bin/restart-skip-listener-launchagent.sh"

if [ ! -x "$EXE" ]; then
    echo "Missing bundled executable: $EXE" >&2
    exit 1
fi

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.elle.skip-listener</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXE</string>
    </array>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.elleai.skip-listener</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/elle-skip-listener.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/elle-skip-listener.err</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST" >/dev/null

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || \
    launchctl bootout "$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$LABEL" 2>/dev/null || true

if [ -x "$RESTART_SCRIPT" ]; then
    "$RESTART_SCRIPT"
else
    launchctl kickstart -k "$LABEL"
fi

echo "Installed LaunchAgent: $PLIST"
echo "App: $APP"
echo "Executable: $EXE"
