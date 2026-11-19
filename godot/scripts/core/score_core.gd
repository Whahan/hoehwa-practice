class_name ScoreCore
extends RefCounted
## English pronunciation scoring on the phone: the GDScript copy of backend/server.py `score_en` (design docs/v201_design.md 2.1,
## docs/v200_phone_design.md 6.4). Pure static functions, no state worth the name, no I/O, no network.
## `score_en(target, words, text)` returns the same result dictionary as the server for every input of the golden file
## godot/tests/fixtures/score_golden_en.json (written by phone_src/tools/make_score_golden.py FROM the server functions):
##   keys transcript, score, accuracy, clarity, fluency, units[{t, ok, conf, heard}], tips_ko, in that order.
## What is copied: en_words (+ _expand_contraction, _num_words = num2words English cardinals below one billion),
## nw_align / align_seq (difflib.SequenceMatcher get_opcodes / ratio, ported from CPython incl. the autojunk rule of word_sim),
## word_sim, fluency_score, _final_score, en_tips / en_tip_for_pair / _EN_RULES, mismatch_tip, empty_score.
## Python's round() is half-to-even on the exact binary value: _round_int and _round3 do the same (GDScript round() and
## String.num() do not).
##
## RULES FIXED FOR THE CALIBRATION TOOLS (PA5a / PA5b implement the same sentences in Python):
##   map_p(p, p_map): p is cut to [0, 1] (NaN -> 0). p_map is a list of points [x, y]; between two neighbouring points the value is
##     linear: t = (p - x0) / (x1 - x0), y = y0 + (y1 - y0) * t; p equal to a point gives that point's y; outside the first / last
##     x the value is the end value. No two points have the same x. An invalid map (valid_p_map false) gives p unchanged.
##   map_final(score, final_map): the same on the axis 0..100 (score cut to [0, 100]); the result is floor(y + 0.5), cut to 0..100.
##     An invalid map gives the score unchanged.
##
## NFKC is not in GDScript. en_words builds it from tables generated from CPython's unicodedata 13.0.0 (one code point at a time):
##   _NFKC_RUNS / _NFKC_ONE: every code point U+0080..U+2FFFF whose NFKC text holds a-z, 0-9, an apostrophe or a comma (full-width
##   letters and digits, ligatures, superscripts, circled and mathematical letters, ...). Non-ASCII letters of such a text are
##   reduced to U+00C0 (a word character) and the other non-ASCII characters to a space, because en_words turns every non-a-z
##   character into a space anyway. İ (U+0130) is "i" + space (its lower() is i + U+0307). _ACCENT: an ASCII letter followed by a
##   combining mark that composes with it (e + U+0301 -> é, which en_words turns into a space).
##   _NONWORD: the non-ASCII ranges that are not \w, used by the rule "a thousands comma is deleted only when the three digits are
##   followed by a non-word character". Outside those ranges a non-ASCII character counts as a word character.
## KNOWN DIFFERENCES from the server (the golden file lists examples in "known_gaps"; the test asserts they still differ).
##   Every single code point U+0020..U+2FFFF was compared with the server in a scratch run, each as "x?y", "1,234?" and "e?"
##   (194,528 x 3 comparisons): the only differences are of these kinds, all of them extremely rare in English text:
##   - "1,234" followed by a non-ASCII character that Python treats as a non-word character but the copy as a word character
##     (the _NONWORD ranges cover Latin-1, punctuation, symbols, CJK punctuation, private use and unassigned planes; left out are
##     the 48,755 unassigned code points of the BMP and planes 1-2 and about 4,200 marks and symbols of other scripts);
##   - an ASCII letter followed by a combining mark that does not compose with it but would with a second mark after it
##     (e + U+0320 + U+0301);
##   - digits of other scripts inside the three-digit group after a thousands comma (Python's \d counts them, here only 0-9).
## Contract for other files: PA4 calls score_en, map_p, map_final, valid_p_map, valid_final_map. `score_en` returns {} when the
## target has no words (the caller answers 400 with TARGET_EMPTY_TEXT).

const OK_PROB := 0.45
const TARGET_EMPTY_TEXT := "연습할 문장이 비어 있어요."
const NO_VOICE_TIP := "목소리가 들리지 않았어요. 마이크를 확인하고 조금 더 크게 말해 보세요."
const MAX_MAP_POINTS := 32
## CPython SequenceMatcher: autojunk applies to a second sequence of 200 or more items
const _AUTOJUNK_N := 200

const _CONTR := {
	"can't": "can not", "cannot": "can not", "won't": "will not", "shan't": "shall not", "ain't": "is not",
	"let's": "let us", "gonna": "going to", "wanna": "want to", "gotta": "got to", "y'all": "you all",
	"ma'am": "madam", "o'clock": "oclock", "gimme": "give me", "lemme": "let me", "kinda": "kind of",
}
const _S_IS := ["it", "that", "what", "there", "here", "who", "he", "she", "where", "how", "when", "why", "this", "everything", "something", "nothing", "someone", "everyone"]
const _CONTR_SUFFIXES := [["'m", "am"], ["'re", "are"], ["'ve", "have"], ["'ll", "will"], ["'d", "would"]]

## num2words (English cardinal) cards below one billion, highest first
const _CARDS := [
	[1000000, "million"], [1000, "thousand"], [100, "hundred"], [90, "ninety"], [80, "eighty"], [70, "seventy"], [60, "sixty"],
	[50, "fifty"], [40, "forty"], [30, "thirty"], [20, "twenty"], [19, "nineteen"], [18, "eighteen"], [17, "seventeen"],
	[16, "sixteen"], [15, "fifteen"], [14, "fourteen"], [13, "thirteen"], [12, "twelve"], [11, "eleven"], [10, "ten"],
	[9, "nine"], [8, "eight"], [7, "seven"], [6, "six"], [5, "five"], [4, "four"], [3, "three"], [2, "two"], [1, "one"], [0, "zero"],
]

const _EN_RULES := {
	"r|l": ["rl", "r은 혀끝을 입천장에 대지 않고 뒤로 살짝 말아 올려요. 한국어 ㄹ처럼 혀를 대면 l로 들려요."],
	"l|r": ["rl", "l은 혀끝을 윗니 뒤 잇몸에 붙인 채로 소리를 내요. 혀를 말면 r로 들려요."],
	"f|p": ["fp", "f는 윗니를 아랫입술에 살짝 대고 바람을 새게 내는 소리예요. 입술을 붙였다 터뜨리면 p가 돼요."],
	"p|f": ["fp", "p는 두 입술을 붙였다가 터뜨리는 소리예요. 윗니를 입술에 대지 마세요."],
	"v|b": ["vb", "v는 윗니를 아랫입술에 살짝 대고 목을 울려요. 입술을 붙이면 b로 들려요."],
	"b|v": ["vb", "b는 두 입술을 붙였다 터뜨리는 소리예요. 윗니를 입술에 대면 v로 들려요."],
	"th|s": ["th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 안으로 넣으면 s로 들려요."],
	"th|d": ["th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 입천장에 붙이면 d로 들려요."],
	"th|t": ["th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 입천장에 붙이면 t로 들려요."],
	"th|z": ["th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 안으로 넣으면 z로 들려요."],
	"z|j": ["zj", "z는 혀를 윗잇몸 가까이에 두고 목을 울리며 바람을 내보내요. 혀를 붙였다 떼면 j로 들려요."],
	"j|z": ["zj", "j는 혀를 윗잇몸에 붙였다가 떼며 소리를 내요. 바람만 내보내면 z로 들려요."],
	"i|ee": ["vowel", "짧은 i(ship)와 긴 ee(sheep)를 구분해야 해요. 짧은 i는 입 힘을 풀고 짧게 발음해요."],
	"i|ea": ["vowel", "짧은 i(ship)와 긴 ee(sheep)를 구분해야 해요. 짧은 i는 입 힘을 풀고 짧게 발음해요."],
	"ee|i": ["vowel", "긴 ee(sheep)는 입꼬리를 옆으로 당기고 길게 끌어 발음해요. 짧게 하면 i(ship)로 들려요."],
	"ea|i": ["vowel", "긴 ee(sheep)는 입꼬리를 옆으로 당기고 길게 끌어 발음해요. 짧게 하면 i(ship)로 들려요."],
	"u|oo": ["vowel", "짧은 u(full)와 긴 oo(fool)를 구분해야 해요. 짧은 u는 입술을 덜 내밀고 짧게 발음해요."],
	"oo|u": ["vowel", "긴 oo(fool)는 입술을 동그랗게 내밀고 길게 끌어 발음해요. 짧게 하면 u(full)로 들려요."],
	"a|e": ["vowel", "a와 e 모음이 헷갈렸어요. a(bad)는 입을 더 크게 벌려 발음해요."],
	"e|a": ["vowel", "e와 a 모음이 헷갈렸어요. e(bed)는 입을 덜 벌리고 발음해요."],
}

const _NFKC_RUNS := [
	[0x1D33, 0x1D3A, "G"], [0x2074, 0x2079, "4"], [0x2080, 0x2089, "0"], [0x2096, 0x2099, "k"],
	[0x2119, 0x211B, "P"], [0x2460, 0x2468, "1"], [0x24B6, 0x24CF, "A"], [0x24D0, 0x24E9, "a"],
	[0xFF10, 0xFF19, "0"], [0xFF21, 0xFF3A, "A"], [0xFF40, 0xFF5A, "`"], [0x1D400, 0x1D419, "A"],
	[0x1D41A, 0x1D433, "a"], [0x1D434, 0x1D44D, "A"], [0x1D44E, 0x1D454, "a"], [0x1D456, 0x1D467, "i"],
	[0x1D468, 0x1D481, "A"], [0x1D482, 0x1D49B, "a"], [0x1D4A9, 0x1D4AC, "N"], [0x1D4AE, 0x1D4B5, "S"],
	[0x1D4B6, 0x1D4B9, "a"], [0x1D4BD, 0x1D4C3, "h"], [0x1D4C5, 0x1D4CF, "p"], [0x1D4D0, 0x1D4E9, "A"],
	[0x1D4EA, 0x1D503, "a"], [0x1D507, 0x1D50A, "D"], [0x1D50D, 0x1D514, "J"], [0x1D516, 0x1D51C, "S"],
	[0x1D51E, 0x1D537, "a"], [0x1D53B, 0x1D53E, "D"], [0x1D540, 0x1D544, "I"], [0x1D54A, 0x1D550, "S"],
	[0x1D552, 0x1D56B, "a"], [0x1D56C, 0x1D585, "A"], [0x1D586, 0x1D59F, "a"], [0x1D5A0, 0x1D5B9, "A"],
	[0x1D5BA, 0x1D5D3, "a"], [0x1D5D4, 0x1D5ED, "A"], [0x1D5EE, 0x1D607, "a"], [0x1D608, 0x1D621, "A"],
	[0x1D622, 0x1D63B, "a"], [0x1D63C, 0x1D655, "A"], [0x1D656, 0x1D66F, "a"], [0x1D670, 0x1D689, "A"],
	[0x1D68A, 0x1D6A3, "a"], [0x1D7CE, 0x1D7D7, "0"], [0x1D7D8, 0x1D7E1, "0"], [0x1D7E2, 0x1D7EB, "0"],
	[0x1D7EC, 0x1D7F5, "0"], [0x1D7F6, 0x1D7FF, "0"], [0x1F130, 0x1F149, "A"], [0x1FBF0, 0x1FBF9, "0"],
]
const _NFKC_ONE := {
	0xAA: "a", 0xB2: "2", 0xB3: "3", 0xB9: "1", 0xBA: "o",
	0xBC: "1 4", 0xBD: "1 2", 0xBE: "3 4", 0x132: "IJ", 0x133: "ij",
	0x13F: "L ", 0x140: "l ", 0x149: "\u00c0n", 0x17F: "s", 0x1C4: "D\u00c0",
	0x1C5: "D\u00c0", 0x1C6: "d\u00c0", 0x1C7: "LJ", 0x1C8: "Lj", 0x1C9: "lj",
	0x1CA: "NJ", 0x1CB: "Nj", 0x1CC: "nj", 0x1F1: "DZ", 0x1F2: "Dz",
	0x1F3: "dz", 0x2B0: "h", 0x2B2: "j", 0x2B3: "r", 0x2B7: "w",
	0x2B8: "y", 0x2E1: "l", 0x2E2: "s", 0x2E3: "x", 0x1D2C: "A",
	0x1D2E: "B", 0x1D30: "D", 0x1D31: "E", 0x1D3C: "O", 0x1D3E: "P",
	0x1D3F: "R", 0x1D40: "T", 0x1D41: "U", 0x1D42: "W", 0x1D43: "a",
	0x1D47: "b", 0x1D48: "d", 0x1D49: "e", 0x1D4D: "g", 0x1D4F: "k",
	0x1D50: "m", 0x1D52: "o", 0x1D56: "p", 0x1D57: "t", 0x1D58: "u",
	0x1D5B: "v", 0x1D62: "i", 0x1D63: "r", 0x1D64: "u", 0x1D65: "v",
	0x1D9C: "c", 0x1DA0: "f", 0x1DBB: "z", 0x1E9A: "a\u00c0", 0x1FEF: "`",
	0x2070: "0", 0x2071: "i", 0x207F: "n", 0x2090: "a", 0x2091: "e",
	0x2092: "o", 0x2093: "x", 0x2095: "h", 0x209A: "p", 0x209B: "s",
	0x209C: "t", 0x20A8: "Rs", 0x2100: "a/c", 0x2101: "a/s", 0x2102: "C",
	0x2103: " C", 0x2105: "c/o", 0x2106: "c/u", 0x2109: " F", 0x210A: "g",
	0x210B: "H", 0x210C: "H", 0x210D: "H", 0x210E: "h", 0x2110: "I",
	0x2111: "I", 0x2112: "L", 0x2113: "l", 0x2115: "N", 0x2116: "No",
	0x211C: "R", 0x211D: "R", 0x2120: "SM", 0x2121: "TEL", 0x2122: "TM",
	0x2124: "Z", 0x2128: "Z", 0x212A: "K", 0x212C: "B", 0x212D: "C",
	0x212F: "e", 0x2130: "E", 0x2131: "F", 0x2133: "M", 0x2134: "o",
	0x2139: "i", 0x213B: "FAX", 0x2145: "D", 0x2146: "d", 0x2147: "e",
	0x2148: "i", 0x2149: "j", 0x2150: "1 7", 0x2151: "1 9", 0x2152: "1 10",
	0x2153: "1 3", 0x2154: "2 3", 0x2155: "1 5", 0x2156: "2 5", 0x2157: "3 5",
	0x2158: "4 5", 0x2159: "1 6", 0x215A: "5 6", 0x215B: "1 8", 0x215C: "3 8",
	0x215D: "5 8", 0x215E: "7 8", 0x215F: "1 ", 0x2160: "I", 0x2161: "II",
	0x2162: "III", 0x2163: "IV", 0x2164: "V", 0x2165: "VI", 0x2166: "VII",
	0x2167: "VIII", 0x2168: "IX", 0x2169: "X", 0x216A: "XI", 0x216B: "XII",
	0x216C: "L", 0x216D: "C", 0x216E: "D", 0x216F: "M", 0x2170: "i",
	0x2171: "ii", 0x2172: "iii", 0x2173: "iv", 0x2174: "v", 0x2175: "vi",
	0x2176: "vii", 0x2177: "viii", 0x2178: "ix", 0x2179: "x", 0x217A: "xi",
	0x217B: "xii", 0x217C: "l", 0x217D: "c", 0x217E: "d", 0x217F: "m",
	0x2189: "0 3", 0x2469: "10", 0x246A: "11", 0x246B: "12", 0x246C: "13",
	0x246D: "14", 0x246E: "15", 0x246F: "16", 0x2470: "17", 0x2471: "18",
	0x2472: "19", 0x2473: "20", 0x2474: "(1)", 0x2475: "(2)", 0x2476: "(3)",
	0x2477: "(4)", 0x2478: "(5)", 0x2479: "(6)", 0x247A: "(7)", 0x247B: "(8)",
	0x247C: "(9)", 0x247D: "(10)", 0x247E: "(11)", 0x247F: "(12)", 0x2480: "(13)",
	0x2481: "(14)", 0x2482: "(15)", 0x2483: "(16)", 0x2484: "(17)", 0x2485: "(18)",
	0x2486: "(19)", 0x2487: "(20)", 0x2488: "1.", 0x2489: "2.", 0x248A: "3.",
	0x248B: "4.", 0x248C: "5.", 0x248D: "6.", 0x248E: "7.", 0x248F: "8.",
	0x2490: "9.", 0x2491: "10.", 0x2492: "11.", 0x2493: "12.", 0x2494: "13.",
	0x2495: "14.", 0x2496: "15.", 0x2497: "16.", 0x2498: "17.", 0x2499: "18.",
	0x249A: "19.", 0x249B: "20.", 0x249C: "(a)", 0x249D: "(b)", 0x249E: "(c)",
	0x249F: "(d)", 0x24A0: "(e)", 0x24A1: "(f)", 0x24A2: "(g)", 0x24A3: "(h)",
	0x24A4: "(i)", 0x24A5: "(j)", 0x24A6: "(k)", 0x24A7: "(l)", 0x24A8: "(m)",
	0x24A9: "(n)", 0x24AA: "(o)", 0x24AB: "(p)", 0x24AC: "(q)", 0x24AD: "(r)",
	0x24AE: "(s)", 0x24AF: "(t)", 0x24B0: "(u)", 0x24B1: "(v)", 0x24B2: "(w)",
	0x24B3: "(x)", 0x24B4: "(y)", 0x24B5: "(z)", 0x24EA: "0", 0x2C7C: "j",
	0x2C7D: "V", 0x3250: "PTE", 0x3251: "21", 0x3252: "22", 0x3253: "23",
	0x3254: "24", 0x3255: "25", 0x3256: "26", 0x3257: "27", 0x3258: "28",
	0x3259: "29", 0x325A: "30", 0x325B: "31", 0x325C: "32", 0x325D: "33",
	0x325E: "34", 0x325F: "35", 0x32B1: "36", 0x32B2: "37", 0x32B3: "38",
	0x32B4: "39", 0x32B5: "40", 0x32B6: "41", 0x32B7: "42", 0x32B8: "43",
	0x32B9: "44", 0x32BA: "45", 0x32BB: "46", 0x32BC: "47", 0x32BD: "48",
	0x32BE: "49", 0x32BF: "50", 0x32C0: "1\u00c0", 0x32C1: "2\u00c0", 0x32C2: "3\u00c0",
	0x32C3: "4\u00c0", 0x32C4: "5\u00c0", 0x32C5: "6\u00c0", 0x32C6: "7\u00c0", 0x32C7: "8\u00c0",
	0x32C8: "9\u00c0", 0x32C9: "10\u00c0", 0x32CA: "11\u00c0", 0x32CB: "12\u00c0", 0x32CC: "Hg",
	0x32CD: "erg", 0x32CE: "eV", 0x32CF: "LTD", 0x3358: "0\u00c0", 0x3359: "1\u00c0",
	0x335A: "2\u00c0", 0x335B: "3\u00c0", 0x335C: "4\u00c0", 0x335D: "5\u00c0", 0x335E: "6\u00c0",
	0x335F: "7\u00c0", 0x3360: "8\u00c0", 0x3361: "9\u00c0", 0x3362: "10\u00c0", 0x3363: "11\u00c0",
	0x3364: "12\u00c0", 0x3365: "13\u00c0", 0x3366: "14\u00c0", 0x3367: "15\u00c0", 0x3368: "16\u00c0",
	0x3369: "17\u00c0", 0x336A: "18\u00c0", 0x336B: "19\u00c0", 0x336C: "20\u00c0", 0x336D: "21\u00c0",
	0x336E: "22\u00c0", 0x336F: "23\u00c0", 0x3370: "24\u00c0", 0x3371: "hPa", 0x3372: "da",
	0x3373: "AU", 0x3374: "bar", 0x3375: "oV", 0x3376: "pc", 0x3377: "dm",
	0x3378: "dm2", 0x3379: "dm3", 0x337A: "IU", 0x3380: "pA", 0x3381: "nA",
	0x3382: "\u00c0A", 0x3383: "mA", 0x3384: "kA", 0x3385: "KB", 0x3386: "MB",
	0x3387: "GB", 0x3388: "cal", 0x3389: "kcal", 0x338A: "pF", 0x338B: "nF",
	0x338C: "\u00c0F", 0x338D: "\u00c0g", 0x338E: "mg", 0x338F: "kg", 0x3390: "Hz",
	0x3391: "kHz", 0x3392: "MHz", 0x3393: "GHz", 0x3394: "THz", 0x3395: "\u00c0l",
	0x3396: "ml", 0x3397: "dl", 0x3398: "kl", 0x3399: "fm", 0x339A: "nm",
	0x339B: "\u00c0m", 0x339C: "mm", 0x339D: "cm", 0x339E: "km", 0x339F: "mm2",
	0x33A0: "cm2", 0x33A1: "m2", 0x33A2: "km2", 0x33A3: "mm3", 0x33A4: "cm3",
	0x33A5: "m3", 0x33A6: "km3", 0x33A7: "m s", 0x33A8: "m s2", 0x33A9: "Pa",
	0x33AA: "kPa", 0x33AB: "MPa", 0x33AC: "GPa", 0x33AD: "rad", 0x33AE: "rad s",
	0x33AF: "rad s2", 0x33B0: "ps", 0x33B1: "ns", 0x33B2: "\u00c0s", 0x33B3: "ms",
	0x33B4: "pV", 0x33B5: "nV", 0x33B6: "\u00c0V", 0x33B7: "mV", 0x33B8: "kV",
	0x33B9: "MV", 0x33BA: "pW", 0x33BB: "nW", 0x33BC: "\u00c0W", 0x33BD: "mW",
	0x33BE: "kW", 0x33BF: "MW", 0x33C0: "k\u00c0", 0x33C1: "M\u00c0", 0x33C2: "a.m.",
	0x33C3: "Bq", 0x33C4: "cc", 0x33C5: "cd", 0x33C6: "C kg", 0x33C7: "Co.",
	0x33C8: "dB", 0x33C9: "Gy", 0x33CA: "ha", 0x33CB: "HP", 0x33CC: "in",
	0x33CD: "KK", 0x33CE: "KM", 0x33CF: "kt", 0x33D0: "lm", 0x33D1: "ln",
	0x33D2: "log", 0x33D3: "lx", 0x33D4: "mb", 0x33D5: "mil", 0x33D6: "mol",
	0x33D7: "PH", 0x33D8: "p.m.", 0x33D9: "PPM", 0x33DA: "PR", 0x33DB: "sr",
	0x33DC: "Sv", 0x33DD: "Wb", 0x33DE: "V m", 0x33DF: "A m", 0x33E0: "1\u00c0",
	0x33E1: "2\u00c0", 0x33E2: "3\u00c0", 0x33E3: "4\u00c0", 0x33E4: "5\u00c0", 0x33E5: "6\u00c0",
	0x33E6: "7\u00c0", 0x33E7: "8\u00c0", 0x33E8: "9\u00c0", 0x33E9: "10\u00c0", 0x33EA: "11\u00c0",
	0x33EB: "12\u00c0", 0x33EC: "13\u00c0", 0x33ED: "14\u00c0", 0x33EE: "15\u00c0", 0x33EF: "16\u00c0",
	0x33F0: "17\u00c0", 0x33F1: "18\u00c0", 0x33F2: "19\u00c0", 0x33F3: "20\u00c0", 0x33F4: "21\u00c0",
	0x33F5: "22\u00c0", 0x33F6: "23\u00c0", 0x33F7: "24\u00c0", 0x33F8: "25\u00c0", 0x33F9: "26\u00c0",
	0x33FA: "27\u00c0", 0x33FB: "28\u00c0", 0x33FC: "29\u00c0", 0x33FD: "30\u00c0", 0x33FE: "31\u00c0",
	0x33FF: "gal", 0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi",
	0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st", 0xFE10: ",", 0xFE50: ",",
	0xFF07: "'", 0xFF0C: ",", 0x1D49C: "A", 0x1D49E: "C", 0x1D49F: "D",
	0x1D4A2: "G", 0x1D4A5: "J", 0x1D4A6: "K", 0x1D4BB: "f", 0x1D504: "A",
	0x1D505: "B", 0x1D538: "A", 0x1D539: "B", 0x1D546: "O", 0x1F100: "0.",
	0x1F101: "0,", 0x1F102: "1,", 0x1F103: "2,", 0x1F104: "3,", 0x1F105: "4,",
	0x1F106: "5,", 0x1F107: "6,", 0x1F108: "7,", 0x1F109: "8,", 0x1F10A: "9,",
	0x1F110: "(A)", 0x1F111: "(B)", 0x1F112: "(C)", 0x1F113: "(D)", 0x1F114: "(E)",
	0x1F115: "(F)", 0x1F116: "(G)", 0x1F117: "(H)", 0x1F118: "(I)", 0x1F119: "(J)",
	0x1F11A: "(K)", 0x1F11B: "(L)", 0x1F11C: "(M)", 0x1F11D: "(N)", 0x1F11E: "(O)",
	0x1F11F: "(P)", 0x1F120: "(Q)", 0x1F121: "(R)", 0x1F122: "(S)", 0x1F123: "(T)",
	0x1F124: "(U)", 0x1F125: "(V)", 0x1F126: "(W)", 0x1F127: "(X)", 0x1F128: "(Y)",
	0x1F129: "(Z)", 0x1F12A: " S ", 0x1F12B: "C", 0x1F12C: "R", 0x1F12D: "CD",
	0x1F12E: "WZ", 0x1F14A: "HV", 0x1F14B: "MV", 0x1F14C: "SD", 0x1F14D: "SS",
	0x1F14E: "PPV", 0x1F14F: "WC", 0x1F16A: "MC", 0x1F16B: "MD", 0x1F16C: "MR",
	0x1F190: "DJ",
}
const _NONWORD := [
	0x80, 0xA9, 0xAB, 0xB1, 0xB4, 0xB4, 0xB6, 0xB8, 0xBB, 0xBB, 0xBF, 0xBF, 0xD7, 0xD7, 0xF7, 0xF7,
	0x2C2, 0x2C5, 0x2D2, 0x2DF, 0x2E5, 0x2EB, 0x2ED, 0x2ED, 0x2EF, 0x36F, 0x2000, 0x206F, 0x2072, 0x2073, 0x207A, 0x207E,
	0x208A, 0x208F, 0x209D, 0x20A7, 0x20A9, 0x20FF, 0x2104, 0x2104, 0x2108, 0x2108, 0x2114, 0x2114, 0x2117, 0x2118, 0x211E, 0x211F,
	0x2123, 0x2123, 0x2125, 0x2125, 0x2127, 0x2127, 0x2129, 0x2129, 0x212E, 0x212E, 0x213A, 0x213A, 0x2140, 0x2144, 0x214A, 0x214D,
	0x214F, 0x214F, 0x218A, 0x245F, 0x2500, 0x2775, 0x2794, 0x2BFF, 0x2E00, 0x2E2E, 0x2E30, 0x2E9E, 0x2EA0, 0x2EF2, 0x2EF4, 0x2EFF,
	0x2FD6, 0x3004, 0x3008, 0x3020, 0x302A, 0x3030, 0x3036, 0x3037, 0x303D, 0x303F, 0x4DC0, 0x4DFF, 0xE000, 0xF8FF, 0xFE00, 0xFE0F,
	0xFE11, 0xFE32, 0xFE35, 0xFE4C, 0xFE51, 0xFE6F, 0xFF00, 0xFF06, 0xFF08, 0xFF0B, 0xFF0D, 0xFF0F, 0xFF1A, 0xFF20, 0xFF3B, 0xFF3E,
	0xFF5B, 0xFF65, 0xFF9E, 0xFF9F, 0xFFBF, 0xFFC1, 0xFFC8, 0xFFC9, 0xFFD0, 0xFFD1, 0xFFD8, 0xFFD9, 0xFFDD, 0xFFFF, 0x1F000, 0x1F0FF,
	0x1F10D, 0x1F10F, 0x1F12F, 0x1F12F, 0x1F150, 0x1F169, 0x1F16D, 0x1F18F, 0x1F191, 0x1F1FF, 0x1F203, 0x1F20F, 0x1F23C, 0x1F24F, 0x1F252, 0x1FAFF,
	0x323B0, 0x10FFFF,
]
const _ACCENT := {
	0x300: "aeinouwyAEINOUWY", 0x301: "acegiklmnoprsuwyzACEGIKLMNOPRSUWYZ", 0x302: "aceghijosuwyzACEGHIJOSUWYZ",
	0x303: "aeinouvyAEINOUVY", 0x304: "aegiouyAEGIOUY", 0x306: "aegiouAEGIOU",
	0x307: "abcdefghmnoprstwxyzABCDEFGHIMNOPRSTWXYZ", 0x308: "aehiotuwxyAEHIOUWXY", 0x309: "aeiouyAEIOUY",
	0x30A: "auwyAU", 0x30B: "ouOU", 0x30C: "acdeghijklnorstuzACDEGHIKLNORSTUZ",
	0x30F: "aeioruAEIORU", 0x311: "aeioruAEIORU", 0x31B: "ouOU",
	0x323: "abdehiklmnorstuvwyzABDEHIKLMNORSTUVWYZ", 0x324: "uU", 0x325: "aA",
	0x326: "stST", 0x327: "cdeghklnrstCDEGHKLNRST", 0x328: "aeiouAEIOU",
	0x32D: "delntuDELNTU", 0x32E: "hH", 0x330: "eiuEIU",
	0x331: "bdhklnrtzBDKLNRTZ", 0x340: "aeinouwyAEINOUWY", 0x341: "acegiklmnoprsuwyzACEGIKLMNOPRSUWYZ",
	0x344: "aehiotuwxyAEHIOUWXY",
}

static var _nfkc_map: Dictionary = {}


# ================================================================================================ public API
## Same result dictionary as backend/server.py score_en(target, words, text) (see the header). `words` is the recogniser's word
## list [{w, p, start, end}]: anything that is not a list gives no words, entries that are not dictionaries with a "w" are skipped,
## p is cut to [0, 1] (NaN -> 0), start never goes back and end is never before start. For input the recogniser can really
## produce these corrections change nothing. {} when the target has no words.
static func score_en(target: String, words: Variant, text: String, ok_prob: float = OK_PROB) -> Dictionary:
	var tw: Array = en_words(target)
	if tw.is_empty():
		return {}
	var ws: Array = _clean_words(words)
	var hw: Array = []   # [norm word, prob]
	for w in ws:
		for x in en_words(String(w["w"])):
			hw.append([x, float(w["p"])])
	if hw.is_empty():
		var empty_units: Array = []
		for t in tw:
			empty_units.append({"t": t, "ok": false, "conf": 0.0, "heard": null})
		return _empty_score(empty_units)
	var heard: Array = []
	for h in hw:
		heard.append(h[0])
	var al: Dictionary = align_seq(tw, heard)
	var pairs: Array = al["pairs"]
	var units: Array = []
	var exact_flags: Array = []
	for i in tw.size():
		var j: Variant = pairs[i][0]
		var exact: bool = bool(pairs[i][1])
		if j != null and exact:
			var p: float = float(hw[int(j)][1])
			units.append({"t": tw[i], "ok": p >= ok_prob, "conf": _round3(p), "heard": null})
			exact_flags.append(true)
		elif j != null:
			units.append({"t": tw[i], "ok": false, "conf": 0.0, "heard": hw[int(j)][0]})
			exact_flags.append(false)
		else:
			units.append({"t": tw[i], "ok": false, "conf": 0.0, "heard": null})
			exact_flags.append(false)
	var n: int = units.size()
	var n_ok: int = 0
	var conf_sum: float = 0.0
	var n_matched: int = 0
	for i in n:
		if bool(units[i]["ok"]):
			n_ok += 1
		if bool(exact_flags[i]):
			conf_sum += float(units[i]["conf"])
			n_matched += 1
	var accuracy: float = 100.0 * float(n_ok) / float(n)
	var clarity: float = 100.0 * (conf_sum / float(n_matched)) if n_matched > 0 else 0.0
	var fluency: int = fluency_score(n, ws)
	var tips: Array = _en_tips(units, fluency, clarity, not ws.is_empty())
	if accuracy < 40.0:
		var with_mismatch: Array = [_mismatch_tip(text)]
		with_mismatch.append_array(tips)
		tips = with_mismatch.slice(0, 3)
	return {
		"transcript": text, "score": _final_score(accuracy, clarity, fluency), "accuracy": _round_int(accuracy),
		"clarity": _round_int(clarity), "fluency": fluency, "units": units, "tips_ko": tips,
	}


## server en_words: the words of a text, lower case, contractions and numbers up to 9 digits spelled out.
static func en_words(text: String) -> Array:
	if text.is_empty():
		return []
	var s: PackedInt32Array = _normalise(text)
	var out: Array = []
	var cur: String = ""
	var tokens: Array = []
	for c in s:
		if c == 0x20:
			if not cur.is_empty():
				tokens.append(cur)
				cur = ""
		else:
			cur += String.chr(c)
	if not cur.is_empty():
		tokens.append(cur)
	for tok in tokens:
		var w: String = _strip_apos(String(tok))
		if w.is_empty():
			continue
		for x0 in _expand_contraction(w):
			var x: String = _strip_apos(String(x0))
			if x.is_empty():
				continue
			out.append_array(_num_words(x))
	return out


## server align_seq with word_sim as the similarity: {"pairs": [[j or null, exact], ...] (one per target item), "inserts":
## [[before target index, j], ...]}. Items are Strings.
static func align_seq(target: Array, heard: Array) -> Dictionary:
	var blocks: Array = _matching_blocks(target, heard, false)
	var pairs: Array = []
	for i in target.size():
		pairs.append([null, false])
	var inserts: Array = []
	for op in _opcodes(blocks, target.size(), heard.size()):
		var tag: String = op[0]
		var i1: int = op[1]
		var i2: int = op[2]
		var j1: int = op[3]
		var j2: int = op[4]
		if tag == "equal":
			for k in i2 - i1:
				pairs[i1 + k] = [j1 + k, true]
		elif tag == "replace":
			for pr in _nw_align(target.slice(i1, i2), heard.slice(j1, j2)):
				var ti: Variant = pr[0]
				var hj: Variant = pr[1]
				if ti != null and hj != null:
					pairs[i1 + int(ti)] = [j1 + int(hj), false]
				elif hj != null:
					inserts.append([i1 + (int(ti) if ti != null else 0), j1 + int(hj)])
		elif tag == "insert":
			for hj2 in range(j1, j2):
				inserts.append([i1, hj2])
	return {"pairs": pairs, "inserts": inserts}


## difflib.SequenceMatcher(None, a, b).ratio() for two strings (the characters are the items)
static func word_sim(a: String, b: String) -> float:
	if a == b and b.length() < _AUTOJUNK_N:
		return 1.0
	var total: int = a.length() + b.length()
	if total == 0:
		return 1.0
	var matches: int = 0
	for blk in _matching_blocks(_chars(a), _chars(b), true):
		matches += int(blk[2])
	return 2.0 * float(matches) / float(total)


## server fluency_score("en", n_units, words): words is the cleaned list [{w, p, start, end}]
static func fluency_score(_n_units: int, words: Array) -> int:
	if words.is_empty():
		return 0
	var span: float = maxf(0.01, float(words[words.size() - 1]["end"]) - float(words[0]["start"]))
	var lo: float = 1.8
	var hi: float = 3.5
	var rate: float = float(words.size()) / span
	var short: bool = words.size() <= 2
	var rate_score: float
	if short or span < 0.6:
		rate_score = 100.0
	elif rate < lo:
		rate_score = 100.0 * maxf(0.0, rate / lo)
	elif rate > hi:
		rate_score = maxf(0.0, 100.0 - (rate - hi) / hi * 60.0)
	else:
		rate_score = 100.0
	var pen: float = 0.0
	for k in range(1, words.size()):
		var gap: float = float(words[k]["start"]) - float(words[k - 1]["end"])
		if gap > 0.8:
			pen += 12.0 + minf(25.0, (gap - 0.8) * 15.0)
	return _round_int(maxf(0.0, minf(100.0, rate_score - pen)))


## Piecewise linear map of a word probability (see the header). p_map: [[x, y], ...]
static func map_p(p: float, p_map: Array) -> float:
	var q: float = 0.0 if is_nan(p) else clampf(p, 0.0, 1.0)
	if not valid_p_map(p_map):
		return q
	return _interp(q, p_map)


## true when p_map is a list of 2..32 points [x, y]: x strictly increasing from 0 to 1, y non-decreasing within [0, 1]
static func valid_p_map(p_map: Variant) -> bool:
	return _valid_map(p_map, 1.0)


## Piecewise linear map of a final score 0..100 (see the header), integer result
static func map_final(score: int, final_map: Array) -> int:
	var q: int = clampi(score, 0, 100)
	if not valid_final_map(final_map):
		return q
	var y: float = _interp(float(q), final_map)
	return clampi(int(floor(y + 0.5)), 0, 100)


## true when m is a list of 2..32 points [x, y]: x strictly increasing from 0 to 100, y non-decreasing within [0, 100]
static func valid_final_map(m: Variant) -> bool:
	return _valid_map(m, 100.0)


# ================================================================================================ maps
static func _valid_map(m: Variant, top: float) -> bool:
	if not (m is Array):
		return false
	var arr: Array = m
	if arr.size() < 2 or arr.size() > MAX_MAP_POINTS:
		return false
	var prev_x: float = -INF
	var prev_y: float = -INF
	for i in arr.size():
		var pt: Variant = arr[i]
		if not (pt is Array) or (pt as Array).size() != 2:
			return false
		var xv: Variant = (pt as Array)[0]
		var yv: Variant = (pt as Array)[1]
		if not _is_num(xv) or not _is_num(yv):
			return false
		var x: float = float(xv)
		var y: float = float(yv)
		if is_nan(x) or is_nan(y) or is_inf(x) or is_inf(y):
			return false
		if y < 0.0 or y > top or x < 0.0 or x > top:
			return false
		if i == 0 and x != 0.0:
			return false
		if i == arr.size() - 1 and x != top:
			return false
		if x <= prev_x or y < prev_y:
			return false
		prev_x = x
		prev_y = y
	return true


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## value of the (valid) map at q: linear between the neighbouring points, the end value outside
static func _interp(q: float, m: Array) -> float:
	var n: int = m.size()
	if q <= float(m[0][0]):
		return float(m[0][1])
	if q >= float(m[n - 1][0]):
		return float(m[n - 1][1])
	for k in range(n - 1):
		var x0: float = float(m[k][0])
		var x1: float = float(m[k + 1][0])
		if q <= x1:
			var y0: float = float(m[k][1])
			var y1: float = float(m[k + 1][1])
			var t: float = (q - x0) / (x1 - x0)
			return y0 + (y1 - y0) * t
	return float(m[n - 1][1])


# ================================================================================================ rounding (Python semantics)
## Python round(x) for a float: half to even. x is finite.
static func _round_int(x: float) -> int:
	var f: float = floor(x)
	var d: float = x - f
	var fi: int = int(f)
	if d < 0.5:
		return fi
	if d > 0.5:
		return fi + 1
	return fi if fi % 2 == 0 else fi + 1


## Python round(p, 3) for p in [0, 1]: the double nearest to the thousandths that the EXACT binary value of p rounds to
## (half to even on an exact tie). The product p * 1000 is split into hi + lo without error (Dekker), so the decision uses the
## exact value, not the rounded product.
static func _round3(p: float) -> float:
	if p <= 0.0:
		return 0.0
	if p >= 1.0:
		return 1.0
	var hi: float = p * 1000.0
	var c: float = 134217729.0 * p
	var ph: float = c - (c - p)
	var pl: float = p - ph
	# 1000 = 1111101000b fits in the high half, so its low half is 0
	var lo: float = ((ph * 1000.0 - hi) + pl * 1000.0)
	var j0: float = floor(hi)
	var diff: float = ((hi - j0) - 0.5) + lo
	var j: int = int(j0)
	if diff > 0.0:
		j += 1
	elif diff == 0.0:
		if j % 2 != 0:
			j += 1
	return float(j) / 1000.0


# ================================================================================================ text
static func _normalise(text: String) -> PackedInt32Array:
	if _nfkc_map.is_empty():
		_build_nfkc()
	# 1. NFKC subset: table, then the accent rule
	var mapped := PackedInt32Array()
	for i in text.length():
		var c: int = text.unicode_at(i)
		if c < 0x80:
			mapped.append(c)
		elif c == 0x130:
			mapped.append(0x69)
			mapped.append(0x20)
		elif _nfkc_map.has(c):
			var rep: String = _nfkc_map[c]
			for k in rep.length():
				mapped.append(rep.unicode_at(k))
		else:
			mapped.append(c)
	var composed := PackedInt32Array()
	var n: int = mapped.size()
	var i2: int = 0
	while i2 < n:
		var c2: int = mapped[i2]
		if i2 + 1 < n and ((c2 >= 0x41 and c2 <= 0x5A) or (c2 >= 0x61 and c2 <= 0x7A)) and _ACCENT.has(mapped[i2 + 1]) \
				and String(_ACCENT[mapped[i2 + 1]]).contains(String.chr(c2)):
			if c2 == 0x49 and mapped[i2 + 1] == 0x307:
				composed.append(0x69)   # I + dot above composes to İ, whose lower() is i + U+0307: "i" and a space
			composed.append(0x20)   # the composed letter is not a-z: a space
			i2 += 2
			continue
		composed.append(c2)
		i2 += 1
	# 2. lower case, quotes, dashes
	var s := PackedInt32Array()
	for c3 in composed:
		var c4: int = c3
		if c4 >= 0x41 and c4 <= 0x5A:
			c4 += 0x20
		elif c4 == 0x2019 or c4 == 0x2018 or c4 == 0x60:
			c4 = 0x27
		elif c4 == 0x2D or c4 == 0x2013 or c4 == 0x2014:
			c4 = 0x20
		s.append(c4)
	# 3. thousands comma: (?<=\d),(?=\d{3}\b)
	var kept := PackedInt32Array()
	var m: int = s.size()
	for k2 in m:
		var ch: int = s[k2]
		if ch == 0x2C and k2 > 0 and _is_digit(s[k2 - 1]) \
				and _thousands_follow(s, k2 + 1):
			continue
		kept.append(ch)
	# 4. everything but a-z 0-9 ' becomes a space
	var out := PackedInt32Array()
	for ch2 in kept:
		if (ch2 >= 0x61 and ch2 <= 0x7A) or (ch2 >= 0x30 and ch2 <= 0x39) or ch2 == 0x27:
			out.append(ch2)
		else:
			out.append(0x20)
	return out


## three digits at s[from..from+2] and then a non-word character or the end
static func _thousands_follow(s: PackedInt32Array, from: int) -> bool:
	if from + 3 > s.size():
		return false
	for k in 3:
		if not _is_digit(s[from + k]):
			return false
	if from + 3 == s.size():
		return true
	return not _is_word(s[from + 3])


static func _is_digit(c: int) -> bool:
	return c >= 0x30 and c <= 0x39


static func _is_word(c: int) -> bool:
	if c < 0x80:
		return (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A) or c == 0x5F
	var k: int = 0
	while k < _NONWORD.size():
		if c >= int(_NONWORD[k]) and c <= int(_NONWORD[k + 1]):
			return false
		k += 2
	return true


static func _build_nfkc() -> void:
	var m: Dictionary = {}
	for r in _NFKC_RUNS:
		var base: int = String(r[2]).unicode_at(0)
		for c in range(int(r[0]), int(r[1]) + 1):
			m[c] = String.chr(base + c - int(r[0]))
	for c in _NFKC_ONE:
		m[int(c)] = String(_NFKC_ONE[c])
	_nfkc_map = m


static func _strip_apos(s: String) -> String:
	var a: int = 0
	var b: int = s.length()
	while a < b and s.unicode_at(a) == 0x27:
		a += 1
	while b > a and s.unicode_at(b - 1) == 0x27:
		b -= 1
	return s.substr(a, b - a)


static func _expand_contraction(w: String) -> Array:
	if _CONTR.has(w):
		return Array(String(_CONTR[w]).split(" ", false))
	if w.ends_with("n't") and w.length() > 3:
		return [w.substr(0, w.length() - 3), "not"]
	for sf in _CONTR_SUFFIXES:
		var suf: String = sf[0]
		if w.ends_with(suf) and w.length() > suf.length():
			return [w.substr(0, w.length() - suf.length()), sf[1]]
	if w.ends_with("'s") and w.length() > 2:
		var base: String = w.substr(0, w.length() - 2)
		return [base, "is"] if _S_IS.has(base) else [base]
	return [w.replace("'", "")] if w.ends_with("'") else [w]


## server _num_words: a word of 1..9 digits becomes the English words of the number (num2words), anything else stays
static func _num_words(w: String) -> Array:
	var n: int = w.length()
	if n == 0 or n > 9:
		return [w]
	for i in n:
		if not _is_digit(w.unicode_at(i)):
			return [w]
	var txt: String = String(_nw(int(w))[0])
	var clean: String = ""
	for i in txt.length():
		var c: int = txt.unicode_at(i)
		clean += String.chr(c) if ((c >= 0x61 and c <= 0x7A) or c == 0x20) else " "
	return Array(clean.split(" ", false))


@warning_ignore("integer_division")
static func _nw(value: int) -> Array:
	for card in _CARDS:
		var elem: int = card[0]
		if elem > value:
			continue
		var div: int = 1
		var mod: int = 0
		if value != 0:
			div = value / elem
			mod = value % elem
		var left: Array = ["one", 1] if div == 1 else _nw(div)
		var res: Array = _merge(left, [card[1], elem])
		if mod != 0:
			res = _merge(res, _nw(mod))
		return res
	return ["zero", 0]


static func _merge(l: Array, r: Array) -> Array:
	var ltext: String = l[0]
	var lnum: int = l[1]
	var rtext: String = r[0]
	var rnum: int = r[1]
	if lnum == 1 and rnum < 100:
		return [rtext, rnum]
	elif 100 > lnum and lnum > rnum:
		return ["%s-%s" % [ltext, rtext], lnum + rnum]
	elif lnum >= 100 and 100 > rnum:
		return ["%s and %s" % [ltext, rtext], lnum + rnum]
	elif rnum > lnum:
		return ["%s %s" % [ltext, rtext], lnum * rnum]
	return ["%s, %s" % [ltext, rtext], lnum + rnum]


# ================================================================================================ words
static func _clean_words(words: Variant) -> Array:
	var out: Array = []
	if not (words is Array):
		return out
	var prev_start: float = 0.0
	for it in (words as Array):
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		if not d.has("w"):
			continue
		var wv: Variant = d["w"]
		var w: String = wv if wv is String else str(wv)
		var p: float = _num_or(d.get("p", 0.0), 0.0)
		p = 0.0 if is_nan(p) else clampf(p, 0.0, 1.0)
		var st: float = _num_or(d.get("start", prev_start), prev_start)
		if is_nan(st) or is_inf(st):
			st = prev_start
		st = maxf(st, prev_start)
		var en: float = _num_or(d.get("end", st), st)
		if is_nan(en) or is_inf(en):
			en = st
		en = maxf(en, st)
		prev_start = st
		out.append({"w": w, "p": p, "start": st, "end": en})
	return out


static func _num_or(v: Variant, fallback: float) -> float:
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return float(v)
	return fallback


static func _final_score(accuracy: float, clarity: float, fluency: int) -> int:
	return _round_int(0.6 * accuracy + 0.25 * clarity + 0.15 * float(fluency))


static func _empty_score(units: Array) -> Dictionary:
	return {"transcript": "", "score": 0, "accuracy": 0, "clarity": 0, "fluency": 0, "units": units, "tips_ko": [NO_VOICE_TIP]}


static func _mismatch_tip(text: String) -> String:
	return "목표 문장과 많이 다르게 들렸어요 (들린 문장: \"%s\"). 화면의 문장을 보면서 천천히 또박또박 따라 읽어 보세요." % [text]


# ================================================================================================ tips
static func _en_tokens(w: String) -> Array:
	var out: Array = []
	var n: int = w.length()
	var i: int = 0
	while i < n:
		var c: int = w.unicode_at(i)
		var two: String = w.substr(i, 2)
		if two == "th" or two == "sh" or two == "ch" or two == "ee" or two == "ea" or two == "oo":
			out.append(two)
			i += 2
		elif c >= 0x61 and c <= 0x7A:
			out.append(String.chr(c))
			i += 1
		else:
			i += 1
	return out


## server en_tip_for_pair: [category, tip] or null
static func _en_tip_for_pair(t: String, h: String) -> Variant:
	var ta: Array = _en_tokens(t)
	var hb: Array = _en_tokens(h)
	var blocks: Array = _matching_blocks(ta, hb, false)
	for op in _opcodes(blocks, ta.size(), hb.size()):
		if op[0] == "replace":
			var a: String = "".join(PackedStringArray(ta.slice(int(op[1]), int(op[2]))))
			var b: String = "".join(PackedStringArray(hb.slice(int(op[3]), int(op[4]))))
			var key: String = a + "|" + b
			if _EN_RULES.has(key):
				var rule: Array = _EN_RULES[key]
				return [rule[0], "'%s'가 '%s'로 들렸어요. %s" % [t, h, rule[1]]]
	# dropped final consonant(s)
	if h.length() < t.length() and t.begins_with(h) and t.length() - h.length() <= 2 and not _has_vowel(t.substr(h.length())):
		var tail: String = t.substr(h.length())
		if h.length() < 3:
			return null
		if tail == "s" or tail == "es":
			return ["final", "'%s'가 '%s'로 들렸어요. 끝의 복수형 s 소리가 빠졌어요. 단어 끝 s를 또렷하게 내 주세요." % [t, h]]
		if tail == "ed" or tail == "d":
			return ["final", "'%s'가 '%s'로 들렸어요. 끝의 -ed(d/t) 소리가 빠졌어요. 단어 끝 자음까지 살려서 발음해 주세요." % [t, h]]
		return ["final", "'%s'가 '%s'로 들렸어요. 단어 끝 자음 '%s'가 빠졌어요. 받침처럼 끝 자음까지 짧게 소리 내 주세요." % [t, h, tail]]
	return null


static func _has_vowel(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c == 0x61 or c == 0x65 or c == 0x69 or c == 0x6F or c == 0x75:
			return true
	return false


## server en_tips(units, fluency, clarity, lang_words); has_words = the word list is not empty
static func _en_tips(units: Array, fluency: int, clarity: float, has_words: bool) -> Array:
	var tips: Array = []
	var seen: Array = []
	var generic: Array = []
	for u in units:
		if bool(u["ok"]):
			continue
		var heard: Variant = u["heard"]
		if heard != null and not String(heard).is_empty():
			var r: Variant = null
			if word_sim(String(u["t"]), String(heard)) >= 0.5:
				r = _en_tip_for_pair(String(u["t"]), String(heard))
			if r != null:
				if not seen.has(r[0]):
					seen.append(r[0])
					tips.append(r[1])
				continue
			generic.append("'%s'가 '%s'로 들렸어요." % [u["t"], heard])
		else:
			generic.append("'%s'가 잘 들리지 않았어요." % [u["t"]])
	var out: Array = tips.slice(0, 3)
	if out.size() < 3 and not generic.is_empty():
		var missed: Array = []
		for u in units:
			if not bool(u["ok"]) and missed.size() < 4:
				missed.append(u["t"])
		if generic.size() == 1:
			out.append(String(generic[0]) + " 그 단어만 따로 천천히 연습한 뒤 문장으로 이어 보세요.")
		else:
			var quoted: Array = []
			for m in missed:
				quoted.append("'%s'" % [m])
			out.append("놓치거나 다르게 들린 단어: %s. 이 단어들을 먼저 따로 연습한 뒤 문장으로 이어 말해 보세요." % [", ".join(PackedStringArray(quoted))])
	out = out.slice(0, 3)
	if out.size() < 3 and fluency < 70 and has_words:
		out.append("말 속도나 멈춤이 고르지 않았어요. 문장을 한 호흡으로 자연스럽게 이어서 말해 보세요.")
	if out.size() < 3 and out.is_empty() and clarity < 70.0:
		out.append("전체적으로 또렷함이 조금 부족해요. 입을 크게 벌리고 단어 끝까지 또박또박 말해 보세요.")
	return out.slice(0, 3)


# ================================================================================================ difflib
static func _chars(s: String) -> Array:
	var out: Array = []
	for i in s.length():
		out.append(s.unicode_at(i))
	return out


## nw_align of the server (global alignment, sim = word_sim): list of [i or null, j or null]
static func _nw_align(a: Array, b: Array) -> Array:
	var n: int = a.size()
	var m: int = b.size()
	var gap: float = -0.5
	var sc: Array = []
	var bt: Array = []
	for i in n + 1:
		var row: Array = []
		var brow: Array = []
		row.resize(m + 1)
		brow.resize(m + 1)
		row.fill(0.0)
		brow.fill(0)
		sc.append(row)
		bt.append(brow)
	for i in range(1, n + 1):
		sc[i][0] = float(i) * gap
		bt[i][0] = 1
	for j in range(1, m + 1):
		sc[0][j] = float(j) * gap
		bt[0][j] = 2
	var memo: Dictionary = {}
	for i in range(1, n + 1):
		for j in range(1, m + 1):
			var key: String = String(a[i - 1]) + "\u0001" + String(b[j - 1])
			var sv: float
			if memo.has(key):
				sv = memo[key]
			else:
				sv = word_sim(String(a[i - 1]), String(b[j - 1]))
				memo[key] = sv
			var d: float = float(sc[i - 1][j - 1]) + ((sv - 0.45) if sv >= 0.3 else -1.1)
			var u: float = float(sc[i - 1][j]) + gap
			var l: float = float(sc[i][j - 1]) + gap
			var best: float = maxf(d, maxf(u, l))
			sc[i][j] = best
			bt[i][j] = 0 if best == d else (1 if best == u else 2)
	var i2: int = n
	var j2: int = m
	var out: Array = []
	while i2 > 0 or j2 > 0:
		var t: int = int(bt[i2][j2])
		if i2 > 0 and j2 > 0 and t == 0:
			out.append([i2 - 1, j2 - 1])
			i2 -= 1
			j2 -= 1
		elif i2 > 0 and (t == 1 or j2 == 0):
			out.append([i2 - 1, null])
			i2 -= 1
		else:
			out.append([null, j2 - 1])
			j2 -= 1
	out.reverse()
	return out


## SequenceMatcher(None, a, b, autojunk).get_matching_blocks() without the final (la, lb, 0) block: [[i, j, size], ...] sorted
@warning_ignore("integer_division")
static func _matching_blocks(a: Array, b: Array, autojunk: bool) -> Array:
	var la: int = a.size()
	var lb: int = b.size()
	if la == 0 or lb == 0:
		return []
	var b2j: Dictionary = {}
	for j in lb:
		var e: Variant = b[j]
		if b2j.has(e):
			(b2j[e] as Array).append(j)
		else:
			b2j[e] = [j]
	if autojunk and lb >= _AUTOJUNK_N:
		var ntest: int = int(lb / 100) + 1
		for e2 in b2j.keys():
			if (b2j[e2] as Array).size() > ntest:
				b2j.erase(e2)
	var queue: Array = [[0, la, 0, lb]]
	var found: Array = []
	while not queue.is_empty():
		var q: Array = queue.pop_back()
		var alo: int = q[0]
		var ahi: int = q[1]
		var blo: int = q[2]
		var bhi: int = q[3]
		var m: Array = _find_longest(a, b, b2j, alo, ahi, blo, bhi)
		var i: int = m[0]
		var j2: int = m[1]
		var k: int = m[2]
		if k > 0:
			found.append(m)
			if alo < i and blo < j2:
				queue.append([alo, i, blo, j2])
			if i + k < ahi and j2 + k < bhi:
				queue.append([i + k, ahi, j2 + k, bhi])
	found.sort_custom(func(x: Array, y: Array) -> bool:
		if x[0] != y[0]:
			return x[0] < y[0]
		if x[1] != y[1]:
			return x[1] < y[1]
		return x[2] < y[2])
	# join adjacent blocks
	var out: Array = []
	var i1: int = 0
	var j1: int = 0
	var k1: int = 0
	for blk in found:
		var i2: int = blk[0]
		var jj2: int = blk[1]
		var k2: int = blk[2]
		if i1 + k1 == i2 and j1 + k1 == jj2:
			k1 += k2
		else:
			if k1 > 0:
				out.append([i1, j1, k1])
			i1 = i2
			j1 = jj2
			k1 = k2
	if k1 > 0:
		out.append([i1, j1, k1])
	return out


static func _find_longest(a: Array, b: Array, b2j: Dictionary, alo: int, ahi: int, blo: int, bhi: int) -> Array:
	var besti: int = alo
	var bestj: int = blo
	var bestsize: int = 0
	var j2len: Dictionary = {}
	for i in range(alo, ahi):
		var newj2len: Dictionary = {}
		var js: Variant = b2j.get(a[i])
		if js != null:
			for jv in (js as Array):
				var j: int = jv
				if j < blo:
					continue
				if j >= bhi:
					break
				var k: int = int(j2len.get(j - 1, 0)) + 1
				newj2len[j] = k
				if k > bestsize:
					besti = i - k + 1
					bestj = j - k + 1
					bestsize = k
		j2len = newj2len
	# extend by equal items on each end (nothing is junk here, popular items included)
	while besti > alo and bestj > blo and a[besti - 1] == b[bestj - 1]:
		besti -= 1
		bestj -= 1
		bestsize += 1
	while besti + bestsize < ahi and bestj + bestsize < bhi and a[besti + bestsize] == b[bestj + bestsize]:
		bestsize += 1
	return [besti, bestj, bestsize]


## get_opcodes: [[tag, i1, i2, j1, j2], ...]
static func _opcodes(blocks: Array, la: int, lb: int) -> Array:
	var i: int = 0
	var j: int = 0
	var out: Array = []
	var all: Array = blocks.duplicate()
	all.append([la, lb, 0])
	for blk in all:
		var ai: int = blk[0]
		var bj: int = blk[1]
		var size: int = blk[2]
		var tag: String = ""
		if i < ai and j < bj:
			tag = "replace"
		elif i < ai:
			tag = "delete"
		elif j < bj:
			tag = "insert"
		if tag != "":
			out.append([tag, i, ai, j, bj])
		i = ai + size
		j = bj + size
		if size > 0:
			out.append(["equal", i - size, i, j - size, j])
	return out
