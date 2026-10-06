#!/usr/bin/env python3
"""Export completed transcript turns into an atomic, non-autoplay batch."""

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from pathlib import Path

MAX_SCAN = 32 * 1024 * 1024
MAX_ANSWER = 256 * 1024
MAX_BATCH = 2 * 1024 * 1024
NORMALIZATION_VERSION = 1


def parse_time(value):
    if isinstance(value, (int, float)):
        return float(value)
    if not value:
        return 0.0
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def reverse_bounded_records(path):
    skipped = 0
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        start = max(0, size - MAX_SCAN)
        handle.seek(start)
        data = handle.read(MAX_SCAN)
    limited = start > 0
    if limited:
        newline = data.find(b"\n")
        data = data[newline + 1 :] if newline >= 0 else b""
        skipped += 1
    records = []
    for raw in data.splitlines():
        try:
            item = json.loads(raw)
            if isinstance(item, dict):
                records.append(item)
            else:
                skipped += 1
        except (UnicodeDecodeError, ValueError, TypeError):
            skipped += 1
    return records, skipped, limited


def resolve_transcript_path(source, session_id, requested):
    if requested and requested != "auto" and Path(requested).is_file():
        return requested
    if source != "Codex":
        raise SystemExit("transcript path is unavailable for this session")
    root = Path(os.environ.get("CODEX_SESSIONS_DIR", "~/.codex/sessions")).expanduser()
    candidates = sorted(root.glob("**/*.jsonl"), key=lambda path: path.stat().st_mtime, reverse=True)
    for candidate in candidates:
        records, _, _ = reverse_bounded_records(candidate)
        for record in records:
            payload = record.get("payload") or {}
            if record.get("type") == "session_meta" and payload.get("id") == session_id:
                return str(candidate)
    raise SystemExit("no Codex transcript found for session " + session_id)


def content_blocks(message):
    content = message.get("content", []) if isinstance(message, dict) else []
    if isinstance(content, str):
        return [content]
    result = []
    for block in content if isinstance(content, list) else []:
        if isinstance(block, dict) and block.get("type") in ("text", "output_text"):
            value = block.get("text")
            if isinstance(value, str) and value.strip():
                result.append(value.strip())
    return result


def genuine_user(record):
    if record.get("type") != "user":
        return False
    content = (record.get("message") or {}).get("content", [])
    if isinstance(content, str):
        return bool(content.strip())
    blocks = content if isinstance(content, list) else []
    return any(isinstance(block, dict) and block.get("type") != "tool_result" for block in blocks)


def claude_turns(records, session_id):
    skipped = sum(1 for record in records if record.get("isSidechain"))
    nodes = {}
    order = {}
    for index, record in enumerate(records):
        if record.get("isSidechain") or record.get("sessionId") not in (None, "", session_id):
            continue
        node_id = record.get("uuid")
        if node_id:
            nodes[node_id] = record
            order[node_id] = index
    parents = {record.get("parentUuid") for record in nodes.values() if record.get("parentUuid")}
    leaves = [node_id for node_id in nodes if node_id not in parents]
    if not leaves:
        return [], skipped
    leaf = max(leaves, key=lambda node_id: (parse_time(nodes[node_id].get("timestamp")), order[node_id]))
    chain = []
    seen = set()
    while leaf and leaf in nodes and leaf not in seen:
        seen.add(leaf)
        chain.append(nodes[leaf])
        leaf = nodes[leaf].get("parentUuid")
    chain.reverse()

    turns = []
    current = None
    for record in chain:
        if genuine_user(record):
            if current and current["complete"] and current["parts"]:
                turns.append(current)
            elif current and current["parts"]:
                skipped += 1
            current = {"parts": [], "complete": False, "turn_id": record.get("uuid", ""), "answered_at": 0.0}
            continue
        if current is None or record.get("type") != "assistant":
            continue
        parts = content_blocks(record.get("message") or {})
        current["parts"].extend(parts)
        message = record.get("message") or {}
        if message.get("stop_reason") not in (None, "", "tool_use"):
            current["complete"] = True
            current["turn_id"] = message.get("id") or record.get("uuid") or current["turn_id"]
            current["answered_at"] = parse_time(record.get("timestamp"))
    if current and current["complete"] and current["parts"]:
        turns.append(current)
    elif current and current["parts"]:
        skipped += 1
    return turns, skipped


def codex_text(payload):
    if not isinstance(payload, dict):
        return ""
    if isinstance(payload.get("message"), str):
        return payload["message"].strip()
    return " ".join(content_blocks(payload)).strip()


def codex_turns(records, session_id):
    meta_ids = [(r.get("payload") or {}).get("id") for r in records if r.get("type") == "session_meta"]
    if meta_ids and session_id not in meta_ids:
        return [], 0
    turns = []
    current = None
    sequence = 0
    for record in records:
        payload = record.get("payload") or {}
        kind = record.get("type")
        subtype = payload.get("type")
        is_user_boundary = (
            kind == "event_msg" and subtype in ("user_message", "user_prompt")
        ) or (
            kind == "response_item" and subtype == "message" and payload.get("role") == "user"
        )
        if is_user_boundary:
            if current and (current.get("preferred") or current.get("fallback")):
                turns.append(current)
            sequence += 1
            current = {"preferred": "", "fallback": "", "turn_id": str(payload.get("id") or sequence), "answered_at": 0.0}
            continue
        if current is None:
            continue
        if kind == "response_item" and subtype == "message" and payload.get("role") == "assistant":
            text = codex_text(payload)
            phase = payload.get("phase")
            if text and phase != "commentary" and payload.get("status") not in ("in_progress", "incomplete"):
                current["preferred"] = text
                current["turn_id"] = str(payload.get("id") or current["turn_id"])
                current["answered_at"] = parse_time(record.get("timestamp"))
        elif kind == "event_msg" and subtype == "agent_message":
            text = codex_text(payload)
            if text:
                current["fallback"] = text
                current["answered_at"] = parse_time(record.get("timestamp"))
    if current and (current.get("preferred") or current.get("fallback")):
        turns.append(current)
    return [
        {"parts": [turn.get("preferred") or turn.get("fallback")], "turn_id": turn["turn_id"], "answered_at": turn["answered_at"]}
        for turn in turns
    ], 0


def normalized_answer(text):
    text = unicodedata.normalize("NFC", text.replace("\r\n", "\n").replace("\r", "\n"))
    return "\n".join(line.rstrip() for line in text.strip().splitlines())


def session_name(source, session_id):
    helper = Path(__file__).with_name("session-metadata.py")
    try:
        output = subprocess.check_output(
            [sys.executable, str(helper), "show", "--source", source, "--session-id", session_id],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        name = str(json.loads(output).get("speech_name") or "")
        if name:
            return name
    except (OSError, subprocess.CalledProcessError, ValueError, TypeError):
        pass
    if source == "Codex":
        index_path = Path(os.environ.get("CODEX_SESSION_INDEX", "~/.codex/session_index.jsonl")).expanduser()
        latest = ""
        try:
            with index_path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    try:
                        record = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    if record.get("id") == session_id and record.get("thread_name"):
                        latest = str(record["thread_name"])
        except OSError:
            return ""
        if latest:
            try:
                return subprocess.check_output(
                    [sys.executable, str(helper), "normalize", latest], text=True
                ).strip()
            except (OSError, subprocess.CalledProcessError):
                return latest
    return ""


def prepare(text):
    helper = Path(__file__).with_name("prepare-speech.sh")
    return subprocess.check_output([str(helper)], input=text, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", choices=("Claude Code", "Codex"))
    parser.add_argument("session_id")
    parser.add_argument("transcript_path")
    parser.add_argument("count", nargs="?", type=int, default=10)
    args = parser.parse_args()
    if not 1 <= args.count <= 100:
        parser.error("N must be between 1 and 100")

    transcript_path = resolve_transcript_path(args.source, args.session_id, args.transcript_path)
    records, skipped, scan_limited = reverse_bounded_records(transcript_path)
    turns, adapter_skipped = claude_turns(records, args.session_id) if args.source == "Claude Code" else codex_turns(records, args.session_id)
    skipped += adapter_skipped
    turns = turns[-args.count :]
    outbox = Path(os.environ.get("CLAUDE_TTS_BACKFILL_OUTBOX", "/tmp/claude-tts-backfill-outbox"))
    outbox.mkdir(parents=True, exist_ok=True)
    batch_id = "%d-%s" % (int(dt.datetime.now().timestamp() * 1000), uuid.uuid4().hex[:12])
    temporary = Path(tempfile.mkdtemp(prefix=".%s." % batch_id, dir=str(outbox)))
    imported_at = dt.datetime.now().timestamp()
    exported = 0
    limited = 1 if scan_limited else 0
    total_bytes = 0
    name = session_name(args.source, args.session_id)
    try:
        for turn in turns:
            full = normalized_answer(" ".join(turn["parts"]))
            full_bytes = full.encode("utf-8")
            if not full or len(full_bytes) > MAX_ANSWER:
                skipped += 1
                limited += 1
                continue
            speech = prepare(full)
            item_bytes = len(full_bytes) + len(speech.encode("utf-8"))
            if not speech or total_bytes + item_bytes > MAX_BATCH:
                skipped += 1
                limited += 1
                continue
            prefix = "%03d" % exported
            content_hash = hashlib.sha256(full.encode("utf-8")).hexdigest()
            metadata = {
                "schema_version": 1, "origin": "backfill", "autoplay": False,
                "batch_id": batch_id, "batch_index": exported, "turn_id": turn["turn_id"],
                "answered_at": turn["answered_at"], "imported_at": imported_at,
                "content_hash": content_hash, "normalization_version": NORMALIZATION_VERSION,
            }
            (temporary / (prefix + ".txt")).write_text(speech, encoding="utf-8")
            (temporary / (prefix + ".full.txt")).write_text(full, encoding="utf-8")
            (temporary / (prefix + ".session")).write_text(args.session_id, encoding="utf-8")
            (temporary / (prefix + ".source")).write_text(args.source, encoding="utf-8")
            (temporary / (prefix + ".session_name")).write_text(name, encoding="utf-8")
            (temporary / (prefix + ".meta.json")).write_text(json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8")
            total_bytes += item_bytes
            exported += 1
        manifest = {"schema_version": 1, "batch_id": batch_id, "item_count": exported,
                    "source": args.source, "session_id": args.session_id, "imported_at": imported_at,
                    "skipped": skipped, "limited": limited}
        (temporary / "batch.json").write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        destination = outbox / batch_id
        os.replace(temporary, destination)
    except Exception:
        for child in temporary.iterdir():
            child.unlink()
        temporary.rmdir()
        raise
    print(json.dumps({"batch_id": batch_id, "batch_dir": str(destination), "exported": exported,
                      "skipped": skipped, "dupes": 0, "limited": limited}, sort_keys=True))


if __name__ == "__main__":
    main()
