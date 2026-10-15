class_name ReviewView
extends AppView
## 복습: see the Korean meaning, say (or type) the sentence, compare with the stored target.

const NAME_KO := {"en": "영어", "ja": "일본어"}
const SESSION_MAX := 20
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

var _page: PageScroll
var _score_call = null
var _record_widget: RecorderWidget = null
var _serial: int = 0


func _ready() -> void:
	_page = PageScroll.new(720.0)
	_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_page)
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


func on_hide() -> void:
	if _record_widget != null and is_instance_valid(_record_widget):
		_record_widget.stop_if_recording()


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


func _render() -> void:
	if _page == null:
		return
	_record_widget = null
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


func _render_home(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	var top := UI.hbox(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		_render()))
	c.add_child(top)
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("복습", "Eyebrow", false))
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
		var go := UI.button("복습 시작" if due_n <= SESSION_MAX else "복습 시작 (%d개씩)" % SESSION_MAX, "primary", acc, 52)
		go.pressed.connect(_start)
		card.body.add_child(go)
	elif rv > 0:
		card.body.add_child(UI.label("오늘 복습할 문장을 다 끝냈어요", "Strong"))
		var nd: int = Store.next_due(lang)
		if nd > 0:
			card.body.add_child(UI.label("다음 복습: %s" % due_text(nd, Store.now()), "Muted"))
		var pr := UI.button("미리 연습하기", "soft", acc, 46)
		pr.pressed.connect(_start_practice)
		card.body.add_child(pr)
		card.body.add_child(UI.label("미리 연습해도 복습 일정은 바뀌지 않아요.", "Small"))
	else:
		card.body.add_child(UI.label("아직 복습할 %s 문장이 없어요. 레슨에서 틀린 문장과 대화에서 교정받은 문장이 여기에 쌓여요." % NAME_KO[lang], "Muted"))
		var to_lesson := UI.button("레슨 하러 가기", "soft", acc, 46)
		to_lesson.pressed.connect(func() -> void: Store.navigate.emit("lesson", lang))
		card.body.add_child(to_lesson)
	c.add_child(card)
	if rv > 0:
		var list := UI.card("Card", 8)
		list.body.add_child(UI.label("모인 문장 (최근순) · 전체 %d개" % rv, "Eyebrow", false))
		var all: Array = Store.review_for(lang)
		var shown := 0
		for i in range(all.size() - 1, -1, -1):
			var it: Dictionary = all[i]
			var row := UI.hbox(8)
			var col := UI.vbox(0)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.add_child(UI.label(str(it["target"]), "Strong"))
			if str(it["ko"]) != "":
				col.add_child(UI.label(str(it["ko"]), "Small"))
			row.add_child(col)
			row.add_child(UI.speak_buttons(str(it["target"]), lang))
			list.body.add_child(row)
			shown += 1
			if shown >= 8:
				break
		if all.size() > shown:
			list.body.add_child(UI.label("… 외 %d개" % (all.size() - shown), "Small"))
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
	var row := UI.hbox(8)
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
	quit.pressed.connect(func() -> void:
		_reset_item()
		Tts.stop()
		status = "idle"
		_render())
	bar_row.add_child(quit)
	bar_row.add_child(UI.progress_bar(float(idx) / float(n), acc, 12.0))
	bar_row.add_child(UI.label("%d/%d" % [idx + 1, n], "Muted", false))
	c.add_child(bar_row)
	var head_txt: String = "미리 연습 · 복습 일정은 바뀌지 않아요" if practice else "오늘 복습 %d개 · 새 문장 %d개" % [n, session_new]
	c.add_child(UI.label(head_txt, "Small", false))

	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.colored("한국어 뜻을 보고 %s로 말하기" % NAME_KO[lang], acc, "Strong", false))
	var meaning := UI.label(str(it["ko"]) if str(it["ko"]) != "" else "(뜻 없음)", "")
	meaning.add_theme_font_size_override("font_size", 22)
	meaning.add_theme_font_override("font", UI.bold_font())
	card.body.add_child(meaning)

	if not checked:
		_record_widget = RecorderWidget.new(true, acc, true)
		_record_widget.recorded.connect(_on_recorded)
		_record_widget.set_enabled(not scoring)
		card.body.add_child(_record_widget)
		if scoring:
			card.body.add_child(UI.label("발음을 채점하는 중이에요…", "Muted"))
		card.body.add_child(UI.label("또는 직접 입력", "Small", false))
		var row := UI.hbox(8)
		var le := LineEdit.new()
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
		var show := UI.button("정답 보기", "default")
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
	elif not typed_sim.is_empty():
		card.body.add_child(_typed_result())
	c.add_child(card)

	var ans := UI.card("Card", 8)
	ans.body.add_child(UI.label("정답", "Eyebrow", false))
	var target := UI.label(str(it["target"]), "")
	target.add_theme_font_size_override("font_size", 21)
	target.add_theme_font_override("font", UI.bold_font())
	ans.body.add_child(target)
	if lang == "ja" and str(it["reading"]) != "":
		ans.body.add_child(UI.label(str(it["reading"]), "Small"))
	ans.body.add_child(UI.speak_buttons(str(it["target"]), lang))
	if str(it["note"]) != "":
		ans.body.add_child(UI.label(str(it["note"]), "Muted"))
	c.add_child(ans)
	c.add_child(_rating_card(it))


## Rating step: four FSRS buttons with the resulting interval, the one matching the score is highlighted.
func _rating_card(it: Dictionary) -> Control:
	var acc: Color = Pal.accent(lang)
	var box := UI.card("Card", 8)
	var score: float = -1.0
	if not score_result.is_empty():
		score = float(score_result.get("score", 0))
	elif not typed_sim.is_empty():
		score = float(typed_sim["score"])
	if practice:
		box.body.add_child(UI.label("미리 연습 중이라 복습 일정은 바뀌지 않아요.", "Small"))
		var nxt := UI.button("다음 문장" if idx + 1 < items.size() else "연습 끝내기", "primary", acc, 50)
		nxt.pressed.connect(_advance)
		box.body.add_child(nxt)
		box.body.add_child(_remove_button(it))
		return box
	var pre: int = rating_for_score(score) if score >= 0.0 else FSRS.Rating.AGAIN
	var hint: String = "점수 %d점에 맞춰 '%s'를 골라 뒀어요." % [roundi(score), RATING_NAME[pre]] if score >= 0.0 else "정답을 확인했으니 '%s'를 골라 뒀어요." % RATING_NAME[pre]
	box.body.add_child(UI.label("얼마나 잘 기억했나요? " + hint + " 다르게 느꼈다면 직접 눌러 주세요.", "Small"))
	var now: int = Store.now()
	var pv: Dictionary = FSRS.preview(it, now)
	var colors := {1: Pal.BAD, 2: Pal.WARN, 3: Pal.OK, 4: acc}
	var row := UI.hbox(8)
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
	box.body.add_child(row)
	box.body.add_child(_remove_button(it))
	return box


func _remove_button(it: Dictionary) -> Control:
	var rm := UI.link_button("목록에서 빼기", "이 문장을 복습 목록에서 완전히 지워요")
	rm.pressed.connect(func() -> void:
		Store.remove_review(str(it["id"]))
		Store.save_progress()
		_advance())
	return rm


func _typed_result() -> Control:
	var box := UI.vbox(8)
	var score: int = int(typed_sim["score"])
	var col: Color = ScorePanel.score_color(score)
	var row := UI.hbox(12)
	var big := Label.new()
	big.theme_type_variation = &"Score"
	big.text = str(score)
	big.add_theme_color_override("font_color", col)
	row.add_child(big)
	row.add_child(UI.colored(ScorePanel.verdict(score), col, "Strong"))
	box.add_child(row)
	var fl := UI.flow(0 if lang == "ja" else 6, 4)
	var toks: PackedStringArray = typed_sim["toks"]
	var hit: Array = typed_sim["hit"]
	for i in toks.size():
		var ok: bool = bool(hit[i])
		var l := Label.new()
		l.text = toks[i]
		l.add_theme_font_size_override("font_size", 18)
		l.add_theme_color_override("font_color", Pal.OK if ok else Pal.BAD)
		fl.add_child(l)
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


func _on_recorded(result: Dictionary) -> void:
	if scoring:
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
		checked = true
	_render()
