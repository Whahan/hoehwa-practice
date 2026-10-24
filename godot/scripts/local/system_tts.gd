class_name SystemTts
extends RefCounted
## Phone speech through the system text-to-speech engine (`DisplayServer.tts_*`), used by the `Tts` autoload when
## `Tts.engine_now() == "system"` (docs/phone_standalone_design.md §3.2). Facts it is built around:
##  - Android ignores `interrupt` and queues utterances -> `stop()` before every new speech.
##  - The engine initialises asynchronously and a `speak` before that is silently dropped -> `wake()` at start, and
##    a first utterance that ends with CANCEL, or shows no sign of life for `start_timeout_sec`, is retried ONCE.
##  - There is no audio data to get, so no cache and no pitch comparison (`Tts.last_timing` stays empty).
##  - A language without an installed voice is NOT read with another language's voice (F11): a Toast tells the user
##    how to install it, the speech is skipped and `finished` is still emitted once.
## All DisplayServer calls go through `adapter` (tests replace it: `SystemTts.adapter = FakeAdapter.new()`).

signal chunk_started(index: int, text: String)
signal state_changed(busy: bool, playing: bool) ## busy = waiting for the engine, playing = a chunk is being spoken
signal finished ## a speech ended on its own (played out, failed or skipped); NOT emitted by stop()

const START_TIMEOUT_SEC := 1.5 ## no START/CANCEL within this long after the first speak() = engine not ready yet
const LATER_TIMEOUT_SEC := 5.0 ## same for chunks 2..n (they never retry)
const VOICE_WAIT_SEC := 1.5 ## an empty voice list may only mean "engine still starting": poll this long
const VOLUME := 100
const LANG_PREFIX := {"en": ["en"], "ja": ["ja", "jpn"]}
const LANG_NAME := {"en": "영어", "ja": "일본어"}
const FAIL_TEXT := "휴대폰 음성이 재생되지 않았어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환을 확인해 주세요."


## The thin layer over DisplayServer (what a test fakes). Without TTS support (headless, desktop without a
## speech service) every call is a harmless no-op.
class Adapter:
	extends RefCounted

	func available() -> bool:
		return DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH)

	## [{name, id, language}]
	func get_voices() -> Array:
		return DisplayServer.tts_get_voices() if available() else []

	func speak(text: String, voice: String, volume: int, pitch: float, rate: float, utterance_id: int, interrupt: bool) -> void:
		if available():
			DisplayServer.tts_speak(text, voice, volume, pitch, rate, utterance_id, interrupt)

	func stop() -> void:
		if available():
			DisplayServer.tts_stop()

	func is_speaking() -> bool:
		return DisplayServer.tts_is_speaking() if available() else false

	## kind = DisplayServer.TTS_UTTERANCE_STARTED/ENDED/CANCELED (callback(utterance_id)) or _BOUNDARY (callback(pos, utterance_id))
	func set_callback(kind: int, cb: Callable) -> void:
		if available():
			DisplayServer.tts_set_utterance_callback(kind, cb)


class Job:
	extends RefCounted
	signal first_started
	var chunks: Array[String] = []
	var lang: String = "en"
	var rate: float = 1.0
	var voice: String = ""
	var idx: int = 0 ## chunk being spoken
	var utt: int = -1 ## id of the utterance we currently wait for
	var utt_started: bool = false
	var started: bool = false ## the first chunk has started (callers awaiting speak_chunks wake up)
	var retried: bool = false
	var cancelled: bool = false
	var done: bool = false

	func finish() -> void:
		done = true
		first_started.emit()


## Tests assign a fake here before the first use.
static var adapter: Adapter = null

var host: Node = null ## gives access to the SceneTree timers (the Tts autoload)
var start_timeout_sec: float = START_TIMEOUT_SEC
var later_timeout_sec: float = LATER_TIMEOUT_SEC
var voice_wait_sec: float = VOICE_WAIT_SEC

var _job: Job = null
var _next_id: int = 1
var _bound: Adapter = null


func _init(p_host: Node = null) -> void:
	host = p_host


static func current() -> Adapter:
	if adapter == null:
		adapter = Adapter.new()
	return adapter


static func no_voice_text(lang: String) -> String:
	if lang == "ja":
		return "이 휴대폰에 일본어 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 일본어 음성 데이터를 내려받아 주세요."
	if LANG_NAME.has(lang):
		return "이 휴대폰에 %s 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 %s 음성 데이터를 내려받아 주세요." % [LANG_NAME[lang], LANG_NAME[lang]]
	return Route.text_for("no_voice")


# ---------------------------------------------------------------- voices

## Wakes the engine (its initialisation is asynchronous; reading the voices starts it) and (re)binds the callbacks.
func wake() -> void:
	_bind()
	current().get_voices()


func all_voices() -> Array:
	var out: Array = []
	for v in current().get_voices():
		if v is Dictionary and str((v as Dictionary).get("id", "")) != "":
			out.append(v)
	return out


static func voice_matches(v: Dictionary, lang: String) -> bool:
	var l: String = str(v.get("language", "")).to_lower()
	for p in LANG_PREFIX.get(lang, [lang]):
		if l.begins_with(p):
			return true
	return false


func _matching(lang: String) -> Array:
	var out: Array = []
	for v in all_voices():
		if voice_matches(v, lang):
			out.append(v)
	return out


## The system voice id to use for `lang`: `prefer` (a preview) or the saved `tts_sys_voice_<lang>` when the phone really
## has it for that language, else the first voice of the language. "" = this phone has no voice for the language.
func voice_id_for(lang: String, prefer: String = "") -> String:
	var lst: Array = _matching(lang)
	if lst.is_empty():
		return ""
	var want: String = prefer.strip_edges()
	if want == "":
		want = str(Store.prefs.get("tts_sys_voice_" + lang, "")).strip_edges()
	if want != "":
		for v in lst:
			if str(v["id"]) == want:
				return want
	return str(lst[0]["id"])


## [{id, name, gender:"", default}] for the settings drop-down (same shape as the PC list).
func voices_for(lang: String) -> Array:
	var def: String = voice_id_for(lang)
	var out: Array = []
	for v in _matching(lang):
		var id: String = str(v["id"])
		out.append({"id": id, "name": str(v.get("name", id)), "gender": "", "default": id == def})
	return out


func voices_ok() -> Dictionary:
	return {"en": not _matching("en").is_empty(), "ja": not _matching("ja").is_empty()}


# ---------------------------------------------------------------- speaking

func active() -> bool:
	return _job != null and not _job.done


## Speaks the chunks one after another. Coroutine: returns once the first chunk started (or the speech ended /
## was skipped), like the PC path.
func speak_chunks(chunks: Array, lang: String, rate: float, prefer_voice: String = "") -> void:
	if chunks.is_empty():
		return
	_cancel_job()
	var job := Job.new()
	for c in chunks:
		job.chunks.append(str(c))
	job.lang = lang
	job.rate = rate
	_job = job
	_bind()
	_emit_state(true, false)
	var voice: String = voice_id_for(lang, prefer_voice)
	if voice == "" and all_voices().is_empty():
		await _wait_voices(job) # nothing at all: the engine may still be starting
		if job.cancelled or job.done:
			return
		voice = voice_id_for(lang, prefer_voice)
	if voice == "":
		Toast.error(no_voice_text(lang))
		_end(job)
		return
	job.voice = voice
	current().stop() # Android queues utterances instead of interrupting
	_speak_current(job)
	if not job.started and not job.done:
		await job.first_started


func stop() -> void:
	if not active():
		return
	_cancel_job()
	current().stop()
	_emit_state(false, false)


func _cancel_job() -> void:
	if _job != null:
		_job.cancelled = true
		_job.finish()
		_job = null


func _wait_voices(job: Job) -> void:
	var waited := 0.0
	while waited < voice_wait_sec and not job.cancelled and all_voices().is_empty():
		if host == null or not host.is_inside_tree():
			return
		await host.get_tree().create_timer(0.1).timeout
		waited += 0.1


func _speak_current(job: Job) -> void:
	var id: int = _next_id
	_next_id += 1
	job.utt = id
	job.utt_started = false # set before the call: a fake/real engine may fire START synchronously
	current().speak(job.chunks[job.idx], job.voice, VOLUME, 1.0, job.rate, id, true)
	if job.idx == 0:
		_arm_watchdog(job, id, start_timeout_sec)
	else:
		_arm_watchdog(job, id, later_timeout_sec)


func _arm_watchdog(job: Job, id: int, sec: float) -> void:
	if host == null or not host.is_inside_tree():
		return
	host.get_tree().create_timer(sec).timeout.connect(_on_watchdog.bind(job, id))


func _alive(job: Job, id: int) -> bool:
	return job == _job and not job.cancelled and not job.done and job.utt == id


func _on_watchdog(job: Job, id: int) -> void:
	if not _alive(job, id) or job.utt_started:
		return
	current().stop() # drop a possibly queued, not yet started copy
	_failed_utterance(job)


## The current utterance died without being heard (CANCEL or silence): the first one gets exactly one more try.
func _failed_utterance(job: Job) -> void:
	if job.idx == 0 and not job.retried and not job.started:
		job.retried = true
		current().get_voices() # nudge the engine
		_speak_current(job)
		return
	if job.idx == 0 and not job.started:
		Toast.error(FAIL_TEXT)
	_end(job)


func _on_started(id: int) -> void:
	var job: Job = _job
	if job == null or not _alive(job, id) or job.utt_started:
		return
	job.utt_started = true
	if not job.started:
		job.started = true
		_emit_state(false, true)
	chunk_started.emit(job.idx, job.chunks[job.idx])
	job.first_started.emit()


func _on_ended(id: int) -> void:
	var job: Job = _job
	if job == null or not _alive(job, id):
		return
	if not job.utt_started:
		_on_started(id) # an engine that reports only END
		if not _alive(job, id):
			return
	job.idx += 1
	if job.idx >= job.chunks.size():
		_end(job)
	else:
		_speak_current(job)


func _on_canceled(id: int) -> void:
	var job: Job = _job
	if job == null or not _alive(job, id):
		return
	if job.utt_started:
		_end(job) # interrupted while speaking (another app took the audio): stop, no retry
	else:
		_failed_utterance(job)


func _on_boundary(_pos: int, _id: int) -> void:
	pass # word highlight is a follow-up


func _end(job: Job) -> void:
	if job != _job:
		return
	_job = null
	job.finish()
	_emit_state(false, false)
	finished.emit()


func _emit_state(b: bool, p: bool) -> void:
	state_changed.emit(b, p)


func _bind() -> void:
	var a: Adapter = current()
	if _bound == a:
		return
	_bound = a
	a.set_callback(DisplayServer.TTS_UTTERANCE_STARTED, _on_started)
	a.set_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_ended)
	a.set_callback(DisplayServer.TTS_UTTERANCE_CANCELED, _on_canceled)
	a.set_callback(DisplayServer.TTS_UTTERANCE_BOUNDARY, _on_boundary)
