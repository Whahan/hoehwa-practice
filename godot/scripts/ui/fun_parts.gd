class_name FunParts
extends RefCounted
## 재미 기능 화면 조각(주간 리포트 카드, 홈 "이번 주" 카드, 배지 타일). docs/v160_fun_design.md §4.4~4.6, §5.3 B2.
##
## 이 파일은 데이터를 스스로 읽지 않는다: 리포트 사전(WeekReport.build 결과), 배지 개수, 배지 정보(BadgeEngine.ui_list 항목)를
## 인자로 받는다. StudyLog / Store / BadgeEngine 을 부르지 않는다. 색은 Pal 토큰만, 도형은 GlyphIcon 만(이모지·도형 글자 없음).
## 모양이 틀린 입력(null, {}, 숫자가 아닌 값, NaN, 음수)은 에러 없이 "기록 없음" / 0 으로 그린다.

const TILE_ICON := 36.0
const TILE_PAD := 8.0
const TILE_NAME_LINES := 3
const DOT_D := 12.0
const NOTE_FIRST_WEEK := "새 카드는 1.6.0부터 세요"
const NOTE_NO_RECORD := "아직 기록이 없어요. 오늘 10분만 해 볼까요?"
const NOTE_HOME_EMPTY := "공부를 시작하면 이번 주 기록이 여기에 쌓여요"
const NOTE_NEW_BADGE := "새 배지"
const LANG_NAME := {"en": "영어", "ja": "일본어"}


# ---------------------------------------------------------------- 값 청소

## 0 이상 hi 이하 정수. 숫자가 아니거나(문자열·null·bool·배열) NaN·INF 면 dflt.
static func _i(v: Variant, dflt: int = 0, hi: int = 1000000) -> int:
	if v is int:
		return clampi(v, -1, hi) if (v as int) < 0 else mini(v, hi)
	if v is float:
		if is_nan(v) or is_inf(v):
			return dflt
		return clampi(int(v), -1, hi) if v < 0.0 else int(minf(v, float(hi)))
	return dflt


## true/false 만 믿는다(숫자 0/1 도 받는다). 그 밖의 값은 false.
static func _b(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	return false


## "2026-11-08" -> "11.08". 날짜 모양이 아니면 "".
static func _md(iso: Variant) -> String:
	if not (iso is String):
		return ""
	var p: PackedStringArray = (iso as String).split("-")
	if p.size() != 3 or not (p[1] as String).is_valid_int() or not (p[2] as String).is_valid_int():
		return ""
	return "%02d.%02d" % [int(p[1]), int(p[2])]


## 리포트 사전이 "기록 없음" 인가: 사전이 아니거나, WeekReport 결과 모양이 아니거나("minutes" 없음), empty == true.
static func report_is_empty(report: Variant) -> bool:
	if not (report is Dictionary) or not (report as Dictionary).has("minutes"):
		return true
	return _b((report as Dictionary).get("empty", false))


## "공부 128분 · 레슨 6개 · 새 카드 18" (홈 카드·compact 카드용). 기록 없음이면 "".
static func numbers_line(report: Variant) -> String:
	if report_is_empty(report):
		return ""
	var r: Dictionary = report
	return "공부 %d분 · 레슨 %d개 · 새 카드 %d" % [maxi(0, _i(r.get("minutes", 0))), maxi(0, _i(r.get("lessons", 0))), maxi(0, _i(r.get("new_cards", 0)))]


# ---------------------------------------------------------------- 주간 리포트 카드 (§4.5)

## compact=false: 전체 카드(공부한 날, 공부 시간, 레슨, 새 카드, 발음 점수, 규칙 문구). compact=true: 숫자 3개 한 줄만.
## meta "report" = 받은 사전(복사), "empty" = 기록 없음 여부, "line" = compact 의 한 줄 글자.
static func report_card(report: Variant, compact: bool = false) -> CardBox:
	var card := UI.card("Card", Ds.S3)
	var rep: Dictionary = (report as Dictionary).duplicate(true) if report is Dictionary else {}
	var empty: bool = report_is_empty(rep)
	card.set_meta("report", rep)
	card.set_meta("empty", empty)
	if compact:
		var line: String = numbers_line(rep)
		card.set_meta("line", line)
		card.body.add_child(UI.label(line if line != "" else NOTE_HOME_EMPTY, "Strong" if line != "" else "Small"))
		return card

	var lang: String = str(rep.get("lang", ""))
	var title: String = "이번 주 리포트"
	var a: String = _md(rep.get("from", ""))
	var b: String = _md(rep.get("to", ""))
	if a != "" and b != "":
		title += " · %s ~ %s" % [a, b]
	if LANG_NAME.has(lang):
		title += " (%s)" % LANG_NAME[lang]
	card.body.add_child(UI.label(title, "Strong"))

	if empty:
		var msg: String = NOTE_NO_RECORD
		var ls: Variant = rep.get("lines", null)
		if ls is Array and (ls as Array).size() > 0 and str((ls as Array)[0]) != "":
			msg = str((ls as Array)[0])
		card.body.add_child(UI.label(msg, "Muted"))
		card.body.add_child(UI.label("공부 시간 · 레슨 · 새 카드 · 발음 점수가 여기에 쌓여요", "Small"))
		return card

	card.body.add_child(_row("공부한 날", "%d / 7일" % clampi(_i(rep.get("days_studied", 0)), 0, 7)))
	card.body.add_child(_row("공부 시간", _time_text(rep)))
	card.body.add_child(_row("레슨", _lesson_text(rep)))
	card.body.add_child(_row("새 카드", "%d · 복습 %d번" % [maxi(0, _i(rep.get("new_cards", 0))), maxi(0, _i(rep.get("reviews", 0)))]))
	card.body.add_child(_row("발음 점수", _score_text(rep)))
	var lines: Variant = rep.get("lines", null)
	if lines is Array:
		var first := true
		for ln in (lines as Array):
			var t: String = str(ln)
			if t == "":
				continue
			card.body.add_child(UI.label(t, "Strong" if first else "Muted"))
			first = false
	card.body.add_child(UI.label(NOTE_FIRST_WEEK, "Small"))
	return card


## 한 줄: 앞 이름(흐림, 줄바꿈 안 함) + 값(굵게, 오른쪽 정렬, 칸이 모자라면 줄바꿈). 큰 글자에서도 가로로 삐져나오지 않는다.
static func _row(name: String, value: String) -> Control:
	var h := UI.hbox(Ds.S3)
	var n := UI.label(name, "Muted", false)
	n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(n)
	var v := UI.label(value, "Strong")
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	h.set_meta("name", name)
	h.set_meta("value", value)
	return h


static func _time_text(r: Dictionary) -> String:
	var m: int = maxi(0, _i(r.get("minutes", 0)))
	var prev: int = maxi(0, _i(r.get("minutes_prev", 0)))
	var d: int = m - prev
	var t: String = "%d분" % m
	if prev <= 0:
		return t + " (지난주 기록 없음)"
	if d > 0:
		return t + " (지난주 +%d분)" % d
	if d < 0:
		return t + " (지난주 %d분)" % d
	return t + " (지난주와 같아요)"


static func _lesson_text(r: Dictionary) -> String:
	var n: int = maxi(0, _i(r.get("lessons", 0)))
	var t: String = "%d개" % n
	var acc: int = _i(r.get("lesson_acc", -1), -1, 100)
	if acc >= 0:
		t += " · 정답률 %d%%" % acc
		var prev: int = _i(r.get("lesson_acc_prev", -1), -1, 100)
		if prev >= 0:
			t += " (지난주 %d%%)" % prev
	return t


static func _score_text(r: Dictionary) -> String:
	var avg: int = _i(r.get("score_avg", -1), -1, 100)
	var sn: int = maxi(0, _i(r.get("score_n", 0)))
	if avg < 0 or sn <= 0:
		return "기록이 적어요"
	var t: String = "평균 %d점" % avg
	var d: Variant = r.get("score_delta", null)
	if d is int or d is float:
		var di: int = _i(d, 0, 100) if float(d) >= 0.0 else -_i(-float(d), 0, 100)
		var prev: int = _i(r.get("score_prev", -1), -1, 100)
		if prev >= 0:
			t += " (지난주 %d점, %s%d)" % [prev, "+" if di >= 0 else "-", absi(di)]
		else:
			t += " (%s%d)" % ["+" if di >= 0 else "-", absi(di)]
	else:
		t += " (비교하기엔 기록이 적어요)"
	return t


# ---------------------------------------------------------------- 홈 "이번 주" 카드 (§4.6)

## on_open(kind: String): "report" | "speed" | "kana" | "badges".
## meta "buttons" = {"speed": Button, "kana": Button | null (일본어가 아니면), "badges": Button}, "tap_area" = 본문(눌러서 "report"),
## "numbers" = 숫자 줄 Label, "badge_dot" = 새 배지 점(새 배지가 없으면 이 meta 가 없다).
static func home_card(lang: String, report: Variant, badge_counts: Variant, on_open: Callable) -> CardBox:
	var card := UI.card("Card", Ds.S3)
	card.set_meta("lang", lang)

	var head := UI.vbox(4)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.custom_minimum_size.y = Ds.touch_min()
	var title_row := UI.hbox(Ds.S2)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tl := UI.label("이번 주", "Strong")
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(tl)
	var chev := GlyphIcon.new("chevron_right", 18.0, Pal.MUTED)
	chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(chev)
	head.add_child(title_row)
	var line: String = numbers_line(report)
	var nl: Label = UI.label(line if line != "" else NOTE_HOME_EMPTY, "Muted" if line != "" else "Small")
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(nl)
	UI.on_tap(head, func() -> void: _open(on_open, "report"))
	head.accessibility_name = "이번 주 리포트 보기"
	card.body.add_child(head)
	card.set_meta("tap_area", head)
	card.set_meta("numbers", nl)

	var got: int = 0
	var total: int = 0
	var unseen: int = 0
	if badge_counts is Dictionary:
		got = maxi(0, _i((badge_counts as Dictionary).get("got", 0)))
		total = maxi(0, _i((badge_counts as Dictionary).get("total", 0)))
		unseen = maxi(0, _i((badge_counts as Dictionary).get("unseen", 0)))
	var btns := UI.flow(Ds.S2, Ds.S2)
	var speed := UI.button("60초 퀴즈", "soft", Pal.PRIMARY, 48.0)
	speed.pressed.connect(func() -> void: _open(on_open, "speed"))
	btns.add_child(speed)
	var kana: Button = null
	if lang == "ja":
		kana = UI.button("가나 코스", "soft", Pal.PRIMARY, 48.0)
		kana.pressed.connect(func() -> void: _open(on_open, "kana"))
		btns.add_child(kana)
	var btext: String = "배지 %d/%d" % [got, total] if total > 0 else "배지"
	var badges := UI.button(btext, "soft", Pal.REWARD, 48.0)
	badges.pressed.connect(func() -> void: _open(on_open, "badges"))
	var dot: GlyphIcon = null
	if unseen > 0:
		badges.accessibility_name = "%s, %s %d개" % [btext, NOTE_NEW_BADGE, unseen]
		dot = _pin_dot(badges)
	btns.add_child(badges)
	card.body.add_child(btns)
	card.set_meta("buttons", {"speed": speed, "kana": kana, "badges": badges})
	if dot != null:
		card.set_meta("badge_dot", dot)
	return card


static func _open(on_open: Callable, kind: String) -> void:
	if on_open.is_valid():
		on_open.call(kind)


## 버튼 오른쪽 위 모서리의 새 배지 점(도형, 터치는 버튼이 받는다).
static func _pin_dot(b: Control) -> GlyphIcon:
	var d := GlyphIcon.new("record", DOT_D * 2.0, Pal.REWARD)
	d.custom_minimum_size = Vector2.ZERO
	d.anchor_left = 1.0
	d.anchor_right = 1.0
	d.anchor_top = 0.0
	d.anchor_bottom = 0.0
	d.offset_left = -DOT_D - 6.0
	d.offset_right = -6.0
	d.offset_top = 6.0
	d.offset_bottom = 6.0 + DOT_D
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.set_meta("new_dot", true)
	b.add_child(d)
	return d


# ---------------------------------------------------------------- 배지 타일 (§4.4)

## info = {id, name, desc, cat, glyph, got, at, retro, value, target, is_new}. 이름이 비었거나 target <= 0 인 항목도 에러 없이 만든다
## (걸러내는 것은 BadgeView). 받은 것: 별(REWARD) + 이름 + 날짜 "11.02". 못 받은 것: 자물쇠(흐림) + 이름 + 진행 "3/30".
## meta "id", "got", "is_new", "sub" (아래 글자). 새 배지면 오른쪽 위에 점 도형(meta "new_dot").
static func badge_tile(info: Variant, on_tap: Callable) -> Button:
	var d: Dictionary = info if info is Dictionary else {}
	var id: String = str(d.get("id", ""))
	var nm: String = str(d.get("name", ""))
	var got: bool = _b(d.get("got", false))
	var is_new: bool = got and _b(d.get("is_new", false))
	var target: int = maxi(0, _i(d.get("target", 0)))
	var value: int = clampi(_i(d.get("value", 0)), 0, target) if target > 0 else maxi(0, _i(d.get("value", 0)))
	var sub: String = ""
	if got:
		sub = _md(d.get("at", ""))
	else:
		sub = "%d/%d" % [value, target]

	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.text = ""
	b.clip_contents = true
	b.accessibility_name = _tile_a11y(nm, got, sub, is_new)
	b.set_meta("id", id)
	b.set_meta("got", got)
	b.set_meta("is_new", is_new)
	b.set_meta("sub", sub)
	var bg: Color = Pal.REWARD_SOFT if got else Pal.SURFACE
	var border: Color = Pal.REWARD if got else Pal.LINE_STRONG
	var st := UI.style(bg, border, 2 if got else 1, Ds.R_S, 6, 6)
	var hv := UI.style(bg.lerp(Pal.REWARD, 0.08), border, 2 if got else 1, Ds.R_S, 6, 6)
	var pr := UI.style(bg.lerp(Pal.REWARD, 0.16), border, 2 if got else 1, Ds.R_S, 6, 6)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("disabled", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("hover_pressed", pr)
	b.add_theme_stylebox_override("focus", UI.style(Color(0, 0, 0, 0), Pal.PRIMARY, 2, Ds.R_S, 6, 6))

	var vb := UI.vbox(4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = TILE_PAD
	vb.offset_right = -TILE_PAD
	vb.offset_top = TILE_PAD
	vb.offset_bottom = -TILE_PAD
	var gk: String = str(d.get("glyph", "star"))
	if not got:
		gk = "lock"
	elif not GlyphIcon.KINDS.has(gk):
		gk = "star"
	var icon := GlyphIcon.new(gk, TILE_ICON, Pal.REWARD if got else Pal.MUTED)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(icon)
	var nl := UI.label(nm, "Small")
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nl.max_lines_visible = TILE_NAME_LINES
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.add_theme_color_override("font_color", Pal.REWARD_ON if got else Pal.INK)
	nl.add_theme_font_override("font", UI.bold_font())
	nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(nl)
	var sl := UI.label(sub, "Small")
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sl.add_theme_color_override("font_color", Pal.MUTED)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(sl)
	b.add_child(vb)
	b.set_meta("name_label", nl)
	b.set_meta("sub_label", sl)
	b.set_meta("icon", icon)

	b.custom_minimum_size.y = maxf(Ds.touch_min() * 2.0, 96.0)
	var fit := func() -> void:
		if is_instance_valid(b) and is_instance_valid(vb):
			var want: float = maxf(maxf(Ds.touch_min() * 2.0, 96.0), vb.get_combined_minimum_size().y + TILE_PAD * 2.0)
			if absf(b.custom_minimum_size.y - want) > 0.5:
				b.custom_minimum_size.y = want
	vb.minimum_size_changed.connect(fit)
	b.set_meta("fit", fit)

	if is_new:
		_pin_dot(b)
	b.pressed.connect(func() -> void:
		if on_tap.is_valid():
			on_tap.call())
	return b


static func _tile_a11y(nm: String, got: bool, sub: String, is_new: bool) -> String:
	var s: String = nm + (", 받음 " if got else ", 못 받음 ") + sub
	if is_new:
		s += ", " + NOTE_NEW_BADGE
	return s
