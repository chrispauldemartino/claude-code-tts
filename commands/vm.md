---
description: "Global voice mode toggle for Claude Code + Codex — including per-session names, session/source announcement cues, focus, playback, and status."
argument-hint: "[on [claude|codex]|off|listen [claude|codex]|dictation [claude|codex]|name [nickname]|cue session/source/both/off|cue-frequency always/change|focus|log|speed|engine|doctor|status|voice on/off|mic on/off|subtitle on/off|summary on/off]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh:*)
---

Execute the voice toggle script:

```!
"${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh" $ARGUMENTS
```

Display the script output to the user without additional commentary.

Session announcement controls:

- `/vm name` shows the invoking session's nickname and provenance.
- `/vm name <nickname>` stores a per-session override. Quote a nickname that contains spaces.
- `/vm cue session|source|both|off` selects the standalone announcement content.
- `/vm cue-frequency change|always` announces only on a `(source, session_id)` transition (the default) or before every item.
- `/vm status` includes the invoking session ID, nickname/provenance, allowlist state, and whether voice is on, open, or background-muted for that session.
