extends Node
## U4a: SongStudyScreen (틀: 재생 막대 · 탭 전환) + SongListenTab + SongSingTab (docs/song_study_design.md §4.3 §5.4 §5.5 §6 §8 U-9 U-10 U-14).
##   godot --headless --path <project> res://tests/song_study_screen_test.tscn            (PC 1280x800)
##   godot --headless --path <project> res://tests/song_study_screen_test.tscn -- --phone (폰 412x915)
## Exit code 0 = all checks passed. Last line: "== song_study_screen_test result: N passed, 0 failed ==".
## 소리는 가짜 어댑터(자체 시계), 채점 요청은 SpeakDrill.api_hook 또는 가짜 Api(요청 경로 기록), 서버 · 네트워크 없음.
## 가사는 모두 이 파일에서 직접 쓴 문장. 파일은 user://test_song_u4a* 에만 쓰고 끝에 지운다 (진행 · 학습 기록 · 설정도 시험용 경로로 돌렸다가 되돌린다).

const ROOT := "user://test_song_u4a"
const TEST_PROGRESS := "user://test_song_u4a_progress.json"
const TEST_LOG := "user://test_song_u4a_studylog.json"
const TEST_PREFS := "user://test_song_u4a_prefs.json"
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const SID := "s_0123456789ab"
const SID2 := "s_ba9876543210"
const TONE_MP3 := "res://tests/fixtures/song/tone_8s.mp3"
const SECTIONS := ["open", "bar", "list", "word", "tabs", "contract", "sing_hook", "sing_api", "self_rate", "ja", "attribution",
	"leave", "errors", "real_audio", "layout"]

## 가짜 /score 응답 (노래 점수 = (0.6·정확도 + 0.25·또렷함) / 0.85)
const SCORE_HIGH := {"transcript": "the quiet river runs on", "score": 10, "accuracy": 90, "clarity": 80, "fluency": 10,
	"units": [{"t": "the", "ok": true, "conf": 0.9, "heard": null}]}
const SCORE_LOW := {"transcript": "the quiet", "score": 99, "accuracy": 30, "clarity": 20, "fluency": 99,
	"units": [{"t": "the", "ok": false, "conf": 0.2, "heard": "a"}]}

## SongPlayer 어댑터 대역: 자체 시계를 시험이 흘린다.
class Fake:
	extends SongPlayer.Adapter
	var dur: float = 40.0
	var now: float = 0.0
	var running: bool = false
	var paused: bool = false
	var speed: float = 1.0
	var fx_pitch: float = 1.0
	var fx_on: bool = false
	var starts: Array = []
	var halts: int = 0
	var released: bool = false
	var fail: bool = false
	var loaded_path: String = ""

	func load_audio(path: String) -> float:
		loaded_path = path
		if fail:
			err = "fake load failure"
			return 0.0
		return dur

	func start(from: float) -> void:
		now = from
		running = true
		paused = false
		starts.append(from)

	func set_paused(p: bool) -> void:
		paused = p

	func halt() -> void:
		running = false
		halts += 1

	func is_playing() -> bool:
		return running

	func pos() -> float:
		return now

	func set_speed_pitch(s: float, p: float, e: bool) -> void:
		speed = s
		fx_pitch = p
		fx_on = e

	func release() -> void:
		released = true

	func advance(dt: float) -> void:
		if running and not paused:
			now += dt * speed
			if now >= dur:
				now = dur
				running = false


## 탭 위젯 계약 시험용 가짜 탭: 불린 순서를 기록한다.
class ProbeTab:
	extends VBoxContainer
	var calls: Array = []
	var ctx: Dictionary = {}
	var song_arg: Dictionary = {}
	signal song_changed

	func setup(sg: Dictionary, c: Dictionary) -> void:
		song_arg = sg
		ctx = c
		calls.append("setup")

	func on_show() -> void:
		calls.append("on_show")

	func set_line(i: int) -> void:
		calls.append("set_line:%d" % i)

	func on_hide() -> void:
		calls.append("on_hide")


class Gate:
	extends RefCounted
	signal opened


var passed: int = 0
var failed: int = 0
var reached: Dictionary = {}
var score_calls: Array = [] ## api_hook 이 받은 /score 요청 [{method, path, body}]
var hook_paths: Array = []
var score_mode: String = "high"
var hold_gate: Gate = null
var tts_calls: Array = []
var closed_n: int = 0
var finished_counts: Array = []
var phone: bool = false

var _saved_prefs: Dictionary = {}
var _saved_prefs_path: String = ""
var _saved_progress: Dictionary = {}
var _saved_progress_path: String = ""
var _saved_log_path: String = ""
var _saved_base: String = ""
var _saved_mode: String = ""
var _saved_phone_hook: Callable = Callable()
var _saved_overrides: Dictionary = {}
var _saved_root: String = ""
var _saved_songs_root: String = ""
var _orig_api_script: Script = null
var _host: Control = null
var _overflow: Array = []
var _small: Array = []

## api.gd 의 복사본 끝에 붙이는 감시 코드: `_start` 는 모든 요청의 입구라 요청 경로를 기록한다. Route 가 "pc" 일 때만 canned 로 대답한다.
const SPY_TAIL := """

var spy_log: Array = []
var canned: Dictionary = {}


func _start(method: int, path: String, body: Variant, timeout: float, report: bool, base_override: String = "", auth: bool = true) -> ApiCall:
	var p: String = path.split("?")[0]
	spy_log.append(p)
	var m: String = "GET" if method == HTTPClient.METHOD_GET else "POST"
	var bd: Dictionary = body if body is Dictionary else {}
	if canned.has(p) and Route.decide(m, p, bd) == "pc":
		var call_obj := ApiCall.new()
		call_obj.path = path
		active_count += 1
		var res: Dictionary = {"ok": true, "code": 200, "data": canned[p], "bytes": PackedByteArray(), "error": "", "cancelled": false, "err_code": "", "err_body": null}
		_finish_later(call_obj, res, false)
		return call_obj
	return _start_orig(method, path, body, timeout, report, base_override, auth)
"""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== song_study_screen_test start ==")
	phone = Platform.is_phone()
	await _setup()
	await _run()
	_teardown()
	for s in SECTIONS:
		ok(reached.has(s), "section '%s' ran to its end" % s)
	print("== song_study_screen_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup / helpers

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(cond: Callable, max_frames: int = 300) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _setup() -> void:
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_prefs_path = Store.prefs_path
	_saved_progress = Store.progress.duplicate(true)
	_saved_progress_path = Store.progress_path
	_saved_log_path = StudyLog.path
	_saved_base = Api.base_url
	_saved_mode = Route.mode
	_saved_phone_hook = Route.phone_hook
	_saved_overrides = LocalApi.handler_override.duplicate()
	_saved_root = SongStore.root
	_saved_songs_root = SongPlayer.songs_root
	var want := Vector2i(412, 915) if phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(2)
	UiBoot.apply(get_window(), "light", 1.0)
	Store.prefs_path = TEST_PREFS
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	Api.base_url = "http://127.0.0.1:9" # 닫힌 포트: 실수로 8770 서버에 닿지 않게
	SongStore.root = ROOT
	_rm_rf(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	Sheet.animate = false
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")
	_orig_api_script = Api.get_script()
	var spy: GDScript = _make_spy_script()
	ok(spy != null, "spy Api script compiles")
	if spy != null:
		Api.set_script(spy)
		Api.set("canned", {"/score": SCORE_HIGH})
	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	_mode_pc()


func _make_spy_script() -> GDScript:
	var src: String = FileAccess.get_file_as_string("res://scripts/autoload/api.gd")
	if not src.contains("func _start("):
		return null
	var g := GDScript.new()
	g.source_code = src.replace("func _start(", "func _start_orig(") + SPY_TAIL
	if g.reload() != OK:
		return null
	return g


func _teardown() -> void:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	SpeakDrill.api_hook = Callable()
	SpeakDrill.score_hook = Callable()
	SongStudyScreen.tab_factory = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	if _orig_api_script != null:
		Api.set_script(_orig_api_script)
	Api.base_url = _saved_base
	Route.mode = _saved_mode
	Route.phone_hook = _saved_phone_hook
	LocalApi.handler_override = _saved_overrides
	Recorder.owner_id = 0
	Recorder.recording = false
	StudyLog.reset()
	StudyLog.path = _saved_log_path
	Store.progress_path = _saved_progress_path
	Store.progress = _saved_progress
	Store.prefs_path = _saved_prefs_path
	Store.prefs = _saved_prefs
	SongStore.root = _saved_root
	SongPlayer.songs_root = _saved_songs_root
	_rm_rf(ROOT)
	for f in [TEST_PROGRESS, TEST_LOG, TEST_LOG + ".bad", TEST_PREFS, TEST_PROGRESS + ".tmp", TEST_PREFS + ".tmp", TEST_LOG + ".tmp"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	UiBoot.apply(get_window(), "light", 1.0)


func _rm_rf(path: String) -> void:
	var gp: String = ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(gp):
		return
	for f in DirAccess.get_files_at(gp):
		DirAccess.remove_absolute(gp.path_join(f))
	for d in DirAccess.get_directories_at(gp):
		_rm_rf(path.path_join(d))
	DirAccess.remove_absolute(gp)


func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _hook(method: String, path: String, body: Variant) -> Variant:
	hook_paths.append(path)
	if path.begins_with("/score"):
		score_calls.append({"method": method, "path": path, "body": body})
		if hold_gate != null:
			await hold_gate.opened
		return {"ok": true, "code": 200, "data": (SCORE_HIGH if score_mode == "high" else SCORE_LOW).duplicate(true), "error": ""}
	return {"ok": false, "code": 404, "data": null, "error": "no"}


func _spy_log() -> Array:
	return Api.get("spy_log") as Array


func _spy_count(path: String) -> int:
	var n := 0
	for p in _spy_log():
		if str(p) == path:
			n += 1
	return n


func event_count(kind: String) -> int:
	var n := 0
	var days: Dictionary = StudyLog.snapshot()["days"]
	for d in days.values():
		for l in (d as Dictionary).values():
			n += int(((l as Dictionary)["n"] as Dictionary).get(kind, 0))
	return n


## 직접 쓴 가사로 만든 영어 곡. 줄 i 는 t0 = 2 + 4i, 길이 3초, 단어 5개(0.5초 간격).
func _song(n: int, o: Dictionary = {}) -> Dictionary:
	var lines: Array = []
	var ws: Array = ["the", "quiet", "river", "runs", "on"]
	for i in n:
		var t0: float = 2.0 + 4.0 * i
		var words: Array = []
		for k in ws.size():
			var s: float = t0 + 0.2 + 0.5 * k
			words.append({"w": ws[k], "lemma": ws[k], "level": "easy", "zipf": 5.0, "s": s, "e": s + 0.4, "est": false, "content": ws[k] != "the" and ws[k] != "on"})
		lines.append({"i": i, "p": int(i / 4), "t0": t0, "t1": t0 + 3.0, "text": "the quiet river runs on", "reading": "", "pron": "", "ko": "조용한 강이 흘러요", "conf": null, "est": bool(o.get("est_lines", false)), "stale": false, "words": words})
	return {"v": 1, "id": str(o.get("id", SID)), "lang": "en", "title": str(o.get("title", "Test Tune")), "artist": "Test Band", "created": 1,
		"duration": 4.0 * n + 6.0, "audio": {"file": "audio.mp3", "bytes": 1, "sha256": "", "orig_name": "x.mp3"},
		"source": {"lyrics": str(o.get("lyrics", "pasted")), "lrclib_id": null, "timing": str(o.get("timing", "word")), "attribution": str(o.get("attr", ""))},
		"offset": float(o.get("offset", 0.0)), "lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {}, "warnings": [], "app": "test"}


func _song_ja() -> Dictionary:
	var s: Dictionary = _song(3, {"id": SID2})
	s["lang"] = "ja"
	var texts: Array = ["朝の光が差し込む", "ゆっくり歩いていこう", "空は青く澄んでいる"]
	var readings: Array = ["あさのひかりがさしこむ", "ゆっくりあるいていこう", "そらはあおくすんでいる"]
	for i in 3:
		var ln: Dictionary = s["lines"][i]
		ln["text"] = texts[i]
		ln["reading"] = readings[i]
		ln["pron"] = "アサノヒカリガサシコム"
		ln["words"] = []
		ln["ko"] = "해석 %d" % i
	return s


## 가짜 어댑터를 단 화면을 만든다 (open 은 부르는 쪽이).
func _new_screen(fake: Fake) -> SongStudyScreen:
	var s := SongStudyScreen.new()
	s.player.backend = fake
	s.closed.connect(func() -> void: closed_n += 1)
	_host.add_child(s)
	return s


func _open(song: Dictionary, args: Dictionary = {}, fake: Fake = null) -> Array:
	var f: Fake = fake if fake != null else Fake.new()
	f.dur = float(song.get("duration", 40.0))
	var s: SongStudyScreen = _new_screen(f)
	var a: Dictionary = args.duplicate()
	a["song"] = song
	s.open(str(song.get("lang", "en")), a)
	await _frames(4)
	return [s, f]


func _free_screen(s: SongStudyScreen) -> void:
	if s != null and is_instance_valid(s):
		if s.get_parent() != null:
			s.get_parent().remove_child(s)
		s.queue_free()
	await _frames(2)


func _click(c: Control) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = c.size / 2.0
	ev.global_position = c.get_global_rect().get_center()
	c.gui_input.emit(ev)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = ev.position
	up.global_position = ev.global_position
	c.gui_input.emit(up)


func _chip(s: SongStudyScreen, node_name: String) -> Button:
	return s.find_child(node_name, true, false) as Button


func _press(b: Button) -> void:
	if b != null:
		b.pressed.emit()


func _near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func _texts_under(n: Node) -> Array:
	var out: Array = []
	for c in n.find_children("*", "Label", true, false):
		if (c as Label).is_visible_in_tree():
			out.append((c as Label).text)
	return out


func _text_in_tree(n: Node, part: String) -> bool:
	for c in n.find_children("*", "Label", true, false):
		if (c as Label).text.contains(part):
			return true
	return false


func _has_text(n: Node, part: String) -> bool:
	for t in _texts_under(n):
		if str(t).contains(part):
			return true
	return false


func _run() -> void:
	await _t_open_bar_list()
	await _t_word()
	await _t_tabs()
	await _t_sing()
	await _t_self_rate()
	await _t_ja_attr()
	await _t_leave_errors()
	await _t_real_audio()
	await _t_layout()


# ---------------------------------------------------------------- open / bar / list

func _t_open_bar_list() -> void:
	var song: Dictionary = _song(6)
	var r: Array = await _open(song)
	var s: SongStudyScreen = r[0]
	var fake: Fake = r[1]
	# --- open
	ok(s.audio_ok and s.open_error == "", "open: the song loads through the (fake) adapter")
	ok(SongPlayer.songs_root == SongStore.root, "open: SongPlayer.songs_root is SongStore.root")
	ok(fake.loaded_path == "%s/%s/audio.mp3" % [SongStore.root, SID], "open: the adapter was asked for <SongStore.root>/<id>/audio.mp3 (%s)" % fake.loaded_path)
	ok((s._shell["title"] as Label).text == "Test Tune" and (s._shell["count"] as Label).text == "Test Band", "open: the head line shows the title and the artist")
	var tabs: Array = s._tab_row.get_children()
	ok(tabs.size() == 6, "open: six tab chips (%d)" % tabs.size())
	ok(s.tab == "listen" and s.current_tab() is SongListenTab, "open: the first tab is 듣기 (SongListenTab)")
	var lt: SongListenTab = s.current_tab()
	ok(lt.line_count() == 6, "open: six lines listed (%d)" % lt.line_count())
	ok(_has_text(lt, "the quiet river runs on"), "open: the lyric text is shown")
	ok(s._btn_play.text == SongStudyScreen.PLAY_TEXT and not s._btn_play.disabled, "bar: the play button says 재생 and is enabled")
	reached["open"] = true

	# --- play bar: play / pause / resume / stop
	_press(s._btn_play)
	ok(s.player.is_playing() and fake.starts.size() == 1 and _near(fake.starts[0], 0.0), "bar: 재생 with no line chosen plays from the start")
	ok(s._btn_play.text == SongStudyScreen.PAUSE_TEXT, "bar: while playing the button says 일시정지")
	fake.advance(2.5)
	s.player.update()
	_press(s._btn_play)
	ok(s.player.is_paused() and fake.paused, "bar: pressing it again pauses")
	ok(s._btn_play.text == SongStudyScreen.RESUME_TEXT, "bar: paused -> 이어서")
	var starts_before: int = fake.starts.size()
	_press(s._btn_play)
	ok(s.player.is_playing() and not fake.paused and fake.starts.size() == starts_before, "bar: resume continues without restarting the audio")
	_press(s._btn_stop)
	ok(s.player.state() == SongPlayer.State.STOPPED and not fake.running, "bar: 정지 stops the player")
	ok(s._btn_play.text == SongStudyScreen.PLAY_TEXT, "bar: after 정지 the button says 재생 again")

	# --- speed presets, keep pitch
	var chip75: Button = _chip(s, "Speed75")
	ok(chip75 != null, "bar: a 0.75배 preset chip exists")
	_press(chip75)
	ok(_near(s.player.speed, 0.75) and _near(fake.speed, 0.75) and _near(fake.fx_pitch, 1.0 / 0.75, 0.001) and fake.fx_on, "bar: 0.75배 -> player 0.75, effect 1/0.75")
	ok(_near(float(Store.prefs.get("song_speed", 0.0)), 0.75), "bar: song_speed is saved in the prefs")
	_press(_chip(s, "KeepPitch"))
	ok(not s.keep_pitch and not fake.fx_on and _near(fake.fx_pitch, 1.0) and _near(fake.speed, 0.75), "bar: 음높이 유지 off -> effect 1.0 (speed stays)")
	ok(Store.prefs.get("song_keep_pitch", true) == false, "bar: song_keep_pitch false is saved")
	_press(_chip(s, "KeepPitch"))
	ok(s.keep_pitch and fake.fx_on, "bar: 음높이 유지 on again")
	_press(_chip(s, "Speed100"))
	ok(_near(fake.speed, 1.0) and not fake.fx_on, "bar: 1배 -> effect bypassed")
	ok(s.find_child("Speed50", true, false) != null and s.find_child("Speed65", true, false) != null and s.find_child("Speed90", true, false) != null, "bar: all five presets (0.5 0.65 0.75 0.9 1)")

	# --- list: tap a line -> play_line, highlight
	fake.starts.clear()
	var row1: Control = lt.row_panel(1)
	ok(row1 != null, "list: a row for line 1")
	_click(row1)
	ok(s.cur_line == 1 and s.player.is_playing() and s.player.current_line() == 1, "list: tapping line 1 selects and plays it")
	ok(fake.starts.size() == 1 and _near(fake.starts[0], 6.0 - 0.15), "list: the section starts 0.15 s before t0 (%s)" % [fake.starts])
	await _frames(1)
	ok(lt.hl == 1, "list: line 1 is highlighted")
	ok(row1.get_theme_stylebox("panel") == lt._style_cur and lt.row_panel(0).get_theme_stylebox("panel") == lt._style_normal, "list: only the current line has the highlight style")
	ok((lt.rows[1]["label"] as Label).get_theme_font("font") == lt._bold or lt.rows[1]["rtl"] != null, "list: the current line is bold (never colour alone)")

	# continuous play: the highlight follows the position
	_press(s._btn_stop)
	await _frames(1)
	s.select_line(1)
	_press(s._btn_play)
	ok(fake.starts.size() >= 1 and _near(fake.starts.back(), 6.0), "bar: 재생 plays from the chosen line's t0")
	fake.advance(4.6) # 10.6 -> line 2 (t0 10)
	s.player.update()
	await _frames(1)
	ok(s.player.current_line() == 2 and lt.hl == 2, "list: the highlight follows playback to line 2 (hl %d)" % lt.hl)
	fake.advance(4.0) # 14.6 -> line 3
	s.player.update()
	await _frames(1)
	ok(lt.hl == 3, "list: ... and on to line 3")
	_press(s._btn_stop)
	await _frames(1)
	ok(lt.hl == s.cur_line, "list: after 정지 the highlight goes back to the chosen line")

	# prev / next
	s.select_line(2)
	fake.starts.clear()
	_press(s._btn_next)
	ok(s.cur_line == 3 and _near(fake.starts.back(), 14.0 - 0.15), "bar: 다음 줄 plays line 3")
	_press(s._btn_prev)
	ok(s.cur_line == 2 and _near(fake.starts.back(), 10.0 - 0.15), "bar: 이전 줄 plays line 2")
	_press(s._btn_stop)
	s.select_line(0)
	_press(s._btn_prev)
	ok(s.cur_line == 0, "bar: 이전 줄 at the first line stays on it")
	_press(s._btn_stop)

	# --- repeat 1 / 3 / infinite
	ok(s.repeat == 1 and _chip(s, "Repeat1") != null and _chip(s, "Repeat3") != null and _chip(s, "Repeat0") != null, "bar: repeat chips 1회 3회 계속")
	_press(_chip(s, "Repeat3"))
	ok(s.repeat == 3 and int(Store.prefs.get("song_repeat", 0)) == 3, "bar: 3회 is kept and saved")
	finished_counts.clear()
	s.player.finished_loop.connect(func(c: int) -> void: finished_counts.append(c))
	fake.starts.clear()
	_click(lt.row_panel(2))
	ok(s.player.is_playing(), "repeat 3: line 2 plays")
	var guard := 0
	while s.player.is_playing() and guard < 200:
		fake.advance(0.1)
		s.player.update()
		guard += 1
	ok(s.player.loops_done == 3 and finished_counts == [3], "repeat 3: exactly 3 passes and finished_loop(3) once (%d, %s)" % [s.player.loops_done, finished_counts])
	ok(fake.starts.size() == 3, "repeat 3: the audio was started 3 times (%d)" % fake.starts.size())
	_press(_chip(s, "Repeat0"))
	ok(s.repeat == 0, "bar: 계속 selected")
	_click(lt.row_panel(1))
	guard = 0
	while guard < 250:
		fake.advance(0.1)
		s.player.update()
		guard += 1
	ok(s.player.is_playing() and s.player.loops_done >= 5, "repeat 계속: still looping after 5+ passes (%d)" % s.player.loops_done)
	_press(s._btn_stop)
	_press(_chip(s, "Repeat1"))

	# --- recording blocks the song
	fake.starts.clear()
	Recorder.recording = true
	s.play_line(4)
	ok(fake.starts.is_empty() and not s.player.is_playing(), "bar: while recording no line is played")
	s.toggle_play()
	ok(fake.starts.is_empty(), "bar: while recording 재생 does nothing")
	Recorder.recording = false
	reached["bar"] = true

	# --- auto scroll on a long song
	await _free_screen(s)
	var long_song: Dictionary = _song(60)
	var r2: Array = await _open(long_song)
	var s2: SongStudyScreen = r2[0]
	var f2: Fake = r2[1]
	var lt2: SongListenTab = s2.current_tab()
	var pg: ScrollContainer = s2._shell["page"]
	ok(pg.scroll_vertical == 0, "scroll: starts at the top")
	s2.select_line(0)
	_click(lt2.row_panel(0))
	f2.now = 0.0
	s2.player.play_from(2.0 + 4.0 * 45 + 0.5) # jump far down -> line 45
	f2.now = 2.0 + 4.0 * 45 + 0.5
	s2.player.update()
	await _frames(4)
	ok(lt2.hl == 45, "scroll: the highlight is on line 45 (%d)" % lt2.hl)
	var pr: Rect2 = pg.get_global_rect()
	var rr: Rect2 = lt2.row_panel(45).get_global_rect()
	ok(pg.scroll_vertical > 0 and pr.intersects(rr) and rr.position.y >= pr.position.y - 1.0 and rr.end.y <= pr.end.y + 1.0, "scroll: the page followed to show line 45 (scroll %d)" % pg.scroll_vertical)
	reached["list"] = true
	await _free_screen(s2)


# ---------------------------------------------------------------- word highlight

func _t_word() -> void:
	var r: Array = await _open(_song(6))
	var s: SongStudyScreen = r[0]
	var fake: Fake = r[1]
	var lt: SongListenTab = s.current_tab()
	s.select_line(2)
	_press(s._btn_play) # from t0 of line 2 = 10.0
	fake.now = 10.0 + 0.2 + 0.5 * 1 + 0.1 # inside "quiet"
	s.player.update()
	await _frames(1)
	ok(lt.hl == 2 and lt.word_highlight_on(), "word: a timed song turns the word highlight on")
	ok(lt.active_word == 1, "word: 'quiet' is the active word (%d)" % lt.active_word)
	var rtl: RichTextLabel = lt.rows[2]["rtl"]
	ok(rtl != null and rtl.text.contains("[b]") and rtl.text.contains("quiet[/color]"), "word: the active word is bold in the line text")
	fake.now = 10.0 + 0.2 + 0.5 * 3 + 0.1
	s.player.update()
	await _frames(1)
	ok(lt.active_word == 3 and lt.rows[2]["rtl"].text.contains("runs[/color]"), "word: ... then 'runs'")
	fake.now = 10.0 + 2.9 # after the last word
	s.player.update()
	await _frames(1)
	ok(lt.active_word == -1, "word: between words nothing is bold")
	_press(s._btn_stop)
	await _frames(1)
	var mix: int = 0
	for i in lt.rows.size():
		if lt.rows[i]["rtl"] != null and i != lt.hl:
			mix += 1
	ok(mix == 0, "word: only the current line carries the word text")
	await _free_screen(s)

	# estimated times: the highlight is off (U-9)
	var r2: Array = await _open(_song(6, {"timing": "est"}))
	var s2: SongStudyScreen = r2[0]
	var f2: Fake = r2[1]
	var lt2: SongListenTab = s2.current_tab()
	s2.select_line(2)
	_press(s2._btn_play)
	f2.now = 10.0 + 0.2 + 0.5 * 1 + 0.1
	s2.player.update()
	await _frames(1)
	ok(lt2.hl == 2 and not lt2.word_highlight_on(), "est song: the word highlight is off")
	ok(lt2.rows[2]["rtl"] == null and lt2.active_word == -1, "est song: no per-word text is made")
	ok(_has_text(lt2, "추정"), "est song: the list says the times are estimated")
	await _free_screen(s2)
	# one estimated line in an otherwise timed song
	var mixed: Dictionary = _song(6)
	(mixed["lines"][2] as Dictionary)["est"] = true
	var r3: Array = await _open(mixed)
	var s3: SongStudyScreen = r3[0]
	var lt3: SongListenTab = s3.current_tab()
	ok(lt3.word_highlight_on(1) and not lt3.word_highlight_on(2), "est line: only the estimated line has no word highlight")
	await _free_screen(s3)
	reached["word"] = true


# ---------------------------------------------------------------- tabs

func _t_tabs() -> void:
	var r: Array = await _open(_song(6))
	var s: SongStudyScreen = r[0]
	var lt: SongListenTab = s.current_tab()
	_press(_chip(s, "Tab_sing"))
	await _frames(2)
	ok(s.tab == "sing" and s.current_tab() is SongSingTab, "tabs: 따라 부르기 shows SongSingTab")
	ok(not lt.visible and s.current_tab().visible, "tabs: the listen tab is hidden, the sing tab visible")
	ok(Store.prefs.get("song_last_tab", "") == "sing", "tabs: song_last_tab is saved")
	for k in ["words", "cloze", "dictation", "meaning"]:
		s.show_tab(k)
		await _frames(1)
		var node: Control = s.current_tab()
		var file_there: bool = ResourceLoader.exists(SongStudyScreen.TAB_SCRIPTS[k])
		ok(node != null and s.tab == k and (node.has_meta("placeholder") != file_there), "tabs: '%s' shows %s" % [k, "its tab" if file_there else "the 준비 중 placeholder"])
	s.show_tab("bogus")
	ok(s.tab == "meaning", "tabs: an unknown tab name is ignored")
	s.show_tab("listen")
	ok(lt.visible and s.tab == "listen", "tabs: back to 듣기")
	await _free_screen(s)
	# reopen: the last tab comes back
	Store.prefs["song_last_tab"] = "sing"
	var r2: Array = await _open(_song(6))
	ok((r2[0] as SongStudyScreen).tab == "sing", "tabs: opening again starts on the last tab (pref)")
	await _free_screen(r2[0])
	var r3: Array = await _open(_song(6), {"tab": "listen"})
	ok((r3[0] as SongStudyScreen).tab == "listen", "tabs: args.tab beats the pref")
	await _free_screen(r3[0])
	reached["tabs"] = true

	# --- the tab widget contract, with a probe tab for 'words'
	var probe_made: Array = []
	SongStudyScreen.tab_factory = func(kind: String) -> Control:
		if kind == "words":
			var p := ProbeTab.new()
			probe_made.append(p)
			return p
		return null
	var r4: Array = await _open(_song(6), {"tab": "listen"})
	var s4: SongStudyScreen = r4[0]
	s4.select_line(2)
	s4.show_tab("words")
	await _frames(1)
	var probe: ProbeTab = probe_made[0] if not probe_made.is_empty() else null
	ok(probe != null and s4.current_tab() == probe, "contract: tab_factory supplies the tab")
	if probe == null:
		await _free_screen(s4)
		SongStudyScreen.tab_factory = Callable()
		return
	ok(probe.calls == ["setup", "on_show"], "contract: setup then on_show (%s)" % [probe.calls])
	var keys_ok := true
	for k in ["lang", "player", "screen", "line", "save"]:
		keys_ok = keys_ok and probe.ctx.has(k)
	ok(keys_ok, "contract: opts has lang player screen line save")
	ok(is_same(probe.song_arg, s4.song), "contract: setup(song, opts) gets the live song object, not a copy")
	ok(probe.ctx["screen"] == s4 and probe.ctx["player"] == s4.player and int(probe.ctx["line"]) == 2, "contract: opts.player is the screen's SongPlayer, opts.line the chosen line")
	ok(probe.ctx["save"] is Callable and (probe.ctx["save"] as Callable).is_valid(), "contract: ctx.save is a valid Callable")
	s4.select_line(3)
	ok(probe.calls.back() == "set_line:3", "contract: set_line(3) when the chosen line changes (%s)" % [probe.calls])
	s4.select_line(3)
	var n_calls: int = probe.calls.size()
	ok(n_calls == 3, "contract: choosing the same line again does not call set_line again")
	s4.show_tab("listen")
	ok(probe.calls.back() == "on_hide" and not probe.visible, "contract: on_hide when another tab opens, tab hidden")
	s4.show_tab("words")
	ok(probe.calls.count("setup") == 1 and probe.calls.back() == "on_show", "contract: the tab is kept, setup only once, on_show again")
	s4.on_hide()
	ok(probe.calls.back() == "on_hide", "contract: leaving the screen calls on_hide of the tabs")
	# song_changed: the list is drawn again with the new text
	var lt4: SongListenTab = s4.tab_nodes["listen"]
	Store.prefs["show_ko"] = true
	(s4.song["lines"][1] as Dictionary)["ko"] = "고친 해석"
	probe.song_changed.emit()
	await _frames(1)
	ok(lt4.line_count() == 6 and _text_in_tree(lt4, "고친 해석"), "contract: song_changed redraws the line list (new text appears)")
	Store.prefs["show_ko"] = false
	SongStudyScreen.tab_factory = Callable()

	# the dictation tab hides the lyric list (no answers on screen)
	var r6: Array = await _open(_song(6), {"tab": "listen"})
	var s6: SongStudyScreen = r6[0]
	ok(s6.lyrics_visible() and _has_text(s6, "the quiet river runs on"), "dictation: on 듣기 the lyric list is visible")
	s6.show_tab("dictation")
	await _frames(2)
	ok(not s6.lyrics_visible(), "dictation: while the dictation tab is open the lyric list is hidden")
	ok(not _has_text(s6, "the quiet river runs on"), "dictation: no lyric text is visible anywhere on the screen")
	s6.show_tab("sing")
	s6.show_tab("dictation")
	await _frames(1)
	ok(not s6.lyrics_visible(), "dictation: still hidden after coming back from another tab")
	s6.show_tab("listen")
	await _frames(1)
	ok(s6.lyrics_visible(), "dictation: 듣기 shows the list again")
	await _free_screen(s6)
	reached["contract"] = true


# ---------------------------------------------------------------- sing (api_hook)

func _score_n() -> int:
	return score_calls.size()


func _t_sing() -> void:
	StudyLog.reset()
	score_calls.clear()
	hook_paths.clear()
	_mode_pc()
	var r: Array = await _open(_song(6), {"tab": "sing"})
	var s: SongStudyScreen = r[0]
	var fake: Fake = r[1]
	var tab: SongSingTab = s.current_tab()
	ok(tab != null and tab.drill != null and tab.drill is SongSingDrill and tab.drill.source == "song", "sing: the tab uses SongSingDrill")
	ok(not tab.drill.show_prosody, "sing: no prosody")
	ok(tab.line == 0 and tab.current_text() == "the quiet river runs on", "sing: starts on line 1")
	ok(tab.drill.target == "the quiet river runs on" and tab.drill.lang == "en", "sing: the drill target is the line")
	ok(not _has_text(tab, "스스로 평가"), "sing (PC): no self-rating note")

	# listen to the line with the song player
	fake.starts.clear()
	tab.listen_line()
	ok(s.player.is_playing() and fake.starts.size() == 1 and _near(fake.starts[0], 2.0 - 0.15), "sing: '이 줄 듣기' plays the line through SongPlayer")

	# a good take
	score_mode = "high"
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return tab.drill.status == "ok")
	ok(_score_n() == 1 and tab.drill.status == "ok", "sing: one recording -> exactly one /score request (%d)" % _score_n())
	ok(str(score_calls[0]["body"].get("target", "")) == "the quiet river runs on" and not hook_paths.has("/prosody"), "sing: /score gets the line text, and /prosody is not asked")
	ok(int(tab.drill.result.get("score", -1)) == SongStudy.song_score(SCORE_HIGH) and SongStudy.song_score(SCORE_HIGH) == 87, "sing: the score is the song score (87), not the server's 10")
	ok(event_count("shadow") == 1 and tab.shadow_events == 1 and tab.passed_lines.has(0), "sing: a pass (87 >= 70) adds one 'shadow' event")
	ok(tab.find_child("PassMark", true, false) != null, "sing: the pass is marked on the line")
	# the same line passes again: no second event
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return _score_n() == 2 and tab.drill.status == "ok")
	ok(event_count("shadow") == 1 and tab.shadow_events == 1, "sing: the same line passing again adds no second event")
	# a bad take on line 2
	tab.go_line(1)
	await _frames(1)
	ok(tab.line == 1 and s.cur_line == 1 and tab.drill.status == "idle", "sing: next line -> the screen's chosen line follows, the old result is cleared")
	score_mode = "low"
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return _score_n() == 3 and tab.drill.status == "ok")
	ok(int(tab.drill.result.get("score", -1)) == SongStudy.song_score(SCORE_LOW) and SongStudy.song_score(SCORE_LOW) < 70, "sing: the low take scores under 70 (%d)" % int(tab.drill.result.get("score", -1)))
	ok(event_count("shadow") == 1 and not tab.passed_lines.has(1), "sing: a score under 70 adds no event")
	score_mode = "high"
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return _score_n() == 4 and tab.drill.status == "ok")
	ok(event_count("shadow") == 2 and tab.passed_lines.size() == 2, "sing: line 2 passing -> the second event")
	# the screen's choice moves the tab
	s.select_line(4)
	ok(tab.line == 4 and tab.drill.target == "the quiet river runs on", "sing: a line chosen elsewhere moves the sing tab")
	ok(event_count("drill") == 0 and event_count("dictation") == 0, "sing: no other event kinds are added")

	# the song stops right before the microphone starts
	s.select_line(2)
	s.play_line(2)
	ok(s.player.is_playing(), "pause: the song plays")
	Recorder.owner_id = tab.recorder.get_instance_id()
	Recorder.started.emit()
	ok(fake.paused and s.player.is_paused() and tab.pause_calls == 1, "pause: SongPlayer.pause() when this tab's recorder starts")
	Recorder.owner_id = 0
	s.player.resume()
	Recorder.owner_id = 987654
	Recorder.started.emit()
	ok(s.player.is_playing() and tab.pause_calls == 1, "pause: another owner's recording does not pause the song")
	Recorder.owner_id = 0
	s.stop_play()

	# leaving the tab mid-scoring drops the answer
	hold_gate = Gate.new()
	var ev0: int = event_count("shadow")
	tab.go_line(5)
	await _frames(1)
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return tab.drill.status == "scoring")
	ok(tab.drill.status == "scoring", "leave: the take is being scored")
	s.show_tab("listen")
	await _frames(1)
	ok(tab.drill.status == "idle", "leave: switching tabs cancels the scoring")
	var g: Gate = hold_gate
	hold_gate = null
	g.opened.emit()
	await _frames(3)
	ok(tab.drill.status == "idle" and event_count("shadow") == ev0, "leave: a late answer is dropped, no event")
	reached["sing_hook"] = true
	await _free_screen(s)

	# the Api level: /score is sent once through Api (PC), nothing else
	SpeakDrill.api_hook = Callable()
	Api.set("spy_log", [])
	Api.set("canned", {"/score": SCORE_HIGH.duplicate(true)})
	StudyLog.reset()
	var r2: Array = await _open(_song(6), {"tab": "sing"})
	var s2: SongStudyScreen = r2[0]
	var tab2: SongSingTab = s2.current_tab()
	tab2.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return tab2.drill.status == "ok")
	ok(_spy_count("/score") == 1, "sing (Api): PC connected -> one /score request through Api (%d)" % _spy_count("/score"))
	ok(_spy_count("/prosody") == 0, "sing (Api): no /prosody request")
	ok(event_count("shadow") == 1, "sing (Api): the pass adds one event")
	await _free_screen(s2)
	SpeakDrill.api_hook = Callable(self, "_hook")
	reached["sing_api"] = true


# ---------------------------------------------------------------- self rating (phone alone)

func _t_self_rate() -> void:
	StudyLog.reset()
	SpeakDrill.api_hook = Callable()
	Api.set("spy_log", [])
	_mode_none()
	ok(SelfRatePanel.needed(), "self: with no PC and no phone STT, scoring has nowhere to go (SelfRatePanel.needed)")
	var r: Array = await _open(_song(6), {"tab": "sing"})
	var s: SongStudyScreen = r[0]
	var tab: SongSingTab = s.current_tab()
	ok(_has_text(tab, "스스로 평가"), "self: the tab tells the user it is self-rating")
	tab.drill._on_recorded(FAKE_REC)
	await _frames(2)
	ok(tab.drill.status == "self", "self: a take opens the self-rating panel")
	ok(_spy_count("/score") == 0 and _spy_log().filter(func(p: Variant) -> bool: return str(p).begins_with("/score") or str(p).begins_with("/prosody")).is_empty(), "self: /score and /prosody requests = 0")
	var panel: SelfRatePanel = tab.drill.find_child("SelfRatePanel", true, false) as SelfRatePanel
	ok(panel != null, "self: the SelfRatePanel is shown")
	ok(event_count("shadow") == 0, "self: nothing recorded before rating")
	panel._btn_again.pressed.emit()
	await _frames(1)
	ok(tab.drill.status == "idle" and event_count("shadow") == 0 and tab.passed_lines.is_empty(), "self: '다시' records nothing")
	tab.drill._on_recorded(FAKE_REC)
	await _frames(2)
	panel = tab.drill.find_child("SelfRatePanel", true, false) as SelfRatePanel
	panel._btn_good.pressed.emit()
	await _frames(1)
	ok(tab.drill.status == "self_ok", "self: '잘했어요' is accepted")
	ok(event_count("shadow") == 1 and tab.shadow_events == 1 and int(tab.passed_lines.get(0, -1)) == SelfRatePanel.GOOD_SCORE, "self: '잘했어요' counts as a pass: one shadow event")
	ok(_spy_count("/score") == 0, "self: still no /score request after rating")
	# the same line again: no second event
	tab.drill._on_recorded(FAKE_REC)
	await _frames(2)
	panel = tab.drill.find_child("SelfRatePanel", true, false) as SelfRatePanel
	panel._btn_good.pressed.emit()
	await _frames(1)
	ok(event_count("shadow") == 1, "self: rating the same line again adds no second event")
	ok(_spy_count("/score") == 0 and tts_calls.size() >= 0, "self: /score count is still 0")
	await _free_screen(s)
	_mode_pc()
	Api.set("spy_log", [])
	SpeakDrill.api_hook = Callable(self, "_hook")
	reached["self_rate"] = true


# ---------------------------------------------------------------- japanese, attribution

func _t_ja_attr() -> void:
	StudyLog.reset()
	score_calls.clear()
	Store.prefs["show_reading"] = true
	Store.prefs["show_hangul_ja"] = true
	var r: Array = await _open(_song_ja(), {"tab": "listen", "id": SID2})
	var s: SongStudyScreen = r[0]
	var lt: SongListenTab = s.current_tab()
	ok(s.lang == "ja" and lt.lang == "ja", "ja: the song's language wins over the one passed to open()")
	ok(_has_text(lt, "朝の光が差し込む") and _has_text(lt, "あさのひかりがさしこむ"), "ja: text and hiragana reading are listed (show_reading)")
	Store.prefs["show_ko"] = true
	s.show_tab("sing")
	await _frames(2)
	var tab: SongSingTab = s.current_tab()
	ok(tab.drill.lang == "ja" and tab.drill.reading == "あさのひかりがさしこむ" and tab.drill.target == "朝の光が差し込む", "ja: the drill gets text and hiragana reading")
	ok(_has_text(tab, "해석 0"), "ja: the Korean line shows when show_ko is on")
	tab.drill._on_recorded(FAKE_REC)
	await _wait(func() -> bool: return tab.drill.status == "ok")
	ok(score_calls.size() == 1 and str(score_calls[0]["body"].get("lang", "")) == "ja" and str(score_calls[0]["body"].get("reading", "")) == "あさのひかりがさしこむ", "ja: /score gets lang ja and the reading")
	ok(event_count("shadow") == 1, "ja: a pass adds a shadow event for the song's language")
	Store.prefs["show_ko"] = false
	reached["ja"] = true
	await _free_screen(s)

	# attribution (U-14)
	var lr: Dictionary = _song(6, {"lyrics": "lrclib", "attr": "가사: LRCLIB (lrclib.net) · 시험용 문구"})
	var r2: Array = await _open(lr)
	var s2: SongStudyScreen = r2[0]
	var holder: Control = s2._shell["footer_holder"]
	var lab: Label = s2.find_child("Attribution", true, false) as Label
	ok(holder.visible and lab != null and lab.is_visible_in_tree() and lab.text == "가사: LRCLIB (lrclib.net) · 시험용 문구", "attr: an LRCLIB song shows its attribution under the content")
	var tabs_ok := true
	for k in ["sing", "words", "cloze", "dictation", "meaning", "listen"]:
		s2.show_tab(k)
		await _frames(1)
		tabs_ok = tabs_ok and lab.is_visible_in_tree()
	ok(tabs_ok, "attr: it stays visible on every tab")
	await _free_screen(s2)
	var lr2: Dictionary = _song(6, {"lyrics": "lrclib", "attr": ""})
	var r3: Array = await _open(lr2)
	var lab3: Label = (r3[0] as SongStudyScreen).find_child("Attribution", true, false) as Label
	ok(lab3 != null and lab3.text == SongStudyScreen.DEFAULT_ATTRIBUTION, "attr: an LRCLIB song with no stored text gets the standard sentence")
	await _free_screen(r3[0])
	var r4: Array = await _open(_song(6, {"lyrics": "pasted"}))
	var s4: SongStudyScreen = r4[0]
	ok(not (s4._shell["footer_holder"] as Control).visible and s4.find_child("Attribution", true, false) == null, "attr: a pasted-lyrics song shows no attribution line")
	await _free_screen(s4)
	reached["attribution"] = true


# ---------------------------------------------------------------- leaving, errors

func _t_leave_errors() -> void:
	closed_n = 0
	var r: Array = await _open(_song(6))
	var s: SongStudyScreen = r[0]
	var fake: Fake = r[1]
	s.select_line(1)
	s.play_line(1)
	ok(s.player.is_playing(), "leave: playing")
	s.on_hide()
	ok(not s.player.is_playing() and not fake.running and s.player.state() == SongPlayer.State.STOPPED, "leave: on_hide() stops the song")
	s.play_line(2)
	ok(s.go_back() and closed_n == 1 and not s.player.is_playing(), "leave: go_back() stops the song and emits closed once")
	s.play_line(2)
	fake.released = false
	await _free_screen(s)
	ok(fake.released and not fake.running, "leave: freeing the screen releases the audio (adapter.release)")

	# open by id through SongStore
	var song: Dictionary = _song(4, {"title": "Stored Tune"})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SongStore.song_dir(SID)))
	ok(SongStore.save_song(song), "store: the test song is saved in the test folder")
	var f2 := Fake.new()
	f2.dur = 40.0
	var s2: SongStudyScreen = _new_screen(f2)
	s2.open("en", {"id": SID})
	await _frames(3)
	ok(s2.audio_ok and (s2._shell["title"] as Label).text == "Stored Tune", "store: open({id}) reads the song through SongStore")
	ok(f2.loaded_path == "%s/%s/audio.mp3" % [ROOT, SID], "store: the audio path is under the test SongStore.root")
	await _free_screen(s2)

	# errors
	var s3: SongStudyScreen = _new_screen(Fake.new())
	s3.open("en", {"id": "s_aaaaaaaaaaaa"})
	await _frames(2)
	ok(s3.open_error != "" and _has_text(s3, "곡을 열 수 없어요"), "errors: an unknown song id shows a notice, no crash")
	ok(s3._btn_play.disabled and s3._btn_next.disabled, "errors: the transport is disabled with no song")
	s3.open("en", {"song": {}})
	await _frames(1)
	ok(s3.open_error != "", "errors: an empty song dict shows the notice too")
	s3.open("en", {"song": "not a dict"})
	await _frames(1)
	ok(s3.open_error != "", "errors: a non-dictionary song is the same notice")
	await _free_screen(s3)

	var bad := Fake.new()
	bad.fail = true
	var r4: Array = await _open(_song(6), {}, bad)
	var s4: SongStudyScreen = r4[0]
	ok(not s4.audio_ok and _has_text(s4, "fake load failure"), "errors: a broken audio file shows the player's message")
	ok(s4._btn_play.disabled and s4._btn_prev.disabled and s4._btn_stop.disabled, "errors: the transport buttons are disabled")
	var lt4: SongListenTab = s4.current_tab()
	_click(lt4.row_panel(1))
	s4.toggle_play()
	ok(bad.starts.is_empty() and not s4.player.is_playing(), "errors: tapping a line / 재생 plays nothing")
	ok(s4.cur_line == 1 and lt4.line_count() == 6, "errors: the lyrics can still be read and a line chosen")
	await _free_screen(s4)

	var empty_song: Dictionary = _song(0)
	var r5: Array = await _open(empty_song)
	ok(_has_text(r5[0], "가사 줄이 없어요"), "errors: a song with no lines says so")
	(r5[0] as SongStudyScreen).show_tab("sing")
	await _frames(2)
	ok(_has_text(r5[0], "가사 줄이 없어요"), "errors: the sing tab with no lines does not crash")
	(r5[0] as SongStudyScreen).step_line(1)
	await _free_screen(r5[0])
	reached["leave"] = true
	reached["errors"] = true


# ---------------------------------------------------------------- real audio adapter (headless dummy driver)

func _t_real_audio() -> void:
	var gp: String = ProjectSettings.globalize_path(SongStore.song_dir(SID))
	DirAccess.make_dir_recursive_absolute(gp)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(TONE_MP3)
	ok(bytes.size() > 1000, "real: the test tone mp3 is readable")
	var f := FileAccess.open(SongStore.audio_path(SID), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	var master_fx: int = AudioServer.get_bus_effect_count(0)
	var buses_before: int = AudioServer.bus_count
	var song: Dictionary = _song(2)
	song["duration"] = 8.0
	var s := SongStudyScreen.new() # the real AudioAdapter
	_host.add_child(s)
	s.open("en", {"song": song})
	await _frames(3)
	ok(s.audio_ok and s.player.is_loaded(), "real: the real adapter loads the tone mp3 through songs_root")
	ok(AudioServer.get_bus_index("Song") >= 0 and AudioServer.bus_count == buses_before + 1, "real: the 'Song' bus exists while the screen is open")
	s.play_line(0)
	await _frames(3)
	ok(s.player.is_playing(), "real: a line plays")
	s.set_speed(0.75)
	ok(_near(s.player.speed, 0.75), "real: speed is applied")
	await _free_screen(s)
	ok(AudioServer.get_bus_index("Song") == -1 and AudioServer.bus_count == buses_before, "real: leaving removes the 'Song' bus")
	ok(AudioServer.get_bus_effect_count(0) == master_fx, "real: the Master bus effects are untouched")
	reached["real_audio"] = true


# ---------------------------------------------------------------- layout

## 새 화면의 보이는 컨트롤을 훑는다: 창 가로 밖으로 나간 것, (폰) 눌러 쓰기에 작은 버튼, 내용 열이 쪽보다 넓은 것.
func _scan(root: Control, state: String, touch_min: float) -> int:
	var w: float = get_viewport().get_visible_rect().size.x
	var n := 0
	for c in root.find_children("*", "Control", true, false):
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var rect: Rect2 = ctl.get_global_rect()
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		n += 1
		if rect.end.x > w + 0.5 or rect.position.x < -0.5:
			_overflow.append("%s: %s %s end.x=%.1f" % [state, root.get_path_to(ctl), ctl.get_class(), rect.end.x])
		if phone and (ctl is BaseButton) and (rect.size.y < touch_min or rect.size.x < touch_min):
			_small.append("%s: %s %s '%s' (%.0fx%.0f)" % [state, root.get_path_to(ctl), ctl.get_class(), (ctl as Button).text if ctl is Button else "", rect.size.x, rect.size.y])
	for pg in root.find_children("*", "PageScroll", true, false):
		var page := pg as PageScroll
		if page.is_visible_in_tree() and page.column.size.x > page.size.x + 0.5:
			_overflow.append("%s: page content %.1f wider than the page %.1f" % [state, page.column.size.x, page.size.x])
	return n


func _t_layout() -> void:
	var touch_min: float = 47.5
	var combos: Array = [["listen", false], ["sing", false]]
	# self-check: the scan must report a wide control, a 20 px button and a column wider than the page
	var rs: Array = await _open(_song(6))
	var ss: SongStudyScreen = rs[0]
	var o0: int = _overflow.size()
	var s0: int = _small.size()
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(get_viewport().get_visible_rect().size.x + 300.0, 10)
	ss.add_child(wide)
	var tiny := Button.new()
	tiny.text = "tiny"
	tiny.custom_minimum_size = Vector2(20, 20)
	ss.add_child(tiny)
	await _frames(2)
	_scan(ss, "selfcheck", touch_min)
	var got_o: int = _overflow.size() - o0
	var got_s: int = _small.size() - s0
	wide.queue_free()
	tiny.queue_free()
	_overflow.resize(o0)
	_small.resize(s0)
	ok(got_o >= 1, "layout self-check: a control wider than the window is reported (%d)" % got_o)
	if phone:
		ok(got_s >= 1, "layout self-check: a 20 px button is reported as small (%d)" % got_s)
	await _free_screen(ss)

	var states: Array = []
	for scale in ([1.0, 1.5] if phone else [1.0]):
		UiBoot.apply(get_window(), "light", scale)
		await _frames(2)
		for st in combos:
			StudyLog.reset()
			_mode_pc()
			var r: Array = await _open(_song(8, {"lyrics": "lrclib", "attr": "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"}), {"tab": st[0]})
			var s: SongStudyScreen = r[0]
			s.select_line(2)
			await _frames(3)
			var nn: int = _scan(s, "%s@%s" % [st[0], scale], touch_min)
			states.append("%s@%s=%d" % [st[0], scale, nn])
			ok(nn > 10, "layout %s @%sx: the scan looked at %d controls" % [st[0], scale, nn])
			await _free_screen(s)
		# self-rating state (the tallest sing tab) and a japanese song
		_mode_none()
		SpeakDrill.api_hook = Callable()
		var r2: Array = await _open(_song(8), {"tab": "sing"})
		var s2: SongStudyScreen = r2[0]
		var tab2: SongSingTab = s2.current_tab()
		tab2.drill._on_recorded(FAKE_REC)
		await _frames(3)
		_scan(s2, "self@%s" % scale, touch_min)
		await _free_screen(s2)
		_mode_pc()
		SpeakDrill.api_hook = Callable(self, "_hook")
		Store.prefs["show_ko"] = true
		var r3: Array = await _open(_song_ja(), {"tab": "listen"})
		await _frames(2)
		_scan(r3[0], "ja@%s" % scale, touch_min)
		(r3[0] as SongStudyScreen).show_tab("sing")
		await _frames(3)
		_scan(r3[0], "ja-sing@%s" % scale, touch_min)
		Store.prefs["show_ko"] = false
		await _free_screen(r3[0])
	UiBoot.apply(get_window(), "light", 1.0)
	print("LAYOUT states: ", states)
	for line in _overflow.slice(0, 30):
		print("  overflow  ", line)
	for line in _small.slice(0, 30):
		print("  small     ", line)
	print("LAYOUT_OVERFLOW_COUNT ", _overflow.size())
	print("TOUCH_SMALL_COUNT ", _small.size())
	ok(_overflow.size() == 0, "layout: nothing sticks out of the window, no content wider than its page (%s)" % ("phone 412 px" if phone else "pc 1280 px"))
	ok(_small.size() == 0, "layout: every button is a touch target >= %s px (phone only)" % touch_min)
	reached["layout"] = true
