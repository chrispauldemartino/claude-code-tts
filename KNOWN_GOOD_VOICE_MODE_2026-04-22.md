# Voice Mode Known Good - 2026-04-22

This note marks the working voice-mode baseline after the April 22, 2026 trust and shortcut repair.

## Verified Working State

- `SkipListener.app` remains on the MBP LaunchAgent path and idles under `launchd` instead of self-terminating when voice mode is off.
- Rebuilds preserve the installed Apple Development signing identity instead of picking a random valid identity.
- Keyboard trust recovered with `AXIsProcessTrusted: true` and `CGPreflightListenEventAccess: true`, and the MBP listener returned to a single live process with `forks = 0`.
- `/vm rebuild` supports a GUI fallback on the MBP when headless codesign cannot unlock the signing identity.

## Behavioral Contract

- `opt + arrow left/right` moves one spoken sentence at a time during normal playback, and while idle it moves backward or forward through playback-log items.
- `opt + opt` pauses and resumes in place.
- `shift + shift` stops all playback, clears queued audio, and resets repeat back to the newest saved message.
- `cmd + shift` repeats from the current repeat anchor while playback is active or paused, and while idle it continues the playback-log timeline instead of jumping to the newest item.
- `fn + fn` continues playback from the playback-log timeline. It advances to the item after the current cursor, starts at the oldest item when no cursor exists, and does not wrap around at the end.
- If the playback-log manifest has been cleared, `fn + fn` and `/vm log play` fall back to the current session history instead of stopping at a boundary chime.
- `opt + shift + arrow` message nav uses MBP session history first and only falls back to transcript parsing if that history is missing.
- `/vm log play` follows the same bounded timeline cursor. `/vm log first` and `/vm log latest` explicitly move the cursor to the start or end, and `/vm stop` resets repeat/log playback back to the newest saved item.
- Spoken replies now begin with a short source/title prefix, for example `Codex Queue Cleanup` or `Claude Code Subscription Consumption`, before reading the response body.
- `/vm doctor` is the quick preflight for signer, trust, LaunchAgent, listener, and bridge health.
- Default `code=silent` speech does not read code literally. It summarizes implementation references into short phrases such as `python code - test transform for speech`, `skip listener implementation`, or `configuration`.
- Numeric inline references such as `#248`, `#537`, or short hashes like `cdb55310` stay preserved in normalized speech instead of collapsing to placeholder narration.
- Short inline phrases and ratios inside backticks stay literal in silent mode, so outputs like `19/19`, `name summary`, `19 detail`, and `name summary detail` no longer collapse to `implementation detail`.
- Non-spoken metadata blocks such as `<oai-mem-citation>...</oai-mem-citation>` are stripped from spoken output even when they remain present in the rendered final answer text.
- Internal ELLE markdown doc names remain speakable in silent mode, while implementation paths and filenames are shortened instead of being read token by token.
- `ELLE` is spoken as `El Lee` throughout normalized vm speech output, including prose, doc names, and summarized file references.

## Files In Scope

- `bin/build-skip-listener-app.sh`
- `bin/install-skip-listener-launchagent.sh`
- `bin/restart-skip-listener-launchagent.sh`
- `bin/transform-for-speech.py`
- `bin/vm-toggle.sh`
- `cmd/skip-listener/main.swift`
- `hooks/auto-speak.sh`

## Rollback

If voice mode regresses later, revert the plugin repo to the commit that introduced this note and rebuild the MBP listener from that revision.
