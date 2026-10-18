class_name ListGroup
extends CardBox
## One card holding several rows (settings, menus, lists), docs/ui_redesign_design.md §6.4. The "Group" theme variation
## draws the card (radius 24, no outline); rows are 56 px high (72 with a second line), their text starts 16 px
## inside the card, and a 1 px divider (indented 16) sits between neighbours, none after the last row.
##
## Touch: a tappable row uses UI.on_tap (phone: fires when the finger is lifted within PhoneLayout.TAP_SLOP, so a
## drag that starts on the row scrolls the page instead). The row shows a SUNK highlight while hovered (PC) or
## pressed; a scroll that starts cancels the highlight. A BaseButton inside a row (the switch) handles its own tap;
## tapping the rest of the row toggles it.

const ROW_H := 56.0
const ROW_H_SUB := 72.0
const PAD_X := 16

var _count: int = 0 ## children of the body (rows + custom) so far; a divider goes in front of every one but the first


func _init() -> void:
	super()
	theme_type_variation = &"Group"
	body.add_theme_constant_override("separation", 0)


## A row: `main` (one line, trimmed with an ellipsis) over an optional `sub` line, `trailing` at the right end.
## `on_tap` (valid Callable) makes the whole row pressable. `danger` colours the main text BAD_ON.
## An empty `main` adds nothing and returns null (with a warning).
func add_row(main: String, sub: String = "", trailing: Control = null, on_tap: Callable = Callable(), danger: bool = false) -> Control:
	if main.strip_edges() == "":
		push_warning("ListGroup.add_row: empty main text, row not added")
		if trailing != null and trailing.get_parent() == null:
			trailing.queue_free()
		return null
	var row := _Row.new()
	row.custom_minimum_size.y = ROW_H_SUB if sub != "" else ROW_H
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.content.add_child(h)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ml := UI.label(main, "ListMain", false)
	ml.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	ml.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ml.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if danger:
		ml.add_theme_color_override("font_color", Pal.BAD_ON)
	col.add_child(ml)
	if sub != "":
		var sl := UI.label(sub, "ListSub")
		sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(sl)
	h.add_child(col)
	if trailing != null:
		trailing.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(trailing)
		if trailing is BaseButton:
			row.guard = trailing # a press on it is the button's own tap, not the row's
	if on_tap.is_valid():
		row.make_tappable()
		row.accessibility_name = main
		UI.on_tap(row, func() -> void:
			if not row.press_on_guard:
				on_tap.call())
	_append(row)
	return row


## A row that shows `value` (muted) and a chevron at the right; the whole row is pressable.
func add_value_row(main: String, value: String, on_tap: Callable) -> Control:
	var t := HBoxContainer.new()
	t.add_theme_constant_override("separation", 4)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if value != "":
		var vl := UI.label(value, "Muted", false)
		vl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		t.add_child(vl)
	var chev := GlyphIcon.new("chevron_right", 20.0, Pal.MUTED)
	chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.add_child(chev)
	return add_row(main, "", t, on_tap)


## On/off row bound to a pref key (the same keys as UI.pref_toggle / UI.pref_switch). Returns the switch.
func add_switch_row(main: String, sub: String, pref_key: String) -> CheckButton:
	var cb := UI.switch_button(Store.pref_bool(pref_key))
	cb.accessibility_name = main
	cb.toggled.connect(func(on: bool) -> void: Store.set_pref(pref_key, on))
	var row := add_row(main, sub, cb, func() -> void: cb.button_pressed = not cb.button_pressed)
	if row == null:
		cb.queue_free()
		return null
	return cb


## A checkbox row (UI.check_row inside the group). Returns the CheckBox.
func add_check_row(main: String, checked: bool, on_toggle: Callable, sub: String = "") -> CheckBox:
	var r := UI.check_row(main, checked, on_toggle, sub)
	add_custom(r)
	return r.get_child(0) as CheckBox


## Any control as a row of its own: same side padding, same divider rule.
func add_custom(c: Control) -> void:
	_append(UI.margin(c, PAD_X, 8, PAD_X, 8))


## Section heading above a group: SectionHeader text, `top` px above, 8 below, 8 at the left.
static func header(text: String, top: int = Ds.S6) -> Label:
	var l := UI.label(text, "SectionHeader", true)
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = float(top)
	sb.content_margin_bottom = 8.0
	l.add_theme_stylebox_override("normal", sb)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _append(c: Control) -> void:
	if _count > 0:
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", PAD_X)
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var line := ColorRect.new()
		line.color = Pal.LINE
		line.custom_minimum_size = Vector2(0, 1)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(line)
		body.add_child(m)
	body.add_child(c)
	_count += 1


## The row: an (initially hidden) highlight under a padded content box.
class _Row extends PanelContainer:
	var content: MarginContainer
	var _hi: Panel
	var _tappable: bool = false
	var _hover: bool = false
	var _down: bool = false
	## A BaseButton inside the row (the switch). With the phone touch hook it passes its press on to the row, so the
	## row must know the press landed on it: its own tap then stays quiet.
	var guard: Control = null
	var press_on_guard: bool = false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var wrap := MarginContainer.new()
		wrap.add_theme_constant_override("margin_left", 8)
		wrap.add_theme_constant_override("margin_right", 8)
		wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hi = Panel.new()
		_hi.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hi.add_theme_stylebox_override("panel", UI.style(Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_S, 0, 0))
		_hi.visible = false
		wrap.add_child(_hi)
		add_child(wrap)
		content = MarginContainer.new()
		content.add_theme_constant_override("margin_left", PAD_X)
		content.add_theme_constant_override("margin_right", PAD_X)
		content.add_theme_constant_override("margin_top", 8)
		content.add_theme_constant_override("margin_bottom", 8)
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(content)

	func make_tappable() -> void:
		_tappable = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(ev: InputEvent) -> void:
		if _tappable and ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := ev as InputEventMouseButton
			if mb.pressed:
				press_on_guard = guard != null and guard.get_global_rect().has_point(mb.global_position)
			_down = mb.pressed and not press_on_guard
			_refresh()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hover = _tappable and not Platform.is_phone()
		elif what == NOTIFICATION_MOUSE_EXIT or what == NOTIFICATION_SCROLL_BEGIN or what == NOTIFICATION_VISIBILITY_CHANGED:
			_hover = false
			_down = false
		else:
			return
		_refresh()

	func _refresh() -> void:
		if _hi != null:
			_hi.visible = _tappable and (_hover or _down)
