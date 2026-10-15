# -*- coding: utf-8 -*-
"""AI engine "openai_api": any OpenAI-compatible HTTP API (POST {base}/chat/completions).

config.json:  "llm_provider": "openai_api",
              "openai_api": {"preset": "opencode_zen", "base_url": "...", "model": "...", "key_source": "secret"}
API key (never printed, logged or returned): ONLY a key the person typed into this app, stored by POST /llm in
  backend\\secrets.json {"openai_api": {"<preset>": "<key>"}}. This module never reads the OpenCode login or any other
  program's credential file (an old config value key_source "opencode" is treated as "secret").
Errors are raised as llm_common.LlmError with .kind "auth" / "limit" / "overload" / None, so server.py's usage-limit
fallback to the local model works the same as for the OpenCode engine.
"""
import json
import os
import threading
import time

import requests

import llm_common

BASE = os.path.dirname(os.path.abspath(__file__))
SECRETS_PATH = os.path.join(BASE, "secrets.json")

# base URLs checked against each provider's documentation (2026-10):
#   OpenCode Zen  https://opencode.ai/docs/zen/            (".../zen/v1" answers the same)
#   DeepSeek      https://api-docs.deepseek.com/           (OpenAI-compatible base_url)
#   Gemini        https://ai.google.dev/gemini-api/docs/openai
#   OpenRouter    https://openrouter.ai/docs/quickstart
PRESETS = {
    "opencode_zen": {"label": "OpenCode Zen", "base_url": "https://opencode.ai/inference/v1",
                     "model": "deepseek-v4.1-flash",
                     "note": "무료(free) 모델은 OpenCode 프로그램 안에서만 쓸 수 있어요. 이 앱에서는 유료 모델이 필요해요."},
    "deepseek": {"label": "DeepSeek", "base_url": "https://api.deepseek.com",
                 "model": "deepseek-flash", "note": ""},
    "gemini": {"label": "Google Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
               "model": "gemini-2.5-flash", "note": ""},
    "openrouter": {"label": "OpenRouter", "base_url": "https://openrouter.ai/api/v1",
                   "model": "openrouter/auto", "note": ""},
}
KEY_SOURCES = ("secret",)
DEFAULT = {"preset": "opencode_zen", "model": "", "key_source": "secret"}

_session = requests.Session()
_session.headers.update({"User-Agent": "hoehwa-practice/1.0", "X-Title": "hoehwa-practice"})
_no_json_mode = set()      # (base_url, model) that rejected response_format
_lock = threading.Lock()


class _Secret(str):
    """A str whose repr never shows the value (keeps keys out of tracebacks and logs)."""
    def __repr__(self):
        return "<secret>"


# ---------------------------------------------------------------------------------------------- settings
def settings(cfg):
    """Effective settings from CFG["openai_api"] (preset defaults filled in). Contains no key."""
    raw = dict(DEFAULT)
    raw.update({k: v for k, v in (cfg.get("openai_api") or {}).items() if k in ("preset", "base_url", "model", "key_source")})
    preset = raw["preset"] if raw["preset"] in PRESETS else DEFAULT["preset"]
    p = PRESETS[preset]
    return {"preset": preset, "label": p["label"],
            "base_url": (raw.get("base_url") or p["base_url"]).rstrip("/"),
            "model": raw.get("model") or p["model"],
            "key_source": "secret",   # the only source: a key typed into this app (secrets.json)
            "note": p["note"]}


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def get_key(s):
    """API key for settings `s`, or None. Never log the result."""
    k = ((_read_json(SECRETS_PATH).get("openai_api") or {}).get(s["preset"]))
    return _Secret(k.strip()) if isinstance(k, str) and k.strip() else None


def has_key(s):
    return get_key(s) is not None


def save_secret(preset, key):
    """Store (or with key "" remove) the API key for `preset` in backend/secrets.json."""
    with _lock:
        d = _read_json(SECRETS_PATH)
        keys = d.setdefault("openai_api", {})
        if key:
            keys[preset] = key.strip()
        else:
            keys.pop(preset, None)
        tmp = SECRETS_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f)
        os.replace(tmp, SECRETS_PATH)


# ---------------------------------------------------------------------------------------------- errors
def _err_text(r):
    try:
        d = r.json()
        e = d.get("error", d) if isinstance(d, dict) else d
        if isinstance(e, dict):
            return " ".join(str(e.get(k, "")) for k in ("type", "code", "status", "message") if e.get(k))
        if isinstance(e, list) and e and isinstance(e[0], dict):  # Gemini returns a list
            return json.dumps(e[0].get("error", e[0]), ensure_ascii=False)[:400]
        return str(e)[:400]
    except Exception:
        return (r.text or "")[:400]


def _fail(s, r, key):
    st = r.status_code
    text = _err_text(r)
    if key:
        text = text.replace(key, "<key>")
    low = text.lower()
    label = s["label"]
    if "freetier" in low.replace(" ", "") or "free tier" in low:
        return llm_common.LlmError("%s 무료 모델은 OpenCode 프로그램 안에서만 쓸 수 있어요. 유료 모델을 고르거나 다른 AI 엔진을 써 주세요." % label,
                                503, "auth", "HTTP %d %s" % (st, text))
    if st in (401, 403):
        return llm_common.LlmError("%s API 키를 확인해 주세요. (키가 없거나 올바르지 않아요)" % label, 503, "auth", "HTTP %d %s" % (st, text))
    if st in (402, 429) or "quota" in low or "insufficient" in low or "balance" in low or "rate limit" in low:
        ra = r.headers.get("Retry-After", "")
        extra = (" retry in %s seconds" % ra) if ra.strip().isdigit() else ""
        return llm_common.LlmError("%s 사용 한도(또는 잔액)에 도달했어요. 잠시 뒤에 다시 시도해 주세요." % label, 502, "limit",
                                "HTTP %d usage limit %s%s" % (st, text, extra))
    if st == 404 or "model" in low and ("not found" in low or "not exist" in low or "invalid" in low or "unknown" in low):
        return llm_common.LlmError("%s에서 AI 모델 '%s'을(를) 찾을 수 없어요. 설정에서 모델을 다시 골라 주세요." % (label, s["model"]), 400,
                                None, "HTTP %d %s" % (st, text))
    if st in (500, 502, 503, 504, 529):
        return llm_common.LlmError("%s 서버가 바빠요. 잠시 뒤에 다시 시도해 주세요." % label, 502, "overload", "HTTP %d %s" % (st, text))
    return llm_common.LlmError("%s 호출에 실패했어요 (HTTP %d). 잠시 뒤에 다시 시도해 주세요." % (label, st), 502, None, "HTTP %d %s" % (st, text))


# ---------------------------------------------------------------------------------------------- calls
def _post(s, key, body, timeout):
    try:
        return _session.post(s["base_url"] + "/chat/completions", json=body, timeout=timeout,
                             headers={"Authorization": "Bearer " + key})
    except requests.exceptions.Timeout:
        raise llm_common.LlmError("AI 응답이 너무 오래 걸려요. 잠시 뒤에 다시 시도해 주세요.", 504)
    except requests.exceptions.RequestException as e:
        raise llm_common.LlmError("%s에 연결할 수 없어요. 인터넷 연결을 확인해 주세요." % s["label"], 503, None, type(e).__name__)


def call_json(cfg, messages, schema, temperature=0.7, max_tokens=None, timeout=120):
    """One chat completion that must return a JSON object. Returns (data, seconds, model)."""
    s = settings(cfg)
    if llm_common.SIMULATE_LIMIT:  # test hook (server.py /debug/engine_limit)
        import llm_fallback
        raw = llm_common.SIMULATE_LIMIT
        raise llm_common.LlmError("%s 사용 한도(또는 잔액)에 도달했어요. 잠시 뒤에 다시 시도해 주세요." % s["label"], 502,
                               llm_fallback.classify(raw), raw)
    key = get_key(s)
    if not key:
        raise llm_common.LlmError("%s API 키가 없어요. 설정에서 API 키를 입력해 주세요." % s["label"], 503, "auth", "no api key")
    instr = ("Reply with ONLY one JSON object (no code fences, no extra text) that matches this JSON schema:\n"
             + json.dumps(schema, ensure_ascii=False))
    msgs = list(messages) + [{"role": "system", "content": instr}]
    body = {"model": s["model"], "messages": msgs, "temperature": temperature, "stream": False}
    if max_tokens:
        body["max_tokens"] = int(max_tokens)
    jm = (s["base_url"], s["model"]) not in _no_json_mode
    if jm:
        body["response_format"] = {"type": "json_object"}
    t0 = time.time()
    r = _post(s, key, body, timeout)
    if r.status_code == 400 and jm and any(w in _err_text(r).lower() for w in ("response_format", "json", "not support")):
        _no_json_mode.add((s["base_url"], s["model"]))  # JSON mode unsupported here: prompt-only JSON from now on
        body.pop("response_format", None)
        r = _post(s, key, body, timeout)
    if r.status_code != 200:
        raise _fail(s, r, key)
    try:
        d = r.json()
        msg = d["choices"][0]["message"]
        content = msg.get("content") or ""
        if isinstance(content, list):  # some providers return content parts
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        return llm_common.extract_json(content), time.time() - t0, s["model"]
    except Exception:
        raise llm_common.LlmError("AI가 올바른 형식으로 답하지 못했어요. 다시 시도해 주세요.", 502, None, (r.text or "")[:300])


def list_models(cfg, preset=None, key_source=None):
    """[{"id", "free"}] from GET {base}/models, sorted (free first)."""
    c = dict(cfg.get("openai_api") or {})
    if preset:
        if preset not in PRESETS:
            raise llm_common.LlmError("알 수 없는 API 제공자예요: %s" % preset, 400)
        if preset != c.get("preset"):
            c.pop("base_url", None)
            c.pop("model", None)
        c["preset"] = preset
    if key_source in KEY_SOURCES:
        c["key_source"] = key_source
    s = settings({"openai_api": c})
    key = get_key(s)
    if not key:
        raise llm_common.LlmError("%s API 키가 없어요. 키를 먼저 설정해 주세요." % s["label"], 400, "auth", "no api key")
    try:
        r = _session.get(s["base_url"] + "/models", headers={"Authorization": "Bearer " + key}, timeout=30)
    except requests.exceptions.RequestException as e:
        raise llm_common.LlmError("%s에 연결할 수 없어요. 인터넷 연결을 확인해 주세요." % s["label"], 503, None, type(e).__name__)
    if r.status_code != 200:
        raise _fail(s, r, key)
    data = r.json()
    items = data.get("data", data.get("models", [])) if isinstance(data, dict) else data
    ids = []
    for m in items or []:
        mid = m.get("id") if isinstance(m, dict) else str(m)
        if mid:
            ids.append(mid[len("models/"):] if mid.startswith("models/") else mid)  # Gemini lists "models/<id>"
    ids = sorted(set(ids), key=lambda i: ("free" not in i.lower(), i))
    return s, [{"id": i, "free": "free" in i.lower()} for i in ids]
