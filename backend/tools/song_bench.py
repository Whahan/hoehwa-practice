# -*- coding: utf-8 -*-
"""Song study S0 bench (K3): measures windowed Whisper transcription (song_asr) + alignment (song_align) on the
synthetic K6 songs. Standard library + numpy + faster-whisper; the Whisper model files are only READ.

  backend\\.venv\\Scripts\\python.exe -I backend\\tools\\song_bench.py selftest
  ... run    --gen DIR --truth DIR --out rows.jsonl [--langs en,ja] [--snr inf,10,5,0] [--formats wav]
             [--devices cuda,cpu] [--hints none,first150,window30] [--vad off,on] [--model small] [--limit N]
  ... long   --gen DIR --truth FILE --out rows.jsonl [--devices cuda,cpu] [--hint window30] [--snr inf,5]
  ... silent --work DIR --out rows.jsonl [--devices cuda]          (accompaniment only / silence / pure tone input)
  ... report --in rows.jsonl [--in more.jsonl]                    (markdown tables)
  ... near   --in rows.jsonl [--sim 300]                          (near on / off / time-consistent, real rows + simulation)

The model is loaded in this process with the same settings as server._load_whisper (no server, no port, nothing is
written into config.json). Each row of the .jsonl holds the inputs, timing and metrics and the recognised words.
"""
import argparse
import difflib
import glob
import json
import math
import os
import random
import statistics
import sys
import time
import unicodedata

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.normpath(os.path.join(HERE, ".."))
sys.path.insert(0, BACKEND)
import song_align as sal  # noqa: E402
import song_asr  # noqa: E402

COMPUTE = {"cuda": "int8_float16", "cpu": "int8"}      # same as server.py defaults / --stt-cpu
LINE_TOL = 0.5          # anchored word counts as correct if its time is within [t0 - 0.5, t1 + 0.5] of its own line


# =====================================================================================================================
# scoring helpers (tested by ``selftest`` with deliberately wrong input)
# =====================================================================================================================
def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (0 if x == y else 1)))
        prev = cur
    return prev[-1]


def error_rate(ref, hyp):
    """edit distance / len(ref); ref empty -> 0.0 if hyp is empty else 1.0"""
    if not ref:
        return 0.0 if not hyp else 1.0
    return edit_distance(ref, hyp) / float(len(ref))


def en_tokens(text):
    out = []
    for w in unicodedata.normalize("NFKC", text or "").lower().replace("'", "").split():
        w = "".join(c for c in w if c.isalnum())
        if w:
            out.append(w)
    return out


def ja_chars(text):
    return [c for c in unicodedata.normalize("NFKC", text or "") if unicodedata.category(c)[0] in "LN"]


def pctl(xs, q):
    if not xs:
        return None
    s = sorted(xs)
    k = (len(s) - 1) * q
    lo, hi = int(math.floor(k)), int(math.ceil(k))
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def line_errors(lines, truth_lines):
    """|t0 - truth t0| per line (by index). Lines missing on either side count as an error of +inf."""
    out = []
    for i, tl in enumerate(truth_lines):
        out.append(abs(lines[i]["t0"] - tl["t0"]) if i < len(lines) else float("inf"))
    return out


def anchor_accuracy(lines, truth_lines, tol=LINE_TOL):
    """(right, anchored): an anchored (est False) word is right when its start lies in its own truth line +-tol."""
    right = total = 0
    for i, ln in enumerate(lines):
        if i >= len(truth_lines):
            break
        tl = truth_lines[i]
        for w in ln.get("words", []):
            if w.get("est"):
                continue
            total += 1
            if tl["t0"] - tol <= w["s"] <= tl["t1"] + tol:
                right += 1
    return right, total


def foreign_segments(segments, lyric_text, lang):
    """segments (dicts with "text") with < 30 % of their words (characters for ja) found in the lyrics = hallucinations"""
    ja = lang.startswith("ja")
    vocab = set(ja_chars(lyric_text)) if ja else set(en_tokens(lyric_text))
    n = 0
    for sg in segments:
        units = ja_chars(sg["text"]) if ja else en_tokens(sg["text"])
        if not units:
            continue
        if sum(1 for u in units if u in vocab) / float(len(units)) < 0.3:
            n += 1
    return n


def stats(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return {"med": None, "p90": None, "max": None, "n": 0}
    return {"med": round(statistics.median(xs), 3), "p90": round(pctl(xs, 0.9), 3), "max": round(max(xs), 3), "n": len(xs)}


# =====================================================================================================================
# alignment variants: near ON (song_align as is) / OFF / time-consistent
# =====================================================================================================================
CONS_TOL_MIN = 1.5      # seconds
CONS_TOL_FRAC = 0.25    # of the gap between the two neighbouring exact anchors


def _align_dp_allowed(lk, ak, near, allowed):
    """Copy of song_align._align_dp (full table, no band) in which a "near" pairing (lyric index i, recognised index j,
    both 0-based) only scores when ``allowed(i, j)``. With allowed == always True it gives the same matches."""
    n, m = len(lk), len(ak)
    if n == 0 or m == 0:
        return []
    NEG = sal._NEG
    score = [[NEG] * (m + 1) for _ in range(n + 1)]
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for j in range(m + 1):
        score[0][j] = 0.0
        d[0][j] = 2
    for i in range(1, n + 1):
        score[i][0] = 0.0
        d[i][0] = 1
        a = lk[i - 1]
        nm = near.get(a) if near else None
        for j in range(1, m + 1):
            b = ak[j - 1]
            if a == b:
                sc = 2.0
            elif nm is not None and b in nm and allowed(i - 1, j - 1):
                sc = 1.0
            else:
                sc = sal._MISMATCH
            bv, bd = score[i - 1][j - 1] + sc, 0
            v = score[i - 1][j] - sal._GAP
            if v > bv:
                bv, bd = v, 1
            v = score[i][j - 1] - sal._GAP
            if v > bv:
                bv, bd = v, 2
            score[i][j] = bv
            d[i][j] = bd
    best = (NEG, 0, 0)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            if (j == m or i == n) and score[i][j] >= best[0]:
                best = (score[i][j], i, j)
    _, i, j = best
    if i == 0:
        return []
    out = []
    while i > 0 and j > 0:
        dd = d[i][j]
        if dd == 0:
            a, b = lk[i - 1], ak[j - 1]
            if a == b:
                out.append((i - 1, j - 1, 2))
            elif near and b in near.get(a, ()) and allowed(i - 1, j - 1):
                out.append((i - 1, j - 1, 1))
            i -= 1
            j -= 1
        elif dd == 1:
            i -= 1
        else:
            j -= 1
    out.reverse()
    return out


def _expected_times(weights, exact, asr, lang):
    """for every lyric unit: (expected recognised time, tolerance), interpolated between the neighbouring exact anchors
    exact = [(unit index, time)] sorted by index"""
    from bisect import bisect_left
    n = len(weights)
    cw = [0.0]
    for w in weights:
        cw.append(cw[-1] + w)
    mid = [(cw[i] + cw[i + 1]) / 2.0 for i in range(n)]
    total_w = cw[-1] or 1.0
    ex_i = [e[0] for e in exact]
    if len(exact) >= 2 and cw[exact[-1][0]] > cw[exact[0][0]]:
        rate = (exact[-1][1] - exact[0][1]) / (cw[exact[-1][0]] - cw[exact[0][0]])
    else:
        rate = sal._SEC_PER_WEIGHT["ja" if sal._is_ja(lang) else "en"]
    rate = max(rate, 1e-3)
    span = max(asr[-1]["e"] - asr[0]["s"], 1.0) if asr else 1.0
    t_lo = asr[0]["s"] if asr else 0.0
    exp, tol = [], []
    for i in range(n):
        q = bisect_left(ex_i, i)
        p = q - 1
        prev_e = exact[p] if p >= 0 else None
        next_e = exact[q] if q < len(exact) else None
        if prev_e and next_e and cw[next_e[0]] > cw[prev_e[0]]:
            cp, cq = cw[prev_e[0]], cw[next_e[0]]
            e = prev_e[1] + (mid[i] - cp) / (cq - cp) * (next_e[1] - prev_e[1])
            t = max(CONS_TOL_MIN, CONS_TOL_FRAC * (next_e[1] - prev_e[1]))
        elif prev_e or next_e:
            ref = prev_e or next_e
            e = ref[1] + (mid[i] - cw[ref[0]]) * rate
            t = max(2.0, 0.35 * abs(e - ref[1]))
        else:
            e = t_lo + mid[i] / total_w * span
            t = max(3.0, 0.2 * span)
        exp.append(e)
        tol.append(t)
    return exp, tol


def align_variant(lyrics, asr_words, duration, lang, reader, near):
    """near = "on" (song_align.align_lyrics unchanged), "off" (no near matches), "cons" (near only when consistent)."""
    if near == "on":
        return sal.align_lyrics(lyrics, asr_words, duration, lang, reader)
    if near == "off":
        old = sal.NEAR_RATIO
        sal.NEAR_RATIO = 2.0
        try:
            return sal.align_lyrics(lyrics, asr_words, duration, lang, reader)
        finally:
            sal.NEAR_RATIO = old
    if near != "cons":
        raise ValueError(near)
    # copy of song_align.align_lyrics with one extra step (the consistency filter) after the DP
    recs, warns = sal._prepare_lyrics(lyrics, lang, reader)
    raw_end = sal._raw_end(asr_words)
    dur = sal._duration(duration, raw_end)
    asr = sal.sanitize_asr(asr_words, dur, lang, reader)
    if not recs:
        return {"lines": [], "match_rate": 0.0, "anchored": 0, "total": 0, "line_match": [], "timing": "est", "warnings": warns}
    keys, weights, real, spans, line_range = sal._build_units(recs, lang)
    au = sal._asr_units(asr, lang)
    ak = [u[0] for u in au]
    ja = sal._is_ja(lang)
    nearm = {} if ja else sal._near_map(keys, ak)
    if ja or not nearm:
        matches = sal._align_dp(keys, ak, nearm)
    else:
        # pass 1: exact anchors only -> expected time (+ tolerance) of every lyric unit; pass 2: near pairs only where
        # the recognised time agrees with that expectation
        first = _align_dp_allowed(keys, ak, nearm, lambda i, j: False)
        exp, tol = _expected_times(weights, [(i, au[j][1]) for i, j, k in first if k == 2], asr, lang)
        matches = _align_dp_allowed(keys, ak, nearm, lambda i, j: abs(au[j][1] - exp[i]) <= tol[i])
    matches = sal._filter_runs(matches, sal.JA_MIN_RUN if ja else 1)
    anchors = {i: (au[j][1], au[j][2]) for i, j, _ in matches}
    anchored = [i in anchors for i in range(len(keys))]
    total = sum(real)
    hit = sum(1 for i in anchors if real[i])
    rate = hit / total if total else 0.0
    if anchors:
        span_lo, span_hi = 0.0, dur
    elif asr:
        span_lo, span_hi = asr[0]["s"], asr[-1]["e"]
    else:
        span_lo, span_hi = 0.0, dur
    times = sal._place(weights, anchors, span_lo, span_hi, dur)
    lines = sal._finalize(recs, spans, line_range, times, anchored, dur, lambda li: {})
    for ln in lines:
        ln["est"] = ln["est"] or all(w["est"] for w in ln["words"])
    if not asr and "no_vocals" not in warns:
        warns.append("no_vocals")
    if rate < sal.LOW_MATCH:
        for w in ("low_match", "est_times"):
            if w not in warns:
                warns.append(w)
    return {"lines": lines, "match_rate": round(rate, 4), "anchored": hit, "total": total, "line_match": [],
            "timing": "word" if rate >= sal.LOW_MATCH else "est", "warnings": warns}


def align_metrics(res, truth_lines):
    errs = line_errors(res["lines"], truth_lines)
    right, tot = anchor_accuracy(res["lines"], truth_lines)
    fin = [e for e in errs if e != float("inf")]
    return {"match_rate": res["match_rate"], "low_match": "low_match" in res["warnings"],
            "anchored_words": tot, "anchor_acc": round(right / tot, 4) if tot else None, "wrong_anchors": tot - right,
            "line_err_med": None if not fin else round(statistics.median(fin), 3),
            "line_err_p90": None if not fin else round(pctl(fin, 0.9), 3),
            "line_err_max": None if not fin else round(max(fin), 3), "lines_missing": len(errs) - len(fin),
            "warnings": res["warnings"]}


# =====================================================================================================================
# S0 verdicts (design 8): kept as a function so selftest can feed it failing rows
# =====================================================================================================================
def verdict(rows_by_lang):
    """rows_by_lang: {"en"/"ja": {"lyrics": row, "nolyrics": row}, "silent": row, "long": row}; None = missing -> "미검증"."""
    out = {}
    for lg in ("en", "ja"):
        r = (rows_by_lang.get(lg) or {}).get("lyrics")
        if r is None:
            out["S0-2 " + lg] = "미검증"
        else:
            a = r["align"]["on"]
            out["S0-2 " + lg] = "O" if (a["match_rate"] >= 0.85 and a["line_err_med"] is not None and a["line_err_med"] <= 0.35
                                       and a["line_err_p90"] <= 1.0) else "X"
        r = (rows_by_lang.get(lg) or {}).get("nolyrics")
        if r is None:
            out["S0-3 " + lg] = "미검증"
        else:
            out["S0-3 " + lg] = "O" if r["err"] <= (0.25 if lg == "en" else 0.30) else "X"
    r = rows_by_lang.get("silent")
    out["S0-4"] = "미검증" if r is None else ("O" if (r["asr_lines"] <= 1 and "no_vocals" in r["warnings"]) else "X")
    r = rows_by_lang.get("long")
    out["S0-5"] = "미검증" if r is None else ("O" if r["proc_sec"] <= 90.0 else "X")
    return out


# =====================================================================================================================
# running
# =====================================================================================================================
def load_truth(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def make_reader():
    import pyopenjtalk

    def reader(text):
        t = unicodedata.normalize("NFKC", text or "")
        if not t.strip():
            return ""
        return "".join(c for c in pyopenjtalk.g2p(t, kana=True) if "ァ" <= c <= "ヶ" or c == "ー")
    return reader


def kana_passthrough(reader):
    """reader that leaves an all-katakana string alone (the recognised words already are readings) and reads the rest"""
    def r(text):
        t = text or ""
        if t and all(("ァ" <= c <= "ヶ") or c == "ー" for c in t):
            return t
        return reader(t)
    return r


class Models:
    """one WhisperModel per (name, device), loaded on first use; load time is remembered"""

    def __init__(self, root):
        self.root = root
        self.cache = {}
        self.load_sec = {}

    def get(self, name, device):
        key = (name, device)
        if key not in self.cache:
            t0 = time.time()
            m = song_asr.load_whisper(name, device, COMPUTE[device], self.root)
            import numpy as np
            list(m.transcribe(np.zeros(16000, dtype="float32"), language="en", beam_size=1)[0])   # warm-up (CUDA init)
            self.cache[key] = m
            self.load_sec[key] = round(time.time() - t0, 2)
            print("  [model] %s on %s/%s loaded in %.1fs" % (name, device, COMPUTE[device], self.load_sec[key]), flush=True)
        return self.cache[key]


def default_model_root():
    for base in (os.path.join(BACKEND, "models", "hf", "whisper"),
                 os.path.join("D:\\", "Ai", "언어", "app", "backend", "models", "hf", "whisper")):
        if os.path.isdir(base):
            return base
    raise SystemExit("no Whisper model folder found (use --model-root)")


def score_asr(res, lang, truth, reader):
    """metrics of a transcription against the truth lyrics (no alignment)"""
    ref_text = " ".join(l["text"] for l in truth["lines"])
    hyp_text = ("" if lang == "ja" else " ").join(s["text"] for s in res["segments"])
    out = {}
    if lang == "ja":
        out["err"] = round(error_rate(ja_chars(ref_text), ja_chars(hyp_text)), 4)       # raw character error rate
        if reader:
            out["err_kana"] = round(error_rate(ja_chars(reader(ref_text)), ja_chars(reader(hyp_text))), 4)
    else:
        out["err"] = round(error_rate(en_tokens(ref_text), en_tokens(hyp_text)), 4)     # word error rate
    out["hyp_text"] = hyp_text
    out["foreign_lines"] = foreign_segments(res["segments"], ref_text, lang)
    return out


def run_one(models, audio, dur, lang, truth, model_name, device, hint, vad, reader, near_modes=("on", "off", "cons")):
    lyrics_lines = [l["text"] for l in truth["lines"]]
    model = models.get(model_name, device)
    res = song_asr.transcribe_song(audio, lang, model, None, device=device, hint_mode=hint, lyrics_lines=lyrics_lines, vad=vad,
                                   reader=reader if lang == "ja" else None)
    row = {"model": model_name, "device": device, "compute": COMPUTE[device], "hint": hint, "vad": vad,
           "dur": round(dur, 3), "asr_sec": res["timing"]["asr_sec"], "windows": res["windows"],
           "skipped_windows": res["timing"]["skipped_windows"], "asr_warnings": res["warnings"],
           "n_words": len(res["words"]), "n_segments": len(res["segments"])}
    row["asr_ratio"] = round(row["asr_sec"] / dur, 4) if dur else None
    row.update(score_asr(res, lang, truth, reader))
    # no-lyrics path: lines made from the recognised words
    t0 = time.time()
    al = sal.lines_from_asr(res["words"], dur, lang)
    row["asr_lines"] = len(al["lines"])
    row["asr_lines_warnings"] = al["warnings"]
    near_t = [min((abs(l["t0"] - tl["t0"]) for l in al["lines"]), default=float("inf")) for tl in truth["lines"]]
    fin = [x for x in near_t if x != float("inf")]
    row["nolyric_line_err_med"] = round(statistics.median(fin), 3) if fin else None
    # with-lyrics path
    lyr = [{"text": t, "p": truth["lines"][i].get("p", 0)} for i, t in enumerate(lyrics_lines)]
    row["align"] = {}
    for nm in near_modes:
        t1 = time.time()
        ar = align_variant(lyr, res["words"], dur, lang, reader if lang == "ja" else None, nm)
        row["align"][nm] = align_metrics(ar, truth["lines"])
        row["align"][nm]["sec"] = round(time.time() - t1, 3)
    if lang == "ja":
        # Japanese with the reading of each recognised word taken in the context of its line (song_asr "k")
        kw = [{"w": x["k"], "s": x["s"], "e": x["e"], "p": x["p"]} for x in res["words"] if x.get("k")]
        t1 = time.time()
        ar = sal.align_lyrics(lyr, kw, dur, lang, kana_passthrough(reader))
        row["align_ctx"] = align_metrics(ar, truth["lines"])
        row["align_ctx"]["sec"] = round(time.time() - t1, 3)
    row["align_sec"] = row["align"]["on"]["sec"]
    row["proc_sec"] = round(row["asr_sec"] + row["align_sec"], 3)
    row["words"] = [[w["w"], w["s"], w["e"], w["p"], w.get("k")] for w in res["words"]]
    return row


def snr_list(s):
    return [x.strip() for x in s.split(",") if x.strip()]


def cmd_run(a):
    import numpy as np  # noqa: F401
    models = Models(a.model_root or default_model_root())
    reader = make_reader()
    rows = []
    n = 0
    with open(a.out, "w", encoding="utf-8") as fo:
        for device in a.devices.split(","):
            for lang in a.langs.split(","):
                truth = load_truth(os.path.join(a.truth, "song_%s.truth.json" % lang))
                for fmt in a.formats.split(","):
                    for snr in snr_list(a.snr):
                        path = os.path.join(a.gen, "song_%s_snr%s.%s" % (lang, snr, fmt))
                        if not os.path.isfile(path):
                            print("  missing", path)
                            continue
                        t0 = time.time()
                        audio = song_asr.decode_file(path)
                        dec = time.time() - t0
                        dur = len(audio) / 16000.0
                        for hint in a.hints.split(","):
                            for vad in [v == "on" for v in a.vad.split(",")]:
                                if a.limit and n >= a.limit:
                                    break
                                row = run_one(models, audio, dur, lang, truth, a.model, device, hint, vad, reader)
                                row.update({"song": "song_" + lang, "lang": lang, "snr": snr, "fmt": fmt, "decode_sec": round(dec, 3)})
                                fo.write(json.dumps(row, ensure_ascii=False) + "\n")
                                fo.flush()
                                rows.append(row)
                                n += 1
                                al = row["align"]["on"]
                                print("%-4s %s %-3s snr%-3s %-4s hint=%-8s vad=%-5s asr %5.1fs (x%.3f) err %.2f match %.2f line_med %s" % (
                                    device, lang, fmt, snr, "", hint, vad, row["asr_sec"], row["asr_ratio"], row["err"],
                                    al["match_rate"], al["line_err_med"]), flush=True)
    print("rows:", len(rows), "->", a.out)


def cmd_long(a):
    models = Models(a.model_root or default_model_root())
    reader = make_reader()
    truth = load_truth(a.truth)
    lang = truth["lang"]
    with open(a.out, "w", encoding="utf-8") as fo:
        for device in a.devices.split(","):
            for snr in snr_list(a.snr):
                path = os.path.join(a.gen, "%s_snr%s.mp3" % (truth["id"], snr))
                t0 = time.time()
                audio = song_asr.decode_file(path)
                dec = time.time() - t0
                dur = len(audio) / 16000.0
                models.get(a.model, device)
                row = run_one(models, audio, dur, lang, truth, a.model, device, a.hint, False, reader)
                row.update({"song": truth["id"], "lang": lang, "snr": snr, "fmt": "mp3", "decode_sec": round(dec, 3),
                            "model_load_sec": models.load_sec.get((a.model, device))})
                fo.write(json.dumps(row, ensure_ascii=False) + "\n")
                fo.flush()
                al = row["align"]["on"]
                print("%s %s snr%s dur %.1fs: decode %.1fs asr %.1fs align %.2fs total %.1fs (x%.3f of the song) err %.3f match %.3f line_med %s p90 %s" % (
                    device, truth["id"], snr, dur, dec, row["asr_sec"], row["align_sec"], row["proc_sec"], row["proc_sec"] / dur,
                    row["err"], al["match_rate"], al["line_err_med"], al["line_err_p90"]), flush=True)


def cmd_silent(a):
    """accompaniment only (K6's backing generator, no voice), digital silence, and a pure tone: no lines expected"""
    import importlib.util
    import numpy as np
    spec = importlib.util.spec_from_file_location("make_song_fixtures", os.path.join(HERE, "make_song_fixtures.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    os.makedirs(a.work, exist_ok=True)
    inputs = {}
    for name, secs, seed in (("backing_en", 20.69, 6001), ("backing_ja", 16.66, 6002)):
        n = int(secs * mod.SR)
        x = mod.make_backing(n, mod.SR, seed)
        pcm = mod.to_int16(x)
        p = os.path.join(a.work, name + ".wav")
        mod.write_audio(p, pcm, mod.SR, "wav")
        inputs[name] = p
    if a.tone and os.path.isfile(a.tone):
        inputs["tone_8s"] = a.tone
    models = Models(a.model_root or default_model_root())
    rows = []
    lyr = {}
    for lg in ("en", "ja"):
        tp = os.path.join(a.truth, "song_%s.truth.json" % lg)
        lyr[lg] = [l["text"] for l in load_truth(tp)["lines"]] if os.path.isfile(tp) else []
    with open(a.out, "w", encoding="utf-8") as fo:
        for device in a.devices.split(","):
            model = models.get(a.model, device)
            for lang in ("en", "ja"):
                for name, p in inputs.items():
                    audio = song_asr.decode_file(p)
                    dur = len(audio) / 16000.0
                    for hint in ("none", "first150", "window30"):
                        for vad in (False, True):
                            if hint != "none" and not lyr[lang]:
                                continue
                            res = song_asr.transcribe_song(audio, lang, model, None, device=device, hint_mode=hint,
                                                           lyrics_lines=lyr[lang], vad=vad)
                            al = sal.lines_from_asr(res["words"], dur, lang)
                            warns = sorted(set(res["warnings"]) | set(al["warnings"]))
                            row = {"input": name, "lang": lang, "device": device, "hint": hint, "vad": vad, "dur": round(dur, 2),
                                   "asr_sec": res["timing"]["asr_sec"], "n_words": len(res["words"]), "asr_lines": len(al["lines"]),
                                   "warnings": warns, "text": " | ".join(l["text"] for l in al["lines"])[:200]}
                            rows.append(row)
                            fo.write(json.dumps(row, ensure_ascii=False) + "\n")
                            print("%s %-11s lang=%s hint=%-8s vad=%-5s words=%d lines=%d warnings=%s %s" % (
                                device, name, lang, hint, vad, row["n_words"], row["asr_lines"], warns, row["text"][:60]))
    return rows


def cmd_wrong(a):
    """F6: lyrics that do not belong to the song -> match rate < 0.15 and low_match"""
    models = Models(a.model_root or default_model_root())
    reader = make_reader()
    wrong = {"en": SIM_SONGS[0][:6],
             "ja": ["夜の海辺で静かな風が吹く", "遠い星まで手紙を送ろう", "", "季節がめぐる街の灯り", "猫は窓辺でまるくなる"]}
    with open(a.out, "w", encoding="utf-8") as fo:
        for device in a.devices.split(","):
            model = models.get(a.model, device)
            for lang in ("en", "ja"):
                path = os.path.join(a.gen, "song_%s_snr5.wav" % lang)
                audio = song_asr.decode_file(path)
                dur = len(audio) / 16000.0
                lines = [x for x in wrong[lang] if x]
                for hint in ("none", "first150"):
                    res = song_asr.transcribe_song(audio, lang, model, None, device=device, hint_mode=hint, lyrics_lines=lines)
                    for nm in ("on", "off", "cons"):
                        ar = align_variant([{"text": x} for x in lines], res["words"], dur, lang, reader if lang == "ja" else None, nm)
                        row = {"lang": lang, "device": device, "hint": hint, "near": nm, "match_rate": ar["match_rate"],
                               "warnings": ar["warnings"], "all_est": all(l["est"] for l in ar["lines"])}
                        fo.write(json.dumps(row, ensure_ascii=False) + "\n")
                        print("%s %s hint=%-8s near=%-4s match %.3f est-all=%s warnings=%s" % (
                            device, lang, hint, nm, row["match_rate"], row["all_est"], row["warnings"]))


# ---- simulation for the near comparison -------------------------------------------------------------------------------
SIM_SONGS = [
    # hand-written for this test (CC0), rhyme-rich on purpose; not real songs
    ["I walk alone tonight", "under the pale moonlight", "nothing here feels right", "I hold on with all my might",
     "you said we would be fine", "I counted every sign", "now I stand in line", "hoping that you are mine",
     "the night is long and cold", "the stories all are old", "the hands I used to hold", "have turned to dust and gold",
     "so I sing it out tonight", "let the morning bring the light", "if the end is out of sight", "I will stay and fight"],
    ["the river runs so slow", "where the tall grass seems to grow", "I watched the lanterns glow", "in the dark with nowhere to go",
     "we carried every stone", "we never walked alone", "and the wind has always known", "where the seeds of hope were sown",
     "bring the summer rain", "wash away the pain", "I will meet you once again", "down the quiet lane",
     "count the stars with me", "as far as we can see", "set the old ship free", "over the open sea"],
    ["morning on the street", "I can hear a drumbeat", "dancing on my feet", "no time to take a seat",
     "turn the radio up high", "watch the clouds go by", "we can touch the sky", "you and I",
     "hold the golden light", "keep the dream in sight", "say it is all right", "we will be alright tonight",
     "love is all around", "feel the shaking ground", "hear the joyful sound", "lost and then found"],
]
RHYME_POOL = [["night", "light", "right", "might", "tight", "sight", "fight", "bright"],
              ["line", "mine", "fine", "sign", "shine", "wine"], ["old", "cold", "hold", "gold", "told", "bold"],
              ["glow", "slow", "go", "know", "grow", "sown", "stone", "alone"], ["rain", "pain", "again", "lane", "plain"],
              ["see", "free", "me", "sea", "key"], ["street", "beat", "feet", "seat", "heat"],
              ["high", "by", "sky", "eye", "I"], ["round", "ground", "sound", "found"]]


def _variants(w):
    """realistic misrecognitions of a word: other inflection / one letter changed"""
    out = []
    if len(w) > 3:
        out.append(w[:-1])
    out += [w + "s", w + "ed", w + "ing"]
    if len(w) > 3:
        out.append(w[:-1] + ("e" if w[-1] != "e" else "a"))
    return out


def sim_asr(lyrics, rng, miss, garble_rhyme, morph, drop_line):
    asr, truth = [], []
    t = 10.0
    for li, line in enumerate(lyrics):
        ws = line.split()
        t0 = t
        s = t
        for k, w in enumerate(ws):
            if k:
                s += rng.uniform(0.25, 0.9)          # irregular word spacing (singing is not metronomic)
            if rng.random() < miss or rng.random() < drop_line:
                continue
            ww = w.lower()
            r = rng.random()
            if r < garble_rhyme:
                pool = next((p for p in RHYME_POOL if ww in p), None)
                if pool:
                    ww = rng.choice([x for x in pool if x != ww] or [ww])
            elif r < garble_rhyme + morph:
                ww = rng.choice(_variants(ww))
            asr.append({"w": ww, "s": round(s, 3), "e": round(s + 0.4, 3), "p": 0.9})
        truth.append({"t0": t0, "t1": s + 0.4})
        t = s + 0.4 + rng.uniform(1.0, 3.5)           # irregular gaps between lines
    return asr, truth, t + 4.0


def cmd_near(a):
    out = {}
    # (1) real rows
    rows = []
    for p in a.inp or []:
        with open(p, encoding="utf-8") as f:
            rows += [json.loads(x) for x in f if x.strip()]
    en_rows = [r for r in rows if r["lang"] == "en"]
    if en_rows:
        out["real_en"] = _agg_near([r["align"] for r in en_rows], len(en_rows))
    # (2) simulation (English, own rhyme-rich lyrics)
    scen = {"rhyme_garble (20% rhyme words swapped, 30% missed)": (0.30, 0.20, 0.0, 0.0),
            "morph (25% inflection errors, 20% missed)": (0.20, 0.0, 0.25, 0.0),
            "mixed (rhyme 15%, morph 15%, 30% missed, 10% lines lost)": (0.30, 0.15, 0.15, 0.10),
            "sparse (60% missed, rhyme 10%, morph 10%)": (0.60, 0.10, 0.10, 0.0),
            "very sparse (85% missed, rhyme 40% of the rest)": (0.85, 0.40, 0.0, 0.0),
            "half the lines lost + rhyme 20%": (0.20, 0.20, 0.0, 0.50),
            "clean (5% missed)": (0.05, 0.0, 0.0, 0.0)}
    for name, (miss, g, m, d) in (scen.items() if a.sim > 0 else []):
        per = {"on": [], "off": [], "cons": []}
        rng = random.Random(a.seed)
        for k in range(a.sim):
            lyrics = SIM_SONGS[k % len(SIM_SONGS)]
            asr, truth_lines, dur = sim_asr(lyrics, rng, miss, g, m, d)
            lyr = [{"text": x} for x in lyrics]
            for nm in per:
                r = align_variant(lyr, asr, dur, "en", None, nm)
                per[nm].append(align_metrics(r, truth_lines))
        out["sim: " + name] = {nm: _agg_one(v) for nm, v in per.items()}
    return out


def _agg_one(ms):
    tot = sum(m["anchored_words"] for m in ms)
    wrong = sum(m["wrong_anchors"] for m in ms)
    meds = [m["line_err_med"] for m in ms if m["line_err_med"] is not None]
    p90s = [m["line_err_p90"] for m in ms if m["line_err_p90"] is not None]
    return {"n": len(ms), "match_rate": round(statistics.mean(m["match_rate"] for m in ms), 4),
            "anchor_acc": round(1 - wrong / tot, 4) if tot else None, "wrong_anchors": wrong, "anchored": tot,
            "low_match_pct": round(100.0 * sum(1 for m in ms if m["low_match"]) / len(ms), 1),
            "line_err_med": round(statistics.mean(meds), 3) if meds else None,
            "line_err_p90": round(statistics.mean(p90s), 3) if p90s else None}


def _agg_near(aligns, n):
    return {nm: _agg_one([al[nm] for al in aligns]) for nm in ("on", "off", "cons")}


# ---- report -------------------------------------------------------------------------------------------------------------
def _f(x, nd=3):
    return "-" if x is None else ("%.*f" % (nd, x))


def cmd_report(a):
    rows = []
    for p in a.inp:
        with open(p, encoding="utf-8") as f:
            rows += [json.loads(x) for x in f if x.strip()]
    print("| device | lang | snr | fmt | hint | vad | asr s | x song | err | match | line med | line p90 | anchor acc | foreign | lines(no lyr) | warn |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        al = r["align"]["on"]
        print("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["device"], r["lang"], r["snr"], r["fmt"], r["hint"], "on" if r["vad"] else "off", _f(r["asr_sec"], 1), _f(r["asr_ratio"], 3),
            _f(r["err"], 2), _f(al["match_rate"], 2), _f(al["line_err_med"], 2), _f(al["line_err_p90"], 2), _f(al["anchor_acc"], 2),
            r["foreign_lines"], r["asr_lines"], ",".join(r["asr_warnings"]) or "-"))


# =====================================================================================================================
# selftest: the scorers and verdicts must FAIL on deliberately wrong input
# =====================================================================================================================
def cmd_selftest():
    bad = []

    def check(name, cond, detail=""):
        print("  [%s] %s" % ("PASS" if cond else "FAIL", name))
        if not cond:
            bad.append(name)

    check("edit distance kitten/sitting = 3", edit_distance(list("kitten"), list("sitting")) == 3)
    check("WER identical = 0", error_rate(en_tokens("The kettle hums"), en_tokens("the KETTLE hums!")) == 0.0)
    check("WER unrelated = 1", error_rate(en_tokens("a b c d"), en_tokens("w x y z")) == 1.0)
    check("WER one deletion of 4 = 0.25", abs(error_rate(en_tokens("a b c d"), en_tokens("a b c")) - 0.25) < 1e-9)
    check("WER empty hyp = 1", error_rate(en_tokens("a b"), []) == 1.0)
    check("CER ja identical = 0", error_rate(ja_chars("朝の窓辺、で"), ja_chars("朝の窓辺で")) == 0.0)
    check("CER ja half wrong = 0.5", abs(error_rate(ja_chars("あいうえ"), ja_chars("あいかき")) - 0.5) < 1e-9)
    truth = [{"t0": 1.0, "t1": 3.0}, {"t0": 5.0, "t1": 7.0}]
    good = [{"t0": 1.1, "words": [{"s": 1.1, "est": False}, {"s": 2.0, "est": False}]},
            {"t0": 5.2, "words": [{"s": 5.2, "est": False}]}]
    check("line errors small for right lines", max(line_errors(good, truth)) < 0.25)
    shifted = [{"t0": 3.0, "words": []}, {"t0": 9.0, "words": []}]
    check("line errors large for shifted lines", min(line_errors(shifted, truth)) >= 2.0)
    check("missing line = inf", line_errors(good[:1], truth)[1] == float("inf"))
    check("anchor_accuracy: all right", anchor_accuracy(good, truth) == (3, 3))
    wrong = [{"t0": 1.0, "words": [{"s": 5.5, "est": False}, {"s": 2.0, "est": False}]}, {"t0": 5.0, "words": [{"s": 1.0, "est": True}]}]
    check("anchor_accuracy: wrong word time is counted, est words are ignored", anchor_accuracy(wrong, truth) == (1, 2))
    segs = [{"text": "the kettle hums"}, {"text": "thanks for watching"}, {"text": "subscribe now please"}]
    check("foreign_segments finds 2 hallucinated lines", foreign_segments(segs, "The kettle hums while", "en") == 2)
    check("foreign_segments on ja characters", foreign_segments([{"text": "朝の窓"}, {"text": "字幕作成"}], "朝の窓辺で", "ja") == 1)
    check("pctl p90 of 1..10 = 9.1", abs(pctl(list(range(1, 11)), 0.9) - 9.1) < 1e-9)
    # verdicts: good rows -> O, bad rows -> X, missing -> 미검증
    good_row = {"align": {"on": {"match_rate": 0.9, "line_err_med": 0.2, "line_err_p90": 0.6}}, "err": 0.1}
    bad_row = {"align": {"on": {"match_rate": 0.5, "line_err_med": 0.9, "line_err_p90": 2.0}}, "err": 0.6}
    v = verdict({"en": {"lyrics": good_row, "nolyrics": good_row}, "ja": {"lyrics": bad_row, "nolyrics": bad_row},
                 "silent": {"asr_lines": 0, "warnings": ["no_vocals"]}, "long": {"proc_sec": 50.0}})
    check("verdict: good rows O", v["S0-2 en"] == "O" and v["S0-3 en"] == "O" and v["S0-4"] == "O" and v["S0-5"] == "O")
    check("verdict: bad rows X", v["S0-2 ja"] == "X" and v["S0-3 ja"] == "X")
    v2 = verdict({"silent": {"asr_lines": 3, "warnings": []}, "long": {"proc_sec": 120.0}})
    check("verdict: noisy silent input and slow long song X", v2["S0-4"] == "X" and v2["S0-5"] == "X")
    check("verdict: nothing measured -> 미검증", set(verdict({}).values()) == {"미검증"})
    # near variants: ON must equal song_align itself; OFF must differ on a rhyme case; CONS rejects the rhyme anchor
    lyr = [{"text": t} for t in ["the night is bright and long", "I see the light", "you hold me tight", "we fight the fright", "and sleep till the sight"]]
    asr = [{"w": "night", "s": 13.0, "e": 13.4}, {"w": "light", "s": 15.0, "e": 15.4}, {"w": "right", "s": 19.0, "e": 19.4}]
    on = align_variant(lyr, asr, 40.0, "en", None, "on")
    ref = sal.align_lyrics(lyr, asr, 40.0, "en", None)
    check("near ON == song_align.align_lyrics", on["lines"] == ref["lines"] and on["match_rate"] == ref["match_rate"])
    off = align_variant(lyr, asr, 40.0, "en", None, "off")
    tl = [{"t0": 10, "t1": 13.5}, {"t0": 14, "t1": 16}, {"t0": 18, "t1": 20}, {"t0": 22, "t1": 24}, {"t0": 26, "t1": 28}]
    m_on, m_off = align_metrics(on, tl), align_metrics(off, tl)
    check("rhyme case: ON line error is larger than OFF (the reviewer's night/light/right problem)",
          m_on["line_err_med"] > m_off["line_err_med"] + 1.0, (m_on["line_err_med"], m_off["line_err_med"]))
    cons = align_variant(lyr, asr, 40.0, "en", None, "cons")
    check("rhyme case: CONS gives the OFF result (rhyme anchor rejected)", cons["lines"] == off["lines"])
    clean = [{"w": w, "s": 10 + 0.45 * k, "e": 10.4 + 0.45 * k} for k, w in enumerate("the night is bright and long".split())]
    c_on = align_variant(lyr[:1], clean, 30.0, "en", None, "on")
    c_cons = align_variant(lyr[:1], clean, 30.0, "en", None, "cons")
    check("clean input: CONS == ON", c_on["lines"] == c_cons["lines"])
    try:
        align_variant(lyr, asr, 40.0, "en", None, "bogus")
        check("unknown near mode raises", False)
    except ValueError:
        check("unknown near mode raises", True)
    rr = random.Random(3)
    words = ["night", "light", "right", "love", "loved", "lover", "live", "move", "old", "cold", "hold", "gold", "sing", "sang"]
    same = True
    for _ in range(40):
        lk = [rr.choice(words) for _ in range(rr.randint(1, 14))]
        ak = [rr.choice(words) for _ in range(rr.randint(1, 14))]
        nm = sal._near_map(lk, ak)
        if _align_dp_allowed(lk, ak, nm, lambda i, j: True) != sal._align_dp(lk, ak, nm):
            same = False
    check("DP copy with allowed==True equals song_align._align_dp (40 random cases)", same)
    nok = True
    for _ in range(40):
        lk = [rr.choice(words) for _ in range(rr.randint(1, 14))]
        ak = [rr.choice(words) for _ in range(rr.randint(1, 14))]
        nm = sal._near_map(lk, ak)
        if any(k == 1 for _, _, k in _align_dp_allowed(lk, ak, nm, lambda i, j: False)):
            nok = False
    check("DP copy with allowed==False never returns a near match", nok)
    # a morph error exactly where the neighbours agree is kept by CONS; the same word 20 s away is rejected
    lyr2 = [{"text": t} for t in ["we walk down the lonely road", "the lights are low", "we walk down the lonely road", "the lights are low"]]
    a_ok = [{"w": "we", "s": 10.0, "e": 10.3}, {"w": "walk", "s": 10.5, "e": 10.8}, {"w": "lights", "s": 14.0, "e": 14.4},
            {"w": "low", "s": 14.9, "e": 15.2}]
    check("CONS keeps a plausible near match", align_variant(lyr2[:2], a_ok + [{"w": "roads", "s": 12.2, "e": 12.6}], 30.0, "en", None, "cons")["anchored"]
          >= align_variant(lyr2[:2], a_ok, 30.0, "en", None, "cons")["anchored"])
    print("== song_bench selftest: %d failed ==" % len(bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    for nm in ("run", "long", "silent", "wrong"):
        p = sub.add_parser(nm)
        p.add_argument("--out", required=True)
        p.add_argument("--model", default="small")
        p.add_argument("--model-root", default="")
        p.add_argument("--devices", default="cuda")
        if nm == "wrong":
            p.add_argument("--gen", required=True)
        if nm in ("run", "long"):
            p.add_argument("--gen", required=True)
            p.add_argument("--truth", required=True)
            p.add_argument("--snr", default="inf,10,5,0" if nm == "run" else "inf,5")
        if nm == "run":
            p.add_argument("--langs", default="en,ja")
            p.add_argument("--formats", default="wav")
            p.add_argument("--hints", default="none,first150,window30")
            p.add_argument("--vad", default="off,on")
            p.add_argument("--limit", type=int, default=0)
        if nm == "long":
            p.add_argument("--hint", default="window30")
        if nm == "silent":
            p.add_argument("--work", required=True)
            p.add_argument("--truth", required=True)
            p.add_argument("--tone", default="")
    p = sub.add_parser("report")
    p.add_argument("--in", dest="inp", action="append", required=True)
    p = sub.add_parser("near")
    p.add_argument("--in", dest="inp", action="append")
    p.add_argument("--sim", type=int, default=300)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--json", default="")
    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(cmd_selftest())
    if a.cmd == "run":
        cmd_run(a)
    elif a.cmd == "long":
        cmd_long(a)
    elif a.cmd == "silent":
        cmd_silent(a)
    elif a.cmd == "wrong":
        cmd_wrong(a)
    elif a.cmd == "report":
        cmd_report(a)
    elif a.cmd == "near":
        res = cmd_near(a)
        for k, v in res.items():
            print("##", k)
            for nm, m in v.items():
                print("   %-5s %s" % (nm, json.dumps(m, ensure_ascii=False)))
        if a.json:
            with open(a.json, "w", encoding="utf-8") as f:
                json.dump(res, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
