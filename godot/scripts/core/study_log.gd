class_name StudyLog
extends RefCounted
## 학습 기록 저장소 (user://studylog.json). 기존 progress.json 은 건드리지 않는다.
##
## 정적 API 만 쓴다. add_* 는 메모리만 바꾸고(dirty), 저장은 flush() (StudyClock 이 30초마다, 화면 전환 때).
## 파일이 없으면 빈 상태, 깨졌으면 `<path>.bad` 로 옮기고 빈 상태(예전 .bad 는 .bad.1, .bad.2 로 밀려 최대 3개 보존),
## `v` 가 더 크거나 모르는 최상위 키가 있어도 그 키는 그대로 보존해서 다시 쓴다.
## 파일이 있는데 열기만 실패하면(잠금 등) 이번 실행은 읽기 전용: 저장하지 않아서 원본을 덮어쓰지 않는다.
##
## 파일 모양 (v1)
##   {"v":1, "saved":unix,
##    "days": {"2026-10-16": {"en": {"sec":840, "by":{"lesson":300}, "n":{"lessons":1}, "lesson":[ok,total], "score":[count,sum]}}},
##    "phon": {"en": {"θ": {"h":"0110", "heard":{"s":5}}}},
##    "freeze": {"en": {"tokens":1, "frozen":["2026-10-14"], "awarded":0, "last":740000}},
##    "missions": {"cafe_order": {"stars":2, "plays":3, "last":"2026-10-16", "done_goals":2}}}

const VERSION := 1
const KEEP_DAYS := 400
const MAX_SEC_PER_DAY := 86400
const MAX_COUNT := 1000000
const GOAL_MAX_MIN := 240
const GOAL_DEFAULT_MIN := 10
const LANGS := ["en", "ja"]
const KINDS := ["lessons", "talks", "missions", "reviews", "shadow", "dictation", "drill"]
const VIEWS := ["today", "lesson", "talk", "reading", "review", "roadmap", "practice", "stats"]
const KNOWN_KEYS := ["v", "saved", "days", "phon", "freeze", "missions"]
const MAX_MISSIONS := 200
const KEEP_BAD := 3 ## .bad, .bad.1, .bad.2

static var path := "user://studylog.json"
## Tests only: pretend today is this day number (Plan.days_from_civil). -1 = system clock.
static var today_override: int = -1
## "new" | "ok" | "empty" | "bad" | "unreadable" -- how the last load_from_disk() went.
static var last_load_status: String = ""
## Tests only: (path: String) -> FileAccess or null, replaces FileAccess.open(path, READ) when loading.
static var open_hook: Callable = Callable()

static var _data: Dictionary = {}
static var _loaded: bool = false
static var _dirty: bool = false
## The file exists but could not be opened: keep it as it is (no saving) until the next load_from_disk().
static var _read_only: bool = false


# ---------------------------------------------------------------- load / save

static func today() -> int:
	return today_override if today_override >= 0 else Plan.today_days()


## Reads the file. There is deliberately no function called reload: calling that name on the class would run
## Godot's built-in GDScript.reload() and reset the static variables (path included).
static func load_from_disk() -> void:
	_loaded = true
	_dirty = false
	_read_only = false
	_data = _blank()
	last_load_status = "new"
	if not FileAccess.file_exists(path):
		return
	var f: FileAccess = open_hook.call(path) if open_hook.is_valid() else FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_load_status = "unreadable"
		_read_only = true
		Toast.info("학습 기록 파일을 읽지 못했어요. 이번에는 기록을 저장하지 않고, 다음에 다시 시도해요.")
		return
	var text: String = f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		last_load_status = "empty"
		return
	var js := JSON.new()
	if js.parse(text) != OK or not (js.data is Dictionary):
		last_load_status = "bad"
		_quarantine()
		return
	_data = _normalize(js.data)
	last_load_status = "ok"


## Writes the file if something changed. Returns true when the file was written.
static func flush() -> bool:
	_ensure()
	if not _dirty or _read_only:
		return false
	_prune_for_save()
	_data["saved"] = int(Time.get_unix_time_from_system())
	if not _write_text(JSON.stringify(_data)):
		return false
	_dirty = false
	return true


## Deletes all records (also the unknown keys) and writes an empty file.
static func reset() -> void:
	_loaded = true
	_data = _blank()
	_dirty = false
	if _read_only:
		return ## the real file could not be read: do not overwrite it
	last_load_status = "new"
	_write_text(JSON.stringify(_data))


## Deep copy of the in-memory state (tests / debugging).
static func snapshot() -> Dictionary:
	_ensure()
	return _data.duplicate(true)


static func is_dirty() -> bool:
	return _dirty


## True when the file could not be opened at load time (nothing is saved this run).
static func is_read_only() -> bool:
	_ensure()
	return _read_only


static func _ensure() -> void:
	if not _loaded:
		load_from_disk()


## Moves the broken file to `<path>.bad`; older ones shift to .bad.1, .bad.2 (KEEP_BAD files at most).
static func _quarantine() -> void:
	var gp: String = ProjectSettings.globalize_path(path)
	var i: int = KEEP_BAD - 1
	while i >= 0:
		var from: String = gp + (".bad" if i == 0 else ".bad.%d" % i)
		if FileAccess.file_exists(from):
			if i == KEEP_BAD - 1:
				DirAccess.remove_absolute(from)
			else:
				var to: String = gp + ".bad.%d" % (i + 1)
				if FileAccess.file_exists(to):
					DirAccess.remove_absolute(to)
				DirAccess.rename_absolute(from, to)
		i -= 1
	DirAccess.rename_absolute(gp, gp + ".bad")


static func _write_text(text: String) -> bool:
	var tmp: String = path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	var err: int = f.get_error()
	f.close()
	if err != OK:
		return false
	var gt: String = ProjectSettings.globalize_path(tmp)
	if DirAccess.rename_absolute(gt, ProjectSettings.globalize_path(path)) == OK:
		return true
	# rename refused (target busy?): fall back to a plain overwrite
	var f2: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f2 == null:
		return false
	f2.store_string(text)
	f2.close()
	DirAccess.remove_absolute(gt)
	return true


static func _prune_for_save() -> void:
	var oldest: int = today() - (KEEP_DAYS - 1)
	var days: Dictionary = _data["days"]
	for iso in days.keys():
		if _iso_days(str(iso)) < oldest:
			days.erase(iso)
	for l in LANGS:
		PhonemeStats.prune(((_data["phon"] as Dictionary)[l]) as Dictionary, PhonemeStats.MAX_PHONEMES)
		var fz: Dictionary = ((_data["freeze"] as Dictionary)[l]) as Dictionary
		var keep: Array = []
		for iso in fz["frozen"]:
			if _iso_days(str(iso)) >= oldest:
				keep.append(iso)
		fz["frozen"] = keep


# ---------------------------------------------------------------- normalizing (anything read from disk)

static func _blank_freeze() -> Dictionary:
	return {"tokens": 1, "frozen": [], "awarded": 0, "last": 0}


static func _blank() -> Dictionary:
	return {
		"v": VERSION,
		"saved": 0,
		"days": {},
		"phon": {"en": {}, "ja": {}},
		"freeze": {"en": _blank_freeze(), "ja": _blank_freeze()},
		"missions": {},
	}


## Integer in [lo, hi]; anything that is not a finite number becomes 0 (then clamped).
static func _n(v: Variant, lo: int = 0, hi: int = MAX_COUNT) -> int:
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


## Cleans anything into the current shape. Unknown top-level keys are kept (deep copy).
static func _normalize(raw: Variant) -> Dictionary:
	var out: Dictionary = _blank()
	if not (raw is Dictionary):
		return out
	var src: Dictionary = raw
	for k in src.keys():
		if k is String and not KNOWN_KEYS.has(k):
			var keep: Variant = src[k]
			out[k] = keep.duplicate(true) if (keep is Dictionary or keep is Array) else keep
	out["v"] = _n(src.get("v", 1), 1, 1000000)
	out["saved"] = _n(src.get("saved", 0), 0, 9223372036854775807 / 2)
	out["days"] = _norm_days(src.get("days", null))
	var pin: Variant = src.get("phon", null)
	var phon_out := {}
	for l in LANGS:
		phon_out[l] = _norm_phon(pin.get(l, null) if pin is Dictionary else null)
	out["phon"] = phon_out
	var fin: Variant = src.get("freeze", null)
	var fz_out := {}
	for l in LANGS:
		fz_out[l] = _norm_freeze(fin.get(l, null) if fin is Dictionary else null)
	out["freeze"] = fz_out
	out["missions"] = _norm_missions(src.get("missions", null))
	return out


static func _norm_days(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for iso in (v as Dictionary).keys():
		if not (iso is String) or _iso_days(iso) < 0:
			continue
		var per: Variant = (v as Dictionary)[iso]
		if not (per is Dictionary):
			continue
		var one := {}
		for l in LANGS:
			var rec: Variant = (per as Dictionary).get(l, null)
			if rec is Dictionary:
				one[l] = _norm_rec(rec)
		if not one.is_empty():
			out[iso] = one
	return out


static func _norm_rec(r: Dictionary) -> Dictionary:
	var les: Array = _pair(r.get("lesson", null))
	les[0] = mini(les[0], les[1])
	var sc: Array = _pair(r.get("score", null))
	sc[1] = mini(sc[1], sc[0] * 100)
	return {
		"sec": _n(r.get("sec", 0), 0, MAX_SEC_PER_DAY),
		"by": _counts(r.get("by", null), MAX_SEC_PER_DAY),
		"n": _counts(r.get("n", null), MAX_COUNT),
		"lesson": les,
		"score": sc,
	}


static func _pair(v: Variant) -> Array:
	if v is Array and (v as Array).size() >= 2:
		return [_n((v as Array)[0]), _n((v as Array)[1])]
	return [0, 0]


static func _counts(v: Variant, hi: int) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for k in (v as Dictionary).keys():
		if out.size() >= 32:
			break
		if k is String and (k as String).length() > 0 and (k as String).length() <= 24:
			var x: int = _n((v as Dictionary)[k], 0, hi)
			if x > 0:
				out[k] = x
	return out


static func _norm_phon(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for p in (v as Dictionary).keys():
		if not (p is String) or (p as String).strip_edges() == "" or (p as String).length() > PhonemeStats.MAX_P_LEN:
			continue
		var e: Variant = (v as Dictionary)[p]
		if not (e is Dictionary):
			continue
		var h_raw: Variant = (e as Dictionary).get("h", null)
		var h := ""
		if h_raw is String:
			for ch in (h_raw as String):
				if ch == "0" or ch == "1":
					h += ch
			if h.length() > PhonemeStats.HISTORY:
				h = h.substr(h.length() - PhonemeStats.HISTORY)
		var heard := {}
		var hv: Variant = (e as Dictionary).get("heard", null)
		if hv is Dictionary:
			for hk in (hv as Dictionary).keys():
				if hk is String and (hk as String) != "" and (hk as String).length() <= PhonemeStats.MAX_P_LEN:
					var c: int = _n((hv as Dictionary)[hk], 0, MAX_COUNT)
					if c > 0:
						heard[hk] = c
		PhonemeStats._trim_heard(heard)
		out[p] = {"h": h, "heard": heard}
	PhonemeStats.prune(out, PhonemeStats.MAX_PHONEMES)
	return out


static func _norm_freeze(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return _blank_freeze()
	var d: Dictionary = v
	var frozen: Array = []
	var seen := {}
	var fr: Variant = d.get("frozen", null)
	if fr is Array:
		for iso in fr:
			if iso is String and _iso_days(iso) >= 0 and not seen.has(iso):
				seen[iso] = true
				frozen.append(iso)
		frozen.sort()
	return {
		"tokens": _n(d.get("tokens", 1), 0, StreakCalc.MAX_TOKENS) if d.has("tokens") else 1,
		"frozen": frozen,
		"awarded": _n(d.get("awarded", 0), 0, 100000),
		"last": _n(d.get("last", 0), 0, 100000000),
	}


static func _norm_missions(v: Variant) -> Dictionary:
	var out := {}
	if not (v is Dictionary):
		return out
	for id in (v as Dictionary).keys():
		if out.size() >= MAX_MISSIONS:
			break
		if not (id is String) or (id as String) == "" or (id as String).length() > 64:
			continue
		var m: Variant = (v as Dictionary)[id]
		if not (m is Dictionary):
			continue
		var dg: Variant = (m as Dictionary).get("done_goals", 0)
		var last_v: Variant = (m as Dictionary).get("last", "")
		out[id] = {
			"stars": _n((m as Dictionary).get("stars", 0), 0, 3),
			"plays": _n((m as Dictionary).get("plays", 0)),
			"last": last_v if (last_v is String and _iso_days(last_v) >= 0) else "",
			"done_goals": (dg as Array).size() if dg is Array else _n(dg, 0, 1000),
		}
	return out


## "YYYY-MM-DD" -> day number, -1 when it is not a real calendar date.
static func _iso_days(s: String) -> int:
	if s.length() != 10 or s[4] != "-" or s[7] != "-":
		return -1
	var ys: String = s.substr(0, 4)
	var ms: String = s.substr(5, 2)
	var ds: String = s.substr(8, 2)
	if not (ys.is_valid_int() and ms.is_valid_int() and ds.is_valid_int()):
		return -1
	var y: int = int(ys)
	var m: int = int(ms)
	var d: int = int(ds)
	if m < 1 or m > 12 or d < 1 or d > 31:
		return -1
	var days: int = Plan.days_from_civil(y, m, d)
	var back: Dictionary = Plan.civil_from_days(days)
	if int(back["month"]) != m or int(back["day"]) != d:
		return -1
	return days


# ---------------------------------------------------------------- recording

static func _valid_lang(lang: String) -> bool:
	return lang == "en" or lang == "ja"


## Today's record of `lang` (live dictionary). Created on demand when `create`, else a detached empty one.
static func _rec(lang: String, create: bool) -> Dictionary:
	_ensure()
	var iso: String = Plan.days_to_iso(today())
	var days: Dictionary = _data["days"]
	if not days.has(iso):
		if not create:
			return _norm_rec({})
		days[iso] = {}
	var per: Dictionary = days[iso]
	if not per.has(lang):
		if not create:
			return _norm_rec({})
		per[lang] = _norm_rec({})
	return per[lang]


static func _bump(d: Dictionary, key: String, amount: int) -> void:
	d[key] = int(d.get(key, 0)) + amount


static func add_seconds(lang: String, view: String, sec: int) -> void:
	if not _valid_lang(lang) or sec <= 0:
		return
	var r: Dictionary = _rec(lang, true)
	sec = mini(sec, MAX_SEC_PER_DAY - int(r["sec"]))
	if sec <= 0:
		return
	r["sec"] = int(r["sec"]) + sec
	_bump(r["by"], view if VIEWS.has(view) else "other", sec)
	_dirty = true


static func add_event(lang: String, kind: String, n: int = 1) -> void:
	if not _valid_lang(lang) or not KINDS.has(kind) or n <= 0:
		return
	var r: Dictionary = _rec(lang, true)
	_bump(r["n"], kind, mini(n, 1000))
	_dirty = true


## Lesson result: `ok` of `total` exercises right. Also counts as one finished lesson (n.lessons).
static func add_lesson(lang: String, ok: int, total: int) -> void:
	if not _valid_lang(lang) or total <= 0 or total > 1000:
		return
	var r: Dictionary = _rec(lang, true)
	var pair: Array = r["lesson"]
	pair[0] = int(pair[0]) + clampi(ok, 0, total)
	pair[1] = int(pair[1]) + total
	_bump(r["n"], "lessons", 1)
	_dirty = true


## Folds a /score response into the pronunciation average and the per-phoneme history.
## Silent recordings (empty transcript) and malformed responses are ignored -> false.
static func add_score(lang: String, res: Dictionary, source: String) -> bool:
	return add_score_any(lang, res, source)


## Same as add_score for a raw (possibly null / non-dictionary) JSON value.
static func add_score_any(lang: String, res: Variant, _source: String = "") -> bool:
	if not _valid_lang(lang) or not (res is Dictionary):
		return false
	var d: Dictionary = res
	var tr: Variant = d.get("transcript", null)
	if not (tr is String) or (tr as String).strip_edges() == "":
		return false
	if not (d.get("units", null) is Array):
		return false
	var sv: Variant = d.get("score", null)
	if not (sv is int or (sv is float and is_finite(sv))):
		return false
	var score: int = clampi(roundi(float(sv)), 0, 100)
	var r: Dictionary = _rec(lang, true)
	var pair: Array = r["score"]
	pair[0] = int(pair[0]) + 1
	pair[1] = int(pair[1]) + score
	PhonemeStats.observe(((_data["phon"] as Dictionary)[lang]) as Dictionary, d)
	_dirty = true
	return true


static func add_mission(lang: String, id: String, stars: int, done_goals: int) -> void:
	if not _valid_lang(lang) or id.strip_edges() == "" or id.length() > 64:
		return
	_ensure()
	var ms: Dictionary = _data["missions"]
	if not ms.has(id) and ms.size() >= MAX_MISSIONS:
		return
	var m: Dictionary = ms.get(id, {"stars": 0, "plays": 0, "last": "", "done_goals": 0})
	m["stars"] = maxi(int(m["stars"]), clampi(stars, 0, 3))
	m["plays"] = mini(int(m["plays"]) + 1, MAX_COUNT)
	m["last"] = Plan.days_to_iso(today())
	m["done_goals"] = clampi(done_goals, 0, 1000)
	ms[id] = m
	_dirty = true


## Raises the best record of an already played mission (stars / goals) WITHOUT counting another play.
## Used when the result screen changes the result of the game that was just logged by add_mission().
static func update_mission_best(lang: String, id: String, stars: int, done_goals: int) -> void:
	if not _valid_lang(lang) or id.strip_edges() == "" or id.length() > 64:
		return
	_ensure()
	var ms: Dictionary = _data["missions"]
	if not ms.has(id):
		return
	var m: Dictionary = ms[id]
	var s: int = maxi(int(m["stars"]), clampi(stars, 0, 3))
	var g: int = maxi(int(m["done_goals"]), clampi(done_goals, 0, 1000))
	if s == int(m["stars"]) and g == int(m["done_goals"]):
		return
	m["stars"] = s
	m["done_goals"] = g
	_dirty = true


static func mission_best(id: String) -> Dictionary:
	_ensure()
	var m: Variant = (_data["missions"] as Dictionary).get(id, null)
	if m is Dictionary:
		return (m as Dictionary).duplicate(true)
	return {}


static func mission_ids() -> Array:
	_ensure()
	return (_data["missions"] as Dictionary).keys()


# ---------------------------------------------------------------- goal / streak

## Daily goal in minutes (0 = off). Stored in prefs ("daily_goal_min").
static func goal_minutes() -> int:
	var v: Variant = Store.prefs.get("daily_goal_min", GOAL_DEFAULT_MIN)
	if v is int or (v is float and is_finite(v)):
		return clampi(int(v), 0, GOAL_MAX_MIN)
	return GOAL_DEFAULT_MIN


static func set_goal_minutes(m: int) -> void:
	Store.set_pref("daily_goal_min", clampi(m, 0, GOAL_MAX_MIN))


static func today_seconds(lang: String) -> int:
	if not _valid_lang(lang):
		return 0
	return int(_rec(lang, false)["sec"])


static func _freeze(lang: String) -> Dictionary:
	_ensure()
	return ((_data["freeze"] as Dictionary)[lang]) as Dictionary


## Days (day number -> true) with a study mark in progress.json for `lang`.
static func _done_days(lang: String) -> Dictionary:
	var done := {}
	var days: Variant = Store.progress.get("days", null)
	if not (days is Dictionary):
		return done
	for iso in (days as Dictionary).keys():
		var rec: Variant = (days as Dictionary)[iso]
		if rec is Dictionary and bool((rec as Dictionary).get(lang, false)) and iso is String:
			var d: int = _iso_days(iso)
			if d >= 0:
				done[d] = true
	return done


## Applies streak protection for today (idempotent) and returns {streak, tokens, used, gained}.
## Clock rewind guard: `freeze.<lang>.last` is the latest day settle() ever applied. When today is earlier than that
## (the clock was set back after having been set forward) nothing is changed, spent or paid -- the streak is only
## calculated for display -- so tokens cannot be granted a second time for a run that was already paid.
static func settle(lang: String) -> Dictionary:
	if not _valid_lang(lang):
		return {"streak": 0, "tokens": 0, "used": 0, "gained": 0}
	var fz: Dictionary = _freeze(lang)
	var frozen := {}
	for iso in fz["frozen"]:
		var fd: int = _iso_days(str(iso))
		if fd >= 0:
			frozen[fd] = true
	var t: int = today()
	var res: Dictionary = StreakCalc.settle(_done_days(lang), frozen, int(fz["tokens"]), int(fz["awarded"]), t)
	if t < int(fz["last"]):
		return {"streak": int(res["streak"]), "tokens": int(fz["tokens"]), "used": 0, "gained": 0}
	var list: Array = []
	for d in (res["frozen"] as Dictionary).keys():
		list.append(Plan.days_to_iso(int(d)))
	list.sort()
	fz["last"] = t ## saved together with the next real change (advancing it alone does not make the log dirty)
	if int(res["tokens"]) != int(fz["tokens"]) or int(res["awarded"]) != int(fz["awarded"]) or list != fz["frozen"]:
		fz["tokens"] = int(res["tokens"])
		fz["awarded"] = int(res["awarded"])
		fz["frozen"] = list
		_dirty = true
	if int(res["used"]) > 0:
		Toast.info("연속 기록 보호권 %d개를 써서 연속 기록을 지켰어요" % int(res["used"]))
	if int(res["gained"]) > 0:
		Toast.ok("연속 %d일! 보호권 %d개를 받았어요" % [int(res["streak"]), int(res["gained"])])
	return {"streak": int(res["streak"]), "tokens": int(res["tokens"]), "used": int(res["used"]), "gained": int(res["gained"])}


static func streak(lang: String) -> int:
	return int(settle(lang)["streak"])


static func tokens(lang: String) -> int:
	return int(settle(lang)["tokens"])


# ---------------------------------------------------------------- reading back

## `days` entries (1..KEEP_DAYS), oldest first, ending today. Days without a record are all zero.
static func range_summary(lang: String, days: int) -> Array:
	var out: Array = []
	if not _valid_lang(lang) or days <= 0:
		return out
	_ensure()
	days = mini(days, KEEP_DAYS)
	var end: int = today()
	var all: Dictionary = _data["days"]
	for i in range(days):
		var iso: String = Plan.days_to_iso(end - (days - 1 - i))
		var r: Dictionary = {}
		if all.has(iso) and (all[iso] as Dictionary).has(lang):
			r = (all[iso] as Dictionary)[lang]
		else:
			r = _norm_rec({})
		var n: Dictionary = {}
		for k in KINDS:
			n[k] = 0
		for k in (r["n"] as Dictionary).keys():
			n[k] = int((r["n"] as Dictionary)[k])
		out.append({
			"iso": iso,
			"sec": int(r["sec"]),
			"lessons_ok": int((r["lesson"] as Array)[0]),
			"lessons_n": int((r["lesson"] as Array)[1]),
			"score_n": int((r["score"] as Array)[0]),
			"score_sum": int((r["score"] as Array)[1]),
			"n": n,
		})
	return out


## [{p, n, bad, rate, heard}] weakest first (see PhonemeStats.weakest).
static func weak_phonemes(lang: String, limit: int, min_n: int = 5) -> Array:
	if not _valid_lang(lang):
		return []
	_ensure()
	return PhonemeStats.weakest(((_data["phon"] as Dictionary)[lang]) as Dictionary, limit, min_n)


## True when anything at all was recorded for `lang` (stats screen empty state).
static func has_data(lang: String) -> bool:
	if not _valid_lang(lang):
		return false
	_ensure()
	for iso in (_data["days"] as Dictionary).keys():
		var per: Dictionary = (_data["days"] as Dictionary)[iso]
		if per.has(lang):
			var r: Dictionary = per[lang]
			if int(r["sec"]) > 0 or int((r["lesson"] as Array)[1]) > 0 or int((r["score"] as Array)[0]) > 0 or not (r["n"] as Dictionary).is_empty():
				return true
	if not ((_data["phon"] as Dictionary)[lang] as Dictionary).is_empty():
		return true
	return lang == "en" and not (_data["missions"] as Dictionary).is_empty()
