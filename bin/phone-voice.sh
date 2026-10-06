#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${PHONE_VOICE_TESTING:-}" = "1" ] && [ -n "${CLAUDE_TTS_PHONE_STATE_DIR:-}" ]; then
    STATE_DIR="$CLAUDE_TTS_PHONE_STATE_DIR"
else
    STATE_DIR="$HOME/.claude-tts-phone"
fi
QUEUE_DIR="$STATE_DIR/queue"
TOKEN_FILE="$STATE_DIR/token"
SPEED_FILE="$STATE_DIR/speed"
PID_FILE="$STATE_DIR/server.pid"
PORT="${PHONE_VOICE_PORT:-8765}"

usage() {
    echo "Usage: phone-voice.sh enroll|unenroll|status|speed <0.5-3.0>|serve|stop" >&2
}

ensure_state() {
    umask 077
    mkdir -p "$QUEUE_DIR"
    chmod 700 "$STATE_DIR" "$QUEUE_DIR"
    [ -f "$SPEED_FILE" ] || printf '1\n' > "$SPEED_FILE"
}

ensure_token() {
    if [ ! -s "$TOKEN_FILE" ]; then
        python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE" || return 1
    fi
    chmod 600 "$TOKEN_FILE"
}

owned_server_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid command_line
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null)"
    case "$command_line" in
        *"/phone-audio-server.py"*"$STATE_DIR"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_owned_server() {
    if ! owned_server_running; then
        rm -f "$PID_FILE"
        return 1
    fi
    local pid attempts=0
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || return 1
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Phone audio server did not stop cleanly (PID $pid)." >&2
        return 1
    fi
    rm -f "$PID_FILE"
    return 0
}

command_name="${1:-}"
case "$command_name" in
    enroll)
        ensure_state || exit 1
        ensure_token || exit 1
        : > "$STATE_DIR/enrolled"
        chmod 600 "$STATE_DIR/enrolled"
        echo "Phone voice enrolled."
        ;;
    unenroll)
        if owned_server_running; then
            stop_owned_server || exit 1
        else
            rm -f "$PID_FILE"
        fi
        rm -f "$STATE_DIR/enrolled"
        rm -f "$TOKEN_FILE"
        echo "Phone voice unenrolled."
        ;;
    status)
        if [ -f "$STATE_DIR/enrolled" ]; then enrolled=yes; else enrolled=no; fi
        speed="$(cat "$SPEED_FILE" 2>/dev/null || echo 1)"
        if owned_server_running; then running=yes; else running=no; fi
        echo "enrolled=$enrolled"
        echo "server_running=$running"
        echo "speed=$speed"
        echo "state=$STATE_DIR"
        ;;
    speed)
        value="${2:-}"
        if ! python3 - "$value" <<'PY'
import sys
try:
    value = float(sys.argv[1])
except (IndexError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if 0.5 <= value <= 3.0 else 1)
PY
        then
            echo "Speed must be between 0.5 and 3.0." >&2
            exit 2
        fi
        ensure_state || exit 1
        printf '%s\n' "$value" > "$SPEED_FILE"
        chmod 600 "$SPEED_FILE"
        echo "Phone playback speed set to $value."
        ;;
    serve)
        if [ ! -f "$STATE_DIR/enrolled" ]; then
            echo "Phone voice is not enrolled. Run: $0 enroll" >&2
            exit 1
        fi
        if ! command -v tailscale >/dev/null 2>&1; then
            echo "tailscale is unavailable; refusing to bind." >&2
            exit 1
        fi
        bind_ip="$(tailscale ip -4 2>/dev/null | sed -n '1p')"
        if [ -z "$bind_ip" ]; then
            echo "No Tailscale IPv4 address is available; refusing to bind." >&2
            exit 1
        fi
        ensure_state || exit 1
        ensure_token || exit 1
        exec python3 "$PLUGIN_DIR/bin/phone-audio-server.py" \
            --bind "$bind_ip" --port "$PORT" --state "$STATE_DIR" \
            --web-root "$PLUGIN_DIR/web/phone-player" --token-file "$TOKEN_FILE"
        ;;
    stop)
        if [ ! -f "$PID_FILE" ]; then
            echo "Phone audio server is not running."
            exit 0
        fi
        if stop_owned_server; then
            echo "Phone audio server stopped."
        else
            echo "Removed stale phone audio server PID."
            rm -f "$PID_FILE"
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
