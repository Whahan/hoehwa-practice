class_name PhoneLayout
extends RefCounted
## Numbers and helpers of the phone layout (docs/android_remote_design.md §5).
## Every function is only meant to be used when Platform.is_phone(); PC code paths never call it.

const W := 412.0           ## logical width of the phone screen
const H := 915.0           ## logical height
const PAD := 16            ## page side padding
const TOP_H := 40.0        ## top status strip
const TAB_H := 56.0        ## bottom tab bar (without the safe-area inset)
const BTN_H := 48.0        ## minimum height of buttons, options and fields
const LINK_H := 44.0       ## minimum size of text links

## Tests overwrite these (docs §5.1): keyboard height in logical px (>= 0 overrides), and
## {"top","bottom","left","right"} insets in logical px (null = ask the OS).
static var test_keyboard_height: float = -1.0
static var test_insets: Variant = null

static var _theme_done: bool = false


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


## Text sizes of the phone: 16 -> 17, "Small" 13 -> 14, "Eyebrow" 12 -> 13 (docs §5.1). Idempotent via apply_theme.
static func font_bump(theme: Theme) -> void:
	theme.default_font_size = 17
	var bumps := {"Small": 14, "Eyebrow": 13, "Muted": 16, "Strong": 17}
	for k in bumps.keys():
		theme.set_font_size("font_size", k, int(bumps[k]))


## Raises the theme's text sizes and tightens card padding for the small screen. Idempotent.
static func apply_theme(theme: Theme) -> void:
	if theme == null or _theme_done:
		return
	_theme_done = true
	font_bump(theme)
	for spec in [["Card", 14, 14], ["BigCard", 16, 16], ["Sunk", 12, 12]]:
		var sb: StyleBox = theme.get_stylebox("panel", spec[0])
		if sb != null:
			sb.content_margin_left = float(spec[1])
			sb.content_margin_right = float(spec[1])
			sb.content_margin_top = float(spec[2])
			sb.content_margin_bottom = float(spec[2])
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
