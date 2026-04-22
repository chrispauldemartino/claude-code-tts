#!/bin/bash
# setup-remote-tts.sh — One-time setup on MBP for remote TTS from Mac Mini
# Run this ONCE on your MBP. It installs:
#   1. TTS bridge (pulls text from Mac Mini, writes to local queue)
#   2. skip-listener as a bundled app under ~/.claude/plugins/claude-code-tts/
# Both auto-start on login. The bridge is a detached background script and
# skip-listener is owned by the com.elle.skip-listener LaunchAgent.
#
# Usage: ./setup-remote-tts.sh [tunnel-host]
# Example: ./setup-remote-tts.sh mac-mini-ts

HOST="${1:-mac-mini-ts}"
INSTALL_DIR="$HOME/.claude-tts"
PLUGIN_ROOT="$HOME/.claude/plugins/claude-code-tts"
PLIST_DIR="$HOME/Library/LaunchAgents"

echo "=== Remote TTS Setup ==="
echo "Mac Mini host: $HOST"
echo "Install dir: $INSTALL_DIR"
echo ""

# Step 1: Create install directories
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$PLIST_DIR"
mkdir -p "$PLUGIN_ROOT/bin"
mkdir -p "$PLUGIN_ROOT/cmd/skip-listener"

# Step 2: Copy skip-listener source + helpers from Mac Mini
echo "Copying skip-listener source and helpers from $HOST..."
scp "$HOST:~/.claude/plugins/claude-code-tts/cmd/skip-listener/main.swift" \
    "$PLUGIN_ROOT/cmd/skip-listener/main.swift"
scp "$HOST:~/.claude/plugins/claude-code-tts/bin/build-skip-listener-app.sh" \
    "$PLUGIN_ROOT/bin/build-skip-listener-app.sh"
scp "$HOST:~/.claude/plugins/claude-code-tts/bin/install-skip-listener-launchagent.sh" \
    "$PLUGIN_ROOT/bin/install-skip-listener-launchagent.sh"
scp "$HOST:~/.claude/plugins/claude-code-tts/bin/restart-skip-listener-launchagent.sh" \
    "$PLUGIN_ROOT/bin/restart-skip-listener-launchagent.sh"
scp "$HOST:~/.claude/plugins/claude-code-tts/bin/tts-bridge.sh" \
    "$INSTALL_DIR/bin/tts-bridge.sh"
chmod +x \
    "$PLUGIN_ROOT/bin/build-skip-listener-app.sh" \
    "$PLUGIN_ROOT/bin/install-skip-listener-launchagent.sh" \
    "$PLUGIN_ROOT/bin/restart-skip-listener-launchagent.sh" \
    "$INSTALL_DIR/bin/tts-bridge.sh"

echo "Building SkipListener.app..."
"$PLUGIN_ROOT/bin/build-skip-listener-app.sh"

# Step 3: Create LaunchAgent for the bridge
echo "Installing LaunchAgent: com.elle.tts-bridge..."
cat > "$PLIST_DIR/com.elle.tts-bridge.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.elle.tts-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/bin/tts-bridge.sh</string>
        <string>${HOST}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/elle-tts-bridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/elle-tts-bridge.err</string>
</dict>
</plist>
PLIST

# Step 4: Load the bridge LaunchAgent and install the bundled skip-listener LaunchAgent
echo "Loading LaunchAgents..."
launchctl bootout "gui/$(id -u)" "$PLIST_DIR/com.elle.tts-bridge.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DIR/com.elle.tts-bridge.plist"
"$PLUGIN_ROOT/bin/install-skip-listener-launchagent.sh"

echo ""
echo "=== Setup Complete ==="
echo "TTS bridge: running (pulls from $HOST into /tmp/claude-tts-queue)"
echo "Skip listener: running from $PLUGIN_ROOT/bin/SkipListener.app"
echo ""
echo "Both will auto-start on login. To check status:"
echo "  launchctl list | grep com.elle"
echo ""
echo "To stop:"
echo "  launchctl unload ~/Library/LaunchAgents/com.elle.tts-bridge.plist"
echo "  launchctl unload ~/Library/LaunchAgents/com.elle.skip-listener.plist"
