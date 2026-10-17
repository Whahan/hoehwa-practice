class_name DictationScreen
extends Control
## 받아쓰기 (영어만): 듣고 타자로 쓰고, 단어별로 맞고 틀린 것을 본다. 문장 8개.
## 문장은 GET /practice/sentences?mode=dictation. 채점은 DictationDiff (서버 AI 없음). 계약: 설계 8.3.

signal closed

const SESSION_N := 8
const PASS_SCORE := 85
const XP_PER_PASS := 3
const XP_CAP := 24
const MARK_TODAY_AT := 5
const REVIEW_MAX := 5
const MAX_INPUT := 300
const ATTRIBUTION := "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"
const NEXT_LOCK_MSEC := 250

static var seen_ids: Array = []

var lang: String = "en"
var stage: String = "loading" ## loading | error | empty | unsupported | run | summary
var sentences: Array = []
var results: Array = [] ## 문장마다 {tries, score, passed, gave_up, said, diff, listens, hint}
var idx: int = 0
var attribution: String = ""
var err_text: String = ""
var xp_gained: int = 0
var added_cards: int = 0

var _shell: Dictionary = {}
var _serial: int = 0
var _call = null
var _typed: String = ""
var _edit: LineEdit = null
var _check_btn: Button = null
var _listen_label: Label = null
var _hint_label: Label = null
var _marked_today: bool = false
var _summary_done: bool = false
var _last_next_msec: int = -100000


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)


func _exit_tree() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null


func open(l: String, _args: Dictionary = {}) -> void:
	lang = l
	_reset()
	if lang != "en":
		stage = "unsupported"
		_render()
		return
	_load()


func on_hide() -> void:
	Tts.stop()


func go_back() -> bool:
	closed.emit()
	return true


func _reset() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	sentences = []
	results = []
	idx = 0
	attribution = ""
	err_text = ""
	xp_gained = 0
	added_cards = 0
	_typed = ""
	_marked_today = false
	_summary_done = false
	stage = "loading"


# ---------------------------------------------------------------- loading

func sentences_query() -> String:
	var pos: Dictionary = Store.position()
	var month: int = int(pos.get("n", 1))
	var week: int = int(pos.get("w", 1))
	var q := "lang=en&mode=dictation&stage=%d&month=%d&week=%d&n=%d&seed=%d" % [Plan.stage_of(month), month, week, SESSION_N, randi() % 100000]
	var ex: Array = seen_ids.slice(-100)
	if not ex.is_empty():
		q += "&exclude=" + ",".join(PackedStringArray(ex.map(func(v: Variant) -> String: return str(v))))
	return q


func _load() -> void:
	stage = "loading"
	_render()
	var serial: int = _serial
	var req: Object = SpeakDrill.request("/practice/sentences?" + sentences_query(), null, Api.TIMEOUT_SHORT)
	_call = req
	var res: Dictionary = await req.wait()
	if serial != _serial or stage != "loading":
		return
	_call = null
	if bool(res.get("cancelled", false)):
		return
	if not bool(res.get("ok", false)):
		stage = "error"
		err_text = SpeakDrill.error_message(res, "문장을 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.")
		_render()
		return
	var items := ShadowScreen.parse_sentences(res.get("data", null))
	if items.is_empty():
		stage = "empty"
		err_text = "문장이 없어요. 다른 때 다시 해 보세요."
		_render()
		return
	for it in items:
		var sid: int = int((it as Dictionary).get("id", 0))
		if sid > 0:
			seen_ids.append(sid)
	if seen_ids.size() > 300:
		seen_ids = seen_ids.slice(-200)
	begin_run(items, str((res["data"] as Dictionary).get("attribution", "")))


func begin_run(items: Array, attr: String) -> void:
	sentences = items
	attribution = attr
	results = []
	for i in items.size():
		results.append({"tries": 0, "score": 0, "passed": false, "gave_up": false, "said": "", "diff": {}, "listens": 0, "hint": false})
	idx = 0
	_typed = ""
	stage = "run"
	_render()


# ---------------------------------------------------------------- one sentence

func current() -> Dictionary:
	if idx >= 0 and idx < sentences.size():
		return sentences[idx]
	return {}


func is_checked() -> bool:
	return idx < results.size() and int((results[idx] as Dictionary)["tries"]) > 0


func listen(slow: bool = false) -> void:
	if stage != "run" or current().is_empty():
		return
	var r: Dictionary = results[idx]
	r["listens"] = int(r["listens"]) + 1
	if _listen_label != null and is_instance_valid(_listen_label):
		_listen_label.text = "들은 횟수 %d" % int(r["listens"])
	Tts.speak(str(current()["text"]), "en", slow)


func toggle_hint() -> void:
	if stage != "run" or idx >= results.size():
		return
	var r: Dictionary = results[idx]
	r["hint"] = not bool(r["hint"])
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.visible = bool(r["hint"])


func set_typed(t: String) -> void:
	_typed = t.left(MAX_INPUT)
	if _check_btn != null and is_instance_valid(_check_btn):
		_check_btn.disabled = _typed.strip_edges() == ""


## 확인 (또는 "모르겠어요"). 한 문장에 한 번만 처리된다. 입력이 비었으면 아무 일도 하지 않는다.
func check(gave_up: bool = false) -> bool:
	if stage != "run" or current().is_empty() or is_checked():
		return false
	var said: String = "" if gave_up else _typed.left(MAX_INPUT)
	if not gave_up and said.strip_edges() == "":
		return false
	var target: String = str(current()["text"])
	var d: Dictionary = DictationDiff.diff(said, target)
	var sc: int = 0 if gave_up else int(d["score"])
	var r: Dictionary = results[idx]
	r["tries"] = 1
	r["score"] = sc
	r["gave_up"] = gave_up
	r["said"] = said
	r["diff"] = d
	r["passed"] = (not gave_up) and sc >= PASS_SCORE
	StudyLog.add_event("en", "dictation", 1)
	if bool(r["passed"]):
		_award_xp()
	if not _marked_today and tried_count() >= MARK_TODAY_AT:
		_marked_today = true
		Store.mark_today("en")
		Store.save_progress()
	_render_page()
	_render_footer()
	return true


func _award_xp() -> void:
	if xp_gained + XP_PER_PASS > XP_CAP:
		return
	xp_gained += XP_PER_PASS
	Store.add_xp("en", XP_PER_PASS)
	Store.save_progress()


func tried_count() -> int:
	var n := 0
	for r in results:
		if int((r as Dictionary)["tries"]) > 0:
			n += 1
	return n


func next_sentence() -> void:
	if stage != "run":
		return
	if idx + 1 >= sentences.size():
		finish()
		return
	idx += 1
	_typed = ""
	_render_run()


func _on_next_pressed() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_next_msec < NEXT_LOCK_MSEC:
		return
	_last_next_msec = now
	next_sentence()


## 85점 미만 문장(최대 5개)을 복습 카드로 넣고 요약을 보인다.
func finish() -> void:
	if stage != "run" and stage != "summary":
		return
	stage = "summary"
	Tts.stop()
	if not _summary_done:
		_summary_done = true
		var items: Array = []
		for i in sentences.size():
			if items.size() >= REVIEW_MAX:
				break
			var r: Dictionary = results[i]
			if int(r["tries"]) > 0 and not bool(r["passed"]):
				var s: Dictionary = sentences[i]
				items.append({"lang": "en", "target": str(s["text"]), "reading": "", "ko": str(s.get("ko", "")), "note": "받아쓰기"})
		if not items.is_empty():
			added_cards = Store.add_review(items)
			if added_cards > 0:
				Store.save_progress()
	_render()


## {n, tried, passed, avg}
static func summarize(rs: Array) -> Dictionary:
	var tried := 0
	var passed := 0
	var sum := 0
	for r in rs:
		if int((r as Dictionary)["tries"]) > 0:
			tried += 1
			sum += int((r as Dictionary)["score"])
			if bool((r as Dictionary)["passed"]):
				passed += 1
	return {"n": rs.size(), "tried": tried, "passed": passed, "avg": roundi(float(sum) / float(tried)) if tried > 0 else 0}


# ---------------------------------------------------------------- drawing

func _acc() -> Color:
	return Pal.EN


func _render() -> void:
	var c: VBoxContainer = (_shell["page"] as PageScroll).content
	UI.clear(c)
	_edit = null
	_check_btn = null
	_listen_label = null
	_hint_label = null
	(_shell["title"] as Label).text = "받아쓰기"
	(_shell["count"] as Label).text = ""
	SpeakDrill.hide_footer(_shell)
	match stage:
		"loading":
			c.add_child(UI.label("문장을 불러오는 중이에요…", "Muted"))
			var cb := SpeakDrill.touch_button("취소", "outline", _acc())
			cb.pressed.connect(func() -> void: closed.emit())
			c.add_child(cb)
		"unsupported":
			c.add_child(SpeakDrill.notice("받아쓰기는 영어만 지원해요. 위쪽 탭에서 영어로 바꿔 주세요.", false))
			var ub := SpeakDrill.touch_button("연습으로", "outline", _acc())
			ub.pressed.connect(func() -> void: closed.emit())
			c.add_child(ub)
		"error":
			c.add_child(SpeakDrill.notice(err_text))
			var rb := SpeakDrill.touch_button("다시 시도", "primary", _acc())
			rb.pressed.connect(_load)
			c.add_child(rb)
		"empty":
			c.add_child(SpeakDrill.notice(err_text if err_text != "" else "문장이 없어요.", false))
			var bb := SpeakDrill.touch_button("연습으로", "outline", _acc())
			bb.pressed.connect(func() -> void: closed.emit())
			c.add_child(bb)
		"run":
			_render_run()
		"summary":
			_render_summary(c)
	UI.fix_cjk(c)


func _render_run() -> void:
	if stage != "run":
		return
	(_shell["count"] as Label).text = "%d / %d" % [idx + 1, sentences.size()]
	_render_page()
	_render_footer()


func _render_page() -> void:
	var c: VBoxContainer = (_shell["page"] as PageScroll).content
	UI.clear(c)
	_listen_label = null
	_hint_label = null
	var s: Dictionary = current()
	if s.is_empty():
		return
	var r: Dictionary = results[idx]
	var acc := _acc()
	var target: String = str(s["text"])

	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("들리는 대로 영어로 써 보세요", "H3"))
	var lr := UI.flow(8, 8)
	var b1 := SpeakDrill.touch_button("▶ 듣기", "primary", acc)
	b1.pressed.connect(func() -> void: listen(false))
	lr.add_child(b1)
	var b2 := SpeakDrill.touch_button("천천히", "soft", acc)
	b2.pressed.connect(func() -> void: listen(true))
	lr.add_child(b2)
	_listen_label = UI.label("들은 횟수 %d" % int(r["listens"]), "Muted", false)
	_listen_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lr.add_child(_listen_label)
	card.body.add_child(lr)
	var wc: int = DictationDiff.word_count(target)
	card.body.add_child(UI.label("단어 %d개" % wc, "Strong"))
	if not is_checked():
		var hr := UI.flow(8, 8)
		var hb := SpeakDrill.touch_button("첫 글자 힌트", "outline", acc)
		hb.pressed.connect(toggle_hint)
		hr.add_child(hb)
		var gb := SpeakDrill.touch_button("모르겠어요", "outline", Pal.MUTED)
		gb.pressed.connect(func() -> void: check(true))
		hr.add_child(gb)
		card.body.add_child(hr)
		_hint_label = UI.label(DictationDiff.first_letters(target), "Muted")
		_hint_label.visible = bool(r["hint"])
		card.body.add_child(_hint_label)
	c.add_child(card)

	if is_checked():
		c.add_child(_result_card(s, r))
	UI.fix_cjk(c)


func _result_card(s: Dictionary, r: Dictionary) -> Control:
	var d: Dictionary = r["diff"]
	var card := UI.card("Card", 10)
	var sc: int = int(r["score"])
	var passed: bool = bool(r["passed"])
	card.body.add_child(UI.colored("%d점" % sc, ScorePanel.score_color(float(sc)), "H1", false))
	if bool(r["gave_up"]):
		card.body.add_child(UI.label("정답을 확인했어요. 다음에 또 해 봐요.", "Muted"))
	else:
		card.body.add_child(UI.colored("통과!" if passed else "통과 기준은 %d점이에요." % PASS_SCORE, Pal.OK if passed else Pal.WARN, "Strong"))
		card.body.add_child(UI.label("내가 쓴 것:  " + str(r["said"]), "Muted"))
	var chips := UI.flow(6, 6)
	for w in d.get("words", []):
		var wd: Dictionary = w
		var kind: String = str(wd.get("kind", "missing"))
		var txt: String = str(wd["w"])
		var fg: Color = Pal.OK
		var bg: Color = Pal.OK_SOFT
		if kind == "missing":
			txt += "  · 빠짐"
			fg = Pal.BAD
			bg = Pal.BAD_SOFT
		elif kind == "typo":
			txt += "  · 철자 틀림 (%s)" % str(wd.get("said", ""))
			fg = Pal.BAD
			bg = Pal.BAD_SOFT
		var chip := UI.chip(txt, fg, bg)
		(chip.get_child(0) as Label).add_theme_font_size_override("font_size", 16)
		chips.add_child(chip)
	card.body.add_child(chips)
	var extra: Array = d.get("extra", [])
	if not extra.is_empty():
		card.body.add_child(UI.colored("정답에 없는 단어:  " + ", ".join(PackedStringArray(extra)), Pal.WARN, "Small"))
	card.body.add_child(UI.hline())
	card.body.add_child(UI.label("정답", "Eyebrow", false))
	var tr := UI.hbox(8)
	var tl := UI.label(str(s["text"]), "Strong")
	tr.add_child(tl)
	var pb := SpeakDrill.touch_button("▶", "soft", _acc())
	pb.pressed.connect(func() -> void: Tts.speak(str(s["text"]), "en", false))
	tr.add_child(pb)
	card.body.add_child(tr)
	if str(s.get("ko", "")) != "":
		card.body.add_child(UI.label(str(s["ko"]), "Muted"))
	if attribution != "":
		card.body.add_child(UI.colored(attribution, Pal.MUTED, "Small"))
	return card


func _render_footer() -> void:
	if stage != "run":
		return
	var row := SpeakDrill.new_footer_row(_shell)
	_edit = null
	_check_btn = null
	if is_checked():
		row.add_child(UI.spacer())
		var nb := SpeakDrill.touch_button("결과 보기" if idx + 1 >= sentences.size() else "다음 ▶", "primary", _acc())
		nb.pressed.connect(_on_next_pressed)
		row.add_child(nb)
		return
	_edit = LineEdit.new()
	_edit.max_length = MAX_INPUT
	_edit.placeholder_text = "들은 문장을 써 보세요"
	_edit.custom_minimum_size = Vector2(0, 48)
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.text = _typed
	_edit.text_changed.connect(set_typed)
	_edit.text_submitted.connect(func(_t: String) -> void: check(false))
	row.add_child(_edit)
	_check_btn = SpeakDrill.touch_button("확인", "primary", _acc(), 48)
	_check_btn.disabled = _typed.strip_edges() == ""
	_check_btn.pressed.connect(func() -> void: check(false))
	row.add_child(_check_btn)


func _render_summary(c: VBoxContainer) -> void:
	var acc := _acc()
	var sm: Dictionary = summarize(results)
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("오늘의 받아쓰기", "Eyebrow", false))
	if int(sm["tried"]) == 0:
		card.body.add_child(UI.label("써 본 문장이 없어요.", "H2"))
	else:
		card.body.add_child(UI.colored("평균 %d점" % int(sm["avg"]), ScorePanel.score_color(float(sm["avg"])), "H1", false))
		card.body.add_child(UI.label("통과 %d개 / 시도 %d개 (통과 기준 %d점)" % [int(sm["passed"]), int(sm["tried"]), PASS_SCORE], "Strong"))
	if xp_gained > 0:
		card.body.add_child(UI.label("+%d XP" % xp_gained, "Muted"))
	if added_cards > 0:
		card.body.add_child(UI.label("%d점 미만 문장 %d개를 복습 카드에 넣었어요." % [PASS_SCORE, added_cards], "Muted"))
	c.add_child(card)
	var list := UI.card("Card", 8)
	for i in sentences.size():
		var r: Dictionary = results[i]
		var row := UI.hbox(10)
		var tag := "-" if int(r["tries"]) == 0 else str(int(r["score"]))
		var col: Color = Pal.MUTED if int(r["tries"]) == 0 else ScorePanel.score_color(float(r["score"]))
		var sl := UI.colored(tag, col, "Strong", false)
		sl.custom_minimum_size.x = 36
		row.add_child(sl)
		row.add_child(UI.label(str((sentences[i] as Dictionary)["text"]), ""))
		list.body.add_child(row)
	c.add_child(list)
	if attribution != "":
		c.add_child(UI.colored(attribution, Pal.MUTED, "Small"))
	var again := SpeakDrill.touch_button("다시 하기", "primary", acc, 48)
	again.pressed.connect(func() -> void: open("en"))
	c.add_child(again)
	var out := SpeakDrill.touch_button("연습으로", "outline", acc, 48)
	out.pressed.connect(func() -> void: closed.emit())
	c.add_child(out)
