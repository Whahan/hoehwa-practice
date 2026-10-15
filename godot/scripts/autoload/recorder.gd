extends Node
## Microphone recording, done by the local backend (POST /mic/start, GET /mic/level, POST /mic/stop).
##
## Godot does not open the microphone itself: its WASAPI input crashed the whole app with some
## USB audio interfaces (ZOOM H/F series) when the input was opened and closed for every
## recording. The backend records with PortAudio; a failure there only fails one request.
##
## Typical use: Recorder.begin(owner_id) ... Recorder.end() -> emits `finished(result)` once the
## backend has handed back the audio.
## result = {ok, silent, duration, b64: String (16 kHz mono WAV, base64), wav: PackedByteArray, owner: int}

signal finished(result: Dictionary)
signal started

const MAX_SECONDS := 30.0
const LEVEL_POLL_SEC := 0.12

var recording: bool = false  ## true from begin() until end()/cancel()
var stopping: bool = false   ## end() called, waiting for the audio
var elapsed: float = 0.0
var level: float = 0.0 ## 0..1 input level reported by the backend
var owner_id: int = 0

var _poll_wait: float = 0.0
var _poll_busy: bool = false
var _start_serial: int = 0


func _ready() -> void:
	Backend.status_changed.connect(func() -> void:
		if Backend.status == Backend.Status.READY and _devices.is_empty():
			refresh_devices())


func input_devices() -> PackedStringArray:
	## Filled asynchronously by refresh_devices(); "Default" is always first.
	var out := PackedStringArray(["Default"])
	for d in _devices:
		out.append(d)
	return out


var _devices: PackedStringArray = PackedStringArray()


func refresh_devices() -> void:
	var req = Api.get_json("/mic/devices", 10.0, false)
	var res: Dictionary = await req.wait()
	if res["ok"] and res["data"] is Dictionary:
		var arr: Variant = (res["data"] as Dictionary).get("devices", [])
		_devices = PackedStringArray()
		if arr is Array:
			for d in arr:
				_devices.append(str(d))


func apply_device(name: String) -> void:
	Store.set_pref("mic_device", name)


func begin(for_owner: int = 0) -> bool:
	if recording or stopping:
		return false
	Tts.stop()
	recording = true
	elapsed = 0.0
	level = 0.0
	owner_id = for_owner
	_poll_wait = 0.0
	_start_serial += 1
	var serial: int = _start_serial
	started.emit()
	_open_backend_mic(serial)
	return true


func _open_backend_mic(serial: int) -> void:
	var dev: String = str(Store.prefs.get("mic_device", "Default"))
	var req = Api.post_json("/mic/start", {"device": "" if dev == "Default" else dev}, 10.0, false)
	var res: Dictionary = await req.wait()
	if serial != _start_serial or res["ok"]:
		return
	recording = false
	level = 0.0
	Toast.error(str(res["error"]) if str(res["error"]) != "" else "마이크를 열지 못했어요.")
	finished.emit({"ok": false, "silent": false, "duration": 0.0, "owner": owner_id, "b64": "", "wav": PackedByteArray(), "reported": true})


## Stops recording. The result arrives through `finished` when the backend returns the audio.
func end() -> void:
	if not recording:
		return
	recording = false
	stopping = true
	level = 0.0
	var who: int = owner_id
	var req = Api.post_json("/mic/stop", {}, 20.0, false)
	var res: Dictionary = await req.wait()
	stopping = false
	var result := {"ok": false, "silent": false, "duration": 0.0, "owner": who, "b64": "", "wav": PackedByteArray()}
	if res["ok"] and res["data"] is Dictionary:
		var d: Dictionary = res["data"]
		if bool(d.get("ok", false)) and str(d.get("b64", "")) != "":
			result["ok"] = true
			result["b64"] = str(d["b64"])
			result["wav"] = Marshalls.base64_to_raw(result["b64"])
			result["duration"] = float(d.get("duration", 0.0))
			result["silent"] = bool(d.get("silent", false))
	finished.emit(result)


func cancel() -> void:
	if not recording:
		return
	recording = false
	level = 0.0
	_start_serial += 1
	Api.post_json("/mic/cancel", {}, 10.0, false)


func _process(delta: float) -> void:
	if not recording:
		return
	elapsed += delta
	if elapsed >= MAX_SECONDS:
		end()
		return
	_poll_wait -= delta
	if _poll_wait <= 0.0 and not _poll_busy:
		_poll_wait = LEVEL_POLL_SEC
		_poll_level()


func _poll_level() -> void:
	_poll_busy = true
	var req = Api.get_json("/mic/level", 2.0, false)
	var res: Dictionary = await req.wait()
	_poll_busy = false
	if recording and res["ok"] and res["data"] is Dictionary:
		level = clampf(float((res["data"] as Dictionary).get("level", 0.0)), 0.0, 1.0)
