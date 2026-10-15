class_name AppView
extends Control
## Base class of the five tab screens. Subclasses build their UI in code.


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true


## Called whenever the tab becomes visible (or its data may have changed).
func refresh() -> void:
	pass


## Called when the user leaves the tab.
func on_hide() -> void:
	pass


## Rebuilds a scrolling page while keeping the scroll position.
func rebuild_keep_scroll(scroll: ScrollContainer, builder: Callable) -> void:
	var sv: int = scroll.scroll_vertical
	builder.call()
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(scroll):
		scroll.scroll_vertical = sv
