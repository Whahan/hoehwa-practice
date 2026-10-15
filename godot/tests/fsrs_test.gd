extends Node
## Headless FSRS test: replays tests/fsrs_reference.json (generated with py-fsrs, fuzz off)
## through scripts/core/fsrs.gd.
##   godot --headless --path <project> res://tests/fsrs_test.tscn
## Exit code 0 = all checks passed.

const REFERENCE := "res://tests/fsrs_reference.json"
const TOL := 1e-4

var passed: int = 0
var failed: int = 0


func _ready() -> void:
	print("== fsrs test start ==")
	_test_reference()
	_test_helpers()
	print("== fsrs result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _test_reference() -> void:
	print("[py-fsrs reference]")
	var f := FileAccess.open(REFERENCE, FileAccess.READ)
	if f == null:
		ok(false, "cannot open " + REFERENCE)
		return
	var doc: Dictionary = JSON.parse_string(f.get_as_text())
	var params: Dictionary = doc["params"]
	# the reference must have been generated with the same constants the port hard-codes
	ok(params["parameters"].size() == 21, "reference has 21 parameters")
	var same_params: bool = true
	for i in 21:
		if absf(float(params["parameters"][i]) - FSRS.PARAMETERS[i]) > 1e-12:
			same_params = false
	ok(same_params, "default parameters identical to py-fsrs")
	ok(is_equal_approx(float(params["desired_retention"]), FSRS.DESIRED_RETENTION), "desired retention")
	ok(int(params["learning_steps_sec"][0]) == 60 and int(params["learning_steps_sec"][1]) == 600 and params["learning_steps_sec"].size() == 2 and params["relearning_steps_sec"].size() == 1 and int(params["relearning_steps_sec"][0]) == 600, "step lists")
	ok(int(params["maximum_interval"]) == FSRS.MAXIMUM_INTERVAL, "maximum interval")
	ok(not bool(params["fuzz"]), "reference generated with fuzz off")

	var t0: int = int(doc["t0"])
	var steps_total := 0
	var states_seen := {}
	var max_stab_err := 0.0
	var max_diff_err := 0.0
	for cs in doc["cases"]:
		var card: Dictionary = FSRS.new_card(t0)
		var now: int = t0
		var n := 0
		for st in cs["steps"]:
			n += 1
			now += int(st["elapsed"])
			card = FSRS.review(card, int(st["rating"]), now, false)
			var tag := "%s #%d" % [cs["name"], n]
			var interval: int = int(card["due"]) - now
			var e_s: float = absf(float(card["stability"]) - float(st["stability"]))
			var e_d: float = absf(float(card["difficulty"]) - float(st["difficulty"]))
			max_stab_err = maxf(max_stab_err, e_s)
			max_diff_err = maxf(max_diff_err, e_d)
			ok(interval == int(st["interval"]), "%s interval %d vs %d" % [tag, interval, int(st["interval"])])
			ok(e_s < TOL, "%s stability %f vs %f" % [tag, card["stability"], st["stability"]])
			ok(e_d < TOL, "%s difficulty %f vs %f" % [tag, card["difficulty"], st["difficulty"]])
			ok(int(card["state"]) == int(st["state"]), "%s state %d vs %d" % [tag, card["state"], int(st["state"])])
			if int(st["state"]) != FSRS.State.REVIEW:
				ok(int(card["step"]) == int(st["step"]), "%s step" % tag)
			states_seen[int(st["state"])] = true
			steps_total += 1
	print("  %d cases, %d review steps, max |stability err| = %s, max |difficulty err| = %s" % [
		doc["cases"].size(), steps_total, str(max_stab_err), str(max_diff_err)])
	ok(doc["cases"].size() >= 20, "at least 20 sequences")
	ok(states_seen.size() == 3, "reference exercises Learning, Review and Relearning")


func _test_helpers() -> void:
	print("[helpers]")
	ok(FSRS._round_half_even(0.5) == 0 and FSRS._round_half_even(1.5) == 2 and FSRS._round_half_even(2.5) == 2 and FSRS._round_half_even(2.6) == 3, "round half to even (like Python)")
	# new card counters and lapses
	var t := 1_800_000_000
	var c: Dictionary = FSRS.new_card(t)
	ok(FSRS.is_new(c) and int(c["state"]) == FSRS.State.LEARNING and int(c["due"]) == t, "new_card")
	c = FSRS.review(c, 3, t, false)
	c = FSRS.review(c, 3, t + 600, false)
	ok(int(c["state"]) == FSRS.State.REVIEW and int(c["reps"]) == 2 and int(c["lapses"]) == 0 and not FSRS.is_new(c), "Good,Good graduates to Review, reps=2")
	c = FSRS.review(c, 1, int(c["due"]), false)
	ok(int(c["state"]) == FSRS.State.RELEARNING and int(c["lapses"]) == 1, "Again in Review -> Relearning, lapses=1")
	# preview does not mutate and gives 4 distinct outcomes for a new card
	var n0: Dictionary = FSRS.new_card(t)
	var pv: Dictionary = FSRS.preview(n0, t)
	ok(FSRS.is_new(n0) and pv.size() == 4, "preview leaves card untouched")
	ok(int(pv[1]["due"]) - t == 60 and int(pv[2]["due"]) - t == 330 and int(pv[3]["due"]) - t == 600 and int(pv[4]["due"]) - t >= FSRS.DAY, "new card preview: 1분 / 6분 / 10분 / >=1일")
	# fuzz stays inside py-fsrs' bounds (interval 20d -> delta 1+0.15*4.5+0.1*13 = 2.975 -> 17..23)
	var rev: Dictionary = {"due": t, "stability": 20.0, "difficulty": 5.0, "state": 2, "step": 0, "last_review": t - 20 * FSRS.DAY, "reps": 3, "lapses": 0}
	var base: int = int(FSRS.review(rev, 3, t, false)["due"]) - t
	ok(base >= 20 * FSRS.DAY and base < 60 * FSRS.DAY, "review interval grows (%d d)" % (base / FSRS.DAY))
	var lo := 1_000_000
	var hi := 0
	for r in [0.0, 0.25, 0.5, 0.75, 0.9999]:
		FSRS.fuzz_override = r
		var days: int = (int(FSRS.review(rev, 3, t, true)["due"]) - t) / FSRS.DAY
		lo = mini(lo, days)
		hi = maxi(hi, days)
	FSRS.fuzz_override = -1.0
	var center: int = base / FSRS.DAY
	ok(lo >= center - 6 and hi <= center + 6 and lo < hi, "fuzz varies the interval within bounds (%d..%d around %d)" % [lo, hi, center])
	ok(FSRS._fuzzed_days(2) == 2 and FSRS._fuzzed_days(1) == 1, "no fuzz below 2.5 days")
	# ensure_fields: legacy item becomes a new card, damaged fields are repaired
	var legacy := {"id": "x", "target": "Hi"}
	FSRS.ensure_fields(legacy, t)
	ok(int(legacy["due"]) == t and int(legacy["state"]) == 1 and legacy["id"] == "x", "legacy item -> new card due now")
	var broken := {"state": 2, "due": 5, "stability": "abc", "difficulty": null}
	FSRS.ensure_fields(broken, t)
	ok(int(broken["state"]) == 1 and int(broken["due"]) == t, "Review card without memory state restarts")
	# display
	ok(FSRS.format_interval(600) == "10분" and FSRS.format_interval(60) == "1분" and FSRS.format_interval(3 * 3600) == "3시간", "format minutes/hours")
	ok(FSRS.format_interval(FSRS.DAY) == "1일" and FSRS.format_interval(8 * FSRS.DAY) == "8일" and FSRS.format_interval(90 * FSRS.DAY) == "3개월" and FSRS.format_interval(730 * FSRS.DAY) == "2.0년", "format days/months/years")
