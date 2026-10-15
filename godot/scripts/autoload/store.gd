extends Node
## App state: progress (user://progress.json), preferences (user://prefs.json),
## curriculum data, and a small navigation signal bus.

signal changed ## progress changed
signal prefs_changed
signal navigate(view: String, lang: String)
signal curriculum_updated

const PROGRESS_PATH := "user://progress.json"
const PREFS_PATH := "user://prefs.json"
const CURRICULUM_CACHE := "user://curriculum.json"
const CURRICULUM_BUNDLED := "res://data/curriculum.json"

const DEFAULT_PREFS := {
	"lang": "en",
	"tts_speed": 1.0,
	"mic_device": "Default",
	"auto_speak": true,
	"show_fix": true,
	"show_reading": true,
	"show_ko": false,
	"auto_send": true,
	"open_months": {},
}

var progress_path: String = PROGRESS_PATH
var progress: Dictionary = Progress.blank()
var prefs: Dictionary = DEFAULT_PREFS.duplicate(true)
var curriculum: Dictionary = {}
var curriculum_from_backend: bool = false
var time_offset: int = 0 ## seconds added to the clock for review scheduling (tests only)


func _ready() -> void:
	load_prefs()
	load_progress()
	_load_curriculum_local()


# ---------------------------------------------------------------- persistence

func load_progress() -> void:
	progress = Progress.load_file(progress_path)


func save_progress() -> void:
	progress["updatedAt"] = int(Time.get_unix_time_from_system())
	if not Progress.save_file(progress_path, progress):
		Toast.error("진행 기록을 저장하지 못했어요.")
	changed.emit()


func load_prefs() -> void:
	prefs = DEFAULT_PREFS.duplicate(true)
	if FileAccess.file_exists(PREFS_PATH):
		var f := FileAccess.open(PREFS_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				for k in (parsed as Dictionary).keys():
					prefs[k] = (parsed as Dictionary)[k]


func save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(prefs, "\t"))
	prefs_changed.emit()


func set_pref(key: String, value: Variant) -> void:
	prefs[key] = value
	save_prefs()


func pref_bool(key: String) -> bool:
	return bool(prefs.get(key, false))


func lang() -> String:
	var l: String = str(prefs.get("lang", "en"))
	return l if l == "ja" else "en"


func set_lang(l: String) -> void:
	set_pref("lang", l)


# ---------------------------------------------------------------- curriculum

func _load_curriculum_local() -> void:
	for path in [CURRICULUM_CACHE, CURRICULUM_BUNDLED]:
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null:
				continue
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if _valid_curriculum(parsed):
				curriculum = parsed
				return


static func _valid_curriculum(v: Variant) -> bool:
	if not (v is Dictionary):
		return false
	var d: Dictionary = v
	for l in ["en", "ja"]:
		if not d.has(l) or not (d[l] is Dictionary) or not (d[l] as Dictionary).has("months"):
			return false
	return true


## Refresh from the backend (GET /curriculum); keeps the local copy on failure.
func refresh_curriculum() -> void:
	var req_call = Api.get_json("/curriculum", Api.TIMEOUT_SHORT, false)
	var res: Dictionary = await req_call.wait()
	if res["ok"] and _valid_curriculum(res["data"]):
		curriculum = res["data"]
		curriculum_from_backend = true
		var f := FileAccess.open(CURRICULUM_CACHE, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(curriculum))
		curriculum_updated.emit()


func months(l: String) -> Array:
	if not curriculum.has(l):
		return []
	return (curriculum[l] as Dictionary).get("months", [])


func month_data(l: String, n: int) -> Dictionary:
	for m in months(l):
		if int((m as Dictionary).get("n", 0)) == n:
			return m
	var ms := months(l)
	if ms.is_empty():
		return {"n": n, "title": "", "goal": "", "content": [], "weeks": [], "missions": [], "checks": []}
	return ms[0]


func week_data(l: String, n: int, w: int) -> Dictionary:
	var weeks: Array = month_data(l, n).get("weeks", [])
	if weeks.is_empty():
		return {"w": "%d주차" % w, "topic": "", "act": ""}
	return weeks[clampi(w - 1, 0, weeks.size() - 1)]


func roadmap_rows(l: String) -> Array:
	if not curriculum.has(l):
		return []
	var rm: Dictionary = (curriculum[l] as Dictionary).get("roadmap", {})
	return rm.get("rows", [])


# ---------------------------------------------------------------- position / dates

func start_iso() -> String:
	return str(progress.get("start", Plan.DEFAULT_START))


func position() -> Dictionary:
	return Plan.position(start_iso(), Plan.today_days())


func set_start(iso: String) -> bool:
	if not Plan.is_valid_iso(iso):
		return false
	progress["start"] = iso
	save_progress()
	return true


# ---------------------------------------------------------------- checks

func check_key(l: String, n: int, kind: String, i: int) -> String:
	return "%s-%d-%s%d" % [l, n, kind, i]


func is_checked(key: String) -> bool:
	return bool((progress["checks"] as Dictionary).get(key, false))


func set_checked(key: String, on: bool) -> void:
	var checks: Dictionary = progress["checks"]
	if on:
		checks[key] = true
	else:
		checks.erase(key)
	save_progress()


func month_items(l: String, n: int) -> Array[String]:
	var m := month_data(l, n)
	var keys: Array[String] = []
	for i in (m.get("weeks", []) as Array).size():
		keys.append(check_key(l, n, "w", i))
	for i in (m.get("missions", []) as Array).size():
		keys.append(check_key(l, n, "m", i))
	for i in (m.get("checks", []) as Array).size():
		keys.append(check_key(l, n, "c", i))
	return keys


func pct(keys: Array) -> int:
	if keys.is_empty():
		return 0
	var done := 0
	for k in keys:
		if is_checked(str(k)):
			done += 1
	return roundi(float(done) / float(keys.size()) * 100.0)


func lang_pct(l: String) -> int:
	var all: Array = []
	for m in months(l):
		all.append_array(month_items(l, int((m as Dictionary).get("n", 0))))
	return pct(all)


# ---------------------------------------------------------------- study days / streak / xp

func did_day(days: int, l: String) -> bool:
	var rec: Variant = (progress["days"] as Dictionary).get(Plan.days_to_iso(days), null)
	return rec is Dictionary and bool((rec as Dictionary).get(l, false))


func mark_today(l: String) -> void:
	var k := Plan.today_iso()
	var days: Dictionary = progress["days"]
	var rec: Dictionary = days.get(k, {})
	rec[l] = true
	days[k] = rec


func toggle_today(l: String) -> void:
	var k := Plan.today_iso()
	var days: Dictionary = progress["days"]
	var rec: Dictionary = days.get(k, {})
	if rec.get(l, false):
		rec.erase(l)
	else:
		rec[l] = true
	if rec.is_empty():
		days.erase(k)
	else:
		days[k] = rec
	save_progress()


func streak(l: String) -> int:
	var d := Plan.today_days()
	var c := 0
	if not did_day(d, l):
		d -= 1
	while did_day(d, l):
		c += 1
		d -= 1
	return c


func xp(l: String) -> int:
	return int((progress["xp"] as Dictionary).get(l, 0))


func add_xp(l: String, amount: int) -> void:
	(progress["xp"] as Dictionary)[l] = xp(l) + amount


func stat(l: String, key: String) -> int:
	return int(((progress["stats"] as Dictionary)[l] as Dictionary).get(key, 0))


func inc_stat(l: String, key: String) -> void:
	((progress["stats"] as Dictionary)[l] as Dictionary)[key] = stat(l, key) + 1


func reset_progress() -> void:
	var keep_start: String = start_iso()
	progress = Progress.blank()
	progress["start"] = keep_start
	save_progress()


# ---------------------------------------------------------------- review list

## items: [{lang, target, reading, ko, note}]; duplicates (lang|target) are skipped.
func add_review(items: Array) -> int:
	var review: Array = progress["review"]
	var seen := {}
	for r in review:
		seen["%s|%s" % [(r as Dictionary)["lang"], (r as Dictionary)["target"]]] = true
	var added := 0
	for it in items:
		var d: Dictionary = it
		var target: String = str(d.get("target", "")).strip_edges()
		var lang: String = str(d.get("lang", ""))
		if target == "" or (lang != "en" and lang != "ja"):
			continue
		var key := "%s|%s" % [lang, target]
		if seen.has(key):
			continue
		seen[key] = true
		var item := {
			"id": Progress.new_id(),
			"lang": lang,
			"target": target.left(300),
			"reading": str(d.get("reading", "")).left(300),
			"ko": str(d.get("ko", "")).left(300),
			"note": str(d.get("note", "")).left(300),
		}
		item.merge(FSRS.new_card(now())) # new FSRS card, due now
		review.append(item)
		added += 1
	if review.size() > Progress.MAX_REVIEW:
		progress["review"] = review.slice(review.size() - Progress.MAX_REVIEW)
	return added


func review_for(l: String) -> Array:
	var out: Array = []
	for r in progress["review"]:
		if (r as Dictionary)["lang"] == l:
			out.append(r)
	return out


func remove_review(id: String) -> void:
	var keep: Array = []
	for r in progress["review"]:
		if (r as Dictionary)["id"] != id:
			keep.append(r)
	progress["review"] = keep


## Current unix time used for review scheduling (+ time_offset, which tests use as a fake clock).
func now() -> int:
	return int(Time.get_unix_time_from_system()) + time_offset


## Items of language `l` that are due, oldest due first (ties keep list order); at most `limit`.
func due_for(l: String, limit: int = 0) -> Array:
	return _sorted_by_due(l, true, limit)


## Items of language `l` that are not due yet, soonest first.
func upcoming_for(l: String, limit: int = 0) -> Array:
	return _sorted_by_due(l, false, limit)


func due_count(l: String) -> int:
	return _sorted_by_due(l, true, 0).size()


## Unix time of the soonest not-yet-due item of language `l`, or 0 if none.
func next_due(l: String) -> int:
	var up: Array = _sorted_by_due(l, false, 1)
	return int((up[0] as Dictionary)["due"]) if not up.is_empty() else 0


func _sorted_by_due(l: String, want_due: bool, limit: int) -> Array:
	var t: int = now()
	var pairs: Array = []
	var review: Array = progress["review"]
	for i in review.size():
		var r: Dictionary = review[i]
		if r["lang"] == l and (int(r["due"]) <= t) == want_due:
			pairs.append([int(r["due"]), i])
	pairs.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out: Array = []
	for p in pairs:
		out.append(review[p[1]])
		if limit > 0 and out.size() >= limit:
			break
	return out


## Apply an FSRS rating (1..4) to the review item `id` right now. Returns false if not found.
func rate_review(id: String, rating: int) -> bool:
	for r in progress["review"]:
		var d: Dictionary = r
		if d["id"] == id:
			d.merge(FSRS.review(d, rating, now()), true)
			return true
	return false


# ---------------------------------------------------------------- known words (읽기)

## Set (lemma -> true) of the words of language `l` the person marked as known.
func known_set(l: String) -> Dictionary:
	var out := {}
	var kw: Dictionary = progress.get("known_words", {})
	for w in kw.get(l, []):
		out[str(w)] = true
	return out


func is_known(l: String, lemma: String) -> bool:
	var kw: Dictionary = progress.get("known_words", {})
	return (kw.get(l, []) as Array).has(lemma)


## Marks (on=true) or unmarks lemmas as known. Does not save; call save_progress().
## Returns how many entries changed.
func set_known(l: String, lemmas: Array, on: bool) -> int:
	if l != "en" and l != "ja":
		return 0
	if not progress.has("known_words") or not (progress["known_words"] is Dictionary):
		progress["known_words"] = {"en": [], "ja": []}
	var kw: Dictionary = progress["known_words"]
	var arr: Array = kw.get(l, [])
	var have := {}
	for w in arr:
		have[str(w)] = true
	var changed := 0
	if on:
		for w in lemmas:
			var t: String = str(w).strip_edges()
			if t != "" and not have.has(t):
				have[t] = true
				arr.append(t)
				changed += 1
		if arr.size() > Progress.MAX_KNOWN:
			arr = arr.slice(arr.size() - Progress.MAX_KNOWN)
	else:
		var drop := {}
		for w in lemmas:
			drop[str(w).strip_edges()] = true
		var keep: Array = []
		for w in arr:
			if drop.has(str(w)):
				changed += 1
			else:
				keep.append(w)
		arr = keep
	kw[l] = arr
	return changed
