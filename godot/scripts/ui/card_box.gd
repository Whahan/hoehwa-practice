class_name CardBox
extends PanelContainer
## PanelContainer (styled through theme_type_variation) with a ready-made inner VBox `body`.

var body: VBoxContainer


func _init() -> void:
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(body)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func add(c: Control) -> Control:
	body.add_child(c)
	return c
