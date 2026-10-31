extends Node
## 노래 공부 U1: SongView (곡 목록 화면) + main.gd 탭 등록. 서버·마이크를 쓰지 않는다.
##   PC:   godot --headless --path <project> res://tests/song_view_test.tscn
##   폰:   godot --headless --path <project> res://tests/song_view_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5
## 마지막 줄: "== song_view_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 곡은 user://test_songs_u1 에만 만든다 (SongStore.root 를 바꿔서). 설정·진행·학습 기록 파일도 user://test_u1/ 로 돌린다.
## 시험 전후로 실제 user://songs 와 앱 파일(prefs / progress / studylog / ...)이 그대로인지 목록을 비교한다.
## 오디오는 가짜 바이트이고 곡 제목·가사는 직접 지은 것이다.

const ROOT := "user://test_songs_u1"
const DIR := "user://test_u1"
const MARK := "ZZSONGLINEZZ"

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
var _sent0: int = 0


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


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _audio(n: int, salt: int = 0) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = (i * 31 + 7 + salt) & 255
	return b


func _song(title: String, artist: String, lang: String = "en", last: int = 0, nlines: int = 2) -> Dictionary:
	var lines: Array = []
	for i in nlines:
		lines.append({"i": i, "p": 0, "t0": 1.0 + i * 3.0, "t1": 3.0 + i * 3.0, "text": "A made up line %d %s" % [i, MARK], "words": []})
	return {"v": 1, "lang": lang, "title": title, "artist": artist, "created": 1790000000, "duration": 231.4,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "x.m4a"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": last, "best": {}}, "warnings": []}


func _install(title: String, artist: String = "Tester", lang: String = "en", last: int = 0, n: int = 1500, nlines: int = 2) -> String:
	var r: Dictionary = SongStore.install(_song(title, artist, lang, last, nlines), _audio(n, title.length()))
	return str(r["id"]) if bool(r["ok"]) else ""


func _is_link(path: String) -> bool:
	var d := DirAccess.open(_g(path).get_base_dir())
	return d != null and d.is_link(_g(path))


func _rm_rf(path: String) -> void:
	if _is_link(path):
		DirAccess.remove_absolute(_g(path))
		return
	var d := DirAccess.open(_g(path))
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(_g(path).path_join(fn))
	DirAccess.remove_absolute(_g(path))


func _write(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _dirs(path: String) -> Array:
	var d := DirAccess.open(_g(path))
	if d == null:
		return []
	var out: Array = Array(d.get_directories())
	out.sort()
	return out


func _files(path: String) -> Array:
	var d := DirAccess.open(_g(path))
	if d == null:
		return []
	var out: Array = Array(d.get_files())
	out.sort()
	return out


## The user's real files this test must not touch (see song_store_test).
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
	out["songs_dirs"] = _dirs("user://songs")
	out["songs_files"] = _files("user://songs")
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


func _close_sheets() -> void:
	while Sheet.is_open():
		Sheet.close_top()


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


func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _make_view() -> SongView:
	var v := SongView.new()
	v.host_screens = false # U5 wiring: this test is about the list and its signals; the hub opens real screens in song_flow_test
	_stage(v)
	return v


func _wait_loaded(v: SongView, max_frames: int = 120) -> void:
	for i in max_frames:
		await get_tree().process_frame
		if v.state != "loading" and v.state != "idle" and not v.is_loading():
			break
	await _frames(2)


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


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== song_view_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	_before = _user_listing()
	_sent0 = Api.sent_count
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.prefs.erase("song_consent")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: the PC run must never reach the user's engine (8770)
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

	_test_formats()
	await _test_empty_and_loading()
	await _test_list()
	await _test_tap_and_delete()
	await _test_broken_songs()
	ok(Api.sent_count == _sent0, "listing, opening, deleting and cleaning up sent no request to any server (Api.sent_count %d -> %d)" % [_sent0, Api.sent_count])
	await _test_add_gate()
	await _test_layout()
	await _test_load_edges()
	await _test_real_folder_untouched()
	await _test_main_wiring()

	_close_sheets()
	_fresh()
	SongStore.root = old_root
	Store.prefs.erase("song_consent")
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Backend.health = _old_health
	Backend.status = _old_status
	_rm_rf(DIR)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "test folders cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_view_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- sections

func _test_formats() -> void:
	print("[formats]")
	ok(SongView.clip("short", 60) == "short", "clip: a short text is unchanged")
	var long_t: String = "A".repeat(500)
	var c: String = SongView.clip(long_t, 60)
	ok(c.length() == 60 and c.ends_with("…"), "clip: a 500 character title -> 60 characters ending in an ellipsis (%d)" % c.length())
	var huge: String = "あ".repeat(2000000)
	var t0: int = Time.get_ticks_msec()
	var ch: String = SongView.clip(huge, 60)
	ok(ch.length() == 60 and Time.get_ticks_msec() - t0 < 500, "clip: a 2 million character title is cut quickly (%d ms)" % (Time.get_ticks_msec() - t0))
	ok(SongView.clip("a\nb\tc", 20) == "a b c", "clip: line breaks and tabs become spaces")
	ok(SongView.clip("   ", 20) == "", "clip: blank -> empty")
	ok(SongView.fmt_dur(231.4) == "3:51" and SongView.fmt_dur(-5.0) == "0:00" and SongView.fmt_dur(59.6) == "1:00" and SongView.fmt_dur(NAN) == "0:00", "fmt_dur: 231.4 -> 3:51, negative / NaN -> 0:00")
	ok(SongView.fmt_bytes(0) == "0 KB" and SongView.fmt_bytes(1500) == "2 KB" and SongView.fmt_bytes(3800000) == "3.6 MB" and SongView.fmt_bytes(12 * 1048576) == "12 MB" and SongView.fmt_bytes(400 * 1048576) == "400 MB", "fmt_bytes: KB / one decimal below 10 MB / whole MB")
	ok(SongView.usage_text({"songs": 3, "bytes": 12 * 1048576, "max_songs": 40, "max_bytes": 400 * 1048576}) == "곡 3개 · 12 MB / 400 MB", "usage_text: '곡 3개 · 12 MB / 400 MB'")
	var ct: String = SongView.consent_text()
	ok(ct.contains("lrclib.net") and ct.contains("AI 서비스") and ct.contains("다른 곳에 올리거나 공유할 수 없어요"), "consent text (L9): lrclib.net, AI 서비스, no sharing")


func _test_empty_and_loading() -> void:
	print("[empty state and a list that is read while the screen keeps running]")
	_fresh()
	_toasts.clear()
	_disconnect_pc()
	var v := _make_view()
	await _frames(2)
	ok(v.state == "idle" and v.load_count == 0, "a new view does not read the songs folder before it is shown")
	v.refresh()
	await _wait_loaded(v)
	ok(v.state == "ready" and v.songs.is_empty() and v.load_count == 1, "empty folder: ready, 0 songs")
	var txt: String = _texts(v)
	ok(txt.contains("아직 곡이 없어요") and txt.contains("이 기기에만 저장돼요"), "empty state: '아직 곡이 없어요' and where songs are kept")
	ok(v.usage_label() != null and v.usage_label().text == "곡 0개 · 0 KB / 400 MB", "usage: '곡 0개 · 0 KB / 400 MB' (%s)" % [v.usage_label().text if v.usage_label() != null else "-"])
	v.queue_free()
	await _frames(2)

	# a slow list (the first SongStore.list() hashes up to 400 MiB): the screen shows "불러오는 중" and keeps drawing frames
	var v2 := _make_view()
	v2.loader = func() -> Dictionary:
		OS.delay_msec(450)
		return {"list": [], "orphans": [], "usage": {"songs": 0, "bytes": 0, "max_songs": 40, "max_bytes": 400 * 1048576}, "quarantined": []}
	await _frames(2)
	v2.refresh()
	await _frames(1)
	ok(v2.state == "loading" and v2.is_loading() and _texts(v2).contains("곡을 불러오는 중"), "slow list: '곡을 불러오는 중…' is shown while the list is read")
	var n_frames: int = 0
	var worst: int = 0
	var last: int = Time.get_ticks_msec()
	while v2.is_loading() and n_frames < 400:
		await get_tree().process_frame
		var now: int = Time.get_ticks_msec()
		worst = maxi(worst, now - last)
		last = now
		n_frames += 1
	ok(n_frames >= 5 and worst < 250, "slow list (thread): the main thread kept running (%d frames, longest gap %d ms)" % [n_frames, worst])
	await _frames(2)
	ok(v2.state == "ready", "slow list: ready afterwards")
	# no thread available: the screen is drawn first, the list is read two frames later
	var v3 := _make_view()
	v3.use_thread = false
	await _frames(2)
	v3.refresh()
	ok(v3.state == "loading" and v3.load_count == 0, "no thread: refresh() itself does not read the list")
	await _wait_loaded(v3)
	ok(v3.state == "ready" and v3.load_count == 1, "no thread: the list is read a couple of frames later")
	# refresh while loading is remembered and read once more afterwards
	v2.loader = func() -> Dictionary:
		OS.delay_msec(200)
		return {"list": [], "orphans": [], "usage": {"songs": 0, "bytes": 0, "max_songs": 40, "max_bytes": 400 * 1048576}, "quarantined": []}
	var c0: int = v2.load_count
	v2.refresh()
	await _frames(1)
	v2.refresh()
	await _wait_loaded(v2)
	await _frames(30)
	await _wait_loaded(v2)
	ok(v2.load_count == c0 + 2 and v2.state == "ready", "a refresh while loading reads the list once more (%d -> %d)" % [c0, v2.load_count])
	v2.queue_free()
	v3.queue_free()
	await _frames(2)


func _test_list() -> void:
	print("[song list]")
	_fresh()
	_toasts.clear()
	_disconnect_pc()
	var a: String = _install("Blue Morning", "The Testers", "en", 1790000100)
	var b: String = _install("月あかりの歌", "テスト太郎", "ja", 1790000300, 2500, 5)
	var c: String = _install("Zeta Song", "", "en", 1790000200)
	ok(a != "" and b != "" and c != "", "fixtures installed")
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.songs.size() == 3 and v.songs[0]["id"] == b and v.songs[1]["id"] == c and v.songs[2]["id"] == a, "list order: most recently used first")
	ok(v.row_for(a) != null and v.row_for(b) != null and v.row_for(c) != null, "one row per song")
	var tx: String = _texts(v)
	ok(tx.contains("Blue Morning") and tx.contains("The Testers") and tx.contains("월") == false and tx.contains("月あかりの歌"), "rows show title and artist")
	ok(tx.contains("영어") and tx.contains("일본어") and tx.contains("3:51") and tx.contains("5줄"), "rows show language, length and line count")
	var u: Dictionary = SongStore.usage()
	ok(v.usage_label().text == SongView.usage_text(u) and v.usage_label().text.begins_with("곡 3개 · "), "usage line matches SongStore.usage() (%s)" % v.usage_label().text)
	ok(tx.contains("이 기기에만 저장돼요"), "where the songs are kept is stated")
	# long titles / artists (LRCLIB strings have no length limit)
	var long_id: String = _install("T".repeat(900) + " end", "Artist ".repeat(200), "en", 1790000400)
	v.refresh()
	await _wait_loaded(v)
	var row: Control = v.row_for(long_id)
	ok(row != null, "a song with a 900 character title is listed")
	var main_lbl: Label = null
	var sub_lbl: Label = null
	if row != null:
		for l in row.find_children("*", "Label", true, false):
			if (l as Label).theme_type_variation == &"ListMain":
				main_lbl = l
			elif (l as Label).theme_type_variation == &"ListSub":
				sub_lbl = l
	ok(main_lbl != null and main_lbl.text.length() <= SongView.TITLE_MAX and main_lbl.text.ends_with("…") and main_lbl.max_lines_visible == 2, "long title: cut with an ellipsis, at most two lines (%d chars)" % [main_lbl.text.length() if main_lbl != null else -1])
	ok(sub_lbl != null and sub_lbl.max_lines_visible == 1 and sub_lbl.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS and sub_lbl.text.length() < 120, "long artist: the sub line is one line with an ellipsis (%d chars)" % [sub_lbl.text.length() if sub_lbl != null else -1])
	ok(row != null and row.get_global_rect().size.y < 130.0, "the long song's row is not tall (%.0f px)" % [row.get_global_rect().size.y if row != null else -1.0])
	v.queue_free()
	await _frames(2)


func _test_tap_and_delete() -> void:
	print("[open and delete]")
	_fresh()
	_toasts.clear()
	_close_sheets()
	var a: String = _install("Alpha Song", "Tester", "en", 1790000100)
	var b: String = _install("Bravo Song", "Tester", "en", 1790000200)
	var gone: String = _install("Gone Audio", "Tester", "en", 1790000300)
	DirAccess.remove_absolute(_g(SongStore.audio_path(gone))) # the audio file was deleted behind the app's back
	SongStore.clear_cache()
	var v := _make_view()
	var opened: Array = []
	var sig_ok := true
	v.song_open_requested.connect(func(id: String) -> void: opened.append(id))
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.songs.size() == 3 and bool(v.songs[0]["ready"]) == false and v.songs[0]["id"] == gone, "the song without audio is listed as not ready")
	ok(_texts(v.row_for(gone)).contains("오디오 없음"), "its row says 오디오 없음")
	# tap
	v._on_song_tap(a, true)
	ok(opened == [a], "tapping a song asks to open it (song_open_requested(id))")
	v._on_song_tap(gone, false)
	ok(opened == [a] and _toast_has("오디오 파일이 없어요"), "a song without audio does not open and says why")
	# a real tap on the row of the ready song (the row is pressable)
	var row: Control = v.row_for(b)
	for pressed in [true, false]: # a click: PC acts on the press, the phone on the lift (within the tap slop)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = row.size * 0.5
		ev.global_position = row.get_global_rect().get_center()
		row.gui_input.emit(ev)
	ok(opened == [a, b], "a click / tap on the row opens the song")
	var v_no_listener := SongView.new()
	v_no_listener.host_screens = false # U5 wiring: without hosting and without a listener the old short notice is what happens
	_stage(v_no_listener)
	_toasts.clear()
	v_no_listener._on_song_tap(a, true)
	ok(_toast_has("준비 중"), "no learning screen connected yet: a short notice instead of nothing")
	v_no_listener.queue_free()
	# delete: confirm sheet
	var before_n: int = SongStore.list().size()
	ok(v.delete_button(a) != null, "each row has a delete button")
	v.delete_button(a).pressed.emit()
	await _frames(3)
	ok(Sheet.is_open() and v.last_sheet != null and _texts(v.last_sheet).contains("Alpha Song") and _texts(v.last_sheet).contains("되돌릴 수 없어요"), "delete: a confirm sheet names the song and says it cannot be undone")
	v.last_sheet.buttons["cancel"].pressed.emit()
	await _frames(3)
	ok(DirAccess.dir_exists_absolute(_g(SongStore.song_dir(a))) and SongStore.list().size() == before_n, "cancel: the song is still there")
	v.delete_button(a).pressed.emit()
	await _frames(3)
	v.last_sheet.close("dismiss")
	await _frames(3)
	ok(DirAccess.dir_exists_absolute(_g(SongStore.song_dir(a))), "dismissing the sheet (tap outside / back) deletes nothing")
	_toasts.clear()
	v.delete_button(a).pressed.emit()
	await _frames(3)
	var sh: Sheet = v.last_sheet
	sh.buttons["ok"].pressed.emit()
	await _frames(2)
	ok(not DirAccess.dir_exists_absolute(_g(SongStore.song_dir(a))), "confirm: the song's folder is gone from the disk")
	await _wait_loaded(v)
	ok(v.songs.size() == before_n - 1 and v.row_for(a) == null and _toast_has("곡을 지웠어요"), "the list reloads without it and a toast says so")
	ok(v.usage_label().text.begins_with("곡 %d개" % (before_n - 1)), "usage follows (%s)" % v.usage_label().text)
	ok(DirAccess.dir_exists_absolute(_g(SongStore.song_dir(b))), "the other songs are untouched")
	# the delete failing is reported, not silent
	_toasts.clear()
	v.delete_now("../../x")
	ok(not _toast_has("곡을 지웠어요") and DirAccess.dir_exists_absolute(_g(ROOT)), "a path-like id deletes nothing")
	_close_sheets()
	v.queue_free()
	await _frames(2)


func _test_broken_songs() -> void:
	print("[broken songs]")
	_fresh()
	_toasts.clear()
	_close_sheets()
	var good: String = _install("Good Song", "Tester", "en", 1790000100)
	var bad: String = _install("Bad Song", "Tester", "en", 1790000200)
	var f := FileAccess.open(SongStore.song_dir(bad).path_join("song.json"), FileAccess.READ)
	var whole: String = f.get_as_text()
	f.close()
	_write(SongStore.song_dir(bad).path_join("song.json"), whole.substr(0, whole.length() / 2)) # cut in the middle
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.songs.size() == 1 and v.songs[0]["id"] == good, "a song with a cut song.json is left out of the list; the other one is fine")
	ok(_toast_has("깨져"), "a toast tells that a song file was broken")
	ok(SongStore.take_quarantined().is_empty(), "the quarantine list was taken (not announced twice)")
	ok(v.orphans == [bad] and v.cleanup_button() != null and _texts(v).contains("복구할 수 없는 곡 1개"), "'복구할 수 없는 곡 1개' with a 정리 button")
	ok(v.usage_label().text.begins_with("곡 1개"), "usage counts the one song that works (%s)" % v.usage_label().text)
	v.cleanup_button().pressed.emit()
	await _frames(3)
	ok(Sheet.is_open() and v.last_sheet != null and _texts(v.last_sheet).contains("되돌릴 수 없어요"), "cleanup asks first")
	v.last_sheet.buttons["cancel"].pressed.emit()
	await _frames(3)
	ok(DirAccess.dir_exists_absolute(_g(SongStore.song_dir(bad))), "cancel: nothing is cleaned")
	v.cleanup_button().pressed.emit()
	await _frames(3)
	_toasts.clear()
	v.last_sheet.buttons["ok"].pressed.emit()
	await _frames(2)
	await _wait_loaded(v)
	ok(not DirAccess.dir_exists_absolute(_g(SongStore.song_dir(bad))) and DirAccess.dir_exists_absolute(_g(SongStore.song_dir(good))), "cleanup removes the broken song's folder only")
	ok(v.orphans.is_empty() and v.cleanup_button() == null and _toast_has("정리했어요"), "afterwards no cleanup row, a toast says it is done")
	v.queue_free()
	await _frames(2)


func _test_add_gate() -> void:
	print("[adding a song: PC link and consent]")
	_fresh()
	_toasts.clear()
	_close_sheets()
	Store.prefs.erase("song_consent")
	_install("Gate Song", "Tester", "en", 1790000100)
	var v := _make_view()
	var added: Array = [0]
	var opened: Array = []
	v.add_requested.connect(func() -> void: added[0] += 1)
	v.song_open_requested.connect(func(id: String) -> void: opened.append(id))
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	var sent: int = Api.sent_count
	# no PC
	_disconnect_pc()
	await _frames(2)
	ok(v.add_block_reason() == "no_pc" and v.notice_label() != null and v.notice_label().text.contains("곡 추가는 PC 연결 시"), "no PC: the notice says '곡 추가는 PC 연결 시 ...'")
	ok(v.notice_label().text.contains("저장된 곡은 지금도 공부할 수 있어요"), "the notice says stored songs can still be studied")
	_toasts.clear()
	v.add_button().pressed.emit()
	await _frames(2)
	ok(added[0] == 0 and not Sheet.is_open() and _toast_has("곡 추가는 PC 연결 시"), "no PC: [+ 곡 추가] shows the notice, no add screen, no consent sheet")
	ok(Api.sent_count == sent, "no PC: no request was sent (Api.sent_count unchanged)")
	v._on_song_tap(str(v.songs[0]["id"]), true)
	ok(opened.size() == 1, "no PC: a stored song can still be opened")
	# PC without the song feature
	_connect_pc(false)
	await _frames(2)
	ok(v.add_block_reason() == "old_pc" and v.notice_label().text.contains("최신으로 업데이트"), "old PC program: 'PC 프로그램을 최신으로 업데이트해 주세요'")
	v.request_add()
	await _frames(2)
	ok(added[0] == 0 and not Sheet.is_open(), "old PC program: no add screen")
	# the notice follows the connection without a refresh
	_connect_pc(true)
	await _frames(2)
	ok(v.add_block_reason() == "" and v.notice_label() == null, "PC connected with the song feature: no notice (it followed Backend.status_changed)")
	# phone-only mode: the route says none even when a PC answers
	Route.phone_hook = func() -> bool: return true
	var old_mode: String = Route.mode
	Route.mode = "phone"
	ok(v.add_block_reason() == "no_pc", "phone-only mode: songs cannot be added even if a PC is up")
	Route.mode = old_mode
	Route.phone_hook = Callable()
	ok(v.add_block_reason() == "", "back to automatic mode: allowed again")
	# consent sheet
	await _frames(5) # (the recorder asks the engine for microphones when it connects: not ours)
	var sent2: int = Api.sent_count
	ok(not Store.pref_bool("song_consent"), "song_consent starts false")
	v.add_button().pressed.emit()
	await _frames(3)
	ok(Sheet.is_open() and added[0] == 0, "first time: the consent sheet comes up, the add screen does not")
	var st: String = _texts(v.last_sheet)
	ok(st.contains("lrclib.net") and st.contains("AI 서비스") and st.contains("DeepSeek"), "the sheet names lrclib.net and the AI service in use")
	ok(v.last_sheet.buttons.has("agree") and v.last_sheet.buttons.has("cancel"), "the sheet has 동의 and 취소")
	v.request_add()
	await _frames(1)
	ok(Sheet.depth() == 1, "pressing again does not stack a second consent sheet")
	v.last_sheet.buttons["cancel"].pressed.emit()
	await _frames(3)
	ok(added[0] == 0 and not Store.pref_bool("song_consent"), "취소: no add screen, nothing saved")
	v.request_add()
	await _frames(3)
	v.last_sheet.close("dismiss")
	await _frames(3)
	ok(added[0] == 0 and not Store.pref_bool("song_consent"), "dismissed without agreeing: still no add screen, nothing saved")
	v.request_add()
	await _frames(3)
	v.last_sheet.buttons["agree"].pressed.emit()
	await _frames(3)
	ok(Store.pref_bool("song_consent") and added[0] == 1, "동의: song_consent saved as true and the add screen is asked for")
	ok(bool(JSON.parse_string(FileAccess.get_file_as_string(DIR.path_join("prefs.json"))).get("song_consent", false)), "song_consent is in the prefs file")
	v.request_add()
	await _frames(3)
	ok(added[0] == 2 and not Sheet.is_open(), "after consent: [+ 곡 추가] goes straight to the add screen")
	ok(Api.sent_count == sent2, "the consent and add steps sent no request themselves (Api.sent_count unchanged)")
	# a local AI says nothing leaves the PC
	_connect_pc(true, "ollama")
	ok(SongView.consent_text().contains("밖으로 나가지 않아요") and SongView.consent_text().contains("AI 서비스"), "with a local AI (Ollama) the sheet says nothing leaves the PC")
	_connect_pc(true)
	# full: 40 songs
	v.loader = func() -> Dictionary:
		return {"list": [], "orphans": [], "usage": {"songs": 40, "bytes": 5 * 1048576, "max_songs": 40, "max_bytes": 400 * 1048576}, "quarantined": []}
	v.refresh()
	await _wait_loaded(v)
	ok(v.add_block_reason() == "full" and v.notice_label() != null and v.notice_label().text.contains("가득"), "40 songs: the notice says the storage is full")
	v.request_add()
	ok(added[0] == 2, "full: no add screen")
	_close_sheets()
	_disconnect_pc()
	v.queue_free()
	await _frames(2)


func _test_layout() -> void:
	print("[layout]")
	_fresh()
	_close_sheets()
	_install("Layout Song", "Tester", "en", 1790000100)
	_install("月あかりの歌", "テスト太郎", "ja", 1790000200)
	_install("T".repeat(900), "Artist ".repeat(100), "en", 1790000300)
	var gone: String = _install("Gone Audio", "Tester", "en", 1790000400)
	DirAccess.remove_absolute(_g(SongStore.audio_path(gone)))
	SongStore.clear_cache()
	var bad: String = _install("Bad Song", "Tester", "en", 1790000500)
	_write(SongStore.song_dir(bad).path_join("song.json"), "{\"v\": 1, \"title\"")
	_disconnect_pc() # the notice card is part of the page
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	await _frames(3)
	var over: Array = _overflow(v)
	ok(over.is_empty(), "no control sticks out of the screen sideways (%s)" % [over.slice(0, 3)])
	ok(v._page.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "the page never scrolls sideways")
	# nothing overlaps its row neighbour: the delete button stays right of the title
	var clash := 0
	for id in v._rows.keys():
		var r: Control = v.row_for(str(id))
		var d: Button = v.delete_button(str(id))
		for l in r.find_children("*", "Label", true, false):
			if (l as Label).get_global_rect().intersects(d.get_global_rect().grow(-1.0)):
				clash += 1
	ok(clash == 0, "a title / artist never runs under the delete button (%d overlaps)" % clash)
	var short_btn := 0
	var tmin: float = Ds.touch_min()
	if _phone:
		for id in v._rows.keys():
			var r2: Rect2 = v.delete_button(str(id)).get_global_rect()
			if r2.size.y < tmin - 0.5 or r2.size.x < tmin - 0.5:
				short_btn += 1
		var ar: Rect2 = v.add_button().get_global_rect()
		if ar.size.y < tmin - 0.5:
			short_btn += 1
		if v.cleanup_button() != null and v.cleanup_button().get_global_rect().size.y < tmin - 0.5:
			short_btn += 1
		ok(short_btn == 0, "phone: add / delete / cleanup buttons are at least Ds.touch_min() (%.0f px) in both directions" % tmin)
		ok(v.add_button().get_parent() == v._page.content, "phone: [+ 곡 추가] is a full-width button under the title")
	else:
		ok(v.add_button() != null and v.add_button().get_parent() == v._header, "PC: [+ 곡 추가] is the action of the title row")
	var min_row := 1000.0
	for id in v._rows.keys():
		min_row = minf(min_row, v.row_for(str(id)).get_global_rect().size.y)
	ok(min_row >= 55.5, "every row is at least 56 px high (%.0f)" % min_row)
	ok(v.scroll_host() == v._page and v.header_block() != null and v.header_block().get_parent() == v._page.content, "app bar contract: scroll_host and header_block are the page and its title block")
	ok(v.page_title() == "" and v.page_actions().is_empty() and not v.go_back(), "app bar contract: top screen (no back button, no actions, go_back false)")
	_close_sheets()
	v.queue_free()
	await _frames(2)


func _test_load_edges() -> void:
	print("[load edges]")
	_fresh()
	_toasts.clear()
	var v := _make_view()
	await _frames(2)
	v.loader = func() -> Variant: return "garbage"
	v.refresh()
	await _wait_loaded(v)
	ok(v.state == "error" and _texts(v).contains("곡 목록을 불러오지 못했어요"), "a broken list result -> an error card, no exception")
	v.loader = func() -> Dictionary:
		return {"list": [{"id": "../x", "title": "bad id"}, 5, {"id": "s_aaaaaaaaaaaa", "title": "ok", "artist": "", "lang": "en", "duration": 10.0, "lines": 1, "ready": true}], "orphans": ["../y", 7, "s_bbbbbbbbbbbb"], "usage": 3, "quarantined": []}
	(v._body.find_children("*", "Button", true, false)[0] as Button).pressed.emit() # 다시 시도
	await _wait_loaded(v)
	ok(v.state == "ready" and v.songs.size() == 1 and v.orphans == ["s_bbbbbbbbbbbb"], "entries with a path-like id or a wrong type are dropped (%d songs, %s)" % [v.songs.size(), v.orphans])
	ok(v.usage_label() != null and v.usage_label().text.begins_with("곡 1개"), "a missing usage is replaced by a safe default")
	# leaving while the list is being read
	var v2 := _make_view()
	v2.loader = func() -> Dictionary:
		OS.delay_msec(250)
		return {"list": [], "orphans": [], "usage": {}, "quarantined": []}
	await _frames(2)
	v2.refresh()
	await _frames(2)
	var t0: int = Time.get_ticks_msec()
	v2.queue_free()
	await _frames(4)
	ok(not is_instance_valid(v2), "the view can be removed while it is still reading (the thread is joined, no crash; %d ms)" % (Time.get_ticks_msec() - t0))
	v.queue_free()
	await _frames(2)


func _test_main_wiring() -> void:
	print("[main.gd: the tab]")
	_fresh()
	_close_sheets()
	_disconnect_pc()
	var m: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	m.set("quit_on_exit", false)
	add_child(m)
	await _frames(4)
	ok(not m.tab_keys().has("song"), "before add_v11_tabs(): no 노래 tab (the layout tests that load main.tscn keep their tab list)")
	m.add_v11_tabs()
	await _frames(4)
	var keys: Array = m.tab_keys()
	ok(keys == ["today", "lesson", "talk", "review", "practice", "reading", "song", "stats", "roadmap", "settings"], "tab order: 노래 right after 읽기 (%s)" % [keys])
	ok(m.views.get("song", null) is SongView, "views['song'] is a SongView")
	var labels := {}
	for t in m._tabs:
		labels[str(t[0])] = str(t[1])
	ok(labels.get("song", "") == "노래", "tab label is 노래")
	ok(m.NAV_LEARN.has("song") and m.NAV_LEARN.find("song") == m.NAV_LEARN.find("reading") + 1 and m.OWN_HEADER.has("song"), "NAV_LEARN has song right after reading, OWN_HEADER has song")
	if _phone:
		var bt: BottomTabs = m._bottom_tabs
		ok(bt.direct_keys() == ["today", "lesson", "talk", "review"] and bt.overflow_keys().has("song") and bt.cell_buttons().size() == 5, "phone: the bottom bar keeps its 4 cells + 더보기, 노래 is inside 더보기 (%s)" % [bt.overflow_keys()])
	else:
		var btns: Dictionary = m._side_nav.item_buttons()
		ok(btns.has("song") and (btns["song"] as Button).text.contains("노래"), "PC: the side nav has a 노래 item")
		var ys := {}
		for k in ["practice", "reading", "song", "review", "stats"]:
			ys[k] = (btns[k] as Control).get_global_rect().position.y
		ok(ys["reading"] < ys["song"] and ys["song"] < ys["review"] and ys["practice"] < ys["reading"], "PC: 학습 section order ... 읽기, 노래, 복습")
		ok(ys["song"] < ys["stats"], "PC: 노래 is in the 학습 section (above 기록)")
	_toasts.clear()
	await _frames(10) # the shell's own start-up requests (health ...) are done
	var sent_shell: int = Api.sent_count
	m.show_view("song")
	await _frames(3)
	var sv: SongView = m.views["song"]
	await _wait_loaded(sv)
	ok(Api.sent_count == sent_shell, "showing the 노래 tab sends no request (Api.sent_count unchanged)")
	ok(m.current == "song" and sv.visible and sv.state == "ready", "showing the tab loads the list")
	ok(_overflow(sv).is_empty(), "inside the shell: nothing sticks out sideways")
	m.show_view("today")
	await _frames(2)
	ok(not sv.visible, "leaving the tab hides it")
	m.queue_free()
	await _frames(3)


func _test_real_folder_untouched() -> void:
	print("[the real songs folder]")
	var keep: String = SongStore.root
	SongStore.root = "user://songs" # the user's real folder: under the test guard a view must not read it at all
	SongStore.last_error = ""
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.state == "ready" and v.songs.is_empty() and SongStore.last_error != "test_guard", "test guard: the view shows an empty list without touching the real folder (no TEST_GUARD error)")
	v.queue_free()
	await _frames(2)
	SongStore.root = keep
