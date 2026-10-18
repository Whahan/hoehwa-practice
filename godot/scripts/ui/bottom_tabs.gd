class_name BottomTabs
extends PanelContainer
## Phone tab bar at the bottom of the screen (docs/android_remote_design.md §5.1).
##
## `set_tabs([[key, label], ...])` takes the tab list of main.gd. Up to MAX_DIRECT tabs get their own cell.
## With more tabs the first MAX_DIRECT - 1 stay in the bar and the rest move into a "더보기" sheet that
## slides over the page, so 7 or 8 tabs (English v1.1 adds 연습 and 기록) never get narrower than 58 px.
## Every cell is at least 48 x 56 px; the bar adds `set_bottom_inset()` px below for the gesture bar.
##
## Look (docs/ui_redesign_design.md §6.7): SURFACE bar with a hairline on top, text only (no icons). The selected cell
## says so three ways: PRIMARY colour, bold weight and a small 20 x 3 pill under the text. `max_direct` stays 6 here;
## the shell switches it to 5 (4 tabs + 더보기) when it is connected. The "더보기" list is a Sheet.choice.

signal tab_selected(key: String)
signal more_toggled(is_open: bool)

const MAX_DIRECT := 6
const MORE_LABEL := "더보기"
const MARK_W := 20.0
const MARK_H := 3.0
const BADGE := 8.0

## Cells that get their own place in the bar; with more tabs the first max_direct - 1 stay and the rest go to the sheet.
var max_direct: int = MAX_DIRECT:
	set(v):
		max_direct = maxi(2, v)
		if not _tabs.is_empty():
			_rebuild()

var _tabs: Array = []
var _current: String = ""
var _short: Dictionary = {}
var _cells: Dictionary = {}   ## key -> Button of a tab that sits in the bar
var _more_btn: Button
var _row: HBoxContainer
var _margin: MarginContainer
var _sheet: Sheet = null
var _badges: Dictionary = {}  ## key -> bool


func _init() -> void:
	add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0))
	mouse_filter = Control.MOUSE_FILTER_STOP
	_margin = MarginContainer.new()
	_margin.add_theme_constant_override("margin_left", 0)
	_margin.add_theme_constant_override("margin_right", 0)
	_margin.add_theme_constant_override("margin_top", 0)
	_margin.add_theme_constant_override("margin_bottom", 0)
	add_child(_margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	_margin.add_child(col)
	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 1)
	col.add_child(line)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 0)
	col.add_child(_row)


## Gap below the cells (gesture bar / rounded corners), logical px.
func set_bottom_inset(px: float) -> void:
	_margin.add_theme_constant_override("margin_bottom", int(ceilf(px)))


func set_side_inset(left: float, right: float) -> void:
	_margin.add_theme_constant_override("margin_left", int(ceilf(left)))
	_margin.add_theme_constant_override("margin_right", int(ceilf(right)))


## tabs = [[key, label], ...]; `short` = {key: label for the narrow cell} (e.g. "talk" -> "대화").
func set_tabs(tabs: Array, short: Dictionary = {}) -> void:
	_tabs = tabs.duplicate()
	_short = short
	_rebuild()


func set_current(key: String) -> void:
	_current = key
	_style_cells()


## Tabs that did not fit into the bar (shown in the "더보기" sheet).
func overflow_keys() -> Array:
	var out: Array = []
	for i in range(_direct_count(), _tabs.size()):
		out.append(str((_tabs[i] as Array)[0]))
	return out


func direct_keys() -> Array:
	var out: Array = []
	for i in _direct_count():
		out.append(str((_tabs[i] as Array)[0]))
	return out


func cell_buttons() -> Array:
	var out: Array = []
	for c in _row.get_children():
		out.append(c)
	return out


func is_more_open() -> bool:
	return _sheet != null and is_instance_valid(_sheet) and not _sheet.is_closed()


## A small dot on a tab (e.g. reviews are due). Off by default.
func set_badge(key: String, on: bool) -> void:
	_badges[key] = on
	_style_cells()


func _direct_count() -> int:
	return _tabs.size() if _tabs.size() <= max_direct else max_direct - 1


func _label_of(t: Array) -> String:
	return str(_short.get(str(t[0]), t[1]))


func _rebuild() -> void:
	close_more()
	UI.clear(_row)
	_cells = {}
	_more_btn = null
	for i in _direct_count():
		var t: Array = _tabs[i]
		var b := _make_cell(_label_of(t))
		var key: String = str(t[0])
		b.pressed.connect(func() -> void: tab_selected.emit(key))
		_cells[key] = b
		_row.add_child(b)
	if _tabs.size() > max_direct:
		_more_btn = _make_cell(MORE_LABEL)
		_more_btn.pressed.connect(toggle_more)
		_row.add_child(_more_btn)
	_style_cells()


func _make_cell(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.custom_minimum_size = Vector2(48, PhoneLayout.TAB_H)
	b.accessibility_name = text
	# the pill under the selected text and the badge dot never take a click
	var mark := Panel.new()
	mark.name = "Mark"
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.anchor_left = 0.5
	mark.anchor_right = 0.5
	mark.anchor_top = 1.0
	mark.anchor_bottom = 1.0
	mark.offset_left = -MARK_W * 0.5
	mark.offset_right = MARK_W * 0.5
	mark.offset_top = -MARK_H - 7.0
	mark.offset_bottom = -7.0
	mark.visible = false
	b.add_child(mark)
	var dot := Panel.new()
	dot.name = "Badge"
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.anchor_left = 0.5
	dot.anchor_right = 0.5
	dot.offset_left = 14.0
	dot.offset_right = 14.0 + BADGE
	dot.offset_top = 9.0
	dot.offset_bottom = 9.0 + BADGE
	dot.visible = false
	b.add_child(dot)
	return b


func _cell_styles(b: Button, selected: bool, key: String = "") -> void:
	var clear := Color(0, 0, 0, 0)
	# room under the text for the pill: the text sits a little above the middle of the 56 px cell
	var sn := UI.style(clear, clear, 0, Ds.R_S, 2, 6)
	sn.content_margin_bottom = 12
	var sp := UI.style(Pal.SUNK, clear, 0, Ds.R_S, 2, 6)
	sp.content_margin_bottom = 12
	for n in ["normal", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, sn)
	for n in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(n, sp)
	var col: Color = Pal.PRIMARY if selected else Pal.MUTED
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(n, col)
	b.add_theme_font_size_override("font_size", Ds.fs(14))
	if selected:
		b.add_theme_font_override("font", UI.bold_font())
	else:
		b.remove_theme_font_override("font")
	var mark := b.get_node_or_null("Mark") as Panel
	if mark != null:
		mark.visible = selected
		mark.add_theme_stylebox_override("panel", UI.style(Pal.PRIMARY, clear, 0, Ds.R_PILL, 0, 0))
	var dot := b.get_node_or_null("Badge") as Panel
	if dot != null:
		dot.visible = key != "" and bool(_badges.get(key, false))
		dot.add_theme_stylebox_override("panel", UI.style(Pal.BAD, clear, 0, Ds.R_PILL, 0, 0))


func _style_cells() -> void:
	for k in _cells.keys():
		_cell_styles(_cells[k] as Button, k == _current, str(k))
	if _more_btn != null:
		var hidden_badge := false
		for ok in overflow_keys():
			hidden_badge = hidden_badge or bool(_badges.get(ok, false))
		_cell_styles(_more_btn, overflow_keys().has(_current) or is_more_open())
		var bd := _more_btn.get_node_or_null("Badge") as Panel
		if bd != null:
			bd.visible = hidden_badge


# ---------------------------------------------------------------- "더보기" sheet

func toggle_more() -> void:
	if is_more_open():
		close_more()
	else:
		open_more()


func open_more() -> void:
	if overflow_keys().is_empty() or is_more_open() or not is_inside_tree():
		return
	var items: Array = []
	for i in range(_direct_count(), _tabs.size()):
		var t: Array = _tabs[i]
		items.append([str(t[0]), str(t[1])])
	_sheet = Sheet.choice(self, MORE_LABEL, items, _current)
	_sheet.closed.connect(_on_sheet_closed)
	_style_cells()
	more_toggled.emit(true)


func close_more() -> void:
	if _sheet != null and is_instance_valid(_sheet) and not _sheet.is_closed():
		_sheet.close("dismiss") # -> _on_sheet_closed
	_sheet = null


func _on_sheet_closed(result: Variant) -> void:
	_sheet = null
	_style_cells()
	more_toggled.emit(false)
	# a picked tab (not "dismiss"): the sheet is closed first, then the tab changes (as before)
	var key: String = str(result)
	if key != "dismiss" and not overflow_keys().is_empty() and overflow_keys().has(key):
		tab_selected.emit(key)
