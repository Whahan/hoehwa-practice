extends Node
## v2.0 E5 (docs/v200_design.md §14.2 E5-1..E5-10): 코스 홈(72주 길)과 레슨 탭 연결. 서버 없이.
##   PC   : godot --headless --path godot res://tests/course_home_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/course_home_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark]
## 마지막 줄: "== course_home: N passed, M failed (presses: P) ==" (실패가 있으면 종료 코드 1)
## 흐름은 실제 버튼의 pressed.emit() 으로 간다(출력의 "press: ..." 줄): [새 코스로 시작] -> 확인 시트 [시작] -> 72주 길 -> 현재 노드 ->
## 주 상세 시트 -> [이 주 시작] -> 플레이어가 열림 -> [나가기] -> [그만하기] -> 길로 돌아옴 -> [예전 길] -> 48칸 길 -> [새 코스].
## 데이터는 실제 출시 데이터(res://data/course, 1~16주)다. 검사기(상태표·5자리 숫자·겹침·소스 검사)는 일부러 틀린 입력도 넣어
## 실제로 실패하는지 본다("selfcheck FAIL-as-expected ..." 줄). 시험 전용 파일(user://test_e5_*)만 쓰고 끝에 되돌린다. 주소는 닫힌 포트(9)다.

const PROG := "user://test_e5_progress.json"
const PREFS := "user://test_e5_prefs.json"
const LOG := "user://test_e5_studylog.json"
const CS := "user://test_e5_course.json"
const GONE_DIR := "res://tests/fixtures/__not_here__"
const SRC_NEW := ["res://scripts/views/course_home.gd"]
const SRC_ALL := ["res://scripts/views/course_home.gd", "res://scripts/views/lesson_view.gd", "res://scripts/views/roadmap_view.gd",
	"res://scripts/ui/path_board.gd", "res://tests/course_home_test.gd"]
const PHONE_SCREEN := Vector2(412, 820)
const PC_SCREEN := Vector2(1100, 760)
const NOW_ISO := "2026-11-14" ## 토요일
const OLD_LESSON_SYMBOLS := 9 ## check / cross marks already in lesson_view.gd at the base commit (1ec62fe)

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var _scheme: String = "light"
var _font_scale: float = 1.0
var _screen: Vector2 = PC_SCREEN
var lv: LessonView = null
var rv: RoadmapView = null
var _saved: Dictionary = {}
var _before: Array = []
var _reached: Array = []
var _spec_log: Array = []
var _done_cb: Array = []
var _avail: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


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
	_screen = PHONE_SCREEN if phone else PC_SCREEN
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== course_home start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	ok(is_equal_approx(Ds.font_scale, Ds.sanitize_scale(_font_scale)) and Pal.is_dark() == (_scheme == "dark"), "the run uses the asked text scale and colour scheme")
	_before = _user_listing()
	_setup()
	_selfcheck()
	await _sec_gate()
	await _sec_main_flow()
	await _sec_states()
	await _sec_lock_soon()
	await _sec_skip()
	await _sec_unit_spec()
	await _sec_wrong_input()
	await _sec_layout()
	await _sec_pathboard()
	await _sec_roadmap()
	await _sec_numbers()
	_sec_source()
	_teardown()
	for s in ["selfcheck", "gate", "main_flow", "states", "lock_soon", "skip", "unit_spec", "wrong_input", "layout", "pathboard", "roadmap", "numbers", "source"]:
		ok(_reached.has(s), "section '%s' ran to its end" % s)
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_home: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _setup() -> void:
	_saved = {"prefs": Store.prefs.duplicate(true), "progress": Store.progress.duplicate(true), "progress_path": Store.progress_path,
		"prefs_path": Store.prefs_path, "log_path": StudyLog.path, "cs": CourseStore.path, "base": CourseData.base_dir,
		"api": Api.base_url, "route": Route.mode, "anim": Sheet.animate, "phone_hook": Route.phone_hook}
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	Route.phone_hook = Callable(self, "_yes")
	Route.mode = "phone"
	Sheet.animate = false
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(_screen)


func _teardown() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
	if rv != null and is_instance_valid(rv):
		rv.queue_free()
	Tts.fetch_hook = Callable()
	SpeakDrill.api_hook = Callable()
	Tts.stop()
	_close_sheets()
	StudyLog.reset()
	_rm_all()
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	CourseFeed.reset()
	CourseStore.reset_memory()
	CourseStore.today_override = -1
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.prefs_path = _saved["prefs_path"]
	CourseStore.path = _saved["cs"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Api.base_url = _saved["api"]
	Route.mode = _saved["route"]
	Route.phone_hook = _saved["phone_hook"]
	Sheet.animate = _saved["anim"]


func _rm_all() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


## 새 세계: 기록 없음, 코스를 고르지 않음, 실제 코스 데이터, 영어.
func _world() -> void:
	_close_sheets()
	_rm_all()
	Store.progress = Progress.blank()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	StudyLog.reset()
	CourseStore.reset_memory()
	CourseStore.today_override = Plan.iso_to_days(NOW_ISO)
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	CourseFeed.reset()
	_avail = CourseData.available_weeks()


func _yes() -> bool:
	return true


func _tts_hook(_text: String, _l: String, _speed: float, _voice: String) -> Variant:
	return null


func _api_hook(_method: String, _path: String, _body: Variant) -> Variant:
	return {}


func _close_sheets() -> void:
	var guard: int = 0
	while Sheet.is_open() and guard < 12:
		Sheet.close_top()
		guard += 1


# ---------------------------------------------------------------- 도우미

func _new_view() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
		await _frames(2)
	lv = LessonView.new()
	add_child(lv)
	lv.size = _screen
	await _frames(4)


func _find_sheet() -> Sheet:
	return _find_sheet_in(get_tree().root)


func _find_sheet_in(n: Node) -> Sheet:
	if n is Sheet and not (n as Sheet).is_closed():
		return n as Sheet
	for c in n.get_children():
		var r: Sheet = _find_sheet_in(c)
		if r != null:
			return r
	return null


func _named(root: Node, nm: String) -> Node:
	return root.find_child(nm, true, false) if root != null else null


func _seg_button(root: Node, text: String) -> Button:
	var sel: Node = _named(root, "CourseModeSelector")
	if sel == null:
		return null
	return _button_with_text(sel, text)


func _button_with_text(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r: Button = _button_with_text(c, text)
		if r != null:
			return r
	return null


func _ready_btn(b: Variant) -> bool:
	return b is Button and is_instance_valid(b) and (b as Button).is_visible_in_tree() and not (b as Button).disabled


## 실제 버튼을 누른다: 보이고 눌릴 수 있는지 먼저 확인하고, pressed 를 낸다.
func press(b: Variant, label: String) -> void:
	var good: bool = _ready_btn(b)
	ok(good, "button ready: %s" % label)
	if not good:
		return
	presses += 1
	print("press: ", label)
	(b as Button).pressed.emit()


func _texts(n: Node, out: Array) -> void:
	if n is Label or n is Button or n is RichTextLabel:
		out.append(str(n.text))
	for c in n.get_children():
		_texts(c, out)


func _has_text(root: Node, needle: String) -> bool:
	var all: Array = []
	_texts(root, all)
	for t in all:
		if str(t).contains(needle):
			return true
	return false


## 화면 글 중 연속 5자리 이상 숫자가 있는 것의 개수(REVIEW.md: 초·밀리초·바이트·unix 시각을 그대로 보이면 안 된다).
func _five_digits(root: Node) -> int:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	var all: Array = []
	_texts(root, all)
	var cnt: int = 0
	for t in all:
		if rx.search(str(t)) != null:
			cnt += 1
	return cnt


func _course_states() -> Array:
	var out: Array = []
	for w in range(1, 73):
		out.append(lv._course.state_of(w) if lv != null and lv._course != null else "<none>")
	return out


## 독립 계산: 열림 칸 수 2 를 시험 안에 박아 둔다(CourseModel 의 상수에 기대지 않는다).
func _expected(done: Array, cur_w: int, avail: int) -> Array:
	var out: Array = []
	for i in 72:
		var s: String
		if i >= avail:
			s = "locked"
		elif done.has(i + 1):
			s = "done"
		elif i + 1 == cur_w:
			s = "current"
		elif i + 1 < cur_w:
			s = "past"
		elif i + 1 <= cur_w + 2:
			s = "open"
		else:
			s = "locked"
		out.append(s)
	return out


## "" 이면 같다. 아니면 처음 다른 칸을 적는다.
func _diff(actual: Array, expected: Array) -> String:
	if actual.size() != expected.size():
		return "size %d != %d" % [actual.size(), expected.size()]
	for i in actual.size():
		if str(actual[i]) != str(expected[i]):
			return "week %d: %s != %s" % [i + 1, actual[i], expected[i]]
	return ""


func _overlaps(rects: Array) -> int:
	var cnt: int = 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				cnt += 1
	return cnt


## Number of argument dictionaries that open_target accepts (returns true).
func _accepted(arg_list: Array) -> int:
	var n: int = 0
	for a in arg_list:
		if a is Dictionary and lv.open_target(a):
			n += 1
			print("  open_target accepted: ", str(a))
	return n


## Text of the Label named `n` inside the player ("" when there is none).
func _label_text(p: Node, n: String) -> String:
	var l: Node = p.find_child(n, true, false)
	return String(l.text) if l is Label else ""


func _btn(p: Node, n: String) -> Button:
	var b: Node = p.find_child(n, true, false)
	return b as Button if b is Button else null


func _in_band(frac: float) -> bool:
	return frac >= 0.2 and frac <= 0.55


func _unit(w: int, d: int) -> Dictionary:
	return {"unit": "new", "w": w, "d": d, "ok": 1, "total": 1, "first_try": 1, "wrong": [], "words_new": [], "completed": true, "seconds": 60, "block": "new"}


## 칸을 하나씩 끝내 pos 를 (w, d) 까지 옮긴다(CourseStore 의 규칙 그대로: pos 만 앞으로 간다).
func _advance_to(w: int, d: int) -> void:
	var guard: int = 0
	while guard < 600:
		var p: Dictionary = CourseStore.pos()
		if int(p["w"]) * 10 + int(p["d"]) >= w * 10 + d:
			return
		CourseStore.unit_done(_unit(int(p["w"]), int(p["d"])))
		guard += 1


func _start_course_mode() -> void:
	CourseStore.set_mode("course")
	CourseData.reset()
	CourseFeed.reset()


# ---------------------------------------------------------------- 검사기 자체 시험

func _selfcheck() -> void:
	print("[selfcheck: the checkers fail on wrong input]")
	var good: Array = _expected([1], 2, 16)
	eq(_diff(good, _expected([1], 2, 16)), "", "the table diff accepts equal tables")
	var wrong: Array = good.duplicate()
	wrong[10] = "open"
	fails(_diff(wrong, good) != "", "a table with one wrong week is rejected")
	fails(_diff([], good) != "", "a short table is rejected")
	var fake := Control.new()
	var lab := Label.new()
	lab.text = "12345"
	fake.add_child(lab)
	fails(_five_digits(fake) == 1, "a screen with the text 12345 is counted by the 5-digit scan")
	var ok_fake := Control.new()
	var lab2 := Label.new()
	lab2.text = "1234 / 99"
	ok_fake.add_child(lab2)
	eq(_five_digits(ok_fake), 0, "four digits are fine for the 5-digit scan")
	fake.free()
	ok_fake.free()
	fails(_overlaps([Rect2(0, 0, 10, 10), Rect2(5, 5, 10, 10)]) == 1, "overlapping rectangles are counted")
	eq(_overlaps([Rect2(0, 0, 10, 10), Rect2(20, 0, 10, 10)]), 0, "separate rectangles are not counted")
	fails(_scan_source_text("var x = \"%d" + "/%d\" % [a, b]", true).size() > 0, "a source with a self-made %d/%d progress text is flagged")
	fails(_scan_source_text("var c = Color(\"" + "#ff0000\")", false).size() > 0, "a source with a hex Color is flagged")
	fails(_scan_source_text("var s = \"" + char(0x2605) + " star\"", false).size() > 0, "a source with a star glyph is flagged")
	fails(_scan_source_text("var h = HTTPRe" + "quest.new()", true).size() > 0, "a new source with an HTTP request node is flagged")
	fails(_scan_source_text("var u = \"http://127.0.0.1:877" + "0\"", false).size() > 0, "a source with a forbidden port is flagged")
	eq(_scan_source_text("var s = \"ok text\"", true).size(), 0, "a clean source is not flagged")
	_reached.append("selfcheck")


## 소스 글에서 금지 패턴을 찾는다. 반환: 찾은 것의 이름 목록. strict: 새 파일용 검사(네트워크 호출·자체 진행 글)까지 켤지.
func _scan_source_text(txt: String, strict: bool, symbols: bool = true) -> Array:
	var hits: Array = []
	if txt.contains("Color(\"" + "#"):
		hits.append("hex colour")
	for needle in ["877" + "0", "877" + "5", "877" + "6"]:
		if txt.contains(needle):
			hits.append(needle)
	if strict: # new files only (lesson_view.gd already opened the Tatoeba link and shows its own legacy counters)
		for needle in ["HTTPRe" + "quest", "shell" + "_open", "request" + "_permission", "%d" + "/%d"]:
			if txt.contains(needle):
				hits.append(needle)
	if symbols and _symbol_count(txt) > 0:
		hits.append("symbol glyph")
	return hits


## Emoji and shape glyphs (the old lesson view has 9 check / cross marks of its own at the base commit; nothing new may be added).
func _symbol_count(txt: String) -> int:
	var n: int = 0
	for i in txt.length():
		var cp: int = txt.unicode_at(i)
		if (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x1F300 and cp <= 0x1FAFF) or cp == 0x2B50 or cp == 0x2713:
			n += 1
	return n


# ---------------------------------------------------------------- 1. 코스를 고르기 전·일본어

func _sec_gate() -> void:
	print("[gate: nothing chosen yet, Japanese, odd values]")
	_world()
	ok(_avail >= 4 and _avail < 72, "the real course data has some weeks but not 72 (%d)" % _avail)
	await _new_view()
	ok(lv._course == null, "nothing chosen: no course road")
	ok(_named(lv, "CourseStartCard") != null, "nothing chosen: the [새 코스로 시작] card is shown")
	ok(_named(lv, "CourseStartButton") != null and _ready_btn(_named(lv, "CourseStartButton")), "the start button is visible and enabled")
	ok(_named(lv, "CourseModeSelector") == null, "nothing chosen: no [새 코스 | 예전 길] switch")
	ok(_named(lv, "CourseNotice") == null, "the course data is fine: no notice line")
	eq(lv.path_boards().size(), 12, "the old path has 12 month boards")
	eq(CourseStore.mode(), "legacy", "nothing chosen = legacy mode")
	ok(not CourseHome.mode_chosen(), "mode_chosen() is false")
	# Japanese: not one line changes
	Store.set_lang("ja")
	lv.refresh()
	await _frames(3)
	ok(_named(lv, "CourseStartCard") == null and _named(lv, "CourseModeSelector") == null and _named(lv, "CourseNotice") == null, "Japanese: no start card, no switch, no notice")
	eq(lv.path_boards().size(), 12, "Japanese: 12 month boards")
	Store.set_lang("en")
	# Japanese stays untouched even in course mode and with a missing course
	Store.prefs["course_mode"] = "course"
	Store.set_lang("ja")
	lv.refresh()
	await _frames(3)
	ok(lv._course == null and _named(lv, "CourseModeSelector") == null, "Japanese + course mode: still the old path without a switch")
	eq(lv.path_boards().size(), 12, "Japanese + course mode: 12 month boards")
	Store.set_lang("en")
	# odd values of course_mode: always the old path, the card stays (nothing was chosen)
	var odd: Array = ["x", 5, null, true, [], {}, 1.5, "", "COURSE", " course"]
	var bad_n: int = 0
	var shown_n: int = 0
	for v in odd:
		Store.prefs["course_mode"] = v
		lv.refresh()
		await _frames(2)
		if CourseStore.mode() != "legacy" or CourseHome.mode_chosen() or lv._course != null or lv.path_boards().size() != 12:
			bad_n += 1
		if _named(lv, "CourseStartCard") != null and _named(lv, "CourseModeSelector") == null:
			shown_n += 1
	eq(bad_n, 0, "course_mode odd values (x, 5, null, true, [], {}, 1.5, '', 'COURSE', ' course'): old path, mode legacy, not chosen")
	eq(shown_n, odd.size(), "odd values: the start card is shown, no switch")
	Store.prefs["course_mode"] = "legacy"
	lv.refresh()
	await _frames(3)
	ok(CourseHome.mode_chosen() and _named(lv, "CourseModeSelector") != null and _named(lv, "CourseStartCard") == null, "an explicit 'legacy': the switch replaces the start card")
	_reached.append("gate")


# ---------------------------------------------------------------- 2. 실제 버튼 흐름 (E5-2)

func _sec_main_flow() -> void:
	print("[main flow with real buttons]")
	_world()
	Store.prefs["lang"] = "en"
	await _new_view()
	_done_cb = []
	var legacy_cur: Dictionary = PathModel.current_cell("en")
	# 1. [새 코스로 시작] -> 확인 시트
	press(_named(lv, "CourseStartButton"), "새 코스로 시작")
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null, "the start button opens a confirm sheet")
	ok(sh != null and sh.buttons.has("start") and sh.buttons.has("later"), "the sheet has [시작] and [나중에]")
	ok(sh != null and _has_text(sh, "점검으로 건너뛰기") and _has_text(sh, "예전 길") and _has_text(sh, "72주"), "the sheet explains the 72 weeks, skip by check and the old path")
	ok(sh != null and _named(sh, "CourseGoalRow") != null and _has_text(sh, "45분"), "the sheet offers the 45-minute daily goal")
	eq(CourseStore.mode(), "legacy", "before [시작] the mode is still legacy")
	# 2. [나중에]: 아무것도 바꾸지 않는다
	var goal0: int = StudyLog.goal_minutes()
	if sh != null:
		press(sh.buttons["later"], "시트 나중에")
	await _frames(3)
	ok(not Sheet.is_open() and CourseStore.mode() == "legacy" and not CourseHome.mode_chosen(), "[나중에]: sheet closed, mode unchanged, nothing chosen")
	eq(StudyLog.goal_minutes(), goal0, "[나중에]: the daily goal is unchanged")
	ok(_named(lv, "CourseStartCard") != null and lv._course == null, "[나중에]: the card is still there")
	# 3. 다시 누르고 [시작]
	press(_named(lv, "CourseStartButton"), "새 코스로 시작 (2)")
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null, "the sheet opens again")
	if sh != null:
		press(sh.buttons["start"], "시트 시작")
	await _frames(5)
	eq(CourseStore.mode(), "course", "[시작]: course mode")
	eq(str(Store.prefs.get("course_mode", "")), "course", "[시작]: prefs.course_mode is 'course'")
	eq(StudyLog.goal_minutes(), 45, "[시작]: the daily goal became 45 minutes")
	ok(CourseStore.started() != "", "[시작]: the course file has a start date")
	ok(lv._course != null and _named(lv, "CourseCard") != null, "the 72-week road is shown")
	ok(_named(lv, "CourseStartCard") == null, "the start card is gone")
	eq(lv.path_boards().size(), 18, "the road has 18 boards (blocks)")
	var sel_new: Button = _seg_button(lv, "새 코스")
	var sel_old: Button = _seg_button(lv, "예전 길")
	ok(sel_new != null and sel_old != null and sel_new.has_theme_font_override("font") and not sel_old.has_theme_font_override("font"), "the switch shows [새 코스] selected")
	# 4. 길 상태 (처음)
	var diff: String = _diff(_course_states(), _expected([], 1, _avail))
	ok(diff == "", "first look: week 1 current, 2-3 open, the rest locked (%s)" % diff)
	eq(lv._course.cur_w, 1, "the current week is 1")
	ok(lv.current_node_button() == lv._course.node_of(1), "LessonView.current_node_button() is the node of week 1")
	# 5. 현재 노드 -> 주 상세 시트
	press(lv._course.current_node(), "현재 노드(1주)")
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and sh.title_label != null and sh.title_label.text.begins_with("1주"), "the node opens the week sheet with a title '1주 ...'")
	ok(sh != null and sh.buttons.has("start") and sh.buttons.has("skip") and sh.buttons.has("close"), "week sheet: [이 주 시작] [점검으로 건너뛰기] [닫기]")
	ok(sh != null and sh.buttons.has("start") and (sh.buttons["start"] as Button).text == "이 주 시작", "the start button says '이 주 시작'")
	ok(sh != null and _named(sh, "AheadNote") == null, "the sheet of the current week has no preview note")
	ok(sh != null and _has_text(sh, "할 수 있게 되는 말") and _has_text(sh, "이번 주 공부량") and _has_text(sh, "요일 칸"), "week sheet: can-do, amount and day slots")
	ok(sh != null and _has_text(sh, "단어") and _has_text(sh, "문형"), "week sheet: word and pattern counts in words")
	var day_n: int = 0
	if sh != null:
		for d in range(1, 8):
			if _named(sh, "Day%d" % d) != null:
				day_n += 1
	eq(day_n, 7, "week sheet: 7 day chips")
	ok(sh != null and _named(sh, "Day1") != null and _has_text(_named(sh, "Day1"), "1일 새 내용 지금"), "day 1 is marked as the next one")
	ok(sh != null and _named(sh, "Day5") != null and _has_text(_named(sh, "Day5"), "말하기") and _has_text(_named(sh, "Day6"), "점검") and _has_text(_named(sh, "Day7"), "자유"), "days 5, 6, 7 are speaking, check and free")
	# 6. [이 주 시작] -> 플레이어
	if sh != null:
		press(sh.buttons["start"], "이 주 시작")
	await _frames(4)
	var pl: CoursePlayer = lv.course_player()
	ok(pl != null and is_instance_valid(pl), "[이 주 시작] opens the CoursePlayer")
	eq(lv.status, "course", "the lesson view is in the 'course' state")
	ok(pl != null and pl.is_inside_tree() and pl.get_parent() == lv, "the player is a child of the lesson view")
	ok(pl != null and pl.kind == "new" and pl.w == 1 and pl.d == 1 and pl.block == "new", "the unit is new, week 1 day 1, block new")
	ok(pl != null and pl.state == "run", "the player runs (a unit was built from the real data)")
	ok(pl != null and pl.title_label != null and pl.title_label.text.begins_with("1주 1일"), "the player title starts with '1주 1일'")
	ok(not lv._root.visible, "the page behind the player is hidden")
	ok(lv.open_target({"lang": "en"}) == false, "open_target while a unit is open: false (the progress would be lost)")
	ok(lv.go_back() == true and pl != null and pl.leave_sheet() != null, "the back key while solving asks first (the player's leave sheet)")
	if pl != null and pl.leave_sheet() != null:
		press(pl.leave_sheet().buttons["continue"], "플레이어 계속하기")
	await _frames(2)
	ok(pl != null and pl.leave_sheet() == null and pl.state == "run", "[계속하기]: still solving")
	# 7. [나가기] -> [그만하기] -> 길로 돌아옴
	if pl != null:
		press(pl.back_btn, "플레이어 나가기")
	await _frames(2)
	ok(pl != null and pl.leave_sheet() != null, "[나가기] opens the leave sheet")
	if pl != null and pl.leave_sheet() != null:
		press(pl.leave_sheet().buttons["quit"], "플레이어 그만하기")
	await _frames(5)
	ok(lv.course_player() == null and lv.status == "idle", "[그만하기]: the player is gone, the lesson view is idle")
	ok(lv._root.visible and lv._course != null and _named(lv, "CourseCard") != null, "the road is shown again")
	var p: Dictionary = CourseStore.pos()
	ok(int(p["w"]) == 1 and int(p["d"]) == 1, "leaving records nothing: pos is still week 1 day 1")
	eq(CourseStore.week_state(1).get("days", [1]), [], "leaving records nothing: no day is done")
	eq(Store.stat("en", "lessons"), 0, "leaving records nothing: no lesson counted")
	ok(_diff(_course_states(), _expected([], 1, _avail)) == "", "the road is the same after leaving")
	# 8. [예전 길] -> 기존 48칸 길
	press(_seg_button(lv, "예전 길"), "예전 길")
	await _frames(5)
	eq(CourseStore.mode(), "legacy", "[예전 길]: legacy mode")
	eq(str(Store.prefs.get("course_mode", "")), "legacy", "[예전 길]: prefs.course_mode is 'legacy'")
	eq(lv.path_boards().size(), 12, "[예전 길]: the old 48-cell path (12 boards)")
	var cells: int = 0
	for b in lv.path_boards():
		for w in range(1, 5):
			if (b as PathBoard).node_button(w) != null:
				cells += 1
	eq(cells, 48, "[예전 길]: 48 node buttons")
	ok(_named(lv, "CourseModeSelector") != null and _named(lv, "CourseStartCard") == null and lv._course == null, "[예전 길]: the switch stays, no start card, no course road")
	var cc: Dictionary = PathModel.current_cell("en")
	ok(int(cc["n"]) == int(legacy_cur["n"]) and int(cc["w"]) == int(legacy_cur["w"]), "[예전 길]: the old path position is the same as before the course")
	ok(_has_text(lv, "레슨 시작") and _has_text(lv, "지금 위치"), "[예전 길]: the old '지금 위치' card and [레슨 시작] are there")
	ok(StudyLog.path_last("en").is_empty(), "the old path records were not touched")
	# 9. [새 코스] 다시
	press(_seg_button(lv, "새 코스"), "새 코스")
	await _frames(5)
	eq(CourseStore.mode(), "course", "[새 코스]: course mode again")
	ok(not Sheet.is_open(), "[새 코스]: no confirm sheet (the course was started before)")
	eq(lv.path_boards().size(), 18, "[새 코스]: the 18-board road is back")
	ok(_diff(_course_states(), _expected([], 1, _avail)) == "", "[새 코스]: the same states")
	# 10. 카드의 [이어서 하기]
	press(lv._course.card_start_button, "이어서 하기")
	await _frames(4)
	pl = lv.course_player()
	ok(pl != null and pl.kind == "new" and pl.w == 1 and pl.d == 1, "[이어서 하기] opens week 1 day 1 directly")
	if pl != null:
		press(pl.back_btn, "플레이어 나가기 (2)")
	await _frames(2)
	if pl != null and pl.leave_sheet() != null:
		press(pl.leave_sheet().buttons["quit"], "플레이어 그만하기 (2)")
	await _frames(5)
	ok(lv.course_player() == null and lv.status == "idle", "back at the road again")
	ok(presses >= 12, "at least 12 real button presses so far (%d)" % presses)
	# E6 계약: ask_start(host, on_done) 로 시작 (홈의 카드가 쓴다)
	_world()
	await _new_view()
	_done_cb = []
	CourseHome.ask_start(lv, Callable(self, "_on_started"))
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and sh == CourseHome.last_start_sheet, "ask_start(host, on_done) opens the sheet")
	if sh != null:
		press(sh.buttons["start"], "ask_start 시작")
	await _frames(4)
	eq(_done_cb, [true], "ask_start: on_done(true) after [시작]")
	eq(CourseStore.mode(), "course", "ask_start: course mode")
	lv.refresh()
	await _frames(3)
	ok(lv._course != null and lv.path_boards().size() == 18, "the lesson tab shows the road after the home started the course (refresh)")
	CourseHome.ask_start(lv, Callable(self, "_on_started"))
	await _frames(2)
	sh = _find_sheet()
	if sh != null:
		press(sh.buttons["later"], "ask_start 나중에")
	await _frames(3)
	eq(_done_cb, [true, false], "ask_start: on_done(false) after [나중에]")
	CourseHome.ask_start(lv)
	await _frames(2)
	ok(_find_sheet() != null, "ask_start(host) with no callback also works")
	_close_sheets()
	_reached.append("main_flow")


func _on_started(v: bool) -> void:
	_done_cb.append(v)


# ---------------------------------------------------------------- 3. 상태 표시 (E5-3)

func _sec_states() -> void:
	print("[states: done / current / open / locked / soon, pending check]")
	_world()
	_start_course_mode()
	await _new_view()
	var diff: String = _diff(_course_states(), _expected([], 1, _avail))
	ok(diff == "", "new learner: 1 current, 2 open, 3 open, 4.. locked, after the data soon-locked (%s)" % diff)
	var cnt: Dictionary = {"done": 0, "current": 0, "open": 0, "locked": 0, "past": 0}
	for s in _course_states():
		cnt[s] = int(cnt[s]) + 1
	eq(int(cnt["open"]), 2, "exactly 2 open weeks after the current one")
	eq(int(cnt["current"]), 1, "exactly 1 current week")
	eq(int(cnt["locked"]), 72 - 3, "every other week is locked")
	# 완료: 1주, 2주 (D1~D7 칸 14개) -> 3주 지금
	CourseStore.today_override = Plan.iso_to_days(NOW_ISO)
	_advance_to(3, 1)
	eq(CourseStore.pos(), {"w": 3, "d": 1}, "after 14 cells pos is week 3 day 1")
	lv.refresh()
	await _frames(4)
	diff = _diff(_course_states(), _expected([1, 2], 3, _avail))
	ok(diff == "", "weeks 1-2 done, 3 current, 4-5 open, the rest locked (%s)" % diff)
	var n1: PathNode = lv._course.node_of(1) as PathNode
	var sb: StyleBoxFlat = n1.get_theme_stylebox("normal") as StyleBoxFlat
	ok(n1.state == "done" and sb != null and sb.bg_color == Pal.PRIMARY and n1.get_child_count() == 1, "done: PRIMARY fill + one mark (check)")
	var n3: PathNode = lv._course.node_of(3) as PathNode
	sb = n3.get_theme_stylebox("normal") as StyleBoxFlat
	ok(n3.state == "current" and sb != null and sb.border_color == Pal.REWARD and sb.get_border_width(SIDE_LEFT) == 4, "current: PRIMARY fill + 4 px REWARD ring")
	var n4: PathNode = lv._course.node_of(4) as PathNode
	ok(n4.state == "open" and n4.text == "4", "open: shows the absolute week number (4)")
	var n9: PathNode = lv._course.node_of(9) as PathNode
	ok(n9.state == "locked" and n9.text == "" and n9.get_child_count() == 1, "locked: a lock mark, no number")
	ok(n1.accessibility_name.begins_with("0단계 입문 1주,") and n1.accessibility_name.ends_with("완료"), "accessibility name of week 1: '%s'" % n1.accessibility_name)
	var n5n: PathNode = lv._course.node_of(5) as PathNode
	ok(n5n.accessibility_name.begins_with("1개월차 5주,"), "accessibility name of week 5: '%s'" % n5n.accessibility_name)
	var b1: PathBoard = lv.path_boards()[0] as PathBoard
	ok(b1.label_of(1).text.begins_with("1주 · "), "the name tag of week 1 is '1주 · <title>' (%s)" % b1.label_of(1).text)
	# 헤더
	var h1: Node = _named(lv, "MonthHeader1")
	var h2: Node = _named(lv, "MonthHeader2")
	ok(h1 != null and _has_text(h1, "0단계 입문") and not _has_text(h1, "0개월차"), "block 1 header says '0단계 입문'")
	ok(h1 != null and _has_text(h1, "완료 2/4주"), "block 1 header: '완료 2/4주' (from progress_label)")
	ok(h2 != null and _has_text(h2, "1개월차") and _has_text(h2, "완료 0/4주"), "block 2 header: '1개월차' and '완료 0/4주'")
	ok(lv._course.card_start_button != null and _has_text(_named(lv, "CourseCard"), "3주 1일"), "the card says '3주 1일'")
	ok(_has_text(_named(lv, "CourseCard"), "완료 2/%d주" % _avail), "the card: finished weeks from progress_label ('완료 2/%d주')" % _avail)
	ok(_has_text(_named(lv, "CourseCard"), "11월 14일 (토)에 시작"), "the card: the start date in a readable form ('11월 14일 (토)')")
	# 콘텐츠가 없는 주: 항상 locked + 준비 중
	var soon_ok: int = 0
	var soon_tag: int = 0
	for w in range(_avail + 1, 73):
		var nd: PathNode = lv._course.node_of(w) as PathNode
		if nd != null and nd.state == "locked":
			soon_ok += 1
		var bd: PathBoard = lv.path_boards()[CourseModel.block_of(w) - 1] as PathBoard
		if bd.label_of(CourseModel.k_of(w)).text.contains("준비 중"):
			soon_tag += 1
	eq(soon_ok, 72 - _avail, "every week after the data (%d..72) is locked" % (_avail + 1))
	eq(soon_tag, 72 - _avail, "every week after the data says '준비 중' on its tag")
	ok(_has_text(_named(lv, "CourseCard"), "%d주부터는 준비 중이에요" % (_avail + 1)), "the card tells where the content ends")
	# 점검 미완료 표시: 1·2주는 점검 없이 지나갔다
	var pend: Dictionary = CourseStore.check_pending()
	ok(bool(pend["pending"]) and int(pend["w"]) == 1, "CourseStore: the check of week 1 is pending")
	ok(b1.label_of(1).text.contains("점검 남음"), "the name tag of week 1 says '점검 남음' (%s)" % b1.label_of(1).text)
	ok(not b1.label_of(3).text.contains("점검 남음"), "week 3 has no pending-check mark")
	lv._course.node_of(1).pressed.emit()
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null and _named(sh, "WeekChips") != null and _has_text(_named(sh, "WeekChips"), "점검 남음") and _has_text(_named(sh, "WeekChips"), "완료"), "a done week with a pending check: sheet chips '완료' and '점검 남음'")
	ok(sh != null and sh.buttons.has("start") and (sh.buttons["start"] as Button).text == "이 주 다시 하기" and not sh.buttons.has("skip"), "a done week: [이 주 다시 하기], no skip button")
	ok(sh != null and _has_text(sh, "11월 14일 (토)에 마쳤어요"), "a done week shows when it was finished, as '11월 14일 (토)'")
	ok(sh != null and _has_text(_named(sh, "Day1"), "완료") and _has_text(_named(sh, "Day7"), "완료"), "the day chips of a done week say '완료'")
	_close_sheets()
	await _frames(2)
	# 점검을 통과하면 표시가 2주로 옮겨 가고, 둘 다 하면 사라진다
	CourseStore.check_done(1, {"ok": 12, "total": 12})
	lv.refresh()
	await _frames(4)
	b1 = lv.path_boards()[0] as PathBoard
	ok(not b1.label_of(1).text.contains("점검 남음") and b1.label_of(2).text.contains("점검 남음"), "after week 1's check: the mark moves to week 2")
	CourseStore.check_done(2, {"ok": 12, "total": 12})
	lv.refresh()
	await _frames(4)
	b1 = lv.path_boards()[0] as PathBoard
	ok(not b1.label_of(1).text.contains("점검 남음") and not b1.label_of(2).text.contains("점검 남음"), "after both checks: no pending mark")
	lv._course.node_of(1).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and not _has_text(_named(sh, "WeekChips"), "점검 남음") and _has_text(sh, "점검 최고 100%"), "the sheet shows the check best ('점검 최고 100%') and no pending chip")
	_close_sheets()
	# 약함 표시: 두 번 떨어짐
	CourseStore.check_done(3, {"ok": 2, "total": 12})
	CourseStore.check_done(3, {"ok": 3, "total": 12})
	lv.refresh()
	await _frames(4)
	lv._course.node_of(3).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and _has_text(_named(sh, "WeekChips"), "점검 약함"), "a week with two failed checks shows '점검 약함'")
	ok(sh != null and _has_text(sh, "점검 최고 25%"), "the best check score is 25 percent")
	_close_sheets()
	# 전부 끝낸 뒤(준비된 주): 마지막 주가 지금
	_world()
	_start_course_mode()
	for w in range(1, _avail + 1):
		CourseStore.check_done(w, {"ok": 12, "total": 12, "skip": true})
	await _new_view()
	diff = _diff(_course_states(), _expected(range(1, _avail + 1), _avail, _avail))
	ok(diff == "", "all prepared weeks done: every prepared week is done, the rest locked (%s)" % diff)
	ok(_has_text(_named(lv, "CourseCard"), "준비된 주를 모두 마쳤어요"), "all prepared weeks done: the card says so")
	_reached.append("states")


# ---------------------------------------------------------------- 4. 잠김·준비 중 (E5-3)

func _sec_lock_soon() -> void:
	print("[locked weeks ask first, weeks without content never open]")
	_world()
	_start_course_mode()
	await _new_view()
	var locked_w: int = 6
	ok(lv._course.state_of(locked_w) == "locked", "week 6 is locked for a new learner")
	press(lv._course.node_of(locked_w), "잠긴 노드(6주)")
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null and sh.buttons.has("preview") and sh.buttons.has("close") and not sh.buttons.has("start"), "a locked node asks first: [미리 해 보기] [닫기]")
	ok(sh != null and _has_text(sh, "미리 해 볼까요"), "the question is asked in Korean")
	ok(lv.course_player() == null, "no player yet")
	if sh != null:
		press(sh.buttons["close"], "잠김 확인 닫기")
	await _frames(2)
	ok(not Sheet.is_open() and lv.course_player() == null and lv.status == "idle", "[닫기]: nothing opened")
	press(lv._course.node_of(locked_w), "잠긴 노드(6주) (2)")
	await _frames(2)
	sh = _find_sheet()
	if sh != null:
		press(sh.buttons["preview"], "잠김 미리 해 보기")
	await _frames(3)
	sh = _find_sheet()
	ok(sh != null and sh.title_label != null and sh.title_label.text.begins_with("6주") and sh.buttons.has("start"), "[미리 해 보기]: the week sheet of week 6 opens")
	ok(sh != null and _named(sh, "AheadNote") != null, "[미리 해 보기]: the sheet says the cells are a preview")
	ok(lv.course_player() == null, "...and the player is still not open (a second press is needed)")
	_close_sheets()
	await _frames(2)
	# 내용이 없는 주
	var soon_w: int = _avail + 1
	press(lv._course.node_of(soon_w), "준비 중 노드(%d주)" % soon_w)
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and _has_text(sh, "준비 중") and sh.buttons.has("close") and not sh.buttons.has("start") and not sh.buttons.has("preview"), "a week without content: only [닫기]")
	if sh != null:
		press(sh.buttons["close"], "준비 중 닫기")
	await _frames(2)
	ok(not Sheet.is_open() and lv.course_player() == null, "the player did not open for a week without content")
	var all_closed: int = 0
	for w in [_avail + 1, _avail + 2, 40, 71, 72]:
		lv._course.node_of(w).pressed.emit()
		await _frames(1)
		var s2: Sheet = _find_sheet()
		if s2 != null and not s2.buttons.has("start") and not s2.buttons.has("preview") and lv.course_player() == null:
			all_closed += 1
		_close_sheets()
		await _frames(1)
	eq(all_closed, 5, "weeks %d, %d, 40, 71, 72: never open (5 of 5)" % [_avail + 1, _avail + 2])
	# 열린 칸: 지금 뒤 2칸
	ok(lv._course.state_of(2) == "open" and lv._course.state_of(3) == "open" and lv._course.state_of(4) == "locked", "weeks 2 and 3 are open, week 4 is locked (2 open weeks after the current one)")
	press(lv._course.node_of(2), "열림 노드(2주)")
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and sh.buttons.has("start") and not sh.buttons.has("preview"), "an open node opens its sheet without a question")
	_close_sheets()
	_reached.append("lock_soon")


# ---------------------------------------------------------------- 5. 점검으로 건너뛰기

func _sec_skip() -> void:
	print("[skip by check: real buttons, one skip record, a low score changes nothing]")
	_world()
	_start_course_mode()
	await _new_view()
	press(lv._course.node_of(3), "열림 노드(3주)")
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null and sh.buttons.has("skip") and (sh.buttons["skip"] as Button).text == "점검으로 건너뛰기", "the sheet of an open week has [점검으로 건너뛰기]")
	ok(sh != null and _named(sh, "AheadNote") != null and _has_text(_named(sh, "AheadNote"), "진도는 지금 칸을 끝내야 넘어가요"), "an open week ahead says its cells are a preview (progress needs the current cell)")
	if sh != null:
		press(sh.buttons["skip"], "점검으로 건너뛰기")
	await _frames(4)
	var pl: CoursePlayer = lv.course_player()
	ok(pl != null and pl.kind == "check" and pl.w == 3 and pl.d == 6, "[점검으로 건너뛰기] opens the weekly check of week 3 (day 6)")
	ok(pl != null and pl.skip_mode and bool(pl.spec.get("skip", false)), "the lesson tab opened it with skip:true (the player is in skip mode)")
	ok(pl != null and pl.state == "run", "the check unit was built from the real data")
	# 나가면 아무 기록도 없다
	if pl != null:
		press(pl.back_btn, "점검 나가기")
	await _frames(2)
	if pl != null and pl.leave_sheet() != null:
		press(pl.leave_sheet().buttons["quit"], "점검 그만하기")
	await _frames(5)
	ok(lv.course_player() == null and not bool(CourseStore.week_state(3)["done"]), "leaving the check skips nothing (week 3 is not done)")
	ok(not bool(CourseStore.week_state(3)["has_check"]), "leaving the check records nothing")
	# 0 % 두 번: weak 가 붙으면 안 된다
	for i in 2:
		var p0: CoursePlayer = await _skip_player(3)
		var n_auto: int = _auto_count(p0)
		ok(n_auto >= 5, "the real check has auto-graded questions (%d)" % n_auto)
		await _solve(p0, n_auto)
		ok(p0.state == "result" and bool(p0.result["skip"]), "skip 0%% #%d: the result card is shown (skip)" % i)
		eq(int(p0.result["pct"]), 0, "skip 0%% #%d: pct 0" % i)
		_expect_week(3, {"tries": 0, "best": 0, "weak": false, "done": false, "skipped": false, "has_check": false}, "skip 0%% #%d" % i)
		ok(_label_text(p0, "VerdictLine").contains("그대로") and _label_text(p0, "NextLine").contains("건너뛰지 않았어요"), "skip 0%% card tells the truth: %s / %s" % [_label_text(p0, "VerdictLine"), _label_text(p0, "NextLine")])
		press(_btn(p0, "DoneBtn"), "점검 완료 (0%%, %d)" % i)
		await _frames(4)
		ok(lv.course_player() == null and lv.status == "idle", "skip 0%% #%d: back on the road" % i)
	ok(lv._course.state_of(3) != "done", "0 percent twice: the road does not show week 3 done")
	# 80 % 대: 일반 점검이었다면 통과. 건너뛰기에서는 아무것도 바꾸지 않는다
	var p1: CoursePlayer = await _skip_player(3)
	var a1: int = _auto_count(p1)
	var wrong80: int = _wrong_for_band(a1, 80, 89)
	ok(wrong80 > 0, "a wrong-answer count exists for the 80s with %d auto questions (%d)" % [a1, wrong80])
	await _solve(p1, wrong80)
	var pct1: int = int(p1.result["pct"])
	ok(pct1 >= 80 and pct1 < 90 and not bool(p1.result["pass"]), "skip 80s: pct %d, not passed (the skip line is 90 percent)" % pct1)
	_expect_week(3, {"tries": 0, "best": 0, "weak": false, "done": false, "skipped": false, "has_check": false}, "skip 80s")
	ok(not _label_text(p1, "VerdictLine").contains("통과해서") and _label_text(p1, "NextLine").contains("건너뛰지 않았어요"), "skip 80s card does not say passed: %s" % _label_text(p1, "VerdictLine"))
	press(_btn(p1, "DoneBtn"), "점검 완료 (80s)")
	await _frames(4)
	ok(lv.course_player() == null, "skip 80s: back on the road")
	# 100 %: 건너뜀
	var p2: CoursePlayer = await _skip_player(3)
	await _solve(p2, 0)
	eq(int(p2.result["pct"]), 100, "skip 100%: pct 100")
	ok(bool(p2.result["pass"]), "skip 100%: passed")
	_expect_week(3, {"tries": 0, "best": 100, "weak": false, "done": true, "skipped": true, "has_check": true}, "skip 100%")
	ok(_label_text(p2, "VerdictLine").contains("건너뛰었어요") and _label_text(p2, "NextLine").contains("3주를 건너뛰었어요"), "skip 100%% card says the week was skipped: %s / %s" % [_label_text(p2, "VerdictLine"), _label_text(p2, "NextLine")])
	press(_btn(p2, "DoneBtn"), "점검 완료 (100%)")
	await _frames(5)
	ok(lv.course_player() == null and lv._course != null and lv._course.state_of(3) == "done", "after 100%: the road shows week 3 done")
	ok(lv._course.state_of(1) != "done" and lv._course.state_of(2) != "done", "weeks 1 and 2 are not touched by skipping week 3")
	lv._course.node_of(3).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and _has_text(_named(sh, "WeekChips"), "점검으로 건너뜀"), "the sheet of a skipped week says '점검으로 건너뜀'")
	_close_sheets()
	eq(StudyLog.path_last("en"), [], "the old path records stay empty")
	_reached.append("skip")


## 건너뛰기 점검을 레슨 탭의 길로 연다(주 상세 시트 [점검으로 건너뛰기]와 같은 신호). 열린 플레이어를 돌려준다.
func _skip_player(w: int) -> CoursePlayer:
	lv._course.unit_requested.emit(CourseHome.skip_spec(w))
	await _frames(4)
	var p: CoursePlayer = lv.course_player()
	ok(p != null and p.state == "run" and p.skip_mode, "a skip check is open (week %d)" % w)
	return p


func _expect_week(w: int, want: Dictionary, label: String) -> void:
	var st: Dictionary = CourseStore.week_state(w)
	var bad: Array = []
	for k in want.keys():
		if st.get(k) != want[k]:
			bad.append("%s=%s (want %s)" % [k, str(st.get(k)), str(want[k])])
	ok(bad.is_empty(), "%s: week %d record %s" % [label, w, str(bad) if not bad.is_empty() else str(want)])


## 처음 낸 문제 중 자동 채점(말하기가 아닌) 문제 수.
func _auto_count(p: CoursePlayer) -> int:
	var n: int = 0
	for e in p.queue:
		var ex: Dictionary = e["ex"]
		if int(e["attempt"]) == 0 and not CourseExerciseView.is_info_card(ex) and String(ex.get("type", "")) != "speak":
			n += 1
	return n


## 자동 채점 문제 auto 개 중 wrong 개를 틀렸을 때 점수가 lo..hi 가 되는 가장 작은 wrong (없으면 0).
func _wrong_for_band(auto: int, lo: int, hi: int) -> int:
	for w in range(1, auto + 1):
		var pct: int = clampi(roundi((auto - w) * 100.0 / float(auto)), 0, 100)
		if pct >= lo and pct <= hi:
			return w
	return 0


func _tile_press(v: CourseExerciseView, tok: String) -> bool:
	for b in v.tile_btns:
		if String(b.text) == tok and not b.disabled:
			press(b, "Tile %s" % tok)
			return true
	return false


## 지금 문제를 실제 버튼으로 맞게/틀리게 푼다. 말하기는 [말하기 어려워요]로 넘긴다(자동 채점에 들지 않는다).
func _answer(p: CoursePlayer, right: bool) -> void:
	var v: CourseExerciseView = p.view
	var e: Dictionary = v.ex
	match String(e["type"]):
		"recognize", "listen", "recall":
			if e.has("options"):
				var n: int = (e["options"] as Array).size()
				var pick: int = int(e["answer"]) if right else (int(e["answer"]) + 1) % n
				press(v.option_btns[pick], "Opt%d" % pick)
			else:
				var txt: String = String((e["accept"] as Array)[0]) if right else "qqxx"
				v.edit.text = txt
				v.edit.text_changed.emit(txt)
			press(p.find_child("ConfirmBtn", true, false), "ConfirmBtn")
		"build":
			var ans: Array = e["answer"]
			var toks: Array = ans if right else ans.slice(0, maxi(0, ans.size() - 1))
			for t in toks:
				_tile_press(v, String(t))
			press(p.find_child("ConfirmBtn", true, false), "ConfirmBtn")
		"dialogue_script":
			var g: int = 0
			while v.state != "answered" and g < 14:
				g += 1
				if v.state == "turn_done":
					press(p.find_child("ContinueBtn", true, false), "ContinueBtn")
				elif right:
					v.drill.recorder.recorded.emit({"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false})
					await _frames(3)
					press(_button_with_text(v, "잘했어요"), "잘했어요")
				else:
					press(p.find_child("SkipBtn", true, false), "SkipBtn")
				await _frames(2)
		_:
			press(p.find_child("SkipBtn", true, false), "SkipBtn")
	for i in 40:
		if v.state == "answered":
			return
		await get_tree().process_frame


## 단위를 끝까지 푼다: 자동 채점 문제 중 처음 wrong_n 개를 틀린다.
func _solve(p: CoursePlayer, wrong_n: int) -> void:
	var guard: int = 0
	var k: int = 0
	while p.state == "run" and guard < 300:
		guard += 1
		var v: CourseExerciseView = p.view
		var e: Dictionary = v.ex
		if CourseExerciseView.is_info_card(e):
			press(p.find_child("NextBtn", true, false), "NextBtn card")
			await _frames(1)
			continue
		var right: bool = true
		if String(e["type"]) != "speak":
			k += 1
			right = k > wrong_n
		await _answer(p, right)
		ok(v.state == "answered" and v.feedback != null and v.feedback.is_visible_in_tree(), "question %d: the feedback is visible after the answer" % k)
		press(p.find_child("NextBtn", true, false), "NextBtn")
		await _frames(1)
	ok(guard < 300 and p.state == "result", "the check ended in a result card (%d screens)" % guard)


# ---------------------------------------------------------------- 6. 시작 단위

func _sec_unit_spec() -> void:
	print("[the unit [이 주 시작] opens]")
	_world()
	_start_course_mode()
	var want_kind: Array = ["new", "new", "new", "new", "speak", "check", "listen"]
	var good: int = 0
	for d in range(1, 8):
		_advance_to(3, d)
		var sp: Dictionary = CourseHome.unit_spec(3)
		if str(sp["kind"]) == want_kind[d - 1] and int(sp["w"]) == 3 and int(sp["d"]) == d and str(sp["block"]) == "new":
			good += 1
		else:
			print("  unit_spec day %d: %s" % [d, str(sp)])
	eq(good, 7, "unit_spec(3) on days 1..7: new new new new speak check listen, block new")
	ok(str(CourseHome.unit_spec(3)["kind"]) != "free", "the free day never opens a 'free' unit (the player has no such unit)")
	# 다른 주: 아직 안 한 첫 날, 다 했으면 1일
	eq(int(CourseHome.unit_spec(6)["d"]), 1, "a week ahead: day 1")
	eq(int(CourseHome.unit_spec(1)["d"]), 1, "a week that is all done: day 1")
	_advance_to(4, 3)
	eq(int(CourseHome.unit_spec(4)["d"]), 3, "the week pos is in: its day")
	eq(CourseHome.skip_spec(5), {"kind": "check", "w": 5, "d": 6, "block": "new", "skip": true}, "skip_spec(5) is the weekly check, day 6, with skip:true")
	ok(not CourseHome.unit_spec(5).has("skip"), "unit_spec (a normal start) never carries skip")
	# D5 단위는 실제로 플레이어를 연다
	await _new_view()
	lv._course.unit_requested.emit(CourseHome.unit_spec(4))
	await _frames(3)
	eq(lv.status, "course", "a unit of day 3 opens in the player")
	var pl: CoursePlayer = lv.course_player()
	ok(pl != null and pl.d == 3 and pl.kind == "new", "the player got day 3")
	lv.go_back()
	await _frames(1)
	if pl != null and pl.leave_sheet() != null:
		pl.leave_sheet().buttons["quit"].pressed.emit()
	await _frames(4)
	_advance_to(4, 5)
	lv.refresh()
	await _frames(3)
	lv._course.unit_requested.emit(CourseHome.unit_spec(4))
	await _frames(3)
	pl = lv.course_player()
	ok(pl != null and pl.kind == "speak" and pl.d == 5 and pl.block == "new", "day 5: a speaking unit opened with block 'new' (so the cell can finish)")
	ok(pl != null and (pl.state == "run" or pl.state == "error"), "day 5: the player reached a state (%s)" % (pl.state if pl != null else "none"))
	if pl != null:
		pl.left.emit()
	await _frames(3)
	ok(lv.course_player() == null and lv.status == "idle", "the player closes on left()")
	# 두 번째 열기는 무시된다(이미 열려 있을 때)
	lv._course.unit_requested.emit(CourseHome.unit_spec(4))
	await _frames(2)
	var first: CoursePlayer = lv.course_player()
	lv._course.unit_requested.emit(CourseHome.unit_spec(4))
	await _frames(2)
	ok(first != null and lv.course_player() == first, "a second request while a unit is open is ignored")
	first.left.emit()
	await _frames(3)
	_reached.append("unit_spec")


# ---------------------------------------------------------------- 7. 일부러 틀린 입력 (E5-6)

func _sec_wrong_input() -> void:
	print("[wrong input]")
	# 코스 데이터가 없다
	_world()
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	CourseFeed.reset()
	var info: Dictionary = CourseHome.availability()
	ok(not bool(info["ok"]) and str(info["text"]) != "" and int(info["weeks"]) == 0, "availability(): not ok with a Korean text when the data is missing")
	eq(str(info["text"]), CourseData.text_for("course_missing"), "the text is the CourseData one")
	await _new_view()
	ok(_named(lv, "CourseNotice") != null and _has_text(_named(lv, "CourseNotice"), "코스 데이터"), "missing data: a one-line Korean notice")
	ok(_named(lv, "CourseStartCard") == null and _named(lv, "CourseModeSelector") == null, "missing data: no start card, no switch")
	eq(lv.path_boards().size(), 12, "missing data: the old path is shown (the app did not die)")
	Store.prefs["course_mode"] = "course"
	lv.refresh()
	await _frames(3)
	ok(lv._course == null and lv.path_boards().size() == 12 and _named(lv, "CourseNotice") != null, "missing data + course mode: the old path and the notice")
	_done_cb = []
	CourseHome.ask_start(lv, Callable(self, "_on_started"))
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null and sh.buttons.has("close") and not sh.buttons.has("start") and _has_text(sh, "코스 데이터"), "missing data: ask_start only explains")
	if sh != null:
		press(sh.buttons["close"], "데이터 없음 시트 닫기")
	await _frames(3)
	eq(_done_cb, [false], "missing data: on_done(false)")
	Store.prefs.erase("course_mode")
	eq(CourseStore.mode(), "legacy", "missing data: the mode was not switched")
	# 깨진 course.json
	_world()
	var f := FileAccess.open(CS, FileAccess.WRITE)
	f.store_string("{\"v\":1,\"pos\":{\"w\":")
	f.close()
	CourseStore.reset_memory()
	Store.prefs["course_mode"] = "course"
	await _new_view()
	ok(lv._course != null, "a broken course.json: the road opens")
	var pp: Dictionary = CourseStore.pos()
	ok(int(pp["w"]) == 1 and int(pp["d"]) == 1, "a broken course.json: the start state (week 1 day 1)")
	ok(FileAccess.file_exists(CS + ".bad"), "a broken course.json was moved to .bad")
	ok(_diff(_course_states(), _expected([], 1, _avail)) == "", "a broken course.json: the road is the first look")
	# 모르는 args
	var bad_args: Array = [{"lang": "fr"}, {"lang": 5}, {"lang": null}, {"n": "x", "w": 1}, {"n": 13, "w": 1}, {"n": 1.5, "w": 1}, {"n": 1, "w": 0}, {"w": 99}]
	var true_n: int = _accepted(bad_args)
	eq(true_n, 0, "open_target with unknown or odd args: false for all %d" % bad_args.size())
	ok(lv.open_target({"lang": "en"}) == true, "control: open_target({lang: en}) is true")
	eq(_accepted(["x"]), 0, "selfcheck helper: a non-dictionary argument list is not accepted")
	fails(_accepted([{"lang": "en"}]) != 0, "an accepted argument set is counted by the 'false for odd args' check")
	# 이상한 course_mode 가 코스 모드를 켜지 않는다
	for v in ["x", 5, null, true]:
		Store.prefs["course_mode"] = v
		lv.refresh()
		await _frames(2)
	ok(lv._course == null and CourseStore.mode() == "legacy", "the last odd value leaves the old path")
	_reached.append("wrong_input")


# ---------------------------------------------------------------- 8. 배치 (E5-8)

func _sec_layout() -> void:
	print("[layout: scroll to the current node, no sideways scroll, no overlaps]")
	_world()
	_start_course_mode()
	for w in range(1, 13):
		CourseStore.check_done(w, {"ok": 12, "total": 12, "skip": true})
	eq(CourseStore.pos(), {"w": 13, "d": 1}, "12 weeks done: pos is week 13 day 1")
	await _new_view()
	eq(lv._course.cur_w, 13, "the current week is 13")
	var pg: Rect2 = lv._page.get_global_rect()
	var cb: Button = lv.current_node_button()
	ok(cb != null and cb == lv._course.node_of(13), "the current node button is the node of week 13")
	ok(lv._page.scroll_vertical > 0, "the page scrolled down to the current node (%d)" % lv._page.scroll_vertical)
	var r: Rect2 = cb.get_global_rect()
	ok(pg.encloses(r), "the whole current node is inside the visible page")
	var yfrac: float = (r.get_center().y - pg.position.y) / maxf(pg.size.y, 1.0)
	ok(yfrac >= 0.2 and yfrac <= 0.55, "the current node is about 35 %% from the top (%.2f)" % yfrac)
	fails(not _in_band(0.9), "selfcheck: 90 % from the top is outside the band")
	ok(_in_band(0.35), "selfcheck: 35 % from the top is inside the band")
	var min_w: float = lv._page.column.get_combined_minimum_size().x
	ok(min_w <= lv._page.size.x + 0.5, "no sideways scrolling: the page content is not wider than the page (%.0f <= %.0f)" % [min_w, lv._page.size.x])
	ok(lv._page.get_h_scroll_bar().max_value <= lv._page.get_h_scroll_bar().page + 0.5 or not lv._page.get_h_scroll_bar().visible, "the horizontal scroll bar has nothing to scroll")
	var lr: Rect2 = lv.get_global_rect()
	var rects: Array = []
	var mins: Array = []
	var out_x: int = 0
	var tag_hits: int = 0
	var tag_out: int = 0
	var tag_tag: int = 0
	var tags_total: int = 0
	for b in lv.path_boards():
		var board: PathBoard = b
		var nr: Array = board.node_rects()
		var lrs: Array = []
		for k in range(1, 5):
			var nd: PathNode = board.node_button(k) as PathNode
			mins.append(72.0 if nd.state == "current" else 56.0)
			var tr: Rect2 = board.label_rect(k)
			lrs.append(tr)
			tags_total += 1
			for q in nr:
				if tr.intersects(q as Rect2):
					tag_hits += 1
			if tr.position.x < lr.position.x - 0.5 or tr.end.x > lr.end.x + 0.5:
				tag_out += 1
		rects.append_array(nr)
		for q in nr:
			if (q as Rect2).position.x < lr.position.x - 0.5 or (q as Rect2).end.x > lr.end.x + 0.5:
				out_x += 1
		var cr: Rect2 = board.chip_rect()
		if cr.size != Vector2.ZERO:
			for q in nr:
				if cr.intersects(q as Rect2):
					tag_hits += 1
			for t in lrs:
				if cr.intersects(t as Rect2):
					tag_hits += 1
		tag_tag += _overlaps(lrs)
		tag_tag += _overlaps(nr)
	eq(rects.size(), 72, "72 node rectangles")
	var small: int = 0
	for i in rects.size():
		var rr: Rect2 = rects[i]
		if rr.size.x < float(mins[i]) - 0.5 or rr.size.y < float(mins[i]) - 0.5:
			small += 1
	eq(small, 0, "every node is >= 56x56 (the current one 72)")
	eq(out_x, 0, "no node sticks out of the screen sideways")
	eq(tags_total, 72, "72 name tags")
	eq(tag_hits, 0, "no name tag or chip touches a node")
	eq(tag_tag, 0, "name tags and nodes of a board do not overlap each other")
	eq(tag_out, 0, "no name tag sticks out of the screen sideways")
	var chips: int = 0
	for b in lv.path_boards():
		if (b as PathBoard).chip_rect().size != Vector2.ZERO:
			chips += 1
	eq(chips, 1, "exactly one board shows the '지금' chip")
	# 주 상세 시트가 화면 안에 있다
	lv._course.node_of(13).pressed.emit()
	await _frames(3)
	var sh: Sheet = _find_sheet()
	ok(sh != null and sh.panel != null, "the week sheet of week 13 opens")
	if sh != null and sh.panel != null:
		var vp: Rect2 = Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
		ok(vp.grow(0.5).encloses(sh.panel.get_global_rect()), "the sheet panel is inside the screen (%s in %s)" % [str(sh.panel.get_global_rect()), str(vp)])
		var days_c: Node = _named(sh, "WeekDays")
		var dr: Array = []
		var d_out: int = 0
		if days_c != null:
			for c in days_c.get_children():
				dr.append((c as Control).get_global_rect())
				if (c as Control).get_global_rect().end.x > sh.panel.get_global_rect().end.x + 0.5:
					d_out += 1
		eq(dr.size(), 7, "7 day chips in the sheet")
		eq(_overlaps(dr), 0, "day chips do not overlap")
		eq(d_out, 0, "day chips stay inside the sheet width")
	_close_sheets()
	# PC 폭에서도 (폰이면 PC 폭 창으로 한 번 더)
	lv.size = Vector2(1100, 760) if phone else Vector2(412, 820)
	await _frames(4)
	var min_w2: float = lv._page.column.get_combined_minimum_size().x
	ok(min_w2 <= lv._page.size.x + 0.5, "the other width (%.0f): still no sideways overflow" % lv._page.size.x)
	lv.size = _screen
	await _frames(3)
	_reached.append("layout")


# ---------------------------------------------------------------- 9. PathBoard (월 번호 상한·옵션)

func _sec_pathboard() -> void:
	print("[PathBoard: 18 blocks, course options, old look unchanged]")
	var holder := Control.new()
	holder.size = _screen
	add_child(holder)
	var b := PathBoard.new()
	holder.add_child(b)
	b.size = Vector2(_screen.x, 400)
	b.build("en", 18, ["done", "current", "open", "locked"], ["가", "나", "다", "라"], 70, {"first_w": 69, "soon": [false, false, true, true], "label": "17개월차"})
	await _frames(2)
	eq(b.month_n, 18, "month_n 18 is kept (the limit is 18 now)")
	eq((b.node_button(1) as PathNode).text, "", "week 69 is done: a check mark, no number")
	eq((b.node_button(3) as PathNode).state, "locked", "a 'soon' week is locked even when its state says open")
	ok(b.label_of(1).text == "69주 · 가" and b.label_of(2).text == "70주 · 나", "tags count weeks from first_w: '69주 · 가', '70주 · 나'")
	ok(b.label_of(3).text == "71주 · 준비 중" and b.label_of(4).text == "72주 · 준비 중", "a soon week's tag says '준비 중'")
	eq((b.node_button(3) as PathNode).accessibility_name, "17개월차 71주, 준비 중", "accessibility name of a soon week")
	var got: Array = []
	b.node_pressed.connect(func(n: int, w: int, s: String) -> void: got.append([n, w, s]))
	b.node_button(2).pressed.emit()
	eq(got, [[18, 2, "current"]], "node_pressed sends the block and the week of the block (1..4)")
	b.build("en", 99, [], [], -1)
	eq(b.month_n, 18, "a block number above 18 is clamped to 18")
	b.build("en", 0, [], [], -1)
	eq(b.month_n, 1, "a block number below 1 is clamped to 1")
	# 예전 길: 옵션 없이 부르면 예전 그대로
	b.build("en", 3, ["done", "current", "open", "locked"], ["a", "b", "c", "d"], 5)
	ok(b.label_of(1).text == "1주 · a" and b.label_of(4).text == "4주 · d", "the old call (no options): tags '1주 · a' ... '4주 · d'")
	eq((b.node_button(3) as PathNode).accessibility_name, "3개월차 3주, 열림", "the old call: accessibility name '3개월차 3주, 열림'")
	eq((b.node_button(3) as PathNode).text, "3", "the old call: the node shows its week of the month")
	fails((b.node_button(3) as PathNode).text != "7", "a check that expects the number 7 on that node is rejected (it shows 3)")
	var h_old: Node = PathBoard.month_header(3, "제목", 1)
	ok(_has_text(h_old, "3개월차 · 제목") and _has_text(h_old, "완료 1/4주"), "the old month header text is unchanged")
	var h_new: Node = PathBoard.month_header(1, "", 2, 4, "0단계 입문")
	ok(_has_text(h_new, "0단계 입문") and not _has_text(h_new, "1개월차") and _has_text(h_new, "완료 2/4주"), "the course month header: the heading, and the count text from progress_label")
	h_old.free()
	h_new.free()
	holder.queue_free()
	await _frames(2)
	_reached.append("pathboard")


# ---------------------------------------------------------------- 10. 로드맵

func _sec_roadmap() -> void:
	print("[roadmap: the course card above the old 12 months]")
	_world()
	rv = RoadmapView.new()
	add_child(rv)
	rv.size = _screen
	await _frames(4)
	ok(_named(rv, "CourseProgressCard") == null and not _has_text(rv, "예전 12개월 로드맵"), "no course chosen: the roadmap is the old one (no card, no heading)")
	var cards_before: int = _count_nodes(rv)
	_start_course_mode()
	rv.refresh()
	await _frames(5)
	var card: Node = _named(rv, "CourseProgressCard")
	ok(card != null and _has_text(card, "새 코스 진행") and _has_text(card, "1주 1일"), "course mode: the '새 코스 진행' card says '1주 1일'")
	ok(card != null and _has_text(card, "완료 0/%d주" % _avail) and _has_text(card, "지금 1주차 · 전체 72주"), "the card: progress texts from progress_label ('완료 0/%d주', '지금 1주차 · 전체 72주')" % _avail)
	ok(_has_text(rv, "예전 12개월 로드맵"), "the old months are headed '예전 12개월 로드맵'")
	ok(_count_nodes(rv) > cards_before, "course mode adds the card and the heading to the old roadmap")
	ok(_has_text(rv, "전체 진행"), "the old roadmap content ('전체 진행') is still below")
	Store.set_lang("ja")
	rv.refresh()
	await _frames(4)
	ok(_named(rv, "CourseProgressCard") == null and not _has_text(rv, "예전 12개월 로드맵"), "Japanese: no card, no heading")
	Store.set_lang("en")
	CourseStore.set_mode("legacy")
	rv.refresh()
	await _frames(4)
	ok(_named(rv, "CourseProgressCard") == null, "[예전 길] mode: no course card on the roadmap")
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	CourseStore.set_mode("course")
	rv.refresh()
	await _frames(4)
	ok(_named(rv, "CourseProgressCard") == null, "course mode with missing data: no card (the roadmap still opens)")
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	rv.queue_free()
	await _frames(2)
	_reached.append("roadmap")


func _count_nodes(n: Node) -> int:
	var c: int = 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


# ---------------------------------------------------------------- 11. 보이는 숫자 (E5-7)

func _sec_numbers() -> void:
	print("[visible numbers: no 5-digit number, readable dates]")
	_world()
	_start_course_mode()
	CourseStore.today_override = Plan.iso_to_days(NOW_ISO)
	_advance_to(3, 4)
	CourseStore.check_done(1, {"ok": 9, "total": 12})
	await _new_view()
	eq(_five_digits(lv), 0, "the road (card, headers, tags, nodes): no text with a 5-digit number")
	var screens: Array = []
	for w in [1, 3, 6, _avail + 1, 72]:
		lv._course.node_of(w).pressed.emit()
		await _frames(2)
		var s: Sheet = _find_sheet()
		if s != null:
			screens.append(_five_digits(s))
			if s.buttons.has("preview"):
				(s.buttons["preview"] as Button).pressed.emit()
				await _frames(2)
				var s2: Sheet = _find_sheet()
				if s2 != null:
					screens.append(_five_digits(s2))
		_close_sheets()
		await _frames(1)
	var total_bad: int = 0
	for v in screens:
		total_bad += int(v)
	ok(screens.size() >= 5, "the sheets of 5 weeks (done, current, locked, soon, last) were scanned (%d)" % screens.size())
	eq(total_bad, 0, "the week sheets: no text with a 5-digit number")
	CourseHome.ask_start(lv)
	await _frames(2)
	eq(_five_digits(_find_sheet()) if _find_sheet() != null else 1, 0, "the start sheet: no 5-digit number")
	_close_sheets()
	# 날짜는 읽을 수 있는 꼴
	eq(CourseHome.date_label("2026-11-14"), "11월 14일 (토)", "date_label('2026-11-14') = '11월 14일 (토)'")
	eq(CourseHome.date_label("2026-12-01"), "12월 1일 (화)", "date_label('2026-12-01') = '12월 1일 (화)'")
	eq(CourseHome.date_label("garbage"), "", "date_label of garbage is ''")
	eq(CourseHome.date_label(20261114), "", "date_label of a number is ''")
	eq(CourseHome.date_label(null), "", "date_label of null is ''")
	fails(CourseHome.date_label("2026-11-14") != "2026-11-14", "a check that expects the raw ISO text is rejected (the label is the readable form)")
	var rx := RegEx.new()
	rx.compile("\\d{4}-\\d{2}-\\d{2}")
	var all: Array = []
	_texts(lv, all)
	var iso_hits: int = 0
	for t in all:
		if rx.search(str(t)) != null:
			iso_hits += 1
	eq(iso_hits, 0, "no raw ISO date (2026-11-14) on the road")
	# 진행 글은 CourseModel.progress_label 과 같은 글이다
	eq(CourseModel.progress_label("weeks", 2, 4), "2/4주", "progress_label('weeks', 2, 4) = '2/4주' (the header text is built from it)")
	eq(CourseModel.progress_label("weeks", 123456, 4), "4/4주", "progress_label never shows more than the target")
	_reached.append("numbers")


# ---------------------------------------------------------------- 12. 소스 검사

func _sec_source() -> void:
	print("[source scan]")
	for p in SRC_ALL:
		var f := FileAccess.open(p, FileAccess.READ)
		var txt: String = f.get_as_text() if f != null else ""
		ok(txt != "", "source readable: %s" % p)
		var is_lesson: bool = p.ends_with("lesson_view.gd")
		var hits: Array = _scan_source_text(txt, SRC_NEW.has(p), not is_lesson)
		ok(hits.is_empty(), "no forbidden pattern in %s (%s)" % [p, str(hits)])
		if is_lesson:
			ok(_symbol_count(txt) <= OLD_LESSON_SYMBOLS, "lesson_view.gd has no new symbol glyph (the %d check/cross marks of the old screen only): %d" % [OLD_LESSON_SYMBOLS, _symbol_count(txt)])
	fails(_symbol_count("a " + char(0x2713) + " b " + char(0x2713) + " c") > 1, "the symbol counter counts two glyphs")
	_reached.append("source")
