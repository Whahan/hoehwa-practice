extends RefCounted
## Phone version of POST /stt and POST /score (docs/v201_design.md 2.3, docs/v200_phone_design.md 1.5 / 1.6): the speech is
## recognised by the on-device whisper model (WhisperBridge) and scored by ScoreCore, the GDScript copy of the server's score_en.
##
## Flow (handle is a coroutine; the main thread only does the cheap parts and keeps running its frames):
##   1) input checks in the server's order (lang, empty target, base64, WAV, 30 s cut)      [main]
##   2) SttEngine (one thread) loads the model when needed and runs transcribe              [engine thread]
##   3) 12 s after the engine started the job: cancel_job() = abort() + stt_timeout          [main, polls every frame]
##   4) the words get map_p (p from score_params.json) and the D-1 time clean-up, then
##      /stt -> {text, words, duration}, /score -> ScoreCore.score_en(..., ok_prob) + map_final    [main]
## Two time-outs in a row switch the phone scoring off (pref `stt_phone_off`); one success in between starts the count again.
##
## LocalApi loads this file by path (no class_name): static handle / is_available / unavailable_reason (+ the `_for` forms).
## This file writes no log lines: nothing that was said, scored or sent leaves it (X-7). stats() holds numbers and codes only.

const STT_TIMEOUT_SEC := 12.0
const IDLE_UNLOAD_SEC := 90.0
const MAX_AUDIO_SEC := 30.0
## A job that the engine has not started (a load or an earlier job in front of it) after this long is given up too.
const QUEUE_WAIT_SEC := 36.0
const PARAMS_PATH := "res://data/score_params.json"
const PREF_PHONE_OFF := "stt_phone_off"
const OFF_AFTER_TIMEOUTS := 2
const MAX_B64_CHARS := 16 * 1024 * 1024 ## the server's MAX_AUDIO_B64
const RECENT_MAX := 20
const SAMPLES_MAX := 200
const PATHS := ["/stt", "/score"]

const TEXT_PAUSED := "앱이 잠시 멈춰서 채점을 끝내지 못했어요. 다시 말해 보세요."
const TEXT_PHONE_OFF := "이 폰에서 채점이 두 번 연속 너무 오래 걸려서 폰 채점을 껐어요. 설정 > 음성 인식에서 다시 켤 수 있어요."
const TEXT_NO_AUDIO := "녹음된 소리가 없어요. 다시 녹음해 주세요."
const TEXT_BAD_B64 := "오디오 데이터를 읽을 수 없어요."
const TEXT_BAD_WAV := "오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요."
const TEXT_TOO_BIG := "녹음 파일이 너무 커요. 60초 이내로 짧게 녹음해 주세요."
const TEXT_BAD_LANG := "lang은 'en' 또는 'ja'여야 해요."

## Tests: () -> an object with the WhisperBridge functions (a fake). Not valid = ClassDB.instantiate("WhisperBridge").
## A factory that returns null counts as "the engine is missing".
static var bridge_factory: Callable = Callable()
## Tests: another score_params.json (a user:// or absolute path).
static var params_path_override: String = ""
## Tests: () -> seconds (float). Used for the time-out, the idle unload and the engine's job start stamp.
static var clock: Callable = Callable()

static var _consec_timeouts: int = 0
static var _b64_rx: RegEx = null
static var _st: Dictionary = {"runs": 0, "ok": 0, "timeouts": 0, "engine_err": 0, "aborted": 0, "stt_ms": [], "audio_ms": [], "rtf": [], "recent": []}


# ================================================================================================ availability
## {err_code, text_ko} of what stops the phone from serving /stt and /score now; err_code "" = it can.
static func unavailable_reason() -> Dictionary:
	if not _engine_present():
		return _why("engine_missing")
	if _phone_off():
		return {"err_code": "engine_error", "text_ko": TEXT_PHONE_OFF}
	match ModelStore.state(ModelStore.active_id()):
		"ready":
			return {"err_code": "", "text_ko": ""}
		"corrupt":
			return _why("model_corrupt")
	return _why("model_missing")


static func is_available() -> bool:
	return str(unavailable_reason().get("err_code", "")) == ""


static func unavailable_reason_for(path: String, _query: Dictionary, body: Dictionary) -> Dictionary:
	if not (path in PATHS) or _lang_of(body) != "en":
		return _why("not_on_phone")
	return unavailable_reason()


static func is_available_for(path: String, query: Dictionary, body: Dictionary) -> bool:
	return str(unavailable_reason_for(path, query, body).get("err_code", "")) == ""


static func _why(code: String) -> Dictionary:
	return {"err_code": code, "text_ko": Route.text_for(code)}


static func _lang_of(body: Dictionary) -> String:
	var v: Variant = body.get("lang", "en")
	return v if v is String else ""


static func _phone_off() -> bool:
	var v: Variant = Store.prefs.get(PREF_PHONE_OFF, false)
	return typeof(v) == TYPE_BOOL and bool(v)


static func _engine_present() -> bool:
	if bridge_factory.is_valid():
		return bridge_factory.call() is Object
	return ClassDB.can_instantiate("WhisperBridge")


## The phone and the model is ready: start loading it in the background (nothing happens otherwise). Never waits.
static func warm() -> void:
	if not Route.is_phone() or not is_available():
		return
	_engine().request_load(ModelStore.path_of(ModelStore.active_id()))


# ================================================================================================ params
## score_params.json after the reading rules (docs/v201_design.md 2.3): anything wrong, another model, or a tiny model gives the
## identity maps, ok_prob 0.45, beam 1 and degraded = true. Keys: calibrated, state ("calibrated"|"uncalibrated"), degraded,
## ok_prob, beam, p_map, final_map, model_id, date, report, tiny.
static func params() -> Dictionary:
	var model_id: String = ModelStore.active_id()
	var out: Dictionary = {
		"calibrated": false, "state": "uncalibrated", "degraded": true, "ok_prob": ScoreCore.OK_PROB, "beam": 1,
		"p_map": [[0.0, 0.0], [1.0, 1.0]], "final_map": [[0, 0], [100, 100]], "model_id": model_id, "date": "", "report": {},
		"tiny": model_id.contains("tiny"),
	}
	if bool(out["tiny"]):
		return out
	var path: String = params_path_override if params_path_override != "" else PARAMS_PATH
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var txt: String = f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK or not (j.data is Dictionary):
		return out
	var d: Dictionary = j.data
	if not _is_num(d.get("v")) or float(d["v"]) != 1.0:
		return out
	if str(d.get("model_id", "")) != model_id or typeof(d.get("model_id")) != TYPE_STRING:
		return out
	if typeof(d.get("calibrated")) != TYPE_BOOL or not bool(d["calibrated"]):
		return out
	if not _is_num(d.get("ok_prob")):
		return out
	var okp: float = float(d["ok_prob"])
	if is_nan(okp) or not (okp > 0.2 and okp < 0.8):
		return out
	if not _is_num(d.get("beam")):
		return out
	var bf: float = float(d["beam"])
	if bf != floor(bf) or not (int(bf) in [1, 2, 3]):
		return out
	if not ScoreCore.valid_p_map(d.get("p_map")):
		return out
	var fm: Array = [[0, 0], [100, 100]]
	if d.has("final_map"):
		if not ScoreCore.valid_final_map(d["final_map"]):
			return out
		fm = d["final_map"]
	out["calibrated"] = true
	out["state"] = "calibrated"
	out["degraded"] = false
	out["ok_prob"] = okp
	out["beam"] = int(bf)
	out["p_map"] = d["p_map"]
	out["final_map"] = fm
	out["date"] = str(d.get("date", ""))
	out["report"] = d["report"] if d.get("report") is Dictionary else {}
	return out


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _degraded(p: Dictionary) -> Array:
	var out: Array = ["phoneme_off"]
	if bool(p["degraded"]):
		out.append("score_uncalibrated")
	if bool(p["tiny"]):
		out.append("stt_tiny_model")
	return out


# ================================================================================================ word times (D-1)
## D-1 (docs/v201_design.md 8.1), the one rule of the phone app and of phone_src/tools/calib_fit.py clean_word_times.
## words: [{w, p, start, end}] in transcription order, clip_sec: the length of the WAV in seconds.
##   1) a start / end that is not a finite number is 0   2) both are cut to [0, clip_sec]
##   3) from the first word on, start = max(start, the previous word's start)   4) end = max(end, start)
##   5) when a next word exists, end = min(end, the next word's cleaned start), an end below start becomes start
##   6) order, count, w and p stay; the times are not rounded. Returns new dictionaries (entries that are not dictionaries are no words).
static func tidy_words(words: Array, clip_sec: float) -> Array:
	var clip: float = clip_sec if (not is_nan(clip_sec) and not is_inf(clip_sec) and clip_sec > 0.0) else 0.0
	var kept: Array = []
	var starts: Array = []
	var ends: Array = []
	for it in words:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var a: float = minf(clip, maxf(0.0, _finite_or_zero(d.get("start"))))
		var b: float = minf(clip, maxf(0.0, _finite_or_zero(d.get("end"))))
		if not starts.is_empty():
			a = maxf(a, float(starts[starts.size() - 1]))
		b = maxf(b, a)
		kept.append(d)
		starts.append(a)
		ends.append(b)
	for i in range(ends.size() - 1):
		ends[i] = minf(float(ends[i]), float(starts[i + 1]))
		if float(ends[i]) < float(starts[i]):
			ends[i] = starts[i]
	var out: Array = []
	for i in kept.size():
		var c: Dictionary = (kept[i] as Dictionary).duplicate()
		c["start"] = float(starts[i])
		c["end"] = float(ends[i])
		out.append(c)
	return out


static func _finite_or_zero(v: Variant) -> float:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return 0.0
	var f: float = float(v)
	return 0.0 if (is_nan(f) or is_inf(f)) else f


# ================================================================================================ handle
## LocalApi contract: {ok, code, data, bytes, error, cancelled, err_code, err_body}. A coroutine.
static func handle(method: String, path: String, _query: Dictionary, body: Dictionary) -> Dictionary:
	if method.to_upper() != "POST" or not (path in PATHS):
		return LocalApi.fail("not_on_phone")
	var lang: String = _lang_of(body)
	if lang == "ja":
		return LocalApi.fail("not_on_phone")
	if lang != "en":
		return LocalApi.fail("bad_request", TEXT_BAD_LANG, 400)
	var target: String = ""
	if path == "/score":
		var tv: Variant = body.get("target", "")
		target = tv if tv is String else ""
		if target.strip_edges() == "":
			return LocalApi.fail("bad_request", ScoreCore.TARGET_EMPTY_TEXT, 400)
	var dec: Dictionary = _decode_audio(body.get("audio_b64", ""))
	if not bool(dec["ok"]):
		return LocalApi.fail("bad_request", str(dec["text"]), 400)
	return await _serve(path, dec["wav"], target, false)


## Transcribe and answer. `wav` is a WAV file (bytes); from_bench keeps the run out of the auto-off count.
static func _serve(path: String, wav: PackedByteArray, target: String, from_bench: bool) -> Dictionary:
	var prep: Dictionary = _prepare_wav(wav)
	if not bool(prep["ok"]):
		return LocalApi.fail("bad_request", TEXT_BAD_WAV, 400)
	var is_score: bool = path == "/score"
	if is_score and ScoreCore.en_words(target).is_empty():
		return LocalApi.fail("bad_request", ScoreCore.TARGET_EMPTY_TEXT, 400)
	var tr: Dictionary = await _transcribe(prep["wav"], float(prep["sec"]), from_bench)
	if not bool(tr["ok"]):
		return tr["fail"]
	var p: Dictionary = tr["params"]
	var mapped: Array = []
	for w in (tr["words"] as Array):
		var d: Dictionary = w
		mapped.append({"w": d["w"], "p": ScoreCore.map_p(float(d["p"]), p["p_map"]), "start": d["start"], "end": d["end"]})
	var words: Array = tidy_words(mapped, float(tr["duration"]))
	var text: String = str(tr["text"])
	if not is_score:
		return LocalApi.ok({"text": text, "words": words, "duration": float(tr["duration"])}, _degraded(p))
	var res: Dictionary = ScoreCore.score_en(target, words, text, float(p["ok_prob"]))
	if res.is_empty():
		return LocalApi.fail("bad_request", ScoreCore.TARGET_EMPTY_TEXT, 400)
	if not words.is_empty():
		res["score"] = ScoreCore.map_final(int(res["score"]), p["final_map"])
	var n_ok: int = 0
	for u in (res["units"] as Array):
		if bool((u as Dictionary).get("ok", false)):
			n_ok += 1
	_push_cap(_st["recent"], {"score": int(res["score"]), "n": (res["units"] as Array).size(), "ok": n_ok}, RECENT_MAX)
	return LocalApi.ok(res, _degraded(p))


## Returns {ok:true, text, words:[{w,p,start,end}], duration, params} or {ok:false, fail:<LocalApi.fail result>}.
static func _transcribe(wav: PackedByteArray, wav_sec: float, from_bench: bool) -> Dictionary:
	var why: Dictionary = unavailable_reason()
	if str(why.get("err_code", "")) != "":
		return {"ok": false, "fail": LocalApi.fail(str(why["err_code"]), str(why.get("text_ko", "")))}
	var ml: MainLoop = Engine.get_main_loop()
	if not (ml is SceneTree):
		return {"ok": false, "fail": LocalApi.fail("engine_error")}
	var tree: SceneTree = ml
	var model_id: String = ModelStore.active_id()
	var p: Dictionary = params()
	var eng: SttEngine = _engine()
	eng.request_load(ModelStore.path_of(model_id))
	_st["runs"] = int(_st["runs"]) + 1
	var wall0: int = Time.get_ticks_msec()
	var job: SttEngine.Job = eng.submit(wav, {"beam": int(p["beam"]), "max_seconds": MAX_AUDIO_SEC})
	var t0: float = _now()
	var timed_out: bool = false
	while not job.done:
		await tree.process_frame
		if job.done:
			break
		var started: float = eng.job_started_at(job)
		if started >= 0.0:
			timed_out = _now() - started >= STT_TIMEOUT_SEC
		else:
			timed_out = _now() - t0 >= QUEUE_WAIT_SEC
		if timed_out:
			break
	if timed_out:
		eng.cancel_job(job)
		_st["timeouts"] = int(_st["timeouts"]) + 1
		if not from_bench:
			_note_timeout()
		return {"ok": false, "fail": LocalApi.fail("stt_timeout")}
	var res: Dictionary = job.result
	if typeof(res.get("ok")) != TYPE_BOOL or not bool(res["ok"]):
		var e: String = str(res.get("error", ""))
		if e == "paused":
			_st["aborted"] = int(_st["aborted"]) + 1
			return {"ok": false, "fail": LocalApi.fail("engine_error", TEXT_PAUSED)}
		if e == "aborted" or e == "cancelled" or e == "shutdown":
			_st["aborted"] = int(_st["aborted"]) + 1
			return {"ok": false, "fail": LocalApi.fail("engine_error")}
		if e == "bad_wav":
			return {"ok": false, "fail": LocalApi.fail("bad_request", TEXT_BAD_WAV, 400)}
		_st["engine_err"] = int(_st["engine_err"]) + 1
		if e == "load_failed":
			ModelStore.mark_corrupt(model_id)
			return {"ok": false, "fail": LocalApi.fail("model_corrupt")}
		return {"ok": false, "fail": LocalApi.fail("engine_error")}
	var words: Array = []
	var wr: Variant = res.get("words")
	if wr is Array:
		for it in (wr as Array):
			if not (it is Dictionary) or not (it as Dictionary).has("w"):
				continue
			var d: Dictionary = it
			var pv: float = float(d["p"]) if _is_num(d.get("p")) else 0.0
			words.append({"w": str(d["w"]), "p": 0.0 if is_nan(pv) else pv,
				"start": float(d["start"]) if _is_num(d.get("start")) else NAN,
				"end": float(d["end"]) if _is_num(d.get("end")) else NAN})
	var dur: float = float(res["duration"]) if _is_num(res.get("duration")) else 0.0
	if is_nan(dur) or is_inf(dur) or dur <= 0.0:
		dur = wav_sec
	var ms: int = int(res["ms"]) if _is_num(res.get("ms")) else Time.get_ticks_msec() - wall0
	_consec_timeouts = 0
	_st["ok"] = int(_st["ok"]) + 1
	_push_cap(_st["stt_ms"], ms, SAMPLES_MAX)
	_push_cap(_st["audio_ms"], int(round(dur * 1000.0)), SAMPLES_MAX)
	if dur > 0.0:
		_push_cap(_st["rtf"], float(ms) / (dur * 1000.0), SAMPLES_MAX)
	var text: String = res["text"] if res.get("text") is String else ""
	return {"ok": true, "text": text, "words": words, "duration": dur, "params": p}


static func _note_timeout() -> void:
	_consec_timeouts += 1
	if _consec_timeouts >= OFF_AFTER_TIMEOUTS:
		_consec_timeouts = 0
		Store.set_pref(PREF_PHONE_OFF, true)


# ================================================================================================ audio input
## {ok:true, wav} or {ok:false, text}: the server's checks and Korean texts (decode_audio_b64). Invalid base64 is refused here
## because Godot prints an engine ERROR for it.
static func _decode_audio(v: Variant) -> Dictionary:
	var s: String = v if v is String else ""
	s = s.replace("\r", "").replace("\n", "").replace(" ", "").replace("\t", "")
	if s == "":
		return {"ok": false, "text": TEXT_NO_AUDIO}
	if s.length() > MAX_B64_CHARS:
		return {"ok": false, "text": TEXT_TOO_BIG}
	if _b64_rx == null:
		_b64_rx = RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}\\z")
	if s.length() % 4 != 0 or _b64_rx.search(s) == null:
		return {"ok": false, "text": TEXT_BAD_B64}
	var raw: PackedByteArray = Marshalls.base64_to_raw(s)
	if raw.is_empty():
		return {"ok": false, "text": TEXT_BAD_B64}
	return {"ok": true, "wav": raw}


## {riff, ok, rate, channels, bits, data_off, data_len}: the same strict chunk walk as the bridge (a data chunk that claims more
## than the file has is no WAV; size 0 or 0xFFFFFFFF = to the end of the file). riff = the RIFF/WAVE header is there.
static func _wav_info(w: PackedByteArray) -> Dictionary:
	var out: Dictionary = {"riff": false, "ok": false, "rate": 0, "channels": 0, "bits": 0, "data_off": 0, "data_len": 0}
	var n: int = w.size()
	if n < 44 or w.decode_u32(0) != 0x46464952 or w.decode_u32(8) != 0x45564157:
		return out
	out["riff"] = true
	var off: int = 12
	var have_fmt: bool = false
	while off + 8 <= n:
		var id: int = w.decode_u32(off)
		var sz: int = w.decode_u32(off + 4)
		var body: int = off + 8
		var remain: int = n - body
		if id == 0x20746D66: # "fmt "
			if sz < 16 or sz > remain:
				return out
			out["channels"] = w.decode_u16(body + 2)
			out["rate"] = w.decode_u32(body + 4)
			out["bits"] = w.decode_u16(body + 14)
			have_fmt = true
		elif id == 0x61746164: # "data"
			if not have_fmt:
				return out
			var dlen: int = sz
			if sz == 0 or sz == 0xFFFFFFFF:
				dlen = remain
			elif sz > remain:
				return out
			out["data_off"] = body
			out["data_len"] = dlen
			out["ok"] = int(out["rate"]) > 0 and int(out["channels"]) > 0 and int(out["bits"]) >= 8
			return out
		if sz > remain:
			return out
		off = body + sz + (sz & 1)
	return out


## {ok, wav, sec}: refuses what is no WAV, cuts a WAV longer than MAX_AUDIO_SEC to MAX_AUDIO_SEC (the header sizes are rewritten),
## sec = the length in seconds after the cut (0 when the header could not be read: the bridge then decides).
static func _prepare_wav(wav: PackedByteArray) -> Dictionary:
	var info: Dictionary = _wav_info(wav)
	if not bool(info["riff"]):
		return {"ok": false, "wav": wav, "sec": 0.0}
	if not bool(info["ok"]):
		return {"ok": true, "wav": wav, "sec": 0.0}
	var frame: int = (int(info["bits"]) / 8) * int(info["channels"])
	var rate: int = int(info["rate"])
	var frames: int = int(info["data_len"]) / frame
	var sec: float = float(frames) / float(rate)
	if sec <= MAX_AUDIO_SEC:
		return {"ok": true, "wav": wav, "sec": sec}
	var keep: int = int(MAX_AUDIO_SEC * float(rate)) * frame
	var off: int = int(info["data_off"])
	var cut: PackedByteArray = wav.slice(0, off + keep)
	cut.encode_u32(4, cut.size() - 8)
	cut.encode_u32(off - 4, keep)
	return {"ok": true, "wav": cut, "sec": MAX_AUDIO_SEC}


# ================================================================================================ engine glue, stats
static func _engine() -> SttEngine:
	var e: SttEngine = SttEngine.get_or_create()
	e.bridge_factory = bridge_factory
	e.clock = clock
	e.idle_unload_sec = IDLE_UNLOAD_SEC
	return e


static func _now() -> float:
	if clock.is_valid():
		return float(clock.call())
	return float(Time.get_ticks_msec()) / 1000.0


static func _push_cap(arr: Array, v: Variant, cap: int) -> void:
	arr.append(v)
	while arr.size() > cap:
		arr.pop_front()


## Nearest-rank percentile (q in 0..1) of numbers; 0 for an empty list.
static func _pct(arr: Array, q: float) -> float:
	if arr.is_empty():
		return 0.0
	var s: Array = arr.duplicate()
	s.sort()
	var idx: int = clampi(int(ceil(q * float(s.size()))) - 1, 0, s.size() - 1)
	return float(s[idx])


## Numbers, codes and version texts only (never a word that was said or a target). Keys: runs, ok, timeouts, engine_err, aborted,
## load_count, unload_count, load_ms_first, stt_ms_p50, stt_ms_p95, stt_ms_max, audio_ms_p50, rtf_p50, rss_mb_before_load,
## rss_mb_after_load, rss_mb_peak, abort_patch, bridge_version, model_id, params_state, beam, phone_off, recent [{score, n, ok}].
static func stats() -> Dictionary:
	var eng: SttEngine = SttEngine.peek()
	var info: Dictionary = eng.info() if eng != null else {}
	var mem: Dictionary = eng.memory_now() if eng != null else {"peak_kb": 0, "rss_kb": 0}
	var p: Dictionary = params()
	var ms: Array = _st["stt_ms"]
	return {
		"runs": int(_st["runs"]), "ok": int(_st["ok"]), "timeouts": int(_st["timeouts"]), "engine_err": int(_st["engine_err"]),
		"aborted": int(_st["aborted"]),
		"load_count": int(info.get("load_calls", 0)), "unload_count": int(info.get("unload_calls", 0)),
		"load_ms_first": int(info.get("load_ms_first", 0)),
		"stt_ms_p50": int(_pct(ms, 0.5)), "stt_ms_p95": int(_pct(ms, 0.95)), "stt_ms_max": int(_pct(ms, 1.0)),
		"audio_ms_p50": int(_pct(_st["audio_ms"], 0.5)), "rtf_p50": snappedf(_pct(_st["rtf"], 0.5), 0.001),
		"rss_mb_before_load": _mb(int(info.get("rss_before_kb", 0))), "rss_mb_after_load": _mb(int(info.get("rss_after_kb", 0))),
		"rss_mb_peak": _mb(int(mem.get("peak_kb", 0))),
		"abort_patch": int(info.get("abort_patch", 0)), "bridge_version": str(info.get("bridge_version", "")),
		"model_id": str(p["model_id"]), "params_state": str(p["state"]), "beam": int(p["beam"]),
		"phone_off": 1 if _phone_off() else 0,
		"recent": (_st["recent"] as Array).duplicate(true),
	}


static func _mb(kb: int) -> int:
	return int(round(float(kb) / 1024.0)) if kb > 0 else 0


## Diagnostics: the same WAV and target n times through transcribe + score (nothing is written to StudyLog or Store, a time-out here
## does not count towards the auto-off). on_step(i, n) after every run. A coroutine.
## -> {n, ok, fail, ms_p50, ms_p95, ms_max, rss_mb_peak, seconds}
static func bench(wav: PackedByteArray, target: String, n: int, on_step: Callable = Callable()) -> Dictionary:
	var t0: int = Time.get_ticks_msec()
	var times: Array = []
	var okc: int = 0
	var bad: int = 0
	var total: int = maxi(n, 0)
	for i in total:
		var t1: int = Time.get_ticks_msec()
		var r: Dictionary = await _serve("/score", wav, target, true)
		times.append(Time.get_ticks_msec() - t1)
		if bool(r.get("ok", false)):
			okc += 1
		else:
			bad += 1
		if on_step.is_valid():
			on_step.call(i + 1, total)
	var eng: SttEngine = SttEngine.peek()
	var mem: Dictionary = eng.memory_now() if eng != null else {"peak_kb": 0}
	return {"n": total, "ok": okc, "fail": bad, "ms_p50": int(_pct(times, 0.5)), "ms_p95": int(_pct(times, 0.95)),
		"ms_max": int(_pct(times, 1.0)), "rss_mb_peak": _mb(int(mem.get("peak_kb", 0))),
		"seconds": snappedf(float(Time.get_ticks_msec() - t0) / 1000.0, 0.01)}


## Tests: join and drop the engine, forget every counter and every hook.
static func reset_for_tests() -> void:
	var e: SttEngine = SttEngine.peek()
	if e != null:
		e.shutdown() ## joins the thread and frees the node (also when it has not joined the tree yet: the deferred add_child runs first)
	_consec_timeouts = 0
	_st = {"runs": 0, "ok": 0, "timeouts": 0, "engine_err": 0, "aborted": 0, "stt_ms": [], "audio_ms": [], "rtf": [], "recent": []}
	bridge_factory = Callable()
	params_path_override = ""
	clock = Callable()
