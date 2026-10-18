class_name RoadmapView
extends AppView
## 로드맵: stage cards, 12 expandable months with checkboxes and per-month progress.
## Each month is a list group (docs/ui_redesign_design.md §7.9): a tappable title row (56+) that opens the weeks under it.

var lang: String = "en"
var _scroll: PageScroll
var _header: Control = null ## big title block (see header_block)


func _ready() -> void:
	_scroll = PageScroll.new(880.0)
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


# ---------------------------------------------------------------- app bar contract (AppView)

func scroll_host() -> ScrollContainer:
	return _scroll


func header_block() -> Control:
	return _header if _header != null and is_instance_valid(_header) else null


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
	var phone: bool = Platform.is_phone()

	_header = PageHeader.build("로드맵")
	c.add_child(_header)
	var top := UI.adaptive(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		refresh()))
	if not phone:
		top.add_child(UI.spacer())
	top.add_child(UI.label("전체 진행 %d%%" % Store.lang_pct(lang), "Muted", false))
	c.add_child(top)
	c.add_child(UI.progress_bar(float(Store.lang_pct(lang)) / 100.0, acc, 10.0))

	# stage cards
	var rows: Array = Store.roadmap_rows(lang)
	var grid := GridContainer.new()
	grid.columns = 4 if size.x >= 1000.0 else 2
	if phone:
		grid.columns = 1
	grid.add_theme_constant_override("h_separation", Ds.S3)
	grid.add_theme_constant_override("v_separation", Ds.S3)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in rows.size():
		var r: Array = rows[i]
		var cur: bool = on_phase and Plan.stage_of(int(pos["n"])) == i + 1
		var sp := PanelContainer.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# the stage the learner is in: tinted surface AND a 2 px outline (colour is not the only cue)
		var st := UI.style(soft if cur else Pal.SURFACE, acc if cur else Pal.LINE, 2 if cur else 1, Ds.R_CARD, Ds.S4, Ds.S4)
		sp.add_theme_stylebox_override("panel", st)
		var v := UI.vbox(5)
		v.add_child(UI.label(UI.plain(r[1]), "Eyebrow"))
		v.add_child(UI.label(UI.plain(r[0]), "H3"))
		v.add_child(UI.label(UI.plain(r[2]), "Small"))
		v.add_child(UI.colored(UI.plain(r[3]), Pal.on(lang), "Small"))
		sp.add_child(v)
		grid.add_child(sp)
	c.add_child(grid)

	# months
	var months := UI.vbox(Ds.S3 if phone else Ds.S4)
	for m in Store.months(lang):
		months.add_child(_month_card(m, on_phase and int(pos["n"]) == int(m["n"])))
	c.add_child(months)
	UI.fix_cjk(c)
	bar_changed.emit() # the big title block was rebuilt


func _month_card(m: Dictionary, current: bool) -> Control:
	var acc: Color = Pal.accent(lang)
	var n: int = int(m["n"])
	var open: bool = _is_open(n, current)
	var pc: int = Store.pct(Store.month_items(lang, n))

	var group := ListGroup.new()
	if current: # this month: a 2 px outline around the group (shape cue, not only colour)
		group.add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, acc, 2, Ds.R_CARD, 0, 0))

	# title row: month number + date | title + goal | progress + chevron. The whole row is tappable (UI.on_tap: a drag
	# that starts on it scrolls the page, a tap opens / closes the month).
	var right := UI.vbox(4)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pr := UI.hbox(8)
	pr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pr.alignment = BoxContainer.ALIGNMENT_END
	var pl := UI.label("%d%%" % pc, "Muted", false)
	pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pr.add_child(pl)
	var chev := UI.label("▴" if open else "▾", "Muted", false)
	chev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pr.add_child(chev)
	right.add_child(pr)
	var pb := UI.progress_bar(float(pc) / 100.0, acc, 6.0)
	pb.custom_minimum_size = Vector2(72, 6)
	pb.size_flags_horizontal = Control.SIZE_FILL
	pb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(pb)
	var head: Control = group.add_row(UI.plain(m["title"]), UI.plain(m["goal"]), right, func() -> void:
		_set_open(n, not open)
		refresh())
	var num := UI.vbox(0)
	num.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var nl := Label.new()
	nl.text = "%02d" % n
	nl.theme_type_variation = &"H2"
	nl.add_theme_color_override("font_color", Pal.on(lang))
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.add_child(nl)
	var ym := UI.label(Plan.month_label(Store.start_iso(), n), "Small", false)
	ym.mouse_filter = Control.MOUSE_FILTER_IGNORE
	num.add_child(ym)
	num.custom_minimum_size = Vector2(60, 0)
	if head != null:
		var hrow: Node = (head as ListGroup._Row).content.get_child(0)
		hrow.add_child(num)
		hrow.move_child(num, 0)

	if not open:
		return group

	var body := UI.vbox(14)
	group.add_custom(body)

	body.add_child(_section_title("핵심 학습 내용"))
	for kv in m.get("content", []):
		var d: Dictionary = kv
		var row := UI.adaptive(12) # phone: the key above its text
		var k := UI.colored(UI.plain(d.get("k", "")) if str(d.get("k", "")) != "" else "·", Pal.on(lang), "Strong", false)
		if not Platform.is_phone():
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
	return group


func _section_title(t: String) -> Label:
	var l := UI.label(t, "Eyebrow", false)
	return l
