# -*- coding: utf-8 -*-
"""Tests for the "less AI" features and the removal of the local model (Ollama) against a RUNNING test server started with
the test hooks on and a FAKE OpenCode (HOEHWA_OPENCODE_EXE=<fake>; never the real one, never a real login):

    set HOEHWA_TEST_HOOKS=1
    .venv\\Scripts\\python.exe server.py --port 18851 --tag gramcache --stt-cpu
    .venv\\Scripts\\python.exe test_offline_ai.py --base http://127.0.0.1:18851 [--tag gramcache]

(--base is REQUIRED: pass the URL of YOUR test server; there is deliberately no default, the app's own server must never
be used by a test.) Sections that need an AI that answers run only when /health.llm_state is "ready" (fake OpenCode logged in)
and print SKIP otherwise; the checks for "not connected" run only when it is "not_connected" / "not_installed".

1. LanguageTool grammar correction (/fix with AI polish off = LanguageTool only), English + Japanese
2. /fix result cache: the second identical call is a cache hit (timing + server log line)
3. usage limit of the engine (simulated): the call fails with 429 ai_limit, a Korean notice shows in /health.llm_fallback
   (llm_state "blocked", no word about a local AI), and the next call is NOT blocked (it is tried again)
4. openai_api engine against a mock OpenAI-compatible server
5. opencode engine with the REAL OpenCode login: only with --live-opencode (otherwise "SKIP live opencode")
6. (--no-ai-server) a server whose AI is not installed / not connected: /fix gives an empty fix (HTTP 200) when LanguageTool
   finds nothing, the LanguageTool fix when it does, and no notice claims that a local AI answers
7. Ollama removed (docs/onetouch_install_design.md B2): /health and GET /llm shapes, POST /llm {"provider": "ollama"} -> 400
   engine_removed, /chat -> 503 ai_not_connected / ai_not_installed (Korean) while LanguageTool, /lesson, /score still work
8. (--spawn-legacy) its own test server (free port 18853..18859, config from a temp file with the old "ollama" keys whose
   ollama_url points at a listener this test counts on a free 127.0.0.1 port of its own): migration to "opencode" with notice "ollama_removed",
   /llm/notice/ack, config file unchanged, ZERO connections to the old Ollama address. The spawned server gets no OpenCode
   (its path points nowhere: llm_state not_installed) unless --fake-opencode PATH names a fake one.

The openai_api engine is tested ONLY against a local mock server and a key typed into the app (secrets.json); no test
reads or uses the OpenCode login or any real API key.
"""
import json
import os
import random
import re
import sys
import time

import requests

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

if "--base" not in sys.argv or sys.argv.index("--base") + 1 >= len(sys.argv):
    print("usage: test_offline_ai.py --base http://127.0.0.1:<port of YOUR test server> [--tag TAG] [--no-api] [--live-opencode] [--no-ai-server]\n"
          "                          [--spawn-legacy [--fake-opencode PATH]]\n"
          "--base is required (there is no default: never test against the app's own server).")
    sys.exit(2)
BASE = sys.argv[sys.argv.index("--base") + 1].rstrip("/")
TAG = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else "gramcache"
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "server-%s.log" % TAG)
HANGUL = re.compile(r"[가-힣]")

results, timings = [], []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def has_keys(d, keys):
    """The response has at least these keys (extra keys such as /chat's tts_chunks are allowed)."""
    return isinstance(d, dict) and set(keys) <= set(d)


FIX_KEYS = ("fix", "fix_ko")
CHAT_KEYS = ("reply", "reading", "ko", "fix", "fix_ko", "suggest")


def call(method, path, label=None, **kw):
    t0 = time.time()
    r = requests.request(method, BASE + path, timeout=600, **kw)
    dt = time.time() - t0
    timings.append((label or "%s %s" % (method, path), dt))
    return r, dt


def log_size():
    try:
        return os.path.getsize(LOG)
    except OSError:
        return 0


def log_since(pos):
    try:
        with open(LOG, "rb") as f:
            f.seek(pos)
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


EN = [  # (learner sentence, words the correction must contain)
    ("He go to school yesterday", ["went"]),
    ("I have a apple", ["an apple"]),
    ("She don't like it", ["doesn't"]),
    ("I am agree with you", ["I agree"]),
    ("I went to home", ["went home"]),
    ("I can speaks English", ["can speak"]),
    ("He have two cat", ["has", "cats"]),
    ("I am interesting in music", ["interested"]),
    ("I look forward to see you", ["seeing"]),
    ("I want go to the park", ["want to go"]),
]
JA = ["これわ ペンです", "私わ学生です", "昨日は映画を見ます", "水を飲むます"]


def main():
    print("Backend:", BASE, "| log:", LOG)
    h = call("GET", "/health")[0].json()
    print("  health:", json.dumps({k: h.get(k) for k in ("llm", "llm_provider", "llm_state", "grammar", "llm_fallback")}, ensure_ascii=False))
    check("health has grammar=true", h.get("grammar") is True, h.get("grammar"))
    state = h.get("llm_state")
    check("health has llm_fallback {active, until, reason}", isinstance(h.get("llm_fallback"), dict)
          and has_keys(h["llm_fallback"], ("active", "until", "reason")), h.get("llm_fallback"))
    r = requests.post(BASE + "/debug/config", json={}, timeout=10)
    if not check("test hooks enabled (HOEHWA_TEST_HOOKS=1)", r.status_code == 200, r.status_code):
        return 2
    requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
    test_no_credential_reads()
    if "--no-ai-server" in sys.argv:   # server started without any usable AI engine: only sections 6 and 7
        test_no_ai()
        test_ollama_removed()
        if "--spawn-legacy" in sys.argv:
            test_spawn_legacy()
        return finish()

    # ------------------------------------------------------------------ 1. LanguageTool only
    print("\n== 1. LanguageTool only (AI polish off): English")
    requests.post(BASE + "/debug/config", json={"grammar_llm_polish": False}, timeout=10)
    for i, (s, need) in enumerate(EN):
        r, dt = call("POST", "/fix", "fix LT en %d" % i, json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   %-28s -> %-32s %.2fs | %s" % (s, d.get("fix"), dt, d.get("fix_ko")))
        ok = r.status_code == 200 and has_keys(d, FIX_KEYS) and all(n.lower() in d["fix"].lower() for n in need)
        check("LT fixes %r" % s, ok and bool(HANGUL.search(d["fix_ko"])), d)
        check("LT %r is fast (< 2 s)" % s, dt < 2.0 or i == 0, "%.2fs" % dt)
    print("\n== 1b. LanguageTool only: Japanese (LanguageTool's Japanese rules are few)")
    for i, s in enumerate(JA):
        r, dt = call("POST", "/fix", "fix LT ja %d" % i, json={"lang": "ja", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   %-14s -> %-16s %.2fs | %s" % (s, d.get("fix"), dt, d.get("fix_ko")))
    check("LT ja fixes これわ -> これは", "これは" in (call("POST", "/fix", "fix LT ja korewa", json={"lang": "ja", "stage": 1, "text": JA[0]})[0].json().get("fix") or ""))

    print("\n== 1d. LanguageTool guard against dubious fixes (in-process LanguageTool)")
    test_lt_guard()

    print("\n== 1c. LanguageTool + AI polish (default)")
    requests.post(BASE + "/debug/config", json={"grammar_llm_polish": True}, timeout=10)
    r, dt = call("POST", "/fix", "fix LT+AI en", json={"lang": "en", "stage": 1, "text": "Yesterday he go to cafe with his friend", "prev_ai": ""})
    d = r.json()
    print("   -> %s | %s (%.1fs)" % (d.get("fix"), d.get("fix_ko"), dt))
    check("LT+AI fix has went", r.status_code == 200 and "went" in (d.get("fix") or ""), d)

    # ------------------------------------------------------------------ 2. cache
    print("\n== 2. /fix cache (sentence LanguageTool does not catch -> AI)")
    if not ai_ready():
        print("   SKIP: needs an AI that answers (fake OpenCode logged in); /health.llm_state is %r" % call("GET", "/health")[0].json().get("llm_state"))
    else:
        s = "There is many people in room %d" % random.randint(100, 999)
        pos = log_size()
        r1, dt1 = call("POST", "/fix", "fix AI first", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        r2, dt2 = call("POST", "/fix", "fix AI second (cache)", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        time.sleep(0.5)
        lg = log_since(pos)
        print("   %r -> %r | first %.2fs, second %.2fs" % (s, r1.json(), dt1, dt2))
        for line in lg.splitlines():
            if "llm cache" in line or "languagetool" in line:
                print("   log:", line[20:].strip())
        check("cache: same answer twice", r1.json() == r2.json() and r1.status_code == 200)
        # (a fake engine answers at once: with a first call under 0.3 s there is nothing to compare, the log line below decides)
        check("cache: second call fast (< 1 s) and much faster than a slow first call", dt2 < 1.0 and (dt1 < 0.3 or dt2 < dt1 / 3), "%.2fs vs %.2fs" % (dt1, dt2))
        check("cache: log shows MISS then HIT for fix", "llm cache MISS fix" in lg and "llm cache HIT fix" in lg)

    # ------------------------------------------------------------------ 3. engine limit -> notice only, never blocked
    print("\n== 3. simulated usage limit of the engine (OpenCode free DeepSeek): 429 ai_limit, a Korean notice, nothing blocked")
    if not ai_ready():
        print("   SKIP: needs an AI that answers (fake OpenCode logged in)")
    else:
        reset = int(time.time()) + 1800
        requests.post(BASE + "/debug/engine_limit", json={"message": "usage limit reached|%d" % reset}, timeout=10)
        pos = log_size()
        scen = {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."}
        chat_body = {"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": scen, "history": [], "conv_id": "limit-test-%d" % reset}
        r, dt = call("POST", "/chat", "chat during engine limit", json=chat_body)
        d = r.json()
        print("   /chat opening -> %s %s (%.1fs)" % (r.status_code, json.dumps(d, ensure_ascii=False)[:200], dt))
        check("limit: /chat -> HTTP 429, code ai_limit, Korean message", r.status_code == 429 and d.get("code") == "ai_limit"
              and bool(HANGUL.search(d.get("error", ""))), r.text[:200])
        check("limit: the message names the time to try again (HH:MM)", bool(re.search(r"\d\d:\d\d", d.get("error", ""))), d.get("error"))
        # a JSON call (/fix, a sentence LanguageTool does not catch) cannot reach the AI either: no fix, but HTTP 200
        s = "Yesterday I eat pizza with %d friends" % random.randint(10, 99)
        r, dt = call("POST", "/fix", "fix during engine limit", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   /fix %r -> %s (%.1fs)" % (s, d, dt))
        check("limit: /fix still answers (HTTP 200, same shape)", r.status_code == 200 and has_keys(d, FIX_KEYS), r.text[:200])
        h = call("GET", "/health")[0].json()
        fb = h.get("llm_fallback") or {}
        print("   health:", {k: h.get(k) for k in ("llm", "llm_state")}, "llm_fallback:", fb)
        check("limit: /health.llm_fallback.active true", fb.get("active") is True, fb)
        check("limit: until parsed from the message (~30 min)", bool(fb.get("until")) and abs(
            time.mktime(time.strptime(fb["until"][:19], "%Y-%m-%dT%H:%M:%S")) - reset) < 5, fb.get("until"))
        check("limit: reason is Korean and says nothing about a local AI", bool(HANGUL.search(fb.get("reason", "")))
              and "로컬" not in fb.get("reason", "") and "Ollama" not in fb.get("reason", ""), fb.get("reason"))
        check("limit: /health.llm_state is blocked and llm stays true (the engine is still tried)", h.get("llm_state") == "blocked" and h.get("llm") is True,
              {k: h.get(k) for k in ("llm", "llm_state")})
        g = call("GET", "/llm")[0].json()
        check("limit: GET /llm has the same notice and state blocked", (g.get("llm_fallback") or {}).get("active") is True and g.get("state") == "blocked",
              {"state": g.get("state"), "fb": g.get("llm_fallback")})
        lg = log_since(pos)
        for line in lg.splitlines():
            if "unusable" in line or "call failed" in line or "chat failed" in line:
                print("   log:", line[20:].strip()[:200])
        check("limit: server log never mentions ollama / a local model", "ollama" not in lg.lower() and "local model" not in lg.lower())
        # the limit is over: the very next call is tried (not refused because of the notice) and answers
        requests.post(BASE + "/debug/engine_limit", json={"message": ""}, timeout=10)   # simulation off, the notice is NOT cleared
        h = call("GET", "/health")[0].json()
        check("not blocked: the notice is still showing before the next call", (h.get("llm_fallback") or {}).get("active") is True, h.get("llm_fallback"))
        r, dt = call("POST", "/chat", "chat after engine limit", json=dict(chat_body, conv_id="limit-test-%d-b" % reset))
        print("   /chat after the limit -> %s (%.1fs)" % (r.status_code, dt))
        check("not blocked: the next /chat answers (HTTP 200, same shape)", r.status_code == 200 and has_keys(r.json(), CHAT_KEYS), r.text[:200])
        h = call("GET", "/health")[0].json()
        check("not blocked: a successful call ends the notice (active false, llm_state ready)", (h.get("llm_fallback") or {}).get("active") is False
              and h.get("llm_state") == "ready", {k: h.get(k) for k in ("llm_state", "llm_fallback")})
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)

    if "--no-api" not in sys.argv:
        test_openai_api()
    if "--live-opencode" in sys.argv:   # the REAL OpenCode login and the real free model: never part of a default run
        test_opencode()
    else:
        print("\n== 5. opencode engine\n   SKIP live opencode (pass --live-opencode to use the real OpenCode login and the real free model)")
    test_ollama_removed()
    if "--spawn-legacy" in sys.argv:
        test_spawn_legacy()
    return finish()


def ai_ready():
    """True when the server's AI answers right now (fake OpenCode logged in): /health.llm_state is "ready"."""
    requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
    return call("GET", "/health")[0].json().get("llm_state") == "ready"


def finish():
    print("\n================ SUMMARY ================")
    for k, v in timings:
        print("%-40s %8.2f" % (k, v))
    failed = [n for n, ok in results if not ok]
    print("\n%d checks, %d passed, %d failed" % (len(results), len(results) - len(failed), len(failed)))
    for n in failed:
        print("  FAILED:", n)
    return 1 if failed else 0


CORRECT_EN = ["I went to the store yesterday.", "She is my sister.", "We are going to Tokyo next week.",
              "Could you tell me where the station is?", "I have been studying English for two years.",
              "He doesn't like coffee.", "They played soccer in the park.", "My name is Jiho and I live in Seoul.",
              "I like Seoul and Busan.", "Can I have a cup of coffee, please?"]
DUBIOUS_EN = ["Me and him goes to school together", "Me and Tom went home", "My friend and me went to the park",
              "Me is Tom", "Them are my friends"]


def test_no_credential_reads():
    """No backend code may read the OpenCode login (auth.json in OpenCode's data dir) or any XDG data dir."""
    import glob
    here = os.path.dirname(os.path.abspath(__file__))
    pat = re.compile(r"auth\.json|\.local[/\\]+share|XDG_DATA_HOME")
    bad = []
    for fn in sorted(glob.glob(os.path.join(here, "*.py"))):
        if os.path.basename(fn) == os.path.basename(__file__):
            continue
        with open(fn, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f, 1):
                if pat.search(line):
                    bad.append("%s:%d" % (os.path.basename(fn), i))
    check("backend code never touches auth.json / ~/.local/share / XDG_DATA_HOME", not bad, bad)


def test_lt_guard():
    """LanguageTool itself (own child process, not the server): no worse-than-the-original fixes, no false fixes."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import grammar
    except Exception as e:
        print("   cannot import grammar (%s): skipped" % e)
        return
    if not (grammar.find_jar() and grammar.find_java()):
        print("   LanguageTool/Java not installed: skipped")
        return
    try:
        for s in DUBIOUS_EN:
            r = grammar.correct("en", s)
            print("   %-40s -> %s" % (s, r and r["fix"]))
            check("LT guard: no fix for %r (pronoun-case rules are unreliable)" % s, r is None, r)
        for s in CORRECT_EN:
            r = grammar.correct("en", s)
            check("LT: correct sentence %r gets no fix" % s, r is None, r and r["fix"])
        for s, need in EN:
            r = grammar.correct("en", s)
            check("LT still fixes %r" % s, bool(r) and all(n.lower() in r["fix"].lower() for n in need), r and r["fix"])
        r = grammar.correct("en", "I have a apple")
        check("LT label: grammar fix is not called spelling", bool(r) and "철자" not in r["fix_ko"], r and r["fix_ko"])
        r = grammar.correct("en", "Starbuks is good")
        check("LT label: real misspelling is called spelling", bool(r) and "철자" in r["fix_ko"], r and r["fix_ko"])
        r = grammar.correct("en", "Tomas go to school")
        check("LT keeps a name (Tomas) untouched", bool(r) and r["fix"].startswith("Tomas "), r and r["fix"])
    finally:
        grammar.stop()


def test_no_ai():
    """Server whose AI is not installed / not connected: LanguageTool only, never an error."""
    print("\n== 6. no AI engine available (LanguageTool only)")
    h = call("GET", "/health")[0].json()
    fb = h.get("llm_fallback") or {}
    print("   health: llm=%s provider=%s llm_fallback=%s" % (h.get("llm"), h.get("llm_provider"), fb))
    check("no-AI: /health.llm is false", h.get("llm") is False, h.get("llm"))
    check("no-AI: /health.llm_state is not_installed or not_connected (no limit notice, nothing about a local AI)",
          h.get("llm_state") in ("not_installed", "not_connected") and fb.get("active") is False and "로컬" not in fb.get("reason", ""), {"state": h.get("llm_state"), "fb": fb})
    g = call("GET", "/llm")[0].json()
    check("no-AI: GET /llm agrees (state, installed/connected, no notice)", g.get("state") == h.get("llm_state") and g.get("connected") is False
          and g["llm_fallback"]["active"] is False and (g["state"] != "not_installed" or g.get("installed") is False), {"state": g.get("state"), "installed": g.get("installed"), "connected": g.get("connected")})
    requests.post(BASE + "/debug/config", json={"grammar_llm_polish": True}, timeout=10)
    for s in CORRECT_EN:
        r, dt = call("POST", "/fix", "no-AI fix correct", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        check("no-AI: %r -> HTTP 200, empty fix" % s, r.status_code == 200 and r.json() == {"fix": "", "fix_ko": ""}, r.text[:200])
    for s in DUBIOUS_EN:
        r, dt = call("POST", "/fix", "no-AI fix dubious", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        check("no-AI: %r -> HTTP 200, no 'I and him' fix" % s, r.status_code == 200 and has_keys(d, FIX_KEYS) and "I and" not in d["fix"], d)
    for s, need in EN:
        r, dt = call("POST", "/fix", "no-AI fix LT", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   %-28s -> %-32s %.2fs | %s" % (s, d.get("fix"), dt, d.get("fix_ko")))
        check("no-AI: LT fixes %r" % s, r.status_code == 200 and all(n.lower() in d.get("fix", "").lower() for n in need) and bool(HANGUL.search(d.get("fix_ko", ""))), d)
    r, dt = call("POST", "/fix", "no-AI fix, after the failures were recorded", json={"lang": "en", "stage": 1, "text": "I went to the store yesterday."})
    check("no-AI: a repeated call is still fast and empty (< 2 s)", r.status_code == 200 and r.json()["fix"] == "" and dt < 2.0, "%.2fs" % dt)
    # the API engine without a key is "not connected" too: no fix from the AI, LanguageTool still answers, no notice about a local AI
    secrets_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "secrets.json")
    try:
        with open(secrets_path, encoding="utf-8") as f:
            has_real_key = bool((json.load(f).get("openai_api") or {}).get("opencode_zen"))
    except Exception:
        has_real_key = False
    if has_real_key:
        print("   secrets.json has an opencode_zen key: skipped the API-engine-without-a-key check")
        return
    requests.post(BASE + "/debug/config", json={"llm_provider": "openai_api"}, timeout=10)
    try:
        r, dt = call("POST", "/fix", "no-AI fix, failing API engine", json={"lang": "en", "stage": 1, "text": "I went to the store yesterday."})
        check("no-AI: failing engine -> /fix HTTP 200, empty fix", r.status_code == 200 and r.json() == {"fix": "", "fix_ko": ""}, r.text[:200])
        h = call("GET", "/health")[0].json()
        fb = h.get("llm_fallback") or {}
        print("   health after the call: llm_state=%s llm_fallback=%s" % (h.get("llm_state"), fb))
        check("no-AI: API engine without a key -> llm_state not_connected, llm false, nothing about a local AI",
              h.get("llm_state") == "not_connected" and h.get("llm") is False and "로컬" not in fb.get("reason", ""), {"state": h.get("llm_state"), "fb": fb})
        r, dt = call("POST", "/chat", "no-AI chat, API engine without a key", json={"lang": "en", "stage": 1, "history": [], "scenario": {"id": "x"}})
        check("no-AI: API engine without a key -> /chat 503 ai_not_connected", r.status_code == 503 and r.json().get("code") == "ai_not_connected", r.text[:200])
        r, dt = call("POST", "/fix", "no-AI fix LT, failing API engine", json={"lang": "en", "stage": 1, "text": "I have a apple"})
        check("no-AI: failing engine -> LanguageTool fix still returned", r.status_code == 200 and "an apple" in r.json().get("fix", ""), r.text[:200])
    finally:
        requests.post(BASE + "/debug/config", json={"llm_provider": "opencode"}, timeout=10)


# ---------------------------------------------------------------------------------------------- 4. openai_api
def _free_port():
    import socket
    sk = socket.socket()
    sk.bind(("127.0.0.1", 0))
    port = sk.getsockname()[1]
    sk.close()
    return port


MOCK_PORT = _free_port()   # a free local port: parallel test runs never collide
MOCK_KEY = "test-key-" + "%06d" % random.randint(0, 999999)
MOCK_SEEN = {"auth_ok": 0, "auth_bad": 0, "json_mode": 0, "plain": 0}


def _mock_obj(schema, name=""):
    if schema.get("type") == "object":
        return {k: _mock_obj(v, k) for k, v in (schema.get("properties") or {}).items()}
    if schema.get("type") == "array":
        n = max(2, schema.get("minItems", 2))
        return [_mock_obj(schema.get("items") or {"type": "string"}, name) for _ in range(n)]
    if schema.get("type") == "integer":
        return 3
    if name == "reading":
        return ""
    return "모의 응답이에요" if name in ("ko", "fix_ko", "summary", "why") else "This is a mock answer."


def start_mock():
    """A tiny OpenAI-compatible server: model ids select the behavior."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import threading

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, obj, headers=None):
            b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def _authed(self):
            ok = self.headers.get("Authorization") == "Bearer " + MOCK_KEY
            MOCK_SEEN["auth_ok" if ok else "auth_bad"] += 1
            return ok

        def do_GET(self):
            if not self._authed():
                return self._send(401, {"error": {"message": "invalid api key"}})
            if self.path.endswith("/models"):
                return self._send(200, {"data": [{"id": i} for i in ("mock-ok", "mock-nojson", "deepseek-v4.1-flash-free", "mock-limit")]})
            self._send(404, {"error": {"message": "not found"}})

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            if not self._authed():
                return self._send(401, {"error": {"message": "invalid api key"}})
            model = body.get("model")
            has_rf = "response_format" in body
            MOCK_SEEN["json_mode" if has_rf else "plain"] += 1
            if model == "mock-limit":
                return self._send(429, {"error": {"message": "Rate limit exceeded"}}, {"Retry-After": "600"})
            if model == "mock-free":
                return self._send(403, {"type": "error", "error": {"type": "FreeTierError", "message": "free tier only in OpenCode"}})
            if model == "mock-nojson" and has_rf:
                return self._send(400, {"error": {"message": "response_format is not supported for this model"}})
            if model not in ("mock-ok", "mock-nojson"):
                return self._send(404, {"error": {"message": "The model `%s` does not exist" % model}})
            sch = {}
            for m in body.get("messages", []):
                c = m.get("content", "")
                if m.get("role") == "system" and "JSON schema:" in c:
                    sch = json.loads(c.split("JSON schema:", 1)[1])
            content = json.dumps(_mock_obj(sch), ensure_ascii=False)
            if model == "mock-nojson":
                content = "Here you go:\n```json\n" + content + "\n```"
            self._send(200, {"choices": [{"message": {"role": "assistant", "content": content}}]})

    srv = ThreadingHTTPServer(("127.0.0.1", MOCK_PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_openai_api():
    print("\n== 4. openai_api engine (mock OpenAI-compatible server on :%d only; no real network, no OpenCode login)" % MOCK_PORT)
    before = call("GET", "/health")[0].json().get("llm_provider")
    secrets_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "secrets.json")
    try:  # the test writes a fake key into secrets.json: put the file back exactly as it was afterwards
        with open(secrets_path, "rb") as f:
            secrets_before = f.read()
    except OSError:
        secrets_before = None
    srv = start_mock()
    pos = log_size()
    try:
        g = call("GET", "/llm")[0].json()
        api = g.get("openai_api") or {}
        try:
            stored = json.loads(secrets_before or b"{}").get("openai_api", {})
        except Exception:
            stored = {}
        if not stored.get(api.get("preset")):
            check("GET /llm openai_api.has_key is false while secrets.json has no key (nothing else is consulted)",
                  api.get("has_key") is False, api.get("has_key"))
        check("GET /llm openai_api.key_source is 'secret' (OpenCode's login is never read)", api.get("key_source") == "secret", api.get("key_source"))
        r, _ = call("POST", "/llm", json={"provider": "openai_api", "key_source": "opencode"})
        check("POST /llm refuses key_source 'opencode'", r.status_code == 400, r.status_code)
        check("GET /llm has openai_api settings with presets (not in the picker options)", not any(o.get("id") == "openai_api" for o in g.get("options", []))
              and {p["id"] for p in api.get("presets", [])} >= {"opencode_zen", "deepseek", "gemini", "openrouter"}, api.get("presets"))
        # store a (fake) key through POST /llm -> backend/secrets.json, then point the preset at the mock
        r, _ = call("POST", "/llm", json={"provider": "openai_api", "preset": "openrouter", "key_source": "secret", "api_key": MOCK_KEY})
        txt = r.text
        check("POST /llm never echoes the key", r.status_code == 200 and MOCK_KEY not in txt, r.status_code)
        check("POST /llm reports has_key", (r.json().get("openai_api") or {}).get("has_key") is True)
        requests.post(BASE + "/debug/config", json={"openai_api": {"base_url": "http://127.0.0.1:%d/v1" % MOCK_PORT, "model": "mock-ok"}}, timeout=10)
        r, _ = call("GET", "/llm/models?preset=openrouter&key_source=secret")
        d = r.json()
        print("   /llm/models ->", d.get("models"))
        check("/llm/models returns ids, free marked", r.status_code == 200 and any(m["free"] and "free" in m["id"] for m in d.get("models", [])))
        r, dt = call("POST", "/llm/test", "llm/test openai_api mock")
        check("/llm/test via API ok", r.status_code == 200 and r.json().get("provider") == "openai_api", r.text[:200])
        scen = {"id": "cafe", "persona": "Emma, a barista", "scene": "ordering"}
        r, dt = call("POST", "/chat", "chat openai_api mock", json={"lang": "en", "stage": 1, "history": [], "scenario": scen})
        d = r.json()
        check("/chat via API: same shape", r.status_code == 200 and has_keys(d, CHAT_KEYS), r.text[:200])
        # JSON mode unsupported -> retried as prompt-only JSON, fenced output still parsed
        requests.post(BASE + "/debug/config", json={"openai_api": {"model": "mock-nojson"}}, timeout=10)
        r, _ = call("POST", "/llm/test", "llm/test no json mode")
        check("no response_format support -> plain retry works", r.status_code == 200, r.text[:200])
        # 404 model -> Korean message naming the model
        requests.post(BASE + "/debug/config", json={"openai_api": {"model": "no-such-model"}}, timeout=10)
        r, _ = call("POST", "/llm/test", "llm/test unknown model")
        print("   unknown model ->", r.status_code, r.json())
        check("unknown model -> Korean error naming it", r.status_code >= 400 and "no-such-model" in r.json().get("error", "") and HANGUL.search(r.json()["error"]))
        # 401 -> 'API 키를 확인해 주세요'
        requests.post(BASE + "/debug/config", json={"openai_api": {"model": "mock-free"}}, timeout=10)
        r, _ = call("POST", "/llm/test", "llm/test free tier")
        print("   FreeTierError ->", r.status_code, r.json())
        check("FreeTierError -> Korean explanation", r.status_code >= 400 and "OpenCode" in r.json().get("error", ""))
        # 429 -> usage-limit notice (nothing answers in its place), Retry-After parsed
        requests.post(BASE + "/debug/config", json={"openai_api": {"model": "mock-limit"}, "llm_provider": "openai_api"}, timeout=10)
        s = "Yesterday I eat rice with %d friends" % random.randint(10, 99)
        r, dt = call("POST", "/fix", "fix API 429", json={"lang": "en", "stage": 1, "text": s})
        h = call("GET", "/health")[0].json()
        fb = h.get("llm_fallback") or {}
        print("   /fix ->", r.json(), "(%.1fs)" % dt, "| llm_fallback:", fb)
        check("API 429 -> /fix still HTTP 200 (LanguageTool / empty fix)", r.status_code == 200 and has_keys(r.json(), FIX_KEYS), r.text[:200])
        check("API 429 -> llm_fallback active, Korean reason naming the API engine, nothing about a local AI",
              fb.get("active") is True and "API" in fb.get("reason", "") and bool(HANGUL.search(fb.get("reason", ""))) and "로컬" not in fb.get("reason", ""), fb)
        r, dt = call("POST", "/chat", "chat API 429", json={"lang": "en", "stage": 1, "history": [], "scenario": scen})
        check("API 429 -> /chat HTTP 429 with code ai_limit and a Korean message", r.status_code == 429 and r.json().get("code") == "ai_limit"
              and bool(HANGUL.search(r.json().get("error", ""))), r.text[:200])
        check("API 429 -> until from Retry-After (~10 min)", bool(fb.get("until")) and 300 < time.mktime(time.strptime(fb["until"][:19], "%Y-%m-%dT%H:%M:%S")) - time.time() < 700, fb.get("until"))
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
        # key must not appear anywhere the server writes
        lg = log_since(pos)
        cfg_txt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json"), encoding="utf-8").read()
        check("key not in server log / config.json / GET /llm", MOCK_KEY not in lg and MOCK_KEY not in cfg_txt and MOCK_KEY not in call("GET", "/llm")[0].text)
        check("mock saw the key on every call", MOCK_SEEN["auth_bad"] == 0 and MOCK_SEEN["auth_ok"] > 0, MOCK_SEEN)
        call("POST", "/llm", json={"provider": "openai_api", "api_key": ""})  # remove the fake key from secrets.json
        g = call("GET", "/llm")[0].json()
        if not stored.get(api.get("preset")) and not stored.get("openrouter"):
            check("fake key removed again -> has_key false", (g.get("openai_api") or {}).get("has_key") is False, (g.get("openai_api") or {}).get("has_key"))
    finally:
        srv.shutdown()
        try:
            if secrets_before is None:
                if os.path.exists(secrets_path):
                    os.remove(secrets_path)
            else:
                with open(secrets_path, "wb") as f:
                    f.write(secrets_before)
        except OSError:
            pass
        call("POST", "/llm", json={"provider": before or "opencode"})
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)


# ---------------------------------------------------------------------------------------------- 5. opencode
def test_opencode():
    print("\n== 5. opencode engine (`opencode serve` + free DeepSeek V4.1 Flash)")
    before = call("GET", "/health")[0].json().get("llm_provider")
    try:
        g = call("POST", "/llm", json={"provider": "opencode"})[0].json()
        opt = [o for o in g.get("options", []) if o.get("id") == "opencode"]
        check("GET /llm lists opencode first with its Korean label", bool(opt) and g["options"][0]["id"] == "opencode"
              and "무료" in opt[0]["label"], opt)
        if not (opt and opt[0].get("available")):
            print("   OpenCode is not installed: skipped")
            return
        conv = "oc-test-%d" % random.randint(1000, 9999)
        scen = {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."}
        hist, lat = [], []
        for said in (None, "Hi, can I get a latte?", "What does 'to go' mean?", "OK, to go please. How much is it?"):
            if said:
                hist.append({"role": "me", "text": said})
            r, dt = call("POST", "/chat", "opencode chat en turn %d" % len(lat),
                         json={"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": scen, "history": hist, "conv_id": conv, "skip_fix": True})
            d = r.json()
            lat.append(dt)
            print("   [%.1fs] %s -> %s" % (dt, said or "(opening)", json.dumps(d, ensure_ascii=False)[:260]))
            ok = r.status_code == 200 and has_keys(d, CHAT_KEYS) and d["reply"] and HANGUL.search(d["ko"])
            check("opencode chat en turn %d shape + Korean ko" % (len(lat) - 1), ok, r.text[:200])
            if not ok:
                break
            hist.append({"role": "ai", "text": d["reply"]})
        if len(lat) > 2:
            print("   warm turn latency: %s (mean %.1fs)" % (["%.1f" % x for x in lat[1:]], sum(lat[1:]) / len(lat[1:])))
        jscen = {"id": "konbini", "title": "편의점", "persona": "Tanaka, a cheerful convenience store clerk in Tokyo", "scene": "The learner buys snacks."}
        jh = []
        for said in (None, "「温めますか」はどういう意味ですか？"):
            if said:
                jh.append({"role": "me", "text": said})
            r, dt = call("POST", "/chat", "opencode chat ja", json={"lang": "ja", "stage": 1, "month": 1, "week": 2, "scenario": jscen,
                                                                     "history": jh, "conv_id": conv + "-ja", "skip_fix": True})
            d = r.json()
            print("   [%.1fs] ja %s -> %s" % (dt, said or "(opening)", json.dumps(d, ensure_ascii=False)[:300]))
            check("opencode chat ja: Japanese reply + hiragana reading", r.status_code == 200 and re.search(r"[ぁ-んァ-ン]", d.get("reply", ""))
                  and d.get("reading"), r.text[:200])
            jh.append({"role": "ai", "text": d.get("reply", "")})
        s = "Yesterday I buy %d apples in market" % random.randint(10, 99)
        r, dt = call("POST", "/fix", "opencode /fix", json={"lang": "en", "stage": 1, "text": s})
        print("   [%.1fs] /fix %r -> %s" % (dt, s, r.json()))
        check("opencode /fix answers", r.status_code == 200 and r.json().get("fix"), r.text[:200])
        r, dt = call("POST", "/lesson", "opencode /lesson ai", json={"lang": "en", "month": 1, "week": 1, "stage": 1, "source": "ai"})
        d = r.json()
        if r.status_code == 200:
            print("   [%.1fs] lesson: %s, %d exercises, types %s" % (dt, d.get("title"), len(d.get("exercises", [])),
                                                                    sorted({e.get("type") for e in d.get("exercises", [])})))
            for e in d.get("exercises", [])[:3]:
                print("      ", json.dumps(e, ensure_ascii=False)[:200])
        check("opencode /lesson source ai", r.status_code == 200 and len(d.get("exercises", [])) >= 4, r.text[:200])
        # free model limit -> 429 ai_limit and a Korean notice
        requests.post(BASE + "/debug/engine_limit", json={"message": "429 Too Many Requests: rate limit, retry in 600 seconds"}, timeout=10)
        r, dt = call("POST", "/chat", "opencode chat during limit", json={"lang": "en", "stage": 1, "scenario": scen, "history": [], "conv_id": conv + "-lim"})
        fb = call("GET", "/health")[0].json().get("llm_fallback") or {}
        print("   [%.1fs] chat during limit -> %s | llm_fallback %s" % (dt, r.status_code, fb))
        check("opencode limit -> chat HTTP 429, code ai_limit", r.status_code == 429 and r.json().get("code") == "ai_limit", r.text[:200])
        check("opencode limit -> Korean notice in llm_fallback.reason", fb.get("active") is True and "DeepSeek" in fb.get("reason", "") and "로컬" not in fb.get("reason", ""), fb)
    finally:
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
        call("POST", "/llm", json={"provider": before or "opencode"})


# ---------------------------------------------------------------------------------------------- 7. Ollama removed
LLM_STATES = ("ready", "not_connected", "not_installed", "blocked")
HEALTH_KEYS = ("ok", "stt", "tts", "tts_device", "llm", "llm_model", "llm_provider", "llm_state", "score", "phoneme", "tatoeba", "grammar",
               "llm_fallback", "song", "song_v", "song_identify")
LLM_KEYS = ("provider", "label", "state", "installed", "connected", "model", "login_url", "options", "llm_fallback", "notice", "openai_api")


def check_health_and_llm(h, g, tag):
    """The shapes of GET /health and GET /llm (docs/onetouch_install_design.md 3.4.3)."""
    check("%s: /health has every key" % tag, has_keys(h, HEALTH_KEYS), sorted(set(HEALTH_KEYS) - set(h)))
    check("%s: /health.llm_state is one of ready/not_connected/not_installed/blocked" % tag, h.get("llm_state") in LLM_STATES, h.get("llm_state"))
    check("%s: /health.llm is true exactly for ready/blocked" % tag, h.get("llm") is (h.get("llm_state") in ("ready", "blocked")), {k: h.get(k) for k in ("llm", "llm_state")})
    check("%s: /health.llm_model is the free DeepSeek id" % tag, h.get("llm_provider") != "opencode" or h.get("llm_model") == "deepseek-v4.1-flash-free", h.get("llm_model"))
    check("%s: /health.llm_fallback has active, until, reason" % tag, has_keys(h.get("llm_fallback"), ("active", "until", "reason")), h.get("llm_fallback"))
    check("%s: GET /llm has every key" % tag, has_keys(g, LLM_KEYS), sorted(set(LLM_KEYS) - set(g)))
    opts = g.get("options") or []
    check("%s: GET /llm.options is one opencode entry with a Korean label, no ollama" % tag,
          len(opts) == 1 and opts[0].get("id") == "opencode" and bool(HANGUL.search(opts[0].get("label", ""))) and "ollama" not in json.dumps(g).lower().replace("ollama_removed", ""), opts)
    check("%s: GET /llm.state / installed / connected / login_url" % tag, g.get("state") == h.get("llm_state") and isinstance(g.get("installed"), bool)
          and isinstance(g.get("connected"), bool) and g.get("login_url", "").startswith("https://"), {k: g.get(k) for k in ("state", "installed", "connected", "login_url")})
    check("%s: GET /llm.notice is '' or 'ollama_removed'" % tag, g.get("notice") in ("", "ollama_removed"), g.get("notice"))
    check("%s: GET /llm.openai_api is still there (developer engine)" % tag, isinstance(g.get("openai_api"), dict) and "presets" in g["openai_api"], list((g.get("openai_api") or {}))[:6])


def test_ollama_removed():
    print("\n== 7. Ollama removed: /health and GET /llm shapes, POST /llm, /chat without a connection, features that need no AI")
    requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
    requests.post(BASE + "/debug/config", json={"llm_provider": "opencode"}, timeout=10)
    h = call("GET", "/health")[0].json()
    g = call("GET", "/llm")[0].json()
    check_health_and_llm(h, g, "7")
    r, _ = call("POST", "/llm", json={"provider": "ollama"})
    check("POST /llm ollama -> 400, code engine_removed, Korean message", r.status_code == 400 and r.json().get("code") == "engine_removed"
          and bool(HANGUL.search(r.json().get("error", ""))), r.text[:200])
    r, _ = call("POST", "/llm", json={"provider": "zzz"})
    check("POST /llm with an unknown engine -> 400 (no engine_removed code)", r.status_code == 400 and r.json().get("code") != "engine_removed", r.text[:200])
    r, _ = call("POST", "/llm", json={"provider": "opencode"})
    check("POST /llm opencode -> 200 with the GET /llm shape", r.status_code == 200 and has_keys(r.json(), LLM_KEYS), r.text[:200])
    state = call("GET", "/health")[0].json().get("llm_state")
    scen = {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."}
    body = {"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": scen, "history": [], "conv_id": "b2-%d" % random.randint(1000, 9999)}
    if state in ("not_connected", "not_installed"):
        r, dt = call("POST", "/chat", "chat %s" % state, json=body)
        d = r.json()
        print("   /chat while %s -> %s %s" % (state, r.status_code, json.dumps(d, ensure_ascii=False)[:160]))
        check("%s: first /chat turn -> 503, code ai_%s, Korean message" % (state, state), r.status_code == 503 and d.get("code") == "ai_" + state
              and bool(HANGUL.search(d.get("error", ""))), r.text[:200])
        check("%s: a refused chat leaves no limit notice" % state, call("GET", "/health")[0].json()["llm_fallback"]["active"] is False)
    elif state == "ready":
        r, dt = call("POST", "/chat", "chat ready", json=body)
        check("ready: first /chat turn -> 200, same shape", r.status_code == 200 and has_keys(r.json(), CHAT_KEYS), r.text[:200])
    else:
        print("   /health.llm_state is %r: the /chat check is skipped" % state)
    # nothing below needs an AI
    r, dt = call("POST", "/lesson", "lesson tatoeba (no AI)", json={"lang": "en", "month": 1, "week": 1, "stage": 1})
    d = r.json()
    check("/lesson (rule-based Tatoeba) -> 200 with exercises", r.status_code == 200 and len(d.get("exercises", [])) >= 4, r.text[:200])
    r, dt = call("POST", "/fix", "fix (no AI)", json={"lang": "en", "stage": 1, "text": "He go to school yesterday", "prev_ai": ""})
    check("/fix with a grammar mistake -> 200 and a fix (LanguageTool)", r.status_code == 200 and "went" in r.json().get("fix", ""), r.text[:200])
    r, dt = call("POST", "/tts", "tts for score", json={"text": "Hello, how are you?", "lang": "en", "speed": 1.0})
    if check("/tts -> audio for the score check", r.status_code == 200 and r.headers.get("content-type", "").startswith("audio/wav"), r.status_code):
        import base64
        r, dt = call("POST", "/score", "score (no AI)", json={"lang": "en", "target": "Hello, how are you?", "reading": "", "audio_b64": base64.b64encode(r.content).decode()})
        d = r.json()
        check("/score -> 200 with a score", r.status_code == 200 and isinstance(d.get("score"), (int, float)), r.text[:200])


# ---------------------------------------------------------------------------------------------- 8. old config, own server
def test_spawn_legacy():
    import hashlib
    import socket
    import subprocess
    import tempfile
    import threading
    print("\n== 8. old config.json with the ollama keys, own test server: migration, notice, file unchanged, zero Ollama connections")
    here = os.path.dirname(os.path.abspath(__file__))
    lsn = socket.socket()
    lsn.bind(("127.0.0.1", 0))   # a port of its own (other test runs use 18851-18859 and sometimes probe them: they would be counted)
    LPORT = lsn.getsockname()[1]
    lsn.listen(8)
    seen = {"n": 0}

    def accept_loop():
        while True:
            try:
                c, _ = lsn.accept()
            except OSError:
                return
            seen["n"] += 1
            seen.setdefault("peers", []).append(c.getpeername())
            c.close()

    threading.Thread(target=accept_loop, daemon=True).start()
    port = None
    for p in range(18853, 18860):
        sk = socket.socket()
        try:
            sk.bind(("127.0.0.1", p))
            port = p
            sk.close()
            break
        except OSError:
            sk.close()
    tmp = tempfile.mkdtemp(prefix="b2legacy_")
    proc = None
    try:
        if port is None:
            check("a free test-server port in 18853..18859", False)
            return
        cfgp = os.path.join(tmp, "config.json")
        legacy = {"port": 8770, "llm_provider": "ollama", "llm_model": "qwen3:8b", "ollama_url": "http://127.0.0.1:%d" % LPORT,
                  "keep_alive": "30m", "num_ctx": 6144, "stt": {"model": "small", "device": "cpu", "compute_type": "int8"}}
        with open(cfgp, "w", encoding="utf-8") as f:
            json.dump(legacy, f, indent=2)
        sha0 = hashlib.sha256(open(cfgp, "rb").read()).hexdigest()
        fake = sys.argv[sys.argv.index("--fake-opencode") + 1] if "--fake-opencode" in sys.argv else os.path.join(tmp, "no-such-opencode.exe")
        env = dict(os.environ, HOEHWA_TEST_HOOKS="1", HOEHWA_OPENCODE_EXE=fake, APPDATA=os.path.join(tmp, "appdata"))
        env["PATH"] = os.pathsep.join(x for x in env.get("PATH", "").split(os.pathsep) if "opencode" not in x.lower() and not x.lower().endswith("npm"))
        proc = subprocess.Popen([sys.executable, "-X", "utf8", os.path.join(here, "server.py"), "--port", str(port), "--tag", "b2legacy",
                                 "--stt-cpu", "--config", cfgp], cwd=here, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = "http://127.0.0.1:%d" % port
        up = False
        for _ in range(90):
            time.sleep(2)
            try:
                if requests.get(base + "/health", timeout=3).status_code == 200:
                    up = True
                    break
            except requests.RequestException:
                pass
        if not check("own test server on %d is up (pid %d)" % (port, proc.pid), up):
            return

        def c(method, path, **kw):
            return requests.request(method, base + path, timeout=300, **kw)

        g = c("GET", "/llm").json()
        h = c("GET", "/health").json()
        print("   /llm:", {k: g.get(k) for k in ("provider", "state", "notice")})
        check("old config 'ollama' -> GET /llm.provider is opencode, notice ollama_removed", g.get("provider") == "opencode" and g.get("notice") == "ollama_removed", g)
        check("old config -> /health.llm_provider opencode, llm_model deepseek", h.get("llm_provider") == "opencode" and h.get("llm_model") == "deepseek-v4.1-flash-free", h)
        check_health_and_llm(h, g, "8")
        r = requests.post(base + "/llm/notice/ack", json={}, timeout=30)
        check("POST /llm/notice/ack -> 200", r.status_code == 200 and r.json().get("ok") is True, r.text[:200])
        check("after the ack the notice is ''", c("GET", "/llm").json().get("notice") == "")
        state = h.get("llm_state")
        if state in ("not_installed", "not_connected", "ready"):   # never "blocked" here, and the real OpenCode is hidden (fake path)
            scen = {"id": "cafe", "persona": "Emma, a barista", "scene": "ordering"}
            r = c("POST", "/chat", json={"lang": "en", "stage": 1, "history": [], "scenario": scen, "conv_id": "b2legacy"})
            check("old config: /chat answers by the AI state (%s)" % state, (r.status_code == 200) if state == "ready" else (r.status_code == 503 and r.json().get("code") == "ai_" + state), r.text[:160])
        c("POST", "/fix", json={"lang": "en", "stage": 1, "text": "He go to school yesterday", "prev_ai": ""})
        c("POST", "/lesson", json={"lang": "en", "month": 1, "week": 1, "stage": 1})
        c("POST", "/llm", json={"provider": "opencode"})
        c("GET", "/llm")
        c("GET", "/health")
        check("Ollama listener on 127.0.0.1:%d got ZERO connections" % LPORT, seen["n"] == 0, seen.get("peers"))
        sha1 = hashlib.sha256(open(cfgp, "rb").read()).hexdigest()
        check("the test server never wrote its config file (SHA-256 unchanged, also after the ack)", sha0 == sha1)
        check("no config.json.tmp was left", not os.path.exists(cfgp + ".tmp"))
    finally:
        if proc is not None:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        lsn.close()
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except requests.exceptions.ConnectionError:
        print("Cannot reach the backend at", BASE)
        sys.exit(2)
