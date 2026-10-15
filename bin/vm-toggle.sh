#!/usr/bin/env bash
# vm-toggle.sh — Direct config manipulation for /vm slash command
# Config file: /tmp/claude-voice-config
# See: ELLE_Advanced_Voice_Mode_Toggles_Spec.md

CONFIG="${CLAUDE_VOICE_CONFIG:-/tmp/claude-voice-config}"
PID_FILE="/tmp/claude-skip-listener.pid"
ACTIVE_SESSION_ID_FILE="/tmp/claude-tts-active-session-id"
ACTIVE_TRANSCRIPT_PATH_FILE="/tmp/claude-tts-active-transcript-path"
ACTIVE_SOURCE_LABEL_FILE="/tmp/claude-tts-active-source"
CLAIM_NEXT_SESSION_FILE="/tmp/claude-tts-claim-next-session"
LAST_SOURCE_FILE="/tmp/claude-tts-last-source"
LAST_SESSION_FILE="/tmp/claude-tts-last-session"
FOCUSED_SESSION_ID_FILE="/tmp/claude-tts-focused-session-id"
FOCUSED_SOURCE_LABEL_FILE="/tmp/claude-tts-focused-source"
FOREGROUND_ALLOWLIST="${CLAUDE_TTS_FOREGROUND_ALLOWLIST:-/tmp/claude-tts-foreground-sessions}"
RESTART_QUEUE_FLAG="/tmp/claude-tts-restart-queue"
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
MBP_STOPALL_PUBLISH_MODE="/Users/christopherdemartino/.claude-tts/bin/stopall-bridge-publish-mode.sh"
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)

LOCAL_SKIP_LISTENER_SRC="$PLUGIN_DIR/cmd/skip-listener/main.swift"
LOCAL_PROCESS_LAUNCH_SRC="$PLUGIN_DIR/cmd/skip-listener/ProcessLaunch.swift"
LOCAL_STOP_GENERATION_SRC="$PLUGIN_DIR/cmd/skip-listener/StopGeneration.swift"
LOCAL_STOP_ARCHIVE_SRC="$PLUGIN_DIR/cmd/skip-listener/StopAllArchive.swift"
LOCAL_BACKFILL_IMPORT_SRC="$PLUGIN_DIR/cmd/skip-listener/BackfillImport.swift"
LOCAL_SPEAK_TEXT_SRC="$PLUGIN_DIR/cmd/speak-text/main.go"
LOCAL_STOPALL_DRAIN="$PLUGIN_BIN/stopall-drain.sh"
LOCAL_SKIP_LISTENER_BUILD="$PLUGIN_BIN/build-skip-listener-app.sh"
LOCAL_SKIP_LISTENER_INSTALL="$PLUGIN_BIN/install-skip-listener-launchagent.sh"
LOCAL_SKIP_LISTENER_RESTART="$PLUGIN_BIN/restart-skip-listener-launchagent.sh"
LOCAL_TTS_BRIDGE="$PLUGIN_BIN/tts-bridge.sh"
LOCAL_STOPALL_PUBLISH_MODE="$PLUGIN_BIN/stopall-bridge-publish-mode.sh"
BACKFILL_STATUS_DIR="${CLAUDE_TTS_BACKFILL_STATUS_DIR:-/tmp/claude-tts-backfill-status}"

DEFAULTS="voice=on
mic=on
target=both
target_drop_nonmatching=false
speed=300
volume=normal
engine=say
openai_voice=nova
summary=on
code=silent
cue=session
cue_frequency=change
subtitle=off
mic_device="
SPEED_MIN=150
SPEED_MAX=450
SPEED_STEP=25
SPEED_DEFAULT=300

ssh_mbp() {
    ssh "${SSH_OPTS[@]}" "$MBP_HOST" "$@"
}

scp_mbp() {
    scp "${SSH_OPTS[@]}" "$@"
}

detect_current_session_id() {
    local var value
    for var in CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID SESSION_ID CODEX_SESSION_ID CLAUDE_CONVERSATION_ID; do
        value="${!var:-}"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

detect_current_source_label() {
    if [ -n "${CLAUDE_TTS_SESSION_SOURCE:-}" ]; then
        printf '%s\n' "$CLAUDE_TTS_SESSION_SOURCE"
        return 0
    fi
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ] || [ -n "${CLAUDE_CONVERSATION_ID:-}" ]; then
        printf '%s\n' "Claude Code"
        return 0
    fi

    if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
        printf '%s\n' "Codex"
        return 0
    fi

    return 1
}

set_local_focus() {
    local session_id="$1"
    local source_label="$2"

    if [ -n "$session_id" ]; then
        printf '%s\n' "$session_id" > "$FOCUSED_SESSION_ID_FILE"
    else
        rm -f "$FOCUSED_SESSION_ID_FILE"
    fi

    if [ -n "$source_label" ]; then
        printf '%s\n' "$source_label" > "$FOCUSED_SOURCE_LABEL_FILE"
    else
        rm -f "$FOCUSED_SOURCE_LABEL_FILE"
    fi
}

clear_local_focus() {
    rm -f "$FOCUSED_SESSION_ID_FILE" "$FOCUSED_SOURCE_LABEL_FILE"
}

append_foreground_allowlist() {
    local sid="$1"
    [ -z "$sid" ] && return 0
    if [ ! -f "$FOREGROUND_ALLOWLIST" ]; then
        printf '%s\n' "$sid" > "$FOREGROUND_ALLOWLIST"
    elif ! grep -Fxq -- "$sid" "$FOREGROUND_ALLOWLIST" 2>/dev/null; then
        printf '%s\n' "$sid" >> "$FOREGROUND_ALLOWLIST"
    fi
}

ensure_suppress_background_on() {
    # Write suppress_background=on to config only if not already explicitly set to off
    local cur
    cur="$(grep '^suppress_background=' "$CONFIG" 2>/dev/null | cut -d= -f2 || true)"
    if [ "$cur" != "off" ]; then
        if grep -q '^suppress_background=' "$CONFIG" 2>/dev/null; then
            sed -i '' 's/^suppress_background=.*/suppress_background=on/' "$CONFIG"
        else
            echo "suppress_background=on" >> "$CONFIG"
        fi
    fi
}

parse_focus_field() {
    local payload="$1"
    local key="$2"

    printf '%s\n' "$payload" | awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    '
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
    kill_remote_tts_bridge >/dev/null 2>&1 || true
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
cd '$MBP_PLUGIN_ROOT' >/dev/null 2>&1
go build -o '$MBP_PLUGIN_ROOT/bin/speak-text' ./cmd/speak-text >> \"\$LOG\" 2>&1 || status=\$?
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
        "$LOCAL_PROCESS_LAUNCH_SRC"
        "$LOCAL_STOP_GENERATION_SRC"
        "$LOCAL_STOP_ARCHIVE_SRC"
        "$LOCAL_BACKFILL_IMPORT_SRC"
        "$LOCAL_SPEAK_TEXT_SRC"
        "$LOCAL_STOPALL_DRAIN"
        "$LOCAL_SKIP_LISTENER_BUILD"
        "$LOCAL_SKIP_LISTENER_INSTALL"
        "$LOCAL_SKIP_LISTENER_RESTART"
        "$LOCAL_TTS_BRIDGE"
        "$LOCAL_STOPALL_PUBLISH_MODE"
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
    ssh_mbp "mkdir -p '$MBP_PLUGIN_ROOT/bin' '$MBP_PLUGIN_ROOT/cmd/skip-listener' '$MBP_PLUGIN_ROOT/cmd/speak-text'" || return 1

    scp_mbp "$LOCAL_SKIP_LISTENER_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/main.swift" || return 1
    scp_mbp "$LOCAL_PROCESS_LAUNCH_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/ProcessLaunch.swift" || return 1
    scp_mbp "$LOCAL_STOP_GENERATION_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/StopGeneration.swift" || return 1
    scp_mbp "$LOCAL_STOP_ARCHIVE_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/StopAllArchive.swift" || return 1
    scp_mbp "$LOCAL_BACKFILL_IMPORT_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/skip-listener/BackfillImport.swift" || return 1
    scp_mbp "$LOCAL_SPEAK_TEXT_SRC" "$MBP_HOST:$MBP_PLUGIN_ROOT/cmd/speak-text/main.go" || return 1
    scp_mbp "$LOCAL_STOPALL_DRAIN" "$MBP_HOST:$MBP_PLUGIN_ROOT/bin/stopall-drain.sh" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_BUILD" "$MBP_HOST:$MBP_SKIP_LISTENER_BUILD" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_INSTALL" "$MBP_HOST:$MBP_SKIP_LISTENER_INSTALL" || return 1
    scp_mbp "$LOCAL_SKIP_LISTENER_RESTART" "$MBP_HOST:$MBP_SKIP_LISTENER_RESTART" || return 1
    scp_mbp "$LOCAL_TTS_BRIDGE" "$MBP_HOST:$MBP_TTS_BRIDGE" || return 1
    scp_mbp "$LOCAL_STOPALL_PUBLISH_MODE" "$MBP_HOST:$MBP_STOPALL_PUBLISH_MODE" || return 1

    kill_remote_tts_bridge || return 1
    signer="$(remote_skip_listener_identity)"

    if ssh_mbp "
        chmod +x '$MBP_SKIP_LISTENER_BUILD' '$MBP_SKIP_LISTENER_INSTALL' '$MBP_SKIP_LISTENER_RESTART' '$MBP_TTS_BRIDGE' '$MBP_STOPALL_PUBLISH_MODE' '$MBP_PLUGIN_ROOT/bin/stopall-drain.sh' && \
        cd '$MBP_PLUGIN_ROOT' && go build -o '$MBP_PLUGIN_ROOT/bin/speak-text' ./cmd/speak-text && \
        chmod +x '$MBP_PLUGIN_ROOT/bin/speak-text' && \
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
    [ "${CLAUDE_TTS_NO_SYNC:-0}" = "1" ] && return 0
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
    [ "${CLAUDE_TTS_NO_SYNC:-0}" = "1" ] && return 0
    # Sync config to MBP
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "cat > /tmp/claude-voice-config" < "$CONFIG" 2>/dev/null &
    disown 2>/dev/null
}

migrate_cue_settings() {
    local cue frequency
    [ ! -f "$CONFIG" ] && return 0
    cue="$(read_config "cue")"
    case "$cue" in
        on) update_toggle "cue" "session" ;;
        session|source|both|off) ;;
        *) update_toggle "cue" "session" ;;
    esac
    frequency="$(read_config "cue_frequency")"
    case "$frequency" in
        change|always) ;;
        *) update_toggle "cue_frequency" "change" ;;
    esac
}

current_session_metadata() {
    local session_id source_label transcript_path
    session_id="$(detect_current_session_id || true)"
    source_label="$(detect_current_source_label || true)"
    [ -z "$session_id" ] && return 1
    [ -z "$source_label" ] && source_label="Claude Code"
    transcript_path="${CLAUDE_TRANSCRIPT_PATH:-}"
    if [ -z "$transcript_path" ] && [ -f "$ACTIVE_TRANSCRIPT_PATH_FILE" ]; then
        transcript_path="$(cat "$ACTIVE_TRANSCRIPT_PATH_FILE" 2>/dev/null)"
    fi
    python3 "$PLUGIN_BIN/session-metadata.py" show \
        --source "$source_label" --session-id "$session_id" 2>/dev/null || \
    python3 "$PLUGIN_BIN/session-metadata.py" register \
        --source "$source_label" --session-id "$session_id" \
        --cwd "$PWD" --transcript-path "$transcript_path" 2>/dev/null
}

handle_name_command() {
    local nickname="${1:-}" session_id source_label result
    session_id="$(detect_current_session_id || true)"
    source_label="$(detect_current_source_label || true)"
    [ -z "$source_label" ] && source_label="Claude Code"
    if [ -z "$session_id" ]; then
        echo "No current Claude/Codex session ID was found in this shell." >&2
        return 1
    fi
    if [ -n "$nickname" ]; then
        result=$(python3 "$PLUGIN_BIN/session-metadata.py" override \
            --source "$source_label" --session-id "$session_id" --name "$nickname") || return 1
        echo "Session name: $(printf '%s' "$result" | jq -r '.display_name')"
        echo "  speech_name=$(printf '%s' "$result" | jq -r '.speech_name')"
        echo "  provenance=override"
        return 0
    fi
    result="$(current_session_metadata)" || return 1
    echo "Session name: $(printf '%s' "$result" | jq -r '.display_name')"
    echo "  speech_name=$(printf '%s' "$result" | jq -r '.speech_name')"
    echo "  provenance=$(printf '%s' "$result" | jq -r '.name_provenance')"
}

current_speed() {
    local speed
    speed="$(read_config "speed")"
    if [[ "$speed" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$speed"
    else
        printf '%s\n' "$SPEED_DEFAULT"
    fi
}

set_speed() {
    local speed="$1"

    if ! [[ "$speed" =~ ^[0-9]+$ ]]; then
        echo "Speed must be an integer wpm value." >&2
        return 1
    fi

    if [ "$speed" -lt "$SPEED_MIN" ] || [ "$speed" -gt "$SPEED_MAX" ]; then
        echo "Speed must be between ${SPEED_MIN} and ${SPEED_MAX} wpm." >&2
        return 1
    fi

    update_toggle "speed" "$speed"
}

handle_speed_command() {
    local action="${1:-status}"
    local speed

    case "$action" in
        status)
            echo "Speed: $(current_speed) wpm"
            ;;
        up)
            speed="$(current_speed)"
            speed=$((speed + SPEED_STEP))
            [ "$speed" -gt "$SPEED_MAX" ] && speed="$SPEED_MAX"
            set_speed "$speed" || return 1
            echo "Speed: ${speed} wpm"
            ;;
        down)
            speed="$(current_speed)"
            speed=$((speed - SPEED_STEP))
            [ "$speed" -lt "$SPEED_MIN" ] && speed="$SPEED_MIN"
            set_speed "$speed" || return 1
            echo "Speed: ${speed} wpm"
            ;;
        default|reset)
            set_speed "$SPEED_DEFAULT" || return 1
            echo "Speed: ${SPEED_DEFAULT} wpm"
            ;;
        *)
            if [[ "$action" =~ ^[0-9]+$ ]]; then
                set_speed "$action" || return 1
                echo "Speed: ${action} wpm"
            else
                echo "Usage: /vm speed [status|up|down|default|<wpm>]" >&2
                return 1
            fi
            ;;
    esac
}

current_engine() {
    local engine
    engine="$(read_config "engine")"
    case "$engine" in
        openai) printf '%s\n' "openai" ;;
        *) printf '%s\n' "say" ;;
    esac
}

handle_engine_command() {
    local action="${1:-status}"

    case "$action" in
        status)
            echo "Engine: $(current_engine)"
            ;;
        say|openai)
            update_toggle "engine" "$action"
            echo "Engine: $action"
            ;;
        *)
            echo "Usage: /vm engine [status|say|openai]" >&2
            return 1
            ;;
    esac
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
    rm -f /tmp/claude-tts-log-command

    ssh -o ConnectTimeout=3 -o BatchMode=yes "$MBP_HOST" "
        pkill say 2>/dev/null || true
        pkill afplay 2>/dev/null || true
        rm -f /tmp/claude-tts-skip /tmp/claude-tts-pause /tmp/claude-tts-playing
        rm -f /tmp/claude-tts-last-text /tmp/claude-tts-last-speed /tmp/claude-tts-last-volume
        rm -f '$LAST_SOURCE_FILE' '$LAST_SESSION_FILE'
        rm -f /tmp/claude-tts-transcript-path /tmp/claude-tts-repeat-anchor /tmp/claude-tts-active-segment
        rm -f /tmp/claude-tts-log-command
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
        rm -f '$FOCUSED_SESSION_ID_FILE' '$FOCUSED_SOURCE_LABEL_FILE' '$RESTART_QUEUE_FLAG'
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
    clear_local_focus
}

show_status() {
    local deferred_count=0 invoking_session_id source_label metadata
    local allowlisted voice_state voice_setting suppress_bg
    if [ ! -f "$CONFIG" ]; then
        echo "Voice mode: OFF (text mode)"
        return
    fi
    if [ -d /tmp/claude-tts-deferred-queue ]; then
        deferred_count=$(find /tmp/claude-tts-deferred-queue -maxdepth 1 -type d -name 'entry-*' | wc -l | tr -d ' ')
    fi
    echo "Voice mode: ACTIVE"
    echo "---"
    echo "  routing=global"
    invoking_session_id="$(detect_current_session_id || true)"
    source_label="$(detect_current_source_label || true)"
    echo "  invoking_session_id=${invoking_session_id:-<not set>}"
    metadata="$(current_session_metadata 2>/dev/null || true)"
    if [ -n "$metadata" ]; then
        echo "  nickname=$(printf '%s' "$metadata" | jq -r '.display_name')"
        echo "  nickname_provenance=$(printf '%s' "$metadata" | jq -r '.name_provenance')"
    else
        echo "  nickname=<unresolved>"
        echo "  nickname_provenance=unknown"
    fi
    if [ ! -s "$FOREGROUND_ALLOWLIST" ]; then
        allowlisted="open"
    elif [ -n "$invoking_session_id" ] && grep -Fxq -- "$invoking_session_id" "$FOREGROUND_ALLOWLIST" 2>/dev/null; then
        allowlisted="yes"
    else
        allowlisted="no"
    fi
    voice_setting="$(read_config "voice")"
    suppress_bg="$(read_config "suppress_background")"
    if [ "$voice_setting" != "on" ]; then
        voice_state="off"
    elif [ "$suppress_bg" = "on" ] && [ "$allowlisted" = "no" ]; then
        voice_state="muted (bg)"
    elif [ "$suppress_bg" = "on" ] && [ "$allowlisted" = "open" ]; then
        voice_state="on (open)"
    else
        voice_state="on"
    fi
    echo "  allowlisted=$allowlisted"
    echo "  voice: $voice_state"
    while IFS= read -r line; do
        [ -n "$line" ] && echo "  $line"
    done < "$CONFIG"
    if [ -f "$ACTIVE_SESSION_ID_FILE" ]; then
        echo "  last_session_id=$(cat "$ACTIVE_SESSION_ID_FILE" 2>/dev/null)"
    fi
    if [ -f "$ACTIVE_SOURCE_LABEL_FILE" ]; then
        echo "  last_source=$(cat "$ACTIVE_SOURCE_LABEL_FILE" 2>/dev/null)"
    fi
    if [ -f "$FOCUSED_SESSION_ID_FILE" ]; then
        echo "  focused_session_id=$(cat "$FOCUSED_SESSION_ID_FILE" 2>/dev/null)"
    fi
    if [ -f "$FOCUSED_SOURCE_LABEL_FILE" ]; then
        echo "  focused_source=$(cat "$FOCUSED_SOURCE_LABEL_FILE" 2>/dev/null)"
    fi
    if [ "${deferred_count:-0}" -gt 0 ]; then
        echo "  deferred_queue_count=$deferred_count"
    fi
}

run_doctor() {
    local overall=0
    local config_present="no"
    local voice_setting="off"
    local mic_setting="off"
    local speed_setting=""
    local signer=""
    local launch_snapshot=""
    local skip_lines=""
    local bridge_lines=""
    local bridge_count=0
    local doctor_output=""
    local doctor_status=0
    local err_health=""

    if [ -f "$CONFIG" ]; then
        config_present="yes"
        voice_setting="$(read_config "voice")"
        mic_setting="$(read_config "mic")"
        speed_setting="$(read_config "speed")"
        [ -z "$voice_setting" ] && voice_setting="off"
        [ -z "$mic_setting" ] && mic_setting="off"
    fi

    signer="$(remote_skip_listener_identity)"
    [ -z "$signer" ] && overall=1

    launch_snapshot="$(ssh_mbp "launchctl print gui/\$(id -u)/com.elle.skip-listener 2>/dev/null | egrep 'state =|pid =|runs =|forks =|path = ' || true")"
    skip_lines="$(ssh_mbp "ps -axo pid=,comm=,args= | awk 'index(\$0, \"$MBP_SKIP_LISTENER\") && \$2 != \"zsh\" && \$2 != \"sshd\" && \$2 != \"awk\" {print}'")"
    bridge_lines="$(ssh_mbp "ps -axo pid=,comm=,args= | awk 'index(\$0, \"$MBP_TTS_BRIDGE mac-mini-ts\") && (\$2 == \"login\" || \$2 == \"/bin/bash\" || \$2 == \"bash\") {print}'")"
    if [ -n "$bridge_lines" ]; then
        bridge_count=$(printf '%s\n' "$bridge_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    fi
    doctor_output="$(ssh_mbp "'$MBP_SKIP_LISTENER' --doctor" 2>&1)"
    doctor_status=$?

    if [ "$doctor_status" -ne 0 ]; then
        overall=1
    fi

    if [ "$voice_setting" = "on" ]; then
        if ! printf '%s\n' "$launch_snapshot" | grep -q 'state = running'; then
            overall=1
        fi
        [ -z "$skip_lines" ] && overall=1
        [ -z "$bridge_lines" ] && overall=1
        [ "${bridge_count:-0}" -ne 1 ] && overall=1
    fi

    err_health="$(ssh_mbp "grep -aiE 'Accessibility|Input Monitoring|Event tap|denied|fatal|error' /tmp/elle-skip-listener.err 2>/dev/null | tail -n 5 || true")"
    if [ -n "$err_health" ]; then
        overall=1
    fi

    echo "Voice mode doctor"
    echo "---"
    echo "  local_config_present=$config_present"
    echo "  local_voice=$voice_setting"
    echo "  local_mic=$mic_setting"
    [ -n "$speed_setting" ] && echo "  local_speed=$speed_setting"
    echo "  mbp_signer=${signer:-<missing>}"

    echo
    echo "SkipListener doctor:"
    if [ -n "$doctor_output" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
        done <<< "$doctor_output"
    else
        echo "  <no output>"
    fi

    echo
    echo "LaunchAgent:"
    if [ -n "$launch_snapshot" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
        done <<< "$launch_snapshot"
    else
        echo "  <not loaded>"
    fi

    echo
    echo "Processes:"
    if [ -n "$skip_lines" ]; then
        echo "  skip-listener:"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "    $line"
        done <<< "$skip_lines"
    else
        echo "  skip-listener: <not running>"
    fi
    if [ -n "$bridge_lines" ]; then
        echo "  tts-bridge (count=${bridge_count:-0}):"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "    $line"
        done <<< "$bridge_lines"
    else
        echo "  tts-bridge: <not running>"
    fi

    if [ -n "$err_health" ]; then
        echo
        echo "skip-listener health warnings:"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
        done <<< "$err_health"
    fi

    echo
    echo "Foreground allowlist:"
    local active_id=""
    [ -f "$ACTIVE_SESSION_ID_FILE" ] && active_id=$(cat "$ACTIVE_SESSION_ID_FILE" 2>/dev/null)
    if [ -n "$active_id" ]; then
        if [ -f "$FOREGROUND_ALLOWLIST" ] && grep -Fxq -- "$active_id" "$FOREGROUND_ALLOWLIST" 2>/dev/null; then
            echo "  [OK] active session in foreground allowlist (${active_id})"
        else
            echo "  [FAIL] active session NOT in foreground allowlist (${active_id}; forwarder silently blocked)"
            overall=1
        fi
    else
        echo "  [OK] no active session id claimed (suppress check skipped)"
    fi

    echo
    if [ "$overall" -eq 0 ]; then
        echo "RESULT: PASS"
        if [ "$config_present" = "no" ]; then
            echo "  Voice mode is currently off, but the trusted shortcut path looks healthy."
        fi
        return 0
    fi

    echo "RESULT: ATTENTION"
    echo "  One or more checks failed. If voice mode should be active, fix the failing section above before relying on shortcuts."
    return 1
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
        : > /tmp/claude-tts-stop-all-request
    "
}

remote_clear_autoplay_hold() {
    ssh_mbp ": > /tmp/claude-tts-autoplay-resume"
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

remote_log_command() {
    local action="$1"
    ssh_mbp "printf '%s\n' '$action' > /tmp/claude-tts-log-command"
}

read_backfill_stop_generation() {
    local generation="${CLAUDE_TTS_BACKFILL_GENERATION:-}"
    if [ -z "$generation" ]; then
        generation="$(ssh_mbp "generation=\$(awk -F= '\$1 == \"generation\" { print \$2; exit }' /tmp/claude-tts-stop-generation 2>/dev/null); printf '%s\n' \"\${generation:-0}\"" 2>/dev/null)" || return 1
    fi
    case "$generation" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$generation"
}

remote_log_status() {
    ssh_mbp "python3 - <<'PY'
import json
import os

manifest = '/tmp/claude-tts-playback-log/manifest.jsonl'
focus_file = '/tmp/claude-tts-focused-session-id'
current_file = '/tmp/claude-tts-current-item-id'

def read_text(path):
    try:
        return open(path, 'r', encoding='utf-8').read().strip()
    except FileNotFoundError:
        return ''

items = []
if os.path.exists(manifest):
    with open(manifest, 'r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                items.append(json.loads(line))
            except json.JSONDecodeError:
                pass

focus_session = read_text(focus_file)
filtered = [item for item in items if item.get('sessionID') == focus_session] if focus_session else list(items)
current_item_id = read_text(current_file)
current_item = next((item for item in filtered if item.get('id') == current_item_id), None)
latest_item = filtered[-1] if filtered else None

def preview(item):
    if not item:
        return ''
    path = item.get('normalizedTextPath', '')
    text = read_text(path)[:80]
    source = (item.get('sourceLabel') or '').strip()
    return f'[{source}] {text}' if source else text

print(f'total_count={len(items)}')
print(f'filtered_count={len(filtered)}')
print(f'focus_session={focus_session}')
print(f'current_item_id={current_item_id}')
print(f'current_preview={preview(current_item)}')
print(f'latest_item_id={(latest_item or {}).get(\"id\", \"\")}')
print(f'latest_preview={preview(latest_item)}')
PY"
}

clear_remote_focus() {
    ssh_mbp "
        rm -f '$FOCUSED_SESSION_ID_FILE' '$FOCUSED_SOURCE_LABEL_FILE' '$RESTART_QUEUE_FLAG'
    "
}

remote_focus_status() {
    ssh_mbp "
        setopt nonomatch 2>/dev/null || true
        focus_session=\$(cat '$FOCUSED_SESSION_ID_FILE' 2>/dev/null | tr -d '[:space:]')
        focus_source=\$(cat '$FOCUSED_SOURCE_LABEL_FILE' 2>/dev/null)
        current_session=\$(cat '$LAST_SESSION_FILE' 2>/dev/null | tr -d '[:space:]')
        match_count=0
        log_match_count=0
        focus_replay_allowed=0
        current_item_id=\$(cat /tmp/claude-tts-current-item-id 2>/dev/null | tr -d '[:space:]')

        if [ -n \"\$focus_session\" ]; then
            for entry in /tmp/claude-tts-queue/entry-*; do
                [ -d \"\$entry\" ] || continue
                entry_session=\$(cat \"\$entry/session\" 2>/dev/null | tr -d '[:space:]')
                [ \"\$entry_session\" = \"\$focus_session\" ] && match_count=\$((match_count + 1))
            done

            log_match_count=\$(python3 - <<'PY'
import json
import os

manifest = '/tmp/claude-tts-playback-log/manifest.jsonl'
focus_session = os.popen(\"cat '$FOCUSED_SESSION_ID_FILE' 2>/dev/null\").read().strip()
count = 0
if focus_session and os.path.exists(manifest):
    with open(manifest, 'r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (item.get('sessionID') or '').strip() == focus_session:
                count += 1
print(count)
PY
)
        fi

        printf 'focus_session=%s\n' \"\$focus_session\"
        printf 'focus_source=%s\n' \"\$focus_source\"
        printf 'match_count=%s\n' \"\$match_count\"
        printf 'log_match_count=%s\n' \"\$log_match_count\"
        printf 'current_session=%s\n' \"\$current_session\"
        printf 'current_item_id=%s\n' \"\$current_item_id\"
        if [ -f /tmp/claude-tts-playing ]; then
            printf 'playing=1\n'
        else
            printf 'playing=0\n'
        fi
    "
}

remote_focus_session() {
    local session_id="$1"
    local source_label="$2"
    local session_q source_q

    session_q=$(printf '%q' "$session_id")
    source_q=$(printf '%q' "$source_label")

    ssh_mbp "
        setopt nonomatch 2>/dev/null || true
        session_id=$session_q
        source_label=$source_q
        current_session=\$(cat '$LAST_SESSION_FILE' 2>/dev/null | tr -d '[:space:]')
        paused=0
        [ -f /tmp/claude-tts-pause ] && paused=1
        match_count=0
        log_match_count=0

        printf '%s\n' \"\$session_id\" > '$FOCUSED_SESSION_ID_FILE'
        if [ -n \"\$source_label\" ]; then
            printf '%s\n' \"\$source_label\" > '$FOCUSED_SOURCE_LABEL_FILE'
        else
            rm -f '$FOCUSED_SOURCE_LABEL_FILE'
        fi

        for entry in /tmp/claude-tts-queue/entry-*; do
            [ -d \"\$entry\" ] || continue
            entry_session=\$(cat \"\$entry/session\" 2>/dev/null | tr -d '[:space:]')
            [ \"\$entry_session\" = \"\$session_id\" ] && match_count=\$((match_count + 1))
        done

        log_counts=\$(python3 - <<'PY'
import json
import os

manifest = '/tmp/claude-tts-playback-log/manifest.jsonl'
session_id = os.popen(\"cat '$FOCUSED_SESSION_ID_FILE' 2>/dev/null\").read().strip()
count = 0
latest = None
if session_id and os.path.exists(manifest):
    with open(manifest, 'r', encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (item.get('sessionID') or '').strip() == session_id:
                count += 1
                latest = item
print(count, 1 if latest and latest.get('origin') != 'backfill' else 0)
PY
)
        log_match_count=\${log_counts%% *}
        focus_replay_allowed=\${log_counts##* }

        restarted=0
        replayed=0
        if [ \"\$paused\" -eq 0 ] && [ \"\$match_count\" -gt 0 ] && [ -f /tmp/claude-tts-playing ] && [ \"\$current_session\" != \"\$session_id\" ]; then
            : > '$RESTART_QUEUE_FLAG'
            pkill say 2>/dev/null || true
            pkill afplay 2>/dev/null || true
            pkill -f whisper-stream 2>/dev/null || true
            restarted=1
        elif [ \"\$paused\" -eq 0 ] && [ \"\$match_count\" -eq 0 ] && [ \"\$log_match_count\" -gt 0 ] && [ \"\$focus_replay_allowed\" -eq 1 ]; then
            printf 'timeline\n' > /tmp/claude-tts-log-command
            replayed=1
        fi

        printf 'focus_session=%s\n' \"\$session_id\"
        printf 'focus_source=%s\n' \"\$source_label\"
        printf 'match_count=%s\n' \"\$match_count\"
        printf 'log_match_count=%s\n' \"\$log_match_count\"
        printf 'current_session=%s\n' \"\$current_session\"
        printf 'paused=%s\n' \"\$paused\"
        printf 'restarted=%s\n' \"\$restarted\"
        printf 'replayed=%s\n' \"\$replayed\"
    "
}

do_repeat() {
    remote_log_command "replay"
}

handle_log_command() {
    local action="${1:-status}"
    local log_status filtered_count total_count focus_session current_preview latest_preview

    case "$action" in
        status)
            log_status="$(remote_log_status)" || return 1
            total_count="$(parse_focus_field "$log_status" "total_count")"
            filtered_count="$(parse_focus_field "$log_status" "filtered_count")"
            focus_session="$(parse_focus_field "$log_status" "focus_session")"
            current_preview="$(parse_focus_field "$log_status" "current_preview")"
            latest_preview="$(parse_focus_field "$log_status" "latest_preview")"

            if [ "${filtered_count:-0}" -eq 0 ] 2>/dev/null; then
                if [ "${total_count:-0}" -eq 0 ] 2>/dev/null; then
                    echo "Playback log: empty"
                elif [ -n "$focus_session" ]; then
                    echo "Playback log: no items for focused session"
                    echo "  focus_session=$focus_session"
                    echo "  total_items=${total_count:-0}"
                else
                    echo "Playback log: empty"
                fi
                return 0
            fi

            echo "Playback log: ${filtered_count} item(s)"
            [ -n "$focus_session" ] && echo "  focus_session=$focus_session"
            [ -n "$current_preview" ] && echo "  current=$current_preview"
            [ -n "$latest_preview" ] && echo "  latest=$latest_preview"
            ;;
        back|prev)
            remote_log_command "back" || return 1
            echo "Playback log back requested on the MBP."
            ;;
        play|timeline)
            remote_log_command "play" || return 1
            echo "Playback log timeline play requested on the MBP."
            ;;
        next)
            remote_log_command "next" || return 1
            echo "Playback log next requested on the MBP."
            ;;
        first|oldest)
            remote_log_command "first" || return 1
            echo "Playback log first item requested on the MBP."
            ;;
        replay|repeat)
            remote_log_command "replay" || return 1
            echo "Playback log replay requested on the MBP."
            ;;
        latest)
            remote_log_command "latest" || return 1
            echo "Playback log latest requested on the MBP."
            ;;
        *)
            echo "Usage: /vm log [status|play|timeline|back|next|first|oldest|replay|latest]" >&2
            return 1
            ;;
    esac
}

handle_backfill_command() {
    local requested="${1:-10}" session_id source_label metadata transcript result
    local batch_id batch_dir export_skipped status_file imported listener_skipped dupes tries latest request_generation

    if [ "$requested" = "status" ]; then
        latest=""
        if [ -d "$BACKFILL_STATUS_DIR" ]; then
            latest=$(ls -t "$BACKFILL_STATUS_DIR"/*.json 2>/dev/null | head -1 || true)
        fi
        if [ -z "$latest" ]; then
            echo "Backfill status: no completed imports"
            return 0
        fi
        imported=$(jq -r '.imported // 0' "$latest")
        listener_skipped=$(jq -r '.skipped // 0' "$latest")
        dupes=$(jq -r '.dupes // 0' "$latest")
        echo "Backfill status: imported $imported, skipped $listener_skipped (dupes $dupes)"
        return 0
    fi

    case "$requested" in
        ''|*[!0-9]*) echo "Usage: /vm backfill [1-100|status]" >&2; return 1 ;;
    esac
    if [ "$requested" -lt 1 ] || [ "$requested" -gt 100 ]; then
        echo "Backfill count must be between 1 and 100." >&2
        return 1
    fi

    session_id="$(detect_current_session_id || true)"
    source_label="$(detect_current_source_label || true)"
    [ -z "$source_label" ] && source_label="Claude Code"
    if [ -z "$session_id" ]; then
        echo "No invoking Claude/Codex session ID was found." >&2
        return 1
    fi
    metadata="$(python3 "$PLUGIN_BIN/session-metadata.py" show \
        --source "$source_label" --session-id "$session_id" 2>/dev/null || true)"
    transcript="$(printf '%s' "$metadata" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    [ -z "$transcript" ] && transcript="auto"

    if ! request_generation="$(read_backfill_stop_generation)"; then
        echo "Could not read the MBP stop generation; backfill was not exported." >&2
        return 1
    fi
    result="$(python3 "$PLUGIN_BIN/backfill-transcript.py" "$source_label" "$session_id" "$transcript" "$requested")" || return 1
    batch_id="$(printf '%s' "$result" | jq -r .batch_id)"
    batch_dir="$(printf '%s' "$result" | jq -r .batch_dir)"
    [ -d "$batch_dir" ] || { echo "Backfill exporter returned a missing batch directory." >&2; return 1; }
    printf '%s\n' "$request_generation" > "$batch_dir/.generation"
    export_skipped="$(printf '%s' "$result" | jq -r '.skipped // 0')"
    status_file="$BACKFILL_STATUS_DIR/$batch_id.json"

    tries=0
    while [ ! -f "$status_file" ] && [ "$tries" -lt 120 ]; do
        [ "${CLAUDE_TTS_BACKFILL_NO_WAIT:-0}" = "1" ] && break
        sleep 0.25
        tries=$((tries + 1))
    done
    if [ ! -f "$status_file" ]; then
        echo "Backfill queued: batch $batch_id (skipped $export_skipped before import)"
        return 0
    fi
    imported=$(jq -r '.imported // 0' "$status_file")
    listener_skipped=$(jq -r '.skipped // 0' "$status_file")
    dupes=$(jq -r '.dupes // 0' "$status_file")
    echo "imported $imported, skipped $listener_skipped (dupes $dupes)"
}

run_vm_command() {
case "${1:-status}" in
    status)
        show_status
        ;;
    doctor)
        run_doctor
        ;;
    on)
        clear_voice_session_claim
        write_full_config "$DEFAULTS"
        append_foreground_allowlist "${CLAUDE_CODE_SESSION_ID:-}"
        ensure_suppress_background_on
        case "${2:-both}" in
            claude) update_toggle "target" "claude"; scope_label="Claude Code only" ;;
            codex)  update_toggle "target" "codex";  scope_label="Codex only" ;;
            both|"") update_toggle "target" "both";  scope_label="Claude Code + Codex" ;;
            *) echo "Usage: /vm on [claude|codex]"; exit 1 ;;
        esac
        start_daemon
        remote_clear_autoplay_hold || exit 1
        echo "Voice mode ON — global speech + dictation enabled ($scope_label)"
        ;;
    off)
        rm -f "$CONFIG"
        local allowlist_session_count=0
        if [ -f "$FOREGROUND_ALLOWLIST" ]; then
            allowlist_session_count="$(awk 'NF { count++ } END { print count + 0 }' "$FOREGROUND_ALLOWLIST" 2>/dev/null || printf '0\n')"
        fi
        printf '%s [%s] allowlist-clear reason="vm off" ppid=%s session_ids=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${PPID:-unknown}" "$allowlist_session_count" >> /tmp/claude-tts-debug.log 2>/dev/null || true
        rm -f "$FOREGROUND_ALLOWLIST"
        clear_voice_session_claim
        stop_daemon
        echo "Voice mode OFF — text mode"
        ;;
    listen)
        clear_voice_session_claim
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        append_foreground_allowlist "${CLAUDE_CODE_SESSION_ID:-}"
        ensure_suppress_background_on
        update_toggle "voice" "on"
        update_toggle "mic" "off"
        case "${2:-both}" in
            claude) update_toggle "target" "claude"; scope_label="Claude Code only" ;;
            codex)  update_toggle "target" "codex";  scope_label="Codex only" ;;
            both|"") update_toggle "target" "both";  scope_label="Claude Code + Codex" ;;
            *) echo "Usage: /vm listen [claude|codex]"; exit 1 ;;
        esac
        start_daemon
        remote_clear_autoplay_hold || exit 1
        echo "Listen mode — TTS on, you type ($scope_label)"
        ;;
    test)
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        update_toggle "voice" "on"
        update_toggle "mic" "off"
        start_daemon
        prepare_voice_test
        queue_voice_test
        echo "Voice test queued — you should hear a short test sentence on the MBP."
        ;;
    dictation)
        clear_voice_session_claim
        [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
        append_foreground_allowlist "${CLAUDE_CODE_SESSION_ID:-}"
        ensure_suppress_background_on
        update_toggle "voice" "off"
        update_toggle "mic" "on"
        case "${2:-both}" in
            claude) update_toggle "target" "claude"; scope_label="Claude Code only" ;;
            codex)  update_toggle "target" "codex";  scope_label="Codex only" ;;
            both|"") update_toggle "target" "both";  scope_label="Claude Code + Codex" ;;
            *) echo "Usage: /vm dictation [claude|codex]"; exit 1 ;;
        esac
        start_daemon
        echo "Dictation mode — you speak, text replies ($scope_label)"
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
        do_repeat || exit 1
        echo "Playback log replay requested on the MBP."
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
    focus)
        case "${2:-current}" in
            off|clear)
                clear_local_focus
                clear_remote_focus || exit 1
                echo "Focused playback cleared — queue order is back to normal FIFO."
                ;;
            status)
                focus_status="$(remote_focus_status)" || exit 1
                focus_session="$(parse_focus_field "$focus_status" "focus_session")"
                focus_source="$(parse_focus_field "$focus_status" "focus_source")"
                match_count="$(parse_focus_field "$focus_status" "match_count")"
                log_match_count="$(parse_focus_field "$focus_status" "log_match_count")"
                current_session="$(parse_focus_field "$focus_status" "current_session")"
                current_item_id="$(parse_focus_field "$focus_status" "current_item_id")"
                playing="$(parse_focus_field "$focus_status" "playing")"

                if [ -z "$focus_session" ]; then
                    echo "Focused playback: off"
                    return 0
                fi

                echo "Focused playback: ${focus_source:-Session}"
                echo "  session_id=$focus_session"
                echo "  queued_matches=${match_count:-0}"
                echo "  log_matches=${log_match_count:-0}"
                echo "  playback_active=$([ "${playing:-0}" = "1" ] && echo yes || echo no)"
                if [ -n "$current_session" ]; then
                    if [ "${playing:-0}" = "1" ]; then
                        echo "  current_playback_session=$current_session"
                    else
                        echo "  last_playback_session=$current_session"
                    fi
                fi
                [ -n "$current_item_id" ] && echo "  current_log_item=$current_item_id"
                # Show invoking session id and whether it matches the lock
                echo "  invoking_session_id=${CLAUDE_CODE_SESSION_ID:-<not set>}"
                local locked_active
                locked_active="$(cat "$ACTIVE_SESSION_ID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
                if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -n "$locked_active" ]; then
                    if [ "$CLAUDE_CODE_SESSION_ID" = "$locked_active" ]; then
                        echo "  match=yes (invoking session IS the locked active session)"
                    else
                        echo "  match=no (invoking session differs from locked active ${locked_active})"
                    fi
                fi
                ;;
            *)
                focus_session="$2"
                if [ -z "$focus_session" ] || [ "$focus_session" = "current" ]; then
                    # Prefer CLAUDE_CODE_SESSION_ID (verified present in env when /vm runs)
                    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
                        focus_session="$CLAUDE_CODE_SESSION_ID"
                    else
                        focus_session="$(detect_current_session_id)"
                    fi
                fi
                focus_source="$(detect_current_source_label || true)"

                if [ -z "$focus_session" ]; then
                    echo "No current Claude/Codex session ID was found in this shell. Try /vm focus <session-id>."
                    exit 1
                fi

                # Write session id to active-session file (deterministic lock)
                printf '%s\n' "$focus_session" > "$ACTIVE_SESSION_ID_FILE"
                # Append to foreground allowlist
                append_foreground_allowlist "$focus_session"

                set_local_focus "$focus_session" "$focus_source"
                remote_clear_autoplay_hold || exit 1
                focus_result="$(remote_focus_session "$focus_session" "$focus_source")" || exit 1
                match_count="$(parse_focus_field "$focus_result" "match_count")"
                log_match_count="$(parse_focus_field "$focus_result" "log_match_count")"
                current_session="$(parse_focus_field "$focus_result" "current_session")"
                paused="$(parse_focus_field "$focus_result" "paused")"
                restarted="$(parse_focus_field "$focus_result" "restarted")"
                replayed="$(parse_focus_field "$focus_result" "replayed")"

                if [ "${restarted:-0}" = "1" ]; then
                    echo "Focused playback on ${focus_source:-this} session — jumped ahead to queued audio from this thread."
                elif [ "${replayed:-0}" = "1" ]; then
                    echo "Focused playback on ${focus_source:-this} session — replaying the newest logged item from this thread now."
                elif [ "${match_count:-0}" -gt 0 ] 2>/dev/null; then
                    if [ "${paused:-0}" = "1" ]; then
                        echo "Focused playback armed for ${focus_source:-this} session — ${match_count} queued item(s) match, and they will take priority after resume."
                    elif [ "$current_session" = "$focus_session" ]; then
                        echo "Focused playback confirmed for ${focus_source:-this} session — this thread is already active and future queued items stay prioritized."
                    else
                        echo "Focused playback armed for ${focus_source:-this} session — ${match_count} queued item(s) will play next."
                    fi
                elif [ "${log_match_count:-0}" -gt 0 ] 2>/dev/null; then
                    if [ "${paused:-0}" = "1" ]; then
                        echo "Focused playback armed for ${focus_source:-this} session — ${log_match_count} logged item(s) match and the newest one will replay after resume."
                    else
                        echo "Focused playback on ${focus_source:-this} session — the newest logged item is ready."
                    fi
                else
                    echo "Focused playback armed for ${focus_source:-this} session — no queued audio from this thread yet, but new replies will jump the line."
                fi
                ;;
        esac
        ;;
    log)
        handle_log_command "$2" || exit 1
        ;;
    backfill)
        handle_backfill_command "${2:-10}" || exit 1
        ;;
    speed)
        handle_speed_command "$2" || exit 1
        ;;
    engine)
        handle_engine_command "$2" || exit 1
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
    name)
        handle_name_command "${2:-}" || exit 1
        ;;
    cue)
        case "$2" in
            on|session) update_toggle "cue" "session"; echo "Cue: session" ;;
            source) update_toggle "cue" "source"; echo "Cue: source" ;;
            both) update_toggle "cue" "both"; echo "Cue: both" ;;
            off) cue_setting="off"; update_toggle "cue" "$cue_setting"; echo "Cue: off" ;;
            *) echo "Usage: /vm cue session|source|both|off" ;;
        esac
        ;;
    cue-frequency)
        case "$2" in
            always|change) update_toggle "cue_frequency" "$2"; echo "Cue frequency: $2" ;;
            *) echo "Usage: /vm cue-frequency always|change" ;;
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
            on)  update_toggle "summary" "on";  echo "Summary mode: on — spoken highlights enabled, with drill-down for tables and lists"  ;;
            off) update_toggle "summary" "off"; echo "Summary mode: off — full detail narrated"  ;;
            *)   echo "Usage: /vm summary on|off" ;;
        esac
        ;;
    background)
        case "${2:-status}" in
            on)
                [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
                if grep -q '^suppress_background=' "$CONFIG" 2>/dev/null; then
                    sed -i '' 's/^suppress_background=.*/suppress_background=on/' "$CONFIG"
                else
                    echo "suppress_background=on" >> "$CONFIG"
                fi
                echo "Background suppression: ON — only allowlisted sessions will speak"
                ;;
            off)
                [ ! -f "$CONFIG" ] && write_full_config "$DEFAULTS"
                if grep -q '^suppress_background=' "$CONFIG" 2>/dev/null; then
                    sed -i '' 's/^suppress_background=.*/suppress_background=off/' "$CONFIG"
                else
                    echo "suppress_background=off" >> "$CONFIG"
                fi
                echo "Background suppression: OFF — all sessions speak (global mode)"
                ;;
            status)
                local cur_bg
                cur_bg="$(grep '^suppress_background=' "$CONFIG" 2>/dev/null | cut -d= -f2 || true)"
                [ -z "$cur_bg" ] && cur_bg="unset (defaults to on when voice is active)"
                echo "Background suppression: $cur_bg"
                if [ -f "$FOREGROUND_ALLOWLIST" ]; then
                    echo "Foreground allowlist ($FOREGROUND_ALLOWLIST):"
                    while IFS= read -r line; do
                        [ -n "$line" ] && echo "  $line"
                    done < "$FOREGROUND_ALLOWLIST"
                else
                    echo "Foreground allowlist: empty"
                fi
                ;;
            *)
                echo "Usage: /vm background [on|off|status]" >&2
                return 1
                ;;
        esac
        ;;
    *)
        echo "Usage: /vm [help|on [claude|codex]|off|rebuild|listen [claude|codex]|test|dictation [claude|codex]|quiet|mute|unmute|repeat|skip|stop|pause|resume|forward|rewind|focus|log|backfill [N|status]|speed|engine|status|doctor|voice|mic|name|cue|cue-frequency|subtitle|summary]"
        echo "Keyboard: ctrl+ctrl pause/resume; ctrl+left/right sentence seek (playback-log nav while idle); ctrl+shift+left/right message/session-history nav (20-line skip during active file read); ctrl+up/down speed ±25 WPM."
        ;;
esac
}

vm_chain_arg_count() {
    local command="$1"
    local next_arg="${2:-}"

    case "$command" in
        on|listen|dictation)
            if [ "$next_arg" = "claude" ] || [ "$next_arg" = "codex" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        focus)
            if [ "$next_arg" = "status" ] || [ "$next_arg" = "off" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        speed)
            if [ "$next_arg" = "up" ] || [ "$next_arg" = "down" ] || [ "$next_arg" = "status" ] || [[ "$next_arg" =~ ^[0-9]+$ ]]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        engine)
            if [ "$next_arg" = "say" ] || [ "$next_arg" = "openai" ] || [ "$next_arg" = "status" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        log)
            if [ "$next_arg" = "status" ] || [ "$next_arg" = "back" ] || [ "$next_arg" = "next" ] || [ "$next_arg" = "replay" ] || [ "$next_arg" = "latest" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        backfill)
            if [ "$next_arg" = "status" ] || [[ "$next_arg" =~ ^[0-9]+$ ]]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        background)
            if [ "$next_arg" = "on" ] || [ "$next_arg" = "off" ] || [ "$next_arg" = "status" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        name)
            case "$next_arg" in
                ""|on|off|rebuild|listen|test|dictation|quiet|mute|unmute|repeat|skip|stop|pause|resume|forward|rewind|focus|log|backfill|speed|engine|status|doctor|voice|mic|name|cue|cue-frequency|subtitle|summary|background)
                    printf '%s\n' 1
                    ;;
                *) printf '%s\n' 2 ;;
            esac
            ;;
        cue-frequency)
            if [ "$next_arg" = "always" ] || [ "$next_arg" = "change" ]; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        voice|mic|cue|subtitle|summary)
            if [ "$next_arg" = "on" ] || [ "$next_arg" = "off" ] || \
               { [ "$command" = "cue" ] && { [ "$next_arg" = "session" ] || [ "$next_arg" = "source" ] || [ "$next_arg" = "both" ]; }; }; then
                printf '%s\n' 2
            else
                printf '%s\n' 1
            fi
            ;;
        help|-h|--help|off|quiet|mute|unmute|repeat|skip|stop|pause|resume|forward|rewind|test|doctor|status|rebuild)
            printf '%s\n' 1
            ;;
        *)
            printf '%s\n' 0
            ;;
    esac
}

migrate_cue_settings

vm_chain_args=("$@")
if [ "${#vm_chain_args[@]}" -eq 0 ]; then
    vm_chain_args=(status)
fi

while [ "${#vm_chain_args[@]}" -gt 0 ]; do
    vm_command="${vm_chain_args[0]}"
    vm_next_arg="${vm_chain_args[1]:-}"
    vm_arity="$(vm_chain_arg_count "$vm_command" "$vm_next_arg")"

    case "$vm_arity" in
        2)
            run_vm_command "$vm_command" "$vm_next_arg"
            vm_rc=$?
            vm_chain_args=("${vm_chain_args[@]:2}")
            ;;
        1)
            run_vm_command "$vm_command"
            vm_rc=$?
            vm_chain_args=("${vm_chain_args[@]:1}")
            ;;
        *)
            printf "vm: unknown command '%s' (skipped)\n" "$vm_command" >&2
            vm_chain_args=("${vm_chain_args[@]:1}")
            continue
            ;;
    esac

    if [ "$vm_rc" -ne 0 ]; then
        exit "$vm_rc"
    fi
done
