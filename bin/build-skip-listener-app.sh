#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$PLUGIN_ROOT/cmd/skip-listener/main.swift"
APP="$PLUGIN_ROOT/bin/SkipListener.app"
EXE="$APP/Contents/MacOS/skip-listener"
PLIST="$APP/Contents/Info.plist"
LEGACY_EXE="$PLUGIN_ROOT/bin/skip-listener"
ALLOW_ADHOC="${SKIP_LISTENER_ALLOW_ADHOC:-0}"
TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/skip-listener-build.XXXXXX")"
APP_STAGE="$TMPDIR_BUILD/SkipListener.app"
EXE_STAGE="$APP_STAGE/Contents/MacOS/skip-listener"
PLIST_STAGE="$APP_STAGE/Contents/Info.plist"
LEGACY_STAGE="$TMPDIR_BUILD/skip-listener"

cleanup() {
    rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

if [ ! -f "$SRC" ]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi

mkdir -p "$APP_STAGE/Contents/MacOS"

choose_codesign_identity() {
    if [ -n "${SKIP_LISTENER_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$SKIP_LISTENER_CODESIGN_IDENTITY"
        return 0
    fi

    if [ -n "${APPLE_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$APPLE_CODESIGN_IDENTITY"
        return 0
    fi

    local available_identities
    available_identities="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2}')"

    if [ -e "$APP" ]; then
        local current_identity
        current_identity="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^Authority=Apple Development:/ {print $2; exit}')"
        if [ -n "$current_identity" ] && printf '%s\n' "$available_identities" | grep -Fx "$current_identity" >/dev/null; then
            printf '%s\n' "$current_identity"
            return 0
        fi
    fi

    local identity_count
    identity_count="$(printf '%s\n' "$available_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$identity_count" = "1" ]; then
        printf '%s\n' "$available_identities"
        return 0
    fi

    if [ "$identity_count" -gt 1 ]; then
        echo "Multiple Apple Development identities detected for skip-listener signing." >&2
        echo "Refusing to pick one arbitrarily because changing identities can invalidate macOS trust grants." >&2
        echo "Set SKIP_LISTENER_CODESIGN_IDENTITY explicitly if you need to override the current app identity." >&2
        return 1
    fi

    return 1
}

cat > "$PLIST_STAGE" <<'PLIST'
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

plutil -lint "$PLIST_STAGE" >/dev/null

swiftc -O -o "$EXE_STAGE" "$SRC"
cp "$EXE_STAGE" "$LEGACY_STAGE"
chmod +x "$EXE_STAGE" "$LEGACY_STAGE"

CODESIGN_IDENTITY="$(choose_codesign_identity || true)"
if [ -n "$CODESIGN_IDENTITY" ]; then
    if codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_STAGE" && \
       codesign --force --sign "$CODESIGN_IDENTITY" --identifier "com.elleai.skip-listener" --timestamp=none "$LEGACY_STAGE"; then
        echo "Signed with identity: $CODESIGN_IDENTITY"
    else
        if [ "$ALLOW_ADHOC" = "1" ]; then
            echo "Apple Development signing failed for '$CODESIGN_IDENTITY' — falling back to ad hoc because SKIP_LISTENER_ALLOW_ADHOC=1" >&2
            codesign --force --sign - "$APP_STAGE"
            codesign --force --sign - --identifier "com.elleai.skip-listener" "$LEGACY_STAGE"
            echo "Signed ad hoc (explicitly allowed)"
        else
            echo "Apple Development signing failed for '$CODESIGN_IDENTITY'." >&2
            echo "Refusing to replace the installed listener with an ad hoc build." >&2
            echo "Run this script locally on the MBP so codesign can use the Apple Development certificate," >&2
            echo "or set SKIP_LISTENER_ALLOW_ADHOC=1 only if you intentionally want a shortcut-unsafe build." >&2
            exit 1
        fi
    fi
else
    if [ "$ALLOW_ADHOC" = "1" ]; then
        codesign --force --sign - "$APP_STAGE"
        codesign --force --sign - --identifier "com.elleai.skip-listener" "$LEGACY_STAGE"
        echo "Signed ad hoc (no Apple Development identity found, but explicitly allowed)"
    else
        echo "No Apple Development identity found for skip-listener signing." >&2
        echo "Refusing to replace the installed listener with an ad hoc build." >&2
        echo "Run this script locally on the MBP after enabling certificate access," >&2
        echo "or set SKIP_LISTENER_ALLOW_ADHOC=1 only for a temporary fallback." >&2
        exit 1
    fi
fi

codesign --verify --strict --verbose=2 "$APP_STAGE"
codesign --verify --verbose=2 "$LEGACY_STAGE"

rm -rf "$APP"
mv "$APP_STAGE" "$APP"
mv "$LEGACY_STAGE" "$LEGACY_EXE"

echo "Built bundle: $APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|CDHash|TeamIdentifier" || true
echo "Updated legacy fallback binary: $LEGACY_EXE"
