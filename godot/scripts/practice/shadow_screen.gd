class_name ShadowScreen
extends Control
## 쉐도잉: 원어민 목소리를 듣고 바로 따라 말하기. 문장 8개를 한 번에 연습한다.
## 문장은 GET /practice/sentences?mode=shadow (이번 주 예문) 또는 내 복습 카드. 계약: 설계 8.3 (open / closed / on_hide).

signal closed

const SESSION_N := 8
const PASS_SCORE := 70
const XP_PER_PASS := 3
const XP_CAP := 24
const MARK_TODAY_AT := 5
const REVIEW_MAX := 5
const ATTRIBUTION := "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"
const NEXT_LOCK_MSEC := 250
const SPAN_NOTE := "구간 듣기는 그 부분만 따로 합성해서, 문장 속에서의 억양과 조금 달라요."

## 이미 나왔던 Tatoeba 문장 id (같은 문장이 연달아 나오지 않게 exclude 로 보낸다)
static var seen_ids: Dictionary = {"en": [], "ja": []}

var lang: String = "en"
var stage: String = "start" ## start | loading | error | empty | run | summary
var source: String = "week" ## week | review
var sentences: Array = []
var results: Array = [] ## 문장마다 {tries, best, passed, bad, span_tries}
var idx: int = 0
var attribution: String = ""
var err_text: String = ""
var xp_gained: int = 0
var added_cards: int = 0
var show_ko: bool = true
var span_a: int = -1
var span_b: int = -1
var speak_span: bool = false
var drill: SpeakDrill = null

var _shell: Dictionary = {}
var _top_box: VBoxContainer = null
var _next_btn: Button = null
var _serial: int = 0
var _call = null
var _marked_today: bool = false
var _summary_done: bool = false
var _picking_end: bool = false
var _last_next_msec: int = -100000


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)
	lang = Store.lang()


func _exit_tree() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_leave_run() ## _render() takes the drill and its recorder out of the tree: they would never be freed with this screen


## 허브 계약. args: {source: "week"|"review"} 가 있으면 시작 화면 없이 바로 시작한다.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l if l == "ja" else "en"
	_reset_session()
	var src: String = str(args.get("source", ""))
	if src == "week" or src == "review":
		start_session(src)
	else:
		_render()


func on_hide() -> void:
	if drill != null and is_instance_valid(drill):
		drill.stop_all()


## 안드로이드 뒤로 가기 / 머리줄 버튼. 세션 중이면 시작 화면으로, 시작 화면이면 허브로.
func go_back() -> bool:
	if stage != "start":
		_reset_session()
		_render()
		return true
	closed.emit()
	return true


## 이 화면 안에서만 언어를 바꾼다 (저장된 언어는 그대로). 진행 중인 요청 · 세션은 버린다.
func change_lang(l: String) -> void:
	if l != "en" and l != "ja":
		return
	lang = l
	_reset_session()
	_render()


func _reset_session() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_leave_run()
	stage = "start"
	sentences = []
	results = []
	idx = 0
	attribution = ""
	err_text = ""
	xp_gained = 0
	added_cards = 0
	span_a = -1
	span_b = -1
	speak_span = false
	_picking_end = false
	_marked_today = false
	_summary_done = false


# ---------------------------------------------------------------- loading

func start_session(src: String) -> void:
	_reset_session()
	source = src
	if src == "review":
		var items := review_sentences(lang)
		if items.is_empty():
			stage = "empty"
			err_text = "복습 카드가 없어요. 레슨이나 대화에서 틀린 문장이 여기에 쌓여요."
			_render()
			return
		_begin_run(items, "")
		return
	_load_week()


## 내 복습 카드에서 최대 SESSION_N 문장 (복습할 차례가 된 것 먼저).
static func review_sentences(l: String) -> Array:
	var cards: Array = Store.due_for(l, SESSION_N)
	if cards.size() < SESSION_N:
		var seen := {}
		for c in cards:
			seen[str((c as Dictionary).get("id", ""))] = true
		for c in Store.upcoming_for(l, SESSION_N):
			if cards.size() >= SESSION_N:
				break
			if not seen.has(str((c as Dictionary).get("id", ""))):
				cards.append(c)
	var out: Array = []
	for c in cards:
		var d: Dictionary = c
		var t: String = str(d.get("target", "")).strip_edges()
		if t == "":
			continue
		out.append({"id": 0, "text": t, "ko": str(d.get("ko", "")), "reading": str(d.get("reading", "")), "url": ""})
	return out


func sentences_query() -> String:
	var pos: Dictionary = Store.position()
	var month: int = int(pos.get("n", 1))
	var week: int = int(pos.get("w", 1))
	var q := "lang=%s&mode=shadow&stage=%d&month=%d&week=%d&n=%d&seed=%d" % [lang, Plan.stage_of(month), month, week, SESSION_N, randi() % 100000]
	var ex: Array = (seen_ids[lang] as Array).slice(-100)
	if not ex.is_empty():
		q += "&exclude=" + ",".join(PackedStringArray(ex.map(func(v: Variant) -> String: return str(v))))
	return q


func _load_week() -> void:
	stage = "loading"
	_render()
	var serial: int = _serial
	var my_lang: String = lang
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
	var items := parse_sentences(res.get("data", null))
	if items.is_empty():
		stage = "empty"
		err_text = "문장이 없어요. 다른 때 다시 해 보세요."
		_render()
		return
	var d: Dictionary = res["data"]
	for it in items:
		var sid: int = int((it as Dictionary).get("id", 0))
		if sid > 0:
			(seen_ids[my_lang] as Array).append(sid)
	if (seen_ids[my_lang] as Array).size() > 300:
		seen_ids[my_lang] = (seen_ids[my_lang] as Array).slice(-200)
	_begin_run(items, str(d.get("attribution", "")))


## 서버 응답에서 쓸 수 있는 문장만 고른다.
static func parse_sentences(data: Variant) -> Array:
	var out: Array = []
	if not (data is Dictionary):
		return out
	var arr: Variant = (data as Dictionary).get("sentences", null)
	if not (arr is Array):
		return out
	for s in arr:
		if not (s is Dictionary):
			continue
		var d: Dictionary = s
		var t: String = str(d.get("text", "")).strip_edges().left(300)
		if t == "" or not (d.get("text", null) is String):
			continue
		var sid: int = 0
		var raw_id: Variant = d.get("id", 0)
		if raw_id is int or raw_id is float:
			sid = int(raw_id)
		out.append({"id": sid, "text": t, "ko": str(d.get("ko", "")), "reading": str(d.get("reading", "")), "url": str(d.get("url", ""))})
		if out.size() >= 20:
			break
	return out


func _begin_run(items: Array, attr: String) -> void:
	sentences = items
	attribution = attr
	results = []
	for i in items.size():
		results.append({"tries": 0, "best": -1, "passed": false, "bad": {}, "span_tries": 0})
	idx = 0
	stage = "run"
	_leave_run()
	drill = SpeakDrill.new(lang, "shadow")
	drill.show_prosody = lang == "en"
	drill.auto_record = Store.pref_bool("shadow_auto_rec")
	drill.make_recorder("따라 말하기")
	drill.scored.connect(_on_scored)
	drill.silent_result.connect(func(_t: String) -> void: _render_top())
	_render()
	_show_sentence()


func _leave_run() -> void:
	if drill == null:
		return
	if is_instance_valid(drill):
		drill.stop_all()
		var rec: RecorderWidget = drill.recorder
		if rec != null and is_instance_valid(rec):
			if rec.get_parent() != null:
				rec.get_parent().remove_child(rec)
			rec.queue_free()
		if drill.get_parent() != null:
			drill.get_parent().remove_child(drill)
		drill.queue_free()
	drill = null
	_top_box = null
	_next_btn = null


# ---------------------------------------------------------------- one sentence

func current() -> Dictionary:
	if idx >= 0 and idx < sentences.size():
		return sentences[idx]
	return {}


func _show_sentence() -> void:
	span_a = -1
	span_b = -1
	speak_span = false
	_picking_end = false
	var s: Dictionary = current()
	if drill != null and not s.is_empty():
		drill.set_target(str(s["text"]), str(s.get("reading", "")), str(s.get("ko", "")))
	_render_top()
	_update_footer()
	_update_count()


func next_sentence() -> void:
	if stage != "run":
		return
	if idx + 1 >= sentences.size():
		finish()
		return
	idx += 1
	_show_sentence()


func _on_next_pressed() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_next_msec < NEXT_LOCK_MSEC:
		return # 연타는 한 번만
	_last_next_msec = now
	next_sentence()


func _on_scored(res: Dictionary, _tgt: String) -> void:
	if stage != "run" or idx >= results.size():
		return
	var r: Dictionary = results[idx]
	if speak_span and has_span():
		r["span_tries"] = int(r["span_tries"]) + 1 # 구간 연습은 통과·기록에 넣지 않는다
		_render_top()
		return
	var sc: int = clampi(roundi(float(res.get("score", 0))), 0, 100)
	r["tries"] = int(r["tries"]) + 1
	var was_best: int = int(r["best"])
	r["best"] = maxi(was_best, sc)
	# 자가 평가("잘했어요")로 통과한 문장은 점수가 아니라서 평균에서 뺀다 (r.self). 진짜 점수가 같거나 더 높으면 점수로 되돌린다.
	if SelfRatePanel.is_self_rated(res):
		if sc > was_best:
			r["self"] = true
	elif sc >= was_best:
		r["self"] = false
	var bad: Dictionary = r["bad"]
	for p in SpeakDrill.bad_phonemes(res):
		bad[p] = int(bad.get(p, 0)) + 1
	if int(r["tries"]) == 1:
		StudyLog.add_event(lang, "shadow", 1)
	if sc >= PASS_SCORE and not bool(r["passed"]):
		r["passed"] = true
		_award_xp()
	_check_mark_today()
	_render_top()


func _award_xp() -> void:
	if xp_gained + XP_PER_PASS > XP_CAP:
		return
	xp_gained += XP_PER_PASS
	Store.add_xp(lang, XP_PER_PASS)
	Store.save_progress()


func tried_count() -> int:
	var n := 0
	for r in results:
		if int((r as Dictionary)["tries"]) > 0:
			n += 1
	return n


func _check_mark_today() -> void:
	if not _marked_today and tried_count() >= MARK_TODAY_AT:
		_marked_today = true
		Store.mark_today(lang)
		Store.save_progress()


# ---------------------------------------------------------------- span (구간 반복)

static func words_of(text: String) -> PackedStringArray:
	return text.split(" ", false)


## 단어 칩 (i)을 눌렀을 때의 구간. 반환 {a, b, picking}: a/b = -1 이면 구간 없음.
## 첫 번째 누름 = 그 단어 하나, 두 번째 누름 = 두 칩 사이 (순서가 거꾸로여도 정렬), 같은 칩을 다시 누르면 해제.
static func span_after_tap(a: int, b: int, picking: bool, i: int) -> Dictionary:
	if a < 0:
		return {"a": i, "b": i, "picking": true}
	if picking:
		if a == b and i == a:
			return {"a": -1, "b": -1, "picking": false}
		return {"a": mini(a, i), "b": maxi(a, i), "picking": false}
	return {"a": i, "b": i, "picking": true}


static func span_text(words: PackedStringArray, a: int, b: int) -> String:
	if a < 0 or b < a or b >= words.size():
		return ""
	var t: String = " ".join(words.slice(a, b + 1))
	return t.lstrip(".,!?;:\"“”‘’(").rstrip(".,!?;:\"“”‘’)")


func has_span() -> bool:
	return span_a >= 0 and span_b >= span_a


func current_span_text() -> String:
	return span_text(words_of(str(current().get("text", ""))), span_a, span_b)


func tap_word(i: int) -> void:
	var words := words_of(str(current().get("text", "")))
	if i < 0 or i >= words.size():
		return
	var r: Dictionary = span_after_tap(span_a, span_b, _picking_end, i)
	span_a = int(r["a"])
	span_b = int(r["b"])
	_picking_end = bool(r["picking"])
	if not has_span():
		speak_span = false
	_apply_span_target()
	_render_top()


func clear_span() -> void:
	span_a = -1
	span_b = -1
	speak_span = false
	_picking_end = false
	_apply_span_target()
	_render_top()


func set_speak_span(on: bool) -> void:
	speak_span = on and has_span()
	_apply_span_target()
	_render_top()


func _apply_span_target() -> void:
	if drill == null:
		return
	if speak_span and has_span():
		drill.set_score_target(current_span_text())
	else:
		drill.set_score_target("")


# ---------------------------------------------------------------- summary

## 세션 요약. {n, tried, passed, avg, worst: {p, n}, weak: [인덱스...]}
static func summarize(rs: Array) -> Dictionary:
	var tried := 0
	var passed := 0
	var sum := 0
	var self_n := 0 ## 스스로 평가로 통과한 문장 (평균 점수에 넣지 않는다)
	var bad_all := {}
	var weak: Array = []
	for i in rs.size():
		var r: Dictionary = rs[i]
		if int(r["tries"]) <= 0:
			continue
		tried += 1
		if bool(r.get("self", false)):
			self_n += 1
		else:
			sum += int(r["best"])
		if bool(r["passed"]):
			passed += 1
		if int(r["best"]) < PASS_SCORE:
			weak.append(i)
		for p in (r["bad"] as Dictionary).keys():
			bad_all[p] = int(bad_all.get(p, 0)) + int((r["bad"] as Dictionary)[p])
	var worst := {}
	for p in bad_all.keys():
		if worst.is_empty() or int(bad_all[p]) > int(worst["n"]):
			worst = {"p": str(p), "n": int(bad_all[p])}
	return {"n": rs.size(), "tried": tried, "passed": passed, "avg": roundi(float(sum) / float(tried - self_n)) if tried - self_n > 0 else 0, "worst": worst, "weak": weak, "self_n": self_n}


## 70점 미만으로 끝난 문장을 복습 카드로 (최대 5개). 추가한 장 수를 돌려준다.
func finish() -> void:
	if stage != "run" and stage != "summary":
		return
	stage = "summary"
	_leave_run()
	if not _summary_done:
		_summary_done = true
		var sm: Dictionary = summarize(results)
		var items: Array = []
		for i in sm["weak"]:
			if items.size() >= REVIEW_MAX:
				break
			var s: Dictionary = sentences[int(i)]
			items.append({"lang": lang, "target": str(s["text"]), "reading": str(s.get("reading", "")), "ko": str(s.get("ko", "")), "note": "쉐도잉 %d점" % int((results[int(i)] as Dictionary)["best"])})
		if not items.is_empty():
			added_cards = Store.add_review(items)
			if added_cards > 0:
				Store.save_progress()
	_render()


# ---------------------------------------------------------------- drawing

func _acc() -> Color:
	return Pal.accent(lang)


## Text colour of a score shown beside a pass mark: passed = OK_ON, not passed = WARN_ON (>= 60) or BAD_ON (< 60),
## so a green number never carries a cross (ScorePanel.score_color has its own 80 / 60 steps).
static func score_ink(score: float) -> Color:
	if score >= float(PASS_SCORE):
		return Pal.OK_ON
	return Pal.WARN_ON if score >= 60.0 else Pal.BAD_ON


func _update_count() -> void:
	var c: Label = _shell["count"]
	c.text = "%d / %d" % [idx + 1, sentences.size()] if stage == "run" else ""


func _render() -> void:
	var page: PageScroll = _shell["page"]
	var c: VBoxContainer = page.content
	if drill != null and is_instance_valid(drill) and drill.get_parent() != null:
		drill.get_parent().remove_child(drill)
	_top_box = null
	UI.clear(c)
	(_shell["title"] as Label).text = "쉐도잉"
	_update_count()
	if stage != "run":
		SpeakDrill.hide_footer(_shell, drill.recorder if drill != null and is_instance_valid(drill) else null)
	match stage:
		"start":
			_render_start(c)
		"loading":
			c.add_child(UI.label("문장을 불러오는 중이에요…", "Muted"))
			var cb := SpeakDrill.touch_button("취소", "soft", _acc())
			cb.pressed.connect(func() -> void:
				_reset_session()
				_render())
			c.add_child(cb)
		"error":
			c.add_child(SpeakDrill.notice(err_text))
			var rb := SpeakDrill.touch_button("다시 시도", "primary", _acc())
			rb.pressed.connect(func() -> void: start_session(source))
			c.add_child(rb)
		"empty":
			c.add_child(SpeakDrill.notice(err_text if err_text != "" else "문장이 없어요.", false))
			var bb := SpeakDrill.touch_button("처음으로", "soft", _acc())
			bb.pressed.connect(func() -> void:
				_reset_session()
				_render())
			c.add_child(bb)
		"run":
			_top_box = UI.vbox(12)
			c.add_child(_top_box)
			c.add_child(drill)
			_build_footer()
			_render_top()
		"summary":
			_render_summary(c)
	UI.fix_cjk(c)


func _render_start(c: VBoxContainer) -> void:
	var acc := _acc()
	var top := UI.hbox(12)
	var seg := UI.lang_segmented(lang, func(v: String) -> void: change_lang(v))
	if Platform.is_phone(): # the buttons share the whole row there; at 150 % text the two labels do not fit one line each
		for sb in seg.get_child(0).get_children():
			if sb is Button:
				(sb as Button).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(seg)
	if not Platform.is_phone():
		top.add_child(UI.spacer()) # phone: the control takes the whole row
	SpeakDrill.fit_touch(top)
	c.add_child(top)

	var intro := UI.card("BigCard", 10)
	intro.body.add_child(UI.label("쉐도잉", "Eyebrow", false))
	intro.body.add_child(UI.label("듣고 바로 따라 말하기", "H2"))
	intro.body.add_child(UI.label("원어민 목소리를 한 번 듣고 곧바로 따라 말해요. 문장마다 점수와 억양을 보여 주고, 느리게 듣거나 일부분만 반복할 수 있어요.", "Muted"))
	c.add_child(intro)
	if SelfRatePanel.needed():
		c.add_child(UI.label("지금은 점수를 낼 수 없어요(점수는 PC 연결 시). 따라 말한 뒤 내 목소리와 원어민 소리를 들어 보고 스스로 평가해요.", "Small"))

	var week := UI.card("Card", 8)
	week.body.add_child(UI.label("이번 주 예문", "H3"))
	week.body.add_child(UI.label("이번 달·이번 주에 배우는 단어가 든 실제 예문 %d개예요." % SESSION_N, "Muted"))
	var wb := SpeakDrill.touch_button("시작하기", "primary", acc, 48)
	wb.pressed.connect(func() -> void: start_session("week"))
	week.body.add_child(wb)
	c.add_child(week)

	var n_cards: int = Store.review_for(lang).size()
	var rv := UI.card("Card", 8)
	rv.body.add_child(UI.label("내 복습 카드", "H3"))
	if n_cards > 0:
		rv.body.add_child(UI.label("복습 카드 %d장 중에서 골라요. 복습할 차례가 된 카드가 먼저 나와요." % n_cards, "Muted"))
		var rb := SpeakDrill.touch_button("시작하기", "soft", acc, 48)
		rb.pressed.connect(func() -> void: start_session("review"))
		rv.body.add_child(rb)
	else:
		rv.body.add_child(UI.label("복습 카드가 아직 없어요. 레슨이나 대화에서 틀린 문장이 여기에 쌓여요.", "Muted"))
	c.add_child(rv)

	# option = a switch row in a list group (the pref key and its text are unchanged), the caution under it as a caption
	var opt := UI.card("Group") as ListGroup
	opt.add_switch_row("듣고 나면 자동으로 녹음 시작", "", "shadow_auto_rec")
	c.add_child(opt)
	c.add_child(UI.label("스피커로 들으면 내 소리에 원어민 소리가 섞일 수 있어요. 이어폰을 쓰면 가장 정확해요.", "Small"))


func _render_top() -> void:
	if _top_box == null or not is_instance_valid(_top_box) or stage != "run":
		return
	UI.clear(_top_box)
	var s: Dictionary = current()
	if s.is_empty():
		return
	var acc := _acc()
	var text: String = str(s["text"])
	var card := UI.card("BigCard", 10)
	var big := UI.label(text, "")
	big.add_theme_font_size_override("font_size", Ds.fs(22))
	big.add_theme_font_override("font", UI.bold_font())
	card.body.add_child(big)
	var ko: String = str(s.get("ko", ""))
	if ko != "":
		var kr := UI.hbox(6)
		var kl := UI.label(ko if show_ko else "번역 숨김", "Muted")
		kr.add_child(kl)
		var tb := UI.link_button("보기" if not show_ko else "숨기기")
		tb.custom_minimum_size.y = maxf(SpeakDrill.TOUCH_H, Ds.touch_min())
		tb.pressed.connect(func() -> void:
			show_ko = not show_ko
			_render_top())
		kr.add_child(tb)
		card.body.add_child(kr)

	var lr := UI.flow(8, 8)
	var b1 := SpeakDrill.touch_button("▶ 듣기", "soft", acc)
	b1.pressed.connect(func() -> void: drill.listen(false))
	lr.add_child(b1)
	var b2 := SpeakDrill.touch_button("천천히", "soft", acc)
	b2.pressed.connect(func() -> void: drill.listen(true))
	lr.add_child(b2)
	card.body.add_child(lr)

	if lang == "en":
		card.body.add_child(UI.label("구간 반복: 단어를 눌러 시작과 끝을 고르세요.", "Small"))
		var words := words_of(text)
		var chips := UI.flow(6, 6)
		for i in words.size():
			var in_span: bool = has_span() and i >= span_a and i <= span_b
			var ii: int = i
			# selected = tinted fill + 2 px outline + bold text (never colour alone); tap_word rebuilds the chips
			chips.add_child(UI.filter_chip(words[i], in_span, func() -> void: tap_word(ii)))
		SpeakDrill.fit_touch(chips) # the PC chip is 32 px high: every pressable thing here is at least 44
		for ch in chips.get_children():
			(ch as Control).custom_minimum_size.x = maxf((ch as Control).custom_minimum_size.x, maxf(44.0, Ds.touch_min())) # one short word is still a full-size target
		card.body.add_child(chips)
		if has_span():
			var st := current_span_text()
			card.body.add_child(UI.label("구간:  " + st, "Strong"))
			var sr := UI.flow(8, 8)
			var sl := SpeakDrill.touch_button("구간 듣기", "soft", acc)
			sl.pressed.connect(func() -> void: drill.listen(false, st))
			sr.add_child(sl)
			var sp := SpeakDrill.touch_button("전체 말하기" if speak_span else "구간 말하기", "outline" if speak_span else "soft", acc)
			sp.pressed.connect(func() -> void: set_speak_span(not speak_span))
			sr.add_child(sp)
			var cl := SpeakDrill.touch_button("해제", "flat", acc)
			cl.pressed.connect(clear_span)
			sr.add_child(cl)
			card.body.add_child(sr)
			card.body.add_child(UI.label(SPAN_NOTE, "Small"))
			if speak_span:
				card.body.add_child(UI.label("지금은 이 구간만 채점해요. 점수는 문장 통과에 들어가지 않아요.", "Small"))
	_top_box.add_child(card)

	var r: Dictionary = results[idx] if idx < results.size() else {}
	if not r.is_empty() and int(r["tries"]) > 0:
		var ok := bool(r["passed"])
		if bool(r.get("self", false)):
			_top_box.add_child(UI.colored("✓ 통과! 스스로 '잘했어요'로 평가했어요.", Pal.OK_ON, "Strong"))
		else:
			_top_box.add_child(UI.colored(
				("✓ 통과! 이 문장은 %d점이에요." % int(r["best"])) if ok else ("✕ 아직 %d점이에요. 한 번 더 따라 해 볼까요?" % int(r["best"])),
				Pal.OK_ON if ok else Pal.WARN_ON, "Strong"))
	if attribution != "":
		_top_box.add_child(_attribution_label(s))
	UI.fix_cjk(_top_box)


func _attribution_label(s: Dictionary) -> Label:
	var l := UI.colored(attribution, Pal.MUTED, "Small")
	var url: String = str(s.get("url", ""))
	if url.begins_with("https://tatoeba.org/"):
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		l.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		l.tooltip_text = url
		UI.on_tap(l, func() -> void: OS.shell_open(url))
	return l


func _build_footer() -> void:
	var row := SpeakDrill.new_footer_row(_shell, drill.recorder)
	row.add_child(drill.recorder)
	row.add_child(UI.spacer())
	_next_btn = SpeakDrill.touch_button("다음 ▶", "primary", _acc())
	_next_btn.pressed.connect(_on_next_pressed)
	row.add_child(_next_btn)


func _update_footer() -> void:
	if _next_btn != null and is_instance_valid(_next_btn):
		_next_btn.text = "결과 보기" if idx + 1 >= sentences.size() else "다음 ▶"


func _render_summary(c: VBoxContainer) -> void:
	var acc := _acc()
	var sm: Dictionary = summarize(results)
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("오늘의 쉐도잉", "Eyebrow", false))
	if int(sm["tried"]) == 0:
		card.body.add_child(UI.label("말해 본 문장이 없어요.", "H2"))
	else:
		if int(sm["self_n"]) >= int(sm["tried"]):
			# 전부 스스로 평가: 점수가 없으니 평균을 보이지 않는다
			card.body.add_child(UI.colored("✓ 잘했어요 %d개" % int(sm["passed"]), Pal.OK_ON, "H1", false))
			card.body.add_child(UI.label("시도 %d개 · 점수 대신 스스로 평가했어요" % int(sm["tried"]), "Strong"))
		else:
			card.body.add_child(UI.colored("평균 %d점" % int(sm["avg"]), score_ink(float(sm["avg"])), "H1", false))
			card.body.add_child(UI.label("통과 %d개 / 시도 %d개 (통과 기준 %d점)" % [int(sm["passed"]), int(sm["tried"]), PASS_SCORE], "Strong"))
			if int(sm["self_n"]) > 0:
				card.body.add_child(UI.label("평균에는 스스로 평가한 %d개를 넣지 않았어요." % int(sm["self_n"]), "Small"))
	if lang == "en" and not (sm["worst"] as Dictionary).is_empty():
		card.body.add_child(UI.label("가장 많이 틀린 소리:  %s  (%d번)" % [str(sm["worst"]["p"]), int(sm["worst"]["n"])], "Muted"))
	if xp_gained > 0:
		card.body.add_child(UI.label("+%d XP" % xp_gained, "Muted"))
	if added_cards > 0:
		card.body.add_child(UI.label("%d점 미만 문장 %d개를 복습 카드에 넣었어요." % [PASS_SCORE, added_cards], "Muted"))
	c.add_child(card)

	var list := UI.card("Card", 8)
	for i in sentences.size():
		var r: Dictionary = results[i]
		var row := UI.hbox(10)
		# the mark (✓ passed / ✕ not passed) is the shape cue next to the coloured score
		var tag := "-" if int(r["tries"]) == 0 else "%s %d" % ["✓" if bool(r["passed"]) else "✕", int(r["best"])]
		var col: Color = Pal.MUTED if int(r["tries"]) == 0 else score_ink(float(r["best"]))
		if int(r["tries"]) > 0 and bool(r.get("self", false)):
			tag = "✓ 자가" # 스스로 평가: 점수 숫자 없음
			col = Pal.OK_ON
		var sl := UI.colored(tag, col, "Strong", false)
		sl.custom_minimum_size.x = Ds.fs(60)
		row.add_child(sl)
		row.add_child(UI.label(str((sentences[i] as Dictionary)["text"]), ""))
		list.body.add_child(row)
	c.add_child(list)
	if attribution != "":
		c.add_child(UI.colored(attribution, Pal.MUTED, "Small"))

	var again := SpeakDrill.touch_button("다시 하기", "primary", acc, 48)
	again.pressed.connect(func() -> void: start_session(source))
	c.add_child(again)
	var out := SpeakDrill.touch_button("연습으로", "flat", acc, 48)
	out.pressed.connect(func() -> void: closed.emit())
	c.add_child(out)
