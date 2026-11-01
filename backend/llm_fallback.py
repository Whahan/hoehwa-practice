# -*- coding: utf-8 -*-
"""Usage-limit notice: when the AI engine (OpenCode's free DeepSeek, or the OpenAI-compatible API) hits a usage/rate
limit, is busy, or rejects the login, server.py records it here and /health.llm_fallback and GET /llm show a Korean notice
until the reset time. There is no local model to answer in its place and calls are never blocked by the notice: every call
is tried, a success (server.py) clears the notice. (The module name is historical.)

State is in memory only (a restart starts without a notice). Reset time: parsed from the error text if present
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
    # a clock time needs ":MM" or am/pm - a bare number ("try again 1 time", "resets after 2026-10-17") is not a time
    m = re.search(r"(?:reset[s]?|try again|available again)(?:\s+at)?\s+(?<![\d:.-])(\d{1,2})(?:(?::(\d{2})(?![\d:.-]))\s*([ap]\.?m\.?(?![a-z]))?|\s*([ap]\.?m\.?(?![a-z])))", t, re.I)
    if m:
        hour, minute = int(m.group(1)), int(m.group(2) or 0)
        ap = (m.group(3) or m.group(4) or "").lower().replace(".", "")
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
    name = label or provider
    when = _dt.datetime.fromtimestamp(until).strftime("%H:%M" if until - now < 20 * 3600 else "%m/%d %H:%M")
    cause = {"limit": "%s 사용 한도에 도달했어요." % name, "auth": "%s 로그인이나 키에 문제가 있어요." % name,
             "overload": "%s 서버가 바빠요." % name}.get(kind, "%s 호출에 실패했어요." % name)
    reason = ("%s [AI 연결하기]로 다시 연결해 주세요." % cause) if kind == "auth" else ("%s %s 이후 다시 시도해요." % (cause, when))
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


def reset_text(provider=None):
    """"HH:MM" (or "MM/DD HH:MM") when the notice for `provider` ends, "" if there is none."""
    with _lock:
        if _state["provider"] and time.time() < _state["until"] and (provider is None or _state["provider"] == provider):
            return _state["when"]
        return ""


def status(provider=None):
    """{"active", "until" (ISO 8601 local time or None), "reason"} for /health and GET /llm. `active` is true only while a
    limit / busy / rejected-login notice is showing for `provider`."""
    with _lock:
        live = bool(_state["provider"]) and time.time() < _state["until"] and (provider is None or _state["provider"] == provider)
        if not live:
            return {"active": False, "until": None, "reason": ""}
        until = _dt.datetime.fromtimestamp(_state["until"]).astimezone().isoformat(timespec="seconds")
        return {"active": True, "until": until, "reason": _state["reason"]}
