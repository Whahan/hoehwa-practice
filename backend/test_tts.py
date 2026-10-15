# -*- coding: utf-8 -*-
"""TTS speed / voices / cache tests.

  Test server (fake LLM, real Kokoro) on a side port, e.g.:
      .venv\\Scripts\\python.exe test_tts.py --serve --port 8789 --tag tts --stt-cpu
  Client checks against a running server (any server for most checks; /chat checks need the fake-LLM one):
      .venv\\Scripts\\python.exe test_tts.py --base http://127.0.0.1:8789 --tag tts [--cache-dir DIR --cap-mb 2]
  Unit checks only (splitter, voices):   test_tts.py --unit
  Dump splitter cases for the Godot parity test:   test_tts.py --dump-split ..\\godot\\tests\\sample_tts_split.json
"""
import io
import json
import os
import random
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


SPLIT_CASES = [
    ("en", "Hello there."),
    ("en", "Really? That sounds amazing! Where did you go?"),
    ("en", "Oh, that sounds like a great weekend, did you go with your friends?"),
    ("en", "Mr. Smith lives in the U.S. and likes tea. He pays 3.5 dollars."),
    ("en", "I met J. K. Rowling yesterday. She was nice."),
    ("en", "Wait... what? No way!!"),
    ("en", "She said \"stop.\" Then she left."),
    ("en", "First line.\nSecond line without a stop\nThird one!"),
    ("en", "That is great, but I have a long day tomorrow, so I should go to bed early tonight."),
    ("en", "No commas here but it is a fairly long sentence that goes on and on."),
    ("en", "  Spaces   everywhere .  Really ?  "),
    ("en", ""),
    ("ja", "えっ、本当？すごいね！どこに行ったの？"),
    ("ja", "こんにちは。はじめまして。週末はどうでしたか。"),
    ("ja", "昨日は友達と一緒に、新宿でおいしいラーメンを食べました。"),
    ("ja", "「ありがとう。」と言いました。それから帰りました。"),
    ("ja", "短いです。"),
    ("ja", "はい!そうです?"),
]


def split_expected():
    import server
    return [{"lang": l, "text": t, "chunks": server.tts_chunks(t, l), "sentences": server.split_sentences(t, l)} for l, t in SPLIT_CASES]


NAMES = ["Sam", "Kate", "Ben", "Lily", "Tom", "Anna", "Max", "Zoe", "Dan", "Eva", "Leo", "Amy", "Jack", "Ruby", "Finn", "Nora"]
PLACES = ["Seattle", "Boston", "Denver", "Austin", "Miami", "Dallas", "Tampa", "Reno", "Provo", "Omaha", "Tulsa", "Salem"]
ADJ = ["lovely", "wonderful", "relaxing", "exciting", "fantastic", "peaceful", "busy", "fun", "amazing", "perfect"]
FAKE_REPLIES = {
    "en1q": ("en", "That sounds {a}, {n}."),
    "en1s": ("en", "{a} {p} sounds really nice, {n}."),
    "en1": ("en", "{a} {p} sounds like a great weekend, did you go with your friend {n}?"),
    "en3": ("en", "Oh, {a} {p} sounds like a great weekend. Did you go with your friend {n}? Tell me more about the trip!"),
    "ja1": ("ja", "{p}ですか、それはすごいですね、{p2}にもいきましたか。"),
}
JA_PLACES = ["東京", "大阪", "京都", "福岡", "札幌", "名古屋", "神戸", "奈良", "広島", "仙台", "横浜", "金沢"]


def serve():
    import server
    from fastapi import HTTPException

    def fake_run_chat(req):
        key = (req.history[-1].text if req.history else "en1").strip()
        lang, tpl = FAKE_REPLIES[key]
        time.sleep(0.05)
        reply = tpl.format(n=random.choice(NAMES) + random.choice(["", " and Kim", " and Joe"]), p=random.choice(PLACES if lang == "en" else JA_PLACES), a=random.choice(ADJ).capitalize(), p2=random.choice(JA_PLACES))
        return {"reply": reply, "reading": "", "ko": "", "fix": "", "fix_ko": "", "suggest": ["a", "b"]}

    server.run_chat = fake_run_chat
    server.main()


# ------------------------------------------------------------------------------------------------ client
results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def log_lines(tag):
    p = os.path.join(HERE, "logs", "server-%s.log" % tag)
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def main():
    import requests
    import soundfile as sf
    import hashlib
    base = arg("--base", "http://127.0.0.1:8789")
    tag = arg("--tag", "tts")

    def tts(text, lang="en", speed=1.0, **kw):
        t0 = time.time()
        r = requests.post(base + "/tts", json=dict(text=text, lang=lang, speed=speed, **kw), timeout=120)
        return r, time.time() - t0

    print("== voices")
    v = requests.get(base + "/tts/voices", timeout=10).json()
    print("  ", json.dumps(v, ensure_ascii=False))
    import server
    local = sorted(os.path.splitext(os.path.basename(f))[0] for f in server._voice_files())
    listed = sorted(x["id"] for l in ("en", "ja") for x in v["voices"][l])
    check("/tts/voices lists only locally present voices", set(listed) <= set(local) and len(listed) > 0, "listed=%s local=%s" % (listed, local))
    check("default voices marked", any(x["default"] for x in v["voices"]["en"]) and any(x["default"] for x in v["voices"]["ja"]))
    h = requests.get(base + "/health", timeout=10).json()
    check("/health has tts_device", h.get("tts_device") in ("cpu", "cuda"), h.get("tts_device"))

    print("== cache hit and in-flight dedupe")
    uniq = "%d cache test sentence." % random.randint(100000, 999999)
    r1, d1 = tts(uniq)
    r2, d2 = tts(uniq)
    check("second request is fast and identical", r1.status_code == 200 and r1.content == r2.content and d2 < 0.1, "%.2fs -> %.3fs" % (d1, d2))
    check("log shows 'tts cache hit'", any("tts cache hit" in l and uniq[:30] in l for l in log_lines(tag)))
    uniq2 = "%d simultaneous request sentence, please." % random.randint(100000, 999999)
    out = []
    ths = [threading.Thread(target=lambda: out.append(tts(uniq2))) for _ in range(2)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    time.sleep(0.3)
    lines = [l for l in log_lines(tag) if uniq2[:30] in l]
    n_synth = sum("tts synth" in l for l in lines)
    n_join = sum("in-flight join" in l or "cache hit" in l for l in lines)
    check("two simultaneous requests -> one synthesis", n_synth == 1 and n_join >= 1 and out[0][0].content == out[1][0].content, "synth=%d join/hit=%d" % (n_synth, n_join))

    print("== voice choice")
    sp = server._voice_files()
    snap = os.path.dirname(sp[0])
    tmp_voice = os.path.join(snap, "af_zztest.pt")
    import torch
    base_pt = torch.load(sp[0], map_location="cpu", weights_only=True)
    torch.save(base_pt * 0.8, tmp_voice)
    try:
        v2 = requests.get(base + "/tts/voices", timeout=10).json()
        check("temp voice shows up in /tts/voices", any(x["id"] == "af_zztest" for x in v2["voices"]["en"]))
        s = "Voices can sound different %d." % random.randint(1000, 9999)
        ra, _ = tts(s, voice="af_heart")
        rb, _ = tts(s, voice="af_zztest")
        rc, _ = tts(s, voice="af_nonexistent")
        ha, hb, hc = [hashlib.sha1(x.content).hexdigest()[:10] for x in (ra, rb, rc)]
        check("different voice -> different audio hash (cache key includes voice)", ra.status_code == 200 and rb.status_code == 200 and ha != hb, "%s vs %s" % (ha, hb))
        check("unknown voice falls back to default", hc == ha, hc)
    finally:
        try:
            os.remove(tmp_voice)
        except OSError:
            pass

    print("== /chat presynth latency (fake LLM)")
    rows = []
    for key in ("en1q", "en1s", "en1", "en3", "ja1") * int(arg("--trials", "1")):
        lang = FAKE_REPLIES[key][0]
        body = {"lang": lang, "stage": 1, "month": 1, "week": 1, "scenario": {}, "history": [{"role": "me", "text": key}], "skip_fix": True,
                "tts_speed": 1.0, "tts_voice": ""}
        # BEFORE (old behaviour): no pre-synthesis, the whole reply is one /tts request after the reply arrived
        r0 = requests.post(base + "/chat", json=dict(body, presynth=False), timeout=60)
        t0 = time.time()
        full = r0.json()["reply"]
        tts(full, lang)
        before = time.time() - t0
        r = requests.post(base + "/chat", json=body, timeout=60)
        t_recv = time.time()
        if r.status_code != 200 or "tts_chunks" not in r.json():
            check("/chat %s returns tts_chunks" % key, False, r.text[:200])
            continue
        chunks = r.json()["tts_chunks"]
        times = []
        for c in chunks:
            rr, _ = tts(c, lang)
            t_done = time.time()
            info = sf.info(io.BytesIO(rr.content))
            times.append((t_done - t_recv, info.duration))
        rows.append((key, chunks, times))
        print("  %s BEFORE (whole reply, single /tts): audio starts %.2fs after reply" % (key, before))
        print("  %s chunks=%s" % (key, json.dumps(chunks, ensure_ascii=False)))
        print("     chunk ready after /chat reply (s) / audio length (s): %s" % ", ".join("%.2f/%.2f" % t for t in times))
    import statistics
    for key in ("en1q", "en1s", "en1", "en3", "ja1"):
        rs = [r for r in rows if r[0] == key]
        if not rs:
            continue
        first = statistics.median(r[2][0][0] for r in rs)
        print("  %s median first-chunk-ready over %d trials: %.2fs" % (key, len(rs), first))
        if key == "en1q":
            check("en short 1-sentence reply (~2 s of audio): first audio <= 0.6 s after reply (median)", first <= 0.6, "%.2fs" % first)
        if key == "en1s":   # ~2.5 s of audio in the first chunk: 0.25 s x 2.5 = the CPU floor, a bit above 0.6
            aud = statistics.median(r[2][0][1] for r in rs)
            check("en 1-sentence reply with 2.5 s first chunk: first audio within the CPU floor (<= 0.3 x audio + 0.1 s)", first <= 0.3 * aud + 0.1, "%.2fs for %.2fs of audio" % (first, aud))
        if key == "en1":   # first chunk is ~3 s of audio
            aud = statistics.median(r[2][0][1] for r in rs)
            check("en long 1-sentence (clause-split head): first audio within the CPU floor (<= 0.3 x audio + 0.1 s)", first <= 0.3 * aud + 0.1, "%.2fs for %.2fs of audio" % (first, aud))
        if key in ("en3", "ja1"):
            ok = True
            for _k, _c, times in rs:
                start = times[0][0]
                for i in range(1, len(times)):
                    play_at = start + sum(t[1] + 0.15 for t in times[:i])
                    ok = ok and times[i][0] <= play_at + 0.05
            check("%s: every chunk ready before the previous one finishes playing" % key, ok)

    cap = arg("--cap-mb")
    cdir = arg("--cache-dir")
    if cap and cdir:
        print("== LRU cache eviction (cap %s MB, dir %s)" % (cap, cdir))
        capb = float(cap) * 1048576
        for i in range(60):
            tts("Eviction filler sentence number %d, long enough to take some space on disk." % i)
            if i == 3:
                keep_text = "Eviction filler sentence number 3, long enough to take some space on disk."
        size = sum(os.path.getsize(os.path.join(cdir, f)) for f in os.listdir(cdir) if f.endswith(".wav"))
        n = len([f for f in os.listdir(cdir) if f.endswith(".wav")])
        check("cache stays under the cap after filling past it", size <= capb, "%.2f MB in %d files (cap %.1f MB)" % (size / 1048576, n, float(cap)))
        check("cache is not just empty (newest clips kept)", n >= 3)
        recent = "Eviction filler sentence number 59, long enough to take some space on disk."
        r, d = tts(recent)
        check("newest clip still cached", d < 0.1, "%.3fs" % d)
        oldest = "Eviction filler sentence number 0, long enough to take some space on disk."
        r, d = tts(oldest)
        check("oldest clip was evicted (re-synthesized)", d > 0.15, "%.3fs" % d)

    bad = [n for n, ok in results if not ok]
    print("\n%d checks, %d failed" % (len(results), len(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    if "--dump-split" in sys.argv:
        out = split_expected()
        with open(arg("--dump-split"), "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print("wrote", len(out), "cases")
    elif "--unit" in sys.argv:
        for c in split_expected():
            print(c["lang"], json.dumps(c["text"], ensure_ascii=False), "->", json.dumps(c["chunks"], ensure_ascii=False))
    elif "--serve" in sys.argv:
        serve()
    else:
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
        main()
