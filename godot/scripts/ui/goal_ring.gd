class_name GoalRing
extends Control
## 오늘 목표 링 (docs/home_menu_design.md §5.4, §5.5, §8.1-9). draw_arc 로 그린 링 + 가운데 글자(또는 달성 체크).
## 표시 전용이라 터치 대상이 아니다(mouse_filter IGNORE). 목표가 꺼져 있으면(show_ring=false) 링 없이 글자만 그린다.
## 호 길이 트윈 400ms 는 목표를 막 채운 순간 한 번만 쓴다(animate_from).

const ANIM_SEC := 0.4

## 0..1. 바꾸면 다시 그린다.
var fraction: float = 0.0:
	set(v):
		fraction = clampf(v, 0.0, 1.0) if is_finite(v) else 0.0
		queue_redraw()
var show_ring: bool = true
var done: bool = false
var diameter: float = 96.0
var stroke: float = Ds.RING_STROKE
var center_text: String = ""

var _label: Label
var _check: GlyphIcon
var _tween: Tween = null


func _init(d: float = 0.0) -> void:
	diameter = d if d > 0.0 else (Ds.RING_D_PHONE if Platform.is_phone() else Ds.RING_D_PC)
	custom_minimum_size = Vector2(diameter, diameter)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_override("font", UI.bold_font())
	_label.add_theme_color_override("font_color", Pal.INK)
	add_child(_label)
	_check = GlyphIcon.new("check", diameter * 0.42, Pal.OK)
	_check.set_anchors_preset(Control.PRESET_CENTER)
	_check.offset_left = -diameter * 0.21
	_check.offset_right = diameter * 0.21
	_check.offset_top = -diameter * 0.21
	_check.offset_bottom = diameter * 0.21
	_check.visible = false
	add_child(_check)


## value 0..1, text = 가운데 글자(달성 땐 쓰지 않고 체크), is_done = 목표 달성, ring = false 면 링 없이 글자만.
func setup(value: float, text: String, is_done: bool, ring: bool = true, name_text: String = "") -> void:
	show_ring = ring
	done = is_done and ring
	center_text = text
	fraction = value if ring else 0.0
	accessibility_name = name_text if name_text != "" else text
	_check.visible = done
	_label.visible = not done
	_label.text = text
	_label.add_theme_font_size_override("font_size", _fit_font_size(text))
	queue_redraw()


## 글자 크기: Ds.fs(34) 배율을 따르되 상한 diameter*0.34, 그리고 링 안쪽 폭에 들어가게 줄인다(최저 Ds.MIN_FONT).
func _fit_font_size(text: String) -> int:
	var cap: int = maxi(Ds.MIN_FONT, int(floorf(diameter * 0.34)))
	var size_px: int = mini(Ds.fs(34), cap)
	var inner: float = (diameter - stroke * 2.0) * 0.9 if show_ring else diameter
	while size_px > Ds.MIN_FONT and UI.text_width(text, size_px, true) > inner:
		size_px -= 1
	return size_px


## 목표를 막 채운 순간: 호가 `from`(0..1)에서 지금 값까지 400ms 동안 차오른다.
func animate_from(from: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var target: float = fraction
	fraction = clampf(from, 0.0, 1.0)
	if not is_inside_tree():
		fraction = target
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_QUINT)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "fraction", target, ANIM_SEC)


func _draw() -> void:
	if not show_ring:
		return
	var s: float = minf(size.x, size.y)
	if s <= stroke * 2.0:
		return
	var c := Vector2(size.x, size.y) * 0.5
	var r: float = s * 0.5 - stroke * 0.5
	draw_arc(c, r, 0.0, TAU, 64, Pal.LINE, stroke, true)
	var col: Color = Pal.OK if done else Pal.PRIMARY
	if fraction > 0.0:
		var a0: float = -PI * 0.5
		var a1: float = a0 + TAU * fraction
		draw_arc(c, r, a0, a1, maxi(8, int(64.0 * fraction)), col, stroke, true)
		if fraction < 1.0: # round caps
			draw_circle(c + Vector2(cos(a0), sin(a0)) * r, stroke * 0.5, col)
			draw_circle(c + Vector2(cos(a1), sin(a1)) * r, stroke * 0.5, col)
