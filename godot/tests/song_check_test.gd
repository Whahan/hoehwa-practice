extends Node
## 노래 공부 U3: SongCheckScreen (가사 확인·수정 화면). 서버·마이크·실제 오디오를 쓰지 않는다 (가짜 SongPlayer 어댑터).
##   PC:   godot --headless --path <project> res://tests/song_check_test.tscn
##   폰:   godot --headless --path <project> res://tests/song_check_test.tscn -- --phone
##   변조: ... -- --tamper=time|stale|order|marks|est|save   (일부러 틀린 값을 끼워 넣는다: 시험이 FAIL 해야 한다)
## Exit code 0 = all passed. Last line: "== song_check_test result: N passed, M failed =="
## 저장은 user://test_songs_u3 에만 한다 (SongStore.root 를 바꿔서). 가사는 직접 쓴 문장이고 오디오는 가짜 바이트다.
## 편집 연산마다 독립적으로 쓴 불변식 검사기(inv)를 돌린다: 0<=t0<t1<=duration, t0 오름차순, 줄 1..400, 글자 1..200,
## 단어 시간·marks·stats.best 범위, 오프셋 0.05 단위. 검사기가 틀린 곡을 실제로 잡는지도 먼저 확인한다.

const ROOT := "user://test_songs_u3"
const LONG_HINT := "ran to the end"

var passed: int = 0
var failed: int = 0
var tamper: String = ""
var host: Control = null
var _reached_end: bool = false
var _phone: bool = false
var _vp: Vector2 = Vector2(1280, 800)
var _closed_n: int = 0
var _saved_n: int = 0
var _scr: SongCheckScreen = null


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


## 시험용 가짜 소리 쪽: 자기 시계, 시험이 앞으로 돌린다.
class Fake:
	extends SongPlayer.Adapter
	var dur: float = 40.0
	var now: float = 0.0
	var running: bool = false
	var paused: bool = false
	var speed: float = 1.0
	var starts: Array = []
	var loads: int = 0
	var halts: int = 0
	var released: bool = false
	var fail: bool = false
	var loaded_path: String = ""

	func load_audio(path: String) -> float:
		loads += 1
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

	func set_speed_pitch(s: float, _p: float, _e: bool) -> void:
		speed = s

	func release() -> void:
		released = true

	func advance(dt: float) -> void:
		if running and not paused:
			now += dt * speed
			if now >= dur:
				now = dur
				running = false


# ---------------------------------------------------------------- fixtures

func _audio(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = (i * 31 + 7) & 255
	return b


func _words(text: String, t0: float, t1: float) -> Array:
	var out: Array = []
	var toks: PackedStringArray = text.split(" ", false)
	var step: float = (t1 - t0) / maxf(1.0, float(toks.size()))
	for k in toks.size():
		out.append({"w": toks[k], "lemma": toks[k].to_lower(), "level": "easy", "zipf": 5.0, "s": t0 + step * k, "e": t0 + step * (k + 1),
			"est": false, "content": true})
	return out


func _line(i: int, text: String, t0: float, t1: float, conf: Variant = 0.9, est: bool = false) -> Dictionary:
	return {"i": i, "p": 0, "t0": t0, "t1": t1, "text": text, "reading": "", "pron": "", "ko": "한국어 %d" % i, "conf": conf,
		"est": est, "stale": false, "words": _words(text, t0, t1)}


const LYRICS_EN := ["The morning light is soft and low", "I walk along the quiet road", "Every step feels like a song",
	"And I sing it all night long", "Hold the lantern high tonight", "Let the river carry me home",
	"Stars are falling on the water", "I will never feel alone"]


func _song(lang: String = "en", warnings: Array = [], confs: Array = [], ests: Array = []) -> Dictionary:
	var ls: Array = []
	for i in LYRICS_EN.size():
		var t0: float = 2.0 + 4.0 * i
		var conf: Variant = confs[i] if i < confs.size() else 0.9
		var est: bool = ests[i] if i < ests.size() else false
		var txt: String = LYRICS_EN[i]
		ls.append(_line(i, txt, t0, t0 + 3.5, conf, est))
	return {"v": 1, "lang": lang, "title": "Test Song", "artist": "Tester", "created": 1790000000, "duration": 40.0,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "x.m4a"},
		"source": {"lyrics": "asr", "lrclib_id": null, "timing": "line", "attribution": ""},
		"offset": 0.0, "lines": ls, "glossary": {},
		"marks": {"lines": [1, 3, 6], "words": []},
		"stats": {"plays": 2, "last": 0, "best": {"0": 50, "1": 80, "3": 60, "6": 90}},
		"warnings": warnings, "app": "1.4.0"}


## 곡을 설치하고 화면을 연다. 가짜 플레이어를 달아서 넘긴다.
func _open_song(song: Dictionary = {}, lang: String = "en") -> Dictionary:
	var s: Dictionary = song if not song.is_empty() else _song()
	var inst: Dictionary = SongStore.install(s, _audio(1500))
	var id: String = str(inst.get("id", ""))
	var fake := Fake.new()
	var scr := SongCheckScreen.new()
	host.add_child(scr)
	scr.player = SongPlayer.new()
	scr.player.backend = fake
	host.add_child(scr.player)
	_closed_n = 0
	_saved_n = 0
	scr.closed.connect(func() -> void: _closed_n += 1)
	scr.saved.connect(func(_i: String) -> void: _saved_n += 1)
	scr.open(lang, {"song_id": id})
	_scr = scr
	return {"scr": scr, "fake": fake, "id": id, "ok": bool(inst.get("ok", false))}


func _close_scr(d: Dictionary) -> void:
	var scr: SongCheckScreen = d["scr"]
	while Sheet.close_top("dismiss"):
		pass
	if scr.player != null and is_instance_valid(scr.player):
		host.remove_child(scr.player)
		scr.player.free()
	host.remove_child(scr)
	scr.free()


func _read_text(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	return FileAccess.get_file_as_string(p)


func _rm_rf(path: String) -> void:
	var gp: String = _g(path)
	var d := DirAccess.open(gp)
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(gp.path_join(fn))
	DirAccess.remove_absolute(gp)


func _btn(scr: Node, nm: String) -> Button:
	return scr.find_child(nm, true, false) as Button


func _press(scr: Node, nm: String) -> bool:
	var b: Button = _btn(scr, nm)
	if b == null or b.disabled:
		return false
	b.pressed.emit()
	return true


# ---------------------------------------------------------------- the invariant checker (written independently of SongModel)

func inv(song: Dictionary) -> Array:
	var errs: Array = []
	if not (song.get("lines", null) is Array):
		return ["lines is not an array"]
	var ls: Array = song["lines"]
	var dur: float = float(song.get("duration", 0.0))
	if dur <= 0.0:
		errs.append("duration <= 0")
	if ls.size() < 1 or ls.size() > 400:
		errs.append("line count %d" % ls.size())
	var prev: float = -1.0
	for i in ls.size():
		var ln: Dictionary = ls[i]
		var t0: float = float(ln.get("t0", -1.0))
		var t1: float = float(ln.get("t1", -1.0))
		if is_nan(t0) or is_nan(t1) or is_inf(t0) or is_inf(t1):
			errs.append("line %d: time not finite" % i)
			continue
		if t0 < 0.0:
			errs.append("line %d: t0 %.3f < 0" % [i, t0])
		if not (t0 < t1):
			errs.append("line %d: t0 %.3f !< t1 %.3f" % [i, t0, t1])
		if t1 > dur + 0.000001:
			errs.append("line %d: t1 %.3f > duration %.3f" % [i, t1, dur])
		if t0 < prev - 0.000001:
			errs.append("line %d: t0 %.3f before previous %.3f" % [i, t0, prev])
		prev = t0
		if int(ln.get("i", -1)) != i:
			errs.append("line %d: i == %s" % [i, str(ln.get("i"))])
		var tx: String = str(ln.get("text", ""))
		if tx.strip_edges() == "" or tx.length() > 200:
			errs.append("line %d: text length %d" % [i, tx.length()])
		for w in (ln.get("words", []) as Array):
			var s: float = float((w as Dictionary).get("s", 0.0))
			var e: float = float((w as Dictionary).get("e", 0.0))
			if s < 0.0 or e < s or e > dur + 0.000001:
				errs.append("line %d: word time %.3f..%.3f" % [i, s, e])
	var off: float = float(song.get("offset", 0.0))
	if off < -5.0 or off > 5.0 or absf(roundf(off / 0.05) * 0.05 - off) > 0.000001:
		errs.append("offset %.4f" % off)
	var last: int = -1
	for x in ((song.get("marks", {}) as Dictionary).get("lines", []) as Array):
		var xi: int = int(x)
		if xi < 0 or xi >= ls.size() or xi <= last:
			errs.append("marks.lines %d" % xi)
		last = xi
	var best: Dictionary = (song.get("stats", {}) as Dictionary).get("best", {})
	for k in best.keys():
		var ki: int = int(str(k))
		if ki < 0 or ki >= ls.size() or int(best[k]) < 0 or int(best[k]) > 100:
			errs.append("stats.best[%s]" % str(k))
	return errs


## 화면의 working 곡 하나를 검사한다: 불변식 + normalize 를 한 번 더 거쳐도 그대로(이미 정규화된 모양).
func _check(scr: SongCheckScreen, name: String) -> void:
	var errs: Array = inv(scr.working)
	var fixed: bool = JSON.stringify(SongModel.normalize(scr.working), "", true) == JSON.stringify(scr.working, "", true)
	ok(errs.is_empty() and fixed, "invariants after %s%s" % [name, "" if errs.is_empty() else " -> " + "; ".join(errs).left(160)])


func _texts(scr: SongCheckScreen) -> Array:
	var out: Array = []
	for ln in scr.lines():
		out.append((ln as Dictionary)["text"])
	return out


func _line_of(scr: SongCheckScreen, i: int) -> Dictionary:
	return (scr.lines()[i] as Dictionary)


# ---------------------------------------------------------------- start

func _ready() -> void:
	print("== song_check_test start ==")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tamper="):
			tamper = a.substr(9)
	_phone = Platform.is_phone()
	_vp = Vector2(412, 915) if _phone else Vector2(1280, 800)
	print("mode: %s tamper='%s'" % ["phone" if _phone else "pc", tamper])
	if Vector2i(get_window().size) != Vector2i(_vp):
		get_window().min_size = Vector2i.ZERO
		get_window().size = Vector2i(_vp)
		await _frames(2)
	UiBoot.apply(get_window(), "light", 1.0)
	Sheet.animate = false
	SongStore.root = ROOT
	_rm_rf(ROOT)
	host = Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	await _frames(2)

	_test_checker_self()
	_test_open()
	_test_text()
	_test_times()
	_test_merge_split_delete()
	_test_offset_revert()
	_test_fuzz()
	await _test_save()
	_test_player()
	_test_suspect()
	_test_readonly()
	_test_ui_paths()
	_test_big_song()
	await _test_layout()
	_reached_end = true
	ok(_reached_end, LONG_HINT)
	while Sheet.close_top("dismiss"):
		pass
	SongStore.write_hook = Callable()
	SongStore.rename_fail = false
	_rm_rf(ROOT)
	print("== song_check_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- tests

func _test_checker_self() -> void:
	var base: Dictionary = _song()
	ok(inv(base).is_empty(), "checker: a good song has no violations")
	var a: Dictionary = base.duplicate(true)
	a["lines"][2]["t1"] = a["lines"][2]["t0"]
	ok(not inv(a).is_empty(), "checker catches t1 == t0")
	a = base.duplicate(true)
	a["lines"][2]["t0"] = 100.0
	a["lines"][2]["t1"] = 101.0
	ok(not inv(a).is_empty(), "checker catches t1 > duration (and out-of-order t0)")
	a = base.duplicate(true)
	a["lines"][3]["t0"] = 1.0
	a["lines"][3]["t1"] = 2.0
	ok(not inv(a).is_empty(), "checker catches a line starting before the previous one")
	a = base.duplicate(true)
	a["lines"][0]["t0"] = -0.5
	ok(not inv(a).is_empty(), "checker catches a negative start")
	a = base.duplicate(true)
	a["lines"][1]["text"] = "  "
	ok(not inv(a).is_empty(), "checker catches an empty text")
	a = base.duplicate(true)
	a["marks"]["lines"] = [1, 99]
	ok(not inv(a).is_empty(), "checker catches marks.lines out of range")
	a = base.duplicate(true)
	a["offset"] = 0.123
	ok(not inv(a).is_empty(), "checker catches an offset that is not a multiple of 0.05")
	a = base.duplicate(true)
	a["lines"][4]["words"][0]["e"] = 99.0
	ok(not inv(a).is_empty(), "checker catches a word time past the duration")


func _test_open() -> void:
	SongStore.write_hook = Callable()
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var fake: Fake = d["fake"]
	ok(bool(d["ok"]), "fixture song installed")
	ok(scr.line_count() == 8 and scr.song_id == str(d["id"]), "open(): 8 lines of the stored song")
	ok(not scr.is_dirty() and scr.selected == -1 and scr.result == "", "open(): clean, nothing selected")
	ok(fake.loaded_path == SongStore.audio_path(str(d["id"])), "the player loads <SongStore.root>/<id>/audio.mp3 (%s)" % fake.loaded_path)
	ok(scr.audio_ready and SongPlayer.songs_root == SongStore.root, "player ready; songs_root == SongStore.root")
	_check(scr, "open")
	ok(scr.find_children("Row*", "PanelContainer", true, false).size() == 8, "8 line rows are shown")
	ok(_btn(scr, "BtnRevert").disabled, "[변경 취소] is disabled while nothing changed")
	ok(_btn(scr, "BtnSave") != null and not _btn(scr, "BtnSave").disabled and _btn(scr, "BtnSave").text == "저장하고 공부하기", "[저장하고 공부하기] is there")
	_close_scr(d)
	# a song that does not exist -> a message, no crash, nothing to save
	var scr2 := SongCheckScreen.new()
	host.add_child(scr2)
	scr2.open("en", {"song_id": "s_000000000000"})
	ok(scr2.load_error != "" and scr2.working.is_empty() and not scr2.is_dirty(), "a missing song shows a message instead of a list")
	ok(not scr2.set_text(0, "x") and not scr2.save() and scr2.line_count() == 0, "nothing can be edited or saved without a song")
	host.remove_child(scr2)
	scr2.free()


func _test_text() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var before: Array = scr.lines().duplicate(true)
	ok(scr.set_text(2, "Every step is a new song"), "set_text returns true")
	if tamper == "stale":
		_line_of(scr, 2)["stale"] = false
	ok(_line_of(scr, 2)["text"] == "Every step is a new song" and _line_of(scr, 2)["stale"] == true, "edited text -> stale:true")
	var others_same := true
	for i in [0, 1, 3, 4, 5, 6, 7]:
		others_same = others_same and JSON.stringify(_line_of(scr, i), "", true) == JSON.stringify(before[i], "", true)
	ok(others_same, "no other line changed")
	ok(_line_of(scr, 2)["t0"] == before[2]["t0"] and _line_of(scr, 2)["t1"] == before[2]["t1"] and _line_of(scr, 2)["ko"] == before[2]["ko"], "times and the old translation of the edited line are kept")
	ok(scr.is_dirty(), "dirty after an edit")
	_check(scr, "set_text")
	ok(scr.set_text(3, "And I sing it all night long") and not bool(_line_of(scr, 3)["stale"]), "the same text again does not mark stale")
	ok(scr.set_text(3, "  And I sing it all night long  ") and not bool(_line_of(scr, 3)["stale"]), "only spaces around -> not stale")
	ok(not scr.set_text(1, "   ") and _line_of(scr, 1)["text"] == "I walk along the quiet road", "an empty text is refused, the line is kept")
	ok(scr.set_text(1, "x".repeat(300)) and str(_line_of(scr, 1)["text"]).length() == 200, "a 300 character text is cut to 200")
	ok(scr.set_text(4, "Hold\nthe\tlantern") and not str(_line_of(scr, 4)["text"]).contains("\n"), "control characters are removed")
	ok(not scr.set_text(-1, "a") and not scr.set_text(8, "a") and not scr.set_text(99, "a"), "a bad line number is refused")
	_check(scr, "set_text series")
	_close_scr(d)


func _test_times() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var fake: Fake = d["fake"]
	var w_s0: float = float(_line_of(scr, 2)["words"][0]["s"])
	ok(scr.set_line_start(2, 10.5), "set_line_start returns true")
	ok(is_equal_approx(float(_line_of(scr, 2)["t0"]), 10.5), "start is 10.5")
	ok(is_equal_approx(float(_line_of(scr, 2)["words"][0]["s"]), w_s0 + 0.5), "the line's word times moved with the start")
	ok(is_equal_approx(float(_line_of(scr, 2)["t1"]), 13.5), "the end stays when the start moves inside the line")
	_check(scr, "set_line_start")
	ok(scr.nudge_line_start(2, 0.1) and is_equal_approx(float(_line_of(scr, 2)["t0"]), 10.6), "+0.1 s -> 10.6 (no float drift)")
	for k in 7:
		scr.nudge_line_start(2, 0.1)
	ok(is_equal_approx(float(_line_of(scr, 2)["t0"]), 11.3), "eight +0.1 steps -> 11.3 exactly")
	ok(scr.nudge_line_start(2, -0.1) and is_equal_approx(float(_line_of(scr, 2)["t0"]), 11.2), "-0.1 s works")
	_check(scr, "nudge_line_start")
	# the neighbours limit it: line 2 stays between line 1 (6.0) and line 3 (14.0), the order never changes
	var texts: Array = _texts(scr)
	ok(scr.set_line_start(2, 100.0) and is_equal_approx(float(_line_of(scr, 2)["t0"]), 14.0), "start past the next line is held at the next line's start")
	if tamper == "order":
		var t: Variant = _line_of(scr, 2)["t0"]
		_line_of(scr, 2)["t0"] = _line_of(scr, 3)["t0"] + 1.0
		_line_of(scr, 2)["t1"] = _line_of(scr, 2)["t0"] + 1.0
	ok(_texts(scr) == texts, "the line order (texts) did not change")
	_check(scr, "start clamped at the next line")
	ok(scr.set_line_start(2, -5.0) and is_equal_approx(float(_line_of(scr, 2)["t0"]), 6.0), "start before the previous line is held at the previous line's start")
	_check(scr, "start clamped at the previous line")
	ok(scr.set_line_start(0, -3.0) and is_equal_approx(float(_line_of(scr, 0)["t0"]), 0.0), "the first line cannot start before 0")
	ok(scr.set_line_start(7, 999.0) and float(_line_of(scr, 7)["t0"]) <= 40.0 - SongModel.MIN_LINE + 0.0001 and float(_line_of(scr, 7)["t1"]) <= 40.0 + 0.0001, "the last line cannot go past the song end")
	_check(scr, "last line at the song end")
	ok(not scr.set_line_start(1, NAN) and not scr.set_line_start(1, INF) and not scr.set_line_end(1, NAN), "NaN / infinity are refused")
	# end
	ok(scr.set_line_end(1, 7.0) and is_equal_approx(float(_line_of(scr, 1)["t1"]), 7.0), "set_line_end 7.0")
	ok(scr.set_line_end(1, 1.0) and is_equal_approx(float(_line_of(scr, 1)["t1"]), float(_line_of(scr, 1)["t0"]) + SongModel.MIN_LINE), "an end before the start is held 0.1 s after the start")
	ok(scr.set_line_end(1, 999.0) and is_equal_approx(float(_line_of(scr, 1)["t1"]), 40.0), "an end past the song is held at the duration")
	ok(scr.nudge_line_end(1, -0.1) and is_equal_approx(float(_line_of(scr, 1)["t1"]), 39.9), "nudge_line_end -0.1")
	_check(scr, "set_line_end")
	# the start moves past the end: the line length is kept
	var d2: Dictionary = _open_song()
	var s2: SongCheckScreen = d2["scr"]
	var len0: float = float(_line_of(s2, 2)["t1"]) - float(_line_of(s2, 2)["t0"])
	s2.set_line_start(2, 13.9)
	ok(float(_line_of(s2, 2)["t1"]) > float(_line_of(s2, 2)["t0"]) and is_equal_approx(float(_line_of(s2, 2)["t1"]) - float(_line_of(s2, 2)["t0"]), len0), "a start moved past the end keeps the line length")
	_check(s2, "start past the end")
	_close_scr(d2)
	# "지금 위치": the player position (song time) - the offset is subtracted
	var d3: Dictionary = _open_song()
	var s3: SongCheckScreen = d3["scr"]
	var f3: Fake = d3["fake"]
	s3.player.play_from(12.34)
	s3.player.pause()
	ok(s3.set_line_start_now(3) and is_equal_approx(float(_line_of(s3, 3)["t0"]), 12.34), "start = the position the player stopped at (12.34)")
	s3.player.play_from(16.0)
	s3.player.pause()
	ok(s3.set_line_end_now(3) and is_equal_approx(float(_line_of(s3, 3)["t1"]), 16.0), "end = the position (16.0)")
	_check(s3, "start/end = now")
	s3.set_song_offset(0.5)
	s3.seek(13.0)
	s3.player.pause()
	ok(is_equal_approx(f3.now, 13.5) and s3.set_line_start_now(3) and is_equal_approx(float(_line_of(s3, 3)["t0"]), 13.0), "with offset 0.5 the audio is at 13.5 but 'now' is song time 13.0")
	_check(s3, "now with offset")
	_close_scr(d3)
	_close_scr(d)


func _test_merge_split_delete() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var a: Dictionary = _line_of(scr, 1).duplicate(true)
	var b: Dictionary = _line_of(scr, 2).duplicate(true)
	ok(scr.merge_lines(1), "merge_lines(1) returns true")
	if tamper == "time":
		_line_of(scr, 1)["t1"] = float(_line_of(scr, 1)["t0"]) - 1.0
	if tamper == "est":
		_line_of(scr, 1)["est"] = false
	ok(scr.line_count() == 7, "7 lines after a merge")
	var m: Dictionary = _line_of(scr, 1)
	ok(m["text"] == str(a["text"]) + " " + str(b["text"]), "merged text = both texts joined by a space (en)")
	ok(is_equal_approx(float(m["t0"]), float(a["t0"])) and is_equal_approx(float(m["t1"]), maxf(float(a["t1"]), float(b["t1"]))), "merged times = [first start, later end]")
	ok(m["est"] == true and m["stale"] == true, "merged line: est:true and stale:true")
	ok((m["words"] as Array).size() == (a["words"] as Array).size() + (b["words"] as Array).size(), "merged line keeps both lines' words")
	ok(_line_of(scr, 2)["text"] == LYRICS_EN[3], "the line after the pair moved up")
	ok((scr.working["marks"]["lines"] as Array) == [1, 2, 5], "marks.lines [1,3,6] -> [1,2,5]")
	ok((scr.working["stats"]["best"] as Dictionary) == {"0": 50, "2": 60, "5": 90}, "stats.best follows the lines; the merged lines' best is dropped (%s)" % str(scr.working["stats"]["best"]))
	_check(scr, "merge")
	ok(not scr.merge_lines(6) and not scr.merge_lines(-1) and not scr.merge_lines(99) and scr.line_count() == 7, "merging the last line / a bad index is refused")
	# two long lines do not merge (200 character limit)
	var d2: Dictionary = _open_song()
	var s2: SongCheckScreen = d2["scr"]
	s2.set_text(0, "a".repeat(150))
	s2.set_text(1, "b".repeat(150))
	var before_json: String = JSON.stringify(s2.working, "", true)
	ok(not s2.merge_lines(0) and JSON.stringify(s2.working, "", true) == before_json, "a merge over 200 characters is refused and changes nothing")
	_close_scr(d2)
	# Japanese: no space
	var d3: Dictionary = _open_song({}, "ja")
	var s3: SongCheckScreen = d3["scr"]
	s3.set_text(0, "朝の光")
	s3.set_text(1, "静かな道")
	ok(s3.lang == "en" or s3.lang == "ja", "language comes from the song")
	_close_scr(d3)
	var js: Dictionary = _song("ja")
	js["lines"][0]["text"] = "朝の光"
	js["lines"][1]["text"] = "静かな道"
	var d4: Dictionary = _open_song(js, "ja")
	var s4: SongCheckScreen = d4["scr"]
	ok(s4.lang == "ja" and s4.merge_lines(0) and _line_of(s4, 0)["text"] == "朝の光静かな道", "Japanese lines are joined without a space")
	_check(s4, "ja merge")
	_close_scr(d4)

	# split
	var orig: Dictionary = _line_of(scr, 0).duplicate(true)
	var n0: int = scr.line_count()
	ok(scr.split_line(0, 11), "split_line(0, 11) returns true")
	ok(scr.line_count() == n0 + 1, "one more line after a split")
	var l: Dictionary = _line_of(scr, 0)
	var r: Dictionary = _line_of(scr, 1)
	ok(l["text"] == "The morning" and r["text"] == "light is soft and low", "split at the character 11: '%s' | '%s'" % [l["text"], r["text"]])
	ok(is_equal_approx(float(l["t0"]), float(orig["t0"])) and is_equal_approx(float(r["t1"]), float(orig["t1"])) and is_equal_approx(float(l["t1"]), float(r["t0"])), "the halves cover the old time span without a gap")
	ok(float(l["t1"]) > float(l["t0"]) and float(r["t1"]) > float(r["t0"]), "both halves have a positive length")
	ok(l["est"] == true and r["est"] == true and l["stale"] == true and r["stale"] == true, "split halves: est:true, stale:true")
	ok(l["ko"] == "" and r["ko"] == "" and l["reading"] == "", "split halves have no (old) translation / reading")
	ok((l["words"] as Array).size() + (r["words"] as Array).size() == (orig["words"] as Array).size(), "words are split, none lost or doubled")
	var lw: Array = []
	for w in (l["words"] as Array):
		lw.append(w["w"])
	ok(lw == ["The", "morning"], "the left half has the words 'The morning' (%s)" % str(lw))
	ok((scr.working["marks"]["lines"] as Array) == [2, 3, 6] and not (scr.working["stats"]["best"] as Dictionary).has("0") and (scr.working["stats"]["best"] as Dictionary).get("3", 0) == 60, "marks and best move down by one; the split line's best is dropped (%s %s)" % [str(scr.working["marks"]["lines"]), str(scr.working["stats"]["best"])])
	_check(scr, "split")
	ok(scr.split_line(2, -1) and scr.line_count() == n0 + 2, "split without a position cuts at a space near the middle")
	ok(_line_of(scr, 2)["text"] + " " + _line_of(scr, 3)["text"] == "I walk along the quiet road Every step feels like a song", "auto split keeps the text (as a merged line it was '%s')" % _line_of(scr, 2)["text"])
	_check(scr, "auto split")
	# too short to split
	scr.set_line_start(5, float(_line_of(scr, 5)["t0"]))
	scr.set_line_end(5, float(_line_of(scr, 5)["t0"]) + 0.1)
	var short_before: String = JSON.stringify(scr.working, "", true)
	ok(not scr.split_line(5, 5) and JSON.stringify(scr.working, "", true) == short_before, "a 0.1 s line cannot be split")
	ok(scr.split_line(0, 0), "split at 0 falls back to the middle")
	_check(scr, "split series")

	# delete
	var d5: Dictionary = _open_song()
	var s5: SongCheckScreen = d5["scr"]
	ok(s5.delete_line(2), "delete_line(2)")
	ok(s5.line_count() == 7 and _line_of(s5, 2)["text"] == LYRICS_EN[3], "7 lines, the next line took its place")
	ok((s5.working["marks"]["lines"] as Array) == [1, 2, 5], "marks.lines [1,3,6] -> [1,2,5]")
	ok((s5.working["stats"]["best"] as Dictionary) == {"0": 50, "1": 80, "2": 60, "5": 90}, "stats.best moved with the lines (%s)" % str(s5.working["stats"]["best"]))
	if tamper == "marks":
		s5.working["marks"]["lines"] = [1, 2, 12]
	_check(s5, "delete")
	ok(s5.delete_line(1), "delete a marked line")
	ok((s5.working["marks"]["lines"] as Array) == [1, 4] and (s5.working["stats"]["best"] as Dictionary) == {"0": 50, "1": 60, "4": 90}, "deleting a marked line drops its mark and best (%s %s)" % [str(s5.working["marks"]["lines"]), str(s5.working["stats"]["best"])])
	_check(s5, "delete a marked line")
	ok(not s5.delete_line(-1) and not s5.delete_line(50), "a bad index is refused")
	while s5.line_count() > 1:
		s5.delete_line(0)
	ok(s5.line_count() == 1 and not s5.delete_line(0), "the last line cannot be deleted")
	_check(s5, "delete down to one line")
	_close_scr(d5)
	_close_scr(d)


func _test_offset_revert() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var snap: String = JSON.stringify(scr.working, "", true)
	var t_before: Array = []
	for ln in scr.lines():
		t_before.append([ln["t0"], ln["t1"]])
	ok(scr.set_song_offset(0.5) and is_equal_approx(float(scr.working["offset"]), 0.5), "offset 0.5")
	ok(scr.set_song_offset(7.0) and float(scr.working["offset"]) == 5.0, "offset is held at +5")
	ok(scr.set_song_offset(-9.0) and float(scr.working["offset"]) == -5.0, "offset is held at -5")
	ok(scr.set_song_offset(0.123) and is_equal_approx(float(scr.working["offset"]), 0.1), "offset is snapped to 0.05 steps (0.123 -> 0.10)")
	ok(scr.nudge_song_offset(0.1) and is_equal_approx(float(scr.working["offset"]), 0.2), "nudge_song_offset +0.1")
	ok(not scr.set_song_offset(NAN) and is_equal_approx(float(scr.working["offset"]), 0.2), "NaN offset refused")
	var t_after: Array = []
	for ln in scr.lines():
		t_after.append([ln["t0"], ln["t1"]])
	ok(t_before == t_after, "the offset does not change any line time")
	_check(scr, "offset")
	# revert brings everything back
	scr.set_text(0, "Changed")
	scr.merge_lines(2)
	scr.delete_line(4)
	ok(scr.is_dirty(), "dirty before revert")
	scr.revert()
	ok(JSON.stringify(scr.working, "", true) == snap and not scr.is_dirty(), "revert(): the song equals the state at open, not dirty")
	_check(scr, "revert")
	ok(_btn(scr, "BtnRevert").disabled, "[변경 취소] disabled again")
	_close_scr(d)


func _test_fuzz() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var bad: Array = []
	var applied: int = 0
	var per_op: Dictionary = {}
	for step in 400:
		var n: int = scr.line_count()
		var i: int = rng.randi_range(-1, n)
		var op: int = rng.randi_range(0, 9)
		var res: bool = false
		match op:
			0:
				res = scr.set_text(i, ["", " ", "new words here", "x".repeat(rng.randi_range(1, 260)), "日本語の歌詞 です"][rng.randi_range(0, 4)])
			1:
				res = scr.set_line_start(i, rng.randf_range(-5.0, 46.0))
			2:
				res = scr.set_line_end(i, rng.randf_range(-5.0, 46.0))
			3:
				res = scr.nudge_line_start(i, rng.randf_range(-3.0, 3.0))
			4:
				res = scr.nudge_line_end(i, rng.randf_range(-3.0, 3.0))
			5:
				res = scr.merge_lines(i)
			6:
				res = scr.split_line(i, rng.randi_range(-1, 40))
			7:
				res = scr.delete_line(i)
			8:
				res = scr.set_song_offset(rng.randf_range(-8.0, 8.0))
			9:
				res = scr.nudge_song_offset(rng.randf_range(-1.0, 1.0))
		if res:
			applied += 1
			per_op[op] = int(per_op.get(op, 0)) + 1
		var errs: Array = inv(scr.working)
		var fixed: bool = JSON.stringify(SongModel.normalize(scr.working), "", true) == JSON.stringify(scr.working, "", true)
		if not errs.is_empty() or not fixed:
			bad.append("step %d op %d line %d: %s" % [step, op, i, "; ".join(errs).left(120) if not errs.is_empty() else "not normalized"])
			break
	ok(bad.is_empty(), "fuzz: 400 random edit operations all keep the invariants%s" % ("" if bad.is_empty() else " -> " + str(bad)))
	ok(applied >= 150, "fuzz: %d operations were applied (>= 150)" % applied)
	var kinds: int = 0
	for k in per_op.keys():
		if int(per_op[k]) > 0:
			kinds += 1
	ok(kinds == 10, "fuzz: every kind of operation was applied at least once (%d/10)" % kinds)
	# the file produced by saving after the fuzz is valid as well
	ok(scr.save(), "the fuzzed song can be saved")
	var back: Dictionary = SongStore.load_song(str(d["id"]))
	ok(inv(back).is_empty() and JSON.stringify(back, "", true) == JSON.stringify(scr.working, "", true), "the saved file passes the invariants and equals the screen's song")
	_close_scr(d)


func _test_save() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var id: String = str(d["id"])
	var path: String = SongStore.song_dir(id).path_join("song.json")
	# nothing changed -> nothing written
	var calls: Array = [0]
	SongStore.write_hook = func(_p: String) -> bool:
		calls[0] += 1
		return true
	ok(scr.save() and calls[0] == 0, "save() with no change writes nothing")
	scr.set_text(2, "Every step is a new song")
	scr.merge_lines(5)
	scr.set_song_offset(0.25)
	scr.set_line_start(1, 6.4)
	ok(scr.save() and calls[0] >= 1, "save() writes the song")
	SongStore.write_hook = Callable()
	var back: Dictionary = SongStore.load_song(id)
	ok(back["lines"].size() == 7 and back["lines"][2]["text"] == "Every step is a new song" and back["lines"][2]["stale"] == true, "the file has the edited text and stale:true")
	ok(back["lines"][5]["est"] == true and back["lines"][5]["stale"] == true and is_equal_approx(float(back["offset"]), 0.25) and is_equal_approx(float(back["lines"][1]["t0"]), 6.4), "the file has the merged line (est/stale), the offset and the new start")
	ok(inv(back).is_empty(), "the saved file passes the invariants")
	ok(not scr.is_dirty() and _btn(scr, "BtnRevert").disabled, "not dirty after saving")
	scr.set_text(0, "After the save")
	scr.revert()
	ok(_line_of(scr, 0)["text"] == LYRICS_EN[0] and scr.line_count() == 7, "revert() after a save goes back to the saved song, not the first one")
	_close_scr(d)

	# [저장하고 공부하기] closes with saved
	var d2: Dictionary = _open_song()
	var s2: SongCheckScreen = d2["scr"]
	s2.set_text(0, "Saved by the button")
	ok(_press(s2, "BtnSave"), "[저장하고 공부하기] pressed")
	ok(_saved_n == 1 and _closed_n == 1 and s2.result == "saved", "saved(song_id) once, then closed once, result == saved")
	ok(SongStore.load_song(str(d2["id"]))["lines"][0]["text"] == "Saved by the button", "the button saved the text")
	_close_scr(d2)

	# a failing write keeps the old data and tells the user
	var d3: Dictionary = _open_song()
	var s3: SongCheckScreen = d3["scr"]
	var id3: String = str(d3["id"])
	var p3: String = SongStore.song_dir(id3).path_join("song.json")
	var disk_before: String = _read_text(p3)
	ok(disk_before != "", "the stored song.json exists before the failing save")
	s3.set_text(1, "This must not reach the disk")
	s3.merge_lines(3)
	var work_before: String = JSON.stringify(s3.working, "", true)
	SongStore.write_hook = func(_p: String) -> bool: return false
	var res: bool = s3.save()
	var disk_after: String = _read_text(p3)
	if tamper == "save":
		var f := FileAccess.open(p3, FileAccess.WRITE)
		f.store_string("{broken")
		f.close()
		disk_after = _read_text(p3)
	ok(not res, "save() returns false when the write fails")
	ok(disk_after == disk_before, "the stored song.json is byte for byte the old one after a failed write")
	ok(not FileAccess.file_exists(p3 + ".tmp"), "no half-written .tmp file is left")
	ok(s3.save_error != "" and s3.find_child("SaveError", true, false) != null, "the user is told (SaveError banner)")
	ok(s3.is_dirty() and JSON.stringify(s3.working, "", true) == work_before, "the screen keeps the unsaved edits")
	ok(_press(s3, "BtnSave") and _closed_n == 0 and _saved_n == 0 and s3.result == "", "pressing [저장하고 공부하기] on a failing disk does not leave the screen")
	ok(SongStore.load_song(id3)["lines"][1]["text"] == LYRICS_EN[1], "load_song() still returns the old lyrics")
	# the rename can fail as well
	SongStore.write_hook = Callable()
	SongStore.rename_fail = true
	ok(not s3.save() and _read_text(p3) == disk_before and s3.is_dirty(), "a failing rename keeps the old file and the edits too")
	SongStore.rename_fail = false
	ok(s3.save(), "after the disk works again the same edits can be saved")
	ok(s3.save_error == "" and s3.find_child("SaveError", true, false) == null, "the error banner is gone after a successful save")
	ok(SongStore.load_song(id3)["lines"][1]["text"] == "This must not reach the disk", "the retry wrote the edits")
	_close_scr(d3)


func _test_player() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var fake: Fake = d["fake"]
	var loads0: int = fake.loads
	scr.select_line(2)
	fake.starts.clear()
	scr.preview_line(2)
	var t0: float = float(_line_of(scr, 2)["t0"])
	ok(fake.starts.size() == 1 and absf(float(fake.starts[0]) - (t0 - SongPlayer.PRE_ROLL)) < 0.001, "preview plays the line from t0 - 0.15 (%s)" % str(fake.starts))
	ok(scr.player.is_playing() and scr.player.current_line() == 2, "the player plays line 2 (play_line)")
	ok(fake.loads == loads0, "no reload while the times are unchanged")
	# play to the end of the section: it stops, finished_loop
	fake.advance(10.0)
	scr.player.update()
	ok(not scr.player.is_playing(), "the line preview stops by itself")
	scr.preview_line(2)
	ok(fake.loads == loads0, "a second preview does not reload")
	# an edited time is heard
	scr.set_line_start(2, t0 + 1.0)
	scr.preview_line(2)
	ok(fake.loads == loads0 + 1, "an edited start makes the screen reload the song into the player")
	ok(absf(float(fake.starts.back()) - (t0 + 1.0 - SongPlayer.PRE_ROLL)) < 0.001, "the preview starts at the new start (%s)" % str(fake.starts.back()))
	scr.set_song_offset(0.5)
	scr.preview_line(2)
	ok(fake.loads == loads0 + 2 and absf(float(fake.starts.back()) - (t0 + 1.0 + 0.5 - SongPlayer.PRE_ROLL)) < 0.001, "an offset change is heard too (%s)" % str(fake.starts.back()))
	# transport
	scr.player.stop()
	scr.toggle_play()
	ok(scr.player.is_playing(), "▶ plays")
	scr.toggle_play()
	ok(scr.player.is_paused(), "a second press pauses")
	scr.toggle_play()
	ok(scr.player.is_playing(), "a third press resumes")
	scr.seek(5.0)
	ok(absf(float(fake.starts.back()) - 5.5) < 0.001, "seek(5.0) plays from song time 5.0 (audio 5.5 with the offset)")
	scr.on_hide()
	ok(scr.player.is_paused(), "on_hide() pauses the player")
	_btn(scr, "BtnPlay").pressed.emit()
	ok(scr.player.is_playing(), "the play button works")
	var tl: Label = scr.find_child("TimeLabel", true, false)
	ok(tl != null and tl.text.contains("/"), "the position label is shown (%s)" % (tl.text if tl != null else ""))
	_close_scr(d)
	# the audio fails to load: the screen still edits
	var s: Dictionary = _song()
	var inst: Dictionary = SongStore.install(s, _audio(900))
	var fk := Fake.new()
	fk.fail = true
	var scr2 := SongCheckScreen.new()
	host.add_child(scr2)
	scr2.player = SongPlayer.new()
	scr2.player.backend = fk
	host.add_child(scr2.player)
	scr2.open("en", {"song_id": str(inst["id"])})
	ok(not scr2.audio_ready and scr2.audio_error != "", "a failing audio load is reported (%s)" % scr2.audio_error)
	ok(scr2.set_text(0, "Still editable") and _btn(scr2, "BtnPlay").disabled, "editing works without sound; the play button is off")
	scr2.preview_line(0)
	ok(fk.starts.is_empty(), "no playback is tried without audio")
	_close_scr({"scr": scr2})


func _test_suspect() -> void:
	var confs: Array = [0.9, 0.3, 0.8, null, 0.45, 0.9, 0.9, 0.9]
	var ests: Array = [false, false, true, false, false, false, false, false]
	var d: Dictionary = _open_song(_song("en", ["low_match", "est_times"], confs, ests))
	var scr: SongCheckScreen = d["scr"]
	ok(scr.suspect_indices() == [1, 2, 4], "suspect lines: low confidence (1, 4) and estimated times (2) -> %s" % str(scr.suspect_indices()))
	ok(SongCheckScreen.suspect_reason(_line_of(scr, 3)) == "" and SongCheckScreen.suspect_reason(_line_of(scr, 0)) == "", "a line without confidence (pasted) and a good line are not suspect")
	ok(scr.is_doubtful_song(), "a low_match song is flagged")
	var banner_text := ""
	for l in scr.find_children("*", "Label", true, false):
		if (l as Label).text.contains("확인 필요"):
			banner_text += (l as Label).text + "|"
	ok(banner_text.contains("3개"), "the banner tells how many lines to check (%s)" % banner_text.left(80))
	var row_text: String = ""
	for l in scr.find_children("*", "Label", true, false):
		var tx: String = (l as Label).text
		if tx.begins_with("2 ·") or tx.begins_with("3 ·") or tx.begins_with("5 ·"):
			row_text += tx + "|"
	ok(row_text.contains("인식 불확실") and row_text.contains("시간 추정"), "suspect rows say why (%s)" % row_text.left(120))
	ok(_btn(scr, "ChipSuspect") != null and _btn(scr, "ChipAll") != null, "the 'check only' chips are there")
	_btn(scr, "ChipSuspect").pressed.emit()
	ok(scr.suspect_only and scr.find_children("Row*", "PanelContainer", true, false).size() == 3, "only the 3 suspect rows are listed")
	_btn(scr, "ChipAll").pressed.emit()
	ok(not scr.suspect_only and scr.find_children("Row*", "PanelContainer", true, false).size() == 8, "all 8 rows are listed again")
	# a merged line is an estimate -> it turns suspect
	scr.merge_lines(5)
	ok(scr.suspect_indices().has(5), "a merged line is flagged as an estimate")
	_close_scr(d)
	# a clean song (pasted / LRCLIB timing: conf null, est false) has no banner and no chips
	var clean: Dictionary = _song("en", [], [null, null, null, null, null, null, null, null])
	var d2: Dictionary = _open_song(clean)
	var s2: SongCheckScreen = d2["scr"]
	ok(s2.suspect_indices().is_empty() and not s2.is_doubtful_song(), "a clean song has no suspect line")
	ok(_btn(s2, "ChipSuspect") == null, "no 'check only' chip for a clean song")
	var any_warn := false
	for l in s2.find_children("*", "Label", true, false):
		any_warn = any_warn or (l as Label).text.contains("잘 맞지 않았어요")
	ok(not any_warn, "no mismatch banner for a clean song")
	_close_scr(d2)


func _test_readonly() -> void:
	var inst: Dictionary = SongStore.install(_song(), _audio(800))
	var id: String = str(inst["id"])
	var p: String = SongStore.song_dir(id).path_join("song.json")
	var raw: Variant = JSON.parse_string(_read_text(p))
	raw["v"] = 2
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify(raw))
	f.close()
	var disk_before: String = _read_text(p)
	var fake := Fake.new()
	var scr := SongCheckScreen.new()
	host.add_child(scr)
	scr.player = SongPlayer.new()
	scr.player.backend = fake
	host.add_child(scr.player)
	_closed_n = 0
	_saved_n = 0
	scr.closed.connect(func() -> void: _closed_n += 1)
	scr.saved.connect(func(_i: String) -> void: _saved_n += 1)
	scr.open("en", {"song_id": id})
	ok(scr.read_only and scr.line_count() == 8, "a v2 song opens read-only")
	ok(not scr.set_text(0, "x") and not scr.set_line_start(0, 1.0) and not scr.merge_lines(0) and not scr.split_line(0, 3) and not scr.delete_line(0) and not scr.set_song_offset(1.0), "every edit is refused")
	ok(not scr.save() and _read_text(p) == disk_before, "save() refuses and the file is untouched")
	ok(_btn(scr, "BtnOffP1") == null and _btn(scr, "BtnRevert").disabled, "no edit buttons for a read-only song")
	scr.select_line(1)
	ok(_btn(scr, "BtnPreview") != null and _btn(scr, "BtnMergeNext") == null and _btn(scr, "BtnDelete") == null, "the line card only offers listening")
	ok(_press(scr, "BtnSave") and _saved_n == 1 and _closed_n == 1 and _read_text(p) == disk_before, "[공부하러 가기] leaves without writing")
	host.remove_child(scr.player)
	scr.player.free()
	host.remove_child(scr)
	scr.free()


func _test_ui_paths() -> void:
	var d: Dictionary = _open_song()
	var scr: SongCheckScreen = d["scr"]
	var fake: Fake = d["fake"]
	var count_lbl: Label = scr._shell["count"]
	ok(count_lbl.text == "8줄", "the header shows the line count (%s)" % count_lbl.text)
	ok(scr.find_child("LineEditor", true, false) == null, "no editor card before a line is picked")
	scr.select_line(2)
	var ed: Node = scr.find_child("LineEditor", true, false)
	var te: LineEdit = scr.find_child("TextInput", true, false) as LineEdit
	ok(ed != null and te != null and te.text == LYRICS_EN[2], "picking a line shows its card with the text")
	ok(ed.get_index() == scr.find_child("Row2", true, false).get_index() + 1, "the card sits right under the picked row")
	te.text = "Every step feels like a new song"
	te.text_submitted.emit(te.text)
	ok(_line_of(scr, 2)["text"] == "Every step feels like a new song" and _line_of(scr, 2)["stale"] == true, "typing + enter changes the line (stale:true)")
	ok(_label_texts(scr.find_child("Row2", true, false)).contains("new song"), "the row shows the new text")
	# typing, then picking another row, keeps the typing
	te.text = "Every step is the best song"
	scr.select_line(3)
	ok(_line_of(scr, 2)["text"] == "Every step is the best song", "typed text is kept when another line is picked")
	te = scr.find_child("TextInput", true, false) as LineEdit
	ok(te.text == LYRICS_EN[3] and scr.selected == 3, "line 3 is picked now")
	# an emptied field goes back to the old text
	te.text = ""
	te.text_submitted.emit("")
	ok(_line_of(scr, 3)["text"] == LYRICS_EN[3] and te.text == LYRICS_EN[3], "an emptied text field is put back; the line keeps its text")
	# time buttons
	var t0: float = float(_line_of(scr, 3)["t0"])
	ok(_press(scr, "BtnStartPlus") and is_equal_approx(float(_line_of(scr, 3)["t0"]), t0 + 0.1), "[+0.1초] on the start")
	ok(_press(scr, "BtnStartMinus") and is_equal_approx(float(_line_of(scr, 3)["t0"]), t0), "[−0.1초] on the start")
	var t1: float = float(_line_of(scr, 3)["t1"])
	ok(_press(scr, "BtnEndPlus") and is_equal_approx(float(_line_of(scr, 3)["t1"]), t1 + 0.1), "[+0.1초] on the end")
	var sv: Label = scr.find_child("StartValue", true, false)
	ok(sv != null and sv.text == SongCheckScreen.fmt_time(t0), "the card shows the start time (%s)" % (sv.text if sv != null else ""))
	scr.player.play_from(15.55)
	scr.player.pause()
	ok(_press(scr, "BtnStartNow") and is_equal_approx(float(_line_of(scr, 3)["t0"]), 15.55), "[지금 위치로] on the start uses the player position")
	ok((scr.find_child("StartValue", true, false) as Label).text == SongCheckScreen.fmt_time(15.55), "the card's start label follows (%s)" % (scr.find_child("StartValue", true, false) as Label).text)
	# preview button
	fake.starts.clear()
	ok(_press(scr, "BtnPreview") and fake.starts.size() == 1, "[이 줄 듣기] plays through SongPlayer.play_line")
	# merge
	var n: int = scr.line_count()
	ok(_press(scr, "BtnMergeNext") and scr.line_count() == n - 1 and scr.selected == 3, "[다음 줄과 합치기]")
	ok(_press(scr, "BtnMergePrev") and scr.line_count() == n - 2 and scr.selected == 2, "[앞 줄과 합치기]")
	# split at the caret
	var te2: LineEdit = scr.find_child("TextInput", true, false) as LineEdit
	var whole: String = te2.text
	te2.caret_column = 5
	ok(_press(scr, "BtnSplit") and scr.line_count() == n - 1 and _line_of(scr, 2)["text"] == whole.substr(0, 5).strip_edges(), "[나누기] cuts at the caret column")
	# delete asks first
	var n2: int = scr.line_count()
	ok(_press(scr, "BtnDelete") and Sheet.is_open() and scr.line_count() == n2, "[삭제] asks before deleting")
	Sheet.close_top("cancel")
	ok(scr.line_count() == n2, "cancelling keeps the line")
	_press(scr, "BtnDelete")
	Sheet.close_top("ok")
	ok(scr.line_count() == n2 - 1, "confirming deletes the line")
	# offset buttons
	ok(_press(scr, "BtnOffP5") and is_equal_approx(float(scr.working["offset"]), 0.5), "offset [+0.5초]")
	ok(_press(scr, "BtnOffM1") and is_equal_approx(float(scr.working["offset"]), 0.4), "offset [−0.1초]")
	ok((scr.find_child("OffsetValue", true, false) as Label).text.contains("+0.40"), "the offset label shows +0.40 (%s)" % (scr.find_child("OffsetValue", true, false) as Label).text)
	ok(_press(scr, "BtnOffZero") and float(scr.working["offset"]) == 0.0, "offset [0으로]")
	_check(scr, "UI operations")
	# revert button asks, then reverts
	ok(not _btn(scr, "BtnRevert").disabled, "[변경 취소] is enabled after edits")
	_press(scr, "BtnRevert")
	ok(Sheet.is_open() and scr.is_dirty(), "[변경 취소] asks first")
	Sheet.close_top("ok")
	ok(not scr.is_dirty() and scr.line_count() == 8 and _line_of(scr, 2)["text"] == LYRICS_EN[2], "confirming brings back the opened state")
	# back button: leaving with unsaved edits asks
	scr.set_text(0, "Unsaved")
	ok(scr.go_back() and Sheet.is_open() and _closed_n == 0, "back with unsaved edits asks first")
	Sheet.close_top("cancel")
	ok(_closed_n == 0, "'계속 고치기' stays")
	scr.go_back()
	Sheet.close_top("ok")
	ok(_closed_n == 1 and scr.result == "left", "'버리고 나가기' leaves (result == left)")
	ok(SongStore.load_song(str(d["id"]))["lines"][0]["text"] == LYRICS_EN[0], "the discarded edit never reached the disk")
	_close_scr(d)
	var d2: Dictionary = _open_song()
	var s2: SongCheckScreen = d2["scr"]
	ok(s2.go_back() and _closed_n == 1 and not Sheet.is_open(), "back without edits leaves at once")
	_close_scr(d2)


func _label_texts(n: Node) -> String:
	var out := ""
	for l in n.find_children("*", "Label", true, false):
		out += (l as Label).text + "|"
	return out


func _test_big_song() -> void:
	var s: Dictionary = _song()
	var ls: Array = []
	for i in 400:
		var t0: float = 1.0 + 1.4 * i
		ls.append(_line(i, "Line number %d of a very long song" % i, t0, t0 + 1.2, null))
	s["lines"] = ls
	s["duration"] = 600.0
	s["marks"] = {"lines": [0, 399], "words": []}
	s["stats"] = {"plays": 0, "last": 0, "best": {"399": 77}}
	var ms0: int = Time.get_ticks_msec()
	var d: Dictionary = _open_song(s)
	var scr: SongCheckScreen = d["scr"]
	var ms: int = Time.get_ticks_msec() - ms0
	print("  info  opening a 400-line song took %d ms" % ms)
	ok(bool(d["ok"]) and scr.line_count() == 400, "a 400-line song opens")
	ok(scr.find_children("Row*", "PanelContainer", true, false).size() == 400, "400 rows are built")
	ok(ms < 15000, "opening 400 lines took %d ms (< 15 s)" % ms)
	var before: String = JSON.stringify(scr.working, "", true)
	ok(not scr.split_line(0, 4) and JSON.stringify(scr.working, "", true) == before, "a split is refused at 400 lines (limit)")
	ok(scr.merge_lines(0) and scr.line_count() == 399, "merge at 400 lines")
	ok(scr.split_line(0, 4) and scr.line_count() == 400, "a split is possible again at 399 lines")
	ok((scr.working["stats"]["best"] as Dictionary).get("399", 0) == 77 and (scr.working["marks"]["lines"] as Array) == [0, 1, 399], "marks / best of the last line survive merge + split (%s)" % str(scr.working["marks"]["lines"]))
	_check(scr, "400-line edits")
	ok(scr.save(), "a 400-line song saves")
	ok(inv(SongStore.load_song(str(d["id"]))).is_empty(), "the saved 400-line file passes the invariants")
	_close_scr(d)


# ---------------------------------------------------------------- layout

var _overflow: Array = []
var _small: Array = []
var _clipped: Array = []


func _visible_controls(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Window:
			continue
		if c is Control and (c as Control).visible:
			out.append(c)
		_visible_controls(c, out)


func _scan(root: Node, state: String, touch_min: float) -> int:
	var all: Array = []
	_visible_controls(root, all)
	var n: int = 0
	for c in all:
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var r: Rect2 = ctl.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		n += 1
		if r.end.x > _vp.x + 0.5 or r.position.x < -0.5:
			_overflow.append("%s: %s %s x=%.1f..%.1f" % [state, ctl.name, ctl.get_class(), r.position.x, r.end.x])
		if _phone and (ctl is BaseButton or ctl is LineEdit or ctl is Slider):
			var mh: float = 40.0 if ctl is Slider else touch_min
			var mw: float = 0.0 if ctl is Slider else touch_min
			if r.size.y < mh or r.size.x < mw:
				_small.append("%s: %s %s (%.0fx%.0f)" % [state, ctl.name, ctl.get_class(), r.size.x, r.size.y])
		if ctl is Label or ctl is Button or ctl is LineEdit:
			var m: Vector2 = ctl.get_combined_minimum_size()
			if ctl.size.x + 1.0 < m.x or ctl.size.y + 1.0 < m.y:
				_clipped.append("%s: %s %s size=%s min=%s" % [state, ctl.name, ctl.get_class(), str(ctl.size), str(m)])
	return n


func _test_layout() -> void:
	# the scan itself must fail on a bad layout
	var probe_host := Control.new()
	probe_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(probe_host)
	var box := VBoxContainer.new()
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(_vp.x + 200.0, 10)
	box.add_child(wide)
	var tiny := BaseButton.new()
	tiny.custom_minimum_size = Vector2(60, 20)
	box.add_child(tiny)
	probe_host.add_child(box)
	await _frames(3)
	_overflow.clear()
	_small.clear()
	_clipped.clear()
	_scan(probe_host, "selfcheck", Ds.touch_min() - 0.5)
	ok(_overflow.size() >= 1, "layout scan: a control wider than the screen is reported")
	ok(not _phone or _small.size() >= 1, "layout scan: a 20 px high touch target is reported (phone)")
	probe_host.queue_free()
	await _frames(2)

	for scale in [1.0, 1.5]:
		UiBoot.apply(get_window(), "light", scale)
		ok(is_equal_approx(Ds.font_scale, scale), "font scale %s is applied (Ds.font_scale %s)" % [scale, Ds.font_scale])
		await _frames(2)
		_overflow.clear()
		_small.clear()
		_clipped.clear()
		var confs: Array = [0.9, 0.3, 0.8, null, 0.45, 0.9, 0.9, 0.9]
		var ests: Array = [false, false, true, false, false, false, false, false]
		var s: Dictionary = _song("en", ["low_match", "est_times"], confs, ests)
		s["lines"][1]["text"] = "Hold the lantern high tonight and let the river carry every worry far away from me tonight, tonight and then some more words until the line is very long indeed ok"
		s["title"] = "A Quite Long Title For A Test Song That Keeps Going On"
		s["artist"] = "Some Artist With A Long Name"
		var d: Dictionary = _open_song(s)
		var scr: SongCheckScreen = d["scr"]
		scr.select_line(1)
		scr.set_text(1, str(s["lines"][1]["text"]))
		scr.save_error = SongCheckScreen.MSG_SAVE_FAIL % "disk_write"
		scr._render_banners()
		await _frames(8)
		var n1: int = _scan(scr, "scale%s_line_editor" % scale, Ds.touch_min() - 0.5)
		# fixed parts must be inside the screen vertically and leave room for the list
		var foot: Control = scr._shell["footer_holder"]
		var tp: Control = scr._transport
		var pg: Control = scr._shell["page"]
		ok(foot.get_global_rect().end.y <= _vp.y + 0.5 and tp.get_global_rect().position.y >= -0.5, "scale %s: footer and transport are inside the screen" % scale)
		ok(pg.size.y >= 200.0, "scale %s: the list keeps %d px of height" % [scale, int(pg.size.y)])
		# open a different state: nothing selected + the check-only filter
		scr.select_line(-1)
		scr.set_suspect_only(true)
		await _frames(6)
		var n2: int = _scan(scr, "scale%s_filter" % scale, Ds.touch_min() - 0.5)
		scr.set_suspect_only(false)
		scr.select_line(5)
		await _frames(6)
		var n3: int = _scan(scr, "scale%s_other_line" % scale, Ds.touch_min() - 0.5)
		print("  info  scale %s: screen %s, scanned %d / %d / %d controls, overflow %d, small %d, clipped %d" % [scale, scr.size, n1, n2, n3, _overflow.size(), _small.size(), _clipped.size()])
		for e in _overflow.slice(0, 6):
			print("    overflow: ", e)
		for e in _small.slice(0, 6):
			print("    small: ", e)
		for e in _clipped.slice(0, 6):
			print("    clipped: ", e)
		ok(n1 > 30 and n2 > 20 and n3 > 30, "scale %s: the scan looked at controls (%d, %d, %d)" % [scale, n1, n2, n3])
		ok(_overflow.is_empty(), "scale %s: no control sticks out of the %dpx wide screen" % [scale, int(_vp.x)])
		ok(_small.is_empty(), "scale %s: touch targets are >= %.1f px (phone only)" % [scale, Ds.touch_min() - 0.5])
		ok(_clipped.is_empty(), "scale %s: no text is cut (every label / button has the room its text needs)" % scale)
		_close_scr(d)
	UiBoot.apply(get_window(), "light", 1.0)
