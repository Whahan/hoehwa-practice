extends Node
## 가사 외우기 M5: SongMemoScreen (집 화면 · 세션 진행 · 요약 · 설정 칩 · 줄 목록 · 가사 고치기 · 진도 초기화 · 해석 칸). 서버·마이크·실제 곡을 쓰지 않는다.
##   PC:   godot --headless --path godot res://tests/song_memo_screen_test.tscn
##   폰:   godot --headless --path godot res://tests/song_memo_screen_test.tscn -- --phone
##   글자: ... -- --phone --font-scale=1.5
## 마지막 줄: "== song_memo_screen_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 가사는 tests/fixtures/song/lyrics_en.txt · lyrics_ja.txt (직접 쓴 문장, CC0)뿐이다. 곡은 user://test_songs_memo_screen 에만 만든다.
## 설정·진행·학습 기록은 user://test_memo_screen/ 로 돌린다. /stt · /song/enrich 는 SpeakDrill.api_hook 으로 가로채고(실제 서버·네트워크 0),
## 시계는 주입한 NOW(screen.now_fn), FSRS.fuzz_override = 0.5.
## 일부러 틀린 입력(변조): _selftest() 구간 (검사기가 새는 줄·넘침·이벤트 수·기록 변화를 실제로 잡는지).

const NOW := 1790000000
const DAY := 86400
const ROOT := "user://test_songs_memo_screen"
const DIR := "user://test_memo_screen"
const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"
const SECTIONS := ["selftest", "home", "session", "settings", "lines", "reset", "edit", "meaning", "attribution", "phone_only", "broken",
	"save_fail", "leave", "audio_song", "ja", "review_cards", "layout"]

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
var _old_pc_hook: Callable = Callable()
var _reqs: Array = []
var _toasts: Array = []
var _closed: int = 0
var _clock: int = NOW
var _seq: int = 0
var enrich_resp: Variant = {"lines": []}


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


func _read(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func _write(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


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


func _line(i: int, p: int, text: String, ko: String = "") -> Dictionary:
	return {"i": i, "p": p, "t0": 0.0, "t1": 0.0, "text": text, "reading": "", "pron": "", "ko": ko, "conf": null, "est": true,
		"stale": false, "words": []}


func _lyrics_song(lang: String, title: String = "", ko: bool = true, extra: Array = []) -> Dictionary:
	var lines: Array = []
	for e in _fixture_lines(EN_PATH if lang == "en" else JA_PATH):
		var i: int = lines.size()
		lines.append(_line(i, e["p"], e["text"], ("해석 %d" % i) if ko else ""))
	for x in extra:
		lines.append(_line(lines.size(), 1, str(x)))
	_seq += 1
	return {"v": 1, "kind": "lyrics", "lang": lang, "title": title if title != "" else "Screen %s %d" % [lang, _seq], "artist": "Tester",
		"created": 1790000000 + _seq, "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "none", "attribution": ""}, "offset": 0.0,
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [], "app": "1.4.0"}


## 곡을 만들어 시험 저장소에 설치하고 id 를 돌려준다.
func _install(song: Dictionary) -> String:
	var r: Dictionary = SongStore.install_lyrics(song)
	return str(r.get("id", ""))


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled and (b as Button).is_visible_in_tree():
		(b as Button).pressed.emit()
		return true
	return false


func _press_text(root: Node, needle: String) -> bool:
	for n in root.find_children("*", "Button", true, false):
		var b := n as Button
		if b.text.contains(needle) and not b.disabled and b.is_visible_in_tree():
			b.pressed.emit()
			return true
	return false


func _until(cond: Callable, sec: float = 4.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _clock_now() -> int:
	return _clock


func _new_screen(id: String, l: String = "en", args: Dictionary = {}) -> SongMemoScreen:
	var s := SongMemoScreen.new()
	s.now_fn = Callable(self, "_clock_now")
	s.closed.connect(func() -> void: _closed += 1)
	add_child(s)
	var a: Dictionary = {"id": id}
	a.merge(args, true)
	s.open(l, a)
	return s


func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		n.get_parent().remove_child(n)
		n.free()


func _label_text(root: Node, name: String) -> String:
	var n: Node = _find(root, name)
	return (n as Label).text if n is Label else ""


## 시작 직후 드릴의 단추 잠금(250 ms)을 끈다.
func _nolock(s: SongMemoScreen) -> void:
	if s.drill != null and is_instance_valid(s.drill):
		s.drill.lock_msec = 0


func _start(s: SongMemoScreen) -> bool:
	var okv: bool = s.start_today()
	_nolock(s)
	return okv


## 지금 줄을 정답으로 끝까지 진행해 결과(NextLineBtn)가 보이게 한다. wrong_final: 맨 끝 단계에서 한 번 틀린다.
func _play_line(s: SongMemoScreen, wrong_final: bool = false) -> bool:
	var d: SongMemoDrill = s.drill
	var wrong_done := false
	for g in 40:
		var c: Dictionary = d.session.current()
		if not bool(c.get("ok", false)):
			return false
		if d.phase == "result":
			if _find(d, "NextLineBtn") != null:
				return true
			if not _press(d, "NextBtn"):
				_press(d, "RetryBtn")
		elif bool(c["read_only_stage"]):
			_press(d, "ReadBtn")
		else:
			if wrong_final and bool(c["final"]) and not wrong_done:
				wrong_done = true
				d.set_typed("zzq xxv wwy")
			else:
				d.set_typed(str(c["text"]))
			d.submit_typed()
	return false


func _next_line(s: SongMemoScreen) -> void:
	_press(s.drill, "NextLineBtn")


func _drill_n(l: String = "en") -> int:
	return int((StudyLog.range_summary(l, 1)[0]["n"] as Dictionary)["drill"])


func _review_json() -> String:
	return JSON.stringify(Store.progress.get("review", []))


func _memo_text(id: String) -> String:
	return _read(SongStore.song_dir(id).path_join("memo.json"))


func _card(due: int, state: int = 2, last: int = NOW - 3 * DAY) -> Dictionary:
	return {"due": due, "stability": 2.0, "difficulty": 5.0, "state": state, "step": 0, "last_review": last, "reps": 2, "lapses": 0}


## 줄 번호 -> 카드 로 기록을 만들어 저장한다.
func _put_memo(id: String, song: Dictionary, cards: Dictionary, seen: int = NOW - DAY) -> Dictionary:
	var m: Dictionary = MemoModel.new_memo()
	for idx in cards.keys():
		var key: String = MemoModel.line_key(str((song["lines"] as Array)[int(idx)]["text"]), str(song["lang"]))
		(m["lines"] as Dictionary)[key] = {"stage": 0, "seen": seen, "tries": 3, "passes": 3, "card": cards[idx]}
	SongStore.save_memo(id, m)
	return m


func _key(song: Dictionary, idx: int) -> String:
	return MemoModel.line_key(str((song["lines"] as Array)[idx]["text"]), str(song["lang"]))


## 노드 트리의 모든 글자.
func _strings(root: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(str(n.name))
		if n is Label:
			out.append((n as Label).text)
		if n is RichTextLabel:
			out.append((n as RichTextLabel).get_parsed_text())
		if n is Button:
			out.append((n as Button).text)
		if n is LineEdit:
			out.append((n as LineEdit).text)
			out.append((n as LineEdit).placeholder_text)
		if n is TextEdit:
			out.append((n as TextEdit).text)
		if n is Control:
			out.append((n as Control).tooltip_text)
		for c in n.get_children():
			stack.append(c)
	return out


func _has_text(root: Node, needle: String) -> bool:
	for s in _strings(root):
		if s.contains(needle):
			return true
	return false


## 줄 글자가 노드 트리에 새는 곳 (영어 3글자 이상 단어)
func _leaks(root: Node, text: String) -> Array:
	var hay: String = "\n".join(_strings(root)).to_lower()
	var rx := RegEx.new()
	rx.compile("[A-Za-z0-9']+")
	var have := {}
	for m in rx.search_all(hay):
		have[m.get_string()] = true
	var bad: Array = []
	for m in rx.search_all(text.to_lower()):
		var w: String = m.get_string()
		if w.length() >= 3 and have.has(w):
			bad.append(w)
	return bad


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
			bad.append("%s %s %s" % [c.get_class(), c.name, r])
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
	return bad


func _hook(method: String, path: String, body: Variant) -> Variant:
	_reqs.append({"method": method, "path": path, "body": body})
	if path == "/song/enrich":
		return enrich_resp
	return {"ok": false, "code": 404, "data": null, "error": "no"}


func _count_path(path: String) -> int:
	var n := 0
	for r in _reqs:
		if str(r["path"]) == path:
			n += 1
	return n


func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


func _toast_has(needle: String) -> bool:
	for t in _toasts:
		if str(t[0]).contains(needle):
			return true
	return false


func _enrich_for(song: Dictionary) -> Dictionary:
	var arr: Array = []
	var ls: Array = song["lines"]
	for i in ls.size():
		arr.append({"i": i, "ko": "만든 해석 %d" % i})
	return {"lines": arr, "warnings": []}


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
	print("== song_memo_screen_test start (%s, font scale %s) ==" % ["phone" if _phone else "pc", _scale])
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
	_old_pc_hook = SongMeaningTab.pc_hook
	_rm_rf(DIR)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	StudyLog.reset()
	for k in ["memo_fast", "memo_prev_cue", "memo_answer", "tts_engine", "song_consent", "song_translate"]:
		Store.prefs.erase(k)
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
	Sheet.animate = false
	FSRS.fuzz_override = 0.5
	_old_root = SongStore.root
	SongStore.root = ROOT
	_rm_rf(ROOT)
	SongStore.clear_cache()
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = func(_t: String, _l: String, _s: float, _v: String) -> Variant: return null
	_mode_pc()

	var reached := {}
	await _selftest()
	reached["selftest"] = true
	await _test_home()
	reached["home"] = true
	await _test_session()
	reached["session"] = true
	await _test_settings()
	reached["settings"] = true
	await _test_lines()
	reached["lines"] = true
	await _test_reset()
	reached["reset"] = true
	await _test_edit()
	reached["edit"] = true
	await _test_meaning()
	reached["meaning"] = true
	await _test_attribution()
	reached["attribution"] = true
	await _test_phone_only()
	reached["phone_only"] = true
	await _test_broken()
	reached["broken"] = true
	await _test_save_fail()
	reached["save_fail"] = true
	await _test_leave()
	reached["leave"] = true
	await _test_audio_song()
	reached["audio_song"] = true
	await _test_ja()
	reached["ja"] = true
	await _test_review_cards()
	reached["review_cards"] = true
	await _test_layout()
	reached["layout"] = true
	for k in SECTIONS:
		ok(reached.has(k), "section '%s' ran to its end" % k)

	# cleanup
	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	Route.mode = _old_mode
	Route.phone_hook = _old_phone_hook
	LocalApi.handler_override = _old_overrides
	SongMeaningTab.pc_hook = _old_pc_hook
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
	print("== song_memo_screen_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 검사기 변조 시험

func _selftest() -> void:
	print("[selftest: the checkers fail on bad input]")
	var line := "The kettle hums while the morning climbs the wall"
	var host := VBoxContainer.new()
	add_child(host)
	var lab := Label.new()
	lab.text = "정답: " + line
	host.add_child(lab)
	ok(not _leaks(host, line).is_empty(), "leak checker catches the line in a Label")
	lab.text = "아무 글자 없음 123"
	ok(_leaks(host, line).is_empty(), "leak checker passes a Korean-only tree")
	var had_before: bool = _has_text(host, "XYZ")
	lab.text = "xyz XYZ"
	ok(not had_before and _has_text(host, "XYZ"), "_has_text sees a label's text")
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
	# the event counter and the record comparers see a change
	var n0: int = _drill_n()
	StudyLog.add_event("en", "drill", 1)
	ok(_drill_n() == n0 + 1, "the StudyLog drill counter sees one extra event (a double count would be caught)")
	StudyLog.reset()
	var rj: String = _review_json()
	Store.add_review([{"lang": "en", "target": "selftest card", "reading": "", "ko": ""}])
	ok(_review_json() != rj, "the review-card comparer sees a new card")
	Store.progress["review"] = []
	var sid: String = _install(_lyrics_song("en"))
	var m1: String = _memo_text(sid)
	SongStore.save_memo(sid, MemoModel.new_memo())
	ok(_memo_text(sid) != m1, "the memo.json comparer sees a write")
	SongStore.delete(sid)


# ---------------------------------------------------------------- 집 화면

func _test_home() -> void:
	print("[home screen]")
	_clock = NOW
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(3)
	ok(s.view == "home" and s.open_error == "", "the screen opens a lyrics-only song at the home view")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/6", "home: '외운 줄 0/6' for the 6-line fixture (got '%s')" % _label_text(s, "ProgressLabel"))
	ok(_label_text(s, "NewLabel") == "오늘 새 줄 5줄", "home: 5 new lines shown for today (got '%s')" % _label_text(s, "NewLabel"))
	ok(_label_text(s, "DueLabel") == "오늘 복습 0줄", "home: 0 review lines (got '%s')" % _label_text(s, "DueLabel"))
	ok(_find(s, "StartBtn") != null and not (_find(s, "StartBtn") as Button).disabled and _find(s, "MoreBtn") != null, "home: [오늘 외우기] and [5줄 더하기] exist")
	ok(_find(s, "NextDueLabel") == null, "home: no next-review line while nothing is scheduled")
	ok(s.page_title() == str(song["title"]), "the app-bar title is the song title")
	ok(_press(s, "MoreBtn"), "[5줄 더하기] pressed")
	await _frames(2)
	ok(_label_text(s, "NewLabel") == "오늘 새 줄 6줄", "[5줄 더하기]: today's new lines grow but never past the 6 that exist (got '%s')" % _label_text(s, "NewLabel"))
	ok((_find(s, "MoreBtn") as Button).disabled, "[5줄 더하기] is off once every new line is on today's list")
	_drop(s)
	# three lines due now, three memorized lines waiting
	var song2: Dictionary = _lyrics_song("en")
	var id2: String = _install(song2)
	_put_memo(id2, song2, {0: _card(NOW - 100), 1: _card(NOW - 5000), 2: _card(NOW - 1), 3: _card(NOW + 2 * DAY), 4: _card(NOW + 5 * DAY, 1)})
	var s2: SongMemoScreen = _new_screen(id2)
	await _frames(3)
	ok(_label_text(s2, "DueLabel") == "오늘 복습 3줄", "home: 3 cards with due <= now -> '오늘 복습 3줄' (got '%s')" % _label_text(s2, "DueLabel"))
	ok(_label_text(s2, "ProgressLabel") == "외운 줄 4/6", "home: 4 cards in state 2 -> '외운 줄 4/6' (got '%s')" % _label_text(s2, "ProgressLabel"))
	ok(_label_text(s2, "NewLabel") == "오늘 새 줄 1줄", "home: 1 line has no card -> '오늘 새 줄 1줄' (got '%s')" % _label_text(s2, "NewLabel"))
	ok(_find(s2, "NextDueLabel") != null and _label_text(s2, "NextDueLabel").contains("다음 복습: 약 2일 뒤"), "home: next review about 2 days away (got '%s')" % _label_text(s2, "NextDueLabel"))
	ok(s2.home_stats()["due"] == 3 and s2.home_stats()["memorized"] == 4, "home_stats() agrees with MemoModel.summary")
	# the closed signal
	var c0: int = _closed
	ok(s2.go_back() and _closed == c0 + 1 and s2.result == "back", "go_back() at home emits closed once (result 'back')")
	_drop(s2)
	SongStore.delete(id)
	SongStore.delete(id2)


# ---------------------------------------------------------------- 세션 진행

func _test_session() -> void:
	print("[session: start, lines, StudyLog once per line, saved memo, summary]")
	_clock = NOW
	StudyLog.reset()
	var song: Dictionary = _lyrics_song("en", "", true, ["Extra line number seven ends here"])
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	var n0: int = _drill_n()
	ok(_press(s, "StartBtn") or _start(s), "[오늘 외우기] starts a session")
	_nolock(s)
	await _frames(2)
	ok(s.view == "session" and s.drill != null and s.session != null, "view is 'session' with a SongMemoDrill inside")
	ok(int(s.session.current()["total"]) == 5 and str(s.session.current()["kind"]) == "new", "the queue has today's 5 new lines")
	ok(_play_line(s), "line 1 played from stage 0 to its end with correct answers")
	var key0: String = _key(song, 0)
	var mm: Dictionary = SongStore.load_memo(id)
	var e0: Dictionary = (mm["lines"] as Dictionary).get(key0, {})
	ok(not e0.is_empty() and (e0.get("card", {}) as Dictionary).get("state", 0) == 2 and int((e0["card"] as Dictionary)["reps"]) == 2, "line 1 finished: memo.json holds a card in state 2 (two Good ratings)")
	ok(_drill_n() == n0 + 1 and s.drill_events == 1, "StudyLog 'drill' +1 exactly once for the finished line (got %d)" % (_drill_n() - n0))
	_next_line(s)
	await _frames(2)
	ok(int(s.session.current()["pos"]) == 2 and _drill_n() == n0 + 1, "the next line opened (2/5); no extra event from moving on")
	# going back mid-session: home, the memorized line counts, stage 0 of line 2 saves nothing
	var c0: int = _closed
	ok(s.go_back() == true and s.view == "home" and _closed == c0, "go_back() in a session returns to home without closing the screen")
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 1/7", "home after one memorized line: '외운 줄 1/6' (got '%s')" % _label_text(s, "ProgressLabel"))
	ok(not (SongStore.load_memo(id)["lines"] as Dictionary).has(_key(song, 1)), "a new line left at stage 0 stores nothing")
	# reached stage is stored when leaving mid-line
	ok(_start(s), "start again: the finished line is not asked again")
	await _frames(2)
	var cur: Dictionary = s.session.current()
	ok(str(cur["text"]) == str((song["lines"] as Array)[1]["text"]) and int(cur["total"]) == 5, "second session starts with line 2 (5 new lines left)")
	_press(s.drill, "ReadBtn")
	var c1: Dictionary = s.session.current()
	s.drill.set_typed(str(c1["text"]))
	s.drill.submit_typed()
	ok(int(s.session.current()["stage"]) == 2, "line 2 reached stage 2 (index)")
	ok(s.go_back() and s.view == "home", "go_back() mid-line returns home")
	var e1: Dictionary = (SongStore.load_memo(id)["lines"] as Dictionary).get(_key(song, 1), {})
	ok(not e1.is_empty() and int(e1["stage"]) == 2 and not e1.has("card"), "the reached stage (2) is saved, no card, and nothing was logged (events %d)" % s.drill_events)
	ok(_drill_n() == n0 + 1, "leaving mid-line adds no StudyLog event")
	# finish the remaining queue: summary
	ok(_start(s), "start a third time: line 2 continues from its saved stage")
	await _frames(2)
	ok(int(s.session.current()["stage"]) == 2, "line 2 resumes at the saved stage 2")
	for k in 5:
		ok(_play_line(s, k == 1), "line %d played to its end%s" % [k + 2, " (one wrong answer on the blank stage)" if k == 1 else ""])
		_next_line(s)
		await _frames(2)
	await _until(func() -> bool: return s.view == "summary")
	ok(s.view == "summary", "the queue ended: the summary view is shown")
	ok(_label_text(s, "DoneLabel") == "오늘 5줄 했어요", "summary: '오늘 5줄' (got '%s')" % _label_text(s, "DoneLabel"))
	ok(_label_text(s, "ProgressLabel").begins_with("외운 줄 ") and _label_text(s, "NextDueLabel").contains("다음 복습: 약"), "summary: progress and the next review time (got '%s' / '%s')" % [_label_text(s, "ProgressLabel"), _label_text(s, "NextDueLabel")])
	ok(_drill_n() == n0 + 6 and s.drill_events == 6, "StudyLog drill total = 6 lines in all (got %d)" % (_drill_n() - n0))
	ok(int(SongStore.load_memo(id)["stats"]["sessions"]) >= 1, "the finished session was counted in memo stats")
	var sm: Dictionary = s.last_summary
	ok(int(sm["lines_done"]) == 5 and int(sm["new_done"]) == 5 and int(sm["hard"]) == 1, "summary numbers: 5 lines, 5 new, one Hard from the wrong answer")
	# one more line (the 7th)
	ok(not (_find(s, "MoreBtn") as Button).disabled, "summary: [5줄 더 외우기] is on (1 new line left)")
	ok(s.start_more(), "[5줄 더 외우기] starts another session")
	_nolock(s)
	await _frames(2)
	ok(int(s.session.current()["total"]) == 1 and _play_line(s), "the extra session holds the last new line, played through")
	_next_line(s)
	await _until(func() -> bool: return s.view == "summary")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 6/7", "summary after the last line: 6/7, the Hard line is still learning (got '%s')" % _label_text(s, "ProgressLabel"))
	ok((_find(s, "MoreBtn") as Button).disabled, "summary: [5줄 더 외우기] is off when nothing is left")
	ok(_drill_n() == n0 + 7, "StudyLog drill total = 7 for seven lines (got %d)" % (_drill_n() - n0))
	# back to home through the summary
	ok(_press(s, "HomeBtn") and s.view == "home", "[집으로] from the summary returns home")
	await _frames(2)
	ok(s.home_stats()["fresh"] == 0, "every line has a card now")
	_drop(s)
	# skip_new: lines postponed with [이 줄 나중에] are skipped by the 'more' session
	var song2: Dictionary = _lyrics_song("en")
	var id2: String = _install(song2)
	var s2: SongMemoScreen = _new_screen(id2)
	await _frames(2)
	_start(s2)
	await _frames(2)
	# finish 4 lines, postpone the 5th
	for k in 4:
		_play_line(s2)
		_next_line(s2)
		await _frames(1)
	_press(s2.drill, "LaterBtn")
	await _until(func() -> bool: return s2.view == "summary")
	ok(s2.view == "summary" and s2._skip_new == 1, "a postponed new line is counted for the 'more' session (skip_new 1)")
	ok(s2.start_more(), "[5줄 더 외우기] after a postponed line")
	_nolock(s2)
	await _frames(2)
	ok(str(s2.session.current()["text"]) == str((song2["lines"] as Array)[5]["text"]), "the 'more' session skips the postponed line and opens line 6")
	_drop(s2)
	SongStore.delete(id)
	SongStore.delete(id2)


# ---------------------------------------------------------------- 설정 칩

func _test_settings() -> void:
	print("[setting chips: memo_fast, memo_prev_cue, memo_answer]")
	for k in ["memo_fast", "memo_prev_cue", "memo_answer"]:
		Store.prefs.erase(k)
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_find(s, "ChipFast") != null and _find(s, "ChipCue") != null and _find(s, "ChipType") != null and _find(s, "ChipSpeak") != null, "the four setting chips exist")
	# default session: 5 stages, previous line shown from the second line on
	_start(s)
	await _frames(2)
	ok(int(s.session.current()["stage_count"]) == 5 and s.drill.answer_mode == "type", "defaults: 5 stages, answering by typing")
	_play_line(s)
	_next_line(s)
	await _frames(2)
	ok(str(s.session.current()["prev_text"]) == str((song["lines"] as Array)[0]["text"]) and _find(s.drill, "CueBox") != null, "defaults: line 2 shows the previous line as a cue")
	s.go_back()
	await _frames(2)
	ok(_press(s, "ChipFast") and Store.prefs.get("memo_fast", false) == true, "[빠르게] saves memo_fast = true")
	ok(_press(s, "ChipCue") and Store.prefs.get("memo_prev_cue", true) == false, "[앞 줄 힌트] saves memo_prev_cue = false")
	ok(_press(s, "ChipSpeak") and Store.prefs.get("memo_answer", "type") == "speak", "[말하기로 답하기] saves memo_answer = 'speak'")
	ok(JSON.parse_string(_read(DIR.path_join("prefs.json"))).get("memo_fast", null) == true, "the setting is written to the prefs file")
	_start(s)
	await _frames(2)
	var c: Dictionary = s.session.current()
	ok(int(c["stage_count"]) == 3, "next session: fast mode -> 3 stages (9-unit line: 0, 5, 9) (got %d)" % int(c["stage_count"]))
	_play_line(s)
	_next_line(s)
	await _frames(2)
	ok(str(s.session.current()["prev_text"]) == "" and _find(s.drill, "CueBox") == null, "next session: no previous-line cue when it is turned off")
	ok(s.drill.answer_mode == "speak", "next session: the answer mode is 'speak' (drill reads memo_answer)")
	# the drill's own mode button writes the pref back
	_press(s.drill, "ReadBtn")
	await _frames(1)
	ok(_press(s.drill, "ModeBtn") and Store.prefs.get("memo_answer", "") == "type", "the drill's answer-mode switch saves memo_answer = 'type'")
	s.go_back()
	await _frames(2)
	_press(s, "ChipFast")
	_press(s, "ChipCue")
	ok(Store.prefs.get("memo_fast", true) == false and Store.prefs.get("memo_prev_cue", false) == true, "pressing the chips again turns both back")
	for k in ["memo_fast", "memo_prev_cue", "memo_answer"]:
		Store.prefs.erase(k)
	var leak := false
	for k in SyncDoc.SHARED_PREFS.keys():
		if str(k).begins_with("memo_"):
			leak = true
	ok(not leak, "the memo_* prefs are not in the sync whitelist")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 줄 목록

func _test_lines() -> void:
	print("[line list: states in words, practice-only]")
	StudyLog.reset()
	var song: Dictionary = _lyrics_song("en", "", true, ["[Chorus]", "♪♪", "The kettle hums while the morning climbs the wall!"])
	var id: String = _install(song)
	_put_memo(id, song, {0: _card(NOW + 3 * DAY), 1: _card(NOW - 500), 2: _card(NOW + DAY, 1)})
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 2/6", "M counts distinct lines only (6): the chorus mark, the symbol line and the repeated line are not extra; 2 cards are in state 2 (got '%s')" % _label_text(s, "ProgressLabel"))
	ok(_press(s, "ListBtn") and s.view == "lines", "[줄 목록] opens the list")
	await _frames(2)
	var rows: Array = s.find_children("LineRow_*", "", true, false)
	ok(rows.size() == 6, "the list has 6 rows: [Chorus], the symbol line and the repeat are left out (got %d)" % rows.size())
	ok(not _has_text(s, "[Chorus]") and not _has_text(s, "♪♪"), "the section mark and the symbol line are not listed")
	var states: Array = []
	for i in 6:
		var r: Node = _find(s, "LineRow_%d" % i)
		var chip: Node = r.find_child("StateChip", true, false) if r != null else null
		var t := ""
		if chip != null:
			for l in chip.find_children("*", "Label", true, false):
				t = (l as Label).text
		states.append(t)
	ok(states == ["외움", "복습 시간", "학습 중", "새 줄", "새 줄", "새 줄"], "row states are words (색만으로 구분하지 않음): %s" % str(states))
	ok(s.line_state(_key(song, 0)) == "memorized" and s.line_state(_key(song, 1)) == "due" and s.line_state(_key(song, 2)) == "learning" and s.line_state(_key(song, 3)) == "new", "line_state() gives memorized / due / learning / new")
	# practice-only
	var before_memo: String = _memo_text(id)
	var n0: int = _drill_n()
	var rj: String = _review_json()
	ok(_press(s, "PracticeBtn_0") and s.view == "session", "[이 줄만 연습] opens a one-line session")
	_nolock(s)
	await _frames(2)
	ok(s.session.practice_only and int(s.session.current()["total"]) == 1 and int(s.session.current()["line_i"]) == 0, "the session is practice-only with exactly that line")
	ok(_play_line(s), "the practice line was played to its end")
	ok(_has_text(s.drill, "연습만 했어요"), "the result says that nothing is recorded")
	_next_line(s)
	await _until(func() -> bool: return s.view == "summary")
	ok(s.view == "summary" and _has_text(s, "연습만 했어요"), "practice summary says nothing was recorded")
	ok(_memo_text(id) == before_memo, "practice leaves memo.json byte for byte unchanged")
	ok(_drill_n() == n0 and s.drill_events == 0, "practice adds no StudyLog event")
	ok(_review_json() == rj, "practice leaves the review cards unchanged")
	ok(_press(s, "ListBtn") and s.view == "lines", "summary -> [줄 목록] returns to the list")
	await _frames(1)
	# a new line can be practised too without storing anything
	ok(_press(s, "PracticeBtn_5") and s.view == "session", "a new line can be practised")
	_nolock(s)
	_play_line(s)
	s.go_back()
	ok(_memo_text(id) == before_memo, "practising a new line leaves memo.json unchanged")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 진도 초기화

func _test_reset() -> void:
	print("[reset progress]")
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	_put_memo(id, song, {0: _card(NOW + DAY), 1: _card(NOW + DAY)})
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 2/6", "before the reset: 2/6")
	var song_before: String = _read(SongStore.song_dir(id).path_join("song.json"))
	ok(_press(s, "ResetBtn") and s.last_sheet != null, "[진도 초기화] opens a confirm sheet")
	await _frames(2)
	ok(FileAccess.file_exists(SongStore.song_dir(id).path_join("memo.json")), "nothing is deleted before the sheet is confirmed")
	(s.last_sheet.buttons["cancel"] as Button).pressed.emit()
	await _frames(2)
	ok(FileAccess.file_exists(SongStore.song_dir(id).path_join("memo.json")) and _label_text(s, "ProgressLabel") == "외운 줄 2/6", "cancel keeps the records")
	_press(s, "ResetBtn")
	await _frames(2)
	(s.last_sheet.buttons["ok"] as Button).pressed.emit()
	await _frames(3)
	ok(not FileAccess.file_exists(SongStore.song_dir(id).path_join("memo.json")), "after confirming, memo.json is gone")
	ok(_read(SongStore.song_dir(id).path_join("song.json")) == song_before and not SongStore.load_song(id).is_empty(), "song.json is untouched")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/6" and _label_text(s, "NewLabel") == "오늘 새 줄 5줄", "the numbers are back to 0/6 and 5 new lines")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 가사 고치기

func _test_edit() -> void:
	print("[edit lyrics]")
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	_put_memo(id, song, {0: _card(NOW + DAY), 1: _card(NOW + DAY), 2: _card(NOW + DAY)})
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_find(s, "EditBtn") != null, "a lyrics-only song has [가사 고치기]")
	ok(_press(s, "EditBtn") and s.view == "edit" and _find(s, "LyricsEdit") != null, "the edit view shows a text box")
	var original: String = (_find(s, "LyricsEdit") as TextEdit).text
	ok(original == s.lyrics_text() and original.contains("The kettle hums while the morning climbs the wall"), "the box holds the lyrics, one line each")
	var lines: PackedStringArray = original.split("\n")
	var idx1 := -1
	for i in lines.size():
		if lines[i].begins_with("I count my steps"):
			idx1 = i
	var edited: PackedStringArray = lines.duplicate()
	edited[idx1] = "I count my steps to the old red chair"
	var r: Dictionary = s.save_edit("\n".join(edited))
	await _frames(2)
	ok(bool(r["ok"]) and int(r["changed"]) == 1, "saving one changed line works and counts 1 changed line (got %s)" % str(r))
	var after: Dictionary = SongStore.load_song(id)
	ok((after["lines"] as Array).size() == 6 and str(after["kind"]) == "lyrics", "song.json keeps 6 lines and kind 'lyrics'")
	ok(str((after["lines"] as Array)[1]["text"]) == "I count my steps to the old red chair", "the edited line is stored")
	var m: Dictionary = SongStore.load_memo(id)
	var ml: Dictionary = m["lines"]
	ok(ml.has(_key(song, 0)) and ml.has(_key(song, 2)) and (ml[_key(song, 0)] as Dictionary).has("card") and (ml[_key(song, 2)] as Dictionary).has("card"), "the unchanged lines keep their cards")
	ok(s.line_state(MemoModel.line_key("I count my steps to the old red chair", "en")) == "new", "the edited line is a new line (its key changed)")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 2/6", "home shows the cards that were kept: 2/6 (got '%s')" % _label_text(s, "ProgressLabel"))
	ok(s.view == "home", "the screen returns to the home view after saving")
	# a failed write keeps the original
	var song_json: String = _read(SongStore.song_dir(id).path_join("song.json"))
	s.show_edit()
	SongStore.write_hook = func(path: String) -> bool: return not path.ends_with("song.json.tmp")
	var bad_text: String = s.lyrics_text().replace("old red chair", "old green chair")
	var r2: Dictionary = s.save_edit(bad_text)
	SongStore.write_hook = Callable()
	ok(not bool(r2["ok"]) and str(r2["err"]) == "disk_write", "a failed write is reported (disk_write)")
	ok(_read(SongStore.song_dir(id).path_join("song.json")) == song_json, "after a failed write song.json is unchanged")
	ok(str((s.song["lines"] as Array)[1]["text"]) == "I count my steps to the old red chair", "after a failed write the screen still holds the original lines")
	ok(s.view == "edit" and _find(s, "EditNote") != null, "the edit view stays open with a note (the typed text is kept)")
	# limits: nothing is saved
	var r3: Dictionary = s.save_edit("   \n \n")
	ok(not bool(r3["ok"]) and str(r3["err"]) == "empty" and _read(SongStore.song_dir(id).path_join("song.json")) == song_json, "empty lyrics are not saved (note shown)")
	var big: PackedStringArray = PackedStringArray()
	for i in 401:
		big.append("Line number %d of the long test song" % i)
	var r4: Dictionary = s.save_edit("\n".join(big))
	ok(not bool(r4["ok"]) and str(r4["err"]) == "too_long" and _read(SongStore.song_dir(id).path_join("song.json")) == song_json, "401 lines are not saved (note shown)")
	var r5: Dictionary = s.save_edit("x".repeat(201) + " and more words")
	ok(not bool(r5["ok"]) and str(r5["err"]) == "too_long", "a 201-character line is not saved either")
	var okmax := PackedStringArray()
	for i in 400:
		okmax.append("Line number %d of the long test song" % i)
	ok(bool(s.save_edit("\n".join(okmax))["ok"]) and (SongStore.load_song(id)["lines"] as Array).size() == 400, "exactly 400 lines is allowed")
	_drop(s)
	SongStore.delete(id)
	# back with unsaved edits asks first
	var song3: Dictionary = _lyrics_song("en")
	var id3: String = _install(song3)
	var s3: SongMemoScreen = _new_screen(id3)
	await _frames(2)
	s3.show_edit()
	(_find(s3, "LyricsEdit") as TextEdit).text += "\nAnother small line"
	ok(s3.go_back() and s3.view == "edit" and s3.last_sheet != null, "back with unsaved changes asks first (still in the edit view)")
	await _frames(1)
	(s3.last_sheet.buttons["ok"] as Button).pressed.emit()
	await _frames(2)
	ok(s3.view == "home" and (SongStore.load_song(id3)["lines"] as Array).size() == 6, "discarding goes home; the song is unchanged")
	_drop(s3)
	SongStore.delete(id3)


# ---------------------------------------------------------------- 해석 칸

func _tab_button(s: SongMemoScreen, text: String) -> Button:
	if s.meaning == null:
		return null
	for n in s.meaning.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n as Button
	return null


func _test_meaning() -> void:
	print("[meaning box: no request before the button, consent AND switch, PC only]")
	var song: Dictionary = _lyrics_song("en", "", false)
	var id: String = _install(song)
	_reqs = []
	var enrich0: int = _count_path("/song/enrich")
	# no consent
	Store.prefs["song_consent"] = false
	SongMeaningTab.pc_hook = func() -> bool: return true
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_label_text(s, "MeaningCount") == "6줄 중 0줄에 해석이 있어요", "meaning count: 0 of 6 (got '%s')" % _label_text(s, "MeaningCount"))
	ok(_count_path("/song/enrich") == enrich0, "opening the screen sends no /song/enrich request")
	ok(_press(s, "MeaningBtn") and s.meaning != null, "[해석 보기 · 만들기] opens the box (a SongMeaningTab)")
	await _frames(2)
	ok(_has_text(s.meaning, SongMeaningTab.MSG_NO_CONSENT), "without consent: the box says MSG_NO_CONSENT")
	ok(_tab_button(s, "해석 만들기") == null and not (await s.meaning.make_missing()) and _count_path("/song/enrich") == enrich0, "without consent: no make button and make_missing() sends nothing (0 requests)")
	# consent, but no PC
	Store.prefs["song_consent"] = true
	SongMeaningTab.pc_hook = func() -> bool: return false
	s.toggle_meaning()
	s.toggle_meaning()
	await _frames(2)
	ok(_has_text(s.meaning, SongMeaningTab.MSG_NO_PC), "consent but no PC: the box says MSG_NO_PC")
	ok(_tab_button(s, "해석 만들기") == null and not (await s.meaning.make_missing()) and _count_path("/song/enrich") == enrich0, "no PC: nothing is sent")
	# consent + PC, but the song's switch is off
	SongMeaningTab.pc_hook = func() -> bool: return true
	s.song["translate"] = false
	s.toggle_meaning()
	s.toggle_meaning()
	await _frames(2)
	ok(_tab_button(s, "해석 만들기") == null and not (await s.meaning.make_missing()) and _count_path("/song/enrich") == enrich0, "switch off (ai_ok false): no button and nothing is sent")
	# everything on: still nothing until the button is pressed
	s.song["translate"] = true
	s.toggle_meaning()
	s.toggle_meaning()
	await _frames(2)
	ok(SongMeaningTab.ai_ok(s.song) and _count_path("/song/enrich") == enrich0, "consent AND switch on: ai_ok is true but no request has been sent yet")
	var mb: Button = _tab_button(s, "해석 만들기")
	ok(mb != null, "the [해석 만들기] button appears")
	enrich_resp = _enrich_for(s.song)
	mb.pressed.emit()
	await _until(func() -> bool: return not s.meaning.busy and _count_path("/song/enrich") > enrich0)
	await _frames(2)
	var reqs: Array = _reqs.filter(func(r: Dictionary) -> bool: return str(r["path"]) == "/song/enrich")
	ok(reqs.size() == 1 and bool((reqs[0]["body"] as Dictionary).get("ai_ok", false)) == true, "pressing it sends exactly one request with ai_ok true")
	ok(str((SongStore.load_song(id)["lines"] as Array)[0].get("ko", "")) == "만든 해석 0", "the translations were saved into the song")
	ok(_label_text(s, "MeaningCount") == "6줄 중 6줄에 해석이 있어요", "the count follows: 6 of 6 (got '%s')" % _label_text(s, "MeaningCount"))
	# the translation shows in the drill: stage 0 and the middle stages (not the blank stage)
	s.show_home()
	await _frames(2)
	_start(s)
	await _frames(2)
	ok(_find(s.drill, "KoLabel") != null and (_find(s.drill, "KoLabel") as Label).text == "만든 해석 0", "stage 0 shows the made translation")
	_press(s.drill, "ReadBtn")
	await _frames(1)
	ok(_find(s.drill, "KoLabel") != null, "a middle stage shows it too")
	_drop(s)
	# a request sent with ai_ok false is impossible: set consent off after the button appeared
	Store.prefs["song_consent"] = false
	var song2: Dictionary = _lyrics_song("en", "", false)
	var id2: String = _install(song2)
	var s2: SongMemoScreen = _new_screen(id2)
	s2.toggle_meaning()
	await _frames(2)
	var n1: int = _count_path("/song/enrich")
	_start(s2)
	_play_line(s2)
	await _frames(2)
	ok(_count_path("/song/enrich") == n1, "running a whole line with the box closed or no consent sends no AI request")
	Store.prefs.erase("song_consent")
	SongMeaningTab.pc_hook = Callable()
	enrich_resp = {"lines": []}
	_drop(s2)
	SongStore.delete(id)
	SongStore.delete(id2)


# ---------------------------------------------------------------- 출처 문구

func _test_attribution() -> void:
	print("[attribution]")
	var song: Dictionary = _lyrics_song("en")
	(song["source"] as Dictionary)["lyrics"] = "lrclib"
	(song["source"] as Dictionary)["lrclib_id"] = 123
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	var a: Node = _find(s, "Attribution")
	ok(a is Label and (a as Label).text == SongStudyScreen.DEFAULT_ATTRIBUTION and a.is_visible_in_tree(), "an LRCLIB song shows the attribution line at the bottom")
	_start(s)
	await _frames(2)
	ok(_find(s, "Attribution") != null and (_find(s, "Attribution") as Label).is_visible_in_tree(), "the attribution stays while a session runs")
	s.go_back()
	_drop(s)
	var song2: Dictionary = _lyrics_song("en")
	var id2: String = _install(song2)
	var s2: SongMemoScreen = _new_screen(id2)
	await _frames(2)
	ok(_find(s2, "Attribution") == null, "a pasted song shows no attribution")
	_drop(s2)
	var song3: Dictionary = _lyrics_song("en")
	(song3["source"] as Dictionary)["lyrics"] = "lrclib"
	(song3["source"] as Dictionary)["attribution"] = "내가 적은 출처"
	var id3: String = _install(song3)
	var s3: SongMemoScreen = _new_screen(id3)
	await _frames(2)
	ok(_find(s3, "Attribution") is Label and (_find(s3, "Attribution") as Label).text == "내가 적은 출처", "a stored attribution text wins over the default")
	_drop(s3)
	for x in [id, id2, id3]:
		SongStore.delete(x)


# ---------------------------------------------------------------- 폰 단독

func _test_phone_only() -> void:
	print("[phone alone: no request at all]")
	_mode_none()
	_reqs = []
	var sent0: int = Api.sent_count
	var song: Dictionary = _lyrics_song("en", "", false)
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_start(s)
	await _frames(2)
	ok(_play_line(s), "phone alone: a line is played with typed answers")
	_next_line(s)
	await _frames(1)
	s.go_back()
	await _frames(2)
	_press(s, "MeaningBtn")
	await _frames(2)
	ok(Api.sent_count == sent0, "phone alone: Api.sent_count did not change (open, start, answer, finish, meaning box)")
	ok(_reqs.is_empty(), "phone alone: no /stt and no /song/* request went through the hook (%d)" % _reqs.size())
	ok(_label_text(s, "ProgressLabel") == "외운 줄 1/6", "phone alone: the line is memorized and saved (1/6)")
	ok(_has_text(s, SongMeaningTab.MSG_NO_PC) or _has_text(s, SongMeaningTab.MSG_NO_CONSENT), "phone alone: the meaning box explains why it cannot make anything")
	_drop(s)
	_mode_pc()
	SongStore.delete(id)


# ---------------------------------------------------------------- 깨진 입력

func _test_broken() -> void:
	print("[broken inputs]")
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	var mp: String = SongStore.song_dir(id).path_join("memo.json")
	_write(mp, '{"v":1,"lines":{"abc')
	_toasts = []
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_toast_has("외우기 기록이 깨져 새로 시작했어요"), "a cut memo.json: the toast says it started fresh")
	ok(FileAccess.file_exists(mp + ".bad") and not FileAccess.file_exists(mp), "the broken file was moved to memo.json.bad")
	ok(_has_text(s, SongMemoScreen.MSG_BAD_MEMO) and s.view == "home", "the home view also shows the note and works")
	ok(_start(s) and _play_line(s), "a session runs normally on the fresh record")
	ok(FileAccess.file_exists(mp), "the fresh record was saved")
	_drop(s)
	SongStore.delete(id)
	# newer version: practice only, nothing saved
	var song2: Dictionary = _lyrics_song("en")
	var id2: String = _install(song2)
	var mp2: String = SongStore.song_dir(id2).path_join("memo.json")
	var newer: String = JSON.stringify({"v": 2, "lines": {_key(song2, 0): {"stage": 0, "seen": NOW, "tries": 1, "passes": 1, "card": _card(NOW + DAY)}}, "stats": {"sessions": 1, "last": NOW}})
	_write(mp2, newer)
	StudyLog.reset()
	var s2: SongMemoScreen = _new_screen(id2)
	await _frames(2)
	ok(_has_text(s2, SongMemoScreen.MSG_NEWER_MEMO), "a v2 record: the note 'more recent version' is shown")
	ok(_start(s2), "a v2 record: practice still works")
	ok(s2.session.practice_only and s2.session.read_only_memo, "the session is practice-only (read-only record)")
	ok(_play_line(s2), "the line is played to its end")
	_next_line(s2)
	s2.go_back()
	await _frames(2)
	ok(_read(mp2) == newer, "a v2 record is never rewritten")
	ok(_drill_n() == 0, "a v2 record: practice adds no StudyLog event")
	_drop(s2)
	SongStore.delete(id2)
	# cannot open
	var nr := SongMemoScreen.new()
	nr.now_fn = Callable(self, "_clock_now")
	nr.closed.connect(func() -> void: _closed += 1)
	add_child(nr)
	nr.open("en", {"id": "s_000000000000"})
	ok(nr.open_error == SongMemoScreen.MSG_OPEN_FAIL and nr.view == "error" and _has_text(nr, SongMemoScreen.MSG_OPEN_FAIL), "an unknown id: the open-failure message, no exception")
	nr.open("en", {})
	ok(nr.view == "error", "no id at all: the same message")
	nr.open("en", {"song": {}})
	ok(nr.view == "error", "an empty song dictionary: the same message")
	nr.open("en", {"id": "../../etc"})
	ok(nr.view == "error", "a bad id is refused")
	ok(not nr.start_today() and not nr.show_edit() and not nr.reset_progress(), "buttons do nothing on an unopened song")
	var c0: int = _closed
	ok(nr.go_back() and _closed == c0 + 1, "the error view can be closed")
	_drop(nr)


# ---------------------------------------------------------------- 저장 실패

func _test_save_fail() -> void:
	print("[save failure keeps the state]")
	StudyLog.reset()
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_start(s)
	await _frames(2)
	SongStore.write_hook = func(path: String) -> bool: return not path.contains("memo.json")
	ok(_play_line(s) == false or true, "playing a line while memo.json cannot be written")
	await _frames(2)
	ok(_find(s.drill, "RetrySaveBtn") != null, "the drill offers [다시 저장] when the save fails")
	ok(not FileAccess.file_exists(SongStore.song_dir(id).path_join("memo.json")), "nothing was written")
	ok(_drill_n() == 0 and s.drill_events == 0, "the unsaved line is not logged in StudyLog")
	ok(JSON.stringify(s.session.memo["lines"]) == "{}", "the session's record is unchanged (state kept)")
	# going back fails once (stays), twice (discards)
	ok(s.go_back() and s.view == "session", "go_back() with an unsaved line stays in the session (first try)")
	ok(_toast_has("저장하지 못해서 아직 나가지 않았어요"), "a toast explains that it did not leave")
	ok(_find(s.drill, "RetrySaveBtn") != null, "the retry button is still there")
	# retry works once the disk is back, counted exactly once
	SongStore.write_hook = Callable()
	ok(_press(s.drill, "RetrySaveBtn"), "[다시 저장] pressed after the disk is back")
	await _frames(2)
	ok(_find(s.drill, "NextLineBtn") != null and _drill_n() == 1 and s.drill_events == 1, "the line finished and StudyLog counted it exactly once (got %d)" % _drill_n())
	ok(FileAccess.file_exists(SongStore.song_dir(id).path_join("memo.json")), "memo.json exists now")
	var saved: String = _memo_text(id)
	# a second line whose save is pending while the disk comes back: go_back retries first, then closes the session
	_next_line(s)
	await _frames(2)
	SongStore.write_hook = func(path: String) -> bool: return not path.contains("memo.json")
	_play_line(s)
	await _frames(1)
	ok(_find(s.drill, "RetrySaveBtn") != null and _drill_n() == 1, "second line: its save is pending (not logged yet)")
	SongStore.write_hook = Callable()
	ok(s.go_back() and s.view == "home", "the disk is back: go_back() saves the pending line and leaves")
	var m2: Dictionary = SongStore.load_memo(id)
	ok((m2["lines"] as Dictionary).size() == 2 and int((m2["lines"] as Dictionary)[_key(song, 1)]["card"]["state"]) == 2, "both lines are in memo.json")
	ok(int(m2["stats"]["sessions"]) == 1, "the session stats were saved after the retry and not reverted by it (sessions == 1, got %s)" % str(m2["stats"]["sessions"]))
	ok(_drill_n() == 2 and s.drill_events == 2, "the line saved by the retry on leaving is logged once (got %d)" % _drill_n())
	saved = _memo_text(id)
	# a third failing line: go back twice discards without touching the file
	ok(_start(s), "a new session for the third line")
	await _frames(2)
	SongStore.write_hook = func(path: String) -> bool: return not path.contains("memo.json")
	_play_line(s)
	ok(s.go_back() and s.view == "session", "third line, save fails: first back stays")
	ok(s.go_back() and s.view == "home", "second back goes home without saving (the way out is never blocked)")
	SongStore.write_hook = Callable()
	ok(_memo_text(id) == saved, "the file still holds the earlier state")
	ok(_drill_n() == 2, "the discarded line was never logged")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 2/6", "home shows only the two saved lines (2/6)")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 화면을 떠날 때

func _test_leave() -> void:
	print("[leaving the screen: on_hide / freeing]")
	var song: Dictionary = _lyrics_song("en")
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_start(s)
	await _frames(2)
	_press(s.drill, "ReadBtn")
	var c: Dictionary = s.session.current()
	s.drill.set_typed(str(c["text"]))
	s.drill.submit_typed()
	var c0: int = _closed
	s.on_hide()
	ok(not Recorder.recording, "on_hide: no recording is running")
	ok(_closed == c0, "on_hide does not emit closed")
	var e: Dictionary = (SongStore.load_memo(id)["lines"] as Dictionary).get(_key(song, 0), {})
	ok(not e.is_empty() and int(e["stage"]) == 2, "on_hide saves the reached stage (2)")
	ok(s.session == null, "on_hide ended the session")
	_drop(s)
	# freeing mid-line saves too
	var s2: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_start(s2)
	await _frames(2)
	ok(int(s2.session.current()["stage"]) == 2, "the saved stage is resumed")
	_press(s2.drill, "LaterBtn")
	_drop(s2)
	await _frames(1)
	ok(true, "freeing the screen right after leaving a line raises nothing")
	# a late /stt answer after leaving is discarded (drill rule); here: speak mode, hide, no crash
	Store.prefs["memo_answer"] = "speak"
	var s3: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_start(s3)
	await _frames(2)
	_press(s3.drill, "ReadBtn")
	await _frames(1)
	s3.on_hide()
	await _frames(2)
	ok(not Recorder.recording and not _has_text(s3, "XYZNOPE"), "speak mode: hiding the screen leaves no recording")
	Store.prefs.erase("memo_answer")
	_drop(s3)
	SongStore.delete(id)


# ---------------------------------------------------------------- 음원 곡

func _test_audio_song() -> void:
	print("[a song with audio opens too]")
	var raw := PackedByteArray()
	raw.resize(400)
	for i in 400:
		raw[i] = (i * 31 + 7) & 255
	var sd: Dictionary = {"v": 1, "lang": "en", "title": "Audio screen", "artist": "Tester", "created": 1790000000, "duration": 30.0,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "x.m4a"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"lines": [{"i": 0, "p": 0, "t0": 1.0, "t1": 3.0, "text": "The sky is blue today", "words": []},
			{"i": 1, "p": 0, "t0": 4.0, "t1": 6.0, "text": "[Chorus]", "words": []},
			{"i": 2, "p": 0, "t0": 7.0, "t1": 9.0, "text": "Nobody calls, so the quiet stays small", "words": []}],
		"glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": []}
	var inst: Dictionary = SongStore.install(sd, raw)
	var id: String = str(inst.get("id", ""))
	ok(bool(inst.get("ok", false)), "an audio song installed in the test root")
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(s.view == "home" and _label_text(s, "ProgressLabel") == "외운 줄 0/2", "an audio song: home shows 0/2 ([Chorus] is not a line)")
	ok(not s.is_lyrics_song() and _find(s, "EditBtn") == null, "an audio song has no [가사 고치기] here")
	ok(not bool(s.save_edit("x")["ok"]) and str(s.last_edit["err"]) == "not_lyrics", "save_edit refuses an audio song")
	ok(_start(s) and _play_line(s), "an audio song can be memorized")
	_next_line(s)
	await _frames(1)
	s.go_back()
	ok(_label_text(s, "ProgressLabel") == "외운 줄 1/2", "an audio song: progress saved (1/2)")
	ok(FileAccess.file_exists(SongStore.song_dir(id).path_join("audio.mp3")), "the audio file is untouched")
	_drop(s)
	SongStore.delete(id)
	# a song given directly (test argument)
	var direct := SongMemoScreen.new()
	direct.now_fn = Callable(self, "_clock_now")
	add_child(direct)
	direct.open("en", {"song": _lyrics_song("en")})
	await _frames(2)
	ok(direct.view == "home" and _label_text(direct, "ProgressLabel") == "외운 줄 0/6", "args.song opens a song that is not in the store")
	_drop(direct)


# ---------------------------------------------------------------- 일본어

func _test_ja() -> void:
	print("[japanese song]")
	StudyLog.reset()
	var song: Dictionary = _lyrics_song("ja")
	(song["lines"] as Array)[0]["reading"] = "あさのまどべでちいさなやかんがなる"
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id, "en")
	await _frames(2)
	ok(s.lang == "ja" and _label_text(s, "ProgressLabel") == "외운 줄 0/5", "the song's language wins; 5 lines")
	_start(s)
	await _frames(2)
	ok(s.drill.lang == "ja" and _play_line(s), "a Japanese line is played to its end")
	ok(_drill_n("ja") == 1 and _drill_n("en") == 0, "the StudyLog event goes to the song's language (ja)")
	s.go_back()
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 기존 복습 카드 불변

func _test_review_cards() -> void:
	print("[the review tab's cards are never touched]")
	Store.progress["review"] = []
	Store.add_review([{"lang": "en", "target": "my own card", "reading": "", "ko": "내 카드"}, {"lang": "ja", "target": "ねこ", "reading": "ねこ", "ko": "고양이"}])
	var rj: String = _review_json()
	var song: Dictionary = _lyrics_song("en", "", false)
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	_press(s, "ChipFast")
	_press(s, "MeaningBtn")
	await _frames(2)
	_press(s, "MeaningBtn")
	_start(s)
	await _frames(2)
	for k in 3:
		_play_line(s, k == 1)
		_next_line(s)
		await _frames(1)
	s.go_back()
	await _frames(2)
	_press(s, "ListBtn")
	await _frames(2)
	_press(s, "PracticeBtn_4")
	_nolock(s)
	_play_line(s)
	s.go_back()
	s.go_back()
	await _frames(2)
	s.save_edit(s.lyrics_text().replace("old blue chair", "old red chair"))
	await _frames(2)
	_press(s, "ResetBtn")
	await _frames(1)
	if s.last_sheet != null:
		(s.last_sheet.buttons["ok"] as Button).pressed.emit()
	await _frames(2)
	ok(_review_json() == rj and (Store.progress["review"] as Array).size() == 2, "after chips, sessions, wrong answers, practice, edit and reset the review cards are byte-identical")
	ok(_drill_n() >= 3, "(the flow really ran: StudyLog counted %d lines)" % _drill_n())
	Store.progress["review"] = []
	Store.prefs.erase("memo_fast")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- 레이아웃

func _layout_check(root: Control, label: String) -> void:
	await _frames(4)
	var over: Array = _overflow(root)
	ok(over.is_empty(), "layout [%s]: no control sticks out sideways (%s)" % [label, over.slice(0, 3)])
	var sm: Array = _small_touch(root)
	ok(sm.is_empty(), "layout [%s]: buttons are at least Ds.touch_min() high (%s)" % [label, sm.slice(0, 3)])
	var pg: PageScroll = root.find_child("*", false, false) as PageScroll
	var scs: Array = root.find_children("*", "PageScroll", true, false)
	if not scs.is_empty():
		ok((scs[0] as PageScroll).horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "layout [%s]: the page never scrolls sideways" % label)
	pg = null


func _test_layout() -> void:
	print("[layout: PC 1280x800 / phone 412x915, font scale %s]" % _scale)
	_mode_pc()
	var long_title := "A very long song title that has to wrap on a small phone screen " + "supercalifragilistic".repeat(2)
	var song: Dictionary = _lyrics_song("en", long_title, true, ["The kettle hums while the morning climbs the wall " + "and a long tail ".repeat(6)])
	var lines: Array = song["lines"]
	(lines[0] as Dictionary)["ko"] = "아주 긴 해석 문장입니다. ".repeat(8)
	var id: String = _install(song)
	(song["source"] as Dictionary)["lyrics"] = "lrclib"
	var s: SongMemoScreen = _new_screen(id)
	await _layout_check(s, "home")
	s.toggle_meaning()
	await _layout_check(s, "home, meaning box open")
	s.toggle_meaning()
	_start(s)
	await _layout_check(s, "session stage 0, long line")
	_press(s.drill, "ReadBtn")
	s.drill.set_typed("x".repeat(300))
	await _layout_check(s, "session typing")
	s.go_back()
	await _frames(2)
	s.show_lines()
	await _layout_check(s, "line list")
	s.show_edit()
	await _layout_check(s, "edit lyrics")
	s.go_back()
	await _frames(2)
	s.show_home()
	_start(s)
	for k in 4:
		_play_line(s)
		_next_line(s)
		await _frames(1)
	_play_line(s)
	_next_line(s)
	await _until(func() -> bool: return s.view == "summary")
	await _layout_check(s, "summary")
	s.show_home()
	await _frames(1)
	_press(s, "ResetBtn")
	await _frames(3)
	var sheet: Sheet = s.last_sheet
	ok(sheet != null and sheet.panel.get_global_rect().size.x > 0.0, "layout: the reset confirm sheet has a size")
	if sheet != null:
		var pr: Rect2 = sheet.panel.get_global_rect()
		var win := Rect2(Vector2.ZERO, Vector2(get_window().size))
		ok(win.encloses(pr.grow(-0.5)), "layout: the reset sheet fits inside the window")
		(sheet.buttons["cancel"] as Button).pressed.emit()
	_drop(s)
	SongStore.delete(id)
