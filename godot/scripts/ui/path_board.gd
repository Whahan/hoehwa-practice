class_name PathBoard
extends Container
## One month (4 nodes = 4 weeks) of the lesson path (docs/home_menu_design.md §7.3, §7.4, §9.8).
##
## Lays out its own children (no fixed positions in a scene): the nodes swing left and right along a thick line, every
## node has a name tag. Phone: the tag is centred under the node (two lines, then an ellipsis). PC: the tag stands to the
## right of the node and the path is at most Ds.PATH_COL_W_PC wide, centred. The current node is bigger and carries a
## small "지금" chip. Heights do not depend on the width, so the page never re-flows twice.
## Also the home of the small static parts the lesson home needs: month_header, dots, detail_body (node sheet text).

signal node_pressed(n: int, w: int, state: String)

const WAVE := [0.0, 0.9, 0.0, -0.9] ## sideways swing per week, times the amplitude (the same in every month)
const AMP_PC := 120.0
const LABEL_W_PHONE := 220.0 ## widest name tag on the phone (a longer text wraps to two lines, then an ellipsis)
const LABEL_W_PC := 200.0
const TAG_PAD_H := 6.0 ## name tags sit on a page-coloured pill so the thick line never runs through the text
const TAG_PAD_V := 1.0
const PAD_TOP := 6.0
const GAP_CHIP := 4.0
const GAP_ROW := 14.0

static var _tag_styles: Dictionary = {}

var lang: String = "en"
var month_n: int = 1
var states: Array = []
var current_idx: int = -1 ## global cell index of the current cell (-1 = none known)

var _nodes: Array = [] ## 4 PathNode
var _labels: Array = [] ## 4 Label
var _chip: Control = null ## the "지금" chip, null when no node of this month is current
var _chip_week: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


## `states`: the 4 states of this month ("done|current|open|past|locked", missing = locked); `names`: the 4 week topics
## ("" = none: the tag is just "2주"); `current_global_idx`: cell index of the current cell of the whole path.
func build(lang_: String, month_n_: int, states_: Array, names_: Array, current_global_idx: int) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_nodes.clear()
	_labels.clear()
	_chip = null
	_chip_week = 0
	lang = lang_
	month_n = clampi(month_n_, 1, PathModel.MONTHS)
	current_idx = current_global_idx
	states = []
	var phone: bool = Platform.is_phone()
	for k in PathModel.WEEKS:
		var w: int = k + 1
		var st: String = str(states_[k]) if k < states_.size() else "locked"
		if not PathNode.STATES.has(st):
			st = "locked"
		states.append(st)
		var node := PathNode.new(month_n, w, st)
		node.pressed.connect(func() -> void: node_pressed.emit(month_n, w, st))
		add_child(node)
		_nodes.append(node)
		var topic: String = UI.plain(names_[k]) if k < names_.size() else ""
		var txt: String = "%d주" % w if topic == "" else "%d주 · %s" % [w, topic]
		var lab := UI.label(txt, "Small")
		lab.max_lines_visible = 2
		lab.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if phone else HORIZONTAL_ALIGNMENT_LEFT
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lab.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		lab.add_theme_stylebox_override("normal", _tag_style())
		match st:
			"past", "locked":
				lab.add_theme_color_override("font_color", Pal.MUTED)
			"current":
				lab.add_theme_color_override("font_color", Pal.INK)
				lab.add_theme_font_override("font", UI.bold_font())
			_:
				lab.add_theme_color_override("font_color", Pal.INK)
		add_child(lab)
		_labels.append(lab)
		if st == "current" and _chip == null:
			_chip = UI.chip("지금", Pal.REWARD_ON, Pal.REWARD_SOFT)
			_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_chip_week = w
			add_child(_chip)
	update_minimum_size()
	queue_sort()
	queue_redraw()


## 4 PathNode buttons' global rectangles in week order.
func node_rects() -> Array:
	var out: Array = []
	for n in _nodes:
		out.append((n as Control).get_global_rect())
	return out


## The node button of week w (1..4); null outside.
func node_button(w: int) -> Button:
	if w < 1 or w > _nodes.size():
		return null
	return _nodes[w - 1] as Button


## Name tag of week w (1..4); null outside.
func label_of(w: int) -> Label:
	if w < 1 or w > _labels.size():
		return null
	return _labels[w - 1] as Label


## Global rectangle of the name tag of week w; an empty Rect2 outside.
func label_rect(w: int) -> Rect2:
	var l := label_of(w)
	return l.get_global_rect() if l != null else Rect2()


func chip_rect() -> Rect2:
	return _chip.get_global_rect() if _chip != null else Rect2()


# ---------------------------------------------------------------- layout

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_layout()


func _get_minimum_size() -> Vector2:
	var rows: Dictionary = _rows(Platform.is_phone())
	return Vector2(Ds.NODE_D_CUR + 16.0, float(rows["total"]))


## Height of a two-line name tag.
func _label_h() -> float:
	var lh: float = 0.0
	for l in _labels:
		lh = maxf(lh, float((l as Label).get_line_height()))
	if lh <= 0.0:
		lh = float(Ds.fs(14)) * 1.3
	return ceilf(lh) * 2.0 + 2.0 * TAG_PAD_V + 2.0


## Size of the name tag of label `lab` when it may be `max_w` wide: as narrow as its text (one line) or `max_w` (two lines).
func _tag_size(lab: Label, max_w: float) -> Vector2:
	var f: Font = lab.get_theme_font("font")
	var fsz: int = lab.get_theme_font_size("font_size")
	var tw: float = ceilf(f.get_string_size(lab.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x) + 2.0 * TAG_PAD_H + 2.0
	var lines: float = 1.0 if tw <= max_w else 2.0
	return Vector2(minf(tw, max_w), ceilf(lab.get_line_height()) * lines + 2.0 * TAG_PAD_V + 2.0)


func _chip_h() -> float:
	return maxf(28.0, ceilf(_chip.get_combined_minimum_size().y)) if _chip != null else 0.0


## Row geometry that does not depend on the width: {"total", "top": [y], "h": [height], "d": [diameter]}.
func _rows(phone: bool) -> Dictionary:
	var tops: Array = []
	var hs: Array = []
	var ds: Array = []
	var y: float = PAD_TOP
	var lab_h: float = _label_h()
	var chip_h: float = _chip_h()
	for k in _nodes.size():
		var cur: bool = states[k] == "current"
		var d: float = Ds.NODE_D_CUR if cur else Ds.NODE_D
		var h: float
		if phone:
			h = d + 4.0 + lab_h + GAP_ROW + ((chip_h + GAP_CHIP) if cur else 0.0)
		else:
			var block: float = lab_h + ((chip_h + GAP_CHIP) if cur else 0.0)
			h = maxf(Ds.NODE_STRIDE_PC, maxf(block, d) + GAP_ROW)
		tops.append(y)
		hs.append(h)
		ds.append(d)
		y += h
	return {"total": y, "top": tops, "h": hs, "d": ds}


func _layout() -> void:
	if _nodes.is_empty():
		return
	var phone: bool = Platform.is_phone()
	var rows: Dictionary = _rows(phone)
	var w_all: float = size.x
	var label_w: float
	var amp: float
	var cx0: float
	if phone:
		label_w = minf(LABEL_W_PHONE, maxf(w_all - 16.0, 0.0))
		amp = clampf(w_all * 0.5 - Ds.NODE_D_CUR * 0.5 - 4.0, 0.0, Ds.NODE_AMP_MAX)
		cx0 = w_all * 0.5
	else:
		var col_w: float = minf(w_all, Ds.PATH_COL_W_PC)
		var x_off: float = (w_all - col_w) * 0.5
		label_w = clampf(col_w - 98.0, 100.0, LABEL_W_PC)
		var left: float = 8.0 + Ds.NODE_D_CUR * 0.5
		var right: float = maxf(left, col_w - label_w - 10.0 - Ds.NODE_D_CUR * 0.5 - 8.0)
		amp = minf((right - left) * 0.5, AMP_PC)
		cx0 = x_off + (left + right) * 0.5
	var chip_h: float = _chip_h()
	for k in _nodes.size():
		var node: Control = _nodes[k]
		var lab: Control = _labels[k]
		var d: float = float(rows["d"][k])
		var top: float = float(rows["top"][k])
		var h: float = float(rows["h"][k])
		var cur: bool = states[k] == "current"
		var cx: float = cx0 + amp * float(WAVE[k % WAVE.size()])
		var cy: float = top + d * 0.5 if phone else top + h * 0.5
		fit_child_in_rect(node, Rect2(cx - d * 0.5, cy - d * 0.5, d, d))
		var chip_here: bool = cur and _chip != null and _chip_week == k + 1
		if phone:
			var ly: float = top + d + 4.0
			if chip_here:
				var cw: float = _chip.get_combined_minimum_size().x
				fit_child_in_rect(_chip, Rect2(cx - cw * 0.5, top + d + 2.0, cw, chip_h))
				ly += chip_h + GAP_CHIP
			var ts: Vector2 = _tag_size(lab as Label, label_w)
			var tx: float = clampf(cx - ts.x * 0.5, 0.0, maxf(w_all - ts.x, 0.0))
			fit_child_in_rect(lab, Rect2(tx, ly, ts.x, ts.y))
		else:
			var ts2: Vector2 = _tag_size(lab as Label, label_w)
			var block: float = ts2.y + ((chip_h + GAP_CHIP) if chip_here else 0.0)
			var lx: float = cx + d * 0.5 + 10.0
			var ly2: float = cy - block * 0.5
			if chip_here:
				var cw2: float = _chip.get_combined_minimum_size().x
				fit_child_in_rect(_chip, Rect2(lx, ly2, cw2, chip_h))
				ly2 += chip_h + GAP_CHIP
			fit_child_in_rect(lab, Rect2(lx, ly2, ts2.x, ts2.y))
	queue_redraw()


func _draw() -> void:
	# the thick line behind the nodes: PRIMARY from a finished node on to the next finished / current one, else LINE
	for k in range(0, _nodes.size() - 1):
		var a: Control = _nodes[k]
		var b: Control = _nodes[k + 1]
		var lit: bool = states[k] == "done" and (states[k + 1] == "done" or states[k + 1] == "current")
		var col: Color = Pal.PRIMARY if lit else Pal.LINE
		var pa: Vector2 = a.position + a.size * 0.5
		var pb: Vector2 = b.position + b.size * 0.5
		draw_line(pa, pb, col, Ds.PATH_TRACK_W, true)
		draw_circle(pa, Ds.PATH_TRACK_W * 0.5, col)
		draw_circle(pb, Ds.PATH_TRACK_W * 0.5, col)


# ---------------------------------------------------------------- static parts

## The pill behind a name tag (shared by all tags of a colour scheme; never edited afterwards).
static func _tag_style() -> StyleBoxFlat:
	var k: String = Pal.BG.to_html()
	if not _tag_styles.has(k):
		_tag_styles[k] = UI.style(Pal.BG, Color(0, 0, 0, 0), 0, Ds.R_S, int(TAG_PAD_H), int(TAG_PAD_V))
	return _tag_styles[k]


## "주제" text of a week from the curriculum; "" when the curriculum has none (empty curriculum, a month with 3 weeks).
static func topic_of(l: String, n: int, w: int) -> String:
	var m: Dictionary = _month(l, n)
	var weeks: Variant = m.get("weeks", [])
	if not (weeks is Array) or w < 1 or w > (weeks as Array).size():
		return ""
	var wk: Variant = (weeks as Array)[w - 1]
	return UI.plain((wk as Dictionary).get("topic", "")) if wk is Dictionary else ""


## Title of month n from the curriculum; "" when missing (never another month's title).
static func month_title_of(l: String, n: int) -> String:
	return UI.plain(_month(l, n).get("title", ""))


static func _month(l: String, n: int) -> Dictionary:
	for m in Store.months(l):
		if m is Dictionary and int((m as Dictionary).get("n", 0)) == n:
			return m
	return {}


## Month heading row: "3개월차 · title" on the left, a star and "완료 k/4주" on the right (the star is filled when all
## weeks are done, an outline otherwise).
static func month_header(n: int, title: String, done_k: int, total: int = PathModel.WEEKS) -> Control:
	var row := UI.hbox(8)
	row.name = "MonthHeader%d" % n
	var txt: String = "%d개월차" % n if title == "" else "%d개월차 · %s" % [n, title]
	var l := UI.label(txt, "H3")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	var right := UI.hbox(6)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var all_done: bool = done_k >= total
	var star := _Star.new(22.0, all_done)
	star.accessibility_name = "별 채움" if all_done else "별 비어 있음"
	right.add_child(star)
	var cnt := UI.label("완료 %d/%d주" % [done_k, total], "Small", false)
	cnt.add_theme_color_override("font_color", Pal.REWARD_ON if all_done else Pal.MUTED)
	right.add_child(cnt)
	row.add_child(right)
	return row


## Row of `goal` dots, `done_n` of them filled (a shape cue: filled / ring). Display only.
static func dots(done_n: int, goal: int = PathModel.NODE_GOAL, d: float = 14.0) -> Control:
	return _Dots.new(done_n, goal, d)


## Body of the node sheet (§7.5): the week topic, "레슨 k/5" with dots and the weekly check "이번 주 활동 끝냄"
## (Store.set_checked on the same key as the roadmap and the old 오늘 card). The buttons are the sheet's.
static func detail_body(l: String, n: int, w: int, state: String) -> Control:
	var col := UI.vbox(10)
	col.name = "NodeDetail"
	var topic: String = topic_of(l, n, w)
	if topic != "":
		col.add_child(UI.label("주제: %s" % topic))
	var goal: int = PathModel.NODE_GOAL
	var cnt: int = clampi(StudyLog.path_done(l, n, w), 0, goal)
	var row := UI.hbox(10)
	var cl := UI.label("레슨 %d/%d" % [cnt, goal], "Strong", false)
	cl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(cl)
	var dt := dots(cnt, goal)
	dt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dt)
	col.add_child(row)
	if state == "past":
		col.add_child(UI.label("건너뛴 칸이에요. 지금 해도 괜찮아요.", "Muted"))
	var key: String = Store.check_key(l, n, "w", w - 1)
	col.add_child(UI.check_row("이번 주 활동 끝냄", Store.is_checked(key), func(on: bool) -> void: Store.set_checked(key, on)))
	return col


# ---------------------------------------------------------------- small drawn parts

class _Dots extends Control:
	var done_n: int = 0
	var goal: int = 5
	var dia: float = 14.0

	func _init(done_: int, goal_: int, d_: float) -> void:
		goal = maxi(goal_, 1)
		done_n = clampi(done_, 0, goal)
		dia = d_
		custom_minimum_size = Vector2(float(goal) * (dia + 6.0) - 6.0, dia)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		accessibility_name = "%d/%d" % [done_n, goal]

	func _draw() -> void:
		var r: float = dia * 0.5
		for i in goal:
			var c := Vector2(r + float(i) * (dia + 6.0), size.y * 0.5)
			if i < done_n:
				draw_circle(c, r, Pal.PRIMARY)
			else:
				draw_arc(c, r - 1.0, 0.0, TAU, 24, Pal.LINE_STRONG, 2.0, true)


class _Star extends Control:
	var filled: bool = false
	var px: float = 22.0

	func _init(px_: float, filled_: bool) -> void:
		px = px_
		filled = filled_
		custom_minimum_size = Vector2(px, px)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		if s <= 0.0:
			s = px
		var o := Vector2((size.x - s) * 0.5, (size.y - s) * 0.5)
		var c := o + Vector2(0.5, 0.54) * s
		var pts := PackedVector2Array()
		for i in 10:
			var r: float = (0.47 if i % 2 == 0 else 0.2) * s
			var a: float = -PI * 0.5 + float(i) * PI / 5.0
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		if filled:
			draw_colored_polygon(pts, Pal.REWARD)
		else:
			pts.append(pts[0])
			draw_polyline(pts, Pal.MUTED, 2.0, true)
