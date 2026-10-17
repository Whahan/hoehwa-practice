class_name RemoteLinkPanel
extends VBoxContainer
## 휴대폰 설정의 "PC 연결" 카드 (docs/android_remote_design.md §4.8 나).
## 상태 점, PC 이름·주소, [연결 변경], [연결 끊기], 마이크 권한 상태 줄.

signal change_requested

const MIC_HINT := "휴대폰 설정 > 앱 > 회화 연습 > 권한 > 마이크를 허용해 주세요."

var dot: PanelContainer
var status_label: Label
var pc_label: Label
var mic_label: Label
var mic_hint: Label
var change_button: Button
var disconnect_button: Button
var _busy: bool = false
var _unpair_call: Api.ApiCall = null


func _init() -> void:
	add_theme_constant_override("separation", 10)


func _ready() -> void:
	add_child(UI.label("PC 연결", "Strong", false))
	var row := UI.hbox(8)
	dot = UI.tinted_panel(Pal.MUTED, Color(0, 0, 0, 0), 0, 99, 0, 0)
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)
	status_label = UI.label("", "", true)
	row.add_child(status_label)
	add_child(row)
	pc_label = UI.label("", "Small")
	add_child(pc_label)
	var brow := UI.flow(8, 8)
	change_button = UI.button("연결 변경", "default", Pal.INK, 48.0)
	change_button.pressed.connect(func() -> void: change_requested.emit())
	brow.add_child(change_button)
	disconnect_button = UI.button("연결 끊기", "outline", Pal.BAD, 48.0)
	disconnect_button.pressed.connect(func() -> void: disconnect_pc())
	brow.add_child(disconnect_button)
	add_child(brow)
	add_child(UI.hline())
	mic_label = UI.label("", "Strong")
	add_child(mic_label)
	mic_hint = UI.colored("", Pal.WARN, "Small")
	add_child(mic_hint)
	Backend.status_changed.connect(refresh)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func _exit_tree() -> void:
	# removed while the PC is being told: finish the request now (the token is still forgotten locally)
	if _unpair_call != null:
		_unpair_call.cancel()


## "연결 끊기": 가능하면 PC 에 알리고(POST /lan/unpair), 이 폰의 토큰을 지운다.
func disconnect_pc() -> void:
	if _busy:
		return
	_busy = true
	if Api.token != "" and Api.base_url != "":
		_unpair_call = Api.post_json("/lan/unpair", {}, 5.0, false)
		await _unpair_call.wait()
		_unpair_call = null
	_busy = false
	Backend.forget_pairing()
	if is_inside_tree():
		refresh()


static func mic_granted() -> bool:
	if not Platform.is_android():
		return false
	for p in OS.get_granted_permissions():
		if str(p).ends_with("RECORD_AUDIO"):
			return true
	return false


func refresh() -> void:
	if status_label == null:
		return
	var st: int = Backend.status
	var color: Color = Pal.MUTED
	var text: String
	match st:
		Backend.Status.READY:
			color = Pal.OK
			text = "PC 연결됨"
		Backend.Status.NEEDS_PAIRING:
			color = Pal.WARN
			text = "연결 필요 — PC와 아직 연결되지 않았어요."
		Backend.Status.FAILED:
			color = Pal.BAD
			text = "PC 연결 안 됨"
		_:
			text = "PC에 연결하는 중…"
	dot.add_theme_stylebox_override("panel", UI.style(color, Color(0, 0, 0, 0), 0, 99, 0, 0))
	status_label.text = text
	var conn: Dictionary = RemoteLink.load_saved(Api.remote_path)
	var name: String = str(conn.get("server_name", ""))
	var addr: String = str(conn.get("base_url", Api.base_url)).trim_prefix("http://")
	if st == Backend.Status.READY and Api.base_url != "":
		addr = Api.base_url.trim_prefix("http://")
	var lines: Array[String] = []
	if name != "":
		lines.append("PC 이름: " + name)
	if addr != "":
		lines.append("주소: " + addr)
	pc_label.text = "\n".join(lines) if not lines.is_empty() else "연결된 PC가 없어요."
	disconnect_button.disabled = st == Backend.Status.NEEDS_PAIRING
	# microphone
	if Platform.is_android():
		var ok: bool = mic_granted()
		mic_label.text = "마이크: 허용됨" if ok else "마이크: 꺼짐"
		mic_hint.text = "" if ok else "처음 녹음할 때 허용을 물어봐요. 거절했다면 " + MIC_HINT
	else:
		mic_label.text = "마이크: 시험 모드 (이 화면에서는 쓰지 않아요)"
		mic_hint.text = ""
	mic_hint.visible = mic_hint.text != ""
