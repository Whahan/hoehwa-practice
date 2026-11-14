class_name MissionText
extends RefCounted
## Japanese mission text normalisation (design v1.7.0 sec 2.3.1 / 2.3.3). Pure functions, no state, no I/O.
## `norm_ja(text)` must give the same string as backend/missions.py `normalize_ja` (the PC rule engine) for every input
## the golden file tests (godot/tests/fixtures/mission_golden.json, "ja_*" keys), which is the same rule list:
##   1. first 300 characters   2. NFKC   3. lower case   4. katakana -> hiragana (U+30A1..30F6 minus 0x60, ヽ -> ゝ, ヾ -> ゞ)
##   5. keep only hiragana (U+3041..3096, 309D, 309E), ー (30FC), kanji (4E00..9FFF, 3400..4DBF), 々 (3005), 〇 (3007), a-z, 0-9
##      (spaces, punctuation and symbols are DELETED, not turned into spaces)   6. cut to 300 characters AGAIN at the end
## Two rules are not in the server docstring but are in its code: the cut in 6, and U+30F7..30FA (ヷヸヹヺ, which NFKC makes
## from ワヰヱヲ + a voicing mark) are not kept, because the katakana range of 4 stops at U+30F6.
##
## NFKC is not in GDScript, so only a SUBSET is built (see _expand):
##   - full-width ASCII U+FF01..FF5E -> ASCII, U+3000 -> space
##   - half-width katakana U+FF66..FF9F -> full-width, with the voicing marks ﾞ ﾟ (U+FF9E, FF9F -> U+3099, 309A)
##   - kana + U+3099 / U+309A are composed (か + ゛ -> が, ウ + ゛ -> ヴ, ワ + ゛ -> ヷ, は + ゜ -> ぱ ...), as NFC/NFKC do
##   - ゟ -> より, ヿ -> コト, K (Kelvin) -> k, İ -> i (the characters whose NFKC / lower() ends in kept letters)
##   - the compat characters that end in ASCII letters and digits (ordinals, superscripts, subscripts, circled digits and
##     letters, fractions, ligatures, (tm)); the same set as LocalMissions.NFKC_MAP
## KNOWN DIFFERENCES (everything else NFKC does is NOT built; the golden file does not contain them; mission_text_test lists
## a sample of them as "known gaps" and asserts that they still differ, so the list cannot go stale unnoticed):
##   ㈱ -> 株, ㌔ -> キロ, ㎏ -> kg, Roman numerals Ⅳ -> iv, CJK compatibility ideographs (U+F900.. 豈) and Kangxi radicals
##   (U+2F00..) -> unified kanji, mathematical alphanumerics (𝐀), enclosed CJK (㊤), a Latin letter + a combining accent
##   (e + U+0301, NFKC makes the letter é, which is deleted; here the e stays), parenthesised / dotted digits (⑴ ⒈).
##   A kana and U+3099 / U+309A with another combining mark between them (ヲ U+302E U+3099: NFC reorders the marks and composes
##   ヺ, which is deleted; here only a kana directly followed by the mark is composed). Every single code point U+0000..2FFFF
##   was compared with the PC (scratch run, 2657 differ, all of the kinds above); strings without those characters: 0 differences.
## Contract for other files (MissionLogic in B4): `MissionText.norm_ja(text: String) -> String`, never null, "" when nothing is kept.

const MAX_TEXT := 300
const _KATA_TO_HIRA := 0x60

## half-width katakana U+FF66..FF9D in order (56 characters); FF9E and FF9F are the voicing marks, FF61..FF65 are punctuation.
const _HW_KANA := "ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン"

## voiceable kana (hiragana forms); the voiced letter is the next code point (は行: ば = は + 1, ぱ = は + 2).
const _VOICEABLE := "かきくけこさしすせそたちつてとはひふへほ"
const _HANDAKU := "はひふへほ"

## Code point -> replacement for the compat characters that end in ASCII (upper case is lowered later) or kana.
const _COMPAT := {
	0x00AA: "a", 0x00BA: "o", 0x2071: "i", 0x207F: "n",
	0x00B9: "1", 0x00B2: "2", 0x00B3: "3",
	0x2070: "0", 0x2074: "4", 0x2075: "5", 0x2076: "6", 0x2077: "7", 0x2078: "8", 0x2079: "9",
	0x2080: "0", 0x2081: "1", 0x2082: "2", 0x2083: "3", 0x2084: "4",
	0x2085: "5", 0x2086: "6", 0x2087: "7", 0x2088: "8", 0x2089: "9",
	0x2460: "1", 0x2461: "2", 0x2462: "3", 0x2463: "4", 0x2464: "5",
	0x2465: "6", 0x2466: "7", 0x2467: "8", 0x2468: "9", 0x2469: "10",
	0x00BC: "14", 0x00BD: "12", 0x00BE: "34",             # the fraction slash U+2044 is deleted
	0x2122: "TM",
	0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
	0x212A: "K", 0x0130: "i",                              # Kelvin sign; capital dotted I (lower() gives i + U+0307)
	0x309F: "より", 0x30FF: "コト",                         # ゟ ヿ (compat digraphs)
	0x309B: " ", 0x309C: " ",                                 # spacing voicing marks: NFKC gives space + combining mark (a space here, so no composition)
}

static var _compose_map: Dictionary = {}


## The Japanese rule text of `text` (see the file header). Same string as backend/missions.py normalize_ja.
static func norm_ja(text: String) -> String:
	var src: String = text.substr(0, MAX_TEXT)
	var cps: PackedInt32Array = _compose(_expand(src))
	var out: String = ""
	for c in cps:
		if c >= 0x41 and c <= 0x5A:                  # lower case (A-Z only; the other upper case letters are deleted anyway)
			c += 0x20
		if c >= 0x30A1 and c <= 0x30F6:              # katakana -> hiragana
			c -= _KATA_TO_HIRA
		elif c == 0x30FD:
			c = 0x309D
		elif c == 0x30FE:
			c = 0x309E
		if _keeps(c):
			out += String.chr(c)
	return out.substr(0, MAX_TEXT)


## True for the code points norm_ja keeps (after lower case and katakana folding).
static func _keeps(c: int) -> bool:
	return ((c >= 0x3041 and c <= 0x3096) or c == 0x309D or c == 0x309E or c == 0x30FC
		or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF) or c == 0x3005 or c == 0x3007
		or (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39))


## NFKC subset, step 1: one code point -> zero or more code points (no composition yet).
static func _expand(src: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in src.length():
		var c: int = src.unicode_at(i)
		if c >= 0xFF01 and c <= 0xFF5E:              # full-width ASCII
			out.append(c - 0xFEE0)
		elif c == 0x3000:
			out.append(0x20)
		elif c >= 0xFF66 and c <= 0xFF9D:            # half-width katakana -> full-width
			out.append(_HW_KANA.unicode_at(c - 0xFF66))
		elif c == 0xFF9E:                            # half-width voiced / semi-voiced mark -> combining marks
			out.append(0x3099)
		elif c == 0xFF9F:
			out.append(0x309A)
		elif c >= 0x24B6 and c <= 0x24CF:            # circled capital letters
			out.append(0x41 + c - 0x24B6)
		elif c >= 0x24D0 and c <= 0x24E9:            # circled small letters
			out.append(0x61 + c - 0x24D0)
		elif _COMPAT.has(c):
			var rep: String = _COMPAT[c]
			for j in rep.length():
				out.append(rep.unicode_at(j))
		else:
			out.append(c)
	return out


## NFKC subset, step 2: kana + U+3099 / U+309A -> the composed kana (the table is built once).
static func _compose(cps: PackedInt32Array) -> PackedInt32Array:
	if _compose_map.is_empty():
		_build_compose_map()
	var out := PackedInt32Array()
	var i: int = 0
	var n: int = cps.size()
	while i < n:
		var c: int = cps[i]
		if i + 1 < n and (cps[i + 1] == 0x3099 or cps[i + 1] == 0x309A):
			var key: int = cps[i + 1] * 0x200000 + c
			if _compose_map.has(key):
				out.append(int(_compose_map[key]))
				i += 2
				continue
		out.append(c)
		i += 1
	return out


static func _build_compose_map() -> void:
	var m: Dictionary = {}
	for k in _VOICEABLE.length():
		var h: int = _VOICEABLE.unicode_at(k)
		m[0x3099 * 0x200000 + h] = h + 1
		m[0x3099 * 0x200000 + h + _KATA_TO_HIRA] = h + 1 + _KATA_TO_HIRA
	for k in _HANDAKU.length():
		var h2: int = _HANDAKU.unicode_at(k)
		m[0x309A * 0x200000 + h2] = h2 + 2
		m[0x309A * 0x200000 + h2 + _KATA_TO_HIRA] = h2 + 2 + _KATA_TO_HIRA
	m[0x3099 * 0x200000 + 0x3046] = 0x3094           # う + ゛ -> ゔ
	m[0x3099 * 0x200000 + 0x30A6] = 0x30F4           # ウ + ゛ -> ヴ
	m[0x3099 * 0x200000 + 0x309D] = 0x309E           # ゝ + ゛ -> ゞ
	m[0x3099 * 0x200000 + 0x30FD] = 0x30FE           # ヽ + ゛ -> ヾ
	m[0x3099 * 0x200000 + 0x30EF] = 0x30F7           # ワ ヰ ヱ ヲ + ゛ -> ヷ ヸ ヹ ヺ (these four are deleted by norm_ja)
	m[0x3099 * 0x200000 + 0x30F0] = 0x30F8
	m[0x3099 * 0x200000 + 0x30F1] = 0x30F9
	m[0x3099 * 0x200000 + 0x30F2] = 0x30FA
	_compose_map = m
