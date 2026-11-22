extends Node
## LocalStt + SttEngine (docs/v201_design.md 2.3, 5.4 PA4-1..PA4-19; D-1 in 8.1) with a FAKE bridge (no model, no native library).
##   Godot ... res://tests/local_stt_test.tscn [-- --phone] [--real-model=<ggml bin> --real-wav=<wav>]
## Last line: "== local_stt_test result: N passed, M failed ==", exit code 1 = failure.
## The fake bridge counts every call that happens on the main thread (SttEngine.main_thread_calls must stay 0), blocks for as long
## as a test asks (real milliseconds), and can ignore abort() to show that a late result is dropped. The clock of LocalStt / SttEngine
## is a fake (`_clock_t`), so the time-outs (12 s) and the idle unload (90 s) are tested without waiting.
## No file outside user://test_local_stt/ is written. This test prints no recognised text and no target (ZZ_TGT_4417 is a marker the
## leak checks look for in memory; it is never printed).

const DIR := "user://test_local_stt"
const BASE := "whisper-base.en-q5_1"
const TINY := "whisper-tiny.en-q5_1"
const TARGET := "The cat sat on the mat."
const TEXT := "the cat sat on the mat"
const MARK := "ZZ_TGT_4417"
const NO_VOICE_TIP := "목소리가 들리지 않았어요. 마이크를 확인하고 조금 더 크게 말해 보세요."

var passed: int = 0
var failed: int = 0
var LS: GDScript = null
var _clock_t: float = 1000.0
var _cap: LogCap = null
var _old_prefs: String = ""
var _old_manifest: String = ""
var _old_base_dir: String = ""
var _old_mode: String = ""
var _wavs: Dictionary = {}
var _real_model: String = ""
var _real_wav: String = ""


# ================================================================================================ the fake bridge
class Fake:
	extends RefCounted
	var mu := Mutex.new()
	var order: Array = []
	var load_calls: int = 0
	var unload_calls: int = 0
	var transcribe_calls: int = 0
	var abort_calls: int = 0
	var abort_gen: int = 0
	var load_delay_ms: int = 0
	var unload_delay_ms: int = 0
	var tr_delay_ms: int = 0
	var hang_count: int = 0 ## the next N transcribe calls block until aborted / released
	var release: bool = false
	var max_hang_ms: int = 20000
	var ignore_abort: bool = false
	var fail_load: bool = false
	var mode: String = "normal" ## normal | error | null | no_words | words_missing | raw | bad_wav
	var raw_result: Variant = null
	var words: Array = []
	var text: String = TEXT
	var duration: float = 2.0
	var ms: int = 120
	var rec_opts: Dictionary = {}
	var rec_wav_size: int = 0
	var rec_wav_data: int = 0
	var rec_riff: int = 0
	var loaded_path: String = ""
	var ver: String = "bridge 1 / whisper.cpp test +abort-sched"

	func _init() -> void:
		words = [
			{"w": "The", "p": 0.9, "start": 0.10, "end": 0.35}, {"w": "cat", "p": 0.8, "start": 0.40, "end": 0.70},
			{"w": "sat", "p": 0.7, "start": 0.75, "end": 1.00}, {"w": "on", "p": 0.85, "start": 1.05, "end": 1.20},
			{"w": "the", "p": 0.6, "start": 1.25, "end": 1.40}, {"w": "mat", "p": 0.95, "start": 1.45, "end": 1.90}]

	func _note(ev: String) -> void:
		mu.lock()
		order.append(ev)
		mu.unlock()

	func events() -> Array:
		mu.lock()
		var c: Array = order.duplicate()
		mu.unlock()
		return c

	func _main_check() -> void:
		if OS.get_thread_caller_id() == OS.get_main_thread_id():
			SttEngine.main_thread_calls += 1

	func version() -> String:
		return ver

	func memory_info() -> Dictionary:
		return {"peak_kb": 310000, "rss_kb": 150000 + (60000 * load_calls if loaded_path != "" else 0)}

	func is_loaded() -> bool:
		return loaded_path != ""

	func model_file() -> String:
		return loaded_path.get_file()

	func load_model(path: String, _threads: int = 0) -> int:
		_main_check()
		load_calls += 1
		_note("load")
		_sleep(load_delay_ms)
		if fail_load:
			return ERR_FILE_CORRUPT
		loaded_path = path
		return OK

	func unload() -> void:
		_main_check()
		unload_calls += 1
		_sleep(unload_delay_ms)
		loaded_path = ""
		_note("unload")

	func abort() -> void:
		abort_calls += 1
		abort_gen += 1

	func _sleep(msec: int) -> void:
		var t0: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < msec:
			OS.delay_msec(2)

	func transcribe(wav: PackedByteArray, lang: String, opts: Dictionary = {}) -> Variant:
		_main_check()
		transcribe_calls += 1
		rec_opts = opts.duplicate()
		rec_wav_size = wav.size()
		rec_riff = wav.decode_u32(4) if wav.size() >= 8 else -1
		rec_wav_data = wav.decode_u32(40) if wav.size() >= 44 else -1
		var gen0: int = abort_gen
		var t0: int = Time.get_ticks_msec()
		_note("t_start")
		if hang_count > 0:
			hang_count -= 1
			while not release and (ignore_abort or abort_gen == gen0) and Time.get_ticks_msec() - t0 < max_hang_ms:
				OS.delay_msec(2)
		else:
			while Time.get_ticks_msec() - t0 < tr_delay_ms and (ignore_abort or abort_gen == gen0):
				OS.delay_msec(2)
		_note("t_end")
		if abort_gen != gen0 and not ignore_abort:
			return {"ok": false, "error": "aborted", "text": "", "words": [], "duration": duration, "ms": 1, "model": "fake"}
		if lang != "en":
			return {"ok": false, "error": "bad_lang"}
		match mode:
			"error":
				return {"ok": false, "error": "engine", "text": "", "words": [], "duration": duration, "ms": 1, "model": "fake"}
			"bad_wav":
				return {"ok": false, "error": "bad_wav", "text": "", "words": [], "duration": 0.0, "ms": 1, "model": "fake"}
			"null":
				return null
			"raw":
				return raw_result
			"no_words":
				return {"ok": true, "error": "", "text": "", "words": [], "duration": duration, "ms": ms, "model": "fake"}
			"words_missing":
				return {"ok": true, "error": "", "text": text, "duration": duration, "ms": ms, "model": "fake"}
		return {"ok": true, "error": "", "text": text, "words": words.duplicate(true), "duration": duration, "ms": ms, "model": "fake"}


# ================================================================================================ logger, checks, helpers
class LogCap:
	extends Logger
	var lines: Array = []
	var mu := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		lines.append("%s %s:%d %s %s" % [function, file, line, code, rationale])
		mu.unlock()

	func count() -> int:
		mu.lock()
		var n: int = lines.size()
		mu.unlock()
		return n

	func snapshot() -> Array:
		mu.lock()
		var c: Array = lines.duplicate()
		mu.unlock()
		return c


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _until(cond: Callable, max_sec: float = 10.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(max_sec * 1000.0):
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _write(path: String, txt: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(txt)
	f.close()


func _rm_rf(path: String) -> void:
	var gp: String = _g(path)
	var d := DirAccess.open(gp)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(gp.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(gp)


## A mono PCM16 WAV of a quiet tone (amp 0 = silence). `streamed` writes 0xFFFFFFFF as the data size.
func _wav(sec: float, rate: int = 16000, amp: float = 0.3, streamed: bool = false) -> PackedByteArray:
	var n: int = int(sec * float(rate))
	var out := PackedByteArray()
	out.resize(44 + n * 2)
	out.encode_u32(0, 0x46464952)
	out.encode_u32(4, 36 + n * 2)
	out.encode_u32(8, 0x45564157)
	out.encode_u32(12, 0x20746D66)
	out.encode_u32(16, 16)
	out.encode_u16(20, 1)
	out.encode_u16(22, 1)
	out.encode_u32(24, rate)
	out.encode_u32(28, rate * 2)
	out.encode_u16(32, 2)
	out.encode_u16(34, 16)
	out.encode_u32(36, 0x61746164)
	out.encode_u32(40, 0xFFFFFFFF if streamed else n * 2)
	var a: int = int(amp * 32767.0)
	for i in n:
		out.encode_s16(44 + i * 2, int(sin(float(i) * 0.05) * float(a)))
	return out


func _wav_of(key: String, sec: float, rate: int = 16000, amp: float = 0.3) -> PackedByteArray:
	if not _wavs.has(key):
		_wavs[key] = _wav(sec, rate, amp)
	return _wavs[key]


func _body(target: String, wav: PackedByteArray) -> Dictionary:
	return {"lang": "en", "target": target, "audio_b64": Marshalls.raw_to_base64(wav)}


func _score(fake_wav: PackedByteArray = PackedByteArray(), target: String = TARGET) -> Dictionary:
	var w: PackedByteArray = fake_wav if not fake_wav.is_empty() else _wav_of("2s", 2.0)
	return await LS.handle("POST", "/score", {}, _body(target, w))


func _spawn(path: String, body: Dictionary) -> Dictionary:
	var h := {"done": false, "res": {}}
	_run_into(h, path, body)
	return h


func _run_into(h: Dictionary, path: String, body: Dictionary) -> void:
	h["res"] = await LS.handle("POST", path, {}, body)
	h["done"] = true


func _leaks(s: String) -> bool:
	return s.contains(MARK)


func _strip_via(d: Dictionary) -> Dictionary:
	var c: Dictionary = d.duplicate(true)
	c.erase("via")
	c.erase("degraded")
	return c


func _ids() -> Array:
	return [BASE, TINY]


func _make_ready(id: String) -> void:
	var m: Dictionary = ModelStore.model(id)
	var dir: String = _g(DIR + "/store")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join(str(m["file"])), FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0x41]).duplicate())
	var pad := PackedByteArray()
	pad.resize(int(m["bytes"]) - 1)
	f.store_buffer(pad)
	f.close()
	_write(dir.path_join(str(m["file"]) + ".ok"), JSON.stringify({"v": 1, "sha256": str(m["sha256"]), "bytes": int(m["bytes"])}))


func _set_model(state: String) -> void:
	for id in _ids():
		ModelStore.remove(id)
	if state == "missing":
		return
	for id in _ids():
		_make_ready(id)
	if state == "corrupt":
		ModelStore.mark_corrupt(BASE)


func _use_params(variant: Dictionary, good: Dictionary) -> void:
	var path: String = DIR + "/p.json"
	var kind: String = str(variant.get("kind", "patch"))
	if kind == "absent":
		DirAccess.remove_absolute(_g(path))
	elif kind == "raw":
		_write(path, str(variant.get("text", "")))
	else:
		var d: Dictionary = good.duplicate(true)
		var st: Dictionary = variant.get("set", {})
		for k in st.keys():
			d[k] = st[k]
		for k in variant.get("remove", []):
			d.erase(k)
		_write(path, JSON.stringify(d))
	LS.params_path_override = path


func _params_good() -> Dictionary:
	var f := FileAccess.open("res://tests/fixtures/score_params_test.json", FileAccess.READ)
	var j := JSON.new()
	var parsed: bool = f != null and j.parse(f.get_as_text()) == OK
	return j.data if parsed and j.data is Dictionary else {}


## Fresh state for a test: no engine, a new fake bridge, the fake clock at 1000 s, models ready, no params file, phone scoring on.
func _setup(fake: Fake, fake_clock: bool = true) -> void:
	LS.reset_for_tests()
	await _frames(3)
	LS.bridge_factory = func() -> Object: return fake
	if fake_clock:
		_clock_t = 1000.0
		LS.clock = func() -> float: return _clock_t
	LS.params_path_override = DIR + "/absent.json"
	DirAccess.remove_absolute(_g(DIR + "/p.json"))
	Store.set_pref("stt_phone_off", false)
	ModelStore.set_active(BASE)
	_set_model("ready")
	SttEngine.main_thread_calls = 0


func _ready() -> void:
	print("== local_stt_test start ==")
	_cap = LogCap.new()
	OS.add_logger(_cap)
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s.begins_with("--real-model="):
			_real_model = s.substr(13)
		elif s.begins_with("--real-wav="):
			_real_wav = s.substr(11)
	ok(Store.test_guard_on, "test guard is on")
	LS = load("res://scripts/local/local_stt.gd")
	ok(LS != null, "local_stt.gd loads")
	_old_prefs = Store.prefs_path
	_old_manifest = ModelStore.manifest_path
	_old_base_dir = ModelStore.base_dir
	_old_mode = Route.mode
	_rm_rf(DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.prefs = {}
	_write_manifest()
	ModelStore.manifest_path = DIR + "/manifest.json"
	ModelStore.base_dir = DIR + "/store/"
	Route.phone_hook = func() -> bool: return true
	Route.pc_ready_hook = func() -> bool: return false
	Route.mode = "auto"

	_selfchecks()
	_static_checks()
	_tidy_cases()
	await _availability()
	await _params()
	await _parity()
	await _input_defense()
	await _lifecycle()
	await _nonblocking()
	await _network()
	await _bad_bridge()
	await _timeouts()
	await _async_engine()
	await _engine_race()
	await _patch_marker()
	await _auto_off()
	await _bench()
	await _leak_checks()
	await _real_run()
	_source_checks()
	await _finish()


func _finish() -> void:
	LS.reset_for_tests()
	await _frames(3)
	ok(SttEngine.peek() == null, "no engine node is left after reset_for_tests")
	ok(get_tree().root.get_node_or_null("SttEngine") == null, "no SttEngine node below the root")
	if _cap != null:
		OS.remove_logger(_cap)
		ok(_cap.count() == 0, "no engine ERROR line during the run (%d)" % _cap.count())
		for l in _cap.snapshot().slice(0, 5):
			print("engine error: ", l)
	Route.phone_hook = Callable()
	Route.pc_ready_hook = Callable()
	Route.mode = _old_mode
	ModelStore.manifest_path = _old_manifest
	ModelStore.base_dir = _old_base_dir
	Store.prefs_path = _old_prefs
	_rm_rf(DIR)
	print("== local_stt_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _write_manifest() -> void:
	var f := FileAccess.open("res://data/models.json", FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	for m in (d["models"] as Array):
		(m as Dictionary)["bytes"] = 1000 if str((m as Dictionary)["id"]) == BASE else 800
	_write(DIR + "/manifest.json", JSON.stringify(d))


# ================================================================================================ self-checks of the checkers
func _selfchecks() -> void:
	# 1) the main-thread counter really goes up when a fake bridge function is called on the main thread
	var fk := Fake.new()
	var before: int = SttEngine.main_thread_calls
	fk.load_model("x")
	fk.transcribe(PackedByteArray(), "en", {})
	fk.unload()
	var detected: bool = SttEngine.main_thread_calls == before + 3
	SttEngine.main_thread_calls = before
	print("selfcheck FAIL-as-expected main_thread")
	ok(detected, "selfcheck FAIL-as-expected main_thread (a direct call from the main thread is counted)")
	# 2) the leak checker sees the marker in a memory string and not in a clean one
	print("selfcheck FAIL-as-expected leak")
	ok(_leaks("some " + MARK + " text") and not _leaks("some clean text"), "selfcheck FAIL-as-expected leak (the checker sees the marker)")
	# 3) raw times are not the cleaned ones (a missing rule would differ)
	var raw: Array = [{"w": "a", "p": 0.5, "start": 0.5, "end": 1.0}, {"w": "b", "p": 0.5, "start": 0.2, "end": 0.4}]
	var cleaned: Array = LS.tidy_words(raw, 2.0)
	ok(float(cleaned[1]["start"]) != 0.2 and float(cleaned[0]["end"]) != 1.0, "selfcheck FAIL-as-expected tidy (raw times are not accepted as they are)")
	# 4) the source scanners find a log line that prints a target / a network class
	print("selfcheck FAIL-as-expected log_scan")
	ok(_log_hits(['\tprint("x", target)']) == 1 and _log_hits(['\tprint("stt_ms=", ms)']) == 0, "selfcheck FAIL-as-expected log_scan (a print of the target is found)")
	ok(_net_hits(["var r := HTTP" + "Request.new()"]) == 1 and _net_hits(["var x := 1"]) == 0, "selfcheck FAIL-as-expected net_scan (a network class is found)")
	# 5) a params file that is broken is not taken (see _params for all variants); here the checker side: valid_p_map says no
	ok(not ScoreCore.valid_p_map([[0.0, 0.0], [0.5, 0.8], [0.7, 0.3], [1.0, 1.0]]), "selfcheck FAIL-as-expected p_map (a non-monotone map is refused by ScoreCore)")


func _log_hits(lines: Array) -> int:
	var rx := RegEx.create_from_string("(print|push_warning|push_error|printerr)\\(.*(text|target|transcript|words|url|path)")
	var n: int = 0
	for l in lines:
		if rx.search(String(l)) != null:
			n += 1
	return n


func _net_hits(lines: Array) -> int:
	var n: int = 0
	for l in lines:
		for w in ["HTTP" + "Request", "HTTP" + "Client", "shell_" + "open", "request_" + "permission"]:
			if String(l).contains(w):
				n += 1
	return n


# ================================================================================================ constants and wiring
func _static_checks() -> void:
	ok(is_equal_approx(float(LS.STT_TIMEOUT_SEC), 12.0), "STT_TIMEOUT_SEC is 12")
	ok(is_equal_approx(float(LS.IDLE_UNLOAD_SEC), 90.0), "IDLE_UNLOAD_SEC is 90")
	ok(is_equal_approx(float(LS.MAX_AUDIO_SEC), 30.0), "MAX_AUDIO_SEC is 30")
	ok(str(LS.PARAMS_PATH) == "res://data/score_params.json", "PARAMS_PATH")
	ok(str(LocalApi.HANDLERS.get("stt", "")) == "res://scripts/local/local_stt.gd" and ResourceLoader.exists("res://scripts/local/local_stt.gd"), "LocalApi finds the handler by its path")
	for fn in ["handle", "is_available", "unavailable_reason", "is_available_for", "unavailable_reason_for", "warm", "params", "stats", "bench", "reset_for_tests", "tidy_words"]:
		ok(LS.has_method(fn), "LocalStt has " + fn)
	var stt_src: String = FileAccess.get_file_as_string("res://scripts/local/local_stt.gd")
	ok(not stt_src.begins_with("class_name") and not stt_src.contains("
class_name"), "local_stt.gd has no class_name line")
	for d in ["phoneme_off", "score_uncalibrated", "stt_tiny_model"]:
		ok(Route.DEGRADED.has(d), "Route.DEGRADED knows " + d)
	for c in ["engine_error", "stt_timeout", "model_missing", "model_corrupt", "engine_missing"]:
		ok(Route.ERR_TEXT.has(c), "Route.ERR_TEXT knows " + c)


# ================================================================================================ D-1 word times
func _wd(pairs: Array) -> Array:
	var out: Array = []
	for i in pairs.size():
		out.append({"w": "w%d" % i, "p": 0.5 + float(i) / 100.0, "start": pairs[i][0], "end": pairs[i][1]})
	return out


func _times(words: Array) -> Array:
	var t: Array = []
	for w in words:
		t.append([float(w["start"]), float(w["end"])])
	return t


func _tidy_cases() -> void:
	# The same cases as phone_src/tools/test_calib_fit.py WordTimes.test_rule_cases (D-1, docs/v201_design.md 8.1).
	var nan: float = NAN
	var inf: float = INF
	var cases: Array = [
		["1 not finite -> 0", [[nan, 1.0], [0.5, inf]], 3.0, [[0.0, 0.5], [0.5, 0.5]]],
		["2 cut to [0, clip]", [[-1.0, 5.0]], 3.0, [[0.0, 3.0]]],
		["3 start never goes back; end never before start; end <= next start", [[0.5, 1.0], [0.2, 0.4]], 2.0, [[0.5, 0.5], [0.5, 0.5]]],
		["5 end cut to the next start", [[0.0, 1.0], [0.6, 1.5]], 3.0, [[0.0, 0.6], [0.6, 1.5]]],
		["the real case: whisper.cpp spreads over 30 s, the clip is 2.075 s", [[0.07, 5.52], [5.52, 9.62], [9.62, 15.07]], 2.075,
			[[0.07, 2.075], [2.075, 2.075], [2.075, 2.075]]],
		["6 no rounding", [[0.123456789, 0.987654321]], 5.0, [[0.123456789, 0.987654321]]],
		["fine input stays", [[0.0, 0.4], [0.45, 0.85], [0.9, 1.3]], 2.0, [[0.0, 0.4], [0.45, 0.85], [0.9, 1.3]]],
		["clip length 0", [[0.1, 0.2]], 0.0, [[0.0, 0.0]]],
		["empty", [], 1.0, []],
		["negative clip counts as 0", [[0.1, 0.2]], -3.0, [[0.0, 0.0]]],
	]
	for c in cases:
		var out: Array = LS.tidy_words(_wd(c[1]), float(c[2]))
		ok(_times(out) == c[3], "D-1: " + str(c[0]))
	# None / text count as not finite
	var odd: Array = [{"w": "a", "p": 0.5, "start": null, "end": "x"}, {"w": "b", "p": 0.5, "start": 0.3, "end": 0.6}]
	ok(_times(LS.tidy_words(odd, 1.0)) == [[0.0, 0.0], [0.3, 0.6]], "D-1: null and text times count as not finite")
	# order, count, w and p stay; the input is not changed
	var ws: Array = _wd([[0.5, 1.0], [0.2, 0.4], [9.0, 12.0]])
	var before: String = JSON.stringify(ws)
	var out2: Array = LS.tidy_words(ws, 2.0)
	ok(JSON.stringify(ws) == before, "D-1: the input list is not changed")
	var same: bool = out2.size() == ws.size()
	for i in out2.size():
		same = same and out2[i]["w"] == ws[i]["w"] and is_equal_approx(float(out2[i]["p"]), float(ws[i]["p"]))
	ok(same, "D-1: order, count, w and p stay")
	var sorted_ok: bool = true
	var inside: bool = true
	for i in out2.size():
		sorted_ok = sorted_ok and (i == 0 or float(out2[i]["start"]) >= float(out2[i - 1]["start"]))
		inside = inside and 0.0 <= float(out2[i]["start"]) and float(out2[i]["start"]) <= float(out2[i]["end"]) and float(out2[i]["end"]) <= 2.0
	ok(sorted_ok and inside, "D-1: starts do not go back and every time is inside [0, clip]")
	var mixed: Array = LS.tidy_words([{"w": "a", "p": 0.1, "start": 0.1, "end": 0.2}, 7, "x", null, {"w": "b", "p": 0.2, "start": 0.3, "end": 0.4}], 1.0)
	ok(mixed.size() == 2, "D-1: an entry that is no dictionary is no word")


# ================================================================================================ PA4-2 availability
func _availability() -> void:
	var fake := Fake.new()
	var combos: int = 0
	for state in ["ready", "missing", "corrupt"]:
		for present in [true, false]:
			for lang in ["en", "ja"]:
				for path in ["/stt", "/score"]:
					await _setup(fake)
					_set_model(state)
					if present:
						LS.bridge_factory = func() -> Object: return fake
					else:
						LS.bridge_factory = func() -> Object: return null
					var body: Dictionary = {"lang": lang, "target": TARGET}
					var want: String = ""
					if lang != "en":
						want = "not_on_phone"
					elif not present:
						want = "engine_missing"
					elif state == "corrupt":
						want = "model_corrupt"
					elif state == "missing":
						want = "model_missing"
					var r: Dictionary = LS.unavailable_reason_for(path, {}, body)
					var good: bool = bool(LS.is_available_for(path, {}, body)) == (want == "") and str(r.get("err_code", "x")) == want
					if want != "":
						good = good and str(r.get("text_ko", "")) == Route.text_for(want)
					ok(good, "available %s / bridge %s / %s / %s -> '%s'" % [state, present, lang, path, want])
					combos += 1
	ok(combos == 24, "the availability table has 24 rows")
	await _setup(fake)
	ok(bool(LS.is_available()) and str(LS.unavailable_reason().get("err_code", "x")) == "", "is_available / unavailable_reason without a request: ready + bridge")
	ok(bool(LS.is_available_for("/score", {}, {"target": "hi"})), "a body without lang is English")
	ok(not bool(LS.is_available_for("/score", {}, {"lang": "fr"})) and not bool(LS.is_available_for("/score", {}, {"lang": 5})), "another or odd lang is not served")
	ok(str(LS.unavailable_reason_for("/chat", {}, {"lang": "en"}).get("err_code", "")) == "not_on_phone", "another path is not_on_phone")
	ok(bool(LocalApi.available("POST", "/score", {"lang": "en", "target": "hi"})) and bool(LocalApi.available("POST", "/stt", {"lang": "en"})), "LocalApi.available agrees (ready)")
	_set_model("missing")
	ok(not bool(LocalApi.available("POST", "/score", {"lang": "en", "target": "hi"})), "LocalApi.available agrees (missing)")
	ok(str(LocalApi.why_none("POST", "/score", {"lang": "en"}).get("err_code", "")) == "model_missing", "LocalApi.why_none says model_missing")
	var h: Dictionary = LocalApi.health()
	ok(not bool(h["stt"]) and not bool(h["score"]), "the synthetic /health says stt false while the model is missing")
	_set_model("ready")
	h = LocalApi.health()
	ok(bool(h["stt"]) and bool(h["score"]), "the synthetic /health says stt true with a ready model")


# ================================================================================================ PA4-3 params
func _params() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var fx: Dictionary = _params_good()
	ok(fx.has("good") and fx.has("variants") and (fx["variants"] as Array).size() >= 12, "the params fixture is there with >= 12 variants")
	var bad_n: int = 0
	for v in (fx["variants"] as Array):
		var vd: Dictionary = v
		_use_params(vd, fx["good"])
		var p: Dictionary = LS.params()
		var want_valid: bool = bool(vd["valid"])
		var good: bool
		if want_valid:
			good = bool(p["calibrated"]) and not bool(p["degraded"]) and str(p["state"]) == "calibrated"
		else:
			bad_n += 1
			good = (not bool(p["calibrated"])) and bool(p["degraded"]) and str(p["state"]) == "uncalibrated" \
				and is_equal_approx(float(p["ok_prob"]), 0.45) and int(p["beam"]) == 1 \
				and is_equal_approx(float(ScoreCore.map_p(0.3, p["p_map"])), 0.3) and ScoreCore.map_final(37, p["final_map"]) == 37
		ok(good, "params variant: " + str(vd["name"]))
	ok(bad_n >= 9, "at least 9 bad params variants were tried (%d)" % bad_n)
	# the good file's values
	_use_params({"name": "good"}, fx["good"])
	var g: Dictionary = LS.params()
	ok(is_equal_approx(float(g["ok_prob"]), 0.5) and int(g["beam"]) == 2 and g["p_map"] == fx["good"]["p_map"] and g["final_map"] == fx["good"]["final_map"], "the good file gives its ok_prob, beam, p_map and final_map")
	# a bad file through handle(): identity + degraded
	_use_params({"name": "bad", "set": {"v": 2}}, fx["good"])
	var r: Dictionary = await _score()
	ok(bool(r["ok"]) and (r["data"]["degraded"] as Array).has("score_uncalibrated"), "a bad params file: /score still works and says score_uncalibrated")
	# tiny model: always score_uncalibrated + stt_tiny_model
	_use_params({"name": "good"}, fx["good"])
	ModelStore.set_active(TINY)
	var tp: Dictionary = LS.params()
	ok(bool(tp["tiny"]) and bool(tp["degraded"]) and is_equal_approx(float(tp["ok_prob"]), 0.45), "a tiny model is always uncalibrated")
	var rt: Dictionary = await _score()
	var dg: Array = rt["data"]["degraded"] if bool(rt["ok"]) else []
	ok(dg.has("score_uncalibrated") and dg.has("stt_tiny_model") and dg.has("phoneme_off"), "tiny: degraded has phoneme_off, score_uncalibrated and stt_tiny_model")
	ModelStore.set_active(BASE)
	var rb: Dictionary = await _score()
	ok(bool(rb["ok"]) and not (rb["data"]["degraded"] as Array).has("stt_tiny_model") and not (rb["data"]["degraded"] as Array).has("score_uncalibrated"), "base + good file: no stt_tiny_model, no score_uncalibrated")
	ok(str(LS.stats()["params_state"]) == "calibrated" and int(LS.stats()["beam"]) == 2, "stats() shows params_state and beam")


# ================================================================================================ PA4-3 / 4 / 16 parity and answer keys
func _expected_score(fake: Fake, target: String, params: Dictionary, clip: float) -> Dictionary:
	var mapped: Array = []
	for w in fake.words:
		mapped.append({"w": w["w"], "p": ScoreCore.map_p(float(w["p"]), params["p_map"]), "start": w["start"], "end": w["end"]})
	var words: Array = LS.tidy_words(mapped, clip)
	var res: Dictionary = ScoreCore.score_en(target, words, fake.text, float(params["ok_prob"]))
	res["score"] = ScoreCore.map_final(int(res["score"]), params["final_map"])
	return res


func _parity() -> void:
	var fake := Fake.new()
	await _setup(fake)
	# identity (no params file): the same as ScoreCore.score_en on the same words
	var r: Dictionary = await _score()
	var ident: Dictionary = LS.params()
	var want: Dictionary = _expected_score(fake, TARGET, ident, 2.0)
	ok(bool(r["ok"]) and _strip_via(r["data"]) == want, "PA4-3: /score with the identity map = ScoreCore.score_en on the same words")
	ok(int(r["code"]) == 200 and str(r["data"]["via"]) == "phone", "/score answer has code 200 and via phone")
	var keys: Array = (r["data"] as Dictionary).keys()
	keys.sort()
	ok(keys == ["accuracy", "clarity", "degraded", "fluency", "score", "tips_ko", "transcript", "units", "via"], "PA4-4: /score keys")
	ok(r["data"]["degraded"] == ["phoneme_off", "score_uncalibrated"], "PA4-4: /score degraded is phoneme_off + score_uncalibrated")
	ok(int(fake.rec_opts.get("beam", 0)) == 1 and is_equal_approx(float(fake.rec_opts.get("max_seconds", 0.0)), 30.0), "the bridge got beam 1 and max_seconds 30")
	var u0: Dictionary = r["data"]["units"][0]
	ok(u0.has("t") and u0.has("ok") and u0.has("conf") and u0.has("heard"), "units carry t, ok, conf, heard")
	# /stt
	var rs: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	var sk: Array = (rs["data"] as Dictionary).keys()
	sk.sort()
	ok(bool(rs["ok"]) and sk == ["degraded", "duration", "text", "via", "words"], "PA4-4: /stt keys are text, words, duration, via, degraded")
	ok(str(rs["data"]["text"]) == TEXT and (rs["data"]["words"] as Array).size() == 6 and is_equal_approx(float(rs["data"]["duration"]), 2.0), "/stt returns the text, 6 words and the duration")
	ok(str(rs["data"]["via"]) == "phone" and rs["data"]["degraded"].has("phoneme_off"), "/stt: via phone, phoneme_off")
	var w0: Dictionary = rs["data"]["words"][0]
	ok(w0.has("w") and w0.has("p") and w0.has("start") and w0.has("end"), "/stt words carry w, p, start, end")
	# calibrated file: p mapped, ok_prob 0.5, beam 2, final_map
	var fx: Dictionary = _params_good()
	_use_params({"name": "good"}, fx["good"])
	var cal: Dictionary = LS.params()
	var r2: Dictionary = await _score()
	var want2: Dictionary = _expected_score(fake, TARGET, cal, 2.0)
	ok(bool(r2["ok"]) and _strip_via(r2["data"]) == want2, "PA4-16: calibrated /score = map_p + ok_prob + map_final applied by hand")
	ok(int(fake.rec_opts.get("beam", 0)) == 2, "PA4-16: beam 2 in the file -> the bridge got options.beam == 2")
	ok(r2["data"]["degraded"] == ["phoneme_off"], "calibrated: degraded is only phoneme_off")
	# p 0.5 is mapped to 0.2 by [[0,0],[0.5,0.2],[1,1]]: a word at p 0.5 is not ok (0.2 < 0.5) while the raw 0.5 would be
	fake.words = [{"w": "The", "p": 0.5, "start": 0.1, "end": 0.3}]
	var rs2: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	ok(is_equal_approx(float(rs2["data"]["words"][0]["p"]), 0.2), "PA4-3: /stt p is the mapped value (0.5 -> 0.2)")
	var r3: Dictionary = await _score(PackedByteArray(), "The")
	ok(bool(r3["ok"]) and not bool(r3["data"]["units"][0]["ok"]) and is_equal_approx(float(r3["data"]["units"][0]["conf"]), 0.2), "PA4-3: the mapped p goes into score_en (conf 0.2, not ok)")
	# final_map: a node at the unmapped score S sends S -> 70
	fake.words = Fake.new().words
	var base_cal: Dictionary = cal.duplicate(true)
	base_cal["final_map"] = [[0, 0], [100, 100]]
	var s_raw: int = int(_expected_score(fake, TARGET, base_cal, 2.0)["score"])
	ok(s_raw > 0 and s_raw < 100, "the test sentence scores between 0 and 100 (%d)" % s_raw)
	var variant: Dictionary = {"name": "fm", "set": {"final_map": [[0, 0], [s_raw, 70], [100, 100]]}}
	_use_params(variant, fx["good"])
	var r4: Dictionary = await _score()
	ok(bool(r4["ok"]) and int(r4["data"]["score"]) == 70, "PA4-16: final_map [[0,0],[%d,70],[100,100]]: score %d -> 70" % [s_raw, s_raw])
	_use_params({"name": "nofm", "remove": ["final_map"]}, fx["good"])
	var r5: Dictionary = await _score()
	ok(bool(r5["ok"]) and int(r5["data"]["score"]) == s_raw, "without final_map the score stays %d" % s_raw)
	# the words of the answer have the D-1 times: the bridge spreads words beyond the clip
	fake.words = [{"w": "The", "p": 0.9, "start": 0.07, "end": 5.52}, {"w": "cat", "p": 0.9, "start": 5.52, "end": 9.62}]
	var rs3: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	var ww: Array = rs3["data"]["words"]
	ok(is_equal_approx(float(ww[0]["start"]), 0.07) and is_equal_approx(float(ww[0]["end"]), 2.0) and is_equal_approx(float(ww[1]["start"]), 2.0) and is_equal_approx(float(ww[1]["end"]), 2.0), "D-1 in the answer: times beyond the 2 s clip are cut to 2 s")
	# a different word list order and count are kept
	ok(ww[0]["w"] == "The" and ww[1]["w"] == "cat" and ww.size() == 2, "D-1 in the answer: order and count stay")


# ================================================================================================ PA4-5 input defense
func _input_defense() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var w2: PackedByteArray = _wav_of("2s", 2.0)
	var b64: String = Marshalls.raw_to_base64(w2)
	var cases: Array = [
		["empty audio_b64", {"lang": "en", "target": TARGET, "audio_b64": ""}, "녹음된 소리가 없어요. 다시 녹음해 주세요."],
		["audio_b64 missing", {"lang": "en", "target": TARGET}, "녹음된 소리가 없어요. 다시 녹음해 주세요."],
		["audio_b64 is blanks", {"lang": "en", "target": TARGET, "audio_b64": "  \n\t "}, "녹음된 소리가 없어요. 다시 녹음해 주세요."],
		["audio_b64 is a number", {"lang": "en", "target": TARGET, "audio_b64": 123}, "녹음된 소리가 없어요. 다시 녹음해 주세요."],
		["base64 with a bad character", {"lang": "en", "target": TARGET, "audio_b64": "QU!D"}, "오디오 데이터를 읽을 수 없어요."],
		["base64 of a bad length", {"lang": "en", "target": TARGET, "audio_b64": "QUJ"}, "오디오 데이터를 읽을 수 없어요."],
		["base64 with padding in the middle", {"lang": "en", "target": TARGET, "audio_b64": "QQ==QQ=="}, "오디오 데이터를 읽을 수 없어요."],
		["base64 only padding", {"lang": "en", "target": TARGET, "audio_b64": "===="}, "오디오 데이터를 읽을 수 없어요."],
		["base64 of text, not a WAV", {"lang": "en", "target": TARGET, "audio_b64": Marshalls.utf8_to_base64("this is not a wav file at all, only some text that is long enough to pass 44 bytes")}, "오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요."],
		["a RIFF header that is too short", {"lang": "en", "target": TARGET, "audio_b64": Marshalls.raw_to_base64(w2.slice(0, 30))}, "오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요."],
		["empty target", {"lang": "en", "target": "", "audio_b64": b64}, "연습할 문장이 비어 있어요."],
		["blank target", {"lang": "en", "target": "   ", "audio_b64": b64}, "연습할 문장이 비어 있어요."],
		["target missing", {"lang": "en", "audio_b64": b64}, "연습할 문장이 비어 있어요."],
		["target is a number", {"lang": "en", "target": 5, "audio_b64": b64}, "연습할 문장이 비어 있어요."],
		["target without words", {"lang": "en", "target": "?! ...", "audio_b64": b64}, "연습할 문장이 비어 있어요."],
		["lang fr", {"lang": "fr", "target": TARGET, "audio_b64": b64}, "lang은 'en' 또는 'ja'여야 해요."],
	]
	for c in cases:
		var r: Dictionary = await LS.handle("POST", "/score", {}, c[1])
		ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["err_code"]) == "bad_request" and str(r["error"]) == str(c[2]), "PA4-5: 400 " + str(c[0]))
	ok(fake.transcribe_calls == 0 and fake.load_calls == 0, "PA4-5: none of the refused requests reached the engine (no load, no transcribe)")
	var rj: Dictionary = await LS.handle("POST", "/score", {}, {"lang": "ja", "target": "こんにちは", "audio_b64": b64})
	ok(not bool(rj["ok"]) and str(rj["err_code"]) == "not_on_phone", "PA4-5: lang ja is not_on_phone")
	var rm: Dictionary = await LS.handle("GET", "/score", {}, {"lang": "en"})
	ok(str(rm["err_code"]) == "not_on_phone", "a GET is not_on_phone")
	var rp: Dictionary = await LS.handle("POST", "/other", {}, {"lang": "en"})
	ok(str(rp["err_code"]) == "not_on_phone", "another path is not_on_phone")
	var rs: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": ""})
	ok(int(rs["code"]) == 400 and str(rs["error"]) == "녹음된 소리가 없어요. 다시 녹음해 주세요.", "PA4-5: /stt with no audio is a 400 too (and needs no target)")
	# the bridge says bad_wav for a header that the main thread could not judge
	fake.mode = "bad_wav"
	var rb: Dictionary = await _score()
	ok(int(rb["code"]) == 400 and str(rb["error"]) == "오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요.", "PA4-5: the bridge's bad_wav is the same 400")
	fake.mode = "normal"
	# silence: score 0 + NO_VOICE_TIP, also with a final_map that would lift 0
	fake.mode = "no_words"
	var rn: Dictionary = await _score()
	ok(bool(rn["ok"]) and int(rn["data"]["score"]) == 0 and rn["data"]["tips_ko"] == [NO_VOICE_TIP] and str(rn["data"]["transcript"]) == "", "PA4-5: silence -> score 0 + NO_VOICE_TIP")
	var fx: Dictionary = _params_good()
	_use_params({"name": "lift", "set": {"final_map": [[0, 10], [100, 100]]}}, fx["good"])
	var rn2: Dictionary = await _score()
	ok(bool(rn2["ok"]) and int(rn2["data"]["score"]) == 0, "PA4-5: silence stays 0 even with a final_map that starts at 10")
	var rns: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": b64})
	ok(bool(rns["ok"]) and str(rns["data"]["text"]) == "" and (rns["data"]["words"] as Array).is_empty(), "PA4-5: /stt on silence is an empty text and no words")
	fake.mode = "normal"
	LS.params_path_override = DIR + "/absent.json"
	# 30 s cut
	var long: PackedByteArray = _wav(35.0, 8000, 0.2)
	var r30: Dictionary = await LS.handle("POST", "/score", {}, _body(TARGET, long))
	ok(bool(r30["ok"]) and fake.rec_wav_size == 44 + 30 * 8000 * 2 and fake.rec_wav_data == 30 * 8000 * 2 and fake.rec_riff == fake.rec_wav_size - 8, "PA4-5: a 35 s WAV reaches the bridge as 30 s (data %d, riff size %d)" % [fake.rec_wav_data, fake.rec_riff])
	ok(is_equal_approx(float(fake.rec_opts.get("max_seconds", 0.0)), 30.0), "PA4-5: the bridge also got options.max_seconds 30")
	var exact: PackedByteArray = _wav(30.0, 8000, 0.2)
	await LS.handle("POST", "/score", {}, _body(TARGET, exact))
	ok(fake.rec_wav_size == exact.size(), "PA4-5: a 30 s WAV is passed on as it is")
	var streamed: PackedByteArray = _wav(33.0, 8000, 0.2, true)
	await LS.handle("POST", "/score", {}, _body(TARGET, streamed))
	ok(fake.rec_wav_data == 30 * 8000 * 2 and fake.rec_wav_size == 44 + 30 * 8000 * 2, "PA4-5: a streamed-size WAV of 33 s is cut to 30 s with a real data size")
	var short: PackedByteArray = _wav(2.0)
	await LS.handle("POST", "/score", {}, _body(TARGET, short))
	ok(fake.rec_wav_size == short.size(), "PA4-5: a 2 s WAV is passed on as it is")
	# base64 with line breaks (MIME) is fine
	var wrapped: String = b64.substr(0, 100) + "\r\n" + b64.substr(100, 100) + "\n" + b64.substr(200)
	var rw: Dictionary = await LS.handle("POST", "/score", {}, {"lang": "en", "target": TARGET, "audio_b64": wrapped})
	ok(bool(rw["ok"]), "base64 with line breaks is read")


# ================================================================================================ PA4-7 lifecycle
func _lifecycle() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var r1: Dictionary = await _score()
	ok(bool(r1["ok"]) and fake.load_calls == 1 and fake.unload_calls == 0, "PA4-7: the first use loads the model once")
	var r2: Dictionary = await _score()
	ok(bool(r2["ok"]) and fake.load_calls == 1, "PA4-7: the next request reuses the loaded model")
	ok(str(fake.loaded_path).ends_with("ggml-base.en-q5_1.bin"), "PA4-7: the model path comes from ModelStore.path_of")
	_clock_t += 80.0
	await _frames(8)
	ok(fake.unload_calls == 0, "PA4-7: 80 s after the last use the model is still loaded")
	_clock_t += 12.0
	var gone: bool = await _until(func() -> bool: return fake.unload_calls == 1, 5.0)
	ok(gone and fake.loaded_path == "", "PA4-7: 92 s after the last use the model is unloaded (fake clock)")
	await _frames(10)
	ok(fake.unload_calls == 1, "PA4-7: it is unloaded once, not again and again")
	var r3: Dictionary = await _score()
	ok(bool(r3["ok"]) and fake.load_calls == 2, "PA4-7: the next request loads it again")
	# a load that fails: model_corrupt and ModelStore says corrupt
	var f2 := Fake.new()
	f2.fail_load = true
	await _setup(f2)
	var rc: Dictionary = await _score()
	ok(not bool(rc["ok"]) and str(rc["err_code"]) == "model_corrupt" and int(rc["code"]) == 503, "PA4-7: a load that fails -> model_corrupt")
	ok(ModelStore.state(BASE) == "corrupt", "PA4-7: ModelStore.mark_corrupt was called (state corrupt)")
	ok(not bool(LS.is_available_for("/score", {}, {"lang": "en"})) and str(LS.unavailable_reason().get("err_code", "")) == "model_corrupt", "PA4-7: after that the phone says model_corrupt up front")
	ok(f2.transcribe_calls == 0, "PA4-7: no transcribe was tried without a model")
	ok(int(LS.stats()["engine_err"]) == 1, "stats: the failed load counts as an engine error")
	# warm(): loads without a request, only on the phone with a ready model
	var f3 := Fake.new()
	await _setup(f3)
	Route.phone_hook = func() -> bool: return false
	LS.warm()
	await _frames(6)
	ok(f3.load_calls == 0 and SttEngine.peek() == null, "warm() on the PC app does nothing")
	Route.phone_hook = func() -> bool: return true
	_set_model("missing")
	LS.warm()
	await _frames(6)
	ok(f3.load_calls == 0, "warm() without a ready model does nothing")
	_set_model("ready")
	LS.warm()
	LS.warm()
	var warmed: bool = await _until(func() -> bool: return f3.load_calls == 1, 5.0)
	ok(warmed and SttEngine.main_thread_calls == 0, "warm() loads the model once in the background (twice called, one load)")
	var rw: Dictionary = await _score()
	ok(bool(rw["ok"]) and f3.load_calls == 1, "a request after warm() does not load again")
	ok(int(LS.stats()["load_count"]) == 1 and int(LS.stats()["load_ms_first"]) >= 0, "stats: load_count 1")


# ================================================================================================ PA4-8 not blocking
func _nonblocking() -> void:
	var fake := Fake.new()
	await _setup(fake)
	fake.tr_delay_ms = 1000
	await _score() # loads the model; the next one is measured
	var frames: Array = [0]
	var h: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	var t0: int = Time.get_ticks_msec()
	while not bool(h["done"]) and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().process_frame
		frames[0] += 1
	var sec: float = float(Time.get_ticks_msec() - t0) / 1000.0
	var rate: float = float(frames[0]) / maxf(sec, 0.001)
	ok(bool(h["done"]) and bool(h["res"]["ok"]) and sec >= 0.9, "PA4-8: the 1 s bridge call took %.2f s" % sec)
	ok(rate >= 50.0, "PA4-8: the main thread ran %.0f frames per second while the bridge blocked (>= 50)" % rate)
	ok(SttEngine.main_thread_calls == 0, "PA4-8: no bridge function was called on the main thread")


# ================================================================================================ PA4-9 no network
func _network() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var sent0: int = Api.sent_count
	var served0: int = LocalApi.served_count
	var call1 = Api.post_json("/score", _body(TARGET, _wav_of("2s", 2.0)), 60.0, false)
	var r1: Dictionary = await call1.wait()
	var call2 = Api.post_json("/stt", {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))}, 60.0, false)
	var r2: Dictionary = await call2.wait()
	var r3: Dictionary = await LocalApi.dispatch("POST", "/score", _body(TARGET, _wav_of("2s", 2.0)))
	ok(bool(r1["ok"]) and bool(r2["ok"]) and bool(r3["ok"]), "PA4-9: /score and /stt through Api and LocalApi.dispatch work")
	ok(str(r1["data"]["via"]) == "phone" and str(r2["data"]["via"]) == "phone", "PA4-9: Api served both on the phone")
	ok(Api.sent_count == sent0, "PA4-9: Api.sent_count did not move (%d -> %d)" % [sent0, Api.sent_count])
	ok(LocalApi.served_count == served0 + 3, "PA4-9: LocalApi served 3 requests")
	ok(Api.active_count == 0, "PA4-9: Api.active_count is 0 afterwards")


# ================================================================================================ PA4-10 bad bridge answers
func _bad_bridge() -> void:
	var fake := Fake.new()
	await _setup(fake)
	for m in ["error", "null"]:
		fake.mode = m
		var r: Dictionary = await _score()
		ok(not bool(r["ok"]) and str(r["err_code"]) == "engine_error" and int(r["code"]) == 500, "PA4-10: bridge answer '%s' -> engine_error" % m)
	for raw in [5, "text", [1, 2], {"ok": true}, {"ok": "yes"}]:
		fake.mode = "raw"
		fake.raw_result = raw
		var r2: Dictionary = await _score()
		var strict_ok: bool = raw is Dictionary and typeof((raw as Dictionary).get("ok")) == TYPE_BOOL and bool((raw as Dictionary)["ok"])
		var good: bool = bool(r2["ok"]) if strict_ok else ((not bool(r2["ok"])) and str(r2["err_code"]) == "engine_error")
		ok(good, "PA4-10: raw bridge answer %s is handled without a crash" % JSON.stringify(raw))
	fake.mode = "normal"
	# odd words: negative / NaN / huge p, start after end, no start, text as number, entries that are no words
	fake.words = [
		{"w": "The", "p": -0.5, "start": 0.5, "end": 0.2},
		{"w": "cat", "p": 7.0, "start": 0.4},
		{"w": "sat", "p": "high", "start": "a", "end": null},
		{"p": 0.9, "start": 1.0, "end": 1.1},
		42,
		{"w": "on", "p": NAN, "start": NAN, "end": INF},
		{"w": "the", "p": 0.6, "start": 1.25, "end": 1.4},
		{"w": "mat", "p": 0.95, "start": 1.45, "end": 1.9}]
	var r3: Dictionary = await _score()
	ok(bool(r3["ok"]), "PA4-10: odd words (negative p, p > 1, text p, NaN, no w, a number) -> an answer, no crash")
	var stt: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	var ws: Array = stt["data"]["words"]
	var clean: bool = ws.size() == 6
	var times_ok: bool = true
	var p_ok: bool = true
	for i in ws.size():
		var w: Dictionary = ws[i]
		times_ok = times_ok and float(w["start"]) >= 0.0 and float(w["start"]) <= float(w["end"]) and float(w["end"]) <= 2.0 and (i == 0 or float(w["start"]) >= float(ws[i - 1]["start"]))
		p_ok = p_ok and float(w["p"]) >= 0.0 and float(w["p"]) <= 1.0
	ok(clean and times_ok and p_ok, "PA4-10: /stt words: the 6 real words stay, p in [0, 1], times sorted inside the clip")
	ok(is_equal_approx(float(ws[0]["p"]), 0.0) and is_equal_approx(float(ws[1]["p"]), 1.0), "PA4-10: p -0.5 -> 0 and p 7 -> 1 (cut by map_p)")
	fake.mode = "words_missing"
	var r4: Dictionary = await _score()
	ok(bool(r4["ok"]) and int(r4["data"]["score"]) == 0, "PA4-10: an answer without words is scored like silence")
	fake.mode = "normal"
	fake.words = Fake.new().words
	fake.text = ""
	var r5: Dictionary = await _score()
	ok(bool(r5["ok"]) and int(r5["data"]["score"]) > 0, "PA4-10: an empty text with words is still scored by the words")
	fake.duration = -3.0
	var r6: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	ok(bool(r6["ok"]) and is_equal_approx(float(r6["data"]["duration"]), 2.0), "PA4-10: a bad duration falls back to the WAV length")
	fake.duration = 2.0
	fake.text = TEXT
	var rr: Dictionary = await _score()
	ok(bool(rr["ok"]), "PA4-10: and the next normal request is fine")


# ================================================================================================ PA4-6 time-out, queue, cancel
func _timeouts() -> void:
	# (a) 13 s on the fake clock: abort() once, stt_timeout; the late result is dropped
	var fake := Fake.new()
	await _setup(fake)
	fake.hang_count = 1
	fake.ignore_abort = true
	var h: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	var started: bool = await _until(func() -> bool: return fake.events().has("t_start"), 5.0)
	await _frames(5)
	ok(started and not bool(h["done"]), "PA4-6: the bridge is blocking and the request waits")
	_clock_t += 11.0
	await _frames(5)
	ok(not bool(h["done"]) and fake.abort_calls == 0, "PA4-6: at 11 s nothing happened")
	_clock_t += 2.0
	var done: bool = await _until(func() -> bool: return bool(h["done"]), 5.0)
	var r: Dictionary = h["res"]
	ok(done and not bool(r["ok"]) and str(r["err_code"]) == "stt_timeout" and int(r["code"]) == 504, "PA4-6: 13 s -> stt_timeout (504)")
	ok(fake.abort_calls == 1, "PA4-6: abort() was called once (%d)" % fake.abort_calls)
	ok(int(LS.stats()["timeouts"]) == 1, "stats: timeouts 1")
	# the bridge ignores abort and answers late: the answer is dropped, nothing breaks
	fake.release = true
	var settled: bool = await _until(func() -> bool: return fake.events().has("t_end"), 5.0)
	await _frames(5)
	ok(settled and not bool(h["res"]["ok"]) and int(LS.stats()["ok"]) == 0, "PA4-6: the late result is dropped (the answer stays stt_timeout, ok stays 0)")
	fake.release = false
	var rn: Dictionary = await _score()
	ok(bool(rn["ok"]), "PA4-6: the next request works after a time-out")
	# (b) two requests at once: in order, the second is fine
	var f2 := Fake.new()
	await _setup(f2)
	f2.tr_delay_ms = 250
	var ha: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	var hb: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	var both: bool = await _until(func() -> bool: return bool(ha["done"]) and bool(hb["done"]), 10.0)
	var ev: Array = f2.events()
	ok(both and bool(ha["res"]["ok"]) and bool(hb["res"]["ok"]), "PA4-6: two requests at once both give an answer")
	var seq: Array = ev.filter(func(e: Variant) -> bool: return str(e) != "load")
	ok(seq == ["t_start", "t_end", "t_start", "t_end"], "PA4-6: the bridge ran them one after the other (%s)" % str(seq))
	ok(f2.load_calls == 1, "PA4-6: the model was loaded once for both")
	# (c) ApiCall.cancel() on the first: the second is not blocked, active_count 0
	var f3 := Fake.new()
	await _setup(f3)
	f3.tr_delay_ms = 400
	var c1 = Api.post_json("/score", _body(TARGET, _wav_of("2s", 2.0)), 60.0, false)
	await _frames(4)
	var c2 = Api.post_json("/score", _body(TARGET, _wav_of("2s", 2.0)), 60.0, false)
	await _frames(2)
	c1.cancel()
	var r1: Dictionary = await c1.wait()
	ok(bool(r1["cancelled"]), "PA4-6: the first ApiCall ended cancelled")
	var r2: Dictionary = await c2.wait()
	ok(bool(r2["ok"]) and str(r2["data"]["via"]) == "phone", "PA4-6: the second request still answers after the first was cancelled")
	await _frames(6)
	ok(Api.active_count == 0, "PA4-6: Api.active_count is 0")
	ok(f3.transcribe_calls == 2 and f3.abort_calls == 0, "PA4-6: a cancel only drops the result (no abort, both ran)")
	# (d) the first hangs and times out, the second waits behind it and still gets its turn
	var f4 := Fake.new()
	await _setup(f4)
	f4.hang_count = 1
	var h1: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return f4.events().has("t_start"), 5.0)
	await _frames(3)
	var h2: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _frames(5)
	_clock_t += 13.0
	var both2: bool = await _until(func() -> bool: return bool(h1["done"]) and bool(h2["done"]), 10.0)
	ok(both2 and str(h1["res"]["err_code"]) == "stt_timeout", "PA4-6: the hanging request times out")
	ok(bool(h2["res"]["ok"]), "PA4-6: the request behind it is not broken by that time-out")
	ok(f4.abort_calls == 1, "PA4-6: only one abort() for the whole sequence")
	# (e) a job that never starts: it gives up after QUEUE_WAIT_SEC
	var f5 := Fake.new()
	await _setup(f5)
	f5.hang_count = 1
	f5.ignore_abort = true
	var k1: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return f5.events().has("t_start"), 5.0)
	await _frames(3)
	var k2: Dictionary = _spawn("/stt", {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	await _frames(4)
	_clock_t += 13.0
	await _until(func() -> bool: return bool(k1["done"]), 5.0)
	ok(str(k1["res"]["err_code"]) == "stt_timeout", "PA4-6: (e) the first times out")
	_clock_t += 40.0
	var kd: bool = await _until(func() -> bool: return bool(k2["done"]), 5.0)
	ok(kd and str(k2["res"].get("err_code", "")) == "stt_timeout", "PA4-6: (e) a job that did not start in 36 s is given up")
	f5.release = true
	await _until(func() -> bool: return f5.events().count("t_end") >= 1, 5.0)
	await _frames(5)


# ================================================================================================ PA4-13 the engine thread
func _async_engine() -> void:
	# (1) thread of the calls
	var fake := Fake.new()
	await _setup(fake)
	await _score()
	LS.warm()
	await _frames(3)
	_clock_t += 100.0
	await _until(func() -> bool: return fake.unload_calls == 1, 5.0)
	ok(fake.load_calls >= 1 and fake.unload_calls == 1 and fake.transcribe_calls >= 1 and SttEngine.main_thread_calls == 0, "PA4-13 (1): load, transcribe and unload ran and none of them on the main thread")
	# (2) frames while load_model blocks 1.5 s and transcribe 2 s
	var f2 := Fake.new()
	await _setup(f2)
	f2.load_delay_ms = 1500
	f2.tr_delay_ms = 2000
	var fr: int = 0
	var h: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	var t0: int = Time.get_ticks_msec()
	while not bool(h["done"]) and Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
		fr += 1
	var sec: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(bool(h["done"]) and bool(h["res"]["ok"]) and sec >= 3.4, "PA4-13 (2): load 1.5 s + transcribe 2 s took %.2f s" % sec)
	ok(float(fr) / sec >= 50.0, "PA4-13 (2): %.0f frames per second on the main thread meanwhile (>= 50)" % (float(fr) / sec))
	ok(SttEngine.main_thread_calls == 0, "PA4-13 (2): still no bridge call on the main thread")
	# (3) request_unload while a transcription runs
	var f3 := Fake.new()
	await _setup(f3)
	f3.tr_delay_ms = 15000
	var h3: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return f3.events().has("t_start"), 5.0)
	var eng: SttEngine = SttEngine.peek()
	var us0: int = Time.get_ticks_usec()
	var fr0: int = Engine.get_process_frames()
	eng.request_unload()
	var us1: int = Time.get_ticks_usec()
	var fr1: int = Engine.get_process_frames()
	ok(us1 - us0 < 50000 and fr1 == fr0, "PA4-13 (3): request_unload() returned at once (%d us, same frame)" % (us1 - us0))
	ok(f3.abort_calls == 1, "PA4-13 (3): abort() was called right away, once")
	var unloaded: bool = await _until(func() -> bool: return f3.unload_calls == 1, 5.0)
	var ev3: Array = f3.events()
	ok(unloaded and ev3.find("t_end") >= 0 and ev3.find("unload") > ev3.find("t_end"), "PA4-13 (3): unload ran after the transcription returned (%s)" % str(ev3))
	await _until(func() -> bool: return bool(h3["done"]), 5.0)
	ok(bool(h3["done"]) and str(h3["res"]["err_code"]) == "engine_error", "PA4-13 (3): the aborted request is an engine_error")
	ok(eng.loaded_path() == "", "PA4-13 (3): the engine knows nothing is loaded")
	# (4) pause: the request that waits gets TEXT_PAUSED, one unload
	var f4 := Fake.new()
	await _setup(f4)
	f4.tr_delay_ms = 15000
	var p1: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return f4.events().has("t_start"), 5.0)
	await _frames(2)
	var p2: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _frames(4)
	var eng4: SttEngine = SttEngine.peek()
	eng4.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var pd: bool = await _until(func() -> bool: return bool(p1["done"]) and bool(p2["done"]), 5.0)
	ok(pd and str(p1["res"]["err_code"]) == "engine_error" and str(p1["res"]["error"]) == LS.TEXT_PAUSED, "PA4-13 (4): the running request gets engine_error with TEXT_PAUSED")
	ok(str(p2["res"]["err_code"]) == "engine_error" and str(p2["res"]["error"]) == LS.TEXT_PAUSED, "PA4-13 (4): the queued request gets it too")
	var ud: bool = await _until(func() -> bool: return f4.unload_calls == 1, 5.0)
	ok(ud and f4.abort_calls >= 1 and f4.transcribe_calls == 1, "PA4-13 (4): abort() and one unload; the queued request never reached the bridge")
	var rr: Dictionary = await _score()
	ok(bool(rr["ok"]) and f4.load_calls == 2, "PA4-13 (4): after the pause the next request loads the model again")
	ok(int(LS.stats()["aborted"]) >= 2, "stats: aborted counts the paused requests")
	var eng4b: SttEngine = SttEngine.peek()
	eng4b.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(3)
	ok(eng4b.loaded_path() != "", "PA4-13 (4): a resume does nothing (the model stays loaded)")
	# (5) shutdown while a transcription blocks
	var f5 := Fake.new()
	await _setup(f5)
	f5.tr_delay_ms = 15000
	var s1: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return f5.events().has("t_start"), 5.0)
	var eng5: SttEngine = SttEngine.peek()
	var t5: int = Time.get_ticks_msec()
	eng5.shutdown()
	var took: int = Time.get_ticks_msec() - t5
	ok(took < 3000, "PA4-13 (5): shutdown() returned in %d ms although a transcription was running" % took)
	ok(eng5._thread == null and f5.abort_calls >= 1 and f5.unload_calls == 1, "PA4-13 (5): the thread is joined, abort() was called, the model was unloaded")
	var after: SttEngine.Job = eng5.submit(PackedByteArray(), {}) ## before the next frame: the stopped node frees itself at the end of this one
	ok(after.done and str(after.result["error"]) == "shutdown", "PA4-13 (5): a stopped engine refuses new jobs")
	eng5.shutdown()
	ok(true, "PA4-13 (5): a second shutdown() is harmless")
	ok(SttEngine.peek() == null, "PA4-13 (5): a stopped engine is not the current one")
	await _until(func() -> bool: return bool(s1["done"]), 5.0)
	ok(bool(s1["done"]) and str(s1["res"]["err_code"]) == "engine_error", "PA4-13 (5): the waiting request ended (engine_error)")
	await _frames(2)
	ok(not is_instance_valid(eng5), "PA4-13 (5): the stopped engine node was freed")
	var rn: Dictionary = await _score()
	ok(bool(rn["ok"]) and SttEngine.peek() != null and SttEngine.peek() != eng5, "PA4-13 (5): the next request creates a new engine")
	# engine API: queue order, dedupe of loads, cancel of a waiting job
	var f6 := Fake.new()
	await _setup(f6)
	var e6: SttEngine = SttEngine.get_or_create()
	e6.bridge_factory = func() -> Object: return f6
	await _frames(3)
	ok(e6.is_inside_tree() and e6.name == "SttEngine" and get_tree().root.get_node_or_null("SttEngine") == e6, "the engine is one node named SttEngine below the root")
	e6.request_load("user://a.bin")
	e6.request_load("user://a.bin")
	e6.request_load("user://a.bin")
	await _until(func() -> bool: return e6.loaded_path() == "user://a.bin", 5.0)
	await _frames(5)
	ok(f6.load_calls == 1 and e6.loaded_path() == "user://a.bin", "engine: the same file requested three times is loaded once")
	e6.request_load("user://b.bin")
	await _until(func() -> bool: return e6.loaded_path() == "user://b.bin", 5.0)
	ok(f6.load_calls == 2 and e6.loaded_path() == "user://b.bin", "engine: another file replaces the loaded one")
	f6.tr_delay_ms = 600
	var j1: SttEngine.Job = e6.submit(_wav_of("2s", 2.0), {})
	var j2: SttEngine.Job = e6.submit(_wav_of("2s", 2.0), {})
	var j3: SttEngine.Job = e6.submit(_wav_of("2s", 2.0), {})
	await _until(func() -> bool: return f6.events().has("t_start"), 5.0)
	e6.cancel_job(j2)
	ok(j2.done and str(j2.result["error"]) == "cancelled", "engine: a waiting job that is cancelled ends 'cancelled' at once")
	ok(e6.busy(), "engine: busy() is true while jobs run")
	await _until(func() -> bool: return j1.done and j3.done, 10.0)
	ok(bool(j1.result["ok"]) and bool(j3.result["ok"]) and f6.transcribe_calls == 2, "engine: the other two jobs ran (the cancelled one never reached the bridge)")
	ok(not e6.busy(), "engine: busy() is false when everything is done")
	var res_t: Dictionary = await e6.transcribe(_wav_of("2s", 2.0), {})
	ok(bool(res_t["ok"]), "engine: transcribe() is a coroutine that returns the result")
	f6.tr_delay_ms = 0
	var mem: Dictionary = e6.memory_now()
	ok(int(mem["rss_kb"]) > 0 and int(mem["peak_kb"]) > 0, "engine: memory_now() reads the bridge's memory_info")
	var inf: Dictionary = e6.info()
	ok(int(inf["load_calls"]) == 2 and int(inf["rss_after_kb"]) > int(inf["rss_before_kb"]), "engine: info() has the load count and the rss before / after the load")
	# a job without a model
	var f7 := Fake.new()
	await _setup(f7)
	var e7: SttEngine = SttEngine.get_or_create()
	e7.bridge_factory = func() -> Object: return f7
	var jn: SttEngine.Job = e7.submit(_wav_of("2s", 2.0), {})
	await _until(func() -> bool: return jn.done, 5.0)
	ok(jn.done and str(jn.result["error"]) == "no_model" and f7.transcribe_calls == 0, "engine: a job without a loaded model ends no_model")
	var e8: SttEngine = SttEngine.get_or_create()
	ok(e8 == e7, "get_or_create() returns the same node")
	var f8 := Fake.new()
	f8.fail_load = true
	await _setup(f8)
	var e9: SttEngine = SttEngine.get_or_create()
	e9.bridge_factory = func() -> Object: return f8
	e9.request_load("user://c.bin")
	var jf: SttEngine.Job = e9.submit(_wav_of("2s", 2.0), {})
	await _until(func() -> bool: return jf.done, 5.0)
	ok(str(jf.result["error"]) == "load_failed", "engine: a failed load_model ends the next job 'load_failed'")
	e9.request_load("user://c.bin")
	await _until(func() -> bool: return f8.load_calls == 2, 5.0)
	ok(f8.load_calls == 2, "engine: after a failed load the same file is tried again")
	# a late cancel must not abort the NEXT job: A is finished on the engine thread (its answer is still on the way), B is running
	var f11 := Fake.new()
	await _setup(f11)
	var e11: SttEngine = SttEngine.get_or_create()
	e11.bridge_factory = func() -> Object: return f11
	e11.request_load("user://d.bin")
	await _until(func() -> bool: return f11.load_calls == 1, 5.0)
	var ja: SttEngine.Job = e11.submit(_wav_of("2s", 2.0), {})
	var spin: int = Time.get_ticks_msec()
	while f11.events().count("t_end") < 1 and Time.get_ticks_msec() - spin < 5000:
		OS.delay_msec(2) ## no frame passes here: the answer of A is not delivered yet
	f11.tr_delay_ms = 800
	var jb: SttEngine.Job = e11.submit(_wav_of("2s", 2.0), {})
	spin = Time.get_ticks_msec()
	while f11.events().count("t_start") < 2 and Time.get_ticks_msec() - spin < 5000:
		OS.delay_msec(2)
	var a_waiting: bool = not ja.done
	e11.cancel_job(ja)
	ok(a_waiting and f11.abort_calls == 0, "engine: cancelling a job that already finished on the thread does not abort the job that runs now")
	await _until(func() -> bool: return jb.done, 10.0)
	ok(jb.done and bool(jb.result["ok"]), "engine: that next job finished normally")
	var f9 := Fake.new()
	await _setup(f9)
	var e10: SttEngine = SttEngine.get_or_create()
	e10.bridge_factory = func() -> Object: return null
	var jx: SttEngine.Job = e10.submit(PackedByteArray(), {})
	ok(jx.done and str(jx.result["error"]) == "no_engine", "engine: without a bridge a job ends no_engine at once")


# ================================================================================================ the engine's load / unload / abort races
## A request that arrives while the thread is in the middle of an item (taken from the queue, `_loaded_path` not yet changed) must see
## that item: the same file is loaded once, a load that is running can be unloaded, an unload that is running can be followed by a load.
func _race_engine(f: Fake) -> SttEngine:
	await _setup(f)
	var e: SttEngine = SttEngine.get_or_create()
	e.bridge_factory = func() -> Object: return f
	await _frames(3)
	return e


func _engine_race() -> void:
	# (1) the same path asked again while the first load is running: one load_model call
	var f1 := Fake.new()
	f1.load_delay_ms = 500
	var e1: SttEngine = await _race_engine(f1)
	e1.request_load("user://a.bin")
	var started: bool = await _until(func() -> bool: return f1.load_calls == 1, 5.0)
	var mid_loaded: String = e1.loaded_path()
	e1.request_load("user://a.bin")
	e1.request_load("user://a.bin")
	var done1: bool = await _until(func() -> bool: return e1.loaded_path() == "user://a.bin", 5.0)
	OS.delay_msec(300) ## a wrongly queued second load would start (and count) now
	await _frames(5)
	ok(started and mid_loaded == "" and done1, "race (1): the first load was in flight (nothing loaded yet) when the same path was asked again")
	ok(f1.load_calls == 1 and int(e1.info()["load_calls"]) == 1, "race (1): the same path asked twice while its load runs is loaded once (%d calls)" % f1.load_calls)
	# (2) load A, unload, load A again: the second load is real
	var f2 := Fake.new()
	var e2: SttEngine = await _race_engine(f2)
	e2.request_load("user://a.bin")
	await _until(func() -> bool: return e2.loaded_path() == "user://a.bin", 5.0)
	e2.request_unload()
	await _until(func() -> bool: return f2.unload_calls == 1 and e2.loaded_path() == "", 5.0)
	e2.request_load("user://a.bin")
	await _until(func() -> bool: return e2.loaded_path() == "user://a.bin", 5.0)
	ok(f2.load_calls == 2 and f2.unload_calls == 1 and f2.loaded_path == "user://a.bin", "race (2): load A, unload, load A loads twice (%d loads, %d unloads)" % [f2.load_calls, f2.unload_calls])
	# (2b) the same, but unload and the second load are asked while the first load still runs
	var f2b := Fake.new()
	f2b.load_delay_ms = 400
	var e2b: SttEngine = await _race_engine(f2b)
	e2b.request_load("user://a.bin")
	await _until(func() -> bool: return f2b.load_calls == 1, 5.0)
	e2b.request_unload()
	e2b.request_load("user://a.bin")
	e2b.request_load("user://a.bin")
	await _until(func() -> bool: return f2b.load_calls == 2 and e2b.loaded_path() == "user://a.bin", 5.0)
	OS.delay_msec(300)
	ok(f2b.load_calls == 2 and f2b.unload_calls == 1 and f2b.loaded_path == "user://a.bin", "race (2b): load A (running), unload, load A, load A -> 2 loads, 1 unload (%d, %d)" % [f2b.load_calls, f2b.unload_calls])
	# (3) another path while the first load runs: both are loaded, in order
	var f3 := Fake.new()
	f3.load_delay_ms = 400
	var e3: SttEngine = await _race_engine(f3)
	e3.request_load("user://a.bin")
	await _until(func() -> bool: return f3.load_calls == 1, 5.0)
	e3.request_load("user://b.bin")
	await _until(func() -> bool: return e3.loaded_path() == "user://b.bin", 5.0)
	ok(f3.load_calls == 2 and f3.loaded_path == "user://b.bin", "race (3): another path B asked while A loads is loaded once, after A (%d loads)" % f3.load_calls)
	# (4) an unload asked while a load runs is not dropped (the model is not loaded yet, but it will be)
	var f4 := Fake.new()
	f4.load_delay_ms = 400
	var e4: SttEngine = await _race_engine(f4)
	e4.request_load("user://a.bin")
	await _until(func() -> bool: return f4.load_calls == 1, 5.0)
	e4.request_unload()
	await _until(func() -> bool: return f4.unload_calls == 1, 5.0)
	await _frames(3)
	ok(f4.unload_calls == 1 and f4.loaded_path == "" and e4.loaded_path() == "", "race (4): an unload asked during a load runs after it (model freed)")
	# (5) a load asked while an unload runs is not dropped
	var f5 := Fake.new()
	var e5: SttEngine = await _race_engine(f5)
	e5.request_load("user://a.bin")
	await _until(func() -> bool: return e5.loaded_path() == "user://a.bin", 5.0)
	f5.unload_delay_ms = 400
	e5.request_unload()
	await _until(func() -> bool: return f5.unload_calls == 1, 5.0)
	e5.request_load("user://a.bin")
	await _until(func() -> bool: return f5.load_calls == 2 and e5.loaded_path() == "user://a.bin", 5.0)
	ok(f5.load_calls == 2 and f5.loaded_path == "user://a.bin", "race (5): a load asked while the unload runs loads again (%d loads)" % f5.load_calls)
	# (6) abort + next work: the running transcription is aborted, the model is freed and loaded again, and the NEXT job is not aborted
	var f6 := Fake.new()
	var e6: SttEngine = await _race_engine(f6)
	e6.request_load("user://a.bin")
	await _until(func() -> bool: return e6.loaded_path() == "user://a.bin", 5.0)
	f6.tr_delay_ms = 15000
	var j1: SttEngine.Job = e6.submit(_wav_of("2s", 2.0), {})
	await _until(func() -> bool: return f6.events().has("t_start"), 5.0)
	e6.request_unload()
	e6.request_load("user://a.bin")
	f6.tr_delay_ms = 0
	var j2: SttEngine.Job = e6.submit(_wav_of("2s", 2.0), {})
	await _until(func() -> bool: return j1.done and j2.done, 10.0)
	ok(j1.done and str(j1.result["error"]) == "aborted" and j2.done and bool(j2.result["ok"]), "race (6): unload aborts the running job, the job after the reload is not aborted")
	ok(f6.unload_calls == 1 and f6.load_calls == 2, "race (6): one unload and one reload (%d, %d)" % [f6.unload_calls, f6.load_calls])
	# (7) a job the thread took but has not given to the bridge yet: abort() / cancel after the pop must stop it (white box, no thread)
	var f7 := Fake.new()
	await _setup(f7)
	var e7 := SttEngine.new()
	e7.bridge_factory = func() -> Object: return f7
	e7._ensure_bridge()
	e7._loaded_path = "user://a.bin"
	var ja := SttEngine.Job.new()
	ja.abort_seq = e7._abort_seq
	var r0: Dictionary = e7._do_transcribe(ja)
	ok(bool(r0["ok"]) and f7.transcribe_calls == 1, "race (7): a job nobody aborted reaches the bridge (control)")
	var jb := SttEngine.Job.new()
	jb.abort_seq = e7._abort_seq
	e7.abort()
	var r1: Dictionary = e7._do_transcribe(jb)
	ok(not bool(r1["ok"]) and str(r1["error"]) == "aborted" and f7.transcribe_calls == 1, "race (7): abort() between the pop and the bridge call: aborted, the bridge is not called")
	var jc := SttEngine.Job.new()
	jc.abort_seq = e7._abort_seq
	jc.abandoned = true
	var r2: Dictionary = e7._do_transcribe(jc)
	ok(str(r2["error"]) == "aborted" and f7.transcribe_calls == 1, "race (7): a cancelled (abandoned) job is not started either")
	var jd := SttEngine.Job.new()
	jd.abort_seq = e7._abort_seq
	var r3: Dictionary = e7._do_transcribe(jd)
	ok(bool(r3["ok"]) and f7.transcribe_calls == 2, "race (7): a job taken after the abort runs normally")
	SttEngine.main_thread_calls = 0 ## the white box above called the fake on the main thread on purpose
	e7.free()
	await _frames(2)


# ================================================================================================ PA4-14 abort patch marker
func _patch_marker() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var r: Dictionary = await _score()
	var st: Dictionary = LS.stats()
	ok(bool(r["ok"]) and int(st["abort_patch"]) == 1 and str(st["bridge_version"]).contains("+abort-sched"), "PA4-14: version with +abort-sched -> abort_patch 1")
	var f2 := Fake.new()
	f2.ver = "bridge 1 / whisper.cpp test"
	await _setup(f2)
	var r2: Dictionary = await _score()
	var st2: Dictionary = LS.stats()
	ok(bool(r2["ok"]) and int(st2["abort_patch"]) == 0, "PA4-14: version without the marker -> abort_patch 0, and scoring is normal")
	ok(int(st["runs"]) == 1 and int(st["ok"]) == 1, "stats: runs and ok count 1 each")
	ok(int(st["rss_mb_before_load"]) > 0 and int(st["rss_mb_after_load"]) > int(st["rss_mb_before_load"]) and int(st["rss_mb_peak"]) > 0, "stats: rss before / after the load and the peak come from memory_info (MB)")
	ok(int(st["stt_ms_p50"]) == 120 and int(st["audio_ms_p50"]) == 2000 and is_equal_approx(float(st["rtf_p50"]), 0.06), "stats: stt_ms 120, audio_ms 2000, rtf 0.06")


# ================================================================================================ PA4-15 auto off
func _auto_off() -> void:
	var fake := Fake.new()
	await _setup(fake)
	ok(not bool(Store.prefs.get("stt_phone_off", false)), "PA4-15: phone scoring is on at the start")
	var t1: Dictionary = await _timeout_once(fake)
	ok(str(t1["err_code"]) == "stt_timeout" and not bool(Store.prefs.get("stt_phone_off", false)), "PA4-15: one time-out does not switch it off")
	var t2: Dictionary = await _timeout_once(fake)
	ok(str(t2["err_code"]) == "stt_timeout", "PA4-15: the second time-out is still an stt_timeout answer")
	ok(Store.prefs.get("stt_phone_off", false) == true, "PA4-15: two time-outs in a row -> pref stt_phone_off is true")
	ok(not bool(LS.is_available_for("/score", {}, {"lang": "en"})), "PA4-15: is_available_for is false")
	var why: Dictionary = LS.unavailable_reason_for("/score", {}, {"lang": "en"})
	ok(str(why["err_code"]) == "engine_error" and str(why["text_ko"]) == LS.TEXT_PHONE_OFF, "PA4-15: the reason is engine_error with TEXT_PHONE_OFF")
	ok(not bool(LocalApi.available("POST", "/score", {"lang": "en", "target": "hi"})), "PA4-15: LocalApi.available is false (Route goes to the PC or self rating)")
	ok(int(LS.stats()["phone_off"]) == 1, "stats: phone_off 1")
	var rr: Dictionary = await _score()
	ok(not bool(rr["ok"]) and str(rr["err_code"]) == "engine_error" and str(rr["error"]) == LS.TEXT_PHONE_OFF, "PA4-15: a request that comes anyway is refused with TEXT_PHONE_OFF")
	Store.set_pref("stt_phone_off", false)
	ok(bool(LS.is_available_for("/score", {}, {"lang": "en"})), "PA4-15: pref false -> available again")
	var rok: Dictionary = await _score()
	ok(bool(rok["ok"]), "PA4-15: and it scores again")
	# time-out, success, time-out: stays on
	await _timeout_once(fake)
	var rs: Dictionary = await _score()
	await _timeout_once(fake)
	ok(bool(rs["ok"]) and not bool(Store.prefs.get("stt_phone_off", false)), "PA4-15: time-out, success, time-out does not switch it off")
	# timeouts in bench do not count
	var f2 := Fake.new()
	await _setup(f2)
	f2.hang_count = 2
	f2.ignore_abort = false
	var hb: Dictionary = {"done": false, "res": {}}
	_bench_into(hb, 2)
	await _until(func() -> bool: return f2.events().count("t_start") >= 1, 5.0)
	await _frames(3)
	_clock_t += 13.0
	await _until(func() -> bool: return f2.events().count("t_start") >= 2, 5.0)
	await _frames(3)
	_clock_t += 13.0
	await _until(func() -> bool: return bool(hb["done"]), 8.0)
	ok(bool(hb["done"]) and int(hb["res"]["fail"]) == 2 and not bool(Store.prefs.get("stt_phone_off", false)), "PA4-15: two time-outs inside bench() do not switch the phone scoring off")


func _bench_into(h: Dictionary, n: int) -> void:
	h["res"] = await LS.bench(_wav_of("2s", 2.0), TARGET, n)
	h["done"] = true


func _timeout_once(fake: Fake) -> Dictionary:
	fake.hang_count = 1
	var before: int = fake.events().count("t_start")
	var h: Dictionary = _spawn("/score", _body(TARGET, _wav_of("2s", 2.0)))
	await _until(func() -> bool: return fake.events().count("t_start") > before, 5.0)
	await _frames(3)
	_clock_t += 13.0
	await _until(func() -> bool: return bool(h["done"]), 8.0)
	await _until(func() -> bool: return fake.events().count("t_end") >= fake.events().count("t_start"), 5.0)
	return h["res"]


# ================================================================================================ PA4-17 bench
func _bench() -> void:
	var fake := Fake.new()
	await _setup(fake)
	var prog_before: String = JSON.stringify(Store.progress)
	var sent0: int = Api.sent_count
	var steps: Array = []
	var runs0: int = int(LS.stats()["runs"])
	var res: Dictionary = await LS.bench(_wav_of("2s", 2.0), TARGET, 5, func(i: int, n: int) -> void: steps.append([i, n]))
	ok(int(res["n"]) == 5 and int(res["ok"]) == 5 and int(res["fail"]) == 0, "PA4-17: bench 5 -> n 5, ok 5, fail 0")
	var keys: Array = res.keys()
	keys.sort()
	ok(keys == ["fail", "ms_max", "ms_p50", "ms_p95", "n", "ok", "rss_mb_peak", "seconds"], "PA4-17: bench result keys")
	ok(steps.size() == 5 and steps[0] == [1, 5] and steps[4] == [5, 5], "PA4-17: on_step was called 5 times with (i, n)")
	ok(JSON.stringify(Store.progress) == prog_before, "PA4-17: Store.progress is the same before and after")
	ok(Api.sent_count == sent0, "PA4-17: Api.sent_count did not move")
	ok(int(LS.stats()["runs"]) == runs0 + 5, "PA4-17: stats().runs grew by 5")
	ok(int(res["ms_p50"]) <= int(res["ms_p95"]) and int(res["ms_p95"]) <= int(res["ms_max"]) and int(res["rss_mb_peak"]) > 0 and float(res["seconds"]) >= 0.0, "PA4-17: percentiles are ordered, rss peak and seconds are filled")
	var bad: Dictionary = await LS.bench(PackedByteArray([1, 2, 3]), TARGET, 2)
	ok(int(bad["n"]) == 2 and int(bad["fail"]) == 2 and int(bad["ok"]) == 0, "PA4-17: bench with a bad WAV: 2 fails, no crash")
	var zero: Dictionary = await LS.bench(_wav_of("2s", 2.0), TARGET, 0)
	ok(int(zero["n"]) == 0 and int(zero["ok"]) == 0, "PA4-17: bench with n 0 does nothing")
	var rec: Array = LS.stats()["recent"]
	ok(rec.size() == 5 and rec[0].has("score") and rec[0].has("n") and rec[0].has("ok"), "stats: recent holds {score, n, ok} entries (5 here)")
	for i in 25:
		await LS.bench(_wav_of("2s", 2.0), TARGET, 1)
	ok((LS.stats()["recent"] as Array).size() == 20, "stats: recent keeps the last 20 only")


# ================================================================================================ privacy: nothing said or sent in stats
func _leak_checks() -> void:
	var fake := Fake.new()
	await _setup(fake)
	fake.text = MARK + " hello"
	fake.words = [{"w": MARK, "p": 0.9, "start": 0.1, "end": 0.5}, {"w": "hello", "p": 0.8, "start": 0.6, "end": 1.0}]
	var tgt: String = MARK + " hello"
	var r: Dictionary = await _score(PackedByteArray(), tgt)
	ok(bool(r["ok"]), "leak: a request with the marker in target and text works")
	await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(_wav_of("2s", 2.0))})
	var eng: SttEngine = SttEngine.peek()
	ok(not _leaks(JSON.stringify(LS.stats())), "leak: stats() holds no target and no recognised text")
	ok(not _leaks(JSON.stringify(eng.info())) and not _leaks(JSON.stringify(LS.params())), "leak: engine info() and params() hold none either")
	fake.mode = "error"
	var re: Dictionary = await _score(PackedByteArray(), tgt)
	ok(not _leaks(str(re.get("error", ""))) and not _leaks(JSON.stringify(re.get("err_body", {}))), "leak: an error answer holds none")
	fake.mode = "bad_wav"
	var rw: Dictionary = await _score(PackedByteArray(), tgt)
	ok(not _leaks(str(rw.get("error", ""))), "leak: the bad_wav answer holds none")
	var rt: Dictionary = await LS.handle("POST", "/score", {}, {"lang": "en", "target": "", "audio_b64": MARK})
	ok(not _leaks(str(rt.get("error", ""))), "leak: an input error does not repeat what was sent")


# ================================================================================================ PA4-18 the real model (optional)
func _real_run() -> void:
	if _real_model == "" or _real_wav == "":
		print("real: skipped (no --real-model / --real-wav)")
		return
	if not FileAccess.file_exists(_real_model) or not FileAccess.file_exists(_real_wav) or not ClassDB.can_instantiate("WhisperBridge"):
		ok(false, "real: model, wav and the WhisperBridge class are there")
		return
	LS.reset_for_tests()
	await _frames(3)
	var size: int = FileAccess.open(_real_model, FileAccess.READ).get_length()
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/models.json"))
	for m in (d["models"] as Array):
		if str((m as Dictionary)["id"]) == BASE:
			(m as Dictionary)["bytes"] = size
	_write(DIR + "/manifest.json", JSON.stringify(d))
	var store: String = _g(DIR + "/store")
	DirAccess.make_dir_recursive_absolute(store)
	DirAccess.copy_absolute(_real_model, store.path_join("ggml-base.en-q5_1.bin"))
	var bm: Dictionary = ModelStore.model(BASE)
	_write(store.path_join("ggml-base.en-q5_1.bin.ok"), JSON.stringify({"v": 1, "sha256": str(bm["sha256"]), "bytes": size}))
	ModelStore.set_active(BASE)
	LS.params_path_override = DIR + "/absent.json"
	ok(ModelStore.state(BASE) == "ready" and bool(LS.is_available()), "real: the model is ready and the real bridge class is available")
	var target: String = "I would like a cup of coffee, please."
	var exp: String = _real_wav.get_base_dir().path_join("expected.json")
	if FileAccess.file_exists(exp):
		var ej: Variant = JSON.parse_string(FileAccess.get_file_as_string(exp))
		if ej is Dictionary and (ej as Dictionary).has(_real_wav.get_file()):
			target = str((ej as Dictionary)[_real_wav.get_file()])
	var wavb: PackedByteArray = FileAccess.get_file_as_bytes(_real_wav)
	var r: Dictionary = await LS.handle("POST", "/score", {}, _body(target, wavb))
	var words: int = (r["data"]["units"] as Array).size() if bool(r["ok"]) else 0
	ok(bool(r["ok"]) and str(r["data"]["via"]) == "phone" and int(r["data"]["score"]) >= 60 and words >= 5, "real: /score via phone, score >= 60, words >= 5 (score %d, words %d)" % [int(r["data"]["score"]) if bool(r["ok"]) else -1, words])
	var st: Dictionary = LS.stats()
	ok(int(st["load_count"]) == 1 and str(st["bridge_version"]).begins_with("bridge ") and int(st["rss_mb_after_load"]) >= 0 and int(st["abort_patch"]) == (1 if str(st["bridge_version"]).contains("+abort-sched") else 0), "real: stats has the bridge version and the abort marker (the rss is 0 where the bridge cannot read it, e.g. Windows)")
	print("real: abort_patch=", st["abort_patch"], " stt_ms_p50=", st["stt_ms_p50"], " load_ms=", st["load_ms_first"], " rss_after_mb=", st["rss_mb_after_load"], " rss_peak_mb=", st["rss_mb_peak"])
	var rs: Dictionary = await LS.handle("POST", "/stt", {}, {"lang": "en", "audio_b64": Marshalls.raw_to_base64(wavb)})
	var wl: Array = rs["data"]["words"] if bool(rs["ok"]) else []
	var times_ok: bool = not wl.is_empty()
	for i in wl.size():
		times_ok = times_ok and float(wl[i]["start"]) <= float(wl[i]["end"]) and (i == 0 or float(wl[i]["start"]) >= float(wl[i - 1]["start"]))
	ok(bool(rs["ok"]) and times_ok, "real: /stt words have clean times (D-1)")
	var eng: SttEngine = SttEngine.peek()
	eng.request_unload()
	var gone: bool = await _until(func() -> bool: return eng.loaded_path() == "", 5.0)
	ok(gone, "real: the model is unloaded")
	var silent: Dictionary = await LS.handle("POST", "/score", {}, _body(target, _wav(2.0, 16000, 0.0)))
	ok(bool(silent["ok"]) and int(silent["data"]["score"]) == 0, "real: silence scores 0")
	var t0: int = Time.get_ticks_msec()
	var sh: Dictionary = _spawn("/score", _body(target, wavb))
	await _frames(2)
	LS.reset_for_tests()
	await _until(func() -> bool: return bool(sh["done"]), 10.0)
	ok(bool(sh["done"]) and Time.get_ticks_msec() - t0 < 8000, "real: shutting the engine down while it works ends in time (%d ms)" % (Time.get_ticks_msec() - t0))
	await _frames(3)


# ================================================================================================ static source checks (X-6, X-7)
func _source_checks() -> void:
	var files: Array = ["res://scripts/local/local_stt.gd", "res://scripts/local/stt_engine.gd"]
	var lines: Array = []
	for f in files:
		var txt: String = FileAccess.get_file_as_string(f)
		ok(txt != "", "source: %s is readable" % f.get_file())
		lines.append_array(txt.split("\n"))
	ok(_log_hits(lines) == 0, "X-7: no print / push_warning / push_error / printerr line mentions text, target, transcript, words, url or path (%d)" % _log_hits(lines))
	ok(_net_hits(lines) == 0, "X-6: no network class, shell open or permission request in the two files")
	var all_txt: String = "\n".join(lines)
	ok(not all_txt.contains("WorkerThreadPool"), "the engine uses its own Thread (no WorkerThreadPool)")
	ok(all_txt.count("_thread.wait_to_finish()") == 1, "the thread is joined in exactly one place (wait_to_finish once)")
	ok(all_txt.contains("_exit_tree") and all_txt.contains("NOTIFICATION_PREDELETE"), "shutdown is wired to _exit_tree and PREDELETE")
	ok(all_txt.contains("NOTIFICATION_APPLICATION_PAUSED"), "the engine handles the pause notification")
