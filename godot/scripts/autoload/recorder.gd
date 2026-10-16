extends Node
## Microphone recording.
##
## PC: done by the local backend (POST /mic/start, GET /mic/level, POST /mic/stop).
## Godot does not open the microphone itself there: its WASAPI input crashed the whole app with some
## USB audio interfaces (ZOOM H/F series) when the input was opened and closed for every
## recording. The backend records with PortAudio; a failure there only fails one request.
##
## Android: Godot records with AudioStreamMicrophone -> bus "Record" (AudioEffectRecord) and sends a
## mono 16-bit WAV in `b64` (the PC converts to 16 kHz itself). See docs/android_remote_design.md section 4.6.
## Desktop `-- --phone`: the microphone is never opened (see `test_audio_source`).
##
## Typical use: Recorder.begin(owner_id) ... Recorder.end() -> emits `finished(result)` once the
## audio is ready.
## result = {ok, silent, duration, b64: String (mono 16-bit WAV, base64), wav: PackedByteArray, owner: int,
##           reported: bool (only on failures: the user was already told why), stream: AudioStreamWAV (Android)}

signal finished(result: Dictionary)
signal started

const MAX_SECONDS := 30.0
const LEVEL_POLL_SEC := 0.12
const SILENT_PEAK := 0.003          ## same threshold as the backend (server.py mic_stop)
const PERMISSION_WAIT_SEC := 60.0
const RECORD_BUS := "Record"
const DENIED_TEXT := "마이크 권한이 꺼져 있어요. 휴대폰 설정 > 앱 > 회화 연습 > 권한 > 마이크를 허용해 주세요."

var recording: bool = false  ## true from begin() until end()/cancel()
var stopping: bool = false   ## end() called, waiting for the audio
var elapsed: float = 0.0
var level: float = 0.0 ## 0..1 input level reported by the backend
var owner_id: int = 0

## Tests: "" = decide from Platform, or "pc" | "phone" (desktop --phone) | "android".
var mode_override: String = ""
## Desktop `--phone` only: Callable() -> AudioStreamWAV used as the microphone (tests, screenshots).
var test_audio_source: Callable = Callable()
## Tests: replace pieces of the Android microphone path. Keys (all optional Callables):
## "granted" () -> bool, "request" () -> bool (coroutine ok), "open" () -> bool, "close" (), "recording" () -> AudioStreamWAV,
## "level" () -> float
var test_hooks: Dictionary = {}

var _poll_wait: float = 0.0
var _poll_busy: bool = false
var _start_serial: int = 0
var _mic_live: bool = false       ## Godot-side capture is running (Android / hook)
var _mic_player: AudioStreamPlayer = null
var _record_fx: AudioEffectRecord = null
var _capture_fx: AudioEffectCapture = null
var _perm_result: int = -1        ## -1 waiting, 0 denied, 1 granted
var _devices: PackedStringArray = PackedStringArray()


func _ready() -> void:
	Backend.status_changed.connect(func() -> void:
		if mode() == "pc" and Backend.status == Backend.Status.READY and _devices.is_empty():
			refresh_devices())


## "pc" | "phone" (desktop --phone, no microphone) | "android"
func mode() -> String:
	if mode_override != "":
		return mode_override
	if Platform.is_android():
		return "android"
	if Platform.is_phone():
		return "phone"
	return "pc"


func input_devices() -> PackedStringArray:
	## Filled asynchronously by refresh_devices(); "Default" is always first.
	var out := PackedStringArray(["Default"])
	if mode() != "pc":
		return out
	for d in _devices:
		out.append(d)
	return out


func refresh_devices() -> void:
	if mode() != "pc":
		return
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
	if mode() == "pc":
		_open_backend_mic(serial)
	else:
		_begin_godot(serial)
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


## Stops recording. The result arrives through `finished` when the audio is ready.
func end() -> void:
	if not recording:
		return
	recording = false
	stopping = true
	level = 0.0
	var who: int = owner_id
	if mode() != "pc":
		_end_godot(who)
		return
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
	if mode() != "pc":
		_mic_close()
		return
	Api.post_json("/mic/cancel", {}, 10.0, false)


func _process(delta: float) -> void:
	if not recording:
		return
	if mode() != "pc":
		if not _mic_live:
			return   # still waiting for the permission dialog
		elapsed += delta
		level = _read_level()
		if elapsed >= MAX_SECONDS:
			end()
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


## The phone leaves the foreground: never keep the microphone (or the speaker) running in the background.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		if recording:
			cancel()
		Tts.stop()


# ---------------------------------------------------------------- Godot-side recording (Android, hooks)

func _begin_godot(serial: int) -> void:
	await get_tree().process_frame   # `started` is delivered before any failure
	if serial != _start_serial or not recording:
		return
	if mode() == "phone" and not test_audio_source.is_valid():
		_fail_start("이 환경에서는 마이크를 쓸 수 없어요(시험 모드).")
		return
	var granted: bool = await _ensure_permission()
	if serial != _start_serial or not recording:
		return
	if not granted:
		_fail_start(DENIED_TEXT)
		return
	if not _mic_open():
		_fail_start("마이크를 열지 못했어요.")
		return
	_mic_live = true
	elapsed = 0.0


func _fail_start(msg: String) -> void:
	recording = false
	_mic_live = false
	level = 0.0
	if msg != "":
		Toast.error(msg)
	finished.emit({"ok": false, "silent": false, "duration": 0.0, "owner": owner_id, "b64": "", "wav": PackedByteArray(), "reported": true})


func _end_godot(who: int) -> void:
	var live: bool = _mic_live
	var rec: AudioStreamWAV = null
	if live:
		rec = _mic_stop()
	_mic_close()
	if not live:
		# stopped while the permission dialog was still open
		stopping = false
		_start_serial += 1
		finished.emit({"ok": false, "silent": false, "duration": 0.0, "owner": who, "b64": "", "wav": PackedByteArray(), "reported": true})
		return
	var result := {"ok": false, "silent": false, "duration": 0.0, "owner": who, "b64": "", "wav": PackedByteArray()}
	if rec != null and rec.data.size() > 0:
		var box := {}
		var task: int = WorkerThreadPool.add_task(func() -> void: _convert(rec, box), false, "recorder convert")
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		if box.has("b64"):
			result["ok"] = true
			result["b64"] = box["b64"]
			result["wav"] = box["wav"]
			result["duration"] = box["duration"]
			result["silent"] = float(box["peak"]) < SILENT_PEAK
			result["stream"] = box["stream"]
	stopping = false
	finished.emit(result)


## Runs in a worker thread: only touches `rec` and `box`.
static func _convert(rec: AudioStreamWAV, box: Dictionary) -> void:
	var r: Dictionary = WavUtil.mono16_with_peak(rec, MAX_SECONDS)
	var st: AudioStreamWAV = r.get("stream", null)
	if st == null:
		return
	var wav: PackedByteArray = WavUtil.to_wav_bytes(st)
	box["stream"] = st
	box["wav"] = wav
	box["b64"] = Marshalls.raw_to_base64(wav)
	box["duration"] = WavUtil.duration(st)
	box["peak"] = r["peak"]


func _hook(key: String) -> Callable:
	var c: Variant = test_hooks.get(key, null)
	return c if c is Callable and (c as Callable).is_valid() else Callable()


func _has_mic_permission() -> bool:
	for p in OS.get_granted_permissions():
		if str(p).ends_with("RECORD_AUDIO"):
			return true
	return false


## Asks for RECORD_AUDIO the first time (Android only; hooks / the desktop test source skip the OS).
func _ensure_permission() -> bool:
	var h: Callable = _hook("granted")
	if h.is_valid():
		if bool(h.call()):
			return true
	elif mode() == "phone":
		return true   # desktop test source: nothing to ask
	elif Platform.is_android() and _has_mic_permission():
		return true
	Toast.info("마이크 권한이 필요해요. 다음 창에서 '허용'을 눌러 주세요.")
	var rq: Callable = _hook("request")
	if rq.is_valid():
		return bool(await rq.call())
	if not Platform.is_android():
		return false
	_perm_result = -1
	var cb := Callable(self, "_on_permission_result")
	get_tree().on_request_permissions_result.connect(cb)
	OS.request_permission("RECORD_AUDIO")
	var waited := 0.0
	while _perm_result < 0 and waited < PERMISSION_WAIT_SEC:
		await get_tree().process_frame
		waited += get_process_delta_time()
	get_tree().on_request_permissions_result.disconnect(cb)
	return _perm_result == 1


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission.ends_with("RECORD_AUDIO"):
		_perm_result = 1 if granted else 0


## Builds bus "Record": AudioEffectRecord -> AudioEffectCapture (level) -> Amplify -80 dB (no feedback to the speaker).
func ensure_record_bus() -> int:
	var idx: int = AudioServer.get_bus_index(RECORD_BUS)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, RECORD_BUS)
		AudioServer.set_bus_send(idx, "Master")
		var rec := AudioEffectRecord.new()
		rec.format = AudioStreamWAV.FORMAT_16_BITS
		AudioServer.add_bus_effect(idx, rec)
		AudioServer.add_bus_effect(idx, AudioEffectCapture.new())
		var amp := AudioEffectAmplify.new()
		amp.volume_db = -80.0
		AudioServer.add_bus_effect(idx, amp)
	_record_fx = null
	_capture_fx = null
	for i in AudioServer.get_bus_effect_count(idx):
		var fx: AudioEffect = AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectRecord and _record_fx == null:
			_record_fx = fx
		elif fx is AudioEffectCapture and _capture_fx == null:
			_capture_fx = fx
	return idx


func _mic_open() -> bool:
	var h: Callable = _hook("open")
	if h.is_valid():
		return bool(h.call())
	if mode() == "phone":
		return test_audio_source.is_valid()
	if not Platform.is_android():
		return false   # the desktop microphone is never opened by Godot
	ensure_record_bus()
	if _record_fx == null:
		return false
	_mic_close()
	_mic_player = AudioStreamPlayer.new()   # a fresh player after the permission was granted
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = RECORD_BUS
	add_child(_mic_player)
	_mic_player.play()
	_record_fx.set_recording_active(true)
	return true


## Stops capturing and returns what was recorded (null when nothing).
func _mic_stop() -> AudioStreamWAV:
	var h: Callable = _hook("recording")
	if h.is_valid():
		return h.call()
	if mode() == "phone":
		return test_audio_source.call() if test_audio_source.is_valid() else null
	if _record_fx == null:
		return null
	_record_fx.set_recording_active(false)
	return _record_fx.get_recording()


func _mic_close() -> void:
	_mic_live = false
	var h: Callable = _hook("close")
	if h.is_valid():
		h.call()
	if _mic_player != null:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	if _record_fx != null and _record_fx.is_recording_active():
		_record_fx.set_recording_active(false)


func _read_level() -> float:
	var h: Callable = _hook("level")
	if h.is_valid():
		return clampf(float(h.call()), 0.0, 1.0)
	if _capture_fx == null:
		return 0.0
	var n: int = _capture_fx.get_frames_available()
	if n <= 0:
		return level
	var buf: PackedVector2Array = _capture_fx.get_buffer(n)
	var sum := 0.0
	for v in buf:
		var m: float = (v.x + v.y) * 0.5
		sum += m * m
	var rms: float = sqrt(sum / float(buf.size()))
	return clampf(rms * 4.0, 0.0, 1.0)
