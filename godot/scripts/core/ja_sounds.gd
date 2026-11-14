class_name JaSounds
extends RefCounted
## 일본어 약한 소리 코어 (순수 함수 + data/ja_sounds.json 읽기). docs/v170_design.md §2.2.
##  - events(reading)          : 히라가나 읽기에서 소리 칸(장음·촉음·청탁·つ/す·ざ/じゃ·요음)이 걸리는 모라 자리를 찾는다.
##  - annotate(res)            : 일본어 /score 응답의 units[i] 에 ph(소리 칸별 맞음/틀림)를 붙인다 (StudyLog.add_score_any 가 복사본에 쓴다).
##  - build_listen_session(...) : 듣고 고르기 문항(쌍 하나 + 재생할 쪽 + 보기 2개) 만들기.
##  - load_data()              : data/ja_sounds.json 을 한 번 읽어 캐시. 깨졌거나 없으면 ok=false (앱은 죽지 않음).
## 한계(화면 안내로도 보여 준다): 인식된 글자와 비교한 추정이다. 소리 길이나 성대 울림을 직접 재지는 않는다.
## 모라는 server.split_mora 와 같이 작은 가나(ゃゅょ ぁぃぅぇぉ ゎ)를 앞 글자에 붙인 단위다. 쉼표·공백은 세지 않는다.

const CATEGORIES := ["j_long", "j_sokuon", "j_voice", "j_tsu", "j_za", "j_youon"]
const DATA_PATH := "res://data/ja_sounds.json"
const SESSION_N := 10

const _SMALL := "ゃゅょぁぃぅぇぉゎ"
## 모라의 마지막 글자 -> 모음 (장음 판정용)
const _V_A := "あかさたなはまやらわがざだばぱゃぁゎゔ"
const _V_I := "いきしちにひみりぎじぢびぴぃ"
const _V_U := "うくすつぬふむゆるぐずづぶぷゅぅ"
const _V_E := "えけせてねへめれげぜでべぺぇ"
const _V_O := "おこそとのほもよろをごぞどぼぽょぉ"
## 청탁: か・が, さ・ざ, た・だ, は・ば・ぱ 행의 첫 글자
const _VOICE := "かきくけこがぎぐげごさしすせそざじずぜぞたちつてとだぢづでどはひふへほばびぶべぼぱぴぷぺぽ"
const _TSU := "つづすず"
const _ZA := "ざずぜぞじ"
const _PUNCT := " 　、。，．,.!！?？・「」『』…～〜"

## 시험 훅: 다른 파일(깨진 JSON 등)을 가리키게 바꾼다. 바꾼 뒤 clear_cache() 를 부른다.
static var data_path: String = DATA_PATH
static var _cache: Dictionary = {}   ## path -> {"ok": bool, "categories": Array, "err": String}


static func is_category(p: String) -> bool:
	return CATEGORIES.has(p)


static func clear_cache() -> void:
	_cache.clear()


## {"ok": bool, "categories": [{p, label, hint_ko, tip_ko, pairs, words, phrases}], "err": "" | "missing" | "bad"}
## 나쁜 항목(문자열이 아니거나 비어 있음)만 버린다. 쓸 수 있는 카테고리가 하나도 없으면 ok=false.
static func load_data() -> Dictionary:
	return _load().duplicate(true)


static func _load() -> Dictionary:
	var path := data_path
	if _cache.has(path):
		return _cache[path]
	var res := {"ok": false, "categories": [], "err": ""}
	if not FileAccess.file_exists(path):
		res["err"] = "missing"
	else:
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(path)) != OK or not (j.data is Dictionary):
			res["err"] = "bad"
		else:
			var raw: Variant = (j.data as Dictionary).get("categories", null)
			var cats: Array = []
			if raw is Array:
				for c in raw:
					var cc: Dictionary = _clean_category(c)
					if not cc.is_empty():
						cats.append(cc)
			if cats.is_empty():
				res["err"] = "bad"
			else:
				res["ok"] = true
				res["categories"] = cats
	_cache[path] = res
	return res


## 카테고리 하나(없거나 데이터가 깨졌으면 {}).
static func category(p: String) -> Dictionary:
	var d: Dictionary = _load()
	if not bool(d.get("ok", false)):
		return {}
	for c in d["categories"]:
		if str((c as Dictionary).get("p", "")) == p:
			return (c as Dictionary).duplicate(true)
	return {}


static func label_of(p: String) -> String:
	var c: Dictionary = category(p)
	if c.is_empty():
		return p
	var l: String = str(c.get("label", ""))
	return l if l != "" else p


# ---------------------------------------------------------------- events

## [{"cat": "j_long", "i": 모라 번호(0부터), "mora": "あ"}] 모라 번호 순, 같은 모라 안에서는 CATEGORIES 순.
## 입력은 히라가나 읽기(가타카나는 히라가나로 바꿔 읽는다). 가나·ー·쉼표·공백이 아닌 글자가 하나라도 있으면 [].
static func events(reading: Variant) -> Array:
	var out: Array = []
	var moras: Array = _moras(reading)
	var prev_v := ""   ## 앞 모라의 모음 ("" = 없음: 문장 처음, ん, っ 뒤)
	for i in moras.size():
		var m: String = moras[i]
		var cats := {}
		var v := prev_v
		if m == "ー":
			cats["j_long"] = true   # v 는 그대로 이어진다
		elif m == "っ":
			cats["j_sokuon"] = true
			v = ""
		elif m == "ん":
			v = ""
		else:
			if m.length() == 1 and _is_long_vowel(m, prev_v):
				cats["j_long"] = true
			var first: String = m.substr(0, 1)
			if _VOICE.contains(first):
				cats["j_voice"] = true
			if _TSU.contains(first):
				cats["j_tsu"] = true
			if _ZA.contains(first):
				cats["j_za"] = true
			if m.length() >= 2 and "ゃゅょ".contains(m.substr(1, 1)):
				cats["j_youon"] = true
			v = _vowel_of(m.substr(m.length() - 1, 1))
		prev_v = v
		for cat in CATEGORIES:
			if cats.has(cat):
				out.append({"cat": cat, "i": i, "mora": m})
	return out


## 단독 あ・い・う・え・お 가 앞 모음에 이어져 길어지는가. あ←あ단, い←い·え단, う←う·お단, え←え단, お←お단.
static func _is_long_vowel(m: String, prev_v: String) -> bool:
	match m:
		"あ":
			return prev_v == "a"
		"い":
			return prev_v == "i" or prev_v == "e"
		"う":
			return prev_v == "u" or prev_v == "o"
		"え":
			return prev_v == "e"
		"お":
			return prev_v == "o"
	return false


static func _vowel_of(ch: String) -> String:
	if _V_A.contains(ch):
		return "a"
	if _V_I.contains(ch):
		return "i"
	if _V_U.contains(ch):
		return "u"
	if _V_E.contains(ch):
		return "e"
	if _V_O.contains(ch):
		return "o"
	return ""


## 읽기 -> 모라 목록(히라가나). 문자열이 아니거나 허용 밖 글자가 있으면 [].
static func _moras(reading: Variant) -> Array:
	var out: Array = []
	if not (reading is String):
		return out
	var s: String = reading
	if s.length() > 400:
		return out
	for k in s.length():
		var ch: String = s.substr(k, 1)
		var cp: int = ch.unicode_at(0)
		if cp >= 0x30A1 and cp <= 0x30F6:        # 가타카나 -> 히라가나
			ch = char(cp - 0x60)
			cp = ch.unicode_at(0)
		if _PUNCT.contains(ch):
			continue
		if ch == "ー" or (cp >= 0x3041 and cp <= 0x3096):
			if not out.is_empty() and _SMALL.contains(ch):
				out[out.size() - 1] = str(out[out.size() - 1]) + ch
			else:
				out.append(ch)
		else:
			return []
	return out


# ---------------------------------------------------------------- annotate

## 일본어 /score 응답 res 의 units[i].ph 에 [{"p": 소리 칸, "ok": units[i].ok, "heard": units[i].heard 또는 null}] 를 붙인다.
## units[i].t 는 히라가나 모라 하나(가타카나도 받음). 붙인 항목 수를 돌려준다.
## 두 번 불러도 중복되지 않는다(이 코어의 소리 칸 항목만 다시 만든다). 사전이 아니거나 units 가 없거나 t 가 가나가 아닌 응답(영어)은
## 0 이고 res 를 바꾸지 않는다. ok 가 true/false 가 아닌 유닛은 건너뛴다.
static func annotate(res: Variant) -> int:
	if not (res is Dictionary):
		return 0
	var units: Variant = (res as Dictionary).get("units", null)
	if not (units is Array) or (units as Array).is_empty() or (units as Array).size() > 400:
		return 0
	# 1) 검사: 전부 가나인 t 를 가진 사전이어야 한다 (하나라도 아니면 아무것도 바꾸지 않는다)
	var joined := ""
	var starts: Array = []   # 유닛 i 의 첫 글자 위치(joined 안)
	for u in units:
		if not (u is Dictionary):
			return 0
		var t: Variant = (u as Dictionary).get("t", null)
		if not (t is String) or (t as String) == "" or _moras(t).is_empty() or (t as String).strip_edges() != t:
			return 0
		for k in (t as String).length():
			if _PUNCT.contains((t as String).substr(k, 1)):
				return 0   # 유닛 t 에는 쉼표·공백이 없다 (모라 번호가 유닛 번호와 어긋나지 않게)
		starts.append(joined.length())
		joined += t
	var evs: Array = events(joined)
	# 2) 모라 -> 유닛: 모라의 첫 글자가 들어 있는 유닛
	var mora_unit: Array = []
	var pos := 0
	for mo in _moras(joined):
		mora_unit.append(_unit_at(starts, pos))
		pos += (mo as String).length()
	# 3) 붙이기 (이미 있는 이 코어의 항목은 먼저 지운다)
	var add: Dictionary = {}   # 유닛 번호 -> Array
	for e in evs:
		var ui: int = int(mora_unit[int(e["i"])])
		var ok_v: Variant = (units[ui] as Dictionary).get("ok", null)
		if not (ok_v is bool):
			continue
		var hv: Variant = (units[ui] as Dictionary).get("heard", null)
		var heard: Variant = hv if (hv is String and (hv as String) != "") else null
		if not add.has(ui):
			add[ui] = []
		(add[ui] as Array).append({"p": str(e["cat"]), "ok": ok_v, "heard": heard})
	var n := 0
	for ui in (units as Array).size():
		var u: Dictionary = units[ui]
		var old: Variant = u.get("ph", null)
		var keep: Array = []
		var had_mine := false
		if old is Array:
			for ph in old:
				if ph is Dictionary and CATEGORIES.has(str((ph as Dictionary).get("p", ""))):
					had_mine = true
				else:
					keep.append(ph)
		var mine: Array = add.get(ui, [])
		if mine.is_empty() and not had_mine:
			continue   # 바뀔 것이 없다
		keep.append_array(mine)
		u["ph"] = keep
		n += mine.size()
	return n


static func _unit_at(starts: Array, pos: int) -> int:
	var idx := 0
	for i in starts.size():
		if int(starts[i]) <= pos:
			idx = i
	return idx


# ---------------------------------------------------------------- 듣고 고르기

## [{"play": "a"|"b", "pair": {...}, "options": [{w, rd, ko}, {w, rd, ko}] (섞음), "answer": 0|1}] 최대 n 개.
## 한 바퀴(쌍 수만큼) 안에서는 같은 쌍을 반복하지 않는다. 쌍이 n 보다 적으면 다시 섞어 순환한다. 쌍이 없으면 [].
static func build_listen_session(p: String, rng: RandomNumberGenerator, n: int = SESSION_N) -> Array:
	var out: Array = []
	if n <= 0 or not is_category(p):
		return out
	var c: Dictionary = category(p)
	if c.is_empty():
		return out
	var pairs: Array = c.get("pairs", [])
	if pairs.is_empty():
		return out
	var r: RandomNumberGenerator = rng
	if r == null:
		r = RandomNumberGenerator.new()
		r.randomize()
	var order: Array = []
	var last_idx := -1
	while out.size() < n:
		if order.is_empty():
			order = range(pairs.size())
			_shuffle(order, r)
			if order.size() > 1 and int(order[0]) == last_idx:   # 바퀴 사이에 같은 쌍이 바로 이어지지 않게
				var tmp: Variant = order[0]
				order[0] = order[order.size() - 1]
				order[order.size() - 1] = tmp
		var pi: int = int(order.pop_front())
		last_idx = pi
		var pair: Dictionary = pairs[pi]
		var opts: Array = [
			{"w": pair["a"], "rd": pair["a_rd"], "ko": pair["a_ko"], "side": "a"},
			{"w": pair["b"], "rd": pair["b_rd"], "ko": pair["b_ko"], "side": "b"},
		]
		var play: String = "a" if r.randi_range(0, 1) == 0 else "b"
		if r.randi_range(0, 1) == 1:
			opts.reverse()
		var ans := 0
		for i in 2:
			if str((opts[i] as Dictionary)["side"]) == play:
				ans = i
			(opts[i] as Dictionary).erase("side")
		out.append({"play": play, "pair": pair.duplicate(true), "options": opts, "answer": ans})
	return out


static func _shuffle(a: Array, r: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j: int = r.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


# ---------------------------------------------------------------- 데이터 청소

static func _s(v: Variant) -> String:
	return (v as String).strip_edges() if v is String else ""


static func _clean_category(c: Variant) -> Dictionary:
	if not (c is Dictionary):
		return {}
	var d: Dictionary = c
	var p: String = _s(d.get("p", null))
	var re := RegEx.new()
	re.compile("^j_[a-z]{2,8}$")
	if re.search(p) == null or p.length() > 12:
		return {}
	var out := {"p": p, "label": _s(d.get("label", null)), "hint_ko": _s(d.get("hint_ko", null)), "tip_ko": _s(d.get("tip_ko", null)),
		"pairs": [], "words": [], "phrases": []}
	var pr: Variant = d.get("pairs", null)
	if pr is Array:
		for e in pr:
			if e is Dictionary:
				var x: Dictionary = {}
				var good := true
				for k in ["a", "a_rd", "a_ko", "b", "b_rd", "b_ko"]:
					var sv: String = _s((e as Dictionary).get(k, null))
					if sv == "":
						good = false
					x[k] = sv
				if good:
					for k in ["a_pr", "b_pr"]:
						x[k] = _s((e as Dictionary).get(k, null))
					(out["pairs"] as Array).append(x)
	var wr: Variant = d.get("words", null)
	if wr is Array:
		for e in wr:
			if e is Dictionary:
				var w: String = _s((e as Dictionary).get("w", null))
				var rd: String = _s((e as Dictionary).get("rd", null))
				var ko: String = _s((e as Dictionary).get("ko", null))
				if w != "" and rd != "" and ko != "":
					(out["words"] as Array).append({"w": w, "rd": rd, "pr": _s((e as Dictionary).get("pr", null)), "ko": ko})
	var phr: Variant = d.get("phrases", null)
	if phr is Array:
		for e in phr:
			if e is Dictionary:
				var t: String = _s((e as Dictionary).get("text", null))
				var rd2: String = _s((e as Dictionary).get("rd", null))
				var ko2: String = _s((e as Dictionary).get("ko", null))
				if t != "" and rd2 != "" and ko2 != "":
					(out["phrases"] as Array).append({"text": t, "rd": rd2, "pr": _s((e as Dictionary).get("pr", null)), "ko": ko2})
	return out
