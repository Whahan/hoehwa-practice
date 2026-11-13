class_name KanaCourseView
extends RefCounted
## 가나 기초 코스 화면 조각(docs/v160_fun_design.md §4.2): 코스 목록 · 단계 소개 · 헷갈리는 짝 고르기 · 단계 결과.
## 상태와 동작은 KanaScreen 이 가진다(이 파일은 그리기만 한다). 데이터는 KanaCourse(단계·짝) + StudyLog(코스 기록·글자 숙련).
## 색은 Pal 토큰만, 도형은 GlyphIcon 으로 그린다(도형 글자·이모지 없음). 눌리는 것은 전부 Button.

const ROW_MIN_H := 64.0
const MARK_PX := 24.0
const INTRO_COLS := 5
const INTRO_COLS_YOON := 3
const SCRIPT_LABEL := {"hira": "히라가나", "kata": "가타카나"}


static func script_label(script: String) -> String:
	return str(SCRIPT_LABEL.get(script, ""))


## 단계 이름 앞에 붙는 번호: h3 -> "3", 짝 단계 -> "".
static func stage_number(id: String) -> String:
	if id.begins_with("p_"):
		return ""
	return id.substr(1)


## 화면 맨 위 제목(머리줄): "히라가나 · あ행" / "히라가나 · 헷갈리는 짝".
static func stage_heading(st: Dictionary) -> String:
	if st.is_empty():
		return "가나 기초 코스"
	return "%s · %s" % [script_label(str(st["script"])), str(st["title"])]


## 그 단계 글자 중 숙련 3(익힘)인 개수.
static func mastered_count(st: Dictionary, stats: Dictionary) -> int:
	var n := 0
	for ch in st.get("chars", []):
		var pr: Variant = stats.get(str(ch), null)
		if pr is Array and (pr as Array).size() >= 2 and KanaData.mastery(int((pr as Array)[0]), int((pr as Array)[1])) >= 3:
			n += 1
	return n


# ---------------------------------------------------------------- course list

## 코스 목록: 히라가나 · 가타카나 구역마다 진행 바 + 단계 행. 행 표시는 host.stage_marks[id] = "done" | "next" | "none".
static func build_course(c: VBoxContainer, host: KanaScreen) -> void:
	var done: Dictionary = StudyLog.kana_course_done()
	var best: Dictionary = StudyLog.kana_course_best()
	var stats: Dictionary = StudyLog.kana_stats()
	var rec: String = KanaCourse.next_stage("both", done)
	host.stage_rows = {}
	host.stage_marks = {}
	host.recommended_stage = rec
	c.add_child(host.build_view_switch())
	c.add_child(UI.label("글자를 행 단위로 익히고 단계 시험(15문제 중 12개)으로 확인해요. 이미 아는 단계는 건너뛰어도 돼요.", "Muted"))
	for script in ["hira", "kata"]:
		var sts: Array = KanaCourse.stages(script)
		var n_done := 0
		var known := 0
		var total_chars := 0
		for st in sts:
			if done.has(str((st as Dictionary)["id"])):
				n_done += 1
		for e in KanaData.entries(script):
			total_chars += 1
			var pr: Variant = stats.get(str((e as Dictionary)["ch"]), null)
			if pr is Array and (pr as Array).size() >= 2 and KanaData.mastery(int((pr as Array)[0]), int((pr as Array)[1])) >= 3:
				known += 1
		c.add_child(UI.section_header(script_label(script), Ds.S2))
		c.add_child(UI.label("%d / %d 단계 완료  ·  글자 숙련 %d / %d" % [n_done, sts.size(), known, total_chars], "Strong"))
		c.add_child(UI.progress_bar(float(n_done) / maxf(1.0, float(sts.size())), Pal.PRIMARY))
		var col := UI.vbox(8)
		c.add_child(col)
		for st in sts:
			var d: Dictionary = st
			var id: String = str(d["id"])
			var mark: String = "done" if done.has(id) else ("next" if id == rec else "none")
			var row: Button = _stage_row(host, d, mark, int(best.get(id, -1)), mastered_count(d, stats))
			col.add_child(row)
			host.stage_rows[id] = row
			host.stage_marks[id] = mark
	c.add_child(UI.label("단계 시험 통과 기록과 최고 점수는 이 기기에만 저장돼요.", "Small"))


## 단계 행 하나: 표시(완료 = 체크, 추천 = 재생 도형) + 이름 + 글자 미리보기 + 숙련 + 최고 점수. 행 전체가 눌린다.
static func _stage_row(host: KanaScreen, st: Dictionary, mark: String, best_pct: int, known: int) -> Button:
	var id: String = str(st["id"])
	var is_pairs: bool = str(st["kind"]) == "pairs"
	var chars: Array = st["chars"]
	var b := Button.new()
	b.name = "Stage_" + id
	b.text = ""
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var n_text: String = stage_number(id)
	var title: String = str(st["title"]) if n_text == "" else "%s  %s" % [n_text, str(st["title"])]
	var preview: String = " ".join(PackedStringArray(chars.slice(0, 8).map(func(x: Variant) -> String: return str(x))))
	if chars.size() > 8:
		preview += " …"
	var state_text: String = ""
	match mark:
		"done":
			state_text = "완료" if best_pct < 0 else "완료 · 최고 %d%%" % best_pct
		"next":
			state_text = "추천" if best_pct < 0 else "추천 · 최고 %d%%" % best_pct
		_:
			state_text = "" if best_pct < 0 else "최고 %d%%" % best_pct
	var mastery_text: String = "%d/%d" % [known, chars.size()]
	b.tooltip_text = "%s  %s  숙련 %s%s" % [title, preview, mastery_text, ("  " + state_text) if state_text != "" else ""]
	var line_h: float = float(UI.fs(16)) * 1.45 + float(UI.fs(13)) * 1.45 + 22.0
	b.custom_minimum_size = Vector2(0, maxf(ROW_MIN_H, line_h))
	var sel: bool = mark == "next"
	var n: StyleBoxFlat
	if sel:
		n = UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 2, 2)
	else:
		n = UI.style(Pal.SURFACE, Pal.LINE_STRONG, 1, Ds.R_S, 2, 2)
	var hv := UI.style(Pal.SUNK, Pal.LINE_STRONG, 1, Ds.R_S, 2, 2)
	var pr := UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 2, 2)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", n if sel else hv)
	b.add_theme_stylebox_override("pressed", pr)
	b.add_theme_stylebox_override("hover_pressed", pr)
	b.add_theme_stylebox_override("focus", n)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 12)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	b.add_child(pad)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(h)
	var slot := CenterContainer.new()
	slot.custom_minimum_size = Vector2(MARK_PX, 0)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(slot)
	match mark:
		"done":
			slot.add_child(GlyphIcon.new("check", MARK_PX, Pal.OK))
		"next":
			slot.add_child(GlyphIcon.new("play", MARK_PX * 0.85, Pal.PRIMARY))
	var mid := VBoxContainer.new()
	mid.add_theme_constant_override("separation", 0)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.clip_contents = true
	h.add_child(mid)
	mid.add_child(_row_label(title, UI.fs(16), Pal.INK, true))
	var sub: String = preview if not is_pairs else "%d쌍 · %s" % [KanaCourse.pairs(str(st["script"])).size(), preview]
	mid.add_child(_row_label(sub, UI.fs(13), Pal.MUTED, false))
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 0)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(right)
	var ml := _row_label(mastery_text, UI.fs(16), Pal.INK, true)
	ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(ml)
	var sl := _row_label(state_text, maxi(Ds.MIN_FONT, UI.fs(12)), Pal.OK_ON if mark == "done" else (Pal.PRIMARY if mark == "next" else Pal.MUTED), false)
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(sl)
	b.pressed.connect(func() -> void: host.open_stage(id))
	return b


static func _row_label(text: String, size: int, color: Color, bold: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", UI.bold_font())
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	return l


# ---------------------------------------------------------------- stage intro

## 단계 소개: 그 단계 글자 칸(누르면 소리) + [단계 시험 시작] + [표로].
static func build_stage_intro(c: VBoxContainer, host: KanaScreen, st: Dictionary) -> void:
	var id: String = str(st["id"])
	var stats: Dictionary = StudyLog.kana_stats()
	var best: Dictionary = StudyLog.kana_course_best()
	var done: Dictionary = StudyLog.kana_course_done()
	var chars: Array = st["chars"]
	var card := UI.card("BigCard", 8)
	card.body.add_child(UI.label(stage_heading(st), "H2"))
	card.body.add_child(UI.label("글자를 눌러 소리를 들어 보세요. 준비가 되면 단계 시험을 시작해요.", "Muted"))
	card.body.add_child(UI.label(_record_text(id, best, done, mastered_count(st, stats), chars.size()), "Small"))
	c.add_child(card)
	_build_cells(c, host, chars)
	host.render_intro_footer()
	_add_test_start(c, host, id)
	var back := SpeakDrill.touch_button("표로", "outline", Pal.JA, 48)
	back.name = "ToTable"
	back.pressed.connect(func() -> void: host.open_table())
	c.add_child(back)


static func _record_text(id: String, best: Dictionary, done: Dictionary, known: int, total: int) -> String:
	var parts: Array = ["글자 숙련 %d / %d" % [known, total]]
	if best.has(id):
		parts.append("최고 %d%%" % int(best[id]))
	if done.has(id):
		parts.append("완료한 날 %s" % str(done[id]))
	return "  ·  ".join(PackedStringArray(parts))


## 글자 칸 모음(표와 같은 Cell). 칸을 누르면 host.tap_intro_cell.
static func _build_cells(c: VBoxContainer, host: KanaScreen, chars: Array) -> void:
	var wide := false
	for ch in chars:
		if str(ch).length() > 1:
			wide = true
	var g := GridContainer.new()
	g.columns = INTRO_COLS_YOON if wide else INTRO_COLS
	g.add_theme_constant_override("h_separation", KanaScreen.GRID_GAP)
	g.add_theme_constant_override("v_separation", KanaScreen.GRID_GAP)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(g)
	host.grids.append(g)
	for ch in chars:
		var e: Dictionary = KanaData.get_entry(str(ch))
		if e.is_empty():
			continue
		var cell := KanaScreen.Cell.new()
		cell.setup(e, StudyLog.kana_stat(str(ch)), KanaScreen.CELL_MIN_W, KanaScreen.CELL_MIN_H)
		var chs: String = str(ch)
		cell.pressed.connect(func() -> void: host.tap_intro_cell(chs))
		g.add_child(cell)
		host.cells[chs] = cell


## [단계 시험 시작 (15문제)] 버튼(+ 소리 없는 기기 안내 한 줄).
static func _add_test_start(c: VBoxContainer, host: KanaScreen, id: String) -> void:
	if not KanaVoice.available():
		var note := UI.colored("%s 듣기 문제는 글자 보고 읽기 문제로 바꿔서 내요." % KanaVoice.no_text(), Pal.WARN_ON, "Small")
		note.name = "NoSoundNote"
		c.add_child(note)
	var go := SpeakDrill.touch_button("단계 시험 시작 (%d문제)" % KanaCourse.STAGE_QUESTIONS, "primary", Pal.JA, 56)
	go.name = "StartStage"
	go.pressed.connect(func() -> void: host.start_stage(id))
	c.add_child(go)
	host.start_button = go


# ---------------------------------------------------------------- pairs picker

## 헷갈리는 짝 단계: 짝 칩(여러 개 고르기) / 전체 섞기 + [짝 연습 시작] + 단계 시험.
static func build_pairs(c: VBoxContainer, host: KanaScreen, st: Dictionary) -> void:
	var id: String = str(st["id"])
	var script: String = str(st["script"])
	var best: Dictionary = StudyLog.kana_course_best()
	var done: Dictionary = StudyLog.kana_course_done()
	var stats: Dictionary = StudyLog.kana_stats()
	var chars: Array = st["chars"]
	var card := UI.card("BigCard", 8)
	card.body.add_child(UI.label(stage_heading(st), "H2"))
	card.body.add_child(UI.label("닮은 글자 두 개가 보기에 꼭 함께 나와요. 연습할 짝을 고르거나 전체를 섞어서 풀어요.", "Muted"))
	card.body.add_child(UI.label(_record_text(id, best, done, mastered_count(st, stats), chars.size()), "Small"))
	c.add_child(card)

	c.add_child(UI.section_header("연습할 짝", Ds.S2))
	var chips := UI.flow(8, 8)
	host.pair_chips = {}
	var all_chip := UI.filter_chip("전체 섞기", host.selected_pairs.is_empty(), func() -> void: host.clear_pairs())
	all_chip.name = "PairAll"
	chips.add_child(all_chip)
	host.pair_all_chip = all_chip
	for p in KanaCourse.pairs(script):
		var pd: Dictionary = p
		var pid: String = str(pd["id"])
		var chip := UI.filter_chip("%s / %s" % [str(pd["a"]), str(pd["b"])], host.selected_pairs.has(pid), func() -> void: host.toggle_pair(pid))
		chip.name = "Pair_" + pid
		chips.add_child(chip)
		host.pair_chips[pid] = chip
	c.add_child(chips)

	var shown: Array = host.selected_pairs
	if shown.size() > 0 and shown.size() <= 3:
		for pid in shown:
			var pr: Dictionary = KanaCourse.pair_by_id(str(pid))
			if pr.is_empty():
				continue
			var tip: String = str(pr.get("tip", ""))
			var line := UI.label("%s / %s" % [str(pr["a"]), str(pr["b"])] + (("  " + tip) if tip != "" else ""), "Small")
			c.add_child(line)
	var n_pairs: int = host.selected_pairs.size() if not host.selected_pairs.is_empty() else KanaCourse.pairs(script).size()
	c.add_child(UI.label("%s 짝 %d개로 %d문제를 풀어요." % ["고른" if not host.selected_pairs.is_empty() else "전체", n_pairs, KanaCourse.PAIR_SESSION_N], "Strong"))
	var go := SpeakDrill.touch_button("짝 연습 시작 (%d문제)" % KanaCourse.PAIR_SESSION_N, "primary", Pal.JA, 56)
	go.name = "StartPairs"
	go.pressed.connect(func() -> void: host.start_pairs(host.selected_pairs))
	c.add_child(go)
	host.start_button = go

	c.add_child(UI.section_header("단계 시험", Ds.S4))
	c.add_child(UI.label("이 단계의 모든 짝 글자에서 %d문제를 내요. %d개 이상 맞히면 단계 완료예요." % [KanaCourse.STAGE_QUESTIONS, KanaCourse.STAGE_PASS], "Muted"))
	if not KanaVoice.available():
		var note := UI.colored("%s 듣기 문제는 글자 보고 읽기 문제로 바꿔서 내요." % KanaVoice.no_text(), Pal.WARN_ON, "Small")
		note.name = "NoSoundNote"
		c.add_child(note)
	var st_btn := SpeakDrill.touch_button("단계 시험 시작 (%d문제)" % KanaCourse.STAGE_QUESTIONS, "outline", Pal.JA, 56)
	st_btn.name = "StartStage"
	st_btn.pressed.connect(func() -> void: host.start_stage(id))
	c.add_child(st_btn)
	host.stage_button = st_btn
	var to_course := SpeakDrill.touch_button("코스로", "outline", Pal.JA, 48)
	to_course.name = "ToCourse"
	to_course.pressed.connect(func() -> void: host.open_course())
	c.add_child(to_course)


# ---------------------------------------------------------------- result

## 단계 시험 / 짝 연습 결과. host.run_kind == "stage" 면 통과 여부와 [다음 단계], "pairs" 면 [같은 짝으로 다시].
static func build_stage_result(c: VBoxContainer, host: KanaScreen) -> void:
	var is_stage: bool = host.run_kind == "stage"
	var rate: int = host.rate_pct()
	var total: int = host.questions.size()
	var correct: int = host.correct_count()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("단계 시험 결과" if is_stage else "짝 연습 결과", "Eyebrow", false))
	card.body.add_child(UI.colored("정답률 %d%%" % rate, ScorePanel.score_color(float(rate)), "H1", false))
	card.body.add_child(UI.label("%d문제 중 %d개 맞혔어요." % [total, correct], "Strong"))
	if is_stage:
		var verdict := UI.hbox(8)
		var mk := GlyphIcon.new("check" if host.last_passed else "close", 22.0, Pal.OK if host.last_passed else Pal.WARN_ON)
		mk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		verdict.add_child(mk)
		var vt := UI.colored("통과했어요! 이 단계를 마쳤어요." if host.last_passed else "통과하지 못했어요. %d문제 중 %d개 이상 맞혀야 해요." % [KanaCourse.STAGE_QUESTIONS, KanaCourse.STAGE_PASS], Pal.OK_ON if host.last_passed else Pal.WARN_ON, "Strong")
		vt.name = "Verdict"
		verdict.add_child(vt)
		card.body.add_child(verdict)
	c.add_child(card)
	host.build_wrong_card(c)

	var acc: Color = Pal.JA
	var wrong: Array = host.wrong_entries()
	var next_id: String = host.next_stage_id() if is_stage and host.last_passed else ""
	if next_id != "":
		var nb := SpeakDrill.touch_button("다음 단계", "primary", acc, 56)
		nb.name = "NextStage"
		nb.pressed.connect(func() -> void: host.open_stage(next_id))
		c.add_child(nb)
	if not wrong.is_empty():
		var rb := SpeakDrill.touch_button("틀린 글자 복습 카드로 추가", "soft", acc, 48)
		rb.name = "AddReview"
		if host.review_pressed:
			rb.text = "복습 카드에 넣었어요 (새 카드 %d개)" % host.added_cards if host.added_cards > 0 else "이미 복습 카드에 있어요"
			rb.disabled = true
		else:
			rb.pressed.connect(func() -> void:
				host.add_wrong_to_review()
				host._render())
		c.add_child(rb)
	if is_stage:
		var again := SpeakDrill.touch_button("같은 단계 다시", "primary" if next_id == "" else "outline", acc, 48)
		again.name = "RetryStage"
		again.pressed.connect(func() -> void: host.start_stage(host.course_id))
		c.add_child(again)
	else:
		var again2 := SpeakDrill.touch_button("같은 짝으로 다시", "primary", acc, 48)
		again2.name = "RetryPairs"
		again2.pressed.connect(func() -> void: host.start_pairs(host.selected_pairs))
		c.add_child(again2)
		var pick := SpeakDrill.touch_button("짝 고르기", "outline", acc, 48)
		pick.name = "ToPairs"
		pick.pressed.connect(func() -> void: host.open_stage(host.course_id))
		c.add_child(pick)
	var out := SpeakDrill.touch_button("코스로", "outline", acc, 48)
	out.name = "ToCourse"
	out.pressed.connect(func() -> void: host.open_course())
	c.add_child(out)
