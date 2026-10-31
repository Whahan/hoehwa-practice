extends Node
## 가사 외우기 M4: SongMemoDrill (단계 그림 · 입력 · 말하기 · 자가 평가 · 읽어 주기 · 결과). 서버·마이크·실제 곡을 쓰지 않는다.
##   PC:   godot --headless --path godot res://tests/song_memo_drill_test.tscn
##   폰:   godot --headless --path godot res://tests/song_memo_drill_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5
## 마지막 줄: "== song_memo_drill_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 가사는 tests/fixtures/song/lyrics_en.txt · lyrics_ja.txt (직접 쓴 문장, CC0)뿐이다. 곡은 user://test_songs_memo_drill 에만 만든다.
## 설정·진행·학습 기록은 user://test_memo_drill/ 로 돌린다. /stt 는 SpeakDrill.api_hook 으로 가로채고(실제 서버·네트워크 0),
## 읽어 주기는 Tts.fetch_hook 으로 센다. 시계는 주입한 NOW, FSRS.fuzz_override = 0.5.
## 일부러 틀린 입력(변조): _selftest() 구간 (검사기가 새는 줄·넘침을 실제로 잡는지).

const NOW := 1790000000
const DAY := 86400
const ROOT := "user://test_songs_memo_drill"
const DIR := "user://test_memo_drill"
const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"
const JA_READING := "あさのまどべでちいさなやかんがなる"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _before: Dictionary = {}
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_status: Variant
var _old_prefs_data: Dictionary = {}
var _old_mode: String = ""
var _old_phone_hook: Callable = Callable()
var _old_overrides: Dictionary = {}
var _old_root: String = ""
var _reqs: Array = []
var _tts_calls: Array = []
var stt_resp: Variant = {"text": ""}
var stt_delay: float = 0.0
var _events: Array = []
var _en: Dictionary = {}
var _ja: Dictionary = {}
var _en_id: String = ""
var _ja_id: String = ""
var _save_fail: bool = false
var _save_calls: int = 0
var _toasts: Array = []


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


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(_g(path))
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(_g(path).path_join(fn))
	DirAccess.remove_absolute(_g(path))


func _dirs(path: String) -> Array:
	var d := DirAccess.open(_g(path))
	if d == null:
		return []
	var out: Array = Array(d.get_directories())
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
	out["songs_dirs"] = _dirs("user://songs")
	return out


func _fixture_lines(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	var out: Array = []
	if f == null:
		return out
	var kept: PackedStringArray = []
	for ln in f.get_as_text().split("\n"):
		if not ln.strip_edges().begins_with("#"):
			kept.append(ln)
	f.close()
	for e in LrcParser.split_plain("\n".join(kept)):
		out.append({"text": e["text"], "p": e["p"]})
	return out


func _lyrics_song(lang: String) -> Dictionary:
	var lines: Array = []
	for e in _fixture_lines(EN_PATH if lang == "en" else JA_PATH):
		var i: int = lines.size()
		lines.append({"i": i, "p": e["p"], "t0": 0.0, "t1": 0.0, "text": e["text"], "reading": "", "pron": "", "ko": "해석 %d" % i,
			"conf": null, "est": true, "stale": false, "words": []})
	if lang == "ja":
		(lines[0] as Dictionary)["reading"] = JA_READING
	return {"v": 1, "kind": "lyrics", "lang": lang, "title": "Drill " + lang, "artist": "Tester", "created": 1790000000, "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "none", "attribution": ""}, "offset": 0.0,
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [], "app": "1.4.0"}


func _fresh_song(lang: String) -> Dictionary:
	return (_en if lang == "en" else _ja).duplicate(true)


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled and (b as Button).is_visible_in_tree():
		(b as Button).pressed.emit()
		return true
	return false


func _until(cond: Callable, sec: float = 4.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _save(id: String, memo: Dictionary) -> Variant:
	_save_calls += 1
	if _save_fail:
		return {"ok": false, "err_code": "disk_write"}
	return SongStore.save_memo(id, memo)


## 세션을 만든다. memo 를 안 주면 새 기록. 저장은 SongStore.save_memo (실패 스위치 _save_fail).
func _session(song: Dictionary, memo: Variant = null, opts: Dictionary = {}) -> MemoSession:
	var s := MemoSession.new()
	var o: Dictionary = {"save": Callable(self, "_save"), "id": str(song.get("id", "")), "prev_cue": true}
	o.merge(opts, true)
	s.begin(song, memo if memo != null else MemoModel.new_memo(), NOW, o)
	return s


func _grade(s: MemoSession, wrong: bool = false) -> Dictionary:
	var c: Dictionary = s.current()
	return MemoGrade.grade(c["lang"], "zzq xxv wwy" if wrong else str(c["text"]), {"text": c["text"], "reading": c["reading"]}, "type")


## 세션을 단계 target 까지 (정답으로) 올린다.
func _to_stage(s: MemoSession, target: int) -> void:
	var guard := 0
	while guard < 20 and int(s.current().get("stage", 0)) < target:
		guard += 1
		if bool(s.current()["read_only_stage"]):
			s.skip_read()
		else:
			s.submit(_grade(s))


func _drill(s: MemoSession, lang: String, host: Node = null) -> SongMemoDrill:
	var d := SongMemoDrill.new()
	d.lock_msec = 0
	d.event.connect(func(kind: String, data: Dictionary) -> void: _events.append([kind, data]))
	(host if host != null else self).add_child(d)
	d.setup(s, lang)
	return d


func _drop(d: Node) -> void:
	if d != null and is_instance_valid(d):
		d.get_parent().remove_child(d)
		d.free()


func _ev_count(kind: String) -> int:
	var n := 0
	for e in _events:
		if e[0] == kind:
			n += 1
	return n


func _last_ev(kind: String) -> Dictionary:
	for i in range(_events.size() - 1, -1, -1):
		if _events[i][0] == kind:
			return _events[i][1]
	return {}


## 노드 트리의 모든 글자 (Label · RichTextLabel · Button · LineEdit · TextEdit · 툴팁 · 접근성 이름 · 노드 이름). skip: 이 이름의 하위는 건너뜀.
func _strings(root: Node, skip: String = "") -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if skip != "" and str(n.name) == skip:
			continue
		out.append(str(n.name))
		if n is Label:
			out.append((n as Label).text)
		if n is RichTextLabel:
			out.append((n as RichTextLabel).text)
			out.append((n as RichTextLabel).get_parsed_text())
		if n is Button:
			out.append((n as Button).text)
		if n is LineEdit:
			out.append((n as LineEdit).text)
			out.append((n as LineEdit).placeholder_text)
		if n is TextEdit:
			out.append((n as TextEdit).text)
			out.append((n as TextEdit).placeholder_text)
		if n is Control:
			out.append((n as Control).tooltip_text)
			var an: Variant = n.get("accessibility_name")
			if an is String:
				out.append(an)
			var ad: Variant = n.get("accessibility_description")
			if ad is String:
				out.append(ad)
		for c in n.get_children():
			stack.append(c)
	return out


## 줄 글자가 노드 트리에 새는 곳: 영어는 3글자 이상 단어, 일본어는 3글자 연속 조각. 새는 것의 목록.
func _leaks(root: Node, text: String, lang: String, skip: String = "") -> Array:
	var hay: String = "\n".join(_strings(root, skip))
	var bad: Array = []
	if lang == "ja":
		var chars := ""
		for i in text.length():
			if TextSim.JA_SKIP.find(text[i]) == -1:
				chars += text[i]
		for i in range(0, chars.length() - 2):
			var win: String = chars.substr(i, 3)
			if hay.contains(win):
				bad.append(win)
	else:
		var have := {}
		for w in _words(hay):
			have[w] = true
		for w in _words(text):
			if w.length() >= 3 and have.has(w):
				bad.append(w)
	return bad


## lower-case words of a text (own tokenizer: not the code under test, no length cap)
func _words(t: String) -> Array:
	var rx := RegEx.new()
	rx.compile("[A-Za-z0-9']+")
	var out: Array = []
	for m in rx.search_all(t.to_lower()):
		out.append(m.get_string().trim_prefix("'").trim_suffix("'"))
	return out


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
	for n in root.find_children("*", "Button", true, false):
		var b := n as Button
		if not b.is_visible_in_tree():
			continue
		var r: Rect2 = b.get_global_rect()
		if r.size.y < tmin - 0.5:
			bad.append("%s %s %s" % [b.name, b.text, r.size])
	for n in root.find_children("*", "LineEdit", true, false):
		var le := n as LineEdit
		if le.is_visible_in_tree() and le.get_global_rect().size.y < tmin - 0.5:
			bad.append("%s %s" % [le.name, le.get_global_rect().size])
	return bad


func _count_sub(hay: String, sub: String) -> int:
	return hay.split(sub).size() - 1


func _hook(method: String, path: String, body: Variant) -> Variant:
	_reqs.append({"method": method, "path": path, "body": body})
	if path == "/stt":
		if stt_delay > 0.0:
			await get_tree().create_timer(stt_delay).timeout
		return stt_resp
	return {"ok": false, "code": 404, "data": null, "error": "no"}


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	_tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _stt_calls() -> int:
	var n := 0
	for r in _reqs:
		if str(r["path"]) == "/stt":
			n += 1
	return n


func _rec() -> Dictionary:
	var wav: PackedByteArray = WavUtil.to_wav_bytes(WavUtil.sine(0.6, 16000))
	return {"ok": true, "silent": false, "duration": 0.6, "b64": Marshalls.raw_to_base64(wav), "wav": wav, "owner": 0}


func _speak(d: SongMemoDrill, text: Variant, delay: float = 0.0) -> void:
	_speak_raw(d, {"text": text}, delay)


## raw: the whole /stt reply the hook will give (any value).
func _speak_raw(d: SongMemoDrill, raw: Variant, delay: float = 0.0) -> void:
	stt_resp = raw
	stt_delay = delay
	var rws: Array = d.find_children("*", "RecorderWidget", true, false)
	if not rws.is_empty():
		(rws[0] as RecorderWidget).recorded.emit(_rec())


func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


func _log_json() -> String:
	return JSON.stringify(StudyLog.snapshot())


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== song_memo_drill_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_prefs_data = Store.prefs.duplicate(true)
	_old_mode = Route.mode
	_old_phone_hook = Route.phone_hook
	_old_overrides = LocalApi.handler_override.duplicate()
	_rm_rf(DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	StudyLog.reset()
	Store.prefs.erase("memo_answer")
	Store.prefs.erase("tts_engine")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port: this run must never reach the user's engine (8770)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	FSRS.fuzz_override = 0.5
	_old_root = SongStore.root
	SongStore.root = ROOT
	_rm_rf(ROOT)
	SongStore.clear_cache()
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")
	_mode_pc()

	var r1: Dictionary = SongStore.install_lyrics(_lyrics_song("en"))
	var r2: Dictionary = SongStore.install_lyrics(_lyrics_song("ja"))
	_en_id = str(r1["id"])
	_ja_id = str(r2["id"])
	ok(bool(r1["ok"]) and bool(r2["ok"]), "fixture songs installed in the test root only")
	_en = SongStore.load_song(_en_id)
	_ja = SongStore.load_song(_ja_id)
	ok((_en["lines"] as Array).size() == 6 and (_ja["lines"] as Array).size() == 5, "fixtures: en 6 lines, ja 5 lines")
	ok(str((_ja["lines"] as Array)[0].get("reading", "")) == JA_READING, "fixture ja line 0 has a reading")

	var reached := {}
	await _selftest()
	reached["selftest"] = true
	await _test_stages()
	reached["stages"] = true
	await _test_leak()
	reached["leak"] = true
	await _test_ja_fields()
	reached["ja_fields"] = true
	await _test_typing()
	reached["typing"] = true
	await _test_flow()
	reached["flow"] = true
	await _test_speak_pc()
	reached["speak_pc"] = true
	await _test_phone_only()
	reached["phone_only"] = true
	await _test_listen()
	reached["listen"] = true
	await _test_hide()
	reached["hide"] = true
	await _test_save_failed()
	reached["save_failed"] = true
	await _test_layout()
	reached["layout"] = true
	for k in ["selftest", "stages", "leak", "ja_fields", "typing", "flow", "speak_pc", "phone_only", "listen", "hide", "save_failed", "layout"]:
		ok(reached.has(k), "section '%s' ran to its end" % k)

	# cleanup
	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	Route.mode = _old_mode
	Route.phone_hook = _old_phone_hook
	LocalApi.handler_override = _old_overrides
	FSRS.fuzz_override = -1.0
	SongStore.write_hook = Callable()
	SongStore.root = _old_root
	_rm_rf(ROOT)
	_rm_rf(DIR)
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Store.prefs = _old_prefs_data
	ok(_user_listing() == _before, "the user's own song folder and app files were not touched")
	print("== song_memo_drill_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 검사기 변조 시험

func _selftest() -> void:
	print("[selftest: the checkers fail on bad input]")
	var line: String = (_en["lines"] as Array)[0]["text"]
	var host := VBoxContainer.new()
	add_child(host)
	var lab := Label.new()
	lab.text = "정답: " + line
	host.add_child(lab)
	ok(not _leaks(host, line, "en").is_empty(), "leak checker (en) catches the line in a Label")
	lab.text = "아무 글자 없음 123"
	ok(_leaks(host, line, "en").is_empty(), "leak checker (en) passes a Korean-only tree")
	lab.tooltip_text = "kettle"
	ok(not _leaks(host, line, "en").is_empty(), "leak checker (en) catches the line in a tooltip")
	lab.tooltip_text = ""
	var le := LineEdit.new()
	le.placeholder_text = "morning"
	host.add_child(le)
	ok(not _leaks(host, line, "en").is_empty(), "leak checker (en) catches the line in a placeholder")
	le.placeholder_text = ""
	var jline: String = (_ja["lines"] as Array)[1]["text"]
	var jb := Button.new()
	jb.text = jline.substr(2, 5)
	host.add_child(jb)
	ok(not _leaks(host, jline, "ja").is_empty(), "leak checker (ja) catches 3 characters of the line in a Button")
	jb.text = "확인"
	ok(_leaks(host, jline, "ja").is_empty(), "leak checker (ja) passes a Korean-only tree")
	var flat := Control.new()
	add_child(flat)
	flat.size = Vector2(100, 40)
	var wide := Control.new()
	flat.add_child(wide)
	wide.size = Vector2(3000, 10)
	await _frames(2)
	ok(not _overflow(flat).is_empty(), "overflow checker reports a child that sticks out sideways")
	wide.size = Vector2(60, 10)
	await _frames(1)
	ok(_overflow(flat).is_empty(), "overflow checker passes a child that fits")
	var tb := Button.new()
	tb.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	tb.add_theme_font_size_override("font_size", 8)
	tb.text = "x"
	flat.add_child(tb)
	await _frames(2)
	ok(not _small_touch(flat).is_empty(), "touch checker reports a tiny button")
	flat.remove_child(tb)
	tb.free()
	_drop(flat)
	_drop(host)
	host = null


# ---------------------------------------------------------------- 단계 그림

func _test_stages() -> void:
	print("[stage drawing]")
	var song: Dictionary = _fresh_song("en")
	var text: String = (song["lines"] as Array)[0]["text"]
	var s: MemoSession = _session(song)
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(2)
	var cur: Dictionary = s.current()
	ok(int(cur["stage"]) == 0 and int(cur["stage_count"]) == 5, "new line starts at stage 0 of 5 (9 units: 0,3,5,7,9)")
	ok(d.line_text() == text and not d.line_text().contains("____"), "stage 0: the whole line is shown, no blanks")
	ok(_find(d, "ReadBtn") != null and _find(d, "AnswerEdit") == null and _find(d, "SubmitBtn") == null, "stage 0: [next stage] only, no input yet")
	ok(_find(d, "LineBox") != null and _find(d, "LaterBtn") != null and _find(d, "ListenBtn") != null, "stage 0: LineBox, LaterBtn, ListenBtn exist")
	ok(str((_find(d, "StageDots") as Label).text) == "●○○○○", "stage 0: stage dots show 1 of 5")
	_press(d, "ReadBtn")
	ok(int(s.current()["stage"]) == 1 and _ev_count("skip_read") == 1, "[next stage] skips the read stage (event skip_read once)")
	s.submit(_grade(s))
	cur = s.current()
	d.render()
	ok(int(cur["stage"]) == 2 and int(cur["hidden_count"]) == 5, "stage 2 of the 9-unit line hides 5 units")
	var shown: String = d.line_text()
	ok(_count_sub(shown, "____") == 5, "stage 2: exactly 5 blanks in LineText (got %d)" % _count_sub(shown, "____"))
	ok(shown == MemoMask.render(text, "en", cur["hidden"]), "stage 2: LineText equals MemoMask.render of the hidden flags")
	var vis_expect: Array = []
	for k in (cur["units"] as Array).size():
		if not bool((cur["hidden"] as Array)[k]):
			vis_expect.append(str(((cur["units"] as Array)[k] as Dictionary)["w"]))
	var vis_got: Array = []
	for tok in shown.split(" "):
		var t: String = tok.strip_edges()
		if t != "" and t != "____":
			vis_got.append(t)
	ok(vis_got == vis_expect, "stage 2: the visible words are exactly the units outside the hidden set, in order")
	ok(_find(d, "AnswerEdit") != null and _find(d, "SubmitBtn") != null and _find(d, "RevealBtn") != null, "stage 2: AnswerEdit, SubmitBtn, RevealBtn exist")
	var punct: Dictionary = _fresh_song("en")
	var s2: MemoSession = _session(punct, null, {"only_line": 2})
	_to_stage(s2, 2)
	var d2: SongMemoDrill = _drill(s2, "en")
	var t2: String = (punct["lines"] as Array)[2]["text"]
	ok(d2.line_text() == MemoMask.render(t2, "en", s2.current()["hidden"]) and d2.line_text().contains(","), "punctuation is kept in a masked line (%s)" % d2.line_text())
	ok(str((_find(d2, "StageDots") as Label).text) == "●●●○○", "stage dots follow the plan of a 7-unit line (stage 3 of 5)")
	_drop(d2)
	# 단계 그림이 단계와 함께 바뀐다: 맨 끝은 줄 글자 칸이 없음
	_to_stage(s, 4)
	d.render()
	ok(_find(d, "LineText") == null and _find(d, "BlankHint") != null, "final stage: no LineText, only the blank hint")
	ok(_find(d, "SubmitBtn") != null and (_find(d, "SubmitBtn") as Button).disabled, "empty input: SubmitBtn is disabled")
	d.set_typed("   ")
	ok((_find(d, "SubmitBtn") as Button).disabled, "spaces only: SubmitBtn stays disabled (not an attempt)")
	ok(not d.submit_typed(), "submit_typed() with blank input does nothing")
	d.set_typed("a")
	ok(not (_find(d, "SubmitBtn") as Button).disabled, "some text: SubmitBtn is enabled")
	_drop(d)


# ---------------------------------------------------------------- 맨 끝 단계 누출 검사

func _review_memo(song: Dictionary) -> Dictionary:
	var memo: Dictionary = MemoModel.new_memo()
	for i in (song["lines"] as Array).size():
		var key: String = MemoModel.line_key(str(song["lines"][i]["text"]), str(song["lang"]))
		memo["lines"][key] = {"stage": 0, "seen": NOW - 3 * DAY, "tries": 1, "passes": 1,
			"card": {"due": NOW - DAY + i, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0, "last_review": NOW - 3 * DAY, "reps": 2, "lapses": 0}}
	return memo


func _test_leak() -> void:
	print("[blank screen: no line text anywhere in the node tree]")
	for lang in ["en", "ja"]:
		var song: Dictionary = _fresh_song(lang)
		var s: MemoSession = _session(song, _review_memo(song), {"prev_cue": false})
		var d: SongMemoDrill = _drill(s, lang)
		var n_lines := 0
		var leaks := 0
		var bad_listen := 0
		var all_final := true
		var guard := 0
		while guard < 10 and bool(s.current().get("ok", false)):
			guard += 1
			await _frames(1)
			var cur: Dictionary = s.current()
			if not bool(cur["final"]) or not bool(cur["ok"]):
				all_final = false
			var lk: Array = _leaks(d, str(cur["text"]), lang)
			if not lk.is_empty():
				leaks += 1
				print("    leak in %s: %s" % [lang, lk])
			if not (_find(d, "ListenBtn") as Button).disabled:
				bad_listen += 1
			n_lines += 1
			s.leave_line()
			if not s.next_line():
				break
			d.render()
		ok(n_lines == (6 if lang == "en" else 5) and all_final, "%s: all %d review lines start at the blank stage and were checked" % [lang, n_lines])
		ok(leaks == 0, "%s: blank stage shows none of the line in labels, buttons, edits, tooltips or accessibility names" % lang)
		ok(bad_listen == 0, "%s: ListenBtn is disabled on every blank-stage line" % lang)
		_drop(d)
	# 앞 줄 힌트: 켬이면 앞 줄이 CueBox 에만, 끔이면 CueBox 없음
	var song2: Dictionary = _fresh_song("en")
	var memo2: Dictionary = _review_memo(song2)
	var on: MemoSession = _session(song2, memo2, {"prev_cue": true})
	var don: SongMemoDrill = _drill(on, "en")
	await _frames(1)
	ok(_find(don, "CueBox") == null, "prev cue on: the first line has no previous line, so no CueBox")
	on.leave_line()
	on.next_line()
	don.render()
	var cue_txt: String = "\n".join(_strings(_find(don, "CueBox")))
	var cur_on: Dictionary = on.current()
	ok(_find(don, "CueBox") != null and cue_txt.contains(str((song2["lines"] as Array)[int(cur_on["line_i"]) - 1]["text"])), "prev cue on: CueBox shows the previous line")
	ok(_leaks(don, str(cur_on["text"]), "en", "CueBox").is_empty(), "prev cue on: outside CueBox the blank stage still shows none of the line")
	var off: MemoSession = _session(song2, memo2, {"prev_cue": false})
	off.leave_line()
	off.next_line()
	don.session = off
	don.render()
	ok(_find(don, "CueBox") == null, "prev cue off: no CueBox on the second line")
	_drop(don)
	# 변조: 맨 끝 단계 위젯에 줄 글자를 일부러 넣으면 검사기가 잡는다
	var s3: MemoSession = _session(song2, memo2, {"prev_cue": false})
	var d3: SongMemoDrill = _drill(s3, "en")
	var inject := Label.new()
	inject.text = str(s3.current()["text"])
	d3.add_child(inject)
	ok(not _leaks(d3, str(s3.current()["text"]), "en").is_empty(), "tamper: a planted Label with the line is caught in the drill's tree")
	inject.queue_free()
	_drop(d3)


# ---------------------------------------------------------------- 일본어 읽기·해석 보임/숨김

func _test_ja_fields() -> void:
	print("[ja reading, pronunciation and Korean translation]")
	var song: Dictionary = _fresh_song("ja")
	var s: MemoSession = _session(song, null, {"only_line": 0})
	var d: SongMemoDrill = _drill(s, "ja")
	await _frames(2)
	var plan: Array = MemoMask.stage_plan((s.current()["units"] as Array).size(), false)
	var txt0: String = "\n".join(_strings(d))
	ok(txt0.contains(JA_READING) and txt0.contains("해석 0"), "stage 0: reading and Korean translation are shown")
	_press(d, "ReadBtn")
	var mid_ok := true
	var guard := 0
	while guard < 8 and not bool(s.current()["final"]):
		guard += 1
		d.render()
		var tmid: String = "\n".join(_strings(d))
		if bool(s.current()["read_only_stage"]):
			continue
		if tmid.contains(JA_READING):
			mid_ok = false
		if not tmid.contains("해석 0"):
			mid_ok = false
		s.submit(_grade(s))
	ok(mid_ok and plan.size() >= 3, "middle stages: reading hidden, Korean translation still shown")
	d.render()
	var tfin: String = "\n".join(_strings(d))
	ok(bool(s.current()["final"]) and not tfin.contains(JA_READING) and not tfin.contains("해석 0"), "blank stage: reading and Korean translation are hidden")
	d.set_typed(str(s.current()["text"]))
	_press(d, "SubmitBtn")
	await _frames(1)
	var tres: String = "\n".join(_strings(d))
	ok(tres.contains(JA_READING) and tres.contains("해석 0") and tres.contains(str(s.current()["text"])), "after the answer: reading, translation and the answer line are shown")
	_drop(d)


# ---------------------------------------------------------------- 입력 · 결과 표시

func _test_typing() -> void:
	print("[typing: result display, marks, reveal]")
	var song: Dictionary = _fresh_song("en")
	var text0: String = (song["lines"] as Array)[0]["text"]
	_events.clear()
	var s: MemoSession = _session(song, null, {"only_line": 0})
	_to_stage(s, 1)
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(1)
	d.set_typed(text0)
	ok(_press(d, "SubmitBtn"), "stage 1: a correct line can be submitted")
	await _frames(1)
	var rb: Node = _find(d, "ResultBox")
	ok(rb != null and "\n".join(_strings(rb)).contains("✓ 통과"), "correct answer: ResultBox shows '✓ 통과'")
	ok(_ev_count("submit") == 1 and _ev_count("stage_pass") == 1, "events: submit once, stage_pass once")
	ok(bool((_last_ev("submit")["grade"] as Dictionary)["passed"]) and str((_last_ev("submit")["grade"] as Dictionary)["via"]) == "type", "submit event carries the MemoGrade (via type, passed)")
	ok(_find(d, "NextBtn") != null and _find(d, "AnswerEdit") == null, "after a pass: [next stage] shown, no input")
	_press(d, "NextBtn")
	ok(_find(d, "ResultBox") == null and _find(d, "AnswerEdit") != null and int(s.current()["stage"]) == 2, "[next stage] opens the next stage's input")
	# 틀린 입력: 앞 3단어만
	d.set_typed("The kettle hums")
	_press(d, "SubmitBtn")
	await _frames(1)
	rb = _find(d, "ResultBox")
	var rtxt: String = "\n".join(_strings(rb))
	var ans: RichTextLabel = _find(rb, "AnswerLine") as RichTextLabel
	var plain: String = ans.get_parsed_text()
	ok(rtxt.contains("✕") and plain.contains("✕wall") and ans.text.contains("[u]") and ans.text.contains("[b]"), "wrong answer: the missed words carry a text mark (✕, bold, underline), not only colour")
	ok(plain.contains("The kettle hums") and not plain.contains("✕kettle"), "wrong answer: right words are plain, wrong ones are marked")
	ok(_find(d, "RetryBtn") != null and _find(d, "RevealBtn") != null, "wrong answer: RetryBtn and RevealBtn are offered")
	ok(rtxt.contains("내가 쓴 것") and rtxt.contains("The kettle hums"), "wrong answer: shows what I typed")
	ok(_ev_count("stage_fail") == 1 and int(s.current()["stage"]) == 2, "wrong answer: stage_fail, still in stage 2")
	_press(d, "RetryBtn")
	d.set_typed("The kettle hums banana zebra")
	_press(d, "SubmitBtn")
	await _frames(1)
	rtxt = "\n".join(_strings(_find(d, "ResultBox")))
	ok(rtxt.contains("정답에 없는 단어") and rtxt.contains("banana") and rtxt.contains("zebra"), "English: extra words are listed")
	ok(_ev_count("revealed") == 1 and int(s.current()["stage"]) == 1, "second miss in a stage: revealed, one stage down")
	ok(rtxt.contains("정답을 알려") and _find(d, "NextBtn") != null and _find(d, "RetryBtn") == null, "revealed: explanation and [continue]")
	_press(d, "NextBtn")
	# [정답 보기]
	var before: int = int(s.current()["stage"])
	ok(_press(d, "RevealBtn"), "RevealBtn is pressable in the answer phase")
	await _frames(1)
	ok(_ev_count("reveal") == 1 and str((s.current())["stage"]) != "" and int(s.current()["stage"]) >= 1, "RevealBtn: reveal event, stage never below 1 (was %d)" % before)
	ok("\n".join(_strings(_find(d, "ResultBox"))).contains(text0), "RevealBtn: the whole line is shown in the result")
	# 일본어: 한 단위만 틀림 → 그 단위만 표식
	_drop(d)
	var jsong: Dictionary = _fresh_song("ja")
	var js: MemoSession = _session(jsong, null, {"only_line": 1})
	_to_stage(js, 1)
	var jd: SongMemoDrill = _drill(js, "ja")
	var jc: Dictionary = js.current()
	var jtext: String = str(jc["text"])
	var jus: Array = jc["units"]
	var first_w: String = str((jus[0] as Dictionary)["w"])
	jd.set_typed(jtext.substr(first_w.length()))
	_press(jd, "SubmitBtn")
	await _frames(1)
	var jans: RichTextLabel = _find(jd, "AnswerLine") as RichTextLabel
	ok(jans != null and jans.get_parsed_text().contains("✕" + first_w), "ja: the missing first unit is marked in the answer line")
	var marks: Array = (_last_ev("submit")["grade"] as Dictionary)["marks"]
	var bad_n := 0
	for m in marks:
		if not bool(m):
			bad_n += 1
	ok(marks.size() == jus.size() and bad_n >= 1 and not bool(marks[0]), "ja: marks align with units and the first is wrong")
	_drop(jd)


# ---------------------------------------------------------------- 줄 끝 · 저장 · 나중에 · 다음 줄

func _answer_line_by_typing(d: SongMemoDrill, s: MemoSession) -> Array:
	## 지금 줄을 끝까지 입력으로 진행. 만난 이벤트 목록.
	var evs: Array = []
	var guard := 0
	while guard < 30:
		guard += 1
		var cur: Dictionary = s.current()
		if not bool(cur.get("ok", false)):
			break
		if _find(d, "NextLineBtn") != null:
			break
		if _find(d, "ReadBtn") != null:
			_press(d, "ReadBtn")
			evs.append("skip_read")
			continue
		if _find(d, "NextBtn") != null:
			_press(d, "NextBtn")
			continue
		d.set_typed(str(cur["text"]))
		_press(d, "SubmitBtn")
		evs.append(str(d.last.get("ev", {}).get("event", "")))
	return evs


func _test_flow() -> void:
	print("[a whole line: finish, save, next line, later]")
	_save_fail = false
	var song: Dictionary = _fresh_song("en")
	var sid: String = _en_id
	var log0: String = _log_json()
	_events.clear()
	var s: MemoSession = _session(song, SongStore.load_memo(sid, song))
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(1)
	var evs: Array = _answer_line_by_typing(d, s)
	await _frames(1)
	ok(evs.count("stage_pass") == 3 and evs[evs.size() - 1] == "line_done", "typing every stage right: skip_read, 3 stage_pass, line_done (%s)" % [evs])
	ok(_ev_count("line_done") == 1 and bool(_last_ev("line_done")["ev"].get("counted", false)), "line_done event once, counted")
	var key: String = MemoModel.line_key(str(song["lines"][0]["text"]), "en")
	var saved: Dictionary = SongStore.load_memo(sid, song)
	ok((saved["lines"] as Dictionary).has(key) and int(saved["lines"][key]["card"]["state"]) == 2, "the finished line is saved: memo.json has a review card for it")
	var rtxt: String = "\n".join(_strings(_find(d, "ResultBox")))
	ok(rtxt.contains("이 줄을 끝냈어요") and rtxt.contains("다음 복습") and _find(d, "NextLineBtn") != null, "line done: verdict, next review time and [next line]")
	ok(_log_json() == log0, "the drill itself wrote nothing to StudyLog (the screen counts drill events)")
	_press(d, "NextLineBtn")
	await _frames(1)
	ok(_ev_count("next_line") == 1 and int(s.current()["pos"]) == 2 and int(s.current()["stage"]) == 0, "[next line]: next_line event, line 2 opens at stage 0")
	# 이 줄 나중에
	_to_stage(s, 2)
	d.render()
	var saved_before: Dictionary = SongStore.load_memo(sid, song)
	_press(d, "LaterBtn")
	await _frames(1)
	ok(_ev_count("later") == 1 and bool(_last_ev("later")["res"]["ok"]) and _ev_count("next_line") == 2, "[later]: later event, then the next line opens")
	var after: Dictionary = SongStore.load_memo(sid, song)
	var k2: String = MemoModel.line_key(str(song["lines"][1]["text"]), "en")
	ok(int(after["lines"][k2]["stage"]) == 2 and not (after["lines"][k2] as Dictionary).has("card") and saved_before != after, "[later]: the reached stage 2 is saved, no card")
	# 큐 끝
	var guard := 0
	while guard < 12 and bool(s.current().get("ok", false)):
		guard += 1
		_answer_line_by_typing(d, s)
		if _find(d, "NextLineBtn") != null:
			_press(d, "NextLineBtn")
		await _frames(1)
	ok(_ev_count("queue_end") == 1 and s.finished, "queue end: queue_end event once, session finished")
	var sm: Dictionary = _last_ev("queue_end")["summary"]
	ok(int(sm["lines_done"]) >= 3 and int(sm["queue_total"]) == 5, "queue_end carries the summary (queue 5, lines done %d)" % int(sm["lines_done"]))
	ok(_find(d, "ResultBox") == null and "\n".join(_strings(d)).contains("모두 했어요"), "after the last line the drill shows an 'all done' notice")
	_drop(d)
	# 연습만: 기록 안 함 안내
	var ps: MemoSession = _session(song, SongStore.load_memo(sid, song), {"only_line": 3, "practice_only": true})
	var pd: SongMemoDrill = _drill(ps, "en")
	var pe: Array = _answer_line_by_typing(pd, ps)
	await _frames(1)
	ok(str(pe[pe.size() - 1]) == "line_done" and "\n".join(_strings(pd)).contains("연습만"), "practice only: finishes and says nothing is recorded")
	_drop(pd)


# ---------------------------------------------------------------- 말하기 (PC)

func _test_speak_pc() -> void:
	print("[speaking: PC with /stt]")
	_mode_pc()
	_save_fail = false
	var song: Dictionary = _fresh_song("en")
	var text0: String = (song["lines"] as Array)[0]["text"]
	_reqs.clear()
	_events.clear()
	Store.prefs["memo_answer"] = "speak"
	var s: MemoSession = _session(song, null, {"only_line": 0})
	_to_stage(s, 1)
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(1)
	Store.prefs.erase("memo_answer")
	ok(d.answer_mode == "speak" and _find(d, "RecordBox") != null and _find(d, "AnswerEdit") == null, "memo_answer=speak: RecordBox instead of the input")
	ok(_find(d, "ModeBtn") != null and _find(d, "RevealBtn") != null, "speak mode: ModeBtn and RevealBtn exist")
	var sent0: int = Api.sent_count
	_speak(d, text0)
	ok(await _until(func() -> bool: return d.phase == "result"), "a good recording is graded")
	var g: Dictionary = _last_ev("submit")["grade"]
	ok(_stt_calls() == 1 and str(_reqs[0]["body"]["lang"]) == "en" and str(_reqs[0]["body"]["audio_b64"]) != "", "exactly one POST /stt with {lang, audio_b64}")
	ok(str(g["via"]) == "speak" and int(g["threshold"]) == 75 and bool(g["passed"]) and _ev_count("stage_pass") == 1, "graded with MemoGrade speak (pass line 75): stage_pass")
	ok(Api.sent_count == sent0, "the /stt call went through the hook (Api.sent_count unchanged)")
	_press(d, "NextBtn")
	# 무음
	var fails0: int = int(s.current()["fails_stage"])
	_events.clear()
	_speak(d, "")
	ok(await _until(func() -> bool: return _ev_count("silent") == 1), "empty /stt text: silent event")
	await _frames(1)
	ok("\n".join(_strings(d)).contains("소리가 들리지 않았어요") and d.phase == "answer", "silence: '소리가 들리지 않았어요' and back to answering")
	ok(int(s.current()["fails_stage"]) == fails0 and _ev_count("submit") == 0 and not bool(s.current()["answered"]), "silence is not an attempt (fails and answered unchanged)")
	# 오인식: 틀리게 나와도 [내가 맞게 말했어요]
	_speak(d, "banana zebra")
	ok(await _until(func() -> bool: return d.phase == "result"), "a wrong recognition is graded")
	ok(_ev_count("stage_fail") == 1 and _find(d, "SelfPassBtn") != null, "wrong speech: stage_fail and [내가 맞게 말했어요] is offered")
	var stage_before: int = int(s.current()["stage"])
	_press(d, "SelfPassBtn")
	await _frames(1)
	ok(_ev_count("self_pass") == 1 and _ev_count("stage_pass") == 1 and int(s.current()["stage"]) == stage_before + 1, "[내가 맞게 말했어요] passes the stage (self_pass event, stage +1)")
	ok("\n".join(_strings(_find(d, "ResultBox"))).contains("✓ 통과"), "after self pass the result says passed")
	_press(d, "NextBtn")
	# 입력 오답은 [내가 맞게 말했어요]가 없다
	d.answer_mode = "type"
	d.render()
	d.set_typed("banana zebra")
	_press(d, "SubmitBtn")
	await _frames(1)
	ok(_find(d, "SelfPassBtn") == null, "a wrong typed answer has no [내가 맞게 말했어요]")
	_press(d, "RetryBtn")
	# /stt 오류 → 자가 평가
	d.answer_mode = "speak"
	d.render()
	_events.clear()
	var calls0: int = _stt_calls()
	_speak_raw(d, {"ok": false, "code": 503, "data": null, "error": ""})
	ok(await _until(func() -> bool: return d.phase == "self" or _stt_calls() > calls0), "an /stt error is reached")
	ok(await _until(func() -> bool: return d.phase == "self"), "/stt error: switches to the self-rating panel")
	ok(_find(d, "SelfRatePanel") != null and _ev_count("stt_error") == 1 and _ev_count("submit") == 0, "/stt error: SelfRatePanel shown, stt_error event, not counted as an attempt")
	ok("\n".join(_strings(d)).contains("스스로 평가"), "/stt error: the explanation is shown")
	var panel: SelfRatePanel = _find(d, "SelfRatePanel") as SelfRatePanel
	var log0: String = _log_json()
	panel.rated.emit(true)
	await _frames(1)
	ok(_ev_count("submit") == 1 and str((_last_ev("submit")["grade"] as Dictionary)["via"]) == "self" and bool((_last_ev("submit")["grade"] as Dictionary)["passed"]), "'잘했어요' after an /stt error passes (via self)")
	ok(_log_json() == log0, "self rating records no StudyLog score")
	# 서버가 글자 없는 오류 객체가 아닌 값을 줌 → 같은 처리
	_press(d, "NextBtn")
	d.answer_mode = "speak"
	d.render()
	_speak_raw(d, "not a dict")
	ok(await _until(func() -> bool: return d.phase == "self"), "a malformed /stt reply also falls back to self rating")
	d.on_hide()
	_drop(d)


# ---------------------------------------------------------------- 폰 단독

func _test_phone_only() -> void:
	print("[phone only: no /stt, self rating]")
	_mode_none()
	_reqs.clear()
	_events.clear()
	var song: Dictionary = _fresh_song("en")
	var s: MemoSession = _session(song, null, {"only_line": 0})
	_to_stage(s, 1)
	Store.prefs["memo_answer"] = "speak"
	var d: SongMemoDrill = _drill(s, "en")
	Store.prefs.erase("memo_answer")
	await _frames(1)
	ok(Route.decide("POST", "/stt", {}) == "none", "phone-only mode: Route.decide('/stt') is 'none'")
	var sent0: int = Api.sent_count
	var log0: String = _log_json()
	_speak(d, "never used")
	await _frames(2)
	ok(d.phase == "self" and _find(d, "SelfRatePanel") != null, "phone only: recording opens the SelfRatePanel")
	ok(_stt_calls() == 0 and _reqs.is_empty() and Api.sent_count == sent0 and d.stt_requests == 0, "phone only: /stt calls 0, requests 0, Api.sent_count unchanged")
	ok(str((_find(d, "SelfRatePanel") as SelfRatePanel).text) == str(s.current()["text"]) and d.line_text() == str(s.current()["text"]), "self rating shows the line to compare with")
	(_find(d, "SelfRatePanel") as SelfRatePanel).rated.emit(true)
	await _frames(1)
	ok(_ev_count("stage_pass") == 1 and _ev_count("submit") == 1, "'잘했어요' -> stage_pass event")
	_press(d, "NextBtn")
	d.answer_mode = "speak"
	d.render()
	_speak(d, "never used")
	await _frames(2)
	(_find(d, "SelfRatePanel") as SelfRatePanel).rated.emit(false)
	await _frames(1)
	ok(_ev_count("stage_fail") == 1 and _find(d, "SelfPassBtn") == null, "'다시' -> stage_fail event, no [내가 맞게 말했어요]")
	ok(_log_json() == log0 and _stt_calls() == 0 and Api.sent_count == sent0, "phone only: StudyLog score count 0, still no /stt, Api.sent_count unchanged")
	# 두 번 '다시' → 정답 공개
	_press(d, "RetryBtn")
	d.answer_mode = "speak"
	d.render()
	_speak(d, "never used")
	await _frames(2)
	(_find(d, "SelfRatePanel") as SelfRatePanel).rated.emit(false)
	await _frames(1)
	ok(_ev_count("revealed") == 1, "two 'again' in a stage reveal the answer")
	_drop(d)
	_mode_pc()


# ---------------------------------------------------------------- 읽어 주기

func _test_listen() -> void:
	print("[listen: allowed at stage 0 and after answering only]")
	_mode_pc()
	var song: Dictionary = _fresh_song("en")
	var text0: String = (song["lines"] as Array)[0]["text"]
	_tts_calls.clear()
	var s: MemoSession = _session(song, null, {"only_line": 0})
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(1)
	ok(not (_find(d, "ListenBtn") as Button).disabled, "stage 0: ListenBtn is enabled")
	_press(d, "ListenBtn")
	await _frames(2)
	ok(_tts_calls.size() == 1 and str(_tts_calls[0]["text"]).strip_edges() == text0 and str(_tts_calls[0]["lang"]) == "en", "stage 0: pressing it speaks the line once")
	_press(d, "ReadBtn")
	var calls: int = _tts_calls.size()
	var all_off := true
	var guard := 0
	while guard < 6 and not bool(s.current()["final"]):
		guard += 1
		d.render()
		if not (_find(d, "ListenBtn") as Button).disabled or d.listen():
			all_off = false
		s.submit(_grade(s))
	d.render()
	await _frames(2)
	ok(all_off and bool(s.current()["final"]) and (_find(d, "ListenBtn") as Button).disabled and not d.listen(), "middle and blank stages (before answering): ListenBtn disabled, listen() refuses")
	ok(_tts_calls.size() == calls, "no Tts call before answering")
	ok(str((_find(d, "ListenNote") as Label).text) != "" and (_find(d, "ListenNote") as Label).visible, "a note says why listening is locked")
	d.set_typed("zzq xxv")
	_press(d, "SubmitBtn")
	await _frames(1)
	ok(not (_find(d, "ListenBtn") as Button).disabled, "after the answer: ListenBtn is enabled")
	_press(d, "ListenBtn")
	await _frames(2)
	ok(_tts_calls.size() == calls + 1 and _ev_count("listen") == 2, "after the answer: one more Tts call")
	# 녹음 중에는 읽어 주기 막기 + Tts 정지
	_press(d, "RetryBtn")
	d.answer_mode = "speak"
	d.render()
	Tts.busy = true
	Tts.playing = true
	var rws: Array = d.find_children("*", "RecorderWidget", true, false)
	(rws[0] as RecorderWidget).state_changed.emit(true)
	ok(not Tts.busy and not Tts.playing, "recording starts -> Tts is stopped")
	# 폰: 시스템 음성이 없으면 비활성 + 안내
	Tts.fetch_hook = Callable()
	Route.phone_hook = func() -> bool: return true
	Store.prefs["tts_engine"] = "system"
	var s2: MemoSession = _session(song, null, {"only_line": 0})
	var d2: SongMemoDrill = _drill(s2, "en")
	await _frames(2)
	var voices_ok: bool = bool(Tts.system_voices_ok().get("en", false))
	if not voices_ok:
		ok((_find(d2, "ListenBtn") as Button).disabled and "\n".join(_strings(d2)).contains("음성"), "phone without a system voice: ListenBtn disabled with the 'no voice' explanation")
		ok(not d2.listen(), "phone without a system voice: listen() does nothing")
	else:
		ok(true, "phone with a system voice (not testable here)")
		ok(true, "phone with a system voice (not testable here)")
	Store.prefs.erase("tts_engine")
	Tts.fetch_hook = Callable(self, "_tts_hook")
	_mode_pc()
	_drop(d2)
	d.on_hide()
	_drop(d)


# ---------------------------------------------------------------- 화면 떠남

func _test_hide() -> void:
	print("[on_hide: recording cancelled, Tts stopped, late replies dropped]")
	_mode_pc()
	Recorder.mode_override = "phone" # cancel() must not send /mic/cancel anywhere
	var song: Dictionary = _fresh_song("en")
	var s: MemoSession = _session(song, null, {"only_line": 0})
	_to_stage(s, 1)
	Store.prefs["memo_answer"] = "speak"
	var d: SongMemoDrill = _drill(s, "en")
	Store.prefs.erase("memo_answer")
	await _frames(1)
	var rw: RecorderWidget = (d.find_children("*", "RecorderWidget", true, false)[0]) as RecorderWidget
	Recorder.recording = true
	Recorder.owner_id = rw.get_instance_id()
	Tts.busy = true
	Tts.playing = true
	d.on_hide()
	ok(not Recorder.recording, "on_hide() cancels the recording")
	ok(not Tts.busy and not Tts.playing, "on_hide() stops Tts")
	# 늦게 오는 /stt 응답
	_events.clear()
	_reqs.clear()
	d.render()
	_speak(d, str((song["lines"] as Array)[0]["text"]), 0.4)
	await _frames(2)
	ok(d.phase == "stt" and _stt_calls() == 1, "a slow /stt request is in flight")
	d.on_hide()
	await get_tree().create_timer(0.7).timeout
	ok(_ev_count("submit") == 0 and _ev_count("stage_pass") == 0 and d.phase == "answer", "a reply that arrives after on_hide() is dropped (no events)")
	ok(int(s.current()["stage"]) == 1 and not bool(s.current()["answered"]), "the late reply did not touch the session")
	# 화면이 트리에서 빠질 때도 녹음 취소
	d.render()
	rw = (d.find_children("*", "RecorderWidget", true, false)[0]) as RecorderWidget
	Recorder.recording = true
	Recorder.owner_id = rw.get_instance_id()
	_drop(d)
	ok(not Recorder.recording, "the drill removed from the tree while recording cancels the recording")
	Recorder.recording = false
	Recorder.mode_override = ""
	# 취소 단추
	var s2: MemoSession = _session(song, null, {"only_line": 0})
	_to_stage(s2, 1)
	var d2: SongMemoDrill = _drill(s2, "en")
	d2.answer_mode = "speak"
	d2.render()
	_events.clear()
	_speak(d2, str((song["lines"] as Array)[0]["text"]), 0.4)
	await _frames(2)
	ok(_press(d2, "CancelBtn") and d2.phase == "answer", "[취소] while waiting for /stt returns to answering")
	await get_tree().create_timer(0.7).timeout
	ok(_ev_count("submit") == 0, "the cancelled /stt reply is ignored")
	_drop(d2)


# ---------------------------------------------------------------- 저장 실패

func _test_save_failed() -> void:
	print("[save failed -> retry]")
	var song: Dictionary = _fresh_song("en")
	var memo: Dictionary = MemoModel.new_memo()
	_save_fail = false
	_events.clear()
	var s: MemoSession = _session(song, memo, {"only_line": 4})
	_to_stage(s, 4)
	var d: SongMemoDrill = _drill(s, "en")
	await _frames(1)
	_save_fail = true
	var calls0: int = _save_calls
	d.set_typed(str(s.current()["text"]))
	_press(d, "SubmitBtn")
	await _frames(1)
	ok(_ev_count("save_failed") == 1 and _ev_count("line_done") == 0, "disk failure at the line end: save_failed event, not line_done")
	var rtxt: String = "\n".join(_strings(_find(d, "ResultBox")))
	ok(rtxt.contains("저장하지 못했어요") and _find(d, "RetrySaveBtn") != null and _find(d, "NextLineBtn") == null, "save failure: explanation and [다시 저장], no [next line]")
	ok((s.memo["lines"] as Dictionary).is_empty() or not (s.memo["lines"] as Dictionary).has(MemoModel.line_key(str(song["lines"][4]["text"]), "en")), "the in-memory memo did not take the unsaved line")
	_press(d, "RetrySaveBtn")
	await _frames(1)
	ok(_ev_count("save_failed") == 2 and _find(d, "RetrySaveBtn") != null, "retry while the disk is still failing: save_failed again, button stays")
	_save_fail = false
	_press(d, "RetrySaveBtn")
	await _frames(1)
	ok(_ev_count("line_done") == 1 and _find(d, "NextLineBtn") != null and _find(d, "RetrySaveBtn") == null, "retry after the disk recovers: line_done and [next line]")
	var saved: Dictionary = SongStore.load_memo(_en_id, song)
	ok((saved["lines"] as Dictionary).has(MemoModel.line_key(str(song["lines"][4]["text"]), "en")) and _save_calls > calls0, "the card was saved on the retry")
	# 나중에: 저장 실패면 나가지 않는다
	var s2: MemoSession = _session(song, MemoModel.new_memo(), {"only_line": 5})
	_to_stage(s2, 2)
	var d2: SongMemoDrill = _drill(s2, "en")
	_save_fail = true
	var nl0: int = _ev_count("next_line")
	_press(d2, "LaterBtn")
	await _frames(1)
	ok(_ev_count("next_line") == nl0 and "\n".join(_strings(d2)).contains("저장하지 못해서"), "[later] with a failing disk: stays on the line and says why")
	_save_fail = false
	_drop(d2)
	_drop(d)


# ---------------------------------------------------------------- 레이아웃

func _layout_check(host: Control, d: SongMemoDrill, label: String) -> void:
	await _frames(3)
	var nbtn: int = 0
	for n in d.find_children("*", "Button", true, false):
		if (n as Button).is_visible_in_tree() and (n as Button).get_global_rect().size.x > 20.0:
			nbtn += 1
	ok(nbtn >= 2 and d.get_global_rect().size.x >= 200.0 and d.get_global_rect().size.x <= host.get_global_rect().size.x + 0.5, "layout [%s]: the drill was laid out (%d sized buttons, width %.0f of %.0f)" % [label, nbtn, d.get_global_rect().size.x, host.get_global_rect().size.x])
	var over: Array = _overflow(host)
	ok(over.is_empty(), "layout [%s]: no control sticks out sideways (%s)" % [label, over.slice(0, 3)])
	var page: PageScroll = host as PageScroll
	if page != null:
		ok(page.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "layout [%s]: the page never scrolls sideways" % label)
	var sm: Array = _small_touch(d)
	ok(sm.is_empty(), "layout [%s]: buttons and inputs are at least Ds.touch_min() (%s)" % [label, sm.slice(0, 3)])


func _test_layout() -> void:
	print("[layout: PC 1280x800 / phone 412x915, font scale %s]" % _scale)
	_mode_pc()
	var song: Dictionary = _fresh_song("en")
	var lines: Array = song["lines"]
	(lines[0] as Dictionary)["text"] = "A " + "supercalifragilistic".repeat(5) + " word and " + "another long phrase to wrap ".repeat(5).strip_edges()
	(lines[0] as Dictionary)["ko"] = "아주 긴 해석 문장입니다. ".repeat(8)
	var page := PageScroll.new(720.0)
	page.size = Vector2(412, 800) if _phone else Vector2(900, 800)
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	var s: MemoSession = _session(song, null, {"only_line": 0})
	var d := SongMemoDrill.new()
	d.lock_msec = 0
	page.content.add_child(d)
	d.setup(s, "en")
	await _layout_check(page, d, "stage 0, long line")
	_press(d, "ReadBtn")
	d.set_typed("x".repeat(300))
	await _layout_check(page, d, "stage 1, long typed text")
	_to_stage(s, 2)
	d.render()
	await _layout_check(page, d, "middle stage")
	_to_stage(s, 4)
	d.render()
	await _layout_check(page, d, "blank stage")
	d.answer_mode = "speak"
	d.render()
	await _layout_check(page, d, "blank stage, speak mode")
	d.answer_mode = "type"
	d.render()
	d.set_typed("The kettle")
	_press(d, "SubmitBtn")
	await _layout_check(page, d, "wrong result (marks)")
	_press(d, "RetryBtn")
	d.answer_mode = "speak"
	d.render()
	_mode_none()
	_speak(d, "x")
	await _frames(2)
	await _layout_check(page, d, "self rating panel")
	_mode_pc()
	var jsong: Dictionary = _fresh_song("ja")
	var js: MemoSession = _session(jsong, null, {"only_line": 0})
	d.session = js
	d.lang = "ja"
	d.phase = "answer"
	d.answer_mode = "type"
	d.render()
	await _layout_check(page, d, "ja stage 0 with reading")
	_drop(page)
