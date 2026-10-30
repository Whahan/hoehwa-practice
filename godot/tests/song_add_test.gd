extends Node
## 노래 공부 U2: SongAddScreen (곡 추가 화면) + SongImport (파일 고르기) 시험.
##   PC:   godot --headless --path godot res://tests/song_add_test.tscn
##   폰:   godot --headless --path godot res://tests/song_add_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5      (--python=<python.exe> 로 파이썬 지정, --only=<구간> 으로 한 구간만)
## 시험 서버는 시험이 직접 띄우고 자기 PID(와 하위)만 끈다:
##   18797 = tests/fixtures/song/fake_lrclib.py (가짜 LRCLIB, 실제 lrclib.net 접속 없음)
##   18794 = backend/lan_stub_server.py --song (가짜 전사, 종단 흐름) 그다음 같은 포트에 GDScript 가짜 서버(Spy: 요청 본문 기록 · 끊김 · 실패)
## 곡은 user://test_songs_u2 에만 설치한다. 설정·진행·학습 기록은 user://test_u2/ 로 돌린다. 가사·제목은 모두 직접 지은 문장이다.
## 마지막 줄: "== song_add_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 일부러 틀린 입력(변조)으로 검사기가 실제로 FAIL 을 내는지: _selftest() 구간.

const LR_PORT := 18797
const SV_PORT := 18794
const LR_BASE := "http://127.0.0.1:18797"
const SV_BASE := "http://127.0.0.1:18794"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const ROOT := "user://test_songs_u2"
const DIR := "user://test_u2"
const JOBS_DIR := "user://test_u2_jobs"
const TONE := "res://tests/fixtures/song/tone_8s.mp3"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _toasts: Array = []
var _before: Dictionary = {}
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_status: Variant
var _old_health: Dictionary
var _lr_pid: int = -1
var _sv_pid: int = -1
var spy: Spy = null
var _added: Array = []
var _closed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- helpers

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(prefix):
			return String(a).substr(prefix.length())
	return ""


func _want(name: String) -> bool:
	var only: String = _arg("--only=")
	return only == "" or only == name


func _until(cond: Callable, max_sec: float = 20.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < max_sec:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _rm_rf(p: String) -> void:
	var gp: String = _g(p)
	var d := DirAccess.open(gp)
	if d != null:
		for sub in d.get_directories():
			_rm_rf(p.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(gp.path_join(fn))
	DirAccess.remove_absolute(gp)


func _write_bytes(p: String, b: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(_g(p).get_base_dir())
	var f := FileAccess.open(_g(p), FileAccess.WRITE)
	if f != null:
		f.store_buffer(b)
		f.close()


func _write_zero(p: String, n: int) -> void:
	DirAccess.make_dir_recursive_absolute(_g(p).get_base_dir())
	var f := FileAccess.open(_g(p), FileAccess.WRITE)
	if f == null:
		return
	var blk := PackedByteArray()
	blk.resize(1048576)
	var left: int = n
	while left > 0:
		var k: int = mini(left, blk.size())
		f.store_buffer(blk.slice(0, k))
		left -= k
	f.close()


## 16-bit mono WAV, `sec` seconds of a quiet tone.
func _wav(sec: int, rate: int = 8000) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(sec * rate * 2)
	for i in sec * rate:
		data.encode_s16(i * 2, int(sin(TAU * 220.0 * float(i) / float(rate)) * 3000.0))
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


func _listing(p: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(_g(p))
	if d == null:
		return out
	for sub in d.get_directories():
		out.append("d:" + sub)
	for fn in d.get_files():
		out.append("f:%s:%d" % [fn, FileAccess.get_size(_g(p).path_join(fn))])
	out.sort()
	return out


func _user_listing() -> Dictionary:
	var out := {}
	for fn in ["prefs.json", "progress.json", "studylog.json", "remote.json", "curriculum.json", "sync_state.json"]:
		var p: String = "user://" + fn
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			out[fn] = [f.get_length() if f != null else -1, FileAccess.get_modified_time(p)]
		else:
			out[fn] = null
	out["songs_dir"] = DirAccess.dir_exists_absolute(_g("user://songs"))
	out["songs"] = _listing("user://songs")
	return out


func _fresh() -> void:
	SongStore.write_hook = Callable()
	SongStore.rename_fail = false
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.clear_cache()
	SongStore.take_quarantined()
	_rm_rf(ROOT)


func _texts(root: Node) -> String:
	var t := ""
	for n in root.find_children("*", "Label", true, false):
		t += (n as Label).text + "\n"
	for n in root.find_children("*", "Button", true, false):
		t += (n as Button).text + "\n"
	return t


func _toast_has(sub: String) -> bool:
	for t in _toasts:
		if str(t[0]).contains(sub):
			return true
	return false


func _connect_pc(song: bool = true, provider: String = "opencode") -> void:
	Backend.health = {"song": song, "song_v": 1, "llm": true, "llm_provider": provider}
	Backend._set_status(Backend.Status.READY)


func _disconnect_pc() -> void:
	Backend.health = {}
	Backend._set_status(Backend.Status.FAILED, "x")


func _consent(on: bool) -> void:
	Store.prefs["song_consent"] = on


func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _new_screen(lang: String = "en") -> SongAddScreen:
	var s := SongAddScreen.new()
	_stage(s)
	s.lrclib_base_url = LR_BASE
	s.transfer.poll_interval = 0.05
	s.transfer.retry_delays = [0.02, 0.02, 0.02]
	s.song_added.connect(func(id: String) -> void: _added.append(id))
	s.closed.connect(func() -> void: _closed += 1)
	s.open(lang, {})
	return s


func _drop(s: SongAddScreen) -> void:
	if s != null and is_instance_valid(s):
		if s.transfer != null and s.transfer.busy:
			s.transfer.abandon()
		s.queue_free()


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled:
		(b as Button).pressed.emit()
		return true
	return false


## 안 보이는 시험 파일: 대화상자 대신 path 를 바로 돌려준다.
func _hook_pick(s: SongAddScreen, path: String) -> void:
	s.importer.dialog_hook = func(_f: PackedStringArray, done: Callable) -> bool:
		done.call(path)
		return true


## x-overflow check: every visible control inside `root` stays inside root's horizontal extent.
func _overflow(root: Control) -> Array:
	var bad: Array = []
	var rr: Rect2 = root.get_global_rect()
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		if r.size.x <= 0.0:
			continue
		if r.position.x < rr.position.x - 0.5 or r.end.x > rr.end.x + 0.5:
			bad.append("%s %s" % [c.get_class(), r])
	return bad


func _lines_in_limits(lines: Array) -> bool:
	if lines.size() > 400:
		return false
	var total := 0
	for l in lines:
		var n: int = str((l as Dictionary)["text"]).length()
		if n > 200:
			return false
		total += n
	return total <= 20000


func _numbered(n: int) -> String:
	var a: PackedStringArray = []
	for i in n:
		a.append("Made up line number %d of the test song" % (i + 1))
	return "\n".join(a)


# ---------------------------------------------------------------- servers

func _http(base: String, method: int, path: String, body: Dictionary = {}) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	var hdr := PackedStringArray(["Content-Type: application/json"])
	var err: int = req.request(base + path, hdr, method, JSON.stringify(body) if method == HTTPClient.METHOD_POST else "")
	if err != OK:
		req.queue_free()
		return {"code": 0, "data": null}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"code": 0, "data": null}
	var txt: String = (res[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(res[1]), "data": JSON.parse_string(txt) if (txt.begins_with("{") or txt.begins_with("[")) else null}


func _lr_log() -> Array:
	var r: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_log")
	if r["data"] is Dictionary:
		return (r["data"] as Dictionary).get("requests", [])
	return []


func _lr_reset() -> void:
	await _http(LR_BASE, HTTPClient.METHOD_POST, "/_reset")


func _lr_paths(reqs: Array) -> Array:
	var out: Array = []
	for r in reqs:
		out.append(str(r["path"]))
	return out


func _start_py(args: PackedStringArray, base: String, ping: String, pid_slot: String) -> bool:
	var busy: Dictionary = await _http(base, HTTPClient.METHOD_GET, ping)
	for i in 60: # another worker's test may hold the port for a moment: wait for it (never kill it)
		if int(busy["code"]) == 0:
			break
		await get_tree().create_timer(2.0).timeout
		busy = await _http(base, HTTPClient.METHOD_GET, ping)
	if int(busy["code"]) != 0:
		print("  port of %s is still in use, not starting" % base)
		return false
	var py: String = _arg("--python=")
	if py == "":
		py = DEFAULT_PY
	var pid: int = OS.create_process(py, args)
	if pid <= 0:
		return false
	if pid_slot == "lr":
		_lr_pid = pid
	else:
		_sv_pid = pid
	for i in 150:
		await get_tree().create_timer(0.2).timeout
		var h: Dictionary = await _http(base, HTTPClient.METHOD_GET, ping)
		if int(h["code"]) == 200:
			return true
	return false


func _kill(pid: int) -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		OS.execute("taskkill", PackedStringArray(["/PID", str(pid), "/T", "/F"])) ## only the process this test started, and its children
	else:
		OS.kill(pid)


func _start_lrclib() -> bool:
	var script: String = _g("res://tests/fixtures/song/fake_lrclib.py")
	return await _start_py(PackedStringArray(["-I", script, "--port", str(LR_PORT)]), LR_BASE, "/_ping", "lr")


func _stop_lrclib() -> void:
	if _lr_pid > 0:
		await _http(LR_BASE, HTTPClient.METHOD_POST, "/_quit")
		await get_tree().create_timer(0.3).timeout
		_kill(_lr_pid)
		_lr_pid = -1


func _start_stub() -> bool:
	var script: String = _g("res://").path_join("../backend/lan_stub_server.py").simplify_path()
	var args := PackedStringArray(["-I", script, "--song", "--port", str(SV_PORT), "--song-dir", _g(JOBS_DIR), "--tag", "u2test",
		"--devices-file", _g(DIR).path_join("devices.json")])
	return await _start_py(args, SV_BASE, "/health", "sv")


func _stop_stub() -> void:
	if _sv_pid > 0:
		_kill(_sv_pid)
		_sv_pid = -1


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== song_add_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	_rm_rf(DIR)
	_rm_rf(JOBS_DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.prefs.erase("song_consent")
	Store.prefs.erase("song_translate")
	Store.prefs.erase("song_gloss")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port until a section starts a server: the run must never reach the user's engine (8770)
	Sheet.animate = false
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	var old_root: String = SongStore.root
	SongStore.root = ROOT
	_fresh()

	_selftest()
	_test_pure()
	_test_source_rules()
	await _test_gate()
	await _test_pick()
	await _test_screen_lyrics()

	var lr_up: bool = await _start_lrclib()
	ok(lr_up, "fake LRCLIB (fake_lrclib.py) is up on port %d" % LR_PORT)
	if lr_up:
		await _test_lrclib()
	await _stop_lrclib()
	await get_tree().create_timer(0.3).timeout
	var lr_closed: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	ok(int(lr_closed["code"]) == 0, "fake LRCLIB is gone and port %d is closed again" % LR_PORT)

	Api.set_remote(SV_BASE, "")
	var sv_up: bool = await _start_stub()
	ok(sv_up, "stub server (lan_stub_server.py --song) is up on port %d" % SV_PORT)
	if sv_up:
		await _test_stub_flow()
	_stop_stub()
	await get_tree().create_timer(0.4).timeout
	var sv_closed: Dictionary = await _http(SV_BASE, HTTPClient.METHOD_GET, "/health")
	ok(int(sv_closed["code"]) == 0, "stub server is gone and port %d is closed again" % SV_PORT)

	spy = Spy.new()
	add_child(spy)
	var spy_up: bool = spy.setup(SV_PORT)
	for i in 60:
		if spy_up:
			break
		await get_tree().create_timer(2.0).timeout
		spy_up = spy.setup(SV_PORT)
	ok(spy_up, "spy server is listening on port %d" % SV_PORT)
	if spy_up:
		await _test_spy_requests()
		await _test_transfer_ui()
		await _test_layout()
	spy.stop()
	spy.queue_free()
	spy = null
	Api.clear_remote()
	await _test_real_folder_untouched()

	_close_sheets()
	_fresh()
	SongStore.root = old_root
	Store.prefs.erase("song_consent")
	Store.prefs.erase("song_translate")
	Store.prefs.erase("song_gloss")
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Backend.health = _old_health
	Backend.status = _old_status
	_rm_rf(DIR)
	_rm_rf(JOBS_DIR)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "test folders cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_add_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _close_sheets() -> void:
	for i in 5:
		if not Sheet.close_top("dismiss"):
			break


# ---------------------------------------------------------------- sections

## 검사기 자체: 일부러 틀린 입력을 넣으면 실제로 FAIL 을 내는지.
func _selftest() -> void:
	print("[checker self-test: wrong input must FAIL]")
	var too_many: Array = []
	for i in 401:
		too_many.append({"text": "x"})
	ok(not _lines_in_limits(too_many), "limit checker rejects 401 lines")
	ok(not _lines_in_limits([{"text": "y".repeat(201)}]), "limit checker rejects a 201 character line")
	var big: Array = []
	for i in 150:
		big.append({"text": "z".repeat(150)})
	ok(not _lines_in_limits(big), "limit checker rejects 22500 characters in total")
	ok(_lines_in_limits([{"text": "fine"}]), "limit checker accepts a normal line")
	var wide := Control.new()
	wide.position = Vector2(0, 0)
	wide.size = Vector2(300, 20)
	var child := ColorRect.new()
	child.position = Vector2(250, 0)
	child.size = Vector2(200, 10)
	wide.add_child(child)
	add_child(wide)
	ok(not _overflow(wide).is_empty(), "overflow checker reports a child that sticks out sideways")
	wide.queue_free()
	var ai_wrong: Dictionary = {"options": {"ai_ok": true}}
	ok(not _ai_rule(false, true, ai_wrong), "ai_ok rule checker rejects ai_ok:true without consent")
	ok(not _ai_rule(true, false, ai_wrong), "ai_ok rule checker rejects ai_ok:true with the translation off")
	ok(_ai_rule(true, true, ai_wrong), "ai_ok rule checker accepts ai_ok:true with consent and translation on")
	ok(not _calls_ok(2, 1) and not _calls_ok(1, 2) and _calls_ok(1, 1) and _calls_ok(0, 0), "call-count checker: get <= 1 and search <= 1 only")


func _ai_rule(consent: bool, translate: bool, body: Dictionary) -> bool:
	var want: bool = consent and translate
	return bool((body.get("options", {}) as Dictionary).get("ai_ok", null)) == want


func _calls_ok(get_n: int, search_n: int) -> bool:
	return get_n <= 1 and search_n <= 1


func _test_pure() -> void:
	print("[lyrics preparation, texts, file checks]")
	# plain text: stanzas
	var p1: Dictionary = SongAddScreen.prepare_lyrics("pasted", "Alpha line\nBeta line\n\nGamma line")
	var l1: Array = p1["lines"]
	ok(l1.size() == 3 and not bool(p1["timed"]) and l1[0]["t"] == null and int(l1[2]["p"]) == 1 and int(l1[1]["p"]) == 0, "plain text: 3 lines, t null, stanza numbers 0 0 1 (from split_plain)")
	# LRC with a gap line: gap dropped, times kept (t = -1.0 never reaches the server), stanza number grows after the gap
	var p2: Dictionary = SongAddScreen.prepare_lyrics("pasted", "[00:01.00] one\n[00:03.50] two\n[00:05.00]\n[00:06.00] three")
	var l2: Array = p2["lines"]
	ok(bool(p2["timed"]) and l2.size() == 3 and is_equal_approx(float(l2[0]["t"]), 1.0) and is_equal_approx(float(l2[2]["t"]), 6.0) and int(l2[2]["p"]) == 1, "LRC: 3 lines with times, the empty timed line is dropped and starts stanza 1")
	var no_gap := true
	var no_neg := true
	for l in l2:
		if str(l["text"]) == "":
			no_gap = false
		if l["t"] != null and float(l["t"]) < 0.0:
			no_neg = false
	ok(no_gap and no_neg, "LRC: no empty text line and no negative time is left")
	# section marks
	var p3: Dictionary = SongAddScreen.prepare_lyrics("pasted", "[Verse 1]\nHello there\n[Chorus]\nWorld again\n[ ar:Nobody ]")
	ok((p3["lines"] as Array).size() == 2 and int(p3["marks"]) == 3 and "\n".join(p3["notes"]).contains("구간 표시 3줄"), "[Chorus]-like lines (only a [..] group) are left out, and the person is told")
	var p3b: Dictionary = SongAddScreen.prepare_lyrics("pasted", "[00:01.00] [Chorus]\n[00:02.00] real words")
	ok((p3b["lines"] as Array).size() == 1 and str(p3b["lines"][0]["text"]) == "real words", "a timed [Chorus] line is left out too")
	# 401 lines
	var p4: Dictionary = SongAddScreen.prepare_lyrics("pasted", _numbered(401))
	ok((p4["lines"] as Array).size() == 400 and int(p4["cut_lines"]) == 1 and "\n".join(p4["notes"]).contains("400줄까지"), "401 lines -> 400 lines and a note '400줄까지'")
	var p4b: Dictionary = SongAddScreen.prepare_lyrics("pasted", _numbered(400))
	ok((p4b["lines"] as Array).size() == 400 and (p4b["notes"] as Array).is_empty(), "exactly 400 lines: nothing cut, no note")
	# 201 characters
	var p5: Dictionary = SongAddScreen.prepare_lyrics("pasted", "short\n" + "a".repeat(201) + "\n" + "b".repeat(200))
	ok(str(p5["lines"][1]["text"]).length() == 200 and str(p5["lines"][2]["text"]).length() == 200 and int(p5["cut_chars"]) == 1 and "\n".join(p5["notes"]).contains("200자"), "a 201 character line -> 200 characters (the 200 one is untouched) and a note '200자'")
	# 20000 characters in total
	var big: PackedStringArray = []
	for i in 150:
		big.append(str(i).pad_zeros(3) + "c".repeat(147))
	var p6: Dictionary = SongAddScreen.prepare_lyrics("pasted", "\n".join(big))
	var tot := 0
	for l in p6["lines"]:
		tot += str(l["text"]).length()
	ok(bool(p6["cut_total"]) and tot <= 20000 and tot > 19000 and _lines_in_limits(p6["lines"]) and "\n".join(p6["notes"]).contains("20000자"), "22500 characters -> at most 20000 (%d) and a note '20000자'" % tot)
	# the same limits as the sender (SongTransfer cuts again but must not find more to cut)
	var body: Dictionary = SongTransfer.job_body("0".repeat(32), {"lang": "en", "lyrics": {"source": "pasted", "lines": p6["lines"]}})
	ok((body["lyrics"]["lines"] as Array).size() == (p6["lines"] as Array).size(), "SongTransfer.job_body keeps every prepared line (same limits)")
	# LRCLIB records
	var rec_s := {"id": 7, "syncedLyrics": "[00:02.00] first\n[00:04.00] second", "plainLyrics": "first\nsecond"}
	var p7: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", rec_s)
	ok(bool(p7["timed"]) and (p7["lines"] as Array).size() == 2, "LRCLIB record with synced lyrics -> timed lines")
	var rec_p := {"id": 8, "syncedLyrics": "", "plainLyrics": "first\nsecond\n\n[Chorus]\nthird"}
	var p8: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", rec_p)
	ok(not bool(p8["timed"]) and (p8["lines"] as Array).size() == 3 and p8["lines"][0]["t"] == null and int(p8["lines"][2]["p"]) == 1, "LRCLIB record with plain lyrics only -> lines without times (has_synced false -> plain), [Chorus] left out")
	var p9: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", {"id": 9, "syncedLyrics": "", "plainLyrics": ""})
	ok((p9["lines"] as Array).is_empty(), "LRCLIB record with no lyrics -> no lines")
	var p10: Dictionary = SongAddScreen.prepare_lyrics("pasted", "")
	var p11: Dictionary = SongAddScreen.prepare_lyrics("pasted", "\ufeffbom line\u0001 with ctrl\r\nsecond\r\n")
	ok((p10["lines"] as Array).is_empty() and (p11["lines"] as Array).size() == 2 and not str(p11["lines"][0]["text"]).contains("\u0001"), "broken input: empty text -> no lines; BOM / control character / CRLF handled")
	var t0: int = Time.get_ticks_msec()
	var p12: Dictionary = SongAddScreen.prepare_lyrics("pasted", "x\n".repeat(60000))
	ok(_lines_in_limits(p12["lines"]) and Time.get_ticks_msec() - t0 < 3000, "60000 lines of input are cut to the limits quickly (%d ms)" % (Time.get_ticks_msec() - t0))
	# candidate texts
	var huge := {"trackName": "あ".repeat(2000000), "artistName": "B".repeat(5000), "albumName": "C".repeat(300), "duration": 200.0, "syncedLyrics": "[00:01.00] x", "plainLyrics": ""}
	var t1: int = Time.get_ticks_msec()
	var ct: Dictionary = SongAddScreen.candidate_text(huge, 150.0)
	ok(str(ct["main"]).length() <= 60 + 3 + 40 and str(ct["sub"]).length() <= 30 + 60 and str(ct["main"]).contains("…") and Time.get_ticks_msec() - t1 < 1000, "a 2 million character LRCLIB name is cut with an ellipsis (main %d, sub %d chars, %d ms)" % [str(ct["main"]).length(), str(ct["sub"]).length(), Time.get_ticks_msec() - t1])
	ok(str(ct["sub"]).contains("50초 달라요") and str(ct["sub"]).contains("3:20") and str(ct["sub"]).contains("줄 시간 있음"), "candidate sub line: length, difference from the file (>2 s) and the kind of lyrics")
	var ct2: Dictionary = SongAddScreen.candidate_text({"trackName": "Same", "artistName": "X", "duration": 100.5, "plainLyrics": "a"}, 100.0)
	ok(not str(ct2["sub"]).contains("달라요") and str(ct2["sub"]).contains("글자만 있음"), "within 2 s: no 'differs' text; plain-only is labelled")
	ok(not SongAddScreen.usable_record({"instrumental": true, "plainLyrics": "a"}) and not SongAddScreen.usable_record({}) and SongAddScreen.usable_record({"plainLyrics": "a"}), "usable_record: instrumental / empty are not usable")
	var gn: Array = SongAddScreen.guess_from_name("Some Artist - Some Title.mp3")
	var gn2: Array = SongAddScreen.guess_from_name("plain_name.m4a")
	ok(gn == ["Some Title", "Some Artist"] and gn2 == ["plain name", ""], "file name -> title / artist guess")
	# ai_ok = consent AND translate
	_consent(false)
	ok(not SongAddScreen.ai_ok_for(true) and not SongAddScreen.ai_ok_for(false), "ai_ok_for: without consent always false")
	_consent(true)
	ok(SongAddScreen.ai_ok_for(true) and not SongAddScreen.ai_ok_for(false), "ai_ok_for: consent + translation on = true, translation off = false")
	_consent(false)
	# file checks
	var wav_p: String = DIR.path_join("t3.wav")
	_write_bytes(wav_p, _wav(3))
	var txt_p: String = DIR.path_join("notes.txt")
	_write_bytes(txt_p, "hello".to_utf8_buffer())
	var empty_p: String = DIR.path_join("empty.mp3")
	_write_bytes(empty_p, PackedByteArray())
	ok(bool(SongImport.inspect(wav_p)["ok"]) and str(SongImport.inspect(wav_p)["name"]) == "t3.wav", "inspect: a wav is fine")
	ok(str(SongImport.inspect(txt_p)["err_code"]) == "bad_ext" and str(SongImport.inspect(DIR.path_join("none.mp3"))["err_code"]) == "file_open" and str(SongImport.inspect(empty_p)["err_code"]) == "empty_file", "inspect: .txt -> bad_ext, missing -> file_open, empty -> empty_file")
	ok(str(SongImport.inspect("content://nothing/here")["err_code"]) == "file_open", "inspect: a content:// address is not rejected for its extension (it just cannot be opened here)")
	var d_wav: float = SongImport.probe_duration(ProjectSettings.globalize_path(wav_p))
	var d_mp3: float = SongImport.probe_duration(TONE)
	ok(absf(d_wav - 3.0) < 0.05, "probe_duration: wav header -> 3.0 s (%.3f)" % d_wav)
	ok(d_mp3 > 7.0 and d_mp3 < 9.0, "probe_duration: mp3 -> about 8 s (%.2f)" % d_mp3)
	ok(SongImport.probe_duration(txt_p) == -1.0 and SongImport.probe_duration(DIR.path_join("none.wav")) == -1.0, "probe_duration: unknown format / missing file -> -1.0")
	ok(SongImport.filters().size() >= 1, "dialog filters: at least one (%s)" % [SongImport.filters()])


func _test_source_rules() -> void:
	print("[source rules]")
	var imp: String = FileAccess.get_file_as_string("res://scripts/song/song_import.gd")
	var scr: String = FileAccess.get_file_as_string("res://scripts/song/song_add_screen.gd")
	var bad := 0
	for needle in ["request_permission", "READ_MEDIA", "READ_EXTERNAL", "OS.request", "permissions/"]:
		if imp.contains(needle) or scr.contains(needle):
			bad += 1
	ok(bad == 0, "no permission request code in song_import.gd / song_add_screen.gd (12.1a: no read permission is added)")
	ok(not scr.contains("HTTPRequest") and not imp.contains("HTTPRequest"), "no direct HTTPRequest in the screen / importer (all PC traffic goes through SongTransfer / Api)")
	ok(not scr.contains("cancel_request") and not scr.contains("/api/publish") and not scr.contains("request-challenge"), "no cancel_request / publish / challenge in the screen")
	var proj: String = FileAccess.get_file_as_string("res://export_presets.cfg")
	ok(not proj.contains("READ_MEDIA_AUDIO") and not proj.contains("READ_EXTERNAL_STORAGE"), "export_presets.cfg has no audio / storage read permission")
	ok(imp.contains("file_dialog_show") and imp.contains("FileDialog") and imp.contains("is_phone"), "SongImport uses FileDialog (PC) and DisplayServer.file_dialog_show (phone)")


func _test_gate() -> void:
	print("[PC missing / old PC / phone only / storage full]")
	_fresh()
	_toasts.clear()
	var sent: int = Api.sent_count
	_disconnect_pc()
	var s := _new_screen()
	await _frames(2)
	ok(_texts(s).contains("곡 추가는 PC 연결 시 가능해요"), "no PC: the screen explains that adding a song needs the PC")
	var r: String = s.make()
	ok(r.contains("PC 연결") and not s.transfer.busy and s.phase == "form", "no PC: make() refuses with the explanation, nothing starts")
	ok(Api.sent_count == sent, "no PC: no request sent (Api.sent_count %d -> %d)" % [sent, Api.sent_count])
	ok(_toast_has("PC 연결"), "no PC: the person is also told by a toast")
	# the notice follows the engine coming up
	_connect_pc(true)
	await _frames(2)
	ok(not _texts(s).contains("곡 추가는 PC 연결 시 가능해요"), "PC connects: the notice is gone without reopening the screen")
	# old PC
	_connect_pc(false)
	await _frames(2)
	ok(_texts(s).contains("PC 프로그램을 최신으로 업데이트해 주세요"), "old PC (no 'song' in /health): 'update the PC program' notice")
	sent = Api.sent_count ## other parts of the app may talk to the PC when it connects: count only around make()
	var r2: String = s.make()
	ok(r2.contains("업데이트") and Api.sent_count == sent and not s.transfer.busy, "old PC: make() refuses, no request sent")
	# phone-only mode
	_connect_pc(true)
	Route.phone_hook = func() -> bool: return true
	var old_mode: String = Route.mode
	Route.mode = "phone"
	await _frames(1)
	s._on_env_changed()
	await _frames(2)
	ok(SongAddScreen.block_reason() == "no_pc" and _texts(s).contains("곡 추가는 PC 연결 시 가능해요"), "phone-only mode: adding is blocked with the PC explanation")
	sent = Api.sent_count
	var r3: String = s.make()
	ok(r3 != "" and Api.sent_count == sent and not s.transfer.busy, "phone-only mode: make() refuses, no request sent")
	Route.mode = old_mode
	Route.phone_hook = Callable()
	# storage full
	_connect_pc(true)
	SongStore.max_songs = 0
	ok(SongAddScreen.block_reason() == "full" and SongAddScreen.block_text("full").contains("가득"), "40 songs / 400 MiB reached: 'full' notice")
	SongStore.max_songs = SongStore.MAX_SONGS
	ok(SongAddScreen.block_reason() == "", "PC connected with the song feature and room left: nothing blocks")
	_drop(s)
	await _frames(2)


func _test_pick() -> void:
	print("[picking a file]")
	_fresh()
	_connect_pc(true)
	var s := _new_screen()
	await _frames(2)
	var sent: int = Api.sent_count
	# a normal pick
	s.duration_probe = func(_p: String) -> float: return 8.0
	_hook_pick(s, TONE)
	_press(s, "BtnPick")
	await _frames(2)
	ok(not s.file.is_empty() and str(s.file["name"]) == "tone_8s.mp3" and int(s.file["size"]) > 1000 and is_equal_approx(float(s.file["duration"]), 8.0), "pick: tone_8s.mp3 accepted (name, size, 8 s)")
	ok(_texts(s).contains("tone_8s.mp3") and _texts(s).contains("0:08") and s.title_text == "tone 8s", "pick: the file name, its length and a title guess are shown")
	ok(s.importer.open_count == 1 and not s.importer.picking, "pick: the dialog was opened once and is closed again")
	# cancel
	var canceled: Array = [0]
	s.importer.canceled.connect(func() -> void: canceled[0] += 1)
	s.importer.dialog_hook = func(_f: PackedStringArray, done: Callable) -> bool:
		done.call("")
		return true
	s.pick_file()
	await _frames(1)
	ok(canceled[0] == 1 and str(s.file["name"]) == "tone_8s.mp3", "pick cancelled: the earlier file stays, canceled signal once")
	# second pick() while a dialog is open is ignored
	var held: Array = [Callable()]
	s.importer.dialog_hook = func(_f: PackedStringArray, done: Callable) -> bool:
		held[0] = done
		return true
	var oc: int = s.importer.open_count
	s.importer.pick()
	s.importer.pick()
	ok(s.importer.open_count == oc + 1 and s.importer.picking, "pick while a dialog is open: ignored (one dialog)")
	(held[0] as Callable).call("")
	ok(not s.importer.picking, "pick: closing the dialog frees the next pick")
	# wrong files
	var txt_p: String = _g(DIR.path_join("lyrics.txt"))
	_write_bytes(txt_p, "hi".to_utf8_buffer())
	_hook_pick(s, txt_p)
	s.pick_file()
	await _frames(2)
	ok(s.pick_error.contains("mp3, ogg, wav") and str(s.file["name"]) == "tone_8s.mp3" and _find(s, "PickError") != null, "a .txt file is refused with the list of formats, the earlier file stays")
	var empty_p: String = _g(DIR.path_join("empty.mp3"))
	_write_bytes(empty_p, PackedByteArray())
	_hook_pick(s, empty_p)
	s.pick_file()
	await _frames(1)
	ok(s.pick_error.contains("빈 파일"), "an empty file is refused")
	var big_p: String = _g(DIR.path_join("big.mp3"))
	_write_zero(big_p, SongImport.MAX_BYTES + 1)
	_hook_pick(s, big_p)
	s.pick_file()
	await _frames(1)
	ok(s.pick_error.contains("64MB") and str(s.file["name"]) == "tone_8s.mp3", "64 MiB + 1 byte: refused before any upload, the earlier file stays")
	_write_zero(big_p, SongImport.MAX_BYTES)
	_hook_pick(s, big_p)
	s.pick_file()
	await _frames(1)
	ok(s.pick_error == "" and str(s.file["name"]) == "big.mp3" and int(s.file["size"]) == SongImport.MAX_BYTES, "exactly 64 MiB is accepted")
	DirAccess.remove_absolute(big_p)
	# too long (probe says 11 minutes)
	s.duration_probe = func(_p: String) -> float: return 660.0
	_hook_pick(s, TONE)
	s.pick_file()
	await _frames(1)
	ok(s.pick_error.contains("10분") and str(s.file["name"]) == "big.mp3", "a 660 s song: 'under 10 minutes' notice, the earlier file stays")
	s.duration_probe = func(_p: String) -> float: return 600.0
	s.pick_file()
	await _frames(1)
	ok(s.pick_error == "" and str(s.file["name"]) == "tone_8s.mp3", "exactly 600 s is accepted")
	s.duration_probe = func(_p: String) -> float: return -1.0
	s.pick_file()
	await _frames(1)
	ok(s.pick_error == "" and float(s.file["duration"]) < 0.0, "unknown length (m4a / flac): accepted, the PC checks the length")
	# a dialog that cannot open
	s.importer.dialog_hook = func(_f: PackedStringArray, _done: Callable) -> bool: return false
	s.pick_file()
	await _frames(1)
	var msg_ok: bool = s.pick_error.contains("이 폰에서는 파일을 고를 수 없어요") if _phone else s.pick_error.contains("파일 선택 창을 열 수 없어요")
	ok(msg_ok and not s.importer.picking, "a dialog that cannot open: only the 'cannot pick' notice (%s)" % s.pick_error)
	if _phone:
		# no hook at all: the real phone path. A headless run has no system file dialog.
		s.importer.dialog_hook = Callable()
		var failed_msgs: Array = []
		s.importer.failed.connect(func(m: String) -> void: failed_msgs.append(m))
		s.pick_file()
		await _frames(2)
		ok(failed_msgs.size() == 1 and str(failed_msgs[0]).contains("이 폰에서는 파일을 고를 수 없어요") and not s.importer.picking, "phone without a system file dialog: failed('이 폰에서는 파일을 고를 수 없어요') once, no permission asked")
	ok(Api.sent_count == sent, "picking and refusing files sent no request (Api.sent_count %d -> %d)" % [sent, Api.sent_count])
	_drop(s)
	await _frames(2)


func _test_screen_lyrics() -> void:
	print("[paste box and preview]")
	_fresh()
	_connect_pc(true)
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 8.0
	await _frames(2)
	s.set_file(TONE)
	s.set_source("pasted")
	await _frames(2)
	var te: TextEdit = _find(s, "PasteInput") as TextEdit
	ok(te != null, "pasted: a multi-line text box is shown")
	if te != null:
		te.text = _numbered(401)
		te.text_changed.emit()
		await _frames(1)
	var pv: Label = _find(s, "LyricsPreview") as Label
	ok(pv != null and pv.text.contains("400줄까지") and pv.text.contains("400줄"), "401 pasted lines: the preview says '400줄까지' while typing")
	ok(_lines_in_limits(s.build_params()["lyrics"]["lines"]) and (s.build_params()["lyrics"]["lines"] as Array).size() == 400, "401 pasted lines: the request carries 400 lines")
	s.set_pasted("[00:01.00] one\n[00:02.00] two")
	await _frames(1)
	ok(s.preview_text().contains("2줄") and s.preview_text().contains("시간이 있어요") and s.current_lyrics()["timed"], "LRC paste: 2 lines with times")
	var p: Dictionary = s.build_params()
	ok(bool(p["options"]["verify"]) and p["lyrics"]["source"] == "pasted" and not p["lyrics"].has("lrclib_id"), "LRC paste: verify option on, source pasted, no lrclib_id")
	s.set_pasted("just words\nno times")
	ok(not bool(s.build_params()["options"]["verify"]) and s.build_params()["lyrics"]["lines"][0]["t"] == null, "plain paste: verify is off (it only means something with times), t is null")
	s.set_source("none")
	ok(s.build_params()["lyrics"]["lines"] == [] and s.build_params()["lyrics"]["source"] == "none", "receive-by-listening: no lines, source none")
	s.set_source("pasted")
	s.set_pasted("")
	var before: int = Api.sent_count
	var e: String = s.make()
	ok(e.contains("붙여넣은 가사가 없어요") and Api.sent_count == before and not s.transfer.busy, "empty paste: make() refuses with a hint, nothing is sent")
	s.set_source("lrclib")
	var e2: String = s.make()
	ok(e2.contains("찾아서") and Api.sent_count == before, "lrclib without a chosen record: make() refuses with a hint, nothing is sent")
	_drop(s)
	await _frames(2)


func _test_lrclib() -> void:
	print("[LRCLIB: only on the button, get <= 1 + search <= 1 per song]")
	_fresh()
	_connect_pc(true)
	await _lr_reset()
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 21.0
	await _frames(2)
	s.set_file(TONE)
	s.set_title("Kettle Morning")
	s.set_artist("Test Artist")
	s.set_source("lrclib")
	await _frames(2)
	await get_tree().create_timer(0.8).timeout
	var log0: Array = await _lr_log()
	ok(log0.is_empty() and s._client == null and s.lr_get_calls == 0 and s.lr_search_calls == 0, "opening, picking a file, typing title / artist, choosing the LRCLIB source: 0 calls (no client even created)")
	ok(_find(s, "BtnFind") != null and _find(s, "BtnSearch") != null, "the 'find' and 'similar' buttons exist")
	ok((_find(s, "BtnSearch") as Button).disabled, "'similar' is not available before the first find")
	# --- one tap = one get
	_press(s, "BtnFind")
	ok(s.lr_busy and s.lr_status == "busy" and _texts(s).contains("찾는 중"), "while waiting the screen says it is searching")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get finished")
	var log1: Array = await _lr_log()
	ok(log1.size() == 1 and str(log1[0]["path"]) == "/api/get", "after one tap: exactly 1 request, GET /api/get (%s)" % [_lr_paths(log1)])
	ok(str(log1[0]["query"].get("duration", "")) == "21" and str(log1[0]["query"].get("track_name", "")) == "Kettle Morning", "the get carried title and the file length (21 s)")
	ok(str(log1[0]["headers"]["user-agent"]).begins_with("HoehwaPractice/1.") and str(log1[0]["headers"]["lrclib-client"]).begins_with("HoehwaPractice/1."), "the get identified the app (User-Agent and Lrclib-Client)")
	await _frames(2)
	ok(s.lr_status == "found" and not s.lr_record.is_empty() and int(s.lr_record["id"]) == 1001 and s.lr_items.size() == 1, "exact hit: the one record is listed and pre-selected")
	ok(_find(s, "Attribution") != null and (_find(s, "Attribution") as Label).text == "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요", "LRCLIB lyrics chosen: the attribution text is shown (L7)")
	ok(s.preview_text().contains("줄마다 시간이 있어요"), "the chosen record has line times")
	# --- more taps do not call again
	_press(s, "BtnFind")
	_press(s, "BtnFind")
	_press(s, "BtnFind")
	await get_tree().create_timer(0.8).timeout
	var log2: Array = await _lr_log()
	ok(log2.size() == 1 and s.lr_get_calls == 1, "tapping 'find' 3 more times: still 1 request (get <= 1 per song)")
	ok(_toast_has("이미 그 방법으로"), "the extra taps explain why nothing was sent")
	# --- one search
	_press(s, "BtnSearch")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "search finished")
	_press(s, "BtnSearch")
	s.search_lyrics()
	s.search_lyrics()
	await get_tree().create_timer(0.8).timeout
	var log3: Array = await _lr_log()
	ok(log3.size() == 2 and str(log3[1]["path"]) == "/api/search" and s.lr_search_calls == 1, "search: exactly 1 more request after several taps (total 2: %s)" % [_lr_paths(log3)])
	ok(_calls_ok(s.lr_get_calls, s.lr_search_calls), "per song at most 1 get and 1 search")
	await _frames(2)
	ok(s.lr_items.size() >= 2 and (_find(s, "Candidates") != null), "the similar-song candidates are listed (%d)" % s.lr_items.size())
	ok(float((s.lr_items[0] as Dictionary)["duration_diff"]) <= float((s.lr_items[1] as Dictionary)["duration_diff"]), "candidates are ordered by how close their length is to the file")
	# choose a different one (the 31 s long edit): shown as 'differs', can still be chosen
	var idx_long := -1
	for i in s.lr_items.size():
		if int((s.lr_items[i] as Dictionary)["id"]) == 1002:
			idx_long = i
	ok(idx_long >= 0 and SongAddScreen.candidate_text(s.lr_items[idx_long], 21.0)["sub"].contains("10초 달라요"), "a 31 s record is marked '파일과 10초 달라요'")
	ok(s.choose_candidate(idx_long) and int(s.lr_record["id"]) == 1002, "choosing a candidate selects it")
	# --- many results are cut to 20
	_drop(s)
	await _frames(2)
	await _lr_reset()
	var s2 := _new_screen()
	s2.duration_probe = func(_p: String) -> float: return 100.0
	s2.set_file(TONE)
	s2.set_title("many")
	s2.set_artist("")
	s2.set_source("lrclib")
	s2.search_lyrics()
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "search for 'many' finished")
	await _frames(3)
	var rows := 0
	var g: Node = _find(s2, "Candidates")
	if g != null:
		for l in g.find_children("*", "Label", true, false):
			if (l as Label).theme_type_variation == &"ListMain":
				rows += 1
	ok(s2.lr_items.size() == 20 and rows == 20, "25 results: at most 20 are kept and shown (%d rows)" % rows)
	var log4: Array = await _lr_log()
	ok(log4.size() == 1 and str(log4[0]["path"]) == "/api/search" and s2.lr_get_calls == 0, "search without a get: 1 request, the search budget is separate")
	ok(float(s2.lr_items[0]["duration_diff"]) < 1.0 and str(s2.lr_items[0]["duration"]) == "100.0", "the 100 s record is first for a 100 s file")
	_drop(s2)
	await _frames(2)

	# --- file length outside +-2 s: get answers 404 -> the person taps 'similar' (get 1 + search 1)
	await _lr_reset()
	var s3 := _new_screen()
	s3.duration_probe = func(_p: String) -> float: return 8.0
	s3.set_file(TONE)
	s3.set_title("Kettle Morning")
	s3.set_artist("Test Artist")
	s3.set_source("lrclib")
	_press(s3, "BtnFind")
	ok(await _until(func() -> bool: return not s3.lr_busy, 10.0), "a file of the wrong length: get finished")
	await _frames(2)
	ok(s3.lr_status == "none" and s3.lr_record.is_empty() and s3.lr_message.contains("비슷한 곡 찾기"), "get 404 (length differs by more than 2 s): 'not found', it points to the similar-song button")
	ok(not (_find(s3, "BtnSearch") as Button).disabled, "'similar' is available after the get")
	_press(s3, "BtnSearch")
	ok(await _until(func() -> bool: return not s3.lr_busy, 10.0), "similar search finished")
	await _frames(2)
	var log5: Array = await _lr_log()
	ok(_lr_paths(log5) == ["/api/get", "/api/search"], "wrong-length file: one get then one search (%s)" % [_lr_paths(log5)])
	ok(s3.lr_items.size() >= 1 and s3.choose_candidate(0), "a candidate can be chosen after the search")
	ok(SongAddScreen.candidate_text(s3.lr_items[0], 8.0)["sub"].contains("달라요"), "the candidate says its length differs from the file")
	# plain-only and instrumental
	var plain_i := -1
	var instr_i := -1
	s3.lr_items = [{"id": 1003, "trackName": "Plain Boat", "artistName": "Test Artist", "albumName": "", "duration": 30.0, "syncedLyrics": "", "plainLyrics": "a\nb", "instrumental": false},
		{"id": 1004, "trackName": "Quiet Room", "artistName": "Test Artist", "albumName": "", "duration": 45.0, "syncedLyrics": "", "plainLyrics": "", "instrumental": true}]
	plain_i = 0
	instr_i = 1
	ok(not s3.choose_candidate(instr_i), "an instrumental record cannot be chosen")
	ok(s3.choose_candidate(plain_i) and not bool(s3.current_lyrics()["timed"]) and (s3.build_params()["lyrics"]["lines"] as Array)[0]["t"] == null and int(s3.build_params()["lyrics"]["lrclib_id"]) == 1003, "a plain-only record: lines without times, lrclib_id 1003 in the request")
	ok(not bool(s3.build_params()["options"]["verify"]), "plain-only LRCLIB lyrics: verify is off")
	_drop(s3)
	await _frames(2)

	# --- title / artist too short: no call; errors: one call, not repeated
	await _lr_reset()
	var s4 := _new_screen()
	s4.set_file(TONE)
	s4.set_title("a")
	s4.set_artist("Test Artist")
	s4.set_source("lrclib")
	s4.find_lyrics()
	await _frames(2)
	var log6: Array = await _lr_log()
	ok(log6.is_empty() and s4.lr_get_calls == 0 and s4.lr_message.contains("두 글자 이상"), "a 1 character title: no request, 'at least two characters' hint")
	s4.set_title("__500__ x")
	s4.find_lyrics()
	ok(await _until(func() -> bool: return not s4.lr_busy, 10.0), "a server error: get finished")
	await _frames(2)
	ok(s4.lr_status == "error" and s4.lr_message.contains("파일을 다시 골라"), "a server error: the message says what to do next (%s)" % s4.lr_message)
	s4.find_lyrics()
	s4.find_lyrics()
	await get_tree().create_timer(0.7).timeout
	var log7: Array = await _lr_log()
	ok(log7.size() == 1, "after an error the get is not repeated by itself or by more taps (1 request)")
	# picking the file again starts a new song: the budget is back
	s4.duration_probe = func(_p: String) -> float: return 21.0
	s4.set_file(TONE)
	ok(s4.lr_get_calls == 0 and s4.lr_search_calls == 0 and s4.lr_items.is_empty() and s4.lr_record.is_empty(), "picking a file again resets the per-song LRCLIB state")
	_drop(s4)
	await _frames(2)

	# --- the real lrclib.net can never be reached from a test
	var s5 := _new_screen()
	s5.lrclib_base_url = "https://lrclib.net"
	s5.set_file(TONE)
	s5.set_title("Kettle Morning")
	s5.set_artist("Test Artist")
	s5.set_source("lrclib")
	s5.find_lyrics()
	ok(await _until(func() -> bool: return not s5.lr_busy, 10.0), "the real host: the call ended")
	ok(s5._client != null and s5._client.sent_count == 0 and s5.lr_status == "error", "the real lrclib.net was refused by the test guard without sending (sent_count 0)")
	_drop(s5)
	# --- leaving the screen drops the client and ignores a late answer
	await _lr_reset()
	var s6 := _new_screen()
	s6.set_file(TONE)
	s6.set_title("__slow__ x")
	s6.set_artist("Test Artist")
	s6.set_source("lrclib")
	s6.find_lyrics()
	await get_tree().create_timer(0.3).timeout
	var cl: LrclibClient = s6._client
	ok(cl != null and s6.lr_busy, "a slow answer is on its way")
	var cl0: int = _closed
	s6.go_back()
	ok(_closed == cl0 + 1, "go_back while only searching: the screen closes at once")
	s6.queue_free()
	await get_tree().create_timer(2.2).timeout
	ok(not is_instance_valid(cl), "the client of a closed screen is gone after its slow answer (no late signal reached the dead screen)")


func _test_stub_flow() -> void:
	print("[real stub server: whole flow with the screen]")
	_fresh()
	_connect_pc(true)
	# --- consent false: no AI, the song still arrives (translate flag stored)
	_consent(false)
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 8.0
	s.set_file(TONE)
	s.set_title("Stub Song One")
	s.set_artist("Tester")
	s.set_source("pasted")
	s.set_pasted("The river runs past the old wooden bridge\nWe hum a tune while the lanterns glow\nMorning comes and the sky turns gold")
	var added0: int = _added.size()
	var got_progress: Array = []
	s.transfer.progress.connect(func(stage: String, pct: float, text: String) -> void: got_progress.append([stage, pct, text]))
	var e: String = s.make()
	ok(e == "" and s.phase == "running", "make() starts the transfer and shows the progress view")
	ok(await _until(func() -> bool: return s.phase == "done" or s.phase == "failed", 40.0), "stub: the whole flow ended")
	ok(s.phase == "done" and _added.size() == added0 + 1, "stub: phase done and song_added emitted once (%s / %d)" % [s.phase, _added.size() - added0])
	var id1: String = str(_added[_added.size() - 1]) if _added.size() > added0 else ""
	var song1: Dictionary = SongStore.load_song(id1)
	ok(not song1.is_empty() and (song1["lines"] as Array).size() >= 1 and bool(SongStore.list().size() == 1), "stub: the song is installed and listed (id %s)" % id1)
	ok(song1.has("translate") and song1["translate"] == true, "stub: song['translate'] = true was saved on the installed song (the person's switch)")
	var ko_empty := true
	for ln in song1["lines"]:
		if str((ln as Dictionary).get("ko", "")) != "":
			ko_empty = false
	ok(ko_empty and (song1["warnings"] as Array).has("ko_missing"), "stub: consent false -> no translation made (ko empty, warning ko_missing): the lyrics never went to the AI")
	ok(_texts(s).contains("해석은 만들지 못했어요"), "stub: the done view explains the missing translation")
	var pcts: Array = []
	for g in got_progress:
		pcts.append(float(g[1]))
	var mono := true
	for i in range(1, pcts.size()):
		if pcts[i] < pcts[i - 1] - 0.0001:
			mono = false
	ok(mono and pcts.size() > 3, "stub: progress events are monotone (%d events)" % pcts.size())
	ok(SongStore.pending_list().is_empty(), "stub: pending is empty after success")
	_drop(s)
	await _frames(2)
	# --- consent true + translate on: the AI part runs (fake LLM in the stub), translate saved true
	_consent(true)
	var s2 := _new_screen()
	s2.duration_probe = func(_p: String) -> float: return 8.0
	s2.set_file(TONE)
	s2.set_title("Stub Song Two")
	s2.set_artist("Tester")
	s2.set_source("pasted")
	s2.set_pasted("[00:01.00] The river runs past the old wooden bridge\n[00:03.50] We hum a tune while the lanterns glow\n[00:06.00] Morning comes and the sky turns gold")
	var a1: int = _added.size()
	s2.make()
	ok(await _until(func() -> bool: return s2.phase == "done" or s2.phase == "failed", 40.0), "stub, consent + translate on: the flow ended")
	var id2: String = str(_added[_added.size() - 1]) if _added.size() > a1 else ""
	var song2: Dictionary = SongStore.load_song(id2)
	var ko_n := 0
	for ln in song2.get("lines", []):
		if str((ln as Dictionary).get("ko", "")) != "":
			ko_n += 1
	ok(s2.phase == "done" and ko_n >= 1 and song2.get("translate", null) == true, "stub: consent + translate on -> the PC translated %d lines and song['translate'] is true" % ko_n)
	_drop(s2)
	await _frames(2)
	# --- consent true + translate off: no translation, song['translate'] = false
	var s3 := _new_screen()
	s3.duration_probe = func(_p: String) -> float: return 8.0
	s3.set_file(TONE)
	s3.set_title("Stub Song Three")
	s3.set_artist("Tester")
	s3.set_source("pasted")
	s3.set_pasted("The river runs past the old wooden bridge\nWe hum a tune while the lanterns glow")
	s3.set_translate(false)
	var a2: int = _added.size()
	s3.make()
	ok(await _until(func() -> bool: return s3.phase == "done" or s3.phase == "failed", 40.0), "stub, translate off: the flow ended")
	var id3: String = str(_added[_added.size() - 1]) if _added.size() > a2 else ""
	var song3: Dictionary = SongStore.load_song(id3)
	var ko3 := 0
	for ln in song3.get("lines", []):
		if str((ln as Dictionary).get("ko", "")) != "":
			ko3 += 1
	ok(s3.phase == "done" and ko3 == 0 and song3.get("translate", null) == false, "stub, translate off (even with consent): nothing translated, song['translate'] is false")
	ok(bool(Store.prefs.get("song_translate", true)) == false, "the last choice is remembered as the default (song_translate pref)")
	Store.prefs["song_translate"] = true
	_drop(s3)
	await _frames(2)
	# --- LRCLIB-style source: attribution is stored by the server
	var s4 := _new_screen()
	s4.duration_probe = func(_p: String) -> float: return 8.0
	s4.set_file(TONE)
	s4.set_title("Kettle Morning")
	s4.set_artist("Test Artist")
	s4.source = "lrclib"
	s4.lr_record = {"id": 1001, "trackName": "Kettle Morning", "artistName": "Test Artist", "albumName": "", "duration": 8.0, "instrumental": false,
		"syncedLyrics": "[00:01.00] The kettle hums while the morning climbs the wall\n[00:03.00] I count my steps to the old blue chair\n[00:05.00] Nobody calls so the quiet stays small", "plainLyrics": ""}
	var a3: int = _added.size()
	s4.make()
	ok(await _until(func() -> bool: return s4.phase == "done" or s4.phase == "failed", 40.0), "stub, lrclib source: the flow ended")
	var id4: String = str(_added[_added.size() - 1]) if _added.size() > a3 else ""
	var song4: Dictionary = SongStore.load_song(id4)
	var src: Dictionary = song4.get("source", {})
	ok(s4.phase == "done" and str(src.get("lyrics", "")) == "lrclib" and int(src.get("lrclib_id", 0)) == 1001 and str(src.get("attribution", "")).contains("LRCLIB"), "stub, lrclib source: the installed song says lyrics 'lrclib', id 1001 and carries the attribution")
	_drop(s4)
	_consent(false)
	await _frames(2)


# ---------------------------------------------------------------- spy server sections

func _job_body(n: int = -1) -> Dictionary:
	var jobs: Array = []
	for e in spy.log:
		if e["m"] == "POST" and e["path"] == "/song/jobs":
			jobs.append(e["body"])
	if jobs.is_empty():
		return {}
	return jobs[n] if n >= 0 else jobs[jobs.size() - 1]


func _make_run(s: SongAddScreen, max_sec: float = 20.0) -> void:
	await _until(func() -> bool: return s.phase == "done" or s.phase == "failed", max_sec)


func _test_spy_requests() -> void:
	print("[requests the screen sends (spy server): lyrics limits, ai_ok AND, options]")
	_fresh()
	_connect_pc(true)
	# --- 401 pasted lines / 201 chars / 22500 chars: the request carries the cut lyrics
	spy.reset()
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 8.0
	s.set_file(TONE)
	s.set_title("Limit Song")
	s.set_source("pasted")
	s.set_pasted(_numbered(401))
	ok(s.make() == "", "401 lines: make() starts")
	await _make_run(s)
	var b1: Dictionary = _job_body()
	var l1: Array = b1.get("lyrics", {}).get("lines", [])
	ok(l1.size() == 400 and _lines_in_limits(l1), "401 pasted lines: the request carries exactly 400 lines (%d)" % l1.size())
	ok(s.run_notes.size() == 1 and str(s.run_notes[0]).contains("400줄까지"), "401 pasted lines: the person was told '400줄까지' (%s)" % [s.run_notes])
	_drop(s)
	await _frames(2)
	spy.reset()
	var s2 := _new_screen()
	s2.duration_probe = func(_p: String) -> float: return 8.0
	s2.set_file(TONE)
	s2.set_source("pasted")
	s2.set_pasted("first\n" + "q".repeat(201) + "\nthird")
	s2.make()
	await _make_run(s2)
	var l2: Array = _job_body().get("lyrics", {}).get("lines", [])
	ok(l2.size() == 3 and str(l2[1]["text"]).length() == 200 and _lines_in_limits(l2) and s2.run_notes.size() == 1 and str(s2.run_notes[0]).contains("200자"), "a 201 character line: the request carries 200 characters and the person was told")
	ok(str(_job_body()["title"]) == "tone 8s", "no title typed: the file name is used as the title")
	_drop(s2)
	await _frames(2)
	spy.reset()
	var big: PackedStringArray = []
	for i in 150:
		big.append(str(i).pad_zeros(3) + "c".repeat(147))
	var s3 := _new_screen()
	s3.duration_probe = func(_p: String) -> float: return 8.0
	s3.set_file(TONE)
	s3.set_source("pasted")
	s3.set_pasted("\n".join(big))
	s3.make()
	await _make_run(s3)
	var l3: Array = _job_body().get("lyrics", {}).get("lines", [])
	ok(_lines_in_limits(l3) and l3.size() < 150 and s3.run_notes.size() == 1 and str(s3.run_notes[0]).contains("20000자"), "22500 characters: the request carries <= 20000 and the person was told (%d lines)" % l3.size())
	_drop(s3)
	await _frames(2)
	# --- section marks never reach the server
	spy.reset()
	var s3b := _new_screen()
	s3b.duration_probe = func(_p: String) -> float: return 8.0
	s3b.set_file(TONE)
	s3b.set_source("pasted")
	s3b.set_pasted("[Intro]\nAlpha words\n[Chorus]\nBeta words")
	s3b.make()
	await _make_run(s3b)
	var l3b: Array = _job_body().get("lyrics", {}).get("lines", [])
	ok(l3b.size() == 2 and str(l3b[0]["text"]) == "Alpha words", "[Intro] / [Chorus] lines are not sent")
	_drop(s3b)
	await _frames(2)

	# --- ai_ok = consent AND translate
	for combo in [[false, true], [true, true], [true, false], [false, false]]:
		var consent: bool = combo[0]
		var translate: bool = combo[1]
		spy.reset()
		_consent(consent)
		var sa := _new_screen()
		sa.duration_probe = func(_p: String) -> float: return 8.0
		sa.set_file(TONE)
		sa.set_title("AI rule")
		sa.set_source("pasted")
		sa.set_pasted("one two three\nfour five six")
		sa.set_translate(translate)
		sa.make()
		await _make_run(sa)
		var body: Dictionary = _job_body()
		var opts: Dictionary = body.get("options", {})
		ok(_ai_rule(consent, translate, body), "consent %s + translate %s -> the request says ai_ok:%s" % [consent, translate, opts.get("ai_ok", "?")])
		ok(opts.get("ai_ok", null) is bool and opts.get("translate", null) == translate and opts.get("gloss", null) == translate, "consent %s + translate %s -> translate:%s gloss:%s (real booleans)" % [consent, translate, opts.get("translate", "?"), opts.get("gloss", "?")])
		var got: Dictionary = SongStore.load_song(str(_added[_added.size() - 1])) if sa.phase == "done" else {}
		ok(got.get("translate", null) == translate, "consent %s + translate %s -> installed song['translate'] == %s" % [consent, translate, translate])
		_drop(sa)
		await _frames(2)
	_consent(false)
	# --- gloss off while translate on
	spy.reset()
	_consent(true)
	Store.prefs["song_translate"] = true
	var sg := _new_screen()
	sg.duration_probe = func(_p: String) -> float: return 8.0
	sg.set_file(TONE)
	sg.set_source("pasted")
	sg.set_pasted("a b\nc d")
	sg.set_gloss(false)
	sg.make()
	await _make_run(sg)
	var og: Dictionary = _job_body().get("options", {})
	ok(og.get("translate", null) == true and og.get("gloss", null) == false and og.get("ai_ok", null) == true and og.get("precise", null) == false, "gloss switched off: translate true, gloss false, precise false")
	_drop(sg)
	_consent(false)
	await _frames(2)
	# --- language and ja
	spy.reset()
	Store.prefs["song_translate"] = true
	var sj := _new_screen("ja")
	sj.duration_probe = func(_p: String) -> float: return 8.0
	sj.set_file(TONE)
	sj.set_source("pasted")
	sj.set_pasted("月あかりの下で\n歌を歌おう")
	sj.make()
	await _make_run(sj)
	ok(str(_job_body().get("lang", "")) == "ja" and str(_job_body()["lyrics"]["lines"][0]["text"]) == "月あかりの下で", "Japanese: lang ja and the lines are sent unchanged")
	_drop(sj)
	await _frames(2)
	# --- LRCLIB source in the request
	spy.reset()
	var sl := _new_screen()
	sl.duration_probe = func(_p: String) -> float: return 8.0
	sl.set_file(TONE)
	sl.source = "lrclib"
	sl.lr_record = {"id": 1001, "trackName": "Kettle Morning", "artistName": "Test Artist", "albumName": "", "duration": 8.0, "instrumental": false,
		"syncedLyrics": "[00:01.00] first words\n[00:02.00] second words", "plainLyrics": ""}
	sl.make()
	await _make_run(sl)
	var bl: Dictionary = _job_body()
	ok(str(bl["lyrics"]["source"]) == "lrclib" and int(bl["lyrics"]["lrclib_id"]) == 1001 and bl["lyrics"]["lines"][0]["t"] != null and bool(bl["options"]["verify"]), "LRCLIB source: source lrclib, lrclib_id 1001, line times, verify on")
	_drop(sl)
	await _frames(2)


func _stage_has(s: SongAddScreen, sub: String) -> bool:
	var l: Node = _find(s, "StageText")
	return l is Label and (l as Label).text.contains(sub)


func _test_transfer_ui() -> void:
	print("[progress, cancel, resume (spy server)]")
	_fresh()
	_connect_pc(true)
	_consent(true)
	# --- progress view: stage name, percent, remaining time; [취소] -> SongTransfer.cancel()
	spy.reset()
	spy.cfg["hold_at"] = 1
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 8.0
	s.set_file(TONE)
	s.set_title("Progress Song")
	s.set_source("pasted")
	s.set_pasted("one two three\nfour five six")
	var fin: Array = []
	s.transfer.finished.connect(func(r: Dictionary) -> void: fin.append(r))
	var before: int = Api.sent_count
	ok(s.make() == "", "make() ok")
	ok(s.phase == "running" and _find(s, "RunningCard") != null and _find(s, "BtnCancel") != null and _find(s, "BtnMake") == null, "progress view: shown with [취소], the [곡 만들기] button is gone")
	ok(await _until(func() -> bool: return _stage_has(s, "받아 적는 중") and _stage_has(s, "40%") and _stage_has(s, "남음"), 15.0), "progress text shows the stage name, the percent and the time left: '%s'" % [(_find(s, "StageText") as Label).text if _find(s, "StageText") != null else "-"])
	var pl: Label = _find(s, "PctText") as Label
	var bar: ProgressBar = _find(s, "ProgressBar") as ProgressBar
	ok(pl != null and pl.text.begins_with("전체 ") and bar != null and bar.value > 0.3 and bar.value < 0.7, "overall percent label and bar follow (%s / %.2f)" % [pl.text if pl != null else "-", bar.value if bar != null else -1.0])
	ok(_find(s, "RunHint") != null and (_find(s, "RunHint") as Label).text.contains("이어 받기"), "a job is on the PC: the hint says it can be received again later")
	ok(s.make() == SongAddScreen.MSG_BUSY and spy.count("POST /song/jobs") == 1, "make() while running is refused (one job on the PC)")
	_press(s, "BtnCancel")
	ok(await _until(func() -> bool: return fin.size() == 1, 10.0), "[취소] -> SongTransfer.cancel() -> finished")
	ok(str(fin[0].get("err_code", "")) == "cancelled" and not s.transfer.busy, "finished says cancelled and the transfer is idle")
	ok(await _until(func() -> bool: return spy.count("POST /song/jobs/cancel") >= 1 and spy.count("POST /song/jobs/release") >= 1, 5.0), "the cancel and the release reached the PC")
	await get_tree().create_timer(0.3).timeout
	ok(spy.count("POST /song/jobs/cancel") == 1, "the PC got exactly one cancel")
	await _frames(2)
	ok(s.phase == "form" and _find(s, "BtnMake") != null and str(s.file["name"]) == "tone_8s.mp3" and s.title_text == "Progress Song", "after cancel: back to the form with the inputs kept")
	ok(SongStore.pending_list().is_empty() and SongStore.list().is_empty() and _toast_has("취소했어요"), "after cancel: nothing pending, no song installed, the person was told")
	_drop(s)
	await _frames(2)

	# --- leaving a running transfer asks first; the job can be received again
	spy.reset()
	spy.cfg["hold_at"] = 1
	var s2 := _new_screen()
	s2.duration_probe = func(_p: String) -> float: return 8.0
	s2.set_file(TONE)
	s2.set_title("Resume Song")
	s2.set_source("pasted")
	s2.set_pasted("one two three\nfour five six")
	s2.make()
	ok(await _until(func() -> bool: return _stage_has(s2, "40%"), 15.0), "second run is at 40 percent")
	var c0: int = _closed
	s2.go_back()
	await _frames(2)
	ok(Sheet.is_open() and _closed == c0, "leaving while running: a confirm sheet, the screen stays")
	Sheet.close_top("cancel")
	await _frames(2)
	ok(not Sheet.is_open() and _closed == c0 and s2.transfer.busy, "'continue waiting': the sheet closes, the transfer goes on")
	s2.go_back()
	await _frames(2)
	Sheet.close_top("ok")
	await _frames(2)
	ok(_closed == c0 + 1 and not s2.transfer.busy, "'leave': closed signal, the transfer stopped without telling the PC")
	ok(spy.count("POST /song/jobs/cancel") == 0 and spy.count("POST /song/jobs/release") == 0, "leaving sent neither cancel nor release (the job stays on the PC)")
	var pend: Array = SongStore.pending_list()
	ok(pend.size() == 1 and str(pend[0]["title"]) == "Resume Song", "the job is kept in pending (%d)" % pend.size())
	_drop(s2)
	await _frames(2)
	# reopen: the pending job is offered
	var s3 := _new_screen()
	await _frames(2)
	var job: String = str(pend[0]["job"])
	ok(_find(s3, "PendingCard") != null and _find(s3, "BtnResume_" + job) != null and _texts(s3).contains("Resume Song"), "reopening the screen offers '이어 받기' for the pending job")
	spy.cfg["released"] = true
	var a0: int = _added.size()
	_press(s3, "BtnResume_" + job)
	ok(s3.phase == "running", "[이어 받기] shows the progress view")
	ok(await _until(func() -> bool: return s3.phase == "done" or s3.phase == "failed", 20.0), "resume finished")
	ok(s3.phase == "done" and _added.size() == a0 + 1 and SongStore.pending_list().is_empty(), "resume: the song is installed, song_added emitted, pending cleared")
	var rs: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	ok(rs.get("translate", null) is bool, "resume: song['translate'] is stored too")
	ok(spy.count("POST /song/upload") == 1, "resume did not upload again")
	_drop(s3)
	await _frames(2)

	# --- discard a pending job
	spy.reset()
	SongStore.pending_put({"job": "j_00000f01", "upload_id": "a".repeat(32), "lang": "en", "title": "Old Job", "t": 1790000000})
	var s4 := _new_screen()
	await _frames(2)
	ok(_find(s4, "BtnDiscard_j_00000f01") != null, "pending card has a discard button")
	_press(s4, "BtnDiscard_j_00000f01")
	await _frames(2)
	ok(SongStore.pending_list().is_empty() and _find(s4, "PendingCard") == null, "discard: the record is gone and the card disappears")
	ok(await _until(func() -> bool: return spy.count("POST /song/jobs/release") == 1, 5.0), "discard: the PC was asked to release the job")
	_drop(s4)
	await _frames(2)

	# --- link lost while the PC works: 'receive again' after reconnect
	spy.reset()
	spy.cfg["hold_at"] = 1
	spy.cfg["drop_status"] = 100
	var s5 := _new_screen()
	s5.duration_probe = func(_p: String) -> float: return 8.0
	s5.set_file(TONE)
	s5.set_title("Cut Song")
	s5.set_source("pasted")
	s5.set_pasted("one two three\nfour five six")
	s5.make()
	ok(await _until(func() -> bool: return s5.phase == "failed", 30.0), "five failed polls end the transfer as failed")
	await _frames(2)
	ok(str(s5.last_result.get("err_code", "")) == "transport" and bool(s5.last_result.get("resumable", false)), "the failure is 'transport' and resumable")
	ok(_find(s5, "FailedCard") != null and _find(s5, "BtnResume") != null and _texts(s5).contains("PC와 연결이 끊겼어요"), "failed view: the message and [이어 받기]")
	spy.cfg["drop_status"] = 0
	spy.cfg["released"] = true
	var a1: int = _added.size()
	_press(s5, "BtnResume")
	ok(await _until(func() -> bool: return s5.phase == "done" or s5.phase == "failed", 20.0), "[이어 받기] after the link is back finished")
	ok(s5.phase == "done" and _added.size() == a1 + 1, "the song arrived after the link came back")
	_drop(s5)
	await _frames(2)

	# --- PC says no_speech: message + back to the form with inputs
	spy.reset()
	spy.cfg["script"] = [{"state": "queued"}, {"state": "failed", "error": {"code": "no_speech", "message": "서버 문장"}}]
	var s6 := _new_screen()
	s6.duration_probe = func(_p: String) -> float: return 8.0
	s6.set_file(TONE)
	s6.set_title("Silent Song")
	s6.set_source("pasted")
	s6.set_pasted("one two three")
	var songs_before: int = SongStore.list().size()
	s6.make()
	ok(await _until(func() -> bool: return s6.phase == "failed", 20.0), "a failed job ends in the failed view")
	await _frames(2)
	ok(_texts(s6).contains("소리가 들리지 않는") and SongStore.list().size() == songs_before, "no_speech: Korean explanation, no song installed")
	ok(_find(s6, "BtnResume") == null and _find(s6, "BtnBackToForm") != null, "no_speech: no resume button (nothing to receive), a way back")
	_press(s6, "BtnBackToForm")
	await _frames(2)
	ok(s6.phase == "form" and s6.title_text == "Silent Song" and s6.pasted_text == "one two three", "back to the form keeps the title and the lyrics")
	_drop(s6)
	await _frames(2)
	# --- done view lists warnings in Korean
	spy.reset()
	spy.cfg["script"] = [{"state": "running", "stage": "enrich", "pct": 90}, {"state": "done", "warnings": ["low_match", "offset_guess"]}]
	var s7 := _new_screen()
	s7.duration_probe = func(_p: String) -> float: return 8.0
	s7.set_file(TONE)
	s7.set_source("pasted")
	s7.set_pasted("one two three")
	s7.make()
	await _make_run(s7)
	await _frames(2)
	ok(s7.phase == "done" and _find(s7, "DoneCard") != null and _texts(s7).contains("잘 맞지 않았어요") and _texts(s7).contains("어긋나"), "done view: the PC's warnings are explained in Korean")
	_drop(s7)
	await _frames(2)
	# --- upload cut in the middle then 'continue upload' (same upload_id, no re-send of chunks)
	spy.reset()
	spy.part_chunks = true
	var s8 := _new_screen()
	s8.duration_probe = func(_p: String) -> float: return 8.0
	var big_p: String = _g(DIR.path_join("two_chunks.wav"))
	_write_bytes(big_p, _wav(40, 8000))
	s8.set_file(big_p)
	s8.transfer.chunk_bytes = 400000
	s8.set_title("Two Chunks")
	s8.set_source("pasted")
	s8.set_pasted("one two three")
	spy.cfg["drop_upload_index"] = 1
	spy.cfg["drop_upload_times"] = 100
	s8.make()
	ok(await _until(func() -> bool: return s8.phase == "failed", 30.0), "an upload that keeps failing ends as failed")
	await _frames(2)
	ok(str(s8.last_result.get("err_code", "")) == "transport" and str(s8.last_result.get("upload_id", "")).length() == 32 and _find(s8, "BtnContinue") != null, "failed upload: [이어서 올리기] is offered with the upload_id")
	spy.cfg["drop_upload_times"] = 0
	spy.cfg["released"] = true
	var a2: int = _added.size()
	var first_id: String = str(s8.last_result.get("upload_id", ""))
	_press(s8, "BtnContinue")
	ok(await _until(func() -> bool: return s8.phase == "done" or s8.phase == "failed", 30.0), "continued upload finished")
	ok(s8.phase == "done" and _added.size() == a2 + 1, "continued upload: the song arrived")
	ok(spy.uploads.has(first_id) and spy.accepted_indices(first_id) == [0, 1], "continued upload used the same upload_id and sent chunk 0 only once (%s)" % [spy.accepted_indices(first_id)])
	DirAccess.remove_absolute(big_p)
	_drop(s8)
	_consent(false)
	await _frames(2)


# ---------------------------------------------------------------- layout

func _small_touch(root: Control) -> Array:
	var bad: Array = []
	var tmin: float = Ds.touch_min()
	for n in root.find_children("Btn*", "Button", true, false):
		var b := n as Button
		if not b.is_visible_in_tree():
			continue
		var r: Rect2 = b.get_global_rect()
		if r.size.y < tmin - 0.5 or r.size.x < tmin - 0.5:
			bad.append("%s %s" % [b.name, r.size])
	for n in root.find_children("*", "LineEdit", true, false):
		var le := n as LineEdit
		if le.is_visible_in_tree() and le.get_global_rect().size.y < tmin - 0.5:
			bad.append("%s %s" % [le.name, le.get_global_rect().size])
	return bad


func _layout_check(s: SongAddScreen, label: String) -> void:
	await _frames(3)
	var over: Array = _overflow(s)
	ok(over.is_empty(), "layout [%s]: no control sticks out sideways (%s)" % [label, over.slice(0, 3)])
	var page: PageScroll = s._shell["page"]
	ok(page.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "layout [%s]: the page never scrolls sideways" % label)
	if _phone:
		var sm: Array = _small_touch(s)
		ok(sm.is_empty(), "layout [%s]: buttons and inputs are at least Ds.touch_min() (%s)" % [label, sm.slice(0, 3)])


func _test_layout() -> void:
	print("[layout: PC 1280x800 / phone 412x915, font scale %s]" % _scale)
	_fresh()
	_connect_pc(true)
	_consent(true)
	var s := _new_screen()
	s.duration_probe = func(_p: String) -> float: return 8.0
	await _layout_check(s, "empty form")
	s.set_file(TONE)
	s.set_title("T".repeat(900))
	s.set_artist("Artist ".repeat(100))
	s._render()
	await _layout_check(s, "file chosen, 900 character title")
	s.set_source("pasted")
	s.set_pasted(_numbered(401))
	await _layout_check(s, "pasted 401 lines (notes shown)")
	s.set_source("lrclib")
	var items: Array = []
	for i in 20:
		items.append({"id": 100 + i, "trackName": "Name %d " % i + "N".repeat(800), "artistName": "Artist " + "A".repeat(500), "albumName": "Album " + "L".repeat(300), "duration": 200.0 + i,
			"syncedLyrics": "[00:01.00] x" if i % 2 == 0 else "", "plainLyrics": "x", "instrumental": i == 3})
	s.lr_items = items
	s.lr_get_calls = 1
	s.lr_search_calls = 1
	s.lr_status = "found"
	s.lr_message = "비슷한 곡 20개를 찾았어요. 하나를 골라 주세요."
	s.lr_record = items[0]
	s._render()
	await _layout_check(s, "lrclib with 20 very long candidates")
	var cand_labels := 0
	var clipped := true
	var g: Node = _find(s, "Candidates")
	if g != null:
		for l in g.find_children("*", "Label", true, false):
			cand_labels += 1
			if (l as Label).text.length() > 140:
				clipped = false
	ok(cand_labels >= 20 and clipped, "layout: long LRCLIB names are cut in the label text itself (%d labels, none above 140 chars)" % cand_labels)
	s.set_translate(false)
	await _layout_check(s, "options with translation off")
	# running / failed / done / blocked
	s.phase = "running"
	s.last_progress = {"stage": "asr", "pct": 43.0, "text": "가사를 받아 적는 중 40% · 약 30초 남음"}
	s.run_notes = ["가사가 400줄을 넘어서 앞의 400줄까지만 써요. (뒤의 1줄은 뺐어요)"]
	s._render()
	await _layout_check(s, "running")
	s.phase = "failed"
	s.last_result = {"ok": false, "err_code": "transport", "message": SongTransfer.message_for("transport"), "resumable": false, "upload_id": ""}
	s._render()
	await _layout_check(s, "failed")
	s.phase = "done"
	s.added_warnings = ["low_match", "ko_missing", "offset_guess"]
	s._render()
	await _layout_check(s, "done")
	s.phase = "form"
	_disconnect_pc()
	s._on_env_changed()
	s._render()
	await _layout_check(s, "no PC notice")
	_connect_pc(true)
	SongStore.pending_put({"job": "j_00000a01", "upload_id": "b".repeat(32), "lang": "en", "title": "P".repeat(900), "t": 1790000000})
	s._render()
	await _layout_check(s, "pending job card")
	SongStore.pending_remove("j_00000a01")
	_drop(s)
	_consent(false)
	await _frames(2)


func _test_real_folder_untouched() -> void:
	print("[real folders]")
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "user files and the real user://songs are untouched (checked in the middle of the run)")


# ---------------------------------------------------------------- spy server (a small PC: records every request)

class Spy:
	extends Node
	var srv: TCPServer = null
	var log: Array = [] ## {key, m, path, q, body}
	var uploads: Dictionary = {}
	var jobs: Dictionary = {}
	var job_seq: int = 0
	var cfg: Dictionary = {}
	var audio: PackedByteArray = PackedByteArray()
	var audio_sha: String = ""
	var conns: Array = []
	var part_chunks: bool = false
	var accepted: Dictionary = {} ## upload_id -> Array of accepted chunk indices

	func setup(p: int) -> bool:
		srv = TCPServer.new()
		if srv.listen(p, "127.0.0.1") != OK:
			srv = null
			return false
		audio = FileAccess.get_file_as_bytes("res://tests/fixtures/song/tone_8s.mp3")
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
		accepted.clear()
		job_seq = 0
		part_chunks = false
		cfg = {"health": {"ok": true, "song": true, "song_v": 1}, "hold_at": -1, "released": false, "drop_status": 0, "drop_upload_index": -1, "drop_upload_times": 0,
			"script": [{"state": "queued", "queue_pos": 1}, {"state": "running", "stage": "asr", "pct": 40, "eta_sec": 30},
				{"state": "running", "stage": "enrich", "pct": 80, "eta_sec": 5}, {"state": "done", "warnings": []}]}

	func _process(_d: float) -> void:
		if srv != null and srv.is_listening():
			while srv.is_connection_available():
				var peer: StreamPeerTCP = srv.take_connection()
				conns.append(peer)
				_serve(peer)

	func count(key: String) -> int:
		var n: int = 0
		for e in log:
			if e["key"] == key:
				n += 1
		return n

	func accepted_indices(id: String) -> Array:
		return accepted.get(id, [])

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
		var slim: Dictionary = body.duplicate(true)
		if slim.has("data_b64"):
			slim["data_b64"] = "len:%d" % str(slim["data_b64"]).length()
		log.append({"key": key, "m": m, "path": path, "q": q, "body": slim})
		if key == "GET /song/jobs/status" and int(cfg["drop_status"]) > 0:
			cfg["drop_status"] = int(cfg["drop_status"]) - 1
			peer.disconnect_from_host()
			return
		if key == "POST /song/upload" and int(cfg["drop_upload_times"]) > 0 and int(body.get("index", -1)) == int(cfg["drop_upload_index"]):
			cfg["drop_upload_times"] = int(cfg["drop_upload_times"]) - 1
			peer.disconnect_from_host()
			return
		var res: Array = _route(m, path, q, body)
		var payload: PackedByteArray = JSON.stringify(res[1]).to_utf8_buffer()
		var hd := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [int(res[0]), payload.size()]
		peer.put_data(hd.to_utf8_buffer())
		peer.put_data(payload)
		await get_tree().process_frame
		peer.disconnect_from_host()

	func _err(status: int, code: String, extra: Dictionary = {}) -> Array:
		var d := {"error": "서버 오류 " + code, "code": code}
		for k in extra:
			d[k] = extra[k]
		return [status, d]

	func _route(m: String, path: String, q: Dictionary, body: Dictionary) -> Array:
		match m + " " + path:
			"GET /health":
				return [200, cfg["health"]]
			"POST /song/upload":
				return _upload(body)
			"GET /song/upload":
				var u: Variant = uploads.get(str(q.get("upload_id", "")), null)
				if u == null:
					return _err(404, "no_upload")
				return [200, {"upload_id": q["upload_id"], "next": u["next"], "bytes": u["next"] * 1000, "done": u["next"] >= u["total"]}]
			"POST /song/jobs":
				return _job_create(body)
			"GET /song/jobs/status":
				return _status(str(q.get("job", "")))
			"POST /song/jobs/cancel":
				var j: Variant = jobs.get(str(body.get("job", "")), null)
				if j == null:
					return _err(404, "no_job")
				j["cancelled"] = true
				return [200, {"ok": true, "state": "cancelled"}]
			"GET /song/result":
				return _result(str(q.get("job", "")))
			"GET /song/audio":
				return _audio(str(q.get("job", "")), int(q.get("part", "0")))
			"POST /song/jobs/release":
				var jid: String = str(body.get("job", ""))
				jobs.erase(jid)
				return [200, {"ok": true, "removed": true}]
		return _err(404, "no_route")

	func _upload(body: Dictionary) -> Array:
		var id: String = str(body.get("upload_id", ""))
		var idx: int = int(body.get("index", -1))
		var total: int = int(body.get("total", 0))
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
		if not accepted.has(id):
			accepted[id] = []
		(accepted[id] as Array).append(idx)
		if int(u["next"]) < total:
			return [200, {"upload_id": id, "received": u["next"], "bytes": int(u["next"]) * 1000}]
		return [200, {"upload_id": id, "done": true, "bytes": audio.size(), "duration": 8.0, "format": "mp3", "sha256": audio_sha}]

	func _job_create(body: Dictionary) -> Array:
		var u: Variant = uploads.get(str(body.get("upload_id", "")), null)
		if u == null:
			return _err(404, "no_upload")
		job_seq += 1
		var jid: String = "j_%08x" % (0xabc000 + job_seq)
		jobs[jid] = {"up": str(body.get("upload_id", "")), "polls": 0, "cancelled": false, "last": "queued", "body": body}
		return [202, {"job": jid, "state": "queued", "queue_pos": 0}]

	func _status(jid: String) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			# a job made by an earlier (abandoned) screen is known by its id only: unknown ids are treated like a fresh job
			j = {"up": "", "polls": 0, "cancelled": false, "last": "queued", "body": {}}
			jobs[jid] = j
		var out := {"job": jid, "state": "queued", "stage": "", "pct": 0, "eta_sec": null, "message_ko": "순서를 기다리는 중", "warnings": [], "error": null}
		if j["cancelled"]:
			out["state"] = "cancelled"
			return [200, out]
		var script: Array = cfg["script"]
		var i: int = int(j["polls"])
		var hold: int = int(cfg["hold_at"])
		if hold >= 0 and not bool(cfg["released"]):
			i = mini(i, hold)
		var step: Dictionary = script[mini(i, script.size() - 1)]
		j["polls"] = int(j["polls"]) + 1
		for k in step:
			out[k] = step[k]
		if str(out["state"]) == "done":
			out["pct"] = 100
		j["last"] = str(out["state"])
		return [200, out]

	func _result(jid: String) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			return _err(404, "no_job")
		if j["last"] != "done":
			return _err(409, "not_done")
		var texts: Array = []
		var ly: Variant = (j["body"] as Dictionary).get("lyrics", {})
		if ly is Dictionary:
			for l in (ly as Dictionary).get("lines", []):
				texts.append(str((l as Dictionary).get("text", "")))
		if texts.is_empty():
			texts = ["The river runs past the old wooden bridge", "We hum a tune while the lanterns glow", "Morning comes and the sky turns gold"]
		var lines: Array = []
		for i in mini(texts.size(), 3):
			lines.append({"i": i, "p": 0, "t0": 0.5 + i * 2.0, "t1": 2.0 + i * 2.0, "text": texts[i], "reading": "", "pron": "", "ko": "", "conf": 0.9, "est": false, "stale": false, "words": []})
		return [200, {"v": 1, "lang": str((j["body"] as Dictionary).get("lang", "en")), "title": str((j["body"] as Dictionary).get("title", "")),
			"artist": str((j["body"] as Dictionary).get("artist", "")), "created": 1793377559, "duration": 8.0,
			"audio": {"file": "audio.mp3", "bytes": audio.size(), "sha256": audio_sha, "orig_name": "fake.mp3", "parts": 1},
			"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""}, "offset": 0.0, "lines": lines, "glossary": {}, "warnings": []}]

	func _audio(jid: String, part: int) -> Array:
		var j: Variant = jobs.get(jid, null)
		if j == null:
			return _err(404, "no_job")
		if j["last"] != "done":
			return _err(409, "not_done")
		if part != 0:
			return _err(400, "bad_index")
		return [200, {"part": 0, "parts": 1, "bytes": audio.size(), "total_bytes": audio.size(), "data_b64": Marshalls.raw_to_base64(audio), "sha256": audio_sha}]
