class_name Sheet
extends Control
## Bottom sheet (phone) / centred dialog (PC) over a dimmed screen (docs/ui_redesign_design.md §6.5).
##
## Choices and confirmations come up from the bottom edge on the phone; on the PC every sheet is a 440 px dialog in
## the middle. Information / progress dialogs ask for mode "center" themselves. Opened sheets form a stack: the
## newest is on top and `close_top()` closes only that one. Depth is made with dim only (no shadow on a sheet).
##
## Overlay order (CanvasLayer.layer, low = behind): sheet 16, each sheet opened above another one +1 (at most 27);
## splash 20; connect screen 25; first-connection question (SyncChoiceDialog) 28; toast 30. So the question and the
## toast are always above a sheet, while the splash (20) and the connect screen (25) cover a sheet on layer 16.
## A sheet that must appear from inside the connect screen passes opts.layer = 26.
##
## Phone touch rules: every tappable thing is a BaseButton, the dim is tapped with UI.on_tap (on release, no drag).
## The body sits in a ScrollContainer, so the global touch-scroll hook treats it like every other scrolling page.

signal closed(result: Variant)

const BASE_LAYER := 16
const MAX_LAYER := 27
const PC_W := 440.0
const SIDE := 24
const OPEN_SEC := 0.28
const CLOSE_SEC := 0.2

## Tests switch the slide / fade off so that rectangles are final right after a few frames.
static var animate: bool = true
static var _stack: Array = []

var mode: String = "bottom" ## "bottom" | "center" (resolved from "auto")
var dismissable: bool = true
var max_h_frac: float = 0.7
var dim: ColorRect
var panel: PanelContainer
var title_label: Label = null
var body: Control = null
var buttons: Dictionary = {} ## id -> Button
var layer_node: CanvasLayer = null

var _scroll: ScrollContainer = null
var _btn_box: Control = null
var _done: bool = false
var _settled: bool = false
var _kb: float = 0.0
var _h: float = 0.0
var _anim_t: float = 1.0
var _tween: Tween = null
var _title_text: String = ""


# ---------------------------------------------------------------- opening

## buttons = [{"id": String, "text": String, "kind": "danger" | "primary" | "soft" | "flat"}] (none is fine).
## opts = {"mode": "auto" | "bottom" | "center", "dismissable": true, "max_h_frac": 0.7, "layer": 16}.
## `body` may be null (title and buttons only). `host` is any node; one that is not in the tree is replaced by the
## scene tree root.
static func open(host: Node, title: String, body_: Control, buttons_: Array = [], opts: Dictionary = {}) -> Sheet:
	_prune()
	var s := Sheet.new()
	s._setup(title, body_, buttons_, opts)
	var parent: Node = host
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		var ml: MainLoop = Engine.get_main_loop()
		parent = (ml as SceneTree).root if ml is SceneTree else null
	if parent == null:
		return s # no tree at all (a test without a scene): the sheet exists but shows nothing
	var cl := CanvasLayer.new()
	var base: int = clampi(int(opts.get("layer", BASE_LAYER)), 1, MAX_LAYER)
	cl.layer = mini(base + _stack.size(), MAX_LAYER)
	s.layer_node = cl
	parent.add_child(cl)
	cl.add_child(s)
	_stack.append(s)
	return s


static func confirm(host: Node, title: String, message: String, ok_text: String = "확인", danger: bool = false, cancel_text: String = "취소") -> Sheet:
	var msg := UI.label(message)
	return open(host, title, msg, [
		{"id": "ok", "text": ok_text, "kind": "danger" if danger else "primary"},
		{"id": "cancel", "text": cancel_text, "kind": "flat"},
	])


## items = [[value, label], ...]; closed(value) with the picked value ("dismiss" when closed without a pick).
## `current` (compared as text) is shown bold with a check mark.
static func choice(host: Node, title: String, items: Array, current: String = "") -> Sheet:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	var s := open(host, title, col, [], {})
	var row_h: float = 56.0 if Platform.is_phone() else 48.0
	for it in items:
		if not (it is Array) or (it as Array).size() < 2:
			continue
		var value: Variant = (it as Array)[0]
		var label: String = str((it as Array)[1])
		var b := Button.new()
		b.theme_type_variation = &"FlatButton"
		b.text = label
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.custom_minimum_size.y = row_h
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var picked: bool = str(value) == current and current != ""
		var fg: Color = Pal.PRIMARY if picked else Pal.INK
		for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(n, fg)
		if picked:
			b.add_theme_font_override("font", UI.bold_font())
			var chk := GlyphIcon.new("check", 22.0, Pal.PRIMARY)
			chk.anchor_left = 1.0
			chk.anchor_right = 1.0
			chk.anchor_top = 0.5
			chk.anchor_bottom = 0.5
			chk.offset_left = -38.0
			chk.offset_right = -16.0
			chk.offset_top = -11.0
			chk.offset_bottom = 11.0
			b.add_child(chk)
		b.pressed.connect(func() -> void: s.close(value))
		col.add_child(b)
		s.buttons[str(value)] = b
	return s


static func is_open() -> bool:
	_prune()
	return not _stack.is_empty()


## Closes the newest open sheet with `result` and returns true; false when none is open.
static func close_top(result: Variant = "dismiss") -> bool:
	_prune()
	if _stack.is_empty():
		return false
	(_stack.back() as Sheet).close(result)
	return true


## For the Android back button: the newest sheet is closed with "dismiss" when it may be dismissed; one that must be
## answered swallows the press. Returns false when no sheet is open.
static func handle_back() -> bool:
	_prune()
	if _stack.is_empty():
		return false
	var top: Sheet = _stack.back()
	if top.dismissable:
		top.close("dismiss")
	return true


static func depth() -> int:
	_prune()
	return _stack.size()


static func _prune() -> void:
	var keep: Array = []
	for s in _stack:
		if is_instance_valid(s) and not (s as Sheet)._done:
			keep.append(s)
	_stack = keep


# ---------------------------------------------------------------- building

func _setup(title: String, body_: Control, buttons_: Array, opts: Dictionary) -> void:
	_title_text = title
	body = body_
	dismissable = bool(opts.get("dismissable", true))
	var f: float = float(opts.get("max_h_frac", 0.7))
	max_h_frac = clampf(f, 0.2, 0.95) if not is_nan(f) else 0.7
	var m: String = str(opts.get("mode", "auto"))
	if m == "bottom" or m == "center":
		mode = m
	else:
		mode = "bottom" if Platform.is_phone() else "center"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	name = "Sheet"

	dim = ColorRect.new()
	dim.name = "Dim"
	dim.color = Pal.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	UI.on_tap(dim, func() -> void:
		if dismissable and not _done:
			close("dismiss"))

	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.modulate.a = 0.0 # invisible (but laid out, so rectangles are right at once) until its height is known (_settle)
	dim.modulate.a = 0.0
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	if mode == "bottom":
		var hc := CenterContainer.new()
		hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var grip := Panel.new()
		grip.custom_minimum_size = Vector2(36, 4)
		grip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grip.add_theme_stylebox_override("panel", UI.style(Pal.LINE_STRONG, Color(0, 0, 0, 0), 0, 2, 0, 0))
		hc.add_child(grip)
		v.add_child(hc)
	if title != "":
		title_label = UI.label(title, "H2")
		v.add_child(title_label)
	if body != null:
		_scroll = ScrollContainer.new()
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if body.get_parent() != null:
			body.get_parent().remove_child(body)
		_scroll.add_child(body)
		v.add_child(_scroll)
	_build_buttons(v, buttons_)
	_style_panel(0.0)


func _build_buttons(v: VBoxContainer, specs: Array) -> void:
	var phone_like: bool = mode == "bottom"
	var items: Array = []
	for s in specs:
		if s is Dictionary and str((s as Dictionary).get("text", "")) != "":
			items.append(s)
	if items.is_empty():
		return
	if phone_like:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 8)
		_btn_box = col
	else:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 8)
		_btn_box = row
		items.reverse() # the first button (the answer) ends up rightmost
	var h: float = 56.0 if phone_like else 44.0
	for spec in items:
		var d: Dictionary = spec
		var text: String = str(d.get("text", ""))
		var id: String = str(d.get("id", text))
		var b: Button
		match str(d.get("kind", "soft")):
			"danger":
				b = UI.button(text, "primary", Pal.BAD, h)
			"primary":
				b = UI.button(text, "primary", Pal.PRIMARY, h)
			"flat":
				b = UI.button(text, "flat", Pal.PRIMARY, h)
			_:
				b = UI.button(text, "soft", Pal.PRIMARY, h)
		b.pressed.connect(func() -> void: close(id))
		_btn_box.add_child(b)
		buttons[id] = b
	v.add_child(_btn_box)


func _style_panel(bottom_inset: float) -> void:
	var sb := UI.style(Pal.SURFACE_HI, Color(0, 0, 0, 0), 0, Ds.R_CARD, SIDE, 0)
	if mode == "bottom":
		sb.corner_radius_top_left = Ds.R_SHEET
		sb.corner_radius_top_right = Ds.R_SHEET
		sb.corner_radius_bottom_left = 0
		sb.corner_radius_bottom_right = 0
		sb.content_margin_top = 12
		sb.content_margin_bottom = 16.0 + bottom_inset
	else:
		sb.content_margin_top = 24
		sb.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", sb)


# ---------------------------------------------------------------- layout

func _ready() -> void:
	set_process(true)
	_relayout()
	# the labels need a frame or two to know their wrapped height
	await get_tree().process_frame
	_relayout()
	await get_tree().process_frame
	if _done or not is_inside_tree():
		return
	_relayout()
	_settle()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready() and not _done:
		_relayout()


func _process(_delta: float) -> void:
	if _done:
		return
	var kb: float = PhoneLayout.keyboard_height()
	if not is_equal_approx(kb, _kb):
		_relayout()


## Public so a caller whose body changed size (a list that grew) can ask for a new height.
func relayout() -> void:
	_relayout()


func _relayout() -> void:
	if panel == null or not is_inside_tree():
		return
	var sz: Vector2 = size
	if sz.x < 1.0 or sz.y < 1.0:
		sz = get_viewport_rect().size
	_kb = maxf(0.0, PhoneLayout.keyboard_height())
	var inset: float = float(PhoneLayout.safe_insets()["bottom"]) if _kb <= 0.0 and mode == "bottom" else 0.0
	_style_panel(inset)
	var w: float = sz.x if mode == "bottom" else minf(PC_W, maxf(240.0, sz.x - 32.0))
	var max_h: float = minf(sz.y * max_h_frac, sz.y - _kb - 16.0)
	max_h = maxf(max_h, 120.0)
	if _scroll != null:
		_scroll.custom_minimum_size.y = 0.0
	panel.custom_minimum_size.x = w
	var fixed_h: float = panel.get_combined_minimum_size().y
	var h: float = fixed_h
	if _scroll != null and body != null:
		var body_h: float = body.get_combined_minimum_size().y
		var room: float = maxf(0.0, max_h - fixed_h)
		_scroll.custom_minimum_size.y = minf(body_h, room)
		h = panel.get_combined_minimum_size().y
	_h = h
	if mode == "bottom":
		panel.anchor_left = 0.0
		panel.anchor_right = 1.0
		panel.anchor_top = 1.0
		panel.anchor_bottom = 1.0
	else:
		panel.anchor_left = 0.5
		panel.anchor_right = 0.5
		panel.anchor_top = 0.5
		panel.anchor_bottom = 0.5
	_place()


## Puts the panel at its place for the current animation value (_anim_t 1 = at rest).
func _place() -> void:
	var slide: float = 0.0
	if mode == "bottom":
		slide = (1.0 - _anim_t) * (_h + _kb)
		panel.offset_left = 0.0
		panel.offset_right = 0.0
		panel.offset_bottom = -_kb + slide
		panel.offset_top = -_kb - _h + slide
	else:
		var w: float = panel.custom_minimum_size.x
		slide = (1.0 - _anim_t) * 24.0
		panel.offset_left = -w * 0.5
		panel.offset_right = w * 0.5
		panel.offset_top = -_kb * 0.5 - _h * 0.5 + slide
		panel.offset_bottom = -_kb * 0.5 + _h * 0.5 + slide


func _settle() -> void:
	if _settled:
		return
	_settled = true
	if not animate:
		_anim_t = 1.0
		_apply_anim(1.0)
		return
	_apply_anim(0.0)
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_QUINT)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.tween_method(_apply_anim, 0.0, 1.0, OPEN_SEC)


func _apply_anim(t: float) -> void:
	_anim_t = t
	dim.modulate.a = t
	panel.modulate.a = t if mode == "center" else 1.0
	_place()


# ---------------------------------------------------------------- closing

## Closes this sheet once: `closed(result)` is sent at once, the fade out then takes 200 ms.
func close(result: Variant = "dismiss") -> void:
	if _done:
		return
	_done = true
	_stack.erase(self)
	closed.emit(result)
	if not is_inside_tree():
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not animate or not _settled:
		_free_layer()
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_QUINT)
	_tween.set_ease(Tween.EASE_IN)
	_tween.tween_method(_apply_anim, _anim_t, 0.0, CLOSE_SEC)
	_tween.tween_callback(_free_layer)


func _free_layer() -> void:
	if layer_node != null and is_instance_valid(layer_node):
		layer_node.queue_free()
	else:
		queue_free()


func is_closed() -> bool:
	return _done


## The panel's rectangle once it is at rest (tests and the shell read it).
func panel_rect() -> Rect2:
	return panel.get_global_rect()


func _exit_tree() -> void:
	_done = true
	_stack.erase(self)
