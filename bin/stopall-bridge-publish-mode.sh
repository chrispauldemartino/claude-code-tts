#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: stopall-bridge-publish-mode.sh FETCH_GENERATION PUBLISH_GENERATION" >&2
    exit 2
fi

if [ "$1" = "failed" ] || [ "$2" = "failed" ]; then
    echo "archive"
elif [ "$1" = "$2" ]; then
    echo "play"
else
    echo "archive"
fi
