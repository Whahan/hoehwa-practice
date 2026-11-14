# -*- coding: utf-8 -*-
"""Tests for POST /fix "private": true (v1.7.0 C2: the diary's sentences must not stay in the cache, the logs or any file).
Runs server.py IN PROCESS (FastAPI TestClient) with FAKE engines: no network, no OpenCode, nothing on a port.

    .venv\\Scripts\\python.exe test_fix_private.py [--lt-dir <...\\tools\\languagetool>]

Every request carries a canary (ZZ_MARK_9731 + a Japanese / English sentence). After the private requests the canary must be
in NONE of: the llm cache DB (rows unchanged, bytes), the collected log records (all levels, with tracebacks), the temp folder,
the real backend\\logs and backend\\cache, what the process printed. The same requests with private false / missing are the
positive control: the cache does store them and the log does repeat them (a scanner that never finds anything is not trusted).
--lt-dir: a real LanguageTool install (the folder that holds LanguageTool-x.y) -> section 8 runs the real JVM on a free
port and scans its log; without it that section prints "SKIP" (미검증).
Writes only under a temp folder. Exit code 1 on any FAIL or on a section that could not run when --lt-dir was given.
"""
import contextlib
import io
import json
import logging
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

TMP = tempfile.mkdtemp(prefix="hoehwa_fixprivate_")
os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(TMP, "espeak")
LT_DIR_ARG = sys.argv[sys.argv.index("--lt-dir") + 1] if "--lt-dir" in sys.argv else ""
sys.argv = [sys.argv[0], "--tag", "unit_fixprivate"]

import llm_cache
DB_PRIVATE = os.path.join(TMP, "db_private", "llm_cache.sqlite")   # used by the private requests: must stay free of the canary
DB_PUBLIC = os.path.join(TMP, "db_public", "llm_cache.sqlite")     # used by the positive controls: it does hold the canary
llm_cache.DB_PATH = DB_PRIVATE
llm_cache._conn = None
import llm_common
import llm_opencode
import llm_api
import grammar
import server
from fastapi.testclient import TestClient

MARK = "ZZ_MARK_9731"
JA_TEXT = MARK + "きのう ともだちと えいがをみた。"
JA_FIX = MARK + "昨日、友達と映画を見ました。"
EN_TEXT = MARK + " yesterday i go to school with my friend"
EN_FIX = MARK + " Yesterday I went to school with my friend."
TOKENS = [MARK, "えいがをみた", "友達と映画", "went to school", "go to school with"]   # anything of the sentence, not only the marker
KO_WHY = "과거형과 정중체로 맞췄어요."
HANGUL = re.compile(r"[가-힣]")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)[:300]) if detail != "" else ""))
    return bool(cond)


def selfcheck(name, cond, detail=""):
    """a checker that was fed a WRONG input must say so: cond is True when it did"""
    results.append((name, bool(cond)))
    print("  [%s] selfcheck FAIL-as-expected: %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)[:200]) if detail != "" else ""))


# ------------------------------------------------------------------------------------------------ collectors
class Collect(logging.Handler):
    """every record of every logger, formatted WITH its traceback"""
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []
        self.fmt = logging.Formatter("%(levelname)s %(name)s %(message)s")

    def emit(self, record):
        try:
            self.lines.append(self.fmt.format(record))
        except Exception as e:   # a record that cannot be formatted is a finding too
            self.lines.append("UNFORMATTABLE %r" % (e,))


COLLECT = Collect()
logging.getLogger().addHandler(COLLECT)
logging.getLogger().setLevel(logging.DEBUG)
server.log.setLevel(logging.DEBUG)
grammar.init(log=server.log)


def found(blob):
    """tokens of the canary that appear in a str / bytes"""
    out = []
    for t in TOKENS:
        if isinstance(blob, bytes):
            if t.encode("utf-8") in blob:
                out.append(t)
        elif t in blob:
            out.append(t)
    return out


def log_hits():
    return found("\n".join(COLLECT.lines))


def cache_blob():
    """all bytes of the cache DB and its WAL / SHM (closed first so the WAL is checkpointed into the DB file)"""
    with llm_cache._lock:
        if llm_cache._conn is not None:
            llm_cache._conn.close()
            llm_cache._conn = None
    blob = b""
    for suffix in ("", "-wal", "-shm"):
        p = llm_cache.DB_PATH + suffix
        if os.path.isfile(p):
            with open(p, "rb") as f:
                blob += f.read()
    return blob


def cache_count():
    with llm_cache._lock:
        return llm_cache._db().execute("SELECT COUNT(*) FROM llm_cache").fetchone()[0]


def scan_folder(root, limit=64 * 1024 * 1024):
    """canary tokens found in any file under root (file names too)"""
    hits = []
    for d, _dirs, files in os.walk(root):
        for fn in files:
            p = os.path.join(d, fn)
            if found(fn):
                hits.append((p, "name"))
            try:
                if os.path.getsize(p) > limit:
                    continue
                with open(p, "rb") as f:
                    t = found(f.read())
                if t:
                    hits.append((p, t))
            except OSError:
                pass
    return hits


# ------------------------------------------------------------------------------------------------ fake engines
class Engine:
    """replaces llm_opencode.call_json / llm_api.call_json (the AI engines: server._remote_json, _opencode_json, remote_failure
    and llm_json run for real) and grammar.correct (LanguageTool)"""
    def __init__(self):
        self.reset()

    def reset(self):
        self.ai = lambda messages: {"fix": "", "fix_ko": ""}     # callable(messages) -> dict | raises
        self.lt = None                                            # None | dict | Exception | callable(lang, text)
        self.ai_calls = []
        self.lt_calls = []

    def remote(self, cfg, messages, schema, temperature=0.7, timeout=180):
        self.ai_calls.append(messages)
        return self.ai(messages), 0.01, {"s": 0.01}

    def correct(self, lang, text, quiet=False):
        self.lt_calls.append((lang, text, quiet))
        lt = self.lt
        if callable(lt):
            return lt(lang, text)
        if isinstance(lt, BaseException):
            raise lt
        return lt


ENG = Engine()
llm_opencode.call_json = ENG.remote
llm_api.call_json = ENG.remote
llm_api.has_key = lambda s: True
PROVIDER = ["opencode"]
server.llm_provider = lambda: PROVIDER[0]
REAL_CORRECT = grammar.correct
grammar.correct = ENG.correct
server.CFG["grammar_llm_polish"] = True

# FastAPI: the loopback client, errors become responses (500) like in the real server
CLIENT = TestClient(server.app, raise_server_exceptions=False, client=("127.0.0.1", 50000))


def post(body):
    buf_o, buf_e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf_o), contextlib.redirect_stderr(buf_e):
        r = CLIENT.post("/fix", json=body)
    PRINTED.append(buf_o.getvalue() + buf_e.getvalue())
    return r


PRINTED = []


def req(lang, text, private=True, **extra):
    body = {"lang": lang, "stage": 1, "text": text, "prev_ai": ""}
    if private is not None:
        body["private"] = private
    body.update(extra)
    return post(body)


# the four paths x two languages: (name, lt, ai)
def ai_fix(fix, ko=KO_WHY):
    return lambda messages: {"fix": fix, "fix_ko": ko}


def lt_result(fix, ko="문법을 고쳤어요."):
    return {"fix": fix, "fix_ko": ko, "changes": [{"from": "a", "to": "b", "rule": "R_TEST", "category": "GRAMMAR", "ko": ko}]}


def paths(lang):
    text, fix = (JA_TEXT, JA_FIX) if lang == "ja" else (EN_TEXT, EN_FIX)
    lt_fix = fix.replace("。", "").replace(".", "") + "_lt"
    return [
        ("LT fix + AI polish", lt_result(lt_fix), ai_fix(fix), fix),
        ("LT fix + AI agrees", lt_result(fix), ai_fix(fix), fix),
        ("LT none + AI fix (AI alone)", None, ai_fix(fix), fix),
        ("LT fix only (AI polish off)", lt_result(fix), ai_fix("never used"), fix),
        ("LT none + AI says nothing to fix", None, ai_fix("", ""), ""),
    ]


def run_path(lang, lt, ai, private, polish=True):
    use_db(private is not True)
    ENG.reset()
    ENG.lt, ENG.ai = lt, ai
    server.CFG["grammar_llm_polish"] = polish
    text = JA_TEXT if lang == "ja" else EN_TEXT
    r = req(lang, text, private=private)
    server.CFG["grammar_llm_polish"] = True
    return r


# ------------------------------------------------------------------------------------------------ 1. selfchecks of the scanners
def test_selfcheck():
    print("== 0. the scanners can fail: wrong input -> they find the canary")
    n0 = len(COLLECT.lines)
    server.log.info("planted %s in a log line", MARK)
    selfcheck("log collector finds a planted marker", MARK in log_hits())
    server.log.info("planted again %r", JA_TEXT)
    try:
        raise ValueError(EN_TEXT)
    except ValueError:
        server.log.exception("planted traceback")
    selfcheck("log collector finds a marker inside a traceback", any("Traceback" in l and MARK in l for l in COLLECT.lines[n0:]))
    del COLLECT.lines[n0:]
    check("(the planted lines are removed again)", not log_hits())
    d = os.path.join(TMP, "selfcheck")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "x.txt"), "wb") as f:
        f.write(("abc " + JA_TEXT + " def").encode("utf-8"))
    selfcheck("folder scanner finds a planted file", bool(scan_folder(d)))
    os.makedirs(os.path.join(d, "sub"), exist_ok=True)
    open(os.path.join(d, "sub", "a" + MARK + ".log"), "w").close()
    selfcheck("folder scanner finds a planted file NAME", any(h[1] == "name" for h in scan_folder(d)))
    import shutil
    shutil.rmtree(d)
    use_db(True)
    key = llm_cache.make_key("fix", "opencode", "m", {}, [{"content": JA_TEXT}], {})
    n = cache_count()
    llm_cache.put(key, "fix", "opencode", "m", {"fix": JA_FIX})
    selfcheck("cache scanner finds a planted row", bool(found(cache_blob())) and cache_count() == n + 1)
    use_db(False)
    check("(the planted row is gone with its DB file)", cache_count() == 0 and not found(cache_blob()))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        print(JA_TEXT)
    selfcheck("stdout capture sees a printed marker", bool(found(buf.getvalue())))


# ------------------------------------------------------------------------------------------------ 2. responses (C2-6, C2-2)
HIRA = re.compile(r"[ぁ-ゖゝゞー、。，．・…！？!?.,:;~〜\-「」『』（）()\[\]\"'_＿\s]*")
KATA = re.compile(r"[ァ-ヶー、。，．・…！？!?.,:;~〜\-「」『』（）()\[\]\"'_＿\s]*")


def test_response():
    print("== 1. responses: reading / pron, and no new keys without private")
    use_db(True)    # some requests here are not private: their cache goes to the public DB
    clean_fix = "昨日、友達と映画を見ました。"
    ENG.reset()
    ENG.ai = ai_fix(clean_fix)
    r = req("ja", "きのう ともだちと えいがをみた。")
    d = r.json()
    check("ja private -> 200 and the 4 keys", r.status_code == 200 and sorted(d) == ["fix", "fix_ko", "pron", "reading"], d)
    check("ja private: fix is the AI's sentence", d.get("fix") == clean_fix, d.get("fix"))
    check("ja private: reading is hiragana only", bool(d.get("reading")) and HIRA.fullmatch(d["reading"]) is not None, d.get("reading"))
    check("ja private: pron is katakana only", bool(d.get("pron")) and KATA.fullmatch(d["pron"]) is not None, d.get("pron"))
    check("ja private: reading of 昨日、友達と映画を見ました。 is right", d.get("reading") == "きのう、ともだちとえいがをみました。", d.get("reading"))
    ENG.ai = ai_fix("I went to school.")
    d = req("en", "i go to school").json()
    check("en private: reading and pron are empty strings", d.get("reading") == "" and d.get("pron") == "" and d.get("fix") == "I went to school.", d)
    ENG.ai = ai_fix("", "")
    d = req("ja", "きのうは あめでした。").json()
    check("ja private, nothing to fix: fix '', reading '', pron ''", d == {"fix": "", "fix_ko": "", "reading": "", "pron": ""}, d)
    # a fix that holds Hangul is refused by the existing validation (it asks again, then gives up): fix == ""
    ENG.reset()
    ENG.ai = ai_fix("I went 학교 to school.")
    d = req("en", "i go to school").json()
    check("en: a fix with Hangul is rejected -> fix ''", d.get("fix") == "" and d.get("reading") == "" and d.get("pron") == "", d)
    ENG.ai = ai_fix("안녕하세요 학교")
    d = req("ja", "きのう がっこうにいった。").json()
    check("ja: a fix without kana or kanji (Hangul only) is rejected -> fix ''", d.get("fix") == "" and d.get("reading") == "" and d.get("pron") == "", d)
    # mixed Latin letters in a Japanese fix never reach reading / pron
    ENG.ai = ai_fix("私は iPhone を買いました。")
    d = req("ja", "わたしは あいふぉん を かった。").json()
    check("ja: Latin letters in the fix are not in reading / pron", d.get("fix") and HIRA.fullmatch(d["reading"]) and KATA.fullmatch(d["pron"]) and not re.search(r"[A-Za-z]", d["reading"] + d["pron"]), d)
    # without private the answer has exactly the old two keys
    for pv in (None, False):
        ENG.reset()
        ENG.ai = ai_fix(clean_fix)
        r = req("ja", "きのう ともだちと えいがをみた。", private=pv)
        check("private=%r -> keys fix, fix_ko only" % (pv,), r.status_code == 200 and sorted(r.json()) == ["fix", "fix_ko"], r.json())
    # the LanguageTool-only answer keeps its explanation (private or not)
    ENG.reset()
    ENG.lt = lt_result("I went to school.", "과거형을 써요.")
    server.CFG["grammar_llm_polish"] = False
    d1 = req("en", "i go to school", private=True).json()
    d2 = req("en", "i go to school", private=False).json()
    server.CFG["grammar_llm_polish"] = True
    check("LT-only answer: same fix and fix_ko with / without private", d1["fix"] == d2["fix"] and d1["fix_ko"] == d2["fix_ko"] == "과거형을 써요.", (d1, d2))


# ------------------------------------------------------------------------------------------------ 3. C2-3 / C2-4: canary paths
def test_canary():
    print("== 2. canary: private requests leave nothing in the cache / log / output; the same requests without private do")
    for lang in ("ja", "en"):
        for name, lt, ai, expect_fix in paths(lang):
            polish = "AI polish off" not in name
            # --- private: nothing stored, nothing logged
            clear_state(False)
            r = run_path(lang, lt, ai, True, polish)
            d = r.json()
            hits = log_hits()
            check("[%s] %s private: 200 and an answer" % (lang, name), r.status_code == 200 and "fix" in d, d)
            check("[%s] %s private: fix is as expected" % (lang, name), d.get("fix", "") == expect_fix, d.get("fix"))
            check("[%s] %s private: cache rows unchanged (0)" % (lang, name), cache_count() == 0, cache_count())
            check("[%s] %s private: no canary in the cache DB bytes" % (lang, name), not found(cache_blob()))
            check("[%s] %s private: no canary in any log record" % (lang, name), not hits, hits)
            check("[%s] %s private: nothing printed with the canary" % (lang, name), not found("\n".join(PRINTED)))
            # --- same request, private missing: the old behaviour (positive control)
            clear_state(True)
            r = run_path(lang, lt, ai, None, polish)
            if name in ("LT fix + AI polish", "LT fix + AI agrees", "LT none + AI fix (AI alone)", "LT none + AI says nothing to fix"):
                # the paths that ask the AI: its answer is cached ("nothing to fix" too: it is a complete answer)
                check("[%s] %s no private: the AI answer IS cached (positive control)" % (lang, name), cache_count() == 1, cache_count())
                if "nothing to fix" not in name:
                    check("[%s] %s no private: the cache DB holds the canary (positive control)" % (lang, name), bool(found(cache_blob())))
            else:
                check("[%s] %s no private: no AI call, nothing cached" % (lang, name), cache_count() == 0 and not ENG.ai_calls)
            if name == "LT fix + AI polish":
                check("[%s] %s no private: the log repeats the sentences (positive control)" % (lang, name), bool(log_hits()), log_hits())
            clear_state()
    # the positive controls that must be strict (separate, simple cases)
    print("== 2b. positive controls (a scanner that never finds anything is not trusted)")
    clear_state()
    r = run_path("ja", None, ai_fix(JA_FIX), None)
    check("no private: cache row stored", cache_count() == 1, cache_count())
    check("no private: cache bytes hold the canary (the cache scanner works on this DB)", bool(found(cache_blob())))
    ENG.reset()
    ENG.ai = ai_fix("別の文です。")
    d = req("ja", JA_TEXT, private=None).json()
    check("no private: the second identical request is a cache HIT (no AI call, the stored answer)", d.get("fix") == JA_FIX and not ENG.ai_calls, d)
    ENG.reset()
    ENG.ai = ai_fix("別の文です。")
    d = req("ja", JA_TEXT, private=True).json()
    check("private: the same request does NOT read the cache (asks the AI, gets the new answer)", d.get("fix") == "別の文です。" and len(ENG.ai_calls) == 1, d)
    clear_state()
    r = run_path("en", lt_result(EN_FIX + "_lt"), ai_fix(EN_FIX), None)
    check("no private: 'AI polished LanguageTool fix' log line repeats the sentences", any("AI polished LanguageTool fix" in l and MARK in l for l in COLLECT.lines), [l[:80] for l in COLLECT.lines][-4:])
    clear_state()
    r = run_path("en", RuntimeError(EN_TEXT), ai_fix(EN_FIX), None)
    check("no private: a LanguageTool exception is logged with its message (traceback holds the canary)", any("languagetool correction failed" in l and MARK in l for l in COLLECT.lines))
    clear_state()
    r = run_path("en", RuntimeError(EN_TEXT), ai_fix(EN_FIX), True)
    check("private: the same LanguageTool exception is logged by type only", any("languagetool correction failed (RuntimeError)" in l for l in COLLECT.lines) and not log_hits(), [l[:100] for l in COLLECT.lines])
    check("private: ... and the answer still comes (the AI is asked)", r.status_code == 200 and r.json().get("fix") == EN_FIX, r.text[:100])
    # the private flag reaches the AI call: cache_key_kind None; non-private: "fix"
    seen = []
    orig = server.llm_json

    def spy(messages, schema, **kw):
        seen.append(kw.get("cache_key_kind"))
        return orig(messages, schema, **kw)
    server.llm_json = spy
    try:
        clear_state()
        run_path("en", None, ai_fix(EN_FIX), True)
        priv_kinds = list(seen)
        del seen[:]
        clear_state()
        run_path("en", None, ai_fix(EN_FIX), None)
        pub_kinds = list(seen)
    finally:
        server.llm_json = orig
    check("llm_json is called with cache_key_kind None when private", priv_kinds and all(k is None for k in priv_kinds), priv_kinds)
    check("llm_json is called with cache_key_kind 'fix' when not private (unchanged)", pub_kinds and all(k == "fix" for k in pub_kinds), pub_kinds)
    clear_state()


def use_db(public):
    """a brand new cache DB file (DB_PUBLIC for the not-private positive controls, else DB_PRIVATE)"""
    with llm_cache._lock:
        if llm_cache._conn is not None:
            llm_cache._conn.close()
            llm_cache._conn = None
        llm_cache.DB_PATH = DB_PUBLIC if public else DB_PRIVATE
        for suffix in ("", "-wal", "-shm"):
            if os.path.isfile(llm_cache.DB_PATH + suffix):
                os.remove(llm_cache.DB_PATH + suffix)


def clear_state(public=False):
    use_db(public)
    del COLLECT.lines[:]
    del PRINTED[:]
    ENG.ai_calls[:] = []
    ENG.lt_calls[:] = []


# ------------------------------------------------------------------------------------------------ 4. failure paths
def test_failures():
    print("== 3. failure paths (private): nothing of the sentence in the log or the cache")
    cases = []
    fmt_err = llm_common.LlmError("AI가 올바른 형식으로 답하지 못했어요. 다시 시도해 주세요.", 502, None, "garbled: " + JA_FIX + " " + EN_FIX)

    def raiser(e):
        def f(messages):
            raise e
        return f
    cases.append(("AI format error (raw repeats the corrected sentence), LT none", None, raiser(fmt_err)))
    cases.append(("AI overload (raw repeats the sentence), LT none", None, raiser(llm_common.LlmError("x", 502, "overload", "HTTP 529 " + JA_TEXT))))
    cases.append(("AI limit, LT none", None, raiser(llm_common.LlmError("x", 429, "limit", "429 retry in 600 seconds " + JA_TEXT))))
    cases.append(("AI not connected", None, raiser(llm_common.LlmError("연결 안 됨", 503, "not_connected", JA_TEXT))))
    cases.append(("AI format error after an LT fix (polish fails)", lt_result(JA_FIX), raiser(fmt_err)))
    cases.append(("AI overload after an LT fix", lt_result(JA_FIX), raiser(llm_common.LlmError("x", 502, "overload", JA_TEXT))))
    cases.append(("LT raises (message holds the sentence), AI answers", RuntimeError(JA_TEXT), ai_fix(JA_FIX)))
    cases.append(("LT raises, AI format error", ValueError(EN_TEXT), raiser(fmt_err)))
    for name, lt, ai in cases:
        for lang in ("ja", "en"):
            clear_state()
            ENG.reset()
            ENG.lt, ENG.ai = lt, ai
            r = req(lang, JA_TEXT if lang == "ja" else EN_TEXT, private=True)
            check("[%s] %s: handled (HTTP %s)" % (lang, name, r.status_code), r.status_code in (200, 502, 503, 429), r.text[:120])
            check("[%s] %s: no canary in the log" % (lang, name), not log_hits(), [l[:160] for l in COLLECT.lines if found(l)][:2])
            check("[%s] %s: no canary in the response body error text" % (lang, name), not found(r.text) or r.status_code == 200, r.text[:120])
            check("[%s] %s: cache empty" % (lang, name), cache_count() == 0 and not found(cache_blob()))
    # the same failures WITHOUT private: the raw text IS logged (positive control for the failure log lines)
    clear_state(True)
    ENG.reset()
    ENG.ai = raiser(llm_common.LlmError("x", 502, "overload", "HTTP 529 " + JA_TEXT))
    req("ja", JA_TEXT, private=None)
    check("no private: 'opencode call failed' repeats the engine's raw text (positive control)", any("opencode call failed" in l and MARK in l for l in COLLECT.lines), [l[:100] for l in COLLECT.lines])
    # the OpenAI-compatible engine's failure log line (_api_json)
    PROVIDER[0] = "openai_api"
    try:
        for pv, want in ((True, False), (None, True)):
            clear_state(pv is None)
            ENG.reset()
            ENG.ai = raiser(llm_common.LlmError("x", 502, "overload", "HTTP 529 " + JA_TEXT))
            r = req("ja", JA_TEXT, private=pv)
            hit = any("openai_api call failed" in l and MARK in l for l in COLLECT.lines)
            check("openai_api engine failure, private=%r: raw text %s in the log" % (pv, "IS" if want else "is NOT"), hit == want and any("openai_api call failed" in l for l in COLLECT.lines) and (want or not log_hits()), [l[:100] for l in COLLECT.lines])
            check("openai_api engine failure, private=%r: handled (HTTP %s)" % (pv, r.status_code), r.status_code == 200)
        clear_state(False)
        ENG.reset()
        ENG.ai = ai_fix(JA_FIX)
        r = req("ja", JA_TEXT, private=True)
        check("openai_api engine answering, private: 200, nothing cached, no canary in the log", r.status_code == 200 and r.json().get("fix") == JA_FIX and cache_count() == 0 and not log_hits())
    finally:
        PROVIDER[0] = "opencode"
    # an unexpected exception in the middle of a private request: 500, Korean, nothing of the sentence in the log
    clear_state(False)
    ENG.reset()
    ENG.ai = raiser(RuntimeError("boom " + JA_TEXT))
    r = req("ja", JA_TEXT, private=True)
    check("private: an unexpected exception -> 500 with the Korean error body", r.status_code == 500 and HANGUL.search(r.json().get("error", "")) and not found(r.text), r.text[:150])
    check("private: ... and its log line names the type only", not log_hits() and any("private /fix failed (RuntimeError)" in l for l in COLLECT.lines), [l[:100] for l in COLLECT.lines])
    clear_state(True)
    ENG.ai = raiser(RuntimeError("boom " + JA_TEXT))
    r = req("ja", JA_TEXT, private=None)
    check("no private: the same exception is logged with traceback by the app's handler (positive control)", r.status_code == 500 and log_hits(), [l[:100] for l in COLLECT.lines])
    # OpenJTalk failing inside the reading step: log by type only
    clear_state()
    ENG.reset()
    ENG.ai = ai_fix(JA_FIX)
    orig_ojt = server.ojt

    def bad_ojt():
        raise RuntimeError("ojt " + JA_FIX)
    server.ojt = bad_ojt
    try:
        server._ja_pair.cache_clear()
        r = req("ja", JA_TEXT, private=True)
        priv_hits = log_hits()
        priv_lines = [l[:100] for l in COLLECT.lines]
        clear_state()
        server._ja_pair.cache_clear()
        server.ja_reading(JA_FIX)    # not private: the old log.exception with the traceback
        pub_hits = log_hits()
    finally:
        server.ojt = orig_ojt
        server._ja_pair.cache_clear()
    check("private: an OpenJTalk failure while reading the fix -> 200 and no canary in the log", r.status_code == 200 and not priv_hits, priv_lines)
    check("not private: the same OpenJTalk failure keeps its traceback log (positive control)", bool(pub_hits))
    # the sentence does not stay in the ja_reading lru_cache (memory) either
    server._ja_pair.cache_clear()
    ENG.ai = ai_fix("昨日、友達と映画を見ました。")
    req("ja", "きのう ともだちと えいがをみた。", private=True)
    check("private: the fixed sentence is not left in the in-memory reading cache", server._ja_pair.cache_info().currsize == 0, server._ja_pair.cache_info())


# ------------------------------------------------------------------------------------------------ 5. the real grammar.py with a fake check()
class FakeResp:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)

    def json(self):
        return self._body


def test_grammar_quiet():
    print("== 4. grammar.py (real code, fake HTTP): quiet=True keeps the sentence out of the log")
    orig_post, orig_start = grammar.requests.post, grammar.start
    grammar.start = lambda wait=60.0: "http://127.0.0.1:1"
    text = EN_TEXT
    try:
        for label, post_fn in (
            ("connection error with the text in its message", lambda *a, **k: (_ for _ in ()).throw(ConnectionError("failed to send " + text))),
            ("HTTP 500 whose body repeats the text", lambda *a, **k: FakeResp(500, "Error: bad input: " + text)),
        ):
            grammar.requests.post = post_fn
            for quiet in (True, False):
                clear_state()
                res = REAL_CORRECT("en", text, quiet=quiet)
                hit = bool(log_hits())
                if quiet:
                    check("grammar.correct quiet=True, %s: None and no canary in the log" % label, res is None and not hit, [l[:120] for l in COLLECT.lines])
                else:
                    check("grammar.correct quiet=False, %s: the old log line repeats it (positive control)" % label, res is None and hit, [l[:120] for l in COLLECT.lines])
        # 'still flagged' after the fix rounds, and a fix that works: sentences are in the log only when not quiet
        # always flagged: a different replacement every round -> 'still flagged' log path
        def post_always(url, data=None, timeout=None, **k):
            t = data["text"]
            return FakeResp(200, {"matches": [{"offset": 0, "length": 2, "replacements": [{"value": "Z" + t[1:2] + "x"}], "rule": {"id": "R_X", "category": {"id": "GRAMMAR"}}}]})
        grammar.requests.post = post_always
        for quiet in (True, False):
            clear_state()
            res = REAL_CORRECT("en", text, quiet=quiet)
            hit = bool(log_hits())
            if quiet:
                check("grammar.correct quiet=True, 'still flagged' path: None and no canary in the log", res is None and not hit and any("still flagged" in l for l in COLLECT.lines), [l[:120] for l in COLLECT.lines])
            else:
                check("grammar.correct quiet=False, 'still flagged' path logs the sentence (positive control)", res is None and hit, [l[:120] for l in COLLECT.lines])
        # a real fix, found in the first pass and clean in the second
        state = {"n": 0}

        def post_fix(url, data=None, timeout=None, **k):
            state["n"] += 1
            t = data["text"]
            if "yesterday i go" in t:
                i = t.index("go")
                return FakeResp(200, {"matches": [{"offset": i, "length": 2, "replacements": [{"value": "went"}], "rule": {"id": "R_FIX", "category": {"id": "GRAMMAR"}}}]})
            return FakeResp(200, {"matches": []})
        grammar.requests.post = post_fix
        clear_state()
        res = REAL_CORRECT("en", text, quiet=True)
        check("grammar.correct quiet=True with a real fix: fix returned, log has rule id only", bool(res) and "went" in res["fix"] and not log_hits() and any("R_FIX" in l for l in COLLECT.lines), [l[:120] for l in COLLECT.lines])
        # and the 'no fix' line
        clear_state()
        res = REAL_CORRECT("en", "ZZ_MARK_9731 all good here", quiet=True)
        check("grammar.correct quiet=True, nothing to fix: None, no canary in the log", res is None and not log_hits())
    finally:
        grammar.requests.post, grammar.start = orig_post, orig_start


# ------------------------------------------------------------------------------------------------ 6. odd inputs (C2-7)
def test_odd_inputs():
    print("== 5. odd inputs")
    use_db(True)    # the "treated as false" requests are cached: public DB
    korean = lambda r: bool(HANGUL.search((r.json() or {}).get("error", "")))
    for pv in ("yes", "true", 1, 0, None, [], {}, "false"):
        ENG.reset()
        ENG.ai = ai_fix(JA_FIX)
        clear_state(True)
        r = req("ja", JA_TEXT, private=pv)
        d = r.json()
        check("private=%r -> 200, treated as false: 2 keys and the answer IS cached" % (pv,), r.status_code == 200 and sorted(d) == ["fix", "fix_ko"] and cache_count() == 1, (r.status_code, d, cache_count()))
    clear_state(True)
    r = CLIENT.post("/fix", json={"lang": "ja", "text": JA_TEXT})
    check("private missing (no key at all) -> 200, 2 keys", r.status_code == 200 and sorted(r.json()) == ["fix", "fix_ko"], r.text[:100])
    # text over 500 chars is cut to 500 before the AI sees it
    for pv in (True, None):
        ENG.reset()
        ENG.ai = ai_fix("")
        long_text = "a" * 500 + "ZZ_TAIL_END" + "b" * 500
        r = req("en", long_text, private=pv)
        sent = " ".join(m["content"] for call in ENG.ai_calls for m in call)
        check("private=%r: a 1011-char text -> 200 and the AI got only the first 500 chars" % (pv,), r.status_code == 200 and "a" * 500 in sent and "a" * 501 not in sent and "ZZ_TAIL" not in sent, (r.status_code, len(sent)))
    for pv in (True, None):
        for txt in ("", "   ", "\n\t \n", "\x00\x01\x02", "   "):
            if pv is None and txt in ("\x00\x01\x02", "   "):
                continue   # without private nothing changes: those are not "empty" there
            r = req("ja", txt, private=pv)
            check("private=%r empty / whitespace-only %r -> 400 with a Korean message" % (pv, txt), r.status_code == 400 and korean(r), (r.status_code, r.text[:80]))
    for pv in (True, None):
        r = req("fr", "bonjour", private=pv)
        check("private=%r lang 'fr' -> 400 with a Korean message" % (pv,), r.status_code == 400 and korean(r), r.text[:80])
        r = req("xx" * 20, "x", private=pv)
        check("private=%r absurd lang -> 400" % (pv,), r.status_code == 400)
    ENG.reset()
    ENG.ai = ai_fix("")
    r = req("ja", "ZZ_MARK_9731きのう\x00\x07の\x1b[31mひ\x85 。", private=True)
    sent = " ".join(m["content"] for call in ENG.ai_calls for m in call)
    check("private: control characters are removed before the sentence is used (200, none in the prompt)", r.status_code == 200 and not re.search(r"[\x00-\x08\x0b-\x1f\x7f-\x9f  ]", sent.replace("\n", "")) and "ZZ_MARK_9731きのう" in sent, (r.status_code, repr(sent[-160:])))
    # a bad type of text is the old validation (422 -> the existing Korean body, not a crash)
    r = CLIENT.post("/fix", json={"lang": "ja", "text": 123, "private": True})
    check("text not a string -> 422 with the existing Korean message (unchanged)", r.status_code == 422 and korean(r), r.text[:80])
    r = CLIENT.post("/fix", content=b"{broken json", headers={"content-type": "application/json"})
    check("broken JSON body -> 4xx with a Korean message, no 500", 400 <= r.status_code < 500 and korean(r), (r.status_code, r.text[:80]))
    # prev_ai with the marker (the partner's last line) is not logged either
    clear_state(False)
    ENG.reset()
    ENG.ai = ai_fix(JA_FIX)
    r = req("ja", JA_TEXT, private=True, prev_ai=MARK + "どうでしたか")
    check("private with prev_ai: 200 and no canary in the log", r.status_code == 200 and not log_hits() and cache_count() == 0)


# ------------------------------------------------------------------------------------------------ 7. C2-8 + files (C2-5)
def test_files():
    print("== 6. lan.py allow list, files")
    import lan
    check("lan.ALLOW already has POST /fix (lan.py untouched)", ("POST", "/fix") in lan.ALLOW)
    use_db(False)
    hits = [h for h in scan_folder(TMP) if os.sep + "db_public" + os.sep not in h[0]]   # the public DB is the positive control
    check("the temp folder of this test (private DB, espeak, ...) has no canary file / content", not hits, hits[:3])
    check("(the public DB file does hold the canary: the folder scan can see it)", any(os.sep + "db_public" + os.sep in h[0] for h in scan_folder(TMP)))
    for sub in ("logs", "cache"):
        p = os.path.join(HERE, sub)
        if not os.path.isdir(p):
            print("  [INFO] %s: no such folder (nothing to scan)" % p)
            continue
        h = scan_folder(p)
        check("real backend\\%s has no canary (%d files scanned)" % (sub, sum(len(f) for _d, _s, f in os.walk(p))), not h, h[:3])
    check("nothing printed with the canary during the whole run", not found("\n".join(PRINTED)))


# ------------------------------------------------------------------------------------------------ 8. real LanguageTool JVM
def test_live_lt():
    print("== 7. real LanguageTool process: its own log (languagetool.log) after private calls")
    if not LT_DIR_ARG:
        print("  [SKIP] no --lt-dir: not run (미검증)")
        return None
    grammar.LT_DIR = LT_DIR_ARG
    lt_log_dir = os.path.join(TMP, "ltlogs")
    grammar.LOG_DIR = lt_log_dir
    if not grammar.find_jar() or not grammar.find_java():
        print("  [SKIP] LanguageTool jar or Java 17+ not found under %s (미검증)" % LT_DIR_ARG)
        return False
    server.log.info("starting the real LanguageTool for this test")
    base = grammar.start(wait=90.0)
    if not base:
        print("  [SKIP] LanguageTool did not start (미검증)")
        return False
    try:
        sentences = [("en", MARK + " yesterday he go to school with his friend"), ("en", MARK + " I has a apple and she don't like it"),
                     ("ja", MARK + " これわ ほんです。"), ("ja", JA_TEXT)]
        for lang, s in sentences:
            res = REAL_CORRECT(lang, s, quiet=True)
            print("   real LT %s -> %s" % (lang, "fix" if res else "none"))
        # a broken request the real server rejects (text is not repeated by our code)
        r = grammar.requests.post(base + "/v2/check", data={"text": MARK + " x", "language": "xx-XX"}, timeout=8)
        print("   (a request the server rejects: HTTP %s)" % r.status_code)
        grammar.stop()
        import time
        time.sleep(1.0)
        p = os.path.join(lt_log_dir, "languagetool.log")
        blob = open(p, "rb").read() if os.path.isfile(p) else b""
        check("languagetool.log exists and has content (the scan is meaningful: %d bytes)" % len(blob), len(blob) > 0)
        h = found(blob)
        # report-only: the JVM's own log is what O-5 decides on; also say it in one line
        print("  [INFO] canary tokens found in the real languagetool.log: %s" % (h or "none"))
        return not h
    finally:
        try:
            grammar.stop()
        except Exception:
            pass


if __name__ == "__main__":
    test_selfcheck()
    clear_state()
    test_response()
    clear_state()
    test_canary()
    test_failures()
    test_grammar_quiet()
    test_odd_inputs()
    lt_ok = test_live_lt()
    test_files()
    bad = [n for n, ok in results if not ok]
    print("\n%d checks, %d FAIL" % (len(results), len(bad)))
    for n in bad:
        print("  FAIL:", n)
    print("live LanguageTool section: %s" % ("run, no canary in languagetool.log" if lt_ok is True else
          ("canary FOUND in languagetool.log or could not run" if LT_DIR_ARG else "not run (no --lt-dir): 미검증")))
    sys.exit(1 if bad or (LT_DIR_ARG and lt_ok is not True) else 0)
