# -*- coding: utf-8 -*-
"""English readings of numbers, prices, times, ordinals, phone numbers (stdlib only, offline).

The course never lets the TTS guess how to read "$5.99" or "12:30": the manuscript carries a `say` text and the
linter (check_course.py, code NUM_SAY) compares it with what this module produces. Every public function returns None
for input it cannot read (empty, letters, negative, two decimal points ...) instead of raising.

  words(n)              1234 -> "one thousand two hundred thirty-four"      (0 .. 999,999,999,999)
  price_say("5.99")     "five ninety-nine"      price_say("$20") -> "twenty dollars"
  time_say("12:30")     "twelve thirty"         time_say("9:05") -> "nine oh five"
  ordinal_say(21)       "twenty-first"          ordinal_say("3rd") -> "third"
  digits_say("0123")    "zero one two three"    phone_say("555-0123") -> "five five five, oh one two three"
  percent_say("20%")    "twenty percent"        decimal_say("3.5") -> "three point five"
  readings(token)       all accepted readings of one token (first = canonical), or None
  say_sentence(text)    canonical reading of a whole sentence (abbreviations / acronyms are left as they are)
  needs_say(text)       True when the sentence has digits, symbols, abbreviations or acronyms (a `say` is required)
  say_matches(text, say) True when `say` is an accepted reading of `text`
"""
import re
import unicodedata

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
SCALES = [(10 ** 9, "billion"), (10 ** 6, "million"), (1000, "thousand")]
MAX_N = 999_999_999_999

ORD_IRREGULAR = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                 "nine": "ninth", "twelve": "twelfth"}

ABBREV = {  # abbreviation (lower, without the final dot) -> accepted readings
    "mr": ["mister"], "mrs": ["missus", "misses"], "ms": ["miz", "ms", "mizz"], "dr": ["doctor"],
    "st": ["street", "saint"], "ave": ["avenue"], "rd": ["road"], "apt": ["apartment"],
    "vs": ["versus"], "etc": ["et cetera", "etcetera"], "a.m": ["a m", "am"], "p.m": ["p m", "pm"],
    "blvd": ["boulevard"], "dept": ["department"],
}
ACRONYM_EXEMPT = {"OK"}


def _to_int(n):
    """int / digit string ("1,234" too) -> int, anything else (bool, float, negative, junk) -> None."""
    if isinstance(n, bool):
        return None
    if isinstance(n, int):
        return n if n >= 0 else None
    if isinstance(n, str):
        s = n.strip()
        if re.fullmatch(r"\d{1,3}(,\d{3})+|\d+", s):
            return int(s.replace(",", ""))
    return None


def _under_100(n):
    if n < 20:
        return ONES[n]
    t, o = divmod(n, 10)
    return TENS[t] + ("-" + ONES[o] if o else "")


def _under_1000(n):
    h, r = divmod(n, 100)
    parts = []
    if h:
        parts.append(ONES[h] + " hundred")
    if r:
        parts.append(_under_100(r))
    return " ".join(parts)


def words(n):
    v = _to_int(n)
    if v is None or v > MAX_N:
        return None
    if v == 0:
        return "zero"
    parts = []
    for size, name in SCALES:
        q, v = divmod(v, size)
        if q:
            parts.append(_under_1000(q) + " " + name)
    if v:
        parts.append(_under_1000(v))
    return " ".join(parts)


def ordinal_say(n):
    suffix = None
    if isinstance(n, str):
        m = re.fullmatch(r"\s*(\d+)(st|nd|rd|th)\s*", n.lower())
        if not m:
            return None
        v, suffix = int(m.group(1)), m.group(2)
    else:
        v = _to_int(n)
    if v is None:
        return None
    w = words(v)
    if w is None:
        return None
    if suffix is not None:  # "21th" is not a reading we accept
        last2 = v % 100
        want = "th" if 10 <= last2 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(v % 10, "th")
        if suffix != want:
            return None
    parts = re.split(r"([ -])", w)
    last = parts[-1]
    if last in ORD_IRREGULAR:
        last = ORD_IRREGULAR[last]
    elif last.endswith("y"):
        last = last[:-1] + "ieth"
    else:
        last = last + "th"
    return "".join(parts[:-1]) + last


def digits_say(s, zero="zero"):
    if not isinstance(s, str) or not re.fullmatch(r"\d+", s.strip()):
        return None
    return " ".join(zero if c == "0" else ONES[int(c)] for c in s.strip())


_PHONE = re.compile(r"^(?:(\+?1)[-. ]?)?(?:\(?(\d{3})\)?[-. ]?)?(\d{3})[-. ](\d{4})$")


def _phone_groups(s):
    """"555-0123" -> ["555", "0123"];  "604-555-0123" -> ["604", "555", "0123"];  else None."""
    if not isinstance(s, str):
        return None
    m = _PHONE.match(s.strip())
    if not m:
        return None
    return [g.lstrip("+") for g in m.groups() if g]


def phone_say(s, zero="oh"):
    g = _phone_groups(s)
    if g is None:
        return None
    return ", ".join(digits_say(x, zero=zero) for x in g)


def percent_say(s):
    if not isinstance(s, str):
        return None
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*%\s*", s)
    if not m:
        return None
    base = decimal_say(m.group(1)) if "." in m.group(1) else words(m.group(1))
    return None if base is None else base + " percent"


def decimal_say(s):
    if not isinstance(s, str):
        return None
    m = re.fullmatch(r"\s*(\d+)\.(\d+)\s*", s)
    if not m:
        return None
    ip = words(m.group(1))
    if ip is None:
        return None
    return ip + " point " + digits_say(m.group(2))


_PRICE = re.compile(r"^\s*\$?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?\s*$")


def _price_parts(text):
    if not isinstance(text, str):
        return None
    m = _PRICE.match(text)
    if not m:
        return None
    d = int(m.group(1).replace(",", ""))
    c = int(m.group(2)) if m.group(2) is not None else None
    if words(d) is None:
        return None
    return d, c


def _dollars(d):
    return words(d) + (" dollar" if d == 1 else " dollars")


def _cents(c):
    return words(c) + (" cent" if c == 1 else " cents")


def price_readings(text):
    p = _price_parts(text)
    if p is None:
        return None
    d, c = p
    if c is None or c == 0:
        return [_dollars(d)]
    if d == 0:
        return [_cents(c)]
    short = words(d) + " " + (words(c) if c >= 10 else "oh " + words(c))
    full = _dollars(d) + " and " + _cents(c)
    return [full] if d >= 100 else [short, full]


def price_say(text):
    r = price_readings(text)
    return None if r is None else r[0]


_TIME = re.compile(r"^\s*(\d{1,2}):(\d{2})\s*(?:([ap])\.?m\.?)?\s*$", re.I)


def time_readings(text):
    if not isinstance(text, str):
        return None
    m = _TIME.match(text)
    if not m:
        return None
    h, mi, ap = int(m.group(1)), int(m.group(2)), m.group(3)
    if mi > 59 or h > 23 or (ap and not 1 <= h <= 12):
        return None
    hw = ONES[h] if h < 20 else words(h)
    if mi == 0:
        base = hw + " o'clock"
    elif mi < 10:
        base = hw + " oh " + ONES[mi]
    else:
        base = hw + " " + words(mi)
    if not ap:
        return [base]
    letter = ap.lower()
    return [base + " " + letter + " m", base + " " + letter + "m"]


def time_say(text):
    r = time_readings(text)
    return None if r is None else r[0]


# ------------------------------------------------------------------------------------------------ sentences
# What a reading may look like:
#  * a plain integer is read as a number (25 = "twenty-five"); never digit by digit ("two five" is rejected), 911 = "nine one one" only
#  * digit by digit ("three oh five"), two digits at a time ("twelve oh five", "nineteen twenty") and the plain number are all
#    accepted for codes: a number with 3+ digits when an identifier word (room, apartment, apt, unit, suite, flight, gate, bus,
#    route, platform, code, pin, number, # / No. ...) is among the 4 words before it in the same sentence with nothing but one
#    be-verb between (room is 305; "the bus has 100 seats" and "No, 305 people" are no code); 4+ digit numbers that are
#    no year (1000-2099); a leading zero is always read digit by digit
#  * years 1000-2099 also read as "nineteen ninety-nine", "twenty twenty-four", "twenty oh five", "two thousand and five";
#    "twenty five" for 2005 and "nineteen five" for 1905 are wrong
#  * -5 = "minus five" / "negative five", 5 deg C = "five degrees Celsius" or "five degrees", 5-10 = "five to ten" / "five through ten"
#  * 5 pm = "five p m" / "five pm"
#  * an all-capital word is an ordinary word first (STOP = stop); an acronym registered in the lexicon (en in capitals) is read
#    as that entry's `say` (its letters a t m / ay tee em are letter words, any other reading is the acronym's own word); an
#    unregistered one only letter by letter (A B C, or ay bee see)
_TOKEN_RE = re.compile(
    r"""(?P<price>\$\s?\d[\d,]*(?:\.\d{2})?)
      | (?P<time>\b\d{1,2}:\d{2}(?:\s?[AaPp]\.?[Mm]\.?)?)
      | (?P<hourap>\b\d{1,2}\s?[AaPp]\.?[Mm]\.?(?![A-Za-z]))
      | (?P<phone>(?<![\d])(?:\+?1[-. ])?(?:\(?\d{3}\)?[-. ])?\d{3}[-. ]\d{4}(?!\d))
      | (?P<date>\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b)
      | (?P<temp>(?<![\w.])-?\d+(?:\.\d+)?\s?°\s?[CcFf]?(?![A-Za-z]))
      | (?P<percent>(?<![\w.])-?\d+(?:\.\d+)?\s?%)
      | (?P<ordinal>\b\d+(?:st|nd|rd|th)\b)
      | (?P<range>\b\d+\s?[-–—]\s?\d+\b)
      | (?P<decimal>(?<![\w.])-?\d+\.\d+\b)
      | (?P<alnum>\b\d+[A-Za-z][A-Za-z\d]*\b|\b[A-Za-z]+\d[A-Za-z\d]*\b)
      | (?P<int>(?<![\w.])-?(?:\d{1,3}(?:,\d{3})+|\d+)\b)
      | (?P<abbrev>\b(?:[Mm]rs?|[Mm]s|[Dd]r|[Ss]t|[Aa]ve|[Rr]d|[Aa]pt|[Vv]s|[Ee]tc|[Bb]lvd|[Dd]ept)\.|\b[AaPp]\.[Mm]\.)
      | (?P<acronym>\b[A-Z]{2,6}\b)
      | (?P<symbol>[&+@=#/*<>~^|\\_])
    """, re.X)
_NUMERIC_KINDS = ("price", "time", "hourap", "phone", "percent", "ordinal", "decimal", "int", "temp", "range")

SYMBOL_READ = {"&": ["and"], "+": ["plus"], "@": ["at"], "=": ["equals", "equal"], "#": ["number", "hash", "pound"]}
ID_WORDS = {"room", "rm", "apartment", "apt", "unit", "suite", "flight", "gate", "bus", "route", "code", "pin", "extension", "ext",
            "number", "id", "zip", "postal", "line", "platform", "locker", "seat", "table", "bay", "box", "channel", "highway", "hwy"}
NEG = ("minus ", "negative ")
# between an identifier word and its number only a be-verb (once), "not" and further identifier words may stand: "room is 305",
# "room number is 305"; "bus has 100 seats" / "the 305 people" are no identifier context
BE_VERBS = {"is", "are", "am", "was", "were", "be", "isn't", "aren't", "wasn't", "weren't", "ain't"}
# a pronunciation hint of a word's `say` that is the same word in another spelling (OK -> okay)
HINT_ALIASES = {"ok": ["okay"]}
LETTER_NAMES = {
    "a": [["a"], ["ay"]], "b": [["b"], ["bee"]], "c": [["c"], ["see"], ["cee"]], "d": [["d"], ["dee"]], "e": [["e"], ["ee"]],
    "f": [["f"], ["eff"]], "g": [["g"], ["gee"]], "h": [["h"], ["aitch"], ["haitch"]], "i": [["i"], ["eye"]], "j": [["j"], ["jay"]],
    "k": [["k"], ["kay"]], "l": [["l"], ["el"], ["ell"]], "m": [["m"], ["em"]], "n": [["n"], ["en"]], "o": [["o"], ["oh"]],
    "p": [["p"], ["pee"]], "q": [["q"], ["cue"], ["queue"]], "r": [["r"], ["ar"], ["are"]], "s": [["s"], ["ess"]], "t": [["t"], ["tee"]],
    "u": [["u"], ["you"], ["yoo"]], "v": [["v"], ["vee"]], "w": [["w"], ["double", "you"], ["double", "u"]], "x": [["x"], ["ex"]],
    "y": [["y"], ["why"], ["wye"]], "z": [["z"], ["zed"], ["zee"]],
}


def norm_say(s):
    """say text -> list of lower-case words (punctuation and hyphens are word breaks, inner ' stays)."""
    t = unicodedata.normalize("NFKC", s or "").replace("’", "'").replace("‘", "'").lower()
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", t)


def _year_readings(n):
    """1000-2099 read as a year (besides the plain number reading)."""
    h, r = divmod(n, 100)
    out = []
    if n == 2000:
        return out
    if 2001 <= n <= 2099:
        out.append("two thousand and " + words(r))
    if r == 0:
        if n % 1000:
            out.append(words(h) + " hundred")
    elif r < 10:
        out.append(words(h) + " oh " + ONES[r])
    else:
        out.append(words(h) + " " + words(r))
    return out


def _pair_readings(core):
    """4 digits two at a time: 1205 = "twelve oh five", 1920 = "nineteen twenty", 2100 = "twenty-one hundred"."""
    if len(core) != 4 or core[0] == "0":
        return []
    a, b = int(core[:2]), core[2:]
    if b == "00":
        return [words(a) + " hundred"]
    if b[0] == "0":
        return [words(a) + " oh " + ONES[int(b[1])]]
    return [words(a) + " " + words(int(b))]


def _int_readings(s, prev=""):
    """all accepted readings of an integer token ("25", "-5", "1,234", "2005", "007", "911") in its context; `prev` is
    an identifier word when one stands in the 4 words before the number (room 305, code 4821)."""
    s = str(s).strip()
    neg = s.startswith("-")
    core = s.lstrip("-").replace(",", "")
    if not core.isdigit():
        return None
    n = int(core)
    if core == "911":
        base = ["nine one one"]
    elif len(core) > 1 and core[0] == "0":
        base = [digits_say(core, zero="oh"), digits_say(core)]
    else:
        w = words(n)
        if w is None:
            return None
        base = [w]
        if not neg and "," not in s:
            is_year = 1000 <= n <= 2099
            idctx = prev in ID_WORDS
            digits = [digits_say(core, zero="oh"), digits_say(core)]
            if is_year:
                base += _year_readings(n)
            if idctx and len(core) >= 3:
                base = digits + _pair_readings(core) + base            # canonical: digit by digit / two at a time
            elif len(core) >= 4 and not is_year:
                base += digits
    base = [b for b in base if b]
    return [p + b for p in NEG for b in base] if neg else base


def _number_readings(num):
    """plain number readings (no digit-by-digit) of "5", "-5", "3.5" for temperatures and ranges."""
    neg = num.startswith("-")
    core = num.lstrip("-")
    r = [decimal_say(core)] if "." in core else [words(core)]
    r = [x for x in r if x]
    return [p + x for p in NEG for x in r] if neg else r


def _temp_readings(tok):
    m = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s?°\s?([CcFf]?)\s*", tok)
    if not m:
        return None
    base = _number_readings(m.group(1))
    if not base:
        return None
    unit = {"c": " celsius", "f": " fahrenheit"}.get(m.group(2).lower())
    out = [b + " degrees" + unit for b in base] if unit else []
    return out + [b + " degrees" for b in base]


def _range_readings(tok):
    m = re.fullmatch(r"\s*(\d+)\s?[-–—]\s?(\d+)\s*", tok)
    if not m:
        return None
    ra, rb = _int_readings(m.group(1)), _int_readings(m.group(2))
    if not ra or not rb:
        return None
    digits_only = r"(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine) ?)+"
    ra = [x for x in ra if not re.fullmatch(digits_only, x) or len(ra) == 1]
    rb = [x for x in rb if not re.fullmatch(digits_only, x) or len(rb) == 1]
    return [a + sep + b for a in ra for b in rb for sep in (" to ", " through ")]


def _hour_ampm_readings(tok):
    m = re.fullmatch(r"\s*(\d{1,2})\s?([AaPp])\.?[Mm]\.?\s*", tok)
    if not m or not 1 <= int(m.group(1)) <= 12:
        return None
    hw, ap = ONES[int(m.group(1))] if int(m.group(1)) < 20 else words(int(m.group(1))), m.group(2).lower()
    return [hw + " " + ap + " m", hw + " " + ap + "m"]


def readings(token, prev=""):
    """All accepted readings of one numeric token ("$5.99", "12:30", "5 pm", "21st", "20%", "555-0123", "205", "-5", "5-10" ...),
    canonical first. `prev` = an identifier word when one precedes the number (room 205 may be read digit by digit)."""
    if not isinstance(token, str):
        return None
    t = unicodedata.normalize("NFKC", token).strip().replace("−", "-")
    r = price_readings(t) if t.startswith("$") else time_readings(t)
    if r:
        return r
    r = _hour_ampm_readings(t)
    if r:
        return r
    ph = phone_say(t)
    if ph:
        return [ph, phone_say(t, zero="zero")]
    r = _temp_readings(t)
    if r:
        return r
    pm = re.fullmatch(r"(-?)(\d+(?:\.\d+)?)\s?%", t)
    if pm:
        base = percent_say(pm.group(2) + "%")
        return None if base is None else ([p + base for p in NEG] if pm.group(1) else [base])
    r = ordinal_say(t) if re.fullmatch(r"\d+(?:st|nd|rd|th)", t.lower()) else None
    if r:
        return [r]
    r = _range_readings(t)
    if r:
        return r
    if re.fullmatch(r"-?\d+\.\d+", t):
        return _number_readings(t)
    return _int_readings(t, prev)


def _head_sentence(head):
    """the part of `head` after the last sentence end ("No." in "Room No. 305" is an abbreviation, no sentence end)."""
    start = 0
    for m in re.finditer(r"[.?!]\s", head):
        if re.search(r"(?<![A-Za-z])[Nn]o$", head[:m.start()]):
            continue
        start = m.end()
    return head[start:]


def _id_context(text, pos):
    """The identifier word standing in the 4 words before `pos` in the same sentence ("" when there is none). Only "#" and
    "No." count for the word no ("No, 305 people" is no identifier); between the identifier word and the number only one
    be-verb, "not" and other identifier words may stand (room is 305, room number is 305; "bus has 100 seats" is none)."""
    toks = re.findall(r"(?<![A-Za-z])[Nn]o\.|[A-Za-z][A-Za-z']*|#", _head_sentence(text[:pos]))[-4:]
    for i in range(len(toks) - 1, -1, -1):
        t = toks[i]
        low = t.lower()
        if t == "#" or low == "no.":
            return "number"
        if low in ID_WORDS:
            be = 0
            for b in toks[i + 1:]:
                bl = b.lower()
                if bl in BE_VERBS:
                    be += 1
                    if be > 1:
                        return ""
                elif bl != "not" and bl not in ID_WORDS and b != "#":
                    return ""
            return low
    return ""


def _norm_text(text):
    return unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'").replace("−", "-")


def is_letter_reading(token, words):
    """True when the words spell `token` letter by letter (a t m / ay tee em / a tee m): every letter by one of its names."""
    letters = [c for c in token.lower() if c.isalpha()]
    words = list(words)

    def spell(k, p):
        if k == len(letters):
            return p == len(words)
        for opt in LETTER_NAMES.get(letters[k], ()):
            if words[p:p + len(opt)] == opt and spell(k + 1, p + len(opt)):
                return True
        return False

    return bool(letters) and spell(0, 0)


def _segments(text, acronyms=None, is_word=None):
    """text -> [(kind, data, label)]: kind lit (words) | alt (list of word lists) | any | letters (an acronym token).
    label = where the say words come from: lit, number, abbrev, symbol, acr, any, letters."""
    segs, pos = [], 0
    text = _norm_text(text)
    for m in _TOKEN_RE.finditer(text):
        if m.start() > pos:
            segs.append(("lit", norm_say(text[pos:m.start()]), "lit"))
        kind, tok = m.lastgroup, m.group(0)
        if kind in _NUMERIC_KINDS:
            rd = readings(tok, _id_context(text, m.start()))
            segs.append(("alt", [norm_say(r) for r in rd], "number") if rd else ("any", None, "any"))
        elif kind == "abbrev":
            key = tok.lower().rstrip(".")
            segs.append(("alt", [norm_say(r) for r in ABBREV[key]], "abbrev") if key in ABBREV else ("any", None, "any"))
        elif kind == "acronym":
            if tok in ACRONYM_EXEMPT:
                segs.append(("lit", norm_say(tok), "lit"))
            elif acronyms and acronyms.get(tok):
                # a registered acronym: the entry's say; its letters (a t m / ay tee em) are letter words like those of an
                # unregistered acronym, any other reading (SIN -> sin) is the acronym's own word
                segs.append(("alt", acronyms[tok], ["letters" if is_letter_reading(tok, alt) else "acr" for alt in acronyms[tok]]))
            elif is_word is not None and is_word(tok.lower()):
                segs.append(("lit", norm_say(tok), "lit"))              # STOP is the word stop
            else:
                segs.append(("letters", tok, "letters"))
        elif kind == "alnum":                       # 3D = three + d, 2x = two + x: digits as numbers, letters letter by letter
            parts = re.findall(r"\d+|[A-Za-z]+", tok)
            ok = True
            sub = []
            for part in parts:
                if part.isdigit():
                    rd = readings(part, "")
                    if not rd:
                        ok = False
                        break
                    sub.append(("alt", [norm_say(r) for r in rd], "number"))
                else:
                    sub.append(("letters", part, "letters"))
            segs.extend(sub if ok else [("any", None, "any")])
        elif kind == "date":
            segs.append(("any", None, "any"))
        else:
            rd = SYMBOL_READ.get(tok)
            segs.append(("alt", [norm_say(r) for r in rd], "symbol") if rd else ("any", None, "any"))
        pos = m.end()
    if pos < len(text):
        segs.append(("lit", norm_say(text[pos:]), "lit"))
    return [s for s in segs if s[0] != "lit" or s[1]]


def align(text, say, acronyms=None, is_word=None):
    """Match `say` against the readings of `text`. -> None when it does not match, else one label per say word
    (lit, number, abbrev, symbol, acr, any, letters): where that word of the reading comes from."""
    segs = _segments(text, acronyms, is_word)
    target = norm_say(say)
    memo = {}

    def go(i, j):
        key = (i, j)
        if key in memo:
            return memo[key]
        res = None
        if i == len(segs):
            res = [] if j == len(target) else None
        else:
            kind, data, label = segs[i]
            if kind == "lit":
                n = len(data)
                if target[j:j + n] == data:
                    t = go(i + 1, j + n)
                    res = None if t is None else [label] * n + t
            elif kind == "alt":
                for k, alt in enumerate(data):
                    n = len(alt)
                    if target[j:j + n] == alt:
                        t = go(i + 1, j + n)
                        if t is not None:
                            res = [label[k] if isinstance(label, list) else label] * n + t
                            break
            elif kind == "letters":
                def spell(k, p):
                    if k == len(data):
                        return go(i + 1, p)
                    for opt in LETTER_NAMES[data[k].lower()]:
                        n = len(opt)
                        if target[p:p + n] == opt:
                            t = spell(k + 1, p + n)
                            if t is not None:
                                return [label] * n + t
                    return None
                res = spell(0, j)
            else:  # any: 1..6 words
                for n in range(1, 7):
                    if j + n <= len(target):
                        t = go(i + 1, j + n)
                        if t is not None:
                            res = ["any"] * n + t
                            break
        memo[key] = res
        return res

    return go(0, 0)


def say_matches(text, say, acronyms=None, is_word=None):
    """True when `say` is an accepted reading of `text` (numbers must be spelled out, other words must be equal,
    an unregistered acronym is spelled letter by letter)."""
    return align(text, say, acronyms, is_word) is not None


def spans(text, acronyms=False):
    """[(start, end)] of every number / symbol / abbreviation match in NFKC-normalised text (those parts are read through
    `say`, not looked up in the lexicon); acronym matches only with acronyms=True."""
    text = _norm_text(text)
    return [(m.start(), m.end()) for m in _TOKEN_RE.finditer(text)
            if m.lastgroup != "acronym" or (acronyms and m.group(0) not in ACRONYM_EXEMPT)]


def plain_text(text):
    """text without its number / symbol / abbreviation parts. Capital words stay: they are looked up like any word."""
    text = _norm_text(text)
    out, pos = [], 0
    for a, b in spans(text):
        out.append(text[pos:a] + " ")
        pos = b
    out.append(text[pos:])
    return "".join(out)


def acronym_tokens(text):
    return [m.group(0) for m in _TOKEN_RE.finditer(_norm_text(text)) if m.lastgroup == "acronym" and m.group(0) not in ACRONYM_EXEMPT]


def say_sentence(text):
    """Canonical reading: numbers spelled out, known abbreviations expanded; acronyms and unknown symbols stay as they are."""
    out, pos = [], 0
    text = _norm_text(text)
    for m in _TOKEN_RE.finditer(text):
        out.append(text[pos:m.start()])
        kind, tok = m.lastgroup, m.group(0)
        rd = None
        if kind in _NUMERIC_KINDS:
            rd = readings(tok, _id_context(text, m.start()))
        elif kind == "abbrev":
            rd = ABBREV.get(tok.lower().rstrip("."))
        elif kind == "symbol":
            rd = SYMBOL_READ.get(tok)
        out.append(rd[0] if rd else tok)
        pos = m.end()
    out.append(text[pos:])
    return re.sub(r"\s+", " ", "".join(out)).strip()


def has_numeric(text):
    """True when the text has a number token (price, time, phone, temperature, percent, ordinal, range, decimal, integer)."""
    if not isinstance(text, str):
        return False
    return any(m.lastgroup in _NUMERIC_KINDS for m in _TOKEN_RE.finditer(_norm_text(text)))


def needs_say(text, acronyms=None, is_word=None):
    """True when a TTS would have to guess: digits, symbols, abbreviations, tokens like 3D or 2x, and acronyms. A capital word
    that is an ordinary word (is_word) needs no say; without `is_word` every acronym needs one."""
    if not isinstance(text, str):
        return False
    if spans(text):
        return True
    for tok in acronym_tokens(text):
        if acronyms and tok in acronyms:
            return True
        if is_word is None or not is_word(tok.lower()):
            return True
    return False


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        print(a, "->", say_sentence(a))
