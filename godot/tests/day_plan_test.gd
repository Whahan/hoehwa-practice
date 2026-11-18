extends Node
## DayPlan: today's 45 minutes as a pure function (v2.0 E3, docs/v200_design.md §6.1, §6.2, §14 E3-4, E3-5, E3-9).
##   PC   : godot --headless --path <project>/godot res://tests/day_plan_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/day_plan_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== day_plan_test: N passed, M failed ==".
## No files are read or written. The rule table is also fed deliberately wrong expectations ("selfcheck FAIL-as-expected ...").
## Mutation check (E3-9): DayPlan.REVIEW_ON 40 -> 400 must make the table FAIL.

const BAD := [null, "x", "", [], {}, true, NAN, INF, -INF, -1, -1.5, 0, 1.0e20, -1.0e20, "7", "7.5", "-3"]

var passed: int = 0
var failed: int = 0
var table_rows: int = 0


func _ready() -> void:
	print("== day_plan_test start ==")
	_selfcheck()
	_constants()
	_minutes_by_stage()
	_day_kinds()
	_review_priority_table()
	_hysteresis_table()
	_streak_table()
	_away_table()
	_no_cards()
	_check_pending()
	_late_weeks()
	_expected_week()
	_blocks_state()
	_texts()
	_finished()
	_legacy()
	_sums_grid()
	_purity()
	_bad_input()
	_source_scan()
	print("rule table rows: %d" % table_rows)
	print("== day_plan_test: %d passed, %d failed ==" % [passed, failed])
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


## A normal course snapshot (week 5 day 2, 10 cards due, nothing special); `over` replaces keys.
func snap(over: Dictionary = {}) -> Dictionary:
	var s: Dictionary = {"mode": "course", "w": 5, "d": 2, "due": 10, "away_days": 0, "blocks_done": {}, "check_pending": false,
		"check_pending_days": 0, "rp_prev": false, "rp_streak": 0, "elapsed_days": 0, "finished": false}
	s.merge(over, true)
	return s


func mins_of(plan: Dictionary) -> String:
	var parts: Array = []
	for b in plan["blocks"]:
		parts.append(str(b["min"]))
	return "/".join(parts)


func has_long_number(s: String) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	return rx.search(s) != null


func all_strings(v: Variant, out: Array) -> void:
	if v is String:
		out.append(v)
	elif v is Dictionary:
		for k in v.keys():
			all_strings(k, out)
			all_strings(v[k], out)
	elif v is Array:
		for x in v:
			all_strings(x, out)


## One table row: expect holds any of mins / kind / rp / recap / reopen / late / ask / half.
func row(name: String, over: Dictionary, expect: Dictionary) -> void:
	table_rows += 1
	var p: Dictionary = DayPlan.today(snap(over))
	var bad: Array = []
	if expect.has("mins") and mins_of(p) != expect["mins"]:
		bad.append("mins %s want %s" % [mins_of(p), expect["mins"]])
	if expect.has("kind") and p["kind"] != expect["kind"]:
		bad.append("kind %s want %s" % [p["kind"], expect["kind"]])
	if expect.has("rp") and p["review_priority"] != expect["rp"]:
		bad.append("rp %s want %s" % [str(p["review_priority"]), str(expect["rp"])])
	if expect.has("recap") and p["recap"] != expect["recap"]:
		bad.append("recap %s want %s" % [str(p["recap"]), str(expect["recap"])])
	if expect.has("reopen") and p["reopen"] != expect["reopen"]:
		bad.append("reopen %s want %s" % [str(p["reopen"]), str(expect["reopen"])])
	if expect.has("late") and p["late_weeks"] != expect["late"]:
		bad.append("late %s want %s" % [str(p["late_weeks"]), str(expect["late"])])
	if expect.has("ask") and p["ask_check"] != expect["ask"]:
		bad.append("ask %s want %s" % [str(p["ask_check"]), str(expect["ask"])])
	if expect.has("half") and p["blocks"][0]["half"] != expect["half"]:
		bad.append("half %s want %s" % [str(p["blocks"][0]["half"]), str(expect["half"])])
	if p["total_min"] != 45 or p["blocks"].size() != 4:
		bad.append("total %s blocks %d" % [str(p["total_min"]), p["blocks"].size()])
	ok(bad.is_empty(), "row: %s %s" % [name, "" if bad.is_empty() else str(bad)])


# ---------------------------------------------------------------- checks

func _selfcheck() -> void:
	var p: Dictionary = DayPlan.today(snap({"due": 39}))
	var wrong_rp: bool = p["review_priority"] == true
	print("selfcheck %s 39 due cards are not review-first (a row that expects review-first would fail)" % ("FAIL-as-expected" if not wrong_rp else "UNEXPECTED-PASS"))
	ok(not wrong_rp, "selfcheck: 39 due is not review-first")
	var p2: Dictionary = DayPlan.today(snap({"away_days": 6}))
	var wrong_recap: bool = p2["recap"] == true
	print("selfcheck %s away 6 is not a recap day" % ("FAIL-as-expected" if not wrong_recap else "UNEXPECTED-PASS"))
	ok(not wrong_recap, "selfcheck: away_days 6 is not recap")
	var wrong_sum: bool = DayPlan.today(snap())["total_min"] == 46
	print("selfcheck %s the plan does not add up to 46" % ("FAIL-as-expected" if not wrong_sum else "UNEXPECTED-PASS"))
	ok(not wrong_sum, "selfcheck: total is 45, not 46")
	var wrong_mins: bool = mins_of(DayPlan.today(snap({"due": 40}))) == "15/10/8/12"
	print("selfcheck %s a review-first day does not keep the normal minutes" % ("FAIL-as-expected" if not wrong_mins else "UNEXPECTED-PASS"))
	ok(not wrong_mins, "selfcheck: review-first minutes differ from normal minutes")
	var strings: Array = []
	all_strings({"sub": "카드 12345장"}, strings)
	var flagged := false
	for s in strings:
		flagged = flagged or has_long_number(s)
	print("selfcheck %s the 5-digit scan flags a fake label" % ("FAIL-as-expected" if flagged else "UNEXPECTED-PASS"))
	ok(flagged, "selfcheck: the 5-digit scan flags 12345")
	ok(not has_long_number("카드 15장"), "the 5-digit scan accepts a real label")


func _constants() -> void:
	eq(DayPlan.REVIEW_ON, 40, "REVIEW_ON == 40")
	eq(DayPlan.REVIEW_OFF, 25, "REVIEW_OFF == 25")
	eq(DayPlan.MAX_STREAK, 3, "MAX_STREAK == 3")
	eq(DayPlan.RECAP_AWAY, 7, "RECAP_AWAY == 7")
	eq(DayPlan.REOPEN_AWAY, 21, "REOPEN_AWAY == 21")
	eq(DayPlan.BLOCK_IDS, ["new", "review", "listen", "speak"], "four block ids in order")


func _minutes_by_stage() -> void:
	# (week, day) -> "new/review/listen/speak" by §6.1, written out here (not read from CourseModel)
	var s0 := "18/5/12/10"
	var s12 := "15/10/8/12"
	var s34 := "12/12/8/13"
	var s56 := "10/10/10/15"
	for pair in [[1, 1, s0], [4, 4, s0], [4, 7, s0], [5, 1, s12], [16, 3, s12], [17, 4, s12], [32, 4, s12], [33, 1, s34], [48, 2, s34],
			[49, 1, s34], [60, 6, s34], [61, 1, s56], [68, 5, s56], [69, 1, s56], [72, 7, s56]]:
		row("minutes week %d day %d" % [pair[0], pair[1]], {"w": pair[0], "d": pair[1]}, {"mins": pair[2], "rp": false, "recap": false})


func _day_kinds() -> void:
	var kinds := ["new", "new", "new", "new", "speak", "check", "free"]
	for d in range(1, 8):
		row("day kind d%d" % d, {"w": 6, "d": d}, {"kind": kinds[d - 1]})
	var titles := ["새 내용", "새 내용", "새 내용", "새 내용", "말하기 날", "주간 점검", "자유 시간"]
	for d in range(1, 8):
		eq(DayPlan.today(snap({"w": 6, "d": d}))["blocks"][0]["title"], titles[d - 1], "new block title of day %d" % d)
	var p: Dictionary = DayPlan.today(snap({"w": 6, "d": 6}))
	eq(p["blocks"][0]["sub"], CourseModel.progress_label("questions", 12, 0), "check day: sub is the shared progress label (12 questions)")
	eq(p["w"], 6, "plan echoes w")
	eq(p["d"], 6, "plan echoes d")


func _review_priority_table() -> void:
	row("due 0", {"due": 0}, {"mins": "15/0/18/12", "rp": false})
	row("due 1", {"due": 1}, {"mins": "15/10/8/12", "rp": false})
	row("due 25", {"due": 25}, {"mins": "15/10/8/12", "rp": false})
	row("due 38", {"due": 38}, {"mins": "15/10/8/12", "rp": false})
	row("due 39 is normal", {"due": 39}, {"mins": "15/10/8/12", "rp": false, "half": false})
	row("due 40 is review first", {"due": 40}, {"mins": "15/20/5/5", "rp": true, "half": true})
	row("due 41", {"due": 41}, {"mins": "15/20/5/5", "rp": true})
	row("due 500", {"due": 500}, {"mins": "15/20/5/5", "rp": true})
	row("due 999999", {"due": 999999}, {"mins": "15/20/5/5", "rp": true})
	row("review first in stage 0", {"w": 2, "d": 1, "due": 60}, {"mins": "15/20/5/5", "rp": true})
	row("review first in stage 6", {"w": 70, "d": 3, "due": 60}, {"mins": "15/20/5/5", "rp": true})
	row("review first on a check day", {"w": 5, "d": 6, "due": 60}, {"mins": "15/20/5/5", "rp": true, "kind": "check"})
	row("review first on a free day", {"w": 5, "d": 7, "due": 60}, {"mins": "15/20/5/5", "rp": true, "kind": "free"})
	var p: Dictionary = DayPlan.today(snap({"due": 40}))
	eq(p["blocks"][0]["sub"], "5주 2일 · " + CourseModel.progress_label("words", 3, 0) + "까지", "review first: the new block says words up to 3")
	ok(p["review_priority"] and not p["recap"], "review first: flags")
	eq(p["blocks"][1]["target"], 15, "review first: review target is capped at 15 cards")


func _hysteresis_table() -> void:
	row("prev on, due 26 stays on", {"rp_prev": true, "due": 26}, {"rp": true, "mins": "15/20/5/5"})
	row("prev on, due 25 releases", {"rp_prev": true, "due": 25}, {"rp": false, "mins": "15/10/8/12"})
	row("prev on, due 24 releases", {"rp_prev": true, "due": 24}, {"rp": false})
	row("prev on, due 39 stays on", {"rp_prev": true, "due": 39}, {"rp": true})
	row("prev on, due 40 stays on", {"rp_prev": true, "due": 40}, {"rp": true})
	row("prev on, due 100 stays on", {"rp_prev": true, "due": 100}, {"rp": true})
	row("prev on, due 0 releases", {"rp_prev": true, "due": 0}, {"rp": false, "mins": "15/0/18/12"})
	row("prev off, due 26 is normal", {"rp_prev": false, "due": 26}, {"rp": false})
	row("prev off, due 39 is normal", {"rp_prev": false, "due": 39}, {"rp": false})
	row("prev off, due 40 turns on", {"rp_prev": false, "due": 40}, {"rp": true})


func _streak_table() -> void:
	row("due 40, streak 0", {"due": 40, "rp_streak": 0}, {"rp": true})
	row("due 40, streak 1", {"due": 40, "rp_streak": 1, "rp_prev": true}, {"rp": true})
	row("due 40, streak 2: the 3rd day is still review first", {"due": 40, "rp_streak": 2, "rp_prev": true}, {"rp": true})
	row("due 40, streak 3: the 4th day is normal", {"due": 40, "rp_streak": 3, "rp_prev": true}, {"rp": false, "mins": "15/10/8/12", "half": false})
	row("due 400, streak 3: still normal on the 4th day", {"due": 400, "rp_streak": 3, "rp_prev": true}, {"rp": false})
	row("due 400, streak 9: normal", {"due": 400, "rp_streak": 9, "rp_prev": true}, {"rp": false})
	row("due 30 (kept on), streak 3: normal", {"due": 30, "rp_streak": 3, "rp_prev": true}, {"rp": false})
	row("due 30 (kept on), streak 2: on", {"due": 30, "rp_streak": 2, "rp_prev": true}, {"rp": true})
	row("after the normal day: streak 0, due 400: review first again", {"due": 400, "rp_streak": 0, "rp_prev": false}, {"rp": true})


func _away_table() -> void:
	row("away 0", {"away_days": 0}, {"recap": false, "kind": "new", "reopen": []})
	row("away 1", {"away_days": 1}, {"recap": false, "reopen": []})
	row("away 6 is normal", {"away_days": 6}, {"recap": false, "mins": "15/10/8/12", "kind": "new", "reopen": []})
	row("away 7 is a recap day", {"away_days": 7}, {"recap": true, "mins": "15/20/5/5", "kind": "recap", "reopen": []})
	row("away 8", {"away_days": 8}, {"recap": true, "kind": "recap", "reopen": []})
	row("away 20", {"away_days": 20}, {"recap": true, "reopen": []})
	row("away 21 reopens the 2 weeks before w=5", {"away_days": 21}, {"recap": true, "kind": "recap", "reopen": [3, 4]})
	row("away 30", {"away_days": 30}, {"recap": true, "reopen": [3, 4]})
	row("away 21 at w=2 reopens only week 1", {"away_days": 21, "w": 2}, {"recap": true, "reopen": [1]})
	row("away 21 at w=1 reopens nothing", {"away_days": 21, "w": 1}, {"recap": true, "reopen": []})
	row("away 21 at w=3 reopens 1 and 2", {"away_days": 21, "w": 3}, {"recap": true, "reopen": [1, 2]})
	row("away 7 beats review first (same minutes, rp false)", {"away_days": 7, "due": 100}, {"recap": true, "rp": false, "mins": "15/20/5/5"})
	row("away 7 with 0 cards: review minutes go to listening", {"away_days": 7, "due": 0}, {"recap": true, "mins": "15/0/25/5"})
	var p: Dictionary = DayPlan.today(snap({"away_days": 7}))
	eq(p["blocks"][0]["title"], "복귀 점검", "recap day: the new block is the recap check")
	eq(p["blocks"][0]["sub"], CourseModel.progress_label("questions", 6, 0), "recap day: sub is the shared label (6 questions)")
	eq(p["start_label"], "오늘 45분 시작", "recap day: start label")


func _no_cards() -> void:
	row("no cards, stage 0: review minutes go to listening", {"w": 1, "d": 1, "due": 0}, {"mins": "18/0/17/10"})
	row("no cards, stage 3", {"w": 40, "d": 2, "due": 0}, {"mins": "12/0/20/13"})
	row("no cards, stage 5", {"w": 64, "d": 2, "due": 0}, {"mins": "10/0/20/15"})
	var p: Dictionary = DayPlan.today(snap({"due": 0}))
	eq(p["blocks"][1]["state"], "skip", "no cards: the review block is skipped")
	eq(p["blocks"][1]["min"], 0, "no cards: review minutes 0")
	eq(p["blocks"][1]["target"], 0, "no cards: review target 0")
	eq(p["total_min"], 45, "no cards: the sum stays 45")
	eq(p["blocks"][2]["min"], 18, "no cards: listening gets 8 + 10 minutes")
	eq(p["blocks"][0]["state"], "current", "no cards: the first block is current")
	var done: Dictionary = DayPlan.today(snap({"due": 0, "blocks_done": {"new": true, "listen": true, "speak": true}}))
	eq(done["start_label"], "더 연습하기", "no cards, the other three done: nothing left")


func _check_pending() -> void:
	row("pending, 0 days", {"check_pending": true, "check_pending_days": 0}, {"ask": false})
	row("pending, 1 day", {"check_pending": true, "check_pending_days": 1}, {"ask": false})
	row("pending, 2 days: ask", {"check_pending": true, "check_pending_days": 2}, {"ask": true})
	row("pending, 5 days: ask", {"check_pending": true, "check_pending_days": 5}, {"ask": true})
	row("not pending, 9 days", {"check_pending": false, "check_pending_days": 9}, {"ask": false})
	row("pending, days missing", {"check_pending": true}, {"ask": false})
	eq(DayPlan.CHECK_ASK_DAYS, 2, "CHECK_ASK_DAYS == 2")


func _late_weeks() -> void:
	for t in [[1, 0, 0], [1, 6, 0], [1, 7, 1], [1, 13, 1], [1, 14, 2], [5, 28, 0], [3, 28, 2], [16, 105, 0], [16, 111, 0], [16, 112, 0],
			[16, 118, 0], [16, 119, 1], [32, 224, 0], [10, 0, 0], [72, 9999, 0], [20, 7 * 17, 0], [20, 7 * 19, 0], [20, 7 * 20, 0], [20, 7 * 21, 1]]:
		row("late weeks w%d elapsed %d" % [t[0], t[1]], {"w": t[0], "elapsed_days": t[1]}, {"late": t[2]})
	row("late weeks: 1 at day 7 even with review first", {"w": 1, "elapsed_days": 7, "due": 90}, {"late": 1, "rp": true})
	row("late weeks are shown on a recap day too", {"w": 1, "elapsed_days": 70, "away_days": 8}, {"late": 10, "recap": true})


func _expected_week() -> void:
	for t in [[0, 1], [6, 1], [7, 2], [48, 7], [49, 8], [105, 16], [111, 16], [112, 16], [118, 16], [119, 17], [7 * 31, 31], [7 * 32, 32],
			[7 * 33, 32], [7 * 34, 33], [7 * 76, 72], [7 * 77, 72], [99999, 72], [-5, 1], ["x", 1], [null, 1], [3.9, 1], ["14", 3]]:
		eq(DayPlan.expected_week(t[0]), t[1], "expected_week(%s) = %d" % [str(t[0]), t[1]])
	var prev := 0
	var monotonic := true
	for e in range(0, 700):
		var x: int = DayPlan.expected_week(e)
		if x < prev or x - prev > 1:
			monotonic = false
		prev = x
	ok(monotonic, "expected_week never goes back and moves one week at a time (0..699 days)")
	var spare := 0
	var last := 0
	for cal in range(1, 79):
		var x2: int = DayPlan.expected_week((cal - 1) * 7)
		if x2 == last:
			spare += 1
		last = x2
	eq(spare, 6, "6 spare weeks in the 78 calendar weeks (the expected week repeats 6 times)")


func _blocks_state() -> void:
	var p: Dictionary = DayPlan.today(snap())
	eq([p["blocks"][0]["state"], p["blocks"][1]["state"], p["blocks"][2]["state"], p["blocks"][3]["state"]], ["current", "todo", "todo", "todo"], "nothing done: first block current, rest todo")
	eq(p["done_min"], 0, "nothing done: done_min 0")
	eq(p["start_label"], "오늘 45분 시작", "nothing done: start label")
	var p1: Dictionary = DayPlan.today(snap({"blocks_done": {"new": true}}))
	eq([p1["blocks"][0]["state"], p1["blocks"][1]["state"], p1["blocks"][2]["state"]], ["done", "current", "todo"], "new done: review is current")
	eq(p1["done_min"], 15, "new done: done_min 15")
	var p2: Dictionary = DayPlan.today(snap({"blocks_done": {"new": true, "review": true, "listen": true, "speak": true}}))
	eq(p2["done_min"], 45, "all done: done_min 45")
	eq(p2["start_label"], "더 연습하기", "all done: start label 더 연습하기")
	eq(p2["blocks"][3]["state"], "done", "all done: the last block is done")
	var p3: Dictionary = DayPlan.today(snap({"blocks_done": {"speak": true, "listen": true}}))
	eq([p3["blocks"][0]["state"], p3["blocks"][2]["state"], p3["blocks"][3]["state"]], ["current", "done", "done"], "later blocks done: the first open block stays current")
	eq(p3["done_min"], 20, "listen + speak done: 8 + 12 minutes")
	var p4: Dictionary = DayPlan.today(snap({"blocks_done": {"new": "true", "review": null, "listen": 1, "speak": 0}}))
	eq([p4["blocks"][0]["state"], p4["blocks"][2]["state"], p4["blocks"][3]["state"]], ["current", "done", "todo"], "blocks_done: only true / non-zero int count (text, null, 0 do not)")
	var p5: Dictionary = DayPlan.today(snap({"blocks_done": "all"}))
	eq(p5["done_min"], 0, "blocks_done that is not a dictionary: nothing done")
	var p6: Dictionary = DayPlan.today(snap({"due": 40, "blocks_done": {"new": true}}))
	eq(p6["done_min"], 15, "review first: done_min counts the minutes of the shown blocks")
	var ids: Array = []
	for b in p["blocks"]:
		ids.append(b["id"])
	eq(ids, ["new", "review", "listen", "speak"], "block ids in order")
	for b in p["blocks"]:
		for k in ["id", "min", "title", "sub", "state", "target"]:
			ok(b.has(k), "block %s has %s" % [b["id"], k])


func _texts() -> void:
	var p: Dictionary = DayPlan.today(snap({"due": 12}))
	eq(p["blocks"][1]["sub"], CourseModel.progress_label("cards", 12, 0), "review sub is the shared label for 12 cards")
	eq(p["blocks"][1]["sub"], "카드 12장", "review sub reads 카드 12장")
	eq(p["blocks"][1]["target"], 12, "review target 12")
	var p2: Dictionary = DayPlan.today(snap({"due": 200}))
	eq(p2["blocks"][1]["target"], 15, "review target is capped at 15")
	eq(p2["blocks"][1]["sub"], "카드 15장", "review sub shows the capped target")
	eq(p["blocks"][2]["sub"], CourseModel.progress_label("questions", 8, 0), "listen sub is the shared label for 8 questions")
	eq(p["blocks"][3]["sub"], CourseModel.progress_label("sentences", 5, 0), "speak sub is the shared label for 5 sentences")
	eq(p["blocks"][0]["sub"], "5주 2일", "new block sub names the cell")
	eq(p["blocks"][0]["title"], "새 내용", "new block title")
	eq([p["blocks"][1]["title"], p["blocks"][2]["title"], p["blocks"][3]["title"]], ["복습", "듣기", "말하기"], "block titles")
	# no label ever has a 5-digit number, even with huge inputs
	var strings: Array = []
	for over in [{"due": 999999}, {"due": 1.0e20}, {"away_days": 99999999, "due": 99999999}, {"elapsed_days": 1.0e12, "w": 3}, {"w": 99999, "d": 99999},
			{"away_days": 400, "w": 70, "due": 5000}, {"check_pending": true, "check_pending_days": 9999999}]:
		all_strings(DayPlan.today(snap(over)), strings)
	var long_hits := 0
	for s in strings:
		if has_long_number(s):
			long_hits += 1
			print("  long number in: ", s)
	eq(long_hits, 0, "no text of any plan has a number of 5 or more digits (%d texts scanned)" % strings.size())
	ok(strings.size() > 40, "the scan really looked at many texts")
	for s in strings:
		if s.contains("%d") or s.contains("%s"):
			long_hits += 1
	eq(long_hits, 0, "no unfilled format placeholder in any text")
	eq(DayPlan.today(snap({"due": 40}))["start_label"], "오늘 45분 시작", "start label shows the total minutes")


func _finished() -> void:
	var p: Dictionary = DayPlan.today(snap({"w": 72, "d": 7, "finished": true}))
	eq(p["finished"], true, "finished: flag")
	eq(p["kind"], "free", "finished: kind free")
	eq(p["late_weeks"], 0, "finished: late 0")
	eq(p["total_min"], 45, "finished: still 45 minutes of practice")
	eq(p["blocks"].size(), 4, "finished: 4 blocks")
	var p2: Dictionary = DayPlan.today(snap({"w": 72, "d": 7, "finished": true, "away_days": 60, "elapsed_days": 9999}))
	eq([p2["recap"], p2["late_weeks"], p2["reopen"]], [false, 0, []], "finished: no recap, no late weeks, no reopen even after a long break")
	row("finished row", {"w": 72, "d": 7, "finished": true}, {"kind": "free", "mins": "10/10/10/15"})
	var p3: Dictionary = DayPlan.today(snap({"w": 72, "d": 7, "finished": false}))
	eq(p3["finished"], false, "week 72 day 7 but not finished: normal")
	eq(p3["kind"], "free", "week 72 day 7 is the free day")


func _legacy() -> void:
	for s in [{}, {"mode": "legacy"}, {"mode": 5}, {"mode": null}, {"mode": "Course"}, {"mode": ""}, {"mode": ["course"]}, {"due": 90, "w": 5}]:
		var p: Dictionary = DayPlan.today(s)
		eq([p["mode"], p["blocks"], p["total_min"], p["late_weeks"], p["review_priority"], p["recap"]], ["legacy", [], 0, 0, false, false], "legacy plan for %s" % str(s))
	for s in [null, [], "course", 5, 1.5, true]:
		var p2: Dictionary = DayPlan.today(s)
		eq([p2["mode"], p2["total_min"]], ["legacy", 0], "legacy plan for a snapshot of type %s" % str(typeof(s)))
	eq(DayPlan.today({"mode": "legacy"})["start_label"], "", "legacy: no start label")


func _sums_grid() -> void:
	var cells := 0
	var wrong := 0
	for w in range(1, 73):
		for d in range(1, 8):
			for due in [0, 10, 40, 5000]:
				for away in [0, 7, 21]:
					var p: Dictionary = DayPlan.today(snap({"w": w, "d": d, "due": due, "away_days": away}))
					var total := 0
					for b in p["blocks"]:
						total += int(b["min"])
					cells += 1
					if total != 45 or p["total_min"] != 45 or p["blocks"].size() != 4:
						wrong += 1
	eq(cells, 72 * 7 * 4 * 3, "grid: %d snapshots planned" % cells)
	eq(wrong, 0, "grid: every plan has 4 blocks and 45 minutes in total")


func _purity() -> void:
	var s: Dictionary = snap({"due": 77, "blocks_done": {"new": true}, "away_days": 8})
	var copy: Dictionary = s.duplicate(true)
	var a: Dictionary = DayPlan.today(s)
	var b: Dictionary = DayPlan.today(s)
	eq(a, b, "same input, same output")
	eq(s, copy, "the input snapshot is not changed")
	ok(s["blocks_done"] == {"new": true}, "the nested blocks_done is not changed")
	a["blocks"][0]["min"] = 999
	a["total_min"] = 1
	(a["reopen"] as Array).append(9)
	var c: Dictionary = DayPlan.today(s)
	eq(c, b, "changing a returned plan does not leak into the next call (no shared state)")
	var s2: Dictionary = snap()
	s2.erase("due")
	s2.erase("blocks_done")
	var copy2: Dictionary = s2.duplicate(true)
	DayPlan.today(s2)
	eq(s2, copy2, "missing keys are not added to the input")
	var seq: Array = []
	for i in 3:
		seq.append(DayPlan.today(snap({"due": 40 + i * 100})))
	eq(DayPlan.today(snap({"due": 40})), seq[0], "an earlier call has no effect on a later one")
	# no clock: the plan does not depend on time
	var t1: Dictionary = DayPlan.today(snap({"elapsed_days": 100}))
	OS.delay_msec(5)
	eq(DayPlan.today(snap({"elapsed_days": 100})), t1, "the plan does not depend on the clock")


func _bad_input() -> void:
	var failures := 0
	var count := 0
	for key in ["w", "d", "due", "away_days", "rp_streak", "rp_prev", "elapsed_days", "finished", "check_pending", "check_pending_days", "blocks_done"]:
		for v in BAD:
			count += 1
			var p: Dictionary = DayPlan.today(snap({key: v}))
			if p["mode"] != "course" or p["blocks"].size() != 4 or p["total_min"] != 45 or p["w"] < 1 or p["w"] > 72 or p["d"] < 1 or p["d"] > 7:
				failures += 1
				print("  bad value broke the plan: ", key, " = ", str(v))
	eq(failures, 0, "%d bad values (null, text, NaN, INF, negative, huge, arrays) give a normal 45-minute plan" % count)
	var p2: Dictionary = DayPlan.today(snap({"w": "x", "d": "y"}))
	eq([p2["w"], p2["d"]], [1, 1], "w / d as junk text -> 1 / 1")
	var p3: Dictionary = DayPlan.today(snap({"w": 99, "d": 0}))
	eq([p3["w"], p3["d"]], [72, 1], "w 99 / d 0 are clamped to 72 / 1")
	var p4: Dictionary = DayPlan.today(snap({"w": -4, "d": 12}))
	eq([p4["w"], p4["d"]], [1, 7], "w -4 / d 12 are clamped to 1 / 7")
	var p5: Dictionary = DayPlan.today(snap({"w": 5.0, "d": "3"}))
	eq([p5["w"], p5["d"]], [5, 3], "whole float w and integer text d are accepted")
	eq(DayPlan.today(snap({"due": "40"}))["review_priority"], true, "due as integer text 40 counts")
	eq(DayPlan.today(snap({"due": 39.9}))["review_priority"], false, "due 39.9 is cut to 39: normal")
	eq(DayPlan.today(snap({"due": 40.9}))["review_priority"], true, "due 40.9 is cut to 40: review first")
	eq(DayPlan.today(snap({"due": -5}))["blocks"][1]["min"], 0, "a negative due count is 0 cards")
	eq(DayPlan.today(snap({"away_days": 7.9}))["recap"], true, "away_days 7.9 is cut to 7: recap")
	eq(DayPlan.today(snap({"away_days": -3}))["recap"], false, "a negative away_days is 0")
	eq(DayPlan.today(snap({"rp_prev": 1, "due": 30}))["review_priority"], true, "rp_prev as a non-zero int counts")
	eq(DayPlan.today(snap({"rp_prev": "yes", "due": 30}))["review_priority"], false, "rp_prev as text does not count")


func _source_scan() -> void:
	var full: String = FileAccess.get_file_as_string("res://scripts/core/day_plan.gd")
	ok(full.length() > 0, "day_plan.gd is readable")
	var code: Array = []
	for line in full.split("
"):
		if not String(line).strip_edges().begins_with("##"):
			code.append(line)
	var text: String = "
".join(code)
	for bad in ["FileAccess", "DirAccess", "Store.", "StudyLog.", "CourseStore.", "Time.", "randi", "randf", "OS."]:
		ok(not text.contains(bad), "day_plan.gd has no %s (pure function)" % bad)
	for bad in ["%d" + "/%d", "Color(" + "\"#"]:
		ok(not text.contains(bad), "day_plan.gd has no %s" % bad)
