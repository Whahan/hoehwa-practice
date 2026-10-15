# -*- coding: utf-8 -*-
"""Tests reading mode (/reading/analyze, /reading/gloss) and Tatoeba examples (/examples) against a RUNNING server.
Usage:  .venv\\Scripts\\python.exe test_reading.py [--base http://127.0.0.1:8770]
"""
import sys
import time
import requests

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BASE = "http://127.0.0.1:8770"
if "--base" in sys.argv:
    BASE = sys.argv[sys.argv.index("--base") + 1]

results, timings = [], []

EN_TEXT = """City officials unveiled an ambitious plan on Tuesday to replace thousands of aging streetlights with energy-efficient LED fixtures, a move they say will cut the city's electricity bill by nearly a third.

The project, which is expected to cost $48 million over five years, will begin in neighborhoods where outages have been most frequent. "Residents have been asking for better lighting for a long time," said Maria Lopez, the deputy mayor for infrastructure. "This isn't just about saving money. It's about making streets safer at night."

Smart sensors, now ubiquitous in large cities around the world, will be installed alongside the new lights. They can dim automatically when streets are empty and brighten when pedestrians or cars approach. Engineers believe the sensors could also detect broken water pipes and measure air quality, although those features will not be activated right away.

Critics argued that the timeline was too optimistic. Some council members pointed out that a similar program in a neighboring town ran two years behind schedule after supply problems delayed the delivery of equipment. Others questioned whether the data collected by the sensors would be stored securely and who would have access to it.

The administration responded that all information would be anonymized and that an independent auditor would review the system every year. Officials also promised to publish monthly progress reports online so that residents can track how the money is being spent.

Local business owners largely welcomed the announcement. "When the street is dark, people simply don't come out," said a café owner who has run her shop on Elm Street for twelve years. "Brighter streets mean more customers, especially in winter."

Construction is scheduled to start in early spring, weather permitting."""

JA_TEXT = """昨日、私は友達と新しいレストランに行きました。駅の近くにある小さな店ですが、とても人気があります。
私たちは寿司と天ぷらを食べました。「おいしかったね！」と友達は言いました。
来週は家族と一緒にもう一度行きたいと思っています。"""


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def call(method, path, label, **kw):
    t0 = time.time()
    r = requests.request(method, BASE + path, timeout=400, **kw)
    dt = time.time() - t0
    timings.append((label, dt))
    print("  (%s %s -> HTTP %d in %.2fs)" % (method, path, r.status_code, dt))
    return r


def token_of(tokens, surface):
    return next((t for t in tokens if t["t"] == surface and t.get("w")), None)


def test_analyze_en():
    print("\n== /reading/analyze en (%d words)" % len(EN_TEXT.split()))
    r = call("POST", "/reading/analyze", "analyze en ~300 words", json={"lang": "en", "text": EN_TEXT})
    if not check("HTTP 200", r.status_code == 200, r.text[:200]):
        return
    d = r.json()
    toks = d["tokens"]
    check("round trip == input", "".join(t["t"] for t in toks) == EN_TEXT)
    check("every token has t/w/s", all("t" in t and "w" in t and "s" in t for t in toks))
    the = token_of(toks, "the")
    ubi = token_of(toks, "ubiquitous")
    check("'the' is easy", the and the["level"] == "easy", the)
    lv_of = lambda z: "easy" if z >= 4.5 else ("mid" if z >= 3.5 else "hard")
    check("levels follow 4.5 / 3.5 thresholds", all(t["level"] == lv_of(t["zipf"]) for t in toks if t["w"]))
    check("a 4.5-5.0 word is easy", any(t["w"] and 4.5 <= t["zipf"] < 5.0 and t["level"] == "easy" for t in toks))
    check("'ubiquitous' is hard", ubi and ubi["level"] == "hard", ubi)
    ran = token_of(toks, "ran")
    check("'ran' -> lemma run", ran and ran["lemma"] == "run", ran)
    for name in ("Maria", "Lopez", "$48", "48", "2"):
        t = next((t for t in toks if t["t"].strip() == name), None)
        if t is not None:
            check("'%s' is not a word" % name, not t["w"], t)
    check("no punctuation-only word tokens", not any(t["w"] and not any(c.isalpha() for c in t["t"]) for t in toks))
    ns = len(d["sentences"])
    check("sentences 15..30", 15 <= ns <= 30, ns)
    check("sentence ids consecutive", [s["i"] for s in d["sentences"]] == list(range(ns)))
    check("token s within sentences", all(0 <= t["s"] < ns for t in toks))
    check("first sentence text", d["sentences"][0]["text"].startswith("City officials unveiled"), d["sentences"][0]["text"][:60])
    lv = {}
    for w in d["words"]:
        lv[w["level"]] = lv.get(w["level"], 0) + 1
    print("  words: %d unique, levels %s" % (len(d["words"]), lv))
    print("  hard words:", ", ".join(sorted(w["lemma"] for w in d["words"] if w["level"] == "hard")))
    check("words have lemma/count/zipf/level", all(set(w) >= {"lemma", "count", "zipf", "level"} for w in d["words"]))
    check("'the' counted many times", next((w["count"] for w in d["words"] if w["lemma"] == "the"), 0) >= 10)


def test_analyze_big():
    print("\n== /reading/analyze 20,000 chars")
    big = (EN_TEXT + "\n\n") * 20
    big = big[:20000]
    r = call("POST", "/reading/analyze", "analyze en 20,000 chars", json={"lang": "en", "text": big})
    check("HTTP 200", r.status_code == 200)
    check("round trip", "".join(t["t"] for t in r.json()["tokens"]) == big)
    check("< 2 s", timings[-1][1] < 2.0, "%.2fs" % timings[-1][1])
    jbig = (JA_TEXT * 200)[:20000]
    r = call("POST", "/reading/analyze", "analyze ja 20,000 chars", json={"lang": "ja", "text": jbig})
    check("ja HTTP 200", r.status_code == 200)
    check("ja round trip", "".join(t["t"] for t in r.json()["tokens"]) == jbig)
    check("ja < 2 s", timings[-1][1] < 2.0, "%.2fs" % timings[-1][1])
    r = call("POST", "/reading/analyze", "analyze too long", json={"lang": "en", "text": "a" * 20001})
    check("20,001 chars -> 400 with Korean error", r.status_code == 400 and "error" in r.json(), r.text[:100])
    r = call("POST", "/reading/analyze", "analyze bad lang", json={"lang": "fr", "text": "Bonjour"})
    check("bad lang -> 400", r.status_code == 400, r.text[:100])


def test_analyze_ja():
    print("\n== /reading/analyze ja")
    r = call("POST", "/reading/analyze", "analyze ja paragraph", json={"lang": "ja", "text": JA_TEXT})
    if not check("HTTP 200", r.status_code == 200, r.text[:200]):
        return
    d = r.json()
    toks = d["tokens"]
    check("round trip == input", "".join(t["t"] for t in toks) == JA_TEXT)
    tabe = token_of(toks, "食べ")
    check("食べ(ました) -> lemma 食べる", tabe and tabe["lemma"] == "食べる", tabe)
    iki = token_of(toks, "行き")
    check("行き(ました) -> lemma 行く", iki and iki["lemma"] == "行く", iki)
    wa = token_of(toks, "は")
    check("particle は is easy", wa and wa["level"] == "easy", wa)
    check("sentences >= 5", len(d["sentences"]) >= 5, [s["text"] for s in d["sentences"]])
    print("  sentences:", " / ".join(s["text"] for s in d["sentences"]))
    print("  words:", ", ".join("%s(%s)" % (w["lemma"], w["level"]) for w in d["words"]))


EN_GLOSS = [("unveil", "City officials unveiled an ambitious plan on Tuesday."),
            ("ambitious", "City officials unveiled an ambitious plan on Tuesday."),
            ("fixture", "replace thousands of aging streetlights with energy-efficient LED fixtures"),
            ("outage", "will begin in neighborhoods where outages have been most frequent."),
            ("ubiquitous", "Smart sensors, now ubiquitous in large cities around the world, will be installed."),
            ("dim", "They can dim automatically when streets are empty."),
            ("optimistic", "Critics argued that the timeline was too optimistic."),
            ("run", "a café owner who has run her shop on Elm Street for twelve years"),
            ("anonymize", "all information would be anonymized"),
            ("permit", "Construction is scheduled to start in early spring, weather permitting.")]
JA_GLOSS = [("食べる", "私たちは寿司と天ぷらを食べました。"), ("人気", "とても人気があります。"),
            ("近く", "駅の近くにある小さな店ですが、とても人気があります。"), ("一緒", "来週は家族と一緒にもう一度行きたいと思っています。"),
            ("思う", "来週は家族と一緒にもう一度行きたいと思っています。")]


def test_gloss(lang, pairs):
    print("\n== /reading/gloss %s (%d items)" % (lang, len(pairs)))
    body = {"lang": lang, "items": [{"lemma": l, "sentence": s} for l, s in pairs]}
    r = call("POST", "/reading/gloss", "gloss %s %d items" % (lang, len(pairs)), json=body)
    if not check("HTTP 200", r.status_code == 200, r.text[:300]):
        return
    gl = r.json()["glosses"]
    for g in gl:
        print("   %-12s %-6s %-22s %-16s %s" % (g["lemma"], g["pos"], g["ko"], g["ipa"], g["note"]))
    check("all %d answered" % len(pairs), len(gl) == len(pairs), len(gl))
    check("Korean meanings non-empty", all(g["ko"].strip() for g in gl))
    check("ipa/reading non-empty", all(g["ipa"].strip() for g in gl))
    check("fields present", all(set(g) >= {"lemma", "pos", "ko", "ipa", "note"} for g in gl))
    if lang == "ja":
        tb = next((g for g in gl if g["lemma"] == "食べる"), None)
        check("食べる reading たべる", tb and tb["ipa"] == "たべる", tb and tb["ipa"])
    r = call("POST", "/reading/gloss", "gloss %s cached" % lang, json=body)
    check("second call served from cache (< 1 s)", r.status_code == 200 and timings[-1][1] < 1.0, "%.2fs" % timings[-1][1])
    check("same answers from cache", r.json().get("glosses") == gl)


def test_gloss_errors():
    print("\n== /reading/gloss errors")
    r = call("POST", "/reading/gloss", "gloss 31 items", json={"lang": "en", "items": [{"lemma": "a", "sentence": ""}] * 31})
    check("31 items -> 400", r.status_code == 400 and "error" in r.json(), r.text[:100])
    r = call("POST", "/reading/gloss", "gloss empty", json={"lang": "en", "items": []})
    check("no items -> 400", r.status_code == 400, r.text[:100])


def test_examples():
    for lang, q in (("en", "run"), ("en", "apple"), ("en", "ubiquitous"), ("ja", "食べる")):
        print("\n== /examples %s %s" % (lang, q))
        r = call("GET", "/examples", "examples %s %s" % (lang, q), params={"lang": lang, "q": q, "limit": 5})
        if not check("HTTP 200", r.status_code == 200, r.text[:200]):
            continue
        d = r.json()
        ex = d["examples"]
        for e in ex:
            print("   #%-9d %s | ko: %s | en: %s | ja: %s" % (e["id"], e["text"], e["ko"], e["en"], e["ja"]))
        check("1..5 examples", 1 <= len(ex) <= 5, len(ex))
        check("attribution", "Tatoeba" in d.get("attribution", "") and "CC BY 2.0 FR" in d["attribution"])
        check("url format", all(e["url"] == "https://tatoeba.org/sentences/show/%d" % e["id"] for e in ex))
        if q in ("run", "apple", "食べる"):
            check("has Korean translations", sum(1 for e in ex if e["ko"]) >= 3, sum(1 for e in ex if e["ko"]))
        if q == "run":
            forms = {w.strip(".,!?").lower() for e in ex for w in e["text"].split()} & {"run", "runs", "ran", "running"}
            check("inflected forms matched", len(forms) >= 2, forms)
        if lang == "en":
            check("3..14 words", all(3 <= len(e["text"].split()) <= 14 for e in ex))
    r = call("GET", "/examples", "examples bad lang", params={"lang": "xx", "q": "run"})
    check("bad lang -> 400", r.status_code == 400)
    r = call("GET", "/examples", "examples no q", params={"lang": "en", "q": ""})
    check("empty q -> 400", r.status_code == 400)


def main():
    print("server:", BASE)
    h = requests.get(BASE + "/health", timeout=10).json()
    check("/health has tatoeba", h.get("tatoeba") is True, h)
    test_analyze_en()
    test_analyze_ja()
    test_analyze_big()
    test_examples()
    test_gloss_errors()
    test_gloss("en", EN_GLOSS)
    test_gloss("ja", JA_GLOSS)
    print("\n== timings")
    for name, dt in timings:
        print("  %-28s %6.2fs" % (name, dt))
    bad = [n for n, ok in results if not ok]
    print("\n%d/%d checks passed" % (len(results) - len(bad), len(results)))
    for n in bad:
        print("  FAILED:", n)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
