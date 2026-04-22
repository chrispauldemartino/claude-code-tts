#!/usr/bin/env python3
"""
transform-for-speech.py

Speech normalization pipeline for technical text. It preserves the existing
table/list summary behavior, but expands normalization for filenames, paths,
URLs, emails, flags, env vars, versions, structured key/value blocks, logs,
stack traces, and diff-like text.

Reads raw text from stdin and writes speech-ready text to stdout.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from collections import Counter
from typing import Iterable

CACHE_DIR = "/tmp/claude-tts-detail-cache"
CONFIG_FILE = "/tmp/claude-voice-config"
ORDINALS = [
    "First",
    "Second",
    "Third",
    "Fourth",
    "Fifth",
    "Sixth",
    "Seventh",
    "Eighth",
    "Ninth",
    "Tenth",
]
FILE_EXTENSIONS = {
    "aiff": "aiff",
    "cfg": "config",
    "css": "css",
    "csv": "csv",
    "env": "env",
    "gif": "gif",
    "go": "go",
    "html": "html",
    "ini": "ini",
    "jpeg": "jpeg",
    "jpg": "jpeg",
    "js": "javascript",
    "json": "json",
    "jsx": "javascript jsx",
    "lock": "lock",
    "log": "log",
    "md": "markdown",
    "mp3": "mp3",
    "pdf": "pdf",
    "plist": "plist",
    "png": "png",
    "py": "python",
    "rb": "ruby",
    "sh": "shell",
    "sql": "sql",
    "svg": "svg",
    "swift": "swift",
    "toml": "toml",
    "ts": "typescript",
    "tsx": "typescript jsx",
    "txt": "text",
    "wav": "wav",
    "xml": "xml",
    "yaml": "yaml",
    "yml": "yaml",
}


def ensure_cache_dir() -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)


def clear_cache() -> None:
    if os.path.isdir(CACHE_DIR):
        for name in os.listdir(CACHE_DIR):
            os.remove(os.path.join(CACHE_DIR, name))


def cache_id_for(prefix: str, content: str) -> str:
    digest = hashlib.md5(content.encode("utf-8")).hexdigest()[:10]
    return f"{prefix}-{digest}"


def write_cache(cache_id: str, content: str) -> str:
    ensure_cache_dir()
    cache_path = os.path.join(CACHE_DIR, f"{cache_id}.txt")
    with open(cache_path, "w", encoding="utf-8") as fh:
        fh.write(content)

    index_path = os.path.join(CACHE_DIR, "index.txt")
    existing = set()
    if os.path.exists(index_path):
        with open(index_path, "r", encoding="utf-8") as fh:
            existing = {line.strip() for line in fh if line.strip()}
    if cache_id not in existing:
        with open(index_path, "a", encoding="utf-8") as fh:
            fh.write(f"{cache_id}\n")
    return cache_path


def is_summary_mode() -> bool:
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip().startswith("summary="):
                    return line.strip().split("=", 1)[1] == "on"
    except FileNotFoundError:
        pass
    return False


def split_camel_case(text: str) -> str:
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", text)
    return text


def humanize_token(text: str) -> str:
    text = text.strip()
    if not text:
        return text

    if "." in text and "/" not in text:
        base, ext = text.rsplit(".", 1)
        if ext.lower() in FILE_EXTENSIONS and base:
            base = humanize_token(base)
            ext_label = FILE_EXTENSIONS[ext.lower()]
            return f"{base} {ext_label} file"

    text = split_camel_case(text)
    text = text.replace("_", " ")
    text = text.replace("-", " ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def humanize_path(text: str) -> str:
    parts = [humanize_token(part) for part in text.split("/") if part]
    return " slash ".join(part for part in parts if part)


def normalize_urls(text: str) -> str:
    def repl(match: re.Match[str]) -> str:
        url = match.group(0)
        url = re.sub(r"^https?://", "", url)
        url = url.replace("www.", "www dot ")
        url = url.replace(".", " dot ")
        url = url.replace("/", " slash ")
        url = re.sub(r"\s+", " ", url)
        return url.strip()

    return re.sub(r"https?://[^\s)]+", repl, text)


def normalize_emails(text: str) -> str:
    def repl(match: re.Match[str]) -> str:
        local, domain = match.group(0).split("@", 1)
        return f"{humanize_token(local)} at {domain.replace('.', ' dot ')}"

    return re.sub(r"\b[\w.+-]+@[\w.-]+\.\w+\b", repl, text)


def normalize_paths_and_files(text: str) -> str:
    def path_repl(match: re.Match[str]) -> str:
        return humanize_path(match.group(0))

    text = re.sub(
        r"(?<!https:)(?<!http:)\b[\w.~-]+(?:/[\w.~:-]+)+\b",
        path_repl,
        text,
    )

    def file_repl(match: re.Match[str]) -> str:
        return humanize_token(match.group(0))

    file_exts = "|".join(sorted(FILE_EXTENSIONS))
    return re.sub(rf"\b[\w.-]+\.({file_exts})\b", file_repl, text, flags=re.IGNORECASE)


def normalize_flags_and_vars(text: str) -> str:
    text = re.sub(r"\$([A-Z][A-Z0-9_]{1,})", lambda m: f"{humanize_token(m.group(1))} environment variable", text)
    text = re.sub(r"\b([A-Z][A-Z0-9_]{2,})\b", lambda m: humanize_token(m.group(1)), text)
    text = re.sub(r"--([a-z0-9][a-z0-9-]*)", lambda m: f"dash dash {humanize_token(m.group(1))}", text)
    text = re.sub(r"(?<!-)-([A-Za-z0-9])\b", lambda m: f"dash {m.group(1)}", text)
    return text


def normalize_numbers_and_times(text: str) -> str:
    text = re.sub(r"\bv(\d+(?:\.\d+)+)\b", lambda m: "version " + m.group(1).replace(".", " dot "), text)
    text = re.sub(r"\b(\d+\.\d+)%\b", lambda m: m.group(1).replace(".", " point ") + " percent", text)
    text = re.sub(r"\b(\d+)%\b", r"\1 percent", text)
    text = re.sub(r"\b(\d+)\.(\d+)\.(\d+)\b", r"\1 dot \2 dot \3", text)
    text = re.sub(r"\b(\d+)\.(\d+)\b", r"\1 point \2", text)
    text = re.sub(r"(?<=\d)-(?=\d)", " to ", text)
    text = re.sub(r"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b", lambda m: " ".join(part for part in m.groups() if part), text)
    return text


def normalize_inline_code(text: str) -> str:
    return re.sub(r"`([^`]+)`", lambda m: humanize_token(m.group(1)), text)


def normalize_markdown_links(text: str) -> str:
    return re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)


def normalize_log_line(line: str) -> str:
    line = line.strip()
    m = re.match(r"^(ERROR|WARN|WARNING|INFO|DEBUG|FATAL)[:\s-]+(.+)$", line, flags=re.IGNORECASE)
    if m:
        level = m.group(1).lower()
        return f"{level.capitalize()}: {normalize_plain_text(m.group(2))}."
    return normalize_plain_text(line)


def transform_key_value_block(lines: list[str]) -> str:
    parts = []
    for line in lines:
        key, value = line.split(":", 1)
        parts.append(f"{humanize_token(key)}: {normalize_plain_text(value.strip())}.")
    return " ".join(parts)


def transform_stack_trace(lines: list[str]) -> str:
    frames = []
    for line in lines:
        cleaned = normalize_plain_text(line.strip())
        if cleaned:
            frames.append(cleaned)
    if not frames:
        return ""
    preview = "; ".join(frames[:3])
    if len(frames) > 3:
        preview += f"; plus {len(frames) - 3} more frames."
    return f"Stack trace with {len(frames)} lines. {preview}"


def transform_diff_block(lines: list[str]) -> str:
    additions = sum(1 for line in lines if line.startswith("+") and not line.startswith("+++"))
    deletions = sum(1 for line in lines if line.startswith("-") and not line.startswith("---"))
    hunks = sum(1 for line in lines if line.startswith("@@"))
    files = [line[6:].strip() for line in lines if line.startswith("diff --git ")]

    parts = []
    if files:
        parts.append(f"Diff block for {', '.join(humanize_path(name) for name in files[:2])}.")
    else:
        parts.append("Diff block.")
    parts.append(f"{additions} additions and {deletions} deletions.")
    if hunks:
        parts.append(f"{hunks} hunk sections.")
    return " ".join(parts)


def normalize_plain_text(text: str) -> str:
    text = normalize_markdown_links(text)
    text = normalize_inline_code(text)
    text = normalize_urls(text)
    text = normalize_emails(text)
    text = normalize_paths_and_files(text)
    text = normalize_flags_and_vars(text)
    text = normalize_numbers_and_times(text)
    text = re.sub(r"[\u2500-\u257F]+", " ", text)
    text = re.sub(r"[★☆•◦▪▫■□◆◇▶►▸▹]+", " ", text)
    text = re.sub(r"[_=~]{4,}", " ", text)
    text = split_camel_case(text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def parse_table_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


def is_separator_row(line: str) -> bool:
    line = line.strip()
    if not line.startswith("|"):
        return False
    cells = parse_table_row(line)
    return all(re.match(r"^:?-+:?$", cell.strip()) for cell in cells if cell.strip())


def is_table_row(line: str) -> bool:
    line = line.strip()
    return line.startswith("|") and line.endswith("|") and line.count("|") >= 2


def find_outliers(headers: list[str], rows: list[list[str]]) -> list[tuple[str, str, str]]:
    if not rows or not headers:
        return []
    last_col_idx = len(headers) - 1
    last_col_name = headers[last_col_idx]
    values = [row[last_col_idx] for row in rows if last_col_idx < len(row)]
    if not values:
        return []

    counts = Counter(values)
    total = len(values)
    outliers = []
    for value, count in counts.items():
        if count < total / 2:
            for idx, row in enumerate(rows):
                if last_col_idx < len(row) and row[last_col_idx] == value:
                    row_label = humanize_token(row[0]) if row else f"Row {idx + 1}"
                    outliers.append((row_label, humanize_token(last_col_name), normalize_plain_text(value)))
    return outliers


def narrate_row(idx: int, headers: list[str], row: list[str]) -> str:
    parts = []
    for header, value in zip(headers, row):
        parts.append(f"{humanize_token(header)} {normalize_plain_text(value)}")
    return f"Row {idx}: {', '.join(parts)}."


def transform_table(headers: list[str], rows: list[list[str]]) -> str:
    num_rows = len(rows)
    normalized_headers = [humanize_token(header) for header in headers]

    if num_rows <= 3 or not is_summary_mode():
        lines = []
        if num_rows > 3:
            lines.append(f"Table with {num_rows} rows.")
        for idx, row in enumerate(rows, 1):
            lines.append(narrate_row(idx, normalized_headers, row))
        return "\n".join(lines)

    summary_parts = [
        f"Table with {num_rows} rows across {len(normalized_headers)} columns: {', '.join(normalized_headers)}.",
        f"First entry: {narrate_row(1, normalized_headers, rows[0])}",
    ]
    if num_rows > 2:
        summary_parts.append(f"Last entry: {narrate_row(num_rows, normalized_headers, rows[-1])}")

    outliers = find_outliers(normalized_headers, rows)
    if outliers and len(outliers) <= max(1, num_rows // 2):
        summary_parts.append("Notable entries:")
        for row_label, col_name, value in outliers[:4]:
            summary_parts.append(f"{row_label} has {col_name} {value}.")

    cache_content = "\n".join(narrate_row(idx, normalized_headers, row) for idx, row in enumerate(rows, 1))
    cache_id = cache_id_for("table", cache_content)
    write_cache(cache_id, cache_content)
    summary_parts.append('Say "read rows" to hear every row in detail.')
    return "\n".join(summary_parts)


def extract_list_item(line: str) -> str | None:
    line = line.strip()
    match = re.match(r"^[-*]\s+(.+)$", line)
    if match:
        return match.group(1)
    match = re.match(r"^\d+\.\s+(.+)$", line)
    if match:
        return match.group(1)
    return None


def transform_list(items: list[str]) -> str:
    items = [normalize_plain_text(item) for item in items]
    num_items = len(items)

    if num_items < 5 or not is_summary_mode():
        lines = []
        if num_items >= 5:
            lines.append(f"List with {num_items} items.")
        for idx, item in enumerate(items):
            ordinal = ORDINALS[idx] if idx < len(ORDINALS) else f"Item {idx + 1}"
            lines.append(f"{ordinal}: {item}.")
        return " ".join(lines)

    cache_content = "\n".join(
        f"{ORDINALS[idx] if idx < len(ORDINALS) else f'Item {idx + 1}'}: {item}."
        for idx, item in enumerate(items)
    )
    cache_id = cache_id_for("list", cache_content)
    write_cache(cache_id, cache_content)

    first_three = ", ".join(items[:3])
    return f"{num_items} items. First three: {first_three}. Say \"read items\" for the full list."


def classify_line(line: str) -> str:
    stripped = line.strip()
    if not stripped:
        return "blank"
    if stripped == "<<MSG_BREAK>>":
        return "break"
    if stripped.startswith("```"):
        return "fence"
    if is_table_row(stripped):
        return "table"
    if extract_list_item(stripped) is not None:
        return "list"
    if re.match(r"^[A-Za-z0-9_.\-/]+:\s+\S", stripped):
        return "key_value"
    if stripped.startswith(("diff --git", "@@", "+++", "---", "+", "-")):
        return "diff"
    if stripped.startswith(("Traceback", "File ", "at ")) or stripped.endswith("Error:"):
        return "stack"
    if stripped.startswith("$ "):
        return "command"
    if re.match(r"^(ERROR|WARN|WARNING|INFO|DEBUG|FATAL)[:\s-]+", stripped, flags=re.IGNORECASE):
        return "log"
    return "plain"


def process_input(text: str) -> str:
    lines = text.splitlines()
    output: list[str] = []
    i = 0

    while i < len(lines):
        line = lines[i]
        kind = classify_line(line)

        if kind == "blank":
            output.append("")
            i += 1
            continue
        if kind == "break":
            output.append(line.strip())
            i += 1
            continue
        if kind == "fence":
            output.append(line)
            i += 1
            continue

        if kind == "table":
            table_lines = [line]
            j = i + 1
            while j < len(lines) and (is_table_row(lines[j]) or is_separator_row(lines[j])):
                table_lines.append(lines[j])
                j += 1
            if len(table_lines) >= 3 and is_separator_row(table_lines[1]):
                headers = parse_table_row(table_lines[0])
                rows = [parse_table_row(tl) for tl in table_lines[2:] if not is_separator_row(tl)]
                if rows:
                    output.append(transform_table(headers, rows))
                    i = j
                    continue

        if kind == "list":
            items = []
            j = i
            while j < len(lines):
                item = extract_list_item(lines[j])
                if item is None:
                    break
                items.append(item)
                j += 1
            if len(items) >= 2:
                output.append(transform_list(items))
                i = j
                continue

        if kind == "key_value":
            block = []
            j = i
            while j < len(lines) and classify_line(lines[j]) == "key_value":
                block.append(lines[j].strip())
                j += 1
            if len(block) >= 2:
                output.append(transform_key_value_block(block))
                i = j
                continue

        if kind == "diff":
            block = []
            j = i
            while j < len(lines) and classify_line(lines[j]) == "diff":
                block.append(lines[j].rstrip())
                j += 1
            output.append(transform_diff_block(block))
            i = j
            continue

        if kind == "stack":
            block = []
            j = i
            while j < len(lines) and classify_line(lines[j]) in {"stack", "plain"}:
                block.append(lines[j].rstrip())
                j += 1
            output.append(transform_stack_trace(block))
            i = j
            continue

        if kind == "command":
            output.append(f"Command: {normalize_plain_text(line[2:])}.")
            i += 1
            continue

        if kind == "log":
            output.append(normalize_log_line(line))
            i += 1
            continue

        output.append(normalize_plain_text(line))
        i += 1

    return "\n".join(output)


def final_polish(text: str) -> str:
    polished_lines = []
    for line in text.splitlines():
        if line.strip() == "<<MSG_BREAK>>":
            polished_lines.append(line.strip())
            continue
        cleaned = re.sub(r"\s+", " ", line).strip()
        polished_lines.append(cleaned)
    return "\n".join(polished_lines).strip()


def main() -> None:
    text = sys.stdin.read()
    if not text.strip():
        sys.stdout.write(text)
        return

    result = process_input(text)
    result = final_polish(result)
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
