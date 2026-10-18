class_name KanaHangul
extends RefCounted
## Kana (hiragana / katakana) -> Hangul sound spelling for learners who cannot read kana yet.
##   KanaHangul.to_hangul("こんにちは。")  ->  "콘니치와。"
## Pure functions, no scene or autoload access. Two inputs:
##   from_pron(pron)  the backend's `pron` field (katakana pronunciation form, ワタシワガクセーデス): exact, no guessing.
##   to_hangul(kana)  the `reading` field (HIRAGANA in spelling form: backend/server.py ja_reading, は stays は, を stays を,
##                    no spaces, 、。！？ kept, ___ kept), for places that have no pron (saved review cards, old data).
##                    The spelling form hides which は / へ is a particle and which vowel repeats are long, so this one is a
##                    heuristic (tests/kana_hangul_test.gd measures it on a corpus). Katakana input works in both.
##
## Rules (learner spelling, not the official Korean transcription):
##   - plain syllables from the BASE table, no word-initial voicing change (か카 / が가, た타 / だ다, ぱ파).
##   - ゃゅょ and small ぁぃぅぇぉ after a consonant kana: COMBO table (きゃ캬 しゃ샤 ちゃ챠 じゃ쟈 ファ파 ティ티 ウィ위 ヴァ바 ...);
##     the 요음 table of KanaData (kana practice) is the same (kana_hangul_test checks every KanaData entry).
##   - ん = final ㄴ on the previous syllable ("응" when there is nothing to attach to).
##   - っ = final on the previous syllable, chosen by the next sound: か行/が行 ㄱ, ぱ行 ㅂ, anything else ㅅ
##     (がっこう 각코-, いっぱい 입파이, ちょっと 촛토); ignored at the end / before a non-kana.
##   - long vowel: ー, and a vowel that repeats the previous vowel (ああ いい うう ええ おお, えい, おう) -> "-"
##     (せんせい 센세-, おかあさん 오카-산, コーヒー 코-히-).
##   - は as the topic particle -> 와, へ as the direction particle -> 에, を -> 오 (see _ha_particle / _he_particle:
##     the reading has no word boundaries, so this is a heuristic; every other は stays 하 and へ stays 헤).
##   - punctuation, digits, Latin letters, spaces and anything unknown pass through unchanged.

## hiragana -> Hangul syllable.
const BASE := {
	"あ": "아", "い": "이", "う": "우", "え": "에", "お": "오",
	"か": "카", "き": "키", "く": "쿠", "け": "케", "こ": "코",
	"が": "가", "ぎ": "기", "ぐ": "구", "げ": "게", "ご": "고",
	"さ": "사", "し": "시", "す": "스", "せ": "세", "そ": "소",
	"ざ": "자", "じ": "지", "ず": "즈", "ぜ": "제", "ぞ": "조",
	"た": "타", "ち": "치", "つ": "츠", "て": "테", "と": "토",
	"だ": "다", "ぢ": "지", "づ": "즈", "で": "데", "ど": "도",
	"な": "나", "に": "니", "ぬ": "누", "ね": "네", "の": "노",
	"は": "하", "ひ": "히", "ふ": "후", "へ": "헤", "ほ": "호",
	"ば": "바", "び": "비", "ぶ": "부", "べ": "베", "ぼ": "보",
	"ぱ": "파", "ぴ": "피", "ぷ": "푸", "ぺ": "페", "ぽ": "포",
	"ま": "마", "み": "미", "む": "무", "め": "메", "も": "모",
	"や": "야", "ゆ": "유", "よ": "요",
	"ら": "라", "り": "리", "る": "루", "れ": "레", "ろ": "로",
	"わ": "와", "ゐ": "이", "ゑ": "에", "を": "오",
	"ゔ": "부", "ゕ": "카", "ゖ": "케",
}

## two-kana combinations (consonant kana + small kana), keyed by the two hiragana.
const COMBO := {
	"きゃ": "캬", "きゅ": "큐", "きょ": "쿄", "ぎゃ": "갸", "ぎゅ": "규", "ぎょ": "교",
	"しゃ": "샤", "しゅ": "슈", "しょ": "쇼", "じゃ": "쟈", "じゅ": "쥬", "じょ": "죠",
	"ぢゃ": "쟈", "ぢゅ": "쥬", "ぢょ": "죠", "ちゃ": "챠", "ちゅ": "츄", "ちょ": "쵸",
	"にゃ": "냐", "にゅ": "뉴", "にょ": "뇨", "ひゃ": "햐", "ひゅ": "휴", "ひょ": "효",
	"びゃ": "뱌", "びゅ": "뷰", "びょ": "뵤", "ぴゃ": "퍄", "ぴゅ": "퓨", "ぴょ": "표",
	"みゃ": "먀", "みゅ": "뮤", "みょ": "묘", "りゃ": "랴", "りゅ": "류", "りょ": "료",
	"しぇ": "셰", "じぇ": "제", "ちぇ": "체", "いぇ": "예",
	"ふぁ": "파", "ふぃ": "피", "ふぇ": "페", "ふぉ": "포", "ふゅ": "퓨",
	"てぃ": "티", "とぅ": "투", "でぃ": "디", "どぅ": "두", "てゅ": "튜", "でゅ": "듀",
	"うぃ": "위", "うぇ": "웨", "うぉ": "워",
	"ゔぁ": "바", "ゔぃ": "비", "ゔぇ": "베", "ゔぉ": "보", "ゔゅ": "뷰",
	"つぁ": "차", "つぃ": "치", "つぇ": "체", "つぉ": "초",
	"すぃ": "시", "ずぃ": "지",
	"くぁ": "콰", "くぃ": "퀴", "くぇ": "퀘", "くぉ": "쿼",
	"ぐぁ": "과", "ぐぃ": "귀", "ぐぇ": "궤", "ぐぉ": "궈",
}

## a small kana that is not part of a COMBO is read as the full-size kana.
const SMALL := {
	"ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ", "ゎ": "わ",
}

const KA_GYO := "かきくけこがぎぐげごゕゖ" ## っ before these -> final ㄱ
const PA_GYO := "ぱぴぷぺぽ" ## っ before these -> final ㅂ
const I_ROW := "きしちにひみりぎじびぴ" ## い-row syllables: an い right after them is a long い in pron
const PARTICLE_LETTERS := "がにでをのもとはへ" ## a repeated vowel after one of these is usually a new word (がある にいく)
const SEPARATORS := " 　\t\n、。，．・…！？!?.,:;~〜「」『』（）()[]\"'" ## a は / へ right after one of these starts a word

## Final consonant offsets in a Hangul syllable block (Unicode: 0xAC00 + (lead * 21 + vowel) * 28 + final).
const FINAL_N := 4 ## ㄴ
const FINAL_K := 1 ## ㄱ
const FINAL_P := 17 ## ㅂ
const FINAL_S := 19 ## ㅅ

## Words that start with は (a は where one of these begins is not the particle).
const HA_WORDS := ["はいっ", "はいり", "はいる", "はいれ", "はなし", "はなす", "はなさ", "はなせ", "はなそ", "はたら", "はやく", "はやい", "はやめ",
	"はじめ", "はじま", "はしり", "はしる", "はしっ", "はしれ", "はずが", "はずだ", "はずで", "はずな", "はずは", "はらを", "はまに", "はこに", "はこを"]
## (unused by _ha_particle since the default became "particle": kept for the tests that name them)
const TOPIC_BEFORE := ["わたし", "ぼく", "おれ", "あなた", "これ", "それ", "あれ", "ここ", "そこ", "あそこ", "どこ", "だれ", "なに", "なん",
	"きょう", "あした", "きのう", "いま", "かれ", "かのじょ", "さん", "くん", "みなさん", "から", "まで", "より"]
## Sounds right after a topic は (…はどこですか, …はありません).
const TOPIC_AFTER := ["どこ", "どう", "どれ", "どの", "どち", "だれ", "なに", "なん", "いつ", "いくら", "です", "でし", "じゃ", "ありま"]
## Words that contain a non-particle へ in the middle (the position of へ inside the word is looked up).
const HE_WORDS := ["ちへい", "じへい", "あへん", "いへん", "ふへん", "おへそ"]


## Hangul spelling of a PRONUNCIATION form (the backend's `pron` field: katakana, ワタシワガクセーデス). Particles are already
## ワ / エ / オ there and long vowels are already ー (the backend also writes the verb 言う as ユー), so no heuristic is applied
## (テイマス stays 테이마스, オモウ 오모우, アイウエオ 아이우에오);
## only the plain イ of an adjective ending シイ (ムズカシイ) is written long (시-), like the ー of チーサイ.
static func from_pron(pron: String) -> String:
	return _convert(pron, true)


## Hangul spelling of the kana in `kana` (anything that is not kana is passed through unchanged). Takes the spelling-form
## hiragana `reading`; use from_pron when the backend sent a `pron` (exact).
static func to_hangul(kana: String) -> String:
	return _convert(kana, false)


static func _convert(kana: String, pron: bool) -> String:
	var total: int = kana.length()
	if total == 0:
		return ""
	var n: String = _to_hiragana(kana)
	if not pron:
		# 言う is read ゆう; いいえ has a long first vowel (same length: indexes still match `kana`)
		n = n.replace("という", "とゆう").replace("ういう", "うゆう").replace("いいえ", "いーえ")
		if n.begins_with("いう"):
			n = "ゆう" + n.substr(2)
	var parts := PackedStringArray()
	var last_v: String = "" ## vowel class (a i u e o) of the last syllable written, "" = none / just after a long mark
	var i: int = 0
	while i < total:
		var c: String = n[i]
		var syl: String = ""
		var step: int = 1
		var reset_v: bool = false ## particles are separate words: the next vowel never lengthens them
		if i + 1 < total and COMBO.has(c + n[i + 1]):
			syl = COMBO[c + n[i + 1]]
			step = 2
		else:
			if SMALL.has(c):
				c = SMALL[c]
			# pron marks every other long vowel with ー itself; only the イ of -シイ adjectives stays unmarked
			var lengthen: bool = (_is_long(last_v, c) and _long_ok(n, i)) if not pron else (c == "い" and i >= 1 and n[i - 1] == "し")
			if c in "あいうえお" and lengthen:
				parts.append("-")
				last_v = ""
				i += 1
				continue
			if c == "ー":
				parts.append("-")
				last_v = ""
				i += 1
				continue
			if c == "ん":
				if not _attach(parts, FINAL_N):
					parts.append("응")
				last_v = ""
				i += 1
				continue
			if c == "っ":
				var fin: int = _tsu_final(n, i + 1)
				if fin > 0:
					_attach(parts, fin)
				last_v = ""
				i += 1
				continue
			if not pron and c == "は" and kana[i] == "は" and _ha_particle(n, i):
				syl = "와"
				reset_v = true
			elif not pron and c == "へ" and kana[i] == "へ" and _he_particle(n, i):
				syl = "에"
				reset_v = true
			elif BASE.has(c):
				syl = BASE[c]
				reset_v = c == "を"
		if syl == "":
			parts.append(kana[i]) # not kana: unchanged
			last_v = ""
			i += 1
			continue
		parts.append(syl)
		last_v = "" if reset_v else _vowel_class(syl)
		i += step
	return "".join(parts)


## Katakana -> hiragana, one code point for one code point (same length, so indexes match the input).
static func _to_hiragana(s: String) -> String:
	var cps := PackedInt32Array()
	for i in s.length():
		var cp: int = s.unicode_at(i)
		if cp >= 0x30A1 and cp <= 0x30F6:
			cp -= 0x60
		cps.append(cp)
	return cps.to_byte_array().get_string_from_utf32()


## Vowel class of a Hangul syllable block (a i u e o) from its vowel part.
@warning_ignore("integer_division")
static func _vowel_class(syl: String) -> String:
	var v: int = ((syl.unicode_at(0) - 0xAC00) / 28) % 21
	match v:
		0, 2, 9: # ㅏ ㅑ ㅘ
			return "a"
		20, 16: # ㅣ ㅟ
			return "i"
		13, 17, 18: # ㅜ ㅠ ㅡ
			return "u"
		5, 7, 15: # ㅔ ㅖ ㅞ
			return "e"
		8, 12, 14: # ㅗ ㅛ ㅝ
			return "o"
	return ""


## True when vowel kana `c` only lengthens the previous vowel `last_v` (おう おお えい いい ああ うう ええ).
static func _is_long(last_v: String, c: String) -> bool:
	match c:
		"あ":
			return last_v == "a"
		"い":
			return last_v == "i" or last_v == "e"
		"う":
			return last_v == "u" or last_v == "o"
		"え":
			return last_v == "e"
		"お":
			return last_v == "o"
	return false


## Extra conditions for a repeated vowel at index i of `n` to be a long vowel in the spelling-form reading (the reading
## cannot tell, pron can): 思う / ている / ある / 聞いて read the vowels one by one.
static func _long_ok(n: String, i: int) -> bool:
	if i < 1:
		return true
	var pv: String = n[i - 1]
	var nx: String = n[i + 1] if i + 1 < n.length() else ""
	match n[i]:
		"う":
			if _ends_with_at(n, i, "おも"): # おもう
				return false
		"い":
			if (pv == "て" or pv == "で") and _verb_i(n, i):
				return false
			if pv == "い" or pv in I_ROW: # i + i is long in ちいさい おにいさん おおきい and -しい adjectives; いい きいて にいます are not
				return nx == "さ" or (pv == "き" and i >= 2 and n[i - 2] == "お") or (pv == "し" and (nx == "" or nx in "での。、よねかな？！"))
			if pv in PARTICLE_LETTERS and nx != "さ":
				return false
		"あ":
			if pv in PARTICLE_LETTERS: # がある / であった
				return false
		"え":
			if pv in PARTICLE_LETTERS and pv != "へ":
				return false
		"お":
			if pv in "がにでをのもはへ": # the honorific お after a particle (のおはなし); とお stays long (とおい)
				return false
	return true


## Is the い at index i, right after て / で, the verb いる / いく (ています ている ていた ていく ...)?
static func _verb_i(n: String, i: int) -> bool:
	var nx: String = n[i + 1] if i + 1 < n.length() else ""
	if nx == "" or nx in "るまたなてれくっ":
		return true
	if nx == "き":
		var n2: String = n[i + 2] if i + 2 < n.length() else ""
		return n2 != "" and n2 in "またてな"
	return false


## Adds final consonant `fin` (offset 1..27) to the last syllable written (skipping "-" marks) when that syllable has none.
static func _attach(parts: PackedStringArray, fin: int) -> bool:
	var j: int = parts.size() - 1
	while j >= 0 and parts[j] == "-":
		j -= 1
	if j < 0 or parts[j].length() != 1:
		return false
	var cp: int = parts[j].unicode_at(0)
	if cp < 0xAC00 or cp > 0xD7A3 or (cp - 0xAC00) % 28 != 0:
		return false
	parts[j] = String.chr(cp + fin)
	return true


## Final consonant for a っ that is followed (from index `at`) by the kana there; 0 = no kana follows (っ is dropped).
static func _tsu_final(n: String, at: int) -> int:
	if at >= n.length():
		return 0
	var x: String = n[at]
	if not (BASE.has(x) or SMALL.has(x)):
		return 0
	if x in KA_GYO:
		return FINAL_K
	if x in PA_GYO:
		return FINAL_P
	return FINAL_S


static func _is_kana(ch: String) -> bool:
	return BASE.has(ch) or SMALL.has(ch) or ch == "ん" or ch == "っ" or ch == "ー"


static func _ends_with_at(n: String, i: int, w: String) -> bool:
	return i >= w.length() and n.substr(i - w.length(), w.length()) == w


static func _starts_with_at(n: String, i: int, w: String) -> bool:
	return n.substr(i, w.length()) == w


## Is the hiragana は at index i (of `n`) the topic particle (read わ)? Default yes (it is by far the most common は);
## no at a word start, after another は, after を が も へ and the honorific お / ご, and where a word that starts with は
## begins (はいる はなす はたらく はやく はじめ ...). Without the backend's `pron` this is a heuristic.
static func _ha_particle(n: String, i: int) -> bool:
	if i <= 0:
		return false
	var pv: String = n[i - 1]
	if pv in SEPARATORS or pv == "は":
		return false
	if i + 1 >= n.length() or not _is_kana(n[i + 1]):
		return true
	var nx: String = n[i + 1]
	if nx in "んっーぁぃぅぇぉゃゅょ": # no word (and no particle) is followed by these
		return false
	if pv in "をがもへお" or (pv == "ご" and nx == "ん"): # ごはん, おはし
		return false
	if pv == "の" and i >= 2 and n[i - 2] in "こそあど": # このはこ
		return false
	for w in HA_WORDS:
		if _starts_with_at(n, i, w):
			return false
	return true


## Is the hiragana へ at index i the direction particle (read え)? No at a word start, after a particle letter
## (のへや) and before the stems of へや へん へた へび へそ へっ; へい only before the verb stems いき いく いこ いっ いか.
static func _he_particle(n: String, i: int) -> bool:
	if i <= 0:
		return false
	var pv: String = n[i - 1]
	if not _is_kana(pv) or pv == "ー" or pv in PARTICLE_LETTERS or pv == "や" or pv == "か":
		return false
	for w in HE_WORDS:
		var k: int = w.find("へ")
		if i - k >= 0 and n.substr(i - k, w.length()) == w:
			return false
	var nx: String = n[i + 1] if i + 1 < n.length() else ""
	if nx != "" and nx in "やんたびそっ":
		return false
	if nx == "い":
		for v in ["いき", "いく", "いこ", "いっ", "いか", "いけ"]:
			if _starts_with_at(n, i + 1, v):
				return true
		return false
	return true
