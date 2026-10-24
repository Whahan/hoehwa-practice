extends Node
## System-voice TTS engine (A5): SystemTts + the Tts autoload's engine choice, with a fake DisplayServer adapter.
##   godot --headless --path <project> res://tests/system_tts_test.tscn -- --phone
## Without `--phone` only the PC-side checks and the SystemTts unit checks run (Tts.engine_now() is always "pc" there).
## Exit code 0 = all checks passed. Last line: "== system_tts_test result: N passed, 0 failed =="

const S := DisplayServer.TTS_UTTERANCE_STARTED
const E := DisplayServer.TTS_UTTERANCE_ENDED
const C := DisplayServer.TTS_UTTERANCE_CANCELED
const JA_TEXT := "이 휴대폰에 일본어 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 일본어 음성 데이터를 내려받아 주세요."

var passed: int = 0
var failed: int = 0

var fake: Fake
var _orig_adapter: SystemTts.Adapter
var _events: Array = [] ## ["state", busy, playing] / ["chunk", i, text] / ["seq"]
var _toasts: Array[String] = []
var _prefs_backup: Dictionary = {}


## Records every call; the test fires the callbacks in the order it wants.
class Fake:
	extends SystemTts.Adapter
	var voices: Array = []
	var speaks: Array = [] ## {text, voice, volume, pitch, rate, id, interrupt}
	var stops: int = 0
	var speaking: bool = false
	var calls: Array = [] ## "speak" / "stop" / "voices" in call order
	var cbs: Dictionary = {}
	var fire_start_inside_speak: bool = false

	func available() -> bool:
		return true

	func get_voices() -> Array:
		calls.append("voices")
		return voices

	func speak(text: String, voice: String, volume: int, pitch: float, rate: float, utterance_id: int, interrupt: bool) -> void:
		calls.append("speak")
		speaks.append({"text": text, "voice": voice, "volume": volume, "pitch": pitch, "rate": rate, "id": utterance_id, "interrupt": interrupt})
		speaking = true
		if fire_start_inside_speak:
			fire(DisplayServer.TTS_UTTERANCE_STARTED)

	func stop() -> void:
		calls.append("stop")
		stops += 1
		speaking = false

	func is_speaking() -> bool:
		return speaking

	func set_callback(kind: int, cb: Callable) -> void:
		cbs[kind] = cb

	func last_id() -> int:
		return int(speaks[speaks.size() - 1]["id"]) if not speaks.is_empty() else -1

	func fire(kind: int, id: int = -2) -> void:
		var cb: Callable = cbs.get(kind, Callable())
		if cb.is_valid():
			cb.call(last_id() if id == -2 else id)

	## calls without the voice-list reads
	func moves() -> Array:
		return calls.filter(func(c: String) -> bool: return c != "voices")


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== system_tts_test start ==  phone=%s" % str(Platform.is_phone()))
	Store.prefs_path = "user://test_a5_prefs.json"
	_prefs_backup = Store.prefs.duplicate(true)
	for k in ["tts_engine", "tts_voice_en", "tts_voice_ja", "tts_sys_voice_en", "tts_sys_voice_ja", "tts_speed"]:
		Store.prefs.erase(k)
	_orig_adapter = SystemTts.adapter
	Tts.state_changed.connect(func() -> void: _events.append(["state", Tts.busy, Tts.playing]))
	Tts.chunk_started.connect(func(i: int, t: String) -> void: _events.append(["chunk", i, t]))
	Tts.sequence_finished.connect(func() -> void: _events.append(["seq"]))
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	_test_engine_table()
	_test_voice_selection()
	if Platform.is_phone():
		await _test_signals()
		await _test_stop_and_interrupt()
		await _test_no_voice()
		await _test_retry()
		await _test_watchdog()
		await _test_misc()
		await _test_voice_list()
	else:
		print("  (not --phone: Tts-level system tests skipped)")
	_cleanup()
	print("== system_tts_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _cleanup() -> void:
	Tts.stop()
	SystemTts.adapter = _orig_adapter
	Store.prefs = _prefs_backup
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_a5_prefs.json"))
	Route.mode = Route.DEFAULT_MODE
	Backend.status = Backend.Status.IDLE


func _new_fake(with_ja: bool = true) -> Fake:
	Tts.stop() # a speech of the previous fake must not keep its timers alive against the new one
	var f := Fake.new()
	f.voices = [
		{"name": "English US A", "id": "en-us-a", "language": "en_US"},
		{"name": "English US B", "id": "en-us-b", "language": "en-US"},
		{"name": "Korean", "id": "ko-kr-a", "language": "ko_KR"},
	]
	if with_ja:
		f.voices.append({"name": "Japanese", "id": "ja-jp-a", "language": "ja_JP"})
	fake = f
	SystemTts.adapter = f
	Tts._sys = null # a fresh engine object binds to the new fake
	_reset_log()
	return f


func _reset_log() -> void:
	_events.clear()
	_toasts.clear()


func _count(kind: String) -> int:
	var n := 0
	for e in _events:
		if e[0] == kind:
			n += 1
	return n


# ---------------------------------------------------------------- A5-6: engine_now table

func _engine_with(pref: Variant, ready: bool, mode: String) -> String:
	if pref == null:
		Store.prefs.erase("tts_engine")
	else:
		Store.prefs["tts_engine"] = pref
	Backend.status = Backend.Status.READY if ready else Backend.Status.IDLE
	Route.mode = mode
	return Tts.engine_now()


func _test_engine_table() -> void:
	print("[engine_now table]")
	if not Platform.is_phone():
		var all_pc := true
		for p in [null, "auto", "system", "pc", "x"]:
			for r in [true, false]:
				if _engine_with(p, r, "auto") != "pc":
					all_pc = false
		ok(all_pc, "PC app: engine_now() is always pc (every pref x backend state)")
		ok(Tts.voice_for("en") == "af_heart", "PC app: voice_for unchanged (af_heart)")
		Backend.status = Backend.Status.IDLE
		Store.prefs.erase("tts_engine")
		return
	ok(_engine_with(null, false, "auto") == "system", "phone, no pref (auto), backend not ready -> system")
	ok(_engine_with("auto", true, "auto") == "pc", "phone auto + backend ready (mode auto) -> pc")
	ok(_engine_with("auto", true, "phone") == "system", "phone auto + backend ready but mode phone -> system")
	ok(_engine_with("auto", true, "pc") == "pc", "phone auto + backend ready, mode pc -> pc")
	ok(_engine_with("auto", false, "auto") == "system", "phone auto + backend not ready -> system")
	ok(_engine_with("system", true, "auto") == "system", "phone system (even with backend ready) -> system")
	ok(_engine_with("system", false, "auto") == "system", "phone system, not ready -> system")
	ok(_engine_with("pc", false, "auto") == "pc", "phone pc (backend not ready) -> pc")
	ok(_engine_with("pc", true, "phone") == "pc", "phone pc, mode phone -> pc")
	ok(_engine_with("x", false, "auto") == "system", "pref 'x' counts as auto (not ready -> system)")
	ok(_engine_with("x", true, "auto") == "pc", "pref 'x' counts as auto (ready -> pc)")
	ok(_engine_with(7, false, "auto") == "system", "pref of a wrong type counts as auto")
	Backend.status = Backend.Status.IDLE
	Route.mode = Route.DEFAULT_MODE
	Store.prefs.erase("tts_engine")


# ---------------------------------------------------------------- voice choice (SystemTts alone)

func _test_voice_selection() -> void:
	print("[voice selection]")
	var f := _new_fake()
	var sys := SystemTts.new(null)
	ok(sys.voice_id_for("en") == "en-us-a", "en: first en voice when no pref")
	ok(sys.voice_id_for("ja") == "ja-jp-a", "ja: first ja voice when no pref")
	Store.prefs["tts_sys_voice_en"] = "en-us-b"
	ok(sys.voice_id_for("en") == "en-us-b", "en: saved tts_sys_voice_en wins")
	Store.prefs["tts_sys_voice_en"] = "gone-voice"
	ok(sys.voice_id_for("en") == "en-us-a", "en: saved id that the phone no longer has -> first en voice")
	Store.prefs["tts_sys_voice_ja"] = "en-us-a"
	ok(sys.voice_id_for("ja") == "ja-jp-a", "ja: a saved English voice is never used for Japanese")
	Store.prefs.erase("tts_sys_voice_en")
	Store.prefs.erase("tts_sys_voice_ja")
	ok(sys.voice_id_for("en", "en-us-b") == "en-us-b", "preview voice (argument) wins when the phone has it")
	f.voices = [{"name": "English", "id": "en-x", "language": "en_GB"}]
	ok(sys.voice_id_for("ja") == "", "no ja voice -> empty id")
	ok(sys.voices_ok() == {"en": true, "ja": false}, "voices_ok -> {en: true, ja: false}")
	f.voices = [{"name": "Japanese", "id": "jpn-x", "language": "jpn_JPN"}, "junk", {"name": "no id", "language": "en_US"}]
	ok(sys.voice_id_for("ja") == "jpn-x", "language code 'jpn' counts as Japanese; junk entries ignored")
	ok(sys.voices_ok() == {"en": false, "ja": true}, "voices_ok with junk entries -> {en: false, ja: true}")


# ---------------------------------------------------------------- A5-2: signal order

func _test_signals() -> void:
	print("[signal order]")
	Store.prefs["tts_engine"] = "system"
	var f := _new_fake()
	Tts.speak("A. B.", "en")
	ok(f.speaks.size() == 1 and f.speaks[0]["text"] == "A.", "first chunk handed to the engine")
	ok(f.speaks[0]["voice"] == "en-us-a" and bool(f.speaks[0]["interrupt"]), "voice id and interrupt flag passed")
	ok(f.moves() == ["stop", "speak"], "stop() precedes speak() (Android queues): %s" % str(f.moves()))
	ok(_count("chunk") == 0 and Tts.busy and not Tts.playing, "busy (not playing) until the engine reports START")
	f.fire(S)
	ok(Tts.playing and not Tts.busy, "START -> playing")
	ok(_events.has(["state", false, true]), "state_changed emitted with playing=true")
	f.fire(E)
	ok(f.speaks.size() == 2 and f.speaks[1]["text"] == "B.", "END of chunk 0 -> chunk 1 spoken")
	ok(_count("seq") == 0, "no sequence_finished before the last chunk ends")
	f.fire(S)
	f.fire(E)
	var chunks: Array = _events.filter(func(e: Array) -> bool: return e[0] == "chunk")
	ok(chunks == [["chunk", 0, "A."], ["chunk", 1, "B."]], "chunk_started(0,'A.') then chunk_started(1,'B.')")
	ok(_count("seq") == 1, "sequence_finished exactly once")
	var i_state := _events.find(["state", false, true])
	var i_c0 := _events.find(["chunk", 0, "A."])
	var i_c1 := _events.find(["chunk", 1, "B."])
	var i_seq := _events.find(["seq"])
	ok(i_state >= 0 and i_state < i_c0 and i_c0 < i_c1 and i_c1 < i_seq, "order: state_changed(playing) < chunk 0 < chunk 1 < sequence_finished")
	ok(not Tts.playing and not Tts.busy, "idle after the sequence")
	ok(Tts.last_timing.is_empty(), "last_timing stays empty on the system engine")
	ok(not Tts.is_cached("A. B.", "en"), "is_cached false on the system engine")


# ---------------------------------------------------------------- stop, interrupt, stale events

func _test_stop_and_interrupt() -> void:
	print("[stop / interrupt / stale events]")
	var f := _new_fake()
	Tts.speak("One. Two.", "en")
	f.fire(S)
	var stops_before := f.stops
	_reset_log()
	Tts.stop()
	ok(f.stops == stops_before + 1, "stop() -> adapter.stop() exactly once")
	ok(not Tts.playing and not Tts.busy, "stop() -> playing false")
	var old_id := f.last_id()
	var n_speaks := f.speaks.size()
	f.fire(C, old_id)
	f.fire(E, old_id)
	ok(f.speaks.size() == n_speaks and _count("seq") == 0, "late CANCEL/END of the stopped speech are ignored (no next chunk, no sequence_finished)")
	var stops_idle := f.stops
	Tts.stop()
	ok(f.stops == stops_idle, "stop() while idle does not touch the engine")
	# a new speech while another plays: stop() first, then speak()
	Tts.speak("First one.", "en")
	f.fire(S)
	f.calls.clear()
	var first_id := f.last_id()
	Tts.speak("Second one.", "en")
	ok(f.moves() == ["stop", "speak"], "speaking over a running speech: stop then speak (calls: %s)" % str(f.moves()))
	f.fire(C, first_id)
	ok(_count("seq") == 0, "the replaced speech's CANCEL does not end the new one")
	f.fire(S)
	f.fire(E)
	ok(_count("seq") == 1, "the new speech ends normally (sequence_finished once)")
	# events from a synchronous engine (START fired inside speak())
	var g := _new_fake()
	g.fire_start_inside_speak = true
	Tts.speak("Quick.", "en")
	ok(Tts.playing and _count("chunk") == 1, "START fired inside speak() is handled")
	g.fire(E)
	ok(_count("seq") == 1, "...and the speech ends")


# ---------------------------------------------------------------- A5-3: no voice for the language

func _test_no_voice() -> void:
	print("[no voice for the language]")
	var f := _new_fake(false) # English and Korean only
	Tts.speak("こんにちは。", "ja")
	ok(f.speaks.is_empty(), "no Japanese voice -> engine.speak never called (no English voice reads Japanese)")
	ok(_toasts.size() == 1 and _toasts[0] == JA_TEXT, "Toast carries the section 3.2 Japanese-voice text")
	ok(_count("seq") == 1, "sequence_finished still emitted once")
	ok(not Tts.busy and not Tts.playing, "state idle afterwards")
	ok(Tts.system_voices_ok() == {"en": true, "ja": false}, "system_voices_ok() -> {en: true, ja: false}")
	# the English side still works on the same phone
	_reset_log()
	Tts.speak("Hello.", "en")
	ok(f.speaks.size() == 1 and _toasts.is_empty(), "English still speaks on that phone")
	f.fire(S)
	f.fire(E)
	# a phone that reports no voice at all (engine not up): waits briefly, then the same kind of message
	var empty := _new_fake()
	empty.voices = []
	Tts._sys_get().voice_wait_sec = 0.3
	Tts.speak("Hello.", "en")
	await get_tree().create_timer(0.7).timeout
	ok(empty.speaks.is_empty() and _toasts.size() == 1 and _count("seq") == 1, "no voice at all: nothing spoken, one Toast, one sequence_finished")
	# the voices show up while waiting (engine finished starting) -> it speaks
	var late := _new_fake()
	late.voices = []
	Tts._sys_get().voice_wait_sec = 1.0
	Tts.speak("Hello.", "en")
	await get_tree().create_timer(0.25).timeout
	late.voices = [{"name": "English", "id": "en-late", "language": "en_US"}]
	await get_tree().create_timer(0.3).timeout
	ok(late.speaks.size() == 1 and late.speaks[0]["voice"] == "en-late", "voices appearing while waiting -> speaks with them")
	Tts.stop()


# ---------------------------------------------------------------- A5-4: one retry of the first utterance

func _test_retry() -> void:
	print("[first utterance retry]")
	var f := _new_fake()
	Tts._sys_get().start_timeout_sec = 5.0
	Tts.speak("Hello there.", "en")
	f.fire(C)
	ok(f.speaks.size() == 2, "first CANCEL -> exactly one retry (speak called twice)")
	ok(f.speaks[1]["text"] == "Hello there." and f.speaks[1]["id"] != f.speaks[0]["id"], "retry repeats the same text with a new utterance id")
	ok(_count("seq") == 0 and Tts.busy, "still busy during the retry, no sequence_finished yet")
	f.fire(S)
	f.fire(E)
	ok(_count("seq") == 1 and _count("chunk") == 1, "retry succeeded: chunk_started once, sequence_finished once")
	# both attempts cancelled
	var g := _new_fake()
	Tts._sys_get().start_timeout_sec = 5.0
	Tts.speak("Hello there.", "en")
	g.fire(C)
	g.fire(C)
	ok(g.speaks.size() == 2, "second CANCEL -> no third attempt (speak called twice in total)")
	ok(_count("seq") == 1 and not Tts.busy and not Tts.playing, "gives up: sequence_finished once, state idle")
	ok(_toasts.size() == 1, "gives up with one Toast")
	g.fire(C, g.last_id())
	ok(g.speaks.size() == 2 and _count("seq") == 1, "another late CANCEL changes nothing")
	# a later chunk that is cancelled is not retried
	var h := _new_fake()
	Tts._sys_get().start_timeout_sec = 5.0
	Tts.speak("One. Two.", "en")
	h.fire(S)
	h.fire(E)
	h.fire(C)
	ok(h.speaks.size() == 2 and _count("seq") == 1, "cancel of chunk 2 -> no retry, speech ends")
	# cancel after the first chunk started (interrupted) is not a retry either
	var k := _new_fake()
	Tts._sys_get().start_timeout_sec = 5.0
	Tts.speak("Hello there.", "en")
	k.fire(S)
	k.fire(C)
	ok(k.speaks.size() == 1 and _count("seq") == 1, "cancel after START -> no retry, speech ends")


# ---------------------------------------------------------------- no reaction for the timeout

func _test_watchdog() -> void:
	print("[no reaction -> one retry]")
	var f := _new_fake()
	Tts._sys_get().start_timeout_sec = 0.2
	Tts.speak("Hello there.", "en")
	await get_tree().create_timer(0.1).timeout
	ok(f.speaks.size() == 1, "no retry before the timeout")
	await get_tree().create_timer(0.2).timeout
	ok(f.speaks.size() == 2, "silence for the timeout -> exactly one retry")
	var mv := f.moves()
	ok(mv.size() >= 4 and mv[mv.size() - 2] == "stop" and mv[mv.size() - 1] == "speak", "queued copy dropped (stop) right before the retry's speak")
	await get_tree().create_timer(0.5).timeout
	ok(f.speaks.size() == 2 and _count("seq") == 1 and not Tts.busy, "still silent -> gives up after the retry (no third speak, sequence_finished once)")
	f.fire(S, int(f.speaks[0]["id"]))
	ok(_count("chunk") == 0, "late START of an abandoned utterance ignored")
	# the retry answers in time
	var g := _new_fake()
	Tts._sys_get().start_timeout_sec = 0.2
	Tts.speak("Hello there.", "en")
	await get_tree().create_timer(0.3).timeout
	g.fire(S)
	await get_tree().create_timer(0.4).timeout
	ok(g.speaks.size() == 2 and Tts.playing and _count("seq") == 0, "START after the retry keeps the speech running (watchdog stays quiet)")
	g.fire(E)
	ok(_count("seq") == 1, "speech finishes")


# ---------------------------------------------------------------- rate, language, odds and ends

func _test_misc() -> void:
	print("[rate / language / misc]")
	var f := _new_fake()
	Store.prefs["tts_engine"] = "system"
	Store.prefs["tts_speed"] = 1.2
	Tts.speak("Fast one.", "en")
	ok(is_equal_approx(float(f.speaks[0]["rate"]), 1.2), "normal speed = tts_speed pref -> rate 1.2")
	Tts.stop()
	Tts.speak("Slow one.", "en", true)
	ok(is_equal_approx(float(f.speaks[1]["rate"]), Tts.SLOW_SPEED), "slow -> rate SLOW_SPEED (0.75)")
	Tts.stop()
	Store.prefs["tts_speed"] = 9.0
	ok(is_equal_approx(Tts.normal_speed(), 1.3), "tts_speed is still clamped to 1.3")
	Store.prefs.erase("tts_speed")
	Tts.speak("   ", "en")
	ok(f.speaks.size() == 2, "blank text speaks nothing")
	Tts.speak("こんにちは。", "ja")
	ok(f.speaks.size() == 3 and f.speaks[2]["voice"] == "ja-jp-a" and f.speaks[2]["text"] == "こんにちは。", "Japanese text spoken with the Japanese voice")
	Tts.stop()
	Tts.speak("Preview.", "en", false, "en-us-b")
	ok(f.speaks[f.speaks.size() - 1]["voice"] == "en-us-b", "speak(..., voice) preview uses that system voice")
	Tts.stop()
	Tts.speak("Preview.", "en", false, "af_heart")
	ok(f.speaks[f.speaks.size() - 1]["voice"] == "en-us-a", "a PC voice id (af_heart) passed as preview falls back to a system voice")
	Tts.stop()
	Tts.speak_chunks(["Ready.", "", "Go."], "en")
	f.fire(S)
	f.fire(E)
	ok(f.speaks[f.speaks.size() - 1]["text"] == "Go.", "speak_chunks skips blank chunks")
	f.fire(S)
	f.fire(E)
	ok(Tts.voice_for("en") == "en-us-a" and Tts.voice_for("ja") == "ja-jp-a", "voice_for returns the system voice ids")
	# the PC path is untouched when the engine is pc
	Store.prefs["tts_engine"] = "pc"
	ok(Tts.engine_now() == "pc" and Tts.voice_for("en") == "af_heart", "tts_engine=pc -> PC voice again")
	var before := f.speaks.size()
	var hook_calls := [0]
	Tts.fetch_hook = func(_t: String, _l: String, _s: float, _v: String) -> AudioStreamWAV:
		hook_calls[0] += 1
		return WavUtil.silence(0.1, 24000)
	await Tts.speak_chunks(["Only PC."], "en")
	ok(hook_calls[0] == 1 and f.speaks.size() == before, "tts_engine=pc: the PC fetch path runs, the system engine is not used")
	Tts.stop()
	Tts.fetch_hook = Callable()
	Store.prefs["tts_engine"] = "system"


# ---------------------------------------------------------------- voices for the settings screen

func _test_voice_list() -> void:
	print("[voice list]")
	var f := _new_fake()
	Store.prefs["tts_engine"] = "system"
	Tts.voices = {}
	Tts._voices_engine = ""
	var loaded := [0]
	var cb := func() -> void: loaded[0] += 1
	Tts.voices_loaded.connect(cb)
	await Tts.load_voices()
	Tts.voices_loaded.disconnect(cb)
	ok(loaded[0] == 1 and not Tts.voices.is_empty(), "load_voices() on the system engine fills voices and emits voices_loaded")
	var en: Array = Tts.voices_for("en")
	var ids: Array = en.map(func(v: Dictionary) -> String: return str(v["id"]))
	ok(ids == ["en-us-a", "en-us-b"], "voices_for('en') lists only English system voices: %s" % str(ids))
	var v0: Dictionary = en[0]
	ok(v0.has("id") and v0.has("name") and v0.has("gender") and v0.has("default") and v0["gender"] == "", "entry shape {id,name,gender:'',default}")
	ok(en.filter(func(v: Dictionary) -> bool: return bool(v["default"])).size() == 1 and bool(en[0]["default"]), "exactly one default voice (the one that would be used)")
	var lbl := Tts.voice_label(v0)
	ok(lbl.find("남성") < 0 and lbl.find("여성") < 0 and lbl.begins_with("English US A"), "voice_label without gender: '%s'" % lbl)
	ok(Tts.voice_label({"id": "af_heart", "name": "Heart", "gender": "female", "default": false}) == "Heart · 여성", "voice_label keeps the PC gender text")
	ok(Tts.voice_label({"id": "am_x", "name": "X", "gender": "male", "default": true}) == "X · 남성 (기본)", "voice_label male + default unchanged")
	f.voices = []
	var none: Array = Tts.voices_for("en")
	ok(none.size() == 1 and none[0]["id"] == "", "no voices at all -> one placeholder entry (drop-down never empty)")
	Tts.voices = {}
	Tts._voices_engine = ""
