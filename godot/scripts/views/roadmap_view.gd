class_name RoadmapView
extends AppView
## 로드맵: stage cards, 12 expandable months with checkboxes and per-month progress.

var lang: String = "en"
var _scroll: PageScroll


func _ready() -> void:
	_scroll = PageScroll.new(960.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	lang = Store.lang()
	Store.curriculum_updated.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func refresh() -> void:
	if _scroll == null:
		return
	lang = Store.lang()
	rebuild_keep_scroll(_scroll, _build)


func _is_open(n: int, current: bool) -> bool:
	var m: Dictionary = Store.prefs.get("open_months", {})
	var k := "%s%d" % [lang, n]
	if m.has(k):
		return bool(m[k])
	return current


func _set_open(n: int, open: bool) -> void:
	var m: Dictionary = Store.prefs.get("open_months", {})
	m["%s%d" % [lang, n]] = open
	Store.set_pref("open_months", m)


func _build() -> void:
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)
	var soft: Color = Pal.soft(lang)
	var pos: Dictionary = Store.position()
	var on_phase: bool = pos["phase"] == "on"

	var top := UI.hbox(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		refresh()))
	top.add_child(UI.spacer())
	top.add_child(UI.label("전체 진행 %d%%" % Store.lang_pct(lang), "Muted", false))
	c.add_child(top)
	c.add_child(UI.progress_bar(float(Store.lang_pct(lang)) / 100.0, acc, 10.0))

	# stage cards
	var rows: Array = Store.roadmap_rows(lang)
	var grid := GridContainer.new()
	grid.columns = 4 if size.x >= 1000.0 else 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in rows.size():
		var r: Array = rows[i]
		var cur: bool = on_phase and Plan.stage_of(int(pos["n"])) == i + 1
		var sp := PanelContainer.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var st := UI.style(soft if cur else Pal.SURFACE, Pal.LINE, 1, 10, 14, 12)
		st.border_width_top = 4
		st.border_color = acc
		sp.add_theme_stylebox_override("panel", st)
		var v := UI.vbox(5)
		v.add_child(UI.label(UI.plain(r[1]), "Eyebrow"))
		v.add_child(UI.label(UI.plain(r[0]), "H3"))
		v.add_child(UI.label(UI.plain(r[2]), "Small"))
		var lv := UI.label(UI.plain(r[3]), "Small")
		lv.add_theme_color_override("font_color", acc)
		v.add_child(lv)
		sp.add_child(v)
		grid.add_child(sp)
	c.add_child(grid)

	# months
	var months := UI.vbox(8)
	for m in Store.months(lang):
		months.add_child(_month_card(m, on_phase and int(pos["n"]) == int(m["n"])))
	c.add_child(months)
	UI.fix_cjk(c)


func _month_card(m: Dictionary, current: bool) -> Control:
	var acc: Color = Pal.accent(lang)
	var n: int = int(m["n"])
	var open: bool = _is_open(n, current)
	var pc: int = Store.pct(Store.month_items(lang, n))

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, acc if current else Pal.LINE, 2 if current else 1, 12, 0, 0))
	var outer := UI.vbox(0)
	card.add_child(outer)

	# header (clickable)
	var head := PanelContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	head.add_theme_stylebox_override("panel", UI.style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 12, 16, 12))
	var hrow := UI.hbox(14)
	hrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var num := UI.vbox(0)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nl := Label.new()
	nl.text = "%02d" % n
	nl.add_theme_font_size_override("font_size", 24)
	nl.add_theme_font_override("font", UI.bold_font())
	nl.add_theme_color_override("font_color", acc)
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.add_child(nl)
	var ym := UI.label(Plan.month_label(Store.start_iso(), n), "Small", false)
	ym.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.add_child(ym)
	num.custom_minimum_size = Vector2(60, 0)
	hrow.add_child(num)
	var mid := UI.vbox(1)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tl := UI.label(UI.plain(m["title"]), "Strong")
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(tl)
	var gl := UI.label(UI.plain(m["goal"]), "Small")
	gl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(gl)
	hrow.add_child(mid)
	var right := UI.vbox(4)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pl := UI.colored("%d%%" % pc, acc, "Strong", false)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(pl)
	var pb := UI.progress_bar(float(pc) / 100.0, acc, 6.0)
	pb.custom_minimum_size = Vector2(72, 6)
	pb.size_flags_horizontal = Control.SIZE_FILL
	pb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(pb)
	var chev := UI.label("▴" if open else "▾", "Muted", false)
	chev.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	chev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(chev)
	hrow.add_child(right)
	head.add_child(hrow)
	head.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_set_open(n, not open)
			refresh())
	outer.add_child(head)

	if not open:
		return card

	var body := UI.vbox(14)
	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 1)
	outer.add_child(line)
	outer.add_child(UI.margin(body, 18, 12, 18, 18))

	body.add_child(_section_title("핵심 학습 내용"))
	for kv in m.get("content", []):
		var d: Dictionary = kv
		var row := UI.hbox(12)
		var k := UI.colored(UI.plain(d.get("k", "")) if str(d.get("k", "")) != "" else "·", acc, "Strong", false)
		k.custom_minimum_size = Vector2(96, 0)
		k.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(k)
		row.add_child(UI.label(UI.plain(d.get("v", ""))))
		body.add_child(row)

	body.add_child(_section_title("주차별 포커스"))
	var weeks: Array = m.get("weeks", [])
	for i in weeks.size():
		var w: Dictionary = weeks[i]
		var key: String = Store.check_key(lang, n, "w", i)
		body.add_child(UI.check_row("%s · %s" % [UI.plain(w.get("w", "")), UI.plain(w.get("topic", ""))], Store.is_checked(key), func(on: bool) -> void:
			Store.set_checked(key, on)
			refresh(), UI.plain(w.get("act", ""))))

	body.add_child(_section_title("말하기 미션"))
	var missions: Array = m.get("missions", [])
	for i in missions.size():
		var key2: String = Store.check_key(lang, n, "m", i)
		body.add_child(UI.check_row(UI.plain(missions[i]), Store.is_checked(key2), func(on: bool) -> void:
			Store.set_checked(key2, on)
			refresh()))

	body.add_child(_section_title("월말 체크리스트"))
	var checks: Array = m.get("checks", [])
	for i in checks.size():
		var key3: String = Store.check_key(lang, n, "c", i)
		body.add_child(UI.check_row(UI.plain(checks[i]), Store.is_checked(key3), func(on: bool) -> void:
			Store.set_checked(key3, on)
			refresh()))
	return card


func _section_title(t: String) -> Label:
	var l := UI.label(t, "Eyebrow", false)
	return l
