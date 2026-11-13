extends Node
## 가나 코스 화면 시험 (서버 없이): KanaScreen 의 코스 목록 · 단계 소개 · 단계 시험(듣기/읽기/입력) · 짝 연습 · 결과 · 뒤로 가기,
## KanaTypeBox(입력칸), 코스 기록(StudyLog.add_kana_course_try), 폰 레이아웃(글자 크기·다크·가상 키보드 높이 300 가정).
##   PC   : godot --headless --path godot res://tests/kana_course_screen_test.tscn
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/kana_course_screen_test.tscn -- --phone
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark] [--shots=<폴더>]   (--shots 는 창이 있는 실행에서만 PNG 가 저장된다: 헤드리스는 그림이 없다)
## 마지막 줄: "== kana_course_screen: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 시험 전용 파일 경로(user://test_fun_k2_*)만 쓰고 끝에 되돌린다. 소리는 Tts.fetch_hook 으로 가로채고 주소는 닫힌 포트(9)다.
## 검사기(check_marks / rect_inside)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다 ("selfcheck FAIL-as-expected ..." 줄).

const TEST_PROGRESS := "user://test_fun_k2_progress.json"
const TEST_LOG := "user://test_fun_k2_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const KEYBOARD_H := 300.0

var passed: int = 0
var failed: int = 0
var phone: bool = false
var tts_calls: Array = []
var toasts: Array = []
var activities: Array = []
var _saved := {}
var _holder: Control = null
var _screen: KanaScreen = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _shots_dir: String = ""
var _closed_n: int = 0
var _api: Node = null ## 자동 로드 Api (접속 금지 규칙 때문에 이름으로 직접 부르지 않고 노드로 잡는다)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 검사기가 "실패로 판정"해야 하는 입력: 실패로 판정하면 통과로 센다.
func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	phone = Platform.is_phone()
	_api = get_node("/root/Api")
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
		elif a.begins_with("--shots="):
			_shots_dir = a.substr(8)
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== kana_course_screen start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_setup()
	_selfcheck()
	await _test_open_and_course()
	await _test_intro()
	await _test_stage_pass()
	await _test_stage_fail_and_retry()
	await _test_type_question()
	await _test_no_sound()
	await _test_pairs()
	await _test_ui_runs()
	await _test_back_navigation()
	await _test_bad_input()
	await _test_quiz_setup_type()
	await _test_layout()
	_teardown()
	print("== kana_course_screen: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true),
		"progress": Store.progress.duplicate(true),
		"progress_path": Store.progress_path,
		"log_path": StudyLog.path,
		"base": _api.base_url,
	}
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "ja"
	_api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게 (소리는 fetch_hook 이 가로챈다)
	Tts.fetch_hook = Callable(self, "_tts_hook")
	Toast.message.connect(func(t: String, k: String) -> void: toasts.append([t, k]))
	Store.activity.connect(func(k: String) -> void: activities.append(k))
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(PHONE_SCREEN if phone else PC_SCREEN)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	Tts.stop()
	PhoneLayout.test_keyboard_height = -1.0
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp"]:
		_rm(p)
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	_api.base_url = _saved["base"]
	Store.prefs = _saved["prefs"]


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _reset_state() -> void:
	StudyLog.reset()
	Store.progress = Progress.blank()
	tts_calls.clear()
	toasts.clear()
	activities.clear()
	_api.base_url = "http://127.0.0.1:9"


func _make_screen() -> KanaScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	_screen = KanaScreen.new()
	_holder.add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_closed_n = 0
	_screen.closed.connect(func() -> void: _closed_n += 1)
	return _screen


func _page(s: KanaScreen) -> PageScroll:
	return s._shell["page"]


func _find(n: Node, node_name: String) -> Node:
	if n.name == node_name:
		return n
	for c in n.get_children():
		var f: Node = _find(c, node_name)
		if f != null:
			return f
	return null


func _has_text(n: Node, needle: String) -> bool:
	for c in n.get_children():
		if (c is Label or c is Button) and str(c.text).contains(needle):
			return true
		if _has_text(c, needle):
			return true
	return false


func _glyph_kinds(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is GlyphIcon:
			out.append((c as GlyphIcon).kind)
		_glyph_kinds(c, out)


func _shot(name: String, plain: bool = false) -> void:
	if _shots_dir == "":
		return
	await _frames(3)
	var img: Image = get_viewport().get_texture().get_image() if get_viewport().get_texture() != null else null
	if img == null or img.is_empty():
		print("  (no image for shot %s: headless?)" % name)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var path := "%s/%s.png" % [_shots_dir, name] if plain else "%s/%s_%s_f%d.png" % [_shots_dir, name, _scheme, roundi(Ds.font_scale * 100.0)]
	print("  shot ", path, " err=", img.save_png(path))


# ---------------------------------------------------------------- validators (also checked against broken input)

## 코스 목록 표시 검사: 모든 단계 id 가 있고, 추천("next")이 정확히 하나, 값은 done/next/none 중 하나.
func check_marks(marks: Dictionary, ids: Array) -> bool:
	if marks.size() != ids.size():
		return false
	var nexts := 0
	for id in ids:
		if not marks.has(id):
			return false
		var m: String = str(marks[id])
		if not ["done", "next", "none"].has(m):
			return false
		if m == "next":
			nexts += 1
	return nexts == 1


## r 이 bounds 안(가로)에 들어 있고 높이가 min_h 이상인가.
func rect_inside(r: Rect2, bounds: Rect2, min_h: float) -> bool:
	return r.position.x >= bounds.position.x - 0.5 and r.end.x <= bounds.end.x + 0.5 and r.size.y >= min_h - 0.5


func _selfcheck() -> void:
	var ids: Array = KanaCourse.stage_ids()
	var good := {}
	for id in ids:
		good[id] = "none"
	good["h1"] = "next"
	ok(check_marks(good, ids), "selfcheck: check_marks accepts a good mark table")
	var two := good.duplicate()
	two["h2"] = "next"
	fails(not check_marks(two, ids), "two recommended stages")
	var none := good.duplicate()
	none["h1"] = "none"
	fails(not check_marks(none, ids), "no recommended stage")
	var missing := good.duplicate()
	missing.erase("k11")
	fails(not check_marks(missing, ids), "a stage row missing")
	var weird := good.duplicate()
	weird["h3"] = "zz"
	fails(not check_marks(weird, ids), "an unknown mark value")
	var bounds := Rect2(0, 0, 412, 915)
	ok(rect_inside(Rect2(12, 100, 388, 64), bounds, 64.0), "selfcheck: rect_inside accepts a row inside the screen")
	fails(not rect_inside(Rect2(12, 100, 420, 64), bounds, 64.0), "row sticks out to the right")
	fails(not rect_inside(Rect2(-5, 100, 100, 64), bounds, 64.0), "row sticks out to the left")
	fails(not rect_inside(Rect2(12, 100, 388, 40), bounds, 64.0), "row shorter than 64")


# ---------------------------------------------------------------- 코스 목록 (K2-3)

func _test_open_and_course() -> void:
	print("[open + course list]")
	_reset_state()
	var s := _make_screen()
	s.open("ja")
	await _frames(3)
	ok(s.stage == "table", "open(ja) with no args: the table (default view)")
	s.open("ja", {"view": "table"})
	ok(s.stage == "table", "args.view = table: the table")
	s.open("ja", {"view": "zz"})
	ok(s.stage == "table", "args.view = zz (unknown): the table, no error")
	s.open("ja", {"view": "course"})
	await _frames(4)
	ok(s.stage == "course", "args.view = course: the course list")
	var ids: Array = KanaCourse.stage_ids()
	ok(s.stage_rows.size() == 24 and ids.size() == 24, "24 stage rows (hira 11 + pairs 1, kata 11 + pairs 1) (got %d)" % s.stage_rows.size())
	var all_rows := true
	for id in ids:
		if not s.stage_rows.has(id):
			all_rows = false
	ok(all_rows, "every KanaCourse stage id has a row")
	ok(check_marks(s.stage_marks, ids) and s.recommended_stage == "h1" and s.stage_marks["h1"] == "next", "fresh start: only h1 is recommended (marks valid)")
	var page_rect: Rect2 = _page(s).get_global_rect()
	var min_h := 1e9
	var inside := true
	for id in ids:
		var b: Button = s.stage_rows[id]
		min_h = minf(min_h, b.size.y)
		if not rect_inside(b.get_global_rect(), page_rect, 64.0):
			inside = false
	ok(min_h >= 64.0, "every stage row is at least 64 high (smallest %.1f)" % min_h)
	ok(inside, "every stage row sits inside the page width and is >= 64 high")
	var kinds: Array = []
	_glyph_kinds(s.stage_rows["h1"], kinds)
	ok(kinds.has("play"), "the recommended row draws a play glyph (shape, not colour alone)")
	ok(_has_text(_page(s), "0 / 12 단계 완료"), "the course header counts finished stages (0 / 12)")
	await _shot("course_fresh")
	# 기록이 있으면: h1, h2 완료, h3 추천
	StudyLog.add_kana_course_try("h1", 14, 15, true)
	StudyLog.add_kana_course_try("h2", 12, 15, true)
	StudyLog.add_kana_course_try("h3", 9, 15, false)
	s.open_course()
	await _frames(3)
	ok(check_marks(s.stage_marks, ids), "after records: mark table valid")
	ok(s.stage_marks["h1"] == "done" and s.stage_marks["h2"] == "done", "h1 and h2 are done")
	ok(s.stage_marks["h3"] == "next" and s.recommended_stage == "h3", "h3 is the recommended stage (a failed try does not finish it)")
	var nexts := 0
	for id in ids:
		if s.stage_marks[id] == "next":
			nexts += 1
	ok(nexts == 1, "exactly one recommended row")
	var k1: Array = []
	_glyph_kinds(s.stage_rows["h1"], k1)
	var k3: Array = []
	_glyph_kinds(s.stage_rows["h3"], k3)
	var k4: Array = []
	_glyph_kinds(s.stage_rows["h4"], k4)
	ok(k1.has("check") and k3.has("play") and k4.is_empty(), "done row = check glyph, recommended = play glyph, others none")
	ok(_has_text(_page(s), "2 / 12 단계 완료"), "header: 2 / 12 stages done")
	ok(_has_text(s.stage_rows["h1"], "93%"), "h1 row shows its best score (93%)")
	# 전부 끝내면 추천 없음 (모든 단계 완료) -> check_marks 는 '추천 정확히 1개' 라서 별도로 본다
	for id in ids:
		StudyLog.add_kana_course_try(str(id), 15, 15, true)
	s.open_course()
	await _frames(2)
	ok(s.recommended_stage == "" and not s.stage_marks.values().has("next"), "all 24 done: no recommended row")
	# [표 | 코스] 전환
	_reset_state()
	s.open("ja")
	await _frames(2)
	ok(s.get("stage") == "table" and _find(_holder, "ViewSwitch") != null, "table has the [표 | 코스] switch")
	s._on_view_switch("course")
	await _frames(2)
	ok(s.stage == "course" and _find(_holder, "ViewSwitch") != null, "switch -> course (the switch is on the course list too)")
	s._on_view_switch("table")
	await _frames(2)
	ok(s.stage == "table" and s.cells.size() == 104, "switch -> table (104 cells)")


# ---------------------------------------------------------------- 단계 소개

func _test_intro() -> void:
	print("[stage intro]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	ok(s.open_stage("h1") and s.stage == "stage_intro" and s.course_id == "h1", "open_stage(h1) -> intro")
	await _frames(3)
	ok(s.cells.size() == 5 and s.cells.has("あ") and s.cells.has("お"), "intro shows the 5 glyph cells of あ행")
	ok(s.start_button != null and s.start_button.text.contains("15문제"), "intro has the start button '단계 시험 시작 (15문제)'")
	ok(s.start_button.size.y >= 56.0 - 0.5, "start button is >= 56 high (%.1f)" % s.start_button.size.y)
	ok(_find(_holder, "ToTable") != null, "intro has the '표로' button")
	s.tap_intro_cell("あ")
	await _frames(2)
	ok(s.sound_requests == 1 and tts_calls.size() == 1 and tts_calls[0]["text"] == "あ", "tapping a cell asks the voice once (sound %d)" % s.sound_requests)
	ok(s.last_ch == "あ", "the tapped glyph is remembered for the footer")
	await _shot("intro")
	ok(s.open_stage("k11") and s.cells.size() == 33, "katakana yoon intro shows 33 cells")
	await _frames(2)
	ok(s.open_stage("p_h") and s.stage == "pairs", "a pair stage opens the pair picker, not the plain intro")
	ok(not s.open_stage("zz") and s.stage == "pairs", "open_stage(zz) is false and the screen stays")


# ---------------------------------------------------------------- 단계 시험: 통과 (K2-4, K2-11)

## 문제를 차례로 푼다: 앞의 n_right 개는 정답, 나머지는 오답. 입력 문제는 로마자(ro)로 쓰거나 엉뚱한 글을 쓴다.
func _play(s: KanaScreen, n_right: int) -> void:
	for i in s.questions.size():
		var q: Dictionary = s.current()
		var want_ok: bool = i < n_right
		if str(q["kind"]) == "type":
			s.answer_text(str(q["ro"]) if want_ok else "zzz")
		else:
			var a: int = int(q["answer"])
			s.answer(a if want_ok else (a + 1) % 4)
		s.next_question()


func _kana_total() -> int:
	var n := 0
	var st: Dictionary = StudyLog.kana_stats()
	for k in st.keys():
		n += int((st[k] as Array)[0]) + int((st[k] as Array)[1])
	return n


func _test_stage_pass() -> void:
	print("[stage test: pass]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	ok(s.start_stage("h1", 7) and s.stage == "stage_test", "start_stage(h1) -> stage_test")
	await _frames(3)
	var kinds := {"listen": 0, "read": 0, "type": 0}
	var letters_ok := true
	for q in s.questions:
		kinds[str(q["kind"])] += 1
		if not ["あ", "い", "う", "え", "お"].has(str(q["ch"])):
			letters_ok = false
	ok(s.questions.size() == 15 and kinds["listen"] == 5 and kinds["read"] == 5 and kinds["type"] == 5, "15 questions: listen 5 + read 5 + type 5 (%s)" % str(kinds))
	ok(letters_ok, "every question letter belongs to あ행")
	ok(_has_text(_holder, "1 / 15"), "the header counts '1 / 15'")
	# 한 판을 끝까지: 12개 맞힘
	_play(s, 12)
	await _frames(3)
	ok(s.stage == "stage_result" and s.finished, "after the 15th answer: the stage result")
	ok(s.correct_count() == 12 and s.last_passed, "12 right = passed")
	ok(_has_text(_page(s), "통과했어요"), "result says 통과했어요")
	ok(StudyLog.kana_course_done().has("h1"), "kana_course.done has h1")
	var tries: Dictionary = StudyLog.snapshot()["kana_course"]["tries"]
	ok(int(tries.get("h1", 0)) == 1, "tries.h1 == 1 (got %s)" % str(tries.get("h1", 0)))
	ok(int(StudyLog.kana_course_best().get("h1", 0)) == 80, "best.h1 == 80")
	ok(_kana_total() == 15, "add_kana went up 15 times in total (got %d)" % _kana_total())
	ok(StudyLog.kana_summary()["runs"] == 1 and StudyLog.kana_summary()["total"] == 15, "one run of 15 logged (add_kana_run)")
	ok(s.sound_requests == 5 and s.silent_requests == 0, "sound requests == number of listen questions (5) (sound %d, silent %d)" % [s.sound_requests, s.silent_requests])
	ok(activities == ["kana"], "Store.activity said 'kana' exactly once (%s)" % str(activities))
	ok(toasts.size() == 1 and str(toasts[0][0]).contains("단계 통과"), "one toast on passing (%s)" % str(toasts))
	ok(_find(_holder, "NextStage") != null and _find(_holder, "RetryStage") != null and _find(_holder, "ToCourse") != null, "result has [다음 단계] [같은 단계 다시] [코스로]")
	ok(s.next_stage_id() == "h2", "next stage after h1 is h2")
	var wrong_n: int = s.wrong_entries().size()
	ok(wrong_n >= 1 and wrong_n <= 3, "1..3 distinct wrong letters (%d)" % wrong_n)
	var cards0: int = Store.review_for("ja").size()
	var rb: Button = _find(_holder, "AddReview") as Button
	ok(rb != null, "result has the [틀린 글자 복습 카드로 추가] button")
	if rb != null:
		rb.pressed.emit()
	await _frames(2)
	ok(Store.review_for("ja").size() == cards0 + wrong_n and s.added_cards == wrong_n, "the wrong letters became review cards (+%d)" % wrong_n)
	var rb2: Button = _find(_holder, "AddReview") as Button
	ok(rb2 != null and rb2.disabled, "after adding, the button is disabled (no double add)")
	var done_before: Dictionary = StudyLog.kana_course_done()
	s.finish()
	ok(StudyLog.snapshot()["kana_course"]["tries"]["h1"] == 1 and activities.size() == 1, "finish() called again does not count the run twice")
	ok(StudyLog.kana_course_done() == done_before, "done is unchanged")
	# 다음 단계 버튼 -> h2 소개
	(_find(_holder, "NextStage") as Button).pressed.emit()
	await _frames(2)
	ok(s.stage == "stage_intro" and s.course_id == "h2", "[다음 단계] opens the h2 intro")
	await _shot("stage_passed")


# ---------------------------------------------------------------- 단계 시험: 미통과 · 다시 (K2-5)

func _test_stage_fail_and_retry() -> void:
	print("[stage test: fail + retry]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	s.start_stage("h2", 11)
	await _frames(2)
	_play(s, 11)
	await _frames(3)
	ok(s.stage == "stage_result" and s.correct_count() == 11 and not s.last_passed, "11 right = not passed")
	ok(not StudyLog.kana_course_done().has("h2"), "done.h2 is NOT recorded")
	ok(int(StudyLog.kana_course_best().get("h2", 0)) == 73, "best.h2 == 73")
	ok(int(StudyLog.snapshot()["kana_course"]["tries"]["h2"]) == 1, "tries.h2 == 1 (a failed run still counts as a try)")
	ok(_has_text(_page(s), "통과하지 못했어요"), "result says 통과하지 못했어요")
	ok(_find(_holder, "NextStage") == null, "no [다음 단계] button after a failed stage")
	ok(toasts.is_empty(), "no toast when the stage is not passed")
	var first_q: Array = s.questions.duplicate(true)
	(_find(_holder, "RetryStage") as Button).pressed.emit()
	await _frames(3)
	ok(s.stage == "stage_test" and s.idx == 0 and s.questions.size() == 15 and s.answered_count() == 0, "[같은 단계 다시] starts a fresh 15-question run")
	var same := true
	for i in 15:
		if str((s.questions[i] as Dictionary)["ch"]) != str((first_q[i] as Dictionary)["ch"]) or str((s.questions[i] as Dictionary)["kind"]) != str((first_q[i] as Dictionary)["kind"]):
			same = false
	ok(not same, "the new 15 questions are not the same as the first run")
	_play(s, 15)
	await _frames(2)
	ok(s.last_passed and StudyLog.kana_course_done().has("h2") and int(StudyLog.snapshot()["kana_course"]["tries"]["h2"]) == 2, "second run 15/15 passes: done.h2 set, tries == 2")
	ok(int(StudyLog.kana_course_best().get("h2", 0)) == 100, "best.h2 rises to 100")
	ok(s.wrong_entries().is_empty() and _find(_holder, "AddReview") == null, "no wrong letters: no review button")
	ok(_has_text(_page(s), "틀린 글자가 없어요"), "result says there are no wrong letters")


# ---------------------------------------------------------------- 입력 문제 (K2-6)

func _test_type_question() -> void:
	print("[type question]")
	_reset_state()
	var s := _make_screen()
	s.open("ja")
	ok(s.start_quiz({"kind": "type", "script": "hira", "only": ["し"], "rows": [], "focus": false}, 3), "start_quiz with kind type (only し)")
	await _frames(3)
	var q: Dictionary = s.current()
	ok(str(q["kind"]) == "type" and q["ch"] == "し" and (q["options"] as Array).is_empty(), "the question is a type question for し, no options")
	ok(s.type_box != null and s.option_buttons.is_empty(), "the screen shows the type box and no option buttons")
	ok(s.type_box.edit.custom_minimum_size.y >= 56.0 and s.type_box.confirm.custom_minimum_size.y >= 56.0, "edit and confirm minimum height >= 56")
	ok(s.type_box.confirm.disabled, "confirm is disabled while the input is empty")
	ok(not s.type_box.submit() and not s.is_answered(), "submitting an empty box does nothing")
	s.type_box.set_text("   ")
	ok(not s.type_box.submit() and s.type_box.confirm.disabled, "spaces only: nothing happens, confirm stays disabled")
	s.type_box.set_text("shi")
	ok(not s.type_box.confirm.disabled, "confirm is enabled once there is text")
	s.type_box.confirm.pressed.emit()
	await _frames(2)
	ok(s.is_answered() and bool(s.answers[0]["ok"]), "pressing confirm with 'shi' answers し right")
	ok(StudyLog.kana_stat("し") == {"ok": 1, "bad": 0}, "StudyLog: し ok 1")
	ok(not s.answer_text("shi") and StudyLog.kana_stat("し") == {"ok": 1, "bad": 0}, "a second submission on the same question counts nothing")
	ok(not s.type_box.submit(), "the locked box does not submit again")
	var acl: Label = _find(_holder, "AcceptedAnswers") as Label
	ok(acl != null and acl.text.contains("shi") and acl.text.contains("si") and acl.text.contains("시"), "the answer line lists every accepted answer (shi / si / 시): %s" % (acl.text if acl != null else "none"))
	await _shot("type_answered")
	# 두 번째 문제: "ka" 는 틀림, 틀린 것도 센다
	s.next_question()
	await _frames(2)
	ok(not s.answer_text("ka") and StudyLog.kana_stat("し") == {"ok": 1, "bad": 1}, "'ka' for し is wrong and counted as a miss")
	ok(_has_text(_holder, "정답:"), "a wrong answer shows '정답:' with the accepted answers")
	s.next_question()
	await _frames(2)
	ok(not s.answer_text("") and StudyLog.kana_stat("し") == {"ok": 1, "bad": 2}, "answer_text('') is wrong (counted as a miss)")
	s.next_question()
	await _frames(2)
	ok(s.answer_text("  SI ") and s.answer_text("x") == false, "'  SI ' (spaces, upper case, kunrei) is right; the second call is ignored")
	s.next_question()
	await _frames(2)
	ok(s.answer_text("시"), "hangul 시 is right")
	ok(not s.answer(0), "answer(i) on a type question does nothing")
	var rd_ok: bool = true
	for q2 in s.questions:
		if str(q2["ch"]) != "し":
			rd_ok = false
	ok(rd_ok, "every type question was for し")
	await _shot("type_question_done")


# ---------------------------------------------------------------- 소리 없는 기기 (K2-6, K2-11)

func _test_no_sound() -> void:
	print("[no sound device]")
	_reset_state()
	_api.base_url = "" ## fetch_hook 이 있어서 engine 은 pc: 주소가 없으면 소리를 낼 수 없다
	ok(not KanaVoice.available(), "setup: no sound available")
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	s.open_stage("h3")
	await _frames(3)
	ok(_find(_holder, "NoSoundNote") != null, "intro shows the no-sound note")
	ok(s.start_stage("h3", 5), "start_stage works without sound")
	await _frames(3)
	var kinds := {"listen": 0, "read": 0, "type": 0}
	for q in s.questions:
		kinds[str(q["kind"])] += 1
	ok(kinds["listen"] == 0 and kinds["read"] == 10 and kinds["type"] == 5, "without sound: read 10 + type 5, no listen (%s)" % str(kinds))
	ok(_find(_holder, "NoSoundNote") != null, "the first question shows the one-line note")
	_play(s, 15)
	await _frames(2)
	ok(s.sound_requests == 0 and s.silent_requests == 0 and tts_calls.is_empty(), "no sound requests at all (sound %d, silent %d)" % [s.sound_requests, s.silent_requests])
	ok(s.last_passed, "the stage is still finishable and passes without sound")
	_api.base_url = "http://127.0.0.1:9"


# ---------------------------------------------------------------- 짝 연습 (K2-7)

func _test_pairs() -> void:
	print("[pairs]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	ok(s.open_stage("p_h") and s.stage == "pairs", "open the hira pair stage")
	await _frames(3)
	var pairs: Array = KanaCourse.pairs("hira")
	ok(s.pair_chips.size() == pairs.size() and pairs.size() == 10, "10 pair chips for hiragana (got %d)" % s.pair_chips.size())
	ok(s.pair_all_chip != null and s.selected_pairs.is_empty(), "'전체 섞기' chip is the default (nothing picked)")
	var nu_me: String = ""
	var sa_chi: String = ""
	for p in pairs:
		if p["a"] == "ぬ" and p["b"] == "め":
			nu_me = str(p["id"])
		if p["a"] == "さ" and p["b"] == "ち":
			sa_chi = str(p["id"])
	ok(nu_me != "" and sa_chi != "", "found the ぬ/め and さ/ち pairs")
	s.toggle_pair(nu_me)
	await _frames(2)
	ok(s.selected_pairs == [nu_me], "tapping a chip picks that pair")
	s.toggle_pair(nu_me)
	ok(s.selected_pairs.is_empty(), "tapping it again drops it")
	s.toggle_pair(nu_me)
	s.toggle_pair("zz")
	ok(s.selected_pairs == [nu_me], "an unknown pair id is ignored")
	ok(s.start_pairs(s.selected_pairs, 4) and s.stage == "stage_test" and s.run_kind == "pairs", "start_pairs -> a pair run")
	await _frames(3)
	ok(s.questions.size() == 10, "10 questions")
	var all_pair := true
	var has_partner := true
	for q in s.questions:
		if str(q["pair"]) != nu_me:
			all_pair = false
		var chs: Array = []
		for o in q["options"]:
			chs.append(o["ch"])
		if not chs.has(q["ch"]) or not chs.has(q["partner"]):
			has_partner = false
	ok(all_pair, "every question is from the picked pair")
	ok(has_partner, "every question lists the answer and its partner among the options")
	ok(_find(_holder, "PairTip") != null and (_find(_holder, "PairTip") as Label).text.contains("구별 요령"), "a pair with a tip shows the tip line")
	await _shot("pair_question")
	var before_total: int = _kana_total()
	_play(s, 8)
	await _frames(3)
	ok(s.stage == "stage_result" and s.run_kind == "pairs" and s.correct_count() == 8, "the pair run ends in a result (8 / 10)")
	ok(_has_text(_page(s), "짝 연습 결과") and _find(_holder, "Verdict") == null, "result is titled 짝 연습 결과 and has no pass/fail verdict")
	ok(_kana_total() == before_total + 10, "the 10 answers were counted per letter")
	ok(StudyLog.snapshot().get("kana_course", {}).get("tries", {}).is_empty(), "a pair run is not a course try (tries stay empty)")
	ok(StudyLog.kana_summary()["runs"] == 1, "one run logged")
	ok(_find(_holder, "RetryPairs") != null and _find(_holder, "ToPairs") != null and _find(_holder, "NextStage") == null, "result has [같은 짝으로 다시] and [짝 고르기]")
	(_find(_holder, "RetryPairs") as Button).pressed.emit()
	await _frames(2)
	ok(s.stage == "stage_test" and s.idx == 0 and s.selected_pairs == [nu_me], "[같은 짝으로 다시] keeps the picked pair")
	# 요령이 없는 짝(さ/ち)은 줄이 없다
	ok(s.start_pairs([sa_chi], 5), "start a pair run for さ/ち (no tip)")
	await _frames(3)
	ok(KanaCourse.pair_by_id(sa_chi)["tip"] == "" and _find(_holder, "PairTip") == null, "a pair without a tip shows no tip line")
	# 전체 섞기
	s.go_back()
	await _frames(2)
	ok(s.stage == "pairs", "back from a pair run: the pair picker")
	s.clear_pairs()
	ok(s.selected_pairs.is_empty() and s.start_pairs([], 6) and s.questions.size() == 10, "전체 섞기: 10 questions from all pairs")
	var pids := {}
	for q in s.questions:
		pids[str(q["pair"])] = true
	ok(pids.size() >= 2, "mixed run uses several pairs (%d)" % pids.size())
	# 단계 시험(짝 단계)도 된다
	s.go_back()
	await _frames(2)
	ok(s.stage == "pairs" and s.stage_button != null, "the pair stage has a stage-test button")
	s.stage_button.pressed.emit()
	await _frames(2)
	ok(s.stage == "stage_test" and s.run_kind == "stage" and s.course_id == "p_h" and s.questions.size() == 15, "the stage-test button starts the 15-question p_h test")
	_play(s, 13)
	await _frames(2)
	ok(s.last_passed and StudyLog.kana_course_done().has("p_h"), "p_h passes with 13/15 and is recorded")
	# 가타카나 짝
	ok(s.open_stage("p_k") and s.pair_chips.size() == 11, "katakana pair stage has 11 pair chips")


# ---------------------------------------------------------------- 화면 버튼으로 끝까지 (코드로 answer/next 를 부르지 않는다)

func _footer_buttons(s: KanaScreen) -> Array:
	return _buttons(s._shell["footer_col"])


## 화면 버튼만 눌러 한 판을 끝까지 푼다. 앞의 n_right 개는 정답, 나머지는 오답(입력은 틀린 글, 일부는 [모르겠어요]).
## 문제마다: 답한 뒤 피드백 상자가 보이고, 아래 줄에 다음(결과 보기) 버튼이 있고, 입력칸은 잠기며, 다음 버튼으로 진행한다.
## 돌려주는 값: 실제로 끝까지 간 문제 수.
func _play_ui(s: KanaScreen, n_right: int, label: String) -> int:
	var n: int = s.questions.size()
	var done_n := 0
	var all_feedback := true
	var all_next := true
	var all_locked := true
	var all_progress := true
	var skip_used := 0
	for i in n:
		if s.stage != "stage_test":
			break
		var q: Dictionary = s.current()
		var want_ok: bool = i < n_right
		if str(q["kind"]) == "type":
			var tb: KanaTypeBox = s.type_box
			if want_ok:
				tb.set_text(str(q["ro"]))
				tb.confirm.pressed.emit()
			elif skip_used < 1:
				skip_used += 1
				tb.skip.pressed.emit() ## [모르겠어요]
			else:
				tb.set_text("zzz")
				tb.confirm.pressed.emit()
		else:
			var a: int = int(q["answer"])
			(s.option_buttons[a if want_ok else (a + 1) % 4] as Button).pressed.emit()
		if not s.is_answered():
			all_progress = false
			break
		if s._feedback_box == null or s._feedback_box.get_child_count() == 0:
			all_feedback = false
		var holder: Control = s._shell["footer_holder"]
		var btns: Array = _footer_buttons(s)
		if not holder.visible or btns.is_empty():
			all_next = false
		if str(q["kind"]) == "type" and (s.type_box.edit.editable or not s.type_box.locked):
			all_locked = false
		if btns.is_empty():
			break
		await get_tree().create_timer(0.3).timeout ## 다음 버튼은 연타 방지로 0.25초 잠긴다
		(btns.back() as Button).pressed.emit()
		await _frames(2)
		done_n += 1
	ok(done_n == n, "%s: all %d questions were completed with button presses only (%d)" % [label, n, done_n])
	ok(all_feedback, "%s: after every answer the feedback box had content" % label)
	ok(all_next, "%s: after every answer the footer shows a next / result button" % label)
	ok(all_locked, "%s: every typed answer locked the input box" % label)
	ok(all_progress, "%s: every answer was accepted (the run never got stuck)" % label)
	return done_n


func _test_ui_runs() -> void:
	print("[full runs with button presses only]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	ok(s.start_stage("h1", 7), "start h1 stage test")
	await _frames(3)
	# 첫 문제에 화면 버튼으로 답한 직후의 화면 (피드백 상자 + 다음 버튼)
	var q0: Dictionary = s.current()
	if str(q0["kind"]) == "type":
		s.type_box.set_text(str(q0["ro"]))
		s.type_box.confirm.pressed.emit()
	else:
		(s.option_buttons[int(q0["answer"])] as Button).pressed.emit()
	await _frames(3)
	ok(s.is_answered() and s._feedback_box.get_child_count() > 0 and not _footer_buttons(s).is_empty(), "stage test: right after the first answer the feedback box and the next button are there")
	await _shot("stage_after_answer", true)
	s.start_stage("h1", 7)
	await _frames(3)
	var before_kana: int = _kana_total()
	await _play_ui(s, 12, "stage h1")
	await _frames(2)
	ok(s.stage == "stage_result" and s.correct_count() == 12 and s.last_passed, "stage h1 by buttons: result screen, 12 right, passed")
	ok(_kana_total() == before_kana + 15, "stage h1 by buttons: 15 letter answers counted")
	ok(StudyLog.kana_course_done().has("h1"), "stage h1 by buttons: done.h1 recorded")
	await _shot("stage_after_answer_result")
	# 짝 연습
	s.open("ja", {"view": "course"})
	s.open_stage("p_h")
	ok(s.start_pairs([], 4), "start a pair run")
	await _frames(3)
	await _play_ui_pairs(s)
	# 입력 문제 [모르겠어요]
	s.open("ja")
	ok(s.start_quiz({"kind": "type", "script": "hira", "only": ["し"], "rows": [], "focus": false}, 3), "start a type quiz for skip test")
	await _frames(3)
	ok(s.type_box != null and s.type_box.skip != null and s.type_box.skip.visible and not s.type_box.skip.disabled, "the type question has an enabled [모르겠어요] button")
	ok(s.type_box.skip.size.y >= 48.0 - 0.5, "[모르겠어요] is >= 48 high (%.1f)" % s.type_box.skip.size.y)
	s.type_box.skip.pressed.emit()
	await _frames(2)
	ok(s.is_answered() and not bool(s.answers[0]["ok"]), "[모르겠어요] answers the question as wrong")
	ok(StudyLog.kana_stat("し") == {"ok": 0, "bad": 1}, "[모르겠어요] counted a miss for し")
	var acl: Label = _find(_holder, "AcceptedAnswers") as Label
	ok(acl != null and acl.text.contains("shi") and acl.text.contains("시"), "[모르겠어요] reveals the accepted answers")
	ok(s.type_box.locked and not s.type_box.edit.editable and not s.type_box.skip.visible, "after [모르겠어요] the box is locked and the button hidden")
	ok(not s.type_box.give_up() and StudyLog.kana_stat("し") == {"ok": 0, "bad": 1}, "pressing it again counts nothing")
	ok(not _footer_buttons(s).is_empty(), "after [모르겠어요] the next button is available")
	await _shot("type_skipped")


func _play_ui_pairs(s: KanaScreen) -> void:
	ok(s.stage == "stage_test" and s.run_kind == "pairs" and s.questions.size() == 10, "pair run is on the screen with 10 questions")
	await _play_ui(s, 7, "pairs")
	await _frames(2)
	ok(s.stage == "stage_result" and s.run_kind == "pairs" and s.correct_count() == 7, "pairs by buttons: result screen, 7 right")


# ---------------------------------------------------------------- 뒤로 가기 (K2-9)

func _test_back_navigation() -> void:
	print("[back navigation]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {"view": "course"})
	s.start_stage("h4", 2)
	await _frames(2)
	s.answer(int(s.current()["answer"]) if str(s.current()["kind"]) != "type" else 0)
	ok(s.go_back() and s.stage == "course", "back from a stage test -> the course list")
	ok(not StudyLog.snapshot().has("kana_course") or StudyLog.snapshot()["kana_course"]["tries"].is_empty(), "leaving mid-run records no try")
	ok(activities.is_empty() and StudyLog.kana_summary()["runs"] == 0, "no run logged and no activity for a left run")
	ok(s.go_back() and s.stage == "table" and _closed_n == 0, "back from the course list -> the table (not the hub)")
	ok(s.go_back() and _closed_n == 1, "back from the table -> closed")
	# 소개에서
	s.open("ja", {"view": "course"})
	s.open_stage("h5")
	ok(s.go_back() and s.stage == "course", "back from an intro -> the course list")
	s.open_stage("p_k")
	ok(s.go_back() and s.stage == "course", "back from the pair picker -> the course list")
	# 결과에서
	s.start_stage("h5", 3)
	_play(s, 15)
	ok(s.stage == "stage_result" and s.go_back() and s.stage == "course", "back from a stage result -> the course list")
	# 설정 퀴즈(기존 계약)
	s.open("ja")
	s.open_setup()
	ok(s.go_back() and s.stage == "table", "back from the quiz setup -> the table (unchanged)")


# ---------------------------------------------------------------- 잘못된 입력 (K2-12, K2-10)

func _test_bad_input() -> void:
	print("[bad input]")
	_reset_state()
	var sent0: int = int(_api.sent_count)
	var s := _make_screen()
	s.open("en")
	await _frames(2)
	ok(s.stage == "unsupported", "open(en): the 'Japanese only' screen")
	ok(not s.start_stage("h1") and not s.open_stage("h1") and s.stage == "unsupported", "English: start_stage / open_stage are refused, the screen stays")
	s.open("en", {"view": "course"})
	ok(s.stage == "unsupported", "open(en, view=course) is still unsupported")
	s.open("ja", {"view": "course"})
	await _frames(2)
	ok(not s.start_stage("zz") and not s.start_stage("") and not s.start_stage("h12") and s.stage == "course", "start_stage with an unknown id is false, the course list stays")
	ok(not s.open_stage("zz") and s.stage == "course", "open_stage(zz) is false, the screen stays")
	ok(not s.start_pairs(["zz"]) and s.stage == "course", "start_pairs outside a pair stage is false")
	s.open_stage("p_h")
	ok(not s.start_pairs(["zz", "yy"]) and s.stage == "pairs", "start_pairs with only unknown pair ids is false, the picker stays")
	s.toggle_pair("zz")
	ok(s.selected_pairs.is_empty(), "toggle_pair(zz) picks nothing")
	# 글자가 모자란 가짜 단계
	var raw: Array = KanaCourse._stages
	var saved_chars: Array = (raw[2] as Dictionary)["chars"].duplicate()
	var sid: String = str((raw[2] as Dictionary)["id"])
	(raw[2] as Dictionary)["chars"] = []
	s.open("ja", {"view": "course"})
	ok(not s.start_stage(sid) and s.stage == "course", "a stage with no letters: start_stage is false, no error")
	(raw[2] as Dictionary)["chars"] = [saved_chars[0]]
	ok(s.start_stage(sid, 1) and s.questions.size() == 15, "a stage with one letter still makes 15 questions (it cycles)")
	(raw[2] as Dictionary)["chars"] = saved_chars
	ok(s.answer_text("zz") == false and s.answer(9) == false, "answer / answer_text outside a valid state or range is false")
	s.open("ja", {"view": "course"})
	ok(not s.answer_text("shi") and not s.answer(0), "answer_text / answer on the course list does nothing")
	s.next_question()
	s.finish()
	ok(s.stage == "course", "next_question / finish on the course list do nothing")
	ok(int(_api.sent_count) == sent0, "no request left through the Api autoload (sent_count unchanged)")


# ---------------------------------------------------------------- 퀴즈 설정의 "입력" 종류

func _test_quiz_setup_type() -> void:
	print("[quiz setup: kind type]")
	_reset_state()
	var s := _make_screen()
	s.open("ja")
	s.open_setup()
	await _frames(2)
	s.set_cfg("kind", "type")
	await _frames(2)
	ok(str(s.cfg["kind"]) == "type" and _has_text(_page(s), "입력"), "setup has the '입력' kind and it can be chosen")
	ok(s.start_quiz({}, 3) and s.stage == "quiz" and s.questions.size() == 10, "the setup starts a 10-question type quiz")
	var all_type := true
	for q in s.questions:
		if str(q["kind"]) != "type":
			all_type = false
	ok(all_type, "all 10 are type questions")
	await _frames(3)
	for q in s.questions:
		s.answer_text(str(q["ro"]))
		s.next_question()
	await _frames(2)
	ok(s.stage == "result" and s.correct_count() == 10, "typed all 10 right -> the quiz result")
	ok(activities == ["kana"], "the plain quiz also says Store.activity('kana') once")
	s.set_cfg("kind", "read")
	ok(str(s.cfg["kind"]) == "read", "kind read is still selectable")
	ok(s.start_quiz({"kind": "read"}, 4) and s.option_buttons.size() == 4, "a read quiz still has 4 option buttons")


# ---------------------------------------------------------------- 레이아웃 (K2-8)

func _test_layout() -> void:
	print("[layout: %s, scale %s, %s]" % ["phone 412x915" if phone else "pc 1280x800", Ds.font_scale, _scheme])
	_reset_state()
	var s := _make_screen()
	var screen: Vector2 = PHONE_SCREEN if phone else PC_SCREEN
	var bounds := Rect2(Vector2.ZERO, screen)
	s.open("ja", {"view": "course"})
	await _frames(4)
	var page: PageScroll = _page(s)
	var hbar := page.get_h_scroll_bar()
	ok(not hbar.visible or hbar.max_value - hbar.page < 1.0, "course list: no horizontal scrolling")
	var all_in := true
	var min_h := 1e9
	for id in s.stage_rows.keys():
		var b: Button = s.stage_rows[id]
		min_h = minf(min_h, b.size.y)
		if not rect_inside(b.get_global_rect(), bounds, 64.0):
			all_in = false
	ok(all_in and min_h >= 64.0, "course list: all 24 rows are inside the screen width and >= 64 high (smallest %.1f)" % min_h)
	# 라벨이 줄 밖으로 나가지 않는다(말줄임): 행 안 모든 Label 의 오른쪽 끝이 행 안
	var label_out := false
	for id in s.stage_rows.keys():
		var b2: Button = s.stage_rows[id]
		var rr: Rect2 = b2.get_global_rect()
		for l in _labels(b2):
			if (l as Label).get_global_rect().end.x > rr.end.x + 1.0:
				label_out = true
	ok(not label_out, "course list: no label sticks out of its row")
	s.start_stage("h1", 8)
	# 입력 문제가 나올 때까지 (정답으로) 진행
	var guard := 0
	while str(s.current().get("kind", "")) != "type" and guard < 15:
		s.answer(int(s.current()["answer"]))
		s.next_question()
		guard += 1
	await _frames(4)
	ok(str(s.current().get("kind", "")) == "type" and s.type_box != null, "reached a type question")
	var tb: KanaTypeBox = s.type_box
	ok(tb.edit.size.y >= 56.0 - 0.5, "input box height >= 56 (%.1f)" % tb.edit.size.y)
	ok(tb.confirm.size.y >= 56.0 - 0.5, "confirm button height >= 56 (%.1f)" % tb.confirm.size.y)
	var page_rect: Rect2 = page.get_global_rect()
	ok(rect_inside(tb.edit.get_global_rect(), bounds, 56.0) and rect_inside(tb.confirm.get_global_rect(), bounds, 56.0), "the input box and confirm button are inside the screen width")
	ok(not page.get_h_scroll_bar().visible or page.get_h_scroll_bar().max_value - page.get_h_scroll_bar().page < 1.0, "type question: no horizontal scrolling")
	await _shot("stage_type_question")
	# 가상 키보드 높이 300 가정: 화면(= 본문 영역)을 300 줄이고 입력칸이 보이게 스크롤한다(main.gd 의 _keep_focus_visible 과 같은 방식)
	_holder.size = Vector2(screen.x, screen.y - KEYBOARD_H)
	await _frames(3)
	PhoneLayout.ensure_visible(tb.edit)
	await _frames(3)
	var vis: Rect2 = page.get_global_rect()
	var eb: Rect2 = tb.edit.get_global_rect()
	var cb: Rect2 = tb.confirm.get_global_rect()
	var limit: float = screen.y - KEYBOARD_H + 1.0
	ok(vis.end.y <= limit, "with a 300 px keyboard the page area ends above it (%.0f <= %.0f)" % [vis.end.y, limit])
	ok(eb.position.y >= vis.position.y - 1.0 and eb.end.y <= vis.end.y + 1.0, "with a 300 px keyboard the input box is in the visible page area")
	ok(cb.end.y <= vis.end.y + 1.0 and cb.position.y >= vis.position.y - 1.0, "with a 300 px keyboard the confirm button is also in the visible area (%.0f..%.0f of %.0f..%.0f)" % [cb.position.y, cb.end.y, vis.position.y, vis.end.y])
	_holder.size = screen
	await _frames(2)
	# 선택지 문제(읽기)와 짝 연습
	s.go_back()
	s.open_stage("p_k")
	await _frames(3)
	ok(s.start_button != null and rect_inside(s.start_button.get_global_rect(), bounds, 56.0), "pair picker: the start button is inside the screen and >= 56 high")
	var chips_in := true
	for pid in s.pair_chips.keys():
		if not rect_inside((s.pair_chips[pid] as Control).get_global_rect(), bounds, 0.0):
			chips_in = false
	ok(chips_in, "pair picker: every chip is inside the screen width")
	s.start_pairs([], 3)
	await _frames(3)
	var opts_in := true
	for b3 in s.option_buttons:
		if not rect_inside((b3 as Control).get_global_rect(), bounds, 0.0):
			opts_in = false
	ok(opts_in and s.option_buttons.size() == 4, "pair question: 4 option buttons inside the screen")
	await _shot("pair_question_layout")
	_play(s, 5)
	await _frames(2)
	ok(s.stage == "stage_result", "layout run ended in a result")
	var res_in := true
	for b4 in _buttons(_holder):
		if (b4 as Control).is_visible_in_tree() and (b4 as Control).get_global_rect().end.x > screen.x + 0.5:
			res_in = false
	ok(res_in, "result page: no button sticks out to the right")
	await _shot("stage_result")


func _labels(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Label:
			out.append(c)
		out.append_array(_labels(c))
	return out


func _buttons(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_buttons(c))
	return out
