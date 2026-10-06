#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHONE_VOICE_PATH="${PHONE_VOICE_PATH:-$SCRIPT_DIR/phone-voice.sh}"
VM_TOGGLE_PATH="${VM_TOGGLE_PATH:-$SCRIPT_DIR/vm-toggle.sh}"

if [ "${1:-}" = "phone" ]; then
    shift
    exec "$PHONE_VOICE_PATH" "$@"
fi

exec "$VM_TOGGLE_PATH" "$@"
