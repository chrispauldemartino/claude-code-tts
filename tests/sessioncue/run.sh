#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-sessioncue-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export CLAUDE_TTS_SESSIONS_DIR="$TEST_ROOT/sessions"
export CLAUDE_VOICE_CONFIG="$TEST_ROOT/voice-config"
export CLAUDE_TTS_FOREGROUND_ALLOWLIST="$TEST_ROOT/foreground-sessions"
export CLAUDE_TTS_NO_SYNC=1
export ELLE_PRIMARY_WORKTREE="$TEST_ROOT/primary"

META="$ROOT/bin/session-metadata.py"

assert_eq() {
    local want="$1"
    local got="$2"
    local label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s\n  want: %s\n   got: %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

register() {
    python3 "$META" register \
        --source "${1:-Claude Code}" \
        --session-id "$2" \
        --cwd "$3" \
        --transcript-path "${4:-}"
}

mkdir -p "$TEST_ROOT/plain"

# Tier 1a: explicit handoff environment wins.
env_result="$(ELLE_HANDOFF_ID=49 register "Claude Code" "env-session" "$TEST_ROOT/plain")"
assert_eq "handoff 49" "$(printf '%s' "$env_result" | jq -r .display_name)" "ELLE_HANDOFF_ID display name"
assert_eq "handoff forty-nine" "$(printf '%s' "$env_result" | jq -r .speech_name)" "ELLE_HANDOFF_ID speech name"
assert_eq "handoff_env" "$(printf '%s' "$env_result" | jq -r .name_provenance)" "ELLE_HANDOFF_ID provenance"

# Tier 1b: marker in the git worktree root is found from a nested cwd.
mkdir -p "$TEST_ROOT/marker-root/subdir"
git -C "$TEST_ROOT/marker-root" init -q
printf '%s\n' '{"id": 46}' > "$TEST_ROOT/marker-root/.elle-current-handoff"
marker_result="$(register "Claude Code" "marker-session" "$TEST_ROOT/marker-root/subdir")"
assert_eq "handoff 46" "$(printf '%s' "$marker_result" | jq -r .display_name)" "handoff marker display name"
assert_eq "handoff_marker" "$(printf '%s' "$marker_result" | jq -r .name_provenance)" "handoff marker provenance"

# Tier 2: handoff_<N> cwd/worktree basename.
mkdir -p "$TEST_ROOT/handoff_27"
basename_result="$(register "Claude Code" "basename-session" "$TEST_ROOT/handoff_27")"
assert_eq "handoff 27" "$(printf '%s' "$basename_result" | jq -r .display_name)" "handoff basename display name"
assert_eq "worktree_name" "$(printf '%s' "$basename_result" | jq -r .name_provenance)" "handoff basename provenance"

# Tier 3: configured primary worktree with a .git common directory.
mkdir -p "$ELLE_PRIMARY_WORKTREE"
git -C "$ELLE_PRIMARY_WORKTREE" init -q
primary_result="$(register "Claude Code" "primary-session" "$ELLE_PRIMARY_WORKTREE")"
assert_eq "main session" "$(printf '%s' "$primary_result" | jq -r .display_name)" "primary worktree display name"
assert_eq "primary_worktree" "$(printf '%s' "$primary_result" | jq -r .name_provenance)" "primary worktree provenance"

# Tier 4: latest real-shape Claude custom-title record.
transcript="$TEST_ROOT/title.jsonl"
printf '%s\n' \
    '{"type":"custom-title","customTitle":"older_title","sessionId":"title-session"}' \
    '{"type":"assistant","message":{"content":[]}}' \
    '{"type":"custom-title","customTitle":"Release-Train 7","sessionId":"title-session"}' \
    > "$transcript"
title_result="$(register "Claude Code" "title-session" "$TEST_ROOT/plain" "$transcript")"
assert_eq "Release-Train 7" "$(printf '%s' "$title_result" | jq -r .display_name)" "latest custom title"
assert_eq "Release Train seven" "$(printf '%s' "$title_result" | jq -r .speech_name)" "custom-title speech normalization"
assert_eq "custom_title" "$(printf '%s' "$title_result" | jq -r .name_provenance)" "custom-title provenance"

# Tier 5: deterministic adjective-noun fallback is persisted.
generated_first="$(register "Codex" "01234567-89ab-cdef-0123-456789abcdef" "$TEST_ROOT/plain")"
generated_second="$(register "Codex" "01234567-89ab-cdef-0123-456789abcdef" "$TEST_ROOT/plain")"
assert_eq "generated" "$(printf '%s' "$generated_first" | jq -r .name_provenance)" "generated provenance"
assert_eq "$(printf '%s' "$generated_first" | jq -r .display_name)" "$(printf '%s' "$generated_second" | jq -r .display_name)" "generated nickname persistence"
test -f "$(printf '%s' "$generated_first" | jq -r .registry_path)"

# Explicit override wins over all automatic tiers.
override_result="$(python3 "$META" override --source "Claude Code" --session-id "env-session" --name "Night_Owl-8")"
assert_eq "Night_Owl-8" "$(printf '%s' "$override_result" | jq -r .display_name)" "override display name"
assert_eq "Night Owl eight" "$(printf '%s' "$override_result" | jq -r .speech_name)" "override speech name"
assert_eq "override" "$(printf '%s' "$override_result" | jq -r .name_provenance)" "override provenance"
override_refresh="$(ELLE_HANDOFF_ID=99 register "Claude Code" "env-session" "$TEST_ROOT/plain")"
assert_eq "Night_Owl-8" "$(printf '%s' "$override_refresh" | jq -r .display_name)" "override survives refresh"

# Speech normalization strips controls, collapses separators/space, caps output,
# spells bounded numbers, and reads a short hex token character by character.
normalized="$(python3 "$META" normalize $'  handoff__49\001  ab12  very-very-very-very-very-long-session-name  ')"
assert_eq "handoff forty-nine a b one two very very" "$normalized" "speech normalization"
assert_eq "d e a d b e e f" "$(python3 "$META" normalize deadbeef)" "all-letter short hex normalization"

# SessionStart registers even before a Stop hook arrives.
session_start_dir="$TEST_ROOT/session-start"
mkdir -p "$session_start_dir"
printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"start-session\",\"cwd\":\"$session_start_dir\",\"transcript_path\":\"\"}" \
    | "$ROOT/hooks/session-start.sh"
start_result="$(python3 "$META" show --source "Claude Code" --session-id "start-session")"
assert_eq "start-session" "$(printf '%s' "$start_result" | jq -r .session_id)" "SessionStart registration"

# Status uses the hook's fail-open allowlist policy and reports the invoking
# session's resolved name/provenance.
printf '%s\n' 'voice=on' 'suppress_background=on' 'cue=session' 'cue_frequency=change' > "$CLAUDE_VOICE_CONFIG"
status_open="$(CLAUDE_CODE_SESSION_ID="start-session" "$ROOT/bin/vm-toggle.sh" status)"
printf '%s\n' "$status_open" | grep -F 'nickname_provenance=generated' >/dev/null
printf '%s\n' "$status_open" | grep -F 'allowlisted=open' >/dev/null
printf '%s\n' "$status_open" | grep -F 'voice: on (open)' >/dev/null
printf '%s\n' 'some-other-session' > "$CLAUDE_TTS_FOREGROUND_ALLOWLIST"
status_muted="$(CLAUDE_CODE_SESSION_ID="start-session" "$ROOT/bin/vm-toggle.sh" status)"
printf '%s\n' "$status_muted" | grep -F 'allowlisted=no' >/dev/null
printf '%s\n' "$status_muted" | grep -F 'voice: muted (bg)' >/dev/null
printf '%s\n' 'start-session' >> "$CLAUDE_TTS_FOREGROUND_ALLOWLIST"
status_allowed="$(CLAUDE_CODE_SESSION_ID="start-session" "$ROOT/bin/vm-toggle.sh" status)"
printf '%s\n' "$status_allowed" | grep -F 'allowlisted=yes' >/dev/null
printf '%s\n' "$status_allowed" | grep -F 'voice: on' >/dev/null

# Legacy cue=on migrates to session; explicit off remains off. Frequency has a
# separate CLI so command chaining remains unambiguous.
printf '%s\n' 'voice=on' 'cue=on' > "$CLAUDE_VOICE_CONFIG"
CLAUDE_CODE_SESSION_ID="start-session" "$ROOT/bin/vm-toggle.sh" status >/dev/null
assert_eq "session" "$(awk -F= '$1 == "cue" {print $2}' "$CLAUDE_VOICE_CONFIG")" "legacy cue migration"
"$ROOT/bin/vm-toggle.sh" cue off >/dev/null
"$ROOT/bin/vm-toggle.sh" status >/dev/null
assert_eq "off" "$(awk -F= '$1 == "cue" {print $2}' "$CLAUDE_VOICE_CONFIG")" "explicit cue off preserved"
"$ROOT/bin/vm-toggle.sh" cue session >/dev/null
"$ROOT/bin/vm-toggle.sh" cue-frequency always >/dev/null
assert_eq "always" "$(awk -F= '$1 == "cue_frequency" {print $2}' "$CLAUDE_VOICE_CONFIG")" "cue frequency CLI"

# New commands still compose with the existing chained-command parser.
CLAUDE_CODE_SESSION_ID="start-session" "$ROOT/bin/vm-toggle.sh" name Blue_Fox cue both cue-frequency change status >/dev/null
assert_eq "both" "$(awk -F= '$1 == "cue" {print $2}' "$CLAUDE_VOICE_CONFIG")" "chained cue command"
assert_eq "change" "$(awk -F= '$1 == "cue_frequency" {print $2}' "$CLAUDE_VOICE_CONFIG")" "chained frequency command"
chained_name="$(python3 "$META" show --source "Claude Code" --session-id "start-session")"
assert_eq "Blue_Fox" "$(printf '%s' "$chained_name" | jq -r .display_name)" "chained name override"

# The full listener remains type-safe and optional manifest fields keep legacy
# decoding source-compatible.
swiftc -typecheck \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$ROOT/cmd/skip-listener/main.swift" \
    "$ROOT/cmd/skip-listener/StopGeneration.swift" \
    "$ROOT/cmd/skip-listener/StopAllArchive.swift"

echo "session cue tests: PASS"
