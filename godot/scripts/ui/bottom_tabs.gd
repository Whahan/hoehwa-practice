class_name BottomTabs
extends PanelContainer
## Phone tab bar at the bottom of the screen (docs/android_remote_design.md §5.1).
##
## `set_tabs([[key, label], ...])` takes the tab list of main.gd. Up to MAX_DIRECT tabs get their own cell.
## With more tabs the first MAX_DIRECT - 1 stay in the bar and the rest move into a "더보기" sheet that
## slides over the page, so 7 or 8 tabs (English v1.1 adds 연습 and 기록) never get narrower than 58 px.
## Every cell is at least 48 x 56 px; the bar adds `set_bottom_inset()` px below for the gesture bar.

signal tab_selected(key: String)
signal more_toggled(is_open: bool)

const MAX_DIRECT := 6
const MORE_LABEL := "더보기"

var _tabs: Array = []
var _current: String = ""
var _short: Dictionary = {}
var _cells: Dictionary = {}   ## key -> Button of a tab that sits in the bar
var _more_btn: Button
var _row: HBoxContainer
var _margin: MarginContainer
var _layer: CanvasLayer = null
var _sheet: Control = null


func _init() -> void:
	add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0))
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
	return _sheet != null and is_instance_valid(_sheet)


func _direct_count() -> int:
	return _tabs.size() if _tabs.size() <= MAX_DIRECT else MAX_DIRECT - 1


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
	if _tabs.size() > MAX_DIRECT:
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
	return b


func _cell_styles(b: Button, selected: bool) -> void:
	var sn := UI.style(Color(0, 0, 0, 0), Pal.INK if selected else Color(0, 0, 0, 0), 0, 0, 2, 6)
	sn.border_width_top = 3
	var sp := UI.style(Pal.SUNK, Pal.INK if selected else Color(0, 0, 0, 0), 0, 0, 2, 6)
	sp.border_width_top = 3
	for n in ["normal", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, sn)
	for n in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(n, sp)
	var col: Color = Pal.INK if selected else Pal.MUTED
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(n, col)
	b.add_theme_font_size_override("font_size", 14)
	if selected:
		b.add_theme_font_override("font", UI.bold_font())
	else:
		b.remove_theme_font_override("font")


func _style_cells() -> void:
	for k in _cells.keys():
		_cell_styles(_cells[k] as Button, k == _current)
	if _more_btn != null:
		_cell_styles(_more_btn, overflow_keys().has(_current) or is_more_open())


# ---------------------------------------------------------------- "더보기" sheet

func toggle_more() -> void:
	if is_more_open():
		close_more()
	else:
		open_more()


func open_more() -> void:
	if overflow_keys().is_empty() or is_more_open() or not is_inside_tree():
		return
	_layer = CanvasLayer.new()
	_layer.layer = 16
	add_child(_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.25)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			close_more())
	root.add_child(dim)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, Pal.LINE, 1, 0, 8, 8))
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	panel.add_child(v)
	for i in range(_direct_count(), _tabs.size()):
		var t: Array = _tabs[i]
		var key: String = str(t[0])
		var b := UI.button(str(t[1]), "flat", Pal.INK, PhoneLayout.TAB_H)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 17)
		if key == _current:
			b.add_theme_font_override("font", UI.bold_font())
			b.add_theme_color_override("font_color", Pal.INK)
		b.pressed.connect(func() -> void:
			close_more()
			tab_selected.emit(key))
		v.add_child(b)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_bottom = -size.y
	panel.offset_top = panel.offset_bottom - panel.get_combined_minimum_size().y
	_sheet = root
	_style_cells()
	more_toggled.emit(true)


func close_more() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	var was_open: bool = _sheet != null
	_sheet = null
	if was_open:
		_style_cells()
		more_toggled.emit(false)
