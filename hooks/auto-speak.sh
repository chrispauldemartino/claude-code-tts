#!/bin/bash

# Advanced Voice Mode Hook — reads /tmp/claude-voice-config for toggle state
# No config file = default mode (speak first sentence only, no mic)

CONFIG_FILE="/tmp/claude-voice-config"
SKIP_FLAG="/tmp/claude-tts-skip"
PAUSE_FLAG="/tmp/claude-tts-pause"
TTS_PLAYING_FLAG="/tmp/claude-tts-playing"
MIC_LISTENING_FLAG="/tmp/claude-voice-listening"
TMP_AUDIO="/tmp/claude-tts-$$.aiff"
PENDING_FILE="/tmp/claude-tts-pending"
FORWARD_FLAG="/tmp/claude-tts-forward"
REWIND_FLAG="/tmp/claude-tts-rewind"
LAST_TEXT="/tmp/claude-tts-last-text"
LAST_SPEED="/tmp/claude-tts-last-speed"
LAST_VOLUME="/tmp/claude-tts-last-volume"
HISTORY_DIR="/tmp/claude-tts-history-$PPID"
LISTEN_SOUND="/System/Library/Sounds/Tink.aiff"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_BIN="$PLUGIN_DIR/bin"
INVOCATION_ID="$$-$(date +%s)"

trap 'rm -f "$TMP_AUDIO"' EXIT

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

[ -z "$msg" ] && exit 0

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

# Sentence-indexed playback with forward/rewind support
speak_sentences() {
    local text="$1"
    local rate="${2:-200}"
    local vol="${3:-1.0}"

    # Split into sentence file for indexed access
    local sentences_file="/tmp/claude-tts-sentences-$$"
    echo "$text" | sed -E 's/([.!?]) /\1\n/g' | grep -v '^[[:space:]]*$' > "$sentences_file"
    local total
    total=$(wc -l < "$sentences_file" | tr -d ' ')
    local idx=1

    while [ "$idx" -le "$total" ]; do
        [ -f "$SKIP_FLAG" ] && break

        # Check forward flag (+3 sentences)
        if [ -f "$FORWARD_FLAG" ]; then
            rm -f "$FORWARD_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            idx=$((idx + 3))
            [ "$idx" -gt "$total" ] && idx=$total
            continue
        fi

        # Check rewind flag (-3 sentences)
        if [ -f "$REWIND_FLAG" ]; then
            rm -f "$REWIND_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            idx=$((idx - 3))
            [ "$idx" -lt 1 ] && idx=1
            continue
        fi

        local sentence
        sentence=$(sed -n "${idx}p" "$sentences_file")
        [ -z "$sentence" ] && { idx=$((idx + 1)); continue; }

        echo "$sentence" | say -r "$rate" -o "$TMP_AUDIO" 2>/dev/null \
            && afplay --volume "$vol" "$TMP_AUDIO" 2>/dev/null
        rm -f "$TMP_AUDIO"
        idx=$((idx + 1))
    done

    rm -f "$sentences_file"
}

# Save text for repeat (cmd+shift) and session history (opt+shift+arrow)
save_for_repeat() {
    local text="$1"
    local speed="$2"
    local volume="$3"

    # Save for repeat
    echo "$text" > "$LAST_TEXT"
    echo "$speed" > "$LAST_SPEED"
    echo "$volume" > "$LAST_VOLUME"

    # Save to session history
    mkdir -p "$HISTORY_DIR"
    local current_total=0
    [ -f "$HISTORY_DIR/total" ] && current_total=$(cat "$HISTORY_DIR/total")
    local next=$((current_total + 1))
    local padded
    padded=$(printf "%03d" "$next")

    echo "$text" > "$HISTORY_DIR/msg-${padded}.txt"
    echo "$speed" > "$HISTORY_DIR/msg-${padded}.speed"
    echo "$volume" > "$HISTORY_DIR/msg-${padded}.volume"
    echo "$next" > "$HISTORY_DIR/total"
    echo "$next" > "$HISTORY_DIR/current"
}

start_skip_listener() {
    rm -f /tmp/claude-tts-skip-listener-stop
    pkill -f "skip-listener" 2>/dev/null
    "$PLUGIN_BIN/skip-listener" --timeout 300 &
    SKIP_LISTENER_PID=$!
    disown "$SKIP_LISTENER_PID" 2>/dev/null
}

stop_skip_listener() {
    touch "/tmp/claude-tts-skip-listener-stop" 2>/dev/null
    sleep 0.2
    [ -n "$SKIP_LISTENER_PID" ] && kill "$SKIP_LISTENER_PID" 2>/dev/null
}

if has_config; then
    VOICE=$(read_config "voice" "off")
    MIC=$(read_config "mic" "off")
    CUE=$(read_config "cue" "off")
    SPEED=$(read_config "speed" "200")
    [[ "$SPEED" =~ ^[0-9]+$ ]] || SPEED=200
    VOLUME=$(read_config "volume" "normal")
    SUMMARY=$(read_config "summary" "off")
    CODE=$(read_config "code" "silent")

    VOL_LEVEL="1.0"
    [ "$VOLUME" = "quiet" ] && VOL_LEVEL="0.3"

    # --- DEDUPLICATION ---
    # Only speak the last message when multiple Stop hooks fire in rapid succession.
    # Write our ID, wait briefly, check if a newer invocation superseded us.
    if [ "$VOICE" = "on" ]; then
        echo "$INVOCATION_ID" > "$PENDING_FILE"
        sleep 0.5
        current_pending=$(cat "$PENDING_FILE" 2>/dev/null)
        if [ "$current_pending" != "$INVOCATION_ID" ]; then
            exit 0
        fi
    fi

    # Clean up stale flags from previous cycle
    rm -f "$PAUSE_FLAG" "$TTS_PLAYING_FLAG" "$MIC_LISTENING_FLAG" /tmp/claude-voice-input-stop
    rm -f "$FORWARD_FLAG" "$REWIND_FLAG" /tmp/claude-tts-next-msg /tmp/claude-tts-prev-msg

    # Start skip/pause listener (covers BOTH TTS and mic phases)
    if [ "$VOICE" = "on" ] || [ "$MIC" = "on" ]; then
        start_skip_listener
    fi

    # --- VOICE OUTPUT ---
    if [ "$VOICE" = "on" ]; then
        touch "$TTS_PLAYING_FLAG"

        if [ "$SUMMARY" = "on" ]; then
            # Extract [SUMMARY: ...] marker
            summary_text=$(echo "$msg" | sed -n 's/.*\[SUMMARY: \(.*\)\].*/\1/p' | head -1)
            if [ -n "$summary_text" ]; then
                cleaned_text="$summary_text"
            else
                # Fallback: first sentence
                cleaned_text=$(echo "$msg" | sed 's/\. [A-Z].*/\./' | head -c 200)
            fi
            save_for_repeat "$cleaned_text" "$SPEED" "$VOL_LEVEL"
            speak "$cleaned_text" "$SPEED" "$VOL_LEVEL"
        else
            # Full response (markdown-stripped)
            cleaned_text=$(strip_markdown "$msg" "$CODE")
            save_for_repeat "$cleaned_text" "$SPEED" "$VOL_LEVEL"
            speak_sentences "$cleaned_text" "$SPEED" "$VOL_LEVEL"
        fi

        rm -f "$TTS_PLAYING_FLAG" "$PAUSE_FLAG" "$SKIP_FLAG" "$PENDING_FILE"
    fi

    # --- MIC ACTIVATION ---
    # Skip mic if user already submitted (Enter during TTS creates stop flag)
    if [ "$MIC" = "on" ] && [ ! -f /tmp/claude-voice-input-stop ]; then
        pkill -f "voice-input" 2>/dev/null
        pkill -f "whisper-stream" 2>/dev/null
        rm -f /tmp/claude-voice-input-stop

        # Set preferred mic device if configured
        MIC_DEVICE=$(read_config "mic_device" "")
        if [ -n "$MIC_DEVICE" ] && command -v SwitchAudioSource >/dev/null 2>&1; then
            SwitchAudioSource -s "$MIC_DEVICE" -t input 2>/dev/null
        fi

        PLAY_CUE="$CUE"
        (
            sleep 0.3
            [ "$PLAY_CUE" = "on" ] && afplay "$LISTEN_SOUND" 2>/dev/null
            touch "$MIC_LISTENING_FLAG"
            "$PLUGIN_BIN/voice-input" --timeout 60
            rm -f "$MIC_LISTENING_FLAG" "$PAUSE_FLAG"
            # Signal skip-listener to stop (mic phase done)
            touch /tmp/claude-tts-skip-listener-stop
        ) &
        disown
    else
        # No mic phase — stop skip-listener now
        if [ "$VOICE" = "on" ]; then
            stop_skip_listener
        fi
    fi
else
    # --- DEFAULT MODE (no config) ---
    start_skip_listener
    summary=$(echo "$msg" | sed 's/\. [A-Z].*/\./' | head -c 200)
    speak "$summary" 200 1.0
    stop_skip_listener
    rm -f "$SKIP_FLAG"
fi
