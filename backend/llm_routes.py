# -*- coding: utf-8 -*-
"""HTTP endpoints of "AI connect" (contract: docs/onetouch_install_design.md 3.4). server.py injects its helpers with
init(CFG, log, ApiError, local_only, fallback_status, save_config) and mounts `router`.

  POST /llm/connect       {"key": "..."}  store the person's OpenCode API key in OpenCode and test it   (this PC only)
  POST /llm/disconnect                    delete OpenCode's stored login                                (this PC only)
  POST /llm/install                       download opencode.exe in the background (vendor/install_tools.py)
  GET  /llm/install                       {"state": idle|running|done|error, "pct": 0-100, "error": ""}
  POST /llm/notice/ack                    the person saw the "Ollama was removed" notice

Every endpoint is for this PC only: lan._local_only (the phone listener, loopback address, Host / Origin, JSON content type)
and none of these paths is in lan.ALLOW, so a paired phone is refused twice.

SECRET RULES (3.5): the key lives only in the local variable `key` of connect_endpoint, is passed on to llm_opencode.connect()
and nowhere else. No log line, no answer body, no exception text in this file contains it. log calls here must never take `key`.
Errors are returned as {"error": <Korean>, "code": <code>} built here, so they do not depend on the server's ApiError.
"""
import atexit
import json
import os
import subprocess
import sys
import threading
import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import llm_common
import llm_config
import llm_fallback
import llm_opencode

H = {}          # injected by server.py: CFG, log, ApiError (unused: answers are built here), local_only, fallback_status, save_config
router = APIRouter()

BASE = os.path.dirname(os.path.abspath(__file__))
NO_WINDOW = 0x08000000
KEY_MIN, KEY_MAX = 16, 256
MAX_BODY = 2048
MSG_BAD_KEY = "키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요."
MSG_NO_TOOLS = "설치 구성 요소 정보가 없어요"


def init(CFG=None, log=None, ApiError=None, local_only=None, fallback_status=None, save_config=None):
    H.update(CFG=CFG if CFG is not None else {}, log=log, ApiError=ApiError, local_only=local_only,
             fallback_status=fallback_status, save_config=save_config)


def _log():
    import logging
    return H.get("log") or logging.getLogger("backend")


def _guard(request):
    f = H.get("local_only")
    if f is None:
        import lan
        f = lan._local_only
    return f(request)


def _err(status, code, msg):
    return JSONResponse({"error": msg, "code": code}, status_code=status)


def clean_key(value):
    """The key as typed (trailing / leading white space removed) or None when it does not look like a key.
    No prefix is required (the valid format is not known): 16-256 printable ASCII characters, no white space inside."""
    if not isinstance(value, str):
        return None
    k = value.strip()
    if not (KEY_MIN <= len(k) <= KEY_MAX):
        return None
    if any(not (0x21 <= ord(c) <= 0x7E) for c in k):
        return None
    return k


async def _read_key(request):
    raw = await request.body()
    if len(raw) > MAX_BODY:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return clean_key(data.get("key"))


def _fail(e, key=""):
    """JSONResponse for an LlmError (never contains the key)"""
    kind = getattr(e, "kind", None)
    msg = getattr(e, "msg", "") or str(e)
    if key:
        msg = msg.replace(key, "***")
    if kind == "not_installed":
        return _err(503, "ai_not_installed", llm_opencode.MSG_NOT_INSTALLED)
    if kind == "auth":
        return _err(503, "ai_auth", llm_opencode.MSG_AUTH)
    if kind == "bad_key":
        return _err(400, "bad_key_format", MSG_BAD_KEY)
    status = e.status if getattr(e, "status", 0) in (502, 503, 504) else 502
    return _err(status, "ai_unavailable", msg)


# ----------------------------------------------------------------------------------------------
# connect / disconnect
# ----------------------------------------------------------------------------------------------
@router.post("/llm/connect")
async def connect_endpoint(request: Request):
    blocked = _guard(request)
    if blocked is not None:
        return blocked
    key = await _read_key(request)
    if key is None:
        return _err(400, "bad_key_format", MSG_BAD_KEY)
    t0 = time.time()
    try:
        res = await run_in_threadpool(llm_opencode.connect, key, H.get("CFG"))
    except llm_common.LlmError as e:
        _log().warning("llm/connect failed: kind=%s status=%s %.1fs", e.kind, e.status, time.time() - t0)
        return _fail(e, key)
    except Exception as ex:
        _log().warning("llm/connect failed: %s", type(ex).__name__)
        return _err(502, "ai_unavailable", "AI 연결에 실패했어요. 다시 시도해 주세요.")
    llm_fallback.clear()      # a "login problem" notice of an earlier call is outdated now
    _log().info("llm/connect ok: tested=%s %.1fs", res.get("tested"), time.time() - t0)
    if res.get("tested"):
        return {"ok": True, "state": "ready", "tested": True, "seconds": res.get("seconds", 0.0)}
    return {"ok": True, "state": "ready", "tested": False, "note": "한도 또는 서버 사정으로 시험은 건너뛰었어요."}


@router.post("/llm/disconnect")
async def disconnect_endpoint(request: Request):
    blocked = _guard(request)
    if blocked is not None:
        return blocked
    try:
        await run_in_threadpool(llm_opencode.disconnect)
    except llm_common.LlmError as e:
        _log().warning("llm/disconnect failed: kind=%s status=%s", e.kind, e.status)
        return _fail(e)
    except Exception as ex:
        _log().warning("llm/disconnect failed: %s", type(ex).__name__)
        return _err(502, "ai_unavailable", "연결을 해제하지 못했어요. 다시 시도해 주세요.")
    llm_fallback.clear()
    _log().info("llm/disconnect ok")
    return {"ok": True, "state": "not_connected"}


@router.post("/llm/notice/ack")
async def notice_ack_endpoint(request: Request):
    blocked = _guard(request)
    if blocked is not None:
        return blocked
    cfg = H.get("CFG")
    if isinstance(cfg, dict) and llm_config.ack(cfg):
        save = H.get("save_config")
        if save:
            try:
                save(cfg)
            except Exception as ex:
                _log().warning("llm/notice/ack: could not save config (%s)", type(ex).__name__)
    return {"ok": True}


# ----------------------------------------------------------------------------------------------
# install opencode.exe (vendor/install_tools.py, only for installs that do not have it yet)
# ----------------------------------------------------------------------------------------------
_inst = {"state": "idle", "pct": 0, "error": "", "proc": None}
_inst_lock = threading.Lock()


def _hooks():
    return os.environ.get("HOEHWA_TEST_HOOKS") == "1"


def _paths():
    """(install_tools.py, tools.lock.json, app root); the first two may not exist (a development PC)"""
    root = os.path.dirname(BASE)
    script = os.path.join(root, "vendor", "install_tools.py")
    lock = os.path.join(root, "vendor", "tools.lock.json")
    if _hooks():      # tests only
        script = os.environ.get("HOEHWA_INSTALL_TOOLS_PY") or script
        lock = os.environ.get("HOEHWA_TOOLS_LOCK") or lock
        root = os.environ.get("HOEHWA_APP_ROOT") or root
    return script, lock, root


def _progress_file():
    return os.path.join(os.path.dirname(llm_opencode.WORK), "install_progress.json")


def _kill_pid(pid):
    try:     # by PID (and its children) only, never by name
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10, creationflags=NO_WINDOW)
    except Exception:
        pass


def _stop_install():
    with _inst_lock:
        p = _inst["proc"]
    if p is not None and p.poll() is None:
        _kill_pid(p.pid)


atexit.register(_stop_install)


def _fail_reason(out_path):
    """the Korean reason install_tools.py printed on its `TOOL opencode FAIL <kind> <reason>` line (120 characters at most)"""
    try:
        with open(out_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split(None, 4)
                if len(parts) >= 4 and parts[0] == "TOOL" and parts[2] == "FAIL":
                    return (parts[4] if len(parts) > 4 else "").strip()[:120]
    except OSError:
        pass
    return ""


def _result_ok(out_path):
    try:
        with open(out_path, encoding="utf-8", errors="replace") as f:
            return any(line.strip() == "TOOL_RESULT OK" for line in f)
    except OSError:
        return False


def _watch_install(proc, pf, out_path):
    last = 0
    while proc.poll() is None:
        try:
            with open(pf, "rb") as f:        # read and close at once: the writer replaces the file by renaming, which fails while it is open
                raw = f.read()
            p = int(float(json.loads(raw.decode("utf-8")).get("pct", 0)))
            last = max(last, min(99, max(0, p)))
            with _inst_lock:
                _inst["pct"] = last
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        time.sleep(0.2)
    ok = proc.returncode == 0 and _result_ok(out_path)
    reason = "" if ok else (_fail_reason(out_path) or "AI 구성 요소를 받지 못했어요. 인터넷 연결을 확인하고 다시 시도해 주세요.")
    for f in (pf, out_path):
        try:
            os.remove(f)
        except OSError:
            pass
    if ok:
        llm_opencode.after_install()
    with _inst_lock:
        _inst.update(state="done" if ok else "error", pct=100 if ok else last, error=reason, proc=None)
    _log().info("llm/install %s (exit code %s)", "done" if ok else "failed", proc.returncode)


def _install_view():
    with _inst_lock:
        return {"state": _inst["state"], "pct": _inst["pct"], "error": _inst["error"]}


@router.post("/llm/install")
async def install_endpoint(request: Request):
    blocked = _guard(request)
    if blocked is not None:
        return blocked
    with _inst_lock:
        if _inst["state"] == "running":
            return {"ok": True, "state": "running"}
    if llm_opencode.installed():
        with _inst_lock:
            _inst.update(state="done", pct=100, error="")
        return {"ok": True, "state": "done"}
    script, lock, root = _paths()
    if not (os.path.isfile(script) and os.path.isfile(lock)):
        with _inst_lock:
            _inst.update(state="error", pct=0, error=MSG_NO_TOOLS)
        return {"ok": False, "state": "error", "error": MSG_NO_TOOLS}
    pf = _progress_file()
    out_path = pf + ".out"
    with _inst_lock:
        if _inst["state"] == "running":      # a second request raced the first one: one process only
            return {"ok": True, "state": "running"}
        try:
            os.makedirs(os.path.dirname(pf), exist_ok=True)
            for f in (pf, out_path):
                try:
                    os.remove(f)
                except OSError:
                    pass
            out = open(out_path, "wb")
            try:
                proc = subprocess.Popen([sys.executable, "-X", "utf8", script, lock, root, "--only", "opencode", "--progress-file", pf],
                                        stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
            finally:
                out.close()
        except OSError as ex:
            _inst.update(state="error", pct=0, error="구성 요소 설치를 시작하지 못했어요")
            _log().warning("llm/install: could not start (%s)", type(ex).__name__)
            return {"ok": False, "state": "error", "error": _inst["error"]}
        _inst.update(state="running", pct=0, error="", proc=proc)
    _log().info("llm/install started: pid %d", proc.pid)
    threading.Thread(target=_watch_install, args=(proc, pf, out_path), daemon=True, name="llm-install").start()
    return {"ok": True, "state": "running"}


@router.get("/llm/install")
async def install_status_endpoint(request: Request):
    blocked = _guard(request)
    if blocked is not None:
        return blocked
    return _install_view()
