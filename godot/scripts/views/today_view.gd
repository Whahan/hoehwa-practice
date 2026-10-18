class_name TodayView
extends AppView
## 오늘: progress overview, two language cards (docs/ui_redesign_design.md §7.1). The settings are a SettingsView
## (views/settings_view.gd), a screen of its own (views["settings"] in main.gd): this screen carries no settings.

const WD := ["일", "월", "화", "수", "목", "금", "토"]
const NATIVE := {"en": "English", "ja": "日本語"}
const NAME_KO := {"en": "영어", "ja": "일본어"}

var _scroll: PageScroll
var _grid: GridContainer
var _built: bool = false
var _header: Control = null ## big title block (see header_block)


func _ready() -> void:
	_scroll = PageScroll.new(880.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	Store.curriculum_updated.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func refresh() -> void:
	if _scroll == null:
		return
	rebuild_keep_scroll(_scroll, _build)


# ---------------------------------------------------------------- app bar contract (AppView)

# (page_title / page_actions stay at their defaults: the tab name "오늘" is the title, and the shell adds the
# 설정 action of the app bar itself and opens its own settings screen.)

func scroll_host() -> ScrollContainer:
	return _scroll


func header_block() -> Control:
	return _header if _header != null and is_instance_valid(_header) else null


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _grid != null:
		_grid.columns = 2 if size.x >= 980.0 else 1


func _build() -> void:
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	var pos: Dictionary = Store.position()
	_header = PageHeader.build("오늘", _subtitle(pos))
	for k in ["title_label", "subtitle_label"]: # text only: the finger goes through to the page
		if _header.has_meta(k):
			(_header.get_meta(k) as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(_header)
	var hero := UI.card("Card", 12)
	hero.body.add_child(_hero(pos))
	hero.body.add_child(GoalCard.compact(Store.lang()))
	c.add_child(hero)
	_grid = GridContainer.new()
	_grid.columns = 2 if size.x >= 980.0 else 1
	_grid.add_theme_constant_override("h_separation", Ds.S4)
	_grid.add_theme_constant_override("v_separation", Ds.S3 if Platform.is_phone() else Ds.S4)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(_grid)
	for l in ["en", "ja"]:
		_grid.add_child(_lang_card(l, pos))
	if Platform.is_phone():
		c.add_child(_shortcuts())
	UI.fix_cjk(c)
	_built = true
	bar_changed.emit() # the big title block was rebuilt


## Phone: the 5-tab bar keeps 연습 and 읽기 behind 더보기, so 오늘 offers them as two rows (design §11 Q2).
func _shortcuts() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.add_child(UI.section_header("바로가기"))
	var g := UI.card("Group") as ListGroup
	for t in [["연습", "practice"], ["읽기", "reading"]]:
		var view: String = t[1]
		g.add_value_row(String(t[0]), "", func() -> void: Store.navigate.emit(view, ""))
	v.add_child(g)
	return v


## One line under the big title: stage and week (nothing before the start day: the hero card says it).
func _subtitle(pos: Dictionary) -> String:
	var phase: String = pos["phase"]
	if phase == "before":
		return ""
	if phase == "after":
		return "1년 완주"
	var n: int = pos["n"]
	return "%d단계 · %d개월차 %d주차" % [Plan.stage_of(n), n, int(pos["w"])]


# ---------------------------------------------------------------- hero

func _hero(pos: Dictionary) -> Control:
	var v := UI.vbox(8)
	var phase: String = pos["phase"]
	var start: String = Store.start_iso()
	if phase == "before":
		v.add_child(UI.label("시작까지", "Eyebrow", false))
		var line := UI.adaptive(14)
		var big := UI.label("D-%d" % int(pos["days"]), "Big", false)
		line.add_child(big)
		var s := UI.label("%s 시작 · 아래는 첫 주 미리보기예요. 레슨과 원어민 대화는 지금 바로 써 볼 수 있어요." % start.replace("-", "."), "Muted")
		s.size_flags_vertical = Control.SIZE_SHRINK_END
		line.add_child(s)
		v.add_child(line)
		v.add_child(UI.progress_bar(0.0, Pal.INK, 8.0))
	else:
		var total: int = Plan.total_days(start)
		var dn: int = mini(int(pos["day_no"]), total)
		var line := UI.hbox(10)
		line.add_child(UI.label("%d일째" % dn, "Big", false))
		var of := UI.label("/ %d일" % total, "Muted", false)
		of.size_flags_vertical = Control.SIZE_SHRINK_END
		line.add_child(of)
		v.add_child(line)
		v.add_child(UI.progress_bar(float(dn) / float(total), Pal.INK, 8.0))
	return v


# ---------------------------------------------------------------- language card

func _lang_card(l: String, pos: Dictionary) -> Control:
	var acc: Color = Pal.accent(l)
	var n: int = pos["n"]
	var w: int = pos["w"]
	var m: Dictionary = Store.month_data(l, n)
	var wk: Dictionary = Store.week_data(l, n, w)
	var phone: bool = Platform.is_phone()
	var card := UI.card("Card", 14)

	var head: Container = UI.hbox(8)
	if phone:
		head = UI.flow(8, 4) # the XP chip drops under the name when the card is narrow
	var nm := Label.new()
	nm.text = NATIVE[l]
	nm.theme_type_variation = &"H2"
	nm.add_theme_color_override("font_color", Pal.on(l))
	head.add_child(nm)
	var ko := UI.label(NAME_KO[l], "Small", false)
	ko.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(ko)
	if not phone:
		head.add_child(UI.spacer())
	var st: int = StudyLog.streak(l)
	var chip_text := ("연속 %d일" % st) if st > 0 else "오늘부터 시작"
	head.add_child(UI.chip_kind("%s · %d XP" % [chip_text, Store.xp(l)], "lang_" + l))
	card.body.add_child(head)

	var where := UI.vbox(2)
	where.add_child(UI.label("%d개월차 · %s" % [n, str(wk.get("w", ""))], "Eyebrow", false))
	where.add_child(UI.label(UI.plain(m.get("title", "")), "H3"))
	card.body.add_child(where)

	var box := UI.tinted_panel(Pal.soft(l), Color(0, 0, 0, 0), 0, Ds.R_S, 14, 12)
	var bv := UI.vbox(4)
	bv.add_child(UI.colored("이번 주", Pal.on(l), "Small", false))
	bv.add_child(UI.label(UI.plain(wk.get("topic", "")), "Strong"))
	bv.add_child(UI.label(UI.plain(wk.get("act", "")), "Small"))
	box.add_child(bv)
	card.body.add_child(box)

	# one filled button per card (the lesson); everything else is tonal
	var b1 := UI.button("오늘의 레슨", "primary", acc, 56.0 if phone else 46.0)
	b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b1.pressed.connect(func() -> void: Store.navigate.emit("lesson", l))
	card.body.add_child(b1)

	var btns := UI.flow(8, 8) # the second button drops to its own line when the text is large
	var b2 := UI.button("원어민과 대화", "soft", acc, 46.0)
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b2.custom_minimum_size.x = 140.0
	b2.pressed.connect(func() -> void: Store.navigate.emit("talk", l))
	btns.add_child(b2)

	# FSRS: the button shows how many sentences are due now; hidden when nothing is due and nothing is stored.
	var due_n: int = Store.due_count(l)
	if due_n > 0 or not Store.review_for(l).is_empty():
		var rb := UI.button("복습 %d개" % due_n, "soft", acc, 46.0)
		rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rb.custom_minimum_size.x = 140.0
		rb.pressed.connect(func() -> void: Store.navigate.emit("review", l))
		btns.add_child(rb)
	card.body.add_child(btns)

	var wi: int = 0
	var weeks: Array = m.get("weeks", [])
	for i in weeks.size():
		if weeks[i] == wk:
			wi = i
	var key: String = Store.check_key(l, n, "w", wi)
	# a check only dims its own label: the page is not rebuilt (the box under the finger stays)
	var holder: Array = []
	var chk := UI.check_row("이번 주 활동 끝냄", Store.is_checked(key), func(on: bool) -> void:
		Store.set_checked(key, on)
		_dim_check_label(holder[0], on))
	holder.append(chk)
	card.body.add_child(chk)

	# the day toggle: outlined when open, tonal with a check mark when done (never a second filled button)
	var done: bool = Store.did_day(Plan.today_days(), l)
	var db := UI.button(("오늘 %s 완료함  ✓" % NAME_KO[l]) if done else ("오늘 %s 공부 완료" % NAME_KO[l]), "soft" if done else "outline", acc, 46.0)
	db.pressed.connect(func() -> void:
		Store.toggle_today(l)
		refresh())
	card.body.add_child(db)

	card.body.add_child(_week_dots(l))
	return card


## UI.check_row puts the text label first in its second child; a done item reads muted.
func _dim_check_label(row: Control, on: bool) -> void:
	if row == null or not is_instance_valid(row) or row.get_child_count() < 2:
		return
	var col: Node = row.get_child(1)
	if col.get_child_count() == 0 or not (col.get_child(0) is Label):
		return
	var l: Label = col.get_child(0)
	if on:
		l.add_theme_color_override("font_color", Pal.MUTED)
	else:
		l.remove_theme_color_override("font_color")


## One row of the voice settings (kept here for the voice test; the settings screen builds it).
func _voice_row(l: String) -> Control:
	return SettingsView.voice_row(l)


func _week_dots(l: String) -> Control:
	var acc: Color = Pal.accent(l)
	var row := UI.hbox(6)
	var today: int = Plan.today_days()
	var mon: int = Plan.monday_of(today)
	for i in 7:
		var d: int = mon + i
		var col := UI.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var dot := PanelContainer.new()
		var on: bool = Store.did_day(d, l)
		# done = filled, not done = an outline only: the shape differs, not just the colour
		dot.add_theme_stylebox_override("panel", UI.style(acc, Color(0, 0, 0, 0), 0, 4, 0, 0) if on else UI.style(Color(0, 0, 0, 0), Pal.LINE_STRONG, 2, 4, 0, 0))
		dot.custom_minimum_size = Vector2(0, 8)
		col.add_child(dot)
		var wl := Label.new()
		wl.text = WD[Plan.weekday(d)]
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wl.add_theme_font_size_override("font_size", UI.fs(12))
		wl.add_theme_color_override("font_color", Pal.INK if d == today else Pal.MUTED)
		if d == today:
			wl.add_theme_font_override("font", UI.bold_font())
		col.add_child(wl)
		row.add_child(col)
	return row
