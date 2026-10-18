class_name TodayView
extends AppView
## 오늘: progress overview, two language cards, settings.

## The phone's connection card asked for the connect screen (main.gd opens it).
signal connect_requested

const WD := ["일", "월", "화", "수", "목", "금", "토"]
const NATIVE := {"en": "English", "ja": "日本語"}
const NAME_KO := {"en": "영어", "ja": "일본어"}

var _scroll: PageScroll
var _grid: GridContainer
var _settings_open: bool = false
var _status_label: Label
var _status_dot: PanelContainer
var _llm_hint: Label
var _speed_label: Label
var _start_edit: LineEdit
var _start_msg: Label
var _confirm_row: BoxContainer
var _test_player: AudioStreamPlayer
var _built: bool = false
var _settings_btn: Button


func _ready() -> void:
	_scroll = PageScroll.new(1040.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	_test_player = AudioStreamPlayer.new()
	add_child(_test_player)
	Backend.status_changed.connect(_update_status)
	Store.curriculum_updated.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func refresh() -> void:
	if _scroll == null:
		return
	rebuild_keep_scroll(_scroll, _build)


## Phone: the status strip opens the settings card at the top of the page.
func open_settings() -> void:
	_settings_open = true
	refresh()
	if is_inside_tree():
		await get_tree().process_frame
		await get_tree().process_frame
		if _scroll != null and is_instance_valid(_scroll):
			_scroll.scroll_vertical = int(_settings_toggle_y())


func _settings_toggle_y() -> float:
	if _settings_btn == null or not is_instance_valid(_settings_btn):
		return 0.0
	return maxf(0.0, _settings_btn.global_position.y - _scroll.content.global_position.y - 8.0)


## Android back button: close the settings first.
func go_back() -> bool:
	if _settings_open:
		_settings_open = false
		refresh()
		return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _grid != null:
		_grid.columns = 2 if size.x >= 980.0 else 1


func _build() -> void:
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	var pos: Dictionary = Store.position()
	c.add_child(_hero(pos))
	c.add_child(GoalCard.compact(Store.lang()))
	_grid = GridContainer.new()
	_grid.columns = 2 if size.x >= 980.0 else 1
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(_grid)
	for l in ["en", "ja"]:
		_grid.add_child(_lang_card(l, pos))
	c.add_child(_settings_panel())
	UI.fix_cjk(c)
	_update_status()
	_built = true


# ---------------------------------------------------------------- hero

func _hero(pos: Dictionary) -> Control:
	var v := UI.vbox(8)
	var phase: String = pos["phase"]
	var start: String = Store.start_iso()
	if phase == "before":
		v.add_child(UI.label("시작까지", "Eyebrow", false))
		var line := UI.adaptive(14)
		var big := UI.label("D-%d" % int(pos["days"]), "Big", false)
		line.add_child(big)
		var s := UI.label("%s 시작 · 아래는 첫 주 미리보기예요. 레슨과 원어민 대화는 지금 바로 써 볼 수 있어요." % start.replace("-", "."), "Muted")
		s.size_flags_vertical = Control.SIZE_SHRINK_END
		line.add_child(s)
		v.add_child(line)
		v.add_child(UI.progress_bar(0.0, Pal.INK, 8.0))
	else:
		var n: int = pos["n"]
		var eyebrow := "1년 완주" if phase == "after" else "%d단계 · %d개월차 %d주차" % [Plan.stage_of(n), n, int(pos["w"])]
		v.add_child(UI.label(eyebrow, "Eyebrow", false))
		var total: int = Plan.total_days(start)
		var dn: int = mini(int(pos["day_no"]), total)
		var line := UI.hbox(10)
		line.add_child(UI.label("%d일째" % dn, "Big", false))
		var of := UI.label("/ %d일" % total, "Muted", false)
		of.size_flags_vertical = Control.SIZE_SHRINK_END
		line.add_child(of)
		v.add_child(line)
		v.add_child(UI.progress_bar(float(dn) / float(total), Pal.INK, 8.0))
	return v


# ---------------------------------------------------------------- language card

func _lang_card(l: String, pos: Dictionary) -> Control:
	var acc: Color = Pal.accent(l)
	var n: int = pos["n"]
	var w: int = pos["w"]
	var m: Dictionary = Store.month_data(l, n)
	var wk: Dictionary = Store.week_data(l, n, w)
	var card := UI.card("Card", 14)

	var head: Container = UI.hbox(8)
	if Platform.is_phone():
		head = UI.flow(8, 4) # the XP chip drops under the name when the card is narrow
	var nm := Label.new()
	nm.text = NATIVE[l]
	nm.theme_type_variation = &"H2"
	nm.add_theme_color_override("font_color", acc)
	head.add_child(nm)
	var ko := UI.label(NAME_KO[l], "Small", false)
	ko.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(ko)
	if not Platform.is_phone():
		head.add_child(UI.spacer())
	var st: int = StudyLog.streak(l)
	var chip_text := ("연속 %d일" % st) if st > 0 else "오늘부터 시작"
	head.add_child(UI.chip("%s · %d XP" % [chip_text, Store.xp(l)], acc, Pal.soft(l)))
	card.body.add_child(head)

	var where := UI.vbox(2)
	where.add_child(UI.label("%d개월차 · %s" % [n, str(wk.get("w", ""))], "Eyebrow", false))
	where.add_child(UI.label(UI.plain(m.get("title", "")), "H3"))
	card.body.add_child(where)

	var box := UI.tinted_panel(Pal.soft(l), Color(0, 0, 0, 0), 0, 10, 14, 12)
	var bv := UI.vbox(4)
	bv.add_child(UI.colored("이번 주", acc, "Small", false))
	bv.add_child(UI.label(UI.plain(wk.get("topic", "")), "Strong"))
	bv.add_child(UI.label(UI.plain(wk.get("act", "")), "Small"))
	box.add_child(bv)
	card.body.add_child(box)

	var btns := UI.hbox(8)
	var b1 := UI.button("오늘의 레슨", "primary", acc, 46)
	b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b1.pressed.connect(func() -> void: Store.navigate.emit("lesson", l))
	var b2 := UI.button("원어민과 대화", "soft", acc, 46)
	b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b2.pressed.connect(func() -> void: Store.navigate.emit("talk", l))
	btns.add_child(b1)
	btns.add_child(b2)
	card.body.add_child(btns)

	# FSRS: the button shows how many sentences are due now; hidden when nothing is due and nothing is stored.
	var due_n: int = Store.due_count(l)
	if due_n > 0 or not Store.review_for(l).is_empty():
		var rb := UI.button("복습 %d개" % due_n, "default")
		rb.pressed.connect(func() -> void: Store.navigate.emit("review", l))
		card.body.add_child(rb)

	var wi: int = 0
	var weeks: Array = m.get("weeks", [])
	for i in weeks.size():
		if weeks[i] == wk:
			wi = i
	var key: String = Store.check_key(l, n, "w", wi)
	card.body.add_child(UI.check_row("이번 주 활동 끝냄", Store.is_checked(key), func(on: bool) -> void:
		Store.set_checked(key, on)
		refresh()))

	var done: bool = Store.did_day(Plan.today_days(), l)
	var db := UI.button(("오늘 %s 완료함  ✓" % NAME_KO[l]) if done else ("오늘 %s 공부 완료" % NAME_KO[l]), "primary" if done else "outline", acc, 46)
	db.pressed.connect(func() -> void:
		Store.toggle_today(l)
		refresh())
	card.body.add_child(db)

	card.body.add_child(_week_dots(l))
	return card


const VOICE_SAMPLE := {
	"en": "Really? That sounds amazing! Where did you go?",
	"ja": "えっ、本当？すごいね！どこに行ったの？",
}


## One row of the voice settings: dropdown of the voices installed for `l` + a preview button.
func _voice_row(l: String) -> Control:
	var phone: bool = Platform.is_phone()
	var row: BoxContainer = UI.vbox(6) if phone else UI.hbox(12)
	var line: BoxContainer = row # phone: the dropdown and the preview button share a second line
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
	var pv := UI.button("미리 듣기", "default")
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


func _fill_voice_option(ob: OptionButton, l: String) -> void:
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


func _week_dots(l: String) -> Control:
	var acc: Color = Pal.accent(l)
	var row := UI.hbox(6)
	var today: int = Plan.today_days()
	var mon: int = Plan.monday_of(today)
	for i in 7:
		var d: int = mon + i
		var col := UI.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var dot := PanelContainer.new()
		var on: bool = Store.did_day(d, l)
		dot.add_theme_stylebox_override("panel", UI.style(acc if on else Pal.SUNK, Color(0, 0, 0, 0), 0, 4, 0, 0))
		dot.custom_minimum_size = Vector2(0, 8)
		col.add_child(dot)
		var wl := Label.new()
		wl.text = WD[Plan.weekday(d)]
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wl.add_theme_font_size_override("font_size", 12)
		wl.add_theme_color_override("font_color", Pal.INK if d == today else Pal.MUTED)
		if d == today:
			wl.add_theme_font_override("font", UI.bold_font())
		col.add_child(wl)
		row.add_child(col)
	return row


# ---------------------------------------------------------------- settings

func _settings_panel() -> Control:
	var wrap := UI.vbox(10)
	var toggle := UI.button(("설정  ▴" if _settings_open else "설정  ▾"), "default")
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_settings_btn = toggle
	toggle.pressed.connect(func() -> void:
		_settings_open = not _settings_open
		refresh())
	wrap.add_child(toggle)
	if not _settings_open:
		return wrap

	var card := UI.card("Card", 16)
	wrap.add_child(card)

	# phone: the connection to the PC comes first
	if Platform.is_phone():
		var rl := RemoteLinkPanel.new()
		rl.change_requested.connect(func() -> void: connect_requested.emit())
		_mount_link_panel(card, rl)

	# start date
	var sd := UI.vbox(6)
	sd.add_child(UI.label("시작일", "Strong"))
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
	var apply := UI.button("적용", "soft", Pal.INK)
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
	card.body.add_child(sd)
	card.body.add_child(UI.hline())

	# TTS speed
	var sp := UI.vbox(6)
	sp.add_child(UI.label("읽어주는 속도", "Strong"))
	var phone: bool = Platform.is_phone()
	var srow: BoxContainer = UI.adaptive(12) # phone: slider line, then the two listen buttons
	var sline: BoxContainer = srow
	if phone:
		sline = UI.hbox(12)
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
	var t1 := UI.button("영어 들어보기", "default")
	t1.pressed.connect(func() -> void:
		Store.set_pref("tts_speed", snappedf(slider.value, 0.05))
		Tts.speak("Hi! Nice to meet you. How was your weekend?", "en"))
	var t2 := UI.button("日本語 들어보기", "default")
	t2.pressed.connect(func() -> void:
		Store.set_pref("tts_speed", snappedf(slider.value, 0.05))
		Tts.speak("こんにちは。はじめまして。週末はどうでしたか。", "ja"))
	if phone:
		var tline := UI.hbox(8)
		t1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tline.add_child(t1)
		tline.add_child(t2)
		srow.add_child(tline)
	else:
		srow.add_child(t1)
		srow.add_child(t2)
	sp.add_child(srow)
	sp.add_child(UI.label("목소리", "Strong"))
	sp.add_child(_voice_row("en"))
	sp.add_child(_voice_row("ja"))
	sp.add_child(UI.label("연결한 PC에 설치된 목소리만 보여요. 바꾼 목소리는 바로 저장돼요." if phone else "이 PC에 설치된 목소리만 보여요. 바꾼 목소리는 바로 저장돼요.", "Small"))
	card.body.add_child(sp)
	card.body.add_child(UI.hline())

	# microphone
	var mic := UI.vbox(6)
	mic.add_child(UI.label("마이크", "Strong"))
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
	var test_row := UI.hbox(12)
	var rw := RecorderWidget.new(false, Pal.accent(Store.lang()), false)
	rw.idle_text = "테스트"
	rw.recorded.connect(_on_mic_test)
	test_row.add_child(rw)
	test_row.add_child(UI.label("눌러서 말하고 다시 눌러 끝내면 녹음한 소리를 들려줘요. 막대가 움직이면 마이크가 잘 들어오는 거예요.", "Small"))
	mic.add_child(test_row)
	card.body.add_child(mic)
	card.body.add_child(UI.hline())

	# backend status
	var be := UI.vbox(6)
	be.add_child(UI.label("PC 연결 상태" if Platform.is_phone() else "AI 엔진 상태", "Strong"))
	var brow: BoxContainer = UI.adaptive(8) # phone: the status text on its own line, the button under it
	var bline: BoxContainer = brow
	if Platform.is_phone():
		bline = UI.hbox(8)
		brow.add_child(bline)
	_status_dot = UI.tinted_panel(Pal.MUTED, Color(0, 0, 0, 0), 0, 99, 0, 0)
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bline.add_child(_status_dot)
	_status_label = UI.label("", "")
	bline.add_child(_status_label)
	var rb := UI.button("다시 확인", "default")
	rb.pressed.connect(func() -> void:
		if Backend.status == Backend.Status.READY:
			Backend.refresh_health()
		else:
			Backend.start())
	brow.add_child(rb)
	be.add_child(brow)
	_llm_hint = UI.colored("", Pal.WARN, "Small")
	be.add_child(_llm_hint)
	card.body.add_child(be)
	card.body.add_child(UI.hline())
	if not Platform.is_phone(): # the AI engine is a PC setting (the phone link may not change it)
		card.body.add_child(_engine_section())
		card.body.add_child(UI.hline())
		_mount_link_panel(card, PhoneLinkPanel.new())
	_mount_link_panel(card, SyncPanel.new()) # 1.2 learning-record sync (hidden while there is no SyncManager)

	# reset
	var rs := UI.vbox(6)
	var rrow: BoxContainer = UI.adaptive(8)
	var reset := UI.button("모든 기록 지우기", "outline", Pal.BAD)
	rrow.add_child(reset)
	_confirm_row = UI.adaptive(8)
	_confirm_row.visible = false
	var confirm_label := UI.label("정말 지울까요? 되돌릴 수 없어요.", "Small", false)
	_confirm_row.add_child(confirm_label)
	var yes := UI.button("지우기", "primary", Pal.BAD)
	yes.pressed.connect(func() -> void:
		await SyncPanel.before_reset()
		Store.reset_progress()
		_settings_open = false
		refresh())
	var no := UI.button("취소", "default")
	no.pressed.connect(func() -> void:
		_confirm_row.visible = false
		reset.visible = true)
	_confirm_row.add_child(yes)
	_confirm_row.add_child(no)
	reset.pressed.connect(func() -> void:
		SyncPanel.apply_reset_text(confirm_label)
		_confirm_row.visible = true
		reset.visible = false)
	rrow.add_child(_confirm_row)
	rs.add_child(rrow)
	if Platform.is_phone():
		rs.add_child(UI.label("이 휴대폰에 쌓인 기록만 지워져요. PC의 기록은 그대로예요.", "Small"))
	card.body.add_child(rs)
	return wrap


## Puts a connection panel (ui/remote_link_panel.gd, phone_link_panel.gd) and a divider into the settings
## card. Both stay hidden while the panel has no content yet.
func _mount_link_panel(card: CardBox, panel: Control) -> void:
	var sep := UI.hline()
	card.body.add_child(panel)
	card.body.add_child(sep)
	var sync := func() -> void:
		var has: bool = panel.get_child_count() > 0
		panel.visible = has
		sep.visible = has
	sync.call()
	panel.child_entered_tree.connect(func(_n: Node) -> void: sync.call())


func _apply_start() -> void:
	var t: String = _start_edit.text.strip_edges()
	if Store.set_start(t):
		_start_msg.text = ""
		refresh()
	else:
		_start_msg.text = "날짜 형식이 맞지 않아요 (예: 2026-11-01)"
		_start_msg.add_theme_color_override("font_color", Pal.BAD)


func _on_mic_test(result: Dictionary) -> void:
	var bytes: PackedByteArray = result.get("wav", PackedByteArray())
	var s: AudioStreamWAV = WavUtil.from_wav_bytes(bytes) if not bytes.is_empty() else null
	if s != null:
		_test_player.stream = s
		_test_player.play()


# ---------------------------------------------------------------- AI engine choice

var _engine_ob: OptionButton
var _engine_ids: Array = []
var _engine_note: Label


func _engine_section() -> Control:
	var box := UI.vbox(6)
	box.add_child(UI.label("AI 엔진", "Strong"))
	box.add_child(UI.label("레슨 만들기, 원어민 대화, 교정에 쓰는 AI예요. 음성 인식·발음 채점·목소리·문법 검사는 어느 쪽이든 이 PC에서 무료로 돌아가요.", "Small"))
	var row := UI.hbox(12)
	_engine_ob = UI.option_button(["불러오는 중…"], 0)
	_engine_ob.custom_minimum_size = Vector2(320, 0)
	_engine_ob.disabled = true
	_engine_ob.item_selected.connect(_on_engine_selected)
	row.add_child(_engine_ob)
	var tb := UI.button("연결 시험", "default")
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
