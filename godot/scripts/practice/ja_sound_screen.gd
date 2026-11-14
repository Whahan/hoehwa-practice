class_name JaSoundScreen
extends Control
## 일본어 약한 소리 화면 (v1.7.0 A5, docs/v170_design.md §1.3 · §4.2 A5). 영어 PhonemeScreen 의 일본어 짝이다.
##   list      : 지금 약한 소리(최근 30회) + 소리 직접 고르기 + "추정" 안내
##   detail    : 소리 설명(hint_ko / tip_ko), 비슷한 낱말 쌍(눌러서 듣기), 낱말·구절, [듣고 고르기 시작] [따라 말하기 5문항]
##   listen    : 듣고 고르기 10문항. 소리를 들려주고 두 보기 중 고른다. 한 문항마다 StudyLog.add_phon_obs("ja", p, ok, heard)
##   result    : 정답률, 틀린 쌍, [틀린 낱말 복습 카드로 추가], [같은 소리 다시] [소리 목록으로]. 끝나면 XP 10 + 드릴 1회
##   speak     : 따라 말하기 5문항(SpeakDrill). PC 채점(/score)이면 JaSounds 가 모라 결과를 소리 칸으로 판정, 없으면 자가 평가(통계 제외)
##   speak_result : 따라 말하기 요약
## 기록하는 언어는 항상 "ja" 다 (StudyLog.add_phon_obs 는 언어와 소리 칸이 맞는지 보지 않는다). 화면의 lang 이 ja 가 아니면 안내만 보인다.
## 소리는 가나 읽기(a_rd / b_rd / rd)로 낸다: 한자 표제어를 TTS 가 읽게 하지 않는다. 보기에는 표제어(w)와 읽기(rd)를 함께 보인다.
## 소리는 KanaVoice 한 곳으로만 낸다. 요청은 SpeakDrill.request 로만 간다(이 파일에는 HTTP 부품도 쉘 열기도 없다).
## 한계(화면에 적는다): 따라 말하기는 인식된 글자와 비교한 추정이다. 소리 길이나 성대 울림을 직접 재지는 않는다.
## 쓰는 법(연습 허브): s := JaSoundScreen.new(); s.closed.connect(...); add_child(s); s.open("ja", {"p": "j_long"})  (args.p 는 고르기)
##   뒤로 가기는 go_back() (처리했으면 true), 화면을 떠날 때 on_hide().

signal closed

const LANG := "ja"
const SPEAK_N := 5
const XP_DONE := 10
const MARK_TODAY_AT := 5
const WEAK_SHOWN := 5
const ESTIMATE_TEXT := "인식된 글자와 비교한 추정이에요. 소리 길이나 성대 울림을 직접 재지는 않아요."
const NO_SOUND_TEXT := "일본어 음성이 있어야 해요. 폰 설정에서 일본어 음성 데이터를 내려받거나 PC에 연결해 주세요. 지금은 설명과 낱말 쌍을 눈으로 읽을 수만 있어요."
const NO_DATA_TEXT := "소리 데이터를 불러오지 못했어요. 앱을 다시 켜거나 업데이트해 주세요."
const NO_PAIRS_TEXT := "이 소리는 낱말 쌍이 아직 없어서 듣고 고르기는 쓸 수 없어요. 따라 말하기로 연습해요."
const NO_ITEMS_TEXT := "이 소리는 연습할 낱말과 구절이 아직 없어요."

var lang: String = LANG
var stage: String = "list" ## unsupported | error | list | detail | listen | result | speak | speak_result
var weak: Array = [] ## [{p, n, bad, rate, heard}]
var cur_p: String = ""
var info: Dictionary = {}
var session: Array = [] ## 듣고 고르기 문항 (JaSounds.build_listen_session)
var answers: Array = [] ## 문항마다 {picked: -1 | 0 | 1, ok: bool}
var idx: int = 0
var option_buttons: Array = []
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var xp_gained: int = 0
var cards_added: int = -1 ## -1 = 아직 안 눌렀다
var speak_items: Array = [] ## [{text, target, rd, ko, kind}]
var speak_results: Array = [] ## 문항마다 {tries, success, unavailable, self, last}
var speak_idx: int = 0
var attempts: int = 0
var drill: SpeakDrill = null

var _shell: Dictionary = {}
var _feedback_box: VBoxContainer = null
var _top_box: VBoxContainer = null
var _next_btn: Button = null
var _done: bool = false ## XP · 드릴 기록을 이미 했다 (한 세션에 한 번)
var _marked_today: bool = false


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)
	rng.randomize()


func _exit_tree() -> void:
	_leave_drill() ## _render() takes the drill and its recorder out of the tree: they would never be freed with this screen


## args: {p: "j_long"} 가 있으면 그 소리의 설명 화면으로 바로 간다.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l
	_reset()
	if lang != LANG:
		stage = "unsupported"
		_render()
		return
	if not bool(JaSounds.load_data().get("ok", false)):
		stage = "error"
		_render()
		return
	var p: String = str(args.get("p", ""))
	if p != "" and not JaSounds.category(p).is_empty():
		choose(p)
		return
	_refresh_weak()
	stage = "list"
	_render()


func on_hide() -> void:
	if drill != null and is_instance_valid(drill):
		drill.stop_all()
	else:
		Tts.stop()


## 뒤로: 연습 중이면 소리 설명 -> 소리 목록 -> 허브 순서.
func go_back() -> bool:
	match stage:
		"listen", "result", "speak", "speak_result":
			Tts.stop()
			_leave_drill()
			stage = "detail" if not info.is_empty() else "list"
			_render()
			return true
		"detail":
			info = {}
			_refresh_weak()
			stage = "list"
			_render()
			return true
	closed.emit()
	return true


func _reset() -> void:
	_leave_drill()
	weak = []
	cur_p = ""
	info = {}
	session = []
	answers = []
	idx = 0
	option_buttons = []
	xp_gained = 0
	cards_added = -1
	speak_items = []
	speak_results = []
	speak_idx = 0
	attempts = 0
	_done = false
	_marked_today = false
	stage = "list"


# ---------------------------------------------------------------- pure helpers (checked by the test)

## 낱말 표시: 표제어와 읽기가 다르면 "家 (いえ)", 같으면 표제어만.
static func word_text(w: String, rd: String) -> String:
	return w if rd == "" or rd == w else "%s (%s)" % [w, rd]


## 틀린 비율 (0~1 또는 0~100 어느 쪽으로 와도) -> 0~100 정수.
static func rate_pct(it: Dictionary) -> int:
	var rv: Variant = it.get("rate", null)
	var r: float = float(rv) if (rv is float or rv is int) else 0.0
	if r <= 1.0:
		r *= 100.0
	return clampi(roundi(r), 0, 100)


## 진행 표시 "3 / 10" 를 만드는 한 곳 (듣고 고르기 · 따라 말하기 · 요약이 모두 이 함수로).
static func progress_text(i: int, n: int) -> String:
	return "%d / %d" % [mini(maxi(i, 0), maxi(n, 0)), maxi(n, 0)]


## 정답률 0~100 (문항이 없으면 0).
static func percent(correct: int, total: int) -> int:
	if total <= 0:
		return 0
	return clampi(roundi(100.0 * float(correct) / float(total)), 0, 100)


## 통계에 남기는 "고른 쪽 낱말": 읽기(가나). 통계 한 칸은 12자까지라 길면 표제어, 그것도 길면 비운다.
static func heard_text(opt: Dictionary) -> String:
	var rd: String = str(opt.get("rd", "")).strip_edges()
	if rd != "" and rd.length() <= PhonemeStats.MAX_P_LEN:
		return rd
	var w: String = str(opt.get("w", "")).strip_edges()
	return w if w.length() <= PhonemeStats.MAX_P_LEN else ""


## 따라 말하기 문항 최대 5개: 낱말 2개 + 구절 3개, 모자라면 남은 것으로 채운다.
## 항목: {text(화면 글), target(채점·듣기 글), rd, ko, kind}. 낱말은 한자를 TTS 가 읽지 않게 읽기(가나)를 target 으로 쓴다.
static func build_speak_items(cat: Dictionary, n: int = SPEAK_N) -> Array:
	var words: Array = []
	var phrases: Array = []
	var wr: Variant = cat.get("words", [])
	if wr is Array:
		for w in wr:
			if w is Dictionary and str((w as Dictionary).get("w", "")).strip_edges() != "":
				var d: Dictionary = w
				var rd: String = str(d.get("rd", "")).strip_edges()
				var txt: String = str(d["w"]).strip_edges()
				words.append({"text": txt, "target": rd if rd != "" else txt, "rd": rd, "ko": str(d.get("ko", "")), "kind": "word"})
	var pr: Variant = cat.get("phrases", [])
	if pr is Array:
		for s in pr:
			if s is Dictionary and str((s as Dictionary).get("text", "")).strip_edges() != "":
				var d2: Dictionary = s
				var t2: String = str(d2["text"]).strip_edges()
				phrases.append({"text": t2, "target": t2, "rd": str(d2.get("rd", "")).strip_edges(), "ko": str(d2.get("ko", "")), "kind": "phrase"})
	var out: Array = []
	var nw: int = mini(words.size(), 2)
	var np: int = mini(phrases.size(), n - nw)
	nw = mini(words.size(), n - np) ## phrases ran short: fill with more words
	out.append_array(words.slice(0, nw))
	out.append_array(phrases.slice(0, np))
	return out.slice(0, n)


## 한 번의 채점 결과(ja /score)가 이 소리 칸(p)을 잘 냈는지. JaSounds.annotate 를 복사본에 써서 모라 결과를 소리 칸으로 바꾼다.
## 반환 {has_ph, found, good, success, unavailable, words: [{t, ok, heard}]}
static func judge(res: Dictionary, p: String) -> Dictionary:
	var out := {"has_ph": false, "found": 0, "good": 0, "success": false, "unavailable": true, "words": []}
	var copy: Dictionary = res.duplicate(true)
	if JaSounds.annotate(copy) <= 0:
		return out
	out["has_ph"] = true
	out["unavailable"] = false
	for u in copy["units"]:
		if not (u is Dictionary):
			continue
		var phs: Variant = (u as Dictionary).get("ph", null)
		if not (phs is Array):
			continue
		var hit := 0
		var bad := 0
		var heard := ""
		for ph in phs:
			if not (ph is Dictionary) or str((ph as Dictionary).get("p", "")) != p:
				continue
			hit += 1
			if bool((ph as Dictionary).get("ok", true)):
				out["good"] = int(out["good"]) + 1
			else:
				bad += 1
				var hv: Variant = (ph as Dictionary).get("heard", null)
				if heard == "" and hv != null:
					heard = str(hv)
		if hit > 0:
			out["found"] = int(out["found"]) + hit
			(out["words"] as Array).append({"t": str((u as Dictionary).get("t", "")), "ok": bad == 0, "heard": heard})
	out["success"] = int(out["found"]) > 0 and int(out["good"]) == int(out["found"])
	return out


## 지금 약한 소리 (데이터에 있는 소리 칸만).
static func weak_list(limit: int) -> Array:
	var out: Array = []
	for it in StudyLog.weak_phonemes(LANG, limit + 6):
		if it is Dictionary:
			var p: String = str((it as Dictionary).get("p", ""))
			if JaSounds.is_category(p) and not JaSounds.category(p).is_empty():
				out.append(it)
		if out.size() >= limit:
			break
	return out


func _refresh_weak() -> void:
	weak = weak_list(WEAK_SHOWN)


func current() -> Dictionary:
	if idx >= 0 and idx < session.size():
		return session[idx]
	return {}


func correct_count() -> int:
	var n := 0
	for a in answers:
		if bool((a as Dictionary)["ok"]):
			n += 1
	return n


func answered_count() -> int:
	var n := 0
	for a in answers:
		if int((a as Dictionary)["picked"]) >= 0:
			n += 1
	return n


func speak_success_count() -> int:
	var n := 0
	for r in speak_results:
		if bool((r as Dictionary)["success"]):
			n += 1
	return n


func has_pairs() -> bool:
	var pr: Variant = info.get("pairs", [])
	return pr is Array and not (pr as Array).is_empty()


func has_speak_items() -> bool:
	return not build_speak_items(info).is_empty()


# ---------------------------------------------------------------- choose / listen

## 소리 하나를 고른다: 설명 화면으로.
func choose(p: String) -> void:
	var c: Dictionary = JaSounds.category(p)
	if c.is_empty() or lang != LANG:
		return
	_leave_drill()
	cur_p = p
	info = c
	stage = "detail"
	_render()


## 소리를 낸다 (가나 읽기). 낼 수 없으면 false.
func say(text: String) -> bool:
	return KanaVoice.speak(text)


## 듣고 고르기 시작: 소리가 없거나 낱말 쌍이 없으면 시작하지 않는다.
func start_listen() -> bool:
	if info.is_empty() or not KanaVoice.available():
		return false
	var s: Array = JaSounds.build_listen_session(cur_p, rng)
	if s.is_empty():
		return false
	_leave_drill()
	session = s
	answers = []
	for i in session.size():
		answers.append({"picked": -1, "ok": false})
	idx = 0
	xp_gained = 0
	cards_added = -1
	_done = false
	_marked_today = false
	stage = "listen"
	_enter_question()
	return true


func _enter_question() -> void:
	_render()
	_play_current()


## 이 문항의 소리(재생할 쪽의 읽기)를 다시 들려준다.
func _play_current() -> void:
	var q: Dictionary = current()
	if q.is_empty() or stage != "listen":
		return
	var pair: Dictionary = q["pair"]
	say(str(pair["a_rd"] if str(q["play"]) == "a" else pair["b_rd"]))


func _on_pick(i: int) -> void:
	if stage != "listen" or idx >= answers.size():
		return
	var a: Dictionary = answers[idx]
	if int(a["picked"]) >= 0:
		return
	var q: Dictionary = current()
	var ok: bool = i == int(q["answer"])
	a["picked"] = i
	a["ok"] = ok
	var heard := ""
	if not ok:
		heard = heard_text((q["options"] as Array)[i])
	StudyLog.add_phon_obs(LANG, cur_p, ok, heard) ## 언어는 늘 "ja"
	if not _marked_today and answered_count() >= MARK_TODAY_AT:
		_marked_today = true
		Store.mark_today(LANG)
		Store.save_progress()
	_render_listen_state()


func next_question() -> void:
	if stage != "listen":
		return
	if idx + 1 >= session.size():
		finish_listen()
		return
	idx += 1
	_enter_question()


## 10문항이 끝났을 때: XP 10 한 번, 드릴 기록 1회, 요약.
func finish_listen() -> void:
	if stage != "listen" and stage != "result":
		return
	stage = "result"
	if not _done:
		_done = true
		if answered_count() > 0:
			xp_gained = XP_DONE
			Store.add_xp(LANG, XP_DONE)
			Store.save_progress()
			StudyLog.add_event(LANG, "drill", 1)
			StudyLog.flush()
	_render()


## 틀린 문항의 두 낱말(w, rd, ko)을 복습 카드 항목으로 (같은 낱말은 한 번만).
func wrong_cards() -> Array:
	var out: Array = []
	var seen := {}
	var note: String = "약한 소리 · " + JaSounds.label_of(cur_p)
	for i in session.size():
		if i >= answers.size() or bool((answers[i] as Dictionary)["ok"]) or int((answers[i] as Dictionary)["picked"]) < 0:
			continue
		for o in (session[i]["options"] as Array):
			var w: String = str((o as Dictionary).get("w", "")).strip_edges()
			if w == "" or seen.has(w):
				continue
			seen[w] = true
			out.append({"lang": LANG, "target": w, "reading": str((o as Dictionary).get("rd", "")), "ko": str((o as Dictionary).get("ko", "")), "note": note})
	return out


func add_wrong_cards() -> int:
	if cards_added >= 0:
		return cards_added
	cards_added = Store.add_review(wrong_cards())
	Store.save_progress()
	_render()
	return cards_added


# ---------------------------------------------------------------- speak

## 따라 말하기 시작. 소리가 없거나 문항이 없으면 시작하지 않는다.
func start_speak() -> bool:
	if info.is_empty() or not KanaVoice.available():
		return false
	var items: Array = build_speak_items(info)
	if items.is_empty():
		return false
	_leave_drill()
	speak_items = items
	speak_results = []
	for i in items.size():
		speak_results.append({"tries": 0, "success": false, "unavailable": false, "self": false})
	speak_idx = 0
	attempts = 0
	xp_gained = 0
	_done = false
	_marked_today = false
	stage = "speak"
	drill = SpeakDrill.new(LANG, "drill")
	drill.show_prosody = false
	drill.make_recorder("말하기")
	drill.scored.connect(_on_scored)
	_render()
	_show_speak_item()
	return true


func speak_current() -> Dictionary:
	if speak_idx >= 0 and speak_idx < speak_items.size():
		return speak_items[speak_idx]
	return {}


func _show_speak_item() -> void:
	var it: Dictionary = speak_current()
	if drill != null and not it.is_empty():
		drill.set_target(str(it["target"]), str(it["rd"]), str(it["ko"]))
	(_shell["count"] as Label).text = progress_text(speak_idx + 1, speak_items.size()) if stage == "speak" else ""
	_render_top()
	if _next_btn != null and is_instance_valid(_next_btn):
		_next_btn.text = "결과 보기" if speak_idx + 1 >= speak_items.size() else "다음"


func _on_scored(res: Dictionary, _tgt: String) -> void:
	if stage != "speak" or speak_idx >= speak_results.size():
		return
	var r: Dictionary = speak_results[speak_idx]
	r["tries"] = int(r["tries"]) + 1
	attempts += 1
	var v: Dictionary
	if SelfRatePanel.is_self_rated(res):
		# 채점할 곳이 없어 스스로 "잘했어요"로 평가했다: 이 소리 칸 통계에는 넣지 않는다(StudyLog.add_score 가 이미 건너뜀)
		v = {"has_ph": false, "found": 0, "good": 0, "success": true, "unavailable": false, "words": [], "self": true}
		r["self"] = true
		r["unavailable"] = false
	else:
		v = judge(res, cur_p)
		r["unavailable"] = bool(v["unavailable"])
	r["last"] = v
	if bool(v["success"]) and not bool(r["unavailable"]):
		r["success"] = true
	if not _marked_today and attempts >= MARK_TODAY_AT:
		_marked_today = true
		Store.mark_today(LANG)
		Store.save_progress()
	_render_top()


func next_speak() -> void:
	if stage != "speak":
		return
	if speak_idx + 1 >= speak_items.size():
		finish_speak()
		return
	speak_idx += 1
	_show_speak_item()


func finish_speak() -> void:
	if stage != "speak" and stage != "speak_result":
		return
	stage = "speak_result"
	_leave_drill()
	if not _done:
		_done = true
		if attempts > 0:
			xp_gained = XP_DONE
			Store.add_xp(LANG, XP_DONE)
			Store.save_progress()
			StudyLog.add_event(LANG, "drill", 1)
			StudyLog.flush()
	_render()


func _leave_drill() -> void:
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


# ---------------------------------------------------------------- drawing helpers

func _acc() -> Color:
	return Pal.accent(LANG)


func _btn(text: String, kind: String, node_name: String, min_h: float = 48.0) -> Button:
	var b := SpeakDrill.touch_button(text, kind, _acc(), min_h)
	b.name = node_name
	return b


## 눌러서 소리를 듣는 줄: 표제어(읽기) + 뜻. 소리가 없으면 눌리지 않는다.
func _sound_row(text: String, rd: String, node_name: String) -> Button:
	var b := SpeakDrill.touch_button(text, "soft", _acc(), 56)
	b.name = node_name
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = not KanaVoice.available()
	b.pressed.connect(func() -> void: say(rd))
	return b


func _wrapping_chip(txt: String, kind: String) -> PanelContainer:
	var chip := UI.chip_kind(txt, kind)
	var lbl := chip.get_child(0) as Label
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chip.custom_minimum_size.x = minf(UI.text_width(txt, Ds.fs(13), true) + 28.0, 280.0)
	return chip


func _estimate_note() -> Label:
	var l := UI.label(ESTIMATE_TEXT, "Small")
	l.name = "EstimateNote"
	return l


func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 1 if (Platform.is_phone() or Ds.font_scale > 1.25) else 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 10)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return g


# ---------------------------------------------------------------- drawing

func _render() -> void:
	var c: VBoxContainer = (_shell["page"] as PageScroll).content
	if drill != null and is_instance_valid(drill) and drill.get_parent() != null:
		drill.get_parent().remove_child(drill)
	_top_box = null
	_feedback_box = null
	_next_btn = null
	option_buttons = []
	UI.clear(c)
	(_shell["title"] as Label).text = "약한 소리 (일본어)"
	(_shell["count"] as Label).text = ""
	if stage != "speak":
		SpeakDrill.hide_footer(_shell, drill.recorder if drill != null and is_instance_valid(drill) else null)
	match stage:
		"unsupported":
			c.add_child(SpeakDrill.notice("일본어 약한 소리는 일본어 탭에서 할 수 있어요. 위쪽 탭에서 일본어로 바꿔 주세요.", false))
			var ub := _btn("연습으로", "flat", "CloseBtn")
			ub.pressed.connect(func() -> void: closed.emit())
			c.add_child(ub)
		"error":
			c.add_child(SpeakDrill.notice(NO_DATA_TEXT))
			var eb := _btn("연습으로", "flat", "CloseBtn")
			eb.pressed.connect(func() -> void: closed.emit())
			c.add_child(eb)
		"list":
			_render_list(c)
		"detail":
			_render_detail(c)
		"listen":
			_render_question(c)
			_render_listen_state()
		"result":
			_render_result(c)
		"speak":
			_top_box = UI.vbox(12)
			c.add_child(_top_box)
			c.add_child(drill)
			_build_speak_footer()
			_render_top()
			(_shell["count"] as Label).text = progress_text(speak_idx + 1, speak_items.size())
		"speak_result":
			_render_speak_result(c)
	UI.fix_cjk(c)


func _render_list(c: VBoxContainer) -> void:
	var intro := UI.card("BigCard", 8)
	intro.body.add_child(UI.label("약한 소리 연습 (일본어)", "Eyebrow", false))
	intro.body.add_child(UI.label("헷갈리기 쉬운 소리만 골라서 연습해요", "H2"))
	intro.body.add_child(UI.label("장음, 촉음, 청탁 같은 소리를 두 낱말 중에 골라 듣거나 따라 말하며 연습해요.", "Muted"))
	c.add_child(intro)

	var wk := UI.card("Card", 10)
	wk.body.add_child(UI.label("지금 약한 소리 (최근 30회 기준)", "H3"))
	if weak.is_empty():
		wk.body.add_child(UI.label("아직 약한 소리를 찾지 못했어요. 듣고 고르기나 따라 말하기를 하면 약한 소리를 찾아 줘요. 아래에서 연습할 소리를 직접 골라도 돼요.", "Muted"))
	else:
		var fl := UI.flow(8, 8)
		for it in weak:
			var d: Dictionary = it
			var p: String = str(d["p"])
			var b := SpeakDrill.touch_button("%s  틀림 %d%%" % [JaSounds.label_of(p), rate_pct(d)], "soft", Pal.BAD)
			b.name = "Weak_" + p
			b.pressed.connect(func() -> void: choose(p))
			fl.add_child(b)
		wk.body.add_child(fl)
	c.add_child(wk)

	var all := UI.card("Card", 10)
	all.body.add_child(UI.label("소리 직접 고르기", "H3"))
	var fl2 := UI.flow(8, 8)
	for cat in JaSounds.load_data()["categories"]:
		var p2: String = str((cat as Dictionary)["p"])
		var chip := UI.filter_chip(JaSounds.label_of(p2), false, func() -> void: choose(p2))
		chip.name = "Chip_" + p2
		fl2.add_child(chip)
	SpeakDrill.fit_touch(fl2) # the PC chip is 32 px high: every pressable thing here is at least 44
	all.body.add_child(fl2)
	c.add_child(all)
	c.add_child(_estimate_note())


func _render_detail(c: VBoxContainer) -> void:
	var sound_ok: bool = KanaVoice.available()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label(JaSounds.label_of(cur_p), "H2"))
	if str(info.get("hint_ko", "")) != "":
		card.body.add_child(UI.label(str(info["hint_ko"]), ""))
	if str(info.get("tip_ko", "")) != "":
		card.body.add_child(UI.label(str(info["tip_ko"]), "Muted"))
	c.add_child(card)
	if not sound_ok:
		var nv := UI.colored(NO_SOUND_TEXT, Pal.WARN_ON, "Small")
		nv.name = "NoSoundNote"
		c.add_child(nv)

	var pairs: Variant = info.get("pairs", null)
	if pairs is Array and not (pairs as Array).is_empty():
		var pc := UI.card("Card", 10)
		pc.name = "PairsCard"
		pc.body.add_child(UI.label("비슷한 낱말 (눌러서 듣기)" if sound_ok else "비슷한 낱말", "H3"))
		var i := 0
		for pr in pairs:
			var d: Dictionary = pr
			var g := _grid()
			g.add_child(_sound_row("%s\n%s" % [word_text(str(d["a"]), str(d["a_rd"])), str(d["a_ko"])], str(d["a_rd"]), "PairA_%d" % i))
			g.add_child(_sound_row("%s\n%s" % [word_text(str(d["b"]), str(d["b_rd"])), str(d["b_ko"])], str(d["b_rd"]), "PairB_%d" % i))
			pc.body.add_child(g)
			i += 1
		c.add_child(pc)
	else:
		var np := UI.label(NO_PAIRS_TEXT, "Muted")
		np.name = "NoPairsNote"
		c.add_child(np)

	var words: Variant = info.get("words", null)
	if words is Array and not (words as Array).is_empty():
		var wc := UI.card("Card", 10)
		wc.name = "WordsCard"
		wc.body.add_child(UI.label("이 소리가 든 낱말", "H3"))
		var g2 := _grid()
		var k := 0
		for w in words:
			var wd: Dictionary = w
			g2.add_child(_sound_row("%s\n%s" % [word_text(str(wd["w"]), str(wd["rd"])), str(wd["ko"])], str(wd["rd"]), "Word_%d" % k))
			k += 1
		wc.body.add_child(g2)
		c.add_child(wc)
	var phrases: Variant = info.get("phrases", null)
	if phrases is Array and not (phrases as Array).is_empty():
		var sc := UI.card("Card", 10)
		sc.name = "PhrasesCard"
		sc.body.add_child(UI.label("이 소리가 든 구절", "H3"))
		var m := 0
		for s in phrases:
			var sd: Dictionary = s
			var rds: String = str(sd["rd"])
			sc.body.add_child(_sound_row("%s\n%s\n%s" % [str(sd["text"]), rds, str(sd["ko"])], rds, "Phrase_%d" % m))
			m += 1
		c.add_child(sc)

	var can_listen: bool = sound_ok and has_pairs()
	var can_speak: bool = sound_ok and has_speak_items()
	var go := _btn("듣고 고르기 시작", "primary", "StartListenBtn", 52)
	go.disabled = not can_listen
	go.pressed.connect(func() -> void: start_listen())
	c.add_child(go)
	var sp := _btn("따라 말하기 %d문항" % build_speak_items(info).size(), "soft", "StartSpeakBtn", 52)
	sp.disabled = not can_speak
	sp.pressed.connect(func() -> void: start_speak())
	c.add_child(sp)
	if build_speak_items(info).is_empty():
		c.add_child(UI.label(NO_ITEMS_TEXT, "Muted"))
	c.add_child(_estimate_note())


# ---------------------------------------------------------------- listen drawing

func _render_question(c: VBoxContainer) -> void:
	var q: Dictionary = current()
	if q.is_empty():
		return
	(_shell["count"] as Label).text = progress_text(idx + 1, session.size())
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("듣고 고르기  ·  " + JaSounds.label_of(cur_p), "Eyebrow", false))
	card.body.add_child(UI.label("어느 쪽이 들렸을까요?", "H3"))
	var rb := _btn("다시 듣기", "primary", "ReplayBtn", 56)
	rb.pressed.connect(func() -> void: _play_current())
	card.body.add_child(rb)
	c.add_child(card)

	var g := GridContainer.new()
	g.columns = 1 if (Platform.is_phone() and Ds.font_scale > 1.25) else 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 10)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(g)
	var opts: Array = q["options"]
	for i in opts.size():
		var o: Dictionary = opts[i]
		var b := UI.option_row("%s\n%s" % [word_text(str(o["w"]), str(o["rd"])), str(o["ko"])])
		b.name = "Opt%d" % i
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_font_size_override("font_size", UI.fs(20))
		b.custom_minimum_size = Vector2(0, 72)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var n: int = i
		b.pressed.connect(func() -> void: _on_pick(n))
		g.add_child(b)
		option_buttons.append(b)
	_feedback_box = UI.vbox(8)
	c.add_child(_feedback_box)


## 보기 색 · 정답/오답 상자 · 아래 [다음] 줄을 지금 상태로.
func _render_listen_state() -> void:
	if stage != "listen" or current().is_empty():
		return
	var q: Dictionary = current()
	var a: Dictionary = answers[idx]
	var picked: int = int(a["picked"])
	if picked < 0:
		SpeakDrill.hide_footer(_shell)
		return
	var acc := _acc()
	for i in option_buttons.size():
		var b: Button = option_buttons[i]
		if not is_instance_valid(b):
			continue
		b.disabled = true
		if i == int(q["answer"]):
			UI.paint_option(b, "right", acc)
		elif i == picked:
			UI.paint_option(b, "wrong", acc)
	if _feedback_box != null and is_instance_valid(_feedback_box):
		UI.clear(_feedback_box)
		var ok: bool = bool(a["ok"])
		var p := UI.tinted_panel(Pal.OK_SOFT if ok else Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
		p.name = "Feedback"
		var v := UI.vbox(4)
		p.add_child(v)
		var head := UI.colored("정답이에요" if ok else "아쉬워요", Pal.OK_ON if ok else Pal.BAD_ON, "Strong")
		head.name = "FeedbackHead"
		v.add_child(head)
		var opts: Array = q["options"]
		var right: Dictionary = opts[int(q["answer"])]
		v.add_child(UI.label("들린 낱말:  %s  %s" % [word_text(str(right["w"]), str(right["rd"])), str(right["ko"])], "Strong", true))
		if not ok:
			var wrong: Dictionary = opts[picked]
			v.add_child(UI.label("고른 낱말:  %s  %s" % [word_text(str(wrong["w"]), str(wrong["rd"])), str(wrong["ko"])], "Muted", true))
			if str(info.get("tip_ko", "")) != "":
				v.add_child(UI.label("구별 요령: " + str(info["tip_ko"]), "Small"))
		_feedback_box.add_child(p)
		var pr := UI.flow(8, 8)
		for j in opts.size():
			var o: Dictionary = opts[j]
			var pb := SpeakDrill.touch_button("%s 듣기" % str(o["rd"]), "soft", acc)
			pb.name = "HearOpt%d" % j
			var rd: String = str(o["rd"])
			pb.pressed.connect(func() -> void: say(rd))
			pr.add_child(pb)
		_feedback_box.add_child(pr)
		UI.fix_cjk(_feedback_box)
	var row: HBoxContainer = SpeakDrill.new_footer_row(_shell)
	row.add_child(UI.spacer())
	var nb := _btn("결과 보기" if idx + 1 >= session.size() else "다음", "primary", "NextBtn")
	nb.pressed.connect(func() -> void: next_question())
	row.add_child(nb)
	_next_btn = nb


func _render_result(c: VBoxContainer) -> void:
	var total: int = session.size()
	var good: int = correct_count()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("듣고 고르기 결과  ·  " + JaSounds.label_of(cur_p), "Eyebrow", false))
	var pct: int = percent(good, total)
	var head := UI.colored("정답 %s  (%d%%)" % [progress_text(good, total), pct], Pal.OK_ON if pct >= 70 else Pal.WARN_ON, "H1", false)
	head.name = "ResultHead"
	card.body.add_child(head)
	card.body.add_child(UI.label("한 번에 안 되어도 괜찮아요. 같은 소리를 며칠 나눠서 연습하면 귀가 열려요.", "Muted"))
	if xp_gained > 0:
		card.body.add_child(UI.label("+%d XP" % xp_gained, "Muted"))
	c.add_child(card)

	var wrong_i: Array = []
	for i in answers.size():
		if int((answers[i] as Dictionary)["picked"]) >= 0 and not bool((answers[i] as Dictionary)["ok"]):
			wrong_i.append(i)
	if wrong_i.is_empty():
		c.add_child(UI.label("틀린 쌍이 없어요.", "Muted"))
	else:
		var wc := UI.card("Card", 10)
		wc.name = "WrongPairs"
		wc.body.add_child(UI.label("틀린 쌍", "H3"))
		for i in wrong_i:
			var pair: Dictionary = session[i]["pair"]
			wc.body.add_child(UI.label("%s  %s\n%s  %s" % [word_text(str(pair["a"]), str(pair["a_rd"])), str(pair["a_ko"]), word_text(str(pair["b"]), str(pair["b_rd"])), str(pair["b_ko"])], "", true))
		c.add_child(wc)
		var cb: Button
		if cards_added >= 0:
			cb = _btn("복습 카드에 넣었어요" if cards_added > 0 else "이미 복습 카드에 있어요", "soft", "AddCardsBtn")
			cb.disabled = true
		else:
			cb = _btn("틀린 낱말 복습 카드로 추가", "soft", "AddCardsBtn")
			cb.pressed.connect(func() -> void: add_wrong_cards())
		c.add_child(cb)
	var again := _btn("같은 소리 다시", "primary", "AgainBtn")
	again.pressed.connect(func() -> void: start_listen())
	c.add_child(again)
	var back := _btn("소리 목록으로", "outline", "ListBtn")
	back.pressed.connect(func() -> void:
		Tts.stop()
		info = {}
		_refresh_weak()
		stage = "list"
		_render())
	c.add_child(back)


# ---------------------------------------------------------------- speak drawing

func _build_speak_footer() -> void:
	var row := SpeakDrill.new_footer_row(_shell, drill.recorder)
	row.add_child(drill.recorder)
	row.add_child(UI.spacer())
	_next_btn = _btn("결과 보기" if speak_idx + 1 >= speak_items.size() else "다음", "primary", "NextBtn")
	_next_btn.pressed.connect(func() -> void: next_speak())
	row.add_child(_next_btn)


func _render_top() -> void:
	if _top_box == null or not is_instance_valid(_top_box) or stage != "speak":
		return
	UI.clear(_top_box)
	var it: Dictionary = speak_current()
	if it.is_empty():
		return
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("따라 말하기 %s  ·  %s" % [progress_text(speak_idx + 1, speak_items.size()), JaSounds.label_of(cur_p)], "Eyebrow", false))
	var big := UI.label(str(it["text"]), "")
	big.name = "SpeakText"
	big.add_theme_font_size_override("font_size", Ds.fs(22))
	big.add_theme_font_override("font", UI.bold_font())
	card.body.add_child(big)
	if str(it["rd"]) != "" and str(it["rd"]) != str(it["text"]):
		card.body.add_child(UI.label(str(it["rd"]), "Muted"))
	if str(it.get("ko", "")) != "":
		card.body.add_child(UI.label(str(it["ko"]), "Muted"))
	var lr := UI.flow(8, 8)
	var rd: String = str(it["rd"]) if str(it["rd"]) != "" else str(it["text"])
	var b1 := SpeakDrill.touch_button("듣기", "soft", acc)
	b1.name = "ListenBtn"
	b1.pressed.connect(func() -> void: drill.listen(false, rd))
	lr.add_child(b1)
	var b2 := SpeakDrill.touch_button("천천히", "soft", acc)
	b2.name = "SlowBtn"
	b2.pressed.connect(func() -> void: drill.listen(true, rd))
	lr.add_child(b2)
	card.body.add_child(lr)
	card.body.add_child(_estimate_note())
	_top_box.add_child(card)

	var r: Dictionary = speak_results[speak_idx] if speak_idx < speak_results.size() else {}
	if not r.is_empty() and r.has("last"):
		_top_box.add_child(_verdict_box(r))
	UI.fix_cjk(_top_box)


func _verdict_box(r: Dictionary) -> Control:
	var v: Dictionary = r["last"]
	var box := UI.card("Sunk", 8)
	box.name = "Verdict"
	if bool(v.get("self", false)):
		box.body.add_child(UI.colored("스스로 '잘했어요'로 평가했어요. 이 소리 통계에는 넣지 않아요.", Pal.OK_ON, "Strong"))
		box.body.add_child(UI.label("소리별 판정은 PC에 연결하면 볼 수 있어요.", "Small"))
		return box
	if bool(v["unavailable"]):
		box.body.add_child(UI.colored("이 결과로는 소리별 판정을 할 수 없어요. 점수만 보여 드려요.", Pal.WARN_ON))
		return box
	if int(v["found"]) == 0:
		box.body.add_child(UI.label("이 문장에서 %s 소리를 찾지 못했어요. 다른 문항으로 넘어가도 돼요." % JaSounds.label_of(cur_p), "Muted"))
		box.body.add_child(UI.label(ESTIMATE_TEXT, "Small"))
		return box
	box.body.add_child(UI.label("이번 소리  " + JaSounds.label_of(cur_p), "Strong"))
	var fl := UI.flow(6, 6)
	for w in v["words"]:
		var wd: Dictionary = w
		var ok := bool(wd["ok"])
		var txt: String = str(wd["t"]) + ("  맞음" if ok else "  틀림")
		if not ok and str(wd.get("heard", "")) != "":
			txt += " (%s로 들림)" % str(wd["heard"])
		fl.add_child(_wrapping_chip(txt, "ok" if ok else "bad")) # the words 맞음 / 틀림 are the non-colour cue
	box.body.add_child(fl)
	if bool(v["success"]):
		box.body.add_child(UI.colored("잘 들렸어요. 이 소리를 잘 냈어요.", Pal.OK_ON, "Strong"))
	else:
		box.body.add_child(UI.colored("한 번 더 해 볼까요? 위의 설명을 떠올려 보세요.", Pal.WARN_ON, "Small"))
	box.body.add_child(UI.label(ESTIMATE_TEXT, "Small"))
	return box


func _render_speak_result(c: VBoxContainer) -> void:
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("따라 말하기 결과  ·  " + JaSounds.label_of(cur_p), "Eyebrow", false))
	var all_unavailable := true
	var any_self := false
	for r in speak_results:
		var rr: Dictionary = r
		if int(rr["tries"]) > 0 and not bool(rr["unavailable"]):
			all_unavailable = false
		if int(rr["tries"]) > 0 and bool(rr.get("self", false)):
			any_self = true
	if attempts == 0:
		card.body.add_child(UI.label("말해 본 문항이 없어요.", "H2"))
	elif all_unavailable:
		card.body.add_child(UI.label("%d문항 연습했어요" % attempts, "H2"))
		card.body.add_child(UI.colored("소리별 판정을 쓸 수 없어서 점수만 남겼어요.", Pal.WARN_ON, "Small"))
	else:
		var s: int = speak_success_count()
		var good: bool = s * 2 >= speak_items.size()
		var head := UI.colored("%s %s" % [progress_text(s, speak_items.size()), "잘했어요 (스스로 평가 포함)" if any_self else "잘 냈어요"], Pal.OK_ON if good else Pal.WARN_ON, "H1", false)
		head.name = "SpeakResultHead"
		card.body.add_child(head)
		card.body.add_child(UI.label("한 번에 안 되어도 괜찮아요. 같은 소리를 며칠 나눠서 연습하면 좋아져요.", "Muted"))
	if xp_gained > 0:
		card.body.add_child(UI.label("+%d XP" % xp_gained, "Muted"))
	card.body.add_child(_estimate_note())
	c.add_child(card)
	var again := _btn("다시 하기", "primary", "AgainBtn")
	again.pressed.connect(func() -> void: start_speak())
	c.add_child(again)
	var other := _btn("소리 목록으로", "outline", "ListBtn")
	other.pressed.connect(func() -> void:
		_leave_drill()
		info = {}
		_refresh_weak()
		stage = "list"
		_render())
	c.add_child(other)
