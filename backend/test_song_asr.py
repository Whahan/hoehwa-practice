# -*- coding: utf-8 -*-
"""Tests of song_asr.py (song study K3). No server, no real model, no network: the Whisper model is a fake injected into
transcribe_song(). Lyrics used here are written for this test (no real songs).

  .venv\\Scripts\\python.exe -I test_song_asr.py

Last line:  == test_song_asr: N passed, 0 failed ==   (exit 0)
"""
import ast
import os
import re
import sys
import threading
import time
from types import SimpleNamespace as NS

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np  # noqa: E402
import song_asr as sa  # noqa: E402

PASSED, FAILED = [], []


def ok(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if (detail != "" and not cond) else ""))
    return bool(cond)


SR = 16000


def W(word, s, e, p=0.9):
    return NS(word=" " + word, start=s, end=e, probability=p)


def SEG(words, text=None):
    return NS(text=text if text is not None else " ".join(w.word.strip() for w in words), words=words)


class FakeModel:
    """transcribe(chunk, **kw) -> (segments, info). ``script`` is a function (call_index, chunk, kw) -> list of segments."""

    def __init__(self, script=None, lock=None, on_call=None):
        self.script = script or (lambda i, chunk, kw: [SEG([W("la", 0.5, 0.9)])])
        self.calls = []
        self.lock = lock
        self.on_call = on_call
        self.held_during_call = []

    def transcribe(self, chunk, **kw):
        i = len(self.calls)
        self.calls.append({"n": len(chunk), "kw": kw, "peak": float(np.max(np.abs(chunk))) if len(chunk) else 0.0})
        if self.lock is not None:
            self.held_during_call.append(self.lock.locked())
        if self.on_call:
            self.on_call(i)
        return iter(self.script(i, chunk, kw)), None


def tone(sec, amp=0.3, f=220.0):
    t = np.arange(int(sec * SR)) / SR
    return (amp * np.sin(2 * np.pi * f * t)).astype(np.float32)


def signal_with_silences(sec, seed=1):
    """noisy 'voice' with quiet gaps every ~6 s, so boundaries have a clear quiet spot"""
    rng = np.random.default_rng(seed)
    x = (0.2 * rng.standard_normal(int(sec * SR))).astype(np.float32)
    for k in range(5, int(sec), 6):
        x[int((k + 0.2) * SR):int((k + 0.9) * SR)] *= 0.001
    return x


def check_coverage(wins, n):
    """problems list; [] = every sample in exactly one window, contiguous, non-empty windows"""
    p = []
    if n == 0:
        return p if not wins else ["windows for empty audio"]
    if not wins:
        return ["no windows"]
    if wins[0][0] != 0:
        p.append("does not start at 0")
    if wins[-1][1] != n:
        p.append("does not end at n")
    for k, (a, b) in enumerate(wins):
        if b <= a:
            p.append("empty window %d" % k)
        if k and a != wins[k - 1][1]:
            p.append("gap/overlap at %d" % k)
    cover = np.zeros(n, dtype=np.int32)
    for a, b in wins:
        cover[a:b] += 1
    if not (cover == 1).all():
        p.append("coverage not exactly once")
    return p


# ---- K3-2 windows ---------------------------------------------------------------------------------------------------
print("-- windows")
x90 = signal_with_silences(90.0)
w90 = sa.plan_windows(x90, 30.0)
ok("K3-2 90 s signal -> every sample covered exactly once", check_coverage(w90, len(x90)) == [], check_coverage(w90, len(x90)))
ok("K3-2 90 s signal -> 3..4 windows, none longer than 30 s",
   3 <= len(w90) <= 4 and all((b - a) <= 30 * SR for a, b in w90), [(a / SR, b / SR) for a, b in w90])
req_ok, req_in_gap = True, True
for k in range(len(w90) - 1):
    req = w90[k][0] + 30 * SR
    cut = w90[k][1]
    if not (req - 3 * SR <= cut <= req):
        req_ok = False
    # the gaps are at 5.2-5.9, 11.2-11.9, ... -> the cut must fall into a quiet gap
    sec = cut / SR
    if not any(g + 0.2 <= sec <= g + 0.9 for g in range(5, 90, 6)):
        req_in_gap = False
ok("K3-2 every cut is within 3 s before the requested point", req_ok, [(a / SR, b / SR) for a, b in w90])
ok("K3-2 every cut sits in the quiet gap", req_in_gap, [b / SR for a, b in w90])
x_exact = signal_with_silences(60.0)
w_exact = sa.plan_windows(x_exact, 30.0)
ok("exactly 2 windows of audio -> last window is not empty and covered once",
   check_coverage(w_exact, len(x_exact)) == [] and len(w_exact) in (2, 3), w_exact)
ok("short audio (12 s) -> one window", sa.plan_windows(tone(12.0), 30.0) == [(0, 12 * SR)])
ok("audio of exactly one window -> one window", sa.plan_windows(tone(30.0), 30.0) == [(0, 30 * SR)])
ok("empty audio -> no windows", sa.plan_windows(np.zeros(0, dtype=np.float32), 30.0) == [])
ok("20 s CPU windows: 90 s signal covered exactly once",
   check_coverage(sa.plan_windows(x90, 20.0), len(x90)) == [])
rnd_ok = True
for seed, sec in [(2, 31.0), (3, 44.7), (4, 61.3), (5, 119.9), (6, 30.02), (7, 27.0)]:
    xx = signal_with_silences(sec, seed)
    if check_coverage(sa.plan_windows(xx, 30.0), len(xx)):
        rnd_ok = False
ok("random lengths 27..120 s: coverage exactly once", rnd_ok)
# the checker itself must fail on bad plans (deliberately wrong input)
ok("checker flags a gap", check_coverage([(0, 100), (200, len(x90))], len(x90)) != [])
ok("checker flags an overlap", check_coverage([(0, 100), (50, len(x90))], len(x90)) != [])
ok("checker flags a short plan", check_coverage([(0, 100)], len(x90)) != [])
ok("checker flags an empty window", check_coverage([(0, 0), (0, len(x90))], len(x90)) != [])
try:
    sa.plan_windows(x90, 3.0)
    ok("window_sec <= search_sec raises ValueError", False)
except ValueError:
    ok("window_sec <= search_sec raises ValueError", True)
# the quietest frame is chosen even when it is at the very beginning of the search range
xq = (0.2 * np.random.default_rng(9).standard_normal(70 * SR)).astype(np.float32)
xq[int(27.1 * SR):int(27.3 * SR)] = 0.0
wq = sa.plan_windows(xq, 30.0)
ok("quietest frame at the start of the search range is found", 27.1 <= wq[0][1] / SR <= 27.3, wq[0][1] / SR)
xq2 = (0.2 * np.random.default_rng(10).standard_normal(70 * SR)).astype(np.float32)
xq2[int(29.8 * SR):int(29.95 * SR)] = 0.0
ok("quietest frame at the end of the search range is found",
   abs(sa.plan_windows(xq2, 30.0)[0][1] / SR - 29.875) < 0.06)
xq3 = (0.2 * np.random.default_rng(11).standard_normal(70 * SR)).astype(np.float32)
xq3[int(10 * SR):int(10.5 * SR)] = 0.0     # quiet but outside the 3 s search range -> must not be chosen
ok("a quiet spot outside the search range is ignored", 27.0 <= sa.plan_windows(xq3, 30.0)[0][1] / SR <= 30.0)

# ---- transcription basics --------------------------------------------------------------------------------------------
print("-- transcribe_song")


def script_words(i, chunk, kw):
    return [SEG([W("hello%d" % i, 1.0, 1.4), W("world", 1.5, 2.0)])]


lock = threading.Lock()
fm = FakeModel(script_words, lock=lock)
res = sa.transcribe_song(x90, "en", fm, lock, window_sec=30.0)
ok("one model call per window", len(fm.calls) == res["windows"] == len(w90), (len(fm.calls), res["windows"]))
starts = [a / SR for a, b in w90]
exp = []
for (a, b) in w90:
    exp += [round(min(a / SR + 1.0, b / SR), 3), round(min(a / SR + 1.5, b / SR), 3)]   # clipped into the window
got = [w["s"] for w in res["words"]]
ok("window start offset is added to every word time", all(abs(g - e) < 0.002 for g, e in zip(got, exp)) and len(got) == len(exp), (got, exp))
ok("words are sorted and carry w/s/e/p", all(set(w) == {"w", "s", "e", "p"} for w in res["words"])
   and [w["s"] for w in res["words"]] == sorted(w["s"] for w in res["words"]))
ok("word text is stripped", res["words"][0]["w"] == "hello0")
ok("run lock held during each model call", all(fm.held_during_call), fm.held_during_call)
ok("run lock free after the run", lock.acquire(blocking=False) and (lock.release() or True))
kw = fm.calls[0]["kw"]
ok("settings: beam 5, temperature (0,0.2,0.4), word_timestamps, no previous text",
   kw["beam_size"] == 5 and kw["temperature"] == (0.0, 0.2, 0.4) and kw["word_timestamps"] is True
   and kw["condition_on_previous_text"] is False, kw)
ok("settings: thresholds 0.5 / 2.0 / 1.5, transcribe, language",
   kw["no_speech_threshold"] == 0.5 and kw["compression_ratio_threshold"] == 2.0
   and kw["hallucination_silence_threshold"] == 1.5 and kw["task"] == "transcribe" and kw["language"] == "en", kw)
ok("VAD off by default, prompt None by default", kw["vad_filter"] is False and kw["initial_prompt"] is None)
fm2 = FakeModel(script_words)
sa.transcribe_song(tone(5.0), "ja", fm2, vad=True)
ok("vad=True and language ja are passed through", fm2.calls[0]["kw"]["vad_filter"] is True and fm2.calls[0]["kw"]["language"] == "ja")
ok("result fields", set(res) >= {"words", "segments", "duration", "windows", "warnings", "timing"} and abs(res["duration"] - 90.0) < 0.01)
ok("segments carry text/s/e/p/n and no raw words", all(set(g) == {"text", "s", "e", "p", "n"} for g in res["segments"]))
ok("device chooses the window: cpu 20 s -> more windows than cuda 30 s",
   len(sa.plan_windows(x90, sa.window_for_device("cpu"))) > len(sa.plan_windows(x90, sa.window_for_device("cuda"))))

# silent windows are not sent to the model
xs = np.concatenate([tone(10.0), np.zeros(40 * SR, dtype=np.float32), tone(10.0)])
fm3 = FakeModel(script_words)
r3 = sa.transcribe_song(xs, "en", fm3, window_sec=20.0)
ok("silent windows are skipped (model not called) and counted", r3["timing"]["skipped_windows"] >= 1
   and len(fm3.calls) < r3["windows"], (len(fm3.calls), r3["windows"]))
ok("silent input only -> no words and no_vocals", sa.transcribe_song(np.zeros(20 * SR, dtype=np.float32), "en", FakeModel())["warnings"] == ["no_vocals"])
r_empty = sa.transcribe_song(np.zeros(0, dtype=np.float32), "en", FakeModel())
ok("empty audio -> no exception, no words, no_vocals", r_empty["words"] == [] and "no_vocals" in r_empty["warnings"] and r_empty["windows"] == 0)
r_nov = sa.transcribe_song(tone(8.0), "en", FakeModel(lambda i, c, k: []))
ok("model finds nothing -> no_vocals", r_nov["words"] == [] and r_nov["warnings"] == ["no_vocals"])
r_clip = sa.transcribe_song(tone(8.0), "en", FakeModel(lambda i, c, k: [SEG([W("late", 7.9, 12.0)]), SEG([W("neg", -1.0, 0.2)])]))
ok("word times are clipped into the window", r_clip["words"][-1]["e"] <= 8.0 + 1e-6 and r_clip["words"][0]["s"] >= 0.0, r_clip["words"])

# ---- hallucination removal (K3-4) ----------------------------------------------------------------------------------
print("-- hallucination")
rep = [SEG([W("thank", 1 + 3 * k, 1.5 + 3 * k), W("you", 1.6 + 3 * k, 2.0 + 3 * k)]) for k in range(5)]
r4 = sa.transcribe_song(tone(20.0), "en", FakeModel(lambda i, c, k: rep))
ok("K3-4 same line 5 times in a row -> 1 line + hallucination_cut",
   len(r4["segments"]) == 1 and "hallucination_cut" in r4["warnings"] and r4["segments"][0]["text"] == "thank you", r4["segments"])
ok("K3-4 the first one stays (earliest time)", abs(r4["segments"][0]["s"] - 1.0) < 0.01)
rep2 = rep[:2] + [SEG([W("other", 8, 8.5), W("words", 8.6, 9)])]
r5 = sa.transcribe_song(tone(20.0), "en", FakeModel(lambda i, c, k: rep2))
ok("same line only twice in a row -> both stay, no warning", len(r5["segments"]) == 3 and "hallucination_cut" not in r5["warnings"])
def mk(text, t):
    ws = text.split()
    return SEG([W(w, t + 0.4 * k, t + 0.4 * k + 0.3) for k, w in enumerate(ws)])


rep3 = [mk("thank you", 1), mk("thank you", 3), mk("thank you", 5), mk("x y", 8), mk("thank you", 11), mk("thank you", 13)]
r6 = sa.transcribe_song(tone(20.0), "en", FakeModel(lambda i, c, k: rep3))
ok("a run of 3 followed by another line, then 2 more -> only the first run is cut",
   [g["text"] for g in r6["segments"]] == ["thank you", "x y", "thank you", "thank you"], [g["text"] for g in r6["segments"]])
one_low = [SEG([W("hmm", 2.0, 2.4, p=0.2)])]
r7 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: one_low + [SEG([W("good", 5, 5.5), W("line", 5.6, 6.1, p=0.8)])]))
ok("K3-4 low-probability single-word line is dropped", [g["text"] for g in r7["segments"]] == ["good line"], r7["segments"])
r8 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [SEG([W("yeah", 2.0, 2.4, p=0.9)])] + [SEG([W("good", 5, 6.2), W("line", 6.3, 7.0)])]))
ok("a confident single-word line stays", [g["text"] for g in r8["segments"]] == ["yeah", "good line"])
r9 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [SEG([W("no", 2.0, 2.4, p=0.2), W("way", 2.5, 3.5, p=0.3)])]))
ok("a two-word line with low probability stays", len(r9["segments"]) == 1)
r10 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [SEG([W("m", 1, 1.1, p=0.1)]), SEG([W("m", 2, 2.1, p=0.1)]), SEG([W("m", 3, 3.1, p=0.1)])]))
ok("3 identical low-probability one-word lines -> cut then dropped, still warns", r10["segments"] == [] and "hallucination_cut" in r10["warnings"] and "no_vocals" in r10["warnings"], r10)
# repeats across a window boundary are consecutive lines too
def across(i, chunk, kw):
    return [SEG([W("la", 1.0, 1.5), W("la", 1.6, 2.0)], text="la la")] if i < 4 else []
r11 = sa.transcribe_song(signal_with_silences(100.0), "en", FakeModel(across), window_sec=30.0)
ok("the same line in 4 consecutive windows -> cut to one line", len(r11["segments"]) == 1 and "hallucination_cut" in r11["warnings"], r11["segments"])
# the cleaning function on its own with wrong input
segs_bad = [{"text": "a b", "words": [{"p": 0.9}, {"p": 0.9}]}] * 3
cs, cw = sa.clean_segments(segs_bad)
ok("clean_segments on 3 equal lines -> 1 + warning", len(cs) == 1 and cw == ["hallucination_cut"])
cs, cw = sa.clean_segments([{"text": "", "words": [{"p": 0.9}, {"p": 0.9}]}] * 4)
ok("empty-text lines are never treated as repeats", len(cs) == 4 and cw == [])

# music-noise lines flagged by the model's own no_speech_prob
def NSEG(words, nsp):
    sg = SEG(words)
    sg.no_speech_prob = nsp
    return sg


r_n1 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [NSEG([W("thanks", 1, 1.5, 0.6), W("watching", 1.6, 2.4, 0.6)], 0.95)]))
ok("short line with no_speech_prob 0.95 is dropped (music noise) -> no_vocals", r_n1["segments"] == [] and "no_vocals" in r_n1["warnings"], r_n1)
r_n2 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [NSEG([W("real", 1, 1.5), W("words", 1.6, 2.4)], 0.48), SEG([W("no", 4, 4.5), W("attr", 4.6, 5.2)])]))
ok("lines with no_speech_prob 0.48 or no attribute at all stay", len(r_n2["segments"]) == 2)
r_n3 = sa.transcribe_song(tone(10.0), "en", FakeModel(lambda i, c, k: [NSEG([W("w%d" % q, 1 + 0.5 * q, 1.4 + 0.5 * q) for q in range(10)], 0.95)]))
ok("a long line (>= 8 words) is kept even with a high no_speech_prob", len(r_n3["segments"]) == 1)
ok("no_speech_prob is not part of the result segments", all("nsp" not in g and "words" not in g for g in r_n2["segments"]))

# Japanese: readings in the context of the line
print("-- contextual readings")
_FULL = {"窓辺": "マドベ", "椅子": "イス", "歩数": "ホスー"}
_ONE = {"窓": "マド", "辺": "ヘン", "椅": "ハシ", "子": "コ", "歩": "フ", "数": "カズ", "の": "ノ", "で": "デ"}


def fake_reader(t):
    out, i = "", 0
    while i < len(t):
        for k in sorted(_FULL, key=len, reverse=True):
            if t.startswith(k, i):
                out += _FULL[k]
                i += len(k)
                break
        else:
            out += _ONE.get(t[i], "")
            i += 1
    return out


ks = sa.contextual_readings(["窓", "辺", "で"], fake_reader)
ok("contextual_readings: 辺 after 窓 reads ベ (not ヘン)", ks == ["マド", "ベ", "デ"], ks)
ok("contextual_readings: pieces add up to the reading of the whole line",
   "".join(sa.contextual_readings(["椅", "子", "の", "歩", "数"], fake_reader)) == fake_reader("椅子の歩数"))
ok("contextual_readings: alone the same pieces would be wrong (checks the fake)", fake_reader("辺") == "ヘン" and fake_reader("椅") == "ハシ")
ok("contextual_readings: punctuation gives an empty piece", sa.contextual_readings(["窓", "、", "辺"], fake_reader)[1] == "")
ok("contextual_readings: reader that raises does not break the line", sa.contextual_readings(["窓", "辺"], lambda t: 1 / 0) == ["", ""])
ok("contextual_readings: a reading that is not a continuation uses the part after the common prefix",
   sa.contextual_readings(["a", "b"], lambda t: {"a": "アイ", "ab": "アウエ"}[t]) == ["ア", "ウエ"])
import random as _rnd
_rr = _rnd.Random(5)
prop_ok = True
for _ in range(200):
    n_tok = _rr.randint(1, 7)
    table = {k: "".join(_rr.choice("アイウエオカキ") for _ in range(_rr.randint(0, 2 * k))) for k in range(1, n_tok + 1)}
    toks = [chr(0x3042 + q) for q in range(n_tok)]
    got = sa.contextual_readings(toks, lambda t: table[len(t)])
    if "".join(got) != table[n_tok] or len(got) != n_tok:
        prop_ok = False
ok("contextual_readings: pieces always add up to the reading of the whole line (200 random reading tables)", prop_ok)
rj = sa.transcribe_song(tone(8.0), "ja", FakeModel(lambda i, c, k: [SEG([W("窓", 1.0, 1.3), W("辺", 1.3, 1.6), W("で", 1.6, 1.9)])]), reader=fake_reader)
ok("transcribe_song(reader=...) adds 'k' to Japanese words", [w.get("k") for w in rj["words"]] == ["マド", "ベ", "デ"], rj["words"])
re_ = sa.transcribe_song(tone(8.0), "en", FakeModel(script_words), reader=fake_reader)
ok("English words never get 'k'", all("k" not in w for w in re_["words"]))
rn = sa.transcribe_song(tone(8.0), "ja", FakeModel(script_words))
ok("no reader -> no 'k'", all("k" not in w for w in rn["words"]))

# ---- hints ---------------------------------------------------------------------------------------------------------
print("-- hints")
lyr = ["the kettle hums while the morning climbs", "I count my steps to the old blue chair", "nobody calls so the quiet stays small"]
fmh = FakeModel(script_words)
sa.transcribe_song(signal_with_silences(70.0), "en", fmh, window_sec=30.0, hint_mode="first150", lyrics_lines=lyr)
prompts = [c["kw"]["initial_prompt"] for c in fmh.calls]
ok("first150: same prompt (the lyrics) in every window", len(set(prompts)) == 1 and prompts[0].startswith("the kettle hums"), prompts[:1])
long_lyr = [" ".join("w%d" % k for k in range(400))]
fml = FakeModel(script_words)
sa.transcribe_song(tone(10.0), "en", fml, hint_mode="first150", lyrics_lines=long_lyr)
ok("first150: at most 150 words", len(fml.calls[0]["kw"]["initial_prompt"].split()) == 150)
fmw = FakeModel(lambda i, c, k: [SEG([W("the", 1, 1.2), W("kettle", 1.3, 1.6), W("hums", 1.7, 2.0)])] if i == 0 else [SEG([W("I", 1, 1.2), W("count", 1.3, 1.6)])])
sa.transcribe_song(signal_with_silences(70.0), "en", fmw, window_sec=30.0, hint_mode="window30", lyrics_lines=lyr)
p0, p1 = fmw.calls[0]["kw"]["initial_prompt"], fmw.calls[1]["kw"]["initial_prompt"]
ok("window30: first window starts at the first lyric word", p0.startswith("the kettle hums") and len(p0.split()) <= 30, p0)
ok("window30: next window starts after the words that were matched", p1.startswith("while the morning"), p1)
p2 = fmw.calls[2]["kw"]["initial_prompt"] if len(fmw.calls) > 2 else ""
ok("window30: the pointer moves on with recognised lyric words", p2.startswith("my steps"), p2)
fmn = FakeModel(lambda i, c, k: [SEG([W("zzz", 1, 1.3), W("qqq", 1.4, 1.8)])])
sa.transcribe_song(signal_with_silences(70.0), "en", fmn, window_sec=30.0, hint_mode="window30", lyrics_lines=lyr)
ok("window30: unmatched words do not move the pointer", all(c["kw"]["initial_prompt"].startswith("the kettle hums") for c in fmn.calls))
fmj = FakeModel(script_words)
sa.transcribe_song(tone(5.0), "ja", fmj, hint_mode="window30", lyrics_lines=["朝の窓辺で小さなやかんが鳴る", "青い椅子まで"])
pj = fmj.calls[0]["kw"]["initial_prompt"]
ok("window30 Japanese: characters, no spaces, at most 30", pj.startswith("朝の窓辺") and " " not in pj and len(pj) <= 30, pj)
fm_none = FakeModel(script_words)
sa.transcribe_song(tone(5.0), "en", fm_none, hint_mode="window30", lyrics_lines=[])
ok("hint mode without lyrics -> no prompt", fm_none.calls[0]["kw"]["initial_prompt"] is None)
try:
    sa.transcribe_song(tone(5.0), "en", FakeModel(), hint_mode="bogus")
    ok("unknown hint_mode raises", False)
except ValueError:
    ok("unknown hint_mode raises", True)

# ---- progress / eta ------------------------------------------------------------------------------------------------
print("-- progress")
prog = []


def slow(i, chunk, kw):
    time.sleep(0.02)
    return [SEG([W("la", 1, 1.4), W("la", 1.5, 1.9)], text="la%d" % i)]


sa.transcribe_song(signal_with_silences(125.0), "en", FakeModel(slow), window_sec=30.0, progress=lambda d, t, e: prog.append((d, t, e)))
ok("progress called 0..N", prog[0][0] == 0 and prog[-1][0] == prog[-1][1] == len(prog) - 1, prog)
ok("eta is None until 2 windows are done, then a number", prog[0][2] is None and prog[1][2] is None
   and all(isinstance(p[2], float) for p in prog[2:]) and prog[-1][2] == 0.0, prog)
ok("eta shrinks as windows finish", all(prog[i][2] >= prog[i + 1][2] for i in range(2, len(prog) - 1)), prog)
lk2 = threading.Lock()
held_in_cb = []
sa.transcribe_song(signal_with_silences(70.0), "en", FakeModel(script_words), lk2, window_sec=30.0,
                   progress=lambda d, t, e: held_in_cb.append(lk2.locked()))
ok("run lock is NOT held while the progress callback runs (a /score can slip in between windows)", held_in_cb and not any(held_in_cb), held_in_cb)

# ---- cancel (K3-3) --------------------------------------------------------------------------------------------------
print("-- cancel")
flag = threading.Event()
lk3 = threading.Lock()
fmc = FakeModel(script_words, on_call=lambda i: flag.set() if i == 1 else None)
raised = False
try:
    sa.transcribe_song(signal_with_silences(125.0), "en", fmc, lk3, window_sec=30.0, cancel=flag)
except sa.Cancelled:
    raised = True
ok("K3-3 Cancelled raised after the flag is set during window 2", raised)
ok("K3-3 no window is started after the flag is set", len(fmc.calls) == 2, len(fmc.calls))
got_it = []
th = threading.Thread(target=lambda: got_it.append(lk3.acquire(timeout=0.5)))
th.start()
th.join()
ok("K3-3 the run lock is free right after Cancelled (another thread gets it at once)", got_it == [True])
if got_it and got_it[0]:
    lk3.release()
flag2 = threading.Event()
flag2.set()
fm_pre = FakeModel(script_words)
try:
    sa.transcribe_song(tone(10.0), "en", fm_pre, cancel=flag2)
    pre = False
except sa.Cancelled:
    pre = True
ok("a flag that is already set cancels before the first window", pre and not fm_pre.calls)
cnt = {"n": 0}
fm_fn = FakeModel(script_words)
try:
    sa.transcribe_song(signal_with_silences(125.0), "en", fm_fn, window_sec=30.0, cancel=lambda: (cnt.__setitem__("n", cnt["n"] + 1) or cnt["n"] > 3))
    fn_ok = False
except sa.Cancelled:
    fn_ok = True
ok("cancel may be a callable", fn_ok and len(fm_fn.calls) <= 2, len(fm_fn.calls))
fm_exc = FakeModel(lambda i, c, k: (_ for _ in ()).throw(RuntimeError("boom")))
lk4 = threading.Lock()
try:
    sa.transcribe_song(tone(10.0), "en", fm_exc, lk4)
except RuntimeError:
    pass
ok("a model exception also releases the run lock", lk4.acquire(blocking=False))
lk4.release()

# ---- config / source rules (K3-forbid) -----------------------------------------------------------------------------
print("-- config / source")
ok("pick_model_name: song.model wins", sa.pick_model_name({"stt": {"model": "small"}, "song": {"model": "medium"}}) == "medium")
ok("pick_model_name: falls back to stt.model", sa.pick_model_name({"stt": {"model": "small"}}) == "small")
ok("pick_model_name: wrong types fall back", sa.pick_model_name({"stt": {"model": "small"}, "song": {"model": 5}}) == "small"
   and sa.pick_model_name(None) == "small" and sa.pick_model_name({"song": {"model": "  "}}) == "small")
cfg = {"stt": {"model": "small"}}
sa.pick_model_name(cfg)
ok("pick_model_name does not write into the config", cfg == {"stt": {"model": "small"}})
src = open(os.path.join(HERE, "song_asr.py"), encoding="utf-8").read()
tree = ast.parse(src)
top_imports = set()
for node in tree.body:
    if isinstance(node, ast.Import):
        top_imports |= {a.name.split(".")[0] for a in node.names}
    elif isinstance(node, ast.ImportFrom):
        top_imports.add((node.module or "").split(".")[0])
ok("module-level imports: stdlib + numpy only (no faster_whisper / torch / server)",
   top_imports <= {"re", "threading", "time", "unicodedata", "numpy"}, top_imports)
ok("source does not import server and never calls save_config",
   not re.search(r"^\s*(import|from)\s+server", src, re.M) and "save_config" not in src)
ok("run lock is taken only in a `with lock:` around one model call", len(re.findall(r"with lock:", src)) == 1
   and src.count("model.transcribe(") == 1)
server_src = open(os.path.join(HERE, "server.py"), encoding="utf-8").read()
ok("server.py transcribe() still has the original call (not changed by K3)",
   "vad_filter=True, condition_on_previous_text=False" in server_src and "def transcribe(audio: np.ndarray, lang: str):" in server_src)

# ---- end ------------------------------------------------------------------------------------------------------------
ok("test file ran to the end", True)
print("== test_song_asr: %d passed, %d failed ==" % (len(PASSED), len(FAILED)))
if FAILED:
    print("FAILED:", FAILED)
sys.exit(1 if FAILED else 0)
