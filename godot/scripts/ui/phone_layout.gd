class_name PhoneLayout
extends RefCounted
## Numbers and helpers of the phone layout (docs/android_remote_design.md §5).
## Every function is only meant to be used when Platform.is_phone(); PC code paths never call it.

const W := 412.0           ## logical width of the phone screen
const H := 915.0           ## logical height
const PAD := 16            ## page side padding
const TOP_H := 40.0        ## top status strip
const TAB_H := 56.0        ## bottom tab bar (without the safe-area inset)
const BTN_H := 48.0        ## minimum height of buttons, options and fields (= Ds.touch_min() on a 412 dp phone)
const LINK_H := 48.0       ## minimum size of text links (48 dp touch target, docs/ui_redesign_design.md §5.3)

## Tests overwrite these (docs §5.1): keyboard height in logical px (>= 0 overrides), and
## {"top","bottom","left","right"} insets in logical px (null = ask the OS).
static var test_keyboard_height: float = -1.0
static var test_insets: Variant = null

## Marks a Theme that apply_theme has already adjusted (it runs once per theme: light and dark are two themes).
const _THEME_META := "phone_done"


## Logical px of the screen that the status bar, notch and gesture bar cover. Always zero off Android.
static func safe_insets() -> Dictionary:
	var out := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	if test_insets is Dictionary:
		for k in out.keys():
			out[k] = float((test_insets as Dictionary).get(k, 0.0))
		return out
	if not Platform.is_android():
		return out
	var scale: float = _px_per_logical()
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	var scr: Vector2i = DisplayServer.screen_get_size()
	if scale <= 0.0 or safe.size.x <= 0 or scr.x <= 0:
		return out
	out["top"] = maxf(0.0, float(safe.position.y) / scale)
	out["left"] = maxf(0.0, float(safe.position.x) / scale)
	out["right"] = maxf(0.0, float(scr.x - safe.end.x) / scale)
	out["bottom"] = maxf(0.0, float(scr.y - safe.end.y) / scale)
	return out


## Height of the on-screen keyboard in logical px (0 when hidden).
static func keyboard_height() -> float:
	if test_keyboard_height >= 0.0:
		return test_keyboard_height
	if not Platform.is_android():
		return 0.0
	var scale: float = _px_per_logical()
	if scale <= 0.0:
		return 0.0
	return maxf(0.0, float(DisplayServer.virtual_keyboard_get_height()) / scale)


## Window pixels per logical px (1.0 on the desktop test window).
static func _px_per_logical() -> float:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		var win: Window = (ml as SceneTree).root
		var logical_w: float = win.get_visible_rect().size.x
		if logical_w > 0.0:
			return float(win.size.x) / logical_w
	return 1.0


## True when a layout this wide should use the one-column phone arrangement.
static func is_narrow(width: float) -> bool:
	return width < 700.0


## dp per logical px: below 1.0 on a phone narrower than the 412 dp the logical canvas assumes, so 48 logical px
## are fewer than 48 dp. 1.0 off Android (desktop tests). Ds.touch_min() = 48 / dp_scale().
static func dp_scale() -> float:
	if not Platform.is_android():
		return 1.0
	var dpi: float = float(DisplayServer.screen_get_dpi())
	var ppl: float = _px_per_logical()
	if dpi <= 0.0 or ppl <= 0.0:
		return 1.0
	return clampf(ppl / (dpi / 160.0), 0.5, 2.0)


## Text sizes of the phone from the Ds table (16 -> 17, "Small" 13 -> 14, "Eyebrow" 12 -> 13, H1..H3 +1..2).
static func font_bump(theme: Theme) -> void:
	Ds.apply_type_sizes(theme, true)


## Raises the theme's text sizes and tightens card padding for the small screen. Idempotent per theme.
static func apply_theme(theme: Theme) -> void:
	if theme == null or theme.has_meta(_THEME_META):
		return
	theme.set_meta(_THEME_META, true)
	font_bump(theme)
	# card padding 16 on the phone, no outline (the grey page background separates the cards); radius stays R_CARD
	for spec in [["Card", 16, 16], ["BigCard", 16, 16], ["Sunk", 12, 12]]:
		var sb: StyleBox = theme.get_stylebox("panel", spec[0])
		if sb != null:
			sb.content_margin_left = float(spec[1])
			sb.content_margin_right = float(spec[1])
			sb.content_margin_top = float(spec[2])
			sb.content_margin_bottom = float(spec[2])
			if sb is StyleBoxFlat and spec[0] != "Sunk":
				(sb as StyleBoxFlat).set_border_width_all(0)
	# a little more air between lines of Korean body text (Godot default Label 3: PC 4, phone 5; RichTextLabel 0: PC 2, phone 3)
	theme.set_constant("line_spacing", "Label", 5)
	theme.set_constant("line_separation", "RichTextLabel", 3)
	# Android has none of the Windows fonts: put common system names behind them.
	var f: Font = theme.default_font
	if f is SystemFont:
		var names := PackedStringArray((f as SystemFont).font_names)
		for n in ["Roboto", "Noto Sans CJK KR", "Noto Sans KR", "Noto Sans CJK JP", "Noto Sans JP", "sans-serif"]:
			if not names.has(n):
				names.append(n)
		(f as SystemFont).font_names = names


## Scrolls the nearest ScrollContainer above `c` so that `c` is visible (keyboard just opened).
static func ensure_visible(c: Control) -> void:
	var n: Node = c.get_parent()
	while n != null:
		if n is ScrollContainer:
			(n as ScrollContainer).ensure_control_visible(c)
			return
		n = n.get_parent()


## Raises `c`'s minimum height to at least `h` (and the width to `w` when given). Phone only.
static func touch(c: Control, h: float = BTN_H, w: float = 0.0) -> void:
	c.custom_minimum_size.y = maxf(c.custom_minimum_size.y, h)
	if w > 0.0:
		c.custom_minimum_size.x = maxf(c.custom_minimum_size.x, w)


# ---------------------------------------------------------------- touch scrolling

## Drag distance (logical px) that turns a touch into a scroll; also the largest wobble that still counts as a tap.
const SCROLL_DEADZONE := 12
const TAP_SLOP := 12.0

## Controls that keep their own pointer handling (their drag is a value, a thumb or an inner scroll), so a drag
## that starts on them does not scroll the page.
const _OWN_DRAG := ["Slider", "ScrollBar", "ItemList", "Tree", "SpinBox"]

static var _touch_scroll_hooked: bool = false


## Phone only, called once by main.gd before any screen is built.
##
## Why: Godot 4.6 ScrollContainer scrolls from the (touch-emulated) mouse button / motion events that BUBBLE up to
## it (scene/gui/scroll_container.cpp gui_input; routing in Viewport::_gui_call_input). A control with
## mouse_filter STOP (the default of PanelContainer, Button, LineEdit, RichTextLabel, ProgressBar, ...) ends the
## bubbling, so a finger that starts on a card or a button never reaches the page and only blank space scrolls.
## Fix: every control inside a ScrollContainer that would STOP the event passes it on (PASS: it still gets the
## event first, so taps, focus and hover work as before; a covering overlay still blocks, because the event only
## bubbles to the parents of the control that is hit). Once the finger leaves the dead zone, ScrollContainer
## sends NOTIFICATION_SCROLL_BEGIN to its children, which cancels the press of the Button under the finger.
## Every ScrollContainer gets the same dead zone (the default is 0, where any shaky tap would scroll).
## Nested scroll containers: the inner one scrolls first and only accepts a drag that moves it, so when it is at
## its end the rest of the same drag continues in the outer page (scroll chaining).
static func install_touch_scroll(tree: SceneTree) -> void:
	if _touch_scroll_hooked:
		return
	_touch_scroll_hooked = true
	tree.node_added.connect(_on_node_added)
	_touch_prepare(tree.root)


static func _touch_prepare(n: Node) -> void:
	_on_node_added(n)
	for c in n.get_children():
		_touch_prepare(c)


static func _on_node_added(n: Node) -> void:
	if n is ScrollContainer:
		var sc := n as ScrollContainer
		if sc.scroll_deadzone < SCROLL_DEADZONE:
			sc.scroll_deadzone = SCROLL_DEADZONE
	elif n is OptionButton:
		# It opens its popup on PRESS by default, which cannot be undone when the press turns into a scroll.
		(n as OptionButton).action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	if n is Control:
		pass_touch_to_scroll(n as Control)


## STOP -> PASS for `c` when it sits inside a ScrollContainer (see install_touch_scroll). Public so a screen can
## call it for a control it sets to STOP after adding it to the tree. A control can opt out with
## c.set_meta("own_drag", true).
static func pass_touch_to_scroll(c: Control) -> void:
	if c.mouse_filter != Control.MOUSE_FILTER_STOP or c.has_meta("own_drag"):
		return
	for cls in _OWN_DRAG:
		if c.is_class(cls):
			return
	var p: Node = c.get_parent()
	while p != null and not (p is Window):
		if p is ScrollContainer:
			c.mouse_filter = Control.MOUSE_FILTER_PASS
			if c is LineEdit or c is TextEdit:
				_assist_field_drag(c)
			return
		p = p.get_parent()


## LineEdit and TextEdit accept every left press themselves (line_edit.cpp: "Don't pass event further when clicked
## on text field"), so the press never reaches the ScrollContainer and its own touch drag cannot start. Taps, focus,
## caret and keyboard stay with the field; a mostly vertical drag that starts on it is scrolled here instead:
## a TextEdit with text left to scroll moves its own text first (inner first), the rest goes to the nearest
## scrollable parent (chaining); the field does not select text and does not open the keyboard on release, and a
## flick keeps the page moving a little (a tween; the ScrollContainer fling is not reachable from here).
static func _assist_field_drag(c: Control) -> void:
	if c.has_meta("touch_assist"):
		return
	c.set_meta("touch_assist", true)
	var st := {"down": false, "drag": false, "start": Vector2.ZERO, "acc": 0.0, "sc": null, "vel": 0.0}
	c.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := ev as InputEventMouseButton
			if mb.pressed:
				st["down"] = true
				st["drag"] = false
				st["start"] = mb.global_position
				st["acc"] = 0.0
				st["sc"] = null
			else:
				if st["down"] and st["drag"]:
					c.accept_event() # a scroll, not a tap: no keyboard, no selection bookkeeping
					_fling(st["sc"] as ScrollContainer, float(st["vel"]))
				st["down"] = false
				st["drag"] = false
		elif ev is InputEventMouseMotion and st["down"] and ((ev as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			var mm := ev as InputEventMouseMotion
			var d: Vector2 = mm.global_position - (st["start"] as Vector2)
			var dy: float = -mm.relative.y
			if not st["drag"]:
				if absf(d.y) <= SCROLL_DEADZONE or absf(d.y) <= absf(d.x):
					return
				st["drag"] = true
				dy = -d.y # everything since the press, so no distance is lost to the dead zone
				var old: Variant = _scrollable_parent(c, dy)
				if old is ScrollContainer and (old as ScrollContainer).has_meta("fling"):
					((old as ScrollContainer).get_meta("fling") as Tween).kill()
			st["vel"] = mm.velocity.y
			st["sc"] = _scroll_step(c, dy, st)
			if c is LineEdit:
				(c as LineEdit).deselect.call_deferred()
			else:
				(c as TextEdit).deselect.call_deferred())


## Moves `dy` px (> 0 = content up) into the TextEdit itself if it has text left in that direction, else into the
## nearest scrollable parent. Returns the page that moved (null when the TextEdit took it).
static func _scroll_step(c: Control, dy: float, st: Dictionary) -> ScrollContainer:
	if c is TextEdit:
		var te := c as TextEdit
		var vb := te.get_v_scroll_bar()
		var lh: float = maxf(1.0, float(te.get_line_height()))
		var room: float = vb.max_value - vb.page
		if vb.visible and room > 0.5 and ((dy > 0.0 and te.get_v_scroll() < room - 0.01) or (dy < 0.0 and te.get_v_scroll() > 0.01)):
			te.set_v_scroll(clampf(te.get_v_scroll() + dy / lh, 0.0, room))
			return null
	var sc: ScrollContainer = _scrollable_parent(c, dy)
	if sc == null:
		return null
	st["acc"] = float(st["acc"]) + dy
	var whole: int = int(st["acc"])
	if whole != 0:
		st["acc"] = float(st["acc"]) - float(whole)
		sc.scroll_vertical += whole
	return sc


## Nearest ScrollContainer above `c` that can still move in direction `dir` (> 0 = down); chains outwards.
static func _scrollable_parent(c: Control, dir: float) -> ScrollContainer:
	var p: Node = c.get_parent()
	while p != null and not (p is Window):
		if p is ScrollContainer:
			var sc := p as ScrollContainer
			var bar := sc.get_v_scroll_bar()
			var top: float = maxf(0.0, bar.max_value - bar.page)
			if sc.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED and ((dir > 0.0 and float(sc.scroll_vertical) < top) or (dir < 0.0 and sc.scroll_vertical > 0)):
				return sc
		p = p.get_parent()
	return null


static func _fling(sc: ScrollContainer, vel_y: float) -> void:
	if sc == null or not is_instance_valid(sc) or absf(vel_y) < 300.0:
		return
	var bar := sc.get_v_scroll_bar()
	var target: float = clampf(float(sc.scroll_vertical) - vel_y * 0.3, 0.0, maxf(0.0, bar.max_value - bar.page))
	var tw := sc.create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(sc, "scroll_vertical", int(target), 0.5)
	sc.set_meta("fling", tw)
