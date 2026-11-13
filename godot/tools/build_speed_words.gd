extends SceneTree
## 스피드 퀴즈 단어 목록 만들기 (읽기만 하는 도구: data/pack/* 를 읽고 data/speed_words.json 하나만 쓴다).
##   godot --headless --path <project> --script res://tools/build_speed_words.gd
## 마지막 줄: "speed_words: en=<N> ja=<M> bytes=<B>"  (실패하면 종료 코드 1)
## 결정적(deterministic): 같은 입력이면 파일이 바이트 단위로 같다(만든 날짜는 manifest.json 의 built 날짜를 쓴다).
## 규칙(docs/v160_fun_design.md §5.4):
##  - 영어: 레슨 은행 문장(build 정답 이어 붙임 · listen audio · fill 빈칸을 정답으로 채운 문장 · speak text)을
##    소문자 단어로 쪼개 gloss_en 에 있고(품사 명사/동사/형용사/부사, 뜻 1~12자) 처음 나온 달 m(1~12).
##  - 일본어: gloss_ja 표제어(2글자 이상 또는 한자 포함, 같은 품사·뜻 조건)가 그 달 문장 전체 문자열에
##    부분 문자열로 나오는 첫 달 m.
##  - v = 한국어 뜻 첫 조각의 어간(끝 "다"·"~" 제거)이 그 달 한국어 번역(ko / options[answer]) 어딘가에 들어 있으면 true.
##  - 같은 w 중복 제거, 정렬은 m 다음 gloss 순서(빈도순).
## 뜻 품질 표본 점검(설계 Q1-3)에서 일본어 30개 중 명백히 틀린 뜻이 3개를 넘어 규칙을 조였다(설계 §6.5 Q1-3 "도구 규칙을 조이고 다시"):
##  - 일본어: 한자가 없는 1~2글자 표제어(とう·かい·ラン·プレ …)는 레슨 build 문제의 단어 조각(정답 배열)과 똑같을 때만 넣는다
##    (부분 문자열 일치만으로는 "ありがとう" 속의 "とう" 같은 우연한 일치를 못 거른다).
##  - v(교차 확인)는 더 엄격하게: 어간이 2글자 이상이어야 한다(1글자 어간은 아무 번역에나 들어 있다).
##    일본어는 거기에 더해 그 달 문장 읽기(reading, 가타카나는 히라가나로 바꿔서)에 gloss 읽기(ipa)가 들어 있어야 한다
##    (착=ちゃく·원=いん 같은 한자 한 글자 음독 조각이 걸러진다).
##  - 일본어: 한자 한 글자 표제어는 v(교차 확인)를 통과하거나 "뜻 2글자 이상 + 읽기가 그 달 문장 읽기에 있음"일 때만 파일에 넣는다
##    ("会=회", "英=영" 처럼 음독 소리값이 뜻으로 적힌 경우가 많다).
## 뜻 오답 정리(Q1 fix, 검토에서 v=true 오답이 나왔다):
##  - DROP_WORDS: 뜻이 틀렸거나 확신이 없는 단어는 파일에서 아예 뺀다(en kobe=이름, ja 寝/書=들어, 慣れ=관련 …).
##  - FIX_KO    : 올바른 뜻을 확신할 수 있는 단어는 뜻을 바꾼다(바꾼 뜻으로 v 를 다시 계산한다).
##  - 영어 고유명사(문장 중간에서 늘 대문자로만 나오는 말: Tokyo·Kobe·Jackson …)는 v=false (EN_COMMON_CAPS 는 예외).
##  - 일본어 한자 한 글자 표제어는 앞뒤가 모두 한자가 아닌 자리에서 한 번이라도 나와야 v=true
##    (名·医·校 처럼 名前·医者·学校 의 조각일 뿐인 글자를 거른다).
##  v 가 아닌 단어는 파일에 남지만 SpeedPool.build 는 통과 단어가 모자랄 때만 섞는다(설계 §10 Q3).

const BANK_PATH := "res://data/pack/lesson_bank_%s.json"
const GLOSS_PATH := "res://data/pack/gloss_%s.json"
const MANIFEST_PATH := "res://data/pack/manifest.json"
const OUT_PATH := "res://data/speed_words.json"
const POS_OK := ["명사", "동사", "형용사", "부사"]
const KO_MAX := 12
const MONTHS := 12
const SPLIT_CHARS := ",·/;~"  # 뜻 조각 나누는 글자(SpeedPool.ko_tokens 와 같은 규칙)
## 뜻이 틀렸거나 확신이 없어 파일에서 뺀 단어(언어별). speed_words_test 가 이 상수를 읽어 파일에 없는지 확인한다.
const DROP_WORDS := {
	"en": ["kobe", "assembly", "championship", "taste", "web"],
	"ja": ["寝", "書", "慣れ", "入り", "出来"],
}
## 올바른 뜻이 확실해서 고친 단어(언어별 단어 -> 뜻). 파일에는 고친 뜻이 들어간다.
const FIX_KO := {
	"en": {"spoke": "말했다", "headache": "두통"},
	"ja": {"食べ物": "음식", "こないだ": "지난번", "きっと": "분명히", "テレビ": "텔레비전", "月曜": "월요일"},
}
## 늘 대문자로 나오지만 고유명사가 아닌 영어 단어(v=false 로 내리지 않는다).
const EN_COMMON_CAPS := ["sunday", "english", "vietnamese", "christmas", "tv", "university", "library", "internet"]


func _init() -> void:
	var langs := {}
	for l in ["en", "ja"]:
		var words := build_lang(l)
		if words.is_empty():
			printerr("speed_words: no words for ", l)
			quit(1)
			return
		langs[l] = words
	var text := serialize(langs, _built_date())
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("speed_words: cannot write ", OUT_PATH)
		quit(1)
		return
	f.store_string(text)
	f.close()
	var bytes := FileAccess.get_file_as_bytes(OUT_PATH).size()
	print("speed_words: en=%d ja=%d bytes=%d" % [langs["en"].size(), langs["ja"].size(), bytes])
	quit(0)


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _built_date() -> String:
	var man: Variant = _read_json(MANIFEST_PATH)
	if man is Dictionary:
		var b := str((man as Dictionary).get("built", ""))
		if b.length() >= 10:
			return b.substr(0, 10)
	return "unknown"


## 한 언어의 단어 목록(정렬 끝). 입력이 없거나 깨졌으면 [].
func build_lang(lang: String) -> Array:
	var bank: Variant = _read_json(BANK_PATH % lang)
	var gloss: Variant = _read_json(GLOSS_PATH % lang)
	if not (bank is Dictionary) or not (gloss is Dictionary):
		return []
	var lessons: Variant = (bank as Dictionary).get("lessons", null)
	if not (lessons is Dictionary):
		return []
	var sent: Array = []  # 달(1~12) -> 그 달 문장들
	var kor: Array = []   # 달 -> 그 달 한국어 번역들
	var rdg: Array = []   # 달 -> 그 달 문장 읽기(reading) 들
	var tokens := {}      # build 정답 배열의 단어 조각(일본어 짧은 표제어 확인용)
	for m in range(MONTHS + 1):
		sent.append([])
		kor.append([])
		rdg.append([])
	for key in (lessons as Dictionary).keys():
		var m := int(str(key).split("-")[0])
		if m < 1 or m > MONTHS:
			continue
		var cell: Variant = (lessons as Dictionary)[key]
		if not (cell is Array):
			continue
		for les in cell:
			if not (les is Dictionary):
				continue
			var exs: Variant = (les as Dictionary).get("exercises", [])
			if not (exs is Array):
				continue
			for ex in exs:
				if ex is Dictionary:
					_collect(lang, ex as Dictionary, sent[m], kor[m])
					var rv: Variant = (ex as Dictionary).get("reading", "")
					if rv is String and rv != "":
						rdg[m].append(_to_hira(rv))
					if str((ex as Dictionary).get("type", "")) == "build" and (ex as Dictionary).get("answer", null) is Array:
						for tk in (ex as Dictionary)["answer"]:
							tokens[str(tk)] = true
	var found: Array = []  # [m, gloss 순서, 항목]
	var order := 0
	var seen := {}
	var drop: Array = DROP_WORDS.get(lang, [])
	var fix: Dictionary = FIX_KO.get(lang, {})
	if lang == "en":
		var first := {}
		var capmid := {}    # 문장 중간에서 대문자로 나온 단어
		var lower_seen := {}  # 소문자로 나온 적이 있는 단어
		for m in range(1, MONTHS + 1):
			for s in sent[m]:
				for w in _en_words(str(s).to_lower()):
					if not first.has(w):
						first[w] = m
				_scan_case(str(s), capmid, lower_seen)
		for w in (gloss as Dictionary).keys():
			order += 1
			var g: Variant = (gloss as Dictionary)[w]
			if not first.has(w) or seen.has(w) or str(w) in drop or not _gloss_ok(g):
				continue
			seen[w] = true
			var gd: Dictionary = (g as Dictionary).duplicate()
			if fix.has(str(w)):
				gd["ko"] = fix[str(w)]
			var e := _entry(lang, str(w), gd, first[w], kor, "")
			if capmid.has(w) and not lower_seen.has(w) and not (str(w) in EN_COMMON_CAPS):
				e["v"] = false  # 고유명사(이름·나라·도시): 교차 확인 대상에서 뺀다
			found.append([first[w], order, e])
	else:
		var joined: Array = [""]
		var rjoined: Array = [""]
		for m in range(1, MONTHS + 1):
			joined.append("\n".join(PackedStringArray(sent[m])))
			rjoined.append("\n".join(PackedStringArray(rdg[m])))
		for w in (gloss as Dictionary).keys():
			order += 1
			var g: Variant = (gloss as Dictionary)[w]
			var ws := str(w)
			if seen.has(ws) or ws in drop or not _gloss_ok(g) or not _ja_headword_ok(ws):
				continue
			if ws.length() <= 2 and not _has_kanji(ws) and not tokens.has(ws):
				continue
			var rd := str((g as Dictionary).get("ipa", ""))
			if not _all_kana(rd):
				continue
			for m in range(1, MONTHS + 1):
				if (joined[m] as String).contains(ws):
					var gd: Dictionary = (g as Dictionary).duplicate()
					if fix.has(ws):
						gd["ko"] = fix[ws]
					var e := _entry(lang, ws, gd, m, kor, rjoined[m])
					if ws.length() == 1 and not _isolated(joined[m], ws):
						e["v"] = false  # 한자 한 글자가 다른 한자 옆에서만 나오면 단어가 아니라 조각이다
					if ws.length() == 1 and not e["v"] and not (str(e["ko"]).length() >= 2 and (rjoined[m] as String).contains(_to_hira(rd))):
						break  # 한자 한 글자는 v 를 통과하거나, 뜻이 2글자 이상이고 읽기가 그 달 문장 읽기에 있어야만 넣는다(한 글자 조각 뜻은 음독 소리값("회"·"영")인 경우가 많다)
					seen[ws] = true
					found.append([m, order, e])
					break
	found.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out: Array = []
	for f in found:
		out.append(f[2])
	return out


## 연습문제 하나에서 문장(sent)과 한국어 번역(kor)을 모은다.
func _collect(lang: String, ex: Dictionary, sent: Array, kor: Array) -> void:
	var sep := " " if lang == "en" else ""
	match str(ex.get("type", "")):
		"build":
			var ans: Variant = ex.get("answer", [])
			if ans is Array:
				var parts := PackedStringArray()
				for p in ans:
					parts.append(str(p))
				sent.append(sep.join(parts))
			kor.append(str(ex.get("ko", "")))
		"listen":
			sent.append(str(ex.get("audio", "")))
			kor.append(_picked(ex))
		"fill":
			var sentence := str(ex.get("sentence", ""))
			var pick := _picked(ex)
			sent.append(sentence.replace("___", pick))
			kor.append(str(ex.get("ko", "")))
		"speak":
			sent.append(str(ex.get("text", "")))
			kor.append(str(ex.get("ko", "")))


## 영어 문장 하나에서 대문자 사용을 모은다: capmid = 문장 중간(앞 단어와 . ! ? 줄바꿈으로 갈리지 않은 자리)에서
## 대문자로 시작한 단어, lower_seen = 소문자로 시작한 적이 있는 단어(둘 다 소문자 키).
func _scan_case(s: String, capmid: Dictionary, lower_seen: Dictionary) -> void:
	var i := 0
	var n := s.length()
	var start := true
	while i < n:
		var c := s.unicode_at(i)
		if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 39:
			var j := i
			while j < n:
				var d := s.unicode_at(j)
				if (d >= 65 and d <= 90) or (d >= 97 and d <= 122) or d == 39:
					j += 1
				else:
					break
			var tok := s.substr(i, j - i)
			var low := tok.to_lower()
			var is_cap := c >= 65 and c <= 90
			if is_cap:
				if not start:
					capmid[low] = true
			else:
				lower_seen[low] = true
			start = false
			i = j
		else:
			if c == 46 or c == 33 or c == 63 or c == 10:  # . ! ? 줄바꿈
				start = true
			i += 1


## 한자 한 글자 ch 가 text 안에서 앞뒤 글자가 모두 한자가 아닌 자리(문장 끝·가나·기호 옆)에 한 번이라도 나오나.
func _isolated(text: String, ch: String) -> bool:
	var i := text.find(ch)
	while i >= 0:
		var prev_ok := i == 0 or not _is_kanji(text.unicode_at(i - 1))
		var next_ok := i + 1 >= text.length() or not _is_kanji(text.unicode_at(i + 1))
		if prev_ok and next_ok:
			return true
		i = text.find(ch, i + 1)
	return false


## options[answer] (번호가 틀리면 빈 문자열).
func _picked(ex: Dictionary) -> String:
	var opts: Variant = ex.get("options", [])
	var a: Variant = ex.get("answer", -1)
	if opts is Array and (a is float or a is int):
		var i := int(a)
		if i >= 0 and i < (opts as Array).size():
			return str((opts as Array)[i])
	return ""


## 영어 문장 -> 소문자 단어 조각([a-z']+).
func _en_words(s: String) -> Array:
	var out: Array = []
	var cur := ""
	for i in s.length():
		var c := s.unicode_at(i)
		if (c >= 97 and c <= 122) or c == 39:
			cur += s[i]
		else:
			if cur != "":
				out.append(cur)
				cur = ""
	if cur != "":
		out.append(cur)
	return out


func _gloss_ok(g: Variant) -> bool:
	if not (g is Dictionary):
		return false
	var d: Dictionary = g
	var ko: Variant = d.get("ko", null)
	if not (ko is String):
		return false
	var k: String = (ko as String).strip_edges()
	if k == "" or k.length() > KO_MAX:
		return false
	return str(d.get("pos", "")) in POS_OK


func _is_kanji(c: int) -> bool:
	return (c >= 0x4E00 and c <= 0x9FFF) or c == 0x3005


func _ja_headword_ok(w: String) -> bool:
	if w.length() >= 2:
		return true
	return w.length() == 1 and _is_kanji(w.unicode_at(0))


func _has_kanji(s: String) -> bool:
	for i in s.length():
		if _is_kanji(s.unicode_at(i)):
			return true
	return false


## 가타카나를 히라가나로(ー 는 그대로).
func _to_hira(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		out += String.chr(c - 0x60) if (c >= 0x30A1 and c <= 0x30F6) else s[i]
	return out


func _all_kana(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 0x3041 and c <= 0x3096) or (c >= 0x30A1 and c <= 0x30FC)):
			return false
	return true


## rtext: 일본어일 때 그 달 문장 읽기(히라가나) 전체. 영어는 "".
func _entry(lang: String, w: String, g: Dictionary, m: int, kor: Array, rtext: String) -> Dictionary:
	var ko := str(g.get("ko", "")).strip_edges()
	var e := {"w": w}
	if lang == "ja":
		e["rd"] = str(g.get("ipa", ""))
	e["ko"] = ko
	e["pos"] = str(g.get("pos", ""))
	e["m"] = m
	var stem := _stem(ko)
	var ok := false
	if stem.length() >= 2 and (lang != "ja" or rtext.contains(_to_hira(str(g.get("ipa", ""))))):
		for t in kor[m]:
			if (t as String).contains(stem):
				ok = true
				break
	e["v"] = ok
	return e


## 한국어 뜻의 첫 조각에서 "~" 와 끝의 "다" 를 뗀 어간.
func _stem(ko: String) -> String:
	var piece := ko
	for ch in SPLIT_CHARS:
		var i := piece.find(ch)
		if i == 0:
			piece = piece.substr(1)
		elif i > 0:
			piece = piece.left(i)
	piece = piece.replace("~", "").strip_edges()
	if piece.ends_with("다"):
		piece = piece.left(piece.length() - 1)
	return piece


## 항목마다 한 줄. 키 순서 고정이라 결정적이다.
func serialize(langs: Dictionary, built: String) -> String:
	var lines := PackedStringArray()
	lines.append("{\"v\": 1, \"built\": %s, \"src\": %s," % [JSON.stringify(built), JSON.stringify("gloss_<lang>.json + lesson_bank_<lang>.json (godot/tools/build_speed_words.gd)")])
	var keys := ["en", "ja"]
	for ki in keys.size():
		var l: String = keys[ki]
		lines.append(" \"%s\": [" % l)
		var arr: Array = langs[l]
		for i in arr.size():
			var e: Dictionary = arr[i]
			var parts := PackedStringArray()
			for k in ["w", "rd", "ko", "pos", "m", "v"]:
				if e.has(k):
					parts.append("\"%s\": %s" % [k, JSON.stringify(e[k])])
			lines.append("  {" + ", ".join(parts) + "}" + ("," if i < arr.size() - 1 else ""))
		lines.append(" ]" + ("," if ki < keys.size() - 1 else ""))
	lines.append("}")
	return "\n".join(lines) + "\n"
