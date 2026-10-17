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

## 설정에서 "연결 변경"으로 열었으면 true (취소 버튼이 보인다). add_child 전에 정한다.
var allow_cancel: bool = false

var previous_label: Label
var address_edit: LineEdit
var code_edit: LineEdit
var name_edit: LineEdit
var connect_button: Button
var cancel_button: Button
var error_label: Label
var progress_label: Label
var notice_label: Label

var _busy: bool = false
var _scroll: ScrollContainer
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
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		outer.add_theme_constant_override("margin_" + side, 16)
	outer.add_theme_constant_override("margin_top", 24)
	outer.add_theme_constant_override("margin_bottom", 32)
	_scroll.add_child(outer)
	var col := UI.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(col)

	col.add_child(UI.label("내 PC에 연결", "H1", false))
	col.add_child(UI.label("① 휴대폰에 Tailscale을 설치하고 PC와 같은 구글 계정으로 로그인해 켜 주세요.", "Muted"))
	col.add_child(UI.label("② PC의 회화 연습 > 설정 > 휴대폰 연결에 나오는 주소(100.x.y.z)와 6자리 코드를 입력하세요.", "Muted"))
	notice_label = UI.colored("", Pal.WARN, "")
	notice_label.visible = false
	col.add_child(notice_label)

	previous_label = UI.label("", "Small")
	col.add_child(previous_label)

	col.add_child(UI.label("PC 주소 (Tailscale)", "Strong", false))
	address_edit = _line_edit("100.101.102.103:8775", 48.0)
	address_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_URL
	address_edit.text_submitted.connect(func(_t: String) -> void: code_edit.grab_focus())
	col.add_child(address_edit)
	col.add_child(UI.label("포트를 안 적으면 8775를 써요.", "Small"))

	col.add_child(UI.label("연결 코드 (PC 화면의 6자리)", "Strong", false))
	code_edit = _line_edit("482 913", 48.0)
	code_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code_edit.max_length = 8
	code_edit.text_submitted.connect(func(_t: String) -> void: submit())
	col.add_child(code_edit)

	col.add_child(UI.label("이 휴대폰 이름", "Strong", false))
	name_edit = _line_edit("", 48.0)
	name_edit.max_length = 40
	name_edit.text = default_device_name()
	col.add_child(name_edit)

	connect_button = UI.button("연결", "primary", Pal.EN, 52.0)
	connect_button.pressed.connect(func() -> void: submit())
	col.add_child(connect_button)
	if allow_cancel:
		cancel_button = UI.button("취소", "default", Pal.INK, 48.0)
		cancel_button.pressed.connect(func() -> void:
			cancelled.emit()
			queue_free())
		col.add_child(cancel_button)
	progress_label = UI.label("", "Muted")
	col.add_child(progress_label)
	error_label = UI.colored("", Pal.BAD, "")
	error_label.visible = false
	col.add_child(error_label)

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


func _line_edit(placeholder: String, min_h: float) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(0, min_h)
	le.focus_entered.connect(func() -> void:
		if _scroll != null:
			_scroll.ensure_control_visible.call_deferred(le))
	return le


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


func _set_busy(on: bool, msg: String = "") -> void:
	_busy = on
	connect_button.disabled = on
	progress_label.text = msg


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


func _on_progress(text: String) -> void:
	progress_label.text = text


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
