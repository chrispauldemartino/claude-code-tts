#!/usr/bin/env python3
"""Persist and resolve stable spoken names for voice-mode sessions."""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path


DEFAULT_PRIMARY_WORKTREE = "/Users/demo/elleai"
ADJECTIVES = (
    "amber", "brisk", "calm", "clear", "cobalt", "crisp", "eager", "gentle",
    "golden", "keen", "lively", "lunar", "mellow", "nimble", "quiet", "rapid",
    "silver", "steady", "sunny", "vivid", "warm", "wise", "bright", "bold",
)
NOUNS = (
    "badger", "brook", "cedar", "comet", "falcon", "fern", "fox", "harbor",
    "heron", "island", "lark", "maple", "meadow", "otter", "pine", "raven",
    "river", "sparrow", "summit", "tiger", "willow", "wren", "orchid", "trail",
)


def sessions_dir():
    return Path(os.environ.get("CLAUDE_TTS_SESSIONS_DIR", "~/.claude-tts/sessions")).expanduser()


def registry_path(source, session_id):
    digest = hashlib.sha256((source + "\0" + session_id).encode("utf-8")).hexdigest()
    return sessions_dir() / (digest + ".json")


def load_record(source, session_id):
    path = registry_path(source, session_id)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    if value.get("source") != source or value.get("session_id") != session_id:
        return None
    return value


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def save_record(record):
    directory = sessions_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = registry_path(record["source"], record["session_id"])
    fd, temporary = tempfile.mkstemp(prefix=".session-", suffix=".json", dir=str(directory))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(record, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass
    result = dict(record)
    result["registry_path"] = str(path)
    return result


def number_words(number):
    ones = (
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    )
    tens = ("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
    if number < 20:
        return ones[number]
    if number < 100:
        return tens[number // 10] + (("-" + ones[number % 10]) if number % 10 else "")
    if number < 1000:
        tail = number % 100
        return ones[number // 100] + " hundred" + ((" " + number_words(tail)) if tail else "")
    return str(number)


def normalize_speech(value):
    text = "".join(ch for ch in value if unicodedata.category(ch)[0] != "C")
    text = re.sub(r"[_-]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    def expand_number(match):
        number = int(match.group(0))
        return number_words(number) if number <= 999 else match.group(0)

    text = re.sub(r"(?<![A-Za-z0-9])\d{1,3}(?![A-Za-z0-9])", expand_number, text)

    digit_names = {
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    }

    def expand_short_hex(match):
        token = match.group(0)
        mixed = re.search(r"[A-Fa-f]", token) and re.search(r"\d", token)
        if not mixed and len(token) < 6:
            return token
        return " ".join(digit_names.get(ch, ch.lower()) for ch in token)

    text = re.sub(r"\b[A-Fa-f0-9]{4,8}\b", expand_short_hex, text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= 40:
        return text
    clipped = text[:40]
    if len(text) > 40 and not text[40].isspace() and " " in clipped:
        clipped = clipped.rsplit(" ", 1)[0]
    return clipped.rstrip()


def run_git(cwd, *args):
    try:
        return subprocess.check_output(
            ["git", "-C", cwd] + list(args), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def worktree_root(cwd):
    return run_git(cwd, "rev-parse", "--show-toplevel")


def marker_handoff_id(cwd, root):
    checked = []
    for directory in (cwd, root):
        if not directory or directory in checked:
            continue
        checked.append(directory)
        marker = Path(directory) / ".elle-current-handoff"
        try:
            value = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            continue
        marker_id = value.get("id") if isinstance(value, dict) else None
        if re.fullmatch(r"\d+", str(marker_id or "")):
            return str(marker_id)
    return ""


def latest_custom_title(transcript_path, session_id):
    if not transcript_path:
        return ""
    latest = ""
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(record, dict) or record.get("type") != "custom-title":
                    continue
                if record.get("sessionId") not in (None, "", session_id):
                    continue
                candidate = str(record.get("customTitle") or "").strip()
                if candidate:
                    latest = candidate
    except OSError:
        return ""
    return latest


def speakable(value):
    normalized = normalize_speech(value)
    return bool(normalized and re.search(r"[A-Za-z0-9]", normalized))


def generated_name(session_id):
    digest = hashlib.sha256(session_id.encode("utf-8")).digest()
    adjective = ADJECTIVES[int.from_bytes(digest[:2], "big") % len(ADJECTIVES)]
    noun = NOUNS[int.from_bytes(digest[2:4], "big") % len(NOUNS)]
    return adjective + " " + noun


def is_primary_worktree(cwd, root):
    primary = os.path.realpath(os.environ.get("ELLE_PRIMARY_WORKTREE", DEFAULT_PRIMARY_WORKTREE))
    if not root or os.path.realpath(root) != primary:
        return False
    return run_git(root, "rev-parse", "--git-common-dir") == ".git"


def automatic_name(session_id, cwd, transcript_path, launch_name):
    root = worktree_root(cwd) if cwd else ""
    env_id = os.environ.get("ELLE_HANDOFF_ID", "").strip()
    if re.fullmatch(r"\d+", env_id):
        return "handoff " + env_id, "handoff_env"

    marker_id = marker_handoff_id(cwd, root)
    if marker_id:
        return "handoff " + marker_id, "handoff_marker"

    for directory in (cwd, root):
        match = re.fullmatch(r"handoff_(\d+)", os.path.basename(os.path.normpath(directory or "")))
        if match:
            return "handoff " + match.group(1), "worktree_name"

    if is_primary_worktree(cwd, root):
        return "main session", "primary_worktree"

    title = latest_custom_title(transcript_path, session_id)
    if title and speakable(title):
        return title, "custom_title"
    if launch_name and speakable(launch_name):
        return launch_name, "launch_name"
    return generated_name(session_id), "generated"


def register(args):
    if not args.source or not args.session_id:
        raise SystemExit("source and session id are required")
    existing = load_record(args.source, args.session_id)
    if (
        existing
        and speakable(existing.get("display_name", ""))
        and existing.get("name_provenance")
    ):
        display_name = existing.get("display_name", "")
        provenance = existing.get("name_provenance")
    else:
        display_name, provenance = automatic_name(
            args.session_id, args.cwd, args.transcript_path, args.launch_name
        )

    record = {
        "source": args.source,
        "session_id": args.session_id,
        "transcript_path": args.transcript_path or (existing or {}).get("transcript_path", ""),
        "display_name": display_name,
        "speech_name": normalize_speech(display_name),
        "name_provenance": provenance,
        "updated_at": utc_now(),
    }
    return save_record(record)


def override(args):
    if not args.source or not args.session_id or not speakable(args.name):
        raise SystemExit("source, session id, and a speakable name are required")
    existing = load_record(args.source, args.session_id) or {}
    record = {
        "source": args.source,
        "session_id": args.session_id,
        "transcript_path": existing.get("transcript_path", ""),
        "display_name": args.name.strip(),
        "speech_name": normalize_speech(args.name),
        "name_provenance": "override",
        "updated_at": utc_now(),
    }
    return save_record(record)


def show(args):
    record = load_record(args.source, args.session_id)
    if not record:
        raise SystemExit(1)
    result = dict(record)
    result["registry_path"] = str(registry_path(args.source, args.session_id))
    return result


def build_parser():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    register_parser = subparsers.add_parser("register")
    register_parser.add_argument("--source", required=True)
    register_parser.add_argument("--session-id", required=True)
    register_parser.add_argument("--cwd", default=os.getcwd())
    register_parser.add_argument("--transcript-path", default="")
    register_parser.add_argument(
        "--launch-name",
        default=os.environ.get("CLAUDE_CODE_NAME", os.environ.get("CLAUDE_NAME", "")),
    )

    override_parser = subparsers.add_parser("override")
    override_parser.add_argument("--source", required=True)
    override_parser.add_argument("--session-id", required=True)
    override_parser.add_argument("--name", required=True)

    show_parser = subparsers.add_parser("show")
    show_parser.add_argument("--source", required=True)
    show_parser.add_argument("--session-id", required=True)

    normalize_parser = subparsers.add_parser("normalize")
    normalize_parser.add_argument("value")
    return parser


def main():
    args = build_parser().parse_args()
    if args.command == "normalize":
        print(normalize_speech(args.value))
        return
    if args.command == "register":
        result = register(args)
    elif args.command == "override":
        result = override(args)
    else:
        result = show(args)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
