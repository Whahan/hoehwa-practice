# -*- coding: utf-8 -*-
"""Song study K2: lyrics <-> recognised-words alignment. Pure functions, standard library only.

No heavy imports (no torch / faster_whisper / numpy / pyopenjtalk): the caller (song.py, K5) passes
  * the recognised words from song_asr (K3):  [{"w": "feel", "s": 17.5, "e": 17.8, "p": 0.9}, ...]
    (faster-whisper names "word" "start" "end" "probability" are accepted too; "p" is optional)
  * the lyrics lines (POST /song/jobs ``lyrics.lines``): [{"text": "...", "t": 12.3 | None, "p": 0}, ...]
    a line may carry ``"tokens": [{"w": "君", "kata": "キミ"}]`` (K4 analysis; the output words then coincide with it)
  * ``reader``: optional ``callable(str) -> katakana str`` (server.ja_to_kata) for Japanese.
    Alignment of Japanese is done on the katakana reading, so 君 matches きみ when the reader knows it.
    Without a reader only kana (hiragana is folded to katakana) can match; kanji are compared as themselves.

Entry points (all return plain dicts, never raise for empty / odd input):
  align_lyrics(lyrics, asr_words, duration, lang, reader)   lyrics + recognised words -> timed lines
  lines_from_lrc(lyrics, duration, offset, lang, reader)    LRC line times -> timed lines (word times are estimates)
  estimate_lrc_offset(lyrics, asr_words, lang, reader)      sample check: offset = audio time - LRC time
  lines_from_asr(asr_words, duration, lang)                 no lyrics: build lines from the recognised words
  check_lines(lines, duration)                              output invariants (list of violations, [] = fine)

Output line (design 5.2 subset; K4 adds reading/pron/ko/lemma/level/zipf/content):
  {"i","p","t0","t1","text","conf","est","stale","words":[{"w","s","e","est"}]}
Anchor match rate = lyric units that were matched to a recognised unit / lyric units
(unit = word for English-like languages, kana character for Japanese).
"""
import difflib
import math
import re
import unicodedata
from bisect import bisect_left, bisect_right

# ---- constants -------------------------------------------------------------------------------------------------
LOW_MATCH = 0.4            # match rate below this -> "low_match" (+ "est_times")
NEAR_RATIO = 0.75          # English words this similar (difflib ratio) count as the same word (misrecognition)
JA_MIN_RUN = 3             # Japanese: a matched kana only counts when it is part of >= 3 consecutive matches
MAX_LINES = 400
MAX_LINE_CHARS = 200
MAX_OFFSET = 5.0           # |offset| limit (seconds), same as the UI slider
OFFSET_STEP = 0.05
OFFSET_SEARCH = 6.0        # +-seconds searched for an LRC offset
OFFSET_MIN_SUPPORT = 5     # fewer supporting lines -> offset 0
MIN_WORD_SEC = 0.02
MIN_LINE_SEC = 0.05
FULL_CELLS = 2_000_000     # DP cells before the alignment switches to a band around the diagonal
MIN_BAND = 150
_GAP = 0.3                 # skipping one unit on either side (ASR missed a word / sang an extra one)
_MISMATCH = -0.5           # different words facing each other (a misrecognition)
_NEG = -10 ** 9
_SEC_PER_WEIGHT = {"en": 0.07, "ja": 0.20}   # rough singing speed, only for estimates

_KATA_MAP = str.maketrans({
    "ヲ": "オ", "ヅ": "ズ", "ヂ": "ジ", "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ",
    "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ", "ヵ": "カ", "ヶ": "ケ", "ッ": "", "ー": "",
})
_HAN = re.compile(r"[㐀-䶿一-鿿豈-﫿々〆]")
_JA_RUNS = re.compile(r"[㐀-䶿一-鿿豈-﫿々〆]+|[ぁ-ゟ]+|[゠-ヿー]+|[A-Za-z0-9]+")
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_SENT_END = ("。", "！", "？", "!", "?", ".")


# ---- small helpers ---------------------------------------------------------------------------------------------
def _is_ja(lang):
    return str(lang or "").lower().startswith("ja")


def _num(v, default=None):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    return f if math.isfinite(f) else default


def _clean(text):
    s = unicodedata.normalize("NFKC", str(text if text is not None else ""))
    s = _CTRL.sub(" ", s)
    return re.sub(r"[ \t\r\n　]+", " ", s).strip()


def _fold_kana(s):
    return "".join(chr(ord(c) + 0x60) if 0x3041 <= ord(c) <= 0x3096 else c for c in s)


def _ja_key_chars(s):
    out = []
    for c in _fold_kana(s).translate(_KATA_MAP):
        o = ord(c)
        if 0x30A1 <= o <= 0x30FA:
            out.append(c)
        elif c.isalnum() and o < 0x250:
            out.append(c.lower())
        elif _HAN.match(c):
            out.append(c)
    return "".join(out)


def normalize_key(text, lang="en", reader=None):
    """Comparison key of one word. English-like: lower-case letters/digits only (apostrophes and punctuation gone).
    Japanese: katakana reading (reader if given and it answers, else kana folded to katakana; long marks and small
    tsu dropped, small kana widened); kanji without a reader stay as themselves."""
    s = _clean(text)
    if not s:
        return ""
    if _is_ja(lang):
        if reader is not None:
            try:
                r = reader(s)
            except Exception:
                r = ""
            if isinstance(r, str) and r.strip():
                k = _ja_key_chars(unicodedata.normalize("NFKC", r))
                if k:
                    return k
        return _ja_key_chars(s)
    return "".join(c for c in s.casefold() if c.isalnum())


def _strip_edges(tok):
    i, j = 0, len(tok)
    while i < j and not tok[i].isalnum():
        i += 1
    while j > i and not tok[j - 1].isalnum():
        j -= 1
    return tok[i:j]


def tokenize_line(text, lang="en", reader=None, tokens=None):
    """Words of one lyric line -> [{"w": surface, "key": comparison key}] (tokens without a key are dropped).
    ``tokens`` ([{"w", "kata"|"key"}], from K4) wins over the built-in splitter."""
    out = []
    if tokens:
        for tk in tokens:
            if isinstance(tk, str):
                tk = {"w": tk}
            if not isinstance(tk, dict):
                continue
            w = _clean(tk.get("w", ""))
            if _is_ja(lang):
                key = normalize_key(tk["kata"], lang) if tk.get("kata") else normalize_key(w, lang, reader)
            else:
                key = normalize_key(tk["key"], lang) if tk.get("key") else normalize_key(w, lang)
            if w and key:
                out.append({"w": w, "key": key})
        if out:
            return out
    s = _clean(text)
    if _is_ja(lang):
        for part in _JA_RUNS.findall(s):
            key = normalize_key(part, lang, reader)
            if key:
                out.append({"w": part, "key": key})
    else:
        for part in re.split(r"[\s—–]+", s):
            key = normalize_key(part, lang)
            if key:
                out.append({"w": _strip_edges(part) or part, "key": key})
    return out


def _r3(x):
    return round(float(x), 3)


# ---- recognised words ------------------------------------------------------------------------------------------
def sanitize_asr(words, duration=None, lang="en", reader=None):
    """Clean the recognised words: aliases (word/start/end/probability), drop bad items, sort by start, make the
    times monotone (each word starts at or after the previous one ended, minimum length 0.02 s), clip to
    [0, duration]. Returns [{"w","s","e","p","key"}] (words without a key are dropped)."""
    items = []
    for it in words or []:
        if not isinstance(it, dict):
            continue
        w = it.get("w", it.get("word"))
        s = _num(it.get("s", it.get("start")))
        e = _num(it.get("e", it.get("end")))
        if w is None or s is None or e is None:
            continue
        key = normalize_key(w, lang, reader)
        if not key:
            continue
        items.append({"w": _clean(w), "s": max(0.0, s), "e": max(0.0, e),
                      "p": _num(it.get("p", it.get("probability"))), "key": key})
    items.sort(key=lambda x: (x["s"], x["e"]))
    out = []
    prev_e = 0.0
    for it in items:
        s = max(it["s"], prev_e)
        e = max(it["e"], s + MIN_WORD_SEC)
        if duration is not None and s >= duration - MIN_WORD_SEC:
            break
        if duration is not None and e > duration:
            e = duration
            if e - s < 1e-6:
                break
        it["s"], it["e"] = s, e
        prev_e = e
        out.append(it)
    return out


# ---- lyrics preparation ----------------------------------------------------------------------------------------
def _prepare_lyrics(lyrics, lang, reader):
    """-> (records, warnings, markers). record: {"text","t","p","tokens","end_hint"}. Blank lines are skipped;
    a blank line that carries a time becomes the ``end_hint`` of the line before it (LRC end marker)."""
    recs, warns = [], []
    for item in lyrics or []:
        if isinstance(item, str):
            item = {"text": item}
        if not isinstance(item, dict):
            continue
        text = _clean(item.get("text", ""))[:MAX_LINE_CHARS]
        t = _num(item.get("t"))
        if not text:
            if t is not None and recs and recs[-1]["end_hint"] is None:
                recs[-1]["end_hint"] = t
            continue
        if len(recs) >= MAX_LINES:
            if "lyrics_truncated" not in warns:
                warns.append("lyrics_truncated")
            break
        p = item.get("p", 0)
        p = int(p) if isinstance(p, (int, float)) and not isinstance(p, bool) and math.isfinite(p) else 0
        toks = tokenize_line(text, lang, reader, item.get("tokens") if isinstance(item.get("tokens"), list) else None)
        recs.append({"text": text, "t": t, "p": max(0, p), "tokens": toks, "end_hint": None})
    return recs, warns


def _line_weight(rec, lang):
    if _is_ja(lang):
        return float(sum(len(t["key"]) for t in rec["tokens"]) or 1)
    return float(sum(len(t["key"]) + 1 for t in rec["tokens"]) or 1)


def _build_units(recs, lang):
    """Flatten the lyrics into alignment units. Returns (keys, weights, real, spans) where spans[li][ti] is the
    (first, last) unit of token ti and line_range[li] the (first, last) unit of the line (pseudo unit if no token)."""
    ja = _is_ja(lang)
    keys, weights, real = [], [], []
    spans, line_range = [], []
    for rec in recs:
        first = len(keys)
        sp = []
        for tk in rec["tokens"]:
            f = len(keys)
            if ja:
                for ch in tk["key"]:
                    keys.append(ch)
                    weights.append(1.0)
                    real.append(True)
            else:
                keys.append(tk["key"])
                weights.append(len(tk["key"]) + 1.0)
                real.append(True)
            sp.append((f, len(keys) - 1))
        if not sp:
            keys.append("")
            weights.append(1.0)
            real.append(False)
        spans.append(sp)
        line_range.append((first, len(keys) - 1))
    return keys, weights, real, spans, line_range


# ---- alignment -------------------------------------------------------------------------------------------------
def _near_map(lk, ak):
    """{lyric key: set(asr keys that are a likely misrecognition of it)} (English words only)."""
    la = {}
    for k in set(lk):
        if len(k) >= 3:
            la.setdefault((k[0], len(k)), []).append(k)
    ad = [k for k in set(ak) if len(k) >= 3]
    out = {}
    for b in ad:
        for a in set(lk):
            if a == b or len(a) < 3 or abs(len(a) - len(b)) > 3:
                continue
            if a[0] != b[0] and a[-1] != b[-1]:
                continue
            if difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() >= NEAR_RATIO:
                out.setdefault(a, set()).add(b)
    return out


def _align_dp(lk, ak, near):
    """Overlap alignment (free leading/trailing gaps) of two key lists. Returns [(i, j, kind)] with kind 2 = same,
    1 = near. Band around the diagonal when the table would be large."""
    n, m = len(lk), len(ak)
    if n == 0 or m == 0:
        return []
    w = max(n, m) if n * m <= FULL_CELLS else max(MIN_BAND, FULL_CELLS // (2 * n))
    lo_of = [0] * (n + 1)
    dirs = [None] * (n + 1)
    hi0 = min(m, w)
    prev = [0.0] * (hi0 + 1)
    plo = 0
    dirs[0] = bytearray([2]) * (hi0 + 1)
    best = (_NEG, 0, 0)
    for i in range(1, n + 1):
        c = (i * m) // n
        lo, hi = max(0, c - w), min(m, c + w)
        phi = plo + len(prev) - 1
        cur = [_NEG] * (hi - lo + 1)
        dr = bytearray(hi - lo + 1)
        a = lk[i - 1]
        nm = near.get(a) if near else None
        for j in range(lo, hi + 1):
            if j == 0:
                cur[0] = 0.0
                dr[0] = 1
                continue
            bv, bd = _NEG, 0
            if plo <= j - 1 <= phi:
                b = ak[j - 1]
                sc = 2.0 if a == b else (1.0 if (nm is not None and b in nm) else _MISMATCH)
                bv = prev[j - 1 - plo] + sc
            if plo <= j <= phi:
                v = prev[j - plo] - _GAP
                if v > bv:
                    bv, bd = v, 1
            if j > lo:
                v = cur[j - 1 - lo] - _GAP
                if v > bv:
                    bv, bd = v, 2
            cur[j - lo] = bv
            dr[j - lo] = bd
            if (j == m or i == n) and bv >= best[0]:
                best = (bv, i, j)
        lo_of[i] = lo
        dirs[i] = dr
        prev, plo = cur, lo
    _, i, j = best
    if i == 0:
        return []
    matches = []
    while i > 0 and j > 0:
        d = dirs[i][j - lo_of[i]]
        if d == 0:
            a, b = lk[i - 1], ak[j - 1]
            if a == b:
                matches.append((i - 1, j - 1, 2))
            elif near and b in near.get(a, ()):
                matches.append((i - 1, j - 1, 1))
            i -= 1
            j -= 1
        elif d == 1:
            i -= 1
        else:
            j -= 1
    matches.reverse()
    return matches


def _filter_runs(matches, min_run):
    if min_run <= 1 or not matches:
        return matches
    out, run = [], [matches[0]]

    def flush():
        if len(run) >= min_run:
            out.extend(run)

    for mt in matches[1:]:
        if mt[0] == run[-1][0] + 1 and mt[1] == run[-1][1] + 1:
            run.append(mt)
        else:
            flush()
            run = [mt]
    flush()
    return out


def _asr_units(asr, lang):
    """Recognised words -> alignment units: [(key, s, e, asr_index)]. Japanese words are cut into kana characters
    sharing the word's time evenly."""
    if not _is_ja(lang):
        return [(w["key"], w["s"], w["e"], ai) for ai, w in enumerate(asr)]
    out = []
    for ai, w in enumerate(asr):
        k = w["key"]
        n = len(k)
        for m, ch in enumerate(k):
            out.append((ch, w["s"] + (w["e"] - w["s"]) * m / n, w["s"] + (w["e"] - w["s"]) * (m + 1) / n, ai))
    return out


# ---- time placement --------------------------------------------------------------------------------------------
def _distribute(out, weights, i0, i1, t0, t1):
    """Spread units i0..i1 over [t0, t1] proportionally to their weights."""
    if i1 < i0:
        return
    if t1 < t0:
        t1 = t0
    total = sum(weights[i0:i1 + 1]) or 1.0
    acc = 0.0
    for i in range(i0, i1 + 1):
        s = t0 + (t1 - t0) * acc / total
        acc += weights[i]
        out[i] = [s, t0 + (t1 - t0) * acc / total]


def _place(weights, anchors, span_lo, span_hi, duration):
    """Times of every unit. anchors {unit: (s, e)} are kept; units between anchors share the gap; units before the
    first / after the last anchor are extrapolated at the average speed (squeezed to fit [0, duration]).
    Without anchors everything is spread over [span_lo, span_hi]."""
    n = len(weights)
    out = [None] * n
    if not anchors:
        _distribute(out, weights, 0, n - 1, span_lo, span_hi)
        return out
    idx = sorted(anchors)
    for i in idx:
        out[i] = [anchors[i][0], anchors[i][1]]
    for a, b in zip(idx, idx[1:]):
        if b > a + 1:
            _distribute(out, weights, a + 1, b - 1, out[a][1], out[b][0])
    first, last = idx[0], idx[-1]
    span_w = sum(weights[first:last + 1]) or 1.0
    spd = (out[last][1] - out[first][0]) / span_w
    spd = min(0.6, max(0.01, spd))
    if first > 0:
        end = out[first][0]
        need = sum(weights[:first]) * spd
        _distribute(out, weights, 0, first - 1, end - need if need <= end else 0.0, end)
    if last < n - 1:
        start = out[last][1]
        need = sum(weights[last + 1:]) * spd
        _distribute(out, weights, last + 1, n - 1, start, start + need if start + need <= duration else duration)
    return out


def _finalize(recs, spans, line_range, times, unit_anchored, duration, extra=None):
    """Units' times -> output lines (token words, line t0/t1) with the invariants enforced."""
    lines = []
    prev_t0 = 0.0
    for li, rec in enumerate(recs):
        f, l = line_range[li]
        t0 = times[f][0]
        t1 = times[l][1]
        words = []
        for ti, tk in enumerate(rec["tokens"]):
            a, b = spans[li][ti]
            cnt = b - a + 1
            hit = sum(1 for u in range(a, b + 1) if unit_anchored[u])
            words.append({"w": tk["w"], "s": times[a][0], "e": times[b][1], "est": hit * 2 < cnt})
        t0 = min(max(t0, prev_t0, 0.0), max(0.0, duration - MIN_LINE_SEC))
        t1 = min(max(t1, t0 + MIN_LINE_SEC), duration)
        if t1 <= t0:
            t0 = max(0.0, t1 - MIN_LINE_SEC)
        ps = t0
        for wd in words:
            s = min(max(wd["s"], t0, ps), t1)
            e = min(max(wd["e"], s), t1)
            wd["s"], wd["e"], ps = _r3(s), _r3(e), s
        line = {"i": li, "p": rec["p"], "t0": _r3(t0), "t1": _r3(t1), "text": rec["text"], "conf": None,
                "est": all(w["est"] for w in words) if words else True, "stale": False, "words": words}
        if extra:
            line.update(extra(li))
        lines.append(line)
        prev_t0 = t0
    for ln in lines:                       # rounding must not break t0 < t1
        if ln["t1"] <= ln["t0"]:
            ln["t1"] = _r3(min(duration, ln["t0"] + MIN_LINE_SEC))
            if ln["t1"] <= ln["t0"]:
                ln["t0"] = _r3(max(0.0, ln["t1"] - MIN_LINE_SEC))
    return lines


def _raw_end(words):
    """Largest finite end time among the raw recognised words (0.0 if none)."""
    best = 0.0
    for it in words or []:
        if isinstance(it, dict):
            e = _num(it.get("e", it.get("end")))
            if e is not None and e > best:
                best = e
    return best


def _duration(duration, raw_end=0.0):
    d = _num(duration)
    if d is None or d <= 0:
        d = raw_end + 1.0 if raw_end > 0 else 1.0
    return d


# ---- public: lyrics + recognised words -------------------------------------------------------------------------
def align_lyrics(lyrics, asr_words, duration, lang="en", reader=None):
    """Align the lyrics to the recognised words. Matched units take the recognised time; the rest is interpolated
    (est True). Returns {"lines","match_rate","anchored","total","line_match","timing","warnings"}."""
    recs, warns = _prepare_lyrics(lyrics, lang, reader)
    raw_end = _raw_end(asr_words)
    dur = _duration(duration, raw_end)
    asr = sanitize_asr(asr_words, dur, lang, reader)
    if not recs:
        return {"lines": [], "match_rate": 0.0, "anchored": 0, "total": 0, "line_match": [], "timing": "est",
                "warnings": warns}
    keys, weights, real, spans, line_range = _build_units(recs, lang)
    au = _asr_units(asr, lang)
    ak = [u[0] for u in au]
    ja = _is_ja(lang)
    near = {} if ja else _near_map(keys, ak)
    matches = _align_dp(keys, ak, near)
    matches = _filter_runs(matches, JA_MIN_RUN if ja else 1)
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
    times = _place(weights, anchors, span_lo, span_hi, dur)
    line_match = []
    for li, (f, l) in enumerate(line_range):
        n_real = sum(real[f:l + 1])
        line_match.append(round(sum(1 for u in range(f, l + 1) if real[u] and anchored[u]) / n_real, 3) if n_real else 0.0)
    lines = _finalize(recs, spans, line_range, times, anchored, dur, lambda li: {})
    for ln in lines:
        ln["est"] = ln["est"] or all(w["est"] for w in ln["words"])
    if not asr and "no_vocals" not in warns:
        warns.append("no_vocals")
    if rate < LOW_MATCH:
        for w in ("low_match", "est_times"):
            if w not in warns:
                warns.append(w)
    if raw_end > dur + 2.0:
        warns.append("duration_mismatch")
    return {"lines": lines, "match_rate": round(rate, 4), "anchored": hit, "total": total, "line_match": line_match,
            "timing": "word" if rate >= LOW_MATCH else "est", "warnings": warns}


# ---- public: LRC line times ------------------------------------------------------------------------------------
def lines_from_lrc(lyrics, duration, offset=0.0, lang="en", reader=None, offset_guessed=False):
    """Lines from LRC start times (+ offset). Line end = next start (capped by a length estimate or a blank-line
    end marker); words share the line evenly by length (est True). Lines without a time are interpolated."""
    recs, warns = _prepare_lyrics(lyrics, lang, reader)
    dur = _duration(duration)
    if not recs:
        return {"lines": [], "timing": "line", "warnings": warns}
    off = _num(offset, 0.0)
    wts = [_line_weight(r, lang) for r in recs]
    spd = _SEC_PER_WEIGHT["ja" if _is_ja(lang) else "en"]
    known = [i for i, r in enumerate(recs) if r["t"] is not None]
    spread = not known
    t = [None] * len(recs)
    if known:
        for i in known:
            t[i] = recs[i]["t"]
        run = [t[i] for i in known]
        if max(run) > dur + 2.0:
            warns.append("duration_mismatch")
        for a, b in zip(known, known[1:]):
            if b > a + 1:
                tot = sum(wts[a:b]) or 1.0
                acc = 0.0
                for k in range(a + 1, b):
                    acc += wts[k - 1]
                    t[k] = t[a] + (t[b] - t[a]) * acc / tot
        f0, l0 = known[0], known[-1]
        acc = 0.0
        for k in range(f0 - 1, -1, -1):
            acc += wts[k] * spd
            t[k] = max(0.0, t[f0] - acc)
        acc = wts[l0] * spd
        for k in range(l0 + 1, len(recs)):
            t[k] = t[l0] + acc
            acc += wts[k] * spd
    else:
        tot = sum(wts)
        acc = 0.0
        for k in range(len(recs)):
            t[k] = dur * acc / tot
            acc += wts[k]
    starts, prev = [], 0.0
    for v in t:
        v = min(max(v + off, 0.0, prev), max(0.0, dur - MIN_LINE_SEC))
        starts.append(v)
        prev = v
    times, anch = [], []
    spans, line_range = [], []
    for li, rec in enumerate(recs):
        t0 = starts[li]
        nxt = starts[li + 1] if li + 1 < len(recs) else dur
        est_len = max(1.5, min(12.0, wts[li] * spd))
        hint = rec["end_hint"]
        cap = (hint + off) if hint is not None else (dur if spread else t0 + est_len * 1.6)
        t1 = min(nxt, cap, dur)
        t1 = min(max(t1, t0 + MIN_LINE_SEC), dur)
        toks = rec["tokens"]
        sp = []
        first = len(times)
        if toks:
            ws = [float(len(tk["key"]) + 1) for tk in toks]
            buf = [None] * len(toks)
            _distribute(buf, ws, 0, len(toks) - 1, t0, t1)
            for k, tm in enumerate(buf):
                times.append(tm)
                anch.append(False)
                sp.append((first + k, first + k))
        else:
            times.append([t0, t1])
            anch.append(False)
        spans.append(sp)
        line_range.append((first, len(times) - 1))
    lines = _finalize(recs, spans, line_range, times, anch, dur)
    for ln in lines:
        ln["est"] = False        # the line time itself is given (words are est)
    if offset_guessed and abs(off) > 1e-9 and "offset_guess" not in warns:
        warns.append("offset_guess")
    if "est_times" not in warns:
        warns.append("est_times")
    return {"lines": lines, "timing": "line", "warnings": warns}


def _round_step(x, step):
    return round(round(x / step) * step, 4)


def estimate_lrc_offset(lyrics, asr_words, lang="en", reader=None):
    """Sample check for LRC lyrics. ``asr_words`` may come from a few short windows only.
    offset = audio time - LRC time (add it to the LRC times); 0.0 when fewer than 5 lines support one value.
    Returns {"offset","support","used","in_sample","sample_match"}.
    Method: the first few words (Japanese: kana pairs) of every timed line vote with (recognised time - expected
    time) for every same word within +-6 s; the densest +-0.2 s cluster wins, its median is rounded to 0.05."""
    recs, _ = _prepare_lyrics(lyrics, lang, reader)
    asr = sanitize_asr(asr_words, None, lang, reader)
    zero = {"offset": 0.0, "support": 0, "used": 0, "in_sample": 0, "sample_match": 0.0}
    timed = [(li, r) for li, r in enumerate(recs) if r["t"] is not None]
    if not timed or not asr:
        return zero
    ja = _is_ja(lang)
    spd = _SEC_PER_WEIGHT["ja" if ja else "en"]
    index = {}
    if ja:
        stream = [(ch, s) for ch, s, _e, _ai in _asr_units(asr, lang)]
        for k in range(len(stream) - 1):
            index.setdefault(stream[k][0] + stream[k + 1][0], []).append(stream[k][1])
    else:
        for w in asr:
            if len(w["key"]) >= 4:
                index.setdefault(w["key"], []).append(w["s"])
    a_times = sorted(w["s"] for w in asr)
    votes, per_line = [], {}
    in_sample = 0
    for li, rec in timed:
        t = rec["t"]
        if any(abs(x - t) <= OFFSET_SEARCH for x in a_times):
            in_sample += 1
        items = []
        if ja:
            chars = "".join(tk["key"] for tk in rec["tokens"])
            items = [(chars[k:k + 2], k * spd) for k in range(len(chars) - 1)][:6]
        else:
            acc = 0.0
            for tk in rec["tokens"]:
                if len(tk["key"]) >= 4:
                    items.append((tk["key"], acc * spd))
                acc += len(tk["key"]) + 1
            items = items[:4]
        for key, rel in items:
            exp = t + rel
            for at in index.get(key, ()):
                d = at - exp
                if abs(d) <= OFFSET_SEARCH:
                    votes.append((d, li))
                    per_line[li] = per_line.get(li, 0) + 1
    res = dict(zero, used=len(per_line), in_sample=in_sample)
    res["sample_match"] = round(len(per_line) / in_sample, 3) if in_sample else 0.0
    if not votes:
        return res
    ds = sorted(d for d, _ in votes)
    best_d, best_c = 0.0, -1
    for d in ds:
        c = bisect_right(ds, d + 0.2) - bisect_left(ds, d - 0.2)
        if c > best_c or (c == best_c and abs(d) < abs(best_d)):
            best_d, best_c = d, c
    members = [d for d in ds if abs(d - best_d) <= 0.4]
    mid = len(members) // 2
    med = members[mid] if len(members) % 2 else (members[mid - 1] + members[mid]) / 2.0
    off = max(-MAX_OFFSET, min(MAX_OFFSET, _round_step(med, OFFSET_STEP)))
    sup = len({li for d, li in votes if abs(d - off) <= 0.4})
    res["support"] = sup
    if sup >= OFFSET_MIN_SUPPORT and sup * 2 >= len(per_line):
        res["offset"] = off
    return res


# ---- public: no lyrics, lines from the recognised words ---------------------------------------------------------
def lines_from_asr(asr_words, duration, lang="en"):
    """Group the recognised words into lines (pause >= 0.8 s, sentence end, or 12 words / 24 kana); a pause >= 3 s
    starts a new stanza. conf = mean word probability. Word times are the recognised ones (est False)."""
    ja = _is_ja(lang)
    dur = _duration(duration, _raw_end(asr_words))
    asr = sanitize_asr(asr_words, dur, lang)
    warns = []
    if not asr or sum(w["e"] - w["s"] for w in asr) < 1.0:
        warns.append("no_vocals")
    if not asr:
        return {"lines": [], "timing": "word", "warnings": warns}
    groups, cur = [], []
    for w in asr:
        if cur:
            gap = w["s"] - cur[-1]["e"]
            size = sum(len(x["key"]) for x in cur) if ja else len(cur)
            end = cur[-1]["w"].endswith(_SENT_END) and (size >= (6 if ja else 3))
            if gap >= 0.8 or end or size >= (24 if ja else 12):
                groups.append((cur, gap))
                cur = []
        cur.append(w)
    groups.append((cur, 0.0))
    lines, p = [], 0
    for gi, (g, gap_after) in enumerate(groups):
        text = ("" if ja else " ").join(x["w"] for x in g).strip()
        ps = [x["p"] for x in g if x["p"] is not None]
        t0, t1 = g[0]["s"], g[-1]["e"]
        t1 = max(t1, t0 + MIN_LINE_SEC)
        ws = [{"w": (_strip_edges(x["w"]) or x["w"]), "s": _r3(x["s"]), "e": _r3(min(max(x["e"], x["s"]), t1)),
               "est": False} for x in g]
        lines.append({"i": gi, "p": p, "t0": _r3(t0), "t1": _r3(min(t1, dur)), "text": text,
                      "conf": round(sum(ps) / len(ps), 3) if ps else None, "est": False, "stale": False, "words": ws})
        if gap_after >= 3.0:
            p += 1
    return {"lines": lines, "timing": "word", "warnings": warns}


# ---- invariants ------------------------------------------------------------------------------------------------
def check_lines(lines, duration):
    """Design 8 K2-7: 0 <= t0 < t1 <= duration, t0 ascending, words inside [t0, t1] with s <= e and monotone.
    Returns a list of violation strings ([] = fine)."""
    bad = []
    prev = -1.0
    for n, ln in enumerate(lines or []):
        try:
            t0, t1 = float(ln["t0"]), float(ln["t1"])
        except (KeyError, TypeError, ValueError):
            bad.append("line %d: no t0/t1" % n)
            continue
        if not (0.0 <= t0 < t1 <= duration + 1e-6):
            bad.append("line %d: need 0 <= t0 < t1 <= %.3f, got %.3f %.3f" % (n, duration, t0, t1))
        if t0 < prev - 1e-9:
            bad.append("line %d: t0 not ascending" % n)
        prev = t0
        ps = -1.0
        for k, w in enumerate(ln.get("words", [])):
            s, e = w.get("s"), w.get("e")
            if s is None or e is None or s > e + 1e-9:
                bad.append("line %d word %d: s > e" % (n, k))
                continue
            if s < t0 - 1e-6 or e > t1 + 1e-6:
                bad.append("line %d word %d: outside the line" % (n, k))
            if s < ps - 1e-9:
                bad.append("line %d word %d: not monotone" % (n, k))
            ps = s
    return bad
