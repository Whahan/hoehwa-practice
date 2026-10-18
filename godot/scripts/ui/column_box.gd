class_name ColumnBox
extends MarginContainer
## A MarginContainer that keeps its content in a centered column of at most `max_width`.
## Put children into `content` (a VBoxContainer).

@export var max_width: float = 960.0
@export var min_pad: int = 20
@export var pad_top: int = 20
@export var pad_bottom: int = 28

var content: VBoxContainer
var apply_calls: int = 0 ## how often _apply_margins was called (ui_regress_test watches it)
var _applying: bool = false
var _pending_width: float = NAN


func _init() -> void:
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", Ds.S3 if Platform.is_phone() else Ds.S4) # card gap: phone 12, PC 16
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(content)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_margins(1280.0)


func set_padding(top: int, bottom: int) -> void:
	pad_top = top
	pad_bottom = bottom
	_apply_margins(size.x)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_apply_margins(size.x)


## Margins that keep the content in a centred column of at most `max_width`.
## - The column is at least as wide as the content needs (a content wider than `max_width` is not squeezed), so the side
##   margins never push the minimum size past the width they were computed from: no endless "margins -> resize ->
##   margins". Without this a wide child (e.g. an unwrapped PC recorder hint at 150 % text) made the width grow forever.
## - Setting a margin can resize this node, which calls back here. A call that arrives while one is running is not
##   run recursively: its width is remembered and applied once more after the first one (at most twice in all).
## - A margin that already has the wanted value is not set again (setting it re-sorts the layout).
func _apply_margins(width: float) -> void:
	apply_calls += 1
	if _applying:
		_pending_width = width
		return
	_applying = true
	var w: float = width
	for _i in 2:
		_pending_width = NAN
		_set_margins(w)
		if is_nan(_pending_width) or is_equal_approx(_pending_width, w):
			break
		w = _pending_width
	_applying = false


func _set_margins(width: float) -> void:
	var side: int = 0
	if Platform.is_phone():
		side = PhoneLayout.PAD # narrow screen: max_width is ignored, the column is as wide as the page
	else:
		var avail: float = width
		var holder := get_parent_control()
		if holder != null and holder.size.x > 0.0:
			avail = minf(avail, holder.size.x) # our own width may already be inflated by the margins: trust the parent's
		var wanted: float = maxf(max_width, content.get_combined_minimum_size().x)
		side = maxi(min_pad, int((avail - wanted) * 0.5))
	_set_margin("margin_left", side)
	_set_margin("margin_right", side)
	_set_margin("margin_top", pad_top)
	_set_margin("margin_bottom", pad_bottom)


func _set_margin(item: String, value: int) -> void:
	if has_theme_constant_override(item) and get_theme_constant(item) == value:
		return
	add_theme_constant_override(item, value)
