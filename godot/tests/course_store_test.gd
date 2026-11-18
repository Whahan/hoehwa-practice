extends Node
## CourseStore: v2.0 course progress file (docs/v200_design.md §6.2, §10.6, §14 E3-2, E3-3, E3-8, E3-10).
##   PC   : godot --headless --path <project>/godot res://tests/course_store_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_store_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== course_store_test: N passed, M failed ==".
## Only user://test_e3_* files are used: CourseStore.path, Store.prefs_path, Store.progress_path and StudyLog.path are pointed
## there and restored at the end (the real course.json / prefs / progress / studylog are never written; the user:// listing is
## compared before / after). The shape checker is also fed deliberately broken files (lines "selfcheck FAIL-as-expected ...").

const P := "user://test_e3_course.json"
const PREFS := "user://test_e3_prefs.json"
const PROG := "user://test_e3_progress.json"
const LOG := "user://test_e3_studylog.json"
const BASE_Y := 2026
const BASE_M := 12
const BASE_D := 1

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved_paths: Dictionary = {}
var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var base_day: int = 0


func _ready() -> void:
	print("== course_store_test start ==")
	base_day = Plan.days_from_civil(BASE_Y, BASE_M, BASE_D)
	_before = _user_listing()
	_saved_paths = {"cs": CourseStore.path, "prefs": Store.prefs_path, "prog": Store.progress_path, "log": StudyLog.path,
		"today": CourseStore.today_override}
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	CourseStore.path = P
	Store.prefs_path = PREFS
	Store.progress_path = PROG
	StudyLog.path = LOG
	_selfcheck()
	_legacy_writes_nothing()
	_set_mode()
	_unit_done_table()
	_unit_done_bad_input()
	_check_done_table()
	_check_done_skip()
	_month_done()
	_blocks_and_clock()
	_review_state()
	_reopen()
	_check_pending()
	_file_shape_and_roundtrip()
	_unknown_keys_and_future()
	_broken_files()
	_unreadable_and_write_failure()
	_value_clamps()
	_pruning()
	_real_name_guard()
	_full_walk()
	_model_integration()
	_source_scan()
	_restore()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	ok(not FileAccess.file_exists("user://course.json"), "no user://course.json was created")
	print("== course_store_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


# ---------------------------------------------------------------- helpers

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _rm_all() -> void:
	for base in [P, PREFS, PROG, LOG]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2", ".bad.3"]:
			var f: String = base + suffix
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


func _restore() -> void:
	_rm_all()
	Progress.write_hook = Callable()
	Progress.open_hook = Callable()
	CourseStore.path = _saved_paths["cs"]
	Store.prefs_path = _saved_paths["prefs"]
	Store.progress_path = _saved_paths["prog"]
	StudyLog.path = _saved_paths["log"]
	CourseStore.today_override = _saved_paths["today"]
	Store.prefs = _saved_prefs
	Store.progress = _saved_progress
	CourseStore.reset_memory()


## Clean slate: no files, memory forgotten, today = base day, mode as given.
func _fresh(m: String = "course") -> void:
	_rm_all()
	Progress.write_hook = Callable()
	Progress.open_hook = Callable()
	CourseStore.reset_memory()
	CourseStore.today_override = base_day
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	if m != "":
		Store.prefs["course_mode"] = m


func _day(n: int) -> void:
	CourseStore.today_override = base_day + n


func _iso(n: int) -> String:
	return Plan.days_to_iso(base_day + n)


func _read_text(p: String) -> String:
	return FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else ""


func _read_json(p: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read_text(p))
	return parsed if parsed is Dictionary else {}


func _write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _cell(w: int, d: int, unit: String = "new", extra: Dictionary = {}) -> Dictionary:
	var r: Dictionary = {"unit": unit, "w": w, "d": d, "ok": 10, "total": 12, "first_try": 9, "wrong": [], "words_new": [], "completed": true, "seconds": 600}
	r.merge(extra, true)
	return r


func _is_int_in(v: Variant, lo: int, hi: int) -> bool:
	return (v is int or v is float) and float(v) == floorf(float(v)) and int(v) >= lo and int(v) <= hi


func _is_iso(v: Variant) -> bool:
	return v is String and Plan.is_valid_iso(v)


## The checker for a file written by CourseStore (design §10.6): returns [] when clean, else the list of problems.
func _shape_problems(d: Variant) -> Array:
	var bad: Array = []
	if not (d is Dictionary):
		return ["not a dictionary"]
	if not _is_int_in(d.get("v"), 1, 1):
		bad.append("v")
	if not (d.get("started") is String) or (d["started"] != "" and not _is_iso(d["started"])):
		bad.append("started")
	if not (d.get("last_active") is String) or (d["last_active"] != "" and not _is_iso(d["last_active"])):
		bad.append("last_active")
	var pos: Variant = d.get("pos")
	if not (pos is Dictionary) or not _is_int_in(pos.get("w"), 1, 72) or not _is_int_in(pos.get("d"), 1, 7):
		bad.append("pos")
	if d.get("weeks") is Dictionary:
		for k in d["weeks"].keys():
			if not _is_int_in(float(k) if String(k).is_valid_int() else -1, 1, 72):
				bad.append("week key " + str(k))
			var r: Variant = d["weeks"][k]
			if not (r is Dictionary):
				bad.append("week rec " + str(k))
				continue
			if not (r.get("done") is String) or (r["done"] != "" and not _is_iso(r["done"])):
				bad.append("week done " + str(k))
			if not (r.get("days") is Dictionary):
				bad.append("week days " + str(k))
			else:
				for dk in r["days"].keys():
					if not _is_int_in(float(dk) if String(dk).is_valid_int() else -1, 1, 7) or not _is_iso(r["days"][dk]):
						bad.append("week day " + str(k) + "/" + str(dk))
			if r.has("check"):
				var c: Variant = r["check"]
				if not (c is Dictionary) or not _is_int_in(c.get("best"), 0, 100) or not _is_int_in(c.get("tries"), 0, 99):
					bad.append("check " + str(k))
				elif not ["", "pass", "fail", "unverified"].has(c.get("speak")):
					bad.append("check speak " + str(k))
			if not (r.get("weak") is bool):
				bad.append("weak " + str(k))
	else:
		bad.append("weeks")
	if d.get("months") is Dictionary:
		for k in d["months"].keys():
			var m: Variant = d["months"][k]
			if not _is_int_in(float(k) if String(k).is_valid_int() else -1, 1, 18) or not (m is Dictionary):
				bad.append("month key " + str(k))
			elif not _is_int_in(m.get("score"), 0, 100) or not _is_int_in(m.get("tries"), 0, 99) or not _is_iso(m.get("date")) or not ["stt", "self"].has(m.get("mode")):
				bad.append("month rec " + str(k))
	else:
		bad.append("months")
	if d.get("day") is Dictionary:
		for k in d["day"].keys():
			if not _is_iso(k) or not (d["day"][k] is Dictionary):
				bad.append("day " + str(k))
				continue
			for bk in d["day"][k].keys():
				if ["new", "review", "listen", "speak", "rp"].has(bk) and not _is_int_in(d["day"][k][bk], 0, 1):
					bad.append("day flag " + str(k) + "/" + str(bk))
	else:
		bad.append("day")
	if d.get("skips") is Array:
		var last := 0
		for s in d["skips"]:
			if not _is_int_in(s, 1, 72) or int(s) <= last:
				bad.append("skips")
			last = int(s)
	else:
		bad.append("skips")
	return bad


# ---------------------------------------------------------------- checks

func _selfcheck() -> void:
	var good: Dictionary = {"v": 1, "started": "2026-12-01", "pos": {"w": 5, "d": 2}, "weeks": {"1": {"done": "2026-12-07", "days": {"1": "2026-12-01"},
		"check": {"best": 90, "tries": 1, "last": "2026-12-07", "speak": "pass"}, "weak": false}},
		"months": {"1": {"score": 78, "date": "2026-12-28", "tries": 1, "mode": "stt"}}, "day": {"2026-12-01": {"new": 1}}, "last_active": "2026-12-01", "skips": [3]}
	ok(_shape_problems(good).is_empty(), "the design example (§10.6) passes the shape checker")
	var variants: Dictionary = {
		"pos w 99": {"pos": {"w": 99, "d": 1}},
		"pos d 0": {"pos": {"w": 1, "d": 0}},
		"week key 99": {"weeks": {"99": {"done": "", "days": {}, "weak": false}}},
		"score 150": {"months": {"1": {"score": 150, "date": "2026-12-28", "tries": 1, "mode": "stt"}}},
		"bad date": {"started": "2026-13-45"},
		"skips unsorted": {"skips": [5, 3]},
		"v 2": {"v": 2},
	}
	for name in variants.keys():
		var broken: Dictionary = good.duplicate(true)
		broken.merge(variants[name], true)
		var probs: Array = _shape_problems(broken)
		print("selfcheck %s shape checker flags '%s' (%s)" % ["FAIL-as-expected" if not probs.is_empty() else "UNEXPECTED-PASS", name, str(probs)])
		ok(not probs.is_empty(), "selfcheck: the shape checker flags " + name)
	_fresh()
	var wrong: bool = CourseStore.pos() == {"w": 2, "d": 1}
	print("selfcheck %s a fresh course is not at week 2" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "selfcheck: a fresh course is at week 1 day 1, not week 2")


func _legacy_writes_nothing() -> void:
	_fresh("legacy")
	eq(CourseStore.mode(), "legacy", "legacy: mode() == legacy")
	var r: Dictionary = CourseStore.unit_done(_cell(1, 1))
	ok(bool(r["ignored"]) and not bool(r["advanced"]), "legacy: unit_done is ignored")
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "legacy: pos() unchanged")
	ok(bool(CourseStore.check_done(1, {"ok": 10, "total": 10})["ignored"]), "legacy: check_done is ignored")
	ok(bool(CourseStore.month_done(1, {"score": 80})["ignored"]), "legacy: month_done is ignored")
	ok(not CourseStore.mark_block("new"), "legacy: mark_block is false")
	ok(not CourseStore.note_review_priority(true), "legacy: note_review_priority is false")
	eq(CourseStore.reopen_weeks([1, 2]), 0, "legacy: reopen_weeks is 0")
	ok(not CourseStore.save(), "legacy: save() writes nothing")
	ok(not FileAccess.file_exists(P), "legacy: no course file was created")
	ok(not FileAccess.file_exists(P + ".tmp"), "legacy: no temp file either")
	_fresh("")
	eq(CourseStore.mode(), "legacy", "no course_mode pref at all: legacy")
	Store.prefs["lang"] = "ja"
	eq(CourseStore.mode(), "legacy", "Japanese without course_mode: legacy")
	ok(bool(CourseStore.unit_done(_cell(1, 1))["ignored"]) and not CourseStore.mark_block("listen"), "Japanese: nothing is recorded")
	ok(not FileAccess.file_exists(P), "Japanese: no course file was created")
	Store.prefs["course_mode"] = "something else"
	eq(CourseStore.mode(), "legacy", "an unknown course_mode value counts as legacy")
	Store.prefs["course_mode"] = 5
	eq(CourseStore.mode(), "legacy", "a non-text course_mode counts as legacy")
	ok(not CourseStore.save() and not FileAccess.file_exists(P), "still no file after save() in a wrong mode")


func _set_mode() -> void:
	_fresh("")
	ok(not CourseStore.set_mode("bogus"), "set_mode('bogus') is refused")
	ok(not CourseStore.set_mode(null), "set_mode(null) is refused")
	ok(not CourseStore.set_mode(5), "set_mode(5) is refused")
	ok(not FileAccess.file_exists(P) and not FileAccess.file_exists(PREFS), "refused set_mode writes no file")
	ok(CourseStore.set_mode("course"), "set_mode('course') works")
	eq(CourseStore.mode(), "course", "mode() == course afterwards")
	ok(FileAccess.file_exists(P), "set_mode('course') creates the course file")
	var d: Dictionary = _read_json(P)
	eq(d.get("started"), _iso(0), "started == today")
	eq(d.get("pos"), {"w": 1.0, "d": 1.0}, "pos starts at week 1 day 1")
	ok(_shape_problems(d).is_empty(), "the new file has the §10.6 shape")
	eq(_read_json(PREFS).get("course_mode"), "course", "prefs file records course_mode")
	ok(not FileAccess.file_exists(P + ".tmp"), "no temp file is left behind")
	ok(CourseStore.set_mode("legacy"), "set_mode('legacy') works")
	eq(CourseStore.mode(), "legacy", "mode() == legacy again")
	ok(FileAccess.file_exists(P), "going back to legacy keeps the course file")
	CourseStore.set_mode("course")
	CourseStore.unit_done(_cell(1, 1))
	CourseStore.set_mode("course")
	eq(CourseStore.pos(), {"w": 1, "d": 2}, "set_mode('course') again keeps the progress")
	eq(_read_json(P).get("started"), _iso(0), "started is not rewritten")


func _unit_done_table() -> void:
	_fresh()
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "fresh course: pos 1/1")
	var r: Dictionary = CourseStore.unit_done(_cell(1, 1))
	eq([r["w"], r["d"], r["advanced"], r["finished"], r["ignored"]], [1, 2, true, false, false], "unit_done(1/1) -> next cell 1/2")
	ok(FileAccess.file_exists(P), "the first unit_done created the file (course mode)")
	var d: Dictionary = _read_json(P)
	eq(d["weeks"]["1"]["days"]["1"], _iso(0), "cell 1/1 has today's date")
	eq(d["pos"], {"w": 1.0, "d": 2.0}, "file pos 1/2")
	eq(d["started"], _iso(0), "started was set by the first record")
	eq(d["last_active"], _iso(0), "last_active == today")
	ok(CourseStore.blocks_today()["new"], "block new is marked today")
	ok(not CourseStore.blocks_today()["review"], "block review is not")
	# the same cell again (another day): no duplicate, no move, date stays
	_day(1)
	var r2: Dictionary = CourseStore.unit_done(_cell(1, 1))
	eq([r2["w"], r2["d"], r2["advanced"]], [1, 2, false], "the same cell again: pos stays 1/2, advanced false")
	eq(_read_json(P)["weeks"]["1"]["days"]["1"], _iso(0), "the same cell again keeps the first date")
	eq(CourseStore.week_state(1)["days"], [1], "week 1 has one finished day")
	# step through to the end of week 1
	for d2 in range(2, 7):
		CourseStore.unit_done(_cell(1, d2))
	eq(CourseStore.pos(), {"w": 1, "d": 7}, "after day 6 pos is 1/7")
	ok(not CourseStore.week_state(1)["done"], "week 1 is not done before day 7")
	var r3: Dictionary = CourseStore.unit_done(_cell(1, 7))
	eq([r3["w"], r3["d"], r3["week_done"], r3["advanced"]], [2, 1, true, true], "day 7 -> week 2 day 1, week_done")
	ok(CourseStore.week_state(1)["done"], "week 1 is done")
	eq(CourseStore.path_flags()[0], true, "path_flags()[0] is true")
	eq(CourseStore.path_flags().size(), 72, "path_flags() has 72 entries")
	eq(CourseStore.path_flags()[1], false, "path_flags()[1] is false")
	# out of order: an earlier cell after pos moved on
	var r4: Dictionary = CourseStore.unit_done(_cell(1, 3))
	eq([r4["w"], r4["d"], r4["advanced"]], [2, 1, false], "an earlier cell again never moves pos back")
	# a cell ahead of pos moves pos to the cell after it
	var r5: Dictionary = CourseStore.unit_done(_cell(3, 2))
	eq([r5["w"], r5["d"], r5["advanced"]], [3, 3, true], "a cell ahead of pos: pos = the cell after it")
	var r6: Dictionary = CourseStore.unit_done(_cell(2, 5))
	eq([r6["w"], r6["d"]], [3, 3], "finishing a cell before pos (2/5) leaves pos at 3/3")
	# speak day: a unit of kind speak that is the "new" block finishes the cell
	var r7: Dictionary = CourseStore.unit_done(_cell(3, 3, "speak", {"block": "new"}))
	eq([r7["w"], r7["d"]], [3, 4], "a speak unit that is the new block finishes its cell")
	# listen / speak blocks only mark their block
	var r8: Dictionary = CourseStore.unit_done(_cell(3, 4, "listen"))
	eq([r8["w"], r8["d"], r8["advanced"]], [3, 4, false], "a listen unit does not finish a cell")
	ok(CourseStore.blocks_today()["listen"], "a listen unit marks the listen block")
	CourseStore.unit_done(_cell(3, 4, "speak"))
	ok(CourseStore.blocks_today()["speak"], "a speak unit (block speak) marks the speak block")
	eq(CourseStore.pos(), {"w": 3, "d": 4}, "speak block alone does not move pos")
	# recap marks block new, last_active, but no cell
	_day(40)
	var r9: Dictionary = CourseStore.unit_done(_cell(3, 4, "recap"))
	eq([r9["w"], r9["d"], r9["advanced"]], [3, 4, false], "a recap unit does not finish a cell")
	ok(CourseStore.blocks_today()["new"], "a recap unit marks the new block")
	eq(CourseStore.away_days(), 0, "a recap unit counts as activity (away_days 0)")
	ok(not CourseStore.week_state(3)["days"].has(4), "recap did not mark day 4 of week 3")
	# the end of the course
	_fresh()
	for w in range(1, 73):
		for d3 in range(1, 8):
			if w == 72 and d3 == 7:
				break
			CourseStore.unit_done(_cell(w, d3))
	eq(CourseStore.pos(), {"w": 72, "d": 7}, "walking all cells: pos 72/7 before the last one")
	ok(not CourseStore.finished(), "not finished before the last cell")
	var last: Dictionary = CourseStore.unit_done(_cell(72, 7))
	eq([last["w"], last["d"], last["finished"], last["week_done"]], [72, 7, true, true], "72/7 done -> finished")
	ok(CourseStore.finished(), "finished() is true")
	var again: Dictionary = CourseStore.unit_done(_cell(72, 7))
	eq([again["w"], again["d"], again["finished"], again["advanced"]], [72, 7, true, false], "finished: asking again changes nothing")
	eq(CourseStore.path_flags().count(true), 72, "all 72 weeks are done")
	ok(_shape_problems(_read_json(P)).is_empty(), "the finished file still has the §10.6 shape")
	# the last cell finished first (out of order) also moves pos to the end
	_fresh()
	var jump: Dictionary = CourseStore.unit_done(_cell(72, 7))
	eq([jump["w"], jump["d"], jump["finished"]], [72, 7, true], "72/7 finished first: pos 72/7, finished")


func _unit_done_bad_input() -> void:
	_fresh()
	for bad in [null, [], "x", 5, 1.5, true]:
		var r: Dictionary = CourseStore.unit_done(bad)
		ok(bool(r["ignored"]) and r["w"] == 1 and r["d"] == 1, "unit_done(%s) is ignored" % str(bad))
	ok(not FileAccess.file_exists(P), "ignored input wrote nothing")
	var not_done: Dictionary = CourseStore.unit_done(_cell(1, 1, "new", {"completed": false}))
	ok(bool(not_done["ignored"]), "completed == false is ignored")
	var missing: Dictionary = _cell(1, 1)
	missing.erase("completed")
	ok(bool(CourseStore.unit_done(missing)["ignored"]), "a result without `completed` is ignored")
	ok(bool(CourseStore.unit_done(_cell(1, 1, "new", {"completed": "yes"}))["ignored"]), "completed as text is ignored")
	ok(bool(CourseStore.unit_done(_cell(1, 1, "check"))["ignored"]), "unit check goes through check_done: ignored here")
	ok(bool(CourseStore.unit_done(_cell(1, 1, "month"))["ignored"]), "unit month goes through month_done: ignored here")
	ok(bool(CourseStore.unit_done(_cell(1, 1, "nonsense"))["ignored"]), "an unknown unit is ignored")
	ok(bool(CourseStore.unit_done(_cell(1, 1, "new", {"block": "check"}))["advanced"]), "an unknown block name falls back to the unit's block (cell finished)")
	eq(CourseStore.pos(), {"w": 1, "d": 2}, "pos 1/2 after the last valid call")
	for wd in [[0, 1], [73, 1], [1, 0], [1, 8], ["x", 1], [null, 2], [-3, 5], [1.5, 1], [NAN, 1]]:
		var before: Dictionary = CourseStore.pos()
		var r2: Dictionary = CourseStore.unit_done(_cell(1, 1, "new", {"w": wd[0], "d": wd[1]}))
		ok(not bool(r2["advanced"]) and CourseStore.pos() == before, "invalid cell %s/%s: no cell finished, pos unchanged" % [str(wd[0]), str(wd[1])])
	var r3: Dictionary = CourseStore.unit_done(_cell(1, 2, "new", {"w": 1.0, "d": "2"}))
	ok(bool(r3["advanced"]), "whole float w and integer text d are accepted")
	eq(CourseStore.pos(), {"w": 1, "d": 3}, "pos 1/3 after cell 1/2 given as 1.0 / '2'")
	ok(_shape_problems(_read_json(P)).is_empty(), "the file is still clean after bad input")


func _check_done_table() -> void:
	_fresh()
	for d in range(1, 6):
		CourseStore.unit_done(_cell(1, d))
	eq(CourseStore.pos(), {"w": 1, "d": 6}, "check test: pos is 1/6 (the check day)")
	# first failure
	var f1: Dictionary = CourseStore.check_done(1, {"ok": 7, "total": 10, "speak": "unverified"})
	eq([f1["ok"], f1["pass"], f1["pct"], f1["tries"], f1["best"], f1["weak"]], [true, false, 70, 1, 70, false], "check 7/10: not passed, tries 1, best 70, not weak")
	eq([f1["w"], f1["d"]], [1, 6], "the first failure keeps pos on the check day")
	ok(CourseStore.blocks_today()["new"], "a finished (failed) check still marks the new block today")
	ok(not CourseStore.week_state(1)["days"].has(6), "the check cell is not finished after one failure")
	eq(CourseStore.week_state(1)["speak"], "unverified", "speak result 'unverified' is stored")
	# second failure -> weak, the way opens
	_day(1)
	var f2: Dictionary = CourseStore.check_done(1, {"ok": 6, "total": 10, "speak": "fail"})
	eq([f2["pass"], f2["pct"], f2["tries"], f2["best"], f2["weak"]], [false, 60, 2, 70, true], "second failure: weak, best stays 70, tries 2")
	eq([f2["w"], f2["d"]], [1, 7], "the second failure opens the way (pos 1/7)")
	ok(CourseStore.week_state(1)["days"].has(6), "the check cell is finished after the second failure")
	ok(CourseStore.week_state(1)["weak"], "week_state weak == true")
	# a later pass clears the weak mark
	_day(2)
	var p1: Dictionary = CourseStore.check_done(1, {"ok": 9, "total": 10, "speak": "pass"})
	eq([p1["pass"], p1["pct"], p1["tries"], p1["best"], p1["weak"]], [true, 90, 3, 90, false], "a later pass: best 90, weak cleared")
	ok(CourseStore.week_state(1)["passed"] and not CourseStore.week_state(1)["weak"], "week_state passed, not weak")
	eq([p1["w"], p1["d"]], [1, 7], "pos stays 1/7 (already there)")
	# a pass at once
	for d in range(1, 6):
		CourseStore.unit_done(_cell(2, d))
	var p2: Dictionary = CourseStore.check_done(2, {"ok": 10, "total": 10, "speak": "pass"})
	eq([p2["pass"], p2["pct"], p2["tries"], p2["weak"], p2["w"], p2["d"]], [true, 100, 1, false, 2, 7], "week 2 passes at once: pos 2/7")
	# boundaries: 80 passes, 79 does not
	_fresh()
	var b80: Dictionary = CourseStore.check_done(1, {"ok": 8, "total": 10})
	eq([b80["pass"], b80["pct"]], [true, 80], "boundary: 8/10 = 80 passes")
	_fresh()
	var b79: Dictionary = CourseStore.check_done(1, {"ok": 79, "total": 100})
	eq([b79["pass"], b79["pct"]], [false, 79], "boundary: 79/100 = 79 does not pass")
	var zero: Dictionary = CourseStore.check_done(1, {"ok": 0, "total": 0})
	eq([zero["ok"], zero["pass"], zero["pct"]], [true, false, 0], "0 of 0 questions: pct 0, not passed, no crash")
	var over: Dictionary = CourseStore.check_done(1, {"ok": 15, "total": 10})
	eq(over["pct"], 100, "ok above total is clamped to 100 percent")
	var neg: Dictionary = CourseStore.check_done(1, {"ok": -4, "total": 10})
	eq(neg["pct"], 0, "a negative ok is clamped to 0")
	var junk: Dictionary = CourseStore.check_done(1, {"ok": "x", "total": null, "speak": 5})
	eq([junk["ok"], junk["pct"]], [true, 0], "junk numbers: pct 0, no crash")
	eq(CourseStore.week_state(1)["speak"], "", "an unknown speak value is stored as empty")
	# bad week / result
	for bw in [0, 73, "x", null, -1, 2.5]:
		ok(bool(CourseStore.check_done(bw, {"ok": 10, "total": 10})["ignored"]), "check_done(week %s) is ignored" % str(bw))
	for br in [null, [], "x", 5]:
		ok(bool(CourseStore.check_done(1, br)["ignored"]), "check_done(1, %s) is ignored" % str(br))
	ok(_shape_problems(_read_json(P)).is_empty(), "the file is clean after the check tests")
	# tries are capped at 99
	_fresh()
	for i in 105:
		CourseStore.check_done(1, {"ok": 1, "total": 10})
	eq(CourseStore.week_state(1)["tries"], 99, "tries are capped at 99")


func _check_done_skip() -> void:
	_fresh()
	var s1: Dictionary = CourseStore.check_done(1, {"ok": 9, "total": 10, "skip": true})
	eq([s1["pass"], s1["skip"], s1["pct"]], [true, true, 90], "skip by check 9/10 = 90 passes")
	ok(CourseStore.week_state(1)["done"] and CourseStore.week_state(1)["skipped"], "week 1 is done and skipped")
	eq(CourseStore.pos(), {"w": 2, "d": 1}, "skipping the current week moves pos to the next week")
	var s2: Dictionary = CourseStore.check_done(2, {"ok": 89, "total": 100, "skip": true})
	eq([s2["pass"], s2["pct"]], [false, 89], "skip by check 89/100 does not pass")
	ok(not CourseStore.week_state(2)["done"] and not CourseStore.week_state(2)["skipped"], "a failed skip changes nothing")
	eq(CourseStore.week_state(2)["tries"], 0, "a failed skip is not counted as a failed check")
	eq(CourseStore.pos(), {"w": 2, "d": 1}, "pos unchanged after a failed skip")
	# skip a week that is ahead: pos jumps over it later
	CourseStore.check_done(4, {"ok": 10, "total": 10, "skip": true})
	eq(CourseStore.pos(), {"w": 2, "d": 1}, "skipping a week ahead leaves pos")
	for d in range(1, 8):
		CourseStore.unit_done(_cell(2, d))
	eq(CourseStore.pos(), {"w": 3, "d": 1}, "after week 2: week 3")
	for d in range(1, 8):
		CourseStore.unit_done(_cell(3, d))
	eq(CourseStore.pos(), {"w": 5, "d": 1}, "after week 3: the skipped week 4 is jumped over")
	ok(CourseStore.week_state(4)["done"], "week 4 stays done")
	# two skipped weeks in a row, and the end
	CourseStore.check_done(5, {"ok": 10, "total": 10, "skip": true})
	eq(CourseStore.pos(), {"w": 6, "d": 1}, "skipping the current week 5 -> 6")
	CourseStore.check_done(7, {"ok": 10, "total": 10, "skip": true})
	CourseStore.check_done(6, {"ok": 10, "total": 10, "skip": true})
	eq(CourseStore.pos(), {"w": 8, "d": 1}, "skipping 6 while 7 is already skipped: pos 8/1")
	eq(CourseStore.week_state(5)["best"], 100, "the skip check's score is kept as best")
	_fresh()
	CourseStore.check_done(72, {"ok": 10, "total": 10, "skip": true})
	ok(CourseStore.finished(), "week 72 skipped by check: finished")
	ok(_shape_problems(_read_json(P)).is_empty(), "the file is clean after skips")
	var sk: Array = _read_json(P)["skips"]
	eq(sk, [72.0], "skips lists week 72")


func _month_done() -> void:
	_fresh()
	var m1: Dictionary = CourseStore.month_done(1, {"score": 78, "mode": "stt"})
	eq([m1["ok"], m1["n"], m1["score"], m1["tries"]], [true, 1, 78, 1], "month 1: score 78, tries 1")
	eq(CourseStore.month_state(1), {"n": 1, "score": 78, "date": _iso(0), "tries": 1, "mode": "stt"}, "month_state(1) matches the §10.6 record")
	_day(3)
	var m2: Dictionary = CourseStore.month_done(1, {"score": 90, "mode": "self"})
	eq([m2["score"], m2["tries"]], [90, 2], "month 1 again: score 90, tries 2")
	eq(CourseStore.month_state(1)["date"], _iso(3), "month date is the latest try")
	eq(CourseStore.month_done(2, {"score": 150})["score"], 100, "score 150 is cut to 100")
	eq(CourseStore.month_done(3, {"score": -5})["score"], 0, "score -5 is cut to 0")
	eq(CourseStore.month_done(4, {"score": "x"})["score"], 0, "score as junk text is 0")
	eq(CourseStore.month_state(2)["mode"], "self", "a missing mode is stored as self")
	eq(CourseStore.month_done(5, {"score": 50, "mode": "voice"})["ok"], true, "an unknown mode is accepted ...")
	eq(CourseStore.month_state(5)["mode"], "self", "... and stored as self")
	eq(CourseStore.month_done(18, {"score": 50})["ok"], true, "block 18 exists")
	for bn in [0, 19, -1, "x", null, 1.5]:
		ok(bool(CourseStore.month_done(bn, {"score": 50})["ignored"]), "month_done(%s) is ignored" % str(bn))
	for br in [null, [], "x", 5]:
		ok(bool(CourseStore.month_done(1, br)["ignored"]), "month_done(1, %s) is ignored" % str(br))
	eq(CourseStore.month_state(7), {}, "month_state of a block without a record is {}")
	eq(CourseStore.month_state(0), {}, "month_state(0) is {}")
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "month_done never moves pos")
	ok(_shape_problems(_read_json(P)).is_empty(), "the file is clean after the month records")
	for i in 105:
		CourseStore.month_done(6, {"score": 10})
	eq(CourseStore.month_state(6)["tries"], 99, "month tries are capped at 99")


func _blocks_and_clock() -> void:
	_fresh()
	eq(CourseStore.blocks_today(), {"new": false, "review": false, "listen": false, "speak": false}, "fresh: no block done")
	eq(CourseStore.away_days(), 0, "fresh: away_days 0 (no activity yet)")
	eq(CourseStore.elapsed_days(), 0, "fresh: elapsed_days 0")
	eq(CourseStore.started(), "", "fresh: started is empty")
	for id in ["new", "review", "listen", "speak"]:
		ok(CourseStore.mark_block(id), "mark_block(%s) is true the first time" % id)
		ok(not CourseStore.mark_block(id), "mark_block(%s) again is false (no duplicate)" % id)
	eq(CourseStore.blocks_today(), {"new": true, "review": true, "listen": true, "speak": true}, "all four blocks are done")
	for bad in ["", "check", "NEW", null, 5, []]:
		ok(not CourseStore.mark_block(bad), "mark_block(%s) is false" % str(bad))
	eq(CourseStore.started(), _iso(0), "started was set by the first block")
	_day(1)
	eq(CourseStore.blocks_today(), {"new": false, "review": false, "listen": false, "speak": false}, "next day: blocks are fresh")
	# away_days table: the last activity was on day 0
	for pair in [[0, 0], [1, 1], [6, 6], [7, 7], [8, 8], [20, 20], [21, 21], [100, 100]]:
		_day(int(pair[0]))
		eq(CourseStore.away_days(), int(pair[1]), "away_days %d days after the last activity" % int(pair[0]))
	_day(-5)
	eq(CourseStore.away_days(), 0, "a clock before the last activity: away_days 0")
	_day(10)
	eq(CourseStore.elapsed_days(), 10, "elapsed_days 10 days after the start")
	_day(-3)
	eq(CourseStore.elapsed_days(), 0, "a clock before the start: elapsed_days 0")
	# the file keeps the flags
	var d: Dictionary = _read_json(P)
	eq(d["day"][_iso(0)], {"new": 1.0, "review": 1.0, "listen": 1.0, "speak": 1.0}, "the day record has the four flags")
	ok(_shape_problems(d).is_empty(), "the file is clean after the block tests")


func _review_state() -> void:
	_fresh()
	eq(CourseStore.review_state(), {"prev": false, "streak": 0}, "fresh: no review-first history")
	_day(0)
	CourseStore.note_review_priority(true)
	_day(1)
	CourseStore.note_review_priority(true)
	_day(2)
	CourseStore.note_review_priority(true)
	_day(3)
	eq(CourseStore.review_state(), {"prev": true, "streak": 3}, "three review-first days in a row: streak 3, prev true")
	CourseStore.note_review_priority(true)
	eq(CourseStore.review_state(), {"prev": true, "streak": 3}, "today's own record is not counted")
	CourseStore.note_review_priority(false)
	eq(CourseStore.review_state(), {"prev": true, "streak": 3}, "turning today off changes nothing for today")
	_day(4)
	eq(CourseStore.review_state(), {"prev": false, "streak": 0}, "after a normal day (rp 0): streak 0, prev false")
	_day(6)
	eq(CourseStore.review_state(), {"prev": false, "streak": 0}, "a rest day in between: streak 0, prev from the latest record (rp 0)")
	_fresh()
	_day(0)
	CourseStore.note_review_priority(true)
	_day(3)
	eq(CourseStore.review_state(), {"prev": true, "streak": 0}, "a gap: streak 0 but prev stays true (the 25-card release needs it)")
	ok(not CourseStore.note_review_priority("yes"), "note_review_priority('yes') is refused")
	ok(not CourseStore.note_review_priority(null), "note_review_priority(null) is refused")
	ok(CourseStore.note_review_priority(true), "note_review_priority(true) twice is fine")
	var d: Dictionary = _read_json(P)
	eq(d["day"][_iso(3)], {"rp": 1.0}, "the day record holds rp")
	ok(_shape_problems(d).is_empty(), "the file is clean after rp records")


func _reopen() -> void:
	_fresh()
	for w in range(1, 5):
		for d in range(1, 8):
			CourseStore.unit_done(_cell(w, d))
	CourseStore.check_done(3, {"ok": 9, "total": 10})
	CourseStore.check_done(4, {"ok": 9, "total": 10})
	eq(CourseStore.pos(), {"w": 5, "d": 1}, "reopen test: pos 5/1")
	eq(CourseStore.reopen_weeks([3, 4]), 2, "reopen_weeks([3, 4]) reopens 2 weeks")
	ok(not CourseStore.week_state(3)["done"] and not CourseStore.week_state(4)["done"], "weeks 3 and 4 are not done any more")
	eq(CourseStore.week_state(3)["days"], [], "their finished days are cleared")
	eq(CourseStore.week_state(3)["best"], 90, "the check record is kept")
	ok(CourseStore.week_state(2)["done"], "week 2 stays done")
	eq(CourseStore.pos(), {"w": 3, "d": 1}, "pos goes back to the first reopened week")
	eq(CourseStore.reopen_weeks([3, 4]), 0, "reopening again changes nothing (0)")
	eq(CourseStore.reopen_weeks([40, 41]), 0, "weeks that were never started: 0")
	eq(CourseStore.reopen_weeks([0, 73, "x", null, 1.5]), 0, "invalid weeks: 0")
	eq(CourseStore.reopen_weeks("3"), 0, "a non-array: 0")
	eq(CourseStore.reopen_weeks([]), 0, "an empty list: 0")
	eq(CourseStore.reopen_weeks([1]), 1, "reopening an earlier week still works")
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "pos goes back to week 1")
	# redoing a reopened week records its days again
	var r: Dictionary = CourseStore.unit_done(_cell(1, 1))
	eq([r["w"], r["d"]], [1, 2], "a reopened week can be finished again")
	ok(_shape_problems(_read_json(P)).is_empty(), "the file is clean after reopening")
	# finished course reopened
	_fresh()
	CourseStore.check_done(72, {"ok": 10, "total": 10, "skip": true})
	ok(CourseStore.finished(), "finished before reopening")
	CourseStore.unit_done(_cell(72, 6))
	CourseStore.reopen_weeks([72])
	ok(not CourseStore.finished(), "reopening week 72 clears finished()")


func _check_pending() -> void:
	_fresh()
	eq(CourseStore.check_pending(), {"pending": false, "w": 0, "days": 0}, "fresh: no pending check")
	for d in range(1, 8):
		CourseStore.unit_done(_cell(1, d))
	_day(2)
	eq(CourseStore.check_pending(), {"pending": true, "w": 1, "days": 2}, "week 1 passed over without a check: pending, 2 days")
	_day(5)
	eq(CourseStore.check_pending()["days"], 5, "pending days grow with the calendar")
	CourseStore.check_done(1, {"ok": 9, "total": 10})
	eq(CourseStore.check_pending()["pending"], false, "a passed check ends the pending state")
	_fresh()
	for d in range(1, 8):
		CourseStore.unit_done(_cell(1, d))
	CourseStore.check_done(1, {"ok": 1, "total": 10})
	CourseStore.check_done(1, {"ok": 1, "total": 10})
	eq(CourseStore.check_pending()["pending"], false, "a weak week (2 failures) is not pending")
	_fresh()
	for d in range(1, 8):
		CourseStore.unit_done(_cell(1, d))
	CourseStore.check_done(1, {"ok": 10, "total": 10, "skip": true})
	eq(CourseStore.check_pending()["pending"], false, "a skipped week is not pending")
	_fresh()
	for d in range(1, 4):
		CourseStore.unit_done(_cell(1, d))
	eq(CourseStore.check_pending()["pending"], false, "the current week is never pending")


func _file_shape_and_roundtrip() -> void:
	_fresh()
	CourseStore.unit_done(_cell(1, 1))
	CourseStore.unit_done(_cell(1, 2))
	CourseStore.mark_block("review")
	CourseStore.check_done(1, {"ok": 7, "total": 10, "speak": "pass"})
	CourseStore.month_done(1, {"score": 66, "mode": "stt"})
	CourseStore.note_review_priority(true)
	var text: String = _read_text(P)
	var d: Dictionary = JSON.parse_string(text)
	ok(_shape_problems(d).is_empty(), "round trip: the file has the §10.6 shape")
	ok(not FileAccess.file_exists(P + ".tmp"), "round trip: no temp file left")
	for k in ["v", "started", "pos", "weeks", "months", "day", "last_active", "skips"]:
		ok(d.has(k), "round trip: the file has key %s" % k)
	var ws: Dictionary = CourseStore.week_state(1)
	var pos: Dictionary = CourseStore.pos()
	var flags: Array = CourseStore.path_flags()
	var blocks: Dictionary = CourseStore.blocks_today()
	var mon: Dictionary = CourseStore.month_state(1)
	CourseStore.reset_memory()
	eq(CourseStore.pos(), pos, "round trip: pos")
	eq(CourseStore.week_state(1), ws, "round trip: week_state(1)")
	eq(CourseStore.path_flags(), flags, "round trip: path_flags")
	eq(CourseStore.blocks_today(), blocks, "round trip: blocks_today")
	eq(CourseStore.month_state(1), mon, "round trip: month_state(1)")
	eq(CourseStore.last_load_status, "ok", "round trip: load status ok")
	CourseStore.load()
	eq(CourseStore.last_load_status, "ok", "CourseStore.load() reads the file again")
	# writing again gives the same text (stable)
	CourseStore.unit_done(_cell(1, 2))
	eq(_read_text(P).length() > 0, true, "the file is still there after repeated records")
	# a valid file written by hand is read as it is
	_fresh()
	_write_text(P, JSON.stringify({"v": 1, "started": "2026-12-01", "pos": {"w": 5, "d": 2},
		"weeks": {"1": {"done": "2026-12-07", "days": {"1": "2026-12-01"}, "check": {"best": 90, "tries": 1, "last": "2026-12-07", "speak": "pass"}, "weak": false}},
		"months": {"1": {"score": 78, "date": "2026-12-28", "tries": 1, "mode": "stt"}}, "day": {"2026-12-01": {"new": 1, "review": 1, "listen": 1, "speak": 1}},
		"last_active": "2026-12-01", "skips": [3]}))
	eq(CourseStore.pos(), {"w": 5, "d": 2}, "the design example file: pos 5/2")
	eq(CourseStore.started(), "2026-12-01", "the design example file: started")
	var st: Dictionary = CourseStore.week_state(1)
	eq([st["done"], st["best"], st["tries"], st["speak"], st["passed"]], [true, 90, 1, "pass", true], "the design example file: week 1")
	eq(CourseStore.week_state(3)["skipped"], true, "the design example file: week 3 skipped")
	eq(CourseStore.month_state(1)["score"], 78, "the design example file: month 1 score")
	_day(9)
	eq(CourseStore.away_days(), 8 + 1, "the design example file: away_days counts from last_active (2026-12-01)")


func _unknown_keys_and_future() -> void:
	_fresh()
	_write_text(P, JSON.stringify({"v": 1, "pos": {"w": 2, "d": 3}, "future_key": {"a": [1, 2, {"b": "c"}]}, "note": "keep me",
		"weeks": {"2": {"done": "", "days": {}, "weak": false, "extra_field": 7}}, "months": {"1": {"score": 50, "date": "2026-12-01", "tries": 1, "mode": "stt", "cheer": "yes"}}}))
	CourseStore.unit_done(_cell(2, 3))
	var d: Dictionary = _read_json(P)
	eq(d.get("note"), "keep me", "an unknown top-level key (text) is kept")
	eq(d.get("future_key"), {"a": [1.0, 2.0, {"b": "c"}]}, "an unknown top-level key (nested) is kept")
	eq(d["weeks"]["2"].get("extra_field"), 7.0, "an unknown key inside a week record is kept")
	eq(d["months"]["1"].get("cheer"), "yes", "an unknown key inside a month record is kept")
	eq(d["pos"], {"w": 2.0, "d": 4.0}, "the known part was updated")
	# a newer file version is read-only
	_fresh()
	var future_text: String = JSON.stringify({"v": 2, "started": "2026-12-01", "pos": {"w": 9, "d": 4}, "shiny": [1, 2, 3]})
	_write_text(P, future_text)
	eq(CourseStore.pos(), {"w": 9, "d": 4}, "v 2 file: the known fields are read (pos 9/4)")
	eq(CourseStore.last_load_status, "future", "v 2 file: load status future")
	ok(CourseStore.is_read_only(), "v 2 file: is_read_only()")
	var r: Dictionary = CourseStore.unit_done(_cell(9, 4))
	eq([r["w"], r["d"]], [9, 5], "v 2 file: the session still works in memory")
	ok(not CourseStore.last_save_ok, "v 2 file: last_save_ok is false")
	eq(_read_text(P), future_text, "v 2 file: the file is byte for byte unchanged")
	ok(CourseStore.mark_block("review"), "v 2 file: mark_block works in memory")
	ok(not CourseStore.save(), "v 2 file: save() writes nothing")
	eq(_read_text(P), future_text, "v 2 file: still unchanged after save()")
	CourseStore.set_mode("course")
	eq(_read_text(P), future_text, "v 2 file: set_mode('course') does not overwrite it")
	# v 0 or junk v: treated as readable
	_fresh()
	_write_text(P, JSON.stringify({"v": "x", "pos": {"w": 3, "d": 3}}))
	eq(CourseStore.pos(), {"w": 3, "d": 3}, "a junk v is read like v 1")
	ok(not CourseStore.is_read_only(), "a junk v is not read-only")


func _broken_files() -> void:
	var cases: Dictionary = {
		"cut JSON": '{"v":1,"pos":{"w":3',
		"empty file": "",
		"array": "[1,2,3]",
		"text": "hello",
		"number": "42",
		"null": "null",
	}
	for name in cases.keys():
		_fresh()
		_write_text(P, cases[name])
		eq(CourseStore.pos(), {"w": 1, "d": 1}, "broken file (%s): the state starts empty" % name)
		ok(FileAccess.file_exists(P + ".bad"), "broken file (%s): moved to .bad" % name)
		ok(not FileAccess.file_exists(P), "broken file (%s): the original name is free" % name)
		eq(_read_text(P + ".bad"), cases[name], "broken file (%s): the .bad copy is the original text" % name)
		ok(not CourseStore.is_read_only(), "broken file (%s): not read-only (a new file can be written)" % name)
		CourseStore.unit_done(_cell(1, 1))
		ok(_shape_problems(_read_json(P)).is_empty(), "broken file (%s): the next record writes a clean file" % name)
		eq(CourseStore.pos(), {"w": 1, "d": 2}, "broken file (%s): and works" % name)
	# up to three .bad files are kept
	_fresh()
	for i in 5:
		_write_text(P, "broken %d" % i)
		CourseStore.reset_memory()
		CourseStore.pos()
	ok(FileAccess.file_exists(P + ".bad") and FileAccess.file_exists(P + ".bad.1") and FileAccess.file_exists(P + ".bad.2"), "five broken files: .bad .bad.1 .bad.2 exist")
	ok(not FileAccess.file_exists(P + ".bad.3"), "five broken files: no .bad.3 (three at most)")
	eq(_read_text(P + ".bad"), "broken 4", "the newest broken file is .bad")
	eq(_read_text(P + ".bad.1"), "broken 3", "the one before is .bad.1")
	eq(_read_text(P + ".bad.2"), "broken 2", "and .bad.2")
	# a broken file in legacy mode: reading only (still nothing written but the quarantine move)
	_fresh("legacy")
	ok(not FileAccess.file_exists(P), "legacy: no file to start with")


func _unreadable_and_write_failure() -> void:
	# a file that exists but cannot be opened: read-only, untouched
	_fresh()
	CourseStore.unit_done(_cell(1, 1))
	var good: String = _read_text(P)
	CourseStore.reset_memory()
	Progress.open_hook = func(_p: String) -> FileAccess: return null
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "unreadable file: the state starts empty")
	eq(CourseStore.last_load_status, "unreadable", "unreadable file: load status unreadable")
	ok(CourseStore.is_read_only(), "unreadable file: read-only")
	var r: Dictionary = CourseStore.unit_done(_cell(1, 1))
	ok(not bool(r["ignored"]), "unreadable file: the session still works in memory")
	ok(not CourseStore.last_save_ok, "unreadable file: nothing was saved")
	Progress.open_hook = Callable()
	eq(_read_text(P), good, "unreadable file: the file is byte for byte unchanged")
	ok(not FileAccess.file_exists(P + ".bad"), "unreadable file: not moved to .bad")
	# the write fails (read-only folder / disk full): no crash, memory keeps the change, the old file stays
	_fresh()
	CourseStore.unit_done(_cell(1, 1))
	var before: String = _read_text(P)
	Progress.write_hook = func(_tmp: String, _text: String) -> bool: return false
	var r2: Dictionary = CourseStore.unit_done(_cell(1, 2))
	ok(not bool(r2["ignored"]) and r2["d"] == 3, "write failure: the change stays in memory")
	ok(not CourseStore.last_save_ok, "write failure: last_save_ok is false")
	ok(not CourseStore.save(), "write failure: save() returns false")
	ok(CourseStore.check_done(1, {"ok": 9, "total": 10})["ok"], "write failure: check_done does not crash")
	ok(CourseStore.month_done(1, {"score": 70})["ok"], "write failure: month_done does not crash")
	ok(CourseStore.mark_block("listen"), "write failure: mark_block does not crash")
	Progress.write_hook = Callable()
	eq(_read_text(P), before, "write failure: the old file is unchanged")
	ok(not FileAccess.file_exists(P + ".tmp"), "write failure: no temp file left")
	# a half-written temp file (a crash while writing) never replaces the file
	Progress.write_hook = func(tmp: String, text: String) -> bool:
		_write_text(tmp, text.substr(0, text.length() / 2))
		return false
	CourseStore.unit_done(_cell(1, 3))
	Progress.write_hook = Callable()
	eq(_read_text(P), before, "half-written write: the old file is unchanged")
	ok(not FileAccess.file_exists(P + ".tmp"), "half-written write: the temp file was removed")
	# the next good write recovers
	CourseStore.mark_block("speak")
	ok(CourseStore.last_save_ok and _shape_problems(_read_json(P)).is_empty(), "after the failures a normal write works again")
	# a folder that does not exist: save fails quietly
	CourseStore.path = "user://test_e3_no_such_dir/course.json"
	CourseStore.reset_memory()
	var r3: Dictionary = CourseStore.unit_done(_cell(1, 1))
	ok(not bool(r3["ignored"]), "missing folder: the call works in memory")
	ok(not CourseStore.last_save_ok, "missing folder: nothing saved, no crash")
	CourseStore.path = P


func _value_clamps() -> void:
	_fresh()
	var raw: Dictionary = {"v": 1, "started": "2026-02-30", "last_active": "garbage", "pos": {"w": 99, "d": 0},
		"weeks": {"99": {"done": "2026-12-01", "days": {}}, "0": {"done": "2026-12-01"}, "x": {}, "-3": {}, "5": {"done": "bad date", "days": {"0": "2026-12-01", "8": "2026-12-01", "3": "2026-12-05", "4": "nope"},
			"check": {"best": 150, "tries": 500, "last": "2026-12-05", "speak": "excellent"}, "weak": "yes"}, "6": "not a record", "7": [1, 2]},
		"months": {"0": {"score": 10}, "19": {"score": 10}, "2": {"score": 150, "date": "2026-12-05", "tries": -3, "mode": "x"}, "3": 5},
		"day": {"2026-13-01": {"new": 1}, "2026-12-05": {"new": 7, "review": -1, "listen": "x", "speak": 1.0, "rp": 1}, "nope": {}},
		"skips": [3, 3, 99, "x", 5.0, 2, 0, -1, 72, 1.5]}
	_write_text(P, JSON.stringify(raw))
	eq(CourseStore.pos(), {"w": 72, "d": 1}, "pos w 99 -> 72, d 0 -> 1")
	eq(CourseStore.started(), "", "an impossible date in started is dropped")
	eq(CourseStore.away_days(), 0, "a junk last_active gives away_days 0")
	var flags: Array = CourseStore.path_flags()
	eq(flags.size(), 72, "72 flags")
	eq(flags.count(true), 0, "week keys 99 / 0 / x / -3 are dropped (no week became done)")
	var w5: Dictionary = CourseStore.week_state(5)
	eq(w5["best"], 100, "check best 150 -> 100")
	eq(w5["tries"], 99, "check tries 500 -> 99")
	eq(w5["speak"], "", "an unknown speak value -> empty")
	eq(w5["weak"], false, "weak as text -> false")
	eq(w5["days"], [3], "day keys 0 / 8 / 4(bad date) are dropped, day 3 stays")
	eq(w5["done"], false, "a bad done date -> not done")
	eq(CourseStore.week_state(6)["days"], [], "a week record that is not a dictionary: empty")
	eq(CourseStore.week_state(7)["days"], [], "a week record that is an array: empty")
	var m2: Dictionary = CourseStore.month_state(2)
	eq([m2["score"], m2["tries"], m2["mode"]], [100, 0, "self"], "month: score 150 -> 100, tries -3 -> 0, mode x -> self")
	eq(CourseStore.month_state(3), {}, "a month record that is a number is dropped")
	eq(CourseStore.month_state(19), {}, "month 19 does not exist")
	CourseStore.mark_block("listen")
	var d: Dictionary = _read_json(P)
	ok(_shape_problems(d).is_empty(), "after one write the clamped file has the §10.6 shape: %s" % str(_shape_problems(d)))
	eq(d["skips"], [2.0, 3.0, 5.0, 72.0], "skips: unique, sorted, in range")
	eq(d["day"]["2026-12-05"], {"new": 1.0, "review": 0.0, "listen": 0.0, "speak": 1.0, "rp": 1.0}, "day flags are 0 / 1")
	ok(not d["day"].has("2026-13-01") and not d["day"].has("nope"), "day keys that are not dates are dropped")
	# whole containers of the wrong type
	_fresh()
	_write_text(P, JSON.stringify({"v": 1, "pos": "5", "weeks": [1, 2], "months": "x", "day": 5, "skips": {"a": 1}, "started": 5}))
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "pos as text -> 1/1")
	eq(CourseStore.path_flags().count(true), 0, "weeks as an array -> nothing")
	ok(not CourseStore.finished(), "junk containers: not finished")
	CourseStore.unit_done(_cell(1, 1))
	ok(_shape_problems(_read_json(P)).is_empty(), "junk containers: the next write is clean")
	# floats and text numbers in pos
	_fresh()
	_write_text(P, JSON.stringify({"v": 1, "pos": {"w": "12", "d": 3.7}}))
	eq(CourseStore.pos(), {"w": 12, "d": 3}, "pos from text / float: 12/3")


func _pruning() -> void:
	_fresh()
	for i in 130:
		_day(i)
		CourseStore.mark_block("new")
	var d: Dictionary = _read_json(P)
	eq((d["day"] as Dictionary).size(), 120, "only 120 day records are kept")
	ok(d["day"].has(_iso(129)) and d["day"].has(_iso(10)), "the newest days are kept")
	ok(not d["day"].has(_iso(9)) and not d["day"].has(_iso(0)), "the oldest days are dropped")
	ok(_shape_problems(d).is_empty(), "the pruned file is clean")
	eq(CourseStore.started(), _iso(0), "started survives the pruning")


func _real_name_guard() -> void:
	ok(Progress.test_guard, "this run is a test run (the test guard is active)")
	ok(Progress.REAL_FILE_NAMES.has("course.json"), "course.json is in Progress.REAL_FILE_NAMES")
	ok(Progress.guard_blocks("user://course.json"), "the guard blocks user://course.json")
	ok(not Progress.guard_blocks(P), "the guard lets user://test_e3_course.json through")
	ok(not Progress.guard_blocks("user://test_guard/course.json"), "the guard lets user://test_guard/course.json through")
	_fresh()
	CourseStore.path = "user://course.json"
	CourseStore.reset_memory()
	var r: Dictionary = CourseStore.unit_done(_cell(1, 1))
	ok(not bool(r["ignored"]), "a record on the real file name works in memory")
	ok(not CourseStore.last_save_ok, "writing the real name course.json is refused by the test guard")
	ok(not FileAccess.file_exists("user://course.json"), "and no user://course.json exists")
	ok(not CourseStore.save(), "save() on the real name is refused too")
	CourseStore.path = P
	CourseStore.reset_memory()


## The whole course, cell by cell.
func _full_walk() -> void:
	_fresh()
	var steps := 0
	var wrong := 0
	for w in range(1, 73):
		for d in range(1, 8):
			_day(steps / 2)
			var r: Dictionary = CourseStore.unit_done(_cell(w, d))
			steps += 1
			var nw: int = w
			var nd: int = d + 1
			if nd > 7:
				nw = w + 1
				nd = 1
			if w == 72 and d == 7:
				nw = 72
				nd = 7
			if r["w"] != nw or r["d"] != nd:
				wrong += 1
	eq(steps, 504, "walked 504 cells")
	eq(wrong, 0, "every cell moved pos to exactly the next cell (no jump, no repeat)")
	ok(CourseStore.finished(), "the walk ends finished")
	eq(CourseStore.path_flags().count(true), 72, "all weeks done after the walk")
	var d2: Dictionary = _read_json(P)
	ok(_shape_problems(d2).is_empty(), "the file after 504 records has the §10.6 shape")
	eq((d2["day"] as Dictionary).size(), 120, "the walk (252 calendar days) keeps 120 day records")
	ok(_read_text(P).length() < 65536, "the finished file is small (< 64 KB, %d bytes)" % _read_text(P).length())


## CourseModel reads CourseStore dynamically (store_script_path): course mode gives the course position, legacy / Japanese do not.
func _model_integration() -> void:
	_fresh()
	for w in range(1, 20):
		for d in range(1, 8):
			CourseStore.unit_done(_cell(w, d))
	CourseStore.unit_done(_cell(20, 1))
	CourseStore.unit_done(_cell(20, 2))
	eq(CourseStore.pos(), {"w": 20, "d": 3}, "integration: pos 20/3")
	var p: Dictionary = CourseModel.pos_for("en")
	eq([p["cw"], p["cd"], p["stage"], p["n"], p["w"]], [20, 3, 2, 4, 1], "integration: pos_for('en') = course week 20 day 3, legacy stage 2, cell 4-1")
	eq(CourseModel.stage_for("en"), 2, "integration: stage_for('en') == 2 in course mode")
	var ja: Dictionary = CourseModel.pos_for("ja")
	eq([ja["cw"], ja["cd"]], [0, 0], "integration: Japanese never uses the course position")
	var st: Dictionary = CourseModel.states(CourseStore.path_flags(), 20, 20)
	eq(st["states"][18], "done", "integration: states(): week 19 is done")
	eq(st["states"][19], "current", "integration: states(): week 20 is the current week")
	eq(st["done_count"], 19, "integration: 19 weeks done")
	Store.prefs["course_mode"] = "legacy"
	var p2: Dictionary = CourseModel.pos_for("en")
	eq([p2["cw"], p2["cd"]], [0, 0], "integration: legacy mode gives the calendar position (cw 0)")


func _source_scan() -> void:
	for f in ["res://scripts/core/course_store.gd", "res://scripts/core/day_plan.gd", "res://scripts/core/course_cards.gd", "res://scripts/core/course_feed.gd"]:
		var text: String = FileAccess.get_file_as_string(f)
		ok(text.length() > 0, "%s is readable" % f.get_file())
		for bad in _forbidden():
			ok(not text.contains(bad), "%s has no %s" % [f.get_file(), bad])
		ok(not _has_symbol_chars(text), "%s has no emoji or dingbat characters" % f.get_file())
	var store_text: String = FileAccess.get_file_as_string("res://scripts/core/course_store.gd")
	ok(not store_text.contains("StudyLog.add_") and not store_text.contains("Store.add_"), "course_store.gd calls no StudyLog.add_* / Store.add_*")


## Built from pieces so that this test file itself never contains the forbidden words.
func _forbidden() -> Array:
	return ["add_path" + "_lesson", "HTTP" + "Request", "OS.shell" + "_open", "request" + "_permission", "87" + "70", "87" + "75", "87" + "76", "Color(" + "\"#"]


func _has_symbol_chars(text: String) -> bool:
	for i in text.length():
		var c: int = text.unicode_at(i)
		if (c >= 0x2190 and c <= 0x2BFF) or c >= 0x1F000:
			return true
	return false
