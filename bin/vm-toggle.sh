#!/usr/bin/env bash
# vm-toggle.sh — Direct config manipulation for /vm slash command
# Config file: /tmp/claude-voice-config
# See: ELLE_Advanced_Voice_Mode_Toggles_Spec.md

CONFIG="/tmp/claude-voice-config"
PID_FILE="/tmp/claude-skip-listener.pid"
ACTIVE_SESSION_ID_FILE="/tmp/claude-tts-active-session-id"
ACTIVE_TRANSCRIPT_PATH_FILE="/tmp/claude-tts-active-transcript-path"
ACTIVE_SOURCE_LABEL_FILE="/tmp/claude-tts-active-source"
CLAIM_NEXT_SESSION_FILE="/tmp/claude-tts-claim-next-session"
LAST_SOURCE_FILE="/tmp/claude-tts-last-source"
LAST_SESSION_FILE="/tmp/claude-tts-last-session"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_BIN="$PLUGIN_DIR/bin"
MBP_HOST="christopherdemartino@demo-m5-mbp"
MBP_PLUGIN_ROOT="/Users/christopherdemartino/.claude/plugins/claude-code-tts"
# skip-listener is managed by LaunchAgent com.elle.skip-listener.plist on the MBP;
# vm-toggle.sh must NOT spawn its own copy, or two listeners run in parallel and
# every TTS entry / keyboard shortcut is processed twice (echo + double-skip bug).
MBP_SKIP_LISTENER_APP="$MBP_PLUGIN_ROOT/bin/SkipListener.app"
MBP_SKIP_LISTENER="$MBP_SKIP_LISTENER_APP/Contents/MacOS/skip-listener"
MBP_SKIP_LISTENER_LEGACY="$MBP_PLUGIN_ROOT/bin/skip-listener"
MBP_SKIP_LISTENER_BUILD="$MBP_PLUGIN_ROOT/bin/build-skip-listener-app.sh"
MBP_SKIP_LISTENER_INSTALL="$MBP_PLUGIN_ROOT/bin/install-skip-listener-launchagent.sh"
MBP_SKIP_LISTENER_RESTART="$MBP_PLUGIN_ROOT/bin/restart-skip-listener-launchagent.sh"
MBP_TTS_BRIDGE="/Users/christopherdemartino/.claude-tts/bin/tts-bridge.sh"
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)

LOCAL_SKIP_LISTENER_SRC="$PLUGIN_DIR/cmd/skip-listener/main.swift"
LOCAL_SKIP_LISTENER_BUILD="$PLUGIN_BIN/build-skip-listener-app.sh"
LOCAL_SKIP_LISTENER_INSTALL="$PLUGIN_BIN/install-skip-listener-launchagent.sh"
LOCAL_SKIP_LISTENER_RESTART="$PLUGIN_BIN/restart-skip-listener-launchagent.sh"
LOCAL_TTS_BRIDGE="$PLUGIN_BIN/tts-bridge.sh"

DEFAULTS="voice=on
mic=off
speed=300
volume=normal
summary=on
code=silent
cue=off
subtitle=off
mic_device="

ssh_mbp() {
    ssh "${SSH_OPTS[@]}" "$MBP_HOST" "$@"
}

scp_mbp() {
    scp "${SSH_OPTS[@]}" "$@"
}

kill_remote_tts_bridge() {
    ssh_mbp "
        screen -ls 2>/dev/null | awk '/tts-bridge/ {print \$1}' | xargs -I{} screen -S {} -X quit 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            bridge_pids=\$(ps -axo pid=,comm=,args= | awk 'index(\$0, \"$MBP_TTS_BRIDGE mac-mini-ts\") && (\$2 == \"login\" || \$2 == \"/bin/bash\") {print \$1}')
            [ -z \"\$bridge_pids\" ] && break
            printf '%s\n' \"\$bridge_pids\" | xargs kill 2>/dev/null || true
            sleep 0.2
        done
        bridge_pids=\$(ps -axo pid=,comm=,args= | awk 'index(\$0, \"$MBP_TTS_BRIDGE mac-mini-ts\") && (\$2 == \"login\" || \$2 == \"/bin/bash\") {print \$1}')
        [ -z \"\$bridge_pids\" ] || printf '%s\n' \"\$bridge_pids\" | xargs kill -9 2>/dev/null || true
        screen -wipe >/dev/null 2>&1 || true
    "
}

start_remote_tts_bridge() {
    ssh_mbp "
        nohup '$MBP_TTS_BRIDGE' mac-mini-ts </dev/null >/tmp/claude-tts-bridge.log 2>&1 &
    "
}

restart_remote_skip_listener() {
    ssh_mbp "
        if [ -x '$MBP_SKIP_LISTENER_RESTART' ]; then
            '$MBP_SKIP_LISTENER_RESTART'
        else
            launchctl kickstart -k gui/\$(id -u)/com.elle.skip-listener 2>/dev/null || \
                (pgrep -f skip-listener >/dev/null 2>&1 || nohup '$MBP_SKIP_LISTENER_LEGACY' </dev/null >/dev/null 2>&1 &)
        fi
    "
}

remote_skip_listener_identity() {
    ssh_mbp "codesign -dv --verbose=4 '$MBP_SKIP_LISTENER_APP' 2>&1 | awk -F= '/^Authority=Apple Development:/ {print \$2; exit}'" 2>/dev/null
}

trigger_remote_gui_rebuild() {
    local signer="$1"

    ssh_mbp "cat > /tmp/skip-listener-rebuild-gui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG=/tmp/skip-listener-rebuild-gui.log
: > \"\$LOG\"
status=0
if [ -n \"$signer\" ]; then
    export SKIP_LISTENER_CODESIGN_IDENTITY=\"$signer\"
fi
'$MBP_SKIP_LISTENER_BUILD' >> \"\$LOG\" 2>&1 || status=\$?
if [ \"\$status\" -eq 0 ]; then
    '$MBP_SKIP_LISTENER_INSTALL' >> \"\$LOG\" 2>&1 || status=\$?
fi
if [ \"\$status\" -eq 0 ]; then
    '$MBP_SKIP_LISTENER_RESTART' >> \"\$LOG\" 2>&1 || status=\$?
fi
echo \"__EXIT__\${status}\" >> \"\$LOG\"
EOF
chmod +x /tmp/skip-listener-rebuild-gui.sh
osascript -e 'tell application \"Terminal\" to activate' -e 'tell application \"Terminal\" to do script \"/tmp/skip-listener-rebuild-gui.sh\"'
" || return 1
}

wait_for_remote_gui_rebuild() {
    local timeout_s="${1:-90}"
    local waited=0
    local status_line=""

    while [ "$waited" -lt "$timeout_s" ]; do
        status_line="$(ssh_mbp "tail -n 1 /tmp/skip-listener-rebuild-gui.log 2>/dev/null || true" 2>/dev/null || true)"

        case "$status_line" in
            __EXIT__0)
                return 0
                ;;
            __EXIT__*)
                ssh_mbp "cat /tmp/skip-listener-rebuild-gui.log 2>/dev/null" 2>/dev/null || true
                return 1
                ;;
        esac

        sleep 2
        waited=$((waited + 2))
    done

    echo "GUI rebuild did not finish within ${timeout_s}s. Check /tmp/skip-listener-rebuild-gui.log on the MBP." >&2
    return 1
}

rebuild_remote_skip_listener() {
    local required_files=(
        "$LOCAL_SKIP_LISTENER_SRC"
        "$LOCAL_SKIP_LISTENER_BUILD"
        "$LOCAL_SKIP_LISTENER_INSTALL"
        "$LOCAL_SKIP_LISTENER_RESTART"
        "$LOCAL_TTS_BRIDGE"
    )
    local file
    local signer

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            echo "Missing local file: $file" >&2
            return 1
        fi
    done

    echo "Syncing skip-listener sources to $MBP_HOST..."
    ssh_mbp "mkdir -p '$MBP_PLUGIN_ROOT/bin' '$MBP_PLUGIN_ROOT/cmd/skip-listener'" || return 1

    scp_mbp "$LOCAL_SKIP_LISTENER_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/main.swift" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_BUILD" "$MBP_HOST:$MBP_SKIP_LISTENER_BUILD" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_INSTALL" "$MBP_HOST:$MBP_SKIP_LISTENER_INSTALL" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_RESTART" "$MBP_HOST:$MBP_SKIP_LISTENER_RESTART" || return 1
    scp_mbp "$LOCAL_TTS_BRIDGE" "$MBP_HOST:$MBP_TTS_BRIDGE" || return 1

    kill_remote_tts_bridge || return 1
    signer="$(remote_skip_listener_identity)"

    if ssh_mbp "
        chmod +x '$MBP_SKIP_LISTENER_BUILD' '$MBP_SKIP_LISTENER_INSTALL' '$MBP_SKIP_LISTENER_RESTART' '$MBP_TTS_BRIDGE' && \
        '$MBP_SKIP_LISTENER_BUILD' && \
        '$MBP_SKIP_LISTENER_INSTALL' && \
        nohup '$MBP_TTS_BRIDGE' mac-mini-ts </dev/null >/tmp/claude-tts-bridge.log 2>&1 &
    "; then
        return 0
    fi

    echo "Headless codesign failed on the MBP. Opening a local Terminal rebuild so macOS can use GUI keychain access..."
    trigger_remote_gui_rebuild "$signer" || return 1
    echo "Waiting for GUI rebuild to finish on the MBP..."
    wait_for_remote_gui_rebuild 120 || return 1
    start_remote_tts_bridge || return 1
}

read_config() {
    [ -f "$CONFIG" ] && grep "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2
}

write_full_config() {
    local tmp="${CONFIG}.tmp"
    printf '%s\n' "$1" > "$tmp"
    mv "$tmp" "$CONFIG"
    # Sync config to MBP
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "cat > /tmp/claude-voice-config" < "$CONFIG" 2>/dev/null &
    disown 2>/dev/null
}

update_toggle() {
    local key="$1" value="$2"
    if [ ! -f "$CONFIG" ]; then
        write_full_config "$DEFAULTS"
    fi
    if grep -q "^${key}=" "$CONFIG" 2>/dev/null; then
        sed -i '' "s/^${key}=.*/${key}=${value}/" "$CONFIG"
    else
        echo "${key}=${value}" >> "$CONFIG"
    fi
    # Sync config to MBP
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "cat > /tmp/claude-voice-config" < "$CONFIG" 2>/dev/null &
    disown 2>/dev/null
}

arm_voice_session_claim() {
    : > "$CLAIM_NEXT_SESSION_FILE"
    rm -f "$ACTIVE_SESSION_ID_FILE" "$ACTIVE_TRANSCRIPT_PATH_FILE" "$ACTIVE_SOURCE_LABEL_FILE"
    rm -f "$LAST_SOURCE_FILE" "$LAST_SESSION_FILE" "$PID_FILE"
    pkill -f "$PLUGIN_BIN/skip-listener" 2>/dev/null || true
    clear_voice_runtime_buffers
}

clear_voice_session_claim() {
    rm -f "$CLAIM_NEXT_SESSION_FILE" "$ACTIVE_SESSION_ID_FILE" "$ACTIVE_TRANSCRIPT_PATH_FILE" "$ACTIVE_SOURCE_LABEL_FILE"
    rm -f "$LAST_SOURCE_FILE" "$LAST_SESSION_FILE" "$PID_FILE"
    pkill -f "$PLUGIN_BIN/skip-listener" 2>/dev/null || true
    clear_voice_runtime_buffers
}

clear_voice_runtime_buffers() {
    rm -rf /tmp/claude-tts-remote
    mkdir -p /tmp/claude-tts-remote
    rm -f /tmp/claude-tts-spoken-hashes /tmp/claude-tts-queued-prefix /tmp/claude-tts-queued-length
    rm -f /tmp/claude-tts-last-text /tmp/claude-tts-last-speed /tmp/claude-tts-last-volume
    rm -f /tmp/claude-tts-last-source /tmp/claude-tts-last-session
    rm -f /tmp/claude-tts-transcript-path /tmp/claude-tts-repeat-anchor /tmp/claude-tts-active-segment

    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "
        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        rm -f /tmp/claude-tts-skip /tmp/claude-tts-pause /tmp/claude-tts-playing
        rm -f /tmp/claude-tts-last-text /tmp/claude-tts-last-speed /tmp/claude-tts-last-volume
        rm -f '$LAST_SOURCE_FILE' '$LAST_SESSION_FILE'
        rm -f /tmp/claude-tts-transcript-path /tmp/claude-tts-repeat-anchor /tmp/claude-tts-active-segment
        history_dir=\$(cat /tmp/claude-tts-history-dir 2>/dev/null || true)
        if [ -n \"\$history_dir\" ]; then
            rm -rf \"\$history_dir\"
        fi
        rm -f /tmp/claude-tts-history-dir
        rm -rf /tmp/claude-tts-queue
        mkdir -p /tmp/claude-tts-queue
    " 2>/dev/null || true
}

prepare_voice_test() {
    rm -f "$CLAIM_NEXT_SESSION_FILE"
    clear_voice_runtime_buffers
}

queue_voice_test() {
    local text="${1:-Voice mode test. If you hear this, the playback path is working.}"
    local speed
    speed=$(read_config "speed")
    [ -z "$speed" ] && speed="300"

    local remote_dir="/tmp/claude-tts-remote"
    local ts
    ts=$(date +%s%N)

    mkdir -p "$remote_dir"
    printf '%s\n' "$speed" > "$remote_dir/entry-${ts}.speed"
    printf '%s\n' "1.0" > "$remote_dir/entry-${ts}.volume"
    printf '%s\n' "Voice Test" > "$remote_dir/entry-${ts}.source"
    printf '%s\n' "$text" > "$remote_dir/entry-${ts}.txt"
}

start_daemon() {
    # Start skip-listener + TTS bridge on MBP.
    # The bridge runs detached with nohup so it survives the SSH session.
    # NOTE: skip-listener is owned by LaunchAgent com.elle.skip-listener.plist.
    # Prefer the bundled-app helper if present; fall back to the legacy loose binary
    # only on hosts that have not been migrated yet.
    kill_remote_tts_bridge >/dev/null 2>&1 || true
    ssh "${SSH_OPTS[@]}" "$MBP_HOST" \
        "if [ -x '$MBP_SKIP_LISTENER_RESTART' ]; then
             '$MBP_SKIP_LISTENER_RESTART' >/dev/null 2>&1
         else
             launchctl kickstart -k gui/\$(id -u)/com.elle.skip-listener 2>/dev/null || \
               (pgrep -f skip-listener >/dev/null 2>&1 || nohup '$MBP_SKIP_LISTENER_LEGACY' </dev/null >/dev/null 2>&1 &)
         fi
         nohup '$MBP_TTS_BRIDGE' mac-mini-ts </dev/null >/tmp/claude-tts-bridge.log 2>&1 &" \
        2>/dev/null &
    disown 2>/dev/null
}

stop_daemon() {
    # Unload the LaunchAgent on /vm off so KeepAlive cannot relaunch the listener
    # into a permission-prompt loop while voice mode is disabled.
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "
        launchctl bootout gui/\$(id -u) \$HOME/Library/LaunchAgents/com.elle.skip-listener.plist 2>/dev/null || \
            launchctl bootout gui/\$(id -u)/com.elle.skip-listener 2>/dev/null || \
            pkill -f '$MBP_SKIP_LISTENER' 2>/dev/null || true
        screen -ls | grep tts-bridge | cut -d. -f1 | xargs -I{} screen -S {} -X quit 2>/dev/null
        pkill -f tts-bridge 2>/dev/null
        pkill say 2>/dev/null
        pkill afplay 2>/dev/null
        rm -f /tmp/claude-tts-skip /tmp/claude-tts-pause
        rm -f /tmp/claude-tts-playing /tmp/claude-voice-listening
        rm -f /tmp/claude-voice-config /tmp/claude-tts-bridge-stop
        rm -rf /tmp/claude-tts-queue
    " 2>/dev/null
    # Clean up local flag files
    rm -f /tmp/claude-tts-skip /tmp/claude-tts-pause
    rm -f /tmp/claude-tts-playing /tmp/claude-voice-listening
    rm -f /tmp/claude-tts-forward /tmp/claude-tts-rewind
    rm -f /tmp/claude-tts-next-msg /tmp/claude-tts-prev-msg
    rm -f /tmp/claude-tts-pending /tmp/claude-tts-pending-ts
    rm -f /tmp/claude-tts-skip-listener-stop
    rm -f /tmp/claude-tts-spoken-hashes
}

show_status() {
    if [ ! -f "$CONFIG" ]; then
        echo "Voice mode: OFF (text mode)"
        return
    fi
    echo "Voice mode: ACTIVE"
    echo "---"
    echo "  routing=global"
    while IFS= read -r line; do
        [ -n "$line" ] && echo "  $line"
    done < "$CONFIG"
    if [ -f "$ACTIVE_SESSION_ID_FILE" ]; then
        echo "  last_session_id=$(cat "$ACTIVE_SESSION_ID_FILE" 2>/dev/null)"
    fi
    if [ -f "$ACTIVE_SOURCE_LABEL_FILE" ]; then
        echo "  last_source=$(cat "$ACTIVE_SOURCE_LABEL_FILE" 2>/dev/null)"
    fi
}

remote_skip() {
    ssh_mbp "
        preserve_pause=0
        [ -f /tmp/claude-tts-pause ] && preserve_pause=1

        for name in afplay say whisper-stream; do
            pkill -CONT \$name 2>/dev/null || true
        done

        : > /tmp/claude-tts-skip
        if [ \"\$preserve_pause\" -eq 0 ]; then
            rm -f /tmp/claude-tts-pause
        else
            : > /tmp/claude-tts-pause
        fi

        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        pkill -f whisper-stream 2>/dev/null || true
    "
}

remote_stop_all() {
    ssh_mbp "
        : > /tmp/claude-tts-skip
        rm -f /tmp/claude-tts-pause /tmp/claude-tts-playing /tmp/claude-voice-listening
        rm -f /tmp/claude-tts-active-segment /tmp/claude-voice-input-stop
        rm -f /tmp/claude-tts-reading-file
        rm -rf /tmp/claude-tts-speaking.lock
        rm -f /tmp/claude-tts-nav-index

        hist_dir=\$(cat /tmp/claude-tts-history-dir 2>/dev/null || true)
        if [ -n \"\$hist_dir\" ] && [ -f \"\$hist_dir/total\" ]; then
            cat \"\$hist_dir/total\" > /tmp/claude-tts-repeat-anchor
        fi

        pkill -f read-file.sh 2>/dev/null || true
        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        pkill -f voice-input 2>/dev/null || true
        pkill -f whisper-stream 2>/dev/null || true
    "
}

remote_pause() {
    ssh_mbp "
        : > /tmp/claude-tts-pause
        for name in afplay say whisper-stream; do
            pkill -STOP \$name 2>/dev/null || true
        done
    "
}

remote_resume() {
    ssh_mbp "
        rm -f /tmp/claude-tts-pause
        for name in afplay say whisper-stream; do
            pkill -CONT \$name 2>/dev/null || true
        done
    "
}

remote_seek() {
    local direction="$1"
    local flag=""
    local label=""

    case "$direction" in
        forward)
            flag="/tmp/claude-tts-forward"
            label="Forward"
            ;;
        rewind)
            flag="/tmp/claude-tts-rewind"
            label="Rewind"
            ;;
        *)
            echo "Unknown seek direction: $direction" >&2
            return 1
            ;;
    esac

    if ! ssh_mbp "[ -f /tmp/claude-tts-playing ]"; then
        echo "$label fallback only works during active playback right now."
        return 0
    fi

    ssh_mbp "
        : > '$flag'
        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        pkill -f whisper-stream 2>/dev/null || true
    "
}

do_repeat() {
    ssh_mbp "
        history_dir_file=/tmp/claude-tts-history-dir
        anchor_file=/tmp/claude-tts-repeat-anchor
        text_file=/tmp/claude-tts-last-text
        speed_file=/tmp/claude-tts-last-speed
        vol_file=/tmp/claude-tts-last-volume

        hist_dir=\$(cat \"\$history_dir_file\" 2>/dev/null || true)
        anchor=\$(cat \"\$anchor_file\" 2>/dev/null | tr -d '[:space:]')
        if [ -n \"\$hist_dir\" ] && [ -n \"\$anchor\" ]; then
            padded=\$(printf '%03d' \"\$anchor\" 2>/dev/null || true)
            if [ -f \"\$hist_dir/msg-\$padded.txt\" ]; then
                text_file=\"\$hist_dir/msg-\$padded.txt\"
                speed_file=\"\$hist_dir/msg-\$padded.speed\"
                vol_file=\"\$hist_dir/msg-\$padded.volume\"
            fi
        fi

        if [ ! -f \"\$text_file\" ]; then
            echo 'Nothing to repeat — no previous TTS response saved.'
            exit 1
        fi

        speed=\$(cat \"\$speed_file\" 2>/dev/null || echo '300')
        volume=\$(cat \"\$vol_file\" 2>/dev/null || echo '1.0')
        tmpfile=\"/tmp/claude-tts-repeat-\$\$.aiff\"

        echo \"Repeating saved response (speed=\$speed, volume=\$volume)...\"
        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        say -r \"\$speed\" -o \"\$tmpfile\" < \"\$text_file\" 2>/dev/null
        if [ -f \"\$tmpfile\" ]; then
            afplay --volume \"\$volume\" \"\$tmpfile\" 2>/dev/null
            rm -f \"\$tmpfile\"
        fi
        echo 'Done.'
    "
}

case "${1:-status}" in
    status)
        show_status
        ;;
    on)
        clear_voice_session_claim
        write_full_config "$DEFAULTS"
        start_daemon
        echo "Voice mode ON — global Claude Code + Codex speech enabled"
        ;;
    off)
        rm -f "$CONFIG"
        clear_voice_session_claim
        stop_daemon
        echo "Voice mode OFF — text mode"
        ;;
    listen)
        clear_voice_session_claim
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        update_toggle "voice" "on"
        update_toggle "mic" "off"
        update_toggle "cue" "off"
        start_daemon
        echo "Listen mode — global Claude Code + Codex speech, you type"
        ;;
    test)
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        update_toggle "voice" "on"
        update_toggle "mic" "off"
        update_toggle "cue" "off"
        start_daemon
        prepare_voice_test
        queue_voice_test
        echo "Voice test queued — you should hear a short test sentence on the MBP."
        ;;
    dictation)
        clear_voice_session_claim
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        update_toggle "voice" "off"
        update_toggle "mic" "on"
        update_toggle "cue" "off"
        start_daemon
        echo "Dictation mode — you speak, text replies"
        ;;
    quiet)
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        update_toggle "volume" "quiet"
        update_toggle "speed" "250"
        echo "Quiet mode — softer + faster speech"
        ;;
    mute)
        MUTE_FLAG="/tmp/claude-tts-muted"
        # Kill all active TTS playback immediately
        pkill -f "say.*claude-tts" 2>/dev/null
        pkill afplay 2>/dev/null
        pkill say 2>/dev/null
        # Save current voice state before muting
        cur_voice=$(read_config "voice")
        [ -z "$cur_voice" ] && cur_voice="on"
        echo "$cur_voice" > "$MUTE_FLAG"
        # Set voice=off but preserve everything else
        if [ ! -f "$CONFIG" ]; then
            write_full_config "$DEFAULTS"
        fi
        update_toggle "voice" "off"
        echo "Muted — TTS silenced, config preserved. /vm unmute to restore."
        ;;
    unmute)
        MUTE_FLAG="/tmp/claude-tts-muted"
        if [ ! -f "$MUTE_FLAG" ]; then
            echo "Not muted — nothing to unmute."
        else
            prev_voice=$(cat "$MUTE_FLAG" 2>/dev/null)
            [ -z "$prev_voice" ] && prev_voice="on"
            update_toggle "voice" "$prev_voice"
            rm -f "$MUTE_FLAG"
            echo "Unmuted — TTS restored."
        fi
        ;;
    repeat)
        do_repeat
        ;;
    skip)
        remote_skip || exit 1
        echo "Skip requested on the MBP."
        ;;
    stop)
        remote_stop_all || exit 1
        echo "Stop-all requested on the MBP."
        ;;
    pause)
        remote_pause || exit 1
        echo "Pause requested on the MBP."
        ;;
    resume)
        remote_resume || exit 1
        echo "Resume requested on the MBP."
        ;;
    forward)
        remote_seek "forward" || exit 1
        echo "Forward requested on the MBP."
        ;;
    rewind)
        remote_seek "rewind" || exit 1
        echo "Rewind requested on the MBP."
        ;;
    rebuild)
        rebuild_remote_skip_listener || exit 1
        echo "skip-listener rebuilt on $MBP_HOST"
        ;;
    voice)
        case "$2" in
            on)  clear_voice_session_claim; update_toggle "voice" "on";  echo "TTS: on (global Claude Code + Codex)"  ;;
            off) update_toggle "voice" "off"; echo "TTS: off" ;;
            *)   echo "Usage: /vm voice on|off" ;;
        esac
        ;;
    mic)
        case "$2" in
            on)  update_toggle "mic" "on";  echo "Mic: on"  ;;
            off) update_toggle "mic" "off"; echo "Mic: off" ;;
            *)   echo "Usage: /vm mic on|off" ;;
        esac
        ;;
    cue)
        case "$2" in
            on)  update_toggle "cue" "on";  echo "Cue: on"  ;;
            off) update_toggle "cue" "off"; echo "Cue: off" ;;
            *)   echo "Usage: /vm cue on|off" ;;
        esac
        ;;
    subtitle)
        case "$2" in
            on)  update_toggle "subtitle" "on";  echo "Subtitle: on"  ;;
            off) update_toggle "subtitle" "off"; echo "Subtitle: off" ;;
            *)   echo "Usage: /vm subtitle on|off" ;;
        esac
        ;;
    summary)
        case "$2" in
            on)  update_toggle "summary" "on";  echo "Summary mode: on — tables summarized, say 'read rows' for detail"  ;;
            off) update_toggle "summary" "off"; echo "Summary mode: off — all rows narrated"  ;;
            *)   echo "Usage: /vm summary on|off" ;;
        esac
        ;;
    *)
        echo "Usage: /vm [on|off|rebuild|mute|unmute|listen|test|dictation|quiet|repeat|skip|stop|pause|resume|forward|rewind|status|voice|mic|cue|subtitle|summary]"
        ;;
esac
