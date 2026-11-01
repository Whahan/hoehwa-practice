extends Node
## 가사 외우기 "뜻 보기" (1.5.1): 연습 줄 위의 한국어 해석 · 설정 칩 [뜻 보기] · 집 화면 안내 카드와 해석 만들기. 서버·마이크·실제 곡을 쓰지 않는다.
##   PC:   godot --headless --path godot res://tests/memo_ko_test.tscn
##   폰:   godot --headless --path godot res://tests/memo_ko_test.tscn -- --phone
## 마지막 줄: "== memo_ko_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 가사는 tests/fixtures/song/lyrics_en.txt · lyrics_ja.txt (직접 쓴 문장, CC0)뿐이다. 곡은 user://test_songs_memo_ko 에만 만든다.
## 설정·진행·학습 기록은 user://test_memo_ko/ 로 돌린다. /song/enrich 는 SpeakDrill.api_hook 으로 가로챈다(가짜 서버: 실제 서버·네트워크 0).
## 일부러 틀린 입력: _selftest() 구간. 변조 시험(동의 검사 제거 -> FAIL, stale 검사 제거 -> FAIL)은 러너 보고에 있다(소스를 잠깐 바꿔 이 시험을 돌린다).

const NOW := 1790000000
const DAY := 86400
const ROOT := "user://test_songs_memo_ko"
const DIR := "user://test_memo_ko"
const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"
const SECTIONS := ["selftest", "show", "toggle", "missing", "card_table", "make", "late"]

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _before: Dictionary = {}
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_status: Variant
var _old_health: Dictionary = {}
var _old_prefs_data: Dictionary = {}
var _old_mode: String = ""
var _old_phone_hook: Callable = Callable()
var _old_overrides: Dictionary = {}
var _old_root: String = ""
var _old_pc_hook: Callable = Callable()
var _reqs: Array = []
var _clock: int = NOW
var _seq: int = 0
var _hold: bool = false ## true 인 동안 가짜 /song/enrich 는 응답을 미룬다
var _ai_requests: int = 0
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


func _line(i: int, p: int, text: String, ko: String = "", stale: bool = false) -> Dictionary:
	return {"i": i, "p": p, "t0": 0.0, "t1": 0.0, "text": text, "reading": "", "pron": "", "ko": ko, "conf": null, "est": true,
		"stale": stale, "words": []}


## 곡 사전. kos: 줄마다의 해석(없으면 ""), stales: stale 로 표시할 줄 번호들, extra: [{text, ko, stale}] 뒤에 더하는 줄.
func _song(lang: String, kos: Array, stales: Array = [], extra: Array = []) -> Dictionary:
	var lines: Array = []
	for e in _fixture_lines(EN_PATH if lang == "en" else JA_PATH):
		var i: int = lines.size()
		var ko: String = str(kos[i]) if i < kos.size() else ""
		lines.append(_line(i, e["p"], e["text"], ko, stales.has(i)))
	for x in extra:
		lines.append(_line(lines.size(), 1, str(x["text"]), str(x.get("ko", "")), bool(x.get("stale", false))))
	_seq += 1
	return {"v": 1, "kind": "lyrics", "lang": lang, "title": "Ko %s %d" % [lang, _seq], "artist": "Tester",
		"created": 1790000000 + _seq, "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "none", "attribution": ""}, "offset": 0.0,
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [], "app": "1.4.0"}


func _all_ko(n: int = 6) -> Array:
	var a: Array = []
	for i in n:
		a.append("뜻 %d" % i)
	return a


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


func _until(cond: Callable, sec: float = 4.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _clock_now() -> int:
	return _clock


func _new_screen(id: String, l: String = "en") -> SongMemoScreen:
	var s := SongMemoScreen.new()
	s.now_fn = Callable(self, "_clock_now")
	add_child(s)
	s.open(l, {"id": id})
	return s


func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		n.get_parent().remove_child(n)
		n.free()


func _start(s: SongMemoScreen) -> bool:
	var okv: bool = s.start_today()
	if s.drill != null and is_instance_valid(s.drill):
		s.drill.lock_msec = 0
	return okv


func _practice(s: SongMemoScreen, i: int) -> bool:
	var okv: bool = s.practice_line(i)
	if s.drill != null and is_instance_valid(s.drill):
		s.drill.lock_msec = 0
	return okv


func _to_stage(s: SongMemoScreen, stage: int) -> void:
	var d: SongMemoDrill = s.drill
	for g in 30:
		var c: Dictionary = d.session.current()
		if int(c["stage"]) >= stage or bool(c["final"]):
			d.render()
			return
		if bool(c["read_only_stage"]):
			d.session.skip_read()
		else:
			d.session.submit(MemoGrade.grade(str(c["lang"]), str(c["text"]), {"text": c["text"], "reading": c["reading"]}, "type"))
	d.render()


func _hook(method: String, path: String, body: Variant) -> Variant:
	_reqs.append({"method": method, "path": path, "body": body})
	if path == "/song/enrich":
		while _hold:
			await get_tree().process_frame
		if enrich_resp is Callable:
			return (enrich_resp as Callable).call(body)
		return enrich_resp
	return {"ok": false, "code": 404, "data": null, "error": "no"}


func _count_path(path: String) -> int:
	var n := 0
	for r in _reqs:
		if str(r["path"]) == path:
			n += 1
	return n


## 요청 본문의 줄 번호들.
func _req_indices(k: int) -> Array:
	var out: Array = []
	var seen := 0
	for r in _reqs:
		if str(r["path"]) == "/song/enrich":
			if seen == k:
				for e in (r["body"] as Dictionary).get("lines", []):
					out.append(int(e["i"]))
				return out
			seen += 1
	return out


func _enrich_all(body: Variant) -> Dictionary:
	var arr: Array = []
	for e in (body as Dictionary).get("lines", []):
		arr.append({"i": int(e["i"]), "ko": "만든 뜻 %d" % int(e["i"])})
	return {"lines": arr, "warnings": []}


func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


## 환경을 정한다: pc(PC 연결 가짜), ai("ready" | "not_connected" | "blocked" | "down"), consent(동의 여부).
func _env(pc: bool, ai: String, consent: bool) -> void:
	SongMeaningTab.pc_hook = func() -> bool: return pc
	match ai:
		"down":
			Backend.status = Backend.Status.FAILED
			Backend.health = {}
		_:
			Backend.status = Backend.Status.READY
			Backend.health = {"llm": ai == "ready", "llm_state": ai, "song": true}
	if consent:
		Store.prefs["song_consent"] = true
	else:
		Store.prefs.erase("song_consent")
	Store.prefs.erase("song_translate")
	if pc:
		_mode_pc()
	else:
		_mode_none()


func _ko_label(root: Node) -> Label:
	var n: Node = _find(root, "KoLabel")
	return n as Label if n is Label else null


## 화면에 보이는 해석 글자 ("" = 없음).
func _ko_text(root: Node) -> String:
	var l: Label = _ko_label(root)
	return l.text if l != null and l.is_visible_in_tree() else ""


## 해석 Label 이 줄 상자(LineBox)보다 위(앞)에 있나.
func _ko_above_line(root: Node) -> bool:
	var kl: Label = _ko_label(root)
	var lb: Node = _find(root, "LineBox")
	if kl == null or lb == null or kl.get_parent() != lb.get_parent():
		return false
	return kl.get_index() < lb.get_index()


## 줄 카드의 직접 자식 수 (해석이 없을 때 빈 자리가 없는지 비교).
func _card_children(root: Node) -> int:
	var lb: Node = _find(root, "LineBox")
	return lb.get_parent().get_child_count() if lb != null else -1


func _node_counts() -> Array:
	return [int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))]


func _saved_ko(id: String) -> Array:
	var out: Array = []
	for d in SongStore.load_song(id).get("lines", []):
		out.append(str((d as Dictionary).get("ko", "")))
	return out


func _reset_env() -> void:
	_reqs = []
	_hold = false
	enrich_resp = {"lines": []}
	SongMemoScreen.reset_auto()


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	print("== memo_ko_test start (%s) ==" % ("phone" if _phone else "pc"))
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	_before = _user_listing()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
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
	for k in ["memo_fast", "memo_prev_cue", "memo_answer", "memo_show_ko", "tts_engine", "song_consent", "song_translate"]:
		Store.prefs.erase(k)
	Store.ai_connect_requested.connect(func() -> void: _ai_requests += 1)
	Backend._starting = true
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port: this run must never reach the user's engine (8770)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", 1.0)
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
	_env(false, "down", false)

	var reached := {}
	await _selftest()
	reached["selftest"] = true
	await _test_show()
	reached["show"] = true
	await _test_toggle()
	reached["toggle"] = true
	await _test_missing()
	reached["missing"] = true
	await _test_card_table()
	reached["card_table"] = true
	await _test_make()
	reached["make"] = true
	await _test_late()
	reached["late"] = true
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
	Backend.status = _old_status
	Backend.health = _old_health
	FSRS.fuzz_override = -1.0
	SongStore.root = _old_root
	SongMemoScreen.reset_auto()
	_rm_rf(ROOT)
	_rm_rf(DIR)
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Store.prefs = _old_prefs_data
	ok(_user_listing() == _before, "the user's own song folder and app files were not touched")
	print("== memo_ko_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 검사기 selfcheck (일부러 틀린 입력)

func _selftest() -> void:
	print("[selftest: the checkers fail on bad input]")
	var host := VBoxContainer.new()
	add_child(host)
	# 해석 Label 찾기: 없으면 "", 있으면 정확한 글자, 안 보이면 ""
	ok(_ko_text(host) == "" and _ko_label(host) == null, "ko finder: no KoLabel -> empty")
	var lb := VBoxContainer.new()
	lb.name = "LineBox"
	host.add_child(lb)
	var kl := Label.new()
	kl.name = "KoLabel"
	kl.text = "정확한 뜻"
	host.add_child(kl)
	await _frames(1)
	ok(_ko_text(host) == "정확한 뜻" and _ko_text(host) != "다른 뜻", "ko finder: returns the exact text and not another")
	ok(not _ko_above_line(host), "above-line checker fails when the label comes AFTER the line box")
	host.move_child(kl, 0)
	ok(_ko_above_line(host), "above-line checker passes when the label comes before the line box")
	kl.visible = false
	ok(_ko_text(host) == "", "ko finder: a hidden label is not 'shown'")
	var c0: int = _card_children(host)
	kl.get_parent().remove_child(kl)
	ok(_card_children(host) == c0 - 1, "children counter sees a removed label (an empty slot would be caught)")
	kl.free()
	_drop(host)
	# 노드 수 비교: 새는 노드를 실제로 잡는다
	var n0: Array = _node_counts()
	var leak := Node.new()
	add_child(leak)
	ok(_node_counts()[0] == int(n0[0]) + 1, "node counter sees one extra node (a leaked maker would be caught)")
	_drop(leak)
	await _frames(2)
	ok(_node_counts() == n0, "node counter returns to the start after the node is freed")
	# 요청·전송 카운터
	var s0: int = Api.sent_count
	Api.sent_count += 1
	ok(Api.sent_count != s0, "Api.sent_count comparer sees a bump (a phone-alone send would be caught)")
	Api.sent_count = s0
	_reqs = []
	_reqs.append({"method": "POST", "path": "/song/enrich", "body": {}})
	ok(_count_path("/song/enrich") == 1, "request counter sees one request")
	_reqs = []
	# 해석 규칙 (정적): stale · 공백 · 없음은 ""
	var sg: Dictionary = _song("en", ["뜻 A", "뜻 B"], [1])
	ok(SongMemoDrill.ko_text(sg, 0, "en") == "뜻 A", "ko_text: a normal line returns its meaning")
	ok(SongMemoDrill.ko_text(sg, 1, "en") == "", "ko_text: a stale line returns nothing (bad input is rejected)")
	ok(SongMemoDrill.ko_text(sg, 2, "en") == "" and SongMemoDrill.ko_text(sg, 99, "en") == "" and SongMemoDrill.ko_text(sg, -1, "en") == "", "ko_text: empty / out-of-range -> nothing")
	var sw: Dictionary = _song("en", ["   "])
	ok(SongMemoDrill.ko_text(sw, 0, "en") == "", "ko_text: a blank string returns nothing")
	# 카드 상태 표: 동의가 없으면 ready 가 될 수 없다
	_env(true, "ready", false)
	ok(SongMemoScreen.ko_card_state(_song("en", [])) == "consent", "card state: no consent can never be 'ready'")
	_env(true, "ready", true)
	ok(SongMemoScreen.ko_card_state(_song("en", [])) == "ready", "card state: consent + PC + ready AI is 'ready'")
	ok(SongMemoScreen.ko_card_state(_song("en", _all_ko())) == "none", "card state: nothing missing is 'none'")
	_env(false, "down", false)


# ---------------------------------------------------------------- (a) 줄 위의 해석

## 단계마다 보이는 해석을 확인한다 (읽기 · 가림 · 빈 화면 · 결과).
func _check_stages(s: SongMemoScreen, want: String, label: String) -> void:
	var d: SongMemoDrill = s.drill
	var c: Dictionary = d.session.current()
	var kinds: Array = []
	for g in 12:
		c = d.session.current()
		var tag: String = "%s stage %d/%d" % [label, int(c["stage"]), int(c["stage_count"]) - 1]
		var kl: Label = _ko_label(d)
		ok(_ko_text(d) == want and _ko_above_line(d), "%s: the meaning '%s' shows exactly, above the line (got '%s')" % [tag, want, _ko_text(d)])
		if kl != null:
			ok(kl.max_lines_visible == 2 and kl.get_theme_color("font_color") == Pal.MUTED, "%s: small MUTED label, at most 2 lines" % tag)
		kinds.append(bool(c["final"]))
		if bool(c["final"]):
			break
		if bool(c["read_only_stage"]):
			d.session.skip_read()
		else:
			d.session.submit(MemoGrade.grade(str(c["lang"]), str(c["text"]), {"text": c["text"], "reading": c["reading"]}, "type"))
		d.render()
		await _frames(1)
	ok(kinds.has(true), "%s: reached the blank stage" % label)
	# 결과 (정답 뒤)
	d.set_typed(str(d.session.current()["text"]))
	d.submit_typed()
	await _frames(1)
	ok(d.phase == "result" and _ko_text(d) == want and _ko_above_line(d), "%s: the meaning stays above the answer after answering" % label)


func _test_show() -> void:
	print("[a: the meaning shows above the line]")
	_reset_env()
	_env(false, "down", false)
	# 새 줄: 읽기 -> 가림 -> 빈 화면 -> 결과
	var song: Dictionary = _song("en", _all_ko())
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	ok(_start(s), "a session starts")
	await _frames(2)
	await _check_stages(s, "뜻 0", "new line")
	_drop(s)
	SongStore.delete_memo(id) # the first line was finished above: start again from a clean record
	# 말하기 모드
	Store.prefs["memo_answer"] = "speak"
	s = _new_screen(id)
	await _frames(2)
	_start(s)
	await _frames(2)
	s.drill.session.skip_read()
	s.drill.render()
	await _frames(1)
	ok(_find(s.drill, "RecordBox") != null and _ko_text(s.drill) == "뜻 0" and _ko_above_line(s.drill), "speak mode: the meaning shows above the line next to the record box")
	_to_stage(s, 99)
	await _frames(1)
	ok(bool(s.drill.session.current()["final"]) and _find(s.drill, "RecordBox") != null and _ko_text(s.drill) == "뜻 0", "speak mode, blank stage: the meaning shows")
	Store.prefs.erase("memo_answer")
	_drop(s)
	# 복습 카드: 맨 끝 단계(빈 화면)에서 시작하는 줄
	var cards := {}
	var mm: Dictionary = MemoModel.new_memo()
	var key: String = MemoModel.line_key(str(song["lines"][2]["text"]), "en")
	(mm["lines"] as Dictionary)[key] = {"stage": 0, "seen": NOW - DAY, "tries": 3, "passes": 3,
		"card": {"due": NOW - 100, "stability": 2.0, "difficulty": 5.0, "state": 2, "step": 0, "last_review": NOW - 3 * DAY, "reps": 2, "lapses": 0}}
	SongStore.save_memo(id, mm)
	cards[0] = 1
	s = _new_screen(id)
	await _frames(2)
	_start(s)
	await _frames(2)
	var cur: Dictionary = s.drill.session.current()
	ok(str(cur["kind"]) == "review" and bool(cur["final"]) and int(cur["line_i"]) == 2, "a due review card opens at the blank stage (line 2)")
	ok(_find(s.drill, "BlankHint") != null and s.drill.line_text() == "", "the blank stage shows no line text")
	ok(_ko_text(s.drill) == "뜻 2" and _ko_above_line(s.drill), "review card: the meaning shows exactly above the blank (got '%s')" % _ko_text(s.drill))
	ok(not _has_line(s.drill, str(cur["text"])), "review card: the answer line does not leak into any label")
	_drop(s)
	SongStore.delete(id)
	# 후렴 묶음: 같은 글자의 줄은 한 줄로 센다. 첫 줄에 해석이 없으면 같은 글자의 다른 줄 해석을 쓴다
	var chorus: String = "Hey hey the lamp is on"
	var cs: Dictionary = _song("en", [], [], [{"text": chorus, "ko": ""}, {"text": "Another verse of nothing much", "ko": "또 다른 절"}, {"text": chorus, "ko": "후렴 해석"}])
	var cid: String = _install(cs)
	s = _new_screen(cid)
	await _frames(2)
	var chorus_i: int = 6
	ok(_practice(s, chorus_i), "practice the first chorus line")
	await _frames(2)
	ok(int(s.drill.session.current()["line_i"]) == chorus_i, "the chorus group opens at its first line (6)")
	ok(_ko_text(s.drill) == "후렴 해석" and _ko_above_line(s.drill), "chorus group: shows the meaning of the repeated line (got '%s')" % _ko_text(s.drill))
	_to_stage(s, 99)
	await _frames(1)
	ok(_ko_text(s.drill) == "후렴 해석", "chorus group, blank stage: still shown")
	_drop(s)
	# 첫 줄에 해석이 있으면 그것을 쓴다
	SongStore.delete(cid)
	var cs2: Dictionary = _song("en", ["", "", "", "", "", ""], [], [{"text": chorus, "ko": "첫 후렴 뜻"}, {"text": chorus, "ko": "둘째 후렴 뜻"}])
	var cid2: String = _install(cs2)
	s = _new_screen(cid2)
	await _frames(2)
	_practice(s, 6)
	await _frames(2)
	ok(_ko_text(s.drill) == "첫 후렴 뜻", "chorus group: the first line's own meaning wins (got '%s')" % _ko_text(s.drill))
	_drop(s)
	SongStore.delete(cid2)
	# 일본어
	var js: Dictionary = _song("ja", ["일본어 뜻 0", "일본어 뜻 1"])
	var jid: String = _install(js)
	s = _new_screen(jid, "ja")
	await _frames(2)
	_practice(s, 1)
	await _frames(2)
	ok(_ko_text(s.drill) == "일본어 뜻 1" and _ko_above_line(s.drill), "ja song: the meaning shows (got '%s')" % _ko_text(s.drill))
	_to_stage(s, 99)
	await _frames(1)
	ok(_ko_text(s.drill) == "일본어 뜻 1", "ja song, blank stage: still shown")
	_drop(s)
	SongStore.delete(jid)
	# 긴 해석은 2줄에서 잘린다
	var long_ko: String = "아주 긴 해석 문장입니다. ".repeat(12)
	var ls: Dictionary = _song("en", [long_ko])
	var lid: String = _install(ls)
	var page := PageScroll.new(720.0)
	page.size = Vector2(412, 800) if _phone else Vector2(900, 800)
	add_child(page)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sess := MemoSession.new()
	sess.begin(SongStore.load_song(lid), MemoModel.new_memo(), NOW, {"only_line": 0, "practice_only": true, "clock": Callable(self, "_clock_now")})
	var d := SongMemoDrill.new()
	d.lock_msec = 0
	page.content.add_child(d)
	d.setup(sess, "en")
	await _frames(4)
	var kl: Label = _ko_label(d)
	ok(kl != null and kl.get_line_count() > 2, "the long meaning needs more than 2 lines (%d)" % (kl.get_line_count() if kl != null else -1))
	ok(kl != null and kl.get_visible_line_count() <= 2, "…but at most 2 are shown (the rest is cut)")
	ok(kl != null and kl.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "the cut text ends with an ellipsis")
	var over: Array = _overflow(page)
	ok(over.is_empty(), "the long meaning does not stick out sideways (%s)" % [over.slice(0, 3)])
	_drop(page)
	SongStore.delete(lid)


func _has_line(root: Node, text: String) -> bool:
	var hay: String = "\n".join(_strings(root)).to_lower()
	return hay.contains(text.to_lower())


func _strings(root: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label:
			out.append((n as Label).text)
		if n is RichTextLabel:
			out.append((n as RichTextLabel).get_parsed_text())
		if n is Button:
			out.append((n as Button).text)
		if n is LineEdit:
			out.append((n as LineEdit).text)
			out.append((n as LineEdit).placeholder_text)
		if n is Control:
			out.append((n as Control).tooltip_text)
		for c in n.get_children():
			stack.append(c)
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
			bad.append("%s %s %s" % [c.get_class(), c.name, r])
	return bad


# ---------------------------------------------------------------- (b) 끄기

func _test_toggle() -> void:
	print("[b: the [뜻 보기] chip, prefs]")
	_reset_env()
	_env(false, "down", false)
	var song: Dictionary = _song("en", _all_ko())
	var id: String = _install(song)
	var s: SongMemoScreen = _new_screen(id)
	await _frames(2)
	var chip: Button = _find(s, "ChipKo") as Button
	ok(chip != null and chip.text == "뜻 보기", "the settings chips include [뜻 보기]")
	ok(s.pref_show_ko() == true and not Store.prefs.has("memo_show_ko"), "default: on (and no key stored yet)")
	ok(chip != null and chip.theme_type_variation == &"FilterChip", "the chip is a FilterChip")
	_press(s, "ChipKo")
	await _frames(2)
	ok(Store.prefs.get("memo_show_ko", null) == false and s.pref_show_ko() == false, "pressing it turns it off in Store.prefs")
	var saved: Variant = JSON.parse_string(_read(DIR.path_join("prefs.json")))
	ok(saved is Dictionary and (saved as Dictionary).get("memo_show_ko", null) == false, "…and it was saved to the TEST prefs file only")
	ok(Store.prefs_path == DIR.path_join("prefs.json"), "the prefs path is the test path")
	_practice(s, 0)
	await _frames(2)
	ok(_ko_label(s.drill) == null and _ko_text(s.drill) == "", "off: no meaning label in the drill (stage 0)")
	var n_off: int = _card_children(s.drill)
	_to_stage(s, 99)
	await _frames(1)
	ok(_ko_label(s.drill) == null, "off: no meaning label in the blank stage either")
	_drop(s)
	# 다시 열어도 꺼져 있다 · 켜면 보인다
	s = _new_screen(id)
	await _frames(2)
	chip = _find(s, "ChipKo") as Button
	ok(s.pref_show_ko() == false, "reopened: still off")
	_press(s, "ChipKo")
	await _frames(2)
	ok(Store.prefs.get("memo_show_ko", null) == true and s.pref_show_ko() == true, "pressing it again turns it on")
	_practice(s, 0)
	await _frames(2)
	ok(_ko_text(s.drill) == "뜻 0" and _card_children(s.drill) == n_off + 1, "on: the meaning shows again (one more child in the card, nothing else moved)")
	_drop(s)
	# 잘못된 값은 기본(켬)으로 본다
	Store.prefs["memo_show_ko"] = "no"
	ok(SongMemoDrill.show_ko_pref() == true, "a non-bool pref value falls back to on")
	Store.prefs.erase("memo_show_ko")
	SongStore.delete(id)


# ---------------------------------------------------------------- (c) 해석 없음 · stale

func _test_missing() -> void:
	print("[c: no meaning / stale -> nothing shown, no empty slot]")
	_reset_env()
	_env(false, "down", false)
	# 기준: 해석이 있는 곡에서 줄 카드의 자식 수
	var with_id: String = _install(_song("en", _all_ko()))
	var s: SongMemoScreen = _new_screen(with_id)
	await _frames(2)
	_practice(s, 1)
	await _frames(2)
	ok(_ko_text(s.drill) == "뜻 1", "baseline: a line with a meaning shows it")
	var base: int = _card_children(s.drill)
	_drop(s)
	# ko 없음
	var none_id: String = _install(_song("en", []))
	s = _new_screen(none_id)
	await _frames(2)
	_practice(s, 1)
	await _frames(2)
	ok(_ko_label(s.drill) == null and _ko_text(s.drill) == "", "no ko: no meaning label")
	ok(_card_children(s.drill) == base - 1, "no ko: no empty slot (card children %d vs %d)" % [_card_children(s.drill), base])
	_to_stage(s, 99)
	await _frames(1)
	ok(_ko_label(s.drill) == null, "no ko, blank stage: nothing shown")
	_drop(s)
	# 공백뿐인 ko
	var ws_id: String = _install(_song("en", ["  ", "   "]))
	s = _new_screen(ws_id)
	await _frames(2)
	_practice(s, 1)
	await _frames(2)
	ok(_ko_label(s.drill) == null and _card_children(s.drill) == base - 1, "whitespace-only ko: nothing shown, no empty slot")
	_drop(s)
	# stale: 해석 글자는 있지만 고친 줄이라 믿을 수 없다
	var st_id: String = _install(_song("en", _all_ko(), [1]))
	s = _new_screen(st_id)
	await _frames(2)
	var stale_song: Dictionary = SongStore.load_song(st_id)
	ok(bool(stale_song["lines"][1].get("stale", false)) and str(stale_song["lines"][1].get("ko", "")) != "", "the stored song really has a stale line that still has ko text")
	_practice(s, 1)
	await _frames(2)
	ok(_ko_label(s.drill) == null and _ko_text(s.drill) == "", "stale: the old meaning is NOT shown")
	ok(_card_children(s.drill) == base - 1, "stale: no empty slot")
	_to_stage(s, 99)
	await _frames(1)
	ok(_ko_label(s.drill) == null, "stale, blank stage: nothing shown")
	_drop(s)
	# 같은 곡의 stale 이 아닌 줄은 그대로 보인다
	s = _new_screen(st_id)
	await _frames(2)
	_practice(s, 0)
	await _frames(2)
	ok(_ko_text(s.drill) == "뜻 0", "the non-stale line of the same song still shows its meaning")
	_drop(s)
	for i in [with_id, none_id, ws_id, st_id]:
		SongStore.delete(i)


# ---------------------------------------------------------------- (d) 안내 카드 조건 표

func _card_row(name: String, pc: bool, ai: String, consent: bool, want_state: String) -> SongMemoScreen:
	_reset_env()
	_env(pc, ai, consent)
	var id: String = _install(_song("en", ["뜻 0", "뜻 1", "뜻 2"])) # 3 of 6 lines have a meaning
	var sent0: int = Api.sent_count
	var ai0: int = _ai_requests
	var s: SongMemoScreen = _new_screen(id)
	await _frames(3)
	ok(SongMemoScreen.ko_card_state(s.song) == want_state, "%s: card state is '%s' (got '%s')" % [name, want_state, SongMemoScreen.ko_card_state(s.song)])
	ok(_find(s, "KoHintCard") != null and _has_text(s, SongMemoScreen.MSG_KO_TITLE), "%s: the top card says '%s'" % [name, SongMemoScreen.MSG_KO_TITLE])
	ok(_has_text(s, "6줄 중 3줄에 해석이 있어요"), "%s: the card shows the partial count (3 of 6)" % name)
	var first: Node = _find(s, "KoBox")
	ok(first != null and first.get_index() == 0, "%s: the card is at the very top of the home screen" % name)
	s.set_meta("sent0", sent0)
	s.set_meta("ai0", ai0)
	return s


func _has_text(root: Node, needle: String) -> bool:
	for t in _strings(root):
		if t.contains(needle):
			return true
	return false


func _test_card_table() -> void:
	print("[d: the hint card and the auto start, by condition]")
	# 1. PC + 동의 + AI 준비 -> 자동으로 한 번 요청
	_reset_env()
	_env(true, "ready", true)
	enrich_resp = Callable(self, "_enrich_all")
	var id: String = _install(_song("en", ["뜻 0", "뜻 1", "뜻 2"]))
	var s: SongMemoScreen = _new_screen(id)
	await _until(func() -> bool: return _count_path("/song/enrich") >= 1 and not s.ko_working())
	await _frames(2)
	ok(s.auto_calls == 1 and s.make_calls == 1 and _count_path("/song/enrich") == 1, "PC + consent + AI ready: exactly one automatic request (auto %d, make %d, sent %d)" % [s.auto_calls, s.make_calls, _count_path("/song/enrich")])
	var body0: Dictionary = (_reqs[0]["body"] as Dictionary) if not _reqs.is_empty() else {}
	ok(bool(body0.get("ai_ok", false)) == true and _req_indices(0) == [3, 4, 5], "the request has ai_ok true and carries only the 3 missing lines %s" % [_req_indices(0)])
	_drop(s)
	SongStore.delete(id)

	# 2. 동의 전 -> 요청 0, 동의 흐름
	s = await _card_row("no consent", true, "ready", false, "consent")
	await _frames(2)
	ok(s.auto_calls == 0 and s.make_calls == 0 and _count_path("/song/enrich") == 0, "no consent: no automatic request (auto %d, make %d, sent %d)" % [s.auto_calls, s.make_calls, _count_path("/song/enrich")])
	var mk: Button = _find(s, "KoMakeBtn") as Button
	ok(mk != null and not mk.disabled and not Store.pref_bool("song_consent"), "no consent: [해석 만들기] is enabled and consent is still off")
	ok(s.consent_asks == 0 and s.last_sheet == null, "no consent: no sheet yet")
	_press(s, "KoMakeBtn")
	await _frames(2)
	ok(s.consent_asks == 1 and s.last_sheet != null and not s.last_sheet.is_closed(), "pressing it opens the consent sheet")
	ok(_count_path("/song/enrich") == 0 and s.make_calls == 0 and not Store.pref_bool("song_consent"), "…and nothing is sent, consent is not set, while the sheet is open")
	ok(s.last_sheet != null, "(the sheet object exists)")
	if s.last_sheet != null:
		s.last_sheet.close("cancel")
	await _frames(2)
	ok(_count_path("/song/enrich") == 0 and s.make_calls == 0 and not Store.pref_bool("song_consent"), "cancel: still no request, consent still off")
	ok(_ko_text(s) == "", "(no meaning label on the home screen)")
	enrich_resp = Callable(self, "_enrich_all")
	_press(s, "KoMakeBtn")
	await _frames(2)
	ok(s.consent_asks == 2 and _count_path("/song/enrich") == 0, "pressing again asks again (still 0 requests)")
	if s.last_sheet != null:
		s.last_sheet.close("agree")
	await _until(func() -> bool: return _count_path("/song/enrich") >= 1 and not s.ko_working())
	await _frames(2)
	ok(Store.pref_bool("song_consent") and s.make_calls == 1 and _count_path("/song/enrich") == 1 and bool((_reqs[0]["body"] as Dictionary).get("ai_ok", false)), "agree: consent saved, then exactly one request with ai_ok true")
	ok(s.auto_calls == 0, "(that start was not an automatic one)")
	var sid1: String = s.song_id
	_drop(s)
	SongStore.delete(sid1)

	# 3. AI 미연결 -> 요청 0, [AI 연결하기]
	for row in [["AI not connected", "not_connected"], ["AI engine down", "down"]]:
		s = await _card_row(str(row[0]), true, str(row[1]), true, "noai")
		await _frames(2)
		ok(s.auto_calls == 0 and s.make_calls == 0 and _count_path("/song/enrich") == 0, "%s: no request (auto %d, make %d, sent %d)" % [row[0], s.auto_calls, s.make_calls, _count_path("/song/enrich")])
		ok(_find(s, "KoAiBtn") != null and (_find(s, "KoAiBtn") as Button).text == "AI 연결하기", "%s: the card has [AI 연결하기]" % row[0])
		ok((_find(s, "KoMakeBtn") as Button).disabled, "%s: [해석 만들기] is disabled" % row[0])
		var a0: int = _ai_requests
		_press(s, "KoAiBtn")
		ok(_ai_requests == a0 + 1, "%s: [AI 연결하기] calls Store.request_ai_connect" % row[0])
		var sid2: String = s.song_id
		_drop(s)
		SongStore.delete(sid2)

	# 4. 폰 단독 -> 요청 0, Api.sent_count 불변
	s = await _card_row("phone alone", false, "ready", true, "nopc")
	var sent_before: int = int(s.get_meta("sent0"))
	await _frames(3)
	ok(s.auto_calls == 0 and s.make_calls == 0 and _count_path("/song/enrich") == 0, "phone alone: no request (auto %d, make %d, sent %d)" % [s.auto_calls, s.make_calls, _count_path("/song/enrich")])
	ok(Api.sent_count == sent_before, "phone alone: Api.sent_count did not change (%d -> %d)" % [sent_before, Api.sent_count])
	ok(_has_text(s, SongMemoScreen.MSG_KO_NO_PC) and SongMemoScreen.MSG_KO_NO_PC == "PC에 연결하면 해석을 만들 수 있어요", "phone alone: the card says 'PC에 연결하면 해석을 만들 수 있어요'")
	ok((_find(s, "KoMakeBtn") as Button).disabled and _find(s, "KoAiBtn") == null, "phone alone: the button is disabled and there is no [AI 연결하기]")
	_press(s, "KoMakeBtn")
	await _frames(2)
	ok(s.make_calls == 0 and _count_path("/song/enrich") == 0 and Api.sent_count == sent_before, "phone alone: pressing the disabled button does nothing")
	var sid3: String = s.song_id
	_drop(s)
	SongStore.delete(sid3)

	# 5. 곡별 해석이 꺼져 있다 -> 요청 0
	_reset_env()
	_env(true, "ready", true)
	var off_song: Dictionary = _song("en", ["뜻 0"])
	off_song["translate"] = false
	var oid: String = _install(off_song)
	s = _new_screen(oid)
	await _frames(3)
	ok(SongMemoScreen.ko_card_state(s.song) == "off" and s.auto_calls == 0 and _count_path("/song/enrich") == 0, "this song's AI switch off: state 'off', no request")
	ok((_find(s, "KoMakeBtn") as Button).disabled and _has_text(s, SongMeaningTab.MSG_SWITCH_OFF), "…the button is disabled and the reason is shown")
	_drop(s)
	SongStore.delete(oid)

	# 6. 해석이 다 있으면 카드가 없다
	_reset_env()
	_env(true, "ready", true)
	var full_id: String = _install(_song("en", _all_ko()))
	s = _new_screen(full_id)
	await _frames(3)
	ok(_find(s, "KoHintCard") == null and s.auto_calls == 0 and _count_path("/song/enrich") == 0, "all lines have a meaning: no card and no request")
	_drop(s)
	SongStore.delete(full_id)
	# 7. 해석이 하나도 없는 곡 + 폰 단독: 카드는 있고 숫자는 0
	_reset_env()
	_env(false, "down", true)
	var zid: String = _install(_song("en", []))
	s = _new_screen(zid)
	await _frames(3)
	ok(_find(s, "KoHintCard") != null and _has_text(s, "6줄 중 0줄에 해석이 있어요"), "no meaning at all: the card shows 0 of 6")
	_drop(s)
	SongStore.delete(zid)
	_env(false, "down", false)


# ---------------------------------------------------------------- (e) 받은 해석 저장·표시, 재진입

func _test_make() -> void:
	print("[e: made meanings are saved and shown; re-entry does not request again]")
	_reset_env()
	_env(true, "ready", true)
	enrich_resp = Callable(self, "_enrich_all")
	var id: String = _install(_song("en", ["뜻 0", "뜻 1"]))
	var s: SongMemoScreen = _new_screen(id)
	await _until(func() -> bool: return s.make_calls == 1 and not s.ko_working() and _count_path("/song/enrich") == 1)
	await _frames(3)
	ok(_count_path("/song/enrich") == 1 and s.auto_calls == 1, "opening the screen sent one automatic request")
	var ko: Array = _saved_ko(id)
	ok(ko == ["뜻 0", "뜻 1", "만든 뜻 2", "만든 뜻 3", "만든 뜻 4", "만든 뜻 5"], "the received meanings were saved into song.json (%s)" % [ko])
	ok(SongStore.load_song(id)["lines"][0]["ko"] == "뜻 0", "existing meanings were kept")
	ok(_has_text(s, SongMemoScreen.MSG_KO_DONE), "the card reports that the meanings were made")
	ok(_has_text(s, "6줄 중 6줄에 해석이 있어요"), "the meaning card count follows: 6 of 6")
	ok(SongMemoScreen.ko_missing(s.song) == 0 and SongMemoScreen.ko_card_state(s.song) == "none", "nothing is missing now")
	_start(s)
	await _frames(2)
	_to_stage(s, 99)
	await _frames(1)
	var li: int = int(s.drill.session.current()["line_i"])
	ok(_ko_text(s.drill) == ko[li] and ko[li] != "", "the drill shows the saved meaning of line %d: '%s'" % [li, _ko_text(s.drill)])
	_drop(s)
	# 저장돼서 PC 없이도 보인다
	_env(false, "down", false)
	_reqs = []
	var sent0: int = Api.sent_count
	s = _new_screen(id)
	await _frames(3)
	_practice(s, 4)
	await _frames(2)
	ok(_ko_text(s.drill) == "만든 뜻 4", "later, without a PC: the saved meaning shows (got '%s')" % _ko_text(s.drill))
	ok(_count_path("/song/enrich") == 0 and Api.sent_count == sent0, "…and nothing was requested")
	_drop(s)
	SongStore.delete(id)

	# 일부만 채워 준 응답: 다시 들어가도 자동 요청은 다시 가지 않는다 (곡마다 한 번)
	_reset_env()
	_env(true, "ready", true)
	enrich_resp = {"lines": [{"i": 3, "ko": "한 줄만 왔어요"}], "warnings": []}
	var pid: String = _install(_song("en", ["뜻 0", "뜻 1"]))
	s = _new_screen(pid)
	await _until(func() -> bool: return s.make_calls == 1 and not s.ko_working() and _count_path("/song/enrich") == 1)
	await _frames(2)
	ok(_saved_ko(pid)[3] == "한 줄만 왔어요" and _saved_ko(pid)[2] == "" and SongMemoScreen.ko_missing(s.song) == 3, "a partial answer: one line saved, three still missing")
	ok(_find(s, "KoHintCard") != null and (_find(s, "KoMakeBtn") as Button).disabled == false, "the card stays (3 missing) with an enabled [해석 만들기]")
	_drop(s)
	var n1: int = _count_path("/song/enrich")
	s = _new_screen(pid)
	await _frames(5)
	ok(s.auto_calls == 0 and s.make_calls == 0 and _count_path("/song/enrich") == n1, "entering the same song again: no automatic request (still %d)" % n1)
	ok(_find(s, "KoMakeBtn") != null and not (_find(s, "KoMakeBtn") as Button).disabled, "…but the button is still there for the person to press")
	# 버튼은 누를 수 있다 (그때는 세 줄만 보낸다)
	enrich_resp = Callable(self, "_enrich_all")
	_press(s, "KoMakeBtn")
	await _until(func() -> bool: return _count_path("/song/enrich") == n1 + 1 and not s.ko_working())
	await _frames(2)
	ok(_req_indices(n1) == [2, 4, 5] and SongMemoScreen.ko_missing(s.song) == 0, "pressing the button sends only the 3 missing lines %s and fills them" % [_req_indices(n1)])
	_drop(s)
	SongStore.delete(pid)

	# 실패하면 자동 재시도 없음
	_reset_env()
	_env(true, "ready", true)
	enrich_resp = {"ok": false, "code": 500, "data": null, "error": "서버 오류"}
	var fid: String = _install(_song("en", ["뜻 0"]))
	s = _new_screen(fid)
	await _until(func() -> bool: return s.make_calls == 1 and not s.ko_working())
	await _frames(3)
	ok(s.make_calls == 1 and _count_path("/song/enrich") == 1, "a failing server: one request")
	ok(_saved_ko(fid)[1] == "" and SongMemoScreen.ko_missing(s.song) == 5, "…and nothing was saved")
	ok(_find(s, "KoHintMsg") != null, "the card shows why it failed (%s)" % _label_text(s, "KoHintMsg"))
	ok(_find(s, "KoMakeBtn") != null and not (_find(s, "KoMakeBtn") as Button).disabled, "[해석 만들기] is available to try again by hand")
	await _frames(20)
	ok(_count_path("/song/enrich") == 1, "no automatic retry while the screen stays open")
	_drop(s)
	s = _new_screen(fid)
	await _frames(5)
	ok(s.auto_calls == 0 and _count_path("/song/enrich") == 1, "re-entering after a failure: still no automatic retry")
	_drop(s)
	SongStore.delete(fid)
	_env(false, "down", false)


func _label_text(root: Node, name: String) -> String:
	var n: Node = _find(root, name)
	return (n as Label).text if n is Label else ""


# ---------------------------------------------------------------- (f) 닫은 뒤 늦은 응답

func _test_late() -> void:
	print("[f: a late answer after the screen is closed is ignored, no node leaks]")
	for mode in ["free", "on_hide", "cancel"]:
		_reset_env()
		_env(true, "ready", true)
		enrich_resp = Callable(self, "_enrich_all")
		var id: String = _install(_song("en", ["뜻 0"]))
		var before: Array = _node_counts()
		_hold = true
		var s: SongMemoScreen = _new_screen(id)
		await _until(func() -> bool: return _count_path("/song/enrich") == 1)
		await _frames(2)
		ok(s.ko_working() and s.make_calls == 1, "[%s] the automatic request is in flight" % mode)
		ok(_find(s, "KoCancelBtn") != null, "[%s] the card shows [취소] while it works" % mode)
		match mode:
			"free":
				_drop(s)
			"on_hide":
				s.on_hide()
			"cancel":
				_press(s, "KoCancelBtn")
		_hold = false
		await _frames(12)
		ok(_saved_ko(id)[1] == "" and _saved_ko(id)[5] == "", "[%s] the late answer was ignored: nothing saved" % mode)
		if mode != "free":
			ok(not s.ko_working(), "[%s] the screen is no longer 'working'" % mode)
			ok(SongMemoScreen.ko_missing(s.song) == 5, "[%s] the screen's song did not get the late meanings" % mode)
			_drop(s)
		await _frames(5)
		ok(_node_counts() == before, "[%s] no node leaks: nodes/orphans %s -> %s" % [mode, before, _node_counts()])
		ok(_count_path("/song/enrich") == 1, "[%s] no second request" % mode)
		SongStore.delete(id)
	# 요청 중에 연습을 시작하면, 늦게 온 해석이 (화면이 열려 있는 동안) 그 연습에도 들어간다
	_reset_env()
	_env(true, "ready", true)
	enrich_resp = Callable(self, "_enrich_all")
	var id2: String = _install(_song("en", []))
	_hold = true
	var s2: SongMemoScreen = _new_screen(id2)
	await _until(func() -> bool: return _count_path("/song/enrich") == 1)
	ok(_practice(s2, 1) and s2.view == "session", "a practice session starts while the request is in flight")
	await _frames(2)
	ok(_ko_label(s2.drill) == null, "…it has no meaning yet")
	_hold = false
	await _until(func() -> bool: return not s2.ko_working())
	await _frames(2)
	ok(_saved_ko(id2)[1] == "만든 뜻 1", "the answer that arrived while the screen was open was saved")
	s2.drill.render()
	await _frames(1)
	ok(_ko_text(s2.drill) == "만든 뜻 1", "the running practice shows it from the next redraw (got '%s')" % _ko_text(s2.drill))
	_drop(s2)
	SongStore.delete(id2)
	_env(false, "down", false)
