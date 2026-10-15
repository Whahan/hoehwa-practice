extends Node
## Text-to-speech playback through the backend (/tts -> WAV), with an in-memory clip cache.

signal state_changed ## emitted when `busy` or `playing` changes

const SLOW_SPEED := 0.75
const MAX_CACHE := 200

var busy: bool = false ## waiting for the backend
var playing: bool = false
var current_key: String = ""

var _player: AudioStreamPlayer
var _cache: Dictionary = {} # key -> AudioStreamWAV
var _cache_order: Array[String] = []
var _req_id: int = 0


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	add_child(_player)
	_player.finished.connect(_on_finished)


static func cache_key(text: String, lang: String, speed: float) -> String:
	return "%s|%.2f|%s" % [lang, speed, text]


func normal_speed() -> float:
	return clampf(float(Store.prefs.get("tts_speed", 1.0)), 0.6, 1.3)


func is_cached(text: String, lang: String, slow: bool = false) -> bool:
	var speed: float = SLOW_SPEED if slow else normal_speed()
	return _cache.has(cache_key(text.strip_edges(), lang, speed))


func stop() -> void:
	_req_id += 1
	if _player != null and _player.playing:
		_player.stop()
	_set_state(false, false)


## Speaks `text`. Fire and forget (it is a coroutine; callers may `await` it to know when
## playback has *started*).
func speak(text: String, lang: String, slow: bool = false) -> void:
	var t: String = text.strip_edges()
	if t == "":
		return
	var speed: float = SLOW_SPEED if slow else normal_speed()
	var key: String = cache_key(t, lang, speed)
	_req_id += 1
	var my_id: int = _req_id
	if _player.playing:
		_player.stop()
	var stream: AudioStreamWAV = _cache.get(key, null)
	if stream == null:
		_set_state(true, false)
		var req_call = Api.post_json("/tts", {"text": t, "lang": lang, "speed": speed}, Api.TIMEOUT_SHORT, true)
		var res: Dictionary = await req_call.wait()
		if not res["ok"]:
			if my_id == _req_id:
				_set_state(false, false)
			return
		var bytes: PackedByteArray = res["bytes"]
		stream = WavUtil.from_wav_bytes(bytes)
		if stream == null:
			Toast.error("받은 음성을 재생하지 못했어요.")
			if my_id == _req_id:
				_set_state(false, false)
			return
		_put_cache(key, stream)
	if my_id != _req_id:
		return
	current_key = key
	_player.stream = stream
	_player.play()
	_set_state(false, true)


func _put_cache(key: String, stream: AudioStreamWAV) -> void:
	if not _cache.has(key):
		_cache_order.append(key)
		if _cache_order.size() > MAX_CACHE:
			var old: String = _cache_order.pop_front()
			_cache.erase(old)
	_cache[key] = stream


func _on_finished() -> void:
	_set_state(false, false)


func _set_state(b: bool, p: bool) -> void:
	if busy == b and playing == p:
		return
	busy = b
	playing = p
	state_changed.emit()
