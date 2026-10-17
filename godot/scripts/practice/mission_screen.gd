class_name MissionScreen
extends Control
## 롤플레이 미션 화면 (영어). 목록 -> 설명 -> 대화 -> 결과.
## 계약: 설계 8.3 (신호 closed, open(lang, args), 선택 on_hide()). 하위 단계로 돌아가는 go_back() -> bool.
##
## AI 호출: 말할 때마다 /missions/check (규칙, AI 없음) 와 /chat 을 동시에 보낸다. 체크 결과가 항상 먼저 반영된다.
## 끝나면 /feedback 1번. 규칙으로 못 잡은 목표는 직접 체크하거나 /missions/judge 로 AI 에게 다시 묻는다.
## AI 를 못 쓰면 대본 모드: 상대 대사는 데이터의 script 줄, 내 답은 규칙 + 문장 유사도로 확인 (AI 호출 0회).
## 녹음은 RecorderWidget, 재생은 Tts 공개 함수만 쓴다. 요청 응답은 늘 일련번호로 확인해 늦게 온 것을 버린다.

signal closed

const WIDE_MIN := 700.0         ## 이 폭 이상(폰이 아닐 때)이면 목표가 오른쪽 패널
const SIDE_W := 300.0
const JA_NOTE := "일본어 미션은 다음 버전에서 만들 예정이에요. 영어로 바꿔서 연습해 보세요."
const OLD_SERVER := "이 PC 프로그램은 미션을 아직 지원하지 않아요. PC 프로그램을 최신 버전으로 업데이트해 주세요."
const EMPTY_NOTE := "지금 연습할 수 있는 미션이 없어요. PC 프로그램이 최신 버전인지 확인해 주세요."

var lang: String = "en"
var status: String = "idle"   ## idle | loading | list | brief | talk | wait | result
var mode: String = "ai"       ## ai | script
var missions: Array = []
var list_note: String = ""
var list_error: bool = false
var mission: Dictionary = {}
var msgs: Array = []          ## {role: ai|me|note|model, ...}
var done: Dictionary = {}     ## 목표 id -> MissionLogic.BY_RULE | BY_MANUAL | BY_AI
var turns: int = 0            ## 학습자 턴 (대본 모드에서는 통과/넘긴 줄 수)
var err: String = ""
var chat_failed: bool = false
var script_state: Dictionary = {}
var conv_id: String = ""
var hints_open: bool = false
var goals_open: bool = false  ## 폰: 목표 패널 펼침
var ko_open: Dictionary = {}
var fb: Dictionary = {}
var fb_state: String = "none" ## none | wait | ok | fail
var fb_error: String = ""
var fb_added: int = 0
var judge_busy: bool = false
var judge_note: String = ""
var leave_confirm: bool = false
var stt_busy: bool = false

## 시험용 갈아끼우기. 비어 있으면 실제 Api 를 쓴다.
var http: Callable = Callable()       ## (method: String, path: String, body: Variant, timeout: float) -> ApiCall 같은 객체(wait/cancel)
var log_hook: Callable = Callable()   ## (kind: String, data: Dictionary) -> void, StudyLog 호출을 기록
var phone_mode: int = -1              ## -1 자동(Platform.is_phone), 0 PC, 1 폰
var llm_override: int = -1            ## -1 자동(Backend), 0 AI 가능, 1 AI 없음

var _awarded: Dictionary = {}
var _serial: int = 0
var _fb_serial: int = 0
var _judge_serial: int = 0
var _list_serial: int = 0
var _chat_req = null
var _fb_req = null
var _pending: Array = []
var _open_args: Array = []
var _wide: bool = false
var _msg_w: float = -1.0

var _root: VBoxContainer
var _head: ColumnBox
var _back_btn: Button
var _title: Label
var _end_btn: Button
var _stack: Control
var _list_page: PageScroll
var _brief_page: PageScroll
var _result_page: PageScroll
var _chat_root: VBoxContainer
var _goal_bar: PanelContainer
var _goal_bar_box: VBoxContainer
var _chat_body: HBoxContainer
var _msg_scroll: PageScroll
var _side_wrap: MarginContainer
var _side_box: VBoxContainer
var _aux: VBoxContainer
var _comp_row: HBoxContainer
var _mic_row: HBoxContainer
var _input: LineEdit
var _send: Button
var _mic: RecorderWidget
var _status_label: Label


# ---------------------------------------------------------------- 계약 (8.3)

func open(l: String, args: Dictionary = {}) -> void:
	if not is_node_ready():
		_open_args = [l, args]
		return
	lang = l
	_reset_run()
	var want: String = str(args.get("mission_id", ""))
	_load_list(want)


func on_hide() -> void:
	if _mic != null and is_instance_valid(_mic):
		_mic.stop_if_recording()
	Tts.stop()


## 한 단계 위로. 처리했으면 true, 맨 위(목록)라서 화면을 닫아야 하면 false.
func go_back() -> bool:
	match status:
		"talk", "wait":
			if _me_count() > 0 and not leave_confirm:
				leave_confirm = true
				_render_aux()
				return true
			_abandon()
			return true
		"brief", "result":
			_abandon()
			return true
	return false


# ---------------------------------------------------------------- 만들기

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true

	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)

	_head = ColumnBox.new()
	_head.max_width = 1100.0
	_head.min_pad = 12
	_head.set_padding(8, 6)
	var hrow := UI.hbox(8)
	_back_btn = UI.button("← 연습", "flat", Pal.INK, 44)
	_back_btn.pressed.connect(_on_back_pressed)
	hrow.add_child(_back_btn)
	_title = UI.label("롤플레이 미션", "Strong", true)
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hrow.add_child(_title)
	_end_btn = UI.button("끝내기", "outline", Pal.EN, 44)
	_end_btn.pressed.connect(_on_end_pressed)
	hrow.add_child(_end_btn)
	_head.content.add_child(hrow)
	_root.add_child(_head)

	_stack = Control.new()
	_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stack.clip_contents = true
	_root.add_child(_stack)
	_list_page = _page(720.0)
	_brief_page = _page(720.0)
	_result_page = _page(720.0)
	_build_chat_root()

	Store.prefs_changed.connect(func() -> void:
		if status == "talk" or status == "wait":
			_render_msgs())
	_apply_layout(true)
	_update_pages()
	if not _open_args.is_empty():
		var a: Array = _open_args
		_open_args = []
		open(a[0], a[1])


func _exit_tree() -> void:
	_serial += 1
	_fb_serial += 1
	_judge_serial += 1
	_list_serial += 1
	_cancel_all()


func _page(max_w: float) -> PageScroll:
	var p := PageScroll.new(max_w)
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.column.min_pad = 12
	_stack.add_child(p)
	return p


func _build_chat_root() -> void:
	_chat_root = VBoxContainer.new()
	_chat_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_chat_root.add_theme_constant_override("separation", 0)
	_stack.add_child(_chat_root)

	# 폰: 목표 패널은 접힌 한 줄
	_goal_bar = PanelContainer.new()
	_goal_bar.add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 12, 4))
	_goal_bar_box = UI.vbox(6)
	_goal_bar.add_child(_goal_bar_box)
	_chat_root.add_child(_goal_bar)

	_chat_body = HBoxContainer.new()
	_chat_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_body.add_theme_constant_override("separation", 0)
	_chat_root.add_child(_chat_body)
	_msg_scroll = PageScroll.new(820.0)
	_msg_scroll.column.min_pad = 12
	_msg_scroll.column.pad_top = 12
	_msg_scroll.content.add_theme_constant_override("separation", 12)
	_msg_scroll.resized.connect(_on_msg_resized)
	_chat_body.add_child(_msg_scroll)
	# PC: 오른쪽 목표 패널
	_side_wrap = MarginContainer.new()
	_side_wrap.custom_minimum_size = Vector2(SIDE_W + 16.0, 0)
	_side_wrap.add_theme_constant_override("margin_right", 16)
	_side_wrap.add_theme_constant_override("margin_top", 12)
	_side_wrap.add_theme_constant_override("margin_bottom", 12)
	var side_panel := PanelContainer.new()
	side_panel.add_theme_stylebox_override("panel", UI.style(Pal.SURFACE, Pal.LINE, 1, 12, 12, 12))
	var side_scroll := ScrollContainer.new()
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_box = UI.vbox(8)
	_side_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.add_child(_side_box)
	side_panel.add_child(side_scroll)
	_side_wrap.add_child(side_panel)
	_chat_body.add_child(_side_wrap)

	# 아래 고정 바
	var bottom := PanelContainer.new()
	bottom.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
	_chat_root.add_child(bottom)
	var bcol := ColumnBox.new()
	bcol.max_width = 820.0
	bcol.min_pad = 12
	bcol.set_padding(8, 8)
	bottom.add_child(bcol)
	var b: VBoxContainer = bcol.content
	b.add_theme_constant_override("separation", 6)
	_aux = UI.vbox(6)
	b.add_child(_aux)
	_comp_row = UI.hbox(8)
	_input = LineEdit.new()
	_input.placeholder_text = "영어로 말하거나 입력하기"
	_input.max_length = MissionLogic.MAX_TEXT
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, 48)
	_input.text_submitted.connect(func(_t: String) -> void: _send_message())
	_comp_row.add_child(_input)
	_send = UI.button("보내기", "primary", Pal.EN, 48)
	_send.pressed.connect(_send_message)
	_comp_row.add_child(_send)
	b.add_child(_comp_row)
	_mic_row = UI.hbox(10)
	_mic = RecorderWidget.new(false, Pal.EN, false)
	_mic.idle_text = "말하기"
	_mic.recorded.connect(_on_recorded)
	_mic_row.add_child(_mic)
	_status_label = UI.label("", "Small", true)
	_mic_row.add_child(_status_label)
	b.add_child(_mic_row)
	var tg := UI.flow(14, 0)
	for spec in [["AI 말 자동 읽기", "auto_speak"], ["말하면 바로 보내기", "auto_send"]]:
		var t := UI.pref_toggle(spec[0], spec[1])
		t.custom_minimum_size.y = 44
		tg.add_child(t)
	b.add_child(tg)


# ---------------------------------------------------------------- 요청

func _req(method: String, path: String, body: Variant, timeout: float) -> Variant:
	if http.is_valid():
		return http.call(method, path, body, timeout)
	if method == "GET":
		return Api.get_json(path, timeout, false)
	return Api.post_json(path, body as Dictionary, timeout, false)


func _wait(req: Variant) -> Dictionary:
	_pending.append(req)
	var res: Dictionary = await req.wait()
	_pending.erase(req)
	return res


func _cancel_all() -> void:
	for r in _pending.duplicate():
		r.cancel()
	_pending.clear()
	_chat_req = null
	_fb_req = null


func _llm_down() -> bool:
	if llm_override >= 0:
		return llm_override == 1
	return Backend.llm_missing()


func _is_phone() -> bool:
	if phone_mode >= 0:
		return phone_mode == 1
	return Platform.is_phone()


func _is_wide() -> bool:
	return not _is_phone() and size.x >= WIDE_MIN


func _stage() -> int:
	return clampi(int(mission.get("min_stage", 1)), 1, 4)


func _goals() -> Array:
	return mission.get("goals", []) as Array


func _script() -> Array:
	return mission.get("script", []) as Array


func _mission_id() -> String:
	return str(mission.get("id", ""))


func _me_count() -> int:
	var n := 0
	for m in msgs:
		if (m as Dictionary)["role"] == "me":
			n += 1
	return n


func _who() -> String:
	var p: String = str((mission.get("scenario", {}) as Dictionary).get("persona", "")).split(",")[0].strip_edges()
	if p == "" or p.length() > 20:
		return "AI"
	return p


func _goal_label(id: String) -> String:
	for g in _goals():
		if str((g as Dictionary)["id"]) == id:
			return str((g as Dictionary)["label_ko"])
	return id


func _history() -> Array:
	var h: Array = []
	for m in msgs:
		var d: Dictionary = m
		if d["role"] == "ai":
			h.append({"role": "ai", "text": str(d["reply"])})
		elif d["role"] == "me":
			h.append({"role": "me", "text": str(d["text"])})
	return h.slice(maxi(0, h.size() - 24))


func _me_texts() -> Array:
	var out: Array = []
	for m in msgs:
		if (m as Dictionary)["role"] == "me":
			out.append(str((m as Dictionary)["text"]))
	return out


# ---------------------------------------------------------------- 상태 전환

func _reset_run() -> void:
	_serial += 1
	_fb_serial += 1
	_judge_serial += 1
	_cancel_all()
	mission = {}
	msgs = []
	done = {}
	turns = 0
	err = ""
	chat_failed = false
	script_state = {}
	ko_open = {}
	fb = {}
	fb_state = "none"
	fb_error = ""
	fb_added = 0
	judge_busy = false
	judge_note = ""
	leave_confirm = false
	stt_busy = false
	hints_open = false
	goals_open = false
	_awarded = {}
	if _input != null:
		_input.text = ""


func _abandon() -> void:
	_reset_run()
	Tts.stop()
	if _mic != null:
		_mic.stop_if_recording()
	status = "list"
	_update_pages()
	_render_list()


func _on_back_pressed() -> void:
	if not go_back():
		closed.emit()


func _on_end_pressed() -> void:
	if status == "talk" and _me_count() > 0:
		_finish()


func _update_pages() -> void:
	if _list_page == null:
		return
	_list_page.visible = status == "loading" or status == "list" or status == "idle"
	_brief_page.visible = status == "brief"
	_chat_root.visible = status == "talk" or status == "wait"
	_result_page.visible = status == "result"
	var back := "← 연습"
	var title := "롤플레이 미션"
	match status:
		"brief":
			back = "← 목록"
			title = str(mission.get("title_ko", title))
		"talk", "wait":
			back = "← 목록"
			title = str(mission.get("title_ko", title))
		"result":
			back = "← 목록"
			title = "결과 · " + str(mission.get("title_ko", ""))
	_back_btn.text = back
	_title.text = title
	_end_btn.visible = status == "talk" or status == "wait"
	_end_btn.disabled = status != "talk" or _me_count() == 0
	UI.fix_cjk(_head)


# ---------------------------------------------------------------- 목록

func _load_list(want_id: String = "") -> void:
	_list_serial += 1
	var serial: int = _list_serial
	list_error = false
	list_note = ""
	missions = []
	if lang != "en":
		status = "list"
		list_note = JA_NOTE
		_update_pages()
		_render_list()
		return
	status = "loading"
	_update_pages()
	_render_list()
	var res: Dictionary = await _wait(_req("GET", "/missions?lang=en", null, Api.TIMEOUT_SHORT))
	if serial != _list_serial:
		return
	if res.get("cancelled", false):
		return
	if not res.get("ok", false):
		list_error = true
		list_note = OLD_SERVER if int(res.get("code", 0)) == 404 else str(res.get("error", "미션 목록을 불러오지 못했어요."))
	elif not (res.get("data", null) is Dictionary):
		list_error = true
		list_note = "미션 목록을 읽지 못했어요. 잠시 뒤 다시 시도해 주세요."
	else:
		var parsed: Dictionary = MissionLogic.parse_list(res["data"])
		if bool(parsed["unsupported"]):
			list_note = str(parsed["message"]) if str(parsed["message"]) != "" else JA_NOTE
		else:
			missions = MissionLogic.sort_for_stage(parsed["missions"], _user_stage())
			if missions.is_empty():
				list_note = EMPTY_NOTE
	status = "list"
	_update_pages()
	_render_list()
	if want_id != "":
		_select(want_id)


func _user_stage() -> int:
	var p: Dictionary = Store.position()
	return clampi(Plan.stage_of(int(p.get("n", 1))), 1, 4)


func _render_list() -> void:
	var c: VBoxContainer = _list_page.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)
	c.add_child(UI.label("롤플레이 미션", "Eyebrow", false))
	c.add_child(UI.label("상황 속에서 목표를 채워 봐요", "H2"))
	c.add_child(UI.label("말할 때마다 목표가 자동으로 체크돼요. 모두 채우면 별 3개!", "Muted"))
	if status == "loading":
		c.add_child(UI.label("미션을 불러오는 중…", "Muted"))
	if list_note != "":
		var p := UI.tinted_panel(Pal.BAD_SOFT if list_error else Pal.SUNK, Color(0, 0, 0, 0), 0, 10, 14, 10)
		var v := UI.vbox(8)
		v.add_child(UI.colored(list_note, Pal.BAD if list_error else Pal.INK))
		if list_error:
			var retry := UI.button("다시 시도", "outline", Pal.BAD, 44)
			retry.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			retry.pressed.connect(func() -> void: _load_list())
			v.add_child(retry)
		p.add_child(v)
		c.add_child(p)
	for m in missions:
		c.add_child(_mission_card(m, acc))
	UI.fix_cjk(c)


func _mission_card(m: Dictionary, acc: Color) -> Control:
	var best: Dictionary = StudyLog.mission_best(str(m["id"]))
	var st: int = clampi(int(best.get("stars", 0)), 0, 3)
	var fits: bool = int(m["min_stage"]) <= _user_stage()
	var card := UI.card("Card", 6)
	var top := UI.hbox(8)
	var title := UI.label(str(m["title_ko"]), "Strong")
	top.add_child(title)
	top.add_child(UI.colored(MissionLogic.star_text(st), acc if st > 0 else Pal.MUTED, "", false))
	card.body.add_child(top)
	card.body.add_child(UI.label(str(m["situation_ko"]), "Muted"))
	var meta := "%d단계 · 목표 %d개" % [int(m["min_stage"]), (m["goals"] as Array).size()]
	if not fits:
		meta += " · 조금 어려워요"
	card.body.add_child(UI.label(meta, "Small"))
	var go := UI.button("선택", "soft", acc, 44)
	go.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var id: String = str(m["id"])
	go.pressed.connect(func() -> void: _select(id))
	card.body.add_child(go)
	return card


func _select(id: String) -> void:
	for m in missions:
		if str((m as Dictionary)["id"]) == id:
			mission = (m as Dictionary).duplicate(true)
			hints_open = false
			status = "brief"
			_update_pages()
			_render_brief()
			return


# ---------------------------------------------------------------- 설명

func _render_brief() -> void:
	var c: VBoxContainer = _brief_page.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)
	var card := UI.card("BigCard", 12)
	card.body.add_child(UI.label("미션 · %d단계" % _stage(), "Eyebrow", false))
	card.body.add_child(UI.label(str(mission["title_ko"]), "H2"))
	card.body.add_child(UI.label(str(mission["situation_ko"])))
	var best: Dictionary = StudyLog.mission_best(_mission_id())
	if int(best.get("stars", 0)) > 0:
		card.body.add_child(UI.label("내 최고 기록 " + MissionLogic.star_text(int(best["stars"])), "Muted"))
	card.body.add_child(UI.label("목표 %d개" % _goals().size(), "Eyebrow", false))
	for g in _goals():
		card.body.add_child(UI.label("• " + str((g as Dictionary)["label_ko"])))
	var hb := UI.button("힌트 숨기기" if hints_open else "힌트 보기", "outline", acc, 44)
	hb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hb.pressed.connect(func() -> void:
		hints_open = not hints_open
		_render_brief())
	card.body.add_child(hb)
	if hints_open:
		var hp := UI.tinted_panel(Pal.SUNK, Color(0, 0, 0, 0), 0, 10, 12, 10)
		var hv := UI.vbox(4)
		for g in _goals():
			var gd: Dictionary = g
			hv.add_child(UI.label("%s → %s" % [gd["label_ko"], gd["hint_en"]] if str(gd["hint_en"]) != "" else str(gd["label_ko"])))
		hp.add_child(hv)
		card.body.add_child(hp)
	card.body.add_child(UI.label("말하는 횟수는 %d번까지예요. 상대의 첫 마디는 바로 나와요." % int(mission["max_turns"]), "Small"))
	var down: bool = _llm_down()
	if down:
		var np := UI.tinted_panel(Pal.WARN_SOFT, Color(0, 0, 0, 0), 0, 10, 12, 10)
		np.add_child(UI.colored("지금은 AI를 쓸 수 없어요. 대본 모드로 연습할 수 있어요. 상대 대사가 미리 정해져 있고 AI 호출이 없어요.", Pal.WARN))
		card.body.add_child(np)
	var has_script: bool = not _script().is_empty()
	var go := UI.button("미션 시작", "primary", acc, 52)
	go.pressed.connect(func() -> void: _start("ai"))
	var sc_btn := UI.button("대본 모드로 연습", "primary" if down else "outline", acc, 52)
	sc_btn.disabled = not has_script
	sc_btn.pressed.connect(func() -> void: _start("script"))
	if down:
		card.body.add_child(sc_btn)
		card.body.add_child(go)
	else:
		card.body.add_child(go)
		card.body.add_child(sc_btn)
	c.add_child(card)
	UI.fix_cjk(c)


# ---------------------------------------------------------------- 시작

func _start(new_mode: String) -> void:
	if mission.is_empty():
		return
	var m: Dictionary = mission
	_reset_run()
	mission = m
	mode = new_mode
	conv_id = "m%d-%d" % [Time.get_ticks_usec(), randi()]
	var first: String = str(mission["opening"])
	if mode == "script":
		if _script().is_empty():
			mode = "ai"
		else:
			script_state = MissionLogic.script_new()
			first = str((_script()[0] as Dictionary)["ai"])
	if first == "":
		first = "Hello! Shall we begin?"
	msgs.append({"role": "ai", "reply": first, "ko": ""})
	status = "talk"
	_speak(first)
	_update_pages()
	_apply_layout(true)
	_render_chat()


func _speak(text: String) -> void:
	if Store.pref_bool("auto_speak"):
		Tts.speak(text, lang)


# ---------------------------------------------------------------- 보내기

func _send_message() -> void:
	if status != "talk" or stt_busy:
		return
	var t: String = MissionLogic.clean_text(_input.text)
	if t == "":
		return
	_input.text = ""
	msgs.append({"role": "me", "text": t})
	err = ""
	chat_failed = false
	leave_confirm = false
	if mode == "script":
		_script_turn(t)
	else:
		_ai_turn(t)


func _ai_turn(text: String) -> void:
	turns += 1
	status = "wait"
	_serial += 1
	var serial: int = _serial
	_render_chat()
	var chk = _req("POST", "/missions/check", {"lang": lang, "mission_id": _mission_id(), "text": text, "done": done.keys()}, Api.TIMEOUT_SHORT)
	_chat_req = _req("POST", "/chat", _chat_payload(), Api.TIMEOUT_LLM)
	var chat = _chat_req
	var cres: Dictionary = await _wait(chk)  ## 체크가 먼저. /chat 이 먼저 끝났어도 여기서 기다린 뒤에 반영한다
	if serial != _serial:
		return
	_apply_check(cres)
	var res: Dictionary = await _wait(chat)
	if serial != _serial or chat != _chat_req:
		return
	_chat_req = null
	_after_chat(res)


func _resend() -> void:
	if status != "talk" or not chat_failed or msgs.is_empty() or (msgs[msgs.size() - 1] as Dictionary)["role"] != "me":
		return
	status = "wait"
	err = ""
	chat_failed = false
	_serial += 1
	var serial: int = _serial
	_render_chat()
	_chat_req = _req("POST", "/chat", _chat_payload(), Api.TIMEOUT_LLM)
	var chat = _chat_req
	var res: Dictionary = await _wait(chat)
	if serial != _serial or chat != _chat_req:
		return
	_chat_req = null
	_after_chat(res)


func _chat_payload() -> Dictionary:
	var p: Dictionary = Store.position()
	return {
		"lang": lang, "stage": _stage(), "month": int(p.get("n", 1)), "week": int(p.get("w", 1)),
		"scenario": mission.get("scenario", {}),
		"history": _history(),
		"skip_fix": true, "conv_id": conv_id,
		"tts_speed": Tts.normal_speed(), "tts_voice": Tts.voice_for(lang), "presynth": Store.pref_bool("auto_speak"),
	}


func _apply_check(res: Dictionary) -> void:
	if res.get("cancelled", false) or not res.get("ok", false):
		return  # 규칙 체크가 안 돼도 대화는 계속, 직접 체크할 수 있다
	var fresh: Array = MissionLogic.apply_check(_goals(), done, res.get("data", null))
	_toast_new(fresh)
	if not fresh.is_empty():
		_render_goals()


func _toast_new(ids: Array) -> void:
	for id in ids:
		Toast.ok("목표 달성: " + _goal_label(str(id)))


func _after_chat(res: Dictionary) -> void:
	status = "talk"
	var data: Variant = res.get("data", null)
	if res.get("cancelled", false):
		chat_failed = true
		err = "답을 기다리다가 멈췄어요. 다시 보내려면 아래 버튼을 눌러 주세요."
	elif not res.get("ok", false):
		chat_failed = true
		err = str(res.get("error", "AI에게 연결하지 못했어요."))
	elif not (data is Dictionary) or str((data as Dictionary).get("reply", "")).strip_edges() == "":
		chat_failed = true
		err = "AI 답을 읽지 못했어요. 다시 시도해 주세요."
	else:
		var d: Dictionary = data
		var reply: String = str(d["reply"]).strip_edges()
		msgs.append({"role": "ai", "reply": reply, "ko": str(d.get("ko", ""))})
		var chunks: Variant = d.get("tts_chunks", null)
		if Store.pref_bool("auto_speak"):
			if chunks is Array and not (chunks as Array).is_empty():
				Tts.speak_chunks(chunks, lang)
			else:
				Tts.speak(reply, lang)
	if MissionLogic.should_end(done.size(), _goals().size(), turns, int(mission["max_turns"])):
		_finish()
		return
	_render_chat()


func _cancel_chat() -> void:
	if _chat_req != null:
		_chat_req.cancel()


# ---------------------------------------------------------------- 대본 모드 (AI 호출 0회)

func _script_turn(text: String) -> void:
	status = "wait"
	_serial += 1
	var serial: int = _serial
	_render_chat()
	var lines: Array = _script()
	var line: Dictionary = lines[mini(int(script_state["idx"]), lines.size() - 1)]
	# 규칙 체크 (AI 아님). done 을 비워 보내면 "이 문장이 닿은 목표"만 돌아온다. 서버가 안 되면 문장 유사도만 쓴다.
	var res: Dictionary = await _wait(_req("POST", "/missions/check", {"lang": lang, "mission_id": _mission_id(), "text": text, "done": []}, Api.TIMEOUT_SHORT))
	if serial != _serial:
		return
	var reached: Array = []
	if res.get("ok", false) and not res.get("cancelled", false):
		reached = MissionLogic.reached_ids(_goals(), res.get("data", null))
	var passed: bool = MissionLogic.script_passes(text, line, reached)
	var fresh: Array = []
	var line_goal: String = str(line.get("goal", ""))
	if passed and line_goal != "" and MissionLogic.goal_ids(_goals()).has(line_goal) and not reached.has(line_goal):
		reached.append(line_goal)
	for id in reached:
		if not done.has(id):
			done[id] = MissionLogic.BY_RULE
			fresh.append(id)
	_toast_new(fresh)
	var step: Dictionary = MissionLogic.script_step(script_state, lines.size(), passed)
	script_state = step["state"]
	var outcome: String = str(step["outcome"])
	if outcome == "pass" or outcome == "miss":
		turns += 1
	if outcome == "retry":
		var n: int = int(script_state["fails"])
		msgs.append({"role": "note", "text": "조금 달라요. 다시 말해 보세요 (%d/%d) · 목표: %s" % [n, MissionLogic.MAX_FAILS, _goal_label(line_goal)]})
	elif outcome == "miss":
		msgs.append({"role": "model", "text": "이렇게 말할 수 있어요: " + str(line.get("model", ""))})
	status = "talk"
	var limit: int = maxi(int(mission["max_turns"]), lines.size())
	if bool(step["finished"]) or MissionLogic.should_end(done.size(), _goals().size(), turns, limit):
		_finish()
		return
	if outcome == "pass" or outcome == "miss":
		var next_line: String = str((lines[int(script_state["idx"])] as Dictionary)["ai"])
		msgs.append({"role": "ai", "reply": next_line, "ko": ""})
		_speak(next_line)
	_render_chat()


# ---------------------------------------------------------------- 음성 입력

func _on_recorded(result: Dictionary) -> void:
	if status != "talk" or stt_busy:
		return
	stt_busy = true
	_update_composer()
	var serial: int = _serial
	var res: Dictionary = await _wait(_req("POST", "/stt", {"lang": lang, "audio_b64": result.get("b64", "")}, Api.TIMEOUT_SHORT))
	stt_busy = false
	if serial != _serial:
		return
	_update_composer()
	if res.get("cancelled", false):
		return
	if not res.get("ok", false) or not (res.get("data", null) is Dictionary):
		Toast.error(str(res.get("error", "말한 내용을 글자로 바꾸지 못했어요.")))
		return
	var text: String = str((res["data"] as Dictionary).get("text", "")).strip_edges()
	if text == "":
		Toast.info("잘 알아듣지 못했어요. 조금 더 크게, 또렷하게 다시 말해 주세요.")
		return
	_input.text = text.left(MissionLogic.MAX_TEXT)
	if Store.pref_bool("auto_send"):
		_send_message()
	else:
		_input.grab_focus()
		_input.caret_column = _input.text.length()


# ---------------------------------------------------------------- 대화 화면

func _render_chat() -> void:
	_update_pages()
	_apply_layout(false)
	_render_msgs()
	_render_goals()
	_render_aux()
	_update_composer()


func _update_composer() -> void:
	if _input == null:
		return
	var talk: bool = status == "talk"
	_input.editable = talk and not stt_busy
	_send.disabled = not talk or stt_busy
	_mic.set_enabled(talk and not stt_busy)
	if talk:
		_input.placeholder_text = "영어로 말하거나 입력하기"
	else:
		_input.placeholder_text = "답을 기다리는 중…"
	_status_label.text = "말한 내용을 글자로 바꾸는 중…" if stt_busy else ""
	_end_btn.disabled = status != "talk" or _me_count() == 0


func _apply_layout(force: bool) -> void:
	if _chat_root == null:
		return
	var wide: bool = _is_wide()
	if wide == _wide and not force:
		return
	_wide = wide
	_side_wrap.visible = wide
	_goal_bar.visible = not wide
	# 마이크: PC 는 입력줄 안, 폰은 아래 줄 (412 폭에 한 줄로 안 들어간다)
	var host: Control = _comp_row if wide else _mic_row
	if _mic.get_parent() != host:
		_mic.get_parent().remove_child(_mic)
		host.add_child(_mic)
		if wide:
			host.move_child(_mic, host.get_child_count() - 2)  # 보내기 앞
		else:
			host.move_child(_mic, 0)
	_mic_row.visible = true
	_mic.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if status == "talk" or status == "wait":
		_render_msgs()
		_render_goals()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _chat_root != null:
		_apply_layout(false)


func _on_msg_resized() -> void:
	if _msg_scroll != null and absf(_msg_scroll.size.x - _msg_w) > 1.0 and (status == "talk" or status == "wait"):
		_render_msgs()


func _render_msgs() -> void:
	var c: VBoxContainer = _msg_scroll.content
	UI.clear(c)
	_msg_w = _msg_scroll.size.x
	var max_w: float = clampf(_msg_scroll.size.x * 0.8 - 40.0, 200.0, 620.0)
	for i in msgs.size():
		var m: Dictionary = msgs[i]
		match str(m["role"]):
			"me":
				c.add_child(_me_row(m, max_w))
			"ai":
				c.add_child(_ai_row(m, i, max_w))
			"model":
				var p := UI.tinted_panel(Pal.OK_SOFT, Color(0, 0, 0, 0), 0, 10, 12, 8)
				p.add_child(UI.colored(str(m["text"]), Pal.OK))
				c.add_child(p)
			_:
				c.add_child(UI.label(str(m.get("text", "")), "Muted"))
	if status == "wait":
		var row := UI.hbox(10)
		row.add_child(UI.label("%s 입력 중…" % _who() if mode == "ai" else "확인하는 중…", "Muted", false))
		if mode == "ai":
			var cancel := UI.link_button("취소")
			cancel.custom_minimum_size.y = 44
			cancel.pressed.connect(_cancel_chat)
			row.add_child(cancel)
		c.add_child(row)
	if chat_failed and err != "":
		var p2 := UI.tinted_panel(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
		var v := UI.vbox(8)
		v.add_child(UI.colored(err, Pal.BAD))
		var acts := UI.flow(8, 8)
		var retry := UI.button("다시 보내기", "outline", Pal.BAD, 44)
		retry.pressed.connect(_resend)
		acts.add_child(retry)
		var has_script: bool = not _script().is_empty()
		if mode == "ai" and has_script:
			var sb := UI.button("대본 모드로 연습", "soft", Pal.EN, 44)
			sb.pressed.connect(func() -> void: _start("script"))
			acts.add_child(sb)
		v.add_child(acts)
		p2.add_child(v)
		c.add_child(p2)
	UI.fix_cjk(c)
	UI.scroll_to_bottom(_msg_scroll)


func _bubble(text: String, bg: Color, border: Color, fg: Color, max_w: float, rl: int, rr: int) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UI.style(bg, border, 1 if border.a > 0.0 else 0, 16, 14, 10)
	st.corner_radius_bottom_left = rl
	st.corner_radius_bottom_right = rr
	p.add_theme_stylebox_override("panel", st)
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var l := UI.label(text, "")
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", fg)
	l.size_flags_horizontal = Control.SIZE_FILL
	l.custom_minimum_size = Vector2(minf(UI.text_width(text, 17) + 6.0, max_w), 0)
	p.add_child(l)
	return p


func _ai_row(m: Dictionary, i: int, max_w: float) -> Control:
	var row := UI.hbox(0)
	var col := UI.vbox(4)
	col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(UI.label(_who(), "Small", false))
	col.add_child(_bubble(str(m["reply"]), Pal.SURFACE, Pal.LINE, Pal.INK, max_w, 4, 16))
	var ko: String = str(m.get("ko", ""))
	var always_ko: bool = Store.pref_bool("show_ko")
	var show_ko: bool = ko != "" and (always_ko or bool(ko_open.get(i, false)))
	if show_ko:
		var kl := UI.label(ko, "Muted")
		kl.custom_minimum_size = Vector2(minf(UI.text_width(ko, 15) + 6.0, max_w), 0)
		kl.size_flags_horizontal = Control.SIZE_FILL
		col.add_child(kl)
	var acts := UI.hbox(2)
	var listen := UI.link_button("▶ 듣기")
	listen.custom_minimum_size.y = 44
	var said: String = str(m["reply"])
	listen.pressed.connect(func() -> void: Tts.speak(said, lang))
	acts.add_child(listen)
	if ko != "" and not always_ko:
		var tb := UI.link_button("번역 숨기기" if show_ko else "번역")
		tb.custom_minimum_size.y = 44
		tb.pressed.connect(func() -> void:
			ko_open[i] = not bool(ko_open.get(i, false))
			_render_msgs())
		acts.add_child(tb)
	col.add_child(acts)
	row.add_child(col)
	return row


func _me_row(m: Dictionary, max_w: float) -> Control:
	var row := UI.hbox(0)
	row.add_child(UI.spacer())
	var bub := _bubble(str(m["text"]), Pal.accent(lang), Color(0, 0, 0, 0), Color.WHITE, max_w, 16, 4)
	bub.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(bub)
	return row


## 위쪽 안내 줄: 나가기 확인
func _render_aux() -> void:
	UI.clear(_aux)
	if not leave_confirm or (status != "talk" and status != "wait"):
		return
	var p := UI.tinted_panel(Pal.WARN_SOFT, Color(0, 0, 0, 0), 0, 10, 12, 8)
	var v := UI.vbox(6)
	v.add_child(UI.colored("대화를 그만하고 목록으로 갈까요? 지금까지의 기록은 저장되지 않아요.", Pal.WARN))
	var acts := UI.flow(8, 8)
	var stop := UI.button("그만두기", "outline", Pal.BAD, 44)
	stop.pressed.connect(_abandon)
	var keep := UI.button("계속하기", "soft", Pal.EN, 44)
	keep.pressed.connect(func() -> void:
		leave_confirm = false
		_render_aux())
	acts.add_child(stop)
	acts.add_child(keep)
	v.add_child(acts)
	p.add_child(v)
	_aux.add_child(p)
	UI.fix_cjk(_aux)


# ---------------------------------------------------------------- 목표 패널

func _render_goals() -> void:
	if _side_box == null:
		return
	UI.clear(_side_box)
	UI.clear(_goal_bar_box)
	if _wide:
		_fill_goals(_side_box, false)
	else:
		var total: int = _goals().size()
		var n: int = MissionLogic.count_done(_goals(), done)
		var bar := UI.button("목표 %d / %d  %s" % [n, total, "▴" if goals_open else "▾"], "flat", Pal.INK, 44)
		bar.alignment = HORIZONTAL_ALIGNMENT_LEFT
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.pressed.connect(func() -> void:
			goals_open = not goals_open
			_render_goals())
		_goal_bar_box.add_child(bar)
		if goals_open:
			_fill_goals(_goal_bar_box, true)
	UI.fix_cjk(_side_box)
	UI.fix_cjk(_goal_bar_box)


func _fill_goals(box: VBoxContainer, compact: bool) -> void:
	var total: int = _goals().size()
	var n: int = MissionLogic.count_done(_goals(), done)
	if not compact:
		box.add_child(UI.label("목표  %d / %d" % [n, total], "Strong", false))
	for g in _goals():
		box.add_child(_goal_row(g))
	var hb := UI.button("힌트 숨기기" if hints_open else "힌트 보기", "outline", Pal.EN, 44)
	hb.pressed.connect(func() -> void:
		hints_open = not hints_open
		_render_goals())
	box.add_child(hb)
	if hints_open:
		for g in _goals():
			var gd: Dictionary = g
			if str(gd["hint_en"]) != "":
				box.add_child(UI.label("%s: %s" % [gd["label_ko"], gd["hint_en"]], "Small"))
	if not compact:
		box.add_child(UI.label("자동으로 체크되지 않으면 목표를 눌러 직접 체크할 수 있어요.", "Small"))


## 목표 한 줄 = 누르는 버튼. 안 한 목표를 누르면 직접 체크, 직접 체크한 것을 누르면 해제.
func _goal_row(g: Dictionary) -> Button:
	var id: String = str(g["id"])
	var by: String = str(done.get(id, ""))
	var mark := "○"
	var tag := ""
	if by != "":
		mark = "✓"
		tag = {"rule": "  (자동)", "manual": "  (직접)", "ai": "  (AI 판정)"}.get(by, "")
	var b := UI.option_row("%s  %s%s" % [mark, g["label_ko"], tag])
	b.custom_minimum_size.y = 44
	UI.paint_option(b, "right" if by != "" else "idle", Pal.EN)
	b.pressed.connect(func() -> void: _toggle_goal(id))
	return b


func _toggle_goal(id: String) -> void:
	if status == "talk" or status == "wait" or status == "result":
		var by: String = str(done.get(id, ""))
		if by == "":
			done[id] = MissionLogic.BY_MANUAL
		elif by == MissionLogic.BY_MANUAL:
			done.erase(id)
		else:
			return
		if status == "result":
			_recompute_award()
			_render_result()
		else:
			_render_goals()
			if MissionLogic.should_end(done.size(), _goals().size(), turns, int(mission["max_turns"])) and status == "talk":
				_finish()


# ---------------------------------------------------------------- 끝내기

func _finish() -> void:
	if status == "result" or mission.is_empty():
		return
	_serial += 1
	_cancel_all()
	status = "result"
	judge_note = ""
	_commit()
	fb_state = "none"
	if mode == "ai" and turns >= 1:
		_request_feedback()
	_update_pages()
	_render_result()


func _calc_award() -> Dictionary:
	var n: int = MissionLogic.count_done(_goals(), done)
	var limit: int = int(mission["max_turns"])
	if mode == "script":
		limit = maxi(limit, _script().size())
	var s: int = MissionLogic.stars(n, _goals().size(), turns, limit)
	return {"done": n, "stars": s, "xp": MissionLogic.xp(n, s)}


func _commit() -> void:
	if _me_count() == 0:
		_awarded = {"done": 0, "stars": 0, "xp": 0, "none": true}
		return
	_awarded = _calc_award()
	Store.add_xp(lang, int(_awarded["xp"]))
	if MissionLogic.marks_today(int(_awarded["done"]), turns):
		Store.mark_today(lang)
	Store.save_progress()
	_log_mission(int(_awarded["stars"]))
	_log_event("missions")


## 결과 화면에서 직접 체크/AI 판정으로 달성이 바뀌면 XP 차이만 반영한다. 별이나 달성 목표가 늘었을 때만 최고 기록을
## 올린다(update_mission_best: 도전 횟수 plays 는 그대로. add_mission 을 다시 부르면 한 판이 두 번으로 센다).
func _recompute_award() -> void:
	if _awarded.is_empty() or _awarded.get("none", false):
		return
	var cur: Dictionary = _calc_award()
	var delta: int = int(cur["xp"]) - int(_awarded["xp"])
	if delta != 0:
		Store.add_xp(lang, delta)
	if MissionLogic.marks_today(int(cur["done"]), turns):
		Store.mark_today(lang)
	Store.save_progress()
	if int(cur["stars"]) > int(_awarded["stars"]) or int(cur["done"]) > int(_awarded["done"]):
		_log_mission_best(int(cur["stars"]))
	_awarded = cur


static var _am_wants_int: int = -1


## T0 뼈대의 add_mission 4번째 인자는 int(개수), 설계 8.4 는 목록. 실제 구현의 모양에 맞춰 넘긴다.
static func _add_mission_takes_int() -> bool:
	if _am_wants_int < 0:
		_am_wants_int = 1
		var sc: Script = load("res://scripts/core/study_log.gd")
		for md in sc.get_script_method_list():
			if str(md["name"]) == "add_mission":
				var args: Array = md["args"]
				if args.size() >= 4 and int(args[3]["type"]) != TYPE_INT:
					_am_wants_int = 0
	return _am_wants_int == 1


func _log_mission(star_count: int) -> void:
	var ids: Array = []
	for id in done.keys():
		ids.append(str(id))
	if log_hook.is_valid():
		log_hook.call("mission", {"lang": lang, "id": _mission_id(), "stars": star_count, "done_goals": ids})
	var arg: Variant = ids.size() if _add_mission_takes_int() else ids
	StudyLog.add_mission(lang, _mission_id(), star_count, arg)


## Same game, better result (result screen): raises the best record only, plays stays as it is.
func _log_mission_best(star_count: int) -> void:
	var ids: Array = []
	for id in done.keys():
		ids.append(str(id))
	if log_hook.is_valid():
		log_hook.call("mission_best", {"lang": lang, "id": _mission_id(), "stars": star_count, "done_goals": ids})
	StudyLog.update_mission_best(lang, _mission_id(), star_count, ids.size())


func _log_event(kind: String) -> void:
	if log_hook.is_valid():
		log_hook.call("event", {"lang": lang, "kind": kind})
	StudyLog.add_event(lang, kind)


# ---------------------------------------------------------------- 피드백 (/feedback)

func _request_feedback() -> void:
	fb_state = "wait"
	fb_error = ""
	_fb_serial += 1
	var serial: int = _fb_serial
	var req = _req("POST", "/feedback", {"lang": lang, "stage": _stage(), "history": _history()}, Api.TIMEOUT_LLM)
	_fb_req = req
	var res: Dictionary = await _wait(req)
	if serial != _fb_serial or req != _fb_req:
		return
	_fb_req = null
	var data: Variant = res.get("data", null)
	if res.get("cancelled", false) or not res.get("ok", false) or not (data is Dictionary):
		fb_state = "fail"
		fb_error = str(res.get("error", ""))
	else:
		fb = data
		fb_state = "ok"
		var items: Array = []
		var corrs: Variant = fb.get("corrections", [])
		if corrs is Array:
			for cc in corrs:
				if cc is Dictionary and str((cc as Dictionary).get("better", "")).strip_edges() != "":
					var cd: Dictionary = cc
					items.append({"lang": lang, "target": str(cd["better"]), "reading": str(cd.get("reading", "")), "ko": str(cd.get("ko", "")), "note": str(cd.get("why", ""))})
		fb_added = Store.add_review(items)
		Store.save_progress()
	if status == "result":
		_render_result()


func _stop_feedback() -> void:
	_fb_serial += 1
	if _fb_req != null:
		_fb_req.cancel()
		_fb_req = null
	fb_state = "fail"
	fb_error = "취소했어요."
	_render_result()


# ---------------------------------------------------------------- AI 로 다시 판정 (/missions/judge)

func _judge() -> void:
	var pending: Array = MissionLogic.pending_ids(_goals(), done)
	if judge_busy or pending.is_empty() or status != "result":
		return
	judge_busy = true
	judge_note = ""
	_judge_serial += 1
	var serial: int = _judge_serial
	_render_result()
	var res: Dictionary = await _wait(_req("POST", "/missions/judge", {"lang": lang, "mission_id": _mission_id(), "pending": pending, "history": _history()}, Api.TIMEOUT_LLM))
	if serial != _judge_serial:
		return
	judge_busy = false
	var data: Variant = res.get("data", null)
	if res.get("cancelled", false):
		judge_note = ""
	elif not res.get("ok", false) or not (data is Dictionary):
		judge_note = "AI 판정을 쓸 수 없어서 규칙 결과를 그대로 뒀어요. " + str(res.get("error", ""))
	elif (data as Dictionary).get("ai", true) == false:
		judge_note = "AI가 판정하지 못했어요. 규칙 결과를 그대로 뒀어요."
	else:
		var fresh: Array = MissionLogic.apply_judge(done, pending, data, _me_texts())
		judge_note = "AI가 목표 %d개를 더 인정했어요." % fresh.size() if not fresh.is_empty() else "AI도 더 달성한 목표를 찾지 못했어요."
		_recompute_award()
	if status == "result":
		_render_result()


# ---------------------------------------------------------------- 결과 화면

func _render_result() -> void:
	var c: VBoxContainer = _result_page.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)
	var cur: Dictionary = _calc_award()
	var card := UI.card("BigCard", 12)
	card.body.add_child(UI.label("미션 결과 · %s" % str(mission.get("title_ko", "")), "Eyebrow", false))
	var stars_l := UI.colored(MissionLogic.star_text(int(cur["stars"])), acc, "Big", false)
	stars_l.add_theme_font_size_override("font_size", 44)
	card.body.add_child(stars_l)
	var xp_text := "목표 %d / %d 달성" % [int(cur["done"]), _goals().size()]
	if not _awarded.get("none", false) and not _awarded.is_empty():
		xp_text += " · XP +%d" % int(cur["xp"])
	else:
		xp_text += " · 말한 기록이 없어서 저장하지 않았어요"
	card.body.add_child(UI.label(xp_text, "Muted"))
	if mode == "script":
		card.body.add_child(UI.label("대본 모드로 연습했어요 (AI 호출 없음)", "Small"))
	c.add_child(card)

	# 목표 목록
	var gc := UI.card("BigCard", 8)
	gc.body.add_child(UI.label("목표", "Eyebrow", false))
	for g in _goals():
		gc.body.add_child(_goal_row(g))
	var pending: Array = MissionLogic.pending_ids(_goals(), done)
	if not pending.is_empty():
		gc.body.add_child(UI.label("자동으로 체크되지 않은 목표는 눌러서 직접 체크할 수 있어요.", "Small"))
		if mode == "ai" and not _llm_down() and _me_count() > 0:
			var jb := UI.button("AI로 다시 판정", "soft", acc, 44)
			jb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			jb.disabled = judge_busy
			jb.pressed.connect(_judge)
			gc.body.add_child(jb)
	if judge_busy:
		gc.body.add_child(UI.label("AI가 대화를 다시 살펴보는 중…", "Muted"))
	if judge_note != "":
		gc.body.add_child(UI.label(judge_note, "Muted"))
	c.add_child(gc)

	if mode == "script":
		c.add_child(_script_summary_card(cur))
	else:
		_add_feedback(c, acc)

	# 대화 다시 보기
	var tr := UI.card("Card", 6)
	tr.body.add_child(UI.label("대화 기록", "Eyebrow", false))
	for m in msgs:
		var d: Dictionary = m
		if d["role"] == "ai":
			tr.body.add_child(UI.label("%s: %s" % [_who(), d["reply"]], "Small"))
		elif d["role"] == "me":
			tr.body.add_child(UI.label("나: %s" % d["text"], "Small"))
	c.add_child(tr)

	var row := UI.flow(8, 8)
	var again := UI.button("다시 하기", "primary", acc, 50)
	again.pressed.connect(func() -> void: _start("script" if mode == "script" else "ai"))
	var to_list := UI.button("미션 목록", "soft", acc, 50)
	to_list.pressed.connect(_abandon)
	var to_hub := UI.button("연습으로", "outline", acc, 50)
	to_hub.pressed.connect(func() -> void: closed.emit())
	row.add_child(again)
	row.add_child(to_list)
	row.add_child(to_hub)
	c.add_child(row)
	UI.fix_cjk(c)
	UI.fix_cjk(_head)


func _script_summary_card(cur: Dictionary) -> Control:
	var sc := UI.card("BigCard", 8)
	sc.body.add_child(UI.label("대본 모드 정리", "Eyebrow", false))
	sc.body.add_child(UI.label(MissionLogic.rule_summary(_goals(), done, int(cur["stars"]), turns)))
	var results: Array = script_state.get("results", []) if script_state.get("results", []) is Array else []
	var lines: Array = _script()
	for i in results.size():
		if results[i] == "miss" and i < lines.size():
			var ln: Dictionary = lines[i]
			sc.body.add_child(UI.label("놓친 줄: %s → %s" % [ln["ai"], ln["model"]], "Small"))
	sc.body.add_child(UI.label("AI가 연결되면 고쳐 말하기와 점수 피드백도 받을 수 있어요.", "Small"))
	return sc


func _score_tile(value: int, caption: String, acc: Color) -> Control:
	var p := UI.tinted_panel(Pal.soft(lang), Color(0, 0, 0, 0), 0, 10, 12, 10)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := UI.vbox(0)
	var n := Label.new()
	n.text = "%d/5" % value
	n.add_theme_font_size_override("font_size", 24)
	n.add_theme_font_override("font", UI.bold_font())
	n.add_theme_color_override("font_color", acc)
	v.add_child(n)
	v.add_child(UI.label(caption, "Small", false))
	p.add_child(v)
	return p


func _add_feedback(c: VBoxContainer, acc: Color) -> void:
	if turns < 1:
		return
	if fb_state == "wait":
		var w := UI.card("BigCard", 10)
		w.body.add_child(UI.label("피드백", "Eyebrow", false))
		w.body.add_child(UI.label("대화를 돌아보는 중이에요. 보통 10~60초 걸려요."))
		var bar := ProgressBar.new()
		bar.indeterminate = true
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.add_theme_stylebox_override("fill", UI.style(acc, Color(0, 0, 0, 0), 0, 99, 0, 0))
		w.body.add_child(bar)
		var stop := UI.button("그만 기다리기", "outline", acc, 44)
		stop.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		stop.pressed.connect(_stop_feedback)
		w.body.add_child(stop)
		c.add_child(w)
		return
	if fb_state == "fail":
		var f := UI.card("BigCard", 10)
		f.body.add_child(UI.label("피드백", "Eyebrow", false))
		f.body.add_child(UI.colored("피드백을 불러오지 못했어요. 별점과 목표 결과는 위에 그대로 있어요.", Pal.BAD))
		if fb_error != "":
			f.body.add_child(UI.label(fb_error, "Small"))
		var rt := UI.button("다시 시도", "outline", Pal.BAD, 44)
		rt.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		rt.pressed.connect(func() -> void:
			_request_feedback()
			_render_result())
		f.body.add_child(rt)
		c.add_child(f)
		return
	if fb_state != "ok":
		return
	var scores: Dictionary = fb.get("scores", {}) if fb.get("scores", {}) is Dictionary else {}
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("대화 피드백", "Eyebrow", false))
	var sr := UI.hbox(8)
	for spec in [["유창성", "fluency"], ["정확성", "accuracy"], ["어휘", "vocabulary"]]:
		var raw: Variant = scores.get(spec[1], 0)
		var v: int = clampi(int(raw) if (raw is int or raw is float) else 0, 0, 5)
		sr.add_child(_score_tile(v, spec[0], acc))
	card.body.add_child(sr)
	if str(fb.get("summary", "")) != "":
		card.body.add_child(UI.label(str(fb["summary"])))
	c.add_child(card)
	var corrs: Array = []
	if fb.get("corrections", []) is Array:
		for cc in fb["corrections"]:
			if cc is Dictionary and str((cc as Dictionary).get("better", "")).strip_edges() != "":
				corrs.append(cc)
	if not corrs.is_empty():
		var cb := UI.card("BigCard", 8)
		cb.body.add_child(UI.label("고쳐 말하기 · 복습 목록에 추가됨", "Eyebrow", false))
		for cc in corrs:
			var d: Dictionary = cc
			var item := UI.tinted_panel(Pal.SURFACE, Pal.LINE, 1, 10, 12, 10)
			var iv := UI.vbox(3)
			if str(d.get("you", "")) != "":
				iv.add_child(UI.rich("[s][color=#B83A3A]%s[/color][/s]" % UI.bb_escape(str(d["you"])), 16))
			iv.add_child(UI.colored(str(d["better"]), Pal.OK, "Strong"))
			if str(d.get("ko", "")) != "":
				iv.add_child(UI.label(str(d["ko"]), "Muted"))
			if str(d.get("why", "")) != "":
				iv.add_child(UI.label(str(d["why"]), "Small"))
			var lb := UI.link_button("▶ 듣기")
			lb.custom_minimum_size.y = 44
			var target: String = str(d["better"])
			lb.pressed.connect(func() -> void: Tts.speak(target, lang))
			iv.add_child(lb)
			item.add_child(iv)
			cb.body.add_child(item)
		c.add_child(cb)
	var phrases: Array = []
	if fb.get("phrases", []) is Array:
		for pp in fb["phrases"]:
			if pp is Dictionary and str((pp as Dictionary).get("phrase", "")).strip_edges() != "":
				phrases.append(pp)
	if not phrases.is_empty():
		var pb := UI.card("BigCard", 8)
		pb.body.add_child(UI.label("이 상황에서 쓸 만한 표현", "Eyebrow", false))
		for pp in phrases:
			var d2: Dictionary = pp
			var item2 := UI.tinted_panel(Pal.SURFACE, Pal.LINE, 1, 10, 12, 10)
			var iv2 := UI.vbox(3)
			iv2.add_child(UI.label(str(d2["phrase"]), "Strong"))
			if str(d2.get("ko", "")) != "":
				iv2.add_child(UI.label(str(d2["ko"]), "Muted"))
			item2.add_child(iv2)
			pb.body.add_child(item2)
		c.add_child(pb)
