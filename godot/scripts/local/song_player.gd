class_name SongPlayer
extends Node
## Song playback for the song-study feature (docs/song_study_design.md §5.4, §5.5):
## MP3 load, a runtime-made "Song" audio bus (pitch-shift effect), speed with pitch compensation, line loops.
##
## Time model: every public time is *lyric time* (the `t0`/`t1` of the song lines). The audio file position is
## lyric time + song.offset ("offset" is added to all times when playing).
## Everything that touches sound goes through `backend` (a `SongPlayer.Adapter`); the default is the real
## `AudioAdapter` (AudioStreamPlayer on the "Song" bus). Tests swap in a fake backend with its own clock.
## Only the "Song" bus is created/changed here (never "Master", never the Tts/Recorder buses); it is removed again
## when the last real backend is released (player freed or `unload()`).

signal position_changed(t: float)
signal line_changed(i: int)
signal finished_loop(count: int) ## a play_line() with a finite repeat count played all its passes
signal song_ended ## the song played to its end (not emitted for line loops)

const SPEED_MIN := 0.5
const SPEED_MAX := 1.25
const SPEED_PRESETS := [0.5, 0.65, 0.75, 0.9, 1.0]
const PRE_ROLL := 0.15 ## a line section starts this long before t0 ...
const POST_ROLL := 0.25 ## ... and ends this long after t1
const MIN_SECTION := 0.2
const BUS_NAME := "Song"
const MSG_NO_AUDIO := "오디오 파일이 없어요 — 삭제 후 다시 추가해 주세요"
const MSG_BAD_AUDIO := "오디오 파일을 읽을 수 없어요 — 삭제 후 다시 추가해 주세요"
const MSG_BAD_SONG := "곡 정보가 올바르지 않아요"

enum State { STOPPED, PLAYING, PAUSED }

## Root of the song folders; the audio is `<songs_root>/<id>/<audio.file>` unless the song carries `_audio_path`.
## (The orchestrator may point this at SongStore.root; this file does not depend on SongStore.)
static var songs_root: String = "user://songs"

## Adapter. null = a real AudioAdapter is created on the first load_song(). A test sets a fake before load_song().
var backend: Adapter = null
var last_error: String = ""
var duration: float = 0.0 ## real length of the loaded audio (s)
var offset: float = 0.0 ## song.offset (s)
var loops_done: int = 0 ## passes finished by the current play_line()
var speed: float = 1.0
var keep_pitch: bool = true

var _state: int = State.STOPPED
var _lines: Array = [] ## [{t0, t1}] from the song
var _loaded: bool = false
var _apos: float = 0.0 ## audio position while not PLAYING
var _line_mode: bool = false
var _sec_start: float = 0.0 ## audio time
var _sec_end: float = 0.0
var _repeat: int = 1
var _cur_line: int = -1
var _owns_backend: bool = false


## What the player needs from the sound side. Times are audio-file seconds.
class Adapter:
	extends RefCounted
	var err: String = ""
	## Called once with the owning player node (the real backend adds its AudioStreamPlayer there).
	func setup(_owner: Node) -> void:
		pass
	## Loads the file. Returns its length in seconds, <= 0 on failure (and sets `err`).
	func load_audio(_path: String) -> float:
		return 0.0
	func start(_from: float) -> void:
		pass
	func set_paused(_paused: bool) -> void:
		pass
	func halt() -> void:
		pass
	## true while the stream is running (also while paused); false once it ended or was halted
	func is_playing() -> bool:
		return false
	func pos() -> float:
		return 0.0
	## player `pitch_scale` = speed; the bus effect gets `fx_pitch`; `fx_enabled == false` bypasses the effect
	func set_speed_pitch(_speed: float, _fx_pitch: float, _fx_enabled: bool) -> void:
		pass
	func release() -> void:
		pass


## The real thing: AudioStreamPlayer -> "Song" bus (AudioEffectPitchShift) -> Master.
class AudioAdapter:
	extends Adapter
	static var _bus_users: int = 0
	var player: AudioStreamPlayer = null
	var fx: AudioEffectPitchShift = null
	var _bus_held: bool = false
	var _play_frame: int = -1
	var _from: float = 0.0
	var _paused: bool = false
	var _pending: Array = [1.0, 1.0, false] ## speed, fx pitch, fx enabled (applied when the bus exists)

	func setup(owner: Node) -> void:
		if player != null:
			return
		player = AudioStreamPlayer.new()
		player.name = "SongAudio"
		owner.add_child(player)

	func load_audio(path: String) -> float:
		err = ""
		if player == null:
			err = SongPlayer.MSG_BAD_AUDIO
			return 0.0
		if not FileAccess.file_exists(path):
			err = SongPlayer.MSG_NO_AUDIO
			return 0.0
		var size := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
		if size <= 0:
			err = SongPlayer.MSG_BAD_AUDIO
			return 0.0
		var stream: AudioStreamMP3 = AudioStreamMP3.load_from_file(path)
		if stream == null or stream.get_length() <= 0.0:
			err = SongPlayer.MSG_BAD_AUDIO
			return 0.0
		_acquire_bus()
		player.stop()
		player.stream = stream
		player.bus = SongPlayer.BUS_NAME
		_apply_pending()
		return stream.get_length()

	func _acquire_bus() -> void:
		if _bus_held:
			return
		_bus_held = true
		_bus_users += 1
		var idx := AudioServer.get_bus_index(SongPlayer.BUS_NAME)
		if idx == -1:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, SongPlayer.BUS_NAME)
			AudioServer.set_bus_send(idx, "Master")
			var e := AudioEffectPitchShift.new()
			e.fft_size = AudioEffectPitchShift.FFT_SIZE_2048
			e.oversampling = 4
			AudioServer.add_bus_effect(idx, e)
		fx = null
		for i in AudioServer.get_bus_effect_count(idx):
			var cand: AudioEffect = AudioServer.get_bus_effect(idx, i)
			if cand is AudioEffectPitchShift:
				fx = cand
				break

	func _apply_pending() -> void:
		set_speed_pitch(_pending[0], _pending[1], _pending[2])

	func set_speed_pitch(speed: float, fx_pitch: float, fx_enabled: bool) -> void:
		_pending = [speed, fx_pitch, fx_enabled]
		if player != null:
			player.pitch_scale = speed
		if fx != null:
			fx.pitch_scale = fx_pitch
			var idx := AudioServer.get_bus_index(SongPlayer.BUS_NAME)
			if idx != -1:
				AudioServer.set_bus_effect_enabled(idx, 0, fx_enabled)

	func start(from: float) -> void:
		if player == null or player.stream == null:
			return
		_from = from
		_paused = false
		_play_frame = Engine.get_process_frames()
		player.stream_paused = false
		player.play(from)

	func set_paused(paused: bool) -> void:
		_paused = paused
		if player != null:
			player.stream_paused = paused

	func halt() -> void:
		_paused = false
		if player != null:
			player.stream_paused = false
			player.stop()

	func is_playing() -> bool:
		return player != null and player.playing

	func pos() -> float:
		if player == null or not player.playing:
			return _from
		if Engine.get_process_frames() == _play_frame:
			return _from ## the playback position may still be the one from before the seek
		var p := player.get_playback_position()
		if not _paused:
			p += AudioServer.get_time_since_last_mix() * player.pitch_scale
		if player.stream != null:
			p = minf(p, player.stream.get_length())
		return maxf(p, 0.0)

	func release() -> void:
		if player != null:
			player.stop()
			player.stream = null
			if is_instance_valid(player):
				if player.get_parent() != null:
					player.get_parent().remove_child(player)
				player.queue_free()
			player = null
		fx = null
		if _bus_held:
			_bus_held = false
			_bus_users = maxi(_bus_users - 1, 0)
			if _bus_users == 0:
				var idx := AudioServer.get_bus_index(SongPlayer.BUS_NAME)
				if idx != -1:
					AudioServer.remove_bus(idx)


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	unload()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		pause()
	elif what == NOTIFICATION_PREDELETE:
		if backend != null and _owns_backend:
			backend.release()
			backend = null


func _process(_delta: float) -> void:
	update()


## Loads the song's audio. Returns false (with `last_error`) for a missing/empty/broken file or a bad song.
func load_song(song: Dictionary) -> bool:
	stop()
	_loaded = false
	_lines = []
	last_error = ""
	if not _valid_song(song):
		last_error = MSG_BAD_SONG
		return false
	var declared: float = float(song.get("duration", -1.0)) if song.has("duration") else -1.0
	if song.has("duration") and declared <= 0.0:
		last_error = MSG_BAD_AUDIO
		return false
	var path := _audio_path(song)
	if path == "":
		last_error = MSG_NO_AUDIO
		return false
	if backend == null:
		backend = AudioAdapter.new()
		_owns_backend = true
		backend.setup(self)
	var d := backend.load_audio(path)
	if d <= 0.0:
		last_error = backend.err if backend.err != "" else MSG_BAD_AUDIO
		return false
	duration = d
	offset = clampf(float(song.get("offset", 0.0)), -5.0, 5.0)
	for ln in song["lines"]:
		if ln is Dictionary:
			_lines.append({"t0": float(ln.get("t0", 0.0)), "t1": float(ln.get("t1", 0.0))})
	_loaded = true
	_apply_speed()
	_apos = 0.0
	return true


## Stops and releases the audio (and the "Song" bus when no other player uses it).
func unload() -> void:
	stop()
	_loaded = false
	if backend != null and _owns_backend:
		backend.release()
		backend = null
		_owns_backend = false
	elif backend != null:
		backend.release()


func is_loaded() -> bool:
	return _loaded


func is_playing() -> bool:
	return _state == State.PLAYING


func is_paused() -> bool:
	return _state == State.PAUSED


func state() -> int:
	return _state


## Current line index (-1 before the first line / when stopped at the start).
func current_line() -> int:
	return _cur_line


func line_count() -> int:
	return _lines.size()


## Audio-time section [start, end] of line i (clamped to the song), or [] for a bad index.
func line_section(i: int) -> Array:
	if i < 0 or i >= _lines.size():
		return []
	var t0: float = _lines[i]["t0"]
	var t1: float = _lines[i]["t1"]
	var s := maxf(t0 + offset - PRE_ROLL, 0.0)
	var e := minf(t1 + offset + POST_ROLL, duration)
	if e < s + MIN_SECTION:
		e = minf(s + MIN_SECTION, duration)
	return [s, e]


func play_from(t: float) -> void:
	if not _loaded:
		return
	_line_mode = false
	_repeat = 1
	loops_done = 0
	_seek_play(clampf(t + offset, 0.0, duration))
	_update_line_from_pos(true)
	set_process(true)


## Plays line i (section = [t0 - 0.15, t1 + 0.25]) `repeat` times; repeat == 0 loops until stop(). Bad index: ignored.
func play_line(i: int, repeat: int = 1) -> void:
	if not _loaded or i < 0 or i >= _lines.size():
		return
	var sec := line_section(i)
	if sec.is_empty() or sec[1] <= sec[0]:
		return
	_line_mode = true
	_sec_start = sec[0]
	_sec_end = sec[1]
	_repeat = repeat if repeat >= 0 else 1
	loops_done = 0
	_seek_play(_sec_start)
	_set_line(i)
	set_process(true)


func pause() -> void:
	if _state != State.PLAYING or backend == null:
		return
	_apos = backend.pos()
	backend.set_paused(true)
	_state = State.PAUSED
	position_changed.emit(position())


## Continues after pause() (from where it stopped).
func resume() -> void:
	if _state != State.PAUSED or backend == null:
		return
	backend.set_paused(false)
	_state = State.PLAYING
	set_process(true)


func stop() -> void:
	if backend != null and _state != State.STOPPED:
		backend.halt()
	_state = State.STOPPED
	_line_mode = false
	_apos = 0.0
	_cur_line = -1
	set_process(false)


## 0.5 .. 1.25; the player's pitch_scale = s, the bus effect compensates by 1/s (keep_pitch).
func set_speed(s: float) -> void:
	speed = clampf(s, SPEED_MIN, SPEED_MAX)
	_apply_speed()


func set_keep_pitch(b: bool) -> void:
	keep_pitch = b
	_apply_speed()


## Lyric time (offset applied), clamped to [0, duration].
func position() -> float:
	var a := _apos
	if _state == State.PLAYING and backend != null:
		a = backend.pos()
	return clampf(a - offset, 0.0, maxf(duration, 0.0))


## One step of the loop / line tracking. _process calls it each frame; a test with a fake clock calls it itself.
func update() -> void:
	if _state != State.PLAYING or backend == null:
		return
	var a := backend.pos()
	var alive := backend.is_playing()
	if _line_mode:
		if a >= _sec_end or not alive:
			_pass_done()
			return
	elif not alive or a >= duration - 0.001:
		_state = State.STOPPED
		_apos = duration
		set_process(false)
		position_changed.emit(position())
		song_ended.emit()
		return
	else:
		_update_line_from_pos(false)
	position_changed.emit(position())


# ---------------------------------------------------------------- internals

func _pass_done() -> void:
	loops_done += 1
	if _repeat != 0 and loops_done >= _repeat:
		backend.halt()
		_state = State.STOPPED
		_apos = _sec_end
		_line_mode = false
		set_process(false)
		position_changed.emit(position())
		finished_loop.emit(loops_done)
		return
	backend.start(_sec_start)
	position_changed.emit(position())


func _seek_play(apos: float) -> void:
	backend.start(apos)
	_state = State.PLAYING
	_apos = apos


func _apply_speed() -> void:
	if backend == null:
		return
	var fx_pitch := 1.0
	var fx_on := false
	if keep_pitch and absf(speed - 1.0) > 0.0005:
		fx_pitch = 1.0 / speed
		fx_on = true
	backend.set_speed_pitch(speed, fx_pitch, fx_on)


func _set_line(i: int) -> void:
	if i != _cur_line:
		_cur_line = i
		line_changed.emit(i)


func _update_line_from_pos(force: bool) -> void:
	var t := position()
	var idx := -1
	if _cur_line >= 0 and _cur_line < _lines.size() and not force:
		var lo: float = _lines[_cur_line]["t0"]
		var hi: float = _lines[_cur_line + 1]["t0"] if _cur_line + 1 < _lines.size() else INF
		if t >= lo and t < hi:
			return
	for i in _lines.size():
		if _lines[i]["t0"] <= t:
			idx = i
		else:
			break
	_set_line(idx)


func _audio_path(song: Dictionary) -> String:
	var p := str(song.get("_audio_path", ""))
	if p != "":
		return p
	var audio = song.get("audio")
	var f := ""
	if audio is Dictionary:
		f = str(audio.get("file", ""))
	var id := str(song.get("id", ""))
	if f == "" or id == "" or f.contains("..") or f.contains("/") or f.contains("\\") or id.contains("..") or id.contains("/") or id.contains("\\"):
		return ""
	return "%s/%s/%s" % [songs_root, id, f]


func _valid_song(song: Dictionary) -> bool:
	return song.has("lines") and song["lines"] is Array
