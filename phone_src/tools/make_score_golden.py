# -*- coding: utf-8 -*-
"""PA2: golden file for the phone's English scoring (docs/v201_design.md 2.1, 5.2; docs/v200_phone_design.md 6.4).

The phone (GDScript `ScoreCore`) must score a spoken English sentence exactly like backend\\server.py `score_en`. This tool CALLS the
server functions in the same process (nothing is copied here) and writes what they returned:
  cases      full `score_en(target, words, text)` results (keys, values and key order), some with another OK_PROB
  align      `align_seq` pairs / inserts and `word_sim` values for token lists
  en_words   `en_words(text)` for practice sentences and hard inputs
  known_gaps inputs where the GDScript copy is KNOWN to differ (the test asserts they still differ)
into godot\\tests\\fixtures\\score_golden_en.json. `godot\\tests\\score_parity_test.gd` must reproduce all of it.

  --write   (default) write the golden file
  --check   build the same data in memory and compare with the file on disk (and check that the Unicode tables in
            godot\\scripts\\core\\score_core.gd are the ones this tool generates). Different -> "GOLDEN_DRIFT <what>" lines, exit 1.
            (the server changed: port the change to ScoreCore, then run --write.) Last line when clean: SCORE_GOLDEN_OK cases=<n>
  --tables  print the generated Unicode tables (the block between "const _NFKC_RUNS" and the end of "const _ACCENT" in score_core.gd)
  --list    print the number of entries per section

Exit code: 0 ok, 1 drift / missing file, 2 bad usage or a case that cannot run.

Safety: no network, no model, no port, no server process, nothing written under backend\\. Socket creation, name lookup and process
start are blocked while the generator runs; importing server.py makes its log/cache folders and writes bytecode: those calls are
skipped for paths under backend\\. Only godot\\tests\\fixtures\\score_golden_en.json is written (with --write).
Run:  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I -X utf8 phone_src\\tools\\make_score_golden.py --check
"""
import contextlib
import copy
import json
import os
import platform
import random
import re
import shutil
import socket
import string
import subprocess
import sys
import tempfile
import unicodedata

sys.dont_write_bytecode = True   # no backend\__pycache__ (and none next to this file)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BACKEND = os.path.join(ROOT, "backend")
OUT_PATH = os.path.join(ROOT, "godot", "tests", "fixtures", "score_golden_en.json")
CORE_PATH = os.path.join(ROOT, "godot", "scripts", "core", "score_core.gd")
PRACTICE_PATH = os.path.join(ROOT, "godot", "data", "pack", "practice_en.json")
FORMAT_VERSION = 1
SEED = 20261119
EMPTY_TARGET_MSG = "연습할 문장이 비어 있어요."


class GoldenError(Exception):
    """something that cannot run (missing practice file, a case the server rejects unexpectedly): exit 2"""


class NetworkBlocked(RuntimeError):
    """socket / name lookup / process start while the generator runs"""


STATE = {"server": None}


# ------------------------------------------------------------------------------------------------ safety guards
@contextlib.contextmanager
def no_network():
    """socket creation, name lookup and subprocess start raise NetworkBlocked inside this block"""
    def _blocked(*a, **k):
        raise NetworkBlocked("network / process access is blocked while the golden generator runs")
    platform.uname()   # numpy reads the OS name at import, which starts `ver` on Windows the first time: do it before the guard
    saved = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__)
    socket.socket.__init__ = _blocked
    socket.getaddrinfo = _blocked
    socket.create_connection = _blocked
    subprocess.Popen.__init__ = _blocked
    try:
        yield
    finally:
        socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__ = saved


def _under_backend(path):
    try:
        p = os.path.abspath(os.fspath(path))
    except Exception:
        return False
    b = os.path.abspath(BACKEND)
    return p == b or p.startswith(b + os.sep)


@contextlib.contextmanager
def keep_backend_clean():
    """importing server.py calls os.makedirs for backend\\models\\hf, logs, cache\\tts: skip those (nothing is created under backend\\)"""
    real = os.makedirs

    def makedirs(name, mode=0o777, exist_ok=False):
        if _under_backend(name):
            return None
        return real(name, mode, exist_ok)
    os.makedirs = makedirs
    try:
        yield
    finally:
        os.makedirs = real


def load_server():
    """import backend\\server.py once, in this process (no port is opened: only a server PROCESS does that)"""
    if STATE["server"] is not None:
        return STATE["server"]
    sys.dont_write_bytecode = True
    tmp = tempfile.mkdtemp(prefix="hoehwa_scoregolden_")
    os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(tmp, "espeak")
    saved_argv = sys.argv
    sys.argv = [saved_argv[0], "--tag", "golden_score"]   # server.py reads sys.argv for --port / --prefetch / --tag
    if BACKEND not in sys.path:
        sys.path.insert(0, BACKEND)
    try:
        with keep_backend_clean():
            import server
    finally:
        sys.argv = saved_argv
        shutil.rmtree(tmp, ignore_errors=True)
    STATE["server"] = server
    return server


# ------------------------------------------------------------------------------------------------ the Unicode tables of score_core.gd
def _lit(s):
    return json.dumps(s, ensure_ascii=True)   # \uXXXX escapes: a valid GDScript string literal


def _ranges(values):
    """sorted integers -> [(first, last), ...] of consecutive runs"""
    out = []
    if not values:
        return out
    s = p = values[0]
    for x in values[1:]:
        if x == p + 1:
            p = x
        else:
            out.append((s, p))
            s = p = x
    out.append((s, p))
    return out


def unicode_data():
    """The facts en_words needs from unicodedata (CPython's NFKC, lower(), \\d, \\w), as plain Python data.
    en_words does NFKC, lower(), then keeps only a-z 0-9 ' (everything else is a space), deletes a thousands comma that has a digit
    before it and three digits and a non-word character (or the end) after it, and splits. What can matter for one code point:
      ent      its NFKC text holds a-z 0-9 ' or a comma: the text itself (non-ASCII letters reduced to U+00C0, a word character,
               other non-ASCII characters to a space, which is what the final step makes of them)
      mark_decomp / ccc / compose   canonical ordering and composition of an ASCII letter with the combining marks after it
               (a letter that composes is no longer a-z: it becomes U+00C0, a word character; I + U+0307 gives U+0130 whose lower()
               is "i" + U+0307, so "i" and a space)
      digits   code points >= 0x80 with category Nd (\\d), nonword   code points >= 0x80 that are not \\w, both for the character
               as it is after NFKC. Asserts below make sure the shortcuts used here are true for this Unicode version."""
    word = re.compile(r"\w")
    digit = re.compile(r"\d")
    N = unicodedata.normalize

    def proj(out):
        r = []
        for ch in out:
            if ord(ch) < 128:
                r.append(ch)
            elif ch in "\u2019\u2018":
                r.append("'")
            elif digit.match(ch):
                raise AssertionError("a non-ASCII digit in an NFKC text: U+%04X" % ord(ch))
            elif word.match(ch):
                r.append("\u00c0")
            else:
                r.append(" ")
        return "".join(r)
    ent, changed = {}, {}
    for c in range(0x80, 0x110000):
        if 0xD800 <= c <= 0xDFFF:
            continue
        ch = chr(c)
        n = N("NFKC", ch)
        if n == ch:
            continue
        changed[c] = n
        low = n.lower()
        if re.search(r"[a-z0-9',]", low) or re.search("[\u2019\u2018`]", low):
            ent[c] = proj(n)
        elif not n:
            raise AssertionError("a character that vanishes under NFKC: U+%04X" % c)
        elif any(digit.match(x) and ord(x) > 127 for x in n):
            raise AssertionError("a non-ASCII digit in an NFKC text: U+%04X" % c)
    # lower() changes the length of a text only for U+0130 (to "i" + U+0307) and gives ASCII only for it: no table of multi-character
    # lower() mappings is needed, U+0130 is handled as I + U+0307 (its canonical decomposition) before the marks are composed
    for c in range(0x80, 0x110000):
        if 0xD800 <= c <= 0xDFFF:
            continue
        if len(chr(c).lower()) != 1 and c != 0x130:
            raise AssertionError("lower() of U+%04X is not one character" % c)
    assert N("NFD", "\u0130") == "I\u0307" and N("NFKC", "\u0130") == "\u0130" and "\u0130".lower() == "i\u0307"
    for c, out in ent.items():   # the projection drops marks: no NFKC text of the table may hold one
        assert not any(unicodedata.combining(x) for x in N("NFKC", chr(c))), "U+%04X" % c
    # lower() of a character that NFKC leaves alone gives ASCII only for U+0130
    for c in range(0x80, 0x30000):
        if 0xD800 <= c <= 0xDFFF or c in changed:
            continue
        if re.search(r"[a-z0-9]", chr(c).lower()) and c != 0x130:
            raise AssertionError("lower() gives ASCII for U+%04X" % c)
    # marks
    ccc = {}
    for c in range(0x80, 0x110000):
        if 0xD800 <= c <= 0xDFFF:
            continue
        cc = unicodedata.combining(chr(c))
        if cc:
            ccc[c] = cc
    mark_decomp = {}
    for c in range(0x80, 0x110000):
        if 0xD800 <= c <= 0xDFFF:
            continue
        n = N("NFKD", chr(c))
        if n != chr(c) and n and all(unicodedata.combining(x) > 0 for x in n):
            mark_decomp[c] = [ord(x) for x in n]
    for c in ent:   # no NFKC text of the table starts with a mark (it would join the letter before it)
        assert not unicodedata.combining(N("NFKD", chr(c))[0]), "U+%04X" % c
    for c, n in changed.items():   # a changed character that starts with a mark is one of mark_decomp
        if unicodedata.combining(N("NFKD", chr(c))[0]):
            assert c in mark_decomp, "U+%04X" % c
    compose = {}
    for m in sorted(ccc):
        if m in mark_decomp:
            continue
        letters = "".join(L for L in string.ascii_letters if len(N("NFC", L + chr(m))) == 1)
        if letters:
            compose[m] = letters
        for x in string.digits + "',":    # only letters compose with a mark
            assert len(N("NFC", x + chr(m))) == 2, "U+%04X" % m
    digits, nonword = [], []
    for c in range(0x80, 0x110000):
        if 0xD800 <= c <= 0xDFFF or c in ent:
            continue
        n = changed.get(c, chr(c))
        f = n[0]
        if not word.match(f):
            nonword.append(c)
        if c not in changed and digit.match(chr(c)):
            digits.append(c)
    # runs of NFKC-text that are consecutive ASCII
    items = sorted(ent.items())
    runs, singles = [], {}
    i = 0
    while i < len(items):
        c, n = items[i]
        j = i
        if len(n) == 1 and n.isascii():
            while (j + 1 < len(items) and items[j + 1][0] == items[j][0] + 1 and len(items[j + 1][1]) == 1
                   and items[j + 1][1].isascii() and ord(items[j + 1][1]) == ord(items[j][1]) + 1):
                j += 1
        if j - i >= 2:
            runs.append((c, items[j][0], n))
            i = j + 1
        else:
            singles[c] = n
            i += 1
    ccc_runs, items2 = [], sorted(ccc.items())
    for c, cc in items2:
        if ccc_runs and ccc_runs[-1][1] == c - 1 and ccc_runs[-1][2] == cc:
            ccc_runs[-1] = (ccc_runs[-1][0], c, cc)
        else:
            ccc_runs.append((c, c, cc))
    return {"runs": runs, "singles": singles, "mark_decomp": mark_decomp, "ccc": ccc_runs, "compose": compose,
            "digits": _ranges(digits), "nonword": _ranges(nonword)}


def nfkc_tables_text():
    """GDScript source of the tables of score_core.gd (the block between the TABLES-BEGIN and TABLES-END comment lines)"""
    d = unicode_data()
    out = ["const _NFKC_RUNS := ["]
    line = ["[0x%X, 0x%X, %s]" % (a, b, _lit(base)) for a, b, base in d["runs"]]
    for k in range(0, len(line), 4):
        out.append("\t" + ", ".join(line[k:k + 4]) + ",")
    out.append("]")
    out.append("const _NFKC_ONE := {")
    line = ["0x%X: %s" % (c, _lit(v)) for c, v in sorted(d["singles"].items())]
    for k in range(0, len(line), 5):
        out.append("\t" + ", ".join(line[k:k + 5]) + ",")
    out.append("}")
    out.append("const _MARK_DECOMP := {")
    line = ["0x%X: [%s]" % (c, ", ".join("0x%X" % x for x in v)) for c, v in sorted(d["mark_decomp"].items())]
    for k in range(0, len(line), 4):
        out.append("\t" + ", ".join(line[k:k + 4]) + ",")
    out.append("}")
    out.append("const _CCC := [")
    line = ["0x%X, 0x%X, %d" % (a, b, cc) for a, b, cc in d["ccc"]]
    for k in range(0, len(line), 6):
        out.append("\t" + ", ".join(line[k:k + 6]) + ",")
    out.append("]")
    out.append("const _COMPOSE := {")
    line = ['0x%X: "%s"' % (m, s) for m, s in d["compose"].items()]
    for k in range(0, len(line), 3):
        out.append("\t" + ", ".join(line[k:k + 3]) + ",")
    out.append("}")
    out.append("const _DIGITS := [")
    line = ["0x%X, 0x%X" % (a, b) for a, b in d["digits"]]
    for k in range(0, len(line), 8):
        out.append("\t" + ", ".join(line[k:k + 8]) + ",")
    out.append("]")
    out.append("const _NONWORD := [")
    line = ["0x%X, 0x%X" % (a, b) for a, b in d["nonword"]]
    for k in range(0, len(line), 8):
        out.append("\t" + ", ".join(line[k:k + 8]) + ",")
    out.append("]")
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------------------------------------ inputs
def load_practice():
    try:
        with open(PRACTICE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return [s["text"] for s in data["sentences"]]
    except (OSError, ValueError, KeyError) as e:
        raise GoldenError("cannot read %s: %s" % (PRACTICE_PATH, e))


# confusions the server has tips for: (target letters, heard letters)
CONFUSIONS = [("r", "l"), ("l", "r"), ("f", "p"), ("p", "f"), ("v", "b"), ("b", "v"), ("th", "s"), ("th", "d"), ("th", "t"),
              ("th", "z"), ("z", "j"), ("j", "z"), ("i", "ee"), ("ee", "i"), ("u", "oo"), ("oo", "u"), ("a", "e"), ("e", "a")]


def confuse(rng, word):
    """a heard word: one confusable letter group replaced, or the last letters dropped, or None when nothing applies"""
    w = word.lower()
    opts = [(a, b) for a, b in CONFUSIONS if a in w]
    if opts and rng.random() < 0.75:
        a, b = rng.choice(opts)
        k = w.find(a)
        return w[:k] + b + w[k + len(a):]
    if len(w) >= 4 and rng.random() < 0.6:
        return w[:-rng.choice([1, 1, 2])]
    return None


def pround(rng, x):
    return round(x, rng.choice([2, 3, 3, 4, 4, 4, 5]))


def make_words(rng, tokens, probs, scale=1.0, pause_at=None, pause=1.2):
    """[{w, p, start, end}] for tokens, with time stamps: short words ~0.2-0.5 s, small gaps, one optional long pause"""
    out = []
    t = round(rng.uniform(0.0, 0.4), 2)
    for k, (w, p) in enumerate(zip(tokens, probs)):
        dur = round(scale * rng.uniform(0.15, 0.30) * (1.0 + len(w) / 6.0), 2)
        dur = max(dur, 0.05)
        out.append({"w": w, "p": p, "start": round(t, 2), "end": round(t + dur, 2)})
        gap = round(scale * rng.uniform(0.0, 0.18), 2)
        if pause_at is not None and k == pause_at:
            gap = pause
        t = round(t + dur + gap, 2)
    return out


def spec_words(spec, scale=1.0, p=0.9):
    """spec: words separated by spaces, or a list of words / (word, p) tuples -> words with a fixed pace (no randomness)"""
    items = spec.split() if isinstance(spec, str) else list(spec)
    out = []
    t = 0.1
    for it in items:
        w, pp = (it if isinstance(it, tuple) else (it, p))
        dur = round(scale * 0.25 * (1.0 + len(w) / 8.0), 2)
        out.append({"w": w, "p": pp, "start": round(t, 2), "end": round(t + dur, 2)})
        t = round(t + dur + round(scale * 0.05, 2), 2)
    return out


def join_text(words):
    return " ".join(w["w"] for w in words)


# ------------------------------------------------------------------------------------------------ cases
def hand_cases():
    """(id, target, words, text, ok_prob or None): hand written, one idea each"""
    H = []

    def add(cid, target, words, text=None, ok_prob=None):
        H.append((cid, target, words, join_text(words) if text is None else text, ok_prob))
    # exact / good
    add("exact_basic", "I would like a cup of coffee, please.", spec_words("I would like a cup of coffee, please."))
    add("exact_caps_punct", "Where is the nearest station?", spec_words("Where is the nearest station?"))
    add("exact_curly_quotes", "It\u2019s a nice day, isn\u2019t it?", spec_words("It\u2019s a nice day, isn\u2019t it?"))
    add("exact_one_word", "Hello", spec_words("Hello."))
    add("exact_two_words", "Thank you", spec_words("Thank you."))
    add("low_p_all", "I would like a cup of coffee, please.", spec_words("I would like a cup of coffee, please.", p=0.3))
    add("p_zero", "How are you today", spec_words("How are you today", p=0.0))
    add("p_one", "How are you today", spec_words("How are you today", p=1.0))
    add("p_boundary_045", "See you tomorrow", spec_words([("See", 0.45), ("you", 0.4499), ("tomorrow", 0.4501)]))
    # missing / extra / substitution
    add("missing_one", "I would like a cup of coffee, please.", spec_words("I would like cup of coffee, please."))
    add("missing_many", "I would like a cup of coffee, please.", spec_words("I like coffee."))
    add("extra_one", "I would like a cup of coffee.", spec_words("I would really like a cup of coffee."))
    add("extra_start_end", "Nice to meet you", spec_words("Well nice to meet you too"))
    add("sub_unrelated", "I would like a cup of coffee.", spec_words("I would like a bag of coffee."))
    add("sub_two", "She sells sea shells by the sea shore.", spec_words("She sells see shall by the see shore."))
    add("repeat_word", "I love you", spec_words("I I love love you"))
    add("reverse_order", "one two three four five", spec_words("five four three two one"))
    add("all_wrong", "I would like a cup of coffee, please.", spec_words("Good morning everyone how are things"))
    add("totally_different_short", "Hello", spec_words("Goodbye"))
    # tip rules: one per rule key of _EN_RULES
    for tag, tgt, heard in [
        ("rl", "I think the right answer is here", "I think the light answer is here"),
        ("lr", "I think the light answer is here", "I think the right answer is here"),
        ("fp", "I need a fan today", "I need a pan today"),
        ("pf", "I need a pan today", "I need a fan today"),
        ("vb", "It is very good", "It is berry good"),
        ("bv", "It is berry good", "It is very good"),
        ("th_s", "I think so", "I sink so"),
        ("th_d", "I like this one", "I like dis one"),
        ("th_t", "I have three cats", "I have tree cats"),
        ("th_z", "I like this one", "I like zis one"),
        ("zj", "I went to the zoo", "I went to the joo"),
        ("jz", "He told a joke today", "He told a zoke today"),
        ("i_ee", "The ship is big", "The sheep is big"),
        ("i_ea", "I will bit it", "I will beat it"),
        ("ee_i", "The sheep is big", "The ship is big"),
        ("ea_i", "I will beat it", "I will bit it"),
        ("u_oo", "It is full of milk", "It is fool of milk"),
        ("oo_u", "He is a fool today", "He is a full today"),
        ("a_e", "That was bad news", "That was bed news"),
        ("e_a", "I need a bed now", "I need a bad now"),
    ]:
        add("tip_" + tag, tgt, spec_words(heard))
    add("tip_two_rules", "I think the right ship is here", spec_words("I sink the light sheep is here"))
    add("tip_same_rule_twice", "The right light is here", spec_words("The light right is here"))
    add("tip_three_rules_cap", "I think the right ship has a fan", spec_words("I sink the light sheep has a pan"))
    # dropped final consonants
    add("final_s", "I have two cats here", spec_words("I have two cat here"))
    add("final_d", "He is my best friend", spec_words("He is my best frien"))
    add("final_other", "That is the best one", spec_words("That is the bes one"))
    add("final_short_none", "It is on its way", spec_words("It is on it way"))
    add("final_two_missing", "He has many hands", spec_words("He has many han"))
    add("generic_one_missing", "I like red apples", spec_words("I like apples"))
    add("generic_extra_ok", "I like apples", spec_words("I like red apples"))
    # contractions / numbers / text rules
    add("contr_dont", "I don't know", spec_words("I don't know"))
    add("contr_dont_split", "I do not know", spec_words("I don't know"))
    add("contr_im", "I'm happy", spec_words("I'm happy"))
    add("contr_its", "It's raining", spec_words("It's raining"))
    add("contr_expanded_heard", "I'm happy and it's late", spec_words("I am happy and it is late"))
    add("contr_cant_cannot", "I can't go", spec_words("I cannot go"))
    add("contr_wont", "We won't stay", spec_words("We won't stay"))
    add("contr_lets", "Let's go", spec_words("Let us go"))
    add("contr_gonna", "I'm gonna leave", spec_words("I am going to leave"))
    add("contr_possessive", "This is John's book", spec_words("This is John's book"))
    add("contr_curly_ive", "I\u2019ve been there, you\u2019re right", spec_words("I\u2019ve been there, you\u2019re right"))
    add("contr_ll_d", "She'll come and he'd go", spec_words("She'll come and he'd go"))
    add("num_digits_target", "I have 3 apples", spec_words("I have three apples"))
    add("num_digits_heard", "I have three apples", spec_words("I have 3 apples"))
    add("num_21", "I am 21 years old", spec_words("I am twenty-one years old"))
    add("num_99", "It costs 99 dollars", spec_words("It costs ninety-nine dollars"))
    add("num_100", "There are 100 people", spec_words("There are 100 people"))
    add("num_1234", "It costs 1,234 dollars", spec_words("It costs 1,234 dollars"))
    add("num_zero", "I have 0 money", spec_words("I have zero money"))
    add("num_big_ten_digits", "The number is 1234567890", spec_words("The number is 1234567890"))
    add("hyphen_target", "I have a well-known friend", spec_words("I have a well known friend"))
    add("hyphen_heard", "I have a well known friend", spec_words("I have a well-known friend"))
    add("upper_case", "HELLO WORLD", spec_words("hello world"))
    add("punct_only_token", "Hello there", spec_words("Hello ... there"))
    add("punct_only_all", "Hello there", spec_words("... !!! ???"))
    add("long_sentence_25", "I think that we should leave early tomorrow morning because the weather will be bad and the roads will be slow "
        "so please tell everyone about the change before it gets too late tonight", spec_words(
            "I think that we should leave early tomorrow morning because the weather will be bad and the roads will be slow "
            "so please tell everyone about the change before it gets too late tonight"))
    add("long_sentence_25_noisy", "I think that we should leave early tomorrow morning because the weather will be bad and the roads "
        "will be slow so please tell everyone about the change before it gets too late tonight", spec_words(
            "I think we should leave early morning because weather will be bad and the road will be so slow please tell everyone "
            "change before it gets late tonight"))
    # empty inputs
    add("words_empty", "I would like a cup of coffee, please.", [], text="")
    add("target_empty", "", spec_words("hello"))
    add("target_punct_only", "?!...", spec_words("hello"))
    add("target_empty_words_empty", "", [], text="")
    # fluency: pace and pauses
    add("flu_slow", "I would like a cup of coffee, please.", spec_words("I would like a cup of coffee, please.", scale=3.5))
    add("flu_very_slow", "I would like a cup of coffee, please.", spec_words("I would like a cup of coffee, please.", scale=8.0))
    add("flu_fast", "I would like a cup of coffee, please.", spec_words("I would like a cup of coffee, please.", scale=0.25))
    add("flu_pause_once", "I would like a cup of coffee, please.", make_words(random.Random(5), "I would like a cup of coffee, please.".split(),
                                                                                [0.9] * 8, pause_at=3, pause=1.0))
    add("flu_pause_long", "I would like a cup of coffee, please.", make_words(random.Random(6), "I would like a cup of coffee, please.".split(),
                                                                               [0.9] * 8, pause_at=2, pause=3.5))
    add("flu_short_span", "Hello there friend", spec_words("Hello there friend", scale=0.15))
    add("flu_two_words_slow", "Thank you", spec_words("Thank you", scale=6.0))
    # canonical ordering of the marks after a letter (review, 2nd round): E + U+0315 + U+0301 is E-acute + U+0315, the letter is gone
    add("unicode_marks_reordered", "CAFE\u0315\u0301", spec_words("cafe"))
    add("unicode_marks_blocked", "ca\u0310\u0301b", spec_words("cab"))
    add("unicode_digit_group", "I paid 1,2\u06634", spec_words("I paid twelve four"))
    add("unicode_armenian_stop", "I paid 1,234\u0589", spec_words("I paid one thousand two hundred and thirty four"))
    add("unicode_greek_question", "I paid 1,234\u037e", spec_words("I paid one thousand two hundred and thirty four"))
    # 3rd round (review): U+0130 is I + U+0307 for NFKC, the marks after it are sorted and composed with the I before lower() runs
    add("unicode_dotted_I_equivalent", "YOU DRANK \u0130\u0323 COFFEE", spec_words(["you", "drank", "I\u0307\u0323", "coffee"]))
    add("unicode_dotted_I_ogonek", "AN \u0130\u0328 AND", spec_words("an and"))
    add("unicode_dotted_I_plain", "AN \u0130 AND", spec_words("an i and"))
    # conf rounding (Python round(p, 3) on exact binary values)
    for k, ps in enumerate([
        [0.0625, 0.1875, 0.3125, 0.4375],
        [0.5625, 0.6875, 0.8125, 0.9375],
        [0.0005, 0.0015, 0.1235, 0.2345],
        [0.9995, 0.4505, 0.7775, 0.6665],
        [0.12349999999999999, 0.1235000000000001, 0.5, 0.999],
    ]):
        add("round_%d" % k, "red green blue pink", spec_words([(w, p) for w, p in zip(["red", "green", "blue", "pink"], ps)]))
    return H


def random_cases(rng, sentences, n):
    """n cases: practice sentences recognised with random errors, noise in p and time stamps"""
    pool = [s for s in sentences if 3 <= len(s.split()) <= 18]
    out = []
    for k in range(n):
        target = rng.choice(pool)
        toks = target.split()
        heard, probs = [], []
        for tok in toks:
            r = rng.random()
            if r < 0.09:
                continue   # missed word
            if r < 0.24:
                alt = confuse(rng, tok.strip(".,!?\"")) or rng.choice(["the", "a", "very", "big", "red", "and"])
                heard.append(alt)
                probs.append(pround(rng, rng.uniform(0.15, 0.85)))
            else:
                heard.append(tok)
                probs.append(pround(rng, rng.choice([rng.uniform(0.55, 0.99), rng.uniform(0.3, 0.7), rng.uniform(0.85, 1.0)])))
            if rng.random() < 0.05:
                heard.append(rng.choice(["uh", "so", "really", "well", "okay"]))
                probs.append(pround(rng, rng.uniform(0.2, 0.9)))
        if not heard:
            heard, probs = ["uh"], [0.5]
        scale = rng.choice([0.6, 0.9, 1.0, 1.0, 1.2, 1.8, 2.6])
        pause_at = rng.randrange(len(heard)) if rng.random() < 0.2 else None
        words = make_words(rng, heard, probs, scale=scale, pause_at=pause_at, pause=round(rng.uniform(0.85, 2.5), 2))
        ok_prob = None
        if k % 11 == 0:
            ok_prob = rng.choice([0.2, 0.3, 0.35, 0.4, 0.5, 0.55, 0.6, 0.7])
        out.append(("rnd_%03d" % k, target, words, join_text(words), ok_prob))
    return out


def run_case(S, target, words, text, ok_prob):
    """server score_en result as a plain dict, or ({}, message) when the server refuses the target"""
    saved = S.OK_PROB
    if ok_prob is not None:
        S.OK_PROB = ok_prob
    try:
        try:
            return S.score_en(target, copy.deepcopy(words), text), None
        except S.ApiError as e:
            return {}, e.msg
    finally:
        S.OK_PROB = saved


def build_cases(S, sentences):
    rng = random.Random(SEED)
    raw = hand_cases() + random_cases(rng, sentences, 130)
    out = []
    for cid, target, words, text, ok_prob in raw:
        res, err = run_case(S, target, words, text, ok_prob)
        rec = {"id": cid, "target": target, "words": words, "text": text}
        if ok_prob is not None:
            rec["ok_prob"] = ok_prob
        rec["expect"] = res
        if err is not None:
            if err != EMPTY_TARGET_MSG:
                raise GoldenError("case %s: unexpected server error %r" % (cid, err))
            rec["error"] = err
        out.append(rec)
    return out


# ------------------------------------------------------------------------------------------------ align
def build_align(S, sentences):
    rng = random.Random(SEED + 1)
    vocab = []
    for s in sentences[:600]:
        vocab.extend(S.en_words(s))
    vocab = sorted(set(vocab))
    out = []

    def mutate(seq):
        b = []
        for w in seq:
            r = rng.random()
            if r < 0.12:
                continue
            if r < 0.30:
                b.append(confuse(rng, w) or rng.choice(vocab))
            elif r < 0.36:
                b.append(rng.choice(vocab))
                b.append(w)
            elif r < 0.40:
                b.extend([w, w])
            else:
                b.append(w)
        if rng.random() < 0.15 and len(b) > 2:
            i = rng.randrange(len(b) - 1)
            b[i], b[i + 1] = b[i + 1], b[i]
        return b

    def entry(a, b):
        pairs, inserts = S.align_seq(a, b, S.word_sim)
        return {"a": a, "b": b, "pairs": [[j, bool(e)] for j, e in pairs], "inserts": [[i, j] for i, j in inserts],
                "sim": [S.word_sim(a[k], b[k]) for k in range(min(len(a), len(b)))]}
    for k in range(240):    # a sentence and a damaged copy
        a = S.en_words(rng.choice(sentences))[:14]
        out.append(entry(a, mutate(a)))
    for k in range(50):     # unrelated sequences
        a = [rng.choice(vocab) for _ in range(rng.randint(1, 10))]
        b = [rng.choice(vocab) for _ in range(rng.randint(1, 10))]
        out.append(entry(a, b))
    for k in range(20):     # random letter strings (many repeated letters)
        letters = "abcde"
        a = ["".join(rng.choice(letters) for _ in range(rng.randint(1, 6))) for _ in range(rng.randint(0, 7))]
        b = ["".join(rng.choice(letters) for _ in range(rng.randint(1, 6))) for _ in range(rng.randint(0, 7))]
        out.append(entry(a, b))
    out.append(entry([], []))
    out.append(entry([], ["a", "b"]))
    out.append(entry(["a", "b"], []))
    out.append(entry(["a"], ["a"]))
    out.append(entry(["a", "a", "a"], ["a"]))
    out.append(entry(["a"], ["a", "a", "a"]))
    out.append(entry(["a", "b", "a", "b"], ["b", "a", "b", "a"]))
    out.append(entry(["x", "y", "z"], ["p", "q", "r", "s"]))
    # tokens of 200+ characters: SequenceMatcher's autojunk drops frequent characters of the second string
    long_a = "ab" * 130 + "c"
    long_b = "ab" * 130 + "d"
    out.append(entry([long_a, "x"], [long_b, "x"]))
    out.append(entry(["a" * 250], ["a" * 250]))
    out.append(entry(["a" * 250 + "b"], ["a" * 199 + "b" + "a" * 50]))
    out.append(entry([("abcde" * 50)], [("edcba" * 50)]))
    out.append(entry(["hello"], ["h" * 200 + "ello"]))
    out.append(entry(["h" * 200 + "ello"], ["hello"]))
    return out


# ------------------------------------------------------------------------------------------------ en_words
HARD_INPUTS = [
    # text rules
    "Hello, World!", "  leading and trailing   spaces  ", "tab\tand\nnewline", "UPPER lower MiXeD", "well-known e-mail rock-and-roll",
    "a\u2013b a\u2014b a - b", "Let\u2019s go", "\u2018quoted\u2019 words", "`backtick` words", "'single' quotes 'tis", "rock'n'roll",
    "''' only apostrophes '''", "don't can't won't shan't ain't", "cannot gonna wanna gotta gimme lemme kinda", "y'all ma'am o'clock",
    "I'm you're we've they'll he'd", "it's that's what's there's here's who's he's she's where's how's when's why's this's",
    "everything's something's nothing's someone's everyone's", "John's Mary's the dog's", "it'S IT'S", "the dogs' bones", "'s", "n't", "x'm", "x'd'd",
    "Mr. Smith, Dr. Jones & Co.", "U.S.A. and U.K.", "3.14 and 2.5", "$5.99 and 20% and #1", "1st 2nd 3rd 21st", "1,234", "1,234,567", "12,34",
    "1,2345", "1,234 apples", "1,234.50", "1,234abc", "abc1,234", "1,23", "1,234,5678", ",234", "1,", "1,,234", "a,234 1,234,", "12,345,678,901",
    "007", "00", "0000000001", "1000000000", "1234567890", "123456789", "999999999", "100", "101", "110", "999", "1000", "1001", "1100", "1101",
    "10000", "12345", "100000", "123456", "1000000", "1000001", "1001000", "1000100", "1001001", "1234567", "12345678", "500000500", "20000000",
    # Unicode
    "caf\u00e9 na\u00efve", "cafe\u0301 nai\u0308ve", "e\u0301 a\u0300 o\u0302", "\u0130stanbul", "\ufb01ne \ufb02ow \ufb03", "x\u00b2 H\u2082O 10\u00b3",
    "\u2460\u2461\u2462 \u24d0\u24d1\u24d2", "\u2160 \u2163 \u2169", "\u212a elvin", "\u017f ong", "\u339d \u2103 \u00bd \u2122", "\U0001d407\U0001d41e\U0001d425\U0001d425\U0001d428",
    "\uff28\uff25\uff2c\uff2c\uff2f\u3000\uff57\uff4f\uff52\uff4c\uff44\uff11\uff12\uff13", "\uff11\uff0c\uff12\uff13\uff14 \uff44\uff4f\uff4c\uff4c\uff41\uff52\uff53",
    "don\uff07t \uff48\uff45\uff4c\uff4c\uff4f", "a\u00a0b a\u2009b a\u3000b a\u200bb a\u2060b", "hello\u2026world", "\u201chello\u201d \u00abworld\u00bb",
    "\u3053\u3093\u306b\u3061\u306f hello 안녕", "\U0001f600 hello \U0001f44d", "1,234\u00a0apples", "1,234\u2014apples", "1,234\u00e9", "1,234\u0301",
    "H\u00e9llo w\u00f6rld \u00dfeta", "\u00e6 \u0153 \u00f8 \u00f0 \u00fe", "ABC\u0301 xyz\u0308", "i\u0307 I\u0307", "\u1e9b \u1e9e",
    "", " ", "!!!", "\u3000", "'", "-", "a", "I", "am", "\u00c0\u00c9", "\u0391\u0392 \u0410\u0411",
    # 2nd round (review): canonical ordering of marks, other-script digits and non-word characters around a thousands comma
    "CAFE\u0315\u0301", "cafe\u0315\u0301", "1,2\u06634", "1,234\u0589", "1,234\u037e", "1,23\u0664", "1,234\u0482", "1,234\u0903",
    "I\u0307\u0323", "\u0130\u0323", "AN \u0130\u0328 AND", "I\u0323\u0307", "I\u0328\u0307", "\u0130\u0307", "i\u0307",
    "xe\u0320\u0301y", "a\u0310\u0301b", "e\u05b0\u0301", "e\u0344", "I\u0307 \u0130", "1,234e\u0301", "1,234 e\u0301", "\uff45\u0301",
    "\ufb01\u0308", "e\u3099\u0301", "e\uff9e\u0301", "1,234\u0301", "1,234\u200b", "1,\u0663\u0664\u0665", "\u0663,234 1,234",
]

# Inputs where the GDScript copy is KNOWN to differ from the server: (text, why); the test asserts that each still differs.
# Empty since the 2nd round: ScoreCore uses generated tables for NFKC, canonical ordering and composition, \d and \w. One-off scans (not
# committed) found no difference to the server: every code point U+0020..U+2FFFF in four forms ("x?y", "1,234?", "e?", "CAFE?" + U+0301),
# score_en for two of them, plane 3 and U+E0000..E0FFF and the ends of the private planes, a sample of the rest, 216 marks as pairs
# (six letters) and 60,000 random strings with 2-4 marks. An entry added here must have a reason; the test asserts it still differs.
KNOWN_GAP_INPUTS = []


_UD_CACHE = {}


def table_inputs():
    """one input per entry of the generated tables, so that a changed table entry makes the GDScript test fail: every compatibility
    character, both ends of every Nd range and of every non-word range (after "1,234"), the ends of every combining class range and
    every composing mark with a letter that composes and one that does not"""
    if "d" not in _UD_CACHE:
        _UD_CACHE["d"] = unicode_data()
    d = _UD_CACHE["d"]
    out = []
    for a, b, base in d["runs"]:
        for c in range(a, b + 1):
            out.append("x" + chr(c) + "y")
    for c in sorted(d["singles"]):
        out.append("x" + chr(c) + "y")
    for a, b in d["digits"]:
        out += ["1,2" + chr(a) + "4", "1,2" + chr(b) + "4"]
    for a, b in d["nonword"]:
        out += ["1,234" + chr(a), "1,234" + chr(b)]
    for a, b, cc in d["ccc"]:
        out += ["e" + chr(a) + "\u0301", "e" + chr(b) + "\u0301", "xe" + chr(a) + chr(a) + "y"]
    for m, letters in d["compose"].items():
        no = [L for L in string.ascii_letters if L not in letters]
        out.append(letters[0] + chr(m) + "y")
        out.append(letters[-1] + chr(m) + "y")
        if no:
            out.append(no[0] + chr(m) + "y")
    for c in sorted(d["mark_decomp"]):
        out.append("e" + chr(c) + "y")
    return out


def dotted_inputs():
    """characters that NFKC or lower() changes (and the letters around them) with one and two marks of different combining classes"""
    specials = [0x49, 0x69, 0x130, 0x4B, 0x212A, 0xFB01, 0x1E9B, 0x1C6, 0x65, 0x45, 0x61, 0xC9, 0xE9, 0x1ECA, 0x12E, 0x1E2C]
    marks = [0x323, 0x328, 0x301, 0x307, 0x315, 0x345, 0x310, 0x320, 0x338, 0x344]
    out = []
    for c in specials:
        for m in marks:
            out.append("x" + chr(c) + chr(m) + "y")
            for m2 in marks:
                out.append("x" + chr(c) + chr(m) + chr(m2) + "y")
    return out


def unicode_inputs(rng):
    """seeded inputs around marks and other-script characters: letter + 2..3 marks, digit groups with other-script digits,
    "1,234" + a character from many categories"""
    marks = [0x300, 0x301, 0x302, 0x307, 0x308, 0x30A, 0x30C, 0x315, 0x316, 0x31B, 0x320, 0x323, 0x327, 0x328, 0x338, 0x345, 0x344,
             0x340, 0x5B0, 0x610, 0x64B, 0x93C, 0xE38, 0x3099, 0x1DC0, 0x20D0, 0xFF9E]
    out = []
    for k in range(120):
        letter = rng.choice("eEIaxuoOAyz")
        ms = "".join(chr(rng.choice(marks)) for _ in range(rng.choice([2, 2, 3])))
        out.append("%s%s%s" % (rng.choice(["", "caf", "1,234", "x"]), letter + ms, rng.choice(["", "y", " z", "5"])))
    digits = [0x660, 0x6F0, 0x966, 0x9E6, 0xE50, 0xFF10, 0x1D7CE, 0x1D7D8, 0x1D7E2]
    for d in digits:
        D = chr(d)
        out += ["1,23" + D, "1,2" + D + "4", "1," + D + "34", D + ",234", "1" + D + ",234", "1,234" + D, D * 3, "1," + D * 3]
    cats = [0x482, 0x589, 0x37E, 0x387, 0x58A, 0x5BE, 0x600, 0x6DD, 0x903, 0xF3A, 0x1680, 0x2028, 0x202F, 0x2E3A, 0x3002, 0x4DC0, 0xA830,
            0xE000, 0xFE0F, 0xFFFD, 0x1F600, 0xE0001, 0x10FFFF, 0x3B1, 0x416, 0x5D0, 0x627, 0x4E00, 0xAC00, 0x3042, 0x2160, 0xB2, 0xBD]
    for c in cats:
        out += ["1,234" + chr(c), "1,234" + chr(c) + "5", "x" + chr(c) + "y"]
    return out


def build_en_words(S, sentences):
    rng = random.Random(SEED + 2)
    picked = sentences[::max(1, len(sentences) // 330)][:330]
    extra = [s for s in sentences if re.search(r"['\u2019]|\d", s)]
    picked += rng.sample(extra, min(40, len(extra)))
    inputs = list(dict.fromkeys(picked))
    inputs += [str(n) for n in range(100)]
    inputs += HARD_INPUTS
    inputs += unicode_inputs(rng)
    inputs += table_inputs()
    inputs += dotted_inputs()
    inputs = list(dict.fromkeys(inputs))
    out = []
    for s in inputs:
        out.append({"in": s, "out": S.en_words(s)})
    return out


def build_known_gaps(S):
    return [{"in": s, "out": S.en_words(s), "why": why} for s, why in KNOWN_GAP_INPUTS]


# ------------------------------------------------------------------------------------------------ build / write / compare
def build():
    S = load_server()
    sentences = load_practice()
    return {
        "v": FORMAT_VERSION, "ok_prob": S.OK_PROB,
        "cases": build_cases(S, sentences),
        "align": build_align(S, sentences),
        "en_words": build_en_words(S, sentences),
        "known_gaps": build_known_gaps(S),
    }


def dumps(doc):
    """one line per entry (small diffs, readable); the same text for the same data"""
    def line(x):
        return json.dumps(x, ensure_ascii=False, separators=(",", ":"))
    parts = ['{"v":%d,"ok_prob":%s,' % (doc["v"], json.dumps(doc["ok_prob"]))]
    sections = []
    for key in ("cases", "align", "en_words", "known_gaps"):
        sections.append('"%s":[\n%s\n]' % (key, ",\n".join(line(x) for x in doc[key])))
    parts.append(",\n".join(sections))
    parts.append("}\n")
    return "\n".join(parts)


def write(doc, path=OUT_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(doc))


def compare(doc, path=OUT_PATH, core_path=CORE_PATH):
    """list of "GOLDEN_DRIFT ..." lines (empty = the file on disk is what the server gives now)"""
    drift = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        return ["GOLDEN_DRIFT missing file %s (%s)" % (path, e)]
    try:
        old = json.loads(text)
    except ValueError as e:
        return ["GOLDEN_DRIFT file is not valid JSON: %s" % e]
    new = json.loads(dumps(doc))
    for key in ("v", "ok_prob"):
        if old.get(key) != new[key]:
            drift.append("GOLDEN_DRIFT %s: file %r server %r" % (key, old.get(key), new[key]))
    for key in ("cases", "align", "en_words", "known_gaps"):
        a, b = old.get(key), new[key]
        if not isinstance(a, list):
            drift.append("GOLDEN_DRIFT section %s missing" % key)
            continue
        if len(a) != len(b):
            drift.append("GOLDEN_DRIFT section %s: file has %d entries, the server run %d" % (key, len(a), len(b)))
        for i in range(min(len(a), len(b))):
            if a[i] != b[i] or json.dumps(a[i], sort_keys=False) != json.dumps(b[i], sort_keys=False):
                label = b[i].get("id") if key == "cases" else "#%d" % i
                drift.append("GOLDEN_DRIFT %s %s" % (key, label))
    if text != dumps(doc) and not drift:
        drift.append("GOLDEN_DRIFT file text differs from the generated text (formatting only: run --write)")
    try:
        with open(core_path, "r", encoding="utf-8") as f:
            core = f.read()
        if nfkc_tables_text() not in core:
            drift.append("GOLDEN_DRIFT tables: score_core.gd does not hold the Unicode tables this tool generates (--tables prints them)")
    except OSError as e:
        drift.append("GOLDEN_DRIFT cannot read %s (%s)" % (core_path, e))
    return drift


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    mode = "write"
    for a in argv:
        if a in ("--write", "--check", "--tables", "--list"):
            mode = a[2:]
        else:
            print("usage: make_score_golden.py [--write | --check | --tables | --list]")
            return 2
    if mode == "tables":
        sys.stdout.write(nfkc_tables_text())
        return 0
    try:
        with no_network():
            doc = build()
        if mode == "list":
            for key in ("cases", "align", "en_words", "known_gaps"):
                print("%-10s %d" % (key, len(doc[key])))
            print("ok_prob != %s: %d" % (doc["ok_prob"], sum(1 for c in doc["cases"] if "ok_prob" in c)))
            return 0
        if mode == "write":
            write(doc)
            print("SCORE_GOLDEN_WRITTEN cases=%d align=%d en_words=%d known_gaps=%d" % (
                len(doc["cases"]), len(doc["align"]), len(doc["en_words"]), len(doc["known_gaps"])))
            return 0
        drift = compare(doc)
        for line in drift:
            print(line)
        if drift:
            print("SCORE_GOLDEN_FAIL drift=%d (the server changed: port it to ScoreCore, then run --write)" % len(drift))
            return 1
        print("SCORE_GOLDEN_OK cases=%d" % len(doc["cases"]))
        return 0
    except GoldenError as e:
        print("SCORE_GOLDEN_ERROR %s" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
