class_name SettingsView
extends AppView
## 설정: list-group sections (docs/ui_redesign_design.md §7.2). Section ids, top to bottom:
##   connection (PC link on the phone / phone link on the PC), engine (AI engine; the phone's future "처리 위치·모델·AI 연결"
##   slot, empty and hidden until something is mounted), learning, voice, display, sync (the SyncPanel), danger.
## `mount(section, control)` puts any panel into a section; a panel without children stays hidden (together with its
## divider, and the whole section when nothing in it shows).
##
## An AppView of its own (PageScroll + big "설정" title): `SettingsView.new()`; it mounts the link panels and the
## SyncPanel itself (`auto_panels`, on by default).

## RemoteLinkPanel's [연결 변경] was pressed (main.gd opens the connect screen).
signal connect_requested
## The start date changed (오늘 shows the new week).
signal start_changed
## "모든 기록 지우기" was confirmed and the record is wiped.
signal records_reset

const SECTIONS := [
	["connection", "연결"],
	["engine", "엔진"],
	["learning", "학습"],
	["voice", "소리"],
	["display", "화면"],
	["sync", "동기화"],
	["danger", "기록"],
]
const SCHEMES := [["system", "시스템"], ["light", "라이트"], ["dark", "다크"]]
const FONT_CHOICES := [[0.9, "작게 (90%)"], [1.0, "보통 (100%)"], [1.15, "조금 크게 (115%)"], [1.3, "크게 (130%)"], [1.5, "아주 크게 (150%)"]]
const VOICE_SAMPLE := {
	"en": "Really? That sounds amazing! Where did you go?",
	"ja": "えっ、本当？すごいね！どこに行ったの？",
}
const TXT_RESTART_PHONE := "다시 열면 적용돼요"
const TXT_RESTART_PC := "앱을 다시 시작하면 적용돼요"
const TXT_BAD_VALUE := "지원하지 않는 값이에요"
const TXT_DISPLAY_NOTE := "화면 모드와 글자 크기는 앱을 다시 열면 적용돼요."
const TXT_FONT_SAMPLE := "가나다라 ABC abc 123"

## Standalone: set to false before add_child() when the host mounts the panels itself.
var auto_panels: bool = true

var _body: VBoxContainer
var _secs: Dictionary = {} ## id -> {header, group, entries: [{wrap, div, panel}]}
var _scroll: PageScroll = null
var _header: Control = null

var _start_edit: LineEdit
var _start_msg: Label
var _speed_label: Label
var _status_label: Label
var _status_dot: PanelContainer
var _llm_hint: Label
var _test_player: AudioStreamPlayer
var _scheme_value: Label
var _font_value: Label
var _font_sample: Label
var _engine_ob: OptionButton
var _engine_ids: Array = []
var _engine_note: Label
var _reset_button: Button


func _init() -> void:
	super()
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 0)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in SECTIONS:
		var id: String = s[0]
		var header := ListGroup.header(String(s[1]))
		var group := ListGroup.new()
		group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.visible = false
		group.visible = false
		_body.add_child(header)
		_body.add_child(group)
		_secs[id] = {"header": header, "group": group, "entries": []}


func _ready() -> void:
	_scroll = PageScroll.new(720.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	_header = PageHeader.build("설정")
	_scroll.content.add_child(_header)
	_scroll.content.add_child(_body)
	_test_player = AudioStreamPlayer.new()
	add_child(_test_player)
	Backend.status_changed.connect(_update_status)
	if auto_panels:
		mount_default_panels() # first, so a link panel is the first entry of its section (as a host that mounts before add_child)
	_build_default_content()
	_relayout()
	UI.fix_cjk(_body)
	_update_status()
	bar_changed.emit()


# ---------------------------------------------------------------- app bar contract (standalone)

func page_title() -> String:
	return "설정"


func scroll_host() -> ScrollContainer:
	return _scroll


func header_block() -> Control:
	return _header if _header != null and is_instance_valid(_header) else null


func refresh() -> void:
	_update_status()
	_refresh_display_values()


# ---------------------------------------------------------------- mounting

func section_ids() -> Array:
	var out: Array = []
	for s in SECTIONS:
		out.append(String(s[0]))
	return out


## The section is on screen (it holds something that shows).
func section_visible(section: String) -> bool:
	return _secs.has(section) and (_secs[section]["group"] as Control).visible


## The section a mounted control sits in ("" when it was not mounted here).
func section_of(c: Control) -> String:
	var n: Node = c
	while n != null and n != self:
		for id in _secs.keys():
			for e in _secs[id]["entries"]:
				if e["wrap"] == n:
					return id
		n = n.get_parent()
	return ""


## Puts `c` into a section as a row of its own. Unknown section: a warning and it goes to the last one. A control
## without children stays hidden, with its divider, until it gets its first child (SyncPanel while there is no
## SyncManager, the link panels before their first answer).
func mount(section: String, c: Control) -> void:
	if c == null:
		return
	var id: String = section
	if not _secs.has(id):
		push_warning("SettingsView.mount: unknown section '%s', mounted in 'danger'" % section)
		id = String(SECTIONS[SECTIONS.size() - 1][0])
	var s: Dictionary = _secs[id]
	var g: ListGroup = s["group"]
	var before: int = g.body.get_child_count()
	g.add_custom(c)
	_record(s, g, before, c)
	var changed := func(_n: Node) -> void:
		_relayout()
	c.child_entered_tree.connect(changed)
	c.child_exiting_tree.connect(func(_n: Node) -> void: _relayout.call_deferred())
	_relayout()


## The panels the settings screen shows on its own (standalone): PC link on the phone, phone link on the PC, sync.
func mount_default_panels() -> void:
	if Platform.is_phone():
		var rl := RemoteLinkPanel.new()
		rl.change_requested.connect(func() -> void: connect_requested.emit())
		mount("connection", rl)
	else:
		mount("connection", PhoneLinkPanel.new())
	mount("sync", SyncPanel.new())


func _record(s: Dictionary, g: ListGroup, before: int, panel: Control) -> void:
	var n: int = g.body.get_child_count()
	if n <= before:
		return
	var div: Control = g.body.get_child(n - 2) if n - before >= 2 else null
	(s["entries"] as Array).append({"wrap": g.body.get_child(n - 1), "div": div, "panel": panel})


## Shows what has content: a mounted panel needs a child, a divider needs a visible row above it, a section needs a
## visible row.
func _relayout() -> void:
	for id in _secs.keys():
		var s: Dictionary = _secs[id]
		var seen := false
		var keep: Array = []
		for e in s["entries"]:
			var wrap: Control = e["wrap"]
			if not is_instance_valid(wrap):
				continue
			keep.append(e)
			var p: Control = e["panel"]
			var vis := true
			if p != null:
				vis = is_instance_valid(p) and p.get_child_count() > 0
				if is_instance_valid(p):
					p.visible = vis
			wrap.visible = vis
			var div: Control = e["div"]
			if div != null and is_instance_valid(div):
				div.visible = vis and seen
			seen = seen or vis
		s["entries"] = keep
		(s["header"] as Control).visible = seen
		(s["group"] as Control).visible = seen


func _group(id: String) -> ListGroup:
	return (_secs[id] as Dictionary)["group"]


func _add_row(sec: String, main: String, sub: String = "", trailing: Control = null, on_tap: Callable = Callable()) -> Control:
	var s: Dictionary = _secs[sec]
	var g: ListGroup = s["group"]
	var before: int = g.body.get_child_count()
	var row: Control = g.add_row(main, sub, trailing, on_tap)
	_record(s, g, before, null)
	return row


func _add_custom(sec: String, c: Control) -> void:
	var s: Dictionary = _secs[sec]
	var g: ListGroup = s["group"]
	var before: int = g.body.get_child_count()
	g.add_custom(c)
	_record(s, g, before, null)


func _add_switch(sec: String, main: String, key: String) -> void:
	var s: Dictionary = _secs[sec]
	var g: ListGroup = s["group"]
	var before: int = g.body.get_child_count()
	g.add_switch_row(main, "", key)
	_record(s, g, before, null)


# ---------------------------------------------------------------- default content

func _build_default_content() -> void:
	if Platform.is_phone():
		_build_status("connection", "PC 연결 상태")
	else:
		_build_status("engine", "AI 엔진 상태")
		_add_custom("engine", _engine_section())
	_add_custom("learning", _start_block())
	_add_custom("voice", _speed_block())
	_add_custom("voice", _voice_block())
	_add_custom("voice", _mic_block())
	_build_display()
	_build_danger()


# -------- learning

func _start_block() -> Control:
	var sd := UI.vbox(6)
	sd.add_child(UI.label("시작일", "ListMain"))
	var row := UI.hbox(8)
	_start_edit = LineEdit.new()
	_start_edit.text = Store.start_iso()
	_start_edit.placeholder_text = "YYYY-MM-DD"
	_start_edit.custom_minimum_size = Vector2(170, 0)
	if Platform.is_phone():
		_start_edit.custom_minimum_size = Vector2(0, 0)
		_start_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		PhoneLayout.touch(_start_edit)
	row.add_child(_start_edit)
	var apply := UI.button("적용", "soft", Pal.PRIMARY)
	apply.pressed.connect(_apply_start)
	_start_edit.text_submitted.connect(func(_t: String) -> void: _apply_start())
	row.add_child(apply)
	_start_msg = UI.label("", "Small", Platform.is_phone())
	if not Platform.is_phone():
		row.add_child(_start_msg)
	sd.add_child(row)
	if Platform.is_phone():
		sd.add_child(_start_msg)
	sd.add_child(UI.label("시작일을 바꾸면 오늘이 몇 개월차 몇 주차인지 다시 계산돼요. 체크한 기록은 그대로 남아요.", "Small"))
	return sd


func _apply_start() -> void:
	var t: String = _start_edit.text.strip_edges()
	if Store.set_start(t):
		_start_msg.text = ""
		start_changed.emit()
	else:
		_start_msg.text = "날짜 형식이 맞지 않아요 (예: 2026-11-01)"
		_start_msg.add_theme_color_override("font_color", Pal.BAD_ON)


# -------- voice

func _speed_block() -> Control:
	var phone: bool = Platform.is_phone()
	var sp := UI.vbox(6)
	sp.add_child(UI.label("읽어주는 속도", "ListMain"))
	var srow: Container = UI.adaptive(12) # phone: slider line, then the two listen buttons
	if not phone:
		srow = UI.flow(12, 8) # PC: one line while it fits, the listen buttons drop to a second line in a narrow window
	var sline: Container = UI.hbox(12) # the slider and its value stay together
	srow.add_child(sline)
	var slider := HSlider.new()
	slider.min_value = 0.6
	slider.max_value = 1.3
	slider.step = 0.05
	slider.value = clampf(float(Store.prefs.get("tts_speed", 1.0)), 0.6, 1.3)
	slider.custom_minimum_size = Vector2(240, 24)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	if phone:
		slider.custom_minimum_size = Vector2(120, 40)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sline.add_child(slider)
	_speed_label = UI.label("%.2f배" % slider.value, "Muted", false)
	_speed_label.custom_minimum_size = Vector2(60, 0)
	sline.add_child(_speed_label)
	slider.value_changed.connect(func(v: float) -> void:
		_speed_label.text = "%.2f배" % v)
	slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			Store.set_pref("tts_speed", snappedf(slider.value, 0.05)))
	var t1 := UI.button("영어 들어보기", "soft", Pal.PRIMARY)
	t1.pressed.connect(func() -> void:
		Store.set_pref("tts_speed", snappedf(slider.value, 0.05))
		Tts.speak("Hi! Nice to meet you. How was your weekend?", "en"))
	var t2 := UI.button("日本語 들어보기", "soft", Pal.PRIMARY)
	t2.pressed.connect(func() -> void:
		Store.set_pref("tts_speed", snappedf(slider.value, 0.05))
		Tts.speak("こんにちは。はじめまして。週末はどうでしたか。", "ja"))
	if phone:
		var tline := UI.flow(8, 8) # two buttons side by side; with large text the second one drops to its own line
		t1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tline.add_child(t1)
		tline.add_child(t2)
		srow.add_child(tline)
	else:
		srow.add_child(t1)
		srow.add_child(t2)
	sp.add_child(srow)
	return sp


func _voice_block() -> Control:
	var phone: bool = Platform.is_phone()
	var v := UI.vbox(6)
	v.add_child(UI.label("목소리", "ListMain"))
	v.add_child(voice_row("en"))
	v.add_child(voice_row("ja"))
	v.add_child(UI.label("연결한 PC에 설치된 목소리만 보여요. 바꾼 목소리는 바로 저장돼요." if phone else "이 PC에 설치된 목소리만 보여요. 바꾼 목소리는 바로 저장돼요.", "Small"))
	return v


## One row of the voice settings: dropdown of the voices installed for `l` + a preview button.
static func voice_row(l: String) -> Control:
	var phone: bool = Platform.is_phone()
	var row: Container = UI.vbox(6) if phone else UI.flow(12, 8) # PC: wraps in a narrow window
	var line: Container = row # phone: the dropdown and the preview button share a second line
	var cap := UI.label("영어" if l == "en" else "일본어", "Muted", false)
	if not phone:
		cap.custom_minimum_size = Vector2(60, 0)
	row.add_child(cap)
	if phone:
		line = UI.hbox(8)
		row.add_child(line)
	var ob := UI.option_button([], -1)
	if phone:
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		ob.custom_minimum_size = Vector2(260, 0)
	_fill_voice_option(ob, l)
	ob.item_selected.connect(func(idx: int) -> void:
		Store.set_pref("tts_voice_" + l, str(ob.get_item_metadata(idx))))
	line.add_child(ob)
	var pv := UI.button("미리 듣기", "soft", Pal.PRIMARY)
	pv.pressed.connect(func() -> void:
		if ob.selected >= 0:
			Tts.speak(str(VOICE_SAMPLE[l]), l, false, str(ob.get_item_metadata(ob.selected))))
	line.add_child(pv)
	if Tts.voices.is_empty():
		Tts.voices_loaded.connect(func() -> void:
			if is_instance_valid(ob):
				_fill_voice_option(ob, l), CONNECT_ONE_SHOT)
		Tts.load_voices()
	return row


static func _fill_voice_option(ob: OptionButton, l: String) -> void:
	ob.clear()
	var saved: String = Tts.voice_for(l)
	var sel := 0
	var lst: Array = Tts.voices_for(l)
	for i in lst.size():
		var v: Dictionary = lst[i]
		ob.add_item(Tts.voice_label(v))
		ob.set_item_metadata(i, str(v["id"]))
		if str(v["id"]) == saved:
			sel = i
	ob.select(sel)


func _mic_block() -> Control:
	var mic := UI.vbox(6)
	mic.add_child(UI.label("마이크", "ListMain"))
	if not Platform.is_phone(): # the phone has one microphone: only the test below
		var devs := Recorder.input_devices()
		var names: Array = []
		var sel := 0
		var cur: String = str(Store.prefs.get("mic_device", "Default"))
		for i in devs.size():
			names.append(devs[i])
			if devs[i] == cur:
				sel = i
		var ob := UI.option_button(names, sel)
		ob.custom_minimum_size = Vector2(320, 0)
		ob.item_selected.connect(func(idx: int) -> void:
			var dn: String = ob.get_item_text(idx)
			Store.set_pref("mic_device", dn)
			Recorder.apply_device(dn))
		var mrow := UI.hbox(12)
		mrow.add_child(ob)
		mic.add_child(mrow)
	var test_row: BoxContainer = UI.adaptive(12) # phone: the hint under the button (beside it, large text pushes the page wider)
	var rw := RecorderWidget.new(false, Pal.accent(Store.lang()), false)
	rw.idle_text = "테스트"
	rw.recorded.connect(_on_mic_test)
	test_row.add_child(rw)
	test_row.add_child(UI.label("눌러서 말하고 다시 눌러 끝내면 녹음한 소리를 들려줘요. 막대가 움직이면 마이크가 잘 들어오는 거예요.", "Small"))
	mic.add_child(test_row)
	return mic


func _on_mic_test(result: Dictionary) -> void:
	var bytes: PackedByteArray = result.get("wav", PackedByteArray())
	var s: AudioStreamWAV = WavUtil.from_wav_bytes(bytes) if not bytes.is_empty() else null
	if s != null and _test_player != null and is_instance_valid(_test_player):
		_test_player.stream = s
		_test_player.play()


# -------- display (screen mode, text size, hangul line)

func _build_display() -> void:
	_scheme_value = UI.label("", "Muted", false)
	_add_row("display", "화면 모드", "", _value_trailing(_scheme_value), _pick_scheme)
	_font_value = UI.label("", "Muted", false)
	_add_row("display", "글자 크기", "", _value_trailing(_font_value), _pick_font)
	_font_sample = UI.label(TXT_FONT_SAMPLE, "", false)
	_font_sample.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_add_custom("display", _font_sample)
	_add_switch("display", "한글 발음 표시", "show_hangul_ja")
	_add_custom("display", UI.label(TXT_DISPLAY_NOTE, "ListSub"))
	_refresh_display_values()


func _value_trailing(value: Label) -> Control:
	var t := HBoxContainer.new()
	t.add_theme_constant_override("separation", 4)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.add_child(value)
	var chev := GlyphIcon.new("chevron_right", 20.0, Pal.MUTED)
	chev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.add_child(chev)
	return t


## The saved screen mode ("system" | "light" | "dark"); anything else reads as "system" (like UiBoot).
static func saved_scheme() -> String:
	var v: Variant = Store.prefs.get("scheme", "system")
	if typeof(v) == TYPE_STRING and valid_scheme(v):
		return String(v)
	return "system"


static func saved_font_scale() -> float:
	return Ds.sanitize_scale(Store.prefs.get("font_scale", 1.0))


static func valid_scheme(v: Variant) -> bool:
	if typeof(v) != TYPE_STRING:
		return false
	for s in SCHEMES:
		if String(s[0]) == String(v):
			return true
	return false


## One of Ds.SCALES (0.9 / 1.0 / 1.15 / 1.3 / 1.5); a number only, no rounding to the nearest.
static func valid_font_scale(v: Variant) -> bool:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return false
	var f: float = float(v)
	if is_nan(f) or is_inf(f):
		return false
	for s in Ds.SCALES:
		if is_equal_approx(f, float(s)):
			return true
	return false


## Saves the screen mode. A value that is not offered is not saved and says so in a toast. Returns whether it was saved.
func save_scheme(v: Variant) -> bool:
	if not valid_scheme(v):
		Toast.error(TXT_BAD_VALUE)
		return false
	var changed: bool = saved_scheme() != String(v) or not Store.prefs.has("scheme")
	Store.set_pref("scheme", String(v))
	_refresh_display_values()
	if changed:
		Toast.info(TXT_RESTART_PHONE if Platform.is_phone() else TXT_RESTART_PC)
	return true


func save_font_scale(v: Variant) -> bool:
	if not valid_font_scale(v):
		Toast.error(TXT_BAD_VALUE)
		return false
	var f: float = float(v)
	var changed: bool = not is_equal_approx(saved_font_scale(), f) or not Store.prefs.has("font_scale")
	Store.set_pref("font_scale", f)
	_refresh_display_values()
	if changed:
		Toast.info(TXT_RESTART_PHONE if Platform.is_phone() else TXT_RESTART_PC)
	return true


func _pick_scheme() -> void:
	var sh := Sheet.choice(self, "화면 모드", SCHEMES, saved_scheme())
	sh.closed.connect(func(v: Variant) -> void:
		if valid_scheme(v):
			save_scheme(v))


func _pick_font() -> void:
	var sh := Sheet.choice(self, "글자 크기", FONT_CHOICES, str(saved_font_scale()))
	sh.closed.connect(func(v: Variant) -> void:
		if typeof(v) == TYPE_FLOAT:
			save_font_scale(v))


func _refresh_display_values() -> void:
	if _scheme_value == null or not is_instance_valid(_scheme_value):
		return
	var cur: String = saved_scheme()
	for s in SCHEMES:
		if String(s[0]) == cur:
			_scheme_value.text = String(s[1])
	var fs: float = saved_font_scale()
	var name := "보통"
	for c in FONT_CHOICES:
		if is_equal_approx(float(c[0]), fs):
			name = String(c[1]).split(" (")[0]
	if is_equal_approx(fs, 0.9):
		name = "작게"
	_font_value.text = name
	# a sample at the saved size: what the app will look like the next time it is opened
	_font_sample.add_theme_font_size_override("font_size", maxi(Ds.MIN_FONT, int(roundf(float(Ds.type_size("")) * fs))))


# -------- connection / engine status

func _build_status(sec: String, title: String) -> void:
	var rb := UI.button("다시 확인", "soft", Pal.PRIMARY)
	rb.pressed.connect(func() -> void:
		if Backend.status == Backend.Status.READY:
			Backend.refresh_health()
		else:
			Backend.start())
	_add_row(sec, title, "", rb)
	var be := UI.vbox(6)
	var line := UI.hbox(8)
	_status_dot = UI.tinted_panel(Pal.MUTED, Color(0, 0, 0, 0), 0, 99, 0, 0)
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(_status_dot)
	_status_label = UI.label("", "")
	line.add_child(_status_label)
	be.add_child(line)
	_llm_hint = UI.colored("", Pal.WARN_ON, "Small")
	be.add_child(_llm_hint)
	_add_custom(sec, be)


func _update_status() -> void:
	if _status_label == null or not is_instance_valid(_status_label):
		return
	var dot_color: Color = Pal.MUTED
	var text := ""
	var hint := ""
	match Backend.status:
		Backend.Status.READY:
			var h: Dictionary = Backend.health
			var tts: Dictionary = h.get("tts", {}) if h.get("tts", {}) is Dictionary else {}
			var parts: Array[String] = ["연결됨"]
			parts.append("음성 인식 " + ("✓" if h.get("stt", false) else "✗"))
			parts.append("영어 음성 " + ("✓" if tts.get("en", false) else "✗"))
			parts.append("일본어 음성 " + ("✓" if tts.get("ja", false) else "✗"))
			parts.append("채점 " + ("✓" if h.get("score", false) else "✗"))
			var llm_ok: bool = bool(h.get("llm", false))
			var llm_name: String = str(h.get("llm_model", "")) if Backend.llm_provider() == "ollama" else Backend.llm_label()
			parts.append("AI %s %s" % [llm_name, "✓" if llm_ok else "✗"])
			text = " · ".join(parts)
			dot_color = Pal.OK if llm_ok else Pal.WARN
			if not llm_ok:
				hint = Backend.llm_missing_text()
			elif h.get("llm_fallback") is Dictionary and bool((h["llm_fallback"] as Dictionary).get("active", false)):
				hint = str((h["llm_fallback"] as Dictionary).get("reason", ""))  # e.g. limit reached -> local AI answers
		Backend.Status.FAILED:
			text = Backend.message
			dot_color = Pal.BAD
		_:
			text = Backend.message if Backend.message != "" else "확인 중…"
			dot_color = Pal.WARN
	_status_label.text = text
	_status_dot.add_theme_stylebox_override("panel", UI.style(dot_color, Color(0, 0, 0, 0), 0, 99, 0, 0))
	if _llm_hint != null and is_instance_valid(_llm_hint):
		_llm_hint.text = hint


# -------- AI engine choice (PC)

func _engine_section() -> Control:
	var box := UI.vbox(6)
	box.add_child(UI.label("AI 엔진", "ListMain"))
	box.add_child(UI.label("레슨 만들기, 원어민 대화, 교정에 쓰는 AI예요. 음성 인식·발음 채점·목소리·문법 검사는 어느 쪽이든 이 PC에서 무료로 돌아가요.", "Small"))
	var row := UI.flow(12, 8) # the test button drops to a second line in a narrow window
	_engine_ob = UI.option_button(["불러오는 중…"], 0)
	_engine_ob.custom_minimum_size = Vector2(320, 0)
	_engine_ob.disabled = true
	_engine_ob.item_selected.connect(_on_engine_selected)
	row.add_child(_engine_ob)
	var tb := UI.button("연결 시험", "soft", Pal.PRIMARY)
	tb.pressed.connect(_on_engine_test)
	row.add_child(tb)
	box.add_child(row)
	_engine_note = UI.label("", "Small")
	box.add_child(_engine_note)
	_load_engines()
	return box


func _load_engines() -> void:
	var req = Api.get_json("/llm", 10.0, false)
	var res: Dictionary = await req.wait()
	if _engine_ob == null or not is_instance_valid(_engine_ob):
		return
	if not res["ok"] or not (res["data"] is Dictionary):
		_engine_ob.set_item_text(0, "AI 엔진 목록을 불러오지 못했어요")
		return
	var d: Dictionary = res["data"]
	_engine_ob.clear()
	_engine_ids = []
	var sel := 0
	for o in d.get("options", []):
		var od: Dictionary = o
		var id: String = str(od.get("id", ""))
		if id != "opencode" and id != "ollama":  # the app offers exactly these two engines
			continue
		var label: String = str(od.get("label", id))
		if not bool(od.get("available", false)):
			label += " · 설치 안 됨"
		_engine_ob.add_item(label)
		_engine_ids.append(id)
		if id == str(d.get("provider", "opencode")):
			sel = _engine_ids.size() - 1
	_engine_ob.select(sel)
	_engine_ob.disabled = false
	_engine_note.text = _engine_note_text(str(d.get("provider", "opencode")))
	var fb = d.get("llm_fallback", {})
	if fb is Dictionary and bool((fb as Dictionary).get("active", false)) and str((fb as Dictionary).get("reason", "")) != "":
		_engine_note.text += "\n" + str((fb as Dictionary)["reason"])  # e.g. "AI 엔진을 쓸 수 없어요: …" when no AI answers at all
	UI.fix_cjk(_engine_ob)


func _engine_note_text(p: String) -> String:
	if p == "ollama":
		return "인터넷 없이 이 PC에서만 돌아가요. 무료이지만 작은 모델이라 가끔 어색한 답이나 애매한 문제가 나와요."
	return "무료 DeepSeek V4.1 Flash를 OpenCode로 써요. 대화 한 턴에 3~4초쯤 걸리고, 쓸 수 없을 때는 자동으로 오프라인 로컬 AI가 대신 답해요."


func _on_engine_selected(idx: int) -> void:
	if idx < 0 or idx >= _engine_ids.size():
		return
	var p: String = _engine_ids[idx]
	_engine_ob.disabled = true
	var req = Api.post_json("/llm", {"provider": p}, 15.0, true)
	var res: Dictionary = await req.wait()
	if _engine_ob == null or not is_instance_valid(_engine_ob):
		return
	_engine_ob.disabled = false
	if res["ok"]:
		Toast.ok("AI 엔진을 %s(으)로 바꿨어요." % str(Backend.LLM_LABELS.get(p, p)))
		_engine_note.text = _engine_note_text(p)
		Backend.refresh_health()
	else:
		_load_engines()


func _on_engine_test() -> void:
	_engine_note.text = "연결을 시험하는 중이에요…"
	var req = Api.post_json("/llm/test", {}, 120.0, false)
	var res: Dictionary = await req.wait()
	if _engine_note == null or not is_instance_valid(_engine_note):
		return
	if res["ok"] and res["data"] is Dictionary:
		_engine_note.text = "연결 성공 · %s · %.1f초 걸렸어요." % [Backend.llm_label(), float((res["data"] as Dictionary).get("seconds", 0.0))]
	else:
		_engine_note.text = "연결 실패: " + str(res["error"])


# -------- danger: wipe the record

func _build_danger() -> void:
	var rs := UI.vbox(8)
	_reset_button = UI.button("모든 기록 지우기", "soft", Pal.BAD)
	_reset_button.pressed.connect(_ask_reset)
	rs.add_child(_reset_button)
	if Platform.is_phone():
		rs.add_child(UI.label("이 휴대폰에 쌓인 기록만 지워져요. PC의 기록은 그대로예요.", "Small"))
	_add_custom("danger", rs)


## The confirmation is a danger sheet. Nothing is touched until [지우기]; then the sync link is cut first (and a running
## sync round is waited for), and only after that the record is wiped.
func _ask_reset() -> void:
	var sh := Sheet.confirm(self, "모든 기록 지우기", SyncPanel.reset_confirm_text(), "지우기", true, "취소")
	sh.closed.connect(func(r: Variant) -> void:
		if typeof(r) == TYPE_STRING and String(r) == "ok":
			_reset_records())


func _reset_records() -> void:
	await SyncPanel.before_reset()
	Store.reset_progress()
	records_reset.emit()
