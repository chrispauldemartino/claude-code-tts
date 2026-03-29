#!/bin/bash

# test-transform.sh — Tests for transform-for-speech.py
# Tests table detection, list detection, cache creation, mixed content, and passthrough

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSFORMER="$SCRIPT_DIR/transform-for-speech.py"
CACHE_DIR="/tmp/claude-tts-detail-cache"
PASS=0
FAIL=0

# --- Helpers ---

clean_cache() {
    rm -rf "$CACHE_DIR"
}

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -qi "$needle"; then
        return 0
    else
        echo "  FAIL: expected output to contain '$needle'"
        echo "  GOT: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if echo "$haystack" | grep -qi "$needle"; then
        echo "  FAIL: expected output NOT to contain '$needle'"
        echo "  GOT: $haystack"
        return 1
    else
        return 0
    fi
}

assert_file_exists() {
    local label="$1"
    local filepath="$2"
    if [ -f "$filepath" ]; then
        return 0
    else
        echo "  FAIL: expected file to exist: $filepath"
        return 1
    fi
}

# ============================================================
# Test 1: Small table (3 rows) — read all rows, no summary count
# ============================================================
echo ""
echo "=== Test 1: Small table (3 rows) ==="
clean_cache

INPUT='| Name | Status |
|------|--------|
| Alice | Active |
| Bob | Active |
| Carol | Inactive |'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "row1" "$TEST_OUTPUT" "Row 1" || ok=false
    assert_contains "row2" "$TEST_OUTPUT" "Row 2" || ok=false
    assert_contains "row3" "$TEST_OUTPUT" "Row 3" || ok=false
    assert_not_contains "no-count" "$TEST_OUTPUT" "3 rows" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 2: Large table (5 rows) — summary with row count, cache file
# ============================================================
echo ""
echo "=== Test 2: Large table (5 rows) ==="
clean_cache

INPUT='| Service | Region | Status |
|---------|--------|--------|
| API | US-East | Running |
| Web | US-East | Running |
| DB | US-West | Running |
| Cache | EU | Running |
| Auth | US-East | Down |'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "count" "$TEST_OUTPUT" "5 rows" || ok=false
    assert_contains "columns" "$TEST_OUTPUT" "Service" || ok=false
    assert_contains "row1" "$TEST_OUTPUT" "Row 1" || ok=false
    assert_contains "outlier" "$TEST_OUTPUT" "Down" || ok=false
    assert_file_exists "cache" "$CACHE_DIR/table-001.txt" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 3: Short list (3 items) — read all items
# ============================================================
echo ""
echo "=== Test 3: Short list (3 items) ==="
clean_cache

INPUT='- First item
- Second item
- Third item'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "first" "$TEST_OUTPUT" "First" || ok=false
    assert_contains "third" "$TEST_OUTPUT" "Third" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 4: Long list (6 items) — summary with count, cache file
# ============================================================
echo ""
echo "=== Test 4: Long list (6 items) ==="
clean_cache

INPUT='- Alpha component
- Beta component
- Gamma component
- Delta component
- Epsilon component
- Zeta component'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "count" "$TEST_OUTPUT" "6 items" || ok=false
    assert_contains "first" "$TEST_OUTPUT" "Alpha" || ok=false
    assert_file_exists "cache" "$CACHE_DIR/list-001.txt" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 5: No structured data — plain text passes through unchanged
# ============================================================
echo ""
echo "=== Test 5: No structured data (plain text passthrough) ==="
clean_cache

INPUT='This is just a regular paragraph with no tables or lists.
It should pass through the transformer completely unchanged.'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "passthrough" "$TEST_OUTPUT" "regular paragraph" || ok=false
    assert_contains "passthrough2" "$TEST_OUTPUT" "completely unchanged" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 6: Mixed content (text + table + text) — only table transformed
# ============================================================
echo ""
echo "=== Test 6: Mixed content ==="
clean_cache

INPUT='Here is the deployment status:

| Service | Status |
|---------|--------|
| API | Running |
| Web | Running |
| DB | Running |
| Cache | Down |
| Auth | Running |

All services are monitored continuously.'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "prefix" "$TEST_OUTPUT" "deployment status" || ok=false
    assert_contains "suffix" "$TEST_OUTPUT" "monitored continuously" || ok=false
    assert_not_contains "no-pipes" "$TEST_OUTPUT" "|" || ok=false
    assert_contains "table-summary" "$TEST_OUTPUT" "5 rows" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 7: Malformed table (no separator line) — passes through unchanged
# ============================================================
echo ""
echo "=== Test 7: Malformed table (no separator) ==="
clean_cache

INPUT='| Name | Value |
| foo | 123 |
| bar | 456 |'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    # Should pass through unchanged (including pipes) since it's not a valid table
    assert_contains "passthrough" "$TEST_OUTPUT" "|" || ok=false
    assert_not_contains "no-row" "$TEST_OUTPUT" "Row 1" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 8: Degenerate outliers (all unique values) — no outlier callouts
# ============================================================
echo ""
echo "=== Test 8: Degenerate outliers (all unique values) ==="
clean_cache

INPUT='| Student | Score |
|---------|-------|
| Alice | 95 |
| Bob | 87 |
| Carol | 91 |
| Dave | 73 |
| Eve | 88 |'

TEST_OUTPUT=$(echo "$INPUT" | python3 "$TRANSFORMER" 2>/dev/null)
EXIT=$?
ok=true

if [ $EXIT -ne 0 ]; then
    echo "  FAIL: transformer exited with code $EXIT"
    ok=false
fi

if $ok; then
    assert_contains "count" "$TEST_OUTPUT" "5 rows" || ok=false
    assert_contains "row1" "$TEST_OUTPUT" "Row 1" || ok=false
    # All scores are unique, so every row would be an "outlier" (5/5 > 50%)
    # The fix should suppress outlier callouts entirely
    assert_not_contains "no-outlier-95" "$TEST_OUTPUT" "has Score" || ok=false
fi

if $ok; then
    echo "  PASS"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed (of $((PASS + FAIL)) tests)"
echo "=============================="

# Clean up
clean_cache

[ $FAIL -eq 0 ] && exit 0 || exit 1
