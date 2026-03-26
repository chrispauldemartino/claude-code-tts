---
name: voice-mode
description: Use when the user says "voice mode", "text mode", "listen mode", "dictation mode", "quiet mode", "voice on", "voice off", "mic on", "mic off", "cue on", "cue off", "summary mode on", "summary mode off", "narrate code", "skip code", "speak faster", "speak slower", or "exit voice mode". Manages voice mode toggles for hands-free conversation.
---

# Voice Mode

Composable toggle system for hands-free conversation. Config lives at `/tmp/claude-voice-config` as key=value pairs. The post-response hook reads this file to control speech, mic, and cues.

## Config File

Location: `/tmp/claude-voice-config`

Seven independent toggles with defaults:

```
voice=on
mic=on
speed=200
volume=normal
summary=off
code=silent
cue=on
```

| Toggle   | Values              | What it controls                              |
|----------|---------------------|-----------------------------------------------|
| voice    | on / off            | Whether Claude speaks responses aloud          |
| mic      | on / off            | Whether mic opens for voice input after reply  |
| speed    | 175-350 (wpm)       | Speech rate passed to macOS `say`              |
| volume   | normal / quiet      | Speech volume                                  |
| summary  | off / on            | Full spoken vs summary-only spoken output      |
| code     | silent / narrate    | Whether code blocks get spoken descriptions    |
| cue      | on / off            | Whether "Your turn" cue and chime play         |

## Shortcut Commands

These set multiple toggles at once.

### "voice mode"

Full reset to defaults. Activates everything.

```bash
cat > /tmp/claude-voice-config << 'EOF'
voice=on
mic=on
speed=200
volume=normal
summary=off
code=silent
cue=on
EOF
```

Confirm: "Voice mode activated. I'll speak my replies and open the mic. Say send to submit."

### "text mode" / "exit voice mode"

Deactivate voice mode entirely. Remove the config file.

```bash
rm -f /tmp/claude-voice-config
```

Confirm: "Text mode. Back to normal."

### "listen mode"

Claude speaks, user types. No mic, no cue.

```bash
cat > /tmp/claude-voice-config << 'EOF'
voice=on
mic=off
speed=${EXISTING_SPEED:-200}
volume=${EXISTING_VOLUME:-normal}
summary=${EXISTING_SUMMARY:-off}
code=${EXISTING_CODE:-silent}
cue=off
EOF
```

To preserve existing values, first read the current config if it exists, then write the file keeping speed/volume/summary/code from the existing config (or defaults if no config exists). Set voice=on, mic=off, cue=off.

Confirm: "Listen mode. I'll speak, you type."

### "dictation mode"

User speaks, Claude replies in text. No voice output, no cue.

```bash
cat > /tmp/claude-voice-config << 'EOF'
voice=off
mic=on
speed=${EXISTING_SPEED:-200}
volume=${EXISTING_VOLUME:-normal}
summary=${EXISTING_SUMMARY:-off}
code=${EXISTING_CODE:-silent}
cue=off
EOF
```

Same approach: preserve existing speed/volume/summary/code values, set voice=off, mic=on, cue=off.

Confirm: "Dictation mode. You speak, I'll reply in text."

### "quiet mode"

Lower volume and faster speech. Keeps other values.

```bash
sed -i '' "s/^volume=.*/volume=quiet/" /tmp/claude-voice-config
sed -i '' "s/^speed=.*/speed=250/" /tmp/claude-voice-config
```

Confirm: "Quiet mode on. Speaking faster and softer."

## Individual Toggle Commands

These update a single setting in the existing config file.

### "voice on" / "voice off"

```bash
sed -i '' "s/^voice=.*/voice=on/" /tmp/claude-voice-config
```

Confirm: "Voice on." or "Voice off."

### "mic on" / "mic off"

```bash
sed -i '' "s/^mic=.*/mic=off/" /tmp/claude-voice-config
```

Confirm: "Mic on." or "Mic off."

### "cue on" / "cue off"

```bash
sed -i '' "s/^cue=.*/cue=on/" /tmp/claude-voice-config
```

Confirm: "Cue on." or "Cue off."

### "summary mode on" / "summary mode off"

```bash
sed -i '' "s/^summary=.*/summary=on/" /tmp/claude-voice-config
```

Confirm: "Summary mode on. I'll speak highlights, full detail on screen." or "Summary mode off."

### "narrate code" / "skip code"

```bash
sed -i '' "s/^code=.*/code=narrate/" /tmp/claude-voice-config
```

or

```bash
sed -i '' "s/^code=.*/code=silent/" /tmp/claude-voice-config
```

Confirm: "Code narration on." or "Code narration off."

### "speak faster"

Increase speed by 50 wpm, capped at 350.

```bash
current_speed=$(grep '^speed=' /tmp/claude-voice-config 2>/dev/null | cut -d= -f2)
new_speed=$((${current_speed:-200} + 50))
[ "$new_speed" -gt 350 ] && new_speed=350
sed -i '' "s/^speed=.*/speed=$new_speed/" /tmp/claude-voice-config
```

Confirm: "Speed up to [new_speed] words per minute."

### "speak slower"

Decrease speed by 50 wpm, minimum 175.

```bash
current_speed=$(grep '^speed=' /tmp/claude-voice-config 2>/dev/null | cut -d= -f2)
new_speed=$((${current_speed:-200} - 50))
[ "$new_speed" -lt 175 ] && new_speed=175
sed -i '' "s/^speed=.*/speed=$new_speed/" /tmp/claude-voice-config
```

Confirm: "Speed down to [new_speed] words per minute."

## "Send" Convention

When the user's message ends with the word "send" (case insensitive), it means they used voice input and "send" is a verbal submit command, NOT part of their actual message. Strip "send" from the end and process the rest as their actual input.

Example: "What's on my calendar tomorrow send" -> process as "What's on my calendar tomorrow"

## Output Style

Adapt output based on the current config values. Read `/tmp/claude-voice-config` to determine active toggles.

### voice=on, summary=off (default voice mode)

- Concise, conversational, listenable. Short sentences.
- No markdown artifacts in prose. Write in natural language, not bullet lists.
- 2-4 sentences when possible.
- Spell out abbreviations. Avoid file paths in spoken text.
- End with clear next steps or a question.

### voice=on, summary=on

- Normal detailed output on screen (full markdown, code blocks, etc.).
- Prepend `[SUMMARY: 1-2 sentence spoken version]` at the top of the response.
- The summary should capture the key point and next action.
- The hook will speak only the summary; the full response stays on screen.

### voice=on, code=narrate

- When showing code, add a brief natural language description above the code block.
- The hook speaks the description instead of skipping the code block.
- Example: "I added a function called triggerSend that deletes the send keyword and presses Enter."

### voice=off

- Normal text output. No style adaptation needed.
- Standard markdown, full detail, code blocks as usual.

## Controls

- Interrupt speech: run `pkill say` from another terminal, or double-tap Command key.
- Cancel voice input: double-tap Command while mic is active.
- Submit message: say "send" at the end of your message.
- Exit voice mode: say "exit voice mode send" or "text mode send".
