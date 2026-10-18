extends Node
## Phone layout test (docs/android_remote_design.md §9.3, L-01..L-09). Walks every view in fixed states
## (the same walk as shots_phone.gd) and checks each state:
##   phone: godot --headless --path <project> --resolution 412x915 res://tests/phone_layout_test.tscn -- --phone
##   PC:    godot --headless --path <project> --resolution 1280x800 res://tests/phone_layout_test.tscn
## With --phone: no control sticks out of the 412 px screen (LAYOUT_OVERFLOW_COUNT), every button, option,
## field and check row is a touch target (TOUCH_SMALL_COUNT), keyboard / safe area / back button / 8 tabs work
## and no text mentions Ctrl or the space bar. Without --phone: the PC shell (SideNav, no top tabs, content column)
## is checked (docs/ui_redesign_design.md §8.4 W4).
## Options after `--` (docs §8.4 W4 (9)):
##   --touch-min=<f>     smallest touch target in px (default 43.5; the 48 dp target of the redesign is 47.5)
##   --only=<prefix>     scan only the states whose name starts with <prefix> (the walk itself is unchanged; the run
##                       fails when no state matches). Also: --dark, --font-scale=<f> go to the walk (shots_phone.gd).
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
var _touch_min: float = 43.5
var _only: String = ""
var _dark: bool = false
var _font_scale_arg: String = ""
var _matched: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	_phone = Platform.is_phone()
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: the PC run must never reach the user's engine (8770)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--touch-min="):
			_touch_min = a.substr(12).to_float() if a.substr(12).is_valid_float() else 43.5
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a == "--dark":
			_dark = true
		elif a.begins_with("--font-scale="):
			_font_scale_arg = a.substr(13)
	print("== phone layout test start (%s) touch_min=%s only='%s' dark=%s font_scale='%s' ==" % ["phone" if _phone else "pc", _touch_min, _only, _dark, _font_scale_arg])
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
	if _only != "" and not state.begins_with(_only):
		return
	_matched += 1
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
			var min_h: float = 40.0 if ctl is Slider else _touch_min
			var min_w: float = 0.0 if ctl is Slider else _touch_min
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
	# a bigger text size (--font-scale) makes the Button / LineEdit above taller than their custom minimum, so the
	# self-check also puts down controls whose size nothing but custom_minimum_size decides
	var bare := BaseButton.new()
	bare.custom_minimum_size = Vector2(60, 20)
	box.add_child(bare)
	var bare30 := BaseButton.new()
	bare30.custom_minimum_size = Vector2(100, 30)
	box.add_child(bare30)
	var bare47 := BaseButton.new()
	bare47.custom_minimum_size = Vector2(120, 47)
	box.add_child(bare47)
	var lab := Label.new()
	lab.text = "붙여넣기 (Ctrl+V)"
	box.add_child(lab)
	main.add_child(box)
	await _frames(3)
	_scan("selfcheck", main)
	var got_o: int = _overflow.size() - o0
	var got_s: int = _small.size() - s0
	var got_t: int = _bad_text.size() - t0
	var small_lines: Array = _small.slice(s0)
	box.queue_free()
	_overflow.resize(o0)
	_small.resize(s0)
	_bad_text.resize(t0)
	ok(got_o >= 1, "self-check: a 600 px wide control is reported as overflow (%d)" % got_o)
	ok(got_s >= 2, "self-check: a 20 px button and a 30 px field are reported as small (%d)" % got_s)
	ok(got_s >= 1 and _small_texts_have(small_lines, "BaseButton  (") and _small_texts_have(small_lines, "x20)"), "self-check: a 20 px high touch target is reported as small at every text size")
	if _touch_min > 47.0:
		ok(_small_texts_have(small_lines, "x47)"), "self-check (F5): a 47 px high button is reported as small with --touch-min=%s" % _touch_min)
	else:
		ok(not _small_texts_have(small_lines, "x47)"), "self-check (F5): a 47 px high button passes with --touch-min=%s" % _touch_min)
	ok(got_t >= 1, "self-check: a Ctrl+V label is reported (%d)" % got_t)


func _small_texts_have(lines: Array, part: String) -> bool:
	for l in lines:
		if str(l).contains(part):
			return true
	return false


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
	var bar: AppBar = main._app_bar
	match state:
		"today":
			var tv: TodayView = main.views["today"]
			ok(tv._grid.columns == 1, "L: today cards are one column on the phone")
			ok(bt.visible and bt.get_global_rect().end.y >= SCREEN_H - 0.5, "bottom tab bar is at the bottom of the screen")
			var cells: Array = bt.cell_buttons()
			ok(cells.size() == 5, "W4-1: bottom bar has 5 cells: 4 tabs + 더보기 (%d)" % cells.size())
			var wide_enough := true
			for cb in cells:
				var r: Rect2 = (cb as Control).get_global_rect()
				if r.size.x < 48.0 or r.size.y < 56.0:
					wide_enough = false
			ok(wide_enough, "every tab cell is at least 48x56")
			ok(bt.max_direct == 5, "W4-1: BottomTabs.max_direct is 5")
			ok(bt.direct_keys() == ["today", "lesson", "talk", "review"], "W4-1: the direct tabs are 오늘, 레슨, 대화, 복습 (%s)" % [bt.direct_keys()])
			ok(bt.overflow_keys().has("settings") and bt.overflow_keys().back() == "settings", "W4-1: 설정 is the last entry of the 더보기 sheet (%s)" % [bt.overflow_keys()])
			ok(main._side_nav == null, "no side navigation on the phone")
			var inset: float = float(PhoneLayout.safe_insets()["top"])
			ok(bar.get_global_rect().size.y <= 56.0 + inset + 0.5, "W4-1: the app bar is at most 56 px + the inset high (%.0f)" % bar.get_global_rect().size.y)
			ok(main._status_text.text != "" and bar.get_global_rect().encloses(main._status_text.get_global_rect()), "W4-1: the connection chip text '%s' is inside the app bar" % main._status_text.text)
			ok(bar.get_global_rect().position.y <= 0.5 and bar.get_global_rect().end.y <= main._content.get_global_rect().position.y + 0.5, "the app bar sits on top of the page")
			var acts: Array = bar.action_buttons()
			ok(acts.size() == 1 and (acts[0] as Button).text == "설정", "오늘: the app bar has the 설정 action")
			ok(not bar.back_button().visible and bar.title_label().text == "오늘", "오늘: no back button, the tab name is the bar title")
		"settings":
			var tv0: SettingsView = main.views["settings"]
			ok(main.current == "settings" and bt.overflow_keys().has("settings"), "settings: the shell shows the settings screen (a 더보기 entry)")
			ok(tv0.find_children("*", "RemoteLinkPanel", true, false).size() == 1, "settings: RemoteLinkPanel is mounted on the phone")
			ok(tv0.find_children("*", "PhoneLinkPanel", true, false).is_empty(), "settings: no PhoneLinkPanel on the phone")
			ok(tv0._engine_ob == null, "settings: the AI engine section is hidden on the phone")
			var rl: Node = tv0.find_children("*", "RemoteLinkPanel", true, false)[0]
			var first_sec := ""
			for sid in tv0.section_ids():
				if first_sec == "" and tv0.section_visible(sid):
					first_sec = sid
			ok(first_sec == "connection" and tv0.section_of(rl) == "connection", "settings: the first section on the screen is 'connection' and RemoteLinkPanel sits in it")
			ok(rl.get_parent().get_index() == 0, "settings: RemoteLinkPanel is the first entry of that section")
			ok(bar.title_label().text == "설정" and not bar.back_button().visible, "settings: the bar says 설정 and has no back button (a top-level screen)")
		"lesson_home":
			ok(bar.title_label().text == "레슨" and bar.title_label().modulate.a < 0.5, "lesson home: the bar title is the tab name, faded while the big title shows")
		"talk_setup":
			ok(bar.title_label().text == "원어민 대화" and not bar.back_button().visible, "talk setup: the bar says the tab name")
		"talk_chat_en":
			var tv2: TalkView = main.views["talk"]
			ok(tv2._input.get_parent() != tv2._mic.get_parent(), "talk: the microphone has its own line under the input")
			ok(tv2._mic.get_global_rect().size.x > 300.0, "talk: the microphone button is full width")
			ok(tv2.page_title() != "" and bar.title_label().text == "" and not bar.back_button().visible and bar.action_buttons().is_empty(), "talk chat: the chat draws its own title / end button, so the bar adds none (no double header)")
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
			ok(main._status_text.get_global_rect().position.y >= 48.0, "L-05: the app bar content starts at y >= 48 (y=%.1f)" % main._status_text.get_global_rect().position.y)
			ok(bar.top_inset() == 48.0 and bar.get_global_rect().size.y <= 56.0 + 48.0 + 0.5, "L-05: the app bar is 56 px + the 48 px inset high (%.0f)" % bar.get_global_rect().size.y)
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
			ok(bar.title_label().text == "읽기" and not bar.back_button().visible, "reading library: the bar says the tab name")
		"reading_reader_en":
			var rv2: ReadingView = main.views["reading"]
			ok(rv2.bar_hosted and bar.back_button().visible and bar.title_label().text == "Running in the Rain", "reading reader: the bar shows the back button and the text title ('%s')" % bar.title_label().text)
			ok(bar.action_buttons().size() == 1 and (bar.action_buttons()[0] as Button).text == "글자 크기", "reading reader: the bar has the 글자 크기 action")
		"tabs_more_sheet":
			ok(bt.is_more_open(), "tabs: the 더보기 sheet is open in this state")


func _has_button(root: Node, text: String) -> bool:
	var all: Array = []
	_controls(root, all)
	for c in all:
		if c is Button and (c as Button).text == text and (c as Control).is_visible_in_tree():
			return true
	return false


# ---------------------------------------------------------------- PC (W4-2)

func _pc_state_checks(state: String, main: Control) -> void:
	match state:
		"settings":
			var tv0: SettingsView = main.views["settings"]
			ok(main.current == "settings" and main._side_nav.current() == "settings", "L-06: the settings screen is the selected side-nav item")
			ok(tv0.find_children("*", "PhoneLinkPanel", true, false).size() == 1, "L-06: PhoneLinkPanel is mounted in the PC settings")
			ok(tv0.find_children("*", "RemoteLinkPanel", true, false).is_empty(), "L-06: no RemoteLinkPanel on the PC")
			ok(tv0._engine_ob != null, "L-06: the AI engine section is still in the PC settings")
			var pl: Control = tv0.find_children("*", "PhoneLinkPanel", true, false)[0]
			var ids: Array = tv0.section_ids()
			ok(tv0.section_of(pl) == "connection" and tv0.section_of(tv0._engine_ob) == "engine", "L-06: PhoneLinkPanel is in the 'connection' section and the AI engine dropdown in the 'engine' section")
			ok(ids.find("connection") < ids.find("engine") and tv0.section_visible("connection") and tv0.section_visible("engine"), "L-06: both sections show, the phone link above the AI engine")
			# (a column is as wide as its content needs: with a text size above 100 % the settings rows may need more)
			ok(Ds.font_scale > 1.0 or tv0._scroll.content.get_global_rect().size.x <= 720.5, "W4-2: the settings column is at most 720 px wide (%.0f)" % tv0._scroll.content.get_global_rect().size.x)
		"today":
			var tv: TodayView = main.views["today"]
			var nav: SideNav = main._side_nav
			ok(tv._grid.columns == 2, "W4-2: today cards are two columns at 1280 (the side nav included)")
			ok(main._bottom_tabs == null and main._app_bar == null, "W4-2: no bottom tab bar and no app bar on the PC")
			ok(nav != null and nav.size.x >= 223.0 and nav.size.x <= 225.0, "W4-2: the side nav is 224 px wide (%.1f)" % nav.size.x)
			ok(nav.get_global_rect().position.x <= 0.5 and nav.get_global_rect().end.y >= get_viewport().get_visible_rect().size.y - 0.5, "W4-2: the side nav fills the left edge, top to bottom")
			ok(main._content.get_global_rect().position.y <= 0.5 and main._content.get_global_rect().position.x >= nav.get_global_rect().end.x - 0.5, "W4-2: no tab row on top: the page starts at the top edge, right of the side nav")
			ok(tv._scroll.content.get_global_rect().size.x <= 880.5, "W4-2: the content column is at most 880 px wide (%.0f)" % tv._scroll.content.get_global_rect().size.x)
			ok(not main._link_chip.visible, "L-06: '폰 연결 켜짐' hidden by default")
			ok(main._status_text.text != "" and nav.get_global_rect().encloses(main._status_text.get_global_rect()), "W4-2: the engine chip '%s' is inside the side nav" % main._status_text.text)
			ok(nav.current() == "today" and nav.item_buttons().has("settings") and (nav.item_buttons()["settings"] as Control).is_visible_in_tree(), "W4-2: 오늘 is selected and the 설정 item is shown")
		"roadmap":
			var rm: RoadmapView = main.views["roadmap"]
			ok(rm._scroll.content.get_global_rect().size.x <= 880.5, "W4-2: the roadmap column is at most 880 px wide (%.0f)" % rm._scroll.content.get_global_rect().size.x)
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
	var all_states: bool = _only == ""
	if not all_states:
		ok(_matched >= 1, "--only=%s matched %d of the %d walked states" % [_only, _matched, _states.size()])
	ok(not all_states or _states.size() >= 30, "walked %d states" % _states.size())
	await _test_scheme(main)
	if _phone:
		ok(not all_states or _scanned > 2000, "the scan looked at %d visible controls" % _scanned)
		ok(all_states or _scanned > 0, "the scan looked at %d visible controls" % _scanned)
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
		ok(_small.size() == 0, "L-03: TOUCH_SMALL_COUNT 0 (touch min %s)" % _touch_min)
		ok(_bad_text.size() == 0, "L-08: no Ctrl / 스페이스바 text on the phone")
		if all_states:
			await _test_back(main)
			await _test_tabs(main)
			_test_deadzone(main)
			await _test_chip_and_actions(main)
	elif all_states:
		await _test_pc_nav(main)
		await _test_pc_narrow(main)
		await _test_link_indicator(main)
		_test_helpers_pc()
	if all_states:
		await _test_sheet_back(main)
		await _test_toast(main)
		await _test_bad_prefs()
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
	var card := SettingsView.new()
	card.auto_panels = false
	card.embedded = true
	add_child(card)
	var panel := VBoxContainer.new()
	var other := VBoxContainer.new() # a second panel: its divider needs a visible row above it
	card.mount("sync", panel) # 'sync' holds nothing else, so the section itself shows only with a panel that has content
	card.mount("sync", other)
	ok(not panel.visible, "mount: an empty connection panel stays hidden")
	var sep: Control = other.get_parent().get_parent().get_child(other.get_parent().get_index() - 1)
	ok(not sep.visible and not card.section_visible("sync"), "mount: so do its divider and the section (nothing in it shows)")
	panel.add_child(Label.new())
	other.add_child(Label.new())
	ok(panel.visible and other.visible and sep.visible and card.section_visible("sync"), "mount: the panels, the divider and the section show up when a panel gets content")
	card.queue_free()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## W4: the connection chip and the 설정 action of the app bar open the settings screen; the chip itself reacts to a tap.
func _test_chip_and_actions(main: Control) -> void:
	main.show_view("review")
	await _frames(3)
	main._app_bar.chip_pressed.emit()
	await _frames(3)
	ok(main.current == "settings", "chip: the app bar's connection chip opens the settings screen")
	main.show_view("today")
	await _frames(3)
	var acts: Array = main._app_bar.action_buttons()
	if acts.size() == 1:
		(acts[0] as Button).pressed.emit()
	await _frames(3)
	ok(main.current == "settings", "the 설정 action of 오늘 opens the settings screen")
	# a real tap on the chip: press and release (phone: the tap counts on release)
	main.show_view("review")
	await _frames(3)
	var chip: ConnChip = main._conn_chip
	var pos: Vector2 = chip.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	chip.gui_input.emit(down)
	ok(main.current == "review", "chip: pressing alone does not open anything (phone: on release)")
	chip.gui_input.emit(up)
	await _frames(3)
	ok(main.current == "settings", "chip: a tap (press + release) opens the settings screen")
	main.show_view("today")
	await _frames(2)


## PC: the SideNav shows "폰 연결 켜짐" while the settings card (PhoneLinkPanel.last_enabled) says so.
func _test_link_indicator(main: Control) -> void:
	var was: bool = PhoneLinkPanel.last_enabled
	PhoneLinkPanel.last_enabled = true
	await _frames(3)
	ok(main._link_chip.visible and main._link_chip.is_visible_in_tree() and main._link_text.text == "폰 연결 켜짐", "link indicator: shown while last_enabled is true")
	ok(main._side_nav.get_global_rect().encloses(main._link_chip.get_global_rect()), "link indicator: the chip stays inside the side nav")
	PhoneLinkPanel.last_enabled = false
	await _frames(3)
	ok(not main._link_chip.visible, "link indicator: hidden again when it turns off")
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
	ok(main._app_bar.back_button().visible and main._app_bar.title_label().text == "Back test", "L-09: the app bar shows the reader's back button and title")
	back.call()
	ok(rv.mode == "library", "L-09: back leaves the reader for the library")
	ok(not main._app_bar.back_button().visible and main._app_bar.title_label().text == "읽기", "L-09: the bar is back to the tab name in the library")
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
	var saved_status: int = Backend.status
	Backend.status = Backend.Status.NEEDS_PAIRING
	main.call("_open_connect_view")
	ok(main.is_connect_open(), "L-09 setup: connect screen open")
	ok((main._connect_view as ConnectView).cancel_button == null, "1.1.1: opened while not connected (pairing needed): no cancel button")
	back.call()
	await _frames(2)
	ok(not main.is_connect_open(), "L-09: back closes the connect screen")
	# 1.1.1: "연결 변경" while connected shows the cancel button, and it closes the screen
	Backend.status = Backend.Status.READY
	main.call("_open_connect_view")
	await _frames(2)
	var cv: ConnectView = main._connect_view as ConnectView
	ok(main.is_connect_open() and cv.cancel_button != null, "1.1.1: opened while connected (연결 변경): cancel button shown")
	cv.cancel_button.pressed.emit()
	await _frames(3)
	ok(not main.is_connect_open(), "1.1.1: the cancel button closes the connect screen")
	Backend.status = saved_status as Backend.Status
	# other tab -> 오늘
	main.show_view("review")
	back.call()
	ok(main.current == "today", "L-09: back from another tab goes to 오늘")
	# the settings are a screen of their own: back leaves it for 오늘
	main.show_view("settings")
	back.call()
	ok(main.current == "today", "L-09: back from the settings screen goes to 오늘")
	# today: toast, then exit
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


## Tab extension point: the whole list on the phone (4 tabs in the bar, the rest in the 더보기 sheet).
func _test_tabs(main: Control) -> void:
	main.add_tab("practice", "연습", AppView.new(), "연습", "review")
	main.add_tab("stats", "기록", AppView.new(), "기록", "reading")
	var bt: BottomTabs = main._bottom_tabs
	await _frames(3)
	ok(main.tab_keys() == ["today", "lesson", "talk", "review", "practice", "reading", "stats", "roadmap", "settings"], "tabs: order after the v1.1 tabs (%s)" % [main.tab_keys()])
	ok(bt.direct_keys() == ["today", "lesson", "talk", "review"], "W4-1: direct tabs = 오늘, 레슨, 대화, 복습 (%s)" % [bt.direct_keys()])
	ok(bt.overflow_keys() == ["practice", "reading", "stats", "roadmap", "settings"], "W4-1: 더보기 = 연습, 읽기, 기록, 로드맵, 설정 (%s)" % [bt.overflow_keys()])
	var cells: Array = bt.cell_buttons()
	ok(cells.size() == 5, "tabs: bar shows 4 tabs + the 더보기 cell")
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
	ok(sheet_btns == 5 and small == 0, "tabs: sheet lists 5 tabs, each >= 56 px high (%d, %d small)" % [sheet_btns, small])
	main.handle_back()
	ok(not bt.is_more_open(), "tabs: back closes the sheet")
	bt.open_more()
	await _frames(2)
	var sheet_pick: Sheet = bt._sheet
	if sheet_pick != null and sheet_pick.buttons.has("settings"):
		(sheet_pick.buttons["settings"] as Button).pressed.emit()
	await _frames(3)
	ok(main.current == "settings" and not bt.is_more_open(), "tabs: picking 설정 in the sheet opens the settings screen")
	main.add_tab("log", "기록 2", AppView.new(), "기록 2")
	await _frames(2)
	ok(main.tab_keys().slice(-2) == ["log", "settings"] and bt.overflow_keys().back() == "settings", "tabs: a tab added without after_key goes in front of 설정")
	main.show_view("log")
	ok(main.current == "log" and bt.overflow_keys().has("log"), "tabs: an overflow tab can be shown")
	main.show_view("today")


## W4-2 (PC): the SideNav lists every tab (no 더보기 menu), selects the open one and opens a clicked one.
func _test_pc_nav(main: Control) -> void:
	var nav: SideNav = main._side_nav
	main.show_view("today")
	await _frames(3)
	var keys: Array = main.tab_keys()
	var btns: Dictionary = nav.item_buttons()
	var all_vis := true
	for k in keys:
		if not btns.has(k) or not (btns[k] as Control).is_visible_in_tree():
			all_vis = false
	ok(all_vis and btns.size() == keys.size(), "PC nav: all %d tabs are visible items (no 더보기 menu)" % keys.size())
	for k in keys:
		(btns[k] as Button).pressed.emit()
		await _frames(2)
		ok(main.current == str(k) and (main.views[k] as Control).visible and nav.current() == str(k), "PC nav: clicking '%s' opens it and selects it" % k)
	main.show_view("today")
	main.add_tab("practice", "연습", AppView.new(), "", "review")
	main.add_tab("stats", "기록", AppView.new(), "", "reading")
	main.add_tab("log", "기록 2", AppView.new())
	await _frames(3)
	btns = nav.item_buttons()
	ok(main.tab_keys() == ["today", "lesson", "talk", "review", "practice", "reading", "stats", "roadmap", "log", "settings"], "PC nav: tab order (%s)" % [main.tab_keys()])
	ok(btns.size() == 10, "PC nav: ten items in all (%d)" % btns.size())
	var ys := {}
	for k in btns.keys():
		ys[k] = (btns[k] as Control).get_global_rect().position.y
	ok(ys["today"] < ys["lesson"] and ys["lesson"] < ys["talk"] and ys["talk"] < ys["practice"] and ys["practice"] < ys["reading"] and ys["reading"] < ys["review"], "PC nav: 학습 section order 오늘, 레슨, 대화, 연습, 읽기, 복습")
	ok(ys["review"] < ys["stats"] and ys["stats"] < ys["roadmap"] and ys["roadmap"] < ys["log"] and ys["log"] < ys["settings"], "PC nav: 기록 section (기록, 로드맵, the added tab) and 설정 at the bottom")
	main.show_view("log")
	await _frames(2)
	ok(main.current == "log" and nav.current() == "log", "PC nav: an added tab opens")
	main.show_view("today")


## Controls of the given views that stick out of a window `w` px wide (as "view: path class end.x=...").
func _pc_overflow(main: Control, keys: Array, w: float) -> Array[String]:
	var bad: Array[String] = []
	for k in keys:
		main.show_view(k)
		await _frames(5)
		var all: Array = []
		_controls(main, all)
		for c in all:
			var ctl := c as Control
			if not ctl.is_visible_in_tree():
				continue
			var r: Rect2 = ctl.get_global_rect()
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				continue
			if r.end.x > w + 0.5 or r.position.x < -0.5:
				bad.append("%s: %s %s end.x=%.1f" % [k, _path_of(ctl, main), ctl.get_class(), r.end.x])
	return bad


## W4-2: at the smallest window (900x600) nothing leaves the window, the nav and the page do not overlap, the cards are
## one column; at 1280 they are two again.
func _test_pc_narrow(main: Control) -> void:
	var win: Window = get_window()
	win.min_size = Vector2i(300, 300)
	win.size = Vector2i(900, 600)
	await _frames(6)
	var bad: Array[String] = await _pc_overflow(main, ["today", "lesson", "talk", "review", "reading", "roadmap", "settings"], 900.0)
	for line in bad.slice(0, 20):
		print("  pc900 overflow  ", line)
	ok(bad.is_empty(), "W4-2: at 900x600 no control of 오늘, 레슨, 대화, 복습, 읽기, 로드맵, 설정 leaves the window (%d)" % bad.size())
	# 640 px (below the real minimum 900; only exercises how narrow a page can get): the settings screen must still fit
	win.size = Vector2i(640, 600)
	await _frames(6)
	var bad640: Array[String] = await _pc_overflow(main, ["settings"], 640.0)
	for line in bad640.slice(0, 20):
		print("  pc640 overflow  ", line)
	ok(bad640.is_empty(), "W4-2: at 640x600 no control of the settings screen leaves the window (%d)" % bad640.size())
	var others640: Array[String] = await _pc_overflow(main, ["today", "lesson", "talk", "review", "reading", "roadmap"], 640.0)
	print("PC640_OTHER_VIEWS_OVERFLOW_COUNT ", others640.size(), " (information, not asserted)")
	win.size = Vector2i(900, 600)
	await _frames(6)
	var nav: SideNav = main._side_nav
	ok(nav.get_global_rect().end.x <= main._content.get_global_rect().position.x + 0.5, "W4-2: at 900 the side nav and the page do not overlap")
	ok(nav.size.x >= 223.0 and nav.size.x <= 225.0, "W4-2: the side nav stays 224 px wide at 900 (%.1f)" % nav.size.x)
	main.show_view("today")
	await _frames(5)
	var tv: TodayView = main.views["today"]
	ok(tv._grid.columns == 1, "W4-2: at 900 the content is %.0f px wide: one column of cards" % tv.size.x)
	var cards: Array = tv._grid.get_children()
	var overlap := false
	for i in cards.size():
		for j in range(i + 1, cards.size()):
			if (cards[i] as Control).get_global_rect().intersects((cards[j] as Control).get_global_rect()):
				overlap = true
	ok(cards.size() == 2 and not overlap, "W4-2: at 900 the two language cards do not overlap")
	ok(main._status_text.get_global_rect().end.x <= nav.get_global_rect().end.x + 0.5, "W4-2: at 900 the engine chip text stays inside the side nav")
	win.size = Vector2i(1280, 800)
	await _frames(6)
	ok(tv._grid.columns == 2, "W4-2: back at 1280 the cards are two columns")


# ---------------------------------------------------------------- W4-3..W4-5 (both platforms)

## W4-3: the walk ran with the scheme that was asked for (--dark -> dark palette + dark theme file on the Window and in the
## project theme the controls read; otherwise light). The two theme files differ, so the check can tell them apart.
func _test_scheme(main: Control) -> void:
	var win: Window = get_window()
	ok(Pal.is_dark() == _dark, "W4-3: Pal.is_dark() is %s with%s --dark" % [Pal.is_dark(), "" if _dark else "out"])
	var light: Theme = ResourceLoader.load(UiBoot.LIGHT_THEME, "Theme", ResourceLoader.CACHE_MODE_IGNORE) as Theme
	var dark: Theme = ResourceLoader.load(UiBoot.DARK_THEME, "Theme", ResourceLoader.CACHE_MODE_IGNORE) as Theme
	var lc: StyleBoxFlat = light.get_stylebox("panel", "Card") as StyleBoxFlat
	var dc: StyleBoxFlat = dark.get_stylebox("panel", "Card") as StyleBoxFlat
	ok(lc != null and dc != null and lc.bg_color != dc.bg_color, "W4-3: the light and the dark theme file differ in the Card colour")
	var want: Color = dc.bg_color if _dark else lc.bg_color
	var on_win: StyleBoxFlat = win.theme.get_stylebox("panel", "Card") as StyleBoxFlat if win.theme != null else null
	ok(on_win != null and on_win.bg_color == want and want == Pal.SURFACE, "W4-3: Window.theme is the %s theme (Card %s)" % ["dark" if _dark else "light", want.to_html()])
	var on_proj: StyleBoxFlat = ThemeDB.get_project_theme().get_stylebox("panel", "Card") as StyleBoxFlat
	ok(on_proj != null and on_proj.bg_color == want, "W4-3: the project theme the controls read is the same")
	var bg := main.get_child(0) as ColorRect
	ok(bg != null and bg.color == Pal.BG, "W4-3: the page background is Pal.BG of that scheme")


## W4-4: an open sheet takes the Android back press, the screen behind it stays; two sheets need two presses.
func _test_sheet_back(main: Control) -> void:
	main.show_view("review")
	await _frames(2)
	var sh: Sheet = Sheet.confirm(main, "시험", "열려 있는 동안 뒤로 가면 시트만 닫혀요.")
	await _frames(3)
	ok(Sheet.is_open(), "W4-4 setup: a confirm sheet is open")
	main.handle_back()
	await _frames(3)
	ok(not Sheet.is_open() and sh.is_closed(), "W4-4: back closes the sheet")
	ok(main.current == "review", "W4-4: and the screen behind it stays (%s)" % main.current)
	var s1: Sheet = Sheet.confirm(main, "첫째", "하나")
	var s2: Sheet = Sheet.confirm(main, "둘째", "둘")
	await _frames(3)
	ok(Sheet.depth() == 2, "W4-4 setup: two sheets are stacked (%d)" % Sheet.depth())
	main.handle_back()
	await _frames(2)
	ok(Sheet.depth() == 1 and s2.is_closed() and not s1.is_closed() and main.current == "review", "W4-4: one back press closes only the top sheet")
	main.handle_back()
	await _frames(2)
	ok(Sheet.depth() == 0 and s1.is_closed() and main.current == "review", "W4-4: the second press closes the other one, the screen stays")
	main.handle_back()
	ok(main.current == "today", "W4-4: with no sheet open the back press works as before (to 오늘)")


## W4-5: Toast.message keeps its text and kind; the host shows it in _toast_box / _toast_label; an error is marked with "! ".
func _test_toast(main: Control) -> void:
	var got: Array = []
	var cb := func(t: String, k: String) -> void: got.append([t, k])
	Toast.message.connect(cb)
	Toast.error("시험 오류 문장")
	await _frames(2)
	Toast.message.disconnect(cb)
	ok(got == [["시험 오류 문장", "error"]], "W4-5: Toast.error sends the text unchanged with kind 'error' (%s)" % [got])
	ok(main._toast_box is PanelContainer and main._toast_box.visible and main._toast_label.text == "시험 오류 문장", "W4-5: the toast host shows it through _toast_box / _toast_label")
	ok(main._toast_host.mark.visible, "W4-5: an error toast starts with the '! ' mark (not by colour alone)")
	main._toast_box.visible = false # what shots_phone does
	ok(not main._toast_box.visible, "W4-5: _toast_box.visible can be switched off from outside")
	Toast.info("시험 안내")
	await _frames(2)
	ok(main._toast_label.text == "시험 안내" and not main._toast_host.mark.visible, "W4-5: an info toast has no mark")
	var calls: Array = [0]
	Toast.show_snack("되돌릴까요", "되돌리기", func() -> void: calls[0] += 1)
	await _frames(2)
	ok(main._toast_host.action_button.visible and main._toast_host.action_button.text == "되돌리기", "W4-5: a snack shows its action button")
	main._toast_host.action_button.pressed.emit()
	ok(calls[0] == 1, "W4-5: the action runs once")
	main._toast_box.visible = false


## W4-3 / F6: a broken saved scheme or font size never stops the app. Main is started again with bad prefs and must come up
## on 오늘 with the fallback (light / 1.0, or the closest allowed size).
func _test_bad_prefs() -> void:
	var win: Window = get_window()
	var keep_scheme: String = Pal.scheme()
	var keep_scale: float = Ds.font_scale
	var had_s: bool = Store.prefs.has("scheme")
	var had_f: bool = Store.prefs.has("font_scale")
	var old_s: Variant = Store.prefs.get("scheme")
	var old_f: Variant = Store.prefs.get("font_scale")
	var cases: Array = [
		["purple", "abc", "light", 1.0],
		["purple", 9.0, "light", 1.5],
		["dark", 1.15, "dark", 1.15],
		[7, 0.0, "light", 1.0],
		[null, -3, "light", 1.0],
	]
	for c in cases:
		win.theme = null
		Store.prefs["scheme"] = c[0]
		Store.prefs["font_scale"] = c[1]
		var m: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
		m.set("quit_on_exit", false)
		add_child(m)
		await _frames(5)
		ok(Pal.scheme() == c[2] and is_equal_approx(Ds.font_scale, float(c[3])) and m.get("current") == "today" and win.theme != null, "W4-3: prefs scheme=%s font_scale=%s start as %s / %s" % [var_to_str(c[0]), var_to_str(c[1]), Pal.scheme(), Ds.font_scale])
		m.queue_free()
		await _frames(3)
	if had_s:
		Store.prefs["scheme"] = old_s
	else:
		Store.prefs.erase("scheme")
	if had_f:
		Store.prefs["font_scale"] = old_f
	else:
		Store.prefs.erase("font_scale")
	win.theme = null
	UiBoot.apply(win, keep_scheme, keep_scale)


func _test_helpers_pc() -> void:
	ok(UI.adaptive(8) is HBoxContainer, "L-06: UI.adaptive is a row on the PC")
	var b := UI.button("x", "default")
	ok(b.custom_minimum_size.y == 0.0, "L-06: UI.button has no forced height on the PC")
	var l := UI.link_button("x", "tip")
	ok(l.custom_minimum_size == Vector2.ZERO and l.tooltip_text == "tip", "L-06: link button unchanged on the PC")
	b.free()
	l.free()
