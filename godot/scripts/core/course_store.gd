class_name CourseStore
extends RefCounted
## v2.0 English course progress (user://course.json, this device only). Design docs/v200_design.md §6.2, §10.5, §10.6, §14 E3.
##
## Static API only. Every change is written right away (the file is small): atomic write through Progress.write_text_atomic.
## The course is "on" only while Store.prefs.course_mode == "course" (mode()). In "legacy" mode (old 12-month path, Japanese,
## nothing chosen yet) no function here writes a file: the mutators return {"ignored": true} / false / 0 and keep the memory as it was.
##
## File (v1): {"v":1,"started":"2026-12-01","pos":{"w":5,"d":2},
##   "weeks":{"1":{"done":"2026-12-07","days":{"1":"2026-12-01"},"check":{"best":90,"tries":1,"last":"2026-12-07","speak":"pass"},"weak":false}},
##   "months":{"1":{"score":78,"date":"2026-12-28","tries":1,"mode":"stt"}},
##   "day":{"2026-12-01":{"new":1,"review":1,"listen":1,"speak":1,"rp":0}},
##   "last_active":"2026-12-01","skips":[3]}
## `rp` (new) = that day's plan was "review first" (DayPlan reads it back through review_state()).
## Unknown top-level keys (and unknown keys inside week / month / day records) are kept when the file is written again.
## A file with `v` greater than VERSION is read-only: it is read, but never written over (this app does not know the new fields).
## A broken file (cut JSON, empty, an array) is moved to `<path>.bad` (.bad.1, .bad.2: three at most) and the state starts empty.
## A file that exists but cannot be opened: read-only for this run (nothing is saved over it).
## Values are clamped: w 1..72, d 1..7, scores 0..100, tries 0..99; a week / month key outside its range is dropped.
## Tests: CourseStore.path = "user://test_*.json", CourseStore.reset_memory(), CourseStore.today_override = <day number>.
## Never calls StudyLog / Store writers (except Store.set_pref in set_mode): the old 12-month path records stay untouched.

const VERSION := 1
const MODE_COURSE := "course"
const MODE_LEGACY := "legacy"
const PREF_KEY := "course_mode"
const MAX_WEEK := 72
const MAX_BLOCK := 18
const DAYS := 7
const KEEP_DAYS := 120
const MAX_TRIES := 99
const CHECK_PASS := 80 ## weekly check: percent of the auto-graded questions (design §7.1)
const SKIP_PASS := 90 ## "skip by check": percent needed to mark the week done
const WEAK_AFTER_TRIES := 2 ## failed twice -> progress is allowed, the week gets the weak mark
const BLOCK_IDS := ["new", "review", "listen", "speak"]
const SPEAK_VALUES := ["pass", "fail", "unverified"]
const MONTH_MODES := ["stt", "self"]
const KNOWN_KEYS := ["v", "started", "pos", "weeks", "months", "day", "last_active", "skips"]
const WEEK_KEYS := ["done", "days", "check", "weak"]
const MONTH_KEYS := ["score", "date", "tries", "mode"]
const DAY_KEYS := ["new", "review", "listen", "speak", "rp"]
## result.unit -> block id when result.block is missing. check / month have their own functions.
const UNIT_BLOCK := {"new": "new", "free": "new", "recap": "new", "listen": "listen", "speak": "speak"}

static var path := "user://course.json"
## Tests only: pretend today is this day number (Plan.days_from_civil). -1 = StudyLog.today() (which has its own override).
static var today_override: int = -1
## "new" | "ok" | "empty" | "bad" | "unreadable" | "future" -- how the last load() went.
static var last_load_status: String = ""
## false when the last write was refused or failed (read-only file, read-only folder, test guard).
static var last_save_ok: bool = true

static var _data: Dictionary = {}
static var _loaded: bool = false
static var _read_only: bool = false ## file exists but cannot be opened, or has a newer `v`


# ---------------------------------------------------------------- mode

## "course" only when the learner pressed [start the new course] (prefs.course_mode == "course"); everything else is "legacy".
static func mode() -> String:
	var v: Variant = Store.prefs.get(PREF_KEY, "")
	return MODE_COURSE if (v is String and v == MODE_COURSE) else MODE_LEGACY


## Switches the mode (writes prefs through Store.set_pref). "course" also creates the course file (started = today) when
## it is missing. Anything but "course" / "legacy" is refused (false). "legacy" never touches the course file.
static func set_mode(m: Variant) -> bool:
	if not (m is String) or (m != MODE_COURSE and m != MODE_LEGACY):
		return false
	Store.set_pref(PREF_KEY, m)
	if m == MODE_COURSE:
		_ensure()
		if str(_data["started"]) == "":
			_data["started"] = today_iso()
		_write()
	return true


# ---------------------------------------------------------------- load / save

static func today() -> int:
	return today_override if today_override >= 0 else StudyLog.today()


static func today_iso() -> String:
	return Plan.days_to_iso(today())


## Forgets the memory copy; the next call reads the file again (tests).
static func reset_memory() -> void:
	_loaded = false
	_data = {}
	_read_only = false


## Reads the file (never writes, except that a broken file is moved to `.bad`). Always call it as `CourseStore.load()`: inside
## this class the bare name `load` is GDScript's global load(path), so the class itself uses _load_file().
static func load() -> void:
	_load_file()


static func _load_file() -> void:
	_loaded = true
	_read_only = false
	_data = _blank()
	last_load_status = "new"
	if not FileAccess.file_exists(path):
		return
	var r: Dictionary = Progress.read_json_file(path)
	var st: String = str(r["status"])
	last_load_status = st
	match st:
		"ok":
			var raw: Dictionary = r["data"]
			_data = _normalize(raw)
			if _int_in(raw.get("v", VERSION), 0, 1000000000, VERSION) > VERSION:
				_read_only = true
				last_load_status = "future"
		"empty":
			Progress.quarantine(path)
			last_load_status = "empty"
		"unreadable":
			_read_only = true


## Writes the file when the course is on. true = written.
static func save() -> bool:
	if mode() != MODE_COURSE:
		return false
	return _write()


static func is_read_only() -> bool:
	_ensure()
	return _read_only


static func _ensure() -> void:
	if not _loaded:
		_load_file()


static func _write() -> bool:
	_ensure()
	if _read_only:
		last_save_ok = false
		return false
	_prune()
	_data["v"] = VERSION
	last_save_ok = Progress.write_text_atomic(path, JSON.stringify(_data))
	return last_save_ok


## true when a mutator may change something (course on). Loads the file first.
static func _begin() -> bool:
	if mode() != MODE_COURSE:
		return false
	_ensure()
	return true


# ---------------------------------------------------------------- reading

## {"w": 1..72, "d": 1..7}: the next cell to do. CourseModel.pos_for() reads this.
static func pos() -> Dictionary:
	_ensure()
	var p: Dictionary = _data["pos"]
	return {"w": int(p["w"]), "d": int(p["d"])}


static func started() -> String:
	_ensure()
	return str(_data["started"])


## true once week 72 is done (it also happens through "skip by check" or day 7).
static func finished() -> bool:
	_ensure()
	var rec: Variant = (_data["weeks"] as Dictionary).get("72", null)
	return rec is Dictionary and str((rec as Dictionary).get("done", "")) != ""


## Calendar days since the course was started (0 when not started or the clock is before it).
static func elapsed_days() -> int:
	_ensure()
	var s: String = str(_data["started"])
	return 0 if s == "" else maxi(today() - Plan.iso_to_days(s), 0)


## Calendar days since the last day with any course activity (0 when there is none yet).
static func away_days() -> int:
	_ensure()
	var s: String = str(_data["last_active"])
	return 0 if s == "" else maxi(today() - Plan.iso_to_days(s), 0)


## {"new","review","listen","speak": bool} for today.
static func blocks_today() -> Dictionary:
	_ensure()
	var rec: Variant = (_data["day"] as Dictionary).get(today_iso(), {})
	var out: Dictionary = {}
	for id in BLOCK_IDS:
		out[id] = rec is Dictionary and int((rec as Dictionary).get(id, 0)) != 0
	return out


## State of week w: {"w","done": bool,"done_date","days": [d done...],"best","tries","last","speak","weak","passed","skipped","has_check"} or {}.
static func week_state(w: Variant) -> Dictionary:
	var wi: int = _strict(w, 1, MAX_WEEK)
	if wi < 0:
		return {}
	_ensure()
	var rec: Variant = (_data["weeks"] as Dictionary).get(str(wi), {})
	var r: Dictionary = rec if rec is Dictionary else {}
	var days: Array = []
	var dd: Variant = r.get("days", {})
	if dd is Dictionary:
		for k in (dd as Dictionary).keys():
			days.append(int(k))
	days.sort()
	var chk: Variant = r.get("check", {})
	var c: Dictionary = chk if chk is Dictionary else {}
	var best: int = int(c.get("best", 0))
	return {"w": wi, "done": str(r.get("done", "")) != "", "done_date": str(r.get("done", "")), "days": days,
		"best": best, "tries": int(c.get("tries", 0)), "last": str(c.get("last", "")), "speak": str(c.get("speak", "")),
		"weak": bool(r.get("weak", false)), "passed": best >= CHECK_PASS, "has_check": not c.is_empty(),
		"skipped": (_data["skips"] as Array).has(wi)}


## 72 flags (index w-1): week done. Feed for CourseModel.states(done, cur_w, avail).
static func path_flags() -> Array:
	_ensure()
	var out: Array = []
	var ws: Dictionary = _data["weeks"]
	for w in range(1, MAX_WEEK + 1):
		var rec: Variant = ws.get(str(w), null)
		out.append(rec is Dictionary and str((rec as Dictionary).get("done", "")) != "")
	return out


## Month-end speaking records: {"n","score","date","tries","mode"} or {}.
static func month_state(n: Variant) -> Dictionary:
	var ni: int = _strict(n, 1, MAX_BLOCK)
	if ni < 0:
		return {}
	_ensure()
	var rec: Variant = (_data["months"] as Dictionary).get(str(ni), null)
	if not (rec is Dictionary):
		return {}
	var r: Dictionary = rec
	return {"n": ni, "score": int(r.get("score", 0)), "date": str(r.get("date", "")), "tries": int(r.get("tries", 0)), "mode": str(r.get("mode", ""))}


## "Review first" memory for DayPlan: {"prev": bool, "streak": int}.
##   streak: how many days in a row, ending yesterday, the plan was "review first" (rp == 1).
##   prev: the latest earlier day that has an rp record was "review first" (the 25-card release uses it).
static func review_state() -> Dictionary:
	_ensure()
	var days: Dictionary = _data["day"]
	var t: int = today()
	var streak := 0
	var i: int = t - 1
	while streak < MAX_TRIES:
		var rec: Variant = days.get(Plan.days_to_iso(i), null)
		if rec is Dictionary and int((rec as Dictionary).get("rp", 0)) != 0:
			streak += 1
			i -= 1
		else:
			break
	var prev := false
	var best_day: int = -1
	for k in days.keys():
		var rec2: Variant = days[k]
		if not (rec2 is Dictionary) or not (rec2 as Dictionary).has("rp"):
			continue
		var dn: int = Plan.iso_to_days(str(k))
		if dn < t and dn > best_day:
			best_day = dn
			prev = int((rec2 as Dictionary)["rp"]) != 0
	return {"prev": prev, "streak": streak}


## The oldest passed-over week whose weekly check was neither passed nor marked weak ("미리 해 보기", design §6.2 U5):
## {"pending": bool, "w": int, "days": int (days since the last day done in that week)}.
static func check_pending() -> Dictionary:
	_ensure()
	var cur_w: int = int((_data["pos"] as Dictionary)["w"])
	for w in range(1, MAX_WEEK + 1):
		if w >= cur_w and not (w == cur_w and finished()):
			break
		var st: Dictionary = week_state(w)
		if st.is_empty() or (st["days"] as Array).is_empty() or bool(st["passed"]) or bool(st["weak"]) or bool(st["skipped"]):
			continue
		var last := 0
		var rec: Dictionary = (_data["weeks"] as Dictionary).get(str(w), {})
		for k in (rec.get("days", {}) as Dictionary).values():
			last = maxi(last, Plan.iso_to_days(str(k)))
		return {"pending": true, "w": w, "days": maxi(today() - last, 0)}
	return {"pending": false, "w": 0, "days": 0}


# ---------------------------------------------------------------- recording

## One unit of the day ended. result (design §10.4): {"unit","w","d","ok","total","first_try","wrong","words_new","completed","seconds", optional "block"}.
## Only `completed == true` counts. The unit marks its block (result.block, else by unit: new/free/recap -> new, listen, speak) in
## today's record. A block "new" with unit new / speak / free finishes the cell (w, d): its date is kept once (the same cell again
## changes nothing), day 7 also finishes the week, and pos moves to the cell after it unless pos is already further ("recap" never
## moves it). Units check / month go through check_done / month_done and are ignored here.
## Returns {"w","d","finished","advanced","week_done","ignored"}. Legacy mode: nothing is written ("ignored": true).
static func unit_done(result: Variant) -> Dictionary:
	var out: Dictionary = {"advanced": false, "week_done": false, "ignored": false}
	if not (result is Dictionary) or not _begin():
		_fill_pos(out)
		out["ignored"] = true
		return out
	var res: Dictionary = result
	var unit: String = str(res.get("unit", "new")) if res.get("unit", "new") is String else ""
	var block: String = str(res["block"]) if (res.get("block") is String and BLOCK_IDS.has(res["block"])) else str(UNIT_BLOCK.get(unit, ""))
	var completed: Variant = res.get("completed", false)
	if unit == "check" or unit == "month" or block == "" or not (completed is bool and completed):
		_fill_pos(out)
		out["ignored"] = true
		return out
	var changed: bool = _touch()
	changed = _set_block(block) or changed
	var cell_unit: bool = block == "new" and unit != "recap"
	var wi: int = _strict(res.get("w"), 1, MAX_WEEK)
	var di: int = _strict(res.get("d"), 1, DAYS)
	if cell_unit and wi > 0 and di > 0:
		var r: Dictionary = _complete_cell(wi, di)
		out["advanced"] = r["advanced"]
		out["week_done"] = r["week_done"]
		changed = true
	if changed:
		_write()
	_fill_pos(out)
	return out


## Weekly check result for week w: {"ok": auto-graded right, "total": auto-graded questions, "speak": "pass"|"fail"|"unverified", "skip": bool}.
## pct = ok / total (0..100). Regular check: pct >= 80 passes. First failure: the cell (w, 6) stays open (tomorrow again);
## the second failure still opens the way (cell finished) but marks the week weak. A pass clears weak.
## skip == true ("skip by check", design §7.1): pct >= 90 marks the week done and skipped (pos moves on when it is this week);
## a lower score changes nothing (it is not counted as a failed check).
## Returns {"ok": processed, "pass","pct","tries","best","weak","skip","w","d","finished","ignored"}.
static func check_done(w: Variant, result: Variant) -> Dictionary:
	var out: Dictionary = {"ok": false, "pass": false, "pct": 0, "tries": 0, "best": 0, "weak": false, "skip": false, "ignored": false}
	var wi: int = _strict(w, 1, MAX_WEEK)
	if wi < 0 or not (result is Dictionary) or not _begin():
		_fill_pos(out)
		out["ignored"] = true
		return out
	var res: Dictionary = result
	var total: int = _int_in(res.get("total", 0), 0, 999, 0)
	var right: int = _int_in(res.get("ok", 0), 0, total, 0)
	var pct: int = clampi(roundi(right * 100.0 / float(total)), 0, 100) if total > 0 else 0
	var skip_v: Variant = res.get("skip", false)
	var skip: bool = skip_v is bool and skip_v
	var rec: Dictionary = _wk(wi)
	out["ok"] = true
	out["pct"] = pct
	out["skip"] = skip
	var speak: String = str(res.get("speak", "")) if res.get("speak", "") is String else ""
	if not SPEAK_VALUES.has(speak):
		speak = ""
	if skip:
		if pct >= SKIP_PASS:
			out["pass"] = true
			if str(rec["done"]) == "":
				rec["done"] = today_iso()
			var sk: Array = _data["skips"]
			if not sk.has(wi):
				sk.append(wi)
				sk.sort()
			var c: Dictionary = _check_rec(rec)
			c["best"] = maxi(int(c["best"]), pct)
			c["last"] = today_iso()
			_touch()
			var p: Dictionary = _data["pos"]
			if int(p["w"]) == wi:
				_advance_to_week(wi + 1)
			_write()
		_fill_pos(out)
		_fill_check(out, rec)
		return out
	var chk: Dictionary = _check_rec(rec)
	chk["tries"] = mini(int(chk["tries"]) + 1, MAX_TRIES)
	chk["best"] = maxi(int(chk["best"]), pct)
	chk["last"] = today_iso()
	chk["speak"] = speak
	var passed: bool = pct >= CHECK_PASS
	out["pass"] = passed
	var weak := false
	if passed:
		rec["weak"] = false
	else:
		weak = int(chk["tries"]) >= WEAK_AFTER_TRIES and int(chk["best"]) < CHECK_PASS
		rec["weak"] = weak
	_touch()
	_set_block("new")
	if passed or weak:
		_complete_cell(wi, 6)
	_write()
	_fill_pos(out)
	_fill_check(out, rec)
	return out


## Month-end speaking evaluation of block n (1..18): result {"score": 0..100, "mode": "stt"|"self"}. Keeps the latest score / date /
## mode and counts the tries. Does not move pos. Returns {"ok","n","score","tries","ignored"}.
static func month_done(n: Variant, result: Variant) -> Dictionary:
	var ni: int = _strict(n, 1, MAX_BLOCK)
	var out: Dictionary = {"ok": false, "n": maxi(ni, 0), "score": 0, "tries": 0, "ignored": false}
	if ni < 0 or not (result is Dictionary) or not _begin():
		out["ignored"] = true
		return out
	var res: Dictionary = result
	var months: Dictionary = _data["months"]
	var rec: Dictionary = months.get(str(ni), {})
	var m: String = str(res.get("mode", "")) if res.get("mode", "") is String else ""
	rec["score"] = _int_in(res.get("score", 0), 0, 100, 0)
	rec["date"] = today_iso()
	rec["tries"] = mini(int(rec.get("tries", 0)) + 1, MAX_TRIES)
	rec["mode"] = m if MONTH_MODES.has(m) else "self"
	months[str(ni)] = rec
	_touch()
	_write()
	out["ok"] = true
	out["score"] = int(rec["score"])
	out["tries"] = int(rec["tries"])
	return out


## Marks one of the four daily blocks (new / review / listen / speak) done today. true = it was not marked before.
## Legacy mode or an unknown id: false and nothing is written.
static func mark_block(id: Variant) -> bool:
	if not (id is String) or not BLOCK_IDS.has(id) or not _begin():
		return false
	var changed: bool = _set_block(id)
	changed = _touch() or changed
	if changed:
		_write()
	return changed


## Remembers whether today's plan was "review first" (DayPlan.today(...).review_priority). false when nothing is written.
static func note_review_priority(on: Variant) -> bool:
	if not (on is bool) or not _begin():
		return false
	var rec: Dictionary = _day_rec()
	var v: int = 1 if on else 0
	if int(rec.get("rp", -1)) == v:
		return true
	rec["rp"] = v
	_write()
	return true


## After a long break (design §6.2 U4): takes the "done" mark and the finished days off the given weeks (cards, check records and
## the study log stay) and moves pos back to the first of them when pos is later. Returns how many weeks were reopened.
static func reopen_weeks(ws: Variant) -> int:
	if not (ws is Array) or not _begin():
		return 0
	var n := 0
	var first: int = MAX_WEEK + 1
	var weeks: Dictionary = _data["weeks"]
	for v in ws:
		var wi: int = _strict(v, 1, MAX_WEEK)
		if wi < 0 or not weeks.has(str(wi)):
			continue
		var rec: Dictionary = weeks[str(wi)]
		if str(rec.get("done", "")) == "" and (rec.get("days", {}) as Dictionary).is_empty():
			continue
		rec["done"] = ""
		rec["days"] = {}
		(_data["skips"] as Array).erase(wi)
		n += 1
		first = mini(first, wi)
	if n > 0:
		var p: Dictionary = _data["pos"]
		if first < int(p["w"]):
			p["w"] = first
			p["d"] = 1
		_write()
	return n


# ---------------------------------------------------------------- internals (state changes)

## Sets last_active = today (and started when empty). true = something changed.
static func _touch() -> bool:
	var changed := false
	var t: String = today_iso()
	if str(_data["last_active"]) != t:
		_data["last_active"] = t
		changed = true
	if str(_data["started"]) == "":
		_data["started"] = t
		changed = true
	return changed


static func _day_rec() -> Dictionary:
	var days: Dictionary = _data["day"]
	var t: String = today_iso()
	if not (days.get(t, null) is Dictionary):
		days[t] = {}
	return days[t]


static func _set_block(id: String) -> bool:
	var rec: Dictionary = _day_rec()
	if int(rec.get(id, 0)) != 0:
		return false
	rec[id] = 1
	return true


static func _wk(w: int) -> Dictionary:
	var weeks: Dictionary = _data["weeks"]
	var k: String = str(w)
	if not (weeks.get(k, null) is Dictionary):
		weeks[k] = {"done": "", "days": {}, "weak": false}
	var rec: Dictionary = weeks[k]
	if not (rec.get("days", null) is Dictionary):
		rec["days"] = {}
	return rec


static func _check_rec(rec: Dictionary) -> Dictionary:
	if not (rec.get("check", null) is Dictionary):
		rec["check"] = {"best": 0, "tries": 0, "last": "", "speak": ""}
	return rec["check"]


## Finishes cell (w, d). Returns {"advanced","week_done"}.
static func _complete_cell(w: int, d: int) -> Dictionary:
	var out: Dictionary = {"advanced": false, "week_done": false}
	var rec: Dictionary = _wk(w)
	var days: Dictionary = rec["days"]
	if not days.has(str(d)):
		days[str(d)] = today_iso()
	if d == DAYS and str(rec.get("done", "")) == "":
		rec["done"] = today_iso()
		out["week_done"] = true
	# pos: the cell after (w, d), unless pos is already further
	var nw: int = w
	var nd: int = d + 1
	if nd > DAYS:
		nw = w + 1
		nd = 1
	var p: Dictionary = _data["pos"]
	if nw > MAX_WEEK: ## week 72 day 7: the course is finished, pos stays on the last cell
		if int(p["w"]) != MAX_WEEK or int(p["d"]) != DAYS:
			p["w"] = MAX_WEEK
			p["d"] = DAYS
			out["advanced"] = true
		return out
	if nw * 10 + nd > int(p["w"]) * 10 + int(p["d"]):
		p["w"] = nw
		p["d"] = nd
		out["advanced"] = true
		_skip_placed_weeks()
	return out


## pos moves on past weeks the learner placed out of ("skip by check"). When only skipped weeks are left, pos is the last cell.
static func _skip_placed_weeks() -> void:
	var p: Dictionary = _data["pos"]
	var sk: Array = _data["skips"]
	while int(p["d"]) == 1 and sk.has(int(p["w"])):
		if int(p["w"]) >= MAX_WEEK:
			p["w"] = MAX_WEEK
			p["d"] = DAYS
			return
		p["w"] = int(p["w"]) + 1


static func _advance_to_week(w: int) -> void:
	var p: Dictionary = _data["pos"]
	if w > MAX_WEEK:
		p["w"] = MAX_WEEK
		p["d"] = DAYS
		return
	p["w"] = w
	p["d"] = 1
	_skip_placed_weeks()


static func _fill_pos(out: Dictionary) -> void:
	var p: Dictionary = pos()
	out["w"] = p["w"]
	out["d"] = p["d"]
	out["finished"] = finished()


static func _fill_check(out: Dictionary, rec: Dictionary) -> void:
	var c: Dictionary = rec.get("check", {}) if rec.get("check", null) is Dictionary else {}
	out["tries"] = int(c.get("tries", 0))
	out["best"] = int(c.get("best", 0))
	out["weak"] = bool(rec.get("weak", false))


# ---------------------------------------------------------------- normalizing (reading a file)

static func _blank() -> Dictionary:
	return {"v": VERSION, "started": "", "pos": {"w": 1, "d": 1}, "weeks": {}, "months": {}, "day": {}, "last_active": "", "skips": []}


## The whole file as a clean state: every known field clamped, unknown keys carried over unchanged.
static func _normalize(raw: Variant) -> Dictionary:
	var out: Dictionary = _blank()
	if not (raw is Dictionary):
		return out
	var src: Dictionary = raw
	for k in src.keys():
		if not KNOWN_KEYS.has(k):
			out[k] = _deep(src[k])
	out["v"] = _int_in(src.get("v", VERSION), 0, 1000000000, VERSION)
	out["started"] = _iso(src.get("started", ""))
	out["last_active"] = _iso(src.get("last_active", ""))
	var p: Variant = src.get("pos", {})
	if p is Dictionary:
		out["pos"] = {"w": _int_in((p as Dictionary).get("w", 1), 1, MAX_WEEK, 1), "d": _int_in((p as Dictionary).get("d", 1), 1, DAYS, 1)}
	var weeks: Dictionary = {}
	if src.get("weeks", null) is Dictionary:
		for k in (src["weeks"] as Dictionary).keys():
			var wi: int = _strict(k, 1, MAX_WEEK)
			if wi > 0 and (src["weeks"][k] is Dictionary):
				weeks[str(wi)] = _norm_week(src["weeks"][k])
	out["weeks"] = weeks
	var months: Dictionary = {}
	if src.get("months", null) is Dictionary:
		for k in (src["months"] as Dictionary).keys():
			var ni: int = _strict(k, 1, MAX_BLOCK)
			if ni > 0 and (src["months"][k] is Dictionary):
				months[str(ni)] = _norm_month(src["months"][k])
	out["months"] = months
	var days: Dictionary = {}
	if src.get("day", null) is Dictionary:
		for k in (src["day"] as Dictionary).keys():
			var iso: String = _iso(k)
			if iso != "" and (src["day"][k] is Dictionary):
				days[iso] = _norm_day(src["day"][k])
	out["day"] = days
	var sk: Array = []
	if src.get("skips", null) is Array:
		for v in src["skips"]:
			var s: int = _strict(v, 1, MAX_WEEK)
			if s > 0 and not sk.has(s):
				sk.append(s)
	sk.sort()
	out["skips"] = sk
	return out


static func _norm_week(r: Dictionary) -> Dictionary:
	var out: Dictionary = _carry(r, WEEK_KEYS)
	out["done"] = _iso(r.get("done", ""))
	var days: Dictionary = {}
	if r.get("days", null) is Dictionary:
		for k in (r["days"] as Dictionary).keys():
			var di: int = _strict(k, 1, DAYS)
			var iso: String = _iso(r["days"][k])
			if di > 0 and iso != "":
				days[str(di)] = iso
	out["days"] = days
	if r.get("check", null) is Dictionary:
		var c: Dictionary = r["check"]
		var sp: String = str(c.get("speak", "")) if c.get("speak", "") is String else ""
		out["check"] = {"best": _int_in(c.get("best", 0), 0, 100, 0), "tries": _int_in(c.get("tries", 0), 0, MAX_TRIES, 0),
			"last": _iso(c.get("last", "")), "speak": sp if SPEAK_VALUES.has(sp) else ""}
	var weak: Variant = r.get("weak", false)
	out["weak"] = weak is bool and weak
	return out


static func _norm_month(r: Dictionary) -> Dictionary:
	var out: Dictionary = _carry(r, MONTH_KEYS)
	var m: String = str(r.get("mode", "")) if r.get("mode", "") is String else ""
	out["score"] = _int_in(r.get("score", 0), 0, 100, 0)
	out["date"] = _iso(r.get("date", ""))
	out["tries"] = _int_in(r.get("tries", 0), 0, MAX_TRIES, 0)
	out["mode"] = m if MONTH_MODES.has(m) else "self"
	return out


static func _norm_day(r: Dictionary) -> Dictionary:
	var out: Dictionary = _carry(r, DAY_KEYS)
	for k in DAY_KEYS:
		if r.has(k):
			out[k] = 1 if _int_in(r[k], 0, 1, 0) != 0 else 0
	return out


## Copy of the keys of `r` that are not in `known` (deep copies).
static func _carry(r: Dictionary, known: Array) -> Dictionary:
	var out: Dictionary = {}
	for k in r.keys():
		if not known.has(k):
			out[k] = _deep(r[k])
	return out


## Keeps the newest KEEP_DAYS day records.
static func _prune() -> void:
	var days: Dictionary = _data["day"]
	if days.size() <= KEEP_DAYS:
		return
	var keys: Array = days.keys()
	keys.sort()
	for i in range(0, keys.size() - KEEP_DAYS):
		days.erase(keys[i])


# ---------------------------------------------------------------- helpers

static func _deep(v: Variant) -> Variant:
	if v is Dictionary or v is Array:
		return v.duplicate(true)
	return v


static func _iso(v: Variant) -> String:
	return str(v) if (v is String and Plan.is_valid_iso(v)) else ""


## Integer of an int / finite float / integer string clamped to lo..hi; def for anything else.
static func _int_in(v: Variant, lo: int, hi: int, def: int) -> int:
	var i: int
	if v is int:
		i = v
	elif v is float:
		var f: float = v
		if is_nan(f) or is_inf(f):
			return def
		i = int(clampf(f, -1.0e9, 1.0e9))
	elif v is String and (v as String).is_valid_int():
		i = clampi((v as String).to_int(), -1000000000, 1000000000)
	else:
		return def
	return clampi(i, lo, hi)


## v as an integer in lo..hi, else -1 (no clamping: a week 99 is not week 72).
static func _strict(v: Variant, lo: int, hi: int) -> int:
	var i: int
	if v is int:
		i = v
	elif v is float:
		var f: float = v
		if is_nan(f) or is_inf(f) or absf(f) > 1.0e9 or f != floorf(f):
			return -1
		i = int(f)
	elif v is String and (v as String).is_valid_int():
		i = (v as String).to_int()
	else:
		return -1
	return i if (i >= lo and i <= hi) else -1
