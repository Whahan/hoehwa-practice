class_name HomeParts
extends RefCounted
## 홈 화면의 부품 (docs/home_menu_design.md §7, §8.5, §9.5). TodayView 가 조립한다. 색은 전부 Pal 토큰, 도형은 코드로 그린다
## (글자 도형·이모지 없음). 눌리는 것은 BaseButton 뿐이다(터치 스크롤이 버튼을 PASS 로 바꾸므로).
##
## 정적 함수: snapshot, task_row, resume_card, streak_card, stones, ai_card, shortcut_tiles, kind_mark, summary_text.

const WD := ["일", "월", "화", "수", "목", "금", "토"]
const ZWSP := "\u200b" ## zero-width space
const SHORTCUTS := [["대화", "talk"], ["연습", "practice"], ["읽기", "reading"]]

## 시험 전용: 0..23 이면 그 값을 현지 시각(hour)으로 쓴다. -1 = 시스템 시계.
static var hour_override: int = -1


# ---------------------------------------------------------------- snapshot (HomeModel.snapshot 의 본문)

## 실제 값으로 HomeModel 스냅샷을 만든다 (설계 §9.3). 값이 하나라도 이상해도 HomeModel 이 기본값으로 막는다.
static func snapshot(lang: String) -> Dictionary:
	var l: String = lang if (lang == "en" or lang == "ja") else "en"
	var pos: Dictionary = Store.position()
	var rec: Dictionary = {}
	var rs: Array = StudyLog.range_summary(l, 1)
	if rs.size() > 0 and rs[0] is Dictionary:
		rec = rs[0]
	var counts: Dictionary = rec.get("n", {}) if rec.get("n", {}) is Dictionary else {}
	var st: Dictionary = StudyLog.settle(l)
	var cell: Dictionary = PathModel.current_cell(l)
	var has_data: bool = StudyLog.has_data(l)
	var unix: int = StudyLog.unix_override if StudyLog.unix_override >= 0 else int(Time.get_unix_time_from_system())
	var hour: int = hour_override if (hour_override >= 0 and hour_override <= 23) else int(Time.get_datetime_dict_from_system().get("hour", 12))
	var snap := {
		"lang": l,
		"phase": str(pos.get("phase", "on")),
		"before_days": int(pos.get("days", 0)) if str(pos.get("phase", "on")) == "before" else 0,
		"lesson_today": int(counts.get("lessons", 0)),
		"due": Store.due_count(l),
		"reviews_today": int(counts.get("reviews", 0)),
		"song_due": SongDue.due_lines(),
		"song_count": int(SongDue.cache.get("songs", 0)),
		"path": {"n": int(cell.get("n", 1)), "w": int(cell.get("w", 1)), "done": int(cell.get("done", 0)),
			"goal": int(cell.get("goal", PathModel.NODE_GOAL)), "finished": bool(cell.get("finished", false))},
		"goal_min": StudyLog.goal_minutes(),
		"sec_today": StudyLog.today_seconds(l),
		"streak": int(st.get("streak", 0)),
		"tokens": int(st.get("tokens", 0)),
		"studied_today": Store.did_day(StudyLog.today(), l),
		"has_data": has_data,
		"first_run": (not has_data) and Store.xp(l) == 0,
		"hour": hour,
		"now": unix,
		"resume": StudyLog.resume(),
	}
	return snap


# ---------------------------------------------------------------- small drawn marks

## 할 일 줄 앞 표시: done = 채운 원 + 체크, todo = 굵은 윤곽 원, optional = 얇은 윤곽 원 + 가운데 점.
class Mark extends Control:
	var state: String = "todo"

	func _init(s: String = "todo", d: float = 24.0) -> void:
		state = s
		custom_minimum_size = Vector2(d, d)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var d: float = minf(size.x, size.y)
		var c := Vector2(size.x, size.y) * 0.5
		var r: float = d * 0.5 - 1.5
		match state:
			"done":
				draw_circle(c, r + 1.0, Pal.PRIMARY)
				var pts := PackedVector2Array([c + Vector2(-0.26, 0.02) * d, c + Vector2(-0.07, 0.22) * d, c + Vector2(0.28, -0.2) * d])
				draw_polyline(pts, Pal.ON_ACCENT, maxf(2.0, d * 0.1), true)
			"optional":
				draw_arc(c, r, 0.0, TAU, 40, Pal.LINE_STRONG, 1.5, true)
				draw_circle(c, d * 0.09, Pal.LINE_STRONG)
			"ok":
				draw_circle(c, r + 1.0, Pal.OK_SOFT)
				var p2 := PackedVector2Array([c + Vector2(-0.24, 0.02) * d, c + Vector2(-0.06, 0.2) * d, c + Vector2(0.26, -0.18) * d])
				draw_polyline(p2, Pal.OK_ON, maxf(2.0, d * 0.1), true)
			"warn":
				draw_circle(c, r + 1.0, Pal.WARN_SOFT)
				draw_line(c + Vector2(0, -0.24) * d, c + Vector2(0, 0.06) * d, Pal.WARN_ON, maxf(2.0, d * 0.11), true)
				draw_circle(c + Vector2(0, 0.21) * d, maxf(1.5, d * 0.065), Pal.WARN_ON)
			"info":
				draw_circle(c, r + 1.0, Pal.PRIMARY_SOFT)
				draw_circle(c, d * 0.13, Pal.PRIMARY)
			"dot":
				draw_circle(c, r, Pal.WARN)
			_:
				draw_arc(c, r, 0.0, TAU, 40, Pal.PRIMARY, 2.5, true)


## 주간 돌 하나(표시만, 터치 아님). state: done / today / frozen / missed / future.
class Stone extends Control:
	var state: String = "future"

	func _init(s: String = "future", d: float = Ds.STONE_D) -> void:
		state = s
		custom_minimum_size = Vector2(d, d)
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var d: float = minf(size.x, size.y)
		var c := Vector2(size.x, size.y) * 0.5
		var r: float = d * 0.5 - 1.5
		match state:
			"done":
				draw_circle(c, r + 1.0, Pal.REWARD)
				var pts := PackedVector2Array([c + Vector2(-0.24, 0.02) * d, c + Vector2(-0.06, 0.2) * d, c + Vector2(0.26, -0.18) * d])
				draw_polyline(pts, Pal.ON_ACCENT, maxf(2.0, d * 0.1), true)
			"today":
				draw_arc(c, r, 0.0, TAU, 40, Pal.REWARD, 3.0, true)
			"frozen":
				draw_circle(c, r, Pal.REWARD_SOFT)
				draw_arc(c, r, 0.0, TAU, 40, Pal.REWARD, 2.0, true)
			"missed":
				draw_arc(c, r, 0.0, TAU, 40, Pal.LINE_STRONG, 2.0, true)
			_:
				draw_circle(c, d * 0.11, Pal.LINE_STRONG)


static func kind_mark(kind: String, d: float = 22.0) -> Control:
	var m := Mark.new(kind if kind in ["ok", "warn", "info"] else "info", d)
	m.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	return m


# ---------------------------------------------------------------- 할 일 줄 / 요약

## "레슨 1 · 복습 12 · 노래 4줄": 남은(todo) 일의 짧은 요약. 하나도 없으면 "오늘 할 일을 다 했어요".
static func summary_text(tasks: Array) -> String:
	var parts: Array = []
	for t in tasks:
		if str((t as Dictionary).get("state", "")) != "todo":
			continue
		match str(t.get("id", "")):
			"lesson":
				parts.append("레슨 1")
			"review":
				parts.append("복습 " + _digits(str(t.get("title", ""))))
			"song":
				parts.append("노래 " + _digits(str(t.get("title", ""))) + "줄")
	if parts.is_empty():
		return "오늘 할 일을 다 했어요"
	return " · ".join(parts)


static func _digits(s: String) -> String:
	var out := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			out += ch
	return out if out != "" else "0"


## 할 일 한 줄: 왼쪽 정렬 평면 Button(글자 = 제목) + 앞 표시 + 뒤 화살표, 부연이 있으면 버튼 아래 작은 글자.
## 반환한 줄의 meta "button" 이 그 Button, "task_id" 가 줄 id.
static func task_row(t: Dictionary, on_tap: Callable) -> Control:
	var state: String = str(t.get("state", "todo"))
	var title: String = str(t.get("title", ""))
	var sub: String = str(t.get("sub", ""))
	var row := UI.vbox(0)
	row.set_meta("task_id", str(t.get("id", "")))
	# A finished review row ("복습 끝!") must not look like a "복습 N개" button to review_walk_test (no review button when nothing is
	# due): an invisible zero-width space in front keeps the visible text and takes it out of the "복습 " prefix rule.
	var shown: String = title
	if state == "done" and title.begins_with("복습 "):
		shown = ZWSP + title
	var b := UI.button(shown, "flat", Pal.INK, Ds.TASK_ROW_H)
	b.accessibility_name = title
	b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, Ds.TASK_ROW_H)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = false
	var bg0 := Color(0, 0, 0, 0)
	var normal: StyleBoxFlat = UI.style(bg0, bg0, 0, Ds.R_S, 44, 10)
	normal.content_margin_right = 36.0
	var hover: StyleBoxFlat = UI.style(Pal.SUNK, bg0, 0, Ds.R_S, 44, 10)
	hover.content_margin_right = 36.0
	for n in ["normal", "disabled"]:
		b.add_theme_stylebox_override(n, normal)
	for n in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(n, hover)
	b.add_theme_stylebox_override("focus", UI.style(bg0, Pal.PRIMARY, 2, Ds.R_S, 44, 10))
	var fg: Color = Pal.MUTED if state == "done" else Pal.INK
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(n, fg)
	b.add_theme_font_size_override("font_size", Ds.fs(Ds.type_size("Strong")))
	if state != "done":
		b.add_theme_font_override("font", UI.bold_font())
	var mark := Mark.new(state if state in ["done", "optional"] else "todo", 24.0)
	mark.accessibility_name = {"done": "끝냄", "optional": "선택", "todo": "할 일"}.get(state, "할 일")
	_pin(mark, true, 12.0, 24.0)
	b.add_child(mark)
	var chev := GlyphIcon.new("chevron_right", 18.0, Pal.MUTED)
	_pin(chev, false, 10.0, 18.0)
	b.add_child(chev)
	b.pressed.connect(func() -> void: on_tap.call())
	row.add_child(b)
	row.set_meta("button", b)
	if sub != "":
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 44)
		m.add_theme_constant_override("margin_right", 36)
		m.add_theme_constant_override("margin_bottom", 6)
		var sl := UI.label(sub, "Small")
		sl.add_theme_color_override("font_color", Pal.MUTED)
		m.add_child(sl)
		row.add_child(m)
	return row


## 버튼 안쪽 가장자리에 세로 가운데로 붙이는 장식(터치는 버튼이 받는다).
static func _pin(c: Control, left: bool, gap: float, w: float) -> void:
	c.anchor_top = 0.5
	c.anchor_bottom = 0.5
	c.offset_top = -w * 0.5
	c.offset_bottom = w * 0.5
	if left:
		c.anchor_left = 0.0
		c.anchor_right = 0.0
		c.offset_left = gap
		c.offset_right = gap + w
	else:
		c.anchor_left = 1.0
		c.anchor_right = 1.0
		c.offset_left = -gap - w
		c.offset_right = -gap
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ---------------------------------------------------------------- 이어하기

## r = HomeModel.resume() 결과(title, sub, button). 버튼 글자는 r.button.
static func resume_card(r: Dictionary, on_tap: Callable) -> CardBox:
	var card := UI.card("Card", Ds.S3)
	var row := UI.hbox(Ds.S3)
	var col := UI.vbox(2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UI.label(str(r.get("title", "")), "Strong"))
	var sub: String = str(r.get("sub", ""))
	if sub != "":
		col.add_child(UI.label(sub, "Small"))
	row.add_child(col)
	var b := UI.button(str(r.get("button", "시작")), "soft", Pal.PRIMARY, 48.0)
	b.custom_minimum_size.x = 88.0
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(func() -> void: on_tap.call())
	row.add_child(b)
	card.body.add_child(row)
	card.set_meta("button", b)
	return card


# ---------------------------------------------------------------- 연속

## 이번 주(월~일) 돌 7개 + 요일 글자. 돌 상태는 각 돌의 meta "stone_state", 줄의 meta "states" 에 있다.
static func stone_states(lang: String) -> Array:
	var today: int = StudyLog.today()
	var mon: int = Plan.monday_of(today)
	var frozen: Dictionary = StudyLog.frozen_days(lang)
	var out: Array = []
	for i in 7:
		var d: int = mon + i
		var did: bool = Store.did_day(d, lang)
		var s: String
		if d > today:
			s = "future"
		elif d == today:
			s = "done" if did else "today"
		elif did:
			s = "done"
		elif frozen.has(d):
			s = "frozen"
		else:
			s = "missed"
		out.append(s)
	return out


static func stones(lang: String) -> Control:
	var today: int = StudyLog.today()
	var mon: int = Plan.monday_of(today)
	var states: Array = stone_states(lang)
	var row := UI.hbox(Ds.S1)
	row.name = "Stones"
	row.set_meta("states", states)
	for i in 7:
		var d: int = mon + i
		var col := UI.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var st := Stone.new(str(states[i]))
		st.name = "Stone%d" % i
		st.set_meta("stone_state", str(states[i]))
		st.accessibility_name = "%s요일 %s" % [WD[Plan.weekday(d)], {"done": "공부함", "today": "오늘", "frozen": "보호권으로 지킴", "missed": "쉼", "future": "앞으로"}.get(str(states[i]), "")]
		col.add_child(st)
		var wl := Label.new()
		wl.text = WD[Plan.weekday(d)]
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wl.add_theme_font_size_override("font_size", Ds.fs(12))
		wl.add_theme_color_override("font_color", Pal.INK if d == today else Pal.MUTED)
		if d == today:
			wl.add_theme_font_override("font", UI.bold_font())
		col.add_child(wl)
		row.add_child(col)
	return row


## 연속 카드: 보라 숫자 알약(+ 보호권 칩), 돌 7개, "XP · 별" + 별 진행 바, 직접 표시 체크 줄. meta "toggle_button"(CheckBox), "toggle_label".
static func streak_card(lang: String, snap: Dictionary, on_toggle: Callable) -> CardBox:
	var card := UI.card("Card", Ds.S3)
	var head := UI.flow(Ds.S2, Ds.S2)
	var streak: int = int(snap.get("streak", 0))
	head.add_child(pill("연속 %d일" % streak if streak > 0 else "오늘부터 시작"))
	var tokens: int = int(snap.get("tokens", 0))
	if tokens > 0:
		head.add_child(UI.chip("보호권 %d" % tokens, Pal.REWARD_ON, Pal.REWARD_SOFT))
	card.body.add_child(head)
	card.body.add_child(stones(lang))
	var stars: int = 0
	for f in PathModel.done_flags(lang):
		if f:
			stars += 1
	var info := UI.label("XP %d · 별 %d/%d" % [Store.xp(lang), stars, PathModel.CELLS], "Small")
	card.body.add_child(info)
	card.body.add_child(UI.progress_bar(float(stars) / float(PathModel.CELLS), Pal.REWARD, 8.0))
	# the direct mark: a check row (the same control the old 오늘 screen used for its weekly check), flat, not a second filled button
	var marked: bool = Store.did_day(StudyLog.today(), lang)
	var row := UI.check_row("표시 취소" if marked else "오늘 공부한 걸로 표시", marked, func(_on: bool) -> void: on_toggle.call())
	card.body.add_child(row)
	card.set_meta("toggle_button", row.get_child(0)) # the CheckBox
	card.set_meta("toggle_label", (row.get_child(1) as Control).get_child(0)) # its text label
	card.set_meta("pill_text", "연속 %d일" % streak if streak > 0 else "오늘부터 시작")
	return card


## 보라 알약: 반짝임 도형 + 굵은 숫자 글자(REWARD_ON on REWARD_SOFT).
static func pill(text: String) -> PanelContainer:
	var p := UI.tinted_panel(Pal.REWARD_SOFT, Color(0, 0, 0, 0), 0, Ds.R_PILL, 12, 6)
	var h := UI.hbox(6)
	var g := GlyphIcon.new("sparkle", 18.0, Pal.REWARD)
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(g)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", Ds.fs(Ds.type_size("Strong")))
	l.add_theme_color_override("font_color", Pal.REWARD_ON)
	l.add_theme_font_override("font", UI.bold_font())
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	p.add_child(h)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.set_meta("label", l)
	return p


# ---------------------------------------------------------------- AI 연결 자리

## slot = HomeAi.slot() 결과. 버튼 글자는 slot.action(비면 버튼 없음). [나중에] 는 dismissible 이고 prominent 가 아닐 때만.
## meta "action_button", "later_button".
static func ai_card(slot: Dictionary, on_action: Callable, on_later: Callable) -> CardBox:
	var card := UI.card("Card", Ds.S3)
	var head := UI.hbox(Ds.S2)
	var dot := Mark.new("dot", 12.0)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(dot)
	var t := UI.label(str(slot.get("title", "")), "Strong")
	head.add_child(t)
	card.body.add_child(head)
	var body: String = str(slot.get("body", ""))
	if body != "":
		card.body.add_child(UI.label(body, "Small"))
	var action: String = str(slot.get("action", ""))
	var prominent: bool = bool(slot.get("prominent", false))
	if action != "":
		var btns := UI.flow(Ds.S2, Ds.S2)
		var ab := UI.button(action, "soft", Pal.PRIMARY, 48.0)
		ab.pressed.connect(func() -> void: on_action.call())
		btns.add_child(ab)
		card.set_meta("action_button", ab)
		if bool(slot.get("dismissible", false)) and not prominent:
			var lb := UI.button("나중에", "flat", Pal.INK, 48.0)
			lb.pressed.connect(func() -> void: on_later.call())
			btns.add_child(lb)
			card.set_meta("later_button", lb)
		card.body.add_child(btns)
	return card


# ---------------------------------------------------------------- 바로가기 (폰)

## 대화 · 연습 · 읽기 3칸. 각 칸 높이 >= 64. on_tap 은 화면 키 하나를 받는다. meta "buttons".
static func shortcut_tiles(on_tap: Callable) -> Control:
	var row := UI.hbox(Ds.S3)
	var btns: Array = []
	for it in SHORTCUTS:
		var view: String = it[1]
		var b := UI.button(str(it[0]), "soft", Pal.PRIMARY, 64.0)
		b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, 64.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", Ds.fs(Ds.type_size("H3")))
		b.pressed.connect(func() -> void: on_tap.call(view))
		row.add_child(b)
		btns.append(b)
	row.set_meta("buttons", btns)
	return row
