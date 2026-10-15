# -*- coding: utf-8 -*-
"""Tests of the pronunciation-analysis features (POST /prosody, phonemes in POST /score) against a RUNNING server.
Usage:  .venv\\Scripts\\python.exe test_features.py --base http://127.0.0.1:8796
The "learner" audio is Kokoro TTS (from /tts), so this checks plumbing and the obvious cases, not human speech.
"""
import base64
import io
import sys
import time

import numpy as np
import requests
import soundfile as sf

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

results = []
timings = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def post(path, label, **body):
    t0 = time.time()
    r = requests.post(BASE + path, json=body, timeout=300)
    dt = time.time() - t0
    timings.append((label, dt))
    return r, dt


def tts(text, lang, speed=1.0):
    r = requests.post(BASE + "/tts", json={"text": text, "lang": lang, "speed": speed}, timeout=120)
    assert r.status_code == 200, r.text
    return r.content


def b64(b):
    return base64.b64encode(b).decode("ascii")


def prosody(text, lang, wav=None, reading="", label=None):
    body = {"lang": lang, "text": text, "reading": reading}
    if wav is not None:
        body["audio_b64"] = b64(wav)
    r, dt = post("/prosody", label or "POST /prosody %s %s" % (lang, "with audio" if wav else "native only"), **body)
    if r.status_code != 200:
        print("   HTTP", r.status_code, r.text)
        return None, dt
    return r.json(), dt


def score(say_wav, target, lang, reading="", label=None):
    r, dt = post("/score", label or "POST /score %s" % lang, lang=lang, target=target, reading=reading, audio_b64=b64(say_wav))
    return (r.json() if r.status_code == 200 else None), dt


def ph_stats(d):
    n = ok = 0
    for u in d["units"]:
        for p in u.get("ph", []):
            n += 1
            ok += 1 if p["ok"] else 0
    return n, ok


def flagged(d):
    """[(unit, phoneme, heard)] of phonemes judged not ok"""
    return [(u["t"], p["p"], p["heard"]) for u in d["units"] for p in u.get("ph", []) if not p["ok"]]


def rising_end(wav):
    """TTS audio whose last 40% of speech is resampled faster and faster -> the pitch glides up at the end"""
    x, sr = sf.read(io.BytesIO(wav), dtype="float32")
    n = len(x)
    act = np.where(np.abs(x) > 0.02 * np.abs(x).max())[0]
    s0, s1 = int(act[0]), int(act[-1])
    rate = np.ones(n)
    k = s0 + int((s1 - s0) * 0.6)
    rate[k:s1] = np.linspace(1.0, 1.8, s1 - k)
    pos = np.cumsum(rate) - rate[0]
    pos = pos[pos < n - 1]
    y = np.interp(pos, np.arange(n), x).astype(np.float32)
    buf = io.BytesIO()
    sf.write(buf, y, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def main():
    print("== health")
    h = requests.get(BASE + "/health", timeout=10).json()
    check("/health has phoneme=true", h.get("phoneme") is True, h)

    print("\n== /prosody without audio")
    EN = "I would like a cup of coffee, please."
    d, dt = prosody(EN, "en")
    check("en native-only 200", d is not None)
    nat = d["native"]
    check("en native t/f0 same length, t in 0..1 increasing", len(nat["t"]) == len(nat["f0"]) > 20 and nat["t"][0] == 0 and nat["t"][-1] == 1 and all(a <= b for a, b in zip(nat["t"], nat["t"][1:])))
    pts_per_s = len(nat["t"]) / max(0.1, nat.get("dur", 1))
    check("en about 50 points per second", 45 <= pts_per_s <= 55, "%.1f/s" % pts_per_s)
    check("en f0 has voiced values and gaps (null)", any(v is None for v in nat["f0"]) and sum(v is not None for v in nat["f0"]) > 15)
    voiced = [v for v in nat["f0"] if v is not None]
    check("en f0 is in semitones around the median (|median|<2, range<30)", abs(float(np.median(voiced))) < 2 and max(voiced) - min(voiced) < 30)
    check("en has no mine/accent/similarity", d["mine"] is None and d["accent"] is None and d["mine_accent"] is None and d["similarity"] is None)

    print("\n== /prosody with audio (Kokoro TTS as the learner)")
    wav_en = tts(EN, "en")
    d, dt = prosody(EN, "en", wav_en)
    print("   same sentence: similarity=%s tips=%s (%.2fs)" % (d["similarity"], d["tips_ko"], dt))
    check("en same sentence similarity >= 75", d["similarity"] is not None and d["similarity"] >= 75, d["similarity"])
    check("en mine on the native time grid", d["mine"] is not None and d["mine"]["t"] == d["native"]["t"])
    check("en tips_ko is a list of strings", isinstance(d["tips_ko"], list) and all(isinstance(t, str) for t in d["tips_ko"]))
    d2, _ = prosody(EN, "en", tts(EN, "en", 0.85))
    print("   same sentence at speed 0.85 (DTW): similarity=%s" % d2["similarity"])
    check("en same sentence slower (DTW) similarity >= 60", d2["similarity"] is not None and d2["similarity"] >= 60, d2["similarity"])
    d3, _ = prosody(EN, "en", tts("Where is the station?", "en"))
    print("   different sentence: similarity=%s tips=%s" % (d3["similarity"], d3["tips_ko"]))
    check("en different sentence similarity < 40", d3["similarity"] is not None and d3["similarity"] < 40, d3["similarity"])
    print("\n== question vs statement intonation")
    q = "Are you ready?"
    w_state = tts("Are you ready.", "en")
    d, _ = prosody(q, "en", w_state)
    print("   text '?' + falling statement audio: tips=%s" % d["tips_ko"])
    check("question text + falling audio -> tip to raise the end", any("올려" in t and "끝" in t for t in d["tips_ko"]))
    w_rise = rising_end(tts("Are you ready", "en"))
    d, _ = prosody("Are you ready.", "en", w_rise)
    print("   statement text + rising audio: tips=%s" % d["tips_ko"])
    check("statement text + rising audio -> 'you raised the end' tip", any(t.startswith("문장 끝을 올려 말했어요") for t in d["tips_ko"]))
    d, _ = prosody(q, "en", w_rise)
    print("   question text + rising audio: tips=%s" % d["tips_ko"])
    check("question text + rising audio -> no raise-the-end complaint", not any("끝을 더 올려" in t or "끝을 올려야" in t for t in d["tips_ko"]))

    print("\n== /score phonemes: correct TTS")
    for lang, text, rd in (("en", "I like milk and bread.", ""), ("en", "Thank you very much.", ""), ("en", "I would like a cup of coffee, please.", ""),
                           ):
        d, dt = score(tts(text, lang), text, lang, rd)
        n, ok = ph_stats(d)
        print("   %s %r: %d/%d phonemes ok (%.0f%%) %.2fs  flagged=%s" % (lang, text, ok, n, 100.0 * ok / max(1, n), dt, flagged(d)))
        check("%s %r >= 85%% phonemes ok" % (lang, text), n > 0 and ok / n >= 0.85)
        check("old fields kept (transcript/score/accuracy/clarity/fluency/units/tips_ko), units have t/ok/conf/heard", all(k in d for k in ("transcript", "score", "accuracy", "clarity", "fluency", "units", "tips_ko")) and all({"t", "ok", "conf", "heard"} <= set(u) for u in d["units"]))
        check("ph entries have p/ok/conf/heard and tips_ko <= 3", all({"p", "ok", "conf", "heard"} <= set(p) for u in d["units"] for p in u.get("ph", [])) and len(d["tips_ko"]) <= 3)

    print("\n== /score phonemes: deliberately wrong audio")
    cases = [
        ("sink", "think", "en", "", lambda f, tips: any(p == "θ" and (h in ("s", "t", "f", "z")) for _u, p, h in f), lambda tips: any("θ" in t and "혀끝" in t for t in tips), "think<-sink: θ heard as s + th tip"),
        ("Sank you very much.", "Thank you very much.", "en", "", lambda f, tips: any(p == "θ" and h == "s" for _u, p, h in f), lambda tips: any("θ" in t and "s로" in t for t in tips), "thank<-sank: θ heard as s"),
        ("The ship is big.", "The sheep is big.", "en", "", lambda f, tips: any(p == "iː" and h in ("ɪ", "ᵻ", "i") for _u, p, h in f), lambda tips: any("iː" in t or "sheep" in t for t in tips), "sheep<-ship: iː heard as ɪ"),
        ("The lice are on the table.", "The rice is on the table.", "en", "", lambda f, tips: any(p == "ɹ" and h == "l" for _u, p, h in f), lambda tips: any("r이" in t and "l" in t for t in tips), "rice<-lice: r heard as l"),
        ("Turn right here.", "Turn light here.", "en", "", lambda f, tips: any(p == "l" and h in ("ɹ", "r") for _u, p, h in f), lambda tips: any("l이" in t for t in tips), "light<-right: l heard as r"),
    ]
    for say, target, lang, rd, flag_ok, tip_ok, label in cases:
        d, dt = score(tts(say, lang), target, lang, rd)
        f = flagged(d)
        print("   say=%r target=%r (%.2fs)\n     flagged=%s\n     tips=%s" % (say, target, dt, f, d["tips_ko"]))
        check(label + " -> right phoneme flagged", flag_ok(f, d["tips_ko"]))
        check(label + " -> right Korean tip", tip_ok(d["tips_ko"]))

    print("\n== timing: /score on a ~4 s clip")
    long_text = "I would like to order a cup of coffee and a piece of cake, please."
    w = tts(long_text, "en")
    x, sr = sf.read(io.BytesIO(w))
    print("   clip length %.1f s" % (len(x) / sr))
    for i in range(2):
        d, dt = score(w, long_text, "en", label="POST /score en long clip #%d" % (i + 1))
        print("   /score %.2fs (STT device may be CPU on a test server)" % dt)
    d, dt = prosody(long_text, "en", w, label="POST /prosody en long clip")
    print("   /prosody with audio %.2fs" % dt)

    print("\n== timings")
    for k, v in timings:
        print("   %-42s %.2fs" % (k, v))
    fails = [n for n, ok in results if not ok]
    print("\n== features result: %d passed, %d failed" % (len(results) - len(fails), len(fails)))
    for n in fails:
        print("   FAILED:", n)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
