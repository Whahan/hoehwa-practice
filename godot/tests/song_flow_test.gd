extends Node
## 노래 공부 U5 + E1: 화면 연결 종단 시험 (docs/song_study_design.md §4.3 화면 흐름, §7.1 E1, §8 E1).
##   PC:   godot --headless --path godot res://tests/song_flow_test.tscn
##   폰:   godot --headless --path godot res://tests/song_flow_test.tscn -- --phone
##   (--python=<python.exe> 로 파이썬 지정, --only=<구간> 으로 한 구간만)
## 스텁 서버(backend/lan_stub_server.py --song, 가짜 전사)는 이 시험이 직접 띄우고 자기 PID(와 하위)만 끈다. 포트 18795 만 쓴다.
##   SongView(허브) -> [+ 곡 추가] 동의 시트 -> SongAddScreen -> (song_added) SongCheckScreen 한 줄 고쳐 저장 -> SongStudyScreen
##   -> 빈칸 탭 정답 -> 단어 카드 추가 -> 복습 카드가 Store 에 있음 -> ⋯ 메뉴(곡 정보 · 가사 확인·수정 · 곡 삭제) -> 곡 삭제.
##   폰 단독(PC 없음): 저장된 곡 학습은 되고 추가는 막힌다.
##   B: 해석 탭 저장 실패는 성공 문구를 내지 않고 되돌린다 / LRCLIB 늦은 답은 새 곡에 붙지 않는다.
##   화면 닫기: Song 버스 없음 · 목록 스레드 합류 · 녹음 정리. main.tscn 에서 뒤로 가기는 시트 -> 화면 순서.
## 곡은 user://test_songs_u5 에만 설치한다. 설정·진행·학습 기록은 user://test_u5/ 로 돌린다. 가사·제목은 모두 직접 지은 문장이다.
## 실제 사용자 폴더·8770/8775/8776·실제 lrclib.net 에는 접속하지 않는다 (LRCLIB 는 가짜 클라이언트).
## 마지막 줄: "== song_flow_test result: N passed, M failed ==", 종료 코드 1 = 실패.

const SV_PORT := 18795
const SV_BASE := "http://127.0.0.1:18795"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const ROOT := "user://test_songs_u5"
const DIR := "user://test_u5"
const JOBS_DIR := "user://test_u5_jobs"
const TONE := "res://tests/fixtures/song/tone_8s.mp3"
const LYRICS := "The river runs past the old wooden bridge\nWe hum a tune while the lanterns glow\nMorning comes and the sky turns gold"
const EDITED := "The river runs past the quiet wooden bridge"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _toasts: Array = []
var _before: Dictionary = {}
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_status: Variant
var _old_health: Dictionary
var _old_remote_base: String
var _sv_pid: int = -1
var _reached: Dictionary = {}
var _main: Control = null


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


func _fresh() -> void:
	SongStore.write_hook = Callable()
	SongStore.rename_fail = false
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.clear_cache()
	SongStore.take_quarantined()
	_rm_rf(ROOT)


func _consent(on: bool) -> void:
	Store.prefs["song_consent"] = on


func _connect_pc() -> void:
	Api.set_remote(SV_BASE, "")
	Backend.health = {"song": true, "song_v": 1, "llm": true, "llm_provider": "opencode"}
	Backend._set_status(Backend.Status.READY)


func _disconnect_pc() -> void:
	Backend.health = {}
	Backend._set_status(Backend.Status.FAILED, "x")


func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _make_view() -> SongView:
	var v := SongView.new()
	_stage(v)
	return v


func _wait_loaded(v: SongView, max_frames: int = 200) -> void:
	for i in max_frames:
		await get_tree().process_frame
		if v.state != "loading" and v.state != "idle" and not v.is_loading():
			break
	await _frames(2)


func _bus_exists() -> bool:
	return AudioServer.get_bus_index(SongPlayer.BUS_NAME) != -1


func _review_count() -> int:
	return (Store.progress["review"] as Array).size()


func _tone_song(title: String, nlines: int = 3) -> Dictionary:
	var lines: Array = []
	for i in nlines:
		lines.append({"i": i, "p": 0, "t0": 0.5 + i * 2.2, "t1": 2.3 + i * 2.2, "text": "A made up song line number %d about the sea" % i, "words": []})
	return {"v": 1, "lang": "en", "title": title, "artist": "Flow Tester", "created": 1790000000, "duration": 8.0,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "tone.mp3"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": []}


func _install_tone(title: String, nlines: int = 3) -> String:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(TONE)
	var r: Dictionary = SongStore.install(_tone_song(title, nlines), bytes)
	return str(r["id"]) if bool(r["ok"]) else ""


# ---------------------------------------------------------------- stub server (our own process only)

func _http(base: String, method: int, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 3.0
	add_child(req)
	var err: int = req.request(base + path, PackedStringArray(), method, "")
	if err != OK:
		req.queue_free()
		return {"code": 0, "data": null}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"code": 0, "data": null}
	var txt: String = (res[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(res[1]), "data": JSON.parse_string(txt) if (txt.begins_with("{") or txt.begins_with("[")) else null}


func _start_stub() -> bool:
	var busy: Dictionary = await _http(SV_BASE, HTTPClient.METHOD_GET, "/health")
	for i in 60: # another worker's test may hold the port for a moment: wait for it (never kill it)
		if int(busy["code"]) == 0:
			break
		await get_tree().create_timer(2.0).timeout
		busy = await _http(SV_BASE, HTTPClient.METHOD_GET, "/health")
	if int(busy["code"]) != 0:
		print("  port %d is still in use, not starting" % SV_PORT)
		return false
	var script: String = _g("res://").path_join("../backend/lan_stub_server.py").simplify_path()
	var py: String = _arg("--python=")
	if py == "":
		py = DEFAULT_PY
	var args := PackedStringArray(["-I", script, "--song", "--port", str(SV_PORT), "--song-dir", _g(JOBS_DIR), "--tag", "u5test",
		"--devices-file", _g(DIR).path_join("devices.json")])
	_sv_pid = OS.create_process(py, args)
	if _sv_pid <= 0:
		return false
	for i in 150:
		await get_tree().create_timer(0.2).timeout
		var h: Dictionary = await _http(SV_BASE, HTTPClient.METHOD_GET, "/health")
		if int(h["code"]) == 200:
			return true
	return false


func _stop_stub() -> void:
	if _sv_pid > 0:
		if OS.get_name() == "Windows":
			OS.execute("taskkill", PackedStringArray(["/PID", str(_sv_pid), "/T", "/F"])) ## only the process this test started, and its children
		else:
			OS.kill(_sv_pid)
		_sv_pid = -1


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	print("== song_flow_test start (%s) ==" % ["phone" if _phone else "pc"])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	_old_remote_base = Api.base_url
	_rm_rf(DIR)
	_rm_rf(JOBS_DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.progress = Progress.blank()
	for k in ["song_consent", "song_translate", "song_gloss", "song_last_tab"]:
		Store.prefs.erase(k)
	Store.prefs["lang"] = "en"
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port until a section starts the stub: the run must never reach the user's engine (8770)
	Sheet.animate = false
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", 1.0)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	var old_root: String = SongStore.root
	SongStore.root = ROOT
	_fresh()
	var buses0: int = AudioServer.bus_count

	await _selftest()
	if _want("phone_only") and _arg("--live=") == "":
		await _test_no_pc()
	if _want("flow") and _arg("--live=") == "":
		var up: bool = await _start_stub()
		ok(up, "stub server (lan_stub_server.py --song) is up on port %d" % SV_PORT)
		if up:
			await _test_flow()
		_stop_stub()
		await get_tree().create_timer(0.4).timeout
		var closed: Dictionary = await _http(SV_BASE, HTTPClient.METHOD_GET, "/health")
		ok(int(closed["code"]) == 0, "stub server is gone and port %d is closed again" % SV_PORT)
	if _want("meaning") and _arg("--live=") == "":
		await _test_meaning_save()
	if _want("lrclib") and _arg("--live=") == "":
		await _test_lrclib_late()
	if _want("delete") and _arg("--live=") == "":
		await _test_delete_paths()
	if _want("close") and _arg("--live=") == "":
		await _test_close_cleanup()
	if _want("main") and _arg("--live=") == "":
		await _test_main_back()
	if _arg("--live=") != "": # E1-4: one real server (not part of the normal run)
		await _test_live(_arg("--live="), _arg("--file="), _arg("--lyrics="), _arg("--truth="))

	Sheet.close_top("dismiss")
	_fresh()
	SongStore.root = old_root
	for k in ["song_consent", "song_translate", "song_gloss", "song_last_tab"]:
		Store.prefs.erase(k)
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Backend.health = _old_health
	Backend.status = _old_status
	Api.clear_remote()
	Recorder.mode_override = ""
	Recorder.test_hooks = {}
	SpeakDrill.api_hook = Callable()
	SongMeaningTab.pc_hook = Callable()
	_rm_rf(DIR)
	_rm_rf(JOBS_DIR)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "test folders cleaned up")
	ok(AudioServer.bus_count == buses0 and not _bus_exists(), "no audio bus is left over after the whole run")
	ok(_reached.size() == 7 or _arg("--only=") != "" or _arg("--live=") != "", "ran to the end of every section (%s)" % ",".join(PackedStringArray(_reached.keys())))
	print("== song_flow_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- checker self-test

## 일부러 틀린 입력: 검사 장치가 실제로 FAIL 을 낼 수 있는지.
func _selftest() -> void:
	print("[checker self-test: wrong input must FAIL]")
	ok(not await _until(func() -> bool: return false, 0.2), "_until() gives false when its condition never holds")
	ok(not _toast_has("this text was never shown"), "_toast_has() gives false for text that was never shown")
	var p := SongPlayer.new()
	add_child(p)
	var song: Dictionary = _tone_song("Selftest")
	song["id"] = "s_0123456789ab"
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(TONE)
	var gp: String = _g(SongStore.song_dir("s_0123456789ab"))
	DirAccess.make_dir_recursive_absolute(gp)
	var f := FileAccess.open(SongStore.audio_path("s_0123456789ab"), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	SongPlayer.songs_root = SongStore.root
	ok(p.load_song(SongModel.normalize(song)) and _bus_exists(), "a loaded SongPlayer makes the 'Song' bus exist (so '_bus_exists() == false' is a real check)")
	p.unload()
	p.queue_free()
	await _frames(2)
	ok(not _bus_exists(), "unload gives the bus back")
	_rm_rf(ROOT.path_join("s_0123456789ab"))
	var v := _make_view()
	var th := Thread.new()
	th.start(func() -> int:
		OS.delay_msec(150)
		return 1)
	ok(th.is_started() and th.is_alive(), "a running thread reports started + alive (so 'joined' is a real check)")
	th.wait_to_finish()
	ok(not th.is_started(), "after wait_to_finish the thread is no longer started")
	v.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- no PC: stored songs open, adding is blocked

func _test_no_pc() -> void:
	print("[no PC: saved songs can be studied, adding is blocked]")
	_fresh()
	_consent(true)
	_disconnect_pc()
	var id: String = _install_tone("Offline Tune")
	ok(id != "", "a song is saved on this device")
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.songs.size() == 1 and v.add_block_reason() == "no_pc", "list: the song is there and adding says no_pc")
	var sent0: int = Api.sent_count
	_toasts.clear()
	v.request_add()
	await _frames(2)
	ok(v.screen == null and _toast_has("PC 연결"), "[+ 곡 추가] without a PC: only the notice (no screen)")
	ok(Api.sent_count == sent0, "no request left for the PC (sent_count unchanged)")
	v._on_song_tap(id, true)
	await _frames(3)
	var st: SongStudyScreen = v.screen as SongStudyScreen
	ok(st != null and v.screen_kind == "study" and st.audio_ok and st.line_count() == 3, "tapping the song opens the study screen with its audio (no PC needed)")
	ok(v.page_title() == "Offline Tune", "app bar contract: the open screen gives its title (%s)" % v.page_title())
	ok(v.go_back() and v.screen == null, "back from the study screen returns to the list")
	await _wait_loaded(v)
	ok(not _bus_exists(), "the 'Song' bus is gone after leaving")
	# one argument name for opening a song: open(lang, {id}); the old {song_id} is still accepted
	for key in ["id", "song_id"]:
		var chk := SongCheckScreen.new()
		_stage(chk)
		chk.open("en", {key: id})
		var stu := SongStudyScreen.new()
		_stage(stu)
		stu.open("en", {key: id})
		ok(chk.load_error == "" and chk.line_count() == 3 and chk.song_id == id, "SongCheckScreen.open(lang, {%s}) loads the song" % key)
		ok(stu.open_error == "" and stu.song_id == id and stu.line_count() == 3, "SongStudyScreen.open(lang, {%s}) loads the song" % key)
		chk.queue_free()
		stu.queue_free()
		await _frames(2)
	var bad := SongCheckScreen.new()
	_stage(bad)
	bad.open("en", {"id": "s_000000000000"})
	ok(bad.load_error != "", "a wrong id gives the load error, not a crash")
	bad.queue_free()
	v.queue_free()
	await _frames(2)
	_reached["phone_only"] = true


# ---------------------------------------------------------------- the whole flow against the stub server

func _test_flow() -> void:
	print("[E1 flow: add -> process -> install -> check -> study -> cloze -> word card -> delete]")
	_fresh()
	_connect_pc()
	_consent(false)
	Store.progress = Progress.blank()
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.state == "ready" and v.songs.is_empty(), "list: empty state, no songs yet")
	# --- consent sheet, then the add screen opens inside the hub
	v.request_add()
	ok(v.screen == null and v.last_sheet != null and not v.last_sheet.is_closed(), "[+ 곡 추가] the first time: consent sheet, no screen yet")
	(v.last_sheet.buttons["agree"] as Button).pressed.emit()
	await _frames(3)
	ok(Store.pref_bool("song_consent") and v.screen_kind == "add" and v.screen is SongAddScreen, "agreeing saves the consent and opens the add screen")
	ok(v.page_title() == "곡 추가" and v.scroll_host() == null and v.header_block() == null, "app bar contract: the add screen's title, the list's scroll/header are off")
	var a: SongAddScreen = v.screen
	a.transfer.poll_interval = 0.05
	a.transfer.retry_delays = [0.02, 0.02, 0.02]
	a.duration_probe = func(_p: String) -> float: return 8.0
	ok(a.set_file(TONE), "the add screen takes the tone file")
	a.set_title("Flow Song One")
	a.set_artist("Flow Tester")
	a.set_source("pasted")
	a.set_pasted(LYRICS)
	var e: String = a.make()
	ok(e == "" and a.phase == "running", "make() starts the transfer (phase running)")
	ok(await _until(func() -> bool: return v.screen_kind == "check", 60.0), "song_added -> the hub opens the check screen by itself")
	var c: SongCheckScreen = v.screen as SongCheckScreen
	ok(c != null and c.load_error == "" and c.line_count() >= 1, "check screen: the installed song is loaded (%d lines)" % (c.line_count() if c != null else -1))
	var id: String = c.song_id if c != null else ""
	ok(SongModel.is_valid_id(id) and not SongStore.load_song(id).is_empty(), "the song is installed in SongStore (%s)" % id)
	ok(SongStore.pending_list().is_empty(), "pending is empty after the install")
	# --- fix one line, save -> study screen
	var n_lines: int = c.line_count()
	ok(c.set_text(0, EDITED), "check screen: one line is fixed")
	ok(c.is_dirty(), "check screen: the song is dirty")
	var saved_ids: Array = []
	c.saved.connect(func(sid: String) -> void: saved_ids.append(sid))
	c._btn_save.pressed.emit()
	ok(saved_ids == [id], "check screen: saved(song_id) came once")
	ok(await _until(func() -> bool: return v.screen_kind == "study", 20.0), "saved -> closed -> the hub opens the study screen")
	var disk: Dictionary = SongStore.load_song(id)
	ok(str((disk["lines"] as Array)[0]["text"]) == EDITED and bool((disk["lines"] as Array)[0].get("stale", false)), "song.json has the fixed line (stale = true)")
	var st: SongStudyScreen = v.screen as SongStudyScreen
	ok(st != null and st.song_id == id and st.audio_ok and st.line_count() == n_lines, "study screen: this song, audio loaded, same %d lines" % n_lines)
	ok(str(st.line(0).get("text", "")) == EDITED, "study screen shows the fixed line")
	ok(_bus_exists(), "study screen: the 'Song' bus exists while it is open")
	# --- play a line (real adapter)
	st.play_line(0)
	await _frames(3)
	ok(st.player.is_playing(), "study screen: a line plays")
	st.stop_play()
	# --- cloze: tap the right answers
	st.show_tab("cloze")
	await _frames(2)
	var cz: SongClozeTab = st.current_tab() as SongClozeTab
	ok(cz != null and cz.stage == "run", "cloze tab: a round is running (%s)" % (cz.stage if cz != null else "?"))
	var cloze_ok: bool = false
	if cz != null and cz.stage == "run":
		var blanks: Array = cz.cur.get("blanks", [])
		for k in blanks.size():
			cz.set_answer(k, str((blanks[k] as Dictionary)["answer"]))
		ok(cz.check(), "cloze tab: the answers are checked")
		cloze_ok = bool((cz.results[cz.current_line()] as Dictionary)["ok"])
	ok(cloze_ok, "cloze tab: the right answers are marked right")
	# --- word card
	st.show_tab("words")
	await _frames(2)
	var wt: SongWordsTab = st.current_tab() as SongWordsTab
	ok(wt != null and wt.words.size() >= 1, "words tab: unknown words are listed (%d)" % (wt.words.size() if wt != null else -1))
	var base: int = _review_count()
	var lemma: String = str((wt.words[0] as Dictionary)["lemma"]) if wt != null and wt.words.size() >= 1 else ""
	ok(lemma != "" and wt.add_card(lemma) == 1, "words tab: [복습에 추가] adds one card (%s)" % lemma)
	var card_found := false
	for r in Store.progress["review"]:
		if str((r as Dictionary)["target"]) == lemma and str((r as Dictionary).get("note", "")).begins_with("♪ "):
			card_found = true
	ok(_review_count() == base + 1 and card_found, "the review card is in the Store (target %s, note ♪ …)" % lemma)
	# --- the ⋯ menu: info
	st.open_menu()
	await _frames(2)
	ok(st.last_sheet != null and not st.last_sheet.is_closed() and st.last_sheet.buttons.has("delete") and st.last_sheet.buttons.has("check") and st.last_sheet.buttons.has("info"), "⋯ menu: 가사 확인·수정 / 곡 정보 / 곡 삭제")
	(st.last_sheet.buttons["info"] as Button).pressed.emit()
	await _frames(3)
	ok(Sheet.is_open() and st.last_sheet != null and _texts(st.last_sheet).contains("Flow Song One") and _texts(st.last_sheet).contains("붙여넣은 가사"), "곡 정보 sheet: title and lyrics source")
	# the back button: the sheet first, the screen second
	ok(v.go_back() and not Sheet.is_open() and v.screen_kind == "study", "back (1): closes the sheet, the study screen stays")
	# --- the ⋯ menu: 가사 확인·수정 -> check -> back to study
	st.open_menu()
	await _frames(2)
	(st.last_sheet.buttons["check"] as Button).pressed.emit()
	ok(await _until(func() -> bool: return v.screen_kind == "check", 10.0), "⋯ > 가사 확인·수정 opens the check screen")
	var c2: SongCheckScreen = v.screen as SongCheckScreen
	ok(c2 != null and c2.song_id == id and c2.line_count() == n_lines and str(c2.lines()[0]["text"]) == EDITED, "the check screen has the same song (open(lang, {id}))")
	ok(c2.go_back() and await _until(func() -> bool: return v.screen_kind == "study", 10.0), "leaving the check screen without a change returns to the study screen")
	ok(not _bus_exists() or (v.screen as SongStudyScreen).audio_ok, "(the study screen was made again and has its audio)")
	st = v.screen as SongStudyScreen
	# --- the back button: sheet then screen then list
	st.open_menu()
	await _frames(2)
	ok(Sheet.is_open(), "the ⋯ menu sheet is open")
	ok(v.go_back() and not Sheet.is_open() and v.screen_kind == "study", "back (1): sheet closed, screen stays")
	ok(v.go_back() and v.screen == null, "back (2): the screen closes")
	await _wait_loaded(v)
	ok(v.songs.size() == 1 and not v.go_back(), "back (3): the list is the top (go_back false); the song is still listed")
	ok(not _bus_exists(), "after leaving the study screen the 'Song' bus is gone")
	# --- open from the list again, then delete from the menu
	v._on_song_tap(id, true)
	await _frames(3)
	st = v.screen as SongStudyScreen
	ok(st != null and st.audio_ok, "tapping the song opens the study screen again")
	var cards_before: int = _review_count()
	st.open_menu()
	await _frames(2)
	(st.last_sheet.buttons["delete"] as Button).pressed.emit()
	await _frames(3)
	ok(Sheet.is_open() and v.screen_kind == "study" and SongStore.load_song(id).size() > 0, "곡 삭제 asks first: the song is still there")
	ok(Sheet.close_top("dismiss") and not SongStore.load_song(id).is_empty(), "dismissing the question keeps the song")
	st.open_menu()
	await _frames(2)
	(st.last_sheet.buttons["delete"] as Button).pressed.emit()
	await _frames(3)
	var confirm: Sheet = st.last_sheet
	ok(confirm != null and confirm.buttons.has("ok"), "the delete question has a confirm button")
	(confirm.buttons["ok"] as Button).pressed.emit()
	await _frames(3)
	ok(v.screen == null, "after the delete the study screen is closed")
	await _wait_loaded(v)
	ok(SongStore.load_song(id).is_empty() and not DirAccess.dir_exists_absolute(_g(SongStore.song_dir(id))), "the song folder is gone (SongStore.delete)")
	ok(v.songs.is_empty() and v.state == "ready", "the list reloads and is empty again")
	ok(_review_count() == cards_before, "the review cards stay after the song is deleted")
	ok(not _bus_exists(), "the 'Song' bus is gone after the delete")
	v.queue_free()
	await _frames(2)
	_reached["flow"] = true


# ---------------------------------------------------------------- B1: the meaning tab and a failed save

func _enrich_hook(_method: String, _path: String, body: Variant) -> Dictionary:
	var out: Array = []
	for ln in (body as Dictionary).get("lines", []):
		out.append({"i": int((ln as Dictionary)["i"]), "ko": "만든 해석 %d" % int((ln as Dictionary)["i"])})
	return {"ok": true, "code": 200, "data": {"lines": out, "glossary": {}, "warnings": []}}


func _test_meaning_save() -> void:
	print("[B1: a failed save is not reported as a success]")
	_fresh()
	_consent(true)
	Store.prefs.erase("song_translate")
	SpeakDrill.api_hook = Callable(self, "_enrich_hook")
	SongMeaningTab.pc_hook = func() -> bool: return true
	var id: String = _install_tone("Meaning Tune", 3)
	var song: Dictionary = SongStore.load_song(id)
	var tab := SongMeaningTab.new()
	_stage(tab)
	tab.setup(song, {})
	await _frames(2)
	var changed: Array = [0]
	tab.song_changed.connect(func() -> void: changed[0] += 1)
	ok(tab.missing_lines().size() == 3, "meaning tab: 3 lines need a translation")
	# the disk refuses the write
	SongStore.rename_fail = true
	var made: bool = await tab.make_missing()
	ok(not made, "make_missing() with a failing save returns false")
	ok(tab.missing_lines().size() == 3 and str((song["lines"] as Array)[0].get("ko", "")) == "", "the translations are taken back (no ko in memory)")
	ok(not tab.last_msg.contains("만들었어요.") or tab.last_msg.contains("저장하지 못했어요"), "the message is not the success text")
	ok(tab.last_msg.begins_with("해석을 만들었지만 저장하지 못했어요"), "the message says the save failed (%s)" % tab.last_msg)
	ok(changed[0] == 0, "song_changed is not sent for a translation that was not kept")
	ok(_texts(tab).contains("저장하지 못했어요") and not _texts(tab).contains("줄의 해석을 만들었어요"), "the tab shows the failure, not 'N줄의 해석을 만들었어요'")
	ok(str(SongStore.load_song(id)["lines"][0].get("ko", "")) == "", "the song on disk still has no translation")
	# the switch
	var had_sw: bool = song.has("translate")
	var sw_before: Variant = song.get("translate", null)
	tab.set_translate(false)
	ok(song.has("translate") == had_sw and song.get("translate", null) == sw_before, "set_translate(false) with a failing save keeps the old switch value")
	ok(tab.last_msg.begins_with("저장하지 못해서 스위치를 바꾸지 못했어요"), "set_translate says it could not save (%s)" % tab.last_msg)
	ok(SongMeaningTab.translate_on(song), "the switch still reads 'on'")
	# the disk works again: it succeeds and the success text is true
	SongStore.rename_fail = false
	made = await tab.make_missing()
	ok(made and tab.missing_lines().is_empty() and changed[0] == 1, "after the disk works: the translations are made, kept and announced once")
	ok(tab.last_msg.contains("3줄의 해석을 만들었어요"), "the success text is shown (%s)" % tab.last_msg)
	ok(str(SongStore.load_song(id)["lines"][0].get("ko", "")) == "만든 해석 0", "the translation is on disk")
	tab.set_translate(false)
	ok(song.get("translate", null) == false and tab.last_msg == "" and SongStore.load_song(id).get("translate", null) == false, "set_translate(false) with a working save is kept on disk")
	# a read-only (newer app) song cannot be saved either: no false success
	var song2: Dictionary = SongStore.load_song(id)
	song2["v"] = 2
	for ln in song2["lines"]:
		(ln as Dictionary)["ko"] = ""
	song2["translate"] = true
	var tab2 := SongMeaningTab.new()
	_stage(tab2)
	tab2.setup(song2, {})
	var made2: bool = await tab2.make_missing()
	ok(not made2 and tab2.last_msg.contains("더 새로운 버전의 앱") and tab2.missing_lines().size() == 3, "a read-only song: translations are not kept and the message says why")
	tab.queue_free()
	tab2.queue_free()
	SpeakDrill.api_hook = Callable()
	SongMeaningTab.pc_hook = Callable()
	await _frames(2)
	_reached["meaning"] = true


# ---------------------------------------------------------------- B2: a late LRCLIB answer must not land on the new song

class SlowClient:
	extends LrclibClient
	var delay: float = 0.4
	var answers: Array = [] ## one per call (the last one repeats)
	var calls: int = 0

	func _pick() -> Dictionary:
		calls += 1
		return answers[mini(calls, answers.size()) - 1]

	func find(_track: String, _artist: String, _album: String = "", _duration: float = 0.0) -> Dictionary:
		var a: Dictionary = _pick()
		await get_tree().create_timer(delay).timeout
		return a

	func search(_q: String, _track: String = "", _artist: String = "", _duration: float = -1.0) -> Dictionary:
		var a: Dictionary = _pick()
		await get_tree().create_timer(delay).timeout
		return a


func _rec(id: int, name: String) -> Dictionary:
	return {"id": id, "trackName": name, "artistName": "Test Artist", "albumName": "", "duration": 8.0, "instrumental": false,
		"syncedLyrics": "", "plainLyrics": "A made up first line\nA made up second line"}


func _test_lrclib_late() -> void:
	print("[B2: a late LRCLIB answer is dropped when another file was picked]")
	_fresh()
	_consent(true)
	_connect_pc()
	var client := SlowClient.new()
	client.delay = 0.5
	client.answers = [{"kind": "exact", "record": _rec(11, "Old Song Name")}, {"kind": "exact", "record": _rec(22, "New Song Name")}]
	var s := SongAddScreen.new()
	_stage(s)
	s.lrclib_factory = func() -> LrclibClient: return client
	s.duration_probe = func(_p: String) -> float: return 8.0
	s.open("en", {})
	ok(s.set_file(TONE), "add screen: a file is picked")
	s.set_title("Old Song Name")
	s.set_artist("Test Artist")
	s.find_lyrics() # not awaited: the request is in flight
	await _frames(2)
	ok(s.lr_busy and s.lr_get_calls == 1 and client.calls == 1, "the lookup for the old song is in flight")
	ok(s.set_file(TONE), "while it is in flight another file is picked (a new song)")
	ok(s.lr_get_calls == 0 and s.lr_status == "" and not s.lr_busy, "the new song starts clean (no lookups, no status)")
	await get_tree().create_timer(0.8).timeout
	ok(s.lr_status == "" and s.lr_record.is_empty() and s.lr_items.is_empty(), "the old song's late answer was dropped (status '%s', record %s)" % [s.lr_status, s.lr_record.get("id", "-")])
	ok(s.lr_get_calls == 0 and not s.lr_busy and s.source == "none", "…and it did not use up the new song's lookup or flip the source")
	# overlap: the old answer comes back while the new lookup is still waiting
	client.calls = 0
	client.delay = 0.5
	s.find_lyrics() # call 1 -> old record 11, back at t=0.5
	await _frames(2)
	ok(s.set_file(TONE), "again: a new file is picked while a lookup is in flight")
	await get_tree().create_timer(0.1).timeout
	s.title_text = "New Song Name"
	s.find_lyrics() # call 2 -> record 22, back at about t=0.7
	await get_tree().create_timer(0.45).timeout # t=0.55: the old answer (t=0.5) has arrived, the new one has not
	ok(s.lr_busy and s.lr_status == "busy" and s.lr_record.is_empty(), "between the two answers the new lookup is still waiting and shows nothing from the old one (status '%s')" % s.lr_status)
	await get_tree().create_timer(0.5).timeout
	ok(not s.lr_busy and int(s.lr_record.get("id", 0)) == 22 and s.lr_status == "found", "the new song's own answer is the one that is kept (record %s)" % s.lr_record.get("id", "-"))
	# search has the same rule
	s.set_file(TONE)
	client.calls = 0
	client.answers = [{"ok": true, "items": [_rec(31, "Search Old")]}, {"ok": true, "items": [_rec(32, "Search New")]}]
	s.lr_get_calls = 1 # the get lookup of the song is used; the search is what is tested
	s.search_lyrics()
	await _frames(2)
	ok(s.lr_busy, "a search is in flight")
	s.set_file(TONE)
	await get_tree().create_timer(0.8).timeout
	ok(s.lr_items.is_empty() and s.lr_status == "" and s.lr_search_calls == 0, "the late search answer was dropped too (items %d, status '%s')" % [s.lr_items.size(), s.lr_status])
	s.queue_free()
	client.queue_free()
	await _frames(2)
	_reached["lrclib"] = true


# ---------------------------------------------------------------- deleting a song from the study screen: order and failures

## SongPlayer adapter that notes whether the song folder still existed when the audio was given back.
class RecAdapter:
	extends SongPlayer.Adapter
	var dir: String = ""
	var releases: int = 0
	var dir_existed_at_release: bool = false

	func load_audio(_path: String) -> float:
		return 8.0

	func release() -> void:
		releases += 1
		dir_existed_at_release = DirAccess.dir_exists_absolute(dir)


func _test_delete_paths() -> void:
	print("[delete from the study screen: audio is released first, failures are handled]")
	_fresh()
	_consent(true)
	_disconnect_pc()
	# --- (1) the order: the player lets go of the audio BEFORE SongStore.delete (an open audio file blocks the delete on Windows)
	var id: String = _install_tone("Order Tune", 3)
	var fake := RecAdapter.new()
	fake.dir = _g(SongStore.song_dir(id))
	var st := SongStudyScreen.new()
	st.player.backend = fake
	_stage(st)
	st.open("en", {"id": id})
	await _frames(2)
	var rel0: int = fake.releases # open() itself lets go of the old audio once
	ok(st.audio_ok, "study screen with a fake audio adapter is open")
	ok(st.delete_now(), "delete_now() succeeds")
	ok(fake.releases > rel0 and fake.dir_existed_at_release, "the audio was released while the song folder still existed (unload before SongStore.delete)")
	ok(not DirAccess.dir_exists_absolute(fake.dir) and st.result == "deleted", "...and then the folder is deleted")
	st.queue_free()
	await _frames(2)
	# --- (2) a delete that fails and leaves the song complete: the screen says so and keeps working
	var id2: String = _install_tone("Locked Tune", 3)
	var s2 := SongStudyScreen.new()
	_stage(s2)
	s2.open("en", {"id": id2})
	await _frames(2)
	var closed: Array = [0]
	s2.closed.connect(func() -> void: closed[0] += 1)
	ok(s2.audio_ok, "second song: audio loaded")
	var lock_a: FileAccess = FileAccess.open(SongStore.audio_path(id2), FileAccess.READ) # an open file cannot be deleted on Windows
	var lock_j: FileAccess = FileAccess.open(SongStore.song_dir(id2).path_join("song.json"), FileAccess.READ)
	_toasts.clear()
	var did: bool = s2.delete_now()
	var held: bool = FileAccess.file_exists(SongStore.audio_path(id2))
	ok(not did and held, "delete_now() with both files held open fails and the folder is still there")
	ok(_toast_has("곡을 지우지 못했어요") and not _toast_has("일부만"), "the 'could not delete' notice is shown (not the partial one)")
	ok(closed[0] == 0 and s2.result == "" and s2.audio_ok and s2.player.is_loaded(), "the screen stays open and the audio is loaded again (MSG_DELETE_FAIL -> player.load_song)")
	ok(not SongStore.load_song(id2).is_empty(), "the song is still whole on disk")
	lock_a = null
	lock_j = null
	s2.queue_free()
	await _frames(2)
	# --- (3) a delete that fails half way (song.json gone, audio left): the screen closes and the list offers the clean-up
	var id3: String = _install_tone("Half Tune", 3)
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	v._on_song_tap(id3, true)
	await _frames(3)
	var st3: SongStudyScreen = v.screen as SongStudyScreen
	ok(st3 != null and st3.audio_ok, "third song: opened from the list")
	var lock_audio: FileAccess = FileAccess.open(SongStore.audio_path(id3), FileAccess.READ)
	_toasts.clear()
	st3.open_menu()
	await _frames(2)
	(st3.last_sheet.buttons["delete"] as Button).pressed.emit()
	await _frames(3)
	(st3.last_sheet.buttons["ok"] as Button).pressed.emit()
	await _frames(3)
	var half: bool = SongStore.load_song(id3).is_empty() and FileAccess.file_exists(SongStore.audio_path(id3))
	ok(half, "the folder is half deleted (song.json gone, audio left)")
	ok(_toast_has("일부만 지워졌어요") and _toast_has("복구할 수 없는 곡 정리"), "the half-deleted notice names the clean-up in the list")
	ok(v.screen == null, "the study screen closed (it does not say 'keep using it')")
	await _wait_loaded(v)
	ok(v.orphans.has(id3) and v.cleanup_button() != null, "the list was refreshed and offers the clean-up for it")
	lock_audio = null
	await _frames(2)
	v.cleanup_now()
	await _wait_loaded(v)
	ok(not DirAccess.dir_exists_absolute(_g(SongStore.song_dir(id3))) and v.orphans.is_empty(), "the clean-up removes what was left")
	ok(not _bus_exists(), "no 'Song' bus is left")
	v.queue_free()
	await _frames(2)
	_reached["delete"] = true


# ---------------------------------------------------------------- closing screens gives everything back

func _test_close_cleanup() -> void:
	print("[closing: Song bus, list thread, recording]")
	_fresh()
	_consent(true)
	_disconnect_pc()
	var id: String = _install_tone("Close Tune", 3)
	# --- a study screen with a running song and a running recording, closed by the back button
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	v._on_song_tap(id, true)
	await _frames(3)
	var st: SongStudyScreen = v.screen as SongStudyScreen
	ok(st != null and st.audio_ok and _bus_exists(), "study screen open: audio loaded, the 'Song' bus exists")
	st.play_line(1)
	await _frames(2)
	st.show_tab("sing")
	await _frames(2)
	var sing: SongSingTab = st.current_tab() as SongSingTab
	ok(sing != null and sing.recorder != null, "the sing tab has its recorder")
	Recorder.mode_override = "android"
	Recorder.test_hooks = {"granted": func() -> bool: return true, "open": func() -> bool: return true, "close": func() -> void: pass,
		"level": func() -> float: return 0.1, "recording": func() -> AudioStreamWAV: return null}
	ok(Recorder.begin(sing.recorder.get_instance_id()) and Recorder.recording, "a recording is running for the sing tab")
	await _frames(3)
	ok(Recorder.recording and Recorder.owner_id == sing.recorder.get_instance_id(), "…and it is still running before the screen closes")
	# the list tab is left (main.gd calls SongView.on_hide): the recording is cancelled, the screen stays
	v.on_hide()
	await _frames(2)
	ok(not Recorder.recording and v.screen == st and not st.player.is_playing(), "on_hide (tab switch): the recording is cancelled and the sound stops, the screen stays")
	ok(Recorder.begin(sing.recorder.get_instance_id()) and Recorder.recording, "a new recording can start again")
	await _frames(3)
	var ref: WeakRef = weakref(st)
	ok(v.go_back(), "back closes the screen")
	await _frames(3)
	ok(not Recorder.recording, "the recording is cancelled when the screen closes")
	ok(not _bus_exists(), "the 'Song' bus is gone (the player gave its audio back)")
	ok(ref.get_ref() == null, "the study screen object is freed")
	ok(v.screen == null and v._page.visible, "the list is back")
	Recorder.mode_override = ""
	Recorder.test_hooks = {}
	await _wait_loaded(v)
	# --- the whole view freed while a study screen is open (a tab switch away does not free it, removing the view does)
	v._on_song_tap(id, true)
	await _frames(3)
	st = v.screen as SongStudyScreen
	ok(st != null and _bus_exists(), "study screen open again")
	st.play_line(0)
	await _frames(2)
	remove_child(v)
	v.queue_free()
	await _frames(3)
	ok(not _bus_exists(), "removing the list view (screen open) also gives the 'Song' bus back")
	# --- a list read on a thread while the view goes away: the thread is joined
	var v2 := _make_view()
	v2.loader = func() -> Dictionary:
		OS.delay_msec(500)
		return {"list": [], "orphans": [], "usage": {"songs": 0, "bytes": 0, "max_songs": 40, "max_bytes": 1000}, "quarantined": []}
	await _frames(2)
	v2.refresh()
	await _frames(2)
	var th: Thread = v2._thread
	ok(th != null and th.is_started() and v2.is_loading(), "the list is being read on a thread")
	remove_child(v2)
	v2.queue_free()
	ok(not th.is_started() and v2._thread == null, "removing the view joined the thread (no thread left running)")
	await _frames(2)
	# --- the add screen: leaving it never leaves a running transfer behind
	var v3 := _make_view()
	_connect_pc()
	Api.set_remote("http://127.0.0.1:9", "")
	await _frames(2)
	v3.refresh()
	await _wait_loaded(v3)
	ok(v3.open_screen("add", {"lang": "en"}) and v3.screen_kind == "add", "the hub opens the add screen")
	var add_ref: WeakRef = weakref(v3.screen)
	var tr: SongTransfer = (v3.screen as SongAddScreen).transfer
	ok(v3.go_back(), "back from the add screen")
	await _frames(3)
	ok(v3.screen == null and add_ref.get_ref() == null and not tr.busy if is_instance_valid(tr) else true, "the add screen is freed and nothing runs")
	v3.queue_free()
	_disconnect_pc()
	await _frames(2)
	_reached["close"] = true


# ---------------------------------------------------------------- main.tscn: the Android back button order

func _test_main_back() -> void:
	print("[main.tscn: back = sheet first, then the screen, then the list]")
	_fresh()
	_consent(true)
	_disconnect_pc()
	var id: String = _install_tone("Main Tune", 3)
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	_main = get_tree().current_scene
	ok(_main != null and _main.has_method("handle_back"), "main.tscn is the running scene")
	if _main == null:
		return
	_main.quit_on_exit = false
	await _frames(8)
	_main.show_view("song")
	await _frames(3)
	var sv: SongView = _main.views["song"] as SongView
	ok(sv != null and _main.current == "song", "the 노래 tab shows the SongView")
	await _wait_loaded(sv)
	ok(sv.host_screens and sv.songs.size() == 1, "main's SongView hosts its screens and lists the song")
	sv._on_song_tap(id, true)
	await _frames(4)
	var st: SongStudyScreen = sv.screen as SongStudyScreen
	ok(st != null and st.audio_ok, "tapping the song in the real app opens the study screen")
	st.open_menu()
	await _frames(2)
	ok(Sheet.is_open(), "the ⋯ menu sheet is open")
	_main.handle_back()
	await _frames(2)
	ok(not Sheet.is_open() and sv.screen == st and _main.current == "song", "back (1): only the sheet closes")
	_main.handle_back()
	await _frames(3)
	ok(sv.screen == null and _main.current == "song", "back (2): the study screen closes, the list stays")
	await _wait_loaded(sv)
	ok(not _bus_exists(), "the 'Song' bus is gone")
	_main.handle_back()
	await _frames(3)
	ok(_main.current == "today", "back (3): from the list the app goes to 오늘")
	# --- the list tab left while a screen is open: it stops, it is still there
	_main.show_view("song")
	await _frames(3)
	await _wait_loaded(sv)
	sv._on_song_tap(id, true)
	await _frames(4)
	st = sv.screen as SongStudyScreen
	ok(st != null, "the song opens again from the list")
	st.play_line(0)
	await _frames(2)
	ok(st.player.is_playing(), "a line plays in the real app")
	st.show_tab("sing")
	await _frames(2)
	var sing: SongSingTab = st.current_tab() as SongSingTab
	Recorder.mode_override = "android"
	Recorder.test_hooks = {"granted": func() -> bool: return true, "open": func() -> bool: return true, "close": func() -> void: pass,
		"level": func() -> float: return 0.1, "recording": func() -> AudioStreamWAV: return null}
	ok(sing != null and Recorder.begin(sing.recorder.get_instance_id()) and Recorder.recording, "a recording runs in the real app")
	await _frames(3)
	_main.show_view("lesson")
	await _frames(3)
	ok(not Recorder.recording, "switching the tab cancels the running recording")
	Recorder.mode_override = ""
	Recorder.test_hooks = {}
	ok(not st.player.is_playing() and sv.screen == st, "leaving the tab stops the sound (on_hide) and keeps the screen")
	_main.show_view("song")
	await _frames(3)
	ok(sv.screen == st, "coming back to the tab shows the same study screen")
	sv.go_back()
	await _frames(3)
	_main.queue_free()
	await _frames(3)
	get_tree().current_scene = null
	await _frames(2)
	_reached["main"] = true


# ---------------------------------------------------------------- E1-4: one real server (--live=<base> --file=<mp3> --lyrics=<txt> [--truth=<json>])

## The app flow once against a running server.py (real Whisper). ai_ok stays false: song_consent is off, so no lyrics go to any AI service.
func _test_live(base: String, file_path: String, lyrics_path: String, truth_path: String) -> void:
	print("[live: one real server at %s]" % base)
	_fresh()
	Api.set_remote(base, "")
	Backend.health = {"song": true, "song_v": 1}
	Backend._set_status(Backend.Status.READY)
	_consent(false)
	var lyr := ""
	for ln in FileAccess.get_file_as_string(lyrics_path).split("
"):
		if not ln.begins_with("#"): # the comment lines of the fixture are not part of the lyrics a person pastes
			lyr += ln + "
"
	ok(FileAccess.file_exists(file_path) and lyr.strip_edges() != "", "live: the audio file and the lyrics are there")
	var v := _make_view()
	await _frames(2)
	v.refresh()
	await _wait_loaded(v)
	ok(v.open_screen("add", {"lang": "en"}), "live: the add screen is open")
	var a: SongAddScreen = v.screen as SongAddScreen
	ok(a.set_file(file_path), "live: the file is accepted (%.1f s)" % float(a.file.get("duration", 0.0)))
	a.set_title("Live Kettle Song")
	a.set_artist("Synthetic Voice")
	a.set_source("pasted")
	a.set_pasted(lyr)
	ok(not bool(a.build_params()["options"]["ai_ok"]), "live: ai_ok is false in the request (no AI call)")
	var t0: int = Time.get_ticks_msec()
	var e: String = a.make()
	ok(e == "" and a.phase == "running", "live: make() started the transfer")
	var seen: Array = []
	a.transfer.progress.connect(func(stage: String, pct: float, _t: String) -> void:
		if seen.is_empty() or seen[seen.size() - 1] != stage:
			seen.append(stage))
	var got: bool = await _until(func() -> bool: return v.screen_kind == "check" or a.phase == "failed", 1500.0)
	var secs: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(got and v.screen_kind == "check", "live: processing ended and the check screen opened (%.1f s; stages %s; phase %s)" % [secs, seen, a.phase if is_instance_valid(a) else "gone"])
	var c: SongCheckScreen = v.screen as SongCheckScreen
	if c == null:
		print("LIVE_RESULT failed seconds=%.1f error=%s" % [secs, str(a.last_result.get("message", "")) if is_instance_valid(a) else "?"])
		v.queue_free()
		await _frames(2)
		return
	var n: int = c.line_count()
	var warns: Array = c.working.get("warnings", [])
	var errs: Array = []
	if truth_path != "" and FileAccess.file_exists(truth_path):
		var tr: Variant = JSON.parse_string(FileAccess.get_file_as_string(truth_path))
		if tr is Dictionary and (tr as Dictionary).get("lines", null) is Array:
			var tl: Array = (tr as Dictionary)["lines"]
			for i in mini(tl.size(), n):
				errs.append(absf(float((c.lines()[i] as Dictionary)["t0"]) - float((tl[i] as Dictionary)["t0"])))
	errs.sort()
	var med: float = float(errs[errs.size() / 2]) if not errs.is_empty() else -1.0
	var mx: float = float(errs[errs.size() - 1]) if not errs.is_empty() else -1.0
	print("LIVE_RESULT ok lines=%d seconds=%.1f warnings=%s line_start_err_median=%.2f max=%.2f stages=%s" % [n, secs, warns, med, mx, seen])
	ok(n >= 1, "live: the song has %d lines" % n)
	var id: String = c.song_id
	ok(not SongStore.load_song(id).is_empty(), "live: the song is installed")
	c._btn_save.pressed.emit() # [저장하고 공부하기] without a change
	ok(await _until(func() -> bool: return v.screen_kind == "study", 15.0), "live: the check screen leads to the study screen")
	var st: SongStudyScreen = v.screen as SongStudyScreen
	ok(st != null and st.audio_ok and st.line_count() == n, "live: the study screen opened with its audio and %d lines" % n)
	if st != null:
		st.play_line(0)
		await _frames(3)
		ok(st.player.is_playing(), "live: a line plays")
	v.go_back()
	await _frames(3)
	await _wait_loaded(v)
	ok(not _bus_exists() and v.screen == null, "live: the screen is closed and the 'Song' bus is gone")
	v.queue_free()
	await _frames(2)
	_reached["live"] = true
