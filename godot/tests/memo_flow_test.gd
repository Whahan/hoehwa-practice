extends Node
## 가사 외우기 M8: 종단 흐름 시험 (docs/lyrics_memorize_design.md §8 M8-2 ~ M8-7). 실제 노래·서버·마이크를 쓰지 않는다.
##   PC:   godot --headless --path godot res://tests/memo_flow_test.tscn
##   폰:   godot --headless --path godot res://tests/memo_flow_test.tscn -- --phone
##   (--python=<python.exe> 파이썬 지정, --lrclib=<http://127.0.0.1:포트> 이미 떠 있는 가짜 LRCLIB 사용(러너), --only=<구간>)
## 구간: selftest · english(M8-2) · japanese(M8-3) · lrclib(M8-4) · phone_only(M8-5) · failures(M8-6) · cleanup(M8-7)
##   english   : SongView(허브) [가사만 추가] -> 붙여넣기(lyrics_en.txt) -> 저장 -> 외우기 화면 -> 새 줄 5개 끝까지 -> 진도·memo.json·StudyLog
##               -> 시계 +3일 -> "오늘 복습 5줄" -> 복습 줄은 빈 화면에서 시작 -> 정답 -> 카드 due 가 뒤로 밀림
##   japanese  : lyrics_ja.txt 5줄, 단위 가림, 입력 채점(정답 통과 / 틀린 단위 표식)
##   lrclib    : 가짜 LRCLIB(fake_lrclib.py) 찾기 -> 후보 -> 저장 -> 외우기, 하단 출처 문구, get 1 + search <= 1
##   phone_only: PC 없음(Route "phone")에서 추가·외우기·입력·자가 평가(말하기)·복습, Api.sent_count 불변, /stt·/song/* 요청 0
##   failures  : 틀린 답 2번 -> 정답 공개·단계 내려감·다시 통과 -> Again / Hard / Good, 깨진 memo.json -> 격리·새 시작, 곡 삭제 -> 폴더 0
##   cleanup   : user://test_* 밖의 파일 변화 0
## 곡은 user://test_songs_memo_flow 에만, 설정·진행·학습 기록은 user://test_memo_flow/ 로 돌린다. 가사·제목은 직접 지은 문장뿐이다.
## 실제 사용자 폴더·8770/8775/8776·실제 lrclib.net 에는 접속하지 않는다(LRCLIB 는 127.0.0.1 가짜 서버). 시계는 주입(NOW), FSRS.fuzz_override = 0.5.
## 마지막 줄: "== memo_flow_test result: N passed, M failed ==", 종료 코드 1 = 실패.

const NOW := 1790000000
const DAY := 86400
const ROOT := "user://test_songs_memo_flow"
const DIR := "user://test_memo_flow"
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const LR_PORT := 18798
const EN_NAME := "lyrics_en.txt"
const JA_NAME := "lyrics_ja.txt"
const SECTIONS := ["selftest", "english", "japanese", "lrclib", "phone_only", "failures", "cleanup"]
const ATTRIBUTION := "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"
const WRONG_EN := "zzq xxv wwy"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _before: Dictionary = {}
var _top_before: Array = []
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
var _reqs: Array = []
var _toasts: Array = []
var _clock: int = NOW
var _seq: int = 0
var _lr_pid: int = -1
var _lr_base: String = ""
var _lr_own: bool = false
var _lr_up: bool = false
var _reached: Dictionary = {}


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


## user:// 바로 아래 이름 중 `test_` 로 시작하지 않는 것 (시험이 만들어도 되는 것은 test_* 뿐이다).
func _top_names() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for sub in d.get_directories():
		if not String(sub).begins_with("test_"):
			out.append("d:" + sub)
	for fn in d.get_files():
		if not String(fn).begins_with("test_"):
			out.append("f:" + fn)
	out.sort()
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


## 가사 시험 파일: 머리의 # 주석 줄은 먼저 제거한다 (LrcParser.split_plain 은 # 줄을 거르지 않는다).
func _fixture(name: String) -> String:
	var f := FileAccess.open("res://tests/fixtures/song/" + name, FileAccess.READ)
	var out: PackedStringArray = []
	if f == null:
		return ""
	for raw in f.get_as_text().replace("\r", "").split("\n"):
		if not raw.strip_edges().begins_with("#"):
			out.append(raw)
	return "\n".join(out).strip_edges()


func _fixture_lines(name: String) -> Array:
	var out: Array = []
	for e in LrcParser.split_plain(_fixture(name)):
		out.append(str(e["text"]))
	return out


func _find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)


func _press(root: Node, name: String) -> bool:
	var b: Node = _find(root, name)
	if b is Button and not (b as Button).disabled and (b as Button).is_visible_in_tree():
		(b as Button).pressed.emit()
		return true
	return false


func _label_text(root: Node, name: String) -> String:
	var n: Node = _find(root, name)
	return (n as Label).text if n is Label else ""


func _clock_now() -> int:
	return _clock


func _drop(n: Node) -> void:
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.free()


func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _toast_has(needle: String) -> bool:
	for t in _toasts:
		if str(t[0]).contains(needle):
			return true
	return false


## 노드 트리의 모든 글자 (Label · RichTextLabel · Button · 입력칸 · 툴팁 · 노드 이름).
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
			out.append((n as Control).accessibility_name)
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


func _drill_n(l: String = "en") -> int:
	return int((StudyLog.range_summary(l, 1)[0]["n"] as Dictionary)["drill"])


func _memo_path(id: String) -> String:
	return SongStore.song_dir(id).path_join("memo.json")


func _memo_cards(id: String) -> Dictionary:
	var out := {}
	var lines: Variant = SongStore.load_memo(id).get("lines", {})
	if lines is Dictionary:
		for k in (lines as Dictionary):
			var e: Variant = (lines as Dictionary)[k]
			if e is Dictionary and (e as Dictionary).get("card", null) is Dictionary:
				out[k] = (e as Dictionary)["card"]
	return out


func _keys(id: String) -> Array:
	var out: Array = []
	for e in MemoModel.keys_of(SongStore.load_song(id)):
		out.append(str(e["key"]))
	return out


# ---- 가짜 장치

func _hook(method: String, path: String, body: Variant) -> Variant:
	_reqs.append({"method": method, "path": path, "body": body})
	return {"ok": false, "code": 404, "data": null, "error": "no"}


func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


func _rec() -> Dictionary:
	var wav: PackedByteArray = WavUtil.to_wav_bytes(WavUtil.sine(0.6, 16000))
	return {"ok": true, "silent": false, "duration": 0.6, "b64": Marshalls.raw_to_base64(wav), "wav": wav, "owner": 0}


func _fresh() -> void:
	SongStore.write_hook = Callable()
	SongStore.rename_fail = false
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.clear_cache()
	SongStore.take_quarantined()
	_rm_rf(ROOT)
	StudyLog.reset()
	Store.progress = Progress.blank()
	for k in ["memo_fast", "memo_prev_cue", "memo_answer", "tts_engine", "song_translate"]:
		Store.prefs.erase(k)
	Store.prefs["song_consent"] = true
	_reqs = []
	_toasts = []
	_clock = NOW


func _disconnect_pc() -> void:
	Backend.health = {}
	Backend._set_status(Backend.Status.FAILED, "x")


func _wait_loaded(v: SongView, max_frames: int = 300) -> void:
	for i in max_frames:
		await get_tree().process_frame
		if v.state != "loading" and v.state != "idle" and not v.is_loading():
			break
	await _frames(2)


func _new_memo_screen(id: String, l: String = "en") -> SongMemoScreen:
	var s := SongMemoScreen.new()
	s.now_fn = Callable(self, "_clock_now")
	_stage(s)
	s.open(l, {"id": id})
	return s


## 가사만 곡을 만든다 (SongLyricsAddScreen 으로 붙여넣기 -> 저장). 곡 id 를 돌려준다 ("" = 저장 실패).
func _add_pasted(l: String, title: String, text: String) -> String:
	var a := SongLyricsAddScreen.new()
	_stage(a)
	a.open(l, {"lang": l})
	a.set_title(title)
	a.set_artist("Test Artist")
	a.set_pasted(text)
	var id := ""
	if a.save() == "":
		id = a.added_id
	_drop(a)
	return id


func _start(s: SongMemoScreen) -> bool:
	var okv: bool = s.start_today()
	_nolock(s)
	return okv


## 시작 직후 드릴의 단추 잠금(250 ms)을 끈다.
func _nolock(s: SongMemoScreen) -> void:
	if s.drill != null and is_instance_valid(s.drill):
		s.drill.lock_msec = 0


## 지금 줄을 맨 끝 결과(NextLineBtn)까지 진행한다. 정답을 입력한다.
##   wrong_final: 비어 있지 않으면 맨 끝 단계에서 한 번 이 글자를 먼저 낸다.   via_self: 말하기 모드에서 자가 평가(잘했어요)로 진행.
func _play_line(s: SongMemoScreen, wrong_final: String = "", via_self: bool = false) -> bool:
	var d: SongMemoDrill = s.drill
	var wrong_done: bool = wrong_final == ""
	for g in 100:
		await get_tree().process_frame
		if d == null or not is_instance_valid(d) or d.session == null:
			return false
		var c: Dictionary = d.session.current()
		if not bool(c.get("ok", false)):
			return false
		if d.phase == "result":
			if _find(d, "NextLineBtn") != null:
				return true
			if not _press(d, "NextBtn"):
				_press(d, "RetryBtn")
		elif d.phase == "self":
			var p: Node = _find(d, "SelfRatePanel")
			if p is SelfRatePanel:
				(p as SelfRatePanel).rated.emit(true)
		elif bool(c["read_only_stage"]):
			_press(d, "ReadBtn")
		elif via_self and _find(d, "RecordBox") != null:
			var rws: Array = d.find_children("*", "RecorderWidget", true, false)
			if not rws.is_empty():
				(rws[0] as RecorderWidget).recorded.emit(_rec())
		else:
			if not wrong_done and bool(c["final"]):
				wrong_done = true
				d.set_typed(wrong_final)
			else:
				d.set_typed(str(c["text"]))
			d.submit_typed()
	return false


## 맨 끝(빈 화면) 단계의 답하기 전까지 정답으로 진행한다.
func _advance_to_final(s: SongMemoScreen) -> bool:
	var d: SongMemoDrill = s.drill
	for g in 100:
		await get_tree().process_frame
		var c: Dictionary = d.session.current()
		if not bool(c.get("ok", false)):
			return false
		if bool(c["final"]) and d.phase == "answer":
			return true
		if d.phase == "result":
			_press(d, "NextBtn")
		elif bool(c["read_only_stage"]):
			_press(d, "ReadBtn")
		else:
			d.set_typed(str(c["text"]))
			d.submit_typed()
	return false


func _next_line(s: SongMemoScreen) -> void:
	_press(s.drill, "NextLineBtn")


func _last_event(d: SongMemoDrill) -> String:
	return str((d.last.get("ev", {}) as Dictionary).get("event", ""))


# ---------------------------------------------------------------- 가짜 LRCLIB

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
	var r: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_log")
	if r["data"] is Dictionary:
		return (r["data"] as Dictionary).get("requests", [])
	return []


func _lr_bad_calls() -> Array:
	var r: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_log")
	if r["data"] is Dictionary:
		return (r["data"] as Dictionary).get("bad_calls", [])
	return []


func _lr_reset() -> void:
	await _http(_lr_base, HTTPClient.METHOD_POST, "/_reset")


func _lr_count(reqs: Array, path: String) -> int:
	var n := 0
	for r in reqs:
		if str(r["path"]) == path:
			n += 1
	return n


## 러너가 --lrclib=<주소> 로 띄워 준 가짜 서버를 쓴다. 없으면 이 시험이 직접 띄우고(포트 18798, 빈 포트일 때만) 자기 PID 만 끈다.
func _start_lrclib() -> bool:
	var given: String = _arg("--lrclib=")
	if given != "":
		_lr_base = given
		_lr_own = false
		var h: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_ping")
		return int(h["code"]) == 200
	_lr_base = "http://127.0.0.1:%d" % LR_PORT
	var busy: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_ping")
	for i in 30: # 다른 작업자의 시험이 잠시 쓰고 있을 수 있다: 기다린다 (끄지 않는다)
		if int(busy["code"]) == 0:
			break
		await get_tree().create_timer(2.0).timeout
		busy = await _http(_lr_base, HTTPClient.METHOD_GET, "/_ping")
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
	_lr_own = true
	for i in 150:
		await get_tree().create_timer(0.2).timeout
		var h2: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_ping")
		if int(h2["code"]) == 200:
			return true
	return false


func _stop_lrclib() -> void:
	if _lr_own and _lr_pid > 0:
		await _http(_lr_base, HTTPClient.METHOD_POST, "/_quit")
		await get_tree().create_timer(0.3).timeout
		if OS.get_name() == "Windows":
			OS.execute("taskkill", PackedStringArray(["/PID", str(_lr_pid), "/T", "/F"])) ## 이 시험이 시작한 프로세스(와 하위)만
		else:
			OS.kill(_lr_pid)
		_lr_pid = -1


# ---------------------------------------------------------------- main

func _ready() -> void:
	_phone = Platform.is_phone()
	print("== memo_flow_test start (%s) ==" % ["phone" if _phone else "pc"])
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	ok(_phone == OS.get_cmdline_user_args().has("--phone"), "the phone switch matches the command line (is_phone %s)" % _phone)
	_before = _user_listing()
	_top_before = _top_names()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
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
	Store.prefs["lang"] = "en"
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Api.set_remote("http://127.0.0.1:9", "") # a closed port: this run must never reach the user's engine (8770)
	_disconnect_pc()
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
	_fresh()
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = func(_t: String, _l: String, _s: float, _v: String) -> Variant: return null
	_mode_pc()

	await _test_selftest()
	_reached["selftest"] = true
	if _want("english"):
		await _test_english()
	_reached["english"] = true
	if _want("japanese"):
		await _test_japanese()
	_reached["japanese"] = true
	if _want("lrclib"):
		_lr_up = await _start_lrclib()
		ok(_lr_up, "fake LRCLIB is up (%s)" % ["own process" if _lr_own else "started by the runner"])
		ok(_lr_base.begins_with("http://127.0.0.1:") and not _lr_base.contains("lrclib.net") and not _lr_base.contains(":8770") and not _lr_base.contains(":8775") and not _lr_base.contains(":8776"), "the fake LRCLIB address is a local one, not lrclib.net and not 8770 / 8775 / 8776 (%s)" % _lr_base)
		if _lr_up:
			await _test_lrclib()
		await _stop_lrclib()
		if _lr_own:
			await get_tree().create_timer(0.3).timeout
			var closed: Dictionary = await _http(_lr_base, HTTPClient.METHOD_GET, "/_ping")
			ok(int(closed["code"]) == 0, "the fake LRCLIB this test started is gone and its port is closed again")
	_reached["lrclib"] = true
	if _want("phone_only"):
		await _test_phone_only()
	_reached["phone_only"] = true
	if _want("failures"):
		await _test_failures()
	_reached["failures"] = true

	# cleanup (M8-7)
	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	Route.mode = _old_mode
	Route.phone_hook = _old_phone_hook
	LocalApi.handler_override = _old_overrides
	FSRS.fuzz_override = -1.0
	SongStore.write_hook = Callable()
	SongStore.clear_cache()
	SongStore.root = _old_root
	Api.clear_remote()
	Backend.health = _old_health
	Backend.status = _old_status
	_rm_rf(ROOT)
	_rm_rf(DIR)
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	Store.prefs = _old_prefs_data
	_reached["cleanup"] = true
	_test_cleanup()
	for k in SECTIONS:
		ok(_reached.has(k), "section '%s' ran to its end" % k)
	ok(_reached.size() == SECTIONS.size(), "ran to the end of every section")
	print("== memo_flow_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 검사기 변조 시험

## 일부러 틀린 입력을 넣으면 검사 장치가 실제로 FAIL 을 내는지.
func _test_selftest() -> void:
	print("[selftest: the checkers fail on wrong input]")
	ok(not await _until(func() -> bool: return false, 0.2), "_until() gives false when its condition never holds")
	ok(not _toast_has("this text was never shown"), "_toast_has() gives false for text that was never shown")
	var line := "The kettle hums while the morning climbs the wall"
	var host := VBoxContainer.new()
	add_child(host)
	var lab := Label.new()
	lab.text = "정답: " + line
	host.add_child(lab)
	ok(not _leaks(host, line).is_empty(), "leak checker catches the line in a Label")
	lab.text = "아무 글자 없음 123"
	ok(_leaks(host, line).is_empty(), "leak checker passes a Korean-only tree")
	lab.tooltip_text = "kettle"
	ok(not _leaks(host, line).is_empty(), "leak checker catches a word in a tooltip")
	_drop(host)
	# grading: the wrong inputs used by the flow must FAIL, the right ones must pass (a threshold change would flip one of these)
	var ref := {"text": line, "reading": ""}
	ok(bool(MemoGrade.grade("en", line, ref, "type")["passed"]), "grading: the exact line passes")
	ok(not bool(MemoGrade.grade("en", WRONG_EN, ref, "type")["passed"]), "grading: nonsense fails")
	ok(not bool(MemoGrade.grade("en", "The kettle hums while the morning", ref, "type")["passed"]), "grading: half of the line fails (score %d, line 85)" % int(MemoGrade.grade("en", "The kettle hums while the morning", ref, "type")["score"]))
	var ja: String = (_fixture_lines(JA_NAME) as Array)[0]
	var ja_g: Dictionary = MemoGrade.grade("ja", "朝の窓辺で小さなポットが鳴る", {"text": ja, "reading": ""}, "type")
	ok(not bool(ja_g["passed"]) and int(ja_g["score"]) >= 60, "grading: a Japanese line with two wrong units fails but is not nonsense (score %d)" % int(ja_g["score"]))
	ok(bool(MemoGrade.grade("ja", ja, {"text": ja, "reading": ""}, "type")["passed"]), "grading: the exact Japanese line passes")
	# request counters
	var sent0: int = Api.sent_count
	_hook("POST", "/stt", {})
	ok(_reqs.size() == 1, "the request hook records a request")
	_reqs = []
	Api.sent_count += 1
	ok(Api.sent_count != sent0, "Api.sent_count comparison sees one extra request")
	Api.sent_count = sent0
	# file listing and memo comparers
	var probe: String = "user://test_memo_flow_probe"
	DirAccess.make_dir_recursive_absolute(_g(probe))
	ok(_listing("user://").has("d:test_memo_flow_probe"), "the listing sees a new folder")
	_rm_rf(probe)
	ok(not _listing("user://").has("d:test_memo_flow_probe"), "the listing no longer sees a deleted folder")
	var id: String = _add_pasted("en", "Selftest Song", _fixture(EN_NAME))
	var m1: String = _read(_memo_path(id))
	SongStore.save_memo(id, MemoModel.new_memo())
	ok(m1 == "" and _read(_memo_path(id)) != "", "the memo.json comparer sees a write")
	var n0: int = _drill_n()
	StudyLog.add_event("en", "drill", 1)
	ok(_drill_n() == n0 + 1, "the StudyLog drill counter sees one extra event")
	StudyLog.reset()
	ok(SongStore.delete(id) and _listing(ROOT).is_empty(), "delete leaves no folder")
	# the play helper reports failure when there is nothing to play
	var s := SongMemoScreen.new()
	_stage(s)
	ok(not await _play_line(s), "_play_line() gives false when no session is running")
	_drop(s)
	_fresh()


# ---------------------------------------------------------------- M8-2 영어

func _test_english() -> void:
	print("[english: paste -> add -> memorize 5 lines -> +3 days -> review]")
	_fresh()
	_mode_pc()
	var sent0: int = Api.sent_count
	var n0: int = _drill_n()
	var lines: Array = _fixture_lines(EN_NAME)
	ok(lines.size() == 6, "the English fixture has 6 lines")
	var v := SongView.new()
	_stage(v)
	v.refresh()
	await _wait_loaded(v)
	ok(SongStore.list().is_empty() and v.songs.is_empty(), "the list starts empty")
	v.request_add_lyrics()
	ok(v.screen_kind == "lyrics_add" and v.screen is SongLyricsAddScreen, "[가사만 추가] opens the lyrics add screen (consent already given, no PC needed)")
	var a: SongLyricsAddScreen = v.screen as SongLyricsAddScreen
	a.set_title("Flow Test Song")
	a.set_artist("Test Artist")
	a.set_pasted(_fixture(EN_NAME))
	ok(a.preview_text().contains("6줄") and a.save_block_reason() == "", "pasted lyrics: preview says 6줄 and saving is allowed (%s)" % a.preview_text().replace("\n", " | "))
	var save_msg: String = a.save()
	var id: String = a.added_id
	ok(save_msg == "" and SongModel.is_valid_id(id), "[저장하고 외우기] saved the song")
	var saved: Dictionary = SongStore.load_song(id)
	ok(SongModel.is_lyrics(saved) and (saved["lines"] as Array).size() == 6 and str((saved["source"] as Dictionary)["lyrics"]) == "pasted" and SongStore.list().size() == 1, "one lyrics-only song, 6 lines, source pasted")
	ok(await _until(func() -> bool: return v.screen_kind == "memo", 10.0), "song_added -> the hub opens the memorize screen by itself")
	var s: SongMemoScreen = v.screen as SongMemoScreen
	ok(s != null and s.song_id == id and s.view == "home", "the memorize screen is open on the new song (home view)")
	s.now_fn = Callable(self, "_clock_now")
	s.show_home() # redraw with the injected clock
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/6" and _label_text(s, "NewLabel") == "오늘 새 줄 5줄" and _label_text(s, "DueLabel") == "오늘 복습 0줄", "home: 외운 줄 0/6, 오늘 새 줄 5줄, 오늘 복습 0줄 (got '%s' / '%s' / '%s')" % [_label_text(s, "ProgressLabel"), _label_text(s, "NewLabel"), _label_text(s, "DueLabel")])
	ok(_find(s, "Attribution") == null, "a pasted song shows no attribution line")
	# today's 5 new lines, each played from stage 0 to its end with correct answers
	ok(_start(s) and s.view == "session" and int(s.session.current()["total"]) == 5 and str(s.session.current()["kind"]) == "new", "[오늘 외우기]: a session with 5 new lines")
	for k in 5:
		ok(await _play_line(s), "new line %d played from stage 0 to its end with correct answers" % (k + 1))
		ok(_memo_cards(id).size() == k + 1 and _drill_n() == n0 + k + 1, "after line %d: memo.json holds %d cards and StudyLog drill is +%d" % [k + 1, k + 1, k + 1])
		_next_line(s)
		await _frames(2)
	ok(await _until(func() -> bool: return s.view == "summary", 5.0), "the queue ended: the summary view")
	ok(_label_text(s, "DoneLabel") == "오늘 5줄 했어요" and _label_text(s, "ProgressLabel") == "외운 줄 5/6", "summary: 오늘 5줄, 외운 줄 5/6 (got '%s' / '%s')" % [_label_text(s, "DoneLabel"), _label_text(s, "ProgressLabel")])
	ok(_label_text(s, "NextDueLabel").begins_with("다음 복습: 약"), "summary names the next review time ('%s')" % _label_text(s, "NextDueLabel"))
	ok(_drill_n() == n0 + 5 and s.drill_events == 5, "StudyLog drill is +5 exactly (got +%d)" % (_drill_n() - n0))
	var cards: Dictionary = _memo_cards(id)
	var all_state2 := cards.size() == 5
	var latest_due := 0
	for k in cards:
		all_state2 = all_state2 and int((cards[k] as Dictionary)["state"]) == FSRS.State.REVIEW
		latest_due = maxi(latest_due, int((cards[k] as Dictionary)["due"]))
	ok(all_state2, "memo.json: 5 cards, all in the review state (two Good ratings each)")
	ok(latest_due > NOW and latest_due <= NOW + 3 * DAY, "every card is due within 3 days (latest due +%.2f days)" % (float(latest_due - NOW) / float(DAY)))
	var memo_json: String = _read(_memo_path(id)).to_lower()
	var leak_in_file := false
	for ln in lines:
		for w in String(ln).to_lower().split(" ", false):
			if w.length() >= 4 and memo_json.contains(w):
				leak_in_file = true
	ok(not leak_in_file, "memo.json holds no lyric words (hash keys and numbers only)")
	ok(s.go_back() and s.view == "home", "[집으로]: back to home")
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 5/6" and _label_text(s, "DueLabel") == "오늘 복습 0줄" and _label_text(s, "NewLabel") == "오늘 새 줄 1줄", "home right after: 외운 줄 5/6, 복습 0줄, 새 줄 1줄")
	# 3 days later
	var key0: String = _keys(id)[0]
	var before: Dictionary = (_memo_cards(id)[key0] as Dictionary).duplicate()
	_clock = NOW + 3 * DAY
	s.show_home()
	await _frames(2)
	ok(_label_text(s, "DueLabel") == "오늘 복습 5줄" and _label_text(s, "NewLabel") == "오늘 새 줄 1줄", "3 days later: 오늘 복습 5줄 (got '%s'), 새 줄 1줄" % _label_text(s, "DueLabel"))
	ok(_start(s) and int(s.session.current()["total"]) == 6, "[오늘 외우기]: 5 review lines + 1 new line")
	var c0: Dictionary = s.session.current()
	var text0: String = str(c0["text"])
	ok(str(c0["kind"]) == "review" and bool(c0["final"]) and int(c0["stage"]) == int(c0["stage_count"]) - 1, "a review line starts at the last (blank) stage")
	ok(s.drill.line_text() == "" and _find(s.drill, "BlankHint") != null and _leaks(s.drill, text0).is_empty(), "the review line starts on an empty screen: no line text anywhere in the drill tree (leaks: %s)" % [_leaks(s.drill, text0)])
	ok(await _play_line(s), "the review line answered correctly")
	var after: Dictionary = _memo_cards(id)[key0]
	ok(int(after["due"]) > int(before["due"]) and int(after["due"]) > _clock + DAY and int(after["reps"]) == int(before["reps"]) + 1, "the card's due moved later: %d -> %d (+%.1f days from the clock), reps %d -> %d" % [int(before["due"]) - NOW, int(after["due"]) - NOW, float(int(after["due"]) - _clock) / float(DAY), int(before["reps"]), int(after["reps"])])
	ok(_has_text(s.drill, "다음 복습은 약"), "the line result names the next review time")
	_next_line(s)
	for k in 4:
		await _frames(2)
		ok(str(s.session.current()["kind"]) == "review" and await _play_line(s), "review line %d answered correctly" % (k + 2))
		_next_line(s)
	await _frames(2)
	ok(str(s.session.current()["kind"]) == "new" and await _play_line(s), "the last line is the new one: played from stage 0")
	_next_line(s)
	ok(await _until(func() -> bool: return s.view == "summary", 5.0), "the second session ended: summary")
	ok(_label_text(s, "DoneLabel") == "오늘 6줄 했어요" and _label_text(s, "ProgressLabel") == "외운 줄 6/6", "summary: 오늘 6줄, 외운 줄 6/6 (got '%s' / '%s')" % [_label_text(s, "DoneLabel"), _label_text(s, "ProgressLabel")])
	ok(int(s.last_summary["review_done"]) == 5 and int(s.last_summary["new_done"]) == 1, "summary: 5 review + 1 new")
	ok(_drill_n() == n0 + 11 and s.drill_events == 11, "StudyLog drill is +11 in all (got +%d)" % (_drill_n() - n0))
	var cards2: Dictionary = _memo_cards(id)
	var moved := true
	for k in cards:
		moved = moved and int((cards2[k] as Dictionary)["due"]) > _clock
	ok(cards2.size() == 6 and moved, "memo.json: 6 cards, the 5 reviewed cards are all due after the clock")
	# leave the screen: the hub list shows the progress
	ok(s.go_back() and s.view == "home", "back to home")
	var closed_ok: bool = s.go_back()
	await _wait_loaded(v)
	ok(closed_ok and v.screen == null and v.memo_text(id) == "외운 줄 6/6", "closing the screen returns to the list: row says '%s'" % v.memo_text(id))
	ok(Api.sent_count == sent0 and _reqs.is_empty(), "the whole English flow sent no PC request (Api.sent_count %d -> %d, hook requests %d)" % [sent0, Api.sent_count, _reqs.size()])
	_drop(v)
	SongStore.delete(id)


# ---------------------------------------------------------------- M8-3 일본어

func _test_japanese() -> void:
	print("[japanese: 5 lines, unit masks, typed grading with wrong-unit marks]")
	_fresh()
	_mode_pc()
	var lines: Array = _fixture_lines(JA_NAME)
	ok(lines.size() == 5, "the Japanese fixture has 5 lines")
	var id: String = _add_pasted("ja", "Kettle JA Practice", _fixture(JA_NAME))
	ok(id != "" and SongStore.load_song(id)["lang"] == "ja" and (SongStore.load_song(id)["lines"] as Array).size() == 5, "pasted Japanese lyrics saved: 5 lines, lang ja")
	var s: SongMemoScreen = _new_memo_screen(id, "ja")
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/5" and _label_text(s, "NewLabel") == "오늘 새 줄 5줄", "home: 외운 줄 0/5, 오늘 새 줄 5줄")
	ok(_start(s) and int(s.session.current()["total"]) == 5, "a session with the 5 Japanese lines")
	var d: SongMemoDrill = s.drill
	var c: Dictionary = s.session.current()
	var text0: String = str(c["text"])
	ok(text0 == lines[0] and int(c["stage"]) == 0 and d.line_text() == text0, "stage 0 shows the whole first line")
	_press(d, "ReadBtn")
	await _frames(2)
	c = s.session.current()
	var shown: String = d.line_text()
	var hidden: Array = c["hidden"]
	var units: Array = c["units"]
	var hidden_n := 0
	var visible_ok := true
	var hidden_gone := true
	for k in units.size():
		var w: String = str((units[k] as Dictionary)["w"])
		if bool(hidden[k]):
			hidden_n += 1
			hidden_gone = hidden_gone and not shown.contains(w)
		else:
			visible_ok = visible_ok and shown.contains(w)
	ok(int(c["stage"]) == 1 and hidden_n == int(c["hidden_count"]) and hidden_n >= 1 and hidden_n < units.size(), "stage 1: some, not all, of the 5 units are hidden (%d)" % hidden_n)
	ok(shown.count("____") == hidden_n and visible_ok and hidden_gone, "stage 1: each hidden unit is '____', the other units are shown ('%s')" % shown)
	# climb to the last stage with correct answers
	ok(await _advance_to_final(s), "advanced to the last stage with correct answers")
	ok(d.line_text() == "" and _find(d, "BlankHint") != null, "the last stage is an empty screen")
	# a wrong input: two units wrong -> fail, the wrong units are marked in the answer line (glyph, not colour only)
	d.set_typed("朝の窓辺で小さなポットが鳴る")
	ok(d.submit_typed(), "the wrong Japanese input was submitted")
	await _frames(2)
	var g: Dictionary = d.last["grade"]
	ok(_last_event(d) == "stage_fail" and not bool(g["passed"]) and int(g["score"]) >= 60 and int(g["score"]) < 85, "wrong input: the stage failed (score %d, line 85)" % int(g["score"]))
	ok(g["marks"] == [true, true, false, false, true], "the two wrong units are marked in the grade: %s" % [g["marks"]])
	var al: Node = _find(d, "AnswerLine")
	var parsed: String = (al as RichTextLabel).get_parsed_text() if al is RichTextLabel else ""
	ok(parsed.contains("✕小さなや") and parsed.contains("✕かんが") and not parsed.contains("✕朝の") and not parsed.contains("✕鳴る"), "the answer line marks exactly the wrong units with ✕ (%s)" % parsed)
	ok(_has_text(d, "✕") and _find(d, "RetryBtn") != null and _find(d, "RevealBtn") != null, "the result offers retry and reveal")
	_press(d, "RetryBtn")
	await _frames(2)
	d.set_typed(text0)
	ok(d.submit_typed(), "the correct line was submitted at the last stage")
	await _frames(2)
	ok(_last_event(d) == "line_done" and int((d.last["ev"] as Dictionary)["rating"]) == FSRS.Rating.HARD, "the line finished with rating Hard (one wrong answer on the last stage)")
	_next_line(s)
	for k in 4:
		ok(await _play_line(s), "Japanese line %d played with correct answers" % (k + 2))
		_next_line(s)
		await _frames(2)
	ok(await _until(func() -> bool: return s.view == "summary", 5.0), "the session ended: summary")
	ok(int(s.last_summary["lines_done"]) == 5 and int(s.last_summary["hard"]) == 1 and int(s.last_summary["good"]) == 4 and int(s.last_summary["again"]) == 0, "summary: 5 lines, 4 Good, 1 Hard, 0 Again")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 4/5", "progress: 외운 줄 4/5 (the Hard line is still learning; got '%s')" % _label_text(s, "ProgressLabel"))
	ok(_memo_cards(id).size() == 5, "memo.json holds 5 cards")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- M8-4 LRCLIB (가짜)

func _test_lrclib() -> void:
	print("[LRCLIB (fake server): find -> candidate -> save -> memorize]")
	_fresh()
	_mode_pc()
	await _lr_reset()
	var a := SongLyricsAddScreen.new()
	_stage(a)
	a.lrclib_base_url = _lr_base
	a.open("en", {"lang": "en"})
	a.set_title("Kettle Morning")
	a.set_artist("Test Artist")
	a.set_source("lrclib")
	await _frames(2)
	await get_tree().create_timer(0.6).timeout
	ok((await _lr_log()).is_empty() and a.lr_get_calls == 0 and a.lr_search_calls == 0, "typing the title / artist and choosing LRCLIB sent 0 requests")
	a.find_lyrics()
	ok(await _until(func() -> bool: return not a.lr_busy, 10.0), "[가사 찾기] finished")
	ok(a.lr_status == "found" and int(a.lr_record["id"]) == 1001, "an exact hit: record 1001 pre-selected")
	a.search_lyrics()
	ok(await _until(func() -> bool: return not a.lr_busy, 10.0), "[비슷한 곡 찾기] finished")
	var pick := -1
	for i in a.lr_items.size():
		var rec: Dictionary = a.lr_items[i]
		if SongAddScreen.usable_record(rec) and int(rec["id"]) == 1001:
			pick = i
	if pick < 0:
		for i in a.lr_items.size():
			if SongAddScreen.usable_record(a.lr_items[i]):
				pick = i
				break
	ok(pick >= 0 and a.choose_candidate(pick), "a candidate was chosen from the list (index %d of %d)" % [pick, a.lr_items.size()])
	var log1: Array = await _lr_log()
	ok(_lr_count(log1, "/api/get") == 1 and _lr_count(log1, "/api/search") <= 1 and log1.size() <= 2, "server saw get 1 + search <= 1 (paths: %s)" % [log1.map(func(r: Dictionary) -> String: return str(r["path"]))])
	ok(a.preview_text().contains("6줄"), "the chosen LRCLIB lyrics are previewed as 6줄")
	ok(a.save() == "", "saved")
	var id: String = a.added_id
	var sv: Dictionary = SongStore.load_song(id)
	var src: Dictionary = sv.get("source", {})
	ok(SongModel.is_lyrics(sv) and str(src.get("lyrics", "")) == "lrclib" and int(src.get("lrclib_id", 0)) > 0 and str(src.get("attribution", "")) == ATTRIBUTION, "saved: kind lyrics, source lrclib, lrclib_id recorded, attribution text stored")
	_drop(a)
	var s: SongMemoScreen = _new_memo_screen(id)
	await _frames(2)
	var at: Node = _find(s, "Attribution")
	ok(at is Label and (at as Label).text == ATTRIBUTION and (at as Label).is_visible_in_tree(), "the memorize screen shows the attribution line at the bottom")
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/6", "home: 외운 줄 0/6")
	ok(_start(s) and await _play_line(s), "a line of the LRCLIB song was memorized")
	_next_line(s)
	await _frames(2)
	ok(_find(s, "Attribution") != null and (_find(s, "Attribution") as Label).is_visible_in_tree(), "the attribution stays while a session runs")
	s.go_back()
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 1/6" and _memo_cards(id).size() == 1, "one line memorized: 외운 줄 1/6, memo.json holds 1 card")
	var log2: Array = await _lr_log()
	ok(log2.size() == log1.size() and _lr_count(log2, "/api/get") == 1 and _lr_count(log2, "/api/search") <= 1, "saving and memorizing sent no further LRCLIB request (%d in all)" % log2.size())
	ok((await _lr_bad_calls()).is_empty(), "the fake server saw no call other than get / search")
	_drop(s)
	SongStore.delete(id)


# ---------------------------------------------------------------- M8-5 폰 단독

func _test_phone_only() -> void:
	print("[phone alone: add, memorize, typed + self rating, review - no request at all]")
	_fresh()
	_mode_none()
	var sent0: int = Api.sent_count
	var n0: int = _drill_n()
	ok(Route.decide("POST", "/stt", {}) == "none", "phone-only mode: Route.decide('/stt') is 'none'")
	var v := SongView.new()
	_stage(v)
	v.refresh()
	await _wait_loaded(v)
	v.request_add_lyrics()
	ok(v.screen_kind == "lyrics_add", "[가사만 추가] opens without a PC")
	var a: SongLyricsAddScreen = v.screen as SongLyricsAddScreen
	a.set_title("Phone Flow Song")
	a.set_artist("Test Artist")
	a.set_pasted(_fixture(EN_NAME))
	ok(a.save() == "", "the pasted song was saved")
	var id: String = a.added_id
	ok(await _until(func() -> bool: return v.screen_kind == "memo", 10.0), "song_added -> the memorize screen")
	var s: SongMemoScreen = v.screen as SongMemoScreen
	s.now_fn = Callable(self, "_clock_now")
	s.show_home()
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 0/6" and _label_text(s, "NewLabel") == "오늘 새 줄 5줄", "home: 외운 줄 0/6, 오늘 새 줄 5줄")
	s.set_answer("speak") # speaking answers: with no PC the drill must fall back to self rating
	ok(Store.prefs.get("memo_answer", "") == "speak", "the answer mode is speak")
	ok(_start(s), "session started")
	var d: SongMemoDrill = s.drill
	ok(await _play_line(s, "", true) and _last_event(d) == "line_done", "line 1 memorized by self rating (잘했어요) at every stage")
	ok(d.stt_requests == 0 and _has_text(d, "스스로 평가"), "the verdict says it was a self rating; no /stt request was sent")
	_next_line(s)
	await _frames(2)
	# line 2: the first blank-ish stage gets '다시' once
	d = s.drill
	ok(_press(d, "ReadBtn"), "line 2: past the read stage")
	await _frames(2)
	var rws: Array = d.find_children("*", "RecorderWidget", true, false)
	ok(not rws.is_empty() and _find(d, "RecordBox") != null, "line 2: speaking mode shows the record box")
	(rws[0] as RecorderWidget).recorded.emit(_rec())
	await _frames(2)
	ok(d.phase == "self" and _find(d, "SelfRatePanel") != null, "recording on a phone alone opens the self rating panel (no /stt)")
	(_find(d, "SelfRatePanel") as SelfRatePanel).rated.emit(false)
	await _frames(2)
	ok(_last_event(d) == "stage_fail" and _has_text(d, "스스로 평가: 다시"), "'다시' counts as a failed stage")
	ok(await _play_line(s, "", true) and _last_event(d) == "line_done", "line 2 continued with self rating and finished")
	_next_line(s)
	await _frames(2)
	ok(d.stt_requests == 0, "no /stt request from the drill")
	ok(s.go_back() and s.view == "home", "go_back() leaves the session")
	await _frames(2)
	ok(_label_text(s, "ProgressLabel") == "외운 줄 2/6" and _memo_cards(id).size() == 2 and _drill_n() == n0 + 2, "two lines memorized: 외운 줄 2/6, 2 cards, StudyLog drill +2")
	# typed answers for the rest: back to input mode, +3 days
	s.set_answer("type")
	_clock = NOW + 3 * DAY
	s.show_home()
	await _frames(2)
	ok(_label_text(s, "DueLabel") == "오늘 복습 2줄", "3 days later: 오늘 복습 2줄 (got '%s')" % _label_text(s, "DueLabel"))
	var key0: String = _keys(id)[0]
	var before: Dictionary = (_memo_cards(id)[key0] as Dictionary).duplicate()
	ok(_start(s) and str(s.session.current()["kind"]) == "review" and bool(s.session.current()["final"]), "the review starts at the blank stage")
	ok(s.drill.line_text() == "" and _leaks(s.drill, str(s.session.current()["text"])).is_empty(), "the review line shows nothing of the line")
	ok(await _play_line(s), "the review line answered by typing")
	ok(int((_memo_cards(id)[key0] as Dictionary)["due"]) > int(before["due"]), "the card's due moved later")
	_next_line(s)
	await _frames(2)
	ok(await _play_line(s), "the second review line answered by typing")
	_next_line(s)
	await _frames(2)
	ok(str(s.session.current()["kind"]) == "new", "after the 2 review lines the queue goes on with new lines")
	ok(s.go_back() and s.view == "home", "back to home")
	await _frames(2)
	ok(_drill_n() == n0 + 4, "StudyLog drill +4 (2 self rated + 2 review lines)")
	ok(Api.sent_count == sent0, "phone alone: Api.sent_count did not change over the whole flow (%d -> %d)" % [sent0, Api.sent_count])
	ok(_reqs.is_empty(), "phone alone: no /stt and no /song/* request went through the hook (%d: %s)" % [_reqs.size(), _reqs])
	s.go_back()
	await _wait_loaded(v)
	ok(v.screen == null and v.memo_text(id) == "외운 줄 2/6", "closing the screen returns to the list ('%s')" % v.memo_text(id))
	_drop(v)
	SongStore.delete(id)
	Store.prefs.erase("memo_answer")
	_mode_pc()


# ---------------------------------------------------------------- M8-6 실패 입력

func _test_failures() -> void:
	print("[failures: wrong answers, reveal, ratings, broken memo.json, delete]")
	_fresh()
	_mode_pc()
	var lines: Array = _fixture_lines(EN_NAME)
	var id: String = _add_pasted("en", "Failure Flow Song", _fixture(EN_NAME))
	var s: SongMemoScreen = _new_memo_screen(id)
	await _frames(2)
	ok(_start(s), "session started")
	var d: SongMemoDrill = s.drill
	# line 1: wrong twice on the last stage -> answer shown, stage down, pass again -> Again
	ok(await _advance_to_final(s), "line 1: advanced to the last stage")
	var last_stage: int = int(s.session.current()["stage"])
	d.set_typed(WRONG_EN)
	d.submit_typed()
	await _frames(2)
	ok(_last_event(d) == "stage_fail" and int((d.last["ev"] as Dictionary)["fails_stage"]) == 1 and _find(d, "RetryBtn") != null and _has_text(d, "✕"), "wrong answer 1: stage_fail, retry offered")
	_press(d, "RetryBtn")
	await _frames(2)
	d.set_typed(WRONG_EN)
	d.submit_typed()
	await _frames(2)
	var ev: Dictionary = d.last["ev"]
	ok(_last_event(d) == "revealed" and bool(ev["dropped"]) and bool(ev["from_final"]) and int(s.session.current()["stage"]) == last_stage - 1, "wrong answer 2: the answer is revealed and the stage goes down (%d -> %d)" % [last_stage + 1, int(s.session.current()["stage"]) + 1])
	var al: Node = _find(d, "AnswerLine")
	ok(al is RichTextLabel and (al as RichTextLabel).get_parsed_text().contains("kettle") and _has_text(d, "단계가 내려갔어요"), "the revealed answer line is on screen, with the 'stage went down' note")
	ok(_press(d, "NextBtn"), "[계속]")
	await _frames(2)
	var c: Dictionary = s.session.current()
	ok(not bool(c["final"]) and str(d.line_text()) != "", "one stage easier: the line is partly shown again")
	ok(await _play_line(s), "line 1 passed again through the remaining stages")
	ok(_last_event(d) == "line_done" and int((d.last["ev"] as Dictionary)["rating"]) == FSRS.Rating.AGAIN, "line 1: rating Again (the answer was revealed on the last stage)")
	var card1: Dictionary = _memo_cards(id)[_keys(id)[0]]
	ok(int(card1["state"]) == FSRS.State.LEARNING and int(card1["reps"]) == 1, "line 1: one Again -> a learning card (not memorized)")
	_next_line(s)
	await _frames(2)
	# line 2: one wrong on the last stage, then right -> Hard
	ok(await _advance_to_final(s), "line 2: advanced to the last stage")
	d.set_typed(WRONG_EN)
	d.submit_typed()
	await _frames(2)
	ok(_last_event(d) == "stage_fail", "line 2: a wrong answer fails the stage")
	ok(await _play_line(s), "line 2: retried and passed")
	ok(_last_event(d) == "line_done" and int((d.last["ev"] as Dictionary)["rating"]) == FSRS.Rating.HARD, "line 2: rating Hard (one wrong answer, then right)")
	_next_line(s)
	await _frames(2)
	# line 3: all right -> Good; line 4 + 5 too
	for k in 3:
		ok(await _play_line(s), "line %d played with correct answers" % (k + 3))
		ok(_last_event(d) == "line_done" and int((d.last["ev"] as Dictionary)["rating"]) == FSRS.Rating.GOOD, "line %d: rating Good" % (k + 3))
		_next_line(s)
		await _frames(2)
	ok(await _until(func() -> bool: return s.view == "summary", 5.0), "the queue ended: summary")
	ok(int(s.last_summary["again"]) == 1 and int(s.last_summary["hard"]) == 1 and int(s.last_summary["good"]) == 3, "summary: Again 1, Hard 1, Good 3 (got %d / %d / %d)" % [int(s.last_summary["again"]), int(s.last_summary["hard"]), int(s.last_summary["good"])])
	ok(_label_text(s, "ProgressLabel") == "외운 줄 3/6" and _memo_cards(id).size() == 5, "progress: 외운 줄 3/6 (Again and Hard lines still learning), 5 cards")
	ok(lines.size() == 6, "fixture sanity")
	# broken memo.json made in between -> quarantined, a fresh start
	ok(s.go_back() and s.view == "home", "back to home")
	var mp: String = _memo_path(id)
	ok(FileAccess.file_exists(mp), "memo.json exists before it is broken")
	_write(mp, '{"v":1,"lines":{"abc')
	_toasts = []
	s.open("en", {"id": id}) # what the hub does when the song is opened again
	await _frames(2)
	ok(_toast_has("외우기 기록이 깨져 새로 시작했어요"), "a cut memo.json: the toast says it started fresh")
	ok(FileAccess.file_exists(mp + ".bad") and not FileAccess.file_exists(mp), "the broken file was moved to memo.json.bad")
	ok(s.view == "home" and _has_text(s, SongMemoScreen.MSG_BAD_MEMO) and _label_text(s, "ProgressLabel") == "외운 줄 0/6", "home shows the note and starts from 외운 줄 0/6")
	ok(_start(s) and await _play_line(s), "a session runs normally on the fresh record")
	ok(FileAccess.file_exists(mp) and _memo_cards(id).size() == 1, "the fresh memo.json was saved with 1 card")
	s.go_back()
	await _frames(2)
	_drop(s)
	# delete the song from the list: row gone, folder gone
	var v := SongView.new()
	_stage(v)
	v.refresh()
	await _wait_loaded(v)
	ok(v.row_for(id) != null and v.song_kind(id) == "lyrics" and v.delete_text(id).contains("외우기 기록"), "the list shows the song with the lyrics delete text")
	v.delete_now(id)
	await _wait_loaded(v)
	ok(v.row_for(id) == null and v.song_kind(id) == "" and SongStore.list().is_empty(), "after delete the song is gone from the list and from the store")
	ok(not DirAccess.dir_exists_absolute(_g(SongStore.song_dir(id))) and _listing(ROOT).is_empty(), "after delete the song folder (memo.json and memo.json.bad too) is gone: 0 entries left")
	_drop(v)
	_fresh()


# ---------------------------------------------------------------- M8-7 정리

func _test_cleanup() -> void:
	print("[cleanup: nothing outside user://test_* changed]")
	ok(_user_listing() == _before, "the user's prefs / progress / studylog / remote / sync files and user://songs are untouched: before == after")
	ok(_top_names() == _top_before, "nothing outside user://test_* was added or removed in user:// (%s)" % [_top_names()])
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(DIR)), "the test folders are cleaned up")
	ok(_lr_pid <= 0, "no fake server process of this test is left")
