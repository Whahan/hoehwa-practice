extends Node
## v2.0.1 PWA: 말하기 화면과 폰 채점(PA4)·모델 카드(PA3)의 연결 (docs/v201_design.md 2.6, 5.8 PWA-1 ~ PWA-8).
##   PC   : godot --headless --path godot res://tests/phone_score_wiring_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/phone_score_wiring_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark]
## 마지막 줄: "== phone_score_wiring_test result: N passed, M failed (presses: P) ==" (실패가 있으면 종료 코드 1)
## 서버·네트워크 없음. 폰 채점은 가짜 LocalStt 핸들러(LocalApi.handler_override["stt"])가 하고, 흐름은 실제 버튼의 pressed.emit()
## 으로 간다(출력의 "press: ..." 줄). 코스 말하기·쉐도잉·코스 플레이어 말하기는 SpeakDrill.api_hook 없이 실제 Api -> Route -> LocalApi 길이다.
## 검사기는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다("selfcheck FAIL-as-expected ..." 줄).
## 시험 전용 파일 경로(user://test_pwa_*)만 쓰고 끝에 되돌린다. 엔진 ERROR 줄은 로거로 세어 0 이어야 한다.

const K1_DIR := "res://tests/fixtures/course_builder/k1_mini"
const PROG := "user://test_pwa_progress.json"
const PREFS := "user://test_pwa_prefs.json"
const LOG := "user://test_pwa_studylog.json"
const CS := "user://test_pwa_course.json"
const MODEL_DIR := "user://test_pwa_models/"
const REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const SECTIONS := ["badge", "need_ph", "warm", "model_button", "notes", "flow_course", "flow_shadow", "flow_player", "bad_input", "source"]
## 설계가 정한 글(상수 변이는 코드의 상수를 바꾸므로, 시험은 이 글자와 직접 비교한다)
const T_BADGE := "폰 간이 채점"
const T_BADGE_UNCAL := "폰 간이 채점 · 보정 전"
const T_BTN_GET := "음성 인식 모델 받기 (약 60 MB)"
const T_BTN_AGAIN := "음성 인식 모델 다시 받기"
const T_NOTE_OLD_SHADOW := "지금은 점수를 낼 수 없어요(점수는 PC 연결 시). 따라 말한 뒤 내 목소리와 원어민 소리를 들어 보고 스스로 평가해요."
const T_NOTE_OLD_SONG := "지금은 점수를 낼 수 없어요(점수는 PC 연결 시). 따라 부른 뒤 내 목소리와 원어민 소리를 들어 보고 스스로 평가해요."
const T_NOTE_MODEL_SHADOW := "점수를 보려면 설정 > 음성 인식에서 모델을 받아 주세요(약 60 MB). 지금은 스스로 평가해요."
const T_NOTE_MODEL_SONG := "점수를 보려면 설정 > 음성 인식에서 모델을 받아 주세요(약 60 MB). 지금은 따라 부른 뒤 내 목소리와 원어민 소리를 들어 보고 스스로 평가해요."

## 가짜 LocalStt: 상태 코드("" = 준비됨, "model_missing", "model_corrupt", "engine_missing" ...)는 set_code 로 바꾼다.
const FAKE_STT := """extends RefCounted
static var code: String = "model_missing"
static var warms: int = 0
static var handled: int = 0
static var bodies: Array = []
static func set_code(c: String) -> void:
	code = c
static func reset() -> void:
	warms = 0
	handled = 0
	bodies = []
static func counts() -> Dictionary:
	return {"warms": warms, "handled": handled}
static func last_body() -> Dictionary:
	return bodies[bodies.size() - 1] if bodies.size() > 0 else {}
static func is_available() -> bool:
	return code == ""
static func unavailable_reason() -> Dictionary:
	if code == "":
		return {"err_code": "", "text_ko": ""}
	return {"err_code": code, "text_ko": Route.text_for(code)}
static func unavailable_reason_for(_path, _query, body) -> Dictionary:
	if str(body.get("lang", "en")) != "en":
		return {"err_code": "not_on_phone", "text_ko": Route.text_for("not_on_phone")}
	return unavailable_reason()
static func is_available_for(path, query, body) -> bool:
	return str(unavailable_reason_for(path, query, body).get("err_code", "")) == ""
static func warm() -> void:
	warms += 1
static func handle(_method, _path, _query, body):
	handled += 1
	bodies.append(body.duplicate())
	var t: String = str(body.get("target", "x"))
	return LocalApi.ok({"transcript": t, "units": [{"t": t.split(" ")[0], "ok": true}], "score": 91, "accuracy": 90, "clarity": 88, "fluency": 85, "lang": "en"}, ["score_uncalibrated"])
"""
const NO_WARM_STT := """extends RefCounted
static func is_available() -> bool:
	return false
static func unavailable_reason() -> Dictionary:
	return {"err_code": "model_missing", "text_ko": ""}
static func handle(_method, _path, _query, _body):
	return {"ok": false}
"""

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var reached: Dictionary = {}
var hook_bodies: Array = []
var tts_calls: Array = []
var results: Array = []
var _fake: GDScript = null
var _saved: Dictionary = {}
var _holder: Control = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _screen: Vector2 = Vector2(1280, 800)
var _cap: LogCap = null
var _k1: Dictionary = {}


class LogCap:
	extends Logger
	var lines: Array = []
	var mu := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		lines.append("%s %s:%d %s %s" % [function, file, line, code, rationale])
		mu.unlock()

	func snapshot() -> Array:
		mu.lock()
		var c: Array = lines.duplicate()
		mu.unlock()
		return c


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


## 검사기가 "실패로 판정"해야 하는 입력: 실패로 판정하면 통과로 센다.
func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _until(cond: Callable, max_frames: int = 90) -> bool:
	for i in max_frames:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _yes() -> bool:
	return true


func _no() -> bool:
	return false


func _ready() -> void:
	_cap = LogCap.new()
	OS.add_logger(_cap)
	phone = Platform.is_phone()
	_screen = Vector2(412, 915) if phone else Vector2(1280, 800)
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== phone_score_wiring_test start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_setup()
	_selfcheck()
	await _test_badge()
	await _test_need_ph()
	await _test_warm()
	await _test_model_button()
	await _test_notes()
	await _test_flow_course()
	await _test_flow_shadow()
	await _test_flow_player()
	await _test_bad_input()
	_test_source()
	_teardown()
	for s in SECTIONS:
		ok(reached.has(s), "section '%s' ran to its end" % s)
	ok(presses >= 12, "at least 12 real button presses (%d)" % presses)
	var errs: Array = _cap.snapshot()
	OS.remove_logger(_cap)
	ok(errs.is_empty(), "no engine ERROR line during the run (%d)" % errs.size())
	for l in errs.slice(0, 5):
		print("engine error: ", l)
	print("== phone_score_wiring_test result: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {"prefs": Store.prefs.duplicate(true), "progress": Store.progress.duplicate(true), "progress_path": Store.progress_path,
		"prefs_path": Store.prefs_path, "log_path": StudyLog.path, "cs": CourseStore.path, "base": CourseData.base_dir,
		"api": Api.base_url, "route": Route.mode, "phone_hook": Route.phone_hook, "anim": Sheet.animate, "over": LocalApi.handler_override.duplicate(),
		"models": ModelStore.base_dir}
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	_rm_all()
	Store.progress = Progress.blank()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	StudyLog.reset()
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게
	ModelStore.base_dir = MODEL_DIR
	Tts.fetch_hook = Callable(self, "_tts_hook")
	Sheet.animate = false
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(_screen)
	_fake = GDScript.new()
	_fake.source_code = FAKE_STT
	ok(_fake.reload() == OK, "the fake LocalStt script compiles")
	_k1 = _load_k1()
	ok(not _k1.is_empty(), "k1_mini fixture loaded")


func _teardown() -> void:
	while Sheet.is_open():
		Sheet.close_top()
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	SelfRatePanel.model_store_path = "res://scripts/local/model_store.gd"
	SelfRatePanel.model_card_path = "res://scripts/ui/stt_model_card.gd"
	SpeakDrill.api_hook = Callable()
	CoursePlayer.build_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	_rm_all()
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	CourseFeed.reset()
	CourseStore.reset_memory()
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.prefs_path = _saved["prefs_path"]
	CourseStore.path = _saved["cs"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Api.base_url = _saved["api"]
	Route.mode = _saved["route"]
	Route.phone_hook = _saved["phone_hook"]
	LocalApi.handler_override = _saved["over"]
	Sheet.animate = _saved["anim"]
	ModelStore.base_dir = _saved["models"]


func _rm_all() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _api_hook(method: String, path: String, body: Variant) -> Variant:
	hook_bodies.append({"method": method, "path": path, "body": body})
	if path == "/score":
		return {"transcript": "hello there", "units": [{"t": "hello", "ok": true}], "score": 88, "lang": "en"}
	return {}


## 폰 단독: Route 가 "phone" 모드, 가짜 LocalStt 가 상태 `code` 로 응답한다.
func _phone_world(code: String) -> void:
	Route.phone_hook = Callable(self, "_yes")
	Route.mode = "phone"
	_fake.call("set_code", code)
	LocalApi.handler_override = {"stt": _fake}


## PC 앱: Route 는 늘 "pc"(이 시험에서는 SpeakDrill.api_hook 이 /score 를 대신 받는다).
func _pc_world() -> void:
	Route.phone_hook = Callable(self, "_no")
	Route.mode = "pc"
	LocalApi.handler_override = {}


func _load_k1() -> Dictionary:
	var keys: Dictionary = {"en_weeks.json": ["weeks", "weeks"], "en_lexicon.json": ["words", "words"], "en_patterns.json": ["patterns", "patterns"],
		"en_sentences.json": ["sentences", "sentences"], "en_dialogues.json": ["dialogues", "dialogues"], "en_speak_prompts.json": ["prompts", "speak_prompts"]}
	var data: Dictionary = {}
	for fname in keys.keys():
		var f: FileAccess = FileAccess.open(K1_DIR.path_join(fname), FileAccess.READ)
		if f == null:
			return {}
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary) or not (parsed.get(keys[fname][0]) is Array):
			return {}
		data[keys[fname][1]] = parsed[keys[fname][0]]
	return data


func _speak_exercise() -> Dictionary:
	for w in [1, 2, 4]:
		for d in range(1, 8):
			var r: Dictionary = LessonBuilder.build({"kind": "speak", "w": w, "d": d}, _k1, 3)
			if not bool(r["ok"]):
				continue
			for e in r["exercises"]:
				if String(e.get("type", "")) == "speak" and String(e.get("mode", "")) == "repeat":
					return e
	return {}


# ---------------------------------------------------------------- helpers: find / press

func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)


func _nodes(root: Node) -> Array:
	var out: Array = []
	_walk(root, out)
	return out


func _named(root: Node, n: String) -> Node:
	for x in _nodes(root):
		if x.name == n and not x.is_queued_for_deletion():
			return x
	return null


func _find_text_button(root: Node, t: String) -> Button:
	for x in _nodes(root):
		if x is Button and (x as Button).text == t and (x as Button).is_visible_in_tree():
			return x
	return null


func _has_label(root: Node, text: String) -> bool:
	for x in _nodes(root):
		if x is Label and (x as Label).text == text:
			return true
	return false


func _label_with(root: Node, part: String) -> Label:
	for x in _nodes(root):
		if x is Label and (x as Label).text.contains(part):
			return x
	return null


func _ready_btn(b: Variant) -> bool:
	return b is Button and is_instance_valid(b) and (b as Button).is_visible_in_tree() and not (b as Button).disabled


## 실제 버튼을 누른다: 보이고 눌릴 수 있는지 먼저 확인하고, pressed 를 낸다.
func press(b: Variant, label: String) -> void:
	var good: bool = _ready_btn(b)
	ok(good, "button ready: %s" % label)
	if not good:
		return
	presses += 1
	print("press: ", label)
	(b as Button).pressed.emit()


func _fresh_holder() -> Control:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = _screen
	_holder.clip_contents = true
	add_child(_holder)
	return _holder


func _score_res(extra: Dictionary) -> Dictionary:
	var d: Dictionary = {"score": 88, "accuracy": 88, "clarity": 80, "fluency": 70, "transcript": "hello there",
		"units": [{"t": "hello", "ok": true}, {"t": "there", "ok": true}], "lang": "en"}
	d.merge(extra, true)
	return d


func _badge_text(panel: Node) -> String:
	var n: Node = panel.find_child("PhoneScoreBadge", true, false)
	return (n as Label).text if n is Label else "<none>"


func _badge_ok(panel: Node, want: String) -> bool:
	return _badge_text(panel) == want


func _selfcheck() -> void:
	var phone_panel: Node = ScorePanel.build(_score_res({"via": "phone", "degraded": []}), "en")
	var pc_panel: Node = ScorePanel.build(_score_res({"via": "pc"}), "en")
	fails(not _badge_ok(phone_panel, "폰 채점"), "the badge checker rejects a wrong badge text")
	fails(not _badge_ok(pc_panel, T_BADGE), "the badge checker rejects a badge text on a PC result")
	fails(not _badge_ok(phone_panel, "<none>"), "the badge checker does not call a phone result badge-less")
	ok(_badge_ok(phone_panel, T_BADGE) and _badge_ok(pc_panel, "<none>"), "the badge checker accepts the right answers")
	phone_panel.free()
	pc_panel.free()


# ---------------------------------------------------------------- PWA-3: ScorePanel badge

func _test_badge() -> void:
	print("[ScorePanel: the badge only for via == 'phone']")
	var cases: Array = [
		["phone, degraded []", {"via": "phone", "degraded": []}, T_BADGE],
		["phone, no degraded", {"via": "phone"}, T_BADGE],
		["phone, score_uncalibrated", {"via": "phone", "degraded": ["score_uncalibrated"]}, T_BADGE_UNCAL],
		["phone, uncalibrated + tiny", {"via": "phone", "degraded": ["score_uncalibrated", "stt_tiny_model"]}, T_BADGE_UNCAL],
		["phone, only tiny", {"via": "phone", "degraded": ["stt_tiny_model"]}, T_BADGE],
		["phone, degraded is a string", {"via": "phone", "degraded": "score_uncalibrated"}, T_BADGE],
		["phone, degraded is a number", {"via": "phone", "degraded": 5}, T_BADGE],
		["phone, degraded is a dictionary", {"via": "phone", "degraded": {"score_uncalibrated": true}}, T_BADGE],
		["phone, degraded holds a number", {"via": "phone", "degraded": [5, null]}, T_BADGE],
		["pc", {"via": "pc", "degraded": ["score_uncalibrated"]}, "<none>"],
		["no via", {"degraded": ["score_uncalibrated"]}, "<none>"],
		["via is a number", {"via": 5}, "<none>"],
		["via is a float", {"via": 1.5, "degraded": ["score_uncalibrated"]}, "<none>"],
		["via is an array", {"via": ["phone"]}, "<none>"],
		["via is true", {"via": true}, "<none>"],
		["via is a dictionary", {"via": {"v": "phone"}}, "<none>"],
		["via is null", {"via": null}, "<none>"],
		["via is 'Phone'", {"via": "Phone"}, "<none>"],
		["via is 'phone '", {"via": "phone "}, "<none>"],
		["via is empty", {"via": ""}, "<none>"],
	]
	for c in cases:
		var panel: Node = ScorePanel.build(_score_res(c[1]), "en")
		eq(_badge_text(panel), str(c[2]), "badge: %s" % c[0])
		eq(ScorePanel.phone_badge_text(_score_res(c[1])), "" if str(c[2]) == "<none>" else str(c[2]), "badge text function: %s" % c[0])
		panel.free()
	# 배지는 점수 글자 옆 칸에, 점수 숫자는 그대로
	var p2: Node = ScorePanel.build(_score_res({"via": "phone"}), "en")
	var b: Node = p2.find_child("PhoneScoreBadge", true, false)
	ok(b is Label and (b as Label).get_parent() != null and _has_label(p2, "발음 점수"), "the badge sits in the column beside the score, next to the '발음 점수' caption")
	ok(_has_label(p2, "88") or _label_with(p2, "88") != null, "the score number is still shown")
	p2.free()
	reached["badge"] = true


# ---------------------------------------------------------------- PWA-4: need_ph

func _test_need_ph() -> void:
	print("[need_ph: only source 'drill' with lang 'en']")
	_pc_world()
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	var cases: Array = [
		["en", "drill", true], ["en", "shadow", false], ["en", "course", false], ["en", "lesson", false], ["en", "review", false],
		["en", "song", false], ["ja", "drill", false], ["ja", "shadow", false], ["ja", "course", false],
	]
	for c in cases:
		var d := SpeakDrill.new(str(c[0]), str(c[1]))
		add_child(d)
		await _frames(1)
		d.set_target("Hello there", "", "")
		hook_bodies.clear()
		d._on_recorded(REC)
		await _until(func() -> bool: return d.status != "scoring")
		var score_reqs: Array = hook_bodies.filter(func(r: Dictionary) -> bool: return r["path"] == "/score")
		var tag := "%s/%s" % [c[0], c[1]]
		eq(score_reqs.size(), 1, "%s: one /score request" % tag)
		if score_reqs.size() == 1:
			var body: Dictionary = score_reqs[0]["body"]
			if bool(c[2]):
				ok(body.has("need_ph") and body["need_ph"] is bool and bool(body["need_ph"]), "%s: need_ph is true" % tag)
			else:
				ok(not body.has("need_ph"), "%s: no need_ph key" % tag)
			var keys: Array = body.keys()
			keys.sort()
			eq(keys, ["audio_b64", "lang", "need_ph", "reading", "target"] if bool(c[2]) else ["audio_b64", "lang", "reading", "target"], "%s: the other body keys are the old ones" % tag)
			eq(str(body["target"]), "Hello there", "%s: target unchanged" % tag)
			var pol: Dictionary = Route.policy_for("POST", "/score", body)
			eq(str(pol.get("prefer", "")), "pc" if bool(c[2]) else "phone", "%s: Route prefers %s for this body" % [tag, "the PC" if bool(c[2]) else "the phone"])
		d.queue_free()
	SpeakDrill.api_hook = Callable()
	reached["need_ph"] = true


# ---------------------------------------------------------------- PA4 contract: warm()

func _test_warm() -> void:
	print("[SpeakDrill warms the speech engine on the phone for English]")
	_phone_world("")
	_fake.call("reset")
	var d := SpeakDrill.new("en", "shadow")
	add_child(d)
	await _frames(2)
	eq(int(_fake.call("counts")["warms"]), 1, "phone + en: warm() called once when the drill is shown")
	d.queue_free()
	var d2 := SpeakDrill.new("ja", "shadow")
	add_child(d2)
	await _frames(2)
	eq(int(_fake.call("counts")["warms"]), 1, "phone + ja: warm() not called")
	d2.queue_free()
	_pc_world()
	LocalApi.handler_override = {"stt": _fake}
	var d3 := SpeakDrill.new("en", "course")
	add_child(d3)
	await _frames(2)
	eq(int(_fake.call("counts")["warms"]), 1, "PC app + en: warm() not called")
	d3.queue_free()
	_phone_world("model_missing")
	var d4 := SpeakDrill.new("en", "course")
	add_child(d4)
	await _frames(2)
	eq(int(_fake.call("counts")["warms"]), 2, "phone + en + no model: the handler decides (warm() is still called once)")
	d4.queue_free()
	# 핸들러가 없거나 warm 이 없어도 크래시 없음
	LocalApi.handler_override = {"stt": null}
	var d5 := SpeakDrill.new("en", "shadow")
	add_child(d5)
	await _frames(2)
	ok(is_instance_valid(d5) and d5.is_inside_tree(), "no stt handler: the drill still opens")
	d5.queue_free()
	var nw := GDScript.new()
	nw.source_code = NO_WARM_STT
	ok(nw.reload() == OK, "the handler without warm compiles")
	LocalApi.handler_override = {"stt": nw}
	var d6 := SpeakDrill.new("en", "shadow")
	add_child(d6)
	await _frames(2)
	ok(is_instance_valid(d6) and d6.is_inside_tree(), "a handler without warm(): the drill still opens")
	d6.queue_free()
	reached["warm"] = true


# ---------------------------------------------------------------- PWA-2/7: the model button on the card

func _mk_panel(l: String) -> SelfRatePanel:
	var h: Control = _fresh_holder()
	var p := SelfRatePanel.new(l, "Hello there", REC, Pal.EN)
	h.add_child(p)
	return p


func _test_model_button() -> void:
	print("[SelfRatePanel: [음성 인식 모델 받기] only on the phone, English, model missing or corrupt]")
	_phone_world("model_missing")
	var p: SelfRatePanel = _mk_panel("en")
	await _frames(3)
	var b: Node = _named(p, "SelfRateModelBtn")
	ok(b is Button, "model missing: the button SelfRateModelBtn exists inside the card")
	eq((b as Button).text if b is Button else "", T_BTN_GET, "model missing: the button says '음성 인식 모델 받기 (약 60 MB)'")
	eq((b as Button).text if b is Button else "", "%s (%s)" % ["음성 인식 모델 받기", ModelStore.mb_label(int(ModelStore.model(ModelStore.active_id())["bytes"]))], "the size in the button is ModelStore.mb_label of the model bytes")
	ok(b is Button and (b as Button).size.y >= 44.0 and (b as Button).size.x <= p.size.x + 1.0, "the button is at least 44 high and fits the width")
	ok(_has_label(p, Route.text_for("model_missing")), "model missing: the card text is the Route text (settings > 음성 인식)")
	ok(_find_text_button(p, "잘했어요") != null and _find_text_button(p, "다시") != null, "[잘했어요] and [다시] are still there")
	ok(b != null and b.get_parent() != null and b.get_parent().get_parent() is CardBox or b == null, "the button lives inside the card body")
	_phone_world("model_corrupt")
	p = _mk_panel("en")
	await _frames(3)
	b = _named(p, "SelfRateModelBtn")
	eq((b as Button).text if b is Button else "", T_BTN_AGAIN, "model corrupt: the button says '음성 인식 모델 다시 받기'")
	ok(_has_label(p, Route.text_for("model_corrupt")), "model corrupt: the card text is the Route corrupt text")
	for code in ["engine_missing", "engine_error", "needs_pc", "not_connected", "not_on_phone", "pack_missing", ""]:
		_phone_world(code)
		p = _mk_panel("en")
		await _frames(2)
		ok(_named(p, "SelfRateModelBtn") == null, "reason '%s': no model button" % code)
	_phone_world("model_missing")
	p = _mk_panel("ja")
	await _frames(2)
	ok(_named(p, "SelfRateModelBtn") == null, "Japanese: no model button")
	Route.phone_hook = Callable(self, "_no")
	p = _mk_panel("en")
	await _frames(2)
	ok(_named(p, "SelfRateModelBtn") == null, "PC app: no model button")
	# PWA-7: 모델 도우미 스크립트가 없으면 버튼 없음, 크래시 없음
	_phone_world("model_missing")
	SelfRatePanel.model_store_path = "res://scripts/local/__not_here__.gd"
	p = _mk_panel("en")
	await _frames(2)
	ok(is_instance_valid(p) and p.is_inside_tree() and _named(p, "SelfRateModelBtn") == null, "ModelStore script missing: no button, no crash")
	ok(_find_text_button(p, "잘했어요") != null, "ModelStore script missing: the self rating still works")
	SelfRatePanel.model_store_path = "res://scripts/local/model_store.gd"
	SelfRatePanel.model_card_path = "res://scripts/ui/__not_here__.gd"
	p = _mk_panel("en")
	await _frames(2)
	ok(is_instance_valid(p) and _named(p, "SelfRateModelBtn") == null, "model card script missing: no button, no crash")
	SelfRatePanel.model_card_path = "res://scripts/ui/stt_model_card.gd"
	SelfRatePanel.model_store_path = "res://tests/phone_score_wiring_test.gd" # 스크립트이지만 ModelStore 가 아님: 함수가 없다
	p = _mk_panel("en")
	await _frames(2)
	ok(is_instance_valid(p) and _named(p, "SelfRateModelBtn") == null, "a script without the ModelStore functions: no button, no crash")
	SelfRatePanel.model_store_path = "res://scripts/local/model_store.gd"
	# 눌러 보기(직접 만든 패널): 시트가 열린다
	_phone_world("model_missing")
	p = _mk_panel("en")
	await _frames(3)
	press(_named(p, "SelfRateModelBtn"), "SelfRateModelBtn (panel)")
	await _frames(3)
	ok(Sheet.is_open() and _sheet_cards() == 1, "the button opens SttModelCard.open_sheet (one sheet with one model card)")
	_close_sheet()
	await _frames(2)
	ok(not Sheet.is_open(), "[닫기] closes the sheet")
	reached["model_button"] = true


func _sheet_cards() -> int:
	var n := 0
	for x in _nodes(get_tree().root):
		if x is SttModelCard and not x.is_queued_for_deletion():
			n += 1
	return n


func _close_sheet() -> void:
	press(_find_text_button(get_tree().root, "닫기"), "닫기 (model sheet)")


# ---------------------------------------------------------------- PWA-5: reason texts

func _test_notes() -> void:
	print("[shadowing and singing notes by reason]")
	var cases: Array = [["model_missing", true], ["engine_missing", false], ["needs_pc", false], ["not_connected", false], ["model_corrupt", false], ["engine_error", false]]
	for c in cases:
		_phone_world(str(c[0]))
		eq(ShadowScreen.self_note("en"), T_NOTE_MODEL_SHADOW if bool(c[1]) else T_NOTE_OLD_SHADOW, "shadow note for '%s'" % c[0])
		eq(SongSingTab.self_note("en"), T_NOTE_MODEL_SONG if bool(c[1]) else T_NOTE_OLD_SONG, "song note for '%s'" % c[0])
	_phone_world("model_missing")
	eq(ShadowScreen.self_note("ja"), T_NOTE_OLD_SHADOW, "Japanese shadow note is the old one even when the model is missing")
	eq(SongSingTab.self_note("ja"), T_NOTE_OLD_SONG, "Japanese song note is the old one even when the model is missing")
	eq(SongSingTab.SELF_NOTE, T_NOTE_OLD_SONG, "the old SELF_NOTE constant is unchanged")
	# 실제 화면의 글
	var h: Control = _fresh_holder()
	var sc := ShadowScreen.new()
	h.add_child(sc)
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.open("en")
	await _frames(3)
	ok(_has_label(sc, T_NOTE_MODEL_SHADOW) and not _has_label(sc, T_NOTE_OLD_SHADOW), "shadow start screen (model missing): the new note, not the old one")
	_phone_world("engine_missing")
	sc.open("en")
	await _frames(3)
	ok(_has_label(sc, T_NOTE_OLD_SHADOW) and not _has_label(sc, T_NOTE_MODEL_SHADOW), "shadow start screen (engine missing): the old note")
	_phone_world("model_missing")
	sc.open("ja")
	await _frames(3)
	ok(_has_label(sc, T_NOTE_OLD_SHADOW) and not _has_label(sc, T_NOTE_MODEL_SHADOW), "shadow start screen (Japanese): the old note")
	_phone_world("")
	sc.open("en")
	await _frames(3)
	ok(not _has_label(sc, T_NOTE_OLD_SHADOW) and not _has_label(sc, T_NOTE_MODEL_SHADOW), "shadow start screen (model ready): no note")
	for pair in [["model_missing", "en", T_NOTE_MODEL_SONG], ["engine_missing", "en", T_NOTE_OLD_SONG], ["model_missing", "ja", T_NOTE_OLD_SONG]]:
		_phone_world(str(pair[0]))
		var h2: Control = _fresh_holder()
		var tab := SongSingTab.new()
		h2.add_child(tab)
		tab.setup({"lang": str(pair[1]), "lines": [{"text": "Hello world", "ko": "", "reading": "ハロー", "pron": ""}]}, {"lang": str(pair[1])})
		await _frames(3)
		ok(_has_label(tab, str(pair[2])), "song tab (%s, %s): the expected note" % [pair[0], pair[1]])
		var other: String = T_NOTE_OLD_SONG if str(pair[2]) == T_NOTE_MODEL_SONG else T_NOTE_MODEL_SONG
		ok(not _has_label(tab, other), "song tab (%s, %s): not the other note" % [pair[0], pair[1]])
	reached["notes"] = true


# ---------------------------------------------------------------- PWA-2: real button flows (Api -> Route -> LocalApi)

## 모델 없음 -> 자가 평가 + 버튼 -> 시트 열기·닫기 -> 모델 준비 -> [다시] -> 다시 녹음 -> 폰 채점 -> 점수 화면 + 배지.
## `record`: Callable() 녹음을 시작한다, `wait_scored`: Callable() -> bool 점수 화면이 되면 true, `root`: 화면 뿌리.
func _flow_check(tag: String, root: Node, record: Callable, scored_ok: Callable, target_of: Callable) -> void:
	_phone_world("model_missing")
	_fake.call("reset")
	var served0: int = LocalApi.served_count
	var sent0: int = Api.sent_count
	record.call()
	await _until(func() -> bool: return _find_text_button(root, "잘했어요") != null)
	ok(_find_text_button(root, "잘했어요") != null, "%s: no model -> the self rating widget" % tag)
	var mb: Node = _named(root, "SelfRateModelBtn")
	ok(mb is Button and (mb as Button).text == T_BTN_GET, "%s: the widget carries [음성 인식 모델 받기 (약 60 MB)]" % tag)
	eq(LocalApi.served_count, served0, "%s: nothing was served by the phone yet" % tag)
	press(mb, "SelfRateModelBtn (%s)" % tag)
	await _frames(3)
	ok(Sheet.is_open() and _sheet_cards() == 1, "%s: the button opened the model card sheet" % tag)
	_close_sheet()
	await _frames(2)
	ok(not Sheet.is_open(), "%s: the sheet closed" % tag)
	# 모델이 준비됨(가짜 상태): 같은 화면에서 [다시] 눌러 다시 녹음한다
	_fake.call("set_code", "")
	ok(Route.decide("POST", "/score", {"lang": "en"}) == "phone", "%s: the score now goes to the phone" % tag)
	press(_find_text_button(root, "다시"), "다시 (%s)" % tag)
	await _frames(2)
	record.call()
	var got: bool = await _until(func() -> bool: return bool(scored_ok.call()))
	ok(got, "%s: the second recording reaches the score screen" % tag)
	eq(LocalApi.served_count, served0 + 1, "%s: LocalApi served exactly one request (+1)" % tag)
	eq(Api.sent_count, sent0, "%s: Api.sent_count unchanged (nothing went to the PC)" % tag)
	eq(int(_fake.call("counts")["handled"]), 1, "%s: the phone handler scored once" % tag)
	var body: Dictionary = _fake.call("last_body")
	eq(str(body.get("target", "")), str(target_of.call()), "%s: the phone scored the right sentence" % tag)
	ok(not body.has("need_ph"), "%s: no need_ph in this source" % tag)
	var bt: Node = _named(root, "PhoneScoreBadge")
	ok(bt is Label and (bt as Label).text == T_BADGE_UNCAL, "%s: the score screen shows '폰 간이 채점 · 보정 전'" % tag)
	ok(_named(root, "SelfRateModelBtn") == null, "%s: the model button is gone from the score screen" % tag)


func _test_flow_course() -> void:
	print("[flow: CourseExerciseView speak step]")
	var e: Dictionary = _speak_exercise()
	ok(not e.is_empty(), "a speak/repeat exercise is built from k1_mini")
	results = []
	var h: Control = _fresh_holder()
	var v := CourseExerciseView.new()
	h.add_child(v)
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.answered.connect(func(r: Dictionary) -> void: results.append(r))
	_phone_world("model_missing")
	v.show_exercise(e, {})
	await _frames(3)
	var target: String = String(e["target"])
	await _flow_check("course", v,
		func() -> void:
			print("record: recorder.recorded (microphone replaced by REC)")
			v.drill.recorder.recorded.emit(REC),
		func() -> bool: return v.state == "answered",
		func() -> String: return target)
	ok(results.size() == 1 and bool(results[0]["ok"]) and not bool(results[0]["self_rated"]), "course: matching transcript -> right, not self-rated")
	press(_named(v, "NextBtn"), "NextBtn (course)")
	await _frames(2)
	reached["flow_course"] = true


func _test_flow_shadow() -> void:
	print("[flow: ShadowScreen run]")
	var h: Control = _fresh_holder()
	var sc := ShadowScreen.new()
	h.add_child(sc)
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_phone_world("model_missing")
	sc.open("en")
	await _frames(2)
	sc._begin_run([{"id": 1, "text": "Can I have a menu?", "ko": "메뉴 주세요", "reading": "", "url": ""}], "")
	await _frames(3)
	ok(sc.stage == "run" and sc.drill != null, "shadow: a run is open with a drill")
	await _flow_check("shadow", sc,
		func() -> void:
			print("record: drill._on_recorded (microphone replaced by REC)")
			sc.drill._on_recorded(REC),
		func() -> bool: return sc.drill.status == "ok",
		func() -> String: return "Can I have a menu?")
	ok(int((sc.results[0] as Dictionary)["tries"]) == 1, "shadow: the phone score counts as one try")
	reached["flow_shadow"] = true


func _test_flow_player() -> void:
	print("[flow: CoursePlayer speaking step]")
	Store.progress = Progress.blank()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	StudyLog.reset()
	CourseStore.reset_memory()
	CourseStore.set_mode("course")
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()
	CoursePlayer.build_hook = Callable()
	_phone_world("model_missing")
	var h: Control = _fresh_holder()
	var p: CoursePlayer = CoursePlayer.open(h, {"kind": "speak", "w": 2, "d": 2, "block": "speak", "seed": 5})
	await _frames(3)
	ok(p.state == "run" and p.view != null and p.view.drill != null, "player: the speaking stage is running")
	var e1: Dictionary = p.view.ex
	var t1: String = String(e1["target"]) if String(e1["mode"]) == "repeat" else String((e1["accept"] as Array)[0])
	await _flow_check("player", p,
		func() -> void:
			print("record: recorder.recorded (microphone replaced by REC)")
			p.view.drill.recorder.recorded.emit(REC),
		func() -> bool: return p.view.state == "answered",
		func() -> String: return t1)
	ok(bool(p.view.result["ok"]) and not bool(p.view.result["self_rated"]), "player: right and not self-rated")
	press(_named(p, "NextBtn"), "NextBtn (player)")
	await _frames(2)
	p.queue_free()
	reached["flow_player"] = true


# ---------------------------------------------------------------- PWA-7: wrong input

func _test_bad_input() -> void:
	print("[wrong input: no crash]")
	var weird: Array = [
		{"via": 5, "degraded": "x"}, {"via": "phone", "degraded": 7}, {"via": null, "degraded": null}, {"via": [], "degraded": {}},
		{"score": "high", "via": "phone"}, {"units": "x", "via": "phone", "degraded": ["score_uncalibrated"]}, {},
	]
	for w in weird:
		var panel: Node = ScorePanel.build(w, "en")
		ok(panel != null and panel is VBoxContainer, "ScorePanel.build survives %s" % str(w))
		panel.free()
	# 폰이 아닌데 모델 버튼 이유를 물어도, 일본어여도 빈 글자
	_pc_world()
	eq(SelfRatePanel.model_button_reason("en"), "", "PC app: no button reason")
	eq(SelfRatePanel.none_reason("en"), "", "PC app: no note reason")
	_phone_world("model_missing")
	eq(SelfRatePanel.model_button_reason("ja"), "", "Japanese: no button reason")
	eq(SelfRatePanel.model_button_reason("en"), "model_missing", "phone + en + model missing: the button reason")
	eq(SelfRatePanel.model_button_reason(""), "model_missing", "an empty language is not Japanese: the button reason")
	eq(SelfRatePanel.none_reason("ja"), "", "Japanese: no note reason")
	eq(SelfRatePanel.model_button_text("model_missing"), T_BTN_GET, "model_button_text for a missing model")
	eq(SelfRatePanel.model_button_text("model_corrupt"), T_BTN_AGAIN, "model_button_text for a corrupt model")
	SelfRatePanel.model_store_path = ""
	eq(SelfRatePanel.model_button_text("model_missing"), "", "an empty ModelStore path gives no text")
	SelfRatePanel.model_store_path = "res://scripts/local/model_store.gd"
	reached["bad_input"] = true


# ---------------------------------------------------------------- PWA-6: public signatures

func _test_source() -> void:
	print("[source: SpeakDrill public surface unchanged, no forbidden text]")
	for m in ["request", "cancel_call", "error_message", "build_shell", "new_footer_row", "hide_footer", "touch_button", "fit_touch", "notice", "is_valid_score", "bad_phonemes"]:
		ok((SpeakDrill as GDScript).has_method(m), "SpeakDrill.%s (static) still exists" % m)
	var d := SpeakDrill.new()
	for m in ["make_recorder", "set_target", "set_score_target", "is_scoring", "listen", "stop_all", "retry_score", "apply_score"]:
		ok(d.has_method(m), "SpeakDrill.%s still exists" % m)
	ok(d.has_signal("scored") and d.has_signal("silent_result") and d.has_signal("status_changed"), "SpeakDrill signals are unchanged")
	d.free()
	var src: String = FileAccess.get_file_as_string("res://scripts/practice/speak_drill.gd")
	ok(src.contains("func _warm_stt()") and src.contains('body["need_ph"] = true'), "speak_drill.gd holds the new private warm function and the need_ph line")
	reached["source"] = true
