extends Node
## WeekReport(주간 리포트 모델) 시험. 순수 계산 + for_lang(StudyLog 읽기) 연결.
##   PC 실행:   godot --headless --path <project> res://tests/week_report_test.tscn
##   (화면이 없는 순수 계산 시험이라 PC 한 번이면 된다. `-- --phone` 을 붙여도 같다.)
## 종료 코드 0 = 전부 통과. 마지막 줄: "== week_report: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 실제 user:// 기록은 읽지도 쓰지도 않는다: Store.prefs_path / progress_path / StudyLog.path 를 user://test_fun_wr_* 로 바꿨다가 되돌린다.
## "selfcheck FAIL-as-expected" 줄 = 검사 함수(sane)에 일부러 틀린 리포트를 넣어 실제로 실패로 판정되는지 확인한 것.

const LOG_PATH := "user://test_fun_wr_studylog.json"
const PROG_PATH := "user://test_fun_wr_progress.json"
const PREFS_PATH := "user://test_fun_wr_prefs.json"
const INT_KEYS := ["days_studied", "minutes", "minutes_prev", "minutes_delta", "lessons", "lessons_prev",
	"lesson_acc", "lesson_acc_prev", "new_cards", "new_cards_prev", "reviews", "reviews_prev", "practice",
	"score_avg", "score_n", "score_prev", "score_prev_n"]

var passed: int = 0
var failed: int = 0
var _old_paths: Array = []


func _ready() -> void:
	print("== week_report start ==")
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS_PATH
	Store.progress_path = PROG_PATH
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	_cleanup()

	_test_selfcheck()
	_test_hand_calc()
	_test_boundaries()
	_test_lines()
	_test_garbage()
	_test_pure()
	_test_for_lang()

	_cleanup()
	StudyLog.load_from_disk() ## 비어 있는 상태(임시 경로)로 돌려 둔다
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	print("== week_report: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _cleanup() -> void:
	for p in [LOG_PATH, LOG_PATH + ".bad", LOG_PATH + ".tmp", PROG_PATH, PREFS_PATH]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ---------------------------------------------------------------- 입력 만들기

## range_summary 항목 한 개. nd = n 사전.
func day(iso: String, sec: int, les_ok: int, les_n: int, sc_n: int, sc_sum: int, nd: Dictionary = {}) -> Dictionary:
	return {"iso": iso, "sec": sec, "lessons_ok": les_ok, "lessons_n": les_n, "score_n": sc_n, "score_sum": sc_sum, "n": nd.duplicate()}


func zero_week(first_day: int) -> Array:
	var a: Array = []
	for i in range(7):
		a.append(day(Plan.days_to_iso(first_day + i), 0, 0, 0, 0, 0))
	return a


## 이번 주(2026-11-08 ~ 11-14). 손계산은 _test_hand_calc 에 있다.
func cur_week() -> Array:
	return [
		day("2026-11-08", 1800, 8, 10, 0, 0, {"lessons": 2, "reviews": 10, "newcards": 5}),
		day("2026-11-09", 0, 0, 0, 0, 0),
		day("2026-11-10", 1200, 7, 10, 3, 240, {"lessons": 2, "reviews": 12, "newcards": 6, "shadow": 2}),
		day("2026-11-11", 29, 0, 0, 0, 0), ## 29초: sec > 0 이라 공부한 날로 센다
		day("2026-11-12", 0, 0, 0, 0, 0, {"talks": 1}), ## n 합 > 0 이라 공부한 날
		day("2026-11-13", 2400, 3, 5, 2, 170, {"lessons": 1, "reviews": 5, "newcards": 1, "dictation": 1, "drill": 2}),
		day("2026-11-14", 2271, 4, 5, 0, 0, {"lessons": 1}),
	]


## 지난 주(2026-11-01 ~ 11-07).
func prev_week() -> Array:
	return [
		day("2026-11-01", 3600, 4, 5, 3, 210, {"lessons": 1, "reviews": 20, "newcards": 2}),
		day("2026-11-02", 0, 0, 0, 0, 0),
		day("2026-11-03", 1200, 3, 5, 0, 0, {"lessons": 1, "reviews": 8}),
		day("2026-11-04", 0, 0, 0, 0, 0),
		day("2026-11-05", 600, 0, 0, 1, 60, {"reviews": 5}),
		day("2026-11-06", 0, 0, 0, 0, 0),
		day("2026-11-07", 0, 0, 0, 0, 0),
	]


# ---------------------------------------------------------------- 검사 함수 (자기 자신도 시험한다)

## 리포트가 계약(§5.3)에 맞는 모양인지. 맞으면 "" , 아니면 이유.
func sane(r: Variant) -> String:
	if not (r is Dictionary):
		return "not a dictionary"
	var d: Dictionary = r
	for k in INT_KEYS:
		if not d.has(k):
			return "missing " + k
		if typeof(d[k]) != TYPE_INT:
			return "not int: " + k
	for k in ["lang", "from", "to", "empty", "score_delta", "lines"]:
		if not d.has(k):
			return "missing " + k
	if typeof(d["empty"]) != TYPE_BOOL:
		return "empty not bool"
	if int(d["days_studied"]) < 0 or int(d["days_studied"]) > 7:
		return "days_studied out of range"
	for k in ["minutes", "minutes_prev", "lessons", "lessons_prev", "new_cards", "new_cards_prev", "reviews", "reviews_prev", "practice", "score_n", "score_prev_n"]:
		if int(d[k]) < 0:
			return "negative " + k
	for k in ["lesson_acc", "lesson_acc_prev", "score_avg", "score_prev"]:
		if int(d[k]) < -1 or int(d[k]) > 100:
			return "out of range " + k
	if int(d["minutes_delta"]) != int(d["minutes"]) - int(d["minutes_prev"]):
		return "minutes_delta mismatch"
	if d["score_delta"] != null and typeof(d["score_delta"]) != TYPE_INT:
		return "score_delta not int/null"
	if not (d["lines"] is Array) or (d["lines"] as Array).size() > 2:
		return "lines bad"
	for l in d["lines"]:
		if not (l is String) or (l as String) == "":
			return "line not a string"
	for k in ["from", "to"]:
		if not (d[k] is String):
			return k + " not a string"
		if d[k] != "" and not Plan.is_valid_iso(d[k]):
			return k + " bad date"
	if (d["from"] == "") != (d["to"] == ""):
		return "from/to half empty"
	if d["to"] != "" and Plan.iso_to_days(d["to"]) - Plan.iso_to_days(d["from"]) != 6:
		return "from/to not 6 days apart"
	return ""


func _test_selfcheck() -> void:
	var good: Dictionary = WeekReport.build(cur_week(), prev_week(), "en", "2026-11-14")
	ok(sane(good) == "", "selfcheck: sane() accepts a real report")
	var bads: Array = []
	var b: Dictionary = good.duplicate(true)
	b["minutes"] = 12.5
	bads.append(["float minutes", b])
	b = good.duplicate(true)
	b["days_studied"] = 9
	bads.append(["days_studied 9", b])
	b = good.duplicate(true)
	b["score_delta"] = "x"
	bads.append(["score_delta string", b])
	b = good.duplicate(true)
	b.erase("lessons")
	bads.append(["missing key", b])
	b = good.duplicate(true)
	b["lines"] = ["a", "b", "c"]
	bads.append(["3 lines", b])
	b = good.duplicate(true)
	b["from"] = "2026-11-01"
	bads.append(["from/to 13 days apart", b])
	b = good.duplicate(true)
	b["minutes_delta"] = 0
	bads.append(["minutes_delta mismatch", b])
	bads.append(["not a dictionary", [1, 2]])
	for e in bads:
		var why: String = sane(e[1])
		ok(why != "", "selfcheck FAIL-as-expected: %s -> %s" % [e[0], why])


# ---------------------------------------------------------------- R1-2 손계산

func _test_hand_calc() -> void:
	var r: Dictionary = WeekReport.build(cur_week(), prev_week(), "en", "2026-11-14")
	ok(sane(r) == "", "hand: report is sane (" + sane(r) + ")")
	ok(r["lang"] == "en" and r["to"] == "2026-11-14" and r["from"] == "2026-11-08", "hand: lang/from/to = en 11-08 ~ 11-14")
	# 이번 주 sec 합 = 1800+0+1200+29+0+2400+2271 = 7700 -> 7700/60 = 128.33 -> 128분
	ok(r["minutes"] == 128, "hand: minutes = round(7700/60) = 128 (got %s)" % r["minutes"])
	# 지난 주 sec 합 = 3600+1200+600 = 5400 -> 90분. 차이 = 128 - 90 = 38
	ok(r["minutes_prev"] == 90, "hand: minutes_prev = 5400/60 = 90")
	ok(r["minutes_delta"] == 38, "hand: minutes_delta = 128 - 90 = 38")
	# n.lessons 합 = 2+2+1+1 = 6, 지난 주 = 1+1 = 2
	ok(r["lessons"] == 6 and r["lessons_prev"] == 2, "hand: lessons 6 (prev 2)")
	# 정답 8+7+3+4 = 22 / 문제 10+10+5+5 = 30 -> 73.33 -> 73 ; 지난 주 (4+3)/(5+5) = 70
	ok(r["lesson_acc"] == 73, "hand: lesson_acc = round(100*22/30) = 73 (got %s)" % r["lesson_acc"])
	ok(r["lesson_acc_prev"] == 70, "hand: lesson_acc_prev = 70")
	# newcards 5+6+1 = 12 (지난 주 2), reviews 10+12+5 = 27 (지난 주 20+8+5 = 33)
	ok(r["new_cards"] == 12 and r["new_cards_prev"] == 2, "hand: new_cards 12 (prev 2)")
	ok(r["reviews"] == 27 and r["reviews_prev"] == 33, "hand: reviews 27 (prev 33)")
	# practice = shadow 2 + dictation 1 + drill 2 = 5 (talks 는 연습이 아님)
	ok(r["practice"] == 5, "hand: practice = 2+1+2 = 5 (talks not counted)")
	# 점수: 3+2 = 5개, 합 240+170 = 410 -> 82 ; 지난 주 3+1 = 4개, 합 270 -> 67.5 -> 68 (0.5 는 올림)
	ok(r["score_n"] == 5 and r["score_avg"] == 82, "hand: score 82 over 5 samples")
	ok(r["score_prev_n"] == 4 and r["score_prev"] == 68, "hand: score_prev = round(67.5) = 68")
	ok(r["score_delta"] == 14, "hand: score_delta = 82 - 68 = 14")
	# 공부한 날: 11-08, 11-10, 11-11(sec 29), 11-12(n.talks), 11-13, 11-14 = 6 (11-09 는 아님)
	ok(r["days_studied"] == 6, "hand: days_studied = 6")
	ok(r["empty"] == false, "hand: not empty")
	ok(r["lines"] == ["지난주보다 38분 더 공부했어요.", "발음 점수가 14점 올랐어요."], "hand: lines = more minutes + score up (%s)" % str(r["lines"]))


# ---------------------------------------------------------------- R1-3 경계

func _test_boundaries() -> void:
	var d0: int = Plan.iso_to_days("2026-11-08")
	# 이번 주만 있고 지난 주 0
	var only_cur: Dictionary = WeekReport.build(cur_week(), zero_week(d0 - 7), "en", "2026-11-14")
	ok(only_cur["minutes_prev"] == 0 and only_cur["minutes_delta"] == only_cur["minutes"], "boundary: only this week -> minutes_prev 0")
	ok(only_cur["lines"][0] == "이번 주 6일 공부했어요.", "boundary: only this week -> rule 4 (got %s)" % str(only_cur["lines"]))
	ok(only_cur["lessons_prev"] == 0 and only_cur["lesson_acc_prev"] == -1 and only_cur["score_prev"] == -1, "boundary: empty prev week -> acc/score -1")
	ok(only_cur["score_delta"] == null, "boundary: no prev scores -> score_delta null")
	# 두 주 다 0
	var none: Dictionary = WeekReport.build(zero_week(d0 - 7), zero_week(d0), "en", "2026-11-14")
	ok(none["empty"] == true and none["days_studied"] == 0 and none["minutes"] == 0, "boundary: both weeks zero -> empty")
	ok(none["lines"] == ["이번 주에는 아직 기록이 없어요. 오늘 10분만 해 볼까요?"], "boundary: empty -> rule 1 only")
	ok(none["lesson_acc"] == -1 and none["score_avg"] == -1 and none["score_delta"] == null, "boundary: empty -> acc/score -1, delta null")
	# 이번 주 0 이지만 지난 주는 있음: empty 는 이번 주 기준
	var gone: Dictionary = WeekReport.build(zero_week(d0), prev_week(), "en", "2026-11-14")
	ok(gone["empty"] == true and gone["minutes_delta"] == -90, "boundary: this week empty even though prev has data")
	# 레슨 0 -> lesson_acc -1 (정답이 0개여도 문제가 있으면 0)
	var no_les: Dictionary = WeekReport.build([day("2026-11-14", 600, 0, 0, 0, 0)], [], "en", "2026-11-14")
	ok(no_les["lesson_acc"] == -1, "boundary: no lesson exercises -> lesson_acc -1")
	var zero_acc: Dictionary = WeekReport.build([day("2026-11-14", 600, 0, 4, 0, 0, {"lessons": 1})], [], "en", "2026-11-14")
	ok(zero_acc["lesson_acc"] == 0, "boundary: 0 of 4 right -> lesson_acc 0 (not -1)")
	# 점수 표본: (2, 5) -> null, (5, 2) -> null, (3, 3) -> 숫자
	var cases: Array = [[2, 5, false], [5, 2, false], [3, 3, true], [2, 2, false], [3, 2, false], [10, 10, true]]
	for c in cases:
		var cw: Array = [day("2026-11-14", 600, 0, 0, c[0], c[0] * 80, {"drill": 1})]
		var pw: Array = [day("2026-11-07", 600, 0, 0, c[1], c[1] * 70, {"drill": 1})]
		var rr: Dictionary = WeekReport.build(cw, pw, "en", "2026-11-14")
		var has_num: bool = rr["score_delta"] != null
		ok(has_num == c[2], "boundary: score_n %d vs %d -> delta %s" % [c[0], c[1], "number" if c[2] else "null"])
		if c[2]:
			ok(rr["score_delta"] == 10, "boundary: score_n %d vs %d -> delta = 80 - 70 = 10" % [c[0], c[1]])
	# 점수가 내려가면 음수(문구엔 안 나옴), 같으면 0
	var down: Dictionary = WeekReport.build([day("2026-11-14", 600, 0, 0, 3, 150, {"drill": 1})], [day("2026-11-07", 600, 0, 0, 3, 240, {"drill": 1})], "en", "2026-11-14")
	ok(down["score_delta"] == -30 and down["lines"].size() == 1, "boundary: score down -> -30, no score line")
	var same: Dictionary = WeekReport.build([day("2026-11-14", 600, 0, 0, 3, 240, {"drill": 1})], [day("2026-11-07", 600, 0, 0, 3, 240, {"drill": 1})], "en", "2026-11-14")
	ok(same["score_delta"] != null and same["score_delta"] == 0 and same["lines"].size() == 1, "boundary: same score -> 0 (int, not null), no score line")
	# 한 주 안의 날 수가 7 을 넘는 입력은 마지막 7개만
	var ten: Array = []
	for i in range(10):
		ten.append(day(Plan.days_to_iso(d0 - 3 + i), 600, 0, 0, 0, 0))
	var tr: Dictionary = WeekReport.build(ten, [], "en", "")
	ok(tr["minutes"] == 70 and tr["days_studied"] == 7, "boundary: 10 items -> only the last 7 count (70 min, 7 days)")
	ok(tr["to"] == Plan.days_to_iso(d0 + 6) and tr["from"] == Plan.days_to_iso(d0), "boundary: to_iso empty -> latest item date, from = to - 6")


# ---------------------------------------------------------------- 문구 규칙

func _test_lines() -> void:
	# 규칙 3: 이번 주 30분 < 지난 주 90분
	var less: Dictionary = WeekReport.build([day("2026-11-14", 1800, 0, 0, 0, 0, {"reviews": 3})], prev_week(), "en", "2026-11-14")
	ok(less["lines"] == ["지난주보다 60분 적어요. 하루 10분만 더 해 볼까요?"], "lines: less than last week -> rule 3 (%s)" % str(less["lines"]))
	# 규칙 3 은 이번 주 분이 0 이면 안 걸린다(20초만 공부): 규칙 4
	var tiny: Dictionary = WeekReport.build([day("2026-11-14", 20, 0, 0, 0, 0, {"lessons": 1})], prev_week(), "en", "2026-11-14")
	ok(tiny["minutes"] == 0 and tiny["empty"] == false and tiny["lines"] == ["이번 주 1일 공부했어요."], "lines: 0 minutes but not empty -> rule 4 (%s)" % str(tiny["lines"]))
	# 같은 분 수 -> 규칙 4
	var eq: Dictionary = WeekReport.build([day("2026-11-14", 5400, 0, 0, 0, 0, {"reviews": 1})], prev_week(), "en", "2026-11-14")
	ok(eq["minutes_delta"] == 0 and eq["lines"] == ["이번 주 1일 공부했어요."], "lines: same minutes -> rule 4")
	# 규칙 2 + 보조(점수 상승 없음) 한 줄만
	var more: Dictionary = WeekReport.build([day("2026-11-14", 7200, 0, 0, 0, 0, {"reviews": 1})], prev_week(), "en", "2026-11-14")
	ok(more["lines"] == ["지난주보다 30분 더 공부했어요."], "lines: more minutes -> rule 2 only")
	# 보조 줄은 규칙 4 에도 붙는다(지난 주 0)
	var sup: Dictionary = WeekReport.build([day("2026-11-14", 600, 0, 0, 3, 240, {"drill": 1})], [day("2026-11-07", 0, 0, 0, 3, 150)], "en", "2026-11-14")
	ok(sup["lines"] == ["이번 주 1일 공부했어요.", "발음 점수가 30점 올랐어요."], "lines: rule 4 + score up supplement (%s)" % str(sup["lines"]))
	ok(sup["lines"].size() <= 2, "lines: at most 2")


# ---------------------------------------------------------------- R1-4 일부러 틀린 입력

func _test_garbage() -> void:
	var good_prev: Array = prev_week()
	# 입력 자체가 배열이 아님 / 비었음 / 짧음
	var odd: Array = [null, 5, "x", 1.5, true, {}, {"a": 1}, [1, 2], PackedInt32Array([1])]
	for i in range(odd.size()):
		var r: Dictionary = WeekReport.build(odd[i], odd[i], "en", "2026-11-14")
		ok(sane(r) == "" and r["empty"] == true, "garbage: non-array input #%d -> empty, sane (%s)" % [i, sane(r)])
	var r0: Dictionary = WeekReport.build([], [], "en", "")
	ok(sane(r0) == "" and r0["empty"] == true and r0["from"] == "" and r0["to"] == "", "garbage: empty arrays -> empty, from/to \"\"")
	var five: Array = cur_week().slice(0, 5)
	var r5: Dictionary = WeekReport.build(five, good_prev, "en", "2026-11-14")
	# 5개뿐: 11-08..11-12 = sec 1800+0+1200+29+0 = 3029 -> 50분
	ok(sane(r5) == "" and r5["minutes"] == 50 and r5["days_studied"] == 4, "garbage: only 5 items -> counted as given (50 min, 4 days) (%s)" % sane(r5))
	# 항목이 숫자·문자열·null
	var junk_items: Array = [5, "x", null, [1], 2.5, true, {}]
	var rj: Dictionary = WeekReport.build(junk_items, junk_items, "en", "2026-11-14")
	ok(sane(rj) == "" and rj["empty"] == true and rj["days_studied"] == 0, "garbage: items are numbers/strings/null -> all zero, empty")
	# sec 가 음수·NaN·INF·문자열·bool·거대한 값
	var bad_sec: Array = [-5, NAN, INF, -INF, "100", true, null, [60], {"x": 1}, -0.0]
	for i in range(bad_sec.size()):
		var it: Dictionary = day("2026-11-14", 0, 0, 0, 0, 0)
		it["sec"] = bad_sec[i]
		var rs: Dictionary = WeekReport.build([it], [], "en", "2026-11-14")
		ok(sane(rs) == "" and rs["minutes"] == 0 and rs["empty"] == true, "garbage: sec=%s -> 0 minutes, empty (%s)" % [str(bad_sec[i]), sane(rs)])
	var huge: Dictionary = day("2026-11-14", 0, 0, 0, 0, 0)
	huge["sec"] = 1.0e30
	var rh: Dictionary = WeekReport.build([huge], [], "en", "2026-11-14")
	ok(sane(rh) == "" and rh["minutes"] == 1440, "garbage: sec=1e30 -> capped at one day (1440 min)")
	var huge_i: Dictionary = day("2026-11-14", 9223372036854775807, 0, 0, 0, 0)
	var rhi: Dictionary = WeekReport.build([huge_i], [], "en", "2026-11-14")
	ok(sane(rhi) == "" and rhi["minutes"] == 1440, "garbage: sec=int64 max -> capped (1440 min)")
	# n 이 배열·문자열, n 값이 음수·NaN·문자열
	var bad_n: Array = [[1, 2], "x", null, 5, {"lessons": -3, "reviews": NAN, "newcards": "9", "shadow": INF, "drill": true}]
	for i in range(bad_n.size()):
		var it2: Dictionary = day("2026-11-14", 0, 0, 0, 0, 0)
		it2["n"] = bad_n[i]
		var rn: Dictionary = WeekReport.build([it2], [], "en", "2026-11-14")
		ok(sane(rn) == "" and rn["empty"] == true and rn["lessons"] == 0 and rn["new_cards"] == 0 and rn["practice"] == 0, "garbage: bad n #%d -> all zero, empty (%s)" % [i, sane(rn)])
	# 점수 합이 말이 안 됨(> n*100), 정답 > 문제
	var wild: Dictionary = day("2026-11-14", 600, 9, 3, 3, 9999, {"drill": 1})
	var rw: Dictionary = WeekReport.build([wild], [], "en", "2026-11-14")
	ok(sane(rw) == "" and rw["score_avg"] == 100 and rw["lesson_acc"] == 100, "garbage: score_sum > n*100 -> capped avg 100, ok > total -> 100%% (%s)" % sane(rw))
	var neg_score: Dictionary = day("2026-11-14", 600, 0, 0, -3, -90, {"drill": 1})
	var rns: Dictionary = WeekReport.build([neg_score], [], "en", "2026-11-14")
	ok(sane(rns) == "" and rns["score_n"] == 0 and rns["score_avg"] == -1, "garbage: negative score counts -> 0 samples, -1")
	# 날짜가 거꾸로(내림차순)·깨진 날짜·날짜 없음
	var rev: Array = cur_week()
	rev.reverse()
	var rr: Dictionary = WeekReport.build(rev, prev_week(), "en", "")
	ok(sane(rr) == "" and rr["to"] == "2026-11-14" and rr["from"] == "2026-11-08", "garbage: reversed dates -> to = latest date (%s ~ %s)" % [rr["from"], rr["to"]])
	var bad_dates: Array = []
	for s in ["2026-13-40", "x", "", "2026-2-3", "9999-99-99", 5, null]:
		var bd: Dictionary = day("2026-11-14", 600, 0, 0, 0, 0, {"reviews": 1})
		bd["iso"] = s
		bad_dates.append(bd)
	var rbd: Dictionary = WeekReport.build(bad_dates, [], "en", "")
	ok(sane(rbd) == "" and rbd["to"] == "" and rbd["from"] == "" and rbd["empty"] == false, "garbage: broken dates -> from/to \"\", numbers still counted (%s)" % sane(rbd))
	for s in ["2026-13-40", "x", "2026-2-3", "", "2026-11-31"]:
		var rt: Dictionary = WeekReport.build(cur_week(), good_prev, "en", s)
		ok(sane(rt) == "" and rt["to"] == "2026-11-14", "garbage: to_iso=%s -> falls back to the latest item date" % s)
	# 알 수 없는 언어 이름
	var rl: Dictionary = WeekReport.build(cur_week(), good_prev, "xx", "2026-11-14")
	ok(sane(rl) == "" and rl["lang"] == "en", "garbage: unknown lang -> \"en\"")
	var rja: Dictionary = WeekReport.build(cur_week(), good_prev, "ja", "2026-11-14")
	ok(rja["lang"] == "ja", "lang: ja is kept")
	# 항목 안에 알 수 없는 키가 있어도 무시
	var extra: Dictionary = day("2026-11-14", 600, 0, 0, 0, 0, {"reviews": 1, "zzz_unknown": 5})
	extra["junk"] = [1, 2, 3]
	var rx: Dictionary = WeekReport.build([extra], [], "en", "2026-11-14")
	ok(sane(rx) == "" and rx["reviews"] == 1 and rx["minutes"] == 10, "garbage: unknown keys ignored")
	# 요청한 키가 아예 없는 항목
	var rk: Dictionary = WeekReport.build([{}, {"iso": "2026-11-14"}], [{}], "en", "2026-11-14")
	ok(sane(rk) == "" and rk["empty"] == true and rk["to"] == "2026-11-14", "garbage: items without keys -> zeros")


# ---------------------------------------------------------------- R1-6 같은 입력 두 번 / 입력 불변

func _test_pure() -> void:
	var c: Array = cur_week()
	var p: Array = prev_week()
	var c_copy: Array = c.duplicate(true)
	var p_copy: Array = p.duplicate(true)
	var a: Dictionary = WeekReport.build(c, p, "en", "2026-11-14")
	var b: Dictionary = WeekReport.build(c, p, "en", "2026-11-14")
	ok(a == b, "pure: same input twice -> same result")
	ok(c == c_copy and p == p_copy, "pure: input arrays not modified")
	# 결과를 고쳐도 다음 호출에 영향이 없다
	a["minutes"] = 999
	(a["lines"] as Array).append("x")
	var c2: Dictionary = WeekReport.build(c, p, "en", "2026-11-14")
	ok(c2 == b, "pure: mutating a result does not leak into the next call")
	# 더러운 입력도 불변
	var dirty: Array = [{"sec": NAN, "n": [1]}, 5, null, {"sec": -3, "iso": "x"}]
	var dirty_copy: Array = dirty.duplicate(true)
	WeekReport.build(dirty, dirty, "en", "")
	ok(str(dirty) == str(dirty_copy), "pure: dirty input arrays not modified")


# ---------------------------------------------------------------- R1-5 for_lang 실제 연결

func _rec(it: Dictionary) -> Dictionary:
	return {"sec": it["sec"], "n": it["n"], "lesson": [it["lessons_ok"], it["lessons_n"]], "score": [it["score_n"], it["score_sum"]]}


func _test_for_lang() -> void:
	var today: int = Plan.iso_to_days("2026-11-14")
	var days := {}
	for it in prev_week() + cur_week():
		var iso: String = it["iso"]
		if int(it["sec"]) > 0 or not (it["n"] as Dictionary).is_empty():
			days[iso] = {"en": _rec(it)}
	# 14일 창 밖(10-31)과 미래(11-15): 합에 들어가면 안 된다
	days["2026-10-31"] = {"en": _rec(day("x", 9999, 5, 5, 3, 300, {"lessons": 9, "reviews": 99}))}
	days["2026-11-15"] = {"en": _rec(day("x", 5000, 5, 5, 3, 300, {"lessons": 9, "reviews": 99}))}
	# 같은 날 일본어 기록은 영어 리포트에 섞이면 안 된다
	days["2026-11-14"]["ja"] = _rec(day("x", 600, 1, 2, 3, 150, {"lessons": 1, "newcards": 7}))
	days["2026-11-13"]["ja"] = _rec(day("x", 600, 1, 2, 3, 150, {"lessons": 1}))
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "days": days}))
	f.close()
	StudyLog.path = LOG_PATH
	StudyLog.today_override = today
	StudyLog.load_from_disk()
	var raw: Array = StudyLog.range_summary("en", 14)
	ok(raw.size() == 14, "for_lang: range_summary gives 14 items")

	var fl: Dictionary = WeekReport.for_lang("en")
	var direct: Dictionary = WeekReport.build(cur_week(), prev_week(), "en", "2026-11-14")
	ok(sane(fl) == "", "for_lang: report is sane (" + sane(fl) + ")")
	ok(fl["from"] == "2026-11-08" and fl["to"] == "2026-11-14", "for_lang: from/to = today-6 / today (%s ~ %s)" % [fl["from"], fl["to"]])
	ok(fl == direct, "for_lang: equals build() on the hand-made weeks")
	ok(fl["minutes"] == 128 and fl["minutes_delta"] == 38 and fl["lesson_acc"] == 73 and fl["score_avg"] == 82 and fl["days_studied"] == 6, "for_lang: same hand-calculated numbers as R1-2")
	ok(fl["new_cards"] == 12 and fl["reviews"] == 27, "for_lang: n.newcards / n.reviews read from the log")
	ok(fl["lines"] == ["지난주보다 38분 더 공부했어요.", "발음 점수가 14점 올랐어요."], "for_lang: same lines")

	var ja: Dictionary = WeekReport.for_lang("ja")
	# 일본어: 11-13, 11-14 에 600초씩 = 1200초 = 20분, 레슨 2, 새 카드 7
	ok(sane(ja) == "" and ja["lang"] == "ja" and ja["minutes"] == 20 and ja["lessons"] == 2 and ja["new_cards"] == 7, "for_lang: ja separate from en (%d min, %d lessons)" % [ja["minutes"], ja["lessons"]])
	ok(ja["lesson_acc"] == 50 and ja["minutes_prev"] == 0 and ja["days_studied"] == 2, "for_lang: ja acc 50, prev week empty, 2 days")

	var bad: Dictionary = WeekReport.for_lang("xx")
	ok(sane(bad) == "" and bad["empty"] == true and bad["lang"] == "en", "for_lang: unknown lang -> empty report, no error")
	ok(bad["to"] == "2026-11-14", "for_lang: unknown lang still reports today as `to`")

	# 날짜를 하루 옮기면 창도 같이 옮겨진다(11-08 기록이 빠지고 11-15 기록이 들어온다)
	StudyLog.today_override = today + 1
	var shifted: Dictionary = WeekReport.for_lang("en")
	ok(shifted["from"] == "2026-11-09" and shifted["to"] == "2026-11-15", "for_lang: window follows today_override")
	ok(shifted["lessons"] == 6 - 2 + 9, "for_lang: window moved by one day (11-08 out, 11-15 in): lessons %d" % shifted["lessons"])
	StudyLog.today_override = today

	# StudyLog 를 쓰지 않는다: 호출 전후 snapshot 이 같고 dirty 가 아니다
	var before: String = JSON.stringify(StudyLog.snapshot())
	WeekReport.for_lang("en")
	WeekReport.for_lang("ja")
	ok(JSON.stringify(StudyLog.snapshot()) == before and not StudyLog.is_dirty(), "for_lang: read only (snapshot unchanged, not dirty)")
