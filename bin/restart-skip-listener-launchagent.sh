#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="$PLUGIN_ROOT/bin/SkipListener.app"
EXE="$PLUGIN_ROOT/bin/SkipListener.app/Contents/MacOS/skip-listener"
PLIST="$HOME/Library/LaunchAgents/com.elle.skip-listener.plist"
DOMAIN="gui/$(id -u)"
LABEL="$DOMAIN/com.elle.skip-listener"

get_pid() {
    pgrep -f "$EXE" | head -n 1 || true
}

if [ ! -x "$EXE" ]; then
    echo "Missing bundled executable: $EXE" >&2
    exit 1
fi

if ! launchctl print "$LABEL" >/dev/null 2>&1; then
    if [ -f "$PLIST" ]; then
        launchctl bootstrap "$DOMAIN" "$PLIST"
    else
        echo "LaunchAgent not loaded and plist missing: $PLIST" >&2
        exit 1
    fi
fi

pkill -f "$EXE" 2>/dev/null || true
sleep 1
launchctl kickstart -k "$LABEL" 2>/dev/null || true

for _ in 1 2 3 4 5; do
    PID="$(get_pid)"
    if [ -n "${PID:-}" ] && [ "$PID" != "0" ]; then
        break
    fi
    sleep 1
done

PID="$(get_pid)"

if [ -z "${PID:-}" ] || [ "$PID" = "0" ]; then
    echo "skip-listener LaunchAgent did not produce a live pid" >&2
    exit 1
fi

echo "skip-listener pid: $PID"
echo "skip-listener exe: $EXE"
