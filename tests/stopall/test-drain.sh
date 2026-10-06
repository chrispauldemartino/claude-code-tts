#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-stopall-drain-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

QUEUE="$TEST_ROOT/queue"
DEFERRED="$TEST_ROOT/deferred"
BRIDGE_STAGING="$TEST_ROOT/bridge-staging"
mkdir -p \
    "$QUEUE/entry-committed" \
    "$QUEUE/.entry-staging.tmp" \
    "$QUEUE/keep-me" \
    "$DEFERRED/entry-deferred" \
    "$DEFERRED/.entry-deferred.tmp" \
    "$DEFERRED/keep-me" \
    "$BRIDGE_STAGING/.entry-captured.tmp"
touch "$QUEUE/unrelated" "$DEFERRED/unrelated"

bash "$ROOT/bin/stopall-drain.sh" "$QUEUE" "$DEFERRED"

for removed in \
    "$QUEUE/.entry-staging.tmp" \
    "$DEFERRED/.entry-deferred.tmp"; do
    if [ -e "$removed" ]; then
        echo "expected stop-all drain to remove $removed" >&2
        exit 1
    fi
done

for preserved in \
    "$QUEUE/entry-committed" \
    "$QUEUE/keep-me" \
    "$QUEUE/unrelated" \
    "$DEFERRED/entry-deferred" \
    "$DEFERRED/keep-me" \
    "$DEFERRED/unrelated" \
    "$BRIDGE_STAGING/.entry-captured.tmp"; do
    if [ ! -e "$preserved" ]; then
        echo "expected stop-all drain to preserve $preserved" >&2
        exit 1
    fi
done

echo "stop-all staging discard harness: PASS"
