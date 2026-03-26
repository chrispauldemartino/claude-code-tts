#!/bin/bash

# Advanced Voice Mode Hook — reads /tmp/claude-voice-config for toggle state
# No config file = default mode (speak first sentence only, no mic)

CONFIG_FILE="/tmp/claude-voice-config"
SKIP_FLAG="/tmp/claude-tts-skip"
TMP_AUDIO="/tmp/claude-tts-$$.aiff"
LISTEN_SOUND="/System/Library/Sounds/Tink.aiff"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_BIN="$PLUGIN_DIR/bin"

read_config() {
    local key="$1"
    local default="$2"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

has_config() {
    [ -f "$CONFIG_FILE" ]
}

# Read JSON from stdin, extract message
json=$(cat)
msg=$(echo "$json" | jq -r '.last_assistant_message // .stop_hook_message // .message // .content // ""' 2>/dev/null)

[ -z "$msg" ] || [ ${#msg} -lt 30 ] && exit 0

rm -f "$SKIP_FLAG"

strip_markdown() {
    local text="$1"
    local code_mode="${2:-silent}"

    if [ "$code_mode" = "silent" ]; then
        echo "$text" | awk '
            /^```/ {
                if (in_code) { in_code = 0; print "See code on screen." }
                else { in_code = 1 }
                next
            }
            in_code { next }
            { print }
        '
    else
        # narrate mode: skip code blocks entirely, keep surrounding text
        echo "$text" | awk '
            /^```/ {
                if (in_code) { in_code = 0 }
                else { in_code = 1 }
                next
            }
            in_code { next }
            { print }
        '
    fi | sed -E \
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
    local rate="${2:-200}"
    local vol="${3:-1.0}"
    [ -f "$SKIP_FLAG" ] && return
    echo "$text" | say -r "$rate" -o "$TMP_AUDIO" 2>/dev/null \
        && afplay --volume "$vol" "$TMP_AUDIO" 2>/dev/null
    rm -f "$TMP_AUDIO"
}

speak_sentences() {
    local text="$1"
    local rate="${2:-200}"
    local vol="${3:-1.0}"
    echo "$text" | sed -E 's/([.!?]) /\1\n/g' | while IFS= read -r sentence; do
        [ -f "$SKIP_FLAG" ] && break
        [ -z "$sentence" ] && continue
        echo "$sentence" | say -r "$rate" -o "$TMP_AUDIO" 2>/dev/null \
            && afplay --volume "$vol" "$TMP_AUDIO" 2>/dev/null
        rm -f "$TMP_AUDIO"
    done
}

start_skip_listener() {
    pkill -f "skip-listener" 2>/dev/null
    "$PLUGIN_BIN/skip-listener" --timeout 300 &
    SKIP_LISTENER_PID=$!
    disown $SKIP_LISTENER_PID 2>/dev/null
}

stop_skip_listener() {
    touch "/tmp/claude-tts-skip-listener-stop" 2>/dev/null
    sleep 0.2
    kill $SKIP_LISTENER_PID 2>/dev/null 2>&1
}

if has_config; then
    VOICE=$(read_config "voice" "off")
    MIC=$(read_config "mic" "off")
    CUE=$(read_config "cue" "off")
    SPEED=$(read_config "speed" "200")
    VOLUME=$(read_config "volume" "normal")
    SUMMARY=$(read_config "summary" "off")
    CODE=$(read_config "code" "silent")

    VOL_LEVEL="1.0"
    [ "$VOLUME" = "quiet" ] && VOL_LEVEL="0.3"

    # --- VOICE OUTPUT ---
    if [ "$VOICE" = "on" ]; then
        start_skip_listener

        if [ "$SUMMARY" = "on" ]; then
            # Extract [SUMMARY: ...] marker
            summary_text=$(echo "$msg" | sed -n 's/.*\[SUMMARY: \(.*\)\].*/\1/p' | head -1)
            if [ -n "$summary_text" ]; then
                speak "$summary_text" "$SPEED" "$VOL_LEVEL"
            else
                # Fallback: first sentence
                first=$(echo "$msg" | sed 's/\..*/./' | head -c 200)
                speak "$first" "$SPEED" "$VOL_LEVEL"
            fi
        else
            # Full response (markdown-stripped)
            cleaned=$(strip_markdown "$msg" "$CODE")
            speak_sentences "$cleaned" "$SPEED" "$VOL_LEVEL"
        fi

        stop_skip_listener
        rm -f "$SKIP_FLAG"
    fi

    # --- CUE ---
    if [ "$CUE" = "on" ] && [ ! -f "$SKIP_FLAG" ]; then
        speak "Your turn" "$SPEED" "$VOL_LEVEL"
    fi

    # --- MIC ACTIVATION ---
    if [ "$MIC" = "on" ]; then
        pkill -f "voice-input" 2>/dev/null
        pkill -f "whisper-stream" 2>/dev/null
        rm -f /tmp/claude-voice-input-stop

        (
            sleep 0.3
            afplay "$LISTEN_SOUND" 2>/dev/null &
            "$PLUGIN_BIN/voice-input" --timeout 60
        ) &
        disown
    fi
else
    # --- DEFAULT MODE (no config) ---
    if [ ${#msg} -ge 30 ]; then
        start_skip_listener
        summary=$(echo "$msg" | sed 's/\..*/./' | head -c 200)
        speak "$summary" 200 1.0
        stop_skip_listener
        rm -f "$SKIP_FLAG"
    fi
fi
