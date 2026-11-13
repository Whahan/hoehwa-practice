extends Node
## v1.6.0 B1 (배지 엔진) 시험: 스냅샷 · 평가 · 소급 지급 · 알림 1개 · ui_list/counts · BadgeWatcher · 읽기 전용 · 성능.
##   godot --headless --path <project> res://tests/badge_engine_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/badge_engine_test.tscn -- --phone
## 종료 코드 0 = 전부 통과. 마지막 줄: "== badge_engine: N passed, 0 failed =="
## 화면이 없는 시험이라 PC 한 번이면 되지만 --phone 으로 돌려도 같다(약 3초: 감시자 시험이 실제 타이머를 기다린다).
## 실제 user:// 기록은 읽지도 쓰지도 않는다: Store.prefs_path / progress_path / StudyLog.path 를 user://test_fun_b1_* 로 바꿨다가 끝나면 되돌린다.
## SongDue.cache 와 BadgeEngine.provider 도 끝나면 원래대로 되돌린다. 서버·네트워크는 쓰지 않는다.
## selfcheck FAIL-as-expected: 검사 함수(same_ids)에 일부러 틀린 값을 넣어 실제로 실패로 판정되는지 확인하는 줄.

const LOG_PATH := "user://test_fun_b1_studylog.json"
const PROG_PATH := "user://test_fun_b1_progress.json"
const PREFS_PATH := "user://test_fun_b1_prefs.json"

var passed: int = 0
var failed: int = 0
var D: int = 0 ## fixed "today"
var _old_paths: Array = []
var _old_song_cache: Dictionary = {}
var _toasts: Array = [] ## [[text, kind], ...]
var _changed_count: int = 0


func _ready() -> void:
	print("== badge_engine start ==")
	D = Plan.days_from_civil(2026, 11, 20)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	_old_song_cache = SongDue.cache.duplicate()
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	StudyLog.path = LOG_PATH
	Toast.message.connect(_on_toast)
	Store.changed.connect(_on_store_changed)
	_cleanup()

	_selfcheck()
	_test_snapshot_real()
	_test_retro_first_eval()
	_test_second_eval()
	_test_empty_first_eval()
	_test_clock_rewind()
	_test_never_revoked()
	_test_kana()
	_test_song()
	_test_speed_and_multi_toast()
	_test_ui_list_counts()
	_test_provider_garbage()
	_test_readonly()
	_test_perf()
	await _test_watcher()

	_cleanup()
	BadgeEngine.provider = Callable()
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk() ## empty state while the path is still the temp one
	StudyLog.today_override = -1
	SongDue.cache = _old_song_cache
	Toast.message.disconnect(_on_toast)
	Store.changed.disconnect(_on_store_changed)
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	print("== badge_engine: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _on_toast(text: String, kind: String) -> void:
	_toasts.append([text, kind])


func _on_store_changed() -> void:
	_changed_count += 1


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


func rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".bad.1", LOG_PATH + ".bad.2", LOG_PATH + ".bad.3", LOG_PATH + ".tmp", PROG_PATH, PROG_PATH + ".tmp", PREFS_PATH]:
		rm(p)


## new empty state, no file on disk, real snapshot (no provider), empty song cache
func _fresh() -> void:
	StudyLog.open_hook = Callable()
	BadgeEngine.provider = Callable()
	_cleanup()
	Store.progress = Progress.blank()
	Store.progress_read_only = false
	StudyLog.today_override = D
	StudyLog.load_from_disk()
	SongDue.cache = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "done": 0, "at": 0}
	_toasts.clear()


func iso(offset: int) -> String:
	return Plan.days_to_iso(D + offset)


func got_ids() -> Array:
	return StudyLog.badges_got().keys()


## [A, B] == [B, A] (order does not matter)
func same_ids(a: Array, b: Array) -> bool:
	var x: Array = a.duplicate()
	var y: Array = b.duplicate()
	x.sort()
	y.sort()
	return JSON.stringify(x) == JSON.stringify(y)


## 기록이 풍부한 가짜 상태(실제 기록·진행 파일을 채운다): 레슨 12번, 연속 8일, 시간 2시간, 카드 25장, 미션 별 3개 1개
func _fill_rich() -> void:
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 12
	for i in range(8):
		Store.progress["days"][iso(-i)] = {"en": true}
	StudyLog.add_seconds("en", "lesson", 7200)
	var cards: Array = []
	for i in range(25):
		cards.append({"lang": "en", "target": "w%d" % i})
	Store.progress["review"] = cards
	StudyLog.add_mission("en", "cafe_order", 3, 2)
	StudyLog.add_mission("en", "self_intro", 2, 1)


const RICH_IDS := ["first_lesson", "lessons_10", "cards_20", "streak_3", "streak_7", "time_1h", "mission_star3"]


func _letters_ok(letters: Array) -> void:
	for ch in letters:
		for i in range(4):
			StudyLog.add_kana(str(ch), true)


func _toast_texts() -> Array:
	var out: Array = []
	for t in _toasts:
		out.append(t[0])
	return out


# ---------------------------------------------------------------- selfcheck

func _selfcheck() -> void:
	print("[selfcheck]")
	var wrong: bool = same_ids(["a", "b"], ["a", "c"])
	print("selfcheck %s same_ids vs a different id" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "same_ids() rejects a wrong expectation")
	wrong = same_ids(["a"], ["a", "b"])
	print("selfcheck %s same_ids vs a missing id" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "same_ids() rejects a shorter list")
	# a state that must NOT earn streak_7: the rule rejects a value one below the target (the B1-17 mutation would flip this)
	_fresh()
	BadgeEngine.provider = func() -> Dictionary: return {"streak_best": 6}
	var got: Array = BadgeEngine.evaluate()
	var bad: bool = got.has("streak_7")
	print("selfcheck %s streak_best 6 does not earn streak_7" % ("FAIL-as-expected" if not bad else "UNEXPECTED-PASS"))
	ok(not bad and same_ids(got, ["streak_3"]), "streak_best 6 -> only streak_3")
	BadgeEngine.provider = Callable()


# ---------------------------------------------------------------- snapshot (real values)

func _test_snapshot_real() -> void:
	print("[snapshot from real records]")
	_fresh()
	var s0: Dictionary = BadgeEngine.snapshot()
	var all_zero: bool = true
	for m in BadgeRules.MEASURES:
		if not s0.has(m) or int(s0[m]) != 0:
			all_zero = false
	ok(all_zero and s0.size() == BadgeRules.MEASURES.size(), "empty records -> all %d measures present and 0" % BadgeRules.MEASURES.size())
	_fill_rich()
	var s: Dictionary = BadgeEngine.snapshot()
	ok(s["lessons_total"] == 12, "lessons_total 12 (Store.stat en+ja)")
	ok(s["streak_best"] == 8, "streak_best 8 (8 marked days in a row)")
	ok(s["study_sec_total"] == 7200, "study_sec_total 7200")
	ok(s["cards_count"] == 25, "cards_count 25")
	ok(s["mission_star3"] == 1 and s["mission_all_star3"] == 1, "mission_star3 1 (cafe_order), mission_all_star3 1")
	StudyLog.add_mission("en", "not_a_listed_mission", 3, 1)
	s = BadgeEngine.snapshot()
	ok(s["mission_star3"] == 2 and s["mission_all_star3"] == 1, "an unlisted mission with 3 stars counts for mission_star3 but not for the 8-mission badge")
	# ja records are added up too
	(Store.progress["stats"]["ja"] as Dictionary)["lessons"] = 3
	(Store.progress["stats"]["ja"] as Dictionary)["talks"] = 2
	(Store.progress["stats"]["en"] as Dictionary)["talks"] = 1
	StudyLog.add_seconds("ja", "lesson", 100)
	s = BadgeEngine.snapshot()
	ok(s["lessons_total"] == 15 and s["talks_total"] == 3 and s["study_sec_total"] == 7300, "en + ja are added: lessons 15, talks 3, seconds 7300")
	# reviews and pronunciation (day average with >= 3 scores)
	StudyLog.add_event("en", "reviews", 40)
	StudyLog.add_event("ja", "reviews", 60)
	s = BadgeEngine.snapshot()
	ok(s["reviews_total"] == 100, "reviews_total 100 (n.reviews of both languages)")
	var res := {"transcript": "hello", "units": [], "score": 90}
	for i in range(2):
		StudyLog.add_score_any("en", res, "t")
	ok(BadgeEngine.snapshot()["pron_day_best"] == 0, "2 scores in a day: pron_day_best stays 0 (needs >= 3)")
	StudyLog.add_score_any("en", res, "t")
	ok(BadgeEngine.snapshot()["pron_day_best"] == 90, "3 scores averaging 90 -> pron_day_best 90")
	# a day average of 79.67 (rounds to 80) is not 80
	_fresh()
	var r2 := {"transcript": "hi", "units": [], "score": 80}
	var r3 := {"transcript": "hi", "units": [], "score": 80}
	var r4 := {"transcript": "hi", "units": [], "score": 79}
	StudyLog.add_score_any("en", r2, "t")
	StudyLog.add_score_any("en", r3, "t")
	StudyLog.add_score_any("en", r4, "t")
	ok(BadgeEngine.snapshot()["pron_day_best"] == 79 and not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("pron_80"), "average 79.67 -> 79 -> no pron_80 (no rounding up)")
	# future-dated days are ignored by the streak
	_fresh()
	for i in range(1, 6):
		Store.progress["days"][iso(i)] = {"en": true}
	ok(BadgeEngine.snapshot()["streak_best"] == 0, "marked days after today do not count for the streak")
	# broken sources do not crash the snapshot
	Store.progress["review"] = "oops"
	ok(BadgeEngine.snapshot()["cards_count"] == 0, "a broken review list counts as 0 cards")
	Store.progress = Progress.blank()
	# provider with a non-dictionary value
	BadgeEngine.provider = func() -> Variant: return "x"
	ok(BadgeEngine.snapshot() == {}, "a provider returning a string -> {} snapshot")
	BadgeEngine.provider = Callable()


# ---------------------------------------------------------------- B1-6 retro

func _test_retro_first_eval() -> void:
	print("[B1-6 retroactive first evaluation]")
	_fresh()
	_fill_rich()
	ok(not StudyLog.has_badge_record(), "no badge record before the first evaluation")
	var fresh: Array = BadgeEngine.evaluate()
	ok(same_ids(fresh, RICH_IDS), "first evaluate() returns the 7 earned ids: %s" % str(fresh))
	ok(JSON.stringify(fresh) == JSON.stringify(RICH_IDS), "...in table order")
	var got: Dictionary = StudyLog.badges_got()
	var all_retro: bool = got.size() == 7
	for id in got.keys():
		if not bool((got[id] as Dictionary).get("retro", false)) or str((got[id] as Dictionary).get("at", "")) != iso(0):
			all_retro = false
	ok(all_retro, "all 7 stored with retro == true and at == today")
	ok(_toasts.size() == 1, "exactly 1 toast (got %d)" % _toasts.size())
	ok(_toasts.size() == 1 and _toasts[0][0] == "이미 달성한 배지 7개를 모았어요" and _toasts[0][1] == "info", "the toast says \"이미 달성한 배지 7개를 모았어요\" (info)")
	ok(StudyLog.has_badge_record() and not StudyLog.is_dirty(), "the record exists and was flushed to disk")
	var disk: Variant = JSON.parse_string(read_text(LOG_PATH))
	ok(disk is Dictionary and ((disk as Dictionary).get("badges", {}) as Dictionary).get("got", {}).size() == 7, "the file on disk has the 7 badges")
	ok(_changed_count == 0, "evaluate() never emits Store.changed (no evaluation loop)")


# ---------------------------------------------------------------- B1-7 second evaluation

func _test_second_eval() -> void:
	print("[B1-7 second evaluation]")
	_fresh()
	_fill_rich()
	BadgeEngine.evaluate()
	var before: String = JSON.stringify(StudyLog.badges_got())
	var disk_before: String = read_text(LOG_PATH)
	_toasts.clear()
	var again: Array = BadgeEngine.evaluate()
	ok(again.is_empty(), "the same state again -> nothing new")
	ok(_toasts.is_empty(), "...and 0 toasts")
	ok(JSON.stringify(StudyLog.badges_got()) == before, "...and got is unchanged")
	ok(read_text(LOG_PATH) == disk_before and not StudyLog.is_dirty(), "...and the file is not rewritten")
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 50
	var n: Array = BadgeEngine.evaluate()
	ok(JSON.stringify(n) == JSON.stringify(["lessons_50"]), "lessons reach 50 -> only lessons_50 is new: %s" % str(n))
	var rec: Dictionary = StudyLog.badges_got()["lessons_50"]
	ok(rec["retro"] == false, "lessons_50 has retro == false")
	ok(_toasts.size() == 1 and _toasts[0][0] == "배지를 받았어요: 레슨 50번" and _toasts[0][1] == "ok", "1 toast with the badge name: \"%s\"" % (_toasts[0][0] if _toasts.size() > 0 else "-"))
	ok(JSON.stringify(StudyLog.badges_got()["first_lesson"]) == JSON.stringify(JSON.parse_string(before)["first_lesson"]), "earlier badges are untouched (retro stays true)")


# ---------------------------------------------------------------- B1-8 empty first evaluation

func _test_empty_first_eval() -> void:
	print("[B1-8 empty first evaluation]")
	_fresh()
	var init_calls: int = 0
	var fresh: Array = BadgeEngine.evaluate()
	ok(fresh.is_empty(), "nothing earned on empty records")
	ok(_toasts.is_empty(), "0 toasts")
	ok(StudyLog.has_badge_record(), "has_badge_record() is true after the first evaluation (init_badge_record ran)")
	ok(FileAccess.file_exists(LOG_PATH) and (JSON.parse_string(read_text(LOG_PATH)) as Dictionary).has("badges"), "the empty badge record was written to disk")
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 1
	var n: Array = BadgeEngine.evaluate()
	ok(JSON.stringify(n) == JSON.stringify(["first_lesson"]), "a later badge: first_lesson")
	ok(StudyLog.badges_got()["first_lesson"]["retro"] == false, "...is NOT retroactive (the retro decision is made only once)")
	ok(_toasts.size() == 1 and "첫 레슨" in str(_toasts[0][0]), "...with a normal one-line toast")
	init_calls += 1
	# a second empty-state device: a record that exists but is empty is not "first" anymore
	ok(init_calls == 1, "(sanity)")


# ---------------------------------------------------------------- B1-9 clock rewind

func _test_clock_rewind() -> void:
	print("[B1-9 clock rewind]")
	_fresh()
	_fill_rich()
	BadgeEngine.evaluate()
	var before: String = JSON.stringify(StudyLog.badges_got())
	StudyLog.today_override = D - 400 ## the clock was set back far into the past
	ok(StudyLog.longest_streak("en") == 0, "(precondition) longest_streak is 0 after rewinding the clock")
	_toasts.clear()
	var n: Array = BadgeEngine.evaluate()
	ok(n.is_empty() and _toasts.is_empty(), "evaluating with the rewound clock: nothing new, no toast")
	ok(JSON.stringify(StudyLog.badges_got()) == before, "got / at are exactly the same (streak badges are not taken back)")
	ok(StudyLog.badges_got().has("streak_7") and StudyLog.badges_got().has("time_1h"), "streak_7 and time_1h are still there")
	StudyLog.today_override = D


# ---------------------------------------------------------------- never revoked

func _test_never_revoked() -> void:
	print("[badges are never taken back]")
	_fresh()
	_fill_rich()
	BadgeEngine.evaluate()
	var before: String = JSON.stringify(StudyLog.badges_got())
	Store.progress = Progress.blank() ## lessons, cards and marked days fall back to 0 (the badge record is not touched)
	StudyLog.add_mission("en", "cafe_order", 0, 0)
	_toasts.clear()
	var n: Array = BadgeEngine.evaluate()
	ok(BadgeEngine.snapshot()["lessons_total"] == 0 and BadgeEngine.snapshot()["cards_count"] == 0, "(precondition) the counted lessons / cards are 0 now")
	ok(n.is_empty() and JSON.stringify(StudyLog.badges_got()) == before, "after the counted records fell to 0 the 7 badges are all still there")
	# an explicit "기록 초기화" (Store.reset_progress -> StudyLog.reset) wipes the badge record on purpose (design 5.2); evaluating again starts over
	Store.reset_progress()
	ok(not StudyLog.has_badge_record() and StudyLog.badges_got().is_empty(), "the user's own reset wipes the badge record (documented behaviour, not a revoke)")
	_fresh()
	_fill_rich()
	BadgeEngine.evaluate()
	# a badge id this version does not know is kept and not counted
	StudyLog.grant_badge("from_the_future", false)
	BadgeEngine.evaluate()
	ok(StudyLog.badges_got().has("from_the_future"), "an unknown id stays in got")
	var c: Dictionary = BadgeEngine.counts()
	ok(c["got"] == 7 and c["total"] == 23, "counts() ignores the unknown id: got 7 of 23 (got %s)" % str(c))
	ok(BadgeEngine.ui_list().size() == 23, "ui_list() shows only the 23 known badges")
	# MAX_BADGES full: grant returns false and evaluate does not fail
	_fresh()
	for i in range(StudyLog.MAX_BADGES):
		StudyLog.grant_badge("x_%d" % i, false)
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 1
	var n2: Array = BadgeEngine.evaluate()
	ok(n2.is_empty() and _toasts.is_empty(), "a full badge list: nothing granted, no toast, no error")


# ---------------------------------------------------------------- B1-10 kana

func _test_kana() -> void:
	print("[B1-10 kana badges]")
	var hira_seion: Array = []
	for e in KanaData.section_entries("hira", "seion"):
		hira_seion.append((e as Dictionary)["ch"])
	var kata_seion: Array = []
	for e in KanaData.section_entries("kata", "seion"):
		kata_seion.append((e as Dictionary)["ch"])
	ok(hira_seion.size() == 46 and kata_seion.size() == 46, "(precondition) 46 + 46 seion letters")
	# 46 hira seion, all ok 4 bad 0
	_fresh()
	_letters_ok(hira_seion)
	var e1: Array = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(e1.has("kana_hira") and not e1.has("kana_kata") and not e1.has("kana_all"), "46 hira seion mastered -> kana_hira only")
	# only 45
	_fresh()
	_letters_ok(hira_seion.slice(0, 45))
	e1 = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(not e1.has("kana_hira"), "45 of 46 -> no kana_hira")
	# one letter at ok 3 (mastery 2) does not count
	_fresh()
	_letters_ok(hira_seion.slice(0, 45))
	for i in range(3):
		StudyLog.add_kana(str(hira_seion[45]), true)
	ok(not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("kana_hira"), "the 46th letter with only 3 right answers (mastery 2) -> no kana_hira")
	StudyLog.add_kana(str(hira_seion[45]), true)
	ok(BadgeRules.earned_ids(BadgeEngine.snapshot()).has("kana_hira"), "...a 4th right answer -> kana_hira")
	# a letter with too many mistakes (ok 4, bad 2: 2*3 > 4) is not mastered
	_fresh()
	_letters_ok(hira_seion.slice(0, 45))
	for i in range(4):
		StudyLog.add_kana(str(hira_seion[45]), true)
	StudyLog.add_kana(str(hira_seion[45]), false)
	StudyLog.add_kana(str(hira_seion[45]), false)
	ok(KanaData.mastery(4, 2) < 3 and not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("kana_hira"), "ok 4 / bad 2 is not mastery 3 -> no kana_hira")
	# kata
	_fresh()
	_letters_ok(kata_seion)
	e1 = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(e1.has("kana_kata") and not e1.has("kana_hira"), "46 kata seion -> kana_kata only")
	# all 208
	_fresh()
	var every: Array = []
	for e in KanaData.entries("both"):
		every.append((e as Dictionary)["ch"])
	ok(every.size() == 208, "(precondition) 208 letters")
	_letters_ok(every.slice(0, 207))
	e1 = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(not e1.has("kana_all"), "207 of 208 -> no kana_all")
	_letters_ok(every.slice(207, 208))
	e1 = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(e1.has("kana_all") and e1.has("kana_hira") and e1.has("kana_kata") and e1.has("kana_pairs"), "all 208 -> kana_all + kana_hira + kana_kata + kana_pairs")
	# pairs
	var pair_letters: Array = BadgeDefs.pair_letters()
	_fresh()
	_letters_ok(pair_letters.slice(1))
	ok(not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("kana_pairs"), "all pair letters but one -> no kana_pairs")
	_letters_ok(pair_letters.slice(0, 1))
	var e2: Array = BadgeRules.earned_ids(BadgeEngine.snapshot())
	ok(e2.has("kana_pairs") and not e2.has("kana_hira") and not e2.has("kana_all"), "every pair letter mastered -> kana_pairs (and neither hira nor all)")
	ok(int(BadgeEngine.snapshot()["kana_pairs"]) == 37, "kana_pairs counts 37 letters")
	# a full evaluate with the kana state
	_fresh()
	_letters_ok(hira_seion)
	var n: Array = BadgeEngine.evaluate()
	ok(same_ids(n, ["kana_hira"]), "evaluate() with 46 hira seion mastered grants kana_hira (retro)")


# ---------------------------------------------------------------- B1-11 song

func _lister(total: int, memorized: int, kind: String = "lyrics") -> Callable:
	return func() -> Variant: return {"list": [{"id": "s_a", "kind": kind}], "memo": {"s_a": {"total": total, "memorized": memorized, "due": 0, "fresh": 0}}}


func _test_song() -> void:
	print("[B1-11 song badges]")
	_fresh()
	SongDue.scan(_lister(6, 6))
	ok(int(SongDue.cache["done"]) == 1 and int(SongDue.cache["lyrics"]) == 1, "SongDue: total 6 memorized 6 -> done 1")
	var s: Dictionary = BadgeEngine.snapshot()
	ok(s["song_done"] == 1 and s["song_lyrics"] == 1, "snapshot reads SongDue.cache: song_lyrics 1, song_done 1")
	var n: Array = BadgeEngine.evaluate()
	ok(same_ids(n, ["song_first", "song_done"]), "evaluate -> song_first + song_done: %s" % str(n))
	_fresh()
	SongDue.scan(_lister(3, 3))
	ok(int(SongDue.cache["done"]) == 0 and not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("song_done"), "3 lines all memorized (< 4 lines) -> no song_done")
	SongDue.scan(_lister(6, 5))
	ok(int(SongDue.cache["done"]) == 0 and BadgeRules.earned_ids(BadgeEngine.snapshot()).has("song_first") and not BadgeRules.earned_ids(BadgeEngine.snapshot()).has("song_done"), "5 of 6 memorized -> song_first only")
	SongDue.scan(_lister(4, 4))
	ok(int(SongDue.cache["done"]) == 1, "exactly 4 lines, all memorized -> done 1 (the boundary)")
	SongDue.scan(_lister(6, 6, "audio"))
	ok(int(SongDue.cache["done"]) == 0 and int(SongDue.cache["lyrics"]) == 0, "an audio song never counts")
	# song badges are not retroactive when the songs are read after the first evaluation
	_fresh()
	var first: Array = BadgeEngine.evaluate()
	SongDue.scan(_lister(6, 6))
	var second: Array = BadgeEngine.evaluate()
	ok(first.is_empty() and same_ids(second, ["song_first", "song_done"]) and StudyLog.badges_got()["song_done"]["retro"] == false, "songs read after the first evaluation -> granted with retro == false")


# ---------------------------------------------------------------- speed + multi toast

func _test_speed_and_multi_toast() -> void:
	print("[speed badges, several new at once]")
	_fresh()
	BadgeEngine.evaluate() ## first (empty) evaluation: later grants are not retroactive
	_toasts.clear()
	ok(BadgeEngine.snapshot()["speed_plays"] == 0, "no speed record -> speed_plays 0")
	StudyLog.add_speed_run("en", 600, 20, 22, 12)
	(Store.progress["stats"]["en"] as Dictionary)["talks"] = 1
	var s: Dictionary = BadgeEngine.snapshot()
	ok(s["speed_plays"] == 1 and s["speed_combo"] == 12 and s["speed_score"] == 600, "snapshot: plays 1, combo 12, score 600")
	var n: Array = BadgeEngine.evaluate()
	ok(same_ids(n, ["first_talk", "speed_first", "speed_combo_10", "speed_score_500"]), "4 new badges at once: %s" % str(n))
	ok(_toasts.size() == 1, "still exactly 1 toast (got %d)" % _toasts.size())
	ok(_toasts.size() == 1 and _toasts[0][0] == "배지 4개를 받았어요: 첫 원어민 대화 외 3개", "toast text: \"%s\"" % (_toasts[0][0] if _toasts.size() > 0 else "-"))
	# ja speed record is added to plays and the best is the larger of the two languages
	StudyLog.add_speed_run("ja", 700, 25, 26, 5)
	s = BadgeEngine.snapshot()
	ok(s["speed_plays"] == 2 and s["speed_combo"] == 12 and s["speed_score"] == 700, "en + ja: plays 2, best combo 12, best score 700")


# ---------------------------------------------------------------- B1-12 ui_list / counts

func _test_ui_list_counts() -> void:
	print("[B1-12 ui_list / counts / mark_all_seen]")
	_fresh()
	_fill_rich()
	BadgeEngine.evaluate()
	var list: Array = BadgeEngine.ui_list()
	ok(list.size() == 23, "ui_list() has 23 entries")
	var order_ok: bool = true
	for i in range(23):
		if str((list[i] as Dictionary)["id"]) != str(BadgeDefs.ids()[i]):
			order_ok = false
	ok(order_ok, "in table order")
	var by := {}
	for e in list:
		by[(e as Dictionary)["id"]] = e
	var fl: Dictionary = by["first_lesson"]
	ok(fl["got"] == true and fl["at"] == iso(0) and fl["retro"] == true and fl["value"] == 12 and fl["target"] == 1 and fl["is_new"] == true, "first_lesson: got, at today, retro, value 12, target 1, is_new")
	var st: Dictionary = by["streak_30"]
	ok(st["got"] == false and st["at"] == "" and st["retro"] == false and st["value"] == 8 and st["target"] == 30 and st["is_new"] == false, "streak_30: not got, value 8 / target 30, not new")
	var keys_ok: bool = true
	for k in ["id", "name", "desc", "cat", "glyph", "got", "at", "retro", "value", "target", "is_new"]:
		if not fl.has(k):
			keys_ok = false
	ok(keys_ok, "every entry has id, name, desc, cat, glyph, got, at, retro, value, target, is_new")
	var c: Dictionary = BadgeEngine.counts()
	ok(c["got"] == 7 and c["total"] == 23 and c["unseen"] == 7, "counts(): got 7, total 23, unseen 7 (got %s)" % str(c))
	var dirty_before: bool = StudyLog.is_dirty()
	BadgeEngine.ui_list()
	BadgeEngine.counts()
	ok(StudyLog.is_dirty() == dirty_before and StudyLog.badges_seen().is_empty(), "reading (ui_list / counts) changes nothing")
	BadgeEngine.mark_all_seen()
	var none_new: bool = true
	for e in BadgeEngine.ui_list():
		if bool((e as Dictionary)["is_new"]):
			none_new = false
	ok(none_new, "after mark_all_seen() no entry is_new")
	ok(BadgeEngine.counts()["unseen"] == 0 and BadgeEngine.counts()["got"] == 7, "...counts().unseen == 0, got still 7")
	var disk: Variant = JSON.parse_string(read_text(LOG_PATH))
	ok(disk is Dictionary and ((disk as Dictionary)["badges"]["seen"] as Array).size() == 7, "...and the seen list was saved (7)")
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 50
	BadgeEngine.evaluate()
	ok(BadgeEngine.counts()["unseen"] == 1 and BadgeEngine.counts()["got"] == 8, "a badge received later is the one unseen")
	var lessons50: Dictionary = {}
	for e in BadgeEngine.ui_list():
		if (e as Dictionary)["id"] == "lessons_50":
			lessons50 = e
	ok(lessons50["is_new"] == true and lessons50["retro"] == false, "lessons_50: is_new, not retro")


# ---------------------------------------------------------------- garbage from the provider

func _test_provider_garbage() -> void:
	print("[garbage snapshots through evaluate()]")
	for junk in ["x", null, -5, NAN, true, [1, 2], {"lessons_total": "99", "streak_best": NAN, "cards_count": -9, "speed_plays": true, "song_lyrics": [3]}]:
		_fresh()
		var j: Variant = junk
		BadgeEngine.provider = func() -> Variant: return j
		var n: Array = BadgeEngine.evaluate()
		ok(n.is_empty() and _toasts.is_empty() and StudyLog.has_badge_record() and StudyLog.badges_got().is_empty(), "provider returns %s -> nothing earned, no toast, no error" % var_to_str(junk).substr(0, 40))
	_fresh()
	BadgeEngine.provider = func() -> Dictionary: return {"lessons_total": 1, "streak_best": NAN, "cards_count": "20"}
	var n2: Array = BadgeEngine.evaluate()
	ok(same_ids(n2, ["first_lesson"]), "only the one good key earns: %s" % str(n2))
	BadgeEngine.provider = Callable()


# ---------------------------------------------------------------- B1-14 read-only record file

func _test_readonly() -> void:
	print("[B1-14 read-only record file]")
	_fresh()
	StudyLog.add_seconds("en", "lesson", 5)
	StudyLog.flush()
	var disk_before: String = read_text(LOG_PATH)
	StudyLog.open_hook = func(_p: String) -> FileAccess: return null
	StudyLog.load_from_disk()
	ok(StudyLog.is_read_only(), "(precondition) the file could not be opened -> read-only")
	_toasts.clear() ## the loader's own warning toast is not the evaluation's
	BadgeEngine.provider = func() -> Dictionary: return {"lessons_total": 60, "streak_best": 40}
	var n: Array = BadgeEngine.evaluate()
	ok(n.is_empty(), "evaluate() returns [] while read-only")
	ok(_toasts.is_empty(), "...0 toasts")
	ok(not StudyLog.has_badge_record() and StudyLog.badges_got().is_empty(), "...nothing granted, not even an empty record (the first-evaluation decision is not spent)")
	ok(not StudyLog.flush() and read_text(LOG_PATH) == disk_before, "...and the file on disk is unchanged")
	BadgeEngine.mark_all_seen()
	ok(read_text(LOG_PATH) == disk_before, "mark_all_seen() writes nothing either")
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk()
	BadgeEngine.provider = func() -> Dictionary: return {"lessons_total": 60, "streak_best": 40}
	var n2: Array = BadgeEngine.evaluate()
	ok(n2.has("lessons_50") and n2.has("streak_30"), "after the file can be read again the evaluation works (retro)")
	BadgeEngine.provider = Callable()


# ---------------------------------------------------------------- B1-15 performance

func _test_perf() -> void:
	print("[B1-15 performance: snapshot() + evaluate() on 400 days x 2 languages + 208 letters]")
	_fresh()
	for i in range(StudyLog.KEEP_DAYS):
		StudyLog.today_override = D - i
		for lang in ["en", "ja"]:
			StudyLog.add_seconds(lang, "lesson", 600)
			StudyLog.add_lesson(lang, 8, 10)
			StudyLog.add_event(lang, "reviews", 5)
			for k in range(3):
				StudyLog.add_score_any(lang, {"transcript": "hi", "units": [], "score": 85}, "t")
			Store.progress["days"][Plan.days_to_iso(D - i)] = {"en": true, "ja": true}
	StudyLog.today_override = D
	var cards: Array = []
	for i in range(300):
		cards.append({"lang": "en", "target": "w%d" % i})
	Store.progress["review"] = cards
	(Store.progress["stats"]["en"] as Dictionary)["lessons"] = 60
	(Store.progress["stats"]["en"] as Dictionary)["talks"] = 2
	for id in BadgeRules.MISSION_IDS:
		StudyLog.add_mission("en", id, 3, 3)
	StudyLog.add_speed_run("en", 600, 20, 22, 12)
	SongDue.cache = {"songs": 1, "lyrics": 1, "due": 0, "fresh": 0, "done": 1, "at": 1}
	for e in KanaData.entries("both"):
		for k in range(4):
			StudyLog.add_kana(str((e as Dictionary)["ch"]), true)
	var snap_rec: Dictionary = BadgeEngine.snapshot()
	ok(snap_rec["streak_best"] == 400 and snap_rec["study_sec_total"] == 400 * 2 * 600 and snap_rec["reviews_total"] == 400 * 2 * 5 and snap_rec["pron_day_best"] == 85, "the big state is read correctly (streak 400, seconds %d, reviews %d, best day 85)" % [snap_rec["study_sec_total"], snap_rec["reviews_total"]])
	# the first evaluation earns everything this state can earn (and writes the 400-day file once)
	var first: Array = BadgeEngine.evaluate()
	ok(first.size() == 23, "the big state earns all 23 badges on the first evaluation (got %d)" % first.size())
	var runs: int = 100
	var t0: int = Time.get_ticks_usec()
	for i in range(runs):
		BadgeEngine.snapshot()
		BadgeEngine.evaluate()
	var avg_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / float(runs)
	print("perf: snapshot()+evaluate() average %.3f ms over %d runs (PC headless; the phone value is not measured here)" % [avg_ms, runs])
	ok(avg_ms < 20.0, "snapshot() + evaluate(): average %.2f ms < 20 ms" % avg_ms)
	# worst case = a full snapshot (nothing skipped), e.g. for a user who has not received the slow-to-compute badges yet
	t0 = Time.get_ticks_usec()
	for i in range(runs):
		BadgeEngine.snapshot()
	var snap_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / float(runs)
	print("perf: one full snapshot() (nothing skipped) average %.3f ms over %d runs" % [snap_ms, runs])
	ok(snap_ms < 20.0, "a full snapshot() alone: average %.2f ms < 20 ms" % snap_ms)
	var only_ms: float = 0.0
	t0 = Time.get_ticks_usec()
	for i in range(runs):
		BadgeEngine.snapshot(["lessons_total", "speed_plays"])
	only_ms = float(Time.get_ticks_usec() - t0) / 1000.0 / float(runs)
	print("perf: snapshot(only the cheap measures) average %.3f ms" % only_ms)
	ok(only_ms < snap_ms, "snapshot(only) is cheaper than the full snapshot (%.3f < %.3f ms)" % [only_ms, snap_ms])
	var sk: Dictionary = BadgeEngine.snapshot(["lessons_total"])
	ok(sk["lessons_total"] == 60 and sk["streak_best"] == 0 and sk["study_sec_total"] == 0, "a skipped measure is 0 (streak_best / study_sec_total not computed), a wanted one is real")


# ---------------------------------------------------------------- B1-13 BadgeWatcher

func _make_watcher(counter: Dictionary, clock_ref: Dictionary, dirty_ref: Dictionary) -> BadgeWatcher:
	var w := BadgeWatcher.new()
	w.evaluator = func(_src: String) -> Variant:
		counter["n"] = int(counter["n"]) + 1
		return []
	w.clock = func() -> int: return int(clock_ref["ms"])
	w.dirty_probe = func() -> bool: return bool(dirty_ref["v"])
	add_child(w)
	return w


func _test_watcher() -> void:
	print("[B1-13 BadgeWatcher]")
	_fresh()
	# three activity signals in a row -> one evaluation
	var counter := {"n": 0}
	var clock := {"ms": 10000}
	var dirty := {"v": false}
	var w: BadgeWatcher = _make_watcher(counter, clock, dirty)
	Store.note_activity("speed")
	Store.note_activity("speed")
	Store.note_activity("kana")
	ok(counter["n"] == 0, "no evaluation right away (debounced)")
	await get_tree().create_timer(BadgeWatcher.DEBOUNCE_SEC + 0.25).timeout
	ok(counter["n"] == 1 and w.eval_count == 1, "3 activity signals -> exactly 1 evaluation (got %d)" % counter["n"])
	# another signal 500 ms later (fake clock): the gap is not over -> not evaluated again for now
	clock["ms"] = 10500
	Store.note_activity("speed")
	await get_tree().create_timer(BadgeWatcher.DEBOUNCE_SEC + 0.25).timeout
	ok(counter["n"] == 1, "a signal 0.5 s after an evaluation (MIN_GAP 2 s) does not evaluate again (got %d)" % counter["n"])
	# the request is not lost: once the gap is over the deferred evaluation runs
	clock["ms"] = 13000
	await get_tree().create_timer(1.8).timeout
	ok(counter["n"] == 2, "...the postponed request runs once the gap is over (got %d)" % counter["n"])
	# Store.changed also triggers
	clock["ms"] = 20000
	Store.changed.emit()
	await get_tree().create_timer(BadgeWatcher.DEBOUNCE_SEC + 0.25).timeout
	ok(counter["n"] == 3, "Store.changed -> an evaluation (got %d)" % counter["n"])
	# the 30 s timer: clean StudyLog and no Store.changed -> skipped
	clock["ms"] = 40000
	dirty["v"] = false
	ok(w.on_tick() == false and counter["n"] == 3, "tick with a clean StudyLog and no Store.changed: no evaluation")
	dirty["v"] = true
	ok(w.on_tick() == true and counter["n"] == 4, "tick with a dirty StudyLog: evaluates")
	ok(w.on_tick() == false and counter["n"] == 4, "tick again right away (same clock): the 2 s gap blocks it")
	clock["ms"] = 43000
	ok(w.on_tick() == true and counter["n"] == 5, "tick after the gap with a still dirty log: evaluates")
	dirty["v"] = false
	clock["ms"] = 50000
	ok(w.on_tick() == false and counter["n"] == 5, "clean again: skipped")
	# Store.changed since the last evaluation -> the tick evaluates even with a clean StudyLog
	Store.changed.emit()
	ok(w.on_tick() == true and counter["n"] == 6, "Store.changed since the last evaluation: the tick evaluates although StudyLog is clean")
	await get_tree().create_timer(BadgeWatcher.DEBOUNCE_SEC + 0.25).timeout
	ok(counter["n"] == 6, "...and the debounced request does not add a second one inside the gap (got %d)" % counter["n"])
	# a clock that went backwards is treated as 'gap over'
	clock["ms"] = 100
	dirty["v"] = true
	ok(w.on_tick() == true, "a clock that went backwards does not block the evaluation forever")
	# freed watcher: signals are disconnected
	var before_conn: int = Store.activity.get_connections().size()
	w.free()
	ok(Store.activity.get_connections().size() == before_conn - 1, "freeing the watcher disconnects it from Store.activity")
	Store.note_activity("other")
	ok(counter["n"] == 7, "a freed watcher evaluates nothing more")

	# default evaluator = BadgeEngine.evaluate
	_fresh()
	BadgeEngine.provider = func() -> Dictionary: return {"lessons_total": 1}
	var w2 := BadgeWatcher.new()
	add_child(w2)
	ok(not StudyLog.has_badge_record(), "(precondition) no badge record yet")
	Store.note_activity("lesson")
	await get_tree().create_timer(BadgeWatcher.DEBOUNCE_SEC + 0.25).timeout
	ok(w2.eval_count == 1 and StudyLog.badges_got().has("first_lesson"), "the default evaluator is BadgeEngine.evaluate (first_lesson granted)")
	w2.free()
	BadgeEngine.provider = Callable()
	ok(BadgeWatcher.DEBOUNCE_SEC == 0.3 and BadgeWatcher.MIN_GAP_MS == 2000 and BadgeWatcher.TICK_SEC == 30.0, "constants: debounce 0.3 s, gap 2000 ms, tick 30 s")
