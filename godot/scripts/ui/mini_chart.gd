class_name MiniChart
extends Control
## 통계용 작은 차트 (막대 / 꺾은선). 값은 숫자 또는 null(기록 없음). 폭은 부모를 따라가고 최소 폭은 0 이다.
##
##   MiniChart.bars([12, 0, 30, ...], ["월", "화", ...], Pal.EN, 2, 15.0)   # 값, 라벨, 색, 강조 막대, 목표선
##   MiniChart.line([80, null, 90, ...], ["10/3", "", ...], Pal.OK, 100.0)  # null 이면 건너뛰고 앞뒤 점을 잇는다

enum Kind { BARS, LINE }

const PAD_TOP := 22.0
const PAD_BOTTOM := 22.0
const PAD_LEFT := 30.0
const PAD_RIGHT := 6.0
const FONT_SIZE := 12

var kind: int = Kind.BARS
var values: Array = []
var labels: Array = []
var color: Color = Pal.EN
var y_max: float = 0.0 ## 0 = fit to the data
var goal_line: float = -1.0 ## bars: dashed line (same unit as values)
var highlight: int = -1 ## bars: index drawn in full colour, the others lighter
var value_format: String = "%d" ## printed over the bars / last point


static func bars(vals: Array, lbls: Array, col: Color, hi: int = -1, goal: float = -1.0) -> MiniChart:
	var c := MiniChart.new()
	c.kind = Kind.BARS
	c.values = vals
	c.labels = lbls
	c.color = col
	c.highlight = hi
	c.goal_line = goal
	return c


static func line(vals: Array, lbls: Array, col: Color, ymax: float = 100.0) -> MiniChart:
	var c := MiniChart.new()
	c.kind = Kind.LINE
	c.values = vals
	c.labels = lbls
	c.color = col
	c.y_max = ymax
	return c


func _init() -> void:
	custom_minimum_size = Vector2(0, 150)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_values(vals: Array, lbls: Array = []) -> void:
	values = vals
	labels = lbls
	queue_redraw()


## True when at least one value is a positive number (bars) or any number (line).
func has_data() -> bool:
	for v in values:
		if _num(v):
			if kind == Kind.LINE or float(v) > 0.0:
				return true
	return false


func _num(v: Variant) -> bool:
	return (v is int) or (v is float and is_finite(v))


func _scale_max() -> float:
	if y_max > 0.0:
		return y_max
	var m := 1.0
	for v in values:
		if _num(v):
			m = maxf(m, float(v))
	m = maxf(m, goal_line)
	return m * 1.15


func _draw() -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var w: float = size.x
	var h: float = size.y
	if w < PAD_LEFT + PAD_RIGHT + 10.0 or h < PAD_TOP + PAD_BOTTOM + 20.0:
		return
	var left: float = PAD_LEFT
	var top: float = PAD_TOP
	var plot_w: float = w - PAD_LEFT - PAD_RIGHT
	var plot_h: float = h - PAD_TOP - PAD_BOTTOM
	var base_y: float = top + plot_h
	var ymax: float = _scale_max()
	var grid := Color(Pal.LINE, 1.0)
	var muted := Pal.MUTED

	# baseline + two guide lines with their values
	draw_line(Vector2(left, base_y), Vector2(w - PAD_RIGHT, base_y), grid, 1.0)
	for frac in [0.5, 1.0]:
		var gy: float = base_y - plot_h * frac
		draw_line(Vector2(left, gy), Vector2(w - PAD_RIGHT, gy), Color(grid, 0.6), 1.0)
		var txt: String = "%d" % roundi(ymax * frac)
		draw_string(font, Vector2(0, gy + 4.0), txt, HORIZONTAL_ALIGNMENT_RIGHT, PAD_LEFT - 4.0, FONT_SIZE - 1, muted)
	draw_string(font, Vector2(0, base_y + 4.0), "0", HORIZONTAL_ALIGNMENT_RIGHT, PAD_LEFT - 4.0, FONT_SIZE - 1, muted)

	var n: int = values.size()
	if n == 0:
		return
	var slot: float = plot_w / float(n)
	# x labels
	for i in range(n):
		var lb: String = str(labels[i]) if i < labels.size() else ""
		if lb != "":
			var cx: float = left + slot * (float(i) + 0.5)
			var lw: float = maxf(slot, 48.0)
			draw_string(font, Vector2(clampf(cx - lw * 0.5, 0.0, maxf(w - lw, 0.0)), h - 6.0), lb, HORIZONTAL_ALIGNMENT_CENTER, lw, FONT_SIZE, muted)

	if kind == Kind.BARS:
		_draw_bars(font, left, base_y, plot_h, slot, ymax)
	else:
		_draw_line(font, left, base_y, plot_h, slot, ymax)


func _draw_bars(font: Font, left: float, base_y: float, plot_h: float, slot: float, ymax: float) -> void:
	var bar_w: float = clampf(slot * 0.55, 3.0, 40.0)
	for i in range(values.size()):
		var v: Variant = values[i]
		if not _num(v) or float(v) <= 0.0:
			continue
		var bh: float = clampf(float(v) / ymax, 0.0, 1.0) * plot_h
		bh = maxf(bh, 2.0)
		var x: float = left + slot * (float(i) + 0.5) - bar_w * 0.5
		var col: Color = color if (highlight < 0 or i == highlight) else color.lerp(Color.WHITE, 0.45)
		draw_rect(Rect2(x, base_y - bh, bar_w, bh), col)
		draw_string(font, Vector2(x - 8.0, base_y - bh - 4.0), value_format % roundi(float(v)), HORIZONTAL_ALIGNMENT_CENTER, bar_w + 16.0, FONT_SIZE, Pal.INK)
	if goal_line > 0.0:
		var gy: float = base_y - clampf(goal_line / ymax, 0.0, 1.0) * plot_h
		var x0: float = left
		var x1: float = left + slot * float(values.size())
		var dash := 6.0
		var x: float = x0
		while x < x1:
			draw_line(Vector2(x, gy), Vector2(minf(x + dash, x1), gy), Pal.WARN, 1.5)
			x += dash * 2.0


func _draw_line(font: Font, left: float, base_y: float, plot_h: float, slot: float, ymax: float) -> void:
	var prev := Vector2.ZERO
	var has_prev := false
	var last_pt := Vector2.ZERO
	var last_val := 0.0
	var any := false
	for i in range(values.size()):
		var v: Variant = values[i]
		if not _num(v):
			continue ## a day without data: the line simply connects the neighbours
		var pt := Vector2(left + slot * (float(i) + 0.5), base_y - clampf(float(v) / ymax, 0.0, 1.0) * plot_h)
		if has_prev:
			draw_line(prev, pt, color, 2.0, true)
		draw_circle(pt, 3.5, color)
		prev = pt
		has_prev = true
		last_pt = pt
		last_val = float(v)
		any = true
	if any:
		draw_string(font, Vector2(last_pt.x - 24.0, maxf(last_pt.y - 8.0, 12.0)), value_format % roundi(last_val), HORIZONTAL_ALIGNMENT_CENTER, 48.0, FONT_SIZE, Pal.INK)
