#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-stopall-lock-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export STOP_TRANSACTION_LOCK="$TEST_ROOT/stop-transaction.lock"
export STOP_TRANSACTION_LOCK_STALE_SECONDS=0

# shellcheck source=../../bin/stopall-lock.sh
source "$ROOT/bin/stopall-lock.sh"

mkdir "$STOP_TRANSACTION_LOCK"
sleep 1
acquire_stop_transaction_lock

if [ ! -d "$STOP_TRANSACTION_LOCK" ]; then
    echo "expected bridge to acquire the recovered stop transaction lock" >&2
    exit 1
fi

release_stop_transaction_lock
if [ -e "$STOP_TRANSACTION_LOCK" ]; then
    echo "expected bridge to release the stop transaction lock" >&2
    exit 1
fi

echo "bridge stale stop-lock recovery harness: PASS"
