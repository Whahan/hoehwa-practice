extends Node
## StudyLog 저장·집계, PhonemeStats, StudyClock.tick, FixCards 테스트.
##   godot --headless --path <project> res://tests/study_log_test.tscn
## 종료 코드 0 = 전부 통과. 마지막 줄: "== study_log result: N passed, 0 failed =="
## 실제 user://studylog.json / progress.json / prefs.json 은 읽지도 쓰지도 않는다:
## Store.prefs_path / Store.progress_path / StudyLog.path 를 user://t1_test_* 로 바꿨다가 끝나면 원래 값으로 되돌린다.

const LOG_PATH := "user://t1_test_studylog.json"
const PROG_PATH := "user://t1_test_progress.json"
const PREFS_PATH := "user://t1_test_prefs.json"

var passed: int = 0
var failed: int = 0
var D: int = 0 ## fixed "today"
var _old_paths: Array = []
var _toasts: Array = []


func _ready() -> void:
	print("== study_log start ==")
	D = Plan.days_from_civil(2026, 10, 16)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	StudyLog.today_override = D
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	_cleanup()

	_test_broken_files()
	_test_future_version()
	_test_unreadable_and_bad_rotation()
	_test_score()
	_test_weak_and_save()
	_test_recording()
	_test_settle()
	_test_goal_and_clock()
	_test_fix_cards()

	_cleanup()
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk() ## empty state while the path is still the temp one
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	print("== study_log result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- helpers

func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_text(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func read_json(p: String) -> Variant:
	return JSON.parse_string(read_text(p)) if FileAccess.file_exists(p) else null


func rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".bad.1", LOG_PATH + ".bad.2", LOG_PATH + ".bad.3", LOG_PATH + ".tmp", PROG_PATH, PREFS_PATH]:
		rm(p)


func _fresh() -> void:
	## new empty state with no file on disk
	StudyLog.open_hook = Callable()
	_cleanup()
	StudyLog.today_override = D
	StudyLog.load_from_disk()


func fixture(name: String) -> Variant:
	var f := FileAccess.open("res://tests/" + name, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return JSON.parse_string(t)


func iso(offset: int) -> String:
	return Plan.days_to_iso(D + offset)


## a /score response with the given phoneme results: list of [p, ok] (one unit)
func resp(phs: Array, score: int = 80, transcript: String = "hello there") -> Dictionary:
	var ph: Array = []
	for pr in phs:
		ph.append({"p": pr[0], "ok": pr[1], "conf": 0.5, "heard": (pr[2] if pr.size() > 2 else null)})
	return {"transcript": transcript, "score": score, "accuracy": score, "clarity": score, "fluency": score, "units": [{"t": "x", "ok": true, "conf": 0.9, "heard": null, "ph": ph}]}


# ---------------------------------------------------------------- T1-2: broken files

func _test_broken_files() -> void:
	print("[broken files]")
	# (a) garbage text
	_cleanup()
	write_text(LOG_PATH, "this is { not json at all ]]")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "bad", "(a) garbage text: status 'bad'")
	ok(StudyLog.range_summary("en", 7).size() == 7 and int(StudyLog.range_summary("en", 7)[6]["sec"]) == 0, "(a) starts empty")
	ok(FileAccess.file_exists(LOG_PATH + ".bad") and read_text(LOG_PATH + ".bad").begins_with("this is"), "(a) the broken file was kept as .bad")
	ok(not FileAccess.file_exists(LOG_PATH), "(a) the original path is free again")
	StudyLog.add_seconds("en", "lesson", 10)
	ok(StudyLog.flush() and (read_json(LOG_PATH) is Dictionary) and int(read_json(LOG_PATH)["v"]) == 1, "(a) app keeps working: next save writes a valid file")
	# JSON that is not an object
	_cleanup()
	write_text(LOG_PATH, "[1, 2, 3]")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "bad" and FileAccess.file_exists(LOG_PATH + ".bad"), "(a2) a JSON array at top level is treated as broken")

	# (b) empty file
	_cleanup()
	write_text(LOG_PATH, "")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "empty" and StudyLog.tokens("en") == 1 and not StudyLog.has_data("en"), "(b) empty file: starts empty (1 token)")
	write_text(LOG_PATH, "   \n  ")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "empty", "(b) whitespace-only file counts as empty")

	# (d) days is an array
	_cleanup()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "days": [1, 2, {"x": 1}], "freeze": {"en": {"tokens": 2, "frozen": [], "awarded": 0}}}))
	StudyLog.load_from_disk()
	var sum_d: Array = StudyLog.range_summary("en", 30)
	var any_sec := 0
	for r in sum_d:
		any_sec += int(r["sec"])
	ok(any_sec == 0 and not StudyLog.has_data("en"), "(d) days as an array: ignored, empty state")
	ok(StudyLog.tokens("en") == 2, "(d) the rest of the file (freeze tokens=2) survives")

	# (e) sec as string / NaN / negative / huge / infinity
	_cleanup()
	var day_a: String = iso(0)
	var day_b: String = iso(-1)
	var day_c: String = iso(-2)
	var day_d: String = iso(-3)
	write_text(LOG_PATH, '{"v":1,"days":{"%s":{"en":{"sec":"abc","by":{"lesson":"x"},"n":{"lessons":"7"},"lesson":["a",3],"score":[-5,"z"]}},"%s":{"en":{"sec":-50}},"%s":{"en":{"sec":1e999}},"%s":{"en":{"sec":120,"lesson":[9,4],"score":[2,999]}},"not-a-date":{"en":{"sec":5}},"2026-02-31":{"en":{"sec":5}}}}' % [day_a, day_b, day_c, day_d])
	StudyLog.load_from_disk()
	var rs: Array = StudyLog.range_summary("en", 4)
	ok(int(rs[3]["sec"]) == 0 and int(rs[3]["lessons_ok"]) == 0 and int(rs[3]["lessons_n"]) == 3 and int(rs[3]["score_n"]) == 0 and int(rs[3]["score_sum"]) == 0 and int(rs[3]["n"]["lessons"]) == 0, "(e) string/negative numbers on a day -> 0 (valid 3 kept)")
	ok(int(rs[2]["sec"]) == 0, "(e) negative sec -> 0")
	ok(int(rs[1]["sec"]) == 0, "(e) infinite sec -> 0")
	ok(int(rs[0]["sec"]) == 120 and int(rs[0]["lessons_ok"]) <= int(rs[0]["lessons_n"]) and int(rs[0]["score_sum"]) <= int(rs[0]["score_n"]) * 100, "(e) valid day kept, impossible pairs clamped (ok<=total, score sum<=100*count)")
	var norm: Dictionary = StudyLog._normalize({"v": "9", "saved": NAN, "days": {iso(0): {"en": {"sec": NAN, "by": {"x": INF}, "n": {"shadow": -INF}, "lesson": [NAN, 5], "score": [1, NAN]}}}})
	var rec: Dictionary = norm["days"][iso(0)]["en"]
	ok(int(rec["sec"]) == 0 and int(norm["v"]) == 1 and int(norm["saved"]) == 0 and (rec["by"] as Dictionary).is_empty() and (rec["n"] as Dictionary).is_empty(), "(e) NaN / inf directly in memory -> 0 (and v 'abc' -> 1)")
	ok(int((rec["lesson"] as Array)[0]) == 0 and int((rec["score"] as Array)[1]) == 0, "(e) NaN inside pairs -> 0")
	ok(not (norm["days"] as Dictionary).has("not-a-date"), "(e) bad date keys are dropped")

	# (f) phon h is a number / list / missing
	_cleanup()
	write_text(LOG_PATH, '{"v":1,"phon":{"en":{"θ":{"h":12345,"heard":{"s":"x"}},"r":{"h":["1","0"]},"ɹ":{"h":"01x1 1","heard":{"w":3,"":2}},"f":"nope","ð":{"h":"11111","heard":5}},"ja":[]}}')
	StudyLog.load_from_disk()
	var snap: Dictionary = StudyLog.snapshot()
	var pe: Dictionary = snap["phon"]["en"]
	ok(pe.has("θ") and pe["θ"]["h"] == "" and (pe["θ"]["heard"] as Dictionary).is_empty(), "(f) numeric h -> empty history, bad heard count dropped")
	ok(pe["r"]["h"] == "", "(f) list h -> empty")
	ok(pe["ɹ"]["h"] == "0111" and pe["ɹ"]["heard"] == {"w": 3}, "(f) odd characters removed from h ('01x1 1' -> '0111'), empty heard key dropped")
	ok(not pe.has("f") and pe["ð"]["h"] == "11111" and (pe["ð"]["heard"] as Dictionary).is_empty(), "(f) non-dict entry dropped; heard=5 -> {}")
	ok(StudyLog.weak_phonemes("en", 5).size() == 1 and StudyLog.weak_phonemes("en", 5)[0]["p"] == "ð", "(f) only the sound with enough samples is a weak sound (ð 5/5)")
	ok((snap["phon"]["ja"] as Dictionary).is_empty(), "(f) phon.ja as an array -> empty")


# ---------------------------------------------------------------- T1-2 (c): future version

func _test_future_version() -> void:
	print("[newer version file]")
	_cleanup()
	var src: String = read_text("res://tests/sample_studylog_v99.json")
	write_text(LOG_PATH, src)
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok", "(c) v:99 loads")
	ok(int(StudyLog.range_summary("en", 2)[0]["sec"]) == 600, "(c) known data readable (yesterday 600 s)")
	ok(StudyLog.tokens("en") == 2, "(c) known freeze data readable")
	StudyLog.add_seconds("en", "talk", 30)
	ok(StudyLog.flush(), "(c) saves")
	var back: Variant = read_json(LOG_PATH)
	ok(back is Dictionary and (back as Dictionary).has("future_feature") and back["future_feature"]["nested"]["b"] == "keep me" and int(back["future_feature"]["level"]) == 7, "(c) unknown top-level key preserved with its content")
	ok(back is Dictionary and back["sync_marker"] == "x1", "(c) second unknown key preserved")
	ok(int(back["v"]) == 99, "(c) the newer 'v' is kept so the newer app still recognises its file")
	ok(int(back["days"][iso(0)]["en"]["sec"]) == 30 and int(back["days"][iso(-1)]["en"]["sec"]) == 600, "(c) known data written back with the new second counts")
	# unknown keys survive a reload + second save too
	StudyLog.load_from_disk()
	StudyLog.add_seconds("en", "talk", 5)
	StudyLog.flush()
	ok((read_json(LOG_PATH) as Dictionary).has("future_feature"), "(c) still there after reload and another save")


# ---------------------------------------------------------------- unreadable file / .bad rotation

func _test_unreadable_and_bad_rotation() -> void:
	print("[unreadable file: never overwrite the original]")
	_cleanup()
	StudyLog.today_override = D
	var good: String = JSON.stringify({"v": 1, "saved": 5, "days": {iso(-1): {"en": {"sec": 600, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}}}})
	write_text(LOG_PATH, good)
	# the file exists but opening it fails (locked by another program): simulated with the open hook
	StudyLog.open_hook = func(_p: String) -> Variant: return null
	_toasts.clear()
	StudyLog.load_from_disk()
	StudyLog.open_hook = Callable()
	ok(StudyLog.last_load_status == "unreadable" and StudyLog.is_read_only(), "(g) file exists but cannot be opened: status 'unreadable', read-only for this run")
	ok(not StudyLog.has_data("en") and StudyLog.today_seconds("en") == 0, "(g) the run starts with an empty state")
	ok(_toasts.size() == 1 and "저장하지 않" in _toasts[0], "(g) the user is told that nothing will be saved (%s)" % str(_toasts))
	StudyLog.add_seconds("en", "lesson", 30)
	StudyLog.add_lesson("en", 3, 4)
	ok(StudyLog.is_dirty() and not StudyLog.flush(), "(g) recording works in memory, flush() refuses to write")
	ok(read_text(LOG_PATH) == good, "(g) the original file is byte-for-byte unchanged after flush()")
	StudyLog.reset()
	ok(read_text(LOG_PATH) == good, "(g) reset() does not overwrite it either")
	ok(not FileAccess.file_exists(LOG_PATH + ".tmp") and not FileAccess.file_exists(LOG_PATH + ".bad"), "(g) no temp / .bad leftovers")
	# next run: readable again -> the old data is there and saving works
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok" and not StudyLog.is_read_only() and int(StudyLog.range_summary("en", 2)[0]["sec"]) == 600, "(g) next load: readable, old data (600 s yesterday) is still there")
	StudyLog.add_seconds("en", "lesson", 5)
	ok(StudyLog.flush() and int(read_json(LOG_PATH)["days"][iso(-1)]["en"]["sec"]) == 600, "(g) saving works again and keeps the old data")
	# a missing file is not 'unreadable'
	_cleanup()
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "new" and not StudyLog.is_read_only(), "(g) missing file: normal empty start, saving allowed")
	StudyLog.add_seconds("en", "lesson", 5)
	ok(StudyLog.flush(), "(g) ...and it saves")

	print("[.bad files: up to 3 kept]")
	_cleanup()
	for n in range(1, 4):
		write_text(LOG_PATH, "broken number %d {" % n)
		StudyLog.load_from_disk()
	ok(read_text(LOG_PATH + ".bad").begins_with("broken number 3") and read_text(LOG_PATH + ".bad.1").begins_with("broken number 2") and read_text(LOG_PATH + ".bad.2").begins_with("broken number 1"), "(h) three breakages: .bad = newest, .bad.1, .bad.2 = older ones")
	write_text(LOG_PATH, "broken number 4 {")
	StudyLog.load_from_disk()
	ok(read_text(LOG_PATH + ".bad").begins_with("broken number 4") and read_text(LOG_PATH + ".bad.1").begins_with("broken number 3") and read_text(LOG_PATH + ".bad.2").begins_with("broken number 2"), "(h) a fourth one shifts them; the oldest (1) is dropped")
	ok(not FileAccess.file_exists(LOG_PATH + ".bad.3") and not FileAccess.file_exists(LOG_PATH), "(h) never more than 3 files, original path free")
	_cleanup()


# ---------------------------------------------------------------- T1-3: add_score

func _test_score() -> void:
	print("[add_score]")
	_fresh()
	var sample: Variant = fixture("sample_score_en_ph.json")
	ok(StudyLog.add_score("en", sample, "lesson"), "sample_score_en_ph.json is aggregated (returns true)")
	var snap: Dictionary = StudyLog.snapshot()
	var theta: Dictionary = snap["phon"]["en"]["θ"]
	ok(theta["h"] == "1" and theta["heard"] == {"s": 1}, "θ entry: one miss, heard 's'")
	ok(snap["phon"]["en"].has("æ") and snap["phon"]["en"]["æ"]["h"] == "0", "æ entry: one hit")
	var today_rec: Dictionary = snap["days"][iso(0)]["en"]
	ok(today_rec["score"] == [1, 100], "score pair is [1, 100]")
	# fixed-size history
	for i in range(40):
		StudyLog.add_score("en", resp([["θ", i % 2 == 0]]), "lesson")
	ok(StudyLog.snapshot()["phon"]["en"]["θ"]["h"].length() == 30, "history is capped at the last 30 results")

	_fresh()
	var before: Dictionary = StudyLog.snapshot()
	var bad_inputs := {
		"empty dict": {},
		"no units": {"transcript": "hello", "score": 80},
		"units not an array": {"transcript": "hello", "score": 80, "units": "x"},
		"units is a dict": {"transcript": "hello", "score": 80, "units": {"a": 1}},
		"empty transcript": {"transcript": "", "score": 0, "units": []},
		"blank transcript": {"transcript": "   ", "score": 55, "units": [{"t": "a", "ph": [{"p": "θ", "ok": false}]}]},
		"transcript null": {"transcript": null, "score": 55, "units": []},
		"score missing": {"transcript": "hi", "units": []},
		"score a string": {"transcript": "hi", "score": "high", "units": []},
	}
	for name in bad_inputs.keys():
		var r: bool = StudyLog.add_score("en", bad_inputs[name], "lesson")
		ok(not r and StudyLog.snapshot() == before, "not aggregated and state unchanged: %s" % name)
	ok(not StudyLog.add_score_any("en", null, "x") and not StudyLog.add_score_any("en", "text", "x") and not StudyLog.add_score_any("en", [1, 2], "x"), "null / string / array response -> false, no error")
	ok(not StudyLog.add_score("xx", resp([["θ", false]]), "x"), "unknown language -> false")
	ok(StudyLog.snapshot() == before and not StudyLog.is_dirty(), "after all that, the log is still untouched")
	# ph entries that are unusable: score counts, phonemes do not
	var odd: Dictionary = {"transcript": "ok then", "score": 70, "units": [
		{"t": "ok", "ph": [{"ok": true}, {"p": "", "ok": false}, {"p": 5, "ok": true}, {"p": "k"}, "junk", {"p": "k", "ok": "yes"}]},
		"not a dict", {"t": "x", "ph": "nope"}, {"t": "y"}]}
	ok(StudyLog.add_score("en", odd, "lesson"), "response with unusable ph entries still counts the score")
	ok((StudyLog.snapshot()["phon"]["en"] as Dictionary).is_empty(), "...but records no phoneme (no p / empty p / non-string p / missing or non-boolean ok)")
	ok(StudyLog.snapshot()["days"][iso(0)]["en"]["score"] == [1, 70], "score pair [1, 70]")
	# score range
	StudyLog.add_score("en", resp([], 250), "x")
	StudyLog.add_score("en", resp([], -40), "x")
	ok(StudyLog.snapshot()["days"][iso(0)]["en"]["score"] == [3, 170], "scores are clamped to 0..100 (70 + 100 + 0)")
	# Japanese uses its own phoneme table
	ok(StudyLog.add_score("ja", fixture("sample_score_ja_ph.json"), "shadow"), "Japanese sample is aggregated for ja")
	ok(StudyLog.snapshot()["days"][iso(0)].has("ja"), "...into the ja record")


# ---------------------------------------------------------------- T1-4: weak sounds, saving, pruning, reset

func _test_weak_and_save() -> void:
	print("[weak sounds / pruning / reset]")
	_fresh()
	# θ 10 samples 6 bad (60 %), ɹ 5 samples 3 bad (60 %), f 4 samples 4 bad, s 5 samples 1 bad, z 6 samples 0 bad, ʃ 5 samples 4 bad
	var plan := {"θ": "0101010111", "ɹ": "01101", "f": "1111", "s": "00010", "z": "000000", "ʃ": "11011"}
	var order := ["θ", "ɹ", "f", "s", "z", "ʃ"]
	for p in order:
		for ch in (plan[p] as String):
			StudyLog.add_score("en", resp([[p, ch == "0"]]), "t")
	var w: Array = StudyLog.weak_phonemes("en", 10)
	var names: Array = []
	for e in w:
		names.append(e["p"])
	ok(names == ["ʃ", "θ", "ɹ", "s"], "default min_n=5: ʃ(80 pct) θ(60 pct,10) ɹ(60 pct,5) s(20 pct); f has only 4 samples, z never missed -> got %s" % str(names))
	ok(w[1]["n"] == 10 and w[1]["bad"] == 6 and is_equal_approx(float(w[1]["rate"]), 0.6), "entry fields n=10 bad=6 rate=0.6")
	ok(StudyLog.weak_phonemes("en", 2).size() == 2 and StudyLog.weak_phonemes("en", 2)[1]["p"] == "θ", "limit applies")
	var names4: Array = []
	for e in StudyLog.weak_phonemes("en", 10, 4):
		names4.append(e["p"])
	ok(names4 == ["f", "ʃ", "θ", "ɹ", "s"], "min_n=4 lets f (100 pct) in at the top -> got %s" % str(names4))
	ok(StudyLog.weak_phonemes("en", 0).is_empty() and StudyLog.weak_phonemes("xx", 3).is_empty() and StudyLog.weak_phonemes("ja", 3).is_empty(), "limit 0 / unknown lang / other language -> empty")
	# heard counts
	for i in range(3):
		StudyLog.add_score("en", resp([["ʃ", false, "s"]]), "t")
	StudyLog.add_score("en", resp([["ʃ", false, "ʃ"], ["ʃ", false, ""], ["ʃ", false, null]]), "t")
	ok(StudyLog.weak_phonemes("en", 1)[0]["heard"] == {"s": 3}, "'heard' counts only substituted sounds (not the same sound, empty or null)")

	# save / reload round trip
	ok(StudyLog.flush() and not StudyLog.is_dirty(), "flush writes")
	var before: Dictionary = StudyLog.snapshot()
	StudyLog.load_from_disk()
	var after: Dictionary = StudyLog.snapshot()
	after["saved"] = before["saved"]
	ok(after == before, "reload gives the same data")
	ok(not StudyLog.flush(), "flush with nothing changed writes nothing (false)")

	# pruning of old days at save time
	_fresh()
	for off in [-500, -401, -400, -399, -1, 0]:
		StudyLog.today_override = D + off
		StudyLog.add_seconds("en", "lesson", 7)
	StudyLog.today_override = D
	ok(StudyLog.flush(), "flush with old days")
	var days: Dictionary = (read_json(LOG_PATH) as Dictionary)["days"]
	ok(not days.has(iso(-500)) and not days.has(iso(-401)) and not days.has(iso(-400)), "days older than 400 days are deleted when saving (-500, -401, -400)")
	ok(days.has(iso(-399)) and days.has(iso(-1)) and days.has(iso(0)), "day -399 (the 400th) and recent days stay")
	ok(StudyLog.snapshot()["days"].size() == 3, "memory pruned as well")

	# reset
	StudyLog.add_seconds("en", "lesson", 5)
	StudyLog.add_mission("en", "cafe_order", 2, 3)
	StudyLog.reset()
	var disk: Variant = read_json(LOG_PATH)
	ok(disk is Dictionary and (disk["days"] as Dictionary).is_empty() and (disk["missions"] as Dictionary).is_empty() and (disk["phon"]["en"] as Dictionary).is_empty(), "reset() leaves a file with no records")
	ok(StudyLog.range_summary("en", 3)[2]["sec"] == 0 and StudyLog.tokens("en") == 1 and not StudyLog.has_data("en") and not StudyLog.is_dirty(), "reset(): empty state, tokens back to the starting 1")
	# reset also drops unknown keys
	write_text(LOG_PATH, '{"v":3,"keep":{"a":1}}')
	StudyLog.load_from_disk()
	StudyLog.reset()
	ok(not (read_json(LOG_PATH) as Dictionary).has("keep"), "reset() also removes unknown keys")

	# limit of 80 sounds per language
	_fresh()
	var many: Array = []
	for i in range(100):
		many.append(["p%d" % i, false])
	StudyLog.add_score("en", resp(many), "t")
	ok((StudyLog.snapshot()["phon"]["en"] as Dictionary).size() == 80, "at most 80 sounds per language (got %d)" % (StudyLog.snapshot()["phon"]["en"] as Dictionary).size())


# ---------------------------------------------------------------- recording functions

func _test_recording() -> void:
	print("[recording functions]")
	_fresh()
	StudyLog.add_seconds("en", "lesson", 60)
	StudyLog.add_seconds("en", "talk", 30)
	StudyLog.add_seconds("en", "weird-view", 10)
	StudyLog.add_seconds("en", "lesson", 0)
	StudyLog.add_seconds("en", "lesson", -5)
	StudyLog.add_seconds("xx", "lesson", 5)
	StudyLog.add_seconds("ja", "lesson", 20)
	ok(StudyLog.today_seconds("en") == 100 and StudyLog.today_seconds("ja") == 20 and StudyLog.today_seconds("xx") == 0, "seconds add up per language; zero/negative/unknown language ignored")
	var by: Dictionary = StudyLog.snapshot()["days"][iso(0)]["en"]["by"]
	ok(by == {"lesson": 60, "talk": 30, "other": 10}, "per view: unknown view names go to 'other' -> %s" % str(by))
	StudyLog.add_seconds("en", "lesson", 999999)
	ok(StudyLog.today_seconds("en") == 86400, "a day cannot exceed 86400 s")

	_fresh()
	StudyLog.add_event("en", "shadow", 2)
	StudyLog.add_event("en", "shadow")
	StudyLog.add_event("en", "bogus", 5)
	StudyLog.add_event("en", "drill", 0)
	StudyLog.add_event("en", "missions", -3)
	StudyLog.add_event("xx", "shadow", 1)
	StudyLog.add_lesson("en", 8, 10)
	StudyLog.add_lesson("en", 15, 10)
	StudyLog.add_lesson("en", 3, 0)
	StudyLog.add_lesson("en", -2, 5)
	var row: Dictionary = StudyLog.range_summary("en", 1)[0]
	ok(row["n"]["shadow"] == 3 and row["n"]["drill"] == 0 and row["n"]["missions"] == 0 and not row["n"].has("bogus"), "events: valid kinds counted, unknown/zero/negative ignored")
	ok(row["lessons_ok"] == 8 + 10 + 0 and row["lessons_n"] == 25 and row["n"]["lessons"] == 3, "lessons: ok clamped to total, total<=0 ignored, each valid lesson counts once (ok=%d n=%d lessons=%d)" % [row["lessons_ok"], row["lessons_n"], row["n"]["lessons"]])

	var rs: Array = StudyLog.range_summary("en", 7)
	ok(rs.size() == 7 and rs[6]["iso"] == iso(0) and rs[0]["iso"] == iso(-6), "range_summary: 7 entries, oldest first, ending today")
	ok(StudyLog.range_summary("en", 0).is_empty() and StudyLog.range_summary("xx", 7).is_empty() and StudyLog.range_summary("en", 9999).size() == 400, "range_summary: 0 days / unknown language -> empty, capped at 400")
	var keys_ok := true
	for k in ["iso", "sec", "lessons_ok", "lessons_n", "score_n", "score_sum", "n"]:
		keys_ok = keys_ok and rs[0].has(k)
	ok(keys_ok and rs[0]["n"].has("reviews"), "range_summary entries have all keys, n has every kind")

	_fresh()
	ok(StudyLog.mission_best("cafe_order").is_empty(), "mission_best of an unplayed mission is {}")
	StudyLog.add_mission("en", "cafe_order", 2, 3)
	StudyLog.add_mission("en", "cafe_order", 1, 2)
	StudyLog.add_mission("en", "cafe_order", 9, 99999)
	StudyLog.add_mission("en", "", 3, 1)
	StudyLog.add_mission("xx", "x", 3, 1)
	var mb: Dictionary = StudyLog.mission_best("cafe_order")
	ok(mb["stars"] == 3 and mb["plays"] == 3 and mb["last"] == iso(0) and mb["done_goals"] == 1000, "best stars kept (max, clamped to 3), plays counted, last = today, done_goals clamped -> %s" % str(mb))
	ok(StudyLog.mission_ids() == ["cafe_order"], "empty id / unknown language ignored")
	mb["stars"] = 0
	ok(StudyLog.mission_best("cafe_order")["stars"] == 3, "mission_best returns a copy")
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.mission_best("cafe_order")["plays"] == 3, "missions survive a reload")


# ---------------------------------------------------------------- settle with Store.progress

func _test_settle() -> void:
	print("[settle / streak with progress days]")
	_fresh()
	Store.progress = Progress.blank()
	for off in [-3, -2, -1]:
		Store.progress["days"][iso(off)] = {"en": true}
	ok(StudyLog.streak("en") == 3 and StudyLog.tokens("en") == 1, "3 days through yesterday: streak 3, starting token 1")
	ok(StudyLog.streak("ja") == 0, "other language has no streak")

	# missed yesterday: the token bridges it
	Store.progress = Progress.blank()
	for off in [-4, -3, -2]:
		Store.progress["days"][iso(off)] = {"en": true}
	_toasts.clear()
	var s1: Dictionary = StudyLog.settle("en")
	ok(s1["streak"] == 3 and s1["tokens"] == 0 and s1["used"] == 1, "missed 1 day: token used, streak 3 -> %s" % str(s1))
	ok(_toasts.size() == 1 and "보호권" in _toasts[0], "a toast tells about the used token (%s)" % str(_toasts))
	var s2: Dictionary = StudyLog.settle("en")
	ok(s2["streak"] == 3 and s2["tokens"] == 0 and s2["used"] == 0 and _toasts.size() == 1, "settle twice the same day: same result, no second toast")
	ok(StudyLog.is_dirty(), "the use of a token is marked for saving")
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.tokens("en") == 0 and StudyLog.streak("en") == 3, "protection survives save/reload (no second charge)")
	var fz: Array = StudyLog.snapshot()["freeze"]["en"]["frozen"]
	ok(fz == [iso(-1)], "frozen day recorded: %s" % str(fz))

	# the next day without study: gap is 2 (but 1 day already frozen, 0 tokens) -> breaks and the spent token is returned
	StudyLog.today_override = D + 1
	var s3: Dictionary = StudyLog.settle("en")
	ok(s3["streak"] == 0 and s3["tokens"] == 1, "next day also missed with no token: streak 0, the token spent on the first gap comes back")
	StudyLog.today_override = D

	# clock moved back: nothing changes
	StudyLog.load_from_disk()
	var snap_before: Dictionary = StudyLog.snapshot()
	StudyLog.today_override = D - 10
	var s4: Dictionary = StudyLog.settle("en")
	ok(s4["used"] == 0 and s4["gained"] == 0 and StudyLog.snapshot() == snap_before, "clock set back 10 days: nothing spent or paid, state untouched")
	StudyLog.today_override = D

	# 7-day run pays a token, only once
	_fresh()
	Store.progress = Progress.blank()
	for off in range(-6, 1):
		Store.progress["days"][iso(off)] = {"en": true}
	_toasts.clear()
	var s5: Dictionary = StudyLog.settle("en")
	ok(s5["streak"] == 7 and s5["tokens"] == 2 and s5["gained"] == 1, "7 days: +1 token (1 -> 2)")
	var s6: Dictionary = StudyLog.settle("en")
	ok(s6["gained"] == 0 and s6["tokens"] == 2, "...only once")
	Store.progress = Progress.blank()

	# clock jumps T-3 -> T-2 -> T+200 -> T-2: the 7-day token is paid once, never a second time
	_cleanup()
	StudyLog.today_override = D
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 0, "frozen": [], "awarded": 0}}}))
	StudyLog.load_from_disk()
	Store.progress = Progress.blank()
	for off in range(-8, -1):
		Store.progress["days"][iso(off)] = {"en": true}
	_toasts.clear()
	StudyLog.today_override = D - 3
	var j1: Dictionary = StudyLog.settle("en")
	ok(j1["streak"] == 6 and j1["tokens"] == 0 and j1["gained"] == 0, "jump 1 (T-3): 6 days so far, no token -> %s" % str(j1))
	StudyLog.today_override = D - 2
	var j2: Dictionary = StudyLog.settle("en")
	ok(j2["streak"] == 7 and j2["tokens"] == 1 and j2["gained"] == 1, "jump 2 (T-2): 7 days -> +1 token -> %s" % str(j2))
	StudyLog.today_override = D + 200
	var j3: Dictionary = StudyLog.settle("en")
	ok(j3["streak"] == 0 and j3["tokens"] == 1 and j3["gained"] == 0, "jump 3 (T+200): 200 days without study -> streak 0, token kept -> %s" % str(j3))
	StudyLog.today_override = D - 2
	var j4: Dictionary = StudyLog.settle("en")
	ok(j4["gained"] == 0 and j4["used"] == 0 and j4["tokens"] == 1, "jump 4 (back to T-2): no second payment, nothing spent -> %s" % str(j4))
	ok(j4["streak"] == 7, "...the streak is still shown (7)")
	var paid := 0
	for t in _toasts:
		if "받았어요" in t:
			paid += 1
	ok(paid == 1, "only one 'token received' toast in the whole sequence (got %d)" % paid)
	StudyLog.today_override = D - 1
	var j5: Dictionary = StudyLog.settle("en")
	ok(j5["gained"] == 0 and j5["tokens"] == 1, "even a later day of the rewound timeline (T-1) pays nothing while the clock is behind the latest settled day -> %s" % str(j5))
	StudyLog.flush()
	StudyLog.load_from_disk()
	StudyLog.today_override = D - 2
	ok(StudyLog.tokens("en") == 1 and StudyLog.settle("en")["gained"] == 0, "after save and reload the token count is still 1")
	StudyLog.today_override = D + 300
	var j6: Dictionary = StudyLog.settle("en")
	ok(j6["tokens"] == 1 and j6["gained"] == 0, "once the clock is ahead again settle works normally (no study since: streak %d, tokens 1)" % int(j6["streak"]))
	StudyLog.today_override = D
	Store.progress = Progress.blank()


# ---------------------------------------------------------------- goal, StudyClock

func _test_goal_and_clock() -> void:
	print("[goal / StudyClock]")
	Store.load_prefs()
	Store.prefs.erase("daily_goal_min")
	ok(StudyLog.goal_minutes() == 10, "default goal is 10 minutes")
	StudyLog.set_goal_minutes(20)
	ok(StudyLog.goal_minutes() == 20 and int(Store.prefs["daily_goal_min"]) == 20, "set_goal_minutes(20)")
	StudyLog.set_goal_minutes(0)
	ok(StudyLog.goal_minutes() == 0, "0 = off")
	StudyLog.set_goal_minutes(99999)
	ok(StudyLog.goal_minutes() == 240, "goal is capped at 240")
	Store.prefs["daily_goal_min"] = "ten"
	ok(StudyLog.goal_minutes() == 10, "a broken pref falls back to the default")
	Store.prefs["daily_goal_min"] = 0

	# --- tick
	_fresh()
	Store.progress = Progress.blank()
	var clock := StudyClock.new()
	clock.lang_override = "en"
	clock.view_override = "lesson"
	ok(clock.tick(30.0, false) == 0 and StudyLog.today_seconds("en") == 0, "not active (no input / window not focused): no seconds")
	ok(clock.tick(4.0, true) == 0 and StudyLog.today_seconds("en") == 0, "4 s active: still waiting for the 5 s step")
	ok(clock.tick(1.0, true) == 5 and StudyLog.today_seconds("en") == 5, "5 s reached -> 5 s written")
	ok(clock.tick(12.0, true) == 10 and StudyLog.today_seconds("en") == 15, "12 s -> two steps (10 s), 2 s carried")
	ok(clock.tick(3.0, true) == 5 and StudyLog.today_seconds("en") == 20, "2 s carried + 3 s = another step")
	clock.tick(3.0, true)
	clock.tick(3.0, false)
	ok(clock.tick(3.0, true) == 0 and clock.tick(1.0, true) == 0 and clock.tick(1.0, true) == 5, "an idle stretch drops the partial step")
	var sec_now: int = StudyLog.today_seconds("en")
	ok(clock.tick(0.0, true) == 0 and clock.tick(-5.0, true) == 0 and clock.tick(NAN, true) == 0 and StudyLog.today_seconds("en") == sec_now, "zero / negative / NaN delta add nothing")
	ok(clock.tick(100000.0, true) <= 15 and StudyLog.today_seconds("en") <= sec_now + 15, "a huge gap (sleep/pause) counts at most 15 s")
	var by: Dictionary = StudyLog.snapshot()["days"][iso(0)]["en"]["by"]
	ok(by.has("lesson") and by.size() == 1, "seconds are filed under the current view (lesson)")

	# midnight
	_fresh()
	var clock2 := StudyClock.new()
	clock2.lang_override = "en"
	clock2.view_override = "talk"
	clock2.tick(5.0, true)
	StudyLog.today_override = D + 1
	clock2.tick(5.0, true)
	clock2.tick(5.0, true)
	var days: Dictionary = StudyLog.snapshot()["days"]
	ok(days[iso(0)]["en"]["sec"] == 5 and days[iso(1)]["en"]["sec"] == 10, "after midnight the seconds go to the new date (5 s on day 1, 10 s on day 2)")
	ok(StudyLog.today_seconds("en") == 10, "today_seconds follows the date")
	StudyLog.today_override = D

	# is_active composition
	var c3 := StudyClock.new()
	c3.focus_override = 0
	c3._last_input_msec = Time.get_ticks_msec()
	ok(not c3.is_active(), "window without focus: never active, even with fresh input")
	c3.focus_override = 1
	c3._last_input_msec = Time.get_ticks_msec()
	ok(c3.is_active(), "focused + input just now: active")
	c3._last_input_msec = Time.get_ticks_msec() - 46000
	ok(not c3.is_active(), "focused but no input for 46 s: idle")
	Api.active_count += 1
	ok(c3.is_active(), "...but a request in flight keeps it active")
	Api.active_count -= 1
	ok(not c3.is_active(), "request done: idle again")
	c3.free()

	# reaching the goal
	_fresh()
	Store.progress = Progress.blank()
	Store.prefs["daily_goal_min"] = 1
	_toasts.clear()
	var clock4 := StudyClock.new()
	clock4.lang_override = "en"
	clock4.view_override = "lesson"
	for i in range(11):
		clock4.tick(5.0, true)
	ok(_toasts.size() == 0 and not Store.did_day(Plan.today_days(), "en"), "55 s of a 60 s goal: no toast yet")
	clock4.tick(5.0, true)
	ok(_toasts.size() == 1 and "1분" in _toasts[0], "60 s: goal toast once (%s)" % str(_toasts))
	ok(Store.did_day(Plan.today_days(), "en"), "...and today is marked as studied")
	clock4.tick(5.0, true)
	ok(_toasts.size() == 1, "no second toast after the goal")
	Store.prefs["daily_goal_min"] = 0
	_fresh()
	var clock5 := StudyClock.new()
	clock5.lang_override = "ja"
	for i in range(20):
		clock5.tick(5.0, true)
	ok(StudyLog.today_seconds("ja") == 100 and _toasts.size() == 1, "goal off: counts time, no toast")
	Store.prefs.erase("daily_goal_min")
	for c in [clock, clock2, clock4, clock5]:
		c.free()

	# lowering the goal below the time already studied today: judged right away (tick() never crosses it again)
	_fresh()
	Store.progress = Progress.blank()
	StudyClock._celebrated.clear()
	Store.prefs["daily_goal_min"] = 20
	StudyLog.add_seconds("en", "lesson", 720)
	_toasts.clear()
	ok(not StudyClock.check_goal("en") and _toasts.is_empty(), "12 min studied, goal 20: check_goal does nothing")
	StudyLog.set_goal_minutes(10)
	ok(StudyClock.check_goal("en") and _toasts.size() == 1 and "10분" in _toasts[0], "goal lowered to 10 (already 12 min): toast right away (%s)" % str(_toasts))
	ok(Store.did_day(Plan.today_days(), "en"), "...and today is marked as studied")
	ok(not StudyClock.check_goal("en") and _toasts.size() == 1, "asking again: no second toast")
	StudyLog.set_goal_minutes(5)
	ok(not StudyClock.check_goal("en") and _toasts.size() == 1, "goal lowered further after the toast: still no repeat")
	StudyLog.set_goal_minutes(0)
	ok(not StudyClock.check_goal("en"), "goal off: nothing to judge")
	StudyLog.set_goal_minutes(15)
	var clock6 := StudyClock.new()
	clock6.lang_override = "en"
	clock6.view_override = "lesson"
	for i in range(35):
		clock6.tick(5.0, true)
	ok(_toasts.size() == 1, "raised to 15: 14:55 studied, not yet")
	clock6.tick(5.0, true)
	ok(_toasts.size() == 2 and "15분" in _toasts[1], "a harder goal reached later is announced once more (%s)" % str(_toasts))
	clock6.free()
	Store.prefs.erase("daily_goal_min")
	StudyClock._celebrated.clear()


# ---------------------------------------------------------------- T1-7: FixCards

func _test_fix_cards() -> void:
	print("[FixCards]")
	Store.progress = Progress.blank()
	Store.prefs.erase("auto_fix_cards")
	FixCards.reset_counter()
	var m1 := {"role": "me", "text": "I go school yesterday", "fix": "I went to school yesterday.", "fix_ko": "과거형 went 를 써요."}
	ok(FixCards.add("en", m1, "c1") == 1 and Store.review_for("en").size() == 1, "a fix becomes one review card")
	var card: Dictionary = Store.review_for("en")[0]
	ok(card["target"] == "I went to school yesterday." and card["note"] == "과거형 went 를 써요.", "card target = fixed sentence, note = explanation")
	ok(FixCards.add("en", m1, "c1") == 0 and Store.review_for("en").size() == 1, "the same sentence twice -> still 1 card")
	ok(FixCards.add("en", {"text": "Hello", "fix": "Hello!", "fix_ko": "x"}, "c1") == 0, "fix equal to the original (ignoring case/punctuation) -> not added")
	ok(FixCards.add("en", {"text": "Hello", "fix": "", "fix_ko": "x"}, "c1") == 0 and FixCards.add("en", {"text": "Hello"}, "c1") == 0, "empty / missing fix -> not added")
	ok(FixCards.add("xx", m1, "c1") == 0, "unknown language -> not added")
	# 8 per conversation
	FixCards.reset_counter()
	Store.progress = Progress.blank()
	var added := 0
	for i in range(12):
		added += FixCards.add("en", {"text": "bad sentence %d" % i, "fix": "Better sentence number %d." % i, "fix_ko": ""}, "conv-A")
	ok(added == 8 and Store.review_for("en").size() == 8, "one conversation adds at most 8 cards (got %d)" % added)
	var added_b := FixCards.add("en", {"text": "another", "fix": "Another fixed sentence.", "fix_ko": ""}, "conv-B")
	ok(added_b == 1, "a new conversation id starts a new count")
	# duplicates do not use up the 8
	FixCards.reset_counter()
	Store.progress = Progress.blank()
	for i in range(20):
		FixCards.add("en", {"text": "bad", "fix": "Same fixed sentence.", "fix_ko": ""}, "conv-C")
	ok(Store.review_for("en").size() == 1, "20 identical fixes -> 1 card")
	var more := 0
	for i in range(10):
		more += FixCards.add("en", {"text": "x%d" % i, "fix": "Different fix %d." % i, "fix_ko": ""}, "conv-C")
	ok(more == 7, "...and the duplicates did not eat the budget: 7 more fit (got %d)" % more)
	# without conv id: time window
	FixCards.reset_counter()
	Store.progress = Progress.blank()
	var n1 := 0
	for i in range(10):
		n1 += FixCards.add("en", {"text": "q%d" % i, "fix": "Quick fix %d." % i, "fix_ko": ""})
	ok(n1 == 8, "no conversation id: calls close together count as one conversation (8)")
	FixCards._last_add_sec -= FixCards.CONV_GAP_SEC + 5
	ok(FixCards.add("en", {"text": "late", "fix": "A fix after a long pause.", "fix_ko": ""}) == 1, "...a long pause starts a new conversation")
	# setting off
	FixCards.reset_counter()
	Store.progress = Progress.blank()
	Store.prefs["auto_fix_cards"] = false
	ok(FixCards.add("en", m1, "c9") == 0 and Store.review_for("en").is_empty(), "auto_fix_cards=false: nothing is added")
	Store.prefs.erase("auto_fix_cards")
	ok(FixCards.add("en", m1, "c9") == 1, "setting removed (default on): added")
	ok(FileAccess.file_exists(PROG_PATH), "the card list was saved to the (test) progress file")
	Store.progress = Progress.blank()
