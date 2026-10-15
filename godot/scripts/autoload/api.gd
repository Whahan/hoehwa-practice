extends Node
## HTTP client for the local Python backend (see API.md).
##
## Usage:
##   var req_call := Api.post_json("/chat", body, 180.0)
##   var res: Dictionary = await req_call.wait()
##   if res.ok: ... res.data ...
##   req_call.cancel()   # from another place, e.g. a "cancel" button
##
## Result dictionary: {ok: bool, code: int, data: Variant, bytes: PackedByteArray,
##                     error: String (Korean), cancelled: bool}

const BASE_URL := "http://127.0.0.1:8770"

const TIMEOUT_SHORT := 60.0
const TIMEOUT_LLM := 180.0

## Overridable for tests: `godot ... -- --api=http://127.0.0.1:8771`
var base_url: String = BASE_URL
var base_overridden: bool = false
var active_count: int = 0 ## requests currently in flight


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api="):
			base_url = a.substr(6).rstrip("/")
			base_overridden = true


class ApiCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}
	var path: String = ""
	var on_cancel: Callable = Callable()
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
			_req.cancel_request()
		if on_cancel.is_valid():
			on_cancel.call()
		_complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true})

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


func _start(method: int, path: String, body: Variant, timeout: float, report: bool) -> ApiCall:
	var req_call := ApiCall.new()
	req_call.path = path
	var req := HTTPRequest.new()
	req.timeout = timeout
	req.use_threads = true
	add_child(req)
	active_count += 1
	req_call._req = req
	req_call.on_cancel = func() -> void: active_count = maxi(0, active_count - 1)
	req.request_completed.connect(_on_completed.bind(req_call, report))
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json, audio/wav"])
	var payload := ""
	if body != null:
		payload = JSON.stringify(body)
	var err: int = req.request(base_url + path, headers, method, payload)
	if err != OK:
		var msg := "요청을 보내지 못했어요. 앱을 다시 시작해 주세요. (코드 %d)" % err
		_finish_later(req_call, _fail(0, msg), report)
	return req_call


func _finish_later(req_call: ApiCall, res: Dictionary, report: bool) -> void:
	await get_tree().process_frame
	active_count = maxi(0, active_count - 1)
	if report and res.get("error", "") != "":
		Toast.error(res["error"])
	req_call._complete(res)


func _fail(code: int, msg: String) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": msg, "cancelled": false}


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, req_call: ApiCall, report: bool) -> void:
	if req_call.done:
		return
	active_count = maxi(0, active_count - 1)
	var res: Dictionary
	if result != HTTPRequest.RESULT_SUCCESS:
		res = _fail(0, _transport_error(result))
	elif code >= 200 and code < 300:
		res = {"ok": true, "code": code, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": false}
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
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary and (parsed as Dictionary).has("error"):
			msg = str((parsed as Dictionary)["error"])
		if msg == "":
			msg = "서버에서 오류가 났어요. (코드 %d)" % code
		res = _fail(code, msg)
	if report and not res["ok"] and res["error"] != "":
		Toast.error(res["error"])
	req_call._complete(res)


static func _looks_like_wav(b: PackedByteArray) -> bool:
	return b.size() > 12 and b[0] == 0x52 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x46


static func _transport_error(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			return "AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요."
		HTTPRequest.RESULT_TIMEOUT:
			return "응답이 너무 오래 걸려서 멈췄어요. 잠시 뒤 다시 시도해 주세요."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "받은 데이터를 처리하지 못했어요."
		_:
			return "통신 중 문제가 생겼어요. (코드 %d)" % result
