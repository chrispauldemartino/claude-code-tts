#!/bin/bash
# Side-effect-free live/backfill speech preparation. Reads an answer on stdin.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CLAUDE_VOICE_CONFIG:-/tmp/claude-voice-config}"

read_setting() {
    local key="$1" fallback="$2" value=""
    if [ -f "$CONFIG" ]; then
        value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, "", $0); print; exit }' "$CONFIG")
    fi
    printf '%s\n' "${value:-$fallback}"
}

summary_mode="$(read_setting summary off)"
code_mode="$(read_setting code silent)"

extract_explicit_summary() {
    python3 -c '
import re, sys
text = sys.stdin.read()
summary_on = sys.argv[1] == "on"
if summary_on:
    match = re.search(r"\[SUMMARY:\s*(.*?)\]", text, re.S)
    if match:
        text = "ELLEEXPLICITSUMMARYMARKER\n" + match.group(1).strip()
sys.stdout.write(text)
' "$summary_mode"
}

transform_for_speech() {
    python3 "$SCRIPT_DIR/transform-for-speech.py" 2>/dev/null
}

strip_speech_markdown() {
    python3 -c '
import re, sys
text = sys.stdin.read().replace("<<MSG_BREAK>>", "")
code_mode = sys.argv[1]
if code_mode == "silent":
    text = re.sub(r"^```[^\n]*\n.*?^```[ \t]*$", "", text, flags=re.M | re.S)
else:
    text = re.sub(r"^```[^\n]*$|^```[ \t]*$", "", text, flags=re.M)
text = re.sub(r"^#{1,6}\s+", "", text, flags=re.M)
text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
text = re.sub(r"__([^_]*)__", r"\1", text)
text = re.sub(r"(?<!\*)\*([^*]*)\*(?!\*)", r"\1", text)
text = re.sub(r"(?<!_)_([^_]*)_(?!_)", r"\1", text)
text = re.sub(r"`([^`]*)`", r"\1", text)
text = re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", text)
text = re.sub(r"^(?:[-*]|\d+\.)\s+", "", text, flags=re.M)
lines = [line.rstrip() for line in text.splitlines()]
sys.stdout.write("\n".join(line for line in lines if line.strip()).strip())
' "$code_mode"
}

collapse_speech_summary() {
    python3 -c '
import re, sys
text = sys.stdin.read().strip()
if not text:
    raise SystemExit
explicit_summary = text.startswith("ELLEEXPLICITSUMMARYMARKER")
if explicit_summary:
    text = text[len("ELLEEXPLICITSUMMARYMARKER"):].lstrip()
control_prefixes = (
    "Voice mode", "Listen mode", "Dictation mode", "Quiet mode",
    "Voice test queued", "Repeating last", "Nothing to repeat", "Done.",
    "TTS:", "Mic:", "Cue:", "Usage: /vm",
)
if text.startswith(control_prefixes):
    raise SystemExit
if sys.argv[1] != "on" or explicit_summary:
    sys.stdout.write(text)
    raise SystemExit
chunks = []
for line in text.splitlines():
    line = line.strip()
    if not line or re.fullmatch(r"[A-Za-z][A-Za-z0-9 /-]{1,40}:", line):
        continue
    chunks.extend(p.strip() for p in re.split(r"(?<=[.!?])\s+", line) if p.strip())
summary = " ".join(chunks[:2]).strip()
if len(summary) > 280:
    summary = summary[:280].rsplit(" ", 1)[0].strip() or summary[:280]
sys.stdout.write(summary or text[:280])
' "$summary_mode"
}

# Every stage consumes the previous stage's stdout. Settings-disabled summary
# stages are pass-throughs inside their functions, so no stage can bypass the
# transform or markdown stages through shell conditional precedence.
extract_explicit_summary \
    | transform_for_speech \
    | strip_speech_markdown \
    | collapse_speech_summary
