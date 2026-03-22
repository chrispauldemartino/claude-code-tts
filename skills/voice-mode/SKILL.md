---
name: voice-mode
description: Use when the user says "voice mode", "switching to voice mode", "exit voice mode", or "text mode". Activates or deactivates hands-free voice conversation mode using macOS say for TTS output.
---

# Voice Mode

Hands-free conversation loop. Claude speaks responses aloud via macOS `say`, then cues the user with "Your turn." User holds Space to speak back (push-to-talk).

## Activation

When the user says "voice mode" or "switching to voice mode":

1. Create the flag file:
   ```bash
   touch /tmp/claude-voice-mode
   ```
2. Confirm activation. Say exactly: "Voice mode activated. I'll speak my replies aloud. Hold Space to talk back to me."

## Deactivation

When the user says "exit voice mode" or "text mode":

1. Remove the flag file:
   ```bash
   rm -f /tmp/claude-voice-mode
   ```
2. Confirm deactivation. Say exactly: "Voice mode off. Back to text."

## Output Style (while voice mode is active)

When `/tmp/claude-voice-mode` exists, adapt ALL responses:

- **Concise.** Short, conversational sentences. No unnecessary filler.
- **No code blocks read aloud.** If you must show code, write it normally on screen but do NOT narrate it. The hook replaces code blocks with "See code on screen."
- **No markdown artifacts.** Write in natural language. Avoid bullet lists, tables, and headers in your prose. Use flowing sentences instead.
- **Listenable.** Write as if speaking to someone. Spell out abbreviations. Avoid file paths and technical notation that sounds awkward when read aloud.
- **Actionable.** End with clear next steps or a question.
- **Brief.** Aim for 2-4 sentences when possible. The user is listening, not reading.

## Interrupting Speech

If a response is too long, the user can run `pkill say` from another terminal to stop speech without killing the session.
