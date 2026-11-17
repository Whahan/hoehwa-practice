class_name LessonBuilder
extends RefCounted
## 레슨 빌더 (docs/v200_design.md §3, §10.4): 하루 한 단위(unit)의 문제 목록을 만든다.
## 순수 함수: 데이터는 인자, 난수는 시드 인자만(RandomNumberGenerator 를 새로 만들어 시드를 준다), 파일·네트워크 없음.
## 만든 모든 문제는 화면에 올리기 전에 LexiconGuard 로 다시 검사하고, 위반 문제는 버리고 `dropped` 로 센다.
##
## build(spec, data, seed_value) -> {ok, exercises, dropped, errors, warnings, dropped_info, skipped, cur_o}
##   spec = {"kind":"new|listen|speak|check|month|recap","w":5,"d":2,"seen":[낱말 id], "speed":1.0, "half":false}
##   data = LexiconGuard 와 같은 모양({"weeks","words","patterns","sentences","dialogues", 선택 "speak_prompts"}).
##   seen = 이 세션에서 이미 소개 카드를 본 낱말 id(중간에 나갔다 돌아온 경우). `new` 는 seen 에 없는 낱말만 카드로 다시 보인다.
## 호출자는 prepare() 결과를 재사용한다(색인 없이 build 를 부르면 호출마다 색인을 만들어 느리다: 낱말 5,000개에서 약 125ms).
## 월말 answer/intro 채점(judge)은 expect_any 항목이 전사에 하나라도 들어 있으면 정답이다(입문자 말하기는 관대하게: 긴 답에 낱말 하나만 있어도 맞다).
## 같은 (spec, data, seed) 는 항상 같은 결과. `new` 는 어떤 시드로도 같은 항목 집합(순서·보기만 다름).

const KINDS := ["new", "listen", "speak", "check", "month", "recap"]
const NEAR_MIN_LEN := 4 ## 이보다 짧은 낱말은 한 글자 차이를 "거의 맞음" 으로 보지 않는다(cat/cap 혼동)


class Ctx:
	extends RefCounted
	var data: Dictionary = {}
	var idx: Dictionary = {}
	var w: int = 1
	var d: int = 1
	var cur: int = 11
	var rng: RandomNumberGenerator = null
	var seen: Dictionary = {}
	var dropped: int = 0
	var dinfo: Array = []
	var errors: Array = []
	var warnings: Array = []
	var skipped: int = 0
	var speed: float = 1.0
	var week: Dictionary = {}
	var used: Dictionary = {}
	var b: Dictionary = {}
	var n_all: int = 0
	var cache: Dictionary = {}
	var sub_ok: bool = true
	var script_ok: bool = false


static func _int_of(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		var f: float = v
		if is_nan(f) or is_inf(f) or f != floorf(f) or absf(f) > 1.0e9:
			return -1
		return int(f)
	return -1


## ------------------------------------------------------------------ 입구

## 색인(LexiconGuard.index) + 빌더용 색인(낱말·문장을 o 순으로 정렬한 목록)을 한 번 만들어 둔다.
## 로더가 데이터를 읽은 뒤 한 번 부르고, 그 결과를 build 에 계속 넘기면 호출마다 색인을 다시 만들지 않는다.
static func prepare(data: Variant) -> Dictionary:
	var dd: Dictionary = LexiconGuard.index(data)
	_bidx(dd["_idx"])
	return dd


static func build(spec: Variant, data: Variant, seed_value: int) -> Dictionary:
	var res: Dictionary = {"ok": false, "exercises": [], "dropped": 0, "errors": [], "warnings": [],
		"dropped_info": [], "skipped": 0, "cur_o": 0}
	if not (spec is Dictionary):
		res["errors"].append("spec_not_dict")
		return res
	var kind: String = LexiconGuard.str_of(spec.get("kind", "")) if spec.get("kind") is String else ""
	if not KINDS.has(kind):
		res["errors"].append("bad_kind")
	var w: int = _int_of(spec.get("w"))
	var d: int = _int_of(spec.get("d"))
	if w < 1 or w > 72:
		res["errors"].append("bad_w")
	if d < 1 or d > 7:
		res["errors"].append("bad_d")
	var dd: Dictionary = {}
	if not (data is Dictionary) or (data as Dictionary).is_empty():
		res["errors"].append("data_empty")
	else:
		dd = prepare(data)
		if dd["_idx"]["words"].is_empty():
			res["errors"].append("no_words")
	if not res["errors"].is_empty():
		return res
	var ctx: Ctx = Ctx.new()
	ctx.data = dd
	ctx.idx = dd["_idx"]
	ctx.w = w
	ctx.d = d
	ctx.cur = w * 10 + d
	res["cur_o"] = ctx.cur
	ctx.rng = RandomNumberGenerator.new()
	ctx.rng.seed = seed_value
	var sv: Variant = spec.get("seen")
	if sv is Array:
		for s in sv:
			if s is String:
				ctx.seen[s] = true
	var sp: Variant = spec.get("speed")
	if (sp is float or sp is int) and float(sp) >= 0.5 and float(sp) <= 2.0:
		ctx.speed = float(sp)
	ctx.week = ctx.idx["weeks"].get(w, {})
	var lad: Variant = ctx.week.get("ladder")
	ctx.sub_ok = w >= 2
	if lad is Dictionary:
		if lad.has("substitute"):
			ctx.sub_ok = bool(lad["substitute"])
		ctx.script_ok = bool(lad.get("script", false))
	var out: Array = []
	match kind:
		"new":
			_unit_new(ctx, out, bool(spec.get("half", false)))
		"listen":
			_unit_listen(ctx, out)
		"speak":
			_unit_speak(ctx, out)
		"check":
			_unit_check(ctx, out)
		"month":
			_unit_month(ctx, out)
		"recap":
			_unit_recap(ctx, out)
	res["exercises"] = out
	res["dropped"] = ctx.dropped
	res["dropped_info"] = ctx.dinfo
	res["errors"] = ctx.errors
	res["warnings"] = ctx.warnings
	res["skipped"] = ctx.skipped
	if out.is_empty() and ctx.errors.is_empty():
		ctx.errors.append("no_exercises")
	res["ok"] = ctx.errors.is_empty()
	return res


## ------------------------------------------------------------------ 공통 도우미

static func _shuffle(rng: RandomNumberGenerator, a: Array) -> void:
	var i: int = a.size() - 1
	while i > 0:
		var j: int = rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
		i -= 1


static func _rotate(a: Array, k: int) -> Array:
	if a.size() < 2:
		return a
	var n: int = k % a.size()
	if n == 0:
		return a
	return a.slice(n) + a.slice(0, n)


static func _emit(ctx: Ctx, out: Array, ex: Dictionary) -> bool:
	var id: String = LexiconGuard.str_of(ex.get("id", ""))
	if ctx.used.has(id):
		return false
	var g: Dictionary = LexiconGuard.check_exercise_set(ex, ctx.cur, ctx.seen, ctx.idx)
	if not g["ok"]:
		ctx.dropped += 1
		if ctx.dinfo.size() < 20:
			ctx.dinfo.append({"id": id, "bad": g["bad"].slice(0, 3)})
		return false
	ctx.used[id] = true
	out.append(ex)
	return true


## 가드를 세지 않고 미리 돌려 본다(후보를 고르는 중에 쓴다. 고른 뒤에는 _emit 이 다시 검사한다).
static func _probe(ctx: Ctx, ex: Dictionary) -> bool:
	return LexiconGuard.check_exercise_set(ex, ctx.cur, ctx.seen, ctx.idx)["ok"]


static func _tts_of(rec: Dictionary) -> String:
	var say: String = LexiconGuard.str_of(rec.get("say", "")).strip_edges()
	return say if say != "" else LexiconGuard.str_of(rec.get("en", ""))


static func _id(ctx: Ctx, abbr: String, item: String, mode: String = "") -> String:
	var s: String = "x:%d:%d:%s:%s" % [ctx.w, ctx.d, abbr, item]
	if mode != "":
		s += ":" + mode
	return s


static func _day_entry(week: Dictionary, d: int) -> Dictionary:
	var days: Variant = week.get("days")
	if days is Array:
		for e in days:
			if e is Dictionary and LexiconGuard.int_o(e.get("d")) == d:
				return e
	return {}


## 빌더용 색인: 능동 낱말과 문장을 (o, id) 순으로 정렬해 두고 o 구간을 이분 탐색으로 자른다.
static func _bidx(idx: Dictionary) -> Dictionary:
	if idx.has("b"):
		return idx["b"]
	var b: Dictionary = {}
	var keys: Array = []
	for wid in idx["word_ids"]:
		var wd: Dictionary = idx["words"][wid]
		if LexiconGuard.str_of(wd.get("role", "active")) != "active":
			continue
		if LexiconGuard.str_of(wd.get("en", "")).strip_edges() == "" or LexiconGuard.str_of(wd.get("ko", "")).strip_edges() == "":
			continue
		var o: int = idx["word_o"][wid]
		if o >= LexiconGuard.INF_O:
			continue
		keys.append("%010d|%s" % [o, wid])
	keys.sort()
	var act: Array = []
	var act_o: Array = []
	var pos_lists: Dictionary = {}
	for k in keys:
		var parts: PackedStringArray = LexiconGuard.str_of(k).split("|", true, 1)
		var wd2: Dictionary = idx["words"][parts[1]]
		act.append(wd2)
		act_o.append(int(parts[0]))
		var pos: String = LexiconGuard.str_of(wd2.get("pos", ""))
		if not pos_lists.has(pos):
			pos_lists[pos] = {"list": [], "os": []}
		pos_lists[pos]["list"].append(wd2)
		pos_lists[pos]["os"].append(int(parts[0]))
	b["act"] = act
	b["act_o"] = act_o
	b["pos"] = pos_lists
	var sk_all: Array = []
	var sk_any: Array = []
	var by_word: Dictionary = {}
	for sid in idx["sent_ids"]:
		var s: Dictionary = idx["sents"][sid]
		var so: int = LexiconGuard.int_o(s.get("o"))
		if so >= LexiconGuard.INF_O:
			continue
		if LexiconGuard.str_of(s.get("ko", "")).strip_edges() == "" or LexiconGuard.str_of(s.get("en", "")).strip_edges() == "":
			continue
		var sc: String = LexiconGuard.str_of(s.get("scope", "all"))
		if sc == "":
			sc = "all"
		if sc != "all" and sc != "listen":
			continue
		var key: String = "%010d|%s" % [so, sid]
		sk_any.append(key)
		if sc == "all":
			sk_all.append(key)
		if s.get("words") is Array:
			for wid2 in s["words"]:
				if not by_word.has(LexiconGuard.str_of(wid2)):
					by_word[LexiconGuard.str_of(wid2)] = []
				by_word[LexiconGuard.str_of(wid2)].append(s)
	b["sents_all"] = _sorted_list(idx, sk_all)
	b["sents_any"] = _sorted_list(idx, sk_any)
	b["by_word"] = by_word
	idx["b"] = b
	return b


## "%010d|id" 키 목록 -> {"list": 문장들, "os": o 값들} (o 순).
static func _sorted_list(idx: Dictionary, keys: Array) -> Dictionary:
	keys.sort()
	var lst: Array = []
	var os: Array = []
	for k in keys:
		var parts: PackedStringArray = LexiconGuard.str_of(k).split("|", true, 1)
		lst.append(idx["sents"][parts[1]])
		os.append(int(parts[0]))
	return {"list": lst, "os": os}


## 정렬된 o 배열에서 값이 v 이하인 개수.
static func _upper(os: Array, v: int) -> int:
	var lo: int = 0
	var hi: int = os.size()
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if os[mid] <= v:
			lo = mid + 1
		else:
			hi = mid
	return lo


## 정렬된 o 배열에서 값이 v 보다 작은 개수.
static func _lower(os: Array, v: int) -> int:
	var lo: int = 0
	var hi: int = os.size()
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if os[mid] < v:
			lo = mid + 1
		else:
			hi = mid
	return lo


## 질문 항목·보기로 쓸 수 있는 낱말은 o <= cur 인 능동 낱말이고, 오늘(o == cur) 낱말은 소개 카드를 본 것만이다(R6).
static func _make_qpool(ctx: Ctx) -> void:
	ctx.b = _bidx(ctx.idx)
	ctx.n_all = _upper(ctx.b["act_o"], ctx.cur)


static func _q_ok(ctx: Ctx, wd: Dictionary) -> bool:
	return int(ctx.idx["word_o"][LexiconGuard.str_of(wd["id"])]) < ctx.cur or ctx.seen.has(LexiconGuard.str_of(wd["id"]))


## arr[0..n) 에서 보기 후보를 최대 need 개 더한다(정답과 같은 뜻·같은 글 제외, R6).
static func _sample_words(ctx: Ctx, arr: Array, n: int, need: int, picks: Array, shown: Dictionary, aw: Dictionary, lang: String) -> void:
	if need <= 0 or n <= 0:
		return
	var order: Array = []
	if n <= 40:
		order = arr.slice(0, n)
		_shuffle(ctx.rng, order)
	else:
		for _i in range(80):
			order.append(arr[ctx.rng.randi_range(0, n - 1)])
	var want: int = picks.size() + need
	for wd in order:
		if picks.size() >= want:
			return
		if wd["id"] == aw["id"] or LexiconGuard.is_syn(aw, wd) or not _q_ok(ctx, wd):
			continue
		var disp: String = LexiconGuard.str_of(wd.get("ko", "")) if lang == "ko" else LexiconGuard.str_of(wd.get("en", ""))
		if disp == "" or shown.has(disp.to_lower()):
			continue
		shown[disp.to_lower()] = true
		picks.append(wd)


## 단어 보기. lang "ko" 면 뜻, "en" 이면 영어. 보기가 모자라면 줄이고(최소 2), 안 배운 낱말로 채우지 않는다.
static func _word_opts(ctx: Ctx, aw: Dictionary, lang: String, n: int) -> Dictionary:
	var ans_disp: String = LexiconGuard.str_of(aw.get("ko", "")) if lang == "ko" else LexiconGuard.str_of(aw.get("en", ""))
	var shown: Dictionary = {ans_disp.to_lower(): true}
	var picks: Array = []
	var pl: Dictionary = ctx.b["pos"].get(LexiconGuard.str_of(aw.get("pos", "")), {"list": [], "os": []})
	_sample_words(ctx, pl["list"], _upper(pl["os"], ctx.cur), n - 1, picks, shown, aw, lang)
	if picks.size() < n - 1:
		_sample_words(ctx, ctx.b["act"], ctx.n_all, n - 1 - picks.size(), picks, shown, aw, lang)
	if picks.is_empty():
		return {}
	var all: Array = picks.duplicate()
	var at: int = ctx.rng.randi_range(0, all.size())
	all.insert(at, aw)
	var options: Array = []
	var ids: Array = []
	for wd in all:
		options.append(LexiconGuard.str_of(wd.get("ko", "")) if lang == "ko" else LexiconGuard.str_of(wd.get("en", "")))
		ids.append(LexiconGuard.str_of(wd["id"]))
	return {"options": options, "ids": ids, "answer": at}


## "I like apples." -> ["I","like","apples"]: 공백으로 나누고 앞뒤 문장부호만 뗀다.
static func tiles_of(en: String) -> Array:
	var out: Array = []
	var s: String = en
	for ch in [" ", "　", "\t", "\n", "\r", " ", " "]:
		s = s.replace(ch, " ")
	for raw in s.split(" ", false):
		var t: String = LexiconGuard.str_of(raw)
		var a: int = 0
		var b: int = t.length()
		while a < b and ".,!?;:\"()…¿¡“”".contains(t[a]):
			a += 1
		while b > a and ".,!?;:\"()…“”".contains(t[b - 1]):
			b -= 1
		t = t.substr(a, b - a)
		if t != "":
			out.append(t)
	return out


## ------------------------------------------------------------------ 문제 만들기

static func _mk_teach_word(ctx: Ctx, wd: Dictionary, example: Variant) -> Dictionary:
	var ex: Dictionary = {"type": "teach_word", "id": _id(ctx, "tw", LexiconGuard.str_of(wd["id"])), "stage": "intro",
		"item": LexiconGuard.str_of(wd["id"]), "prompt": LexiconGuard.str_of(wd.get("en", "")), "ko": LexiconGuard.str_of(wd.get("ko", "")),
		"pos": LexiconGuard.str_of(wd.get("pos", "")), "ipa": LexiconGuard.str_of(wd.get("ipa", "")), "tts": _tts_of(wd)}
	if example is Dictionary:
		ex["example"] = {"sent": LexiconGuard.str_of(example["id"]), "en": LexiconGuard.str_of(example.get("en", "")), "ko": LexiconGuard.str_of(example.get("ko", "")),
			"say": LexiconGuard.str_of(example.get("say", "")), "tts": _tts_of(example)}
	return ex


static func _mk_teach_pattern(ctx: Ctx, pt: Dictionary, examples: Array) -> Dictionary:
	var exs: Array = []
	for s in examples:
		exs.append({"sent": LexiconGuard.str_of(s["id"]), "en": LexiconGuard.str_of(s.get("en", "")), "ko": LexiconGuard.str_of(s.get("ko", "")),
			"say": LexiconGuard.str_of(s.get("say", "")), "tts": _tts_of(s)})
	return {"type": "teach_pattern", "id": _id(ctx, "tp", LexiconGuard.str_of(pt["id"])), "stage": "intro", "pattern": LexiconGuard.str_of(pt["id"]),
		"tpl": LexiconGuard.str_of(pt.get("tpl", "")), "title_ko": LexiconGuard.str_of(pt.get("title_ko", "")),
		"grammar_ko": pt.get("grammar_ko", []), "examples": exs, "tts": ""}


static func _mk_recognize(ctx: Ctx, wd: Dictionary, mode: String) -> Dictionary:
	var lang: String = "en" if mode == "hear_en" else "ko"
	var o: Dictionary = _word_opts(ctx, wd, lang, 4)
	if o.is_empty():
		ctx.skipped += 1
		return {}
	return {"type": "recognize", "id": _id(ctx, "rec", LexiconGuard.str_of(wd["id"]), mode), "stage": "recognize", "mode": mode,
		"item": LexiconGuard.str_of(wd["id"]), "prompt": LexiconGuard.str_of(wd.get("en", "")) if mode == "en_ko" else "", "tts": _tts_of(wd),
		"options": o["options"], "option_ids": o["ids"], "answer": o["answer"]}


static func _hint_of(en: String) -> String:
	var parts: Array = []
	for t in en.split(" ", false):
		var s: String = LexiconGuard.str_of(t)
		parts.append(s.substr(0, 1) + "_".repeat(maxi(s.length() - 1, 0)))
	return " ".join(PackedStringArray(parts))


static func _mk_recall(ctx: Ctx, wd: Dictionary, mode: String) -> Dictionary:
	var en: String = LexiconGuard.str_of(wd.get("en", ""))
	if mode == "ko_en_choice":
		var o: Dictionary = _word_opts(ctx, wd, "en", 4)
		if o.is_empty():
			ctx.skipped += 1
			return {}
		return {"type": "recall", "id": _id(ctx, "rcl", LexiconGuard.str_of(wd["id"]), mode), "stage": "recall", "mode": mode,
			"item": LexiconGuard.str_of(wd["id"]), "prompt_ko": LexiconGuard.str_of(wd.get("ko", "")), "tts": _tts_of(wd),
			"options": o["options"], "option_ids": o["ids"], "answer": o["answer"], "accept": [en]}
	var accept: Array = [en]
	var alt: Variant = wd.get("alt")
	if alt is Array:
		for a in alt:
			if a is String and not accept.has(a):
				accept.append(a)
	# 같은 뜻의 다른 낱말도 정답으로(배운 것만)
	for oid in ctx.idx["by_ko"].get(LexiconGuard.str_of(wd.get("ko", "")), []):
		var other: Dictionary = ctx.idx["words"][oid]
		if oid != wd["id"] and LexiconGuard.str_of(other.get("role", "active")) == "active" and ctx.idx["word_o"][oid] <= ctx.cur and _q_ok(ctx, other) and not accept.has(LexiconGuard.str_of(other.get("en", ""))):
			accept.append(LexiconGuard.str_of(other.get("en", "")))
	return {"type": "recall", "id": _id(ctx, "rcl", LexiconGuard.str_of(wd["id"]), mode), "stage": "recall", "mode": mode,
		"item": LexiconGuard.str_of(wd["id"]), "prompt_ko": LexiconGuard.str_of(wd.get("ko", "")), "tts": _tts_of(wd),
		"accept": accept, "hint": _hint_of(en)}


static func _extra_tiles(ctx: Ctx, s: Dictionary, tiles: Array) -> Array:
	var ans_set: Dictionary = {}
	for t in LexiconGuard.tokens(" ".join(PackedStringArray(tiles))):
		ans_set[t] = true
	var swords: Array = []
	var sposs: Dictionary = {}
	var sw: Variant = s.get("words")
	if sw is Array:
		for wid in sw:
			var wd: Variant = ctx.idx["words"].get(LexiconGuard.str_of(wid))
			if wd != null:
				swords.append(wd)
				sposs[LexiconGuard.str_of(wd.get("pos", ""))] = true
	var picks: Array = []
	var shown: Dictionary = {}
	if ctx.n_all == 0:
		return picks
	for pass_i in range(2):
		for _i in range(40):
			if picks.size() >= 2:
				break
			var c: Dictionary = ctx.b["act"][ctx.rng.randi_range(0, ctx.n_all - 1)]
			var en: String = LexiconGuard.str_of(c.get("en", ""))
			if en == "" or en.contains(" ") or en.contains("-") or not _q_ok(ctx, c):
				continue
			if pass_i == 0 and not sposs.has(LexiconGuard.str_of(c.get("pos", ""))):
				continue
			if shown.has(en.to_lower()) or ans_set.has(en.to_lower()):
				continue
			var bad: bool = false
			for x in swords:
				if LexiconGuard.is_syn(x, c):
					bad = true
					break
			if bad:
				continue
			shown[en.to_lower()] = true
			picks.append(en)
	return picks


static func _mk_build(ctx: Ctx, s: Dictionary) -> Dictionary:
	var tiles: Array = tiles_of(LexiconGuard.str_of(s.get("en", "")))
	if tiles.size() < 2 or tiles.size() > 10:
		return {}
	var accept: Array = [tiles]
	var acc: Variant = s.get("accept")
	if acc is Array:
		for a in acc:
			var t2: Array = tiles_of(LexiconGuard.str_of(a)) if a is String else []
			if not t2.is_empty() and not accept.has(t2):
				accept.append(t2)
	return {"type": "build", "id": _id(ctx, "bld", LexiconGuard.str_of(s["id"])), "stage": "build", "sent": LexiconGuard.str_of(s["id"]),
		"ko": LexiconGuard.str_of(s.get("ko", "")), "answer": tiles, "extra": _extra_tiles(ctx, s, tiles), "accept": accept,
		"tts": _tts_of(s)}


static func _mk_listen_choose(ctx: Ctx, s: Dictionary, pool: Array) -> Dictionary:
	var ko: String = LexiconGuard.str_of(s.get("ko", ""))
	var picks: Array = []
	var shown: Dictionary = {ko: true}
	var order: Array = []
	if pool.size() <= 40:
		order = pool.duplicate()
		_shuffle(ctx.rng, order)
	else:
		for _i in range(60):
			order.append(pool[ctx.rng.randi_range(0, pool.size() - 1)])
	for c in order:
		if picks.size() >= 3:
			break
		if c["id"] == s["id"]:
			continue
		var ck: String = LexiconGuard.str_of(c.get("ko", ""))
		if ck == "" or shown.has(ck) or LexiconGuard.str_of(c.get("en", "")).to_lower() == LexiconGuard.str_of(s.get("en", "")).to_lower():
			continue
		shown[ck] = true
		picks.append(c)
	if picks.is_empty():
		ctx.skipped += 1
		return {}
	var all: Array = picks.duplicate()
	var at: int = ctx.rng.randi_range(0, all.size())
	all.insert(at, s)
	var options: Array = []
	var ids: Array = []
	for x in all:
		options.append(LexiconGuard.str_of(x.get("ko", "")))
		ids.append(LexiconGuard.str_of(x["id"]))
	return {"type": "listen", "id": _id(ctx, "lis", LexiconGuard.str_of(s["id"])), "stage": "listen", "mode": "choose_ko",
		"sent": LexiconGuard.str_of(s["id"]), "tts": _tts_of(s), "options": options, "option_ids": ids, "answer": at, "speed": ctx.speed}


static func _mk_listen_type(ctx: Ctx, s: Dictionary) -> Dictionary:
	if LexiconGuard.str_of(s.get("say", "")).strip_edges() != "":
		return {}
	var n: int = LexiconGuard.toks_c(ctx.idx, LexiconGuard.str_of(s.get("en", ""))).size()
	if n < 3 or n > 6:
		return {}
	var accept: Array = [LexiconGuard.str_of(s.get("en", ""))]
	var acc: Variant = s.get("accept")
	if acc is Array:
		for a in acc:
			if a is String and not accept.has(a):
				accept.append(a)
	return {"type": "listen", "id": _id(ctx, "lis", LexiconGuard.str_of(s["id"]), "type"), "stage": "listen", "mode": "type",
		"sent": LexiconGuard.str_of(s["id"]), "tts": _tts_of(s), "prompt_ko": LexiconGuard.str_of(s.get("ko", "")), "accept": accept, "speed": ctx.speed}


static func _mk_repeat(ctx: Ctx, s: Dictionary) -> Dictionary:
	return {"type": "speak", "id": _id(ctx, "spk", LexiconGuard.str_of(s["id"]), "repeat"), "stage": "speak", "mode": "repeat",
		"sent": LexiconGuard.str_of(s["id"]), "target": LexiconGuard.str_of(s.get("en", "")), "say": LexiconGuard.str_of(s.get("say", "")),
		"ko": LexiconGuard.str_of(s.get("ko", "")), "tts": _tts_of(s), "accept": []}


## 문형 바꿔 말하기: 틀의 칸에 오는 낱말 하나를 같은 품사의 배운 낱말로 바꾼다(관사 a/an 앞은 건너뜀).
static func _mk_sub(ctx: Ctx, s: Dictionary) -> Dictionary:
	if LexiconGuard.str_of(s.get("say", "")).strip_edges() != "":
		return {}
	var pat: Variant = ctx.idx["pats"].get(LexiconGuard.str_of(s.get("pat", "")))
	if pat == null or not (pat.get("slots") is Array) or pat["slots"].is_empty() or not (pat["slots"][0] is Dictionary):
		return {}
	var poss: Variant = pat["slots"][0].get("pos")
	if not (poss is Array) or poss.is_empty():
		return {}
	var tiles: Array = tiles_of(LexiconGuard.str_of(s.get("en", "")))
	var sw: Variant = s.get("words")
	if not (sw is Array):
		return {}
	var slot_word: Dictionary = {}
	var ti: int = -1
	var sw_rev: Array = sw.duplicate()
	sw_rev.reverse() # 틀의 빈칸은 문장 끝쪽에 있다: 마지막으로 맞는 낱말을 쓴다
	for wid in sw_rev:
		var wd: Variant = ctx.idx["words"].get(LexiconGuard.str_of(wid))
		if wd == null or not poss.has(LexiconGuard.str_of(wd.get("pos", ""))) or LexiconGuard.str_of(wd.get("role", "active")) != "active":
			continue
		var en: String = LexiconGuard.str_of(wd.get("en", "")).to_lower()
		if en.contains(" "):
			continue
		for i in tiles.size():
			if LexiconGuard.str_of(tiles[i]).to_lower() == en:
				slot_word = wd
				ti = i
				break
		if ti >= 0:
			break
	if ti < 0:
		return {}
	if ti > 0 and ["a", "an"].has(LexiconGuard.str_of(tiles[ti - 1]).to_lower()):
		return {}
	# 문법이 틀린 문장을 만들지 않으려고 바꿀 수 있는 품사를 좁힌다: 동사·조동사는 바꾸지 않고,
	# 명사는 tags 가 겹칠 때만(가산·불가산 문제), 형용사·숫자·이름은 그대로 바꾼다.
	var spos: String = LexiconGuard.str_of(slot_word.get("pos", ""))
	if not ["n", "adj", "num", "propn"].has(spos):
		return {}
	var pl: Dictionary = ctx.b["pos"].get(spos, {"list": [], "os": []})
	var pn: int = _upper(pl["os"], ctx.cur)
	var cands: Array = []
	if pn <= 60:
		cands = pl["list"].slice(0, pn)
		_shuffle(ctx.rng, cands)
	else:
		for _i in range(80):
			cands.append(pl["list"][ctx.rng.randi_range(0, pn - 1)])
	var rep: Dictionary = {}
	for c in cands:
		var cen: String = LexiconGuard.str_of(c.get("en", ""))
		if c["id"] == slot_word["id"] or cen.contains(" ") or cen.contains("-") or LexiconGuard.is_syn(slot_word, c) or not _q_ok(ctx, c):
			continue
		if spos == "n":
			var tg1: Variant = slot_word.get("tags")
			var tg2: Variant = c.get("tags")
			var share: bool = false
			if tg1 is Array and tg2 is Array:
				for t in tg1:
					if tg2.has(t):
						share = true
						break
			if not share:
				continue
		rep = c
		break
	if rep.is_empty():
		return {}
	var new_tiles: Array = tiles.duplicate()
	var rtxt: String = LexiconGuard.str_of(rep["en"])
	if ti == 0:
		rtxt = rtxt.substr(0, 1).to_upper() + rtxt.substr(1)
	new_tiles[ti] = rtxt
	var en_full: String = LexiconGuard.str_of(s["en"]).strip_edges()
	var tail: String = en_full.substr(en_full.length() - 1) if ".!?".contains(en_full.substr(en_full.length() - 1)) else ""
	var accept: String = " ".join(PackedStringArray(new_tiles)) + tail
	return {"type": "speak", "id": _id(ctx, "spk", LexiconGuard.str_of(s["id"]), "substitute"), "stage": "speak", "mode": "substitute",
		"sent": LexiconGuard.str_of(s["id"]), "target": LexiconGuard.str_of(s["en"]), "ko": LexiconGuard.str_of(s.get("ko", "")), "tts": _tts_of(s),
		"cue": {"slot": LexiconGuard.str_of(tiles[ti]), "with": LexiconGuard.str_of(rep["en"]), "with_ko": LexiconGuard.str_of(rep.get("ko", ""))},
		"accept": [accept]}


## 대본 대화. role true 면 B 줄을 내가 말한다.
static func _mk_dialogue(ctx: Ctx, did: String, role: bool) -> Dictionary:
	var dl: Variant = ctx.idx["dlgs"].get(did)
	if dl == null or not (dl.get("lines") is Array) or dl["lines"].is_empty():
		return {}
	var user: String = LexiconGuard.str_of(dl.get("user", "B"))
	var lines: Array = []
	for ln in dl["lines"]:
		if not (ln is Dictionary):
			return {}
		var you: bool = role and LexiconGuard.str_of(ln.get("s", "")) == user
		var item: Dictionary = {"s": LexiconGuard.str_of(ln.get("s", "")), "en": LexiconGuard.str_of(ln.get("en", "")), "ko": LexiconGuard.str_of(ln.get("ko", "")),
			"tts": _tts_of(ln), "you": you}
		if LexiconGuard.str_of(ln.get("say", "")) != "":
			item["say"] = LexiconGuard.str_of(ln["say"])
		if you:
			item["hint_ko"] = LexiconGuard.str_of(ln.get("ko", ""))
			item["accept"] = [LexiconGuard.str_of(ln.get("en", ""))]
		lines.append(item)
	return {"type": "dialogue_script", "id": _id(ctx, "dlg", did), "stage": "dialogue", "mode": "role" if role else "listen",
		"dialogue": did, "lines": lines}


## 문장 후보 목록(우선순위순). o 가 [lo, hi] 이고 cur_o 이하, 범위(scope)가 맞는 것.
## 순서: 오늘(o == cur) -> 이번 주 -> 그 전. 같은 묶음 안은 seeded 면 시드로 섞고, 아니면 (주,일)로 돌린 순서(결정적).
## 묶음이 너무 크면(200 초과) 일부만 쓴다: seeded 는 무작위 200개, 아니면 (주,일)에서 정해지는 연속 200개.
const TIER_CAP := 200


static func _sents(ctx: Ctx, listen_ok: bool, lo: int, hi: int, seeded: bool) -> Array:
	var key: String = "s:%s:%d:%d:%s" % [str(listen_ok), lo, hi, str(seeded)]
	if ctx.cache.has(key):
		return ctx.cache[key]
	var src: Dictionary = ctx.b["sents_any"] if listen_ok else ctx.b["sents_all"]
	var lst: Array = src["list"]
	var os: Array = src["os"]
	var top: int = mini(hi, ctx.cur)
	var i0: int = _lower(os, lo)
	var i1: int = _upper(os, top)
	var wk0: int = clampi(_lower(os, ctx.w * 10), i0, i1)
	var cu0: int = clampi(_lower(os, ctx.cur), i0, i1)
	# 구간 [a, b): 묶음 0 = 오늘, 1 = 이번 주(오늘 제외), 2 = 그 전
	var ranges: Array = [[cu0, i1], [wk0, cu0], [i0, wk0]]
	var out: Array = []
	for r in ranges:
		var a: int = r[0]
		var b: int = r[1]
		var n: int = b - a
		if n <= 0:
			continue
		var t: Array = []
		if n <= TIER_CAP:
			t = lst.slice(a, b)
			if seeded:
				_shuffle(ctx.rng, t)
			else:
				t = _rotate(t, ctx.w * 7 + ctx.d)
		elif seeded:
			var got: Dictionary = {}
			for _i in range(TIER_CAP * 2):
				if t.size() >= TIER_CAP:
					break
				var k: int = a + ctx.rng.randi_range(0, n - 1)
				if not got.has(k):
					got[k] = true
					t.append(lst[k])
		else:
			var start: int = ((ctx.w * 7 + ctx.d) * 37) % n
			for j in range(TIER_CAP):
				t.append(lst[a + (start + j) % n])
		out.append_array(t)
	ctx.cache[key] = out
	return out


## 듣기용: Tatoeba 문장은 전체의 25% 이하(모자라면 뒤에서 채운다).
static func _cap_tatoeba(cands: Array, n: int) -> Array:
	var cap: int = maxi(n / 4, 0)
	var main: Array = []
	var late: Array = []
	var cnt: int = 0
	for s in cands:
		if LexiconGuard.str_of(s.get("src", "own")) == "tatoeba":
			if cnt < cap:
				cnt += 1
				main.append(s)
			else:
				late.append(s)
		else:
			main.append(s)
	return main + late


static func _make(ctx: Ctx, what: String, c: Dictionary) -> Dictionary:
	match what:
		"build":
			return _mk_build(ctx, c)
		"listen_choose":
			return _mk_listen_choose(ctx, c, _sents(ctx, true, 0, ctx.cur, false))
		"listen_type":
			return _mk_listen_type(ctx, c)
		"repeat":
			return _mk_repeat(ctx, c)
		"sub":
			return _mk_sub(ctx, c)
		"recall_type":
			return _mk_recall(ctx, c, "ko_en_type")
		"recognize_hear":
			return _mk_recognize(ctx, c, "hear_ko")
	return {}


## cands 를 앞에서부터 만들어 n 개가 될 때까지 시도한다(가드가 버린 것은 dropped 로 세고 다음 후보로).
static func _fill(ctx: Ctx, out: Array, cands: Array, n: int, what: String, tag: String = "") -> int:
	var got: int = 0
	var tries: int = 0
	for c in cands:
		if got >= n or tries >= n + 25:
			break
		tries += 1
		var ex: Dictionary = _make(ctx, what, c)
		if ex.is_empty():
			continue
		if tag != "":
			ex["part"] = tag
			ex["stage"] = "check"
		if _emit(ctx, out, ex):
			got += 1
	return got


## ------------------------------------------------------------------ 단위: new

static func _unit_new(ctx: Ctx, out: Array, half: bool) -> void:
	var idx: Dictionary = ctx.idx
	var day: Dictionary = _day_entry(ctx.week, ctx.d)
	if ctx.week.is_empty():
		ctx.errors.append("week_missing")
		return
	var nw: Array = []
	var wids: Variant = day.get("words")
	if wids is Array:
		for wid in wids:
			var wd: Variant = idx["words"].get(LexiconGuard.str_of(wid))
			if wd == null:
				ctx.warnings.append("word_missing:" + LexiconGuard.str_of(wid))
			elif LexiconGuard.str_of(wd.get("role", "active")) == "active":
				nw.append(wd)
	if half and nw.size() > 3:
		nw = nw.slice(0, 3)
	var pids: Array = []
	var pv: Variant = day.get("patterns")
	if pv is Array:
		for pid in pv:
			if idx["pats"].has(LexiconGuard.str_of(pid)):
				pids.append(LexiconGuard.str_of(pid))
			else:
				ctx.warnings.append("pattern_missing:" + LexiconGuard.str_of(pid))
	if nw.is_empty() and pids.is_empty():
		ctx.errors.append("empty_day")
		return
	# 예문: 낱말 -> 그 낱말이 든 가장 가까운 문장(오늘 것 우선, 짧은 것 우선)
	ctx.b = _bidx(idx)
	var best: Dictionary = {}
	for wd in nw:
		for s in ctx.b["by_word"].get(LexiconGuard.str_of(wd["id"]), []):
			var so: int = LexiconGuard.int_o(s.get("o"))
			if so > ctx.cur or LexiconGuard.str_of(s.get("scope", "all")) not in ["all", ""]:
				continue
			var sc: int = (0 if so == ctx.cur else 1) * 100 + LexiconGuard.str_of(s.get("en", "")).length()
			var wid: String = LexiconGuard.str_of(wd["id"])
			if not best.has(wid) or best[wid][0] > sc:
				best[wid] = [sc, s]
	# (1) 소개
	for wd in nw:
		if ctx.seen.has(LexiconGuard.str_of(wd["id"])):
			continue
		var exm: Variant = best[LexiconGuard.str_of(wd["id"])][1] if best.has(LexiconGuard.str_of(wd["id"])) else null
		var ex: Dictionary = _mk_teach_word(ctx, wd, exm)
		if _emit(ctx, out, ex):
			ctx.seen[LexiconGuard.str_of(wd["id"])] = true
		elif exm != null:
			# 예문 때문에 버려졌을 수 있다: 예문 없이 한 번 더
			var ex2: Dictionary = _mk_teach_word(ctx, wd, null)
			if _emit(ctx, out, ex2):
				ctx.seen[LexiconGuard.str_of(wd["id"])] = true
	for pid in pids:
		var pt: Dictionary = idx["pats"][pid]
		var exs: Array = []
		var ids: Variant = pt.get("examples")
		if ids is Array:
			for sid in ids:
				var s2: Variant = idx["sents"].get(LexiconGuard.str_of(sid))
				if s2 != null and LexiconGuard.int_o(s2.get("o")) <= ctx.cur and LexiconGuard.check_sentence(s2, ctx.cur, ctx.data)["ok"] and LexiconGuard.str_of(s2.get("scope", "all")) in ["all", ""]:
					exs.append(s2)
					if exs.size() >= 3:
						break
		_emit(ctx, out, _mk_teach_pattern(ctx, pt, exs))
	_make_qpool(ctx)
	var qwords: Array = []
	for wd in nw:
		if ctx.seen.has(LexiconGuard.str_of(wd["id"])):
			qwords.append(wd)
	# (2) 알아보기: 낱말당 2
	var rec: Array = []
	for qi in qwords.size():
		var wd: Dictionary = qwords[qi]
		var m2: String = "hear_en" if qi % 3 == 0 else "hear_ko" # 시드와 무관: 항목 집합은 시드가 달라도 같다
		rec.append(_mk_recognize(ctx, wd, "en_ko"))
		rec.append(_mk_recognize(ctx, wd, m2))
	var rec2: Array = rec.filter(func(e): return not e.is_empty())
	_shuffle(ctx.rng, rec2)
	for ex in rec2:
		_emit(ctx, out, ex)
	# (3) 떠올리기: 고르기 -> 쓰기
	var rc: Array = []
	var rt: Array = []
	for wd in qwords:
		rc.append(_mk_recall(ctx, wd, "ko_en_choice"))
		rt.append(_mk_recall(ctx, wd, "ko_en_type"))
	rc = rc.filter(func(e): return not e.is_empty())
	_shuffle(ctx.rng, rc)
	_shuffle(ctx.rng, rt)
	for ex in rc:
		_emit(ctx, out, ex)
	for ex in rt:
		_emit(ctx, out, ex)
	# (4) 조립 5
	_fill(ctx, out, _sents(ctx, false, 0, ctx.cur, false), 5, "build")
	# (5) 듣기 4 (뜻 고르기 3 + 받아쓰기 1)
	var lc: Array = _cap_tatoeba(_sents(ctx, true, 0, ctx.cur, false), 4)
	var got: int = _fill(ctx, out, lc, 3, "listen_choose")
	var lc_rest: Array = lc.filter(func(s): return not ctx.used.has(_id(ctx, "lis", LexiconGuard.str_of(s["id"]))))
	var typed: int = _fill(ctx, out, lc_rest, 1, "listen_type")
	if got + typed < 4:
		_fill(ctx, out, lc_rest, 4 - got - typed, "listen_choose")
	# (6) 말하기 5
	_speak_set(ctx, out, 5, 2, false)
	if ctx.d == 4 and not LexiconGuard.str_of(ctx.week.get("dialogue", "")).is_empty():
		var dx: Dictionary = _mk_dialogue(ctx, LexiconGuard.str_of(ctx.week["dialogue"]), ctx.script_ok)
		if not dx.is_empty():
			_emit(ctx, out, dx)


## 말하기 한 묶음: 따라 말하기 + (열려 있으면) 문형 바꿔 말하기 n_sub.
static func _speak_set(ctx: Ctx, out: Array, total: int, n_sub: int, seeded: bool) -> void:
	if ctx.b.is_empty():
		_make_qpool(ctx)
	var cands: Array = _sents(ctx, false, 0, ctx.cur, seeded)
	var subs: Array = []
	if ctx.sub_ok and n_sub > 0:
		_fill(ctx, subs, cands, n_sub, "sub")
	var sub_sents: Dictionary = {}
	for e in subs:
		sub_sents[LexiconGuard.str_of(e["sent"])] = true
	var rest: Array = cands.filter(func(s): return not sub_sents.has(LexiconGuard.str_of(s["id"])))
	var reps: Array = []
	_fill(ctx, reps, rest, total - subs.size(), "repeat")
	out.append_array(reps)
	out.append_array(subs)


## ------------------------------------------------------------------ 단위: listen / speak

static func _unit_listen(ctx: Ctx, out: Array) -> void:
	_make_qpool(ctx)
	var cands: Array = _cap_tatoeba(_sents(ctx, true, 0, ctx.cur, true), 8)
	var got: int = _fill(ctx, out, cands, 6, "listen_choose")
	var rest: Array = cands.filter(func(s): return not ctx.used.has(_id(ctx, "lis", LexiconGuard.str_of(s["id"]))))
	var typed: int = _fill(ctx, out, rest, 2, "listen_type")
	if got + typed < 8:
		_fill(ctx, out, rest, 8 - got - typed, "listen_choose")


static func _unit_speak(ctx: Ctx, out: Array) -> void:
	_make_qpool(ctx)
	var did: String = LexiconGuard.str_of(ctx.week.get("dialogue", ""))
	if (ctx.d == 4 or ctx.d == 5) and ctx.script_ok and did != "":
		var dx: Dictionary = _mk_dialogue(ctx, did, true)
		if not dx.is_empty():
			_emit(ctx, out, dx)
		_speak_set(ctx, out, 3, 0, true)
		return
	if ctx.d <= 3:
		_speak_set(ctx, out, 10, 5, true)
	else:
		_speak_set(ctx, out, 9, 3, true)


## ------------------------------------------------------------------ 단위: check / recap / month

static func _words_in(ctx: Ctx, lo: int, hi: int) -> Array:
	var key: String = "w:%d:%d" % [lo, hi]
	if ctx.cache.has(key):
		return ctx.cache[key]
	var os: Array = ctx.b["act_o"]
	var i0: int = _lower(os, lo)
	var i1: int = mini(_upper(os, hi), ctx.n_all)
	var a: Array = []
	var n: int = i1 - i0
	if n > 0 and n <= 150:
		for i in range(i0, i1):
			if _q_ok(ctx, ctx.b["act"][i]):
				a.append(ctx.b["act"][i])
	elif n > 150:
		for _i in range(150):
			var wd: Dictionary = ctx.b["act"][i0 + ctx.rng.randi_range(0, n - 1)]
			if _q_ok(ctx, wd):
				a.append(wd)
	_shuffle(ctx.rng, a)
	ctx.cache[key] = a
	return a


static func _dialogue_choose(ctx: Ctx, lo: int, hi: int, tag: String) -> Dictionary:
	var ids: Array = []
	var wk: String = LexiconGuard.str_of(ctx.week.get("dialogue", ""))
	if wk != "" and ctx.idx["dlgs"].has(wk) and ctx.w * 10 >= lo and ctx.w * 10 <= hi + 9:
		ids.append(wk)
	for did in ctx.idx["dlg_ids"]:
		if not ids.has(did):
			var dw: int = LexiconGuard.int_o(ctx.idx["dlgs"][did].get("w"))
			if dw * 10 + 9 >= lo and dw * 10 <= hi and dw * 10 + 1 <= ctx.cur:
				ids.append(did)
	for did in ids:
		var dl: Dictionary = ctx.idx["dlgs"][did]
		if not (dl.get("lines") is Array):
			continue
		var order: Array = range(dl["lines"].size())
		_shuffle(ctx.rng, order)
		for i in order:
			var ln: Variant = dl["lines"][i]
			if not (ln is Dictionary) or LexiconGuard.str_of(ln.get("ko", "")) == "" or LexiconGuard.str_of(ln.get("en", "")) == "" or LexiconGuard.int_o(ln.get("o")) > ctx.cur:
				continue
			var ko: String = LexiconGuard.str_of(ln["ko"])
			var picks: Array = []
			var shown: Dictionary = {ko: true}
			var pool: Array = _sents(ctx, true, 0, ctx.cur, true)
			for j in dl["lines"].size():
				var l2: Variant = dl["lines"][j]
				if j != i and l2 is Dictionary and LexiconGuard.str_of(l2.get("ko", "")) != "" and LexiconGuard.int_o(l2.get("o")) <= ctx.cur and not shown.has(LexiconGuard.str_of(l2["ko"])) and picks.size() < 1:
					shown[LexiconGuard.str_of(l2["ko"])] = true
					picks.append(["%s#%d" % [did, j], LexiconGuard.str_of(l2["ko"])])
			for s in pool:
				if picks.size() >= 3:
					break
				var sk: String = LexiconGuard.str_of(s.get("ko", ""))
				if not shown.has(sk):
					shown[sk] = true
					picks.append([LexiconGuard.str_of(s["id"]), sk])
			if picks.is_empty():
				continue
			var at: int = ctx.rng.randi_range(0, picks.size())
			var all: Array = picks.duplicate()
			all.insert(at, ["%s#%d" % [did, i], ko])
			var ex: Dictionary = {"type": "listen", "id": _id(ctx, "lis", "%s_%d" % [did, i]), "stage": "check", "part": tag,
				"mode": "choose_ko", "dialogue": did, "line": i, "tts": _tts_of(ln),
				"options": all.map(func(p): return p[1]), "option_ids": all.map(func(p): return p[0]),
				"answer": at, "speed": ctx.speed}
			if _probe(ctx, ex):
				return ex
	return {}


static func _unit_check(ctx: Ctx, out: Array) -> void:
	_make_qpool(ctx)
	var parts: Array = ["listen", "listen", "listen", "listen", "write", "write", "write", "build", "build", "speak", "speak", "dialogue"]
	var has_prev: bool = ctx.w > 1
	var prev_flag: Array = []
	for _p in parts:
		prev_flag.append(false)
	if has_prev:
		var slots: Array = range(11) # 대화 칸 제외
		_shuffle(ctx.rng, slots)
		for i in range(4):
			prev_flag[slots[i]] = true
	var this_lo: int = ctx.w * 10
	var prev_lo: int = maxi(1, ctx.w - 3) * 10
	var prev_hi: int = ctx.w * 10 - 1
	var speak_n: int = 0
	for i in parts.size():
		var part: String = parts[i]
		var ranges: Array = []
		if prev_flag[i]:
			ranges = [[prev_lo, prev_hi], [this_lo, ctx.cur], [0, ctx.cur]]
		else:
			ranges = [[this_lo, ctx.cur], [prev_lo, prev_hi], [0, ctx.cur]]
		var done: bool = false
		for r in ranges:
			var lo: int = r[0]
			var hi: int = r[1]
			var got: int = 0
			match part:
				"listen":
					got = _fill(ctx, out, _sents(ctx, true, lo, hi, true), 1, "listen_choose", "listen")
				"write":
					got = _fill(ctx, out, _words_in(ctx, lo, hi), 1, "recall_type", "write")
				"build":
					got = _fill(ctx, out, _sents(ctx, false, lo, hi, true), 1, "build", "build")
				"speak":
					var cs: Array = _sents(ctx, false, lo, hi, true)
					if speak_n == 1 and ctx.sub_ok:
						got = _fill(ctx, out, cs, 1, "sub", "speak")
					if got == 0:
						got = _fill(ctx, out, cs, 1, "repeat", "speak")
				"dialogue":
					var dx: Dictionary = _dialogue_choose(ctx, lo, hi, "dialogue")
					if not dx.is_empty() and _emit(ctx, out, dx):
						got = 1
			if got > 0:
				done = true
				break
		if part == "speak":
			speak_n += 1
		if not done:
			ctx.warnings.append("check_short:" + part)
	# 부분 순서는 parts 순서 그대로(듣기 -> 쓰기 -> 조립 -> 말하기 -> 대화)


static func _unit_recap(ctx: Ctx, out: Array) -> void:
	_make_qpool(ctx)
	var lo: int = maxi(1, ctx.w - 1) * 10
	var hi: int = lo + 9
	if ctx.w == 1:
		hi = ctx.cur
	var tries: Array = [[lo, hi], [0, ctx.cur]]
	var plan: Array = [["listen_choose", 2, "s_l"], ["recognize_hear", 1, "w"], ["recall_type", 1, "w"], ["build", 1, "s"], ["repeat", 1, "s"]]
	for pl in plan:
		var got: int = 0
		for r in tries:
			var cands: Array
			if pl[2] == "w":
				cands = _words_in(ctx, r[0], r[1])
			else:
				cands = _sents(ctx, pl[2] == "s_l", r[0], r[1], true)
			got = _fill(ctx, out, cands, pl[1], pl[0], "recap")
			if got >= pl[1]:
				break
		if got < pl[1]:
			ctx.warnings.append("recap_short:" + LexiconGuard.str_of(pl[0]))
	for ex in out:
		ex["stage"] = "recap"


## 월말 말하기 평가. K1 의 en_speak_prompts.json(= data["speak_prompts"]) 모양을 그대로 쓴다:
##   [{"month":1,"w":4,"prompts":[{"id","kind":"read|answer|question|intro","en","ko","say","expect_any":[...],"o"}]}]
## read -> 따라 읽기, answer·question -> 질문에 대답, intro -> 자기소개. o 가 cur 보다 큰 프롬프트와 가드에 걸리는 프롬프트는 쓰지 않는다.
## 5문제가 안 되면 배운 문장 따라 읽기로 채운다. expect_any 는 학습자에게 말하라고 요구하는 표현이라 배운 낱말이어야 한다:
## 안 배운 낱말이 든 항목은 그 항목만 빼고, 남는 항목이 없으면 문제를 버리고 dropped 로 센다.
static func _unit_month(ctx: Ctx, out: Array) -> void:
	_make_qpool(ctx)
	var m: int = (ctx.w + 3) / 4
	var cs: Array = _sents(ctx, false, maxi(0, (m - 1) * 40), ctx.cur, true)
	var sp: Variant = LexiconGuard.unwrap(ctx.data.get("speak_prompts"), "prompts")
	var plist: Array = []
	if sp is Array:
		plist = sp
	elif sp is Dictionary:
		plist = sp.values()
	var reads: Array = []
	var asks: Array = []
	var intros: Array = []
	for grp in plist:
		if not (grp is Dictionary) or LexiconGuard.int_o(grp.get("month")) != m or not (grp.get("prompts") is Array):
			continue
		for pr in grp["prompts"]:
			if not (pr is Dictionary) or LexiconGuard.str_of(pr.get("id", "")) == "" or LexiconGuard.int_o(pr.get("o")) > ctx.cur:
				continue
			var kind: String = LexiconGuard.str_of(pr.get("kind", ""))
			var en: String = LexiconGuard.str_of(pr.get("en", ""))
			var say: String = LexiconGuard.str_of(pr.get("say", ""))
			var tts: String = say if say.strip_edges() != "" else en
			var expect: Array = []
			if pr.get("expect_any") is Array:
				for e in pr["expect_any"]:
					if e is String:
						expect.append(e)
			if not expect.is_empty():
				var kept: Array = []
				for e2 in expect:
					if LexiconGuard.check_text(e2, ctx.cur, ctx.data)["ok"]:
						kept.append(e2)
				if kept.is_empty():
					ctx.dropped += 1
					if ctx.dinfo.size() < 20:
						ctx.dinfo.append({"id": _id(ctx, "chk", LexiconGuard.str_of(pr["id"])), "bad": [{"where": "expect_any", "token": "", "why": "expect_any_unlearned", "o": -1}]})
					continue
				expect = kept
			var base: Dictionary = {"type": "speak", "id": _id(ctx, "chk", LexiconGuard.str_of(pr["id"])), "stage": "month", "ko": LexiconGuard.str_of(pr.get("ko", "")),
				"say": say, "tts": tts, "expect_any": expect, "prompt_id": LexiconGuard.str_of(pr["id"])}
			var ex: Dictionary = base.duplicate()
			if kind == "read":
				ex["part"] = "read"
				ex["mode"] = "repeat"
				ex["target"] = en
				ex["accept"] = []
				if _probe(ctx, ex) and _emit(ctx, reads, ex):
					pass
			elif kind == "answer" or kind == "question":
				ex["part"] = "ask"
				ex["mode"] = "answer"
				ex["prompt_en"] = en
				if _probe(ctx, ex) and _emit(ctx, asks, ex):
					pass
			elif kind == "intro":
				ex["part"] = "intro"
				ex["mode"] = "intro"
				ex["prompt_en"] = en
				if _probe(ctx, ex) and _emit(ctx, intros, ex):
					pass
	var have: int = reads.size() + asks.size() + intros.size()
	if have < 5:
		_fill(ctx, reads, cs, 5 - have, "repeat", "read")
	out.append_array(reads)
	out.append_array(asks)
	out.append_array(intros)
	for ex3 in out:
		ex3["stage"] = "month"


## ------------------------------------------------------------------ 채점 (E2-9)

## 판정용 정규식(가드의 낱말 검사용 토큰화와는 다른 함수다: 검사는 K1 규칙, 판정은 값을 바꾸는 부호를 지키는 규칙).
static var _rx_cache: Dictionary = {}


static func _rx(pattern: String) -> RegEx:
	if not _rx_cache.has(pattern):
		var r: RegEx = RegEx.new()
		r.compile(pattern)
		_rx_cache[pattern] = r
	return _rx_cache[pattern]


## 전각 -> 반각, 굽은 따옴표 -> 곧은 따옴표, 이상한 공백 -> 공백, 여러 가지 줄표·마이너스 -> 하이픈.
static func _fold(s: String) -> String:
	var out: String = ""
	for i in s.length():
		var u: int = s.unicode_at(i)
		if u >= 0xFF01 and u <= 0xFF5E:
			u -= 0xFEE0
		elif u == 0x2019 or u == 0x2018 or u == 0x2032 or u == 0x2BC or u == 0x60 or u == 0xB4:
			u = 39
		elif u == 0x201C or u == 0x201D or u == 0x201E:
			u = 34
		elif u == 0x3000 or u == 0xA0 or (u >= 0x2000 and u <= 0x200F) or u == 0x2028 or u == 0x2029 or u == 0x202F or u == 0x205F or u == 0xFEFF:
			u = 32
		elif (u >= 0x2010 and u <= 0x2015) or u == 0x2212:
			u = 45
		out += char(u)
	return out


## 공통 정규화(모든 판정 모드): 소문자, 전각·따옴표·공백 정리, 앞뒤 공백 제거, 끝의 . ! ? 제거,
## 글자 뒤 공백(또는 끝)이 따르는 쉼표 제거, 천 단위 쉼표(1,000 -> 1000)만 제거.
## 숫자 덩어리의 부호·소수점·%·$ 와 그 밖의 부호(- + . ' & 등)는 남긴다. 글이 아니면 "".
static func norm_answer(s: Variant) -> String:
	if not (s is String):
		return ""
	var t: String = _fold(s).to_lower()
	t = _rx("\\s+").sub(t, " ", true).strip_edges()
	t = _rx("[\\s.!?]+$").sub(t, "")
	t = _rx("(?<=[^\\W\\d_]),(?=\\s|$)").sub(t, "", true)
	t = _rx("(?<=\\d),(?=\\d{3}(?!\\d))").sub(t, "", true)
	return _rx("\\s+").sub(t, " ", true).strip_edges()


## 부호·공백만 다른 답을 "거의 맞음" 으로 알아보는 뼈대: 글자와 숫자만 남긴다.
static func _skeleton(canon: String) -> String:
	return _rx("[^\\p{L}\\p{N}]+").sub(canon, "", true)


## 말하기(전사)용 토큰: 낱말은 K1 규칙, 숫자 덩어리는 부호·소수점·%·$ 를 붙인 채 한 토큰(1,000 은 1000 으로),
## 낱말 뒤 + 와 # 는 낱말에 붙인다(c++ 와 c 는 다르다). 낱말 사이의 하이픈·쉼표 같은 부호는 접는다.
static func speech_tokens(s: Variant) -> Array:
	var out: Array = []
	if not (s is String):
		return out
	var t: String = _fold(s).to_lower()
	var rx: RegEx = _rx("(?:(?<![^\\W_])[-+$])?\\d[\\d,.:]*%?|[^\\W_]+(?:'[^\\W_]+)*[+#]*")
	for m in rx.search_all(t):
		var tok: String = m.get_string()
		var first: String = tok.substr(0, 1)
		if first == "-" or first == "+" or first == "$" or (first >= "0" and first <= "9"):
			var pct: bool = tok.ends_with("%")
			if pct:
				tok = tok.substr(0, tok.length() - 1)
			tok = _rx("[,.:]+$").sub(tok, "")
			tok = _rx("(?<=\\d),(?=\\d{3}(?!\\d))").sub(tok, "", true)
			if pct:
				tok += "%"
		out.append(tok)
	return out


## 고르기 답으로 쓸 수 있는 값(int, 또는 소수 부분이 없는 float). bool·문자열·1.5 는 아니다.
static func _is_index(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		var f: float = v
		return not is_nan(f) and not is_inf(f) and f == floorf(f) and absf(f) < 1.0e9
	return false


## 타일 배열을 한 줄 글로. 글이 아닌 원소가 하나라도 있으면 null.
static func _tiles_text(v: Array) -> Variant:
	var parts: PackedStringArray = PackedStringArray()
	for x in v:
		if not (x is String):
			return null
		parts.append(x)
	return " ".join(parts)


## 토큰 열 hay 안에 needle 이 연속으로 들어 있는가.
static func _contains_seq(hay: Array, needle: Array) -> bool:
	if needle.is_empty() or needle.size() > hay.size():
		return false
	for i in range(hay.size() - needle.size() + 1):
		var m: bool = true
		for j in needle.size():
			if hay[i + j] != needle[j]:
				m = false
				break
		if m:
			return true
	return false


static func _edit1(a: String, b: String) -> bool:
	## Damerau(OSA) 거리 정확히 1 인가.
	if a == b:
		return false
	var la: int = a.length()
	var lb: int = b.length()
	if absi(la - lb) > 1:
		return false
	if la == lb:
		var diff: Array = []
		for i in la:
			if a[i] != b[i]:
				diff.append(i)
				if diff.size() > 2:
					return false
		if diff.size() == 1:
			return true
		return diff.size() == 2 and diff[1] == diff[0] + 1 and a[diff[0]] == b[diff[1]] and a[diff[1]] == b[diff[0]]
	var s: String = a if la < lb else b
	var l: String = b if la < lb else a
	var i2: int = 0
	while i2 < s.length() and s[i2] == l[i2]:
		i2 += 1
	return s.substr(i2) == l.substr(i2 + 1)


## 답 판정 -> {ok, near}. 고르기(int)·조립(Array/String)·쓰기·말하기(String). 이상한 입력은 {ok:false, near:false}.
## 모드별 규칙:
##  - 타이핑(조립 문자열, recall type, listen type): norm_answer 가 정확히 같아야 ok. 부호·하이픈·공백만 다르면 ok:false, near:true.
##  - 조립 타일 배열: 타일마다 norm_answer 한 뒤 순서와 내용이 모두 같아야 ok(-5 와 5 는 다른 타일).
##  - 말하기(repeat, substitute, answer, intro): 전사는 부호가 들쭉날쭉하므로 speech_tokens 로 비교한다(숫자의 부호·%·$ 는 지킨다).
##    repeat 는 target 과 say(읽는 글, 예: minus five)를 둘 다 정답으로 본다. answer/intro 는 expect_any 항목이 전사 안에 연속으로 들어 있으면 맞다.
static func judge(ex: Variant, answer: Variant) -> Dictionary:
	var res: Dictionary = {"ok": false, "near": false}
	if not (ex is Dictionary):
		return res
	var typ: String = LexiconGuard.str_of(ex.get("type", ""))
	var mode: String = LexiconGuard.str_of(ex.get("mode", ""))
	var is_choice: bool = typ == "recognize" or (typ == "listen" and mode == "choose_ko") or (typ == "recall" and mode == "ko_en_choice")
	if is_choice:
		if _is_index(answer) and _is_index(ex.get("answer")):
			res["ok"] = int(answer) == int(ex["answer"])
		return res
	if typ == "build":
		var lists: Array = []
		if ex.get("answer") is Array:
			lists.append(ex["answer"])
		if ex.get("accept") is Array:
			for a in ex["accept"]:
				lists.append(a)
		if answer is Array:
			var tiles: Array = []
			for x in answer:
				if not (x is String):
					return res
				tiles.append(norm_answer(x))
			if tiles.is_empty():
				return res
			for l in lists:
				if l is Array and l.size() == tiles.size():
					var same: bool = true
					for i in tiles.size():
						if not (l[i] is String) or norm_answer(l[i]) != tiles[i]:
							same = false
							break
					if same:
						res["ok"] = true
						return res
				elif l is String and norm_answer(l) == norm_answer(" ".join(PackedStringArray(tiles))):
					res["ok"] = true
					return res
			return res
		if answer is String:
			var accepts_b: Array = []
			for l in lists:
				if l is Array:
					var jl: Variant = _tiles_text(l)
					if jl != null:
						accepts_b.append(jl)
				elif l is String:
					accepts_b.append(l)
			return _typed(answer, accepts_b, res)
		return res
	if typ == "speak" and (mode == "answer" or mode == "intro"):
		if not (answer is String) or not (ex.get("expect_any") is Array):
			return res
		var ga: Array = speech_tokens(answer)
		for e in ex["expect_any"]:
			if e is String and _contains_seq(ga, speech_tokens(e)):
				res["ok"] = true
				return res
		return res
	if typ == "speak":
		if not (answer is String):
			return res
		var accepts_s: Array = []
		if ex.get("accept") is Array:
			accepts_s = ex["accept"].duplicate()
		if mode == "repeat":
			if ex.get("target") is String and LexiconGuard.str_of(ex["target"]) != "":
				accepts_s.append(ex["target"])
			if ex.get("say") is String and LexiconGuard.str_of(ex["say"]).strip_edges() != "":
				accepts_s.append(ex["say"])
		var gs: Array = speech_tokens(answer)
		if gs.is_empty():
			return res
		for a in accepts_s:
			if a is String and speech_tokens(a) == gs:
				res["ok"] = true
				return res
		var gj: String = " ".join(PackedStringArray(gs))
		for a in accepts_s:
			if a is String:
				var nj: String = " ".join(PackedStringArray(speech_tokens(a)))
				if nj.length() >= NEAR_MIN_LEN and _edit1(nj, gj):
					res["near"] = true
					return res
		return res
	if (typ == "recall" and mode == "ko_en_type") or (typ == "listen" and mode == "type"):
		if not (answer is String):
			return res
		var accepts: Array = []
		if ex.get("accept") is Array:
			accepts = ex["accept"]
		return _typed(answer, accepts, res)
	return res


## 타이핑 판정: norm_answer 가 같으면 ok, 부호·공백만 다르거나 한 글자 차이(4글자 이상)면 near.
static func _typed(answer: String, accepts: Array, res: Dictionary) -> Dictionary:
	var g: String = norm_answer(answer)
	if g == "":
		return res
	for a in accepts:
		if a is String and norm_answer(a) == g:
			res["ok"] = true
			return res
	for a in accepts:
		if a is String:
			var na: String = norm_answer(a)
			if na == "":
				continue
			if _skeleton(na) == _skeleton(g) or (na.length() >= NEAR_MIN_LEN and _edit1(na, g)):
				res["near"] = true
				return res
	return res
