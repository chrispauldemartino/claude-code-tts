---
name: vm-mode
description: Use when the user says "voice mode", "text mode", "listen mode", "dictation mode", "quiet mode", "voice on/off", "mic on/off", "cue on/off", "summary mode on/off", "narrate code", "skip code", "speak faster/slower", or "use [device] mic". Handles natural language voice toggle commands.
---

# Voice Mode (Natural Language Triggers)

Manages the voice config file at `/tmp/claude-voice-config`. Each command reads the current config, applies changes, writes back atomically (write to .tmp, then `mv`).

## Shortcuts (set multiple toggles)

| Trigger | Config Changes |
|---|---|
| "voice mode" | voice=on, mic=on, cue=on, speed=300, volume=normal, summary=off, code=silent (full reset) |
| "text mode" | Delete config file entirely |
| "listen mode" | voice=on, mic=off, cue=off |
| "dictation mode" | voice=off, mic=on, cue=off |
| "quiet mode" | volume=quiet, speed=250 |

## Individual Toggles (update only the named setting)

| Trigger | Config Change |
|---|---|
| "voice on" / "voice off" | voice=on / voice=off |
| "mic on" / "mic off" | mic=on / mic=off |
| "cue on" / "cue off" | cue=on / cue=off |
| "summary mode on" / "summary mode off" | summary=on / summary=off |
| "narrate code" / "skip code" | code=narrate / code=silent |
| "speak faster" | speed += 50 (cap 350) |
| "speak slower" | speed -= 50 (min 175) |
| "use [device] mic" | mic_device=[device name] |

## How to Apply Changes

1. Read current config: `cat /tmp/claude-voice-config` (if exists)
2. Apply changes per the table above (merge, don't replace)
3. Write atomically:
   ```bash
   cat > /tmp/claude-voice-config.tmp << 'EOF'
   voice=on
   mic=on
   ...
   EOF
   mv /tmp/claude-voice-config.tmp /tmp/claude-voice-config
   ```
4. Confirm briefly (see examples below)

If no config file exists and user says a shortcut: create with all defaults.
If no config file exists and user says an individual toggle: create with all defaults, then apply.
"text mode" deletes the file entirely. Individual "off" toggles update the value, don't delete.

## Confirmation Examples

- "Voice mode activated. I'll speak my replies and open the mic for you. Say send to submit."
- "Listen mode. I'll speak, you type."
- "Dictation mode. You speak, I'll reply in text."
- "Mic off. I'll keep speaking, you type back."
- "Quiet mode on. Speaking faster and softer."
- "Summary mode on. I'll speak the highlights, full detail stays on screen."
- "Switched to Yeti X mic."
- "Text mode. Voice off."

## Output Style (while config file exists)

When `/tmp/claude-voice-config` exists with `voice=on`, adapt ALL responses:

- Concise, conversational, listenable. Short sentences.
- No markdown artifacts. Write in natural language.
- 2-4 sentences when possible. End with next steps or a question.
- When `summary=on`: Write full detail on screen, prepend `[SUMMARY: 1-2 sentence spoken version]`.
- When `code=narrate`: Add brief natural language description above code blocks.

## "Send" Convention

When the user's message ends with "send" (case insensitive), strip it — it's a verbal submit command from voice input, not part of the message.
