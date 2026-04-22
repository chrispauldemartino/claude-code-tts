#!/bin/bash
# tts-bridge.sh — Runs on MBP, pulls TTS entries from Mac Mini,
# writes to local /tmp/claude-tts-queue/ for skip-listener to consume.
# skip-listener handles sentence-by-sentence playback + all shortcuts.

HOST="${1:-mac-mini-ts}"
REMOTE_DIR="/tmp/claude-tts-remote"
LOCAL_QUEUE="/tmp/claude-tts-queue"
STOP_FLAG="/tmp/claude-tts-bridge-stop"

mkdir -p "$LOCAL_QUEUE"
rm -f "$STOP_FLAG"

while [ ! -f "$STOP_FLAG" ]; do
    entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" "ls $REMOTE_DIR/*.txt 2>/dev/null" 2>/dev/null)

    if [ -n "$entries" ]; then
        for txt_file in $entries; do
            base="${txt_file%.txt}"
            entry_name=$(basename "$base")

            text=$(ssh -o BatchMode=yes "$HOST" "cat '$txt_file' 2>/dev/null")
            speed=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.speed' 2>/dev/null")
            volume=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.volume' 2>/dev/null")
            source=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.source' 2>/dev/null")
            session=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.session' 2>/dev/null")
            block=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.block' 2>/dev/null")
            raw=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.raw' 2>/dev/null")
            normalized=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.normalized' 2>/dev/null")
            ssh -o BatchMode=yes "$HOST" "rm -f '$txt_file' '${base}.speed' '${base}.volume' '${base}.source' '${base}.session' '${base}.block' '${base}.raw' '${base}.normalized'" 2>/dev/null

            [ -z "$speed" ] && speed="300"
            [ -z "$volume" ] && volume="1.0"
            [ -z "$text" ] && continue

            local_entry="$LOCAL_QUEUE/entry-${entry_name}"
            staging_entry="$LOCAL_QUEUE/.entry-${entry_name}.tmp"
            rm -rf "$staging_entry" "$local_entry"
            mkdir -p "$staging_entry"
            echo "$text" > "$staging_entry/text"
            echo "$speed" > "$staging_entry/speed"
            echo "$volume" > "$staging_entry/volume"
            echo "$source" > "$staging_entry/source"
            [ -n "$session" ] && echo "$session" > "$staging_entry/session"
            [ -n "$block" ] && echo "$block" > "$staging_entry/block"
            [ -n "$raw" ] && printf '%s' "$raw" > "$staging_entry/raw"
            [ -n "$normalized" ] && printf '%s' "$normalized" > "$staging_entry/normalized"
            mv "$staging_entry" "$local_entry"

            # Save for repeat — skip-listener reads these for cmd+shift repeat
            echo "$text" > /tmp/claude-tts-last-text
            echo "$speed" > /tmp/claude-tts-last-speed
            echo "$volume" > /tmp/claude-tts-last-volume

            # Save to session history for message nav (opt+shift+arrow)
            HISTORY_DIR="/tmp/claude-tts-history-$$"
            mkdir -p "$HISTORY_DIR"
            total=0
            [ -f "$HISTORY_DIR/total" ] && total=$(cat "$HISTORY_DIR/total")
            next=$((total + 1))
            padded=$(printf "%03d" "$next")
            echo "$text" > "$HISTORY_DIR/msg-${padded}.txt"
            echo "$speed" > "$HISTORY_DIR/msg-${padded}.speed"
            echo "$volume" > "$HISTORY_DIR/msg-${padded}.volume"
            echo "$source" > "$HISTORY_DIR/msg-${padded}.source"
            [ -n "$session" ] && echo "$session" > "$HISTORY_DIR/msg-${padded}.session"
            echo "$next" > "$HISTORY_DIR/total"
            echo "$next" > "$HISTORY_DIR/current"
            echo "$next" > /tmp/claude-tts-repeat-anchor
            echo "$HISTORY_DIR" > /tmp/claude-tts-history-dir
        done
    fi

    sleep 0.5
done
