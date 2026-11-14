# -*- coding: utf-8 -*-
"""A3b: write godot/tests/fixtures/mission_golden.json from the PC rule engine (missions.check_text).

The phone's LocalMissions (godot/scripts/local/local_missions.gd) must give the same `reached` sets and the same
normalised text for these fixed inputs (INPUTS, 30 English entries; JA_INPUTS, 24 or more Japanese entries) and the same
normalised text for NORM_CASES. Japanese (v1.7.0 B3): JA_NORM_CASES, JA_TABLE_SCOPE (one code point at a time),
JA_KNOWN_GAPS (NFKC results the phone does NOT build; the test asserts they still differ) and JA_RANDOM_N seeded random strings
are written under the "ja_*" keys, for MissionText.norm_ja (godot/scripts/core/mission_text.gd) = missions.normalize_ja.
The inputs live in this file on purpose: change them here, then re-run this script.

Run (Windows, path with the venv python):
  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I <worktree>\\backend\\tools\\make_mission_golden.py

This script only CALLS missions.normalize / missions.check_text. It does not change missions.py or any other module.
"""
import hashlib
import json
import os
import random
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


# ---------------------------------------------------------------------------------------------------------------------
# Japanese (v1.7.0 B3). The phone's MissionText.norm_ja = missions.normalize_ja.
# ---------------------------------------------------------------------------------------------------------------------
# half-width katakana U+FF66..FF9D written out, then the two voicing marks
HW_KATA = "ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
HW_DAKU = "ﾞ"
HW_HANDAKU = "ﾟ"

# (mission id, learner text); the done list is always empty here. 8 missions x 3 or more.
JA_INPUTS = [
    # ja_konbini
    ("ja_konbini", "すみません、おにぎりはどこにありますか"),
    ("ja_konbini", "コレヲクダサイ"),                                          # katakana only: folds to hiragana
    ("ja_konbini", "ｶｰﾄﾞﾃﾞ ﾊﾗｲﾏｽ"),                                         # half-width katakana with voicing marks
    ("ja_konbini", "あたためてください。ふくろもおねがいします！"),             # punctuation is deleted
    ("ja_konbini", "ありがとうございました" + "　" * 3 + "ＯＫ"),                # ideographic spaces, full-width letters
    # ja_ramen
    ("ja_ramen", "ふたりです。カウンターでもいいですか"),
    ("ja_ramen", "とんこつラーメンをひとつ、めんはかためでおねがいします"),
    ("ja_ramen", "ﾗｰﾒﾝ ｵﾈｶﾞｲｼﾏｽ"),                                         # half-width katakana, ｶﾞ is a composed voiced kana
    ("ja_ramen", "お会計お願いします。ごちそうさまでした"),
    # ja_ask_way
    ("ja_ask_way", "すみません、駅はどこですか"),
    ("ja_ask_way", "ここからえきまでとおいですか"),
    ("ja_ask_way", "まっすぐいって、ひだりですね？ありがとうございます"),
    ("ja_ask_way", "エキハドコデスカ"),
    # ja_hotel_checkin
    ("ja_hotel_checkin", "予約しているキムです。チェックインお願いします"),
    ("ja_hotel_checkin", "禁煙の部屋をお願いします"),
    ("ja_hotel_checkin", "ちょうしょくはなんじからですか。ＷｉＦｉはありますか"),   # full-width Latin letters
    ("ja_hotel_checkin", "チェックアウトは何時ですか。荷物を預かってもらえますか"),
    # ja_station_ticket
    ("ja_station_ticket", "きょうとまでおとなにまいください"),
    ("ja_station_ticket", "京都までの切符をください"),
    ("ja_station_ticket", "つぎの電車は何時ですか。何番線から出ますか"),
    ("ja_station_ticket", "カードではらいます。ありがとう"),
    # ja_clinic
    ("ja_clinic", "はじめてきました。診察をお願いします"),
    ("ja_clinic", "あたまがいたいです。ねつもあります"),
    ("ja_clinic", "きのうのよるからです"),
    ("ja_clinic", "アレルギーはありません。保険証はこれです"),
    # ja_shopping
    ("ja_shopping", "これはいくらですか"),
    ("ja_shopping", "もうすこしおおきいのはありますか。ちがういろもみたいです"),
    ("ja_shopping", "免税できますか"),
    ("ja_shopping", "ふくろはいりません。現金でお願いします"),
    # ja_self_intro
    ("ja_self_intro", "はじめまして、キムです。よろしくおねがいします"),
    ("ja_self_intro", "韓国から来ました。しゅみはさんぽです"),
    ("ja_self_intro", "ｻｯｶｰｶﾞｽｷﾃﾞｽ。あなたはどうですか"),                       # half-width katakana, no spaces
    # nothing matches / odd inputs (the norm must still be the same)
    ("ja_konbini", "Hello, I would like some water please"),                  # English only
    ("ja_konbini", "안녕하세요 물 주세요"),                                    # Korean only
    ("ja_konbini", "😀😀 おにぎりはどこですか 👍"),                           # emoji around a match
    ("ja_ramen", "ごちそうさま" * 80),                                          # 480 characters: only the first 300 count
    ("ja_ramen", "あ" * 295 + "ごちそうさま"),                                   # the match straddles the 300th character
    ("ja_ask_way", "、" * 299 + "すみません"),                                  # punctuation fills the cut, the match is after it
]

# MissionText.norm_ja cases (text -> normalize_ja); the half-width / composition / cut rules in one place
JA_NORM_CASES = [
    "ｶﾞｷﾞｸﾞｹﾞｺﾞ ﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ ｳﾞ ﾜﾞ ｦﾞ",           # half-width voiced and semi-voiced; ｳﾞ -> ヴ -> ゔ, ﾜﾞ -> ヷ and ｦﾞ -> ヺ are deleted
    "がぎぱゔゞ",         # combining voicing marks after hiragana
    "ガパヴヷヸヹヺヾ",   # ... after katakana (ワ゛ヰ゛ヱ゛ヲ゛ are deleted)
    "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポヴ",
    "ヷヸヹヺ ヷ ヺ",                                      # U+30F7..30FA are deleted (rule outside the docstring)
    "ヽヾゝゞ々〇ー",                                      # repeat marks, 々, 〇, long vowel
    "ｰｱｲｳｴｵ｡｢｣､･",                                       # half-width long vowel and punctuation
    "ＡＢＣａｂｃ０１２３！？（）",                        # full-width Latin letters, digits, marks
    "　 \t\n",                                            # ideographic space, space, tab, newline
    "",
    "   ",
    "東京タワー、スカイツリー。",
    "漢字ひらがなカタカナABCabc123",
    "I'm Kim. こんにちは！",
    "😀👍🏽🇯🇵",
    "안녕하세요 한국어",
    "ゟヿ",                                                # compat digraphs: より, コト
    "KİKİ ¼ ½ ¾ ™ ª º ① ⑩ ⓐⒶ x² ﬁ ﬃ",                    # compat characters that end in kept letters / digits
    "か゛き゜",                                           # spacing voicing marks (U+309B, 309C) are deleted, they do not compose
    "か゛゙",                                         # spacing mark then a combining mark: no composition
    "が゙",                                      # two combining marks: only the first composes
    "あ" * 300,
    "あ" * 301,
    "あ" * 299 + "ヷ",
    "あ" * 299 + "ヷ",                              # ワ + ゛ near the end: ヷ is deleted
    "ｱ" * 299 + "ﾞ",                                      # ｱ + ﾞ does not compose (ｱ is not voiceable)
    "ｶ" * 299 + "ﾞ",                                      # ｶ + ﾞ composes to ガ, kept
    "ｶ" * 300 + "ﾞ",                                      # the mark is past the first cut (300 characters)
    "①" * 300,                                           # 300 digits
    "⑩" * 200,                                           # each ⑩ gives 2 digits: 400 digits, cut to 300 AT THE END
    "ﬃ" * 150,                                           # each ﬃ gives 3 letters: 450 letters, cut to 300
    "x" * 299 + "ﬃ",                                      # the end cut lands inside an expansion
    "x" * 300 + "あ",                                     # the first cut (300 characters) comes before NFKC
]

# One code point at a time. The phone must give exactly the PC normalize_ja result for each of them.
JA_TABLE_SCOPE = (
    list(range(0x20, 0x7F))
    + [0x3000, 0x00AA, 0x00BA, 0x00B9, 0x00B2, 0x00B3, 0x00BC, 0x00BD, 0x00BE, 0x0130, 0x2070, 0x2071, 0x207F, 0x212A, 0x2122]
    + list(range(0x2074, 0x207A)) + list(range(0x2080, 0x208A)) + list(range(0x2460, 0x246A))
    + list(range(0xFB00, 0xFB07)) + list(range(0x24B6, 0x24EA))
    + list(range(0x3041, 0x3100))                       # hiragana, katakana, ゟ ヿ
    + [0x3005, 0x3007, 0x3001, 0x3002, 0x300C, 0x300D, 0x3004, 0x3006]
    + list(range(0x3099, 0x309D))                       # U+3099 .. 309C voicing marks
    + list(range(0xFF01, 0xFF61))                       # full-width forms
    + list(range(0xFF61, 0xFFA0))                       # half-width kana and the half-width punctuation
    + [0x4E00, 0x4E8C, 0x9FFF, 0x3400, 0x4DBF, 0x4DC0, 0x4DFF, 0xA000]
)

# NFKC results that the phone does NOT build (known gaps): the PC result is written here, the test asserts that the phone
# result is DIFFERENT (so the table cannot silently go stale) and prints them as the "known differences" table.
# (\uf900 is a CJK compatibility ideograph, written as an escape because editors normalise the literal to U+8C48.)
JA_KNOWN_GAPS = [
    "㈱", "㌔", "㎏", "Ⅳ", "\uf900", "⼀", "𝐀", "㊤", "⑴", "⒈", "ℌ", "e\u0301", "ヲ\u302e\u3099", "㍿", "𝟏", "㌻",
]

JA_RANDOM_N = 400
JA_RANDOM_SEED = 170

# character pools of the seeded random strings (the scratch comparison uses the same categories with more strings)
_RP_HIRA = [chr(c) for c in range(0x3041, 0x3097)] + ["ゝ", "ゞ"]
_RP_KATA = [chr(c) for c in range(0x30A1, 0x30FB)] + ["ー", "ヽ", "ヾ"]
_RP_HW = list(HW_KATA) + [HW_DAKU, HW_HANDAKU, "｡", "｢", "｣", "､", "･"]
_RP_FW = [chr(c) for c in range(0xFF01, 0xFF5F)] + ["　"]
_RP_ASCII = [chr(c) for c in range(0x20, 0x7F)]
_RP_KANJI = [chr(c) for c in (0x4E00, 0x4E8C, 0x4E09, 0x65E5, 0x672C, 0x8A9E, 0x7121, 0x9FFF, 0x3400, 0x4DBF)] + ["々", "〇"]
_RP_PUNCT = list("、。！？「」『』（）・〜…※→←￥￠￡") + ["゙", "゚", "゛", "゜"]
_RP_EMOJI = ["😀", "👍", "🇯🇵", "❤", "️", "‍", "1️⃣", "🎌"]
_RP_HANGUL = [chr(c) for c in (0xAC00, 0xD55C, 0xAD6D, 0xC5B4, 0x3131, 0x1100, 0x1161)]
_RP_COMPAT = ["①", "⑩", "ⓐ", "Ⓩ", "½", "™", "ﬁ", "ﬃ", "ª", "º", "x²", "K", "İ", "ゟ", "ヿ"]
_RP_POOLS = [_RP_HIRA, _RP_KATA, _RP_HW, _RP_FW, _RP_ASCII, _RP_KANJI, _RP_PUNCT, _RP_EMOJI, _RP_HANGUL, _RP_COMPAT]


def ja_random_strings(n, seed):
    """n seeded random strings from the pools above (lengths around the 300 character cut)"""
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        k = rnd.choice((1, 2, 3, 3, 6, 12, 40, 150, 290, 299, 300, 301, 330, 400))
        pools = rnd.sample(_RP_POOLS, rnd.choice((1, 2, 3, 4)))
        out.append("".join(rnd.choice(rnd.choice(pools)) for _ in range(k)))
    return out


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
    # Japanese (v1.7.0 B3): added after the English keys, which stay as they were
    assert len(JA_INPUTS) >= 24, len(JA_INPUTS)
    ja_entries = []
    for mission_id, text in JA_INPUTS:
        res = M.check_text("ja", mission_id, text, [])
        ja_entries.append({
            "lang": "ja",
            "mission_id": mission_id,
            "text": text,
            "norm": M.normalize(text, "ja"),
            "reached": list(res["new"]),
        })
    golden["ja_entries"] = ja_entries
    golden["ja_norm_cases"] = [{"text": t, "norm": M.normalize_ja(t)} for t in JA_NORM_CASES]
    golden["ja_table_cases"] = [[cp, M.normalize_ja(chr(cp))] for cp in JA_TABLE_SCOPE]
    golden["ja_known_gaps"] = [{"text": t, "norm": M.normalize_ja(t)} for t in JA_KNOWN_GAPS]
    golden["ja_random"] = [{"text": t, "norm": M.normalize_ja(t)} for t in ja_random_strings(JA_RANDOM_N, JA_RANDOM_SEED)]
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
    ja_cov = {}
    for e in ja_entries:
        ja_cov.setdefault(e["mission_id"], 0)
        if e["reached"]:
            ja_cov[e["mission_id"]] += 1
    print("ja_entries", len(ja_entries), "non-empty reached per mission", ja_cov)
    print("ja_norm_cases", len(JA_NORM_CASES), "ja_table_cases", len(JA_TABLE_SCOPE), "ja_known_gaps", len(JA_KNOWN_GAPS),
          "ja_random", JA_RANDOM_N)
    producers = pc_ascii_producers()
    outside = [cp for cp in producers if cp not in set(TABLE_SCOPE)]
    print("PC ASCII producers in scanned blocks: %d, in table scope: %d, outside (known gap): %d"
          % (len(producers), len(producers) - len(outside), len(outside)))


if __name__ == "__main__":
    main()
