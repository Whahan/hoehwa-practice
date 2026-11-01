class_name AiConnectSheet
extends RefCounted
## [AI 연결하기] sheet (docs/onetouch_install_design.md §3.2 ③, §3.4, §3.5; PC only).
##
## The person logs in at opencode.ai, copies an API key and pastes it into a masked field; [연결] sends it once to the
## local backend (`POST /llm/connect {"key": ...}`) and the field is emptied at the same moment. The key is never stored,
## printed or logged by the app: not in prefs, not in a variable that outlives the request (only its SHA-256 is kept, to
## recognise a clipboard that still holds it), not in a toast. The backend hands it to OpenCode, which saves it.
##
## A phone never opens the sheet and never sends /llm/connect (the PC refuses LAN callers): it only says
## "PC의 회화 연습 설정에서 'AI 연결하기'를 눌러 주세요."
##
## Also here: the "AI 연결" slot the home screen asks for (home_slot, HomeAi.provider) and the once-per-run migration
## notice (check_notice).

const LOGIN_URL := "https://opencode.ai/auth"
const PHONE_TEXT := "PC의 회화 연습 설정에서 'AI 연결하기'를 눌러 주세요."
const NOTE_TEXT := "키는 이 PC의 OpenCode에만 저장돼요. 이 앱은 키를 저장하거나 기록하지 않아요."
const TERMINAL_TEXT := "터미널(명령 프롬프트)에서 opencode auth login 을 실행해 로그인해도 돼요. 끝나면 잠시 뒤 이 앱이 연결 상태를 다시 확인해요. 위 칸에 붙여 넣는 쪽이 더 쉬워요."
const NOTICE_TEXT := "오프라인 로컬 AI는 이제 쓰지 않아요. 무료 DeepSeek으로 바꿨어요. 쓰려면 AI 연결하기를 눌러 주세요."
const DISK_HINT := "예전 오프라인 AI(Ollama)가 남아 있으면 Windows 설정 > 앱에서 지워 약 5GB를 비울 수 있어요."

const MSG_EMPTY := "먼저 API 키를 붙여 넣어 주세요."
const MSG_CONNECTING := "연결하는 중이에요… 몇 초 걸려요."
const MSG_OK := "AI가 연결됐어요."
const MSG_OK_UNTESTED := "연결은 됐어요. 한도 또는 서버 사정으로 시험은 건너뛰었어요."
const MSG_AUTH := "키가 맞지 않아요. 다시 복사해서 붙여 넣어 주세요."
const MSG_BAD_FORMAT := "키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요."
const MSG_LOCAL_ONLY := "이 PC의 회화 연습 앱에서만 연결할 수 있어요."
const MSG_NET := "AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요."
const MSG_INSTALLING := "AI 구성 요소(약 60MB)를 받는 중이에요…"
const MSG_INSTALLED := "AI 구성 요소를 받았어요. 이제 API 키를 붙여 넣고 [연결]을 눌러 주세요."
const MSG_INSTALL_FAIL := "AI 구성 요소를 받지 못했어요."

const CONNECT_TIMEOUT := 120.0
const INSTALL_MAX_SEC := 900.0

## Tests switch these: 1 = phone / 0 = PC / -1 = Platform.is_phone(); the browser opener; the clipboard.
static var force_phone: int = -1
static var opener: Callable = Callable()
static var clip_get: Callable = Callable()
static var clip_set: Callable = Callable()
## Seconds between two GET /llm/install polls.
static var poll_sec: float = 1.0
## The automatic opening (after an `ai_not_connected` answer) is used up for this run, or the person said "나중에".
static var auto_done: bool = false
static var phone_told: bool = false
static var notice_checked: bool = false
## The "ollama_removed" notice is shown and not yet confirmed (the AI card then adds the disk hint).
static var notice_pending: bool = false
static var current: AiConnectSheet = null

var sheet: Sheet = null
var key_edit: LineEdit = null
var status_label: Label = null
var bar: ProgressBar = null
var connect_btn: Button = null
var open_btn: Button = null
var term_btn: Button = null
var term_label: Label = null
var busy: bool = false
var connected_ok: bool = false
var installing: bool = false

var _key_hash: String = ""
var _closed: bool = false


# ---------------------------------------------------------------- static entry points

static func is_phone() -> bool:
	return Platform.is_phone() if force_phone < 0 else force_phone == 1


static func is_open() -> bool:
	return current != null and current.sheet != null and not current.sheet.is_closed()


## Opens the sheet on the PC. On a phone nothing opens and nothing is sent: only the sentence is shown (returns null).
static func open(host: Node) -> AiConnectSheet:
	if is_phone():
		Toast.info(PHONE_TEXT)
		return null
	if is_open():
		return current
	var s := AiConnectSheet.new()
	s._build(host)
	current = s
	if Backend.llm_state() == "not_installed":
		s.start_install() # the components come first: the key box waits
	return s


## `Api.ai_not_connected` (the backend answered 503 ai_not_connected / ai_not_installed): the sheet opens by itself once
## per run, never after "나중에", never over another open sheet. A phone only gets the sentence, once.
static func auto_open(_code: String, host: Node) -> void:
	if is_phone():
		if not phone_told:
			phone_told = true
			Toast.info(PHONE_TEXT)
		return
	if auto_done or is_open():
		return
	auto_done = true
	open(host)


## Home / menu slot (HomeAi.provider): the wording for each `llm_state`. Every other state is the default of HomeAi.
static func home_slot() -> Dictionary:
	if Backend.status == Backend.Status.READY and Backend.llm_missing():
		if is_phone():
			return {"show": true, "state": "llm_off", "title": "AI 연결이 필요해요", "body": "PC의 회화 연습 설정에서 AI 연결하기를 눌러 주세요",
				"action": "", "prominent": false, "dismissible": true}
		if Backend.llm_state() == "not_installed":
			return {"show": true, "state": "not_installed", "title": "AI 구성 요소가 없어요", "body": "받아서 한 번만 연결하면 대화와 AI 레슨을 쓸 수 있어요",
				"action": "AI 연결하기", "prominent": false, "dismissible": true}
		return {"show": true, "state": "llm_off", "title": "AI 연결이 필요해요", "body": "한 번만 연결하면 대화와 AI 레슨을 쓸 수 있어요",
			"action": "AI 연결하기", "prominent": false, "dismissible": true}
	return HomeAi._default_slot()


## Once per run on the PC, when the engine answers: GET /llm. A migrated install (`notice == "ollama_removed"`) gets one
## toast with a [확인] button; [확인] sends POST /llm/notice/ack so it never comes back.
static func check_notice() -> void:
	if notice_checked or is_phone() or not Backend.is_ready():
		return
	notice_checked = true
	var res: Dictionary = await Api.get_json("/llm", 10.0, false).wait()
	if not bool(res.get("ok", false)) or not (res.get("data") is Dictionary):
		return
	if str((res["data"] as Dictionary).get("notice", "")) != "ollama_removed":
		return
	notice_pending = true
	Toast.show_snack(NOTICE_TEXT, "확인", ack_notice)


static func ack_notice() -> void:
	notice_pending = false
	Api.post_json("/llm/notice/ack", {}, 10.0, false)


## Korean sentence for a failed /llm/connect (or /llm/test) answer. Known codes have their own words; anything else
## shows the (Korean) text the backend sent.
static func fail_text(res: Dictionary) -> String:
	var code: String = str(res.get("err_code", ""))
	match code:
		"ai_auth":
			return MSG_AUTH
		"bad_key_format":
			return MSG_BAD_FORMAT
		"local_only", "bad_origin", "lan_forbidden":
			return MSG_LOCAL_ONLY
		"transport":
			return MSG_NET
	if int(res.get("code", 0)) == 403:
		return MSG_LOCAL_ONLY
	var t: String = str(res.get("error", ""))
	return t if t != "" else "연결하지 못했어요. 잠시 뒤 다시 시도해 주세요."


# ---------------------------------------------------------------- building

func _build(host: Node) -> void:
	var col := UI.vbox(10)
	col.add_child(UI.label("대화·AI 레슨·교정에는 무료 AI(DeepSeek)가 필요해요. 한 번만 연결하면 돼요."))
	col.add_child(UI.label("① [OpenCode 열기]를 눌러 로그인하고 API 키를 복사해요.\n② 아래 칸에 붙여 넣고 [연결]을 눌러요."))
	open_btn = UI.button("OpenCode 열기", "soft", Pal.PRIMARY)
	open_btn.pressed.connect(open_login)
	col.add_child(open_btn)

	key_edit = LineEdit.new()
	key_edit.name = "KeyEdit"
	key_edit.secret = true # the characters show as dots
	key_edit.placeholder_text = "여기에 API 키 붙여 넣기"
	key_edit.max_length = 300
	key_edit.context_menu_enabled = true
	key_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	key_edit.custom_minimum_size.y = 40.0
	key_edit.text_submitted.connect(func(_t: String) -> void: submit())
	col.add_child(key_edit)

	connect_btn = UI.button("연결", "primary", Pal.PRIMARY)
	connect_btn.pressed.connect(submit)
	col.add_child(connect_btn)

	status_label = UI.label("", "Small")
	col.add_child(status_label)
	bar = UI.progress_bar(0.0, Pal.PRIMARY)
	bar.visible = false
	col.add_child(bar)

	# D8: the terminal way is only a folded sentence (no button that starts a terminal)
	term_btn = UI.link_button("터미널로 연결하려면")
	term_btn.pressed.connect(toggle_terminal)
	col.add_child(term_btn)
	term_label = UI.label(TERMINAL_TEXT, "Small")
	term_label.visible = false
	col.add_child(term_label)
	col.add_child(UI.label(NOTE_TEXT, "Small"))

	sheet = Sheet.open(host, "AI 연결하기", col, [{"id": "later", "text": "나중에", "kind": "flat"}], {})
	sheet.closed.connect(_on_closed)
	UI.fix_cjk(col)


func toggle_terminal() -> void:
	term_label.visible = not term_label.visible
	term_btn.text = "터미널 안내 접기" if term_label.visible else "터미널로 연결하려면"
	if sheet != null and not _closed:
		sheet.relayout()


func open_login() -> void:
	if opener.is_valid():
		opener.call(LOGIN_URL)
	else:
		OS.shell_open(LOGIN_URL)


func _on_closed(result: Variant) -> void:
	_closed = true
	if key_edit != null and is_instance_valid(key_edit):
		key_edit.text = ""
	if str(result) == "later":
		auto_done = true # "나중에": the sheet does not come back by itself in this run
	if current == self:
		current = null


# ---------------------------------------------------------------- connect

## [연결] / Enter: the key leaves the field at once and goes to the backend exactly once.
func submit() -> void:
	if busy or _closed or key_edit == null:
		return
	var key: String = key_edit.text.strip_edges()
	if key == "":
		_say(MSG_EMPTY, "error")
		return
	_key_hash = key.sha256_text()
	key_edit.text = ""
	var req := Api.post_json("/llm/connect", {"key": key}, CONNECT_TIMEOUT, false)
	key = ""
	_await_connect(req)


func _await_connect(req: Api.ApiCall) -> void:
	_set_busy(true)
	_say(MSG_CONNECTING, "info")
	var res: Dictionary = await req.wait()
	req = null
	_set_busy(false)
	if bool(res.get("ok", false)):
		_after_connected(res.get("data"))
	elif str(res.get("err_code", "")) == "ai_not_installed":
		_say("AI 구성 요소가 없어서 먼저 받아요.", "info")
		start_install(true)
	else:
		_say(fail_text(res), "error")


func _after_connected(data: Variant) -> void:
	connected_ok = true
	# the clipboard may still hold the key: empty it only when it is the same text
	var got: Variant = clip_get.call() if clip_get.is_valid() else DisplayServer.clipboard_get()
	if str(got).strip_edges() != "" and str(got).strip_edges().sha256_text() == _key_hash:
		if clip_set.is_valid():
			clip_set.call("")
		else:
			DisplayServer.clipboard_set("")
	_key_hash = ""
	Backend.refresh_health()
	var tested: bool = not (data is Dictionary) or bool((data as Dictionary).get("tested", true))
	_say(MSG_OK if tested else MSG_OK_UNTESTED, "ok")
	if sheet != null and not _closed and sheet.buttons.has("later"):
		(sheet.buttons["later"] as Button).text = "닫기"


# ---------------------------------------------------------------- install (OpenCode components)

## POST /llm/install, then GET /llm/install until done (or an error). `again`: the key box was emptied by a refused
## connect, so the person is asked to paste it once more afterwards.
func start_install(again: bool = false) -> void:
	if installing or _closed:
		return
	installing = true
	_set_busy(true)
	bar.visible = true
	bar.value = 0.0
	_say(MSG_INSTALLING, "info")
	var res: Dictionary = await Api.post_json("/llm/install", {}, 30.0, false).wait()
	var failed: String = ""
	var errored: bool = false
	var done: bool = false
	if not bool(res.get("ok", false)):
		errored = true
		failed = fail_text(res)
	else:
		var d: Variant = res.get("data")
		var st: String = str((d as Dictionary).get("state", "")) if d is Dictionary else ""
		if st == "done" and bool((d as Dictionary).get("ok", true)):
			done = true
		elif st == "error" or (d is Dictionary and not bool((d as Dictionary).get("ok", true))):
			errored = true # HTTP 200 {"ok": false, "state": "error", "error": ...}: nothing to download
			failed = str((d as Dictionary).get("error", "")) if d is Dictionary else ""
	if not done and not errored:
		var r: Dictionary = await _poll_install()
		done = bool(r["done"])
		failed = str(r["error"])
	installing = false
	if _closed:
		if done:
			Backend.refresh_health()
		return
	bar.visible = false
	_set_busy(false)
	if done:
		Backend.refresh_health()
		_say(MSG_INSTALLED, "ok")
	else:
		_say(MSG_INSTALL_FAIL + (" " + failed if failed != "" else ""), "error")


func _poll_install() -> Dictionary:
	var waited: float = 0.0
	var idle: int = 0
	var fails: int = 0
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	while waited < INSTALL_MAX_SEC and not _closed:
		await tree.create_timer(poll_sec).timeout
		waited += poll_sec
		var g: Dictionary = await Api.get_json("/llm/install", 10.0, false).wait()
		if not bool(g.get("ok", false)) or not (g.get("data") is Dictionary):
			fails += 1
			if fails >= 5:
				return {"done": false, "error": MSG_NET}
			continue
		fails = 0
		var d: Dictionary = g["data"]
		match str(d.get("state", "")):
			"done":
				return {"done": true, "error": ""}
			"error":
				return {"done": false, "error": str(d.get("error", ""))}
			"idle":
				idle += 1
				if idle >= 5:
					return {"done": false, "error": "받기가 시작되지 않았어요."}
			_:
				idle = 0
				var pct: float = clampf(float(d.get("pct", 0)), 0.0, 100.0)
				if bar != null and is_instance_valid(bar):
					bar.value = pct / 100.0
				_say("%s %d%%" % [MSG_INSTALLING, int(pct)], "info")
	return {"done": false, "error": "" if _closed else "시간이 너무 오래 걸려요. 인터넷 연결을 확인하고 다시 시도해 주세요."}


# ---------------------------------------------------------------- small helpers

func _set_busy(b: bool) -> void:
	busy = b
	if _closed:
		return
	if connect_btn != null and is_instance_valid(connect_btn):
		connect_btn.disabled = b
	if key_edit != null and is_instance_valid(key_edit):
		key_edit.editable = not b


## kind: "info" | "ok" | "error". An error is told by a bold "! " in front, not by colour alone.
func _say(text: String, kind: String) -> void:
	if _closed or status_label == null or not is_instance_valid(status_label):
		return
	status_label.text = ("! " + text) if kind == "error" else text
	if sheet != null:
		sheet.relayout()
