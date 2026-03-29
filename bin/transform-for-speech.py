#!/usr/bin/env python3
"""
transform-for-speech.py — Transforms markdown tables and lists into speech-friendly text.

Reads raw markdown from stdin, writes speech-ready text to stdout.
Sits between markdown stripping and TTS synthesis in the auto-speak pipeline.

Tables:
  - 3 or fewer data rows: narrates all rows ("Row 1: col1 val1, col2 val2.")
  - More than 3 rows: summary with row count, column names, outlier analysis.
    Full narration cached to /tmp/claude-tts-detail-cache/table-NNN.txt

Lists:
  - Fewer than 5 items: narrates all ("First: ..., Second: ..., Third: ...")
  - 5 or more items: summary with count and first three.
    Full narration cached to /tmp/claude-tts-detail-cache/list-NNN.txt

Cache index maintained at /tmp/claude-tts-detail-cache/index.txt
Current count at /tmp/claude-tts-detail-cache/current
"""

import sys
import os
import re
from collections import Counter

CACHE_DIR = "/tmp/claude-tts-detail-cache"
ORDINALS = ["First", "Second", "Third", "Fourth", "Fifth",
            "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]


def ensure_cache_dir():
    os.makedirs(CACHE_DIR, exist_ok=True)


def next_cache_id(prefix):
    """Get next sequential ID for cache files (table-001, list-001, etc.)."""
    ensure_cache_dir()
    current_file = os.path.join(CACHE_DIR, "current")
    try:
        current = int(open(current_file).read().strip())
    except (FileNotFoundError, ValueError):
        current = 0
    next_id = current + 1
    open(current_file, "w").write(str(next_id))
    return f"{prefix}-{next_id:03d}"


def write_cache(cache_id, content):
    """Write content to cache file and update index."""
    ensure_cache_dir()
    cache_path = os.path.join(CACHE_DIR, f"{cache_id}.txt")
    with open(cache_path, "w") as f:
        f.write(content)

    # Update index
    index_path = os.path.join(CACHE_DIR, "index.txt")
    with open(index_path, "a") as f:
        f.write(f"{cache_id}\n")

    return cache_path


def parse_table_row(line):
    """Parse a markdown table row into a list of cell values."""
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


def is_separator_row(line):
    """Check if a line is a markdown table separator (|---|---|)."""
    line = line.strip()
    if not line.startswith("|"):
        return False
    # Remove leading/trailing pipes and check cells
    cells = parse_table_row(line)
    return all(re.match(r'^:?-+:?$', cell.strip()) for cell in cells if cell.strip())


def is_table_row(line):
    """Check if a line looks like a markdown table row (starts and ends with |)."""
    line = line.strip()
    return line.startswith("|") and line.endswith("|") and line.count("|") >= 2


def find_outliers(headers, rows):
    """Analyze the last column for minority values (outliers)."""
    if not rows or not headers:
        return []

    # Use the last column for outlier analysis
    last_col_idx = len(headers) - 1
    last_col_name = headers[last_col_idx]
    values = []
    for row in rows:
        if last_col_idx < len(row):
            values.append(row[last_col_idx])

    if not values:
        return []

    counts = Counter(values)
    total = len(values)

    # Find minority values (values that appear less than half the time)
    outliers = []
    for value, count in counts.items():
        if count < total / 2:
            # Find which rows have this value
            for i, row in enumerate(rows):
                if last_col_idx < len(row) and row[last_col_idx] == value:
                    row_label = row[0] if row else f"Row {i + 1}"
                    outliers.append((row_label, last_col_name, value))

    return outliers


def narrate_row(idx, headers, row):
    """Narrate a single table row as speech text."""
    parts = []
    for h, v in zip(headers, row):
        parts.append(f"{h} {v}")
    return f"Row {idx}: {', '.join(parts)}."


def transform_table(headers, rows):
    """Transform a parsed table into speech-friendly text."""
    num_rows = len(rows)

    if num_rows <= 3:
        # Small table: narrate all rows
        lines = []
        for i, row in enumerate(rows, 1):
            lines.append(narrate_row(i, headers, row))
        return "\n".join(lines)
    else:
        # Large table: summary with outlier analysis, cache full narration
        col_names = ", ".join(headers)
        summary_parts = [f"Table with {num_rows} rows. Columns: {col_names}."]

        # Narrate first row fully (spec requirement)
        summary_parts.append(narrate_row(1, headers, rows[0]))

        outliers = find_outliers(headers, rows)
        # Skip outliers if they exceed 50% of rows (no meaningful pattern)
        if outliers and len(outliers) <= num_rows // 2:
            for row_label, col_name, value in outliers:
                summary_parts.append(f"{row_label} has {col_name} {value}.")

        # Cache full narration
        cache_id = next_cache_id("table")
        full_lines = []
        for i, row in enumerate(rows, 1):
            full_lines.append(narrate_row(i, headers, row))
        write_cache(cache_id, "\n".join(full_lines))

        summary_parts.append(f'Say "read rows" for full detail.')
        return " ".join(summary_parts)


def transform_list(items):
    """Transform a list into speech-friendly text."""
    num_items = len(items)

    if num_items < 5:
        # Short list: read all with ordinals
        lines = []
        for i, item in enumerate(items):
            ordinal = ORDINALS[i] if i < len(ORDINALS) else f"Item {i + 1}"
            lines.append(f"{ordinal}: {item}.")
        return " ".join(lines)
    else:
        # Long list: summary with count and first three
        cache_id = next_cache_id("list")

        # Cache full narration
        full_lines = []
        for i, item in enumerate(items):
            ordinal = ORDINALS[i] if i < len(ORDINALS) else f"Item {i + 1}"
            full_lines.append(f"{ordinal}: {item}.")
        write_cache(cache_id, "\n".join(full_lines))

        first_three = items[:3]
        summary = f"{num_items} items. First three: {first_three[0]}, {first_three[1]}, {first_three[2]}."
        summary += f' Say "read items" for the full list.'
        return summary


def extract_list_item(line):
    """Extract item text from a markdown list line. Returns None if not a list item."""
    line = line.strip()
    # Unordered: - or *
    m = re.match(r'^[-*]\s+(.+)$', line)
    if m:
        return m.group(1)
    # Ordered: 1. 2. etc.
    m = re.match(r'^\d+\.\s+(.+)$', line)
    if m:
        return m.group(1)
    return None


def process_input(text):
    """Process input text, transforming tables and lists, preserving other content."""
    lines = text.split("\n")
    output = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # --- Table detection ---
        if is_table_row(line):
            # Collect consecutive table-like lines
            table_lines = [line]
            j = i + 1
            while j < len(lines) and (is_table_row(lines[j]) or is_separator_row(lines[j])):
                table_lines.append(lines[j])
                j += 1

            # Validate: must have at least header + separator + 1 data row
            # and the second line must be a separator
            if len(table_lines) >= 3 and is_separator_row(table_lines[1]):
                headers = parse_table_row(table_lines[0])
                rows = []
                for tl in table_lines[2:]:
                    if not is_separator_row(tl):
                        rows.append(parse_table_row(tl))

                if rows:
                    output.append(transform_table(headers, rows))
                    i = j
                    continue

            # Not a valid table — pass through unchanged
            output.append(line)
            i += 1
            continue

        # --- List detection ---
        if extract_list_item(line) is not None:
            # Collect consecutive list items
            items = []
            j = i
            while j < len(lines):
                item = extract_list_item(lines[j])
                if item is not None:
                    items.append(item)
                    j += 1
                else:
                    break

            # Need at least 2 consecutive list items to be a list
            if len(items) >= 2:
                output.append(transform_list(items))
                i = j
                continue
            else:
                # Single item — not a list, pass through
                output.append(line)
                i += 1
                continue

        # --- Plain text passthrough ---
        output.append(line)
        i += 1

    return "\n".join(output)


def main():
    text = sys.stdin.read()
    if not text.strip():
        sys.stdout.write(text)
        return

    result = process_input(text)
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
