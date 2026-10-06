#!/bin/bash
# tts-bridge.sh — Runs on MBP, pulls TTS entries from Mac Mini,
# writes to local /tmp/claude-tts-queue/ for skip-listener to consume.
# skip-listener handles sentence-by-sentence playback + all shortcuts.

HOST="${1:-mac-mini-ts}"
REMOTE_DIR="${CLAUDE_TTS_REMOTE_DIR:-/tmp/claude-tts-remote}"
LOCAL_QUEUE="${CLAUDE_TTS_LOCAL_QUEUE:-/tmp/claude-tts-queue}"
BRIDGE_STAGING="${CLAUDE_TTS_BRIDGE_STAGING:-/tmp/claude-tts-bridge-staging}"
REMOTE_BACKFILL_OUTBOX="${CLAUDE_TTS_BACKFILL_OUTBOX:-/tmp/claude-tts-backfill-outbox}"
REMOTE_BACKFILL_STATUS="${CLAUDE_TTS_BACKFILL_STATUS_DIR:-/tmp/claude-tts-backfill-status}"
LOCAL_BACKFILL_INBOX="${CLAUDE_TTS_BACKFILL_INBOX:-/tmp/claude-tts-backfill-inbox}"
LOCAL_BACKFILL_ACKS="${CLAUDE_TTS_BACKFILL_ACKS:-/tmp/claude-tts-backfill-acks}"
BACKFILL_STAGING="${CLAUDE_TTS_BACKFILL_STAGING:-/tmp/claude-tts-backfill-staging}"
STOP_FLAG="${CLAUDE_TTS_BRIDGE_STOP:-/tmp/claude-tts-bridge-stop}"
STOP_GENERATION_FILE="${CLAUDE_TTS_STOP_GENERATION_FILE:-/tmp/claude-tts-stop-generation}"
STOP_GENERATION_FAILURE_FILE="${STOP_GENERATION_FILE}.failed"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLISH_MODE="$SCRIPT_DIR/stopall-bridge-publish-mode.sh"
# shellcheck source=stopall-lock.sh
source "$SCRIPT_DIR/stopall-lock.sh"

read_stop_generation() {
    local generation
    if [ -f "$STOP_GENERATION_FAILURE_FILE" ]; then
        printf '%s\n' "failed"
        return 0
    fi
    generation=$(awk -F= '$1 == "generation" { print $2; exit }' \
        "$STOP_GENERATION_FILE" 2>/dev/null || true)
    printf '%s\n' "${generation:-0}"
}

mkdir -p "$LOCAL_QUEUE"
mkdir -p "$BRIDGE_STAGING"
mkdir -p "$LOCAL_BACKFILL_INBOX" "$LOCAL_BACKFILL_ACKS" "$BACKFILL_STAGING"
rm -f "$STOP_FLAG"

while [ ! -f "$STOP_FLAG" ]; do
    # Publish listener acknowledgements back to the Mini before deleting the
    # retained source batch. Backfill deliberately stays outside the live
    # queue and the Stop-all transaction.
    for ack_file in "$LOCAL_BACKFILL_ACKS"/*.imported; do
        [ -f "$ack_file" ] || continue
        batch_id=$(basename "$ack_file" .imported)
        ack_payload=$(cat "$ack_file" 2>/dev/null || true)
        if printf '%s' "$ack_payload" | ssh -o BatchMode=yes "$HOST" \
            "mkdir -p '$REMOTE_BACKFILL_STATUS'; cat > '$REMOTE_BACKFILL_STATUS/$batch_id.json'; touch '$REMOTE_BACKFILL_OUTBOX/$batch_id.imported'; rm -rf '$REMOTE_BACKFILL_OUTBOX/$batch_id'" 2>/dev/null; then
            rm -f "$ack_file"
        fi
    done

    backfill_batches=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" \
        "find '$REMOTE_BACKFILL_OUTBOX' -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print 2>/dev/null" 2>/dev/null || true)
    if [ -n "$backfill_batches" ]; then
        while IFS= read -r remote_batch; do
            [ -n "$remote_batch" ] || continue
            batch_id=$(basename "$remote_batch")
            [ -d "$LOCAL_BACKFILL_INBOX/$batch_id" ] && continue
            fetch_generation=$(read_stop_generation)
            [ "$fetch_generation" = "failed" ] && fetch_generation="18446744073709551615"
            staging_batch="$BACKFILL_STAGING/$batch_id"
            rm -rf "$staging_batch"
            if scp -q -r -o ConnectTimeout=5 -o BatchMode=yes \
                "$HOST:$remote_batch" "$BACKFILL_STAGING/" 2>/dev/null; then
                printf '%s\n' "$fetch_generation" > "$staging_batch/.generation"
                mv "$staging_batch" "$LOCAL_BACKFILL_INBOX/$batch_id"
            fi
        done <<EOF
$backfill_batches
EOF
    fi

    entries=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" "ls $REMOTE_DIR/*.txt 2>/dev/null" 2>/dev/null)

    if [ -n "$entries" ]; then
        for txt_file in $entries; do
            base="${txt_file%.txt}"
            entry_name=$(basename "$base")
            fetch_generation=$(read_stop_generation)

            text=$(ssh -o BatchMode=yes "$HOST" "cat '$txt_file' 2>/dev/null")
            speed=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.speed' 2>/dev/null")
            volume=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.volume' 2>/dev/null")
            source=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.source' 2>/dev/null")
            session=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.session' 2>/dev/null")
            session_name=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.session_name' 2>/dev/null")
            block=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.block' 2>/dev/null")
            raw=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.raw' 2>/dev/null")
            normalized=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.normalized' 2>/dev/null")
            metadata=$(ssh -o BatchMode=yes "$HOST" "cat '${base}.meta.json' 2>/dev/null")
            # Keep the established at-most-once remote deletion ordering. A host
            # failure after this delete can still lose the bundle before local
            # publish; a concurrent stop marks the completed import archive-only.
            ssh -o BatchMode=yes "$HOST" "rm -f '$txt_file' '${base}.speed' '${base}.volume' '${base}.source' '${base}.session' '${base}.session_name' '${base}.block' '${base}.raw' '${base}.normalized' '${base}.meta.json'" 2>/dev/null

            [ -z "$speed" ] && speed="300"
            [ -z "$volume" ] && volume="1.0"
            [ -z "$text" ] && continue

            local_entry="$LOCAL_QUEUE/entry-${entry_name}"
            # Stage outside LOCAL_QUEUE so Stop-all cannot discard a fully
            # captured bundle after the remote at-most-once deletion.
            staging_entry="$BRIDGE_STAGING/.entry-${entry_name}.tmp"
            rm -rf "$staging_entry" "$local_entry"
            mkdir -p "$staging_entry"
            echo "$text" > "$staging_entry/text"
            echo "$speed" > "$staging_entry/speed"
            echo "$volume" > "$staging_entry/volume"
            echo "$source" > "$staging_entry/source"
            [ -n "$session" ] && echo "$session" > "$staging_entry/session"
            [ -n "$session_name" ] && printf '%s' "$session_name" > "$staging_entry/session_name"
            [ -n "$block" ] && echo "$block" > "$staging_entry/block"
            [ -n "$raw" ] && printf '%s' "$raw" > "$staging_entry/raw"
            [ -n "$normalized" ] && printf '%s' "$normalized" > "$staging_entry/normalized"
            [ -n "$metadata" ] && printf '%s' "$metadata" > "$staging_entry/meta.json"
            acquire_stop_transaction_lock
            publish_generation=$(read_stop_generation)
            publish_mode=$(bash "$PUBLISH_MODE" "$fetch_generation" "$publish_generation" 2>/dev/null || true)
            if [ "$publish_mode" != "play" ]; then
                : > "$staging_entry/archive-only"
            fi
            mv "$staging_entry" "$local_entry"

            if [ "$publish_mode" = "play" ]; then
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
                [ -n "$session_name" ] && printf '%s' "$session_name" > "$HISTORY_DIR/msg-${padded}.session_name"
                echo "$next" > "$HISTORY_DIR/total"
                echo "$next" > "$HISTORY_DIR/current"
                echo "$next" > /tmp/claude-tts-repeat-anchor
                echo "$HISTORY_DIR" > /tmp/claude-tts-history-dir
            fi
            release_stop_transaction_lock
        done
    fi

    [ "${CLAUDE_TTS_BRIDGE_ONCE:-0}" = "1" ] && break
    sleep 0.5
done
