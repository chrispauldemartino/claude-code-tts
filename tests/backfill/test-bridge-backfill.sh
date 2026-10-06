#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-backfill-bridge.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/remote-outbox/batch-1" "$TEST_ROOT/remote-live"

printf '%s\n' '{"batch_id":"batch-1","item_count":0,"source":"Claude Code","session_id":"s1"}' > "$TEST_ROOT/remote-outbox/batch-1/batch.json"
printf '%s\n' 'generation=3' 'timestamp=0' 'autoplay_hold=0' > "$TEST_ROOT/generation"

cat > "$TEST_ROOT/bin/ssh" <<'MOCK'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        mockhost) shift; break ;;
        *) shift ;;
    esac
done
/bin/bash -c "$*"
MOCK
cat > "$TEST_ROOT/bin/scp" <<'MOCK'
#!/bin/bash
source_path=""
destination=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q|-r) shift ;;
        -o) shift 2 ;;
        mockhost:*) source_path="${1#mockhost:}"; shift ;;
        *) destination="$1"; shift ;;
    esac
done
cp -R "$source_path" "$destination"
MOCK
chmod +x "$TEST_ROOT/bin/ssh" "$TEST_ROOT/bin/scp"

run_bridge() {
    PATH="$TEST_ROOT/bin:$PATH" \
    CLAUDE_TTS_BRIDGE_ONCE=1 \
    CLAUDE_TTS_REMOTE_DIR="$TEST_ROOT/remote-live" \
    CLAUDE_TTS_LOCAL_QUEUE="$TEST_ROOT/live-queue" \
    CLAUDE_TTS_BRIDGE_STAGING="$TEST_ROOT/live-staging" \
    CLAUDE_TTS_BACKFILL_OUTBOX="$TEST_ROOT/remote-outbox" \
    CLAUDE_TTS_BACKFILL_STATUS_DIR="$TEST_ROOT/remote-status" \
    CLAUDE_TTS_BACKFILL_INBOX="$TEST_ROOT/inbox" \
    CLAUDE_TTS_BACKFILL_ACKS="$TEST_ROOT/acks" \
    CLAUDE_TTS_BACKFILL_STAGING="$TEST_ROOT/backfill-staging" \
    CLAUDE_TTS_BRIDGE_STOP="$TEST_ROOT/stop" \
    CLAUDE_TTS_STOP_GENERATION_FILE="$TEST_ROOT/generation" \
        "$ROOT/bin/tts-bridge.sh" mockhost
}

run_bridge
test -d "$TEST_ROOT/inbox/batch-1"
test -d "$TEST_ROOT/remote-outbox/batch-1"
test "$(cat "$TEST_ROOT/inbox/batch-1/.generation")" = "3"
test ! -e "$TEST_ROOT/live-queue/entry-batch-1"

mkdir -p "$TEST_ROOT/acks"
printf '%s' '{"batch_id":"batch-1","status":"imported","imported":0,"skipped":0,"dupes":0}' > "$TEST_ROOT/acks/batch-1.imported"
run_bridge
test ! -e "$TEST_ROOT/remote-outbox/batch-1"
test -f "$TEST_ROOT/remote-outbox/batch-1.imported"
test -f "$TEST_ROOT/remote-status/batch-1.json"
test ! -e "$TEST_ROOT/acks/batch-1.imported"

echo "backfill bridge test: PASS"
