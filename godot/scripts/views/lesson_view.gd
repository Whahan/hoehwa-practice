class_name LessonView
extends AppView
## 레슨: generate a lesson with POST /lesson, then one exercise per screen.

const TYPE_LABEL := {
	"choice": "알맞은 답 고르기",
	"fill": "빈칸 채우기",
	"build": "문장 만들기",
	"listen": "듣고 뜻 고르기",
	"speak": "소리 내어 말하기",
}
const NAME_KO := {"en": "영어", "ja": "일본어"}
const PASS_SCORE := 70

var lang: String = "en"
var status: String = "idle" # idle | loading | run | done
var err: String = ""
var sel_n: int = 1
var sel_w: int = 1
var title: String = ""
var attribution: String = "" # source credit of the response (CC BY), "" when none
var exercises: Array = []
var idx: int = 0
var results: Array = [] # [{ok: bool, ex: Dictionary}]
var ok_count: int = 0
var added_count: int = 0

# per exercise state
var picked: int = -1
var built: Array = [] # tile ids in answer order
var checked: bool = false
var correct: bool = false
var speak_result: Dictionary = {}
var scoring: bool = false

var _call = null # Api.ApiCall
var _score_call = null
var _page: PageScroll
var _footer_holder: PanelContainer
var _footer_col: ColumnBox
var _loading_label: Label
var _loading_start: int = 0
var _record_widget: RecorderWidget = null
var _lesson_serial: int = 0
var _leave_msec: int = -100000 ## first Android back press while solving (see go_back)
var _stale: bool = false ## on_hide() cancelled a request of the current exercise: redraw when the tab comes back
var _autoplayed: int = -1
var _req_source: String = "tatoeba" # source of the lesson currently being requested

# intonation (POST /prosody) of the current speak exercise
var prosody: Dictionary = {}        # latest response (with the learner's part after a recording)
var prosody_native: Dictionary = {} # response without audio: native contour + accent only
var _prosody_call = null
var _prosody_key: int = -1
var _prosody_state: String = "loading" # loading | ok | error
var _prosody_panel: ProsodyPanel = null
var _prosody_tips: VBoxContainer = null


func _ready() -> void:
	_page = PageScroll.new(720.0)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.add_child(_page)
	_footer_holder = PanelContainer.new()
	_footer_holder.visible = false
	root.add_child(_footer_holder)
	_footer_col = ColumnBox.new()
	_footer_col.max_width = 720.0
	_footer_col.set_padding(14, 16)
	_footer_holder.add_child(_footer_col)
	lang = Store.lang()
	_set_default_selection()
	_render()


func refresh() -> void:
	if status == "idle" or status == "done":
		lang = Store.lang()
		if status == "idle":
			_set_default_selection()
		_render()
	elif status == "run" and _stale:
		_stale = false
		_render()


func _process(_delta: float) -> void:
	if status == "loading" and _req_source == "ai" and _loading_label != null and is_instance_valid(_loading_label):
		var sec: int = (Time.get_ticks_msec() - _loading_start) / 1000
		_loading_label.text = "문제 10개를 새로 만들고 있어요. 보통 10~60초 걸려요.  (%d초 경과)" % sec


func _set_default_selection() -> void:
	var p: Dictionary = Store.position()
	sel_n = int(p["n"])
	sel_w = int(p["w"])


# ---------------------------------------------------------------- generating

func start_lesson() -> void:
	err = ""
	status = "loading"
	_loading_start = Time.get_ticks_msec()
	_lesson_serial += 1
	var serial: int = _lesson_serial
	_req_source = lesson_source()
	_render()
	var body := lesson_request_body(lang, sel_n, sel_w, Plan.stage_of(sel_n), _req_source)
	_call = Api.post_json("/lesson", body, Api.TIMEOUT_LLM, true)
	var res: Dictionary = await _call.wait()
	if serial != _lesson_serial or status != "loading":
		return
	_call = null
	if res.get("cancelled", false):
		status = "idle"
		_render()
		return
	if not res["ok"]:
		err = str(res["error"])
		status = "idle"
		_render()
		return
	if not _apply_lesson_data(res["data"]):
		err = "레슨을 만들지 못했어요. 다시 시도해 주세요."
		status = "idle"
		_render()
		return
	_render()


## Loads a /lesson response into the view. Returns false when fewer than 4 valid exercises remain.
func _apply_lesson_data(data: Variant) -> bool:
	var parsed: Array = _parse_lesson(data)
	if parsed.size() < 4:
		return false
	var d: Dictionary = data
	title = str(d.get("title", "오늘의 레슨"))
	var attr: Variant = d.get("attribution", "")
	attribution = str(attr) if attr is String else ""
	load_exercises(parsed)
	return true


## Lesson source chosen on the start screen: "tatoeba" (default, real sentences) or "ai".
func lesson_source() -> String:
	return "ai" if str(Store.prefs.get("lesson_source", "tatoeba")) == "ai" else "tatoeba"


func set_lesson_source(v: String) -> void:
	Store.set_pref("lesson_source", "ai" if v == "ai" else "tatoeba")
	err = ""
	_render()


## Body of POST /lesson. `source` is sent explicitly so the backend knows which generator to use.
static func lesson_request_body(l: String, n: int, w: int, stage: int, source: String) -> Dictionary:
	return {"lang": l, "month": n, "week": w, "stage": stage, "source": "ai" if source == "ai" else "tatoeba"}


## https://tatoeba.org/sentences/show/<id> for an exercise with a numeric tatoeba_id, else "".
static func tatoeba_url(e: Dictionary) -> String:
	var v: Variant = e.get("tatoeba_id", null)
	var id: int = -1
	if v is int or v is float:
		if float(v) == floorf(float(v)):
			id = int(v)
	elif v is String and str(v).is_valid_int():
		id = int(str(v))
	if id < 1:
		return ""
	return "https://tatoeba.org/sentences/show/%d" % id


## Validates and prepares the exercises of a /lesson response. Returns the valid ones.
static func _parse_lesson(data: Variant) -> Array:
	var out: Array = []
	if not (data is Dictionary):
		return out
	var raw: Variant = (data as Dictionary).get("exercises", [])
	if not (raw is Array):
		return out
	for e in raw:
		if valid_exercise(e):
			out.append(prep_exercise(e))
		if out.size() >= 12:
			break
	return out


func load_exercises(parsed: Array) -> void:
	exercises = parsed
	idx = 0
	results = []
	ok_count = 0
	added_count = 0
	status = "run"
	_reset_answer()


static func valid_exercise(e: Variant) -> bool:
	if not (e is Dictionary):
		return false
	var d: Dictionary = e
	var t: String = str(d.get("type", ""))
	var opts_ok := false
	var opts: Variant = d.get("options", null)
	if opts is Array and (opts as Array).size() >= 2:
		opts_ok = true
		for o in opts:
			if not (o is String):
				opts_ok = false
		var a: Variant = d.get("answer", null)
		if not ((a is int or a is float) and int(a) >= 0 and int(a) < (opts as Array).size() and float(a) == floorf(float(a))):
			opts_ok = false
	match t:
		"choice":
			return opts_ok and d.get("question", null) is String
		"fill":
			return opts_ok and d.get("sentence", null) is String and str(d["sentence"]).contains("___")
		"listen":
			return opts_ok and d.get("audio", null) is String and str(d["audio"]).strip_edges() != ""
		"build":
			var ans: Variant = d.get("answer", null)
			if not (ans is Array) or (ans as Array).size() < 2:
				return false
			for tok in ans:
				if not (tok is String) or str(tok).strip_edges() == "":
					return false
			return true
		"speak":
			return d.get("text", null) is String and str(d["text"]).strip_edges() != ""
	return false


## Adds shuffled `tiles` to build exercises.
static func prep_exercise(e: Dictionary) -> Dictionary:
	if str(e.get("type", "")) == "build":
		var toks: Array = []
		for t in e["answer"]:
			toks.append(str(t))
		var extra: Variant = e.get("extra", [])
		if extra is Array:
			var added := 0
			for t in extra:
				if t is String and str(t).strip_edges() != "" and added < 3:
					toks.append(str(t))
					added += 1
		var tiles: Array = []
		for i in toks.size():
			tiles.append({"t": toks[i], "i": i})
		tiles.shuffle()
		e["tiles"] = tiles
	return e


static func join_tokens(arr: Array, l: String) -> String:
	var parts: Array[String] = []
	for t in arr:
		parts.append(str(t))
	return ("" if l == "ja" else " ").join(parts)


func _reset_answer() -> void:
	picked = -1
	built = []
	checked = false
	correct = false
	speak_result = {}
	scoring = false
	if _score_call != null:
		_score_call.cancel()
		_score_call = null
	if _prosody_call != null:
		_prosody_call.cancel()
		_prosody_call = null
	prosody = {}
	prosody_native = {}
	_prosody_key = -1
	_prosody_state = "loading"


func cur() -> Dictionary:
	return exercises[idx]


# ---------------------------------------------------------------- answering

func check_answer() -> void:
	if checked:
		return
	var e: Dictionary = cur()
	var t: String = str(e["type"])
	if t == "build":
		var got_toks: Array = []
		for id in built:
			for tile in e["tiles"]:
				if int(tile["i"]) == int(id):
					got_toks.append(tile["t"])
		correct = TextSim.norm_text(join_tokens(got_toks, lang), lang) == TextSim.norm_text(join_tokens(e["answer"], lang), lang)
	else:
		correct = picked == int(e["answer"])
	checked = true
	results.append({"ok": correct, "ex": e})
	if t == "fill":
		var opts: Array = e["options"]
		Tts.speak(str(e["sentence"]).replace("___", str(opts[int(e["answer"])])), lang)
	elif t == "build":
		Tts.speak(join_tokens(e["answer"], lang), lang)
	_render()


func next_exercise() -> void:
	if idx + 1 < exercises.size():
		idx += 1
		_reset_answer()
		_render()
		return
	finish_lesson()


func finish_lesson() -> void:
	var ok := 0
	var wrong: Array = []
	for r in results:
		if r["ok"]:
			ok += 1
		else:
			var item: Dictionary = review_from_exercise(r["ex"], lang)
			if not item.is_empty():
				wrong.append(item)
	ok_count = ok
	StudyLog.add_lesson(lang, ok, results.size())
	Store.add_xp(lang, ok * 10)
	Store.inc_stat(lang, "lessons")
	Store.mark_today(lang)
	added_count = Store.add_review(wrong)
	Store.save_progress()
	status = "done"
	_render()


## Mirrors the web app's reviewFromEx(). Returns {} for choice questions.
static func review_from_exercise(e: Dictionary, l: String) -> Dictionary:
	var t: String = str(e.get("type", ""))
	match t:
		"build":
			return {"lang": l, "target": join_tokens(e["answer"], l), "reading": e.get("reading", ""), "ko": e.get("ko", ""), "note": e.get("explain", "")}
		"fill":
			var opts: Array = e["options"]
			return {"lang": l, "target": str(e["sentence"]).replace("___", str(opts[int(e["answer"])])), "reading": e.get("reading", ""), "ko": e.get("ko", ""), "note": e.get("explain", "")}
		"listen":
			var o: Array = e["options"]
			return {"lang": l, "target": e["audio"], "reading": e.get("reading", ""), "ko": str(o[int(e["answer"])]), "note": e.get("explain", "")}
		"speak":
			return {"lang": l, "target": e["text"], "reading": e.get("reading", ""), "ko": e.get("ko", ""), "note": ""}
	return {}


func quit_lesson() -> void:
	_lesson_serial += 1
	_leave_msec = -100000
	_stale = false
	if _call != null:
		_call.cancel()
		_call = null
	_reset_answer()
	Tts.stop()
	status = "idle"
	_render()


func on_hide() -> void:
	if _record_widget != null and is_instance_valid(_record_widget):
		_record_widget.stop_if_recording()
	Tts.stop()
	if status == "loading":
		quit_lesson() ## the lesson request is cancelled; the lesson home is shown when the tab comes back
		return
	if status != "run":
		return
	if _score_call != null:
		_score_call.cancel()
		_score_call = null
		scoring = false
		_stale = true
	if _prosody_call != null:
		_prosody_call.cancel()
		_prosody_call = null
		_prosody_key = -1 ## asked again by the next render
		_prosody_state = "loading"
		_stale = true


## Android back button. While solving, the first press only asks (the progress would be lost); the second one within
## 2 s goes back to the lesson home. Returns false on the lesson home (main.gd then goes to 오늘).
func go_back() -> bool:
	match status:
		"loading", "done":
			quit_lesson()
			return true
		"run":
			var now: int = Time.get_ticks_msec()
			if now - _leave_msec > 2000:
				_leave_msec = now
				Toast.info("레슨을 나가면 지금까지 푼 것이 사라져요. 나가려면 한 번 더 눌러 주세요.")
				return true
			quit_lesson()
			return true
	return false


# ---------------------------------------------------------------- rendering

func _render() -> void:
	if _page == null:
		return
	_record_widget = null
	_prosody_panel = null
	_prosody_tips = null
	_loading_label = null
	_footer_holder.visible = false
	var c: VBoxContainer = _page.content
	UI.clear(c)
	UI.clear(_footer_col.content)
	match status:
		"loading":
			_render_loading(c)
		"run":
			_render_run(c)
		"done":
			_render_done(c)
		_:
			_render_home(c)
	UI.fix_cjk(c)
	UI.fix_cjk(_footer_col.content)


func _render_home(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	var top := UI.adaptive(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		err = ""
		_render()))
	if not Platform.is_phone():
		top.add_child(UI.spacer())
	top.add_child(UI.label("%d XP · 레슨 %d회" % [Store.xp(lang), Store.stat(lang, "lessons")], "Muted", false))
	c.add_child(top)
	if err != "":
		c.add_child(_error_box(err))

	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("오늘의 레슨", "Eyebrow", false))
	card.body.add_child(UI.label(UI.plain(Store.month_data(lang, sel_n).get("title", "")), "H2"))
	card.body.add_child(UI.label("이번 주에 배울 표현으로 문장 고르기, 빈칸, 문장 조립, 듣기, 따라 말하기 문제를 매번 새로 만들어요. 실제 예문 레슨은 바로 만들어지고, AI 레슨은 10~60초 걸릴 수 있어요.", "Muted"))

	var months: Array = Store.months(lang)
	var m_items: Array = []
	var m_sel := 0
	for i in months.size():
		var m: Dictionary = months[i]
		m_items.append("%d개월차 · %s" % [int(m["n"]), UI.plain(m["title"])])
		if int(m["n"]) == sel_n:
			m_sel = i
	var w_items: Array = []
	var weeks: Array = Store.month_data(lang, sel_n).get("weeks", [])
	for i in weeks.size():
		w_items.append("%s · %s" % [str((weeks[i] as Dictionary).get("w", "")), UI.plain((weeks[i] as Dictionary).get("topic", ""))])
	var mo := UI.option_button(m_items, m_sel)
	mo.item_selected.connect(func(i: int) -> void:
		sel_n = int((months[i] as Dictionary)["n"])
		sel_w = 1
		_render())
	var wo := UI.option_button(w_items, clampi(sel_w - 1, 0, maxi(0, w_items.size() - 1)))
	wo.item_selected.connect(func(i: int) -> void: sel_w = i + 1)
	var fields := UI.adaptive(12)
	var f1 := UI.field("범위", mo)
	f1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var f2 := UI.field("주차", wo)
	f2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_child(f1)
	fields.add_child(f2)
	card.body.add_child(fields)

	var src_items: Array = [["tatoeba", "실제 예문 레슨 (빠름)"], ["ai", "AI 레슨 (느림)"]]
	if Platform.is_phone():
		src_items = [["tatoeba", "실제 예문 (빠름)"], ["ai", "AI (느림)"]]
	var src_seg := UI.segmented(src_items, lesson_source(), set_lesson_source, func(_v: String) -> Color: return acc)
	card.body.add_child(UI.field("레슨 종류", src_seg))

	var go := UI.button("레슨 시작", "primary", acc, 52)
	go.pressed.connect(start_lesson)
	card.body.add_child(go)
	c.add_child(card)

	var rv: int = Store.review_for(lang).size()
	var rc := UI.card("Card", 8)
	rc.body.add_child(UI.label("복습", "Eyebrow", false))
	rc.body.add_child(UI.label("틀린 문장 다시 말하기", "H3"))
	if rv > 0:
		rc.body.add_child(UI.label("레슨과 대화에서 틀리거나 고친 문장 %d개가 모여 있어요." % rv, "Muted"))
		var rb := UI.button("복습하러 가기", "soft", acc, 44)
		rb.pressed.connect(func() -> void: Store.navigate.emit("review", lang))
		rc.body.add_child(rb)
	else:
		rc.body.add_child(UI.label("아직 복습할 문장이 없어요. 레슨에서 틀린 문장과 대화에서 교정받은 문장이 여기에 쌓여요.", "Muted"))
	c.add_child(rc)


func _error_box(msg: String) -> Control:
	var p := UI.tinted_panel(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
	p.add_child(UI.colored(msg, Pal.BAD))
	return p


func _render_loading(c: VBoxContainer) -> void:
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("%s 레슨" % NAME_KO[lang], "Eyebrow", false))
	card.body.add_child(UI.label("레슨을 만드는 중이에요", "H2"))
	_loading_label = UI.label("레슨을 만드는 중…" if _req_source == "tatoeba" else "", "Muted")
	card.body.add_child(_loading_label)
	var bar := ProgressBar.new()
	bar.indeterminate = true
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.add_theme_stylebox_override("fill", UI.style(Pal.accent(lang), Color(0, 0, 0, 0), 0, 99, 0, 0))
	card.body.add_child(bar)
	var stop := UI.button("그만두기", "outline", Pal.accent(lang))
	stop.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stop.pressed.connect(func() -> void:
		_lesson_serial += 1
		if _call != null:
			_call.cancel()
			_call = null
		status = "idle"
		_render())
	card.body.add_child(stop)
	c.add_child(card)


func _render_done(c: VBoxContainer) -> void:
	var acc: Color = Pal.accent(lang)
	var total: int = exercises.size()
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("레슨 완료", "Eyebrow", false))
	card.body.add_child(UI.label(title, "H2"))
	var stats := UI.hbox(8)
	for spec in [["%d/%d" % [ok_count, total], "맞힌 문제"], ["+%d" % (ok_count * 10), "XP"], [str(added_count), "복습에 추가"]]:
		var p := UI.tinted_panel(Pal.soft(lang), Color(0, 0, 0, 0), 0, 10, 14, 10)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var v := UI.vbox(0)
		var n := Label.new()
		n.text = spec[0]
		n.add_theme_font_size_override("font_size", 26)
		n.add_theme_font_override("font", UI.bold_font())
		n.add_theme_color_override("font_color", acc)
		v.add_child(n)
		v.add_child(UI.label(spec[1], "Small", false))
		p.add_child(v)
		stats.add_child(p)
	card.body.add_child(stats)
	card.body.add_child(UI.label("오늘 %s 공부 완료로 기록했어요. 틀린 문장은 복습 목록에 들어갔어요." % NAME_KO[lang], "Muted"))
	var row := UI.hbox(8)
	var again := UI.button("레슨 하나 더", "primary", acc, 48)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.pressed.connect(start_lesson)
	var talk := UI.button("원어민과 대화", "soft", acc, 48)
	talk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	talk.pressed.connect(func() -> void: Store.navigate.emit("talk", lang))
	row.add_child(again)
	row.add_child(talk)
	card.body.add_child(row)
	var row2 := UI.hbox(8)
	if added_count > 0:
		var rv := UI.button("복습하러 가기", "default")
		rv.pressed.connect(func() -> void: Store.navigate.emit("review", lang))
		row2.add_child(rv)
	var home := UI.button("처음으로", "default")
	home.pressed.connect(func() -> void:
		status = "idle"
		_render())
	row2.add_child(home)
	card.body.add_child(row2)
	if attribution != "":
		card.body.add_child(UI.colored(attribution, Pal.MUTED, "Small"))
	c.add_child(card)


func _reading_label(r: Variant, pron: Variant = "") -> Control:
	if lang == "ja" and str(r) != "":
		return ReadingLine.make(str(r), lang, Store.pref_bool("show_reading"), 0.0, str(pron))
	return null


func _render_run(c: VBoxContainer) -> void:
	var e: Dictionary = cur()
	var t: String = str(e["type"])
	var acc: Color = Pal.accent(lang)
	var n: int = exercises.size()

	var bar_row := UI.hbox(12)
	var quit := UI.link_button("그만")
	quit.pressed.connect(quit_lesson)
	bar_row.add_child(quit)
	var pb := UI.progress_bar(float(idx) / float(n), acc, 12.0)
	bar_row.add_child(pb)
	bar_row.add_child(UI.label("%d/%d" % [idx + 1, n], "Muted", false))
	c.add_child(bar_row)

	var panel := UI.card("BigCard", 14)
	panel.body.add_child(UI.colored(TYPE_LABEL[t], acc, "Strong", false))
	c.add_child(panel)

	match t:
		"choice":
			panel.body.add_child(_big_text(str(e["question"])))
			panel.body.add_child(_options(e))
		"fill":
			panel.body.add_child(_big_text(str(e["sentence"])))
			var r := _reading_label(e.get("reading", ""), e.get("pron", ""))
			if r != null:
				panel.body.add_child(r)
			if str(e.get("ko", "")) != "":
				panel.body.add_child(UI.label(str(e["ko"]), "Muted"))
			panel.body.add_child(_options(e))
		"listen":
			var row := UI.hbox(12)
			var play := UI.button("▶", "primary", acc, 72)
			play.custom_minimum_size = Vector2(88, 72)
			play.add_theme_font_size_override("font_size", 28)
			play.pressed.connect(func() -> void: Tts.speak(str(e["audio"]), lang, false))
			row.add_child(play)
			var slow := UI.button("천천히", "soft", acc, 48)
			slow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			slow.pressed.connect(func() -> void: Tts.speak(str(e["audio"]), lang, true))
			row.add_child(slow)
			panel.body.add_child(row)
			if checked:
				panel.body.add_child(_big_text(str(e["audio"])))
				var r2 := _reading_label(e.get("reading", ""), e.get("pron", ""))
				if r2 != null:
					panel.body.add_child(r2)
			else:
				panel.body.add_child(UI.label("소리를 듣고 알맞은 뜻을 골라요.", "Muted"))
			panel.body.add_child(_options(e))
			if not checked and _autoplayed != _lesson_serial * 100 + idx:
				_autoplayed = _lesson_serial * 100 + idx
				Tts.speak(str(e["audio"]), lang, false)
		"build":
			panel.body.add_child(_big_text(str(e.get("ko", ""))))
			panel.body.add_child(_build_area(e))
		"speak":
			panel.body.add_child(_big_text(str(e["text"])))
			var r3 := _reading_label(e.get("reading", ""), e.get("pron", ""))
			if r3 != null:
				panel.body.add_child(r3)
			if str(e.get("ko", "")) != "":
				panel.body.add_child(UI.label(str(e["ko"]), "Muted"))
			panel.body.add_child(UI.speak_buttons(str(e["text"]), lang))
			panel.body.add_child(UI.hline())
			if lang == "en": # intonation graph: English only for now
				panel.body.add_child(_prosody_section())
				panel.body.add_child(UI.hline())
			_record_widget = RecorderWidget.new(true, acc, true)
			_record_widget.recorded.connect(_on_recorded)
			_record_widget.set_enabled(not scoring)
			panel.body.add_child(_record_widget)
			if scoring:
				panel.body.add_child(UI.label("발음을 채점하는 중이에요…", "Muted"))
			elif not speak_result.is_empty():
				panel.body.add_child(UI.hline())
				panel.body.add_child(ScorePanel.build(speak_result, lang))
	if attribution != "":
		panel.body.add_child(_attribution_label(e))
	_render_footer(e, t)


## Source credit under the exercise (CC BY). Opens the sentence on Tatoeba when the exercise has one.
func _attribution_label(e: Dictionary) -> Label:
	var l := UI.colored(attribution, Pal.MUTED, "Small")
	var url := tatoeba_url(e)
	if url != "":
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		l.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		l.tooltip_text = url
		UI.on_tap(l, func() -> void: OS.shell_open(url))
	return l


## "억양" block of the speak exercise: contour graph (+ Japanese accent) and, after a recording, tips.
func _prosody_section() -> Control:
	var box := UI.vbox(8)
	var hidden: bool = Store.pref_bool("hide_prosody")
	var head := UI.hbox(8)
	head.add_child(UI.label("억양", "Eyebrow", false))
	head.add_child(UI.spacer())
	var tg := UI.link_button("보기" if hidden else "숨기기")
	tg.pressed.connect(func() -> void:
		Store.set_pref("hide_prosody", not hidden)
		_render())
	head.add_child(tg)
	box.add_child(head)
	if hidden:
		return box
	var key: int = _lesson_serial * 100 + idx
	if _prosody_key != key:
		_prosody_key = key
		_load_prosody("")
	_prosody_panel = ProsodyPanel.new(lang)
	box.add_child(_prosody_panel)
	_prosody_tips = UI.vbox(0)
	box.add_child(_prosody_tips)
	_apply_prosody()
	return box


func _prosody_message() -> String:
	if _prosody_state == "error":
		return "억양을 분석하지 못했어요. (서버를 새로 시작하면 쓸 수 있어요)"
	return "억양을 분석하는 중이에요…"


## Pushes `prosody` into the live widgets without re-rendering the page (a re-render would
## rebuild the recorder while the learner may be recording).
func _apply_prosody() -> void:
	if _prosody_panel != null and is_instance_valid(_prosody_panel):
		if prosody.is_empty():
			_prosody_panel.set_message(_prosody_message())
		else:
			_prosody_panel.set_data(prosody)
	if _prosody_tips != null and is_instance_valid(_prosody_tips):
		UI.clear(_prosody_tips)
		var tips: Variant = prosody.get("tips_ko", [])
		if prosody.get("mine", null) != null and tips is Array and not (tips as Array).is_empty():
			_prosody_tips.add_child(ProsodyPanel.tips_box(tips as Array))
			UI.fix_cjk(_prosody_tips)


func _load_prosody(audio_b64: String) -> void:
	if _prosody_call != null:
		_prosody_call.cancel()
		_prosody_call = null
	var serial: int = _lesson_serial
	var my_idx: int = idx
	var e: Dictionary = cur()
	var body := {"lang": lang, "text": str(e["text"]), "reading": str(e.get("reading", ""))}
	if audio_b64 != "":
		body["audio_b64"] = audio_b64
	else:
		_prosody_state = "loading"
	_prosody_call = Api.post_json("/prosody", body, Api.TIMEOUT_SHORT, false)
	var req = _prosody_call
	var res: Dictionary = await req.wait()
	if serial != _lesson_serial or status != "run" or my_idx != idx or req != _prosody_call:
		return
	_prosody_call = null
	if res["ok"] and res["data"] is Dictionary:
		prosody = res["data"]
		if audio_b64 == "":
			prosody_native = prosody
		_prosody_state = "ok"
	else:
		if audio_b64 == "":
			_prosody_state = "error"
		elif not prosody_native.is_empty():
			prosody = prosody_native
	_apply_prosody()


func _big_text(s: String) -> Label:
	var l := UI.label(s, "")
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_font_override("font", UI.bold_font())
	return l


func _options(e: Dictionary) -> Control:
	var acc: Color = Pal.accent(lang)
	var box := UI.vbox(8)
	var opts: Array = e["options"]
	for i in opts.size():
		var b := UI.option_row(str(opts[i]))
		var state := "idle"
		if checked:
			if i == int(e["answer"]):
				state = "right"
			elif i == picked:
				state = "wrong"
			b.disabled = true
		elif i == picked:
			state = "picked"
		UI.paint_option(b, state, acc)
		var ii: int = i
		b.pressed.connect(func() -> void:
			picked = ii
			_render())
		box.add_child(b)
	return box


func _tile_text(e: Dictionary, id: int) -> String:
	for tile in e["tiles"]:
		if int(tile["i"]) == id:
			return str(tile["t"])
	return ""


func _build_area(e: Dictionary) -> Control:
	var box := UI.vbox(16)
	var ans_panel := UI.tinted_panel(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, 0, 0)
	var ans_col := UI.vbox(0)
	var answer_row := UI.flow(8, 8)
	answer_row.custom_minimum_size = Vector2(0, 52)
	for id in built:
		var tb := UI.tile(_tile_text(e, int(id)))
		tb.disabled = checked
		var iid: int = int(id)
		tb.pressed.connect(func() -> void:
			built.erase(iid)
			_render())
		answer_row.add_child(tb)
	ans_col.add_child(answer_row)
	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 2)
	ans_col.add_child(UI.gap(8))
	ans_col.add_child(line)
	ans_panel.add_child(ans_col)
	box.add_child(ans_panel)

	var pool := UI.flow(8, 8)
	pool.custom_minimum_size = Vector2(0, 52)
	for tile in e["tiles"]:
		var tid: int = int(tile["i"])
		var tb2 := UI.tile(str(tile["t"]))
		if built.has(tid):
			tb2.disabled = true
			tb2.modulate = Color(1, 1, 1, 0.0)
		else:
			tb2.disabled = checked
			tb2.pressed.connect(func() -> void:
				built.append(tid)
				_render())
		pool.add_child(tb2)
	box.add_child(pool)
	return box


# ---------------------------------------------------------------- footer

func _render_footer(e: Dictionary, t: String) -> void:
	var acc: Color = Pal.accent(lang)
	var f: VBoxContainer = _footer_col.content
	_footer_holder.visible = true
	f.add_theme_constant_override("separation", 8)
	var n: int = exercises.size()
	var last: bool = idx + 1 >= n

	if t == "speak":
		if speak_result.is_empty():
			_footer_holder.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
			var skip := UI.button("지금은 말하기 어려워요", "default")
			skip.pressed.connect(_skip_speak)
			f.add_child(skip)
			return
		var score: int = roundi(float(speak_result.get("score", 0)))
		var good: bool = score >= PASS_SCORE
		_style_footer(good)
		f.add_child(UI.colored("맞았어요" if good else "한 번 더 연습해 봐요", Pal.OK if good else Pal.BAD, "H3", false))
		var row := UI.hbox(8)
		var retry := UI.button("다시 말하기", "outline", Pal.OK if good else Pal.BAD, 50)
		retry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		retry.pressed.connect(func() -> void:
			speak_result = {}
			prosody = prosody_native
			_render())
		var nxt := UI.button("결과 보기" if last else "계속", "primary", Pal.OK if good else Pal.BAD, 50)
		nxt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nxt.pressed.connect(func() -> void:
			results.append({"ok": good, "ex": e})
			next_exercise())
		row.add_child(retry)
		row.add_child(nxt)
		f.add_child(row)
		return

	if not checked:
		_footer_holder.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
		var ready: bool = built.size() > 0 if t == "build" else picked >= 0
		var chk := UI.button("확인", "primary", acc, 52)
		chk.disabled = not ready
		chk.pressed.connect(check_answer)
		f.add_child(chk)
		return

	_style_footer(correct)
	var col: Color = Pal.OK if correct else Pal.BAD
	f.add_child(UI.colored("맞았어요" if correct else "아쉬워요", col, "H3", false))
	if t == "build" and not correct:
		f.add_child(UI.label("정답", "Small", false))
		f.add_child(UI.label(join_tokens(e["answer"], lang), "Strong"))
		var rr := _reading_label(e.get("reading", ""), e.get("pron", ""))
		if rr != null:
			f.add_child(rr)
	elif t == "fill":
		var opts: Array = e["options"]
		f.add_child(UI.label(str(e["sentence"]).replace("___", str(opts[int(e["answer"])])), "Strong"))
	if str(e.get("explain", "")) != "":
		f.add_child(UI.label(str(e["explain"]), "Muted"))
	var nb := UI.button("결과 보기" if last else "계속", "primary", col, 52)
	nb.pressed.connect(next_exercise)
	f.add_child(nb)


func _style_footer(ok: bool) -> void:
	_footer_holder.add_theme_stylebox_override("panel", _top_border_style(ok))


func _top_border_style(ok: bool) -> StyleBoxFlat:
	var s := UI.style(Pal.OK_SOFT if ok else Pal.BAD_SOFT, Pal.OK if ok else Pal.BAD, 0, 0, 0, 0)
	s.border_width_top = 2
	return s


func _skip_speak() -> void:
	var e: Dictionary = cur()
	results.append({"ok": false, "ex": e})
	next_exercise()


# ---------------------------------------------------------------- scoring

func _on_recorded(result: Dictionary) -> void:
	if scoring:
		return
	var e: Dictionary = cur()
	scoring = true
	_render()
	var serial: int = _lesson_serial
	var body := {"lang": lang, "target": str(e["text"]), "reading": str(e.get("reading", "")), "audio_b64": result["b64"]}
	_score_call = Api.post_json("/score", body, Api.TIMEOUT_SHORT, true)
	if lang == "en" and not Store.pref_bool("hide_prosody"):
		_load_prosody(str(result["b64"])) # same audio -> contour comparison, runs beside /score
	var req = _score_call
	var res: Dictionary = await req.wait()
	if serial != _lesson_serial or status != "run" or req != _score_call:
		return
	_score_call = null
	scoring = false
	if res["ok"] and res["data"] is Dictionary:
		speak_result = res["data"]
		StudyLog.add_score(lang, speak_result, "lesson")
	_render()
