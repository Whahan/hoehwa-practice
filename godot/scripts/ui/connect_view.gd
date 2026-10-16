class_name ConnectView
extends Control
## 휴대폰의 "내 PC에 연결" 전체 화면 (docs/android_remote_design.md §4.8 가).
##
## 흐름: parse_address → hello(PC 닿는지, pairing_open) → pair → save → Api.set_remote → Backend.start().
## main.gd(W3) 가 CanvasLayer 에 올린다. 성공하면 `connected` 를 방출하고 스스로 닫는다.

signal connected
signal cancelled

## 처음 열릴 때 PC 자동 찾기를 한 번 돌린다(시험에서는 끈다).
var auto_discover: bool = true
## 설정에서 "연결 변경"으로 열었으면 true (취소 버튼이 보인다).
var allow_cancel: bool = false

var find_button: Button
var found_box: VBoxContainer
var find_status: Label
var address_edit: LineEdit
var code_edit: LineEdit
var name_edit: LineEdit
var connect_button: Button
var cancel_button: Button
var error_label: Label
var progress_label: Label

var _busy: bool = false
var _found: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		outer.add_theme_constant_override("margin_" + side, 16)
	outer.add_theme_constant_override("margin_top", 24)
	outer.add_theme_constant_override("margin_bottom", 32)
	scroll.add_child(outer)
	var col := UI.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(col)

	col.add_child(UI.label("내 PC에 연결", "H1", false))
	col.add_child(UI.label("같은 와이파이의 PC에서 회화 연습을 켜고 설정 > 휴대폰 연결을 켜 주세요.", "Muted"))

	find_button = UI.button("PC 자동 찾기", "soft", Pal.EN, 48.0)
	find_button.pressed.connect(func() -> void: find_pcs())
	col.add_child(find_button)
	find_status = UI.label("", "Small")
	col.add_child(find_status)
	found_box = UI.vbox(6)
	col.add_child(found_box)

	col.add_child(UI.label("또는 주소 직접 입력", "Strong", false))
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "192.168.0.12:8775"
	address_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_URL
	address_edit.custom_minimum_size = Vector2(0, 48)
	address_edit.text_submitted.connect(func(_t: String) -> void: code_edit.grab_focus())
	col.add_child(address_edit)
	col.add_child(UI.label("포트를 안 적으면 8775를 써요.", "Small"))

	col.add_child(UI.label("연결 코드 (PC 화면의 6자리)", "Strong", false))
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "482 913"
	code_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code_edit.max_length = 8
	code_edit.custom_minimum_size = Vector2(0, 48)
	code_edit.text_submitted.connect(func(_t: String) -> void: submit())
	col.add_child(code_edit)

	col.add_child(UI.label("이 휴대폰 이름", "Strong", false))
	name_edit = LineEdit.new()
	name_edit.max_length = 40
	name_edit.custom_minimum_size = Vector2(0, 48)
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
	if Backend.message != "" and Backend.status == Backend.Status.NEEDS_PAIRING:
		progress_label.text = Backend.message
	if auto_discover and address_edit.text == "":
		find_pcs()


static func default_device_name() -> String:
	var n: String = OS.get_model_name().strip_edges()
	if n == "" or n == "GenericDevice":
		return "휴대폰"
	return n.substr(0, 40)


## 이전에 연결했던 주소를 미리 채운다.
func _prefill() -> void:
	var conn: Dictionary = Backend.last_conn
	if conn.is_empty():
		conn = RemoteLink.load_saved(Api.remote_path)
	var base: String = str(conn.get("base_url", ""))
	if base != "":
		var p: Dictionary = RemoteLink.parse_address(base)
		address_edit.text = (str(p["host"]) + ":" + str(p["port"])) if p["ok"] else base.trim_prefix("http://")
	var nm: String = str(conn.get("server_name", ""))
	if nm != "":
		find_status.text = "이전에 연결한 PC: " + nm


func _set_busy(on: bool, msg: String = "") -> void:
	_busy = on
	if connect_button != null:
		connect_button.disabled = on
		find_button.disabled = on
	progress_label.text = msg


func show_error(msg: String) -> void:
	error_label.text = msg
	error_label.visible = msg != ""


## PC 자동 찾기 (UDP). Awaitable.
func find_pcs() -> void:
	if _busy:
		return
	_set_busy(true)
	find_status.text = "찾는 중… (2.5초)"
	UI.clear(found_box)
	var tree: SceneTree = get_tree()
	_found = await RemoteLink.discover(tree)
	if not is_inside_tree():
		return
	_busy = false
	connect_button.disabled = false
	find_button.disabled = false
	if _found.is_empty():
		find_status.text = "PC를 찾지 못했어요. 아래에 주소를 직접 입력해 주세요."
		return
	find_status.text = "찾은 PC를 눌러 주소를 채우세요."
	for f in _found:
		var b := UI.option_row("%s   %s" % [str(f["name"]), str(f["host"])])
		var addr := "%s:%d" % [str(f["host"]), int(f["port"])]
		b.custom_minimum_size.y = 48
		b.pressed.connect(func() -> void:
			address_edit.text = addr
			code_edit.grab_focus())
		found_box.add_child(b)


## [연결] 버튼. Awaitable (시험이 직접 부른다).
func submit() -> void:
	if _busy:
		return
	show_error("")
	var addr: Dictionary = RemoteLink.parse_address(address_edit.text)
	if not addr["ok"]:
		show_error(str(addr["error"]))
		return
	var code: String = RemoteLink.normalize_code(code_edit.text)
	if code == "":
		show_error("연결 코드는 숫자 6자리예요.")
		return
	var base: String = str(addr["base_url"])
	_set_busy(true, "PC에 연결하는 중…")
	var hi: Dictionary = await RemoteLink.hello(base)
	if not is_inside_tree():
		return
	if not hi["ok"]:
		_set_busy(false)
		show_error(str(hi["error"]))
		return
	if not bool(hi["pairing_open"]):
		_set_busy(false)
		show_error(RemoteLink.NEED_CODE_HELP)
		return
	progress_label.text = "코드를 확인하는 중…"
	var pr: Dictionary = await RemoteLink.pair(base, code, name_edit.text)
	if not is_inside_tree():
		return
	if not pr["ok"]:
		_set_busy(false)
		show_error(str(pr["error"]))
		if str(pr["err_code"]) == "code_invalid":
			code_edit.select_all()
			code_edit.grab_focus()
		return
	var conn := {
		"base_url": base,
		"token": pr["token"],
		"device_id": pr["device_id"],
		"server_name": str(pr["server_name"]) if str(pr["server_name"]) != "" else str(hi["name"]),
	}
	if not RemoteLink.save(conn, Api.remote_path):
		_set_busy(false)
		show_error("연결 정보를 저장하지 못했어요. 저장 공간을 확인해 주세요.")
		return
	Api.set_remote(base, str(pr["token"]))
	_set_busy(false, "연결됐어요.")
	connected.emit()
	Backend.start()
	queue_free()
