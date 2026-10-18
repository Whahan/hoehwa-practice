class_name AppBar
extends PanelContainer
## Fixed app bar of the phone (docs/ui_redesign_design.md §6.3): back button, small title, at most two text actions
## and a ConnChip. Its height is fixed (56 + the status bar inset), so the page below never changes size while the
## user scrolls; instead the small title fades in as the big PageHeader scrolls away (`collapse_t`) and a hairline
## appears once the page has been scrolled.
##
## It stays OUTSIDE the ScrollContainer. Every tappable part is a BaseButton or the ConnChip (UI.on_tap), so there is
## no press-time input code here (phone touch rule, §3.3). The PC does not use it (SideNav + PageHeader instead).

signal back_pressed
signal action_pressed(id: String)
signal chip_pressed

const BAR_H := 56.0
const MAX_ACTIONS := 2

var _pad: Control
var _row: HBoxContainer
var _left_pad: Control
var _back: Button
var _title: Label
var _actions_box: HBoxContainer
var _chip_slot: HBoxContainer
var _chip: Control = null
var _top_inset: float = 0.0
var _scroll: ScrollContainer = null
var _header: Control = null
var _line_alpha: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP # nothing may leak to the page below the bar
	add_theme_stylebox_override("panel", UI.style(Pal.BG, Color(0, 0, 0, 0), 0, 0, 0, 0))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_pad = Control.new()
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_pad)
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", Ds.S2)
	m.add_theme_constant_override("margin_right", Ds.S4)
	col.add_child(m)
	_row = HBoxContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_theme_constant_override("separation", 4)
	_row.custom_minimum_size.y = BAR_H
	m.add_child(_row)
	_back = _make_back()
	_row.add_child(_back)
	_left_pad = Control.new() # keeps the title 24 px from the edge while there is no back button
	_left_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_pad.custom_minimum_size.x = Ds.S4
	_row.add_child(_left_pad)
	_title = Label.new()
	_title.theme_type_variation = &"AppBarTitle"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.clip_text = true
	_row.add_child(_title)
	_actions_box = HBoxContainer.new()
	_actions_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_actions_box.add_theme_constant_override("separation", 0)
	_row.add_child(_actions_box)
	_chip_slot = HBoxContainer.new()
	_chip_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_chip_slot)
	set_page("", false, [])


func _make_back() -> Button:
	var b := Button.new()
	b.theme_type_variation = &"FlatButton"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(Ds.touch_min(), Ds.touch_min())
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.accessibility_name = "뒤로"
	b.tooltip_text = ""
	var icon := GlyphIcon.new("back", 24.0, Pal.INK)
	icon.anchor_left = 0.5
	icon.anchor_right = 0.5
	icon.anchor_top = 0.5
	icon.anchor_bottom = 0.5
	icon.offset_left = -12.0
	icon.offset_right = 12.0
	icon.offset_top = -12.0
	icon.offset_bottom = 12.0
	b.add_child(icon)
	b.pressed.connect(func() -> void: back_pressed.emit())
	return b


## Pixels of the status bar / notch above the bar (logical px).
func set_top_inset(px: float) -> void:
	_top_inset = maxf(0.0, px) if not is_nan(px) else 0.0
	_pad.custom_minimum_size.y = _top_inset


func top_inset() -> float:
	return _top_inset


## title: small title of the bar; back: show the back button; actions: [{"id": String, "text": String}], at most two
## (more are dropped with a warning).
func set_page(title: String, back: bool = false, actions: Array = []) -> void:
	_title.text = title
	_back.visible = back
	_left_pad.visible = not back
	UI.clear(_actions_box)
	var shown := 0
	for a in actions:
		if not (a is Dictionary):
			continue
		var id: String = str((a as Dictionary).get("id", ""))
		var text: String = str((a as Dictionary).get("text", ""))
		if text == "":
			continue
		if shown >= MAX_ACTIONS:
			push_warning("AppBar.set_page: only %d actions fit, '%s' dropped" % [MAX_ACTIONS, text])
			continue
		shown += 1
		_actions_box.add_child(_make_action(id, text))


func _make_action(id: String, text: String) -> Button:
	var b := UI.button(text, "flat", Pal.PRIMARY, Ds.touch_min())
	b.custom_minimum_size.x = Ds.touch_min()
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(n, Pal.PRIMARY)
	b.add_theme_font_override("font", UI.bold_font())
	b.pressed.connect(func() -> void: action_pressed.emit(id))
	return b


## The title text and the buttons, for tests and for the shell.
func title_label() -> Label:
	return _title


func back_button() -> Button:
	return _back


func action_buttons() -> Array:
	return _actions_box.get_children()


## Puts a ConnChip (or any control) at the right end. A ConnChip's `tapped` becomes `chip_pressed`.
func set_chip(c: Control) -> void:
	if _chip != null and is_instance_valid(_chip):
		if _chip.has_signal("tapped") and _chip.is_connected("tapped", _on_chip_tapped):
			_chip.disconnect("tapped", _on_chip_tapped)
		if _chip.get_parent() == _chip_slot:
			_chip_slot.remove_child(_chip)
	_chip = c
	if c == null:
		return
	if c.get_parent() != null:
		c.get_parent().remove_child(c)
	_chip_slot.add_child(c)
	if c.has_signal("tapped"):
		c.connect("tapped", _on_chip_tapped)


func _on_chip_tapped() -> void:
	chip_pressed.emit()


## Follows `sc`: the small title's alpha and the hairline are updated whenever it scrolls. `header` is the big
## title block (its height decides when the small title appears). A null `sc` makes the title always visible.
func bind_scroll(sc: ScrollContainer, header: Control) -> void:
	if _scroll != null and is_instance_valid(_scroll):
		var old: VScrollBar = _scroll.get_v_scroll_bar()
		if old.value_changed.is_connected(_on_scroll):
			old.value_changed.disconnect(_on_scroll)
	_scroll = sc if (sc != null and is_instance_valid(sc)) else null
	_header = header if (header != null and is_instance_valid(header)) else null
	if _scroll == null:
		_apply(1.0, 0.0)
		return
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll)
	_on_scroll(float(_scroll.scroll_vertical))


func _on_scroll(value: float) -> void:
	var h: float = 0.0
	if _header != null and is_instance_valid(_header):
		h = _header.size.y if _header.size.y > 0.0 else _header.get_combined_minimum_size().y
	_apply(collapse_t(value, h), 1.0 if value > 0.0 else 0.0)


func _apply(title_alpha: float, line_alpha: float) -> void:
	_title.modulate.a = title_alpha
	if not is_equal_approx(_line_alpha, line_alpha):
		_line_alpha = line_alpha
		queue_redraw()


## Alpha of the small title for a scroll position: 0 until the big title is half scrolled away, 1 when it is gone.
## An unknown header height (<= 0, NaN, infinite) means "no big title": 1. A NaN or negative scroll (overscroll) is 0.
static func collapse_t(scroll_y: float, header_h: float) -> float:
	if is_nan(header_h) or is_inf(header_h) or header_h <= 0.0:
		return 1.0
	if is_nan(scroll_y) or scroll_y < 0.0:
		return 0.0
	var half: float = 0.5 * header_h
	return clampf((scroll_y - half) / half, 0.0, 1.0)


func title_alpha() -> float:
	return _title.modulate.a


func line_alpha() -> float:
	return _line_alpha


func _draw() -> void:
	if _line_alpha > 0.0:
		draw_rect(Rect2(0.0, size.y - 1.0, size.x, 1.0), Color(Pal.LINE, _line_alpha))
