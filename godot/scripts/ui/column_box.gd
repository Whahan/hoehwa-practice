class_name ColumnBox
extends MarginContainer
## A MarginContainer that keeps its content in a centered column of at most `max_width`.
## Put children into `content` (a VBoxContainer).

@export var max_width: float = 960.0
@export var min_pad: int = 20
@export var pad_top: int = 20
@export var pad_bottom: int = 28

var content: VBoxContainer


func _init() -> void:
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
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


func _apply_margins(width: float) -> void:
	var side: int = maxi(min_pad, int((width - max_width) * 0.5))
	add_theme_constant_override("margin_left", side)
	add_theme_constant_override("margin_right", side)
	add_theme_constant_override("margin_top", pad_top)
	add_theme_constant_override("margin_bottom", pad_bottom)
