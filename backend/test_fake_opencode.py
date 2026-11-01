# -*- coding: utf-8 -*-
"""FAKE `opencode` for tests (never the real one; no network, no real login, no real key). Contract: docs/onetouch_install_design.md 3.4.7.

  python test_fake_opencode.py serve --port N --hostname 127.0.0.1     (what the backend starts; needs OPENCODE_SERVER_PASSWORD)
  python test_fake_opencode.py auth list                               (prints the logins it knows, like `opencode auth list`)
  python test_fake_opencode.py --version

State lives in the folder named by HOEHWA_FAKE_OC_STATE (required; a test gives it a scratch folder):
  fake_login.json    {"sha256": ...}   the "stored login" (only the SHA-256 of the key it received, never the key)
  received.json      [{"sha256": ...}] one entry per PUT /auth/opencode
  requests.log       "METHOD path status" per request (no bodies, no headers)
  proc_dump.json     SHA-256 of every argument and every environment value of the serve process (so a test can prove that the
                     key was NOT passed on the command line or in the environment, without this file holding any secret)
  control.json       written by the test: {"test_call": "ok|401|429|529|model_not_found|echo_key", "auth_list_delay": 0,
                     "put_status": 200, "message_delay": 0}

Behaviour that mirrors the real OpenCode (measured, see the design 2.2): PUT /auth/opencode stores the key without checking it;
the model list / calls see it only after POST /instance/dispose; GET /session answers 200 once the server is up; every request
needs HTTP Basic auth with the password from OPENCODE_SERVER_PASSWORD; a message call needs a login, else "model not found".
test_call=echo_key makes the error answer contain the key it received (held in memory only): the only way to prove that the
backend scrubs a key out of an upstream error text.
"""
import base64
import hashlib
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get("HOEHWA_FAKE_OC_STATE") or ""


def _p(name):
    return os.path.join(STATE, name)


def _read(name, default):
    try:
        with open(_p(name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write(name, obj):
    tmp = _p(name) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, _p(name))


def _sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _control():
    return _read("control.json", {})


def cmd_auth_list():
    time.sleep(float(_control().get("auth_list_delay", 0) or 0))
    login = _read("fake_login.json", None)
    esc = "\x1b"
    print("%s[0m┌  Credentials ~/fake/state" % esc)
    print("│")
    if login:
        print("●  %s[1mOpenCode%s[0m %s[90mapi%s[0m" % (esc, esc, esc, esc))
        print("│")
        print("└  1 credentials")
    else:
        print("└  0 credentials")
    return 0


class Server:
    def __init__(self):
        self.pw = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
        self.lock = threading.Lock()
        self.active = _read("fake_login.json", None)       # what the "running instance" knows (changes on dispose)
        self.key_in_memory = ""                              # only for test_call=echo_key
        self.sessions = set()
        self.n = 0


SRV = None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _log(self, status):
        try:
            with open(_p("requests.log"), "a", encoding="utf-8") as f:
                f.write("%s %s %d\n" % (self.command, self.path.split("?")[0], status))
        except OSError:
            pass

    def _send(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(status)

    def _authorized(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(h[6:]).decode("utf-8").partition(":")
        except Exception:
            return False
        return pw == SRV.pw and bool(SRV.pw)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return None

    def _route(self):
        if not self._authorized():
            return self._send(401, {"error": "unauthorized"})
        path = self.path.split("?")[0]
        m = self.command
        if m == "GET" and path == "/session":
            return self._send(200, [])
        if m == "POST" and path == "/session":
            self._body()
            with SRV.lock:
                SRV.n += 1
                sid = "ses_fake%d" % SRV.n
                SRV.sessions.add(sid)
            return self._send(200, {"id": sid})
        mm = re.match(r"^/session/([A-Za-z0-9_]+)$", path)
        if mm and m == "DELETE":
            with SRV.lock:
                SRV.sessions.discard(mm.group(1))
            return self._send(200, True)
        mm = re.match(r"^/session/([A-Za-z0-9_]+)/message$", path)
        if mm and m == "POST":
            return self._message()
        if m == "PUT" and path == "/auth/opencode":
            body = self._body()
            if not isinstance(body, dict) or body.get("type") != "api" or not isinstance(body.get("key"), str):
                return self._send(400, {"error": "bad body"})
            ctl = _control()
            st = int(ctl.get("put_status", 200) or 200)
            if st != 200:
                return self._send(st, {"error": "refused"})
            key = body["key"]
            h = _sha(key)
            rec = _read("received.json", [])
            rec.append({"sha256": h})
            _write("received.json", rec)
            _write("fake_login.json", {"sha256": h})
            SRV.key_in_memory = key
            return self._send(200, True)
        if m == "DELETE" and path == "/auth/opencode":
            try:
                os.remove(_p("fake_login.json"))
            except OSError:
                pass
            return self._send(200, True)
        if m == "POST" and path == "/instance/dispose":
            with SRV.lock:
                SRV.active = _read("fake_login.json", None)
            return self._send(200, True)
        return self._send(404, {"error": "not found"})

    def _message(self):
        self._body()
        ctl = _control()
        time.sleep(float(ctl.get("message_delay", 0) or 0))
        mode = ctl.get("test_call", "ok")
        with SRV.lock:
            logged_in = SRV.active is not None
        if not logged_in:
            err = {"name": "ProviderModelNotFoundError", "data": {"message": "Model not found: opencode/deepseek-v4.1-flash-free"}}
        elif mode == "401":
            err = {"name": "APIError", "data": {"message": "Unauthorized: invalid api key", "statusCode": 401}}
        elif mode == "429":
            err = {"name": "APIError", "data": {"message": "Rate limit reached, retry in 600 seconds", "statusCode": 429}}
        elif mode == "529":
            err = {"name": "APIError", "data": {"message": "Overloaded", "statusCode": 529}}
        elif mode == "model_not_found":
            err = {"name": "ProviderModelNotFoundError", "data": {"message": "Model not found: opencode/deepseek-v4.1-flash-free"}}
        elif mode == "echo_key":
            err = {"name": "APIError", "data": {"message": "Unauthorized, bad credential %s" % SRV.key_in_memory, "statusCode": 401}}
        else:
            err = None
        if err:
            return self._send(200, {"info": {"error": err}, "parts": []})
        return self._send(200, {"info": {"tokens": {"input": 5, "output": 5}},
                                "parts": [{"type": "text", "text": json.dumps({"ok": True, "reply": "fake answer"})}]})

    do_GET = do_POST = do_PUT = do_DELETE = _route


def cmd_serve(argv):
    global SRV
    port, host = 0, "127.0.0.1"
    for i, a in enumerate(argv):
        if a == "--port":
            port = int(argv[i + 1])
        if a == "--hostname":
            host = argv[i + 1]
    SRV = Server()
    _write("proc_dump.json", {"argv": [_sha(a) for a in sys.argv], "env": [_sha(v) for v in os.environ.values()], "pid": os.getpid()})
    httpd = ThreadingHTTPServer((host, port), H)
    httpd.daemon_threads = True
    print("opencode server listening on http://%s:%d" % (host, port), flush=True)
    httpd.serve_forever()
    return 0


def main(argv):
    if not STATE:
        print("HOEHWA_FAKE_OC_STATE is not set", file=sys.stderr)
        return 2
    os.makedirs(STATE, exist_ok=True)
    if argv[:1] == ["--version"]:
        print("1.19.0-fake")
        return 0
    if argv[:2] == ["auth", "list"]:
        return cmd_auth_list()
    if argv[:1] == ["serve"]:
        return cmd_serve(argv[1:])
    print("fake opencode: unknown command", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
