# -*- coding: utf-8 -*-
"""Tests the rule-based Tatoeba lessons (POST /lesson, source "tatoeba" = default) against a RUNNING server.
Every exercise is checked against the original sentence in data/tatoeba.sqlite.
Usage:  .venv\\Scripts\\python.exe test_lesson_rules.py --base http://127.0.0.1:8796 [--n 50] [--ai]
  --ai          also generates one LLM lesson per language (source "ai") and checks its shape.
  --no-extra    skip the in-process checks (known bad items, block list, DB validity, AI fallback with a stubbed LLM).
  --corrupt-db  only for a test server started with HOEHWA_TATOEBA_DB=<empty / non-SQLite file> HOEHWA_TEST_HOOKS=1:
                /lesson must answer with a lesson or a Korean 5xx error, never 500.
"""
import os
import re
import sys
import json
import time
import random
import sqlite3
import requests

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def _require_base():
    """These tests send real requests (some write settings / cache files): they never default to the app's server."""
    if "--base" not in sys.argv or sys.argv.index("--base") + 1 >= len(sys.argv):
        sys.exit("--base 가 필요해요 / --base is required. Start your own test server "
                 "(.venv\\Scripts\\python.exe server.py --port 8796 --tag mytest) and pass --base http://127.0.0.1:8796")
    base = sys.argv[sys.argv.index("--base") + 1].rstrip("/")
    if base.endswith(":8770") and "--allow-app-server" not in sys.argv:
        sys.exit("--base points at the app server (port 8770): refused. Use a test server, or add --allow-app-server.")
    return base


BASE = _require_base()
N = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 50
DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "tatoeba.sqlite")
con = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True)
EN_EDGE = ".,!?;:"
JA_END = "。！？!?．…、"

fails = []
counts = {}


def sent(sid):
    r = con.execute("SELECT text, ko FROM sent WHERE id=?", (sid,)).fetchone()
    return r if r else (None, None)


def bad(lang, k, e, msg):
    fails.append("%s lesson %d %s #%s: %s | %s" % (lang, k, e.get("type"), e.get("tatoeba_id"), msg, json.dumps(e, ensure_ascii=False)[:300]))


def opts_ok(e):
    o, a = e.get("options"), e.get("answer")
    return (isinstance(o, list) and len(o) == 4 and all(isinstance(x, str) and x.strip() for x in o) and len(set(o)) == 4
            and isinstance(a, int) and 0 <= a < 4)


def check_lesson(lang, k, d):
    exs = d.get("exercises") or []
    if d.get("source") != "tatoeba" or "Tatoeba" not in d.get("attribution", "") or not d.get("title"):
        fails.append("%s lesson %d: missing source/attribution/title" % (lang, k))
    if len(exs) != 10:
        fails.append("%s lesson %d: %d exercises" % (lang, k, len(exs)))
    mains = {}
    for e in exs:
        t = e.get("type")
        counts[(lang, t)] = counts.get((lang, t), 0) + 1
        sid = e.get("tatoeba_id")
        text, ko = sent(sid)
        if text is None:
            bad(lang, k, e, "unknown tatoeba_id")
            continue
        if sid in mains:
            bad(lang, k, e, "sentence repeated")
        mains[sid] = (text, ko)
        if t == "choice":
            if not opts_ok(e) or not isinstance(e.get("question"), str):
                bad(lang, k, e, "bad choice shape")
                continue
            right = e["options"][e["answer"]]
            if e["question"].endswith("\n" + text):
                if right != ko:
                    bad(lang, k, e, "choice answer is not the Korean translation")
            elif e["question"].endswith("\n" + ko):
                if right != text:
                    bad(lang, k, e, "reverse choice answer is not the sentence")
            else:
                bad(lang, k, e, "question does not quote the sentence")
        elif t == "listen":
            if not opts_ok(e) or e.get("audio") != text or e["options"][e["answer"]] != ko:
                bad(lang, k, e, "listen answer/audio mismatch")
        elif t == "fill":
            if not opts_ok(e) or e.get("sentence", "").count("___") != 1:
                bad(lang, k, e, "bad fill shape")
                continue
            if e["sentence"].replace("___", e["options"][e["answer"]]) != text:
                bad(lang, k, e, "fill + correct option != original sentence")
            for j, o in enumerate(e["options"]):
                if j != e["answer"] and e["sentence"].replace("___", o) == text:
                    bad(lang, k, e, "a distractor also gives the original sentence")
            if e.get("ko") != ko:
                bad(lang, k, e, "fill ko mismatch")
        elif t == "build":
            ans, extra = e.get("answer"), e.get("extra")
            if not (isinstance(ans, list) and len(ans) >= 3 and all(isinstance(x, str) and x.strip() for x in ans)):
                bad(lang, k, e, "bad build answer")
                continue
            if lang == "en":
                want = " ".join(w.strip(EN_EDGE) for w in text.split())
                got = " ".join(ans)
            else:
                want = text.rstrip(JA_END)
                got = "".join(ans)
            if got != want:
                bad(lang, k, e, "build tokens do not re-join to the sentence (%r vs %r)" % (got, want))
            if not (isinstance(extra, list) and len(extra) == 2 and len(set(extra)) == 2):
                bad(lang, k, e, "build needs 2 distinct extra tokens")
            elif any(x in ans or x.lower() in [a.lower() for a in ans] for x in extra):
                bad(lang, k, e, "extra token is also an answer token")
            if e.get("ko") != ko:
                bad(lang, k, e, "build ko mismatch")
        elif t == "speak":
            if e.get("text") != text or e.get("ko") != ko:
                bad(lang, k, e, "speak text/ko mismatch")
        else:
            bad(lang, k, e, "unknown type")
        if lang == "ja" and t in ("fill", "listen", "build", "speak") and not e.get("reading"):
            bad(lang, k, e, "missing Japanese reading")
    # no main sentence may show up as another exercise's distractor
    texts = {v[0] for v in mains.values()} | {v[1] for v in mains.values()}
    for e in exs:
        own = mains.get(e.get("tatoeba_id"), (None, None))
        for j, o in enumerate(e.get("options") or []):
            if j != e.get("answer") and o in texts and o not in own:
                bad(lang, k, e, "distractor %r is another exercise's sentence" % o)


# ---------------------------------------------------------------------------------------------
# extra checks: known bad items, block list, corrupted DB, AI fallback
# ---------------------------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
KNOWN_BAD = [  # (lang, sentence id, answer word the blank hides, distractors that must NEVER be offered)
    ("en", 6854532, "think", {"believe", "feel", "guess", "suppose"}),
    ("en", 1401744, "think", {"feel", "believe", "guess", "suppose"}),   # "I think she'll help me."
    ("en", 6665344, "think", {"feel", "believe", "guess", "suppose"}),   # "I don't think Tom is sorry."
    ("en", 1037301, "good", {"great", "nice", "fine", "excellent"}),
    ("en", 7325634, "decided", {"planned", "wanted", "tried", "chose"}),
    ("en", 8462381, "happened", {"came", "occurred"}),
    ("ja", 1273307, "人", {"者", "方"}),
]
KNOWN_BAD_EXTRA = [("en", 3869718, {"nice", "great", "fine"}), ("en", 17424, {"designed"})]


def _inproc():
    sys.path.insert(0, HERE)
    import lesson_rules
    if not lesson_rules.H:
        cur = json.load(open(os.path.join(HERE, "curriculum.json"), encoding="utf-8-sig"))
        lesson_rules.init(curriculum=lambda: cur, plain=lambda s: str(s or "").replace("**", "").replace("`", ""),
                          ja_reading=lambda s: "", log=None, ApiError=Exception)
    return lesson_rules


def _forced(lr, filters_on=True):
    """{(lang, sid): result of lesson_rules.make_items_for_id}; filters_on=False disables the distractor checks (negative control)"""
    saved = (lr.Maker.fits, lr.Maker.slot_taken)
    if not filters_on:
        lr.Maker.fits = lambda self, *a, **k: False
        lr.Maker.slot_taken = lambda self, *a, **k: False
    try:
        out = {}
        for lang, sid in {(b[0], b[1]) for b in KNOWN_BAD} | {(b[0], b[1]) for b in KNOWN_BAD_EXTRA}:
            out[(lang, sid)] = lr.make_items_for_id(lang, sid, seeds=range(150))
        return out
    finally:
        lr.Maker.fits, lr.Maker.slot_taken = saved


def test_known_bad():
    print("\n== known bad items (forced generation, 150 seeds each)")
    lr = _inproc()
    good = _forced(lr, True)
    for lang, sid, ans, banned in KNOWN_BAD:
        got = good[(lang, sid)]["fills"].get(ans, set())
        hit = banned & got
        print("  #%s %-4s blank %-9s distractors seen: %3d  banned present: %s" % (sid, lang, ans, len(got), sorted(hit) or "none"))
        if hit:
            fails.append("known bad #%s: %s offered as distractor for %r" % (sid, sorted(hit), ans))
        if len(got) < 3:   # a case that never produces distractors proves nothing
            fails.append("known bad #%s: only %d distractors seen for %r in 150 seeds; the case checks nothing, pick another sentence" % (sid, len(got), ans))
    for lang, sid, banned in KNOWN_BAD_EXTRA:
        got = good[(lang, sid)]["extras"]
        hit = banned & got
        print("  #%s %-4s extra tiles seen: %3d  banned present: %s" % (sid, lang, len(got), sorted(hit) or "none"))
        if hit:
            fails.append("known bad #%s: %s offered as extra tile" % (sid, sorted(hit)))
    # negative control: with the checks switched off the same test must see the bad words (otherwise the test proves nothing)
    raw = _forced(lr, False)
    seen = 0
    for lang, sid, ans, banned in KNOWN_BAD:
        seen += bool(banned & raw[(lang, sid)]["fills"].get(ans, set()))
    for lang, sid, banned in KNOWN_BAD_EXTRA:
        seen += bool(banned & raw[(lang, sid)]["extras"])
    total = len(KNOWN_BAD) + len(KNOWN_BAD_EXTRA)
    print("  negative control (checks off): %d of %d known bad items show the bad word" % (seen, total))
    if seen < total - 2:
        fails.append("negative control: only %d of %d known bad items reappear with the checks off; the test cannot detect them" % (seen, total))


def _strings(e):
    out = []
    for k in ("question", "sentence", "audio", "text", "ko", "answer", "options", "extra"):
        v = e.get(k)
        if isinstance(v, str):
            out.append(v)
        elif isinstance(v, list):
            out += [x for x in v if isinstance(x, str)]
    return out


def test_block_list(n=200):
    print("\n== block list over %d lessons per language (sentences, options, distractors, extra tiles)" % n)
    lr = _inproc()
    rng = random.Random(23)
    for lang in ("en", "ja"):
        seen = checked = 0
        for k in range(n):
            m, w = rng.randint(1, 12), rng.randint(1, 4)
            r = requests.post(BASE + "/lesson", json={"lang": lang, "month": m, "week": w, "stage": (m + 2) // 3, "source": "tatoeba"}, timeout=60)
            if r.status_code != 200:
                fails.append("block test %s lesson %d: HTTP %d" % (lang, k, r.status_code))
                continue
            for e in r.json()["exercises"]:
                for s_ in _strings(e):
                    checked += 1
                    if lr.blocked(s_) or lr.BLOCK_KO.search(s_):
                        seen += 1
                        fails.append("block list hit in %s lesson %d %s: %r" % (lang, k, e["type"], s_[:80]))
        print("  %s: %d strings checked, %d block-list hits" % (lang, checked, seen))
    # the block list itself: each required word must be caught (and innocent words must not be)
    must = ["terrorist", "Terrorists", "terrorism", "porn", "Pornography", "abuse", "abused", "rape", "suicide", "killed", "murder", "cancer",
            "bomb", "bombs", "bombed", "gun", "guns", "drug", "drugs", "naked", "sex", "sexual", "sexy", "nazi", "slave", "slavery", "racist",
            "killing of people", "heroin", "cocaine", "meth", "marijuana", "cannabis", "opium", "addict", "addicted", "addictive", "kidnap",
            "kidnapped", "kidnapping", "torture", "tortured", "violence", "violent", "abortion", "condom", "condoms", "knife", "knives",
            "prison", "prisons", "prisoner", "prisoners", "church", "churches", "hate", "hated", "hatred", "ugly", "uglier"]
    miss = [w_ for w_ in must if not lr.blocked("He said %s today." % w_)]
    must_sent = ["Tom is addicted to heroin.", "I'm a cocaine addict.", "She had an abortion.", "Do you have a condom?",
                 "Mary was kidnapped by pirates.", "Gustavo was tied to a chair that was used to torture Rima.", "Fadil had a reputation for violence.",
                 "Have you already sharpened the knives?", "The prisoners were set free.", "There are two churches on this street."]
    miss += [t_ for t_ in must_sent if not lr.blocked(t_)]
    ja_must = ["テロ", "殺", "殺す", "死ね", "自殺", "ポルノ", "麻薬", "爆弾", "虐待", "誘拐", "拷問", "覚醒剤", "中絶", "ヘロイン", "コカイン", "バカ", "ばか", "馬鹿",
               "くそ", "戦争", "銃", "血", "神", "酔っ払い", "タバコ", "レイプ", "セックス", "死亡", "殺人"]
    miss += [w_ for w_ in ja_must if not lr.blocked("これは" + w_ + "です。")]
    miss += [t_ for t_ in ["彼は子供を虐待した。", "彼女は誘拐された。", "拷問を受けた。", "覚醒剤を使った。", "彼女は中絶した。", "バカ野郎！", "テロが起きた。"]
             if not lr.blocked(t_)]
    if miss:
        fails.append("block list misses: %s" % miss)
    innocent = ["The grape and the therapist are nice. I like skates and assorted pasta in the classroom.", "A sextant is on the ship.",
                "She flew to Bombay.", "My assistant likes his skill.", "He lives in Essex.", "The class is a grape harvest.", "I'm a method actor.",
                "The hat is on the table.", "She is pregnant and goes to a funeral.", "Hello, my name is Tom."]
    ja_innocent = ["ばかり食べている。", "神戸に行きました。", "神社でお参りした。", "神経が太い。", "血液型は何ですか。", "ナチュラルな色ですね。", "テロップが出た。",
                   "死角に入った。", "彼女は妊娠した。", "葬儀に出た。", "必死に走った。", "バカンスに行く。", "精神が強い。", "血圧が低い。", "献血に行った。"]
    over = [t_ for t_ in innocent + ja_innocent if lr.blocked(t_)]
    if over:
        fails.append("block list matches innocent text: %s" % over)
    print("  required words all caught: %s; innocent texts all pass: %s" % (not miss, not over))


def test_option_words(n=150):
    """wrong options of fill exercises and extra tiles of build exercises (English) must be independent, reasonably common words"""
    print("\n== English wrong options / extra tiles over %d lessons: real words only" % n)
    lr = _inproc()
    import reading
    rng = random.Random(41)
    checked = 0
    bad_words = {}
    for k in range(n):
        m, w = rng.randint(1, 12), rng.randint(1, 4)
        r = requests.post(BASE + "/lesson", json={"lang": "en", "month": m, "week": w, "stage": (m + 2) // 3, "source": "tatoeba"}, timeout=60)
        if r.status_code != 200:
            fails.append("option-word test lesson %d: HTTP %d" % (k, r.status_code))
            continue
        for e in r.json()["exercises"]:
            words = []
            if e["type"] == "fill":
                words = [o for j, o in enumerate(e["options"]) if j != e["answer"]]
            elif e["type"] == "build":
                words = list(e.get("extra") or [])
            for w_ in words:
                checked += 1
                z = reading.zipf(w_, "en")
                if w_.lower() in lr.AFFIXES or z < 3.0 or not w_.isalpha():
                    bad_words[w_] = z
    print("  %d words checked, %d not real independent words %s" % (checked, len(bad_words), sorted(bad_words)[:12]))
    if bad_words:
        fails.append("wrong options / extra tiles that are no independent words: %s" % sorted(bad_words.items()))


def test_db_validity():
    print("\n== tatoeba_ready() on bad files (in-process)")
    import tempfile
    sys.path.insert(0, HERE)
    import reading
    saved = reading.DB_PATH
    tmp = tempfile.mkdtemp(prefix="lessonfix_")
    try:
        cases = {}
        p = os.path.join(tmp, "empty.sqlite"); open(p, "wb").close(); cases["empty file"] = (p, False)
        p = os.path.join(tmp, "text.sqlite"); open(p, "wb").write(b"this is not a database" * 500); cases["text file"] = (p, False)
        p = os.path.join(tmp, "notables.sqlite"); c = sqlite3.connect(p); c.execute("CREATE TABLE x(a)"); c.commit(); c.close(); cases["sqlite without the tables"] = (p, False)
        p = os.path.join(tmp, "trunc.sqlite"); open(p, "wb").write(open(DB, "rb").read(300000)); cases["truncated real DB"] = (p, False)
        cases["missing file"] = (os.path.join(tmp, "nope.sqlite"), False)
        cases["the real DB"] = (DB, True)
        for name, (path, want) in cases.items():
            reading.DB_PATH = path
            reading._ready["key"] = None
            got = reading.tatoeba_ready()
            print("  %-28s -> %s" % (name, got))
            if got != want:
                fails.append("tatoeba_ready() for %s = %s (want %s)" % (name, got, want))
    finally:
        reading.DB_PATH = saved
        reading._ready["key"] = None
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


def test_ai_fallback():
    """The checker call fails / skips items / leaves < 4 items -> a Tatoeba lesson with fallback_reason, never the unchecked AI lesson."""
    print("\n== AI lesson fallback (in-process server module, stubbed LLM)")
    sys.argv += ["--port", "8799", "--tag", "unit_fallback", "--stt-cpu"]  # server.py: no config writes, own log file
    sys.path.insert(0, HERE)
    cwd = os.getcwd()
    os.chdir(HERE)
    try:
        import server
    finally:
        os.chdir(cwd)
    AI = {"title": "AI 레슨", "exercises": [
        {"type": "choice", "question": "What does 'apple' mean?", "options": ["사과", "배", "포도", "귤"], "answer": 0, "explain": "사과예요."},
        {"type": "listen", "audio": "I eat an apple every morning.", "options": ["나는 매일 아침 사과를 먹는다", "나는 학교에 간다", "그는 책을 읽는다", "비가 온다"], "answer": 0, "explain": "듣기"},
        {"type": "build", "ko": "나는 학생이에요.", "answer": ["I", "am", "a", "student"], "extra": ["is", "an"], "explain": "빌드"},
        {"type": "speak", "text": "Nice to meet you.", "ko": "만나서 반가워요.", "explain": ""},
        {"type": "choice", "question": "Which one is a color?", "options": ["red", "run", "eat", "sit"], "answer": 0, "explain": "색"},
        {"type": "build", "ko": "그는 의사예요.", "answer": ["He", "is", "a", "doctor"], "extra": ["are", "an"], "explain": "빌드"},
    ]}
    req = server.LessonReq(lang="en", month=1, week=1, source="ai")
    saved = server.ollama_json
    saved_ready = server.readmode.tatoeba_ready

    def make_stub(verify):
        def stub(messages, schema, **kw):
            if kw.get("cache_key_kind") == "verify":
                return verify(messages[0]["content"])
            return json.loads(json.dumps(AI))
        return stub

    def verify_ok(prompt):  # solve the items: the right option is the one the stub lesson marks correct
        items = json.loads(prompt[prompt.index("[{"):prompt.index("\n\nReply with JSON")])
        right = {"What does 'apple' mean?": "사과", "I eat an apple every morning.": "나는 매일 아침 사과를 먹는다", "Which one is a color?": "red"}
        out = []
        for it in items:
            key = it.get("question") or it.get("sentence")
            ans = it["options"].index(right[key]) if "options" in it and key in right else -1
            out.append({"id": it["id"], "answer": ans, "a": "O", "b": "O", "c": "O", "d": "O", "e": "O"})
        return {"answers": out}

    def run(name, verify, want_fallback, ready=True, want_503=False):
        server.ollama_json = make_stub(verify)
        server.readmode.tatoeba_ready = saved_ready if ready else (lambda: False)
        try:
            try:
                d = server.lesson(req)
                err = None
            except server.ApiError as e:
                d, err = None, e
        finally:
            server.ollama_json = saved
            server.readmode.tatoeba_ready = saved_ready
        if want_503:
            ok = err is not None and err.status == 503 and re.search(r"[가-힣]", err.msg)
            print("  %-34s -> %s" % (name, ("HTTP %s %s" % (err.status, err.msg)) if err else "no error!"))
        elif want_fallback:
            ok = (err is None and d.get("source") == "tatoeba" and d.get("fallback_reason") and len(d["exercises"]) >= 4
                  and all(e.get("tatoeba_id") for e in d["exercises"]))
            print("  %-34s -> source=%s fallback_reason=%s exercises=%d" % (name, d and d.get("source"), d and d.get("fallback_reason"), d and len(d["exercises"]) or 0))
        else:
            ok = err is None and d.get("source") == "ai" and "fallback_reason" not in d and len(d["exercises"]) >= 4
            print("  %-34s -> source=%s exercises=%d" % (name, d and d.get("source"), d and len(d["exercises"]) or 0))
        if not ok:
            fails.append("AI fallback case failed: " + name)

    def boom(_p):
        raise server.ApiError("checker down", 502)

    run("checker call fails (ApiError)", boom, True)
    run("checker call fails (other error)", lambda _p: (_ for _ in ()).throw(RuntimeError("x")), True)
    run("checker skips items", lambda p: {"answers": verify_ok(p)["answers"][:3]}, True)
    run("checker returns nothing", lambda _p: {"answers": []}, True)
    run("checker rejects all but 3 items", lambda p: {"answers": [dict(a, a="X") if a["id"] >= 3 else a for a in verify_ok(p)["answers"]]}, True)
    run("checker passes everything (control)", verify_ok, False)
    run("checker fails + Tatoeba not ready", boom, False, ready=False, want_503=True)


def show(lang, d):
    print("\n--- sample %s lesson: %s" % (lang, d["title"]))
    for e in d["exercises"]:
        t = e["type"]
        if t in ("choice", "listen", "fill"):
            head = e.get("question") or e.get("audio") or e.get("sentence")
            opts = " / ".join(("*" if j == e["answer"] else "") + o for j, o in enumerate(e["options"]))
            extra = ("  (ko: %s)" % e["ko"]) if t == "fill" else ""
            print("  [%s] %s%s\n        %s" % (t, head.replace("\n", " | "), extra, opts))
        elif t == "build":
            print("  [build] %s -> %s  + extra %s" % (e["ko"], " / ".join(e["answer"]), e["extra"]))
        else:
            print("  [speak] %s (%s)" % (e["text"], e["ko"]))
        if e.get("reading"):
            print("        reading: %s" % e["reading"])
        if e.get("explain"):
            print("        explain: %s" % e["explain"])


def test_corrupt_server():
    """For a test server started with HOEHWA_TATOEBA_DB=<empty or non-SQLite file> (and HOEHWA_TEST_HOOKS=1 + --ollama-url on a closed
    port so the AI path fails fast): /lesson must answer with a lesson or a Korean error, never 500."""
    print("\n== server with a corrupted Tatoeba DB:", BASE)
    h = requests.get(BASE + "/health", timeout=30).json()
    print("  /health tatoeba =", h.get("tatoeba"))
    if h.get("tatoeba") is not False:
        fails.append("/health says tatoeba=%r for a corrupted DB" % h.get("tatoeba"))
    real = "--real-llm" in sys.argv  # no simulated engine failure: the AI path really runs (slow; 2 requests only)
    if not real:
        requests.post(BASE + "/debug/engine_limit", json={"message": "usage limit reached"}, timeout=30)  # needs HOEHWA_TEST_HOOKS=1
    for lang in ("en", "ja"):
        for src in ((None,) if real else (None, "tatoeba", "ai")):
            body = {"lang": lang, "month": 2, "week": 1}
            if src:
                body["source"] = src
            r = requests.post(BASE + "/lesson", json=body, timeout=600)
            try:
                d = r.json()
            except Exception:
                d = {}
            msg = d.get("error", "")
            ok = (r.status_code == 200 and len(d.get("exercises") or []) >= 4) or \
                 (r.status_code in (502, 503, 504) and re.search(r"[가-힣]", msg))
            print("  /lesson %s source=%-7s -> HTTP %d %s" % (lang, src, r.status_code, msg[:60] or ("%d exercises" % len(d.get("exercises") or []))))
            if not ok or r.status_code == 500:
                fails.append("corrupt DB: /lesson %s %s -> HTTP %d %s" % (lang, src, r.status_code, r.text[:120]))
    r = requests.get(BASE + "/examples", params={"lang": "en", "q": "house"}, timeout=30)
    print("  /examples -> HTTP", r.status_code)
    if r.status_code != 503:
        fails.append("corrupt DB: /examples -> HTTP %d (want 503)" % r.status_code)
    requests.post(BASE + "/debug/engine_limit", json={"message": "", "clear": True}, timeout=30)
    print("\n%d problem(s)" % len(fails))
    for f in fails:
        print("  FAIL", f)
    sys.exit(1 if fails else 0)


def main():
    print("server:", BASE)
    if "--corrupt-db" in sys.argv:
        test_corrupt_server()
    rng = random.Random(7)
    for lang in ("en", "ja"):
        r = requests.post(BASE + "/lesson", json={"lang": lang, "month": 1, "week": 1}, timeout=120)  # warm the pool
        print("%s warm-up call: HTTP %d" % (lang, r.status_code))
        times = []
        samples = []
        for k in range(N):
            m, w = rng.randint(1, 12), rng.randint(1, 4)
            body = {"lang": lang, "month": m, "week": w, "stage": (m + 2) // 3}
            if k % 2:
                body["source"] = "tatoeba"
            t0 = time.time()
            r = requests.post(BASE + "/lesson", json=body, timeout=60)
            times.append(time.time() - t0)
            if r.status_code != 200:
                fails.append("%s lesson %d: HTTP %d %s" % (lang, k, r.status_code, r.text[:200]))
                continue
            d = r.json()
            check_lesson(lang, k, d)
            if k in (0, 1):
                samples.append(d)
        times.sort()
        print("%s: %d lessons, time median %.3fs, max %.3fs" % (lang, N, times[len(times) // 2], times[-1]))
        if times[-1] >= 0.5:
            fails.append("%s: slowest lesson %.3fs >= 0.5s" % (lang, times[-1]))
        for d in samples:
            show(lang, d)
    r = requests.post(BASE + "/lesson", json={"lang": "en", "source": "bogus"}, timeout=30)
    if r.status_code != 400:
        fails.append("source bogus -> HTTP %d (want 400)" % r.status_code)
    print("\nexercise type counts:", {"%s/%s" % k: v for k, v in sorted(counts.items())})
    if "--ai" in sys.argv:
        for lang in ("en", "ja"):
            t0 = time.time()
            r = requests.post(BASE + "/lesson", json={"lang": lang, "month": 2, "week": 1, "source": "ai"}, timeout=600)
            d = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
            n = len(d.get("exercises") or [])
            print("AI lesson %s: HTTP %d, %d exercises, %.1fs, source=%s" % (lang, r.status_code, n, time.time() - t0, d.get("source")))
            if r.status_code != 200 or n < 4 or d.get("source") == "tatoeba":
                fails.append("AI lesson %s failed: %s" % (lang, r.text[:200]))
    if "--no-extra" not in sys.argv:
        test_block_list(200)
        test_option_words(150)
        test_db_validity()
        test_known_bad()
        test_ai_fallback()
    print("\n%d problem(s)" % len(fails))
    for f in fails[:40]:
        print("  FAIL", f)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
