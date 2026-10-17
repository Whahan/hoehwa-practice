# -*- coding: utf-8 -*-
"""Practice API (v1.1): shadowing / dictation sentences and the weak-sound drills. Contract: docs/english_v11_design.md (F2, F3, F4).

  GET /practice/ping        -> {"ok": true, "practice": 1, "missions": 1, "tatoeba": bool}
  GET /practice/sentences   -> Tatoeba sentences for shadowing (en, ja) and dictation (en only)
  GET /practice/phonemes    -> the sounds that have a drill (content/phoneme_drills.json)
  GET /practice/phoneme     -> one sound: hint, minimal pairs, phrases, a few Tatoeba example sentences

No AI, no state. server.py injects its helpers with init(log=, ApiError=, ja_reading=, readmode=, lesson_rules=, features=)
and mounts `router`; this module has no authentication code of its own and imports only light stdlib modules
(reading / lesson_rules are imported on first use, never the models).
"""
import os
import re
import sys
import json
import math
import random
import sqlite3
import threading

from fastapi import APIRouter

H = {}  # injected by server.py: log, ApiError, ja_reading, readmode (= reading), lesson_rules, features
router = APIRouter()

PRACTICE_VERSION = 1
BASE = os.path.dirname(os.path.abspath(__file__))
CONTENT_DIR = os.environ.get("HOEHWA_CONTENT_DIR") or os.path.join(BASE, "content")  # env var: tests only
DRILLS_FILE = "phoneme_drills.json"
MAX_EXCLUDE_CHARS = 4000
MAX_EXCLUDE_IDS = 500
DICT_MIN_WORDS, DICT_MAX_WORDS = 3, 10
NOT_READY_MSG = "예문 데이터가 아직 준비되지 않았어요. 설치 프로그램을 다시 실행하거나 'server.py --prefetch'로 만들어 주세요."


def init(**helpers):
    H.update(helpers)


def _log():
    import logging
    return H.get("log") or logging.getLogger("backend")


def _err(msg, status=400):
    E = H.get("ApiError")
    return E(msg, status) if E else ValueError(msg)


def _reading():
    r = H.get("readmode")
    if r is None:
        import reading as r
    return r


def _lessons():
    r = H.get("lesson_rules")
    if r is None:
        import lesson_rules as r
    return r


def _apierr():
    """exception classes that must pass through the catch-all handlers unchanged"""
    return H.get("ApiError") or ()


# ----------------------------------------------------------------------------------------------
# small parsers: query values arrive as strings, never as FastAPI-typed ints (a bad value must give a Korean 400/clamp, not 422)
# ----------------------------------------------------------------------------------------------
def _int(v, lo, hi, default):
    try:
        s = str(v).strip()
        if not re.fullmatch(r"[+-]?\d{1,18}", s):
            return default
        return max(lo, min(hi, int(s)))
    except Exception:
        return default


def parse_exclude(raw):
    """'12,34,a,,%00' -> {12, 34}: non-numeric tokens are ignored, the string is cut at 4000 chars, at most 500 ids"""
    out = set()
    if not isinstance(raw, str):
        return out
    for tok in raw[:MAX_EXCLUDE_CHARS].split(","):
        tok = tok.strip()
        if tok.isascii() and tok.isdigit() and len(tok) <= 12:
            out.add(int(tok))
            if len(out) >= MAX_EXCLUDE_IDS:
                break
    return out


def _need_lang(lang):
    if lang not in ("en", "ja"):
        raise _err("lang은 'en' 또는 'ja'여야 해요.", 400)
    return lang


# ----------------------------------------------------------------------------------------------
# sentences
# ----------------------------------------------------------------------------------------------
_PUNCT_EDGE = ".,!?;:\"“”()"
_JA_PUNCT = re.compile(r"[\s。、！？!?,.，．…・「」『』（）()\"'“”‘’〜~ー―-]")
_HIRA_ONLY = re.compile(r"[ぁ-ゖゝゞー]*")


def dictation_ok(text):
    """3..10 words, no digit, no capitalised word except the first word and 'I' (I, I'm, I'd ...)"""
    if not isinstance(text, str) or re.search(r"\d", text):
        return False
    words = text.split()
    if not DICT_MIN_WORDS <= len(words) <= DICT_MAX_WORDS:
        return False
    for i, w in enumerate(words):
        core = w.strip(_PUNCT_EDGE)
        if not core:
            return False
        if i == 0:
            continue
        if core[0].isupper() and core.replace("’", "'").split("'")[0] != "I":
            return False
    return True


def _ja_reading_ok(rd):
    """non-empty and hiragana only once punctuation is dropped"""
    core = _JA_PUNCT.sub("", rd or "")
    return bool(core) and _HIRA_ONLY.fullmatch(core) is not None


def _word_count(it, lang):
    return len(it["text"].split()) if lang == "en" else int(it.get("n") or len(it["text"]))


def _pick(lang, mode, stage, month, week, n, seed, exclude):
    """the ranking of lesson_rules._make_lesson (curriculum words of this month/week + noise), without building exercises"""
    L = _lessons()
    P = L.pool(lang)
    rng = random.Random(seed)
    try:
        target = L.target_vocab(lang, month, week)
    except Exception:
        _log().warning("practice: curriculum vocabulary unavailable, ranking by chance only", exc_info=True)
        target = {}
    cands = L._eligible(P, stage)
    scored = []
    for it in cands:
        if it["id"] in exclude:
            continue
        if mode == "dictation" and not dictation_ok(it["text"]):
            continue
        s = sum(target.get(l, 0) for l in it.get("lemmas", ()))
        scored.append((min(s, 8.0) * rng.uniform(0.5, 1.5) + rng.random() * 2.5, it["id"], it))
    scored.sort(key=lambda x: (-x[0], x[1]))
    out, seen_text = [], set()
    ja_reading = H.get("ja_reading") if lang == "ja" else None
    tries = 0
    for _s, _i, it in scored:
        if len(out) >= n:
            break
        if it["text"] in seen_text:
            continue
        reading = ""
        if lang == "ja":
            tries += 1
            if tries > n * 8 + 40:
                break
            if ja_reading is not None:
                try:
                    reading = ja_reading(it["text"])
                except Exception:
                    _log().warning("practice: ja_reading failed for sentence %s", it["id"], exc_info=True)
                    continue
                if not _ja_reading_ok(reading):
                    continue
        seen_text.add(it["text"])
        out.append({"id": it["id"], "text": it["text"], "ko": it.get("ko") or "", "reading": reading,
                    "words": _word_count(it, lang), "url": "https://tatoeba.org/sentences/show/%d" % it["id"]})
    return out


def get_sentences(lang, mode, stage=None, month=None, week=None, n=None, seed=None, exclude=None):
    """the whole /practice/sentences logic with string inputs (the route and the tests call this)"""
    _need_lang(lang)
    if mode not in ("shadow", "dictation"):
        raise _err("mode는 'shadow' 또는 'dictation'이어야 해요.", 400)
    if lang == "ja" and mode == "dictation":
        raise _err("받아쓰기는 영어만 지원해요.", 400)
    month_i = _int(month, 1, 12, 1)
    stage_i = _int(stage, 1, 4, int(math.ceil(month_i / 3.0)))
    week_i = _int(week, 1, 4, 1)
    n_i = _int(n, 1, 20, 8)
    seed_v = _int(seed, -(1 << 62), 1 << 62, None) if seed is not None else None
    exclude_ids = parse_exclude(exclude)
    R = _reading()
    if not R.tatoeba_ready():
        raise _err(NOT_READY_MSG, 503)
    try:
        sents = _pick(lang, mode, stage_i, month_i, week_i, n_i, seed_v, exclude_ids)
    except _apierr():
        raise
    except sqlite3.Error:
        R.invalidate_tatoeba_ready()
        _log().exception("practice: Tatoeba DB unreadable")
        raise _err(NOT_READY_MSG, 503)
    except Exception:
        _log().exception("practice: could not build the sentence list")
        raise _err("예문을 준비하지 못했어요. 잠시 뒤에 다시 시도해 주세요.", 503)
    return {"lang": lang, "mode": mode, "stage": stage_i, "sentences": sents, "attribution": R.ATTRIBUTION}


@router.get("/practice/ping")
def practice_ping():
    ok = False
    try:
        ok = bool(_reading().tatoeba_ready())
    except Exception:
        _log().warning("practice ping: tatoeba check failed", exc_info=True)
    return {"ok": True, "practice": PRACTICE_VERSION, "missions": 1 if "missions" in sys.modules else 0, "tatoeba": ok}


@router.get("/practice/sentences")
def practice_sentences(lang: str = "en", mode: str = "", stage: str = "", month: str = "", week: str = "",
                       n: str = "", seed: str = "", exclude: str = ""):
    return get_sentences(lang, mode, stage or None, month or None, week or None, n or None, seed or None, exclude)


# ----------------------------------------------------------------------------------------------
# weak-sound drills (content/phoneme_drills.json, re-read when the file changes)
# ----------------------------------------------------------------------------------------------
_drills = {"key": None, "items": []}
_drills_lock = threading.Lock()


def _str_list(v):
    return [x.strip() for x in v if isinstance(x, str) and x.strip()] if isinstance(v, list) else []


def _clean_drill(d):
    if not isinstance(d, dict) or not isinstance(d.get("p"), str) or not d["p"].strip():
        return None
    pairs = [{"a": x["a"].strip(), "b": x["b"].strip(), "ko": str(x.get("ko") or "")} for x in (d.get("pairs") or [])
             if isinstance(x, dict) and isinstance(x.get("a"), str) and isinstance(x.get("b"), str) and x["a"].strip() and x["b"].strip()]
    phrases = [{"text": x["text"].strip(), "ko": str(x.get("ko") or "")} for x in (d.get("phrases") or [])
               if isinstance(x, dict) and isinstance(x.get("text"), str) and x["text"].strip()]
    return {"p": d["p"].strip(), "label": str(d.get("label") or d["p"]), "hint_ko": str(d.get("hint_ko") or ""),
            "words": _str_list(d.get("words")), "pairs": pairs, "phrases": phrases}


def load_drills():
    """list of cleaned drill entries; raises ApiError 503 if the content file is missing or broken"""
    path = os.path.join(CONTENT_DIR, DRILLS_FILE)
    try:
        st = os.stat(path)
        key = (path, st.st_size, st.st_mtime_ns)
    except OSError:
        _log().error("practice: %s not found", path)
        raise _err("연습 자료를 찾을 수 없어요. 프로그램을 다시 설치해 주세요.", 503)
    with _drills_lock:
        if _drills["key"] == key:
            return _drills["items"]
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            items, seen = [], set()
            for d in data.get("phonemes") or []:
                c = _clean_drill(d)
                if c and c["p"] not in seen:
                    seen.add(c["p"])
                    items.append(c)
        except Exception:
            _log().exception("practice: %s is unreadable", path)
            raise _err("연습 자료를 읽지 못했어요. 프로그램을 다시 설치해 주세요.", 503)
        _drills["key"], _drills["items"] = key, items
        return items


def get_phonemes():
    return {"phonemes": [{"p": d["p"], "label": d["label"], "hint_ko": d["hint_ko"]} for d in load_drills()]}


def _example_ok(row):
    """a Tatoeba example for a drill word: 3..10 words, clean English, a clean Korean translation"""
    L = _lessons()
    text, ko = row.get("text") or "", row.get("ko") or ""
    if not isinstance(text, str) or not DICT_MIN_WORDS <= len(text.split()) <= DICT_MAX_WORDS:
        return False
    try:
        return bool(L.EN_CLEAN.fullmatch(text)) and not L.blocked(text) and bool(L._ko_clean(ko))
    except Exception:
        return False


def _drill_sentences(words, count):
    """round-robin over the drill words so that one word does not fill the list; [] if the DB is missing (drills still work)"""
    if count <= 0:
        return []
    R = _reading()
    try:
        if not R.tatoeba_ready():
            return []
    except Exception:
        return []
    per_word = []
    order = list(words)
    random.shuffle(order)
    try:
        for w in order[:8]:
            try:
                rows = R.examples("en", w, 6).get("examples", [])
            except sqlite3.Error:
                R.invalidate_tatoeba_ready()
                _log().warning("practice: Tatoeba DB unreadable while looking up drill examples", exc_info=True)
                return []
            per_word.append([{"id": r["id"], "text": r["text"], "ko": r["ko"], "url": r["url"]} for r in rows if _example_ok(r)])
            if sum(len(g) for g in per_word) >= count * 2:
                break
    except _apierr():
        return []
    except Exception:
        _log().warning("practice: drill examples failed", exc_info=True)
        return []
    out, ids, texts, i = [], set(), set(), 0
    while len(out) < count and any(i < len(g) for g in per_word):
        for g in per_word:
            if i < len(g) and len(out) < count and g[i]["id"] not in ids and g[i]["text"] not in texts:
                ids.add(g[i]["id"])
                texts.add(g[i]["text"])
                out.append(g[i])
        i += 1
    return out


def get_phoneme(p, sentences=None):
    p = p.strip() if isinstance(p, str) else ""
    if not p:
        raise _err("소리(p)를 보내 주세요.", 400)
    d = next((x for x in load_drills() if x["p"] == p), None)
    if d is None:
        raise _err("아직 연습 자료가 없는 소리예요.", 404)
    count = _int(sentences, 0, 5, 3)
    sents = _drill_sentences(d["words"], count)
    return {"p": d["p"], "label": d["label"], "hint_ko": d["hint_ko"], "words": d["words"], "pairs": d["pairs"],
            "phrases": d["phrases"], "sentences": sents, "attribution": _reading().ATTRIBUTION}


@router.get("/practice/phonemes")
def practice_phonemes():
    return get_phonemes()


@router.get("/practice/phoneme")
def practice_phoneme(p: str = "", sentences: str = ""):
    return get_phoneme(p, sentences or None)
