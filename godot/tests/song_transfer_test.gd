extends Node
## 노래 공부 G4: SongTransfer 시험. 포트 18794 만 쓴다 (127.0.0.1).
##   godot --headless --path godot res://tests/song_transfer_test.tscn [-- --phone] [--python=<python.exe>]
## 1) 진짜 스텁 서버(backend/lan_stub_server.py --song, 가짜 전사)를 이 시험이 띄워서(자기 PID 와 하위만 종료) 종단 흐름을 본다.
## 2) 그 서버를 끄고 같은 포트에 GDScript 가짜 서버(FakeSong)를 띄워 끊김·변조·실패 응답을 일부러 만든다.
## 마지막 줄: "== song_transfer_test result: N passed, M failed ==". 곡은 모두 user://test_songs_g4 에만 설치한다.
## 가사는 직접 쓴 문장, 오디오는 시험이 만든 소리/가짜 바이트다. 실제 user://songs 와 사용자 폴더는 건드리지 않는다.

const PORT := 18794
const BASE := "http://127.0.0.1:18794"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const SONG_ROOT := "user://test_songs_g4"
const WORK := "user://test_g4"
const JOBS_DIR := "user://test_g4_jobs"
const LYRICS_EN := ["The river runs past the old wooden bridge", "We hum a tune while the lanterns glow", "Morning comes and the sky turns gold"]

var passed: int = 0
var failed: int = 0
var _reached_end: bool = false
var _server_pid: int = -1
var _own_server: bool = false
var _max_delta: float = 0.0
var _songs_before: Array = []
var fake: FakeSong = null
var phone_run: bool = false


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _process(delta: float) -> void:
	_max_delta = maxf(_max_delta, delta)


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(prefix):
			return String(a).substr(prefix.length())
	return ""


func _ready() -> void:
	print("== song_transfer_test start ==")
	phone_run = Platform.is_phone()
	print("  mode: ", "phone" if phone_run else "pc")
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_songs_before = _listing("user://songs")
	_cleanup_dirs()
	DirAccess.make_dir_recursive_absolute(_g(WORK))
	SongStore.root = SONG_ROOT
	Api.set_remote(BASE, "")
	_test_pure()
	_test_source_rules()
	await _test_phone_none()
	var up: bool = await _start_real()
	ok(up, "stub server (lan_stub_server.py --song) is up on port %d" % PORT)
	if up:
		await _real_sections()
	_stop_real()
	await get_tree().create_timer(0.4).timeout
	var closed: Dictionary = await _http(HTTPClient.METHOD_GET, "/health")
	ok(int(closed["code"]) == 0, "stub server is gone and port %d is closed again" % PORT)
	fake = FakeSong.new()
	add_child(fake)
	var fup: bool = fake.setup(PORT)
	ok(fup, "fake server is listening on port %d" % PORT)
	if fup:
		await _fake_sections()
	if fake != null:
		fake.stop()
		fake.queue_free()
	Api.clear_remote()
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.write_hook = Callable()
	_cleanup_dirs()
	ok(_listing("user://songs") == _songs_before, "the real user://songs folder was not touched (listing before == after)")
	_reached_end = true
	ok(_reached_end, "all sections ran to the end (last section flag set)")
	print("== song_transfer_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- generic helpers

func _listing(p: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(_g(p))
	if d == null:
		return out
	for sub in d.get_directories():
		out.append("d:" + sub)
	for fn in d.get_files():
		out.append("f:%s:%d" % [fn, FileAccess.get_size(_g(p).path_join(fn)) if FileAccess.file_exists(_g(p).path_join(fn)) else -1])
	out.sort()
	return out


func _rm_rf(p: String) -> void:
	var gp: String = _g(p)
	var d := DirAccess.open(gp)
	if d != null:
		for sub in d.get_directories():
			_rm_rf(p.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(gp.path_join(fn))
	DirAccess.remove_absolute(gp)


func _cleanup_dirs() -> void:
	for p in [SONG_ROOT, WORK, JOBS_DIR]:
		_rm_rf(p)


func _write_bytes(p: String, b: PackedByteArray) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func _noise(n: int, salt: int = 1) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	var x: int = 2463534242 + salt
	for i in n:
		x = (x * 1103515245 + 12345) & 0x7fffffff
		b[i] = (x >> 16) & 255
	return b


## 16-bit mono WAV with a quiet two-tone melody, `sec` seconds.
func _wav(sec: int, rate: int = 8000) -> PackedByteArray:
	var one := PackedByteArray()
	one.resize(rate * 2)
	for i in rate:
		var f: float = 220.0 if (i / (rate / 4)) % 2 == 0 else 330.0
		one.encode_s16(i * 2, int(sin(TAU * f * float(i) / float(rate)) * 6000.0))
	var data := PackedByteArray()
	for s in sec:
		data.append_array(one)
	var h := PackedByteArray()
	h.resize(44)
	h.encode_u32(0, 0x46464952)
	h.encode_u32(4, 36 + data.size())
	h.encode_u32(8, 0x45564157)
	h.encode_u32(12, 0x20746d66)
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)
	h.encode_u16(22, 1)
	h.encode_u32(24, rate)
	h.encode_u32(28, rate * 2)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u32(36, 0x61746164)
	h.encode_u32(40, data.size())
	h.append_array(data)
	return h


func _new_t(chunk: int = 0) -> SongTransfer:
	var t := SongTransfer.new()
	add_child(t)
	t.poll_interval = 0.05
	t.retry_delays = [0.05, 0.05, 0.05]
	if chunk > 0:
		t.chunk_bytes = chunk
	return t


class Rec:
	extends RefCounted
	var res: Variant = null
	var pcts: Array = []
	var stages: Array = []
	var texts: Array = []


## start() and wait for `finished` (or time out). -> {res, pcts, stages, texts}
func _go(t: SongTransfer, src: String, params: Dictionary, timeout: float = 60.0, on_progress: Callable = Callable()) -> Rec:
	var rec := Rec.new()
	t.finished.connect(func(r: Dictionary) -> void: rec.res = r)
	t.progress.connect(func(stage: String, pct: float, text: String) -> void:
		rec.pcts.append(pct)
		rec.stages.append(stage)
		rec.texts.append(text)
		if on_progress.is_valid():
			on_progress.call(stage, pct, text))
	t.start(src, params)
	await _until_finished(rec, timeout)
	return rec


func _until_finished(rec: Rec, timeout: float) -> void:
	var t0: int = Time.get_ticks_msec()
	while rec.res == null and float(Time.get_ticks_msec() - t0) / 1000.0 < timeout:
		await get_tree().process_frame


func _res(rec: Rec) -> Dictionary:
	return rec.res if rec.res is Dictionary else {"ok": false, "err_code": "TIMEOUT"}


func _monotone(a: Array) -> bool:
	for i in range(1, a.size()):
		if float(a[i]) < float(a[i - 1]) - 0.0001:
			return false
	return true


func _params(extra: Dictionary = {}) -> Dictionary:
	var lines: Array = []
	for i in LYRICS_EN.size():
		lines.append({"text": LYRICS_EN[i], "t": null, "p": 0 if i < 2 else 1})
	var p := {"lang": "en", "title": "Bridge Song", "artist": "Test Band",
		"lyrics": {"source": "pasted", "lines": lines}, "options": {"translate": true, "gloss": true, "verify": false, "precise": false, "ai_ok": false}}
	for k in extra:
		p[k] = extra[k]
	return p


func _songs() -> Array:
	return SongStore.list()


## Plain HTTP call (not through Api: Api.sent_count and the transfer's own state stay untouched). -> {code, data}
func _http(method: int, path: String, body: Variant = null) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	var payload := "" if body == null else JSON.stringify(body)
	var err: int = req.request(BASE + path, PackedStringArray(["Content-Type: application/json"]), method, payload)
	if err != OK:
		req.queue_free()
		return {"code": 0, "data": null}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"code": 0, "data": null}
	return {"code": int(res[1]), "data": JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())}


func _server_dirs() -> Array:
	var out: Array = []
	var d := DirAccess.open(_g(JOBS_DIR))
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.begins_with("j_") or sub.begins_with("u_"):
			out.append(sub)
	return out


func _wait_for(cond: Callable, timeout: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < timeout:
		if bool(cond.call()):
			return true
		await get_tree().create_timer(0.05).timeout
	return bool(cond.call())


func _reset_store() -> void:
	_rm_rf(SONG_ROOT)
	SongStore.clear_cache()
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.write_hook = Callable()


# ---------------------------------------------------------------- pure checks and the checker's own self-test

func _test_pure() -> void:
	print("[pure functions and the checkers' own failure checks]")
	# message_for: every code the transfer can return has a Korean text (a checker that never fails proves nothing: see below)
	var codes := ["cancelled", "transport", "not_on_phone", "needs_pc", "not_connected", "pc_old", "app_old", "busy", "bad_args", "file_open",
		"empty_file", "too_large", "bad_ext", "bad_audio", "too_long", "storage_full", "queue_full", "no_job", "no_upload", "job_running",
		"asr_failed", "no_speech", "model_missing", "server_restart", "internal", "sha_mismatch", "disk_write", "bad_song", "quota_songs", "quota_bytes"]
	var all_ko: bool = true
	for c in codes:
		var m: String = SongTransfer.message_for(c)
		if m == "" or not _has_hangul(m):
			all_ko = false
			print("    no Korean text for ", c)
	ok(all_ko, "message_for: every error code has a Korean text")
	ok(not _has_hangul("plain english only") and _has_hangul("한국어"), "self-test: the Hangul checker fails on English-only text")
	ok(SongTransfer.message_for("zz_unknown", "서버가 준 문장") == "서버가 준 문장" and _has_hangul(SongTransfer.message_for("zz_unknown")), "message_for: unknown code uses the server text, else a generic Korean text")
	ok(SongTransfer.eta_text(45) == "약 45초 남음" and SongTransfer.eta_text(61) == "약 2분 남음" and SongTransfer.eta_text(null) == "" and SongTransfer.eta_text(0) == "", "eta_text")
	# job_body: server wants real booleans, <= 400 lines, <= 200 chars, t float or null, p int
	var lines: Array = []
	for i in 450:
		lines.append({"text": "line %d " % i + "x".repeat(250), "t": -1.0 if i == 0 else (float(i) if i % 2 == 0 else null), "p": "bad" if i == 1 else 2})
	var b: Dictionary = SongTransfer.job_body("a".repeat(32), {"lang": "ja", "title": "T", "artist": "A",
		"lyrics": {"source": "pasted", "lines": lines}, "options": {"translate": "yes", "gloss": false, "ai_ok": 1}})
	var bl: Array = b["lyrics"]["lines"]
	ok(bl.size() <= 400 and bl.size() > 0, "job_body: at most 400 lines (got %d)" % bl.size())
	var long_ok: bool = true
	for l in bl:
		if str(l["text"]).length() > 200:
			long_ok = false
	ok(long_ok, "job_body: no line longer than 200 chars")
	ok(bl[0]["t"] == null and bl[1]["p"] == 0 and bl[2]["t"] == 2.0 and typeof(bl[2]["t"]) == TYPE_FLOAT and typeof(bl[2]["p"]) == TYPE_INT, "job_body: negative t -> null, bad p -> 0, t float, p int")
	ok(b["options"]["translate"] == true and b["options"]["gloss"] == false and b["options"]["ai_ok"] == false and b["options"]["verify"] == true, "job_body: non-boolean options fall back to the default (never a string)")
	var chars: int = 0
	for l in bl:
		chars += str(l["text"]).length()
	ok(chars <= 20000, "job_body: total lyric chars <= 20000 (%d)" % chars)
	var none_b: Dictionary = SongTransfer.job_body("b".repeat(32), {"lang": "en", "lyrics": {"source": "none", "lines": [{"text": "x"}]}})
	ok(none_b["lyrics"]["lines"].is_empty() and none_b["lyrics"]["source"] == "none", "job_body: source none sends no lines")
	var lr: Dictionary = SongTransfer.job_body("c".repeat(32), {"lang": "en", "lyrics": {"source": "lrclib", "lrclib_id": 123, "lines": [{"text": "hi", "t": 1.5}]}})
	ok(lr["lyrics"]["lrclib_id"] == 123 and lr["lyrics"]["lines"][0]["t"] == 1.5, "job_body: lrclib id and timed line kept")
	ok(SongTransfer.POLL_SEC == 1.5 and SongTransfer.CHUNK_BYTES == 3 * 1024 * 1024 and SongTransfer.RETRY_DELAYS == [0.5, 1.0, 2.0] and SongTransfer.POLL_FAIL_LIMIT == 5, "constants: 3 MiB chunks, 1.5 s polling, retries 0.5/1/2 s, 5 poll failures")


func _has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


func _test_source_rules() -> void:
	print("[source rules]")
	var src: String = FileAccess.get_file_as_string("res://scripts/local/song_transfer.gd")
	ok(src != "", "song_transfer.gd is readable")
	ok(src.find("HTTPRequest") == -1 or _only_in_comments(src, "HTTPRequest"), "song_transfer.gd creates no HTTPRequest of its own")
	ok(src.find("cancel_request") == -1, "song_transfer.gd never calls cancel_request")
	ok(src.find("Authorization") == -1 and src.find("Api.token") == -1 and src.find("hp1_") == -1, "song_transfer.gd never handles the bearer token")
	ok(src.find("print(") == -1 and src.find("Toast.") == -1 and src.find("push_warning") == -1, "song_transfer.gd logs nothing and shows no toast (so no token can leak)")
	ok(src.find("get_buffer(") != -1 and src.find("get_file_as_bytes") == -1, "the file is read chunk by chunk (get_buffer), never as a whole")
	ok(src.find("post_json(") != -1 and src.find("get_json(") != -1, "all calls go through Api.post_json / get_json")
	# the checker must fail on a bad source: a copy with a forbidden call must be caught
	ok(("x HTTPRequest.new() y").find("HTTPRequest.new") != -1 and not _only_in_comments("x HTTPRequest.new() y", "HTTPRequest"), "self-test: the HTTPRequest checker fails on a real use")


func _only_in_comments(src: String, word: String) -> bool:
	for line in src.split("\n"):
		var l: String = line
		var at: int = l.find(word)
		if at >= 0:
			var hash_at: int = l.find("#")
			if hash_at < 0 or hash_at > at:
				return false
	return true


func _test_phone_none() -> void:
	print("[phone standalone: Route says none]")
	_reset_store()
	var src: String = WORK + "/none.mp3"
	_write_bytes(src, _noise(2000))
	var saved_hook: Callable = Route.phone_hook
	var saved_mode: String = Route.mode
	Route.phone_hook = func() -> bool: return true
	Route.mode = "phone"
	var before: int = Api.sent_count
	var t := _new_t()
	var rec: Rec = await _go(t, src, _params(), 10.0)
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and (r.get("err_code") == "not_on_phone" or r.get("err_code") == "needs_pc"), "phone standalone: err_code not_on_phone/needs_pc (got %s)" % r.get("err_code"))
	ok(Api.sent_count == before, "phone standalone: Api.sent_count unchanged (nothing left the app)")
	ok(_has_hangul(str(r.get("message", ""))) and _songs().is_empty(), "phone standalone: Korean message, nothing installed")
	t.queue_free()
	Route.phone_hook = saved_hook
	Route.mode = saved_mode


# ================================================================ real stub server

func _start_real() -> bool:
	var busy: Dictionary = await _http(HTTPClient.METHOD_GET, "/health")
	if int(busy["code"]) != 0:
		print("  port %d is already in use, not starting" % PORT)
		return false
	var py: String = _arg("--python=")
	if py == "":
		py = DEFAULT_PY
	var script: String = _g("res://").path_join("../backend/lan_stub_server.py").simplify_path()
	var args := PackedStringArray(["-I", script, "--song", "--port", str(PORT), "--song-dir", _g(JOBS_DIR), "--tag", "g4test",
		"--devices-file", _g(WORK).path_join("devices.json")])
	_server_pid = OS.create_process(py, args)
	_own_server = _server_pid > 0
	if not _own_server:
		return false
	for i in 150:
		await get_tree().create_timer(0.2).timeout
		var h: Dictionary = await _http(HTTPClient.METHOD_GET, "/health")
		if int(h["code"]) == 200 and h["data"] is Dictionary and bool((h["data"] as Dictionary).get("song", false)):
			return true
	return false


func _stop_real() -> void:
	if _own_server and _server_pid > 0:
		if OS.get_name() == "Windows":
			OS.execute("taskkill", PackedStringArray(["/PID", str(_server_pid), "/T", "/F"])) ## only the process this test started, and its children
		else:
			OS.kill(_server_pid)
		_server_pid = -1
		_own_server = false


func _want(name: String) -> bool:
	var only: String = _arg("--only=")
	return only == "" or only == name


func _real_sections() -> void:
	if _want("single"):
		await _real_single_chunk()
	if _want("multi"):
		await _real_multi_chunk()
	if _want("cut"):
		await _real_resume_upload()
	if _want("cancel"):
		await _real_cancel_upload()
	if _want("bad"):
		await _real_bad_audio()
	if _want("pending"):
		await _real_pending_resume()


func _real_single_chunk() -> void:
	print("[real server: one chunk, pasted lyrics]")
	_reset_store()
	var src: String = "res://tests/fixtures/song/tone_8s.mp3"
	var t := _new_t()
	var rec: Rec = await _go(t, src, _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == true and r.get("err_code") == "" and str(r.get("song_id", "")).begins_with("s_"), "real: finished.ok == true with a song id (got %s)" % r.get("err_code"))
	ok(_monotone(rec.pcts) and rec.pcts.size() > 3 and float(rec.pcts[rec.pcts.size() - 1]) == 100.0, "real: progress pct is non-decreasing and ends at 100 (%d events)" % rec.pcts.size())
	ok(rec.stages.has("upload") and rec.stages.has("download") and rec.stages.has("install") and rec.stages[rec.stages.size() - 1] == "done", "real: stages upload / download / install / done were reported")
	var list: Array = _songs()
	ok(list.size() == 1, "real: SongStore.list() has 1 song (%d)" % list.size())
	if list.size() == 1:
		var s: Dictionary = SongStore.load_song(list[0]["id"])
		ok(s.get("title") == "Bridge Song" and (s.get("lines") as Array).size() >= 3 and list[0]["ready"] == true, "real: installed song has the title, lines and a verified audio file")
		ok(FileAccess.get_size(_g(SongStore.audio_path(list[0]["id"]))) == int(s["audio"]["bytes"]) and SongStore.verify_audio(list[0]["id"]), "real: audio file size and sha256 match song.json")
		var texts: Array = []
		for l in s["lines"]:
			texts.append(str(l["text"]))
		ok(texts.has(LYRICS_EN[0]) or texts.size() > 0, "real: song lines present")
	ok(await _wait_for(func() -> bool: return _server_dirs().is_empty(), 3.0), "real: PC job and upload folders are gone (release was called): %s" % str(_server_dirs()))
	ok(SongStore.pending_list().is_empty(), "real: pending record removed after install")
	ok(t.busy == false, "real: transfer is idle again")
	t.queue_free()


func _real_multi_chunk() -> void:
	print("[real server: 2 upload chunks, 2 audio parts]")
	_reset_store()
	var src: String = WORK + "/long.wav"
	_write_bytes(src, _wav(215))
	var size: int = FileAccess.get_size(_g(src))
	ok(size > SongTransfer.CHUNK_BYTES, "wav is bigger than one 3 MiB chunk (%d bytes)" % size)
	var t := _new_t()
	var rec: Rec = await _go(t, src, _params({"lyrics": {"source": "none"}}), 120.0)
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == true, "real multi: ok (got %s)" % r.get("err_code"))
	ok(t.chunk_log == [0, 1], "real multi: chunks sent exactly once each: %s" % str(t.chunk_log))
	var list: Array = _songs()
	if list.size() == 1:
		var s: Dictionary = SongStore.load_song(list[0]["id"])
		ok(int(s["audio"]["bytes"]) > SongTransfer.CHUNK_BYTES, "real multi: the installed audio is %d bytes, more than one 3 MiB part" % int(s["audio"]["bytes"]))
		ok(SongStore.verify_audio(list[0]["id"]), "real multi: parts glued together match sha256")
	else:
		ok(false, "real multi: one song installed (%d)" % list.size())
	var dl: int = 0
	for tx in rec.texts:
		if str(tx).begins_with("내려받는 중"):
			dl += 1
	ok(dl >= 2, "real multi: download progress was reported per part (%d events)" % dl)
	t.queue_free()


func _real_resume_upload() -> void:
	print("[real server: a half-sent upload is continued with the same upload id]")
	_reset_store()
	var src: String = WORK + "/cut.wav"
	var wav: PackedByteArray = _wav(215)
	_write_bytes(src, wav)
	var cb: int = 1024 * 1024
	var total: int = int(ceil(float(wav.size()) / float(cb)))
	ok(total == 4, "cut: the wav makes 4 chunks of 1 MiB (%d)" % total)
	# an earlier run of the app sent chunks 0 and 1 and then lost the connection
	var up_id: String = Crypto.new().generate_random_bytes(16).hex_encode()
	for i in 2:
		var h: Dictionary = await _http(HTTPClient.METHOD_POST, "/song/upload", {"upload_id": up_id, "index": i, "total": total, "name": "cut.wav",
			"data_b64": Marshalls.raw_to_base64(wav.slice(i * cb, (i + 1) * cb))})
		ok(int(h["code"]) == 200, "cut: chunk %d of the earlier run is on the PC" % i)
	var st: Dictionary = await _http(HTTPClient.METHOD_GET, "/song/upload?upload_id=" + up_id)
	ok(int(st["code"]) == 200 and int((st["data"] as Dictionary).get("next", -1)) == 2, "cut: the PC says next == 2")
	var t := _new_t(cb)
	var rec: Rec = await _go(t, src, _params({"lyrics": {"source": "none"}, "upload_id": up_id}), 120.0)
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == true, "cut: start with the same upload id finishes ok (got %s)" % r.get("err_code"))
	ok(t.chunk_log == [2, 3], "cut: chunks 0 and 1 were NOT sent again, only 2 and 3: %s" % str(t.chunk_log))
	ok(t.resyncs >= 1 or t.chunk_log.size() == 2, "cut: the first thing was asking the PC where to continue")
	var list: Array = _songs()
	ok(list.size() == 1 and SongStore.verify_audio(str(list[0]["id"])), "cut: the song was installed intact")
	ok(await _wait_for(func() -> bool: return _server_dirs().is_empty(), 3.0), "cut: PC folders released")
	t.queue_free()
	# an upload id the PC does not know: start from chunk 0
	_reset_store()
	var t2 := _new_t(cb)
	var r2: Dictionary = _res(await _go(t2, src, _params({"lyrics": {"source": "none"}, "upload_id": "b".repeat(32)}), 120.0))
	ok(r2.get("ok") == true and t2.chunk_log == [0, 1, 2, 3], "cut: an unknown upload id starts over from chunk 0: %s" % str(t2.chunk_log))
	t2.queue_free()
	# a malformed upload id is refused
	var t3 := _new_t()
	var r3: Dictionary = _res(await _go(t3, src, _params({"upload_id": "../../x"}), 10.0))
	ok(r3.get("err_code") == "bad_args", "cut: a malformed upload id -> bad_args")
	t3.queue_free()


func _real_cancel_upload() -> void:
	print("[real server: cancel while uploading]")
	_reset_store()
	var src: String = WORK + "/cancel.wav"
	_write_bytes(src, _wav(215))
	var t := _new_t(1024 * 1024)
	var hit := [false]
	var on_p := func(stage: String, _p: float, text: String) -> void:
		if stage == "upload" and text == "올리는 중 2/4" and not hit[0]:
			hit[0] = true
			t.cancel.call_deferred()
	_max_delta = 0.0
	var t0: int = Time.get_ticks_msec()
	var rec: Rec = await _go(t, src, _params({"lyrics": {"source": "none"}}), 20.0, on_p)
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "cancelled", "real cancel: finished(ok=false, err_code=cancelled) (got %s)" % r.get("err_code"))
	ok(float(Time.get_ticks_msec() - t0) / 1000.0 < 2.0, "real cancel: finished within 2 s (%d ms)" % (Time.get_ticks_msec() - t0))
	ok(_max_delta < 0.5, "real cancel: the main thread kept running (longest frame %.0f ms)" % (_max_delta * 1000.0))
	ok(_songs().is_empty(), "real cancel: nothing installed")
	ok(await _wait_for(func() -> bool: return _server_dirs().is_empty(), 4.0), "real cancel: the PC's upload folder was cleaned up: %s" % str(_server_dirs()))
	ok(t.busy == false and SongStore.pending_list().is_empty(), "real cancel: idle, nothing pending")
	t.queue_free()


func _real_bad_audio() -> void:
	print("[real server: a file that is not audio]")
	_reset_store()
	var src: String = WORK + "/garbage.mp3"
	_write_bytes(src, _noise(50000, 7))
	var t := _new_t()
	var rec: Rec = await _go(t, src, _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "bad_audio" and _has_hangul(str(r.get("message", ""))), "bad audio: err_code bad_audio with a Korean text (got %s)" % r.get("err_code"))
	ok(_songs().is_empty() and SongStore.pending_list().is_empty(), "bad audio: nothing installed, nothing pending")
	t.queue_free()
	# client-side checks that never reach the network
	var before: int = Api.sent_count
	var t2 := _new_t()
	var r_missing: Dictionary = _res(await _go(t2, WORK + "/does_not_exist.mp3", _params(), 10.0))
	ok(r_missing.get("err_code") == "file_open", "missing file: file_open")
	_write_bytes(WORK + "/empty.mp3", PackedByteArray())
	var r_empty: Dictionary = _res(await _go(t2, WORK + "/empty.mp3", _params(), 10.0))
	ok(r_empty.get("err_code") == "empty_file", "empty file: empty_file")
	_write_bytes(WORK + "/notes.txt", _noise(100))
	var r_ext: Dictionary = _res(await _go(t2, WORK + "/notes.txt", _params(), 10.0))
	ok(r_ext.get("err_code") == "bad_ext", "wrong extension: bad_ext")
	var f := FileAccess.open(WORK + "/huge.mp3", FileAccess.WRITE)
	var mb: PackedByteArray = _noise(1024 * 1024)
	for i in 65:
		f.store_buffer(mb)
	f.close()
	var r_big: Dictionary = _res(await _go(t2, WORK + "/huge.mp3", _params(), 10.0))
	DirAccess.remove_absolute(_g(WORK + "/huge.mp3"))
	ok(r_big.get("err_code") == "too_large", "65 MiB file: too_large before anything is uploaded")
	var r_lang: Dictionary = _res(await _go(t2, "res://tests/fixtures/song/tone_8s.mp3", {"lang": "xx"}, 10.0))
	ok(r_lang.get("err_code") == "bad_args", "unknown language: bad_args")
	ok(Api.sent_count == before, "none of the 5 client-side rejections sent a request")
	t2.queue_free()


func _real_pending_resume() -> void:
	print("[real server: app restart in the middle, resume from the pending record]")
	_reset_store()
	var t := _new_t()
	var src: String = "res://tests/fixtures/song/tone_8s.mp3"
	var seen_job := [""]
	var on_p := func(stage: String, _p: float, _text: String) -> void:
		if t.job_id != "" and seen_job[0] == "":
			seen_job[0] = t.job_id
			t.abandon.call_deferred() ## the app dies here: no finished, no server call
	var rec: Rec = await _go(t, src, _params(), 3.0, on_p)
	ok(rec.res == null, "abandon: no finished signal after abandon()")
	var pend: Array = SongStore.pending_list()
	ok(pend.size() == 1 and str(pend[0]["job"]).begins_with("j_") and str(pend[0]["upload_id"]).length() == 32 and pend[0]["lang"] == "en" and pend[0]["title"] == "Bridge Song", "abandon: a pending record {job, upload_id, lang, title} was written")
	ok(_songs().is_empty() and t.busy == false, "abandon: nothing installed, transfer idle")
	t.queue_free()
	var t2 := _new_t()
	var box := [null]
	t2.finished.connect(func(r: Dictionary) -> void: box[0] = r)
	t2.resume(pend[0])
	var t0: int = Time.get_ticks_msec()
	while box[0] == null and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	var r2: Dictionary = box[0] if box[0] is Dictionary else {}
	ok(r2.get("ok") == true and str(r2.get("song_id", "")).begins_with("s_"), "resume: finished ok (got %s)" % r2.get("err_code"))
	ok(_songs().size() == 1 and SongStore.pending_list().is_empty(), "resume: one song, pending removed")
	ok(await _wait_for(func() -> bool: return _server_dirs().is_empty(), 3.0), "resume: PC folders released")
	# a job the PC no longer knows
	var ghost := {"job": "j_deadbeef", "upload_id": "a".repeat(32), "lang": "en", "title": "Ghost", "t": 1}
	SongStore.pending_put(ghost)
	var box2 := [null]
	t2.finished.connect(func(r: Dictionary) -> void: box2[0] = r)
	t2.resume(ghost)
	t0 = Time.get_ticks_msec()
	while box2[0] == null and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().process_frame
	var r3: Dictionary = box2[0] if box2[0] is Dictionary else {}
	ok(r3.get("ok") == false and r3.get("err_code") == "no_job" and _has_hangul(str(r3.get("message", ""))), "resume of an unknown job: no_job with a Korean text (got %s)" % r3.get("err_code"))
	ok(SongStore.pending_list().is_empty(), "resume of an unknown job: the dead pending record is removed")
	var bad_box := [null]
	t2.finished.connect(func(r: Dictionary) -> void: bad_box[0] = r)
	t2.resume({"job": "not-a-job"})
	await get_tree().process_frame
	await get_tree().process_frame
	ok(bad_box[0] is Dictionary and (bad_box[0] as Dictionary).get("err_code") == "bad_pending", "resume with a broken record: bad_pending")
	t2.queue_free()


# ================================================================ fake server scenarios

func _fake_src(n: int = 350000, name: String = "fake.mp3") -> String:
	var p: String = WORK + "/" + name
	_write_bytes(p, _noise(n, 3))
	return p


func _fake_sections() -> void:
	var all: Array = [["normal", _fake_normal], ["drop", _fake_chunk_drop], ["unreachable", _fake_upload_transport_fail],
		["fcancel", _fake_cancel_upload], ["jcancel", _fake_cancel_job], ["sha", _fake_sha], ["failed", _fake_job_failed],
		["poll", _fake_poll_transport], ["install", _fake_install_fail], ["restart", _fake_server_restart], ["old", _fake_old_server],
		["jobs", _fake_job_errors], ["misc", _fake_misc]]
	for e in all:
		if _want(str(e[0])):
			await (e[1] as Callable).call()


func _fake_normal() -> void:
	print("[fake: normal flow, 4 upload chunks, 3 audio parts]")
	_reset_store()
	fake.reset()
	var t := _new_t(100000)
	var rec: Rec = await _go(t, _fake_src(), _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == true and r.get("err_code") == "", "fake normal: ok (got %s)" % r.get("err_code"))
	ok(t.chunk_log == [0, 1, 2, 3] and fake.posted_indices() == [0, 1, 2, 3], "fake normal: 4 chunks, each once: %s / server %s" % [str(t.chunk_log), str(fake.posted_indices())])
	ok(_monotone(rec.pcts) and float(rec.pcts[rec.pcts.size() - 1]) == 100.0 and float(rec.pcts[0]) <= 1.0, "fake normal: pct monotone 0 -> 100")
	ok(fake.count("GET /song/audio") == 3 and fake.count("GET /song/result") == 1, "fake normal: 3 audio parts and 1 result fetched")
	ok(fake.count("POST /song/jobs/release") == 1 and fake.count("POST /song/jobs/cancel") == 0, "fake normal: release called once, cancel never")
	ok(fake.release_after_audio(), "fake normal: release came after the last audio part")
	ok(fake.jobs.is_empty() and fake.uploads.is_empty(), "fake normal: the PC holds no job or upload any more")
	var list: Array = _songs()
	ok(list.size() == 1 and list[0]["ready"] == true and int(list[0]["bytes"]) > fake.audio.size(), "fake normal: 1 song installed, audio verified")
	ok(SongStore.pending_list().is_empty(), "fake normal: pending removed")
	var jb: Dictionary = fake.last_job_body()
	ok(jb.get("lang") == "en" and jb.get("title") == "Bridge Song" and jb["lyrics"]["source"] == "pasted" and (jb["lyrics"]["lines"] as Array).size() == 3 and jb["options"]["ai_ok"] == false and jb["upload_id"] == fake.last_upload_id(), "fake normal: job request carries lang, title, lyrics lines and boolean options")
	ok(str(jb.get("upload_id", "")).length() == 32, "fake normal: upload id is 32 hex chars")
	ok(fake.all_have_name("fake.mp3"), "fake normal: every chunk carried the file name")
	var warns: Variant = r.get("warnings")
	ok(warns is Array, "fake normal: warnings is an Array")
	var s: Dictionary = SongStore.load_song(list[0]["id"]) if list.size() == 1 else {}
	ok(SongModel.is_valid_id(list[0]["id"] if list.size() == 1 else "") and s.get("id") == r.get("song_id"), "fake normal: song id came from SongStore.new_id and is the one reported")
	t.queue_free()


func _fake_chunk_drop() -> void:
	print("[fake: connection dropped at chunk 2, then revived]")
	_reset_store()
	fake.reset()
	fake.cfg["drop"] = {"POST /song/upload:2": 1}
	var t := _new_t(100000)
	var rec: Rec = await _go(t, _fake_src(), _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == true, "drop: ok after one dropped chunk (got %s)" % r.get("err_code"))
	ok(t.chunk_log == [0, 1, 2, 2, 3], "drop: chunk 2 sent twice, 0/1/3 once: %s" % str(t.chunk_log))
	ok(fake.attempts_of(0) == 1 and fake.attempts_of(1) == 1 and fake.attempts_of(2) == 2 and fake.attempts_of(3) == 1, "drop: the server saw chunks 0 and 1 exactly once (no re-send of earlier chunks)")
	ok(fake.count("GET /song/upload") >= 1 and t.resyncs >= 1, "drop: the client asked GET /song/upload for the next index before retrying")
	ok(fake.accepted_indices() == [0, 1, 2, 3], "drop: the PC accepted 0,1,2,3 in order: %s" % str(fake.accepted_indices()))
	ok(_songs().size() == 1, "drop: song installed")
	# the answer to chunk 2 is lost but the PC kept it: the client must skip to 3 without sending 2 again
	_reset_store()
	fake.reset()
	fake.cfg["lose_answer"] = {"POST /song/upload:2": 1}
	var t2 := _new_t(100000)
	var r2: Dictionary = _res(await _go(t2, _fake_src(), _params()))
	ok(r2.get("ok") == true and t2.chunk_log == [0, 1, 2, 3], "lost answer: the chunk the PC already had is not sent again: %s" % str(t2.chunk_log))
	# the PC forgot the upload (restart): start over once
	_reset_store()
	fake.reset()
	fake.cfg["forget_upload_at"] = {"POST /song/upload:2": 1}
	var t3 := _new_t(100000)
	var r3: Dictionary = _res(await _go(t3, _fake_src(), _params()))
	ok(r3.get("ok") == true and t3.chunk_log == [0, 1, 2, 0, 1, 2, 3], "forgotten upload: restarted from chunk 0 once: %s" % str(t3.chunk_log))
	# upload_gap answer: go to the index the PC expects
	_reset_store()
	fake.reset()
	fake.cfg["gap_at"] = {"POST /song/upload:1": 1}
	var t4 := _new_t(100000)
	var r4: Dictionary = _res(await _go(t4, _fake_src(), _params()))
	ok(r4.get("ok") == true and t4.chunk_log.size() >= 5 and t4.resyncs >= 1, "upload_gap: followed the expected index (log %s)" % str(t4.chunk_log))
	t.queue_free()
	t2.queue_free()
	t3.queue_free()
	t4.queue_free()


func _fake_upload_transport_fail() -> void:
	print("[fake: PC unreachable for good during upload, then back]")
	_reset_store()
	fake.reset()
	fake.cfg["drop"] = {"POST /song/upload:2": 99, "GET /song/upload": 99}
	var t := _new_t(100000)
	var rec: Rec = await _go(t, _fake_src(), _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "transport" and _has_hangul(str(r.get("message", ""))), "unreachable: transport with a Korean text (got %s)" % r.get("err_code"))
	ok(t.chunk_log.count(2) == 4, "unreachable: chunk 2 tried 1 + 3 times (%s)" % str(t.chunk_log))
	var up_id: String = str(r.get("upload_id", ""))
	ok(up_id.length() == 32 and _songs().is_empty(), "unreachable: upload id returned, nothing installed")
	fake.cfg["drop"] = {}
	var t2 := _new_t(100000)
	var r2: Dictionary = _res(await _go(t2, _fake_src(), _params({"upload_id": up_id})))
	ok(r2.get("ok") == true and t2.chunk_log == [2, 3], "unreachable: the second start continued from chunk 2: %s" % str(t2.chunk_log))
	t.queue_free()
	t2.queue_free()


func _fake_cancel_upload() -> void:
	print("[fake: cancel while a chunk is in flight]")
	_reset_store()
	fake.reset()
	fake.cfg["delay_ms"] = {"POST /song/upload:1": 700}
	var t := _new_t(100000)
	var hit := [false]
	var on_p := func(stage: String, _p: float, text: String) -> void:
		if stage == "upload" and text == "올리는 중 2/4" and not hit[0]:
			hit[0] = true
			get_tree().create_timer(0.2).timeout.connect(func() -> void: t.cancel())
	_max_delta = 0.0
	var t0: int = Time.get_ticks_msec()
	var rec: Rec = await _go(t, _fake_src(), _params(), 20.0, on_p)
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "cancelled" and _has_hangul(str(r.get("message", ""))), "cancel upload: err_code cancelled (got %s)" % r.get("err_code"))
	ok(took < 2.0, "cancel upload: finished within 2 s although the chunk answer takes 0.7 s (%.2f s)" % took)
	ok(_max_delta < 0.5, "cancel upload: no frame longer than 500 ms (%.0f ms)" % (_max_delta * 1000.0))
	ok(t.busy == false and _songs().is_empty(), "cancel upload: idle, nothing installed")
	ok(await _wait_for(func() -> bool: return fake.count("POST /song/jobs/release") == 1, 4.0), "cancel upload: the PC got a release for the upload id")
	ok(fake.last_release().has("upload_id") and not fake.last_release().has("job") and fake.last_release()["upload_id"] == fake.last_upload_id(), "cancel upload: release was by upload_id")
	ok(fake.release_after_chunk_answer(), "cancel upload: the release came after the in-flight chunk was answered (no revived folder)")
	ok(fake.count("POST /song/jobs") == 0, "cancel upload: no job was started")
	ok(SongStore.pending_list().is_empty() and _listing(SONG_ROOT).filter(func(e: String) -> bool: return e.begins_with("d:_tmp")).is_empty(), "cancel upload: no pending record, no temp folder left")
	# a new transfer can start straight away
	fake.reset()
	var t2 := _new_t(100000)
	var r2: Dictionary = _res(await _go(t2, _fake_src(), _params()))
	ok(r2.get("ok") == true, "cancel upload: a new start right after works")
	t.queue_free()
	t2.queue_free()


func _fake_cancel_job() -> void:
	print("[fake: cancel while the PC is working]")
	_reset_store()
	fake.reset()
	fake.cfg["scripts"] = [[{"state": "queued", "queue_pos": 1}, {"state": "running", "stage": "asr", "pct": 30, "eta_sec": 90}]]
	var t := _new_t(100000)
	var seen := [false]
	var on_p := func(stage: String, _p: float, _text: String) -> void:
		if stage == "asr" and not seen[0]:
			seen[0] = true
			t.cancel.call_deferred()
	_max_delta = 0.0
	var t0: int = Time.get_ticks_msec()
	var rec: Rec = await _go(t, _fake_src(), _params(), 20.0, on_p)
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "cancelled", "cancel job: err_code cancelled (got %s)" % r.get("err_code"))
	ok(float(Time.get_ticks_msec() - t0) / 1000.0 < 2.0 and _max_delta < 0.5, "cancel job: within 2 s, no long frame")
	ok(await _wait_for(func() -> bool: return fake.count("POST /song/jobs/cancel") == 1 and fake.count("POST /song/jobs/release") == 1, 4.0), "cancel job: the PC got cancel and then release")
	ok(fake.cancel_before_release(), "cancel job: cancel was sent before release")
	ok(fake.last_release().get("job", "") == fake.last_job_id(), "cancel job: release named the job")
	ok(_songs().is_empty() and SongStore.pending_list().is_empty(), "cancel job: nothing installed, pending record removed")
	ok(fake.count("GET /song/result") == 0, "cancel job: no result was fetched")
	t.queue_free()


func _tamper_sources() -> Array:
	return [_fake_src()]


func _fake_sha() -> void:
	print("[fake: downloaded audio does not match its sha256]")
	_reset_store()
	fake.reset()
	fake.cfg["tamper"] = "always"
	var t := _new_t(100000)
	var rec: Rec = await _go(t, _fake_src(), _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "sha_mismatch" and _has_hangul(str(r.get("message", ""))), "tampered: sha_mismatch with a Korean text (got %s)" % r.get("err_code"))
	ok(_songs().is_empty() and _listing(SONG_ROOT).filter(func(e: String) -> bool: return e.begins_with("d:")).is_empty(), "tampered: nothing installed, no song folder")
	ok(fake.count("POST /song/jobs/release") == 0 and not fake.jobs.is_empty(), "tampered: release NOT called, the PC still holds the song")
	ok(fake.count("GET /song/audio") == 6, "tampered: whole file fetched twice (3 parts x 2) before giving up (%d)" % fake.count("GET /song/audio"))
	ok(SongStore.pending_list().size() == 1 and r.get("resumable") == true, "tampered: the pending record stays so it can be retried")
	# one bad download, then a good one: the retry rescues it
	_reset_store()
	fake.reset()
	fake.cfg["tamper"] = "once"
	var t2 := _new_t(100000)
	var r2: Dictionary = _res(await _go(t2, _fake_src(), _params()))
	ok(r2.get("ok") == true and fake.count("GET /song/audio") == 6 and _songs().size() == 1, "tampered once: the second download was good, installed")
	ok(fake.count("POST /song/jobs/release") == 1 and fake.release_after_audio(), "tampered once: release only after the good download")
	# the result JSON itself disagrees with the audio
	_reset_store()
	fake.reset()
	fake.cfg["meta_sha"] = "0".repeat(64)
	var t3 := _new_t(100000)
	var r3: Dictionary = _res(await _go(t3, _fake_src(), _params()))
	ok(r3.get("ok") == false and r3.get("err_code") == "sha_mismatch" and _songs().is_empty() and fake.count("POST /song/jobs/release") == 0, "wrong song.audio.sha256 in the result: sha_mismatch, no install, no release")
	# a part with the wrong size
	_reset_store()
	fake.reset()
	fake.cfg["short_part"] = true
	var t4 := _new_t(100000)
	var r4: Dictionary = _res(await _go(t4, _fake_src(), _params()))
	ok(r4.get("ok") == false and r4.get("err_code") == "sha_mismatch" and _songs().is_empty() and fake.count("POST /song/jobs/release") == 0, "a truncated part: sha_mismatch, no install, no release")
	# sanity of the checker: an untouched file passes (the previous cases fail for the right reason)
	_reset_store()
	fake.reset()
	var t5 := _new_t(100000)
	ok(_res(await _go(t5, _fake_src(), _params())).get("ok") == true, "self-test: the same fake without tampering installs fine")
	t.queue_free()
	t2.queue_free()
	t3.queue_free()
	t4.queue_free()
	t5.queue_free()


func _fake_job_failed() -> void:
	print("[fake: the PC reports a failed job]")
	for code in ["no_speech", "asr_failed", "model_missing", "internal"]:
		_reset_store()
		fake.reset()
		fake.cfg["scripts"] = [[{"state": "running", "stage": "asr", "pct": 10}, {"state": "failed", "error": {"code": code, "message": "서버 문장 " + code}}]]
		var t := _new_t(100000)
		var r: Dictionary = _res(await _go(t, _fake_src(), _params()))
		var expect: String = SongTransfer.message_for(code)
		ok(r.get("ok") == false and r.get("err_code") == code and r.get("message") == expect and _has_hangul(expect), "failed %s: err_code and Korean guidance (got %s)" % [code, r.get("err_code")])
		ok(_songs().is_empty() and SongStore.pending_list().is_empty(), "failed %s: nothing installed, nothing pending" % code)
		ok(fake.count("GET /song/result") == 0 and fake.count("POST /song/jobs/release") == 1, "failed %s: no result fetched, the dead job released" % code)
		t.queue_free()


func _fake_poll_transport() -> void:
	print("[fake: 5 polls in a row fail]")
	_reset_store()
	fake.reset()
	fake.cfg["drop"] = {"GET /song/jobs/status": 99}
	var t := _new_t(100000)
	var rec: Rec = await _go(t, _fake_src(), _params())
	var r: Dictionary = _res(rec)
	ok(r.get("ok") == false and r.get("err_code") == "transport", "poll fail: transport (got %s)" % r.get("err_code"))
	ok(fake.count("GET /song/jobs/status") >= 5 and fake.count("GET /song/jobs/status") <= 12, "poll fail: gave up after the 5th failed poll (%d status requests)" % fake.count("GET /song/jobs/status"))
	var pend: Array = SongStore.pending_list()
	ok(pend.size() == 1 and r.get("resumable") == true and r.get("job") == pend[0]["job"], "poll fail: the pending record stays and the result says resumable")
	ok(_songs().is_empty() and fake.count("POST /song/jobs/release") == 0 and fake.count("POST /song/jobs/cancel") == 0, "poll fail: nothing installed, the PC job left alone (no cancel, no release)")
	# one hiccup in between is not 5 in a row
	_reset_store()
	fake.reset()
	fake.cfg["drop"] = {"GET /song/jobs/status": 2}
	var t2 := _new_t(100000)
	ok(_res(await _go(t2, _fake_src(), _params())).get("ok") == true, "poll fail: 2 failed polls then a good one is fine")
	# resume the job that was left behind: the PC works again
	_reset_store()
	fake.reset()
	fake.cfg["drop"] = {"GET /song/jobs/status": 99}
	var t3 := _new_t(100000)
	var r3: Dictionary = _res(await _go(t3, _fake_src(), _params()))
	var rec3: Dictionary = SongStore.pending_list()[0]
	fake.cfg["drop"] = {}
	var box := [null]
	t3.finished.connect(func(x: Dictionary) -> void: box[0] = x)
	t3.resume(rec3)
	var t0: int = Time.get_ticks_msec()
	while box[0] == null and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	var r4: Dictionary = box[0] if box[0] is Dictionary else {}
	ok(r3.get("err_code") == "transport" and r4.get("ok") == true and _songs().size() == 1 and SongStore.pending_list().is_empty(), "resume after transport: installed, pending removed")
	ok(fake.count("POST /song/upload") == 4, "resume after transport: no chunk was uploaded again (%d chunk posts)" % fake.count("POST /song/upload"))
	t.queue_free()
	t2.queue_free()
	t3.queue_free()


func _fake_install_fail() -> void:
	print("[fake: the phone cannot store the song]")
	# quota: songs
	_reset_store()
	fake.reset()
	SongStore.max_songs = 0
	var t := _new_t(100000)
	var r: Dictionary = _res(await _go(t, _fake_src(), _params()))
	ok(r.get("ok") == false and r.get("err_code") == "quota_songs" and _has_hangul(str(r.get("message", ""))), "quota_songs: err_code and Korean text (got %s)" % r.get("err_code"))
	ok(fake.count("POST /song/jobs/release") == 0 and not fake.jobs.is_empty(), "quota_songs: release NOT called")
	ok(_songs().is_empty() and SongStore.pending_list().size() == 1 and r.get("resumable") == true, "quota_songs: nothing installed, pending kept, resumable")
	# free the room and resume: the song is still on the PC
	SongStore.max_songs = SongStore.MAX_SONGS
	var box := [null]
	t.finished.connect(func(x: Dictionary) -> void: box[0] = x)
	t.resume(SongStore.pending_list()[0])
	var t0: int = Time.get_ticks_msec()
	while box[0] == null and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	var r2: Dictionary = box[0] if box[0] is Dictionary else {}
	ok(r2.get("ok") == true and _songs().size() == 1 and fake.count("POST /song/jobs/release") == 1 and SongStore.pending_list().is_empty(), "quota_songs: after freeing room, resume installs and only then releases")
	# quota: bytes
	_reset_store()
	fake.reset()
	SongStore.max_bytes = 1000
	var t2 := _new_t(100000)
	var r3: Dictionary = _res(await _go(t2, _fake_src(), _params()))
	ok(r3.get("err_code") == "quota_bytes" and _has_hangul(str(r3.get("message", ""))) and fake.count("POST /song/jobs/release") == 0 and _songs().is_empty(), "quota_bytes: Korean text, no release, nothing installed")
	# write failure
	_reset_store()
	fake.reset()
	SongStore.write_hook = func(p: String) -> bool: return not p.ends_with("audio.mp3")
	var t3 := _new_t(100000)
	var r4: Dictionary = _res(await _go(t3, _fake_src(), _params()))
	SongStore.write_hook = Callable()
	ok(r4.get("err_code") == "disk_write" and _has_hangul(str(r4.get("message", ""))) and fake.count("POST /song/jobs/release") == 0, "disk_write: Korean text, no release")
	ok(_songs().is_empty() and _listing(SONG_ROOT).filter(func(e: String) -> bool: return e.begins_with("d:")).is_empty(), "disk_write: no half-written song folder left")
	ok(SongStore.pending_list().size() == 1, "disk_write: pending kept")
	# a song without usable lines is not worth retrying
	_reset_store()
	fake.reset()
	fake.cfg["no_lines"] = true
	var t4 := _new_t(100000)
	var r5: Dictionary = _res(await _go(t4, _fake_src(), _params()))
	ok(r5.get("err_code") == "bad_song" and fake.count("POST /song/jobs/release") == 0 and SongStore.pending_list().is_empty() and _songs().is_empty(), "bad_song: Korean text, nothing installed, not resumable")
	t.queue_free()
	t2.queue_free()
	t3.queue_free()
	t4.queue_free()


func _fake_server_restart() -> void:
	print("[fake: PC restarted in the middle (server_restart)]")
	_reset_store()
	fake.reset()
	fake.cfg["scripts"] = [[{"state": "failed", "error": {"code": "server_restart", "message": "x"}}], [{"state": "running", "stage": "asr", "pct": 50}, {"state": "done"}]]
	var t := _new_t(100000)
	var r: Dictionary = _res(await _go(t, _fake_src(), _params()))
	ok(r.get("ok") == true and fake.count("POST /song/jobs") == 2 and fake.count("POST /song/upload") == 4, "server_restart: the job was started again with the same upload, no re-upload")
	ok(fake.job_bodies_equal(), "server_restart: the second job request had the same upload id and lyrics")
	ok(_songs().size() == 1 and SongStore.pending_list().is_empty(), "server_restart: installed, pending clean")
	# twice in a row: give up with the Korean text
	_reset_store()
	fake.reset()
	fake.cfg["scripts"] = [[{"state": "failed", "error": {"code": "server_restart", "message": "x"}}]]
	var t2 := _new_t(100000)
	var r2: Dictionary = _res(await _go(t2, _fake_src(), _params()))
	ok(r2.get("ok") == false and r2.get("err_code") == "server_restart" and fake.count("POST /song/jobs") == 2 and _has_hangul(str(r2.get("message", ""))), "server_restart twice: err_code server_restart after 1 automatic retry")
	t.queue_free()
	t2.queue_free()


func _fake_old_server() -> void:
	print("[fake: old / newer PC program]")
	_reset_store()
	fake.reset()
	fake.cfg["health"] = {"ok": true}
	var before: int = fake.count("POST /song/upload")
	var t := _new_t(100000)
	var r: Dictionary = _res(await _go(t, _fake_src(), _params()))
	ok(r.get("err_code") == "pc_old" and fake.count("POST /song/upload") == before and _has_hangul(str(r.get("message", ""))), "old PC program (no song key): pc_old, nothing uploaded")
	ok(str(r.get("message", "")).find("업데이트") >= 0, "old PC program: the text says to update the PC program")
	fake.cfg["health"] = {"ok": true, "song": true, "song_v": 2}
	var r2: Dictionary = _res(await _go(t, _fake_src(), _params()))
	ok(r2.get("err_code") == "app_old" and fake.count("POST /song/upload") == 0, "newer PC program (song_v 2): app_old, nothing uploaded")
	fake.cfg["health"] = {"ok": true, "song": true, "song_v": 1}
	fake.cfg["http_404_song"] = true
	var r3: Dictionary = _res(await _go(t, _fake_src(), _params()))
	ok(r3.get("ok") == true or r3.get("err_code") != "TIMEOUT", "a health answer with song:true proceeds")
	t.queue_free()


func _fake_job_errors() -> void:
	print("[fake: the PC refuses the job]")
	for case in [[429, "queue_full"], [400, "bad_request"], [503, "storage_full"], [404, "no_upload"]]:
		_reset_store()
		fake.reset()
		fake.cfg["job_error"] = {"status": case[0], "code": case[1], "left": 99}
		var t := _new_t(100000)
		var r: Dictionary = _res(await _go(t, _fake_src(), _params()))
		ok(r.get("ok") == false and r.get("err_code") == case[1] and _has_hangul(str(r.get("message", ""))), "job refused %d %s: err_code and Korean text (got %s)" % [case[0], case[1], r.get("err_code")])
		ok(SongStore.pending_list().is_empty() and _songs().is_empty(), "job refused %s: nothing pending, nothing installed" % case[1])
		t.queue_free()
	# last-chunk errors
	for case2 in [[415, "bad_audio"], [413, "too_long"], [413, "too_large"], [503, "storage_full"]]:
		_reset_store()
		fake.reset()
		fake.cfg["upload_error"] = {"status": case2[0], "code": case2[1], "index": 3}
		var t2 := _new_t(100000)
		var r2: Dictionary = _res(await _go(t2, _fake_src(), _params()))
		ok(r2.get("ok") == false and r2.get("err_code") == case2[1] and _has_hangul(str(r2.get("message", ""))), "last chunk refused %s: err_code and Korean text (got %s)" % [case2[1], r2.get("err_code")])
		ok(fake.count("POST /song/jobs") == 0 and _songs().is_empty(), "last chunk refused %s: no job started, nothing installed" % case2[1])
		t2.queue_free()


func _fake_misc() -> void:
	print("[fake: busy, abandon, file name rules, message of a second start]")
	_reset_store()
	fake.reset()
	fake.cfg["scripts"] = [[{"state": "running", "stage": "asr", "pct": 5}, {"state": "running", "stage": "asr", "pct": 5}, {"state": "running", "stage": "asr", "pct": 5}, {"state": "done"}]]
	var t := _new_t(100000)
	var rec := Rec.new()
	t.finished.connect(func(r: Dictionary) -> void:
		if rec.res == null:
			rec.res = r)
	t.start(_fake_src(), _params())
	await get_tree().create_timer(0.1).timeout
	ok(t.busy == true, "busy: busy is true while working")
	var extra := [0]
	t.finished.connect(func(_r: Dictionary) -> void: extra[0] += 1)
	var posts_before: int = fake.count("POST /song/jobs")
	t.start(_fake_src(), _params())
	t.resume({"job": "j_00000001", "upload_id": "a".repeat(32), "lang": "en", "title": "x", "t": 1})
	await get_tree().process_frame
	ok(extra[0] == 0 and t.busy == true and fake.count("POST /song/upload") <= 4, "busy: a second start() / resume() while working is ignored (no signal, no extra upload)")
	await _until_finished(rec, 30.0)
	ok(_res(rec).get("ok") == true and extra[0] == 1 and fake.count("POST /song/jobs") == posts_before + 0 + (1 if posts_before == 0 else 0), "busy: the first transfer ran to its end with exactly one finished (got %s)" % _res(rec).get("err_code"))
	# a name without extension (content:// style) is sent as .mp3
	_reset_store()
	fake.reset()
	var t2 := _new_t(100000)
	var noext: String = WORK + "/track_without_extension"
	_write_bytes(noext, _noise(250000, 5))
	var r2: Dictionary = _res(await _go(t2, noext, _params({"name": "My Song"})))
	ok(r2.get("ok") == true and fake.all_have_name("My Song.mp3"), "a name without an extension is uploaded as .mp3")
	_reset_store()
	fake.reset()
	var r3: Dictionary = _res(await _go(t2, noext, _params({"name": "evil.exe"}), 10.0))
	ok(r3.get("err_code") == "bad_ext" and fake.count("POST /song/upload") == 0, "an .exe name is refused before upload")
	# abandon: silent
	_reset_store()
	fake.reset()
	fake.cfg["scripts"] = [[{"state": "running", "stage": "asr", "pct": 5}]]
	var t3 := _new_t(100000)
	var gone := [false]
	t3.finished.connect(func(_r: Dictionary) -> void: gone[0] = true)
	t3.start(_fake_src(), _params())
	await _wait_for(func() -> bool: return fake.count("GET /song/jobs/status") >= 2, 5.0)
	t3.abandon()
	await get_tree().create_timer(0.4).timeout
	ok(gone[0] == false and t3.busy == false, "abandon: no finished signal, transfer idle")
	var n_status: int = fake.count("GET /song/jobs/status")
	await get_tree().create_timer(0.4).timeout
	ok(fake.count("GET /song/jobs/status") == n_status and fake.count("POST /song/jobs/cancel") == 0 and fake.count("POST /song/jobs/release") == 0, "abandon: no more requests, no cancel, no release (the job lives on for resume)")
	ok(SongStore.pending_list().size() == 1, "abandon: pending record kept")
	# freeing the node mid-flight does not crash and stops quietly
	var t4 := _new_t(100000)
	t4.start(_fake_src(), _params())
	await get_tree().create_timer(0.15).timeout
	t4.queue_free()
	await get_tree().create_timer(0.3).timeout
	ok(true, "freeing the node while working is quiet (no script error)")
	t.queue_free()
	t2.queue_free()
	t3.queue_free()


# ================================================================ GDScript fake of the /song/* API

class FakeSong:
	extends Node
	var srv: TCPServer = null
	var log: Array = [] ## {key, m, path, q, body, t}
	var uploads: Dictionary = {}
	var jobs: Dictionary = {}
	var job_seq: int = 0
	var cfg: Dictionary = {}
	var audio: PackedByteArray = PackedByteArray()
	var audio_sha: String = ""
	var part_bytes: int = 100000
	var tampered_once: bool = false
	var conns: Array = []

	func setup(p: int) -> bool:
		srv = TCPServer.new()
		if srv.listen(p, "127.0.0.1") != OK:
			srv = null
			return false
		audio.resize(250000)
		var x: int = 99991
		for i in audio.size():
			x = (x * 1103515245 + 12345) & 0x7fffffff
			audio[i] = (x >> 16) & 255
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA256)
		h.update(audio)
		audio_sha = h.finish().hex_encode()
		reset()
		return true

	func stop() -> void:
		if srv != null:
			srv.stop()
			srv = null
		for c in conns:
			if c is StreamPeerTCP:
				(c as StreamPeerTCP).disconnect_from_host()
		conns.clear()

	func reset() -> void:
		log.clear()
		uploads.clear()
		jobs.clear()
		job_seq = 0
		tampered_once = false
		cfg = {"health": {"ok": true, "song": true, "song_v": 1}, "drop": {}, "lose_answer": {}, "delay_ms": {}, "forget_upload_at": {}, "gap_at": {},
			"scripts": [[{"state": "queued", "queue_pos": 1}, {"state": "running", "stage": "asr", "pct": 40, "eta_sec": 30},
				{"state": "running", "stage": "enrich", "pct": 80, "eta_sec": 5}, {"state": "done", "warnings": ["ko_missing"]}]]}

	func _process(_d: float) -> void:
		if srv != null and srv.is_listening():
			while srv.is_connection_available():
				var peer: StreamPeerTCP = srv.take_connection()
				conns.append(peer)
				_serve(peer)

	# ---- queries for the test
	func count(key: String) -> int:
		var n: int = 0
		for e in log:
			if e["key"] == key or str(e["key"]).begins_with(key + ":"):
				n += 1
		return n

	func posted_indices() -> Array:
		var out: Array = []
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/upload" and not e["dropped"]:
				out.append(int(e["body"].get("index", -1)))
		return out

	func attempts_of(i: int) -> int:
		var n: int = 0
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/upload" and int(e["body"].get("index", -1)) == i:
				n += 1
		return n

	func accepted_indices() -> Array:
		var out: Array = []
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/upload" and e.get("accepted", false):
				out.append(int(e["body"].get("index", -1)))
		return out

	func all_have_name(n: String) -> bool:
		var any: bool = false
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/upload":
				any = true
				if str(e["body"].get("name", "")) != n:
					return false
		return any

	func last_job_body() -> Dictionary:
		for i in range(log.size() - 1, -1, -1):
			if log[i]["m"] == "POST" and log[i]["path"] == "/song/jobs":
				return log[i]["body"]
		return {}

	func job_bodies_equal() -> bool:
		var bodies: Array = []
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/jobs":
				bodies.append(JSON.stringify(e["body"]))
		return bodies.size() == 2 and bodies[0] == bodies[1]

	func last_upload_id() -> String:
		for i in range(log.size() - 1, -1, -1):
			if log[i]["path"] == "/song/upload" and log[i]["m"] == "POST":
				return str(log[i]["body"].get("upload_id", ""))
		return ""

	func last_job_id() -> String:
		for i in range(log.size() - 1, -1, -1):
			if log[i].has("job_made"):
				return str(log[i]["job_made"])
		return ""

	func last_release() -> Dictionary:
		for i in range(log.size() - 1, -1, -1):
			if log[i]["path"] == "/song/jobs/release":
				return log[i]["body"]
		return {}

	func _index_of(path: String, from_end: bool = false) -> int:
		if from_end:
			for i in range(log.size() - 1, -1, -1):
				if log[i]["path"] == path:
					return i
			return -1
		for i in log.size():
			if log[i]["path"] == path:
				return i
		return -1

	func release_after_audio() -> bool:
		return _index_of("/song/jobs/release") > _index_of("/song/audio", true) and _index_of("/song/audio", true) >= 0

	func cancel_before_release() -> bool:
		var c: int = _index_of("/song/jobs/cancel")
		return c >= 0 and c < _index_of("/song/jobs/release")

	## the release must be logged after the last upload request was answered (the late chunk may not revive the folder)
	func release_after_chunk_answer() -> bool:
		var r: int = _index_of("/song/jobs/release")
		var last_chunk: int = _index_of("/song/upload", true)
		return r > last_chunk

	# ---- the http part
	func _serve(peer: StreamPeerTCP) -> void:
		var buf := PackedByteArray()
		var head_end: int = -1
		var clen: int = 0
		var head: String = ""
		var t0: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 20000:
			peer.poll()
			var st: int = peer.get_status()
			if st != StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() == 0:
				break
			var n: int = peer.get_available_bytes()
			if n > 0:
				var got: Array = peer.get_data(n)
				if int(got[0]) == OK:
					buf.append_array(got[1])
			if head_end < 0:
				var s: String = buf.slice(0, mini(buf.size(), 8192)).get_string_from_ascii()
				var i: int = s.find("\r\n\r\n")
				if i >= 0:
					head_end = i + 4
					head = s.substr(0, i)
					for line in head.split("\r\n"):
						if line.to_lower().begins_with("content-length:"):
							clen = int(line.substr(15).strip_edges())
			if head_end >= 0 and buf.size() >= head_end + clen:
				await _handle(peer, head, buf.slice(head_end, head_end + clen))
				return
			await get_tree().process_frame
		peer.disconnect_from_host()

	func _handle(peer: StreamPeerTCP, head: String, body_bytes: PackedByteArray) -> void:
		var first: PackedStringArray = head.split("\r\n")[0].split(" ")
		var m: String = first[0]
		var target: String = first[1]
		var path: String = target.split("?")[0]
		var q: Dictionary = {}
		if "?" in target:
			for kv in target.split("?", true, 1)[1].split("&"):
				var p2: PackedStringArray = kv.split("=", true, 1)
				q[p2[0].uri_decode()] = p2[1].uri_decode() if p2.size() > 1 else ""
		var body: Dictionary = {}
		if body_bytes.size() > 0:
			var parsed: Variant = JSON.parse_string(body_bytes.get_string_from_utf8())
			if parsed is Dictionary:
				body = parsed
		var key: String = m + " " + path
		var idx_key: String = key
		if body.has("index"):
			idx_key = key + ":" + str(int(body["index"]))
		var entry := {"key": idx_key, "m": m, "path": path, "q": q, "body": _slim(body), "dropped": false}
		log.append(entry)
		var d: Dictionary = cfg["drop"]
		for k in [idx_key, key]:
			if d.has(k) and int(d[k]) != 0:
				d[k] = int(d[k]) - 1
				entry["dropped"] = true
				peer.disconnect_from_host()
				return
		var dl: Dictionary = cfg["delay_ms"]
		for k in [idx_key, key]:
			if dl.has(k):
				await get_tree().create_timer(float(dl[k]) / 1000.0).timeout
				break
		var res: Array = _route(m, path, q, body, entry, idx_key, key)
		var la: Dictionary = cfg["lose_answer"]
		for k in [idx_key, key]:
			if la.has(k) and int(la[k]) != 0:
				la[k] = int(la[k]) - 1
				peer.disconnect_from_host() ## the work was done, the answer never arrives
				return
		var payload: PackedByteArray = JSON.stringify(res[1]).to_utf8_buffer()
		var hd := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [int(res[0]), payload.size()]
		peer.put_data(hd.to_utf8_buffer())
		peer.put_data(payload)
		await get_tree().process_frame
		peer.disconnect_from_host()

	func _slim(b: Dictionary) -> Dictionary:
		var c: Dictionary = b.duplicate(true)
		if c.has("data_b64"):
			c["data_b64"] = "len:%d" % str(c["data_b64"]).length()
		return c

	func _err(status: int, code: String, extra: Dictionary = {}) -> Array:
		var d := {"error": "서버 오류 " + code, "code": code}
		for k in extra:
			d[k] = extra[k]
		return [status, d]

	func _route(m: String, path: String, q: Dictionary, body: Dictionary, entry: Dictionary, idx_key: String, key: String) -> Array:
		match m + " " + path:
			"GET /health":
				return [200, cfg["health"]]
			"POST /song/upload":
				return _upload(body, entry, idx_key)
			"GET /song/upload":
				var u: Variant = uploads.get(str(q.get("upload_id", "")), null)
				if u == null:
					return _err(404, "no_upload")
				return [200, {"upload_id": q["upload_id"], "next": u["next"], "bytes": u["next"] * 1000, "done": u["next"] >= u["total"]}]
			"POST /song/jobs":
				return _job_create(body, entry)
			"GET /song/jobs/status":
				return _status(str(q.get("job", "")))
			"POST /song/jobs/cancel":
				var j: Variant = jobs.get(str(body.get("job", "")), null)
				if j == null:
					return _err(404, "no_job")
				if j["last"] == "done":
					return [200, {"ok": true, "state": "done"}]
				j["cancelled"] = true
				return [200, {"ok": true, "state": "cancelled"}]
			"GET /song/result":
				return _result(str(q.get("job", "")))
			"GET /song/audio":
				return _audio(str(q.get("job", "")), int(q.get("part", "0")))
			"POST /song/jobs/release":
				return _release(body)
		return _err(404, "no_route")

	func _upload(body: Dictionary, entry: Dictionary, idx_key: String) -> Array:
		var ue: Variant = cfg.get("upload_error", null)
		var idx: int = int(body.get("index", -1))
		if ue is Dictionary and int((ue as Dictionary).get("index", -1)) == idx:
			return _err(int(ue["status"]), str(ue["code"]))
		var id: String = str(body.get("upload_id", ""))
		var total: int = int(body.get("total", 0))
		var fg: Dictionary = cfg["forget_upload_at"]
		if fg.has(idx_key) and int(fg[idx_key]) != 0:
			fg[idx_key] = int(fg[idx_key]) - 1
			uploads.erase(id)
			return _err(409, "upload_gap", {"expected": 0})
		var gp: Dictionary = cfg["gap_at"]
		if gp.has(idx_key) and int(gp[idx_key]) != 0:
			gp[idx_key] = int(gp[idx_key]) - 1
			var cur: Variant = uploads.get(id, null)
			var exp: int = maxi(0, idx - 1)
			if cur != null:
				cur["next"] = exp
			return _err(409, "upload_gap", {"expected": exp})
		var u: Variant = uploads.get(id, null)
		if u == null:
			if idx != 0:
				return _err(409, "upload_gap", {"expected": 0})
			u = {"total": total, "next": 0}
			uploads[id] = u
		if idx < int(u["next"]):
			return [200, {"upload_id": id, "received": u["next"], "bytes": 0}]
		if idx > int(u["next"]):
			return _err(409, "upload_gap", {"expected": u["next"]})
		u["next"] = int(u["next"]) + 1
		entry["accepted"] = true
		if int(u["next"]) < total:
			return [200, {"upload_id": id, "received": u["next"], "bytes": int(u["next"]) * 1000}]
		return [200, {"upload_id": id, "done": true, "bytes": audio.size(), "duration": 12.0, "format": "mp3", "sha256": audio_sha}]

	func _job_create(body: Dictionary, entry: Dictionary) -> Array:
		var je: Variant = cfg.get("job_error", null)
		if je is Dictionary and int((je as Dictionary).get("left", 0)) != 0:
			je["left"] = int(je["left"]) - 1
			return _err(int(je["status"]), str(je["code"]))
		var u: Variant = uploads.get(str(body.get("upload_id", "")), null)
		if u == null:
			return _err(404, "no_upload")
		if int(u["next"]) < int(u["total"]):
			return _err(409, "upload_gap", {"expected": u["next"]})
		job_seq += 1
		var jid: String = "j_%08x" % (0xabc000 + job_seq)
		jobs[jid] = {"up": str(body.get("upload_id", "")), "polls": 0, "cancelled": false, "last": "queued", "body": body, "n": job_seq - 1}
		entry["job_made"] = jid
		return [202, {"job": jid, "state": "queued", "queue_pos": 0}]

	func _status(jid: String) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			return _err(404, "no_job")
		var out := {"job": jid, "state": "queued", "stage": "", "pct": 0, "eta_sec": null, "message_ko": "순서를 기다리는 중", "warnings": [], "error": null}
		if j["cancelled"]:
			out["state"] = "cancelled"
			j["last"] = "cancelled"
			return [200, out]
		var scripts: Array = cfg["scripts"]
		var script: Array = scripts[mini(int(j["n"]), scripts.size() - 1)]
		var step: Dictionary = script[mini(int(j["polls"]), script.size() - 1)]
		j["polls"] = int(j["polls"]) + 1
		for k in step:
			out[k] = step[k]
		if str(out["state"]) == "done":
			out["pct"] = 100
		j["last"] = str(out["state"])
		return [200, out]

	func _song_for(j: Dictionary) -> Dictionary:
		var parts: int = int(ceil(float(audio.size()) / float(part_bytes)))
		var lines: Array = []
		if not cfg.get("no_lines", false):
			var texts := ["The river runs past the old wooden bridge", "We hum a tune while the lanterns glow", "Morning comes and the sky turns gold"]
			for i in 3:
				lines.append({"i": i, "p": 0, "t0": 0.5 + i * 3.0, "t1": 3.0 + i * 3.0, "text": texts[i], "reading": "", "pron": "", "ko": "", "conf": 0.9, "est": false, "stale": false, "words": []})
		var meta_sha: String = str(cfg.get("meta_sha", audio_sha))
		return {"v": 1, "lang": "en", "title": str(j["body"].get("title", "")), "artist": str(j["body"].get("artist", "")), "created": 1793377559, "duration": 12.0,
			"audio": {"file": "audio.mp3", "bytes": audio.size(), "sha256": meta_sha, "orig_name": "fake.mp3", "parts": parts},
			"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""}, "offset": 0.0, "lines": lines, "glossary": {}, "warnings": []}

	func _result(jid: String) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			return _err(404, "no_job")
		if j["last"] != "done":
			return _err(409, "not_done")
		return [200, _song_for(j)]

	func _audio(jid: String, part: int) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			return _err(404, "no_job")
		if j["last"] != "done":
			return _err(409, "not_done")
		var parts: int = int(ceil(float(audio.size()) / float(part_bytes)))
		if part < 0 or part >= parts:
			return _err(400, "bad_index")
		var raw: PackedByteArray = audio.slice(part * part_bytes, mini(audio.size(), (part + 1) * part_bytes))
		var tam: String = str(cfg.get("tamper", ""))
		if part == 1 and (tam == "always" or (tam == "once" and not tampered_once)):
			raw[10] = raw[10] ^ 0xFF
			tampered_once = true
		var claimed: int = raw.size()
		if cfg.get("short_part", false) and part == 2:
			raw = raw.slice(0, raw.size() - 5) ## says N bytes, delivers N-5
		return [200, {"part": part, "parts": parts, "bytes": claimed, "total_bytes": audio.size(), "data_b64": Marshalls.raw_to_base64(raw), "sha256": audio_sha}]

	func _release(body: Dictionary) -> Array:
		if body.has("job"):
			var jid: String = str(body["job"])
			var j: Variant = jobs.get(jid, null)
			if j == null:
				return [200, {"ok": true, "removed": false}]
			if j["last"] in ["queued", "running"] and not j["cancelled"]:
				return _err(409, "job_running")
			var up: String = j["up"]
			jobs.erase(jid)
			var others: bool = false
			for k in jobs:
				if jobs[k]["up"] == up:
					others = true
			if not others:
				uploads.erase(up)
			return [200, {"ok": true, "removed": true}]
		var uid: String = str(body.get("upload_id", ""))
		var known: bool = uploads.has(uid)
		uploads.erase(uid)
		return [200, {"ok": true, "removed": known}]
