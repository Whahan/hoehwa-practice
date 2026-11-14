extends Node
## v1.6.0 B1 (배지 엔진) 규칙 시험: BadgeDefs 25개(§5.5 의 23개 + v1.7.0 일기 배지 2개) = 표, BadgeRules 경계값, 쓰레기 스냅샷.
##   godot --headless --path <project> res://tests/badge_rules_test.tscn
## 종료 코드 0 = 전부 통과. 마지막 줄: "== badge_rules: N passed, 0 failed =="
## 화면이 없는 순수 계산 시험이라 PC 한 번이면 된다. 파일·서버·사용자 폴더는 건드리지 않는다.
## selfcheck FAIL-as-expected: 검사 함수(table_matches / boundary_ok)에 일부러 틀린 값을 넣어 실제로 실패로 판정되는지 확인하는 줄.

# 설계 §5.5 표를 그대로 옮긴 것: [id, 이름, cat, measure, target]. BadgeDefs 가 이것과 다르면 FAIL.
# kana_pairs 의 목표는 짝에 나오는 서로 다른 글자 수(히라가나 17 + 가타카나 20 = 37)를 따로 센 값이다.
const TABLE := [
	["first_lesson", "첫 레슨", "learn", "lessons_total", 1],
	["lessons_10", "레슨 10번", "learn", "lessons_total", 10],
	["lessons_50", "레슨 50번", "learn", "lessons_total", 50],
	["first_talk", "첫 원어민 대화", "speak", "talks_total", 1],
	["cards_20", "복습 카드 20장", "learn", "cards_count", 20],
	["reviews_100", "복습 100번", "learn", "reviews_total", 100],
	["streak_3", "3일 연속", "habit", "streak_best", 3],
	["streak_7", "7일 연속", "habit", "streak_best", 7],
	["streak_30", "30일 연속", "habit", "streak_best", 30],
	["time_1h", "공부 1시간", "habit", "study_sec_total", 3600],
	["time_10h", "공부 10시간", "habit", "study_sec_total", 36000],
	["mission_star3", "미션 별 3개", "speak", "mission_star3", 1],
	["mission_all_star3", "미션 8개 모두 별 3개", "speak", "mission_all_star3", 8],
	["pron_80", "발음 80점", "speak", "pron_day_best", 80],
	["song_first", "첫 가사 등록", "song", "song_lyrics", 1],
	["song_done", "가사 한 곡 다 외움", "song", "song_done", 1],
	["kana_hira", "히라가나 청음 마스터", "kana", "kana_hira_seion", 46],
	["kana_kata", "가타카나 청음 마스터", "kana", "kana_kata_seion", 46],
	["kana_all", "가나 전부 숙련", "kana", "kana_all", 208],
	["kana_pairs", "헷갈리는 글자 극복", "kana", "kana_pairs", 37],
	["speed_first", "첫 스피드 퀴즈", "speed", "speed_plays", 1],
	["speed_combo_10", "콤보 10", "speed", "speed_combo", 10],
	["speed_score_500", "스피드 500점", "speed", "speed_score", 500],
	["diary_first", "첫 일기 고침", "learn", "diary_fixed", 1],
	["diary_7", "일기 7일", "learn", "diary_days", 7],
]

var passed: int = 0
var failed: int = 0


func _ready() -> void:
	print("== badge_rules start ==")
	_selfcheck()
	_defs_vs_table()
	_defs_sanity()
	_mission_ids()
	_boundaries()
	_garbage_snapshots()
	_clean_values()
	_progress_and_misc()
	print("== badge_rules: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- 검사 함수

## defs(BadgeDefs.all() 모양)가 table 과 같은가. 다르면 사유 문자열, 같으면 "".
func table_matches(defs: Array, table: Array) -> String:
	if defs.size() != table.size():
		return "size %d != %d" % [defs.size(), table.size()]
	for i in table.size():
		var d: Dictionary = defs[i]
		var t: Array = table[i]
		if d["id"] != t[0] or d["name"] != t[1] or d["cat"] != t[2] or d["measure"] != t[3] or int(d["target"]) != int(t[4]):
			return "row %d (%s) differs" % [i, t[0]]
	return ""


## 한 배지의 경계: 목표 - 1 이면 못 받고 목표이면 받는다. 사유 문자열("" = 좋음).
func boundary_ok(def: Dictionary) -> String:
	var m: String = def["measure"]
	var t: int = int(def["target"])
	var below: Array = BadgeRules.earned_ids({m: t - 1})
	var at: Array = BadgeRules.earned_ids({m: t})
	if below.has(def["id"]):
		return "%s earned at target-1" % def["id"]
	if not at.has(def["id"]):
		return "%s not earned at target" % def["id"]
	return ""


func _selfcheck() -> void:
	print("[selfcheck]")
	var defs: Array = BadgeDefs.all()
	var wrong_table: Array = TABLE.duplicate(true)
	(wrong_table[7] as Array)[4] = 6 # streak_7 의 목표를 6 으로 틀리게
	var why: String = table_matches(defs, wrong_table)
	print("selfcheck %s table_matches vs streak_7 target 6: %s" % ["FAIL-as-expected" if why != "" else "UNEXPECTED-PASS", why])
	ok(why != "", "table_matches() rejects a table whose streak_7 target is 6")
	var short: Array = TABLE.duplicate(true)
	short.pop_back()
	why = table_matches(defs, short)
	print("selfcheck %s table_matches vs 24 rows: %s" % ["FAIL-as-expected" if why != "" else "UNEXPECTED-PASS", why])
	ok(why != "", "table_matches() rejects a table with 24 rows")
	var wrong_diary: Array = TABLE.duplicate(true)
	(wrong_diary[24] as Array)[4] = 6 # diary_7 의 목표를 6 으로 틀리게
	why = table_matches(defs, wrong_diary)
	print("selfcheck %s table_matches vs diary_7 target 6: %s" % ["FAIL-as-expected" if why != "" else "UNEXPECTED-PASS", why])
	ok(why != "", "table_matches() rejects a table whose diary_7 target is 6")
	var shifted: Dictionary = (defs[7] as Dictionary).duplicate(true)
	shifted["target"] = 6 # 코드 상수를 틀리게 한 것처럼
	why = boundary_ok(shifted)
	print("selfcheck %s boundary_ok vs a def with target 6 (real 7): %s" % ["FAIL-as-expected" if why != "" else "UNEXPECTED-PASS", why])
	# target 6 인 def 를 BadgeRules 는 모르고(id 로 진짜 정의를 쓴다) target-1 = 5, target = 6 을 넣어 본다: 6 은 streak_7 를 못 받으므로 실패해야 한다
	ok(why != "", "boundary_ok() rejects a def whose target is 6 (the real rule needs 7)")


# ---------------------------------------------------------------- 표 = 코드

func _defs_vs_table() -> void:
	print("[defs == design table]")
	var defs: Array = BadgeDefs.all()
	ok(defs.size() == 25, "BadgeDefs.all() has 25 badges")
	var why: String = table_matches(defs, TABLE)
	ok(why == "", "id / name / cat / measure / target equal the table (all 25 rows: design 5.5 + 2 diary)" if why == "" else "table differs: " + why)
	ok(BadgeDefs.pair_letter_count() == 37, "pair letters = 37 (hira 17 + kata 20)")
	ok(BadgeDefs.KANA_ALL_COUNT == KanaData.entries("both").size(), "KANA_ALL_COUNT == KanaData both entries (%d)" % KanaData.entries("both").size())
	ok(BadgeDefs.SEION_COUNT == KanaData.section_entries("hira", "seion").size() and BadgeDefs.SEION_COUNT == KanaData.section_entries("kata", "seion").size(), "SEION_COUNT == seion letters per script")
	ok(BadgeDefs.all() is Array and (BadgeDefs.all()[0] as Dictionary).has("glyph"), "entries carry a glyph")
	var copy: Array = BadgeDefs.all()
	(copy[0] as Dictionary)["target"] = 999
	ok(int((BadgeDefs.all()[0] as Dictionary)["target"]) == 1, "all() returns a copy (editing it leaves the definitions alone)")


func _defs_sanity() -> void:
	print("[defs sanity]")
	var seen := {}
	var dup: int = 0
	var empty: int = 0
	var cats: Array = []
	for c in BadgeDefs.categories():
		cats.append((c as Array)[0])
	var bad_cat: int = 0
	var bad_measure: int = 0
	var bad_glyph: int = 0
	var bad_id: int = 0
	var rx := RegEx.create_from_string("^[a-z0-9_]{1,32}$")
	for d in BadgeDefs.all():
		var def: Dictionary = d
		if seen.has(def["id"]):
			dup += 1
		seen[def["id"]] = true
		if str(def["name"]).strip_edges() == "" or str(def["desc"]).strip_edges() == "":
			empty += 1
		if not cats.has(def["cat"]):
			bad_cat += 1
		if not BadgeRules.MEASURES.has(def["measure"]):
			bad_measure += 1
		if not GlyphIcon.KINDS.has(def["glyph"]):
			bad_glyph += 1
		if rx.search(str(def["id"])) == null:
			bad_id += 1
	ok(dup == 0, "no duplicate ids")
	ok(empty == 0, "every name and desc is non-empty")
	ok(bad_cat == 0, "every cat is in categories()")
	ok(bad_measure == 0, "every measure is a snapshot key (BadgeRules.MEASURES)")
	ok(bad_glyph == 0, "every glyph is a GlyphIcon kind")
	ok(bad_id == 0, "every id fits the StudyLog id form ^[a-z0-9_]{1,32}$")
	ok(BadgeDefs.categories().size() == 6, "6 categories")
	var used := {}
	for d in BadgeDefs.all():
		used[(d as Dictionary)["cat"]] = true
	ok(used.size() == 6, "every category has at least one badge")
	ok(BadgeDefs.by_id("streak_7").get("target", 0) == 7 and BadgeDefs.by_id("nope").is_empty(), "by_id() finds a badge / returns {} for an unknown id")
	ok(BadgeDefs.has("kana_all") and not BadgeDefs.has("nope"), "has()")
	ok(BadgeDefs.ids().size() == 25 and BadgeDefs.ids()[0] == "first_lesson" and BadgeDefs.ids()[24] == "diary_7", "ids() in table order (25)")


func _mission_ids() -> void:
	print("[MISSION_IDS]")
	ok(JSON.stringify(BadgeRules.MISSION_IDS) == JSON.stringify(StatsView.MISSION_ORDER), "BadgeRules.MISSION_IDS == StatsView.MISSION_ORDER")
	ok(BadgeRules.MISSION_IDS.size() == 8, "8 missions")
	var wrong: Array = BadgeRules.MISSION_IDS.duplicate()
	wrong.reverse()
	var same: bool = JSON.stringify(wrong) == JSON.stringify(StatsView.MISSION_ORDER)
	print("selfcheck %s order comparison vs a reversed list" % ("FAIL-as-expected" if not same else "UNEXPECTED-PASS"))
	ok(not same, "the MISSION_IDS comparison rejects a reordered list")
	# v1.7.0: 일본어 8개
	ok(JSON.stringify(BadgeRules.MISSION_IDS_JA) == JSON.stringify(StatsView.MISSION_ORDER_JA), "BadgeRules.MISSION_IDS_JA == StatsView.MISSION_ORDER_JA")
	ok(BadgeRules.MISSION_IDS_JA.size() == 8, "8 Japanese missions")
	var overlap := 0
	for id in BadgeRules.MISSION_IDS_JA:
		if BadgeRules.MISSION_IDS.has(id):
			overlap += 1
	ok(overlap == 0, "no id is in both the English and the Japanese list (overlap %d)" % overlap)
	var all_ja := true
	for id in BadgeRules.MISSION_IDS_JA:
		all_ja = all_ja and str(id).begins_with("ja_") and StatsView.MISSION_NAME_JA.has(id)
	ok(all_ja and StatsView.MISSION_NAME_JA.size() == 8, "every Japanese id starts with ja_ and has a name (8 names)")
	var wrong_ja: Array = BadgeRules.MISSION_IDS_JA.duplicate()
	wrong_ja.reverse()
	var same_ja: bool = JSON.stringify(wrong_ja) == JSON.stringify(StatsView.MISSION_ORDER_JA)
	print("selfcheck %s Japanese order comparison vs a reversed list" % ("FAIL-as-expected" if not same_ja else "UNEXPECTED-PASS"))
	ok(not same_ja, "the MISSION_IDS_JA comparison rejects a reordered list")
	var one_off: Array = BadgeRules.MISSION_IDS_JA.duplicate()
	one_off[3] = "ja_hotel_checkin_x"
	var same_off: bool = JSON.stringify(one_off) == JSON.stringify(StatsView.MISSION_ORDER_JA)
	print("selfcheck %s Japanese comparison vs a list with one changed id" % ("FAIL-as-expected" if not same_off else "UNEXPECTED-PASS"))
	ok(not same_off, "the MISSION_IDS_JA comparison rejects a list with one id changed")
	# 설명만 바뀐 mission_all_star3: id · 이름 · 측정 이름 · 목표는 그대로(TABLE 비교가 따로 본다)
	var d: Dictionary = BadgeDefs.by_id("mission_all_star3")
	ok(d["name"] == "미션 8개 모두 별 3개" and d["measure"] == "mission_all_star3" and int(d["target"]) == 8 and d["desc"] == "한 언어의 미션 8개 모두에서 별 3개를 받았어요.", "mission_all_star3: same id / name / measure / target 8, new description (one language)")
	ok(BadgeDefs.by_id("diary_first")["desc"] != "" and BadgeDefs.by_id("diary_7")["desc"] != "", "the two diary badges have a description")


# ---------------------------------------------------------------- 경계

func _boundaries() -> void:
	print("[boundaries: target-1 no, target yes]")
	for row in TABLE: # 목표는 코드가 아니라 설계 표(TABLE)에서 가져온다: 코드의 목표가 틀리면 이 줄이 실패한다
		var def: Dictionary = {"id": row[0], "measure": row[3], "target": row[4]}
		var why: String = boundary_ok(def)
		ok(why == "", "%s: %d no / %d yes" % [def["id"], int(def["target"]) - 1, def["target"]] if why == "" else why)
	# 한 키만 좋은 값이면 그 측정값을 쓰는 배지만 받는다
	var only: Array = BadgeRules.earned_ids({"lessons_total": 10})
	ok(JSON.stringify(only) == JSON.stringify(["first_lesson", "lessons_10"]), "lessons_total 10 -> exactly first_lesson + lessons_10")
	var all_snap := {}
	for m in BadgeRules.MEASURES:
		all_snap[m] = 1000000
	ok(BadgeRules.earned_ids(all_snap).size() == 25, "every measure huge -> all 25 earned")
	ok(BadgeRules.earned_ids({}).is_empty(), "empty snapshot -> nothing")


# ---------------------------------------------------------------- 일부러 틀린 스냅샷

func _garbage_snapshots() -> void:
	print("[garbage snapshots]")
	var junk: Array = ["x", "100", null, -5, -1, NAN, INF, -INF, true, false, [100], {"a": 1}, Vector2(9, 9), 1.0e99 * -1.0]
	var bad_total: int = 0
	for j in junk:
		var snap := {}
		for m in BadgeRules.MEASURES:
			snap[m] = j
		var got: Array = BadgeRules.earned_ids(snap)
		if not got.is_empty():
			bad_total += 1
			print("    garbage ", var_to_str(j), " earned ", got)
	ok(bad_total == 0, "garbage values (string/null/negative/NaN/INF/true/array/dict) in every key -> no badge")
	# 쓰레기와 좋은 값이 섞인 스냅샷: 좋은 키의 배지만
	var mixed := {"lessons_total": "999", "talks_total": 1, "streak_best": NAN, "speed_plays": true, "song_lyrics": [5], "cards_count": 20}
	var got2: Array = BadgeRules.earned_ids(mixed)
	ok(JSON.stringify(got2) == JSON.stringify(["first_talk", "cards_20"]), "mixed snapshot: only the two valid keys earn (first_talk, cards_20) got=%s" % str(got2))
	ok(BadgeRules.earned_ids(null).is_empty() and BadgeRules.earned_ids("x").is_empty() and BadgeRules.earned_ids([1, 2]).is_empty(), "a non-dictionary snapshot (null / string / array) earns nothing")
	var diary_junk := {"diary_fixed": "3", "diary_days": [7], "lessons_total": 0}
	ok(BadgeRules.earned_ids(diary_junk).is_empty(), "diary measures as a string / array earn nothing")
	ok(BadgeRules.earned_ids({"diary_fixed": 1}) == ["diary_first"] and BadgeRules.earned_ids({"diary_days": 6}).is_empty() and BadgeRules.earned_ids({"diary_days": 7}) == ["diary_7"], "diary_fixed 1 -> diary_first only; diary_days 6 -> none, 7 -> diary_7")
	var partial := {"streak_best": 7}
	ok(JSON.stringify(BadgeRules.earned_ids(partial)) == JSON.stringify(["streak_3", "streak_7"]), "missing keys count as 0: streak_best 7 -> streak_3 + streak_7")
	# 검사기가 틀린 입력을 실제로 막는지: 같은 쓰레기를 '받는다' 고 기대하면 FAIL
	var expect_wrong: bool = BadgeRules.earned_ids({"lessons_total": "100"}).has("first_lesson")
	print("selfcheck %s string \"100\" does not earn first_lesson" % ("FAIL-as-expected" if not expect_wrong else "UNEXPECTED-PASS"))
	ok(not expect_wrong, "a numeric string is not a number")


func _clean_values() -> void:
	print("[clean()]")
	ok(BadgeRules.clean(5) == 5 and BadgeRules.clean(0) == 0, "ints pass through")
	ok(BadgeRules.clean(-3) == 0, "negative -> 0")
	ok(BadgeRules.clean(7.9) == 7, "finite float floors")
	ok(BadgeRules.clean(-0.5) == 0, "negative float -> 0")
	ok(BadgeRules.clean(NAN) == 0 and BadgeRules.clean(INF) == 0 and BadgeRules.clean(-INF) == 0, "NaN / INF -> 0")
	ok(BadgeRules.clean(true) == 0 and BadgeRules.clean(false) == 0, "bool -> 0")
	ok(BadgeRules.clean("12") == 0 and BadgeRules.clean(null) == 0 and BadgeRules.clean([1]) == 0, "string / null / array -> 0")
	ok(BadgeRules.clean(1.0e99) == BadgeRules.MAX_VALUE and BadgeRules.clean(1 << 60) == BadgeRules.MAX_VALUE, "huge values are capped at MAX_VALUE")


func _progress_and_misc() -> void:
	print("[progress()]")
	var def: Dictionary = BadgeDefs.by_id("streak_30")
	var p: Dictionary = BadgeRules.progress(def, {"streak_best": 3})
	ok(p["value"] == 3 and p["target"] == 30 and p["earned"] == false, "progress: 3 / 30 not earned")
	p = BadgeRules.progress(def, {"streak_best": 30})
	ok(p["value"] == 30 and p["earned"] == true, "progress: 30 / 30 earned")
	p = BadgeRules.progress(null, {"streak_best": 30})
	ok(p["earned"] == false and p["target"] == 0, "progress(null def) is not earned")
	p = BadgeRules.progress({"measure": "x", "target": 0}, {"x": 5})
	ok(p["earned"] == false, "a target of 0 never earns")
	p = BadgeRules.progress({"measure": "x", "target": -4}, {"x": 5})
	ok(p["earned"] == false, "a negative target never earns")
	ok(BadgeRules.measure("streak_best", {"streak_best": 4}) == 4 and BadgeRules.measure("streak_best", "oops") == 0 and BadgeRules.measure("nope", {}) == 0, "measure(): value / non-dict snapshot / missing key")
	# 규칙 파일이 기록·파일을 읽지 않는다(순수 계산)
	var code := ""
	for line in FileAccess.get_file_as_string("res://scripts/core/badge_rules.gd").split("\n"):
		var l: String = line
		var h: int = l.find("#")
		code += (l if h < 0 else l.substr(0, h)) + "\n" ## 주석은 빼고 코드만 본다
	ok(code.find("StudyLog") == -1 and code.find("Store.") == -1 and code.find("DiaryStore") == -1 and code.find("FileAccess") == -1 and code.find("Toast") == -1, "badge_rules.gd code never touches StudyLog / Store / files / Toast")
	ok(code.find("BadgeDefs") != -1, "(the check reads real code: BadgeDefs is referenced)")
