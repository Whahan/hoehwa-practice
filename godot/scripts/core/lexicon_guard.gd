class_name LexiconGuard
extends RefCounted
## "배운 것만 나온다" 의 실행 중 가드 (docs/v200_design.md §3.3 의 규칙 R1~R6).
## 순수 함수: 파일·네트워크·전역 난수 없음. 데이터는 인자(`data`)로 받는다.
##
## data 모양 (각 모음은 Array(원소에 "id") 또는 Dictionary(id -> 원소) 둘 다 받는다):
##   {"weeks": [...], "words": [...], "patterns": [...], "sentences": [...], "dialogues": [...]}
##   weeks[i] = 설계 §10.2 의 주(w, days, ladder, dialogue ...). words 에는 수동(role:"passive") 낱말도 든다.
## 반복 호출이 빠르도록 `index(data)` 로 색인을 한 번 만들어 쓸 수 있다(없으면 호출마다 만든다).
##
## 도입 순서 o = 주*10 + 일. 현재 o(cur_o) 보다 큰 낱말·문장은 "미래"라서 위반이다.
## 안전한 쪽으로 실패한다: o 가 없거나 이상하면 미래로 본다. 모르는 활용형 문형 id 도 미래로 본다.

const INF_O := 1000000000

## 시험 전용 스위치. false 이면 모든 검사가 통과한다(가드를 일부러 끄고 시험이 FAIL 하는지 보는 용도).
## 앱 코드는 절대 바꾸지 않는다.
static var enabled: bool = true


# ------------------------------------------------------------------ 토큰화 (R2)

## K1(course_src\tools\course_common.py tokenize)과 같은 규칙: 소문자, 토큰 = 글자·숫자 연속(앞뒤에 글자가 있는 안쪽 `'` 는 이어 붙임),
## 하이픈·공백·그 밖의 모든 부호는 토큰을 가른다(thirty-five -> thirty five, I'm 은 한 토큰, 5.99 -> 5 99).
## `say` 가 비어 있지 않으면 `say` 를 토큰 원천으로 쓴다.
static func tokens(text: String, say: String = "") -> Array:
	var src: String = say if say.strip_edges() != "" else text
	return _tok(src)


## 문자 종류: 0 = 구분(공백·하이픈), 1 = 글자·숫자, 2 = 부호·기호, 3 = 아포스트로피.
static func _cls(u: int) -> int:
	if u >= 97 and u <= 122:
		return 1
	if u >= 65 and u <= 90:
		return 1
	if u >= 48 and u <= 57:
		return 1
	if u == 39:
		return 3
	if u <= 32 or u == 0x7F or u == 0xA0 or u == 0x1680 or (u >= 0x2000 and u <= 0x200F) \
			or u == 0x2028 or u == 0x2029 or u == 0x202F or u == 0x205F or u == 0x2060 \
			or u == 0x3000 or u == 0xFEFF:
		return 0
	if u == 45 or (u >= 0x2010 and u <= 0x2015) or u == 0x2212:
		return 0
	if u < 0x80:
		return 2
	if u < 0xC0:
		return 1 if (u == 0xAA or u == 0xB5 or u == 0xBA) else 2
	if u == 0xD7 or u == 0xF7:
		return 2
	if u >= 0x2016 and u <= 0x2BFF:
		return 2
	if u >= 0x3000 and u <= 0x303F:
		return 2
	if u >= 0xFE00 and u <= 0xFE0F:
		return 2
	if u >= 0xFE30 and u <= 0xFE6F:
		return 2
	if u >= 0xFF00 and u <= 0xFF60:
		return 2
	if u >= 0x1F000:
		return 2
	return 1


static func _tok(src: String) -> Array:
	var out: Array = []
	var chunk: String = ""
	var n: int = src.length()
	var us: Array = []
	for i in range(n):
		var u: int = src.unicode_at(i)
		if u >= 0xFF01 and u <= 0xFF5E:
			u -= 0xFEE0 # 전각 ASCII -> 반각
		elif u == 0x2019 or u == 0x2018 or u == 0x2032 or u == 0x2BC or u == 0x60 or u == 0xB4:
			u = 39
		us.append(u)
	for i in range(n):
		var u2: int = us[i]
		var c: int = _cls(u2)
		if c == 1:
			chunk += char(u2)
		elif c == 3 and chunk != "" and i + 1 < n and _cls(us[i + 1]) == 1:
			chunk += "'"
		elif chunk != "":
			out.append(chunk.to_lower())
			chunk = ""
	if chunk != "":
		out.append(chunk.to_lower())
	return out


# ------------------------------------------------------------------ 색인

## 정수 o. 없거나 숫자가 아니거나 정수가 아니면 INF_O(미래로 취급).
static func int_o(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		var f: float = v
		if is_nan(f) or is_inf(f) or f != floorf(f) or absf(f) > 1.0e9:
			return INF_O
		return int(f)
	return INF_O


## 어떤 값이든 안전하게 문자열로: String/StringName/숫자만 글로 바꾸고, null·Dictionary·Array·Object 등은 "" 이다(에러 없음).
## 글이어야 하는 자리에서는 호출하는 쪽이 따로 `not_string` 위반으로 센다.
static func str_of(v: Variant) -> String:
	if v is String:
		return v
	if v is StringName:
		return String(v)
	if v is int or v is float:
		return str(v)
	return ""


## d[key] 가 있는데 String 이 아니면 not_string 위반.
static func _fields_str(bad: Array, d: Dictionary, keys: Array, where: String) -> void:
	for k in keys:
		if d.has(k) and not (d[k] is String):
			bad.append(_b(where + "." + k, "", "not_string", -1))


## 타일·글 배열을 한 줄 글로 합친다. 글이 아닌 원소는 not_string 위반으로 세고 건너뛴다.
static func _join_strs(bad: Array, arr: Array, where: String) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for i in arr.size():
		if arr[i] is String:
			parts.append(arr[i])
		else:
			bad.append(_b("%s[%d]" % [where, i], "", "not_string", -1))
	return " ".join(parts)


## Array(원소에 "id") 또는 Dictionary 를 id -> Dictionary 로 바꾼다. 이상한 원소는 건너뛴다.
static func coll(v: Variant) -> Dictionary:
	var out: Dictionary = {}
	if v is Array:
		for e in v:
			if e is Dictionary and e.get("id") is String and str_of(e["id"]) != "":
				out[str_of(e["id"])] = e
	elif v is Dictionary:
		for k in v.keys():
			var e: Variant = v[k]
			if e is Dictionary:
				var id: String = str_of(e.get("id", k))
				if id != "":
					out[id] = e
	return out


static func _sorted_keys(d: Dictionary) -> Array:
	var k: Array = d.keys()
	k.sort()
	return k


## K1 파일 모양({"v":1,"lang":"en","<key>":[...]})이 통째로 들어와도 안의 배열을 꺼낸다.
static func unwrap(v: Variant, key: String) -> Variant:
	if v is Dictionary and v.get(key) is Array and (v.has("v") or v.has("lang")):
		return v[key]
	return v


## data 에 색인("_idx")을 더한 얕은 복사본. 이미 있으면 그대로.
static func index(data: Variant) -> Dictionary:
	if data is Dictionary and data.get("_idx") is Dictionary:
		return data
	var base: Dictionary = data if data is Dictionary else {}
	var out: Dictionary = base.duplicate(false)
	out["_idx"] = _build_idx(base)
	return out


static func _get_idx(data: Variant) -> Dictionary:
	if data is Dictionary and data.get("_idx") is Dictionary:
		return data["_idx"]
	var base: Dictionary = data if data is Dictionary else {}
	return _build_idx(base)


static func _build_idx(data: Dictionary) -> Dictionary:
	var idx: Dictionary = {}
	var words: Dictionary = coll(unwrap(data.get("words"), "words"))
	var sents: Dictionary = coll(unwrap(data.get("sentences"), "sentences"))
	var pats: Dictionary = coll(unwrap(data.get("patterns"), "patterns"))
	var dlgs: Dictionary = coll(unwrap(data.get("dialogues"), "dialogues"))
	var weeks: Dictionary = {}
	var wv: Variant = unwrap(data.get("weeks"), "weeks")
	if wv is Array:
		for e in wv:
			if e is Dictionary:
				weeks[int_o(e.get("w"))] = e
	elif wv is Dictionary:
		for k in wv.keys():
			var e: Variant = wv[k]
			if e is Dictionary:
				var wn: int = INF_O
				if e.has("w"):
					wn = int_o(e["w"])
				elif str_of(k).is_valid_int():
					wn = int(str_of(k))
				weeks[wn] = e
	idx["words"] = words
	idx["sents"] = sents
	idx["pats"] = pats
	idx["dlgs"] = dlgs
	idx["weeks"] = weeks
	idx["word_ids"] = _sorted_keys(words)
	idx["sent_ids"] = _sorted_keys(sents)
	idx["pat_ids"] = _sorted_keys(pats)
	idx["dlg_ids"] = _sorted_keys(dlgs)
	idx["tcache"] = {}
	var seqs: Dictionary = {}
	var by_ko: Dictionary = {}
	var word_o: Dictionary = {}
	for wid in idx["word_ids"]:
		var wd: Dictionary = words[wid]
		var wo: int = int_o(wd.get("o"))
		word_o[wid] = wo
		var pv: bool = str_of(wd.get("role", "active")) == "passive"
		_add_seq(seqs, tokens(str_of(wd.get("en", ""))), wo, wid, pv)
		var forms: Variant = wd.get("forms")
		if forms is Array:
			for f in forms:
				if not (f is Dictionary):
					continue
				var pid: String = str_of(f.get("pat", ""))
				var fo: int
				if f.has("o"):
					fo = maxi(wo, int_o(f["o"])) # K1 이 이미 max(낱말 o, 문형 o) 로 계산해 준다
				elif pid == "":
					fo = wo
				elif pats.has(pid):
					fo = maxi(wo, int_o(pats[pid].get("o")))
				else:
					fo = INF_O
				_add_seq(seqs, tokens(str_of(f.get("f", ""))), fo, wid, pv)
		var alt: Variant = wd.get("alt")
		if alt is Array:
			for a in alt:
				if a is String:
					_add_seq(seqs, tokens(a), wo, wid, pv)
		var ko: String = str_of(wd.get("ko", ""))
		if ko != "":
			if not by_ko.has(ko):
				by_ko[ko] = []
			by_ko[ko].append(wid)
	for k in seqs.keys():
		var arr: Array = seqs[k]
		arr.sort_custom(func(a, b): return a["t"].size() > b["t"].size())
	idx["seqs"] = seqs
	idx["word_o"] = word_o
	idx["by_ko"] = by_ko
	# 듣기 보기용: 뜻(ko) -> 문장 id 또는 대화 줄 "d0005#1"
	var sent_by_ko: Dictionary = {}
	for sid in idx["sent_ids"]:
		var ko2: String = str_of(sents[sid].get("ko", ""))
		if ko2 != "":
			if not sent_by_ko.has(ko2):
				sent_by_ko[ko2] = []
			sent_by_ko[ko2].append(sid)
	for did in idx["dlg_ids"]:
		var lines: Variant = dlgs[did].get("lines")
		if lines is Array:
			for i in lines.size():
				if lines[i] is Dictionary:
					var ko3: String = str_of(lines[i].get("ko", ""))
					if ko3 != "":
						if not sent_by_ko.has(ko3):
							sent_by_ko[ko3] = []
						sent_by_ko[ko3].append("%s#%d" % [did, i])
	idx["sent_by_ko"] = sent_by_ko
	return idx


static func _add_seq(seqs: Dictionary, toks: Array, o: int, wid: String, pv: bool) -> void:
	if toks.is_empty():
		return
	var key: String = toks[0]
	if not seqs.has(key):
		seqs[key] = []
	seqs[key].append({"t": toks, "o": o, "id": wid, "pv": pv})


## 캐시된 토큰화(색인 안 dictionary 에 저장).
static func toks_c(idx: Dictionary, text: String, say: String = "") -> Array:
	var key: String = text + "\u0001" + say
	var cache: Dictionary = idx["tcache"]
	if cache.has(key):
		return cache[key]
	var t: Array = tokens(text, say)
	if cache.size() > 20000:
		cache.clear()
	cache[key] = t
	return t


# ------------------------------------------------------------------ 검사

static func _b(where: String, token: String, why: String, o: int) -> Dictionary:
	return {"where": where, "token": token, "why": why, "o": o}


static func _pass() -> Dictionary:
	return {"ok": true, "bad": []}


## 토큰 열을 낱말 목록으로 덮는다(가장 긴 항목 먼저, 능동 우선). 덮지 못한 토큰을 bad 에 더한다.
static func _cover(toks: Array, cur_o: int, idx: Dictionary, allow_passive: bool, bad: Array, where: String) -> void:
	var seqs: Dictionary = idx["seqs"]
	var n: int = toks.size()
	var i: int = 0
	while i < n:
		var t: String = toks[i]
		var best: Variant = null
		var best_pv: Variant = null
		var min_future: int = INF_O
		var matched_any: bool = false
		var cands: Array = seqs.get(t, [])
		for e in cands:
			var et: Array = e["t"]
			var ln: int = et.size()
			if i + ln > n:
				continue
			var m: bool = true
			for k in range(1, ln):
				if toks[i + k] != et[k]:
					m = false
					break
			if not m:
				continue
			matched_any = true
			var eo: int = e["o"]
			if eo > cur_o:
				min_future = mini(min_future, eo)
				continue
			if e["pv"]:
				if best_pv == null:
					best_pv = e
			else:
				best = e
				break
		if best != null:
			i += best["t"].size()
		elif best_pv != null:
			if not allow_passive:
				bad.append(_b(where, t, "passive", best_pv["o"]))
			i += best_pv["t"].size()
		else:
			bad.append(_b(where, t, "future" if matched_any else "unknown", min_future if matched_any else -1))
			i += 1


static func _scope_of(s: Dictionary) -> String:
	var sc: String = str_of(s.get("scope", "all"))
	return "all" if sc == "" else sc


## 글 한 줄 검사. say 가 있으면 say 가 토큰 원천.
static func check_text(text: String, cur_o: int, data: Variant, allow_passive: bool = false, say: String = "") -> Dictionary:
	if not enabled:
		return _pass()
	var idx: Dictionary = _get_idx(data)
	var bad: Array = []
	_cover(toks_c(idx, text, say), cur_o, idx, allow_passive, bad, "text")
	return {"ok": bad.is_empty(), "bad": bad}


## 문장 검사: 문장 o <= cur_o, 모든 토큰이 o <= cur_o 인 낱말, 수동 낱말은 scope:"listen" 문장에만.
## sent 는 문장 Dictionary 또는 문장 id.
static func check_sentence(sent: Variant, cur_o: int, data: Variant) -> Dictionary:
	if not enabled:
		return _pass()
	var idx: Dictionary = _get_idx(data)
	var bad: Array = []
	_check_sentence_into(sent, cur_o, idx, bad, "sentence", false)
	return {"ok": bad.is_empty(), "bad": bad}


static func _check_sentence_into(sent: Variant, cur_o: int, idx: Dictionary, bad: Array, where: String, general_only: bool) -> void:
	var s: Dictionary = {}
	if sent is String:
		s = idx["sents"].get(sent, {})
		if s.is_empty():
			bad.append(_b(where, str_of(sent), "unknown_sentence", -1))
			return
	elif sent is Dictionary:
		s = sent
	else:
		bad.append(_b(where, "", "not_sentence", -1))
		return
	var so: int = int_o(s.get("o"))
	if so > cur_o:
		bad.append(_b(where, str_of(s.get("id", "")), "sentence_future", so))
	var sc: String = _scope_of(s)
	if sc != "all" and sc != "listen":
		bad.append(_b(where, sc, "scope", -1))
	if general_only and sc != "all":
		bad.append(_b(where, str_of(s.get("id", "")), "scope_listen", -1))
	var ids: Variant = s.get("words")
	if ids is Array:
		for wid in ids:
			var wd: Variant = idx["words"].get(str_of(wid))
			if wd == null:
				bad.append(_b(where, str_of(wid), "words_unknown", -1))
			elif int_o(wd.get("o")) > cur_o:
				bad.append(_b(where, str_of(wid), "words_future", int_o(wd.get("o"))))
			elif str_of(wd.get("role", "active")) == "passive" and sc != "listen":
				bad.append(_b(where, str_of(wid), "passive", int_o(wd.get("o"))))
	var en: String = str_of(s.get("en", ""))
	if en.strip_edges() == "":
		bad.append(_b(where, "", "empty", -1))
		return
	_cover(toks_c(idx, en, str_of(s.get("say", ""))), cur_o, idx, sc == "listen" and not general_only, bad, where)


## 낱말 id 가 이 문제의 항목으로 쓸 수 있는가. need_seen 이면 (o < cur_o) 이거나 이 세션에서 소개 카드를 본 것이어야 한다(R6).
static func item_ok(wid: String, cur_o: int, seen_set: Dictionary, idx: Dictionary, need_seen: bool) -> String:
	var wd: Variant = idx["words"].get(wid)
	if wd == null:
		return "unknown_item"
	var o: int = idx["word_o"][wid]
	if o > cur_o:
		return "future"
	if str_of(wd.get("role", "active")) == "passive":
		return "passive"
	if need_seen and o >= cur_o and not seen_set.has(wid):
		return "unseen"
	return ""


static func _chk_item(bad: Array, where: String, wid: String, cur_o: int, seen_set: Dictionary, idx: Dictionary, need_seen: bool) -> void:
	var why: String = item_ok(wid, cur_o, seen_set, idx, need_seen)
	if why != "":
		bad.append(_b(where, wid, why, idx["word_o"].get(wid, -1)))


## 두 낱말이 같은 뜻(보기로 함께 쓰면 안 됨)인가.
static func is_syn(a: Dictionary, b: Dictionary) -> bool:
	if str_of(a.get("ko", "")) == str_of(b.get("ko", "")):
		return true
	var sa: Variant = a.get("syn")
	var sb: Variant = b.get("syn")
	if sa is Array and sa.has(b.get("id")):
		return true
	if sb is Array and sb.has(a.get("id")):
		return true
	return false


static func _chk_word_options(bad: Array, ex: Dictionary, cur_o: int, seen_set: Dictionary, idx: Dictionary, lang: String) -> void:
	var opts: Variant = ex.get("options")
	if not (opts is Array) or opts.size() < 2:
		bad.append(_b("options", "", "options_count", -1))
		return
	var ans: Variant = ex.get("answer")
	var ans_ok: bool = (ans is int or ans is float) and int(ans) >= 0 and int(ans) < opts.size()
	if not ans_ok:
		bad.append(_b("answer", "", "answer_range", -1))
	var ids: Variant = ex.get("option_ids")
	var have_ids: bool = ids is Array and ids.size() == opts.size()
	var shown: Dictionary = {}
	for j in opts.size():
		var where: String = "options[%d]" % j
		if not (opts[j] is String):
			bad.append(_b(where, "", "not_string", -1))
			continue
		var txt: String = opts[j]
		if shown.has(txt):
			bad.append(_b(where, txt, "dup_option", -1))
		shown[txt] = true
		if have_ids:
			if not (ids[j] is String):
				bad.append(_b(where, "", "not_string", -1))
				continue
			var wid: String = ids[j]
			var wd: Variant = idx["words"].get(wid)
			if wd == null:
				bad.append(_b(where, wid, "unknown_item", -1))
			else:
				_chk_item(bad, where, wid, cur_o, seen_set, idx, true)
				var disp: String = str_of(wd.get("ko", "")) if lang == "ko" else str_of(wd.get("en", ""))
				if disp != txt:
					bad.append(_b(where, txt, "option_mismatch", -1))
		elif lang == "ko":
			var cands: Array = idx["by_ko"].get(txt, [])
			var any_ok: bool = false
			for wid2 in cands:
				if item_ok(wid2, cur_o, seen_set, idx, true) == "":
					any_ok = true
					break
			if not any_ok:
				bad.append(_b(where, txt, "option_unlearned", -1))
		if lang == "en":
			_cover(toks_c(idx, txt), cur_o, idx, false, bad, where)
	if have_ids and ans_ok:
		var aw: Variant = idx["words"].get(str_of(ids[int(ans)]))
		if aw != null:
			for j in opts.size():
				if j == int(ans):
					continue
				var ow: Variant = idx["words"].get(str_of(ids[j]))
				if ow != null and is_syn(aw, ow):
					bad.append(_b("options[%d]" % j, str_of(ids[j]), "syn_option", -1))


## 듣기 보기(뜻 문장)의 한 참조("s0145" 또는 "d0005#1")가 쓸 수 있는가.
static func ref_ok(ref: String, cur_o: int, idx: Dictionary) -> String:
	if ref.contains("#"):
		var parts: PackedStringArray = ref.split("#")
		var dl: Variant = idx["dlgs"].get(parts[0])
		if dl == null or not (dl.get("lines") is Array):
			return "unknown_option"
		var i: int = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else -1
		var lines: Array = dl["lines"]
		if i < 0 or i >= lines.size() or not (lines[i] is Dictionary):
			return "unknown_option"
		var line: Dictionary = lines[i]
		if int_o(line.get("o")) > cur_o:
			return "future"
		var bad: Array = []
		_cover(toks_c(idx, str_of(line.get("en", "")), str_of(line.get("say", ""))), cur_o, idx, true, bad, "ref")
		return "" if bad.is_empty() else "future"
	var s: Variant = idx["sents"].get(ref)
	if s == null:
		return "unknown_option"
	var bad2: Array = []
	_check_sentence_into(s, cur_o, idx, bad2, "ref", false)
	return "" if bad2.is_empty() else "future"


static func _chk_sent_options(bad: Array, ex: Dictionary, cur_o: int, idx: Dictionary) -> void:
	var opts: Variant = ex.get("options")
	if not (opts is Array) or opts.size() < 2:
		bad.append(_b("options", "", "options_count", -1))
		return
	var ans: Variant = ex.get("answer")
	if not ((ans is int or ans is float) and int(ans) >= 0 and int(ans) < opts.size()):
		bad.append(_b("answer", "", "answer_range", -1))
	var ids: Variant = ex.get("option_ids")
	var have_ids: bool = ids is Array and ids.size() == opts.size()
	var shown: Dictionary = {}
	for j in opts.size():
		var where: String = "options[%d]" % j
		if not (opts[j] is String):
			bad.append(_b(where, "", "not_string", -1))
			continue
		var txt: String = opts[j]
		if shown.has(txt):
			bad.append(_b(where, txt, "dup_option", -1))
		shown[txt] = true
		if have_ids:
			if not (ids[j] is String):
				bad.append(_b(where, "", "not_string", -1))
				continue
			var why: String = ref_ok(ids[j], cur_o, idx)
			if why != "":
				bad.append(_b(where, str_of(ids[j]), why, -1))
		else:
			var refs: Array = idx["sent_by_ko"].get(txt, [])
			var any_ok: bool = false
			for r in refs:
				if ref_ok(str_of(r), cur_o, idx) == "":
					any_ok = true
					break
			if not any_ok:
				bad.append(_b(where, txt, "option_unlearned", -1))


static func _chk_strings(bad: Array, where: String, v: Variant, cur_o: int, idx: Dictionary, allow_passive: bool) -> void:
	if v == null:
		return
	if not (v is Array):
		bad.append(_b(where, "", "not_array", -1))
		return
	for i in v.size():
		if v[i] is String:
			_cover(toks_c(idx, v[i]), cur_o, idx, allow_passive, bad, "%s[%d]" % [where, i])
		else:
			bad.append(_b("%s[%d]" % [where, i], "", "not_string", -1))


## 문제 한 개 검사. ex 는 설계 §10.4 의 문제. seen = 이 세션에서 소개 카드를 본 낱말 id 들.
static func check_exercise(ex: Variant, cur_o: int, seen: Variant, data: Variant) -> Dictionary:
	if not enabled:
		return _pass()
	var bad: Array = []
	if not (ex is Dictionary):
		bad.append(_b("exercise", "", "not_dict", -1))
		return {"ok": false, "bad": bad}
	var idx: Dictionary = _get_idx(data)
	var seen_set: Dictionary = {}
	if seen is Array:
		for s in seen:
			if s is String:
				seen_set[s] = true
	return check_exercise_set(ex, cur_o, seen_set, idx)


## check_exercise 의 빠른 길: seen 이 이미 집합(Dictionary), idx 가 이미 색인(`_idx`).
static func check_exercise_set(ex: Variant, cur_o: int, seen_set: Dictionary, idx: Dictionary) -> Dictionary:
	if not enabled:
		return _pass()
	var bad: Array = []
	if not (ex is Dictionary):
		bad.append(_b("exercise", "", "not_dict", -1))
		return {"ok": false, "bad": bad}
	_fields_str(bad, ex, ["type", "mode", "tts", "prompt", "prompt_en", "target", "say", "sent", "item", "pattern", "dialogue", "tpl", "ko"], "exercise")
	var typ: String = str_of(ex.get("type", ""))
	var mode: String = str_of(ex.get("mode", ""))
	var listenish: bool = typ == "listen" or typ == "dialogue_script"
	# tts: 소리 내어 읽을 글도 배운 것만
	if ex.has("tts") and ex["tts"] is String:
		_cover(toks_c(idx, ex["tts"]), cur_o, idx, listenish, bad, "tts")
	match typ:
		"teach_word":
			_chk_item_card(bad, ex, cur_o, idx)
		"teach_pattern":
			var pid: String = str_of(ex.get("pattern", ""))
			var pt: Variant = idx["pats"].get(pid)
			if pt == null:
				bad.append(_b("pattern", pid, "unknown_pattern", -1))
			else:
				if int_o(pt.get("o")) > cur_o:
					bad.append(_b("pattern", pid, "future", int_o(pt.get("o"))))
				_cover(toks_c(idx, str_of(pt.get("tpl", ""))), cur_o, idx, false, bad, "tpl")
			var exs: Variant = ex.get("examples")
			if exs is Array:
				for i in exs.size():
					_chk_example(bad, exs[i], cur_o, idx, "examples[%d]" % i)
		"recognize":
			_chk_item(bad, "item", str_of(ex.get("item", "")), cur_o, seen_set, idx, true)
			if mode == "en_ko":
				_cover(toks_c(idx, str_of(ex.get("prompt", ""))), cur_o, idx, false, bad, "prompt")
			if mode == "en_ko" or mode == "hear_ko":
				_chk_word_options(bad, ex, cur_o, seen_set, idx, "ko")
			elif mode == "hear_en":
				_chk_word_options(bad, ex, cur_o, seen_set, idx, "en")
			else:
				bad.append(_b("mode", mode, "mode", -1))
		"recall":
			_chk_item(bad, "item", str_of(ex.get("item", "")), cur_o, seen_set, idx, true)
			_chk_strings(bad, "accept", ex.get("accept"), cur_o, idx, false)
			if mode == "ko_en_choice":
				_chk_word_options(bad, ex, cur_o, seen_set, idx, "en")
			elif mode != "ko_en_type":
				bad.append(_b("mode", mode, "mode", -1))
		"build":
			_chk_build(bad, ex, cur_o, idx)
		"listen":
			var sid: String = str_of(ex.get("sent", ""))
			if sid != "":
				_check_sentence_into(sid, cur_o, idx, bad, "sent", false)
			if mode == "choose_ko":
				_chk_sent_options(bad, ex, cur_o, idx)
			elif mode == "type":
				_chk_strings(bad, "accept", ex.get("accept"), cur_o, idx, true)
			else:
				bad.append(_b("mode", mode, "mode", -1))
		"speak":
			var sid2: String = str_of(ex.get("sent", ""))
			if sid2 != "":
				_check_sentence_into(sid2, cur_o, idx, bad, "sent", true)
			if ex.has("target") and ex["target"] is String:
				_cover(toks_c(idx, ex["target"], str_of(ex.get("say", ""))), cur_o, idx, false, bad, "target")
			if ex.has("prompt_en") and ex["prompt_en"] is String:
				_cover(toks_c(idx, ex["prompt_en"], str_of(ex.get("say", ""))), cur_o, idx, false, bad, "prompt_en")
			_chk_strings(bad, "accept", ex.get("accept"), cur_o, idx, false)
			_chk_strings(bad, "expect_any", ex.get("expect_any"), cur_o, idx, false)
			var cue: Variant = ex.get("cue")
			if cue is Dictionary:
				_fields_str(bad, cue, ["slot", "with"], "cue")
				if cue.get("with") is String:
					_cover(toks_c(idx, cue["with"]), cur_o, idx, false, bad, "cue.with")
				if cue.get("slot") is String:
					_cover(toks_c(idx, cue["slot"]), cur_o, idx, false, bad, "cue.slot")
			elif cue != null:
				bad.append(_b("cue", "", "not_dict", -1))
		"dialogue_script":
			_chk_dialogue(bad, ex, cur_o, idx)
		_:
			bad.append(_b("type", typ, "type", -1))
	return {"ok": bad.is_empty(), "bad": bad}


static func _chk_item_card(bad: Array, ex: Dictionary, cur_o: int, idx: Dictionary) -> void:
	var wid: String = str_of(ex.get("item", ""))
	var wd: Variant = idx["words"].get(wid)
	if wd == null:
		bad.append(_b("item", wid, "unknown_item", -1))
		return
	if idx["word_o"][wid] > cur_o:
		bad.append(_b("item", wid, "future", idx["word_o"][wid]))
	if str_of(wd.get("role", "active")) == "passive":
		bad.append(_b("item", wid, "passive", idx["word_o"][wid]))
	_cover(toks_c(idx, str_of(ex.get("prompt", ""))), cur_o, idx, false, bad, "prompt")
	if ex.get("example") is Dictionary:
		_chk_example(bad, ex["example"], cur_o, idx, "example")


## 소개 카드의 예문 {sent, en, say}.
static func _chk_example(bad: Array, e: Variant, cur_o: int, idx: Dictionary, where: String) -> void:
	if not (e is Dictionary):
		bad.append(_b(where, "", "not_dict", -1))
		return
	_fields_str(bad, e, ["sent", "en", "say", "tts"], where)
	var sid: String = str_of(e.get("sent", ""))
	if sid != "":
		_check_sentence_into(sid, cur_o, idx, bad, where, true)
	_cover(toks_c(idx, str_of(e.get("en", "")), str_of(e.get("say", ""))), cur_o, idx, false, bad, where)
	if e.has("tts") and e["tts"] is String:
		_cover(toks_c(idx, e["tts"]), cur_o, idx, false, bad, where + ".tts")


static func _chk_build(bad: Array, ex: Dictionary, cur_o: int, idx: Dictionary) -> void:
	var sid: String = str_of(ex.get("sent", ""))
	var s: Dictionary = {}
	if sid != "":
		_check_sentence_into(sid, cur_o, idx, bad, "sent", true)
		s = idx["sents"].get(sid, {})
	var ans: Variant = ex.get("answer")
	var ans_toks: Dictionary = {}
	if not (ans is Array) or ans.size() < 2:
		bad.append(_b("answer", "", "answer_tiles", -1))
	else:
		var txt: String = _join_strs(bad, ans, "answer")
		var say: String = ""
		if not s.is_empty() and str_of(s.get("say", "")) != "" and toks_c(idx, txt) == toks_c(idx, str_of(s.get("en", ""))):
			say = str_of(s["say"])
		var toks: Array = toks_c(idx, txt, say)
		for t in toks:
			ans_toks[t] = true
		_cover(toks, cur_o, idx, false, bad, "answer")
	var extra: Variant = ex.get("extra")
	if extra is Array:
		for i in extra.size():
			if not (extra[i] is String):
				bad.append(_b("extra[%d]" % i, "", "not_string", -1))
				continue
			var t2: String = extra[i]
			_cover(toks_c(idx, t2), cur_o, idx, false, bad, "extra[%d]" % i)
			for t3 in toks_c(idx, t2):
				if ans_toks.has(t3):
					bad.append(_b("extra[%d]" % i, t2, "extra_dup", -1))
	var acc: Variant = ex.get("accept")
	if acc is Array:
		for i in acc.size():
			if acc[i] is Array:
				var txt2: String = _join_strs(bad, acc[i], "accept[%d]" % i)
				var say2: String = ""
				if not s.is_empty() and str_of(s.get("say", "")) != "" and toks_c(idx, txt2) == toks_c(idx, str_of(s.get("en", ""))):
					say2 = str_of(s["say"])
				_cover(toks_c(idx, txt2, say2), cur_o, idx, false, bad, "accept[%d]" % i)
			elif acc[i] is String:
				_cover(toks_c(idx, acc[i]), cur_o, idx, false, bad, "accept[%d]" % i)
			else:
				bad.append(_b("accept[%d]" % i, "", "not_string", -1))


static func _chk_dialogue(bad: Array, ex: Dictionary, cur_o: int, idx: Dictionary) -> void:
	var did: String = str_of(ex.get("dialogue", ""))
	var dl: Variant = idx["dlgs"].get(did)
	if did != "" and dl == null:
		bad.append(_b("dialogue", did, "unknown_dialogue", -1))
	var lines: Variant = ex.get("lines")
	if not (lines is Array) or lines.is_empty():
		bad.append(_b("lines", "", "no_lines", -1))
		return
	for i in lines.size():
		var line: Variant = lines[i]
		if not (line is Dictionary):
			bad.append(_b("lines[%d]" % i, "", "not_dict", -1))
			continue
		var w: String = "lines[%d]" % i
		_fields_str(bad, line, ["en", "say", "tts", "ko"], w)
		_cover(toks_c(idx, str_of(line.get("en", "")), str_of(line.get("say", ""))), cur_o, idx, true, bad, w)
		if line.has("tts") and line["tts"] is String:
			_cover(toks_c(idx, line["tts"]), cur_o, idx, true, bad, w + ".tts")
		_chk_strings(bad, w + ".accept", line.get("accept"), cur_o, idx, true)
		if dl != null and dl.get("lines") is Array and i < dl["lines"].size() and dl["lines"][i] is Dictionary:
			if int_o(dl["lines"][i].get("o")) > cur_o:
				bad.append(_b(w, did, "line_future", int_o(dl["lines"][i].get("o"))))
