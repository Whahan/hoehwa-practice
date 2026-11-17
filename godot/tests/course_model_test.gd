extends Node
## CourseModel (v2.0 course: 72 weeks / 18 blocks, stages, ladder, minutes, road states, labels, stage_for). Pure tables.
## Design docs/v200_design.md §14 E1-4 .. E1-8, E1-10.
##   PC   : godot --headless --path <project> res://tests/course_model_test.tscn
##   Phone: godot --headless --path <project> --resolution 412x915 res://tests/course_model_test.tscn -- --phone --api=http://127.0.0.1:9
## Exit code 0 = all passed. Last line: "== course_model_test: N passed, M failed ==".
## Only the fake CourseStore scripts under user://test_course_model are written (and removed). The checks are also fed
## deliberately wrong expectations (lines "selfcheck FAIL-as-expected ...").

const TMP := "user://test_course_model"
const BAD := [null, "x", "", [], {}, true, NAN, INF, -INF, -1, 0, 73, 1.0e20, -1.0e20]

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved_path: String = ""


func _ready() -> void:
	print("== course_model_test start ==")
	_before = _user_listing()
	_saved_path = CourseModel.store_script_path
	_selfcheck()
	_constants()
	_addresses()
	_stages()
	_ladder_table()
	_minutes_and_days()
	_speak_plan()
	_states_table()
	_states_vs_path_model()
	_states_inputs()
	_progress_labels()
	_minute_labels()
	_bad_input()
	_stage_for()
	_source_scan()
	_cleanup()
	CourseModel.store_script_path = _saved_path
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_model_test: %d passed, %d failed ==" % [passed, failed])
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


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


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


func _cleanup() -> void:
	var da := DirAccess.open(TMP)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(TMP.path_join(f))
	DirAccess.remove_absolute(TMP)


## One letter per week: D done, C current, O open, P past, L locked.
func abbr(states: Array, n: int = 20) -> String:
	var s := ""
	for i in mini(n, states.size()):
		s += str(states[i]).substr(0, 1).to_upper() if states[i] != "past" else "P"
	return s


func has_long_number(s: String) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	return rx.search(s) != null


# ---------------------------------------------------------------- checks

func _selfcheck() -> void:
	var wrong_stage: bool = CourseModel.stage_of_week(4) == 1
	print("selfcheck %s stage_of_week(4) is not 1 (a table that expects 1 would fail)" % ("FAIL-as-expected" if not wrong_stage else "UNEXPECTED-PASS"))
	ok(not wrong_stage, "selfcheck: wrong stage expectation is false")
	var wrong_week: bool = CourseModel.week_of(19, 1) == 73
	print("selfcheck %s week_of(19, 1) is not 73" % ("FAIL-as-expected" if not wrong_week else "UNEXPECTED-PASS"))
	ok(not wrong_week, "selfcheck: block 19 does not exist")
	var wrong_sum: bool = int(CourseModel.unit_minutes(1, 1)["new"]) + 27 == 46
	print("selfcheck %s a minutes sum of 46 is not produced" % ("FAIL-as-expected" if not wrong_sum else "UNEXPECTED-PASS"))
	ok(not wrong_sum, "selfcheck: minutes do not sum to 46")
	var fake_label := "단어 12345/25개"
	print("selfcheck %s 5-digit scan on a fake label" % ("FAIL-as-expected" if has_long_number(fake_label) else "UNEXPECTED-PASS"))
	ok(has_long_number(fake_label), "selfcheck: the 5-digit scan flags a fake label")
	ok(not has_long_number(CourseModel.progress_label("words", 12, 25)), "the 5-digit scan accepts a real label")
	var fake_states: Array = []
	for i in 72:
		fake_states.append("locked")
	print("selfcheck %s all-locked road is not what states() gives for a fresh learner" % ("FAIL-as-expected" if CourseModel.states([], 1, 16)["states"] != fake_states else "UNEXPECTED-PASS"))
	ok(CourseModel.states([], 1, 16)["states"] != fake_states, "selfcheck: states() differs from an all-locked road")


func _constants() -> void:
	eq(CourseModel.WEEKS, 72, "WEEKS == 72")
	eq(CourseModel.BLOCKS, 18, "BLOCKS == 18")
	eq(CourseModel.DAYS, 7, "DAYS == 7")
	eq(CourseModel.WEEKS_PER_BLOCK, 4, "4 weeks per block")
	eq(CourseModel.BLOCKS * CourseModel.WEEKS_PER_BLOCK, CourseModel.WEEKS, "18 x 4 == 72")


func _addresses() -> void:
	var seen: Dictionary = {}
	var all_ok := true
	for n in range(1, 19):
		for k in range(1, 5):
			var w: int = CourseModel.week_of(n, k)
			if w != (n - 1) * 4 + k or CourseModel.block_of(w) != n or CourseModel.k_of(w) != k or seen.has(w):
				all_ok = false
			seen[w] = true
	ok(all_ok, "72 cells: week_of / block_of / k_of round trip, no duplicates")
	eq(seen.size(), 72, "72 distinct weeks")
	var back_ok := true
	for w in range(1, 73):
		if CourseModel.week_of(CourseModel.block_of(w), CourseModel.k_of(w)) != w:
			back_ok = false
	ok(back_ok, "week -> (block, k) -> week for 1..72")
	eq(CourseModel.week_of(1, 1), 1, "week_of(1,1) == 1")
	eq(CourseModel.week_of(1, 4), 4, "week_of(1,4) == 4")
	eq(CourseModel.week_of(2, 1), 5, "week_of(2,1) == 5")
	eq(CourseModel.week_of(18, 4), 72, "week_of(18,4) == 72")
	eq(CourseModel.block_of(1), 1, "block_of(1)")
	eq(CourseModel.block_of(4), 1, "block_of(4)")
	eq(CourseModel.block_of(5), 2, "block_of(5)")
	eq(CourseModel.block_of(72), 18, "block_of(72)")
	eq(CourseModel.k_of(72), 4, "k_of(72)")
	eq(CourseModel.k_of(5), 1, "k_of(5)")
	eq(CourseModel.order_of(5, 2), 52, "order_of(5,2) == 52 (design example)")
	eq(CourseModel.order_of(1, 1), 11, "order_of(1,1)")
	eq(CourseModel.order_of(72, 7), 727, "order_of(72,7)")
	var o_ok := true
	var last := 0
	for w in range(1, 73):
		for d in range(1, 8):
			var o: int = CourseModel.order_of(w, d)
			if o != w * 10 + d or o <= last:
				o_ok = false
			last = o
	ok(o_ok, "order_of(w,d) == w*10+d and strictly increasing over the 504 days")
	eq(CourseModel.week_of("2", "3"), 7, "integer strings are accepted")
	eq(CourseModel.week_of(2.0, 3.0), 7, "whole floats are accepted")
	eq(CourseModel.block_label(1), "0단계 입문", "block_label(1)")
	eq(CourseModel.block_label(2), "1개월차", "block_label(2)")
	eq(CourseModel.block_label(3), "2개월차", "block_label(3)")
	eq(CourseModel.block_label(18), "17개월차", "block_label(18)")
	eq(CourseModel.block_label(0), "", "block_label(0)")
	eq(CourseModel.block_label(19), "", "block_label(19)")
	var labels: Dictionary = {}
	for n in range(1, 19):
		labels[CourseModel.block_label(n)] = true
	eq(labels.size(), 18, "18 distinct block labels")


func _stages() -> void:
	var stage_rows := {1: 0, 4: 0, 5: 1, 16: 1, 17: 2, 32: 2, 33: 3, 48: 3, 49: 4, 60: 4, 61: 5, 68: 5, 69: 6, 72: 6}
	for w in stage_rows.keys():
		eq(CourseModel.stage_of_week(w), stage_rows[w], "stage_of_week(%d) == %d" % [w, stage_rows[w]])
	var legacy_rows := {1: 1, 16: 1, 17: 2, 36: 2, 37: 3, 56: 3, 57: 4, 72: 4}
	for w in legacy_rows.keys():
		eq(CourseModel.legacy_stage(w), legacy_rows[w], "legacy_stage(%d) == %d" % [w, legacy_rows[w]])
	var cell_rows := {1: [1, 1], 16: [1, 1], 17: [4, 1], 36: [4, 1], 37: [7, 1], 56: [7, 1], 57: [10, 1], 72: [10, 1]}
	for w in cell_rows.keys():
		eq(CourseModel.legacy_cell(w), cell_rows[w], "legacy_cell(%d) == %s" % [w, str(cell_rows[w])])
	# stage / legacy_stage never go down as the week goes up; stage 0..6 all used, legacy 1..4 all used
	var mono := true
	var stages_seen: Dictionary = {}
	var legacy_seen: Dictionary = {}
	for w in range(2, 73):
		if CourseModel.stage_of_week(w) < CourseModel.stage_of_week(w - 1) or CourseModel.legacy_stage(w) < CourseModel.legacy_stage(w - 1):
			mono = false
	for w in range(1, 73):
		stages_seen[CourseModel.stage_of_week(w)] = true
		legacy_seen[CourseModel.legacy_stage(w)] = true
	ok(mono, "stage_of_week and legacy_stage never decrease")
	eq(stages_seen.keys(), [0, 1, 2, 3, 4, 5, 6], "all 7 stages are reached")
	eq(legacy_seen.keys(), [1, 2, 3, 4], "all 4 legacy stages are reached")
	# the legacy cell is a real cell of the old 12 x 4 road
	var cell_ok := true
	for w in range(1, 73):
		var c: Array = CourseModel.legacy_cell(w)
		if c.size() != 2 or int(c[0]) < 1 or int(c[0]) > PathModel.MONTHS or int(c[1]) < 1 or int(c[1]) > PathModel.WEEKS:
			cell_ok = false
		if PathModel.index_of(int(c[0]), int(c[1])) < 0:
			cell_ok = false
	ok(cell_ok, "legacy_cell(w) is always a valid cell of PathModel")
	var legacy_via_plan := true
	for w in range(1, 73):
		var c2: Array = CourseModel.legacy_cell(w)
		if Plan.stage_of(int(c2[0])) != CourseModel.legacy_stage(w):
			legacy_via_plan = false
	ok(legacy_via_plan, "Plan.stage_of(legacy_cell month) == legacy_stage for every week")
	var titles := ["입문", "기초 문장", "생활 말하기", "도착·정착", "일 찾기", "일터 영어", "종합·출발"]
	for s in 7:
		eq(CourseModel.stage_title(s), titles[s], "stage_title(%d)" % s)
	eq(CourseModel.stage_title(7), "", "stage_title(7) == \"\"")
	eq(CourseModel.stage_title(-1), "", "stage_title(-1) == \"\"")


func _ladder_table() -> void:
	# week: [substitute, script, mission, free]  (repeat is always true)
	var rows := {
		1: [false, false, "none", "none"], 2: [true, false, "none", "none"], 7: [true, false, "none", "none"],
		8: [true, true, "none", "none"], 12: [true, true, "none", "none"], 13: [true, true, "script", "none"],
		16: [true, true, "script", "none"], 17: [true, true, "script", "guided"], 24: [true, true, "script", "guided"],
		25: [true, true, "ai", "guided"], 32: [true, true, "ai", "guided"], 33: [true, true, "ai", "free"],
		56: [true, true, "ai", "free"], 57: [true, true, "ai", "open"], 72: [true, true, "ai", "open"]}
	for w in rows.keys():
		var r: Array = rows[w]
		var lad: Dictionary = CourseModel.ladder(w)
		var want := {"repeat": true, "substitute": r[0], "script": r[1], "mission": r[2], "free": r[3]}
		eq(lad, want, "ladder(%d) == %s" % [w, str(want)])
	var keys_ok := true
	for w in range(1, 73):
		if CourseModel.ladder(w).keys().size() != 5:
			keys_ok = false
	ok(keys_ok, "ladder(w) has the 5 keys for every week")
	var fresh1: Dictionary = CourseModel.ladder(1)
	fresh1["repeat"] = false
	eq(CourseModel.ladder(1)["repeat"], true, "ladder() returns a fresh dictionary")


func _minutes_and_days() -> void:
	var sum_ok := true
	var keys_ok := true
	for w in range(1, 73):
		for d in range(1, 8):
			var m: Dictionary = CourseModel.unit_minutes(w, d)
			if int(m["new"]) + int(m["review"]) + int(m["listen"]) + int(m["speak"]) != 45:
				sum_ok = false
			if m.keys().size() != 4:
				keys_ok = false
	ok(sum_ok, "unit_minutes(w,d) adds up to 45 for all 504 days")
	ok(keys_ok, "unit_minutes has exactly new/review/listen/speak")
	eq(CourseModel.unit_minutes(1, 1), {"new": 18, "review": 5, "listen": 12, "speak": 10}, "S0 minutes")
	eq(CourseModel.unit_minutes(4, 3), {"new": 18, "review": 5, "listen": 12, "speak": 10}, "S0 minutes (week 4)")
	eq(CourseModel.unit_minutes(5, 1), {"new": 15, "review": 10, "listen": 8, "speak": 12}, "S1 minutes")
	eq(CourseModel.unit_minutes(32, 7), {"new": 15, "review": 10, "listen": 8, "speak": 12}, "S2 minutes")
	eq(CourseModel.unit_minutes(33, 1), {"new": 12, "review": 12, "listen": 8, "speak": 13}, "S3 minutes")
	eq(CourseModel.unit_minutes(60, 2), {"new": 12, "review": 12, "listen": 8, "speak": 13}, "S4 minutes")
	eq(CourseModel.unit_minutes(61, 1), {"new": 10, "review": 10, "listen": 10, "speak": 15}, "S5 minutes")
	eq(CourseModel.unit_minutes(72, 6), {"new": 10, "review": 10, "listen": 10, "speak": 15}, "S6 minutes")
	var m1: Dictionary = CourseModel.unit_minutes(1, 1)
	m1["new"] = 99
	eq(int(CourseModel.unit_minutes(1, 1)["new"]), 18, "unit_minutes() returns a copy (editing it changes nothing)")
	var kinds := ["new", "new", "new", "new", "speak", "check", "free"]
	for d in range(1, 8):
		eq(CourseModel.day_kind(5, d), kinds[d - 1], "day_kind(5,%d) == %s" % [d, kinds[d - 1]])
	var kind_ok := true
	for w in range(1, 73):
		for d in range(1, 8):
			if CourseModel.day_kind(w, d) != kinds[d - 1]:
				kind_ok = false
	ok(kind_ok, "day_kind follows D1-4 new, D5 speak, D6 check, D7 free in every week")


func _speak_plan() -> void:
	var sum_ok := true
	var rung_ok := true
	for w in range(1, 73):
		for d in range(1, 8):
			var plan: Array = CourseModel.speak_plan(w, d)
			var total := 0
			for it in plan:
				total += int(it["min"])
				if int(it["min"]) <= 0:
					rung_ok = false
			if plan.is_empty() or total != int(CourseModel.unit_minutes(w, d)["speak"]):
				sum_ok = false
	ok(sum_ok, "speak_plan minutes add up to unit_minutes().speak for all 504 days")
	ok(rung_ok, "every speak_plan item has minutes > 0")
	eq(CourseModel.speak_plan(1, 1), [{"rung": "L1", "min": 10}], "week 1 D1: repeat only")
	eq(CourseModel.speak_plan(2, 2), [{"rung": "L1", "min": 5}, {"rung": "L2", "min": 5}], "week 2 D2: L1 5 + L2 5 (S0 speak 10)")
	eq(CourseModel.speak_plan(5, 3), [{"rung": "L1", "min": 5}, {"rung": "L2", "min": 7}], "week 5 D3: L1 5 + L2 7")
	eq(CourseModel.speak_plan(5, 4), [{"rung": "L1", "min": 5}, {"rung": "L2", "min": 7}], "week 5 D4: script not open yet, like D1")
	eq(CourseModel.speak_plan(8, 4), [{"rung": "L3", "min": 12}], "week 8 D4: script dialogue")
	eq(CourseModel.speak_plan(8, 5), [{"rung": "L3", "min": 12}], "week 8 D5: nothing newer is open -> script again")
	eq(CourseModel.speak_plan(5, 5), [{"rung": "L1", "min": 5}, {"rung": "L2", "min": 7}], "week 5 D5: no script, no mission -> basic")
	eq(CourseModel.speak_plan(13, 5), [{"rung": "L4", "min": 12}], "week 13 D5: mission only")
	eq(CourseModel.speak_plan(17, 5), [{"rung": "L4", "min": 6}, {"rung": "L5", "min": 6}], "week 17 D5: mission + guided talk")
	eq(CourseModel.speak_plan(33, 5), [{"rung": "L4", "min": 7}, {"rung": "L5", "min": 6}], "week 33 D5: 13 minutes split 7 + 6")
	eq(CourseModel.speak_plan(9, 6), [{"rung": "check", "min": 12}], "week 9 D6: check speaking")
	eq(CourseModel.speak_plan(9, 7), [{"rung": "choice", "min": 12}], "week 9 D7: learner's choice")
	eq(CourseModel.speak_plan(61, 7), [{"rung": "choice", "min": 15}], "week 61 D7: 15 minutes")
	eq(CourseModel.speak_plan(0, 1), [], "speak_plan(0,1) == []")
	eq(CourseModel.speak_plan(1, 8), [], "speak_plan(1,8) == []")


# ---------------------------------------------------------------- the road

func _states_table() -> void:
	var r: Dictionary
	r = CourseModel.states([], 1, 16)
	eq(abbr(r["states"]), "COOLLLLLLLLLLLLLLLLL", "fresh start, avail 16")
	eq(r["current"], 0, "fresh start: current index 0")
	eq(r["done_count"], 0, "fresh start: nothing done")
	eq(r["finished"], false, "fresh start: not finished")
	eq(r["states"].size(), 72, "72 states")
	var done3: Array = [true, true, true]
	r = CourseModel.states(done3, 4, 16)
	eq(abbr(r["states"]), "DDDCOOLLLLLLLLLLLLLL", "3 done, current week 4")
	eq(r["current"], 3, "3 done: current index 3")
	eq(r["done_count"], 3, "3 done: done_count 3")
	r = CourseModel.states([], 5, 16)
	eq(abbr(r["states"]), "PPPPCOOLLLLLLLLLLLLL", "skipped ahead to week 5: weeks 1-4 are past")
	eq(r["current"], 4, "skipped ahead: current index 4")
	r = CourseModel.states([true, true, true, false, false], 2, 16)
	eq(abbr(r["states"]), "DDDCOOLLLLLLLLLLLLLL", "cur_w points to a done week: the next unfinished one is current")
	eq(r["current"], 3, "cur_w done: current index 3")
	r = CourseModel.states([false, true, true, true], 3, 4)
	eq(r["current"], 0, "avail 4, cur_w done and nothing after it: wraps to the first unfinished")
	eq(abbr(r["states"], 6), "CDDDLL", "avail 4: wrap states")
	var all16: Array = []
	for i in 16:
		all16.append(true)
	r = CourseModel.states(all16, 16, 16)
	eq(abbr(r["states"], 18), "DDDDDDDDDDDDDDDDLL", "all 16 available weeks done: D then locked")
	eq(r["current"], 15, "all available done: current is the last available week")
	eq(r["avail_done"], true, "all available done: avail_done")
	eq(r["finished"], false, "all available done but 56 weeks to come: not finished")
	eq(r["done_count"], 16, "16 done")
	var all72: Array = []
	for i in 72:
		all72.append(true)
	r = CourseModel.states(all72, 72, 72)
	eq(r["finished"], true, "all 72 done: finished")
	eq(r["done_count"], 72, "all 72 done: done_count 72")
	eq(r["current"], 71, "all 72 done: current 71")
	eq(r["states"].count("done"), 72, "all 72 done: every state is done")
	r = CourseModel.states(all72, 72, 16)
	eq(r["finished"], false, "72 flags but avail 16: not finished")
	eq(r["done_count"], 16, "72 flags but avail 16: only the 16 available count")
	eq(r["states"][20], "locked", "a done flag after avail stays locked")
	r = CourseModel.states([], 1, 0)
	eq(r["current"], -1, "avail 0: no current week")
	eq(r["states"].count("locked"), 72, "avail 0: all locked")
	eq(r["avail_done"], false, "avail 0: not avail_done")
	r = CourseModel.states([], 30, 16)
	eq(r["current"], 0, "cur_w 30 beyond avail 16: first unfinished")
	r = CourseModel.states([], 1, 16, 0)
	eq(abbr(r["states"], 6), "CLLLLL", "look 0: nothing is open")
	r = CourseModel.states([], 1, 16, 5)
	eq(abbr(r["states"], 9), "COOOOOLLL", "look 5")
	r = CourseModel.states([], 1, 3, 5)
	eq(abbr(r["states"], 6), "COOLLL", "look 5 but avail 3: open stops at avail")
	r = CourseModel.states([], 1, 16, -4)
	eq(abbr(r["states"], 4), "CLLL", "negative look counts as 0")
	r = CourseModel.states([], 1, 16, "x")
	eq(abbr(r["states"], 5), "COOLL", "look \"x\" falls back to the default 2")
	r = CourseModel.states([], 1, 16)
	eq(r["soon"].size(), 72, "soon has 72 entries")
	eq(r["soon"][15], false, "soon[15] false (week 16 has content)")
	eq(r["soon"][16], true, "soon[16] true (week 17 not yet)")
	eq(r["avail"], 16, "avail echoed")
	var every_week_ok := true
	for w in range(1, 17):
		var rr: Dictionary = CourseModel.states([], w, 16)
		if rr["current"] != w - 1 or rr["states"][w - 1] != "current":
			every_week_ok = false
	ok(every_week_ok, "for each week 1..16 as cur_w on a fresh road, that week is current")
	# every state value is one of the five; exactly one current when something is unfinished
	r = CourseModel.states([true, false, true], 2, 16)
	ok(r["states"].count("current") == 1, "exactly one current")
	var allowed := true
	for s in r["states"]:
		if not (s in ["done", "current", "open", "past", "locked"]):
			allowed = false
	ok(allowed, "only done/current/open/past/locked appear")


## Same rule as PathModel.states: compare 48-cell results for 300 seeded random cases.
func _states_vs_path_model() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261117
	var same_states := 0
	var same_current := 0
	var same_count := 0
	var cases := 300
	for c in cases:
		var done: Array = []
		for i in 48:
			done.append(rng.randf() < (0.15 + 0.7 * float(c % 10) / 10.0))
		var last_idx: int = rng.randi_range(-1, 47)
		var look: int = rng.randi_range(0, 4)
		var pm: Dictionary = PathModel.states(done, 0, last_idx, look)
		var cm: Dictionary = CourseModel.states(done, last_idx + 1 if last_idx >= 0 else "none", 48, look)
		var head: Array = (cm["states"] as Array).slice(0, 48)
		if head == pm["states"]:
			same_states += 1
		if cm["current"] == pm["current"]:
			same_current += 1
		if cm["done_count"] == pm["done_count"]:
			same_count += 1
	eq(same_states, cases, "states match PathModel.states in all %d seeded cases (first 48 cells)" % cases)
	eq(same_current, cases, "current matches PathModel in all %d cases" % cases)
	eq(same_count, cases, "done_count matches PathModel in all %d cases" % cases)
	# the comparison can fail: a PathModel call with a different lookahead differs from CourseModel's
	var differs := 0
	for c in 20:
		var done2: Array = []
		for i in 48:
			done2.append(rng.randf() < 0.3)
		var pm2: Dictionary = PathModel.states(done2, 0, -1, 4)
		var cm2: Dictionary = CourseModel.states(done2, "none", 48, 1)
		if (cm2["states"] as Array).slice(0, 48) != pm2["states"]:
			differs += 1
	print("selfcheck %s mismatched lookahead is detected in %d of 20 cases" % ["FAIL-as-expected" if differs > 0 else "UNEXPECTED-PASS", differs])
	ok(differs > 0, "selfcheck: the PathModel comparison notices a different lookahead")


func _states_inputs() -> void:
	for bad_done in [null, "x", {}, 5, true]:
		var r: Dictionary = CourseModel.states(bad_done, 1, 16)
		eq(r["done_count"], 0, "done=%s: nothing done" % str(bad_done))
		eq(r["states"].size(), 72, "done=%s: still 72 states" % str(bad_done))
	var mixed: Array = [1, 0, true, false, null, "x", 1.0, 2.5]
	var rm: Dictionary = CourseModel.states(mixed, 1, 16)
	eq(rm["done_count"], 4, "mixed flags: 1, true, 1.0, 2.5 count as done")
	var long: Array = []
	for i in 100:
		long.append(true)
	var rl: Dictionary = CourseModel.states(long, 1, 72)
	eq(rl["done_count"], 72, "a flag list longer than 72 is cut")
	eq(rl["finished"], true, "100 flags, avail 72: finished")
	var avail_cases := {"16": 16, 16.0: 16, 16.9: 16, 100: 72, -3: 0, "x": 0, null: 0}
	for k in avail_cases.keys():
		eq(CourseModel.states([], 1, k)["avail"], avail_cases[k], "avail %s -> %d" % [str(k), avail_cases[k]])
	for bad_cw in [null, "x", 0, 73, -3, [], {}, NAN]:
		eq(CourseModel.states([true], bad_cw, 16)["current"], 1, "cur_w=%s is ignored (first unfinished = 1)" % str(bad_cw))


# ---------------------------------------------------------------- labels

func _progress_labels() -> void:
	eq(CourseModel.progress_label("words", 12, 25), "단어 12/25개", "words 12/25")
	eq(CourseModel.progress_label("patterns", 3, 5), "문형 3/5개", "patterns")
	eq(CourseModel.progress_label("sentences", 8, 40), "문장 8/40개", "sentences")
	eq(CourseModel.progress_label("questions", 10, 12), "문제 10/12개", "questions")
	eq(CourseModel.progress_label("cards", 15, 20), "카드 15/20장", "cards")
	eq(CourseModel.progress_label("days", 3, 7), "3/7일", "days")
	eq(CourseModel.progress_label("weeks", 5, 72), "5/72주", "weeks")
	eq(CourseModel.progress_label("minutes", 20, 45), "20/45분", "minutes")
	eq(CourseModel.progress_label("blocks", 2, 4), "블록 2/4개", "blocks")
	eq(CourseModel.progress_label("percent", 80, 100), "80%", "percent")
	eq(CourseModel.progress_label("percent", 250, 0), "100%", "percent is capped at 100")
	eq(CourseModel.progress_label("zzz", 3, 5), "3/5", "unknown kind: plain 3/5")
	eq(CourseModel.progress_label(null, 3, 5), "3/5", "kind null: plain 3/5")
	eq(CourseModel.progress_label("words", 30, 25), "단어 25/25개", "value above target is shown as the target")
	eq(CourseModel.progress_label("words", -4, 25), "단어 0/25개", "negative value is 0")
	eq(CourseModel.progress_label("words", 5, 0), "단어 5/0개", "target 0: value kept")
	eq(CourseModel.progress_label("words", "7", "9"), "단어 7/9개", "integer strings accepted")
	eq(CourseModel.progress_label("words", null, null), "단어 0/0개", "null counts are 0")
	eq(CourseModel.progress_label("words", 999999, 999999), "단어 9999/9999개", "999999 is shown as 9999")
	var long_ok := true
	var inputs := [0, 1, 99, 9999, 10000, 12345, 999999, 1234567890, 1.0e12, -1.0e12, INF, NAN, "99999", "x", null]
	for kind in ["words", "patterns", "sentences", "questions", "cards", "days", "weeks", "minutes", "blocks", "percent", "zzz"]:
		for v in inputs:
			for t in inputs:
				if has_long_number(CourseModel.progress_label(kind, v, t)):
					long_ok = false
	ok(long_ok, "no progress_label contains a 5-digit number, for 11 kinds x 15 x 15 inputs")


func _minute_labels() -> void:
	eq(CourseModel.fmt_minutes(123456), "34시간 17분", "fmt_minutes(123456)")
	eq(CourseModel.fmt_minutes(59), "1분 미만", "fmt_minutes(59)")
	eq(CourseModel.fmt_minutes(1), "1분 미만", "fmt_minutes(1)")
	eq(CourseModel.fmt_minutes(0), "0분", "fmt_minutes(0)")
	eq(CourseModel.fmt_minutes(60), "1분", "fmt_minutes(60)")
	eq(CourseModel.fmt_minutes(119), "1분", "fmt_minutes(119)")
	eq(CourseModel.fmt_minutes(2700), "45분", "fmt_minutes(2700) == 45분")
	eq(CourseModel.fmt_minutes(3599), "59분", "fmt_minutes(3599)")
	eq(CourseModel.fmt_minutes(3600), "1시간", "fmt_minutes(3600)")
	eq(CourseModel.fmt_minutes(3660), "1시간 1분", "fmt_minutes(3660)")
	eq(CourseModel.fmt_minutes(5400), "1시간 30분", "fmt_minutes(5400)")
	eq(CourseModel.fmt_minutes(86400), "24시간", "fmt_minutes(86400)")
	eq(CourseModel.fmt_minutes(59.9), "1분 미만", "fmt_minutes(59.9)")
	eq(CourseModel.fmt_minutes(3600.0), "1시간", "fmt_minutes(3600.0)")
	eq(CourseModel.fmt_minutes(-5), "0분", "fmt_minutes(-5)")
	eq(CourseModel.fmt_minutes(null), "0분", "fmt_minutes(null)")
	eq(CourseModel.fmt_minutes("abc"), "0분", "fmt_minutes(\"abc\")")
	eq(CourseModel.fmt_minutes(NAN), "0분", "fmt_minutes(NAN)")
	eq(CourseModel.fmt_minutes(INF), "0분", "fmt_minutes(INF)")
	eq(CourseModel.fmt_minutes(36000000), "9999시간 59분", "fmt_minutes(10000 hours) is capped")
	var long_ok := true
	for v in [0, 1, 59, 60, 3599, 3600, 123456, 999999, 36000000, 99999999999, 1.0e18, -1, null, "x", NAN, INF]:
		if has_long_number(CourseModel.fmt_minutes(v)):
			long_ok = false
	ok(long_ok, "no fmt_minutes text contains a 5-digit number (seconds are never shown)")


# ---------------------------------------------------------------- bad input

func _bad_input() -> void:
	var all_nothing := true
	for b in BAD:
		var checks := [
			CourseModel.week_of(b, 1) == -1, CourseModel.week_of(1, b) == -1, CourseModel.block_of(b) == -1,
			CourseModel.k_of(b) == -1, CourseModel.order_of(b, 1) == -1, CourseModel.order_of(1, b) == -1,
			CourseModel.stage_of_week(b) == -1, CourseModel.legacy_stage(b) == -1, CourseModel.legacy_cell(b) == [],
			CourseModel.ladder(b) == {}, CourseModel.unit_minutes(b, 1) == {}, CourseModel.unit_minutes(1, b) == {},
			CourseModel.day_kind(b, 1) == "", CourseModel.day_kind(1, b) == "", CourseModel.speak_plan(b, 1) == [],
			CourseModel.speak_plan(1, b) == [], CourseModel.block_label(b) == ""]
		for i in checks.size():
			if not checks[i]:
				all_nothing = false
				print("  detail: input %s check #%d is not the 'nothing' value" % [str(b), i])
	ok(all_nothing, "14 bad inputs x 17 functions: always -1 / {} / [] / \"\" and never an error")
	var stage_ok := true
	for b in [null, "x", "", [], {}, true, NAN, INF, -INF, -1, 7, 73, 1.0e20, -1.0e20]:
		if CourseModel.stage_title(b) != "":
			stage_ok = false
	ok(stage_ok, "stage_title(junk) == \"\" for 14 junk values")
	eq(CourseModel.week_of(0, 1), -1, "week_of(0,1) == -1")
	eq(CourseModel.week_of(19, 1), -1, "week_of(19,1) == -1")
	eq(CourseModel.week_of(1, 5), -1, "week_of(1,5) == -1")
	eq(CourseModel.week_of(1, 0), -1, "week_of(1,0) == -1")
	eq(CourseModel.block_of(0), -1, "block_of(0) == -1")
	eq(CourseModel.block_of(73), -1, "block_of(73) == -1")
	eq(CourseModel.stage_of_week(-5), -1, "stage_of_week(-5) == -1")
	eq(CourseModel.order_of("x", 1), -1, "order_of(\"x\", 1) == -1")
	eq(CourseModel.order_of(null, null), -1, "order_of(null, null) == -1")
	var frac: int = CourseModel.week_of(1.5, 2.5)
	ok(frac == 2, "fractional floats are cut (week_of(1.5, 2.5) == %d)" % frac)
	# progress / states never raise on junk either (reaching this line means no script error happened)
	ok(CourseModel.states(BAD, BAD[0], BAD[1], BAD[2]).has("states"), "states() with junk arguments still answers")
	ok(CourseModel.progress_label(BAD, BAD, BAD) is String, "progress_label() with junk arguments still answers")
	ok(CourseModel.fmt_minutes(BAD) is String, "fmt_minutes() with junk arguments still answers")


# ---------------------------------------------------------------- stage_for / pos_for

func _write_fake(name: String, body: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP)
	var p: String = TMP.path_join(name)
	write_text(p, "extends RefCounted\n" + body)
	return p


func _stage_for() -> void:
	var cal: Dictionary = Store.position()
	var cal_stage: int = Plan.stage_of(int(cal["n"]))
	# no CourseStore (E3 not merged) or a path that does not exist: the calendar, no error
	CourseModel.store_script_path = "res://scripts/core/course_store_does_not_exist.gd"
	eq(CourseModel.stage_for("en"), cal_stage, "stage_for(en) without CourseStore == Plan.stage_of(Store.position().n)")
	eq(CourseModel.stage_for("ja"), cal_stage, "stage_for(ja) == calendar stage")
	var pf: Dictionary = CourseModel.pos_for("en")
	eq(pf["stage"], cal_stage, "pos_for(en).stage without CourseStore")
	eq(pf["n"], int(cal["n"]), "pos_for(en).n == calendar month")
	eq(pf["w"], int(cal["w"]), "pos_for(en).w == calendar week")
	eq(pf["cw"], 0, "pos_for(en).cw == 0 without a course")
	eq(pf["cd"], 0, "pos_for(en).cd == 0 without a course")
	for bad_lang in [null, 5, "", "xx", [], {}]:
		eq(CourseModel.stage_for(bad_lang), cal_stage, "stage_for(%s) == calendar stage" % str(bad_lang))
	# a path that is not a script
	CourseModel.store_script_path = "res://tests/course_model_test.tscn"
	eq(CourseModel.stage_for("en"), cal_stage, "store path pointing at a scene: calendar stage")
	# fake CourseStore: course mode, week 20 day 3
	CourseModel.store_script_path = _write_fake("fake_course.gd", "static func mode() -> String:\n\treturn \"course\"\nstatic func pos() -> Dictionary:\n\treturn {\"w\": 20, \"d\": 3}\n")
	var pc: Dictionary = CourseModel.pos_for("en")
	eq(pc["stage"], 2, "course mode week 20: legacy stage 2")
	eq(pc["n"], 4, "course mode week 20: legacy month 4")
	eq(pc["w"], 1, "course mode week 20: legacy week 1")
	eq(pc["cw"], 20, "course mode: cw 20")
	eq(pc["cd"], 3, "course mode: cd 3")
	eq(CourseModel.stage_for("en"), 2, "stage_for(en) in course mode week 20 == 2")
	eq(CourseModel.stage_for("ja"), cal_stage, "stage_for(ja) in course mode is STILL the calendar stage")
	eq(CourseModel.pos_for("ja")["cw"], 0, "pos_for(ja) in course mode: cw 0")
	eq(CourseModel.pos_for("ja")["n"], int(cal["n"]), "pos_for(ja) in course mode: calendar month")
	# legacy mode
	CourseModel.store_script_path = _write_fake("fake_legacy.gd", "static func mode() -> String:\n\treturn \"legacy\"\nstatic func pos() -> Dictionary:\n\treturn {\"w\": 20, \"d\": 3}\n")
	eq(CourseModel.stage_for("en"), cal_stage, "legacy mode: calendar stage")
	eq(CourseModel.pos_for("en")["cw"], 0, "legacy mode: cw 0")
	# course mode with a position outside 1..72 / wrong shape
	var bi := 0
	for body in ["{\"w\": 99, \"d\": 1}", "{\"w\": 0}", "{}", "{\"w\": \"x\"}", "{\"w\": null}"]:
		bi += 1
		CourseModel.store_script_path = _write_fake("fake_badpos%d.gd" % bi, "static func mode() -> String:\n\treturn \"course\"\nstatic func pos() -> Dictionary:\n\treturn " + body + "\n")
		eq(CourseModel.stage_for("en"), cal_stage, "course mode with pos %s: calendar stage" % body)
	# a position without d: day defaults to 1
	CourseModel.store_script_path = _write_fake("fake_nod.gd", "static func mode() -> String:\n\treturn \"course\"\nstatic func pos() -> Dictionary:\n\treturn {\"w\": 70}\n")
	eq(CourseModel.pos_for("en")["cd"], 1, "pos without d: cd 1")
	eq(CourseModel.stage_for("en"), 4, "week 70: legacy stage 4")
	# a script that lacks the functions
	CourseModel.store_script_path = _write_fake("fake_empty.gd", "static func other() -> int:\n\treturn 1\n")
	eq(CourseModel.stage_for("en"), cal_stage, "script without mode()/pos(): calendar stage")
	# mode() that returns something else than "course"
	CourseModel.store_script_path = _write_fake("fake_weird.gd", "static func mode() -> int:\n\treturn 7\nstatic func pos() -> int:\n\treturn 3\n")
	eq(CourseModel.stage_for("en"), cal_stage, "mode() returning a number: calendar stage")
	# the check can fail: with the real course fake the stage is NOT the calendar stage (unless they coincide)
	CourseModel.store_script_path = _write_fake("fake_course2.gd", "static func mode() -> String:\n\treturn \"course\"\nstatic func pos() -> Dictionary:\n\treturn {\"w\": 72, \"d\": 7}\n")
	var late: int = CourseModel.stage_for("en")
	eq(late, 4, "course mode week 72: stage 4")
	var differs: bool = late != cal_stage
	print("selfcheck %s course-mode stage (4) is told apart from the calendar stage (%d)" % ["FAIL-as-expected" if differs else "SAME-VALUE-CASE", cal_stage])
	CourseModel.store_script_path = _saved_path


func _source_scan() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/core/course_model.gd")
	var bad: Array = []
	for w in ["FileAccess", "DirAccess", "HTTP" + "Request", "shell" + "_open", "OS" + ".", "Time" + ".", "rand" + "i", "rand" + "f", "add_" + "child",
			"Control" + ".new", "CourseStore" + ".", "StudyLog", "87" + "70", "87" + "75", "87" + "76"]:
		if src.contains(w):
			bad.append(w)
	ok(bad.is_empty(), "course_model.gd: no file, clock, random, node or hard CourseStore reference %s" % str(bad))
	var fake: String = "func x(): return FileAccess.open(\"a\", 1)"
	var fake_bad := fake.contains("FileAccess")
	print("selfcheck %s forbidden-word scan on a fake source" % ("FAIL-as-expected" if fake_bad else "UNEXPECTED-PASS"))
	ok(fake_bad, "selfcheck: the forbidden-word scan flags a fake source")
	var colors: bool = src.contains("Color(" + "\"#")
	ok(not colors, "course_model.gd has no hex Color literal")
	var prog: bool = src.contains("%d" + "/%d")
	ok(not prog, "course_model.gd builds no own value/target progress text")
