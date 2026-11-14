class_name DiaryLogic
extends RefCounted
## 한 줄 일기의 순수 규칙 (노드·저장소·네트워크 없음). 설계 docs/v170_design.md §2.4.
##   split()      글을 문장으로 나눈다 (일본어 。！？!?, 영어 .!?, 줄바꿈).
##   check_input()  쓴 글을 검사해 거절 사유를 한국어 안내용 코드로 돌려준다.
##   clean_fix()  AI 가 돌려준 교정(/fix 응답)을 믿기 전에 검증·정리한다.
##   cards_for()  고친 문장을 복습 카드로 만든다 (원문은 어떤 필드에도 넣지 않는다).
##   date_label() "2026-11-14" -> "11월 14일 (토)".
## 일기 원문은 print / push_warning 으로 내보내지 않는다 (이 파일은 아무것도 출력하지 않는다).

const MAX_CHARS := 300
const MAX_SENTENCES := 3
const MAX_SENTENCE_CHARS := 120
const CARDS_PER_ENTRY := 3
const CARDS_PER_DAY := 5
const MAX_FIX_CHARS := 300
const MAX_WHY_CHARS := 200
const MAX_READING_CHARS := 300
const DEFAULT_WHY := "더 자연스럽게 고쳤어요."
## 일기에서 만든 복습 카드의 note. 항상 이 고정 문구다: AI 의 이유(why)는 원문을 인용할 수 있어서 카드에 넣지 않는다.
const CARD_NOTE := "일기에서 고친 문장"
const WEEKDAYS := ["일", "월", "화", "수", "목", "금", "토"]

const _TERMS_JA := "。！？!?"
const _TERMS_EN := ".!?"
const _TERMS_ALL := "。！？!?."
const _OPEN := "「『（(【[“"
const _CLOSE := "」』）)】]”"
const _TRAIL := "」』）)】]”\"'’"
const _PUNCT := ".!?。！？…、,，．・「」『』（）()[]【】\"'“”‘’〜~-—:;：；"
const _EN_ABBR := ["mr", "mrs", "ms", "dr", "prof", "vs", "jr", "sr"]


# ---------------------------------------------------------------- characters

static func is_hangul(cp: int) -> bool:
	return (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0x1100 and cp <= 0x11FF) or (cp >= 0x3130 and cp <= 0x318F)


## 일본어 글자: 히라가나·가타카나·한자 (ー 하나만으로는 글자로 세지 않는다).
static func is_ja_char(cp: int) -> bool:
	return (cp >= 0x3041 and cp <= 0x3096) or cp == 0x309D or cp == 0x309E \
		or (cp >= 0x30A1 and cp <= 0x30FA) or cp == 0x30FD or cp == 0x30FE or (cp >= 0x31F0 and cp <= 0x31FF) \
		or (cp >= 0xFF66 and cp <= 0xFF9D) \
		or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or cp == 0x3005


static func is_en_char(cp: int) -> bool:
	return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)


## 목표 언어의 글자 수 (ja: 가나·한자, en: 알파벳).
static func target_chars(s: String, lang: String) -> int:
	var n := 0
	for i in s.length():
		var cp: int = s.unicode_at(i)
		if (lang == "ja" and is_ja_char(cp)) or (lang == "en" and is_en_char(cp)):
			n += 1
	return n


static func hangul_chars(s: String) -> int:
	var n := 0
	for i in s.length():
		if is_hangul(s.unicode_at(i)):
			n += 1
	return n


# ---------------------------------------------------------------- split

static func _trim(s: String) -> String:
	var a := 0
	var b: int = s.length()
	while a < b and (s[a] == " " or s[a] == "\t" or s[a] == "　" or s[a] == " "):
		a += 1
	while b > a and (s[b - 1] == " " or s[b - 1] == "\t" or s[b - 1] == "　" or s[b - 1] == " "):
		b -= 1
	return s.substr(a, b - a)


static func _is_space(c: String) -> bool:
	return c == " " or c == "\t" or c == "　" or c == " "


## 문장 부호·공백뿐이면 빈 문장으로 본다.
static func _has_content(s: String) -> bool:
	for i in s.length():
		var c: String = s[i]
		if not _is_space(c) and _PUNCT.find(c) == -1:
			return true
	return false


## 영어 '.' 가 문장 끝인가: 바로 뒤에 글자·숫자가 붙으면(3.5, file.txt, e.g.) 끝이 아니고, 약어(Mr. 등)도 아니다.
static func _en_dot_ends(text: String, i: int) -> bool:
	if i + 1 < text.length():
		var nx: String = text[i + 1]
		if not _is_space(nx) and nx != "\n" and nx != "\r" and _TRAIL.find(nx) == -1 and _TERMS_ALL.find(nx) == -1:
			return false
	var j: int = i - 1
	var word := ""
	while j >= 0 and text[j].unicode_at(0) < 128 and is_en_char(text[j].unicode_at(0)):
		word = text[j] + word
		j -= 1
	if _EN_ABBR.has(word.to_lower()) and (i + 1 < text.length()):
		return false
	# p.m. / e.g. : 글자 + 점 + 글자 + 점
	if i >= 3 and text[i - 1] != "." and text[i - 2] == "." and is_en_char(text[i - 1].unicode_at(0)):
		return false
	return true


## 글을 문장으로 나눈다. 끝 부호(와 따라오는 닫는 따옴표·괄호)는 그 문장에 붙고, 빈 문장은 버린다.
## 「…。」 처럼 따옴표 안의 부호에서는 나누지 않는다. 줄바꿈은 항상 문장 끝이다.
static func split(text: String, lang: String) -> Array:
	var out: Array = []
	var terms: String = _TERMS_JA if lang == "ja" else _TERMS_EN
	var cur := ""
	var depth := 0
	var n: int = text.length()
	var i := 0
	while i < n:
		var c: String = text[i]
		if c == "\n" or c == "\r":
			_push(out, cur)
			cur = ""
			depth = 0
			i += 1
			continue
		cur += c
		if _OPEN.find(c) != -1:
			depth += 1
		elif _CLOSE.find(c) != -1:
			depth = maxi(0, depth - 1)
			# 영어는 “Hi.” 처럼 닫는 따옴표 앞이 문장 끝이면 거기서 끊는다 (일본어는 「…。」と言った。 처럼 이어진다)
			if depth == 0 and lang == "en" and cur.length() >= 2 and _TERMS_ALL.find(cur[cur.length() - 2]) != -1 \
					and (i + 1 >= n or _is_space(text[i + 1])):
				_push(out, cur)
				cur = ""
		elif depth == 0 and terms.find(c) != -1 and (lang == "ja" or c != "." or _en_dot_ends(text, i)):
			var j: int = i + 1
			while j < n and (terms.find(text[j]) != -1 or _TRAIL.find(text[j]) != -1):
				cur += text[j]
				j += 1
			_push(out, cur)
			cur = ""
			i = j
			continue
		i += 1
	_push(out, cur)
	return out


static func _push(out: Array, s: String) -> void:
	var t: String = _trim(s)
	if t != "" and _has_content(t):
		out.append(t)


# ---------------------------------------------------------------- check_input

## {"ok": bool, "reason": "" | "empty" | "too_long" | "too_many" | "sentence_long" | "wrong_lang", "sentences": Array}
## 검사 순서: 빈 글 -> 300자 초과 -> 4문장 이상 -> 한 문장 120자 초과 -> 목표 언어 글자가 없거나 한글이 더 많음.
static func check_input(text: String, lang: String) -> Dictionary:
	var t: String = _trim(DiaryStore.clean_text(text))
	if t == "":
		return {"ok": false, "reason": "empty", "sentences": []}
	if t.length() > MAX_CHARS:
		return {"ok": false, "reason": "too_long", "sentences": []}
	var sents: Array = split(t, lang)
	if sents.is_empty():
		return {"ok": false, "reason": "empty", "sentences": []}
	if sents.size() > MAX_SENTENCES:
		return {"ok": false, "reason": "too_many", "sentences": sents}
	for s in sents:
		if (s as String).length() > MAX_SENTENCE_CHARS:
			return {"ok": false, "reason": "sentence_long", "sentences": sents}
	var tc: int = target_chars(t, lang)
	if tc == 0 or hangul_chars(t) > tc:
		return {"ok": false, "reason": "wrong_lang", "sentences": sents}
	return {"ok": true, "reason": "", "sentences": sents}


## 거절 사유 -> 화면에 보일 한국어 안내.
static func reason_text(reason: String, lang: String) -> String:
	var name: String = "일본어" if lang == "ja" else "영어"
	match reason:
		"empty":
			return "일기를 한 줄 이상 써 주세요."
		"too_long":
			return "일기는 %d자까지 쓸 수 있어요." % MAX_CHARS
		"too_many":
			return "일기는 %d문장까지 쓸 수 있어요." % MAX_SENTENCES
		"sentence_long":
			return "한 문장이 너무 길어요. %d자 안으로 나눠 써 주세요." % MAX_SENTENCE_CHARS
		"wrong_lang":
			return "%s로 써 주세요. 한국어로 쓴 글은 고칠 수 없어요." % name
	return ""


# ---------------------------------------------------------------- clean_fix

static func _one_line(s: String) -> String:
	var out := ""
	for i in s.length():
		var cp: int = s.unicode_at(i)
		if cp == 9 or cp == 10 or cp == 13 or cp == 0x2028 or cp == 0x2029:
			out += " "
		elif cp < 32 or cp == 127 or (cp >= 0x80 and cp < 0xA0):
			continue
		else:
			out += s[i]
	while out.contains("  "):
		out = out.replace("  ", " ")
	return _trim(out)


static func _str_or(v: Variant) -> String:
	if v is String:
		return v
	return ""


## AI 가 돌려준 교정(resp: /fix 응답 {fix, fix_ko, reading, pron})을 검증·정리한다.
## 돌려주는 값: {"orig", "fix", "why", "reading", "pron", "same": bool, "bad": bool}
##  - 사전이 아니거나 fix 가 문자열이 아니면 bad (fix 는 "").
##  - fix 는 한 줄(줄바꿈·제어 문자 제거), 300자까지(넘으면 자름). 영어는 한글 없음, 일본어는 가나·한자가 있고 한글 없음.
##  - len(fix) <= 3 * len(orig) + 20 (AI 가 내용을 지어내는 것 차단), 넘으면 bad.
##  - fix 가 비었거나 원문과 TextSim.norm_text 로 같으면 same (고칠 곳 없음).
##  - 원문에 없는 링크(://)나 코드 블록(```)이 든 fix 는 bad.
##  - why 는 200자까지, 비었으면 기본 문구. bad 는 카드에 넣지 않는다.
static func clean_fix(orig: String, resp: Variant, lang: String) -> Dictionary:
	var res := {"orig": orig, "fix": "", "why": "", "reading": "", "pron": "", "same": false, "bad": true}
	if not (resp is Dictionary):
		return res
	var d: Dictionary = resp
	if not (d.get("fix", null) is String):
		return res
	var fix: String = _one_line(d["fix"])
	var why: String = _one_line(_str_or(d.get("fix_ko", d.get("why", ""))))
	if why == "":
		why = _one_line(_str_or(d.get("why", "")))
	if fix == "":
		res["bad"] = false
		res["same"] = true
		return res
	if lang != "en" and lang != "ja":
		return res
	if hangul_chars(fix) > 0:
		return res
	if lang == "ja" and target_chars(fix, "ja") == 0:
		return res
	if lang == "en" and target_chars(fix, "en") == 0:
		return res
	if fix.length() > 3 * orig.length() + 20:
		return res
	if (fix.contains("://") and not orig.contains("://")) or (fix.contains("```") and not orig.contains("```")):
		return res
	res["bad"] = false
	if fix.length() > MAX_FIX_CHARS:
		fix = _trim(fix.substr(0, MAX_FIX_CHARS))
	res["fix"] = fix
	if TextSim.norm_text(fix, lang) == TextSim.norm_text(orig, lang):
		res["same"] = true
		res["fix"] = fix
		return res
	if why == "":
		why = DEFAULT_WHY
	if why.length() > MAX_WHY_CHARS:
		why = _trim(why.substr(0, MAX_WHY_CHARS))
	res["why"] = why
	if lang == "ja":
		res["reading"] = _clean_reading(_str_or(d.get("reading", "")))
		res["pron"] = _cap(_one_line(_str_or(d.get("pron", ""))), MAX_READING_CHARS)
	return res


static func _cap(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n)


# ---------------------------------------------------------------- cards

## 일기 한 개에서 복습 카드로 넣을 것: [{lang, target, reading, ko, note}].
## 고친 문장만. 카드 필드는 lang(일기의 언어), target(고친 문장), reading(고친 문장의 읽기, 히라가나만), ko("" 고정), note(CARD_NOTE 고정 문구)뿐이라
## 원문과 AI 의 이유(why)는 어디에도 들어가지 않는다. same·bad·이미 카드가 된 것·빈 fix 는 뺀다.
## 일기당 CARDS_PER_ENTRY 개, 하루 CARDS_PER_DAY 개(today_cards = 오늘 이미 넣은 수)까지. 순수 함수:
## 설정 auto_fix_cards 가 꺼졌는지는 부르는 쪽이 본다.
static func cards_for(entry: Dictionary, today_cards: int) -> Array:
	var out: Array = []
	var lang: String = str(entry.get("lang", ""))
	if lang != "en" and lang != "ja":
		return out
	var items: Variant = entry.get("items", [])
	if not (items is Array):
		return out
	var room: int = mini(CARDS_PER_ENTRY, CARDS_PER_DAY - maxi(0, today_cards))
	var seen := {}
	for it in items:
		if out.size() >= room:
			break
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		if DiaryStore.as_bool(d.get("same", false)) or DiaryStore.as_bool(d.get("bad", false)) or DiaryStore.as_bool(d.get("card", false)):
			continue
		var fix: String = _str_or(d.get("fix", "")).strip_edges()
		if fix == "":
			continue
		var key: String = TextSim.norm_text(fix, lang)
		if key == "" or seen.has(key):
			continue
		var orig: String = _str_or(d.get("orig", "")).strip_edges()
		if orig != "" and TextSim.norm_text(orig, lang) == key:
			continue ## nothing was fixed (the stored `same` flag may be wrong in a hand-edited file)
		seen[key] = true
		# every field is either the fixed sentence, its reading (checked: kana only), or a constant: nothing from the original
		var reading: String = ""
		if lang == "ja":
			reading = _clean_reading(_str_or(d.get("reading", "")))
		out.append({"lang": lang, "target": fix, "reading": reading, "ko": "", "note": CARD_NOTE})
	return out


## A reading is hiragana (and ー, digits, spaces, marks) only. Anything else (kanji, Latin letters, Hangul...) is not a reading
## and is dropped, so a reading field can not carry a piece of the original text.
static func _clean_reading(s: String) -> String:
	var t: String = _one_line(s)
	if t.length() > MAX_READING_CHARS:
		return ""
	for i in t.length():
		var cp: int = t.unicode_at(i)
		var kana: bool = (cp >= 0x3041 and cp <= 0x3096) or cp == 0x309D or cp == 0x309E or cp == 0x30FC
		var digit: bool = cp >= 0x30 and cp <= 0x39
		if not (kana or digit or _is_space(t[i]) or _PUNCT.find(t[i]) != -1):
			return ""
	return t


# ---------------------------------------------------------------- date

## "2026-11-14" -> "11월 14일 (토)". 잘못된 날짜는 "".
static func date_label(iso: String) -> String:
	if not Plan.is_valid_iso(iso):
		return ""
	var days: int = Plan.iso_to_days(iso)
	var c: Dictionary = Plan.civil_from_days(days)
	return "%d월 %d일 (%s)" % [int(c["month"]), int(c["day"]), WEEKDAYS[Plan.weekday(days)]]
