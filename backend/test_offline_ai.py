# -*- coding: utf-8 -*-
"""Tests for the "less AI" features against a RUNNING test server started with the test hooks on:

    set HOEHWA_TEST_HOOKS=1
    .venv\\Scripts\\python.exe server.py --port 8787 --tag gramcache --stt-cpu
    .venv\\Scripts\\python.exe test_offline_ai.py --base http://127.0.0.1:8787 [--tag gramcache]

1. LanguageTool grammar correction (/fix with AI polish off = LanguageTool only), English + Japanese
2. /fix result cache: the second identical call is a cache hit (timing + server log line)
3. usage limit of the remote engine (simulated) -> answered by the local model, /health.llm_fallback.active
4. openai_api engine against a mock OpenAI-compatible server
5. opencode engine (opencode serve + free DeepSeek V4.1 Flash): en/ja chat latency, /fix, /lesson source ai, limit fallback
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

BASE = "http://127.0.0.1:8787"
if "--base" in sys.argv:
    BASE = sys.argv[sys.argv.index("--base") + 1]
TAG = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else "gramcache"
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "server-%s.log" % TAG)
HANGUL = re.compile(r"[가-힣]")

results, timings = [], []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


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
    print("  health:", json.dumps({k: h.get(k) for k in ("llm", "llm_provider", "grammar", "llm_fallback")}, ensure_ascii=False))
    check("health has grammar=true", h.get("grammar") is True, h.get("grammar"))
    check("health has llm_fallback {active, until, reason}", isinstance(h.get("llm_fallback"), dict)
          and set(h["llm_fallback"]) == {"active", "until", "reason"}, h.get("llm_fallback"))
    r = requests.post(BASE + "/debug/config", json={}, timeout=10)
    if not check("test hooks enabled (HOEHWA_TEST_HOOKS=1)", r.status_code == 200, r.status_code):
        return 2
    requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)

    # ------------------------------------------------------------------ 1. LanguageTool only
    print("\n== 1. LanguageTool only (AI polish off): English")
    requests.post(BASE + "/debug/config", json={"grammar_llm_polish": False}, timeout=10)
    for i, (s, need) in enumerate(EN):
        r, dt = call("POST", "/fix", "fix LT en %d" % i, json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   %-28s -> %-32s %.2fs | %s" % (s, d.get("fix"), dt, d.get("fix_ko")))
        ok = r.status_code == 200 and set(d) == {"fix", "fix_ko"} and all(n.lower() in d["fix"].lower() for n in need)
        check("LT fixes %r" % s, ok and bool(HANGUL.search(d["fix_ko"])), d)
        check("LT %r is fast (< 2 s)" % s, dt < 2.0 or i == 0, "%.2fs" % dt)
    print("\n== 1b. LanguageTool only: Japanese (LanguageTool's Japanese rules are few)")
    for i, s in enumerate(JA):
        r, dt = call("POST", "/fix", "fix LT ja %d" % i, json={"lang": "ja", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   %-14s -> %-16s %.2fs | %s" % (s, d.get("fix"), dt, d.get("fix_ko")))
    check("LT ja fixes これわ -> これは", "これは" in (call("POST", "/fix", "fix LT ja korewa", json={"lang": "ja", "stage": 1, "text": JA[0]})[0].json().get("fix") or ""))

    print("\n== 1c. LanguageTool + AI polish (default)")
    requests.post(BASE + "/debug/config", json={"grammar_llm_polish": True}, timeout=10)
    r, dt = call("POST", "/fix", "fix LT+AI en", json={"lang": "en", "stage": 1, "text": "Yesterday he go to cafe with his friend", "prev_ai": ""})
    d = r.json()
    print("   -> %s | %s (%.1fs)" % (d.get("fix"), d.get("fix_ko"), dt))
    check("LT+AI fix has went", r.status_code == 200 and "went" in (d.get("fix") or ""), d)

    # ------------------------------------------------------------------ 2. cache
    print("\n== 2. /fix cache (sentence LanguageTool does not catch -> AI)")
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
    check("cache: second call much faster (< 1 s)", dt2 < 1.0 and dt2 < dt1 / 3, "%.2fs vs %.2fs" % (dt1, dt2))
    check("cache: log shows MISS then HIT for fix", "llm cache MISS fix" in lg and "llm cache HIT fix" in lg)

    # ------------------------------------------------------------------ 3. remote engine limit -> local
    print("\n== 3. simulated usage limit of the remote engine (OpenCode free DeepSeek) -> local model")
    h = call("GET", "/health")[0].json()
    if h.get("llm_provider") == "ollama":
        print("   provider is ollama: the fallback does not apply (select the opencode engine to test it)")
    else:
        reset = int(time.time()) + 1800
        requests.post(BASE + "/debug/engine_limit", json={"message": "usage limit reached|%d" % reset}, timeout=10)
        pos = log_size()
        # first the per-conversation OpenCode chat session path hits the limit
        scen = {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."}
        r, dt = call("POST", "/chat", "chat during engine limit (local)", json={"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": scen,
                                                                           "history": [], "conv_id": "fallback-test-%d" % reset})
        d = r.json()
        print("   /chat opening -> %s (%.1fs)" % (json.dumps(d, ensure_ascii=False)[:200], dt))
        check("limit: /chat answers with the same shape", r.status_code == 200 and set(d) == {"reply", "reading", "ko", "fix", "fix_ko", "suggest"}, r.text[:200])
        # then a JSON call (/fix, sentence LanguageTool does not catch) goes straight to local
        s = "Yesterday I eat pizza with %d friends" % random.randint(10, 99)
        r, dt = call("POST", "/fix", "fix during engine limit (local)", json={"lang": "en", "stage": 1, "text": s, "prev_ai": ""})
        d = r.json()
        print("   /fix %r -> %s (%.1fs)" % (s, d, dt))
        check("limit: /fix still answers (HTTP 200, same shape)", r.status_code == 200 and set(d) == {"fix", "fix_ko"}, r.text[:200])
        h = call("GET", "/health")[0].json()
        fb = h.get("llm_fallback") or {}
        print("   health.llm_fallback:", fb)
        check("limit: /health.llm_fallback.active true", fb.get("active") is True, fb)
        check("limit: until parsed from the message (~30 min)", bool(fb.get("until")) and abs(
            time.mktime(time.strptime(fb["until"][:19], "%Y-%m-%dT%H:%M:%S")) - reset) < 5, fb.get("until"))
        g = call("GET", "/llm")[0].json()
        check("limit: GET /llm has llm_fallback", (g.get("llm_fallback") or {}).get("active") is True, g.get("llm_fallback"))
        lg = log_since(pos)
        for line in lg.splitlines():
            if "unusable" in line or "call failed" in line or "chat failed" in line or "ollama call" in line:
                print("   log:", line[20:].strip()[:200])
        check("limit: log shows the switch to the local model", "using local model" in lg and "ollama call" in lg)
        if h.get("llm_provider") == "opencode":
            check("limit: the OpenCode chat session path fell back too", "opencode chat failed (limit)" in lg)
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
        h = call("GET", "/health")[0].json()
        check("limit cleared: llm_fallback.active false", (h.get("llm_fallback") or {}).get("active") is False)

    if "--no-api" not in sys.argv:
        test_openai_api()
    if "--no-opencode" not in sys.argv:
        test_opencode()

    print("\n================ SUMMARY ================")
    for k, v in timings:
        print("%-40s %8.2f" % (k, v))
    failed = [n for n, ok in results if not ok]
    print("\n%d checks, %d passed, %d failed" % (len(results), len(results) - len(failed), len(failed)))
    for n in failed:
        print("  FAILED:", n)
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------- 4. openai_api
MOCK_PORT = 8799
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
    print("\n== 4. openai_api engine (mock OpenAI-compatible server on :%d, then the real OpenCode Zen /models)" % MOCK_PORT)
    before = call("GET", "/health")[0].json().get("llm_provider")
    srv = start_mock()
    pos = log_size()
    try:
        g = call("GET", "/llm")[0].json()
        api = g.get("openai_api") or {}
        check("GET /llm lists openai_api with presets", any(o.get("id") == "openai_api" for o in g.get("options", []))
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
        check("/chat via API: same shape", r.status_code == 200 and set(d) == {"reply", "reading", "ko", "fix", "fix_ko", "suggest"}, r.text[:200])
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
        # 429 -> usage-limit fallback to local, Retry-After parsed
        requests.post(BASE + "/debug/config", json={"openai_api": {"model": "mock-limit"}, "llm_provider": "openai_api"}, timeout=10)
        s = "Yesterday I eat rice with %d friends" % random.randint(10, 99)
        r, dt = call("POST", "/fix", "fix API 429 -> local", json={"lang": "en", "stage": 1, "text": s})
        h = call("GET", "/health")[0].json()
        fb = h.get("llm_fallback") or {}
        print("   /fix ->", r.json(), "(%.1fs)" % dt, "| llm_fallback:", fb)
        check("API 429 -> /fix answered locally (HTTP 200)", r.status_code == 200 and set(r.json()) == {"fix", "fix_ko"}, r.text[:200])
        check("API 429 -> llm_fallback active, Korean reason", fb.get("active") is True and "API" in fb.get("reason", "")
              and "로컬 AI" in fb.get("reason", ""), fb)
        check("API 429 -> until from Retry-After (~10 min)", bool(fb.get("until")) and 300 < time.mktime(time.strptime(fb["until"][:19], "%Y-%m-%dT%H:%M:%S")) - time.time() < 700, fb.get("until"))
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
        # key must not appear anywhere the server writes
        lg = log_since(pos)
        cfg_txt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json"), encoding="utf-8").read()
        check("key not in server log / config.json / GET /llm", MOCK_KEY not in lg and MOCK_KEY not in cfg_txt and MOCK_KEY not in call("GET", "/llm")[0].text)
        check("mock saw the key on every call", MOCK_SEEN["auth_bad"] == 0 and MOCK_SEEN["auth_ok"] > 0, MOCK_SEEN)
        # real OpenCode Zen (key from `opencode auth login`), free model list only; free-tier chat is refused outside OpenCode
        call("POST", "/llm", json={"provider": "openai_api", "api_key": ""})  # remove the fake key from secrets.json
        r, _ = call("POST", "/llm", json={"provider": "openai_api", "preset": "opencode_zen", "key_source": "opencode"})
        if (r.json().get("openai_api") or {}).get("has_key"):
            r, dt = call("GET", "/llm/models?preset=opencode_zen&key_source=opencode", "opencode zen /models")
            ms = r.json().get("models", []) if r.status_code == 200 else []
            print("   OpenCode Zen models (%d, %.1fs): free=%s" % (len(ms), dt, [m["id"] for m in ms if m["free"]]))
            check("OpenCode Zen /models with the OpenCode login key", r.status_code == 200 and len(ms) > 5, r.text[:200])
            call("POST", "/llm", json={"provider": "openai_api", "model": "deepseek-v4.1-flash-free"})
            r, dt = call("POST", "/llm/test", "opencode zen free model test")
            print("   deepseek-v4.1-flash-free ->", r.status_code, r.json(), "(%.1fs)" % dt)
        else:
            print("   no OpenCode login key: skipped the real OpenCode Zen check")
    finally:
        srv.shutdown()
        call("POST", "/llm", json={"provider": before or "ollama"})
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
            ok = r.status_code == 200 and set(d) == {"reply", "reading", "ko", "fix", "fix_ko", "suggest"} and d["reply"] and HANGUL.search(d["ko"])
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
        # free model limit -> local fallback with a Korean notice
        requests.post(BASE + "/debug/engine_limit", json={"message": "429 Too Many Requests: rate limit, retry in 600 seconds"}, timeout=10)
        r, dt = call("POST", "/chat", "opencode chat during limit (local)", json={"lang": "en", "stage": 1, "scenario": scen, "history": [], "conv_id": conv + "-lim"})
        fb = call("GET", "/health")[0].json().get("llm_fallback") or {}
        print("   [%.1fs] chat during limit -> %s | llm_fallback %s" % (dt, r.status_code, fb))
        check("opencode limit -> chat answered locally, same shape", r.status_code == 200 and set(r.json()) == {"reply", "reading", "ko", "fix", "fix_ko", "suggest"}, r.text[:200])
        check("opencode limit -> Korean notice in llm_fallback.reason", fb.get("active") is True and "DeepSeek" in fb.get("reason", "") and "로컬 AI" in fb.get("reason", ""), fb)
    finally:
        requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=10)
        call("POST", "/llm", json={"provider": before or "ollama"})


if __name__ == "__main__":
    try:
        sys.exit(main())
    except requests.exceptions.ConnectionError:
        print("Cannot reach the backend at", BASE)
        sys.exit(2)
