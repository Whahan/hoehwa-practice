# -*- coding: utf-8 -*-
"""Reading mode (LingQ/Lute style) + Tatoeba example sentences. Contract: ../API.md "읽기 모드 (/reading/*)".

  analyze(lang, text)   -> tokens / sentences / words  (spaCy for English, fugashi+unidic-lite for Japanese, wordfreq zipf)
  gloss(lang, items)    -> Korean meanings in context, one batched LLM call (server's ollama_json), cached in cache/gloss.json
  examples(lang, q, n)  -> Tatoeba sentences from data/tatoeba.sqlite (built by tatoeba_build.py)

server.py injects its helpers with init(); this module itself only imports light stdlib modules at import time so that
tatoeba_build.py can reuse the tokenisation/lemma code without loading the server.
"""
import os
import re
import json
import math
import time
import sqlite3
import hashlib
import threading
import unicodedata

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE, "data")
DB_PATH = os.environ.get("HOEHWA_TATOEBA_DB") or os.path.join(DATA_DIR, "tatoeba.sqlite")  # env var: tests only
GLOSS_CACHE = os.path.join(BASE, "cache", "gloss.json")
ATTRIBUTION = "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"
MAX_CHARS = 20000
MAX_GLOSS = 30

H = {}  # helpers injected by server.py: log, ApiError, ollama_json, ko_ok, ja_reading, patch_espeak


def init(**helpers):
    H.update(helpers)


def _err(msg, status=400):
    E = H.get("ApiError")
    return E(msg, status) if E else ValueError(msg)


def _log():
    import logging
    return H.get("log") or logging.getLogger("backend")


# ----------------------------------------------------------------------------------------------
# word frequency (wordfreq zipf). The frequency dict is read directly: wordfreq's own tokenizer
# needs MeCab for Japanese, and a dict lookup is much faster anyway.
# ----------------------------------------------------------------------------------------------
_freq = {}
_freq_lock = threading.Lock()


def _fdict(lang):
    d = _freq.get(lang)
    if d is None:
        with _freq_lock:
            d = _freq.get(lang)
            if d is None:
                from wordfreq import get_frequency_dict
                d = get_frequency_dict(lang, wordlist="best")
                _freq[lang] = d
    return d


def zipf(word, lang):
    if not word:
        return 0.0
    w = unicodedata.normalize("NFKC", word).lower().replace("’", "'")
    f = _fdict(lang).get(w)
    return round(math.log10(f) + 9, 2) if f else 0.0


def level_of(z):
    return "easy" if z >= 4.5 else ("mid" if z >= 3.5 else "hard")


# ----------------------------------------------------------------------------------------------
# English: spaCy
# ----------------------------------------------------------------------------------------------
_nlp = None
_nlp_lock = threading.Lock()
_en_run_lock = threading.Lock()


def en_nlp():
    """en_core_web_sm with tagger + lemmatizer + the fast statistical sentence splitter (no parser/NER)."""
    global _nlp
    if _nlp is None:
        with _nlp_lock:
            if _nlp is None:
                import spacy
                nlp = spacy.load("en_core_web_sm", exclude=["parser", "ner"])
                if "senter" in nlp.disabled:
                    nlp.enable_pipe("senter")
                nlp.max_length = 2_000_000
                _nlp = nlp
    return _nlp


def _lem_tables(nlp=None):
    lem = (nlp or en_nlp()).get_pipe("lemmatizer")
    return (lem.lookups.get_table("lemma_index", {}), lem.lookups.get_table("lemma_exc", {}),
            lem.lookups.get_table("lemma_rules", {}))


_lem_t = None


def en_lemma_cands(form, tables=None):
    """dictionary forms a lower-case English word form can come from (context-free; spaCy's rule tables for
    verb/noun/adj/adv). Only forms confirmed by the lemma index or the exception lists are returned."""
    global _lem_t
    if tables is None:
        if _lem_t is None:
            _lem_t = _lem_tables()
        tables = _lem_t
    index_t, exc_t, rules_t = tables
    out = []
    for pos in ("verb", "noun", "adj", "adv"):
        index = index_t.get(pos, {})
        for f in exc_t.get(pos, {}).get(form, []) or []:
            if f and f != form and f not in out:
                out.append(f)
        for old, new in rules_t.get(pos, []) or []:
            if form.endswith(old):
                f = form[: len(form) - len(old)] + new
                if f and f != form and f in index and f not in out:
                    out.append(f)
    return out


EN_WORD_RE = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")
_ALPHA = re.compile(r"[A-Za-z]")
_DIGIT = re.compile(r"\d")


CLITIC = {"'m": "be", "'re": "be", "'s": "be", "'ve": "have", "'ll": "will", "'d": "would"}


def en_index_words(text):
    """lower-case word forms used by the Tatoeba index (same normalisation as the query side)"""
    return {m.group(0).lower().replace("’", "'") for m in EN_WORD_RE.finditer(text)}


def _en_is_word(tok):
    t = tok.text
    if tok.is_space or not _ALPHA.search(t) or _DIGIT.search(t):
        return False
    if tok.like_url or tok.like_email or "@" in t or "/" in t:
        return False
    if tok.tag_ == "POS":  # possessive 's
        return False
    if tok.pos_ == "PROPN" and not t.islower():
        return False
    return True


def _en_stream(text):
    """yields raw tokens: (text, is_word, lemma, zipf, break_before)"""
    nlp = en_nlp()
    with _en_run_lock:
        doc = nlp(text)
    nl_gap = False
    for tok in doc:
        brk = tok.is_sent_start or nl_gap
        nl_gap = False
        if _en_is_word(tok):
            lemma = (tok.lemma_ or tok.text).lower().replace("’", "'")
            if lemma.startswith("'"):  # clitics: 'm 're 've 'll 'd ('s as a verb)
                lemma = CLITIC.get(lemma, lemma.lstrip("'"))
            if not _ALPHA.search(lemma):
                lemma = tok.text.lower()
            z = max(zipf(lemma, "en"), zipf(tok.text, "en"))
            yield tok.text, True, lemma, z, brk
        else:
            if tok.is_space and "\n" in tok.text:
                nl_gap = True
            yield tok.text, False, None, None, brk
        if tok.whitespace_:
            yield tok.whitespace_, False, None, None, False


# ----------------------------------------------------------------------------------------------
# Japanese: fugashi + unidic-lite
# ----------------------------------------------------------------------------------------------
_tagger = None
_tagger_lock = threading.Lock()
JA_CHARS = re.compile(r"[぀-ヿ㐀-䶿一-鿿々〆ヵヶー]")
JA_SENT_END = set("。！？!?．…")
JA_CLOSE = set("」』）)】〉》\"'”’")


def ja_tagger():
    global _tagger
    if _tagger is None:
        with _tagger_lock:
            if _tagger is None:
                import fugashi
                _tagger = fugashi.Tagger()
    return _tagger


def ja_lemma(node):
    """dictionary form in the spelling used in the text (unidic orthBase: し→する, 東京 stays 東京),
    falling back to the unidic lemma (without its '-english' gloss suffix) and then the surface."""
    f = node.feature
    for v in (getattr(f, "orthBase", None), (getattr(f, "lemma", None) or "").split("-")[0]):
        if v and v != "*":
            return v
    return node.surface


def ja_is_word(node):
    f = node.feature
    if f.pos1 in ("補助記号", "記号", "空白") or f.pos2 in ("固有名詞", "数詞"):
        return False
    return bool(JA_CHARS.search(node.surface))


def ja_parse(text):
    """list of (surface, is_word, lemma) covering `text` exactly (whitespace / unmatched spans are non-words)"""
    tg = ja_tagger()
    out = []
    pos = 0
    for m in re.finditer(r"\S+", text):
        if m.start() > pos:
            out.append((text[pos:m.start()], False, None))
        seg = m.group(0)
        with _tagger_lock:
            nodes = [(n.surface, ja_is_word(n), ja_lemma(n)) for n in tg(seg)]
        i = 0
        for surf, isw, lem in nodes:
            if not surf:
                continue
            j = seg.find(surf, i)
            if j < 0:  # should not happen; keep the round trip exact anyway
                continue
            if j > i:
                out.append((seg[i:j], False, None))
            out.append((surf, isw, lem))
            i = j + len(surf)
        if i < len(seg):
            out.append((seg[i:], False, None))
        pos = m.end()
    if pos < len(text):
        out.append((text[pos:], False, None))
    return out


def ja_index_words(text):
    """lemmas used by the Tatoeba index for one Japanese sentence"""
    return {lem for _s, isw, lem in ja_parse(text) if isw and lem}


def _ja_stream(text):
    pending = False
    for surf, isw, lem in ja_parse(text):
        if not surf.strip():
            if "\n" in surf:
                pending = True
            yield surf, False, None, None, False
            continue
        if pending and surf[0] in JA_CLOSE:  # 「…。」と言った: the quote does not end the outer sentence
            pending = False
            yield surf, False, None, None, False
            continue
        brk = pending
        pending = False
        if isw:
            z = max(zipf(lem, "ja"), zipf(surf, "ja"))
            yield surf, True, lem, z, brk
        else:
            yield surf, False, None, None, brk
        if surf[-1] in JA_SENT_END:
            pending = True


def warmup():
    """load spaCy, the wordfreq tables and fugashi so the first /reading/analyze is fast"""
    analyze("en", "Warming up the reader.")
    analyze("ja", "準備しています。")


# ----------------------------------------------------------------------------------------------
# /reading/analyze
# ----------------------------------------------------------------------------------------------
def analyze(lang, text):
    text = text if isinstance(text, str) else ""
    if not text.strip():
        raise _err("분석할 글을 붙여 넣어 주세요.", 400)
    if len(text) > MAX_CHARS:
        raise _err("글이 너무 길어요. %d자까지 한 번에 읽을 수 있어요(지금 %d자)." % (MAX_CHARS, len(text)), 400)
    stream = _en_stream(text) if lang == "en" else _ja_stream(text)
    tokens = []
    cur = -1
    for t, isw, lemma, z, brk in stream:
        if not t:
            continue
        has_content = bool(t.strip())
        if has_content and (brk or cur < 0):
            cur += 1
        s = max(cur, 0)
        if isw:
            tokens.append({"t": t, "w": True, "lemma": lemma, "zipf": z, "level": level_of(z), "s": s})
        elif tokens and not tokens[-1]["w"] and tokens[-1]["s"] == s:
            tokens[-1]["t"] += t  # merge runs of spaces / punctuation inside one sentence
        else:
            tokens.append({"t": t, "w": False, "s": s})
    sents = {}
    words = {}
    for tk in tokens:
        sents.setdefault(tk["s"], []).append(tk["t"])
        if tk["w"]:
            w = words.get(tk["lemma"])
            if w is None:
                words[tk["lemma"]] = {"lemma": tk["lemma"], "count": 1, "zipf": tk["zipf"]}
            else:
                w["count"] += 1
                w["zipf"] = max(w["zipf"], tk["zipf"])
    for w in words.values():
        w["level"] = level_of(w["zipf"])
    sentences = [{"i": i, "text": "".join(sents[i]).strip()} for i in sorted(sents)]
    return {"tokens": tokens, "sentences": sentences, "words": list(words.values())}


# ----------------------------------------------------------------------------------------------
# /reading/gloss
# ----------------------------------------------------------------------------------------------
_gcache = None
_gcache_lock = threading.Lock()


def _gload():
    global _gcache
    if _gcache is None:
        try:
            with open(GLOSS_CACHE, "r", encoding="utf-8") as f:
                _gcache = json.load(f)
        except FileNotFoundError:
            _gcache = {}
        except Exception:
            _log().exception("gloss cache unreadable, starting empty")
            _gcache = {}
    return _gcache


def _gsave():
    os.makedirs(os.path.dirname(GLOSS_CACHE), exist_ok=True)
    tmp = GLOSS_CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(_gcache, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, GLOSS_CACHE)


def _gkey(lang, lemma, sentence):
    h = hashlib.sha1(" ".join(sentence.split()).encode("utf-8")).hexdigest()[:16]
    return "%s\t%s\t%s" % (lang, lemma, h)


POS_EN = "명사, 동사, 형용사, 부사, 대명사, 전치사, 접속사, 조동사, 한정사, 감탄사, 구동사"
POS_JA = "명사, 동사, い형용사, な형용사, 부사, 조사, 조동사, 접속사, 대명사, 연체사, 감탄사, 접두사, 접미사"
_STR = {"type": "string"}


def _gloss_schema(lang, n):
    props = {"i": {"type": "integer", "minimum": 1, "maximum": n}, "pos": _STR, "ko": _STR}
    if lang == "en":
        props["ipa"] = _STR
    props["note"] = _STR
    item = {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}
    return {"type": "object", "properties": {"glosses": {"type": "array", "items": item, "minItems": n, "maxItems": n}},
            "required": ["glosses"], "additionalProperties": False}


def _gloss_prompt(lang, items):
    lname = "English" if lang == "en" else "Japanese"
    lines = ["%d. word: %s | sentence: %s" % (k + 1, it["lemma"], it["sentence"] or "(none)") for k, it in enumerate(items)]
    rules = [
        "You are a %s-Korean learner's dictionary for Korean speakers who read %s texts." % (lname, lname),
        "For each numbered item, explain the WORD (given in its dictionary form) as it is used in its SENTENCE.",
        "- i: the item number.",
        "- pos: the word's part of speech in that sentence, in Korean, one of: %s." % (POS_EN if lang == "en" else POS_JA),
        "- ko: a short, natural Korean meaning that fits THIS sentence (1-5 words; Hangul only, no Chinese characters, "
        "no %s). If the word is part of a phrase or idiom in the sentence, give the meaning it has there." % lname,
    ]
    if lang == "en":
        rules.append("- ipa: General American IPA of the dictionary form, without slashes, with the primary stress mark ˈ "
                     "for words of two or more syllables (e.g. run → rʌn, beautiful → ˈbjuːtɪfəl).")
    rules.append("- note: one short Korean line about usage, nuance or a common collocation that helps a Korean learner, "
                 "or \"\" if nothing important.")
    rules.append("Give exactly one entry per item, in order.\n\nItems:\n" + "\n".join(lines) + "\n\nReply only with the JSON object.")
    return "\n".join(rules)


_IPA_OK = re.compile(r"^[abdefhijklmnoprstuvwzæɑɒɔəɚɛɜɝɪʊʌθðŋʃʒʧʤɡɹɾʔˈˌːˑ.ɫɐɘɵɨʉʍʰ̩̯̃ ]+$")
_IPA_VOWEL = re.compile(r"[aeiouæɑɒɔəɚɛɜɝɪʊʌɐɘɵɨʉ]")


def _clean_ipa(s, lemma):
    s = (s or "").strip().strip("/[]").strip()
    s = s.replace("'", "ˈ").replace("g", "ɡ").replace(":", "ː")
    if not s or not _IPA_OK.match(s) or not _IPA_VOWEL.search(s) or len(s) > 3 * len(lemma) + 6:
        return None
    return s


_esp = None
_esp_lock = threading.Lock()


def espeak_ipa(word):
    """espeak-ng IPA (en-us, with stress) as a fallback when the model's IPA looks broken"""
    global _esp
    try:
        with _esp_lock:
            if _esp is None:
                if H.get("patch_espeak"):
                    H["patch_espeak"]()
                import espeakng_loader
                from phonemizer.backend.espeak.wrapper import EspeakWrapper
                EspeakWrapper.set_library(espeakng_loader.get_library_path())
                from phonemizer.backend import EspeakBackend
                _esp = EspeakBackend("en-us", preserve_punctuation=False, with_stress=True, language_switch="remove-flags")
            from phonemizer.separator import Separator
            out = _esp.phonemize([word], separator=Separator(word=" ", phone="", syllable=""), strip=True)[0]
        return out.strip()
    except Exception:
        _log().exception("espeak IPA failed for %r", word)
        return ""


def _ipa_key(s):
    s = s.replace("ɹ", "r").replace("ɚ", "ər").replace("ɝ", "ɜr").replace("ɡ", "g").replace("ɐ", "ʌ")
    s = s.replace("ᵻ", "ɪ").replace("ɾ", "t").replace("ʧ", "tʃ").replace("ʤ", "dʒ")
    return re.sub(r"[ˈˌːˑ.\s]", "", s)


def _pick_ipa(model_ipa, lemma):
    """the model's IPA unless it looks broken: bad characters, or clearly a different word than espeak's
    pronunciation (an 8B model often writes plausible-looking but wrong IPA, e.g. cope -> kəp)"""
    import difflib
    ipa = _clean_ipa(model_ipa, lemma)
    esp = espeak_ipa(lemma)
    if not ipa:
        return esp
    if esp and difflib.SequenceMatcher(None, _ipa_key(ipa), _ipa_key(esp)).ratio() < 0.7:
        return esp
    return ipa


def _gloss_llm(lang, items):
    """one LLM call; returns {request position: gloss dict} for the entries that passed validation"""
    n = len(items)
    msgs = [{"role": "user", "content": _gloss_prompt(lang, items)}]
    data = H["ollama_json"](msgs, _gloss_schema(lang, n), temperature=0.2, num_predict=max(1500, 140 * n + 300))
    ko_ok = H["ko_ok"]
    got = {}
    for g in (data or {}).get("glosses") or []:
        if not isinstance(g, dict):
            continue
        try:
            i = int(g.get("i")) - 1
        except Exception:
            continue
        if not (0 <= i < n) or i in got:
            continue
        lemma = items[i]["lemma"]
        ko = " ".join(str(g.get("ko") or "").split())
        if not ko_ok(ko, lang) or len(ko) > 60:
            _log().info("gloss dropped (%s %r): bad ko %r", lang, lemma, ko)
            continue
        pos = " ".join(str(g.get("pos") or "").split())
        if not ko_ok(pos, lang, required=False) or len(pos) > 12:
            pos = ""
        note = " ".join(str(g.get("note") or "").split())
        if not ko_ok(note, lang, required=False) or len(note) > 160:
            note = ""
        if lang == "en":
            ipa = _pick_ipa(g.get("ipa"), lemma)
        else:
            try:
                ipa = H["ja_reading"](lemma) if JA_CHARS.search(lemma) else ""
            except Exception:
                ipa = ""
        got[i] = {"lemma": lemma, "pos": pos, "ko": ko, "ipa": ipa, "note": note}
    return got


def _ja_pron(lang, lemma):
    """katakana pronunciation form of a Japanese lemma (not cached with the gloss: one OpenJTalk pass); "" for English / on failure"""
    f = H.get("ja_pron")
    if lang != "ja" or f is None or not JA_CHARS.search(lemma or ""):
        return ""
    try:
        return f(lemma)
    except Exception:
        return ""


def gloss(lang, items):
    if not isinstance(items, list) or not items:
        raise _err("뜻을 찾을 단어를 보내 주세요.", 400)
    if len(items) > MAX_GLOSS:
        raise _err("한 번에 %d개까지 뜻을 찾을 수 있어요." % MAX_GLOSS, 400)
    reqs = []
    for it in items:
        it = it if isinstance(it, dict) else {}
        lemma = " ".join(str(it.get("lemma") or "").split())[:60]
        sentence = " ".join(str(it.get("sentence") or "").split())[:600]
        if lang == "en":
            lemma = lemma.lower() if lemma[:1].isupper() and lemma[1:].islower() else lemma
        reqs.append({"lemma": lemma, "sentence": sentence})
    if not any(r["lemma"] for r in reqs):
        raise _err("뜻을 찾을 단어를 보내 주세요.", 400)
    with _gcache_lock:
        cache = _gload()
        results = [None] * len(reqs)
        todo = {}  # key -> first request index
        for k, r in enumerate(reqs):
            if not r["lemma"]:
                continue
            key = _gkey(lang, r["lemma"], r["sentence"])
            if key in cache:
                results[k] = dict(cache[key], lemma=r["lemma"])
            elif key not in todo:
                todo[key] = k
    t0 = time.time()
    for attempt in range(2):
        if not todo:
            break
        keys = list(todo)
        batch = [reqs[todo[key]] for key in keys]
        try:
            got = _gloss_llm(lang, batch)
        except Exception as e:
            if attempt == 0 and not any(results):
                raise
            _log().warning("gloss retry failed: %s", getattr(e, "msg", e))
            break
        with _gcache_lock:
            cache = _gload()
            for j, g in got.items():
                key = keys[j]
                cache[key] = {"pos": g["pos"], "ko": g["ko"], "ipa": g["ipa"], "note": g["note"]}
                todo.pop(key, None)
            if got:
                _gsave()
    if todo:
        _log().info("gloss: %d item(s) without a valid answer", len(todo))
    with _gcache_lock:
        cache = _gload()
        out = []
        for k, r in enumerate(reqs):
            if not r["lemma"]:
                continue
            g = results[k] or cache.get(_gkey(lang, r["lemma"], r["sentence"]))
            if g:
                out.append({"i": k, "lemma": r["lemma"], "pos": g["pos"], "ko": g["ko"], "ipa": g["ipa"], "note": g["note"],
                            "pron": _ja_pron(lang, r["lemma"])})
    _log().info("gloss %s: %d asked, %d answered (%.1fs)", lang, len(reqs), len(out), time.time() - t0)
    if not out:
        raise _err("AI가 단어 뜻을 만들지 못했어요. 다시 시도해 주세요.", 502)
    return {"glosses": out}


# ----------------------------------------------------------------------------------------------
# /examples (Tatoeba)
# ----------------------------------------------------------------------------------------------
_ready = {"key": None, "ok": False}
_ready_lock = threading.Lock()
DB_TABLES = {"sent", "vocab", "post", "en_forms", "meta"}


def _db_valid():
    """The file opens as SQLite and has the tables the examples / lessons read (an empty, truncated or foreign file does not)."""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB_PATH.replace("\\", "/").replace("?", "%3f").replace("#", "%23"), uri=True)
        try:
            names = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not DB_TABLES <= names:
                return False
            return (con.execute("SELECT 1 FROM sent LIMIT 1").fetchone() is not None
                    and con.execute("SELECT 1 FROM post LIMIT 1").fetchone() is not None)
        finally:
            con.close()
    except Exception:
        return False


def tatoeba_ready():
    """True if the Tatoeba DB exists AND is a usable SQLite file (checked once per file size/mtime, then cached)."""
    try:
        st = os.stat(DB_PATH)
    except OSError:
        return False
    if not os.path.isfile(DB_PATH):
        return False
    key = (DB_PATH, st.st_size, st.st_mtime_ns)
    c = _ready
    if c["key"] == key:
        return c["ok"]
    with _ready_lock:
        ok = _db_valid()
        c["key"], c["ok"] = key, ok
    if not ok:
        try:
            _log().warning("Tatoeba DB %s is not a valid database; examples and rule-based lessons are off", DB_PATH)
        except Exception:
            pass
    return ok


def invalidate_tatoeba_ready():
    """a query on the DB raised sqlite3.DatabaseError (corrupted after the check): re-check on the next call"""
    _ready["key"] = None
    _ready["ok"] = False


def _db():
    uri = "file:%s?mode=ro" % DB_PATH.replace("\\", "/").replace("?", "%3f").replace("#", "%23")
    return sqlite3.connect(uri, uri=True, check_same_thread=False)


def _row(r, lang):
    sid, text, ko, tr = r
    return {"id": sid, "text": text, "ko": ko or "", "en": (tr or "") if lang == "ja" else "",
            "ja": (tr or "") if lang == "en" else "", "url": "https://tatoeba.org/sentences/show/%d" % sid}


def _like_search(con, lang, q, limit):
    pat = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    rows = con.execute("SELECT id, text, ko, tr FROM sent WHERE lang=? AND text LIKE ? ESCAPE '\\' ORDER BY k LIMIT ?",
                       (lang, pat, limit * 20)).fetchall()
    if lang == "en":  # whole words only
        rx = re.compile(r"(?<![A-Za-z])" + re.escape(q) + r"(?![A-Za-z])", re.I)
        rows = [r for r in rows if rx.search(r[1])]
    return rows[:limit]


def examples(lang, q, limit=5):
    if not tatoeba_ready():
        raise _err("예문 데이터가 아직 준비되지 않았어요. 설치 프로그램을 다시 실행하거나 'server.py --prefetch'로 만들어 주세요.", 503)
    q = unicodedata.normalize("NFKC", q or "").strip()
    if not q:
        raise _err("찾을 단어(q)를 보내 주세요.", 400)
    if len(q) > 60:
        raise _err("찾을 단어가 너무 길어요.", 400)
    limit = max(1, min(int(limit or 5), 20))
    con = _db()
    try:
        forms = []
        if lang == "en":
            ql = q.lower().replace("’", "'")
            if EN_WORD_RE.fullmatch(ql):
                forms = [ql] + [r[0] for r in con.execute("SELECT form FROM en_forms WHERE lemma=?", (ql,))]
        else:
            if re.fullmatch(r"\S+", q):
                forms = [q]
                if con.execute("SELECT 1 FROM vocab WHERE lang='ja' AND w=?", (q,)).fetchone() is None:
                    ws = [lem for _s, isw, lem in ja_parse(q) if isw and lem]
                    if ws:  # 食べました -> 食べる (the first word carries the meaning)
                        forms = ws[:1]
        rows = []
        if forms:
            ph = ",".join("?" * len(forms))
            wids = [r[0] for r in con.execute("SELECT id FROM vocab WHERE lang=? AND w IN (%s)" % ph, [lang] + forms)]
            if wids:
                ph = ",".join("?" * len(wids))
                seen = set()
                for r in con.execute("SELECT s.id, s.text, s.ko, s.tr FROM post p JOIN sent s ON s.id = p.sid "
                                     "WHERE p.wid IN (%s) ORDER BY p.k, p.sid LIMIT ?" % ph, wids + [limit * 4]):
                    if r[0] in seen or r[1] in seen:
                        continue
                    seen.update((r[0], r[1]))
                    rows.append(r)
                    if len(rows) >= limit:
                        break
        if not rows:
            rows = _like_search(con, lang, q, limit)
        return {"examples": [_row(r, lang) for r in rows], "attribution": ATTRIBUTION}
    finally:
        con.close()
