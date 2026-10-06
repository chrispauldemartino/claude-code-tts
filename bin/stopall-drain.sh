#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: stopall-drain.sh QUEUE_DIR DEFERRED_QUEUE_DIR" >&2
    exit 2
fi

drain_stopall_entries() {
    local directory="$1"
    [ -d "$directory" ] || return 0

    find "$directory" -mindepth 1 -maxdepth 1 -type d \
        -name '.entry-*.tmp' \
        -exec rm -rf -- {} +
}

drain_stopall_entries "$1"
drain_stopall_entries "$2"
