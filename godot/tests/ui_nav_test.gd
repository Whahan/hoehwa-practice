extends Node
## Overlay and navigation parts test (docs/ui_redesign_design.md §8.4 W3, W3-1..W3-5): AppBar, PageHeader, Sheet,
## ToastHost (+ the Toast bus), SideNav, ConnChip, BottomTabs and the AppView app bar contract.
##   phone: godot --headless --path <project> res://tests/ui_nav_test.tscn -- --phone
##   PC:    godot --headless --path <project> res://tests/ui_nav_test.tscn
## Input is injected like Android does it (ScreenTouch / ScreenDrag through Input.parse_input_event).
## Last line: "== ui_nav: N passed, M failed ==", exit code 1 on any failure.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _stage: Control
var _vp: Vector2 = Vector2.ZERO


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
	print("== ui_nav test start (%s) ==" % ("phone" if _phone else "pc"))
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(2)
	_vp = get_viewport().get_visible_rect().size
	print("viewport ", _vp)
	ok(absf(_vp.x - float(want.x)) < 0.5 and absf(_vp.y - float(want.y)) < 0.5, "viewport is %dx%d" % [want.x, want.y])
	Input.emulate_touch_from_mouse = true # makes is_touchscreen_available() true, as on a phone
	UiBoot.apply(get_window(), "light", 1.0)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)
	Sheet.animate = false
	await _frames(2)

	await _test_collapse_t()
	await _test_app_bar()
	await _test_page_header()
	await _test_sheet()
	await _test_sheet_touch()
	await _test_sheet_animated()
	await _test_toast()
	await _test_conn_chip()
	await _test_side_nav()
	await _test_bottom_tabs()
	await _test_app_view()
	await _test_layers()

	print("== ui_nav: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- input

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


func _tap(pos: Vector2) -> void:
	_touch(pos, true)
	await _frames(2)
	_touch(pos, false)
	await _frames(3)


## Finger down at `from`, moves by `total` in 10 px steps, up.
func _drag(from: Vector2, total: Vector2) -> void:
	_touch(from, true)
	await _frames(2)
	var steps: int = int(ceilf(total.length() / 10.0))
	var p := from
	for i in steps:
		var rel: Vector2 = total / float(steps)
		p += rel
		_drag_ev(p, rel)
		await _frames(1)
	_touch(p, false)
	await _frames(3)


func _center(c: Control) -> Vector2:
	return c.get_global_rect().get_center()


func _clear_stage() -> void:
	for c in _stage.get_children():
		_stage.remove_child(c)
		c.queue_free()


func _close_all_sheets() -> void:
	while Sheet.close_top():
		pass


# ---------------------------------------------------------------- W3-1

func _test_collapse_t() -> void:
	ok(AppBar.collapse_t(0.0, 96.0) == 0.0, "collapse_t(0,96) == 0")
	ok(AppBar.collapse_t(48.0, 96.0) == 0.0, "collapse_t(48,96) == 0")
	ok(is_equal_approx(AppBar.collapse_t(72.0, 96.0), 0.5), "collapse_t(72,96) == 0.5")
	ok(AppBar.collapse_t(96.0, 96.0) == 1.0, "collapse_t(96,96) == 1")
	ok(AppBar.collapse_t(500.0, 96.0) == 1.0, "collapse_t(500,96) == 1")
	# wrong inputs
	ok(AppBar.collapse_t(-50.0, 96.0) == 0.0, "collapse_t(-50,96) == 0 (overscroll)")
	ok(AppBar.collapse_t(NAN, 96.0) == 0.0, "collapse_t(NAN,96) == 0")
	ok(AppBar.collapse_t(10.0, 0.0) == 1.0, "collapse_t(10,0) == 1 (no header)")
	ok(AppBar.collapse_t(10.0, NAN) == 1.0, "collapse_t(10,NAN) == 1")
	ok(AppBar.collapse_t(10.0, -5.0) == 1.0, "collapse_t(10,-5) == 1")
	ok(AppBar.collapse_t(INF, 96.0) == 1.0, "collapse_t(INF,96) == 1")
	ok(AppBar.collapse_t(-INF, 96.0) == 0.0, "collapse_t(-INF,96) == 0")
	ok(AppBar.collapse_t(10.0, INF) == 1.0, "collapse_t(10,INF) == 1")
	# the checker can fail: a wrong expected value is detected
	ok(not (AppBar.collapse_t(72.0, 96.0) == 1.0), "selfcheck: collapse_t(72,96) is not 1 (the comparison can fail)")


# ---------------------------------------------------------------- AppBar

func _test_app_bar() -> void:
	_clear_stage()
	var bar := AppBar.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_stage.add_child(bar)
	bar.set_top_inset(0.0)
	bar.set_page("오늘", false, [])
	await _frames(3)
	var h0: float = bar.get_global_rect().size.y
	ok(absf(h0 - 56.0) < 0.5, "AppBar: height 56 without an inset (%.1f)" % h0)
	bar.set_top_inset(48.0)
	await _frames(3)
	ok(absf(bar.get_global_rect().size.y - 104.0) < 0.5, "AppBar: height 56 + inset 48 = 104 (%.1f)" % bar.get_global_rect().size.y)
	bar.set_top_inset(NAN)
	await _frames(2)
	ok(absf(bar.get_global_rect().size.y - 56.0) < 0.5, "AppBar: a NaN inset counts as 0")
	bar.set_top_inset(0.0)
	ok(not bar.back_button().visible, "AppBar: no back button on a top screen")
	bar.set_page("연습", true, [{"id": "a", "text": "설정"}, {"id": "b", "text": "더보기"}, {"id": "c", "text": "취소"}])
	await _frames(3)
	ok(bar.back_button().visible, "AppBar: back button shown for a sub screen")
	ok(bar.action_buttons().size() == 2, "AppBar: at most 2 actions (got %d of 3)" % bar.action_buttons().size())
	var small := 0
	for b in bar.action_buttons() + [bar.back_button()]:
		var r: Rect2 = (b as Control).get_global_rect()
		if r.size.x < Ds.touch_min() - 0.5 or r.size.y < Ds.touch_min() - 0.5:
			small += 1
	ok(small == 0, "AppBar: back and action buttons are touch size (%.0f px)" % Ds.touch_min())
	var got := {"back": 0, "act": [], "chip": 0}
	bar.back_pressed.connect(func() -> void: got["back"] += 1)
	bar.action_pressed.connect(func(id: String) -> void: (got["act"] as Array).append(id))
	bar.chip_pressed.connect(func() -> void: got["chip"] += 1)
	var chip := ConnChip.new()
	chip.set_state("ok", "PC 연결됨")
	bar.set_chip(chip)
	await _frames(3)
	await _tap(_center(bar.back_button()))
	ok(got["back"] == 1, "AppBar: tapping the back button sends back_pressed once (%d)" % got["back"])
	await _tap(_center(bar.action_buttons()[0] as Control))
	await _tap(_center(bar.action_buttons()[1] as Control))
	ok((got["act"] as Array) == ["a", "b"], "AppBar: action ids come through in order (%s)" % [got["act"]])
	await _tap(_center(chip))
	ok(got["chip"] == 1, "AppBar: tapping the chip sends chip_pressed once (%d)" % got["chip"])
	ok(bar.get_global_rect().encloses(chip.get_global_rect()), "AppBar: the chip sits inside the bar")
	# a drag that starts on the chip is not a tap (phone rule)
	if _phone:
		await _drag(_center(chip), Vector2(0, -60))
		ok(got["chip"] == 1, "AppBar: a drag over the chip does not tap it (%d)" % got["chip"])
	# a bar that is replaced
	var chip2 := ConnChip.new()
	chip2.set_state("bad", "연결 안 됨")
	bar.set_chip(chip2)
	await _frames(2)
	ok(chip.get_parent() == null and chip2.get_parent() != null, "AppBar: set_chip replaces the old chip")
	chip.free()
	bar.set_chip(null)
	ok(true, "AppBar: set_chip(null) does not fail")

	# scroll binding: a page of 1200 px under a header of 96 px
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(300, 400)
	sc.size = Vector2(300, 400)
	var col := VBoxContainer.new()
	var header := Control.new()
	header.custom_minimum_size = Vector2(300, 96)
	col.add_child(header)
	var tall := Control.new()
	tall.custom_minimum_size = Vector2(300, 1200)
	col.add_child(tall)
	sc.add_child(col)
	sc.position = Vector2(0, 200)
	_stage.add_child(sc)
	await _frames(3)
	bar.set_page("레슨", false, [])
	bar.bind_scroll(sc, header)
	ok(is_equal_approx(bar.title_alpha(), 0.0) and bar.line_alpha() == 0.0, "AppBar bound: scroll 0 -> title alpha 0, no hairline")
	sc.scroll_vertical = 60
	await _frames(2)
	ok(is_equal_approx(bar.title_alpha(), AppBar.collapse_t(60.0, 96.0)) and bar.title_alpha() > 0.0 and bar.title_alpha() < 1.0, "AppBar bound: scroll 60 -> partly visible title (%.2f)" % bar.title_alpha())
	ok(bar.line_alpha() == 1.0, "AppBar bound: hairline is on once the page scrolled")
	sc.scroll_vertical = 300
	await _frames(2)
	ok(bar.title_alpha() == 1.0, "AppBar bound: scroll 300 -> title fully visible")
	sc.scroll_vertical = 0
	await _frames(2)
	ok(bar.title_alpha() == 0.0 and bar.line_alpha() == 0.0, "AppBar bound: back at the top -> title hidden again, no hairline")
	bar.bind_scroll(null, null)
	ok(bar.title_alpha() == 1.0, "AppBar: without a scroll host the title is always visible")
	sc.free()
	bar.bind_scroll(sc if false else null, null)
	# a scroll host that is freed later
	var sc2 := ScrollContainer.new()
	_stage.add_child(sc2)
	bar.bind_scroll(sc2, null)
	sc2.free()
	bar.set_page("x", false, [])
	bar.bind_scroll(null, null)
	ok(true, "AppBar: a freed scroll host does not break the next call")
	_clear_stage()


# ---------------------------------------------------------------- PageHeader

func _test_page_header() -> void:
	_clear_stage()
	var cb_count := {"n": 0}
	var hdr: Control = PageHeader.build("오늘", "2단계 · 5개월차 2주차", [{"id": "go", "text": "설정", "cb": func() -> void: cb_count["n"] += 1}])
	var holder := VBoxContainer.new()
	holder.custom_minimum_size.x = 380
	holder.size = Vector2(380, 300)
	holder.add_child(hdr)
	_stage.add_child(holder)
	await _frames(3)
	var want_h: float = 112.0 if _phone else 72.0
	ok(PageHeader.height() == want_h, "PageHeader.height() == %d" % int(want_h))
	ok(hdr.get_global_rect().size.y >= want_h - 0.5, "PageHeader: block at least %d px high (%.0f)" % [int(want_h), hdr.get_global_rect().size.y])
	var buttons: Array = hdr.find_children("*", "BaseButton", true, false)
	if _phone:
		ok(buttons.is_empty(), "PageHeader (phone): no tappable part")
		var bad := 0
		var all: Array = hdr.find_children("*", "Control", true, false) + [hdr]
		for c in all:
			if (c as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
				bad += 1
		ok(bad == 0, "PageHeader (phone): nothing stops the mouse (a drag from the title scrolls), stoppers=%d" % bad)
		var tl := hdr.get_meta("title_label") as Label
		ok(tl.theme_type_variation == &"LargeTitle", "PageHeader (phone): LargeTitle variation")
	else:
		ok(buttons.size() == 1, "PageHeader (pc): one action button")
		if buttons.size() == 1:
			(buttons[0] as Button).pressed.emit()
			ok(cb_count["n"] == 1, "PageHeader (pc): the action callback runs once")
		ok(hdr.has_meta("action_buttons") and (hdr.get_meta("action_buttons") as Dictionary).has("go"), "PageHeader (pc): action_buttons meta by id")
	# a long title is cut to two lines (phone)
	var long_hdr: Control = PageHeader.build("아주 긴 제목 ".repeat(30), "")
	holder.add_child(long_hdr)
	await _frames(3)
	if _phone:
		var lt := long_hdr.get_meta("title_label") as Label
		ok(lt.get_visible_line_count() <= 2, "PageHeader (phone): a long title shows at most 2 lines (%d)" % lt.get_visible_line_count())
	else:
		ok(long_hdr.get_global_rect().size.y <= 100.0, "PageHeader (pc): a long title stays one line (%.0f px)" % long_hdr.get_global_rect().size.y)
	var empty_hdr: Control = PageHeader.build("", "", [{"nope": 1}, 5, {"id": "x", "text": ""}])
	holder.add_child(empty_hdr)
	await _frames(2)
	ok(is_instance_valid(empty_hdr), "PageHeader: empty title and broken actions do not fail")
	_clear_stage()


# ---------------------------------------------------------------- Sheet (W3-2)

func _test_sheet() -> void:
	_clear_stage()
	Sheet.animate = false
	var results: Array = []
	var s := Sheet.confirm(_stage, "기록 지우기", "이 기록을 지울까요?", "확인", true)
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	ok(Sheet.is_open(), "Sheet.confirm opens: Sheet.is_open()")
	ok(s.layer_node != null and s.layer_node.layer == 16, "Sheet: on CanvasLayer 16")
	var pr: Rect2 = s.panel.get_global_rect()
	ok(pr.end.y <= _vp.y + 0.5 and pr.position.y >= -0.5, "Sheet: panel inside the screen (y %.0f..%.0f of %.0f)" % [pr.position.y, pr.end.y, _vp.y])
	if _phone:
		ok(s.mode == "bottom" and absf(pr.end.y - _vp.y) < 1.5 and absf(pr.size.x - _vp.x) < 1.5, "Sheet (phone): sits on the bottom edge, full width")
		var sb: StyleBoxFlat = s.panel.get_theme_stylebox("panel") as StyleBoxFlat
		ok(sb != null and sb.corner_radius_top_left == Ds.R_SHEET and sb.corner_radius_bottom_left == 0, "Sheet (phone): top corners radius 28")
		ok(s.buttons["ok"].get_global_rect().position.y < s.buttons["cancel"].get_global_rect().position.y, "Sheet (phone): the answer is above the cancel button")
		ok(s.buttons["ok"].get_global_rect().size.y >= 55.5 and s.buttons["ok"].get_global_rect().size.x > 300.0, "Sheet (phone): buttons full width, 56 px high")
	else:
		ok(s.mode == "center" and absf(pr.size.x - 440.0) < 1.5, "Sheet (pc): centred dialog 440 px wide (%.0f)" % pr.size.x)
		ok(absf(pr.get_center().x - _vp.x * 0.5) < 1.5 and absf(pr.get_center().y - _vp.y * 0.5) < 1.5, "Sheet (pc): in the middle of the window")
		ok(s.buttons["cancel"].get_global_rect().end.x < s.buttons["ok"].get_global_rect().position.x + 0.5, "Sheet (pc): the answer is the rightmost button")
	ok(Sheet.close_top(), "Sheet.close_top() closes the open sheet and returns true")
	ok(not Sheet.close_top(), "Sheet.close_top() again returns false")
	ok(not Sheet.is_open(), "Sheet.is_open() is false after closing")
	ok(results == ["dismiss"], "Sheet: close_top() sends closed(\"dismiss\") once (%s)" % [results])
	await _frames(3)

	# buttons
	results.clear()
	s = Sheet.confirm(_stage, "t", "m")
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	await _tap(_center(s.buttons["ok"]))
	ok(results == ["ok"], "Sheet: tapping the answer sends closed(\"ok\") (%s)" % [results])
	ok(not Sheet.is_open(), "Sheet: closed by the answer")
	await _frames(2)
	results.clear()
	s = Sheet.confirm(_stage, "t", "m")
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	await _tap(_center(s.buttons["cancel"]))
	ok(results == ["cancel"], "Sheet: tapping cancel sends closed(\"cancel\") (%s)" % [results])
	await _frames(2)

	# the dim
	results.clear()
	s = Sheet.confirm(_stage, "t", "m")
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	await _tap(Vector2(6, 6))
	ok(results == ["dismiss"], "Sheet: tapping the dim sends closed(\"dismiss\") (%s)" % [results])
	await _frames(2)
	# not dismissable
	results.clear()
	s = Sheet.open(_stage, "진행", UI.label("잠시만요"), [], {"dismissable": false, "mode": "center"})
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	await _tap(Vector2(6, 6))
	ok(results.is_empty() and Sheet.is_open(), "Sheet: dismissable=false -> a dim tap does not close it")
	ok(Sheet.handle_back() and Sheet.is_open(), "Sheet: back press on a non-dismissable sheet is swallowed")
	ok(s.mode == "center", "Sheet: opts.mode = center is respected")
	ok(Sheet.close_top("done") and results == ["done"], "Sheet: close_top(result) closes it anyway with that result")
	await _frames(2)
	# the back button on a normal sheet
	results.clear()
	s = Sheet.confirm(_stage, "t", "m")
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(4)
	ok(Sheet.handle_back() and results == ["dismiss"] and not Sheet.is_open(), "Sheet.handle_back() closes a normal sheet")
	ok(not Sheet.handle_back(), "Sheet.handle_back() is false when nothing is open")
	await _frames(2)

	# keyboard
	PhoneLayout.test_keyboard_height = 300.0
	s = Sheet.confirm(_stage, "t", "m")
	await _frames(8)
	var kb_end: float = s.panel.get_global_rect().end.y
	ok(kb_end <= _vp.y - 300.0 + 0.5, "Sheet: with a 300 px keyboard the panel ends at %.0f <= %.0f" % [kb_end, _vp.y - 300.0])
	PhoneLayout.test_keyboard_height = 0.0
	await _frames(8)
	ok(s.panel.get_global_rect().end.y > kb_end + 100.0, "Sheet: the panel comes back down when the keyboard closes")
	PhoneLayout.test_keyboard_height = -1.0
	# a long body keeps within 70 % and scrolls
	_close_all_sheets()
	await _frames(2)
	var long_text: String = "아주 긴 안내문입니다. ".repeat(120)
	s = Sheet.confirm(_stage, "긴 글", long_text)
	await _frames(8)
	var lh: float = s.panel.get_global_rect().size.y
	ok(lh <= _vp.y * 0.7 + 1.0, "Sheet: a long body is held to 70 %% of the screen (%.0f <= %.0f)" % [lh, _vp.y * 0.7])
	var sc: ScrollContainer = s.find_children("*", "ScrollContainer", true, false)[0]
	ok(sc.get_v_scroll_bar().max_value > sc.get_v_scroll_bar().page + 1.0, "Sheet: the long body scrolls")
	var big := Sheet.open(_stage, "x", UI.label("y"), [], {"max_h_frac": 5.0})
	await _frames(4)
	ok(big.max_h_frac <= 0.95, "Sheet: an absurd max_h_frac is clamped (%.2f)" % big.max_h_frac)
	_close_all_sheets()
	await _frames(2)

	# stack
	var r1: Array = []
	var r2: Array = []
	var a := Sheet.confirm(_stage, "a", "1")
	var b := Sheet.confirm(_stage, "b", "2")
	a.closed.connect(func(r: Variant) -> void: r1.append(r))
	b.closed.connect(func(r: Variant) -> void: r2.append(r))
	await _frames(6)
	ok(Sheet.depth() == 2, "Sheet: two opens on the same host make a stack of 2 (%d)" % Sheet.depth())
	ok(b.layer_node.layer > a.layer_node.layer, "Sheet: the newer sheet is on a higher layer (%d > %d)" % [b.layer_node.layer, a.layer_node.layer])
	ok(Sheet.close_top() and r2 == ["dismiss"] and r1.is_empty(), "Sheet: close_top closes only the newest")
	ok(Sheet.close_top() and r1 == ["dismiss"], "Sheet: the second close_top closes the older one")
	ok(not Sheet.close_top() and not Sheet.is_open(), "Sheet: both closed, nothing left")
	await _frames(2)

	# odd input
	var e1_closed := {"v": false}
	var e1 := Sheet.open(_stage, "", null, [], {})
	e1.closed.connect(func(_r: Variant) -> void: e1_closed["v"] = true)
	var e2 := Sheet.open(_stage, "제목만", null, [{"id": "x"}, 5, {"text": ""}, {"id": "ok", "text": "알겠어요"}])
	await _frames(6)
	ok(Sheet.depth() == 2 and e2.buttons.size() == 1, "Sheet: no buttons / null body / broken button entries do not fail (buttons=%d)" % e2.buttons.size())
	_close_all_sheets()
	var e3 := Sheet.open(null, "no host", UI.label("x"))
	await _frames(4)
	ok(e3.is_inside_tree(), "Sheet: a null host falls back to the tree root")
	_close_all_sheets()
	await _frames(3)
	ok(e1_closed["v"], "Sheet: odd inputs survive and close")

	# choice
	results.clear()
	var ch := Sheet.choice(_stage, "시간", [["10", "10분"], ["15", "15분"], ["20", "20분"]], "15")
	ch.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(6)
	var rows: Array = ch.find_children("*", "Button", true, false)
	ok(rows.size() == 3, "Sheet.choice: three rows (%d)" % rows.size())
	var short_rows := 0
	for r in rows:
		var rr: Rect2 = (r as Control).get_global_rect()
		if rr.size.y < (55.5 if _phone else 47.5):
			short_rows += 1
	ok(short_rows == 0, "Sheet.choice: every row is at least %d px high" % (56 if _phone else 48))
	ok(ch.buttons["15"].find_children("*", "GlyphIcon", true, false).size() == 1 and ch.buttons["10"].find_children("*", "GlyphIcon", true, false).is_empty(), "Sheet.choice: only the current row has the check mark")
	await _tap(_center(ch.buttons["20"]))
	ok(results == ["20"], "Sheet.choice: tapping a row sends its value (%s)" % [results])
	await _frames(2)
	ok(not Sheet.is_open(), "Sheet.choice: closed after the pick")
	var ch2 := Sheet.choice(_stage, "leer", [], "")
	await _frames(4)
	ok(Sheet.is_open(), "Sheet.choice: an empty list still opens")
	_close_all_sheets()
	await _frames(3)
	_clear_stage()


## Phone: a drag that starts on the dim, the body or a button does not close / answer anything and the body scrolls.
func _test_sheet_touch() -> void:
	if not _phone:
		return
	Sheet.animate = false
	var results: Array = []
	var s := Sheet.confirm(_stage, "긴 글", "아주 긴 안내문입니다. ".repeat(120), "확인")
	s.closed.connect(func(r: Variant) -> void: results.append(r))
	await _frames(8)
	var sc: ScrollContainer = s.find_children("*", "ScrollContainer", true, false)[0]
	var body_pos: Vector2 = _center(sc)
	var v0: int = sc.scroll_vertical
	await _drag(body_pos, Vector2(0, -200))
	ok(sc.scroll_vertical - v0 >= 150, "Sheet (touch): dragging the body text scrolls it (%d px)" % (sc.scroll_vertical - v0))
	ok(results.is_empty(), "Sheet (touch): that drag closed nothing")
	await _drag(Vector2(200, 100), Vector2(0, 80))
	ok(results.is_empty() and Sheet.is_open(), "Sheet (touch): a drag that starts on the dim does not dismiss")
	var ok_btn: Button = s.buttons["ok"]
	await _drag(_center(ok_btn), Vector2(0, -80))
	ok(results.is_empty(), "Sheet (touch): a drag that starts on the answer button does not press it")
	await _tap(Vector2(200, 100))
	ok(results == ["dismiss"], "Sheet (touch): a tap on the dim dismisses")
	await _frames(3)
	_clear_stage()


func _test_sheet_animated() -> void:
	Sheet.animate = true
	var s := Sheet.confirm(_stage, "움직임", "열고 닫는 움직임")
	await _frames(4)
	var timer := get_tree().create_timer(0.7)
	await timer.timeout
	var pr: Rect2 = s.panel.get_global_rect()
	ok(pr.end.y <= _vp.y + 0.5, "Sheet (animated): at rest inside the screen after 0.7 s (end %.1f of %.0f)" % [pr.end.y, _vp.y])
	if _phone:
		ok(absf(pr.end.y - _vp.y) < 1.5, "Sheet (animated, phone): at rest on the bottom edge")
	ok(absf(s.dim.modulate.a - 1.0) < 0.01, "Sheet (animated): the dim is fully there")
	var layer: CanvasLayer = s.layer_node
	Sheet.close_top()
	ok(not Sheet.is_open() and is_instance_valid(layer), "Sheet (animated): is_open() is false at once, the layer lives for the fade")
	await get_tree().create_timer(0.5).timeout
	await _frames(2)
	ok(not is_instance_valid(layer), "Sheet (animated): the layer is freed after the fade out")
	Sheet.animate = false
	_clear_stage()


# ---------------------------------------------------------------- ToastHost (W3-3)

func _test_toast() -> void:
	_clear_stage()
	var host := ToastHost.new()
	add_child(host)
	await _frames(3)
	ok(host.layer == 30, "ToastHost: layer 30")
	ok(not host.box.visible, "ToastHost: hidden until the first message")
	host.show_message("가".repeat(500), "info")
	await _frames(5)
	var lines: int = host.label.get_visible_line_count()
	ok(lines <= 3 and lines >= 1, "ToastHost: a 500-character message shows %d lines (<= 3)" % lines)
	ok(host.shown_lines() == lines, "ToastHost.shown_lines() matches the label")
	var bw: float = host.box.get_global_rect().size.x
	if _phone:
		ok(bw <= _vp.x - 32.0 + 1.0 and bw >= 200.0, "ToastHost (phone): box width %.0f is screen - 32 at most" % bw)
	else:
		ok(bw <= 420.5, "ToastHost (pc): box width %.0f <= 420" % bw)
	ok(host.box.get_global_rect().size.y < 140.0, "ToastHost: the box is not taller than 3 lines (%.0f px)" % host.box.get_global_rect().size.y)
	var spaced: String = "word ".repeat(300)
	host.show_message(spaced, "info")
	await _frames(5)
	ok(host.label.get_visible_line_count() <= 3, "ToastHost: a long text with spaces is also held to 3 lines")
	host.show_message("ab", "info")
	await _frames(4)
	ok(host.label.get_visible_line_count() == 1 and not host.mark.visible, "ToastHost: a short info message is one line without a mark")
	ok(host.box.mouse_filter == Control.MOUSE_FILTER_IGNORE and host.label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "ToastHost: the toast ignores the mouse")
	ok(not host.action_button.visible, "ToastHost: no action button without an action")

	# the Toast bus and the unchanged signal text
	host.bind_toast_bus()
	host.bind_toast_bus() # twice: still one connection
	var seen: Array = []
	var on_msg := func(t: String, k: String) -> void: seen.append([t, k])
	Toast.message.connect(on_msg)
	Toast.error("x")
	await _frames(4)
	ok(seen == [["x", "error"]], "Toast.error(\"x\") still sends message(\"x\", \"error\") (%s)" % [seen])
	ok(host.label.text == "x" and host.mark.visible and host.mark.text == "! ", "ToastHost: an error shows a bold \"! \" in front, the text is unchanged")
	ok(host.kind == "error", "ToastHost: kind error")
	Toast.ok("done")
	await _frames(3)
	ok(host.kind == "ok" and not host.mark.visible and host.label.text == "done", "ToastHost: ok message, no mark")
	Toast.info("hi")
	await _frames(3)
	ok(host.kind == "info" and host.label.text == "hi", "ToastHost: info message")
	var n_before: int = seen.size()
	host.show_message("weird", "purple")
	ok(host.kind == "info", "ToastHost: an unknown kind is shown as info")
	Toast.message.disconnect(on_msg)

	# the box colours differ by kind and the error does not rely on colour alone
	host.show_message("e", "error")
	var err_bg: Color = (host.box.get_theme_stylebox("panel") as StyleBoxFlat).bg_color
	host.show_message("o", "ok")
	var ok_bg: Color = (host.box.get_theme_stylebox("panel") as StyleBoxFlat).bg_color
	host.show_message("i", "info")
	var info_bg: Color = (host.box.get_theme_stylebox("panel") as StyleBoxFlat).bg_color
	ok(err_bg.is_equal_approx(Pal.TOAST_ERR) and ok_bg.is_equal_approx(Pal.TOAST_OK) and info_bg.is_equal_approx(Pal.TOAST_BG), "ToastHost: backgrounds are the Pal toast tokens")

	# snack with an action
	var calls := {"n": 0}
	host.show_message("지웠어요", "info", "되돌리기", func() -> void: calls["n"] += 1)
	await _frames(5)
	ok(host.action_button.visible and host.action_button.text == "되돌리기", "ToastHost: a snack shows its action button")
	var ar: Rect2 = host.action_button.get_global_rect()
	ok(ar.size.x >= Ds.touch_min() - 0.5 and ar.size.y >= Ds.touch_min() - 0.5, "ToastHost: the action button is touch size")
	host.action_button.pressed.emit()
	ok(calls["n"] == 1, "ToastHost: pressing the action runs the callback once (%d)" % calls["n"])
	ok(not host.box.visible, "ToastHost: the toast goes away after the action")
	host.action_button.pressed.emit()
	ok(calls["n"] == 1, "ToastHost: a second press does not run it again")
	# a real tap on the action button
	host.show_message("지웠어요", "info", "되돌리기", func() -> void: calls["n"] += 1)
	await _frames(6)
	await _tap(_center(host.action_button))
	ok(calls["n"] == 2, "ToastHost: a tap on the action button runs the callback (%d)" % calls["n"])

	# Toast.snack
	ok(Toast.has_signal("snack"), "Toast has the snack signal")
	ok(Toast.has_method("show_snack"), "Toast.show_snack exists (the signal name snack is taken)")
	var snack_calls := {"n": 0}
	var msgs: Array = []
	var m2 := func(t: String, k: String) -> void: msgs.append([t, k])
	Toast.message.connect(m2)
	Toast.show_snack("지웠어요", "되돌리기", func() -> void: snack_calls["n"] += 1)
	await _frames(4)
	ok(host.action_button.visible and host.label.text == "지웠어요", "Toast.show_snack reaches the host as a snack bar")
	ok(msgs.is_empty(), "Toast.show_snack with a host does not also send message()")
	host.action_button.pressed.emit()
	ok(snack_calls["n"] == 1, "Toast.show_snack: the action runs once")
	host.queue_free()
	await _frames(3)
	# nobody listens to snack any more -> the text falls back to a normal info message
	Toast.show_snack("fallback", "x")
	ok(msgs == [["fallback", "info"]], "Toast.show_snack without a listener falls back to message(info) (%s)" % [msgs])
	Toast.message.disconnect(m2)
	ok(n_before >= 1, "Toast: subscribers kept working (%d messages seen)" % n_before)

	# the gap
	var h2 := ToastHost.new()
	add_child(h2)
	h2.set_bottom_gap(100.0)
	h2.show_message("gap", "info")
	await _frames(6)
	ok(absf(h2.box.get_global_rect().end.y - (_vp.y - 100.0)) < 1.5, "ToastHost: set_bottom_gap(100) puts the box 100 px above the bottom (%.1f)" % (_vp.y - h2.box.get_global_rect().end.y))
	h2.set_bottom_gap(NAN)
	ok(h2.bottom_gap() == 28.0, "ToastHost: set_bottom_gap(NaN) -> 28")
	h2.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- ConnChip (W3-4)

func _test_conn_chip() -> void:
	_clear_stage()
	var holder := HBoxContainer.new()
	holder.position = Vector2(20, 300)
	_stage.add_child(holder)
	var chip := ConnChip.new()
	holder.add_child(chip)
	var count := {"n": 0}
	chip.tapped.connect(func() -> void: count["n"] += 1)
	chip.set_state("ok", "PC 연결됨")
	await _frames(4)
	ok(chip.label.visible and chip.label.text == "PC 연결됨", "ConnChip: the text is shown (label.visible and text != \"\")")
	ok(chip.kind == "ok", "ConnChip: kind ok")
	var cols := {}
	for k in ["ok", "warn", "bad", "idle"]:
		chip.set_state(k, "상태 " + k)
		cols[k] = ((chip.dot.get_theme_stylebox("panel") as StyleBoxFlat).bg_color)
		ok(chip.label.visible and chip.label.text == "상태 " + k, "ConnChip: kind %s keeps the text visible" % k)
	ok(cols["ok"] != cols["bad"] and cols["bad"] != cols["warn"] and cols["ok"] != cols["warn"] and cols["idle"] != cols["ok"], "ConnChip: the four dots have different colours")
	chip.set_state("zzz", "모름")
	ok(chip.kind == "idle" and chip.label.text == "모름" and chip.label.visible, "ConnChip: an unknown kind is idle, text still shown")
	chip.set_state("ok", "")
	ok(chip.kind == "ok", "ConnChip: empty text does not fail")
	chip.set_state("ok", "PC 연결됨")
	await _frames(3)
	var r: Rect2 = chip.get_global_rect()
	ok(r.size.y >= Ds.touch_min() - 0.5, "ConnChip: tap area at least %.0f px high (%.0f)" % [Ds.touch_min(), r.size.y])
	ok(chip.dot.get_global_rect().size.x >= 7.5 and chip.dot.get_global_rect().size.x <= 8.5, "ConnChip: dot is 8 px")
	await _tap(_center(chip))
	ok(count["n"] == 1, "ConnChip: a tap sends tapped once (%d)" % count["n"])
	if _phone:
		await _drag(_center(chip), Vector2(0, -80))
		ok(count["n"] == 1, "ConnChip (phone): a drag that starts on it does not tap (%d)" % count["n"])
	# a long text is cut
	chip.set_state("warn", "아주 아주 긴 연결 상태 문구가 들어와도 칩이 화면을 밀어내지 않아야 해요")
	await _frames(3)
	ok(chip.get_global_rect().size.x <= chip.max_text_width + 60.0, "ConnChip: a long text is cut to ~%.0f px (chip %.0f)" % [chip.max_text_width, chip.get_global_rect().size.x])
	_clear_stage()


# ---------------------------------------------------------------- SideNav (W3-4)

func _test_side_nav() -> void:
	_clear_stage()
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(row)
	var nav := SideNav.new()
	row.add_child(nav)
	var rest := Control.new()
	rest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(rest)
	nav.set_items([
		{"title": "학습", "items": [["today", "오늘"], ["lesson", "레슨"], ["talk", "원어민 대화"], ["practice", "연습"], ["reading", "읽기"], ["review", "복습"]]},
		{"title": "기록", "items": [["log", "기록"], ["roadmap", "로드맵"]]},
	])
	nav.set_current("today")
	await _frames(4)
	var nr: Rect2 = nav.get_global_rect()
	ok(nr.size.x >= 223.0 and nr.size.x <= 225.0, "SideNav: width 223..225 (%.1f)" % nr.size.x)
	var items: Dictionary = nav.item_buttons()
	ok(items.size() == 9 or items.size() == 8, "SideNav: 8 items (+ the hidden settings item) (%d)" % items.size())
	var low := 0
	for k in items.keys():
		if k == "settings":
			continue
		if (items[k] as Control).get_global_rect().size.y < 43.5:
			low += 1
	ok(low == 0, "SideNav: every item is at least 44 px high")
	ok(not (items["settings"] as Control).visible, "SideNav: the settings item is hidden by default")

	var chosen: Array = []
	nav.item_selected.connect(func(k: String) -> void: chosen.append(k))
	nav.set_current("lesson")
	ok(_selected_count(nav) == 1 and _is_selected(nav, "lesson"), "SideNav: set_current(lesson) lights exactly one item")
	nav.set_current("review")
	ok(_selected_count(nav) == 1 and _is_selected(nav, "review") and not _is_selected(nav, "lesson"), "SideNav: set_current(review) moves the look")
	nav.set_current("nope")
	ok(_selected_count(nav) == 0, "SideNav: an unknown key lights nothing, no error")
	nav.set_current("talk")
	# selected look: three cues
	var b: Button = items["talk"]
	ok((b.get_theme_stylebox("normal") as StyleBoxFlat).bg_color.is_equal_approx(Pal.PRIMARY_SOFT) and b.get_theme_color("font_color").is_equal_approx(Pal.PRIMARY) and b.has_theme_font_override("font"), "SideNav: selected = PRIMARY_SOFT fill + PRIMARY text + bold")
	await _tap(_center(items["reading"] as Control))
	ok(chosen == ["reading"], "SideNav: a click sends item_selected(reading) once (%s)" % [chosen])
	ok(nav.current() == "talk", "SideNav: a click alone does not change the current item (the shell does)")
	nav.set_settings_visible(true)
	await _frames(3)
	ok((items["settings"] as Control).visible, "SideNav: set_settings_visible(true) shows it")
	await _tap(_center(items["settings"] as Control))
	ok(chosen == ["reading", "settings"], "SideNav: the settings item sends item_selected(settings)")
	nav.set_current("settings")
	ok(_selected_count(nav) == 1 and _is_selected(nav, "settings"), "SideNav: settings can be the current item")
	var chip := ConnChip.new()
	chip.set_state("ok", "AI 엔진 준비됨")
	nav.set_footer(chip)
	await _frames(3)
	ok(nav.is_ancestor_of(chip) and chip.get_global_rect().position.y > (items["roadmap"] as Control).get_global_rect().position.y, "SideNav: the footer control sits below the list")
	var chip2 := ConnChip.new()
	nav.set_footer(chip2)
	ok(chip.get_parent() == null and nav.is_ancestor_of(chip2), "SideNav: set_footer replaces the footer")
	chip.free()
	# items set again keep a single selection
	nav.set_items([{"title": "", "items": [["a", "가"], ["b", "나"]]}, {"nope": 1}, 5])
	nav.set_current("b")
	await _frames(3)
	ok(_selected_count(nav) == 1 and _is_selected(nav, "b"), "SideNav: set_items again, still exactly one selected")
	# a window too low for the list: the list scrolls and the footer stays
	_clear_stage()


func _selected_count(nav: SideNav) -> int:
	var n := 0
	for k in nav.item_buttons().keys():
		if _is_selected(nav, str(k)):
			n += 1
	return n


func _is_selected(nav: SideNav, key: String) -> bool:
	var b: Button = nav.item_buttons().get(key, null)
	if b == null:
		return false
	var sb: StyleBox = b.get_theme_stylebox("normal")
	return sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.is_equal_approx(Pal.PRIMARY_SOFT) and b.get_theme_color("font_color").is_equal_approx(Pal.PRIMARY)


# ---------------------------------------------------------------- BottomTabs (W3-5)

const TABS8 := [["today", "오늘"], ["lesson", "레슨"], ["talk", "원어민 대화"], ["practice", "연습"], ["reading", "읽기"], ["review", "복습"], ["log", "기록"], ["roadmap", "로드맵"]]
const SHORT := {"talk": "대화"}


func _test_bottom_tabs() -> void:
	_clear_stage()
	var page := Control.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(page)
	var host := VBoxContainer.new()
	host.custom_minimum_size = Vector2(412, 0)
	host.size = Vector2(412, _vp.y)
	host.add_theme_constant_override("separation", 0)
	page.add_child(host)
	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(filler)
	var bt := BottomTabs.new()
	host.add_child(bt)
	for m in ["set_tabs", "set_current", "overflow_keys", "direct_keys", "cell_buttons", "is_more_open", "toggle_more", "open_more", "close_more", "set_bottom_inset", "set_side_inset", "set_badge"]:
		ok(bt.has_method(m), "BottomTabs API: %s exists" % m)
	for sg in ["tab_selected", "more_toggled"]:
		ok(bt.has_signal(sg), "BottomTabs API: signal %s exists" % sg)
	ok(bt.max_direct == 6, "BottomTabs: max_direct stays 6 in W3")
	bt.set_tabs(TABS8, SHORT)
	bt.set_current("today")
	await _frames(4)
	ok(bt.direct_keys().size() == 5 and bt.overflow_keys().size() == 3, "BottomTabs: 8 tabs -> 5 direct + 3 in the sheet (%d / %d)" % [bt.direct_keys().size(), bt.overflow_keys().size()])
	var cells: Array = bt.cell_buttons()
	ok(cells.size() == 6, "BottomTabs: 5 cells + 더보기 = 6 (%d)" % cells.size())
	var small := 0
	var right := 0.0
	for c in cells:
		var cr: Rect2 = (c as Control).get_global_rect()
		right = maxf(right, cr.end.x)
		if cr.size.x < 47.5 or cr.size.y < 55.5:
			small += 1
	ok(small == 0 and right <= 412.5, "BottomTabs: every cell at least 48x56 and inside 412 px (right %.0f)" % right)
	ok(absf(bt.get_global_rect().size.y - 57.0) < 0.6, "BottomTabs: bar height unchanged (hairline 1 + cells 56): %.1f" % bt.get_global_rect().size.y)
	ok(not (cells[2] as Button).text.contains("원어민"), "BottomTabs: the short label is used (%s)" % (cells[2] as Button).text)
	# selected look
	var sel_ok := true
	for i in cells.size():
		var cb: Button = cells[i]
		var mark := cb.get_node("Mark") as Panel
		var want_sel: bool = i == 0
		if mark.visible != want_sel or cb.get_theme_color("font_color").is_equal_approx(Pal.PRIMARY) != want_sel or cb.has_theme_font_override("font") != want_sel:
			sel_ok = false
	ok(sel_ok, "BottomTabs: selected cell = PRIMARY text + bold + the pill; the others have none")
	var mr: Rect2 = (cells[0].get_node("Mark") as Control).get_global_rect()
	ok(absf(mr.size.x - 20.0) < 0.6 and absf(mr.size.y - 3.0) < 0.6, "BottomTabs: the pill is 20x3 (%.1f x %.1f)" % [mr.size.x, mr.size.y])
	ok(mr.end.y <= (cells[0] as Control).get_global_rect().end.y and mr.position.y > (cells[0] as Control).get_global_rect().position.y + 30.0, "BottomTabs: the pill sits under the text, inside the cell")
	ok(not (cells[0].get_node("Mark") as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "BottomTabs: the pill does not catch the mouse")
	bt.set_current("review")
	ok((cells[4] as Button).get_node("Mark").visible == false and (cells[0] as Button).get_node("Mark").visible == false, "BottomTabs: a tab in the sheet lights no direct cell (review is overflow here)")
	ok((cells[5] as Button).get_node("Mark").visible, "BottomTabs: …but the 더보기 cell is lit")
	bt.set_current("today")
	# taps on cells
	var picked: Array = []
	bt.tab_selected.connect(func(k: String) -> void: picked.append(k))
	await _tap(_center(cells[1] as Control))
	ok(picked == ["lesson"], "BottomTabs: tapping a cell sends tab_selected (%s)" % [picked])
	# the sheet
	var toggles: Array = []
	bt.more_toggled.connect(func(o: bool) -> void: toggles.append(o))
	bt.open_more()
	await _frames(6)
	ok(bt.is_more_open() and toggles == [true], "BottomTabs: open_more opens the sheet and sends more_toggled(true)")
	bt.open_more()
	ok(toggles == [true], "BottomTabs: open_more twice does not toggle again")
	ok(Sheet.is_open(), "BottomTabs: the 더보기 list is a Sheet")
	var sheet_btns := 0
	var low_btns := 0
	var all: Array = []
	_collect_controls(bt, all)
	for c2 in all:
		if c2 is Button and (c2 as Button).get_parent() is VBoxContainer and (c2 as Control).get_global_rect().size.x > (300.0 if _phone else 200.0):
			sheet_btns += 1
			if (c2 as Control).get_global_rect().size.y < (55.5 if _phone else 47.5):
				low_btns += 1
	ok(sheet_btns == 3 and low_btns == 0, "BottomTabs: the sheet lists 3 tabs, each tall enough (%d, short %d)" % [sheet_btns, low_btns])
	bt.close_more()
	ok(not bt.is_more_open() and toggles == [true, false], "BottomTabs: close_more closes it and sends more_toggled(false)")
	ok(not Sheet.is_open(), "BottomTabs: no sheet left")
	bt.close_more()
	ok(toggles == [true, false], "BottomTabs: close_more when closed sends nothing")
	await _frames(2)
	picked.clear()
	bt.open_more()
	await _frames(6)
	var sheet := (Sheet._stack.back() as Sheet)
	await _tap(_center(sheet.buttons["log"]))
	await _frames(2)
	ok(picked == ["log"] and not bt.is_more_open(), "BottomTabs: tapping a sheet entry closes the sheet and selects that tab (%s)" % [picked])
	# the Android back button path
	bt.open_more()
	await _frames(4)
	ok(Sheet.handle_back() and not bt.is_more_open(), "BottomTabs: Sheet.handle_back() closes the 더보기 sheet and the bar knows it")
	bt.open_more()
	await _frames(4)
	ok(Sheet.close_top() and not bt.is_more_open(), "BottomTabs: Sheet.close_top() likewise")
	await _frames(2)
	# a tab key the sheet would answer but that is not an overflow tab is ignored
	picked.clear()
	# 5 direct (max_direct 5)
	bt.max_direct = 5
	await _frames(3)
	ok(bt.direct_keys().size() == 4 and bt.overflow_keys().size() == 4 and bt.cell_buttons().size() == 5, "BottomTabs: max_direct = 5 -> 4 tabs + 더보기 (5 cells)")
	bt.max_direct = 9
	await _frames(3)
	ok(bt.direct_keys().size() == 8 and bt.overflow_keys().is_empty() and bt.cell_buttons().size() == 8, "BottomTabs: max_direct = 9 -> all 8 direct, no 더보기")
	bt.open_more()
	ok(not bt.is_more_open(), "BottomTabs: open_more without overflow does nothing")
	bt.max_direct = 1
	ok(bt.max_direct == 2, "BottomTabs: max_direct below 2 is raised to 2")
	bt.max_direct = 6
	await _frames(3)
	# badge
	bt.set_badge("lesson", true)
	ok((bt.cell_buttons()[1] as Button).get_node("Badge").visible and not (bt.cell_buttons()[0] as Button).get_node("Badge").visible, "BottomTabs: set_badge shows a dot on that cell only")
	bt.set_badge("log", true)
	ok((bt.cell_buttons()[5] as Button).get_node("Badge").visible, "BottomTabs: a badge on a tab in the sheet shows on 더보기")
	bt.set_badge("lesson", false)
	bt.set_badge("log", false)
	ok(not (bt.cell_buttons()[1] as Button).get_node("Badge").visible and not (bt.cell_buttons()[5] as Button).get_node("Badge").visible, "BottomTabs: set_badge(false) hides them")
	# few tabs
	bt.set_tabs([["a", "가"], ["b", "나"], ["c", "다"]], {})
	await _frames(3)
	ok(bt.cell_buttons().size() == 3 and bt.overflow_keys().is_empty(), "BottomTabs: 3 tabs -> 3 cells, no 더보기")
	bt.set_tabs([], {})
	ok(bt.cell_buttons().is_empty(), "BottomTabs: no tabs, no cells, no error")
	# inset
	bt.set_tabs(TABS8, SHORT)
	bt.set_bottom_inset(34.0)
	await _frames(3)
	ok(absf(bt.get_global_rect().size.y - (57.0 + 34.0)) < 0.6, "BottomTabs: set_bottom_inset(34) adds 34 px below the cells")
	_clear_stage()
	await _frames(2)


func _collect_controls(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Window:
			continue
		if c is Control:
			if not (c as Control).visible:
				continue
			out.append(c)
		_collect_controls(c, out)


# ---------------------------------------------------------------- AppView contract (W3-6)

func _test_app_view() -> void:
	var base := AppView.new()
	ok(base.has_signal("bar_changed"), "AppView: signal bar_changed")
	ok(base.page_title() == "" and base.page_subtitle() == "" and base.page_actions() == [], "AppView: title, subtitle, actions default to empty")
	ok(base.scroll_host() == null and base.header_block() == null, "AppView: scroll_host and header_block default to null")
	base.on_action("x")
	ok(true, "AppView: on_action does nothing by default")
	ok(base.go_back() == false, "AppView: go_back() is still false")
	base.free()
	var names := ["today", "lesson", "talk", "reading", "review", "roadmap", "stats", "practice"]
	var made := 0
	var clean := 0
	for n in names:
		var path: String = "res://scripts/views/%s_view.gd" % n
		var scr: GDScript = load(path) as GDScript
		if scr == null:
			continue
		var v: Object = scr.new()
		if v is AppView:
			made += 1
			var av := v as AppView
			if av.has_signal("bar_changed") and av.page_title() == "" and av.page_actions() == [] and av.scroll_host() == null and av.header_block() == null and av.page_subtitle() == "":
				clean += 1
		if v is Node:
			(v as Node).free()
	ok(made == names.size() and clean == made, "AppView: all %d existing screens still build and keep the empty defaults (made %d, clean %d)" % [names.size(), made, clean])


# ---------------------------------------------------------------- layer order

func _test_layers() -> void:
	# the first-connection dialog is above a sheet, the toast above both
	Sheet.animate = false
	var s := Sheet.confirm(_stage, "a", "b")
	await _frames(4)
	var dlg_layer: int = 28 # SyncChoiceDialog._init sets layer = 28
	var script: GDScript = load("res://scripts/sync/sync_choice_dialog.gd") as GDScript
	if script != null:
		var d: CanvasLayer = script.new()
		dlg_layer = d.layer
		d.free()
	var host := ToastHost.new()
	add_child(host)
	ok(s.layer_node.layer < dlg_layer and dlg_layer < host.layer, "Layers: sheet %d < first-connection question %d < toast %d" % [s.layer_node.layer, dlg_layer, host.layer])
	ok(s.layer_node.layer < 20, "Layers: a sheet is below the splash (20) and the connect screen (25)")
	host.queue_free()
	_close_all_sheets()
	await _frames(3)
	_clear_stage()
