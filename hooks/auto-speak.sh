#!/bin/bash

# Auto-speak hook for Claude Code
# Default: speaks first sentence only
# Voice mode (/tmp/claude-voice-mode exists): speaks full response + "Your turn" cue

TMP_AUDIO="/tmp/claude-tts-$$.aiff"
VOICE_MODE_FLAG="/tmp/claude-voice-mode"

# Read JSON from stdin, extract message
json=$(cat)
msg=$(echo "$json" | jq -r '.stop_hook_message // .message // .content // ""' 2>/dev/null)

# Skip if empty or too short
[ -z "$msg" ] || [ ${#msg} -lt 30 ] && exit 0

strip_markdown() {
    # Replace code blocks (``` ... ```) with "See code on screen."
    # Use awk for multi-line code block replacement
    echo "$1" | awk '
        /^```/ {
            if (in_code) {
                in_code = 0
                print "See code on screen."
            } else {
                in_code = 1
            }
            next
        }
        in_code { next }
        { print }
    ' | sed -E \
        -e 's/^#{1,6} //' \
        -e 's/\*\*([^*]*)\*\*/\1/g' \
        -e 's/\*([^*]*)\*/\1/g' \
        -e 's/__([^_]*)__/\1/g' \
        -e 's/_([^_]*)_/\1/g' \
        -e 's/`([^`]*)`/\1/g' \
        -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
        -e 's/^- //' \
        -e 's/^\* //' \
        -e 's/^[0-9]+\. //' \
        -e '/^[[:space:]]*$/d'
}

speak() {
    local text="$1"
    local rate="${2:-}"
    local rate_flag=""
    [ -n "$rate" ] && rate_flag="-r $rate"
    echo "$text" | say $rate_flag -o "$TMP_AUDIO" 2>/dev/null && afplay "$TMP_AUDIO" 2>/dev/null
    rm -f "$TMP_AUDIO"
}

if [ -f "$VOICE_MODE_FLAG" ]; then
    # Voice mode: speak full response (markdown-stripped) + "Your turn" cue
    cleaned=$(strip_markdown "$msg")
    speak "$cleaned" 200
    speak "Your turn" 200
else
    # Default: speak first sentence only (max 200 chars)
    summary=$(echo "$msg" | sed 's/\..*/./' | head -c 200)
    speak "$summary"
fi
