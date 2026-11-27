extends Node
## 연속 기록 '쉬는 날'(v2.0.2): StreakCalc 규범 표·옛 알고리즘과 R=0 동등·저장/호환·화면·배지·잘못된 입력.
##   godot --headless --path <project> res://tests/rest_days_test.tscn [-- --phone]
## 종료 코드 0 = 전부 통과. 마지막 줄: "== rest_days result: N passed, 0 failed =="
## 실제 user://studylog.json / progress.json / prefs.json 은 읽지도 쓰지도 않는다(user://t_rest_* 로 바꿨다가 되돌림).

const LOG_PATH := "user://t_rest_studylog.json"
const PROG_PATH := "user://t_rest_progress.json"
const PREFS_PATH := "user://t_rest_prefs.json"

var passed: int = 0
var failed: int = 0
var D: int = 0 ## "today": a Friday (2026-10-16). -4 Mon, -3 Tue, -2 Wed, -1 Thu, -5 last Sun, -6 last Sat
var _old_paths: Array = []
var _toasts: Array = []


func _ready() -> void:
	print("== rest_days start ==")
	D = Plan.days_from_civil(2026, 10, 16)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	StudyLog.today_override = D
	StudyLog.rest_per_week_override = -1
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	_cleanup()

	_selfcheck()
	_test_table()
	_test_equivalence_r0()
	_test_properties()
	_test_week_borders()
	_test_study_log_storage()
	_test_study_log_settle()
	await _test_screens()
	_test_badge()
	_test_garbage()

	_cleanup()
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	StudyLog.rest_per_week_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	print("== rest_days result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- helpers

func iso(offset: int) -> String:
	return Plan.days_to_iso(D + offset)


func days(offs: Array) -> Dictionary:
	var d := {}
	for o in offs:
		d[D + int(o)] = true
	return d


func offs_of(m: Dictionary) -> Array:
	var out: Array = []
	for k in m.keys():
		out.append(int(k) - D)
	out.sort()
	return out


func rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".bad.1", LOG_PATH + ".bad.2", LOG_PATH + ".tmp", PROG_PATH, PROG_PATH + ".tmp", PREFS_PATH]:
		rm(p)


func _fresh() -> void:
	StudyLog.open_hook = Callable()
	_cleanup()
	StudyLog.today_override = D
	StudyLog.rest_per_week_override = -1
	Store.progress = Progress.blank()
	StudyLog.load_from_disk()
	_toasts.clear()


func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_json(p: String) -> Variant:
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return JSON.parse_string(t)


func mark_days(offs: Array, lang: String = "en") -> void:
	for o in offs:
		Store.progress["days"][iso(int(o))] = {lang: true}


## one settle() result as a comparable text
func res_text(res: Dictionary) -> String:
	return "frozen=%s rest=%s tokens=%d used=%d rest_used=%d streak=%d" % [str(offs_of(res["frozen"])), str(offs_of(res["rest"])), res["tokens"], res["used"], res["rest_used"], res["streak"]]


## the checker of the table rows: true when the result equals the wanted text
func row_matches(res: Dictionary, want: String) -> bool:
	return res_text(res) == want


# ---------------------------------------------------------------- the 2.0.1 algorithm, copied (R=0 comparison)

func old_settle(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int) -> Dictionary:
	tokens = clampi(tokens, 0, 2)
	awarded = maxi(awarded, 0)
	var fz: Dictionary = old_clean(frozen)
	var dn: Dictionary = old_clean(done)
	for k in dn.keys():
		if int(k) > today:
			return old_reversed(dn, fz, tokens, awarded, today)
	for k in fz.keys():
		if int(k) > today:
			return old_reversed(dn, fz, tokens, awarded, today)
	var used := 0
	var prev: int = -2147483648
	for k in dn.keys():
		var d: int = int(k)
		if d < today and d > prev:
			prev = d
	if prev != -2147483648:
		var gap: int = today - prev - 1
		if gap > 0:
			var in_gap := 0
			for k in fz.keys():
				var d: int = int(k)
				if d > prev and d < today:
					in_gap += 1
			var avail: int = tokens + in_gap
			if gap <= avail:
				for d in range(prev + 1, today):
					fz[d] = true
				tokens = avail - gap
				used = gap - in_gap
			else:
				for k in fz.keys():
					var d: int = int(k)
					if d > prev and d < today:
						fz.erase(k)
				tokens = mini(2, avail)
	var streak: int = old_run(dn, fz, today)
	var gained := 0
	var level: int = streak / 7
	if level > awarded:
		gained = clampi(level - awarded, 0, 2 - tokens)
		tokens += gained
		awarded = level
	elif level < awarded:
		awarded = level
	return {"frozen": fz, "tokens": tokens, "used": used, "streak": streak, "awarded": awarded, "gained": gained}


func old_run(done: Dictionary, frozen: Dictionary, today: int) -> int:
	var d: int = today if done.has(today) else today - 1
	var count := 0
	while true:
		if done.has(d):
			count += 1
		elif not frozen.has(d):
			break
		d -= 1
	return count


func old_reversed(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int) -> Dictionary:
	var dn := {}
	for k in done.keys():
		if int(k) <= today:
			dn[int(k)] = true
	var fz := {}
	for k in frozen.keys():
		if int(k) <= today:
			fz[int(k)] = true
	return {"frozen": frozen.duplicate(), "tokens": tokens, "used": 0, "streak": old_run(dn, fz, today), "awarded": awarded, "gained": 0}


func old_clean(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src.keys():
		if (k is int or (k is float and is_finite(k))) and bool(src[k]):
			out[int(k)] = true
	return out


## the six fields both algorithms return, as one text
func six(res: Dictionary) -> String:
	return "%s|%d|%d|%d|%d|%d" % [str(offs_of(res["frozen"])), res["tokens"], res["used"], res["streak"], res["awarded"], res["gained"]]


# ---------------------------------------------------------------- checks of the checkers

func _selfcheck() -> void:
	print("[selfcheck: the checkers can fail]")
	var res: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, 2)
	var right: String = "frozen=[-3, -2, -1] rest=[-3, -2] tokens=0 used=1 rest_used=2 streak=1"
	var wrong: String = "frozen=[-3, -2, -1] rest=[-3, -1] tokens=0 used=1 rest_used=2 streak=1"
	var m_ok: bool = row_matches(res, right)
	var m_bad: bool = row_matches(res, wrong)
	print("selfcheck %s table row with a wrong rest set" % ("FAIL-as-expected" if not m_bad else "UNEXPECTED-PASS"))
	ok(m_ok and not m_bad, "selfcheck: the table checker accepts the right row and rejects a wrong rest set")
	var a: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, 0)
	var b: Dictionary = old_settle(days([-4]), {}, 1, 0, D)
	var c: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, 2)
	var same_r0: bool = six(a) == six(b)
	var same_r2: bool = six(c) == six(b)
	print("selfcheck %s equivalence checker on R=2 against the old algorithm" % ("FAIL-as-expected" if not same_r2 else "UNEXPECTED-PASS"))
	ok(same_r0 and not same_r2, "selfcheck: the equivalence checker says same for R=0 and different for R=2")
	var fake_old: Dictionary = b.duplicate()
	fake_old["tokens"] = int(fake_old["tokens"]) + 1
	ok(six(fake_old) != six(a), "selfcheck: a changed token count is noticed by the six-field text")
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	ok(rx.search("연속 12345일") != null and rx.search("쉬는 날 2일 남음") == null, "selfcheck: the 5-digit detector finds a long number and not a short one")
	var snap_text: String = JSON.stringify(StudyLog.snapshot())
	print("selfcheck %s rest key detector on a studylog snapshot" % ("FAIL-as-expected" if '"rest"' in snap_text else "UNEXPECTED-PASS"))
	ok('"rest"' in snap_text, "selfcheck: the studylog snapshot itself does contain a rest key (so its absence in the sync view means something)")


# ---------------------------------------------------------------- RD-3 table

func _test_table() -> void:
	print("[RD-3 table, R = 2, today = Friday]")
	var rows: Array = [
		# name, done, frozen, rest, tokens, R, want_frozen, want_rest, want_tokens, want_used, want_rest_used, want_streak
		["1", [-3, -2], [], [], 1, 2, [-1], [-1], 1, 0, 1, 2],
		["2", [-4], [], [], 1, 2, [-3, -2, -1], [-3, -2], 0, 1, 2, 1],
		["3", [-4], [], [], 0, 2, [], [], 0, 0, 0, 0],
		["4", [-6], [], [], 2, 2, [-5, -4, -3, -2, -1], [-5, -4, -3], 0, 2, 3, 1],
		["5", [-6], [], [], 1, 2, [], [], 1, 0, 0, 0],
		["6", [-4], [-3, -2, -1], [-3, -2], 0, 2, [-3, -2, -1], [-3, -2], 0, 0, 0, 1],
		["7", [-6, -3], [-5, -4], [-5, -4], 1, 2, [-5, -4, -2, -1], [-5, -4, -2], 0, 1, 1, 2],
		["8 (R=1)", [-4], [], [], 1, 1, [], [], 1, 0, 0, 0],
		["9 (clock back)", [-4, 1], [], [], 1, 2, [], [], 1, 0, 0, 0],
		["10", [-3], [-2], [], 0, 2, [-2, -1], [-1], 0, 0, 1, 1],
		["11 (R=0 refund)", [-4], [-3], [], 0, 0, [], [], 1, 0, 0, 0],
		["12", [-4], [-3], [], 0, 2, [-3, -2, -1], [-2, -1], 0, 0, 2, 1],
		["13 (rest not in frozen)", [-3], [], [-2], 1, 2, [-2, -1], [-2, -1], 1, 0, 2, 1],
	]
	for r in rows:
		var res: Dictionary = StreakCalc.settle(days(r[1]), days(r[2]), int(r[4]), 0, D, days(r[3]), int(r[5]))
		var want: String = "frozen=%s rest=%s tokens=%d used=%d rest_used=%d streak=%d" % [str(r[6]), str(r[7]), r[8], r[9], r[10], r[11]]
		var got: String = res_text(res)
		ok(got == want, "row %s: %s%s" % [r[0], got, "" if got == want else "  EXPECTED " + want])
	# row 6 literally: feed the result of row 2 back in
	var first: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, 2)
	var second: Dictionary = StreakCalc.settle(days([-4]), first["frozen"], int(first["tokens"]), int(first["awarded"]), D, first["rest"], 2)
	ok(res_text(second) == "frozen=[-3, -2, -1] rest=[-3, -2] tokens=0 used=0 rest_used=0 streak=1", "row 6 fed with the real result of row 2: same state, nothing used again")
	# one day later (Saturday): Friday is the new empty day, the week has no rest day left, so it needs a token
	var sat: Dictionary = StreakCalc.settle(days([-4]), first["frozen"], 1, 0, D + 1, first["rest"], 2)
	ok(res_text(sat).replace("[-3, -2, -1, 0]", "X") == "frozen=X rest=[-3, -2] tokens=0 used=1 rest_used=0 streak=1" and offs_of(sat["frozen"]) == [-3, -2, -1, 0], "the day after, with a token: the bridged days stay and Friday is bridged by the token -> %s" % res_text(sat))
	var sat0: Dictionary = StreakCalc.settle(days([-4]), first["frozen"], 0, 0, D + 1, first["rest"], 2)
	ok(int(sat0["streak"]) == 0 and offs_of(sat0["frozen"]) == [] and offs_of(sat0["rest"]) == [] and int(sat0["tokens"]) == 1, "the day after, no token: the whole gap is dropped, the token spent on Thursday comes back -> %s" % res_text(sat0))
	# a bridged gap does not add the rest days to the streak
	var after: Dictionary = StreakCalc.settle(days([-4, -3, 0]), {}, 0, 0, D, {}, 2)
	ok(int(after["streak"]) == 3 and int(after["rest_used"]) == 2 and int(after["tokens"]) == 0 and int(after["used"]) == 0, "study after two rest days: streak 3, rest days not counted, no token used")
	# the clock-back result keeps the rest set that was given
	var back: Dictionary = StreakCalc.settle(days([-4, 1]), days([-3]), 1, 0, D, days([-3]), 2)
	ok(offs_of(back["rest"]) == [-3] and int(back["rest_used"]) == 0, "clock set back: the rest set is returned unchanged and nothing is used")
	var beyond: Dictionary = StreakCalc.settle(days([-9]), {}, 0, 0, D, {}, 2)
	ok(int(beyond["streak"]) == 0 and offs_of(beyond["frozen"]) == [] and int(beyond["rest_used"]) == 0, "a gap of 8 days with 2 rest days and no token: not bridged, no rest day is taken")


# ---------------------------------------------------------------- RD-2 R=0 equals the old result

func _test_equivalence_r0() -> void:
	print("[RD-2 R=0 equals the 2.0.1 result, 2000 seeded cases]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261127
	var same := 0
	var diff_r2 := 0
	var future_cases := 0
	var n := 2000
	for i in n:
		var hi: int = 4 if rng.randf() < 0.25 else 0
		var done := {}
		var frozen := {}
		var p_done: float = rng.randf_range(0.1, 0.8)
		var p_fz: float = rng.randf_range(0.0, 0.3)
		for off in range(-25, hi + 1):
			if rng.randf() < p_done:
				done[D + off] = true
			if rng.randf() < p_fz:
				frozen[D + off] = true
		var tokens: int = rng.randi_range(-1, 4)
		var awarded: int = rng.randi_range(-1, 5)
		for k in done.keys():
			if int(k) > D:
				future_cases += 1
				break
		var old: Dictionary = old_settle(done, frozen, tokens, awarded, D)
		var neu: Dictionary = StreakCalc.settle(done, frozen, tokens, awarded, D, {}, 0)
		if six(old) == six(neu) and int(neu["rest_used"]) == 0 and (neu["rest"] as Dictionary).is_empty():
			same += 1
		var with_rest: Dictionary = StreakCalc.settle(done, frozen, tokens, awarded, D, {}, 2)
		if six(old) != six(with_rest):
			diff_r2 += 1
	print("RD_EQUIV_R0 cases=%d same=%d" % [n, same])
	ok(same == n, "R=0: all %d random cases give the old result (future days in %d of them)" % [n, future_cases])
	ok(future_cases > 100, "the random cases include records from the future (%d)" % future_cases)
	ok(diff_r2 > 100, "the same cases with R=2 differ often (%d), so the comparison can fail" % diff_r2)
	# the omitted arguments mean R = 0, too
	var o1: Dictionary = StreakCalc.settle(days([-4, -3]), {}, 1, 0, D)
	var o2: Dictionary = old_settle(days([-4, -3]), {}, 1, 0, D)
	ok(six(o1) == six(o2) and int(o1["rest_used"]) == 0, "the old 5-argument call keeps its result")


# ---------------------------------------------------------------- invariants with random inputs

func _test_properties() -> void:
	print("[invariants: random inputs and day-by-day runs]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var subset := 0
	var week_ok := 0
	var tokens_ok := 0
	var n := 600
	for i in n:
		var done := {}
		var frozen := {}
		for off in range(-30, 1):
			if rng.randf() < 0.35:
				done[D + off] = true
			if rng.randf() < 0.1:
				frozen[D + off] = true
		var rest := {}
		for k in frozen.keys():
			if rng.randf() < 0.5:
				rest[k] = true
		var tokens: int = rng.randi_range(0, 2)
		var rpw: int = rng.randi_range(0, 7)
		var r1: Dictionary = StreakCalc.settle(done, frozen, tokens, 0, D, rest, rpw)
		var sub := true
		for k in (r1["rest"] as Dictionary).keys():
			sub = sub and (r1["frozen"] as Dictionary).has(k)
		if sub:
			subset += 1
		# per week: the rest days after settling never exceed max(R, what the (cleaned) input already had in that week)
		var before := {}
		for k in rest.keys():
			if frozen.has(k):
				before[StreakCalc.week_of(int(k))] = int(before.get(StreakCalc.week_of(int(k)), 0)) + 1
		var after := {}
		for k in (r1["rest"] as Dictionary).keys():
			after[StreakCalc.week_of(int(k))] = int(after.get(StreakCalc.week_of(int(k)), 0)) + 1
		var wk := true
		for w in after.keys():
			wk = wk and int(after[w]) <= maxi(rpw, int(before.get(w, 0)))
		if wk:
			week_ok += 1
		if int(r1["tokens"]) >= 0 and int(r1["tokens"]) <= 2:
			tokens_ok += 1
	ok(subset == n, "rest days are always frozen days (%d/%d)" % [subset, n])
	ok(week_ok == n, "no calendar week gets more rest days than R (or than it already had) (%d/%d)" % [week_ok, n])
	ok(tokens_ok == n, "tokens stay within 0..2 (%d/%d)" % [tokens_ok, n])
	# day by day, the way the app uses it: settle every day, studying on random days. Settling a result again changes nothing.
	var runs := 300
	var idem := 0
	var never_more := 0
	for r in runs:
		var rpw2: int = rng.randi_range(0, 7)
		var p_study: float = rng.randf_range(0.2, 0.9)
		var done2 := {}
		var fz2 := {}
		var rs2 := {}
		var tok := 1
		var awd := 0
		var good := true
		var weeks_ok := true
		for day in range(-60, 1):
			var t: int = D + day
			if rng.randf() < p_study:
				done2[t] = true
			var a: Dictionary = StreakCalc.settle(done2, fz2, tok, awd, t, rs2, rpw2)
			var b: Dictionary = StreakCalc.settle(done2, a["frozen"], int(a["tokens"]), int(a["awarded"]), t, a["rest"], rpw2)
			if not (offs_of(a["frozen"]) == offs_of(b["frozen"]) and offs_of(a["rest"]) == offs_of(b["rest"]) and int(b["used"]) == 0 and int(b["rest_used"]) == 0 and int(a["streak"]) == int(b["streak"]) and int(a["tokens"]) == int(b["tokens"])):
				good = false
			var per := {}
			for k in (a["rest"] as Dictionary).keys():
				per[StreakCalc.week_of(int(k))] = int(per.get(StreakCalc.week_of(int(k)), 0)) + 1
			for w in per.keys():
				if int(per[w]) > rpw2:
					weeks_ok = false
			fz2 = a["frozen"]
			rs2 = a["rest"]
			tok = int(a["tokens"])
			awd = int(a["awarded"])
		if good:
			idem += 1
		if weeks_ok:
			never_more += 1
	ok(idem == runs, "day-by-day runs: settling a result again changes nothing (%d/%d runs)" % [idem, runs])
	ok(never_more == runs, "day-by-day runs: no week ever holds more than R rest days (%d/%d runs)" % [never_more, runs])


func _test_week_borders() -> void:
	print("[calendar week borders]")
	# the week border is between Sunday and Monday: each side gets its own 2 rest days
	var res: Dictionary = StreakCalc.settle(days([-8]), {}, 0, 0, D, {}, 2) # gap -7..-1: Fri Sat Sun | Mon Tue Wed Thu
	ok(int(res["streak"]) == 0 and int(res["rest_used"]) == 0, "7 empty days: 2 + 2 rest days are not enough, no token -> not bridged, no rest day taken")
	var res2: Dictionary = StreakCalc.settle(days([-7]), {}, 0, 0, D, {}, 2) # gap -6..-1: Sat Sun | Mon Tue Wed Thu
	ok(int(res2["rest_used"]) == 0 and int(res2["streak"]) == 0, "Sat Sun | Mon..Thu: the second week has 4 empty days, 2 rest days are not enough without tokens")
	var res3: Dictionary = StreakCalc.settle(days([-6]), {}, 1, 0, D, {}, 2) # gap -5..-1: Sun | Mon Tue Wed Thu
	ok(int(res3["streak"]) == 0 and int(res3["tokens"]) == 1, "Sun | Mon..Thu with 1 token: 3 rest days, 2 more days need 2 tokens -> not bridged")
	var res4: Dictionary = StreakCalc.settle(days([-5]), {}, 2, 0, D, {}, 2) # gap -4..-1: Mon Tue Wed Thu, one week
	ok(res_text(res4) == "frozen=[-4, -3, -2, -1] rest=[-4, -3] tokens=0 used=2 rest_used=2 streak=1", "Mon..Thu in one week: 2 rest days + 2 tokens -> %s" % res_text(res4))
	# the weekday of the fixed day is a Friday (the table depends on it)
	ok(Plan.weekday(D) == 5, "the fixed 'today' is a Friday")
	ok(StreakCalc.week_of(D - 5) == D - 11 and StreakCalc.week_of(D - 4) == D - 4, "Sunday belongs to the week before, Monday to the next")
	# week_of is the calendar week even when a rest day is one day before Monday
	var sun: Dictionary = StreakCalc.settle(days([-6]), {}, 2, 0, D, {}, 2)
	ok(offs_of(sun["rest"]) == [-5, -4, -3] and int(sun["used"]) == 2, "gap Sun..Thu: Sun (last week) + Mon + Tue are rest days, Wed and Thu use 2 tokens")


# ---------------------------------------------------------------- StudyLog storage (RD-4)

func _test_study_log_storage() -> void:
	print("[RD-4 storage and compatibility]")
	_fresh()
	mark_days([-4])
	var s1: Dictionary = StudyLog.settle("en")
	ok(int(s1["rest_used"]) == 2 and int(s1["used"]) == 1 and int(s1["tokens"]) == 0 and int(s1["rest_left"]) == 0, "Mon studied, today Fri: 2 rest days + 1 token -> %s" % str(s1))
	var fz: Dictionary = StudyLog.snapshot()["freeze"]["en"]
	ok(fz["rest"] == [iso(-3), iso(-2)] and fz["frozen"] == [iso(-3), iso(-2), iso(-1)], "freeze.en.rest and frozen are written: %s" % str(fz))
	ok(StudyLog.is_dirty(), "the new rest days are marked for saving")
	StudyLog.flush()
	var on_disk: Variant = read_json(LOG_PATH)
	ok(on_disk is Dictionary and (on_disk["freeze"]["en"]["rest"] as Array) == [iso(-3), iso(-2)], "the file has freeze.en.rest as iso dates")
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [iso(-3), iso(-2)] and offs_of(StudyLog.rest_days("en")) == [-3, -2], "saved and read again: same rest days (rest_days)")
	ok(StudyLog.rest_left("en") == 0, "rest_left is 0 after both rest days of the week are used")
	ok(StudyLog.snapshot()["freeze"]["ja"]["rest"] == [], "the other language has no rest days")
	# an old file (2.0.1): no rest key, the streak stays
	_fresh()
	mark_days([-4, -3, -2])
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 1, "frozen": [iso(-1)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [] and StudyLog.rest_days("en").is_empty(), "an old file without rest: rest is []")
	var s2: Dictionary = StudyLog.settle("en")
	ok(int(s2["streak"]) == 3 and int(s2["tokens"]) == 1 and int(s2["used"]) == 0 and int(s2["rest_used"]) == 0, "...and the streak stays 3 with the token kept -> %s" % str(s2))
	ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [], "...the old token day is not turned into a rest day")
	# bad values in the rest list
	_fresh()
	var junk: Array = [iso(-2), "2026-13-45", "x", 5, 2.5, null, {"a": 1}, [1], iso(-2), iso(-9), true]
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 1, "frozen": [iso(-2), iso(-3)], "rest": junk, "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [iso(-2)], "bad dates, numbers, null, duplicates and days that are not frozen are dropped: %s" % str(StudyLog.snapshot()["freeze"]["en"]["rest"]))
	for bad in ["text", 5, {"a": 1}, null, true, 1.5]:
		_fresh()
		write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 1, "frozen": [iso(-2)], "rest": bad, "awarded": 0}}}))
		StudyLog.load_from_disk()
		ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [] and StudyLog.snapshot()["freeze"]["en"]["frozen"] == [iso(-2)], "rest = %s -> [] and frozen stays" % JSON.stringify(bad))
	# 400-day pruning
	_fresh()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 1, "frozen": [iso(-401), iso(-1)], "rest": [iso(-401), iso(-1)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	StudyLog.add_seconds("en", "lesson", 30)
	StudyLog.flush()
	var pruned: Variant = read_json(LOG_PATH)
	ok(pruned is Dictionary and pruned["freeze"]["en"]["rest"] == [iso(-1)] and pruned["freeze"]["en"]["frozen"] == [iso(-1)], "a rest day older than 400 days is removed when saving (frozen too)")
	# apply_sync keeps the rest days
	_fresh()
	mark_days([-4])
	StudyLog.settle("en")
	var before_rest: Array = (StudyLog.snapshot()["freeze"]["en"]["rest"] as Array).duplicate()
	var parts := {"days": (StudyLog.snapshot()["days"] as Dictionary).duplicate(true)}
	ok(StudyLog.apply_sync(parts), "apply_sync works")
	ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == before_rest and before_rest.size() == 2, "after apply_sync the rest days are as before")
	# not part of the sync view
	var view: Dictionary = SyncDoc.extract(Store.progress, StudyLog.snapshot(), Store.prefs, 0)
	var view_text: String = JSON.stringify(view)
	ok(not ('"rest"' in view_text) and not ('"freeze"' in view_text) and not ('"frozen"' in view_text), "SyncDoc.extract has no rest, freeze or frozen key")
	# settle twice: the second is not dirty
	_fresh()
	mark_days([-4])
	StudyLog.settle("en")
	StudyLog.flush()
	ok(not StudyLog.is_dirty(), "(precondition) flushed")
	StudyLog.settle("en")
	ok(not StudyLog.is_dirty(), "settle a second time the same day: the log is not dirty again")
	# the file shape is still version 1
	ok(int(StudyLog.snapshot()["v"]) == 1 and StudyLog.VERSION == 1, "VERSION is still 1 (no migration)")
	ok(not ("rest" in StudyLog.KNOWN_KEYS), "rest is a key inside freeze, not a new top-level key")


# ---------------------------------------------------------------- StudyLog.settle and toasts

func _test_study_log_settle() -> void:
	print("[StudyLog.settle: toasts, override, clock]")
	_fresh()
	mark_days([-3, -2])
	var s: Dictionary = StudyLog.settle("en")
	ok(int(s["rest_used"]) == 1 and int(s["used"]) == 0 and int(s["streak"]) == 2 and int(s["rest_left"]) == 1, "Tue and Wed studied: Thursday is a rest day, no token -> %s" % str(s))
	ok(_toasts.size() == 1 and _toasts[0] == StudyLog.TXT_REST_USED % 1, "the rest day toast is shown exactly once: %s" % str(_toasts))
	StudyLog.settle("en")
	ok(_toasts.size() == 1, "the second settle of the same day shows no toast")
	_fresh()
	mark_days([-4])
	StudyLog.settle("en")
	ok(_toasts.size() == 2 and (StudyLog.TXT_REST_USED % 2) in _toasts and ("보호권 1개를 써서" in _toasts[1] or "보호권 1개를 써서" in _toasts[0]), "both a rest day toast and the token toast when both were used: %s" % str(_toasts))
	# the override turns the feature off
	_fresh()
	StudyLog.rest_per_week_override = 0
	mark_days([-4])
	var s0: Dictionary = StudyLog.settle("en")
	ok(StudyLog.rest_per_week() == 0 and int(s0["streak"]) == 0 and int(s0["rest_used"]) == 0, "rest_per_week_override 0: the old rule (3 empty days, 1 token: broken) -> %s" % str(s0))
	StudyLog.rest_per_week_override = -1
	ok(StudyLog.rest_per_week() == StreakCalc.REST_PER_WEEK, "override -1 means StreakCalc.REST_PER_WEEK")
	StudyLog.rest_per_week_override = 5
	ok(StudyLog.rest_per_week() == 5, "override 5 is used")
	StudyLog.rest_per_week_override = -1
	# clock set back: nothing changes
	_fresh()
	mark_days([-3, -2])
	StudyLog.settle("en")
	StudyLog.flush()
	var snap_before: Dictionary = StudyLog.snapshot()
	_toasts.clear()
	StudyLog.today_override = D - 5
	var sb: Dictionary = StudyLog.settle("en")
	ok(int(sb["rest_used"]) == 0 and int(sb["used"]) == 0 and StudyLog.snapshot() == snap_before and _toasts.is_empty(), "clock set back 5 days: no rest day used, state untouched, no toast")
	StudyLog.today_override = D
	# next day (Saturday): the rest day of Thursday stays, a new gap (Fri) is a second rest day
	StudyLog.today_override = D + 1
	var nx: Dictionary = StudyLog.settle("en")
	ok(int(nx["rest_used"]) == 1 and int(nx["rest_left"]) == 0 and int(nx["streak"]) == 2, "next day: Friday becomes the second rest day of the week, none left -> %s" % str(nx))
	StudyLog.today_override = D + 2
	var nx2: Dictionary = StudyLog.settle("en")
	ok(int(nx2["rest_used"]) == 0 and int(nx2["used"]) == 1 and int(nx2["tokens"]) == 0 and int(nx2["streak"]) == 2, "two days later (Sunday): Saturday needs the token (week full) -> %s" % str(nx2))
	StudyLog.today_override = D + 3 # Monday: a new week
	var nx3: Dictionary = StudyLog.settle("en")
	ok(int(nx3["streak"]) == 0 and int(nx3["tokens"]) == 1 and int(nx3["rest_used"]) == 0 and int(nx3["rest_left"]) == 2, "Monday: Sunday belongs to the full old week and no token is left -> the streak breaks, Saturday's token comes back, the new week has 2 rest days -> %s" % str(nx3))
	StudyLog.today_override = D
	# Japanese has its own rest days
	_fresh()
	mark_days([-3, -2], "ja")
	var ja: Dictionary = StudyLog.settle("ja")
	var en: Dictionary = StudyLog.settle("en")
	ok(int(ja["rest_used"]) == 1 and int(ja["rest_left"]) == 1 and int(en["rest_used"]) == 0 and int(en["rest_left"]) == 2, "the Japanese record uses its own rest day, English keeps 2")
	ok(StudyLog.settle("zz")["rest_left"] == 0 and StudyLog.rest_days("zz").is_empty() and StudyLog.rest_left("zz") == 0, "an unknown language: nothing, no crash")


# ---------------------------------------------------------------- screens (RD-5), no backend needed

func _texts(node: Node) -> Array:
	var out: Array = []
	for n in node.find_children("*", "Label", true, false):
		out.append((n as Label).text)
	for n in node.find_children("*", "Button", true, false):
		out.append((n as Button).text)
	return out


func _has_text(node: Node, part: String) -> bool:
	for t in _texts(node):
		if part in str(t):
			return true
	return false


func _big_number(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	for t in texts:
		if rx.search(str(t)) != null:
			return true
	return false


func _test_screens() -> void:
	print("[RD-5 screens]")
	var holder := Control.new()
	holder.size = Vector2(412, 900)
	add_child(holder)
	# before anything is used: 2 rest days left
	_fresh()
	StudyLog.settle("en")
	var card0: Control = HomeParts.streak_card("en", HomeParts.snapshot("en"), func() -> void: pass)
	holder.add_child(card0)
	await get_tree().process_frame
	ok(_has_text(card0, "쉬는 날 2일 남음"), "home streak card: chip '쉬는 날 2일 남음' before a rest day is used")
	card0.queue_free()
	# Mon studied: today Friday -> Tue Wed rest days, Thu token day
	_fresh()
	mark_days([-4])
	StudyLog.settle("en")
	var states: Array = HomeParts.stone_states("en")
	ok(states == ["done", "rest", "rest", "frozen", "today", "future", "future"], "stone states: Mon done, Tue+Wed rest, Thu frozen, Fri today -> %s" % str(states))
	var card1: Control = HomeParts.streak_card("en", HomeParts.snapshot("en"), func() -> void: pass)
	holder.add_child(card1)
	await get_tree().process_frame
	await get_tree().process_frame
	var row: Control = card1.find_child("Stones", true, false)
	ok(row != null and row.get_meta("states") == states, "the Stones row carries the same states (meta)")
	var kinds := {}
	var rest_named := 0
	for i in 7:
		var st: Control = row.find_child("Stone%d" % i, true, false)
		kinds[str(st.get_meta("stone_state"))] = true
		if st.accessibility_name.ends_with("쉬는 날"):
			rest_named += 1
	ok(kinds.has("rest") and kinds.has("frozen") and rest_named == 2, "rest and frozen stones are different kinds; the 2 rest stones are named '... 쉬는 날' (%d)" % rest_named)
	ok(_has_text(card1, "쉬는 날 0일 남음"), "the chip shows 0 left too: '쉬는 날 0일 남음'")
	ok(not _big_number(_texts(card1)), "home streak card: no 5-digit number in the texts")
	card1.queue_free()
	# one rest day used: 1 left
	_fresh()
	mark_days([-3, -2])
	StudyLog.settle("en")
	var card2: Control = HomeParts.streak_card("en", HomeParts.snapshot("en"), func() -> void: pass)
	holder.add_child(card2)
	await get_tree().process_frame
	ok(_has_text(card2, "쉬는 날 1일 남음") and not _has_text(card2, "쉬는 날 2일 남음"), "after one rest day is used: '쉬는 날 1일 남음'")
	card2.queue_free()
	# a rest day stone beats a frozen one only when both are marked; a studied day beats both
	_fresh()
	mark_days([-3])
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 1, "frozen": [iso(-3), iso(-2)], "rest": [iso(-3), iso(-2)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	var pr: Array = HomeParts.stone_states("en")
	ok(pr[1] == "done" and pr[2] == "rest", "a studied day is 'done' even if it is also marked as a rest day; the other one is 'rest' -> %s" % str(pr))
	# goal card
	_fresh()
	mark_days([-3, -2])
	StudyLog.settle("en")
	var full: GoalCard = GoalCard.full("en")
	holder.add_child(full)
	await get_tree().process_frame
	ok(_has_text(full, GoalCard.EXPLAIN), "goal card: the explanation is GoalCard.EXPLAIN")
	ok(_has_text(full, "보호권 개수보다 많은 날을 놓치면") and _has_text(full, "보호권은 그대로 남아요") and _has_text(full, "2일까지는 보호권 없이"), "goal card: explanation has the three required parts")
	ok(_has_text(full, "쉬는 날 1일 남음"), "goal card chips: '쉬는 날 1일 남음'")
	ok(not _big_number(_texts(full)), "goal card: no 5-digit number in the texts")
	full.queue_free()
	var cmp: GoalCard = GoalCard.compact("en")
	holder.add_child(cmp)
	await get_tree().process_frame
	var line := ""
	for t in _texts(cmp):
		line += str(t) + " "
	ok("보호권 1개 · 쉬는 날 1일 남음" in line, "compact goal card: the line ends with ' · 쉬는 날 1일 남음' -> '%s'" % line.strip_edges())
	ok(cmp.get_combined_minimum_size().x <= 392.0, "compact goal card still fits a 412 px phone (%.0f)" % cmp.get_combined_minimum_size().x)
	cmp.queue_free()
	# the explanation follows the constant
	ok(GoalCard.EXPLAIN.find("%d") == -1 and ("%d일까지는" % StreakCalc.REST_PER_WEEK) in GoalCard.EXPLAIN, "EXPLAIN is filled from StreakCalc.REST_PER_WEEK and has no leftover format mark")
	# rest_per_week 0 hides the chip (the old-rule tests)
	_fresh()
	StudyLog.rest_per_week_override = 0
	var card3: Control = HomeParts.streak_card("en", HomeParts.snapshot("en"), func() -> void: pass)
	holder.add_child(card3)
	await get_tree().process_frame
	ok(not _has_text(card3, "쉬는 날"), "with 0 rest days a week the chip is not shown")
	card3.queue_free()
	StudyLog.rest_per_week_override = -1
	holder.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- badge (RD-7)

func _test_badge() -> void:
	print("[RD-7 badge streak_7 through rest days]")
	_fresh()
	# Mon(S) Tue(R) Wed(R) Thu(S) Fri(S) Sat(S) Sun(S) Mon(S) Tue(S): 7 study days in 9 calendar days
	var study: Array = [-4, -1, 0, 1, 2, 3, 4]
	var rest_offs: Array = [-3, -2]
	for t in range(-4, 5):
		StudyLog.today_override = D + t
		if t in study:
			Store.progress["days"][iso(t)] = {"en": true}
		StudyLog.settle("en")
	StudyLog.today_override = D + 4
	var rd: Dictionary = StudyLog.rest_days("en")
	var picked: Array = offs_of(rd)
	ok(picked == rest_offs, "the two days in the middle were rest days: %s" % str(picked))
	ok(StudyLog.longest_streak("en") == 7, "longest_streak is 7 over 9 calendar days (rest days bridge, they are not counted) -> %d" % StudyLog.longest_streak("en"))
	var snap: Dictionary = BadgeEngine.snapshot(["streak_best"])
	ok(int(snap["streak_best"]) >= 7, "BadgeEngine streak_best >= 7 (%d)" % int(snap["streak_best"]))
	ok("streak_7" in BadgeRules.earned_ids(snap), "streak_7 is earned")
	var low: Dictionary = snap.duplicate()
	low["streak_best"] = 6
	ok(not ("streak_7" in BadgeRules.earned_ids(low)), "selfcheck: with streak_best 6 streak_7 is not earned")
	StudyLog.today_override = D


# ---------------------------------------------------------------- bad input (RD-8)

func _test_garbage() -> void:
	print("[RD-8 bad input]")
	var weird_rest: Array = [{"x": true}, {1.5: true, "7": true}, {NAN: true}, {-1: true}, {D - 3: false}, {D - 3: true}, {D - 3 + 0.0: true}]
	var crashed := false
	for wr in weird_rest:
		var r: Dictionary = StreakCalc.settle(days([-4]), days([-3]), 1, 0, D, wr, 2)
		crashed = crashed or not (r.has("rest") and r.has("rest_used"))
	ok(not crashed, "rest dictionaries with strings, floats, NaN, negative keys and false values give a normal result")
	var r_nan: Dictionary = StreakCalc.settle(days([-4]), days([-3]), 1, 0, D, {NAN: true}, 2)
	ok(offs_of(r_nan["rest"]) == [-2, -1], "a NaN rest key is ignored (the two empty days after the token day became rest days)")
	var neg: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, -3)
	var big: Dictionary = StreakCalc.settle(days([-4]), {}, 1, 0, D, {}, 99)
	ok(int(neg["rest_used"]) == 0 and int(big["rest_used"]) == 3 and int(big["used"]) == 0, "rest_per_week -3 acts as 0; 99 acts as 7 (3 empty days all rest days, token kept) -> %s / %s" % [res_text(neg), res_text(big)])
	ok(StreakCalc.rest_left({}, D, -3) == 0 and StreakCalc.rest_left({}, D, 99) == 7, "rest_left clamps R to 0..7")
	# the studylog with a freeze that is not a dictionary
	for bad in ["x", 5, [1, 2], null]:
		_fresh()
		write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": bad}}))
		StudyLog.load_from_disk()
		var s: Dictionary = StudyLog.settle("en")
		ok(StudyLog.snapshot()["freeze"]["en"]["rest"] == [] and int(s["streak"]) == 0, "freeze.en = %s: a blank freeze with rest [], no crash" % JSON.stringify(bad))
	_fresh()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": "nothing"}))
	StudyLog.load_from_disk()
	ok(StudyLog.rest_days("en").is_empty() and StudyLog.rest_days("ja").is_empty(), "freeze is not a dictionary at all: rest_days are empty")
	StudyLog.today_override = D
