class_name RecorderWidget
extends HBoxContainer
## Record button + timer + level meter.
##
## Interaction: press = start; release after a long hold (>= 0.45 s) = stop (push-to-talk);
## a short click keeps recording until the next click (toggle). Optionally hold Space.
## Emits `recorded(result)` with result.b64 (WAV base64) and result.duration.
##
## Three states, told apart by text, shape and colour (never colour alone):
##   idle      accent fill, "● <idle_text>"
##   recording BAD fill, "■ 멈추기" (small: "■ 멈춤"), timer + level bar (OK fill on a SUNK track)
##   busy      the widget is disabled (set_enabled(false), e.g. while the answer is scored) or the recorder is
##             closing the file: disabled look and `busy_text`
## Sizes: phone = a full-width 56 px button; PC = Ds.REC_BIG_PC (190x58) / Ds.REC_SMALL_PC (96x44), which
## phone_layout_test asserts. The touch behaviour is unchanged (see _notification).

signal recorded(result: Dictionary)
signal state_changed(is_recording: bool)

const HOLD_MSEC := 450

var big: bool = true
var accent: Color = Pal.EN
var use_space: bool = false
var idle_text: String = "녹음 시작"
## Text of the disabled (busy) state. A screen that disables the widget for another reason sets its own.
var busy_text: String = "채점 중…"
## Phone: a small widget as a full-width 56 px button (talk chat). Set before the widget enters the tree.
var wide: bool = false

var _btn: Button
var _time_label: Label
var _meter: ProgressBar
var _enabled: bool = true
var _press_msec: int = 0
var _swallow_release: bool = false
var _btn_down: bool = false ## the button is held and this widget started the recording with that press
var _space_started: bool = false
var _was_recording: bool = false


func _init(is_big: bool = true, accent_color: Color = Pal.EN, space: bool = false) -> void:
	big = is_big
	accent = accent_color
	use_space = space and not Platform.is_phone() # no keyboard on the phone
	add_theme_constant_override("separation", 14)


func _ready() -> void:
	_btn = Button.new()
	_btn.focus_mode = Control.FOCUS_NONE
	_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn.custom_minimum_size = Ds.REC_BIG_PC if big else Ds.REC_SMALL_PC
	var phone: bool = Platform.is_phone()
	var full: bool = big or wide
	if phone:
		_btn.custom_minimum_size = Vector2(0.0 if full else 96.0, maxf(56.0, Ds.touch_min()) if full else PhoneLayout.BTN_H)
		_btn.size_flags_horizontal = Control.SIZE_FILL if full else Control.SIZE_SHRINK_BEGIN
	_btn.button_down.connect(_on_down)
	_btn.button_up.connect(_on_up)
	if not phone:
		add_child(_btn)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_time_label = Label.new()
	_time_label.theme_type_variation = &"Muted"
	col.add_child(_time_label)
	_meter = UI.progress_bar(0.0, Pal.OK, 8.0)
	_meter.add_theme_stylebox_override("background", UI.style(Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_PILL, 0, 0))
	_meter.custom_minimum_size = Vector2(130, 8)
	_meter.size_flags_horizontal = Control.SIZE_FILL
	col.add_child(_meter)
	if phone:
		# vertical: the button over the timer and the level bar, each as wide as the screen allows
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 6)
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_time_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_meter.custom_minimum_size = Vector2(0, 8)
		_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_child(_btn)
		vb.add_child(col)
		add_child(vb)
	else:
		# PC: the hint may wrap inside the column (an unbreakable line at a large text size was wider than the page)
		_time_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(col)
	Recorder.finished.connect(_on_finished)
	_refresh()


func set_enabled(on: bool) -> void:
	_enabled = on
	_refresh()


func is_mine_recording() -> bool:
	return Recorder.recording and Recorder.owner_id == get_instance_id()


func stop_if_recording() -> void:
	if is_mine_recording():
		Recorder.cancel()
		_refresh()


func _exit_tree() -> void:
	if is_mine_recording():
		Recorder.cancel()


func _process(_delta: float) -> void:
	var rec: bool = is_mine_recording()
	if _btn != null and _btn.disabled != (not _enabled or Recorder.stopping):
		_refresh()
	if rec != _was_recording:
		_was_recording = rec
		_refresh()
		state_changed.emit(rec)
	if rec:
		var t: int = int(Recorder.elapsed)
		_time_label.text = "녹음 중  %d:%02d / 0:%02d" % [t / 60, t % 60, int(Recorder.MAX_SECONDS)]
		_meter.value = Recorder.level
	elif _meter.value != 0.0:
		_meter.value = 0.0


## "recording" | "busy" | "idle" (what the button shows now).
func state_name() -> String:
	if is_mine_recording():
		return "recording"
	if not _enabled or Recorder.stopping:
		return "busy"
	return "idle"


func _refresh() -> void:
	if _btn == null:
		return
	var rec: bool = is_mine_recording()
	var busy: bool = not rec and (not _enabled or Recorder.stopping)
	if rec:
		_btn.text = "■ 멈추기" if big else "■ 멈춤"
		UI.style_button(_btn, "primary", Pal.BAD)
	elif busy:
		_btn.text = busy_text
		UI.style_button(_btn, "primary", accent)
	else:
		_btn.text = "● " + idle_text
		UI.style_button(_btn, "primary", accent)
	_btn.disabled = not _enabled or Recorder.stopping
	_time_label.visible = rec or big
	_meter.visible = rec or big
	if not rec:
		_time_label.text = "눌러서 시작, 다시 눌러서 끝 (누른 채로도 가능)" if big else ""
		if big and use_space:
			_time_label.text = "눌러서 시작/끝 · 스페이스바를 누르고 있어도 돼요"
		_time_label.visible = big
		_meter.visible = big


func _on_down() -> void:
	if not _enabled:
		return
	if is_mine_recording():
		_swallow_release = true
		Recorder.end()
		return
	if Recorder.recording:
		return
	if Recorder.begin(get_instance_id()):
		_press_msec = Time.get_ticks_msec()
		_swallow_release = false
		_btn_down = true


## Phone: a page scroll that starts on the record button (ScrollContainer sends SCROLL_BEGIN once the finger leaves
## its dead zone) must not leave a recording behind: a press that is still short (before the push-to-talk hold)
## and began this recording is cancelled, nothing is saved or scored. A long hold keeps its push-to-talk meaning.
func _notification(what: int) -> void:
	if what == NOTIFICATION_SCROLL_BEGIN and Platform.is_phone() and _btn_down:
		_btn_down = false
		if is_mine_recording() and Time.get_ticks_msec() - _press_msec < HOLD_MSEC:
			Recorder.cancel()
			_swallow_release = false
			_refresh()


func _on_up() -> void:
	_btn_down = false
	if _swallow_release:
		_swallow_release = false
		return
	if is_mine_recording() and Time.get_ticks_msec() - _press_msec >= HOLD_MSEC:
		Recorder.end()


func _input(event: InputEvent) -> void:
	if not use_space or not _enabled or not is_visible_in_tree():
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.keycode != KEY_SPACE or k.echo:
		return
	var fo := get_viewport().gui_get_focus_owner()
	if fo is LineEdit or fo is TextEdit:
		return
	if k.pressed:
		if is_mine_recording():
			Recorder.end()
			_space_started = false
		elif not Recorder.recording and Recorder.begin(get_instance_id()):
			_space_started = true
		get_viewport().set_input_as_handled()
	elif _space_started:
		_space_started = false
		if is_mine_recording():
			Recorder.end()
		get_viewport().set_input_as_handled()


func _on_finished(result: Dictionary) -> void:
	if int(result.get("owner", 0)) != get_instance_id():
		return
	_refresh()
	if not bool(result.get("ok", false)):
		if not bool(result.get("reported", false)):
			Toast.error("녹음에 실패했어요. 마이크 연결을 확인해 주세요.")
		return
	if float(result["duration"]) < 0.35:
		Toast.info("너무 짧게 녹음됐어요. 한 번 눌러 시작하고, 말한 뒤 다시 눌러 끝내 보세요.")
		return
	if bool(result.get("silent", false)):
		Toast.error("소리가 거의 들어오지 않았어요. 설정에서 마이크를 확인해 주세요.")
		return
	recorded.emit(result)
