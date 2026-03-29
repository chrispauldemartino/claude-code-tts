#!/bin/bash

# Voice Mode Stop Hook — reads /tmp/claude-voice-config for toggle state
# No config file = silent exit. Daemon managed by vm-toggle.sh.

CONFIG_FILE="/tmp/claude-voice-config"
SKIP_FLAG="/tmp/claude-tts-skip"
PAUSE_FLAG="/tmp/claude-tts-pause"
TTS_PLAYING_FLAG="/tmp/claude-tts-playing"
MIC_LISTENING_FLAG="/tmp/claude-voice-listening"
TMP_AUDIO="/tmp/claude-tts-$$.aiff"
PENDING_FILE="/tmp/claude-tts-pending"
PENDING_TS="/tmp/claude-tts-pending-ts"
PID_FILE="/tmp/claude-skip-listener.pid"
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
TTS_LOCK="/tmp/claude-tts-speaking.lock"
DETAIL_CACHE="/tmp/claude-tts-detail-cache"
DRILL_DOWN_FLAG="/tmp/claude-tts-drill-down"

# Audio mutex — wait for any other instance to finish speaking before we start
acquire_tts_lock() {
    while ! mkdir "$TTS_LOCK" 2>/dev/null; do
        if [ -f "$TTS_LOCK/pid" ]; then
            lock_pid=$(cat "$TTS_LOCK/pid" 2>/dev/null)
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                sleep 0.3
            else
                # Stale lock from a crashed instance — reclaim
                rm -rf "$TTS_LOCK"
            fi
        else
            rm -rf "$TTS_LOCK"
        fi
    done
    echo $$ > "$TTS_LOCK/pid"
}

release_tts_lock() {
    rm -rf "$TTS_LOCK"
}

trap 'rm -f "$TMP_AUDIO"; release_tts_lock' EXIT

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

# Save transcript path and reset nav index so navigation starts from latest message
transcript_path=$(echo "$json" | jq -r '.transcript_path // ""' 2>/dev/null)
[ -n "$transcript_path" ] && echo "$transcript_path" > /tmp/claude-tts-transcript-path
rm -f /tmp/claude-tts-nav-index

# Primary: get last_assistant_message from hook JSON (always current)
last_msg=$(echo "$json" | jq -r '.last_assistant_message // ""' 2>/dev/null)

# Debug log for TTS pipeline diagnostics
DEBUG_LOG="/tmp/claude-tts-debug.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] === Stop hook fired ===" >> "$DEBUG_LOG"
echo "  last_msg length: ${#last_msg}, preview: ${last_msg:0:80}" >> "$DEBUG_LOG"

# Secondary: try transcript parser for multi-block responses (text before AND after tool calls)
msg=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    msg=$(python3 -c "
import json, sys

debug_log = '/tmp/claude-tts-debug.log'
def dbg(msg):
    with open(debug_log, 'a') as f:
        f.write(f'  [parser] {msg}\n')

last = sys.argv[2] if len(sys.argv) > 2 else ''
texts = []
found = False
with open(sys.argv[1]) as f:
    lines = f.readlines()
dbg(f'transcript lines: {len(lines)}')
for line in reversed(lines):
    line = line.strip()
    if not line: continue
    try: entry = json.loads(line)
    except: continue
    t = entry.get('type','')
    if t == 'assistant':
        content = entry.get('message',{}).get('content',[])
        if isinstance(content, list):
            for b in content:
                if b.get('type') == 'text' and b.get('text','').strip():
                    texts.append(b['text'])
                    found = True
    elif t == 'user' and found:
        content = entry.get('message',{}).get('content',[])
        has_text = False
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get('type') == 'text' and b.get('text','').strip():
                    has_text = True
                    break
        elif isinstance(content, str) and content.strip():
            has_text = True
        if has_text:
            break
texts.reverse()
result = '\n<<MSG_BREAK>>\n'.join(texts)
dbg(f'collected {len(texts)} text blocks')
# Prefer transcript parser result (multiple blocks) over single last_assistant_message.
# Only fall back to last_msg if parser found nothing.
if len(texts) > 1:
    dbg(f'using transcript result ({len(texts)} blocks)')
    print(result)
elif len(texts) == 1:
    # Single block: verify it looks right, otherwise use last_msg
    if last and last.strip() and last.strip()[:50] not in result:
        dbg(f'single block mismatch — using last_msg')
        print(last)
    else:
        dbg(f'single block matches — using transcript')
        print(result)
else:
    dbg(f'no blocks found — using last_msg')
    print(last)
" "$transcript_path" "$last_msg" 2>>"$DEBUG_LOG")
fi

# Fallback if transcript parsing failed entirely
if [ -z "$msg" ]; then
    echo "  transcript parser returned empty — falling back to last_msg" >> "$DEBUG_LOG"
    msg="$last_msg"
fi
if [ -z "$msg" ]; then
    msg=$(echo "$json" | jq -r '.stop_hook_message // .message // .content // ""' 2>/dev/null)
fi

# Log final msg stats
msg_breaks=$(echo "$msg" | grep -c '<<MSG_BREAK>>' || true)
echo "  final msg: ${#msg} chars, $msg_breaks breaks, preview: ${msg:0:80}" >> "$DEBUG_LOG"

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

# Check if message is VM status output (don't save these for repeat)
is_vm_status() {
    local text="$1"
    case "$text" in
        "Voice mode"*|"Listen mode"*|"Dictation mode"*|"Quiet mode"*|\
        "Repeating last"*|"Nothing to repeat"*|"Done."*|\
        "TTS:"*|"Mic:"*|"Cue:"*|"Usage: /vm"*)
            return 0 ;;
    esac
    return 1
}

# Save text for repeat (cmd+shift) and session history (opt+shift+arrow)
save_for_repeat() {
    local text="$1"
    local speed="$2"
    local volume="$3"

    # Skip saving VM status messages — preserve actual response for repeat
    is_vm_status "$text" && return

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

# Safety net: restart daemon if voice mode is on but daemon crashed
ensure_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0  # Running
        fi
    fi
    # Daemon not running — restart it
    nohup "$PLUGIN_BIN/skip-listener" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    disown 2>/dev/null
}

# Debounce: write text to pending file, wait for more hooks, then speak
debounce_and_speak() {
    local text="$1"
    local speed="$2"
    local vol="$3"
    local code_mode="$4"
    local summary_mode="$5"

    # Append text to pending file
    echo "$text" >> "$PENDING_FILE"
    # Write timestamp for debounce detection
    date +%s%N > "$PENDING_TS"
    local my_ts
    my_ts=$(cat "$PENDING_TS")

    # Debounce loop: wait 600ms, check if another hook updated the timestamp
    local cycles=0
    while [ "$cycles" -lt 3 ]; do
        sleep 0.6
        [ -f "$SKIP_FLAG" ] && { rm -f "$PENDING_FILE" "$PENDING_TS"; return; }
        local current_ts
        current_ts=$(cat "$PENDING_TS" 2>/dev/null)
        if [ "$current_ts" = "$my_ts" ]; then
            break  # No new hooks fired — we're the last writer
        fi
        my_ts="$current_ts"
        cycles=$((cycles + 1))
    done

    # Try to acquire lock and speak
    acquire_tts_lock

    # Check if another hook already spoke (pending file cleared)
    if [ ! -f "$PENDING_FILE" ]; then
        release_tts_lock
        return
    fi

    # Read all accumulated text
    local all_text
    all_text=$(cat "$PENDING_FILE")
    rm -f "$PENDING_FILE" "$PENDING_TS"

    if [ -z "$all_text" ]; then release_tts_lock; return; fi
    if [ -f "$SKIP_FLAG" ]; then release_tts_lock; return; fi

    # Split into message segments (separated by <<MSG_BREAK>>)
    local seg_dir="/tmp/claude-tts-segments-$$"
    rm -rf "$seg_dir"
    mkdir -p "$seg_dir"

    # Write each segment to its own file
    python3 -c "
import sys
text = sys.stdin.read()
parts = text.split('\n<<MSG_BREAK>>\n')
for i, p in enumerate(parts):
    p = p.strip()
    if p:
        with open(f'$seg_dir/seg-{i:03d}', 'w') as f:
            f.write(p)
" <<< "$all_text"

    local segment_count
    segment_count=$(ls "$seg_dir"/seg-* 2>/dev/null | wc -l | tr -d ' ')
    [ "$segment_count" -eq 0 ] && segment_count=1


    # If no segments were created, write the whole text as one
    if [ ! -f "$seg_dir/seg-000" ]; then
        echo "$all_text" > "$seg_dir/seg-000"
    fi

    # Strip markdown from full text for repeat/history
    local full_cleaned
    full_cleaned=$(strip_markdown "$all_text" "$code_mode" | sed 's/<<MSG_BREAK>>//g')
    save_for_repeat "$full_cleaned" "$speed" "$vol"

    # Speak each segment — skip (cmd+cmd) advances to next segment

    touch "$TTS_PLAYING_FLAG"
    local seg_idx=0
    for seg_file in "$seg_dir"/seg-*; do
        [ -f "$seg_file" ] || continue
        seg_idx=$((seg_idx + 1))


        # Check skip flag — if set, clear it and advance to next segment
        if [ -f "$SKIP_FLAG" ]; then
            rm -f "$SKIP_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            continue
        fi

        local segment transformed_seg cleaned_seg
        segment=$(cat "$seg_file")
        # Transform structured data (tables/lists) before markdown stripping
        transformed_seg=$(echo "$segment" | python3 "$PLUGIN_BIN/transform-for-speech.py" 2>/dev/null)
        [ -z "$transformed_seg" ] && transformed_seg="$segment"
        cleaned_seg=$(strip_markdown "$transformed_seg" "$code_mode")
        if [ -z "$cleaned_seg" ]; then
            continue
        fi

        speak_sentences "$cleaned_seg" "$speed" "$vol"

        # After speaking, check if skip was hit during this segment
        if [ -f "$SKIP_FLAG" ] && [ "$seg_idx" -lt "$segment_count" ]; then
            rm -f "$SKIP_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            continue
        fi
    done
    rm -rf "$seg_dir"
    rm -f "$TTS_PLAYING_FLAG" "$PAUSE_FLAG" "$SKIP_FLAG"

    release_tts_lock
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

    # Takeover: if a PREVIOUS hook from THIS session is still speaking, kill it.
    # Cross-session TTS is left alone — the lock serializes between sessions.
    if [ -d "$TTS_LOCK" ] && [ -f "$TTS_LOCK/pid" ]; then
        old_pid=$(cat "$TTS_LOCK/pid" 2>/dev/null)
        if [ -n "$old_pid" ]; then
            # Check if lock holder is from same session (same PPID = same Claude instance)
            old_ppid=$(ps -p "$old_pid" -o ppid= 2>/dev/null | tr -d ' ')
            my_ppid="$PPID"
            if [ "$old_ppid" = "$my_ppid" ] || ! kill -0 "$old_pid" 2>/dev/null; then
                # Same session or dead process — take over
                touch "$SKIP_FLAG"
                # Kill only our session's say/afplay by targeting children of the lock holder
                kill "$old_pid" 2>/dev/null
                pkill -P "$old_pid" 2>/dev/null
                sleep 0.3
                # Clean up if still held
                if [ -d "$TTS_LOCK" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                    rm -rf "$TTS_LOCK"
                fi
            fi
            # Different session, still alive — let the lock serialize (don't kill)
        fi
    fi

    # Clean up flags for fresh start
    rm -f "$SKIP_FLAG" "$PAUSE_FLAG" "$TTS_PLAYING_FLAG" "$MIC_LISTENING_FLAG" /tmp/claude-voice-input-stop
    rm -f "$FORWARD_FLAG" "$REWIND_FLAG" /tmp/claude-tts-next-msg /tmp/claude-tts-prev-msg
    rm -f "$PENDING_FILE" "$PENDING_TS"
    rm -rf "$DETAIL_CACHE"
    rm -f "$DRILL_DOWN_FLAG"

    # Safety net: ensure daemon is running
    ensure_daemon

    # --- VOICE OUTPUT ---
    if [ "$VOICE" = "on" ]; then
        if [ "$SUMMARY" = "on" ]; then
            # Extract [SUMMARY: ...] marker
            summary_text=$(echo "$msg" | sed -n 's/.*\[SUMMARY: \(.*\)\].*/\1/p' | head -1)
            if [ -n "$summary_text" ]; then
                cleaned_text="$summary_text"
            else
                cleaned_text=$(echo "$msg" | sed 's/\. [A-Z].*/\./' | head -c 200)
            fi
            # Summary mode: speak directly (short text, no debounce needed)
            acquire_tts_lock
            save_for_repeat "$cleaned_text" "$SPEED" "$VOL_LEVEL"
            touch "$TTS_PLAYING_FLAG"
            speak "$cleaned_text" "$SPEED" "$VOL_LEVEL"
            rm -f "$TTS_PLAYING_FLAG" "$PAUSE_FLAG" "$SKIP_FLAG"
            release_tts_lock
        else
            # Full response: debounce for multi-segment coalescing
            debounce_and_speak "$msg" "$SPEED" "$VOL_LEVEL" "$CODE" "$SUMMARY"
        fi
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
        ) &
        disown
    fi
else
    # No config = text mode, no TTS
    exit 0
fi
