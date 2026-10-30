# -*- coding: utf-8 -*-
"""Song study K3: windowed Whisper transcription of a song (design 3.3 / 3.6).

Pure orchestration around an injected faster-whisper model, so it can be tested with a fake model:

    res = transcribe_song(audio, "en", model, run_lock=server._stt_run_lock, window_sec=30,
                          hint_mode="window30", lyrics_lines=["...", "..."], vad=False,
                          progress=lambda done, total, eta: ..., cancel=job.cancel_event)
    res["words"]     -> [{"w": "feel", "s": 17.5, "e": 17.8, "p": 0.91}, ...]   (song_align.align_lyrics input)
    res["segments"]  -> [{"text", "s", "e", "p", "n"}]  (after hallucination removal)
    res["warnings"]  -> ["hallucination_cut", "no_vocals", ...]

  * The audio (float32, 16 kHz mono) is cut into windows of ``window_sec`` (30 s GPU / 20 s CPU). Each cut is the
    quietest 50 ms frame in the 3 s before the requested point. Every sample lies in exactly one window.
  * ``run_lock`` is taken once per window (never across windows), so ``/score`` can run between two windows.
  * Short lines the model itself marks as "no speech" (no_speech_prob >= 0.8, < 8 words) are dropped: Whisper writes
    "thanks for watching" style text over music-only input.
  * Short lines the model itself marks as "no speech" (no_speech_prob >= 0.8, < 8 words) are dropped: Whisper writes
    "thanks for watching" style text over music-only input.
  * ``cancel`` (callable returning True, or an object with ``is_set()``) is checked before every window and right after
    it; ``Cancelled`` is raised with the lock released.
  * Nothing here imports ``server`` or touches ``config.json``. ``faster_whisper`` is imported lazily and only by
    ``load_whisper`` / ``decode_file`` (the bench and K5 use them; the tests do not).
"""
import re
import threading
import time
import unicodedata

import numpy as np

SR = 16000
WINDOW_GPU = 30.0
WINDOW_CPU = 20.0
BOUNDARY_SEARCH = 3.0          # the cut is the quietest frame within this many seconds BEFORE the requested point
FRAME_SEC = 0.05               # energy frame length
HOP_SEC = 0.01                 # candidate cut spacing
SILENT_PEAK = 0.003            # a window whose peak is below this is skipped (same threshold as server.transcribe)
HALLU_RUN = 3                  # the same line this many times in a row -> keep the first only
LOW_P = 0.35                   # a line of < 2 words with a mean word probability below this is dropped
MIN_WORDS = 2
NSP_DROP = 0.8                 # a short line (< NSP_MAX_WORDS words) whose no_speech_prob is >= this is music noise ("ご視聴...")
NSP_MAX_WORDS = 8
MIN_VOCAL_SEC = 1.0            # fewer recognised seconds than this -> no_vocals
HINT_MODES = ("none", "first150", "window30")
HINT_FIRST = 150
HINT_WINDOW = 30

# faster-whisper settings (design 3.3). vad_filter / initial_prompt are added per call.
TRANSCRIBE_OPTS = dict(
    task="transcribe",
    beam_size=5,
    temperature=(0.0, 0.2, 0.4),
    word_timestamps=True,
    condition_on_previous_text=False,
    no_speech_threshold=0.5,
    compression_ratio_threshold=2.0,
    hallucination_silence_threshold=1.5,
)


class Cancelled(Exception):
    """The job was cancelled between two windows (the run lock is free when this is raised)."""


# ---- model helpers (lazy heavy imports) -----------------------------------------------------------------------------
def pick_model_name(cfg):
    """Model name for songs: optional ``cfg["song"]["model"]`` (e.g. "medium"), else ``cfg["stt"]["model"]``.
    Read only: nothing is written into the config."""
    cfg = cfg if isinstance(cfg, dict) else {}
    song = cfg.get("song")
    if isinstance(song, dict) and isinstance(song.get("model"), str) and song["model"].strip():
        return song["model"].strip()
    stt = cfg.get("stt")
    if isinstance(stt, dict) and isinstance(stt.get("model"), str) and stt["model"].strip():
        return stt["model"].strip()
    return "small"


def window_for_device(device):
    return WINDOW_GPU if str(device or "").lower().startswith("cuda") else WINDOW_CPU


def add_cuda_dll_dirs():
    """cuBLAS 12 / cuDNN 9 DLLs from the pip wheels (needed by ctranslate2 on Windows); same lookup as server.py.
    server.py already does this at import, so this only matters for stand-alone use (the bench)."""
    import os
    import site
    try:
        for sp in site.getsitepackages():
            for sub in ("cublas", "cudnn", "cuda_nvrtc"):
                b = os.path.join(sp, "nvidia", sub, "bin")
                if os.path.isdir(b):
                    os.add_dll_directory(b)
                    os.environ["PATH"] = b + os.pathsep + os.environ.get("PATH", "")
    except Exception:
        pass


def load_whisper(name, device, compute_type, download_root, local_files_only=True):
    """Same loader as server._load_whisper (model files are only read; never downloaded when local_files_only)."""
    if str(device).startswith("cuda"):
        add_cuda_dll_dirs()
    from faster_whisper import WhisperModel
    return WhisperModel(name, device=device, compute_type=compute_type, download_root=download_root,
                        local_files_only=local_files_only)


def decode_file(path):
    """Any audio file -> float32 mono 16 kHz (PyAV through faster-whisper)."""
    from faster_whisper.audio import decode_audio
    return np.asarray(decode_audio(path, sampling_rate=SR), dtype=np.float32)


# ---- windows ---------------------------------------------------------------------------------------------------------
def _quietest_center(audio, lo, hi, fr, hop):
    """Sample index of the centre of the quietest ``fr``-sample frame whose centre lies in [lo, hi]; ties -> the latest."""
    a = max(0, lo - fr // 2)
    b = min(len(audio), hi + fr // 2 + 1)
    seg = np.asarray(audio[a:b], dtype=np.float64)
    if len(seg) < fr:
        return min(max(lo, 0), hi)
    cs = np.concatenate(([0.0], np.cumsum(seg * seg)))
    starts = np.arange(0, len(seg) - fr + 1, hop)
    energy = cs[starts + fr] - cs[starts]
    centers = a + starts + fr // 2
    ok = (centers >= lo) & (centers <= hi)
    if not ok.any():
        return min(max(lo, 0), hi)
    idx = np.nonzero(ok)[0]
    e = energy[idx]
    best = idx[len(e) - 1 - int(np.argmin(e[::-1]))]
    return int(centers[best])


def plan_windows(audio, window_sec=WINDOW_GPU, search_sec=BOUNDARY_SEARCH, sr=SR, frame_sec=FRAME_SEC, hop_sec=HOP_SEC):
    """[(start_sample, end_sample), ...] covering [0, len(audio)) exactly once, contiguous. Every cut is the quietest
    frame in [requested - search_sec, requested] where requested = previous cut + window_sec. Empty audio -> []."""
    if window_sec <= search_sec:
        raise ValueError("window_sec must be larger than search_sec")
    n = len(audio)
    if n <= 0:
        return []
    w = int(round(window_sec * sr))
    s = int(round(search_sec * sr))
    fr = max(1, int(round(frame_sec * sr)))
    hop = max(1, int(round(hop_sec * sr)))
    out, start = [], 0
    while n - start > w:
        target = start + w
        cut = _quietest_center(audio, target - s, target, fr, hop)
        cut = min(max(cut, start + 1), target)
        out.append((start, cut))
        start = cut
    out.append((start, n))
    return out


# ---- hints (initial_prompt) ------------------------------------------------------------------------------------------
def _is_ja(lang):
    return str(lang or "").lower().startswith("ja")


def _hint_units(lyrics_lines, lang):
    """Lyric words (English-like) or characters (Japanese), original spelling, in order."""
    text = "\n".join(str(x) for x in (lyrics_lines or []) if x)
    if _is_ja(lang):
        return [c for c in unicodedata.normalize("NFKC", text) if not c.isspace()]
    return text.split()


_KEY_STRIP = re.compile(r"[^\w]+", re.UNICODE)


def _unit_key(u):
    return _KEY_STRIP.sub("", unicodedata.normalize("NFKC", u).lower().replace("'", ""))


def _join_units(units, lang):
    return ("" if _is_ja(lang) else " ").join(units)


def _advance_pointer(keys, ptr, recognised, lang):
    """Move the pointer in the lyric key list after a window: each recognised unit is looked up a few units ahead."""
    look = 15 if _is_ja(lang) else 10
    pos = ptr
    for r in recognised:
        k = _unit_key(r)
        if not k:
            continue
        for j in range(pos, min(len(keys), pos + look)):
            if keys[j] == k:
                pos = j + 1
                break
    return pos


def _units_of_words(words, lang):
    if _is_ja(lang):
        return [c for w in words for c in unicodedata.normalize("NFKC", w["w"]) if not c.isspace()]
    return [w["w"] for w in words]


# ---- hallucination removal -------------------------------------------------------------------------------------------
def _seg_key(text):
    return _KEY_STRIP.sub("", unicodedata.normalize("NFKC", text or "").lower())


def clean_segments(segments):
    """Design 3.3: the same line text 3+ times in a row -> only the first stays (+ ``hallucination_cut``); a line of
    fewer than 2 words with a mean word probability < 0.35 is dropped. Returns (segments, warnings)."""
    warns = []
    kept = []
    i = 0
    n = len(segments)
    while i < n:
        key = _seg_key(segments[i]["text"])
        j = i + 1
        while j < n and key and _seg_key(segments[j]["text"]) == key:
            j += 1
        if j - i >= HALLU_RUN:
            kept.append(segments[i])
            if "hallucination_cut" not in warns:
                warns.append("hallucination_cut")
        else:
            kept.extend(segments[i:j])
        i = j
    out = []
    for seg in kept:
        ps = [w["p"] for w in seg["words"] if w.get("p") is not None]
        mean_p = sum(ps) / len(ps) if ps else 0.0
        if len(seg["words"]) < MIN_WORDS and mean_p < LOW_P:
            continue
        nsp = seg.get("nsp")
        if nsp is not None and nsp >= NSP_DROP and len(seg["words"]) < NSP_MAX_WORDS:
            continue
        out.append(seg)
    return out, warns


# ---- Japanese: reading of a word in the context of its line ---------------------------------------------------------------
def contextual_readings(texts, reader):
    """Katakana reading of every token of ONE line, taken in context: reading(tokens[:i+1]) minus reading(tokens[:i]).
    Whisper cuts Japanese into single characters / short pieces; reading each piece alone is wrong (窓+辺 -> マド+ヘン
    instead of マド+ベ, 椅+子 -> ハシ+コ instead of イス), which made the alignment match rate fall to ~0.7 in S0.
    The pieces always add up to the reading of the whole line. When a longer prefix reads differently from the shorter
    one (椅 -> ハシ, 椅子 -> イス), the earlier pieces are corrected and the new reading lands on the later tokens.
    Returns a list of katakana strings (possibly "" for punctuation)."""
    pieces, prev = [], ""
    for i in range(len(texts)):
        try:
            cur = reader("".join(texts[:i + 1])) or ""
        except Exception:
            cur = prev
        if cur.startswith(prev):
            pieces.append(cur[len(prev):])
        else:
            k = 0
            while k < min(len(cur), len(prev)) and cur[k] == prev[k]:
                k += 1
            m, pos = 0, 0
            while m < len(pieces) and pos + len(pieces[m]) <= k:
                pos += len(pieces[m])
                m += 1
            if m < len(pieces):
                pieces[m] = cur[pos:k]
                for q in range(m + 1, len(pieces)):
                    pieces[q] = ""
            pieces.append(cur[k:])
        prev = cur
    return pieces


def add_kana_readings(segments, reader):
    """sets word["k"] (katakana, in context of its line) on every word of every segment (dicts with a "words" list)."""
    for sg in segments:
        ks = contextual_readings([w["w"] for w in sg["words"]], reader)
        for w, k in zip(sg["words"], ks):
            w["k"] = k


# ---- the transcription -----------------------------------------------------------------------------------------------
def _is_cancelled(cancel):
    if cancel is None:
        return False
    if callable(cancel):
        return bool(cancel())
    is_set = getattr(cancel, "is_set", None)
    return bool(is_set()) if callable(is_set) else bool(cancel)


def _seg_record(seg, offset, win_len_sec):
    words = []
    for w in (getattr(seg, "words", None) or []):
        t = str(getattr(w, "word", "") or "").strip()
        if not t:
            continue
        s = min(max(float(getattr(w, "start", 0.0)), 0.0), win_len_sec)
        e = min(max(float(getattr(w, "end", s)), s), win_len_sec)
        p = getattr(w, "probability", None)
        p = None if p is None else round(float(min(1.0, max(0.0, p))), 4)
        words.append({"w": t, "s": round(offset + s, 3), "e": round(offset + e, 3), "p": p})
    if not words:
        return None
    ps = [w["p"] for w in words if w["p"] is not None]
    nsp = getattr(seg, "no_speech_prob", None)
    return {"text": str(getattr(seg, "text", "") or "").strip(), "s": words[0]["s"], "e": words[-1]["e"],
            "p": round(sum(ps) / len(ps), 4) if ps else None, "n": len(words), "words": words,
            "nsp": None if nsp is None else float(nsp)}


def transcribe_song(audio, lang, model, run_lock=None, *, window_sec=None, device="cuda", hint_mode="none",
                    lyrics_lines=None, vad=False, progress=None, cancel=None, sr=SR, opts=None, reader=None):
    """Transcribe ``audio`` (float32 mono, ``sr`` Hz) window by window. See the module docstring.

    reader: optional ``callable(str) -> katakana`` (server.ja_to_kata); for Japanese every word then also carries "k", its
    reading in the context of its line (see contextual_readings).
    progress(done, total, eta_sec): after every window; eta_sec is None for the first 2 windows.
    Raises Cancelled between windows. Returns {"words","segments","duration","windows","warnings","timing"}."""
    if hint_mode not in HINT_MODES:
        raise ValueError("hint_mode must be one of %s" % (HINT_MODES,))
    audio = np.asarray(audio, dtype=np.float32)
    if window_sec is None:
        window_sec = window_for_device(device)
    lock = run_lock if run_lock is not None else threading.Lock()
    duration = len(audio) / float(sr)
    wins = plan_windows(audio, window_sec, BOUNDARY_SEARCH, sr)
    total = len(wins)
    base = dict(TRANSCRIBE_OPTS)
    base.update(opts or {})
    base["language"] = lang
    base["vad_filter"] = bool(vad)
    units = _hint_units(lyrics_lines, lang) if hint_mode != "none" else []
    keys = [_unit_key(u) for u in units]
    ptr = 0
    segments = []
    times, skipped, audio_done = [], 0, 0.0      # audio_done: seconds of audio that really went to the model
    t_all = time.time()
    if progress:
        progress(0, total, None)
    for wi, (a, b) in enumerate(wins):
        if _is_cancelled(cancel):
            raise Cancelled()
        chunk = np.ascontiguousarray(audio[a:b])
        recognised = []
        if len(chunk) < 1600 or float(np.max(np.abs(chunk))) < SILENT_PEAK:
            skipped += 1
        else:
            call = dict(base)
            if hint_mode == "first150":
                call["initial_prompt"] = _join_units(units[:HINT_FIRST], lang) or None
            elif hint_mode == "window30":
                call["initial_prompt"] = _join_units(units[ptr:ptr + HINT_WINDOW], lang) or None
            else:
                call["initial_prompt"] = None
            t0 = time.time()
            with lock:
                segs, _info = model.transcribe(chunk, **call)
                segs = list(segs)
            times.append(time.time() - t0)
            audio_done += len(chunk) / float(sr)
            off = a / float(sr)
            wlen = (b - a) / float(sr)
            for sg in segs:
                rec = _seg_record(sg, off, wlen)
                if rec:
                    segments.append(rec)
                    recognised.extend(rec["words"])
            if hint_mode == "window30" and keys:
                ptr = _advance_pointer(keys, ptr, _units_of_words(recognised, lang), lang)
        if _is_cancelled(cancel):
            raise Cancelled()
        done = wi + 1
        if progress:
            eta = None
            if done >= 2 and times and audio_done > 0:
                rest = sum(w[1] - w[0] for w in wins[done:]) / float(sr)      # seconds of audio still to do
                eta = round(sum(times) / audio_done * rest, 1)
            progress(done, total, eta)
    segments.sort(key=lambda g: (g["s"], g["e"]))
    segments, warns = clean_segments(segments)
    if reader is not None and _is_ja(lang):
        add_kana_readings(segments, reader)
    words = [dict(w) for g in segments for w in g["words"]]
    words.sort(key=lambda w: (w["s"], w["e"]))
    for g in segments:
        g.pop("words", None)
        g.pop("nsp", None)
    if sum(w["e"] - w["s"] for w in words) < MIN_VOCAL_SEC:
        warns.append("no_vocals")
    return {"words": words, "segments": segments, "duration": round(duration, 3), "windows": total, "warnings": warns,
            "timing": {"asr_sec": round(time.time() - t_all, 3), "window_sec": [round(x, 3) for x in times],
                       "skipped_windows": skipped}}
