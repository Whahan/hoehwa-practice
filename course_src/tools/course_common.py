# -*- coding: utf-8 -*-
"""Shared helpers of the course content tools (stdlib only, offline): tokenizer, manuscript loader, lexicon, limits.

Manuscript folder layout (`--in <dir>`, e.g. course_src\\en):
    skeleton.json        72-week plan (+ the word assignment table for the weeks written so far)   [optional]
    policy.json          blocked words, allowed names, count limits ...                              [optional]
    weeks\\w001.json ...  one file per week (format: README.txt, design docs\\v200_design.md section 10)

The tokenizer is the one the app's LexiconGuard has to use too (design 3.3 R2): NFKC, lower case, "’" -> "'",
tokens are runs of letters/digits that may contain an inner apostrophe; hyphens and all other punctuation split.
"""
import json
import re
import unicodedata
from pathlib import Path

WEEKS = 72
TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent.parent

HANGUL = re.compile(r"[가-힣]")
HAN = re.compile(r"[㐀-䶿一-鿿豈-﫿]")
FOREIGN = re.compile(r"[Ѐ-ӿ؀-ۿ฀-๿֐-׿Ͱ-Ͽ぀-ヿ]")
DAY_MAX = 7
WORD_DAY_MAX = 4          # new words / patterns are introduced on D1..D4 (design 2.2); D5..D7 have no new words
SPEAK_PROMPT_DAY = 6

DEFAULT_LIMITS = {
    "min_sentences": 36,            # sentences per week
    "pattern_min_sentences": 6,     # sentences per pattern
    "word_min_sentences": 2,        # sentences per active word (same week)
    "active_range": [10, 30],
    "intro_active_range": [20, 28],     # weeks 1-4
    "synth_active_range": [10, 16],     # weeks 16, 32, 48, 60, 68
    "final_active_range": [0, 30],      # weeks 69-72
    "passive_range": [8, 16],           # weeks 5+
    "intro_passive_range": [0, 16],     # weeks 1-4
    "pattern_range": [3, 5],
    "intro_pattern_range": [1, 2],
    "synth_pattern_range": [0, 3],
    "final_pattern_range": [0, 3],
    "dialogue_lines_early": [2, 4],     # weeks 1-7
    "dialogue_lines_late": [6, 10],     # weeks 8+
    "speak_prompts_per_month": 3,
    "tatoeba_max_ratio": 0.25,
    "total_active": [1714, 1894],       # 1,804 +- 90 (skeleton, all 72 weeks)
    "total_passive": [892, 1012],       # 952 +- 60
    "assign_active_1_16": [370, 410],
    "assign_passive_1_16": [110, 130],
    "word_day_split_tol": 1,
}
SYNTH_WEEKS = {16, 32, 48, 60, 68}


class Problem:
    __slots__ = ("code", "where", "detail", "warn")

    def __init__(self, code, where, detail="", warn=False):
        self.code, self.where, self.detail, self.warn = code, where, detail, warn

    def line(self):
        return ("WARN " if self.warn else "  ") + self.code + " " + self.where + (" " + self.detail if self.detail else "")


# ------------------------------------------------------------------------------------------------ text helpers
def nfkc(text):
    return unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'").replace("ʼ", "'")


def tokenize(text):
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", nfkc(text).lower())


def norm_en(text):
    return " ".join(tokenize(text))


def norm_ko(text):
    return re.sub(r"[\s.,!?~…·'\"“”]", "", nfkc(text))


def ko_keys(ko):
    parts = re.split(r"[/,;·、]", nfkc(ko))
    return {norm_ko(re.sub(r"\(.*?\)", "", p)) for p in parts if norm_ko(re.sub(r"\(.*?\)", "", p))}


def is_str(x):
    return isinstance(x, str)


def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def parse_weeks_arg(text):
    """"5-8" -> (5, 8), "5" -> (5, 5); None/"" -> None; bad text -> ValueError."""
    if text is None or str(text).strip() == "":
        return None
    m = re.fullmatch(r"\s*(\d{1,2})\s*(?:-\s*(\d{1,2}))?\s*", str(text))
    if not m:
        raise ValueError("bad --weeks: " + str(text))
    a = int(m.group(1))
    b = int(m.group(2)) if m.group(2) else a
    if not (1 <= a <= b <= WEEKS):
        raise ValueError("bad --weeks range: " + str(text))
    return (a, b)


def stage_of_week(w):
    for hi, s in ((4, 0), (16, 1), (32, 2), (48, 3), (60, 4), (68, 5)):
        if w <= hi:
            return s
    return 6


def legacy_stage(w):
    return 1 if w <= 16 else 2 if w <= 36 else 3 if w <= 56 else 4


def week_class(w):
    if w <= 4:
        return "intro"
    if w in SYNTH_WEEKS:
        return "synth"
    if w >= 69:
        return "final"
    return "normal"


def limits_of(policy):
    lim = dict(DEFAULT_LIMITS)
    over = (policy or {}).get("limits")
    if isinstance(over, dict):
        for k, v in over.items():
            if k in lim:
                lim[k] = v
    return lim


def read_json(path):
    """-> (data, error_text). Error text never contains file content."""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f), ""
    except FileNotFoundError:
        return None, "missing"
    except json.JSONDecodeError as e:
        return None, "json_error line=%d col=%d" % (e.lineno, e.colno)
    except (OSError, UnicodeDecodeError) as e:
        return None, "unreadable " + e.__class__.__name__


def dumps_compact(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


# ------------------------------------------------------------------------------------------------ loading
class Course:
    """A manuscript folder in memory. `weeks` holds the raw week dicts (only files that parsed as a JSON object)."""

    def __init__(self, in_dir):
        self.in_dir = Path(in_dir)
        self.policy = {}
        self.skeleton = None
        self.weeks = {}          # w -> dict
        self.week_files = {}     # w -> Path
        self.problems = []       # load-time Problems (SCHEMA)
        self.has_policy = False

    def load(self):
        d = self.in_dir
        if not d.is_dir():
            self.problems.append(Problem("SCHEMA", "in", "in_dir_missing"))
            return self
        pol, err = read_json(d / "policy.json")
        if err == "missing":
            self.policy = {}
        elif err:
            self.problems.append(Problem("SCHEMA", "policy.json", err))
        elif isinstance(pol, dict):
            self.policy, self.has_policy = pol, True
        else:
            self.problems.append(Problem("SCHEMA", "policy.json", "not_an_object"))
        sk, err = read_json(d / "skeleton.json")
        if err == "missing":
            self.skeleton = None
        elif err:
            self.problems.append(Problem("SCHEMA", "skeleton.json", err))
        elif isinstance(sk, dict):
            self.skeleton = sk
        else:
            self.problems.append(Problem("SCHEMA", "skeleton.json", "not_an_object"))
        wdir = d / "weeks"
        if wdir.is_dir():
            for p in sorted(wdir.glob("*.json")):
                m = re.fullmatch(r"w(\d{3})\.json", p.name)
                if not m:
                    self.problems.append(Problem("SCHEMA", p.name, "bad_file_name"))
                    continue
                w = int(m.group(1))
                data, err = read_json(p)
                if err:
                    self.problems.append(Problem("SCHEMA", p.name, err))
                    continue
                if not isinstance(data, dict):
                    self.problems.append(Problem("SCHEMA", p.name, "not_an_object"))
                    continue
                if not (1 <= w <= WEEKS):
                    self.problems.append(Problem("SCHEMA", p.name, "week_out_of_range"))
                    continue
                self.weeks[w] = data
                self.week_files[w] = p
        return self

    def limits(self):
        return limits_of(self.policy)

    # skeleton helpers ---------------------------------------------------------------------------
    def skeleton_assign(self):
        """Word assignment table: list of dicts (id, lemma, pos, role, w, d); tolerant of two layouts."""
        sk = self.skeleton or {}
        out = []
        a = sk.get("assign")
        if isinstance(a, list):
            out += [x for x in a if isinstance(x, dict)]
        for wk in sk.get("weeks", []) if isinstance(sk.get("weeks"), list) else []:
            if isinstance(wk, dict) and isinstance(wk.get("assign"), list):
                for x in wk["assign"]:
                    if isinstance(x, dict):
                        x = dict(x)
                        x.setdefault("w", wk.get("w"))
                        out.append(x)
        return out

    def skeleton_weeks(self):
        sk = self.skeleton or {}
        ws = sk.get("weeks")
        return [x for x in ws if isinstance(x, dict)] if isinstance(ws, list) else []


# ------------------------------------------------------------------------------------------------ lexicon
def week_pattern_day(idx, p):
    d = p.get("d") if isinstance(p, dict) else None
    return d if is_int(d) and 1 <= d <= DAY_MAX else min(idx + 1, 4)


class Lexicon:
    """token -> [(o, word_id, kind)], word_id -> info. Built from week files or from the skeleton assignment table."""

    def __init__(self):
        self.tok = {}
        self.words = {}
        self.chunks = []       # (tokens tuple, word_id, o)

    def _reg(self, token, o, wid, kind):
        self.tok.setdefault(token, []).append((o, wid, kind))

    def add(self, wid, en, pos, role, o, say="", forms=(), alt=(), pat_o=None, week=None):
        src_text = say if (say and re.search(r"[0-9$%&@#+=/]", en or "")) else en
        toks = tokenize(src_text)
        self.words[wid] = {"id": wid, "en": en, "pos": pos, "role": role, "o": o, "tokens": toks, "w": week}
        kind = "word" if len(toks) <= 1 else "chunk"
        for t in toks:
            self._reg(t, o, wid, kind)
        if len(toks) > 1:
            self.chunks.append((tuple(toks), wid, o))
        for f in forms or ():
            if isinstance(f, dict) and is_str(f.get("f")):
                po = (pat_o or {}).get(f.get("pat"), 0)
                fo = max(o, po)
                for t in tokenize(f["f"]):
                    self._reg(t, fo, wid, "form")
        for a in alt or ():
            if is_str(a):
                for t in tokenize(a):
                    self._reg(t, o, wid, "alt")

    def min_o(self, token):
        c = self.tok.get(token)
        return min(x[0] for x in c) if c else None

    def candidates(self, token):
        return self.tok.get(token, [])

    def used_words(self, tokens, item_o):
        """ids of lexicon entries whose token(s) occur in `tokens` (chunks: contiguous), o <= item_o."""
        ids = set()
        for t in tokens:
            for o, wid, kind in self.tok.get(t, []):
                if kind != "chunk" and o <= item_o:
                    ids.add(wid)
        n = len(tokens)
        for seq, wid, o in self.chunks:
            if o <= item_o and len(seq) <= n:
                for i in range(n - len(seq) + 1):
                    if tuple(tokens[i:i + len(seq)]) == seq:
                        ids.add(wid)
                        break
        return ids


def pattern_o_map(course):
    pat_o = {}
    for w, wk in course.weeks.items():
        pats = wk.get("patterns") if isinstance(wk.get("patterns"), list) else []
        for i, p in enumerate(pats):
            if isinstance(p, dict) and is_str(p.get("id")):
                pat_o[p["id"]] = w * 10 + week_pattern_day(i, p)
    return pat_o


def build_lexicon(course, mode="files", weeks=None):
    """weeks: iterable of week numbers whose files may be used (None = all loaded); mode "skeleton" takes the words
    from the assignment table and only the forms / alt spellings from the week files."""
    lex = Lexicon()
    pat_o = pattern_o_map(course)
    use = set(course.weeks) if weeks is None else set(weeks) & set(course.weeks)
    if mode == "skeleton":
        file_words = {}
        for w in use:
            for x in course.weeks[w].get("words", []) if isinstance(course.weeks[w].get("words"), list) else []:
                if isinstance(x, dict) and is_str(x.get("id")):
                    file_words[x["id"]] = x
        for a in course.skeleton_assign():
            wid, w, d = a.get("id"), a.get("w"), a.get("d")
            if not (is_str(wid) and is_int(w) and is_int(d) and is_str(a.get("lemma"))):
                continue
            fw = file_words.get(wid, {})
            lex.add(wid, a["lemma"], a.get("pos"), a.get("role", "active"), w * 10 + d, say=fw.get("say", "") or "",
                    forms=fw.get("forms") or (), alt=fw.get("alt") or (), pat_o=pat_o, week=w)
    else:
        for w in sorted(use):
            for x in course.weeks[w].get("words", []) if isinstance(course.weeks[w].get("words"), list) else []:
                if isinstance(x, dict) and is_str(x.get("id")) and is_str(x.get("en")) and is_int(x.get("d")):
                    lex.add(x["id"], x["en"], x.get("pos"), x.get("role", "active"), w * 10 + x["d"], say=x.get("say", "") or "",
                            forms=x.get("forms") or (), alt=x.get("alt") or (), pat_o=pat_o, week=w)
    return lex


# ------------------------------------------------------------------------------------------------ items
def iter_items(course, weeks):
    """Yield dicts {kind, id, w, o, en, say, ko, raw} for every English text item of the given weeks.
    kinds: sentence, line (dialogue line, id "<dialogue>#<n>"), prompt (speak prompt), pattern (tpl), word (en/say/ko)."""
    for w in sorted(weeks):
        wk = course.weeks.get(w)
        if not wk:
            continue
        for x in wk.get("sentences", []) or []:
            yield {"kind": "sentence", "id": x.get("id"), "w": w, "d": x.get("d"), "en": x.get("en", ""), "say": x.get("say", ""),
                   "ko": x.get("ko", ""), "raw": x}
        for dlg in wk.get("dialogues", []) or []:
            ddef = dlg.get("d") if is_int(dlg.get("d")) else 4
            for i, ln in enumerate(dlg.get("lines", []) or [], 1):
                yield {"kind": "line", "id": "%s#%d" % (dlg.get("id"), i), "w": w, "d": ln.get("d", ddef), "en": ln.get("en", ""),
                       "say": ln.get("say", ""), "ko": ln.get("ko", ""), "raw": ln, "dialogue": dlg.get("id")}
        for x in wk.get("speak_prompts", []) or []:
            yield {"kind": "prompt", "id": x.get("id"), "w": w, "d": SPEAK_PROMPT_DAY, "en": x.get("en", ""), "say": x.get("say", ""),
                   "ko": x.get("ko", ""), "raw": x}


def count_items(course, weeks):
    """Review item ids per kind (the rows R1_X*.tsv must have): words, patterns, sentences, dialogue lines."""
    rows = []
    for w in sorted(weeks):
        wk = course.weeks.get(w)
        if not wk:
            continue
        for x in wk.get("words", []) or []:
            rows.append(("word", x.get("id")))
        for x in wk.get("patterns", []) or []:
            rows.append(("pattern", x.get("id")))
        for x in wk.get("sentences", []) or []:
            rows.append(("sentence", x.get("id")))
        for dlg in wk.get("dialogues", []) or []:
            for i, _ in enumerate(dlg.get("lines", []) or [], 1):
                rows.append(("dialogue_line", "%s#%d" % (dlg.get("id"), i)))
    return rows


def select_weeks(course, weeks_arg):
    if weeks_arg is None:
        return sorted(course.weeks)
    a, b = weeks_arg
    return list(range(a, b + 1))
