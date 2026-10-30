extends Node
## SongPlayer (docs/song_study_design.md §5.4/§5.5, G5): load, "Song" bus, speed + pitch compensation, line loops,
## fake adapter (own clock), real headless audio, bus/stream cleanup.
##   godot --headless --path <project> res://tests/song_player_test.tscn
## Exit code 0 = all checks passed. Last line: "== song_player_test result: N passed, 0 failed =="
## The test mp3 is a 5.000 s 440 Hz sine made by the test author (python av/libmp3lame, 16 kbps mono 22050 Hz), embedded
## below as base64 (no real music). Files go to user://test_song_g5 only.

const DIR := "user://test_song_g5"
const TRUTH_LEN := 5.0

var passed: int = 0
var failed: int = 0
var _done_flag: bool = false
var _skipped: Array[String] = []


var _quiet: bool = false


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		if not _quiet:
			print("  FAIL  ", name)
	if cond and name.begins_with(("G5-5 real")) or cond and name.begins_with("real:"):
		print("  info  ", name)


## Stands in for the audio side: its own clock, advanced by the test.
class Fake:
	extends SongPlayer.Adapter
	var dur: float = 20.0
	var now: float = 0.0
	var running: bool = false
	var paused: bool = false
	var speed: float = 1.0
	var fx_pitch: float = 1.0
	var fx_on: bool = false
	var starts: Array = []
	var before_starts: Array = [] ## pos() just before each start()
	var halts: int = 0
	var released: bool = false
	var fail: bool = false
	var loaded_path: String = ""

	func load_audio(path: String) -> float:
		loaded_path = path
		if fail:
			err = "fake load failure"
			return 0.0
		return dur

	func start(from: float) -> void:
		before_starts.append(now)
		now = from
		running = true
		paused = false
		starts.append(from)

	func set_paused(p: bool) -> void:
		paused = p

	func halt() -> void:
		running = false
		halts += 1

	func is_playing() -> bool:
		return running

	func pos() -> float:
		return now

	func set_speed_pitch(s: float, p: float, e: bool) -> void:
		speed = s
		fx_pitch = p
		fx_on = e

	func release() -> void:
		released = true

	func advance(dt: float) -> void:
		if running and not paused:
			now += dt * speed
			if now >= dur:
				now = dur
				running = false


## A real AudioAdapter that remembers the position it had right before every restart (overshoot of the loop end).
class Probe:
	extends SongPlayer.AudioAdapter
	var before_starts: Array = []

	func start(from: float) -> void:
		before_starts.append(pos())
		super.start(from)


var _loop_counts: Array = []
var _lines_seen: Array = []
var _ends: int = 0
var _positions: Array = []


func _ready() -> void:
	print("== song_player_test start ==")
	_clean_dir()
	DirAccess.make_dir_recursive_absolute(DIR)
	_test_checker_self()
	var baseline := _bus_names()
	_test_fake_basics()
	_test_fake_speed()
	_test_fake_lines_and_loops()
	_test_fake_offset_and_bounds()
	_test_fake_state_and_signals()
	_test_bad_inputs_fake()
	await _test_real_load()
	_test_real_bad_files()
	await _test_real_audio_time()
	await _test_real_line_loop()
	await _test_cleanup(baseline)
	_test_forbidden_files()
	_done_flag = true
	ok(_done_flag, "reached the end of the test")
	_clean_dir()
	if not _skipped.is_empty():
		print("  SKIPPED (unverified): ", ", ".join(_skipped))
	print("== song_player_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ helpers

func _song(lines: Array = [], extra: Dictionary = {}) -> Dictionary:
	var s := {"v": 1, "id": "s_aaaaaaaaaaaa", "lang": "en", "duration": 20.0, "offset": 0.0,
		"audio": {"file": "audio.mp3"}, "lines": lines}
	s.merge(extra, true)
	return s


func _lines3() -> Array:
	return [{"i": 0, "t0": 2.0, "t1": 4.0}, {"i": 1, "t0": 6.0, "t1": 9.0}, {"i": 2, "t0": 10.0, "t1": 12.0}]


func _new_fake_player(song: Dictionary = {}, fake: Fake = null) -> Array:
	var p := SongPlayer.new()
	var f: Fake = fake if fake != null else Fake.new()
	p.backend = f
	add_child(p)
	var s := song if not song.is_empty() else _song(_lines3())
	var loaded := p.load_song(s)
	return [p, f, loaded]


## Advances the fake clock in `step` slices and calls update() each time.
func _run(p: SongPlayer, f: Fake, secs: float, step: float = 0.02) -> void:
	var n := int(round(secs / step))
	for _i in n:
		f.advance(step)
		p.update()


func _bus_names() -> Array:
	var a: Array = []
	for i in AudioServer.bus_count:
		a.append(AudioServer.get_bus_name(i))
	return a


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _mp3_song(id: String, lines: Array = []) -> Dictionary:
	var d := DIR + "/" + id
	DirAccess.make_dir_recursive_absolute(d)
	_write_bytes(d + "/audio.mp3", Marshalls.base64_to_raw(SINE_B64))
	var s := _song(lines, {"id": id, "duration": TRUTH_LEN})
	s["_audio_path"] = d + "/audio.mp3"
	return s


func _clean_dir() -> void:
	_rm_rec(ProjectSettings.globalize_path(DIR))


func _rm_rec(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for n in d.get_directories():
		_rm_rec(path + "/" + n)
	for n in d.get_files():
		DirAccess.remove_absolute(path + "/" + n)
	DirAccess.remove_absolute(path)


# ------------------------------------------------------------------ tests

func _test_checker_self() -> void:
	print("[checker self-test: ok() must count a false condition as a failure]")
	var f0 := failed
	var p0 := passed
	_quiet = true
	ok(false, "intentional failure (expected to be counted, not a real failure)")
	_quiet = false
	var counted := failed == f0 + 1 and passed == p0
	failed = f0 # undo the intentional failure
	ok(counted, "ok(false) increments failed")


func _test_fake_basics() -> void:
	print("[fake adapter: load / position / stop]")
	var r := _new_fake_player()
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	ok(r[2], "load_song with fake backend -> true")
	ok(p.duration == 20.0 and p.is_loaded(), "duration taken from the backend")
	ok(f.loaded_path == "user://songs/s_aaaaaaaaaaaa/audio.mp3", "audio path = songs_root/<id>/<audio.file> (" + f.loaded_path + ")")
	ok(not p.is_playing() and p.position() == 0.0, "idle: not playing, position 0")
	p.play_from(3.0)
	ok(p.is_playing() and is_equal_approx(f.now, 3.0), "play_from(3) starts at audio 3.0")
	_run(p, f, 1.0)
	ok(absf(p.position() - 4.0) < 0.001, "position() after 1.0 s = 4.0 (%.3f)" % p.position())
	p.stop()
	ok(not p.is_playing() and f.halts == 1 and p.position() == 0.0, "stop(): halted once, position 0")
	p.stop()
	ok(f.halts == 1, "stop() while stopped does not call halt again")
	p.free()


func _test_fake_speed() -> void:
	print("[fake adapter: speed / pitch compensation]")
	var r := _new_fake_player()
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	p.set_speed(0.75)
	ok(f.speed == 0.75, "set_speed(0.75) -> player pitch_scale 0.75")
	ok(absf(f.fx_pitch - 1.0 / 0.75) < 0.001 and f.fx_on, "effect pitch_scale = 1/0.75 (%.4f), enabled" % f.fx_pitch)
	p.set_keep_pitch(false)
	ok(f.fx_pitch == 1.0 and not f.fx_on, "keep_pitch=false -> effect 1.0, bypassed")
	ok(f.speed == 0.75, "speed untouched by set_keep_pitch")
	p.set_keep_pitch(true)
	ok(absf(f.fx_pitch - 1.0 / 0.75) < 0.001 and f.fx_on, "keep_pitch=true again -> 1/0.75")
	p.set_speed(1.0)
	ok(f.speed == 1.0 and not f.fx_on and f.fx_pitch == 1.0, "speed 1.0 -> effect bypassed")
	p.set_speed(0.1)
	ok(f.speed == 0.5 and absf(f.fx_pitch - 2.0) < 0.001, "speed clamped to 0.5 (effect 2.0)")
	p.set_speed(9.0)
	ok(f.speed == 1.25 and absf(f.fx_pitch - 0.8) < 0.001, "speed clamped to 1.25 (effect 0.8)")
	for s in SongPlayer.SPEED_PRESETS:
		p.set_speed(s)
		ok(absf(f.speed * f.fx_pitch - 1.0) < 0.001, "preset %.2f: speed * effect = 1" % s)
	# speed set before load_song reaches the new backend
	var p2 := SongPlayer.new()
	var f2 := Fake.new()
	p2.backend = f2
	add_child(p2)
	p2.set_speed(0.65)
	p2.load_song(_song(_lines3()))
	ok(f2.speed == 0.65 and f2.fx_on, "speed chosen before load is applied at load")
	# stream time runs at `speed`
	p.set_speed(0.5)
	p.play_from(0.0)
	_run(p, f, 2.0)
	ok(absf(p.position() - 1.0) < 0.001, "speed 0.5: 2 s later position 1.0 (%.3f)" % p.position())
	p.free()
	p2.free()


func _test_fake_lines_and_loops() -> void:
	print("[fake adapter: line loops]")
	var r := _new_fake_player()
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	_loop_counts = []
	p.finished_loop.connect(func(c): _loop_counts.append(c))
	p.play_line(1, 3)
	# line 1: t0 6, t1 9 -> section 5.85 .. 9.25
	ok(absf(f.starts[0] - 5.85) < 0.0001, "play_line start = t0 - 0.15 (%.3f)" % f.starts[0])
	_run(p, f, 20.0)
	ok(f.starts.size() == 3, "repeat=3: exactly 3 passes started (%d)" % f.starts.size())
	var all_same := true
	for s in f.starts:
		if absf(s - 5.85) > 0.0001:
			all_same = false
	ok(all_same, "every pass restarts at the section start")
	ok(_loop_counts == [3], "finished_loop(3) emitted exactly once (%s)" % str(_loop_counts))
	ok(not p.is_playing(), "stopped after the last pass")
	var max_over := 0.0
	for i in range(1, f.before_starts.size()):
		max_over = maxf(max_over, f.before_starts[i] - 9.25)
	ok(max_over <= 0.08 and max_over >= 0.0, "restart happens within 80 ms of the section end (over %.3f)" % max_over)
	# repeat 1 (default)
	_loop_counts = []
	f.starts.clear()
	p.play_line(0)
	_run(p, f, 10.0)
	ok(f.starts.size() == 1 and _loop_counts == [1], "default repeat=1: one pass, finished_loop(1)")
	# infinite
	_loop_counts = []
	f.starts.clear()
	p.play_line(2, 0)
	_run(p, f, 60.0)
	ok(p.is_playing() and f.starts.size() > 15, "repeat=0 keeps looping (%d passes in 60 s)" % f.starts.size())
	ok(_loop_counts.is_empty(), "repeat=0: no finished_loop while looping")
	p.stop()
	var n := f.starts.size()
	_run(p, f, 5.0)
	ok(f.starts.size() == n and not p.is_playing() and _loop_counts.is_empty(), "stop() ends the infinite loop; no more passes, no finished_loop")
	# changing line in the middle of a loop
	p.play_line(0, 3)
	_run(p, f, 1.0)
	f.starts.clear()
	p.play_line(2, 1)
	ok(absf(f.starts[0] - 9.85) < 0.0001 and p.loops_done == 0, "play_line(new) restarts the pass counter")
	# line_changed from play_line
	_lines_seen = []
	p.line_changed.connect(func(i): _lines_seen.append(i))
	p.play_line(1)
	p.play_line(1)
	ok(_lines_seen == [1], "play_line emits line_changed(1) once (%s)" % str(_lines_seen))
	# negative repeat counts as 1
	f.starts.clear()
	p.play_line(0, -4)
	_run(p, f, 10.0)
	ok(f.starts.size() == 1, "negative repeat treated as 1")
	p.free()


func _test_fake_offset_and_bounds() -> void:
	print("[fake adapter: offset / section bounds]")
	var r := _new_fake_player(_song(_lines3(), {"offset": 0.5}))
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	p.play_line(0)
	ok(absf(f.starts[0] - (2.0 + 0.5 - 0.15)) < 0.0001, "offset 0.5: start = t0 + 0.5 - 0.15 (%.3f)" % f.starts[0])
	var sec := p.line_section(0)
	ok(absf(sec[1] - (4.0 + 0.5 + 0.25)) < 0.0001, "offset 0.5: end = t1 + 0.5 + 0.25 (%.3f)" % sec[1])
	f.now = 3.0
	ok(absf(p.position() - 2.5) < 0.0001, "position() = audio - offset (%.3f)" % p.position())
	p.play_from(10.0)
	ok(absf(f.starts[f.starts.size() - 1] - 10.5) < 0.0001, "play_from(10) with offset 0.5 -> audio 10.5")
	p.free()
	# negative offset
	r = _new_fake_player(_song(_lines3(), {"offset": -1.0}))
	p = r[0]
	f = r[1]
	p.play_line(0)
	ok(absf(f.starts[0] - 0.85) < 0.0001, "offset -1.0: start = 2 - 1 - 0.15 = 0.85 (%.3f)" % f.starts[0])
	p.free()
	# bounds: first line close to the song start, last line close to the song end
	var lines := [{"i": 0, "t0": 0.05, "t1": 1.0}, {"i": 1, "t0": 19.0, "t1": 19.9}]
	r = _new_fake_player(_song(lines))
	p = r[0]
	f = r[1]
	p.play_line(0)
	ok(f.starts[0] == 0.0, "start outside the song -> 0 (%.3f)" % f.starts[0])
	ok(absf(p.line_section(0)[1] - 1.25) < 0.0001, "end = t1 + 0.25")
	ok(p.line_section(1)[1] == 20.0, "end outside the song -> duration")
	f.starts.clear()
	p.play_line(1, 2)
	_run(p, f, 10.0)
	ok(f.starts.size() == 2 and not p.is_playing(), "last line clipped at the song end still loops twice (%d)" % f.starts.size())
	p.free()
	# t1 <= t0 (broken line) gets a minimal section, never an empty one
	r = _new_fake_player(_song([{"i": 0, "t0": 5.0, "t1": 5.0}]))
	p = r[0]
	ok(p.line_section(0)[1] - p.line_section(0)[0] >= SongPlayer.MIN_SECTION - 0.0001, "degenerate line gets a minimal section")
	p.free()
	# offset is clamped to +-5
	r = _new_fake_player(_song(_lines3(), {"offset": 99.0}))
	ok((r[0] as SongPlayer).offset == 5.0, "offset clamped to 5")
	(r[0] as SongPlayer).free()


func _test_fake_state_and_signals() -> void:
	print("[fake adapter: pause / resume / line_changed / end / app pause]")
	var r := _new_fake_player()
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	_lines_seen = []
	_ends = 0
	_positions = []
	p.line_changed.connect(func(i): _lines_seen.append(i))
	p.song_ended.connect(func(): _ends += 1)
	p.position_changed.connect(func(t): _positions.append(t))
	p.play_from(0.0)
	_run(p, f, 2.5)
	_run(p, f, 4.0)
	_run(p, f, 4.0)
	ok(_lines_seen == [0, 1, 2], "line_changed follows the position: 0, 1, 2 (%s)" % str(_lines_seen))
	ok(_positions.size() > 100 and absf(_positions[_positions.size() - 1] - p.position()) < 0.0001, "position_changed emitted while playing")
	p.play_from(10.5)
	p.play_from(1.0)
	ok(_lines_seen.slice(-2) == [2, -1], "seeking emits line_changed (2 then -1): %s" % str(_lines_seen.slice(-2)))
	# pause / resume
	_run(p, f, 1.0)
	p.pause()
	var at := p.position()
	ok(p.is_paused() and f.paused and absf(at - 2.0) < 0.001, "pause(): paused at 2.0 (%.3f)" % at)
	_run(p, f, 3.0)
	ok(absf(p.position() - at) < 0.0001, "position frozen while paused")
	p.resume()
	_run(p, f, 1.0)
	ok(p.is_playing() and absf(p.position() - (at + 1.0)) < 0.001, "resume() continues from the pause point")
	p.pause()
	p.play_from(7.0)
	ok(p.is_playing() and not f.paused, "play_from() while paused starts playing again")
	p.pause()
	p.pause()
	ok(p.is_paused(), "double pause is harmless")
	p.resume()
	# app pause notification
	p.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	ok(p.is_paused() and f.paused, "NOTIFICATION_APPLICATION_PAUSED pauses playback")
	p.stop()
	p.pause()
	ok(not p.is_paused() and not p.is_playing(), "pause() while stopped stays stopped")
	p.resume()
	ok(not p.is_playing(), "resume() while stopped does nothing")
	# song end
	_ends = 0
	p.play_from(19.8)
	_run(p, f, 1.0)
	ok(_ends == 1 and not p.is_playing(), "song_ended once at the end (%d)" % _ends)
	ok(p.position() == 20.0, "position at the end = duration")
	_run(p, f, 1.0)
	ok(_ends == 1, "song_ended not repeated")
	# seek far beyond the end
	p.play_from(999.0)
	_run(p, f, 0.2)
	ok(not p.is_playing(), "play_from beyond the end ends the song")
	# unload
	p.play_from(1.0)
	p.unload()
	ok(f.released and not p.is_loaded() and not p.is_playing(), "unload(): backend released, stopped")
	p.play_from(1.0)
	p.play_line(0)
	ok(not p.is_playing(), "after unload play_* are ignored")
	p.free()


func _test_bad_inputs_fake() -> void:
	print("[wrong inputs with the fake adapter]")
	var r := _new_fake_player()
	var p: SongPlayer = r[0]
	var f: Fake = r[1]
	p.play_line(-1)
	p.play_line(3)
	p.play_line(999, 2)
	ok(f.starts.is_empty() and not p.is_playing(), "play_line with an out-of-range index is ignored")
	ok(p.load_song({}) == false and p.last_error != "", "load_song({}) -> false + message (%s)" % p.last_error)
	ok(p.load_song({"id": "s_x", "audio": {"file": "audio.mp3"}}) == false, "song without lines -> false")
	ok(p.load_song(_song(_lines3(), {"duration": 0.0})) == false and p.last_error != "", "duration 0 -> false + message")
	ok(p.load_song(_song(_lines3(), {"audio": {}})) == false, "no audio file name -> false")
	ok(p.load_song(_song(_lines3(), {"audio": {"file": "../../x.mp3"}})) == false, "audio file with ../ -> false")
	ok(p.load_song(_song(_lines3(), {"id": "../evil"})) == false, "id with ../ -> false")
	ok(not p.is_loaded(), "failed load leaves the player unloaded")
	p.play_from(1.0)
	ok(not p.is_playing(), "play_from on an unloaded player is ignored")
	var f2 := Fake.new()
	f2.fail = true
	p.backend = f2
	ok(p.load_song(_song(_lines3())) == false and p.last_error == "fake load failure", "backend load failure -> false + its message")
	# a good load after a failed one works
	p.backend = Fake.new()
	ok(p.load_song(_song(_lines3())), "load works again after failures")
	p.free()


func _test_real_load() -> void:
	print("[real audio: load the test mp3, bus, speed math]")
	ok(AudioServer.get_bus_index("Song") == -1, "no Song bus before the first load")
	var master_fx := AudioServer.get_bus_effect_count(0)
	var master_vol := AudioServer.get_bus_volume_db(0)
	var master_mute := AudioServer.is_bus_mute(0)
	var bus_count := AudioServer.bus_count
	var p := SongPlayer.new()
	add_child(p)
	var s := _mp3_song("s_real00000001", [{"i": 0, "t0": 1.0, "t1": 2.0}, {"i": 1, "t0": 3.0, "t1": 4.0}])
	ok(p.load_song(s), "load_song(real mp3) -> true (" + p.last_error + ")")
	ok(absf(p.duration - TRUTH_LEN) <= 0.15, "decoded length %.3f vs truth %.1f (+-0.15)" % [p.duration, TRUTH_LEN])
	var idx := AudioServer.get_bus_index("Song")
	ok(idx >= 0 and AudioServer.bus_count == bus_count + 1, "Song bus created (one new bus)")
	ok(AudioServer.get_bus_effect_count(idx) == 1 and AudioServer.get_bus_effect(idx, 0) is AudioEffectPitchShift, "Song bus has exactly one AudioEffectPitchShift")
	var fx: AudioEffectPitchShift = AudioServer.get_bus_effect(idx, 0)
	ok(fx.fft_size == AudioEffectPitchShift.FFT_SIZE_2048 and fx.oversampling == 4, "fft_size 2048, oversampling 4")
	ok(AudioServer.get_bus_send(idx) == &"Master", "Song bus sends to Master")
	var b: SongPlayer.AudioAdapter = p.backend
	ok(b.player != null and b.player.bus == &"Song" and b.player.get_parent() == p, "AudioStreamPlayer is a child of the SongPlayer, on the Song bus")
	# speed math on the real objects
	p.set_speed(0.75)
	ok(b.player.pitch_scale == 0.75, "real player pitch_scale == 0.75")
	ok(absf(fx.pitch_scale - 1.0 / 0.75) <= 0.001, "real effect pitch_scale ~ 1/0.75 (%.4f)" % fx.pitch_scale)
	ok(AudioServer.is_bus_effect_enabled(idx, 0), "effect enabled at 0.75")
	p.set_keep_pitch(false)
	ok(fx.pitch_scale == 1.0 and b.player.pitch_scale == 0.75, "keep_pitch=false -> effect 1.0, speed 0.75 kept")
	p.set_keep_pitch(true)
	p.set_speed(1.0)
	ok(not AudioServer.is_bus_effect_enabled(idx, 0) and b.player.pitch_scale == 1.0, "speed 1.0 -> effect bypassed (disabled)")
	p.set_speed(0.5)
	ok(AudioServer.is_bus_effect_enabled(idx, 0) and absf(fx.pitch_scale - 2.0) <= 0.001, "speed 0.5 -> effect 2.0, enabled again")
	p.set_speed(1.0)
	# nothing else on Master changed
	ok(AudioServer.get_bus_effect_count(0) == master_fx, "Master effect count unchanged (%d)" % master_fx)
	ok(AudioServer.get_bus_volume_db(0) == master_vol and AudioServer.is_bus_mute(0) == master_mute, "Master volume/mute unchanged")
	p.queue_free()
	await get_tree().process_frame
	ok(AudioServer.get_bus_index("Song") == -1 and AudioServer.bus_count == bus_count, "freeing the player removes the Song bus")


func _test_real_bad_files() -> void:
	print("[real audio: wrong files]")
	var bus_count := AudioServer.bus_count
	var p := SongPlayer.new()
	add_child(p)
	var d := DIR + "/s_bad000000001"
	DirAccess.make_dir_recursive_absolute(d)
	# missing file
	var s := _song(_lines3(), {"id": "s_bad000000001"})
	s["_audio_path"] = d + "/audio.mp3"
	ok(p.load_song(s) == false and p.last_error != "", "missing audio file -> false + message (%s)" % p.last_error)
	# via songs_root + id + audio.file
	var old_root := SongPlayer.songs_root
	SongPlayer.songs_root = DIR
	ok(p.load_song(_song(_lines3(), {"id": "s_bad000000001"})) == false, "missing file (songs_root path) -> false")
	# zero-byte file
	_write_bytes(d + "/audio.mp3", PackedByteArray())
	ok(p.load_song(_song(_lines3(), {"id": "s_bad000000001"})) == false and p.last_error != "", "0-byte audio -> false + message")
	# garbage bytes named mp3
	var junk := PackedByteArray()
	for i in 4000:
		junk.append((i * 7919 + 13) % 251)
	_write_bytes(d + "/audio.mp3", junk)
	ok(p.load_song(_song(_lines3(), {"id": "s_bad000000001"})) == false and p.last_error != "", "garbage bytes as mp3 -> false + message")
	# truncated real mp3 (first 200 bytes) must not crash; either rejected or short
	var full := Marshalls.base64_to_raw(SINE_B64)
	_write_bytes(d + "/audio.mp3", full.slice(0, 200))
	var res := p.load_song(_song(_lines3(), {"id": "s_bad000000001"}))
	ok(res == false or p.duration < TRUTH_LEN, "truncated mp3 -> rejected or short, no crash")
	SongPlayer.songs_root = old_root
	p.play_from(0.0)
	p.play_line(0)
	p.free()
	ok(AudioServer.bus_count == bus_count, "bus count back to baseline after the wrong-file cases (no Song bus left)")


func _test_real_audio_time() -> void:
	print("[real audio: elapsed time through the (dummy) audio driver]")
	var p := SongPlayer.new()
	add_child(p)
	var s := _mp3_song("s_real00000002", [{"i": 0, "t0": 1.0, "t1": 2.0}])
	ok(p.load_song(s), "load for timing")
	p.play_from(0.0)
	await get_tree().create_timer(2.0).timeout
	var pos1 := p.position()
	p.stop()
	if pos1 < 0.1:
		_skipped.append("G5-5 (dummy driver does not advance time: pos %.3f)" % pos1)
	else:
		ok(pos1 >= 1.7 and pos1 <= 2.3, "G5-5 real: 2 s of playback -> position %.3f in 1.7..2.3" % pos1)
		p.set_speed(0.5)
		p.play_from(0.0)
		await get_tree().create_timer(2.0).timeout
		var pos2 := p.position()
		p.stop()
		ok(pos2 >= 0.8 and pos2 <= 1.2, "G5-5 real: speed 0.5, 2 s -> position %.3f in 0.8..1.2" % pos2)
	p.free()
	await get_tree().process_frame


func _test_real_line_loop() -> void:
	print("[real audio: line loop restarts]")
	var p := SongPlayer.new()
	var probe := Probe.new()
	p.backend = probe
	probe.setup(p)
	add_child(p)
	var s := _mp3_song("s_real00000003", [{"i": 0, "t0": 1.0, "t1": 1.4}])
	ok(p.load_song(s), "load for loop")
	_loop_counts = []
	p.finished_loop.connect(func(c): _loop_counts.append(c))
	var t_start := Time.get_ticks_msec()
	p.play_line(0, 3)
	# section 0.85 .. 1.65 = 0.8 s per pass at speed 1.0
	while _loop_counts.is_empty():
		await get_tree().process_frame
		if Time.get_ticks_msec() - t_start > 6000:
			break
	var elapsed := (Time.get_ticks_msec() - t_start) / 1000.0
	ok(_loop_counts == [3], "real: 3 passes -> finished_loop(3) once (%s)" % str(_loop_counts))
	ok(elapsed >= 2.0 and elapsed <= 3.0, "real: 3 passes of 0.8 s took %.2f s (2.0..3.0)" % elapsed)
	var max_over := 0.0
	for i in range(1, probe.before_starts.size()):
		max_over = maxf(max_over, probe.before_starts[i] - 1.65)
	ok(probe.before_starts.size() == 3 and max_over <= 0.08, "real: restart overshoot %.3f s <= 0.08 (%d restarts)" % [max_over, probe.before_starts.size() - 1])
	p.free()
	await get_tree().process_frame


func _test_cleanup(baseline: Array) -> void:
	print("[cleanup: bus refcount, leaks, forbidden changes]")
	# two players share the one Song bus; it goes away with the last one
	var a := SongPlayer.new()
	var b := SongPlayer.new()
	add_child(a)
	add_child(b)
	var s1 := _mp3_song("s_real00000004")
	var s2 := _mp3_song("s_real00000005")
	ok(a.load_song(s1) and b.load_song(s2), "two players load")
	var songs := 0
	for n in _bus_names():
		if n == "Song":
			songs += 1
	ok(songs == 1, "still exactly one Song bus with two players (%d)" % songs)
	a.free()
	ok(AudioServer.get_bus_index("Song") >= 0, "bus kept while another player uses it")
	b.set_speed(0.75)
	b.play_from(0.5)
	ok(b.is_playing(), "second player still plays after the first was freed")
	b.unload()
	ok(AudioServer.get_bus_index("Song") == -1, "unload() of the last player removes the Song bus")
	ok(not b.is_playing() and not b.is_loaded(), "unload() stops playback")
	b.free()
	# stream/node leak check over many cycles
	await get_tree().process_frame
	var obj0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var orph0 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	for i in 15:
		var q := SongPlayer.new()
		add_child(q)
		q.load_song(s1)
		q.play_from(0.2)
		q.set_speed(0.9)
		q.unload()
		q.free()
	await get_tree().create_timer(1.5).timeout # the engine frees finished stream playbacks a moment after stop()
	var obj1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var orph1 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	ok(obj1 - obj0 <= 6, "15 load/play/unload cycles: object count %d -> %d (<= +6)" % [obj0, obj1])
	ok(orph1 <= orph0, "no orphan nodes left behind (%d -> %d)" % [orph0, orph1])
	ok(_bus_names() == baseline, "bus list identical to the start: %s" % str(_bus_names()))
	# freeing a player mid-loop frees it and the bus at once
	var c := SongPlayer.new()
	add_child(c)
	c.load_song(_mp3_song("s_real00000006", [{"i": 0, "t0": 1.0, "t1": 1.4}]))
	c.play_line(0, 0)
	await get_tree().create_timer(0.3).timeout
	c.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	ok(not is_instance_valid(c) and AudioServer.get_bus_index("Song") == -1, "freeing a player mid-loop frees it and the Song bus")
	ok(_bus_names() == baseline, "bus list identical to the start after the mid-loop free")
	ok(not Tts.playing and not Tts.busy, "Tts untouched (idle)")


func _test_forbidden_files() -> void:
	print("[things the player must not touch]")
	var raw := FileAccess.get_file_as_string("res://scripts/local/song_player.gd")
	ok(raw != "", "song_player.gd readable")
	var code: Array[String] = []
	for ln in raw.split("\n"):
		var c := ln.get_slice(" #", 0) if not ln.strip_edges().begins_with("#") else ""
		code.append(c)
	var src := "\n".join(code) # code only, comments removed
	ok(src.count("\"Master\"") == 1, "Master is named once (the Song bus send)")
	ok(not src.contains("Recorder") and not src.contains("Tts."), "no reference to Recorder / Tts")
	ok(not src.contains("set_bus_volume_db") and not src.contains("set_bus_mute") and not src.contains("set_bus_solo"), "no volume/mute/solo changes on any bus")
	ok(src.count("add_bus_effect") == 1 and src.count("remove_bus(") == 1, "one add_bus_effect and one remove_bus call (Song bus only)")


const SINE_B64 := "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"
