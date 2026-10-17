class_name TalkView
extends AppView
## 원어민 대화: scenario setup, chat with the local LLM (/chat), voice input (/stt),
## and the feedback screen (/feedback).

const NAME_KO := {"en": "영어", "ja": "일본어"}
const LNAME := {"en": "English", "ja": "Japanese"}

const SCENES := {
	"en": [
		{"id": "cafe", "t": "카페에서 주문", "who": "Emma", "role": "a friendly barista at a busy coffee shop in Seattle", "scene": "The learner is a customer ordering at the counter.", "min": 1},
		{"id": "meet", "t": "처음 만난 사람과 스몰토크", "who": "Jake", "role": "an outgoing software engineer from Toronto at a friend's house party", "scene": "You just met the learner and start small talk.", "min": 1},
		{"id": "hotel", "t": "호텔 체크인", "who": "Olivia", "role": "a front desk clerk at a hotel in London", "scene": "The learner is checking in and has a few requests.", "min": 2},
		{"id": "street", "t": "길 묻기와 여행", "who": "Marcus", "role": "a helpful local New Yorker on the street near Times Square", "scene": "The learner, a tourist, asks for directions and recommendations.", "min": 2},
		{"id": "friend", "t": "친구와 주말 이야기", "who": "Mia", "role": "the learner's close American friend, chatting over a video call", "scene": "Catch up about last weekend and plans for next weekend.", "min": 2},
		{"id": "work", "t": "업무 미팅", "who": "Daniel", "role": "a project manager at a global company, in a short online meeting", "scene": "Discuss the learner's progress on a project and next steps.", "min": 3},
		{"id": "debate", "t": "의견 나누기", "who": "Sophie", "role": "a curious journalist from Chicago", "scene": "Ask for the learner's opinion on everyday social topics (remote work, social media, travel) and push back politely.", "min": 3},
	],
	"ja": [
		{"id": "konbini", "t": "편의점에서", "who": "さくら", "role": "a part-time clerk at a convenience store in Tokyo", "scene": "The learner is a customer buying a few things.", "min": 1},
		{"id": "ramen", "t": "라멘집 주문", "who": "けんじ", "role": "the owner of a small ramen shop in Osaka", "scene": "The learner comes in and orders.", "min": 1},
		{"id": "intro", "t": "첫 만남 자기소개", "who": "ゆうき", "role": "a university student in Tokyo at a language exchange meetup", "scene": "You meet the learner for the first time and introduce yourselves.", "min": 1},
		{"id": "station", "t": "역에서 길 묻기", "who": "たなか", "role": "a station staff member at Shinjuku Station", "scene": "The learner asks how to get somewhere.", "min": 2},
		{"id": "ryokan", "t": "료칸 체크인", "who": "みどり", "role": "a staff member at a traditional ryokan in Kyoto", "scene": "The learner checks in and asks about dinner and the bath.", "min": 2},
		{"id": "friend", "t": "친구와 반말로 수다", "who": "あかり", "role": "the learner's Japanese friend, chatting casually in plain form (タメ口)", "scene": "Talk about last weekend and plans.", "min": 3},
		{"id": "opinion", "t": "경험과 의견 말하기", "who": "なかむら", "role": "a friendly office worker in Fukuoka", "scene": "Ask about the learner's experiences in Japan or Korea and their opinions.", "min": 3},
	],
}
const GENERIC := [
	{"id": "month", "t": "이번 달 주제로", "who": "", "role": "", "scene": "", "min": 1},
	{"id": "free", "t": "자유 대화", "who": "", "role": "a friendly native speaker who is curious about the learner's life in Korea", "scene": "Casual conversation about anything.", "min": 1},
]

var lang: String = "en"
var status: String = "setup" # setup | wait | talk | fbwait | fb
var sel: Dictionary = {}
var sc: Dictionary = {}
var stage: int = 1
var month_n: int = 1
var week_n: int = 1
var msgs: Array = []
var conv_id: String = ""  ## one id per conversation; the OpenCode engine keeps one session per id
var err: String = ""
var fb: Dictionary = {}
var ko_open: Dictionary = {}
var stt_busy: bool = false

var _chat_call = null
var _stt_call = null
var _fb_call = null
var _serial: int = 0

var _setup_page: PageScroll
var _fb_page: PageScroll
var _chat_root: VBoxContainer
var _msg_scroll: PageScroll
var _head_title: Label
var _head_sub: Label
var _avatar_label: Label
var _end_btn: Button
var _aux: VBoxContainer
var _input: LineEdit
var _send: Button
var _mic: RecorderWidget
var _status_label: Label
var _tg: Container          ## phone: the four option toggles (folded behind "옵션 ▾")
var _opts_btn: Button
var _opts_open: bool = false
var _leave_msec: int = -100000


func _ready() -> void:
	var stack := Control.new()
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(stack)

	_setup_page = PageScroll.new(820.0)
	_setup_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_setup_page)
	_fb_page = PageScroll.new(720.0)
	_fb_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_fb_page)
	_build_chat_root(stack)

	lang = Store.lang()
	_reset_selection()
	Store.prefs_changed.connect(func() -> void:
		if status == "talk" or status == "wait":
			_render_msgs())
	_update_visibility()
	_render_setup()


func refresh() -> void:
	if status == "setup":
		lang = Store.lang()
		if sel.is_empty() or sel.get("lang", "") != lang:
			_reset_selection()
		_render_setup()


func on_hide() -> void:
	if _mic != null and is_instance_valid(_mic):
		_mic.stop_if_recording()


## Phone: with the keyboard up the suggestions and the option toggles make room for the text field,
## and the newest message stays in view.
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and Platform.is_phone() and _aux != null and _tg != null:
		var typing: bool = PhoneLayout.keyboard_height() > 0.0
		_aux.visible = not typing
		_opts_btn.visible = not typing
		_tg.visible = _opts_open and not typing
		if status == "talk" or status == "wait":
			UI.scroll_to_bottom(_msg_scroll)


## Android back button: out of the feedback / the chat, one step. A chat that already has my sentences
## asks for a second press (within 2 s) so a stray swipe does not throw the conversation away.
func go_back() -> bool:
	match status:
		"fb":
			status = "setup"
			msgs = []
			_reset_selection()
			_render_setup()
			return true
		"fbwait":
			_serial += 1
			if _fb_call != null:
				_fb_call.cancel()
				_fb_call = null
			status = "talk"
			_update_visibility()
			_render_msgs()
			_update_composer()
			return true
		"wait":
			_cancel_chat()
			return true
		"talk":
			var mine := 0
			for m in msgs:
				if m["role"] == "me":
					mine += 1
			var now: int = Time.get_ticks_msec()
			if mine > 0 and now - _leave_msec > 2000:
				_leave_msec = now
				Toast.info("지금 대화가 사라져요. 나가려면 한 번 더 눌러 주세요. 피드백은 '끝내기'에서 받아요.")
				return true
			_leave_msec = -100000
			_serial += 1
			if _stt_call != null:
				_stt_call.cancel()
				_stt_call = null
			stt_busy = false
			if _mic != null and is_instance_valid(_mic):
				_mic.stop_if_recording()
			status = "setup"
			msgs = []
			_update_visibility()
			_render_setup()
			return true
	return false


func _reset_selection() -> void:
	var p: Dictionary = Store.position()
	sel = {"lang": lang, "scen": "month", "stage": Plan.stage_of(int(p["n"])), "n": int(p["n"]), "w": int(p["w"])}


func scenes_for(l: String) -> Array:
	var all: Array = GENERIC.duplicate()
	all.append_array(SCENES[l])
	return all


func _update_visibility() -> void:
	_setup_page.visible = status == "setup"
	_fb_page.visible = status == "fb" or status == "fbwait"
	_chat_root.visible = status == "talk" or status == "wait"


# ---------------------------------------------------------------- setup screen

func _render_setup() -> void:
	_update_visibility()
	var c: VBoxContainer = _setup_page.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)

	var top := UI.adaptive(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		_reset_selection()
		err = ""
		_render_setup()))
	if not Platform.is_phone():
		top.add_child(UI.spacer())
	top.add_child(UI.label("대화 %d회" % Store.stat(lang, "talks"), "Muted", false))
	c.add_child(top)
	if err != "":
		var p := UI.tinted_panel(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
		p.add_child(UI.colored(err, Pal.BAD))
		c.add_child(p)

	var card := UI.card("BigCard", 16)
	card.body.add_child(UI.label("원어민 AI와 대화", "Eyebrow", false))
	card.body.add_child(UI.label("어떤 상황에서 말해 볼까요?", "H2"))

	var grid := GridContainer.new()
	grid.columns = 3 if size.x >= 900.0 else 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in scenes_for(lang):
		grid.add_child(_scenario_card(s))
	card.body.add_child(grid)

	var stage_names: Array = []
	var level_tags: Array = (["", "A2", "B1", "B1+", "B2"] if lang == "en" else ["", "N5", "N5~N4", "N4", "N3"])
	for s in [1, 2, 3, 4]:
		stage_names.append("%d단계 · %s" % [s, level_tags[s]])
	var so := UI.option_button(stage_names, int(sel["stage"]) - 1)
	so.item_selected.connect(func(i: int) -> void:
		sel["stage"] = i + 1
		_render_setup())
	var months: Array = Store.months(lang)
	var m_items: Array = []
	var m_sel := 0
	for i in months.size():
		m_items.append("%d개월차 · %s" % [int((months[i] as Dictionary)["n"]), UI.plain((months[i] as Dictionary)["title"])])
		if int((months[i] as Dictionary)["n"]) == int(sel["n"]):
			m_sel = i
	var mo := UI.option_button(m_items, m_sel)
	mo.item_selected.connect(func(i: int) -> void:
		sel["n"] = int((months[i] as Dictionary)["n"])
		sel["w"] = 1
		sel["stage"] = Plan.stage_of(int(sel["n"]))
		_render_setup())
	var fields := UI.adaptive(12)
	var f1 := UI.field("말하기 수준", so)
	f1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var f2 := UI.field("이번 달 주제 기준", mo)
	f2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_child(f1)
	fields.add_child(f2)
	card.body.add_child(fields)

	var opts := UI.vbox(4)
	opts.add_child(UI.pref_toggle("AI 말을 자동으로 소리 내어 읽기", "auto_speak"))
	opts.add_child(UI.pref_toggle("대화 중에 고친 문장 바로 보기", "show_fix"))
	if lang == "ja":
		opts.add_child(UI.pref_toggle("히라가나 읽기 표시", "show_reading"))
	opts.add_child(UI.pref_toggle("말하면 바로 보내기 (끄면 인식된 글자를 고친 뒤 직접 보내요)", "auto_send"))
	card.body.add_child(opts)

	var go := UI.button("대화 시작", "primary", acc, 52)
	go.pressed.connect(_start_chat)
	card.body.add_child(go)
	c.add_child(card)

	var tip := UI.tinted_panel(Pal.SUNK, Color(0, 0, 0, 0), 0, 10, 14, 12)
	tip.add_child(UI.label("말로 대화하는 법: 대화 화면의 마이크 버튼을 누른 채 말하거나(떼면 끝), 한 번 눌러 시작하고 다시 눌러 끝내요. 말한 내용이 글자로 바뀌어 AI에게 전달되고, AI의 답은 소리로 읽어 줘요. 처음에는 로컬 AI가 깨어나느라 답이 늦을 수 있어요.", "Muted"))
	c.add_child(tip)
	UI.fix_cjk(c)


func _scenario_card(s: Dictionary) -> Control:
	var acc: Color = Pal.accent(lang)
	var selected: bool = str(sel["scen"]) == str(s["id"])
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var normal := UI.style(acc.lerp(Color.WHITE, 0.92) if selected else Pal.SURFACE, acc if selected else Pal.LINE, 2 if selected else 1, 12, 14, 12)
	p.add_theme_stylebox_override("panel", normal)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		PhoneLayout.touch(p, 64.0)
	var v := UI.vbox(2)
	var t := UI.label(str(s["t"]), "Strong")
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(t)
	var sub := ""
	if s["id"] == "month":
		sub = UI.plain(Store.month_data(lang, int(sel["n"])).get("title", ""))
	elif s["id"] == "free":
		sub = "무엇이든 편하게"
	else:
		sub = str(s["who"])
		if int(s["min"]) > int(sel["stage"]):
			sub += " · %d단계 이상 추천" % int(s["min"])
	var sl := UI.label(sub, "Small")
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(sl)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var sid: String = str(s["id"])
	p.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			sel["scen"] = sid
			_render_setup())
	return p


# ---------------------------------------------------------------- chat screen (built once)

func _build_chat_root(parent: Control) -> void:
	_chat_root = VBoxContainer.new()
	_chat_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_chat_root.add_theme_constant_override("separation", 0)
	parent.add_child(_chat_root)

	# header
	var head_col := ColumnBox.new()
	head_col.max_width = 820.0
	head_col.set_padding(14, 8)
	var hrow := UI.hbox(12)
	var av := PanelContainer.new()
	av.custom_minimum_size = Vector2(42, 42)
	av.add_theme_stylebox_override("panel", UI.style(Pal.EN_SOFT, Color(0, 0, 0, 0), 0, 21, 0, 0))
	_avatar_label = Label.new()
	_avatar_label.theme_type_variation = &"H3"
	_avatar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	av.add_child(_avatar_label)
	hrow.add_child(av)
	var hc := UI.vbox(0)
	hc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_head_title = UI.label("", "Strong", false)
	_head_sub = UI.label("", "Small", false)
	if Platform.is_phone():
		for hl in [_head_title, _head_sub]:
			hl.clip_text = true
			hl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hc.add_child(_head_title)
	hc.add_child(_head_sub)
	hrow.add_child(hc)
	_end_btn = UI.button("끝내기" if Platform.is_phone() else "대화 끝내고 피드백", "default")
	_end_btn.pressed.connect(_end_chat)
	hrow.add_child(_end_btn)
	head_col.content.add_child(hrow)
	_chat_root.add_child(head_col)

	# messages
	_msg_scroll = PageScroll.new(820.0)
	_msg_scroll.content.add_theme_constant_override("separation", 14)
	_chat_root.add_child(_msg_scroll)

	# bottom area
	var bottom_panel := PanelContainer.new()
	bottom_panel.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
	_chat_root.add_child(bottom_panel)
	var bcol := ColumnBox.new()
	bcol.max_width = 820.0
	bcol.set_padding(10, 12)
	bottom_panel.add_child(bcol)
	var b: VBoxContainer = bcol.content
	b.add_theme_constant_override("separation", 8)

	_aux = UI.vbox(8)
	b.add_child(_aux)

	var comp := UI.hbox(8)
	_input = LineEdit.new()
	_input.placeholder_text = "말하거나 입력하기"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, 48)
	_input.text_submitted.connect(func(_t: String) -> void: _send_message())
	comp.add_child(_input)
	_mic = RecorderWidget.new(false, Pal.EN, false)
	_mic.idle_text = "말하기"
	_mic.recorded.connect(_on_recorded)
	if Platform.is_phone():
		_mic.wide = true # the phone's main input: a full-width button on its own line
	else:
		comp.add_child(_mic)
	_send = UI.button("보내기", "primary", Pal.EN, 48)
	_send.pressed.connect(_send_message)
	comp.add_child(_send)
	b.add_child(comp)
	if Platform.is_phone():
		b.add_child(_mic)

	_status_label = UI.label("", "Small", false)
	b.add_child(_status_label)

	var tg := UI.flow(16, 2)
	tg.add_child(UI.pref_toggle("자동 읽기", "auto_speak"))
	tg.add_child(UI.pref_toggle("번역 항상", "show_ko"))
	tg.add_child(UI.pref_toggle("교정 바로 보기", "show_fix"))
	tg.add_child(UI.pref_toggle("말하면 바로 보내기", "auto_send"))
	_tg = tg
	if Platform.is_phone():
		_opts_btn = UI.link_button("옵션 ▾")
		_opts_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		tg.visible = false
		_opts_btn.pressed.connect(func() -> void:
			_opts_open = not _opts_open
			tg.visible = _opts_open
			_opts_btn.text = "옵션 ▴" if _opts_open else "옵션 ▾")
		b.add_child(_opts_btn)
	b.add_child(tg)


func _who() -> String:
	var w: String = str(sc.get("who", ""))
	return w if w != "" else "AI"


func _update_header() -> void:
	var acc: Color = Pal.accent(lang)
	_head_title.text = str(sc.get("t", ""))
	_head_sub.text = "%s · %d단계 수준" % [_who(), stage]
	_avatar_label.text = _who().left(1)
	_avatar_label.add_theme_color_override("font_color", acc)
	var av := _avatar_label.get_parent() as PanelContainer
	av.add_theme_stylebox_override("panel", UI.style(Pal.soft(lang), Color(0, 0, 0, 0), 0, 21, 0, 0))
	UI.style_button(_send, "primary", acc)
	_mic.accent = acc
	_mic._refresh()


func _start_chat() -> void:
	var found: Dictionary = GENERIC[0]
	for s in scenes_for(lang):
		if str(s["id"]) == str(sel["scen"]):
			found = s
	sc = found
	stage = int(sel["stage"])
	month_n = int(sel["n"])
	week_n = int(sel["w"])
	msgs = []
	conv_id = "%d-%d" % [Time.get_ticks_usec(), randi()]
	err = ""
	fb = {}
	ko_open = {}
	_input.text = ""
	if lang == "ja":
		_input.add_theme_font_override("font", UI.ja_font())
	else:
		_input.remove_theme_font_override("font")
	_update_header()
	_call_chat()


func _persona() -> String:
	if sc["id"] == "month":
		return "a friendly native %s speaker (choose a natural name, job and city yourself)" % LNAME[lang]
	var who: String = str(sc.get("who", ""))
	return ("%s, %s" % [who, sc["role"]]) if who != "" else str(sc["role"])


func _scene_text() -> String:
	if sc["id"] == "month":
		return "Choose a concrete everyday situation that lets the learner practice this month's topic and this week's focus. Briefly set the scene in your first line."
	return str(sc["scene"])


func _history() -> Array:
	var h: Array = []
	var start: int = maxi(0, msgs.size() - 24)
	for i in range(start, msgs.size()):
		var m: Dictionary = msgs[i]
		if m["role"] == "ai":
			h.append({"role": "ai", "text": str(m["reply"])})
		else:
			h.append({"role": "me", "text": str(m["text"])})
	return h


func _call_chat() -> void:
	status = "wait"
	err = ""
	_serial += 1
	var serial: int = _serial
	_update_visibility()
	_render_msgs()
	_update_composer()
	var body := {
		"lang": lang, "stage": stage, "month": month_n, "week": week_n,
		"scenario": {"id": str(sc["id"]), "title": str(sc["t"]), "persona": _persona(), "scene": _scene_text()},
		"history": _history(),
		"skip_fix": true,
		"conv_id": conv_id,  # the correction comes from /fix afterwards, so the reply is not held up by it
		# the server starts synthesizing the reply as soon as it exists, at the user's speed and voice
		"tts_speed": Tts.normal_speed(), "tts_voice": Tts.voice_for(lang), "presynth": Store.pref_bool("auto_speak"),
	}
	_chat_call = Api.post_json("/chat", body, Api.TIMEOUT_LLM, true)
	var req = _chat_call
	var res: Dictionary = await req.wait()
	if serial != _serial or req != _chat_call:
		return
	_chat_call = null
	if res.get("cancelled", false):
		status = "talk" if not msgs.is_empty() else "setup"
	elif not res["ok"] or not (res["data"] is Dictionary) or str((res["data"] as Dictionary).get("reply", "")).strip_edges() == "":
		err = str(res["error"]) if not res["ok"] else "AI 답을 읽지 못했어요. 다시 시도해 주세요."
		status = "talk" if not msgs.is_empty() else "setup"
	else:
		_apply_reply(res["data"])
		status = "talk"
	_update_visibility()
	if status == "setup":
		_render_setup()
		return
	_render_msgs()
	_update_composer()


func _apply_reply(d: Dictionary) -> void:
	var last: Variant = msgs[msgs.size() - 1] if not msgs.is_empty() else null
	var fix: String = str(d.get("fix", "")).strip_edges()
	if last is Dictionary and (last as Dictionary)["role"] == "me" and fix != "":
		if TextSim.norm_text(fix, lang) != TextSim.norm_text(str((last as Dictionary)["text"]), lang):
			(last as Dictionary)["fix"] = fix
			(last as Dictionary)["fix_ko"] = str(d.get("fix_ko", ""))
			FixCards.add(lang, last as Dictionary, conv_id)
	var sugg: Array = []
	var raw: Variant = d.get("suggest", [])
	if raw is Array:
		for s in raw:
			if s is String and str(s).strip_edges() != "" and sugg.size() < 3:
				sugg.append(str(s))
	var reply: String = str(d["reply"]).strip_edges()
	msgs.append({
		"role": "ai", "reply": reply,
		"reading": str(d.get("reading", "")) if lang == "ja" else "",
		"ko": str(d.get("ko", "")), "suggest": sugg,
	})
	if Store.pref_bool("auto_speak"):
		var tts_chunks: Variant = d.get("tts_chunks", null)
		if tts_chunks is Array and not (tts_chunks as Array).is_empty():
			Tts.speak_chunks(tts_chunks, lang) # the chunks the server already pre-synthesized
		else:
			Tts.speak(reply, lang)
	if last is Dictionary and (last as Dictionary)["role"] == "me" and str((last as Dictionary).get("fix", "")) == "":
		var prev_ai: String = ""
		var i: int = msgs.size() - 3
		if i >= 0 and str(msgs[i]["role"]) == "ai":
			prev_ai = str(msgs[i]["reply"])
		_request_fix(last as Dictionary, prev_ai)


## Ask /fix for a correction of one of my messages and attach it when it arrives (a few seconds after the reply).
func _request_fix(m: Dictionary, prev_ai: String) -> void:
	var conv: Array = msgs
	var req = Api.post_json("/fix", {"lang": lang, "stage": stage, "text": str(m["text"]), "prev_ai": prev_ai}, Api.TIMEOUT_LLM, false)
	var res: Dictionary = await req.wait()
	if not is_same(conv, msgs) or not is_inside_tree():
		return  # a new conversation started meanwhile
	if not res["ok"] or not (res["data"] is Dictionary):
		return
	var fix: String = str((res["data"] as Dictionary).get("fix", "")).strip_edges()
	if fix == "" or TextSim.norm_text(fix, lang) == TextSim.norm_text(str(m["text"]), lang):
		return
	m["fix"] = fix
	m["fix_ko"] = str((res["data"] as Dictionary).get("fix_ko", ""))
	FixCards.add(lang, m, conv_id)
	if status == "talk" or status == "wait":
		_render_msgs()


func _send_message() -> void:
	var t: String = _input.text.strip_edges()
	if t == "" or status != "talk" or stt_busy:
		return
	msgs.append({"role": "me", "text": t})
	_input.text = ""
	_call_chat()


func _update_composer() -> void:
	var talk: bool = status == "talk"
	_input.editable = talk and not stt_busy
	_send.disabled = not talk or stt_busy
	_mic.set_enabled(talk and not stt_busy)
	_input.placeholder_text = ("%s로 말하거나 입력하기" % NAME_KO[lang]) if talk else "답을 기다리는 중…"
	var has_me := false
	for m in msgs:
		if m["role"] == "me":
			has_me = true
	_end_btn.disabled = not (talk and has_me)
	if stt_busy:
		_status_label.text = "말한 내용을 글자로 바꾸는 중…"
	else:
		_status_label.text = ""


# ---------------------------------------------------------------- voice input

func _on_recorded(result: Dictionary) -> void:
	if status != "talk" or stt_busy:
		return
	stt_busy = true
	_update_composer()
	var serial: int = _serial
	_stt_call = Api.post_json("/stt", {"lang": lang, "audio_b64": result["b64"]}, Api.TIMEOUT_SHORT, true)
	var req = _stt_call
	var res: Dictionary = await req.wait()
	stt_busy = false
	if req != _stt_call or serial != _serial:
		_update_composer()
		return
	_stt_call = null
	_update_composer()
	if not res["ok"] or not (res["data"] is Dictionary):
		return
	var text: String = str((res["data"] as Dictionary).get("text", "")).strip_edges()
	if text == "":
		Toast.info("잘 알아듣지 못했어요. 조금 더 크게, 또렷하게 다시 말해 주세요.")
		return
	_input.text = text
	if Store.pref_bool("auto_send"):
		_send_message()
	else:
		_input.grab_focus()
		_input.caret_column = text.length()


# ---------------------------------------------------------------- messages

func _render_msgs() -> void:
	var c: VBoxContainer = _msg_scroll.content
	UI.clear(c)
	var max_w: float = clampf(_msg_scroll.size.x * 0.72 - 40.0, 260.0, 620.0)
	if Platform.is_phone():
		var base_w: float = _msg_scroll.size.x if _msg_scroll.size.x >= 100.0 else maxf(size.x, PhoneLayout.W)
		max_w = clampf((base_w - 2.0 * PhoneLayout.PAD) * 0.86 - 28.0, 160.0, 620.0)
	for i in msgs.size():
		var m: Dictionary = msgs[i]
		if m["role"] == "me":
			c.add_child(_me_row(m, max_w))
		else:
			c.add_child(_ai_row(m, i, max_w))
	if status == "wait":
		var row := UI.hbox(10)
		row.add_child(UI.label("%s 입력 중…" % _who(), "Muted", false))
		var cancel := UI.link_button("취소")
		cancel.pressed.connect(_cancel_chat)
		row.add_child(cancel)
		c.add_child(row)
	if err != "":
		var p := UI.tinted_panel(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
		var h := UI.hbox(10)
		h.add_child(UI.colored(err, Pal.BAD))
		if not msgs.is_empty() and msgs[msgs.size() - 1]["role"] == "me":
			var retry := UI.button("다시 보내기", "outline", Pal.BAD)
			retry.pressed.connect(_call_chat)
			h.add_child(retry)
		p.add_child(h)
		c.add_child(p)
	_render_suggestions()
	UI.fix_cjk(c)
	UI.scroll_to_bottom(_msg_scroll)


func _cancel_chat() -> void:
	_serial += 1
	if _chat_call != null:
		_chat_call.cancel()
		_chat_call = null
	if msgs.is_empty():
		status = "setup"
		_update_visibility()
		_render_setup()
		return
	status = "talk"
	_render_msgs()
	_update_composer()


func _bubble(text: String, bg: Color, border: Color, fg: Color, max_w: float, radius_left_bottom: int, radius_right_bottom: int) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UI.style(bg, border, 1 if border.a > 0.0 else 0, 16, 14, 10)
	st.corner_radius_bottom_left = radius_left_bottom
	st.corner_radius_bottom_right = radius_right_bottom
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
	var bub := _bubble(str(m["reply"]), Pal.SURFACE, Pal.LINE, Pal.INK, max_w, 4, 16)
	if lang == "ja" and Store.pref_bool("show_reading") and str(m["reading"]) != "":
		var inner := bub.get_child(0) as Label
		bub.remove_child(inner)
		var v := UI.vbox(2)
		v.add_child(inner)
		var rd := UI.label(str(m["reading"]), "Small")
		rd.custom_minimum_size = Vector2(minf(UI.text_width(str(m["reading"]), 13) + 6.0, max_w), 0)
		v.add_child(rd)
		bub.add_child(v)
	col.add_child(bub)
	var always_ko: bool = Store.pref_bool("show_ko")
	var show_ko: bool = always_ko or bool(ko_open.get(i, false))
	if show_ko and str(m["ko"]) != "":
		var kl := UI.label(str(m["ko"]), "Muted")
		kl.custom_minimum_size = Vector2(minf(UI.text_width(str(m["ko"]), 15) + 6.0, max_w), 0)
		kl.size_flags_horizontal = Control.SIZE_FILL
		col.add_child(kl)
	var acts: Container = UI.flow(2, 0) if Platform.is_phone() else UI.hbox(2)
	acts.add_child(UI.speak_buttons(str(m["reply"]), lang))
	if not always_ko:
		var tb := UI.link_button("번역 숨기기" if show_ko else "번역")
		tb.pressed.connect(func() -> void:
			ko_open[i] = not bool(ko_open.get(i, false))
			_render_msgs())
		acts.add_child(tb)
	col.add_child(acts)
	row.add_child(col)
	return row


func _me_row(m: Dictionary, max_w: float) -> Control:
	var acc: Color = Pal.accent(lang)
	var row := UI.hbox(0)
	row.add_child(UI.spacer())
	var col := UI.vbox(6)
	col.size_flags_horizontal = Control.SIZE_SHRINK_END
	var bub := _bubble(str(m["text"]), acc, Color(0, 0, 0, 0), Color.WHITE, max_w, 16, 4)
	bub.size_flags_horizontal = Control.SIZE_SHRINK_END
	col.add_child(bub)
	if str(m.get("fix", "")) != "" and Store.pref_bool("show_fix"):
		var fx := UI.tinted_panel(Pal.OK_SOFT, Color(0, 0, 0, 0), 0, 10, 12, 8)
		fx.size_flags_horizontal = Control.SIZE_SHRINK_END
		var v := UI.vbox(2)
		var w: float = minf(maxf(UI.text_width(str(m["fix"]), 15), UI.text_width("더 자연스럽게 " + str(m["fix"]), 15)) + 6.0, max_w)
		var head := UI.colored("더 자연스럽게", Pal.OK, "Strong", false)
		v.add_child(head)
		var fl := UI.label(str(m["fix"]), "")
		fl.custom_minimum_size = Vector2(w, 0)
		fl.size_flags_horizontal = Control.SIZE_FILL
		v.add_child(fl)
		if str(m.get("fix_ko", "")) != "":
			var kl := UI.label(str(m["fix_ko"]), "Small")
			kl.custom_minimum_size = Vector2(minf(UI.text_width(str(m["fix_ko"]), 13) + 6.0, max_w), 0)
			kl.size_flags_horizontal = Control.SIZE_FILL
			v.add_child(kl)
		var sp := UI.speak_buttons(str(m["fix"]), lang)
		v.add_child(sp)
		fx.add_child(v)
		col.add_child(fx)
	row.add_child(col)
	return row


func _render_suggestions() -> void:
	UI.clear(_aux)
	if status != "talk" or msgs.is_empty():
		return
	var last: Dictionary = msgs[msgs.size() - 1]
	if last["role"] != "ai" or (last["suggest"] as Array).is_empty():
		return
	var acc: Color = Pal.accent(lang)
	_aux.add_child(UI.label("이렇게 말해 볼 수 있어요", "Eyebrow", false))
	var fl := UI.flow(6, 6)
	for s in last["suggest"]:
		var b := UI.button(str(s), "outline", acc)
		b.add_theme_font_size_override("font_size", 15)
		var txt: String = str(s)
		b.pressed.connect(func() -> void:
			_input.text = txt
			_input.grab_focus()
			_input.caret_column = txt.length())
		fl.add_child(b)
	_aux.add_child(fl)
	UI.fix_cjk(_aux)


# ---------------------------------------------------------------- feedback

func _end_chat() -> void:
	var mine := 0
	for m in msgs:
		if m["role"] == "me":
			mine += 1
	if mine == 0 or status != "talk":
		return
	status = "fbwait"
	err = ""
	_serial += 1
	var serial: int = _serial
	_update_visibility()
	_render_fb()
	var body := {"lang": lang, "stage": stage, "history": _history()}
	_fb_call = Api.post_json("/feedback", body, Api.TIMEOUT_LLM, true)
	var req = _fb_call
	var res: Dictionary = await req.wait()
	if serial != _serial or req != _fb_call:
		return
	_fb_call = null
	if res.get("cancelled", false) or not res["ok"] or not (res["data"] is Dictionary):
		status = "talk"
		err = str(res.get("error", ""))
		_update_visibility()
		_render_msgs()
		_update_composer()
		return
	fb = res["data"]
	var corr_items: Array = []
	var corrs: Variant = fb.get("corrections", [])
	if corrs is Array:
		for c in corrs:
			if c is Dictionary and str((c as Dictionary).get("better", "")) != "":
				var cd: Dictionary = c
				corr_items.append({"lang": lang, "target": cd["better"], "reading": cd.get("reading", ""), "ko": cd.get("ko", ""), "note": cd.get("why", "")})
	Store.add_review(corr_items)
	Store.add_xp(lang, 20 + mine * 2)
	Store.inc_stat(lang, "talks")
	Store.mark_today(lang)
	Store.save_progress()
	status = "fb"
	_update_visibility()
	_render_fb()


func _score_tile(value: int, caption: String) -> Control:
	var p := UI.tinted_panel(Pal.soft(lang), Color(0, 0, 0, 0), 0, 10, 14, 10)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := UI.vbox(0)
	var n := Label.new()
	n.text = "%d/5" % value
	n.add_theme_font_size_override("font_size", 26)
	n.add_theme_font_override("font", UI.bold_font())
	n.add_theme_color_override("font_color", Pal.accent(lang))
	v.add_child(n)
	v.add_child(UI.label(caption, "Small", false))
	p.add_child(v)
	return p


func _render_fb() -> void:
	var c: VBoxContainer = _fb_page.content
	UI.clear(c)
	var acc: Color = Pal.accent(lang)
	if status == "fbwait":
		var card := UI.card("BigCard", 14)
		card.body.add_child(UI.label("피드백", "Eyebrow", false))
		card.body.add_child(UI.label("대화를 돌아보는 중이에요", "H2"))
		card.body.add_child(UI.label("고칠 문장과 쓸 만한 표현을 정리하고 있어요. 보통 10~60초 걸려요.", "Muted"))
		var bar := ProgressBar.new()
		bar.indeterminate = true
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.add_theme_stylebox_override("fill", UI.style(acc, Color(0, 0, 0, 0), 0, 99, 0, 0))
		card.body.add_child(bar)
		var stop := UI.button("그만두기", "outline", acc)
		stop.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		stop.pressed.connect(func() -> void:
			_serial += 1
			if _fb_call != null:
				_fb_call.cancel()
				_fb_call = null
			status = "talk"
			_update_visibility()
			_render_msgs()
			_update_composer())
		card.body.add_child(stop)
		c.add_child(card)
		return

	var scores: Dictionary = fb.get("scores", {}) if fb.get("scores", {}) is Dictionary else {}
	var card := UI.card("BigCard", 14)
	card.body.add_child(UI.label("대화 피드백 · %s" % str(sc.get("t", "")), "Eyebrow", false))
	card.body.add_child(UI.label("오늘 대화 정리", "H2"))
	var sr := UI.hbox(8)
	for spec in [["유창성", "fluency"], ["정확성", "accuracy"], ["어휘", "vocabulary"]]:
		var v: int = clampi(int(float(scores.get(spec[1], 0))) if (scores.get(spec[1], 0) is float or scores.get(spec[1], 0) is int) else 0, 0, 5)
		sr.add_child(_score_tile(v, spec[0]))
	card.body.add_child(sr)
	card.body.add_child(UI.label(str(fb.get("summary", ""))))
	c.add_child(card)

	var corrs: Array = fb.get("corrections", []) if fb.get("corrections", []) is Array else []
	var shown_corr: Array = []
	for cc in corrs:
		if cc is Dictionary and str((cc as Dictionary).get("better", "")) != "":
			shown_corr.append(cc)
	if not shown_corr.is_empty():
		var cb := UI.card("BigCard", 10)
		cb.body.add_child(UI.label("고쳐 말하기 · 복습 목록에 추가됨", "Eyebrow", false))
		for cd in shown_corr:
			var d: Dictionary = cd
			var item := UI.tinted_panel(Pal.SURFACE, Pal.LINE, 1, 10, 12, 10)
			var iv := UI.vbox(3)
			if str(d.get("you", "")) != "":
				iv.add_child(UI.rich("[s][color=#B83A3A]%s[/color][/s]" % UI.bb_escape(str(d["you"])), 16))
			iv.add_child(UI.colored(str(d["better"]), Pal.OK, "Strong"))
			if lang == "ja" and str(d.get("reading", "")) != "":
				iv.add_child(UI.label(str(d["reading"]), "Small"))
			if str(d.get("ko", "")) != "":
				iv.add_child(UI.label(str(d["ko"]), "Muted"))
			if str(d.get("why", "")) != "":
				iv.add_child(UI.label(str(d["why"]), "Small"))
			iv.add_child(UI.speak_buttons(str(d["better"]), lang))
			item.add_child(iv)
			cb.body.add_child(item)
		c.add_child(cb)

	var phrases: Array = fb.get("phrases", []) if fb.get("phrases", []) is Array else []
	var shown_ph: Array = []
	for pp in phrases:
		if pp is Dictionary and str((pp as Dictionary).get("phrase", "")) != "":
			shown_ph.append(pp)
	if not shown_ph.is_empty():
		var pb := UI.card("BigCard", 10)
		pb.body.add_child(UI.label("이 상황에서 쓸 만한 표현", "Eyebrow", false))
		for pd in shown_ph:
			var d2: Dictionary = pd
			var item2 := UI.tinted_panel(Pal.SURFACE, Pal.LINE, 1, 10, 12, 10)
			var iv2 := UI.vbox(3)
			iv2.add_child(UI.label(str(d2["phrase"]), "Strong"))
			if lang == "ja" and str(d2.get("reading", "")) != "":
				iv2.add_child(UI.label(str(d2["reading"]), "Small"))
			if str(d2.get("ko", "")) != "":
				iv2.add_child(UI.label(str(d2["ko"]), "Muted"))
			iv2.add_child(UI.speak_buttons(str(d2["phrase"]), lang))
			item2.add_child(iv2)
			pb.body.add_child(item2)
		c.add_child(pb)

	var row := UI.hbox(8)
	var nw := UI.button("새 대화", "primary", acc, 50)
	nw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nw.pressed.connect(func() -> void:
		status = "setup"
		msgs = []
		_reset_selection()
		_render_setup())
	var rv := UI.button("복습하러 가기", "soft", acc, 50)
	rv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rv.pressed.connect(func() -> void:
		Store.navigate.emit("review", lang))
	row.add_child(nw)
	row.add_child(rv)
	c.add_child(row)
	UI.fix_cjk(c)
