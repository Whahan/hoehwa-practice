# -*- coding: utf-8 -*-
"""End-to-end test of every endpoint against a RUNNING test server (start your own: server.py --port 8796 --tag mytest; --base is required).
Usage:  .venv\\Scripts\\python.exe test_backend.py --base http://127.0.0.1:8796
"""
import base64
import json
import os
import re
import sys
import time
from io import BytesIO
from math import gcd

import numpy as np
import requests
import soundfile as sf
from scipy.signal import resample_poly

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
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "test_out")
os.makedirs(OUT, exist_ok=True)

results = []
timings = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def call(method, path, label=None, **kw):
    t0 = time.time()
    r = requests.request(method, BASE + path, timeout=400, **kw)
    dt = time.time() - t0
    timings.append((label or ("%s %s" % (method, path)), dt))
    print("  (%s %s -> HTTP %d in %.2fs)" % (method, path, r.status_code, dt))
    return r


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def wav_info(data):
    info = sf.info(BytesIO(data))
    return info


def to_44k_stereo(data: bytes) -> bytes:
    x, sr = sf.read(BytesIO(data), dtype="float32")
    g = gcd(44100, sr)
    y = resample_poly(x, 44100 // g, sr // g).astype(np.float32)
    buf = BytesIO()
    sf.write(buf, np.stack([y, y], axis=1), 44100, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def valid_ex(e):  # same rules as the web app's validEx
    if not isinstance(e, dict):
        return False
    opts, ans = e.get("options"), e.get("answer")
    opts_ok = isinstance(opts, list) and len(opts) >= 2 and all(isinstance(o, str) for o in opts) and isinstance(ans, int) and 0 <= ans < len(opts)
    t = e.get("type")
    if t == "choice":
        return opts_ok and isinstance(e.get("question"), str)
    if t == "fill":
        return opts_ok and isinstance(e.get("sentence"), str) and "___" in e["sentence"]
    if t == "listen":
        return opts_ok and isinstance(e.get("audio"), str) and e["audio"].strip() != ""
    if t == "build":
        return isinstance(ans, list) and len(ans) >= 2 and all(isinstance(x, str) and x.strip() for x in ans)
    if t == "speak":
        return isinstance(e.get("text"), str) and e["text"].strip() != ""
    return False


HANGUL = re.compile(r"[가-힣]")

EN_SENT = "I would like a cup of coffee and a blueberry muffin, please."
EN_OTHER = "The train to Boston leaves at seven o'clock tomorrow morning."
JA_SENT = "毎朝七時に起きて、コーヒーを飲みます。"
JA_READ = "まいあさしちじにおきて、コーヒーをのみます。"
JA_OTHER = "週末は友達と一緒に映画を見に行きます。"
JA_OTHER_READ = "しゅうまつはともだちといっしょにえいがをみにいきます。"


def main():
    print("Backend:", BASE)
    wavs = {}

    print("\n== /health")
    h = call("GET", "/health").json()
    print("  ", json.dumps(h))
    check("health ok + all ready", h.get("ok") and h.get("stt") and h["tts"]["en"] and h["tts"]["ja"] and h.get("llm") and h.get("score"), h)
    check("health has llm_model", bool(h.get("llm_model")))

    print("\n== /curriculum")
    c = call("GET", "/curriculum").json()
    check("curriculum has en+ja with 12 months", len(c["en"]["months"]) == 12 and len(c["ja"]["months"]) == 12)

    print("\n== /tts")
    for lang, text in (("en", EN_SENT), ("ja", JA_SENT)):
        r = call("POST", "/tts", "POST /tts %s (first)" % lang, json={"text": text, "lang": lang, "speed": 1.0})
        ok = r.status_code == 200 and r.headers.get("content-type", "").startswith("audio/wav")
        check("tts %s returns audio/wav" % lang, ok)
        if ok:
            info = wav_info(r.content)
            check("tts %s is 24kHz mono 16-bit" % lang, info.samplerate == 24000 and info.channels == 1 and info.subtype == "PCM_16",
                  "%d Hz, %d ch, %s, %.2fs" % (info.samplerate, info.channels, info.subtype, info.duration))
            check("tts %s duration plausible" % lang, 1.5 < info.duration < 15)
            wavs[lang] = r.content
            with open(os.path.join(OUT, "tts_%s.wav" % lang), "wb") as f:
                f.write(r.content)
            r2 = call("POST", "/tts", "POST /tts %s (cached)" % lang, json={"text": text, "lang": lang, "speed": 1.0})
            check("tts %s cache returns identical bytes" % lang, r2.content == r.content)
    r = call("POST", "/tts", "POST /tts en speed 0.7", json={"text": EN_SENT, "lang": "en", "speed": 0.7})
    if r.status_code == 200:
        check("tts speed 0.7 is longer than 1.0", wav_info(r.content).duration > wav_info(wavs["en"]).duration * 1.2)

    print("\n== /stt (TTS audio fed back, one as 44.1 kHz stereo)")
    for lang, text in (("en", EN_SENT), ("ja", JA_SENT)):
        if lang not in wavs:
            continue
        audio = to_44k_stereo(wavs[lang]) if lang == "en" else wavs[lang]
        r = call("POST", "/stt", "POST /stt %s" % lang, json={"lang": lang, "audio_b64": b64(audio)})
        d = r.json()
        print("   text:", d.get("text"))
        check("stt %s HTTP 200 + fields" % lang, r.status_code == 200 and all(k in d for k in ("text", "words", "duration")))
        w = d.get("words", [])
        check("stt %s has word timings" % lang, len(w) > 3 and all(k in w[0] for k in ("w", "p", "start", "end")) and 0 <= w[0]["p"] <= 1)
        if lang == "en":
            got = set(re.findall(r"[a-z]+", d["text"].lower()))
            want = set(re.findall(r"[a-z]+", text.lower()))
            check("stt en transcript matches (>=80% of words)", len(got & want) / len(want) >= 0.8, d["text"])
        else:
            check("stt ja transcript contains key words", "起き" in d["text"] and "コーヒー" in d["text"], d["text"])

    print("\n== /score")
    scores = {}
    for lang, tgt, rd, other, other_rd in (("en", EN_SENT, "", EN_OTHER, ""), ("ja", JA_SENT, JA_READ, JA_OTHER, JA_OTHER_READ)):
        if lang not in wavs:
            continue
        r = call("POST", "/score", "POST /score %s same target" % lang, json={"lang": lang, "target": tgt, "reading": rd, "audio_b64": b64(wavs[lang])})
        d = r.json()
        check("score %s same target HTTP 200 + fields" % lang, r.status_code == 200 and all(k in d for k in ("transcript", "score", "accuracy", "clarity", "fluency", "units", "tips_ko")), d if r.status_code != 200 else "")
        print("   score=%s acc=%s clarity=%s fluency=%s transcript=%s" % (d.get("score"), d.get("accuracy"), d.get("clarity"), d.get("fluency"), d.get("transcript")))
        print("   units:", " ".join(("%s%s" % (u["t"], "" if u["ok"] else "(x:%s)" % u["heard"])) for u in d["units"]))
        check("score %s same target >= 80" % lang, d["score"] >= 80, d["score"])
        check("score %s units have t/ok/conf/heard" % lang, all({"t", "ok", "conf", "heard"} <= set(u) <= {"t", "ok", "conf", "heard", "ph"} for u in d["units"]))
        scores[lang] = d["score"]
        r = call("POST", "/score", "POST /score %s different target" % lang, json={"lang": lang, "target": other, "reading": other_rd, "audio_b64": b64(wavs[lang])})
        d2 = r.json()
        print("   score=%s acc=%s clarity=%s fluency=%s" % (d2.get("score"), d2.get("accuracy"), d2.get("clarity"), d2.get("fluency")))
        print("   units:", " ".join(("%s%s" % (u["t"], "" if u["ok"] else "(x:%s)" % u["heard"])) for u in d2["units"][:25]))
        for t in d2.get("tips_ko", []):
            print("   tip:", t)
        check("score %s different target clearly lower (<60 and >=30 below)" % lang, d2["score"] < 60 and d2["score"] <= scores[lang] - 30, d2["score"])
        check("score %s different target has tips (<=3)" % lang, 1 <= len(d2["tips_ko"]) <= 3)

    # a deliberately mispronounced English sample: pass the Japanese audio against an English target -> empty/garbage; silence test:
    sil = BytesIO()
    sf.write(sil, np.zeros(24000, dtype=np.float32), 16000, format="WAV", subtype="PCM_16")
    r = call("POST", "/score", "POST /score silence", json={"lang": "en", "target": EN_SENT, "reading": "", "audio_b64": b64(sil.getvalue())})
    d = r.json()
    check("score silence -> all zeros + mic tip", d["score"] == 0 and d["accuracy"] == 0 and d["clarity"] == 0 and d["fluency"] == 0 and "목소리가 들리지 않았어요" in d["tips_ko"][0])
    # substitution tips: English audio scored against a target that differs by r/l and f/p
    if "en" in wavs:
        r = call("POST", "/score", "POST /score en (r/l target)", json={"lang": "en", "target": "I would like a cup of coffee and a bluebelly muffin, please.", "reading": "", "audio_b64": b64(wavs["en"])})
        d = r.json()
        print("   score=%s tips=%s" % (d["score"], d["tips_ko"]))
        check("score en near-miss word flagged not ok", any((not u["ok"]) for u in d["units"]) and d["score"] < scores.get("en", 100))

    print("\n== /score pronunciation tips (TTS of a minimal-pair sentence scored against the intended target)")
    tip_cases = [
        ("en", "The lice are on the table.", "The rice is on the table.", ""),
        ("en", "Put the ship in the water.", "Put the sheep in the water.", ""),
        ("ja", "おばさんが来ました。", "おばあさんが来ました。", "おばあさんがきました。"),
        ("ja", "きてください。", "きってください。", "きってください。"),
    ]
    for lang, say, target, reading in tip_cases:
        r = call("POST", "/tts", "POST /tts (tip sample)", json={"text": say, "lang": lang, "speed": 1.0})
        r = call("POST", "/score", "POST /score %s tip sample" % lang,
                 json={"lang": lang, "target": target, "reading": reading, "audio_b64": b64(r.content)})
        d = r.json()
        print("   said=%r target=%r -> score=%s transcript=%r" % (say, target, d.get("score"), d.get("transcript")))
        print("   units:", " ".join(("%s%s" % (u["t"], "" if u["ok"] else "(x:%s)" % u["heard"])) for u in d["units"]))
        for t in d["tips_ko"]:
            print("   tip:", t)
        check("score %s '%s' sample: unit flagged + tip given" % (lang, target), r.status_code == 200 and any(not u["ok"] for u in d["units"]) and len(d["tips_ko"]) >= 1)

    print("\n== error format")
    r = call("POST", "/tts", "POST /tts bad lang", json={"text": "hi", "lang": "xx"})
    check("bad lang -> 4xx {error}", 400 <= r.status_code < 500 and "error" in r.json() and HANGUL.search(r.json()["error"]), r.text)
    r = call("POST", "/stt", "POST /stt empty", json={"lang": "en", "audio_b64": ""})
    check("empty audio -> 4xx {error}", 400 <= r.status_code < 500 and "error" in r.json(), r.text)

    print("\n== /chat (en)")
    scen = {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."}
    req = {"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": scen, "history": []}
    r = call("POST", "/chat", "POST /chat en (opening)", json=req)
    d = r.json()
    print("  ", json.dumps(d, ensure_ascii=False))
    check("chat opening shape", r.status_code == 200 and all(k in d for k in ("reply", "reading", "ko", "fix", "fix_ko", "suggest")), r.text[:200])
    check("chat opening reply non-empty English", bool(d.get("reply")) and not HANGUL.search(d["reply"]))
    check("chat opening ko is Korean", bool(HANGUL.search(d.get("ko", ""))))
    check("chat opening: reading '' and fix '' and 2 suggestions", d.get("reading") == "" and d.get("fix") == "" and len(d.get("suggest", [])) == 2)
    hist = [{"role": "ai", "text": d["reply"]}, {"role": "me", "text": "I want go to cafe yesterday"}]
    req["history"] = hist
    r = call("POST", "/chat", "POST /chat en (learner turn)", json=req)
    d = r.json()
    print("  ", json.dumps(d, ensure_ascii=False))
    check("chat turn: fix non-empty (mistake corrected)", bool(d.get("fix")) and d["fix"].strip().lower() != "i want go to cafe yesterday", d.get("fix"))
    check("chat turn: fix_ko is Korean", bool(HANGUL.search(d.get("fix_ko", ""))))
    check("chat turn: reply non-empty", bool(d.get("reply")))
    hist.append({"role": "ai", "text": d["reply"]})
    hist.append({"role": "me", "text": "Yes, I would like a small latte, please."})
    req["history"] = hist
    r = call("POST", "/chat", "POST /chat en (correct sentence)", json=req)
    d = r.json()
    print("  ", json.dumps(d, ensure_ascii=False))
    check("chat correct sentence: reply ok", r.status_code == 200 and bool(d.get("reply")))
    en_hist = hist + [{"role": "ai", "text": d["reply"]}]

    print("\n== /chat (ja)")
    jscen = {"id": "konbini", "title": "편의점", "persona": "Tanaka, a cheerful convenience store clerk in Tokyo", "scene": "The learner buys snacks at the counter."}
    jreq = {"lang": "ja", "stage": 1, "month": 1, "week": 2, "scenario": jscen, "history": []}
    r = call("POST", "/chat", "POST /chat ja (opening)", json=jreq)
    d = r.json()
    print("  ", json.dumps(d, ensure_ascii=False))
    check("chat ja shape + reading hiragana", r.status_code == 200 and bool(d.get("reading")) and re.fullmatch(r"[ぁ-ゖー、。！？\s]+", d["reading"]) is not None, d.get("reading"))
    check("chat ja reply is Japanese", bool(re.search(r"[ぁ-んァ-ン]", d.get("reply", ""))))
    check("chat ja has a katakana pron (pronunciation form of the reply)", re.fullmatch(r"[ァ-ヶー、，。！？\s・…「」]+", d.get("pron", "")) is not None, d.get("pron"))

    print("\n== /feedback")
    fb_req = {"lang": "en", "stage": 1, "history": en_hist}
    r = call("POST", "/feedback", "POST /feedback en", json=fb_req)
    d = r.json()
    print("  ", json.dumps(d, ensure_ascii=False)[:900])
    check("feedback shape", r.status_code == 200 and set(d.get("scores", {})) == {"fluency", "accuracy", "vocabulary"} and all(1 <= v <= 5 for v in d["scores"].values()))
    check("feedback summary Korean", bool(HANGUL.search(d.get("summary", ""))))
    check("feedback has corrections list + phrases", isinstance(d.get("corrections"), list) and len(d.get("phrases", [])) >= 1)
    check("feedback corrections have you/better/reading/pron/ko/why", all(set(c) == {"you", "better", "reading", "pron", "ko", "why"} for c in d["corrections"]))
    r = call("POST", "/feedback", "POST /feedback (no learner lines)", json={"lang": "en", "stage": 1, "history": [{"role": "ai", "text": "Hi!"}]})
    check("feedback without learner lines -> 4xx {error}", 400 <= r.status_code < 500 and "error" in r.json())

    print("\n== /lesson")
    for lang in ("en", "ja"):
        r = call("POST", "/lesson", "POST /lesson %s month 1" % lang, json={"lang": lang, "month": 1, "week": 1, "stage": 1})
        d = r.json()
        if r.status_code != 200:
            check("lesson %s HTTP 200" % lang, False, r.text[:200])
            continue
        ex = d["exercises"]
        types = {}
        for e in ex:
            types[e["type"]] = types.get(e["type"], 0) + 1
        print("   title:", d["title"], "| count:", len(ex), "| types:", types)
        for e in ex[:10]:
            print("    ", json.dumps(e, ensure_ascii=False)[:230])
        check("lesson %s >= 6 valid exercises" % lang, len(ex) >= 6 and all(valid_ex(e) for e in ex), len(ex))
        check("lesson %s title Korean" % lang, bool(HANGUL.search(d["title"])))
        check("lesson %s mixes >= 3 types" % lang, len(types) >= 3, types)
        if lang == "ja":
            need = [e for e in ex if e["type"] in ("fill", "listen", "speak", "build")]
            check("lesson ja: readings present", all(e.get("reading") for e in need))
            check("lesson ja: pron present (katakana)", all(re.fullmatch(r"[ァ-ヶー、，。！？\s・…「」_]+", e.get("pron", "")) for e in need), [e.get("pron") for e in need][:2])

    print("\n================ SUMMARY ================")
    print("%-42s %8s" % ("call", "seconds"))
    for k, v in timings:
        print("%-42s %8.2f" % (k, v))
    failed = [n for n, ok in results if not ok]
    print("\n%d checks, %d passed, %d failed" % (len(results), len(results) - len(failed), len(failed)))
    for n in failed:
        print("  FAILED:", n)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except requests.exceptions.ConnectionError:
        print("Cannot reach the backend. Start it with run_backend.bat first.")
        sys.exit(2)
