# -*- coding: utf-8 -*-
"""A3b: write godot/tests/fixtures/mission_golden.json from the PC rule engine (missions.check_text).

The phone's LocalMissions (godot/scripts/local/local_missions.gd) must give the same `reached` sets and the same
normalised text for these fixed inputs (INPUTS, 30 entries) and the same normalised text for NORM_CASES.
The inputs live in this file on purpose: change them here, then re-run this script.

Run (Windows, path with the venv python):
  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I <worktree>\\backend\\tools\\make_mission_golden.py

This script only CALLS missions.normalize / missions.check_text. It does not change missions.py or any other module.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
ROOT = os.path.dirname(BACKEND)
sys.path.insert(0, BACKEND)

import missions as M  # noqa: E402  (imported after sys.path is set)

OUT = os.path.join(ROOT, "godot", "tests", "fixtures", "mission_golden.json")
CONTENT = os.path.join(BACKEND, "content", "missions.json")


def fw(s):
    """full-width ASCII form of s (U+FF01..U+FF5E); spaces become the ideographic space U+3000"""
    out = []
    for c in s:
        if c == " ":
            out.append("　")
        elif "!" <= c <= "~":
            out.append(chr(ord(c) + 0xFEE0))
        else:
            out.append(c)
    return "".join(out)


RSQ = "’"   # right single quotation mark (curly apostrophe)
LSQ = "‘"
LDQ = "“"
RDQ = "”"

# (mission id, learner text); the done list is always empty here
INPUTS = [
    # cafe_order (6)
    ("cafe_order", "Hi, good morning! Can I get a large latte, please?"),
    ("cafe_order", fw("Hi, good morning")),                                    # full-width letters and spaces
    ("cafe_order", "I" + RSQ + "d like a medium coffee, to go please."),        # curly apostrophe
    ("cafe_order", "HELLO,   I'M   HERE   FOR   A   SMALL   TEA!!!"),            # upper case, repeated spaces
    ("cafe_order", LDQ + "Yes, that" + RSQ + "s all. Thank you so much!" + RDQ),  # curly double quotes
    ("cafe_order", "a " * 160 + "good morning"),                                 # the greeting is past char 300
    # self_intro (5)
    ("self_intro", "My name is Jun and I'm from Busan."),
    ("self_intro", "Nice to meet you! I" + RSQ + "m Minji."),
    ("self_intro", "I like hiking and reading books, especially on weekends."),
    ("self_intro", "What about you? Where are you from?"),
    ("self_intro", "안녕하세요 저는 민지예요"),  # Korean only: nothing matches
    # hotel_checkin (4)
    ("hotel_checkin", "Yes, I have a reservation under the name Kim."),
    ("hotel_checkin", "I booked a room for two nights, a king bed please."),
    ("hotel_checkin", "Is breakfast included? Is there wifi in the room?"),
    ("hotel_checkin", "Could I check out at ten, and I" + RSQ + "ll pay by card?"),
    # ask_directions (4)
    ("ask_directions", "Excuse me, where is the train station?"),
    ("ask_directions", "How far is it from here? Is it far?"),
    ("ask_directions", "So I turn left at the bank, right?"),
    ("ask_directions", fw("Thank you so much, bye")),
    # restaurant (3)
    ("restaurant", "A table for two please."),
    ("restaurant", "What do you recommend? Any specials today?"),
    ("restaurant", "I" + RSQ + "ll have the salmon, please."),
    # pharmacy_doctor (3)
    ("pharmacy_doctor", "I have a headache and I feel dizzy."),
    ("pharmacy_doctor", "It started two days ago and it" + RSQ + "s getting worse."),
    ("pharmacy_doctor", "Should I take one pill twice a day?"),
    # return_item (3)
    ("return_item", "It" + RSQ + "s too small for me, and it has a hole."),
    ("return_item", "I have the receipt right here."),
    ("return_item", "Can I exchange it or get a refund?"),
    # job_interview (2)
    ("job_interview", "My name is Min-ho and I work in design."),
    ("job_interview", "I'm a designer with three years of experience."),
]

# normalize() cases. The replacement table of local_missions.gd must give the same string as missions.normalize.
# (Decomposed accents such as "e" + U+0301 are NOT here: NFKC composes them, the phone table cannot. Known gap.)
NORM_CASES = [
    fw("Hello, World!"),
    "I" + RSQ + "m here, " + LSQ + "ok" + LSQ + " " + LDQ + "yes" + RDQ + " ` ´ ʼ ′ ＇",
    "a″b",                                          # double prime: NFKC gives two primes
    "x—y–z−wーv－u",              # dashes and the katakana long vowel mark
    "ﬁne ﬂow ﬃce ﬀ ﬄ ﬅ",   # ligatures
    "x² y⁴ z₀ ①⑩ ⑧",       # superscript, subscript, circled digits
    "ⒶⓐⓩⓏ",                          # circled letters
    "½ and ¼ ¾",                          # fractions
    "™ ª º ⁱ ⁿ",                # trade mark, ordinals, i and n superscripts
    "ｱｲ",                                      # half-width katakana: nothing ASCII
    "안녕 hello 세상",                   # Korean around an English word
    "tab\tnew\nline   spaces",
    "   ",
    "",
    "Don" + RSQ + "t STOP",
    "a" * 310 + "bcdefgh",                               # cut at 300 characters before matching
    "Kelvin K",
    "don＇t",
]


# Code points of the replacement table (local_missions.gd NFKC_MAP and the range rules) plus all printable ASCII.
# The phone must give exactly the PC normalize result for each of them, one character at a time.
TABLE_SCOPE = (
    list(range(0x20, 0x7F))
    + [0x3000, 0x0060, 0x00B4, 0x2018, 0x2019, 0x02BC, 0x2032, 0x2033]
    + list(range(0x2010, 0x2016)) + [0x2212, 0x30FC]
    + [0x00AA, 0x00BA, 0x2071, 0x207F, 0x00B9, 0x00B2, 0x00B3, 0x2070]
    + list(range(0x2074, 0x207A)) + list(range(0x2080, 0x208A))
    + list(range(0x2460, 0x246A)) + [0x00BC, 0x00BD, 0x00BE, 0x2122]
    + list(range(0xFB00, 0xFB07)) + list(range(0x24B6, 0x24EA))
    + list(range(0xFF01, 0xFF5F))
)


def pc_ascii_producers():
    """PC normalize output for every single code point in the scanned blocks that gives ASCII (informational)"""
    found = []
    for a, b in ((0x80, 0x10000), (0x1D400, 0x1D800), (0x1F100, 0x1F200)):
        for cp in range(a, b):
            if 0xD800 <= cp <= 0xDFFF:
                continue
            n = M.normalize(chr(cp))
            if n != "":
                found.append(cp)
    return found


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    assert len(INPUTS) == 30, len(INPUTS)
    entries = []
    for mission_id, text in INPUTS:
        res = M.check_text("en", mission_id, text, [])
        entries.append({
            "mission_id": mission_id,
            "text": text,
            "norm": M.normalize(text),
            "reached": list(res["new"]),
        })
    golden = {
        "v": 1,
        "source": "backend/content/missions.json",
        "source_sha256": sha256_file(CONTENT),
        "generator": "backend/tools/make_mission_golden.py",
        "entries": entries,
        "norm_cases": [{"text": t, "norm": M.normalize(t)} for t in NORM_CASES],
        "table_cases": [[cp, M.normalize(chr(cp))] for cp in TABLE_SCOPE],
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(golden, f, ensure_ascii=False, indent=1)
        f.write("\n")
    covered = {}
    for e in entries:
        covered.setdefault(e["mission_id"], 0)
        if e["reached"]:
            covered[e["mission_id"]] += 1
    print("wrote", OUT)
    print("entries", len(entries), "non-empty reached per mission", covered)
    print("norm_cases", len(NORM_CASES), "table_cases", len(TABLE_SCOPE))
    producers = pc_ascii_producers()
    outside = [cp for cp in producers if cp not in set(TABLE_SCOPE)]
    print("PC ASCII producers in scanned blocks: %d, in table scope: %d, outside (known gap): %d"
          % (len(producers), len(producers) - len(outside), len(outside)))


if __name__ == "__main__":
    main()
