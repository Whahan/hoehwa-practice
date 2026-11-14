extends Node
## StudyLog 의 일본어 약한 소리 기록 (docs/v170_design.md §2.2, A2-6, A2-7):
##   add_score_any("ja", ...) 가 JaSounds.annotate 한 복사본으로 phon.ja 에 기록, add_phon_obs, 잘못된 입력, 영어 경로 불변,
##   옛 파일(새 키 없음) 호환, 모르는 키 보존, SyncDoc 정리·apply_sync 왕복.
##   godot --headless --path <project> res://tests/study_log_ja_test.tscn
## 마지막 줄: "== study_log_ja: N passed, M failed ==".
## 실제 user://studylog.json 은 읽지도 쓰지도 않는다: StudyLog.path 를 user://test_a2_* 로 바꿨다가 되돌린다.

const LOG_PATH := "user://test_a2_studylog.json"

var passed: int = 0
var failed: int = 0
var _old_path: String = ""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== study_log_ja start ==")
	_old_path = StudyLog.path
	StudyLog.path = LOG_PATH
	StudyLog.today_override = Plan.days_from_civil(2026, 11, 14)
	_cleanup()
	_test_score_ja()
	_test_has_data_missions()
	_test_obs()
	_test_bad_obs()
	_test_persist()
	_test_old_file()
	_test_unknown_keys()
	_test_sync()
	_test_english_unchanged()
	_test_selfchecks()
	_cleanup()
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	StudyLog.path = _old_path
	print("== study_log_ja: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_json(p: String) -> Variant:
	if not FileAccess.file_exists(p):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(p))


func rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".bad.1", LOG_PATH + ".bad.2", LOG_PATH + ".tmp"]:
		rm(p)


func _fresh() -> void:
	StudyLog.open_hook = Callable()
	_cleanup()
	StudyLog.load_from_disk()


## 일본어 /score 응답 모양
func ja_res(ts: Array, oks: Array, heards: Array = []) -> Dictionary:
	var units: Array = []
	for i in ts.size():
		units.append({"t": ts[i], "ok": oks[i], "conf": 0.5, "heard": (heards[i] if i < heards.size() else null)})
	return {"transcript": "おばあさん", "score": 70, "accuracy": 70, "clarity": 70, "fluency": 70, "units": units, "tips_ko": []}


func rate_of(lang: String, p: String, min_n: int = 1) -> float:
	for r in StudyLog.weak_phonemes(lang, 80, min_n):
		if r["p"] == p:
			return float(r["rate"])
	return -1.0


func row_of(lang: String, p: String) -> Dictionary:
	for r in StudyLog.weak_phonemes(lang, 80, 1):
		if r["p"] == p:
			return r
	return {}


# ---------------------------------------------------------------- has_data: Japanese missions count (v1.7.0 S)

func _test_has_data_missions() -> void:
	print("[has_data with mission records only]")
	_fresh()
	ok(not StudyLog.has_data("ja") and not StudyLog.has_data("en"), "empty log: has_data false for both languages")
	StudyLog.add_mission("ja", "ja_konbini", 2, 3)
	ok(StudyLog.has_data("ja"), "only a Japanese mission record -> has_data('ja') is true")
	ok(not StudyLog.has_data("en"), "only a Japanese mission record -> has_data('en') is false (symmetric)")
	_fresh()
	StudyLog.add_mission("en", "cafe_order", 1, 1)
	ok(StudyLog.has_data("en") and not StudyLog.has_data("ja"), "only an English mission record -> has_data('en') true, has_data('ja') false")
	StudyLog.add_mission("ja", "ja_ramen", 1, 1)
	ok(StudyLog.has_data("en") and StudyLog.has_data("ja"), "English and Japanese mission records -> both true")
	_fresh()
	StudyLog.add_mission("en", "some_old_unlisted_id", 0, 0)
	ok(StudyLog.has_data("en") and not StudyLog.has_data("ja"), "an old English id without any prefix (1.6.x records) still counts for English only")
	_fresh()
	StudyLog.add_mission("en", "cafe_order", 1, 1)
	StudyLog.add_mission("en", "ja", 0, 0) # an id that merely equals the prefix word, not 'ja_...'
	ok(not StudyLog.has_data("ja"), "an id without the 'ja_' prefix is not a Japanese mission")
	_fresh()
	StudyLog.add_mission("ja", "ja_unlisted_new_mission", 0, 0)
	ok(StudyLog.has_data("ja"), "any ja_ id counts (even one this version has no name for, 0 stars)")
	ok(not StudyLog.has_data("xx") and not StudyLog.has_data(""), "an unknown language is false")
	# 저장하고 다시 읽어도 같다
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.has_data("ja"), "after saving and reading the file again: still true")
	_fresh()


# ---------------------------------------------------------------- add_score_any (ja)

func _test_score_ja() -> void:
	print("[add_score_any ja]")
	_fresh()
	var res: Dictionary = ja_res(["お", "ば", "ー", "さ", "ん"], [true, true, false, true, true], [null, null, "あ", null, null])
	var before: Dictionary = res.duplicate(true)
	ok(StudyLog.add_score_any("ja", res, "shadow"), "a Japanese /score response is recorded")
	ok(res == before, "the caller's response is not changed (annotate works on a copy)")
	var weak: Array = StudyLog.weak_phonemes("ja", 6, 1)
	ok(not weak.is_empty() and weak[0]["p"] == "j_long" and float(weak[0]["rate"]) == 1.0, "weak_phonemes('ja') lists j_long first (the missed ー): %s" % str(weak))
	ok(row_of("ja", "j_long").get("heard", {}) == {"あ": 1}, "heard of the wrong unit is counted")
	ok(rate_of("ja", "j_voice") == -1.0, "voice moras that were fine are not 'weak' (no miss)")
	var snap: Dictionary = StudyLog.snapshot()
	ok((snap["phon"]["ja"] as Dictionary).has("j_voice") and str(snap["phon"]["ja"]["j_voice"]["h"]) == "00", "but their results are in the history (h = 00)")
	ok((snap["phon"]["en"] as Dictionary).is_empty(), "English stats stay empty")
	ok(StudyLog.has_data("ja"), "has_data('ja') is true with only phon.ja records")
	# 두 번째 응답: 이번엔 장음을 맞힘 -> 히스토리 "10"
	var res2: Dictionary = ja_res(["お", "ば", "ー", "さ", "ん"], [true, true, true, true, true])
	StudyLog.add_score_any("ja", res2, "shadow")
	ok(str(StudyLog.snapshot()["phon"]["ja"]["j_long"]["h"]) == "10" and rate_of("ja", "j_long") == 0.5, "second response appends to the history (h = 10, rate 0.5)")
	# 점수 평균은 영어와 같은 길
	var r: Array = StudyLog.range_summary("ja", 1)
	ok(int(r[0]["score_n"]) == 2 and int(r[0]["score_sum"]) == 140, "the score average counts both responses")
	# 자가 평가(점수 아님)·무음·깨진 응답은 기록 안 함
	var before_snap: Dictionary = StudyLog.snapshot()
	ok(StudyLog.add_score_any("ja", {"self_rated": true, "transcript": "", "units": [], "score": 100}, "x") == true and StudyLog.snapshot() == before_snap, "self-rated: true but nothing recorded")
	ok(StudyLog.add_score_any("ja", ja_res(["あ"], [false]).merged({"transcript": "  "}, true), "x") == false and StudyLog.snapshot() == before_snap, "silent recording: false, nothing recorded")
	ok(StudyLog.add_score_any("ja", null) == false and StudyLog.add_score_any("ja", "x") == false and StudyLog.add_score_any("fr", ja_res(["あ"], [false])) == false and StudyLog.snapshot() == before_snap, "null / string / unknown language: false, nothing recorded")
	# 엔진이 이미 ph 를 붙인 응답: 그 항목도 같이 기록
	var res3: Dictionary = ja_res(["つ", "き"], [false, true])
	(res3["units"][1] as Dictionary)["ph"] = [{"p": "x_engine", "ok": false}]
	StudyLog.add_score_any("ja", res3, "x")
	ok(rate_of("ja", "j_tsu") == 1.0 and rate_of("ja", "x_engine") == 1.0, "ph entries that came with the response are kept next to ours")
	# annotate 가 못 붙이는 응답(t 가 가나가 아님)도 점수는 기록되고 phon 은 늘지 않는다
	_fresh()
	ok(StudyLog.add_score_any("ja", {"transcript": "hi", "score": 50, "units": [{"t": "hello", "ok": false}]}, "x") and (StudyLog.snapshot()["phon"]["ja"] as Dictionary).is_empty(), "a response annotate cannot read: score counted, phon.ja stays empty")


# ---------------------------------------------------------------- add_phon_obs

func _test_obs() -> void:
	print("[add_phon_obs]")
	_fresh()
	var seq: Array = [[false, "おばさん"], [false, "おばさん"], [true, ""], [false, "おじさん"], [false, "おばさん"]]
	var all_true := true
	for s in seq:
		if not StudyLog.add_phon_obs("ja", "j_long", s[0], s[1]):
			all_true = false
	ok(all_true, "five answers recorded (add_phon_obs returned true each time)")
	var row: Dictionary = row_of("ja", "j_long")
	ok(int(row.get("n", 0)) == 5 and int(row.get("bad", 0)) == 4 and float(row.get("rate", 0.0)) == 0.8, "n 5, bad 4, rate 0.8 (%s)" % str(row))
	ok(row.get("heard", {}) == {"おばさん": 3, "おじさん": 1}, "heard counts: おばさん 3, おじさん 1")
	ok(str(StudyLog.snapshot()["phon"]["ja"]["j_long"]["h"]) == "11011", "history is in answer order (11011)")
	var w: Array = StudyLog.weak_phonemes("ja", 6, 5)
	ok(w.size() == 1 and w[0]["p"] == "j_long", "weak_phonemes('ja', 6, 5) returns it once there are 5 answers")
	ok(StudyLog.is_dirty(), "recording marks the log dirty")
	ok(StudyLog.add_phon_obs("ja", "j_sokuon", true), "a right answer with no heard is fine")
	ok(row_of("ja", "j_sokuon").is_empty() and str(StudyLog.snapshot()["phon"]["ja"]["j_sokuon"]["h"]) == "0", "a right answer records '0' (not weak)")
	# 맞았을 때의 heard 는 무시
	StudyLog.add_phon_obs("ja", "j_tsu", true, "ぜんぜん")
	ok((StudyLog.snapshot()["phon"]["ja"]["j_tsu"]["heard"] as Dictionary).is_empty(), "heard of a right answer is ignored")
	# 영어 칸에도 같은 규칙으로 들어간다
	ok(StudyLog.add_phon_obs("en", "th", false, "s") and rate_of("en", "th") == 1.0, "language en works with the same rules")
	# 12자 경계, 공백 정리
	ok(StudyLog.add_phon_obs("ja", "j_aaaaaaaaaa", false), "a 12-character p is the longest accepted")
	ok(StudyLog.add_phon_obs("ja", "  j_voice  ", false) and rate_of("ja", "j_voice") == 1.0, "p is trimmed")
	# 긴 heard 는 건너뛰고 문항은 센다
	StudyLog.add_phon_obs("ja", "j_za", false, "あ".repeat(20))
	ok(row_of("ja", "j_za").get("heard", {}) == {} and int(row_of("ja", "j_za").get("bad", 0)) == 1, "a too-long heard is dropped but the answer counts")


func _test_bad_obs() -> void:
	print("[add_phon_obs bad input]")
	_fresh()
	StudyLog.add_phon_obs("ja", "j_long", false)
	StudyLog.flush()
	var snap: Dictionary = StudyLog.snapshot()
	var dirty_before: bool = StudyLog.is_dirty()
	var cases: Array = [
		["ja", "", false],
		["ja", "   ", false],
		["ja", "j_aaaaaaaaaaa", false],       # 13 자
		["ja", "j_long_extra_x", true],       # 14 자
		["fr", "j_long", false],
		["", "j_long", false],
		["EN", "th", false],
	]
	for c in cases:
		var r: bool = StudyLog.add_phon_obs(c[0], c[1], c[2], "x")
		ok(r == false, "add_phon_obs('%s', '%s') = false" % [c[0], c[1]])
	ok(StudyLog.snapshot() == snap and StudyLog.is_dirty() == dirty_before, "none of them changed the state or the dirty flag")
	ok(not StudyLog.flush(), "nothing to save after the rejected calls")
	print("selfcheck FAIL-as-expected add_phon_obs: %d bad calls rejected, state unchanged" % cases.size())


# ---------------------------------------------------------------- 저장·다시 읽기

func _test_persist() -> void:
	print("[persist]")
	_fresh()
	StudyLog.add_score_any("ja", ja_res(["お", "ば", "ー", "さ", "ん"], [true, false, false, true, true], [null, "ぱ", "あ", null, null]), "x")
	StudyLog.add_phon_obs("ja", "j_tsu", false, "す")
	ok(StudyLog.flush(), "flush writes the file")
	var disk: Variant = read_json(LOG_PATH)
	ok(disk is Dictionary and ((disk as Dictionary)["phon"]["ja"] as Dictionary).has("j_long") and ((disk as Dictionary)["phon"]["ja"] as Dictionary).has("j_tsu"), "phon.ja has the new keys on disk")
	var weak_before: Array = StudyLog.weak_phonemes("ja", 6, 1)
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok" and StudyLog.weak_phonemes("ja", 6, 1) == weak_before, "reloading gives the same weak list (%d rows)" % weak_before.size())
	# 새 키 6개 전부 길이 한도 안
	_fresh()
	for p in JaSounds.CATEGORIES:
		StudyLog.add_phon_obs("ja", p, false)
	StudyLog.flush()
	StudyLog.load_from_disk()
	var kept := 0
	for p in JaSounds.CATEGORIES:
		if rate_of("ja", p) == 1.0:
			kept += 1
	ok(kept == 6 and JaSounds.CATEGORIES.all(func(p: String) -> bool: return p.length() <= PhonemeStats.MAX_P_LEN), "all 6 category ids are stored and fit the sync key limit (%d)" % kept)


# ---------------------------------------------------------------- 옛 파일 호환

func _test_old_file() -> void:
	print("[old files]")
	# 1.6.x 모양: phon.ja = {} (새 키 없음)
	_cleanup()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "saved": 1700000000, "days": {"2026-11-01": {"ja": {"sec": 60, "by": {"lesson": 60}, "n": {"lessons": 1}, "lesson": [3, 4], "score": [1, 80]}}},
		"phon": {"en": {"th": {"h": "0110", "heard": {"s": 2}}}, "ja": {}}, "freeze": {}, "missions": {}}))
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok" and StudyLog.weak_phonemes("ja", 6, 1).is_empty(), "old file (phon.ja = {}) loads, no Japanese weak sounds")
	ok(rate_of("en", "th", 1) == 0.5 and StudyLog.has_data("ja"), "its English data and Japanese day are intact")
	ok(StudyLog.add_phon_obs("ja", "j_long", false, "あ") and StudyLog.flush(), "a new Japanese result can be added and saved")
	var disk: Dictionary = read_json(LOG_PATH)
	ok(str(disk["phon"]["en"]["th"]["h"]) == "0110" and disk["days"].has("2026-11-01") and (disk["phon"]["ja"] as Dictionary).has("j_long"), "the rewritten file keeps the old English data and day")
	# phon 키가 아예 없는 아주 옛 파일
	_cleanup()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "saved": 1, "days": {}}))
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok" and StudyLog.add_phon_obs("ja", "j_voice", true) and StudyLog.flush(), "a file without phon at all also works")
	# phon.ja 가 이상한 모양 (배열)
	_cleanup()
	write_text(LOG_PATH, JSON.stringify({"v": 1, "phon": {"en": {}, "ja": [1, 2]}}))
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok" and StudyLog.add_phon_obs("ja", "j_voice", false) and rate_of("ja", "j_voice") == 1.0, "phon.ja that is not a dictionary is replaced by an empty one")


func _test_unknown_keys() -> void:
	print("[unknown keys are kept]")
	_cleanup()
	write_text(LOG_PATH, JSON.stringify({"v": 3, "saved": 5, "future_top": {"a": [1, 2, {"b": "c"}]}, "days": {},
		"phon": {"en": {}, "ja": {"j_zz_future": {"h": "1100", "heard": {"x": 1}}, "j_long": {"h": "01", "heard": {}}}}, "missions": {"ja_convenience": {"stars": 2, "plays": 1, "last": "2026-11-10", "done_goals": 2}}}))
	StudyLog.open_hook = Callable()
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok", "a file made by a newer version loads")
	ok(rate_of("ja", "j_long") == 0.5 and rate_of("ja", "j_zz_future") == 0.5, "a new key from another version is shown like any other sound")
	StudyLog.add_phon_obs("ja", "j_long", false, "あ")
	ok(StudyLog.flush(), "save after recording")
	var disk: Dictionary = read_json(LOG_PATH)
	ok(disk.has("future_top") and disk["future_top"]["a"][2]["b"] == "c", "an unknown top-level key survives the rewrite")
	ok((disk["phon"]["ja"] as Dictionary).has("j_zz_future") and str(disk["phon"]["ja"]["j_zz_future"]["h"]) == "1100", "an unknown sound key under phon.ja survives, unchanged")
	ok(str(disk["phon"]["ja"]["j_long"]["h"]) == "011" and int(disk["v"]) == 3, "j_long history grew (011) and the file version is kept (v 3)")
	ok(disk["missions"].has("ja_convenience"), "missions.ja_* is kept")


# ---------------------------------------------------------------- 동기화 정리

func _test_sync() -> void:
	print("[sync]")
	_fresh()
	StudyLog.add_score_any("ja", ja_res(["お", "ば", "ー", "さ", "ん"], [true, true, false, true, true], [null, null, "あ", null, null]), "x")
	for i in 5:
		StudyLog.add_phon_obs("ja", "j_sokuon", i % 2 == 0, "")
	StudyLog.add_phon_obs("ja", "j_tsu", false, "す")
	var snap: Dictionary = StudyLog.snapshot()
	var ja_phon: Dictionary = snap["phon"]["ja"]
	ok(SyncDoc.clean_phon_lang(ja_phon) == ja_phon, "SyncDoc.clean_phon_lang leaves the new keys exactly as they are")
	var view: Dictionary = SyncDoc.extract(Progress.blank(), snap, {}, 0)
	ok((view["phon"]["ja"] as Dictionary).has("j_long") and (view["phon"]["ja"] as Dictionary).has("j_sokuon") and (view["phon"]["ja"] as Dictionary).has("j_tsu"), "SyncDoc.extract carries the Japanese category keys")
	ok(view["phon"]["ja"] == ja_phon, "the extracted Japanese phon equals the local one")
	ok(StudyLog.apply_sync({"phon": view["phon"]}) and StudyLog.snapshot()["phon"]["ja"] == ja_phon, "apply_sync round trip keeps phon.ja unchanged")
	StudyLog.load_from_disk()
	ok(StudyLog.snapshot()["phon"]["ja"] == ja_phon, "and it is the same after reloading from disk")
	# 한도: 길이 13 키는 SyncDoc 가 버리고 로컬도 안 받는다 (add_phon_obs 가 막으므로 파일에서 읽는 경우만)
	var viol: Dictionary = {"j_aaaaaaaaaaa": {"h": "1", "heard": {}}, "j_ok": {"h": "1", "heard": {}}}
	ok(not SyncDoc.clean_phon_lang(viol).has("j_aaaaaaaaaaa") and SyncDoc.clean_phon_lang(viol).has("j_ok"), "SyncDoc drops a key longer than 12 (what add_phon_obs also refuses)")


# ---------------------------------------------------------------- 영어 경로 불변

func _test_english_unchanged() -> void:
	print("[english unchanged]")
	_fresh()
	var en: Dictionary = {"transcript": "hello there", "score": 80, "accuracy": 80, "clarity": 80, "fluency": 80,
		"units": [{"t": "x", "ok": true, "conf": 0.9, "heard": null, "ph": [{"p": "th", "ok": false, "conf": 0.2, "heard": "s"}, {"p": "r", "ok": true, "conf": 0.9, "heard": null}]}]}
	var en_before: Dictionary = en.duplicate(true)
	ok(StudyLog.add_score_any("en", en, "x") and en == en_before, "English response recorded, response not changed")
	ok(rate_of("en", "th") == 1.0 and row_of("en", "th").get("heard", {}) == {"s": 1}, "English phoneme stats are the same as before")
	ok((StudyLog.snapshot()["phon"]["ja"] as Dictionary).is_empty(), "nothing leaks into phon.ja")
	# 영어 응답에 가나 t 가 있어도 영어 칸에는 JaSounds 가 개입하지 않는다
	_fresh()
	StudyLog.add_score_any("en", ja_res(["お", "ば", "ー"], [false, false, false]), "x")
	ok((StudyLog.snapshot()["phon"]["en"] as Dictionary).is_empty(), "lang en never goes through JaSounds.annotate")


# ---------------------------------------------------------------- 검사 자체가 실패할 수 있다

func _test_selfchecks() -> void:
	print("[selfchecks]")
	_fresh()
	for i in 5:
		StudyLog.add_phon_obs("ja", "j_long", i != 0)   # 틀림 1 + 맞음 4 -> 비율 0.2
	var rate: float = rate_of("ja", "j_long")
	ok(rate == 0.2, "control: 1 wrong + 4 right gives rate 0.2")
	ok(not (rate == 0.8), "selfcheck FAIL-as-expected: the rate check rejects 0.8 for 1 wrong of 5")
	print("selfcheck FAIL-as-expected rate_of: expected 0.8, got %s" % str(rate))
	ok(row_of("ja", "j_nope").is_empty(), "selfcheck FAIL-as-expected: a sound that was never recorded is not found")
