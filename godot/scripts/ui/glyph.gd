class_name GlyphIcon
extends Control
## A small icon drawn with lines and polygons (no font glyph, no image): glyph characters change shape between
## fonts and turn into emoji on Android (docs/ui_redesign_design.md §5.6). Purely visual: mouse_filter IGNORE.
## An unknown `kind` draws nothing (an empty cell of the same size) and raises no error.

const KINDS := ["back", "chevron_down", "chevron_up", "chevron_right", "check", "close", "play", "record", "more"]

var kind: String = "chevron_right"
var icon_color: Color = Color.BLACK
var icon_size: float = 20.0


func _init(kind_: String = "chevron_right", px: float = 20.0, color: Color = Pal.INK) -> void:
	kind = kind_
	icon_size = maxf(0.0, px)
	icon_color = color
	custom_minimum_size = Vector2(icon_size, icon_size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_kind(k: String) -> void:
	kind = k
	queue_redraw()


func set_icon_color(c: Color) -> void:
	icon_color = c
	queue_redraw()


func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= 0.0:
		s = icon_size
	# centre the square drawing area in the control
	var o := Vector2((size.x - s) * 0.5, (size.y - s) * 0.5)
	var w: float = maxf(1.5, s * 0.1)
	match kind:
		"back":
			_poly([Vector2(0.62, 0.2), Vector2(0.32, 0.5), Vector2(0.62, 0.8)], o, s, w)
		"chevron_right":
			_poly([Vector2(0.38, 0.2), Vector2(0.68, 0.5), Vector2(0.38, 0.8)], o, s, w)
		"chevron_down":
			_poly([Vector2(0.2, 0.38), Vector2(0.5, 0.68), Vector2(0.8, 0.38)], o, s, w)
		"chevron_up":
			_poly([Vector2(0.2, 0.62), Vector2(0.5, 0.32), Vector2(0.8, 0.62)], o, s, w)
		"check":
			_poly([Vector2(0.2, 0.52), Vector2(0.42, 0.74), Vector2(0.8, 0.28)], o, s, w)
		"close":
			_poly([Vector2(0.26, 0.26), Vector2(0.74, 0.74)], o, s, w)
			_poly([Vector2(0.74, 0.26), Vector2(0.26, 0.74)], o, s, w)
		"play":
			draw_colored_polygon(PackedVector2Array([o + Vector2(0.3, 0.2) * s, o + Vector2(0.8, 0.5) * s, o + Vector2(0.3, 0.8) * s]), icon_color)
		"record":
			draw_circle(o + Vector2(0.5, 0.5) * s, s * 0.32, icon_color)
		"more":
			for i in 3:
				draw_circle(o + Vector2(0.2 + 0.3 * i, 0.5) * s, maxf(1.6, s * 0.09), icon_color)
		_:
			pass


func _poly(pts: Array, o: Vector2, s: float, w: float) -> void:
	var line := PackedVector2Array()
	for p in pts:
		line.append(o + (p as Vector2) * s)
	draw_polyline(line, icon_color, w, true)
	# round caps (draw_polyline has square ends)
	draw_circle(line[0], w * 0.5, icon_color)
	draw_circle(line[line.size() - 1], w * 0.5, icon_color)
