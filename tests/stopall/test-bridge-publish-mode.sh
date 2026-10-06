#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

[ "$(bash "$ROOT/bin/stopall-bridge-publish-mode.sh" 7 7)" = "play" ]
[ "$(bash "$ROOT/bin/stopall-bridge-publish-mode.sh" 7 8)" = "archive" ]
[ "$(bash "$ROOT/bin/stopall-bridge-publish-mode.sh" 0 1)" = "archive" ]
[ "$(bash "$ROOT/bin/stopall-bridge-publish-mode.sh" failed failed)" = "archive" ]
[ "$(bash "$ROOT/bin/stopall-bridge-publish-mode.sh" 7 failed)" = "archive" ]

echo "bridge publish mode harness: PASS"
