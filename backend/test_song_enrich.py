# -*- coding: utf-8 -*-
"""Tests of song_enrich.py (song study K4). No server, no model, no network: the LLM, readmode (analyze / gloss) and the
Japanese reader are fakes injected with song_enrich.init(). Lyrics used here are written for this test (no real songs).

  .venv\\Scripts\\python.exe -I test_song_enrich.py [--real-reading]
      --real-reading additionally runs readmode.analyze for real (loads spaCy / fugashi; still no LLM, no network).

Last line:  == test_song_enrich: N passed, 0 failed ==   (exit 0)
"""
import ast
import contextlib
import hashlib
import io
import logging
import os
import re
import socket
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import song_enrich as se  # noqa: E402

PASSED, FAILED = [], []


def ok(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if (detail != "" and not cond) else ""))
    return bool(cond)


MARK = "ZZSONGLINEZZ"


# ----------------------------------------------------------------------------------------------
# fakes
# ----------------------------------------------------------------------------------------------
class FakeApiError(Exception):
    pass


class FakeLLM:
    """ollama_json(messages, schema, temperature=, num_predict=, cache_key_kind=, ...) -> scripted answers.
    `batch_fn(calls_index, items)` returns the data for a batch prompt, `one_fn(text)` for a single-line prompt."""

    def __init__(self, batch_fn=None, one_fn=None):
        self.calls = []        # [{"kind", "items", "before", "after", "kw"}]
        self.batch_fn = batch_fn or (lambda n, items: {"lines": [{"i": k + 1, "ko": "번역:" + t} for k, t in enumerate(items)]})
        self.one_fn = one_fn or (lambda text: {"ko": "다시:" + text})
        self.on_call = None

    def __call__(self, messages, schema, temperature=0.7, num_predict=1800, think=False, cache_key_kind="UNSET", validate=None, **kw):
        text = messages[0]["content"]
        rec = {"prompt": text, "kw": {"temperature": temperature, "num_predict": num_predict, "cache_key_kind": cache_key_kind,
                                      "validate": validate, **kw}}
        if "LINE: " in text:
            line = re.search(r"^LINE: (.*)$", text, re.M).group(1)
            rec.update(kind="one", text=line)
        else:
            items = [m.group(2) for m in re.finditer(r"^(\d+)\. (.*)$", text, re.M)]
            rec.update(kind="batch", items=items)
        rec["before"] = [m.group(1) for m in re.finditer(r"^\(context[^)]*\) (.*)$", text.split("LINE: ")[0] if rec["kind"] == "one" else text, re.M)]
        self.calls.append(rec)
        if self.on_call:
            self.on_call(rec)
        if rec["kind"] == "batch":
            return self.batch_fn(len(self.calls) - 1, rec["items"])
        return self.one_fn(rec["text"])


class FakeReadmode:
    def __init__(self, level_of=None, fail_gloss=None):
        self.analyze_calls = []
        self.gloss_calls = []
        self.level_of = level_of or (lambda w: "hard" if len(w) >= 7 else ("mid" if len(w) >= 5 else "easy"))
        self.fail_gloss = fail_gloss or (lambda n: False)   # n = index of the gloss call
        self.drop = set()

    def analyze(self, lang, text):
        self.analyze_calls.append((lang, text))
        if text.startswith("BOOM"):
            raise FakeApiError("analyze broke")
        toks = []
        for k, w in enumerate(text.split()):
            if k:
                toks.append({"t": " ", "w": False, "s": 0})
            z = {"easy": 5.2, "mid": 4.0, "hard": 3.0}[self.level_of(w)]
            toks.append({"t": w, "w": True, "lemma": w.lower(), "zipf": z, "level": self.level_of(w), "s": 0})
        return {"tokens": toks, "sentences": [], "words": []}

    def gloss(self, lang, items):
        n = len(self.gloss_calls)
        self.gloss_calls.append((lang, [dict(it) for it in items]))
        if self.fail_gloss(n):
            raise FakeApiError("gloss failed")
        out = [{"i": k, "lemma": it["lemma"], "pos": "명사", "ko": "뜻:" + it["lemma"][:3] if re.search("[가-힣]", it["lemma"]) else "뜻풀이",
                "ipa": "ipa" if lang == "en" else "よみ", "note": "메모", "pron": ""}
               for k, it in enumerate(items) if it["lemma"] not in self.drop]
        return {"glosses": out}


def fake_ja_reading(t):
    return t.replace("君", "きみ").replace("空", "そら").replace("笑う", "わらう").replace("見", "み")


def fake_ja_pron(t):
    return "".join(chr(ord(c) + 0x60) if "ぁ" <= c <= "ゖ" else c for c in fake_ja_reading(t))


def install(llm=None, rm=None, **over):
    llm = llm or FakeLLM()
    rm = rm or FakeReadmode()
    helpers = dict(readmode=rm, ollama_json=llm, ja_reading=fake_ja_reading, ja_pron=fake_ja_pron, log=logging.getLogger("backend"),
                   ApiError=FakeApiError)
    helpers.update(over)
    se.H.clear()
    se.init(**helpers)
    return llm, rm


def mk_lines(n, base=100, prefix="line"):
    return [{"i": base + k, "text": "%s number%d here" % (prefix, k)} for k in range(n)]


def run(lang, lines, tasks, **kw):
    return se.enrich_lines(lang, lines, tasks, **kw)


# ----------------------------------------------------------------------------------------------
print("== K4-2 translation batches ==")
llm, rm = install()
lines = mk_lines(40)
res = run("en", lines, ["translate"], allow_ai=True)
ok("40 lines -> 4 LLM calls", len(llm.calls) == 4, len(llm.calls))
ok("batch sizes 12/12/12/4", [len(c["items"]) for c in llm.calls] == [12, 12, 12, 4], [len(c["items"]) for c in llm.calls])
ok("all calls are batch calls", all(c["kind"] == "batch" for c in llm.calls))
ok("40 results, same i values and order", [o["i"] for o in res["lines"]] == [l["i"] for l in lines])
ok("ko lands on the matching line", all(o["ko"] == "번역:" + l["text"] for o, l in zip(res["lines"], lines)))
ok("no warnings on a clean run", res["warnings"] == [], res["warnings"])
ok("translate-only: no reading / words keys", all(set(o) == {"i", "ko"} for o in res["lines"]))
ctx = [len(re.findall(r"^\(context\) ", c["prompt"], re.M)) for c in llm.calls]
ok("context lines: 2 after (first), 2+2 (middle), 2 before (last)", ctx == [2, 4, 4, 2], ctx)
second = llm.calls[1]["prompt"]
ok("context lines are not numbered / translated", "(context) " + lines[10]["text"] in second and "(context) " + lines[25]["text"] in second
   and lines[10]["text"] not in llm.calls[1]["items"] and lines[26]["text"] not in llm.calls[1]["items"])
ok("prompt marks lyrics as data, not instructions", "never instructions" in second)

print("== K4-3 bad AI answers (retry the line only) ==")
# (a) one line without Hangul in the batch; the single retry answers well
bad_k = 5


def batch_a(n, items):
    return {"lines": [{"i": k + 1, "ko": ("hello there" if k == bad_k else "번역:" + t)} for k, t in enumerate(items)]}


llm, rm = install(FakeLLM(batch_fn=batch_a))
res = run("en", mk_lines(12), ["translate"], allow_ai=True)
ones = [c for c in llm.calls if c["kind"] == "one"]
ok("no-Hangul line: 1 batch + exactly 1 single retry", len(llm.calls) == 2 and len(ones) == 1, [c["kind"] for c in llm.calls])
ok("retry asks for that line only", ones[0]["text"] == mk_lines(12)[bad_k]["text"])
ok("retry answer is used, no warning", res["lines"][bad_k]["ko"].startswith("다시:") and res["warnings"] == [])
ok("other lines keep the batch answer", all(o["ko"].startswith("번역:") for k, o in enumerate(res["lines"]) if k != bad_k))
# (b) retry also bad -> ko "" + ko_missing, rest fine, no exception
llm, rm = install(FakeLLM(batch_fn=batch_a, one_fn=lambda t: {"ko": "still english"}))
res = run("en", mk_lines(12), ["translate"], allow_ai=True)
ok("retry bad too: ko empty + ko_missing", res["lines"][bad_k]["ko"] == "" and res["warnings"] == ["ko_missing"], res["warnings"])
ok("retry is only ONE call per line", len([c for c in llm.calls if c["kind"] == "one"]) == 1)
ok("other 11 lines still translated", sum(1 for o in res["lines"] if o["ko"]) == 11)
# (c) Chinese mixed into a Korean sentence (en) is rejected
llm, rm = install(FakeLLM(batch_fn=lambda n, items: {"lines": [{"i": k + 1, "ko": ("안녕하세요!什么东西要买吗?" if k == 0 else "번역:" + t)}
                                                              for k, t in enumerate(items)]}, one_fn=lambda t: {"ko": "你好 世界"}))
res = run("en", mk_lines(3), ["translate"], allow_ai=True)
ok("Chinese-mixed answer -> ko_missing for that line only", res["lines"][0]["ko"] == "" and res["lines"][1]["ko"] != "" and res["warnings"] == ["ko_missing"])
# (d) wrong count: fewer entries -> only the missing lines are retried
llm, rm = install(FakeLLM(batch_fn=lambda n, items: {"lines": [{"i": k + 1, "ko": "번역:" + t} for k, t in enumerate(items) if k not in (2, 9)]}))
res = run("en", mk_lines(12), ["translate"], allow_ai=True)
ones = [c["text"] for c in llm.calls if c["kind"] == "one"]
ok("short array: only the 2 missing lines are retried", len(llm.calls) == 3 and ones == [mk_lines(12)[2]["text"], mk_lines(12)[9]["text"]], ones)
ok("short array: all 12 end with Korean, no warning", all(o["ko"] for o in res["lines"]) and res["warnings"] == [])
# (e) too many / duplicate / out-of-range entries are ignored, never shifting the mapping
llm, rm = install(FakeLLM(batch_fn=lambda n, items: {"lines": [{"i": k + 1, "ko": "번역:" + t} for k, t in enumerate(items)]
                                                    + [{"i": 1, "ko": "중복 덮어쓰기"}, {"i": 99, "ko": "범위 밖"}, {"i": 0, "ko": "영번"}, "junk", {"ko": "번호 없음"}]}))
res = run("en", mk_lines(4), ["translate"], allow_ai=True)
ok("longer array: extras ignored, mapping intact, no retry", len(llm.calls) == 1 and [o["ko"] for o in res["lines"]] == ["번역:" + l["text"] for l in mk_lines(4)])
# (f) unusable shapes -> every line retried on its own, never a whole-song failure
for label, bad in (("not a dict", ["x"]), ("lines is a string", {"lines": "abc"}), ("empty dict", {}), ("None", None)):
    llm, rm = install(FakeLLM(batch_fn=lambda n, items, b=bad: b))
    res = run("en", mk_lines(3), ["translate"], allow_ai=True)
    ok("unusable answer (%s): 3 single retries, all translated" % label, len(llm.calls) == 4 and all(o["ko"].startswith("다시:") for o in res["lines"]), len(llm.calls))
# (g) the LLM raises: first retry fails too -> second consecutive failure stops the retries (no 12 slow calls)
boom = lambda *a, **k: (_ for _ in ()).throw(FakeApiError("down"))
llm, rm = install(FakeLLM(batch_fn=boom, one_fn=boom))
res = run("en", mk_lines(12), ["translate"], allow_ai=True)
ok("AI down: no exception, all ko empty + ko_missing", all(o["ko"] == "" for o in res["lines"]) and res["warnings"] == ["ko_missing"])
ok("AI down: calls stop after 2 consecutive failures", len(llm.calls) == 2, len(llm.calls))
# a transient batch failure recovers through single retries
state = {"n": 0}


def flaky(n, items):
    if n == 0:
        raise FakeApiError("once")
    return {"lines": [{"i": k + 1, "ko": "번역:" + t} for k, t in enumerate(items)]}


llm, rm = install(FakeLLM(batch_fn=flaky))
res = run("en", mk_lines(3), ["translate"], allow_ai=True)
ok("batch raised once: single retries rescue the lines", all(o["ko"].startswith("다시:") for o in res["lines"]) and res["warnings"] == [])
# Japanese: Hanja-heavy answer without Hangul rejected; Hangul with a few Hanja allowed (ko_ok rules)
llm, rm = install(FakeLLM(batch_fn=lambda n, items: {"lines": [{"i": 1, "ko": "你好世界我們"}, {"i": 2, "ko": "나는 君이 좋아"}]}, one_fn=lambda t: {"ko": ""}))
res = run("ja", [{"i": 0, "text": "あ"}, {"i": 1, "text": "い"}], ["translate"], allow_ai=True)
ok("ja: Hanja-only rejected, Hangul with little Hanja kept", res["lines"][0]["ko"] == "" and res["lines"][1]["ko"] == "나는 君이 좋아")

print("== K4-4 cache_key_kind ==")
llm, rm = install(FakeLLM(batch_fn=batch_a, one_fn=lambda t: {"ko": "다시:" + t}))
run("en", mk_lines(13), ["translate"], allow_ai=True)
ok("every LLM call carries cache_key_kind=None (batch + retry)", len(llm.calls) >= 3 and all(c["kw"]["cache_key_kind"] is None for c in llm.calls),
   [c["kw"]["cache_key_kind"] for c in llm.calls])
ok("no validate callback (nothing cached)", all(c["kw"]["validate"] is None for c in llm.calls))
src = open(os.path.join(HERE, "song_enrich.py"), encoding="utf-8").read()
ok("source never names a cache kind", not re.search(r'cache_key_kind\s*=\s*"', src))

print("== K4-5 Japanese reading / pron ==")
llm, rm = install()
ja = [{"i": 0, "text": "君が笑う"}, {"i": 1, "text": "空を見た"}, {"i": 2, "text": ""}]
res = run("ja", ja, ["reading"])
ok("reading equals ja_reading result, pron equals ja_pron result", [(o["reading"], o["pron"]) for o in res["lines"][:2]] ==
   [(fake_ja_reading(l["text"]), fake_ja_pron(l["text"])) for l in ja[:2]], [(o["reading"], o["pron"]) for o in res["lines"][:2]])
ok("reading is hiragana (+ punctuation) only", all(re.fullmatch(r"[ぁ-ゖー・、。！？ ]*", o["reading"]) for o in res["lines"]))
ok("pron is katakana only", all(re.fullmatch(r"[ァ-ヺー・、。！？ ]*", o["pron"]) for o in res["lines"]), [o["pron"] for o in res["lines"]])
ok("reading task alone: no LLM, no gloss, no analyze", not llm.calls and not rm.gloss_calls and not rm.analyze_calls)
ok("empty line gets empty reading / pron", res["lines"][2]["reading"] == "" and res["lines"][2]["pron"] == "")
# exact equality with what ja_reading / ja_pron return when they are clean
install(ja_reading=lambda t: "きみがわらう", ja_pron=lambda t: "キミガワラウ")
res = run("ja", [{"i": 7, "text": "君が笑う"}], ["reading"])
ok("clean ja_reading / ja_pron results pass through unchanged", res["lines"][0] == {"i": 7, "reading": "きみがわらう", "pron": "キミガワラウ"}, res["lines"][0])
# contaminated results are cleaned: ideographs / Latin dropped
install(ja_reading=lambda t: "きみ君がabcわらう買", ja_pron=lambda t: "キミ君xガ")
res = run("ja", [{"i": 0, "text": "君が笑う"}], ["reading"])
ok("ideographs / Latin removed from a bad reader result", res["lines"][0]["reading"] == "きみがわらう" and res["lines"][0]["pron"] == "キミガ", res["lines"][0])
# reader crashes -> empty strings, no exception
install(ja_reading=lambda t: 1 / 0, ja_pron=lambda t: 1 / 0)
res = run("ja", [{"i": 0, "text": "君が笑う"}], ["reading"])
ok("reader exception -> empty reading / pron, no crash", res["lines"][0]["reading"] == "" and res["lines"][0]["pron"] == "")
install()
res = run("en", [{"i": 0, "text": "I feel it"}], ["reading"])
ok("English line: reading and pron are empty", res["lines"][0] == {"i": 0, "reading": "", "pron": ""})

print("== tokens (words) ==")
llm, rm = install()
res = run("en", [{"i": 0, "text": "The breathtaking silence"}, {"i": 1, "text": "BOOM x"}, {"i": 2, "text": "  "}], ["tokens"])
w = res["lines"][0]["words"]
ok("words carry w / lemma / level / zipf / content", [x["w"] for x in w] == ["The", "breathtaking", "silence"] and all(set(x) == {"w", "lemma", "level", "zipf", "content"} for x in w), w)
ok("lemma and level come from analyze", w[1]["lemma"] == "breathtaking" and w[1]["level"] == "hard" and w[1]["zipf"] == 3.0)
ok("stop words are content:false, others true", w[0]["content"] is False and w[1]["content"] is True)
ok("analyze failure -> words [] for that line only", res["lines"][1]["words"] == [] and len(rm.analyze_calls) == 2)
ok("blank line is not analyzed", res["lines"][2]["words"] == [] and all(t.strip() for _l, t in rm.analyze_calls))
ok("tokens task alone: no LLM, no gloss", not llm.calls and not rm.gloss_calls)
ok("tokens task alone: no ko key", all("ko" not in o for o in res["lines"]))
res = run("ja", [{"i": 0, "text": "君が笑う"}], ["tokens"])
ww = res["lines"][0]["words"]
ok("ja words also carry a hiragana reading", ww[0]["w"] == "君が笑う" and ww[0]["reading"].startswith("きみ"), ww)

print("== K4-6 glossary ==")
words = " ".join(["strawberry", "lighthouse", "wonderful"] + ["tiny", "cat", "the", "of", "and"])
llm, rm = install()
res = run("en", [{"i": 0, "text": words}, {"i": 1, "text": "lighthouse strawberry midnight"}], ["gloss"], allow_ai=True)
asked = [it["lemma"] for _l, items in rm.gloss_calls for it in items]
ok("easy words and stop words are never asked", all(a not in asked for a in ("tiny", "cat", "the", "of", "and")), asked)
ok("hard words are asked once each, with their first sentence", asked.count("lighthouse") == 1 and
   [it["sentence"] for _l, items in rm.gloss_calls for it in items if it["lemma"] == "lighthouse"] == [words])
ok("glossary keys are the lemmas, fields pos / ko / ipa / pron", set(res["glossary"]["lighthouse"]) == {"pos", "ko", "ipa", "pron"}, res["glossary"].get("lighthouse"))
ok("gloss-only: no words key, glossary filled", all("words" not in o for o in res["lines"]) and len(res["glossary"]) == len(set(asked)))
ok("gloss-only: LLM batch translate not called", not llm.calls)
# non-content word the analyzer marks: honoured
class ContentRM(FakeReadmode):
    def analyze(self, lang, text):
        r = super().analyze(lang, text)
        for tk in r["tokens"]:
            if tk.get("w"):
                tk["content"] = tk["t"] != "wonderful"
        return r


llm, rm = install(rm=ContentRM())
run("en", [{"i": 0, "text": "wonderful lighthouse"}], ["gloss"], allow_ai=True)
asked = [it["lemma"] for _l, items in rm.gloss_calls for it in items]
ok("a token with content:false is excluded", asked == ["lighthouse"], asked)
# known words
llm, rm = install()
run("en", [{"i": 0, "text": "lighthouse strawberry"}], ["gloss"], known=["lighthouse"], allow_ai=True)
asked = [it["lemma"] for _l, items in rm.gloss_calls for it in items]
ok("known lemmas are excluded", asked == ["strawberry"], asked)
# the 120 cap and the 30 chunk
many = [{"i": k, "text": " ".join("hardword%03d" % (k * 5 + j) for j in range(5))} for k in range(50)]   # 250 distinct hard words
llm, rm = install()
res = run("en", many, ["gloss"], allow_ai=True)
asked = [it["lemma"] for _l, items in rm.gloss_calls for it in items]
ok("250 candidates -> exactly 120 asked", len(asked) == 120 and len(set(asked)) == 120, len(asked))
ok("120 words go out in chunks of <= 30 (4 calls)", [len(i) for _l, i in rm.gloss_calls] == [30, 30, 30, 30])
ok("glossary holds the 120 answered words", len(res["glossary"]) == 120 and res["warnings"] == [])
res = run("en", many, ["gloss"], allow_ai=True, max_gloss=500)
ok("max_gloss cannot raise the cap above 120", sum(len(i) for _l, i in rm.gloss_calls[4:]) == 120)
# hard before mid when over the cap
mixed = [{"i": k, "text": " ".join("mid%03d" % (k * 5 + j) for j in range(5))} for k in range(25)] + [{"i": 99, "text": " ".join("harder%03d" % k for k in range(5))}]
llm, rm = install(rm=FakeReadmode(level_of=lambda w: "hard" if w.startswith("harder") else "mid"))
run("en", mixed, ["gloss"], allow_ai=True)
asked = [it["lemma"] for _l, items in rm.gloss_calls for it in items]
ok("hard words take priority over mid words under the cap", all(("harder%03d" % k) in asked for k in range(5)) and len(asked) == 120)
# partial answers / failures
rm = FakeReadmode()
rm.drop = {"lighthouse"}
llm, rm = install(rm=rm)
res = run("en", [{"i": 0, "text": "lighthouse strawberry"}], ["gloss"], allow_ai=True)
ok("unanswered word -> gloss_missing, others kept", res["warnings"] == ["gloss_missing"] and "strawberry" in res["glossary"] and "lighthouse" not in res["glossary"])
llm, rm = install(rm=FakeReadmode(fail_gloss=lambda n: True))
res = run("en", many, ["gloss"], allow_ai=True)
ok("gloss always raises: no exception, gloss_missing, empty glossary", res["warnings"] == ["gloss_missing"] and res["glossary"] == {})
ok("gloss gives up after 2 consecutive failures", len(rm.gloss_calls) == 2, len(rm.gloss_calls))
llm, rm = install(rm=FakeReadmode(fail_gloss=lambda n: n == 0))
res = run("en", many, ["gloss"], allow_ai=True)
ok("one failed chunk: the others still fill the glossary", len(res["glossary"]) == 90 and res["warnings"] == ["gloss_missing"], len(res["glossary"]))
# readmode.gloss lowercases a capitalised lemma: the answer is mapped by index, keyed by our lemma
class LowerRM(FakeReadmode):
    def gloss(self, lang, items):
        r = super().gloss(lang, items)
        for g in r["glosses"]:
            g["lemma"] = g["lemma"].lower()
        return r


llm, rm = install(rm=LowerRM(level_of=lambda w: "hard"))
res = run("en", [{"i": 0, "text": "Paris"}], ["gloss"], allow_ai=True)
ok("answer mapped by index even if gloss changed the lemma case", "paris" in res["glossary"] or "Paris" in res["glossary"])
llm, rm = install(rm=FakeReadmode(level_of=lambda w: "hard"))
res = run("ja", [{"i": 0, "text": "君が笑う"}], ["gloss"], allow_ai=True)
ok("ja glossary uses lang ja", all(l == "ja" for l, _i in rm.gloss_calls) and rm.gloss_calls)

print("== task subsets / validation ==")
llm, rm = install()
res = run("en", mk_lines(2), [], allow_ai=True)
ok("no tasks: only ids come back, nothing is called", all(set(o) == {"i"} for o in res["lines"]) and not llm.calls and not rm.analyze_calls)
res = run("en", mk_lines(2), ["bogus", "translate", 5], allow_ai=True)
ok("unknown tasks are ignored", all(set(o) == {"i", "ko"} for o in res["lines"]))
res = run("en", mk_lines(2), "translate", allow_ai=True)
ok("tasks that is not a list is treated as empty", all(set(o) == {"i"} for o in res["lines"]))
res = run("en", [{"i": 0, "text": "hello world"}, {"i": 1, "text": ""}, {"i": 2, "text": "   "}, "junk", {"text": "x y"}], ["translate"], allow_ai=True)
ok("blank / junk lines: no exception, empty ko, no item sent", [o["ko"] for o in res["lines"]][1:3] == ["", ""] and len(res["lines"]) == 5)
ok("blank lines are not translated and do not cause ko_missing", len(llm.calls[-1]["items"]) == 2 and res["warnings"] == [], res["warnings"])
res = run("en", [], ["translate", "reading", "tokens", "gloss"], allow_ai=True)
ok("empty lines list -> empty result", res == {"lines": [], "glossary": {}, "warnings": []})
try:
    run("fr", mk_lines(1), ["reading"])
    ok("lang other than en / ja raises ValueError", False)
except ValueError:
    ok("lang other than en / ja raises ValueError", True)
res = run("en", [{"i": k, "text": "a b"} for k in range(450)], ["reading"])
ok("more than 400 lines are cut at 400", len(res["lines"]) == 400)
res = run("en", [{"i": 0, "text": "x" * 500}], ["translate"], allow_ai=True)
ok("a 500-char line is cut to 200 before it is sent", len(llm.calls[-1]["items"][0]) == 200)

print("== Q3 consent flag: no AI, nothing sent ==")
conn = {"n": 0}
real_cc, real_conn = socket.create_connection, socket.socket.connect


def _blocked_cc(*a, **k):
    conn["n"] += 1
    raise OSError("network blocked by test")


def _blocked_conn(self, *a, **k):
    conn["n"] += 1
    raise OSError("network blocked by test")


socket.create_connection, socket.socket.connect = _blocked_cc, _blocked_conn
try:
    llm, rm = install()
    full = ["reading", "translate", "tokens", "gloss"]
    res = run("en", mk_lines(30), full)                 # allow_ai defaults to False
    ok("default (no allow_ai): LLM called 0 times", len(llm.calls) == 0)
    ok("default (no allow_ai): readmode.gloss called 0 times", len(rm.gloss_calls) == 0)
    ok("default (no allow_ai): ko empty, ko_missing + gloss_missing", all(o["ko"] == "" for o in res["lines"]) and set(res["warnings"]) == {"ko_missing", "gloss_missing"}, res["warnings"])
    ok("default (no allow_ai): local tasks still done", all(len(o["words"]) == 3 for o in res["lines"]) and all(o["reading"] == "" for o in res["lines"]))
    res = run("en", mk_lines(30), full, allow_ai=False)
    ok("allow_ai=False behaves the same", len(llm.calls) == 0 and not rm.gloss_calls)
    res = run("ja", [{"i": 0, "text": "君が笑う"}], full, allow_ai=False)
    ok("ja without allow_ai: reading / pron / words yes, ko empty, no AI call", res["lines"][0]["reading"] and res["lines"][0]["ko"] == "" and not llm.calls and not rm.gloss_calls)
    res = run("en", mk_lines(30), ["reading", "tokens"], allow_ai=False)
    ok("local-only tasks give no AI warning at all", res["warnings"] == [])
    res = run("en", mk_lines(30), full, allow_ai=True)
    ok("with allow_ai=True the AI is used", len(llm.calls) == 3 and len(rm.gloss_calls) >= 1)
    ok("module itself opened 0 network connections in all runs above", conn["n"] == 0, conn["n"])
    # the checker must be able to fail: an LLM fake that really tries to connect is caught
    sentinel = FakeLLM(batch_fn=lambda n, items: socket.create_connection(("127.0.0.1", 9)))
    llm, rm = install(sentinel)
    run("en", mk_lines(2), ["translate"], allow_ai=True)
    ok("negative control: a connection attempt is detected by the blocker", conn["n"] >= 1, conn["n"])
finally:
    socket.create_connection, socket.socket.connect = real_cc, real_conn

print("== cancel / progress ==")
llm, rm = install()
flag = {"stop": False}
llm.on_call = lambda rec: flag.__setitem__("stop", True)
try:
    run("en", mk_lines(40), ["translate"], allow_ai=True, cancel=lambda: flag["stop"])
    ok("cancel between batches raises EnrichCancelled", False)
except se.EnrichCancelled:
    ok("cancel between batches raises EnrichCancelled", True)
ok("cancel stops further LLM calls (1 call made)", len(llm.calls) == 1, len(llm.calls))
llm, rm = install()
try:
    run("en", mk_lines(3), ["tokens"], cancel=lambda: True)
    ok("cancel before local work raises too", False)
except se.EnrichCancelled:
    ok("cancel before local work raises too", True)
llm, rm = install()
seen = []
run("en", mk_lines(40) + [{"i": 900 + k, "text": "hardword%03d extraordinary" % k} for k in range(70)], ["translate", "gloss"], allow_ai=True,
    progress=lambda d, t: seen.append((d, t)))
ok("progress is monotonic and never exceeds total", seen and all(a[0] <= b[0] for a, b in zip(seen, seen[1:])) and all(d <= t for d, t in seen), seen[-3:])
ok("progress ends at total", seen[-1][0] == seen[-1][1], seen[-1])

print("== K4-7 no lyric text in logs ==")


class Capture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.text = []

    def emit(self, record):
        try:
            self.text.append(record.getMessage())
        except Exception as e:
            self.text.append("ERR " + str(e))


def run_with_log_capture(fn):
    cap = Capture()
    root = logging.getLogger()
    old = root.level
    root.addHandler(cap)
    root.setLevel(logging.DEBUG)
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            fn()
    finally:
        root.removeHandler(cap)
        root.setLevel(old)
    return "\n".join(cap.text) + out.getvalue() + err.getvalue(), cap.text


def scenario():
    lyr = [{"i": 0, "text": MARK + " hello world"}, {"i": 1, "text": MARK + " strawberry lighthouse"}, {"i": 2, "text": "BOOM " + MARK}]
    install(FakeLLM(batch_fn=lambda n, items: {"lines": [{"i": 1, "ko": "x"}]}, one_fn=lambda t: (_ for _ in ()).throw(FakeApiError(MARK[:0] + "down"))),
            FakeReadmode(fail_gloss=lambda n: True))
    run("en", lyr, ["reading", "translate", "tokens", "gloss"], allow_ai=True)             # failure paths
    install()
    run("en", lyr, ["reading", "translate", "tokens", "gloss"], allow_ai=True)             # success paths
    run("en", lyr, ["translate", "gloss"])                                                 # consent-off path
    install(ja_reading=lambda t: 1 / 0)
    run("ja", [{"i": 0, "text": MARK + "君"}], ["reading", "tokens"])                      # reader failure path


logs, records = run_with_log_capture(scenario)
ok("log capture works (song_enrich logged something)", any("song_enrich" in r for r in records), len(records))
ok("marker ZZSONGLINEZZ never appears in logs / stdout / stderr", MARK not in logs)
# negative control: the same capture does see a marker when something logs it
logs2, _r = run_with_log_capture(lambda: logging.getLogger("backend").info("oops %s", MARK))
ok("negative control: a logged marker is found by the checker", MARK in logs2)
ok("source has no print() and logs no line text", "print(" not in src and not re.search(r"_log\(\)\.\w+\([^)]*(text|texts\[)", src))

print("== ko_ok fallback == server.ko_ok ==")
srv = open(os.path.join(HERE, "server.py"), encoding="utf-8").read()
tree = ast.parse(srv)
ns = {"re": re}
for node in tree.body:
    if (isinstance(node, ast.Assign) and any(getattr(t, "id", "") in ("HANGUL", "HAN", "FOREIGN_SCRIPT") for t in node.targets)) or \
            (isinstance(node, ast.FunctionDef) and node.name == "ko_ok"):
        exec(compile(ast.Module([node], []), "server_ko_ok", "exec"), ns)
samples = ["", "안녕", "hello", "안녕 世界", "你好", "你好吗 안녕", "나는 君이 좋아", "привет 안녕", "ありがとう", "그래요!什么", "한" * 3 + "漢字" * 2]
same = all(se._ko_ok_fallback(s, lg) == ns["ko_ok"](s, lg) for s in samples for lg in ("en", "ja"))
ok("fallback ko_ok matches server.ko_ok on %d samples x 2 langs" % len(samples), "ko_ok" in ns and same)
install(ko_ok=lambda t, lang: False)
llm = se.H["ollama_json"]
res = run("en", mk_lines(2), ["translate"], allow_ai=True)
ok("an injected ko_ok is the one used", all(o["ko"] == "" for o in res["lines"]) and res["warnings"] == ["ko_missing"])

print("== source constraints ==")
ok("no heavy imports (torch / faster_whisper / numpy / server / reading)", not re.search(r"^\s*(import|from)\s+(torch|faster_whisper|numpy|server|reading|requests|httpx|urllib)\b", src, re.M))
ok("no direct network code in the module", not re.search(r"\b(socket|requests|urllib|http\.client|httpx)\b", src))
ok("only song_enrich.py / test_song_enrich.py are new in backend (reading.py / server.py untouched: see git diff)",
   os.path.exists(os.path.join(HERE, "reading.py")) and os.path.exists(os.path.join(HERE, "server.py")))

if "--real-reading" in sys.argv:
    print("== real readmode.analyze (no LLM) ==")
    import reading
    install(rm=reading)
    res = run("en", [{"i": 0, "text": "I feel your breath upon my neck"}], ["tokens"])
    wd = res["lines"][0]["words"]
    ok("real analyze: tokens with lemma / zipf / level", len(wd) >= 6 and all(x["level"] in ("easy", "mid", "hard") for x in wd), wd[:2])
    ok("real analyze: breath is content", any(x["lemma"] == "breath" and x["content"] for x in wd))
    res = run("ja", [{"i": 0, "text": "君が笑う"}], ["tokens"])
    ok("real analyze ja: words found", len(res["lines"][0]["words"]) >= 2)

n_pass, n_fail = len(PASSED), len(FAILED)
if n_fail:
    print("FAILED:")
    for name in FAILED:
        print("  -", name)
print("== test_song_enrich: %d passed, %d failed ==" % (n_pass, n_fail))
sys.exit(1 if n_fail else 0)
