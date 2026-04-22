#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$PLUGIN_ROOT/cmd/skip-listener/main.swift"
APP="$PLUGIN_ROOT/bin/SkipListener.app"
EXE="$APP/Contents/MacOS/skip-listener"
PLIST="$APP/Contents/Info.plist"
LEGACY_EXE="$PLUGIN_ROOT/bin/skip-listener"

if [ ! -f "$SRC" ]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi

mkdir -p "$APP/Contents/MacOS"

choose_codesign_identity() {
    if [ -n "${SKIP_LISTENER_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$SKIP_LISTENER_CODESIGN_IDENTITY"
        return 0
    fi

    if [ -n "${APPLE_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$APPLE_CODESIGN_IDENTITY"
        return 0
    fi

    security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}'
}

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.elleai.skip-listener</string>
    <key>CFBundleName</key>
    <string>SkipListener</string>
    <key>CFBundleDisplayName</key>
    <string>ELLE Skip Listener</string>
    <key>CFBundleExecutable</key>
    <string>skip-listener</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$PLIST" >/dev/null

swiftc -O -o "$EXE" "$SRC"
cp "$EXE" "$LEGACY_EXE"
chmod +x "$EXE" "$LEGACY_EXE"

CODESIGN_IDENTITY="$(choose_codesign_identity || true)"
if [ -n "$CODESIGN_IDENTITY" ]; then
    if codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP" && \
       codesign --force --sign "$CODESIGN_IDENTITY" --identifier "com.elleai.skip-listener" --timestamp=none "$LEGACY_EXE"; then
        echo "Signed with identity: $CODESIGN_IDENTITY"
    else
        echo "Apple Development signing failed for '$CODESIGN_IDENTITY' — falling back to ad hoc" >&2
        codesign --force --sign - "$APP"
        codesign --force --sign - --identifier "com.elleai.skip-listener" "$LEGACY_EXE"
        echo "Signed ad hoc (interactive keychain access unavailable)"
    fi
else
    codesign --force --sign - "$APP"
    codesign --force --sign - --identifier "com.elleai.skip-listener" "$LEGACY_EXE"
    echo "Signed ad hoc (no Apple Development identity found)"
fi

codesign --verify --strict --verbose=2 "$APP"
codesign --verify --verbose=2 "$LEGACY_EXE"

echo "Built bundle: $APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|CDHash|TeamIdentifier" || true
echo "Updated legacy fallback binary: $LEGACY_EXE"
