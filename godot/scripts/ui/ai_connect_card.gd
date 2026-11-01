class_name AiConnectCard
extends VBoxContainer
## "AI 연결" card of the settings screen (PC): the state line, [AI 연결하기 / 다시 연결], [연결 시험], [연결 해제]
## (docs/onetouch_install_design.md §3.2 ③ 8). It replaces the old engine drop-down. The settings screen only calls
## `AiConnectCard.build(self)`; where it sits is the settings screen's business.
##
## The state comes from /health (Backend.llm_state()); the card redraws on Backend.status_changed. It never sends or
## stores a key: [AI 연결하기] opens AiConnectSheet.

const DISCONNECT_TEXT := "이 PC의 OpenCode 로그인이 지워져요. 터미널에서 쓰던 OpenCode도 로그아웃돼요."
const AUTH_EXPIRED_TEXT := "OpenCode 로그인이 만료됐거나 키가 맞지 않아요. [AI 연결하기]로 다시 연결해 주세요."

var host: Node = null
var title_label: Label = null
var status_label: Label = null
var note_label: Label = null
var connect_btn: Button = null
var test_btn: Button = null
var disconnect_btn: Button = null

var _busy: bool = false
var _test_note: String = ""


static func build(host_: Node = null) -> AiConnectCard:
	var c := AiConnectCard.new()
	c.host = host_
	c._build()
	return c


func _build() -> void:
	name = "AiConnectCard"
	add_theme_constant_override("separation", 6)
	title_label = UI.label("AI 연결", "ListMain")
	add_child(title_label)
	add_child(UI.label("레슨 만들기, 원어민 대화, 교정에 쓰는 무료 AI(DeepSeek)예요. 음성 인식·발음 채점·목소리·문법 검사는 AI를 연결하지 않아도 이 PC에서 무료로 돌아가요.", "Small"))
	status_label = UI.label("", "")
	add_child(status_label)
	var row := UI.flow(12, 8) # the buttons drop to a second line in a narrow window
	connect_btn = UI.button("AI 연결하기", "primary", Pal.PRIMARY)
	connect_btn.pressed.connect(_on_connect)
	row.add_child(connect_btn)
	test_btn = UI.button("연결 시험", "soft", Pal.PRIMARY)
	test_btn.pressed.connect(_on_test)
	row.add_child(test_btn)
	disconnect_btn = UI.button("연결 해제", "soft", Pal.BAD)
	disconnect_btn.pressed.connect(_on_disconnect)
	row.add_child(disconnect_btn)
	add_child(row)
	note_label = UI.label("", "Small")
	add_child(note_label)
	Backend.status_changed.connect(refresh)
	refresh()
	UI.fix_cjk(self)


## Redraws from Backend.status / Backend.health.
func refresh() -> void:
	if status_label == null:
		return
	var eng_ok: bool = Backend.status == Backend.Status.READY
	var st: String = Backend.llm_state()
	var linked: bool = eng_ok and (st == "ready" or st == "blocked")
	var text: String = ""
	var note: String = _test_note
	if not eng_ok:
		text = "AI 엔진이 아직 준비되지 않았어요."
	elif Backend.llm_provider() == "openai_api":
		text = "개발용 API 키 엔진을 쓰고 있어요. OpenCode 연결은 쓰지 않아요."
	elif st == "not_installed":
		text = "AI 구성 요소가 없어요. [AI 연결하기]에서 받을 수 있어요."
	elif st == "not_connected":
		text = "아직 연결되지 않았어요. 한 번만 연결하면 대화와 AI 레슨을 쓸 수 있어요."
	else:
		text = "연결됨 · %s" % Backend.llm_label()
		if st == "blocked" and note == "":
			note = Backend.llm_missing_text()
	if AiConnectSheet.notice_pending:
		note = (note + "\n" if note != "" else "") + AiConnectSheet.DISK_HINT
	status_label.text = text
	note_label.text = note
	note_label.visible = note != ""
	var oc: bool = eng_ok and Backend.llm_provider() != "openai_api"
	connect_btn.text = "다시 연결" if linked else "AI 연결하기"
	connect_btn.disabled = _busy or not oc
	test_btn.disabled = _busy or not (oc and linked)
	disconnect_btn.disabled = _busy or not (oc and linked)


func _on_connect() -> void:
	AiConnectSheet.open(host if host != null and is_instance_valid(host) else self)


func _on_test() -> void:
	if _busy:
		return
	_busy = true
	_test_note = "연결을 시험하는 중이에요…"
	refresh()
	var res: Dictionary = await Api.post_json("/llm/test", {}, 120.0, false).wait()
	if not is_instance_valid(self):
		return
	_busy = false
	if bool(res.get("ok", false)) and res.get("data") is Dictionary:
		_test_note = "연결 성공 · %s · %.1f초 걸렸어요." % [Backend.llm_label(), float((res["data"] as Dictionary).get("seconds", 0.0))]
	elif str(res.get("err_code", "")) == "ai_auth":
		_test_note = "연결 실패: " + AUTH_EXPIRED_TEXT
	else:
		_test_note = "연결 실패: " + AiConnectSheet.fail_text(res)
	refresh()
	Backend.refresh_health()


func _on_disconnect() -> void:
	if _busy:
		return
	var sh := Sheet.confirm(host if host != null and is_instance_valid(host) else self, "AI 연결 해제", DISCONNECT_TEXT, "해제", true, "취소")
	sh.closed.connect(func(r: Variant) -> void:
		if typeof(r) == TYPE_STRING and String(r) == "ok":
			_do_disconnect())


func _do_disconnect() -> void:
	_busy = true
	refresh()
	var res: Dictionary = await Api.post_json("/llm/disconnect", {}, 30.0, false).wait()
	if not is_instance_valid(self):
		return
	_busy = false
	if bool(res.get("ok", false)):
		_test_note = ""
		Toast.ok("AI 연결을 해제했어요.")
	else:
		Toast.error(AiConnectSheet.fail_text(res))
	refresh()
	Backend.refresh_health()
