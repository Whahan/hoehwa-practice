extends Node
## 연속 기록 + 보호권 계산 (StreakCalc) 표 테스트.
##   godot --headless --path <project> res://tests/streak_test.tscn
## 종료 코드 0 = 전부 통과. 마지막 줄: "== streak result: N passed, 0 failed =="
## StreakCalc 는 순수 계산이라 파일을 쓰지 않지만, 혹시 모를 쓰기가 실제 사용자 파일로 가지 않게 경로를 임시로 바꿔 둔다.

var passed: int = 0
var failed: int = 0
var T: int = 0 ## "today" used by the tables
var _old_paths: Array = []


func _ready() -> void:
	print("== streak start ==")
	T = Plan.days_from_civil(2026, 10, 16)
	_old_paths = [Store.prefs_path, StudyLog.path]
	Store.prefs_path = "user://t1_test_streak_prefs.json"
	StudyLog.path = "user://t1_test_streak_log.json"
	_tables()
	_leap_and_long()
	_robustness()
	Store.prefs_path = _old_paths[0]
	StudyLog.path = _old_paths[1]
	print("== streak result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## offsets (0 = today, -1 = yesterday ...) -> {day_number: true}
func days(offs: Array) -> Dictionary:
	var d := {}
	for o in offs:
		d[T + int(o)] = true
	return d


func offs_of(frozen: Dictionary) -> Array:
	var out: Array = []
	for k in frozen.keys():
		out.append(int(k) - T)
	out.sort()
	return out


func run_range(a: int, b: int) -> Array:
	var out: Array = []
	for i in range(a, b + 1):
		out.append(i)
	return out


## Checks one settle() result: streak, tokens, used, gained, awarded and the frozen day offsets.
func expect(name: String, res: Dictionary, streak: int, tokens: int, used: int, gained: int, awarded: int, frozen_offs: Array) -> void:
	var got := "streak=%d tokens=%d used=%d gained=%d awarded=%d frozen=%s" % [res["streak"], res["tokens"], res["used"], res["gained"], res["awarded"], str(offs_of(res["frozen"]))]
	var want := "streak=%d tokens=%d used=%d gained=%d awarded=%d frozen=%s" % [streak, tokens, used, gained, awarded, str(frozen_offs)]
	ok(got == want, "%s  [%s]%s" % [name, got, "" if got == want else "  EXPECTED [%s]" % want])


func _tables() -> void:
	print("[tables]")
	expect("no history: nothing happens", StreakCalc.settle({}, {}, 1, 0, T), 0, 1, 0, 0, 0, [])
	expect("5 days through yesterday, today not done yet: not broken", StreakCalc.settle(days(run_range(-5, -1)), {}, 1, 0, T), 5, 1, 0, 0, 0, [])
	expect("5 days including today", StreakCalc.settle(days(run_range(-4, 0)), {}, 1, 0, T), 5, 1, 0, 0, 0, [])
	expect("today only", StreakCalc.settle(days([0]), {}, 1, 0, T), 1, 1, 0, 0, 0, [])
	expect("missed 1 day (yesterday) + 1 token: bridged", StreakCalc.settle(days([-4, -3, -2]), {}, 1, 0, T), 3, 0, 1, 0, 0, [-1])
	expect("missed 2 days + 1 token: cannot bridge, breaks, token kept", StreakCalc.settle(days([-5, -4, -3]), {}, 1, 0, T), 0, 1, 0, 0, 0, [])
	expect("missed 2 days + 2 tokens: bridged, frozen days do not add to the streak", StreakCalc.settle(days([-5, -4, -3]), {}, 2, 0, T), 3, 0, 2, 0, 0, [-2, -1])
	expect("missed 1 day, 0 tokens: breaks", StreakCalc.settle(days([-4, -3, -2]), {}, 0, 0, T), 0, 0, 0, 0, 0, [])
	expect("today done after a missed day + 1 token: bridged, today counts", StreakCalc.settle(days([-4, -3, -2, 0]), {}, 1, 0, T), 4, 0, 1, 0, 0, [-1])
	expect("today done after a 2-day gap + 1 token: breaks, streak is just today", StreakCalc.settle(days([-5, -4, 0]), {}, 1, 0, T), 1, 1, 0, 0, 0, [])
	expect("study history only long ago: protection is not used", StreakCalc.settle(days([-40, -39]), {}, 2, 0, T), 0, 2, 0, 0, 0, [])
	expect("7 days in a row: +1 token", StreakCalc.settle(days(run_range(-6, 0)), {}, 0, 0, T), 7, 1, 0, 1, 1, [])
	expect("6 days: no token yet", StreakCalc.settle(days(run_range(-5, 0)), {}, 0, 0, T), 6, 0, 0, 0, 0, [])
	expect("7 days with 1 token: now 2", StreakCalc.settle(days(run_range(-6, 0)), {}, 1, 0, T), 7, 2, 0, 1, 1, [])
	expect("7 days with 2 tokens: capped at 2, milestone still counted", StreakCalc.settle(days(run_range(-6, 0)), {}, 2, 0, T), 7, 2, 0, 0, 1, [])
	expect("14 days, 0 tokens: +2", StreakCalc.settle(days(run_range(-13, 0)), {}, 0, 0, T), 14, 2, 0, 2, 2, [])
	expect("14 days, 1 token: only +1 (cap)", StreakCalc.settle(days(run_range(-13, 0)), {}, 1, 0, T), 14, 2, 0, 1, 2, [])
	expect("14 days, milestone 1 already paid: only the second", StreakCalc.settle(days(run_range(-13, 0)), {}, 1, 1, T), 14, 2, 0, 1, 2, [])
	# streak broke, then a new run reaches 7 again -> paid again
	var broken: Dictionary = StreakCalc.settle(days([0]), {}, 2, 2, T)
	expect("run broke: awarded counter resets (tokens untouched)", broken, 1, 2, 0, 0, 0, [])
	var again: Dictionary = StreakCalc.settle(days(run_range(-6, 0)), broken["frozen"], 0, int(broken["awarded"]), T)
	expect("new 7-day run after a break pays again", again, 7, 1, 0, 1, 1, [])
	expect("bridged run keeps counting toward the milestone (6 done + 1 frozen + today)", StreakCalc.settle(days([-7, -6, -5, -4, -3, -2, 0]), {}, 1, 0, T), 7, 1, 1, 1, 1, [-1])
	# earlier frozen day is part of the same gap
	expect("earlier frozen day + one more miss, 1 token: both days covered", StreakCalc.settle(days([-3]), days([-2]), 1, 0, T), 1, 0, 1, 0, 0, [-2, -1])
	expect("earlier frozen day + one more miss, 0 tokens: gap too long, spent token returned", StreakCalc.settle(days([-3]), days([-2]), 0, 0, T), 0, 1, 0, 0, 0, [])
	expect("frozen day in the middle of a run bridges without counting", StreakCalc.settle(days([-4, -3, -1]), days([-2]), 0, 0, T), 3, 0, 0, 0, 0, [-2])


func _leap_and_long() -> void:
	print("[leap day / long data]")
	var mar1_leap: int = Plan.days_from_civil(2028, 3, 1)
	var done := {Plan.days_from_civil(2028, 2, 27): true, Plan.days_from_civil(2028, 2, 28): true}
	var r: Dictionary = StreakCalc.settle(done, {}, 1, 0, mar1_leap)
	ok((r["frozen"] as Dictionary).has(Plan.days_from_civil(2028, 2, 29)) and int(r["used"]) == 1 and int(r["streak"]) == 2, "2028-03-01: the missed Feb 29 is the protected day (leap year)")
	var mar1: int = Plan.days_from_civil(2027, 3, 1)
	var done2 := {Plan.days_from_civil(2027, 2, 27): true, Plan.days_from_civil(2027, 2, 28): true}
	var r2: Dictionary = StreakCalc.settle(done2, {}, 1, 0, mar1)
	ok(int(r2["used"]) == 0 and int(r2["streak"]) == 2 and (r2["frozen"] as Dictionary).is_empty(), "2027-03-01: Feb 28 -> Mar 1 has no gap (no leap day)")
	var ny: int = Plan.days_from_civil(2027, 1, 1)
	var r3: Dictionary = StreakCalc.settle({Plan.days_from_civil(2026, 12, 30): true, Plan.days_from_civil(2026, 12, 31): true}, {}, 1, 0, ny)
	ok(int(r3["streak"]) == 2 and int(r3["used"]) == 0, "year boundary: Dec 31 -> Jan 1 is consecutive")
	# 4000-day data is instant
	var big := {}
	for i in range(4000):
		big[T - i] = true
	var t0: int = Time.get_ticks_msec()
	var r4: Dictionary = StreakCalc.settle(big, {}, 0, 0, T)
	var ms: int = Time.get_ticks_msec() - t0
	ok(int(r4["streak"]) == 4000 and int(r4["tokens"]) == 2 and int(r4["awarded"]) == 571, "4000-day streak: streak 4000, tokens capped at 2, awarded 571")
	ok(ms < 300, "4000-day streak computed in %d ms (< 300)" % ms)
	# 4000 frozen days + a long gap must not hang either
	var fz := {}
	for i in range(3000):
		fz[T - 5000 - i] = true
	t0 = Time.get_ticks_msec()
	var r5: Dictionary = StreakCalc.settle(days([-5000]), fz, 2, 0, T)
	ms = Time.get_ticks_msec() - t0
	ok(int(r5["streak"]) == 0 and ms < 300, "huge gap + 3000 frozen days: breaks quickly (%d ms)" % ms)


func _robustness() -> void:
	print("[robustness]")
	# same call twice with the result fed back in -> identical, nothing used or gained the second time
	var cases := {
		"bridge": [days([-4, -3, -2]), {}, 1, 0],
		"two-day bridge": [days([-5, -4, -3]), {}, 2, 0],
		"milestone": [days(run_range(-6, 0)), {}, 0, 0],
		"two milestones": [days(run_range(-13, 0)), {}, 0, 0],
		"break with refund": [days([-4]), days([-3]), 0, 0],
	}
	for name in cases.keys():
		var a: Array = cases[name]
		var first: Dictionary = StreakCalc.settle(a[0], a[1], a[2], a[3], T)
		var second: Dictionary = StreakCalc.settle(a[0], first["frozen"], first["tokens"], first["awarded"], T)
		var same: bool = second["streak"] == first["streak"] and second["tokens"] == first["tokens"] and second["awarded"] == first["awarded"] and offs_of(second["frozen"]) == offs_of(first["frozen"])
		ok(same and int(second["used"]) == 0 and int(second["gained"]) == 0, "idempotent (%s): second call used=%d gained=%d, same state" % [name, second["used"], second["gained"]])

	# the clock went backwards: records dated after "today" -> nothing changes, future days are ignored for the streak
	var rec_done: Dictionary = days([-3, -2, -1, 3])
	var back: Dictionary = StreakCalc.settle(rec_done, days([-9]), 1, 1, T)
	expect("clock set back (a record from the future exists): state unchanged, streak ignores the future", back, 3, 1, 0, 0, 1, [-9])
	var back_f: Dictionary = StreakCalc.settle(days([-3, -2, -1]), days([2]), 2, 0, T)
	ok(int(back_f["tokens"]) == 2 and int(back_f["used"]) == 0 and offs_of(back_f["frozen"]) == [2], "a frozen day in the future also counts as a reversed clock")
	# going back one day after studying today: yesterday-state is what we see, no protection gets spent
	var yday: Dictionary = StreakCalc.settle(days([-3, -2, -1, 0]), {}, 1, 0, T - 1)
	expect("studied today, then the clock goes back 1 day: nothing spent, nothing gained", yday, 3, 1, 0, 0, 0, [])

	# inputs are not modified
	var d_in: Dictionary = days([-4, -3, -2])
	var f_in: Dictionary = {}
	StreakCalc.settle(d_in, f_in, 1, 0, T)
	ok(d_in.size() == 3 and f_in.is_empty(), "inputs are never modified")

	# garbage arguments
	var g1: Dictionary = StreakCalc.settle({"x": true, T - 1: true, T - 2: false}, {}, -5, -3, T)
	ok(int(g1["tokens"]) == 0 and int(g1["streak"]) == 1 and int(g1["awarded"]) == 0, "negative tokens/awarded and non-day keys are cleaned (streak %d tokens %d)" % [g1["streak"], g1["tokens"]])
	var g2: Dictionary = StreakCalc.settle(days([-3, -2]), {}, 99, 0, T)
	ok(int(g2["tokens"]) == 1 and int(g2["used"]) == 1, "tokens above the cap are clamped to 2 first (2 - 1 used = 1)")
	var g3: Dictionary = StreakCalc.settle({T + 0.0: true, NAN: true}, {}, 1, 0, T)
	ok(int(g3["streak"]) == 1, "float day keys work, NaN key ignored")
