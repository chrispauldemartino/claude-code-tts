---
description: "Global voice mode toggle for Claude Code + Codex — including per-session names, session/source announcement cues, focus, playback, and status."
argument-hint: "[on [claude|codex]|off|listen [claude|codex]|dictation [claude|codex]|backfill [N|status]|name [nickname]|cue session/source/both/off|cue-frequency always/change|focus|log|speed|engine|doctor|status|voice on/off|mic on/off|subtitle on/off|summary on/off]"
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
- Once any nickname is persisted, automatic registration keeps that nickname and its provenance; only `/vm name <nickname>` may replace it.
- Automatic nickname tiers are: handoff, worktree, main, custom title, tier 4b Claude `--name` (`launch_name`), then generated fallback.
- `/vm cue session|source|both|off` selects the standalone announcement content. `source` and `both` intentionally speak the AI name (`Claude`, `Codex`, or `Cursor`).
- `/vm cue-frequency change|always` announces only on a `(source, session_id)` transition (the default) or before every item.
- `/vm status` includes the invoking session ID, nickname/provenance, allowlist state, and whether voice is on, open, or background-muted for that session.
- `/vm backfill [N]` imports the invoking session's last completed answers into the playback log without playing them. `N` defaults to 10 and must be 1–100.
- `/vm backfill status` shows the most recent completed import counts. Repeating an import is safe; matching answers are counted as duplicates.
- Mini-side hook files (`bin/session-metadata.py`, `bin/backfill-transcript.py`, `bin/prepare-speech.sh`, `hooks/session-start.sh`, `hooks/hooks.json`, and `hooks/auto-speak.sh`) run from the plugin checkout on the Mini and are not part of the MBP `/vm rebuild` sync.
