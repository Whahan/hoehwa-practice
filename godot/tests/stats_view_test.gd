extends Node
## "기록" 탭(StatsView), GoalCard, MiniChart 레이아웃·내용 테스트 (412x915 폰 / 1280x800 PC × 빈 기록 / 풍부한 기록).
##   godot --headless --path <project> res://tests/stats_view_test.tscn
## v1.7.0: 일본어 탭에도 약한 소리 카드(일본어 소리 칸)와 미션 카드(일본어 미션 8개)가 있다(_test_japanese_cards).
## 종료 코드 0 = 전부 통과. 마지막 줄: "== stats_view result: N passed, 0 failed =="
## 실제 studylog.json / progress.json / prefs.json 은 읽지도 쓰지도 않는다:
## Store.prefs_path / Store.progress_path / StudyLog.path 를 user://t1_test_* 로 바꿨다가 끝나면 원래 값으로 되돌린다.

const LOG_PATH := "user://t1_test_stats_log.json"
const PROG_PATH := "user://t1_test_stats_progress.json"
const PREFS_PATH := "user://t1_test_stats_prefs.json"
const SIZES := [Vector2(412, 915), Vector2(1280, 800)]

var passed: int = 0
var failed: int = 0
var D: int = 0
var _old_paths: Array = []
var _nav: Array = []


func _ready() -> void:
	print("== stats_view start ==")
	D = Plan.days_from_civil(2026, 10, 16)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	_rm(PREFS_PATH)
	Store.prefs_path = PREFS_PATH
	Store.load_prefs() ## defaults: the real prefs.json is never read
	Store.progress_path = PROG_PATH
	StudyLog.path = LOG_PATH
	StudyLog.today_override = D
	Store.navigate.connect(func(v: String, l: String) -> void: _nav.append([v, l]))
	Store.set_lang("en")

	for dataset in ["empty", "rich"]:
		for sz in SIZES:
			await _combo(dataset, sz)
	await _test_switching()
	await _test_japanese_cards()
	_test_pure_helpers()
	await _test_report_once()
	await _test_goal_card()
	await _test_chart_robustness()
	await _test_lifecycle()

	_rm(LOG_PATH)
	_rm(LOG_PATH + ".tmp")
	_rm(PROG_PATH)
	_rm(PREFS_PATH)
	StudyLog.load_from_disk() ## empty state while the path is still the temp one
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	print("== stats_view result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- helpers

func _read(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func _write(p: String, t: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(t)
	f.close()


func _rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _frames(n: int = 3) -> void:
	for i in n:
		await get_tree().process_frame


func _load_dataset(dataset: String) -> void:
	_rm(LOG_PATH)
	Store.progress = Progress.blank()
	for off in [-2, -1, 0]:
		Store.progress["days"][Plan.days_to_iso(D + off)] = {"en": true}
	if dataset == "rich":
		_write(LOG_PATH, _read("res://tests/sample_studylog.json"))
	StudyLog.today_override = D
	StudyLog.load_from_disk()


func _walk(node: Node, out: Array = []) -> Array:
	out.append(node)
	for ch in node.get_children():
		_walk(ch, out)
	return out


func _texts(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is Label:
			out.append((n as Label).text)
		elif n is Button:
			out.append((n as Button).text)
	return out


func _any_text(node: Node, part: String) -> bool:
	for t in _texts(node):
		if part in str(t):
			return true
	return false


func _charts(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is MiniChart:
			out.append(n)
	return out


func _make(sz: Vector2) -> Array:
	var holder := Control.new()
	holder.size = sz
	add_child(holder)
	var v := StatsView.new()
	holder.add_child(v)
	v.size = sz
	await _frames(3)
	return [holder, v]


## L1 (no horizontal overflow) and L2 (touch targets) checks. Returns the number of buttons seen.
func _layout_checks(v: StatsView, sz: Vector2, tag: String) -> int:
	var min_w: float = v._scroll.column.get_combined_minimum_size().x
	ok(min_w <= sz.x, "%s: L1 content minimum width %.0f <= %.0f" % [tag, min_w, sz.x])
	var small: Array = []
	var buttons := 0
	var exempt := 0
	for n in _walk(v):
		if n is Button and (n as Button).is_visible_in_tree():
			buttons += 1
			if bool((n as Button).get_meta("touch_exempt", false)):
				exempt += 1
			elif (n as Button).size.y < 43.5:
				small.append("%s h=%.1f" % [(n as Button).text, (n as Button).size.y])
	ok(buttons >= 8 and small.is_empty() and exempt <= 3, "%s: L2 %d buttons, none under 44 px %s (exempt %d)" % [tag, buttons, str(small), exempt])
	var wide: Array = []
	for n in _walk(v._scroll.content):
		if n is Control and (n as Control).is_visible_in_tree() and (n as Control).get_global_rect().end.x > sz.x + 1.5:
			wide.append("%s %.0f" % [n.get_class(), (n as Control).get_global_rect().end.x])
	ok(wide.is_empty(), "%s: L4 nothing sticks out to the right of %.0f px %s" % [tag, sz.x, str(wide.slice(0, 3))])
	return buttons


# ---------------------------------------------------------------- 2 sizes x 2 datasets

func _combo(dataset: String, sz: Vector2) -> void:
	var tag := "%s %dx%d" % [dataset, sz.x, sz.y]
	print("[%s]" % tag)
	_load_dataset(dataset)
	Store.prefs["daily_goal_min"] = 15
	Store.set_lang("en")
	var made: Array = await _make(sz)
	var holder: Control = made[0]
	var v: StatsView = made[1]
	ok(is_instance_valid(v) and v._scroll.content.get_child_count() >= 4, "%s: view built (%d blocks)" % [tag, v._scroll.content.get_child_count()])
	await _layout_checks(v, sz, tag)
	ok(v._grid != null and v._grid.columns == (2 if sz.x >= 700.0 else 1), "%s: chart grid has %d column(s)" % [tag, v._grid.columns])
	var charts: Array = _charts(v)
	if dataset == "empty":
		ok(charts.is_empty(), "%s: no chart without data" % tag)
		ok(_any_text(v, "아직 기록이 없어요"), "%s: empty-state text shown" % tag)
		ok(_any_text(v, "표본이 더 쌓이면") and _any_text(v, "아직 한 미션이 없어요"), "%s: weak sounds + missions empty states" % tag)
	else:
		ok(charts.size() == 3, "%s: 3 charts (week / lesson / score), got %d" % [tag, charts.size()])
		var all_data := true
		for c in charts:
			all_data = all_data and (c as MiniChart).has_data()
		ok(all_data, "%s: every chart has data" % tag)
		ok(not _any_text(v, "아직 기록이 없어요"), "%s: no empty-state text" % tag)
		ok(_any_text(v, "/θ/") and _any_text(v, "/ɹ/") and _any_text(v, "/f/") and not _any_text(v, "/ð/"), "%s: weak sounds θ ɹ f (ð has only 4 samples)" % tag)
		ok(_any_text(v, "카페 주문 ★★★") and _any_text(v, "자기소개 ★★☆") and _any_text(v, "호텔 체크인 ★☆☆"), "%s: mission stars shown" % tag)
		ok(_any_text(v, "집중 연습"), "%s: practice button" % tag)
	ok(_any_text(v, "연속 3일") and _any_text(v, "보호권 1개"), "%s: goal card shows streak 3 and 1 token" % tag)
	ok(_any_text(v, "/ 15분"), "%s: goal card shows the 15 minute goal" % tag)
	# v1.6.0: the weekly report card sits right under the goal card and above the weekly bar card
	var kids: Array = v._scroll.content.get_children()
	var gi := -1
	var ri := -1
	var wi := -1
	for i in kids.size():
		if kids[i] is GoalCard:
			gi = i
		elif kids[i].has_meta("report"):
			ri = i
		elif kids[i] is CardBox and _any_text(kids[i], "이번 주 공부 시간"):
			wi = i
	ok(gi >= 0 and ri == gi + 1 and wi > ri, "%s: report card is the block right after the goal card (goal %d, report %d, week bars %d)" % [tag, gi, ri, wi])
	if ri >= 0:
		ok(_any_text(kids[ri], "이번 주 리포트") and _any_text(kids[ri], "(영어)"), "%s: report card is titled for the week and the language" % tag)
		if dataset == "empty":
			ok(bool(kids[ri].get_meta("empty")) and not _any_text(kids[ri], "아직 기록이 없어요") and _any_text(kids[ri], "쌓여요"), "%s: empty data -> the report card keeps quiet (the page's own line says it once)" % tag)
			var page_lines := 0
			for k in kids:
				if k is Label and "아직 기록이 없어요" in (k as Label).text:
					page_lines += 1
			ok(page_lines == 1, "%s: empty data -> exactly one page-level 'no record yet' line (got %d)" % [tag, page_lines])
		else:
			ok(not bool(kids[ri].get_meta("empty")) and _any_text(kids[ri], "새 카드") and _any_text(kids[ri], "발음 점수") and _any_text(kids[ri], "정답률"), "%s: rich data -> the report card shows cards, pronunciation and accuracy" % tag)

	# resize to the other size and back: columns follow, no overflow
	var other: Vector2 = SIZES[1] if sz == SIZES[0] else SIZES[0]
	holder.size = other
	v.size = other
	await _frames(3)
	ok(v._grid.columns == (2 if other.x >= 700.0 else 1), "%s: after resizing to %dx%d the grid has %d column(s)" % [tag, other.x, other.y, v._grid.columns])
	await _layout_checks(v, other, tag + " -> resized")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- language switch, refresh, practice button

func _test_switching() -> void:
	print("[language switch / refresh]")
	_load_dataset("rich")
	var made: Array = await _make(SIZES[0])
	var holder: Control = made[0]
	var v: StatsView = made[1]
	ok(v.lang == "en" and _any_text(v, "약한 소리 TOP 3"), "starts in English with the weak-sound card")
	v.set_lang("ja")
	await _frames(2)
	ok(v.lang == "ja" and Store.lang() == "ja", "set_lang('ja') switches the page and the app language")
	ok(_any_text(v, "약한 소리 TOP 3") and _any_text(v, "미션 별점") and not _any_text(v, "영어에서만"), "Japanese page: the weak-sound and mission cards are there (v1.7.0), no 'English only' note")
	ok(_charts(v).size() == 3, "Japanese page: 3 charts from the ja records")
	var rep_ja: Control = null
	for ch in v._scroll.content.get_children():
		if ch.has_meta("report"):
			rep_ja = ch
	ok(rep_ja != null and _any_text(rep_ja, "(일본어)"), "Japanese page: the report card is for Japanese")
	await _layout_checks(v, SIZES[0], "ja 412")
	v.set_lang("xx")
	ok(v.lang == "ja", "unknown language ignored")
	v.set_lang("en")
	await _frames(2)
	v.refresh()
	await _frames(3)
	ok(v.lang == "en" and _charts(v).size() == 3, "refresh() rebuilds the English page")
	# practice button
	_nav.clear()
	var found: Button = null
	for n in _walk(v):
		if n is Button and (n as Button).text == "집중 연습":
			found = n
	ok(found != null, "practice button exists")
	if found != null:
		found.pressed.emit()
		ok(_nav.size() == 1 and _nav[0][0] == "practice" and _nav[0][1] == "en", "pressing it asks main to open the practice tab (%s)" % str(_nav))
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- v1.7.0 S-5: Japanese weak sounds + Japanese mission chips

func _chip_texts(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is PanelContainer and (n as PanelContainer).tooltip_text != "":
			out.append([_first_label_text(n), (n as PanelContainer).tooltip_text])
	return out


func _first_label_text(node: Node) -> String:
	for n in _walk(node):
		if n is Label:
			return (n as Label).text
	return ""


## 화면 전체 글(Label / Button / 툴팁)에서 연속 5자리 이상 숫자를 찾는다(C-15). 찾은 글 목록.
func _raw_numbers(node: Node) -> Array:
	var rx := RegEx.new()
	rx.compile("[0-9]{5,}")
	var out: Array = []
	for t in _texts(node):
		if rx.search(str(t)) != null:
			out.append(str(t))
	for n in _walk(node):
		if n is Control and (n as Control).tooltip_text != "" and rx.search((n as Control).tooltip_text) != null:
			out.append((n as Control).tooltip_text)
	return out


func _find_button(node: Node, text: String) -> Button:
	for n in _walk(node):
		if n is Button and (n as Button).text == text:
			return n
	return null


func _test_japanese_cards() -> void:
	print("[v1.7.0 Japanese weak sounds + mission chips]")
	# --- 기록이 없을 때: 두 카드는 있고 빈 상태 글만
	_load_dataset("empty")
	Store.set_lang("ja")
	var made: Array = await _make(SIZES[0])
	var holder: Control = made[0]
	var v: StatsView = made[1]
	ok(v.lang == "ja" and _any_text(v, "약한 소리 TOP 3") and _any_text(v, "표본이 더 쌓이면") and _any_text(v, "일본어 약한 소리"), "empty ja records: weak-sound card with its empty-state text (Japanese wording)")
	ok(_any_text(v, "미션 별점") and _any_text(v, "아직 한 미션이 없어요") and _find_button(v, "집중 연습") == null, "empty ja records: mission card says no mission yet, no practice button")
	holder.queue_free()
	await _frames(2)
	# --- 기록: 일본어 소리 칸 + 미션
	_load_dataset("empty")
	for i in 10: # long vowel: 4 wrong of 10 (40%); heard "あ" most
		StudyLog.add_phon_obs("ja", "j_long", i >= 4, "あ" if i < 4 else "")
	for i in 6: # sokuon: 2 wrong of 6 (33%)
		StudyLog.add_phon_obs("ja", "j_sokuon", i >= 2)
	for i in 8: # voice: 1 wrong of 8 (13%)
		StudyLog.add_phon_obs("ja", "j_voice", i != 0)
	for i in 3: # too few samples (3 < 5): not listed
		StudyLog.add_phon_obs("ja", "j_tsu", false)
	StudyLog.add_mission("ja", "ja_konbini", 3, 5)
	StudyLog.add_mission("ja", "ja_konbini", 3, 5)
	StudyLog.add_mission("ja", "ja_ramen", 2, 3)
	StudyLog.add_mission("ja", "ja_self_intro", 1, 1)
	StudyLog.add_mission("ja", "ja_new_mission", 3, 1) # 목록에 없지만 일본어 접두어
	StudyLog.add_mission("en", "cafe_order", 3, 4)
	StudyLog.add_mission("en", "other_new_mission", 2, 1) # 목록에 없고 접두어 없음 = 영어 쪽
	StudyLog.flush()
	Store.set_lang("ja")
	made = await _make(SIZES[0])
	holder = made[0]
	v = made[1]
	var long_label: String = JaSounds.label_of("j_long")
	ok(long_label.contains("장음"), "(precondition) JaSounds.label_of('j_long') = '%s'" % long_label)
	ok(_any_text(v, long_label + " 틀림 40%") and _any_text(v, "로 들림"), "ja weak chip: '%s 틀림 40%%' with the heard hint" % long_label)
	ok(_any_text(v, JaSounds.label_of("j_sokuon") + " 틀림 33%") and _any_text(v, JaSounds.label_of("j_voice") + " 틀림 13%"), "ja weak chips: 촉음 33%, 청탁 13% (top 3 by wrong rate)")
	ok(not _any_text(v, JaSounds.label_of("j_tsu")), "a sound with fewer than 5 samples is not listed")
	ok(not _any_text(v, "/j_long/") and not _any_text(v, "j_long"), "the Japanese chips use the label, never the raw id or the English /x/ form")
	ok(_any_text(v, "편의점 ★★★") and _any_text(v, "라멘집 ★★☆") and _any_text(v, "자기소개 ★☆☆"), "ja mission chips: 편의점 ★★★, 라멘집 ★★☆, 자기소개 ★☆☆")
	ok(_any_text(v, "ja_new_mission ★★★"), "an unlisted ja_ id is added after the 8 and shown by its id")
	ok(not _any_text(v, "카페 주문") and not _any_text(v, "other_new_mission"), "ja page: no English mission chips (listed or unlisted)")
	var tips: Array = _chip_texts(v)
	var konbini_tip := false
	for t in tips:
		if str(t[0]).begins_with("편의점") and str(t[1]) == "2번 도전":
			konbini_tip = true
	ok(konbini_tip, "the konbini chip says '2번 도전' (tooltip)")
	# 순서: 정해진 순서(편의점, 라멘집, ..., 자기소개) 다음에 이름 없는 id
	var order: Array = []
	for t in tips:
		if str(t[1]).ends_with("도전"):
			order.append(str(t[0]).get_slice(" ", 0))
	ok(order == ["편의점", "라멘집", "자기소개", "ja_new_mission"], "ja chips follow MISSION_ORDER_JA, then the unlisted id: %s" % str(order))
	ok(_raw_numbers(v).is_empty(), "no 5+ digit number anywhere on the Japanese page %s" % str(_raw_numbers(v).slice(0, 3)))
	await _layout_checks(v, SIZES[0], "ja data 412")
	# 집중 연습: 가장 틀린 비율이 높은 소리(j_long)로
	_nav.clear()
	PracticeView.pending = {}
	var b: Button = _find_button(v, "집중 연습")
	ok(b != null, "ja page: the practice button exists")
	if b != null:
		print("press: 집중 연습 (ja)")
		b.pressed.emit()
		ok(PracticeView.pending == {"kind": "phoneme", "p": "j_long"}, "pressing it sets PracticeView.pending = {kind phoneme, p j_long} (%s)" % str(PracticeView.pending))
		ok(_nav.size() == 1 and _nav[0][0] == "practice" and _nav[0][1] == "ja", "...and asks main to open the practice tab for ja (%s)" % str(_nav))
	PracticeView.pending = {}
	# 영어 탭: 영어 미션만, 일본어 칩 없음. 영어 약한 소리는 영어 기록이 없으니 빈 상태
	v.set_lang("en")
	await _frames(3)
	ok(_any_text(v, "카페 주문 ★★★") and _any_text(v, "other_new_mission ★★☆"), "en tab: English chips (and an unlisted plain id)")
	ok(not _any_text(v, "편의점") and not _any_text(v, "라멘집") and not _any_text(v, "ja_new_mission") and not _any_text(v, "자기소개"), "en tab: no Japanese mission chips")
	ok(_any_text(v, "표본이 더 쌓이면") and not _any_text(v, "틀림") and _find_button(v, "집중 연습") == null, "en tab with no English sound records: empty state, no Japanese chips, no practice button")
	# 다시 일본어 -> 소리 카드가 되돌아온다
	v.set_lang("ja")
	await _frames(3)
	ok(_any_text(v, long_label + " 틀림 40%") and _any_text(v, "편의점 ★★★"), "switching back to ja shows the Japanese cards again")
	holder.queue_free()
	await _frames(2)
	Store.set_lang("en")


func _test_pure_helpers() -> void:
	print("[v1.7.0 stats helpers: chip text / ids / names]")
	ok(StatsView.weak_chip_text("ja", "j_long", 0.4) == JaSounds.label_of("j_long") + " 틀림 40%", "weak_chip_text(ja) = label + ' 틀림 n%'")
	ok(StatsView.weak_chip_text("en", "θ", 0.4, " · s로 들림") == "/θ/ 40% · s로 들림", "weak_chip_text(en) keeps the English '/θ/ 40%' form")
	ok(StatsView.weak_chip_text("ja", "j_nope", 0.5) == "j_nope 틀림 50%", "an unknown sound id is shown as its id")
	var wild: Array = [-1.0, 5.0, NAN, INF, 1.0e99]
	var wild_ok := true
	for r in wild:
		var t: String = StatsView.weak_chip_text("ja", "j_long", r)
		var m := RegEx.create_from_string("틀림 ([0-9]+)%").search(t)
		wild_ok = wild_ok and m != null and int(m.get_string(1)) >= 0 and int(m.get_string(1)) <= 100
	ok(wild_ok, "a rate outside 0..1 / NaN / INF still shows a percent between 0 and 100")
	ok(StatsView.plays_text(2) == "2번 도전" and StatsView.plays_text(999) == "999번 도전" and StatsView.plays_text(1000) == "999번 넘게 도전" and StatsView.plays_text(1000000) == "999번 넘게 도전" and StatsView.plays_text(-5) == "0번 도전", "plays_text: 2 / 999 as they are, 1000+ -> '999번 넘게 도전' (never 5 digits), negative -> 0")
	# 검사기: 5자리 숫자 검사가 실제로 걸린다
	var rx := RegEx.new()
	rx.compile("[0-9]{5,}")
	var fake := Label.new()
	fake.text = "미션 12345번 도전"
	add_child(fake)
	var found: bool = not _raw_numbers(fake).is_empty()
	print("selfcheck %s the raw-number checker on a fake label with 12345" % ("FAIL-as-expected" if found else "UNEXPECTED-PASS"))
	ok(found and rx.search("99999") != null and rx.search("9999") == null, "the 5+ digit checker flags 12345 / 99999 but not 9999")
	fake.queue_free()
	var en_ids: Array = StatsView.mission_ids_for("en", ["cafe_order", "ja_konbini", "ja_unlisted", "plain_unlisted"])
	var ja_ids: Array = StatsView.mission_ids_for("ja", ["cafe_order", "ja_konbini", "ja_unlisted", "plain_unlisted"])
	ok(en_ids == StatsView.MISSION_ORDER + ["plain_unlisted"], "mission_ids_for(en): the 8 English ids + an unlisted plain id; no ja_ ids %s" % str(en_ids))
	ok(ja_ids == StatsView.MISSION_ORDER_JA + ["ja_unlisted"], "mission_ids_for(ja): the 8 Japanese ids + an unlisted ja_ id; no English ids %s" % str(ja_ids))
	ok(StatsView.mission_ids_for("xx", []) == StatsView.MISSION_ORDER, "an unknown language falls back to the English list")
	ok(StatsView.mission_name("ja", "ja_konbini") == "편의점" and StatsView.mission_name("en", "cafe_order") == "카페 주문" and StatsView.mission_name("ja", "ja_zzz") == "ja_zzz" and StatsView.mission_name("en", "zzz") == "zzz", "mission_name: Japanese / English names, an id without a name is shown as the id")
	ok(StatsView.mission_name("en", "ja_konbini") == "ja_konbini", "an English tab does not translate a Japanese id")


# ---------------------------------------------------------------- report card: the "no record yet" line appears once

func _test_report_once() -> void:
	print("[report card: no duplicate empty text]")
	_load_dataset("rich")
	StudyLog.today_override = D + 60 ## old records exist, but nothing in the last 7 days
	var made: Array = await _make(SIZES[0])
	var holder: Control = made[0]
	var v: StatsView = made[1]
	var rep: Control = null
	var page_lines := 0
	for ch in v._scroll.content.get_children():
		if ch.has_meta("report"):
			rep = ch
		elif ch is Label and "아직 기록이 없어요" in (ch as Label).text:
			page_lines += 1
	ok(rep != null and bool(rep.get_meta("empty")) and _any_text(rep, "아직 기록이 없어요"), "records exist but the week is empty: the report card says so itself")
	ok(page_lines == 0, "... and the page does not repeat it with its own line (got %d)" % page_lines)
	holder.queue_free()
	await _frames(2)
	StudyLog.today_override = D


# ---------------------------------------------------------------- GoalCard

func _test_goal_card() -> void:
	print("[GoalCard]")
	_load_dataset("rich")
	Store.prefs["daily_goal_min"] = 15
	var holder := Control.new()
	holder.size = SIZES[0]
	add_child(holder)
	var cmp: GoalCard = GoalCard.compact("en")
	holder.add_child(cmp)
	await _frames(2)
	var line: String = ""
	for t in _texts(cmp):
		line += str(t) + " "
	ok("오늘" in line and "/ 15분" in line and "연속" in line and "보호권" in line, "compact card: one line with minutes, streak, tokens -> '%s'" % line.strip_edges())
	ok(cmp.get_combined_minimum_size().x <= 392.0, "compact card fits a 412 px phone (min width %.0f)" % cmp.get_combined_minimum_size().x)
	cmp.queue_free()
	var full: GoalCard = GoalCard.full("en")
	holder.add_child(full)
	await _frames(2)
	var goal_btns: Array = []
	for n in _walk(full):
		if n is Button:
			goal_btns.append(n)
	ok(goal_btns.size() == 6, "full card: 6 goal buttons (5/10/15/20/30/off), got %d" % goal_btns.size())
	var all_tall := true
	for b in goal_btns:
		all_tall = all_tall and (b as Button).size.y >= 44.0
	ok(all_tall, "full card: goal buttons are 44 px or taller")
	var changed: Array = [0]
	full.goal_changed.connect(func() -> void: changed[0] += 1)
	var b20: Button = null
	for b in goal_btns:
		if (b as Button).text == "20분":
			b20 = b
	b20.pressed.emit()
	await _frames(2)
	ok(StudyLog.goal_minutes() == 20 and changed[0] == 1, "pressing 20분 stores the goal (20) and emits goal_changed once")
	ok(_any_text(full, "/ 20분"), "the card redraws with the new goal")
	var boff: Button = null
	for n in _walk(full):
		if n is Button and (n as Button).text == "끔":
			boff = n
	boff.pressed.emit()
	await _frames(2)
	ok(StudyLog.goal_minutes() == 0 and _any_text(full, "목표 꺼짐"), "goal off: card says so")
	# today minutes show
	StudyLog.set_goal_minutes(10)
	StudyLog.add_seconds("en", "lesson", 650)
	full.refresh()
	await _frames(2)
	ok(_any_text(full, "달성!"), "reached goal shows 달성!")
	ok(_any_text(full, "보호권 개수보다 많은 날을 놓치면") and _any_text(full, "보호권은 그대로 남아요"), "the token explanation says what happens when more days are missed than tokens")
	# lowering the goal under the time already studied is judged right away (toast + today marked)
	StudyClock._celebrated.clear()
	Store.progress = Progress.blank()
	StudyLog.set_goal_minutes(30)
	full.refresh()
	await _frames(2)
	ok(not Store.did_day(Plan.today_days(), "en"), "goal 30 with 10 min studied: today not marked by the goal")
	for n in _walk(full):
		if n is Button and (n as Button).text == "10분":
			(n as Button).pressed.emit()
	await _frames(2)
	ok(Store.did_day(Plan.today_days(), "en"), "pressing 10분 when 10+ minutes are already studied marks today right away")
	StudyClock._celebrated.clear()
	holder.queue_free()
	await _frames(2)
	Store.prefs.erase("daily_goal_min")


# ---------------------------------------------------------------- MiniChart

func _test_chart_robustness() -> void:
	print("[MiniChart]")
	var holder := Control.new()
	holder.size = Vector2(500, 300)
	add_child(holder)
	var weird: Array = [NAN, INF, -INF, null, -5, "x", 1.0e30, 0, 3.5]
	var cases: Array = []
	cases.append(MiniChart.bars(weird, ["a", "b"], Pal.EN, 99, 5.0))
	cases.append(MiniChart.bars([], [], Pal.EN))
	cases.append(MiniChart.bars([1, 2, 3], [], Pal.EN, -1, NAN))
	cases.append(MiniChart.line(weird, ["x"], Pal.OK, 100.0))
	cases.append(MiniChart.line([], [], Pal.OK, 0.0))
	cases.append(MiniChart.line([50], ["only"], Pal.OK, 100.0))
	cases.append(MiniChart.line([null, null], [], Pal.OK, -10.0))
	for c in cases:
		holder.add_child(c)
	var sizes: Array = [Vector2(0, 0), Vector2(1, 1), Vector2(5, 200), Vector2(300, 150), Vector2(2000, 40)]
	for s in sizes:
		for c in cases:
			(c as MiniChart).size = s
			(c as MiniChart).queue_redraw()
		await _frames(1)
	ok(true, "7 odd charts x 5 sizes drew without crashing")
	ok(not (cases[1] as MiniChart).has_data() and not (cases[6] as MiniChart).has_data() and (cases[5] as MiniChart).has_data() and (cases[2] as MiniChart).has_data(), "has_data(): empty / all-null false, real values true")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- freeing while busy

func _test_lifecycle() -> void:
	print("[lifecycle]")
	_load_dataset("rich")
	var made: Array = await _make(SIZES[0])
	var holder: Control = made[0]
	var v: StatsView = made[1]
	v.refresh()
	holder.queue_free()
	await _frames(4)
	ok(not is_instance_valid(v), "freeing the view right after refresh() raises no error")
	var v2 := StatsView.new()
	v2.refresh()
	v2.on_hide()
	v2.free()
	ok(true, "refresh()/on_hide() before the view is in the tree are harmless")
