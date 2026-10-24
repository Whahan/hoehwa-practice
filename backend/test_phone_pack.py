# -*- coding: utf-8 -*-
"""Tests for the phone data pack (godot/data/pack) and its build tool backend/tools/build_phone_pack.py.

    backend\\.venv\\Scripts\\python.exe -I backend\\test_phone_pack.py [--pack DIR]

Part 1 checks the pack that is in godot/data/pack (A2-2 .. A2-5, A2-8), part 2 unit-tests the tool's functions (including
inputs that must be rejected), part 3 runs the tool as a command line (bad --db, unknown --only, determinism) and compares
backend's original data / cache / content hashes before and after. Last line: `== test_phone_pack: N passed, 0 failed ==`.
Nothing here starts a server or opens a port; the pack folder is only read (the tool is run with temporary --out folders,
and with the real folder only for a call that must fail before writing).
"""
import os
import re
import ast
import sys
import json
import shutil
import hashlib
import tempfile
import subprocess

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "tools")
for _p in (HERE, TOOLS):
    if _p not in sys.path:
        sys.path.insert(0, _p)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

import build_phone_pack as B  # noqa: E402

PACK = B.DEFAULT_OUT
if "--pack" in sys.argv:
    PACK = os.path.abspath(sys.argv[sys.argv.index("--pack") + 1])
TOOL = os.path.join(TOOLS, "build_phone_pack.py")
PY = sys.executable

passed = failed = 0


def _crash(t, v, tb):
    """an unreadable / broken pack file raises somewhere in the middle: count it as a failure and still print the summary line"""
    import traceback
    global failed
    failed += 1
    traceback.print_exception(t, v, tb)
    print("FAIL  the test script stopped with %s: %s" % (t.__name__, str(v)[:200]))
    print("== test_phone_pack: %d passed, %d failed ==" % (passed, failed))


sys.excepthook = _crash


def ok(cond, name, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print("PASS  " + name)
    else:
        failed += 1
        print("FAIL  " + name + ((" -- " + str(detail)[:400]) if detail else ""))


def load(name):
    with open(os.path.join(PACK, name), "r", encoding="utf-8") as f:
        return json.load(f)


def run_tool(args, timeout=600):
    p = subprocess.run([PY, "-I", TOOL] + args, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def tree_hash(paths):
    h = {}
    for p in paths:
        if os.path.isdir(p):
            for root, _d, files in os.walk(p):
                if os.sep + "tts" in root or "llm_cache" in root:
                    continue
                for fn in sorted(files):
                    if fn.startswith("llm_cache"):
                        continue
                    fp = os.path.join(root, fn)
                    h[fp] = B.sha256_file(fp)
        elif os.path.isfile(p):
            h[p] = B.sha256_file(p)
    return h


def good_exercises(lang):
    """one valid exercise of every type (synthetic) for the negative tests"""
    en = lang == "en"
    rd = "" if en else "かな"
    return {
        "choice": {"type": "choice", "question": "q", "options": ["a", "b", "c", "d"], "answer": 2, "explain": "", "tatoeba_id": 1},
        "fill": {"type": "fill", "sentence": "I ___ it.", "reading": rd, "pron": rd, "ko": "k", "options": ["a", "b", "c", "d"], "answer": 0,
                 "explain": "", "tatoeba_id": 1},
        "build": {"type": "build", "ko": "k", "answer": ["I", "like", "it"] if en else ["私は", "それが", "好き"], "extra": ["blue", "dog"] if en else ["犬を", "走る"],
                  "reading": rd, "pron": rd, "explain": "", "tatoeba_id": 1},
        "listen": {"type": "listen", "audio": "x", "reading": rd, "pron": rd, "options": ["a", "b", "c", "d"], "answer": 3, "explain": "", "tatoeba_id": 1},
        "speak": {"type": "speak", "text": "x", "reading": rd, "pron": rd, "ko": "k", "tatoeba_id": 1},
    }


def cells(lang):
    return ["%d-%d" % (m, w) for m in range(1, 13) for w in range(1, 5)]


# =====================================================================================================
print("== 1. the pack in %s" % PACK)
# =====================================================================================================
man_problems = B.check_manifest(PACK)
ok(not man_problems, "A2-4 manifest: every file's size and SHA-256 match, every file is listed", man_problems)
files = sorted(f for f in os.listdir(PACK) if os.path.isfile(os.path.join(PACK, f))) if os.path.isdir(PACK) else []
for need in B.BUILT_FILES + ["manifest.json"]:
    if need not in files:
        ok(False, "pack file exists: " + need)
ok(all(n in files for n in B.BUILT_FILES + ["manifest.json"]), "all %d pack files exist" % (len(B.BUILT_FILES) + 1), files)
sizes = {f: os.path.getsize(os.path.join(PACK, f)) for f in files}
ok(sum(sizes.values()) <= B.MAX_PACK_BYTES, "A2-5 pack total <= 30 MB (%.2f MB)" % (sum(sizes.values()) / 1048576.0))
ok(max(sizes.values() or [0]) <= B.MAX_FILE_BYTES, "A2-5 every single file <= 10 MB (largest %s)" % (max(sizes, key=sizes.get) if sizes else "-"))

ok(all(B.sha256_file(os.path.join(PACK, n)) == B.sha256_file(os.path.join(B.DEFAULT_CONTENT, n)) and
       open(os.path.join(PACK, n), "rb").read() == open(os.path.join(B.DEFAULT_CONTENT, n), "rb").read() for n in B.CONTENT_FILES),
   "missions.json / phoneme_drills.json are byte-identical to backend/content")

raw_bad = []
for n in files:
    if not n.endswith(".json"):
        continue
    raw = open(os.path.join(PACK, n), "rb").read()
    if b"\r" in raw or not raw.endswith(b"\n"):
        raw_bad.append(n)
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        raw_bad.append(n + "(utf-8)")
    if re.search(rb"\\u[0-9a-fA-F]{4}", raw) and n not in B.CONTENT_FILES and not n.startswith("gloss_"):
        raw_bad.append(n + "(\\u escapes)")
ok(not raw_bad, "JSON files are UTF-8 (no \\u escapes), LF only, end with a newline", raw_bad)

hits = []
for n in files:
    low = open(os.path.join(PACK, n), "rb").read().lower()
    for pat in B.PRIVACY_PATTERNS:
        if pat.encode("utf-8") in low:
            hits.append((n, pat))
ok(not hits, "A2-8 no 'Users\\', 'AppData' or the user name in any pack file", hits)

banks = {}
for lang in ("en", "ja"):
    try:
        banks[lang] = load("lesson_bank_%s.json" % lang)
    except Exception as e:
        banks[lang] = {}
        ok(False, "lesson bank %s loads" % lang, e)
for lang in ("en", "ja"):
    data = banks[lang]
    ls = data.get("lessons", {})
    ok(sorted(ls) == sorted(cells(lang)) and all(len(v) >= 10 for v in ls.values()),
       "A2-2 lesson_bank_%s: 48 cells, every cell >= 10 lessons (min %s, total %s)" % (lang, min([len(v) for v in ls.values()] or [0]), sum(len(v) for v in ls.values())))
    probs = B.check_bank(data, lang)
    ok(not probs, "A2-2/A2-3 lesson_bank_%s: 4-10 exercises per lesson, API.md keys, answer inside options, build extra not in answer, no duplicates" % lang, probs[:5])
    flat = [e for v in ls.values() for les in v for e in les.get("exercises", ())]
    types = {e.get("type") for e in flat}
    ok(types == set(B.REQUIRED_KEYS), "lesson_bank_%s uses all five exercise types" % lang, types)
    ok(data.get("attribution") and all(les.get("attribution") == data.get("attribution") and les.get("source") == "tatoeba"
                                      for v in ls.values() for les in v), "lesson_bank_%s: attribution / source on every lesson" % lang)

# answers re-derived for every choice / fill / listen of both banks (explicit loop, not only check_bank)
bad_ans = 0
n_ans = 0
for lang in ("en", "ja"):
    for v in banks[lang].get("lessons", {}).values():
        for les in v:
            for e in les.get("exercises", ()):
                if e.get("type") in ("choice", "fill", "listen"):
                    n_ans += 1
                    if not (isinstance(e["answer"], int) and 0 <= e["answer"] < len(e["options"])):
                        bad_ans += 1
                if e.get("type") == "build":
                    n_ans += 1
                    joined = ("".join(e["answer"]) if lang == "ja" else " ".join(e["answer"]))
                    if any((x in joined) if lang == "ja" else B._word_in(joined, x) for x in e["extra"]):
                        bad_ans += 1
ok(n_ans > 5000 and bad_ans == 0, "A2-3 %d answers checked in both banks, %d wrong" % (n_ans, bad_ans))

for lang in ("en", "ja"):
    pr = load("practice_%s.json" % lang)
    ss = pr.get("sentences", [])
    keys_ok = all(set(("id", "text", "ko", "reading", "words", "stage", "lemmas")) <= set(s) for s in ss)
    ids = [s["id"] for s in ss]
    ok(len(ss) > 1000 and keys_ok and len(set(ids)) == len(ids), "practice_%s: %d sentences, schema keys, unique ids" % (lang, len(ss)))
    ok(all(isinstance(s["lemmas"], list) and s["words"] >= 3 and 0 <= s["stage"] <= 4 and B.HANGUL.search(s["ko"]) for s in ss),
       "practice_%s: ko has Hangul, words >= 3, stage 0..4, lemmas a list" % lang)
ja_pr = load("practice_ja.json")["sentences"]
import practice  # noqa: E402
ok(all(practice._ja_reading_ok(s["reading"]) and re.fullmatch(r"[ァ-ヶー、。！？，．…・「」『』（）()\[\]\"'_＿!?.,:;~〜\-]+", s["pron"]) for s in ja_pr),
   "practice_ja: every reading passes practice._ja_reading_ok, every pron is katakana (punctuation aside)")
en_pr = load("practice_en.json")["sentences"]
ok(all(s["reading"] == "" for s in en_pr) and any(s.get("dict") for s in en_pr), "practice_en: no readings, dictation flag set on some sentences")

for lang in ("en", "ja"):
    ex = load("examples_%s.json" % lang)
    sent, idx = ex["sent"], ex["idx"]
    ok(len(sent) > 1000 and len(idx) > 1000, "examples_%s: %d sentences, %d index keys" % (lang, len(sent), len(idx)))
    ok(all(str(i) in sent for ids in idx.values() for i in ids) and all(1 <= len(ids) <= B.EXAMPLES_PER_KEY for ids in idx.values()),
       "examples_%s: index ids all resolve, 1..%d per key" % (lang, B.EXAMPLES_PER_KEY))
    ok(all(set(v) == {"t", "ko"} and B.HANGUL.search(v["ko"]) for v in sent.values()), "examples_%s: only sentences with a Korean translation {t, ko}" % lang)

rd = load("reading_en.json")
ok(set(rd) == {"forms", "zipf"} and len(rd["zipf"]) >= 100000 and len(rd["forms"]) >= 10000, "reading_en: forms %d, zipf %d" % (len(rd["forms"]), len(rd["zipf"])))
ok(all(isinstance(v, int) and 0 < v <= 90 for v in rd["zipf"].values()), "reading_en: zipf values are integers (zipf x 10)")
sp = {w: rd["forms"].get(w) for w in ("ran", "running", "children", "went", "cars", "was", "is", "his", "us")}
ok(sp == {"ran": "run", "running": "run", "children": "child", "went": "go", "cars": "car", "was": "be", "is": "be", "his": None, "us": "we"},
   "reading_en: spot checks of the form table", sp)

ipa = load("ipa_en.json")
ok(len(ipa) >= 20000 and all(isinstance(v, str) and v for v in ipa.values()) and all(k == k.lower() for k in ipa), "ipa_en: %d lower-case words with non-empty IPA" % len(ipa))
ok(ipa.get("think", "").startswith("θ") and "ð" in ipa.get("the", "") and ipa.get("water"), "ipa_en: spot checks (think, the, water)", (ipa.get("think"), ipa.get("the")))
en_words = B.pack_en_words(B.Ctx(type("A", (), {"out": PACK})(), PACK, {}))
ok(all(w in ipa for w in en_words if B.EN_WORD.fullmatch(w)), "ipa_en covers every word of the lesson bank, practice and example sentences", [w for w in en_words if w not in ipa][:10])

jm = load("ja_reading_map.json")
ok(len(jm) >= 10000 and all(B.HIRA_FULL.fullmatch(v) for v in jm.values()), "ja_reading_map: %d entries, readings are hiragana" % len(jm))
ok(not any(re.fullmatch(r"[ぁ-ゖァ-ヺー]+", k) for k in jm) and jm.get("学生") == "がくせい" and jm.get("日本") == "にほん", "ja_reading_map: no kana-only keys, spot checks")

mf = load("manifest.json")
ok([e["path"] for e in mf["files"]] == sorted(e["path"] for e in mf["files"]) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d", mf.get("built", "")),
   "manifest: files sorted by path, built is an ISO time with offset", mf.get("built"))
ids = {s["id"] for s in mf["sources"]}
ok({"tatoeba", "wordfreq", "espeak-ng-output", "pyopenjtalk-output", "hoehwa-content"} <= ids, "manifest sources list Tatoeba, wordfreq, espeak-ng, pyopenjtalk, hoehwa-content", ids)
wf = next((s for s in mf["sources"] if s["id"] == "wordfreq"), {})
ok("CC BY-SA 4.0" in wf.get("license", "") and "Apache-2.0" in wf.get("license", ""), "manifest: wordfreq license read from package metadata", wf.get("license"))

# =====================================================================================================
print("== 2. tool functions, including inputs that must be rejected")
# =====================================================================================================
a = B.dumps({"b": "한글", "a": [1, 2]})
ok(a == '{"b":"한글","a":[1,2]}\n' and "\r" not in a and "\\u" not in a, "dumps: compact, keeps key order, Hangul unescaped, LF + final newline")
ok(B.dumps({"x": 1}, indent=1) == '{\n "x": 1\n}\n', "dumps: indent=1 form (manifest style)")
ok(B.count_records("ipa_en.json", {"lessons": "lɛsənz", "sent": "sɛnt"}) == 2 and B.count_records("lesson_bank_en.json", {"lessons": {"1-1": [1, 2], "1-2": [3]}}) == 3
   and B.count_records("practice_en.json", {"sentences": [1, 2, 3]}) == 3 and B.count_records("examples_en.json", {"sent": {"1": 1}}) == 1,
   "count_records: chosen by file name (a word table with the words 'lessons' / 'sent' is counted as a table)")

for lang in ("en", "ja"):
    g = good_exercises(lang)
    ok(all(B.check_exercise(e, lang) == [] for e in g.values()), "check_exercise accepts a valid exercise of every type (%s)" % lang)

g = good_exercises("en")
bad_cases = []
e = dict(g["choice"]); e["answer"] = 4; bad_cases.append(("answer 4 outside 4 options", e))
e = dict(g["choice"]); e["answer"] = -1; bad_cases.append(("answer -1", e))
e = dict(g["listen"]); e["options"] = ["a", "b", "c"]; bad_cases.append(("3 options", e))
e = dict(g["fill"]); e["options"] = ["a", "a", "c", "d"]; bad_cases.append(("duplicate options", e))
e = dict(g["fill"]); e["sentence"] = "no blank"; bad_cases.append(("fill without ___", e))
e = dict(g["choice"]); del e["explain"]; bad_cases.append(("missing key explain", e))
e = dict(g["speak"]); del e["tatoeba_id"]; bad_cases.append(("missing tatoeba_id", e))
e = dict(g["build"]); e["extra"] = ["like", "dog"]; bad_cases.append(("build extra is an answer token", e))
e = dict(g["build"]); e["answer"] = ["I", "like", "blue"]; bad_cases.append(("build answer contains extra 'blue'", e))
e = dict(g["build"]); e["extra"] = ["blue"]; bad_cases.append(("build with 1 extra", e))
e = dict(g["build"]); e["reading"] = "x"; bad_cases.append(("English exercise with a reading", e))
bad_cases.append(("unknown type", {"type": "dance", "tatoeba_id": 1}))
bad_cases.append(("not an object", "x"))
miss = [n for n, e in bad_cases if not B.check_exercise(e, "en")]
ok(not miss, "check_exercise rejects %d deliberately wrong exercises" % len(bad_cases), miss)
gj = good_exercises("ja")
e = dict(gj["build"]); e["answer"] = ["私は", "それが", "好きです"]; e["extra"] = ["好き", "走る"]
ok(B.check_exercise(e, "ja") != [], "check_exercise rejects a ja build whose extra chunk is inside the joined answer sentence")
e = dict(gj["fill"]); e["reading"] = ""
ok(B.check_exercise(e, "ja") != [], "check_exercise rejects a ja exercise without a reading")

mk_les = lambda n, bid="en-1-1-01": {"bank_id": bid, "title": "t", "source": "tatoeba", "attribution": "a",
                                      "exercises": [dict(good_exercises("en")["choice"]) for _ in range(n)]}
ok(B.check_lesson(mk_les(4), "en", (1, 1)) == [] and B.check_lesson(mk_les(10), "en", (1, 1)) == [], "check_lesson accepts 4 and 10 exercises")
ok(B.check_lesson(mk_les(3), "en", (1, 1)) != [] and B.check_lesson(mk_les(11), "en", (1, 1)) != [], "check_lesson rejects 3 and 11 exercises")
ok(B.check_lesson(mk_les(5, "en-2-1-01"), "en", (1, 1)) != [] and B.check_lesson(mk_les(5, "ja-1-1-01"), "en", (1, 1)) != [],
   "check_lesson rejects a bank_id of another cell / language")

good_bank = {"v": 1, "lang": "en", "attribution": "a",
             "lessons": {k: [dict(mk_les(5, "en-%s-%02d" % (k, i + 1)), title="t%d" % i, exercises=[dict(good_exercises("en")["choice"], question="q%d-%d" % (i, j)) for j in range(5)])
                             for i in range(10)] for k in cells("en")}}
ok(B.check_bank(good_bank, "en") == [], "check_bank accepts a synthetic 48-cell bank with 10 lessons per cell")
b1 = json.loads(json.dumps(good_bank)); del b1["lessons"]["5-3"]
b2 = json.loads(json.dumps(good_bank)); b2["lessons"]["2-2"] = b2["lessons"]["2-2"][:9]
b3 = json.loads(json.dumps(good_bank)); b3["lessons"]["3-1"][1]["exercises"] = b3["lessons"]["3-1"][0]["exercises"]
b4 = json.loads(json.dumps(good_bank)); b4["lessons"]["4-1"][0]["exercises"][0]["answer"] = 9
ok(all(B.check_bank(b, "en") for b in (b1, b2, b3, b4)), "check_bank rejects a missing cell, a cell with 9 lessons, a duplicated problem set and an out-of-range answer")
ok(B.check_bank(good_bank, "ja") != [], "check_bank rejects a bank of the wrong language")
ok(B.lesson_key(mk_les(5)) == B.lesson_key(dict(mk_les(5), title="other")) and B.lesson_key(mk_les(5)) != B.lesson_key(mk_les(6)),
   "lesson_key depends on the exercises only")
ok(B.overlap_limit(0, 20) < B.overlap_limit(61, 20) < B.overlap_limit(101, 20) and B.overlap_limit(0, 20) <= 5, "overlap_limit relaxes step by step")

# build_forms
zt = {"run": 5.6, "runs": 4.5, "ran": 5.0, "is": 7.0, "i": 6.9, "be": 6.8, "year": 5.9, "years": 5.9, "bed": 5.0, "bee": 4.0, "his": 6.5, "hi": 5.0}
forms = B.build_forms(["ran", "is", "years", "bed", "his", "runs", "run", "zzz"], lambda w: zt.get(w, 0.0), lambda w: w in ("years", "bed"),
                      lambda f: {"ran": ["run"], "is": ["be", "i"], "years": ["year"], "bed": ["bee"], "his": ["hi"], "runs": ["run"]}.get(f, []),
                      {"runs": ["run"]}, observed={"bed": {"bed": 5, "bee": 1}}, stop={"his"})
ok(forms == {"ran": "run", "is": "be", "years": "year", "runs": "run"}, "build_forms: override, rules, pool votes (bed stays), stop words (his stays)", forms)
ok(B.build_forms(["x"], lambda w: 0.0, lambda w: False, lambda f: ["yy"], {}) == {}, "build_forms: a candidate unknown to wordfreq and the lemma index is dropped")
obs = B.observed_forms([{"toks": [["Saw", 0, "see", "VBD", "VERB", 5, 0], ["saw", 4, "saw", "NN", "NOUN", 4, 0], ["'s", 8, "be", "VBZ", "AUX", 5, 1]]}])
ok(obs == {"saw": {"see": 1, "saw": 1}}, "observed_forms: lower-cased forms only, clitics skipped", obs)

ok(B.practice_stage({"n": 5, "dmin": 4.5}, {1: (3, 7), 2: (3, 9), 3: (4, 12), 4: (5, 14)}, {1: 4.0, 2: 3.5, 3: 3.0, 4: 0.0}) == 1
   and B.practice_stage({"n": 13, "dmin": 1.0}, {1: (3, 7), 2: (3, 9), 3: (4, 12), 4: (5, 14)}, {1: 4.0, 2: 3.5, 3: 3.0, 4: 0.0}) == 4
   and B.practice_stage({"n": 2, "dmin": 7.0}, {1: (3, 7), 2: (3, 9), 3: (4, 12), 4: (5, 14)}, {1: 4.0, 2: 3.5, 3: 3.0, 4: 0.0}) == 0, "practice_stage")

import phone_pack_ja as J  # noqa: E402
ok(B.parse_only("lessons,ipa_en") == ["lesson_bank_en.json", "lesson_bank_ja.json", "ipa_en.json"] and B.parse_only("") == [], "parse_only: aliases and names")
try:
    B.parse_only("nope")
    ok(False, "parse_only rejects an unknown name")
except B.InputError as e:
    ok("nope" in str(e), "parse_only rejects an unknown name with a Korean message", e)
ok(J.kana_only("ひらがな") and J.kana_only("カタカナー") and not J.kana_only("学生") and B.keep_surface("学生", J, re.compile(r"[぀-ヿ㐀-䶿一-鿿々]")) is True,
   "kana_only / keep_surface: kana-only forms are left out of the reading map")
ok(len({s["id"] for s in B.sources_list()}) == 6, "sources_list: six distinct sources")

# manifest tamper tests on a temporary copy of the real pack's small files
tmp = tempfile.mkdtemp(prefix="pp_test_")
try:
    small = [n for n in ("missions.json", "phoneme_drills.json", "examples_ja.json") if os.path.isfile(os.path.join(PACK, n))]
    for n in small:
        shutil.copyfile(os.path.join(PACK, n), os.path.join(tmp, n))
    B.write_json(os.path.join(tmp, "manifest.json"), B.make_manifest({n: os.path.join(tmp, n) for n in small}, "2026-01-01T00:00:00+09:00"), indent=1)
    ok(B.check_manifest(tmp) == [], "check_manifest passes on a freshly made manifest")
    mp = os.path.join(tmp, "manifest.json")
    man = json.load(open(mp, encoding="utf-8"))
    h = man["files"][0]["sha256"]
    man["files"][0]["sha256"] = ("0" if h[0] != "0" else "1") + h[1:]
    B.write_json(mp, man, indent=1)
    pr = B.check_manifest(tmp)
    ok(len(pr) == 1 and "SHA-256" in pr[0], "check_manifest reports a manifest whose hash has one character changed", pr)
    man["files"][0]["sha256"] = h
    man["files"][0]["bytes"] += 1
    B.write_json(mp, man, indent=1)
    ok(any("크기" in p for p in B.check_manifest(tmp)), "check_manifest reports a wrong size")
    man["files"][0]["bytes"] -= 1
    B.write_json(mp, man, indent=1)
    with open(os.path.join(tmp, small[0]), "ab") as f:
        f.write(b" ")
    ok(B.check_manifest(tmp) != [], "check_manifest reports a pack file that was changed after the manifest was made")
    shutil.copyfile(os.path.join(PACK, small[0]), os.path.join(tmp, small[0]))
    open(os.path.join(tmp, "stray.json"), "w").write("{}")
    ok(any("manifest 에 없는" in p for p in B.check_manifest(tmp)), "check_manifest reports a file the manifest does not list")
    os.remove(os.path.join(tmp, "stray.json"))
    os.remove(os.path.join(tmp, small[1]))
    ok(any("파일이 없음" in p for p in B.check_manifest(tmp)), "check_manifest reports a listed file that is missing")
    open(mp, "w").write("{broken")
    ok(B.check_manifest(tmp) != [], "check_manifest reports a broken manifest.json")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# =====================================================================================================
print("== 3. command line, determinism, original data untouched")
# =====================================================================================================
guard = [B.DEFAULT_DB, B.DEFAULT_CONTENT] + [os.path.join(B.DEFAULT_CACHE, f) for f in B.POOL_FILES + ["lesson_tri_en.bin", "gloss.json"]]
before_guard = tree_hash(guard)
before_pack = tree_hash([PACK])

rc, so, se = run_tool(["--db", os.path.join(tempfile.gettempdir(), "no_such_dir_xyz", "tatoeba.sqlite"), "--out", PACK])
ok(rc != 0 and "오류" in se and re.search(r"[가-힣]", se) and "예문 DB" in se, "A2-6 --db <missing path>: Korean message, exit code != 0 (rc=%d)" % rc, se[-300:])
ok(tree_hash([PACK]) == before_pack, "A2-6 the existing pack files are unchanged after the failed call")
emp = tempfile.mkdtemp(prefix="pp_empty_")
try:
    rc, so, se = run_tool(["--db", os.path.join(emp, "x.sqlite"), "--out", os.path.join(emp, "pack")])
    ok(rc != 0 and not os.path.exists(os.path.join(emp, "pack")), "a failed call does not create an empty pack folder")
    broken = os.path.join(emp, "broken.sqlite")
    open(broken, "wb").write(b"this is not sqlite" * 100)
    rc, so, se = run_tool(["--db", broken, "--out", os.path.join(emp, "pack2"), "--only", "examples_ja"])
    ok(rc != 0 and "오류" in se and not os.path.exists(os.path.join(emp, "pack2")), "a file that is not a SQLite DB is refused with a Korean message (rc=%d)" % rc, se[-200:])
    rc, so, se = run_tool(["--cache", os.path.join(emp, "nocache"), "--out", os.path.join(emp, "pack3"), "--only", "lessons"])
    ok(rc != 0 and "레슨 풀" in se and not os.path.exists(os.path.join(emp, "pack3")), "missing lesson pools: Korean message, exit code != 0, nothing written (rc=%d)" % rc, se[-200:])
    rc, so, se = run_tool(["--only", "nonsense", "--out", os.path.join(emp, "pack4")])
    ok(rc == 2 and "알 수 없는" in se and not os.path.exists(os.path.join(emp, "pack4")), "--only with an unknown name: exit code 2")
    rc, so, se = run_tool(["--per-cell", "0", "--out", os.path.join(emp, "pack5"), "--only", "content"])
    ok(rc == 2 and not os.path.exists(os.path.join(emp, "pack5")), "--per-cell 0 is refused")
    # determinism: same inputs -> identical bytes (the manifest too when --built is fixed)
    outs = []
    for k in (1, 2):
        o = os.path.join(emp, "det%d" % k)
        rc, so, se = run_tool(["--out", o, "--only", "examples_ja,content", "--built", "2026-01-01T00:00:00+09:00"])
        ok(rc == 0, "A2-9 run %d of --only examples_ja,content ends with exit code 0" % k, se[-300:])
        outs.append(o)
    names = sorted(os.listdir(outs[0])) if os.path.isdir(outs[0]) else []
    same = names and names == sorted(os.listdir(outs[1])) and all(open(os.path.join(outs[0], n), "rb").read() == open(os.path.join(outs[1], n), "rb").read() for n in names)
    ok(bool(same) and "manifest.json" in names, "A2-9 two runs give byte-identical files (%s)" % ", ".join(names))
    ok(B.check_manifest(outs[0]) == [], "the manifest written by the tool verifies")
    # a partial run keeps files that other tools put into the folder (gloss_*.json) and lists them
    open(os.path.join(outs[0], "gloss_en.json"), "w", encoding="utf-8", newline="\n").write('{"a":{"pos":"x","ko":"가","ipa":""}}\n')
    rc, so, se = run_tool(["--out", outs[0], "--only", "content", "--built", "2026-01-01T00:00:00+09:00"])
    man = json.load(open(os.path.join(outs[0], "manifest.json"), encoding="utf-8"))
    ok(rc == 0 and "gloss_en.json" in [e["path"] for e in man["files"]] and os.path.isfile(os.path.join(outs[0], "gloss_en.json")) and B.check_manifest(outs[0]) == [],
       "a partial run keeps gloss_en.json and lists it in the manifest")
finally:
    shutil.rmtree(emp, ignore_errors=True)

# ---- runtime pieces: needs spaCy / pyopenjtalk / espeak, runs on a copy of the cache
work = tempfile.mkdtemp(prefix="pp_rt_")
try:
    cache = B.prepare_cache(type("A", (), {"cache": B.DEFAULT_CACHE})(), work)
    B.setup_runtime({"db": B.DEFAULT_DB, "cache": cache})
    import lesson_rules  # noqa: E402
    import reading  # noqa: E402
    ok(reading.DB_PATH == B.DEFAULT_DB and lesson_rules.CACHE_DIR == cache, "setup_runtime points reading / lesson_rules at the DB and the copied cache")

    r1 = B.make_cell(("en", 3, 2, 3))
    r2 = B.make_cell(("en", 3, 2, 3))
    ok(r1 == r2 and len(r1[3]) == 3, "make_cell is deterministic (same cell twice gives the same lessons)")
    ok(all(B.check_lesson(l, "en", (3, 2)) == [] for l in r1[3]) and [l["bank_id"] for l in r1[3]] == ["en-3-2-01", "en-3-2-02", "en-3-2-03"], "make_cell lessons pass check_lesson, bank_ids count up")
    r3 = B.make_cell(("ja", 12, 4, 3))
    ok(len(r3[3]) == 3 and all(B.check_lesson(l, "ja", (12, 4)) == [] for l in r3[3]), "make_cell works for Japanese too")
    # the pack lesson #1 of a cell is lesson_rules.make_lesson(seed 0): the bank can be regenerated
    for lang, m, w in (("en", 3, 2), ("ja", 8, 1)):
        ref = lesson_rules.make_lesson(lang, m, w, B.stage_of(m), 0)
        first = banks[lang]["lessons"]["%d-%d" % (m, w)][0]
        ok({k: v for k, v in first.items() if k != "bank_id"} == ref, "bank lesson %s-%d-%d-01 equals make_lesson(seed 0) of the same cell" % (lang, m, w))
    ok(B.stage_of(1) == 1 and B.stage_of(3) == 1 and B.stage_of(4) == 2 and B.stage_of(12) == 4, "stage_of is ceil(month / 3) like server.py stage_of")

    # ja_reading / ja_pron vs the functions of server.py (extracted from its source, server.py itself is not imported)
    src = open(os.path.join(HERE, "server.py"), encoding="utf-8").read()
    tree = ast.parse(src)
    want = {"SIMP_TO_JA", "HAN_ANY", "VARIANT_TO_STD", "SIMP_EXTRA", "_encodes", "is_chinese_only", "KATA_PRON_RE", "ja_text_foreign", "ja_fix_foreign",
            "_ja_pair", "ja_reading", "ja_pron"}
    chosen = []
    for node in tree.body:
        nm = node.name if isinstance(node, (ast.FunctionDef, ast.ClassDef)) else (node.targets[0].id if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) else None)
        if nm in want:
            chosen.append(node)
    import functools, logging, unicodedata  # noqa: E401
    ns = {"re": re, "functools": functools, "unicodedata": unicodedata, "log": logging.getLogger("x"), "ojt": J.ojt}
    exec(compile(ast.Module(body=chosen, type_ignores=[]), "server_ja_extract", "exec"), ns)
    samples = [it["text"] for it in lesson_rules.pool("ja").items[:150]]
    samples += ["私は学生です。", "买东西吗", "髙橋さんは﨑玉に行きました", "これは___です", "Hello, 世界!", "", "  ", "言うのは易しい。", "今日はいい天気ですね？"]
    diff = [s for s in samples if (ns["ja_reading"](s), ns["ja_pron"](s)) != (J.ja_reading(s), J.ja_pron(s))]
    ok(len(chosen) >= 12 and not diff, "phone_pack_ja.ja_reading / ja_pron equal server.py's on %d sentences" % len(samples), diff[:3])
    ok(J.ja_reading("私は学生です。") == "わたしはがくせいです。" and J.ja_pron("私は学生です。") == "ワタシワガクセーデス。", "ja_reading / ja_pron: spelling form は stays は, pronunciation form ワ")

    import phone_pack_espeak as E
    ws = ["think", "the", "water", "running", "o'clock", "tomorrow", "colour", "a", "I", "beautiful"] + ["word%d" % i for i in range(12)]
    batch, single = E.ipa_batch(ws, work, chunk=7)
    solo = {w: E.ipa_one(w, work) for w in ws}
    ok(batch == solo and single == 0 and batch["think"].startswith("θ"), "espeak batch (chunks of 7) gives the same IPA as one word at a time, no fallbacks")
finally:
    shutil.rmtree(work, ignore_errors=True)

after_guard = tree_hash(guard)
ok(before_guard == after_guard and len(before_guard) >= 7, "A2-7 tatoeba.sqlite, cache pools / bit set / gloss, content: SHA-256 unchanged by all of the above (%d files)" % len(before_guard))
ok(tree_hash([PACK]) == before_pack, "the pack folder was not changed by the tests")

print("== test_phone_pack: %d passed, %d failed ==" % (passed, failed))
sys.exit(0 if failed == 0 else 1)
