# -*- coding: utf-8 -*-
"""Tests the practice API (/practice/*, backend/practice.py) and lints content/phoneme_drills.json.

Usage (a RUNNING test server that has the practice router mounted):
  .venv\\Scripts\\python.exe test_practice.py --base http://127.0.0.1:8811
Content check only (no server, needs espeak + the phoneme model's vocab.json):
  .venv\\Scripts\\python.exe test_practice.py --lint [--content <path to a phoneme_drills.json>] [--full]

Options:
  --base URL     required for the live tests (the app server on port 8770 is refused)
  --lint         only lint the content file (schema, espeak check of every word)
  --content P    lint this file instead of content/phoneme_drills.json
  --full         also require the final content set (at least 15 sounds, the 15 sounds of the design)
  --no-extra     skip the in-process checks (they print SKIP)
Exit code 0 only if nothing FAILED and nothing is UNVERIFIED (a check that could not run is not a pass).
"""
import os
import re
import sys
import json
import glob
import time
import subprocess
import sqlite3
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONTENT = os.path.join(HERE, "content", "phoneme_drills.json")
HANGUL = re.compile(r"[가-힣]")
REQUIRED_SOUNDS = ["θ", "ð", "f", "v", "ɹ", "l", "z", "ʃ", "æ", "ɪ", "iː", "ʊ", "uː", "ʌ", "ɛ"]
PHRASE_WORDS = (2, 5)   # a drill phrase has 2..5 words (one isolated word is not recognised reliably)
# sounds that espeak may write differently inside a word: any of these counts as "the word has the sound"
ALT = {"ɹ": ["ɹ", "ɚ", "ɝ"]}

LINT = "--lint" in sys.argv
FULL = "--full" in sys.argv
NO_EXTRA = "--no-extra" in sys.argv


def _opt(name):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return None


def _require_base():
    """the live tests send many requests: they never default to the app's server"""
    base = _opt("--base")
    if base is None:
        if LINT:
            return None
        sys.exit("--base 가 필요해요 / --base is required. Start your own test server and pass --base http://127.0.0.1:8811")
    base = base.rstrip("/")
    if re.search(r":8770(/|$)", base) and "--allow-app-server" not in sys.argv:
        sys.exit("--base points at the app server (port 8770): refused. Use a test server, or add --allow-app-server.")
    return base


BASE = _require_base()
CONTENT = _opt("--content") or DEFAULT_CONTENT
if not os.path.isabs(CONTENT):
    CONTENT = os.path.abspath(CONTENT)   # absolute before anything changes the working directory

sys.path.insert(0, HERE)
results = []   # (name, "PASS" | "FAIL" | "UNVERIFIED" | "SKIP")


def check(name, cond, detail=""):
    results.append((name, "PASS" if cond else "FAIL"))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def unverified(name, why):
    results.append((name, "UNVERIFIED"))
    print("  [미검증] %s -- %s" % (name, why))


def skip(name, why):
    results.append((name, "SKIP"))
    print("  [SKIP] %s -- %s" % (name, why))


# ----------------------------------------------------------------------------------------------
# content lint (pure: data in, list of problems out)
# ----------------------------------------------------------------------------------------------
def _word_ok(w):
    return isinstance(w, str) and re.fullmatch(r"[a-z]+(?:'[a-z]+)?", w) is not None


def _contains_word(text, word):
    return re.search(r"(?<![A-Za-z])" + re.escape(word) + r"(?![A-Za-z])", text, re.I) is not None


def drill_errors(data, ipa=None, vocab=None, full=False):
    """problems of a phoneme_drills.json structure. ipa: {word: espeak IPA} or None (not checked);
    vocab: set of the recognizer's tokens or None (not checked)"""
    errs = []
    if not isinstance(data, dict):
        return ["최상위가 객체가 아니에요"]
    if data.get("version") != 1:
        errs.append("version이 1이 아니에요")
    items = data.get("phonemes")
    if not isinstance(items, list) or not items:
        return errs + ["phonemes가 비어 있거나 목록이 아니에요"]
    seen = set()
    for i, d in enumerate(items):
        tag = "#%d" % i
        if not isinstance(d, dict):
            errs.append("%s: 항목이 객체가 아니에요" % tag)
            continue
        p = d.get("p")
        if not isinstance(p, str) or not p.strip():
            errs.append("%s: p가 비어 있어요" % tag)
            continue
        tag = "p=%s" % p
        if p in seen:
            errs.append("%s: p가 중복이에요" % tag)
        seen.add(p)
        if vocab is not None and p not in vocab:
            errs.append("%s: 인식기 어휘(/score의 espeak 토큰)에 없는 글자예요" % tag)
        if not isinstance(d.get("label"), str) or not d["label"].strip():
            errs.append("%s: label이 비어 있어요" % tag)
        if not isinstance(d.get("hint_ko"), str) or not HANGUL.search(d["hint_ko"]):
            errs.append("%s: hint_ko에 한글 설명이 없어요" % tag)
        words = d.get("words")
        if not isinstance(words, list) or len(words) < 6:
            errs.append("%s: words가 6개 미만이에요" % tag)
            words = words if isinstance(words, list) else []
        bad = [w for w in words if not _word_ok(w)]
        if bad:
            errs.append("%s: words에 영문 소문자 단어가 아닌 것이 있어요 %s" % (tag, bad[:3]))
        if len(set(w for w in words if isinstance(w, str))) != len(words):
            errs.append("%s: words에 중복이 있어요" % tag)
        pairs = d.get("pairs")
        if not isinstance(pairs, list) or len(pairs) < 2:
            errs.append("%s: pairs가 2개 미만이에요" % tag)
            pairs = pairs if isinstance(pairs, list) else []
        for k, pr in enumerate(pairs):
            if not (isinstance(pr, dict) and _word_ok(pr.get("a")) and _word_ok(pr.get("b")) and pr.get("a") != pr.get("b")
                    and isinstance(pr.get("ko"), str) and HANGUL.search(pr["ko"])):
                errs.append("%s: pairs[%d]가 {a, b(서로 다른 영단어), ko(한글)} 모양이 아니에요" % (tag, k))
        phrases = d.get("phrases")
        if not isinstance(phrases, list) or len(phrases) < 4:
            errs.append("%s: phrases가 4개 미만이에요" % tag)
            phrases = phrases if isinstance(phrases, list) else []
        for k, ph in enumerate(phrases):
            if not (isinstance(ph, dict) and isinstance(ph.get("text"), str) and ph["text"].strip()
                    and isinstance(ph.get("ko"), str) and HANGUL.search(ph["ko"])):
                errs.append("%s: phrases[%d]가 {text, ko(한글)} 모양이 아니에요" % (tag, k))
                continue
            n = len(ph["text"].split())
            if not PHRASE_WORDS[0] <= n <= PHRASE_WORDS[1]:
                errs.append("%s: phrases[%d] '%s'는 %d단어예요 (%d~%d단어여야 해요)" % (tag, k, ph["text"], n, *PHRASE_WORDS))
            if not any(_contains_word(ph["text"], w) for w in words if isinstance(w, str)):
                errs.append("%s: phrases[%d] '%s'에 words의 단어가 하나도 없어요" % (tag, k, ph["text"]))
        if ipa is not None:
            alts = ALT.get(p, [p])
            for w in words:
                if _word_ok(w):
                    s = ipa.get(w)
                    if s is None:
                        errs.append("%s: '%s'의 espeak 결과가 없어요" % (tag, w))
                    elif not any(a in s for a in alts):
                        errs.append("%s: '%s'의 espeak 발음 /%s/에 %s 소리가 없어요" % (tag, w, s, p))
            for k, pr in enumerate(pairs):
                if isinstance(pr, dict) and _word_ok(pr.get("a")) and _word_ok(pr.get("b")):
                    sa, sb = ipa.get(pr["a"]), ipa.get(pr["b"])
                    if sa is not None and sb is not None and not any(a in sa or a in sb for a in alts):
                        errs.append("%s: pairs[%d] %s/%s 둘 다 %s 소리가 없어요" % (tag, k, pr["a"], pr["b"], p))
    if full:
        missing = [p for p in REQUIRED_SOUNDS if p not in seen]
        if missing:
            errs.append("--full: 필수 소리가 빠졌어요 %s (총 %d개, 15개 이상이어야 해요)" % (missing, len(seen)))
        if len(seen) < 15:
            errs.append("--full: 소리가 %d개예요 (15개 이상이어야 해요)" % len(seen))
    return errs


ESPEAK_CHILD = r'''
import sys, os, json
words = json.loads(sys.stdin.buffer.read().decode("utf-8"))
import espeakng_loader
d = espeakng_loader.get_data_path()
try:
    d.encode("ascii"); ascii_ok = True
except UnicodeEncodeError:
    ascii_ok = False
import phonemizer.backend.espeak.wrapper as W
if not ascii_ok:   # same workaround as server._patch_espeak_for_nonascii_path (this project lives under a Korean folder)
    os.chdir(os.path.dirname(d))
    _orig = W.EspeakAPI
    W.EspeakAPI = lambda lib, dp: _orig(lib, ".")
W.EspeakWrapper.set_library(espeakng_loader.get_library_path())
from phonemizer.backend import EspeakBackend
from phonemizer.separator import Separator
be = EspeakBackend("en-us", preserve_punctuation=False, with_stress=False, language_switch="remove-flags")
sep = Separator(word=" ", phone="", syllable="")
out = {w: be.phonemize([w], separator=sep, strip=True)[0].replace(" ", "") for w in words}
sys.stdout.buffer.write(json.dumps(out, ensure_ascii=False).encode("utf-8"))
'''


def espeak_ipa(words):
    """{word: IPA} from espeak in a child process (it changes the working directory), or (None, reason)"""
    try:
        r = subprocess.run([sys.executable, "-X", "utf8", "-c", ESPEAK_CHILD], input=json.dumps(sorted(set(words))).encode("utf-8"),
                           capture_output=True, timeout=120)
    except Exception as e:
        return None, "espeak 프로세스를 실행하지 못했어요: %s" % e
    if r.returncode != 0:
        return None, "espeak 실패: " + r.stderr.decode("utf-8", "replace").strip().splitlines()[-1:][0] if r.stderr.strip() else "espeak 실패"
    raw = json.loads(r.stdout.decode("utf-8"))
    return {w: re.sub(r"[ˈˌ͡‿_\-\s]", "", s).replace(":", "ː") for w, s in raw.items()}, None


def recognizer_vocab():
    for p in glob.glob(os.path.join(HERE, "models", "hf", "models--facebook--wav2vec2-lv-60-espeak-cv-ft", "snapshots", "*", "vocab.json")):
        try:
            with open(p, "r", encoding="utf-8") as f:
                return set(json.load(f))
        except Exception:
            pass
    return None


def run_lint(path, full):
    print("\n== lint %s%s" % (path, " (--full)" if full else ""))
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        check("JSON을 읽을 수 있음", False, "%s: %s" % (type(e).__name__, str(e)[:150]))
        return
    check("JSON을 읽을 수 있음", True)
    words = []
    if isinstance(data, dict) and isinstance(data.get("phonemes"), list):
        for d in data["phonemes"]:
            if isinstance(d, dict):
                for key in ("words",):
                    words += [w for w in (d.get(key) or []) if _word_ok(w)]
                for pr in d.get("pairs") or []:
                    if isinstance(pr, dict):
                        words += [pr[k] for k in ("a", "b") if _word_ok(pr.get(k))]
    ipa, why = (espeak_ipa(words) if words else ({}, None))
    vocab = recognizer_vocab()
    errs = drill_errors(data, ipa=ipa, vocab=vocab, full=full)
    n = len(data.get("phonemes", [])) if isinstance(data, dict) and isinstance(data.get("phonemes"), list) else 0
    check("스키마·단어 수·구절·한글 번역 (소리 %d개)" % n, not errs, "; ".join(errs[:8]) + (" ..." if len(errs) > 8 else ""))
    if ipa is None:
        unverified("espeak로 words의 기대 음소 확인", why)
    else:
        check("espeak 기대 음소에 p가 들어 있음 (단어 %d개)" % len(set(words)), not [e for e in errs if "espeak" in e], "")
    if vocab is None:
        unverified("p가 인식기 어휘에 있음", "models/hf/.../vocab.json 을 찾을 수 없어요")


def meta_lint_checks():
    """the checker must really FAIL on wrong content (a checker that only ever passes is not trusted)"""
    print("\n== lint 자체 검사 (일부러 틀린 내용)")
    good = {"version": 1, "phonemes": [{"p": "θ", "label": "th", "hint_ko": "혀끝을 내밀어요.", "words": ["think", "three", "thank", "mouth", "bath", "month"],
                                        "pairs": [{"a": "think", "b": "sink", "ko": "생각 / 가라앉다"}, {"a": "three", "b": "free", "ko": "셋 / 자유"}],
                                        "phrases": [{"text": "I think so.", "ko": "그렇게 생각해요."}, {"text": "Thank you.", "ko": "고마워요."},
                                                    {"text": "Three of them.", "ko": "셋이에요."}, {"text": "My mouth hurts.", "ko": "입이 아파요."}]}]}
    ipa = {"think": "θɪŋk", "three": "θɹiː", "thank": "θæŋk", "mouth": "maʊθ", "bath": "bæθ", "month": "mʌnθ", "sink": "sɪŋk", "free": "fɹiː"}
    check("올바른 내용은 문제 0건", drill_errors(good, ipa=ipa, vocab={"θ"}) == [])

    def mutate(fn):
        d = json.loads(json.dumps(good))
        fn(d["phonemes"][0])
        return d
    cases = [
        ("words 5개", mutate(lambda d: d["words"].pop())),
        ("pairs 1개", mutate(lambda d: d["pairs"].pop())),
        ("phrases 3개", mutate(lambda d: d["phrases"].pop())),
        ("phrase에 words 단어 없음", mutate(lambda d: d["phrases"].__setitem__(0, {"text": "Hello there friend.", "ko": "안녕"}))),
        ("phrase 한 단어", mutate(lambda d: d["phrases"].__setitem__(0, {"text": "Think.", "ko": "생각"}))),
        ("한글 없는 hint_ko", mutate(lambda d: d.__setitem__("hint_ko", "tongue"))),
        ("어휘에 없는 p", mutate(lambda d: d.__setitem__("p", "θθ"))),
    ]
    for name, data in cases:
        check("틀린 내용을 잡음: " + name, drill_errors(data, ipa=ipa, vocab={"θ"}) != [])
    check("틀린 내용을 잡음: 단어에 소리 없음 (espeak)", drill_errors(mutate(lambda d: d["words"].__setitem__(0, "sink")), ipa=ipa, vocab={"θ"}) != [])
    check("틀린 내용을 잡음: version", drill_errors({"version": 2, "phonemes": good["phonemes"]}, ipa=ipa) != [])
    check("틀린 내용을 잡음: 최상위가 목록", drill_errors([1, 2]) != [])
    check("--full: 15개 미만이면 FAIL", drill_errors(good, ipa=ipa, vocab={"θ"}, full=True) != [])


# ----------------------------------------------------------------------------------------------
# live tests
# ----------------------------------------------------------------------------------------------
def call(path, **params):
    import requests
    return requests.get(BASE + path, params=params, timeout=60)


def raw_get(path_and_query):
    import requests
    return requests.get(BASE + path_and_query, timeout=60)


def is_korean_error(r):
    try:
        b = r.json()
    except Exception:
        return False
    return isinstance(b, dict) and set(b) == {"error"} and isinstance(b["error"], str) and bool(HANGUL.search(b["error"]))


def hira_ok(s):
    core = re.sub(r"[\s。、！？!?,.，．…・「」『』（）()\"'“”‘’〜~ー―-]", "", s or "")
    return bool(core) and re.fullmatch(r"[ぁ-ゖゝゞー]+", core) is not None


def live_tests(full):
    import requests
    try:
        import lesson_rules
        EN_LEN = lesson_rules.EN_LEN
    except Exception:
        EN_LEN = {1: (3, 7), 2: (3, 9), 3: (4, 12), 4: (5, 14)}

    print("\n== /practice/ping")
    r = call("/practice/ping")
    ok = r.status_code == 200
    d = r.json() if ok else {}
    check("ping 200 + {ok, practice, missions, tatoeba}", ok and d.get("ok") is True and d.get("practice") == 1 and d.get("missions") == 1
          and isinstance(d.get("tatoeba"), bool) and set(d) == {"ok", "practice", "missions", "tatoeba"}, r.text[:150])
    tatoeba = bool(d.get("tatoeba"))
    if not tatoeba:
        print("  (Tatoeba DB가 없는 서버: 문장 검사는 503 확인으로 대신해요)")

    print("\n== /practice/sentences shadow / dictation")
    if not tatoeba:
        r = call("/practice/sentences", lang="en", mode="shadow")
        check("DB 없음 -> 503 + 한글 error", r.status_code == 503 and is_korean_error(r), r.text[:150])
    else:
        r = call("/practice/sentences", lang="en", mode="shadow", stage=1, n=8)
        d = r.json() if r.status_code == 200 else {}
        ss = d.get("sentences", [])
        lo, hi = EN_LEN[1]
        check("shadow stage1 n=8 -> 200, 8개", r.status_code == 200 and len(ss) == 8, "%s %d개" % (r.status_code, len(ss)))
        check("id 중복 없음", len({s["id"] for s in ss}) == len(ss) == 8)
        check("단어 수가 EN_LEN[1]=%d~%d 안, words 필드와 일치" % (lo, hi), all(lo <= len(s["text"].split()) <= hi and s["words"] == len(s["text"].split()) for s in ss))
        check("ko에 한글, url이 tatoeba 주소, 필드 모양", all(HANGUL.search(s["ko"]) and s["url"] == "https://tatoeba.org/sentences/show/%d" % s["id"]
                                                          and set(s) == {"id", "text", "ko", "reading", "pron", "words", "url"} for s in ss))
        check("attribution 있음", "Tatoeba" in d.get("attribution", ""), d.get("attribution"))
        check("응답 필드(lang, mode, stage)", (d.get("lang"), d.get("mode"), d.get("stage")) == ("en", "shadow", 1))

        r = call("/practice/sentences", lang="en", mode="dictation", stage=2, n=20, seed=3)
        d = r.json() if r.status_code == 200 else {}
        ss = d.get("sentences", [])
        def dict_ok(t):
            ws = t.split()
            if not 3 <= len(ws) <= 10 or re.search(r"\d", t):
                return False
            return all(not (w.strip(".,!?;:\"")[:1].isupper() and w.strip(".,!?;:\"").replace("’", "'").split("'")[0] != "I") for w in ws[1:])
        check("dictation n=20 -> 200, 숫자 없음·3~10단어·이름 대문자 없음", r.status_code == 200 and len(ss) >= 10 and all(dict_ok(s["text"]) for s in ss),
              "%s %d개 %s" % (r.status_code, len(ss), [s["text"] for s in ss if not dict_ok(s["text"])][:3]))
        r = call("/practice/sentences", lang="ja", mode="dictation")
        check("ja dictation -> 400 + 한글 error", r.status_code == 400 and is_korean_error(r), r.text[:120])

        print("\n== exclude / seed / 일본어 reading")
        a = call("/practice/sentences", lang="en", mode="shadow", stage=2, n=8, seed=7).json()["sentences"]
        b = call("/practice/sentences", lang="en", mode="shadow", stage=2, n=8, seed=7).json()["sentences"]
        check("같은 seed -> 같은 id 목록", [s["id"] for s in a] == [s["id"] for s in b] and len(a) == 8)
        c = call("/practice/sentences", lang="en", mode="shadow", stage=2, n=8, seed=7, exclude=",".join(str(s["id"]) for s in a)).json()["sentences"]
        check("exclude 적용 -> 이전 결과와 겹침 0", len(c) == 8 and not ({s["id"] for s in a} & {s["id"] for s in c}))
        e = call("/practice/sentences", lang="en", mode="shadow", stage=2, n=8, seed=8).json()["sentences"]
        check("다른 seed -> 다른 목록", [s["id"] for s in a] != [s["id"] for s in e])
        j = call("/practice/sentences", lang="ja", mode="shadow", stage=2, n=8, seed=5)
        js = j.json().get("sentences", []) if j.status_code == 200 else []
        check("일본어 shadow 8개, reading이 비어 있지 않고 히라가나만", j.status_code == 200 and len(js) == 8 and all(hira_ok(s["reading"]) for s in js),
              "%s %s" % (j.status_code, [s["reading"] for s in js if not hira_ok(s["reading"])][:3]))
        check("일본어 ko에 한글", all(HANGUL.search(s["ko"]) for s in js))
        check("일본어 pron이 가타카나만", all(re.fullmatch(r"[ァ-ヶー、，。！？\s・…「」]+", s.get("pron", "")) for s in js), [s.get("pron") for s in js][:2])

    print("\n== 틀린 입력 (500 없음, 오류는 {\"error\": 한글})")
    bad = [
        ("lang=xx", "/practice/sentences?lang=xx&mode=shadow", (400,)),
        ("lang 비어 있음", "/practice/sentences?lang=&mode=shadow", (400,)),
        ("mode=foo", "/practice/sentences?lang=en&mode=foo", (400,)),
        ("mode 없음", "/practice/sentences?lang=en", (400,)),
        ("mode=SHADOW(대문자)", "/practice/sentences?lang=en&mode=SHADOW", (400,)),
        ("lang=%00", "/practice/sentences?lang=%00&mode=shadow", (400,)),
        ("stage=-3", "/practice/sentences?lang=en&mode=shadow&stage=-3", (200, 503)),
        ("stage=9", "/practice/sentences?lang=en&mode=shadow&stage=9", (200, 503)),
        ("stage=abc", "/practice/sentences?lang=en&mode=shadow&stage=abc", (200, 503)),
        ("n=0", "/practice/sentences?lang=en&mode=shadow&n=0", (200, 503)),
        ("n=999", "/practice/sentences?lang=en&mode=shadow&n=999", (200, 503)),
        ("n=abc", "/practice/sentences?lang=en&mode=shadow&n=abc", (200, 503)),
        ("month=99 week=-1", "/practice/sentences?lang=en&mode=shadow&month=99&week=-1", (200, 503)),
        ("seed=abc", "/practice/sentences?lang=en&mode=shadow&seed=abc", (200, 503)),
        ("seed=99999999999999999999999", "/practice/sentences?lang=en&mode=shadow&seed=99999999999999999999999", (200, 503)),
        ("exclude=a,,1,%00", "/practice/sentences?lang=en&mode=shadow&exclude=a,,1,%00", (200, 503)),
        ("exclude 5000자", "/practice/sentences?lang=en&mode=shadow&exclude=" + ",".join(["12345"] * 800)[:5000], (200, 503)),
        ("exclude 한글·이모지", "/practice/sentences?lang=en&mode=shadow&exclude=%EA%B0%80,%F0%9F%98%80,-5,1e3", (200, 503)),
        ("ja dictation", "/practice/sentences?lang=ja&mode=dictation", (400,)),
        ("없는 하위 경로", "/practice/nothing", (404,)),
    ]
    for name, path, expect in bad:
        r = raw_get(path)
        good = r.status_code in expect and (r.status_code == 200 or is_korean_error(r)) and r.status_code != 500
        check("%s -> %s" % (name, "/".join(map(str, expect))), good, "HTTP %s %s" % (r.status_code, r.text[:80] if not good else ""))
    if tatoeba:
        check("stage=-3 은 1단계로 보정, stage=9 는 4단계로 보정",
              raw_get("/practice/sentences?lang=en&mode=shadow&stage=-3").json().get("stage") == 1
              and raw_get("/practice/sentences?lang=en&mode=shadow&stage=9").json().get("stage") == 4)
        check("n=0 -> 1개, n=999 -> 20개",
              len(raw_get("/practice/sentences?lang=en&mode=shadow&n=0").json()["sentences"]) == 1
              and len(raw_get("/practice/sentences?lang=en&mode=shadow&n=999").json()["sentences"]) == 20)

    print("\n== /practice/phonemes, /practice/phoneme")
    r = call("/practice/phonemes")
    pl = r.json().get("phonemes", []) if r.status_code == 200 else []
    check("phonemes 200, 항목 {p, label, hint_ko}", r.status_code == 200 and pl and all(set(x) == {"p", "label", "hint_ko"} and HANGUL.search(x["hint_ko"]) for x in pl),
          "%s %d개" % (r.status_code, len(pl)))
    ps = [x["p"] for x in pl]
    check("p 중복 없음", len(set(ps)) == len(ps))
    if full:
        check("--full: 15개 이상 + 필수 15개 포함", len(ps) >= 15 and all(p in ps for p in REQUIRED_SOUNDS), "%d개, 빠진 것 %s" % (len(ps), [p for p in REQUIRED_SOUNDS if p not in ps]))
    else:
        print("  (소리 %d개. 15개 확인은 --full)" % len(ps))
    first = ps[0] if ps else "θ"
    r = call("/practice/phoneme", p=first, sentences=3)
    d = r.json() if r.status_code == 200 else {}
    check("phoneme 구조: p, label, hint_ko, words>=6, pairs>=2, phrases>=4",
          r.status_code == 200 and d.get("p") == first and len(d.get("words", [])) >= 6 and len(d.get("pairs", [])) >= 2 and len(d.get("phrases", [])) >= 4
          and all(set(x) == {"a", "b", "ko"} for x in d.get("pairs", [])) and all(set(x) == {"text", "ko"} for x in d.get("phrases", [])), r.text[:150])
    sents = d.get("sentences", [])
    check("sentences <= 3, 각 {id, text, ko(한글), url}, attribution", len(sents) <= 3 and all(set(s) == {"id", "text", "ko", "url"} and HANGUL.search(s["ko"]) for s in sents)
          and "Tatoeba" in d.get("attribution", ""), "%d개" % len(sents))
    if tatoeba:
        check("DB가 있으면 예문이 1개 이상, 3~10단어", len(sents) >= 1 and all(3 <= len(s["text"].split()) <= 10 for s in sents), "%d개" % len(sents))
    check("sentences=0 -> 예문 []", call("/practice/phoneme", p=first, sentences=0).json().get("sentences") == [])
    check("sentences=99 -> 5개 이하", len(call("/practice/phoneme", p=first, sentences=99).json().get("sentences", [])) <= 5)
    check("sentences=abc -> 200", call("/practice/phoneme", p=first, sentences="abc").status_code == 200)
    r = raw_get("/practice/phoneme")
    check("p 없음 -> 400 + 한글", r.status_code == 400 and is_korean_error(r), r.text[:100])
    r = call("/practice/phoneme", p="   ")
    check("p 공백 -> 400", r.status_code == 400 and is_korean_error(r))
    r = call("/practice/phoneme", p="zzz")
    check("p=zzz -> 404 + 한글", r.status_code == 404 and is_korean_error(r), r.text[:100])
    r = raw_get("/practice/phoneme?p=%00")
    check("p=%00 -> 404 또는 400", r.status_code in (400, 404) and is_korean_error(r), "HTTP %s" % r.status_code)
    r = call("/practice/phoneme", p="θ" * 5000)
    check("p 5000자 -> 404", r.status_code == 404 and is_korean_error(r), "HTTP %s" % r.status_code)


# ----------------------------------------------------------------------------------------------
# in-process checks (T2-7 and friends): fake failures inside this process
# ----------------------------------------------------------------------------------------------
class FakeApiError(Exception):
    def __init__(self, msg, status=400, format_error=False):
        super().__init__(msg)
        self.msg, self.status, self.format_error = msg, status, format_error


def extra_tests():
    print("\n== 프로세스 안 검사 (DB 없음/깨짐, 콘텐츠 없음/깨짐, import 시간)")
    import practice
    import reading
    import lesson_rules
    practice.init(ApiError=FakeApiError, readmode=reading, lesson_rules=lesson_rules, log=__import__("logging").getLogger("test_practice"))
    saved = (reading.tatoeba_ready, reading.invalidate_tatoeba_ready, lesson_rules.pool, reading.examples, practice.CONTENT_DIR)
    calls = []
    try:
        reading.tatoeba_ready = lambda: False
        try:
            practice.get_sentences("en", "shadow")
            check("DB 없음 -> ApiError 503", False, "예외가 없어요")
        except FakeApiError as e:
            check("DB 없음 -> ApiError 503 + 한글", e.status == 503 and bool(HANGUL.search(e.msg)), "%s %s" % (e.status, e.msg))
        check("DB 없음: 음소 연습은 sentences [] 로 200", practice.get_phoneme("θ", "3")["sentences"] == [])

        reading.tatoeba_ready = lambda: True
        reading.invalidate_tatoeba_ready = lambda: calls.append("invalidate")

        def boom(lang):
            raise sqlite3.DatabaseError("database disk image is malformed")
        lesson_rules.pool = boom
        try:
            practice.get_sentences("en", "shadow")
            check("sqlite3.Error -> ApiError 503", False, "예외가 없어요")
        except FakeApiError as e:
            check("sqlite3.Error -> ApiError 503 + 한글", e.status == 503 and bool(HANGUL.search(e.msg)), "%s %s" % (e.status, e.msg))
        check("sqlite3.Error -> invalidate_tatoeba_ready 호출됨", calls == ["invalidate"], calls)

        def boom2(lang):
            raise RuntimeError("something else broke")
        lesson_rules.pool = boom2
        try:
            practice.get_sentences("ja", "shadow")
            check("예상 못 한 오류 -> 500이 아니라 ApiError 503", False, "예외가 없어요")
        except FakeApiError as e:
            check("예상 못 한 오류 -> 500이 아니라 ApiError 503", e.status == 503 and bool(HANGUL.search(e.msg)), "%s" % e.status)
        except Exception as e:
            check("예상 못 한 오류 -> 500이 아니라 ApiError 503", False, type(e).__name__)

        def boom3(lang, q, limit=5):
            raise sqlite3.OperationalError("disk I/O error")
        reading.examples = boom3
        calls.clear()
        res = practice.get_phoneme("θ", "3")
        check("음소 예문 중 sqlite3.Error -> sentences [] 로 200 + invalidate 호출", res["sentences"] == [] and calls == ["invalidate"] and len(res["phrases"]) >= 1, calls)
        reading.examples = saved[3]

        # content file missing / broken -> 503 with a Korean message (never a 500)
        with tempfile.TemporaryDirectory() as td:
            practice.CONTENT_DIR = td
            try:
                practice.get_phonemes()
                check("drills 파일 없음 -> ApiError 503", False, "예외가 없어요")
            except FakeApiError as e:
                check("drills 파일 없음 -> ApiError 503 + 한글", e.status == 503 and bool(HANGUL.search(e.msg)))
            with open(os.path.join(td, "phoneme_drills.json"), "w", encoding="utf-8") as f:
                f.write("{ this is not json")
            try:
                practice.get_phonemes()
                check("drills 깨진 JSON -> ApiError 503", False, "예외가 없어요")
            except FakeApiError as e:
                check("drills 깨진 JSON -> ApiError 503 + 한글", e.status == 503 and bool(HANGUL.search(e.msg)))
            with open(os.path.join(td, "phoneme_drills.json"), "w", encoding="utf-8") as f:
                json.dump({"version": 1, "phonemes": [{"p": "x"}, "junk", {"p": 5}, {"p": "ð", "words": "no"}]}, f)
            res = practice.get_phonemes()
            check("drills 일부 항목이 쓰레기여도 나머지로 응답", [x["p"] for x in res["phonemes"]] == ["x", "ð"], res)
    finally:
        reading.tatoeba_ready, reading.invalidate_tatoeba_ready, lesson_rules.pool, reading.examples, practice.CONTENT_DIR = saved

    # the parsers on their own
    check("parse_exclude: 숫자만 취하고 쓰레기는 무시", practice.parse_exclude("a,,1,%00,22, 33 ,-4,1e3,٣") == {1, 22, 33})
    check("parse_exclude: 5000자·500개 상한", len(practice.parse_exclude(",".join(str(i) for i in range(5000)))) <= 500)
    check("dictation_ok: 첫 단어 이름 허용, 중간 이름·숫자·2단어·11단어 거부",
          practice.dictation_ok("Tom is here today.") and not practice.dictation_ok("Is Tom here today?") and not practice.dictation_ok("I have 3 cats.")
          and not practice.dictation_ok("Go now.") and not practice.dictation_ok("one two three four five six seven eight nine ten eleven")
          and practice.dictation_ok("Then I'm going home."))

    # importing the modules must be cheap and must not touch models or the network
    t0 = time.time()
    r = subprocess.run([sys.executable, "-X", "utf8", "-c", "import sys; sys.path.insert(0, %r); import practice, missions" % HERE],
                       capture_output=True, timeout=30)
    dt = time.time() - t0
    check("python -c 'import practice, missions' 3초 안에 끝남, 종료 코드 0", r.returncode == 0 and dt < 3.0, "exit %s, %.2fs %s" % (r.returncode, dt, r.stderr.decode("utf-8", "replace")[-100:]))


def summary():
    n = {k: sum(1 for _n, s in results if s == k) for k in ("PASS", "FAIL", "UNVERIFIED", "SKIP")}
    print("\n== test_practice result: %d passed, %d failed, %d 미검증, %d skipped ==" % (n["PASS"], n["FAIL"], n["UNVERIFIED"], n["SKIP"]))
    for name, s in results:
        if s in ("FAIL", "UNVERIFIED"):
            print("  %s: %s" % (s, name))
    return 0 if n["FAIL"] == 0 and n["UNVERIFIED"] == 0 else 1


def main():
    if LINT:
        run_lint(CONTENT, FULL)
        if not NO_EXTRA:
            meta_lint_checks()
        sys.exit(summary())
    run_lint(CONTENT, FULL)
    if not NO_EXTRA:
        meta_lint_checks()
    try:
        live_tests(FULL)
    except Exception as e:   # an unexpected answer from the server must be a FAIL, not a stack trace
        import traceback
        check("라이브 검사가 끝까지 실행됨", False, "%s: %s (%s)" % (type(e).__name__, str(e)[:120], traceback.format_exc().strip().splitlines()[-3].strip()))
    if NO_EXTRA:
        skip("프로세스 안 검사 (DB 없음/깨짐, 콘텐츠 깨짐, import 시간)", "--no-extra")
        print("SKIP 1")
    else:
        extra_tests()
    sys.exit(summary())


if __name__ == "__main__":
    main()
