extends Node
## PathModel (레슨 길 48칸 계산) + Store 신호(navigate_args, ai_connect_requested) + AppView.open_target 기본 구현.
##   godot --headless --path <project> res://tests/path_model_test.tscn
## 종료 코드 0 = 전부 통과. 마지막 줄: "== path_model result: N passed, 0 failed =="
## 실제 user:// 파일은 읽지도 쓰지도 않는다: Store.prefs_path / Store.progress_path / StudyLog.path 를
## user://test_home_t1a_* 로 바꿨다가 끝나면 되돌린다.

const LOG_PATH := "user://test_home_t1a_studylog.json"
const PROG_PATH := "user://test_home_t1a_progress.json"
const PREFS_PATH := "user://test_home_t1a_prefs.json"

var passed: int = 0
var failed: int = 0
var _old_paths: Array = []
var _old_progress: Dictionary = {}


func _ready() -> void:
	print("== path_model start ==")
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	_old_progress = Store.progress
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	_cleanup()
	StudyLog.load_from_disk()

	_test_constants_and_indices()
	_test_states_table()
	_test_states_robustness()
	_test_done_flags_and_current()
	_test_signals()

	_cleanup()
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	Store.progress = _old_progress
	print("== path_model result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".tmp", PROG_PATH, PROG_PATH + ".tmp", PREFS_PATH]:
		_rm(p)


# ---------------------------------------------------------------- helpers

## 48 flags with the given cell indices set to true.
func flags(done_idx: Array) -> Array:
	var a: Array = []
	for i in PathModel.CELLS:
		a.append(done_idx.has(i))
	return a


## Compares PathModel.states(done, cal, last, look) with an expectation:
##   exp = {"current": int, "finished": bool, "done_count": int, "state": {index: "state"}, "range": [[from, to, "state"], ...]}
## Returns "" when it matches, otherwise a description of the first difference. This is the one checker every table row uses.
func compare(done: Array, cal: int, last: int, look: int, exp: Dictionary) -> String:
	var r: Dictionary = PathModel.states(done, cal, last, look)
	var st: Array = r["states"]
	if st.size() != PathModel.CELLS:
		return "states has %d entries" % st.size()
	for s in st:
		if not ["done", "current", "open", "past", "locked"].has(s):
			return "unknown state %s" % str(s)
	if int(r["current"]) != int(exp["current"]):
		return "current %d != %d" % [int(r["current"]), int(exp["current"])]
	if bool(r["finished"]) != bool(exp.get("finished", false)):
		return "finished %s" % str(r["finished"])
	if exp.has("done_count") and int(r["done_count"]) != int(exp["done_count"]):
		return "done_count %d != %d" % [int(r["done_count"]), int(exp["done_count"])]
	for k in (exp.get("state", {}) as Dictionary).keys():
		if st[int(k)] != exp["state"][k]:
			return "state[%d] = %s, expected %s" % [int(k), st[int(k)], exp["state"][k]]
	for rg in exp.get("range", []):
		for i in range(int(rg[0]), int(rg[1]) + 1):
			if st[i] != rg[2]:
				return "state[%d] = %s, expected %s" % [i, st[i], rg[2]]
	return ""


## One table row: prints PASS / FAIL with the first difference.
func row(name: String, done: Array, cal: int, last: int, exp: Dictionary, look: int = PathModel.LOOKAHEAD) -> void:
	var diff: String = compare(done, cal, last, look, exp)
	ok(diff == "", "%s%s" % [name, "" if diff == "" else " -> " + diff])


# ---------------------------------------------------------------- tests

func _test_constants_and_indices() -> void:
	print("[constants and indices]")
	ok(PathModel.MONTHS == 12 and PathModel.WEEKS == 4 and PathModel.CELLS == 48 and PathModel.NODE_GOAL == 5 and PathModel.LOOKAHEAD == 2, "constants: 12 months x 4 weeks = 48 cells, NODE_GOAL 5, LOOKAHEAD 2")
	ok(PathModel.index_of(1, 1) == 0 and PathModel.index_of(3, 2) == 9 and PathModel.index_of(12, 4) == 47, "index_of(1,1)=0, (3,2)=9, (12,4)=47")
	ok(PathModel.index_of(13, 1) == -1 and PathModel.index_of(0, 1) == -1 and PathModel.index_of(1, 5) == -1 and PathModel.index_of(1, 0) == -1 and PathModel.index_of(-3, -3) == -1, "index_of(13,1) == -1 and every other out-of-range pair too")
	ok(PathModel.cell_of(9) == [3, 2] and PathModel.cell_of(0) == [1, 1] and PathModel.cell_of(47) == [12, 4], "cell_of(9)=[3,2], (0)=[1,1], (47)=[12,4]")
	ok(PathModel.cell_of(48) == [] and PathModel.cell_of(-1) == [] and PathModel.cell_of(9999) == [], "cell_of(48) == [] (also -1, 9999)")
	var round_trip := true
	for i in PathModel.CELLS:
		var c: Array = PathModel.cell_of(i)
		round_trip = round_trip and PathModel.index_of(c[0], c[1]) == i
	ok(round_trip, "index_of(cell_of(i)) == i for all 48 cells")
	ok(PathModel.key_of(3, 2) == "3-2" and PathModel.key_of(12, 4) == "12-4" and PathModel.key_of(13, 1) == "" and PathModel.key_of(1, 0) == "", "key_of: '3-2', '12-4'; out of range -> ''")
	var keys_ok := true
	for i in PathModel.CELLS:
		var c: Array = PathModel.cell_of(i)
		keys_ok = keys_ok and StudyLog._is_cell_key(PathModel.key_of(c[0], c[1]))
	ok(keys_ok, "every key_of() key is a valid studylog path cell key")


func _test_states_table() -> void:
	print("[states table]")
	var all47: Array = range(0, 47)
	# 1. nothing done, no record, calendar at the start
	row("1 nothing done, cal 0, no record: current 0, 1-2 open, 3.. locked", flags([]), 0, -1,
		{"current": 0, "done_count": 0, "state": {0: "current", 1: "open", 2: "open", 3: "locked", 47: "locked"}, "range": [[3, 47, "locked"]]})
	# 2. record, that cell not finished; cells before it that are not finished are 'past'
	row("2 record at 9 (3-2) unfinished, 8 (3-1) done: current 9; 0-7 past, 8 done, 10-11 open, 12.. locked", flags([8]), 0, 9,
		{"current": 9, "done_count": 1, "state": {8: "done", 9: "current", 10: "open", 11: "open", 12: "locked"}, "range": [[0, 7, "past"], [12, 47, "locked"]]})
	# 3. record cell finished -> next unfinished one
	row("3 record at 9 finished: current 10; 0-7 past, 8-9 done, 11-12 open, 13.. locked", flags([8, 9]), 0, 9,
		{"current": 10, "done_count": 2, "state": {8: "done", 9: "done", 10: "current", 11: "open", 12: "open", 13: "locked"}, "range": [[0, 7, "past"]]})
	# 4. the record is the last cell and finished -> wraps to the first unfinished cell
	row("4 record at 47 finished, nothing else done: current wraps to 0", flags([47]), 0, 47,
		{"current": 0, "done_count": 1, "state": {0: "current", 1: "open", 2: "open", 3: "locked", 47: "done"}})
	# 5. everything done
	row("5 all 48 done: finished, current 47, every cell done", flags(range(0, 48)), 5, 20,
		{"current": 47, "finished": true, "done_count": 48, "range": [[0, 47, "done"]]})
	# 6. no record, calendar at 20
	row("6 no record, calendar 20: current 20; 0-19 past, 21-22 open, 23.. locked", flags([]), 20, -1,
		{"current": 20, "state": {20: "current", 21: "open", 22: "open", 23: "locked"}, "range": [[0, 19, "past"], [23, 47, "locked"]]})
	# 7. no record, calendar cell already done -> next unfinished at or after it
	row("7 no record, calendar 20, cells 20-21 done: current 22", flags([20, 21]), 20, -1,
		{"current": 22, "state": {20: "done", 21: "done", 22: "current", 23: "open", 24: "open", 25: "locked"}})
	# 8. a skipped cell in the middle
	row("8 done 0,1,5 and record at 5: current 6; 2-4 past; 0,1,5 done", flags([0, 1, 5]), 0, 5,
		{"current": 6, "state": {0: "done", 1: "done", 2: "past", 3: "past", 4: "past", 5: "done", 6: "current", 7: "open", 8: "open", 9: "locked"}})
	# 9. nothing after the calendar position is unfinished -> first unfinished from the start
	row("9 no record, calendar 30, cells 20-47 done: current 0 (nothing left after 30)", flags(range(20, 48)), 30, -1,
		{"current": 0, "state": {0: "current", 19: "locked", 20: "done"}, "done_count": 28})
	# 10. only the last cell open
	row("10 cells 0-46 done: current 47, finished false", flags(all47), 0, -1,
		{"current": 47, "finished": false, "done_count": 47, "state": {47: "current", 46: "done"}})
	# 11. lookahead
	row("11a lookahead 0: nothing is open", flags([]), 3, -1,
		{"current": 3, "state": {3: "current", 4: "locked", 5: "locked"}, "range": [[4, 47, "locked"]]}, 0)
	row("11b lookahead 5: 6 cells after current are open", flags([]), 3, -1,
		{"current": 3, "state": {3: "current", 4: "open", 8: "open", 9: "locked"}, "range": [[4, 8, "open"], [9, 47, "locked"]]}, 5)
	row("11c lookahead -3 behaves like 0", flags([]), 3, -1,
		{"current": 3, "state": {4: "locked"}}, -3)
	row("11d lookahead 100: everything after current is open", flags([]), 3, -1,
		{"current": 3, "range": [[4, 47, "open"]]}, 100)
	# 12. a finished cell inside the look-ahead window stays done
	row("12 cell 11 done inside the window: stays done, 10 open, 12 locked", flags([11]), 0, 9,
		{"current": 9, "state": {10: "open", 11: "done", 12: "locked"}})
	# 13. the T5-2 situation: month 3 week 1 done 5x, week 2 done 3x -> current 3-2 (cell 9)
	var t52: Array = flags([8]) ## 3-1 finished (5 lessons), 3-2 not (3 lessons)
	row("13 (design T5-2) record 3-2 unfinished: 0-7 past, 8 done, 9 current, 10-11 open, 12.. locked", t52, 3, 9,
		{"current": 9, "range": [[0, 7, "past"], [12, 47, "locked"]], "state": {8: "done", 9: "current", 10: "open", 11: "open"}})


func _test_states_robustness() -> void:
	print("[states with odd input]")
	# done array length
	var short: Array = [true, true, true, true, true, true, true, true, true, true] ## length 10
	row("14 done array of length 10 (cells 0-9 done): current 10, rest unfinished", short, 0, -1,
		{"current": 10, "done_count": 10, "state": {9: "done", 10: "current", 11: "open", 12: "open", 13: "locked"}})
	var long: Array = []
	for i in 60:
		long.append(true)
	row("15 done array of length 60 all true: extra entries ignored, finished", long, 0, -1,
		{"current": 47, "finished": true, "done_count": 48, "range": [[0, 47, "done"]]})
	var long2: Array = []
	for i in 60:
		long2.append(i != 47)
	row("16 done array of length 60 with cell 47 false: current 47 (entries 48-59 ignored)", long2, 0, -1,
		{"current": 47, "finished": false, "done_count": 47})
	row("17 empty done array: like nothing done", [], 0, -1, {"current": 0, "done_count": 0, "state": {1: "open", 3: "locked"}})
	row("18 odd entries (1, 0, 'x', null, 2.5, true): only 1 and true count", [1, 0, "x", null, 2.5, true], 0, -1,
		{"current": 1, "done_count": 2, "state": {0: "done", 1: "current", 5: "done"}})
	# cal_idx out of range
	row("19a cal_idx -5 -> 0", flags([]), -5, -1, {"current": 0, "state": {0: "current"}})
	row("19b cal_idx 999 -> 47", flags([]), 999, -1, {"current": 47, "state": {47: "current", 46: "past", 0: "past"}, "range": [[0, 46, "past"]]})
	row("19c cal_idx 47 and 47 done: first unfinished from the start (0)", flags([47]), 47, -1, {"current": 0})
	# last_idx out of range = no record
	row("20a last_idx -1 = no record, calendar decides", flags([]), 12, -1, {"current": 12})
	row("20b last_idx 48 = no record", flags([]), 12, 48, {"current": 12})
	row("20c last_idx -99 = no record", flags([]), 12, -99, {"current": 12})
	row("20d last_idx 999 = no record", flags([]), 12, 999, {"current": 12})
	row("20e last_idx 0 is a record (cell 0 unfinished)", flags([]), 12, 0, {"current": 0, "state": {12: "locked"}})
	# the record wins over the calendar
	row("21 record at 5 beats calendar 30", flags([]), 30, 5, {"current": 5})
	# states never gives more than one current
	var one_current := true
	for cal in [-3, 0, 7, 47, 100]:
		for last in [-1, 0, 20, 47, 60]:
			for look in [-1, 0, 2, 9]:
				var st: Array = PathModel.states(flags([2, 3, 20]), cal, last, look)["states"]
				one_current = one_current and st.count("current") == 1 and st.size() == 48
	ok(one_current, "22 exactly one 'current' among 48 states for 100 mixed inputs (unfinished log)")
	var r: Dictionary = PathModel.states(flags([]), 4, -1)
	ok(r.has("states") and r.has("current") and r.has("finished") and r.has("done_count") and r.size() == 4, "result has exactly the keys states / current / finished / done_count")

	# the checker itself must be able to fail
	var good: String = compare(flags([]), 0, -1, 2, {"current": 0, "state": {3: "locked"}})
	var wrong_state: String = compare(flags([]), 0, -1, 2, {"current": 0, "state": {3: "open"}})
	var wrong_current: String = compare(flags([]), 0, -1, 2, {"current": 1})
	var wrong_finished: String = compare(flags([]), 0, -1, 2, {"current": 0, "finished": true})
	var wrong_range: String = compare(flags([]), 0, -1, 2, {"current": 0, "range": [[3, 5, "open"]]})
	ok(good == "", "selfcheck: the right expectation is accepted")
	for pair in [["state", wrong_state], ["current", wrong_current], ["finished", wrong_finished], ["range", wrong_range]]:
		print("  selfcheck %s wrong %s expectation -> %s" % ["FAIL-as-expected" if pair[1] != "" else "MISSED-BUG(!)", pair[0], pair[1]])
		ok(pair[1] != "", "selfcheck: a wrong %s expectation is reported as a failure" % pair[0])


func _test_done_flags_and_current() -> void:
	print("[done_flags / current_cell with the real log + checks]")
	StudyLog.today_override = Plan.days_from_civil(2026, 11, 1)
	Store.progress = Progress.blank()
	Store.progress["start"] = "2026-11-01"
	StudyLog.load_from_disk()

	var f0: Array = PathModel.done_flags("en")
	ok(f0.size() == 48 and not f0.has(true), "fresh state: 48 flags, all false")
	# T1a-10: a weekly check counts as done
	Store.set_checked(Store.check_key("en", 3, "w", 1), true) ## month 3, week index 1 = week 2 = cell 9
	var f1: Array = PathModel.done_flags("en")
	ok(f1[PathModel.index_of(3, 2)] == true and f1.count(true) == 1, "T1a-10: weekly check en-3-w1 -> done_flags('en')[index_of(3,2)] == true (only that one)")
	ok(PathModel.done_flags("ja").count(true) == 0, "...and the other language is untouched")
	Store.set_checked(Store.check_key("en", 3, "w", 1), false)
	ok(PathModel.done_flags("en").count(true) == 0, "check off again -> false")
	# lessons: 4 are not enough, 5 finish the cell
	for i in 4:
		StudyLog.add_path_lesson("en", 2, 3, 8, 10)
	ok(PathModel.done_flags("en")[PathModel.index_of(2, 3)] == false, "4 lessons in a cell: not done yet (NODE_GOAL 5)")
	StudyLog.add_path_lesson("en", 2, 3, 8, 10)
	ok(PathModel.done_flags("en")[PathModel.index_of(2, 3)] == true and PathModel.done_flags("ja")[PathModel.index_of(2, 3)] == false, "5 lessons -> done (only for that language)")
	# current_cell: the record decides (last = 2-3 which is done -> next unfinished = 2-4)
	var cc: Dictionary = PathModel.current_cell("en")
	ok(cc["n"] == 2 and cc["w"] == 4 and cc["i"] == 7 and cc["finished"] == false and cc["goal"] == 5 and cc["done"] == 0, "current_cell: last lesson cell 2-3 finished -> current 2-4 (i 7, done 0, goal 5) -> %s" % str(cc))
	StudyLog.add_path_lesson("en", 2, 4, 5, 10)
	cc = PathModel.current_cell("en")
	ok(cc["n"] == 2 and cc["w"] == 4 and cc["done"] == 1, "a lesson in 2-4 -> still current, done 1 -> %s" % str(cc))
	# the other language has no record: calendar position (today == start day -> cell 0)
	cc = PathModel.current_cell("ja")
	ok(cc["i"] == 0 and cc["n"] == 1 and cc["w"] == 1 and cc["done"] == 0, "language without record: calendar cell (start day = 1-1) -> %s" % str(cc))
	# calendar: 2027-01-20 = month 3 week 3 (cell 10)
	StudyLog.today_override = Plan.days_from_civil(2027, 1, 20)
	var pos: Dictionary = Plan.position(Store.start_iso(), StudyLog.today())
	cc = PathModel.current_cell("ja")
	ok(pos["n"] == 3 and pos["w"] == 3 and cc["i"] == 10 and cc["n"] == 3 and cc["w"] == 3, "no record, 2027-01-20 (3rd month, 3rd week) -> cell 10 = 3-3 -> %s" % str(cc))
	# before the start date -> cell 0; after the year -> cell 47
	StudyLog.today_override = Plan.days_from_civil(2026, 10, 1)
	ok(PathModel.current_cell("ja")["i"] == 0, "before the start date: cell 0")
	StudyLog.today_override = Plan.days_from_civil(2028, 3, 1)
	ok(PathModel.current_cell("ja")["i"] == 47, "after the year: the first unfinished cell from 47 = 47")
	Store.set_checked(Store.check_key("ja", 12, "w", 3), true)
	ok(PathModel.current_cell("ja")["i"] == 0, "after the year and cell 47 done (checked): wraps to the first unfinished cell 0")
	Store.set_checked(Store.check_key("ja", 12, "w", 3), false)
	# everything finished by weekly checks
	for n in range(1, 13):
		for w in range(0, 4):
			Store.progress["checks"][Store.check_key("ja", n, "w", w)] = true
	cc = PathModel.current_cell("ja")
	ok(cc["finished"] == true and cc["i"] == 47 and cc["n"] == 12 and cc["w"] == 4, "all 48 weekly checks -> finished, current cell 47 -> %s" % str(cc))
	ok(PathModel.states(PathModel.done_flags("ja"), 0, -1)["done_count"] == 48, "...and states() agrees: 48 done")
	# damaged log: a path record that is junk must not break current_cell
	StudyLog._path_data(true)["last"]["en"] = "99-9"
	ok(PathModel.current_cell("en")["i"] >= 0, "junk last-cell value in memory: current_cell still answers")


func _test_signals() -> void:
	print("[Store signals + AppView.open_target]")
	var ai_count := [0]
	var nav_calls: Array = []
	var cb_ai: Callable = func() -> void: ai_count[0] += 1
	var cb_nav: Callable = func(v: String, a: Dictionary) -> void: nav_calls.append([v, a])
	Store.ai_connect_requested.connect(cb_ai)
	Store.navigate_args.connect(cb_nav)
	Store.request_ai_connect()
	ok(ai_count[0] == 1, "T1a-11: Store.request_ai_connect() -> ai_connect_requested exactly once (%d)" % ai_count[0])
	Store.request_ai_connect()
	ok(ai_count[0] == 2, "...and once more per call")
	Store.navigate_args.emit("lesson", {})
	Store.navigate_args.emit("lesson", {"lang": "en", "n": 3, "w": 2, "start": true})
	ok(nav_calls.size() == 2 and nav_calls[0][0] == "lesson" and (nav_calls[0][1] as Dictionary).is_empty(), "T1a-11: navigate_args.emit('lesson', {}) is received")
	ok(nav_calls[1][1] == {"lang": "en", "n": 3, "w": 2, "start": true}, "the args dictionary arrives unchanged")
	Store.ai_connect_requested.disconnect(cb_ai)
	Store.navigate_args.disconnect(cb_nav)
	var old_nav_sig_ok: bool = Store.has_signal("navigate") and Store.has_signal("navigate_args") and Store.has_signal("ai_connect_requested")
	ok(old_nav_sig_ok, "the old navigate(view, lang) signal is still there")
	var v := AppView.new()
	ok(v.open_target({}) == false and v.open_target({"lang": "en", "n": 3}) == false, "AppView.open_target default does nothing and returns false")
	v.free()
