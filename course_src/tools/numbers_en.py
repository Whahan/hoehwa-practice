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


_PHONE = re.compile(r"^(?:\+?1[-. ]?)?(?:\(?(\d{3})\)?[-. ]?)?(\d{3})[-. ](\d{4})$")


def _phone_groups(s):
    """"555-0123" -> ["555", "0123"];  "604-555-0123" -> ["604", "555", "0123"];  else None."""
    if not isinstance(s, str):
        return None
    m = _PHONE.match(s.strip())
    if not m:
        return None
    return [g for g in m.groups() if g]


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
_TOKEN_RE = re.compile(
    r"""(?P<price>\$\s?\d[\d,]*(?:\.\d{2})?)
      | (?P<time>\b\d{1,2}:\d{2}(?:\s?[AaPp]\.?[Mm]\.?)?)
      | (?P<phone>(?<![\d])(?:\+?1[-. ])?(?:\(?\d{3}\)?[-. ])?\d{3}[-. ]\d{4}(?!\d))
      | (?P<percent>\b\d+(?:\.\d+)?\s?%)
      | (?P<ordinal>\b\d+(?:st|nd|rd|th)\b)
      | (?P<decimal>\b\d+\.\d+\b)
      | (?P<int>\b\d{1,3}(?:,\d{3})+\b|\b\d+\b)
      | (?P<abbrev>\b(?:[Mm]rs?|[Mm]s|[Dd]r|[Ss]t|[Aa]ve|[Rr]d|[Aa]pt|[Vv]s|[Ee]tc|[Bb]lvd|[Dd]ept)\.|\b[AaPp]\.[Mm]\.)
      | (?P<acronym>\b[A-Z]{2,6}\b)
      | (?P<symbol>[&+@=#/*<>~^|\\_])
    """, re.X)

SYMBOL_READ = {"&": ["and"], "+": ["plus"], "@": ["at"], "=": ["equals", "equal"], "#": ["number", "hash", "pound"]}


def norm_say(s):
    """say text -> list of lower-case words (punctuation and hyphens are word breaks, inner ' stays)."""
    t = unicodedata.normalize("NFKC", s or "").replace("’", "'").replace("‘", "'").lower()
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", t)


def _int_readings(s):
    v = _to_int(s)
    if v is None:
        return None
    out = [words(v)]
    if len(str(s).replace(",", "")) >= 2:      # digit by digit: "room 205" -> "two oh five" / "two zero five"
        out += [digits_say(str(s).replace(",", ""), zero="oh"), digits_say(str(s).replace(",", ""))]
    if 1000 <= v <= 9999 and v % 100:           # years / "twelve thirty-four"
        out.append(_under_100(v // 100) + " " + _under_100(v % 100))
    return [o for o in out if o]


def readings(token):
    """All accepted readings of one numeric token ("$5.99", "12:30", "21st", "20%", "555-0123", "205" ...), canonical first."""
    if not isinstance(token, str):
        return None
    t = token.strip()
    r = price_readings(t) if t.startswith("$") else time_readings(t)
    if r:
        return r
    ph = phone_say(t)
    if ph:
        return [ph, phone_say(t, zero="zero")]
    for fn in (percent_say, ordinal_say, decimal_say):
        r = fn(t)
        if r:
            return [r]
    return _int_readings(t)


def _segments(text):
    """text -> [("lit", [words]) | ("alt", [[words], ...]) | ("any",)] for the matcher."""
    segs, pos = [], 0
    text = unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'")
    for m in _TOKEN_RE.finditer(text):
        if m.start() > pos:
            segs.append(("lit", norm_say(text[pos:m.start()])))
        kind, tok = m.lastgroup, m.group(0)
        if kind in ("price", "time", "phone", "percent", "ordinal", "decimal", "int"):
            rd = readings(tok)
            segs.append(("alt", [norm_say(r) for r in rd]) if rd else ("any",))
        elif kind == "abbrev":
            key = tok.lower().rstrip(".")
            segs.append(("alt", [norm_say(r) for r in ABBREV[key]]) if key in ABBREV else ("any",))
        elif kind == "acronym":
            segs.append(("any",) if tok not in ACRONYM_EXEMPT else ("lit", norm_say(tok)))
        else:
            rd = SYMBOL_READ.get(tok)
            segs.append(("alt", [norm_say(r) for r in rd]) if rd else ("any",))
        pos = m.end()
    if pos < len(text):
        segs.append(("lit", norm_say(text[pos:])))
    return [s for s in segs if s[0] != "lit" or s[1]]


def say_matches(text, say):
    """True when `say` is an accepted reading of `text` (numbers must be spelled out, other words must be equal)."""
    segs = _segments(text)
    target = norm_say(say)
    memo = {}

    def go(i, j):
        key = (i, j)
        if key in memo:
            return memo[key]
        if i == len(segs):
            res = j == len(target)
        else:
            s = segs[i]
            res = False
            if s[0] == "lit":
                n = len(s[1])
                res = target[j:j + n] == s[1] and go(i + 1, j + n)
            elif s[0] == "alt":
                for alt in s[1]:
                    n = len(alt)
                    if target[j:j + n] == alt and go(i + 1, j + n):
                        res = True
                        break
            else:  # any: 1..6 words
                for n in range(1, 7):
                    if j + n <= len(target) and go(i + 1, j + n):
                        res = True
                        break
        memo[key] = res
        return res

    return go(0, 0)


def say_sentence(text):
    """Canonical reading: numbers spelled out, known abbreviations expanded; acronyms and unknown symbols stay as they are."""
    out, pos = [], 0
    text = unicodedata.normalize("NFKC", text or "").replace("’", "'").replace("‘", "'")
    for m in _TOKEN_RE.finditer(text):
        out.append(text[pos:m.start()])
        kind, tok = m.lastgroup, m.group(0)
        rd = None
        if kind in ("price", "time", "phone", "percent", "ordinal", "decimal", "int"):
            rd = readings(tok)
        elif kind == "abbrev":
            rd = ABBREV.get(tok.lower().rstrip("."))
        elif kind == "symbol":
            rd = SYMBOL_READ.get(tok)
        out.append(rd[0] if rd else tok)
        pos = m.end()
    out.append(text[pos:])
    return re.sub(r"\s+", " ", "".join(out)).strip()


def needs_say(text):
    """True when a TTS would have to guess: digits, symbols, abbreviations, acronyms."""
    if not isinstance(text, str):
        return False
    text = unicodedata.normalize("NFKC", text)
    for m in _TOKEN_RE.finditer(text):
        if m.lastgroup == "acronym" and m.group(0) in ACRONYM_EXEMPT:
            continue
        return True
    return False


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        print(a, "->", say_sentence(a))
