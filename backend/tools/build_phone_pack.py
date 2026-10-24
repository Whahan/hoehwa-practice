# -*- coding: utf-8 -*-
"""Builds the phone data pack (godot/data/pack/*) for the stand-alone phone app. Design: docs/phone_standalone_design.md §5.5.

    backend\\.venv\\Scripts\\python.exe -I backend\\tools\\build_phone_pack.py [options]

    --out DIR        pack folder (default godot\\data\\pack)
    --db FILE        Tatoeba SQLite (default backend\\data\\tatoeba.sqlite), opened read-only
    --cache DIR      folder with lesson_pool_*.json / lesson_tri_en.bin / gloss.json (default backend\\cache), read-only:
                     the files are copied to a work folder first, the originals are never written
    --content DIR    folder with missions.json / phoneme_drills.json (default backend\\content)
    --per-cell N     lessons per (month, week) cell and language (default 20, at least 10 are required)
    --only A,B       build only these files (names with or without .json, or: lessons practice examples reading ipa
                     jamap content); the other files of --out stay as they are
    --jobs N         worker processes for the lesson bank (default 4)
    --vocab-dir DIR  also write vocab_en.txt (top 15,000 lemmas) and vocab_ja.txt (top 8,000) there (input of the gloss builder)
    --built ISO      value of manifest "built" (tests)

Everything is built in a temporary folder, checked, and only then moved into --out (file by file, manifest last). On any
error nothing in --out changes. Exit code 0 = ok, 2 = missing input, 1 = build/check failed.
The lessons come from backend/lesson_rules.make_lesson (rule-based, no AI), so every answer is correct by construction.
"""
import os
import re
import sys
import json
import math
import time
import shutil
import hashlib
import argparse
import tempfile
import datetime

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
REPO = os.path.dirname(BACKEND)
for _p in (BACKEND, HERE):
    if _p not in sys.path:
        sys.path.insert(0, _p)

DEFAULT_OUT = os.path.join(REPO, "godot", "data", "pack")
DEFAULT_DB = os.path.join(BACKEND, "data", "tatoeba.sqlite")
DEFAULT_CACHE = os.path.join(BACKEND, "cache")
DEFAULT_CONTENT = os.path.join(BACKEND, "content")
CURRICULUM = os.path.join(BACKEND, "curriculum.json")

PACK_V = 1
MIN_CELL = 10                    # lessons a cell must have at least (target: --per-cell)
MAX_PACK_BYTES = 30 * 1024 * 1024
MAX_FILE_BYTES = 10 * 1024 * 1024
EXAMPLES_PER_KEY = 20
ZIPF_TOP = 120000
IPA_ZIPF_TOP = 20000
VOCAB_EN_N = 15000
VOCAB_JA_N = 8000

LESSON_FILES = ["lesson_bank_en.json", "lesson_bank_ja.json"]
PRACTICE_FILES = ["practice_en.json", "practice_ja.json"]
EXAMPLE_FILES = ["examples_en.json", "examples_ja.json"]
CONTENT_FILES = ["missions.json", "phoneme_drills.json"]
BUILT_FILES = (LESSON_FILES + PRACTICE_FILES + EXAMPLE_FILES + ["reading_en.json", "ipa_en.json", "ja_reading_map.json"]
               + CONTENT_FILES)
BUILD_ORDER = ["missions.json", "phoneme_drills.json"] + LESSON_FILES + PRACTICE_FILES + EXAMPLE_FILES \
    + ["reading_en.json", "ja_reading_map.json", "ipa_en.json"]
ALIASES = {
    "lessons": LESSON_FILES, "practice": PRACTICE_FILES, "examples": EXAMPLE_FILES, "reading": ["reading_en.json"],
    "ipa": ["ipa_en.json"], "jamap": ["ja_reading_map.json"], "content": CONTENT_FILES,
}
POOL_FILES = ["lesson_pool_en.json", "lesson_pool_ja.json"]
PRIVACY_PATTERNS = ["users\\", "appdata"] + ([os.environ["USERNAME"].lower()] if os.environ.get("USERNAME") else [])  # must not occur in any pack file (case-insensitive)

EN_WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
WF_WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")
HIRA_FULL = re.compile(r"[ぁ-ゖゝゞー]+")
HANGUL = re.compile(r"[가-힣]")


class BuildError(Exception):
    """also stands in for the server's ApiError inside lesson_rules / reading (msg, status)"""
    def __init__(self, msg="", status=400):
        Exception.__init__(self, msg)
        self.msg = msg
        self.status = status


class InputError(Exception):
    """a missing / unusable input (exit code 2)"""


T0 = time.time()


def say(msg):
    print("[phone-pack %5.0fs] %s" % (time.time() - T0, msg), flush=True)


# ----------------------------------------------------------------------------------------------
# small helpers (pure; unit-tested)
# ----------------------------------------------------------------------------------------------
def dumps(obj, indent=None):
    """deterministic JSON text: UTF-8 friendly (no \\u escapes), LF only, one trailing newline"""
    if indent is None:
        s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    else:
        s = json.dumps(obj, ensure_ascii=False, indent=indent)
    return s + "\n"


def write_json(path, obj, indent=None):
    data = dumps(obj, indent).encode("utf-8")
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage_of(month):
    return int(math.ceil(month / 3.0))


def iter_strings(obj):
    """every string value of a nested JSON-like object"""
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            for s in iter_strings(v):
                yield s
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            for s in iter_strings(v):
                yield s


def en_words_of(text):
    """lower-case English word forms of a text (apostrophes normalised)"""
    return {m.group(0).lower() for m in EN_WORD.finditer((text or "").replace("’", "'"))}


def count_records(name, data):
    """number of records of a pack file, for the manifest"""
    if not isinstance(data, dict):
        return len(data) if hasattr(data, "__len__") else 0
    # chosen by file name: ipa_en.json / ja_reading_map.json are plain word tables and may have a word "lessons" or "sent"
    key = None
    if name.startswith("lesson_bank_"):
        return sum(len(v) for v in data["lessons"].values())
    if name.startswith("practice_"):
        key = "sentences"
    elif name.startswith("examples_"):
        key = "sent"
    elif name == "reading_en.json":
        key = "forms"
    elif name == "missions.json":
        key = "missions"
    elif name == "phoneme_drills.json":
        key = "phonemes"
    if key is not None and isinstance(data.get(key), (dict, list)):
        return len(data[key])
    return len(data)


# ---- lessons: structure checks -----------------------------------------------------------------
REQUIRED_KEYS = {
    "choice": ("type", "question", "options", "answer", "explain"),
    "fill": ("type", "sentence", "reading", "pron", "ko", "options", "answer", "explain"),
    "build": ("type", "ko", "answer", "extra", "reading", "pron", "explain"),
    "listen": ("type", "audio", "reading", "pron", "options", "answer", "explain"),
    "speak": ("type", "text", "reading", "pron", "ko"),
}


def _word_in(text, word):
    return re.search(r"(?<![A-Za-z'])" + re.escape(word) + r"(?![A-Za-z'])", text, re.I) is not None


def check_exercise(ex, lang):
    """problems (strings) of one exercise; [] when it is fine (API.md /lesson shape, answer / option / tile rules)"""
    if not isinstance(ex, dict):
        return ["문제가 객체가 아니에요"]
    t = ex.get("type")
    if t not in REQUIRED_KEYS:
        return ["알 수 없는 type %r" % (t,)]
    bad = ["키 %s 없음" % k for k in REQUIRED_KEYS[t] if k not in ex]
    if not isinstance(ex.get("tatoeba_id"), int):
        bad.append("tatoeba_id 없음")
    if bad:
        return bad
    for k in REQUIRED_KEYS[t]:
        if k in ("answer", "options", "extra"):
            continue
        if not isinstance(ex[k], str):
            bad.append("%s 가 문자열이 아님" % k)
    if t in ("choice", "fill", "listen"):
        opts, ans = ex["options"], ex["answer"]
        if not (isinstance(opts, list) and len(opts) == 4 and all(isinstance(o, str) and o.strip() for o in opts)):
            bad.append("options 가 문자열 4개가 아님")
        elif len(set(opts)) != 4:
            bad.append("options 에 같은 보기가 있음")
        if not (isinstance(ans, int) and not isinstance(ans, bool) and isinstance(opts, list) and 0 <= ans < len(opts)):
            bad.append("answer 가 options 범위 밖")
    if t == "fill" and isinstance(ex.get("sentence"), str) and "___" not in ex["sentence"]:
        bad.append("fill 문장에 ___ 없음")
    if t == "build":
        ans, extra = ex["answer"], ex["extra"]
        if not (isinstance(ans, list) and len(ans) >= 3 and all(isinstance(x, str) and x for x in ans)):
            bad.append("build answer 토큰이 3개 미만이거나 문자열이 아님")
        elif not (isinstance(extra, list) and len(extra) == 2 and all(isinstance(x, str) and x for x in extra)):
            bad.append("build extra 가 문자열 2개가 아님")
        else:
            joined = ("".join(ans) if lang == "ja" else " ".join(ans))
            for x in extra:
                if x in ans or x.lower() in [a.lower() for a in ans]:
                    bad.append("extra 토큰 %r 이 answer 토큰과 같음" % x)
                elif lang == "en" and _word_in(joined, x):
                    bad.append("answer 로 이은 문장이 extra %r 를 포함함" % x)
                elif lang == "ja" and x in joined:
                    bad.append("answer 로 이은 문장이 extra %r 를 포함함" % x)
            if extra[0] == extra[1]:
                bad.append("extra 토큰 2개가 같음")
    if lang == "ja" and t in ("fill", "build", "listen", "speak") and not ex.get("reading"):
        bad.append("일본어 reading 이 비어 있음")
    if lang == "en" and t in ("fill", "build", "listen", "speak") and (ex.get("reading") or ex.get("pron")):
        bad.append("영어인데 reading/pron 이 채워짐")
    return bad


def check_lesson(les, lang, cell=None):
    """problems of a bank lesson (exercise count 4..10, every exercise, bank_id, source / attribution)"""
    if not isinstance(les, dict):
        return ["레슨이 객체가 아니에요"]
    bad = []
    exs = les.get("exercises")
    if not isinstance(exs, list) or not 4 <= len(exs) <= 10:
        bad.append("exercises 가 4~10개가 아님 (%s)" % (len(exs) if isinstance(exs, list) else "없음"))
        exs = exs if isinstance(exs, list) else []
    for k in ("title", "source", "attribution", "bank_id"):
        if not isinstance(les.get(k), str) or not les.get(k):
            bad.append("키 %s 없음" % k)
    bid = les.get("bank_id")
    if isinstance(bid, str):
        m = re.fullmatch(r"(en|ja)-(\d+)-(\d+)-(\d\d)", bid)
        if not m or m.group(1) != lang or (cell and (int(m.group(2)), int(m.group(3))) != cell):
            bad.append("bank_id %r 가 칸/언어와 맞지 않음" % bid)
    for i, ex in enumerate(exs):
        bad.extend("문제 %d: %s" % (i + 1, p) for p in check_exercise(ex, lang))
    return bad


def lesson_key(les):
    """identity of a problem set: the exercises with their options (a lesson that equals another one is dropped)"""
    return json.dumps(les.get("exercises"), ensure_ascii=False, sort_keys=True)


def lesson_ids(les):
    return {ex.get("tatoeba_id") for ex in les.get("exercises", ())}


def overlap_limit(attempt, per_cell):
    """how many sentences a new lesson may share with an already accepted lesson of its cell: strict first, then looser
    when the cell's good sentences run out (always without exact duplicates)"""
    if attempt < per_cell * 3:
        return 5
    if attempt < per_cell * 5:
        return 7
    return 99


def check_bank(data, lang, min_per_cell=MIN_CELL):
    """problems of a whole lesson bank file"""
    bad = []
    if data.get("v") != PACK_V or data.get("lang") != lang or not data.get("attribution"):
        bad.append("머리말(v/lang/attribution) 이상")
    lessons = data.get("lessons")
    if not isinstance(lessons, dict):
        return bad + ["lessons 가 없음"]
    want = ["%d-%d" % (m, w) for m in range(1, 13) for w in range(1, 5)]
    if sorted(lessons) != sorted(want):
        bad.append("칸이 48개가 아님 (%d개)" % len(lessons))
    ids = set()
    for key in want:
        lst = lessons.get(key) or []
        if len(lst) < min_per_cell:
            bad.append("칸 %s 레슨 %d개 (< %d)" % (key, len(lst), min_per_cell))
        m, w = key.split("-")
        seen = set()
        for les in lst:
            for p in check_lesson(les, lang, (int(m), int(w))):
                bad.append("%s %s: %s" % (key, les.get("bank_id") if isinstance(les, dict) else "?", p))
            if isinstance(les, dict):
                k = lesson_key(les)
                if k in seen:
                    bad.append("칸 %s 에 같은 문제 집합이 두 번 있음 (%s)" % (key, les.get("bank_id")))
                seen.add(k)
                if les.get("bank_id") in ids:
                    bad.append("bank_id 중복 %s" % les.get("bank_id"))
                ids.add(les.get("bank_id"))
    return bad[:50]


# ---- manifest ------------------------------------------------------------------------------------
def check_manifest(pack_dir):
    """problems of pack_dir/manifest.json against the real files (size, SHA-256, every file listed)"""
    bad = []
    mp = os.path.join(pack_dir, "manifest.json")
    try:
        with open(mp, "r", encoding="utf-8") as f:
            man = json.load(f)
    except Exception as e:
        return ["manifest.json 을 읽지 못함: %s" % e]
    if man.get("v") != PACK_V or not isinstance(man.get("files"), list) or not man["files"]:
        return ["manifest.json 모양이 이상함"]
    listed = set()
    for ent in man["files"]:
        p = ent.get("path")
        if not isinstance(p, str) or "/" in p or "\\" in p or p.startswith("."):
            bad.append("이상한 경로 %r" % (p,))
            continue
        listed.add(p)
        fp = os.path.join(pack_dir, p)
        if not os.path.isfile(fp):
            bad.append("%s: 파일이 없음" % p)
            continue
        if os.path.getsize(fp) != ent.get("bytes"):
            bad.append("%s: 크기 불일치 (파일 %d, 기록 %s)" % (p, os.path.getsize(fp), ent.get("bytes")))
        elif sha256_file(fp) != ent.get("sha256"):
            bad.append("%s: SHA-256 불일치" % p)
        if not isinstance(ent.get("records"), int):
            bad.append("%s: records 없음" % p)
    for fn in sorted(os.listdir(pack_dir)):
        if fn != "manifest.json" and os.path.isfile(os.path.join(pack_dir, fn)) and fn not in listed:
            bad.append("%s: manifest 에 없는 파일" % fn)
    return bad


def package_info(name):
    try:
        import importlib.metadata as im
        md = im.metadata(name)
        return md
    except Exception:
        return None


def sources_list():
    """manifest "sources": where the data comes from and under which license (read from package metadata where possible)"""
    wf = package_info("wordfreq")
    wf_lic = "Apache-2.0 (code); data files CC BY-SA 4.0 (see wordfreq README)"
    if wf is not None:
        code = wf.get("License-Expression") or wf.get("License") or ""
        if not code:
            code = next((c.split("::")[-1].strip() for c in (wf.get_all("Classifier") or []) if c.startswith("License ::")), "")
        body = wf.get_payload() or ""
        data = "CC BY-SA 4.0" if re.search(r"Attribution-ShareAlike 4\.0", body) else "unknown (README 확인 필요)"
        wf_lic = "%s (code); data files %s [wordfreq %s]" % (code or "unknown", data, wf.get("Version", "?"))
    oj = package_info("pyopenjtalk-plus")
    oj_lic = "MIT (pyopenjtalk-plus); OpenJTalk BSD-3-Clause"
    if oj is not None:
        lic = oj.get("License-Expression") or oj.get("License") or "MIT"
        oj_lic = "%s (pyopenjtalk-plus %s); OpenJTalk BSD-3-Clause" % (lic, oj.get("Version", "?"))
    sp = package_info("spacy")
    sp_lic = "MIT" if sp is None else "%s (spaCy %s, en_core_web_sm lemma rules)" % (sp.get("License-Expression") or sp.get("License") or "MIT",
                                                                                      sp.get("Version", "?"))
    return [
        {"id": "tatoeba", "license": "CC BY 2.0 FR (sentence text; some CC0)", "url": "https://tatoeba.org"},
        {"id": "wordfreq", "license": wf_lic, "url": "https://github.com/rspeer/wordfreq"},
        {"id": "spacy-lemma-rules", "license": sp_lic, "url": "https://spacy.io"},
        {"id": "espeak-ng-output", "license": "espeak-ng is GPL-3.0; only its pre-computed output (word to IPA) is shipped, no code",
         "url": "https://github.com/espeak-ng/espeak-ng"},
        {"id": "pyopenjtalk-output", "license": oj_lic, "url": "https://github.com/tsukumijima/pyopenjtalk-plus"},
        {"id": "hoehwa-content", "license": "MIT", "url": "https://github.com/Whahan/hoehwa-practice"},
    ]


def make_manifest(file_paths, built):
    """manifest object for {name: path}; names sorted, records read from each JSON"""
    files = []
    for name in sorted(file_paths):
        p = file_paths[name]
        rec = 0
        if name.endswith(".json"):
            with open(p, "r", encoding="utf-8") as f:
                rec = count_records(name, json.load(f))
        files.append({"path": name, "bytes": os.path.getsize(p), "sha256": sha256_file(p), "records": rec})
    return {"v": PACK_V, "built": built, "files": files, "sources": sources_list()}


# ---- English forms ------------------------------------------------------------------------------
# Function-word forms where the rule tables give nonsense (is -> i, his -> hi, as -> a) or no answer (him, us, them)
FORM_OVERRIDES = {
    "am": "be", "is": "be", "are": "be", "was": "be", "were": "be", "been": "be", "being": "be",
    "has": "have", "had": "have", "having": "have", "does": "do", "did": "do", "done": "do", "doing": "do",
    "me": "i", "him": "he", "us": "we", "them": "they", "ca": "can", "wo": "will",
}


def build_forms(cand_words, zipf_of, in_index, cands_fn, tatoeba_forms, observed=None, stop=None):
    """{form: lemma} for lower-case English word forms.
    1. FORM_OVERRIDES.
    2. `observed` {form: {lemma: count}}: what spaCy's full pipeline (with part-of-speech) decided on the lesson-pool sentences;
       the most frequent lemma wins, and a form whose usual lemma is itself stays unmapped.
    3. Other forms: candidates from spaCy's rule / exception tables (cands_fn) and Tatoeba's en_forms (form -> [lemma]);
       the most frequent candidate wins. Function words (`stop`) and one-letter lemmas are never mapped by the rules.
    No part-of-speech information exists on the phone, so ambiguous forms get their most common reading."""
    observed = observed or {}
    stop = stop or ()
    out = {}
    for form in sorted(cand_words):
        if form in FORM_OVERRIDES:
            out[form] = FORM_OVERRIDES[form]
            continue
        votes = observed.get(form)
        if votes:
            lem = sorted(votes, key=lambda k: (-votes[k], k))[0]
            if lem != form and re.fullmatch(r"[a-z]+", lem):
                out[form] = lem
            continue
        if form in stop:
            continue
        cs = []
        for c in list(cands_fn(form) or ()) + list(tatoeba_forms.get(form, ())):
            if c != form and c not in cs and re.fullmatch(r"[a-z]{2,}", c):
                cs.append(c)
        if not cs:
            continue
        best = sorted(cs, key=lambda c: (-zipf_of(c), c))[0]
        if zipf_of(best) <= 0 and not in_index(best):
            continue
        out[form] = best
    return out


def observed_forms(pool_items):
    """{form: {lemma: count}} from the analysed lesson-pool sentences (token = [text, idx, lemma, tag, pos, zipf, stop])"""
    obs = {}
    for it in pool_items:
        for t in it["toks"]:
            s, lem = t[0].lower(), t[2]
            if re.fullmatch(r"[a-z]+", s) and isinstance(lem, str) and lem:
                d = obs.setdefault(s, {})
                d[lem] = d.get(lem, 0) + 1
    return obs


# ----------------------------------------------------------------------------------------------
# runtime (backend modules wired up without server.py)
# ----------------------------------------------------------------------------------------------
_RT = {"cfg": None}


def setup_runtime(cfg):
    """point backend/reading.py and lesson_rules.py at the given DB and (copied) cache folder; idempotent per process"""
    if _RT["cfg"] == cfg:
        return
    import logging
    import warnings
    warnings.filterwarnings("ignore")
    logging.getLogger("backend").setLevel(logging.ERROR)
    import reading
    import lesson_rules
    import phone_pack_ja
    reading.DB_PATH = cfg["db"]
    reading.GLOSS_CACHE = os.path.join(cfg["cache"], "gloss.json")
    lesson_rules.CACHE_DIR = cfg["cache"]
    reading.init(ApiError=BuildError, log=logging.getLogger("backend"))
    cur = None
    if os.path.isfile(CURRICULUM):
        with open(CURRICULUM, "r", encoding="utf-8-sig") as f:
            cur = json.load(f)
    plain = lambda s: str(s or "").replace("**", "").replace("`", "")
    lesson_rules.init(log=logging.getLogger("backend"), ApiError=BuildError, ja_reading=phone_pack_ja.ja_reading,
                      ja_pron=phone_pack_ja.ja_pron, curriculum=lambda: cur, plain=plain)
    _RT["cfg"] = dict(cfg)


def _worker_init(cfg):
    sys.dont_write_bytecode = True
    for p in (BACKEND, HERE):
        if p not in sys.path:
            sys.path.insert(0, p)
    setup_runtime(cfg)
    import lesson_rules
    lesson_rules.pool("en")
    lesson_rules.pool("ja")


def make_cell(args):
    """(lang, month, week, per_cell) -> (lang, month, week, [lessons], stats). Seeds 0, 1, 2 ... in order; a lesson is
    dropped if its problem set already exists in the cell, if it shares too many sentences with an accepted lesson
    (overlap_limit), or if check_lesson finds a problem."""
    lang, month, week, per_cell = args
    import sqlite3
    import lesson_rules
    stage = stage_of(month)
    acc, keys, idsets = [], set(), []
    st = {"dup": 0, "overlap": 0, "invalid": 0, "error": 0, "tried": 0}
    max_attempts = per_cell * 8 + 40
    seed = 0
    while len(acc) < per_cell and seed < max_attempts:
        attempt, seed = seed, seed + 1
        st["tried"] += 1
        try:
            les = lesson_rules.make_lesson(lang, month, week, stage, attempt)
        except sqlite3.Error:
            raise
        except Exception:
            st["error"] += 1
            continue
        les = dict(les)
        les["bank_id"] = "%s-%d-%d-%02d" % (lang, month, week, len(acc) + 1)
        ordered = {"bank_id": les.pop("bank_id")}
        ordered.update(les)
        les = ordered
        if check_lesson(les, lang, (month, week)):
            st["invalid"] += 1
            continue
        k = lesson_key(les)
        if k in keys:
            st["dup"] += 1
            continue
        ids = lesson_ids(les)
        lim = overlap_limit(attempt, per_cell)
        if any(len(ids & o) > lim for o in idsets):
            st["overlap"] += 1
            continue
        keys.add(k)
        idsets.append(ids)
        acc.append(les)
    st["last_seed"] = seed - 1
    return lang, month, week, acc, st


# ----------------------------------------------------------------------------------------------
# build steps. Every step gets the context and returns the object to write
# ----------------------------------------------------------------------------------------------
class Ctx:
    def __init__(self, args, work, cfg):
        self.args, self.work, self.cfg = args, work, cfg
        self.stage = os.path.join(work, "stage")
        self.out = args.out
        self.info = {}           # numbers for the final report
        self._cache = {}

    def path(self, name):
        """staged file if built in this run, else the file already in --out (or None)"""
        p = os.path.join(self.stage, name)
        if os.path.isfile(p):
            return p
        p = os.path.join(self.out, name)
        return p if os.path.isfile(p) else None

    def load(self, name):
        p = self.path(name)
        if p is None:
            raise InputError("%s 가 필요한데 없어요. 먼저 그 파일을 만들어 주세요(--only 를 빼고 전체를 만들면 돼요)." % name)
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)


def step_content(ctx, name):
    src = os.path.join(ctx.args.content, name)
    dst = os.path.join(ctx.stage, name)
    shutil.copyfile(src, dst)
    if sha256_file(src) != sha256_file(dst):
        raise BuildError("%s 사본이 원본과 다름" % name)
    return None


def step_lessons(ctx, lang):
    per_cell = ctx.args.per_cell
    tasks = [(lang, m, w, per_cell) for m in range(1, 13) for w in range(1, 5)]
    t0 = time.time()
    jobs = max(1, ctx.args.jobs)
    if jobs == 1:
        _worker_init(ctx.cfg)
        results = [make_cell(t) for t in tasks]
    else:
        import multiprocessing as mp
        with mp.get_context("spawn").Pool(jobs, initializer=_worker_init, initargs=(ctx.cfg,)) as pool:
            results = pool.map(make_cell, tasks, chunksize=1)
    import reading
    lessons = {}
    tot = {"dup": 0, "overlap": 0, "invalid": 0, "error": 0, "tried": 0}
    short = []
    for _l, m, w, acc, st in results:
        lessons["%d-%d" % (m, w)] = acc
        for k in tot:
            tot[k] += st[k]
        if len(acc) < per_cell:
            short.append("%d-%d:%d" % (m, w, len(acc)))
    n = sum(len(v) for v in lessons.values())
    ctx.info["lessons_" + lang] = {"lessons": n, "seconds": round(time.time() - t0, 1), "rejected": tot, "short_cells": short}
    say("lessons %s: %d lessons in 48 cells, %.1fs, rejected %s%s" % (lang, n, time.time() - t0, tot,
                                                                      (", cells below %d: %s" % (per_cell, " ".join(short))) if short else ""))
    return {"v": PACK_V, "lang": lang, "attribution": reading.ATTRIBUTION, "lessons": lessons}


def practice_stage(it, lens, min_zipf):
    """lowest stage whose own length range and zipf floor the sentence meets (0 if none): the first tier of lesson_rules._eligible"""
    for s in (1, 2, 3, 4):
        lo, hi = lens[s]
        if lo <= it["n"] <= hi and it["dmin"] >= min_zipf[s]:
            return s
    return 0


def step_practice(ctx, lang):
    import reading
    import lesson_rules as L
    import practice
    import phone_pack_ja as J
    P = L.pool(lang)
    lens = L.EN_LEN if lang == "en" else L.JA_LEN
    out, dropped = [], 0
    for it in sorted(P.items, key=lambda x: x["id"]):
        rd = pr = ""
        if lang == "ja":
            rd = J.ja_reading(it["text"])
            pr = J.ja_pron(it["text"])
            if not practice._ja_reading_ok(rd):
                dropped += 1
                continue
        words = len(it["text"].split()) if lang == "en" else int(it.get("n") or len(it["text"]))
        rec = {"id": it["id"], "text": it["text"], "ko": it["ko"], "reading": rd, "pron": pr, "words": words,
               "stage": practice_stage(it, lens, L.MIN_ZIPF), "dmin": round(float(it["dmin"]), 2), "lemmas": list(it["lemmas"])}
        if lang == "en" and practice.dictation_ok(it["text"]):
            rec["dict"] = 1
        out.append(rec)
    ctx.info["practice_" + lang] = {"sentences": len(out), "dropped_reading": dropped}
    say("practice %s: %d sentences (%d dropped: no clean reading)" % (lang, len(out), dropped))
    return {"v": PACK_V, "lang": lang, "attribution": reading.ATTRIBUTION,
            "eligible": {"len": {str(k): list(v) for k, v in lens.items()}, "min_zipf": {str(k): v for k, v in L.MIN_ZIPF.items()}},
            "sentences": out}


def step_examples(ctx, lang):
    import heapq
    import reading
    con = reading._db()
    try:
        sents = {}
        for sid, text, ko in con.execute("SELECT id, text, ko FROM sent WHERE lang=? AND ko IS NOT NULL ORDER BY id", (lang,)):
            if HANGUL.search(ko or ""):
                sents[sid] = (text, ko)
        post = {}
        rows = con.execute("SELECT v.w, p.k, p.sid FROM vocab v JOIN post p ON p.wid = v.id WHERE v.lang=? ORDER BY v.w, p.k, p.sid", (lang,))
        for w, k, sid in rows:
            if sid in sents:
                post.setdefault(w, []).append((k, sid))
        forms_of = {}
        if lang == "en":
            for lemma, form in con.execute("SELECT lemma, form FROM en_forms ORDER BY lemma, form"):
                forms_of.setdefault(lemma, []).append(form)
    finally:
        con.close()
    idx = {}
    used = set()
    for w in sorted(post):
        lists = [post[w]]
        if lang == "en" and w in forms_of and re.fullmatch(r"[a-z]+(?:'[a-z]+)*", w):
            lists += [post[f] for f in forms_of[w] if f in post]
        ids, seen_id, seen_tx = [], set(), set()
        for _k, sid in heapq.merge(*lists):
            tx = sents[sid][0]
            if sid in seen_id or tx in seen_tx:
                continue
            seen_id.add(sid)
            seen_tx.add(tx)
            ids.append(sid)
            if len(ids) >= EXAMPLES_PER_KEY:
                break
        if ids:
            idx[w] = ids
            used.update(ids)
    sent = {str(sid): {"t": sents[sid][0], "ko": sents[sid][1]} for sid in sorted(used)}
    ctx.info["examples_" + lang] = {"sentences": len(sent), "keys": len(idx), "with_ko_total": len(sents)}
    say("examples %s: %d sentences with a Korean translation (%d in DB), %d index keys" % (lang, len(sent), len(sents), len(idx)))
    return {"v": PACK_V, "lang": lang, "attribution": reading.ATTRIBUTION, "sent": sent, "idx": idx}


def top_en_words(n):
    """the n most frequent lower-case words of wordfreq's English list (letters and apostrophes only), most frequent first"""
    import reading
    fd = reading._fdict("en")
    words = [w for w in fd if WF_WORD.fullmatch(w)]
    words.sort(key=lambda w: (-fd[w], w))
    return words[:n]


def step_reading(ctx):
    import reading
    t0 = time.time()
    top = top_en_words(ZIPF_TOP)
    zipf = {w: int(round(reading.zipf(w, "en") * 10)) for w in top}
    con = reading._db()
    try:
        tat_vocab = [w for (w,) in con.execute("SELECT w FROM vocab WHERE lang='en' ORDER BY w") if re.fullmatch(r"[a-z]+", w)]
        tat_forms = {}
        for lemma, form in con.execute("SELECT lemma, form FROM en_forms ORDER BY lemma, form"):
            tat_forms.setdefault(form, []).append(lemma)
    finally:
        con.close()
    index_t, exc_t, rules_t = reading._lem_tables()
    tables = (index_t, exc_t, rules_t)

    def in_index(w):
        return any(w in index_t.get(pos, {}) for pos in ("verb", "noun", "adj", "adv"))

    cache = {}

    def zipf_of(w):
        v = cache.get(w)
        if v is None:
            v = cache[w] = reading.zipf(w, "en")
        return v

    cands = sorted({w for w in top if re.fullmatch(r"[a-z]+", w)} | set(tat_vocab))
    from spacy.lang.en.stop_words import STOP_WORDS
    import lesson_rules
    forms = build_forms(cands, zipf_of, in_index, lambda f: reading.en_lemma_cands(f, tables), tat_forms,
                        observed_forms(lesson_rules.pool("en").items), STOP_WORDS)
    for lem in sorted(set(forms.values())):          # a lemma that is not in the top list still gets its frequency
        if lem not in zipf and zipf_of(lem) > 0:
            zipf[lem] = int(round(zipf_of(lem) * 10))
    ctx.info["reading_en"] = {"forms": len(forms), "zipf": len(zipf), "seconds": round(time.time() - t0, 1)}
    say("reading_en: %d forms, %d zipf entries (%.1fs)" % (len(forms), len(zipf), time.time() - t0))
    return {"forms": {k: forms[k] for k in sorted(forms)}, "zipf": zipf}


def pack_en_words(ctx):
    """lower-case English words of the lesson bank, practice and example sentences (built or already in --out)"""
    words = set()
    bank = ctx.load("lesson_bank_en.json")
    for s in iter_strings(bank["lessons"]):
        words |= en_words_of(s)
    for it in ctx.load("practice_en.json")["sentences"]:
        words |= en_words_of(it["text"])
    for v in ctx.load("examples_en.json")["sent"].values():
        words |= en_words_of(v["t"])
    return words


def step_ipa(ctx):
    import phone_pack_espeak as E
    t0 = time.time()
    words = pack_en_words(ctx)
    n_pack = len(words)
    words |= set(top_en_words(IPA_ZIPF_TOP))
    words = sorted(w for w in words if EN_WORD.fullmatch(w))
    res, single = E.ipa_batch(words, ctx.work)
    ipa = {w: res[w] for w in words if res.get(w)}
    ctx.info["ipa_en"] = {"entries": len(ipa), "pack_words": n_pack, "asked": len(words), "empty": len(words) - len(ipa),
                          "single_fallbacks": single, "seconds": round(time.time() - t0, 1)}
    say("ipa_en: %d entries of %d words (pack words %d), %d single-word fallbacks (%.1fs)" % (len(ipa), len(words), n_pack, single, time.time() - t0))
    return ipa


def ja_surfaces(ctx):
    """Japanese surface forms for the reading map: Tatoeba ja vocabulary + tokens / chunks of the lesson pool sentences"""
    import reading
    import lesson_rules as L
    cand = set()
    con = reading._db()
    try:
        for (w,) in con.execute("SELECT w FROM vocab WHERE lang='ja'"):
            cand.add(w)
    finally:
        con.close()
    for it in L.pool("ja").items:
        for t in it["toks"]:
            cand.add(t[0])
            if t[6]:
                cand.add(t[2])
        for ch in it.get("bt") or ():
            cand.add(ch)
    return cand


def keep_surface(s, J, JA_CHARS):
    return 1 <= len(s) <= 12 and not re.search(r"\s", s) and bool(JA_CHARS.search(s)) and not J.kana_only(s)


def step_jamap(ctx):
    import reading
    import phone_pack_ja as J
    t0 = time.time()
    out = {}
    skipped = 0
    for s in sorted(ja_surfaces(ctx)):
        if not keep_surface(s, J, reading.JA_CHARS):
            continue
        r = J.ja_reading(s)
        if not HIRA_FULL.fullmatch(r) or r == s:
            skipped += 1
            continue
        out[s] = r
    ctx.info["ja_reading_map"] = {"entries": len(out), "unreadable": skipped, "seconds": round(time.time() - t0, 1)}
    say("ja_reading_map: %d entries (%d skipped: no clean kana reading) (%.1fs)" % (len(out), skipped, time.time() - t0))
    return out


def step_vocab(ctx):
    """vocab_en.txt / vocab_ja.txt for the gloss builder: lemmas, most frequent first"""
    import reading
    vd = ctx.args.vocab_dir
    os.makedirs(vd, exist_ok=True)
    rd = ctx.load("reading_en.json")
    forms, zipf = rd["forms"], rd["zipf"]
    cand = {}
    for w in zipf:
        lem = forms.get(w, w)
        if re.fullmatch(r"[a-z]+", lem) and lem in zipf:
            cand[lem] = zipf[lem]
    try:
        for w in pack_en_words(ctx):
            lem = forms.get(w, w)
            if re.fullmatch(r"[a-z]+", lem) and lem not in cand:
                z = int(round(reading.zipf(lem, "en") * 10))
                if z > 0:
                    cand[lem] = z
    except InputError:
        pass
    en = sorted(cand, key=lambda w: (-cand[w], w))[:VOCAB_EN_N]
    con = reading._db()
    try:
        ja_c = {}
        for (w,) in con.execute("SELECT w FROM vocab WHERE lang='ja'"):
            if reading.JA_CHARS.search(w) and not re.search(r"\s", w) and len(w) <= 12:
                ja_c[w] = reading.zipf(w, "ja")
    finally:
        con.close()
    ja = sorted(ja_c, key=lambda w: (-ja_c[w], w))[:VOCAB_JA_N]
    for name, lst in (("vocab_en.txt", en), ("vocab_ja.txt", ja)):
        with open(os.path.join(vd, name), "wb") as f:
            f.write(("\n".join(lst) + "\n").encode("utf-8"))
    say("vocab lists: en %d, ja %d -> %s" % (len(en), len(ja), vd))
    ctx.info["vocab"] = {"en": len(en), "ja": len(ja)}


# ----------------------------------------------------------------------------------------------
# per-file checks done before anything is moved into --out
# ----------------------------------------------------------------------------------------------
def check_built_file(ctx, name):
    p = os.path.join(ctx.stage, name)
    with open(p, "rb") as f:
        raw = f.read()
    bad = []
    if b"\r" in raw:
        bad.append("CR 문자가 있음")
    if not raw.endswith(b"\n"):
        bad.append("끝에 줄바꿈이 없음")
    if len(raw) > MAX_FILE_BYTES:
        bad.append("파일이 %d MB 를 넘음" % (MAX_FILE_BYTES // 1048576))
    data = json.loads(raw.decode("utf-8"))
    lang = "ja" if name.endswith("_ja.json") else "en"
    if name in LESSON_FILES:
        bad.extend(check_bank(data, lang, min(MIN_CELL, ctx.args.per_cell)))
    elif name in PRACTICE_FILES:
        if len(data.get("sentences", ())) < 500:
            bad.append("연습 문장이 너무 적음")
    elif name in EXAMPLE_FILES:
        sent, idx = data.get("sent", {}), data.get("idx", {})
        if len(sent) < 500 or len(idx) < 500:
            bad.append("예문/색인이 너무 적음")
        if any(str(i) not in sent for ids in idx.values() for i in ids):
            bad.append("색인이 없는 문장을 가리킴")
    elif name == "reading_en.json":
        if len(data.get("forms", ())) < 1000 or len(data.get("zipf", ())) < 10000:
            bad.append("어형/빈도표가 너무 적음")
    elif name == "ipa_en.json":
        if len(data) < 10000 or not all(isinstance(v, str) and v for v in data.values()):
            bad.append("IPA 표가 너무 적거나 빈 값이 있음")
    elif name == "ja_reading_map.json":
        if len(data) < 1000 or not all(HIRA_FULL.fullmatch(v) for v in data.values()):
            bad.append("읽기 표가 너무 적거나 가나가 아닌 값이 있음")
    return bad


# ----------------------------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------------------------
def parse_only(text):
    names = []
    for part in [x.strip() for x in (text or "").split(",") if x.strip()]:
        if part in ALIASES:
            names.extend(ALIASES[part])
            continue
        n = part if part.endswith(".json") else part + ".json"
        if n not in BUILT_FILES:
            raise InputError("--only 에 알 수 없는 이름이 있어요: %s (가능: %s)" % (part, ", ".join(sorted(BUILT_FILES) + sorted(ALIASES))))
        names.append(n)
    return [n for n in BUILD_ORDER if n in names]


def check_inputs(args, names):
    """Korean error messages for everything that is missing (the pack is not touched if there are any)"""
    bad = []
    if not os.path.isfile(args.db):
        bad.append("예문 DB 를 찾을 수 없어요: %s (backend\\tatoeba_build.py 로 만들거나 --db 로 알려 주세요)" % args.db)
    needs_pool = any(n in names for n in LESSON_FILES + PRACTICE_FILES + ["ja_reading_map.json"])
    if needs_pool:
        for fn in POOL_FILES:
            if not os.path.isfile(os.path.join(args.cache, fn)):
                bad.append("레슨 풀을 찾을 수 없어요: %s (서버를 한 번 켜서 만들거나 --cache 로 알려 주세요)" % os.path.join(args.cache, fn))
        if any(n in names for n in LESSON_FILES) and not os.path.isfile(CURRICULUM):
            bad.append("curriculum.json 을 찾을 수 없어요: %s" % CURRICULUM)
    for n in names:
        if n in CONTENT_FILES and not os.path.isfile(os.path.join(args.content, n)):
            bad.append("콘텐츠 원본을 찾을 수 없어요: %s" % os.path.join(args.content, n))
    if not bad:
        import reading
        reading.DB_PATH = args.db
        if not reading.tatoeba_ready():
            bad.append("예문 DB 를 열 수 없거나 필요한 표가 없어요(깨졌거나 SQLite 파일이 아님): %s" % args.db)
    if args.per_cell < 1:
        bad.append("--per-cell 은 1 이상이어야 해요")
    return bad


def prepare_cache(args, work):
    """copy the cache files the builders read into the work folder; the originals are never opened for writing"""
    dst = os.path.join(work, "cache")
    os.makedirs(dst, exist_ok=True)
    for fn in POOL_FILES + ["lesson_tri_en.bin", "gloss.json"]:
        src = os.path.join(args.cache, fn)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(dst, fn))
    return dst


def install(ctx, names_built, manifest_obj):
    """move the staged files into --out (each file via a temporary name + os.replace), manifest last"""
    os.makedirs(ctx.out, exist_ok=True)
    for name in names_built + ["manifest.json"]:
        src = os.path.join(ctx.stage, name)
        tmp = os.path.join(ctx.out, name + ".tmp")
        shutil.copyfile(src, tmp)
        os.replace(tmp, os.path.join(ctx.out, name))


def run(args):
    names = parse_only(args.only) if args.only else list(BUILD_ORDER)
    bad = check_inputs(args, names)
    if bad:
        for b in bad:
            print("오류: " + b, file=sys.stderr)
        print("팩을 만들지 않았어요(기존 팩은 그대로예요).", file=sys.stderr)
        return 2
    work = tempfile.mkdtemp(prefix="phonepack_")
    try:
        cache = prepare_cache(args, work)
        cfg = {"db": args.db, "cache": cache}
        ctx = Ctx(args, work, cfg)
        os.makedirs(ctx.stage)
        say("work folder %s, db %s" % (work, os.path.basename(args.db)))
        built = []
        need_rt = any(n not in CONTENT_FILES and n != "ipa_en.json" for n in names) or bool(args.vocab_dir)
        if need_rt:
            setup_runtime(cfg)
        if any(n in LESSON_FILES + PRACTICE_FILES + ["ja_reading_map.json"] for n in names):
            import lesson_rules
            lesson_rules.pool("en")        # loads / (re)builds the pools once here, before worker processes start
            lesson_rules.pool("ja")
        for name in names:
            lang = "ja" if name.endswith("_ja.json") else "en"
            if name in CONTENT_FILES:
                step_content(ctx, name)
            else:
                if name in LESSON_FILES:
                    obj = step_lessons(ctx, lang)
                elif name in PRACTICE_FILES:
                    obj = step_practice(ctx, lang)
                elif name in EXAMPLE_FILES:
                    obj = step_examples(ctx, lang)
                elif name == "reading_en.json":
                    obj = step_reading(ctx)
                elif name == "ja_reading_map.json":
                    obj = step_jamap(ctx)
                elif name == "ipa_en.json":
                    obj = step_ipa(ctx)
                else:
                    raise BuildError("모르는 파일 " + name)
                write_json(os.path.join(ctx.stage, name), obj)
            problems = check_built_file(ctx, name)
            if problems:
                for p in problems:
                    print("검사 실패 %s: %s" % (name, p), file=sys.stderr)
                print("검사에 실패해서 기존 팩을 바꾸지 않았어요.", file=sys.stderr)
                return 1
            built.append(name)
        if args.vocab_dir:
            step_vocab(ctx)
        # the manifest lists every file the pack folder will contain afterwards (also files of other tools, e.g. gloss_*.json)
        final = {}
        if os.path.isdir(args.out):
            for fn in sorted(os.listdir(args.out)):
                fp = os.path.join(args.out, fn)
                if os.path.isfile(fp) and fn != "manifest.json" and not fn.endswith(".tmp"):
                    final[fn] = fp
        for fn in built:
            final[fn] = os.path.join(ctx.stage, fn)
        total = sum(os.path.getsize(p) for p in final.values())
        if total > MAX_PACK_BYTES:
            print("검사 실패: 팩이 %.1f MB (한도 %d MB)" % (total / 1048576.0, MAX_PACK_BYTES // 1048576), file=sys.stderr)
            return 1
        built_at = args.built or datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        man = make_manifest(final, built_at)
        write_json(os.path.join(ctx.stage, "manifest.json"), man, indent=1)
        install(ctx, built, man)
        problems = check_manifest(args.out)
        if problems:
            for p in problems:
                print("설치 후 검사 실패: " + p, file=sys.stderr)
            return 1
        say("done: %d files built, pack %.2f MB in %s" % (len(built), total / 1048576.0, args.out))
        for ent in man["files"]:
            print("  %-24s %9d bytes %7d records" % (ent["path"], ent["bytes"], ent["records"]))
        print("INFO " + json.dumps(ctx.info, ensure_ascii=False, sort_keys=True))
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv=None):
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="폰 단독 앱의 데이터 팩(godot/data/pack)을 만듭니다.")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--content", default=DEFAULT_CONTENT)
    ap.add_argument("--per-cell", type=int, default=20)
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--vocab-dir", default="")
    ap.add_argument("--built", default="")
    args = ap.parse_args(argv)
    for k in ("out", "db", "cache", "content"):
        setattr(args, k, os.path.abspath(getattr(args, k)))
    if args.vocab_dir:
        args.vocab_dir = os.path.abspath(args.vocab_dir)
    try:
        return run(args)
    except InputError as e:
        print("오류: %s" % e, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("중단했어요. 기존 팩은 그대로예요.", file=sys.stderr)
        return 1
    except Exception as e:
        import traceback
        traceback.print_exc()
        print("팩 만들기에 실패했어요(기존 팩은 그대로예요): %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
