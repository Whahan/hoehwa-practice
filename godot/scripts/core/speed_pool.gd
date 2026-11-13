class_name SpeedPool
extends RefCounted
## 60초 스피드 퀴즈의 문제 재료 (순수 계산 + data/speed_words.json 읽기. 기록·복습 일정은 건드리지 않는다).
## docs/v160_fun_design.md §5.3 / §5.4 / §5.8.
##  - load_words(lang)   : data/speed_words.json 을 한 번 읽어 캐시. 깨졌거나 없으면 ok=false (앱은 죽지 않음).
##  - card_items(cards)  : Store.review_for(lang) 결과(인자로 받음) -> 퀴즈 항목. StudyLog/Store 를 읽지 않는다.
##  - build(...)         : 카드 항목 + 레슨 단어(m <= 달+1). 교차 확인(v)을 통과한 단어를 먼저 쓰고,
##                         그 풀이 PREFER_POOL 보다 작을 때만 통과 못한 단어를 필요한 만큼 섞는다(mixed_unverified).
##  - make_question(...) : 단어(+읽기) -> 한국어 뜻 4개 중 고르기.

const MIN_POOL := 12            ## 항목이 이보다 적으면 ok=false (reason "pool_small")
const MIN_DISTINCT_KO := 8      ## 서로 다른 뜻이 이보다 적으면 보기를 만들 수 없어 ok=false
const OPTIONS_N := 4
const PREFER_POOL := 40         ## 통과 단어 + 카드가 이보다 적으면 통과 못한 단어도 모자란 만큼 섞는다
const CARD_HALF_MIN := 8        ## 카드가 이만큼 이상이면 문제의 약 절반을 카드에서(SpeedLogic)
const DATA_PATH := "res://data/speed_words.json"
const KO_MAX_CARD := 40         ## 카드 뜻이 이보다 길면 항목에서 뺀다
const EN_TARGET_MAX_WORDS := 4  ## 영어 카드 target 은 단어 4개까지
const JA_TARGET_MAX_CHARS := 12 ## 일본어 카드 target 은 12자까지
const EN_TARGET_MAX_CHARS := 40
const WORD_MAX := 40
const SPLIT_CHARS := ",·/;~"

## 시험 훅: 다른 파일(깨진 JSON 등)을 가리키게 바꾼다. 바꾼 뒤 clear_cache() 를 부른다.
static var words_path: String = DATA_PATH
static var _cache: Dictionary = {}      ## path -> {"err": String, "langs": {lang: Array}}
static var _tok_cache: Dictionary = {}  ## ko -> Array[String]


static func clear_cache() -> void:
	_cache.clear()
	_tok_cache.clear()


## {"ok": bool, "words": [{w, rd, ko, pos, m, v}], "err": "" | "missing" | "bad"}
## 나쁜 항목(w/ko 가 문자열이 아님, m 이 1~12 가 아님 …)만 버린다. 그 말에 쓸 수 있는 항목이 하나도 없으면 ok=false.
static func load_words(lang: String) -> Dictionary:
	if lang != "en" and lang != "ja":
		return {"ok": false, "words": [], "err": "bad"}
	var root: Dictionary = _load_root()
	var err := str(root.get("err", ""))
	if err != "":
		return {"ok": false, "words": [], "err": err}
	var arr: Array = (root["langs"] as Dictionary).get(lang, [])
	if arr.is_empty():
		return {"ok": false, "words": [], "err": "bad"}
	return {"ok": true, "words": arr.duplicate(), "err": ""}


static func _load_root() -> Dictionary:
	var path := words_path
	if _cache.has(path):
		return _cache[path]
	var res := {"err": "", "langs": {}}
	if not FileAccess.file_exists(path):
		res["err"] = "missing"
	else:
		var j := JSON.new()
		if j.parse(FileAccess.get_file_as_string(path)) != OK or not (j.data is Dictionary):
			res["err"] = "bad"
		else:
			var langs: Dictionary = {}
			for l in ["en", "ja"]:
				var raw: Variant = (j.data as Dictionary).get(l, null)
				var clean: Array = []
				if raw is Array:
					for e in raw:
						var w := _clean_word(e, l)
						if not w.is_empty():
							clean.append(w)
				langs[l] = clean
			res["langs"] = langs
			if (langs["en"] as Array).is_empty() and (langs["ja"] as Array).is_empty():
				res["err"] = "bad"
	_cache[path] = res
	return res


## 항목 하나를 청소해서 {w, rd, ko, pos, m, v} 로. 쓸 수 없으면 {}.
static func _clean_word(e: Variant, lang: String) -> Dictionary:
	if not (e is Dictionary):
		return {}
	var d: Dictionary = e
	if not (d.get("w", null) is String) or not (d.get("ko", null) is String):
		return {}
	var w: String = (d["w"] as String).strip_edges()
	var ko: String = (d["ko"] as String).strip_edges()
	if w == "" or w.length() > WORD_MAX or ko == "" or ko.length() > KO_MAX_CARD:
		return {}
	var mv: Variant = d.get("m", null)
	if not (mv is int or mv is float):
		return {}
	var mf := float(mv)
	if is_nan(mf) or is_inf(mf) or mf != floorf(mf) or mf < 1.0 or mf > 12.0:
		return {}
	var rd := ""
	if d.get("rd", null) is String:
		rd = (d["rd"] as String).strip_edges()
	var pos := ""
	if d.get("pos", null) is String:
		pos = d["pos"]
	return {"w": w, "rd": rd, "ko": ko, "pos": pos, "m": int(mf), "v": d.get("v", false) == true}


## Store.review_for(lang) 결과 -> 퀴즈 항목 [{id, src:"card", w, rd, ko, pos:"", m:0, v:true, due}].
## 뺀다: 목표 단어·뜻이 비었거나 문자열이 아님, 뜻 > 40자, target 이 너무 김(영어 > 4단어 또는 > 40자 / 일본어 > 12자),
## 언어가 en/ja 가 아님, `lang` 을 주었는데 카드 언어가 다름(카드에 lang 이 없으면 `lang` 으로 본다).
static func card_items(cards: Array, lang: String = "") -> Array:
	var out: Array = []
	for c in cards:
		if not (c is Dictionary):
			continue
		var d: Dictionary = c
		var cl := str(d.get("lang", lang))
		if cl != "en" and cl != "ja":
			continue
		if lang != "" and cl != lang:
			continue
		if not (d.get("target", null) is String) or not (d.get("ko", null) is String):
			continue
		var target: String = (d["target"] as String).strip_edges()
		var ko: String = (d["ko"] as String).strip_edges()
		if target == "" or ko == "" or ko.length() > KO_MAX_CARD:
			continue
		if cl == "en":
			if target.length() > EN_TARGET_MAX_CHARS or _count_words(target) > EN_TARGET_MAX_WORDS:
				continue
		elif target.length() > JA_TARGET_MAX_CHARS:
			continue
		var rd := ""
		if d.get("reading", null) is String:
			rd = (d["reading"] as String).strip_edges()
		var due := 0
		var dv: Variant = d.get("due", 0)
		if dv is int or dv is float:
			due = int(dv) if is_finite(float(dv)) else 0
		out.append({"id": "c:" + str(d.get("id", target)), "src": "card", "w": target, "rd": rd, "ko": ko,
			"pos": "", "m": 0, "v": true, "due": due})
	return out


static func _count_words(s: String) -> int:
	var n := 0
	for p in s.split(" ", false):
		if (p as String).strip_edges() != "":
			n += 1
	return n


## {"ok", "items", "reason": "" | "pool_small", "n_cards", "n_words", "mixed_unverified": bool, "n_unverified": int}
## items = 카드 항목 + (words 중 m <= month+1 인 레슨 항목). 통과(v) 단어 우선, 카드+통과 단어가 PREFER_POOL 미만일 때만
## 통과 못한 단어를 (달이 빠른 것부터) 모자란 만큼 섞는다. 합이 MIN_POOL 미만이거나 서로 다른 뜻이 MIN_DISTINCT_KO 미만이면 ok=false.
static func build(lang: String, cards: Array, month: int, words: Array) -> Dictionary:
	var items: Array = card_items(cards, lang)
	var n_cards := items.size()
	var taken := {}
	for it in items:
		taken[str((it as Dictionary)["w"]).to_lower()] = true
	var cap := clampi(month, 1, 12) + 1
	var good: Array = []
	var rest: Array = []
	for wv in words:
		var w := _clean_word(wv, lang)
		if w.is_empty() or int(w["m"]) > cap:
			continue
		var key := str(w["w"]).to_lower()
		if taken.has(key):
			continue
		taken[key] = true
		var item := {"id": "w:" + str(w["w"]), "src": "lesson", "w": w["w"], "rd": w["rd"], "ko": w["ko"],
			"pos": w["pos"], "m": w["m"], "v": w["v"]}
		(good if w["v"] else rest).append(item)
	items.append_array(good)
	var n_unverified := 0
	var need := PREFER_POOL - items.size()
	if need > 0:
		n_unverified = mini(need, rest.size())
		for i in n_unverified:
			items.append(rest[i])
	var ok := items.size() >= MIN_POOL and _distinct_ko(items) >= MIN_DISTINCT_KO
	return {"ok": ok, "items": items if ok else [], "reason": "" if ok else "pool_small", "n_cards": n_cards,
		"n_words": items.size() - n_cards, "mixed_unverified": n_unverified > 0, "n_unverified": n_unverified}


static func _distinct_ko(items: Array) -> int:
	var seen := {}
	for it in items:
		seen[str((it as Dictionary).get("ko", ""))] = true
	return seen.size()


## "일하다, 근무하다" -> ["일하다", "근무하다"]. , · / ; ~ 로 쪼개고 공백을 모두 지우고 빈 조각은 버린다.
static func ko_tokens(ko: String) -> Array:
	if _tok_cache.has(ko):
		return (_tok_cache[ko] as Array).duplicate()
	var s := ko
	for ch in SPLIT_CHARS:
		s = s.replace(ch, "\u0001")
	var out: Array = []
	for p in s.split("\u0001", false):
		var t := (p as String).replace(" ", "").replace("\t", "").replace("\n", "").strip_edges()
		if t != "":
			out.append(t)
	if _tok_cache.size() > 4000:
		_tok_cache.clear()
	_tok_cache[ko] = out
	return out.duplicate()


## 두 뜻이 같은 말로 볼 만큼 겹치나: 조각이 같거나, 2글자 이상 조각이 서로 들어 있다("가다" / "나가다").
static func tokens_clash(a: Array, b: Array) -> bool:
	for x in a:
		for y in b:
			if x == y:
				return true
			var xs := str(x)
			var ys := str(y)
			if mini(xs.length(), ys.length()) >= 2 and (xs.contains(ys) or ys.contains(xs)):
				return true
	return false


## {"id","src","w","rd","ko","options":[뜻 4개],"answer":0..3}. 보기 뜻은 서로 다르고 정답과 겹치지 않는다(같은 품사 우선).
## 만들 수 없으면(풀이 너무 작거나 쓸 항목이 없음) {}.
static func make_question(item: Dictionary, pool: Array, rng: RandomNumberGenerator) -> Dictionary:
	var ko := str(item.get("ko", "")).strip_edges()
	var w := str(item.get("w", ""))
	if ko == "" or w == "":
		return {}
	var r := rng if rng != null else RandomNumberGenerator.new()
	var ans_tok := ko_tokens(ko)
	if ans_tok.is_empty():
		return {}
	var id := str(item.get("id", w))
	var pos := str(item.get("pos", ""))
	var src := str(item.get("src", ""))
	var cands: Array = []
	for p in pool:
		if not (p is Dictionary):
			continue
		var pd: Dictionary = p
		var pk := str(pd.get("ko", "")).strip_edges()
		if pk == "" or str(pd.get("id", pd.get("w", ""))) == id or str(pd.get("w", "")) == w:
			continue
		var ptok := ko_tokens(pk)
		if ptok.is_empty() or tokens_clash(ans_tok, ptok):
			continue
		cands.append({"ko": pk, "tok": ptok, "near": _near(pd, pos, src)})
	shuffle_rng(cands, r)
	var near: Array = []  # 섞인 순서를 지키면서 "가까운" 후보(같은 품사/출처)를 앞으로
	var far: Array = []
	for c in cands:
		(near if c["near"] == 1 else far).append(c)
	cands = near + far
	var picked: Array = []
	var used := {ko: true}
	for strict in [true, false]:  # 1차: 고른 오답끼리도 겹치지 않게, 모자라면 뜻 문자열만 다르게
		for c in cands:
			if picked.size() >= OPTIONS_N - 1:
				break
			if used.has(c["ko"]):
				continue
			if strict:
				var clash := false
				for q in picked:
					if tokens_clash(c["tok"], q["tok"]):
						clash = true
						break
				if clash:
					continue
			used[c["ko"]] = true
			picked.append(c)
	if picked.size() < OPTIONS_N - 1:
		return {}
	var opts: Array = [ko]
	for q in picked:
		opts.append(q["ko"])
	shuffle_rng(opts, r)
	return {"id": id, "src": src, "w": w, "rd": str(item.get("rd", "")), "ko": ko, "options": opts, "answer": opts.find(ko)}


## 같은 품사(품사가 없으면 같은 출처)면 1, 아니면 0.
static func _near(p: Dictionary, pos: String, src: String) -> int:
	if pos != "":
		return 1 if str(p.get("pos", "")) == pos else 0
	return 1 if str(p.get("src", "")) == src else 0


## rng 를 쓰는 Fisher-Yates (Array.shuffle 은 전역 난수라 시드가 안 먹는다).
static func shuffle_rng(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
