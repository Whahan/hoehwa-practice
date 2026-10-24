class_name ReviewView
extends AppView
## 복습: see the Korean meaning, say (or type) the sentence, compare with the stored target.

const NAME_KO := {"en": "영어", "ja": "일본어"}
const SESSION_MAX := 20
const CTA_H := 56.0 ## height of the one big call-to-action button of a screen
const RATING_NAME := {1: "다시", 2: "어려움", 3: "좋음", 4: "쉬움"}

var lang: String = "en"
var status: String = "idle" # idle | run | done
var items: Array = []
var idx: int = 0
var done_count: int = 0
var practice: bool = false # "미리 연습하기": review not-yet-due items without touching their schedule
var session_new: int = 0

var checked: bool = false
var shown_only: bool = false # "정답 보기" without answering
var score_result: Dictionary = {} # backend /score response
var typed_sim: Dictionary = {} # local similarity for typed answers
var scoring: bool = false
var typed_text: String = ""
## 채점할 곳이 없을 때(Route: /score = none) 자가 평가를 기다리는 녹음, 그리고 "잘했어요"로 평가했는지.
var self_rec: Dictionary = {}
var self_good: bool = false

var _page: PageScroll
var _footer_holder: PanelContainer ## fixed bar under the page: the four FSRS rating buttons (or "next" in practice)
var _footer_col: ColumnBox
var _header: Control = null ## big title block of the review home (see header_block)
var _score_call = null
var _record_widget: RecorderWidget = null
var _serial: int = 0
var _leave_msec: int = -100000 ## first Android back press during a session (see go_back)
var _stale: bool = false ## on_hide() cancelled the scoring request: redraw when the tab comes back


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_page = PageScroll.new(720.0)
	root.add_child(_page)
	_footer_holder = PanelContainer.new()
	var fst := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	fst.border_width_top = 1
	_footer_holder.add_theme_stylebox_override("panel", fst)
	_footer_holder.visible = false
	root.add_child(_footer_holder)
	_footer_col = ColumnBox.new()
	_footer_col.max_width = 720.0
	_footer_col.min_pad = Ds.S3
	_footer_col.set_padding(Ds.S3, Ds.S3)
	_footer_holder.add_child(_footer_col)
	lang = Store.lang()
	Store.changed.connect(func() -> void:
		if status == "idle" and is_visible_in_tree():
			_render())
	_render()


func refresh() -> void:
	if status == "idle":
		lang = Store.lang()
		_render()
	elif status == "done":
		_render()
	elif status == "run" and _stale:
		_stale = false
		_render()


func on_hide() -> void:
	if _record_widget != null and is_instance_valid(_record_widget):
		_record_widget.stop_if_recording()
	Tts.stop()
	if _score_call != null:
		_score_call.cancel()
		_score_call = null
		scoring = false
		_stale = true


## Android back button. During a session the first press only asks; the second one within 2 s goes back to the
## review home (the schedule of cards already rated is kept). Returns false on the review home.
func go_back() -> bool:
	match status:
		"done":
			status = "idle"
			_render()
			return true
		"run":
			var now: int = Time.get_ticks_msec()
			if now - _leave_msec > 2000:
				_leave_msec = now
				Toast.info("복습을 그만두면 남은 카드는 그대로 두고 처음 화면으로 가요. 나가려면 한 번 더 눌러 주세요.")
				return true
			quit_session()
			return true
	return false


func quit_session() -> void:
	_leave_msec = -100000
	_stale = false
	_reset_item()
	Tts.stop()
	status = "idle"
	_render()


func _start() -> void:
	_begin(Store.due_for(lang, SESSION_MAX), false)


func _start_practice() -> void:
	_begin(Store.upcoming_for(lang, SESSION_MAX), true)


func _begin(pool: Array, is_practice: bool) -> void:
	items = pool
	if items.is_empty():
		return
	practice = is_practice
	session_new = 0
	for it in items:
		if FSRS.is_new(it):
			session_new += 1
	idx = 0
	done_count = 0
	status = "run"
	_reset_item()
	_render()


## Score (0-100) -> suggested FSRS rating.
static func rating_for_score(score: float) -> int:
	if score >= 95.0:
		return FSRS.Rating.EASY
	if score >= 80.0:
		return FSRS.Rating.GOOD
	if score >= 60.0:
		return FSRS.Rating.HARD
	return FSRS.Rating.AGAIN


## "내일 오후 3시" style description of a due time (local time zone).
static func due_text(due: int, now: int) -> String:
	if due <= now:
		return "지금"
	if due - now < 3600:
		return "%d분 뒤" % ceili((due - now) / 60.0)
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var local: Dictionary = Time.get_datetime_dict_from_unix_time(due + bias)
	var day_diff: int = floori((due + bias) / float(FSRS.DAY)) - floori((now + bias) / float(FSRS.DAY))
	var day: String
	match day_diff:
		0: day = "오늘"
		1: day = "내일"
		2: day = "모레"
		_: day = "%d월 %d일" % [int(local["month"]), int(local["day"])]
	var h: int = int(local["hour"])
	var out := "%s %s %d시" % [day, "오전" if h < 12 else "오후", 12 if h % 12 == 0 else h % 12]
	if int(local["minute"]) != 0:
		out += " %d분" % int(local["minute"])
	return out


func _reset_item() -> void:
	checked = false
	shown_only = false
	score_result = {}
	typed_sim = {}
	scoring = false
	typed_text = ""
	self_rec = {}
	self_good = false
	_serial += 1
	if _score_call != null:
		_score_call.cancel()
		_score_call = null


func _advance() -> void:
	idx += 1
	_reset_item()
	if idx >= items.size():
		status = "done"
	_render()


# ---------------------------------------------------------------- app bar contract (AppView)
# The review has no title of its own for the bar (main uses the tab name); only the home page has a big title block.

func scroll_host() -> ScrollContainer:
	return _page


func header_block() -> Control:
	return _header if status == "idle" and _header != null and is_instance_valid(_header) else null


func _render() -> void:
	if _page == null:
		return
	_record_widget = null
	_header = null
	UI.clear(_footer_col.content)
	_footer_holder.visible = false
	var c: VBoxContainer = _page.content
	UI.clear(c)
	match status:
		"run":
			_render_run(c)
		"done":
			_render_done(c)
		_:
			_render_home(c)
	UI.fix_cjk(c)
	UI.fix_cjk(_footer_col.content)
	bar_changed.emit()


func _render_home(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	_header = PageHeader.build("복습")
	c.add_child(_header)
	var top := UI.hbox(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		_render()))
	c.add_child(top)
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("틀린 문장 다시 말하기", "H2"))
	var rv: int = Store.review_for(lang).size()
	var due_n: int = Store.due_count(lang)
	if rv > 0 and due_n > 0:
		var new_n: int = 0
		for it in Store.due_for(lang, SESSION_MAX):
			if FSRS.is_new(it):
				new_n += 1
		card.body.add_child(UI.label("오늘 복습 %d개 · 새 문장 %d개" % [mini(due_n, SESSION_MAX), new_n], "Strong"))
		card.body.add_child(UI.label("레슨과 대화에서 틀리거나 고친 %s 문장이에요. 한국어 뜻을 보고 직접 말해 보세요. 얼마나 잘 기억했는지에 따라 다음 복습 시기가 정해져요." % NAME_KO[lang], "Muted"))
		var go := UI.button("복습 시작" if due_n <= SESSION_MAX else "복습 시작 (%d개씩)" % SESSION_MAX, "primary", acc, CTA_H)
		go.pressed.connect(_start)
		card.body.add_child(go)
	elif rv > 0:
		card.body.add_child(UI.label("오늘 복습할 문장을 다 끝냈어요", "Strong"))
		var nd: int = Store.next_due(lang)
		if nd > 0:
			card.body.add_child(UI.label("다음 복습: %s" % due_text(nd, Store.now()), "Muted"))
		var pr := UI.button("미리 연습하기", "soft", acc, 48)
		pr.pressed.connect(_start_practice)
		card.body.add_child(pr)
		card.body.add_child(UI.label("미리 연습해도 복습 일정은 바뀌지 않아요.", "Small"))
	else:
		card.body.add_child(UI.label("아직 복습할 %s 문장이 없어요. 레슨에서 틀린 문장과 대화에서 교정받은 문장이 여기에 쌓여요." % NAME_KO[lang], "Muted"))
		var to_lesson := UI.button("레슨 하러 가기", "soft", acc, 48)
		to_lesson.pressed.connect(func() -> void: Store.navigate.emit("lesson", lang))
		card.body.add_child(to_lesson)
	c.add_child(card)
	if rv > 0:
		c.add_child(UI.section_header("모인 문장 (최근순) · 전체 %d개" % rv, Ds.S3))
		var list := ListGroup.new()
		var all: Array = Store.review_for(lang)
		var shown := 0
		for i in range(all.size() - 1, -1, -1):
			var it: Dictionary = all[i]
			var row := UI.hbox(8)
			var col := UI.vbox(0)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			col.add_child(UI.label(str(it["target"]), "Strong"))
			if str(it["ko"]) != "":
				col.add_child(UI.label(str(it["ko"]), "Small"))
			row.add_child(col)
			row.add_child(UI.speak_buttons(str(it["target"]), lang))
			list.add_custom(row)
			shown += 1
			if shown >= 8:
				break
		if all.size() > shown:
			list.add_custom(UI.label("… 외 %d개" % (all.size() - shown), "Small"))
		c.add_child(list)


func _render_done(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("복습 완료", "Eyebrow", false))
	if practice:
		card.body.add_child(UI.label("%d개를 연습했어요" % items.size(), "H2"))
		card.body.add_child(UI.label("미리 연습한 문장은 복습 일정이 그대로예요.", "Muted"))
	else:
		card.body.add_child(UI.label("%d개를 복습했어요" % done_count, "H2"))
		var nd: int = Store.next_due(lang)
		if Store.due_count(lang) > 0:
			card.body.add_child(UI.label("복습할 문장이 아직 %d개 남았어요." % Store.due_count(lang), "Muted"))
		elif nd > 0:
			card.body.add_child(UI.label("다음 복습: %s" % due_text(nd, Store.now()), "Muted"))
	var row := UI.adaptive(8) # phone: one under the other (two side by side do not fit at the big font sizes)
	var again := UI.button("미리 연습하기" if practice else "남은 문장 복습", "primary", acc, 48)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.disabled = Store.upcoming_for(lang, 1).is_empty() if practice else Store.due_count(lang) == 0
	again.pressed.connect(_start_practice if practice else _start)
	var home := UI.button("처음으로", "soft", acc, 48)
	home.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	home.pressed.connect(func() -> void:
		status = "idle"
		_render())
	row.add_child(again)
	row.add_child(home)
	card.body.add_child(row)
	c.add_child(card)


func _render_run(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	var it: Dictionary = items[idx]
	var n: int = items.size()
	var bar_row := UI.hbox(12)
	var quit := UI.link_button("그만")
	quit.pressed.connect(quit_session)
	bar_row.add_child(quit)
	bar_row.add_child(UI.progress_bar(float(idx) / float(n), acc, 10.0))
	bar_row.add_child(UI.label("%d/%d" % [idx + 1, n], "Muted", false))
	c.add_child(bar_row)
	var head_txt: String = "미리 연습 · 복습 일정은 바뀌지 않아요" if practice else "오늘 복습 %d개 · 새 문장 %d개" % [n, session_new]
	c.add_child(UI.label(head_txt, "Small"))

	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.colored("한국어 뜻을 보고 %s로 말하기" % NAME_KO[lang], Pal.on(lang), "Strong"))
	card.body.add_child(UI.label(str(it["ko"]) if str(it["ko"]) != "" else "(뜻 없음)", "H2"))

	if not checked:
		_record_widget = RecorderWidget.new(true, acc, true)
		_record_widget.recorded.connect(_on_recorded)
		_record_widget.set_enabled(not scoring)
		card.body.add_child(_record_widget)
		if scoring:
			card.body.add_child(UI.label("발음을 채점하는 중이에요…", "Muted"))
		if not self_rec.is_empty():
			var sp := SelfRatePanel.new(lang, str(it["target"]), self_rec, acc)
			sp.rated.connect(_on_self_rated)
			card.body.add_child(sp)
		card.body.add_child(UI.label("또는 직접 입력", "Small", false))
		var row := UI.hbox(8)
		var le := LineEdit.new()
		UI.touch(le)
		le.custom_minimum_size.y = maxf(le.custom_minimum_size.y, Ds.field_h())
		le.placeholder_text = "%s로 입력" % NAME_KO[lang]
		le.text = typed_text
		if lang == "ja":
			le.add_theme_font_override("font", UI.ja_font())
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t: String) -> void: typed_text = t)
		le.text_submitted.connect(func(_t: String) -> void: _check_typed())
		row.add_child(le)
		var ok := UI.button("확인", "soft", acc)
		ok.pressed.connect(_check_typed)
		row.add_child(ok)
		card.body.add_child(row)
		var show := UI.button("정답 보기", "flat", acc)
		show.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		show.pressed.connect(func() -> void:
			shown_only = true
			checked = true
			Tts.speak(str(it["target"]), lang)
			_render())
		card.body.add_child(show)
		c.add_child(card)
		return

	# result
	if not score_result.is_empty():
		card.body.add_child(ScorePanel.build(score_result, lang))
	elif self_good:
		card.body.add_child(UI.colored("✓ 스스로 '잘했어요'로 평가했어요. 기록에 남겼어요.", Pal.OK_ON, "Strong"))
	elif not typed_sim.is_empty():
		card.body.add_child(_typed_result())
	c.add_child(card)

	var ans := UI.card("Card", 8)
	ans.body.add_child(UI.label("정답", "Eyebrow", false))
	ans.body.add_child(UI.label(str(it["target"]), "H2"))
	if lang == "ja" and str(it["reading"]) != "":
		ReadingLine.add(ans.body, str(it["reading"]), lang) # no pron is stored with a review card: the heuristic spelling
	ans.body.add_child(UI.speak_buttons(str(it["target"]), lang))
	if str(it["note"]) != "":
		ans.body.add_child(UI.label(str(it["note"]), "Muted"))
	c.add_child(ans)
	_add_rating(c, it)


## Rating step. The page gets the hint and the "remove" link; the four FSRS buttons (with the resulting interval, the one
## matching the score filled) sit in the fixed bar under the page. Practice mode has a "next" button there instead.
func _add_rating(c: VBoxContainer, it: Dictionary) -> void:
	var acc: Color = Pal.accent(lang)
	var score: float = -1.0
	if not score_result.is_empty():
		score = float(score_result.get("score", 0))
	elif not typed_sim.is_empty():
		score = float(typed_sim["score"])
	var note := UI.vbox(Ds.S2)
	var fcol: VBoxContainer = _footer_col.content
	if practice:
		note.add_child(UI.label("미리 연습 중이라 복습 일정은 바뀌지 않아요.", "Small"))
		var nxt := UI.button("다음 문장" if idx + 1 < items.size() else "연습 끝내기", "primary", acc, CTA_H)
		nxt.pressed.connect(_advance)
		fcol.add_child(nxt)
	else:
		var pre: int = rating_for_score(score) if score >= 0.0 else FSRS.Rating.AGAIN
		var hint: String = "점수 %d점에 맞춰 '%s'를 골라 뒀어요." % [roundi(score), RATING_NAME[pre]] if score >= 0.0 else "정답을 확인했으니 '%s'를 골라 뒀어요." % RATING_NAME[pre]
		if self_good:
			pre = FSRS.Rating.GOOD
			hint = "스스로 '잘했어요'라고 평가해서 '%s'를 골라 뒀어요." % RATING_NAME[pre]
		note.add_child(UI.label("얼마나 잘 기억했나요? " + hint + " 다르게 느꼈다면 직접 눌러 주세요.", "Small"))
		var now: int = Store.now()
		var pv: Dictionary = FSRS.preview(it, now)
		# the button look maps each accent to its *_ON text colour; the suggested rating is the filled one
		var colors := {1: Pal.BAD, 2: Pal.WARN, 3: Pal.OK, 4: acc}
		var row: Container = UI.hbox(8)
		if Platform.is_phone(): # four buttons do not fit side by side: two by two
			var g := GridContainer.new()
			g.columns = 2
			g.add_theme_constant_override("h_separation", 8)
			g.add_theme_constant_override("v_separation", 8)
			g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row = g
		for r in [1, 2, 3, 4]:
			var wait: int = int((pv[r] as Dictionary)["due"]) - now
			var b := UI.button("%s\n%s" % [RATING_NAME[r], FSRS.format_interval(wait)], "primary" if r == pre else "outline", colors[r], 64)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(func() -> void:
				Store.rate_review(str(it["id"]), r)
				done_count += 1
				Store.save_progress()
				_advance())
			row.add_child(b)
		fcol.add_child(row)
	note.add_child(_remove_button(it))
	c.add_child(note)
	_footer_holder.visible = true


func _remove_button(it: Dictionary) -> Control:
	var rm := UI.link_button("목록에서 빼기", "이 문장을 복습 목록에서 완전히 지워요")
	rm.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	rm.pressed.connect(func() -> void:
		Store.remove_review(str(it["id"]))
		Store.save_progress()
		_advance())
	return rm


func _typed_result() -> Control:
	var box := UI.vbox(8)
	var score: int = int(typed_sim["score"])
	var row := UI.hbox(12)
	var big := Label.new()
	big.theme_type_variation = &"Score"
	big.text = str(score)
	big.add_theme_color_override("font_color", ScorePanel.score_color(score)) # 40 px: a fill-like colour is enough
	row.add_child(big)
	row.add_child(UI.colored(ScorePanel.verdict(score), ScorePanel.score_text_color(score), "Strong"))
	box.add_child(row)
	# one chip per word: said right = soft green, no outline; missed = soft red, bold, 2 px outline (shape, not only colour)
	var fl := UI.flow(4, 6)
	var toks: PackedStringArray = typed_sim["toks"]
	var hit: Array = typed_sim["hit"]
	for i in toks.size():
		var look: Dictionary = ScorePanel.unit_look(bool(hit[i]), false)
		var ch := UI.chip(toks[i], look["fg"], look["bg"])
		ch.add_theme_stylebox_override("panel", UI.style(look["bg"], look["border"], int(look["bw"]), Ds.R_PILL, 12, 4))
		fl.add_child(ch)
	box.add_child(fl)
	return box


func _check_typed() -> void:
	var it: Dictionary = items[idx]
	if typed_text.strip_edges() == "":
		return
	typed_sim = TextSim.similarity(typed_text, str(it["target"]), str(it["reading"]), lang)
	checked = true
	Tts.speak(str(it["target"]), lang)
	_render()


## 자가 평가 결과: "잘했어요"는 채점 통과와 같은 길(결과 화면 -> 복습 평점, StudyLog.add_score)로, "다시"는 아무것도 기록하지 않는다.
func _on_self_rated(good: bool) -> void:
	if status != "run" or self_rec.is_empty():
		return
	self_rec = {}
	if good:
		var it: Dictionary = items[idx]
		StudyLog.add_score(lang, SelfRatePanel.good_result(lang, str(it["target"])), "review")
		self_good = true
		checked = true
	_render()


func _on_recorded(result: Dictionary) -> void:
	if scoring:
		return
	if SelfRatePanel.needed():
		# no place to score (no PC, no phone model): no /score request, rate by ear instead
		self_rec = result
		_render()
		return
	var it: Dictionary = items[idx]
	scoring = true
	_render()
	var serial: int = _serial
	var body := {"lang": lang, "target": str(it["target"]), "reading": str(it["reading"]), "audio_b64": result["b64"]}
	_score_call = Api.post_json("/score", body, Api.TIMEOUT_SHORT, true)
	var req = _score_call
	var res: Dictionary = await req.wait()
	if serial != _serial or req != _score_call:
		return
	_score_call = null
	scoring = false
	if res["ok"] and res["data"] is Dictionary:
		score_result = res["data"]
		StudyLog.add_score(lang, score_result, "review")
		checked = true
	_render()
