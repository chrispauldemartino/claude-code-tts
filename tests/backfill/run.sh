#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-backfill-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s\n  want: %s\n   got: %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

run_export() {
    CLAUDE_TTS_BACKFILL_OUTBOX="$TEST_ROOT/outbox" \
    CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" \
    CLAUDE_TTS_SESSIONS_DIR="$TEST_ROOT/sessions" \
        python3 "$ROOT/bin/backfill-transcript.py" "$@"
}

printf '%s\n' 'summary=off' 'code=silent' > "$TEST_ROOT/config"
printf '%s\n' '{"id":"codex-session","thread_name":"Release Train 7"}' > "$TEST_ROOT/codex-index.jsonl"
claude_result="$(run_export 'Claude Code' claude-session "$ROOT/tests/backfill/fixtures/claude.jsonl" 10)"
assert_eq "2" "$(printf '%s' "$claude_result" | jq -r .exported)" "Claude completed turns"
claude_batch="$(printf '%s' "$claude_result" | jq -r .batch_dir)"
assert_eq "First answer starts. First answer finishes." "$(cat "$claude_batch/000.full.txt")" "tool cycle grouped"
assert_eq "Selected branch answer." "$(cat "$claude_batch/001.full.txt")" "newest branch selected"
assert_eq "backfill" "$(jq -r .origin "$claude_batch/000.meta.json")" "backfill origin"
assert_eq "false" "$(jq -r .autoplay "$claude_batch/000.meta.json")" "autoplay disabled"
assert_eq "claude-session" "$(cat "$claude_batch/000.session")" "session sidecar"
! rg -q 'Wrong branch|Partial answer|Sidechain|tool output|secret' "$claude_batch"

codex_result="$(CODEX_SESSION_INDEX="$TEST_ROOT/codex-index.jsonl" run_export Codex codex-session "$ROOT/tests/backfill/fixtures/codex.jsonl" 10)"
assert_eq "2" "$(printf '%s' "$codex_result" | jq -r .exported)" "Codex duplicate representations"
codex_batch="$(printf '%s' "$codex_result" | jq -r .batch_dir)"
assert_eq "Canonical answer one." "$(cat "$codex_batch/000.full.txt")" "response_item preferred"
assert_eq "Fallback answer two." "$(cat "$codex_batch/001.full.txt")" "event fallback retained"
assert_eq "Release Train seven" "$(cat "$codex_batch/000.session_name")" "Codex index session name"

printf '%s\n' 'summary=on' 'code=silent' > "$TEST_ROOT/config"
summary="$(printf '%s' 'First complete sentence. Second useful sentence. Third sentence is extra.' | CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" "$ROOT/bin/prepare-speech.sh")"
assert_eq "First complete sentence. Second useful sentence." "$summary" "summary fallback consumes stdin"
explicit="$(printf '%s' 'Long body. [SUMMARY: First chosen sentence. Second chosen sentence. Third chosen sentence.] More detail.' | CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" "$ROOT/bin/prepare-speech.sh")"
assert_eq "First chosen sentence. Second chosen sentence. Third chosen sentence." "$explicit" "explicit summary is not fallback-truncated"

printf '%s\n' 'summary=off' 'code=silent' > "$TEST_ROOT/config"
full="$(printf '%s' $'**Heading**\n\n```sh\necho hidden\n```\nVisible text.' | CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" "$ROOT/bin/prepare-speech.sh")"
assert_eq $'Heading\nshell snippet with 1 lines.\nVisible text.' "$full" "summary off matches live transform and markdown strip"
code_only="$(printf '%s' $'```python\nprint("hello")\n```' | CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" "$ROOT/bin/prepare-speech.sh")"
assert_eq "python snippet with 1 lines." "$code_only" "code-only answer remains speakable"
control_output="$(printf '%s' 'Voice mode ON — global speech enabled' | CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" "$ROOT/bin/prepare-speech.sh")"
assert_eq "" "$control_output" "voice control output excluded"
if run_export 'Claude Code' claude-session "$ROOT/tests/backfill/fixtures/claude.jsonl" 101 >/dev/null 2>&1; then
    echo "FAIL: exporter accepted N > 100" >&2
    exit 1
fi

swiftc \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$ROOT/cmd/skip-listener/BackfillImport.swift" \
    "$ROOT/tests/backfill/BackfillImportHarness.swift" \
    -o "$TEST_ROOT/backfill-import-harness"
"$TEST_ROOT/backfill-import-harness"
bash "$ROOT/tests/backfill/test-bridge-backfill.sh"

# CLI resolves the invoking session through Feature A's registry, accepts the
# default/ranged command shape, and never needs the live queue.
CLAUDE_TTS_SESSIONS_DIR="$TEST_ROOT/sessions" python3 "$ROOT/bin/session-metadata.py" register \
    --source "Claude Code" --session-id claude-session --cwd "$TEST_ROOT" \
    --transcript-path "$ROOT/tests/backfill/fixtures/claude.jsonl" >/dev/null
cli_output="$(CLAUDE_CODE_SESSION_ID=claude-session \
    CLAUDE_TTS_NO_SYNC=1 CLAUDE_TTS_BACKFILL_NO_WAIT=1 \
    CLAUDE_TTS_BACKFILL_OUTBOX="$TEST_ROOT/cli-outbox" \
    CLAUDE_TTS_BACKFILL_STATUS_DIR="$TEST_ROOT/status" \
    CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" \
    CLAUDE_TTS_SESSIONS_DIR="$TEST_ROOT/sessions" \
    "$ROOT/bin/vm-toggle.sh" backfill 2)"
printf '%s\n' "$cli_output" | grep -F 'Backfill queued: batch ' >/dev/null
default_output="$(CLAUDE_CODE_SESSION_ID=claude-session \
    CLAUDE_TTS_NO_SYNC=1 CLAUDE_TTS_BACKFILL_NO_WAIT=1 \
    CLAUDE_TTS_BACKFILL_OUTBOX="$TEST_ROOT/cli-default-outbox" \
    CLAUDE_TTS_BACKFILL_STATUS_DIR="$TEST_ROOT/status" \
    CLAUDE_VOICE_CONFIG="$TEST_ROOT/config" \
    CLAUDE_TTS_SESSIONS_DIR="$TEST_ROOT/sessions" \
    "$ROOT/bin/vm-toggle.sh" backfill)"
printf '%s\n' "$default_output" | grep -F 'Backfill queued: batch ' >/dev/null
test ! -d "$TEST_ROOT/live-queue"
if CLAUDE_TTS_NO_SYNC=1 "$ROOT/bin/vm-toggle.sh" backfill 101 >/dev/null 2>&1; then
    echo "FAIL: CLI accepted N > 100" >&2
    exit 1
fi
mkdir -p "$TEST_ROOT/status"
printf '%s\n' '{"imported":2,"skipped":1,"dupes":1}' > "$TEST_ROOT/status/example.json"
status_output="$(CLAUDE_TTS_BACKFILL_STATUS_DIR="$TEST_ROOT/status" CLAUDE_TTS_NO_SYNC=1 "$ROOT/bin/vm-toggle.sh" backfill status)"
assert_eq "Backfill status: imported 2, skipped 1 (dupes 1)" "$status_output" "CLI status"

swiftc -typecheck \
    -module-cache-path "$TEST_ROOT/full-module-cache" \
    "$ROOT/cmd/skip-listener/main.swift" \
    "$ROOT/cmd/skip-listener/ProcessLaunch.swift" \
    "$ROOT/cmd/skip-listener/StopGeneration.swift" \
    "$ROOT/cmd/skip-listener/StopAllArchive.swift" \
    "$ROOT/cmd/skip-listener/BackfillImport.swift"

echo "backfill tests: PASS"
