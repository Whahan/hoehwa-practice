class_name PageScroll
extends ScrollContainer
## Vertical scrolling page with a centered content column.
## Add children to `content`.

var column: ColumnBox
var content: VBoxContainer


func _init(max_w: float = 960.0) -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if Platform.is_phone():
		scroll_deadzone = 12 # a finger drag that starts on a button still scrolls the page
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	column = ColumnBox.new()
	column.max_width = max_w
	add_child(column)
	content = column.content
