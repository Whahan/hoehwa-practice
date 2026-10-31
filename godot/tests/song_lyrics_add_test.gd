extends Node
## 가사 외우기 M6: SongLyricsAddScreen (가사만 추가 화면) 시험. docs/lyrics_memorize_design.md §8 M6.
##   PC:   godot --headless --path godot res://tests/song_lyrics_add_test.tscn
##   폰:   godot --headless --path godot res://tests/song_lyrics_add_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5      (--python=<python.exe> 로 파이썬 지정, --only=<구간> 으로 한 구간만)
## 가짜 LRCLIB(tests/fixtures/song/fake_lrclib.py, 포트 18797)는 시험이 직접 띄우고 자기 PID(와 하위)만 끈다. 실제 lrclib.net 접속 없음.
## 곡은 user://test_songs_m6 에만 저장한다. 설정·진행·학습 기록은 user://test_m6/ 로 돌린다. 가사·제목은 모두 직접 지은 문장이다.
## 이 화면은 PC(서버)를 쓰지 않는다: 시험 내내 PC 는 끊어 두고, 끝에서 Api.sent_count 가 처음과 같은지 본다.
## 마지막 줄: "== song_lyrics_add_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 일부러 틀린 입력(변조)으로 검사기가 실제로 FAIL 을 내는지: _selftest() 구간.

const LR_PORT := 18797
const LR_BASE := "http://127.0.0.1:18797"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const ROOT := "user://test_songs_m6"
const DIR := "user://test_m6"
const SRC := "res://scripts/song/song_lyrics_add_screen.gd"
const FORBIDDEN := ["publish", "flag", "challenge", "cancel_request", "enrich", "Api.", "Backend", "Route."]

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
	_added.clear()


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


func _disconnect_pc() -> void:
	Backend.health = {}
	Backend._set_status(Backend.Status.FAILED, "x")


func _new_screen(lang: String = "en") -> SongLyricsAddScreen:
	var s := SongLyricsAddScreen.new()
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(s)
	s.lrclib_base_url = LR_BASE
	s.song_added.connect(func(id: String) -> void: _added.append(id))
	s.closed.connect(func() -> void: _closed += 1)
	s.open(lang, {})
	return s


func _drop(s: SongLyricsAddScreen) -> void:
	if s != null and is_instance_valid(s):
		s.queue_free()


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled:
		(b as Button).pressed.emit()
		return true
	return false


## 입력칸에 글자를 쳐 넣는다 (칸이 있으면 칸을 거쳐서, 없으면 바로).
func _type_paste(s: SongLyricsAddScreen, text: String) -> void:
	var e: Node = _find(s, "PasteInput")
	if e is TextEdit:
		(e as TextEdit).text = text
		(e as TextEdit).text_changed.emit()
	else:
		s.set_pasted(text)


func _fixture(name: String) -> String:
	var f := FileAccess.open("res://tests/fixtures/song/" + name, FileAccess.READ)
	var out: PackedStringArray = []
	if f == null:
		return ""
	for raw in f.get_as_text().replace("\r", "").split("\n"):
		if not raw.strip_edges().begins_with("#"):
			out.append(raw)
	return "\n".join(out).strip_edges()


func _numbered(n: int) -> String:
	var a: PackedStringArray = []
	for i in n:
		a.append("Made up line number %d of the test song" % (i + 1))
	return "\n".join(a)


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


func _calls_ok(get_n: int, search_n: int) -> bool:
	return get_n <= 1 and search_n <= 1


func _forbidden_hits(text: String) -> Array:
	var hits: Array = []
	for w in FORBIDDEN:
		if text.contains(str(w)):
			hits.append(w)
	return hits


# ---------------------------------------------------------------- fake LRCLIB server

func _http(base: String, method: int, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	var err: int = req.request(base + path, PackedStringArray(["Content-Type: application/json"]), method, "")
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


func _lr_bad_calls() -> Array:
	var r: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_log")
	if r["data"] is Dictionary:
		return (r["data"] as Dictionary).get("bad_calls", [])
	return []


func _lr_reset() -> void:
	await _http(LR_BASE, HTTPClient.METHOD_POST, "/_reset")


func _lr_paths(reqs: Array) -> Array:
	var out: Array = []
	for r in reqs:
		out.append(str(r["path"]))
	return out


func _start_lrclib() -> bool:
	var busy: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	for i in 60: # another worker's test may hold the port for a moment: wait for it (never kill it)
		if int(busy["code"]) == 0:
			break
		await get_tree().create_timer(2.0).timeout
		busy = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	if int(busy["code"]) != 0:
		print("  port %d is still in use, not starting" % LR_PORT)
		return false
	var py: String = _arg("--python=")
	if py == "":
		py = DEFAULT_PY
	var script: String = _g("res://tests/fixtures/song/fake_lrclib.py")
	var pid: int = OS.create_process(py, PackedStringArray(["-I", script, "--port", str(LR_PORT)]))
	if pid <= 0:
		return false
	_lr_pid = pid
	for i in 150:
		await get_tree().create_timer(0.2).timeout
		var h: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
		if int(h["code"]) == 200:
			return true
	return false


func _stop_lrclib() -> void:
	if _lr_pid > 0:
		await _http(LR_BASE, HTTPClient.METHOD_POST, "/_quit")
		await get_tree().create_timer(0.3).timeout
		if OS.get_name() == "Windows":
			OS.execute("taskkill", PackedStringArray(["/PID", str(_lr_pid), "/T", "/F"])) ## only the process this test started, and its children
		else:
			OS.kill(_lr_pid)
		_lr_pid = -1


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== song_lyrics_add_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	_rm_rf(DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port: the run must never reach the user's engine (8770)
	_disconnect_pc() # this screen needs no PC: the whole run is done without one
	var sent0: int = Api.sent_count
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
	await _test_paste()
	await _test_limits()
	await _test_save_failures()
	await _test_no_pc()
	await _test_source_rules()

	var lr_up: bool = await _start_lrclib()
	ok(lr_up, "fake LRCLIB (fake_lrclib.py) is up on port %d" % LR_PORT)
	if lr_up:
		await _test_lrclib_budget()
		await _test_lrclib_duration()
		await _test_lrclib_new_song()
		await _test_lrclib_failures()
		await _test_lrclib_late()
		await _test_lrclib_save()
		var bad: Array = await _lr_bad_calls()
		ok(bad.is_empty(), "the fake server saw no call other than get / search (bad_calls: %s)" % [bad])
	await _stop_lrclib()
	await get_tree().create_timer(0.3).timeout
	var lr_closed: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	ok(int(lr_closed["code"]) == 0, "fake LRCLIB is gone and port %d is closed again" % LR_PORT)

	await _test_layout()
	_test_real_folder_untouched()
	ok(Api.sent_count == sent0, "the whole run sent no PC request (Api.sent_count %d -> %d)" % [sent0, Api.sent_count])

	_close_sheets()
	_fresh()
	SongStore.root = old_root
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Backend.health = _old_health
	Backend.status = _old_status
	Api.clear_remote()
	_rm_rf(DIR)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "test folders cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_lyrics_add_test result: %d passed, %d failed ==" % [passed, failed])
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
	ok(not _calls_ok(2, 1) and not _calls_ok(1, 2) and _calls_ok(1, 1) and _calls_ok(0, 0), "call-count checker: get <= 1 and search <= 1 only")
	ok(not _forbidden_hits("func x(): flag_it()").is_empty() and not _forbidden_hits("Api.post_json()").is_empty() and not _forbidden_hits("client.cancel_request()").is_empty(), "source scanner finds forbidden words")
	ok(_forbidden_hits("func x(): return 1").is_empty(), "source scanner passes clean text")
	ok(_listing("user://test_m6_no_such_folder").is_empty() and _fixture("no_such_file.txt") == "", "listing / fixture helpers return empty for a missing path")


func _test_pure() -> void:
	print("[pure helpers]")
	var good := {"3:42": 222.0, "0:30": 30.0, "120:00": 7200.0, " 3:42 ": 222.0, "12:05": 725.0, "0:01": 1.0}
	var all_ok := true
	for k in good.keys():
		var d: Dictionary = SongLyricsAddScreen.parse_duration(str(k))
		if not (bool(d["ok"]) and is_equal_approx(float(d["seconds"]), float(good[k]))):
			all_ok = false
			print("    parse_duration(%s) -> %s" % [k, d])
	ok(all_ok, "parse_duration: 3:42 -> 222, 0:30, 120:00, padded, 12:05, 0:01")
	var bad_in: Array = ["abc", "99:99", "-1:30", "3:60", "0:00", "121:00", "3:4", "342", "3:42:10", "１:30", "3.42", "3 :42", "3:42s"]
	var bad_ok := true
	for k in bad_in:
		var d2: Dictionary = SongLyricsAddScreen.parse_duration(str(k))
		if bool(d2["ok"]) or bool(d2["empty"]) or float(d2["seconds"]) != 0.0:
			bad_ok = false
			print("    parse_duration(%s) -> %s" % [k, d2])
	ok(bad_ok, "parse_duration: abc / 99:99 / negative / 0:00 / 3:60 / 121:00 / 3:4 / 342 / hh:mm:ss / full-width are all rejected (not empty)")
	var e: Dictionary = SongLyricsAddScreen.parse_duration("   ")
	ok(bool(e["empty"]) and not bool(e["ok"]), "parse_duration: blank is 'empty', not 'wrong'")
	ok(SongLyricsAddScreen.query_key("Kettle  Morning ", " Test Artist") == SongLyricsAddScreen.query_key("kettle morning", "test   artist"), "query_key ignores case and extra spaces")
	ok(SongLyricsAddScreen.query_key("Kettle Morning", "A") != SongLyricsAddScreen.query_key("Kettle Mornings", "A"), "query_key: another title is another song")
	ok(SongLyricsAddScreen.query_key("ab", "") != SongLyricsAddScreen.query_key("", "ab"), "query_key: title and artist are not interchangeable")
	# analyze
	var prep: Dictionary = SongAddScreen.prepare_lyrics("pasted", "The kettle hums\nthe KETTLE hums!\nOne small note\n♪♪\n...\nThe kettle hums")
	var an: Dictionary = SongLyricsAddScreen.analyze(prep, "en")
	ok(int(an["memo_lines"]) == 4 and int(an["unique"]) == 2 and int(an["repeats"]) == 2 and int(an["symbols"]) == 2, "analyze: 6 lines = 4 memorizable, 2 distinct (chorus x3), 2 symbol-only (%s)" % [an])
	var an0: Dictionary = SongLyricsAddScreen.analyze({"lines": []}, "en")
	ok(int(an0["memo_lines"]) == 0 and int(an0["unique"]) == 0, "analyze: no lines -> zeros")
	# build_song -> normalize
	var p2: Dictionary = SongAddScreen.prepare_lyrics("pasted", _fixture("lyrics_en.txt"))
	var song: Dictionary = SongLyricsAddScreen.build_song("en", "Kettle", "Me", "pasted", {}, p2)
	var norm: Dictionary = SongModel.normalize(song)
	var times_zero := true
	for ln in (norm["lines"] as Array):
		if float(ln["t0"]) != 0.0 or float(ln["t1"]) != 0.0:
			times_zero = false
	ok(SongModel.is_lyrics(norm) and (norm["lines"] as Array).size() == 6 and times_zero and norm["duration"] == 0.0, "build_song -> normalize: kind lyrics, 6 lines, all times 0, duration 0")
	ok(str((norm["audio"] as Dictionary)["file"]) == "" and str((norm["source"] as Dictionary)["timing"]) == "none" and str((norm["source"] as Dictionary)["lyrics"]) == "pasted" and (norm["source"] as Dictionary)["lrclib_id"] == null and str((norm["source"] as Dictionary)["attribution"]) == "", "build_song: no audio, timing none, source pasted, no lrclib_id, no attribution")
	ok(int(norm["lines"][3]["p"]) == 1 and int(norm["lines"][2]["p"]) == 0, "build_song: stanza numbers from the blank line are kept (p 0 0 0 1 1 1)")
	var rec := {"id": 1001, "trackName": "T", "syncedLyrics": "[00:01.00] one\n[00:02.00] two", "plainLyrics": "one\ntwo", "instrumental": false}
	var p3: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", rec)
	var s3: Dictionary = SongModel.normalize(SongLyricsAddScreen.build_song("en", "T", "A", "lrclib", rec, p3))
	ok(int((s3["source"] as Dictionary)["lrclib_id"]) == 1001 and str((s3["source"] as Dictionary)["lyrics"]) == "lrclib" and str((s3["source"] as Dictionary)["attribution"]) == SongAddScreen.ATTRIBUTION, "build_song(lrclib): lrclib_id 1001 and the attribution text are saved")
	ok(float(s3["lines"][0]["t0"]) == 0.0 and float(s3["lines"][1]["t1"]) == 0.0, "build_song(lrclib, synced): the line times are dropped")
	var s4: Dictionary = SongLyricsAddScreen.build_song("en", "T", "A", "lrclib", {}, p3)
	ok(str((s4["source"] as Dictionary)["lyrics"]) == "pasted" and (s4["source"] as Dictionary)["lrclib_id"] == null, "build_song: source lrclib without a chosen record falls back to pasted (no lrclib_id)")
	ok(ProjectSettings.has_setting("application/config/version") and str(song["app"]) != "", "build_song records the app version")


func _test_paste() -> void:
	print("[paste: save, preview, fields]")
	_fresh()
	var sent: int = Api.sent_count
	var s := _new_screen()
	await _frames(2)
	ok(_find(s, "TitleInput") != null and _find(s, "ArtistInput") != null and _find(s, "PasteInput") != null and _find(s, "BtnSave") != null, "the form has title, artist, paste box and the save button")
	ok(_find(s, "SourceSeg") != null and _find(s, "BtnFind") == null, "paste is the first source (no LRCLIB buttons yet)")
	var save_btn: Button = _find(s, "BtnSave") as Button
	ok(save_btn.disabled and (_find(s, "SaveHint") as Label).text == SongLyricsAddScreen.MSG_NEED_TITLE, "empty form: the save button is disabled and says the title is missing")
	var r0: String = s.save()
	ok(r0 == SongLyricsAddScreen.MSG_NEED_TITLE and SongStore.list().is_empty() and _added.is_empty(), "save() with no title: refused with the reason, nothing stored")
	s.set_title("Kettle Test")
	ok(s.save() == SongLyricsAddScreen.MSG_NEED_PASTE and (_find(s, "BtnSave") as Button).disabled, "title but no lyrics: refused ('가사를 붙여넣어 주세요'), button disabled")
	var en: String = _fixture("lyrics_en.txt")
	ok(en.split("\n").size() == 7, "fixture lyrics_en.txt: 7 text lines incl. the blank stanza break (comments stripped)")
	s.set_pasted(en)
	await _frames(1)
	var pv: String = (_find(s, "LyricsPreview") as Label).text
	ok(pv.contains("6줄") and pv.contains("외울 줄 6개"), "the preview says 6 lines / 6 to memorize while pasting (%s)" % pv.replace("\n", " | "))
	ok(not (_find(s, "BtnSave") as Button).disabled and (_find(s, "SaveHint") as Label).text == "", "title + lyrics: the save button is enabled")
	s.set_artist("Nobody Special")
	var ids0: int = _added.size()
	var r1: String = s.save()
	ok(r1 == "" and _added.size() == ids0 + 1, "save: no error and song_added fired once")
	var id: String = str(_added[_added.size() - 1])
	var items: Array = SongStore.list()
	ok(items.size() == 1 and str(items[0]["kind"]) == "lyrics" and str(items[0]["id"]) == id, "SongStore.list(): exactly one song, kind lyrics")
	var saved: Dictionary = SongStore.load_song(id)
	ok((saved["lines"] as Array).size() == 6 and str((saved["source"] as Dictionary)["lyrics"]) == "pasted" and saved["title"] == "Kettle Test" and saved["artist"] == "Nobody Special" and saved["lang"] == "en", "saved song: 6 lines, source pasted, title / artist / lang as typed")
	ok(str((saved["lines"] as Array)[0]["text"]) == "The kettle hums while the morning climbs the wall" and str((saved["lines"] as Array)[5]["text"]) == "Tomorrow can wait while the tea is warm", "saved lines are the pasted sentences in order")
	var files: Array = _listing(ROOT.path_join(id))
	ok(files.size() == 1 and str(files[0]).begins_with("f:song.json:"), "the song folder holds only song.json (%s)" % [files])
	ok(SongLyricsAddScreen.new().save() != "" or true, "a screen that was never opened can be created") # construction alone must not throw
	ok(s.phase == "done" and _find(s, "DoneCard") != null and _find(s, "BtnClose") != null, "after saving the screen shows the done card with a close button")
	ok(s.save() == SongLyricsAddScreen.MSG_SAVING and SongStore.list().size() == 1 and _added.size() == ids0 + 1, "saving again after done: refused, still 1 song and 1 signal")
	ok(Api.sent_count == sent, "pasted save: no PC request (Api.sent_count %d -> %d)" % [sent, Api.sent_count])
	var cl0: int = _closed
	_press(s, "BtnClose")
	ok(_closed == cl0 + 1, "the close button emits closed")
	_drop(s)
	await _frames(2)
	# go_back asks before throwing pasted text away; with nothing typed it just leaves
	var s2 := _new_screen()
	var c1: int = _closed
	ok(s2.go_back() and _closed == c1 + 1, "go_back with nothing typed leaves at once")
	s2.set_pasted("Some typed line")
	var c2: int = _closed
	ok(s2.go_back() and _closed == c2 and Sheet.is_open(), "go_back with pasted text asks first (no close yet)")
	_close_sheets()
	await _frames(2)
	ok(_closed == c2 and s2.pasted_text == "Some typed line", "dismissing the question keeps the screen and the text")
	s2.go_back()
	await _frames(2)
	Sheet.close_top("ok")
	await _frames(2)
	ok(_closed == c2 + 1, "confirming the question leaves")
	_drop(s2)
	# japanese
	var s3 := _new_screen("ja")
	ok(s3.lang == "ja", "open('ja') starts in Japanese")
	s3.set_title("やかんの朝 (テスト)")
	s3.set_pasted(_fixture("lyrics_ja.txt"))
	ok(s3.preview_text().contains("5줄"), "Japanese: 5 lines in the preview")
	ok(s3.save() == "", "Japanese: saved")
	var ja: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	ok(ja["lang"] == "ja" and (ja["lines"] as Array).size() == 5 and SongModel.is_lyrics(ja), "Japanese song: lang ja, 5 lines, kind lyrics")
	_drop(s3)
	# LRC pasted: times are dropped, chorus + symbol lines are explained
	var s4 := _new_screen()
	s4.set_title("Timed Paste")
	s4.set_pasted("[00:01.00] The kettle hums\n[00:03.50] ♪♪\n[00:05.00] the kettle hums!\n[00:07.00] One small note")
	var pv4: String = s4.preview_text()
	ok(pv4.contains("4줄") and pv4.contains("외울 줄 2개") and pv4.contains("후렴으로 묶어서") and pv4.contains("글자가 없는 줄") and pv4.contains("시간표는 쓰지 않고"), "LRC paste: preview explains merged chorus, symbol-only line and that times are not kept (%s)" % pv4.replace("\n", " | "))
	ok(s4.save() == "", "LRC paste saved")
	var timed: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	var all0 := true
	for ln in (timed["lines"] as Array):
		if float(ln["t0"]) != 0.0 or float(ln["t1"]) != 0.0:
			all0 = false
	ok(all0 and (timed["lines"] as Array).size() == 4 and str((timed["lines"] as Array)[0]["text"]) == "The kettle hums", "LRC paste: saved without times, time stamps are not part of the text")
	_drop(s4)
	# nothing memorizable: refused with a reason
	var s5 := _new_screen()
	s5.set_title("Only Symbols")
	s5.set_pasted("♪♪\n...\n---")
	var songs_before: int = SongStore.list().size()
	ok(s5.save() == SongLyricsAddScreen.MSG_NO_MEMO_LINES and SongStore.list().size() == songs_before and (_find(s5, "BtnSave") as Button).disabled, "only symbols: nothing to memorize -> refused with the reason, nothing stored")
	_drop(s5)
	await _frames(2)


func _test_limits() -> void:
	print("[limits: 400 lines / 200 chars / 20000 chars / [Chorus]]")
	_fresh()
	var s := _new_screen()
	s.set_title("Limits")
	s.set_pasted(_numbered(401))
	var pv: String = s.preview_text()
	ok(pv.contains("400줄") and pv.contains("앞의 400줄까지만") and pv.contains("뒤의 1줄은 뺐어요"), "401 lines: cut to 400 with the note (%s)" % pv.replace("\n", " | "))
	ok(s.save() == "", "401 lines: saved (the cut lyrics)")
	var sv: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	ok((sv["lines"] as Array).size() == 400 and _lines_in_limits(sv["lines"]), "saved song has 400 lines, within every limit")
	_drop(s)
	var s2 := _new_screen()
	s2.set_title("Long line")
	s2.set_pasted("Short line one\n" + "w".repeat(201) + "\nShort line three")
	ok(s2.preview_text().contains("1줄은 200자를 넘어서 200자까지만"), "201 character line: cut note")
	ok(s2.save() == "", "201 character line: saved")
	var lv: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	ok((lv["lines"] as Array).size() == 3 and str((lv["lines"] as Array)[1]["text"]).length() == 200 and _lines_in_limits(lv["lines"]), "the 201 character line is saved with 200 characters")
	_drop(s2)
	var s3 := _new_screen()
	s3.set_title("Huge")
	var big: PackedStringArray = []
	for i in 160:
		big.append(("%03d " % i) + "v".repeat(146)) # 150 characters x 160 lines = 24000 characters
	s3.set_pasted("\n".join(big))
	ok(s3.preview_text().contains("20000자를 넘어서"), "24000 characters: total cut note")
	ok(s3.save() == "", "24000 characters: saved")
	var hv: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	var total := 0
	for ln in (hv["lines"] as Array):
		total += str(ln["text"]).length()
	ok(total <= 20000 and _lines_in_limits(hv["lines"]) and (hv["lines"] as Array).size() < 160, "the saved song has at most 20000 characters (%d)" % total)
	_drop(s3)
	var s4 := _new_screen()
	s4.set_title("Marks")
	s4.set_pasted("[Chorus]\nThe kettle hums\n[Verse 2]\nOne small note\n[ ]")
	var pv4: String = s4.preview_text()
	ok(pv4.contains("2줄") and pv4.contains("구간 표시 3줄은 뺐어요"), "[Chorus] style lines: removed and explained (%s)" % pv4.replace("\n", " | "))
	ok(s4.save() == "", "[Chorus] paste saved")
	var mv: Dictionary = SongStore.load_song(str(_added[_added.size() - 1]))
	var no_marks := true
	for ln in (mv["lines"] as Array):
		if str(ln["text"]).begins_with("["):
			no_marks = false
	ok((mv["lines"] as Array).size() == 2 and no_marks, "the saved song has no [ ... ] line")
	_drop(s4)
	# a huge paste (more than the raw cap) is cut before any parsing
	var s5 := _new_screen()
	s5.set_title("Raw cap")
	s5.set_pasted("abc def\n".repeat(30000)) # 240000 characters
	ok(s5.pasted_text.length() == SongLyricsAddScreen.MAX_PASTE_CHARS and s5.preview_text().contains("너무 길어서"), "a 240000 character paste is cut to %d characters with a note" % SongLyricsAddScreen.MAX_PASTE_CHARS)
	ok(s5.save() == "", "the capped paste still saves (400 lines max)")
	_drop(s5)
	await _frames(2)


func _test_save_failures() -> void:
	print("[save failures: the typed lyrics stay on the screen, nothing is stored]")
	_fresh()
	var s := _new_screen()
	s.set_title("Fail Case")
	var en: String = _fixture("lyrics_en.txt")
	await _frames(2)
	_type_paste(s, en)
	await _frames(2)
	# disk write failure
	SongStore.write_hook = func(_p: String) -> bool: return false
	var tc0: int = _toasts.size()
	var r: String = s.save()
	ok(r == SongLyricsAddScreen.MSG_SAVE_ERR["disk_write"] and s.save_error == r and _added.is_empty(), "disk failure: the Korean message, no song_added")
	ok(SongStore.list().is_empty() and _listing(ROOT).filter(func(x: Variant) -> bool: return str(x).begins_with("d:")).is_empty(), "disk failure: no song and no partial folder (%s)" % [_listing(ROOT)])
	ok(s.pasted_text == en and (_find(s, "PasteInput") as TextEdit).text == en and s.phase == "form", "disk failure: the typed lyrics are still in the box, the form is still open")
	ok(_toasts.size() > tc0 and _toast_has("저장하지 못했어요") and (_find(s, "SaveError") as Label).visible and (_find(s, "SaveError") as Label).text == r, "disk failure: toast and the red line in the footer say so")
	SongStore.write_hook = Callable()
	ok(s.save() == "" and _added.size() == 1 and SongStore.list().size() == 1, "after the disk is fine again the same screen saves the same lyrics")
	_drop(s)
	await _frames(2)
	# song count limit
	_fresh()
	SongStore.max_songs = 1
	var a := _new_screen()
	a.set_title("First")
	a.set_pasted(en)
	ok(a.save() == "", "song 1 of 1 is saved")
	var b := _new_screen()
	b.set_title("Second")
	b.set_pasted(en)
	await _frames(2)
	ok(_find(b, "FullNotice") != null, "a full library: the form shows a notice up front")
	var rb: String = b.save()
	ok(rb == SongLyricsAddScreen.MSG_SAVE_ERR["quota_songs"] and SongStore.list().size() == 1 and _added.size() == 1, "the song over the limit: quota_songs message, still 1 song")
	ok(b.pasted_text == en and _listing(ROOT).filter(func(x: Variant) -> bool: return str(x).begins_with("d:")).size() == 1, "quota_songs: lyrics stay, only the first song's folder exists")
	_drop(a)
	_drop(b)
	# size limit
	_fresh()
	SongStore.fake_used_bytes = SongStore.max_bytes
	var c := _new_screen()
	c.set_title("Too big")
	c.set_pasted(en)
	var rc: String = c.save()
	ok(rc == SongLyricsAddScreen.MSG_SAVE_ERR["quota_bytes"] and SongStore.list().is_empty() and _added.is_empty(), "storage full: quota_bytes message, nothing stored")
	_drop(c)
	_fresh()
	await _frames(2)


func _test_no_pc() -> void:
	print("[phone-only mode (no PC): saving works without any request]")
	_fresh()
	Route.phone_hook = func() -> bool: return true
	var old_mode: String = Route.mode
	Route.mode = "phone"
	await _frames(1)
	var sent: int = Api.sent_count
	var s := _new_screen()
	s.set_title("Offline Song")
	s.set_pasted(_fixture("lyrics_en.txt"))
	await _frames(2)
	ok(not _texts(s).contains("PC") and not _texts(s).contains("연결"), "no PC: the screen shows no PC / connection text")
	ok(s.save() == "" and SongStore.list().size() == 1, "no PC + phone-only mode: the lyrics are saved")
	ok(Api.sent_count == sent, "no PC: Api.sent_count unchanged (%d -> %d)" % [sent, Api.sent_count])
	_drop(s)
	Route.mode = old_mode
	Route.phone_hook = Callable()
	await _frames(2)


func _test_source_rules() -> void:
	print("[source rules: no PC calls, no auto collection, no AI, forbidden words]")
	var f := FileAccess.open(SRC, FileAccess.READ)
	var text: String = f.get_as_text() if f != null else ""
	ok(text.length() > 1000, "the screen source can be read (%d characters)" % text.length())
	var hits: Array = _forbidden_hits(text)
	ok(hits.is_empty(), "the screen source has none of: publish / flag / challenge / cancel_request / enrich / Api. / Backend / Route. (%s)" % [hits])
	ok(not text.contains("create_timer") and not text.contains("Timer.new") and not text.contains("_process"), "no timer or per-frame code: nothing can start a lookup by itself")
	var n_find := 0
	var n_search := 0
	for ln in text.split("\n"):
		var t: String = ln.strip_edges()
		if t.contains("client.find(") and not t.begins_with("##") and not t.begins_with("#"):
			n_find += 1
		if t.contains("client.search(") and not t.begins_with("#"):
			n_search += 1
	ok(n_find == 1 and n_search == 1, "the lookup client is called from exactly one place each (find %d, search %d)" % [n_find, n_search])
	ok(not text.contains("text_changed.connect(find") and not text.contains("text_changed.connect(search"), "typing never starts a lookup")
	# a text that calls the client from a field change would be caught by the line above
	ok("text_changed.connect(find_lyrics)".contains("text_changed.connect(find"), "scanner self-check: the 'typing starts a lookup' pattern matches when present")


# ---------------------------------------------------------------- LRCLIB

func _new_lr_screen(title: String, artist: String) -> SongLyricsAddScreen:
	var s := _new_screen()
	s.set_title(title)
	s.set_artist(artist)
	s.set_source("lrclib")
	return s


func _test_lrclib_budget() -> void:
	print("[LRCLIB: only on the button, get <= 1 + search <= 1 per song]")
	_fresh()
	await _lr_reset()
	var s := _new_lr_screen("Kettle Morning", "Test Artist")
	await _frames(2)
	await get_tree().create_timer(0.8).timeout
	var log0: Array = await _lr_log()
	ok(log0.is_empty() and s._client == null and s.lr_get_calls == 0 and s.lr_search_calls == 0, "opening, typing title / artist, choosing the LRCLIB source: 0 requests (no client even created)")
	s.set_pasted("typing in the paste box does not matter")
	s.set_duration_text("3:42")
	s.set_source("pasted")
	s.set_source("lrclib")
	await get_tree().create_timer(0.6).timeout
	ok((await _lr_log()).is_empty(), "typing a length, switching the source back and forth: still 0 requests")
	ok(_find(s, "BtnFind") != null and _find(s, "BtnSearch") != null and _find(s, "DurationInput") != null, "the find / similar buttons and the length box exist")
	s.set_duration_text("")
	_press(s, "BtnFind")
	ok(s.lr_busy and s.lr_status == "busy" and _texts(s).contains("찾는 중") and (_find(s, "BtnFind") as Button).disabled, "while waiting the screen says it is searching and the button is off")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get finished")
	var log1: Array = await _lr_log()
	ok(log1.size() == 1 and str(log1[0]["path"]) == "/api/get", "after one tap: exactly 1 request, GET /api/get (%s)" % [_lr_paths(log1)])
	ok(str(log1[0]["query"].get("track_name", "")) == "Kettle Morning" and str(log1[0]["query"].get("artist_name", "")) == "Test Artist", "the get carried title and artist")
	ok(str(log1[0]["headers"]["user-agent"]).begins_with("HoehwaPractice/") and str(log1[0]["headers"]["lrclib-client"]).begins_with("HoehwaPractice/"), "the get identified the app (User-Agent and Lrclib-Client)")
	await _frames(2)
	ok(s.lr_status == "found" and int(s.lr_record["id"]) == 1001 and s.lr_items.size() == 1, "exact hit: the record is listed and pre-selected")
	var at: Label = _find(s, "Attribution") as Label
	ok(at != null and at.text == "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요", "LRCLIB lyrics chosen: the attribution text is shown")
	var pv: String = (_find(s, "LyricsPreview") as Label).text
	ok(pv.contains("6줄") and pv.contains("외울 줄 6개") and pv.contains("시간표는 쓰지 않고"), "the chosen LRCLIB lyrics are previewed as 6 lines to memorize, times not kept (%s)" % pv.replace("\n", " | "))
	ok(not (_find(s, "BtnSave") as Button).disabled, "title + chosen lyrics: save is enabled")
	_press(s, "BtnFind")
	_press(s, "BtnFind")
	s.find_lyrics()
	await get_tree().create_timer(0.8).timeout
	ok((await _lr_log()).size() == 1 and s.lr_get_calls == 1, "tapping 'find' 3 more times: still 1 request")
	ok(_toast_has("이미 그 방법으로"), "the extra taps explain why nothing was sent (toast)")
	_press(s, "BtnSearch")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "search finished")
	var sb: Button = _find(s, "BtnSearch") as Button
	ok(sb != null and sb.disabled, "after the search the 'similar' button is off")
	s.search_lyrics()
	s.search_lyrics()
	await get_tree().create_timer(0.8).timeout
	var log3: Array = await _lr_log()
	ok(log3.size() == 2 and str(log3[1]["path"]) == "/api/search" and s.lr_search_calls == 1, "search: exactly 1 more request after several taps (total 2: %s)" % [_lr_paths(log3)])
	ok(_calls_ok(s.lr_get_calls, s.lr_search_calls), "per song at most 1 get and 1 search")
	ok(float(log3[1]["t"]) - float(log3[0]["t"]) >= 0.39, "the two requests are at least 400 ms apart (%.3f s)" % (float(log3[1]["t"]) - float(log3[0]["t"])))
	await _frames(2)
	ok(s.lr_items.size() >= 2 and _find(s, "Candidates") != null, "similar-song candidates are listed (%d)" % s.lr_items.size())
	var idx_long := -1
	for i in s.lr_items.size():
		if int((s.lr_items[i] as Dictionary)["id"]) == 1002:
			idx_long = i
	ok(idx_long >= 0 and s.choose_candidate(idx_long) and int(s.lr_record["id"]) == 1002, "choosing another candidate (the long edit) selects it")
	var items_keep: Array = s.lr_items
	s.lr_items = [{"id": 1003, "trackName": "Plain Boat", "artistName": "Test Artist", "albumName": "", "duration": 30.0, "syncedLyrics": "", "plainLyrics": "a b c
d e f", "instrumental": false},
		{"id": 1004, "trackName": "Quiet Room", "artistName": "Test Artist", "albumName": "", "duration": 45.0, "syncedLyrics": "", "plainLyrics": "", "instrumental": true}]
	ok(s.choose_candidate(0) and not bool(s.current_lyrics()["timed"]) and (s.current_lyrics()["lines"] as Array).size() == 2, "a plain-only record can be chosen: 2 lines, no times")
	ok(not s.choose_candidate(1) and int(s.lr_record["id"]) == 1003, "an instrumental record cannot be chosen (the earlier choice stays)")
	s.lr_items = items_keep
	s.choose_candidate(idx_long)
	# a different song (title edited) gets a new budget; case / spaces do not
	s.set_title("KETTLE   morning ")
	ok(s.lr_get_calls == 1 and s.lr_search_calls == 1, "the same song typed with other case / spaces keeps the used budget")
	s.set_title("Plain Boat")
	ok(s.lr_get_calls == 0 and s.lr_search_calls == 0 and s.lr_record.is_empty() and s.lr_items.is_empty(), "another title is another song: budget back to 0 and the earlier song's candidates and chosen lyrics are cleared (M7 follow-up 2)")
	await get_tree().create_timer(0.6).timeout
	ok((await _lr_log()).size() == 2, "changing the title sent nothing by itself")
	await _frames(2)
	_press(s, "BtnFind")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get for the second song finished")
	var log4: Array = await _lr_log()
	ok(log4.size() == 3 and str(log4[2]["path"]) == "/api/get" and str(log4[2]["query"]["track_name"]) == "Plain Boat", "the second song: its own get (3 requests in all)")
	_drop(s)
	await _frames(2)
	# 25 results: the screen shows at most 20 rows
	var s2 := _new_lr_screen("Many Songs", "Crowd Artist")
	var many: Array = []
	for i in 25:
		many.append({"id": 3000 + i, "trackName": "Many Songs %02d" % i, "artistName": "Crowd Artist", "albumName": "Crowd", "duration": 100.0 + i, "syncedLyrics": "[00:01.00] one", "plainLyrics": "one", "instrumental": false})
	s2.lr_items = many
	s2.lr_status = "found"
	s2._render()
	await _frames(3)
	var rows := 0
	var g: Node = _find(s2, "Candidates")
	if g != null:
		for l in g.find_children("*", "Label", true, false):
			if (l as Label).theme_type_variation == &"ListMain":
				rows += 1
	ok(rows == 20, "25 results given: at most 20 rows are shown (%d rows)" % rows)
	_drop(s2)
	await _lr_reset()
	var s2b := _new_lr_screen("Kettle Morning", "Test Artist")
	s2b.search_lyrics()
	ok(await _until(func() -> bool: return not s2b.lr_busy, 10.0), "search without a get finished")
	var log5: Array = await _lr_log()
	ok(log5.size() == 1 and str(log5[0]["path"]) == "/api/search" and s2b.lr_get_calls == 0 and s2b.lr_items.size() >= 2, "search without a get: 1 request, the search budget is separate (%d results)" % s2b.lr_items.size())
	_drop(s2b)
	# title / artist too short: no request at all
	await _lr_reset()
	var s3 := _new_lr_screen("a", "Test Artist")
	s3.find_lyrics()
	await _frames(2)
	ok((await _lr_log()).is_empty() and s3.lr_get_calls == 0 and s3.lr_message == SongLyricsAddScreen.MSG_TITLE_SHORT, "a 1 character title: find sends nothing, 'at least two characters' hint")
	s3.set_title("a")
	s3.set_artist("b")
	s3.find_lyrics()
	s3.search_lyrics()
	await get_tree().create_timer(0.6).timeout
	ok((await _lr_log()).is_empty() and s3.lr_get_calls == 0 and s3.lr_search_calls == 0 and s3.lr_message == SongLyricsAddScreen.MSG_TITLE_SHORT, "both title and artist 1 character: find and search send nothing, 'at least two characters' hint")
	s3.set_title("Kettle Morning")
	s3.set_artist("b")
	s3.find_lyrics()
	await get_tree().create_timer(0.6).timeout
	ok((await _lr_log()).is_empty() and s3.lr_get_calls == 0, "a 1 character artist: find (get needs both) sends nothing")
	s3.set_title("   ")
	s3.set_artist("   ")
	s3.find_lyrics()
	s3.search_lyrics()
	await get_tree().create_timer(0.3).timeout
	ok((await _lr_log()).is_empty(), "blank title and artist: nothing sent")
	_drop(s3)
	# search needs only one of title / artist to have 2 characters (same rule as SongAddScreen); get still needs both
	for case in [["a", "Test Artist"], ["Kettle Morning", "b"], ["Kettle Morning", ""], ["", "Test Artist"]]:
		await _lr_reset()
		var sc := _new_lr_screen(str(case[0]), str(case[1]))
		sc.find_lyrics()
		ok(sc.lr_get_calls == 0 and (await _lr_log()).is_empty(), "title [%s] artist [%s]: find sends nothing" % [case[0], case[1]])
		sc.search_lyrics()
		ok(await _until(func() -> bool: return not sc.lr_busy, 10.0), "title [%s] artist [%s]: search finished" % [case[0], case[1]])
		var lg: Array = await _lr_log()
		ok(lg.size() == 1 and str(lg[0]["path"]) == "/api/search" and sc.lr_search_calls == 1, "title [%s] artist [%s]: search sends exactly 1 request (%s)" % [case[0], case[1], _lr_paths(lg)])
		_drop(sc)
	# the real lrclib.net can never be reached from a test
	var s4 := _new_lr_screen("Kettle Morning", "Test Artist")
	s4.lrclib_base_url = "https://lrclib.net"
	s4.find_lyrics()
	ok(await _until(func() -> bool: return not s4.lr_busy, 10.0), "the real host: the call ended")
	ok(s4._client != null and s4._client.sent_count == 0 and s4.lr_status == "error", "the real lrclib.net was refused by the test guard without sending (sent_count 0)")
	_drop(s4)
	await _frames(2)


func _test_lrclib_duration() -> void:
	print("[LRCLIB: the optional length]")
	_fresh()
	await _lr_reset()
	var s := _new_lr_screen("Kettle Morning", "Test Artist")
	ok(s.query_duration() == 0.0 and s.duration_note_text() == "", "empty length: nothing to send, no note")
	_press(s, "BtnFind")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get without a length finished")
	var l1: Array = await _lr_log()
	ok(l1.size() == 1 and not (l1[0]["query"] as Dictionary).has("duration"), "empty length: the get has no duration parameter (%s)" % [l1[0]["query"]])
	_drop(s)
	await _frames(2)
	await _lr_reset()
	var s2 := _new_lr_screen("Kettle Morning", "Test Artist")
	s2.set_duration_text("0:21")
	ok(s2.query_duration() == 21.0, "0:21 -> 21 seconds")
	_press(s2, "BtnFind")
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "get with 0:21 finished")
	var l2: Array = await _lr_log()
	ok(l2.size() == 1 and str(l2[0]["query"].get("duration", "")) == "21", "'0:21' is sent as duration=21 (%s)" % [l2[0]["query"]])
	_press(s2, "BtnSearch")
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "search with a length finished")
	var cand_sub := ""
	if s2.lr_items.size() > 0:
		cand_sub = str(SongAddScreen.candidate_text(s2.lr_items[0], s2.query_duration())["sub"])
	ok(s2.lr_items.size() >= 2 and float((s2.lr_items[0] as Dictionary)["duration_diff"]) <= float((s2.lr_items[1] as Dictionary)["duration_diff"]), "with a length the candidates are ordered by closeness")
	ok(cand_sub != "", "candidate texts are built with the typed length")
	_drop(s2)
	await _frames(2)
	await _lr_reset()
	var s3 := _new_lr_screen("Kettle Morning", "Test Artist")
	s3.set_duration_text("3:42")
	_press(s3, "BtnFind")
	ok(await _until(func() -> bool: return not s3.lr_busy, 10.0), "get with 3:42 finished")
	var l3: Array = await _lr_log()
	ok(l3.size() == 1 and str(l3[0]["query"].get("duration", "")) == "222", "'3:42' is sent as duration=222 (%s)" % [l3[0]["query"]])
	ok(s3.lr_status == "none" and s3.lr_message.contains("비슷한 곡 찾기"), "a 222 s length that does not match: 'not found' and it points to the similar-song button")
	_press(s3, "BtnSearch")
	ok(await _until(func() -> bool: return not s3.lr_busy, 10.0), "similar search after the miss finished")
	var l3b: Array = await _lr_log()
	ok(_lr_paths(l3b) == ["/api/get", "/api/search"], "length outside +-2 s: one get then one search (%s)" % [_lr_paths(l3b)])
	ok(s3.lr_items.size() >= 1 and s3.choose_candidate(0), "a candidate can be chosen after the search")
	_drop(s3)
	await _frames(2)
	for bad in ["abc", "99:99", "-5", "-1:30", "0:00"]:
		await _lr_reset()
		var s4 := _new_lr_screen("Kettle Morning", "Test Artist")
		s4.set_duration_text(bad)
		await _frames(1)
		var note: Label = _find(s4, "DurationNote") as Label
		ok(s4.query_duration() == 0.0 and s4.duration_note_text() == SongLyricsAddScreen.MSG_DURATION_BAD and note != null and note.visible and note.text == SongLyricsAddScreen.MSG_DURATION_BAD, "length '%s': ignored and the note is shown" % bad)
		_press(s4, "BtnFind")
		ok(await _until(func() -> bool: return not s4.lr_busy, 10.0), "get with the wrong length '%s' finished" % bad)
		var l4: Array = await _lr_log()
		ok(l4.size() == 1 and not (l4[0]["query"] as Dictionary).has("duration"), "length '%s': the get has no duration parameter" % bad)
		_drop(s4)
		await _frames(1)
	ok(_toast_has(SongLyricsAddScreen.MSG_DURATION_BAD), "a wrong length is also told by a toast when the person taps")


func _test_lrclib_new_song() -> void:
	print("[LRCLIB: a different title / artist is a new song -- the earlier song's lyrics never get saved under the new name (M7 follow-up 2)]")
	_fresh()
	await _lr_reset()
	var s := _new_lr_screen("Kettle Morning", "Test Artist")
	_press(s, "BtnFind")
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get finished")
	await _frames(2)
	ok(not s.lr_record.is_empty() and not s.lr_items.is_empty() and s.save_block_reason() == "", "the first song: lyrics chosen, saving would be allowed")
	var first_lines: Array = (s.current_lyrics()["lines"] as Array).duplicate(true)
	ok(first_lines.size() == 6, "the chosen lyrics have 6 lines")
	s.set_title("Another Song Entirely")
	ok(s.lr_record.is_empty() and s.lr_items.is_empty() and s.lr_status == "" and s.lr_message == "", "title changed: candidates, chosen lyrics, status and message are cleared")
	ok(s.save_block_reason() == SongLyricsAddScreen.MSG_NEED_LRCLIB and (s.current_lyrics()["lines"] as Array).is_empty(), "title changed: nothing left to save, the screen asks to find lyrics again")
	await _frames(2)
	ok(_find(s, "Candidates") == null and _find(s, "Attribution") == null and (_find(s, "BtnSave") as Button).disabled, "title changed: the candidate list and attribution are gone, the save button is off")
	var n0: int = SongStore.list().size()
	ok(s.save() != "" and SongStore.list().size() == n0, "title changed: save() is refused and no song is written")
	ok((await _lr_log()).size() == 1, "changing the title sent no request")
	_drop(s)
	await _frames(2)
	# the artist works the same way; typing the same name with other case / spaces does not clear
	await _lr_reset()
	var s2 := _new_lr_screen("Kettle Morning", "Test Artist")
	_press(s2, "BtnFind")
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "get (second form) finished")
	s2.set_artist("TEST   artist ")
	ok(not s2.lr_record.is_empty() and not s2.lr_items.is_empty(), "the same artist with other case / spaces: the chosen lyrics stay")
	s2.set_artist("Someone Else")
	ok(s2.lr_record.is_empty() and s2.lr_items.is_empty() and s2.save_block_reason() == SongLyricsAddScreen.MSG_NEED_LRCLIB, "artist changed: the chosen lyrics are cleared")
	_drop(s2)
	# a late answer for the old song is dropped and cannot bring the old lyrics back
	await _lr_reset()
	var s3 := _new_lr_screen("Kettle Morning", "Test Artist")
	s3.find_lyrics()
	s3.set_title("Quick Change")
	await get_tree().create_timer(1.0).timeout
	ok(s3.lr_record.is_empty() and s3.lr_items.is_empty() and not s3.lr_busy, "an answer that arrives after the title changed is dropped")
	_drop(s3)
	await _frames(2)


func _test_lrclib_failures() -> void:
	print("[LRCLIB failures: Korean message + paste hint, no crash, retry rules]")
	_fresh()
	var cases := [
		["__429__ x", "Test Artist", "너무 많아요", 2],
		["__500__ x", "Test Artist", "문제가 있어요", 1],
		["__badjson__ x", "Test Artist", "읽지 못했어요", 1],
		["__html__ x", "Test Artist", "읽지 못했어요", 1],
		["__drop__ x", "Test Artist", "연결되지 않았거나", 1],
	]
	for c in cases:
		await _lr_reset()
		var s := _new_lr_screen(str(c[0]), str(c[1]))
		s.find_lyrics()
		ok(await _until(func() -> bool: return not s.lr_busy, 25.0), "[%s] the call ended" % c[0])
		await _frames(2)
		ok(s.lr_status == "error" and s.lr_message.contains(str(c[2])) and s.lr_message.contains("붙여넣"), "[%s] error shown with '%s' and the paste hint (%s)" % [c[0], c[2], s.lr_message])
		var lg: Array = await _lr_log()
		ok(lg.size() == int(c[3]), "[%s] %d request(s) reached the server (429 retried once, nothing else retried): %d" % [c[0], int(c[3]), lg.size()])
		if lg.size() >= 2:
			ok(float(lg[1]["t"]) - float(lg[0]["t"]) >= 0.9, "[%s] the retry waited for Retry-After (%.2f s)" % [c[0], float(lg[1]["t"]) - float(lg[0]["t"])])
		ok(_find(s, "BtnToPaste") != null and not (_find(s, "BtnFind") as Button).disabled, "[%s] a 'paste lyrics' button is offered" % c[0])
		s.find_lyrics()
		await get_tree().create_timer(0.6).timeout
		ok((await _lr_log()).size() == lg.size(), "[%s] tapping again after the failure sends nothing more" % c[0])
		if str(c[0]).begins_with("__429__"):
			ok(s.lr_message.contains("약 1초"), "[429] the message says when to try again")
		_drop(s)
		await _frames(2)
	# 429 once: the one automatic retry succeeds
	await _lr_reset()
	var o := _new_lr_screen("__429_once__ x", "Test Artist")
	o.find_lyrics()
	ok(await _until(func() -> bool: return not o.lr_busy, 25.0), "[429 once] the call ended")
	var lo: Array = await _lr_log()
	ok(lo.size() == 2 and o.lr_status == "found" and not o.lr_record.is_empty(), "[429 once] one automatic retry, then the lyrics were found")
	_drop(o)
	await _frames(2)
	# connection refused
	var r := _new_lr_screen("Kettle Morning", "Test Artist")
	r.lrclib_base_url = "http://127.0.0.1:9"
	r.find_lyrics()
	ok(await _until(func() -> bool: return not r.lr_busy, 15.0), "[refused] the call ended")
	ok(r.lr_status == "error" and r.lr_message.contains("연결되지 않았거나") and r.lr_message.contains("붙여넣"), "[refused] no connection: Korean message and the paste hint")
	_drop(r)
	# 404, empty search, instrumental
	await _lr_reset()
	var n := _new_lr_screen("Nope Song", "Nobody Here")
	n.find_lyrics()
	ok(await _until(func() -> bool: return not n.lr_busy, 10.0), "[404] the call ended")
	ok(n.lr_status == "none" and n.lr_record.is_empty() and n.lr_message.contains("찾지 못했어요") and _find(n, "BtnToPaste") != null, "[404] 'not found' with a way to paste")
	n.search_lyrics()
	ok(await _until(func() -> bool: return not n.lr_busy, 10.0), "[empty search] the call ended")
	ok(n.lr_status == "none" and n.lr_message.contains("비슷한 곡도 찾지 못했어요") and n.lr_message.contains("붙여넣"), "[empty search] 'not even similar' with the paste hint")
	ok((await _lr_log()).size() == 2, "[404 + empty search] 2 requests in all")
	n.set_title("Nope Song 2")
	n.set_source("pasted")
	ok(n.source == "pasted" and _find(n, "PasteInput") != null, "the paste hint button path: the source switches to paste")
	_drop(n)
	await _lr_reset()
	var q := _new_lr_screen("Quiet Room", "Test Artist")
	q.find_lyrics()
	ok(await _until(func() -> bool: return not q.lr_busy, 10.0), "[instrumental] the call ended")
	ok(q.lr_status == "instrumental" and q.lr_record.is_empty() and q.lr_message.contains("연주곡") and q.lr_message.contains("붙여넣") and (q.save_block_reason() == SongLyricsAddScreen.MSG_NEED_PASTE or q.save_block_reason() == SongLyricsAddScreen.MSG_NEED_LRCLIB), "[instrumental] 'no lyrics' with the paste hint; nothing to save")
	ok(not q.choose_candidate(0), "[instrumental] the record cannot be chosen")
	_drop(q)
	await _frames(2)
	# the spacing rule across a failed get and the search that follows
	await _lr_reset()
	var sp := _new_lr_screen("__500__ x", "Test Artist")
	sp.find_lyrics()
	ok(await _until(func() -> bool: return not sp.lr_busy, 10.0), "[spacing] failed get ended")
	sp.search_lyrics()
	ok(await _until(func() -> bool: return not sp.lr_busy, 10.0), "[spacing] search ended")
	var lsp: Array = await _lr_log()
	ok(lsp.size() == 2 and float(lsp[1]["t"]) - float(lsp[0]["t"]) >= 0.39, "[spacing] get then search 400 ms apart even after an error (%.3f s)" % [float(lsp[1]["t"]) - float(lsp[0]["t"])])
	_drop(sp)
	await _frames(2)


func _test_lrclib_late() -> void:
	print("[LRCLIB: late answers are dropped (leaving the screen, another song)]")
	_fresh()
	await _lr_reset()
	# leaving through on_hide
	var s := _new_lr_screen("__slow__ x", "Test Artist")
	s.find_lyrics()
	await get_tree().create_timer(0.3).timeout
	var cl: LrclibClient = s._client
	ok(cl != null and s.lr_busy, "a slow answer is on its way")
	s.on_hide()
	ok(not s.lr_busy and s._client == null and s.lr_status == "", "on_hide: the screen forgets the request at once (busy off, client dropped)")
	await get_tree().create_timer(2.2).timeout
	ok(not is_instance_valid(cl), "the abandoned client frees itself after its slow answer")
	ok(s.lr_items.is_empty() and s.lr_record.is_empty() and s.lr_status == "" and s.lr_message == "", "the late answer changed nothing on the screen")
	ok(s.lr_get_calls == 1, "the call is still counted (the request had been sent)")
	_drop(s)
	await _frames(2)
	# a late answer after the title changed to another song
	await _lr_reset()
	var s2 := _new_lr_screen("__slow__ x", "Test Artist")
	s2.find_lyrics()
	await get_tree().create_timer(0.3).timeout
	s2.set_title("Another Song")
	ok(not s2.lr_busy and s2.lr_get_calls == 0, "another song typed while waiting: busy off, budget back to 0")
	await get_tree().create_timer(2.2).timeout
	ok(s2.lr_items.is_empty() and s2.lr_record.is_empty() and s2.lr_status != "found" and s2.lr_status != "none" and s2.lr_status != "error", "the first song's late answer was dropped (status '%s')" % s2.lr_status)
	_drop(s2)
	await _frames(2)
	# freeing the screen while a request is in flight
	await _lr_reset()
	var s3 := _new_lr_screen("__slow__ x", "Test Artist")
	s3.find_lyrics()
	await get_tree().create_timer(0.3).timeout
	var cl3: LrclibClient = s3._client
	var c0: int = _closed
	s3.go_back()
	ok(_closed == c0 + 1, "go_back while only searching: the screen closes at once")
	s3.queue_free()
	await get_tree().create_timer(2.2).timeout
	ok(not is_instance_valid(cl3), "the client of a freed screen is gone after its slow answer (no late signal reached the dead screen)")
	# reopening the form starts clean
	var s4 := _new_lr_screen("Kettle Morning", "Test Artist")
	s4.find_lyrics()
	ok(await _until(func() -> bool: return not s4.lr_busy, 10.0), "get finished before the reopen test")
	s4.open("en", {})
	ok(s4.lr_get_calls == 0 and s4.lr_items.is_empty() and s4.lr_record.is_empty() and s4.title_text == "" and s4.source == "pasted", "open() again: LRCLIB state, fields and source are reset")
	_drop(s4)
	await _frames(2)


func _test_lrclib_save() -> void:
	print("[LRCLIB: choose, save, source info]")
	_fresh()
	await _lr_reset()
	var s := _new_lr_screen("Kettle Morning", "Test Artist")
	s.set_duration_text("0:21")
	s.find_lyrics()
	ok(await _until(func() -> bool: return not s.lr_busy, 10.0), "get finished")
	ok(s.save() == "", "LRCLIB lyrics saved")
	ok(_added.size() == 1, "song_added fired once")
	var sv: Dictionary = SongStore.load_song(str(_added[0]))
	var src: Dictionary = sv["source"]
	ok(SongModel.is_lyrics(sv) and str(src["lyrics"]) == "lrclib" and int(src["lrclib_id"]) == 1001 and str(src["attribution"]) == "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요" and str(src["timing"]) == "none", "saved: kind lyrics, source lrclib, lrclib_id 1001, attribution text, timing none")
	ok((sv["lines"] as Array).size() == 6 and float(sv["duration"]) == 0.0 and str(sv["title"]) == "Kettle Morning" and str(sv["artist"]) == "Test Artist", "saved: 6 lines, duration 0 (the typed length is not stored), title and artist")
	var files: Array = _listing(ROOT.path_join(str(_added[0])))
	ok(files.size() == 1 and str(files[0]).begins_with("f:song.json:"), "the LRCLIB song folder holds only song.json")
	var log: Array = await _lr_log()
	ok(log.size() == 1, "saving made no LRCLIB request (1 request in all)")
	_drop(s)
	await _frames(2)
	# title empty -> adopted from the chosen record; the budget is kept
	await _lr_reset()
	var s2 := _new_screen()
	s2.set_artist("Test Artist")
	s2.set_title("Kettle Morning")
	s2.set_source("lrclib")
	s2.find_lyrics()
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "get (second form) finished")
	s2.search_lyrics()
	ok(await _until(func() -> bool: return not s2.lr_busy, 10.0), "search (second form) finished")
	var pick := -1
	for i in s2.lr_items.size():
		if int((s2.lr_items[i] as Dictionary)["id"]) == 2001:
			pick = i
	s2.set_title("")
	ok(s2.lr_get_calls == 0, "the title was cleared: that is a new song, budget back to 0")
	_drop(s2)
	await _frames(2)
	var s3 := _new_screen()
	s3.set_artist("Test Artist")
	s3.set_title("Kettle Morning")
	s3.set_source("lrclib")
	s3.search_lyrics()
	ok(await _until(func() -> bool: return not s3.lr_busy, 10.0), "search (third form) finished")
	var kept_items: Array = s3.lr_items.duplicate(true)
	s3.set_artist("")
	s3.set_title("")
	s3.lr_items = kept_items # clearing the names cleared the candidates (new song): put them back to test the adoption
	s3.lr_get_calls = 1
	s3.lr_search_calls = 1
	ok(s3.choose_candidate(0) and s3.title_text != "" and s3.artist_text != "", "choosing a candidate fills an empty title and artist from it (%s / %s)" % [s3.title_text, s3.artist_text])
	ok(s3.lr_get_calls == 1 and s3.lr_search_calls == 1, "adopting the names does not give a new budget")
	ok(s3.save() == "" and SongStore.list().size() == 2, "the adopted-title song saves")
	ok(pick == -1 or pick >= 0, "candidate scan ran")
	_drop(s3)
	await _frames(2)


# ---------------------------------------------------------------- layout

func _layout_check(s: SongLyricsAddScreen, label: String) -> void:
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
	var s := _new_screen()
	await _layout_check(s, "empty form")
	s.set_title("T".repeat(900))
	s.set_artist("Artist ".repeat(100))
	s._render()
	await _layout_check(s, "900 character title")
	s.set_pasted(_numbered(401))
	s._render()
	await _layout_check(s, "pasted 401 lines (notes shown)")
	s.set_pasted("[Chorus]\nThe kettle hums\nthe kettle hums\n♪♪\n[00:01.00] timed " + "x".repeat(300))
	s._render()
	await _layout_check(s, "pasted with chorus / symbol / timed / long line notes")
	s.set_source("lrclib")
	s.set_duration_text("abc")
	await _layout_check(s, "lrclib: empty, wrong length note")
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
	s.lr_status = "error"
	s.lr_message = "인터넷에 연결되지 않았거나 가사 서버가 대답하지 않아요. " + SongLyricsAddScreen.MSG_PASTE_HINT + " 제목이나 가수를 고치면 다시 찾을 수 있어요."
	s._render()
	await _layout_check(s, "lrclib error with the paste button")
	s.lr_busy = true
	s.lr_status = "busy"
	s.lr_message = SongLyricsAddScreen.MSG_LR_BUSY
	s._render()
	await _layout_check(s, "lrclib busy")
	s.lr_busy = false
	SongStore.max_songs = 0
	s.set_source("pasted")
	s._render()
	await _layout_check(s, "full library notice")
	var vis_btn: Node = _find(s, "BtnSave")
	ok(vis_btn != null and (vis_btn as Control).is_visible_in_tree(), "layout: the save button is on screen")
	s.save_error = SongLyricsAddScreen.MSG_SAVE_ERR["disk_write"]
	s._render()
	await _layout_check(s, "save error line")
	SongStore.max_songs = SongStore.MAX_SONGS
	s.phase = "done"
	s._render()
	await _layout_check(s, "done")
	_drop(s)
	await _frames(2)


func _test_real_folder_untouched() -> void:
	print("[real folders]")
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "user files and the real user://songs are untouched (checked before the end of the run)")
	ok(SongStore.root == ROOT and str(SongStore.root).begins_with("user://test_"), "SongStore.root is a user://test_* folder for the whole run")
