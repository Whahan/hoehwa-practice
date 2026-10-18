class_name ToastHost
extends CanvasLayer
## Toast / snack bar overlay on layer 30 (docs/ui_redesign_design.md §6.6). It takes over the toast code of main.gd
## (W4 connects it): `show_message(text, kind)` for Toast.message, with an action for Toast.snack.
##
## At most 3 lines of text, then an ellipsis. Width: phone = screen - 32 (at most 420), PC = 420. An error is not
## told by its colour alone: a bold "! " stands before the text (only when it is shown; the Toast.message signal
## text is never changed). It lives 3.5 s (info / ok) or 6 s (error, or a message with an action). The toast
## itself ignores the mouse; only the action button is tappable (a BaseButton, so a scroll drag is never an action).
## Light scheme: a soft shadow; dark scheme: none (the "Toast" theme variation decides, as there is no dim here).

const LAYER := 30
const MAX_W := 420.0
const MAX_LINES := 3
const PAD_X := 18.0
const FADE_IN := 0.15
const FADE_OUT := 0.4
const SHORT_SEC := 3.5
const LONG_SEC := 6.0

var box: PanelContainer       ## the visible toast (tests / shots set .visible = false)
var label: Label              ## the message text, at most MAX_LINES lines
var mark: Label               ## "! " in front of an error
var action_button: Button     ## right-hand action of a snack bar (hidden without an action)
var kind: String = "info"

var _root: Control
var _gap: Control
var _row: HBoxContainer
var _tween: Tween = null
var _action: Callable = Callable()
var _gap_px: float = 28.0


func _init() -> void:
	layer = LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_END
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 0)
	_root.add_child(v)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(h)
	_gap = Control.new()
	_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_gap)
	_gap_px = 12.0 + PhoneLayout.TAB_H if Platform.is_phone() else 28.0
	_gap.custom_minimum_size.y = _gap_px

	box = PanelContainer.new()
	box.name = "ToastBox"
	box.theme_type_variation = &"Toast"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.visible = false
	h.add_child(box)
	_row = HBoxContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_theme_constant_override("separation", 8)
	box.add_child(_row)
	mark = Label.new()
	mark.text = "! "
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mark.add_theme_font_override("font", UI.bold_font())
	mark.visible = false
	_row.add_child(mark)
	label = Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = MAX_LINES
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(label)
	action_button = Button.new()
	action_button.theme_type_variation = &"FlatButton"
	action_button.focus_mode = Control.FOCUS_NONE
	action_button.mouse_filter = Control.MOUSE_FILTER_STOP
	action_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	action_button.custom_minimum_size = Vector2(Ds.touch_min(), Ds.touch_min())
	action_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	action_button.add_theme_font_override("font", UI.bold_font())
	action_button.visible = false
	action_button.pressed.connect(_on_action_pressed)
	_row.add_child(action_button)
	_apply_colors()


func _ready() -> void:
	get_viewport().size_changed.connect(_update_width)
	_update_width()


## Gap between the toast and the bottom edge: phone = 12 + keyboard height or tab bar height (+ inset); PC = 28.
func set_bottom_gap(px: float) -> void:
	_gap_px = maxf(0.0, px) if not is_nan(px) else 28.0
	_gap.custom_minimum_size.y = _gap_px


func bottom_gap() -> float:
	return _gap_px


func _box_width() -> float:
	if not Platform.is_phone():
		return MAX_W
	var vw: float = get_viewport().get_visible_rect().size.x if is_inside_tree() else 412.0
	return clampf(vw - 32.0, 200.0, MAX_W)


func _update_width() -> void:
	# the row (text + action) is as wide as the box minus its side padding; the text wraps inside it
	_row.custom_minimum_size.x = _box_width() - 2.0 * PAD_X


func _apply_colors() -> void:
	var bg: Color = Pal.TOAST_BG
	if kind == "error":
		bg = Pal.TOAST_ERR
	elif kind == "ok":
		bg = Pal.TOAST_OK
	var base: StyleBox = box.get_theme_stylebox("panel", "Toast")
	var sb: StyleBoxFlat
	if base is StyleBoxFlat:
		sb = (base as StyleBoxFlat).duplicate() as StyleBoxFlat
	else:
		sb = UI.style(bg, Color(0, 0, 0, 0), 0, Ds.R_BTN, int(PAD_X), 12)
	sb.bg_color = bg
	box.add_theme_stylebox_override("panel", sb)
	label.add_theme_color_override("font_color", Pal.TOAST_FG)
	mark.add_theme_color_override("font_color", Pal.TOAST_FG)
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		action_button.add_theme_color_override(n, Pal.TOAST_FG)


## kind "info" | "ok" | "error" (anything else is shown as info). With `action_text` the toast gets an action button;
## `action` is called once when it is pressed and the toast goes away.
func show_message(text: String, kind_: String, action_text: String = "", action: Callable = Callable()) -> void:
	kind = kind_ if (kind_ == "ok" or kind_ == "error") else "info"
	label.text = text
	mark.visible = kind == "error"
	var has_action: bool = action_text != ""
	action_button.visible = has_action
	action_button.text = action_text
	_action = action if has_action else Callable()
	_apply_colors()
	_update_width()
	box.visible = true
	box.modulate = Color(1, 1, 1, 0)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(box, "modulate:a", 1.0, FADE_IN)
	_tween.tween_interval(LONG_SEC if (kind == "error" or has_action) else SHORT_SEC)
	_tween.tween_property(box, "modulate:a", 0.0, FADE_OUT)
	_tween.tween_callback(hide_now)


func hide_now() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	box.visible = false
	box.modulate = Color(1, 1, 1, 1)


## Number of text lines that are shown (never more than MAX_LINES).
func shown_lines() -> int:
	return label.get_visible_line_count()


func _on_action_pressed() -> void:
	var cb: Callable = _action
	_action = Callable()
	hide_now()
	if cb.is_valid():
		cb.call()


## Connects the Toast bus (Toast.message and Toast.snack) to this host. Call once after adding it to the tree.
func bind_toast_bus() -> void:
	if not Toast.message.is_connected(_on_message):
		Toast.message.connect(_on_message)
	if not Toast.snack.is_connected(_on_snack):
		Toast.snack.connect(_on_snack)


func _on_message(text: String, k: String) -> void:
	show_message(text, k)


func _on_snack(text: String, action_text: String, action: Callable) -> void:
	show_message(text, "info", action_text, action)
