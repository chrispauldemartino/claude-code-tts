---
description: "Global voice mode toggle for Claude Code + Codex — on, off, listen, test, dictation, quiet, repeat, status"
argument-hint: "[on|off|listen|test|dictation|quiet|repeat|status|voice on/off|mic on/off|cue on/off]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh:*)
---

Execute the voice toggle script:

```!
"${CLAUDE_PLUGIN_ROOT}/bin/vm-toggle.sh" $ARGUMENTS
```

Display the script output to the user without additional commentary.
