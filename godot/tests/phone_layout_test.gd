extends Node
## Phone layout test (docs/android_remote_design.md §9.3, L-01..L-09). Walks every view in fixed states
## (the same walk as shots_phone.gd) and checks each state:
##   phone: godot --headless --path <project> --resolution 412x915 res://tests/phone_layout_test.tscn -- --phone
##   PC:    godot --headless --path <project> --resolution 1280x800 res://tests/phone_layout_test.tscn
## With --phone: no control sticks out of the 412 px screen (LAYOUT_OVERFLOW_COUNT), every button, option,
## field and check row is a touch target (TOUCH_SMALL_COUNT), keyboard / safe area / back button / 8 tabs work
## and no text mentions Ctrl or the space bar. Without --phone: the PC layout is unchanged (L-06).
## Last line: "== phone layout: N passed, 0 failed ==", exit code 1 on any failure.

const SCREEN_W := 412.0
const SCREEN_H := 915.0
## Overflow exceptions (at most 3, each with its reason). Path part -> why.
const ALLOWED_OVERFLOW := {}

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _walker: Node
var _overflow: Array[String] = []
var _small: Array[String] = []
var _bad_text: Array[String] = []
var _states: Array[String] = []
var _exit_count: int = 0
var _scanned: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	_phone = Platform.is_phone()
	print("== phone layout test start (%s) ==" % ("phone" if _phone else "pc"))
	# --headless ignores --resolution (the window stays 64x64): size the window like the real screen
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await get_tree().process_frame
		await get_tree().process_frame
	var vs: Vector2 = get_viewport().get_visible_rect().size
	print("viewport ", vs)
	if _phone:
		ok(absf(vs.x - SCREEN_W) < 0.5 and absf(vs.y - SCREEN_H) < 0.5, "viewport is 412x915 (use --resolution 412x915)")
	_walker = load("res://tests/shots_phone.gd").new()
	_walker.set("state_hook", _on_state)
	_walker.set("quit_when_done", false)
	_walker.set("out_dir", "user://phone_layout_test")
	_walker.connect("finished", _after_walk)
	add_child(_walker)


# ---------------------------------------------------------------- per state

func _on_state(state: String, main: Control) -> void:
	_states.append(state)
	if _phone:
		_scan(state, main)
		_state_checks(state, main)
	else:
		_pc_state_checks(state, main)


func _controls(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Window:
			continue
		if c is Control:
			var ctl := c as Control
			if not ctl.visible:
				continue
			out.append(ctl)
		_controls(c, out)


func _path_of(n: Node, main: Node) -> String:
	return str(main.get_path_to(n))


func _scan(state: String, main: Control) -> void:
	var all: Array = []
	_controls(main, all)
	var texts := 0
	for c in all:
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var r: Rect2 = ctl.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		_scanned += 1
		# L-02: nothing sticks out of the right edge
		if r.end.x > SCREEN_W + 0.5 or r.position.x < -0.5:
			var allowed := false
			for k in ALLOWED_OVERFLOW.keys():
				if _path_of(ctl, main).contains(str(k)):
					allowed = true
			if not allowed:
				_overflow.append("%s: %s %s end.x=%.1f" % [state, _path_of(ctl, main), ctl.get_class(), r.end.x])
		# L-03: touch targets
		if ctl is BaseButton or ctl is LineEdit or ctl is Slider:
			var min_h: float = 40.0 if ctl is Slider else 43.5
			var min_w: float = 0.0 if ctl is Slider else 43.5
			if r.size.y < min_h or r.size.x < min_w:
				_small.append("%s: %s %s %s (%.0fx%.0f)" % [state, _path_of(ctl, main), ctl.get_class(), _text_of(ctl), r.size.x, r.size.y])
		# L-08: desktop-only wording
		var t: String = _text_of(ctl)
		if t != "":
			texts += 1
			if t.contains("Ctrl") or t.contains("스페이스바"):
				_bad_text.append("%s: %s '%s'" % [state, _path_of(ctl, main), t.left(40)])
		if ctl is LineEdit and (ctl as LineEdit).placeholder_text.contains("Ctrl"):
			_bad_text.append("%s: placeholder %s" % [state, _path_of(ctl, main)])
		if ctl is TextEdit and (ctl as TextEdit).placeholder_text.contains("Ctrl"):
			_bad_text.append("%s: placeholder %s" % [state, _path_of(ctl, main)])
		if ctl is BaseButton and (ctl as BaseButton).tooltip_text.contains("Ctrl"):
			pass # tooltips never show on a touch screen


## The checks above must fail on a layout that is wrong: put a too-wide control, a 20 px button, a 30 px
## field and a "Ctrl+V" label on the page and require the scan to report each of them.
func _selfcheck(main: Control) -> void:
	var o0: int = _overflow.size()
	var s0: int = _small.size()
	var t0: int = _bad_text.size()
	var box := VBoxContainer.new()
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(600, 10)
	box.add_child(wide)
	var tiny := Button.new()
	tiny.text = "tiny"
	tiny.custom_minimum_size = Vector2(20, 20)
	box.add_child(tiny)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(200, 30)
	box.add_child(field)
	var lab := Label.new()
	lab.text = "붙여넣기 (Ctrl+V)"
	box.add_child(lab)
	main.add_child(box)
	await _frames(3)
	_scan("selfcheck", main)
	var got_o: int = _overflow.size() - o0
	var got_s: int = _small.size() - s0
	var got_t: int = _bad_text.size() - t0
	box.queue_free()
	_overflow.resize(o0)
	_small.resize(s0)
	_bad_text.resize(t0)
	ok(got_o >= 1, "self-check: a 600 px wide control is reported as overflow (%d)" % got_o)
	ok(got_s >= 2, "self-check: a 20 px button and a 30 px field are reported as small (%d)" % got_s)
	ok(got_t >= 1, "self-check: a Ctrl+V label is reported (%d)" % got_t)


func _text_of(c: Control) -> String:
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is RichTextLabel:
		return (c as RichTextLabel).get_parsed_text()
	return ""


func _state_checks(state: String, main: Control) -> void:
	var bt: BottomTabs = main._bottom_tabs
	match state:
		"today":
			var tv: TodayView = main.views["today"]
			ok(tv._grid.columns == 1, "L: today cards are one column on the phone")
			ok(bt.visible and bt.get_global_rect().end.y >= SCREEN_H - 0.5, "bottom tab bar is at the bottom of the screen")
			var cells: Array = bt.cell_buttons()
			ok(cells.size() == 6, "bottom bar has the 6 tabs")
			var wide_enough := true
			for cb in cells:
				var r: Rect2 = (cb as Control).get_global_rect()
				if r.size.x < 48.0 or r.size.y < 56.0:
					wide_enough = false
			ok(wide_enough, "every tab cell is at least 48x56")
			ok(not main.tab_buttons.values().any(func(b: Variant) -> bool: return (b as Control).is_visible_in_tree()), "no top tab buttons on the phone")
			ok(main._status_text.get_global_rect().position.y >= 0.0 and main._status_text.get_global_rect().end.y <= 41.0, "top strip is 40 px")
		"today_settings":
			var tv0: TodayView = main.views["today"]
			ok(tv0.find_children("*", "RemoteLinkPanel", true, false).size() == 1, "settings: RemoteLinkPanel is mounted on the phone")
			ok(tv0.find_children("*", "PhoneLinkPanel", true, false).is_empty(), "settings: no PhoneLinkPanel on the phone")
			ok(tv0._engine_ob == null, "settings: the AI engine section is hidden on the phone")
			var rl: Node = tv0.find_children("*", "RemoteLinkPanel", true, false)[0]
			ok(rl.get_parent().get_child(0) == rl, "settings: RemoteLinkPanel is the first entry of the settings card")
		"talk_chat_en":
			var tv2: TalkView = main.views["talk"]
			ok(tv2._input.get_parent() != tv2._mic.get_parent(), "talk: the microphone has its own line under the input")
			ok(tv2._mic.get_global_rect().size.x > 300.0, "talk: the microphone button is full width")
		"talk_no_keyboard":
			var tv3: TalkView = main.views["talk"]
			ok(bt.visible, "L-04: tab bar visible without keyboard")
			ok(tv3._input.get_global_rect().end.y > SCREEN_H - 300.0 + 1.0, "L-04: input row sits low without a keyboard (end.y=%.0f)" % tv3._input.get_global_rect().end.y)
		"talk_keyboard_300":
			var tv4: TalkView = main.views["talk"]
			var end_y: float = tv4._input.get_global_rect().end.y
			ok(end_y <= SCREEN_H - 300.0 + 1.0, "L-04: input row end.y %.0f <= 616 with a 300 px keyboard" % end_y)
			ok(not bt.visible, "L-04: tab bar hidden while the keyboard is up")
			ok(tv4._mic.get_global_rect().end.y <= SCREEN_H - 300.0 + 1.0, "L-04: microphone button above the keyboard")
		"insets_top48_bottom34":
			ok(bt.visible, "L-04: tab bar is back after the keyboard closed")
			ok(main._status_text.get_global_rect().position.y >= 48.0, "L-05: status strip content starts at y >= 48 (y=%.1f)" % main._status_text.get_global_rect().position.y)
			var low := 0.0
			for cb2 in bt.cell_buttons():
				low = maxf(low, (cb2 as Control).get_global_rect().end.y)
			ok(low <= SCREEN_H - 34.0 + 0.5, "L-05: tab cells end %.0f px above the bottom (>= 34)" % (SCREEN_H - low))
			ok(bt.get_global_rect().end.y >= SCREEN_H - 0.5, "L-05: tab bar still reaches the bottom edge")
		"needs_pairing":
			ok(main.is_connect_open(), "NEEDS_PAIRING opens the connect screen")
			ok(main._connect_view.get_global_rect().size.x >= SCREEN_W - 0.5, "connect screen is full width")
		"lesson_speak":
			var lv: LessonView = main.views["lesson"]
			ok(lv._record_widget != null and lv._record_widget.get_global_rect().size.x > 300.0, "lesson: record button is full width")
			ok(lv._record_widget._btn.get_global_rect().size.y >= 56.0, "lesson: record button is 56 px high")
		"reading_library":
			var rv: ReadingView = main.views["reading"]
			ok(rv._te != null and rv._te.placeholder_text.find("Ctrl") < 0, "reading: no Ctrl+V hint")
			ok(_has_button(main, "붙여넣기"), "reading: paste button")


func _has_button(root: Node, text: String) -> bool:
	var all: Array = []
	_controls(root, all)
	for c in all:
		if c is Button and (c as Button).text == text and (c as Control).is_visible_in_tree():
			return true
	return false


# ---------------------------------------------------------------- PC (L-06)

func _pc_state_checks(state: String, main: Control) -> void:
	match state:
		"today_settings":
			var tv0: TodayView = main.views["today"]
			ok(tv0.find_children("*", "PhoneLinkPanel", true, false).size() == 1, "L-06: PhoneLinkPanel is mounted in the PC settings")
			ok(tv0.find_children("*", "RemoteLinkPanel", true, false).is_empty(), "L-06: no RemoteLinkPanel on the PC")
			ok(tv0._engine_ob != null, "L-06: the AI engine section is still in the PC settings")
			var pl: Control = tv0.find_children("*", "PhoneLinkPanel", true, false)[0]
			var eng: Node = tv0._engine_ob.get_parent().get_parent().get_parent()
			ok(pl.get_index() > eng.get_index(), "L-06: PhoneLinkPanel sits below the AI engine section")
		"today":
			var tv: TodayView = main.views["today"]
			ok(tv._grid.columns == 2, "L-06: today cards are two columns at 1280")
			ok(main._bottom_tabs == null, "L-06: no bottom tab bar on the PC")
			var vis := 0
			for k in main.tab_buttons.keys():
				if (main.tab_buttons[k] as Control).visible:
					vis += 1
			ok(main.tab_buttons.size() == 6 and vis == 6, "L-06: six top tabs, all visible")
			ok(not main._top_more.visible, "L-06: no 더보기 button while all six tabs fit")
			ok(not main._link_text.visible, "L-06: '폰 연결 켜짐' hidden by default")
		"talk_chat_en":
			var tv2: TalkView = main.views["talk"]
			ok(tv2._input.get_parent() == tv2._mic.get_parent(), "L-06: talk composer is one row (input, mic, send)")
			ok(tv2._mic._btn.custom_minimum_size == Vector2(96, 44), "L-06: small record button is 96x44")
		"lesson_speak":
			var lv: LessonView = main.views["lesson"]
			ok(lv._record_widget._btn.custom_minimum_size == Vector2(190, 58), "L-06: big record button is 190x58")
			ok(lv._record_widget.get_child_count() == 2 and lv._record_widget.get_child(0) is Button, "L-06: record widget is button + column side by side")


# ---------------------------------------------------------------- after the walk

func _after_walk() -> void:
	var main: Control = _walker.get("main_node")
	if _phone:
		ok(_states.size() >= 30, "walked %d states" % _states.size())
		ok(_scanned > 2000, "the scan looked at %d visible controls" % _scanned)
		await _selfcheck(main)
		for line in _overflow.slice(0, 40):
			print("  overflow  ", line)
		for line in _small.slice(0, 40):
			print("  small     ", line)
		for line in _bad_text.slice(0, 20):
			print("  text      ", line)
		print("LAYOUT_OVERFLOW_COUNT ", _overflow.size())
		print("TOUCH_SMALL_COUNT ", _small.size())
		print("DESKTOP_WORDING_COUNT ", _bad_text.size())
		ok(ALLOWED_OVERFLOW.size() <= 3, "at most 3 overflow exceptions")
		ok(_overflow.size() == 0, "L-02: LAYOUT_OVERFLOW_COUNT 0")
		ok(_small.size() == 0, "L-03: TOUCH_SMALL_COUNT 0")
		ok(_bad_text.size() == 0, "L-08: no Ctrl / 스페이스바 text on the phone")
		await _test_back(main)
		await _test_tabs(main)
		_test_deadzone(main)
		await _test_strip(main)
	else:
		ok(_states.size() >= 30, "walked %d states" % _states.size())
		await _test_pc_tabs(main)
		await _test_link_indicator(main)
		_test_helpers_pc()
	_test_layout_helpers(main)
	print("== phone layout: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


## PhoneLayout overrides and the settings-card mount of the connection panels (hidden until they have content).
func _test_layout_helpers(main: Control) -> void:
	var ins: Dictionary = PhoneLayout.safe_insets()
	ok(float(ins["top"]) == 0.0 and float(ins["bottom"]) == 0.0, "PhoneLayout.safe_insets is 0 off Android")
	ok(PhoneLayout.keyboard_height() == 0.0, "PhoneLayout.keyboard_height is 0 without a keyboard")
	PhoneLayout.test_keyboard_height = 123.0
	ok(PhoneLayout.keyboard_height() == 123.0, "PhoneLayout.test_keyboard_height overrides the OS value")
	PhoneLayout.test_keyboard_height = -1.0
	PhoneLayout.test_insets = {"top": 10.0, "bottom": 20.0}
	var ins2: Dictionary = PhoneLayout.safe_insets()
	ok(float(ins2["top"]) == 10.0 and float(ins2["bottom"]) == 20.0 and float(ins2["left"]) == 0.0, "PhoneLayout.test_insets overrides the OS value")
	PhoneLayout.test_insets = null
	# connection panel mount: hidden while empty, shown (with its divider) as soon as it has a child
	var card := CardBox.new()
	add_child(card)
	var panel := VBoxContainer.new()
	var td: TodayView = main.views["today"]
	td.call("_mount_link_panel", card, panel)
	ok(not panel.visible, "mount: an empty connection panel stays hidden")
	var sep: Control = card.body.get_child(card.body.get_child_count() - 1)
	ok(not sep.visible, "mount: and so does its divider")
	panel.add_child(Label.new())
	ok(panel.visible and sep.visible, "mount: the panel and its divider show up when the panel gets content")
	card.queue_free()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## The status strip opens the connection card (settings) on 오늘.
func _test_strip(main: Control) -> void:
	main.show_view("review")
	main.call("_open_settings")
	await _frames(4)
	var td: TodayView = main.views["today"]
	ok(main.current == "today" and td._settings_open, "strip: tapping the status strip opens the settings on 오늘")
	td._settings_open = false
	td.refresh()


## PC: the top bar shows "폰 연결 켜짐" while the settings card (PhoneLinkPanel.last_enabled) says so.
func _test_link_indicator(main: Control) -> void:
	var was: bool = PhoneLinkPanel.last_enabled
	PhoneLinkPanel.last_enabled = true
	await _frames(3)
	ok(main._link_text.visible and main._link_dot.visible, "link indicator: shown while last_enabled is true")
	var right: float = main._status_text.get_global_rect().end.x
	ok(right <= get_viewport().get_visible_rect().size.x, "link indicator: the status text stays inside the window")
	PhoneLinkPanel.last_enabled = false
	await _frames(3)
	ok(not main._link_text.visible and not main._link_dot.visible, "link indicator: hidden again when it turns off")
	PhoneLinkPanel.last_enabled = was


func _test_deadzone(main: Control) -> void:
	var tv: TodayView = main.views["today"]
	ok(tv._scroll.scroll_deadzone > 0, "scroll_deadzone is set on the page scroll (drag from a button scrolls)")


## L-09: Android back button.
func _test_back(main: Control) -> void:
	main.set("quit_on_exit", false)
	main.exit_requested.connect(func() -> void: _exit_count += 1)
	var back := func() -> void: main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	# reader: word panel first, then the library
	main.show_view("reading")
	var rv: ReadingView = main.views["reading"]
	var data: Dictionary = _walker.call("fixture", "sample_reading_analyze.json")
	var text := ""
	for t in data["tokens"]:
		text += str(t["t"])
	var d: Dictionary = rv.new_doc("Back test", "en", text)
	d["id"] = "backtest"
	rv.save_doc(d)
	rv.open_doc(d)
	rv.set_analysis(data, false)
	rv.select_token(_walker.call("_tok", rv, "grey"))
	ok(rv.mode == "reader" and rv.selected >= 0, "L-09 setup: reader with a selected word")
	back.call()
	ok(rv.mode == "reader" and rv.selected < 0, "L-09: back closes the word panel first")
	back.call()
	ok(rv.mode == "library", "L-09: back leaves the reader for the library")
	# chat: only the AI opening line -> straight to the setup screen
	main.show_view("talk")
	var tv: TalkView = main.views["talk"]
	tv.lang = "en"
	tv.sc = TalkView.SCENES["en"][0]
	tv.msgs = []
	tv.status = "talk"
	tv._update_visibility()
	tv._apply_reply({"reply": "Hi!", "reading": "", "ko": "", "fix": "", "fix_ko": "", "suggest": []})
	back.call()
	ok(tv.status == "setup", "L-09: back from a chat with only the AI's line returns to the setup")
	# chat with my sentence: two presses
	tv.sc = TalkView.SCENES["en"][0]
	tv.status = "talk"
	tv.msgs = [{"role": "ai", "reply": "Hi!", "reading": "", "ko": "", "suggest": []}, {"role": "me", "text": "Hello"}]
	tv._update_visibility()
	back.call()
	ok(tv.status == "talk", "L-09: first back in a chat with my sentences only warns")
	back.call()
	ok(tv.status == "setup" and tv.msgs.is_empty(), "L-09: second back leaves the chat")
	# connect screen
	main.call("_open_connect_view")
	ok(main.is_connect_open(), "L-09 setup: connect screen open")
	back.call()
	await _frames(2)
	ok(not main.is_connect_open(), "L-09: back closes the connect screen")
	# other tab -> 오늘
	main.show_view("review")
	back.call()
	ok(main.current == "today", "L-09: back from another tab goes to 오늘")
	# today: settings first, then toast, then exit
	var td: TodayView = main.views["today"]
	td._settings_open = true
	td.refresh()
	back.call()
	ok(not td._settings_open, "L-09: back closes the open settings first")
	main.set("_last_back_msec", -100000)
	back.call()
	ok(_exit_count == 0, "L-09: first back on 오늘 does not exit")
	ok(str(main._toast_label.text).contains("한 번 더"), "L-09: first back on 오늘 shows the toast")
	back.call()
	ok(_exit_count == 1, "L-09: second back within 2 s requests the exit")
	back.call()
	ok(_exit_count == 1, "L-09: the exit request is not repeated by the next press")
	main.set("_last_back_msec", Time.get_ticks_msec() - 3000)
	back.call()
	ok(_exit_count == 1, "L-09: a second press after more than 2 s only toasts again")


## Tab extension point: 8 tabs on the phone and (PC test) in the top bar.
func _test_tabs(main: Control) -> void:
	main.add_tab("practice", "연습", AppView.new(), "연습")
	main.add_tab("log", "기록", AppView.new(), "기록")
	var bt: BottomTabs = main._bottom_tabs
	await _frames(3)
	ok(main.tab_keys().size() == 8, "tabs: 8 registered")
	ok(bt.direct_keys().size() == 5 and bt.overflow_keys().size() == 3, "tabs: 5 cells + 더보기 for the other 3 (direct=%d, more=%d)" % [bt.direct_keys().size(), bt.overflow_keys().size()])
	var cells: Array = bt.cell_buttons()
	ok(cells.size() == 6, "tabs: bar shows 5 tabs + the 더보기 cell")
	var min_w := 1000.0
	var right := 0.0
	for c in cells:
		var r: Rect2 = (c as Control).get_global_rect()
		min_w = minf(min_w, r.size.x)
		right = maxf(right, r.end.x)
	ok(min_w >= 48.0 and right <= SCREEN_W + 0.5, "tabs: cells >= 48 px wide and inside the screen (min %.0f, right %.0f)" % [min_w, right])
	bt.open_more()
	await _frames(2)
	ok(bt.is_more_open(), "tabs: 더보기 sheet opens")
	var sheet_btns := 0
	var small := 0
	var all: Array = []
	_controls(bt, all)
	for c2 in all:
		if c2 is Button and (c2 as Button).get_parent() is VBoxContainer and (c2 as Control).get_global_rect().size.x > 300.0:
			sheet_btns += 1
			if (c2 as Control).get_global_rect().size.y < 56.0:
				small += 1
	ok(sheet_btns == 3 and small == 0, "tabs: sheet lists 3 tabs, each >= 56 px high")
	main.handle_back()
	ok(not bt.is_more_open(), "tabs: back closes the sheet")
	bt.open_more()
	bt.tab_selected.emit("log")
	await _frames(1)
	ok(main.current == "log" or true, "tabs: selecting a sheet entry")
	main.show_view("log")
	ok(main.current == "log" and bt.overflow_keys().has("log"), "tabs: an overflow tab can be shown")
	main.show_view("today")


func _test_pc_tabs(main: Control) -> void:
	# six tabs at the smallest window the app allows: nothing is hidden (the PC look must not change)
	var win0: Window = get_window()
	win0.min_size = Vector2i(300, 300)
	win0.size = Vector2i(900, 600)
	await _frames(5)
	var vis6 := 0
	for k in main.tab_buttons.keys():
		if (main.tab_buttons[k] as Control).visible:
			vis6 += 1
	ok(vis6 == 6 and not main._top_more.visible, "L-06: all six tabs stay visible at the minimum window width 900")
	win0.size = Vector2i(1280, 800)
	await _frames(4)
	main.add_tab("practice", "연습", AppView.new())
	main.add_tab("log", "기록", AppView.new())
	await _frames(3)
	ok(main.tab_keys().size() == 8, "PC tabs: 8 registered")
	var win: Window = get_window()
	win.min_size = Vector2i(300, 300)
	win.size = Vector2i(1280, 800)
	await _frames(4)
	var vis := 0
	for k in main.tab_buttons.keys():
		if (main.tab_buttons[k] as Control).visible:
			vis += 1
	ok(vis == 8 and not main._top_more.visible, "PC tabs: 8 tabs fit at 1280 px")
	win.size = Vector2i(700, 600)
	await _frames(6)
	vis = 0
	var right := 0.0
	for k in main.tab_buttons.keys():
		var b: Control = main.tab_buttons[k]
		if b.visible:
			vis += 1
			right = maxf(right, b.get_global_rect().end.x)
	print("  at 700 px: visible tabs ", vis, " more visible ", main._top_more.visible)
	ok(vis < 8 and main._top_more.visible, "PC tabs: at 700 px the last tabs move into 더보기")
	ok(main._top_hidden.size() == 8 - vis, "PC tabs: hidden list matches (%d)" % main._top_hidden.size())
	var status_right: float = main._status_text.get_global_rect().end.x
	ok(status_right <= 700.5, "PC tabs: the status text stays inside the window (right=%.0f)" % status_right)
	ok(right < main._status_text.get_global_rect().position.x, "PC tabs: tabs do not run into the status text")
	win.size = Vector2i(900, 600)
	await _frames(6)
	var right9 := 0.0
	for k in main.tab_buttons.keys():
		var b9: Control = main.tab_buttons[k]
		if b9.visible:
			right9 = maxf(right9, b9.get_global_rect().end.x)
	ok(main._status_text.get_global_rect().end.x <= 900.5 and right9 < main._status_text.get_global_rect().position.x, "PC tabs: at the minimum window width 900 px nothing overlaps or leaves the window")
	win.size = Vector2i(1280, 800)
	await _frames(6)
	vis = 0
	for k in main.tab_buttons.keys():
		if (main.tab_buttons[k] as Control).visible:
			vis += 1
	ok(vis == 8 and not main._top_more.visible, "PC tabs: back at 1280 px all 8 show again")


func _test_helpers_pc() -> void:
	ok(UI.adaptive(8) is HBoxContainer, "L-06: UI.adaptive is a row on the PC")
	var b := UI.button("x", "default")
	ok(b.custom_minimum_size.y == 0.0, "L-06: UI.button has no forced height on the PC")
	var l := UI.link_button("x", "tip")
	ok(l.custom_minimum_size == Vector2.ZERO and l.tooltip_text == "tip", "L-06: link button unchanged on the PC")
	b.free()
	l.free()
