#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-tts-stopall-swift-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

bash "$ROOT/tests/stopall/test-drain.sh"
bash "$ROOT/tests/stopall/test-bridge-publish-mode.sh"
bash "$ROOT/tests/stopall/test-bridge-lock.sh"
swiftc \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$ROOT/cmd/skip-listener/StopGeneration.swift" \
    "$ROOT/tests/stopall/StopGenerationHarness.swift" \
    -o "$TEST_ROOT/stop-generation-harness"
"$TEST_ROOT/stop-generation-harness"
swiftc \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$ROOT/cmd/skip-listener/StopAllArchive.swift" \
    "$ROOT/tests/stopall/StopAllArchiveHarness.swift" \
    -o "$TEST_ROOT/stop-archive-harness"
"$TEST_ROOT/stop-archive-harness"
swiftc \
    -module-cache-path "$TEST_ROOT/module-cache" \
    "$ROOT/cmd/skip-listener/ProcessLaunch.swift" \
    "$ROOT/tests/stopall/ProcessLaunchHarness.swift" \
    -o "$TEST_ROOT/process-launch-harness"
"$TEST_ROOT/process-launch-harness"
