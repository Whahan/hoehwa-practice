extends Node
## T5 (docs/home_menu_design.md §11.9, T5-1..T5-16): the lesson path on the lesson tab (LessonView home + PathBoard + PathNode).
##   PC:    godot --headless --path <project> --resolution 1280x800 res://tests/lesson_path_test.tscn
##   phone: godot --headless --path <project> --resolution 412x915 res://tests/lesson_path_test.tscn -- --phone
##   options after `--`: --phone, --font-scale=<f> (1.0 .. 1.5), --dark
## Builds the lesson home from logs and checks that happen in this file only (user://test_home_t5_* files, the real
## ones are never opened; Api.base_url is a closed port, Api.sent_count must not move for a sheet that is dismissed).
## The checkers are tried on wrong input too ("selfcheck FAIL-as-expected ..."): a checker that cannot fail proves nothing.
## Last line: "== lesson_path_test: N passed, M failed ==", exit code 1 on any failure.

const LOG := "user://test_home_t5_studylog.json"
const PROG := "user://test_home_t5_progress.json"
const PREFS := "user://test_home_t5_prefs.json"
const LESSON_FIX := "res://tests/sample_lesson.json"
const CLOSED_PORT_URL := "http://127.0.0.1:9"
const PATH_FILES := ["res://scripts/ui/path_board.gd", "res://scripts/ui/path_node.gd", "res://tests/lesson_path_test.gd"]

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _dark: bool = false
var _scale: float = 1.0
var lv: LessonView = null
var _saved: Dictionary = {}
var _reached: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--phone":
			_phone = true
		elif a == "--dark":
			_dark = true
		elif a.begins_with("--font-scale="):
			var f: String = a.substr(13)
			_scale = f.to_float() if f.is_valid_float() else 1.0
	print("== lesson_path_test start (%s, dark=%s, font_scale=%s) ==" % ["phone" if _phone else "pc", _dark, _scale])
	UiBoot.apply(get_tree().root, "dark" if _dark else "light", _scale)
	ok(is_equal_approx(Ds.font_scale, Ds.sanitize_scale(_scale)) and Pal.is_dark() == _dark and Platform.is_phone() == _phone, "the run uses the asked text scale (%s), scheme (dark=%s) and platform (phone=%s)" % [Ds.font_scale, Pal.is_dark(), Platform.is_phone()])
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree()) # main.gd does it for the app; the lesson home is built here without main
	_setup()
	await _run()
	_teardown()
	for s in ["structure", "states", "geometry", "scroll", "touch", "sheets", "lock", "check", "record", "target", "robust", "perf", "files"]:
		ok(_reached.has(s), "section '%s' ran to its end" % s)
	print("== lesson_path_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for p in [LOG, LOG + ".bad", LOG + ".tmp", PROG, PROG + ".tmp", PREFS, PREFS + ".tmp"]:
		_rm(p)


func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true), "progress": Store.progress, "prefs_path": Store.prefs_path,
		"progress_path": Store.progress_path, "log_path": StudyLog.path, "curriculum": Store.curriculum.duplicate(true),
		"base": Api.base_url,
	}
	Store.prefs_path = PREFS
	Store.progress_path = PROG
	StudyLog.path = LOG
	_cleanup()
	Store.progress = Progress.blank()
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("lesson_source")
	Api.base_url = CLOSED_PORT_URL


func _teardown() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
	_cleanup()
	Store.curriculum = _saved["curriculum"]
	Store.prefs = _saved["prefs"]
	Store.progress = _saved["progress"]
	Store.prefs_path = _saved["prefs_path"]
	Store.progress_path = _saved["progress_path"]
	StudyLog.path = _saved["log_path"]
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	Api.base_url = _saved["base"]


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _new_view() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
		await _frames(1)
	lv = LessonView.new()
	add_child(lv)
	lv.size = Vector2(412, 820) if _phone else Vector2(1100, 760)
	await _frames(3)


# ---------------------------------------------------------------- checkers (each also tried on wrong input)

func _node(n: int, w: int) -> PathNode:
	var bs: Array = lv.path_boards()
	if n < 1 or n > bs.size():
		return null
	return (bs[n - 1] as PathBoard).node_button(w) as PathNode


func _states_now() -> Array:
	var out: Array = []
	for n in range(1, 13):
		for w in range(1, 5):
			var nd: PathNode = _node(n, w)
			out.append(nd.state if nd != null else "<none>")
	return out


## "" when `actual` equals `expected`, else a description of the first difference.
func _diff_states(actual: Array, expected: Array) -> String:
	if actual.size() != expected.size():
		return "size %d != %d" % [actual.size(), expected.size()]
	for i in actual.size():
		if str(actual[i]) != str(expected[i]):
			return "cell %d: %s != %s" % [i, actual[i], expected[i]]
	return ""


func _expected_t52(extra_done: Array) -> Array:
	var out: Array = []
	for i in 48:
		var s: String
		if i == 8 or extra_done.has(i):
			s = "done"
		elif i == 9:
			s = "current"
		elif i == 10 or i == 11:
			s = "open"
		elif i < 8:
			s = "past"
		else:
			s = "locked"
		out.append(s)
	return out


func _overlaps(rects: Array) -> int:
	var cnt: int = 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				cnt += 1
	return cnt


## Rectangles smaller than their minimum (56, current 72).
func _small_count(rects: Array, mins: Array) -> int:
	var cnt: int = 0
	for i in rects.size():
		var r: Rect2 = rects[i]
		if r.size.x < float(mins[i]) - 0.5 or r.size.y < float(mins[i]) - 0.5:
			cnt += 1
	return cnt


func _in_band(y: float, top: float, h: float, lo: float, hi: float) -> bool:
	return y >= top + h * lo - 1.0 and y <= top + h * hi + 1.0


func _node_count(root: Node) -> int:
	var c: int = 1
	for ch in root.get_children():
		c += _node_count(ch)
	return c


func _all_node_rects() -> Array:
	var out: Array = []
	for b in lv.path_boards():
		out.append_array((b as PathBoard).node_rects())
	return out


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


func _find_check(n: Node, name: String) -> CheckBox:
	if n is CheckBox and (n as CheckBox).accessibility_name == name:
		return n as CheckBox
	for c in n.get_children():
		var r: CheckBox = _find_check(c, name)
		if r != null:
			return r
	return null


func _fixture() -> Array:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(LESSON_FIX))
	return LessonView._parse_lesson(v)


# ---------------------------------------------------------------- run

func _run() -> void:
	await _new_view()
	await _sec_structure()
	await _sec_states()
	await _sec_geometry()
	await _sec_scroll()
	await _sec_touch()
	await _sec_sheets()
	await _sec_record()
	await _sec_target()
	await _sec_robust()
	_sec_perf_files()


func _sec_structure() -> void:
	print("[T5-1 structure: no records yet]")
	var bs: Array = lv.path_boards()
	ok(bs.size() == 12, "12 month boards (%d)" % bs.size())
	var total: int = 0
	var good_names: bool = true
	for b in bs:
		for w in range(1, 5):
			var nd: Button = (b as PathBoard).node_button(w)
			if nd != null:
				total += 1
				if nd.accessibility_name == "":
					good_names = false
		ok((b as PathBoard).node_button(0) == null and (b as PathBoard).node_button(5) == null, "node_button outside 1..4 is null")
	ok(total == 48, "48 node buttons in total (%d)" % total)
	ok(good_names, "every node has an accessibility_name")
	var st: Array = _states_now()
	ok(st.count("current") == 1, "exactly one current node for a new user (%d)" % st.count("current"))
	ok(st.count("done") == 0, "no node is done for a new user")
	var n1: PathNode = _node(1, 1)
	ok(n1 != null and n1.accessibility_name.begins_with("1개월차 1주,"), "accessibility name '%s' starts with '1개월차 1주,'" % (n1.accessibility_name if n1 != null else ""))
	if _phone:
		ok(lv.header_block() == null and lv.scroll_host() == null, "phone: no big title block, the app bar carries the title (docs 7.3)")
	else:
		ok(lv.header_block() != null and lv.scroll_host() == lv._page, "PC: PageHeader block and scroll host")
	_reached.append("structure")


func _sec_states() -> void:
	print("[T5-2 states for fixed records]")
	for i in 5:
		StudyLog.add_path_lesson("en", 3, 1, 4, 5)
	for i in 3:
		StudyLog.add_path_lesson("en", 3, 2, 4, 5)
	ok(StudyLog.path_done("en", 3, 1) == 5 and StudyLog.path_done("en", 3, 2) == 3, "records: 3-1 five lessons, 3-2 three")
	lv.refresh()
	await _frames(3)
	var cc: Dictionary = PathModel.current_cell("en")
	ok(int(cc["i"]) == 9, "PathModel.current_cell is cell 9 = 3-2 (%d)" % int(cc["i"]))
	var diff: String = _diff_states(_states_now(), _expected_t52([]))
	ok(diff == "", "states: 0..7 past, 8 done, 9 current, 10..11 open, 12.. locked (%s)" % diff)
	ok(lv.sel_n == 3 and lv.sel_w == 2, "selection follows the path: 3-2 (%d-%d)" % [lv.sel_n, lv.sel_w])
	# the PathNode marker follows the PathModel state of every cell
	var model: Dictionary = PathModel.states(PathModel.done_flags("en"), PathModel.calendar_index(), 9)
	ok(_diff_states(_states_now(), model["states"]) == "", "PathNode.state equals PathModel.states cell by cell")
	# a weekly check alone also makes a cell done
	Store.set_checked(Store.check_key("en", 1, "w", 2), true)
	lv.refresh()
	await _frames(3)
	diff = _diff_states(_states_now(), _expected_t52([2]))
	ok(diff == "" and _node(1, 3).state == "done", "a week checked in the roadmap is done on the path (%s)" % diff)
	Store.set_checked(Store.check_key("en", 1, "w", 2), false)
	lv.refresh()
	await _frames(3)
	ok(_diff_states(_states_now(), _expected_t52([])) == "", "un-checking it gives the first table back")
	# node look: shape and token colours of every state
	var sb: StyleBoxFlat = _node(3, 1).get_theme_stylebox("normal") as StyleBoxFlat
	ok(sb != null and sb.bg_color == Pal.PRIMARY and _node(3, 1).get_child_count() == 1, "done: PRIMARY fill + one mark (check)")
	sb = _node(3, 2).get_theme_stylebox("normal") as StyleBoxFlat
	ok(sb != null and sb.bg_color == Pal.PRIMARY and sb.border_color == Pal.REWARD and sb.get_border_width(SIDE_LEFT) == 4, "current: PRIMARY fill + 4 px REWARD ring")
	sb = _node(3, 3).get_theme_stylebox("normal") as StyleBoxFlat
	ok(sb != null and sb.bg_color == Pal.SURFACE and sb.border_color == Pal.PRIMARY and _node(3, 3).text == "3", "open: SURFACE + PRIMARY ring + the week number")
	sb = _node(1, 1).get_theme_stylebox("normal") as StyleBoxFlat
	ok(sb != null and sb.bg_color == Pal.SUNK and _node(1, 1).text == "1", "past: SUNK + the week number")
	sb = _node(4, 1).get_theme_stylebox("normal") as StyleBoxFlat
	ok(sb != null and sb.bg_color == Pal.SUNK and _node(4, 1).text == "" and _node(4, 1).get_child_count() == 1, "locked: SUNK + a mark (lock), no number")
	# checker on wrong input
	var wrong: Array = _expected_t52([])
	wrong[12] = "open"
	ok(_diff_states(_states_now(), wrong) != "", "selfcheck FAIL-as-expected: a table with one wrong cell is rejected")
	ok(_diff_states([], _expected_t52([])) != "", "selfcheck FAIL-as-expected: a short list is rejected")
	_reached.append("states")


func _sec_geometry() -> void:
	print("[T5-4 / T5-13 geometry (scale %s)]" % _scale)
	var rects: Array = _all_node_rects()
	var mins: Array = []
	for n in range(1, 13):
		for w in range(1, 5):
			mins.append(72.0 if _node(n, w).state == "current" else 56.0)
	ok(rects.size() == 48, "48 node rectangles")
	ok(_small_count(rects, mins) == 0, "every node is >= 56x56 (current 72): small=%d" % _small_count(rects, mins))
	ok(_overlaps(rects) == 0, "no two nodes overlap (%d)" % _overlaps(rects))
	var lr: Rect2 = lv.get_global_rect()
	var out_x: int = 0
	for r in rects:
		if (r as Rect2).position.x < lr.position.x - 0.5 or (r as Rect2).end.x > lr.end.x + 0.5:
			out_x += 1
	ok(out_x == 0, "no node sticks out of the page sideways (%d)" % out_x)
	var tag_hits: int = 0
	var tag_out: int = 0
	var tag_tag: int = 0
	var tags_total: int = 0
	for b in lv.path_boards():
		var board: PathBoard = b
		var nr: Array = board.node_rects()
		var lrs: Array = []
		for w in range(1, 5):
			var tr: Rect2 = board.label_rect(w)
			lrs.append(tr)
			tags_total += 1
			for r in nr:
				if tr.intersects(r as Rect2):
					tag_hits += 1
			if tr.position.x < lr.position.x - 0.5 or tr.end.x > lr.end.x + 0.5:
				tag_out += 1
		var cr: Rect2 = board.chip_rect()
		if cr.size != Vector2.ZERO:
			for r in nr:
				if cr.intersects(r as Rect2):
					tag_hits += 1
			for t in lrs:
				if cr.intersects(t as Rect2):
					tag_hits += 1
		tag_tag += _overlaps(lrs)
	ok(tags_total == 48, "48 name tags")
	ok(tag_hits == 0, "no name tag or chip touches a node (%d hits)" % tag_hits)
	ok(tag_tag == 0, "name tags do not overlap each other (%d)" % tag_tag)
	ok(tag_out == 0, "no name tag sticks out of the page sideways (%d)" % tag_out)
	var cur_chip: bool = false
	for b in lv.path_boards():
		if (b as PathBoard).chip_rect().size != Vector2.ZERO:
			cur_chip = true
	ok(cur_chip, "the current node has its chip")
	# checkers on wrong input
	ok(_overlaps([Rect2(0, 0, 10, 10), Rect2(5, 5, 10, 10)]) == 1, "selfcheck FAIL-as-expected: overlapping rectangles are counted")
	ok(_small_count([Rect2(0, 0, 30, 30)], [56.0]) == 1, "selfcheck FAIL-as-expected: a 30 px node is counted as small")
	_reached.append("geometry")


func _sec_scroll() -> void:
	print("[T5-5 the current node is in view]")
	lv.refresh()
	await _frames(3)
	var nd: PathNode = _node(3, 2)
	var pg: Rect2 = lv._page.get_global_rect()
	var r: Rect2 = nd.get_global_rect()
	ok(nd.state == "current", "3-2 is current")
	ok(_in_band(r.get_center().y, pg.position.y, pg.size.y, 0.25, 0.5), "current node centre y %.0f is 25..50 %% from the top of the page (%.0f..%.0f)" % [r.get_center().y, pg.position.y, pg.end.y])
	ok(pg.encloses(r), "the whole current node is inside the visible page")
	ok(not _in_band(pg.position.y + pg.size.y * 0.9, pg.position.y, pg.size.y, 0.25, 0.5), "selfcheck FAIL-as-expected: 90 % from the top is not in the band")
	# the language switch must not keep an old scroll; a lesson-kind change keeps it
	lv._page.scroll_vertical = lv._page.scroll_vertical + 120
	var before: int = lv._page.scroll_vertical
	lv.set_lesson_source("tatoeba")
	await _frames(3)
	ok(absi(lv._page.scroll_vertical - before) <= 1, "changing the lesson kind keeps the scroll position (%d -> %d)" % [before, lv._page.scroll_vertical])
	lv.refresh()
	await _frames(3)
	_reached.append("scroll")


func _touch(pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _drag_ev(pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = pos
	e.relative = rel
	e.velocity = rel * 60.0
	Input.parse_input_event(e)


func _drag_ok(delta: int) -> bool:
	return delta >= 200


## T5-11: a finger that starts ON a node scrolls the page (>= 200 px for a 300 px drag) and presses nothing. (A tap made of
## injected touch events does not reach any Button here, not even a plain one, outside the app's main scene; the tap
## itself is covered by pressing the node in the sheet sections.)
func _sec_touch() -> void:
	print("[T5-11 touch: a drag that starts on a node]")
	if not _phone:
		print("  (phone only)")
		_reached.append("touch")
		return
	Input.emulate_touch_from_mouse = true
	Input.use_accumulated_input = false
	lv.refresh()
	await _frames(4)
	var nd: PathNode = _node(3, 2)
	var count: Array = [0]
	nd.pressed.connect(func() -> void: count[0] += 1)
	var pos: Vector2 = nd.get_global_rect().get_center()
	ok(lv.get_global_rect().has_point(pos), "the current node is on the screen (%s)" % str(pos))
	var start_v: int = lv._page.scroll_vertical
	_touch(pos, true)
	await _frames(1)
	for i in 30:
		pos.y -= 10.0
		_drag_ev(pos, Vector2(0, -10))
		await _frames(1)
	var end_v: int = lv._page.scroll_vertical
	_touch(pos, false)
	await _frames(3)
	ok(_drag_ok(end_v - start_v), "a 300 px drag from the node scrolled the page by %d px (need 200)" % (end_v - start_v))
	ok(count[0] == 0 and Sheet.depth() == 0, "...and pressed nothing (node pressed %d times, sheets %d)" % [count[0], Sheet.depth()])
	ok(not _drag_ok(0) and not _drag_ok(199), "selfcheck FAIL-as-expected: a drag that moved the page 0 or 199 px does not pass the 200 px rule")
	Input.emulate_touch_from_mouse = false
	_reached.append("touch")


func _sec_sheets() -> void:
	print("[T5-6 open node sheet]")
	var sent0: int = Api.sent_count
	var n33: PathNode = _node(3, 3)
	ok(n33.state == "open", "3-3 is open")
	n33.pressed.emit()
	await _frames(2)
	var sh: Sheet = _find_sheet()
	ok(sh != null and Sheet.depth() == 1, "pressing an open node opens a sheet")
	ok(sh != null and sh.buttons.has("start") and sh.buttons.has("close"), "the sheet has [레슨 시작] and [닫기]")
	ok(sh != null and _find_check(sh, "이번 주 활동 끝냄") != null, "the sheet has the weekly check row")
	ok(sh != null and sh.title_label != null and sh.title_label.text == "3개월차 · 3주", "sheet title '3개월차 · 3주'")
	if sh != null:
		(sh.buttons["start"] as Button).pressed.emit()
	ok(lv.status == "loading" and lv.sel_n == 3 and lv.sel_w == 3, "[레슨 시작] makes 3-3 the selection and the lesson loads (status %s, %d-%d)" % [lv.status, lv.sel_n, lv.sel_w])
	lv.quit_lesson()
	await _frames(2)
	ok(lv.status == "idle" and lv.path_boards().size() == 12, "quit_lesson gives the path back")

	print("[T5-7 locked node]")
	var sent1: int = Api.sent_count
	var n41: PathNode = _node(4, 1)
	ok(n41.state == "locked", "4-1 is locked")
	n41.pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	ok(sh != null and sh.buttons.has("preview") and sh.buttons.has("close"), "a locked node opens a confirm sheet with [미리 해 보기] and [닫기]")
	ok(lv.status == "idle", "nothing is started by opening the confirm sheet")
	if sh != null:
		(sh.buttons["close"] as Button).pressed.emit()
	await _frames(2)
	ok(Sheet.depth() == 0 and lv.status == "idle" and Api.sent_count == sent1, "[닫기]: only the sheet closes, status idle, Api.sent_count unchanged (%d -> %d)" % [sent1, Api.sent_count])
	_node(4, 1).pressed.emit()
	await _frames(2)
	ok(Sheet.depth() == 1, "the confirm sheet opens again")
	ok(Sheet.handle_back() == true, "Sheet.handle_back closes it")
	await _frames(2)
	ok(Sheet.depth() == 0 and lv.status == "idle" and Api.sent_count == sent1, "back button: only the sheet closes, nothing sent")
	_node(4, 1).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	if sh != null:
		(sh.buttons["preview"] as Button).pressed.emit()
	ok(lv.status == "loading" and lv.sel_n == 4 and lv.sel_w == 1, "[미리 해 보기] starts 4-1 (status %s, %d-%d)" % [lv.status, lv.sel_n, lv.sel_w])
	lv.quit_lesson()
	await _frames(2)
	ok(Api.sent_count >= sent0, "Api.sent_count only grew by the lessons that were started on purpose (%d -> %d)" % [sent0, Api.sent_count])
	_reached.append("sheets")
	_reached.append("lock")

	print("[T5-8 weekly check in the sheet]")
	var key: String = Store.check_key("en", 3, "w", 2)
	ok(not Store.is_checked(key), "3-3 is not checked yet")
	_node(3, 3).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	var cb: CheckBox = _find_check(sh, "이번 주 활동 끝냄") if sh != null else null
	ok(cb != null, "the weekly check row is a CheckBox")
	if cb != null:
		cb.button_pressed = true
	ok(Store.is_checked(key), "turning it on sets Store.is_checked(%s)" % key)
	if sh != null:
		(sh.buttons["close"] as Button).pressed.emit()
	await _frames(2)
	ok(_node(3, 3).state == "done", "after the sheet closes the path is drawn again: 3-3 is done (%s)" % _node(3, 3).state)
	_node(3, 3).pressed.emit()
	await _frames(2)
	sh = _find_sheet()
	cb = _find_check(sh, "이번 주 활동 끝냄") if sh != null else null
	ok(cb != null and cb.button_pressed, "the check is shown as on when the sheet is opened again")
	if cb != null:
		cb.button_pressed = false
	if sh != null:
		(sh.buttons["close"] as Button).pressed.emit()
	await _frames(2)
	ok(not Store.is_checked(key) and _node(3, 3).state == "open", "turning it off gives 3-3 open again (%s)" % _node(3, 3).state)
	_reached.append("check")


func _sec_record() -> void:
	print("[T5-3 the lesson is counted in the cell it was started for]")
	var fx: Array = _fixture()
	ok(fx.size() >= 4, "lesson fixture parsed (%d exercises)" % fx.size())
	lv.sel_n = 3
	lv.sel_w = 2
	var before_32: int = StudyLog.path_done("en", 3, 2)
	var before_74: int = StudyLog.path_done("en", 7, 4)
	lv.start_lesson()
	lv.quit_lesson() # cancel the request; _run_n / _run_w stay as started
	lv.load_exercises(fx)
	lv.sel_n = 7 # the selection moves while the lesson is running
	lv.sel_w = 4
	lv.results = []
	for e in fx:
		lv.results.append({"ok": true, "ex": e})
	lv.finish_lesson()
	ok(StudyLog.path_done("en", lv._run_n, lv._run_w) == before_32 + 1 and lv._run_n == 3 and lv._run_w == 2, "path_done(3-2) grew by 1 (%d -> %d, run cell %d-%d)" % [before_32, StudyLog.path_done("en", 3, 2), lv._run_n, lv._run_w])
	ok(StudyLog.path_done("en", 7, 4) == before_74, "the cell the selection moved to is unchanged (%d)" % StudyLog.path_done("en", 7, 4))
	var last: Array = StudyLog.path_last("en")
	ok(last == [3, 2], "path_last is the started cell (%s)" % str(last))
	ok(lv.status == "done", "the lesson is finished")
	# the selfcheck: counting at the selection instead of the started cell would be caught by the two lines above
	ok(StudyLog.path_done("en", 7, 4) != before_74 + 1, "selfcheck FAIL-as-expected: 7-4 did not get the lesson")
	lv.quit_lesson()
	await _frames(2)
	ok(lv.status == "idle", "back on the lesson home")
	lv.refresh() # the tab comes back: the selection is the current cell again
	await _frames(3)
	ok(_node(3, 2).state == "current" and lv.sel_n == 3 and lv.sel_w == 2, "the home is drawn for the new log: 3-2 still current with %d/5" % StudyLog.path_done("en", 3, 2))
	_reached.append("record")


func _sec_target() -> void:
	print("[T5-10 open_target]")
	lv.refresh()
	await _frames(2)
	var r: bool = lv.open_target({"lang": "ja", "n": 2, "w": 3, "start": false})
	ok(r == true, "open_target ja 2-3 returns true")
	ok(lv.lang == "ja" and lv.sel_n == 2 and lv.sel_w == 3 and lv.status == "idle", "lang ja, 2-3 selected, idle (%s %d-%d %s)" % [lv.lang, lv.sel_n, lv.sel_w, lv.status])
	ok(Store.lang() == "ja", "the app language follows")
	await _frames(1)
	ok(lv.path_boards().size() == 12, "the home was drawn again for ja")
	r = lv.open_target({"lang": "en", "n": 3, "w": 3, "start": true}) # checked before the next frame: a lesson from the phone's own bank may arrive one frame later
	ok(r == true and lv.status == "loading" and lv.sel_n == 3 and lv.sel_w == 3 and lv.lang == "en", "start: true with real-sentence lessons starts at once")
	lv.quit_lesson()
	await _frames(2)
	lv.set_lesson_source("ai")
	r = lv.open_target({"lang": "en", "n": 3, "w": 3, "start": true})
	ok(r == true and lv.status == "idle", "start: true with an AI lesson does not start (a person presses start)")
	lv.set_lesson_source("tatoeba")
	var sn: int = lv.sel_n
	var sw: int = lv.sel_w
	ok(lv.open_target({"lang": "en", "n": 13, "w": 1}) == false and lv.sel_n == sn and lv.sel_w == sw, "n = 13 -> false, selection unchanged")
	ok(lv.open_target({"lang": "en", "n": 2, "w": 0}) == false and lv.sel_n == sn, "w = 0 -> false")
	ok(lv.open_target({"lang": "en", "n": "2", "w": 1}) == false and lv.sel_n == sn, "n as a string -> false")
	ok(lv.open_target({"lang": "xx", "n": 1, "w": 1}) == false and lv.lang == "en", "unknown lang -> false")
	ok(lv.open_target({"lang": "en", "n": 2.5, "w": 1}) == false and lv.sel_n == sn, "n = 2.5 -> false")
	ok(lv.open_target({"lang": "en", "n": 1, "w": 1, "start": "yes"}) == true and lv.status == "idle" and lv.sel_n == 1, "a start value that is not true does not start")
	ok(lv.open_target({}) == true and lv.sel_n == 3 and lv.sel_w == 2, "an empty target selects the current cell 3-2 (%d-%d)" % [lv.sel_n, lv.sel_w])
	lv.load_exercises(_fixture())
	ok(lv.open_target({"lang": "en", "n": 2, "w": 2, "start": true}) == false and lv.status == "run", "while a lesson is being solved open_target says false and keeps it")
	lv.quit_lesson()
	await _frames(2)
	_reached.append("target")


func _sec_robust() -> void:
	print("[T5-15 broken input]")
	# 1) a broken path in the log
	var f := FileAccess.open(LOG, FileAccess.WRITE)
	f.store_string("{\"v\":1,\"days\":{},\"path\":\"garbage\"}")
	f.close()
	StudyLog.load_from_disk()
	lv.refresh()
	await _frames(3)
	ok(lv.path_boards().size() == 12 and _states_now().count("<none>") == 0, "path = a string in the log: 48 nodes")
	ok(StudyLog.path_done("en", 3, 2) == 0 and _states_now().count("current") == 1, "...and the path starts from the calendar (one current)")
	f = FileAccess.open(LOG, FileAccess.WRITE)
	f.store_string("{\"v\":1,\"days\":{},\"path\":{\"cells\":{\"en\":{\"0-0\":{\"done\":-1},\"13-1\":{\"done\":99},\"3-2\":{\"done\":\"7\"}}},\"last\":{\"en\":\"zz\"}}}")
	f.close()
	StudyLog.load_from_disk()
	lv.refresh()
	await _frames(3)
	ok(lv.path_boards().size() == 12 and StudyLog.path_done("en", 3, 2) == 0, "bad cells and values are dropped: 48 nodes")
	f = FileAccess.open(LOG, FileAccess.WRITE)
	f.store_string("{\"v\":1,\"days\":{}")
	f.close()
	StudyLog.load_from_disk()
	lv.refresh()
	await _frames(3)
	ok(lv.path_boards().size() == 12, "a cut-off log file: 48 nodes")
	_rm(LOG)
	_rm(LOG + ".bad")
	StudyLog.load_from_disk()
	StudyLog.reset()
	for i in 5:
		StudyLog.add_path_lesson("en", 3, 1, 4, 5)
	for i in 3:
		StudyLog.add_path_lesson("en", 3, 2, 4, 5)

	# 2) no curriculum
	var cur_saved: Dictionary = Store.curriculum.duplicate(true)
	Store.curriculum = {}
	lv.refresh()
	await _frames(3)
	var tag: Label = lv.path_boards()[2].label_of(2) if lv.path_boards().size() == 12 else null
	ok(lv.path_boards().size() == 12 and _states_now().count("<none>") == 0, "empty curriculum: 48 nodes")
	ok(tag != null and tag.text == "2주", "...with the number only on the tag ('%s')" % (tag.text if tag != null else ""))
	Store.curriculum = cur_saved

	# 3) a month with 3 weeks
	var ms: Array = ((Store.curriculum["en"] as Dictionary)["months"] as Array)
	var wk: Array = ((ms[2] as Dictionary)["weeks"] as Array)
	var last_week: Variant = wk.pop_back()
	lv.refresh()
	await _frames(3)
	var t4: Label = lv.path_boards()[2].label_of(4)
	ok(lv.path_boards().size() == 12 and _states_now().count("<none>") == 0, "a month with 3 weeks: 48 nodes")
	ok(t4 != null and t4.text == "4주", "...week 4 has no topic and no copy of week 3 ('%s')" % (t4.text if t4 != null else ""))
	wk.append(last_week)

	# 4) quit a lesson that is just starting, then draw the path
	lv.sel_n = 5
	lv.sel_w = 1
	lv.start_lesson()
	lv.quit_lesson()
	lv._render()
	await _frames(3)
	ok(lv.status == "idle" and lv.path_boards().size() == 12 and _states_now().count("<none>") == 0, "start then quit then draw: 48 nodes")
	_reached.append("robust")


func _sec_perf_files() -> void:
	print("[T5-14 size of the page, T5-16 files]")
	var n: int = _node_count(lv._page.content)
	print("PERF lesson home nodes=", n)
	ok(n <= 600, "the lesson home with all 12 months has %d nodes (<= 600)" % n)
	_reached.append("perf")
	var bad_hex: String = "Color(" + "\"#"
	for p in PATH_FILES:
		var src: String = FileAccess.get_file_as_string(p)
		ok(src != "", "%s is readable" % p)
		ok(not src.contains(bad_hex), "%s has no colour literal" % p)
		ok(_symbol_chars(src) == 0, "%s has no emoji or dingbat characters (%d)" % [p, _symbol_chars(src)])
	ok(_symbol_chars("a" + String.chr(0x2605) + "b") == 1 and _symbol_chars("a" + String.chr(0x1F525)) == 1, "selfcheck FAIL-as-expected: a star sign and an emoji are counted")
	ok(("x" + bad_hex).contains(bad_hex), "selfcheck FAIL-as-expected: the colour literal pattern matches a literal")
	_reached.append("files")


func _symbol_chars(s: String) -> int:
	var cnt: int = 0
	for i in s.length():
		var cp: int = s.unicode_at(i)
		if (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x1F300 and cp <= 0x1FAFF) or cp == 0x2B50 or cp == 0x2713:
			cnt += 1
	return cnt
