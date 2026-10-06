#!/usr/bin/env python3
"""Isolated speech preparation shared by the iPhone Stop hook and tests."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
from typing import Any


SPOKEN_HASHES_MAX = 200
MESSAGE_BREAK = "\n<<MSG_BREAK>>\n"
VM_STATUS_PREFIXES = (
    "Voice mode",
    "Listen mode",
    "Dictation mode",
    "Quiet mode",
    "Voice test queued",
    "Repeating last",
    "Nothing to repeat",
    "Done.",
    "TTS:",
    "Mic:",
    "Cue:",
    "Usage: /vm",
)


def is_title_only_payload(text: str) -> bool:
    """Match auto-speak.sh's exact one-key JSON title payload guard."""
    if not isinstance(text, str) or not text.strip():
        return False
    try:
        parsed = json.loads(text)
    except (TypeError, ValueError):
        return False
    return isinstance(parsed, dict) and sorted(parsed) == ["title"]


def is_vm_status(text: str) -> bool:
    """Match the VM control/status prefixes excluded by auto-speak.sh."""
    return isinstance(text, str) and text.startswith(VM_STATUS_PREFIXES)


def _text_blocks(content: Any) -> list[str]:
    if isinstance(content, str):
        return [content.strip()] if content.strip() else []
    if not isinstance(content, list):
        return []
    result = []
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type", "")
        text = ""
        if kind in ("text", "output_text", "input_text"):
            text = block.get("text", "")
        elif kind == "tool_result" and isinstance(block.get("content"), str):
            text = block["content"]
        if isinstance(text, str) and text.strip():
            result.append(text.strip())
    return result


def _normalize_last(raw: Any) -> str:
    if not isinstance(raw, str) or not raw.strip():
        return ""
    value = raw.strip()
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError):
        return value
    if isinstance(parsed, dict) and set(parsed) == {"title"}:
        return ""
    return value


def _choose_texts(texts: list[str], last: str) -> str:
    combined = "\n<<MSG_BREAK>>\n".join(texts)
    if last and last[:50] not in combined:
        return last
    return combined


def extract_final_assistant_text(payload: dict[str, Any]) -> str:
    """Port auto-speak's Claude/Codex transcript selection semantics."""
    last = _normalize_last(payload.get("last_assistant_message", ""))
    transcript_value = payload.get("transcript_path", "")
    transcript = Path(transcript_value).expanduser() if isinstance(transcript_value, str) and transcript_value else None
    claude: list[str] = []
    codex_final: list[str] = []
    codex_commentary: list[str] = []
    found_claude = False
    found_codex = False

    if transcript and transcript.is_file():
        try:
            lines = transcript.read_text(encoding="utf-8", errors="replace").splitlines()
            for line in reversed(lines):
                try:
                    entry = json.loads(line)
                except (TypeError, ValueError):
                    continue
                if not isinstance(entry, dict):
                    continue
                kind = entry.get("type", "")
                payload_obj = entry.get("payload", {})
                payload_obj = payload_obj if isinstance(payload_obj, dict) else {}

                if kind == "assistant":
                    message = entry.get("message", {})
                    content = message.get("content", []) if isinstance(message, dict) else []
                    blocks = [
                        str(block.get("text", "")).strip()
                        for block in content
                        if isinstance(block, dict)
                        and block.get("type") == "text"
                        and str(block.get("text", "")).strip()
                    ] if isinstance(content, list) else []
                    if blocks:
                        claude.append("\n".join(blocks))
                        found_claude = True
                    continue
                if kind == "user":
                    if found_claude:
                        break
                    continue

                if kind == "response_item" and payload_obj.get("type") == "message":
                    blocks = _text_blocks(payload_obj.get("content", []))
                    if payload_obj.get("role") == "assistant" and blocks:
                        joined = "\n".join(blocks)
                        if payload_obj.get("phase") == "final_answer":
                            codex_final.append(joined)
                            found_codex = True
                        elif payload_obj.get("phase") == "commentary":
                            codex_commentary.append(joined)
                            found_codex = True
                    elif payload_obj.get("role") == "user" and found_codex:
                        break
                    continue

                if kind == "event_msg":
                    event_type = payload_obj.get("type", "")
                    if event_type == "user_message" and found_codex:
                        break
                    if event_type == "agent_message" and not found_codex:
                        message = str(payload_obj.get("message", "")).strip()
                        if message:
                            codex_commentary.append(message)
                            found_codex = True
        except OSError:
            pass

    claude.reverse()
    codex_final.reverse()
    codex_commentary.reverse()
    if codex_final:
        return _choose_texts(codex_final, last)
    if claude:
        return _choose_texts(claude, last)
    if codex_commentary:
        return last or "\n<<MSG_BREAK>>\n".join(codex_commentary)
    if last:
        return last
    for key in ("stop_hook_message", "message", "content"):
        value = payload.get(key, "")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def strip_markdown(text: str) -> str:
    """Faithful Python port of auto-speak.sh's strip_markdown function."""
    lines: list[str] = []
    in_code = False
    for line in text.splitlines():
        if line.startswith("```"):
            in_code = not in_code
            continue
        if not in_code:
            lines.append(line)
    text = "\n".join(lines)
    substitutions = (
        (r"^#{1,6} ", ""),
        (r"\*\*([^*]*)\*\*", r"\1"),
        (r"\*([^*]*)\*", r"\1"),
        (r"__([^_]*)__", r"\1"),
        (r"_([^_]*)_", r"\1"),
        (r"`([^`]*)`", r"\1"),
        (r"\[([^]]*)\]\([^)]*\)", r"\1"),
        (r"^- ", ""),
        (r"^\* ", ""),
        (r"^[0-9]+\. ", ""),
    )
    output = []
    for line in text.splitlines():
        for pattern, replacement in substitutions:
            line = re.sub(pattern, replacement, line)
        if line.strip():
            output.append(line)
    return "\n".join(output)


def _load_technical_transformer(state_dir: Path):
    script = Path(__file__).resolve().parents[1] / "bin" / "transform-for-speech.py"
    spec = importlib.util.spec_from_file_location("phone_technical_speech_transform", script)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.CONFIG_FILE = str(state_dir / "transform-settings")
    module.CACHE_DIR = str(state_dir / "detail-cache")
    return module


def prepare_speech(text: str, state_dir: Path) -> str:
    """Transform and clean each auto-speak message segment independently."""
    try:
        transformer = _load_technical_transformer(state_dir)
    except Exception:
        transformer = None

    cleaned_segments = []
    for segment in text.split(MESSAGE_BREAK):
        segment = segment.strip()
        if not segment:
            continue
        transformed = segment
        try:
            if transformer is not None:
                transformed = transformer.final_polish(transformer.process_input(segment)) or segment
        except Exception:
            transformed = segment
        cleaned = strip_markdown(transformed).strip()
        if cleaned:
            cleaned_segments.append(cleaned)
    return "\n".join(cleaned_segments)


def _sentences(text: str) -> list[str]:
    return [line for line in re.sub(r"([.!?]) ", r"\1\n", text).splitlines() if line]


def _sentence_hash(sentence: str) -> str:
    normalized = re.sub(r" +", " ", sentence.lower()).strip()
    return hashlib.md5(normalized.encode("utf-8")).hexdigest() if normalized else ""


def filter_new_sentences(text: str, state_dir: Path) -> str:
    """Return text not present in auto-speak-compatible rolling history."""
    hashes_path = state_dir / "spoken-hashes"
    history_exists = hashes_path.exists()
    existing = hashes_path.read_text(encoding="utf-8").splitlines() if history_exists else []
    new_sentences = []
    for sentence in _sentences(text):
        digest = _sentence_hash(sentence)
        if not digest or digest not in existing:
            new_sentences.append(sentence)
    return ("\n".join(new_sentences) if history_exists else text).strip()


def record_spoken_sentences(text: str, state_dir: Path) -> None:
    """Commit successfully published speech to rolling history atomically."""
    if not text:
        return
    hashes_path = state_dir / "spoken-hashes"
    existing = hashes_path.read_text(encoding="utf-8").splitlines() if hashes_path.exists() else []
    additions = [digest for digest in (_sentence_hash(item) for item in _sentences(text)) if digest]
    if not additions:
        return
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = state_dir / f".spoken-hashes.{os.getpid()}.tmp"
    temporary.write_text("\n".join((existing + additions)[-SPOKEN_HASHES_MAX:]) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, hashes_path)


def filter_and_record_new_sentences(text: str, state_dir: Path) -> str:
    """Compatibility helper matching auto-speak's filter-then-record call pair."""
    filtered = filter_new_sentences(text, state_dir)
    record_spoken_sentences(filtered, state_dir)
    return filtered
