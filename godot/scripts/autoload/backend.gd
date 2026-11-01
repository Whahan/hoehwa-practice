extends Node
## Backend lifecycle: health check, launching the Python server, killing it on quit.

signal status_changed

enum Status { IDLE, CHECKING, STARTING, READY, FAILED, NEEDS_PAIRING }

const MAX_WAIT_SECONDS := 90
const HEALTH_REFRESH_SECONDS := 15.0
const UNREACHABLE_TEXT := "PC에 닿지 않아요. 두 기기 모두 Tailscale이 켜져 있고 같은 계정인지, PC의 휴대폰 연결이 켜져 있는지 확인해 주세요."
const REVOKED_TEXT := "PC에서 이 휴대폰의 연결이 해제됐어요. 다시 연결해 주세요."

var status: Status = Status.IDLE
var health: Dictionary = {}
var message: String = ""
var pid: int = -1
var launched_by_us: bool = false
var remote_mode: bool = false   # phone: talk to a paired PC backend instead of launching one (W2)

var _starting: bool = false
var _fail_streak: int = 0
var _since_refresh: float = 0.0
var _shutdown_done: bool = false
var _paused: bool = false


func _ready() -> void:
	remote_mode = Platform.is_phone()
	Api.auth_failed.connect(_on_auth_failed)


func _process(delta: float) -> void:
	if status != Status.READY or _paused:
		return
	_since_refresh += delta
	if _since_refresh >= HEALTH_REFRESH_SECONDS:
		_since_refresh = 0.0
		# A busy engine (long LLM generation) may answer /health late: do not poll while
		# requests are in flight.
		if Api.active_count == 0:
			refresh_health()


func is_ready() -> bool:
	return status == Status.READY


## True when the server answers but its AI cannot be used yet: no login (`not_connected`), no OpenCode (`not_installed`)
## or an old PC program that says `llm: false`. `blocked` (limit / busy, still tried on every call) is not "missing".
func llm_missing() -> bool:
	if status != Status.READY:
		return false
	if not bool(health.get("llm", false)):
		return true
	var st: String = llm_state()
	return st == "not_connected" or st == "not_installed"


const LLM_LABELS := {"opencode": "DeepSeek V4.1 Flash (무료 · OpenCode)", "openai_api": "API 키 엔진"}
const LLM_STATES := ["ready", "not_connected", "not_installed", "blocked"]
const NOT_CONNECTED_PHONE_TEXT := "AI가 아직 연결되지 않았어요. PC의 회화 연습 설정에서 'AI 연결하기'를 눌러 주세요."


func llm_provider() -> String:
	return str(health.get("llm_provider", "opencode"))


func llm_label() -> String:
	return str(LLM_LABELS.get(llm_provider(), llm_provider()))


## `ready | not_connected | not_installed | blocked` from /health. An old PC program (no `llm_state`) is derived from `llm`.
func llm_state() -> String:
	var v: Variant = health.get("llm_state", "")
	if v is String and (v as String) in LLM_STATES:
		return v
	return "ready" if bool(health.get("llm", false)) else "not_connected"


## What to tell the person when the AI cannot be used (by `llm_state`). The phone is only told to use the PC.
func llm_missing_text() -> String:
	var st: String = llm_state()
	if st == "blocked":
		var fb: Variant = health.get("llm_fallback", {})
		var why: String = str((fb as Dictionary).get("reason", "")) if fb is Dictionary else ""
		return why if why != "" else "AI를 잠시 쓸 수 없어요. 잠시 뒤 다시 시도해 주세요."
	if llm_provider() == "openai_api" and st != "ready":
		return "API 키가 없어요. backend 폴더의 config.json 에서 openai_api 설정을 확인해 주세요."
	if remote_mode or Platform.is_phone():
		return NOT_CONNECTED_PHONE_TEXT
	if st == "not_installed":
		return "AI 구성 요소가 없어요. [AI 연결하기]에서 받을 수 있어요."
	return "AI가 아직 연결되지 않았어요. [AI 연결하기]에서 한 번만 연결하면 대화와 AI 레슨을 쓸 수 있어요."


func _set_status(s: Status, msg: String = "") -> void:
	status = s
	message = msg
	status_changed.emit()


# ---------------------------------------------------------------- locating the server

## Folder that contains server.py, or "" if it cannot be found.
func find_backend_dir() -> String:
	var candidates: Array[String] = []
	if OS.has_feature("editor"):
		var proj: String = ProjectSettings.globalize_path("res://")
		candidates.append(proj.path_join("../backend").simplify_path())
	else:
		var exe_dir: String = OS.get_executable_path().get_base_dir()
		candidates.append(exe_dir.path_join("backend").simplify_path())
		candidates.append(exe_dir.path_join("../backend").simplify_path())
	for c in candidates:
		if DirAccess.dir_exists_absolute(c):
			return c
	return ""


## Interpreter for server.py: the install package ships a portable Python in <root>/runtime/python
## (the folder next to backend/); the dev PC keeps using backend/.venv.
func python_path(dir: String) -> String:
	var portable: String = dir.path_join("../runtime/python/pythonw.exe").simplify_path()
	if FileAccess.file_exists(portable):
		return portable
	return dir.path_join(".venv/Scripts/pythonw.exe")


# ---------------------------------------------------------------- lifecycle

func check_health() -> bool:
	var req_call = Api.get_json("/health", 3.0, false)
	var res: Dictionary = await req_call.wait()
	if res["ok"] and res["data"] is Dictionary and bool((res["data"] as Dictionary).get("ok", false)):
		health = res["data"]
		return true
	return false


## Re-reads /health (used by the settings "다시 확인" button and periodically).
func refresh_health() -> void:
	var ok: bool = await check_health()
	if ok:
		_fail_streak = 0
		if status != Status.READY:
			_set_status(Status.READY)
		else:
			status_changed.emit()
	elif status == Status.READY:
		_fail_streak += 1
		if _fail_streak >= 2:
			health = {}
			_set_status(Status.FAILED, UNREACHABLE_TEXT if remote_mode else "AI 엔진과 연결이 끊겼어요.")


## Uses the port from backend/config.json when it is not the default one.
func _adopt_config_port() -> void:
	if Api.base_overridden:
		return
	var dir: String = find_backend_dir()
	if dir == "":
		return
	var cfg: String = dir.path_join("config.json")
	if not FileAccess.file_exists(cfg):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(cfg))
	if parsed is Dictionary and (parsed as Dictionary).has("port"):
		var port: int = int((parsed as Dictionary)["port"])
		if port > 0 and port < 65536:
			Api.base_url = "http://127.0.0.1:%d" % port


func start() -> void:
	if _starting:
		return
	_starting = true
	if remote_mode:
		# Phone: never look for / launch a local server (no find_backend_dir, python_path, create_process).
		# A pairing made while this check was waiting restarts the check for the new connection.
		while not await _start_remote():
			pass
		_starting = false
		return
	_adopt_config_port()
	_set_status(Status.CHECKING, "AI 엔진 확인 중…")
	if await check_health():
		_set_status(Status.READY)
		_starting = false
		Store.refresh_curriculum()
		return

	var dir: String = find_backend_dir()
	if dir == "":
		_set_status(Status.FAILED, "backend 폴더를 찾지 못했어요. 앱 옆(또는 한 단계 위)에 backend 폴더가 있어야 해요.")
		_starting = false
		return
	var py: String = python_path(dir)
	var server: String = dir.path_join("server.py")
	if not FileAccess.file_exists(py):
		_set_status(Status.FAILED, "파이썬 환경이 아직 없어요. 설치.bat(개발 PC는 backend 폴더의 setup.ps1)을 먼저 실행해 주세요.")
		_starting = false
		return
	if not FileAccess.file_exists(server):
		_set_status(Status.FAILED, "backend\\server.py를 찾지 못했어요.")
		_starting = false
		return

	pid = OS.create_process(py, PackedStringArray([server]))
	if pid <= 0:
		pid = -1
		_set_status(Status.FAILED, "AI 엔진을 시작하지 못했어요.")
		_starting = false
		return
	launched_by_us = true
	_set_status(Status.STARTING, "AI 엔진 준비 중…")

	var waited := 0
	while waited < MAX_WAIT_SECONDS:
		await get_tree().create_timer(1.0).timeout
		waited += 1
		if await check_health():
			_set_status(Status.READY)
			_starting = false
			Store.refresh_curriculum()
			return
		_set_status(Status.STARTING, "AI 엔진 준비 중… (%d초)" % waited)
	if status != Status.READY:
		_set_status(Status.FAILED, "AI 엔진이 %d초 안에 준비되지 않았어요. 잠시 뒤 설정에서 '다시 확인'을 눌러 주세요." % MAX_WAIT_SECONDS)
	_starting = false


# ---------------------------------------------------------------- phone: paired PC

## Reads the saved pairing (or the test injection `--api= --token=`) and checks the PC.
func _saved_connection() -> Dictionary:
	var conn: Dictionary = RemoteLink.load_saved(Api.remote_path)
	if Api.cli_base_url != "" and str(conn.get("base_url", "")) != Api.cli_base_url:
		# --api= points somewhere else than the pairing: the saved token must never be sent to that address.
		# Only an explicit --token= (tests) goes with it.
		return {"base_url": Api.cli_base_url, "token": Api.cli_token, "device_id": "", "server_name": ""}
	if Api.cli_token != "" and not conn.is_empty():
		conn["token"] = Api.cli_token
	return conn


## Returns false when the connection was replaced (new pairing / disconnect) while the check was waiting: the late
## result belongs to the old connection and is dropped; the caller starts over with the current one.
func _start_remote() -> bool:
	var conn: Dictionary = _saved_connection()
	if str(conn.get("token", "")) == "" or str(conn.get("base_url", "")) == "":
		# Not paired: no network at all.
		Api.clear_remote()
		health = {}
		_set_status(Status.NEEDS_PAIRING, "")
		return true
	Api.set_remote(str(conn["base_url"]), str(conn["token"]))
	_set_status(Status.CHECKING, "PC에 연결 중…")
	var ok: bool = await check_health()
	if status == Status.NEEDS_PAIRING:
		return true   # the PC answered 401: the pairing was revoked (see _on_auth_failed)
	if Api.base_url != str(conn["base_url"]).rstrip("/") or Api.token != str(conn["token"]):
		return false
	if ok:
		_fail_streak = 0
		_set_status(Status.READY)
		Store.refresh_curriculum()
		return true
	# No discovery (the link is Tailscale only): the saved address is the only one we try.
	health = {}
	_set_status(Status.FAILED, UNREACHABLE_TEXT)
	return true


## The PC no longer knows this phone: forget the token (keep address and PC name for the connect screen).
func _on_auth_failed(_code: String) -> void:
	if not remote_mode or status == Status.NEEDS_PAIRING:
		return
	RemoteLink.clear_token(Api.remote_path)
	Api.clear_remote()
	health = {}
	_set_status(Status.NEEDS_PAIRING, REVOKED_TEXT)


## "연결 끊기": forget the token locally (the caller already asked the PC to unpair, best effort).
func forget_pairing() -> void:
	RemoteLink.clear_token(Api.remote_path)
	Api.clear_remote()
	health = {}
	_set_status(Status.NEEDS_PAIRING, "")


func shutdown() -> void:
	if _shutdown_done:
		return
	_shutdown_done = true
	Api.arm_exit_watchdog()   # a request that cannot be interrupted must not hold the quit for minutes
	if launched_by_us and pid > 0:
		if OS.get_name() == "Windows":
			# pythonw.exe from a venv may be a launcher that spawns the real interpreter: kill the tree.
			OS.execute("taskkill", PackedStringArray(["/PID", str(pid), "/T", "/F"]), [], true, false)
		else:
			OS.kill(pid)
		pid = -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		shutdown()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		_paused = true   # phone in the background: no polling
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_paused = false
		if remote_mode:
			_since_refresh = 0.0
			if status == Status.READY:
				refresh_health()
			elif status == Status.FAILED:
				start()


func _exit_tree() -> void:
	shutdown()
