class_name SyncDoc
extends RefCounted
## 학습 기록 동기화의 데이터 모양 변환 (순수 함수: 파일·네트워크·시계·난수·전역 상태를 쓰지 않는다).
## 설계: docs/sync_design.md §4 (데이터 모델), §9.1 (시그니처).
##
##   로컬 파일 3개 --extract--> 지역 뷰(view) --SyncMerge.sync_round--> 병합된 뷰 --to_local--> 로컬 모양
##
## 보호권(freeze)은 동기화하지 않는다(§4.6): extract 는 읽지 않고, to_local 은 입력의 freeze 를 그대로 둔다.

const SCHEMA := 1
const SHARED_PREFS := {"daily_goal_min": 10, "lesson_source": "tatoeba", "auto_fix_cards": true,
	"tts_voice_en": "af_heart", "tts_voice_ja": "jf_alpha", "tts_speed": 1.0} ## 키 -> 기본값

const LANGS := ["en", "ja"]
const STAT_KEYS := ["lessons", "talks"]
const MAX_LEAF := 9007199254740992 ## 2^53, 합산 값의 상한
const MAX_TIME := 4102444800 ## 시각(t) 상한 (2100-01-01)
const MAX_SEC_PER_DAY := 86400
const MAX_COUNT := 1000000
const MAX_CARDS := 3000 ## 복습 카드 상한 (S3 가 Progress.MAX_REVIEW 를 3000 으로 올린다)
const MAX_KNOWN := 30000 ## 언어당 아는 단어 상한
const MAX_MISSIONS := 200
const MAX_KEYS := 32 ## by / n 의 키 수
const MAX_KEY_LEN := 24
const KEEP_DAYS := 400
const HISTORY := 30 ## 음소 결과 기록 길이
const MAX_PHONEMES := 80
const MAX_HEARD := 8
const MAX_P_LEN := 12
const TEXT_MAX := 300 ## 카드 target / reading / ko / note
const KEY_MAX := 400
const VOICE_MAX := 64

const _ISO_DIGITS := [0, 1, 2, 3, 5, 6, 8, 9]
const _REPLICA_TOP := ["v", "progress", "studylog", "prefs"]
const LIM_CARDS := 3500 ## 복제본 한 장에 담는 카드 수(허브 한도)
const _LIM_KNOWN := 70000
const _LIM_SET := 5000
const _LIM_DAYS := 800
const _LIM_DEPTH := 8
const _LIM_STR := 400
const _MAX_PROBLEMS := 40
const _CARD_FIELDS := ["id", "lang", "target", "reading", "ko", "note", "due", "stability", "difficulty",
	"state", "step", "last_review", "reps", "lapses"]


# ---------------------------------------------------------------- blanks

static func blank_set() -> Dictionary:
	return {"add": {}, "del": {}}


static func blank_rec() -> Dictionary:
	return {"sec": 0, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}


static func blank_view() -> Dictionary:
	var prefs := {}
	for k in SHARED_PREFS.keys():
		prefs[k] = SHARED_PREFS[k]
	return {
		"start": Plan.DEFAULT_START,
		"checks": [],
		"marks": [],
		"xp": {"en": 0, "ja": 0},
		"stats": {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
		"cards": [],
		"known": {"en": [], "ja": []},
		"days": {},
		"phon": {"en": {}, "ja": {}},
		"missions": {},
		"prefs": prefs,
	}


static func blank_replica() -> Dictionary:
	var prefs := {}
	for k in SHARED_PREFS.keys():
		prefs[k] = {"value": SHARED_PREFS[k], "t": 0}
	return {
		"v": SCHEMA,
		"progress": {
			"start": {"value": Plan.DEFAULT_START, "t": 0},
			"checks": blank_set(),
			"marks": blank_set(),
			"xp": {"en": 0, "ja": 0},
			"stats": {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
			"cards": {"add": {}, "del": {}, "data": {}},
			"known": {"en": blank_set(), "ja": blank_set()},
		},
		"studylog": {"days": {}, "phon": {"en": {}, "ja": {}}, "missions": {}},
		"prefs": prefs,
	}


# ---------------------------------------------------------------- scalar cleaning

## Integer in [lo, hi]. Anything that is not a finite number (string, bool, NaN, inf) becomes 0, then is clamped.
static func to_int(v: Variant, lo: int = 0, hi: int = MAX_LEAF) -> int:
	var x: int = 0
	if v is int:
		x = v
	elif v is float:
		var f: float = v
		if is_nan(f) or is_inf(f):
			x = 0
		else:
			x = int(clampf(f, -4.0e18, 4.0e18))
	return clampi(x, lo, hi)


static func is_num(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v))


## Finite float in [lo, hi]; anything else -> dflt.
static func to_flt(v: Variant, lo: float, hi: float, dflt: float) -> float:
	if v is int or (v is float and is_finite(v)):
		return clampf(float(v), lo, hi)
	return dflt


static func is_lang(v: Variant) -> bool:
	return v is String and (v == "en" or v == "ja")


static func _truthy(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return v != 0.0
	return false


## "YYYY-MM-DD" -> day number (Plan.days_from_civil), -1 when it is not a real calendar date.
static func iso_days(s: Variant) -> int:
	if not (s is String):
		return -1
	var t: String = s
	if t.length() != 10 or t[4] != "-" or t[7] != "-":
		return -1
	for i in _ISO_DIGITS:
		var c: int = t.unicode_at(i)
		if c < 48 or c > 57:
			return -1
	var y: int = int(t.substr(0, 4))
	var m: int = int(t.substr(5, 2))
	var d: int = int(t.substr(8, 2))
	if m < 1 or m > 12 or d < 1 or d > 31:
		return -1
	var days: int = Plan.days_from_civil(y, m, d)
	var back: Dictionary = Plan.civil_from_days(days)
	if int(back["month"]) != m or int(back["day"]) != d:
		return -1
	return days


static func is_iso(s: Variant) -> bool:
	return iso_days(s) >= 0


static func card_key(lang: String, target: String) -> String:
	return "%s|%s" % [lang, target]


## Deterministic id (no randomness): derived from the card key and a counter, skipping ids in `used`.
static func gen_id(key: String, used: Dictionary) -> String:
	var n: int = 0
	while true:
		var id: String = "s" + ("%s#%d" % [key, n]).sha256_text().substr(0, 10)
		if not used.has(id):
			return id
		n += 1
	return ""


# ---------------------------------------------------------------- shared preferences

static func pref_valid(key: String, v: Variant) -> bool:
	match key:
		"daily_goal_min":
			return is_num(v) and float(v) == floorf(float(v)) and float(v) >= 0.0 and float(v) <= 240.0
		"lesson_source":
			return v is String and (v == "ai" or v == "tatoeba")
		"auto_fix_cards":
			return v is bool
		"tts_voice_en", "tts_voice_ja":
			return v is String and (v as String).strip_edges() != "" and (v as String).length() <= VOICE_MAX
		"tts_speed":
			return is_num(v) and float(v) >= 0.1 and float(v) <= 5.0
	return false


## Assumes pref_valid(key, v).
static func pref_norm(key: String, v: Variant) -> Variant:
	match key:
		"daily_goal_min":
			return int(v)
		"tts_speed":
			return float(v)
	return v


static func pref_or_default(key: String, v: Variant) -> Variant:
	if pref_valid(key, v):
		return pref_norm(key, v)
	return SHARED_PREFS[key]


## True when two register values are the same (numbers compare by value).
static func same_value(a: Variant, b: Variant) -> bool:
	if is_num(a) and is_num(b):
		return float(a) == float(b)
	return typeof(a) == typeof(b) and a == b


# ---------------------------------------------------------------- record cleaning (same rules as the study log file)

## {key: count} with 1..24 char keys, value in 1..hi, at most 32 keys (the biggest ones when there are more).
static func clean_counts(v: Variant, hi: int) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for k in (v as Dictionary):
		if k is String and (k as String).length() > 0 and (k as String).length() <= MAX_KEY_LEN:
			var x: int = to_int((v as Dictionary)[k], 0, hi)
			if x > 0:
				out[k] = x
	if out.size() > MAX_KEYS:
		var keys: Array = out.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool:
			if out[a] != out[b]:
				return out[a] > out[b]
			return str(a) < str(b))
		var kept := {}
		for i in MAX_KEYS:
			kept[keys[i]] = out[keys[i]]
		out = kept
	return out


static func _pair(v: Variant) -> Array:
	if v is Array and (v as Array).size() >= 2:
		return [to_int((v as Array)[0], 0, MAX_COUNT), to_int((v as Array)[1], 0, MAX_COUNT)]
	return [0, 0]


## One language of one day: {sec, by, n, lesson:[ok,total], score:[count,sum]} with all limits applied.
static func clean_rec(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return blank_rec()
	var r: Dictionary = v
	var les: Array = _pair(r.get("lesson", null))
	les[0] = mini(les[0], les[1])
	var sc: Array = _pair(r.get("score", null))
	sc[1] = mini(sc[1], sc[0] * 100)
	return {
		"sec": to_int(r.get("sec", 0), 0, MAX_SEC_PER_DAY),
		"by": clean_counts(r.get("by", null), MAX_SEC_PER_DAY),
		"n": clean_counts(r.get("n", null), MAX_COUNT),
		"lesson": les,
		"score": sc,
	}


static func rec_nonzero(r: Dictionary) -> bool:
	return int(r["sec"]) > 0 or not (r["by"] as Dictionary).is_empty() or not (r["n"] as Dictionary).is_empty() \
		or int((r["lesson"] as Array)[0]) > 0 or int((r["lesson"] as Array)[1]) > 0 \
		or int((r["score"] as Array)[0]) > 0 or int((r["score"] as Array)[1]) > 0


## {iso: {lang: rec}}: valid dates and languages only, all-zero records dropped.
static func clean_days(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for iso in (v as Dictionary):
		if not is_iso(iso):
			continue
		var per: Variant = (v as Dictionary)[iso]
		if not (per is Dictionary):
			continue
		var one := {}
		for l in LANGS:
			if (per as Dictionary).has(l):
				var rec: Dictionary = clean_rec((per as Dictionary)[l])
				if rec_nonzero(rec):
					one[l] = rec
		if not one.is_empty():
			out[iso] = one
	return out


static func clean_h(v: Variant) -> String:
	if not (v is String):
		return ""
	var h: String = ""
	for ch in (v as String):
		if ch == "0" or ch == "1":
			h += ch
	if h.length() > HISTORY:
		h = h.substr(h.length() - HISTORY)
	return h


## {sound: count} (count > 0), at most MAX_HEARD entries (the biggest ones).
static func clean_heard(v: Variant) -> Dictionary:
	var out := {}
	if v is Dictionary:
		for k in (v as Dictionary):
			if k is String and (k as String) != "" and (k as String).length() <= MAX_P_LEN:
				var c: int = to_int((v as Dictionary)[k], 0, MAX_COUNT)
				if c > 0:
					out[k] = c
	return trim_heard(out)


static func trim_heard(heard: Dictionary) -> Dictionary:
	if heard.size() <= MAX_HEARD:
		return heard
	var keys: Array = heard.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		if heard[a] != heard[b]:
			return heard[a] > heard[b]
		return str(a) < str(b))
	var kept := {}
	for i in MAX_HEARD:
		kept[keys[i]] = heard[keys[i]]
	return kept


## Keeps the MAX_PHONEMES sounds with the longest history (ties: by symbol). `phon` = {p: {h, ...}}.
static func prune_phon(phon: Dictionary) -> Dictionary:
	if phon.size() <= MAX_PHONEMES:
		return phon
	var keys: Array = phon.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var na: int = str((phon[a] as Dictionary).get("h", "")).length()
		var nb: int = str((phon[b] as Dictionary).get("h", "")).length()
		if na != nb:
			return na > nb
		return str(a) < str(b))
	var kept := {}
	for i in MAX_PHONEMES:
		kept[keys[i]] = phon[keys[i]]
	return kept


## One language of the phoneme map: {p: {h, heard}} (empty entries dropped).
static func clean_phon_lang(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for p in (v as Dictionary):
		if not (p is String) or (p as String).strip_edges() == "" or (p as String).length() > MAX_P_LEN:
			continue
		var e: Variant = (v as Dictionary)[p]
		if not (e is Dictionary):
			continue
		var h: String = clean_h((e as Dictionary).get("h", null))
		var heard: Dictionary = clean_heard((e as Dictionary).get("heard", null))
		if h != "" or not heard.is_empty():
			out[p] = {"h": h, "heard": heard}
	return prune_phon(out)


static func clean_mission(m: Variant) -> Dictionary:
	if not (m is Dictionary):
		return {}
	var d: Dictionary = m
	var dg: Variant = d.get("done_goals", 0)
	var last_v: Variant = d.get("last", "")
	return {
		"stars": to_int(d.get("stars", 0), 0, 3),
		"plays": to_int(d.get("plays", 0), 0, MAX_COUNT),
		"last": last_v if is_iso(last_v) else "",
		"done_goals": (dg as Array).size() if dg is Array else to_int(dg, 0, 1000),
	}


static func clean_missions(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	var ids: Array = []
	for id in (v as Dictionary):
		if id is String and (id as String) != "" and (id as String).length() <= 64:
			ids.append(id)
	ids.sort()
	for id in ids:
		if out.size() >= MAX_MISSIONS:
			break
		var m: Dictionary = clean_mission((v as Dictionary)[id])
		if not m.is_empty():
			out[id] = m
	return out


# ---------------------------------------------------------------- cards

static func _text(v: Variant) -> String:
	if v is String:
		return (v as String).left(TEXT_MAX)
	return ""


## Cleans one review card. Returns {} when it is not a card. `key_hint` = the key it is stored under (replicas).
## Result: {key, id, lang, target, reading, ko, note, due, stability, difficulty, state, step, last_review, reps, lapses}.
static func clean_card(raw: Variant, key_hint: String = "") -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	var key: String = ""
	var kv: Variant = d.get("key", "")
	if kv is String and (kv as String) != "":
		key = kv
	elif key_hint != "":
		key = key_hint
	var lang: String = ""
	var target: String = ""
	if is_lang(d.get("lang", null)):
		lang = d["lang"]
	if d.get("target", null) is String:
		target = d["target"]
	if (lang == "" or target == "") and key.length() > 3 and key.find("|") == 2:
		if lang == "" and is_lang(key.substr(0, 2)):
			lang = key.substr(0, 2)
		if target == "":
			target = key.substr(3)
	if lang == "" or target == "":
		return {}
	target = target.left(TEXT_MAX)
	if key == "":
		key = card_key(lang, target)
	var idv: Variant = d.get("id", "")
	return {
		"key": key,
		"id": idv if (idv is String and (idv as String).length() <= 64) else "",
		"lang": lang,
		"target": target,
		"reading": _text(d.get("reading", null)),
		"ko": _text(d.get("ko", null)),
		"note": _text(d.get("note", null)),
		"due": to_int(d.get("due", 0), 0, MAX_LEAF),
		"stability": to_flt(d.get("stability", 0.0), 0.0, 1.0e9, 0.0),
		"difficulty": to_flt(d.get("difficulty", 0.0), 0.0, 1.0e9, 0.0),
		"state": to_int(d.get("state", 1), 1, 3) if is_num(d.get("state", null)) else 1,
		"step": to_int(d.get("step", 0), 0, MAX_COUNT),
		"last_review": to_int(d.get("last_review", 0), 0, MAX_LEAF),
		"reps": to_int(d.get("reps", 0), 0, MAX_COUNT),
		"lapses": to_int(d.get("lapses", 0), 0, MAX_COUNT),
	}


## Deduplicated, trimmed strings; sorted when `sort_it`, else in the given order.
static func str_list(v: Variant, sort_it: bool) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	var seen := {}
	for w in (v as Array):
		if w is String:
			var t: String = (w as String).strip_edges()
			if t != "" and t.length() <= KEY_MAX and not seen.has(t):
				seen[t] = true
				out.append(t)
	if sort_it:
		out.sort()
	return out


# ---------------------------------------------------------------- view / replica normalisers

## Cleans a local view (or, with base_mode, a base: no prefs, `cards` is an array of keys). Never throws.
static func norm_view(raw: Variant, base_mode: bool = false) -> Dictionary:
	var out: Dictionary = blank_view()
	if base_mode:
		out.erase("prefs")
	if not (raw is Dictionary):
		return out
	var src: Dictionary = raw
	if is_iso(src.get("start", null)):
		out["start"] = src["start"]
	out["checks"] = str_list(src.get("checks", null), true)
	out["marks"] = str_list(src.get("marks", null), true)
	var xp: Variant = src.get("xp", null)
	var st: Variant = src.get("stats", null)
	for l in LANGS:
		(out["xp"] as Dictionary)[l] = to_int((xp as Dictionary).get(l, 0)) if xp is Dictionary else 0
		var one: Variant = (st as Dictionary).get(l, null) if st is Dictionary else null
		for k in STAT_KEYS:
			((out["stats"] as Dictionary)[l] as Dictionary)[k] = to_int((one as Dictionary).get(k, 0)) if one is Dictionary else 0
	var cs: Variant = src.get("cards", null)
	var seen := {}
	var lst: Array = []
	if cs is Array:
		for c in (cs as Array):
			if base_mode and c is String:
				if (c as String) != "" and not seen.has(c):
					seen[c] = true
					lst.append(c)
				continue
			var cc: Dictionary = clean_card(c, "")
			if cc.is_empty() or seen.has(cc["key"]):
				continue
			seen[cc["key"]] = true
			lst.append(cc["key"] if base_mode else cc)
	out["cards"] = lst
	var kn: Variant = src.get("known", null)
	for l in LANGS:
		(out["known"] as Dictionary)[l] = str_list((kn as Dictionary).get(l, null), false) if kn is Dictionary else []
	out["days"] = clean_days(src.get("days", null))
	var ph: Variant = src.get("phon", null)
	for l in LANGS:
		(out["phon"] as Dictionary)[l] = clean_phon_lang((ph as Dictionary).get(l, null) if ph is Dictionary else null)
	out["missions"] = clean_missions(src.get("missions", null))
	if not base_mode:
		var pr: Variant = src.get("prefs", null)
		for k in SHARED_PREFS.keys():
			(out["prefs"] as Dictionary)[k] = pref_or_default(k, (pr as Dictionary).get(k, null) if pr is Dictionary else null)
	return out


static func _clamp_t(t: int, cutoff: int, stat: Dictionary) -> int:
	if cutoff >= 0 and t > cutoff:
		stat["clamped"] = int(stat.get("clamped", 0)) + 1
		return cutoff
	return t


## {add:{key:t}, del:{key:t}}: non-empty string keys, finite numeric times (cut at `cutoff` when cutoff >= 0).
static func norm_set(v: Variant, cutoff: int, stat: Dictionary) -> Dictionary:
	var out: Dictionary = blank_set()
	if not (v is Dictionary):
		return out
	for part in ["add", "del"]:
		var src: Variant = (v as Dictionary).get(part, null)
		if not (src is Dictionary):
			continue
		var dst: Dictionary = out[part]
		for k in (src as Dictionary):
			if k is String and (k as String) != "" and (k as String).length() <= KEY_MAX:
				var tv: Variant = (src as Dictionary)[k]
				if tv is int or (tv is float and is_finite(tv)):
					dst[k] = _clamp_t(to_int(tv, 0, MAX_TIME), cutoff, stat)
	return out


static func _norm_reg(v: Variant, key: String, cutoff: int, stat: Dictionary) -> Dictionary:
	var dflt: Variant = Plan.DEFAULT_START if key == "start" else SHARED_PREFS[key]
	var reg := {"value": dflt, "t": 0}
	if not (v is Dictionary):
		return reg
	var val: Variant = (v as Dictionary).get("value", null)
	var tv: Variant = (v as Dictionary).get("t", null)
	var ok: bool = is_iso(val) if key == "start" else pref_valid(key, val)
	if ok and (tv is int or (tv is float and is_finite(tv))):
		reg["value"] = val if key == "start" else pref_norm(key, val)
		reg["t"] = _clamp_t(to_int(tv, 0, MAX_TIME), cutoff, stat)
	return reg


## Cleans any value into a complete replica document (missing or broken parts become empty). Times are cut at `cutoff`
## (>= 0) and the number of cut times is added to stat["clamped"]. The input is never changed.
static func norm_replica(doc: Variant, cutoff: int, stat: Dictionary) -> Dictionary:
	var out: Dictionary = blank_replica()
	if not (doc is Dictionary):
		return out
	var d: Dictionary = doc
	var pg: Variant = d.get("progress", null)
	if pg is Dictionary:
		var p: Dictionary = pg
		var prog: Dictionary = out["progress"]
		prog["start"] = _norm_reg(p.get("start", null), "start", cutoff, stat)
		prog["checks"] = norm_set(p.get("checks", null), cutoff, stat)
		prog["marks"] = norm_set(p.get("marks", null), cutoff, stat)
		var xp: Variant = p.get("xp", null)
		var st: Variant = p.get("stats", null)
		for l in LANGS:
			(prog["xp"] as Dictionary)[l] = to_int((xp as Dictionary).get(l, 0)) if xp is Dictionary else 0
			var one: Variant = (st as Dictionary).get(l, null) if st is Dictionary else null
			for k in STAT_KEYS:
				((prog["stats"] as Dictionary)[l] as Dictionary)[k] = to_int((one as Dictionary).get(k, 0)) if one is Dictionary else 0
		var cv: Variant = p.get("cards", null)
		var cards: Dictionary = norm_set(cv, cutoff, stat)
		var data := {}
		if cv is Dictionary and (cv as Dictionary).get("data", null) is Dictionary:
			var dd: Dictionary = (cv as Dictionary)["data"]
			for k in dd:
				if k is String and (k as String) != "" and (k as String).length() <= KEY_MAX:
					var c: Dictionary = clean_card(dd[k], k)
					if not c.is_empty():
						c["key"] = k
						c["last_review"] = _clamp_t(int(c["last_review"]), cutoff, stat)
						c.erase("key")
						data[k] = c
		cards["data"] = data
		prog["cards"] = cards
		var kn: Variant = p.get("known", null)
		for l in LANGS:
			(prog["known"] as Dictionary)[l] = norm_set((kn as Dictionary).get(l, null) if kn is Dictionary else null, cutoff, stat)
	var sv: Variant = d.get("studylog", null)
	if sv is Dictionary:
		var s: Dictionary = sv
		var sl: Dictionary = out["studylog"]
		sl["days"] = clean_days(s.get("days", null))
		var ph: Variant = s.get("phon", null)
		for l in LANGS:
			var lv: Variant = (ph as Dictionary).get(l, null) if ph is Dictionary else null
			var pl := {}
			if lv is Dictionary:
				for pp in (lv as Dictionary):
					if not (pp is String) or (pp as String).strip_edges() == "" or (pp as String).length() > MAX_P_LEN:
						continue
					var e: Variant = (lv as Dictionary)[pp]
					if not (e is Dictionary):
						continue
					var h: String = clean_h((e as Dictionary).get("h", null))
					var heard: Dictionary = clean_heard((e as Dictionary).get("heard", null))
					var tv: Variant = (e as Dictionary).get("t", 0)
					var t: int = _clamp_t(to_int(tv, 0, MAX_TIME), cutoff, stat) if (tv is int or (tv is float and is_finite(tv))) else 0
					if h != "" or not heard.is_empty():
						pl[pp] = {"h": h, "t": t, "heard": heard}
			(sl["phon"] as Dictionary)[l] = prune_phon(pl)
		sl["missions"] = clean_missions(s.get("missions", null))
	var pf: Variant = d.get("prefs", null)
	if pf is Dictionary:
		for k in SHARED_PREFS.keys():
			(out["prefs"] as Dictionary)[k] = _norm_reg((pf as Dictionary).get(k, null), k, cutoff, stat)
	return out


# ---------------------------------------------------------------- extract (local files -> view)

## progress = 앱의 진행 기록, studylog = 학습 기록 스냅샷, prefs = 앱 설정. Card times get `skew` added
## (device clock -> hub clock). Protection tokens (freeze) and device-only settings are never read.
static func extract(progress: Dictionary, studylog: Dictionary, prefs: Dictionary, skew: int) -> Dictionary:
	var v: Dictionary = blank_view()
	if is_iso(progress.get("start", null)):
		v["start"] = progress["start"]
	var ck: Variant = progress.get("checks", null)
	if ck is Dictionary:
		var keys: Array = []
		for k in (ck as Dictionary):
			if k is String and (k as String) != "" and (k as String).length() <= KEY_MAX and _truthy((ck as Dictionary)[k]):
				keys.append(k)
		keys.sort()
		v["checks"] = keys
	var dv: Variant = progress.get("days", null)
	if dv is Dictionary:
		var marks: Array = []
		for iso in (dv as Dictionary):
			var rec: Variant = (dv as Dictionary)[iso]
			if rec is Dictionary and is_iso(iso):
				for l in LANGS:
					if _truthy((rec as Dictionary).get(l, false)):
						marks.append("%s|%s" % [iso, l])
		marks.sort()
		v["marks"] = marks
	var xp: Variant = progress.get("xp", null)
	var st: Variant = progress.get("stats", null)
	for l in LANGS:
		(v["xp"] as Dictionary)[l] = to_int((xp as Dictionary).get(l, 0)) if xp is Dictionary else 0
		var one: Variant = (st as Dictionary).get(l, null) if st is Dictionary else null
		for k in STAT_KEYS:
			((v["stats"] as Dictionary)[l] as Dictionary)[k] = to_int((one as Dictionary).get(k, 0)) if one is Dictionary else 0
	var rv: Variant = progress.get("review", null)
	var cards: Array = []
	if rv is Array:
		var seen := {}
		for r in (rv as Array):
			var c: Dictionary = clean_card(r, "")
			if c.is_empty():
				continue
			var key: String = card_key(c["lang"], c["target"])
			if seen.has(key):
				continue
			seen[key] = true
			c["key"] = key
			c["due"] = maxi(0, int(c["due"]) + skew)
			if int(c["last_review"]) > 0:
				c["last_review"] = maxi(1, int(c["last_review"]) + skew)
			cards.append(c)
	v["cards"] = cards
	var kw: Variant = progress.get("known_words", null)
	for l in LANGS:
		(v["known"] as Dictionary)[l] = str_list((kw as Dictionary).get(l, null), false) if kw is Dictionary else []
	v["days"] = clean_days(studylog.get("days", null))
	var ph: Variant = studylog.get("phon", null)
	for l in LANGS:
		(v["phon"] as Dictionary)[l] = clean_phon_lang((ph as Dictionary).get(l, null) if ph is Dictionary else null)
	v["missions"] = clean_missions(studylog.get("missions", null))
	for k in SHARED_PREFS.keys():
		(v["prefs"] as Dictionary)[k] = pref_or_default(k, prefs.get(k, null))
	return v


# ---------------------------------------------------------------- to_local (view -> local shapes)

## Merged view -> local shapes: {"progress", "studylog", "prefs_changes"}. Only the fields that are synchronised are
## replaced; every other key (updatedAt, unknown keys, v, saved, freeze, device-only prefs) stays as it was.
## Card times get `skew` subtracted again. The inputs are not changed.
static func to_local(view: Dictionary, skew: int, progress: Dictionary, studylog: Dictionary, prefs: Dictionary) -> Dictionary:
	var v: Dictionary = norm_view(view)
	var p: Dictionary = progress.duplicate(true)
	p["start"] = v["start"]
	var checks := {}
	for k in (v["checks"] as Array):
		checks[k] = true
	p["checks"] = checks
	# study-day marks: only the en / ja flags are touched, other keys of a day stay
	var want := {}
	for m in (v["marks"] as Array):
		var s: String = m
		var at: int = s.rfind("|")
		if at > 0 and is_iso(s.substr(0, at)) and is_lang(s.substr(at + 1)):
			want[s] = true
	var days: Dictionary = p["days"] if p.get("days", null) is Dictionary else {}
	for iso in days.keys():
		var rec: Variant = days[iso]
		if rec is Dictionary:
			for l in LANGS:
				if (rec as Dictionary).has(l) and not want.has("%s|%s" % [iso, l]):
					(rec as Dictionary).erase(l)
			if (rec as Dictionary).is_empty():
				days.erase(iso)
		else:
			days.erase(iso)
	for s in want.keys():
		var at2: int = (s as String).rfind("|")
		var iso2: String = (s as String).substr(0, at2)
		var lang2: String = (s as String).substr(at2 + 1)
		if not (days.get(iso2, null) is Dictionary):
			days[iso2] = {}
		(days[iso2] as Dictionary)[lang2] = true
	p["days"] = days
	var xp: Dictionary = p["xp"] if p.get("xp", null) is Dictionary else {}
	var stt: Dictionary = p["stats"] if p.get("stats", null) is Dictionary else {}
	for l in LANGS:
		xp[l] = int((v["xp"] as Dictionary)[l])
		var one: Dictionary = stt[l] if stt.get(l, null) is Dictionary else {}
		for k in STAT_KEYS:
			one[k] = int(((v["stats"] as Dictionary)[l] as Dictionary)[k])
		stt[l] = one
	p["xp"] = xp
	p["stats"] = stt
	# review cards: keep this device's id for a card it already has
	var local_ids := {}
	var old: Variant = progress.get("review", null)
	if old is Array:
		for r in (old as Array):
			if r is Dictionary and is_lang((r as Dictionary).get("lang", null)) and (r as Dictionary).get("target", null) is String:
				var rk: String = card_key((r as Dictionary)["lang"], (r as Dictionary)["target"])
				var rid: Variant = (r as Dictionary).get("id", "")
				if not local_ids.has(rk) and rid is String and (rid as String) != "":
					local_ids[rk] = rid
	var used := {}
	var rvs: Array = []
	for c in (v["cards"] as Array):
		var cd: Dictionary = c
		var key: String = cd["key"]
		var id: String = str(local_ids.get(key, ""))
		if id == "" or used.has(id):
			id = str(cd["id"])
		if id == "" or used.has(id):
			id = gen_id(key, used)
		used[id] = true
		var lr: int = int(cd["last_review"])
		rvs.append({
			"id": id, "lang": cd["lang"], "target": cd["target"], "reading": cd["reading"], "ko": cd["ko"], "note": cd["note"],
			"due": maxi(0, int(cd["due"]) - skew), "stability": cd["stability"], "difficulty": cd["difficulty"],
			"state": cd["state"], "step": cd["step"], "last_review": maxi(1, lr - skew) if lr > 0 else 0,
			"reps": cd["reps"], "lapses": cd["lapses"],
		})
	p["review"] = rvs
	var kw: Dictionary = p["known_words"] if p.get("known_words", null) is Dictionary else {}
	for l in LANGS:
		kw[l] = (v["known"] as Dictionary)[l].duplicate()
	p["known_words"] = kw
	# study log parts
	var sl: Dictionary = studylog.duplicate(true)
	sl["days"] = (v["days"] as Dictionary).duplicate(true)
	var ph := {}
	for l in LANGS:
		var pl := {}
		var src: Dictionary = (v["phon"] as Dictionary)[l]
		for pp in src:
			pl[pp] = {"h": (src[pp] as Dictionary)["h"], "heard": (src[pp] as Dictionary)["heard"].duplicate()}
		ph[l] = pl
	sl["phon"] = ph
	sl["missions"] = (v["missions"] as Dictionary).duplicate(true)
	# shared prefs that differ from the current ones
	var changes := {}
	for k in SHARED_PREFS.keys():
		var cur: Variant = pref_or_default(k, prefs.get(k, null))
		var nv: Variant = (v["prefs"] as Dictionary)[k]
		if not same_value(cur, nv):
			changes[k] = nv
	return {"progress": p, "studylog": sl, "prefs_changes": changes}


# ---------------------------------------------------------------- base

## The compact copy kept as `base`: no card data (keys only) and no prefs.
static func to_base(view: Dictionary) -> Dictionary:
	var v: Dictionary = view.duplicate(true)
	var keys: Array = []
	var cs: Variant = v.get("cards", null)
	if cs is Array:
		for c in (cs as Array):
			if c is Dictionary:
				keys.append(str((c as Dictionary).get("key", "")))
			elif c is String:
				keys.append(c)
	v["cards"] = keys
	v.erase("prefs")
	return v


# ---------------------------------------------------------------- replica validation (structure only)

static var _rx_check: RegEx = null
static var _rx_mark: RegEx = null
static var _rx_card: RegEx = null
static var _rx_date: RegEx = null


static func _init_rx() -> void:
	if _rx_check != null:
		return
	_rx_check = RegEx.new()
	_rx_check.compile("^[a-z]{2}-\\d{1,3}-[wmc]\\d{1,3}$")
	_rx_mark = RegEx.new()
	_rx_mark.compile("^\\d{4}-\\d{2}-\\d{2}\\|(en|ja)$")
	_rx_card = RegEx.new()
	_rx_card.compile("^(en|ja)\\|.{1,300}$")
	_rx_date = RegEx.new()
	_rx_date.compile("^\\d{4}-\\d{2}-\\d{2}$")


static func _depth_ok(v: Variant, depth: int) -> bool:
	if depth > _LIM_DEPTH:
		return false
	if v is Dictionary:
		for k in (v as Dictionary):
			if not _depth_ok((v as Dictionary)[k], depth + 1):
				return false
	elif v is Array:
		for e in (v as Array):
			if not _depth_ok(e, depth + 1):
				return false
	return true


static func _bad(out: Array, path: String, why: String) -> void:
	if out.size() < _MAX_PROBLEMS:
		out.append("%s: %s" % [path, why])


static func _is_int(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and v == floorf(v))


static func _int_ge0(out: Array, v: Variant, path: String, hi: int) -> void:
	if not _is_int(v):
		_bad(out, path, "not int")
	elif float(v) < 0.0 or float(v) > float(hi):
		_bad(out, path, "out of range")


static func _check_time_map(out: Array, v: Variant, path: String, rx: RegEx, limit: int) -> void:
	if not (v is Dictionary):
		_bad(out, path, "not object")
		return
	if (v as Dictionary).size() > limit:
		_bad(out, path, "too many")
		return
	for k in (v as Dictionary):
		if not (k is String) or (k as String) == "" or (k as String).length() > _LIM_STR:
			_bad(out, path, "bad key")
			return
		if rx != null and rx.search(k) == null:
			_bad(out, path, "bad key format")
			return
		_int_ge0(out, (v as Dictionary)[k], path + ".*", MAX_TIME)
		if out.size() >= _MAX_PROBLEMS:
			return


static func _check_set(out: Array, v: Variant, path: String, rx: RegEx, limit: int) -> void:
	if not (v is Dictionary):
		_bad(out, path, "not object")
		return
	for part in ["add", "del"]:
		if not (v as Dictionary).has(part):
			_bad(out, path + "." + part, "missing")
		else:
			_check_time_map(out, (v as Dictionary)[part], path + "." + part, rx, limit)
	if v is Dictionary and (v as Dictionary).get("add", null) is Dictionary and (v as Dictionary).get("del", null) is Dictionary:
		if (v as Dictionary)["add"].size() + (v as Dictionary)["del"].size() > limit:
			_bad(out, path, "too many")


static func _check_reg(out: Array, v: Variant, path: String, key: String) -> void:
	if not (v is Dictionary):
		_bad(out, path, "not object")
		return
	var val: Variant = (v as Dictionary).get("value", null)
	if key == "start":
		if not is_iso(val):
			_bad(out, path + ".value", "invalid")
	elif not pref_valid(key, val):
		_bad(out, path + ".value", "invalid")
	if not (v as Dictionary).has("t"):
		_bad(out, path + ".t", "missing")
	else:
		_int_ge0(out, (v as Dictionary)["t"], path + ".t", MAX_TIME)


## Structure check of a replica document. [] = fine, else ["doc.progress.xp.en: not int", ...] (paths only, no values).
static func validate_replica(doc: Variant) -> Array:
	_init_rx()
	var out: Array = []
	if not (doc is Dictionary):
		return ["doc: not object"]
	var d: Dictionary = doc
	for k in d:
		if not (k is String) or not _REPLICA_TOP.has(k):
			_bad(out, "doc", "unknown key")
	if not d.has("v") or not _is_int(d["v"]) or int(d["v"]) != SCHEMA:
		_bad(out, "doc.v", "must be %d" % SCHEMA)
	if not _depth_ok(d, 0):
		_bad(out, "doc", "too deep")
		return out
	# progress
	var pg: Variant = d.get("progress", null)
	if not (pg is Dictionary):
		_bad(out, "doc.progress", "missing or not object")
	else:
		var p: Dictionary = pg
		_check_reg(out, p.get("start", null), "doc.progress.start", "start")
		_check_set(out, p.get("checks", null), "doc.progress.checks", _rx_check, _LIM_SET)
		_check_set(out, p.get("marks", null), "doc.progress.marks", _rx_mark, _LIM_SET)
		var xp: Variant = p.get("xp", null)
		var st: Variant = p.get("stats", null)
		for l in LANGS:
			if not (xp is Dictionary) or not (xp as Dictionary).has(l):
				_bad(out, "doc.progress.xp." + l, "missing")
			else:
				_int_ge0(out, (xp as Dictionary)[l], "doc.progress.xp." + l, MAX_LEAF)
			var one: Variant = (st as Dictionary).get(l, null) if st is Dictionary else null
			for k in STAT_KEYS:
				if not (one is Dictionary) or not (one as Dictionary).has(k):
					_bad(out, "doc.progress.stats.%s.%s" % [l, k], "missing")
				else:
					_int_ge0(out, (one as Dictionary)[k], "doc.progress.stats.%s.%s" % [l, k], MAX_LEAF)
		var cv: Variant = p.get("cards", null)
		if not (cv is Dictionary):
			_bad(out, "doc.progress.cards", "missing or not object")
		else:
			_check_time_map(out, (cv as Dictionary).get("add", null), "doc.progress.cards.add", _rx_card, LIM_CARDS)
			_check_time_map(out, (cv as Dictionary).get("del", null), "doc.progress.cards.del", _rx_card, LIM_CARDS)
			var data: Variant = (cv as Dictionary).get("data", null)
			if not (data is Dictionary):
				_bad(out, "doc.progress.cards.data", "missing or not object")
			elif (data as Dictionary).size() > LIM_CARDS:
				_bad(out, "doc.progress.cards.data", "too many")
			else:
				for k in (data as Dictionary):
					var cp: String = "doc.progress.cards.data.*"
					if not (k is String) or _rx_card.search(k) == null:
						_bad(out, cp, "bad key format")
						continue
					_check_card_data(out, (data as Dictionary)[k], cp)
					if out.size() >= _MAX_PROBLEMS:
						break
		var kn: Variant = p.get("known", null)
		for l in LANGS:
			var kv: Variant = (kn as Dictionary).get(l, null) if kn is Dictionary else null
			_check_set(out, kv, "doc.progress.known." + l, null, _LIM_KNOWN)
	# studylog
	var sv: Variant = d.get("studylog", null)
	if not (sv is Dictionary):
		_bad(out, "doc.studylog", "missing or not object")
	else:
		var s: Dictionary = sv
		var dv: Variant = s.get("days", null)
		if not (dv is Dictionary):
			_bad(out, "doc.studylog.days", "missing or not object")
		elif (dv as Dictionary).size() > _LIM_DAYS:
			_bad(out, "doc.studylog.days", "too many")
		else:
			for iso in (dv as Dictionary):
				if not (iso is String) or _rx_date.search(iso) == null:
					_bad(out, "doc.studylog.days", "bad date key")
					continue
				var per: Variant = (dv as Dictionary)[iso]
				if not (per is Dictionary):
					_bad(out, "doc.studylog.days.*", "not object")
					continue
				for l in (per as Dictionary):
					if not is_lang(l):
						_bad(out, "doc.studylog.days.*", "bad language key")
						continue
					_check_rec(out, (per as Dictionary)[l], "doc.studylog.days.*." + l)
				if out.size() >= _MAX_PROBLEMS:
					break
		var ph: Variant = s.get("phon", null)
		for l in LANGS:
			var lv: Variant = (ph as Dictionary).get(l, null) if ph is Dictionary else null
			if not (lv is Dictionary):
				_bad(out, "doc.studylog.phon." + l, "missing or not object")
				continue
			if (lv as Dictionary).size() > MAX_PHONEMES:
				_bad(out, "doc.studylog.phon." + l, "too many")
				continue
			for pp in (lv as Dictionary):
				var e: Variant = (lv as Dictionary)[pp]
				var ep: String = "doc.studylog.phon.%s.*" % l
				if not (pp is String) or (pp as String) == "" or (pp as String).length() > MAX_P_LEN or not (e is Dictionary):
					_bad(out, ep, "bad entry")
					continue
				if not ((e as Dictionary).get("h", null) is String) or clean_h((e as Dictionary)["h"]) != (e as Dictionary)["h"]:
					_bad(out, ep + ".h", "invalid")
				if not (e as Dictionary).has("t"):
					_bad(out, ep + ".t", "missing")
				else:
					_int_ge0(out, (e as Dictionary)["t"], ep + ".t", MAX_TIME)
				var hv: Variant = (e as Dictionary).get("heard", null)
				if not (hv is Dictionary) or (hv as Dictionary).size() > MAX_HEARD:
					_bad(out, ep + ".heard", "invalid")
				else:
					for hk in (hv as Dictionary):
						if not (hk is String) or (hk as String).length() > MAX_P_LEN:
							_bad(out, ep + ".heard", "bad key")
						else:
							_int_ge0(out, (hv as Dictionary)[hk], ep + ".heard.*", MAX_COUNT)
		var mv: Variant = s.get("missions", null)
		if not (mv is Dictionary):
			_bad(out, "doc.studylog.missions", "missing or not object")
		elif (mv as Dictionary).size() > MAX_MISSIONS:
			_bad(out, "doc.studylog.missions", "too many")
		else:
			for id in (mv as Dictionary):
				var m: Variant = (mv as Dictionary)[id]
				if not (id is String) or (id as String) == "" or (id as String).length() > 64 or not (m is Dictionary):
					_bad(out, "doc.studylog.missions.*", "bad entry")
					continue
				_int_ge0(out, (m as Dictionary).get("stars", null), "doc.studylog.missions.*.stars", 3)
				_int_ge0(out, (m as Dictionary).get("plays", null), "doc.studylog.missions.*.plays", MAX_COUNT)
				_int_ge0(out, (m as Dictionary).get("done_goals", null), "doc.studylog.missions.*.done_goals", 1000)
				var lastv: Variant = (m as Dictionary).get("last", null)
				if not (lastv is String) or ((lastv as String) != "" and not is_iso(lastv)):
					_bad(out, "doc.studylog.missions.*.last", "invalid")
	# prefs
	var pf: Variant = d.get("prefs", null)
	if not (pf is Dictionary):
		_bad(out, "doc.prefs", "missing or not object")
	else:
		for k in (pf as Dictionary):
			if not (k is String) or not SHARED_PREFS.has(k):
				_bad(out, "doc.prefs", "unknown key")
			else:
				_check_reg(out, (pf as Dictionary)[k], "doc.prefs." + k, k)
	return out


static func _check_rec(out: Array, r: Variant, path: String) -> void:
	if not (r is Dictionary):
		_bad(out, path, "not object")
		return
	_int_ge0(out, (r as Dictionary).get("sec", null), path + ".sec", MAX_SEC_PER_DAY)
	for part in ["by", "n"]:
		var cv: Variant = (r as Dictionary).get(part, null)
		var hi: int = MAX_SEC_PER_DAY if part == "by" else MAX_COUNT
		if not (cv is Dictionary) or (cv as Dictionary).size() > MAX_KEYS:
			_bad(out, path + "." + part, "invalid")
			continue
		for k in (cv as Dictionary):
			if not (k is String) or (k as String) == "" or (k as String).length() > MAX_KEY_LEN:
				_bad(out, path + "." + part, "bad key")
			else:
				_int_ge0(out, (cv as Dictionary)[k], path + "." + part + ".*", hi)
	for part in ["lesson", "score"]:
		var pv: Variant = (r as Dictionary).get(part, null)
		if not (pv is Array) or (pv as Array).size() != 2:
			_bad(out, path + "." + part, "not pair")
		else:
			_int_ge0(out, (pv as Array)[0], path + "." + part + "[0]", MAX_COUNT)
			_int_ge0(out, (pv as Array)[1], path + "." + part + "[1]", MAX_COUNT)


static func _check_card_data(out: Array, c: Variant, path: String) -> void:
	if not (c is Dictionary):
		_bad(out, path, "not object")
		return
	var d: Dictionary = c
	for f in ["id", "lang", "target", "reading", "ko", "note"]:
		var s: Variant = d.get(f, null)
		if not (s is String):
			_bad(out, path + "." + f, "not string")
		elif (s as String).length() > (64 if f == "id" else TEXT_MAX):
			_bad(out, path + "." + f, "too long")
	if not is_lang(d.get("lang", null)):
		_bad(out, path + ".lang", "invalid")
	if d.get("target", null) is String and (d["target"] as String) == "":
		_bad(out, path + ".target", "empty")
	for f in ["due", "step", "last_review", "reps", "lapses"]:
		_int_ge0(out, d.get(f, null), path + "." + f, MAX_LEAF)
	for f in ["stability", "difficulty"]:
		var x: Variant = d.get(f, null)
		if not is_num(x) or float(x) < 0.0:
			_bad(out, path + "." + f, "invalid")
	if not _is_int(d.get("state", null)) or int(d["state"]) < 1 or int(d["state"]) > 3:
		_bad(out, path + ".state", "invalid")
