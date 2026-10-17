# -*- coding: utf-8 -*-
"""Pronunciation-analysis features, kept apart from server.py:

  (A) prosody  : pitch contours (librosa.pyin), DTW alignment to the native (Kokoro) contour, Japanese
                 pitch accent (pyopenjtalk full-context labels) and the learner's high/low per mora
  (B) phonemes : wav2vec2 phoneme CTC recognizer (espeak IPA) + CTC forced alignment of the expected
                 phonemes -> per-phoneme confidence / "what was heard" + Korean-learner tips

server.py calls init(...) once with the few helpers it owns (TTS, audio decode, pyopenjtalk, ...).
Everything here runs on CPU. Contract: ../API.md
"""
import os
import re
import json
import time
import hashlib
import threading
import unicodedata
from collections import OrderedDict

import numpy as np

H = {}          # helpers injected by server.py
JA_ENABLED = False   # Japanese accent / phoneme analysis is built but switched off for now (English only)
SR = 16000
HOP = 320       # 20 ms -> 50 points per second
_lock_pitch = threading.Lock()


def init(**helpers):
    H.update(helpers)


def _log():
    return H["log"]


# ==============================================================================================
# (A) prosody
# ==============================================================================================
def _frames_rms_db(x):
    import librosa
    r = librosa.feature.rms(y=x, frame_length=1024, hop_length=HOP, center=True)[0]
    return 20.0 * np.log10(r + 1e-6)


def pitch_track(x):
    """x: 16 kHz mono float32. returns dict(f0 Hz (nan = unvoiced), db, lo, hi) over the whole clip;
    lo..hi is the speech span (frame indices, hi exclusive)."""
    import librosa
    from scipy.signal import medfilt
    x = np.asarray(x, dtype=np.float32)
    if len(x) < 1600:
        return None
    with _lock_pitch:
        f0, vflag, _vp = librosa.pyin(x, fmin=65, fmax=500, sr=SR, frame_length=1024, hop_length=HOP,
                                      beta_parameters=(1, 5), fill_na=np.nan)
    db = _frames_rms_db(x)
    n = min(len(f0), len(db))
    f0, db = f0[:n].astype(np.float64), db[:n]
    mx = float(db.max())
    if mx < -58:
        return None
    act = np.where(db > max(mx - 38.0, -70.0))[0]
    if len(act) == 0:
        return None
    lo, hi = max(0, int(act[0]) - 2), min(n, int(act[-1]) + 3)
    f0 = f0.copy()
    f0[db < mx - 45.0] = np.nan
    # drop short voiced runs, octave outliers, then smooth inside each run
    v = np.isfinite(f0)
    i = 0
    while i < n:
        if not v[i]:
            i += 1
            continue
        j = i
        while j < n and v[j]:
            j += 1
        if j - i < 4:
            f0[i:j] = np.nan
        else:
            seg = f0[i:j]
            med = np.median(seg)
            bad = np.abs(12 * np.log2(seg / med)) > 7
            seg[bad] = np.nan
            f0[i:j] = seg
        i = j
    v = np.isfinite(f0)
    i = 0
    while i < n:
        if not v[i]:
            i += 1
            continue
        j = i
        while j < n and v[j]:
            j += 1
        k = min(5, (j - i) if (j - i) % 2 == 1 else (j - i) - 1)
        if k >= 3:
            f0[i:j] = medfilt(f0[i:j], k)
        i = j
    return {"f0": f0, "db": db, "lo": lo, "hi": hi, "n": n}


def to_semitones(f0, lo, hi):
    seg = f0[lo:hi]
    seg = seg[np.isfinite(seg)]
    if len(seg) < 4:
        return None, None
    med = float(np.median(seg))
    return 12.0 * np.log2(f0 / med), med


def _num_list(a, nd=2):
    return [None if not np.isfinite(v) else round(float(v), nd) for v in a]


_decode_cache = OrderedDict()


def wav_to_16k(data: bytes) -> np.ndarray:
    import soundfile as sf
    from io import BytesIO
    from math import gcd
    from scipy.signal import resample_poly
    d, sr = sf.read(BytesIO(data), dtype="float32", always_2d=True)
    m = d.mean(axis=1)
    if sr != SR:
        g = gcd(int(sr), SR)
        m = resample_poly(m, SR // g, int(sr) // g).astype(np.float32)
    return np.ascontiguousarray(m, dtype=np.float32)


def _feat(x, lo, hi):
    """MFCC + energy features of the speech span, z-scored (for DTW)"""
    import librosa
    m = librosa.feature.mfcc(y=x, sr=SR, n_mfcc=20, n_fft=512, hop_length=HOP, n_mels=40, center=True)
    db = _frames_rms_db(x)
    n = min(m.shape[1], len(db))
    F = np.vstack([m[1:, :n], (db[:n] / 8.0)[None, :]])[:, lo:hi]
    F = (F - F.mean(axis=1, keepdims=True)) / (F.std(axis=1, keepdims=True) + 1e-6)
    return F


def _dtw_path(A, B):
    """A: d x n, B: d x m. returns (n_idx_for_each_pair, m_idx...) as path array shape (L,2)"""
    import librosa
    n, m = A.shape[1], B.shape[1]
    tries = [dict(step_sizes_sigma=np.array([[1, 1], [2, 1], [1, 2]]), global_constraints=True, band_rad=0.35),
             dict(step_sizes_sigma=np.array([[1, 1], [2, 1], [1, 2]])),
             dict(step_sizes_sigma=np.array([[1, 1], [1, 0], [0, 1]]))]
    for kw in tries:
        try:
            D, wp = librosa.sequence.dtw(X=A, Y=B, metric="euclidean", **kw)
            if np.isfinite(D[-1, -1]):
                return wp[::-1], float(D[-1, -1]) / len(wp)
        except Exception:
            continue
    # last resort: linear map
    idx = np.linspace(0, m - 1, n).round().astype(int)
    return np.stack([np.arange(n), idx], axis=1), 99.0


_native_cache = OrderedDict()
_native_lock = threading.Lock()


def native_prosody(text, lang):
    key = (lang, text)
    with _native_lock:
        if key in _native_cache:
            _native_cache.move_to_end(key)
            return _native_cache[key]
    wav = H["synth_wav"](text, lang, 1.0)
    x = wav_to_16k(wav)
    pt = pitch_track(x)
    if pt is None:
        raise H["ApiError"]("원어민 음성의 높낮이를 분석하지 못했어요.", 422)
    st, med = to_semitones(pt["f0"], pt["lo"], pt["hi"])
    if st is None:
        raise H["ApiError"]("원어민 음성에서 높낮이를 찾지 못했어요.", 422)
    lo, hi = pt["lo"], pt["hi"]
    nat = {"x": x, "pt": pt, "st": st, "lo": lo, "hi": hi, "med": med,
           "feat": _feat(x, lo, hi), "dur": (hi - lo) * HOP / SR}
    with _native_lock:
        _native_cache[key] = nat
        while len(_native_cache) > 120:
            _native_cache.popitem(last=False)
    return nat


def _curve(values, lo, hi):
    n = hi - lo
    t = [round(i / max(1, n - 1), 4) for i in range(n)]
    return t, _num_list(values[lo:hi])


# ---- contour comparison ---------------------------------------------------------------------
def _tail_move(v):
    """pitch movement over the end of the contour (semitones; + = rising): linear fit over the last frames of the
    last voiced run that is at least 6 frames long (shorter blips at the very end are tracker noise)"""
    a = np.asarray(v, dtype=float)
    runs, i = [], 0
    while i < len(a):
        if np.isfinite(a[i]):
            j = i
            while j < len(a) and np.isfinite(a[j]):
                j += 1
            runs.append(a[i:j])
            i = j
        else:
            i += 1
    long_runs = [r for r in runs if len(r) >= 6]
    if not long_runs or sum(len(r) for r in runs) < 10:
        return 0.0
    w = long_runs[-1][-8:]
    slope = np.polyfit(np.arange(len(w)), w, 1)[0]
    return float(slope * (len(w) - 1))


def _fill_gaps(a, max_gap=3):
    a = np.array(a, dtype=float)
    n, i = len(a), 0
    while i < n:
        if np.isfinite(a[i]):
            i += 1
            continue
        j = i
        while j < n and not np.isfinite(a[j]):
            j += 1
        if 0 < i and j < n and j - i <= max_gap:
            a[i:j] = np.interp(np.arange(i, j), [i - 1, j], [a[i - 1], a[j]])
        i = j
    return a


def _spread(v):
    v = np.asarray([a for a in v if np.isfinite(a)])
    if len(v) < 6:
        return 0.0
    return float(np.percentile(v, 90) - np.percentile(v, 10))


def compare_contours(nat_st, mine_on_native):
    """similarity 0..100 from the Pearson correlation of the voiced overlap."""
    a = np.asarray(nat_st, dtype=float)
    b = np.asarray(mine_on_native, dtype=float)
    both = np.isfinite(a) & np.isfinite(b)
    nv = int(np.isfinite(a).sum())
    if nv < 6:
        return None
    if both.sum() < 8:
        return 0
    x, y = a[both], b[both]
    if x.std() < 1e-3 or y.std() < 0.35:
        return 5
    r = float(np.corrcoef(x, y)[0, 1])
    cover = both.sum() / nv
    sim = 100.0 * min(1.0, max(0.0, (r + 0.1) / 1.1)) * min(1.0, (cover / 0.55) ** 0.5)
    return int(round(max(0.0, min(100.0, sim))))


def prosody_tips(lang, text, nat_st, mine_st_raw, sim, accent_tips):
    tips = []
    mv = np.asarray(mine_st_raw, dtype=float)
    nv = np.asarray(nat_st, dtype=float)
    q = bool(re.search(r"[?？]\s*$", (text or "").strip())) or (lang == "ja" and bool(re.search(r"か[。]?\s*$", text or "")) and False)
    n_move, m_move = _tail_move(nv), _tail_move(mv)
    _log().info("tail moves native=%.2f mine=%.2f", n_move, m_move)
    n_rise = n_move > 1.5
    m_rise = m_move > 1.5
    expect_rise = q or n_rise
    m_rise = m_move > 2.0
    if m_rise and not expect_rise:
        tips.append("문장 끝을 올려 말했어요. 평서문은 끝을 내려요.")
    elif expect_rise and not m_rise:
        tips.append("문장 끝을 더 올려 보세요. 의문문은 끝을 올려 말해요." if q else "문장 끝을 올려야 해요. 원어민은 끝을 올려 말했어요.")
    elif (not expect_rise) and (n_move < -1.5) and (m_move > -0.6) and not m_rise and len(mv[np.isfinite(mv)]) >= 10:
        tips.append("문장 끝이 내려가지 않고 평평하게 끝났어요. 끝을 낮게 내려 마무리하면 자연스러워요.")
    sn, sm = _spread(nv), _spread(mv)
    if sn > 1.5 and sm < 0.5 * sn:
        tips.append("억양이 평평해요. 강조할 단어에서 목소리를 더 높였다 낮춰 보세요.")
    elif sn > 0.5 and sm > 1.9 * sn and sm > 8:
        tips.append("높낮이 변화가 원어민보다 훨씬 커요. 조금 줄여서 자연스럽게 말해 보세요.")
    tips = tips + list(accent_tips or [])
    if sim is not None and sim >= 80 and not tips:
        tips.append("억양이 원어민과 아주 비슷해요.")
    return tips[:3]


# ---- Japanese pitch accent -------------------------------------------------------------------
_MORA_PH = {"a", "i", "u", "e", "o", "A", "I", "U", "E", "O", "N", "cl"}


def _phrase_heads(t):
    """lexical accent type of the head word of every accent phrase (chain_flag != 1), in order"""
    heads = []
    for m in H["ojt"]().run_frontend(t):
        if m.get("pos") == "記号" or not (m.get("pron") or "").strip("、"):
            continue
        if int(m.get("chain_flag", -1)) != 1 or not heads:
            heads.append((int(m.get("acc", 0)), int(m.get("mora_size", 0))))
    return heads


def ja_accent(text):
    """expected Tokyo accent per mora from OpenJTalk full-context labels.
    returns list of dict(mora, high, phrase, pos, type, count, kind, nucleus)"""
    ojt = H["ojt"]()
    t = unicodedata.normalize("NFKC", text or "")
    labels = ojt.extract_fullcontext(t)
    raw = []
    phrase = -1
    for lab in labels:
        m = re.search(r"-([^+]+)\+", lab)
        if not m:
            continue
        p = m.group(1)
        if p not in _MORA_PH:
            continue
        a = re.search(r"/A:(-?\d+|xx)\+(\d+|xx)\+(\d+|xx)", lab)
        f = re.search(r"/F:(\d+|xx)_(\d+|xx)#", lab)
        if not a or not f or a.group(2) == "xx" or f.group(1) == "xx":
            continue
        pos, cnt, typ = int(a.group(2)), int(f.group(1)), int(f.group(2))
        if pos == 1:
            phrase += 1
        raw.append((p, max(phrase, 0), pos, cnt, typ))
    if not raw:
        return []
    kata = H["split_mora"](H["ja_to_kata"](text))
    import jaconv
    names = [jaconv.kata2hira(k) if k not in ("ー",) else k for k in kata] if len(kata) == len(raw) else None
    heads = _phrase_heads(t)
    n_phr = max(r[1] for r in raw) + 1
    if len(heads) != n_phr:
        heads = None
    out = []
    for i, (p, ph, pos, cnt, typ) in enumerate(raw):
        if heads is not None and typ == cnt and heads[ph][0] == 0:
            typ = 0     # labels write a heiban phrase as "nucleus on the last mora"; the dictionary says heiban
        if typ == 0:
            high = pos >= 2
        elif typ == 1:
            high = pos == 1
        else:
            high = 2 <= pos <= typ
        if typ == 0:
            kind = "heiban"
        elif typ == 1:
            kind = "atamadaka"
        elif typ == cnt or (heads is not None and heads[ph][0] == typ == heads[ph][1]):
            kind = "odaka"      # nucleus on the last mora of the word (the particle after it is low)
        else:
            kind = "nakadaka"
        out.append({"mora": names[i] if names else p, "high": bool(high), "phrase": ph,
                    "pos": pos, "type": typ, "count": cnt, "kind": kind, "nucleus": bool(typ > 0 and pos == typ)})
    return out


def _accent_public(acc):
    return [{"mora": a["mora"], "high": a["high"], "phrase": a["phrase"], "type": a["type"], "kind": a["kind"],
             "nucleus": a["nucleus"]} for a in acc]


def classify_high_low(vals, phrases):
    """vals: per-mora pitch (semitones) or nan -> list of True (high) / False (low) / None (unknown).
    Per accent phrase: the peak defines "high"; the first mora that falls clearly below the peak starts the low part;
    a phrase with no clear movement (range < 1.5 st) stays unknown."""
    vals = np.asarray(vals, dtype=float)
    out = [None] * len(vals)
    fin = vals[np.isfinite(vals)]
    if len(fin) == 0:
        return out
    glob = float(np.median(fin))
    for ph in sorted(set(phrases)):
        idx = [i for i, p in enumerate(phrases) if p == ph]
        v = vals[idx]
        f = np.where(np.isfinite(v))[0]
        if len(f) == 0:
            continue
        if len(f) == 1:
            out[idx[int(f[0])]] = bool(v[f[0]] >= glob)
            continue
        rng = float(v[f].max() - v[f].min())
        if rng < 1.5:
            continue
        top = float(v[f].max())
        pk = int(f[np.where(v[f] >= top - 0.4)[0][0]])
        thr = top - max(1.5, 0.25 * rng)
        dropped = False
        for q in range(len(idx)):
            if not np.isfinite(v[q]):
                continue
            if q < pk:
                out[idx[q]] = bool(v[q] >= thr)
            elif q == pk:
                out[idx[q]] = True
            else:
                if not dropped and v[q] <= thr:
                    dropped = True
                out[idx[q]] = not dropped
    return out


def accent_tips(acc, mine_acc):
    tips = []
    for i, (a, m) in enumerate(zip(acc, mine_acc)):
        if m["high"] is None or m["high"] == a["high"]:
            continue
        if len(tips) >= 2:
            break
        if a["high"] is False and a["pos"] == 1:
            tips.append("%s의 높이가 달라요: 원어민은 낮게 시작해요." % a["mora"])
        elif a["high"] is True and a["pos"] == 1:
            tips.append("%s의 높이가 달라요: 이 말은 첫 박부터 높게 시작해요." % a["mora"])
        elif a["high"] is False:
            tips.append("%s에서 음이 내려가야 해요. 악센트 핵 바로 뒤에서 한 번에 낮춰요." % a["mora"])
        else:
            tips.append("%s의 높이가 달라요: 원어민은 높게 말해요." % a["mora"])
    return tips


# ==============================================================================================
# (B) phoneme recognizer
# ==============================================================================================
PHONEME_REPO = "facebook/wav2vec2-lv-60-espeak-cv-ft"
_ph_model = None
_ph_vocab = None
_ph_lock = threading.Lock()
_ph_run_lock = threading.Lock()
_logit_cache = OrderedDict()
_logit_lock = threading.Lock()   # guards _logit_cache (pool threads and request threads both use it)


def phoneme_ready():
    return _ph_model is not None


def phoneme_load():
    global _ph_model, _ph_vocab
    if _ph_model is not None:
        return _ph_model
    with _ph_lock:
        if _ph_model is not None:
            return _ph_model
        t0 = time.time()
        import torch
        from huggingface_hub import snapshot_download
        from transformers import Wav2Vec2ForCTC
        path = snapshot_download(PHONEME_REPO)
        with open(os.path.join(path, "vocab.json"), "r", encoding="utf-8") as f:
            vocab = json.load(f)
        m = Wav2Vec2ForCTC.from_pretrained(path).eval()
        torch.set_num_threads(max(2, min(8, (os.cpu_count() or 4) - 1)))
        # warm up (first call allocates)
        with torch.inference_mode():
            m(torch.zeros(1, 16000))
        _ph_vocab = vocab
        _ph_model = m
        _log().info("phoneme model loaded in %.1fs", time.time() - t0)
        return _ph_model


def phoneme_probs(x):
    """16 kHz audio -> (T, V) float32 posteriors (20 ms frames), cached by content hash"""
    import torch
    model = phoneme_load()
    x = np.asarray(x, dtype=np.float32)[: SR * 20]
    key = hashlib.sha1(x.tobytes()).hexdigest()
    with _logit_lock:
        hit = _logit_cache.get(key)
        if hit is not None:
            _logit_cache.move_to_end(key)
            return hit
    xn = (x - x.mean()) / np.sqrt(x.var() + 1e-7)
    with _ph_run_lock, torch.inference_mode():
        lg = model(torch.from_numpy(xn)[None]).logits[0]
        P = torch.softmax(lg.float(), dim=-1).numpy()
    with _logit_lock:
        _logit_cache[key] = P
        _logit_cache.move_to_end(key)
        while len(_logit_cache) > 6:
            _logit_cache.popitem(last=False)
    return P


# ---- vocabulary helpers -------------------------------------------------------------------
# tokens the model emits as one unit although they are two phonemes; split so the expected sequence is atomic
SPLIT = {"ɑːɹ": ("ɑː", "ɹ"), "ɔːɹ": ("ɔː", "ɹ"), "oːɹ": ("oː", "ɹ"), "ɛɹ": ("ɛ", "ɹ"), "ɪɹ": ("ɪ", "ɹ"),
         "ʊɹ": ("ʊ", "ɹ"), "əl": ("ə", "l"), "aɪɚ": ("aɪ", "ɚ"), "aɪə": ("aɪ", "ə")}
VOWELS = {"a", "e", "i", "o", "u", "ɑ", "ɑː", "ɒ", "æ", "ɛ", "ɪ", "ɔ", "ɔː", "ʊ", "ʌ", "ə", "ɚ", "ɜ", "ɜː", "ɐ", "ᵻ", "iː", "uː",
          "aɪ", "eɪ", "oʊ", "aʊ", "ɔɪ", "ɯ", "ɨ", "eː", "oː", "aː", "ɛː", "e̞", "o̞", "y", "ø", "œ", "ɵ", "ʉ", "əʊ", "ä"}
WEAK = ["ə", "ɐ", "ɪ", "ᵻ", "ɚ"]
# expected token -> acceptable emitted tokens
ALT_EN = {
    "ə": ["ə", "ɐ", "ᵻ", "ɪ", "ɚ", "ʌ"], "ɐ": ["ɐ", "ə", "ʌ", "ᵻ"], "ɪ": ["ɪ", "ᵻ", "ə"], "ᵻ": ["ᵻ", "ɪ", "ə"], "ɚ": ["ɚ", "ə", "ɜː", "ɜ"],
    "i": ["i", "iː", "ɪ"], "iː": ["iː", "i"], "uː": ["uː", "u"], "u": ["u", "uː", "ʊ"], "ʊ": ["ʊ"],
    "ɹ": ["ɹ", "r"], "t": ["t", "ɾ", "th"], "d": ["d", "ɾ"], "oʊ": ["oʊ", "o", "əʊ"], "eɪ": ["eɪ", "e"],
    "ɑː": ["ɑː", "ɑ", "aː", "ɒ"], "ɑ": ["ɑ", "ɑː", "ɒ", "a", "ʌ"], "ɔː": ["ɔː", "ɔ", "oː"], "ɔ": ["ɔ", "ɔː", "o"], "ɜː": ["ɜː", "ɜ", "ɚ"],
    "ɛ": ["ɛ", "e"], "æ": ["æ", "a"], "ʌ": ["ʌ", "ɐ", "ə"], "l": ["l", "ɫ"], "n": ["n"], "k": ["k", "kh"], "p": ["p", "ph"],
    "aɪ": ["aɪ"], "aʊ": ["aʊ"], "ɔɪ": ["ɔɪ", "oɪ"], "ɡ": ["ɡ"], "tʃ": ["tʃ"], "dʒ": ["dʒ"], "ʒ": ["ʒ", "ʃ"],
}
# Japanese phoneme (pyopenjtalk symbol) -> (IPA to show, acceptable emitted tokens)
JA_PH = {
    "k": ("k", ["k", "kh"]), "g": ("ɡ", ["ɡ"]), "s": ("s", ["s"]), "sh": ("ɕ", ["ɕ", "ʃ"]), "z": ("z", ["z"]),
    "j": ("dʑ", ["dʑ", "dʒ", "ʑ", "ʒ"]), "t": ("t", ["t", "th"]), "ch": ("tɕ", ["tɕ", "tʃ", "ɕ", "ʃ", "t"]), "ts": ("ts", ["ts", "tsh"]),
    "d": ("d", ["d"]), "n": ("n", ["n"]), "ny": ("ɲ", ["ɲ", "n", "nʲ"]), "h": ("h", ["h", "x", "ç"]), "hy": ("ç", ["ç", "h", "ʃ", "ɕ"]),
    "f": ("ɸ", ["ɸ", "f", "h"]), "b": ("b", ["b", "β"]), "p": ("p", ["p", "ph"]), "m": ("m", ["m"]), "y": ("j", ["j"]),
    "r": ("ɾ", ["ɾ", "r", "d"]), "w": ("w", ["w", "v", "ʋ", "β"]), "N": ("n", ["n", "ŋ", "m", "ɴ", "ɲ"]),
    "a": ("a", ["a", "ɑ", "ɐ", "ä", "aː", "ɑː"]), "i": ("i", ["i", "iː", "ɪ", "ᵻ"]), "u": ("ɯ", ["ɯ", "u", "uː", "ʊ", "ɨ", "ə", "e̞"]),
    "e": ("e", ["e", "ɛ", "eː", "e̞"]), "o": ("o", ["o", "oː", "ɔ", "o̞", "ɔː", "e̞", "ə", "ɐ"]),
}
_KANA_CV = {}


def _build_kana():
    rows = {
        "": "アイウエオ", "k": "カキクケコ", "g": "ガギグゲゴ", "s": "サシスセソ", "z": "ザジズゼゾ", "t": "タチツテト", "d": "ダヂヅデド",
        "n": "ナニヌネノ", "h": "ハヒフヘホ", "b": "バビブベボ", "p": "パピプペポ", "m": "マミムメモ", "r": "ラリルレロ",
    }
    vs = "aiueo"
    for c, ks in rows.items():
        for v, k in zip(vs, ks):
            cc = c
            if k == "シ":
                cc = "sh"
            elif k in ("ジ", "ヂ"):
                cc = "j"
            elif k == "チ":
                cc = "ch"
            elif k in ("ヅ",):
                cc = "z"
            elif k == "ツ":
                cc = "ts"
            elif k == "フ":
                cc = "f"
            _KANA_CV[k] = (cc, v)
    for k, cv in (("ヤ", ("y", "a")), ("ユ", ("y", "u")), ("ヨ", ("y", "o")), ("ワ", ("w", "a")), ("ヲ", ("", "o")),
                  ("ン", ("N", "")), ("ヴ", ("b", "u")), ("ヮ", ("w", "a"))):
        _KANA_CV[k] = cv


_build_kana()
_SMALL_V = {"ァ": "a", "ィ": "i", "ゥ": "u", "ェ": "e", "ォ": "o"}
_SMALL_Y = {"ャ": "a", "ュ": "u", "ョ": "o"}
VOICELESS_C = {"k", "s", "sh", "t", "ch", "ts", "h", "hy", "f", "p"}


def mora_phones(mora):
    """katakana mora -> list of (pyopenjtalk-style symbol) e.g. 'キャ' -> ['k','y','a']; 'ッ','ー' -> []"""
    if mora in ("ッ", "ー", ""):
        return []
    c0 = mora[0]
    if c0 not in _KANA_CV:
        return []
    c, v = _KANA_CV[c0]
    if c == "N":
        return ["N"]
    if len(mora) > 1:
        s = mora[1]
        if s in _SMALL_Y:
            v = _SMALL_Y[s]
            if c in ("sh", "ch", "j"):
                pass
            elif c:
                c = c + "y"
            else:
                c = "y"
        elif s in _SMALL_V:
            v = _SMALL_V[s]
            if c == "" and c0 == "ウ":
                c = "w"
            elif c == "" or c0 in "テデ" or c0 == "ト" or c0 == "ド":
                pass
    out = []
    if c:
        if c in ("ky", "gy", "py", "by", "my", "ry"):
            base = c[0]
            out += [base, "y"]
        elif c == "ny":
            out += ["ny"]
        elif c == "hy":
            out += ["hy"]
        else:
            out.append(c)
    if v:
        out.append(v)
    return out


# ---- English: expected phonemes via espeak ------------------------------------------------------
_esp = None
_esp_lock = threading.Lock()


def _espeak():
    global _esp
    if _esp is None:
        with _esp_lock:
            if _esp is None:
                H["patch_espeak"]()
                import espeakng_loader
                from phonemizer.backend.espeak.wrapper import EspeakWrapper
                EspeakWrapper.set_library(espeakng_loader.get_library_path())
                from phonemizer.backend import EspeakBackend
                _esp = EspeakBackend("en-us", preserve_punctuation=False, with_stress=False, language_switch="remove-flags")
    return _esp


def _tokenize_ipa(s):
    """greedy longest-match of an espeak IPA word into model vocabulary tokens (merged r-coloured tokens split)"""
    vocab = _ph_vocab
    s = s.replace("ˈ", "").replace("ˌ", "").replace("͡", "").replace("͜", "").replace("^", "").replace("-", "")
    s = s.replace("̩", "").replace("̯", "").replace(":", "ː")
    keys = [k for k in vocab if k not in ("<s>", "<pad>", "</s>", "<unk>") and len(k) <= 3 and not re.search(r"[0-9\[\.]", k)
            and not (len(k) > 1 and k.isascii())]
    keys.sort(key=lambda k: -len(k))
    out, i = [], 0
    while i < len(s):
        hit = None
        for k in keys:
            if s.startswith(k, i):
                hit = k
                break
        if hit is None:
            i += 1
            continue
        i += len(hit)
        out.extend(SPLIT.get(hit, (hit,)))
    return out


def en_expected(words):
    """words: list of normalised lower-case words -> list (per word) of lists of tokens"""
    from phonemizer.separator import Separator
    sep = Separator(word=" ", phone="", syllable="")
    be = _espeak()
    with _esp_lock:
        full = be.phonemize([" ".join(words)], separator=sep, strip=True)[0].split()
        if len(full) != len(words):
            full = [be.phonemize([w], separator=sep, strip=True)[0].replace(" ", "") for w in words]
    return [_tokenize_ipa(w) for w in full]


# ---- CTC forced alignment ---------------------------------------------------------------------
SPLIT_JA = {"aɪ": ("a", "i"), "eɪ": ("e", "i"), "oʊ": ("o", "ɯ"), "aʊ": ("a", "ɯ"), "ɔɪ": ("o", "i"), "əʊ": ("o", "ɯ"),
            "oɪ": ("o", "i"), "ɑː": ("a", "a")}


def expand_merged(P, lang="en"):
    """duplicate frames where a merged token (e.g. ɑːɹ) fires so that it becomes two adjacent atomic tokens"""
    V = _ph_vocab
    table = SPLIT if lang == "en" else SPLIT_JA
    mids = {V[k]: (V[a], V[b]) for k, (a, b) in table.items() if k in V and a in V and b in V}
    if not mids:
        return P, np.arange(len(P))
    cols = list(mids)
    tot = P[:, cols].sum(axis=1)
    rows, orig = [], []
    for f in range(len(P)):
        if tot[f] > 0.15:
            r1, r2 = P[f].copy(), P[f].copy()
            for j in cols:
                m = P[f, j]
                if m > 0.01:
                    a, b = mids[j]
                    r1[a] += m
                    r2[b] += m
                    r1[j] = 0
                    r2[j] = 0
            rows += [r1, r2]
            orig += [f, f]
        else:
            rows.append(P[f])
            orig.append(f)
    return np.asarray(rows, dtype=np.float32), np.asarray(orig)


def ctc_align(emit, blank, labels):
    """emit: (T,K) log emission score of expected token k at frame t; blank: (T,) log blank.
    labels: list of expected token strings (to forbid skipping between identical tokens).
    returns for each token the list of frames assigned, or None if impossible"""
    T, K = emit.shape
    S = 2 * K + 1
    if T < K:
        return None
    NEG = -1e9
    em = np.full((T, S), NEG, dtype=np.float64)
    em[:, 0::2] = blank[:, None]
    em[:, 1::2] = emit
    skip_ok = np.zeros(S, dtype=bool)
    for k in range(1, K):
        skip_ok[2 * k + 1] = labels[k] != labels[k - 1]
    dp = np.full((T, S), NEG, dtype=np.float64)
    bp = np.zeros((T, S), dtype=np.int8)
    dp[0, 0] = em[0, 0]
    if S > 1:
        dp[0, 1] = em[0, 1]
    for t in range(1, T):
        prev = dp[t - 1]
        c0 = prev
        c1 = np.concatenate([[NEG], prev[:-1]])
        c2 = np.concatenate([[NEG, NEG], prev[:-2]])
        c2 = np.where(skip_ok, c2, NEG)
        stack = np.stack([c0, c1, c2])
        arg = stack.argmax(axis=0)
        dp[t] = stack[arg, np.arange(S)] + em[t]
        bp[t] = arg
    end = S - 1 if dp[T - 1, S - 1] >= dp[T - 1, S - 2] else S - 2
    if dp[T - 1, end] < NEG / 2:
        return None
    s = end
    frames = [[] for _ in range(K)]
    for t in range(T - 1, -1, -1):
        if s % 2 == 1:
            frames[s // 2].append(t)
        s -= int(bp[t, s])
        if s < 0:
            break
    return [sorted(f) for f in frames]


def _ids(tokens):
    return [_ph_vocab[t] for t in tokens if t in _ph_vocab]


def recognise_tokens(P2, orig, spans, alts, exp, vowel_flags=None):
    """per expected token: peak probability of the expected class, best competitor and its probability"""
    T2, V = P2.shape
    K = len(exp)
    peak, comp, pcomp = np.zeros(K), [None] * K, np.zeros(K)
    inv = {v: k for k, v in _ph_vocab.items()}
    for k in range(K):
        fr = spans[k]
        if not fr:
            continue
        lo = (spans[k - 1][-1] + fr[0]) // 2 if k > 0 and spans[k - 1] else max(0, fr[0] - 5)
        hi = (fr[-1] + spans[k + 1][0]) // 2 if k < K - 1 and spans[k + 1] else min(T2 - 1, fr[-1] + 6)
        lo, hi = max(0, min(lo, fr[0])), min(T2 - 1, max(hi, fr[-1]))
        W = P2[lo:hi + 1]
        a_ids = alts[k]
        pe = W[:, a_ids].sum(axis=1).max()
        mask = np.ones(V, dtype=bool)
        mask[0] = False
        mask[a_ids] = False
        for sp in (1, 2, 3):
            mask[sp] = False
        pk = W[:, mask].max(axis=0)
        ci = np.where(mask)[0][int(pk.argmax())]
        peak[k] = float(min(1.0, pe))
        comp[k] = inv[ci]
        pcomp[k] = float(pk.max())
    return peak, comp, pcomp


def judge(pe, pc, lang="en"):
    """-> (ok, conf)"""
    ratio = pe / (pe + pc + 1e-6)
    ok = bool(pe >= (0.22 if lang == "en" else 0.13) and pe >= 0.45 * pc)
    conf = float(min(1.0, ratio * min(1.0, (pe + 0.15) / 0.55)))
    return ok, round(conf, 3)


def _phonemes_for(tokens_per_unit, flat_extra=None):
    pass


def align_expected(P, exp_units, lang="en"):
    """exp_units: list of units; each unit is a list of dict(p=display, alts=[token], opt=bool, tok=label)
    returns per-unit lists of dict(p, ok, conf, heard) and a dict with frame info"""
    P2, orig = expand_merged(P, lang)
    flat = []
    for ui, u in enumerate(exp_units):
        for pi, ph in enumerate(u):
            if ph.get("skip"):
                continue
            flat.append((ui, pi, ph))
    K = len(flat)
    res = [[None] * len(u) for u in exp_units]
    if K == 0:
        return res, None
    alts = []
    for _ui, _pi, ph in flat:
        ids = _ids(ph["alts"])
        alts.append(ids)
    emit = np.stack([np.log(P2[:, ids].sum(axis=1) + 1e-8) for ids in alts], axis=1)
    blank = np.log(P2[:, 0] + 1e-8)
    labels = [ph["tok"] for _u, _p, ph in flat]
    spans = ctc_align(emit, blank, labels)
    if spans is None:
        return None, None
    peak, comp, pcomp = recognise_tokens(P2, orig, spans, alts, labels)
    for k, (ui, pi, ph) in enumerate(flat):
        ok, conf = judge(float(peak[k]), float(pcomp[k]), lang)
        heard = None
        if not ok and pcomp[k] >= 0.2 and comp[k]:
            heard = comp[k]
        if ph.get("opt") and not ok:
            ok = True
        res[ui][pi] = {"p": ph["p"], "ok": ok, "conf": conf, "heard": heard, "_pc": round(float(pcomp[k]), 3)}
    for ui, u in enumerate(exp_units):
        for pi, ph in enumerate(u):
            if res[ui][pi] is None:
                res[ui][pi] = {"p": ph["p"], "ok": True, "conf": 1.0, "heard": None, "_pc": 0.0}
    info = {"P2": P2, "orig": orig, "spans": spans, "flat": flat, "peak": peak, "comp": comp, "pcomp": pcomp}
    return res, info


_CONS_EN = set("pbtdkɡfvθðszʃʒhmnŋlɹrwjɾ") | {"tʃ", "dʒ"}


def detect_epenthesis(info, res, exp_units):
    """consonant followed by an extra vowel the target does not have (milk -> milku)"""
    P2, spans, flat = info["P2"], info["spans"], info["flat"]
    inv = {v: k for k, v in _ph_vocab.items()}
    K = len(flat)
    T2 = len(P2)
    vow_ids = {_ph_vocab[v]: v for v in ("ə", "ɯ", "u", "ɪ", "ɨ", "ɐ", "i", "e", "ɛ", "ᵻ", "o", "ʊ", "a") if v in _ph_vocab}
    for k in range(K):
        ui, pi, ph = flat[k]
        if ph["tok"] not in _CONS_EN or not spans[k]:
            continue
        # only consonants that end the word, or precede another consonant
        last_in_word = pi == len(exp_units[ui]) - 1
        nxt_cons = (not last_in_word) and exp_units[ui][pi + 1]["tok"] in _CONS_EN
        if not (last_in_word or nxt_cons):
            continue
        a = spans[k][-1] + 1
        b = (spans[k + 1][0] - 1) if k + 1 < K and spans[k + 1] else min(T2 - 1, a + 10)
        b = min(b, a + 10)
        if b < a:
            continue
        W = P2[a:b + 1]
        for vid, vname in vow_ids.items():
            pass
        ids = list(vow_ids)
        pv = W[:, ids]
        if pv.size == 0:
            continue
        j = np.unravel_index(int(pv.argmax()), pv.shape)
        if pv[j] >= 0.45 and (last_in_word or nxt_cons):
            r = res[ui][pi]
            if r["ok"]:
                r["ok"] = False
                r["heard"] = ph["p"] + vow_ids[ids[j[1]]]
                r["conf"] = round(min(r["conf"], 0.45), 3)
    return res


# ---- tips ------------------------------------------------------------------------------------
def _w(word):
    return "'%s'" % word


EN_TIPS = {
    ("θ", ("s", "t", "f", "z", "d", "θ")): ("th", "{w}의 th(θ)가 {h}로 들렸어요. 혀끝을 윗니 사이에 살짝 내밀고 바람만 내보내요. 혀를 입안에 넣으면 s로 들려요."),
    ("ð", ("d", "z", "ɾ", "n", "θ")): ("dh", "{w}의 th(ð)가 {h}로 들렸어요. 혀끝을 윗니 사이에 살짝 내밀고 목을 울리며 소리 내요. 혀를 입천장에 붙이면 d로 들려요."),
    ("f", ("p", "h", "ɸ", "b", "ph")): ("f", "{w}의 f가 {h}로 들렸어요. 윗니를 아랫입술에 살짝 대고 바람을 새게 내요. 두 입술을 붙였다 터뜨리면 p가 돼요."),
    ("v", ("b", "w", "β", "ʋ")): ("v", "{w}의 v가 {h}로 들렸어요. 윗니를 아랫입술에 살짝 대고 목을 울려요. 입술을 붙이면 b로 들려요."),
    ("ɹ", ("l", "ɫ", "ɾ", "w")): ("rl", "{w}의 r이 {h}로 들렸어요. r은 혀끝을 입천장에 대지 않고 뒤로 살짝 말아 올려요. 한국어 ㄹ처럼 혀를 대면 l로 들려요."),
    ("l", ("ɹ", "r", "ɾ", "w")): ("rl", "{w}의 l이 {h}로 들렸어요. l은 혀끝을 윗니 뒤 잇몸에 붙인 채로 소리를 내요. 혀를 말면 r로 들려요."),
    ("z", ("dʒ", "dʑ", "tʃ", "ʒ", "s", "d")): ("z", "{w}의 z가 {h}로 들렸어요. z는 혀를 윗잇몸 가까이에 두고 목을 울리며 바람을 계속 내보내요. 혀를 붙였다 떼면 j로 들려요."),
    ("ʃ", ("s", "sʲ", "ɕ", "tʃ")): ("sh", "{w}의 sh(ʃ)가 {h}로 들렸어요. 입술을 앞으로 둥글게 내밀고 혀를 뒤로 당겨 '쉬' 하는 소리를 내요."),
    ("æ", ("e", "ɛ", "a", "ɑ", "ʌ")): ("ae", "{w}의 æ가 {h}로 들렸어요. æ는 입을 크게 벌리고 '애'와 '아' 사이처럼 소리 내요. 한국어 '에'처럼 입을 작게 벌리면 안 돼요."),
    ("ɪ", ("iː", "i")): ("ih", "{w}의 짧은 ɪ가 긴 {h}로 들렸어요. ɪ는 입 힘을 빼고 짧게 '이'와 '으' 사이로 내요 (ship / sheep)."),
    ("iː", ("ɪ", "ᵻ")): ("ih", "{w}의 긴 iː가 짧은 {h}로 들렸어요. iː는 입꼬리를 옆으로 당기고 길게 끌어 줘요 (sheep / ship)."),
    ("ʊ", ("uː", "u")): ("uh", "{w}의 짧은 ʊ가 긴 {h}로 들렸어요. ʊ는 입술을 덜 내밀고 짧게 내요 (full / fool)."),
    ("uː", ("ʊ",)): ("uh", "{w}의 긴 uː가 짧은 {h}로 들렸어요. uː는 입술을 동그랗게 내밀고 길게 끌어 줘요 (fool / full)."),
    ("ʌ", ("ɑ", "ɔ", "a", "o", "ɑː", "ɔː")): ("uh2", "{w}의 ʌ가 {h}로 들렸어요. ʌ는 입을 작게 벌리고 짧게 '어'에 가깝게 내요. 입을 크게 벌리면 ɑ로 들려요."),
    ("ɛ", ("æ",)): ("ae", "{w}의 ɛ가 æ로 들렸어요. ɛ는 입을 너무 크게 벌리지 말고 '에'처럼 내요."),
}


def en_phoneme_tip(word, p, heard, is_last, h_ins):
    """returns (category, text) or None"""
    if heard and p and heard.startswith(p) and len(heard) > len(p) and p in _CONS_EN:
        return "ins", "%s 끝에 모음이 하나 더 들렸어요 (예: milk가 밀크처럼). 끝 자음 %s 뒤에 모음 없이 숨만 짧게 끊어 주세요." % (_w(word), p)
    if heard is None and p in _CONS_EN and is_last:
        return "final", "%s 끝의 %s 소리가 빠졌어요. 단어 끝 자음까지 받침처럼 짧게 소리 내 주세요." % (_w(word), p)
    for (exp, heards), (cat, text) in EN_TIPS.items():
        if exp == p and heard in heards:
            return cat, text.format(w=_w(word), h=heard)
    return None


def en_generic_tip(word, p, heard):
    if heard:
        return "gen", "%s의 %s 소리가 %s로 들렸어요. 이 소리만 따로 천천히 연습해 보세요." % (_w(word), p, heard)
    return "gen", "%s의 %s 소리가 잘 들리지 않았어요. 이 소리를 또렷하게 내 보세요." % (_w(word), p)


_VOICE_PAIRS_JA = {("k", "ɡ"), ("ɡ", "k"), ("t", "d"), ("d", "t"), ("p", "b"), ("b", "p"), ("s", "z"), ("z", "s"), ("h", "b")}


def ja_phoneme_tip(mora, p, heard):
    if p == "ts" and heard in ("tɕ", "tʃ", "ɕ", "ʃ", "s", "t", "ç"):
        return "ts", "'つ'가 '%s' 계열로 들렸어요. つ(ts)는 혀끝을 윗니 뒤에 붙였다 떼며 'ㅊ'과 'ㅅ' 사이처럼 내요. 입술은 내밀지 마세요." % ("ちゅ" if heard in ("tɕ", "tʃ", "ɕ", "ʃ") else "す")
    if p == "z" and heard in ("dʑ", "dʒ", "ʑ", "ʒ", "tɕ"):
        return "zu", "'%s'(z)가 'じゅ'처럼 들렸어요. ず는 혀를 윗잇몸 가까이에 두고 성대를 울리며 내요. '주'가 아니라 '즈'에 가까워요." % mora
    if p == "ɾ" and heard in ("l", "ɫ", "ɹ", "ɭ"):
        return "ra", "'%s'의 ら행(r)이 l로 들렸어요. 혀끝으로 윗잇몸을 한 번 톡 치듯 내요. 혀를 대고 있으면 l이 돼요." % mora
    if (p, heard) in _VOICE_PAIRS_JA:
        if p in ("k", "t", "p", "s", "h"):
            return "voice", "'%s'가 탁음으로 들렸어요 (%s→%s). 성대를 울리지 말고 숨만 내보내며 발음하세요." % (mora, p, heard)
        return "voice", "'%s'가 청음으로 들렸어요 (%s→%s). 탁음은 성대를 울려서 발음해야 해요." % (mora, p, heard)
    return None


def ja_generic_tip(mora, p, heard):
    if heard:
        return "gen", "'%s'의 %s 소리가 %s로 들렸어요. 이 글자만 따로 천천히 연습해 보세요." % (mora, p, heard)
    return "gen", "'%s'의 %s 소리가 잘 들리지 않았어요. 또렷하게 내 보세요." % (mora, p)


# ---- high-level: English / Japanese expected units ---------------------------------------------
def en_units_expected(words):
    ex = en_expected(words)
    units = []
    for w, toks in zip(words, ex):
        u = []
        for ti, t in enumerate(toks):
            alts = list(ALT_EN.get(t, [t]))
            if ti + 1 < len(toks) and toks[ti + 1] == "ɹ":   # "here", "poor": the vowel before r is often tense
                if t == "ɪ":
                    alts += ["iː", "i"]
                elif t == "ʊ":
                    alts += ["uː"]
            u.append({"p": t, "alts": alts, "tok": t})
        units.append(u)
    return units


def ja_units_expected(moras):
    """moras: list of katakana moras (as in /score units). 'ー' and 'ッ' carry no CTC token; their length is checked from timing"""
    units = []
    prev_vowel = None
    for i, m in enumerate(moras):
        u = []
        if m == "ー":
            u.append({"p": "ː", "alts": [], "tok": "ː", "skip": True, "dur": "long"})
        elif m == "ッ":
            u.append({"p": "ʔ", "alts": [], "tok": "ʔ", "skip": True, "dur": "geminate"})
        else:
            ph = mora_phones(m)
            if len(ph) == 1 and ph[0] in "aiueo" and prev_vowel is not None and (
                    ph[0] == prev_vowel or (prev_vowel, ph[0]) in (("o", "u"), ("e", "i"))):
                # a second identical vowel (いい, おお, おう): the model emits one symbol for the pair, so judge by length
                units.append([{"p": JA_PH[ph[0]][0], "alts": [], "tok": ph[0], "skip": True, "dur": "vowel2"}])
                prev_vowel = ph[0]
                continue
            cons_voiceless = bool(ph) and ph[0] in VOICELESS_C
            nxt = moras[i + 1] if i + 1 < len(moras) else ""
            nph = mora_phones(nxt)
            next_voiceless = (not nph) and nxt in ("ッ",) or (bool(nph) and nph[0] in VOICELESS_C) or (not nxt)
            for j, s in enumerate(ph):
                disp, alts = JA_PH[s]
                d = {"p": disp, "alts": alts, "tok": s}
                if s == "y" and j > 0 and j < len(ph) - 1:
                    d["opt"] = True
                if s in ("i", "u") and cons_voiceless and next_voiceless and j == len(ph) - 1:
                    d["opt"] = True  # devoiced vowel: may be absent in speech
                u.append(d)
            if not u:
                u.append({"p": m, "alts": [], "tok": m, "skip": True})
            prev_vowel = ph[-1] if ph and ph[-1] in "aiueo" else None
        units.append(u)
    return units


def _mora_anchor(info, ui_of_flat, spans):
    pass


def ja_duration_checks(res, info, exp_units, moras):
    """long vowel ー and geminate ッ are judged from timing: the gap between the neighbouring nuclei
    must be about (1 + number of extra moras) mora lengths."""
    spans, flat = info["spans"], info["flat"]
    orig = info["orig"]
    # nucleus frame (original frame index) of each mora that has CTC tokens: its last token
    nuc = {}
    first = {}
    for k, (ui, pi, ph) in enumerate(flat):
        if spans[k]:
            nuc[ui] = float(orig[spans[k][-1]])
            first.setdefault(ui, float(orig[spans[k][0]]))
    anchored = sorted(nuc)
    if len(anchored) < 3:
        return res
    # typical distance between neighbouring anchored moras
    d = []
    for a, b in zip(anchored, anchored[1:]):
        if b == a + 1:
            d.append(nuc[b] - nuc[a])
    if len(d) < 2:
        return res
    mora_len = float(np.median(d))
    mora_len = max(mora_len, 3.0)
    _log().info("ja dur: nuc=%s mora_len=%.1f", {k: round(v, 1) for k, v in nuc.items()}, mora_len)
    i = 0
    n = len(moras)
    tim = [bool(u and u[0].get("dur")) for u in exp_units]
    while i < n:
        if tim[i]:
            j = i
            while j < n and tim[j]:
                j += 1
            a = i - 1
            while a >= 0 and a not in nuc:
                a -= 1
            b = j
            while b < n and b not in nuc:
                b += 1
            extra = j - i
            if a >= 0 and b < n and a in nuc and b in nuc:
                gaps_between = [m for m in range(a + 1, b) if not tim[m]]
                units_between = b - a
                span = nuc[b] - nuc[a]
                if not gaps_between:
                    ratio = span / (units_between * mora_len)
                    long_v = any(exp_units[m][0]["dur"] in ("long", "vowel2") for m in range(i, j))
                    thr = 1.05 if long_v else 0.6
                    ok = ratio >= thr
                    conf = round(float(min(1.0, max(0.0, 0.5 + (ratio - thr) * 1.2))), 3)
                    for m in range(i, j):
                        res[m][0]["ok"] = bool(ok)
                        res[m][0]["conf"] = conf
                        res[m][0]["heard"] = None
            i = j
        else:
            i += 1
    return res


def attach_phonemes(lang, target_units, units_res, audio, moras=None, words=None):
    """core of /score phonemes. returns (list_of_ph_lists or None, tips list)"""
    P = phoneme_probs(audio)
    if lang == "en":
        exp_units = en_units_expected(words)
    else:
        exp_units = ja_units_expected(moras)
    res, info = align_expected(P, exp_units, lang)
    if res is None:
        return None, []
    if lang == "en":
        detect_epenthesis(info, res, exp_units)
    else:
        ja_duration_checks(res, info, exp_units, moras)
    tips = make_tips(lang, res, words if lang == "en" else moras, exp_units)
    for u in res:
        for r in u:
            r.pop("_pc", None)
    return res, tips


def make_tips(lang, res, names, exp_units):
    rule, gen = [], []
    seen = set()
    cand = []
    for ui, u in enumerate(res):
        for pi, r in enumerate(u):
            if r["ok"]:
                continue
            cand.append((r["conf"], ui, pi, r))
    cand.sort(key=lambda c: c[0])
    for _c, ui, pi, r in cand:
        word = names[ui]
        p, heard = r["p"], r["heard"]
        t = None
        if heard and r.get("_pc", 1.0) < 0.35 and not exp_units[ui][pi].get("dur"):
            continue   # weak evidence for the confusion: no tip
        if lang == "en":
            is_last = pi == len(res[ui]) - 1
            t = en_phoneme_tip(word, p, heard, is_last, None)
        else:
            if p == "ː" or exp_units[ui][pi].get("dur") in ("long", "vowel2"):
                t = ("long", "장음 'ー'가 짧게 들렸어요. 모음을 한 박 더 길게 끌어 주세요 (예: おばさん / おばあさん).")
                word = "장음"
            elif p == "ʔ" or exp_units[ui][pi].get("dur") == "geminate":
                t = ("sok", "촉음 'っ'가 약했어요. 'っ' 자리에서 소리를 한 박 멈췄다가 다음 소리를 내 주세요 (예: きて / きって).")
                word = "촉음"
            elif heard is None and exp_units[ui][pi]["tok"] == "N":
                t = ("n", "'ん'이 잘 들리지 않았어요. ん은 한 박을 온전히 차지해요. 입을 닫거나 혀를 붙인 채 코로 한 박 울려 주세요.")
            else:
                t = ja_phoneme_tip(word, exp_units[ui][pi]["tok"], heard)
        if t:
            if t[0] not in seen:
                seen.add(t[0])
                rule.append((t[1], word))
        elif len(gen) < 1:
            g = en_generic_tip(word, p, heard) if lang == "en" else ja_generic_tip(word, p, heard)
            gen.append((g[1], word))
    out = rule[:2]
    if not out and gen:
        out = gen[:1]
    return out


# ==============================================================================================
# /prosody
# ==============================================================================================
def prosody(lang, text, reading, audio):
    """audio: 16 kHz float32 array or None. returns the response dict of POST /prosody"""
    nat = native_prosody(text, lang)
    lo, hi = nat["lo"], nat["hi"]
    nt, nf = _curve(nat["st"], lo, hi)
    out = {"native": {"t": nt, "f0": nf, "dur": round(nat["dur"], 3)}, "mine": None, "similarity": None,
           "accent": None, "mine_accent": None, "tips_ko": []}
    acc = None
    if lang == "ja" and JA_ENABLED:
        try:
            acc = ja_accent(text)
        except Exception:
            _log().exception("accent failed")
            acc = []
        out["accent"] = _public_accent(acc) if acc else None
    if audio is None:
        return out
    mt = pitch_track(audio)
    if mt is None:
        out["tips_ko"] = ["목소리의 높낮이를 잡지 못했어요. 조금 더 크게, 또렷하게 말해 보세요."]
        return out
    mst, _ = to_semitones(mt["f0"], mt["lo"], mt["hi"])
    if mst is None:
        out["tips_ko"] = ["목소리의 높낮이를 잡지 못했어요. 조금 더 크게, 또렷하게 말해 보세요."]
        return out
    mlo, mhi = mt["lo"], mt["hi"]
    A = nat["feat"]
    B = _feat(audio, mlo, mhi)
    wp, dcost = _dtw_path(A, B)
    _log().info("prosody dtw cost/step=%.2f lens=%d,%d", dcost, A.shape[1], B.shape[1])
    n = A.shape[1]
    groups = [[] for _ in range(n)]
    for i, j in wp:
        groups[int(i)].append(int(j))
    mine_nat = np.full(n, np.nan)
    mine_seg = mst[mlo:mhi]
    for i in range(n):
        js = groups[i]
        if not js:
            continue
        vals = mine_seg[js]
        fin = vals[np.isfinite(vals)]
        if len(fin) >= max(1, 0.5 * len(vals)):
            mine_nat[i] = float(np.median(fin))
    nat_seg = nat["st"][lo:hi]
    mine_nat = _fill_gaps(mine_nat)
    sim = compare_contours(nat_seg, mine_nat)
    match = content_match(lang, text, reading, audio)
    if match is not None and sim is not None:
        sim = int(round(sim * min(1.0, max(0.15, (match - 0.2) / 0.5))))
    out["mine"] = {"t": nt, "f0": _num_list(mine_nat), "dur": round((mhi - mlo) * HOP / SR, 3)}
    out["similarity"] = sim
    a_tips = []
    if lang == "ja" and acc and JA_ENABLED:
        try:
            mine_acc = mine_accent(audio, mt, mst, acc, text, reading)
            if mine_acc is not None:
                out["mine_accent"] = [{"mora": a["mora"], "high": m} for a, m in zip(acc, mine_acc)]
                a_tips = accent_tips(acc, [{"high": m} for m in mine_acc])
        except Exception:
            _log().exception("mine_accent failed")
    out["tips_ko"] = prosody_tips(lang, text, nat_seg, mine_seg, sim, a_tips)
    if match is not None:
        out["match"] = round(match, 2)
        if match < 0.45:
            out["tips_ko"] = ["목표 문장과 다른 말을 한 것 같아서 억양을 비교하기 어려워요. 문장을 보면서 다시 말해 보세요."]
    return out


def content_match(lang, text, reading, audio):
    """fraction of the target's phonemes found in the audio (None if the phoneme model is not loaded);
    tells whether the learner said the sentence at all, i.e. whether comparing contours makes sense"""
    if not phoneme_ready() or (lang == "ja" and not JA_ENABLED):
        return None
    try:
        P = phoneme_probs(audio)
        if lang == "en":
            words = H["en_words"](text)
            if not words:
                return None
            units = en_units_expected(words)
        else:
            moras = H["split_mora"](H["ja_to_kata"]((reading or "").strip() or text))
            if not moras:
                return None
            units = ja_units_expected(moras)
        res, info = align_expected(P, units, lang)
        if res is None:
            return 0.0
        flat = [r for u, ru in zip(units, res) for ph, r in zip(u, ru) if not ph.get("skip")]
        if not flat:
            return None
        return sum(1 for r in flat if r["ok"]) / len(flat)
    except Exception:
        _log().exception("content_match failed")
        return None


def _public_accent(acc):
    return _accent_public(acc)


def mine_accent(audio, mt, mst, acc, text, reading):
    """learner high/low per accent mora from their pitch and CTC mora timings. None if the phoneme model is not loaded"""
    if not phoneme_ready():
        return None
    moras = [a["mora"] for a in acc]
    import jaconv
    kata = [jaconv.hira2kata(m) if m not in ("ー",) else m for m in moras]
    exp_units = ja_units_expected(kata)
    P = phoneme_probs(audio)
    res, info = align_expected(P, exp_units, "ja")
    if info is None:
        return None
    spans, flat, orig = info["spans"], info["flat"], info["orig"]
    n = len(moras)
    start = [None] * n
    end = [None] * n
    for k, (ui, pi, ph) in enumerate(flat):
        if not spans[k]:
            continue
        s, e = float(orig[spans[k][0]]), float(orig[spans[k][-1]])
        start[ui] = s if start[ui] is None else min(start[ui], s)
        end[ui] = e if end[ui] is None else max(end[ui], e)
    # unanchored moras (ー, ッ): share the interval with the previous anchored mora
    bounds = [None] * n
    i = 0
    while i < n:
        if start[i] is not None:
            bounds[i] = [start[i], end[i] + 1]
            i += 1
            continue
        j = i
        while j < n and start[j] is None:
            j += 1
        prev_end = end[i - 1] + 1 if i > 0 and end[i - 1] is not None else None
        nxt_start = start[j] if j < n else None
        if prev_end is not None and nxt_start is not None and nxt_start > prev_end:
            k = j - i
            step = (nxt_start - prev_end) / (k + 1)
            for q in range(k):
                bounds[i + q] = [prev_end + step * (q + 0.5), prev_end + step * (q + 1.5)]
            # the previous mora's vowel stretches over the first part
        i = j
    f0 = mst
    vals = np.full(n, np.nan)
    for i in range(n):
        if bounds[i] is None:
            continue
        a, b = bounds[i]
        # the vowel is the later part of the mora: use the last 65 %
        a2 = a + 0.35 * (b - a)
        ia, ib = int(max(0, round(a2))), int(min(len(f0), max(round(b), round(a2) + 1)))
        seg = f0[ia:ib]
        seg = seg[np.isfinite(seg)]
        if len(seg):
            vals[i] = float(np.median(seg))
    phrases = [a["phrase"] for a in acc]
    _log().info("mine_accent vals=%s bounds=%s", [None if not np.isfinite(v) else round(float(v), 1) for v in vals],
                [None if b is None else [round(b[0], 1), round(b[1], 1)] for b in bounds])
    return classify_high_low(vals, phrases)


def warmup_pitch():
    try:
        rng = np.random.default_rng(0)
        t = np.arange(SR) / SR
        x = (0.3 * np.sin(2 * np.pi * 180 * t) + 0.01 * rng.standard_normal(SR)).astype(np.float32)
        pitch_track(x)
        _feat(x, 0, 40)
    except Exception:
        _log().exception("pitch warmup failed")
