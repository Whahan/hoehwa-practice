extends Node
## Text-to-speech playback through the backend (/tts -> WAV), with an in-memory clip cache.
##
## A text is cut into chunks (sentences; the first long sentence is cut at its first comma so sound starts sooner).
## Chunk 1 plays as soon as it arrives, chunks 2..n are fetched one after another meanwhile and queued with a
## ~150 ms gap. The splitter below mirrors `tts_chunks()` in backend/server.py (the server pre-synthesizes exactly
## those chunks while a /chat reply travels to the app, so the /tts requests are cache hits).

signal state_changed ## emitted when `busy` or `playing` changes
signal chunk_started(index: int, text: String) ## a chunk of the current speech began playing
signal sequence_finished ## the whole speech played to the end
signal voices_loaded

const SLOW_SPEED := 0.75
const MAX_CACHE := 200
const GAP_SEC := 0.15
const DEFAULT_VOICE := {"en": "af_heart", "ja": "jf_alpha"}

const EN_ABBR := ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "u.s", "no", "mt", "inc", "ltd", "approx"]
const CLOSERS := "\"'”’)]」』）】"
const EN_TERM := ".!?"
const JA_TERM := "。！？!?"
const PUNCT := "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~…—–“”‘’「」『』（）【】。、！？・〜～:;"

var busy: bool = false ## waiting for the backend
var playing: bool = false
var current_key: String = ""
var voices: Dictionary = {} ## lang -> [{id, name, gender, default}] from GET /tts/voices (empty until loaded)
var gap_sec: float = GAP_SEC
## Tests: Callable(text, lang, speed, voice) -> AudioStreamWAV (may be a coroutine) used instead of the backend.
var fetch_hook: Callable = Callable()
## Timing of the first chunk of the last speech (ms): {request_ms, decode_ms, play_ms (since speak() was called)}
var last_timing: Dictionary = {}

var _player: AudioStreamPlayer
var _cache: Dictionary = {} # key -> AudioStreamWAV
var _cache_order: Array[String] = []
var _job: Job = null


class Job:
	extends RefCounted
	signal first_started
	var chunks: Array[String] = []
	var lang: String = "en"
	var speed: float = 1.0
	var voice: String = ""
	var clips: Array = [] ## AudioStreamWAV, or null when that chunk failed
	var next: int = 0
	var cancelled: bool = false
	var done: bool = false
	var started: bool = false
	var gap_pending: bool = false
	var req = null
	var t_call_us: int = 0
	var timing: Dictionary = {}

	func finish() -> void:
		done = true
		first_started.emit()


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	add_child(_player)
	_player.finished.connect(_on_finished)


static func cache_key(text: String, lang: String, speed: float, voice: String = "") -> String:
	return "%s|%.2f|%s|%s" % [lang, speed, voice, text]


func normal_speed() -> float:
	return clampf(float(Store.prefs.get("tts_speed", 1.0)), 0.6, 1.3)


func voice_for(lang: String) -> String:
	var v: String = str(Store.prefs.get("tts_voice_" + lang, "")).strip_edges()
	return v if v != "" else str(DEFAULT_VOICE.get(lang, ""))


## True when every chunk of `text` is already in memory.
func is_cached(text: String, lang: String, slow: bool = false) -> bool:
	var speed: float = SLOW_SPEED if slow else normal_speed()
	var voice: String = voice_for(lang)
	var chunks: Array[String] = split_chunks(text.strip_edges(), lang)
	if chunks.is_empty():
		return false
	for c in chunks:
		if not _cache.has(cache_key(c, lang, speed, voice)):
			return false
	return true


func stop() -> void:
	var job: Job = _job
	_job = null
	if job != null:
		job.cancelled = true
		if job.req != null:
			job.req.cancel()
		job.finish()
	if _player != null and _player.playing:
		_player.stop()
	_set_state(false, false)


## Speaks `text` (fire and forget; a coroutine callers may `await` to know when playback has *started*).
## `voice` overrides the saved voice (settings preview).
func speak(text: String, lang: String, slow: bool = false, voice: String = "") -> void:
	var t: String = text.strip_edges()
	if t == "":
		return
	await speak_chunks(split_chunks(t, lang), lang, slow, voice)


## Same, with the chunks already decided (the /chat reply carries `tts_chunks` that the server pre-synthesized).
func speak_chunks(chunks: Array, lang: String, slow: bool = false, voice: String = "") -> void:
	var clean: Array[String] = []
	for c in chunks:
		var s: String = str(c).strip_edges()
		if s != "":
			clean.append(s)
	if clean.is_empty():
		return
	stop()
	var job := Job.new()
	job.chunks = clean
	job.lang = lang
	job.speed = SLOW_SPEED if slow else normal_speed()
	job.voice = voice if voice != "" else voice_for(lang)
	job.t_call_us = Time.get_ticks_usec()
	_job = job
	_set_state(true, false)
	_fetch_chain(job)
	if not job.started and not job.done:
		await job.first_started


func _fetch_chain(job: Job) -> void:
	for i in job.chunks.size():
		if job.cancelled:
			return
		var text: String = job.chunks[i]
		var key: String = cache_key(text, job.lang, job.speed, job.voice)
		var stream: AudioStreamWAV = _cache.get(key, null)
		var t_req: int = Time.get_ticks_usec()
		var t_got: int = t_req
		if stream == null:
			if fetch_hook.is_valid():
				stream = await fetch_hook.call(text, job.lang, job.speed, job.voice)
				t_got = Time.get_ticks_usec()
			else:
				var body := {"text": text, "lang": job.lang, "speed": job.speed, "voice": job.voice}
				var req_call = Api.post_json("/tts", body, Api.TIMEOUT_SHORT, i == 0)
				job.req = req_call
				var res: Dictionary = await req_call.wait()
				job.req = null
				if job.cancelled:
					return
				t_got = Time.get_ticks_usec()
				if res["ok"]:
					stream = WavUtil.from_wav_bytes(res["bytes"])
					if stream == null:
						Toast.error("받은 음성을 재생하지 못했어요.")
			if job.cancelled:
				return
			if stream != null:
				_put_cache(key, stream)
		if i == 0:
			job.timing = {"request_ms": (t_got - t_req) / 1000.0, "decode_ms": (Time.get_ticks_usec() - t_got) / 1000.0}
		job.clips.append(stream)
		_advance(job)
		if stream == null:
			return


## Starts the next clip when nothing is playing and no gap is pending.
func _advance(job: Job) -> void:
	if job != _job or job.cancelled or job.done:
		return
	if _player.playing or job.gap_pending:
		return
	if job.next >= job.chunks.size():
		_finish(job)
		return
	if job.next >= job.clips.size():
		_set_state(true, false) # the next chunk is still being fetched
		return
	var stream: AudioStreamWAV = job.clips[job.next]
	if stream == null:
		_finish(job)
		return
	var idx: int = job.next
	job.next += 1
	current_key = cache_key(job.chunks[idx], job.lang, job.speed, job.voice)
	_player.stream = stream
	_player.play()
	_set_state(false, true)
	if idx == 0:
		job.timing["play_ms"] = (Time.get_ticks_usec() - job.t_call_us) / 1000.0
		last_timing = job.timing
	chunk_started.emit(idx, job.chunks[idx])
	if not job.started:
		job.started = true
		job.first_started.emit()


func _finish(job: Job) -> void:
	if job != _job:
		return
	_job = null
	job.finish()
	_set_state(false, false)
	sequence_finished.emit()


## The phone leaves the foreground: stop the speech.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		stop()


func _on_finished() -> void:
	var job: Job = _job
	if job == null or job.cancelled:
		_set_state(false, false)
		return
	if job.next >= job.chunks.size():
		_finish(job)
		return
	job.gap_pending = true
	get_tree().create_timer(gap_sec).timeout.connect(func() -> void:
		job.gap_pending = false
		_advance(job))


func _put_cache(key: String, stream: AudioStreamWAV) -> void:
	if not _cache.has(key):
		_cache_order.append(key)
		if _cache_order.size() > MAX_CACHE:
			var old: String = _cache_order.pop_front()
			_cache.erase(old)
	_cache[key] = stream


func _set_state(b: bool, p: bool) -> void:
	if busy == b and playing == p:
		return
	busy = b
	playing = p
	state_changed.emit()


# ---------------------------------------------------------------- voices

## Loads GET /tts/voices once (only the voice packs present on the PC).
func load_voices() -> void:
	if not voices.is_empty():
		return
	var req_call = Api.get_json("/tts/voices", Api.TIMEOUT_SHORT, false)
	var res: Dictionary = await req_call.wait()
	if res["ok"] and res["data"] is Dictionary and (res["data"] as Dictionary).get("voices", null) is Dictionary:
		voices = (res["data"] as Dictionary)["voices"]
		voices_loaded.emit()


## [{id, name, gender, default}] for a language; before the list has loaded, only the built-in default.
func voices_for(lang: String) -> Array:
	var lst: Variant = voices.get(lang, null)
	if lst is Array and not (lst as Array).is_empty():
		return lst
	var d: String = str(DEFAULT_VOICE.get(lang, ""))
	return [{"id": d, "name": d.get_slice("_", 1).capitalize(), "gender": "female" if d.substr(1, 1) == "f" else "male", "default": true}]


static func voice_label(v: Dictionary) -> String:
	var g: String = "여성" if str(v.get("gender", "")) == "female" else "남성"
	var s: String = "%s · %s" % [str(v.get("name", v.get("id", ""))), g]
	if bool(v.get("default", false)):
		s += " (기본)"
	return s


# ---------------------------------------------------------------- chunking (mirror of backend tts_chunks)

static func _is_space(c: int) -> bool:
	return c <= 32 or c == 0xA0 or c == 0x3000 or (c >= 0x2000 and c <= 0x200A) or c == 0x2028 or c == 0x2029


static func _squash(s: String) -> String:
	var out := ""
	var prev_space := true
	for i in s.length():
		if _is_space(s.unicode_at(i)):
			if not prev_space:
				out += " "
			prev_space = true
		else:
			out += s[i]
			prev_space = false
	return out.strip_edges()


static func _has_letters(s: String) -> bool:
	for i in s.length():
		if not _is_space(s.unicode_at(i)) and PUNCT.find(s[i]) < 0:
			return true
	return false


static func split_sentences(text: String, lang: String) -> Array[String]:
	var out: Array[String] = []
	var term: String = EN_TERM if lang == "en" else JA_TERM
	for raw_line in text.replace("\r", "\n").split("\n"):
		var line: String = _squash(raw_line) if lang == "en" else raw_line.strip_edges()
		if line == "":
			continue
		var cur := ""
		var i := 0
		var n := line.length()
		while i < n:
			var ch: String = line[i]
			cur += ch
			i += 1
			if term.find(ch) < 0:
				continue
			var j := i
			while j < n and (term.find(line[j]) >= 0 or CLOSERS.find(line[j]) >= 0):
				cur += line[j]
				j += 1
			if lang == "en":
				if j < n and line[j] != " ":
					i = j
					continue
				if ch == "." and j == i:
					var parts: PackedStringArray = cur.strip_edges().rsplit(" ", true, 1)
					var tok: String = parts[parts.size() - 1].lstrip("\"'“‘([")
					var base: String = tok.rstrip(".").to_lower()
					var is_initial: bool = base.length() == 1 and base.to_upper() != base.to_lower() and tok.substr(0, 1) == tok.substr(0, 1).to_upper() and tok.substr(0, 1) != tok.substr(0, 1).to_lower() and base != "i" and base != "a"
					if EN_ABBR.has(base) or is_initial:
						i = j
						continue
			if lang == "ja" and j < n and line[j] == "と":
				i = j
				continue
			i = j
			out.append(cur.strip_edges())
			cur = ""
			while i < n and line[i] == " ":
				i += 1
		if cur.strip_edges() != "":
			out.append(cur.strip_edges())
	var merged: Array[String] = []
	var joiner: String = " " if lang == "en" else ""
	for s in out:
		if not merged.is_empty() and not _has_letters(s):
			merged[merged.size() - 1] += joiner + s
		else:
			merged.append(s)
	if merged.size() > 1 and not _has_letters(merged[0]):
		merged[1] = merged[0] + joiner + merged[1]
		merged.remove_at(0)
	return merged


static func first_clause_split(s: String, lang: String) -> Array[String]:
	var res: Array[String] = [s]
	if lang == "en":
		var words: PackedStringArray = s.split(" ")
		if s.length() >= 30 and words.size() >= 6:
			for k in range(2, mini(10, words.size() - 2) + 1):
				var w: String = words[k - 1]
				if w != "" and ",;:".find(w.substr(w.length() - 1)) >= 0:
					var head: String = " ".join(words.slice(0, k))
					var tail: String = " ".join(words.slice(k))
					if head.length() >= 8 and tail.length() <= 3.5 * head.length() + 8:
						return [head, tail]
	else:
		if s.length() >= 12:
			for p in s.length():
				if s[p] == "、" and p + 1 >= 5 and p + 1 <= 14 and s.length() - (p + 1) >= 4 and s.length() - (p + 1) <= 3.5 * (p + 1) + 3:
					return [s.substr(0, p + 1), s.substr(p + 1)]
	return res


static func split_chunks(text: String, lang: String) -> Array[String]:
	var sents: Array[String] = split_sentences(text, lang)
	var out: Array[String] = []
	if sents.is_empty():
		return out
	out.append_array(first_clause_split(sents[0], lang))
	out.append_array(sents.slice(1))
	return out
