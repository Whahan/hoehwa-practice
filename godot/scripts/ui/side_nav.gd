class_name SideNav
extends PanelContainer
## Left navigation of the PC layout (docs/ui_redesign_design.md §4.2, §6.7). main.gd connects it in W4; this part
## only draws and reports: it never changes the screen itself (`set_current` is called by the shell).
##
## 224 px wide, background SURFACE_HI, hairline on the right. Top: the app name; below it the sections with their
## items (44 px high, text only, no icons); at the bottom a footer slot (ConnChip, phone-link chip) and the
## optional "설정" item. Selected = PRIMARY_SOFT pill with bold PRIMARY text (three cues: fill, weight, colour);
## hover = SUNK. The list scrolls when the window is too low for all items.

signal item_selected(key: String)

const WIDTH := 224.0
const ITEM_H := 44.0
const HEAD_H := 28.0
const SETTINGS_KEY := "settings"
const SETTINGS_LABEL := "설정"

var app_title: String = "회화 연습"

var _col: VBoxContainer
var _list: VBoxContainer
var _scroll: ScrollContainer
var _footer_slot: VBoxContainer
var _settings_btn: Button
var _footer: Control = null
var _items: Dictionary = {} ## key -> Button (the settings item included)
var _current: String = ""


func _init() -> void:
	custom_minimum_size.x = WIDTH
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := UI.style(Pal.SURFACE_HI, Pal.LINE, 0, 0, 12, 12)
	sb.border_width_right = 1
	add_theme_stylebox_override("panel", sb)
	_col = VBoxContainer.new()
	_col.add_theme_constant_override("separation", 8)
	add_child(_col)
	var title := UI.label(app_title, "H3", false)
	title.custom_minimum_size.y = 40
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_col.add_child(UI.margin(title, 16, 0, 8, 0))
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	_scroll.add_child(_list)
	_footer_slot = VBoxContainer.new()
	_footer_slot.add_theme_constant_override("separation", 4)
	_col.add_child(_footer_slot)
	_settings_btn = _make_item(SETTINGS_KEY, SETTINGS_LABEL)
	_settings_btn.visible = false
	_footer_slot.add_child(_settings_btn)


## sections = [{"title": String, "items": [[key, label], ...]}, ...]; a title of "" has no header line.
func set_items(sections: Array) -> void:
	UI.clear(_list)
	var keep: Button = _items.get(SETTINGS_KEY, null)
	_items = {}
	if keep != null:
		_items[SETTINGS_KEY] = keep
	var first := true
	for sec in sections:
		if not (sec is Dictionary):
			continue
		var st: String = str((sec as Dictionary).get("title", ""))
		if st != "":
			var head := UI.label(st, "Eyebrow", false)
			head.custom_minimum_size.y = HEAD_H
			head.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			_list.add_child(UI.margin(head, 16, 8 if first else 16, 8, 4))
		first = false
		for it in (sec as Dictionary).get("items", []):
			if not (it is Array) or (it as Array).size() < 2:
				continue
			var key: String = str((it as Array)[0])
			if key == "":
				continue
			var b := _make_item(key, str((it as Array)[1]))
			_list.add_child(b)
			_items[key] = b
	_style_all()


func set_current(key: String) -> void:
	_current = key
	_style_all()


func current() -> String:
	return _current


## The control at the bottom (ConnChip, phone link chip). Replaces an earlier one (which is not freed).
func set_footer(c: Control) -> void:
	if _footer != null and is_instance_valid(_footer) and _footer.get_parent() == _footer_slot:
		_footer_slot.remove_child(_footer)
	_footer = c
	if c == null:
		return
	if c.get_parent() != null:
		c.get_parent().remove_child(c)
	_footer_slot.add_child(c)
	_footer_slot.move_child(c, 0)


## Shows or hides the "설정" item at the bottom (hidden until the settings screen exists).
func set_settings_visible(v: bool) -> void:
	_settings_btn.visible = v


## key -> Button of every item (tests look at their look and click them).
func item_buttons() -> Dictionary:
	return _items


func _make_item(key: String, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.custom_minimum_size.y = ITEM_H
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(func() -> void: item_selected.emit(key))
	_items[key] = b
	_style_item(b, false)
	return b


func _style_all() -> void:
	for k in _items.keys():
		_style_item(_items[k] as Button, str(k) == _current)


func _style_item(b: Button, selected: bool) -> void:
	var clear := Color(0, 0, 0, 0)
	var normal := UI.style(Pal.PRIMARY_SOFT if selected else clear, clear, 0, Ds.R_INPUT, 16, 6)
	var hover := UI.style(Pal.PRIMARY_SOFT if selected else Pal.SUNK, clear, 0, Ds.R_INPUT, 16, 6)
	for n in ["normal", "focus", "disabled"]:
		b.add_theme_stylebox_override(n, normal)
	for n in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(n, hover)
	var fg: Color = Pal.PRIMARY if selected else Pal.INK
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(n, fg)
	if selected:
		b.add_theme_font_override("font", UI.bold_font())
	else:
		b.remove_theme_font_override("font")
