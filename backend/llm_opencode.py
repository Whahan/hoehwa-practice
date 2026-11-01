# -*- coding: utf-8 -*-
"""AI engine "opencode": OpenCode's own headless server (`opencode serve`) with the free DeepSeek V4.1 Flash model.

OpenCode Zen's free models answer only OpenCode itself, so the app talks to a local `opencode serve` child process
(started on first use on a free 127.0.0.1 port, with a random HTTP basic-auth password, tied to this process by a
job object and killed by PID at exit). OpenCode uses its own stored login. The person gives the app an API key once
("AI connect": connect(key) -> OpenCode's PUT /auth/opencode, OpenCode writes its auth.json); this module never reads
auth.json, never stores the key and never writes it to a log, an argument list, an environment variable or an error text.
Whether a login exists is read from the names `opencode auth list` prints (connected()).

Working dir %LOCALAPPDATA%/hoehwa-practice/opencode/work (outside the app's folder and any git repository, so
OpenCode's project scope never contains the app's files) holds an opencode.json with an agent "hoehwa": a short "language engine"
prompt, one step per request, and every tool that could change or reach outside the PC denied (edit, bash, web,
tasks, files outside the empty working dir, MCP servers). NOTE: denying ALL tools makes OpenCode Zen refuse the
free model ("free tier can only be used from within OpenCode"), so the harmless read-only tools (read/list/glob/grep
inside the empty working dir) stay available; the prompt tells the model not to use them and steps=1 stops any loop.

  call_json(cfg, messages, schema, temperature)            one-shot JSON answer (temporary session, deleted after)
  chat_json(cfg, conv_id, system, history, last, schema)   chat turn on one session per conversation (only the new
                                                           message is sent once the session has seen the rest)
Errors are llm_common.LlmError with .kind ("auth" for a refused/missing free model, "limit", "overload", "not_installed",
"not_connected", None). ERROR_CODES maps a kind to the HTTP "code" the server sends.
"""
import atexit
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time

import requests

import llm_common
import llm_fallback

BASE = os.path.dirname(os.path.abspath(__file__))


def _work_dir():
    root = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return os.path.join(root, "hoehwa-practice", "opencode", "work")


WORK = _work_dir()
LOG_DIR = os.path.join(BASE, "logs")
if os.environ.get("HOEHWA_TEST_HOOKS") == "1" and os.environ.get("HOEHWA_LOG_DIR"):   # tests only
    LOG_DIR = os.environ["HOEHWA_LOG_DIR"]
NO_WINDOW = 0x08000000
PROVIDER_ID = "opencode"
DEFAULT_MODEL = "deepseek-v4.1-flash-free"
LABEL = "DeepSeek V4.1 Flash (무료 · OpenCode)"
AGENT = "hoehwa"
AGENT_PROMPT = ("You are the language engine of a language-learning app for Korean learners. You are NOT a coding assistant. "
                "Never use tools. Answer only with what the instructions ask for, in the requested format.")
DENY = ["edit", "write", "patch", "multiedit", "bash", "webfetch", "websearch", "codesearch", "task", "todowrite",
        "external_directory", "skill", "lsp", "doom_loop"]
LOGIN_URL = "https://opencode.ai/auth"
MSG_NOT_CONNECTED = "AI가 아직 연결되지 않았어요. 설정에서 [AI 연결하기]를 눌러 주세요. (폰이면 PC의 회화 연습에서)"
MSG_NOT_INSTALLED = "AI 구성 요소가 없어요. [AI 연결하기]에서 받을 수 있어요."
MSG_AUTH = "OpenCode 로그인이 만료됐거나 키가 맞지 않아요. [AI 연결하기]로 다시 연결해 주세요."
# LlmError.kind -> the "code" of the HTTP answer (docs/onetouch_install_design.md 3.4.2)
ERROR_CODES = {"not_connected": "ai_not_connected", "not_installed": "ai_not_installed", "auth": "ai_auth",
               "limit": "ai_limit", "overload": "ai_overload"}
CONN_TTL = 20.0          # seconds a `opencode auth list` answer is trusted
CONN_FIRST_WAIT = 0.4    # the very first state() waits this long for the first answer (never longer: /health must not block)

_log = None
_state = {"proc": None, "port": None, "pw": None, "fail_t": 0.0, "job": None, "fail_msg": ""}
_lock = threading.Lock()
_http = requests.Session()
# This session only talks to the local `opencode serve` on 127.0.0.1 and carries the API key (PUT /auth): it must never use a
# proxy from HTTP(S)_PROXY / ALL_PROXY (the key would go to the proxy in plain text) nor read netrc / CA environment.
_http.trust_env = False


def init(log=None):
    global _log
    _log = log


def _info(msg, *a):
    if _log:
        _log.info(msg, *a)


def _warn(msg, *a):
    if _log:
        _log.warning(msg, *a)


def exe():
    """Path of opencode.exe or None. Order: (test hooks only) HOEHWA_OPENCODE_EXE -> the app's own copy
    backend/tools/opencode/opencode.exe -> the old npm install -> PATH."""
    if os.environ.get("HOEHWA_TEST_HOOKS") == "1" and os.environ.get("HOEHWA_OPENCODE_EXE"):
        p = os.environ["HOEHWA_OPENCODE_EXE"]
        return p if os.path.isfile(p) else None      # a test never falls through to a real OpenCode
    p = os.path.join(BASE, "tools", "opencode", "opencode.exe")
    if os.path.isfile(p):
        return p
    p = os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "opencode-ai", "bin", "opencode.exe")
    if os.path.isfile(p):
        return p
    return shutil.which("opencode.exe")


def installed():
    return exe() is not None


def available():
    return installed()


def model(cfg):
    return ((cfg.get("opencode") or {}).get("model") or DEFAULT_MODEL).strip()


# ---------------------------------------------------------------------------------------------- server
def _write_config():
    os.makedirs(WORK, exist_ok=True)
    perm = {k: "deny" for k in DENY}
    # MCP servers from the person's global OpenCode config must not be reachable from the app: disable them by name
    mcp = {}
    try:
        with open(os.path.join(os.path.expanduser("~"), ".config", "opencode", "opencode.json"), encoding="utf-8") as f:
            for name, e in (json.load(f).get("mcp") or {}).items():
                if isinstance(e, dict):
                    # placeholders only: never copy the person's url/command (it may carry a token) into the app's files
                    if e.get("type") == "remote":
                        mcp[name] = {"type": "remote", "url": "http://127.0.0.1:9/disabled", "enabled": False}
                    else:
                        mcp[name] = {"type": "local", "command": ["disabled"], "enabled": False}
                    perm[name + "_*"] = "deny"
    except Exception:
        pass
    cfg = {"$schema": "https://opencode.ai/config.json", "autoupdate": False, "share": "disabled",
           "permission": perm, "mcp": mcp,
           "agent": {AGENT: {"description": "Plain chat engine of the language-learning app (no editing, no shell, no web)",
                             "mode": "primary", "steps": 1, "prompt": AGENT_PROMPT, "permission": perm}}}
    with open(os.path.join(WORK, "opencode.json"), "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=1)


def _alive():
    p = _state["proc"]
    return p is not None and p.poll() is None


def _url(path):
    return "http://127.0.0.1:%d%s" % (_state["port"], path)


def _auth():
    return ("opencode", _state["pw"])


def start(wait=60.0):
    """Start `opencode serve` if needed. Returns True when it answers."""
    with _lock:
        if _alive():
            return True
        if _state["fail_t"] and time.time() - _state["fail_t"] < 60:
            return False
        e = exe()
        if not e:
            _state.update(fail_t=time.time(), fail_msg="OpenCode가 설치되어 있지 않아요")
            return False
        _write_config()
        _info("opencode exe: %s", e)
        _info("opencode work dir: %s", WORK)
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        pw = secrets.token_urlsafe(18)
        env = dict(os.environ, OPENCODE_SERVER_PASSWORD=pw)
        os.makedirs(LOG_DIR, exist_ok=True)
        out = open(os.path.join(LOG_DIR, "opencode.log"), "ab")
        t0 = time.time()
        try:
            proc = subprocess.Popen([e, "serve", "--port", str(port), "--hostname", "127.0.0.1"], cwd=WORK, env=env,
                                    stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        except OSError as ex:
            _warn("opencode: could not start: %s", ex)
            _state.update(fail_t=time.time(), fail_msg="OpenCode를 실행하지 못했어요")
            return False
        finally:
            out.close()
        try:
            from grammar import _kill_on_close_job
            job = _kill_on_close_job(proc.pid)
        except Exception:
            job = None
        _state.update(proc=proc, port=port, pw=pw, job=job)
        _info("opencode serve starting: pid %d port %d", proc.pid, port)
        while time.time() - t0 < wait:
            if proc.poll() is not None:
                _warn("opencode serve exited during start-up (code %s); see logs/opencode.log", proc.returncode)
                _state.update(proc=None, fail_t=time.time(), fail_msg="OpenCode 서버가 켜지지 않았어요")
                return False
            try:
                if _http.get(_url("/session"), auth=_auth(), timeout=1).status_code == 200:
                    _info("opencode serve ready in %.1fs", time.time() - t0)
                    return True
            except Exception:
                pass
            time.sleep(0.25)
        _stop_locked()
        _state.update(fail_t=time.time(), fail_msg="OpenCode 서버가 응답하지 않아요")
        return False


def _stop_locked():
    p = _state["proc"]
    _state["proc"] = None
    if p is None or p.poll() is not None:
        return
    try:  # by PID (and its child processes) only, never by image name
        subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10, creationflags=NO_WINDOW)
    except Exception:
        pass
    try:
        p.kill()
    except Exception:
        pass


def stop():
    with _lock:
        for k in list(_sessions):
            _sessions.pop(k, None)
        _stop_locked()


atexit.register(stop)


def prestart():
    if installed():
        refresh_async()
        threading.Thread(target=start, daemon=True, name="opencode-start").start()


def running():
    return _alive()


# ---------------------------------------------------------------------------------------------- login state
# Whether a login exists is read from `opencode auth list` (it prints the NAMES of the stored logins, never the keys).
# GET /provider is no help: it says connected:["opencode"] even without a login. auth.json is never opened here.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
_LOGIN_RE = re.compile(r"(?im)\bOpenCode(\s+Zen)?\s+(api|oauth|wellknown)\b")
_conn = {"v": None, "t": 0.0, "thread": None}
_conn_lock = threading.Lock()
_connect_lock = threading.Lock()


def _run_auth_list():
    """True / False, or None when the answer is unknown (no exe, error, time-out). Never logs the output."""
    e = exe()
    if not e:
        return None
    try:
        os.makedirs(WORK, exist_ok=True)
    except OSError:
        pass
    try:
        r = subprocess.run([e, "auth", "list"], cwd=WORK if os.path.isdir(WORK) else None, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=10, creationflags=NO_WINDOW)
    except subprocess.TimeoutExpired:
        _warn("opencode auth list: no answer within 10 s")
        return None
    except OSError as ex:
        _warn("opencode auth list: could not run (%s)", type(ex).__name__)
        return None
    out = _ANSI.sub("", (r.stdout or b"").decode("utf-8", "replace"))
    if _LOGIN_RE.search(out):
        return True
    return False if r.returncode == 0 else None


def _store(v):
    with _conn_lock:
        if v is None:      # unknown: keep the old value and ask again in 5 s
            _conn["t"] = time.time() - CONN_TTL + 5
        else:
            _conn["v"], _conn["t"] = v, time.time()
    return v


def _set_connected(v):
    with _conn_lock:
        _conn["v"], _conn["t"] = v, time.time()


def refresh_async():
    """Ask `opencode auth list` on a background thread (one at a time); connected() then sees the answer."""
    with _conn_lock:
        th = _conn["thread"]
        if th is not None and th.is_alive():
            return
        th = threading.Thread(target=lambda: _store(_run_auth_list()), daemon=True, name="opencode-auth-list")
        _conn["thread"] = th
        th.start()


def connected(force=False):
    """True / False = a login exists / does not; None = not known yet.
    force=False never blocks for long: it reads the cached answer (20 s) and refreshes in the background; only the very
    first call waits up to 0.4 s for the first answer. force=True runs `opencode auth list` now (up to 10 s)."""
    if not installed():
        return None
    if force:
        return _store(_run_auth_list())
    with _conn_lock:
        v, t = _conn["v"], _conn["t"]
    if v is not None and time.time() - t < CONN_TTL:
        return v
    refresh_async()
    if v is None:
        with _conn_lock:
            th = _conn["thread"]
        if th is not None:
            th.join(CONN_FIRST_WAIT)
        with _conn_lock:
            v = _conn["v"]
    return v


def state():
    """"ready" | "not_connected" | "not_installed". Never blocks (see connected()); an answer that is still unknown counts as
    "ready" so that a person who is connected never sees a false "connect AI" hint during the first moments."""
    if not installed():
        return "not_installed"
    c = connected()
    return "not_connected" if c is False else "ready"


def _ready_or_raise():
    """Before a call: no server start when there is nothing to talk to."""
    if not installed():
        raise llm_common.LlmError(MSG_NOT_INSTALLED, 503, "not_installed", "opencode.exe missing")
    c = connected()
    if c is not True:
        c = connected(force=True)     # the cache may be stale (the person may have logged in elsewhere): ask for real
    if c is False:
        raise llm_common.LlmError(MSG_NOT_CONNECTED, 503, "not_connected", "no OpenCode login")


# ---------------------------------------------------------------------------------------------- connect / disconnect
class _Secret(str):
    """A str whose repr, str() and format() never show the value (keeps the key out of tracebacks, logs and f-strings).
    The real text is still there for the code that must send it: json encoding and str.__str__(x) see the value."""
    def __repr__(self):
        return "<secret>"

    def __str__(self):
        return "<secret>"

    def __format__(self, spec):
        return "<secret>"


TEST_SCHEMA = {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}
TEST_MESSAGES = [{"role": "user", "content": 'Reply with the JSON object {"ok": true} and nothing else.'}]


def _scrub(e, key):
    """a copy of the LlmError without the key in any of its texts"""
    k = str.__str__(key)      # the real value (str(key) is masked)

    def clean(t):
        return (t or "").replace(k, "***") if k else (t or "")
    return llm_common.LlmError(clean(e.msg), e.status, e.kind, clean(e.raw))


def _drop_sessions():
    with _lock:
        old = list(_sessions.values())
        _sessions.clear()
    for s in old:
        _retire(s)


def _dispose():
    """OpenCode reads its login again only after this."""
    try:
        r = _http.post(_url("/instance/dispose"), auth=_auth(), timeout=30)
    except requests.exceptions.RequestException as ex:
        raise llm_common.LlmError("OpenCode가 응답하지 않아요. 다시 시도해 주세요.", 502, None, type(ex).__name__) from None
    if r.status_code != 200:
        _warn("opencode: dispose answered HTTP %d", r.status_code)


def connect(key, cfg=None):
    """Store the API key in OpenCode (PUT /auth/opencode) and make one test call.
    Returns {"tested": bool, "seconds": float}. LlmError(kind="auth") when the test call says the key is refused,
    kind="not_installed" without opencode.exe, other kinds for a server that cannot be reached.
    Nothing here keeps the key: it goes to 127.0.0.1 in the request body and is forgotten; no log line, argument, environment
    variable or error text contains it (a LlmError text is scrubbed of it anyway)."""
    if not isinstance(key, str) or not key:
        raise llm_common.LlmError("키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요.", 400, "bad_key")
    key = _Secret(key)
    cfg = cfg if isinstance(cfg, dict) else {}
    with _connect_lock:
        if not installed():
            raise llm_common.LlmError(MSG_NOT_INSTALLED, 503, "not_installed", "opencode.exe missing")
        try:
            _state["fail_t"] = 0.0     # the person asked for it: no waiting after an earlier failed start
            if not start():
                raise llm_common.LlmError((_state["fail_msg"] or "OpenCode를 켜지 못했어요") + ". 잠시 뒤에 다시 시도해 주세요.", 503, None,
                                          _state["fail_msg"] or "opencode did not start")
            try:
                r = _http.put(_url("/auth/" + PROVIDER_ID), auth=_auth(), json={"type": "api", "key": key}, timeout=15)
            except requests.exceptions.RequestException as ex:
                raise llm_common.LlmError("OpenCode에 키를 전달하지 못했어요. 다시 시도해 주세요.", 502, None, type(ex).__name__) from None
            code = r.status_code
            r = None
            if code in (400, 422):
                raise llm_common.LlmError(MSG_AUTH, 503, "auth", "PUT /auth HTTP %d" % code)
            if code != 200:
                raise llm_common.LlmError("OpenCode가 키를 받지 않았어요 (HTTP %d)." % code, 502, None, "PUT /auth HTTP %d" % code)
            _dispose()
            _drop_sessions()
            _set_connected(True)       # the login is stored now, whatever the test call says
            t0 = time.time()
            tested = True
            try:
                _call_json(cfg, TEST_MESSAGES, TEST_SCHEMA, 0, timeout=60)
            except llm_common.LlmError as e:
                if e.kind == "auth":
                    raise llm_common.LlmError(MSG_AUTH, 503, "auth", e.raw) from None
                if e.kind in ("limit", "overload") or llm_common.is_format_error(e) or e.status == 504:
                    tested = False     # the key was stored; the test could not decide
                else:
                    raise
            return {"tested": tested, "seconds": round(time.time() - t0, 2)}
        except llm_common.LlmError as e:
            raise _scrub(e, key) from None
        except Exception as ex:
            raise llm_common.LlmError("AI 연결에 실패했어요. 다시 시도해 주세요.", 502, None, type(ex).__name__) from None


def disconnect():
    """Delete OpenCode's stored login (DELETE /auth/opencode). It is OpenCode's global login: the terminal's OpenCode is logged out too."""
    with _connect_lock:
        if not installed():
            _set_connected(None)
            return
        _state["fail_t"] = 0.0
        if not start():
            raise llm_common.LlmError((_state["fail_msg"] or "OpenCode를 켜지 못했어요") + ". 잠시 뒤에 다시 시도해 주세요.", 503, None,
                                      _state["fail_msg"] or "opencode did not start")
        try:
            r = _http.delete(_url("/auth/" + PROVIDER_ID), auth=_auth(), timeout=15)
        except requests.exceptions.RequestException as ex:
            raise llm_common.LlmError("OpenCode가 응답하지 않아요. 다시 시도해 주세요.", 502, None, type(ex).__name__) from None
        if r.status_code != 200:
            raise llm_common.LlmError("OpenCode 로그인을 지우지 못했어요 (HTTP %d)." % r.status_code, 502, None, "DELETE /auth HTTP %d" % r.status_code)
        try:
            _dispose()
        except llm_common.LlmError:
            pass
        _drop_sessions()
        _set_connected(False)


def reset_state():
    """forget the cached login answer (after an install, or in tests)"""
    with _conn_lock:
        _conn["v"], _conn["t"] = None, 0.0


def after_install():
    """opencode.exe has just been installed: forget an earlier failed start and the cached login answer, ask again."""
    _state["fail_t"] = 0.0
    _state["fail_msg"] = ""
    reset_state()
    refresh_async()


# ---------------------------------------------------------------------------------------------- calls
def _need_server():
    """before every call: something to talk to (not_installed / not_connected end it here, no server is started), then the server"""
    _ready_or_raise()
    if not start():
        raise llm_common.LlmError((_state["fail_msg"] or "OpenCode를 쓸 수 없어요") + ". 잠시 뒤에 다시 시도해 주세요.",
                               503, None, _state["fail_msg"] or "opencode unavailable")


def _new_session(title):
    r = _http.post(_url("/session"), auth=_auth(), json={"title": title}, timeout=15)
    if r.status_code != 200:
        raise llm_common.LlmError("OpenCode 대화를 만들지 못했어요.", 502, None, "HTTP %d %s" % (r.status_code, r.text[:200]))
    return r.json()["id"]


def _delete_session(sid):
    try:
        _http.delete(_url("/session/%s" % sid), auth=_auth(), timeout=5)
    except Exception:
        pass


def _error(err):
    data = (err or {}).get("data") or {}
    msg = str(data.get("message") or err.get("name") or "")
    st = data.get("statusCode")
    raw = "HTTP %s %s %s" % (st, err.get("name", ""), msg)
    low = msg.lower()
    if "free tier" in low or "freetier" in raw.lower():
        return llm_common.LlmError("무료 DeepSeek 모델을 지금 쓸 수 없어요 (OpenCode가 거절했어요).", 503, "auth", raw)
    kind = llm_fallback.classify(raw)
    if st in (401, 403) and not kind:
        kind = "auth"
    if st == 429:
        kind = "limit"
    if st in (500, 502, 503, 504, 529) and not kind:
        kind = "overload"
    if "model" in low and ("not found" in low or "not exist" in low or "unknown" in low):
        return llm_common.LlmError("OpenCode에서 AI 모델을 찾을 수 없어요. 무료 모델이 바뀌었을 수 있어요.", 503, "auth", raw)
    text = {"auth": "OpenCode 로그인 또는 모델 사용 권한을 확인해 주세요.", "limit": "무료 모델의 사용 한도에 도달했어요.",
            "overload": "OpenCode 서버가 바빠요. 잠시 뒤에 다시 시도해 주세요."}.get(kind, "OpenCode 호출에 실패했어요. 잠시 뒤에 다시 시도해 주세요.")
    return llm_common.LlmError(text, 503 if kind == "auth" else 502, kind, raw)


def _send(cfg, sid, text, system, timeout):
    body = {"agent": AGENT, "model": {"providerID": PROVIDER_ID, "modelID": model(cfg)},
            "system": system, "parts": [{"type": "text", "text": text}]}
    variant = (cfg.get("opencode") or {}).get("variant", "low")  # reasoning effort: "low" keeps a chat turn at ~2-3 s
    if variant:
        body["variant"] = variant
    t0 = time.time()
    try:
        r = _http.post(_url("/session/%s/message" % sid), auth=_auth(), json=body, timeout=timeout)
    except requests.exceptions.Timeout:
        raise llm_common.LlmError("AI 응답이 너무 오래 걸려요. 잠시 뒤에 다시 시도해 주세요.", 504)
    except requests.exceptions.RequestException as e:
        raise llm_common.LlmError("OpenCode 연결이 끊겼어요. 다시 시도해 주세요.", 502, None, type(e).__name__)
    if r.status_code != 200:
        raise llm_common.LlmError("OpenCode 호출에 실패했어요 (HTTP %d)." % r.status_code, 502, None, r.text[:300])
    d = r.json()
    info = d.get("info") or {}
    if info.get("error"):
        raise _error(info["error"])
    out = "".join(p.get("text", "") for p in d.get("parts", []) if p.get("type") == "text")
    stats = {"s": round(time.time() - t0, 2), "in": (info.get("tokens") or {}).get("input"),
             "out": (info.get("tokens") or {}).get("output"), "tools": [p.get("tool") for p in d.get("parts", []) if p.get("type") == "tool"]}
    if not out.strip():
        raise llm_common.LlmError("AI가 대답을 만들지 못했어요. 다시 시도해 주세요.", 502, None, "empty text %s" % stats)
    return out, stats


def _schema_instr(schema):
    return ("\n\nReply with ONLY one JSON object (no code fences, no extra text, no tools) that matches this JSON schema:\n"
            + json.dumps(schema, ensure_ascii=False))


def call_json(cfg, messages, schema, temperature=0.7, timeout=180):
    """One-shot JSON answer on a temporary session. Returns (data, seconds, stats)."""
    if llm_common.SIMULATE_LIMIT:
        raise llm_common.LlmError("무료 모델의 사용 한도에 도달했어요.", 502, llm_fallback.classify(llm_common.SIMULATE_LIMIT), llm_common.SIMULATE_LIMIT)
    return _call_json(cfg, messages, schema, temperature, timeout)


def _call_json(cfg, messages, schema, temperature=0.7, timeout=180):
    _need_server()
    system, prompt = llm_common.split(messages)
    t0 = time.time()
    sid = _new_session("hoehwa task")
    try:
        text, stats = _send(cfg, sid, prompt, (system or "") + _schema_instr(schema), timeout)
    finally:
        _delete_session(sid)
    try:
        return llm_common.extract_json(text), time.time() - t0, stats
    except Exception:
        raise llm_common.LlmError("AI가 올바른 형식으로 답하지 못했어요. 다시 시도해 주세요.", 502, None, text[:300])


# one OpenCode session per conversation, so only the newest learner message is sent.
# A session is only valid while it holds EXACTLY the conversation the app shows: `seen` = how many history messages
# (incl. the reply it gave) the session knows, -1 = no longer trustworthy (a failed / unreadable / discarded answer is in
# it) -> the next turn starts a new session from the app's history. Every use of a session (create, send, delete) is under
# its own lock, so a request never races a delete or a second create for the same conversation.
_sessions = {}
MAX_SESSIONS = 4
IDLE_SECONDS = 20 * 60


class _Sess:
    def __init__(self):
        self.sid = None
        self.seen = -1
        self.last_used = time.time()
        self.lock = threading.Lock()
        self.dead = False       # removed from _sessions: a thread that waited for the lock must look it up again


def _session_key(conv_id, system):
    return (conv_id or "") + "|" + hashlib.sha1(system.encode("utf-8")).hexdigest()[:12]


def _retire(sess):
    """Delete the OpenCode session of a removed _Sess - after any request that is using it has finished."""
    sess.dead = True

    def run():
        with sess.lock:
            if sess.sid:
                _delete_session(sess.sid)
                sess.sid = None
    if sess.lock.acquire(blocking=False):
        try:
            if sess.sid:
                _delete_session(sess.sid)
                sess.sid = None
        finally:
            sess.lock.release()
    else:
        threading.Thread(target=run, daemon=True, name="opencode-retire").start()


def invalidate(conv_id, system):
    """The app did not use the answer chat_json returned (it was rejected): the session now holds a reply the user never
    saw, so the next turn must start a new session."""
    with _lock:
        sess = _sessions.get(_session_key(conv_id, system))
    if sess is not None:
        sess.seen = -1


def chat_json(cfg, conv_id, system, history, last_note, schema, timeout=120,
              start_note="(The conversation starts now. Give your opening line.)"):
    """history: [{"role": "ai"|"me", "text"}] as the app shows it. Returns (data, seconds, stats)."""
    if llm_common.SIMULATE_LIMIT:
        raise llm_common.LlmError("무료 모델의 사용 한도에 도달했어요.", 502, llm_fallback.classify(llm_common.SIMULATE_LIMIT), llm_common.SIMULATE_LIMIT)
    _need_server()
    t0 = time.time()
    if not conv_id:   # no conversation id: nothing to continue -> a throw-away session
        sid = _new_session("hoehwa chat")
        try:
            text, stats = _send(cfg, sid, _turn_prompt(history, last_note, start_note, True), system + _schema_instr(schema), timeout)
        finally:
            _delete_session(sid)
        stats["fresh"] = True
        return _parse(text), time.time() - t0, stats
    key = _session_key(conv_id, system)
    for _ in range(5):
        stale = []
        with _lock:
            now = time.time()
            for k, s in list(_sessions.items()):
                if k != key and now - s.last_used > IDLE_SECONDS:
                    stale.append(_sessions.pop(k))
            sess = _sessions.get(key)
            if sess is None:
                while len(_sessions) >= MAX_SESSIONS:
                    oldest = min(_sessions, key=lambda k: _sessions[k].last_used)
                    stale.append(_sessions.pop(oldest))
                sess = _sessions[key] = _Sess()
        for s in stale:
            _retire(s)
        with sess.lock:
            if sess.dead:   # evicted while this request waited: look the conversation up again
                continue
            sess.last_used = time.time()
            fresh = sess.sid is None or sess.seen != max(0, len(history) - 1)
            try:
                if fresh:
                    if sess.sid:
                        _delete_session(sess.sid)
                        sess.sid = None
                    sess.seen = -1
                    sess.sid = _new_session("hoehwa chat")
                text, stats = _send(cfg, sess.sid, _turn_prompt(history, last_note, start_note, fresh),
                                    system + _schema_instr(schema), timeout)
                data = _parse(text)   # raises if unreadable
            except BaseException:
                sess.seen = -1       # the session may hold this message / a junk answer: start over next time
                raise
            sess.seen = len(history) + 1   # only a readable answer moves the session forward
        stats["fresh"] = fresh
        return data, time.time() - t0, stats
    raise llm_common.LlmError("OpenCode 대화를 준비하지 못했어요. 다시 시도해 주세요.", 502)


def _parse(text):
    try:
        return llm_common.extract_json(text)
    except Exception:
        raise llm_common.LlmError("AI가 올바른 형식으로 답하지 못했어요. 다시 시도해 주세요.", 502, None, text[:300])


def _turn_prompt(history, last_note, start_note, fresh):
    if not history:
        return start_note
    note = ("\n\n" + last_note) if last_note else ""
    if fresh and len(history) > 1:
        lines = ["(Conversation so far - you are the partner:)"]
        for h in history[:-1]:
            lines.append(("Partner (you): " if h["role"] == "ai" else "Learner: ") + h["text"])
        lines.append("\nLearner's new message: " + history[-1]["text"] + note)
        return "\n".join(lines)
    if history[-1]["role"] == "ai":  # the app asks the partner to continue
        return "(Continue the conversation naturally.)" + note
    return history[-1]["text"] + note
