class_name ProsodyPanel
extends Control
## Intonation graph (native vs. learner pitch contour, semitones) and, for Japanese, an OJAD-style
## pitch-accent display: a kana row with a line that steps high/low over every mora (drop marker after
## the accent nucleus) and, when the learner recorded, their detected high/low row (mismatches in red).
## Fed with the response of POST /prosody. See API.md.

const GRAPH_H := 150.0
const HEADER_H := 32.0
const AXIS_W := 34.0
const PAD_R := 8.0
const CELL_W := 36.0
const CAP_H := 20.0
const ROW_H := 54.0
const LINE_GAP := 10.0
const NATIVE_COL := Color("#7D8DA8")

const KIND_KO := {
	"heiban": "평판형",
	"atamadaka": "두고형",
	"nakadaka": "중고형",
	"odaka": "미고형",
}

var lang: String = "en"
var native: Dictionary = {}
var mine: Dictionary = {}
var accent: Array = []
var mine_accent: Array = []
var similarity: Variant = null
var message: String = ""
var show_graph: bool = true

var _last_h: float = -1.0


func _init(l: String = "en") -> void:
	lang = l
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Replaces everything with a /prosody response (or a part of one).
func set_data(res: Dictionary) -> void:
	native = _dict(res.get("native", null))
	mine = _dict(res.get("mine", null))
	accent = _arr(res.get("accent", null))
	mine_accent = _arr(res.get("mine_accent", null))
	similarity = res.get("similarity", null)
	if not native.is_empty():
		message = ""
	_changed()


func set_message(msg: String) -> void:
	message = msg
	_changed()


## Native contour/accent stay, the learner part is removed (e.g. "다시 말하기").
func clear_mine() -> void:
	mine = {}
	mine_accent = []
	similarity = null
	_changed()


static func _dict(v: Variant) -> Dictionary:
	if v is Dictionary and (v as Dictionary).has("t") and (v as Dictionary).has("f0"):
		var d: Dictionary = v
		if d["t"] is Array and d["f0"] is Array and (d["t"] as Array).size() == (d["f0"] as Array).size() and (d["t"] as Array).size() > 1:
			return d
	return {}


static func _arr(v: Variant) -> Array:
	return v if v is Array else []


func _changed() -> void:
	_last_h = -1.0
	update_minimum_size()
	queue_redraw()


# ---------------------------------------------------------------- layout

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		var h: float = _content_height(size.x)
		if absf(h - _last_h) > 0.5:
			_last_h = h
			update_minimum_size()
		queue_redraw()


func _get_minimum_size() -> Vector2:
	var w: float = size.x if size.x > 50.0 else 640.0
	return Vector2(260.0, _content_height(w))


func _per_line(w: float) -> int:
	return maxi(1, int(floorf((w - 2.0 * 6.0) / CELL_W)))


func _accent_height(w: float) -> float:
	if accent.is_empty():
		return 0.0
	var lines: int = ceili(float(accent.size()) / float(_per_line(w)))
	var per: float = CAP_H + ROW_H + ((CAP_H - 6.0 + ROW_H) if not mine_accent.is_empty() else 0.0) + LINE_GAP
	return float(lines) * per


func _content_height(w: float) -> float:
	var h: float = HEADER_H
	if show_graph:
		h += GRAPH_H + 10.0
	if native.is_empty() and show_graph:
		h = HEADER_H + 64.0
	h += _accent_height(w)
	return h


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	var w: float = size.x
	var f: Font = get_theme_default_font()
	var fb: Font = UI.bold_font()
	var acc: Color = Pal.accent(lang)
	_draw_header(w, f, fb, acc)
	var y: float = HEADER_H
	if show_graph:
		if native.is_empty():
			var msg: String = message if message != "" else "억양 정보가 없어요."
			draw_string(f, Vector2(0.0, y + 34.0), msg, HORIZONTAL_ALIGNMENT_CENTER, w, 15, Pal.MUTED)
			y += 64.0
		else:
			_draw_graph(Rect2(AXIS_W, y, maxf(60.0, w - AXIS_W - PAD_R), GRAPH_H), f, acc)
			y += GRAPH_H + 10.0
	if not accent.is_empty():
		_draw_accent(w, y, acc)


func _draw_header(w: float, f: Font, fb: Font, acc: Color) -> void:
	var y: float = 20.0
	var x: float = AXIS_W
	draw_line(Vector2(x, y - 5.0), Vector2(x + 22.0, y - 5.0), NATIVE_COL, 3.0, true)
	draw_string(f, Vector2(x + 28.0, y), "원어민", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Pal.INK)
	x += 28.0 + f.get_string_size("원어민", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 16.0
	var has_mine: bool = not mine.is_empty()
	var mc: Color = acc if has_mine else Color(acc, 0.3)
	draw_line(Vector2(x, y - 5.0), Vector2(x + 22.0, y - 5.0), mc, 3.0, true)
	draw_string(f, Vector2(x + 28.0, y), "나", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Pal.INK if has_mine else Pal.MUTED)
	if has_mine and similarity != null:
		var sim: int = roundi(float(similarity))
		var col: Color = ScorePanel.score_color(float(sim))
		var num: String = str(sim)
		var nw: float = fb.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(fb, Vector2(w - PAD_R - nw, y + 2.0), num, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
		var lbl := "억양 비슷한 정도"
		var lw: float = f.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(f, Vector2(w - PAD_R - nw - 8.0 - lw, y), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Pal.MUTED)
	elif not has_mine and not native.is_empty():
		var hint := "녹음하면 내 억양이 겹쳐 보여요"
		var hw: float = f.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		# narrow panel (phone): use a shorter hint, or none, instead of running into the legend
		var legend_end: float = x + 28.0 + f.get_string_size("나", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 10.0
		if w - PAD_R - hw < legend_end:
			hint = "내 억양이 겹쳐 보여요"
			hw = f.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		if w - PAD_R - hw >= legend_end:
			draw_string(f, Vector2(w - PAD_R - hw, y), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Pal.MUTED)


func _y_range() -> Vector2:
	var lo := 1e9
	var hi := -1e9
	for c in [native, mine]:
		if (c as Dictionary).is_empty():
			continue
		for v in c["f0"]:
			if v != null:
				lo = minf(lo, float(v))
				hi = maxf(hi, float(v))
	if lo > hi:
		return Vector2(-6.0, 6.0)
	var y0: float = floorf((lo - 0.8) / 3.0) * 3.0
	var y1: float = ceilf((hi + 0.8) / 3.0) * 3.0
	if y1 - y0 < 9.0:
		var mid: float = (y0 + y1) * 0.5
		y0 = floorf((mid - 4.5) / 3.0) * 3.0
		y1 = y0 + 9.0
	return Vector2(y0, y1)


func _draw_graph(r: Rect2, f: Font, acc: Color) -> void:
	draw_rect(r, Color(1, 1, 1, 1))
	var yr: Vector2 = _y_range()
	var span: float = yr.y - yr.x
	# horizontal grid every 3 semitones, labels every 6
	var g: float = ceilf(yr.x / 3.0) * 3.0
	while g <= yr.y + 0.01:
		var yy: float = r.end.y - (g - yr.x) / span * r.size.y
		var is_zero: bool = absf(g) < 0.01
		draw_line(Vector2(r.position.x, yy), Vector2(r.end.x, yy), Color("#C9D0DC") if is_zero else Color("#E8ECF2"), 1.5 if is_zero else 1.0)
		if int(roundf(g)) % 6 == 0:
			var lab: String = "평균" if is_zero else ("%+d" % int(g))
			draw_string(f, Vector2(r.position.x - 6.0 - f.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x, yy + 4.0), lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Pal.MUTED)
		g += 3.0
	for i in 5:
		var xx: float = r.position.x + r.size.x * float(i) / 4.0
		draw_line(Vector2(xx, r.position.y), Vector2(xx, r.end.y), Color("#EEF1F5"), 1.0)
	draw_rect(r, Pal.LINE, false, 1.0)
	_draw_curve(native, r, yr, NATIVE_COL, 3.0)
	if not mine.is_empty():
		_draw_curve(mine, r, yr, acc, 3.5)
	# the semitone unit
	draw_string(f, Vector2(r.position.x + 4.0, r.position.y + 13.0), "높음", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Pal.MUTED)
	draw_string(f, Vector2(r.position.x + 4.0, r.end.y - 5.0), "낮음", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Pal.MUTED)


func _draw_curve(c: Dictionary, r: Rect2, yr: Vector2, col: Color, wd: float) -> void:
	var ts: Array = c["t"]
	var fs: Array = c["f0"]
	var span: float = yr.y - yr.x
	var vals: Array[float] = []
	var xs: Array[float] = []
	for i in ts.size():
		var v: Variant = fs[i]
		if v == null:
			_flush_run(xs, vals, r, yr, span, col, wd)
			xs = []
			vals = []
		else:
			xs.append(float(ts[i]))
			vals.append(float(v))
	_flush_run(xs, vals, r, yr, span, col, wd)


func _flush_run(xs: Array[float], vals: Array[float], r: Rect2, yr: Vector2, span: float, col: Color, wd: float) -> void:
	var n: int = vals.size()
	if n == 0:
		return
	var pts := PackedVector2Array()
	for i in n:
		# 3-point smoothing hides the stair steps of the pitch tracker
		var a: float = vals[maxi(0, i - 1)]
		var b: float = vals[i]
		var c: float = vals[mini(n - 1, i + 1)]
		var v: float = (a + 2.0 * b + c) * 0.25
		pts.append(Vector2(r.position.x + clampf(xs[i], 0.0, 1.0) * r.size.x, r.end.y - (clampf(v, yr.x, yr.y) - yr.x) / span * r.size.y))
	if n == 1:
		draw_circle(pts[0], wd * 0.7, col)
	else:
		draw_polyline(pts, col, wd, true)


# ---------------------------------------------------------------- Japanese accent

static func kind_text(a: Dictionary) -> String:
	var k: String = KIND_KO.get(str(a.get("kind", "")), "")
	if k == "":
		return ""
	return "%s[%d]" % [k, int(a.get("type", 0))]


func _draw_accent(w: float, y0: float, acc: Color) -> void:
	var per: int = _per_line(w)
	var n: int = accent.size()
	var f: Font = get_theme_default_font()
	var fj: Font = UI.ja_font(false)
	var has_mine: bool = not mine_accent.is_empty()
	var x_off: float = 6.0
	var y: float = y0
	var line_i := 0
	var i := 0
	while i < n:
		var j: int = mini(n, i + per)
		# caption
		if line_i == 0:
			var cap := "도쿄 악센트"
			var kinds: Array[String] = []
			var phrases: Dictionary = {}
			for a in accent:
				var ph: int = int((a as Dictionary).get("phrase", 0))
				if not phrases.has(ph):
					phrases[ph] = true
					kinds.append(kind_text(a))
			if kinds.size() == 1 and kinds[0] != "":
				cap += " · " + kinds[0]
			draw_string(f, Vector2(x_off, y + 14.0), cap, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Pal.MUTED)
		y += CAP_H
		_draw_row(accent, null, i, j, x_off, y, fj, acc, false)
		y += ROW_H
		if has_mine:
			if line_i == 0:
				draw_string(f, Vector2(x_off, y + 8.0), "내 높낮이  (초록 = 맞음, 빨강 = 달라요, ? = 무성음)", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Pal.MUTED)
			y += CAP_H - 6.0
			_draw_row(accent, mine_accent, i, j, x_off, y, fj, acc, true)
			y += ROW_H
		y += LINE_GAP
		i = j
		line_i += 1


## One kana row with its high/low line. expected = accent list; learner = mine_accent list or null.
func _draw_row(expected: Array, learner: Variant, i0: int, i1: int, x_off: float, y: float, fj: Font, acc: Color, is_mine: bool) -> void:
	var hi_y: float = y + 7.0
	var lo_y: float = y + 21.0
	var base_y: float = y + 46.0
	var drop_col: Color = Pal.INK
	var run := PackedVector2Array()
	var prev_phrase: int = -1
	for k in range(i0, i1):
		var e: Dictionary = expected[k]
		var lx: float = x_off + float(k - i0) * CELL_W
		var rx: float = lx + CELL_W
		var ph: int = int(e.get("phrase", 0))
		var high: Variant = bool(e.get("high", false))
		var col: Color = acc
		var txt: String = str(e.get("mora", ""))
		if is_mine:
			var m: Dictionary = (learner as Array)[k] if k < (learner as Array).size() and (learner as Array)[k] is Dictionary else {}
			high = m.get("high", null)
			if high == null:
				col = Pal.MUTED
			elif bool(high) == bool(e.get("high", false)):
				col = Pal.OK
			else:
				col = Pal.BAD
		else:
			col = acc
		# kana
		var tcol: Color = Pal.INK
		if is_mine:
			tcol = col if high != null else Pal.MUTED
		var tw: float = fj.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		draw_string(fj, Vector2(lx + (CELL_W - tw) * 0.5, base_y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, tcol)
		# line segment
		if not is_mine:
			if prev_phrase != -1 and ph != prev_phrase:
				_flush_line(run, acc)
				run = PackedVector2Array()
			var ly: float = hi_y if bool(high) else lo_y
			run.append(Vector2(lx, ly))
			run.append(Vector2(rx, ly))
			prev_phrase = ph
			if bool(e.get("nucleus", false)):
				_flush_line(run, acc)
				run = PackedVector2Array()
				_draw_drop(rx, hi_y, lo_y, drop_col)
				# the line continues (low) with the next mora of the same phrase
				prev_phrase = -1
		else:
			if high == null:
				draw_line(Vector2(lx + 10.0, (hi_y + lo_y) * 0.5), Vector2(rx - 10.0, (hi_y + lo_y) * 0.5), Color(col, 0.7), 2.0, true)
				draw_string(fj, Vector2(lx + CELL_W * 0.5 - 4.0, hi_y - 2.0), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Pal.MUTED)
			else:
				var ly2: float = hi_y if bool(high) else lo_y
				draw_line(Vector2(lx + 2.0, ly2), Vector2(rx - 2.0, ly2), col, 3.5, true)
				# step connector to the next mora when the level changes
				if k + 1 < i1 and (learner as Array)[k + 1] is Dictionary:
					var nxt: Variant = ((learner as Array)[k + 1] as Dictionary).get("high", null)
					if nxt != null and bool(nxt) != bool(high) and int((expected[k + 1] as Dictionary).get("phrase", 0)) == ph:
						draw_line(Vector2(rx - 2.0, hi_y), Vector2(rx - 2.0, lo_y), Color(col, 0.55), 2.0, true)
	if not is_mine:
		_flush_line(run, acc)


func _flush_line(run: PackedVector2Array, col: Color) -> void:
	if run.size() < 2:
		return
	# stepping line: consecutive points share x at cell borders, so vertical steps appear automatically
	var pts := PackedVector2Array()
	for p in run:
		pts.append(p)
	draw_polyline(pts, col, 3.5, true)


func _draw_drop(x: float, hi_y: float, lo_y: float, col: Color) -> void:
	draw_line(Vector2(x, hi_y), Vector2(x, lo_y - 3.0), col, 2.5, true)
	var tri := PackedVector2Array([Vector2(x - 5.0, lo_y - 5.0), Vector2(x + 5.0, lo_y - 5.0), Vector2(x, lo_y + 3.0)])
	draw_colored_polygon(tri, col)


# ---------------------------------------------------------------- helpers for callers

## Card-less tips list for the prosody result (Korean sentences from /prosody tips_ko).
static func tips_box(tips: Array) -> Control:
	var tb := UI.card("Sunk", 6)
	tb.body.add_child(UI.label("억양 팁", "Eyebrow", false))
	for t in tips:
		tb.body.add_child(UI.label("• " + str(t)))
	return tb
