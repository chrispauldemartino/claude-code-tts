#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-h47-reliability.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export CLAUDE_TTS_FOREGROUND_ALLOWLIST="$TEST_ROOT/foreground-sessions"
export CLAUDE_VOICE_CONFIG="$TEST_ROOT/voice-config"

AUTO_SPEAK="$ROOT/hooks/auto-speak.sh"
VM_TOGGLE="$ROOT/bin/vm-toggle.sh"
failures=0

check() {
    local label="$1"
    shift
    if "$@"; then
        printf 'PASS: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

check_self_heal_idempotent() {
    local guard
    guard="$(sed -n '/Feature B: Foreground allowlist suppression guard/,/end suppression guard/p' "$AUTO_SPEAK")"
    grep -F 'grep -Fxq -- "$SESSION_ID" "$FOREGROUND_ALLOWLIST"' <<< "$guard" >/dev/null &&
        grep -F "printf '%s\\n' \"\$SESSION_ID\" >> \"\$FOREGROUND_ALLOWLIST\"" <<< "$guard" >/dev/null
}

check_doctor_failure() {
    grep -F '[FAIL] active session NOT in foreground allowlist' "$VM_TOGGLE" >/dev/null
}

check_no_cue_off_update() {
    ! grep -F 'update_toggle "cue" "off"' "$VM_TOGGLE" >/dev/null
}

check_remote_focus_timeline() {
    local function_body
    function_body="$(sed -n '/^remote_focus_session() {/,/^}/p' "$VM_TOGGLE")"
    grep -F "printf 'timeline\\n' > /tmp/claude-tts-log-command" <<< "$function_body" >/dev/null &&
        ! grep -F "printf 'latest\\n' > /tmp/claude-tts-log-command" <<< "$function_body" >/dev/null
}

check_title_log_only() {
    local voice_block
    voice_block="$(sed -n '/# --- VOICE OUTPUT/,/# --- MIC ACTIVATION ---/p' "$AUTO_SPEAK")"
    grep -F 'title_prefix=$(build_spoken_title_prefix' <<< "$voice_block" >/dev/null &&
        grep -F 'prefix (log only, not spoken)' <<< "$voice_block" >/dev/null &&
        ! grep -E '(cleaned|new_text|filtered_text)=.*title_prefix|printf .*title_prefix.*REMOTE_TTS' <<< "$voice_block" >/dev/null
}

check_allowlist_clear_audit() {
    local off_path audit_count audit_line
    off_path="$(sed -n '/^[[:space:]]*off)/,/^[[:space:]]*;;/p' "$VM_TOGGLE")"
    audit_count="$(grep -c 'allowlist-clear' <<< "$off_path" || true)"
    audit_line="$(grep -B1 'rm -f "$FOREGROUND_ALLOWLIST"' <<< "$off_path" | head -1)"
    [ "$audit_count" -eq 1 ] &&
        grep -F 'allowlist-clear' <<< "$audit_line" >/dev/null &&
        grep -F 'vm off' <<< "$audit_line" >/dev/null &&
        grep -F '$$' <<< "$audit_line" >/dev/null &&
        grep -F '${PPID:-' <<< "$audit_line" >/dev/null &&
        grep -F '$allowlist_session_count' <<< "$audit_line" >/dev/null &&
        grep -F "date '+%Y-%m-%d %H:%M:%S'" <<< "$audit_line" >/dev/null &&
        grep -F '|| true' <<< "$audit_line" >/dev/null
}

check_allowlist_env_override() {
    grep -F 'FOREGROUND_ALLOWLIST="${CLAUDE_TTS_FOREGROUND_ALLOWLIST:-/tmp/claude-tts-foreground-sessions}"' "$AUTO_SPEAK" >/dev/null
}

check 'auto-speak self-heal append is idempotent' check_self_heal_idempotent
check 'doctor reports an active session missing from the allowlist' check_doctor_failure
check 'vm-toggle never disables cue while handling another command' check_no_cue_off_update
check 'remote focus resumes the playback timeline' check_remote_focus_timeline
check 'spoken text remains body-only while title prefixes are log-only' check_title_log_only
check '/vm off audits the allowlist clear immediately before removal' check_allowlist_clear_audit
check 'auto-speak honors CLAUDE_TTS_FOREGROUND_ALLOWLIST' check_allowlist_env_override

if [ "$failures" -ne 0 ]; then
    printf '%d reliability check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'h47 reliability tests: PASS\n'
