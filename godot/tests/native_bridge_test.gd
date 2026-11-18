extends Node
## WhisperBridge (GDExtension, whisper.cpp) test. Needs the Windows DLL (native\whisper_bridge\build.ps1 -Target windows-x64),
## a model and synthesized WAV files; none of them is in the repository.
##   godot --headless --path <project>/godot res://tests/native_bridge_test.tscn -- --model=<ggml-base.en-q5_1.bin> --wav-dir=<folder with wav>
##   (optional) --bench --tiny=<ggml-tiny.en-q5_1.bin>   prints transcription times (reference values, not asserted)
## WAV folder: coffee.wav ("I would like a cup of coffee, please."), coffee_16k/8k/44k_stereo/quiet.wav, s0..s6.wav, long27.wav,
##   silence.wav, tiny_noise.wav, short.wav, empty.wav, garbage.wav, truncated.wav, expected.json (file name -> sentence).
## Exit code 0 = all passed. Last line: "== native_bridge: N passed, M failed =="

var passed: int = 0
var failed: int = 0
var model_path: String = ""
var tiny_path: String = ""
var wav_dir: String = ""
var expected: Dictionary = {}
var fail_names: PackedStringArray = PackedStringArray()   ## names of the failed checks (the probe copies them into its result text)
var trace_path: String = ""          ## --trace=<file>: every item is written here BEFORE it runs (survives a crash); last line "done" = finished
var trace_lines: PackedStringArray = PackedStringArray()
var trace_mutex := Mutex.new()


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		fail_names.append(name.left(120))
		print("  FAIL  ", name)


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


## Breadcrumb: write the item that is about to run, flush and close, so a native crash leaves the last item in the file.
func _trace(item: String) -> void:
	print("TRACE ", item)
	if trace_path == "":
		return
	trace_mutex.lock()
	trace_lines.append(item)
	var f: FileAccess = FileAccess.open(trace_path, FileAccess.WRITE)
	if f != null:
		f.store_string("
".join(trace_lines) + "
")
		f.flush()
		f.close()
	trace_mutex.unlock()


func _ready() -> void:
	print("== native_bridge start ==")
	trace_path = _arg("--trace=")
	_trace("start")
	model_path = _arg("--model=")
	tiny_path = _arg("--tiny=")
	wav_dir = _arg("--wav-dir=")
	if not ClassDB.class_exists("WhisperBridge") or not ClassDB.can_instantiate("WhisperBridge"):
		ok(false, "WhisperBridge class is registered (GDExtension loaded: build.ps1 + godot --import first)")
		_finish()
		return
	if model_path == "" or wav_dir == "" or not FileAccess.file_exists(model_path) or not DirAccess.dir_exists_absolute(wav_dir):
		ok(false, "arguments --model=<file> and --wav-dir=<folder> point at existing paths")
		_finish()
		return
	var ef: String = wav_dir.path_join("expected.json")
	if FileAccess.file_exists(ef):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ef))
		if parsed is Dictionary:
			expected = parsed
	ok(not expected.is_empty(), "expected.json loaded (%d clips)" % expected.size())
	_selfcheck()
	await _test_no_model()
	await _test_bad_model_files()
	await _test_normal()
	await _test_bad_input()
	await _test_options()
	await _test_lifecycle()
	await _test_abort()
	await _test_concurrent()
	if _arg("--bench") != "" or "--bench" in OS.get_cmdline_user_args():
		await _bench()
	_finish()


func _finish() -> void:
	_trace("done")
	print("== native_bridge: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers
func _bridge() -> Object:
	return ClassDB.instantiate("WhisperBridge")


func _wav(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(wav_dir.path_join(name))


func _tokens(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "'":
			cur += ch
		elif cur != "":
			out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


## How many words of `sentence` were heard in `heard`.
func hits(sentence: String, heard: String) -> int:
	var h: PackedStringArray = _tokens(heard)
	var n: int = 0
	for t in _tokens(sentence):
		if t in h:
			n += 1
	return n


## Reasons why a result dictionary breaks the contract (empty = fine).
func contract_problems(r: Dictionary, duration_expected: float = -1.0) -> PackedStringArray:
	var bad := PackedStringArray()
	for k in ["ok", "error", "text", "duration", "ms", "model", "words"]:
		if not r.has(k):
			bad.append("missing key " + k)
	if not bad.is_empty():
		return bad
	if not (r["words"] is Array):
		bad.append("words is not an Array")
		return bad
	var prev_start: float = -1.0
	for w in r["words"]:
		if not (w is Dictionary) or not w.has_all(["w", "p", "start", "end"]):
			bad.append("word without w/p/start/end")
			continue
		var p: float = float(w["p"])
		if p < 0.0 or p > 1.0:
			bad.append("p out of 0..1: %f" % p)
		if not (float(w["start"]) < float(w["end"])):
			bad.append("start >= end for '%s'" % str(w["w"]))
		if float(w["start"]) < prev_start:
			bad.append("start not monotonic at '%s'" % str(w["w"]))
		prev_start = float(w["start"])
		if str(w["w"]).strip_edges() == "":
			bad.append("empty word")
	if duration_expected >= 0.0 and absf(float(r["duration"]) - duration_expected) > 0.1:
		bad.append("duration %f != %f" % [float(r["duration"]), duration_expected])
	return bad


func _selfcheck() -> void:
	# the checkers must be able to fail: wrong text, broken words
	ok(hits("I would like a cup of coffee, please.", "the weather is nice") < 5, "selfcheck FAIL-as-expected: wrong text has < 5 hits")
	ok(hits("I would like a cup of coffee, please.", "i would like a cup of coffee please") == 8, "selfcheck: right text has 8 hits")
	var broken: Dictionary = {"ok": true, "error": "", "text": "x", "duration": 1.0, "ms": 5, "model": "m", "words": [
		{"w": "a", "p": 1.5, "start": 0.2, "end": 0.1}, {"w": "b", "p": 0.5, "start": 0.05, "end": 0.3}]}
	ok(contract_problems(broken).size() >= 3, "selfcheck FAIL-as-expected: broken words are rejected (%d problems)" % contract_problems(broken).size())
	ok(contract_problems({"ok": true}).size() > 0, "selfcheck FAIL-as-expected: missing keys are rejected")


func _transcribe(b: Object, file: String, lang: String = "en", opts: Dictionary = {}) -> Dictionary:
	_trace("transcribe %s lang='%s' opts=%s" % [file, lang, str(opts)])
	return b.transcribe(_wav(file), lang, opts)


func _raw(b: Object, label: String, wav: PackedByteArray, lang: String = "en") -> Dictionary:
	_trace("transcribe %s (%d bytes)" % [label, wav.size()])
	return b.transcribe(wav, lang, {})


func _load(b: Object, path: String) -> int:
	_trace("load_model " + path.get_file())
	return int(b.load_model(path))


# ---------------------------------------------------------------- tests
func _test_no_model() -> void:
	print("[no model loaded]")
	_trace("section no model loaded")
	var b: Object = _bridge()
	var v: String = str(b.call("version"))
	ok(v != "" and v.begins_with("bridge ") and v.contains("whisper.cpp"), "version() is '%s'" % v)
	ok(str(_bridge().call("version")) == v, "version() is stable across instances")
	ok(not b.is_loaded(), "is_loaded() false before load_model")
	ok(str(b.model_file()) == "", "model_file() empty before load_model")
	var r: Dictionary = _transcribe(b, "coffee.wav")
	ok(not r["ok"] and r["error"] == "no_model", "transcribe without a model -> no_model (got '%s')" % str(r.get("error")))
	ok(contract_problems(r).is_empty(), "no_model result keeps the result shape")
	ok(_load(b, "") != OK and not b.is_loaded(), "load_model('') fails")
	ok(_load(b, wav_dir.path_join("does_not_exist.bin")) != OK and not b.is_loaded(), "load_model(missing file) fails")
	b.unload()
	ok(not b.is_loaded(), "unload() without a model is harmless")


func _test_bad_model_files() -> void:
	print("[broken model files]")
	_trace("section broken model files")
	var b: Object = _bridge()
	var full: PackedByteArray = FileAccess.get_file_as_bytes(model_path)
	ok(full.size() > 1000000, "model file read (%d bytes)" % full.size())
	var folder: String = "user://test_native_bridge"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	# name -> [what check_model must say]; every damaged file must be refused before whisper.cpp sees it
	var cases: Dictionary = {
		"half.bin": "truncated",
		"tail_cut.bin": "truncated",
		"header_only.bin": "truncated",
		"empty.bin": "too_small",
		"garbage.bin": "bad_magic",
		"wrong_magic.bin": "bad_magic",
		"extra_tail.bin": "truncated",
	}
	for fname in cases.keys():
		var data: PackedByteArray
		match fname:
			"half.bin": data = full.slice(0, full.size() / 2)
			"tail_cut.bin": data = full.slice(0, full.size() - 1000)
			"header_only.bin": data = full.slice(0, 64)
			"empty.bin": data = PackedByteArray()
			"garbage.bin": data = Crypto.new().generate_random_bytes(200000)
			"wrong_magic.bin":
				data = full.duplicate()
				data[0] = 0
				data[1] = 0
				data[2] = 0
				data[3] = 0
			_:
				data = full.duplicate()
				data.append_array(PackedByteArray([1, 2, 3]))
		_trace("write model case " + fname)
		var p: String = folder.path_join(fname)
		var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
		f.store_buffer(data)
		f.close()
		data = PackedByteArray()
		var gp: String = ProjectSettings.globalize_path(p)
		_trace("check_model " + fname)
		var why: String = str(b.call("check_model", gp))
		ok(why == str(cases[fname]), "check_model(%s) = '%s' (expected '%s')" % [fname, why, str(cases[fname])])
		var err: int = _load(b, gp)
		ok(err != OK and not b.is_loaded(), "load_model(%s) fails without crashing (err %d)" % [fname, err])
		var r: Dictionary = _transcribe(b, "coffee.wav")
		ok(not r["ok"] and r["error"] == "no_model", "transcribe after the failed load -> no_model (%s)" % fname)
		DirAccess.remove_absolute(gp)
	_trace("check_model of the good model")
	ok(str(b.call("check_model", model_path)) == "ok", "check_model(good model) = ok")
	ok(str(b.call("check_model", wav_dir.path_join("nope.bin"))) == "cant_open", "check_model(missing file) = cant_open")
	full = PackedByteArray()
	ok(_load(b, model_path) == OK and b.is_loaded(), "a good model loads after the failed ones")
	b.unload()


func _test_normal() -> void:
	print("[normal transcription]")
	_trace("section normal transcription")
	var b: Object = _bridge()
	var t0: int = Time.get_ticks_msec()
	ok(_load(b, model_path) == OK, "load_model(base.en-q5_1) OK (%d ms)" % (Time.get_ticks_msec() - t0))
	ok(b.is_loaded() and str(b.model_file()) == model_path.get_file(), "is_loaded() and model_file() = %s" % str(b.model_file()))
	var sentence: String = "I would like a cup of coffee, please."
	var r: Dictionary = _transcribe(b, "coffee.wav")
	print("    heard: ", r.get("text"), "  ms=", r.get("ms"))
	ok(r["ok"] and r["error"] == "", "coffee.wav ok:true, error ''")
	ok(hits(sentence, str(r["text"])) >= 5, "coffee.wav: %d of 8 words heard (>= 5)" % hits(sentence, str(r["text"])))
	ok(int(r["ms"]) > 0, "ms > 0 (%d)" % int(r["ms"]))
	ok(contract_problems(r, 2.5).is_empty(), "coffee.wav words: p in 0..1, start < end, starts increasing, duration 2.5 s: %s" % str(contract_problems(r, 2.5)))
	ok(r["words"].size() >= 5 and str(r["model"]) == model_path.get_file(), "%d words, model name reported" % r["words"].size())
	var joined: String = ""
	for w in r["words"]:
		joined += str(w["w"]) + " "
	ok(hits(sentence, joined) >= 5, "the words array carries the same words as text")
	# the same sentence in other formats: 16 kHz, 8 kHz, 44.1 kHz stereo, very quiet (peak about 0.03)
	for f in ["coffee_16k.wav", "coffee_8k.wav", "coffee_44k_stereo.wav", "coffee_quiet.wav"]:
		var rr: Dictionary = _transcribe(b, f)
		ok(rr["ok"] and hits(sentence, str(rr["text"])) >= 5, "%s: %d of 8 words (heard '%s')" % [f, hits(sentence, str(rr["text"])), str(rr["text"])])
		ok(contract_problems(rr).is_empty(), "%s: result contract %s" % [f, str(contract_problems(rr))])
	# more sentences
	var total_hit: int = 0
	var total_words: int = 0
	for i in range(7):
		var cname: String = "s%d.wav" % i
		var s: String = str(expected.get(cname, ""))
		var rs: Dictionary = _transcribe(b, cname)
		var h: int = hits(s, str(rs["text"]))
		total_hit += h
		total_words += _tokens(s).size()
		ok(rs["ok"] and h * 10 >= _tokens(s).size() * 6, "%s: %d of %d words (heard '%s')" % [cname, h, _tokens(s).size(), str(rs["text"])])
	print("    sentences total: %d of %d words" % [total_hit, total_words])
	ok(total_hit * 100 >= total_words * 80, "all sentences together: >= 80 percent of the words heard")
	# long clip (27.5 s): one window, still ok
	var rl: Dictionary = _transcribe(b, "long27.wav")
	ok(rl["ok"] and rl["words"].size() > 20 and contract_problems(rl).is_empty(), "long27.wav: %d words in %d ms" % [rl["words"].size(), int(rl["ms"])])
	ok(float(rl["duration"]) > 27.0, "long27.wav reports its real duration (%f)" % float(rl["duration"]))
	# silence and tiny sounds -> empty result, no error
	for f in ["silence.wav", "tiny_noise.wav", "short.wav"]:
		var rz: Dictionary = _transcribe(b, f)
		ok(rz["ok"] and rz["text"] == "" and rz["words"].is_empty() and rz["error"] == "", "%s -> ok:true, no text, no words" % f)
	_trace("unload")
	b.unload()


func _test_bad_input() -> void:
	print("[bad input]")
	_trace("section bad input")
	var b: Object = _bridge()
	_load(b, model_path)
	for f in ["empty.wav", "garbage.wav", "truncated.wav"]:
		var r: Dictionary = _transcribe(b, f)
		ok(not r["ok"] and r["error"] == "bad_wav", "%s -> bad_wav (got '%s')" % [f, str(r.get("error"))])
		ok(contract_problems(r).is_empty() and r["words"].is_empty(), "%s: result keeps its shape" % f)
	var r0: Dictionary = _raw(b, "0 bytes", PackedByteArray())
	ok(not r0["ok"] and r0["error"] == "bad_wav", "0-byte array -> bad_wav")
	var r3: Dictionary = _raw(b, "3 bytes", PackedByteArray([1, 2, 3]))
	ok(not r3["ok"] and r3["error"] == "bad_wav", "3 bytes -> bad_wav")
	var hdr: PackedByteArray = _wav("coffee.wav").slice(0, 44)
	var rh: Dictionary = _raw(b, "header only", hdr)
	ok(not rh["ok"] and rh["error"] == "bad_wav", "header only (data size lies) -> bad_wav")
	for lang in ["ja", "", "fr", "EN"]:
		var rl: Dictionary = _transcribe(b, "coffee.wav", lang)
		ok(not rl["ok"] and rl["error"] == "bad_lang", "lang '%s' -> bad_lang" % lang)
	# a streamed WAV (data size 0xFFFFFFFF) is read to the end of the file
	var raw: PackedByteArray = _wav("coffee.wav")
	var idx: int = -1
	for i in range(12, 200):
		if raw[i] == 0x64 and raw[i + 1] == 0x61 and raw[i + 2] == 0x74 and raw[i + 3] == 0x61:
			idx = i
			break
	ok(idx > 0, "found the data chunk at %d" % idx)
	if idx > 0:
		var streamed: PackedByteArray = raw.duplicate()
		for k in range(4):
			streamed[idx + 4 + k] = 0xFF
		var rs: Dictionary = _raw(b, "streamed wav", streamed)
		ok(rs["ok"] and hits("I would like a cup of coffee, please.", str(rs["text"])) >= 5, "streamed WAV (size 0xFFFFFFFF) is accepted")
	_trace("unload")
	b.unload()


func _test_options() -> void:
	print("[options]")
	_trace("section options")
	var b: Object = _bridge()
	_load(b, model_path)
	var sentence: String = "I would like a cup of coffee, please."
	var r2: Dictionary = _transcribe(b, "coffee.wav", "en", {"beam": 2})
	ok(r2["ok"] and hits(sentence, str(r2["text"])) >= 5, "beam 2: %d of 8 words (ms %d)" % [hits(sentence, str(r2["text"])), int(r2["ms"])])
	var r9: Dictionary = _transcribe(b, "coffee.wav", "en", {"beam": 99, "max_seconds": 1000, "trim": false})
	ok(r9["ok"] and hits(sentence, str(r9["text"])) >= 5, "out-of-range beam/max_seconds are clamped, trim=false works")
	var rt: Dictionary = _transcribe(b, "coffee.wav", "en", {"token_timestamps": false})
	ok(rt["ok"] and contract_problems(rt).is_empty() and rt["words"].size() >= 5, "token_timestamps=false still gives ordered word times")
	var rm: Dictionary = _transcribe(b, "long27.wav", "en", {"max_seconds": 3.0})
	ok(rm["ok"] and float(rm["duration"]) > 27.0 and rm["words"].size() < 15, "max_seconds 3: only the start is transcribed (%d words)" % rm["words"].size())
	var rtr: Dictionary = _transcribe(b, "coffee.wav", "en", {"trim": true})
	var first_start: float = float(rtr["words"][0]["start"]) if rtr["words"].size() > 0 else -1.0
	ok(first_start >= 0.0 and first_start < 1.5, "trimmed audio keeps times relative to the original file (first word at %f s)" % first_start)
	_trace("unload")
	b.unload()


func _test_lifecycle() -> void:
	print("[load / unload]")
	_trace("section load / unload")
	var b: Object = _bridge()
	ok(_load(b, model_path) == OK and _load(b, model_path) == OK, "loading twice replaces the model")
	b.unload()
	ok(not b.is_loaded() and str(b.model_file()) == "", "unload(): not loaded, no model file name")
	var r: Dictionary = _transcribe(b, "coffee.wav")
	ok(not r["ok"] and r["error"] == "no_model", "transcribe after unload -> no_model")
	ok(_load(b, model_path) == OK, "reload after unload works")
	b.abort() # nothing is running: must not affect the next transcription
	var r2: Dictionary = _transcribe(b, "coffee.wav")
	ok(r2["ok"] and hits("I would like a cup of coffee, please.", str(r2["text"])) >= 5, "abort() while idle does not spoil the next transcription")
	b = null
	ok(true, "a bridge object can be freed after use")


func _thread_transcribe(b: Object, file: String, out: Dictionary) -> void:
	_trace("thread: transcribe " + file)
	var t0: int = Time.get_ticks_msec()
	out["result"] = b.transcribe(_wav(file), "en", {})
	out["done_at"] = Time.get_ticks_msec()
	out["started_at"] = t0


func _test_abort() -> void:
	print("[abort]")
	_trace("section abort")
	var b: Object = _bridge()
	_load(b, model_path)
	var out: Dictionary = {}
	var th := Thread.new()
	_trace("start thread for long27.wav")
	th.start(_thread_transcribe.bind(b, "long27.wav", out))
	await get_tree().create_timer(0.3).timeout
	var t_abort: int = Time.get_ticks_msec()
	_trace("abort() while the thread transcribes long27.wav")
	b.abort()
	var waited: int = 0
	while not out.has("result") and waited < 6000:
		await get_tree().create_timer(0.05).timeout
		waited += 50
	th.wait_to_finish()
	var res: Dictionary = out.get("result", {})
	var took: int = int(out.get("done_at", Time.get_ticks_msec() + 99999)) - t_abort
	ok(not res.is_empty() and not res["ok"] and res["error"] == "aborted", "abort() after 300 ms -> error 'aborted' (got '%s')" % str(res.get("error")))
	ok(took <= 2000, "the aborted transcription ended %d ms after abort() (<= 2000)" % took)
	ok(contract_problems(res).is_empty(), "aborted result keeps its shape")
	var r2: Dictionary = _transcribe(b, "coffee.wav")
	ok(r2["ok"] and hits("I would like a cup of coffee, please.", str(r2["text"])) >= 5, "a normal transcription works right after an abort")
	_trace("unload")
	b.unload()


func _test_concurrent() -> void:
	print("[two threads at once]")
	_trace("section two threads at once")
	var b: Object = _bridge()
	_load(b, model_path)
	# time of one transcription alone (the "ms" of a call that had to wait includes the waiting, so it cannot be summed)
	var solo: Dictionary = {}
	for f in ["coffee.wav", "s1.wav"]:
		_transcribe(b, f)                      # first run after a load is slower (warm-up): not used
		solo[f] = int(_transcribe(b, f)["ms"])
	for round_no in range(2):
		var fa: String = "coffee.wav" if round_no == 0 else "s1.wav"
		var fb: String = "s1.wav" if round_no == 0 else "coffee.wav"
		var oa: Dictionary = {}
		var ob: Dictionary = {}
		var ta := Thread.new()
		var tb := Thread.new()
		_trace("start two threads %s + %s (round %d)" % [fa, fb, round_no])
		ta.start(_thread_transcribe.bind(b, fa, oa))
		tb.start(_thread_transcribe.bind(b, fb, ob))
		var waited: int = 0
		while (not oa.has("result") or not ob.has("result")) and waited < 30000:
			await get_tree().create_timer(0.05).timeout
			waited += 50
		ta.wait_to_finish()
		tb.wait_to_finish()
		var ra: Dictionary = oa.get("result", {"ok": false, "text": ""})
		var rb: Dictionary = ob.get("result", {"ok": false, "text": ""})
		var ha: int = hits(str(expected.get(fa, "")), str(ra["text"]))
		var hb: int = hits(str(expected.get(fb, "")), str(rb["text"]))
		var cross_a: int = hits(str(expected.get(fb, "")), str(ra["text"]))
		ok(ra["ok"] and rb["ok"], "round %d: both transcriptions finished ok" % round_no)
		ok(ha * 10 >= _tokens(str(expected.get(fa, ""))).size() * 6 and hb * 10 >= _tokens(str(expected.get(fb, ""))).size() * 6, "round %d: each thread got its own sentence (%s %d, %s %d)" % [round_no, fa, ha, fb, hb])
		ok(cross_a < ha, "round %d: results are not mixed up (own %d > other %d)" % [round_no, ha, cross_a])
		# they ran one after the other: the two time spans do not overlap by more than a little
		var a0: int = int(oa.get("started_at", 0))
		var a1: int = int(oa.get("done_at", 0))
		var b0: int = int(ob.get("started_at", 0))
		var b1: int = int(ob.get("done_at", 0))
		var wall: int = maxi(a1, b1) - mini(a0, b0)
		var solo_sum: int = int(solo[fa]) + int(solo[fb])
		ok(wall * 100 >= solo_sum * 75, "round %d: transcriptions were serialized (wall %d ms >= 75 percent of the two solo times %d ms)" % [round_no, wall, solo_sum])
	_trace("unload")
	b.unload()


func _bench() -> void:
	print("[bench: reference times on this PC, not asserted]")
	_trace("section bench: reference times on this PC, not asserted")
	var models: Array = [model_path]
	if tiny_path != "" and FileAccess.file_exists(tiny_path):
		models.append(tiny_path)
	for mp in models:
		var b: Object = _bridge()
		var t0: int = Time.get_ticks_msec()
		_load(b, mp)
		var load_ms: int = Time.get_ticks_msec() - t0
		var times: Array = []
		for i in range(7):
			for rep in range(3):
				var r: Dictionary = _transcribe(b, "s%d.wav" % i)
				times.append(int(r["ms"]))
		times.sort()
		print("bench model=%s load_ms=%d runs=%d min_ms=%d median_ms=%d max_ms=%d" % [str(mp).get_file(), load_ms, times.size(), times[0], times[times.size() / 2], times[times.size() - 1]])
