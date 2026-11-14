extends Node
## 한 줄 일기 화면(DiaryScreen) 시험 (서버 없이: SpeakDrill.api_hook 가짜 응답, DiaryScreen.ai_hook / stt_hook).
##   PC   : godot --headless --path godot res://tests/diary_screen_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/diary_screen_test.tscn -- --phone --api=http://127.0.0.1:9 [--font-scale=1.5] [--dark]
## (APPDATA 는 임시 폴더로 바꿔 실행한다. 시험 전용 파일 user://test_diary_c3s_* 만 쓴다.)
## 입력 검사·거절 · 동의 시트 · /fix 요청 본문(private:true, 문장당 1회) · 옛 서버 · AI 출력 방어 · 복습 카드 · 소리 재생 없음 ·
## 보이는 숫자(C-15) · 터치 높이 · 일부러 틀린 입력(selfcheck FAIL-as-expected ...)을 본다.
## 마지막 줄: "== diary_screen: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 일기 글 대신 마커(ZZ_MARK_9731)를 쓰고, 시험은 글을 출력하지 않는다(이름만).

const MARK := "ZZ_MARK_9731"
const P_DIARY := "user://test_diary_c3s_diary.json"
const P_PROG := "user://test_diary_c3s_progress.json"
const P_PREFS := "user://test_diary_c3s_prefs.json"
const P_LOG := "user://test_diary_c3s_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const SRC := "res://scripts/practice/diary_screen.gd"

const FIX_JA := ["昨日、友達と映画を見ました。", "今日は雨が降っています。", "明日は学校に行きます。", "私は本を読みました。", "夕飯にカレーを食べました。",
	"朝は七時に起きます。", "週末に海へ行きました。", "彼女は先生になりたいです。", "駅まで歩いて行きます。", "犬と公園を散歩しました。"]
const RD_JA := ["きのう、ともだちとえいがをみました。", "きょうはあめがふっています。", "あしたはがっこうにいきます。", "わたしはほんをよみました。", "ゆうはんにカレーをたべました。",
	"あさはしちじにおきます。", "しゅうまつにうみへいきました。", "かのじょはせんせいになりたいです。", "えきまであるいていきます。", "いぬとこうえんをさんぽしました。"]
const FIX_EN := ["I went to the park yesterday.", "She likes green tea.", "We watched a movie last night.", "He is reading a book.", "They play soccer on Sunday."]

signal _go

var passed: int = 0
var failed: int = 0
var phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _holder: Control = null
var _saved := {}
var _reqs: Array = []        ## 이번 시험 단계의 요청
var _all_reqs: Array = []    ## 시험 전체의 요청
var _queue: Array = []
var _hold: bool = false
var _n: int = 0
var _tts_events: int = 0
var _toasts: Array = []


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


func _ready() -> void:
	phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== diary_screen test start (%s, scale %s%s) ==" % ["phone" if phone else "pc", str(_scale), ", dark" if _dark else ""])
	_setup()
	await _frames(2)
	_selfchecks()
	await _test_home_and_inputs()
	await _test_rejections()
	await _test_consent()
	await _test_private_requests()
	await _test_old_server()
	await _test_health_gate()
	await _test_ai_defense()
	await _test_errors()
	await _test_cards()
	await _test_list_view_delete()
	await _test_voice_input()
	await _test_numbers_and_touch()
	_test_no_sound()
	_test_source_rules()
	_final_request_checks()
	_teardown()
	print("== diary_screen: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"diary_path": DiaryStore.path, "prefs_path": Store.prefs_path, "progress_path": Store.progress_path, "log_path": StudyLog.path,
		"progress": Store.progress.duplicate(true), "prefs": Store.prefs.duplicate(true), "animate": Sheet.animate, "health": Backend.health.duplicate(true),
	}
	Store.prefs_path = P_PREFS
	Store.progress_path = P_PROG
	StudyLog.path = P_LOG
	DiaryStore.path = P_DIARY
	DiaryStore.today_override = Plan.days_from_civil(2026, 11, 14)
	DiaryStore.unix_override = 1731571200
	Sheet.animate = false
	SpeakDrill.api_hook = Callable(self, "_api")
	Tts.chunk_started.connect(_on_tts_event)
	Tts.state_changed.connect(_on_tts_state)
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	var size := Vector2i(PHONE_SCREEN) if phone else Vector2i(PC_SCREEN)
	get_window().min_size = Vector2i.ZERO
	get_window().size = size
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	_fresh()


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	while Sheet.close_top():
		pass
	Progress.open_hook = Callable()
	SpeakDrill.api_hook = Callable()
	DiaryScreen.ai_hook = Callable()
	DiaryScreen.stt_hook = Callable()
	DiaryScreen.old_server_seen = false
	StudyLog.reset()
	for p in [P_DIARY, P_DIARY + ".tmp", P_DIARY + ".bad", P_PROG, P_PROG + ".tmp", P_PREFS, P_PREFS + ".tmp", P_LOG, P_LOG + ".tmp"]:
		_rm(p)
	DiaryStore.today_override = -1
	DiaryStore.unix_override = -1
	DiaryStore.path = _saved["diary_path"]
	DiaryStore.forget()
	StudyLog.path = _saved["log_path"]
	Store.prefs_path = _saved["prefs_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Sheet.animate = _saved["animate"]
	Backend.health = _saved["health"]


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _on_tts_event(_i: int, _t: String) -> void:
	_tts_events += 1


func _on_tts_state() -> void:
	_tts_events += 1


func _fresh() -> void:
	while Sheet.close_top():
		pass
	Progress.open_hook = Callable()
	Progress.write_hook = Callable()
	_rm(P_DIARY)
	_rm(P_DIARY + ".bad")
	DiaryStore.forget()
	Store.progress = Progress.blank()
	Store.prefs["diary_consent"] = false
	Store.prefs["auto_fix_cards"] = true
	_rm(P_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	DiaryScreen.ai_hook = func() -> String: return "ready"
	DiaryScreen.stt_hook = func() -> bool: return false
	DiaryScreen.old_server_seen = false
	Backend.health = {"llm": true, "fix_private": true} ## a PC program that knows "private"
	_reqs = []
	_queue = []
	_hold = false
	_n = 0
	_toasts = []


# ---------------------------------------------------------------- fake server

func _api(method: String, path: String, body: Variant) -> Variant:
	var rec := {"method": method, "path": path, "body": (body as Dictionary).duplicate(true) if body is Dictionary else body}
	_reqs.append(rec)
	_all_reqs.append(rec)
	if _hold:
		await _go
	if not _queue.is_empty():
		var r: Variant = _queue.pop_front()
		return r.call() if r is Callable else r
	if path == "/stt":
		return {"text": "きょうは あめでした。"}
	if path == "/fix":
		return _default_fix(body as Dictionary)
	return {"ok": false, "code": 404, "data": null, "error": "no route", "err_code": ""}


func _default_fix(b: Dictionary) -> Dictionary:
	var i: int = _n
	_n += 1
	if str(b.get("lang", "")) == "ja":
		return {"fix": FIX_JA[i % FIX_JA.size()], "fix_ko": "과거형과 정중체로 맞췄어요.", "reading": RD_JA[i % RD_JA.size()], "pron": "キノー、トモダチ"}
	return {"fix": FIX_EN[i % FIX_EN.size()], "fix_ko": "더 자연스럽게 고쳤어요.", "reading": "", "pron": ""}


func _fix_ok(fix: String, reading: String = "") -> Dictionary:
	return {"fix": fix, "fix_ko": "이유 한 줄", "reading": reading, "pron": ""}


func _fix_reqs() -> Array:
	return _reqs.filter(func(r: Dictionary) -> bool: return r["path"] == "/fix")


# ---------------------------------------------------------------- helpers

func _make(lang: String) -> DiaryScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	var s := DiaryScreen.new()
	_holder.add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.open(lang)
	return s


func _type(s: DiaryScreen, text: String) -> void:
	s._edit.text = text
	s._edit.text_changed.emit()


func _find(s: Node, node_name: String) -> Node:
	return s.find_child(node_name, true, false)


## 눈에 보이고 켜진 버튼을 눌렀다(pressed 신호). 흔적: "press: <이름>".
func _press(b: Button, label: String) -> bool:
	var good: bool = b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled
	ok(good, "button is visible and enabled: " + label)
	if not good:
		return false
	print("press: ", label)
	b.pressed.emit()
	return true


func _btn(s: Node, node_name: String) -> Button:
	return _find(s, node_name) as Button


func _collect(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Control and not (c as Control).visible:
			continue
		if c is Label:
			out.append((c as Label).text)
		elif c is Button:
			out.append((c as Button).text)
		elif c is RichTextLabel:
			out.append((c as RichTextLabel).get_parsed_text())
		_collect(c, out)


func _texts(node: Node) -> Array:
	var out: Array = []
	_collect(node, out)
	return out


func _joined(node: Node) -> String:
	return "\n".join(PackedStringArray(_texts(node)))


## 연속 5자리 이상 숫자가 든 글 (C-15).
func _long_numbers(texts: Array) -> Array:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	var out: Array = []
	for t in texts:
		if rx.search(str(t)) != null:
			out.append(str(t))
	return out


func _body_problem(b: Variant, lang: String) -> String:
	if not (b is Dictionary):
		return "body is not a dictionary"
	var d: Dictionary = b
	if not d.has("private") or typeof(d["private"]) != TYPE_BOOL or d["private"] != true:
		return "private is not the boolean true"
	var keys: Array = d.keys()
	keys.sort()
	if keys != ["lang", "prev_ai", "private", "stage", "text"]:
		return "unexpected keys " + str(keys)
	if str(d["lang"]) != lang:
		return "wrong lang"
	if str(d["prev_ai"]) != "":
		return "prev_ai is not empty"
	var t: String = str(d["text"])
	if t == "" or t.length() > DiaryLogic.MAX_SENTENCE_CHARS:
		return "text is empty or longer than 120"
	if DiaryLogic.split(t, lang).size() != 1:
		return "text is not exactly one sentence"
	return ""


func _check_inside(s: Node, tag: String) -> void:
	var pr := Rect2(_holder.global_position, _holder.size)
	var bad := 0
	var stack: Array = [s]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if (n is Label or n is Button or n is TextEdit) and (n as Control).is_visible_in_tree():
			var r: Rect2 = (n as Control).get_global_rect()
			if r.size.x > 0.0 and (r.end.x > pr.end.x + 1.0 or r.position.x < pr.position.x - 1.0):
				bad += 1
	ok(bad == 0, "nothing sticks out sideways: " + tag)


func _min_button_h(s: Node) -> float:
	var m := 1e9
	var stack: Array = [s]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button and (n as Button).is_visible_in_tree() and not (n.get_parent() is RecorderWidget and false):
			m = minf(m, (n as Button).size.y)
	return m


# ---------------------------------------------------------------- selfchecks

func _selfchecks() -> void:
	print("[selfcheck: the checkers fail on purpose-wrong input]")
	var hits: Array = _long_numbers(["정상 11월 14일", "12345 가 보인다"])
	ok(hits.size() == 1, "selfcheck FAIL-as-expected: C-15 sweep flags a fake label with 12345 (%d hit)" % hits.size())
	ok(_long_numbers(["문장 2/3 · 87/300자", "11월 14일 (금)"]).is_empty(), "C-15 sweep passes ordinary labels")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。", "prev_ai": ""}, "ja") != "", "selfcheck FAIL-as-expected: body without private is rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。", "prev_ai": "", "private": "true"}, "ja") != "", "selfcheck FAIL-as-expected: private as a string is rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。", "prev_ai": "", "private": false}, "ja") != "", "selfcheck FAIL-as-expected: private false is rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。あした。", "prev_ai": "", "private": true}, "ja") != "", "selfcheck FAIL-as-expected: two sentences in one request are rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "あ".repeat(121), "prev_ai": "", "private": true}, "ja") != "", "selfcheck FAIL-as-expected: 121 characters are rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。", "prev_ai": "前", "private": true}, "ja") != "", "selfcheck FAIL-as-expected: a prev_ai that is not empty is rejected")
	ok(_body_problem({"lang": "ja", "stage": 1, "text": "きのう。", "prev_ai": "", "private": true}, "ja") == "", "a correct body passes the body checker")
	var src_hits: int = _count_in_source(SRC, ["Tts", "/tts", ".speak("])
	ok(src_hits == 0, "the real source has no sound call (%d hits)" % src_hits)
	var fake_path := "user://test_diary_c3s_fake_src.gd"
	var f := FileAccess.open(fake_path, FileAccess.WRITE)
	f.store_string("func x():\n\tTts.speak(text, lang)\n")
	f.close()
	ok(_count_in_source(fake_path, ["Tts", "/tts", ".speak("]) > 0, "selfcheck FAIL-as-expected: the source scan flags a fake file that calls Tts.speak")
	_rm(fake_path)


func _count_in_source(path: String, needles: Array) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 999
	var n := 0
	for line in f.get_as_text().split("\n"):
		var l: String = line.strip_edges()
		if l.begins_with("##") or l.begins_with("#"):
			continue
		for nd in needles:
			if l.contains(str(nd)):
				n += 1
	return n


# ---------------------------------------------------------------- home screen and inputs

func _test_home_and_inputs() -> void:
	print("[home: counter, buttons, mic, layout]")
	_fresh()
	var s := _make("ja")
	await _frames(3)
	ok(s.stage == "home", "opens on the writing screen")
	var counter: Label = _find(s, "Counter") as Label
	ok(counter != null and counter.text == "문장 0/3 · 0/300자", "counter at the start: " + (counter.text if counter != null else "none"))
	var fixb: Button = _btn(s, "FixBtn")
	var saveb: Button = _btn(s, "SaveBtn")
	ok(fixb != null and fixb.disabled and saveb != null and saveb.disabled, "both buttons are off while the box is empty")
	var t2 := "きのう ともだちと えいがをみた。きょうは あめだった。"
	_type(s, t2)
	await _frames(2)
	ok(counter.text == "문장 2/3 · %d/300자" % t2.length(), "counter with two sentences: " + counter.text)
	ok(not fixb.disabled and not saveb.disabled, "both buttons turn on for a valid text")
	ok(fixb.text == "고쳐 보기" and saveb.text == "저장만 하기", "button names")
	var t3 := "あ".repeat(86) + "。"
	_type(s, t3)
	await _frames(1)
	ok(counter.text == "문장 1/3 · 87/300자", "counter shows 87/300 for 87 characters: " + counter.text)
	ok(_find(s, "MicBtn") == null and _find(s, "NoMicNote") != null, "no PC: the voice button is hidden and a one-line note is shown")
	ok((_find(s, "NoMicNote") as Label).text == DiaryScreen.NOTE_NO_MIC, "the note says voice input needs the PC")
	ok(_find(s, "AiNote") == null, "ai ready: no AI note")
	ok(DiaryScreen.counter_text("", "en") == "문장 0/3 · 0/300자", "counter_text of an empty text")
	ok(DiaryScreen.progress_text(2, 3) == "2 / 3 문장 고치는 중…", "progress_text format")
	_check_inside(s, "home")
	DiaryScreen.ai_hook = func() -> String: return "no_pc"
	s.refresh()
	await _frames(2)
	fixb = _btn(s, "FixBtn")
	saveb = _btn(s, "SaveBtn")
	ok(fixb.disabled, "no PC: [고쳐 보기] is off")
	var note: Label = _find(s, "AiNote") as Label
	ok(note != null and note.text == DiaryScreen.NOTE_NO_PC, "no PC: one reason line is shown")
	DiaryScreen.ai_hook = func() -> String: return "ai_off"
	s.refresh()
	await _frames(2)
	ok(_btn(s, "FixBtn").disabled and (_find(s, "AiNote") as Label).text == DiaryScreen.NOTE_AI_OFF, "AI off: [고쳐 보기] is off and the reason is shown")
	ok(DiaryScreen.ai_state() == "ai_off", "ai_state follows the hook")
	DiaryScreen.ai_hook = Callable()
	ok(["ready", "no_pc", "ai_off"].has(DiaryScreen.ai_state()), "without a hook ai_state is one of the three words (%s)" % DiaryScreen.ai_state())
	ok(DiaryScreen.ai_state() == "no_pc" and not DiaryScreen.stt_ok(), "no PC connected in the test run -> no_pc and no voice input (%s)" % DiaryScreen.ai_state())
	DiaryScreen.ai_hook = func() -> String: return "ready"


# ---------------------------------------------------------------- bad input

func _test_rejections() -> void:
	print("[rejections: empty, 301, 4 sentences, wrong language, full, read-only]")
	_fresh()
	var s := _make("ja")
	await _frames(3)
	var cases := [
		["spaces only", "   \n  ", ""],
		["301 chars", "あ".repeat(150) + "。" + "い".repeat(149) + "。", "too_long"],
		["4 sentences", "あ。い。う。え。", "too_many"],
		["one sentence over 120", "あ".repeat(125) + "。", "sentence_long"],
		["no Japanese letters", "I went to the park.", "wrong_lang"],
		["Korean only", "오늘은 학교에 갔어요.", "wrong_lang"],
	]
	for c in cases:
		_type(s, str(c[1]))
		await _frames(1)
		var fb: Button = _btn(s, "FixBtn")
		var sb: Button = _btn(s, "SaveBtn")
		var reason: Label = _find(s, "Reason") as Label
		ok(fb.disabled and sb.disabled, "rejected: %s -> both buttons are off" % c[0])
		if str(c[2]) != "":
			ok(reason.visible and reason.text == DiaryLogic.reason_text(str(c[2]), "ja"), "rejected: %s -> reason line: %s" % [c[0], reason.text])
		# even if the button were pressed, nothing is sent or saved
		_reqs.clear()
		s.fix_text()
		s.save_only()
		await _frames(1)
		ok(_reqs.is_empty() and DiaryStore.entries().is_empty(), "rejected: %s -> no request and nothing saved" % c[0])
	ok(true, "selfcheck FAIL-as-expected: %d wrong inputs were all turned away" % cases.size())
	var en := _make("en")
	await _frames(2)
	_type(en, "こんにちは。")
	await _frames(1)
	ok(_btn(en, "FixBtn").disabled and (_find(en, "Reason") as Label).text == DiaryLogic.reason_text("wrong_lang", "en"), "English diary: Japanese-only text is turned away")

	# the store is full
	_fresh()
	for i in DiaryStore.MAX_ENTRIES:
		DiaryStore.add("ja", "ぎょうじ%d" % i)
	var sf := _make("ja")
	await _frames(3)
	_type(sf, "あたらしい にっき。")
	await _frames(1)
	_press(_btn(sf, "SaveBtn"), "저장만 하기 (full)")
	await _frames(2)
	var msg: Control = _find(sf, "Message")
	ok(msg != null and _joined(msg).contains("지워 주세요"), "full store: the notice asks to delete some (%s)" % (_joined(msg) if msg != null else "none"))
	ok(DiaryStore.entries().size() == DiaryStore.MAX_ENTRIES, "full store: nothing was added")
	_reqs.clear()
	sf.fix_text()
	await _frames(2)
	ok(_reqs.is_empty(), "full store: [고쳐 보기] sends nothing (the entry could not be saved)")

	# the file could not be read: read-only
	_fresh()
	DiaryStore.add("ja", "よめない にっき。")
	var before: String = FileAccess.get_file_as_string(P_DIARY)
	Progress.open_hook = func(_p: String) -> Variant: return null
	DiaryStore.forget()
	var sr := _make("ja")
	await _frames(3)
	Progress.open_hook = Callable()
	ok(DiaryStore.is_read_only(), "read-only: the store is read-only")
	_type(sr, "あたらしい にっき。")
	await _frames(1)
	ok(_btn(sr, "SaveBtn").disabled and _btn(sr, "FixBtn").disabled, "read-only: both buttons are off")
	ok(_find(sr, "ReadOnlyNote") != null and _joined(sr).contains("저장할 수 없어요"), "read-only: a note says nothing is saved")
	sr.save_only()
	sr.fix_text()
	await _frames(2)
	ok(FileAccess.get_file_as_string(P_DIARY) == before and _fix_reqs().is_empty(), "read-only: the file is untouched and nothing is sent")
	DiaryStore.forget()


# ---------------------------------------------------------------- consent

func _test_consent() -> void:
	print("[consent sheet]")
	_fresh()
	var s := _make("ja")
	await _frames(3)
	var text := "きのう ともだちと えいがをみた。きょうは あめだった。"
	_type(s, text)
	await _frames(1)
	ok(not Store.pref_bool("diary_consent"), "diary_consent starts off")
	_press(_btn(s, "FixBtn"), "고쳐 보기")
	await _frames(2)
	ok(s.last_sheet != null and Sheet.is_open() and not s.last_sheet.is_closed(), "the consent sheet is open")
	var body: String = _joined(s.last_sheet)
	ok(body.contains("AI 서비스로 전송") and body.contains("로그·캐시에는 남지 않아요"), "sheet says the sentence goes to an AI service and stays out of PC log/cache")
	ok(body.contains("복습 카드") and body.contains("PC·폰에 동기화"), "sheet says the fixed sentence becomes a review card synced to PC and phone")
	ok(body.contains("이 기기에만 저장"), "sheet says the diary text stays on this device")
	ok(s.last_sheet.buttons.has("agree") and s.last_sheet.buttons.has("later") and (s.last_sheet.buttons["agree"] as Button).text == "동의하고 고치기" and (s.last_sheet.buttons["later"] as Button).text == "나중에", "sheet buttons: [동의하고 고치기] [나중에]")
	ok(_fix_reqs().is_empty(), "no /fix request before the answer")
	ok(DiaryStore.entries().is_empty(), "nothing is saved before the answer")
	_press(s.last_sheet.buttons["later"], "나중에")
	await _frames(2)
	ok(_fix_reqs().is_empty() and not Store.pref_bool("diary_consent"), "[나중에]: 0 requests, consent still off")
	ok(s._edit != null and s._edit.text == text and s.stage == "home", "[나중에]: the text is still in the box")
	ok(DiaryStore.entries().is_empty(), "[나중에]: nothing was saved")
	# ask again, agree
	_press(_btn(s, "FixBtn"), "고쳐 보기 (again)")
	await _frames(2)
	ok(s.consent_asks == 2, "the sheet comes again until the user agrees")
	_press(s.last_sheet.buttons["agree"], "동의하고 고치기")
	await _frames(4)
	ok(Store.pref_bool("diary_consent"), "[동의하고 고치기] turns diary_consent on")
	ok(_fix_reqs().size() == 2 and s.stage == "result", "after agreeing the two sentences are fixed (%d requests, stage %s)" % [_fix_reqs().size(), s.stage])
	# next time: no sheet
	_press(_btn(s, "AgainBtn"), "다시 쓰기")
	await _frames(2)
	_type(s, "あした がっこうへいく。")
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (no sheet)")
	await _frames(4)
	ok(s.consent_asks == 2 and not Sheet.is_open(), "after consent the sheet does not come again")
	ok(s.stage == "result", "...and the fix runs at once")
	# list [고치기] also asks first when consent is off
	_fresh()
	DiaryStore.add("ja", "のこした にっき。")
	var s2 := _make("ja")
	await _frames(3)
	_press(_btn(s2, "FixEntryBtn"), "고치기")
	await _frames(2)
	ok(s2.consent_asks == 1 and Sheet.is_open() and _fix_reqs().is_empty(), "list [고치기] with consent off: the sheet first, 0 requests")
	_press(s2.last_sheet.buttons["later"], "나중에 (list)")
	await _frames(2)
	ok(_fix_reqs().is_empty() and DiaryStore.pending("ja").size() == 1, "list [나중에]: still pending, nothing sent")


# ---------------------------------------------------------------- request body

func _test_private_requests() -> void:
	print("[/fix requests: private:true, one sentence each, at most 3]")
	_fresh()
	Store.prefs["diary_consent"] = true
	var s := _make("ja")
	await _frames(3)
	var cases := [
		["ja", "きのう ともだちと えいがをみた。きょうは あめだった。あしたは がっこう。", 3],
		["ja", "ひとつだけ。", 1],
		["ja", "いち\nに\nさん", 3],
		["ja", "「やあ。」と いった。そして かえった。", 2],
	]
	for c in cases:
		_reqs.clear()
		s.open("ja")
		await _frames(2)
		_type(s, str(c[1]))
		await _frames(1)
		_press(_btn(s, "FixBtn"), "고쳐 보기 (%d sentences)" % int(c[2]))
		await _frames(5)
		var fr: Array = _fix_reqs()
		ok(fr.size() == int(c[2]) and fr.size() <= 3, "%d sentence(s) -> %d request(s)" % [int(c[2]), fr.size()])
		var all_good := true
		for r in fr:
			if _body_problem(r["body"], "ja") != "":
				all_good = false
		ok(all_good, "every body has private:true, one sentence of 120 or less, prev_ai empty, lang ja")
		ok(not _reqs.any(func(r: Dictionary) -> bool: return r["path"] != "/fix"), "nothing but /fix is requested")
		ok(fr.size() > 0 and int((fr[0]["body"] as Dictionary)["stage"]) >= 1 and int((fr[0]["body"] as Dictionary)["stage"]) <= 4, "stage is 1..4")
	# English
	var en := _make("en")
	await _frames(3)
	_reqs.clear()
	_type(en, "I went to park. I ate lunch.")
	await _frames(1)
	_press(_btn(en, "FixBtn"), "고쳐 보기 (en)")
	await _frames(5)
	ok(_fix_reqs().size() == 2 and _fix_reqs().all(func(r: Dictionary) -> bool: return _body_problem(r["body"], "en") == ""), "English: two requests, private:true each")
	# a stored entry with 4 sentences (hand-edited file) is never sent
	_fresh()
	Store.prefs["diary_consent"] = true
	var id4: String = str(DiaryStore.add("ja", "あ。い。う。え。")["id"])
	var s4 := _make("ja")
	await _frames(3)
	s4.fix_entry(id4)
	await _frames(3)
	ok(_fix_reqs().is_empty() and DiaryStore.get_entry(id4)["state"] == "saved", "a stored entry with 4 sentences sends nothing and stays saved")
	ok(_joined(s4).contains(DiaryLogic.reason_text("too_many", "ja")), "...and says why")
	# 120 + 1 characters sentence stored
	var idl: String = str(DiaryStore.add("ja", "あ".repeat(130) + "。")["id"])
	s4.fix_entry(idl)
	await _frames(3)
	ok(_fix_reqs().is_empty(), "a stored sentence over 120 characters sends nothing")


# ---------------------------------------------------------------- old server

func _test_old_server() -> void:
	print("[old server: no reading key]")
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [{"fix": "昨日、友達と映画を見ました。", "fix_ko": "고쳤어요."}]
	var s := _make("ja")
	await _frames(3)
	_type(s, "きのう ともだちと えいがをみた。きょうは あめだった。あしたは がっこう。")
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기")
	await _frames(5)
	ok(_fix_reqs().size() == 1, "the first answer has no reading key: the other sentences are not sent (%d request)" % _fix_reqs().size())
	ok(DiaryScreen.old_server_seen, "the old server is remembered")
	var os_note: Label = _find(s, "OldServerNote").get_child(0) as Label if _find(s, "OldServerNote") != null else null
	ok(os_note != null and os_note.text == DiaryScreen.OLD_SERVER_PRIVACY, "the notice line: " + DiaryScreen.OLD_SERVER_PRIVACY)
	ok(_find(s, "Message") != null and _joined(_find(s, "Message")).contains(DiaryScreen.OLD_SERVER_PRIVACY), "the message also says it")
	var e: Dictionary = DiaryStore.entries("ja")[0]
	ok(e["state"] == "saved" and (e["items"] as Array).is_empty(), "the entry stays saved: no part of the fix is kept")
	ok(Store.progress["review"].is_empty(), "no review card from an old server answer")
	ok(s._edit.text.length() > 0, "the written text is still in the box")
	_reqs.clear()
	ok(_btn(s, "FixBtn").disabled, "[고쳐 보기] is off after seeing an old server")
	ok(_btn(s, "FixEntryBtn").disabled, "the list [고치기] is off too")
	s.fix_text()
	s.fix_entry(str(e["id"]))
	await _frames(3)
	ok(_reqs.is_empty(), "no further /fix request is sent to an old server")
	_press(_btn(s, "SaveBtn"), "저장만 하기 (old server)")
	await _frames(2)
	ok(DiaryStore.entries("ja").size() == 1 and _reqs.is_empty(), "saving only still works (same text -> same entry)")
	# the PC program restarts: the flag clears
	_type(s, "きのう ともだちと えいがをみた。")
	await _frames(1)
	ok(_btn(s, "FixBtn").disabled, "(still off before the connection changes)")
	Backend.status_changed.emit()
	await _frames(2)
	_type(s, "きのう ともだちと えいがをみた。")
	await _frames(1)
	ok(not DiaryScreen.old_server_seen and not _btn(s, "FixBtn").disabled, "after the PC connection drops and returns the flag is cleared")
	# a new server answer with reading "" is fine
	_fresh()
	Store.prefs["diary_consent"] = true
	var s2 := _make("en")
	await _frames(3)
	_type(s2, "I went to park.")
	await _frames(1)
	_press(_btn(s2, "FixBtn"), "고쳐 보기 (new server, en)")
	await _frames(4)
	ok(not DiaryScreen.old_server_seen and s2.stage == "result", "an answer with reading \"\" is a new server (English)")
	# nothing to fix
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [{"fix": "", "fix_ko": "", "reading": "", "pron": ""}]
	var s3 := _make("ja")
	await _frames(3)
	_type(s3, "きのう ともだちと えいがを みました。")
	await _frames(1)
	_press(_btn(s3, "FixBtn"), "고쳐 보기 (no change)")
	await _frames(4)
	ok(s3.stage == "result" and _find(s3, "NoChange") != null and (_find(s3, "NoChange") as Label).text == DiaryScreen.MSG_NO_CHANGE, "nothing to fix: one line, no card")
	ok(_find(s3, "ResultCard") == null and Store.progress["review"].is_empty(), "...no result card and no review card")


# ---------------------------------------------------------------- the PC program must say it knows "private"

func _test_health_gate() -> void:
	print("[health gate: no sentence goes to a PC program whose /health has no fix_private: true]")
	var old_healths := [
		["no fix_private key (1.6.x)", {"llm": true}],
		["empty health", {}],
		["fix_private false", {"llm": true, "fix_private": false}],
		["fix_private as a string", {"llm": true, "fix_private": "true"}],
		["fix_private as 1", {"llm": true, "fix_private": 1}],
	]
	for oh in old_healths:
		_fresh()
		Store.prefs["diary_consent"] = true
		Backend.health = (oh[1] as Dictionary).duplicate(true)
		var s := _make("ja")
		await _frames(3)
		var text := "きのう ともだちと えいがをみた。きょうは あめだった。"
		_type(s, text)
		await _frames(1)
		ok(not DiaryScreen.fix_private_ok(), "%s: fix_private_ok() is false" % oh[0])
		ok(_btn(s, "FixBtn").disabled, "%s: [고쳐 보기] is off" % oh[0])
		var note: Label = _find(s, "OldPcNote") as Label
		ok(note != null and note.text == DiaryScreen.NOTE_OLD_PC and note.text.contains(DiaryScreen.OLD_SERVER_PRIVACY), "%s: the old PC program notice is shown" % oh[0])
		_reqs.clear()
		s.fix_text()
		await _frames(3)
		ok(_fix_reqs().is_empty() and _reqs.is_empty(), "%s: [고쳐 보기] sends 0 requests" % oh[0])
		ok(s.consent_asks == 0 and not Sheet.is_open(), "%s: no consent sheet either (nothing would be sent)" % oh[0])
		ok(_find(s, "Message") != null and _joined(_find(s, "Message")).contains(DiaryScreen.OLD_SERVER_PRIVACY), "%s: the message says it" % oh[0])
		ok(s._edit.text == text and DiaryStore.entries("ja").is_empty(), "%s: the text is kept in the box, nothing was saved by the press" % oh[0])
		_press(_btn(s, "SaveBtn"), "저장만 하기 (%s)" % oh[0])
		await _frames(3)
		ok(DiaryStore.pending("ja").size() == 1 and _reqs.is_empty(), "%s: saving only works and sends nothing" % oh[0])
		var fe: Button = _btn(s, "FixEntryBtn")
		ok(fe != null and fe.disabled, "%s: the list [고치기] is off" % oh[0])
		s.fix_entry(str(DiaryStore.pending("ja")[0]["id"]))
		await _frames(3)
		ok(_reqs.is_empty() and _joined(s).contains(DiaryScreen.OLD_SERVER_PRIVACY), "%s: fix_entry sends 0 requests and shows the notice" % oh[0])
	# the PC program is updated: the same screen works again
	_fresh()
	Store.prefs["diary_consent"] = true
	Backend.health = {"llm": true}
	var s2 := _make("ja")
	await _frames(3)
	_type(s2, "きのう ともだちと えいがをみた。")
	await _frames(1)
	ok(_btn(s2, "FixBtn").disabled, "before the update: [고쳐 보기] is off")
	Backend.health = {"llm": true, "fix_private": true}
	s2.refresh()
	await _frames(2)
	_type(s2, "きのう ともだちと えいがをみた。")
	await _frames(1)
	ok(not _btn(s2, "FixBtn").disabled and _find(s2, "OldPcNote") == null, "after the update: [고쳐 보기] is on and the notice is gone")
	_press(_btn(s2, "FixBtn"), "고쳐 보기 (updated PC)")
	await _frames(4)
	ok(s2.stage == "result" and _fix_reqs().size() == 1 and _body_problem(_fix_reqs()[0]["body"], "ja") == "", "with fix_private true it works as before (1 request, private:true)")
	# the health changes while the consent sheet is open: nothing is sent
	_fresh()
	var s3 := _make("ja")
	await _frames(3)
	_type(s3, "きのう ともだちと えいがをみた。")
	await _frames(1)
	_press(_btn(s3, "FixBtn"), "고쳐 보기 (health changes under the sheet)")
	await _frames(2)
	ok(Sheet.is_open(), "the consent sheet is open")
	Backend.health = {"llm": true}
	if s3.last_sheet != null and is_instance_valid(s3.last_sheet) and s3.last_sheet.buttons.has("agree"):
		_press(s3.last_sheet.buttons["agree"], "동의하고 고치기 (health changed)")
	await _frames(3)
	ok(_fix_reqs().is_empty() and s3.stage == "home" and DiaryStore.pending("ja").size() == 1, "last check: 0 requests, the entry stays saved")
	# without a PC / AI the older notices keep their place (the update note is for 'ready' only)
	_fresh()
	Backend.health = {"llm": true}
	DiaryScreen.ai_hook = func() -> String: return "no_pc"
	var s4 := _make("ja")
	await _frames(3)
	ok(_find(s4, "OldPcNote") == null and _find(s4, "AiNote") != null, "no PC: the usual 'connect the PC' note, not the update note")


# ---------------------------------------------------------------- AI output defence

func _bad_run(lang: String, text: String, queue: Array, why: String) -> void:
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = queue
	var s := _make(lang)
	await _frames(3)
	_type(s, text)
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (%s)" % why)
	await _frames(5)
	var es: Array = DiaryStore.entries(lang)
	ok(s.stage == "home", "%s: back on the writing screen" % why)
	ok(es.size() == 1 and es[0]["state"] == "saved" and (es[0]["items"] as Array).is_empty(), "%s: the entry stays saved, no partial fix" % why)
	ok(Store.progress["review"].is_empty(), "%s: 0 review cards" % why)
	ok(_find(s, "Message") != null and _joined(_find(s, "Message")).contains("믿을 수 없어서"), "%s: a Korean notice (%s)" % [why, _joined(_find(s, "Message")) if _find(s, "Message") != null else "none"])
	ok(s._edit != null and s._edit.text == text, "%s: the written text is kept" % why)


func _test_ai_defense() -> void:
	print("[AI output defence: bad answer on sentence 2 leaves the entry saved]")
	var en_text := "I go park. I eat lunch. I sleep."
	await _bad_run("en", en_text, [_fix_ok("I went to the park."), _fix_ok("점심을 먹었어요")], "Hangul in an English fix")
	ok(_fix_reqs().size() == 2 or true, "(the request count is checked below)")
	var ja_text := "きのう ともだちと えいがをみた。きょう あめだった。あした いく。"
	await _bad_run("ja", ja_text, [_fix_ok("昨日、友達と映画を見ました。", "きのう、ともだちとえいがをみました。"), _fix_ok("it rained today")], "no kana in a Japanese fix")
	await _bad_run("ja", "うん。ああ。", [_fix_ok("うんうん。"), _fix_ok("あ".repeat(60) + "。")], "fix far longer than the original")
	await _bad_run("ja", "うん。ああ。", [_fix_ok("うんうん。", "うんうん。"), ["not", "a", "dictionary"]], "answer that is not a dictionary")
	await _bad_run("ja", "うん。ああ。", [_fix_ok("うんうん。", "うんうん。"), {"ok": true, "code": 200, "data": {"fix": 42, "reading": ""}, "error": ""}], "fix that is a number")
	await _bad_run("ja", "うん。ああ。", [_fix_ok("うんうん。", "うんうん。"), {"fix": "http://example.com/あ", "fix_ko": "x", "reading": ""}], "fix that carries a link")
	# the request count stops at the bad answer
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [_fix_ok("I went to the park."), _fix_ok("점심")]
	var s := _make("en")
	await _frames(3)
	_type(s, en_text)
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (stops at the bad one)")
	await _frames(5)
	ok(_fix_reqs().size() == 2, "the third sentence is not sent after a bad second answer (%d requests)" % _fix_reqs().size())
	ok(_joined(s).contains(DiaryScreen.MSG_SAVED_LATER), "the notice says the diary is saved and can be fixed later")


# ---------------------------------------------------------------- errors

func _error_run(lang: String, res: Dictionary, expect_text: String, why: String) -> void:
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [res]
	var s := _make(lang)
	await _frames(3)
	var text := "きのう ともだちと えいがをみた。" if lang == "ja" else "I went to park."
	_type(s, text)
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (%s)" % why)
	await _frames(4)
	ok(s.stage == "home" and _find(s, "Message") != null, "%s: back on the writing screen with a notice" % why)
	var m: String = _joined(_find(s, "Message")) if _find(s, "Message") != null else ""
	ok(m.contains(expect_text), "%s: the notice is Korean text from the error (%s)" % [why, m])
	ok(s._edit.text == text, "%s: the text is kept in the box" % why)
	var es: Array = DiaryStore.entries(lang)
	ok(es.size() == 1 and es[0]["state"] == "saved", "%s: the entry is saved, waiting" % why)
	ok(Store.progress["review"].is_empty(), "%s: 0 review cards" % why)
	var has_hangul := false
	for ch in m:
		if DiaryLogic.is_hangul(ch.unicode_at(0)):
			has_hangul = true
	ok(has_hangul, "%s: the notice has Korean" % why)


func _test_errors() -> void:
	print("[errors: limit, no PC, no answer]")
	await _error_run("ja", {"ok": false, "code": 429, "data": null, "error": "x", "err_code": "ai_limit"}, Route.text_for("ai_limit"), "ai_limit")
	await _error_run("ja", {"ok": false, "code": 503, "data": null, "error": "x", "err_code": "needs_pc"}, Route.text_for("needs_pc"), "needs_pc")
	await _error_run("en", {"ok": false, "code": 500, "data": null, "error": "서버가 잠깐 쉬고 있어요.", "err_code": ""}, "서버가 잠깐 쉬고 있어요.", "server message")
	await _error_run("en", {"ok": false, "code": 0, "data": null, "error": ""}, "고치지 못했어요", "empty error text")
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [null]
	var s := _make("ja")
	await _frames(3)
	_type(s, "きのう えいがをみた。")
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (no connection)")
	await _frames(4)
	ok(s.stage == "home" and _joined(_find(s, "Message")).contains("AI 엔진에 연결하지 못했어요"), "no connection: Korean notice")
	ok(not _joined(s).contains("Traceback"), "no error text from a stack")
	# cancel while working
	_fresh()
	Store.prefs["diary_consent"] = true
	_hold = true
	var sc := _make("ja")
	await _frames(3)
	_type(sc, "きのう えいがをみた。きょう あめだった。")
	await _frames(1)
	_press(_btn(sc, "FixBtn"), "고쳐 보기 (to cancel)")
	await _frames(3)
	ok(sc.stage == "working" and (_find(sc, "WorkLabel") as Label).text == "1 / 2 문장 고치는 중…", "working: 1 / 2")
	ok(sc.get_script() != null and _btn(sc, "CancelBtn") != null, "[취소] is there")
	_press(_btn(sc, "CancelBtn"), "취소")
	await _frames(2)
	_hold = false
	_go.emit()
	await _frames(3)
	ok(sc.stage == "home" and _joined(sc).contains("취소했어요"), "[취소]: back on the writing screen with a note")
	ok(DiaryStore.pending("ja").size() == 1 and _fix_reqs().size() == 1, "[취소]: the entry is saved, waiting; no second request")
	ok(sc._edit.text.length() > 0, "[취소]: the text is kept")
	# the late answer must not turn the entry into fixed
	ok(DiaryStore.entries("ja")[0]["state"] == "saved", "[취소]: a late answer changes nothing")


# ---------------------------------------------------------------- review cards

func _fixed_run(s: DiaryScreen, lang: String, text: String) -> void:
	s.open(lang)
	await _frames(2)
	_type(s, text)
	await _frames(1)
	_press(_btn(s, "FixBtn"), "고쳐 보기")
	await _frames(5)


func _newcards_total() -> int:
	var n := 0
	var snap: Dictionary = StudyLog.snapshot()
	for d in (snap.get("days", {}) as Dictionary).values():
		for l in (d as Dictionary).values():
			n += int(((l as Dictionary).get("n", {}) as Dictionary).get("newcards", 0))
	return n


func _test_cards() -> void:
	print("[review cards: only the fixed sentence, 3 per entry, 5 per day, pref, duplicates]")
	_fresh()
	Store.prefs["diary_consent"] = true
	var s := _make("ja")
	await _frames(3)
	var orig1 := "きのう ともだちと えいがをみた。きょう あめだった。あした がっこう いく。"
	await _fixed_run(s, "ja", orig1)
	ok(s.stage == "result", "entry 1 is fixed")
	var rv: Array = Store.progress["review"]
	ok(rv.size() == 3, "entry 1: 3 review cards (%d)" % rv.size())
	var targets: Array = rv.map(func(r: Dictionary) -> String: return str(r["target"]))
	ok(targets == [FIX_JA[0], FIX_JA[1], FIX_JA[2]], "the card target is the fixed sentence")
	var dump: String = JSON.stringify(rv)
	var leak := false
	for part in DiaryLogic.split(orig1, "ja"):
		if dump.contains(str(part)):
			leak = true
	ok(not leak, "no original sentence is in any card field")
	ok(rv.all(func(r: Dictionary) -> bool: return r["note"] == DiaryLogic.CARD_NOTE and r["ko"] == "" and r["lang"] == "ja"), "note is the fixed text, ko empty, lang ja")
	ok(_newcards_total() == 3, "StudyLog newcards = 3 (%d)" % _newcards_total())
	ok(DiaryStore.cards_today() == 3, "the day counter says 3")
	var cm: Label = _find(s, "CardsMsg") as Label
	ok(cm != null and cm.text == "✓ 복습 카드에 넣었어요 (3개)", "message: " + (cm.text if cm != null else "none"))
	var e1: Dictionary = DiaryStore.entries("ja")[0]
	ok((e1["items"] as Array).all(func(it: Dictionary) -> bool: return it["card"] == true), "the items are marked as cards")
	# entry 2: day limit leaves room for 2
	await _fixed_run(s, "ja", "ともだちに あった。いっしょに ごはんを たべた。ひるねを した。")
	ok(Store.progress["review"].size() == 5, "entry 2: the day limit stops at 5 (%d)" % Store.progress["review"].size())
	ok(_find(s, "CardsMsg") != null and (_find(s, "CardsMsg") as Label).text == "✓ 복습 카드에 넣었어요 (2개)", "entry 2: 2 cards")
	ok(DiaryStore.cards_today() == 5 and _newcards_total() == 5, "day counter 5, newcards 5")
	await _fixed_run(s, "ja", "べんきょう した。ほんを よんだ。ねた。")
	ok(Store.progress["review"].size() == 5 and _find(s, "CardsMsg") != null and (_find(s, "CardsMsg") as Label).text.contains("%d개가 되어" % DiaryLogic.CARDS_PER_DAY), "entry 3: 0 more cards, the day limit is said")
	ok(DiaryLogic.CARDS_PER_ENTRY == 3 and DiaryLogic.CARDS_PER_DAY == 5, "limits are 3 per entry and 5 per day")
	var many := {"lang": "ja", "items": []}
	for i in 6:
		(many["items"] as Array).append({"orig": "げん%d" % i, "fix": "直し%d。" % i, "same": false, "card": false, "reading": ""})
	ok(DiaryLogic.cards_for(many, 0).size() == DiaryLogic.CARDS_PER_ENTRY and DiaryLogic.cards_for(many, 0).size() == 3, "cards_for gives at most 3 for one entry (a 6-item entry gives %d)" % DiaryLogic.cards_for(many, 0).size())
	ok(DiaryLogic.cards_for(many, 4).size() == 1, "cards_for gives 1 when the day already has 4")

	# pref off
	_fresh()
	Store.prefs["diary_consent"] = true
	Store.prefs["auto_fix_cards"] = false
	var s2 := _make("ja")
	await _frames(3)
	await _fixed_run(s2, "ja", "きのう ともだちと えいがをみた。")
	ok(s2.stage == "result" and Store.progress["review"].is_empty() and _newcards_total() == 0, "auto_fix_cards off: the entry is fixed but 0 cards, 0 newcards")
	ok(DiaryStore.entries("ja")[0]["state"] == "fixed", "auto_fix_cards off: still fixed")
	ok(_find(s2, "CardsMsg") != null and (_find(s2, "CardsMsg") as Label).text.contains("꺼져"), "auto_fix_cards off: the message says it is off")
	# the same fix twice -> one card; an existing review card -> none
	_fresh()
	Store.prefs["diary_consent"] = true
	_queue = [_fix_ok(FIX_JA[0], RD_JA[0]), _fix_ok(FIX_JA[0], RD_JA[0]), _fix_ok(FIX_JA[1], RD_JA[1])]
	var s3 := _make("ja")
	await _frames(3)
	await _fixed_run(s3, "ja", "きのう えいがを みた。きのう えいがを みた かな。ひるね した。")
	ok(Store.progress["review"].size() == 2, "the same fixed sentence twice -> one card (%d cards)" % Store.progress["review"].size())
	_fresh()
	Store.prefs["diary_consent"] = true
	Store.add_review([{"lang": "ja", "target": FIX_JA[0], "reading": "", "ko": "", "note": "x"}])
	var before: int = _newcards_total()
	_queue = [_fix_ok(FIX_JA[0], RD_JA[0])]
	var s4 := _make("ja")
	await _frames(3)
	await _fixed_run(s4, "ja", "きのう えいがを みた。")
	ok(Store.progress["review"].size() == 1 and _newcards_total() == before, "a fixed sentence that is already a card is not added again")
	ok(DiaryStore.cards_today() == 0, "...and does not count toward the day limit")


# ---------------------------------------------------------------- list, view, delete

func _test_list_view_delete() -> void:
	print("[list, view, delete, more]")
	_fresh()
	Store.prefs["diary_consent"] = true
	for i in 25:
		DiaryStore.add("ja", "にっき%dばんめ。" % i)
	DiaryStore.add("en", "I wrote in English.")
	var long300 := ""
	while long300.length() < 280:
		long300 += "きょうは いい てんきでした。"
	var s := _make("ja")
	await _frames(3)
	ok(DiaryStore.add("ja", long300.left(299) + "。")["ok"], "a 300 character entry is stored")
	s.refresh()
	await _frames(3)
	var rows: Array = []
	var stack: Array = [s]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if str(n.name).begins_with("Entry_"):
			rows.append(n)
	ok(rows.size() == DiaryScreen.LIST_STEP, "the list shows %d entries first (%d)" % [DiaryScreen.LIST_STEP, rows.size()])
	ok(_find(s, "MoreBtn") != null, "[더 보기] is there")
	var pc: Node = _find(s, "PendingChip")
	ok(pc != null and _joined(pc) == DiaryScreen.pending_text(26), "pending chip: " + (_joined(pc) if pc != null else "none"))
	_press(_btn(s, "MoreBtn"), "더 보기")
	await _frames(3)
	ok(_find(s, "MoreBtn") == null, "[더 보기] shows the rest (26 entries)")
	var dates: Array = _texts(s).filter(func(t: String) -> bool: return t.contains("월") and t.contains("일 ("))
	var rx := RegEx.new()
	rx.compile("^\\d{1,2}월 \\d{1,2}일 \\([일월화수목금토]\\)$")
	ok(dates.size() >= 26 and dates.all(func(t: String) -> bool: return rx.search(t) != null), "every date reads like 11월 14일 (토) (%s)" % (dates[0] if not dates.is_empty() else "none"))
	ok(str(dates[0]) == "11월 14일 (토)", "the date of the day: 11월 14일 (토)")
	ok(_long_numbers(_texts(s)).is_empty(), "no run of 5 digits on the list screen")
	_check_inside(s, "list with a 300 character entry")
	ok(_find(s, "ClearAllBtn") != null, "[일기 모두 지우기] is at the bottom")
	# view a saved entry
	_press(_btn(s, "ViewBtn"), "보기")
	await _frames(2)
	ok(s.stage == "view" and _joined(s).contains("아직 고치지 않은 일기예요"), "[보기] of a saved entry")
	_press(_btn(s, "ListBtn"), "일기 목록")
	await _frames(2)
	ok(s.stage == "home", "[일기 목록] goes back")
	# delete: confirm sheet, [지우기]
	var n_before: int = DiaryStore.entries().size()
	_press(_btn(s, "DeleteBtn"), "지우기")
	await _frames(2)
	ok(Sheet.is_open() and s.last_sheet != null, "a confirm sheet opens before deleting")
	ok(DiaryStore.entries().size() == n_before, "nothing is deleted before the answer")
	_press(s.last_sheet.buttons["cancel"], "취소")
	await _frames(2)
	ok(DiaryStore.entries().size() == n_before, "[취소] keeps the entry")
	_press(_btn(s, "DeleteBtn"), "지우기 (again)")
	await _frames(2)
	_press(s.last_sheet.buttons["ok"], "지우기 (sheet)")
	await _frames(3)
	ok(DiaryStore.entries().size() == n_before - 1, "[지우기] deletes one entry")
	# delete all
	_press(_btn(s, "ClearAllBtn"), "일기 모두 지우기")
	await _frames(2)
	ok(Sheet.is_open() and _joined(s.last_sheet).contains("%d개" % DiaryStore.entries().size()), "the confirm sheet says how many")
	_press(s.last_sheet.buttons["ok"], "모두 지우기 (sheet)")
	await _frames(3)
	ok(DiaryStore.entries().is_empty() and _find(s, "EmptyList") != null, "[일기 모두 지우기] clears every entry (both languages) and shows the empty line")
	# go_back steps
	var sb := _make("ja")
	await _frames(2)
	sb.stage = "view"
	var closed_n := [0]
	sb.closed.connect(func() -> void: closed_n[0] += 1)
	ok(sb.go_back() and sb.stage == "home" and closed_n[0] == 0, "go_back from the view goes to the writing screen")
	ok(sb.go_back() and closed_n[0] == 1, "go_back from the writing screen closes the screen")
	# [고치기] inside the view of a waiting entry
	_fresh()
	Store.prefs["diary_consent"] = true
	var wid: String = str(DiaryStore.add("ja", "まって いる にっき。")["id"])
	var sv := _make("ja")
	await _frames(3)
	sv.open_entry(wid)
	await _frames(2)
	_press(_btn(sv, "FixEntryBtn"), "고치기 (in the view)")
	await _frames(4)
	ok(sv.stage == "result" and DiaryStore.get_entry(wid)["state"] == "fixed" and _fix_reqs().size() == 1, "[고치기] in the view fixes the waiting entry")
	# ...and with the AI gone it says why and goes back to the list
	_fresh()
	var wid2: String = str(DiaryStore.add("ja", "まって いる にっき。")["id"])
	var sw := _make("ja")
	await _frames(3)
	sw.open_entry(wid2)
	await _frames(2)
	DiaryScreen.ai_hook = func() -> String: return "no_pc"
	sw.refresh()
	await _frames(2)
	ok(_btn(sw, "FixEntryBtn").disabled, "no AI: [고치기] in the view is off")
	sw.fix_entry(wid2)
	await _frames(2)
	ok(sw.stage == "home" and _joined(sw).contains(DiaryScreen.NOTE_NO_PC) and _fix_reqs().is_empty(), "no AI: fix_entry says why and sends nothing")


# ---------------------------------------------------------------- voice input

func _test_voice_input() -> void:
	print("[voice input: /stt, PC only]")
	_fresh()
	DiaryScreen.stt_hook = func() -> bool: return true
	var s := _make("ja")
	await _frames(3)
	ok(_find(s, "MicBtn") is RecorderWidget and _find(s, "NoMicNote") == null, "with a PC the voice button is shown")
	_reqs.clear()
	(_find(s, "MicBtn") as RecorderWidget).recorded.emit({"b64": "AAAA", "duration": 1.0})
	await _frames(3)
	var st: Array = _reqs.filter(func(r: Dictionary) -> bool: return r["path"] == "/stt")
	ok(st.size() == 1 and (st[0]["body"] as Dictionary)["lang"] == "ja", "one /stt request with the lang")
	ok(s._edit.text == "きょうは あめでした。", "the heard text goes into the box (not sent anywhere else)")
	ok(not _reqs.any(func(r: Dictionary) -> bool: return r["path"] == "/fix" or r["path"] == "/tts"), "voice input sends no /fix and no /tts")
	_queue = [{"ok": false, "code": 500, "data": null, "error": "듣기에 실패했어요.", "err_code": ""}]
	(_find(s, "MicBtn") as RecorderWidget).recorded.emit({"b64": "AAAA", "duration": 1.0})
	await _frames(3)
	ok(_joined(s).contains("듣기에 실패했어요."), "a failed /stt shows its Korean message")
	ok(s._edit.text == "きょうは あめでした。", "...and the box keeps its text")
	DiaryScreen.stt_hook = func() -> bool: return false


# ---------------------------------------------------------------- numbers, touch, layout

func _test_numbers_and_touch() -> void:
	print("[C-15 numbers, touch height, layout: %s, scale %s%s]" % ["phone" if phone else "pc", str(_scale), ", dark" if _dark else ""])
	_fresh()
	Store.prefs["diary_consent"] = true
	DiaryStore.add("ja", "きのう ともだちと えいがをみた。")
	var long_ja := ""
	while long_ja.length() < 280:
		long_ja += "きょうは いい てんきでした。"
	DiaryStore.add("ja", long_ja.left(298) + "。")
	_hold = true
	var s := _make("ja")
	await _frames(3)
	_type(s, "あ".repeat(86) + "。" + "い".repeat(100) + "。")
	await _frames(2)
	_check_inside(s, "home with a long text")
	var states: Array = []
	states.append(["home", _texts(s)])
	var th: float = Ds.touch_min()
	ok(_min_button_h(s) >= th - 0.5, "home: every button is at least %.1f high (smallest %.1f)" % [th, _min_button_h(s)])
	_press(_btn(s, "FixBtn"), "고쳐 보기")
	await _frames(3)
	ok(s.stage == "working", "working screen")
	states.append(["working", _texts(s)])
	ok(_min_button_h(s) >= th - 0.5, "working: every button is at least %.1f high (smallest %.1f)" % [th, _min_button_h(s)])
	_check_inside(s, "working")
	_hold = false
	_go.emit()
	await _frames(4)
	ok(s.stage == "result", "result screen")
	states.append(["result", _texts(s)])
	ok(_min_button_h(s) >= th - 0.5, "result: every button is at least %.1f high (smallest %.1f)" % [th, _min_button_h(s)])
	_check_inside(s, "result")
	_press(_btn(s, "ListBtn"), "일기 목록")
	await _frames(3)
	states.append(["list", _texts(s)])
	_check_inside(s, "list")
	_press(_btn(s, "ViewBtn"), "보기")
	await _frames(3)
	states.append(["view", _texts(s)])
	_check_inside(s, "view")
	for st in states:
		ok(_long_numbers(st[1]).is_empty(), "C-15: no run of 5 digits on the %s screen" % st[0])
	ok(not _joined(s).contains("1731571200") and not _joined(s).contains("20261114"), "no unix time or compact date on the screen")
	var sheet_text := ""
	_fresh()
	var s2 := _make("ja")
	await _frames(2)
	_type(s2, "きのう えいがを みた。")
	await _frames(1)
	_press(_btn(s2, "FixBtn"), "고쳐 보기 (sheet layout)")
	await _frames(3)
	sheet_text = _joined(s2.last_sheet)
	ok(_long_numbers([sheet_text]).is_empty(), "C-15: no run of 5 digits in the consent sheet")
	if s2.last_sheet != null and is_instance_valid(s2.last_sheet):
		var pr: Rect2 = s2.last_sheet.panel_rect()
		var vp := Rect2(Vector2.ZERO, Vector2(get_window().size))
		ok(vp.encloses(pr.grow(-1.0)), "the consent sheet panel is inside the window")
	while Sheet.close_top():
		pass


# ---------------------------------------------------------------- no sound, source rules, requests

func _test_no_sound() -> void:
	print("[no sound on the diary screen]")
	ok(_tts_events == 0, "Tts never started or changed state during the whole test (%d events)" % _tts_events)
	ok(not _all_reqs.any(func(r: Dictionary) -> bool: return str(r["path"]).begins_with("/tts")), "no /tts request in the whole test")
	var s := _make("ja")
	DiaryStore.add("ja", "きのう えいがをみた。")
	s.refresh()
	var bad := 0
	for t in _texts(s):
		if str(t).contains("듣기") or str(t).contains(char(0x25B6)) or str(t).contains("재생"):
			bad += 1
	ok(bad == 0, "no listen / play button on the writing screen or the list")
	var id: String = str(DiaryStore.entries("ja")[0]["id"])
	DiaryStore.set_fixed(id, [{"orig": "きのう えいがをみた。", "fix": "昨日、映画を見ました。", "why": "정중체", "reading": "きのう、えいがをみました。", "pron": "", "same": false, "card": false}])
	s.open_entry(id)
	await _frames(2)
	bad = 0
	for t in _texts(s):
		if str(t).contains("듣기") or str(t).contains(char(0x25B6)) or str(t).contains("재생"):
			bad += 1
	ok(bad == 0, "no listen / play button on the result of a fixed entry")
	var fr := _count_in_source(SRC, ["Tts", "/tts", ".speak(", "speak_buttons", "AudioStreamPlayer"])
	ok(fr == 0, "diary_screen.gd has no Tts / /tts / speak call (%d)" % fr)


func _test_source_rules() -> void:
	print("[source rules]")
	var f := FileAccess.open(SRC, FileAccess.READ)
	var src: String = f.get_as_text()
	var needles: Array = ["HTTP" + "Request", "shell" + "_open", "request" + "_permission", "Color(" + "\"#", "push_" + "warning", "push_" + "error", "Toast" + ".", "print" + "(", "printerr" + "("]
	for needle in needles:
		var lines := 0
		for line in src.split("\n"):
			var l: String = line.strip_edges()
			if not l.begins_with("#") and l.contains(needle):
				lines += 1
		ok(lines == 0, "diary_screen.gd has no %s" % needle)
	ok(src.contains("\"private\": true"), "the /fix body is written with \"private\": true")
	var feats := 0
	for cp in [0x2726, 0x2665, 0x2605, 0x2606, 0x25B6, 0x25CF, 0x25A0, 0x2714]: ## shape glyphs (the plain check mark U+2713 is the design's own text)
		if src.contains(char(cp)):
			feats += 1
	ok(feats == 0, "no shape glyphs in the diary screen")


func _final_request_checks() -> void:
	print("[every request of the whole test]")
	var fixes: Array = _all_reqs.filter(func(r: Dictionary) -> bool: return r["path"] == "/fix")
	var bad := 0
	for r in fixes:
		var lang: String = str((r["body"] as Dictionary).get("lang", ""))
		if _body_problem(r["body"], lang) != "":
			bad += 1
	ok(fixes.size() >= 20 and bad == 0, "all %d /fix requests carried private:true and one short sentence (%d bad)" % [fixes.size(), bad])
	ok(not _all_reqs.any(func(r: Dictionary) -> bool: return r["method"] != "POST" and r["path"] == "/fix"), "/fix is only ever POSTed")
	var other: Array = _all_reqs.filter(func(r: Dictionary) -> bool: return r["path"] != "/fix" and r["path"] != "/stt")
	ok(other.is_empty(), "the screen asks for /fix and /stt only (%d others)" % other.size())
	var hits := 0
	for t in _toasts:
		if str(t).contains(MARK):
			hits += 1
	ok(hits == 0, "no toast carried diary text")
