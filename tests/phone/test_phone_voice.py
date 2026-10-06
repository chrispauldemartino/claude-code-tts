#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "hooks" / "phone_speech.py"
HOOK_PATH = ROOT / "hooks" / "phone-speak.py"
SERVER_PATH = ROOT / "bin" / "phone-audio-server.py"
DISPATCH_PATH = ROOT / "bin" / "vm-dispatch.sh"


def load_module(path: Path, name: str):
    if not path.exists():
        raise AssertionError(f"required implementation is missing: {path.relative_to(ROOT)}")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class TransformParityTest(unittest.TestCase):
    """Literal fixtures catch drift from auto-speak.sh's speech cleanup contract."""

    def setUp(self):
        self.helper = load_module(HELPER_PATH, "phone_speech_test")
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_markdown_and_code_fixture_matches_auto_speak_behavior(self):
        raw = (
            "# Result\n"
            "**Done.** Read [the guide](https://example.invalid).\n"
            "```python\nprint('never spoken')\n```\n"
            "- First item\n"
        )
        self.assertEqual(
            self.helper.prepare_speech(raw, self.state),
            "Result\nDone. Read the guide.\npython snippet with 1 lines.\nFirst item",
        )

    def test_each_message_segment_is_transformed_independently(self):
        raw = (
            "```python\n"
            "print('first segment')\n"
            "<<MSG_BREAK>>\n"
            "# Second segment"
        )
        self.assertEqual(
            self.helper.prepare_speech(raw, self.state),
            "python snippet with 1 lines.\nSecond segment",
        )

    def test_title_only_payload_guard_matches_auto_speak(self):
        self.assertTrue(self.helper.is_title_only_payload('{"title":"Rename"}'))
        self.assertFalse(self.helper.is_title_only_payload('{"title":"Rename","body":"Reply"}'))
        self.assertFalse(self.helper.is_title_only_payload("Rename"))

    def test_vm_status_guard_matches_auto_speak_prefixes(self):
        for text in (
            "Voice mode enabled",
            "Listen mode active",
            "Dictation mode enabled",
            "Quiet mode enabled",
            "Voice test queued",
            "Repeating last reply",
            "Nothing to repeat",
            "Done.",
            "TTS: enabled",
            "Mic: enabled",
            "Cue: enabled",
            "Usage: /vm listen",
        ):
            with self.subTest(text=text):
                self.assertTrue(self.helper.is_vm_status(text))
        self.assertFalse(self.helper.is_vm_status("The voice mode implementation is complete."))

    def test_sentence_dedup_fixture_matches_auto_speak_rolling_history(self):
        first = self.helper.filter_and_record_new_sentences(
            "Alpha is ready. Beta is ready!", self.state
        )
        second = self.helper.filter_and_record_new_sentences(
            "ALPHA   is ready. Gamma is ready?", self.state
        )
        self.assertEqual(first, "Alpha is ready. Beta is ready!")
        self.assertEqual(second, "Gamma is ready?")

    def test_filter_does_not_commit_until_recorded(self):
        filtered = self.helper.filter_new_sentences("Retry me.", self.state)
        self.assertEqual(filtered, "Retry me.")
        self.assertFalse((self.state / "spoken-hashes").exists())
        self.helper.record_spoken_sentences(filtered, self.state)
        self.assertEqual(self.helper.filter_new_sentences("RETRY  me.", self.state), "")

    def test_transcript_final_assistant_text_takes_precedence(self):
        transcript = self.state / "session.jsonl"
        entries = [
            {"type": "user", "message": {"content": "question"}},
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "First block."}]},
            },
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "Final block."}]},
            },
        ]
        transcript.write_text("\n".join(json.dumps(item) for item in entries), encoding="utf-8")
        payload = {
            "hook_event_name": "Stop",
            "transcript_path": str(transcript),
            "last_assistant_message": "Final block.",
        }
        self.assertEqual(
            self.helper.extract_final_assistant_text(payload),
            "First block.\n<<MSG_BREAK>>\nFinal block.",
        )


class HookSafetyTest(unittest.TestCase):
    def test_title_only_and_vm_status_jobs_never_invoke_say(self):
        load_module(HELPER_PATH, "phone_speech")
        hook = load_module(HOOK_PATH, "phone_speak_guard_test")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "say-was-invoked"
            fake_say = root / "say"
            fake_say.write_text(
                "#!/bin/sh\nprintf invoked > \"$PHONE_SAY_MARKER\"\n",
                encoding="utf-8",
            )
            fake_say.chmod(0o755)
            previous_testing = os.environ.get("PHONE_VOICE_TESTING")
            previous_say = os.environ.get("PHONE_SAY_BIN")
            previous_marker = os.environ.get("PHONE_SAY_MARKER")
            os.environ.update(
                {
                    "PHONE_VOICE_TESTING": "1",
                    "PHONE_SAY_BIN": str(fake_say),
                    "PHONE_SAY_MARKER": str(marker),
                }
            )
            try:
                payloads = (
                    {"message": '{"title":"Rename chat"}'},
                    {"last_assistant_message": "Voice mode enabled"},
                )
                for index, payload in enumerate(payloads):
                    with self.subTest(payload=payload):
                        state = root / f"state-{index}"
                        state.mkdir()
                        job = root / f"job-{index}.json"
                        job.write_text(
                            json.dumps(
                                {
                                    "state": str(state),
                                    "stem": f"item-{index}",
                                    "payload": payload,
                                }
                            ),
                            encoding="utf-8",
                        )
                        hook.synthesize(job)
                        self.assertFalse(job.exists())
                        self.assertFalse(marker.exists())
                        self.assertEqual(list((state / "queue").glob("*.m4a")), [])
            finally:
                for key, value in (
                    ("PHONE_VOICE_TESTING", previous_testing),
                    ("PHONE_SAY_BIN", previous_say),
                    ("PHONE_SAY_MARKER", previous_marker),
                ):
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

    def test_say_command_uses_nice_and_available_background_taskpolicy(self):
        load_module(HELPER_PATH, "phone_speech")
        hook = load_module(HOOK_PATH, "phone_speak_test")
        command = hook.build_say_command(
            "/usr/bin/say",
            Path("/tmp/reply.m4a"),
            nice_bin="/usr/bin/nice",
            taskpolicy_bin="/usr/sbin/taskpolicy",
        )
        self.assertEqual(
            command,
            [
                "/usr/sbin/taskpolicy",
                "-b",
                "/usr/bin/nice",
                "-n",
                "10",
                "/usr/bin/say",
                "-o",
                "/tmp/reply.m4a",
                "--data-format=aac",
            ],
        )

    def test_unenrolled_hook_is_a_noop(self):
        self.assertTrue(HOOK_PATH.exists(), "phone hook implementation is missing")
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state-that-does-not-exist"
            env = os.environ.copy()
            env["CLAUDE_TTS_PHONE_STATE_DIR"] = str(state)
            env["PHONE_VOICE_TESTING"] = "1"
            result = subprocess.run(
                [sys.executable, str(HOOK_PATH)],
                input=json.dumps(
                    {"hook_event_name": "Stop", "last_assistant_message": "Do not write me."}
                ),
                text=True,
                capture_output=True,
                env=env,
                timeout=2,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")
            self.assertFalse(state.exists())


class ServerSecurityTest(unittest.TestCase):
    def setUp(self):
        self.server_module = load_module(SERVER_PATH, "phone_audio_server_test")
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.queue = self.state / "queue"
        self.queue.mkdir(parents=True)
        self.web = Path(self.tmp.name) / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("phone player", encoding="utf-8")
        (self.queue / "001-session.m4a").write_bytes(b"audio")
        (self.queue / "001-session.txt").write_text("hello", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def make_handler(self, path: str, *, cookie: str = ""):
        handler = self.server_module.Handler.__new__(self.server_module.Handler)
        handler.server = SimpleNamespace(
            state=self.state,
            queue=self.queue,
            web_root=self.web,
            token="test-token",
        )
        handler.path = path
        handler.command = "GET"
        handler.headers = {"Cookie": cookie} if cookie else {}
        responses = []
        handler._send_bytes = lambda status, body, content_type, extra=None: responses.append(
            (status, body, content_type, extra or {})
        )
        return handler, responses

    def test_server_binds_only_to_requested_address(self):
        server = self.server_module.create_server(
            "127.0.0.1", 8765, self.state, self.web, "token", bind_and_activate=False
        )
        self.addCleanup(server.server_close)
        self.assertEqual(server.server_address, ("127.0.0.1", 8765))
        with self.assertRaises(ValueError):
            self.server_module.create_server(
                "0.0.0.0", 8765, self.state, self.web, "token", bind_and_activate=False
            )

    def test_bad_token_is_rejected(self):
        self.assertFalse(self.server_module.token_is_valid("wrong", "test-token"))
        self.assertTrue(self.server_module.token_is_valid("test-token", "test-token"))

    def test_encoded_path_traversal_is_rejected(self):
        with self.assertRaises(FileNotFoundError):
            self.server_module.resolve_audio_path(self.queue, "../README.md")

    def test_authorized_queue_and_audio(self):
        (self.queue / ".002-session.partial.m4a").write_bytes(b"partial")
        payload = self.server_module.build_queue_payload(self.state, self.queue)
        self.assertEqual(len(payload["items"]), 1)
        self.assertEqual(payload["items"][0]["id"], "001-session")
        self.assertEqual(payload["items"][0]["url"], "/audio/001-session.m4a")
        audio = self.server_module.resolve_audio_path(self.queue, "001-session.m4a")
        self.assertEqual(audio.read_bytes(), b"audio")

    def test_initial_html_query_token_sets_strict_http_only_session_cookie(self):
        handler, responses = self.make_handler("/?token=test-token")
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        cookie = responses[0][3]["Set-Cookie"]
        self.assertIn("phone_voice_session=test-token", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertIn("Path=/", cookie)
        self.assertNotIn("Max-Age", cookie)

    def test_initial_query_token_replaces_a_stale_session_cookie(self):
        handler, responses = self.make_handler(
            "/?token=test-token", cookie="phone_voice_session=stale-token"
        )
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertIn("phone_voice_session=test-token", responses[0][3]["Set-Cookie"])

    def test_cookie_authenticates_api_and_query_token_is_only_for_initial_html(self):
        cookie = "phone_voice_session=test-token"
        handler, responses = self.make_handler("/api/queue", cookie=cookie)
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)

        handler, responses = self.make_handler("/api/queue?token=test-token")
        handler.do_GET()
        self.assertEqual(responses[0][0], 403)

    def test_audio_is_written_in_bounded_chunks(self):
        content = b"a" * 150_000
        audio = self.queue / "large.m4a"
        audio.write_bytes(content)
        handler = self.server_module.Handler.__new__(self.server_module.Handler)
        handler.command = "GET"
        handler.headers = {}
        handler.send_response = lambda _status: None
        handler.send_header = lambda _key, _value: None
        handler.end_headers = lambda: None

        class RecordingWriter:
            def __init__(self):
                self.chunks = []

            def write(self, chunk):
                self.chunks.append(bytes(chunk))

        handler.wfile = RecordingWriter()
        handler._serve_audio(audio)
        self.assertEqual(b"".join(handler.wfile.chunks), content)
        self.assertGreater(len(handler.wfile.chunks), 1)
        self.assertLessEqual(max(map(len, handler.wfile.chunks)), 64 * 1024)

    def test_played_log_is_created_with_mode_0600(self):
        body = json.dumps({"id": "001-session"}).encode("utf-8")
        handler = self.server_module.Handler.__new__(self.server_module.Handler)
        handler.server = SimpleNamespace(
            state=self.state,
            queue=self.queue,
            web_root=self.web,
            token="test-token",
        )
        handler.path = "/api/played"
        handler.command = "POST"
        handler.headers = {
            "Cookie": "phone_voice_session=test-token",
            "Content-Length": str(len(body)),
        }
        handler.rfile = io.BytesIO(body)
        responses = []
        handler._send_bytes = lambda status, response, content_type, extra=None: responses.append(
            (status, response, content_type, extra or {})
        )
        previous_umask = os.umask(0)
        try:
            handler.do_POST()
        finally:
            os.umask(previous_umask)
        played = self.state / "played.log"
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(played.read_text(encoding="utf-8"), "001-session\n")
        self.assertEqual(played.stat().st_mode & 0o777, 0o600)

    def test_post_length_and_json_object_are_bounded(self):
        self.assertEqual(self.server_module.validate_body_length("42"), 42)
        for value in (None, "-1", "4097", "nonsense"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.server_module.validate_body_length(value)
        with self.assertRaises(ValueError):
            self.server_module.decode_json_object(b"[]")


class DispatcherTest(unittest.TestCase):
    def test_non_phone_arguments_are_forwarded_byte_for_byte(self):
        self.assertTrue(DISPATCH_PATH.exists(), "dispatcher implementation is missing")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "args.json"
            vm = Path(tmp) / "vm-toggle"
            phone = Path(tmp) / "phone-voice"
            stub = "#!/usr/bin/env python3\nimport json, os, sys\nopen(os.environ['ARGS_OUT'], 'w').write(json.dumps(sys.argv[1:]))\n"
            vm.write_text(stub, encoding="utf-8")
            phone.write_text(stub, encoding="utf-8")
            vm.chmod(0o755)
            phone.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "ARGS_OUT": str(out),
                    "VM_TOGGLE_PATH": str(vm),
                    "PHONE_VOICE_PATH": str(phone),
                }
            )
            args = ["listen", "value with spaces", "", "--literal=*?[x]"]
            result = subprocess.run(
                ["bash", str(DISPATCH_PATH), *args], env=env, timeout=2, check=False
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8")), args)

    def test_phone_prefix_routes_only_remaining_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "args.json"
            stub = Path(tmp) / "phone-voice"
            stub.write_text(
                "#!/usr/bin/env python3\nimport json, os, sys\nopen(os.environ['ARGS_OUT'], 'w').write(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            stub.chmod(0o755)
            env = os.environ.copy()
            env.update({"ARGS_OUT": str(out), "PHONE_VOICE_PATH": str(stub)})
            result = subprocess.run(
                ["bash", str(DISPATCH_PATH), "phone", "speed", "1.25"],
                env=env,
                timeout=2,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8")), ["speed", "1.25"])


if __name__ == "__main__":
    unittest.main()
