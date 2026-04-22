---
description: "Global voice mode toggle for Claude Code + Codex — on, off, rebuild, listen, test, dictation, quiet, repeat, skip, stop, pause, resume, forward, rewind, focus, log, speed, engine, doctor, status"
argument-hint: "[on|off|rebuild|listen|test|dictation|quiet|mute|unmute|repeat|skip|stop|pause|resume|forward|rewind|focus|focus status|focus off|log|log status|log back|log next|log replay|log latest|speed|speed up|speed down|speed <wpm>|engine|engine say|engine openai|doctor|status|voice on/off|mic on/off|cue on/off|subtitle on/off|summary on/off]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh:*)
---

Execute the voice toggle script:

```!
"${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh" $ARGUMENTS
```

Display the script output to the user without additional commentary.
