# -*- coding: utf-8 -*-
"""Course manuscript linter (design docs\\v200_design.md section 9.2). Offline, standard library only.

  python -X utf8 course_src\\tools\\check_course.py --in course_src\\en [--weeks 1-4] [--strict]
         [--skeleton] [--lexicon-from files|skeleton] [--grammar] [--tatoeba-db <path>]
         [--count-items] [--review <tsv>]

Exit code 0 = pass, 1 = fail. First line of a failure: `CHECK_FAIL <CODE>`; last line `CHECK_FAIL ... violations=N`
(pass: last line `CHECK_OK ... violations=0`). Output carries ids, codes and single tokens only, never manuscript text.

Codes: SCHEMA ORDER UNKNOWN_TOKEN NUM_SAY KO_HANGUL KO_HANJA DUP_EN DUP_KO SAME_KO_OPTIONS BLOCKED PERSONAL COUNT
       CANON TATOEBA GRAMMAR (GRAMMAR only with --grammar; without LanguageTool: `GRAMMAR_SKIPPED`, reported as
       "not verified"). --strict turns warnings (unknown keys, Korean style, missing policy ...) into violations.
"""
import argparse
import csv
import importlib.util
import os
import tempfile
import re
import sqlite3
import sys
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import course_common as cc  # noqa: E402
import forms_en  # noqa: E402
import numbers_en as ne  # noqa: E402
from course_common import Problem, is_int, is_str  # noqa: E402

CODES = ["SCHEMA", "ORDER", "UNKNOWN_TOKEN", "NUM_SAY", "KO_HANGUL", "KO_HANJA", "DUP_EN", "DUP_KO", "SAME_KO_OPTIONS",
         "BLOCKED", "PERSONAL", "COUNT", "CANON", "FORM_SUSPECT", "TATOEBA", "GRAMMAR"]
POS = {"n", "v", "adj", "adv", "prep", "pron", "det", "art", "conj", "interj", "intj", "num", "aux", "modal", "propn",
       "chunk", "phr", "part", "exclam", "contr"}
NOTE_KINDS = {"spelling", "vocab", "culture", "fact", "sound"}
PROMPT_KINDS = {"read", "answer", "intro", "question"}
SECRET_FREE_DEFAULT_PAIRS = [("colour", "color"), ("favourite", "favorite"), ("centre", "center"), ("neighbour", "neighbor"),
                             ("flavour", "flavor"), ("honour", "honor"), ("labour", "labor"), ("behaviour", "behavior"),
                             ("theatre", "theater"), ("metre", "meter"), ("grey", "gray"), ("cheque", "check_bank"),
                             ("licence", "license_n")]
# pairs whose US form is also a different valid word are left out of the automatic check (cheque/check, licence/license)
AUTO_PAIRS = [(ca, us) for ca, us in SECRET_FREE_DEFAULT_PAIRS if not us.endswith(("_bank", "_n"))]

WORD_KEYS = {"id", "en", "pos", "ko", "ko2", "ipa", "say", "tags", "role", "d", "o", "forms", "alt", "syn", "ca", "src", "note"}
SENT_KEYS = {"id", "en", "ko", "say", "words", "pat", "d", "o", "scope", "accept", "src", "tid", "note"}
PAT_KEYS = {"id", "tpl", "slots", "title_ko", "grammar_ko", "d", "o", "examples", "note"}
DLG_KEYS = {"id", "w", "title_ko", "scene", "user", "lines", "d", "note"}
LINE_KEYS = {"s", "en", "ko", "say", "words", "d", "o", "hint_ko", "accept", "note"}
PROMPT_KEYS = {"id", "kind", "en", "ko", "say", "expect_any", "note"}
NOTE_KEYS = {"id", "kind", "text_ko", "ca", "us", "en", "fact_date", "note"}
WEEK_KEYS = {"v", "w", "title_ko", "can_do", "scene", "words", "patterns", "sentences", "dialogues", "speak_prompts", "notes"}

ID_WORD = re.compile(r"^w\d{4}$")
ID_SENT = re.compile(r"^s\d{4}$")
ID_DLG = re.compile(r"^d\d{4}$")
ID_PAT = re.compile(r"^p_[a-z0-9_]+$")
ID_PROMPT = re.compile(r"^sp\d{4}$")
ID_NOTE = re.compile(r"^n\d{4}$")
KO_BANMAL = re.compile(r"(?<!니)(다|야|어|아|해|지|자|래|냐)[.?!~…\s]*$")  # plain-style endings (not -니다)


def _where(w, ident=None):
    return "w%03d" % w + (":" + str(ident) if ident else "")


def _keys_unknown(d, allowed, where, out):
    for k in d:
        if k not in allowed and not str(k).startswith("_"):
            out.append(Problem("SCHEMA", where, "unknown_key=" + str(k), warn=True))


def _list_of_str(x):
    return isinstance(x, list) and all(is_str(i) for i in x)


# ================================================================================================ SCHEMA (week files)
def validate_week(w, wk, fname, lim, out):
    """Append SCHEMA problems of one week file to `out`. Never raises on malformed data."""
    W = _where(w)
    if wk.get("v") != 1 or not is_int(wk.get("v")):
        out.append(Problem("SCHEMA", W, "v_must_be_1"))
    if wk.get("w") != w or not is_int(wk.get("w")):
        out.append(Problem("SCHEMA", W, "w_does_not_match_file_name"))
    _keys_unknown(wk, WEEK_KEYS, W, out)
    for key in ("words", "patterns", "sentences", "dialogues"):
        if not isinstance(wk.get(key), list):
            out.append(Problem("SCHEMA", W, key + "_must_be_a_list"))
    for key in ("speak_prompts", "notes"):
        if key in wk and not isinstance(wk.get(key), list):
            out.append(Problem("SCHEMA", W, key + "_must_be_a_list"))
    seen = set()

    def ident(x, rx, kind):
        i = x.get("id")
        wh = _where(w, i if is_str(i) else kind + "?")
        if not (is_str(i) and rx.match(i)):
            out.append(Problem("SCHEMA", wh, "bad_id"))
            return wh, None
        if i in seen:
            out.append(Problem("SCHEMA", wh, "duplicate_id_in_file"))
        seen.add(i)
        return wh, i

    def need_str(x, key, wh, allow_empty=False):
        v = x.get(key)
        if not is_str(v) or (not allow_empty and not v.strip()):
            out.append(Problem("SCHEMA", wh, key + "_must_be_text"))
            return False
        return True

    def en_ok(x, key, wh):
        v = x.get(key)
        if is_str(v) and (cc.HANGUL.search(v) or cc.HAN.search(v)):
            out.append(Problem("SCHEMA", wh, key + "_has_non_english_letters"))

    def day(x, wh, lo=1, hi=cc.DAY_MAX, required=False):
        d = x.get("d")
        if d is None:
            if required:
                out.append(Problem("SCHEMA", wh, "d_missing"))
            return None
        if not (is_int(d) and lo <= d <= hi):
            out.append(Problem("SCHEMA", wh, "d_out_of_range"))
            return None
        if "o" in x and x["o"] != w * 10 + d:
            out.append(Problem("SCHEMA", wh, "o_does_not_match_w_d"))
        return d

    for x in wk.get("words", []) if isinstance(wk.get("words"), list) else []:
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "word_not_an_object"))
            continue
        wh, i = ident(x, ID_WORD, "word")
        _keys_unknown(x, WORD_KEYS, wh, out)
        if need_str(x, "en", wh):
            en_ok(x, "en", wh)
            if len(x["en"]) > 60:
                out.append(Problem("SCHEMA", wh, "en_too_long"))
        if x.get("pos") not in POS:
            out.append(Problem("SCHEMA", wh, "bad_pos"))
        if need_str(x, "ko", wh) and len(x["ko"].strip()) > 12:
            out.append(Problem("SCHEMA", wh, "ko_longer_than_12"))
        if "ko2" in x and not is_str(x["ko2"]):
            out.append(Problem("SCHEMA", wh, "ko2_must_be_text"))
        if "ipa" not in x or not is_str(x.get("ipa")):
            out.append(Problem("SCHEMA", wh, "ipa_must_be_text"))
        elif not x["ipa"].strip() and is_str(x.get("en")) and len(cc.tokenize(x["en"])) <= 1 and x.get("pos") != "chunk":
            out.append(Problem("SCHEMA", wh, "ipa_empty"))
        if "say" in x and not is_str(x["say"]):
            out.append(Problem("SCHEMA", wh, "say_must_be_text"))
        for key in ("tags", "alt", "syn"):
            if key in x and not _list_of_str(x[key]):
                out.append(Problem("SCHEMA", wh, key + "_must_be_a_list_of_text"))
        if x.get("role") not in ("active", "passive"):
            out.append(Problem("SCHEMA", wh, "bad_role"))
        day(x, wh, required=True)
        if "forms" in x:
            if not isinstance(x["forms"], list) or not all(isinstance(f, dict) and is_str(f.get("f")) and f.get("f").strip()
                                                           and is_str(f.get("pat")) for f in x["forms"]):
                out.append(Problem("SCHEMA", wh, "forms_must_be_list_of_f_pat"))
            elif any(not f["pat"].strip() for f in x["forms"]):
                out.append(Problem("SCHEMA", wh, "form_pat_empty"))
        if "ca" in x and not isinstance(x["ca"], bool):
            out.append(Problem("SCHEMA", wh, "ca_must_be_bool"))
        if x.get("src", "own") != "own":
            out.append(Problem("SCHEMA", wh, "word_src_must_be_own"))

    for idx, x in enumerate(wk.get("patterns", []) if isinstance(wk.get("patterns"), list) else []):
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "pattern_not_an_object"))
            continue
        wh, i = ident(x, ID_PAT, "pattern")
        _keys_unknown(x, PAT_KEYS, wh, out)
        need_str(x, "tpl", wh)
        en_ok(x, "tpl", wh)
        need_str(x, "title_ko", wh)
        g = x.get("grammar_ko")
        if not _list_of_str(g) or not (2 <= len(g) <= 4):
            out.append(Problem("SCHEMA", wh, "grammar_ko_must_be_2_to_4_lines"))
        elif any(len(s) > 90 or not s.strip() for s in g):
            out.append(Problem("SCHEMA", wh, "grammar_ko_line_empty_or_longer_than_90"))
        if "slots" in x and not (isinstance(x["slots"], list) and all(isinstance(s, dict) for s in x["slots"])):
            out.append(Problem("SCHEMA", wh, "slots_must_be_a_list_of_objects"))
        if "examples" in x and not _list_of_str(x["examples"]):
            out.append(Problem("SCHEMA", wh, "examples_must_be_a_list_of_text"))
        day(x, wh, 1, cc.WORD_DAY_MAX, required=True)

    for x in wk.get("sentences", []) if isinstance(wk.get("sentences"), list) else []:
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "sentence_not_an_object"))
            continue
        wh, i = ident(x, ID_SENT, "sentence")
        _keys_unknown(x, SENT_KEYS, wh, out)
        if need_str(x, "en", wh):
            en_ok(x, "en", wh)
        need_str(x, "ko", wh)
        if "say" in x:
            if not is_str(x["say"]):
                out.append(Problem("SCHEMA", wh, "say_must_be_text"))
            else:
                en_ok(x, "say", wh)
        if "pat" in x and not is_str(x["pat"]):
            out.append(Problem("SCHEMA", wh, "pat_must_be_text"))
        if "words" in x and not _list_of_str(x["words"]):
            out.append(Problem("SCHEMA", wh, "words_must_be_a_list_of_text"))
        if "accept" in x and not _list_of_str(x["accept"]):
            out.append(Problem("SCHEMA", wh, "accept_must_be_a_list_of_text"))
        if x.get("scope", "all") not in ("all", "listen"):
            out.append(Problem("SCHEMA", wh, "bad_scope"))
        if x.get("src", "own") not in ("own", "tatoeba"):
            out.append(Problem("SCHEMA", wh, "bad_src"))
        if "tid" in x and not (is_int(x["tid"]) and x["tid"] >= 0):
            out.append(Problem("SCHEMA", wh, "tid_must_be_a_non_negative_int"))
        day(x, wh)

    for x in wk.get("dialogues", []) if isinstance(wk.get("dialogues"), list) else []:
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "dialogue_not_an_object"))
            continue
        wh, i = ident(x, ID_DLG, "dialogue")
        _keys_unknown(x, DLG_KEYS, wh, out)
        need_str(x, "title_ko", wh)
        if "w" in x and x["w"] != w:
            out.append(Problem("SCHEMA", wh, "dialogue_w_does_not_match_file"))
        if x.get("user", "B") not in ("A", "B"):
            out.append(Problem("SCHEMA", wh, "bad_user"))
        day(x, wh)
        lines = x.get("lines")
        if not (isinstance(lines, list) and lines):
            out.append(Problem("SCHEMA", wh, "lines_must_be_a_non_empty_list"))
            continue
        user = x.get("user", "B")
        has_user = False
        for n, ln in enumerate(lines, 1):
            lw = "%s#%d" % (wh, n)
            if not isinstance(ln, dict):
                out.append(Problem("SCHEMA", lw, "line_not_an_object"))
                continue
            _keys_unknown(ln, LINE_KEYS, lw, out)
            if ln.get("s") not in ("A", "B"):
                out.append(Problem("SCHEMA", lw, "bad_speaker"))
            has_user = has_user or ln.get("s") == user
            if need_str(ln, "en", lw):
                en_ok(ln, "en", lw)
            need_str(ln, "ko", lw)
            if "say" in ln and not is_str(ln["say"]):
                out.append(Problem("SCHEMA", lw, "say_must_be_text"))
            day(ln, lw)
        if not has_user:
            out.append(Problem("SCHEMA", wh, "no_line_for_the_learner_role"))

    for x in wk.get("speak_prompts", []) if isinstance(wk.get("speak_prompts"), list) else []:
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "prompt_not_an_object"))
            continue
        wh, i = ident(x, ID_PROMPT, "prompt")
        _keys_unknown(x, PROMPT_KEYS, wh, out)
        if x.get("kind") not in PROMPT_KINDS:
            out.append(Problem("SCHEMA", wh, "bad_kind"))
        if need_str(x, "en", wh):
            en_ok(x, "en", wh)
        need_str(x, "ko", wh)
        e = x.get("expect_any")
        if not (_list_of_str(e) and e):
            out.append(Problem("SCHEMA", wh, "expect_any_must_be_a_non_empty_list"))

    for x in wk.get("notes", []) if isinstance(wk.get("notes"), list) else []:
        if not isinstance(x, dict):
            out.append(Problem("SCHEMA", W, "note_not_an_object"))
            continue
        wh, i = ident(x, ID_NOTE, "note")
        _keys_unknown(x, NOTE_KEYS, wh, out)
        if x.get("kind") not in NOTE_KINDS:
            out.append(Problem("SCHEMA", wh, "bad_kind"))
        need_str(x, "text_ko", wh)
        if x.get("kind") == "spelling":
            for key in ("ca", "us"):
                if not (is_str(x.get(key)) and cc.tokenize(x.get(key))):
                    out.append(Problem("SCHEMA", wh, key + "_must_be_text"))
        if x.get("kind") == "fact" and not is_str(x.get("fact_date")):
            out.append(Problem("SCHEMA", wh, "fact_needs_fact_date"))


# ================================================================================================ content checks
class Ctx:
    """Everything the content checks share."""

    def __init__(self, course, weeks, lex, strict):
        self.course, self.weeks, self.lex, self.strict = course, list(weeks), lex, strict
        self.lim = course.limits()
        self.pol = course.policy
        self.out = []
        self.inrange = set(weeks)
        self._seen = set()

    def add(self, code, where, detail="", warn=False, soft=False):
        key = (code, where, detail, warn)
        if key not in self._seen:
            self._seen.add(key)
            self.out.append(Problem(code, where, detail, warn, soft))

    def pol_list(self, *names):
        res = []
        for n in names:
            v = self.pol.get(n)
            if isinstance(v, list):
                res += [x for x in v if is_str(x)]
        return res


def check_order(ctx):
    lex = ctx.lex
    for it in cc.iter_items(ctx.course, ctx.weeks):
        raw = it["raw"]
        d = it["d"] if is_int(it["d"]) else None
        w = it["w"]
        base = w * 10 + (d if d else 1)
        toks = cc.item_tokens(it["en"], it["say"], ctx.acr, ctx.is_word)      # words of `en` + every word of `say`
        extra_texts = []
        if it["kind"] == "sentence" or it["kind"] == "line":
            extra_texts = [a for a in (raw.get("accept") or []) if is_str(a)]
        worst, unknown = 0, set()
        for t in toks:
            mo = lex.min_o(t)
            if mo is None:
                unknown.add(t)
            else:
                worst = max(worst, mo)
                if d is not None and mo > w * 10 + d:
                    ctx.add("ORDER", _where(w, it["id"]), "token=%s need_o=%d item_o=%d" % (t, mo, w * 10 + d))
        if d is None and worst > w * 10 + cc.DAY_MAX:
            bad = [t for t in toks if (lex.min_o(t) or 0) > w * 10 + cc.DAY_MAX]
            for t in bad[:3]:
                ctx.add("ORDER", _where(w, it["id"]), "token=%s need_o=%d item_o=%d" % (t, lex.min_o(t), w * 10 + cc.DAY_MAX))
        for t in sorted(unknown):
            ctx.add("UNKNOWN_TOKEN", _where(w, it["id"]), "token=" + t)
        for a in extra_texts:
            for t in cc.tokenize(ne.plain_text(a)):
                mo = lex.min_o(t)
                if mo is None:
                    ctx.add("UNKNOWN_TOKEN", _where(w, it["id"]), "accept_token=" + t)
                elif mo > (w * 10 + d if d else w * 10 + cc.DAY_MAX):
                    ctx.add("ORDER", _where(w, it["id"]), "accept_token=%s need_o=%d" % (t, mo))
        # R5: passive words only in listen sentences
        if it["kind"] == "sentence" and raw.get("scope", "all") == "all":
            for t in toks:
                c = lex.candidates(t)
                if c and all(lex.words.get(wid, {}).get("role") == "passive" for _, wid, _k in c):
                    ctx.add("ORDER", _where(w, it["id"]), "passive_token_in_scope_all=" + t)
        # declared words: must exist, o <= item o, and must really occur in the text
        declared = raw.get("words") if isinstance(raw.get("words"), list) else []
        if declared:
            item_o = w * 10 + (d if d else cc.DAY_MAX)
            used = lex.used_words(toks, 10 ** 6)
            for wid in declared:
                info = lex.words.get(wid)
                if info is None:
                    ctx.add("SCHEMA", _where(w, it["id"]), "words_unknown_id=" + str(wid))
                elif info["o"] > item_o:
                    ctx.add("ORDER", _where(w, it["id"]), "declared_word=%s need_o=%d" % (wid, info["o"]))
                elif wid not in used:
                    ctx.add("SCHEMA", _where(w, it["id"]), "words_id_not_in_text=" + str(wid))
    # pattern templates
    for w in ctx.weeks:
        wk = ctx.course.weeks.get(w, {})
        for i, p in enumerate(wk.get("patterns", []) or []):
            po = w * 10 + cc.week_pattern_day(i, p)
            for t in cc.tokenize(str(p.get("tpl", "")).replace("___", " ")):
                mo = ctx.lex.min_o(t)
                if mo is None:
                    ctx.add("UNKNOWN_TOKEN", _where(w, p.get("id")), "tpl_token=" + t)
                elif mo > po:
                    ctx.add("ORDER", _where(w, p.get("id")), "tpl_token=%s need_o=%d item_o=%d" % (t, mo, po))
    # speak prompts expect_any
    for w in ctx.weeks:
        for x in ctx.course.weeks.get(w, {}).get("speak_prompts", []) or []:
            for e in x.get("expect_any", []) or []:
                for t in cc.tokenize(ne.plain_text(e)):
                    mo = ctx.lex.min_o(t)
                    if mo is None:
                        ctx.add("UNKNOWN_TOKEN", _where(w, x.get("id")), "expect_token=" + t)
                    elif mo > w * 10 + cc.SPEAK_PROMPT_DAY:
                        ctx.add("ORDER", _where(w, x.get("id")), "expect_token=%s need_o=%d" % (t, mo))
    # forms must point at an existing pattern
    for w in ctx.weeks:
        for x in ctx.course.weeks.get(w, {}).get("words", []) or []:
            for f in x.get("forms", []) or []:
                if f.get("pat") not in ctx.pat_o:
                    ctx.add("SCHEMA", _where(w, x.get("id")), "form_pattern_unknown=" + str(f.get("pat")))


SAY_BAD_CHARS = re.compile(r"[0-9$%&@#+=/*<>~^|\\_]")


def check_num_say(ctx):
    extra_ok = set(ctx.pol_list("acronym_ok"))
    for it in cc.iter_items(ctx.course, ctx.weeks):
        texts = [("en", it["en"])]
        say = it["say"] if is_str(it["say"]) else ""
        for a in (it["raw"].get("accept") or []) if it["kind"] in ("sentence", "line") else []:
            if is_str(a) and ne.needs_say(a, ctx.acr, ctx.is_word) and not it["raw"].get("say"):
                ctx.add("NUM_SAY", _where(it["w"], it["id"]), "accept_needs_say")
        en = it["en"] if is_str(it["en"]) else ""
        probe = en
        for a in extra_ok:
            probe = re.sub(r"\b%s\b" % re.escape(a), "x", probe)
        if ne.needs_say(probe, ctx.acr, ctx.is_word):
            if not say.strip():
                ctx.add("NUM_SAY", _where(it["w"], it["id"]), "say_missing")
            elif re.search(r"[0-9$%&@#+=/*<>~^|\\_]", say):
                ctx.add("NUM_SAY", _where(it["w"], it["id"]), "say_has_digits_or_symbols")
            elif not ne.say_matches(probe, say, ctx.acr, ctx.is_word):
                ctx.add("NUM_SAY", _where(it["w"], it["id"]), "say_differs_from_numbers_en")
        elif say.strip() and re.search(r"[0-9$%&@#+=/*<>~^|\\_]", say):
            ctx.add("NUM_SAY", _where(it["w"], it["id"]), "say_has_digits_or_symbols")
    for w in ctx.weeks:
        for x in ctx.course.weeks.get(w, {}).get("words", []) or []:
            en, say = x.get("en", ""), x.get("say", "") or ""
            where = _where(w, x.get("id"))
            if SAY_BAD_CHARS.search(say):
                ctx.add("NUM_SAY", where, "say_has_digits_or_symbols")
                continue
            sw = ne.norm_say(say)
            if is_str(en) and re.fullmatch(r"[A-Z]{2,6}", en.strip()) and en.strip() not in ne.ACRONYM_EXEMPT:
                # a registered acronym: its say is the letters, or ONE word that starts with the same letter (SIN -> sin)
                if not sw:
                    ctx.add("NUM_SAY", where, "acronym_needs_say")
                elif not (ne.say_matches(en, say) or (len(sw) == 1 and sw[0][:1] == en.strip()[:1].lower())):
                    ctx.add("NUM_SAY", where, "acronym_say_differs")
            elif ne.needs_say(en):
                if not say.strip():
                    ctx.add("NUM_SAY", where, "say_missing")
                elif not ne.say_matches(en, say):
                    ctx.add("NUM_SAY", where, "say_differs_from_numbers_en")
            elif sw:
                # a plain word may carry a say only to spell a letter ("A" -> ay) or to repeat itself; no other word can ride along
                letter = len(en.strip()) == 1 and en.strip().isalpha() and sw in ne.LETTER_NAMES[en.strip().lower()]
                if not letter and sw != cc.tokenize(en):
                    ctx.add("NUM_SAY", where, "say_differs_from_en")


def check_ko(ctx):
    def one(w, ident, ko, field, need_hangul=True):
        if not is_str(ko):
            return
        if need_hangul and not cc.HANGUL.search(ko):
            ctx.add("KO_HANGUL", _where(w, ident), field)
        if cc.HAN.search(ko) or cc.FOREIGN.search(ko):
            ctx.add("KO_HANJA", _where(w, ident), field)

    for w in ctx.weeks:
        wk = ctx.course.weeks.get(w, {})
        one(w, None, wk.get("title_ko", "x가"), "title_ko", need_hangul=False)
        if isinstance(wk.get("scene"), dict):
            one(w, None, wk["scene"].get("title_ko", "x가"), "scene_title_ko", need_hangul=False)
        for x in wk.get("words", []) or []:
            one(w, x.get("id"), x.get("ko"), "ko")
            if "ko2" in x:
                one(w, x.get("id"), x.get("ko2"), "ko2")
        for x in wk.get("patterns", []) or []:
            one(w, x.get("id"), x.get("title_ko"), "title_ko")
            for n, g in enumerate(x.get("grammar_ko", []) or [], 1):
                one(w, x.get("id"), g, "grammar_ko#%d" % n)
        for x in wk.get("sentences", []) or []:
            one(w, x.get("id"), x.get("ko"), "ko")
        for dlg in wk.get("dialogues", []) or []:
            one(w, dlg.get("id"), dlg.get("title_ko"), "title_ko")
            for n, ln in enumerate(dlg.get("lines", []) or [], 1):
                one(w, "%s#%d" % (dlg.get("id"), n), ln.get("ko"), "ko")
                if "hint_ko" in ln:
                    one(w, "%s#%d" % (dlg.get("id"), n), ln.get("hint_ko"), "hint_ko")
        for x in wk.get("speak_prompts", []) or []:
            one(w, x.get("id"), x.get("ko"), "ko")
        for x in wk.get("notes", []) or []:
            one(w, x.get("id"), x.get("text_ko"), "text_ko")
        for c in wk.get("can_do", []) or []:
            if is_str(c):
                one(w, None, c, "can_do", need_hangul=False)
    # Korean style of sentences and lines (warning only; --strict makes it a violation)
    for it in cc.iter_items(ctx.course, ctx.weeks):
        if it["kind"] in ("sentence", "line") and is_str(it["ko"]) and cc.HANGUL.search(it["ko"]):
            plain = re.sub(r"[.?!~\u2026\s]+$", "", it["ko"].strip())
            if " " in plain and KO_BANMAL.search(it["ko"].strip()):       # a single word (a noun like 의자) is never "plain style"
                ctx.add("SCHEMA", _where(it["w"], it["id"]), "ko_style_not_haeyo", warn=True)


def check_dups(ctx):
    allw = ctx.usable
    by_en, by_ko = {}, {}
    for w in allw:
        for x in ctx.course.weeks[w].get("sentences", []) or []:
            if not (isinstance(x, dict) and is_str(x.get("en")) and is_str(x.get("ko"))):
                continue
            by_en.setdefault(cc.norm_en(x["en"]), []).append((w, x.get("id")))
            by_ko.setdefault(cc.norm_ko(x["ko"]), {}).setdefault(cc.norm_en(x["en"]), []).append((w, x.get("id")))
    for key, lst in by_en.items():
        if len(lst) > 1 and any(w in ctx.inrange for w, _ in lst):
            ctx.add("DUP_EN", _where(lst[0][0], lst[0][1]), "same_english_as=" + ",".join(str(i) for _, i in lst[1:]))
    for key, ens in by_ko.items():
        if len(ens) > 1:
            flat = [t for l in ens.values() for t in l]
            if any(w in ctx.inrange for w, _ in flat):
                ids = sorted(str(i) for _, i in flat)
                ctx.add("DUP_KO", _where(flat[0][0], ids[0]), "same_korean_ids=" + ",".join(ids))


def check_same_ko(ctx):
    for w in ctx.weeks:
        words = [x for x in ctx.course.weeks.get(w, {}).get("words", []) or [] if isinstance(x, dict)]
        idx = {}
        for x in words:
            for k in cc.ko_keys(x.get("ko", "")):
                idx.setdefault(k, []).append(x)
        done = set()
        for k, lst in idx.items():
            for i in range(len(lst)):
                for j in range(i + 1, len(lst)):
                    a, b = lst[i], lst[j]
                    pair = tuple(sorted((a.get("id"), b.get("id"))))
                    if pair in done:
                        continue
                    done.add(pair)
                    syn_a, syn_b = set(a.get("syn") or []), set(b.get("syn") or [])
                    if b.get("id") in syn_a or a.get("id") in syn_b:
                        continue
                    ctx.add("SAME_KO_OPTIONS", _where(w, pair[0]), "overlaps_with=" + pair[1])


def _blocked_rules(ctx):
    """-> list of (word, is_prefix, allow_weeks:set, from_w|None). A rule blocks a token in week w unless w is in
    allow_weeks or (from_w is set and w >= from_w).  policy.json layouts: `blocked` = list of words / {word, weeks}
    or {category: [words]}, `blocked_prefix` = [prefixes], `context_allowed` = [{word, from_w}], `allow` = {word: [weeks]}."""
    rules = []
    pol = ctx.pol

    def add(word, prefix, weeks=(), from_w=None):
        if is_str(word) and word.strip():
            rules.append((word.lower().rstrip("*"), prefix or word.endswith("*"), set(weeks), from_w))

    for n in ("blocked", "blocked_words", "blocklist"):
        v = pol.get(n)
        if isinstance(v, dict):
            v = [x for lst in v.values() if isinstance(lst, list) for x in lst]
        if isinstance(v, list):
            for e in v:
                if is_str(e):
                    add(e, False)
                elif isinstance(e, dict) and is_str(e.get("word")):
                    add(e["word"], False, [x for x in e.get("weeks", []) if is_int(x)])
    for e in pol.get("blocked_prefix", []) if isinstance(pol.get("blocked_prefix"), list) else []:
        add(e, True)
    for e in pol.get("context_allowed", []) if isinstance(pol.get("context_allowed"), list) else []:
        if isinstance(e, dict) and is_str(e.get("word")):
            add(e["word"], False, (), e.get("from_w") if is_int(e.get("from_w")) else None)
    allow = {}
    for n in ("allow", "exceptions", "allow_in_weeks"):
        v = pol.get(n)
        if isinstance(v, dict):
            for k, ws in v.items():
                if isinstance(ws, list):
                    allow.setdefault(k.lower().rstrip("*"), set()).update(x for x in ws if is_int(x))
    return [(w, pre, ws | allow.get(w, set()), f) for w, pre, ws, f in rules], allow


def _is_blocked(rules_allow, tok, week):
    rules, allow = rules_allow
    if week in allow.get(tok, ()):
        return False
    for word, prefix, weeks, from_w in rules:
        if (tok.startswith(word) if prefix else tok == word):
            if week in weeks or (from_w is not None and week >= from_w):
                continue
            return True
    return False


def english_texts(ctx):
    """(week, id, kind, text) of every English text a manuscript carries: sentence / line / prompt en, say, accept,
    expect_any, pattern templates, word headwords, say, forms and alt spellings."""
    for it in cc.iter_items(ctx.course, ctx.weeks):
        yield it["w"], it["id"], it["kind"], it["en"]
        yield it["w"], it["id"], "say", it["say"]
        for a in (it["raw"].get("accept") or []) if isinstance(it["raw"].get("accept"), list) else []:
            yield it["w"], it["id"], "accept", a
        for a in (it["raw"].get("expect_any") or []) if isinstance(it["raw"].get("expect_any"), list) else []:
            yield it["w"], it["id"], "expect", a
    for w in ctx.weeks:
        wk = ctx.course.weeks.get(w, {})
        for p in wk.get("patterns", []) or []:
            yield w, p.get("id"), "tpl", str(p.get("tpl", "")).replace("___", " ")
        for x in wk.get("words", []) or []:
            yield w, x.get("id"), "word", x.get("en")
            yield w, x.get("id"), "say", x.get("say")
            for f in x.get("forms", []) or []:
                yield w, x.get("id"), "form", f.get("f")
            for a in x.get("alt", []) or []:
                yield w, x.get("id"), "alt", a


def check_blocked(ctx):
    rules = _blocked_rules(ctx)
    if not rules[0]:
        return
    for w in ctx.weeks:
        for ident, text in cc.week_strings(ctx.course.weeks.get(w, {})):
            for tok in cc.tokenize(text):
                if _is_blocked(rules, tok, w):
                    ctx.add("BLOCKED", _where(w, ident), "token=" + tok)


PHONE_RX = re.compile(r"(?<!\d)(?:\+?1[-. ]?)?(?:\(?(\d{3})\)?[-. ])?(\d{3})[-. ](\d{4})(?!\d)")
EMAIL_RX = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
URL_RX = re.compile(r"(?:https?://|www\.)[^\s]+", re.I)
ADDR_RX = re.compile(r"\b\d{1,5}\s+((?:[A-Z][\w']*\s+){1,3})(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Way|Court|Ct|Crescent|Cres)\b")
# lower case spelling ("1234 granville street"): only the long, unambiguous street words (not "5 minute drive")
ADDR_LOWER_RX = re.compile(r"\b\d{1,5}\s+((?:[A-Za-z][\w']*\s+){1,3})(?:street|avenue|road|boulevard|crescent)\b", re.I)
DOMAIN_RX = re.compile(r"(?<![\w@.-])(?:[a-z\d][a-z\d-]*\.)+(?:com|ca|net|org)\b(?:/\S*)?", re.I)
DASHES = re.compile("[\u2010-\u2015\u2212\ufe58\ufe63\uff0d]")
POSTAL_RX = re.compile(r"\b[A-Za-z]\d[A-Za-z][ -]?\d[A-Za-z]\d\b")
LONGDIGITS_RX = re.compile(r"(?<![\d,.])\d{7,}(?![\d])")


def check_personal(ctx):
    names = cc.policy_names(ctx.pol)          # lower-case name -> first week it may be used
    postal_ok = {re.sub(r"[ -]", "", s).upper() for s in ctx.pol_list("allowed_postal_codes", "fake_postal_codes")}
    pers = ctx.pol.get("personal") if isinstance(ctx.pol.get("personal"), dict) else {}
    mail_ok = [d.lower() for d in pers.get("email_domains", []) if is_str(d)] if isinstance(pers.get("email_domains"), list) else []
    kinds_ok = {"place", "calendar", "country", "language", "org", "brand", "holiday"}

    def scan(w, ident, text):
        if not is_str(text):
            return
        text = DASHES.sub("-", cc.nfkc(text))          # NFKC, then every dash looks like a hyphen
        for m in PHONE_RX.finditer(text):
            digits = [g for g in m.groups() if g]
            exch, last = digits[-2], digits[-1]
            if not (exch == "555" and last.startswith("01")):
                ctx.add("PERSONAL", _where(w, ident), "phone_number")
        if LONGDIGITS_RX.search(text):
            ctx.add("PERSONAL", _where(w, ident), "long_digit_run")
        for m in EMAIL_RX.finditer(text):
            dom = m.group(0).split("@", 1)[1].lower()
            if not (re.search(r"(?:^|\.)example\.(?:com|org|net|ca)$", dom) or any(dom == d or dom.endswith("." + d) for d in mail_ok)):
                ctx.add("PERSONAL", _where(w, ident), "email")
        for m in URL_RX.finditer(text):
            if "example." not in m.group(0).lower():
                ctx.add("PERSONAL", _where(w, ident), "url")
        for rx in (ADDR_RX, ADDR_LOWER_RX):
            for m in rx.finditer(text):
                full = re.sub(r"^\d+\s+", "", m.group(0)).lower()
                name = m.group(1).strip().lower()
                if full not in names and name not in names:
                    ctx.add("PERSONAL", _where(w, ident), "street_address")
        for m in DOMAIN_RX.finditer(text):
            dom = m.group(0).split("/", 1)[0].lower()
            if not (re.search(r"(?:^|\.)example\.(?:com|org|net|ca)$", dom) or any(dom == d or dom.endswith("." + d) for d in mail_ok)):
                ctx.add("PERSONAL", _where(w, ident), "web_address")
        for m in POSTAL_RX.finditer(text):
            if re.sub(r"[ -]", "", m.group(0)).upper() not in postal_ok:
                ctx.add("PERSONAL", _where(w, ident), "postal_code")

    for w in ctx.weeks:                                   # every string of the week file: notes, titles, grammar lines ...
        wk = ctx.course.weeks.get(w, {})
        for ident, text in cc.week_strings(wk):
            scan(w, ident, text)
        for x in wk.get("words", []) or []:
            if x.get("pos") == "propn":
                tags = set(x.get("tags") or [])
                key = cc.nfkc(x.get("en", "")).lower().strip()
                if key in names:
                    if names[key] > w:
                        ctx.add("PERSONAL", _where(w, x.get("id")), "name_before_allowed_week=%d" % names[key])
                elif not (tags & kinds_ok):
                    ctx.add("PERSONAL", _where(w, x.get("id")), "name_not_in_policy")


def _canon_pairs(ctx):
    pairs = list(AUTO_PAIRS)
    for p in ctx.pol.get("canon_pairs", []) if isinstance(ctx.pol.get("canon_pairs"), list) else []:
        if isinstance(p, dict) and is_str(p.get("ca")) and is_str(p.get("us")):
            pairs.append((p["ca"].lower(), p["us"].lower()))
    for w in ctx.usable:
        for n in ctx.course.weeks[w].get("notes", []) or []:
            if isinstance(n, dict) and n.get("kind") == "spelling" and is_str(n.get("ca")) and is_str(n.get("us")):
                pairs.append((n["ca"].lower(), n["us"].lower()))
    return pairs


SOFT_PAIRS = {("metre", "meter"), ("grey", "gray")}      # Canada uses both spellings: a warning, never a violation
US_SUFFIXES = ("", "s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "ful", "less", "hood", "'s", "s'")


def check_canon(ctx):
    pairs = _canon_pairs(ctx)
    ca_to_us = {ca: us for ca, us in pairs}

    def us_hit(tok):
        """US spelling (or an inflection of it: colors, favorites, centered) -> the Canadian stem, else None."""
        for ca, us in pairs:
            if tok.startswith(us) and tok[len(us):] in US_SUFFIXES:
                return ca, us
        return None

    seen = set()
    for w, ident, kind, text in english_texts(ctx):
        if kind == "alt":           # `alt` is where the US spelling belongs
            continue
        for t in cc.tokenize(text if is_str(text) else ""):
            hit = us_hit(t)
            if hit and (w, ident, t) not in seen:
                seen.add((w, ident, t))
                ca, us = hit
                soft = (ca, us) in SOFT_PAIRS
                what = "us_spelling_as_headword" if kind == "word" else "us_spelling"
                ctx.add("CANON", _where(w, ident), "%s=%s want=%s" % (what, t, ca), warn=soft, soft=soft)
    for w in ctx.weeks:
        for x in ctx.course.weeks.get(w, {}).get("words", []) or []:
            alts = {a.lower() for a in x.get("alt") or [] if is_str(a)}
            for t in cc.tokenize(x.get("en", "")):
                if t in ca_to_us and ca_to_us[t] not in alts:
                    soft = (t, ca_to_us[t]) in SOFT_PAIRS
                    ctx.add("CANON", _where(w, x.get("id")), "alt_missing_us_spelling=" + ca_to_us[t], warn=soft, soft=soft)


def check_forms(ctx):
    """FORM_SUSPECT: `forms` / `alt` may not smuggle other words into the lexicon. A form must be a regular derivation of
    its headword or a listed irregular form (forms_en.py), and it may not be the headword / alt of another word; an alt
    must be a spelling variant (case, hyphen, space, Canadian/US pair) of its headword and not the headword, form or alt
    of another word."""
    pairs = _canon_pairs(ctx)
    heads, forms_of, alts_of = {}, {}, {}
    for wid, info in ctx.lex.words.items():
        if len(info["tokens"]) == 1:
            heads.setdefault(info["tokens"][0], set()).add(wid)
    for w in ctx.usable:
        for x in ctx.course.weeks[w].get("words", []) or []:
            wid = x.get("id")
            for f in x.get("forms", []) or []:
                for t in cc.tokenize(f.get("f", "")):
                    forms_of.setdefault(t, set()).add(wid)
            for a in x.get("alt", []) or []:
                for t in cc.tokenize(a if is_str(a) else ""):
                    alts_of.setdefault(t, set()).add(wid)

    def alt_ok(lemma, alt):
        jl, ja = "".join(cc.tokenize(lemma)), "".join(cc.tokenize(alt))
        if jl == ja:
            return True
        return any(jl.replace(ca, us) == ja or jl.replace(us, ca) == ja for ca, us in pairs)

    for w in ctx.weeks:
        for x in ctx.course.weeks.get(w, {}).get("words", []) or []:
            wid, lemma = x.get("id"), x.get("en", "")
            for f in x.get("forms", []) or []:
                ft = f.get("f", "")
                where = _where(w, wid)
                if not forms_en.is_derived(lemma, ft, x.get("pos")):
                    ctx.add("FORM_SUSPECT", where, "form_not_derived_from_headword=" + "_".join(cc.tokenize(ft)))
                for t in cc.tokenize(ft):
                    if heads.get(t, set()) - {wid}:
                        ctx.add("FORM_SUSPECT", where, "form_is_another_headword=" + t)
                    elif alts_of.get(t, set()) - {wid}:
                        ctx.add("FORM_SUSPECT", where, "form_is_another_words_alt=" + t)
            for a in x.get("alt", []) or []:
                where = _where(w, wid)
                if not alt_ok(lemma, a):
                    ctx.add("FORM_SUSPECT", where, "alt_not_a_spelling_variant=" + "_".join(cc.tokenize(a)))
                for t in cc.tokenize(a):
                    if (heads.get(t, set()) | forms_of.get(t, set()) | alts_of.get(t, set())) - {wid}:
                        ctx.add("FORM_SUSPECT", where, "alt_is_another_word=" + t)


def _open_tatoeba(ctx, path_arg):
    cands = []
    if path_arg:
        cands.append(Path(path_arg))
    pd = ctx.pol.get("tatoeba_db")
    if is_str(pd):
        cands.append(ctx.course.in_dir / pd)
    cands += [cc.REPO_ROOT / "backend" / "data" / "tatoeba.sqlite", cc.REPO_ROOT.parent / "app" / "backend" / "data" / "tatoeba.sqlite",
              cc.REPO_ROOT.parent.parent / "app" / "backend" / "data" / "tatoeba.sqlite"]
    for p in cands:
        if p.is_file():
            return p
        if path_arg and p == Path(path_arg):
            return None   # an explicit path that does not exist is never replaced by a default
    return None


def load_tatoeba_texts(path, ids):
    """-> {id: normalized english text}; supports the app's tatoeba.sqlite (read only) and a small {id: text} .json."""
    ids = sorted(set(ids))
    if not ids:
        return {}
    if str(path).lower().endswith(".json"):
        data, err = cc.read_json(path)
        if err or not isinstance(data, dict):
            return None
        return {int(k): cc.norm_en(v) for k, v in data.items() if str(k).isdigit() and is_str(v)}
    try:
        con = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
        try:
            res = {}
            for i in range(0, len(ids), 500):
                chunk = ids[i:i + 500]
                q = "SELECT id, text FROM sent WHERE lang='en' AND id IN (%s)" % ",".join("?" * len(chunk))
                for sid, text in con.execute(q, chunk):
                    res[int(sid)] = cc.norm_en(text)
            return res
        finally:
            con.close()
    except sqlite3.Error:
        return None


def check_tatoeba(ctx, db_arg):
    total = tat = 0
    tids = []
    for w in ctx.weeks:
        sents = [s for s in ctx.course.weeks.get(w, {}).get("sentences", []) or [] if isinstance(s, dict)]
        wt = [s for s in sents if s.get("src") == "tatoeba"]
        total += len(sents)
        tat += len(wt)
        if sents and len(wt) / len(sents) > ctx.lim["tatoeba_max_ratio"] + 1e-9:
            ctx.add("TATOEBA", _where(w), "ratio_over_limit=%d/%d" % (len(wt), len(sents)))
        for s in wt:
            if not (is_int(s.get("tid")) and s["tid"] > 0):
                ctx.add("TATOEBA", _where(w, s.get("id")), "tid_missing")
            else:
                tids.append((w, s))
        for s in sents:
            if s.get("src", "own") == "own" and s.get("tid", 0) not in (0, None):
                ctx.add("TATOEBA", _where(w, s.get("id")), "own_sentence_has_tid")
    if total and tat / total > ctx.lim["tatoeba_max_ratio"] + 1e-9:
        ctx.add("TATOEBA", "all", "ratio_over_limit=%d/%d" % (tat, total))
    if not tids:
        return
    path = _open_tatoeba(ctx, db_arg)
    texts = load_tatoeba_texts(path, [s["tid"] for _, s in tids]) if path else None
    if texts is None:
        ctx.add("TATOEBA", "db", "database_not_available_not_verified", warn=True)
        ctx.notes.append("TATOEBA_SKIPPED sentences=%d (no readable Tatoeba database: not verified)" % len(tids))
        return
    for w, s in tids:
        t = texts.get(s["tid"])
        if t is None:
            ctx.add("TATOEBA", _where(w, s.get("id")), "tid_not_in_database")
        elif t != cc.norm_en(s.get("en", "")):
            ctx.add("TATOEBA", _where(w, s.get("id")), "text_differs_from_database")


def ranges_for(w, lim):
    """-> (active_range, passive_range, pattern_range) of week w."""
    cls = cc.week_class(w)
    a = lim[{"intro": "intro_active_range", "synth": "synth_active_range", "final": "final_active_range"}.get(cls, "active_range")]
    p = lim["intro_passive_range"] if cls == "intro" else [0, 16] if cls == "final" else lim["passive_range"]
    q = lim[{"intro": "intro_pattern_range", "synth": "synth_pattern_range", "final": "final_pattern_range"}.get(cls, "pattern_range")]
    return a, p, q


def check_counts(ctx):
    lim = ctx.lim
    for w in ctx.weeks:
        wk = ctx.course.weeks.get(w)
        if not wk:
            continue
        cls = cc.week_class(w)
        words = [x for x in wk.get("words", []) or [] if isinstance(x, dict)]
        act = [x for x in words if x.get("role") == "active"]
        pas = [x for x in words if x.get("role") == "passive"]
        pats = [x for x in wk.get("patterns", []) or [] if isinstance(x, dict)]
        sents = [x for x in wk.get("sentences", []) or [] if isinstance(x, dict)]
        arange, prange, patrange = ranges_for(w, lim)
        if not arange[0] <= len(act) <= arange[1]:
            ctx.add("COUNT", _where(w), "active_words=%d want=%d-%d" % (len(act), arange[0], arange[1]))
        if not prange[0] <= len(pas) <= prange[1]:
            ctx.add("COUNT", _where(w), "passive_words=%d want=%d-%d" % (len(pas), prange[0], prange[1]))
        if not patrange[0] <= len(pats) <= patrange[1]:
            ctx.add("COUNT", _where(w), "patterns=%d want=%d-%d" % (len(pats), patrange[0], patrange[1]))
        if len(sents) < lim["min_sentences"]:
            ctx.add("COUNT", _where(w), "sentences=%d want>=%d" % (len(sents), lim["min_sentences"]))
        for x in act + pas:
            if is_int(x.get("d")) and x["d"] > cc.WORD_DAY_MAX:
                ctx.add("COUNT", _where(w, x.get("id")), "new_word_day_out_of_range")
        # sentences per pattern / per active word
        per_pat = {}
        for s in sents:
            if s.get("pat"):
                per_pat[s["pat"]] = per_pat.get(s["pat"], 0) + 1
        for p in pats:
            n = per_pat.get(p.get("id"), 0)
            if n < lim["pattern_min_sentences"]:
                ctx.add("COUNT", _where(w, p.get("id")), "pattern_sentences=%d want>=%d" % (n, lim["pattern_min_sentences"]))
        use = {}
        for s in sents:
            if is_str(s.get("en")):
                toks = cc.item_tokens(s["en"], s.get("say", ""), ctx.acr, ctx.is_word)
                for wid in ctx.lex.used_words(toks, 10 ** 6):
                    use[wid] = use.get(wid, 0) + 1
        for x in act:
            n = use.get(x.get("id"), 0)
            if n < lim["word_min_sentences"]:
                ctx.add("COUNT", _where(w, x.get("id")), "word_sentences=%d want>=%d" % (n, lim["word_min_sentences"]))
        mw = (ctx.pol.get("stage0") or {}).get("max_words_per_sentence") if isinstance(ctx.pol.get("stage0"), dict) else None
        if isinstance(mw, dict) and is_int(mw.get(str(w))):
            for s in sents:
                n = len(cc.tokenize(s.get("en", ""))) if is_str(s.get("en")) else 0
                if n > mw[str(w)]:
                    ctx.add("COUNT", _where(w, s.get("id")), "sentence_words=%d want<=%d" % (n, mw[str(w)]))
        # dialogue
        dl = [x for x in wk.get("dialogues", []) or [] if isinstance(x, dict)]
        if len(dl) != 1:
            ctx.add("COUNT", _where(w), "dialogues=%d want=1" % len(dl))
        for x in dl:
            lines = len(x.get("lines", []) or [])
            rng = lim["dialogue_lines_early"] if w <= 7 else lim["dialogue_lines_late"]
            if not rng[0] <= lines <= rng[1]:
                ctx.add("COUNT", _where(w, x.get("id")), "dialogue_lines=%d want=%d-%d" % (lines, rng[0], rng[1]))
        sp = len(wk.get("speak_prompts", []) or [])
        want = lim["speak_prompts_per_month"] if w % 4 == 0 else 0
        if sp != want:
            ctx.add("COUNT", _where(w), "speak_prompts=%d want=%d" % (sp, want))


def _lt_dir_candidates(lt_dir):
    out = []
    if lt_dir:
        out.append(Path(lt_dir))
    if os.environ.get("COURSE_LT_DIR"):
        out.append(Path(os.environ["COURSE_LT_DIR"]))
    for base in (cc.REPO_ROOT, cc.REPO_ROOT.parent / "app", cc.REPO_ROOT.parent.parent / "app"):
        out.append(base / "backend" / "tools" / "languagetool")
    return out


def check_grammar(ctx, grammar_module, grammar_path=None, lt_dir=None):
    """LanguageTool through backend/grammar.py. The module starts the Java server on a free port of its own and is
    stopped here by PID (grammar.stop). Any problem (no module, no jar, no Java, server does not start) = GRAMMAR_SKIPPED."""
    mod = grammar_module
    if mod is None:
        p = Path(grammar_path) if grammar_path else cc.REPO_ROOT / "backend" / "grammar.py"
        if not p.is_file():
            ctx.notes.append("GRAMMAR_SKIPPED reason=grammar_module_missing (not verified)")
            return
        try:
            spec = importlib.util.spec_from_file_location("course_backend_grammar", str(p))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:  # noqa: BLE001 - any import problem means "cannot check"
            ctx.notes.append("GRAMMAR_SKIPPED reason=import_failed_%s (not verified)" % e.__class__.__name__)
            return
        # the worktree has no backend\tools: look for LanguageTool in --lt-dir, COURSE_LT_DIR, this repo, the main checkout
        for d in _lt_dir_candidates(lt_dir):
            if not d.is_dir():
                continue
            mod.LT_DIR, mod.TOOLS = str(d), str(d.parent)
            mod.LOG_DIR = os.path.join(tempfile.gettempdir(), "course_lt_logs")
            if mod.find_jar():
                break
    if isinstance(getattr(mod, "LANG_CODE", None), dict):
        mod.LANG_CODE = dict(mod.LANG_CODE, en="en-CA")      # the course spells the Canadian way (colour, centre ...)
    try:
        ok = bool(mod.installed()) and bool(mod.find_java())
    except Exception:  # noqa: BLE001
        ok = False
    if not ok:
        ctx.notes.append("GRAMMAR_SKIPPED reason=LanguageTool_or_Java_not_found (not verified)")
        return
    n, info = 0, ""
    try:
        if hasattr(mod, "start") and not mod.start():
            ctx.notes.append("GRAMMAR_SKIPPED reason=server_did_not_start (not verified)")
            return
        st = getattr(mod, "_state", None)
        if isinstance(st, dict) and st.get("proc") is not None:
            info = " pid=%s port=%s" % (st["proc"].pid, st.get("port"))
        for it in cc.iter_items(ctx.course, ctx.weeks):
            if it["kind"] != "sentence" or not is_str(it["en"]) or it["raw"].get("src") == "tatoeba":
                continue
            n += 1
            res = mod.correct("en", it["en"], quiet=True)
            if res:
                ctx.add("GRAMMAR", _where(it["w"], it["id"]), "languagetool_suggests_a_change")
    finally:
        try:
            mod.stop()
        except Exception:  # noqa: BLE001
            pass
    ctx.notes.append("GRAMMAR_CHECKED sentences=%d%s (server stopped)" % (n, info))


# ================================================================================================ skeleton
def _id_num(s):
    m = re.fullmatch(r"[a-z]+(\d+)", s) if is_str(s) else None
    return int(m.group(1)) if m else None


def _range_of(v):
    """["w0001","w0500"] / [1, 500] / "w0001-w0500" -> (lo, hi) or None."""
    lo = hi = None
    if isinstance(v, list) and len(v) == 2:
        lo, hi = (_id_num(v[0]) if is_str(v[0]) else v[0]), (_id_num(v[1]) if is_str(v[1]) else v[1])
    elif is_str(v) and "-" in v:
        a, b = v.split("-", 1)
        lo, hi = _id_num(a.strip()), _id_num(b.strip())
    return (lo, hi) if is_int(lo) and is_int(hi) and lo <= hi else None


def _weeks_of(w):
    if isinstance(w, list) and len(w) == 2 and all(is_int(i) for i in w):
        return (w[0], w[1])
    if is_str(w):
        try:
            return cc.parse_weeks_arg(w)
        except ValueError:
            return None
    return None


def parse_id_ranges(sk, out):
    """-> list of (author, weeks (a,b)|None, {kind: (lo, hi)}). Problems go to out.
    Layouts: (a) K0: {"words": {"assigned": [lo,hi], "A1": [lo,hi], ..}, "sentences": {"A1": [..]}, "dialogues": {..},
    "authors": {"A1": [1,4], ..}};  (b) {"A1": {"weeks": [1,4], "words": [lo,hi], "sentences": [..], "dialogues": [..]}}."""
    res = []
    ir = sk.get("id_ranges")
    if not isinstance(ir, dict):
        out.append(Problem("SCHEMA", "skeleton", "id_ranges_missing"))
        return res
    if isinstance(ir.get("authors"), dict):
        for name, w in ir["authors"].items():
            weeks = _weeks_of(w)
            if weeks is None:
                out.append(Problem("SCHEMA", "skeleton.id_ranges", "bad_weeks=" + str(name)))
            kinds = {}
            for kind in ("words", "sentences", "dialogues"):
                src = ir.get(kind)
                if isinstance(src, dict) and name in src:
                    r = _range_of(src[name])
                    if r is None:
                        out.append(Problem("SCHEMA", "skeleton.id_ranges", "bad_%s_range=%s" % (kind, name)))
                    else:
                        kinds[kind] = r
            res.append((str(name), weeks, kinds))
        asg = ir.get("words", {}).get("assigned") if isinstance(ir.get("words"), dict) else None
        if asg is not None:
            r = _range_of(asg)
            if r is None:
                out.append(Problem("SCHEMA", "skeleton.id_ranges", "bad_words_range=assigned"))
            else:
                res.append(("assigned", None, {"words": r}))
        return res
    for name, e in ir.items():
        if not isinstance(e, dict):
            out.append(Problem("SCHEMA", "skeleton.id_ranges", "entry_not_an_object=" + str(name)))
            continue
        weeks = _weeks_of(e.get("weeks"))
        if e.get("weeks") is not None and weeks is None:
            out.append(Problem("SCHEMA", "skeleton.id_ranges", "bad_weeks=" + str(name)))
        kinds = {}
        for kind in ("words", "sentences", "dialogues"):
            r = _range_of(e.get(kind))
            if r is None:
                out.append(Problem("SCHEMA", "skeleton.id_ranges", "bad_%s_range=%s" % (kind, name)))
            else:
                kinds[kind] = r
        res.append((str(name), weeks, kinds))
    return res


R1_ID_LIMITS = {"words": (1, 699), "sentences": (1, 999), "dialogues": (1, 999)}


def check_skeleton(course, lim):
    out = []
    sk = course.skeleton
    if sk is None:
        return [Problem("SCHEMA", "skeleton.json", "missing")]
    weeks = course.skeleton_weeks()
    seen = {}
    for x in weeks:
        w = x.get("w")
        if not (is_int(w) and 1 <= w <= cc.WEEKS):
            out.append(Problem("SCHEMA", "skeleton", "week_number_bad"))
            continue
        if w in seen:
            out.append(Problem("SCHEMA", _where(w), "duplicate_week"))
        seen[w] = x
    for w in range(1, cc.WEEKS + 1):
        if w not in seen:
            out.append(Problem("SCHEMA", _where(w), "week_missing"))
    # ---- assignment table (top-level `words`, or `assign`)
    assign = course.skeleton_assign()
    by_week = {}
    ids, lemmas = set(), {}
    for a in assign:
        wh = "assign:" + str(a.get("id"))
        if not (is_str(a.get("id")) and ID_WORD.match(a["id"])):
            out.append(Problem("SCHEMA", wh, "bad_id"))
            continue
        if a["id"] in ids:
            out.append(Problem("SCHEMA", wh, "duplicate_id"))
        ids.add(a["id"])
        lem = a.get("lemma")
        if not (is_str(lem) and lem.strip()):
            out.append(Problem("SCHEMA", wh, "lemma_missing"))
            continue
        key1 = cc.norm_en(lem)
        if key1 in lemmas:
            out.append(Problem("SCHEMA", wh, "duplicate_lemma_with=" + lemmas[key1]))
        else:
            lemmas[key1] = a["id"]
        if a.get("pos") not in POS:
            out.append(Problem("SCHEMA", wh, "bad_pos"))
        if a.get("role") not in ("active", "passive"):
            out.append(Problem("SCHEMA", wh, "bad_role"))
        if not (is_int(a.get("w")) and 1 <= a["w"] <= cc.WEEKS):
            out.append(Problem("SCHEMA", wh, "bad_w"))
            continue
        if not (is_int(a.get("d")) and 1 <= a["d"] <= cc.WORD_DAY_MAX):
            out.append(Problem("SCHEMA", wh, "bad_d"))
            continue
        by_week.setdefault(a["w"], []).append(a)
    # ---- patterns: weeks list ids, bodies in the top-level `patterns`
    pats = course.skeleton_patterns()
    listed_in = {}
    totals = {"active": 0, "passive": 0}
    assigned_active = assigned_passive = 0
    canada_ids = {n.get("id") for n in sk.get("canada_notes", []) if isinstance(n, dict)} if isinstance(sk.get("canada_notes"), list) else None
    for w in range(1, cc.WEEKS + 1):
        x = seen.get(w)
        if x is None:
            continue
        wh = _where(w)
        if x.get("n") != (w - 1) // 4 + 1 or x.get("k") != (w - 1) % 4 + 1:
            out.append(Problem("SCHEMA", wh, "n_k_wrong"))
        if x.get("stage") != cc.stage_of_week(w):
            out.append(Problem("SCHEMA", wh, "stage_wrong"))
        if x.get("legacy_stage") != cc.legacy_stage(w):
            out.append(Problem("SCHEMA", wh, "legacy_stage_wrong"))
        if not (is_str(x.get("title_ko")) and cc.HANGUL.search(x["title_ko"])):
            out.append(Problem("SCHEMA", wh, "title_ko_missing"))
        cd = x.get("can_do")
        if w <= 16 and not (_list_of_str(cd) and len(cd) >= 2 and all(cc.HANGUL.search(c) for c in cd)):
            out.append(Problem("SCHEMA", wh, "can_do_needs_2_korean_lines"))
        for key in ("scene", "ladder", "check", "minutes"):
            if not isinstance(x.get(key), dict):
                out.append(Problem("SCHEMA", wh, key + "_missing", warn=True))
        if isinstance(x.get("check"), dict) and x["check"] and not (is_int(x["check"].get("pass")) and 0 <= x["check"]["pass"] <= 100):
            out.append(Problem("SCHEMA", wh, "check_pass_must_be_0_to_100"))
        sc = x.get("scene") if isinstance(x.get("scene"), dict) else {}
        if canada_ids is not None and isinstance(sc.get("canada"), list):
            for cid in sc["canada"]:
                if is_str(cid) and cid not in canada_ids:
                    out.append(Problem("SCHEMA", wh, "scene_canada_unknown_id=" + cid))
        wp = x.get("patterns")
        if not isinstance(wp, list):
            out.append(Problem("SCHEMA", wh, "patterns_missing"))
            wp = []
        week_pats = []
        for pi, p in enumerate(wp):
            if is_str(p):                       # design 10.2: an id; the body is in the top-level list
                pid, body = p, pats.get(p)
                if body is None:
                    out.append(Problem("SCHEMA", "%s:%s" % (wh, pid), "pattern_id_not_defined"))
                    continue
            elif isinstance(p, dict) and is_str(p.get("id")):
                pid, body = p["id"], pats.get(p["id"], p)
            else:
                out.append(Problem("SCHEMA", "%s:#%d" % (wh, pi + 1), "pattern_must_be_an_id_or_an_object"))
                continue
            ph = "%s:%s" % (wh, pid)
            if not ID_PAT.match(pid):
                out.append(Problem("SCHEMA", ph, "bad_pattern_id"))
            if pid in listed_in and listed_in[pid] != w:
                out.append(Problem("SCHEMA", ph, "pattern_listed_in_w%03d_too" % listed_in[pid]))
            listed_in[pid] = w
            if not (is_str(body.get("tpl")) and body["tpl"].strip()):
                out.append(Problem("SCHEMA", ph, "tpl_missing"))
            if is_int(body.get("w")) and body["w"] != w:
                out.append(Problem("SCHEMA", ph, "pattern_w_differs_from_week"))
            if "d" in body and not (is_int(body["d"]) and 1 <= body["d"] <= cc.WORD_DAY_MAX):
                out.append(Problem("SCHEMA", ph, "pattern_d_out_of_range"))
            if w <= 16:
                g = body.get("grammar_ko")
                if not is_str(body.get("title_ko")):
                    out.append(Problem("SCHEMA", ph, "title_ko_missing"))
                if not (_list_of_str(g) and 2 <= len(g) <= 4 and all(len(t) <= 90 for t in g)):
                    out.append(Problem("SCHEMA", ph, "grammar_ko_must_be_2_to_4_short_lines"))
            week_pats.append((pid, body))
        # ---- counts
        w_assign = by_week.get(w, [])
        declared = _skel_counts(x)
        if w_assign:
            act = sum(1 for a in w_assign if a.get("role") == "active")
            pas = sum(1 for a in w_assign if a.get("role") == "passive")
            assigned_active += act
            assigned_passive += pas
            if declared[0] is not None and declared != (act, pas):
                out.append(Problem("COUNT", wh, "counts_%s_differ_from_assignment_%d_%d" % ("%d_%d" % declared, act, pas)))
            wd = x.get("words")
            if isinstance(wd, dict):
                for role, key in (("active", "new"), ("passive", "passive")):
                    want = sorted(a["id"] for a in w_assign if a.get("role") == role)
                    if isinstance(wd.get(key), list) and sorted(wd[key]) != want:
                        out.append(Problem("SCHEMA", wh, "words_%s_differ_from_assignment" % key))
            for dd in x.get("days", []) if isinstance(x.get("days"), list) else []:
                if isinstance(dd, dict) and isinstance(dd.get("words"), list) and is_int(dd.get("d")):
                    want = sorted(a["id"] for a in w_assign if a.get("role") == "active" and a.get("d") == dd["d"])
                    if sorted(dd["words"]) != want:
                        out.append(Problem("SCHEMA", wh, "day%d_words_differ_from_assignment" % dd["d"]))
        else:
            act, pas = declared
            if act is None:
                out.append(Problem("SCHEMA", wh, "word_counts_missing"))
                act = pas = 0
        totals["active"] += act
        totals["passive"] += pas
        arange, prange, patrange = ranges_for(w, lim)
        if not arange[0] <= act <= arange[1]:
            out.append(Problem("COUNT", wh, "active_words=%d want=%d-%d" % (act, arange[0], arange[1])))
        if not prange[0] <= pas <= prange[1]:
            out.append(Problem("COUNT", wh, "passive_words=%d want=%d-%d" % (pas, prange[0], prange[1])))
        if not patrange[0] <= len(wp) <= patrange[1]:
            out.append(Problem("COUNT", wh, "patterns=%d want=%d-%d" % (len(wp), patrange[0], patrange[1])))
        if isinstance(x.get("counts"), dict) and is_int(x["counts"].get("patterns")) and x["counts"]["patterns"] != len(wp):
            out.append(Problem("COUNT", wh, "counts_patterns_differ_from_list"))
        if w_assign and x.get("review") is not True:
            days = {1: 0, 2: 0, 3: 0, 4: 0}
            for a in w_assign:
                if a.get("role") == "active" and a.get("d") in days:
                    days[a["d"]] += 1
            tol = lim["word_day_split_tol"]
            if 20 <= act <= 30 and cc.week_class(w) in ("normal", "intro"):
                for dd, want in ((1, 7), (2, 6), (3, 6)):
                    if abs(days[dd] - want) > tol:
                        out.append(Problem("COUNT", wh, "day%d_active=%d want=%d+-%d" % (dd, days[dd], want, tol)))
                if not 4 <= days[4] <= 7:
                    out.append(Problem("COUNT", wh, "day4_active=%d want=4-7" % days[4]))
    for pid in sorted(set(pats) - set(listed_in)):
        out.append(Problem("SCHEMA", "patterns:" + pid, "pattern_not_listed_in_any_week"))
    if totals["active"] and len(seen) == cc.WEEKS:
        lo, hi = lim["total_active"]
        if not lo <= totals["active"] <= hi:
            out.append(Problem("COUNT", "total", "active_words=%d want=%d-%d" % (totals["active"], lo, hi)))
        lo, hi = lim["total_passive"]
        if not lo <= totals["passive"] <= hi:
            out.append(Problem("COUNT", "total", "passive_words=%d want=%d-%d" % (totals["passive"], lo, hi)))
    if assign and all(w in by_week for w in range(1, 17)):
        lo, hi = lim["assign_active_1_16"]
        if not lo <= assigned_active <= hi:
            out.append(Problem("COUNT", "assign_1_16", "active_words=%d want=%d-%d" % (assigned_active, lo, hi)))
        lo, hi = lim["assign_passive_1_16"]
        if not lo <= assigned_passive <= hi:
            out.append(Problem("COUNT", "assign_1_16", "passive_words=%d want=%d-%d" % (assigned_passive, lo, hi)))
    elif assign:
        out.append(Problem("SCHEMA", "assign", "weeks_1_to_16_not_all_assigned"))
    # ---- pattern needs (K0-5): every needed lemma is taught on or before the pattern's day
    lem_o = {}
    for a in assign:
        if is_str(a.get("lemma")) and is_int(a.get("w")) and is_int(a.get("d")):
            o = a["w"] * 10 + a["d"]
            lem_o["lemma:" + cc.norm_en(a["lemma"])] = min(lem_o.get("lemma:" + cc.norm_en(a["lemma"]), 10 ** 9), o)
            for t in cc.tokenize(a["lemma"]):
                lem_o[t] = min(lem_o.get(t, 10 ** 9), o)
            lem_o["id:" + str(a.get("id"))] = o
    for pid, body in sorted(pats.items()):
        if "needs" not in body:
            continue
        w = listed_in.get(pid, body.get("w") if is_int(body.get("w")) else 1)
        idx = next((i for i, p in enumerate(seen.get(w, {}).get("patterns") or []) if (p if is_str(p) else p.get("id")) == pid), 0)
        po = w * 10 + cc.week_pattern_day(idx, body)
        ph = "%s:%s" % (_where(w), pid)
        needs = body.get("needs")
        if not _list_of_str(needs):
            out.append(Problem("SCHEMA", ph, "needs_must_be_a_list_of_text"))
            continue
        for n in needs:
            if ID_WORD.match(n):
                o = lem_o.get("id:" + n)
            else:
                o = lem_o.get("lemma:" + cc.norm_en(n))
                if o is None:
                    toks = cc.tokenize(n)
                    os_ = [lem_o.get(t) for t in toks]
                    o = None if (not toks or any(v is None for v in os_)) else max(os_)
            if o is None:
                out.append(Problem("UNKNOWN_TOKEN", ph, "needs=" + n))
            elif o > po:
                out.append(Problem("ORDER", ph, "needs=%s need_o=%d pattern_o=%d" % (n, o, po)))
    # ---- canada notes: some note in every two consecutive weeks from week 8 (weeks 8..16)
    def has_note(w):
        x = seen.get(w, {})
        sc = x.get("scene") if isinstance(x.get("scene"), dict) else {}
        for v in (sc.get("canada"), x.get("canada_notes"), x.get("canada")):
            if isinstance(v, list) and v:
                return True
        for n in sk.get("canada_notes", []) if isinstance(sk.get("canada_notes"), list) else []:
            if isinstance(n, dict) and n.get("w") == w:
                return True
        return False
    for w in range(8, 16):
        if w in seen and (w + 1) in seen and not (has_note(w) or has_note(w + 1)):
            out.append(Problem("SCHEMA", _where(w), "no_canada_note_in_weeks_%d_%d" % (w, w + 1)))
    # ---- id ranges (K0-6)
    ranges = parse_id_ranges(sk, out)
    for kind, (lo_lim, hi_lim) in R1_ID_LIMITS.items():
        mine = [(n, k[kind]) for n, _w, k in ranges if kind in k]
        for n, (lo, hi) in mine:
            if lo < lo_lim or hi > hi_lim:
                out.append(Problem("SCHEMA", "id_ranges", "%s_range_outside_R1_limits=%s" % (kind, n)))
        for i in range(len(mine)):
            for j in range(i + 1, len(mine)):
                (n1, (a1, b1)), (n2, (a2, b2)) = mine[i], mine[j]
                if not (b1 < a2 or b2 < a1):
                    out.append(Problem("SCHEMA", "id_ranges", "%s_ranges_overlap=%s,%s" % (kind, n1, n2)))
    for a in assign:
        n = _id_num(a.get("id"))
        if n is not None and not (1 <= n <= 699):
            out.append(Problem("SCHEMA", "assign:" + str(a.get("id")), "id_outside_R1_word_range"))
    return out


def _skel_counts(x):
    c = x.get("counts")
    if isinstance(c, dict):
        a, p = c.get("active", c.get("new")), c.get("passive")
        if is_int(a) and is_int(p):
            return a, p
    wd = x.get("words")
    if isinstance(wd, dict):
        a, p = wd.get("active", wd.get("new")), wd.get("passive")
        if is_int(a) and is_int(p):
            return a, p
    for ka, kp in (("active_words", "passive_words"), ("n_active", "n_passive"), ("active", "passive"), ("new_active", "new_passive")):
        if is_int(x.get(ka)) and is_int(x.get(kp)):
            return x[ka], x[kp]
    return None, None


def check_assignment(course, weeks, out):
    """A-2: the week files carry exactly the words assigned in skeleton.json (ids, lemma, pos, role, d). Words on top
    of the table are allowed only for proper nouns (pos propn, listed in policy.json) with an id inside the author's
    word range and not before the week the policy allows the name."""
    by_week = {}
    for a in course.skeleton_assign():
        if is_int(a.get("w")):
            by_week.setdefault(a["w"], {})[a.get("id")] = a
    ranges = parse_id_ranges(course.skeleton or {}, []) if course.skeleton else []
    names = cc.policy_names(course.policy)
    for w in weeks:
        wk = course.weeks.get(w)
        if wk is None:
            continue
        want = by_week.get(w, {})
        got = {x.get("id"): x for x in wk.get("words", []) or [] if isinstance(x, dict)}
        mine = [(n, k) for n, wr, k in ranges if wr and wr[0] <= w <= wr[1]]
        for i in sorted(set(want) - set(got)):
            out.append(Problem("SCHEMA", _where(w, i), "assigned_word_missing"))
        for i in sorted(set(got) - set(want)):
            x = got[i]
            if x.get("pos") != "propn":
                out.append(Problem("SCHEMA", _where(w, i), "word_not_in_assignment"))
                continue
            n = _id_num(i)
            if mine and not any("words" in k and k["words"][0] <= n <= k["words"][1] for _a, k in mine):
                out.append(Problem("SCHEMA", _where(w, i), "id_outside_author_range"))
            key = cc.nfkc(x.get("en", "")).lower().strip()
            if key not in names:
                out.append(Problem("PERSONAL", _where(w, i), "name_not_in_policy"))
            elif names[key] > w:
                out.append(Problem("PERSONAL", _where(w, i), "name_before_allowed_week=%d" % names[key]))
        for i in sorted(set(want) & set(got)):
            a, x = want[i], got[i]
            if cc.norm_en(a.get("lemma", "")) != cc.norm_en(x.get("en", "")):
                out.append(Problem("SCHEMA", _where(w, i), "lemma_differs_from_assignment"))
            if a.get("pos") != x.get("pos") or a.get("role") != x.get("role") or a.get("d") != x.get("d"):
                out.append(Problem("SCHEMA", _where(w, i), "pos_role_or_day_differs_from_assignment"))
        if mine:
            for kind in ("sentences", "dialogues"):
                for x in wk.get(kind, []) or []:
                    n = _id_num(x.get("id")) if isinstance(x, dict) else None
                    if n is None:
                        continue
                    if not any(kind in k and k[kind][0] <= n <= k[kind][1] for _a, k in mine):
                        out.append(Problem("SCHEMA", _where(w, x.get("id")), "id_outside_author_range"))


# ================================================================================================ review tsv
REVIEW_HEADER = ["id", "type", "verdict", "issue", "fix"]


def check_review(course, weeks, tsv_path, strict):
    rows = cc.count_items(course, weeks)
    want = {}
    for kind, i in rows:
        want[str(i)] = kind
    try:
        with open(tsv_path, "r", encoding="utf-8-sig", newline="") as f:
            reader = list(csv.reader(f, delimiter="\t"))
    except (OSError, UnicodeDecodeError):
        return ["REVIEW_FAIL tsv_unreadable"], False
    if not reader or [h.strip().lower() for h in reader[0]][:3] != REVIEW_HEADER[:3]:
        return ["REVIEW_FAIL header_must_start_with_id_type_verdict"], False
    got, bad, counts = {}, [], {"OK": 0, "M": 0, "C": 0}
    for n, r in enumerate(reader[1:], 2):
        if not r or all(not c.strip() for c in r):
            continue
        if len(r) < 3:
            bad.append("row=%d too_few_columns" % n)
            continue
        i, t, v = r[0].strip(), r[1].strip(), r[2].strip()
        if v not in counts:
            bad.append("row=%d verdict_not_OK_M_C" % n)
            continue
        if i in got:
            bad.append("row=%d duplicate_id=%s" % (n, i))
            continue
        if i in want and want[i] != t:
            bad.append("row=%d wrong_type_for_id=%s" % (n, i))
        got[i] = v
        counts[v] += 1
    missing = sorted(set(want) - set(got))
    extra = sorted(set(got) - set(want))
    lines = []
    if bad:
        lines += ["  " + b for b in bad[:50]]
    if missing:
        lines += ["  missing=%s" % ",".join(missing[:30]) + (" ..." if len(missing) > 30 else "")]
    if extra:
        lines += ["  extra=%s" % ",".join(extra[:30]) + (" ..." if len(extra) > 30 else "")]
    if bad or missing or extra:
        return ["REVIEW_FAIL rows=%d items=%d bad=%d missing=%d extra=%d" % (len(got), len(want), len(bad), len(missing), len(extra))] + lines, False
    tail = "REVIEW_OK rows=%d C=%d M=%d" % (len(got), counts["C"], counts["M"])
    if strict and counts["C"]:
        return ["REVIEW_FAIL rows=%d C=%d (strict: C must be 0)" % (len(got), counts["C"])], False
    return [tail], True


# ================================================================================================ driver
class Result:
    def __init__(self):
        self.violations, self.warnings, self.notes, self.stats = [], [], [], {}
        self.first_code = ""


def run_check(in_dir, weeks_arg=None, strict=False, skeleton=False, lexicon_from="files", grammar=False,
              tatoeba_db=None, grammar_module=None, grammar_path=None, lt_dir=None):
    res = Result()
    course = cc.Course(in_dir).load()
    lim = course.limits()
    probs = list(course.problems)
    if skeleton:
        probs += check_skeleton(course, lim)
        if not course.has_policy:
            probs.append(Problem("SCHEMA", "policy.json", "missing", warn=True))
        if weeks_arg is None:
            return _finish(res, probs, strict, "1-72", {"mode": "skeleton"})
    weeks = cc.select_weeks(course, weeks_arg)
    label = "%d-%d" % (weeks[0], weeks[-1]) if weeks else "none"
    if not skeleton:
        if not course.has_policy:
            probs.append(Problem("SCHEMA", "policy.json", "missing", warn=True))
        if weeks_arg is not None:
            for w in weeks:
                if w not in course.weeks:
                    probs.append(Problem("SCHEMA", _where(w), "week_file_missing"))
        elif not weeks:
            probs.append(Problem("SCHEMA", "weeks", "no_week_files_found"))
    # schema of every loaded week file (files outside the range are only reported as warnings)
    bad_weeks = set()
    for w in sorted(course.weeks):
        tmp = []
        validate_week(w, course.weeks[w], course.week_files[w].name, lim, tmp)
        errs = [p for p in tmp if not p.warn]
        if w in weeks:
            probs += tmp
        elif errs:
            probs.append(Problem("SCHEMA", _where(w), "outside_range_file_invalid_ignored_%d_problems" % len(errs), warn=True))
        if errs:
            bad_weeks.add(w)
    # global id uniqueness (words / sentences / dialogues / patterns / prompts / notes)
    owner = {}
    for w in sorted(course.weeks):
        if w in bad_weeks and w not in weeks:
            continue
        wk = course.weeks[w]
        for key in ("words", "patterns", "sentences", "dialogues", "speak_prompts", "notes"):
            for x in wk.get(key, []) or []:
                i = x.get("id") if isinstance(x, dict) else None
                if is_str(i):
                    if i in owner and owner[i] != w and (w in weeks or owner[i] in weeks):
                        probs.append(Problem("SCHEMA", _where(w, i), "duplicate_id_also_in_w%03d" % owner[i]))
                    owner.setdefault(i, w)
    if any(not p.warn and p.code == "SCHEMA" for p in probs):
        return _finish(res, probs, strict, label, {})
    usable = [w for w in course.weeks if w not in bad_weeks]
    if lexicon_from == "skeleton":
        if course.skeleton is None:
            probs.append(Problem("SCHEMA", "skeleton.json", "needed_for_lexicon_from_skeleton"))
            return _finish(res, probs, strict, label, {})
        check_assignment(course, weeks, probs)
    lex = cc.build_lexicon(course, lexicon_from, usable)
    ctx = Ctx(course, [w for w in weeks if w in course.weeks], lex, strict)
    ctx.notes = res.notes
    ctx.usable = sorted(usable)
    ctx.acr, ctx.is_word = lex.acronym_map(), lex.is_word
    ctx.pat_o = cc.pattern_o_map(course)
    for fn in (check_order, check_num_say, check_ko, check_dups, check_same_ko, check_blocked, check_personal, check_counts, check_canon,
               check_forms):
        fn(ctx)
    check_tatoeba(ctx, tatoeba_db)
    if grammar:
        check_grammar(ctx, grammar_module, grammar_path, lt_dir)
    probs += ctx.out
    stats = {"words": sum(len(course.weeks[w].get("words", [])) for w in ctx.weeks),
             "sentences": sum(len(course.weeks[w].get("sentences", [])) for w in ctx.weeks),
             "dialogue_lines": sum(len(d.get("lines", [])) for w in ctx.weeks for d in course.weeks[w].get("dialogues", []))}
    return _finish(res, probs, strict, label, stats)


def _finish(res, probs, strict, label, stats):
    probs = sorted(probs, key=lambda p: (CODES.index(p.code) if p.code in CODES else 99))
    if strict:      # --strict: every warning is a violation (unknown keys, Korean style, missing policy, unverified Tatoeba ...)
        for p in probs:                       # ... except the soft ones (a spelling that Canada uses as well)
            if not p.soft:
                p.warn = False
    res.violations = [p for p in probs if not p.warn]
    res.warnings = [p for p in probs if p.warn]
    res.stats, res.label = stats, label
    res.first_code = res.violations[0].code if res.violations else ""
    return res


def format_result(res, max_lines=200):
    lines = []
    if res.violations:
        lines.append("CHECK_FAIL " + res.first_code)
        for p in res.violations[:max_lines]:
            lines.append(p.line())
        if len(res.violations) > max_lines:
            lines.append("  ... %d more" % (len(res.violations) - max_lines))
    for p in res.warnings[:50]:
        lines.append(p.line())
    lines += res.notes
    counts = {}
    for p in res.violations:
        counts[p.code] = counts.get(p.code, 0) + 1
    st = " ".join("%s=%s" % kv for kv in res.stats.items())
    if res.violations:
        lines.append("CHECK_FAIL weeks=%s%s violations=%d codes=%s" % (res.label, (" " + st) if st else "", len(res.violations),
                                                                      ",".join("%s:%d" % kv for kv in sorted(counts.items()))))
    else:
        lines.append("CHECK_OK weeks=%s%s violations=0" % (res.label, (" " + st) if st else ""))
    return lines


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    ap = argparse.ArgumentParser(description="Course manuscript linter")
    ap.add_argument("--in", dest="in_dir", required=True)
    ap.add_argument("--weeks", default=None)
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--skeleton", action="store_true")
    ap.add_argument("--grammar", action="store_true")
    ap.add_argument("--grammar-backend", dest="grammar_path", default=None, help="path of backend/grammar.py (default: this repo's)")
    ap.add_argument("--lt-dir", dest="lt_dir", default=None, help="LanguageTool folder (default: backend/tools/languagetool of this repo or of the main checkout)")
    ap.add_argument("--lexicon-from", dest="lexicon_from", choices=["files", "skeleton"], default="files")
    ap.add_argument("--tatoeba-db", dest="tatoeba_db", default=None)
    ap.add_argument("--count-items", dest="count_items", action="store_true")
    ap.add_argument("--review", default=None)
    a = ap.parse_args(argv)
    try:
        weeks_arg = cc.parse_weeks_arg(a.weeks)
    except ValueError as e:
        print("CHECK_FAIL SCHEMA bad_weeks_argument")
        print(str(e))
        return 1
    if a.count_items or a.review:
        course = cc.Course(a.in_dir).load()
        if any(p.code == "SCHEMA" for p in course.problems):
            for p in course.problems:
                print(p.line())
            print("CHECK_FAIL SCHEMA load")
            return 1
        weeks = cc.select_weeks(course, weeks_arg)
        if a.count_items:
            rows = cc.count_items(course, weeks)
            kinds = {}
            for k, _ in rows:
                kinds[k] = kinds.get(k, 0) + 1
            print("ITEMS weeks=%s %s total=%d" % ("%d-%d" % (weeks[0], weeks[-1]) if weeks else "none",
                                                  " ".join("%s=%d" % (k, kinds.get(k, 0)) for k in ("word", "pattern", "sentence", "dialogue_line")),
                                                  len(rows)))
            if not a.review:
                return 0
        lines, ok = check_review(course, weeks, a.review, a.strict)
        for ln in lines:
            print(ln)
        return 0 if ok else 1
    res = run_check(a.in_dir, weeks_arg, a.strict, a.skeleton, a.lexicon_from, a.grammar, a.tatoeba_db, None, a.grammar_path, a.lt_dir)
    for ln in format_result(res):
        print(ln)
    return 1 if res.violations else 0


if __name__ == "__main__":
    sys.exit(main())
