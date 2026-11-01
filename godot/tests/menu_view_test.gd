extends Node
## MenuView (phone "메뉴" screen) + the shell pieces around it (home_menu_design §4, §7.6, §9.7; T3-4, T3-9, T3-10, T3-11).
##   phone: godot --headless --path <project> --resolution 412x915 res://tests/menu_view_test.tscn -- --phone
##   PC:    godot --headless --path <project> res://tests/menu_view_test.tscn
##   text:  ... -- --phone --font-scale=1.5
## Part 1 (both): the view alone -- rows, heights, taps, unknown keys, bad entries, the summary card, no overflow at 412 px.
## Part 2: main.tscn as a child -- the phone's AI row, the review badge, the AI-connect signal (phone: connect screen, PC:
## settings), deep navigation. No server is used (Backend is held back; --api is not needed). Files: only user://test_t3_*
## (prefs, progress, study log); the real files are never touched.
## Last line: "== menu_view_test result: N passed, M failed ==", exit code 1 on any failure.

const DIR := "user://test_t3_menu"
const SCREEN_W := 412.0

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _before: Array = []
var _saved := {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== menu_view_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	_before = _user_listing()
	_saved = {"prefs_path": Store.prefs_path, "progress_path": Store.progress_path, "log_path": StudyLog.path,
		"status": Backend.status, "health": Backend.health.duplicate(true), "starting": Backend._starting,
		"prefs": Store.prefs.duplicate(true), "progress": Store.progress.duplicate(true), "provider": HomeAi.provider}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("standalone_ok")
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	HomeAi.provider = Callable()
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: a PC run must never reach a real engine
	Sheet.animate = false
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)

	await _selfcheck()
	await _test_view()
	await _test_bad_entries()
	await _test_summary()
	await _test_overflow()
	await _test_shell()

	Store.prefs_path = _saved["prefs_path"]
	Store.progress_path = _saved["progress_path"]
	StudyLog.path = _saved["log_path"]
	Store.prefs = _saved["prefs"]
	Store.progress = _saved["progress"]
	Backend.health = _saved["health"]
	Backend.status = _saved["status"]
	Backend._starting = _saved["starting"]
	Backend.set_process(true)
	HomeAi.provider = _saved["provider"]
	_rm_dir(DIR)
	ok(JSON.stringify(_before) == JSON.stringify(_user_listing()), "no file of the real user:// folder was added or changed by this test")
	print("== menu_view_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for f in d.get_files():
		if not f.begins_with("test_") and f != "":
			out.append([f, FileAccess.get_modified_time("user://" + f)])
	out.sort() # files only: the views make their own empty folders (user://reading) when they are built
	return out


func _rm_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for s in d.get_directories():
		_rm_dir(path.path_join(s))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _stage(c: Control, w: float = SCREEN_W, h: float = 760.0) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(w, h)
	holder.size = Vector2(w, h)
	holder.position = Vector2.ZERO
	add_child(holder)
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(c)
	return holder


func _sample() -> Array:
	return [
		{"title": "말하기·읽기", "items": [
			{"key": "talk", "title": "원어민 대화", "sub": ""},
			{"key": "practice", "title": "연습", "sub": "미션·쉐도잉·받아쓰기"},
			{"key": "reading", "title": "읽기", "sub": ""}]},
		{"title": "기록", "items": [
			{"key": "stats", "title": "기록", "sub": ""},
			{"key": "roadmap", "title": "로드맵", "sub": ""}]},
		{"title": "앱", "items": [
			{"key": "__ai", "title": "AI 연결", "sub": "AI 연결 안 됨"},
			{"key": "settings", "title": "설정", "sub": ""}]},
	]


## A left click (press + release) on a control: what a tap is on the PC and on the phone (the phone fires on release).
func _tap(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		c.gui_input.emit(ev)


## The checker the tests below use: the rows on the screen are exactly `want` (in this order), each at least 56 px high
## (72 with a second line) and each has an accessibility name.
func _rows_ok(v: MenuView, want: Array) -> bool:
	if v.entry_keys() != want:
		return false
	for k in want:
		var r: Control = v.row_control(str(k))
		if r == null or r.get_global_rect().size.y < 55.5 or r.accessibility_name == "":
			return false
	return true


## Controls of `root` whose right edge is beyond `w` (the checker of the overflow test).
func _overflow_of(root: Node, w: float) -> Array:
	var bad: Array = []
	for c in root.find_children("*", "Control", true, false):
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var r: Rect2 = ctl.get_global_rect()
		if r.size.x > 0.0 and r.size.y > 0.0 and (r.end.x > w + 0.5 or r.position.x < -0.5):
			bad.append("%s %s end.x=%.1f" % [ctl.get_class(), ctl.name, r.end.x])
	return bad


# ---------------------------------------------------------------- the checkers can fail

func _selfcheck() -> void:
	var v := MenuView.new()
	var st := _stage(v)
	v.set_entries(_sample())
	await _frames(4)
	var good: Array = ["talk", "practice", "reading", "stats", "roadmap", "__ai", "settings"]
	ok(_rows_ok(v, good), "selfcheck: the right row list is accepted")
	ok(not _rows_ok(v, ["talk", "reading", "practice", "stats", "roadmap", "__ai", "settings"]), "selfcheck FAIL-as-expected: rows in the wrong order are rejected")
	print("  selfcheck FAIL-as-expected rows (wrong order, a missing row)")
	ok(not _rows_ok(v, ["talk", "practice", "reading", "stats", "roadmap", "settings"]), "selfcheck FAIL-as-expected: a missing row is rejected")
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(600, 10)
	wide.size = Vector2(600, 10)
	st.add_child(wide)
	await _frames(2)
	ok(_overflow_of(st, SCREEN_W).size() >= 1, "selfcheck FAIL-as-expected: a 600 px wide control is reported as overflow")
	print("  selfcheck FAIL-as-expected overflow (600 px control)")
	st.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- the view alone

func _test_view() -> void:
	var v := MenuView.new()
	var st := _stage(v)
	v.set_summary("연속 5일 · XP 240 · 별 6/48")
	v.set_entries(_sample())
	await _frames(4)
	ok(v.group_count() == 3 and v.row_count() == 7, "T3-4: 3 groups and 7 rows (%d, %d)" % [v.group_count(), v.row_count()])
	ok(_rows_ok(v, ["talk", "practice", "reading", "stats", "roadmap", "__ai", "settings"]), "T3-4: the rows are in order, each >= 56 px high with an accessibility name")
	ok(v.row_control("practice").get_global_rect().size.y >= 71.5, "T3-4: a row with a second line is at least 72 px high (%.0f)" % v.row_control("practice").get_global_rect().size.y)
	ok(v.page_title() == "" and v.scroll_host() != null and v.header_block() == null, "T3-4: no own title (the app bar shows 메뉴), a scroll host, no big title block")
	var got: Array = []
	var cb := func(k: String) -> void: got.append(k)
	v.entry_chosen.connect(cb)
	_tap(v.row_control("reading"))
	_tap(v.row_control("__ai"))
	ok(got == ["reading", "__ai"], "T3-4: tapping a row sends entry_chosen(key) (%s)" % [got])
	got.clear()
	v.choose("no_such_key")
	v.choose("")
	ok(got.is_empty(), "T3-4: choosing a key that is not on the screen is ignored")
	v.entry_chosen.disconnect(cb)
	st.queue_free()
	await _frames(2)


func _test_bad_entries() -> void:
	var v := MenuView.new()
	var st := _stage(v)
	v.set_entries([
		{"title": "비어 있는 묶음", "items": []},
		{"title": "", "items": [{"key": "a", "title": "이름 없는 묶음의 행"}]},
		{"title": "섞인 값", "items": [
			{"key": "x", "title": "X"}, {"key": "x", "title": "같은 key"}, {"key": "", "title": "key 없음"},
			{"key": "y", "title": ""}, "문자열", 7, null, {"key": 3, "title": "숫자 key"}, {"key": "z", "title": "Z", "sub": 5}]},
		"묶음이 아님", 3, null, {"title": "items 없음"}, {"title": "items 가 사전", "items": {"key": "q"}},
	])
	await _frames(3)
	ok(v.group_count() == 1 and v.entry_keys() == ["x", "z"], "T3-4: empty groups, a group without a title, rows without key/title, duplicates and non-dictionaries are skipped (%d groups, %s)" % [v.group_count(), v.entry_keys()])
	v.set_entries([])
	await _frames(2)
	ok(v.group_count() == 0 and v.row_count() == 0 and v.summary_card() == null, "T3-4: no entries at all: an empty page, no error")
	v.refresh()
	v.set_entries([{"title": "A", "items": [{"key": "k", "title": "K"}]}])
	await _frames(2)
	ok(v.entry_keys() == ["k"], "T3-4: entries can be set again after an empty page")
	st.queue_free()
	await _frames(2)


func _test_summary() -> void:
	var v := MenuView.new()
	var st := _stage(v)
	v.set_entries(_sample())
	v.set_summary("")
	await _frames(3)
	ok(v.summary_card() == null, "T3-4: set_summary('') shows no card")
	v.set_summary("   ")
	ok(v.summary_card() == null, "T3-4: a blank summary shows no card")
	v.set_summary("연속 5일 · XP 240 · 별 6/48")
	await _frames(3)
	var card: Control = v.summary_card()
	ok(card != null and card.get_global_rect().size.y >= 71.5, "T3-4: the 내 기록 card is there, at least 72 px high")
	var texts := ""
	for l in card.find_children("*", "Label", true, false):
		texts += (l as Label).text + "|"
	ok(texts.contains("연속 5일 · XP 240 · 별 6/48") and texts.contains("내 기록"), "T3-4: the card shows 내 기록 and the summary text (%s)" % texts)
	ok(card.find_children("*", "GlyphIcon", true, false).size() >= 2, "T3-4: the card has the sparkle in front and the chevron behind")
	var got: Array = []
	var cb := func(k: String) -> void: got.append(k)
	v.entry_chosen.connect(cb)
	var row: Control = null
	for c in card.find_children("*", "Control", true, false):
		if c is PanelContainer and (c as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			row = c
	if row == null:
		row = card
	_tap(row)
	ok(got == ["stats"], "T3-4: tapping the card opens 기록 (%s)" % [got])
	v.entry_chosen.disconnect(cb)
	v.set_summary("")
	await _frames(2)
	ok(v.summary_card() == null, "T3-4: clearing the summary removes the card")
	st.queue_free()
	await _frames(2)


func _test_overflow() -> void:
	var v := MenuView.new()
	var st := _stage(v)
	v.set_summary("연속 12일 · XP 12345 · 별 48/48 · 아주 긴 글자가 와도 줄을 바꿔서 보여 줘야 해요")
	v.set_entries([
		{"title": "말하기·읽기", "items": [
			{"key": "talk", "title": "원어민 대화 그리고 아주 긴 이름의 행도 두 줄까지만 보여요", "sub": "미션·쉐도잉·받아쓰기·약한 소리·가나 연습 모음"},
			{"key": "reading", "title": "읽기", "sub": ""}]},
		{"title": "앱", "items": [{"key": "__ai", "title": "AI 연결", "sub": "AI 답변이 꺼져 있어요"}, {"key": "settings", "title": "설정", "sub": ""}]},
	])
	await _frames(4)
	var bad: Array = _overflow_of(st, SCREEN_W)
	for line in bad.slice(0, 10):
		print("  overflow  ", line)
	ok(bad.is_empty(), "T3-4: at %d%% text nothing leaves the 412 px screen (%d)" % [int(_scale * 100.0), bad.size()])
	st.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- the shell around it

func _new_main() -> Control:
	var m: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	m.set("quit_on_exit", false)
	add_child(m)
	await _frames(6)
	return m


func _test_shell() -> void:
	var m: Control = await _new_main()
	var requests: Array = [0]
	var rcb := func() -> void: requests[0] += 1
	Store.ai_connect_requested.connect(rcb)
	# T3-10: the AI row (phone) and the request itself (both) -- the connect screen (phone) / the settings (PC)
	Backend._set_status(Backend.Status.FAILED, "x")
	await _frames(3)
	if _phone:
		var mv: MenuView = m.views["menu"]
		m.call("show_view", "menu")
		await _frames(4)
		ok(mv.entry_keys().has("__ai") and mv.entry_keys().find("__ai") < mv.entry_keys().find("settings"), "T3-10: with the engine down the 메뉴 has an 'AI 연결' row above 설정 (%s)" % [mv.entry_keys()])
		_tap(mv.row_control("__ai"))
		await _frames(3)
		ok(requests[0] == 1, "T3-10: pressing the row sends ai_connect_requested exactly once (%d)" % requests[0])
		ok(m.call("is_connect_open"), "T3-10: on the phone the request opens the connect screen")
		m.call("_close_connect_view")
		await _frames(2)
		# the row goes away when the slot is hidden (engine ready, LLM there)
		Backend.health = {"llm": true}
		Backend._set_status(Backend.Status.READY)
		await _frames(3)
		ok(not mv.entry_keys().has("__ai"), "T3-10: when the AI is ready the row is gone (the 메뉴 refreshes on a status change) (%s)" % [mv.entry_keys()])
	else:
		Store.request_ai_connect()
		await _frames(3)
		ok(requests[0] == 1 and m.get("current") == "settings", "T3-10: on the PC the request opens the settings (%d, %s)" % [requests[0], m.get("current")])
	Store.ai_connect_requested.disconnect(rcb)
	m.call("show_view", "today")
	await _frames(2)

	# T3-9: the review badge follows the number of due cards (phone bar only)
	if _phone:
		var bt: BottomTabs = m.get("_bottom_tabs")
		Store.progress["review"] = []
		Store.changed.emit()
		ok(not bool(bt._badges.get("review", false)), "T3-9: no due card: no dot on 복습")
		Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": ""}])
		Store.changed.emit()
		ok(bool(bt._badges.get("review", false)), "T3-9: one due card: the dot is on")
		Store.set_lang("ja")
		ok(not bool(bt._badges.get("review", false)), "T3-9: the badge counts the chosen language (ja has none)")
		Store.set_lang("en")
		ok(bool(bt._badges.get("review", false)), "T3-9: back to en: the dot is on again")
		Store.progress["review"] = []
		m.call("show_view", "lesson")
		ok(not bool(bt._badges.get("review", false)), "T3-9: showing a screen refreshes it: no due card, dot off")
		ok((bt.cell_buttons()[2] as Button).get_node("Badge") != null and not (bt.cell_buttons()[2] as Button).get_node("Badge").visible, "T3-9: the 복습 cell (3rd) carries the Badge node, hidden again")
	# T3-11: deep navigation changes the language and the screen; a screen without open_target just shows
	Store.navigate_args.emit("lesson", {"lang": "ja", "n": 2, "w": 3, "start": false})
	await _frames(3)
	ok(m.get("current") == "lesson" and Store.lang() == "ja", "T3-11: navigate_args opens 레슨 in 일본어 (%s, %s)" % [m.get("current"), Store.lang()])
	var handled: bool = (m.views["review"] as AppView).open_target({"lang": "en"})
	ok(not handled, "T3-11: the default AppView.open_target does nothing and answers false")
	Store.navigate_args.emit("review", {"lang": "xx", "junk": [1, 2]})
	await _frames(2)
	ok(m.get("current") == "review" and Store.lang() == "ja", "T3-11: a bad language in args is ignored, the screen still opens (%s, %s)" % [m.get("current"), Store.lang()])
	Store.set_lang("en")
	m.queue_free()
	await _frames(3)
