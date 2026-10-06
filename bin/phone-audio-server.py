#!/usr/bin/env python3
"""Token-authenticated phone audio server bound to one explicit IPv4 address."""

from __future__ import annotations

import argparse
import hmac
from http.cookies import SimpleCookie
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import sys
from urllib.parse import parse_qs, unquote, urlsplit


ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
SESSION_COOKIE = "phone_voice_session"
AUDIO_CHUNK_SIZE = 64 * 1024


def token_is_valid(supplied: str, expected: str) -> bool:
    return bool(supplied) and hmac.compare_digest(supplied, expected)


def validate_body_length(raw: str | None) -> int:
    if raw is None:
        raise ValueError("Content-Length is required")
    length = int(raw)
    if not 0 <= length <= 4096:
        raise ValueError("Content-Length must be between 0 and 4096")
    return length


def decode_json_object(body: bytes) -> dict:
    payload = json.loads(body or b"{}")
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object")
    return payload


def resolve_audio_path(queue: Path, name: str) -> Path:
    queue = Path(queue).resolve()
    if not name.endswith(".m4a") or not ID_RE.fullmatch(name) or "/" in name or ".." in name:
        raise FileNotFoundError(name)
    audio = (queue / name).resolve()
    if audio.parent != queue or not audio.is_file():
        raise FileNotFoundError(name)
    return audio


def build_queue_payload(state: Path, queue: Path) -> dict:
    state = Path(state)
    queue = Path(queue)
    played_path = state / "played.log"
    played = set(played_path.read_text(encoding="utf-8").splitlines()) if played_path.exists() else set()
    items = []
    for audio in sorted(queue.glob("*.m4a"), key=lambda item: item.name):
        if audio.name.startswith("."):
            continue
        item_id = audio.stem
        if item_id in played:
            continue
        text_path = audio.with_suffix(".txt")
        text = text_path.read_text(encoding="utf-8", errors="replace") if text_path.exists() else ""
        items.append({"id": item_id, "text": text, "url": f"/audio/{audio.name}"})
    speed_path = state / "speed"
    try:
        speed = float(speed_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        speed = 1.0
    return {"items": items, "speed": speed}


class PhoneHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, state: Path, web_root: Path, token: str):
        self.state = state.resolve()
        self.queue = (state / "queue").resolve()
        self.web_root = web_root.resolve()
        self.token = token
        super().__init__(address, handler)


class Handler(BaseHTTPRequestHandler):
    server: PhoneHTTPServer

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("phone-audio: " + (fmt % args) + "\n")

    def _route(self):
        parsed = urlsplit(self.path)
        return unquote(parsed.path), parse_qs(parsed.query)

    def _cookie_token(self) -> str:
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except Exception:
            return ""
        morsel = cookie.get(SESSION_COOKIE)
        return morsel.value if morsel is not None else ""

    def _authorized(self, query, *, allow_query_token: bool = False) -> bool:
        if token_is_valid(self._cookie_token(), self.server.token):
            return True
        if allow_query_token:
            supplied = query.get("token", [""])[0]
            return token_is_valid(supplied, self.server.token)
        return False

    def _session_cookie(self) -> str:
        cookie = SimpleCookie()
        cookie[SESSION_COOKIE] = self.server.token
        cookie[SESSION_COOKIE]["path"] = "/"
        cookie[SESSION_COOKIE]["httponly"] = True
        cookie[SESSION_COOKIE]["samesite"] = "Strict"
        return cookie.output(header="").strip()

    def _send_bytes(self, status: int, body: bytes, content_type: str, extra=None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload) -> None:
        self._send_bytes(status, json.dumps(payload).encode("utf-8"), "application/json")

    def _forbid_if_unauthorized(self, query, *, allow_query_token: bool = False) -> bool:
        if self._authorized(query, allow_query_token=allow_query_token):
            return False
        self._json(HTTPStatus.FORBIDDEN, {"error": "invalid token"})
        return True

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path, query = self._route()
        if path in ("/", "/index.html"):
            had_cookie = token_is_valid(self._cookie_token(), self.server.token)
            if self._forbid_if_unauthorized(query, allow_query_token=True):
                return
            try:
                body = (self.server.web_root / "index.html").read_bytes()
            except OSError:
                self._json(HTTPStatus.NOT_FOUND, {"error": "player missing"})
                return
            headers = {} if had_cookie else {"Set-Cookie": self._session_cookie()}
            self._send_bytes(HTTPStatus.OK, body, "text/html; charset=utf-8", headers)
            return
        if self._forbid_if_unauthorized(query):
            return
        if path == "/api/queue":
            self._json(
                HTTPStatus.OK,
                build_queue_payload(self.server.state, self.server.queue),
            )
            return
        if path.startswith("/audio/"):
            name = path[len("/audio/") :]
            try:
                audio = resolve_audio_path(self.server.queue, name)
            except FileNotFoundError:
                self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            self._serve_audio(audio)
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def _serve_audio(self, audio: Path) -> None:
        size = audio.stat().st_size
        start, end = 0, size - 1
        status = HTTPStatus.OK
        range_value = self.headers.get("Range", "")
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_value)
        if match and size:
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), end)
            if start > end or start >= size:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = HTTPStatus.PARTIAL_CONTENT
        content_length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "bytes")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD" or not content_length:
            return
        with audio.open("rb") as handle:
            handle.seek(start)
            remaining = content_length
            while remaining:
                chunk = handle.read(min(AUDIO_CHUNK_SIZE, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def do_POST(self) -> None:
        path, query = self._route()
        if self._forbid_if_unauthorized(query):
            return
        try:
            length = validate_body_length(self.headers.get("Content-Length"))
            payload = decode_json_object(self.rfile.read(length))
        except (TypeError, ValueError, json.JSONDecodeError):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
            return
        if path == "/api/speed":
            try:
                speed = float(payload["speed"])
            except (KeyError, TypeError, ValueError):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "invalid speed"})
                return
            if not 0.5 <= speed <= 3.0:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "speed must be 0.5 to 3.0"})
                return
            target = self.server.state / "speed"
            target.write_text(f"{speed:g}\n", encoding="utf-8")
            target.chmod(0o600)
            self._json(HTTPStatus.OK, {"speed": speed})
            return
        if path == "/api/played":
            item_id = str(payload.get("id", ""))
            if not ID_RE.fullmatch(item_id):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "invalid id"})
                return
            played_path = self.server.state / "played.log"
            descriptor = os.open(played_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
                handle.write(item_id + "\n")
            self._json(HTTPStatus.OK, {"played": item_id})
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})


def create_server(
    bind_ip: str,
    port: int,
    state: Path,
    web_root: Path,
    token: str,
    bind_and_activate: bool = True,
) -> PhoneHTTPServer:
    address = ipaddress.ip_address(bind_ip)
    if not isinstance(address, ipaddress.IPv4Address) or address.is_unspecified:
        raise ValueError("an explicit IPv4 bind address is required")
    if not token:
        raise ValueError("a non-empty token is required")
    server = PhoneHTTPServer.__new__(PhoneHTTPServer)
    server.state = Path(state).resolve()
    server.queue = (Path(state) / "queue").resolve()
    server.web_root = Path(web_root).resolve()
    server.token = token
    ThreadingHTTPServer.__init__(server, (str(address), port), Handler, bind_and_activate)
    return server


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--web-root", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    args = parser.parse_args()
    token = args.token_file.read_text(encoding="utf-8").strip()
    server = create_server(args.bind, args.port, args.state, args.web_root, token)
    pid_path = args.state / "server.pid"
    pid_path.write_text(str(__import__("os").getpid()) + "\n", encoding="utf-8")

    def stop(_signum, _frame):
        threading = __import__("threading")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"http://{args.bind}:{server.server_address[1]}/?token={token}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        pid_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
