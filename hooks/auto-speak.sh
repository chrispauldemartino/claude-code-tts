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
LOCAL_DAEMON_FLAG="/tmp/claude-tts-local-daemon"
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
ACTIVE_SEGMENT="/tmp/claude-tts-active-segment"
REPEAT_ANCHOR="/tmp/claude-tts-repeat-anchor"
BLOCK_START="/tmp/claude-tts-block-start"
BLOCK_ID_FILE="/tmp/claude-tts-current-block-id"
LAST_QUEUED_HASH="/tmp/claude-tts-last-queued-hash"
QUEUED_PREFIX="/tmp/claude-tts-queued-prefix"
QUEUED_LENGTH="/tmp/claude-tts-queued-length"
SPOKEN_HASHES="/tmp/claude-tts-spoken-hashes"
SPOKEN_HASHES_MAX=200
ACTIVE_SESSION_ID_FILE="/tmp/claude-tts-active-session-id"
ACTIVE_TRANSCRIPT_PATH_FILE="/tmp/claude-tts-active-transcript-path"
ACTIVE_SOURCE_LABEL_FILE="/tmp/claude-tts-active-source"
CLAIM_NEXT_SESSION_FILE="/tmp/claude-tts-claim-next-session"

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

write_active_segment() {
    local seg="$1"
    local total="$2"
    local preview="$3"
    local status="${4:-speaking}"
    [ ${#preview} -gt 60 ] && preview="${preview:0:57}..."
    cat > "$ACTIVE_SEGMENT" << SEGEOF
segment=$seg
total=$total
preview=$preview
status=$status
SEGEOF
}

clear_active_segment() {
    rm -f "$ACTIVE_SEGMENT"
}

# Subtitle display — writes directly to terminal via /dev/tty
# Detect terminal device from parent process (Claude Code)
TTY_DEV=""
_detect_tty() {
    [ -n "$TTY_DEV" ] && return
    local parent_tty
    parent_tty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
    if [ -n "$parent_tty" ] && [ "$parent_tty" != "??" ]; then
        TTY_DEV="/dev/$parent_tty"
        echo "$TTY_DEV" > /tmp/claude-tts-tty
    fi
}

show_subtitle() {
    [ "$SUBTITLE" != "on" ] && return
    _detect_tty
    [ -z "$TTY_DEV" ] && return
    local preview="$1"
    local cols=100
    local tty_cols
    tty_cols=$(stty size < "$TTY_DEV" 2>/dev/null | awk '{print $2}')
    if [ -n "$tty_cols" ] && [ "$tty_cols" -gt 20 ] 2>/dev/null; then
        cols=$((tty_cols - 10))
    fi
    [ ${#preview} -gt "$cols" ] && preview="${preview:0:$cols}"
    printf '\r\033[K\033[90m▶ %s\033[0m' "$preview" > "$TTY_DEV" 2>/dev/null
}

clear_subtitle() {
    [ "$SUBTITLE" != "on" ] && return
    _detect_tty
    [ -z "$TTY_DEV" ] && return
    printf '\r\033[K' > "$TTY_DEV" 2>/dev/null
}

trap 'rm -f "$TMP_AUDIO"; clear_subtitle' EXIT

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

classify_source_label() {
    local cwd="$1"
    local transcript="$2"
    local session_source="$3"

    if [[ "$transcript" == *"/.claude/projects/"* ]]; then
        echo "Claude Code"
    elif [[ "$session_source" == "exec" ]] || [[ "$session_source" == "mcp" ]] || [[ "$session_source" == \{* ]]; then
        echo ""
    elif [[ "$session_source" == "vscode" ]] || [[ "$session_source" == "cli" ]] || [[ "$session_source" == "app" ]] || [[ "$session_source" == "tui" ]]; then
        echo "Codex"
    elif [[ "$cwd" == *"elle-codex-hook"* ]] || [[ "$cwd" == *"codex-hook-live"* ]] || [[ "$transcript" == *"/.codex/sessions/"* ]]; then
        echo "Codex"
    elif [[ "$cwd" == "/Users/demo/"* ]]; then
        echo "Claude Code"
    else
        echo ""
    fi
}

claim_active_session() {
    local session_id="$1"
    local transcript="$2"
    local source_label="$3"

    if [ -n "$session_id" ]; then
        echo "$session_id" > "$ACTIVE_SESSION_ID_FILE"
    else
        rm -f "$ACTIVE_SESSION_ID_FILE"
    fi

    if [ -n "$transcript" ]; then
        echo "$transcript" > "$ACTIVE_TRANSCRIPT_PATH_FILE"
        echo "$transcript" > /tmp/claude-tts-transcript-path
    else
        rm -f "$ACTIVE_TRANSCRIPT_PATH_FILE"
    fi

    if [ -n "$source_label" ]; then
        echo "$source_label" > "$ACTIVE_SOURCE_LABEL_FILE"
    else
        rm -f "$ACTIVE_SOURCE_LABEL_FILE"
    fi

    rm -f "$CLAIM_NEXT_SESSION_FILE"
}

active_session_matches() {
    local session_id="$1"
    local transcript="$2"
    local active_session_id=""
    local active_transcript=""

    [ -f "$ACTIVE_SESSION_ID_FILE" ] && active_session_id=$(cat "$ACTIVE_SESSION_ID_FILE" 2>/dev/null)
    [ -f "$ACTIVE_TRANSCRIPT_PATH_FILE" ] && active_transcript=$(cat "$ACTIVE_TRANSCRIPT_PATH_FILE" 2>/dev/null)

    if [ -n "$active_session_id" ] && [ -n "$session_id" ] && [ "$session_id" = "$active_session_id" ]; then
        return 0
    fi

    if [ -n "$active_transcript" ] && [ -n "$transcript" ] && [ "$transcript" = "$active_transcript" ]; then
        return 0
    fi

    return 1
}

has_active_session_claim() {
    [ -f "$ACTIVE_SESSION_ID_FILE" ] || [ -f "$ACTIVE_TRANSCRIPT_PATH_FILE" ]
}

has_config() {
    [ -f "$CONFIG_FILE" ]
}

is_title_only_payload() {
    local text="$1"
    [ -z "$text" ] && return 1
    printf '%s' "$text" | jq -e 'type == "object" and (keys | sort) == ["title"]' >/dev/null 2>&1
}

extract_payload_title() {
    python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)

try:
    parsed = json.loads(raw)
except Exception:
    sys.exit(0)

if isinstance(parsed, dict):
    title = str(parsed.get("title", "")).strip()
    if title:
        print(title, end="")
'
}

# Read JSON from stdin, extract message
json=$(cat)

# If a file read is active, queue terminal TTS text for after the read finishes
READING_FILE_FLAG="/tmp/claude-tts-reading-file"
DEFERRED_QUEUE="/tmp/claude-tts-deferred-queue"
if [ -f "$READING_FILE_FLAG" ]; then
    # Extract text and append to deferred queue instead of dropping
    deferred_msg=$(echo "$json" | jq -r '.last_assistant_message // ""' 2>/dev/null)
    if [ -n "$deferred_msg" ]; then
        mkdir -p "$DEFERRED_QUEUE"
        echo "$deferred_msg" > "$DEFERRED_QUEUE/entry-$(date +%s%N)"
    fi
    exit 0
fi

# Detect hook event type (PostToolUse vs Stop)
HOOK_EVENT=$(echo "$json" | jq -r '.hook_event_name // .hook_event // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$json" | jq -r '.session_id // ""' 2>/dev/null)
SESSION_CWD=$(echo "$json" | jq -r '.cwd // ""' 2>/dev/null)
SESSION_SOURCE=$(echo "$json" | jq -r '.source // ""' 2>/dev/null)

# Save transcript path — nav index persists across responses so user can keep navigating back
transcript_path=$(echo "$json" | jq -r '.transcript_path // ""' 2>/dev/null)

# Primary: get last_assistant_message from hook JSON (always current)
last_msg=$(echo "$json" | jq -r '.last_assistant_message // ""' 2>/dev/null)
payload_title=$(printf '%s' "$last_msg" | extract_payload_title)

SOURCE_LABEL=$(classify_source_label "$SESSION_CWD" "$transcript_path" "$SESSION_SOURCE")

# Debug log for TTS pipeline diagnostics
DEBUG_LOG="/tmp/claude-tts-debug.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] === Stop hook fired ===" >> "$DEBUG_LOG"
echo "  raw_json_keys: $(echo "$json" | jq -r 'keys | join(",")' 2>/dev/null)" >> "$DEBUG_LOG"
echo "  hook_event: ${HOOK_EVENT:-<empty>}" >> "$DEBUG_LOG"
echo "  session_id: ${SESSION_ID:-<empty>}" >> "$DEBUG_LOG"
echo "  cwd: ${SESSION_CWD:-<empty>}" >> "$DEBUG_LOG"
echo "  source: ${SESSION_SOURCE:-<empty>}" >> "$DEBUG_LOG"
echo "  transcript_path: ${transcript_path:-<empty>}" >> "$DEBUG_LOG"
echo "  transcript_exists: $([ -f "$transcript_path" ] && echo yes || echo no)" >> "$DEBUG_LOG"
echo "  last_msg length: ${#last_msg}, preview: ${last_msg:0:80}" >> "$DEBUG_LOG"
[ -n "$payload_title" ] && echo "  payload_title: $payload_title" >> "$DEBUG_LOG"

if [ "$HOOK_EVENT" != "Stop" ]; then
    echo "  [skip] hook event is not Stop" >> "$DEBUG_LOG"
    exit 0
fi

if [ -z "$transcript_path" ] && [ -z "$SESSION_SOURCE" ] && is_title_only_payload "$last_msg"; then
    echo "  [skip] title-only control payload — not a spoken assistant reply" >> "$DEBUG_LOG"
    exit 0
fi

if [ -z "$SOURCE_LABEL" ]; then
    echo "  [skip] unrecognized source — not a voice-enabled Claude Code/Codex session" >> "$DEBUG_LOG"
    exit 0
fi

echo "  source_label: $SOURCE_LABEL" >> "$DEBUG_LOG"

claim_active_session "$SESSION_ID" "$transcript_path" "$SOURCE_LABEL"
echo "  [route] global voice mode accepted ${SESSION_ID:-<no-session-id>} (${SOURCE_LABEL})" >> "$DEBUG_LOG"

# Secondary: try transcript parser for multi-block responses (text before AND after tool calls)
msg=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    msg=$(python3 -c "
import json, sys

debug_log = '/tmp/claude-tts-debug.log'
def dbg(msg):
    with open(debug_log, 'a') as f:
        f.write(f'  [parser] {msg}\n')

def extract_text_blocks(content):
    texts = []
    if isinstance(content, str):
        text = content.strip()
        if text:
            texts.append(text)
        return texts
    if not isinstance(content, list):
        return texts
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get('type', '')
        text = ''
        if block_type in ('text', 'output_text', 'input_text'):
            text = block.get('text', '')
        elif block_type == 'tool_result' and isinstance(block.get('content'), str):
            text = block.get('content', '')
        text = text.strip()
        if text:
            texts.append(text)
    return texts

def normalize_last_message(raw):
    raw = (raw or '').strip()
    if not raw:
        return ''
    try:
        parsed = json.loads(raw)
    except Exception:
        return raw
    if isinstance(parsed, dict) and set(parsed.keys()) == {'title'}:
        return ''
    return raw

def choose_texts(texts, label, last):
    result = '\n<<MSG_BREAK>>\n'.join(texts)
    dbg(f'collected {len(texts)} {label} text blocks')
    if last and last[:50] not in result:
        dbg(f'{label} transcript mismatch — using last_msg')
        return last
    dbg(f'using {label} transcript ({len(texts)} blocks)')
    return result

last = normalize_last_message(sys.argv[2] if len(sys.argv) > 2 else '')
claude_texts = []
codex_final = []
codex_commentary = []
found_claude = False
found_codex = False

with open(sys.argv[1]) as f:
    lines = f.readlines()
dbg(f'transcript lines: {len(lines)}')
for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except Exception:
        continue
    t = entry.get('type', '')
    payload = entry.get('payload', {})
    if not isinstance(payload, dict):
        payload = {}

    if t == 'assistant':
        content = entry.get('message', {}).get('content', [])
        blocks = []
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get('type') == 'text':
                    text = b.get('text', '').strip()
                    if text:
                        blocks.append(text)
        if blocks:
            claude_texts.append('\n'.join(blocks))
            found_claude = True
        continue

    if t == 'user':
        if found_claude:
            break
        continue

    if t == 'response_item' and payload.get('type') == 'message':
        role = payload.get('role', '')
        phase = payload.get('phase', '')
        blocks = extract_text_blocks(payload.get('content', []))
        if role == 'assistant' and blocks:
            joined = '\n'.join(blocks)
            if phase == 'final_answer':
                codex_final.append(joined)
                found_codex = True
            elif phase == 'commentary':
                codex_commentary.append(joined)
                found_codex = True
        elif role == 'user' and found_codex:
            break
        continue

    if t == 'event_msg':
        event_type = payload.get('type', '')
        if event_type == 'user_message':
            if found_codex:
                break
            continue
        if event_type == 'agent_message' and not found_codex:
            message = (payload.get('message') or '').strip()
            if message:
                codex_commentary.append(message)
                found_codex = True
        continue

claude_texts.reverse()
codex_final.reverse()
codex_commentary.reverse()

if codex_final:
    print(choose_texts(codex_final, 'codex final', last))
elif claude_texts:
    print(choose_texts(claude_texts, 'claude', last))
elif codex_commentary:
    if last:
        dbg('no codex final blocks — using last_msg over commentary')
        print(last)
    else:
        dbg(f'using codex commentary transcript ({len(codex_commentary)} blocks)')
        print('\n<<MSG_BREAK>>\n'.join(codex_commentary))
else:
    dbg('no blocks found — using last_msg')
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
if is_title_only_payload "$msg"; then
    echo "  [skip] title-only payload after parsing — not a spoken assistant reply" >> "$DEBUG_LOG"
    exit 0
fi

rm -f "$SKIP_FLAG"

strip_markdown() {
    local text="$1"
    local code_mode="${2:-silent}"

    if [ "$code_mode" = "silent" ]; then
        echo "$text" | awk '
            /^```/ {
                if (in_code) { in_code = 0 }
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

collapse_to_spoken_summary() {
    python3 - <<'PY'
import re
import sys

text = sys.stdin.read().strip()
if not text:
    sys.exit(0)

text = text.replace("<<MSG_BREAK>>", " ")
lines = [line.strip() for line in text.splitlines() if line.strip()]

chunks = []
for line in lines:
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9 /-]{1,40}:", line):
        continue
    parts = re.split(r"(?<=[.!?])\s+", line)
    for part in parts:
        part = re.sub(r"\s+", " ", part).strip()
        if part:
            chunks.append(part)

if not chunks:
    chunks = [re.sub(r"\s+", " ", text).strip()]

limit = 280
summary = []
for chunk in chunks:
    candidate = " ".join(summary + [chunk]).strip()
    if len(candidate) > limit and summary:
        break
    if len(candidate) > limit:
        shortened = chunk[:limit].rsplit(" ", 1)[0].strip()
        summary = [shortened or chunk[:limit].strip()]
        break
    summary.append(chunk)
    if len(summary) >= 2 and len(candidate) >= 120:
        break

result = " ".join(summary).strip()
if not result:
    result = text[:limit].rsplit(" ", 1)[0].strip() or text[:limit].strip()

print(result, end="")
PY
}

build_spoken_title_prefix() {
    local source="$1"
    local explicit_title="$2"
    local body="$3"

    python3 -c '
import re
import sys

source = sys.argv[1].strip()
explicit = sys.argv[2].strip()
text = sys.stdin.read()

def clean(value):
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"[\[\]{}\"`*_>#|]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" .:-")
    return value

def title_case(words):
    acronyms = {
        "ai": "AI",
        "api": "API",
        "codex": "Codex",
        "claude": "Claude",
        "elle": "ELLE",
        "fn": "Fn",
        "leq": "LEQ",
        "mbp": "MBP",
        "tts": "TTS",
        "vm": "VM",
    }
    rendered = []
    for word in words:
        key = word.lower()
        if key in acronyms:
            rendered.append(acronyms[key])
        elif word.isupper() and len(word) <= 5:
            rendered.append(word)
        else:
            rendered.append(word[:1].upper() + word[1:].lower())
    return " ".join(rendered)

def derive_title(value):
    lines = [clean(line) for line in value.replace("<<MSG_BREAK>>", "\n").splitlines()]
    lines = [line for line in lines if line]

    for line in lines:
        words = re.findall(r"[A-Za-z0-9]+(?:[-/][A-Za-z0-9]+)?", line)
        if 2 <= len(words) <= 9 and len(line) <= 80 and not re.search(r"[.!?]$", line):
            return title_case(words[:8])

    chunks = []
    for line in lines:
        for chunk in re.split(r"(?<=[.!?])\s+", line):
            chunk = clean(chunk)
            if chunk:
                chunks.append(chunk)

    skip = {"done", "ok", "okay", "sure", "yes", "no"}
    drop = {
        "a", "an", "and", "are", "as", "for", "from", "i", "in", "it", "of",
        "on", "the", "this", "to", "we", "with", "you",
    }
    leading = {"done", "i", "ive", "i ve", "implemented", "updated", "fixed", "added"}

    for chunk in chunks:
        lowered = chunk.lower().strip(" .")
        if lowered in skip:
            continue
        words = re.findall(r"[A-Za-z0-9]+(?:[-/][A-Za-z0-9]+)?", chunk)
        while words and words[0].lower() in leading:
            words = words[1:]
        words = [word for word in words if word.lower() not in drop]
        if len(words) >= 2:
            return title_case(words[:7])

    return ""

title = clean(explicit) if explicit else derive_title(text)
if not title:
    sys.exit(0)

title_words = re.findall(r"[A-Za-z0-9]+(?:[-/][A-Za-z0-9]+)?", title)
title = title_case(title_words[:8]) if title_words else title[:70].strip()
if not title:
    sys.exit(0)

prefix = title
if source and not title.lower().startswith(source.lower()):
    prefix = f"{source} {title}"

print(f"{prefix}. ", end="")
' "$source" "$explicit_title" <<< "$body"
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

        # Check forward flag (+1 sentence)
        if [ -f "$FORWARD_FLAG" ]; then
            rm -f "$FORWARD_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            idx=$((idx + 1))
            [ "$idx" -gt "$total" ] && idx=$total
            continue
        fi

        # Check rewind flag (-1 sentence)
        if [ -f "$REWIND_FLAG" ]; then
            rm -f "$REWIND_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            idx=$((idx - 1))
            [ "$idx" -lt 1 ] && idx=1
            continue
        fi

        local sentence
        sentence=$(sed -n "${idx}p" "$sentences_file")
        [ -z "$sentence" ] && { idx=$((idx + 1)); continue; }

        show_subtitle "$sentence"
        echo "$sentence" | say -r "$rate" -o "$TMP_AUDIO" 2>/dev/null \
            && afplay --volume "$vol" "$TMP_AUDIO" 2>/dev/null
        rm -f "$TMP_AUDIO"
        idx=$((idx + 1))
    done

    rm -f "$sentences_file"
}

# Cross-response sentence dedup — filters out sentences already spoken in recent messages.
# Splits text into sentences, hashes each, checks against rolling history file.
# Returns only the sentences that haven't been spoken yet.
filter_already_spoken() {
    local text="$1"
    [ ! -f "$SPOKEN_HASHES" ] && { echo "$text"; return; }

    local result=""
    local hashes_content
    hashes_content=$(cat "$SPOKEN_HASHES" 2>/dev/null)

    # Split on sentence boundaries and check each
    while IFS= read -r sentence; do
        [ -z "$sentence" ] && continue
        # Normalize: lowercase, strip extra whitespace for consistent hashing
        local normalized
        normalized=$(echo "$sentence" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$normalized" ] && { result+="$sentence"$'\n'; continue; }
        local hash
        hash=$(echo -n "$normalized" | md5 -q 2>/dev/null || echo -n "$normalized" | md5sum 2>/dev/null | cut -d' ' -f1)
        if echo "$hashes_content" | grep -qF "$hash"; then
            # Already spoken — skip this sentence
            true
        else
            result+="$sentence"$'\n'
        fi
    done < <(echo "$text" | sed -E 's/([.!?]) /\1\n/g')

    # Return filtered text (may be empty if everything was already spoken)
    echo "$result" | sed '/^[[:space:]]*$/d'
}

# Record sentence hashes after speaking — call with the text that was actually queued.
record_spoken_hashes() {
    local text="$1"
    [ -z "$text" ] && return
    touch "$SPOKEN_HASHES"
    while IFS= read -r sentence; do
        [ -z "$sentence" ] && continue
        local normalized
        normalized=$(echo "$sentence" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$normalized" ] && continue
        local hash
        hash=$(echo -n "$normalized" | md5 -q 2>/dev/null || echo -n "$normalized" | md5sum 2>/dev/null | cut -d' ' -f1)
        echo "$hash" >> "$SPOKEN_HASHES"
    done < <(echo "$text" | sed -E 's/([.!?]) /\1\n/g')

    # Trim to max size (rolling window — keep most recent)
    local count
    count=$(wc -l < "$SPOKEN_HASHES" | tr -d ' ')
    if [ "$count" -gt "$SPOKEN_HASHES_MAX" ]; then
        tail -n "$SPOKEN_HASHES_MAX" "$SPOKEN_HASHES" > "${SPOKEN_HASHES}.tmp"
        mv "${SPOKEN_HASHES}.tmp" "$SPOKEN_HASHES"
    fi
}

# Check if message is VM status output (don't save these for repeat)
is_vm_status() {
    local text="$1"
    case "$text" in
        "Voice mode"*|"Listen mode"*|"Dictation mode"*|"Quiet mode"*|\
        "Voice test queued"*|"Repeating last"*|"Nothing to repeat"*|"Done."*|\
        "TTS:"*|"Mic:"*|"Cue:"*|"Usage: /vm"*)
            return 0 ;;
    esac
    return 1
}

# Save text for repeat (cmd+shift) and session history (opt+shift+arrow)
# Called with the FULL response text (not deltas). If this is the same response
# block (BLOCK_START already consumed), OVERWRITE the current history entry
# instead of creating a new one — prevents duplicate entries from growing text.
CURRENT_BLOCK_HISTORY_IDX=""
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

    if [ -f "$BLOCK_START" ]; then
        # First save for this response block — create new history entry
        local current_total=0
        [ -f "$HISTORY_DIR/total" ] && current_total=$(cat "$HISTORY_DIR/total")
        local next=$((current_total + 1))
        CURRENT_BLOCK_HISTORY_IDX="$next"
        local padded
        padded=$(printf "%03d" "$next")

        echo "$text" > "$HISTORY_DIR/msg-${padded}.txt"
        echo "$speed" > "$HISTORY_DIR/msg-${padded}.speed"
        echo "$volume" > "$HISTORY_DIR/msg-${padded}.volume"
        echo "$next" > "$HISTORY_DIR/total"
        echo "$next" > "$HISTORY_DIR/current"

        echo "$next" > "$REPEAT_ANCHOR"
        echo "$HISTORY_DIR" > "/tmp/claude-tts-history-dir"
        rm -f "$BLOCK_START"
    elif [ -n "$CURRENT_BLOCK_HISTORY_IDX" ]; then
        # Same response block growing — overwrite the existing history entry
        local padded
        padded=$(printf "%03d" "$CURRENT_BLOCK_HISTORY_IDX")
        echo "$text" > "$HISTORY_DIR/msg-${padded}.txt"
        echo "$speed" > "$HISTORY_DIR/msg-${padded}.speed"
        echo "$volume" > "$HISTORY_DIR/msg-${padded}.volume"
    fi
}

# Safety net: restart daemon if voice mode is on but daemon crashed
ensure_daemon() {
    # Current voice mode is remote-first. The Mac Mini hook only enqueues text and
    # the MBP LaunchAgent-owned skip-listener consumes it via tts-bridge.
    # Starting a local loose skip-listener here recreates the old dual-listener bug.
    # Keep the local fallback available only as an explicit opt-in for debugging.
    if [ ! -f "$LOCAL_DAEMON_FLAG" ]; then
        return 0
    fi

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0  # Running
        fi
    fi

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
        # If TTS playing flag is gone, stop-all was triggered — break entirely
        if [ -f "$SKIP_FLAG" ]; then
            rm -f "$SKIP_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            [ ! -f "$TTS_PLAYING_FLAG" ] && break
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

        write_active_segment "$seg_idx" "$segment_count" "$cleaned_seg"
        show_subtitle "$cleaned_seg"
        speak_sentences "$cleaned_seg" "$speed" "$vol"

        # After speaking, check if skip was hit during this segment
        if [ -f "$SKIP_FLAG" ]; then
            rm -f "$SKIP_FLAG"
            pkill say 2>/dev/null; pkill afplay 2>/dev/null
            [ ! -f "$TTS_PLAYING_FLAG" ] && break
            [ "$seg_idx" -lt "$segment_count" ] && continue
        fi
    done
    clear_active_segment
    clear_subtitle
    rm -rf "$seg_dir"
    rm -f "$TTS_PLAYING_FLAG" "$PAUSE_FLAG" "$SKIP_FLAG"

    release_tts_lock
}

if has_config; then
    VOICE=$(read_config "voice" "off")
    MIC=$(read_config "mic" "off")
    CUE=$(read_config "cue" "off")
    SUBTITLE=$(read_config "subtitle" "off")
    SPEED=$(read_config "speed" "200")
    [[ "$SPEED" =~ ^[0-9]+$ ]] || SPEED=200
    VOLUME=$(read_config "volume" "normal")
    SUMMARY=$(read_config "summary" "off")
    CODE=$(read_config "code" "silent")

    VOL_LEVEL="1.0"
    [ "$VOLUME" = "quiet" ] && VOL_LEVEL="0.3"

    # Clean up flags for fresh start
    rm -f "$SKIP_FLAG" "$PAUSE_FLAG" "$TTS_PLAYING_FLAG" "$MIC_LISTENING_FLAG" /tmp/claude-voice-input-stop
    rm -f "$FORWARD_FLAG" "$REWIND_FLAG" /tmp/claude-tts-next-msg /tmp/claude-tts-prev-msg
    rm -f "$PENDING_FILE" "$PENDING_TS"
    rm -rf "$DETAIL_CACHE"
    rm -f "$DRILL_DOWN_FLAG"
    rm -f "$ACTIVE_SEGMENT"

    # Mark this as a new response block — first save_for_repeat will set the anchor
    touch "$BLOCK_START"
    # QUEUED_PREFIX/QUEUED_LENGTH persist across hook fires within the same response
    # (for incremental dedup). They are cleared on Stop events (line ~642) so the
    # next response starts fresh — NOT here, which fires on every hook invocation.

    # Safety net: ensure daemon is running
    ensure_daemon

    # --- VOICE OUTPUT (queue-based: write to queue immediately, daemon speaks) ---
    if [ "$VOICE" = "on" ]; then
        queued_primary_text=0
        QUEUE_DIR="/tmp/claude-tts-queue"
        mkdir -p "$QUEUE_DIR"

        # Extract text to speak
        text_to_queue="$msg"
        summary_text=""

        if [ "$SUMMARY" = "on" ]; then
            summary_text=$(echo "$msg" | sed -n 's/.*\[SUMMARY: \(.*\)\].*/\1/p' | head -1)
            if [ -n "$summary_text" ]; then
                text_to_queue="$summary_text"
            fi
        fi

        # Transform structured data before markdown stripping
        transformed=$(echo "$text_to_queue" | python3 "$PLUGIN_BIN/transform-for-speech.py" 2>/dev/null)
        [ -z "$transformed" ] && transformed="$text_to_queue"
        cleaned=$(strip_markdown "$transformed" "$CODE" | sed 's/<<MSG_BREAK>>//g')

        if [ "$SUMMARY" = "on" ] && [ -z "$summary_text" ] && [ -n "$cleaned" ]; then
            spoken_summary=$(echo "$cleaned" | collapse_to_spoken_summary)
            [ -n "$spoken_summary" ] && cleaned="$spoken_summary"
        fi

        if [ -n "$cleaned" ]; then
            if is_vm_status "$cleaned"; then
                echo "  [queue] skipped vm control output" >> "$DEBUG_LOG"
                cleaned=""
            fi
        fi

        if [ -n "$cleaned" ]; then
            title_prefix=$(build_spoken_title_prefix "$SOURCE_LABEL" "$payload_title" "$cleaned")
            if [ -n "$title_prefix" ]; then
                cleaned="${title_prefix}${cleaned}"
                echo "  [title] prefix: $title_prefix" >> "$DEBUG_LOG"
            fi
        fi

        if [ -n "$cleaned" ]; then
            # Incremental dedup: track what's been queued by prefix + length
            # so growing responses only queue the NEW portion
            prev_prefix=""
            prev_len=0
            [ -f "$QUEUED_PREFIX" ] && prev_prefix=$(cat "$QUEUED_PREFIX" 2>/dev/null)
            [ -f "$QUEUED_LENGTH" ] && prev_len=$(cat "$QUEUED_LENGTH" 2>/dev/null)
            [[ "$prev_len" =~ ^[0-9]+$ ]] || prev_len=0

            current_len=${#cleaned}
            current_prefix="${cleaned:0:100}"
            block_id=$(cat "$BLOCK_ID_FILE" 2>/dev/null || true)

            new_text=""

            if [ -n "$prev_prefix" ] && [ "${cleaned:0:${#prev_prefix}}" = "$prev_prefix" ]; then
                # Same response (prefix matches) — only queue text beyond what was already queued
                if [ "$current_len" -gt "$prev_len" ]; then
                    new_text="${cleaned:$prev_len}"
                    new_text=$(echo "$new_text" | sed '1s/^[[:space:]]*//')
                fi
            else
                # Different response (new prefix) — queue everything
                new_text="$cleaned"
                block_id=""
            fi

            if [ -z "$block_id" ]; then
                block_id="$(date +%s%N)-$$"
                echo "$block_id" > "$BLOCK_ID_FILE"
            fi

            if [ -n "$new_text" ]; then
                # Save COMPLETE response for repeat/history (not the delta)
                # save_for_repeat handles: LAST_TEXT, history entries, block start anchor
                save_for_repeat "$cleaned" "$SPEED" "$VOL_LEVEL"

                # Cross-response dedup: filter out sentences already spoken recently
                filtered_text=$(filter_already_spoken "$new_text")

                if [ -n "$filtered_text" ]; then
                    # Write to remote TTS pickup dir — MBP bridge pulls and feeds to skip-listener
                    REMOTE_TTS_DIR="/tmp/claude-tts-remote"
                    mkdir -p "$REMOTE_TTS_DIR"
                    remote_ts=$(date +%s%N)
                    echo "$SPEED" > "$REMOTE_TTS_DIR/entry-${remote_ts}.speed"
                    echo "$VOL_LEVEL" > "$REMOTE_TTS_DIR/entry-${remote_ts}.volume"
                    echo "$SOURCE_LABEL" > "$REMOTE_TTS_DIR/entry-${remote_ts}.source"
                    [ -n "$SESSION_ID" ] && echo "$SESSION_ID" > "$REMOTE_TTS_DIR/entry-${remote_ts}.session"
                    echo "$block_id" > "$REMOTE_TTS_DIR/entry-${remote_ts}.block"
                    printf '%s' "$text_to_queue" > "$REMOTE_TTS_DIR/entry-${remote_ts}.raw"
                    printf '%s' "$cleaned" > "$REMOTE_TTS_DIR/entry-${remote_ts}.normalized"
                    echo "$filtered_text" > "$REMOTE_TTS_DIR/entry-${remote_ts}.txt"

                    # Record what we just queued so future responses skip these sentences
                    record_spoken_hashes "$filtered_text"
                    queued_primary_text=1

                    echo "  [queue] queued ${#filtered_text} chars for $SOURCE_LABEL (${#new_text} before dedup, delta from ${prev_len} to ${current_len})" >> "$DEBUG_LOG"
                else
                    echo "  [queue] all sentences already spoken — nothing new to queue (${#new_text} chars filtered)" >> "$DEBUG_LOG"
                fi
            else
                echo "  [queue] skipped — no new text (prefix match, len ${current_len} <= ${prev_len})" >> "$DEBUG_LOG"
            fi

            # Update tracking for next invocation
            echo "$current_prefix" > "$QUEUED_PREFIX"
            echo "$current_len" > "$QUEUED_LENGTH"
        fi
    fi

    # --- MIC ACTIVATION ---
    # Mic does not auto-activate. User triggers manually.
    # Auto-mic reserved for future "hands-free" mode (/vm handsfree).

    # On Stop event, clear dedup tracking so next response starts fresh.
    # This fixes the bug where a new response starting with similar text to the
    # previous response was incorrectly skipped by the prefix-match dedup.
    if [ "$HOOK_EVENT" = "Stop" ]; then
        rm -f "$QUEUED_PREFIX" "$QUEUED_LENGTH"
        rm -f "$BLOCK_ID_FILE"
        echo "  [dedup] cleared prefix/length tracking (Stop event)" >> "$DEBUG_LOG"
    fi

    # "Your turn" cue — ONLY on Stop event (full response complete), not PostToolUse
    if [ "$HOOK_EVENT" = "Stop" ] && [ "$VOICE" = "on" ] && [ "$CUE" = "on" ] && [ "${queued_primary_text:-0}" -eq 1 ]; then
        REMOTE_TTS_DIR="/tmp/claude-tts-remote"
        mkdir -p "$REMOTE_TTS_DIR"
        cue_ts=$(date +%s%N)
        echo "250" > "$REMOTE_TTS_DIR/entry-${cue_ts}.speed"
        echo "1.0" > "$REMOTE_TTS_DIR/entry-${cue_ts}.volume"
        echo "Your turn." > "$REMOTE_TTS_DIR/entry-${cue_ts}.txt"
        echo "  [cue] queued Your turn cue" >> "$DEBUG_LOG"
    elif [ "$HOOK_EVENT" = "Stop" ] && [ "$VOICE" = "on" ]; then
        echo "  [cue] skipped (cue=$CUE queued_primary_text=${queued_primary_text:-0})" >> "$DEBUG_LOG"
    fi
else
    # No config = text mode, no TTS
    exit 0
fi
