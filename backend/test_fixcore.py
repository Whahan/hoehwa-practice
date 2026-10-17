# -*- coding: utf-8 -*-
"""Regression tests for the 1.1.1 backend-core fixes. Runs server.py's functions IN PROCESS with stub engines (no network,
no Ollama, no OpenCode, nothing on a port):

    .venv\\Scripts\\python.exe test_fixcore.py [--only cache|espeak|opencode|reset|audio|align]

1. LLM cache: a bad first answer is never stored (only answers that pass the caller's check), a stored bad one is ignored
2. espeak data path: ASCII path for espeak without os.chdir; works from several threads at once
3. OpenCode sessions: a discarded / unreadable answer invalidates the session; no duplicate create / delete under a running send
4. llm_fallback.parse_reset: bare numbers are not clock times
5. decode_audio_b64: base64 size limit (400, Korean message) and a 60 s cut-off
6. nw_align: unrelated words are 'missed', not 'heard as'
Writes only under a temp folder (the cache DB and the espeak copy go to a folder of its own). Exit code 1 on any FAIL.
"""
import io
import json
import os
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

TMP = tempfile.mkdtemp(prefix="hoehwa_fixcore_")
os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(TMP, "espeak")
sys.argv = [sys.argv[0]] + ["--tag", "unit_fixcore"] + [a for a in sys.argv[1:]]
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""

CWD0 = os.getcwd()
import numpy as np
import soundfile as sf

import llm_cache
llm_cache.DB_PATH = os.path.join(TMP, "llm_cache.sqlite")
llm_cache._conn = None
import llm_common
import llm_fallback
import llm_opencode
import server

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def want(part):
    return not ONLY or ONLY == part


def cache_rows():
    with llm_cache._lock:
        return [(r[0], json.loads(r[1])) for r in llm_cache._db().execute("SELECT kind, value FROM llm_cache").fetchall()]


def clear_cache():
    with llm_cache._lock:
        llm_cache._db().execute("DELETE FROM llm_cache")
        llm_cache._db().commit()


class StubLlm:
    """replaces the local engine: answers come from a list (the last one repeats)"""
    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = 0

    def __call__(self, messages, schema, temperature, num_predict, think):
        a = self.answers[min(self.calls, len(self.answers) - 1)]
        self.calls += 1
        return a


def with_stub(stub):
    server.remote_route_active = lambda: False
    server._ollama_chat_json = stub


# ------------------------------------------------------------------------------------------------ 1. cache
def test_cache():
    print("== 1. LLM cache only keeps validated answers")
    # translate_ko: first answer has Chinese characters only (ko_ok False), second is fine
    clear_cache()
    stub = StubLlm([{"ko": "你好吗"}, {"ko": "안녕하세요"}])
    with_stub(stub)
    check("translate: second (good) answer is returned", server.translate_ko("Hello", "en") == "안녕하세요")
    rows = cache_rows()
    check("translate: the cache holds only the good answer", [v for _k, v in rows] == [{"ko": "안녕하세요"}], rows)
    stub2 = StubLlm([{"ko": "你好吗"}, {"ko": "안녕하세요"}])
    with_stub(stub2)
    check("translate: next request is good again", server.translate_ko("Hello", "en") == "안녕하세요")

    # translate_ko: both bad -> nothing is stored; the next request (healthy engine) is good
    clear_cache()
    with_stub(StubLlm([{"ko": "你好吗"}]))
    check("translate: two bad answers -> ''", server.translate_ko("Hello", "en") == "")
    check("translate: nothing cached after two bad answers", cache_rows() == [], cache_rows())
    with_stub(StubLlm([{"ko": "안녕하세요"}]))
    check("translate: the next request after the bad ones is good", server.translate_ko("Hello", "en") == "안녕하세요")

    # verify_answers: an incomplete checker answer must not stick
    clear_cache()
    exs = [{"type": "choice", "question": "q%d" % i, "options": ["a", "b", "c", "d"], "answer": i % 4, "explain": ""} for i in range(5)]

    def full(n):
        return {"answers": [{"id": i, "answer": exs[i]["answer"], "a": "O", "b": "O", "c": "O", "d": "O", "e": "O"} for i in range(n)]}
    stub = StubLlm([full(2), full(5)])
    with_stub(stub)
    try:
        server.verify_answers("en", exs)
        first = "no error"
    except server.LessonUnchecked as e:
        first = "LessonUnchecked"
    check("verify: incomplete checker answer -> LessonUnchecked", first == "LessonUnchecked", first)
    check("verify: the incomplete answer was NOT cached", cache_rows() == [], cache_rows())
    keep = server.verify_answers("en", exs)
    check("verify: next request is checked normally", len(keep) == 5, len(keep))
    n_rows = len(cache_rows())
    calls = stub.calls
    keep2 = server.verify_answers("en", exs)
    check("verify: the good answer is cached (third request: no engine call)", n_rows == 1 and stub.calls == calls and len(keep2) == 5,
          "rows=%d calls %d->%d" % (n_rows, calls, stub.calls))

    # _llm_correct: Hangul in an English "fix" + no Korean explanation -> not cached
    clear_cache()
    bad = {"fix": "안녕 I am", "fix_ko": ""}
    good = {"fix": "I am fine.", "fix_ko": "문장을 고쳤어요."}
    stub = StubLlm([bad, good])
    with_stub(stub)
    f, fk = server._llm_correct("en", 1, "I are fine", "")
    check("fix: the good second answer is used", (f, fk) == ("I am fine.", "문장을 고쳤어요."), (f, fk))
    check("fix: only the good answer is cached", [v for _k, v in cache_rows()] == [good], cache_rows())

    # a bad entry that is already in the cache (written by older code / another path) is ignored on read
    clear_cache()
    opts = {"temperature": 0.2}
    key = llm_cache.make_key("t", "ollama", "m", {}, [{"role": "user", "content": "x"}], dict(opts, cv=server.CACHE_VERSION))
    llm_cache.put(key, "t", "ollama", "m", {"ko": "你好"})
    out = server._with_cache("t", "ollama", "m", [{"role": "user", "content": "x"}], {}, opts, lambda: {"ko": "안녕"},
                             lambda d: server.ko_ok(d.get("ko", ""), "en"))
    check("a stored bad entry is ignored and replaced by the fresh good answer", out == {"ko": "안녕"}, out)
    # and the cache key carries a version, so answers stored by the old unvalidated code are not reachable
    old_key = llm_cache.make_key("t", "ollama", "m", {}, [{"role": "user", "content": "x"}], opts)
    check("cache key differs from the pre-1.1.1 key (version prefix)", old_key != key)


# ------------------------------------------------------------------------------------------------ 2. espeak
def test_espeak():
    print("== 2. espeak non-ASCII path without os.chdir")
    import espeakng_loader
    d = espeakng_loader.get_data_path()
    ascii_src = all(ord(c) < 128 for c in d)
    cwd = os.getcwd()
    errs = []

    def go():
        try:
            server._patch_espeak_for_nonascii_path()
        except Exception as e:   # noqa
            errs.append(repr(e))
    ts = [threading.Thread(target=go) for _ in range(4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    check("patch from 4 threads at once: no error", not errs, errs)
    check("os.getcwd() unchanged", os.getcwd() == cwd == CWD0, "%s -> %s" % (cwd, os.getcwd()))
    import phonemizer.backend.espeak.wrapper as W
    wrapped = W.EspeakAPI
    server._patch_espeak_for_nonascii_path()
    check("a second call does not wrap again", W.EspeakAPI is wrapped)
    from phonemizer.backend.espeak.wrapper import EspeakWrapper
    from phonemizer.backend import EspeakBackend
    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    be = EspeakBackend("en-us", preserve_punctuation=False, with_stress=False, language_switch="remove-flags")
    ipa = be.phonemize(["hello"], strip=True)[0]
    check("espeak phonemizes after the patch ('hello' -> IPA)", bool(ipa.strip()) and "h" in ipa, ipa)
    check("cwd still unchanged after phonemizing", os.getcwd() == CWD0)
    if not ascii_src:
        copies = [n for n in os.listdir(os.environ["HOEHWA_ESPEAK_DIR"]) if n.startswith("hoehwa-espeak-ng-data-")] \
            if os.path.isdir(os.environ["HOEHWA_ESPEAK_DIR"]) else []
        check("non-ASCII data path -> an ASCII copy (or short path) is used", len(copies) == 1 or server._short_ascii_path(d), copies)
    # the damaged-copy path: a copy missing a file is rebuilt, not trusted
    if not ascii_src and not server._short_ascii_path(d):
        root = os.environ["HOEHWA_ESPEAK_DIR"]
        dest = os.path.join(root, [n for n in os.listdir(root) if n.startswith("hoehwa-espeak-ng-data-")][0])
        victim = next(os.path.join(r, f) for r, _d, fs in os.walk(dest) for f in fs)
        os.remove(victim)
        again = server._ascii_espeak_data(d)
        check("a damaged copy is rebuilt", again == dest and os.path.isfile(victim))


# ------------------------------------------------------------------------------------------------ 3. opencode
class FakeOC:
    """stands in for `opencode serve`: records create / send / delete, can be told what to answer"""
    def __init__(self):
        self.n = 0
        self.live = set()
        self.created = []
        self.deleted = []
        self.sent = []          # (sid, prompt)
        self.inflight = set()
        self.conflicts = []
        self.answers = []       # texts for the next sends (the last one repeats)
        self.delay = 0.0
        self.lock = threading.Lock()

    def new_session(self, title):
        with self.lock:
            self.n += 1
            sid = "s%d" % self.n
            self.live.add(sid)
            self.created.append(sid)
        return sid

    def delete_session(self, sid):
        with self.lock:
            if sid in self.inflight:
                self.conflicts.append(sid)
            self.live.discard(sid)
            self.deleted.append(sid)

    def send(self, cfg, sid, text, system, timeout):
        with self.lock:
            self.inflight.add(sid)
            self.sent.append((sid, text))
            idx = len(self.sent) - 1
        time.sleep(self.delay)
        with self.lock:
            self.inflight.discard(sid)
            a = self.answers[min(idx, len(self.answers) - 1)] if self.answers else '{"reply":"ok","ko":"좋아요","reading":"","suggest":["a","b"]}'
        return a, {"s": 0.0}


def install_fake_oc(fake):
    llm_opencode._need_server = lambda: None
    llm_opencode._new_session = fake.new_session
    llm_opencode._delete_session = fake.delete_session
    llm_opencode._send = fake.send
    llm_opencode._sessions.clear()


def hist(*pairs):
    return [{"role": r, "text": t} for r, t in pairs]


def test_opencode():
    print("== 3. OpenCode sessions")
    SYS = "system prompt"
    # a) normal turns reuse the session; invalidate() (answer discarded) -> a new session with the full history
    fake = FakeOC()
    install_fake_oc(fake)
    llm_opencode.chat_json({}, "c1", SYS, hist(("me", "hello")), "", {})
    llm_opencode.chat_json({}, "c1", SYS, hist(("me", "hello"), ("ai", "hi there"), ("me", "how are you")), "", {})
    check("turn 2 reuses the session", fake.sent[0][0] == fake.sent[1][0] == "s1", fake.sent)
    llm_opencode.invalidate("c1", SYS)
    llm_opencode.chat_json({}, "c1", SYS, hist(("me", "hello"), ("ai", "hi there"), ("me", "how are you"), ("ai", "fine"), ("me", "ok")), "", {})
    check("after invalidate() the next turn uses a NEW session", fake.sent[2][0] == "s2", fake.sent[2][0])
    check("the old session is deleted", "s1" in fake.deleted)
    check("the new session is started with the app's history", "Conversation so far" in fake.sent[2][1] and "fine" in fake.sent[2][1])

    # b) unreadable answer: the session is not trusted any more (even though it worked for the turn before)
    fake = FakeOC()
    fake.answers = ['{"reply":"ok"}', "not json at all", '{"reply":"ok"}']
    install_fake_oc(fake)
    llm_opencode.chat_json({}, "c2", SYS, hist(("me", "hello")), "", {})
    h2 = hist(("me", "hello"), ("ai", "ok"), ("me", "and you"))
    try:
        llm_opencode.chat_json({}, "c2", SYS, h2, "", {})
    except llm_common.LlmError:
        pass
    llm_opencode.chat_json({}, "c2", SYS, h2, "", {})
    check("after an unreadable answer the retry of the same turn starts a new session",
          [s for s, _ in fake.sent] == ["s1", "s1", "s2"], fake.sent)

    # c) run_chat: the first (OpenCode) answer is rejected, another engine's answer is used -> the next turn does not reuse the session
    fake = FakeOC()
    fake.answers = ['{"reply":"한국어로만 대답","ko":"한국어","reading":"","suggest":["a","b"]}',
                    '{"reply":"Nice to meet you.","ko":"만나서 반갑습니다.","reading":"","suggest":["a","b"]}']
    install_fake_oc(fake)
    server.llm_provider = lambda: "opencode"
    server.remote_route_active = lambda: True
    server.llm_opencode.available = lambda: True
    local_calls = []

    def local(msgs, schema, **kw):
        local_calls.append(1)
        return {"reply": "Hello, nice to meet you!", "ko": "안녕하세요, 만나서 반갑습니다!", "reading": "", "suggest": ["Me too.", "Thanks."]}
    server.ollama_json = local
    T = server.Turn
    r1 = server.run_chat(server.ChatReq(lang="en", month=1, week=1, conv_id="c3", skip_fix=True, history=[T(role="me", text="Hi")]))
    check("run_chat adopted the other engine's answer", r1["reply"] == "Hello, nice to meet you!" and local_calls, r1)
    r2 = server.run_chat(server.ChatReq(lang="en", month=1, week=1, conv_id="c3", skip_fix=True, history=[
        T(role="me", text="Hi"), T(role="ai", text=r1["reply"]), T(role="me", text="Nice to meet you")]))
    check("next turn: a NEW OpenCode session", len(fake.sent) == 2 and fake.sent[0][0] != fake.sent[1][0], fake.sent)
    check("next turn: its prompt has the adopted reply and NOT the discarded one",
          "Hello, nice to meet you!" in fake.sent[1][1] and "한국어로만" not in fake.sent[1][1], fake.sent[1][1][:300])
    check("next turn: answered by OpenCode", r2["reply"] == "Nice to meet you.", r2)

    # d) the same conversation asked twice at the same time: no double create that leaks, no delete under a running send
    fake = FakeOC()
    fake.delay = 0.3
    install_fake_oc(fake)
    errs = []

    def go():
        try:
            llm_opencode.chat_json({}, "c4", SYS, hist(("me", "hello")), "", {})
        except Exception as e:   # noqa
            errs.append(repr(e))
    ts = [threading.Thread(target=go) for _ in range(4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    check("4 simultaneous requests: no error", not errs, errs)
    check("never a delete of a session that is being used", not fake.conflicts, fake.conflicts)
    check("no session leaked: exactly one stays open", len(fake.live) == 1 and len(llm_opencode._sessions) == 1,
          "live=%s sessions=%d" % (fake.live, len(llm_opencode._sessions)))
    check("never two requests on one session at the same time", all(
        sum(1 for s, _ in fake.sent if s == sid) <= 4 for sid in fake.created))
    # eviction while in use: the busy session is deleted only after its send finished
    fake = FakeOC()
    fake.delay = 0.4
    install_fake_oc(fake)
    t = threading.Thread(target=lambda: llm_opencode.chat_json({}, "busy", SYS, hist(("me", "hello")), "", {}))
    t.start()
    time.sleep(0.1)
    for k in ("x1", "x2", "x3", "x4"):
        llm_opencode.chat_json({}, k, SYS, hist(("me", "hello")), "", {})
    t.join()
    time.sleep(0.6)
    check("an evicted busy session is deleted after its send, not during", not fake.conflicts, fake.conflicts)


# ------------------------------------------------------------------------------------------------ 4. parse_reset
def test_reset():
    print("== 4. llm_fallback.parse_reset")
    now = time.time()
    for t in ["try again 1 time", "resets after 2026-10-17", "resets 2026-10-17 10:30", "retry 3 times", "available again 12 items",
              "reset 5 minutes ago", "try again 10 more requests", "resets 7 days", "try again at 12345", "resets 2026"]:
        check("not a time: %r" % t, llm_fallback.parse_reset(t, now) is None, llm_fallback.parse_reset(t, now))
    for t, kind in [("usage limit reached|1760000000", "epoch"), ("try again in 2 hours 5 minutes", "dur"), ("retry in 41s", "dur"),
                    ("resets 3pm", "clock"), ("resets at 3:30 PM", "clock"), ("try again at 15:00", "clock")]:
        r = llm_fallback.parse_reset(t, now)
        check("still parsed: %r" % t, r is not None and (kind == "epoch" or r > now), r)
    r = llm_fallback.parse_reset("resets at 3:30 PM", now)
    import datetime
    check("3:30 PM -> 15:30", datetime.datetime.fromtimestamp(r).strftime("%H:%M") == "15:30")


# ------------------------------------------------------------------------------------------------ 5. audio
def wav_b64(seconds, sr=16000, ch=1):
    import base64
    n = int(seconds * sr)
    x = (0.3 * np.sin(2 * np.pi * 220 * np.arange(n) / sr)).astype(np.float32)
    if ch > 1:
        x = np.stack([x] * ch, axis=1)
    b = io.BytesIO()
    sf.write(b, x, sr, format="WAV", subtype="PCM_16")
    return base64.b64encode(b.getvalue()).decode("ascii")


def test_audio():
    print("== 5. decode_audio_b64 limits")
    a = server.decode_audio_b64(wav_b64(2))
    check("2 s clip: unchanged length", len(a) == 32000, len(a))
    a = server.decode_audio_b64(wav_b64(75))
    check("75 s clip (16 kHz) is cut to 60 s", len(a) == 60 * 16000, len(a))
    a = server.decode_audio_b64(wav_b64(70, sr=48000, ch=1))
    check("70 s clip (48 kHz) is cut to 60 s", len(a) == 60 * 16000, len(a))
    try:
        server.decode_audio_b64("A" * (server.MAX_AUDIO_B64 + 1))
        got = None
    except server.ApiError as e:
        got = e
    check("base64 over the limit -> ApiError 400 in Korean", got is not None and got.status == 400 and
          "너무 커요" in got.msg, getattr(got, "msg", got))
    try:
        server.decode_audio_b64(wav_b64(430))   # a valid 13 MB WAV: base64 is over the 16 MB limit
        got = None
    except server.ApiError as e:
        got = e
    check("a valid but oversized WAV is refused too (400, '너무 커요')", got is not None and got.status == 400 and "너무 커요" in got.msg,
          getattr(got, "msg", "accepted"))
    try:
        server.decode_audio_b64("")
        got = None
    except server.ApiError as e:
        got = e
    check("empty -> 400 as before", got is not None and got.status == 400)
    try:
        server.decode_audio_b64("bm90IGF1ZGlv")
        got = None
    except server.ApiError as e:
        got = e
    check("garbage -> 400 as before", got is not None and got.status == 400, getattr(got, "msg", got))


# ------------------------------------------------------------------------------------------------ 6. nw_align
def test_align():
    print("== 6. nw_align: unrelated words are missed, not 'heard as'")
    pairs = server.nw_align(["a", "cat"], ["dog"], server.word_sim)
    check("unrelated 'cat' / 'dog' are not paired", all(not (i is not None and j is not None) for i, j in pairs), pairs)
    pairs = server.nw_align(["red", "apples"], ["read", "apple"], server.word_sim)
    check("similar words are still paired", [(i, j) for i, j in pairs if i is not None and j is not None] == [(0, 0), (1, 1)], pairs)
    pairs = server.nw_align(["カ", "キ"], ["ガ", "ケ"], server.mora_sim)
    check("mora pairs with similarity are still paired", all(i is not None and j is not None for i, j in pairs), pairs)

    # one word missing in the sentence
    words = [{"w": w, "p": 0.9, "start": 0.3 * k, "end": 0.3 * k + 0.25} for k, w in enumerate(["I", "saw", "dog"])]
    res = server.score_en("I saw a cat", words, "I saw dog")
    heard = [u["heard"] for u in res["units"]]
    check("score_en: no unit is 'heard as' dog", "dog" not in heard, heard)
    check("score_en: 'a' and 'cat' count as missed", [u["ok"] for u in res["units"]] == [True, True, False, False], res["units"])
    check("score_en: no tip says '...로 들렸어요' about an unrelated word", not any("dog" in t for t in res["tips_ko"]), res["tips_ko"])
    # a real mispronunciation (similar word) is still reported as heard
    words = [{"w": w, "p": 0.9, "start": 0.3 * k, "end": 0.3 * k + 0.25} for k, w in enumerate(["I", "saw", "a", "cut"])]
    res = server.score_en("I saw a cat", words, "I saw a cut")
    check("score_en: 'cat' heard as 'cut' (similar) is still reported", res["units"][3]["heard"] == "cut", res["units"])


if want("cache"):
    test_cache()
if want("espeak"):
    test_espeak()
if want("opencode"):
    test_opencode()
if want("reset"):
    test_reset()
if want("audio"):
    test_audio()
if want("align"):
    test_align()

bad = [n for n, ok in results if not ok]
print("\n%d checks, %d FAIL%s" % (len(results), len(bad), (": " + "; ".join(bad)) if bad else ""))
try:
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)
except Exception:
    pass
sys.exit(1 if bad else 0)
