#!/usr/bin/env python3
"""Non-blocking, file-only Stop hook for iPhone voice playback."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

from phone_speech import (
    extract_final_assistant_text,
    filter_new_sentences,
    is_title_only_payload,
    is_vm_status,
    prepare_speech,
    record_spoken_sentences,
)


def state_dir() -> Path:
    override = os.environ.get("CLAUDE_TTS_PHONE_STATE_DIR")
    if override and os.environ.get("PHONE_VOICE_TESTING") == "1":
        return Path(override).expanduser()
    return Path.home() / ".claude-tts-phone"


def prune_queue(queue: Path, keep: int = 50) -> None:
    audio = sorted(
        (item for item in queue.glob("*.m4a") if not item.name.startswith(".")),
        key=lambda item: item.name,
    )
    for old in audio[:-keep]:
        old.unlink(missing_ok=True)
        old.with_suffix(".txt").unlink(missing_ok=True)


def spawn_worker(state: Path) -> None:
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--worker", str(state)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def build_say_command(
    say_bin: str,
    destination: Path,
    *,
    nice_bin: str,
    taskpolicy_bin: str | None,
) -> list[str]:
    command = [nice_bin, "-n", "10", say_bin, "-o", str(destination), "--data-format=aac"]
    if taskpolicy_bin:
        command = [taskpolicy_bin, "-b", *command]
    return command


def synthesize(job_path: Path) -> None:
    try:
        job = json.loads(job_path.read_text(encoding="utf-8"))
        state = Path(job["state"])
        queue = state / "queue"
        queue.mkdir(mode=0o700, parents=True, exist_ok=True)
        raw = extract_final_assistant_text(job["payload"])
        if not raw or is_title_only_payload(raw):
            return
        cleaned = prepare_speech(raw, state)
        if not cleaned or is_vm_status(cleaned):
            return
        text = filter_new_sentences(cleaned, state)
        if not text:
            return
        destination = queue / f"{job['stem']}.m4a"
        temporary = queue / f".{job['stem']}.partial.m4a"
        say_bin = (
            os.environ.get("PHONE_SAY_BIN", "/usr/bin/say")
            if os.environ.get("PHONE_VOICE_TESTING") == "1"
            else "/usr/bin/say"
        )
        nice_bin = shutil.which("nice") or "/usr/bin/nice"
        taskpolicy_bin = shutil.which("taskpolicy")
        subprocess.run(
            build_say_command(
                say_bin,
                temporary,
                nice_bin=nice_bin,
                taskpolicy_bin=taskpolicy_bin,
            ),
            input=text,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
            check=True,
        )
        if not temporary.is_file() or temporary.stat().st_size == 0:
            return
        text_tmp = queue / f".{job['stem']}.txt.tmp"
        text_tmp.write_text(text, encoding="utf-8")
        os.replace(text_tmp, queue / f"{job['stem']}.txt")
        os.replace(temporary, destination)
        record_spoken_sentences(text, state)
        prune_queue(queue)
    except Exception:
        pass
    finally:
        try:
            job_path.unlink(missing_ok=True)
            if "temporary" in locals():
                temporary.unlink(missing_ok=True)
            if "text_tmp" in locals():
                text_tmp.unlink(missing_ok=True)
        except Exception:
            pass


def run_one_worker(state: Path) -> None:
    import fcntl

    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    pending = state / "pending"
    pending.mkdir(mode=0o700, exist_ok=True)
    lock_path = state / "worker.lock"
    lock_path.touch(mode=0o600, exist_ok=True)
    with lock_path.open("r+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            time.sleep(0.2)
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
        jobs = sorted(pending.glob("*.json"), key=lambda item: item.name)
        if not jobs:
            return

        def deadline(_signum, _frame):
            raise TimeoutError("phone synthesis deadline exceeded")

        signal.signal(signal.SIGALRM, deadline)
        signal.alarm(35)
        try:
            synthesize(jobs[0])
        finally:
            signal.alarm(0)

    if any(pending.glob("*.json")):
        spawn_worker(state)


def handle_hook() -> None:
    state = state_dir()
    if not (state / "enrolled").is_file():
        return
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return
        event = payload.get("hook_event_name", payload.get("hook_event", "unknown"))
        if event != "Stop":
            return
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        queue = state / "queue"
        pending = state / "pending"
        queue.mkdir(mode=0o700, exist_ok=True)
        pending.mkdir(mode=0o700, exist_ok=True)
        session = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(payload.get("session_id", "session"))).strip("-")
        session = (session or "session")[:48]
        stem = f"{time.time_ns():020d}-{session}"
        job_path = pending / f"{stem}.json"
        job_tmp = pending / f".{stem}.{os.getpid()}.tmp"
        job_tmp.write_text(
            json.dumps({"state": str(state), "stem": stem, "payload": payload}), encoding="utf-8"
        )
        job_tmp.chmod(0o600)
        os.replace(job_tmp, job_path)
        spawn_worker(state)
    except Exception:
        try:
            if "job_tmp" in locals():
                job_tmp.unlink(missing_ok=True)
        except Exception:
            pass
        return


def main() -> int:
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--worker":
            run_one_worker(Path(sys.argv[2]))
        else:
            handle_hook()
    except BaseException:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
