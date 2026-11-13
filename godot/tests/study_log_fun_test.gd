extends Node
## v1.6.0 D1 (기록 계약): StudyLog 의 새 최상위 키 speed / badges / kana_course, n.newcards, longest_streak, Store.activity.
##   godot --headless --path <project> res://tests/study_log_fun_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/study_log_fun_test.tscn -- --phone
## 종료 코드 0 = 전부 통과. 마지막 줄: "== study_log_fun: N passed, 0 failed =="
## 화면이 없는 계산·저장 시험이라 PC 한 번이면 되지만 --phone 으로 돌려도 같다.
## 실제 user:// 기록은 읽지도 쓰지도 않는다: Store.prefs_path / progress_path / StudyLog.path 를 user://test_fun_* 로 바꿨다가 끝나면 되돌린다.
## selfcheck FAIL-as-expected: 검사 함수(_speed_ok 등)에 일부러 틀린 값을 넣어 실제로 실패로 판정되는지 확인하는 줄.

const LOG_PATH := "user://test_fun_studylog.json"
const PROG_PATH := "user://test_fun_progress.json"
const PREFS_PATH := "user://test_fun_prefs.json"
const NEW_KEYS := ["speed", "badges", "kana_course"]

var passed: int = 0
var failed: int = 0
var D: int = 0 ## fixed "today"
var _old_paths: Array = []
var _activity: Array = []


func _ready() -> void:
	print("== study_log_fun start ==")
	D = Plan.days_from_civil(2026, 11, 20)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	StudyLog.today_override = D
	_cleanup()

	_test_old_file()
	_test_normalize_fixture()
	_test_normalize_direct()
	_test_speed_run()
	_test_badges()
	_test_kana_course()
	_test_roundtrip_and_future_file()
	_test_broken_and_readonly()
	_test_newcards()
	_test_sync_keeps_keys()
	_test_longest_streak()
	_test_activity_signal()
	_test_selfchecks()

	_cleanup()
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk() ## empty state while the path is still the temp one
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	print("== study_log_fun: %d passed, %d failed ==" % [passed, failed])
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
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".bad.1", LOG_PATH + ".bad.2", LOG_PATH + ".bad.3", LOG_PATH + ".tmp", PROG_PATH, PROG_PATH + ".tmp", PREFS_PATH]:
		rm(p)


func _fresh() -> void:
	## new empty state with no file on disk
	StudyLog.open_hook = Callable()
	_cleanup()
	Store.progress = Progress.blank()
	Store.progress_read_only = false
	StudyLog.today_override = D
	StudyLog.load_from_disk()


func _load_fixture(name: String) -> void:
	StudyLog.open_hook = Callable()
	_cleanup()
	write_text(LOG_PATH, read_text("res://tests/" + name))
	StudyLog.today_override = D
	StudyLog.load_from_disk()


func iso(offset: int) -> String:
	return Plan.days_to_iso(D + offset)


## A number read back from a JSON file is a float (2.0): same value, so it counts as a whole number here.
func _isn(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and v == floorf(v))


## What the app would make of a file's content (JSON gives floats, the app wants ints): used to compare disk with memory.
func _as_loaded(d: Variant) -> Dictionary:
	return StudyLog._normalize(d)


func has_new_key(d: Dictionary) -> bool:
	for k in NEW_KEYS:
		if d.has(k):
			return true
	return false


## Invariant checkers (the self-check at the end feeds them deliberately wrong values).
func _speed_ok(sp: Variant) -> bool:
	if not (sp is Dictionary) or (sp as Dictionary).size() != 2:
		return false
	for l in ["en", "ja"]:
		var r: Variant = (sp as Dictionary).get(l, null)
		if not (r is Dictionary):
			return false
		var d: Dictionary = r
		for k in ["plays", "ok", "total"]:
			if not _isn(d.get(k, null)) or int(d[k]) < 0 or int(d[k]) > 1000000:
				return false
		if int(d["ok"]) > int(d["total"]):
			return false
		if not (d.get("last", null) is String) or (str(d["last"]) != "" and not Plan.is_valid_iso(str(d["last"]))):
			return false
		var b: Variant = d.get("best", null)
		if not (b is Dictionary):
			return false
		if not (b as Dictionary).is_empty():
			var bd: Dictionary = b
			if bd.size() != 5:
				return false
			if not _isn(bd.get("score", null)) or int(bd["score"]) < 0 or int(bd["score"]) > 100000:
				return false
			for k in ["correct", "total", "combo"]:
				if not _isn(bd.get(k, null)) or int(bd[k]) < 0 or int(bd[k]) > 1000:
					return false
			if int(bd["correct"]) > int(bd["total"]):
				return false
			if str(bd.get("date", "x")) != "" and not Plan.is_valid_iso(str(bd.get("date", ""))):
				return false
	return true


func _badges_ok(b: Variant) -> bool:
	if not (b is Dictionary) or not ((b as Dictionary).get("got", null) is Dictionary) or not ((b as Dictionary).get("seen", null) is Array):
		return false
	var got: Dictionary = (b as Dictionary)["got"]
	if got.size() > StudyLog.MAX_BADGES:
		return false
	for id in got.keys():
		if not (id is String) or (id as String).length() < 1 or (id as String).length() > 32:
			return false
		for i in range((id as String).length()):
			var c: int = (id as String).unicode_at(i)
			if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
				return false
		var e: Variant = got[id]
		if not (e is Dictionary) or not Plan.is_valid_iso(str((e as Dictionary).get("at", ""))) or not ((e as Dictionary).get("retro", null) is bool):
			return false
	var seen: Array = (b as Dictionary)["seen"]
	for i in range(seen.size()):
		if not got.has(seen[i]) or seen.find(seen[i]) != i:
			return false
	return true


func _kc_ok(kc: Variant) -> bool:
	if not (kc is Dictionary):
		return false
	for part in ["done", "best", "tries"]:
		var pd: Variant = (kc as Dictionary).get(part, null)
		if not (pd is Dictionary):
			return false
		for k in (pd as Dictionary).keys():
			if not _stage_key_ok(k):
				return false
			var v: Variant = (pd as Dictionary)[k]
			if part == "done":
				if not (v is String) or not Plan.is_valid_iso(v):
					return false
			elif not _isn(v) or int(v) < 0 or int(v) > (100 if part == "best" else 1000000):
				return false
	return true


func _stage_key_ok(k: Variant) -> bool:
	if not (k is String):
		return false
	if k == "p_h" or k == "p_k":
		return true
	for p in ["h", "k"]:
		for n in range(1, 12):
			if k == "%s%d" % [p, n]:
				return true
	return false


# ---------------------------------------------------------------- D1-2: old files get no new keys

func _test_old_file() -> void:
	print("[old file without the new keys]")
	StudyLog.open_hook = Callable()
	_cleanup()
	write_text(LOG_PATH, read_text("res://tests/sample_studylog_path.json"))
	StudyLog.today_override = D
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok", "old file loads")
	ok(not has_new_key(StudyLog.snapshot()), "old file: no new keys after loading")
	# reading through every new accessor must not create keys either
	ok(StudyLog.speed_best("en") == {} and StudyLog.speed_best("ja") == {} and StudyLog.speed_best("xx") == {}, "speed_best of an empty log is {}")
	ok(StudyLog.speed_summary("en") == {"plays": 0, "ok": 0, "total": 0, "last": ""} and StudyLog.speed_summary("xx") == {"plays": 0, "ok": 0, "total": 0, "last": ""}, "speed_summary of an empty log is all zero")
	ok(StudyLog.badges_got() == {} and StudyLog.badges_seen() == [] and not StudyLog.has_badge_record(), "no badge record yet: nothing received, has_badge_record() false")
	ok(StudyLog.kana_course_done() == {} and StudyLog.kana_course_best() == {}, "no kana course record yet")
	StudyLog.mark_badges_seen(["first_lesson"])
	ok(not has_new_key(StudyLog.snapshot()), "old file: reading (and marking an unknown badge seen) still adds no keys")
	StudyLog.add_seconds("en", "lesson", 60)
	ok(StudyLog.flush(), "old file: a normal write saves")
	ok(not has_new_key(StudyLog.snapshot()) and not has_new_key(read_json(LOG_PATH) as Dictionary), "old file: no new keys in memory or on disk after flush()")
	ok((read_json(LOG_PATH) as Dictionary).has("path"), "old file: its own 'path' key is still there")
	ok(StudyLog.longest_streak("en") == 0 and StudyLog.longest_streak("xx") == 0, "longest_streak without any record is 0")


# ---------------------------------------------------------------- D1-4: garbage in the file

func _test_normalize_fixture() -> void:
	print("[normalizing a file full of garbage]")
	_load_fixture("sample_studylog_fun.json")
	ok(StudyLog.last_load_status == "ok", "garbage fixture loads (status ok)")
	var snap: Dictionary = StudyLog.snapshot()
	var sp: Dictionary = snap["speed"]
	ok(_speed_ok(sp), "speed.* all within range after normalizing")
	ok(sp.keys().size() == 2 and not sp.has("fr"), "speed: only en / ja (the 'fr' entry is dropped)")
	ok(int(sp["en"]["plays"]) == 0, "speed.en.plays = 'x' -> 0")
	ok(int(sp["en"]["total"]) == 10 and int(sp["en"]["ok"]) == 10, "speed.en: ok 50 > total 10 -> ok cut to 10")
	ok(sp["en"]["last"] == "", "speed.en.last = '2026-13-40' -> ''")
	var eb: Dictionary = sp["en"]["best"]
	ok(int(eb["score"]) == 100000, "speed.en.best.score = 1e12 -> 100000")
	ok(int(eb["correct"]) == 20 and int(eb["total"]) == 20, "speed.en.best.correct 99 > total 20 -> 20")
	ok(eb["date"] == "" and not eb.has("junk") and eb.size() == 5, "speed.en.best: bad date '2026-02-30' -> '', unknown sub key dropped")
	ok(int(sp["ja"]["plays"]) == 0, "speed.ja.plays = -5 -> 0")
	ok(sp["ja"]["last"] == "2026-11-20" and int(sp["ja"]["best"]["score"]) == 200 and sp["ja"]["best"]["date"] == "2026-11-19", "speed.ja: valid values stay")
	ok(StudyLog.speed_best("en")["score"] == 100000 and StudyLog.speed_summary("ja")["total"] == 4, "speed_best / speed_summary read the cleaned values")

	var b: Dictionary = snap["badges"]
	ok(_badges_ok(b), "badges: every entry has a valid id, date and bool after normalizing")
	var got: Dictionary = b["got"]
	ok(got.has("first_lesson") and got["first_lesson"] == {"at": "2026-11-02", "retro": true}, "badges: valid entry kept (unknown sub key dropped)")
	ok(got.has("streak_7") and got["streak_7"]["retro"] == false, "badges: retro 'yes' (not a bool true) -> false")
	ok(not got.has("Bad ID!"), "badges: id 'Bad ID!' dropped")
	ok(not got.has("abcdefghijklmnopqrstuvwxyz0123456") and got.has("abcdefghijklmnopqrstuvwxyz012345"), "badges: 33-char id dropped, 32-char id kept")
	ok(not got.has("text_value") and not got.has("bad_date") and not got.has("no_date"), "badges: string value / bad date / missing date dropped")
	ok(got.has("from_newer_version") and StudyLog.badges_got().has("from_newer_version"), "badges: an id no BadgeDefs knows is kept")
	ok(b["seen"] == ["first_lesson", "from_newer_version"], "badges.seen: duplicate, id not in got, and non-string dropped -> %s" % str(b["seen"]))
	ok(StudyLog.has_badge_record(), "has_badge_record() true when the file has the key")

	var kc: Dictionary = snap["kana_course"]
	ok(_kc_ok(kc), "kana_course: every key is a real stage id and every value in range")
	ok(kc["done"] == {"h1": "2026-11-12", "p_h": "2026-11-13"}, "kana_course.done: zz / h12 / h0 / h01 / p_x / bad date / non-string dropped -> %s" % str(kc["done"]))
	ok(kc["best"] == {"h1": 100, "h2": 93, "k3": 0}, "kana_course.best: 150 -> 100, -4 -> 0, bad key / non-number dropped -> %s" % str(kc["best"]))
	ok(kc["tries"] == {"h1": 2, "k3": 0, "k4": 1000000}, "kana_course.tries: 1e99 -> 1000000, h0 dropped -> %s" % str(kc["tries"]))
	ok(not kc.has("mystery") and kc.size() == 3, "kana_course: unknown sub key dropped")
	ok(StudyLog.kana_course_done() == kc["done"] and StudyLog.kana_course_best() == kc["best"], "kana_course_done / best read the cleaned values")
	ok(snap.has("future_feature") and int(snap["future_feature"]["level"]) == 3, "an unknown top-level key next to the new ones is still kept")

	StudyLog.add_seconds("en", "talk", 5)
	ok(StudyLog.flush(), "garbage fixture: saves")
	var back: Dictionary = read_json(LOG_PATH) as Dictionary
	ok(_speed_ok(back["speed"]) and _badges_ok(back["badges"]) and _kc_ok(back["kana_course"]) and _as_loaded(back)["speed"] == StudyLog.snapshot()["speed"], "the cleaned values are what is written back to disk")


func _test_normalize_direct() -> void:
	print("[normalizing values JSON cannot carry]")
	var nan: float = NAN
	var inf: float = INF
	var n: Dictionary = StudyLog._normalize({
		"speed": {
			"en": {"plays": nan, "ok": inf, "total": 7, "last": 5, "best": {"score": nan, "correct": 1, "total": 2}},
			"ja": {"plays": 3, "ok": 2, "total": 4, "best": {"score": 50, "correct": nan, "total": inf, "combo": -inf}},
		},
		"badges": {"got": {"a_b1": {"at": "2026-11-01", "retro": false}}, "seen": "a_b1"},
		"kana_course": {"done": [1, 2], "best": {"h1": nan, "h2": inf, "h3": 55.7}, "tries": {"k1": nan, "k2": 3.9}},
	})
	ok(_speed_ok(n["speed"]), "NaN / inf values: speed comes out in range")
	ok(int(n["speed"]["en"]["plays"]) == 0 and int(n["speed"]["en"]["ok"]) <= 7 and n["speed"]["en"]["last"] == "", "NaN plays -> 0, inf ok cut to total, last 5 -> ''")
	ok(n["speed"]["en"]["best"] == {}, "best with score NaN -> {}")
	ok(int(n["speed"]["ja"]["best"]["score"]) == 50 and int(n["speed"]["ja"]["best"]["correct"]) == 0 and int(n["speed"]["ja"]["best"]["total"]) == 0 and int(n["speed"]["ja"]["best"]["combo"]) == 0, "best with NaN correct / inf total / -inf combo -> 0 / 0 / 0 (a number that is not finite counts as 0)")
	ok(_badges_ok(n["badges"]) and n["badges"]["seen"] == [], "badges.seen that is not an array -> []")
	ok(_kc_ok(n["kana_course"]) and n["kana_course"]["done"] == {}, "kana_course.done that is an array -> {}")
	ok(n["kana_course"]["best"] == {"h3": 55}, "kana_course.best NaN / inf dropped (not numbers), 55.7 -> 55 -> %s" % str(n["kana_course"]["best"]))
	ok(n["kana_course"]["tries"] == {"k2": 3}, "kana_course.tries NaN dropped, 3.9 -> 3 -> %s" % str(n["kana_course"]["tries"]))
	for junk in [null, 5, "x", [1, 2], true]:
		var m: Dictionary = StudyLog._normalize({"speed": junk, "badges": junk, "kana_course": junk})
		ok(_speed_ok(m["speed"]) and _badges_ok(m["badges"]) and _kc_ok(m["kana_course"]), "a %s in place of each new key -> blank valid state" % type_string(typeof(junk)))
	# 101st and later badges are dropped
	var many := {}
	for i in range(105):
		many["b%03d" % i] = {"at": "2026-11-01", "retro": false}
	var cut: Dictionary = StudyLog._normalize({"badges": {"got": many}})
	ok((cut["badges"]["got"] as Dictionary).size() == StudyLog.MAX_BADGES and _badges_ok(cut["badges"]), "105 badges in a file -> the first 100 kept (MAX_BADGES)")
	ok(StudyLog.MAX_BADGES == 100 and StudyLog.SPEED_MIN_ANSWERED == 5 and StudyLog.KINDS.has("newcards") and StudyLog.KNOWN_KEYS.has("kana_course"), "constants: MAX_BADGES 100, SPEED_MIN_ANSWERED 5, KINDS has newcards, KNOWN_KEYS has the new keys")
	ok(StudyLog.KINDS.size() == 8 and StudyLog.KNOWN_KEYS.size() == 11, "KINDS has exactly one new entry (newcards) and KNOWN_KEYS exactly the 3 new keys")


# ---------------------------------------------------------------- D1-5: add_speed_run

func _test_speed_run() -> void:
	print("[add_speed_run]")
	_fresh()
	var before: Dictionary = StudyLog.snapshot()
	var r4: Dictionary = StudyLog.add_speed_run("en", 300, 4, 4, 4)
	ok(r4["recorded"] == false and r4["new_best"] == false, "4 answers (< SPEED_MIN_ANSWERED) -> recorded == false")
	ok(StudyLog.snapshot() == before and not StudyLog.is_dirty(), "4 answers: the state is unchanged and not dirty")
	var r5: Dictionary = StudyLog.add_speed_run("en", 300, 5, 5, 5)
	ok(r5["recorded"] == true and r5["new_best"] == true and int(r5["prev_best"]) == 0, "5 answers, score 300 -> recorded, new_best, prev_best 0")
	ok(StudyLog.speed_best("en") == {"score": 300, "correct": 5, "total": 5, "combo": 5, "date": iso(0)}, "speed_best holds that run with today's date -> %s" % str(StudyLog.speed_best("en")))
	var r2: Dictionary = StudyLog.add_speed_run("en", 200, 3, 6, 2)
	ok(r2["recorded"] == true and r2["new_best"] == false and int(r2["prev_best"]) == 300, "score 200 -> recorded but new_best == false, prev_best 300")
	ok(int(StudyLog.speed_best("en")["score"]) == 300, "speed_best.score stays 300 (a lower run never replaces it)")
	var tie: Dictionary = StudyLog.add_speed_run("en", 300, 6, 6, 6)
	ok(tie["new_best"] == false and int(StudyLog.speed_best("en")["correct"]) == 5, "the same score is not a new best")
	ok(StudyLog.speed_summary("en") == {"plays": 3, "ok": 14, "total": 17, "last": iso(0)}, "speed_summary adds the runs up -> %s" % str(StudyLog.speed_summary("en")))
	var snap_ok: Dictionary = StudyLog.snapshot()
	var bad1: Dictionary = StudyLog.add_speed_run("en", 100, 8, 7, 3)
	var bad2: Dictionary = StudyLog.add_speed_run("fr", 100, 5, 5, 3)
	var bad3: Dictionary = StudyLog.add_speed_run("", 100, 5, 5, 3)
	var bad4: Dictionary = StudyLog.add_speed_run("en", -1, 5, 5, 3)
	var bad5: Dictionary = StudyLog.add_speed_run("en", 100, -1, 5, 3)
	var bad6: Dictionary = StudyLog.add_speed_run("en", 100, 5, 5, -1)
	var bad7: Dictionary = StudyLog.add_speed_run("en", 100, 5, 5000, 3)
	ok(bad1["recorded"] == false and bad2["recorded"] == false and bad3["recorded"] == false, "correct > total / unknown language / empty language -> recorded == false")
	ok(bad4["recorded"] == false and bad5["recorded"] == false and bad6["recorded"] == false and bad7["recorded"] == false, "negative score / correct / combo and a total above 1000 -> recorded == false")
	ok(StudyLog.snapshot() == snap_ok, "all of those left the state untouched")
	ok(StudyLog.speed_best("ja") == {} and StudyLog.speed_summary("ja")["plays"] == 0, "the other language is untouched")
	var big: Dictionary = StudyLog.add_speed_run("ja", 999999999, 20, 20, 5000)
	ok(big["recorded"] == true and int(StudyLog.speed_best("ja")["score"]) == 100000 and int(StudyLog.speed_best("ja")["combo"]) == 1000, "a score / combo above the limits is cut down (100000 / 1000), not refused")
	ok(_speed_ok(StudyLog.snapshot()["speed"]), "the live state obeys the same rules as a normalized file")
	ok(StudyLog.flush() and _speed_ok((read_json(LOG_PATH) as Dictionary)["speed"]), "flush() writes it")
	StudyLog.load_from_disk()
	ok(StudyLog.speed_best("en")["score"] == 300 and StudyLog.speed_summary("ja")["plays"] == 1, "reloaded from disk: the same values")
	# the first run with score 0 is still a best (nothing to beat)
	_fresh()
	var zero: Dictionary = StudyLog.add_speed_run("ja", 0, 0, 5, 0)
	ok(zero["recorded"] and zero["new_best"] and StudyLog.speed_best("ja") == {"score": 0, "correct": 0, "total": 5, "combo": 0, "date": iso(0)}, "the very first run is a best even with score 0")
	var after_zero: Dictionary = StudyLog.add_speed_run("ja", 0, 1, 5, 1)
	ok(after_zero["new_best"] == false, "a second run with score 0 does not beat score 0")


# ---------------------------------------------------------------- D1-6: badges

func _test_badges() -> void:
	print("[badges]")
	_fresh()
	ok(not StudyLog.has_badge_record(), "fresh log: has_badge_record() false")
	ok(StudyLog.grant_badge("first_lesson"), "grant_badge('first_lesson') -> true")
	ok(StudyLog.has_badge_record(), "after the first grant_badge: has_badge_record() true")
	ok(not StudyLog.grant_badge("first_lesson"), "the same id again -> false")
	ok(not StudyLog.grant_badge("Bad ID!") and not StudyLog.grant_badge("") and not StudyLog.grant_badge("UPPER") and not StudyLog.grant_badge("a-b") and not StudyLog.grant_badge("abcdefghijklmnopqrstuvwxyz0123456"), "ids of the wrong form (symbols, empty, capitals, hyphen, 33 chars) -> false")
	ok(StudyLog.grant_badge("streak_7", true), "retro grant -> true")
	var got: Dictionary = StudyLog.badges_got()
	ok(got["first_lesson"] == {"at": iso(0), "retro": false} and got["streak_7"] == {"at": iso(0), "retro": true}, "badges_got: at = today, retro as given -> %s" % str(got))
	got["first_lesson"]["at"] = "x"
	ok(StudyLog.badges_got()["first_lesson"]["at"] == iso(0), "badges_got returns a copy")
	StudyLog.mark_badges_seen(["first_lesson", "nope", 5, "first_lesson"])
	ok(StudyLog.badges_seen() == ["first_lesson"], "mark_badges_seen: ids that were never received / non-strings / duplicates are ignored -> %s" % str(StudyLog.badges_seen()))
	StudyLog.flush()
	var snap: Dictionary = StudyLog.snapshot()
	StudyLog.mark_badges_seen(["first_lesson"])
	ok(not StudyLog.is_dirty() and StudyLog.snapshot() == snap, "marking an already seen badge changes nothing (not dirty)")
	StudyLog.mark_badges_seen(["streak_7"])
	ok(StudyLog.badges_seen() == ["first_lesson", "streak_7"] and StudyLog.is_dirty(), "marking another one adds it in order")
	ok(StudyLog.flush() and _badges_ok((read_json(LOG_PATH) as Dictionary)["badges"]), "flush() writes a valid record")
	# init_badge_record
	_fresh()
	ok(not StudyLog.has_badge_record(), "(fresh again) has_badge_record() false before init_badge_record()")
	StudyLog.init_badge_record()
	ok(StudyLog.has_badge_record() and StudyLog.badges_got() == {} and StudyLog.badges_seen() == [], "init_badge_record() makes an empty record")
	ok(StudyLog.snapshot()["badges"] == {"got": {}, "seen": []}, "the empty record is {got:{}, seen:[]}")
	ok(StudyLog.flush() and (read_json(LOG_PATH) as Dictionary).has("badges"), "an empty record is saved (the first evaluation counts as done)")
	StudyLog.grant_badge("time_10h")
	var snap2: Dictionary = StudyLog.snapshot()
	StudyLog.init_badge_record()
	StudyLog.init_badge_record()
	ok(StudyLog.snapshot() == snap2 and StudyLog.badges_got().size() == 1, "init_badge_record() twice (even after a grant) leaves got as it was")
	# MAX_BADGES
	_fresh()
	var granted := 0
	for i in range(StudyLog.MAX_BADGES):
		if StudyLog.grant_badge("b%03d" % i):
			granted += 1
	ok(granted == 100 and StudyLog.badges_got().size() == 100, "100 badges can be received")
	ok(not StudyLog.grant_badge("one_too_many") and StudyLog.badges_got().size() == 100, "the 101st grant -> false and nothing is added")
	ok(not StudyLog.grant_badge("b000"), "an id that is already there is still false when full")
	# clock set back: a received badge keeps its date
	_fresh()
	StudyLog.grant_badge("first_lesson")
	StudyLog.today_override = D - 30
	ok(StudyLog.badges_got()["first_lesson"]["at"] == iso(0) and not StudyLog.grant_badge("first_lesson"), "setting the clock back does not change or re-grant a received badge")
	StudyLog.today_override = D


# ---------------------------------------------------------------- D1-7: kana course

func _test_kana_course() -> void:
	print("[kana course]")
	_fresh()
	ok(StudyLog.add_kana_course_try("h1", 12, 15, true), "add_kana_course_try('h1', 12, 15, true) -> true")
	ok(StudyLog.kana_course_done() == {"h1": iso(0)}, "done.h1 = today -> %s" % str(StudyLog.kana_course_done()))
	ok(StudyLog.kana_course_best() == {"h1": 80}, "best.h1 == 80 -> %s" % str(StudyLog.kana_course_best()))
	ok(int(StudyLog.snapshot()["kana_course"]["tries"]["h1"]) == 1, "tries.h1 == 1")
	StudyLog.today_override = D + 3
	ok(StudyLog.add_kana_course_try("h1", 9, 15, false), "a second try -> true")
	ok(StudyLog.kana_course_best()["h1"] == 80, "best.h1 stays 80 after a worse try")
	ok(int(StudyLog.snapshot()["kana_course"]["tries"]["h1"]) == 2, "tries.h1 == 2")
	ok(StudyLog.kana_course_done()["h1"] == iso(0), "done.h1 keeps its first date")
	StudyLog.add_kana_course_try("h1", 12, 15, true)
	ok(StudyLog.kana_course_done()["h1"] == iso(0), "passing again keeps the first date too")
	StudyLog.add_kana_course_try("h1", 14, 15, false)
	ok(StudyLog.kana_course_best()["h1"] == 93, "a better try raises best (14/15 -> 93)")
	StudyLog.today_override = D
	var snap: Dictionary = StudyLog.snapshot()
	ok(not StudyLog.add_kana_course_try("x9", 1, 1, true), "('x9', 1, 1, true) -> false")
	ok(not StudyLog.add_kana_course_try("h12", 1, 1, true) and not StudyLog.add_kana_course_try("h0", 1, 1, true) and not StudyLog.add_kana_course_try("", 1, 1, true) and not StudyLog.add_kana_course_try("p_x", 1, 1, true), "h12 / h0 / '' / p_x -> false")
	ok(not StudyLog.add_kana_course_try("h2", 1, 0, true) and not StudyLog.add_kana_course_try("h2", 16, 15, true) and not StudyLog.add_kana_course_try("h2", -1, 15, true) and not StudyLog.add_kana_course_try("h2", 1, 5000, true), "total 0 / correct > total / negative correct / total 5000 -> false (no division by zero)")
	ok(StudyLog.snapshot() == snap, "the false calls changed nothing")
	ok(StudyLog.add_kana_course_try("p_k", 0, 10, false) and StudyLog.kana_course_best()["p_k"] == 0 and not StudyLog.kana_course_done().has("p_k"), "a failed try of p_k: best 0, no done")
	ok(StudyLog.add_kana_course_try("k11", 2, 3, true) and StudyLog.kana_course_best()["k11"] == 67, "round(100 * 2 / 3) == 67")
	ok(StudyLog.flush() and _kc_ok((read_json(LOG_PATH) as Dictionary)["kana_course"]), "flush() writes a valid record")
	var copy: Dictionary = StudyLog.kana_course_done()
	copy["zzz"] = "x"
	ok(not StudyLog.kana_course_done().has("zzz"), "kana_course_done returns a copy")
	ok(not (read_json(LOG_PATH) as Dictionary).has("kana") and not StudyLog.snapshot().has("kana"), "the course record is its own key: the old 'kana' key is not created")


# ---------------------------------------------------------------- reload, newer version, broken file

func _test_roundtrip_and_future_file() -> void:
	print("[round trip / newer version]")
	_fresh()
	StudyLog.add_speed_run("en", 540, 24, 27, 12)
	StudyLog.grant_badge("first_lesson", true)
	StudyLog.mark_badges_seen(["first_lesson"])
	StudyLog.add_kana_course_try("h1", 14, 15, true)
	var before: Dictionary = StudyLog.snapshot()
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["speed"] == before["speed"] and StudyLog.snapshot()["badges"] == before["badges"] and StudyLog.snapshot()["kana_course"] == before["kana_course"], "write -> read gives the same three records")
	StudyLog.add_seconds("ja", "lesson", 10)
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["speed"] == before["speed"] and StudyLog.snapshot()["badges"] == before["badges"] and StudyLog.snapshot()["kana_course"] == before["kana_course"], "another write -> read keeps them")
	# a newer file with unknown top-level keys AND the new ones
	var src: Dictionary = read_json(LOG_PATH) as Dictionary
	src["v"] = 99
	src["future_feature"] = {"nested": {"b": "keep me"}}
	write_text(LOG_PATH, JSON.stringify(src))
	StudyLog.load_from_disk()
	StudyLog.add_seconds("en", "talk", 30)
	StudyLog.flush()
	var back: Dictionary = read_json(LOG_PATH) as Dictionary
	ok(back["future_feature"]["nested"]["b"] == "keep me" and int(back["v"]) == 99, "v:99 file: the unknown key and the version survive a save")
	var back_n: Dictionary = _as_loaded(back)
	ok(back_n["speed"] == before["speed"] and back_n["badges"] == before["badges"] and back_n["kana_course"] == before["kana_course"], "v:99 file: the new keys survive a save unchanged")
	# StudyLog.reset() wipes everything including the new keys
	StudyLog.reset()
	ok(not has_new_key(StudyLog.snapshot()) and not has_new_key(read_json(LOG_PATH) as Dictionary), "StudyLog.reset() removes the three new keys too (blank state)")


func _test_broken_and_readonly() -> void:
	print("[broken file / read-only file]")
	_cleanup()
	StudyLog.open_hook = Callable()
	write_text(LOG_PATH, "{\"v\": 1, \"speed\": {\"en\": {\"plays\": 3,")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "bad" and FileAccess.file_exists(LOG_PATH + ".bad"), "broken JSON -> status bad and the file is moved to .bad")
	ok(not has_new_key(StudyLog.snapshot()) and StudyLog.speed_best("en") == {} and StudyLog.badges_got() == {} and StudyLog.kana_course_done() == {}, "broken JSON -> blank state, accessors return empty values")
	ok(StudyLog.add_speed_run("en", 10, 5, 5, 1)["recorded"] and StudyLog.flush(), "the app goes on recording after a broken file")
	# not an object
	_cleanup()
	write_text(LOG_PATH, "[1,2,3]")
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "bad" and not has_new_key(StudyLog.snapshot()), "a JSON array instead of an object -> bad, blank")
	# unreadable: nothing is written, the old file stays as it is
	_cleanup()
	StudyLog.add_speed_run("en", 100, 5, 5, 2)
	StudyLog.flush()
	var disk_before: String = read_text(LOG_PATH)
	StudyLog.open_hook = func(_p: String) -> FileAccess: return null
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "unreadable" and StudyLog.is_read_only(), "an unreadable file -> read-only run")
	StudyLog.grant_badge("first_lesson")
	StudyLog.add_kana_course_try("h1", 12, 15, true)
	ok(not StudyLog.flush() and read_text(LOG_PATH) == disk_before, "read-only: flush() writes nothing, the file on disk is unchanged")
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk()
	ok(StudyLog.speed_best("en")["score"] == 100 and not StudyLog.badges_got().has("first_lesson"), "reloaded: the old record is still there, the in-memory grant is gone")


# ---------------------------------------------------------------- D1-8: n.newcards

func _test_newcards() -> void:
	print("[n.newcards]")
	_fresh()
	var added: int = Store.add_review([
		{"lang": "en", "target": "apple", "reading": "", "ko": "사과"},
		{"lang": "en", "target": "banana", "reading": "", "ko": "바나나"},
		{"lang": "ja", "target": "りんご", "reading": "ringo", "ko": "사과"},
		{"lang": "en", "target": "apple", "reading": "", "ko": "사과 (중복)"},
		{"lang": "fr", "target": "pomme", "reading": "", "ko": "사과"},
		{"lang": "en", "target": "  ", "reading": "", "ko": "빈 단어"},
	])
	ok(added == 3, "add_review returns 3 new cards (duplicate / unknown language / empty target skipped) -> %d" % added)
	ok(int(StudyLog.range_summary("en", 1)[0]["n"]["newcards"]) == 2, "today's en n.newcards == 2")
	ok(int(StudyLog.range_summary("ja", 1)[0]["n"]["newcards"]) == 1, "today's ja n.newcards == 1")
	Store.add_review([{"lang": "en", "target": "apple", "reading": "", "ko": "사과"}, {"lang": "ja", "target": "りんご", "reading": "", "ko": "사과"}])
	ok(int(StudyLog.range_summary("en", 1)[0]["n"]["newcards"]) == 2 and int(StudyLog.range_summary("ja", 1)[0]["n"]["newcards"]) == 1, "adding only existing cards counts nothing")
	ok(StudyLog.range_summary("en", 1)[0]["n"].has("newcards") and StudyLog.range_summary("en", 3)[0]["n"]["newcards"] == 0, "range_summary always has the newcards key (0 on other days)")
	var rev_n: int = (Store.progress["review"] as Array).size()
	# cards that arrive through sync are not counted
	var p: Dictionary = (Store.progress as Dictionary).duplicate(true)
	var card := {"id": Progress.new_id(), "lang": "en", "target": "zebra", "reading": "", "ko": "얼룩말", "note": ""}
	card.merge(FSRS.new_card(Store.now()))
	(p["review"] as Array).append(card)
	ok(Store.apply_sync_progress(p), "apply_sync_progress with one more card -> true")
	ok((Store.progress["review"] as Array).size() == rev_n + 1, "the synced card is in the review list")
	ok(int(StudyLog.range_summary("en", 1)[0]["n"]["newcards"]) == 2, "a card that came in through apply_sync_progress is not counted")
	ok(StudyLog.flush() and int(read_json(LOG_PATH)["days"][iso(0)]["en"]["n"]["newcards"]) == 2, "newcards is saved in days.<today>.en.n")
	# n leaves are what sync sums up: the key passes SyncDoc cleaning
	var cleaned: Dictionary = SyncDoc.clean_rec({"n": {"newcards": 2, "reviews": 1}})
	ok(int(cleaned["n"].get("newcards", 0)) == 2, "SyncDoc.clean_rec keeps n.newcards (a normal n leaf: it is summed between devices)")
	# a review list at its limit still counts what was added
	_fresh()
	Store.add_review([{"lang": "en", "target": "one", "reading": "", "ko": "하나"}])
	ok(int(StudyLog.range_summary("en", 1)[0]["n"]["newcards"]) == 1 and StudyLog.snapshot().has("days"), "a single new card is counted once")


# ---------------------------------------------------------------- D1-9: sync leaves the new keys alone

func _test_sync_keeps_keys() -> void:
	print("[sync keeps the new keys]")
	_fresh()
	StudyLog.add_speed_run("en", 540, 24, 27, 12)
	StudyLog.grant_badge("first_lesson")
	StudyLog.add_kana_course_try("h1", 14, 15, true)
	StudyLog.add_seconds("en", "lesson", 20)
	StudyLog.flush()
	var before: Dictionary = StudyLog.snapshot()
	var view: Dictionary = SyncDoc.extract(Store.progress, before, Store.prefs, 0)
	ok(not has_new_key(view), "SyncDoc.extract(...) result has none of speed / badges / kana_course at its top level")
	var text: String = JSON.stringify(view)
	ok(text.find("\"speed\"") < 0 and text.find("\"badges\"") < 0 and text.find("\"kana_course\"") < 0, "...and none of those words anywhere in the extracted document")
	var merged_days: Dictionary = {iso(-1): {"en": {"sec": 77, "by": {"lesson": 77}, "n": {"lessons": 1, "newcards": 4}, "lesson": [2, 3], "score": [0, 0]}}}
	ok(StudyLog.apply_sync({"days": merged_days}), "StudyLog.apply_sync({days}) -> true")
	var after: Dictionary = StudyLog.snapshot()
	ok(after["speed"] == before["speed"] and after["badges"] == before["badges"] and after["kana_course"] == before["kana_course"], "speed / badges / kana_course are unchanged by apply_sync")
	ok(after["days"].has(iso(-1)) and int(after["days"][iso(-1)]["en"]["n"]["newcards"]) == 4, "days were replaced and n.newcards arrived through the sync leaf")
	var disk: Dictionary = read_json(LOG_PATH) as Dictionary
	var disk_n: Dictionary = _as_loaded(disk)
	ok(disk_n["speed"] == before["speed"] and disk_n["badges"] == before["badges"] and disk_n["kana_course"] == before["kana_course"], "the file written by apply_sync still has the three records")
	ok(StudyLog.apply_sync({"days": {}, "phon": {}, "missions": {}}), "apply_sync with empty parts -> true")
	ok(StudyLog.snapshot()["speed"] == before["speed"] and StudyLog.snapshot()["kana_course"] == before["kana_course"], "...and the records are still there")
	# a log without the keys stays without them
	_fresh()
	StudyLog.apply_sync({"days": merged_days})
	ok(not has_new_key(StudyLog.snapshot()), "apply_sync on a log without the new keys does not create them")


# ---------------------------------------------------------------- D1-10: longest_streak

func _mark(lang: String, offsets: Array) -> void:
	for o in offsets:
		if not (Store.progress["days"] as Dictionary).has(iso(int(o))):
			Store.progress["days"][iso(int(o))] = {}
		Store.progress["days"][iso(int(o))][lang] = true


func _test_longest_streak() -> void:
	print("[longest_streak]")
	# 7 days in a row, one missing day (-12), 3 days in a row (-11..-9)... laid out so the missing day is -10:
	#   run A: -20..-14 (7 days)   gap: -13   run B: -12..-10 (3 days)   today = day 0 not studied
	var run_a: Array = [-20, -19, -18, -17, -16, -15, -14]
	var run_b: Array = [-12, -11, -10]
	_fresh()
	_mark("en", run_a + run_b)
	ok(StudyLog.longest_streak("en") == 7, "7 days + a missing day + 3 days, the missing day not protected -> 7")
	_fresh()
	_mark("en", run_a + run_b)
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 0, "frozen": [iso(-13)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.longest_streak("en") == 10, "the missing day is a streak-protection day -> 7 + 3 = 10 (the protected day only bridges)")
	var tokens_before: int = int(StudyLog.snapshot()["freeze"]["en"]["tokens"])
	StudyLog.longest_streak("en")
	ok(int(StudyLog.snapshot()["freeze"]["en"]["tokens"]) == tokens_before and not StudyLog.is_dirty(), "longest_streak only reads: no tokens spent or paid, not dirty")
	ok(StudyLog.longest_streak("ja") == 0, "the other language has its own record (0)")
	# a protected day that is not between two studied days adds nothing
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 0, "frozen": [iso(-13), iso(-21), iso(-9 + 5)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.longest_streak("en") == 10, "protected days at the ends (-21) or in the middle of nothing add nothing -> 10")
	# a gap of two with only one protected day does not bridge
	_fresh()
	_mark("en", [-20, -19, -16, -15, -14])
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 0, "frozen": [iso(-18)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.longest_streak("en") == 3, "a gap of 2 days with only 1 protected -> not bridged: runs 2 and 3 -> 3")
	# future days are ignored
	_fresh()
	_mark("en", [-2, -1, 0, 1, 2, 3, 4, 5, 6])
	ok(StudyLog.longest_streak("en") == 3, "days after today are ignored: -2, -1, 0 -> 3")
	_fresh()
	_mark("en", [1, 2, 3])
	ok(StudyLog.longest_streak("en") == 0, "only future days -> 0")
	_fresh()
	ok(StudyLog.longest_streak("en") == 0, "no record -> 0")
	_fresh()
	_mark("en", [0])
	ok(StudyLog.longest_streak("en") == 1, "only today -> 1")
	# garbage in progress.days is skipped
	_fresh()
	Store.progress["days"]["2026-13-40"] = {"en": true}
	Store.progress["days"]["junk"] = {"en": true}
	Store.progress["days"][iso(-1)] = {"en": true}
	Store.progress["days"][iso(-2)] = {"en": false}
	ok(StudyLog.longest_streak("en") == 1, "bad dates and false marks are skipped -> 1")
	_fresh()
	ok(StudyLog.longest_streak("fr") == 0 and StudyLog.longest_streak("") == 0, "unknown language -> 0")
	# a long run is counted fully, protected days in a row bridge a longer gap
	_fresh()
	var many: Array = []
	for i in range(40):
		many.append(-60 + i)
	_mark("en", many)
	_mark("en", [-10, -9])
	write_text(LOG_PATH, JSON.stringify({"v": 1, "freeze": {"en": {"tokens": 0, "frozen": [iso(-20), iso(-19), iso(-18), iso(-17), iso(-16), iso(-15), iso(-14), iso(-13), iso(-12), iso(-11)], "awarded": 0}}}))
	StudyLog.load_from_disk()
	ok(StudyLog.longest_streak("en") == 42, "40 studied days + 10 protected days in a row + 2 studied days -> 42")


# ---------------------------------------------------------------- Store.activity

func _test_activity_signal() -> void:
	print("[Store.activity]")
	_activity.clear()
	var cb := func(kind: String) -> void: _activity.append(kind)
	Store.activity.connect(cb)
	Store.note_activity("speed")
	Store.note_activity("kana")
	Store.activity.disconnect(cb)
	Store.note_activity("lesson")
	ok(_activity == ["speed", "kana"], "note_activity(kind) emits Store.activity(kind) -> %s" % str(_activity))


# ---------------------------------------------------------------- the checkers can fail

func _test_selfchecks() -> void:
	print("[self-check: the checkers reject wrong values]")
	var good_speed := {"en": {"plays": 1, "ok": 5, "total": 5, "last": "2026-11-20", "best": {"score": 10, "correct": 5, "total": 5, "combo": 5, "date": "2026-11-20"}}, "ja": {"plays": 0, "ok": 0, "total": 0, "last": "", "best": {}}}
	ok(_speed_ok(good_speed), "selfcheck: _speed_ok accepts a correct record")
	var bad_a: Dictionary = good_speed.duplicate(true)
	bad_a["en"]["ok"] = 9
	var bad_b: Dictionary = good_speed.duplicate(true)
	bad_b["en"]["best"]["score"] = 10000000
	var bad_c: Dictionary = good_speed.duplicate(true)
	bad_c["ja"]["plays"] = "x"
	var bad_d: Dictionary = good_speed.duplicate(true)
	bad_d["en"]["last"] = "2026-13-40"
	ok(not _speed_ok(bad_a), "selfcheck FAIL-as-expected: ok > total is rejected")
	ok(not _speed_ok(bad_b), "selfcheck FAIL-as-expected: best.score above 100000 is rejected")
	ok(not _speed_ok(bad_c), "selfcheck FAIL-as-expected: plays as a string is rejected")
	ok(not _speed_ok(bad_d), "selfcheck FAIL-as-expected: an impossible date is rejected")
	ok(not _speed_ok(null) and not _speed_ok({}), "selfcheck FAIL-as-expected: null and {} are rejected")
	var good_badges := {"got": {"a": {"at": "2026-11-20", "retro": false}}, "seen": ["a"]}
	ok(_badges_ok(good_badges), "selfcheck: _badges_ok accepts a correct record")
	ok(not _badges_ok({"got": {"Bad ID!": {"at": "2026-11-20", "retro": false}}, "seen": []}), "selfcheck FAIL-as-expected: a badge id with capitals / symbols is rejected")
	ok(not _badges_ok({"got": {"a": {"at": "2026-11-20", "retro": false}}, "seen": ["a", "a"]}), "selfcheck FAIL-as-expected: a duplicate in seen is rejected")
	ok(not _badges_ok({"got": {"a": {"at": "nope", "retro": false}}, "seen": []}), "selfcheck FAIL-as-expected: a bad badge date is rejected")
	ok(not _badges_ok({"got": {"a": {"at": "2026-11-20", "retro": false}}, "seen": ["zzz"]}), "selfcheck FAIL-as-expected: a seen id that was never received is rejected")
	ok(_kc_ok({"done": {"h1": "2026-11-20"}, "best": {"h1": 80}, "tries": {"h1": 1}}), "selfcheck: _kc_ok accepts a correct record")
	ok(not _kc_ok({"done": {"zz": "2026-11-20"}, "best": {}, "tries": {}}), "selfcheck FAIL-as-expected: a stage id zz is rejected")
	ok(not _kc_ok({"done": {}, "best": {"h1": 150}, "tries": {}}), "selfcheck FAIL-as-expected: best above 100 is rejected")
	ok(not _kc_ok({"done": {"h12": "2026-11-20"}, "best": {}, "tries": {}}), "selfcheck FAIL-as-expected: stage id h12 is rejected")
