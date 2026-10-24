class_name ConnectView
extends Control
## 휴대폰의 "내 PC에 연결" 전체 화면 (docs/android_remote_design.md §4.8 가).
##
## 연결은 Tailscale 전용이다(같은 와이파이·UDP 자동 찾기 없음): 사용자가 PC 의 Tailscale 주소(100.x.y.z)와 6자리 코드를 입력한다.
## 흐름: parse_address → hello(PC 닿는지, pairing_open) → pair → save → Api.set_remote → Backend.start().
## main.gd(W3) 가 CanvasLayer 에 올린다. 성공하면 `connected` 를 방출하고 스스로 닫는다.
##
## 네트워크 단계는 화면과 따로 도는 `Flow`(RefCounted)가 맡는다. 요청 도중 화면이 닫혀도(뒤로 가기 등)
## 비동기 함수가 사라진 노드로 돌아오지 않고, 이미 발급된 토큰은 그대로 저장된다.

signal connected
signal cancelled
## 시험·W3 용: [연결] 시도가 끝났다(성공 true / 실패 false). 화면에는 이미 결과가 반영돼 있다.
signal attempt_finished(ok: bool)
## [PC 없이 시작] was pressed: prefs standalone_ok / route_mode are saved and the screen closes itself (main.gd goes home).
signal standalone_chosen

## 가운데 열의 최대 폭(폰은 화면 폭을 그대로 쓴다).
const COLUMN_W := 480.0

## 설정에서 "연결 변경"으로 열었으면 true (취소 버튼이 보인다). add_child 전에 정한다.
var allow_cancel: bool = false

var previous_label: Label
var address_edit: LineEdit
var code_edit: LineEdit
var name_edit: LineEdit
var connect_button: Button
var cancel_button: Button
var standalone_button: Button
var error_label: Label
var progress_label: Label
var notice_label: Label

var _busy: bool = false
var _scroll: ScrollContainer
var _busy_bar: ProgressBar
var _flow: Flow ## the running attempt (its signals are cut when this screen leaves the tree)

## 진행 중인 Flow 는 화면이 사라져도 끝까지 돌아야 하므로 여기서 붙잡아 둔다.
static var _live_flows: Array = []


## 화면과 무관한 네트워크 단계. 결과는 신호로만 알린다.
class Flow:
	extends RefCounted
	signal progress(text: String)
	signal connect_done(res: Dictionary)  ## {ok, error, err_code}

	func connect_to(base: String, code: String, device_name: String) -> void:
		ConnectView._live_flows.append(self)
		var res: Dictionary = await _connect(base, code, device_name)
		ConnectView._live_flows.erase(self)
		connect_done.emit(res)

	func _fail(r: Dictionary) -> Dictionary:
		return {"ok": false, "error": str(r.get("error", "")), "err_code": str(r.get("err_code", ""))}

	func _connect(base: String, code: String, device_name: String) -> Dictionary:
		var hi: Dictionary = await RemoteLink.hello(base)
		if not hi["ok"]:
			return _fail(hi)
		if not bool(hi["pairing_open"]):
			return {"ok": false, "error": RemoteLink.NEED_CODE_HELP, "err_code": "no_code"}
		progress.emit("코드를 확인하는 중…")
		var pr: Dictionary = await RemoteLink.pair(base, code, device_name)
		if not pr["ok"]:
			return _fail(pr)
		var conn := {
			"base_url": base,
			"token": str(pr["token"]),
			"device_id": str(pr["device_id"]),
			"server_name": str(pr["server_name"]) if str(pr["server_name"]) != "" else str(hi["name"]),
		}
		if not RemoteLink.save(conn, Api.remote_path):
			return {"ok": false, "error": "연결 정보를 저장하지 못했어요. 저장 공간을 확인해 주세요.", "err_code": "save_failed"}
		Api.cli_base_url = ""   # the pairing just made supersedes a --api= from the command line
		Api.set_remote(base, str(conn["token"]))
		Backend.start()   # not awaited: the new connection is checked in the background
		return {"ok": true, "error": "", "err_code": ""}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# one centred column: the phone's width minus 16 each side, a narrow column on a wide window
	var page := PageScroll.new(COLUMN_W)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.column.set_padding(8, 32)
	add_child(page)
	_scroll = page
	var col: VBoxContainer = page.content

	col.add_child(PageHeader.build("내 PC에 연결"))
	previous_label = UI.label("", "Small")
	previous_label.add_theme_stylebox_override("normal", _side_margin(Ds.S2))
	previous_label.visible = false
	col.add_child(previous_label)

	# the two steps (what to do before typing anything)
	var steps := UI.card("Card", 12)
	steps.add(UI.label("① 휴대폰에 Tailscale을 설치하고 PC와 같은 구글 계정으로 로그인해 켜 주세요."))
	steps.add(UI.label("② PC의 회화 연습 > 설정 > 휴대폰 연결에 나오는 주소(100.x.y.z)와 6자리 코드를 입력하세요."))
	col.add_child(steps)
	notice_label = _alert_label(Pal.WARN_SOFT, Pal.WARN, Pal.WARN_ON, 1)
	notice_label.visible = false
	col.add_child(notice_label)

	# the three fields
	var form := UI.card("Card", 16)
	address_edit = _line_edit("100.101.102.103:8775")
	address_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_URL
	address_edit.text_submitted.connect(func(_t: String) -> void: code_edit.grab_focus())
	form.add(_field_block("PC 주소 (Tailscale)", address_edit, "포트를 안 적으면 8775를 써요."))
	code_edit = _line_edit("482 913")
	code_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code_edit.max_length = 8
	code_edit.text_submitted.connect(func(_t: String) -> void: submit())
	form.add(_field_block("연결 코드 (PC 화면의 6자리)", code_edit))
	name_edit = _line_edit("")
	name_edit.max_length = 40
	name_edit.text = default_device_name()
	form.add(_field_block("이 휴대폰 이름", name_edit))
	col.add_child(form)

	# progress and the error sit right above the buttons: that is where the eyes are after pressing [연결]
	_busy_bar = UI.progress_indeterminate(Pal.PRIMARY)
	_busy_bar.visible = false
	col.add_child(_busy_bar)
	progress_label = UI.label("", "Muted")
	progress_label.add_theme_stylebox_override("normal", _side_margin(Ds.S2))
	progress_label.visible = false
	col.add_child(progress_label)
	error_label = _alert_label(Pal.BAD_SOFT, Pal.BAD, Pal.BAD_ON, 2)
	error_label.visible = false
	col.add_child(error_label)

	connect_button = UI.button("연결", "primary", Pal.PRIMARY, 56.0)
	connect_button.pressed.connect(func() -> void: submit())
	col.add_child(connect_button)
	if not allow_cancel:
		# Phone standalone (docs/phone_standalone_design.md §4.6): lesson, review, dictation... run inside the phone.
		# Not offered when the screen was opened from "연결 변경" while connected (that person has a PC).
		standalone_button = UI.button("PC 없이 시작", "soft", Pal.PRIMARY, 56.0)
		standalone_button.pressed.connect(func() -> void: start_standalone())
		col.add_child(standalone_button)
		col.add_child(UI.label("PC 없이도 레슨·복습·읽기 같은 기본 기능은 이 폰에서 써요. AI 대화처럼 PC가 필요한 기능은 나중에 설정에서 PC를 연결하면 돼요.", "Small"))
	if allow_cancel:
		cancel_button = UI.button("취소", "soft", Pal.INK, 48.0)
		cancel_button.pressed.connect(func() -> void:
			cancelled.emit()
			queue_free())
		col.add_child(cancel_button)

	_prefill()
	if Backend.status == Backend.Status.NEEDS_PAIRING and Backend.message != "":
		notice_label.text = Backend.message
		notice_label.visible = true


## Closed while waiting for the PC (back button etc.): the Flow keeps running (the issued token is still saved) but must
## not call back into this freed screen.
func _exit_tree() -> void:
	if _flow != null:
		if _flow.progress.is_connected(_on_progress):
			_flow.progress.disconnect(_on_progress)
		if _flow.connect_done.is_connected(_on_connect_done):
			_flow.connect_done.disconnect(_on_connect_done)
		_flow = null


func _line_edit(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(0, Ds.field_h())
	le.focus_entered.connect(func() -> void:
		if _scroll != null:
			_scroll.ensure_control_visible.call_deferred(le))
	return le


## Title (Strong) over the field, an optional hint (Small) under it.
func _field_block(title: String, edit: LineEdit, hint: String = "") -> VBoxContainer:
	var b := UI.vbox(6)
	b.add_child(UI.label(title, "Strong"))
	edit.accessibility_name = title
	b.add_child(edit)
	if hint != "":
		b.add_child(UI.label(hint, "Small"))
	return b


## A Label that carries its own tinted box (the Label's "normal" style): text and `visible` stay on the one node.
func _alert_label(bg: Color, border: Color, fg: Color, border_w: int) -> Label:
	var l := UI.label("")
	l.add_theme_color_override("font_color", fg)
	l.add_theme_stylebox_override("normal", UI.style(bg, border, border_w, Ds.R_S, 14, 10))
	return l


static func _side_margin(px: int) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = float(px)
	sb.content_margin_right = float(px)
	return sb


static func default_device_name() -> String:
	var n: String = OS.get_model_name().strip_edges()
	if n == "" or n == "GenericDevice":
		return "휴대폰"
	return n.substr(0, 40)


## 이전에 연결했던 주소·PC 이름을 미리 채운다.
func _prefill() -> void:
	var conn: Dictionary = RemoteLink.load_saved(Api.remote_path)
	var base: String = str(conn.get("base_url", ""))
	if base != "":
		var p: Dictionary = RemoteLink.parse_address(base)
		address_edit.text = (str(p["host"]) + ":" + str(p["port"])) if p["ok"] else base.trim_prefix("http://")
	var nm: String = str(conn.get("server_name", ""))
	if nm != "":
		previous_label.text = "이전에 연결한 PC: " + nm
		previous_label.visible = true


func _set_busy(on: bool, msg: String = "") -> void:
	_busy = on
	connect_button.disabled = on
	_busy_bar.visible = on
	_show_progress(msg)


func show_error(msg: String) -> void:
	error_label.text = msg
	error_label.visible = msg != ""


## [연결] 버튼. 끝나면 attempt_finished 가 나온다.
func submit() -> void:
	if _busy:
		return
	show_error("")
	var addr: Dictionary = RemoteLink.parse_address(address_edit.text)
	if not addr["ok"]:
		show_error(str(addr["error"]))
		attempt_finished.emit.call_deferred(false)
		return
	var code: String = RemoteLink.normalize_code(code_edit.text)
	if code == "":
		show_error("연결 코드는 숫자 6자리예요.")
		attempt_finished.emit.call_deferred(false)
		return
	_set_busy(true, "PC에 연결하는 중…")
	var flow := Flow.new()
	_flow = flow
	flow.progress.connect(_on_progress)
	flow.connect_done.connect(_on_connect_done)
	flow.connect_to(str(addr["base_url"]), code, name_edit.text)


## [PC 없이 시작]: remember the choice (standalone_ok, route_mode "auto") and leave. Nothing is sent to any PC.
func start_standalone() -> void:
	if _busy:
		return
	Route.set_mode("auto")
	Store.set_pref(Route.PREF_MODE, "auto") # also when Route already was in "auto" without a saved value
	Store.set_pref("standalone_ok", true)
	standalone_chosen.emit()
	queue_free()


func _on_progress(text: String) -> void:
	_show_progress(text)


func _show_progress(text: String) -> void:
	progress_label.text = text
	progress_label.visible = text != ""


func _on_connect_done(res: Dictionary) -> void:
	if not bool(res["ok"]):
		_set_busy(false)
		show_error(str(res["error"]))
		if str(res["err_code"]) == "code_invalid":
			code_edit.select_all()
			code_edit.grab_focus()
		attempt_finished.emit(false)
		return
	_set_busy(false, "연결됐어요.")
	attempt_finished.emit(true)
	connected.emit()
	queue_free()
