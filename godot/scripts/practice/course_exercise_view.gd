class_name CourseExerciseView
extends Control
## v2.0 코스 문제 화면 (docs/v200_design.md §3.2, §10.4, §14.2 E4a): LessonBuilder 가 만든 문제 하나를 그린다.
## 이 화면은 "한 문제"만 안다. 순서·재출제(숙달 루프)·결과 카드·기록은 플레이어(E4b)가 한다.
##
## 쓰는 법:  var v := CourseExerciseView.new(); host.add_child(v); v.answered.connect(...); v.next_requested.connect(...)
##           v.show_exercise(ex, {"retry": false, "next_text": "다음", "hints": "show", "autoplay": false})
## 신호
##   answered(result)  채점이 끝났을 때 한 번(고르기·쓰기·조립은 [확인] 뒤, 말하기는 채점 결과·자가 평가 뒤).
##                     result = {id, type, mode, item, ok, near, skipped, gave_up, answer, tries, first_try, hint_used, self_rated, ...}
##                     깨진 문제는 show_exercise 맨 끝에서 동기로 {skipped:true, ok:false} 를 낸다(화면은 "이 문제를 건너뛰었어요" + [다음]).
##                     정보 카드(teach_word, teach_pattern, 듣기 대화)는 `answered` 를 내지 않는다: is_info_card() 로 구분.
##   next_requested    [다음] 을 눌렀다. 다음 문제로 넘어가는 일은 호출한 쪽이 한다.
## 정답 판정은 전부 LessonBuilder.judge 를 쓴다(이 파일에는 정규화·비교 코드가 없다).
## 소리는 문제의 `tts` 필드 그대로 Tts.speak(tts, "en", slow) 로 읽는다(`say` 는 읽지 않는다: 데이터가 읽을 글을 정한다).

signal answered(result: Dictionary)
signal next_requested

const LANG := "en"
const PASS_SCORE := 70 ## 말하기: 이 점수 이상이면 맞다(SpeakDrill.PASS_SCORE 와 같다)
const MIN_H := 44.0 ## 누르는 것의 최소 높이(폰은 Ds.touch_min())
const EDIT_H := 56.0
const MAX_TYPED := 200
const NEAR_TRIES := 2 ## 쓰기: "거의 맞아요" 뒤 한 번 더(모두 2번까지)
const SKIPPED_TEXT := "이 문제를 건너뛰었어요"
const KNOWN_TYPES := ["teach_word", "teach_pattern", "recognize", "recall", "build", "listen", "speak", "dialogue_script"]
const STAGE_TITLES := {"intro": "소개", "recognize": "알아보기", "recall": "떠올리기", "build": "조립", "listen": "듣기", "speak": "말하기",
	"dialogue": "대화", "check": "점검", "recap": "복습", "month": "월말 말하기"}

## 지금 문제와 화면 상태. state: empty | asking | near | answered | info | skipped
var ex: Dictionary = {}
var ctx: Dictionary = {}
var kind: String = "" ## info | choice | type | build | speak | dialogue | skipped
var state: String = "empty"
var result: Dictionary = {}
var tries: int = 0
var hint_used: bool = false

## 대화 state: asking(내 차례를 기다림) | turn_done(이 줄을 말함, [이어서] 를 기다림) | answered
## 시험·플레이어가 쓰는 부품(문제마다 새로 만든다. 없으면 null / 빈 배열).
var page: PageScroll = null
var confirm_btn: Button = null
var next_btn: Button = null
var skip_btn: Button = null ## 말하기: [말하기 어려워요]
var continue_btn: Button = null ## 대화: [이어서]
var option_btns: Array = []
var tile_btns: Array = [] ## 타일 더미의 버튼(글자 순서는 섞인 순서)
var chosen: Array = [] ## 조립: 고른 타일 번호 순서
var edit: LineEdit = null
var drill: SpeakDrill = null
var feedback: Control = null
var picked: int = -1

var _root: VBoxContainer = null
var _footer_holder: PanelContainer = null
var _footer_col: ColumnBox = null
var _answer_row: HFlowContainer = null
var _tiles_text: Array = []
var _near_note: Control = null
var _dlg_box: VBoxContainer = null
var _dlg_pos: int = 0
var _dlg_you: int = -1
var _dlg_ok: int = 0
var _dlg_total: int = 0
var _dlg_card: CardBox = null
var _dlg_model: Label = null
var _speak_text: String = ""
var _last_line: Dictionary = {}


func _init() -> void:
	name = "CourseExerciseView"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	page = PageScroll.new(720.0)
	page.name = "Page"
	_root.add_child(page)
	_footer_holder = PanelContainer.new()
	_footer_holder.name = "Footer"
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_top = 1
	_footer_holder.add_theme_stylebox_override("panel", st)
	_footer_holder.visible = false
	_root.add_child(_footer_holder)
	_footer_col = ColumnBox.new()
	_footer_col.max_width = 720.0
	_footer_col.min_pad = Ds.S3
	_footer_col.set_padding(Ds.S3 if Platform.is_phone() else 10, Ds.S3)
	_footer_holder.add_child(_footer_col)


func _exit_tree() -> void:
	_leave_drill()


# ================================================================== 공개 함수

## 문제 하나를 그린다. ex 가 깨졌거나 모르는 종류면 에러 없이 "이 문제를 건너뛰었어요" 로 보이고 answered(skipped:true) 를 낸다.
## ctx(모두 선택): retry(bool: "한 번 더" 표시), next_text(String), hints("show"|"tap"|"none": 대화 힌트), autoplay(bool: 듣기 문제에서 바로 재생).
func show_exercise(ex_in: Variant, ctx_in: Variant = {}) -> void:
	_reset()
	ctx = {}
	if ctx_in is Dictionary:
		var c: Dictionary = ctx_in
		ctx["retry"] = _yes(c.get("retry"))
		ctx["next_text"] = c["next_text"] if c.get("next_text") is String and String(c["next_text"]).strip_edges() != "" else "다음"
		var hv: Variant = c.get("hints", "show")
		ctx["hints"] = hv if hv is String and ["show", "tap", "none"].has(hv) else "show"
		ctx["autoplay"] = _yes(c.get("autoplay"))
	else:
		ctx = {"retry": false, "next_text": "다음", "hints": "show", "autoplay": false}
	var why: String = validate(ex_in)
	if why != "":
		_show_skipped(ex_in, why)
		return
	ex = (ex_in as Dictionary).duplicate(true)
	_footer_holder.visible = true
	var typ: String = String(ex["type"])
	_add_head()
	match typ:
		"teach_word":
			_build_teach_word()
		"teach_pattern":
			_build_teach_pattern()
		"recognize", "recall", "listen":
			if _has_options():
				_build_choice()
			else:
				_build_typed()
		"build":
			_build_tiles()
		"speak":
			_build_speak()
		"dialogue_script":
			_build_dialogue()
	_fit_all()
	if bool(ctx["autoplay"]) and ["hear_ko", "hear_en", "choose_ko", "type", "repeat"].has(String(ex.get("mode", ""))) and kind != "dialogue":
		play(false)


## 이 문제를 풀 필요가 없는 카드인가(소개 카드, 듣기 대화): answered 를 내지 않고 [다음] 만 있다.
static func is_info_card(ex_in: Variant) -> bool:
	if not (ex_in is Dictionary):
		return false
	var d: Dictionary = ex_in
	var t: Variant = d.get("type")
	if t == "teach_word" or t == "teach_pattern":
		return true
	if t == "dialogue_script":
		return not _has_you_line(d.get("lines"))
	return false


## 소리 재생: 문제의 `tts` 를 Tts.speak(tts, "en", slow) 로 읽는다. ex.speed 가 0.9 미만인 듣기 문제는 기본 재생도 느리게.
func play(slow: bool = false) -> void:
	_play(String(ex.get("tts", "")), slow or _default_slow())


func is_answered() -> bool:
	return state == "answered" or state == "skipped"


## 화면을 떠날 때·일시 정지: 소리 멈춤, 녹음·채점 취소.
func stop_all() -> void:
	Tts.stop()
	if drill != null and is_instance_valid(drill):
		drill.stop_all()


## 문제가 쓸 수 있는 모양인지: "" 이면 쓸 수 있다, 아니면 이유 글자(내부용, 화면에는 안 보인다).
static func validate(e: Variant) -> String:
	if not (e is Dictionary):
		return "not_dict"
	var d: Dictionary = e
	var t: Variant = d.get("type")
	if not (t is String) or not KNOWN_TYPES.has(t):
		return "bad_type"
	var mode: String = d["mode"] if d.get("mode") is String else ""
	match String(t):
		"teach_word":
			if _s(d.get("prompt")) == "":
				return "no_prompt"
		"teach_pattern":
			if _s(d.get("tpl")) == "" and _s(d.get("title_ko")) == "":
				return "no_tpl"
		"recognize":
			if not ["en_ko", "hear_ko", "hear_en"].has(mode):
				return "bad_mode"
			var r1: String = _check_options(d)
			if r1 != "":
				return r1
			if mode == "en_ko" and _s(d.get("prompt")) == "":
				return "no_prompt"
			if mode != "en_ko" and _s(d.get("tts")) == "":
				return "no_tts"
		"recall":
			if not ["ko_en_choice", "ko_en_type"].has(mode):
				return "bad_mode"
			if _s(d.get("prompt_ko")) == "":
				return "no_prompt"
			if mode == "ko_en_choice":
				return _check_options(d)
			return _check_accept(d)
		"listen":
			if not ["choose_ko", "type"].has(mode):
				return "bad_mode"
			if _s(d.get("tts")) == "":
				return "no_tts"
			if mode == "choose_ko":
				return _check_options(d)
			return _check_accept(d)
		"build":
			var a: Variant = d.get("answer")
			if not (a is Array) or (a as Array).is_empty() or (a as Array).size() > 20:
				return "no_answer"
			for x in a:
				if _s(x) == "":
					return "bad_tile"
			var extra: Variant = d.get("extra", [])
			if not (extra is Array):
				return "bad_extra"
			for y in extra:
				if _s(y) == "":
					return "bad_tile"
		"speak":
			if not ["repeat", "substitute", "answer", "intro"].has(mode):
				return "bad_mode"
			if mode == "repeat" or mode == "substitute":
				if _s(d.get("target")) == "":
					return "no_target"
			if mode == "substitute":
				if not (d.get("cue") is Dictionary) or not (d.get("accept") is Array) or (d["accept"] as Array).is_empty() or _s((d["accept"] as Array)[0]) == "":
					return "no_cue"
			if mode == "answer" or mode == "intro":
				var xa: Variant = d.get("expect_any")
				if not (xa is Array) or (xa as Array).is_empty() or _s((xa as Array)[0]) == "":
					return "no_expect"
				if _s(d.get("prompt_en")) == "":
					return "no_prompt"
		"dialogue_script":
			var ls: Variant = d.get("lines")
			if not (ls is Array) or (ls as Array).is_empty():
				return "no_lines"
			for ln in ls:
				if not (ln is Dictionary) or _s((ln as Dictionary).get("en")) == "":
					return "bad_line"
				if _yes((ln as Dictionary).get("you")):
					var acc: Variant = (ln as Dictionary).get("accept")
					if not (acc is Array) or (acc as Array).is_empty() or _s((acc as Array)[0]) == "":
						return "bad_line"
	return ""


# ================================================================== 도우미(글·검사)

## 깨진 데이터에서도 에러 없이: 진짜 true 일 때만 true.
static func _yes(v: Variant) -> bool:
	return v is bool and v


static func _s(v: Variant) -> String:
	return String(v) if v is String and String(v).strip_edges() != "" else ""


static func _as_index(v: Variant) -> int:
	if v is int:
		return int(v)
	if v is float:
		var f: float = v
		if not is_nan(f) and not is_inf(f) and f == floorf(f) and absf(f) < 1.0e9:
			return int(f)
	return -1


static func _check_options(d: Dictionary) -> String:
	var o: Variant = d.get("options")
	if not (o is Array) or (o as Array).size() < 2 or (o as Array).size() > 8:
		return "no_options"
	for x in o:
		if _s(x) == "":
			return "bad_option"
	var a: int = _as_index(d.get("answer"))
	if a < 0 or a >= (o as Array).size():
		return "answer_range"
	return ""


static func _check_accept(d: Dictionary) -> String:
	var a: Variant = d.get("accept")
	if not (a is Array) or (a as Array).is_empty():
		return "no_accept"
	for x in a:
		if _s(x) == "":
			return "bad_accept"
	return ""


static func _has_you_line(lines: Variant) -> bool:
	if not (lines is Array):
		return false
	for ln in lines:
		if ln is Dictionary and _yes((ln as Dictionary).get("you")):
			return true
	return false


func _has_options() -> bool:
	return ex.get("options") is Array


func _mode() -> String:
	return String(ex.get("mode", ""))


func _item_of(e: Dictionary) -> String:
	for k in ["item", "sent", "dialogue", "id"]:
		if e.get(k) is String:
			return String(e[k])
	return ""


## 맞는 영어 글(피드백에 보인다): 목표 문장 > 정답 목록 첫 항목 > 타일 > 낱말.
func _en_text() -> String:
	if _s(ex.get("target")) != "":
		return String(ex["target"])
	var acc: Variant = ex.get("accept")
	if acc is Array and not (acc as Array).is_empty() and (acc as Array)[0] is String and String((acc as Array)[0]) != "":
		return String((acc as Array)[0])
	if ex.get("answer") is Array:
		return " ".join(PackedStringArray(ex["answer"]))
	if _s(ex.get("prompt")) != "" and String(ex.get("type", "")) != "listen":
		return String(ex["prompt"])
	return String(ex.get("tts", ""))


func _default_slow() -> bool:
	var sp: Variant = ex.get("speed")
	return (sp is float or sp is int) and float(sp) < 0.9


func _play(text: String, slow: bool) -> void:
	if text.strip_edges() == "":
		return
	Tts.speak(text, LANG, slow)


func _accent() -> Color:
	return Pal.accent(LANG)


# ================================================================== 틀 만들기·지우기

func _reset() -> void:
	_leave_drill()
	Tts.stop()
	UI.clear(page.content)
	UI.clear(_footer_col.content)
	_footer_holder.visible = false
	ex = {}
	kind = ""
	state = "empty"
	result = {}
	tries = 0
	hint_used = false
	confirm_btn = null
	next_btn = null
	skip_btn = null
	continue_btn = null
	option_btns = []
	tile_btns = []
	chosen = []
	edit = null
	feedback = null
	picked = -1
	_answer_row = null
	_tiles_text = []
	_near_note = null
	_dlg_box = null
	_dlg_pos = 0
	_dlg_you = -1
	_dlg_ok = 0
	_dlg_total = 0
	_dlg_card = null
	_dlg_model = null
	_speak_text = ""
	page.scroll_vertical = 0


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


func _add(c: Control) -> Control:
	page.content.add_child(c)
	return c


func _label(text: String, variation: String = "", color: Variant = null) -> Label:
	var l: Label = UI.label(text, variation)
	if color is Color:
		l.add_theme_color_override("font_color", color)
	return l


func _btn(text: String, btn_name: String, btn_kind: String = "soft", accent: Variant = null) -> Button:
	var b: Button = UI.button(text, btn_kind, accent if accent is Color else _accent(), MIN_H)
	b.name = btn_name
	return b


func _fit_all() -> void:
	var h: float = maxf(MIN_H, Ds.touch_min() if Platform.is_phone() else 0.0)
	SpeakDrill.fit_touch(page, h)
	SpeakDrill.fit_touch(_footer_col, h)
	UI.fix_cjk(page)
	UI.fix_cjk(_footer_col)


func _add_head() -> void:
	var stage: String = String(ex.get("stage", ""))
	var title: String = String(STAGE_TITLES.get(stage, ""))
	if title == "":
		title = String(STAGE_TITLES.get(_stage_of_type(), ""))
	var row: HBoxContainer = UI.hbox(8)
	row.name = "Head"
	var e: Label = UI.label(title, "Eyebrow", false)
	e.name = "StageTitle"
	row.add_child(e)
	if bool(ctx.get("retry", false)):
		var chip: Control = UI.chip("한 번 더", Pal.WARN_ON, Pal.WARN_SOFT)
		chip.name = "RetryChip"
		row.add_child(chip)
	_add(row)


func _stage_of_type() -> String:
	match String(ex.get("type", "")):
		"teach_word", "teach_pattern":
			return "intro"
		"dialogue_script":
			return "dialogue"
	return String(ex.get("type", ""))


func _sound_row(text: String, play_text: String = "듣기", slow_text: String = "천천히 듣기") -> HFlowContainer:
	var row: HFlowContainer = UI.flow(8, 8)
	row.name = "SoundRow"
	var b1: Button = _btn(play_text, "PlayBtn", "soft")
	b1.pressed.connect(func() -> void: _play(text, _default_slow()))
	row.add_child(b1)
	var b2: Button = _btn(slow_text, "SlowBtn", "outline")
	b2.pressed.connect(func() -> void: _play(text, true))
	row.add_child(b2)
	return row


## 맨 아래 바를 [버튼들] 로 바꾼다.
func _footer_set(items: Array) -> void:
	for c in _footer_col.content.get_children():
		if c is RecorderWidget:
			_footer_col.content.remove_child(c) # 녹음 부품은 지워지지 않게 먼저 뗀다(_leave_drill 이 정리한다)
	UI.clear(_footer_col.content)
	for it in items:
		_footer_col.content.add_child(it)
	_footer_holder.visible = true
	_fit_all()


func _make_confirm(enabled: bool) -> void:
	confirm_btn = _btn("확인", "ConfirmBtn", "primary")
	confirm_btn.disabled = not enabled
	confirm_btn.pressed.connect(_on_confirm)
	_footer_set([confirm_btn])


func _show_next() -> void:
	next_btn = _btn(String(ctx.get("next_text", "다음")), "NextBtn", "primary")
	next_btn.pressed.connect(func() -> void: next_requested.emit())
	_footer_set([next_btn])


# ================================================================== 깨진 문제

func _show_skipped(ex_in: Variant, why: String) -> void:
	kind = "skipped"
	state = "skipped"
	_footer_holder.visible = true
	var l: Label = UI.label(SKIPPED_TEXT, "H3")
	l.name = "SkippedNote"
	_add(UI.tinted_panel(Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_S, 16, 12))
	var p: PanelContainer = page.content.get_child(page.content.get_child_count() - 1) as PanelContainer
	p.name = "SkippedBox"
	p.add_child(l)
	_show_next()
	var typ: String = ""
	var ident: String = ""
	if ex_in is Dictionary:
		var d: Dictionary = ex_in
		typ = String(d["type"]) if d.get("type") is String else ""
		ident = _item_of(d)
	result = {"id": String((ex_in as Dictionary).get("id", "")) if ex_in is Dictionary and (ex_in as Dictionary).get("id") is String else "",
		"type": typ, "mode": "", "item": ident, "ok": false, "near": false, "skipped": true, "gave_up": false,
		"answer": null, "tries": 0, "first_try": false, "hint_used": false, "self_rated": false, "reason": why}
	_fit_all()
	answered.emit(result) # 맨 마지막: 받는 쪽이 바로 다음 문제를 그려도 이 화면은 더 만지지 않는다


# ================================================================== 소개 카드

func _build_teach_word() -> void:
	kind = "info"
	state = "info"
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "TeachCard"
	card.body.add_child(_label(String(ex["prompt"]), "Big"))
	var meta: String = ""
	if _s(ex.get("ipa")) != "":
		meta = String(ex["ipa"])
	if _s(ex.get("pos")) != "":
		meta = (meta + "   " if meta != "" else "") + String(ex["pos"])
	if meta != "":
		card.body.add_child(_label(meta, "Muted"))
	if _s(ex.get("ko")) != "":
		card.body.add_child(_label(String(ex["ko"]), "H2"))
	if _s(ex.get("tts")) != "":
		card.body.add_child(_sound_row(String(ex["tts"])))
	_add(card)
	var e: Variant = ex.get("example")
	if e is Dictionary:
		_add(_example_card(e, "예문"))
	_show_next()


func _example_card(e: Dictionary, title: String) -> Control:
	var card: CardBox = UI.card("Card", 8)
	card.name = "ExampleCard"
	if title != "":
		card.body.add_child(_label(title, "Eyebrow"))
	card.body.add_child(_label(_s(e.get("en")), "Strong"))
	if _s(e.get("ko")) != "":
		card.body.add_child(_label(String(e["ko"]), "Muted"))
	if _s(e.get("tts")) != "":
		var t: String = String(e["tts"])
		var b: Button = _btn("예문 듣기", "ExamplePlayBtn", "soft")
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.pressed.connect(func() -> void: _play(t, false))
		card.body.add_child(b)
	return card


func _build_teach_pattern() -> void:
	kind = "info"
	state = "info"
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "TeachCard"
	if _s(ex.get("title_ko")) != "":
		card.body.add_child(_label(String(ex["title_ko"]), "Strong"))
	if _s(ex.get("tpl")) != "":
		card.body.add_child(_label(String(ex["tpl"]), "H1"))
	var g: Variant = ex.get("grammar_ko")
	if g is Array:
		for line in g:
			if _s(line) != "":
				card.body.add_child(_label(String(line), ""))
	elif _s(g) != "":
		card.body.add_child(_label(String(g), ""))
	_add(card)
	var exs: Variant = ex.get("examples")
	if exs is Array:
		var n: int = 0
		for e in exs:
			if e is Dictionary and _s((e as Dictionary).get("en")) != "":
				n += 1
				_add(_example_card(e, "예문 %d" % n if (exs as Array).size() > 1 else "예문"))
	_show_next()


# ================================================================== 고르기

func _build_choice() -> void:
	kind = "choice"
	state = "asking"
	var typ: String = String(ex["type"])
	var mode: String = _mode()
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "QuestionCard"
	var tts: String = String(ex.get("tts", ""))
	if typ == "recognize" and mode == "en_ko":
		card.body.add_child(_label("이 낱말의 뜻은?", "Eyebrow"))
		card.body.add_child(_label(String(ex["prompt"]), "Big"))
		if tts != "":
			card.body.add_child(_sound_row(tts))
	elif typ == "recognize" and mode == "hear_ko":
		card.body.add_child(_label("듣고 뜻을 골라요", "H3"))
		card.body.add_child(_sound_row(tts))
	elif typ == "recognize":
		card.body.add_child(_label("듣고 알맞은 영어를 골라요", "H3"))
		card.body.add_child(_sound_row(tts))
	elif typ == "recall":
		card.body.add_child(_label("영어로 알맞은 것을 골라요", "Eyebrow"))
		card.body.add_child(_label(String(ex["prompt_ko"]), "H1"))
	else: # listen choose_ko
		card.body.add_child(_label("듣고 뜻을 골라요", "H3"))
		card.body.add_child(_sound_row(tts))
	_add(card)
	var col: VBoxContainer = UI.vbox(10)
	col.name = "Options"
	var opts: Array = ex["options"]
	for i in opts.size():
		var b: Button = UI.option_row(String(opts[i]))
		b.name = "Opt%d" % i
		b.pressed.connect(_on_option.bind(i))
		col.add_child(b)
		option_btns.append(b)
	_add(col)
	_make_confirm(false)


func _on_option(i: int) -> void:
	if state != "asking":
		return
	picked = i
	for k in option_btns.size():
		UI.paint_option(option_btns[k], "picked" if k == i else "idle", _accent())
	if confirm_btn != null:
		confirm_btn.disabled = false


func _judge_choice() -> void:
	if picked < 0:
		return
	tries += 1
	var j: Dictionary = LessonBuilder.judge(ex, picked)
	var right: int = _as_index(ex["answer"])
	var ok: bool = bool(j.get("ok", false))
	for k in option_btns.size():
		var b: Button = option_btns[k]
		b.disabled = true
		if k == right:
			UI.paint_option(b, "right", _accent())
			b.text = String(b.text) + "   (정답)"
		elif k == picked:
			UI.paint_option(b, "wrong", _accent())
			b.text = String(b.text) + "   (내 답)"
	var opts: Array = ex["options"]
	var lines: Array = [_en_text()] if ok else ["정답   %s" % String(opts[right])] + _explain_choice(String(opts[right]))
	_finish(ok, false, picked, lines)


func _explain_choice(right_text: String) -> Array:
	var typ: String = String(ex["type"])
	var mode: String = _mode()
	var lines: Array = []
	if typ == "recognize" and mode == "en_ko":
		lines.append("뜻 풀이   %s = %s" % [String(ex["prompt"]), right_text])
	elif typ == "recognize" and mode == "hear_ko":
		lines.append("들은 말   %s = %s" % [String(ex.get("tts", "")), right_text])
	elif typ == "recognize":
		lines.append("들은 말   %s" % right_text)
	elif typ == "recall":
		lines.append("뜻 풀이   %s = %s" % [String(ex["prompt_ko"]), right_text])
	else:
		lines.append("들은 문장   %s" % String(ex.get("tts", "")))
		lines.append("뜻   %s" % right_text)
	return lines


# ================================================================== 쓰기

func _build_typed() -> void:
	kind = "type"
	state = "asking"
	var typ: String = String(ex["type"])
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "QuestionCard"
	if typ == "recall":
		card.body.add_child(_label("영어로 써 보세요", "Eyebrow"))
		card.body.add_child(_label(String(ex["prompt_ko"]), "H1"))
		if _s(ex.get("hint")) != "":
			var h: Label = _label("힌트   %s" % String(ex["hint"]), "Muted")
			h.name = "HintLabel"
			card.body.add_child(h)
	else: # listen type
		card.body.add_child(_label("들은 문장을 영어로 써요", "H3"))
		card.body.add_child(_sound_row(String(ex["tts"])))
	_add(card)
	edit = LineEdit.new()
	edit.name = "TypeEdit"
	edit.placeholder_text = "영어로 써 보세요"
	edit.max_length = MAX_TYPED
	edit.custom_minimum_size = Vector2(0, EDIT_H)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", UI.fs(20))
	edit.text_changed.connect(_on_text_changed)
	edit.text_submitted.connect(func(_t: String) -> void:
		if confirm_btn != null and not confirm_btn.disabled:
			confirm_btn.pressed.emit())
	_add(edit)
	_make_confirm(false)
	if is_inside_tree():
		edit.grab_focus.call_deferred()


func _on_text_changed(t: String) -> void:
	if confirm_btn != null and state != "answered":
		confirm_btn.disabled = t.strip_edges() == ""


func _judge_typed() -> void:
	var txt: String = edit.text
	if txt.strip_edges() == "":
		return
	tries += 1
	var j: Dictionary = LessonBuilder.judge(ex, txt)
	var ok: bool = bool(j.get("ok", false))
	var near: bool = bool(j.get("near", false))
	if not ok and near and tries < NEAR_TRIES:
		state = "near"
		_show_near()
		return
	edit.editable = false
	confirm_btn.disabled = true
	var lines: Array = ["정답   %s" % _en_text()]
	if String(ex["type"]) == "recall":
		lines.append("뜻 풀이   %s = %s" % [String(ex["prompt_ko"]), _en_text()])
	elif _s(ex.get("prompt_ko")) != "":
		lines.append("뜻   %s" % String(ex["prompt_ko"]))
	_finish(ok, near and not ok, txt, lines if not ok else [_en_text()])


func _show_near() -> void:
	if _near_note != null and is_instance_valid(_near_note):
		_near_note.queue_free()
		page.content.remove_child(_near_note)
	var p: PanelContainer = UI.tinted_panel(Pal.WARN_SOFT, Pal.WARN, 2, Ds.R_S, 16, 12)
	p.name = "NearNote"
	var v: VBoxContainer = UI.vbox(6)
	p.add_child(v)
	v.add_child(_label("거의 맞아요: %s" % _en_text(), "Strong", Pal.WARN_ON))
	v.add_child(_label("한 글자나 부호만 달라요. 한 번 더 써 보세요.", "Muted"))
	_add(p)
	_near_note = p
	edit.select_all()
	if is_inside_tree():
		edit.grab_focus.call_deferred()
	_fit_all()
	_reveal.call_deferred(p)


# ================================================================== 조립

func _build_tiles() -> void:
	kind = "build"
	state = "asking"
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "QuestionCard"
	card.body.add_child(_label("영어 문장을 만들어요", "Eyebrow"))
	card.body.add_child(_label(_s(ex.get("ko")), "H2"))
	_add(card)
	var area: PanelContainer = UI.tinted_panel(Pal.SUNK, Pal.LINE, 1, Ds.R_S, 12, 10)
	area.name = "AnswerArea"
	area.custom_minimum_size.y = maxf(EDIT_H, Ds.touch_min() if Platform.is_phone() else 0.0)
	_answer_row = UI.flow(8, 8)
	_answer_row.name = "AnswerRow"
	area.add_child(_answer_row)
	_add(area)
	var texts: Array = []
	for t in ex["answer"]:
		texts.append(String(t))
	var extra: Variant = ex.get("extra", [])
	if extra is Array:
		for t in extra:
			texts.append(String(t))
	_tiles_text = _shuffled(texts, String(ex.get("id", "")), (ex["answer"] as Array).size())
	var pool: HFlowContainer = UI.flow(8, 8)
	pool.name = "TilePool"
	for i in _tiles_text.size():
		var b: Button = UI.tile(String(_tiles_text[i]))
		b.name = "Tile%d" % i
		b.pressed.connect(_on_tile.bind(i))
		pool.add_child(b)
		tile_btns.append(b)
	_add(pool)
	_make_confirm(false)
	_refresh_answer_row()


## 시드가 같으면 같은 순서로 섞는다. 정답 순서 그대로 나오면 한 칸 돌린다.
func _shuffled(texts: Array, seed_text: String, n_answer: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text) + texts.size()
	var a: Array = texts.duplicate()
	for i in range(a.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
	if a.size() > 1 and a.slice(0, n_answer) == texts.slice(0, n_answer) and n_answer == a.size():
		a.append(a.pop_front())
	return a


func _on_tile(i: int) -> void:
	if state != "asking" or chosen.has(i):
		return
	chosen.append(i)
	(tile_btns[i] as Button).disabled = true
	(tile_btns[i] as Button).modulate.a = 0.35
	_refresh_answer_row()


func _on_chosen_tile(pos: int) -> void:
	if state != "asking" or pos < 0 or pos >= chosen.size():
		return
	var i: int = int(chosen[pos])
	chosen.remove_at(pos)
	(tile_btns[i] as Button).disabled = false
	(tile_btns[i] as Button).modulate.a = 1.0
	_refresh_answer_row()


func _refresh_answer_row() -> void:
	UI.clear(_answer_row)
	if chosen.is_empty():
		var hint: Label = UI.label("아래 낱말을 눌러 문장을 만들어요", "Muted", false)
		hint.name = "AnswerHint"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_answer_row.add_child(hint)
	for pos in chosen.size():
		var b: Button = UI.tile(String(_tiles_text[int(chosen[pos])]))
		b.name = "Chosen%d" % pos
		b.pressed.connect(_on_chosen_tile.bind(pos))
		_answer_row.add_child(b)
	if confirm_btn != null and state == "asking":
		confirm_btn.disabled = chosen.is_empty()
	_fit_all()


func _chosen_texts() -> Array:
	var out: Array = []
	for i in chosen:
		out.append(String(_tiles_text[int(i)]))
	return out


func _judge_tiles() -> void:
	if chosen.is_empty():
		return
	tries += 1
	var mine: Array = _chosen_texts()
	var j: Dictionary = LessonBuilder.judge(ex, mine)
	var ok: bool = bool(j.get("ok", false))
	for b in tile_btns:
		(b as Button).disabled = true
	for c in _answer_row.get_children():
		if c is Button:
			(c as Button).disabled = true
	var lines: Array = []
	if ok:
		lines.append(" ".join(PackedStringArray(mine)))
	else:
		lines.append("정답   %s" % " ".join(PackedStringArray(ex["answer"])))
		if _s(ex.get("ko")) != "":
			lines.append("뜻   %s" % String(ex["ko"]))
	_finish(ok, false, mine, lines)


# ================================================================== 확인 버튼

func _on_confirm() -> void:
	if state != "asking" and state != "near":
		return
	match kind:
		"choice":
			_judge_choice()
		"type":
			_judge_typed()
		"build":
			_judge_tiles()


## 채점 뒤 공통: 피드백 상자(글 + 표시 + 다시 듣기), 아래 바를 [다음] 으로, answered 신호.
func _finish(ok: bool, near: bool, answer: Variant, lines: Array, extra_result: Dictionary = {}) -> void:
	state = "answered"
	if _near_note != null and is_instance_valid(_near_note):
		_near_note.queue_free()
		page.content.remove_child(_near_note)
		_near_note = null
	feedback = _make_feedback(ok, lines)
	_add(feedback)
	result = {"id": String(ex.get("id", "")), "type": String(ex["type"]), "mode": _mode(), "item": _item_of(ex), "ok": ok, "near": near,
		"skipped": false, "gave_up": false, "answer": answer, "tries": tries, "first_try": ok and tries <= 1, "hint_used": hint_used, "self_rated": false}
	result.merge(extra_result, true)
	_show_next()
	_reveal.call_deferred(feedback)
	answered.emit(result)


func _make_feedback(ok: bool, lines: Array) -> Control:
	var bg: Color = Pal.OK_SOFT if ok else Pal.BAD_SOFT
	var edge: Color = Pal.OK if ok else Pal.BAD
	var ink: Color = Pal.OK_ON if ok else Pal.BAD_ON
	var p: PanelContainer = UI.tinted_panel(bg, edge, 2, Ds.R_S, 16, 12)
	p.name = "Feedback"
	p.set_meta("ok", ok)
	var v: VBoxContainer = UI.vbox(8)
	p.add_child(v)
	var head: HBoxContainer = UI.hbox(8)
	var g: GlyphIcon = GlyphIcon.new("check" if ok else "close", 22.0, ink)
	g.name = "FeedbackMark"
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(g)
	var t: Label = UI.label("맞았어요" if ok else "틀렸어요", "H3", false)
	t.name = "FeedbackTitle"
	t.add_theme_color_override("font_color", ink)
	head.add_child(t)
	v.add_child(head)
	for ln in lines:
		var l: Label = _label(String(ln), "Strong" if ln == lines[0] else "")
		l.name = "FeedbackLine"
		v.add_child(l)
	var rt: String = String(ex.get("tts", ""))
	if rt.strip_edges() != "" and kind != "dialogue":
		var rb: Button = _btn("영어 문장 다시 듣기", "ReplayBtn", "soft")
		rb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		rb.pressed.connect(func() -> void: _play(rt, false))
		v.add_child(rb)
	return p


func _reveal(c: Control) -> void:
	await get_tree().process_frame
	if is_instance_valid(c) and c.is_inside_tree() and is_instance_valid(page):
		page.ensure_control_visible(c)


# ================================================================== 말하기

func _build_speak() -> void:
	kind = "speak"
	state = "asking"
	var mode: String = _mode()
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "QuestionCard"
	var score_text: String = ""
	var ko: String = _s(ex.get("ko"))
	match mode:
		"repeat":
			card.body.add_child(_label("듣고 따라 말해요", "Eyebrow"))
			card.body.add_child(_label(String(ex["target"]), "H1"))
			score_text = String(ex["target"])
		"substitute":
			var cue: Dictionary = ex["cue"]
			card.body.add_child(_label("바꿔 말해요", "Eyebrow"))
			card.body.add_child(_label(String(ex["target"]), "H2"))
			var with_ko: String = _s(cue.get("with_ko"))
			var cue_text: String = "%s 대신 %s" % [_s(cue.get("slot")), _s(cue.get("with"))]
			if with_ko != "":
				cue_text += " (%s)" % with_ko
			cue_text += " (으)로 바꿔 말해요"
			var cl: Label = _label(cue_text, "Strong", _accent())
			cl.name = "CueLabel"
			card.body.add_child(cl)
			score_text = String((ex["accept"] as Array)[0])
		"answer":
			card.body.add_child(_label("질문에 영어로 대답해요", "Eyebrow"))
			card.body.add_child(_label(String(ex["prompt_en"]), "H2"))
			score_text = String((ex["expect_any"] as Array)[0])
		"intro":
			card.body.add_child(_label("영어로 자기소개를 해요", "Eyebrow"))
			card.body.add_child(_label(String(ex["prompt_en"]), "H2"))
			score_text = String((ex["expect_any"] as Array)[0])
	if ko != "":
		card.body.add_child(_label(ko, "Muted"))
	if _s(ex.get("tts")) != "":
		card.body.add_child(_sound_row(String(ex["tts"])))
	_add(card)
	_speak_text = score_text
	_start_drill(score_text, ko)
	_speak_footer()


func _start_drill(score_text: String, ko: String) -> void:
	if drill != null:
		_leave_drill()
	drill = SpeakDrill.new(LANG, "course")
	drill.show_prosody = false
	var rec: RecorderWidget = drill.make_recorder("말해 보기")
	rec.wide = Platform.is_phone()
	drill.scored.connect(_on_drill_scored)
	_add(drill)
	drill.set_target(score_text, "", ko)


func _speak_footer() -> void:
	var items: Array = []
	if drill != null and drill.recorder != null:
		items.append(drill.recorder)
	skip_btn = _btn("말하기 어려워요", "SkipBtn", "outline")
	skip_btn.pressed.connect(_on_give_up)
	items.append(skip_btn)
	_footer_set(items)


## 말하기 채점 결과를 맞고 틀림으로: 자가 평가는 "잘했어요" 면 맞음, 아니면 LessonBuilder.judge(전사)이거나 통과 점수.
func _evaluate_speak(e: Dictionary, res: Dictionary) -> Dictionary:
	var out: Dictionary = {"ok": false, "near": false, "self_rated": false, "transcript": ""}
	if SelfRatePanel.is_self_rated(res):
		out["ok"] = true
		out["self_rated"] = true
		return out
	var transcript: String = String(res.get("transcript", ""))
	out["transcript"] = transcript
	var j: Dictionary = LessonBuilder.judge(e, transcript)
	var mode: String = String(e.get("mode", ""))
	var score: float = float(res.get("score", 0.0)) if (res.get("score") is float or res.get("score") is int) else 0.0
	var passed: bool = bool(j.get("ok", false))
	if not passed and (mode == "repeat" or mode == "substitute") and score >= float(PASS_SCORE):
		passed = true
	out["ok"] = passed
	out["near"] = bool(j.get("near", false)) and not passed
	return out


func _on_drill_scored(res: Dictionary, _target: String) -> void:
	if kind == "dialogue":
		_dlg_scored(res)
		return
	if state != "asking":
		return
	tries += 1
	var ev: Dictionary = _evaluate_speak(ex, res)
	var lines: Array = []
	var mode: String = _mode()
	if bool(ev["ok"]):
		if bool(ev["self_rated"]):
			lines.append("스스로 '잘했어요'로 평가했어요")
		elif mode == "answer" or mode == "intro":
			lines.append("말한 내용   %s" % String(ev["transcript"]))
		else:
			lines.append(_en_text())
	else:
		if mode == "answer" or mode == "intro":
			var shown: Array = []
			for e in ex["expect_any"]:
				if shown.size() < 3 and e is String:
					shown.append(String(e))
			lines.append("이렇게 말해 보세요   %s" % "  /  ".join(PackedStringArray(shown)))
		else:
			lines.append("정답   %s" % _en_text())
		if _s(ex.get("ko")) != "":
			lines.append("뜻   %s" % String(ex["ko"]))
		if bool(ev["near"]):
			lines.append("거의 맞아요. 한 번 더 또박또박 말해 보세요.")
	_finish_speak(bool(ev["ok"]), bool(ev["near"]), String(ev["transcript"]), lines, bool(ev["self_rated"]))


func _finish_speak(ok: bool, near: bool, answer: Variant, lines: Array, self_rated: bool, gave_up: bool = false) -> void:
	if drill != null and is_instance_valid(drill) and drill.recorder != null and is_instance_valid(drill.recorder):
		drill.recorder.stop_if_recording()
	_finish(ok, near, answer, lines, {"self_rated": self_rated, "gave_up": gave_up})


func _on_give_up() -> void:
	if state != "asking":
		return
	if kind == "dialogue":
		_dlg_give_up()
		return
	tries += 1
	var lines: Array = []
	var mode: String = _mode()
	if mode == "answer" or mode == "intro":
		lines.append("이렇게 말해 보세요   %s" % String((ex["expect_any"] as Array)[0]))
	else:
		lines.append("정답   %s" % _en_text())
	if _s(ex.get("ko")) != "":
		lines.append("뜻   %s" % String(ex["ko"]))
	if drill != null and is_instance_valid(drill):
		drill.stop_all()
	_finish_speak(false, false, "", lines, false, true)


# ================================================================== 대본 대화

func _build_dialogue() -> void:
	var lines: Array = ex["lines"]
	_dlg_total = 0
	for ln in lines:
		if _yes((ln as Dictionary).get("you")):
			_dlg_total += 1
	_dlg_box = UI.vbox(10)
	_dlg_box.name = "DialogueLines"
	if _dlg_total == 0:
		kind = "info"
		state = "info"
		var card: CardBox = UI.card("BigCard", 8)
		card.body.add_child(_label("대화를 들어 봐요", "H3"))
		_add(card)
		for ln in lines:
			_dlg_box.add_child(_line_card(ln as Dictionary, false))
		_add(_dlg_box)
		_show_next()
		return
	kind = "dialogue"
	state = "asking"
	var card2: CardBox = UI.card("BigCard", 8)
	card2.body.add_child(_label("대화에서 내 차례를 말해요", "H3"))
	card2.body.add_child(_label("상대 말은 듣고, 내 차례가 되면 말해 보세요.", "Muted"))
	_add(card2)
	_add(_dlg_box)
	_start_drill("", "")
	_dlg_pos = 0
	_dlg_advance()


## 한 줄 카드: 말하는 사람 + 영어 + 한국어 + 듣기. 내 줄은 틀 색이 다르다.
func _line_card(ln: Dictionary, mine: bool) -> Control:
	var p: PanelContainer = UI.tinted_panel(Pal.EN_SOFT if mine else Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_S, 14, 10)
	p.name = "LineCard"
	p.set_meta("line_card", true) # 같은 이름이 여럿이라 이름 대신 표시로 센다
	var v: VBoxContainer = UI.vbox(6)
	p.add_child(v)
	var who: String = _s(ln.get("s"))
	if who != "":
		v.add_child(_label(("나 (%s)" % who) if mine else who, "Eyebrow"))
	v.add_child(_label(String(ln["en"]), "Strong"))
	if _s(ln.get("ko")) != "":
		v.add_child(_label(String(ln["ko"]), "Muted"))
	var t: String = _s(ln.get("tts"))
	if t != "":
		var b: Button = _btn("듣기", "LinePlayBtn", "soft")
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.pressed.connect(func() -> void: _play(t, false))
		v.add_child(b)
	return p


## 다음 내 줄 앞까지 상대 줄을 보여 주고, 내 줄이 오면 내 차례 카드 + 말하기 부품을 연다. 줄이 끝났으면 대화를 마친다.
func _dlg_advance() -> void:
	var lines: Array = ex["lines"]
	_dlg_you = -1
	while _dlg_pos < lines.size():
		var ln: Dictionary = lines[_dlg_pos]
		if _yes(ln.get("you")):
			_dlg_you = _dlg_pos
			_dlg_pos += 1
			break
		_dlg_box.add_child(_line_card(ln, false))
		_dlg_pos += 1
	if _dlg_you < 0:
		_dlg_finish()
		return
	_dlg_open_turn(lines[_dlg_you])
	var accept0: String = String((lines[_dlg_you]["accept"] as Array)[0])
	drill.set_target(accept0, "", _s(lines[_dlg_you].get("ko")))
	if drill.get_parent() != null:
		drill.get_parent().move_child(drill, -1)
	state = "asking"
	continue_btn = null
	_speak_footer()
	_reveal.call_deferred(_dlg_card)


func _dlg_open_turn(ln: Dictionary) -> void:
	_dlg_card = UI.card("Card", 8)
	_dlg_card.name = "TurnCard"
	_dlg_card.set_meta("turn_card", true)
	_dlg_card.body.add_child(_label("내 차례", "Eyebrow"))
	var hints: String = String(ctx.get("hints", "show"))
	var hint_lbl: Label = _label("힌트   %s" % _s(ln.get("hint_ko", ln.get("ko", ""))), "Strong")
	hint_lbl.name = "HintKo"
	hint_lbl.visible = hints == "show"
	_dlg_card.body.add_child(hint_lbl)
	var model: Label = _label("모범 답   %s" % String((ln["accept"] as Array)[0]), "Strong", _accent())
	model.name = "ModelEn"
	model.visible = false
	_dlg_model = model
	_dlg_card.body.add_child(model)
	var row: HFlowContainer = UI.flow(8, 8)
	if hints != "show":
		var hb: Button = _btn("힌트 보기", "HintBtn", "outline")
		hb.pressed.connect(func() -> void:
			hint_lbl.visible = true
			hint_used = true
			hb.visible = false)
		row.add_child(hb)
	var mb: Button = _btn("모범 답 보기", "ModelBtn", "outline")
	mb.pressed.connect(func() -> void:
		hint_lbl.visible = true
		model.visible = true
		hint_used = true
		mb.visible = false)
	row.add_child(mb)
	_dlg_card.body.add_child(row)
	_dlg_box.add_child(_dlg_card)


func _dlg_line_ex(idx: int) -> Dictionary:
	var ln: Dictionary = (ex["lines"] as Array)[idx]
	return {"type": "speak", "mode": "repeat", "target": String(ln["en"]), "say": _s(ln.get("say")), "accept": ln.get("accept", [])}


func _dlg_scored(res: Dictionary) -> void:
	if state != "asking" or _dlg_you < 0:
		return
	var ev: Dictionary = _evaluate_speak(_dlg_line_ex(_dlg_you), res)
	_dlg_line_done(bool(ev["ok"]), bool(ev["self_rated"]), String(ev["transcript"]))


func _dlg_give_up() -> void:
	if state != "asking" or _dlg_you < 0:
		return
	if drill != null and is_instance_valid(drill):
		drill.stop_all()
	_dlg_line_done(false, false, "", true)


func _dlg_line_done(ok: bool, self_rated: bool, transcript: String, gave_up: bool = false) -> void:
	tries += 1
	if ok:
		_dlg_ok += 1
	state = "turn_done" # 이 줄은 끝났다: 같은 줄에 다시 채점이 들어와도 한 번만 센다(answered 는 대화 끝에 한 번)
	var fb: Label = _label("맞았어요" if ok else "틀렸어요", "Strong", Pal.OK_ON if ok else Pal.BAD_ON)
	fb.name = "LineFeedback"
	_dlg_card.body.add_child(fb)
	_dlg_model.visible = true
	var more: bool = false
	var lines: Array = ex["lines"]
	for i in range(_dlg_pos, lines.size()):
		if _yes((lines[i] as Dictionary).get("you")):
			more = true
	_last_line = {"ok": ok, "self_rated": self_rated, "gave_up": gave_up, "transcript": transcript}
	if drill != null and is_instance_valid(drill) and drill.recorder != null and is_instance_valid(drill.recorder):
		drill.recorder.stop_if_recording()
	if more:
		continue_btn = _btn("이어서", "ContinueBtn", "primary")
		continue_btn.pressed.connect(_on_continue)
		_footer_set([continue_btn])
	else:
		_dlg_finish()


func _on_continue() -> void:
	if state != "turn_done" or kind != "dialogue":
		return
	_dlg_advance()


func _dlg_finish() -> void:
	var lines: Array = ex["lines"]
	while _dlg_pos < lines.size():
		_dlg_box.add_child(_line_card(lines[_dlg_pos] as Dictionary, false))
		_dlg_pos += 1
	if drill != null and is_instance_valid(drill):
		drill.stop_all()
		if drill.recorder != null and is_instance_valid(drill.recorder) and drill.recorder.get_parent() != null:
			drill.recorder.get_parent().remove_child(drill.recorder)
	var ok: bool = _dlg_ok >= _dlg_total
	state = "answered"
	var msg: Array = ["내 차례를 모두 잘 말했어요" if ok else "다시 말해 볼 차례가 있었어요. 이 대화는 나중에 한 번 더 나와요."]
	feedback = _make_feedback(ok, msg)
	_add(feedback)
	result = {"id": String(ex.get("id", "")), "type": "dialogue_script", "mode": _mode(), "item": _item_of(ex), "ok": ok, "near": false,
		"skipped": false, "gave_up": bool(_last_line.get("gave_up", false)), "answer": null, "tries": tries, "first_try": ok,
		"hint_used": hint_used, "self_rated": bool(_last_line.get("self_rated", false)), "lines_total": _dlg_total, "lines_ok": _dlg_ok}
	_show_next()
	_reveal.call_deferred(feedback)
	answered.emit(result)
