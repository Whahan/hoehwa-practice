extends Node
## 제목으로 가사 찾기 (1.4.1): SongSearchScreen + 허브 검색 카드 시험. 설계 §2 흐름 1~6.
##   PC:   godot --headless --path godot res://tests/song_search_test.tscn
##   폰:   godot --headless --path godot res://tests/song_search_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5      (--python=<python.exe> 로 파이썬 지정)
## 가짜 LRCLIB(tests/fixtures/song/fake_lrclib.py, 포트 18781)는 시험이 직접 띄우고 자기 PID(와 하위)만 끈다.
## 가짜 /song/identify 서버는 이 파일 안의 GDScript(FakeIdentify, 포트 18782, 127.0.0.1 만)다. 실제 lrclib.net · AI 서비스 · 8770/8775/8776 접속 없음.
## 곡은 user://test_songs_ts 에만 저장하고, 설정·진행·학습 기록은 user://test_ts/ 로 돌린다. 시험 가사는 가짜 서버가 가진 직접 지은 문장이다.
## 마지막 줄: "== song_search_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 일부러 틀린 입력(변조)으로 검사기가 실제로 FAIL 을 내는지: _selftest() 구간.

const LR_PORT := 18781
const LR_BASE := "http://127.0.0.1:18781"
const ID_PORT := 18782
const ID_BASE := "http://127.0.0.1:18782"
const CLOSED_BASE := "http://127.0.0.1:9"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const ROOT := "user://test_songs_ts"
const DIR := "user://test_ts"
const SRC := "res://scripts/song/song_search_screen.gd"
const FORBIDDEN := ["/api/get?", "publish", "flag", "challenge", "cancel_request", "enrich", "/song/jobs", "/song/upload"]
const AI_NOTE := "곡 제목이 AI로 전송돼요. 가사는 보내지 않아요."

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
var _old_base: String
var _lr_pid: int = -1
var _fake: FakeIdentify = null
var _added: Array = []
var _pastes: Array = []
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
	_pastes.clear()


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


func _connect_pc(identify: Variant = true) -> void:
	Backend.health = {"song": true, "song_v": 1, "song_identify": identify, "llm": true, "llm_provider": "opencode"} # song_v stays 1: the PC does not bump it
	Backend._set_status(Backend.Status.READY)
	Api.set_remote(ID_BASE, "")


func _disconnect_pc() -> void:
	Backend.health = {}
	Backend._set_status(Backend.Status.FAILED, "x")
	Api.set_remote(CLOSED_BASE, "") # a closed port: a request that is attempted anyway is counted in Api.sent_count and goes nowhere


func _new_screen(lang: String = "en") -> SongSearchScreen:
	var s := SongSearchScreen.new()
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(s)
	s.lrclib_base_url = LR_BASE
	s.song_added.connect(func(id: String) -> void: _added.append(id))
	s.paste_requested.connect(func(t: String, a: String) -> void: _pastes.append([t, a]))
	s.closed.connect(func() -> void: _closed += 1)
	s.open(lang, {})
	return s


func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		n.queue_free()


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled and (b as Button).is_visible_in_tree():
		(b as Button).pressed.emit()
		return true
	return false


func _has(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	return b != null and b is CanvasItem and (b as CanvasItem).is_visible_in_tree()


## 검색칸에 글자를 쳐 넣고 [찾기] 를 누른다 (실제 입력칸과 단추를 거친다).
func _search(s: SongSearchScreen, q: String, wait: bool = true) -> void:
	var e: Node = _find(s, "QueryInput")
	if e is LineEdit:
		(e as LineEdit).text = q
		(e as LineEdit).text_changed.emit(q)
	else:
		s.set_query(q)
	_press(s, "BtnSearch")
	if wait:
		await _until(func() -> bool: return not s.is_busy(), 20.0)
		await _frames(2)


func _ids(items: Array) -> Array:
	var out: Array = []
	for r in items:
		out.append(int((r as Dictionary).get("id", 0)))
	return out


func _unique(a: Array) -> bool:
	var seen := {}
	for v in a:
		if seen.has(v):
			return false
		seen[v] = true
	return true


func _count_class(cls: String) -> int:
	return get_tree().root.find_children("*", cls, true, false).size()


func _consent_clear() -> void:
	Store.prefs.erase("song_consent")
	Store.prefs.erase("song_identify_consent")


func _close_sheets() -> void:
	for i in 5:
		if not Sheet.close_top("dismiss"):
			break


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


func _forbidden_hits(text: String) -> Array:
	var hits: Array = []
	for w in FORBIDDEN:
		if text.contains(str(w)):
			hits.append(w)
	return hits


## 한 요청의 query 에 키가 있는 것만 센다.
func _reqs_with(reqs: Array, path: String) -> Array:
	var out: Array = []
	for r in reqs:
		if str(r["path"]) == path:
			out.append(r)
	return out


# ---------------------------------------------------------------- fake LRCLIB server (python, started by this test)

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


func _start_lrclib() -> bool:
	var busy: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	for i in 60: # another run may hold the port for a moment: wait for it (never kill it)
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
	print("== song_search_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	_old_base = Api.base_url
	_rm_rf(DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	_consent_clear()
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	_disconnect_pc() # a closed port: the run must never reach the user's engine (8770)
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
	_test_source()
	var sent_start: int = Api.sent_count

	_fake = FakeIdentify.new()
	add_child(_fake)
	var id_up: bool = _fake.setup(ID_PORT)
	ok(id_up, "fake /song/identify (GDScript, 127.0.0.1) is up on port %d" % ID_PORT)
	var lr_up: bool = await _start_lrclib()
	ok(lr_up, "fake LRCLIB (fake_lrclib.py) is up on port %d" % LR_PORT)
	if lr_up and id_up:
		await _test_title_search()
		await _test_choose_and_save()
		await _test_unusable()
		await _test_ai_flow()
		await _test_ai_edges()
		await _test_ai_gate()
		await _test_hub()
		await _test_phone_only()
		await _test_lifetime()
		await _test_layout()
		var bad: Array = await _lr_bad_calls()
		ok(bad.is_empty(), "the fake LRCLIB saw no call other than search (bad_calls: %s)" % [bad])
		var all_log: Array = await _lr_log()
		var gets := 0
		for r in all_log:
			if str(r["path"]) != "/api/search":
				gets += 1
		ok(gets == 0, "every LRCLIB request of the whole run was /api/search (%d other)" % gets)
	_fake.stop()
	_fake.queue_free()
	await _stop_lrclib()
	await get_tree().create_timer(0.3).timeout
	var lr_closed: Dictionary = await _http(LR_BASE, HTTPClient.METHOD_GET, "/_ping")
	ok(int(lr_closed["code"]) == 0, "fake LRCLIB is gone and port %d is closed again" % LR_PORT)
	var tc := TCPServer.new()
	var again: bool = tc.listen(ID_PORT, "127.0.0.1") == OK
	tc.stop()
	ok(again, "fake /song/identify is gone and port %d is free again" % ID_PORT)
	_test_real_folder_untouched()
	ok(Api.sent_count >= sent_start, "(sent_count is only read, never reset)")

	_close_sheets()
	_fresh()
	SongStore.root = old_root
	_consent_clear()
	Route.phone_hook = Callable()
	Route.mode = "auto"
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Backend.health = _old_health
	Backend.status = _old_status
	Api.base_url = _old_base
	_rm_rf(DIR)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "test folders cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_search_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- sections

## 검사기 자체: 일부러 틀린 입력을 넣으면 실제로 FAIL 을 내는지.
func _selftest() -> void:
	print("[checker self-test: wrong input must FAIL]")
	ok(not _unique([1001, 1002, 1001]) and _unique([1001, 1002, 1005]) and _unique([]), "uniqueness checker rejects a repeated id")
	ok(not _forbidden_hits("GET /api/get?track_name=x").is_empty() and not _forbidden_hits("POST /song/jobs").is_empty(), "source scanner finds forbidden words")
	ok(_forbidden_hits("func x(): return 1").is_empty(), "source scanner passes clean text")
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
	var fake_reqs: Array = [{"path": "/api/search"}, {"path": "/api/get"}, {"path": "/api/search"}]
	ok(_reqs_with(fake_reqs, "/api/search").size() == 2 and _reqs_with(fake_reqs, "/api/get").size() == 1 and _reqs_with([], "/api/search").is_empty(), "request counter counts only the asked path")
	var dup_merge: Array = [{"id": 1}, {"id": 1}, {"id": 2}]
	ok(_ids(dup_merge) == [1, 1, 2] and not _unique(_ids(dup_merge)), "the id extractor + uniqueness checker see a duplicate in a raw list")


func _test_pure() -> void:
	print("[pure helpers: keys, AI answer checking, merging, language, preview, AI gate]")
	ok(SongSearchScreen.query_key("  Kettle   MORNING ") == "kettle morning" and SongSearchScreen.query_key("a b") != SongSearchScreen.query_key("ab"), "query_key: spaces reduced, lower case, different words differ")
	# parse_cands: the server's answer is not trusted
	ok(SongSearchScreen.parse_cands(null).is_empty() and SongSearchScreen.parse_cands("x").is_empty() and SongSearchScreen.parse_cands({}).is_empty() and SongSearchScreen.parse_cands({"cands": "x"}).is_empty(), "parse_cands: no / broken answer -> no candidates")
	var good: Array = SongSearchScreen.parse_cands({"ok": true, "cands": [{"title": "Aaa", "artist": "Bbb"}, {"title": "Ccc"}, {"title": "Ddd", "artist": ""}, {"title": "Eee", "artist": "F"}]})
	ok(good.size() == 3 and good[0]["title"] == "Aaa" and good[1]["artist"] == "" and good[2]["title"] == "Ddd", "parse_cands: at most 3, the first three kept in order, a missing artist is empty")
	var weird: Array = SongSearchScreen.parse_cands({"cands": [
		{"title": 123, "artist": "x"}, {"title": "", "artist": "x"}, {"title": "two\nlines", "artist": ""}, {"title": "tab\there", "artist": ""},
		{"title": "T".repeat(101), "artist": ""}, {"title": "ok", "artist": "A".repeat(81)}, "text", null, {"title": "Fine", "artist": "Fine Artist"},
		{"title": "  fine ", "artist": "FINE   artist"}]})
	ok(weird.size() == 1 and weird[0]["title"] == "Fine", "parse_cands: non-text values, empty / long / multi-line items and repeats (case / spaces ignored) are dropped (%d left)" % weird.size())
	# merge_items
	var a: Array = [{"id": 1, "trackName": "A", "artistName": "x"}, {"id": 2, "trackName": "B", "artistName": "x"}]
	var b: Array = [{"id": 2, "trackName": "B", "artistName": "x"}, {"id": 3, "trackName": "C", "artistName": "x"}]
	var m: Array = SongSearchScreen.merge_items([a, b])
	ok(_ids(m) == [1, 2, 3], "merge_items: the same lrclib id appears once, order kept (%s)" % [_ids(m)])
	var many: Array = []
	for i in 14:
		many.append({"id": 100 + i, "trackName": "T%d" % i, "artistName": "x"})
	ok(SongSearchScreen.merge_items([many]).size() == 10 and SongSearchScreen.merge_items([many, many]).size() == 10, "merge_items: at most 10")
	var noid: Array = SongSearchScreen.merge_items([[{"id": 0, "trackName": "Same", "artistName": "Me"}, {"id": 0, "trackName": " same ", "artistName": "ME"}, {"id": 0, "trackName": "Other", "artistName": "Me"}]])
	ok(noid.size() == 2, "merge_items: records without an id are told apart by title + artist")
	# language and preview
	ok(SongSearchScreen.guess_lang({"trackName": "Kettle Morning", "plainLyrics": "the kettle sings\nsmall boats"}) == "en", "guess_lang: English text -> en")
	ok(SongSearchScreen.guess_lang({"trackName": "やかんの朝", "plainLyrics": "あさのうた"}) == "ja", "guess_lang: kana -> ja")
	ok(SongSearchScreen.guess_lang({"trackName": "ア", "plainLyrics": ""}) == "en", "guess_lang: a single kana is not enough")
	var rec := {"id": 5, "trackName": "T", "artistName": "A", "plainLyrics": "line one\n\nline two\nline three\nline four\nline five\nline six", "syncedLyrics": "", "instrumental": false}
	var pv: Dictionary = SongSearchScreen.preview_of(rec)
	ok((pv["lines"] as Array).size() == 4 and pv["lines"][0] == "line one" and pv["lines"][1] == "line two" and int(pv["total"]) == 6, "preview_of: the first 4 lines with text, total 6 lines (%s)" % [pv])
	# the AI gate
	_disconnect_pc()
	ok(SongSearchScreen.ai_block_reason() == "no_pc", "ai gate: no PC -> no_pc")
	_connect_pc(false)
	ok(SongSearchScreen.ai_block_reason() == "old_pc", "ai gate: song_identify false -> old_pc")
	Backend.health = {"song": true, "song_v": 1}
	ok(SongSearchScreen.ai_block_reason() == "old_pc", "ai gate: no song_identify key (song_v 1 only) -> old_pc")
	_connect_pc("true")
	ok(SongSearchScreen.ai_block_reason() == "old_pc", "ai gate: song_identify as text 'true' (not a real boolean) -> old_pc")
	_connect_pc(true)
	ok(SongSearchScreen.ai_block_reason() == "", "ai gate: PC connected and song_identify true (song_v 1) -> allowed")
	Route.phone_hook = func() -> bool: return true
	Route.mode = "phone"
	ok(SongSearchScreen.ai_block_reason() == "no_pc", "ai gate: phone-only mode -> no_pc even when a PC answers")
	Route.mode = "auto"
	Route.phone_hook = Callable()
	ok(SongSearchScreen.ai_block_reason() == "", "ai gate: back to automatic mode -> allowed")
	_disconnect_pc()


## 소스 검사: AI 쪽으로 가사를 보내는 말이 없고, LRCLIB 은 search 만 쓴다.
func _test_source() -> void:
	print("[source: only search, nothing but the title goes to the AI]")
	var src: String = FileAccess.get_file_as_string(SRC)
	ok(src != "", "the screen source can be read")
	ok(_forbidden_hits(src).is_empty(), "the screen source has none of the forbidden words (%s)" % [_forbidden_hits(src)])
	ok(src.contains("LrclibClient") and src.contains(".search(") and not src.contains(".find("), "the screen only calls LrclibClient.search (no get)")
	ok(src.contains("Api.post_json(IDENTIFY_PATH, {\"q\": q, \"lang\": lang}"), "the only PC request is POST /song/identify with just q and lang")


func _test_title_search() -> void:
	print("[flow 1: a title alone -> candidates; one LRCLIB call per search]")
	_fresh()
	_toasts.clear()
	await _lr_reset()
	var s := _new_screen()
	ok(s.status == "" and s.items.is_empty() and _has(s, "QueryInput") and _has(s, "BtnSearch"), "a new screen shows the title box and [찾기], nothing searched yet")
	ok(_texts(s).contains("lrclib.net으로 전송돼요"), "the screen says the title is sent to lrclib.net when [찾기] is pressed")
	await _search(s, "k", false) # too short
	ok(s.status == "error" and _toast_has("두 글자 이상"), "one character: '두 글자 이상' notice, nothing sent")
	var l0: Array = await _lr_log()
	ok(l0.is_empty() and s.lr_calls == 0, "one character: no LRCLIB request")
	await _search(s, "Kettle Morning")
	ok(s.status == "found" and s.items.size() == 4, "'Kettle Morning': 4 candidates (%d, status %s)" % [s.items.size(), s.status])
	var log1: Array = await _lr_log()
	var srch1: Array = _reqs_with(log1, "/api/search")
	ok(log1.size() == 1 and srch1.size() == 1 and srch1[0]["query"].get("q", "") == "Kettle Morning", "exactly one LRCLIB request: /api/search?q=Kettle Morning (%d requests)" % log1.size())
	var cand_ids: Array = _ids(s.items)
	ok(_unique(cand_ids) and cand_ids.has(1001) and cand_ids.has(1006), "candidate ids are distinct and include the expected songs (%s)" % [cand_ids])
	var txt: String = _texts(s)
	ok(txt.contains("Kettle Morning - Test Artist") and txt.contains("Offset Artist"), "the list shows 제목 - 가수 for each candidate")
	ok(txt.contains("줄 시간 있음") and txt.contains(":"), "the list shows the length (m:ss) and '줄 시간 있음'")
	ok(_has(s, "Candidates") and (_find(s, "Candidates") as Control).find_children("Cand*", "Control", true, false).size() == 4, "4 candidate rows are drawn")
	# pressing again / the same words typed differently: no new request
	_toasts.clear()
	await _search(s, "Kettle Morning")
	await _search(s, "  kettle   MORNING ")
	var log2: Array = await _lr_log()
	ok(log2.size() == 1 and s.lr_calls == 1, "[찾기] pressed again and the same words with other spaces / case: still ONE LRCLIB request (%d)" % log2.size())
	ok(_toast_has("이미 찾아봤어요") and s.items.size() == 4, "the repeat shows '이미 찾아봤어요' and keeps the list")
	# another title is a new search
	await _search(s, "Plain Boat")
	var log3: Array = await _lr_log()
	ok(log3.size() == 2 and s.lr_calls == 1 and s.ai_calls == 0 and s.items.size() == 1 and int(s.items[0]["id"]) == 1003, "another title: one more request (2 in all), its own list (Plain Boat only)")
	# Enter in the box searches too
	await _lr_reset()
	var e: LineEdit = _find(s, "QueryInput")
	e.text = "Quiet Room"
	e.text_changed.emit("Quiet Room")
	e.text_submitted.emit("Quiet Room")
	await _until(func() -> bool: return not s.is_busy(), 20.0)
	var log4: Array = await _lr_log()
	ok(log4.size() == 1 and s.items.size() == 1, "pressing Enter in the box searches once")
	# a no-result search keeps nothing of the old one
	await _search(s, "Kettle Morning")
	await _lr_reset()
	await _search(s, "zzqq nothing")
	ok(s.items.is_empty() and s.chosen == -1 and s.status == "none" and _texts(s).contains("찾지 못했어요"), "a title with no result clears the old list and says '찾지 못했어요'")
	_drop(s)
	await _frames(2)


func _test_choose_and_save() -> void:
	print("[flow 2: choose a candidate -> preview -> save with source and lrclib id]")
	_fresh()
	await _lr_reset()
	var s := _new_screen()
	await _search(s, "Kettle Morning")
	ok(not _has(s, "BtnUse") and not _has(s, "ChosenCard"), "before choosing: no preview and no [이 가사로 외우기]")
	var i0: int = _ids(s.items).find(1001)
	ok(i0 >= 0 and s.choose(i0), "candidate 1001 (Kettle Morning / Test Artist) can be chosen")
	await _frames(2)
	ok(_has(s, "ChosenCard") and _has(s, "BtnUse"), "after choosing: the preview card and [이 가사로 외우기] are shown")
	var rec: Dictionary = s.items[i0]
	var first_line: String = str(rec["plainLyrics"]).split("\n")[0].strip_edges()
	var pl: Label = _find(s, "PreviewLines")
	ok(pl != null and first_line != "" and pl.text.contains(first_line), "the preview shows the first lyric line ('%s')" % first_line)
	ok(_find(s, "Attribution") != null and (_find(s, "Attribution") as Label).text.contains("LRCLIB"), "the preview shows where the lyrics come from (LRCLIB)")
	var shown: int = pl.text.split("\n").size() if pl != null else 0
	ok(shown <= SongSearchScreen.PREVIEW_LINES + 1, "the preview is only the first lines (%d shown)" % shown)
	ok((_find(s, "Cand%d" % i0) != null), "the chosen row is still in the list")
	var sent0: int = Api.sent_count
	_added.clear()
	ok(_press(s, "BtnUse"), "[이 가사로 외우기] can be pressed")
	await _frames(2)
	ok(_added.size() == 1 and SongModel.is_valid_id(str(_added[0])), "song_added(id) came once with a valid id (%s)" % [_added])
	var song: Dictionary = SongStore.load_song(str(_added[0]))
	ok(str(song.get("kind", "")) == "lyrics" and str(song.get("title", "")) == "Kettle Morning" and str(song.get("artist", "")) == "Test Artist", "saved as a lyrics-only song titled 'Kettle Morning' by 'Test Artist'")
	var src: Dictionary = song.get("source", {})
	ok(str(src.get("lyrics", "")) == "lrclib" and int(src.get("lrclib_id", 0)) == 1001 and str(src.get("timing", "")) == "none" and str(src.get("attribution", "")).contains("LRCLIB"), "source: lyrics 'lrclib', lrclib_id 1001, timing none, attribution (%s)" % [src])
	ok((song.get("lines", []) as Array).size() >= 3 and str(song["lang"]) == "en", "the lines are saved (%d) in English" % (song.get("lines", []) as Array).size())
	ok(Api.sent_count == sent0, "saving sent no PC request")
	# a second press does not save the song twice
	var n_before: int = SongStore.list().size()
	s.save()
	await _frames(1)
	ok(SongStore.list().size() == n_before and _added.size() == 1, "pressing save again does not add a second song")
	# a Japanese candidate is saved as 'ja'
	_drop(s)
	await _frames(2)
	var s2 := _new_screen("en")
	await _search(s2, "やかん")
	ok(s2.items.size() == 1 and s2.choose(0), "the Japanese song (やかんの朝) can be chosen")
	_added.clear()
	s2.save()
	await _frames(2)
	var ja: Dictionary = SongStore.load_song(str(_added[0])) if _added.size() == 1 else {}
	ok(str(ja.get("lang", "")) == "ja" and int(ja.get("source", {}).get("lrclib_id", 0)) == 2001, "a Japanese song is saved with lang 'ja' and its lrclib id")
	_drop(s2)
	await _frames(2)


func _test_unusable() -> void:
	print("[flow 2b: a candidate without lyrics cannot be chosen]")
	_fresh()
	await _lr_reset()
	var s := _new_screen()
	await _search(s, "Test Artist")
	var ids: Array = _ids(s.items)
	var inst: int = ids.find(1004)
	var plain: int = ids.find(1003)
	ok(inst >= 0 and plain >= 0, "the list has an instrumental (Quiet Room) and a plain-lyrics song (Plain Boat) (%s)" % [ids])
	ok(_texts(s).contains("연주곡 (가사 없음)") and _texts(s).contains("글자만 있음"), "the rows say '연주곡 (가사 없음)' and '글자만 있음'")
	ok(not s.choose(inst) and s.chosen == -1, "an instrumental cannot be chosen")
	await _frames(1)
	ok(not _has(s, "BtnUse") and not _has(s, "ChosenCard"), "after tapping an instrumental: still no preview, no save button")
	_added.clear()
	ok(s.save() != "" and _added.is_empty(), "save() with nothing chosen is refused with a message")
	# an empty, not-instrumental record (synthetic)
	s.items.append({"id": 9999, "name": "Empty One", "trackName": "Empty One", "artistName": "Nobody", "albumName": "", "duration": 30.0, "syncedLyrics": "", "plainLyrics": "", "instrumental": false})
	s._render()
	var ei: int = s.items.size() - 1
	ok(_texts(s).contains("가사 없음") and not s.choose(ei) and s.chosen == -1, "a record with empty lyrics shows '가사 없음' and cannot be chosen")
	ok(s.choose(plain) and s.chosen == plain, "a plain-lyrics candidate can be chosen")
	await _frames(1)
	_added.clear()
	s.save()
	await _frames(2)
	var song: Dictionary = SongStore.load_song(str(_added[0])) if _added.size() == 1 else {}
	ok(int(song.get("source", {}).get("lrclib_id", 0)) == 1003, "the plain-lyrics song was saved with lrclib_id 1003")
	_drop(s)
	await _frames(2)


func _test_ai_flow() -> void:
	print("[flow 3: 0 results -> [AI로 다시 찾기] -> consent first -> identify -> one search per candidate -> merged]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	_connect_pc(true)
	await _lr_reset()
	_fake.reset()
	var s := _new_screen()
	await _search(s, "케틀 모닝")
	ok(s.status == "none" and s.items.is_empty(), "'케틀 모닝' (a spelling LRCLIB does not know): 0 results")
	ok(_has(s, "BtnAi") and _has(s, "BtnPaste"), "0 results with a PC: [AI로 다시 찾기] and [가사 붙여넣기] are offered")
	var l1: Array = await _lr_log()
	ok(l1.size() == 1, "the plain search made one LRCLIB request")
	# --- no request before the consent
	ok(not Store.pref_bool("song_consent") and not Store.pref_bool("song_identify_consent"), "no consent given yet")
	ok(_press(s, "BtnAi"), "[AI로 다시 찾기] pressed")
	await _frames(3)
	ok(Sheet.is_open() and s.consent_sheet != null, "the first time: the notice / consent sheet comes up")
	ok(_texts(s.consent_sheet).contains(AI_NOTE), "the sheet says: 곡 제목이 AI로 전송돼요. 가사는 보내지 않아요.")
	await get_tree().create_timer(0.5).timeout
	ok(_fake.count() == 0 and s.ai_calls == 0, "before the consent: ZERO /song/identify requests (%d)" % _fake.count())
	s.consent_sheet.buttons["cancel"].pressed.emit()
	await get_tree().create_timer(0.4).timeout
	ok(not Sheet.is_open() and _fake.count() == 0 and s.ai_calls == 0 and not Store.pref_bool("song_identify_consent") and s.status == "none", "취소: nothing sent, nothing saved, the screen is as before")
	s.start_ai()
	await _frames(3)
	s.consent_sheet.close("dismiss")
	await get_tree().create_timer(0.4).timeout
	ok(_fake.count() == 0 and not Store.pref_bool("song_identify_consent"), "dismissed without agreeing: still zero requests, nothing saved")
	# --- agree
	s.start_ai()
	await _frames(3)
	s.consent_sheet.buttons["ok"].pressed.emit()
	ok(await _until(func() -> bool: return not s.is_busy() and s.ai_calls == 1, 20.0), "after agreeing the AI step ran and finished")
	await _frames(2)
	ok(Store.pref_bool("song_identify_consent") and not Store.pref_bool("song_consent"), "agreeing saves only the title-to-AI consent (song_consent, which covers lyrics going to the AI, stays off)")
	ok(_fake.count() == 1, "exactly one /song/identify request for this search (%d)" % _fake.count())
	var body: Dictionary = _fake.last_body()
	ok(body.keys().size() == 2 and body.get("q", "") == "케틀 모닝" and body.get("lang", "") == "en", "the request carries only q and lang: %s" % [body])
	ok(s.ai_cands.size() == 1 and s.ai_cands[0]["title"] == "Kettle Morning", "the AI named one candidate: Kettle Morning / Test Artist")
	var l2: Array = await _lr_log()
	var cand_searches: Array = _reqs_with(l2, "/api/search").slice(1)
	ok(l2.size() == 2 and cand_searches.size() == 1 and cand_searches[0]["query"].get("track_name", "") == "Kettle Morning" and cand_searches[0]["query"].get("artist_name", "") == "Test Artist" and not cand_searches[0]["query"].has("q"), "one LRCLIB search per candidate by title + artist (2 requests in all)")
	ok(s.status == "found" and _ids(s.items) == [1001, 1002, 1005], "the merged list: 1001, 1002, 1005 (%s)" % [_ids(s.items)])
	ok(not _has(s, "BtnAi"), "after the AI step the AI button is gone")
	# --- pressing again: one AI call per search
	_toasts.clear()
	s.start_ai()
	_press(s, "BtnAi")
	await get_tree().create_timer(0.4).timeout
	ok(_fake.count() == 1 and s.ai_calls == 1 and _toast_has("이미 AI로 찾아봤어요"), "pressing again: still ONE /song/identify, '이미 AI로 찾아봤어요'")
	await _search(s, "케틀 모닝")
	var l3: Array = await _lr_log()
	ok(l3.size() == 2 and _fake.count() == 1, "the same search again: no new LRCLIB request and no new AI call")
	# --- a chosen candidate from the AI step saves like any other
	var idx: int = _ids(s.items).find(1002)
	ok(s.choose(idx), "an AI-found candidate can be chosen")
	_added.clear()
	s.save()
	await _frames(2)
	var song: Dictionary = SongStore.load_song(str(_added[0])) if _added.size() == 1 else {}
	ok(int(song.get("source", {}).get("lrclib_id", 0)) == 1002 and str(song.get("source", {}).get("lyrics", "")) == "lrclib", "saved with source lrclib and lrclib_id 1002")
	# --- another title: the AI budget starts again (once per search), no new consent
	var s2 := _new_screen()
	await _lr_reset()
	_fake.reset()
	await _search(s2, "케틀 모닝 노래")
	ok(s2.status == "none" and _has(s2, "BtnAi"), "another title with 0 results: the AI button is there again")
	_press(s2, "BtnAi")
	await _frames(3)
	ok(not Sheet.is_open(), "the consent is remembered: no sheet the second time")
	ok(await _until(func() -> bool: return not s2.is_busy() and s2.ai_calls == 1, 20.0), "the second search's AI step ran")
	ok(_fake.count() == 1 and s2.items.size() == 3, "one more AI call (this search's only one) and a merged list of 3")
	# --- the broad song consent also counts
	_consent_clear()
	Store.set_pref("song_consent", true)
	var s3 := _new_screen()
	await _lr_reset()
	_fake.reset()
	await _search(s3, "케틀 모닝 또")
	_press(s3, "BtnAi")
	await _frames(3)
	ok(not Sheet.is_open() and await _until(func() -> bool: return not s3.is_busy() and s3.ai_calls == 1, 20.0) and _fake.count() == 1, "with song_consent already given: no extra sheet, the AI step runs")
	_drop(s)
	_drop(s2)
	_drop(s3)
	await _frames(2)
	_consent_clear()


func _test_ai_edges() -> void:
	print("[flow 3/4: duplicates merged, AI says nothing, AI down, malformed answers -> [가사 붙여넣기]]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	Store.set_pref("song_consent", true)
	_connect_pc(true)
	# --- two candidates that find the same songs: one id once
	await _lr_reset()
	_fake.reset()
	var s := _new_screen()
	await _search(s, "dup test")
	_press(s, "BtnAi")
	ok(await _until(func() -> bool: return not s.is_busy() and s.ai_calls == 1, 20.0), "dup: the AI step finished")
	await _frames(2)
	var log: Array = await _lr_log()
	var srch: Array = _reqs_with(log, "/api/search")
	ok(srch.size() == 3, "dup: 1 plain search + one search per candidate (2) = 3 LRCLIB requests (%d)" % srch.size())
	var ids: Array = _ids(s.items)
	ok(_unique(ids) and ids.size() == 4 and ids.has(1006), "dup: the two candidates' results (3 + 4 records) are merged into 4 distinct songs (%s)" % [ids])
	ok(_texts(s).contains("후보 4개"), "dup: the message counts 4 candidates")
	# --- the AI finds nothing -> not found -> paste
	await _lr_reset()
	_fake.reset()
	var s2 := _new_screen()
	await _search(s2, "nothing here")
	_press(s2, "BtnAi")
	ok(await _until(func() -> bool: return not s2.is_busy() and s2.ai_calls == 1, 20.0), "nothing: the AI step finished")
	await _frames(2)
	ok(s2.status == "none" and s2.items.is_empty() and _texts(s2).contains("찾지 못했어요") and not _has(s2, "BtnAi"), "AI found nothing: '찾지 못했어요', no AI button any more")
	var l: Array = await _lr_log()
	ok(l.size() == 1 and _fake.count() == 1, "nothing: no candidate searches (1 LRCLIB request in all), one AI call")
	_pastes.clear()
	ok(_press(s2, "BtnPaste"), "[가사 붙여넣기] is there")
	ok(_pastes.size() == 1 and _pastes[0][0] == "nothing here" and _pastes[0][1] == "", "paste_requested carries the typed title ('nothing here')")
	# --- the AI is down (503)
	await _lr_reset()
	_fake.reset()
	var s3 := _new_screen()
	await _search(s3, "down song")
	_press(s3, "BtnAi")
	ok(await _until(func() -> bool: return not s3.is_busy() and s3.ai_calls == 1, 20.0), "down: the AI step ended")
	await _frames(2)
	ok(s3.status == "error" and _texts(s3).contains("AI가 지금 대답하지 않아요") and _has(s3, "BtnPaste") and not _has(s3, "BtnAi"), "AI down (503): a message, [가사 붙여넣기] stays, no endless retry button")
	ok(_fake.count() == 1, "down: the request was not repeated (%d)" % _fake.count())
	# --- malformed answers
	await _lr_reset()
	_fake.reset()
	var s4 := _new_screen()
	await _search(s4, "weird one")
	_press(s4, "BtnAi")
	ok(await _until(func() -> bool: return not s4.is_busy() and s4.ai_calls == 1, 20.0), "weird: the AI step finished")
	await _frames(2)
	var wl: Array = await _lr_log()
	var wsr: Array = _reqs_with(wl, "/api/search").slice(1)
	var names: Array = []
	for r in wsr:
		names.append(str(r["query"].get("track_name", "")))
	ok(wsr.size() == 3 and names == ["Kettle Morning", "Plain Boat", "Quiet Room"], "weird: of 6 listed items only the 3 valid ones were searched (%s)" % [names])
	await _lr_reset()
	_fake.reset()
	var s5 := _new_screen()
	await _search(s5, "badjson x")
	_press(s5, "BtnAi")
	ok(await _until(func() -> bool: return not s5.is_busy() and s5.ai_calls == 1, 20.0), "badjson: the AI step finished")
	await _frames(2)
	ok((s5.status == "none" or s5.status == "error") and s5.items.is_empty() and _has(s5, "BtnPaste"), "an unreadable answer: nothing is shown as found, [가사 붙여넣기] stays (%s)" % s5.status)
	for x in [s, s2, s3, s4, s5]:
		_drop(x)
	await _frames(2)
	_consent_clear()


func _test_ai_gate() -> void:
	print("[the AI button only with a PC whose /health has song_identify true; no request without it]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	Store.set_pref("song_consent", true) # the consent is not what is tested here
	await _lr_reset()
	_fake.reset()
	var sent0: int = Api.sent_count
	# no song_identify flag
	_connect_pc(false)
	var s := _new_screen()
	await _search(s, "케틀 모닝")
	ok(s.status == "none" and not _has(s, "BtnAi") and _has(s, "BtnPaste"), "no song_identify: no AI button, [가사 붙여넣기] stays")
	ok(_has(s, "AiHint") and (_find(s, "AiHint") as Label).text.contains("최신으로 업데이트"), "no song_identify: the hint says to update the PC program")
	_toasts.clear()
	var sent1: int = Api.sent_count
	s.start_ai()
	await get_tree().create_timer(0.3).timeout
	ok(_fake.count() == 0 and Api.sent_count == sent1 and _toast_has("최신으로 업데이트"), "no song_identify: start_ai() sends nothing")
	_drop(s)
	# no PC
	_disconnect_pc()
	var s2 := _new_screen()
	await _search(s2, "케틀 모닝")
	var want: String = SongSearchScreen.MSG_NEED_PC if _phone else SongSearchScreen.MSG_NEED_PC_PC
	ok(not _has(s2, "BtnAi") and _has(s2, "AiHint") and (_find(s2, "AiHint") as Label).text == want and _has(s2, "BtnPaste"), "no PC: no AI button, hint '%s'" % want)
	_toasts.clear()
	var sent2: int = Api.sent_count
	s2.start_ai()
	await get_tree().create_timer(0.3).timeout
	ok(_fake.count() == 0 and Api.sent_count == sent2, "no PC: start_ai() sends nothing (Api.sent_count %d -> %d)" % [sent2, Api.sent_count])
	# phone-only mode with a PC that answers
	_connect_pc(true)
	Route.phone_hook = func() -> bool: return true
	Route.mode = "phone"
	var s3 := _new_screen()
	await _search(s3, "케틀 모닝")
	ok(not _has(s3, "BtnAi"), "phone-only mode: no AI button even though a PC is up")
	var sent3: int = Api.sent_count
	s3.start_ai()
	await get_tree().create_timer(0.3).timeout
	ok(_fake.count() == 0 and Api.sent_count == sent3, "phone-only mode: start_ai() sends nothing")
	Route.mode = "auto"
	Route.phone_hook = Callable()
	ok(_fake.count() == 0, "in this whole section the fake AI saw zero requests")
	for x in [s2, s3]:
		_drop(x)
	await _frames(2)
	_consent_clear()
	_disconnect_pc()
	ok(Api.sent_count >= sent0, "(gate section ended)")


## 허브: 맨 위 검색 카드 -> 검색 화면 -> 저장 -> SongMemoScreen. 붙여넣기는 제목이 채워진 SongLyricsAddScreen.
func _make_hub() -> SongView:
	var v := SongView.new()
	v.lrclib_base_url = LR_BASE
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(v)
	await _frames(2)
	v.refresh()
	await _until(func() -> bool: return v.state != "loading" and v.state != "idle" and not v.is_loading(), 15.0)
	await _frames(2)
	return v


func _hub_search(v: SongView, q: String) -> void:
	var e: LineEdit = v.search_input()
	e.text = q
	e.text_changed.emit(q)
	v.search_button().pressed.emit()
	await _until(func() -> bool: return v.screen_kind == "search", 5.0)
	await _frames(1)
	var s: Node = v.screen
	if s is SongSearchScreen:
		await _until(func() -> bool: return not (s as SongSearchScreen).is_busy(), 20.0)
	await _frames(2)


func _test_hub() -> void:
	print("[hub: search card -> search screen -> save -> memorize screen; paste mode keeps the title]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	_connect_pc(true)
	await _lr_reset()
	_fake.reset()
	var v: SongView = await _make_hub()
	ok(v.search_card() != null and v.search_input() != null and v.search_button() != null, "the hub has a search card (title box + [찾기])")
	ok(v.search_input().placeholder_text == "곡 제목 (가수도 적으면 더 정확해요)", "the box says '곡 제목 (가수도 적으면 더 정확해요)'")
	ok(v.add_button() != null and v.lyrics_button() != null, "[+ 곡 추가] and [가사만 추가] are still there")
	# too short
	var shown: Array = []
	v.search_requested.connect(func(q: String) -> void: shown.append(q))
	v.search_input().text = "a"
	v.search_button().pressed.emit()
	await _frames(2)
	ok(v.screen == null and shown.is_empty() and _toast_has("두 글자 이상"), "one character: no screen, no signal, a notice")
	# 1 → memo
	await _hub_search(v, "Kettle Morning")
	var s: SongSearchScreen = v.screen as SongSearchScreen
	ok(s != null and v.screen_kind == "search" and shown == ["Kettle Morning"] and s.status == "found" and s.items.size() == 4, "[찾기] opens the search screen and it already searched (4 candidates)")
	ok(v.page_title() == "가사 찾기", "the app bar shows the search screen's title")
	ok(s.choose(_ids(s.items).find(1001)), "choose 1001")
	await _frames(2)
	ok(_press(s, "BtnUse"), "[이 가사로 외우기]")
	ok(await _until(func() -> bool: return v.screen_kind == "memo", 8.0), "the hub opened the memorize screen (screen_kind memo)")
	ok(v.screen is SongMemoScreen, "it is a SongMemoScreen")
	await _frames(3)
	ok(v.search_input().text == "", "the search box is empty again after a song was saved")
	var lyr: Array = []
	for sg in SongStore.list():
		if str(sg.get("kind", "")) == "lyrics":
			lyr.append(sg)
	ok(lyr.size() == 1 and str(lyr[0]["title"]) == "Kettle Morning", "one lyrics-only song 'Kettle Morning' is in the store")
	v.go_back()
	await _frames(3)
	await _until(func() -> bool: return not v.is_loading(), 10.0)
	ok(v.screen == null and v.songs.size() == 1, "closing the memorize screen returns to the list with the new song")
	# 4 → paste mode with the title
	await _lr_reset()
	_fake.reset()
	Store.set_pref("song_consent", true)
	await _hub_search(v, "nothing here")
	var s2: SongSearchScreen = v.screen as SongSearchScreen
	ok(s2 != null and s2.status == "none" and _has(s2, "BtnAi"), "a title with no result: [AI로 다시 찾기] is offered")
	_press(s2, "BtnAi")
	ok(await _until(func() -> bool: return not s2.is_busy() and s2.ai_calls == 1, 20.0), "the AI step ran")
	await _frames(2)
	ok(s2.status == "none" and _texts(s2).contains("찾지 못했어요"), "AI found nothing: '찾지 못했어요'")
	_press(s2, "BtnPaste")
	ok(await _until(func() -> bool: return v.screen_kind == "lyrics_add", 5.0), "[가사 붙여넣기] opened the paste screen")
	await _frames(2)
	var la: SongLyricsAddScreen = v.screen as SongLyricsAddScreen
	ok(la != null and la.title_text == "nothing here" and la.source == "pasted", "the paste screen has the title filled in and the paste mode on")
	var te: LineEdit = _find(la, "TitleInput")
	ok(te != null and te.text == "nothing here", "its title box shows 'nothing here'")
	ok(_find(la, "PasteInput") != null, "its paste box is there")
	v.go_back()
	await _frames(3)
	ok(v.screen == null, "going back from the paste screen returns to the list")
	_drop(v)
	await _frames(3)
	_consent_clear()


## 폰 단독: PC 없이 검색 · 저장 · 외우기까지 되고 PC 로 가는 요청은 0건.
func _test_phone_only() -> void:
	print("[no PC: search, save and the memorize screen all work; Api.sent_count does not change]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	_disconnect_pc()
	await _lr_reset()
	_fake.reset()
	var sent0: int = Api.sent_count
	var v: SongView = await _make_hub()
	await _hub_search(v, "Kettle Morning")
	var s: SongSearchScreen = v.screen as SongSearchScreen
	ok(s != null and s.status == "found" and s.items.size() == 4, "no PC: the search still finds 4 candidates (LRCLIB is reached directly)")
	ok(not _has(s, "BtnAi") and _has(s, "AiHint"), "no PC: no AI button, a hint instead")
	ok(s.choose(_ids(s.items).find(1001)), "no PC: choose a candidate")
	await _frames(2)
	_press(s, "BtnUse")
	ok(await _until(func() -> bool: return v.screen_kind == "memo", 8.0) and v.screen is SongMemoScreen, "no PC: the memorize screen opens")
	await _frames(3)
	ok(Api.sent_count == sent0, "no PC: Api.sent_count did not change through search, save and memorize (%d -> %d)" % [sent0, Api.sent_count])
	ok(_fake.count() == 0, "no PC: the fake AI server saw nothing")
	v.go_back()
	await _frames(3)
	_drop(v)
	await _frames(3)


func _test_lifetime() -> void:
	print("[lifetime: late LRCLIB / AI answers are dropped; no leaked nodes; the list thread is joined]")
	_fresh()
	_toasts.clear()
	_consent_clear()
	Store.set_pref("song_consent", true)
	_connect_pc(true)
	# --- leaving through on_hide while LRCLIB is slow
	await _lr_reset()
	_fake.reset()
	var s := _new_screen()
	await _search(s, "__slow__ x", false)
	await get_tree().create_timer(0.3).timeout
	var cl: LrclibClient = s._client
	ok(cl != null and s.is_busy(), "a slow LRCLIB answer is on its way")
	s.on_hide()
	ok(not s.is_busy() and s._client == null and s.status == "" and s.message == "", "on_hide: the screen forgets the request at once (busy off, client dropped)")
	await get_tree().create_timer(2.2).timeout
	ok(not is_instance_valid(cl), "the abandoned client frees itself after its slow answer")
	ok(s.items.is_empty() and s.status == "" and s.message == "" and s.chosen == -1, "the late LRCLIB answer changed nothing on the screen")
	_drop(s)
	await _frames(2)
	# --- another title typed (a new search) while the first is slow: the first answer is dropped
	await _lr_reset()
	var s2 := _new_screen()
	await _search(s2, "__slow__ y", false)
	await get_tree().create_timer(0.3).timeout
	var gen_before: int = s2._gen
	s2.on_hide()
	ok(s2._gen > gen_before, "on_hide raises the request generation")
	_drop(s2)
	await get_tree().create_timer(2.0).timeout
	# --- freeing the screen while LRCLIB is in flight
	await _lr_reset()
	var s3 := _new_screen()
	await _search(s3, "__slow__ z", false)
	await get_tree().create_timer(0.3).timeout
	var c0: int = _closed
	s3.go_back()
	ok(_closed == c0 + 1, "go_back while searching: the screen closes at once")
	s3.queue_free()
	await get_tree().create_timer(2.2).timeout
	ok(true, "freeing the screen mid-search is quiet (no script error)")
	# --- late AI answer
	await _lr_reset()
	_fake.reset()
	var active0: int = Api.active_count
	var s4 := _new_screen()
	await _search(s4, "slow song")
	ok(s4.status == "none", "'slow song': 0 results")
	_press(s4, "BtnAi")
	await get_tree().create_timer(0.4).timeout
	ok(s4.is_busy() and s4.ai_calls == 1 and _fake.count() == 1, "the AI request is in flight (the fake answers after 1.5 s)")
	s4.on_hide()
	ok(not s4.is_busy() and s4.status == "" and s4._ai_call == null, "on_hide: the AI request is let go at once")
	await get_tree().create_timer(2.4).timeout
	var l4: Array = await _lr_log()
	ok(s4.items.is_empty() and s4.status == "" and s4.ai_cands.is_empty(), "the late AI answer changed nothing on the screen")
	ok(_reqs_with(l4, "/api/search").size() == 1, "the late AI answer started no candidate searches (1 LRCLIB request in all)")
	ok(Api.orphan_count == 0 and Api.active_count <= active0, "the dropped AI request left no orphan or extra active request (orphan %d, active %d -> %d)" % [Api.orphan_count, active0, Api.active_count])
	_drop(s4)
	await _frames(2)
	# --- AI answer arrived, candidate searches in flight, then the screen is left
	await _lr_reset()
	_fake.reset()
	var s5 := _new_screen()
	await _search(s5, "slowcand now")
	_press(s5, "BtnAi")
	await get_tree().create_timer(0.8).timeout # the AI answered; the slow candidate search (1.5 s) is running
	ok(s5.is_busy() and s5.ai_calls == 1 and not s5.ai_cands.is_empty(), "the AI answered and the candidate search is in flight")
	var items_before: Array = s5.items.duplicate()
	s5.on_hide()
	await get_tree().create_timer(2.4).timeout
	ok(s5.items == items_before and s5.status == "" and not s5.is_busy(), "the late candidate answer was dropped (list and status unchanged)")
	_drop(s5)
	await _frames(2)
	# --- the consent sheet is closed when the screen is left
	_consent_clear()
	var s6 := _new_screen()
	await _search(s6, "케틀 모닝")
	s6.start_ai()
	await _frames(3)
	ok(Sheet.is_open(), "the consent sheet is open")
	s6.on_hide()
	await _frames(2)
	ok(not Sheet.is_open(), "on_hide closes the consent sheet")
	var n0: int = _fake.count()
	await get_tree().create_timer(0.3).timeout
	ok(_fake.count() == n0 and s6.ai_calls == 0, "a sheet closed by leaving sends nothing")
	_drop(s6)
	await _frames(2)
	_consent_clear()
	Store.set_pref("song_consent", true)
	# --- no leaked nodes and threads: open / search / leave a few times and compare the node count
	await _lr_reset()
	_fake.reset()
	var http0: int = _count_class("HTTPRequest")
	var v: SongView = await _make_hub()
	await _frames(3)
	var nodes0: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for i in 3:
		await _hub_search(v, "Kettle Morning" if i != 1 else "nothing here")
		ok(v.screen is SongSearchScreen, "round %d: the search screen is open" % (i + 1))
		var sc: SongSearchScreen = v.screen as SongSearchScreen
		if i == 2:
			sc.choose(0)
			await _frames(2)
		v.go_back()
		await _frames(3)
		await _until(func() -> bool: return not v.is_loading(), 10.0)
		await _frames(3)
		ok(v.screen == null, "round %d: the screen is gone after going back" % (i + 1))
	await get_tree().create_timer(1.0).timeout # abandoned LRCLIB clients free themselves
	await _frames(3)
	ok(_count_class("LrclibClient") == 0 and _count_class("SongSearchScreen") == 0, "no LrclibClient or SongSearchScreen node is left in the tree")
	var nodes1: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	ok(nodes1 == nodes0, "node count unchanged after 3 open / search / leave rounds (%d -> %d)" % [nodes0, nodes1])
	ok(_count_class("HTTPRequest") <= http0, "no extra HTTPRequest node is left over (%d -> %d)" % [http0, _count_class("HTTPRequest")])
	ok(v._thread == null and not v.is_loading(), "the hub's list thread is joined")
	# the hub freed while the search screen is open and busy
	await _lr_reset()
	await _hub_search(v, "__slow__ q")
	ok(v.screen is SongSearchScreen, "a slow search is open in the hub")
	var thread_before: bool = v._thread == null
	v.queue_free()
	await get_tree().create_timer(2.0).timeout
	ok(thread_before and not is_instance_valid(v) and _count_class("SongSearchScreen") == 0, "freeing the hub with a busy search screen is quiet and leaves no screen")
	await _frames(2)
	_consent_clear()


func _test_layout() -> void:
	print("[layout: the search card is on the first screen; nothing sticks out; touch targets]")
	_fresh()
	_consent_clear()
	_connect_pc(true)
	await _lr_reset()
	_fake.reset()
	var v: SongView = await _make_hub()
	await _frames(3)
	var card: Control = v.search_card()
	var win: Rect2 = Rect2(Vector2.ZERO, Vector2(get_window().size))
	var r: Rect2 = card.get_global_rect()
	ok(card.is_visible_in_tree() and r.position.y >= 0.0 and r.end.y <= win.end.y and r.position.x >= 0.0 and r.end.x <= win.end.x + 0.5, "the search card sits fully inside the first screen %s (card %s)" % [win.size, r])
	var btn_r: Rect2 = v.search_button().get_global_rect()
	ok(btn_r.size.y >= Ds.touch_min() - 0.5 and btn_r.size.x >= Ds.touch_min() - 0.5 and win.encloses(btn_r), "[찾기] is a full-size touch target inside the screen (%s)" % [btn_r.size])
	var by_top: bool = true
	if _phone:
		var header: Control = v.header_block()
		var hdr_rect: Rect2 = header.get_global_rect() if header != null else Rect2()
		by_top = r.position.y >= hdr_rect.end.y - 0.5 and r.end.y < v.add_button().get_global_rect().position.y
	ok(by_top, "the card is below the title and above [+ 곡 추가] (phone) / in the page (PC)")
	ok(_overflow(v).is_empty(), "the hub has nothing sticking out sideways (%s)" % [_overflow(v)])
	ok(_small_touch(v).is_empty(), "the hub's buttons and boxes are touch sized (%s)" % [_small_touch(v)])
	await _hub_search(v, "Test Artist")
	var s: SongSearchScreen = v.screen as SongSearchScreen
	ok(s != null and s.items.size() >= 4, "the search screen shows many candidates")
	s.choose(_ids(s.items).find(1001))
	await _frames(3)
	ok(_overflow(s).is_empty(), "the search screen has nothing sticking out sideways (%s)" % [_overflow(s)])
	ok(_small_touch(s).is_empty(), "the search screen's buttons and boxes are touch sized (%s)" % [_small_touch(s)])
	var use_btn: Button = _find(s, "BtnUse")
	ok(use_btn != null and win.encloses(use_btn.get_global_rect()), "[이 가사로 외우기] is pinned inside the screen")
	_drop(v)
	await _frames(3)
	_disconnect_pc()


func _test_real_folder_untouched() -> void:
	var sl: Array = _listing("user://songs")
	ok(JSON.stringify(sl) == JSON.stringify(_before.get("songs", [])), "the real user://songs folder is exactly as before")


# ================================================================ GDScript fake of POST /song/identify

class FakeIdentify:
	extends Node
	var srv: TCPServer = null
	var log: Array = [] ## {m, path, body}
	var conns: Array = []

	func setup(p: int) -> bool:
		srv = TCPServer.new()
		if srv.listen(p, "127.0.0.1") != OK:
			srv = null
			return false
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

	func count() -> int:
		var n: int = 0
		for e in log:
			if e["m"] == "POST" and e["path"] == "/song/identify":
				n += 1
		return n

	func last_body() -> Dictionary:
		for i in range(log.size() - 1, -1, -1):
			if log[i]["path"] == "/song/identify":
				return log[i]["body"]
		return {}

	func _process(_d: float) -> void:
		if srv != null and srv.is_listening():
			while srv.is_connection_available():
				var peer: StreamPeerTCP = srv.take_connection()
				conns.append(peer)
				_serve(peer)

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
		var path: String = first[1].split("?")[0]
		var body: Dictionary = {}
		if body_bytes.size() > 0:
			var parsed: Variant = JSON.parse_string(body_bytes.get_string_from_utf8())
			if parsed is Dictionary:
				body = parsed
		log.append({"m": m, "path": path, "body": body})
		var code: int = 404
		var payload: String = JSON.stringify({"error": "not_found"})
		if m == "POST" and path == "/song/identify":
			var q: String = str(body.get("q", ""))
			code = 200
			var cands: Array = [{"title": "Kettle Morning", "artist": "Test Artist"}]
			if q.contains("nothing"):
				cands = []
			elif q.contains("dup"):
				cands = [{"title": "Kettle Morning", "artist": "Test Artist"}, {"title": "Kettle Morning", "artist": ""}]
			elif q.contains("weird"):
				cands = [{"title": "Kettle Morning", "artist": "Test Artist"}, {"title": 123, "artist": "x"}, {"title": "bad\nline", "artist": ""},
					{"title": "kettle morning", "artist": "TEST  artist"}, {"title": "Plain Boat", "artist": "Test Artist"}, {"title": "Quiet Room", "artist": "Test Artist"}]
			elif q.contains("slowcand"):
				cands = [{"title": "Kettle __slow__", "artist": "Test Artist"}]
			if q.contains("slow") and not q.contains("slowcand"):
				await get_tree().create_timer(1.5).timeout
			payload = JSON.stringify({"ok": true, "cands": cands})
			if q.contains("down"):
				code = 503
				payload = JSON.stringify({"error": "ai_unavailable", "code": "ai_unavailable"})
			elif q.contains("badjson"):
				payload = "this is not json {"
		var data: PackedByteArray = payload.to_utf8_buffer()
		var hd := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, data.size()]
		peer.put_data(hd.to_utf8_buffer())
		peer.put_data(data)
		await get_tree().process_frame
		peer.disconnect_from_host()
