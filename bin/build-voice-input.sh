#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$PLUGIN_ROOT/cmd/voice-input/main.swift"
EXE="$PLUGIN_ROOT/bin/voice-input"
ALLOW_ADHOC="${VOICE_INPUT_ALLOW_ADHOC:-0}"
TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/voice-input-build.XXXXXX")"
EXE_STAGE="$TMPDIR_BUILD/voice-input"

cleanup() {
    rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

if [ ! -f "$SRC" ]; then
    echo "Missing source: $SRC" >&2
    exit 1
fi

choose_codesign_identity() {
    if [ -n "${VOICE_INPUT_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$VOICE_INPUT_CODESIGN_IDENTITY"
        return 0
    fi

    if [ -n "${APPLE_CODESIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$APPLE_CODESIGN_IDENTITY"
        return 0
    fi

    local available_identities
    available_identities="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2}')"

    if [ -e "$EXE" ]; then
        local current_identity
        current_identity="$(codesign -dv --verbose=4 "$EXE" 2>&1 | awk -F= '/^Authority=Apple Development:/ {print $2; exit}')"
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
        echo "Multiple Apple Development identities detected for voice-input signing." >&2
        echo "Set VOICE_INPUT_CODESIGN_IDENTITY explicitly if you need to override the current binary identity." >&2
        return 1
    fi

    return 1
}

swiftc -O -o "$EXE_STAGE" "$SRC"
chmod +x "$EXE_STAGE"

CODESIGN_IDENTITY="$(choose_codesign_identity || true)"
if [ -n "$CODESIGN_IDENTITY" ]; then
    if codesign --force --sign "$CODESIGN_IDENTITY" --identifier "com.elleai.voice-input" --timestamp=none "$EXE_STAGE"; then
        echo "Signed with identity: $CODESIGN_IDENTITY"
    else
        if [ "$ALLOW_ADHOC" = "1" ]; then
            echo "Apple Development signing failed for '$CODESIGN_IDENTITY' — falling back to ad hoc because VOICE_INPUT_ALLOW_ADHOC=1" >&2
            codesign --force --sign - --identifier "com.elleai.voice-input" "$EXE_STAGE"
            echo "Signed ad hoc (explicitly allowed)"
        else
            echo "Apple Development signing failed for '$CODESIGN_IDENTITY'." >&2
            echo "Refusing to replace the installed voice-input binary with an ad hoc build." >&2
            echo "Run this script locally where the Apple Development certificate is available," >&2
            echo "or set VOICE_INPUT_ALLOW_ADHOC=1 only if you intentionally want a temporary fallback." >&2
            exit 1
        fi
    fi
else
    if [ "$ALLOW_ADHOC" = "1" ]; then
        codesign --force --sign - --identifier "com.elleai.voice-input" "$EXE_STAGE"
        echo "Signed ad hoc (no Apple Development identity found, but explicitly allowed)"
    else
        echo "No Apple Development identity found for voice-input signing." >&2
        echo "Refusing to replace the installed voice-input binary with an ad hoc build." >&2
        echo "Run this script locally after enabling certificate access," >&2
        echo "or set VOICE_INPUT_ALLOW_ADHOC=1 only for a temporary fallback." >&2
        exit 1
    fi
fi

codesign --verify --strict --verbose=2 "$EXE_STAGE"
mv "$EXE_STAGE" "$EXE"

echo "Built binary: $EXE"
codesign -dv --verbose=2 "$EXE" 2>&1 | grep -E "Identifier|CDHash|TeamIdentifier" || true
