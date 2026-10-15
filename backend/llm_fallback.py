# -*- coding: utf-8 -*-
"""Usage-limit fallback: when the remote AI engine (OpenCode's free DeepSeek, or the OpenAI-compatible API) hits a
usage/rate limit or loses access, server.py retries on the local Ollama model and routes later calls straight to
local until the limit resets.

State is in memory only (a restart tries the remote engine again). Reset time: parsed from the error text if present
("...|1760000000", "resets 3pm", "try again in 2 hours 5 minutes", "retry in 41s"), else DEFAULT_MINUTES.
"""
import datetime as _dt
import re
import threading
import time

DEFAULT_MINUTES = 30
AUTH_MINUTES = 30
OVERLOAD_MINUTES = 5
MAX_SECONDS = 7 * 24 * 3600

_lock = threading.Lock()
_state = {"provider": None, "until": 0.0, "reason": "", "kind": "", "since": 0.0, "message": "", "cause": "", "when": ""}

LIMIT_RE = re.compile(r"usage limit|rate[ _-]?limit|limit reached|hit your (usage )?limit|\b429\b|too many requests|quota|"
                      r"resource[ _]exhausted|insufficient_quota|limit will reset|out of (credits|usage)|"
                      r"session limit|weekly limit|5-hour limit|사용 한도", re.I)
OVERLOAD_RE = re.compile(r"overloaded|\b529\b|capacity", re.I)
AUTH_RE = re.compile(r"authenticate|oauth|not logged in|log ?in|unauthori[sz]ed|\b401\b|ineligible|invalid api key|"
                     r"credentials|로그인", re.I)


def classify(raw):
    """'limit', 'overload', 'auth' or None for the engine's raw error text."""
    t = raw or ""
    if LIMIT_RE.search(t):
        return "limit"
    if AUTH_RE.search(t):
        return "auth"
    if OVERLOAD_RE.search(t):
        return "overload"
    return None


_UNITS = {"d": 86400, "day": 86400, "days": 86400, "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
          "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60, "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1}


def parse_reset(raw, now=None):
    """Epoch seconds when the limit resets, or None if the message does not say."""
    now = now or time.time()
    t = raw or ""
    m = re.search(r"\|\s*(\d{10})\b", t)  # "usage limit reached|1760000000" (epoch seconds)
    if m:
        return float(m.group(1))
    m = re.search(r"(?:try again|retry|reset[s]?|available again|wait)\s*(?:in|after)\s+((?:\d+(?:\.\d+)?\s*[a-z]+[\s,]*(?:and\s+)?)+)", t, re.I)
    if m:
        total = 0.0
        for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*([a-z]+)", m.group(1), re.I):
            total += float(n) * _UNITS.get(u.lower(), 0)
        if total > 0:
            return now + total
    m = re.search(r"(?:reset[s]?|try again|available again)(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?", t, re.I)
    if m:
        hour, minute = int(m.group(1)), int(m.group(2) or 0)
        ap = (m.group(3) or "").lower().replace(".", "")
        if ap == "pm" and hour < 12:
            hour += 12
        if ap == "am" and hour == 12:
            hour = 0
        if hour < 24 and minute < 60:
            base = _dt.datetime.fromtimestamp(now)
            cand = base.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if cand.timestamp() <= now:
                cand += _dt.timedelta(days=1)
            return cand.timestamp()
    return None


def mark(provider, kind, raw, friendly="", label=None):
    """Remember that `provider` is unusable until its reset time. Returns the epoch 'until'."""
    now = time.time()
    until = parse_reset(raw, now) if kind == "limit" else None
    if until is None:
        until = now + 60 * {"limit": DEFAULT_MINUTES, "auth": AUTH_MINUTES, "overload": OVERLOAD_MINUTES}.get(kind, DEFAULT_MINUTES)
    until = min(max(until, now + 60), now + MAX_SECONDS)
    why = {"limit": "사용 한도에 도달해서", "auth": "로그인이나 사용 권한 문제로", "overload": "서버가 바빠서"}.get(kind, "호출에 실패해서")
    cause = "%s %s" % (label or provider, why)
    when = _dt.datetime.fromtimestamp(until).strftime("%H:%M" if until - now < 20 * 3600 else "%m/%d %H:%M")
    reason = "%s %s까지 로컬 AI로 답해요." % (cause, when)
    with _lock:
        _state.update(provider=provider, until=until, reason=reason, kind=kind, since=now, cause=cause, when=when,
                      message=(friendly or raw or "")[:300])
    return until


def active_for(provider):
    with _lock:
        if _state["provider"] == provider and time.time() < _state["until"]:
            return True
        if _state["provider"] and time.time() >= _state["until"]:
            _state.update(provider=None, until=0.0, reason="", kind="", since=0.0, message="", cause="", when="")
        return False


def clear():
    with _lock:
        _state.update(provider=None, until=0.0, reason="", kind="", since=0.0, message="", cause="", when="")


def status(provider=None, local_ok=True):
    """{"active", "until" (ISO 8601 local time or None), "reason"} for /health and GET /llm.
    local_ok=False: the local model cannot answer either, so the reason must not claim that it does."""
    with _lock:
        live = bool(_state["provider"]) and time.time() < _state["until"] and (provider is None or _state["provider"] == provider)
        if not live:
            return {"active": False, "until": None, "reason": ""}
        until = _dt.datetime.fromtimestamp(_state["until"]).astimezone().isoformat(timespec="seconds")
        if local_ok:
            reason = _state["reason"]
        else:
            reason = "AI 엔진을 쓸 수 없어요: %s %s까지 쓸 수 없고, 로컬 AI(Ollama)도 연결되지 않아요. 문법 검사기만 쓸 수 있어요." % (
                _state["cause"], _state["when"])
        return {"active": True, "until": until, "reason": reason}
