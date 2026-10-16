class_name PhoneLinkPanel
extends VBoxContainer
## PC 설정의 "휴대폰 연결" 카드 (docs/android_remote_design.md §4.8 다).
##
## 이 PC 의 백엔드 `/lan` 관리 엔드포인트(루프백 전용)로 켜기/끄기, 연결 코드, 기기 목록을 다룬다.
## 패널이 보이는 동안 2초마다 GET /lan 을 부른다(꺼짐일 때는 보일 때 한 번).

## main.gd(W3) 가 상단 "폰 연결 켜짐" 표시에 읽는 마지막 상태
static var last_enabled: bool = false

const POLL_SEC := 2.0

const DESC_TEXT := "켜면 같은 와이파이에 있는 내 휴대폰의 회화 연습 앱이 이 PC의 AI 엔진을 쓸 수 있어요. 끄면 외부 연결 포트가 바로 닫혀요. 연결 코드를 입력한 휴대폰만 쓸 수 있어요."
const WARN_TEXT := "카페·학교·호텔 같은 공용 와이파이에서는 켜지 마세요. 휴대폰과 PC 사이의 통신은 암호화되지 않아서 같은 와이파이의 다른 사람이 볼 수 있어요. 집이나 내가 관리하는 와이파이에서만 쓰세요. 안 쓸 때는 꺼 두세요."
const FIREWALL_TEXT := "처음 켜면 Windows가 '이 앱이 네트워크에서 통신하도록 허용하시겠습니까?' 창을 띄워요. '개인 네트워크'를 체크하고 '액세스 허용'을 눌러 주세요. 창이 안 보이면 작업 표시줄을 확인해 보세요. 이 프로그램은 방화벽 설정을 직접 바꾸지 않아요. 그래도 폰에서 안 잡히면: 설정 > 네트워크 및 인터넷 > 와이파이 > 이 네트워크의 '네트워크 프로필'이 '개인'인지 확인하세요. 회사·학교 와이파이는 기기끼리 통신을 막는 경우가 많아요. PC가 잠들면 연결이 끊겨요."
const LOCKED_TEXT := "코드를 5번 틀려서 잠겼어요. '새 코드 만들기'를 눌러 주세요."

var state: Dictionary = {}          ## 마지막 GET /lan 응답
var error_text: String = ""

var toggle: CheckButton
var state_label: Label
var code_label: Label
var timer_label: Label
var address_label: Label
var new_code_button: Button
var revoke_all_button: Button
var devices_title: Label
var devices_box: VBoxContainer
var error_label: Label
var warn_box: PanelContainer
var details: VBoxContainer
var read_first_button: Button
var advanced_box: VBoxContainer
var discovery_check: CheckBox
var port_edit: LineEdit
var name_edit: LineEdit

var _expires_at_msec: int = 0
var _poll_timer: Timer
var _busy: bool = false
var _wall_sec_tick: int = -1


func _init() -> void:
	add_theme_constant_override("separation", 10)


func _ready() -> void:
	var head := UI.hbox(10)
	head.add_child(UI.label("휴대폰 연결", "Strong", false))
	head.add_child(UI.spacer())
	state_label = UI.label("꺼짐", "Muted", false)
	head.add_child(state_label)
	toggle = CheckButton.new()
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	toggle.toggled.connect(_on_toggled)
	head.add_child(toggle)
	add_child(head)
	add_child(UI.label(DESC_TEXT, "Small"))

	read_first_button = UI.link_button("▸ 켜기 전에 읽어 주세요")
	read_first_button.pressed.connect(func() -> void: _show_warning(not warn_box.visible))
	add_child(read_first_button)
	warn_box = UI.tinted_panel(Pal.WARN_SOFT, Pal.WARN, 1, 10, 12, 10)
	var wcol := UI.vbox(6)
	wcol.add_child(UI.label("⚠ 공용 와이파이 경고", "Strong"))
	wcol.add_child(UI.label(WARN_TEXT, "Small"))
	wcol.add_child(UI.label("Windows 방화벽 안내", "Strong"))
	wcol.add_child(UI.label(FIREWALL_TEXT, "Small"))
	warn_box.add_child(wcol)
	warn_box.visible = false
	add_child(warn_box)

	error_label = UI.colored("", Pal.BAD, "Small")
	error_label.visible = false
	add_child(error_label)

	details = UI.vbox(10)
	details.visible = false
	var arow := UI.hbox(14)
	address_label = UI.label("", "Strong", false)
	arow.add_child(address_label)
	arow.add_child(UI.spacer())
	code_label = UI.label("", "H2", false)
	arow.add_child(code_label)
	details.add_child(arow)
	var trow := UI.hbox(10)
	timer_label = UI.label("", "Small", false)
	trow.add_child(timer_label)
	trow.add_child(UI.spacer())
	new_code_button = UI.button("새 코드 만들기", "soft", Pal.EN)
	new_code_button.pressed.connect(func() -> void: new_code())
	trow.add_child(new_code_button)
	details.add_child(trow)
	details.add_child(UI.hline())
	devices_title = UI.label("연결된 휴대폰 (0)", "Strong", false)
	details.add_child(devices_title)
	devices_box = UI.vbox(6)
	details.add_child(devices_box)
	revoke_all_button = UI.button("모두 해제", "outline", Pal.BAD)
	revoke_all_button.pressed.connect(func() -> void: revoke_all())
	details.add_child(revoke_all_button)
	add_child(details)

	var adv_btn := UI.link_button("▸ 고급")
	adv_btn.pressed.connect(func() -> void: advanced_box.visible = not advanced_box.visible)
	add_child(adv_btn)
	advanced_box = UI.vbox(8)
	advanced_box.visible = false
	discovery_check = CheckBox.new()
	discovery_check.text = "휴대폰이 이 PC를 자동으로 찾을 수 있게 하기 (UDP 8776)"
	discovery_check.focus_mode = Control.FOCUS_NONE
	discovery_check.toggled.connect(func(on: bool) -> void:
		if not _busy:
			update_settings({"discovery": on}))
	advanced_box.add_child(discovery_check)
	var prow := UI.hbox(8)
	port_edit = LineEdit.new()
	port_edit.placeholder_text = "8775"
	port_edit.custom_minimum_size = Vector2(100, 0)
	prow.add_child(UI.label("연결 포트", "Small", false))
	prow.add_child(port_edit)
	var pbtn := UI.button("적용", "default")
	pbtn.pressed.connect(func() -> void: apply_port())
	prow.add_child(pbtn)
	advanced_box.add_child(prow)
	var nrow := UI.hbox(8)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "비우면 컴퓨터 이름"
	name_edit.custom_minimum_size = Vector2(220, 0)
	nrow.add_child(UI.label("표시 이름", "Small", false))
	nrow.add_child(name_edit)
	var nbtn := UI.button("적용", "default")
	nbtn.pressed.connect(func() -> void: update_settings({"name": name_edit.text.strip_edges()}))
	nrow.add_child(nbtn)
	advanced_box.add_child(nrow)
	add_child(advanced_box)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_SEC
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	_apply_state()
	if is_visible_in_tree():
		refresh()


func _process(_delta: float) -> void:
	if details == null or not details.visible or _expires_at_msec == 0:
		return
	var sec: int = _seconds_left()
	if sec != _wall_sec_tick:
		_wall_sec_tick = sec
		_update_timer_label()


func _on_poll() -> void:
	# 켜져 있는 동안만 2초마다. 꺼짐일 때는 보일 때 한 번(visibility_changed).
	if is_visible_in_tree() and last_enabled:
		refresh()


# ---------------------------------------------------------------- calls

## GET /lan. Awaitable.
func refresh() -> void:
	if _busy:
		return
	var res: Dictionary = await Api.get_json("/lan", 5.0, false).wait()
	_handle_result(res)


func _handle_result(res: Dictionary) -> void:
	if res.get("cancelled", false):
		return
	if res["ok"] and res["data"] is Dictionary:
		state = res["data"]
		error_text = ""
		last_enabled = bool(state.get("enabled", false))
	else:
		if int(res.get("code", 0)) == 404:
			error_text = "이 PC의 엔진이 옛 버전이라 휴대폰 연결을 쓸 수 없어요. 앱을 업데이트해 주세요."
		else:
			error_text = str(res.get("error", ""))
			if error_text == "":
				error_text = "휴대폰 연결 상태를 읽지 못했어요."
		if str(res.get("err_code", "")) == "lan_port_busy":
			error_text = _port_busy_text(res)
	_apply_state()


func _port_busy_text(_res: Dictionary) -> String:
	var port: int = int(state.get("port", 8775))
	return "포트 %d를 다른 프로그램이 쓰고 있어요. 다른 프로그램을 끄거나 아래 '고급'에서 포트를 바꿔 주세요." % port


func _post(path: String, body: Dictionary) -> Dictionary:
	_busy = true
	var res: Dictionary = await Api.post_json(path, body, 10.0, false).wait()
	_busy = false
	return res


## 켜기/끄기. Awaitable; 토글 스위치도 같은 경로를 쓴다.
func set_enabled_remote(on: bool) -> void:
	if on:
		_show_warning(true)
	var res: Dictionary = await _post("/lan", {"enabled": on})
	_handle_result(res)
	if not res["ok"]:
		last_enabled = bool(state.get("enabled", false))
		_apply_state()


func _on_toggled(on: bool) -> void:
	if _busy:
		return
	set_enabled_remote(on)


func new_code() -> void:
	var res: Dictionary = await _post("/lan/code", {})
	if not res["ok"]:
		error_text = str(res["error"])
		_apply_state()
		return
	await refresh()


func revoke_device(id: String) -> void:
	var res: Dictionary = await _post("/lan/devices/revoke", {"id": id})
	if not res["ok"]:
		error_text = str(res["error"])
		_apply_state()
		return
	await refresh()


func revoke_all() -> void:
	var res: Dictionary = await _post("/lan/devices/revoke", {"all": true})
	if not res["ok"]:
		error_text = str(res["error"])
		_apply_state()
		return
	await refresh()


func update_settings(body: Dictionary) -> void:
	var res: Dictionary = await _post("/lan", body)
	_handle_result(res)


func apply_port() -> void:
	var t: String = port_edit.text.strip_edges()
	if not t.is_valid_int() or int(t) < 1024 or int(t) > 65535:
		error_text = "포트는 1024에서 65535 사이 숫자로 적어 주세요."
		_apply_state()
		return
	update_settings({"port": int(t)})


# ---------------------------------------------------------------- view

func _show_warning(on: bool) -> void:
	warn_box.visible = on
	read_first_button.text = ("▾ 켜기 전에 읽어 주세요" if on else "▸ 켜기 전에 읽어 주세요")


func _seconds_left() -> int:
	return maxi(0, int(ceil(float(_expires_at_msec - Time.get_ticks_msec()) / 1000.0)))


func _update_timer_label() -> void:
	var p: Variant = state.get("pairing", null)
	if not (p is Dictionary) or not bool((p as Dictionary).get("active", false)):
		timer_label.text = ""
		return
	var s: int = _seconds_left()
	timer_label.text = "(%d:%02d 안에 입력)" % [s / 60, s % 60]


static func format_code(code: String) -> String:
	if code.length() == 6:
		return code.substr(0, 3) + " " + code.substr(3)
	return code


static func ago_text(iso: String) -> String:
	if iso.strip_edges() == "":
		return ""
	var wall: String = iso.substr(0, 19)
	if wall.length() < 19:
		return ""
	var then: int = Time.get_unix_time_from_datetime_string(wall)
	var now: int = Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system(false))
	var d: int = now - then
	if d < 0:
		d = 0
	if d < 60:
		return "방금 전"
	if d < 3600:
		return "%d분 전" % (d / 60)
	if d < 86400:
		return "%d시간 전" % (d / 3600)
	return "%d일 전" % (d / 86400)


func _apply_state() -> void:
	if toggle == null:
		return
	var enabled: bool = bool(state.get("enabled", false))
	toggle.set_pressed_no_signal(enabled)
	toggle.disabled = state.is_empty() and error_text != ""
	state_label.text = "켜짐" if enabled else "꺼짐"
	details.visible = enabled
	var texts: Array[String] = []
	if error_text != "":
		texts.append(error_text)
	if enabled:
		var p: Dictionary = state.get("pairing", {}) if state.get("pairing", null) is Dictionary else {}
		if bool(p.get("locked", false)):
			texts.append(LOCKED_TEXT)
		if bool(state.get("discovery", false)) and not bool(state.get("discovery_listening", false)):
			texts.append("자동 찾기를 켜지 못했어요(포트 %d 사용 중). 휴대폰에서 주소를 직접 입력하면 연결할 수 있어요." % int(state.get("discovery_port", 8776)))
		if str(state.get("error", "")) != "" and not texts.has(str(state["error"])):
			texts.append(str(state["error"]))
		_show_warning(true)
		var addrs: Array = state.get("addresses", []) if state.get("addresses", null) is Array else []
		var port: int = int(state.get("port", 8775))
		if addrs.is_empty():
			address_label.text = "주소를 찾지 못했어요 (포트 %d)" % port
		else:
			address_label.text = "주소  %s:%d" % [str(addrs[0]), port]
		if p.get("active", false) and p.get("code", null) != null:
			code_label.text = "연결 코드  " + format_code(str(p["code"]))
			_expires_at_msec = Time.get_ticks_msec() + int(p.get("expires_in", 0)) * 1000
		else:
			code_label.text = "연결 코드  –"
			_expires_at_msec = 0
		_update_timer_label()
		_fill_devices(state.get("devices", []) if state.get("devices", null) is Array else [])
		discovery_check.set_pressed_no_signal(bool(state.get("discovery", false)))
		if not port_edit.has_focus():
			port_edit.text = str(port)
		if not name_edit.has_focus():
			name_edit.text = str(state.get("name_config", state.get("name", "")))
	else:
		_expires_at_msec = 0
	error_label.text = "\n".join(texts)
	error_label.visible = not texts.is_empty()


func _fill_devices(devs: Array) -> void:
	UI.clear(devices_box)
	devices_title.text = "연결된 휴대폰 (%d)" % devs.size()
	revoke_all_button.visible = devs.size() > 1
	if devs.is_empty():
		devices_box.add_child(UI.label("아직 연결된 휴대폰이 없어요. 휴대폰 앱에서 위 주소와 코드를 입력해 주세요.", "Small"))
		return
	for d in devs:
		if not (d is Dictionary):
			continue
		var dd: Dictionary = d
		var row := UI.hbox(8)
		row.name = "dev_" + str(dd.get("id", ""))
		var parts: Array[String] = [str(dd.get("name", "휴대폰"))]
		var ago: String = ago_text(str(dd.get("last_seen", "")))
		if ago != "":
			parts.append(ago)
		if str(dd.get("last_ip", "")) != "":
			parts.append(str(dd["last_ip"]))
		row.add_child(UI.label(" · ".join(parts), "", true))
		var b := UI.button("연결 해제", "outline", Pal.BAD)
		var id: String = str(dd.get("id", ""))
		b.pressed.connect(func() -> void: revoke_device(id))
		row.add_child(b)
		devices_box.add_child(row)
