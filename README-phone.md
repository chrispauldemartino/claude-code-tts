# iPhone voice-mode playback (v0)

This optional path synthesizes Claude's completed replies into files on the Mac and lets an iPhone play them over Tailscale. It is isolated from the existing Mac mini / MacBook Pro voice path. Phone mode and `/vm on` are independent; when both are enabled, both devices play the reply.

## Setup

1. Install and connect Tailscale on the Mac and iPhone.
2. On the Mac, run:

   ```bash
   ./bin/phone-voice.sh enroll
   ./bin/phone-voice.sh serve
   ```

3. The server prints a token-bearing URL. Open that exact URL in Safari on the iPhone.
4. Tap **Start listening** once. This iOS gesture authorizes queued audio playback.

`serve` stays in the foreground and binds only to the IPv4 returned by `tailscale ip -4`. Use `./bin/phone-voice.sh stop` from another terminal to stop it. Safari and iOS may suspend browser audio; lock-screen and background playback are not guaranteed in v0.

The query token is used only to authenticate the initial player-page load. That response sets an `HttpOnly`, `SameSite=Strict` session cookie; subsequent queue, control, and audio requests use the cookie, and queued item URLs do not contain the token.

For HTTPS, you may optionally put the bound service behind `tailscale serve`; preserve the token query string when opening the resulting HTTPS URL.

## Register the separate Stop hook

The operator must add this as an additional Stop hook. It is intentionally not registered by this change:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/phone-speak.py"
          }
        ]
      }
    ]
  }
}
```

The pre-existing duplicate registration of `auto-speak.sh` in the plugin `hooks/hooks.json` and `~/.claude/settings.json` is deliberately left untouched.

## Commands

```text
phone-voice.sh enroll
phone-voice.sh unenroll
phone-voice.sh status
phone-voice.sh speed 0.5..3.0
phone-voice.sh serve
phone-voice.sh stop
```

All phone state lives in `~/.claude-tts-phone/`: enrollment, token, playback speed, synthesized `queue/`, transient `pending/` jobs, the FIFO worker lock and rolling speech hashes, technical-transform detail cache, `server.pid`, and `played.log`. The token file and `played.log` are mode 600. Unenrolling stops the owned server and removes its token. The phone hook uses macOS `say` only for file output and never invokes `afplay` or another speaker fallback.

Phone file synthesis and the existing Mac voice path can invoke `say` at the same time. The phone worker runs `say` with niceness 10 and, when macOS `taskpolicy` is available, background scheduling (`taskpolicy -b`) so the Mac playback path gets priority. Under sustained simultaneous use, phone audio may therefore appear in the queue later than Mac speech.

## Optional `/vm phone ...` dispatch

No change is made to `vm-toggle.sh`. To opt into a dispatcher, invoke `bin/vm-dispatch.sh` where you currently invoke `bin/vm-toggle.sh`. It routes `phone ...` to `phone-voice.sh` and execs the original `vm-toggle.sh` with all other arguments unchanged.

Repository note: the existing `.gitignore` ignores `bin/*`. This additive-only implementation does not edit that file, so `bin/phone-audio-server.py`, `bin/phone-voice.sh`, and `bin/vm-dispatch.sh` require an explicit `git add -f` if an operator later chooses to commit them.
