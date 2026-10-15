# -*- coding: utf-8 -*-
"""Tests the rule-based Tatoeba lessons (POST /lesson, source "tatoeba" = default) against a RUNNING server.
Every exercise is checked against the original sentence in data/tatoeba.sqlite.
Usage:  .venv\\Scripts\\python.exe test_lesson_rules.py [--base http://127.0.0.1:8770] [--n 50] [--ai]
  --ai  also generates one LLM lesson per language (source "ai") and checks its shape.
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

BASE = "http://127.0.0.1:8770"
if "--base" in sys.argv:
    BASE = sys.argv[sys.argv.index("--base") + 1]
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


def main():
    print("server:", BASE)
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
    print("\n%d problem(s)" % len(fails))
    for f in fails[:40]:
        print("  FAIL", f)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
