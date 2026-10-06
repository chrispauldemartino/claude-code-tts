#!/usr/bin/env bash

STOP_TRANSACTION_LOCK="${STOP_TRANSACTION_LOCK:-/tmp/claude-tts-stop-transaction.lock}"
STOP_TRANSACTION_LOCK_STALE_SECONDS="${STOP_TRANSACTION_LOCK_STALE_SECONDS:-30}"

stop_transaction_lock_mtime() {
    stat -f %m "$STOP_TRANSACTION_LOCK" 2>/dev/null || \
        stat -c %Y "$STOP_TRANSACTION_LOCK" 2>/dev/null
}

acquire_stop_transaction_lock() {
    local modified now age
    while ! mkdir "$STOP_TRANSACTION_LOCK" 2>/dev/null; do
        modified="$(stop_transaction_lock_mtime || true)"
        now="$(date +%s)"
        if [ -n "$modified" ]; then
            age=$((now - modified))
            if [ "$age" -gt "$STOP_TRANSACTION_LOCK_STALE_SECONDS" ]; then
                printf '%s\n' \
                    "tts-bridge: removing stale stop transaction lock (age=${age}s)" >&2
                rmdir "$STOP_TRANSACTION_LOCK" 2>/dev/null || true
                continue
            fi
        fi
        sleep 0.01
    done
}

release_stop_transaction_lock() {
    rmdir "$STOP_TRANSACTION_LOCK" 2>/dev/null || true
}
