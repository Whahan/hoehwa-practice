extends Node
## Basic UI parts test (docs/ui_redesign_design.md §6.4, W2-1..W2-6):
##   godot --headless --path <project> res://tests/ui_prims_test.tscn               (PC)
##   godot --headless --path <project> res://tests/ui_prims_test.tscn -- --phone    (phone)
## Sizes of buttons, options, tiles, links, segments, check boxes, switches, inputs and ListGroup rows; the shared
## button style cache (with a control run that switches it off); bad input (unknown kind, empty row text); dark colours
## and cache keys; a 300 px finger drag that starts on a row / a switch scrolls the page and calls nothing, taps still
## work; no Color("#...") literal and no fixed font size outside UI.fs in ui.gd.
## Reads and writes only a user://test_ui_prims_* file (prefs). Last line: "== ui_prims: N passed, M failed ==".

const PREFS := "user://test_ui_prims_prefs.json"
const DRAG_STEP := 10.0

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _min: float = 40.0 ## smallest allowed hit size of a control: 47.5 on the phone (48 dp), 40 on the PC
var _old_prefs: String = ""
var _taps: Dictionary = {}
var _toggles: Array = []


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
	print("== ui_prims start ==")
	_phone = Platform.is_phone()
	_min = 47.5 if _phone else 40.0
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)
	_old_prefs = Store.prefs_path
	Store.prefs_path = PREFS
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	print("[mode: %s, min hit size %.1f]" % ["phone" if _phone else "pc", _min])

	await _sizes_test()
	await _list_group_test()
	await _cache_test()
	_bad_input_test()
	_dark_test()
	_source_test()
	await _tap_drag_test()

	Store.prefs_path = _old_prefs
	var f := ProjectSettings.globalize_path(PREFS)
	if FileAccess.file_exists(PREFS):
		DirAccess.remove_absolute(f)
	print("== ui_prims: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _stage(w: float = 400.0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.custom_minimum_size.x = w
	v.size = Vector2(w, 10)
	add_child(v)
	return v


func _first(root: Node, cls: String) -> Control:
	var l: Array = root.find_children("*", cls, true, false)
	return l[0] if not l.is_empty() else null


func _h(c: Control) -> float:
	return maxf(c.size.y, c.get_combined_minimum_size().y)


func _w(c: Control) -> float:
	return maxf(c.size.x, c.get_combined_minimum_size().x)


# ---------------------------------------------------------------- sizes (W2-1)

func _sizes_test() -> void:
	print("[sizes]")
	var v := _stage()
	var items := {}
	for kind in ["default", "primary", "soft", "outline", "flat", "danger"]:
		var b := UI.button("버튼 %s" % kind, kind, Pal.EN)
		v.add_child(b)
		items["button/" + kind] = b
	var big := UI.button("크게", "primary", Pal.EN, 56.0)
	v.add_child(big)
	items["button/min_h56"] = big
	var opt := UI.option_row("선택지 하나")
	v.add_child(opt)
	items["option_row"] = opt
	var tile := UI.tile("word")
	v.add_child(tile)
	items["tile"] = tile
	var seg := UI.segmented([["a", "하나"], ["b", "둘"]], "a", func(_v: String) -> void: pass)
	v.add_child(seg)
	for i in 2:
		items["segmented/%d" % i] = seg.find_children("*", "Button", true, false)[i]
	var cr := UI.check_row("확인 항목", false, func(_on: bool) -> void: pass)
	v.add_child(cr)
	items["check_row/CheckBox"] = _first(cr, "CheckBox")
	var ps := UI.pref_switch("자동 재생", "auto_speak")
	v.add_child(ps)
	items["pref_switch"] = ps
	var pt := UI.pref_toggle("체크", "auto_speak")
	v.add_child(pt)
	items["pref_toggle"] = pt
	var sw := UI.switch_row("스위치 줄", false, func(_on: bool) -> void: pass, "부연")
	v.add_child(sw)
	items["switch_row/CheckButton"] = sw.get_meta("switch")
	var ob := UI.option_button(["하나", "둘"], 0)
	v.add_child(ob)
	items["option_button"] = ob
	var le := LineEdit.new()
	var fld := UI.field("이름", le)
	v.add_child(fld)
	items["field/LineEdit"] = le
	var fob := UI.option_button(["a"], 0)
	v.add_child(UI.field("고르기", fob))
	items["field/OptionButton"] = fob
	var fc := UI.filter_chip("칩", false, Callable())
	v.add_child(fc)
	items["filter_chip"] = fc
	var fcs := UI.filter_chip("선택된 칩", true, Callable())
	v.add_child(fcs)
	items["filter_chip/selected"] = fcs
	var lk := UI.link_button("▶ 듣기")
	v.add_child(lk)
	await _frames(3)
	for k in items.keys():
		var c: Control = items[k]
		var need: float = _min
		if not _phone and str(k).begins_with("filter_chip"):
			need = 32.0 # PC choice chips are 32 high (§5.3)
		ok(_h(c) >= need, "%s height %.1f >= %.1f" % [k, _h(c), need])
	if _phone:
		ok(_h(lk) >= _min and _w(lk) >= _min, "link_button %.1f x %.1f >= %.1f both ways" % [_w(lk), _h(lk), _min])
	else:
		ok(_h(lk) >= 0.0, "link_button builds on the PC")
	ok(sw.get_meta("switch") is CheckButton and _w(sw.get_meta("switch")) >= 48.0, "switch_row switch is at least 48 wide (%.1f)" % _w(sw.get_meta("switch")))
	ok(_h(ps) >= 48.0 and _w(ps) >= 48.0, "pref_switch hit area %.1f x %.1f >= 48x48" % [_w(ps), _h(ps)])
	ok(_h(items["check_row/CheckBox"]) >= _min and _w(items["check_row/CheckBox"]) >= _min, "check_row CheckBox hit area >= %.1f both ways" % _min)
	ok(UI.fs(16) == 16 and Ds.fs(16) == UI.fs(16), "UI.fs is Ds.fs (16 -> %d)" % UI.fs(16))
	v.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- ListGroup (W2-1, W2-3)

func _list_group_test() -> void:
	print("[ListGroup]")
	var v := _stage()
	var g := ListGroup.new()
	v.add_child(g)
	var r1 := g.add_row("한 줄 행")
	var r2 := g.add_row("두 줄 행", "부연 설명")
	var r3 := g.add_value_row("값 행", "켜짐", func() -> void: pass)
	var r4 := g.add_row("위험 행", "", null, func() -> void: pass, true)
	var sw := g.add_switch_row("스위치 행", "설명", "auto_speak")
	var cr := g.add_check_row("체크 행", false, func(_on: bool) -> void: pass)
	g.add_custom(UI.label("임의 조각"))
	await _frames(3)
	ok(r1 != null and r1.size.y >= 56.0 and r1.size.y < 72.0, "row without sub is >= 56 (%.1f)" % r1.size.y)
	ok(r2 != null and r2.size.y >= 72.0, "row with sub is >= 72 (%.1f)" % r2.size.y)
	ok(r3 != null and r3.size.y >= 56.0, "value row is >= 56 (%.1f)" % r3.size.y)
	ok(r3 != null and _first(r3, "Control") != null and not r3.find_children("*", "GlyphIcon", true, false).is_empty(), "value row has a chevron icon")
	var danger_label := _first(r4, "Label") as Label
	ok(danger_label != null and danger_label.get_theme_color("font_color") == Pal.BAD_ON, "danger row text uses BAD_ON")
	ok(sw != null and sw.size.x >= 48.0 and sw.size.y >= 48.0, "switch row switch hit area %.1f x %.1f >= 48x48" % [sw.size.x, sw.size.y])
	ok(sw != null and sw.accessibility_name == "스위치 행", "switch has an accessibility name")
	ok(cr != null, "check row returns its CheckBox")
	# 7 pieces, 6 dividers in between (none before the first, none after the last)
	ok(g.body.get_child_count() == 13, "7 rows + 6 dividers = 13 body children (got %d)" % g.body.get_child_count())
	var lines: Array = g.body.find_children("*", "ColorRect", true, false)
	ok(lines.size() == 6 and (lines[0] as ColorRect).color == Pal.LINE, "6 dividers in LINE colour")
	ok(g.body.get_child(g.body.get_child_count() - 1) is MarginContainer and not (g.body.get_child(g.body.get_child_count() - 1).get_child(0) is ColorRect), "no divider after the last row")
	ok(str(g.theme_type_variation) == "Group", "group variation")
	ok(UI.card("Group") is ListGroup, "UI.card(\"Group\") builds a ListGroup")
	ok(UI.card("Card").get_class() == "PanelContainer" and not (UI.card("Card") is ListGroup), "UI.card(\"Card\") is a plain CardBox")
	var hd := ListGroup.header("머리글")
	ok(hd is Label and str(hd.theme_type_variation) == "SectionHeader", "header is a SectionHeader label")
	ok(hd.get_theme_stylebox("normal").content_margin_top == 24.0 and hd.get_theme_stylebox("normal").content_margin_bottom == 8.0 and hd.get_theme_stylebox("normal").content_margin_left == 8.0, "header gap 24 above, 8 below, 8 left")
	ok(UI.section_header("x").text == "x", "UI.section_header")
	# W2-3: an empty main text adds no row
	var before: int = g.body.get_child_count()
	var warn_row := g.add_row("")
	ok(warn_row == null and g.body.get_child_count() == before, "add_row(\"\") returns null and adds nothing")
	var warn_row2 := g.add_row("   ")
	ok(warn_row2 == null and g.body.get_child_count() == before, "add_row of blanks adds nothing")
	var sw2 := g.add_switch_row("", "", "auto_speak")
	ok(sw2 == null and g.body.get_child_count() == before, "add_switch_row(\"\") adds nothing and returns null")
	var g2 := ListGroup.new()
	v.add_child(g2)
	ok(g2.body.get_child_count() == 0, "empty group has no children")
	g2.add_row("only")
	ok(g2.body.get_child_count() == 1, "a single row has no divider")
	v.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- cache (W2-2)

## What n buttons cost: [Performance resource count growth, live objects beyond the n buttons, distinct StyleBox
## instances held by the buttons]. The monitors refresh once per frame, so wait a couple of frames on both sides.
## OBJECT_RESOURCE_COUNT only counts resources that have a path (cached), so it cannot see StyleBoxes made in code;
## OBJECT_COUNT and the distinct-instance count can.
func _measure_buttons(n: int, bare: bool = false) -> Array:
	await _frames(2)
	var res0: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var obj0: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var keep: Array = []
	var ids := {}
	for i in n:
		var b: Button = Button.new() if bare else UI.button("x", "primary", Pal.EN)
		keep.append(b)
		for k in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			ids[b.get_theme_stylebox(k).get_instance_id()] = true
	await _frames(2)
	var res: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)) - res0
	var obj: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - obj0 - n
	for b in keep:
		(b as Node).free()
	return [res, obj, ids.size()]


func _cache_test() -> void:
	print("[style cache]")
	UI.cache_enabled = true
	var base: Array = await _measure_buttons(200, true) # a bare Button already owns a few helper objects
	var on: Array = await _measure_buttons(200)
	on[1] -= base[1]
	ok(on[0] <= 40, "200 cached buttons: resource count grows by %d (<= 40)" % on[0])
	ok(on[1] <= 40, "200 cached buttons: %d live objects more than 200 bare Buttons (<= 40)" % on[1])
	ok(on[2] <= 40, "200 cached buttons hold %d distinct StyleBoxes (<= 40)" % on[2])
	# control run: with the cache off the same measurement must see the many StyleBoxes (else it measures nothing)
	UI.cache_enabled = false
	var off: Array = await _measure_buttons(200)
	UI.cache_enabled = true
	off[1] -= base[1]
	ok(off[2] > 40, "control run without the cache holds %d distinct StyleBoxes (> 40: the measurement can fail)" % off[2])
	ok(off[1] > 40, "control run without the cache: %d live objects more than 200 bare Buttons (> 40)" % off[1])
	var a := UI.button("a", "primary", Pal.EN)
	var b := UI.button("b", "primary", Pal.EN)
	var c := UI.button("c", "primary", Pal.JA)
	ok(a.get_theme_stylebox("normal") == b.get_theme_stylebox("normal"), "same look shares the StyleBox")
	ok(a.get_theme_stylebox("normal") != c.get_theme_stylebox("normal"), "another accent gets another StyleBox")
	var free_style := UI.style(Pal.SURFACE)
	ok(free_style != UI.style(Pal.SURFACE), "UI.style() still returns a fresh object every time")
	a.free()
	b.free()
	c.free()


# ---------------------------------------------------------------- bad input (W2-3)

func _bad_input_test() -> void:
	print("[bad input]")
	var b := UI.button("", "nope")
	ok(b != null and b.text == "", "UI.button(\"\", \"nope\") builds")
	ok(not b.has_theme_stylebox_override("normal"), "unknown kind keeps the theme look (no style override)")
	b.free()
	var n := UI.chip_kind("x", "nope")
	var neutral := UI.chip_kind("x", "neutral")
	var nl := _first(n, "Label") as Label
	var ml := _first(neutral, "Label") as Label
	ok(nl.get_theme_color("font_color") == ml.get_theme_color("font_color") and (n.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == (neutral.get_theme_stylebox("panel") as StyleBoxFlat).bg_color, "unknown chip kind is neutral")
	var ok_chip := UI.chip_kind("x", "ok")
	ok((ok_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == Pal.OK_SOFT and _first(ok_chip, "Label").get_theme_color("font_color") == Pal.OK_ON, "chip_kind ok = OK_ON on OK_SOFT")
	for k in ["bad", "warn", "info", "lang_en", "lang_ja"]:
		var ck := UI.chip_kind("x", k)
		ok((ck.get_theme_stylebox("panel") as StyleBoxFlat).bg_color != (neutral.get_theme_stylebox("panel") as StyleBoxFlat).bg_color, "chip_kind %s differs from neutral" % k)
		ck.free()
	for k in [n, neutral, ok_chip]:
		(k as Node).free()
	var fcb := UI.filter_chip("x", false, Callable())
	fcb.pressed.emit() # an invalid callback must not crash
	ok(true, "filter_chip with an invalid callback survives a press")
	fcb.free()
	var got: Array = []
	var fc1 := UI.filter_chip("x", false, func(new_state: bool) -> void: got.append(new_state))
	var fc2 := UI.filter_chip("x", true, func() -> void: got.append("plain"))
	fc1.pressed.emit()
	fc2.pressed.emit()
	ok(got == [true, "plain"], "filter_chip passes the new state to a one-argument callback only (%s)" % str(got))
	fc1.free()
	fc2.free()
	var pb := UI.progress_bar(5.0, Pal.EN)
	ok(pb.value == 1.0 and pb.custom_minimum_size.y == 10.0, "progress_bar clamps the value, height 10")
	var pi := UI.progress_indeterminate(Pal.EN)
	ok(pi.indeterminate, "progress_indeterminate is indeterminate")
	pb.free()
	pi.free()
	# bad font scale values through the UI helper
	Ds.set_font_scale(9.0)
	ok(UI.fs(20) == 30, "font scale 9.0 -> 1.5: UI.fs(20) = %d" % UI.fs(20))
	Ds.set_font_scale(0.0)
	ok(UI.fs(20) == 20, "font scale 0 -> 1.0: UI.fs(20) = %d" % UI.fs(20))
	Ds.set_font_scale(1.0)


# ---------------------------------------------------------------- dark colours and the cache key

func _dark_test() -> void:
	print("[dark]")
	Pal.use("light")
	var lb := UI.button("l", "soft", Pal.EN)
	var l_bg: Color = (lb.get_theme_stylebox("normal") as StyleBoxFlat).bg_color
	ok(l_bg == Pal.EN_SOFT, "light soft button = EN_SOFT")
	Pal.use("dark")
	var db := UI.button("d", "soft", Pal.EN)
	var d_bg: Color = (db.get_theme_stylebox("normal") as StyleBoxFlat).bg_color
	ok(d_bg == Pal.EN_SOFT and d_bg != l_bg, "dark soft button = the dark EN_SOFT, not a cached light style")
	var dp := UI.button("p", "primary", Pal.EN)
	ok(dp.get_theme_color("font_color") == Pal.ON_ACCENT, "primary text = ON_ACCENT in dark")
	var dng := UI.button("x", "danger")
	ok((dng.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == Pal.BAD and dng.get_theme_color("font_color") == Pal.ON_ACCENT, "danger = BAD fill + ON_ACCENT text")
	var ds := UI.button("o", "outline", Pal.OK)
	var ol := ds.get_theme_stylebox("normal") as StyleBoxFlat
	ok(ol.border_width_left == 2 and ol.bg_color == Pal.OK_SOFT and ds.get_theme_color("font_color") == Pal.OK_ON, "outline = tonal + 2 px border, text OK_ON")
	Pal.use("light")
	for c in [lb, db, dp, dng, ds]:
		(c as Node).free()


# ---------------------------------------------------------------- source rules (W2-6)

func _source_test() -> void:
	print("[source]")
	var text: String = FileAccess.get_file_as_string("res://scripts/ui/ui.gd")
	ok(text != "", "ui.gd is readable")
	ok(not text.contains('Color("#'), 'no Color("#...") literal in ui.gd')
	var bad := 0
	for line in text.split("\n"):
		if line.contains("add_theme_font_size_override(") and not line.contains("fs(") and not line.begins_with("##"):
			bad += 1
	ok(bad == 0, "every add_theme_font_size_override in ui.gd goes through fs() (%d outside)" % bad)
	# the checker itself can fail: a line without fs() is counted
	var probe := 'x.add_theme_font_size_override("font_size", 14)'
	ok(probe.contains("add_theme_font_size_override(") and not probe.contains("fs("), "selfcheck: a fixed size line is detected")
	ok('Color("#7C9BE8")'.contains('Color("#'), "selfcheck: a colour literal is detected")


# ---------------------------------------------------------------- drag and tap (W2-5)

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


func _mouse(pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(e)


func _build_page() -> PageScroll:
	var ps := PageScroll.new(720.0)
	ps.size = Vector2(412, 600) if _phone else Vector2(900, 600)
	ps.position = Vector2.ZERO
	add_child(ps)
	var c := ps.content
	c.add_child(UI.label("맨 위 글", "H2"))
	c.add_child(ListGroup.header("묶음", 4))
	var g := ListGroup.new()
	c.add_child(g)
	g.add_row("첫째 행", "부연", null, func() -> void: _taps["r1"] = int(_taps.get("r1", 0)) + 1)
	g.add_row("둘째 행", "", null, func() -> void: _taps["r2"] = int(_taps.get("r2", 0)) + 1)
	g.add_value_row("셋째 값 행", "값", func() -> void: _taps["r3"] = int(_taps.get("r3", 0)) + 1)
	var sw := g.add_switch_row("넷째 스위치 행", "설명", "auto_speak")
	sw.toggled.connect(func(on: bool) -> void: _toggles.append(on))
	for i in 14:
		c.add_child(UI.label("아래 채움 줄 %d — 페이지를 길게 만드는 글이에요." % i))
	return ps


func _tap_drag_test() -> void:
	print("[tap and drag on rows and switches]")
	var ps := _build_page()
	await _frames(4)
	var g: ListGroup = ps.content.find_children("*", "CardBox", true, false)[0]
	var rows: Array = []
	for ch in g.body.get_children():
		if ch.get_class() == "PanelContainer":
			rows.append(ch)
	ok(rows.size() == 4, "page has 4 rows (%d)" % rows.size())
	var sw: CheckButton = _first(g, "CheckButton") as CheckButton
	var max_scroll: int = int(ps.get_v_scroll_bar().max_value - ps.get_v_scroll_bar().page)
	ok(max_scroll >= 250, "page scrolls at least 250 px (%d)" % max_scroll)
	if not _phone:
		await _pc_click_test(ps, rows, sw)
		ps.queue_free()
		await _frames(2)
		return
	Input.emulate_touch_from_mouse = true
	Input.use_accumulated_input = false
	ok(DisplayServer.is_touchscreen_available(), "touchscreen available (emulated)")
	var starts := {
		"row1 text": (rows[0] as Control).get_global_rect().get_center(),
		"row2 text": (rows[1] as Control).get_global_rect().get_center(),
		"value row": (rows[2] as Control).get_global_rect().get_center(),
		"switch row (left)": (rows[3] as Control).get_global_rect().position + Vector2(60, 28),
		"switch": sw.get_global_rect().get_center(),
	}
	for k in starts.keys():
		ps.scroll_vertical = 0
		await _frames(3)
		_taps.clear()
		_toggles.clear()
		var sw_before: bool = sw.button_pressed
		var pos: Vector2 = starts[k]
		# the positions were measured at scroll 0: recompute for the switch (it may have moved with the layout)
		if k == "switch":
			pos = sw.get_global_rect().get_center()
		var moved: int = await _drag_up(ps, pos)
		ok(float(moved) >= 200.0, "drag from %s moves the page %d px (>= 200)" % [k, moved])
		ok(_taps.is_empty() and _toggles.is_empty() and sw.button_pressed == sw_before, "drag from %s calls no tap and flips nothing (%s %s)" % [k, str(_taps), str(_toggles)])
	# taps still work
	ps.scroll_vertical = 0
	await _frames(3)
	_taps.clear()
	_toggles.clear()
	await _tap_at((rows[0] as Control).get_global_rect().get_center())
	ok(int(_taps.get("r1", 0)) == 1, "tap on row 1 calls its handler once (%s)" % str(_taps))
	await _tap_at((rows[2] as Control).get_global_rect().get_center())
	ok(int(_taps.get("r3", 0)) == 1, "tap on the value row calls its handler once (%s)" % str(_taps))
	var was: bool = sw.button_pressed
	await _tap_at(sw.get_global_rect().get_center())
	ok(_toggles.size() == 1 and sw.button_pressed != was, "tap on the switch flips it exactly once (%s)" % str(_toggles))
	was = sw.button_pressed
	_toggles.clear()
	await _tap_at((rows[3] as Control).get_global_rect().position + Vector2(60, 28))
	ok(_toggles.size() == 1 and sw.button_pressed != was, "tap on the switch row text flips it exactly once (%s)" % str(_toggles))
	# selfcheck: a press-time handler (what the rule forbids) IS caught by the same harness. A bare panel that acts on
	# press, in the same page, must show a call after the drag; if it did not, this test could not see such a bug.
	var bad := Panel.new()
	bad.custom_minimum_size = Vector2(0, 80)
	bad.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_taps["press_time"] = int(_taps.get("press_time", 0)) + 1)
	ps.content.add_child(bad)
	ps.content.move_child(bad, 1)
	await _frames(4)
	ps.scroll_vertical = 0
	await _frames(3)
	_taps.clear()
	var moved_bad: int = await _drag_up(ps, bad.get_global_rect().get_center())
	ok(int(_taps.get("press_time", 0)) == 1, "selfcheck FAIL-as-expected: a press-time handler is reported by the drag harness (%s, moved %d)" % [str(_taps), moved_bad])
	ps.queue_free()
	await _frames(2)


## 300 px finger drag upwards from `pos`; returns how far the page moved while the finger was down.
func _drag_up(ps: ScrollContainer, pos: Vector2) -> int:
	_touch(pos, true)
	await get_tree().process_frame
	for i in 30:
		pos.y -= DRAG_STEP
		_drag_ev(pos, Vector2(0, -DRAG_STEP))
		await get_tree().process_frame
	var moved: int = ps.scroll_vertical
	_touch(pos, false)
	await _frames(3)
	return moved


func _tap_at(pos: Vector2) -> void:
	_touch(pos, true)
	await _frames(3)
	_touch(pos, false)
	await _frames(3)


func _pc_click_test(ps: PageScroll, rows: Array, sw: CheckButton) -> void:
	_taps.clear()
	_toggles.clear()
	var p1: Vector2 = (rows[0] as Control).get_global_rect().get_center()
	_mouse(p1, true)
	await _frames(2)
	_mouse(p1, false)
	await _frames(2)
	ok(int(_taps.get("r1", 0)) == 1, "PC click on row 1 calls its handler once (%s)" % str(_taps))
	var was: bool = sw.button_pressed
	var ps1: Vector2 = sw.get_global_rect().get_center()
	_mouse(ps1, true)
	await _frames(2)
	_mouse(ps1, false)
	await _frames(2)
	ok(_toggles.size() == 1 and sw.button_pressed != was, "PC click on the switch flips it exactly once (%s)" % str(_toggles))
	was = sw.button_pressed
	_toggles.clear()
	var p4: Vector2 = (rows[3] as Control).get_global_rect().position + Vector2(60, 28)
	_mouse(p4, true)
	await _frames(2)
	_mouse(p4, false)
	await _frames(2)
	ok(_toggles.size() == 1 and sw.button_pressed != was, "PC click on the switch row text flips it exactly once (%s)" % str(_toggles))
