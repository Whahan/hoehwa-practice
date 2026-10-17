extends Node
## HTTP client for the Python backend (see API.md).
##
## PC: talks to the local backend on 127.0.0.1:8770 without any token.
## Phone (Platform.is_phone()): talks to a paired PC on the LAN with `Authorization: Bearer <token>`
## (docs/android_remote_design.md section 4.3). Until `set_remote()` is called a phone has no address
## and requests fail at once without touching the network.
##
## Usage:
##   var req_call := Api.post_json("/chat", body, 180.0)
##   var res: Dictionary = await req_call.wait()
##   if res.ok: ... res.data ...
##   req_call.cancel()   # from another place, e.g. a "cancel" button
##
## Result dictionary: {ok: bool, code: int, data: Variant, bytes: PackedByteArray,
##                     error: String (Korean), cancelled: bool,
##                     err_code: String (server `code` field, "" when absent), err_body: Variant}

## Emitted once per paired session when the PC says the token is missing or revoked (HTTP 401).
signal auth_failed(code: String)

const BASE_URL := "http://127.0.0.1:8770"

const TIMEOUT_SHORT := 60.0
const TIMEOUT_SHORT_PHONE := 90.0
const TIMEOUT_LLM := 180.0

const NOT_CONNECTED_TEXT := "PC에 연결되지 않았어요."
const UNREACHABLE_TEXT := "PC에 닿지 않아요. PC가 켜져 있고 같은 와이파이인지, PC 앱의 '휴대폰 연결'이 켜져 있는지 확인해 주세요."
const RETRY_DELAY_SEC := 0.3
const RESUME_GRACE_MSEC := 8000
const EXIT_GRACE_MSEC := 1500

## POST paths that are safe to send twice (no side effects on the PC). Every GET is safe as well.
const IDEMPOTENT_POST := ["/tts", "/stt", "/score", "/prosody"]
const IDEMPOTENT_POST_PREFIX := ["/reading/"]

## Overridable for tests: `godot ... -- --api=http://127.0.0.1:8771`
var base_url: String = BASE_URL
var base_overridden: bool = false
var active_count: int = 0 ## requests currently in flight
## Bearer token of the paired PC ("" = PC mode / not paired).
var token: String = ""
## Where the pairing is stored (tests: `--remote-file=user://x.json`).
var remote_path: String = RemoteLink.PATH
## Counts every request that really left through an HTTPRequest (tests).
var sent_count: int = 0

## Cancelled requests whose HTTPRequest is still running (see ApiCall.cancel()). Tests.
var orphan_count: int = 0
## `--token=` from the command line (tests); only used together with `--api=`.
var cli_token: String = ""
## `--api=` from the command line (clear_remote() empties base_url, this stays).
var cli_base_url: String = ""
var _auth_failed_sent: bool = false
var _watchdog: Thread = null
var _resumed_msec: int = -1000000   ## when the app last came back to the foreground


func _ready() -> void:
	if Platform.is_phone():
		base_url = ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api="):
			base_url = a.substr(6).rstrip("/")
			cli_base_url = base_url
			base_overridden = true
		elif a.begins_with("--token="):
			cli_token = a.substr(8)
		elif a.begins_with("--remote-file="):
			remote_path = a.substr(14)
	# A token is only accepted together with --api= (test injection).
	if cli_token != "" and base_overridden:
		token = cli_token


## Points the client at a paired PC. Every later request carries the Bearer token.
func set_remote(url: String, new_token: String) -> void:
	base_url = url.rstrip("/")
	token = new_token
	_auth_failed_sent = false


## Forgets the PC (disconnect / revoked). A phone then has no address; a PC goes back to the local one.
func clear_remote() -> void:
	token = ""
	_auth_failed_sent = false
	base_url = "" if Platform.is_phone() else BASE_URL


func is_remote() -> bool:
	return token != "" or Platform.is_phone()


class ApiCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}
	var path: String = ""
	var on_cancel: Callable = Callable()
	var method: int = HTTPClient.METHOD_GET
	var payload: String = ""
	var timeout: float = 60.0
	var base: String = ""
	var use_auth: bool = true
	var retries: int = 0
	var in_flight: bool = false
	var _req: HTTPRequest = null

	## Awaitable: returns immediately if already finished.
	func wait() -> Dictionary:
		if done:
			return result
		return await finished

	func cancel() -> void:
		if done:
			return
		if _req != null and is_instance_valid(_req):
			if in_flight:
				# Godot 4.6.3: HTTPRequest.cancel_request() (and removing the node, which calls it) blocks the
				# main thread forever while a threaded request waits for the answer. Let the request end by
				# itself (it has a timeout) and free the node afterwards.
				var orphan: HTTPRequest = _req
				_req = null
				Api.orphan_count += 1
				orphan.request_completed.connect(func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
					Api.orphan_count = maxi(0, Api.orphan_count - 1)
					orphan.queue_free(), CONNECT_ONE_SHOT)
			else:
				_req.cancel_request()
		if on_cancel.is_valid():
			on_cancel.call()
		_complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true, "err_code": "", "err_body": null})

	func _complete(res: Dictionary) -> void:
		if done:
			return
		done = true
		result = res
		if _req != null and is_instance_valid(_req):
			_req.queue_free()
		_req = null
		finished.emit(res)


func get_json(path: String, timeout: float = TIMEOUT_SHORT, report: bool = true) -> ApiCall:
	return _start(HTTPClient.METHOD_GET, path, null, timeout, report)


func post_json(path: String, body: Dictionary, timeout: float = TIMEOUT_SHORT, report: bool = true) -> ApiCall:
	return _start(HTTPClient.METHOD_POST, path, body, timeout, report)


## Requests to an explicit address WITHOUT the Authorization header (RemoteLink.hello / pair / proof).
func get_json_to(base: String, path: String, timeout: float = 5.0, report: bool = false) -> ApiCall:
	return _start(HTTPClient.METHOD_GET, path, null, timeout, report, base.rstrip("/"), false)


func post_json_to(base: String, path: String, body: Dictionary, timeout: float = 10.0, report: bool = false) -> ApiCall:
	return _start(HTTPClient.METHOD_POST, path, body, timeout, report, base.rstrip("/"), false)


func _start(method: int, path: String, body: Variant, timeout: float, report: bool, base_override: String = "", auth: bool = true) -> ApiCall:
	var req_call := ApiCall.new()
	req_call.path = path
	req_call.method = method
	req_call.use_auth = auth
	req_call.base = base_override if base_override != "" else base_url
	if is_equal_approx(timeout, TIMEOUT_SHORT) and Platform.is_phone():
		timeout = TIMEOUT_SHORT_PHONE
	req_call.timeout = timeout
	if body != null:
		req_call.payload = JSON.stringify(body)
	active_count += 1
	req_call.on_cancel = func() -> void: active_count = maxi(0, active_count - 1)
	if req_call.base == "":
		# A phone that is not paired yet: no network, no 127.0.0.1.
		_finish_later(req_call, _fail(0, NOT_CONNECTED_TEXT, "not_connected"), report)
		return req_call
	var err: int = _send(req_call, report)
	if err != OK:
		var msg := "요청을 보내지 못했어요. 앱을 다시 시작해 주세요. (코드 %d)" % err
		_finish_later(req_call, _fail(0, msg), report)
	return req_call


## Creates the HTTPRequest for `req_call` and sends it. Used for the first try and for the single retry.
func _send(req_call: ApiCall, report: bool) -> int:
	var req := HTTPRequest.new()
	req.timeout = req_call.timeout
	req.use_threads = true
	add_child(req)
	req_call._req = req
	req.request_completed.connect(_on_completed.bind(req_call, report))
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json, audio/wav"])
	if req_call.use_auth and token != "":
		headers.append("Authorization: Bearer " + token)
	sent_count += 1
	req_call.in_flight = true
	var err: int = req.request(req_call.base + req_call.path, headers, req_call.method, req_call.payload)
	if err != OK:
		req_call.in_flight = false
	return err


func _finish_later(req_call: ApiCall, res: Dictionary, report: bool) -> void:
	await get_tree().process_frame
	active_count = maxi(0, active_count - 1)
	if report and res.get("error", "") != "":
		Toast.error(res["error"])
	req_call._complete(res)


func _fail(code: int, msg: String, err_code: String = "", err_body: Variant = null) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": msg, "cancelled": false, "err_code": err_code, "err_body": err_body}


static func is_idempotent(method: int, path: String) -> bool:
	if method == HTTPClient.METHOD_GET:
		return true
	var p: String = path.split("?")[0]
	if p in IDEMPOTENT_POST:
		return true
	for pre in IDEMPOTENT_POST_PREFIX:
		if p.begins_with(pre):
			return true
	return false


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, req_call: ApiCall, report: bool) -> void:
	if req_call.done:
		return
	req_call.in_flight = false
	# The connection broke (Wi-Fi hiccup, app just came back): one more try, only for requests without side effects.
	if result != HTTPRequest.RESULT_SUCCESS and is_remote() and req_call.retries < 1 and _connection_broke(result) and is_idempotent(req_call.method, req_call.path):
		req_call.retries += 1
		_retry_later(req_call, report)
		return
	active_count = maxi(0, active_count - 1)
	var res: Dictionary
	if result != HTTPRequest.RESULT_SUCCESS:
		res = _fail(0, _transport_error(result), "transport")
	elif code >= 200 and code < 300:
		res = {"ok": true, "code": code, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": false, "err_code": "", "err_body": null}
		if _looks_like_wav(body):
			res["bytes"] = body
		else:
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if parsed == null and body.size() > 0:
				res = _fail(code, "서버 응답을 읽지 못했어요. 잠시 뒤 다시 시도해 주세요.")
			else:
				res["data"] = parsed
	else:
		var msg := ""
		var err_code := ""
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary:
			if (parsed as Dictionary).has("error"):
				msg = str((parsed as Dictionary)["error"])
			err_code = str((parsed as Dictionary).get("code", ""))
		if msg == "":
			msg = "서버에서 오류가 났어요. (코드 %d)" % code
		res = _fail(code, msg, err_code, parsed)
		if code == 401 and req_call.use_auth and token != "" and (err_code == "token_missing" or err_code == "token_invalid") and not _auth_failed_sent:
			_auth_failed_sent = true
			auth_failed.emit(err_code)
	if report and not res["ok"] and res["error"] != "":
		Toast.error(res["error"])
	req_call._complete(res)


## True for "the connection broke" failures. Right after the app came back from the background the OS may have
## killed the socket in other ways too, so every failure except a timeout counts for a few seconds.
func _connection_broke(result: int) -> bool:
	if result == HTTPRequest.RESULT_CANT_CONNECT or result == HTTPRequest.RESULT_CONNECTION_ERROR:
		return true
	if Time.get_ticks_msec() - _resumed_msec < RESUME_GRACE_MSEC:
		return result != HTTPRequest.RESULT_TIMEOUT and result != HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_resumed_msec = Time.get_ticks_msec()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		arm_exit_watchdog()


## Godot 4.6.3: a threaded HTTPRequest cannot be interrupted while it waits for the answer, and quitting waits for it
## (measured: the process lingered until the server closed the connection, 58 s). When the app is about to quit with a
## request still out (running or cancelled-but-not-finished), a watchdog thread ends the process after `grace_msec`
## if the normal shutdown has not finished by then. Called from Backend.shutdown() and on the window close request.
func arm_exit_watchdog(grace_msec: int = EXIT_GRACE_MSEC) -> void:
	if _watchdog != null or (orphan_count <= 0 and active_count <= 0):
		return
	var pid: int = OS.get_process_id()
	_watchdog = Thread.new()
	_watchdog.start(func() -> void:
		OS.delay_msec(grace_msec)
		OS.kill(pid))


func _retry_later(req_call: ApiCall, report: bool) -> void:
	if req_call._req != null and is_instance_valid(req_call._req):
		req_call._req.queue_free()
	req_call._req = null
	await get_tree().create_timer(RETRY_DELAY_SEC).timeout
	if req_call.done:
		return
	var err: int = _send(req_call, report)
	if err != OK:
		active_count = maxi(0, active_count - 1)
		req_call._complete(_fail(0, _transport_error(HTTPRequest.RESULT_CANT_CONNECT), "transport"))


static func _looks_like_wav(b: PackedByteArray) -> bool:
	return b.size() > 12 and b[0] == 0x52 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x46


static func _transport_error(result: int) -> String:
	var phone: bool = Platform.is_phone()
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			if phone:
				return UNREACHABLE_TEXT
			return "AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요."
		HTTPRequest.RESULT_TIMEOUT:
			return "응답이 너무 오래 걸려서 멈췄어요. 잠시 뒤 다시 시도해 주세요."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "받은 데이터를 처리하지 못했어요."
		_:
			if phone and result == HTTPRequest.RESULT_NO_RESPONSE:
				return UNREACHABLE_TEXT
			return "통신 중 문제가 생겼어요. (코드 %d)" % result
