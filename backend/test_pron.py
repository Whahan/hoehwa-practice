# -*- coding: utf-8 -*-
"""Tests the katakana pronunciation form `pron` that every Japanese `reading` now travels with (the app builds its Hangul
sound spelling from it; the spelling-form reading cannot tell a topic は from a は inside a word).

    .venv\\Scripts\\python.exe test_pron.py                       in-process only (no network, no Ollama, nothing on a port)
    .venv\\Scripts\\python.exe test_pron.py --base http://127.0.0.1:18791   also checks a RUNNING test server:
                                                                  POST /lesson (tatoeba), GET /practice/sentences, POST /reading/gloss is not called (needs an LLM)

In-process: ja_reading / ja_pron (values, never an ideograph, ___ and punctuation kept, cached), POST /chat and /feedback result
shapes with a stub engine, the LLM lesson exercise normaliser, the rule lesson builder's helper, reading.gloss with a stub engine.
Writes only under a temp folder (the cache DB and the gloss cache go there). Exit code 1 on any FAIL.
"""
import io
import json
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

TMP = tempfile.mkdtemp(prefix="hoehwa_pron_")
os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(TMP, "espeak")
BASE_URL = ""
if "--base" in sys.argv:
    BASE_URL = sys.argv[sys.argv.index("--base") + 1].rstrip("/")
    if BASE_URL.endswith(":8770") or BASE_URL.endswith(":8775") or BASE_URL.endswith(":8776"):
        sys.exit("--base points at an app port: refused. Start your own test server on a free port (18791-18799).")
sys.argv = [sys.argv[0], "--tag", "unit_pron"]

import llm_cache
llm_cache.DB_PATH = os.path.join(TMP, "llm_cache.sqlite")
llm_cache._conn = None
import server
import reading as readmode
import lesson_rules

readmode.GLOSS_CACHE = os.path.join(TMP, "gloss.json")
if hasattr(readmode, "_gcache"):
    readmode._gcache = None

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


KATA_OK = re.compile(r"^[ァ-ヶー、。！？「」『』（）・…~〜:;,.!?\"'_\-\s\[\]()]*$")
IDEO = re.compile(r"[㐀-䶿一-鿿]")
HIRA = re.compile(r"[ぁ-ゖ]")


def test_values():
    print("== 1. ja_reading / ja_pron")
    cases = [
        ("私は学生です。", "わたしはがくせいです。", "ワタシワガクセーデス。"),
        ("この部屋は広いです。", "このへやはひろいです。", "コノヘヤワヒロイデス。"),
        ("こんにちは", "こんにちは", "コンニチワ"),
        ("学校へ行きます。", "がっこうへいきます。", "ガッコーエイキマス。"),
        ("待っています。", "まっています。", "マッテイマス。"),
        ("お母さんはうちにいます。", "おかあさんはうちにいます。", "オカーサンワウチニイマス。"),
        ("花は赤いです。", "はなはあかいです。", "ハナワアカイデス。"),
        ("毎朝走ります。", "まいあさはしります。", "マイアサハシリマス。"),
        ("水をください。", "みずをください。", "ミズヲクダサイ。"),
        ("コーヒーを飲みます。", "こーひーをのみます。", "コーヒーヲノミマス。"),
    ]
    for text, rd, pr in cases:
        r, p = server.ja_reading(text), server.ja_pron(text)
        check("reading of %s" % text, r == rd, r)
        check("pron of %s" % text, p == pr, p)
    # the same readings as before the change (the hiragana reading is untouched)
    for text, pr in [("言うことを聞いてください。", "ユーコトヲキイテクダサイ。"), ("と言う。", "トユー。"), ("彼は何も言わない。", None),
                     ("若いうちに勉強する。", "ワカイウチニ"), ("知らないうちに寝た。", "シラナイウチニ"), ("いいうえに安い。", "イイウエニ")]:
        p = server.ja_pron(text)
        if pr is None:
            check("pron of %s keeps イワ (only the form イウ becomes ユー)" % text, "イワナイ" in p, p)
        elif pr.endswith("。"):
            check("pron of %s" % text, p == pr, p)
        else:
            check("pron of %s keeps イウ (not the verb 言う)" % text, pr in p and "ユー" not in p, p)
    check("pron of という is ユー", server.ja_pron("という") == "トユー", server.ja_pron("という"))
    check("empty -> '' and ''", server.ja_reading("") == "" and server.ja_pron("") == "" and server.ja_pron(None) == "")
    check("spaces only -> ''", server.ja_pron("   ") == "")
    r, p = server.ja_reading("私は___です。"), server.ja_pron("私は___です。")
    check("___ kept in reading and pron", "___" in r and "___" in p, (r, p))
    p = server.ja_pron("今日は,いい天気ですね!")
    check("ASCII punctuation becomes Japanese punctuation in pron too", ("、" in p or "，" in p) and "！" in p and "," not in p and "!" not in p, p)
    for t in ["彼は医者です。", "ご注文はお決まりですか。", "3時にしましょう。", "ハングルを学ぶのは難しいです。", "买东西"]:
        p = server.ja_pron(t)
        check("pron of %r: katakana / long mark / punctuation only, no ideograph, no hiragana" % t,
              KATA_OK.match(p) is not None and not IDEO.search(p) and not HIRA.search(p), p)
        check("reading of %r has no ideograph" % t, not IDEO.search(server.ja_reading(t)))
    check("a stray accent mark never reaches pron", "’" not in server.ja_pron("橋を渡る。") and "'" not in server.ja_pron("橋を渡る。"))
    a = server.ja_pron("私は学生です。")
    b = server.ja_pron("私は学生です。")
    check("second call (cache) gives the same value", a == b == "ワタシワガクセーデス。")
    # a deliberately wrong expectation must NOT pass (the checker can fail)
    check("(negative) topic は is ワ, not ハ", server.ja_pron("私は学生です。") != "ワタシハガクセーデス。")


def stub_engine():
    server.llm_provider = lambda: "ollama"
    server.remote_route_active = lambda: False
    server.translate_ko = lambda text, lang: ""
    server.correct_learner = lambda *a, **k: ("", "")


def test_chat():
    print("== 2. /chat and /feedback shapes (stub engine)")
    stub_engine()
    T = server.Turn

    def local(msgs, schema, **kw):
        if "scores" in json.dumps(schema, ensure_ascii=False):
            return {"scores": {"fluency": 3, "accuracy": 3, "vocabulary": 3}, "summary": "잘했어요. 조금만 더 연습해요.",
                    "corrections": [{"you": "わたしは学生だです", "better": "私は学生です。", "reading": "", "ko": "저는 학생이에요.", "why": "だです는 쓰지 않아요."}],
                    "phrases": [{"phrase": "駅はどこですか。", "reading": "", "ko": "역은 어디예요?"}, {"phrase": "水をください。", "reading": "", "ko": "물 주세요."},
                                {"phrase": "お願いします。", "reading": "", "ko": "부탁해요."}]}
        return {"reply": "私は学生です。あなたは?", "ko": "저는 학생이에요. 당신은요?", "reading": "", "suggest": ["はい。", "いいえ。"]}
    server.ollama_json = local
    r = server.run_chat(server.ChatReq(lang="ja", month=1, week=1, conv_id="p1", skip_fix=True, history=[T(role="me", text="こんにちは")]))
    check("chat ja: reply/reading/pron present", r["reply"] and r["reading"] and r["pron"], r)
    check("chat ja: pron is the pronunciation form of the reply", r["pron"].startswith("ワタシワガクセーデス"), r["pron"])
    check("chat ja: reading is still hiragana only", re.fullmatch(r"[ぁ-ゖー、。！？\s]+", r["reading"]) is not None, r["reading"])
    check("chat ja: key set", set(r) == {"reply", "reading", "pron", "ko", "fix", "fix_ko", "suggest"}, sorted(r))
    server.ollama_json = lambda msgs, schema, **kw: {"reply": "Nice to meet you.", "ko": "만나서 반갑습니다.", "reading": "", "suggest": ["Me too.", "Thanks."]}
    r = server.run_chat(server.ChatReq(lang="en", month=1, week=1, conv_id="p2", skip_fix=True, history=[T(role="me", text="Hi")]))
    check("chat en: pron is '' and reading is ''", r["pron"] == "" and r["reading"] == "", r)
    server.ollama_json = local
    f = server.run_feedback(server.FeedbackReq(lang="ja", stage=1, history=[T(role="ai", text="こんにちは"), T(role="me", text="わたしは学生だです")]))
    check("feedback ja: corrections carry reading + pron", f["corrections"] and all(c["reading"] and c["pron"] for c in f["corrections"]), f["corrections"])
    check("feedback ja: phrases carry reading + pron", f["phrases"] and all(c["reading"] and c["pron"] for c in f["phrases"]), f["phrases"])
    check("feedback ja: a correction's pron matches ja_pron(better)", f["corrections"][0]["pron"] == server.ja_pron(f["corrections"][0]["better"]))
    check("feedback ja: exact key sets", all(set(c) == {"you", "better", "reading", "pron", "ko", "why"} for c in f["corrections"])
          and all(set(c) == {"phrase", "reading", "pron", "ko"} for c in f["phrases"]))
    server.ollama_json = lambda msgs, schema, **kw: {"scores": {"fluency": 3, "accuracy": 3, "vocabulary": 3}, "summary": "Good job. Keep going.",
        "corrections": [{"you": "I has", "better": "I have a pen.", "reading": "", "ko": "나는 펜이 있어요.", "why": "have 를 써요."}],
        "phrases": [{"phrase": "Nice to meet you.", "reading": "", "ko": "만나서 반가워요."}]}
    f = server.run_feedback(server.FeedbackReq(lang="en", stage=1, history=[T(role="ai", text="Hello"), T(role="me", text="I has")]))
    check("feedback en: pron is ''", all(c["pron"] == "" for c in f["corrections"] + f["phrases"]), f)


def test_lessons():
    print("== 3. lesson exercises")
    ex = [
        {"type": "fill", "sentence": "わたしは___です。", "reading": "", "ko": "저는 학생이에요.", "options": ["学生", "先生", "医者", "会社員"], "answer": 0, "explain": "x"},
        {"type": "listen", "audio": "駅はどこですか。", "reading": "", "options": ["역은 어디예요?", "물 주세요", "고맙습니다", "안녕하세요"], "answer": 0, "explain": "x"},
        {"type": "build", "ko": "저는 학생이에요.", "answer": ["私は", "学生", "です"], "extra": ["先生", "医者"], "reading": "", "explain": "x"},
        {"type": "speak", "text": "お母さんはうちにいます。", "reading": "", "ko": "엄마는 집에 있어요."},
    ]
    for e in ex:
        o = server.finish_ex(e, "ja")
        check("LLM lesson %s (ja): reading + pron" % e["type"], o is not None and o.get("reading") and o.get("pron"), o)
        if o:
            src = o.get("sentence") if e["type"] == "fill" else o.get("audio") if e["type"] == "listen" else "".join(o["answer"]) if e["type"] == "build" else o.get("text")
            check("  pron == ja_pron(source)", o["pron"] == server.ja_pron(src), (o["pron"], server.ja_pron(src)))
    en = server.finish_ex({"type": "speak", "text": "Nice to meet you.", "reading": "", "ko": "x"}, "en")
    check("LLM lesson speak (en): reading '' and no pron key needed", en is not None and en.get("reading", "") == "")
    # the rule lesson builder (no engine): pron next to reading for every exercise type that has a reading
    lesson_rules.init(ja_reading=server.ja_reading, ja_pron=server.ja_pron)
    b = lesson_rules.Builder.__new__(lesson_rules.Builder) if hasattr(lesson_rules, "Builder") else None
    cls = None
    for name in dir(lesson_rules):
        o = getattr(lesson_rules, name)
        if isinstance(o, type) and hasattr(o, "pron") and hasattr(o, "reading"):
            cls = o
    check("lesson_rules builder class has pron()", cls is not None)
    if cls:
        inst = cls.__new__(cls)
        inst.lang = "ja"
        check("builder.pron('私は学生です。')", inst.pron("私は学生です。") == "ワタシワガクセーデス。", inst.pron("私は学生です。"))
        inst.lang = "en"
        check("builder.pron on English is ''", inst.pron("Hello") == "" and inst.reading("Hello") == "")
        lesson_rules.init(ja_pron=None)
        inst.lang = "ja"
        check("builder.pron without the helper is '' (old harness)", inst.pron("私は学生です。") == "")
        lesson_rules.init(ja_pron=server.ja_pron)


def test_gloss():
    print("== 4. /reading/gloss")
    readmode.init(ja_pron=server.ja_pron)

    def fake(msgs, schema, **kw):
        return {"glosses": [{"i": 1, "lemma": "学校", "pos": "명사", "ko": "학교", "ipa": "", "note": ""},
                            {"i": 2, "lemma": "行く", "pos": "동사", "ko": "가다", "ipa": "", "note": ""}]}
    readmode.H["ollama_json"] = fake
    readmode.H["ko_ok"] = server.ko_ok
    out = readmode.gloss("ja", [{"lemma": "学校", "sentence": "学校へ行きます。"}, {"lemma": "行く", "sentence": "学校へ行きます。"}])
    gl = out["glosses"]
    check("ja gloss: ipa (hiragana) and pron (katakana) per word", len(gl) == 2 and gl[0]["ipa"] == "がっこう" and gl[0]["pron"] == "ガッコー"
          and gl[1]["ipa"] == "いく" and gl[1]["pron"] == "イク", gl)
    check("ja gloss: fields", all(set(g) == {"i", "lemma", "pos", "ko", "ipa", "note", "pron"} for g in gl))
    readmode.H["ollama_json"] = lambda msgs, schema, **kw: {"glosses": [{"i": 1, "lemma": "run", "pos": "verb", "ko": "달리다", "ipa": "rʌn", "note": ""}]}
    out = readmode.gloss("en", [{"lemma": "run", "sentence": "I run."}])
    check("en gloss: pron ''", out["glosses"][0]["pron"] == "", out)


def test_live():
    if not BASE_URL:
        print("== 5. live server: skipped (no --base)")
        return
    import requests
    print("== 5. live server %s" % BASE_URL)
    r = requests.post(BASE_URL + "/lesson", json={"lang": "ja", "month": 1, "week": 1, "stage": 1}, timeout=120)
    check("POST /lesson ja -> 200", r.status_code == 200, r.text[:200])
    d = r.json() if r.status_code == 200 else {}
    need = [e for e in d.get("exercises", []) if e.get("type") in ("fill", "listen", "build", "speak")]
    check("lesson ja: every reading exercise has a pron", need and all(e.get("pron") for e in need), [e.get("type") for e in need if not e.get("pron")])
    check("lesson ja: pron is katakana / ー / punctuation only", all(KATA_OK.match(e["pron"]) and not HIRA.search(e["pron"]) for e in need))
    check("lesson ja: pron differs from the reading only in the spelling (same length +- long marks)", all(abs(len(e["pron"]) - len(e["reading"])) <= 6 for e in need))
    r = requests.post(BASE_URL + "/lesson", json={"lang": "en", "month": 1, "week": 1, "stage": 1}, timeout=120)
    de = r.json() if r.status_code == 200 else {}
    check("lesson en: exercises have no pron text", all(e.get("pron", "") == "" for e in de.get("exercises", [])))
    r = requests.get(BASE_URL + "/practice/sentences", params={"lang": "ja", "mode": "shadow", "n": 6, "seed": 3}, timeout=60)
    ss = r.json().get("sentences", []) if r.status_code == 200 else []
    check("practice ja: sentences carry pron", ss and all(s.get("pron") for s in ss), r.text[:200])
    r = requests.get(BASE_URL + "/practice/sentences", params={"lang": "en", "mode": "shadow", "n": 6, "seed": 3}, timeout=60)
    ss = r.json().get("sentences", []) if r.status_code == 200 else []
    check("practice en: pron ''", ss and all(s.get("pron", "") == "" for s in ss))


if __name__ == "__main__":
    test_values()
    test_chat()
    test_lessons()
    test_gloss()
    test_live()
    bad = [n for n, ok in results if not ok]
    print("\n== pron: %d passed, %d failed ==" % (len(results) - len(bad), len(bad)))
    for n in bad:
        print("   FAIL:", n)
    sys.exit(1 if bad else 0)
