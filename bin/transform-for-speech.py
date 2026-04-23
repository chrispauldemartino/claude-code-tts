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
    "cjs": "javascript",
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
    "mjs": "javascript",
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
GENERIC_ENTRYPOINT_STEMS = {"main", "index", "init", "app", "mod", "__init__"}
CODE_EXTENSIONS = {"cjs", "go", "js", "jsx", "mjs", "py", "rb", "sh", "swift", "ts", "tsx"}
CONFIG_EXTENSIONS = {"cfg", "env", "ini", "json", "plist", "toml", "yaml", "yml"}
COMMAND_LANGUAGE_LABELS = {
    "python": "python",
    "python3": "python",
    "bash": "shell",
    "sh": "shell",
    "zsh": "shell",
    "node": "javascript",
    "npm": "javascript",
    "npx": "javascript",
    "tsx": "typescript",
    "ts-node": "typescript",
    "ruby": "ruby",
    "swift": "swift",
    "go": "go",
}
PRONUNCIATION_OVERRIDES = (
    (re.compile(r"\bELLE\b"), "El Lee"),
    (re.compile(r"\bElle\b"), "El Lee"),
)
PATH_OR_FILE_PATTERN = re.compile(
    rf"(?<!https:)(?<!http:)\b[\w.~-]+(?:/[\w.~:-]+)+\b|\b[\w.-]+\.({'|'.join(sorted(FILE_EXTENSIONS))})\b",
    flags=re.IGNORECASE,
)


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


def read_config_value(key: str, default: str | None = None) -> str | None:
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip().startswith(f"{key}="):
                    return line.strip().split("=", 1)[1]
    except FileNotFoundError:
        pass
    return default


def is_summary_mode() -> bool:
    return read_config_value("summary", "off") == "on"


def is_code_silent() -> bool:
    return read_config_value("code", "silent") != "narrate"


def strip_nonspoken_metadata(text: str) -> str:
    text = re.sub(
        r"(?is)\n?<oai-mem-citation>\s*.*?</oai-mem-citation>\s*",
        "\n",
        text,
    )
    return text


def apply_pronunciation_overrides(text: str) -> str:
    updated = text
    for pattern, replacement in PRONUNCIATION_OVERRIDES:
        updated = pattern.sub(replacement, updated)
    return updated


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
    return apply_pronunciation_overrides(text.strip())


def humanize_path(text: str) -> str:
    parts = [humanize_token(part) for part in text.split("/") if part]
    return " slash ".join(part for part in parts if part)


def strip_reference_suffix(text: str) -> str:
    cleaned = text.strip().strip("`'\"()[]{}<>")
    cleaned = re.sub(r":\d+(?::\d+)?$", "", cleaned)
    cleaned = cleaned.rstrip(".,;:")
    return cleaned.replace("\\", "/")


def is_internal_doc_reference(text: str) -> bool:
    cleaned = strip_reference_suffix(text)
    if not cleaned.lower().endswith(".md"):
        return False
    normalized = cleaned.lstrip("./")
    basename = os.path.basename(normalized)
    return normalized.startswith("docs/") or basename.startswith("ELLE_")


def humanize_internal_doc_reference(text: str) -> str:
    cleaned = strip_reference_suffix(text)
    basename = os.path.basename(cleaned)
    return humanize_token(basename)


def has_known_file_extension(text: str) -> bool:
    return bool(re.search(rf"\.({'|'.join(sorted(FILE_EXTENSIONS))})$", text, flags=re.IGNORECASE))


def extract_file_like_references(text: str) -> list[str]:
    seen = set()
    refs = []
    for match in PATH_OR_FILE_PATTERN.finditer(text):
        ref = strip_reference_suffix(match.group(0))
        if not ref or ref in seen:
            continue
        seen.add(ref)
        refs.append(ref)
    return refs


def classify_reference_group(refs: list[str]) -> str:
    if not refs:
        return "repo files"

    extensions = []
    for ref in refs:
        cleaned = strip_reference_suffix(ref)
        leaf = os.path.basename(cleaned)
        ext = leaf.rsplit(".", 1)[1].lower() if "." in leaf else ""
        extensions.append(ext)

    nonempty_exts = [ext for ext in extensions if ext]
    if nonempty_exts and all(ext == "md" for ext in nonempty_exts):
        if all(os.path.basename(strip_reference_suffix(ref)).startswith("ELLE_") for ref in refs):
            return "ELLE markdown docs"
        return "markdown docs"
    if nonempty_exts and all(ext == "json" for ext in nonempty_exts):
        return "json artifact files"
    if nonempty_exts and all(ext in CODE_EXTENSIONS for ext in nonempty_exts):
        return "code files"
    if nonempty_exts and len(set(nonempty_exts)) == 1:
        ext_label = FILE_EXTENSIONS.get(nonempty_exts[0], nonempty_exts[0])
        return f"{ext_label} files"
    return "repo files"


def choose_reference_action(words: list[str]) -> str | None:
    word_set = set(words)
    action_map = (
        ({"update", "updated", "updates", "edit", "edited", "modify", "modified", "change", "changed", "touch", "touched"}, "Updated"),
        ({"add", "added", "create", "created", "generate", "generated", "write", "wrote"}, "Added"),
        ({"remove", "removed", "delete", "deleted"}, "Removed"),
    )
    for keywords, label in action_map:
        if word_set.intersection(keywords):
            return label
    return None


def maybe_summarize_file_heavy_text(text: str) -> str | None:
    if not (is_summary_mode() and is_code_silent()):
        return None

    refs = extract_file_like_references(text)
    if len(refs) < 2:
        return None

    masked = text
    for ref in refs:
        masked = masked.replace(ref, " ", 1)

    words = re.findall(r"[A-Za-z]+", masked.lower())
    if len(words) > max(8, len(refs) * 3):
        return None

    action = choose_reference_action(words)
    if action is None:
        return None
    subject = classify_reference_group(refs)
    count = len(refs)
    return f"{action} {count} {subject}."


def summarize_file_subject(text: str) -> str:
    cleaned = strip_reference_suffix(text)
    parts = [part for part in cleaned.split("/") if part]
    leaf = parts[-1] if parts else cleaned
    stem = leaf.rsplit(".", 1)[0] if "." in leaf else leaf
    if stem.lower() in GENERIC_ENTRYPOINT_STEMS and len(parts) >= 2:
        stem = parts[-2]
    return humanize_token(stem)


def summarize_file_reference(text: str) -> str:
    cleaned = strip_reference_suffix(text)
    leaf = os.path.basename(cleaned)
    ext = leaf.rsplit(".", 1)[1].lower() if "." in leaf else ""
    subject = summarize_file_subject(cleaned)
    subject_lower = subject.lower()

    if ext in CONFIG_EXTENSIONS:
        if subject_lower in {"config", "configuration", "settings", "setting"}:
            return "configuration"
        return f"{subject} configuration"

    if ext in CODE_EXTENSIONS:
        if subject_lower in {"test", "tests"}:
            return "test implementation"
        return f"{subject} implementation"

    if ext == "sql":
        return f"{subject} query"
    if ext == "log":
        return f"{subject} log"
    if ext in {"csv", "txt"}:
        return f"{subject} data"
    if ext in {"png", "jpg", "jpeg", "gif", "svg"}:
        return f"{subject} asset"
    if ext == "pdf":
        return f"{subject} document"

    return subject


def looks_like_command_text(text: str) -> bool:
    cleaned = strip_reference_suffix(text)
    if not cleaned or cleaned.startswith("-") or "\n" in cleaned:
        return False
    tokens = cleaned.split()
    if len(tokens) < 2:
        return False
    executable = os.path.basename(tokens[0])
    if executable in COMMAND_LANGUAGE_LABELS:
        return True
    if re.fullmatch(r"python\d+(?:\.\d+)?", executable):
        return True
    return tokens[0].startswith(("./", "/", "~/"))


def summarize_command_text(text: str) -> str:
    cleaned = strip_reference_suffix(text)
    tokens = cleaned.split()
    executable = os.path.basename(tokens[0]) if tokens else ""
    language = COMMAND_LANGUAGE_LABELS.get(executable, "")
    if not language and re.fullmatch(r"python\d+(?:\.\d+)?", executable):
        language = "python"

    target = next(
        (
            token
            for token in reversed(tokens[1:])
            if "/" in token or has_known_file_extension(strip_reference_suffix(token))
        ),
        None,
    )

    if target:
        subject = summarize_file_subject(target)
        if language:
            return f"{language} code - {subject}"
        return f"command - {subject}"
    if language:
        return f"{language} command"
    return f"command - {humanize_token(executable or cleaned)}"


def summarize_hidden_reference(text: str) -> str:
    cleaned = strip_reference_suffix(text)
    if re.fullmatch(r"#\d+", cleaned):
        return cleaned[1:]
    if re.fullmatch(r"\d+(?:\.\d+)?", cleaned):
        return cleaned
    if re.fullmatch(r"\d+(?:\.\d+)?(?:/\d+(?:\.\d+)?)+", cleaned):
        return cleaned
    if re.fullmatch(r"[a-f0-9]{7,40}", cleaned, flags=re.IGNORECASE):
        return cleaned
    if is_internal_doc_reference(cleaned):
        return humanize_internal_doc_reference(cleaned)
    if looks_like_command_text(cleaned):
        return summarize_command_text(cleaned)
    if "/" in cleaned or has_known_file_extension(cleaned):
        return summarize_file_reference(cleaned)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", cleaned):
        return f"code {humanize_token(cleaned)}"
    if re.search(r"\s", cleaned) and re.search(r"[A-Za-z0-9]", cleaned):
        return humanize_token(cleaned)
    return "implementation detail"


def summarize_language_name(language: str) -> str:
    cleaned = language.strip().lower()
    if not cleaned or cleaned in {"text", "plain", "plaintext"}:
        return ""
    mapped = FILE_EXTENSIONS.get(cleaned) or COMMAND_LANGUAGE_LABELS.get(cleaned) or cleaned
    return humanize_token(mapped)


def join_readable(parts: list[str]) -> str:
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]
    if len(parts) == 2:
        return f"{parts[0]} and {parts[1]}"
    return f"{', '.join(parts[:-1])}, and {parts[-1]}"


def detect_code_definitions(lines: list[str]) -> list[tuple[str, str]]:
    patterns = (
        (re.compile(r"^\s*(?:export\s+default\s+)?(?:async\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "function"),
        (re.compile(r"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "function"),
        (re.compile(r"^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "function"),
        (re.compile(r"^\s*(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_][A-Za-z0-9_]*)\s*=>"), "function"),
        (re.compile(r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "class"),
        (re.compile(r"^\s*struct\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "struct"),
        (re.compile(r"^\s*enum\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "enum"),
        (re.compile(r"^\s*interface\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "interface"),
        (re.compile(r"^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\s*="), "type"),
        (re.compile(r"^\s*protocol\s+([A-Za-z_][A-Za-z0-9_]*)\b"), "protocol"),
    )

    definitions: list[tuple[str, str]] = []
    seen = set()
    for line in lines:
        for pattern, kind in patterns:
            match = pattern.search(line)
            if not match:
                continue
            key = (kind, match.group(1))
            if key in seen:
                continue
            seen.add(key)
            definitions.append(key)
            break
    return definitions


def detect_assignment_targets(lines: list[str]) -> list[str]:
    patterns = (
        re.compile(r"^\s*(?:const|let|var)\s+\[?([A-Za-z_][A-Za-z0-9_]*)"),
        re.compile(r"^\s*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*="),
        re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*="),
    )

    targets = []
    seen = set()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith(("return ", "if ", "for ", "while ", "switch ", "case ")):
            continue
        for pattern in patterns:
            match = pattern.search(line)
            if not match:
                continue
            target = match.group(1)
            if target in seen:
                continue
            seen.add(target)
            targets.append(target)
            break
    return targets


def is_react_like_block(language: str, text: str) -> bool:
    lowered = language.strip().lower()
    if lowered in {"jsx", "tsx"}:
        return True
    return any(token in text for token in ("useEffect", "useState", "useReducer", "useRef", "useMemo", "useCallback", "useDeferredValue", "useTransition", "useEffectEvent")) or bool(re.search(r"return\s*<", text))


def describe_definitions(definitions: list[tuple[str, str]], *, react_like: bool) -> str:
    phrases = []
    for kind, name in definitions[:2]:
        human_name = humanize_token(name)
        if kind == "function" and react_like and name[:1].isupper():
            phrases.append(f"defines component {human_name}")
        else:
            phrases.append(f"defines {kind} {human_name}")
    return join_readable(phrases)


def summarize_sql_block(lines: list[str]) -> str | None:
    text = " ".join(line.strip() for line in lines if line.strip()).lower()
    if text.startswith("select") and " from " in text:
        table_match = re.search(r"\bfrom\s+([A-Za-z_][A-Za-z0-9_]*)", text)
        if table_match:
            return f"queries {humanize_token(table_match.group(1))}"
        return "runs a select query"
    if text.startswith("insert") and " into " in text:
        table_match = re.search(r"\binto\s+([A-Za-z_][A-Za-z0-9_]*)", text)
        if table_match:
            return f"inserts into {humanize_token(table_match.group(1))}"
        return "runs an insert query"
    if text.startswith("update "):
        table_match = re.search(r"\bupdate\s+([A-Za-z_][A-Za-z0-9_]*)", text)
        if table_match:
            return f"updates {humanize_token(table_match.group(1))}"
        return "runs an update query"
    if text.startswith("delete") and " from " in text:
        table_match = re.search(r"\bfrom\s+([A-Za-z_][A-Za-z0-9_]*)", text)
        if table_match:
            return f"deletes from {humanize_token(table_match.group(1))}"
        return "runs a delete query"
    return None


def summarize_code_block(fence_line: str, code_lines: list[str]) -> str:
    language = fence_line.strip().lstrip("`").strip().split(None, 1)[0] if fence_line.strip().lstrip("`").strip() else ""
    nonblank = [line.strip() for line in code_lines if line.strip()]

    if len(nonblank) == 1:
        only_line = nonblank[0]
        if looks_like_command_text(only_line):
            return summarize_command_text(only_line)
        if "/" in only_line or has_known_file_extension(strip_reference_suffix(only_line)):
            return summarize_hidden_reference(only_line)

    language_label = summarize_language_name(language)
    text = "\n".join(nonblank)
    react_like = is_react_like_block(language, text)
    definitions = detect_code_definitions(nonblank)
    assignment_targets = detect_assignment_targets(nonblank)

    descriptors = []
    if definitions:
        descriptors.append(describe_definitions(definitions, react_like=react_like))

    if react_like and "uses React hooks" not in descriptors:
        if any(token in text for token in ("useEffect", "useState", "useReducer", "useRef", "useMemo", "useCallback", "useDeferredValue", "useTransition", "useEffectEvent", "useSearchParams")):
            descriptors.append("uses React hooks")
        elif bool(re.search(r"return\s*<", text)):
            descriptors.append("renders UI")
    elif any(token in text for token in ("fetch(", "axios.", "URLSession", "requests.", "httpx.", "client.get(", "client.post(")):
        descriptors.append("fetches data")
    elif any(token in text for token in ("describe(", "test(", "it(", "expect(", "assert ")):
        descriptors.append("defines tests")

    if language.strip().lower() == "sql":
        sql_descriptor = summarize_sql_block(nonblank)
        if sql_descriptor:
            descriptors = [sql_descriptor]

    if not descriptors and assignment_targets:
        descriptors.append(f"sets {join_readable([humanize_token(name) for name in assignment_targets[:2]])}")

    prefix = f"{language_label} snippet" if language_label else "Code snippet"
    if descriptors:
        return f"{prefix} that {join_readable(descriptors[:2])}."
    line_count = len(nonblank)
    return f"{prefix} with {line_count} lines."


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
        path = match.group(0)
        if is_code_silent():
            return summarize_hidden_reference(path)
        return humanize_path(path)

    text = re.sub(
        r"(?<!https:)(?<!http:)\b[\w.~-]+(?:/[\w.~:-]+)+\b",
        path_repl,
        text,
    )

    def file_repl(match: re.Match[str]) -> str:
        filename = match.group(0)
        if is_code_silent():
            return summarize_hidden_reference(filename)
        return humanize_token(filename)

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
    def repl(match: re.Match[str]) -> str:
        value = match.group(1)
        if is_code_silent():
            return summarize_hidden_reference(value)
        return humanize_token(value)

    return re.sub(r"`([^`]+)`", repl, text)


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
    file_summary = maybe_summarize_file_heavy_text(text)
    if file_summary is not None:
        return apply_pronunciation_overrides(file_summary)
    if is_code_silent() and looks_like_command_text(text.strip()):
        return apply_pronunciation_overrides(summarize_command_text(text))
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
    return apply_pronunciation_overrides(text.strip())


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
    if is_summary_mode() and is_code_silent():
        refs = [
            item
            for item in items
            if len(extract_file_like_references(item)) == 1
            and len(re.findall(r"[A-Za-z]+", PATH_OR_FILE_PATTERN.sub(" ", item))) <= 3
        ]
        if len(refs) >= 2 and len(refs) >= max(2, len(items) - 1):
            subject = classify_reference_group([extract_file_like_references(item)[0] for item in refs])
            return apply_pronunciation_overrides(
                f"{len(items)} {subject}. Say \"read items\" for the full list."
            )

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
    text = strip_nonspoken_metadata(text)
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
            if is_code_silent():
                code_lines = []
                j = i + 1
                while j < len(lines) and classify_line(lines[j]) != "fence":
                    code_lines.append(lines[j])
                    j += 1
                output.append(summarize_code_block(line, code_lines))
                i = j + 1 if j < len(lines) else j
                continue
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
            command_text = summarize_command_text(line[2:]) if is_code_silent() else normalize_plain_text(line[2:])
            output.append(f"Command: {command_text}.")
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
