#!/bin/bash

# Register session identity before the first Stop event. Metadata registration is
# best-effort: a naming failure must never block Claude Code startup.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
json=$(cat)
session_id=$(printf '%s' "$json" | jq -r '.session_id // ""' 2>/dev/null)
cwd=$(printf '%s' "$json" | jq -r '.cwd // ""' 2>/dev/null)
transcript_path=$(printf '%s' "$json" | jq -r '.transcript_path // ""' 2>/dev/null)
source_label="Claude Code"

case "$transcript_path" in
    *"/.codex/sessions/"*) source_label="Codex" ;;
esac

if [ -n "$session_id" ]; then
    python3 "$PLUGIN_DIR/bin/session-metadata.py" register \
        --source "$source_label" \
        --session-id "$session_id" \
        --cwd "${cwd:-$PWD}" \
        --transcript-path "$transcript_path" \
        >/dev/null 2>&1 || true
fi

exit 0
