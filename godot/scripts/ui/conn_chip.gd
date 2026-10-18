class_name ConnChip
extends PanelContainer
## Connection status pill: a coloured dot AND a text (the text is always shown, colour alone never says the state).
## It does not decide anything: main.gd chooses `kind` and the wording (docs/ui_redesign_design.md §6.7), so the
## wording of the phone-only mode can change without touching this part.
##
## The pill is 28 px high; the control around it is as high as a touch target (Ds.touch_min(): 48 on the phone), so
## the whole area can be tapped. A tap sends `tapped` (UI.on_tap: on the phone on release and only without a drag).

signal tapped

const KINDS := ["ok", "warn", "bad", "idle"]
const PILL_H := 28.0
const DOT := 8.0

## The text is cut with an ellipsis beyond this width (px); 0 = never cut.
var max_text_width: float = 200.0

var kind: String = "idle"
var text: String = ""
var dot: Panel
var label: Label
var _pill: PanelContainer


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	custom_minimum_size.y = maxf(PILL_H, Ds.touch_min())
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pad: int = int(maxf(0.0, (custom_minimum_size.y - PILL_H) * 0.5))
	m.add_theme_constant_override("margin_top", pad)
	m.add_theme_constant_override("margin_bottom", pad)
	add_child(m)
	_pill = PanelContainer.new()
	_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pill.custom_minimum_size.y = PILL_H
	m.add_child(_pill)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_pill.add_child(row)
	dot = Panel.new()
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.custom_minimum_size = Vector2(DOT, DOT)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)
	label = Label.new()
	label.theme_type_variation = &"Small"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(label)
	UI.on_tap(self, func() -> void: tapped.emit())
	set_state("idle", "")


## kind "ok" | "warn" | "bad" | "idle" (anything else counts as "idle"); `text` is what the user reads.
func set_state(kind_: String, text_: String) -> void:
	kind = kind_ if KINDS.has(kind_) else "idle"
	text = text_
	label.text = text_
	label.visible = true
	_pill.add_theme_stylebox_override("panel", UI.style(Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_PILL, 10, 0))
	dot.add_theme_stylebox_override("panel", UI.style(_dot_color(), Color(0, 0, 0, 0), 0, Ds.R_PILL, 0, 0))
	label.add_theme_color_override("font_color", Pal.INK)
	_fit_text()
	tooltip_text = text_ if not Platform.is_phone() else ""


func _dot_color() -> Color:
	match kind:
		"ok":
			return Pal.OK
		"warn":
			return Pal.WARN
		"bad":
			return Pal.BAD
	return Pal.MUTED


func _fit_text() -> void:
	if max_text_width <= 0.0:
		label.custom_minimum_size.x = 0.0
		return
	var f: Font = label.get_theme_font("font")
	var fsz: int = label.get_theme_font_size("font_size")
	var w: float = f.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x if f != null else 0.0
	label.custom_minimum_size.x = minf(w + 1.0, max_text_width)
