# -*- coding: utf-8 -*-
"""AI engine "opencode": OpenCode's own headless server (`opencode serve`) with the free DeepSeek V4.1 Flash model.

OpenCode Zen's free models answer only OpenCode itself, so the app talks to a local `opencode serve` child process
(started on first use on a free 127.0.0.1 port, with a random HTTP basic-auth password, tied to this process by a
job object and killed by PID at exit). OpenCode uses the login the person made with `opencode auth login`; this
module never reads or handles that key.

Working dir %LOCALAPPDATA%/hoehwa-practice/opencode/work (outside the app's folder and any git repository, so
OpenCode's project scope never contains the app's files) holds an opencode.json with an agent "hoehwa": a short "language engine"
prompt, one step per request, and every tool that could change or reach outside the PC denied (edit, bash, web,
tasks, files outside the empty working dir, MCP servers). NOTE: denying ALL tools makes OpenCode Zen refuse the
free model ("free tier can only be used from within OpenCode"), so the harmless read-only tools (read/list/glob/grep
inside the empty working dir) stay available; the prompt tells the model not to use them and steps=1 stops any loop.

  call_json(cfg, messages, schema, temperature)            one-shot JSON answer (temporary session, deleted after)
  chat_json(cfg, conv_id, system, history, last, schema)   chat turn on one session per conversation (only the new
                                                           message is sent once the session has seen the rest)
Errors are llm_common.LlmError with .kind ("auth" for a refused/missing free model, "limit", "overload", None).
"""
import atexit
import hashlib
import json
import os
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
NO_WINDOW = 0x08000000
PROVIDER_ID = "opencode"
DEFAULT_MODEL = "deepseek-v4.1-flash-free"
LABEL = "DeepSeek V4.1 Flash (무료 · OpenCode)"
AGENT = "hoehwa"
AGENT_PROMPT = ("You are the language engine of a language-learning app for Korean learners. You are NOT a coding assistant. "
                "Never use tools. Answer only with what the instructions ask for, in the requested format.")
DENY = ["edit", "write", "patch", "multiedit", "bash", "webfetch", "websearch", "codesearch", "task", "todowrite",
        "external_directory", "skill", "lsp", "doom_loop"]

_log = None
_state = {"proc": None, "port": None, "pw": None, "fail_t": 0.0, "job": None, "fail_msg": ""}
_lock = threading.Lock()
_http = requests.Session()


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
    p = os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "opencode-ai", "bin", "opencode.exe")
    if os.path.isfile(p):
        return p
    return shutil.which("opencode.exe")


def available():
    return exe() is not None


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
    if available():
        threading.Thread(target=start, daemon=True, name="opencode-start").start()


def running():
    return _alive()


# ---------------------------------------------------------------------------------------------- calls
def _need_server():
    if not start():
        raise llm_common.LlmError((_state["fail_msg"] or "OpenCode를 쓸 수 없어요") + ". 설정에서 다른 AI 엔진을 고를 수 있어요.",
                               503, "auth", _state["fail_msg"] or "opencode unavailable")


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
