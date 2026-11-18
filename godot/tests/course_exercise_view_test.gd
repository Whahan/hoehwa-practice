extends Node
## v2.0 E4a: CourseExerciseView(코스 문제 화면) 시험. 서버 없이. 문제는 LessonBuilder.build 가 k1_mini 데이터로 실제로 만든 것을 쓴다.
##   PC   : godot --headless --path godot res://tests/course_exercise_view_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/course_exercise_view_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark] [--shots=<폴더>]   (--shots 는 창이 있는 실행에서만 PNG 가 저장된다: 헤드리스는 그림이 없다)
## 마지막 줄: "== course_exercise_view: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 흐름은 전부 실제 버튼의 pressed.emit() 으로 간다(출력의 "press: ..." 줄). 입력칸은 글을 넣고 text_changed 를 낸 뒤 [확인] 버튼을 누른다.
## 말하기는 녹음 부품의 recorded 신호(마이크 대신)로 시작하고 SpeakDrill.api_hook 이 /score 를 가짜로 답한다. 폰은 자가 평가 버튼을 누른다.
## 검사기(layout / 숫자 / 소스 검사)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다 ("selfcheck FAIL-as-expected ..." 줄).
## 시험 전용 파일 경로(user://test_e4a_*)만 쓰고 끝에 되돌린다. 소리는 Tts.fetch_hook 이 가로채고 주소는 닫힌 포트(9)다.

const K1_DIR := "res://tests/fixtures/course_builder/k1_mini"
const VIEW_SRC := "res://scripts/practice/course_exercise_view.gd"
const TEST_PROGRESS := "user://test_e4a_progress.json"
const TEST_LOG := "user://test_e4a_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const KEYBOARD_H := 300.0
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const ALL_TYPES := ["teach_word", "teach_pattern", "recognize", "recall", "build", "listen", "speak", "dialogue_script"]

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var tts_calls: Array = []
var requests: Array = []
var score_reply: Variant = {}
var results: Array = []
var next_n: int = 0
var pool: Dictionary = {} ## "type/mode" -> [문제, ...] (LessonBuilder 가 만든 것)
var data_raw: Dictionary = {}
var data_script: Dictionary = {} ## 4주 ladder.script = true (역할 대화를 만들려고)
var _saved := {}
var _holder: Control = null
var _view: CourseExerciseView = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _screen: Vector2 = PC_SCREEN
var _shots_dir: String = ""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


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


func _ready() -> void:
	phone = Platform.is_phone()
	_screen = PHONE_SCREEN if phone else PC_SCREEN
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--shots="):
			_shots_dir = a.substr(8)
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== course_exercise_view start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_setup()
	_selfcheck()
	_gather()
	await _test_pool_and_types()
	await _test_teach()
	await _test_choice()
	await _test_typed()
	await _test_near()
	await _test_normalization()
	await _test_build()
	await _test_sound()
	await _test_speak_pc()
	if phone:
		await _test_speak_self_rate()
	await _test_month_speak()
	await _test_dialogue()
	await _test_full_unit()
	await _test_invalid()
	await _test_layout()
	await _test_keyboard()
	await _test_numbers()
	await _test_source()
	_teardown()
	print("== course_exercise_view: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true),
		"progress": Store.progress.duplicate(true),
		"progress_path": Store.progress_path,
		"log_path": StudyLog.path,
		"base": Api.base_url,
		"route": Route.mode,
	}
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("hide_prosody")
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(_screen)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	SpeakDrill.api_hook = Callable()
	Tts.stop()
	PhoneLayout.test_keyboard_height = -1.0
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp"]:
		_rm(p)
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	Api.base_url = _saved["base"]
	Route.mode = _saved["route"]
	Store.prefs = _saved["prefs"]


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _api_hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	if path == "/score":
		return score_reply
	return {}


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _make_view() -> CourseExerciseView:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = _screen
	_holder.clip_contents = true
	add_child(_holder)
	_view = CourseExerciseView.new()
	_holder.add_child(_view)
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	results = []
	next_n = 0
	_view.answered.connect(func(r: Dictionary) -> void: results.append(r))
	_view.next_requested.connect(func() -> void: next_n += 1)
	return _view


func _show(ex: Variant, ctx: Dictionary = {}) -> CourseExerciseView:
	var v: CourseExerciseView = _make_view()
	v.show_exercise(ex, ctx)
	await _frames(3)
	return v


func _shot(shot_name: String) -> void:
	if _shots_dir == "":
		return
	await _frames(3)
	var img: Image = get_viewport().get_texture().get_image() if get_viewport().get_texture() != null else null
	if img == null or img.is_empty():
		print("  (no image for shot %s: headless?)" % shot_name)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var path := "%s/%s_%s_f%d.png" % [_shots_dir, shot_name, _scheme, roundi(Ds.font_scale * 100.0)]
	print("  shot ", path, " err=", img.save_png(path))


# ---------------------------------------------------------------- 실제 빌더 출력

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


func _key_of(e: Dictionary) -> String:
	return "%s/%s" % [e.get("type", ""), e.get("mode", "")]


func _gather() -> void:
	data_raw = _load_k1()
	ok(not data_raw.is_empty() and data_raw["words"].size() == 23, "k1_mini fixture loaded (23 words)")
	data_script = data_raw.duplicate(true)
	for wk in data_script["weeks"]:
		if int(wk["w"]) == 4:
			wk["ladder"]["script"] = true
	var n_units: int = 0
	for src in [data_raw, data_script]:
		for w in [1, 2, 4]:
			for d in range(1, 8):
				for kind in ["new", "listen", "speak", "check", "month", "recap"]:
					for sd in [3, 11]:
						var r: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": d}, src, sd)
						if not bool(r["ok"]):
							continue
						n_units += 1
						for e in r["exercises"]:
							var k: String = _key_of(e)
							if not pool.has(k):
								pool[k] = []
							if (pool[k] as Array).size() < 6:
								(pool[k] as Array).append(e)
	print("  gathered %d units, %d exercise kinds" % [n_units, pool.size()])


func _first(key: String) -> Dictionary:
	if pool.has(key) and not (pool[key] as Array).is_empty():
		return (pool[key] as Array)[0]
	return {}


func _all(key: String) -> Array:
	return pool.get(key, [])


# ---------------------------------------------------------------- 도우미: 노드 찾기·누르기·훑기

func _node(n: String) -> Node:
	return _view.find_child(n, true, false) if _view != null else null


func _button_named(n: String) -> Button:
	var b: Node = _node(n)
	return b as Button if b is Button else null


## 실제 버튼을 누른다: 보이고 눌릴 수 있는지 먼저 확인하고, pressed 를 낸다.
func press(b: Variant, label: String) -> void:
	var good: bool = b is Button and is_instance_valid(b) and (b as Button).is_visible_in_tree() and not (b as Button).disabled
	ok(good, "button ready: %s" % label)
	if not good:
		return
	presses += 1
	print("press: ", label)
	(b as Button).pressed.emit()


func _texts(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label or c is Button:
			out.append(str(c.text))
		elif c is RichTextLabel:
			out.append(str(c.text))
		elif c is LineEdit:
			out.append(str(c.placeholder_text))
		_texts(c, out)


func _find_text_button(root: Node, t: String) -> Button:
	for c in root.get_children():
		if c is Button and str(c.text) == t:
			return c
		var f: Button = _find_text_button(c, t)
		if f != null:
			return f
	return null


func _count_meta(n: Node, key: String) -> int:
	var c: int = 1 if n.has_meta(key) else 0
	for ch in n.get_children():
		c += _count_meta(ch, key)
	return c


func _has_text(root: Node, needle: String) -> bool:
	var all: Array = []
	_texts(root, all)
	for t in all:
		if str(t).contains(needle):
			return true
	return false


func _buttons(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Button:
			out.append(c)
		_buttons(c, out)


func _wait_state(v: CourseExerciseView, want: String, frames: int = 40) -> void:
	for i in frames:
		if v.state == want:
			return
		await get_tree().process_frame


# ---------------------------------------------------------------- 검사기 (일부러 틀린 입력도 본다)

## 화면 글 전체에서 5자리 이상 연속 숫자가 있는가(C-15).
func has_big_number(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	for t in texts:
		if rx.search(str(t)) != null:
			return true
	return false


## 배치 검사: 보이는 Label/Button 이 화면 가로 안에 있고, 눌리는 Button 높이가 min_h 이상이고, 글 최소 폭이 화면을 넘지 않는다.
## 돌려주는 값: {rect, small, wide} 문제 개수.
func scan_layout(root: Node, bounds: Rect2, min_h: float) -> Dictionary:
	var out := {"rect": 0, "small": 0, "wide": 0}
	_scan(root, bounds, min_h, out)
	return out


func _scan(n: Node, bounds: Rect2, min_h: float, out: Dictionary) -> void:
	for c in n.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			var ctl: Control = c
			if c is Label or c is Button or c is LineEdit:
				var r: Rect2 = ctl.get_global_rect()
				if r.position.x < bounds.position.x - 0.5 or r.end.x > bounds.end.x + 0.5:
					out["rect"] += 1
				if ctl.get_combined_minimum_size().x > bounds.size.x + 0.5:
					out["wide"] += 1
			if c is Button and (c as Button).size.y < min_h - 0.5:
				out["small"] += 1
		_scan(c, bounds, min_h, out)


func min_touch() -> float:
	return maxf(44.0, Ds.touch_min() if phone else 0.0)


func _selfcheck() -> void:
	ok(not has_big_number(["12분 30초", "3 / 8 단계", "1234"]), "selfcheck: has_big_number accepts ordinary numbers (4 digits)")
	fails(has_big_number(["걸린 시간 12345"]), "12345 on screen is found by has_big_number")
	fails(has_big_number(["x", "ID 987654321"]), "a nine digit number is found")
	# 가짜 화면: 작은 버튼, 너무 넓은 글, 바깥으로 나간 상자
	var fake := Control.new()
	fake.size = Vector2(412, 600)
	add_child(fake)
	var vb := VBoxContainer.new()
	fake.add_child(vb)
	var tiny := Button.new()
	tiny.text = "tiny"
	tiny.custom_minimum_size = Vector2(80, 30)
	vb.add_child(tiny)
	var wide := Label.new()
	wide.text = "wide label"
	wide.custom_minimum_size = Vector2(600, 20)
	vb.add_child(wide)
	var fake_rect: Dictionary = scan_layout(fake, Rect2(Vector2.ZERO, Vector2(412, 600)), 44.0)
	var fake_small: Dictionary = scan_layout(fake, Rect2(Vector2.ZERO, Vector2(412, 600)), 300.0) ## (글자 크기가 커져도 확실히 작은 한도)
	fake.queue_free()
	fails(int(fake_small["small"]) > 0, "layout scan finds a button that is shorter than the limit")
	fails(int(fake_rect["wide"]) > 0, "layout scan finds a label wider than the screen")
	fails(int(fake_rect["rect"]) > 0, "layout scan finds a label outside the screen")
	var good_fake := Control.new()
	good_fake.size = Vector2(412, 600)
	add_child(good_fake)
	var gb := Button.new()
	gb.text = "ok"
	gb.custom_minimum_size = Vector2(80, 48)
	good_fake.add_child(gb)
	var gr: Dictionary = scan_layout(good_fake, Rect2(Vector2.ZERO, Vector2(412, 600)), 44.0)
	good_fake.queue_free()
	ok(int(gr["small"]) == 0 and int(gr["wide"]) == 0 and int(gr["rect"]) == 0, "selfcheck: layout scan accepts a normal 48 px button")


# ---------------------------------------------------------------- 문제 모음

func _test_pool_and_types() -> void:
	print("[real builder exercises]")
	var types: Dictionary = {}
	for k in pool.keys():
		types[String(k).get_slice("/", 0)] = true
	for t in ALL_TYPES:
		ok(types.has(t), "the real builder produced a %s exercise" % t)
	for k in ["recognize/en_ko", "recognize/hear_ko", "recognize/hear_en", "recall/ko_en_choice", "recall/ko_en_type", "listen/choose_ko", "listen/type",
			"speak/repeat", "speak/substitute", "speak/answer", "speak/intro", "dialogue_script/listen", "dialogue_script/role"]:
		ok(pool.has(k), "the real builder produced %s" % k)
	ok(pool.has("build/"), "the real builder produced build")
	# 모든 실제 문제는 validate 를 통과한다
	var bad: int = 0
	var total: int = 0
	for k in pool.keys():
		for e in pool[k]:
			total += 1
			if CourseExerciseView.validate(e) != "":
				bad += 1
				print("  invalid real exercise: ", k, " -> ", CourseExerciseView.validate(e))
	ok(total > 20 and bad == 0, "every real exercise passes validate (%d checked, %d bad)" % [total, bad])
	var infos: int = 0
	for k in pool.keys():
		for e in pool[k]:
			if CourseExerciseView.is_info_card(e):
				infos += 1
	ok(infos >= 3, "is_info_card finds the teach cards and the listening dialogue")
	ok(not CourseExerciseView.is_info_card(_first("recognize/en_ko")) and not CourseExerciseView.is_info_card(null) and not CourseExerciseView.is_info_card(_first("dialogue_script/role")), "is_info_card: a question, null and a role dialogue are not info cards")
	var v := _make_view()
	ok(v.state == "empty" and v.find_child("Footer", true, false) != null, "a new view is empty with a footer node")


# ---------------------------------------------------------------- 소개 카드

func _test_teach() -> void:
	print("[teach cards]")
	for key in ["teach_word/", "teach_pattern/"]:
		var e: Dictionary = _first(key)
		var v: CourseExerciseView = await _show(e)
		ok(v.state == "info" and v.kind == "info", "%s: info state" % key)
		ok(v.confirm_btn == null and _button_named("ConfirmBtn") == null, "%s: no confirm button" % key)
		var nb: Button = _button_named("NextBtn")
		ok(nb != null and nb.visible and not nb.disabled and nb.text == "다음", "%s: [다음] visible" % key)
		press(nb, "NextBtn (%s)" % key)
		ok(next_n == 1 and results.is_empty(), "%s: next_requested once and no answered" % key)
		if key == "teach_word/":
			ok(_has_text(v, String(e["prompt"])) and _has_text(v, String(e["ko"])), "teach_word shows the English word and the Korean meaning")
			var pb: Button = _button_named("PlayBtn")
			tts_calls.clear()
			press(pb, "PlayBtn (teach_word)")
			await _frames(4)
			ok(not tts_calls.is_empty() and String(tts_calls[0]["text"]) == String(e["tts"]), "teach_word: the play button reads the exercise tts")
			ok(e.has("example") and _has_text(v, String(e["example"]["en"])), "teach_word shows the example sentence")
		else:
			ok(_has_text(v, String(e["tpl"])) and _has_text(v, String(e["title_ko"])), "teach_pattern shows the template and its Korean title")
			var ex_n: int = (e["examples"] as Array).size()
			var eb: Array = []
			_buttons(v, eb)
			var play_n: int = 0
			for b in eb:
				if b.name == "ExamplePlayBtn":
					play_n += 1
			ok(play_n == ex_n and ex_n >= 1, "teach_pattern: one example play button per example")
	# 소개 카드에 [다음] 만 있고 다음 문제를 그려도 이전 카드 노드가 남지 않는다
	var v2: CourseExerciseView = await _show(_first("teach_word/"))
	v2.show_exercise(_first("teach_pattern/"))
	await _frames(2)
	ok(v2.find_children("TeachCard*", "", true, false).size() == 1, "showing the next exercise replaces the old card (one TeachCard)")


# ---------------------------------------------------------------- 고르기 (보기 -> 확인 -> 피드백 -> 다음)

func _check_feedback(v: CourseExerciseView, right: bool, label: String) -> void:
	var fb: Node = _node("Feedback")
	ok(fb != null and (fb as Control).visible and bool(fb.get_meta("ok", not right)) == right, "%s: feedback shown with ok=%s" % [label, right])
	var t: Label = _node("FeedbackTitle") as Label
	ok(t != null and t.text == ("맞았어요" if right else "틀렸어요"), "%s: feedback says %s in words, not only colour" % [label, "맞았어요" if right else "틀렸어요"])
	var mark: Node = _node("FeedbackMark")
	ok(mark is GlyphIcon and (mark as GlyphIcon).kind == ("check" if right else "close"), "%s: feedback has a %s shape" % [label, "check" if right else "close"])
	var nb: Button = _button_named("NextBtn")
	ok(nb != null and nb.is_visible_in_tree() and not nb.disabled, "%s: [다음] is visible and enabled after the answer" % label)
	ok(_button_named("ConfirmBtn") == null or not _button_named("ConfirmBtn").is_visible_in_tree(), "%s: [확인] is gone after the answer" % label)


func _solve_choice(v: CourseExerciseView, e: Dictionary, right: bool, label: String) -> void:
	var n: int = (e["options"] as Array).size()
	var idx: int = int(e["answer"]) if right else (int(e["answer"]) + 1) % n
	var n_res: int = results.size()
	var cb: Button = _button_named("ConfirmBtn")
	ok(cb != null and cb.disabled, "%s: [확인] is disabled before a choice" % label)
	press(v.option_btns[idx], "Opt%d (%s)" % [idx, label])
	ok(cb.disabled == false and v.picked == idx, "%s: the choice enables [확인]" % label)
	ok(results.size() == n_res, "%s: choosing alone does not answer" % label)
	press(cb, "ConfirmBtn (%s)" % label)


func _test_choice() -> void:
	print("[choice exercises: recognize / recall choice / listen choose]")
	for key in ["recognize/en_ko", "recognize/hear_ko", "recognize/hear_en", "recall/ko_en_choice", "listen/choose_ko"]:
		var e: Dictionary = _first(key)
		# 정답
		var v: CourseExerciseView = await _show(e)
		ok(v.state == "asking" and v.option_btns.size() == (e["options"] as Array).size(), "%s: asking with %d option buttons" % [key, (e["options"] as Array).size()])
		_solve_choice(v, e, true, key + " right")
		ok(results.size() == 1 and bool(results[0]["ok"]) and results[0]["id"] == e["id"] and results[0]["answer"] == int(e["answer"]), "%s: right answer -> result ok, id, answer" % key)
		ok(bool(results[0]["first_try"]) and not bool(results[0]["skipped"]) and not bool(results[0]["near"]), "%s: first try, not skipped" % key)
		_check_feedback(v, true, key + " right")
		var rb: Button = _button_named("ReplayBtn")
		ok(rb != null and rb.is_visible_in_tree(), "%s: right answer offers the English sentence again" % key)
		tts_calls.clear()
		press(rb, "ReplayBtn (%s)" % key)
		await _frames(4)
		ok(not tts_calls.is_empty() and String(tts_calls[0]["text"]) == String(e["tts"]), "%s: replay reads the exercise tts" % key)
		var right_btn: Button = v.option_btns[int(e["answer"])]
		ok(String(right_btn.text).contains("(정답)"), "%s: the right option is marked with text (정답)" % key)
		press(_button_named("NextBtn"), "NextBtn (%s right)" % key)
		ok(next_n == 1, "%s: [다음] sends next_requested" % key)
		# 오답
		var v2: CourseExerciseView = await _show(e)
		var wrong_idx: int = (int(e["answer"]) + 1) % (e["options"] as Array).size()
		_solve_choice(v2, e, false, key + " wrong")
		ok(results.size() == 1 and not bool(results[0]["ok"]) and results[0]["answer"] == wrong_idx, "%s: wrong answer -> result not ok" % key)
		_check_feedback(v2, false, key + " wrong")
		ok(_has_text(_node("Feedback"), "정답"), "%s: wrong answer shows the right answer in Korean text" % key)
		ok(String(v2.option_btns[int(e["answer"])].text).contains("(정답)") and String(v2.option_btns[wrong_idx].text).contains("(내 답)"), "%s: options are marked 정답 / 내 답 by text" % key)
		var all_off: bool = true
		for b in v2.option_btns:
			if not (b as Button).disabled:
				all_off = false
		ok(all_off, "%s: options are locked after the answer" % key)
		press(_button_named("NextBtn"), "NextBtn (%s wrong)" % key)
	# 보기를 바꿔 누르면 마지막 것이 답
	var e2: Dictionary = _first("recognize/en_ko")
	var v3: CourseExerciseView = await _show(e2)
	press(v3.option_btns[0], "Opt0 (change mind)")
	press(v3.option_btns[1], "Opt1 (change mind)")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (change mind)")
	ok(results.size() == 1 and results[0]["answer"] == 1, "the last chosen option is the answer")
	# 화면이 정답을 판정에 쓰는 증거: 정답 위치 다른 같은 문제
	var e3: Dictionary = e2.duplicate(true)
	e3["answer"] = 1 if int(e2["answer"]) != 1 else 0
	var v4: CourseExerciseView = await _show(e3)
	press(v4.option_btns[int(e3["answer"])], "Opt (moved answer)")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (moved answer)")
	ok(results.size() == 1 and bool(results[0]["ok"]), "the judge follows the exercise's answer field, not a fixed position")
	# 재출제 표시
	var v5: CourseExerciseView = await _show(e2, {"retry": true, "next_text": "계속"})
	ok(_node("RetryChip") != null and _button_named("NextBtn") == null, "retry chip shows; [다음] is not there before the answer")
	press(v5.option_btns[0], "Opt0 (retry)")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (retry)")
	ok(_button_named("NextBtn").text == "계속", "ctx.next_text changes the [다음] text")


# ---------------------------------------------------------------- 쓰기

func _type_into(v: CourseExerciseView, txt: String) -> void:
	v.edit.text = txt
	v.edit.text_changed.emit(txt) # 키를 눌렀을 때와 같은 신호


func _test_typed() -> void:
	print("[typed exercises: recall type / listen type]")
	for key in ["recall/ko_en_type", "listen/type"]:
		var e: Dictionary = _first(key)
		var acc0: String = String((e["accept"] as Array)[0])
		# 정답
		var v: CourseExerciseView = await _show(e)
		ok(v.state == "asking" and v.edit != null and v.edit.size.y >= 56.0 - 0.5, "%s: input box (height >= 56)" % key)
		var cb: Button = _button_named("ConfirmBtn")
		ok(cb.disabled, "%s: [확인] disabled with an empty box" % key)
		_type_into(v, "   ")
		ok(cb.disabled, "%s: [확인] stays disabled for spaces only" % key)
		_type_into(v, acc0)
		ok(not cb.disabled, "%s: typing enables [확인]" % key)
		press(cb, "ConfirmBtn (%s right)" % key)
		ok(results.size() == 1 and bool(results[0]["ok"]) and results[0]["answer"] == acc0 and results[0]["tries"] == 1, "%s: exact answer is right on the first try" % key)
		_check_feedback(v, true, key + " right")
		ok(not v.edit.editable, "%s: the box is locked after the answer" % key)
		press(_button_named("NextBtn"), "NextBtn (%s right)" % key)
		# 오답
		var v2: CourseExerciseView = await _show(e)
		_type_into(v2, "zzqq")
		press(_button_named("ConfirmBtn"), "ConfirmBtn (%s wrong)" % key)
		ok(results.size() == 1 and not bool(results[0]["ok"]) and not bool(results[0]["near"]), "%s: a wrong word is wrong (not near)" % key)
		_check_feedback(v2, false, key + " wrong")
		ok(_has_text(_node("Feedback"), acc0), "%s: wrong answer shows the right answer %s" % [key, acc0])
		press(_button_named("NextBtn"), "NextBtn (%s wrong)" % key)
		# Enter 키도 [확인]
		var v3: CourseExerciseView = await _show(e)
		_type_into(v3, acc0)
		v3.edit.text_submitted.emit(acc0)
		ok(results.size() == 1 and bool(results[0]["ok"]), "%s: Enter submits like [확인]" % key)
		# 빈 칸에서 Enter 는 아무 일도 하지 않는다
		var v4: CourseExerciseView = await _show(e)
		v4.edit.text_submitted.emit("")
		ok(results.is_empty() and v4.state == "asking", "%s: Enter on an empty box does nothing" % key)
	# 그 자리에서 어려운 입력: 300자, 한글, 이모지, 다시 쓰기
	var er: Dictionary = _first("recall/ko_en_type")
	var hard: Dictionary = {
		"300 letters": "a".repeat(300),
		"hangul": "사과가 좋아요",
		"emoji": String.chr(0x1F34E) + String.chr(0x1F34E),
		"control chars": "app\tle\n",
		"only punctuation": "?!...",
	}
	for k in hard.keys():
		var vv: CourseExerciseView = await _show(er)
		_type_into(vv, String(hard[k]))
		if (vv.confirm_btn as Button).disabled:
			ok(String(hard[k]).strip_edges() == "" , "hard input '%s': [확인] disabled only for blank text" % k)
			continue
		press(_button_named("ConfirmBtn"), "ConfirmBtn (hard: %s)" % k)
		ok(results.size() == 1 and not bool(results[0]["ok"]), "hard input '%s' is not a right answer" % k)
		ok(vv.state == "answered" or vv.state == "near", "hard input '%s': the view stays in a sane state (%s)" % [k, vv.state])


func _test_near() -> void:
	print("[near: one more try]")
	var e: Dictionary = {}
	for cand in _all("recall/ko_en_type"):
		if String((cand["accept"] as Array)[0]).length() >= 5 and not String((cand["accept"] as Array)[0]).contains(" "):
			e = cand
			break
	ok(not e.is_empty(), "found a typed exercise with an answer of 5+ letters")
	if e.is_empty():
		return
	var acc0: String = String((e["accept"] as Array)[0])
	var typo: String = acc0.substr(0, acc0.length() - 1) # 한 글자 빠짐
	# 거의 맞음 -> 안내 -> 한 번 더 -> 맞음
	var v: CourseExerciseView = await _show(e)
	_type_into(v, typo)
	press(_button_named("ConfirmBtn"), "ConfirmBtn (near 1st)")
	ok(results.is_empty() and v.state == "near", "near: no answered yet, state near")
	var note: Node = _node("NearNote")
	ok(note != null and _has_text(note, "거의 맞아요: " + acc0), "near: the note says '거의 맞아요: %s'" % acc0)
	ok(v.edit.editable and not (v.confirm_btn as Button).disabled and _button_named("ConfirmBtn").is_visible_in_tree(), "near: the box is editable and [확인] works again")
	_type_into(v, acc0)
	press(_button_named("ConfirmBtn"), "ConfirmBtn (near 2nd right)")
	ok(results.size() == 1 and bool(results[0]["ok"]) and not bool(results[0]["first_try"]) and results[0]["tries"] == 2, "near then right: ok, not first try, 2 tries")
	ok(_node("NearNote") == null, "near: the note is gone after the answer")
	_check_feedback(v, true, "near then right")
	# 거의 맞음 두 번 -> 틀림
	var v2: CourseExerciseView = await _show(e)
	_type_into(v2, typo)
	press(_button_named("ConfirmBtn"), "ConfirmBtn (near twice 1)")
	_type_into(v2, typo)
	press(_button_named("ConfirmBtn"), "ConfirmBtn (near twice 2)")
	ok(results.size() == 1 and not bool(results[0]["ok"]) and results[0]["tries"] == 2, "near twice: wrong after the second try")
	_check_feedback(v2, false, "near twice")
	# 부호만 다름(정규화 뒤에도 같지 않음) -> 거의 맞음
	var v3: CourseExerciseView = await _show(e)
	_type_into(v3, acc0.substr(0, 2) + "-" + acc0.substr(2))
	press(_button_named("ConfirmBtn"), "ConfirmBtn (near hyphen)")
	ok(results.is_empty() and v3.state == "near", "a hyphen inside the word is 'near' (one more try)")
	# 4글자 미만 낱말은 한 글자 차이를 거의 맞음으로 보지 않는다
	var shorts: Array = []
	for cand in _all("recall/ko_en_type"):
		if String((cand["accept"] as Array)[0]).length() <= 3:
			shorts.append(cand)
	if not shorts.is_empty():
		var s0: String = String((shorts[0]["accept"] as Array)[0])
		var v4: CourseExerciseView = await _show(shorts[0])
		_type_into(v4, s0.substr(0, s0.length() - 1) + "q")
		press(_button_named("ConfirmBtn"), "ConfirmBtn (short word one letter off)")
		ok(results.size() == 1 and not bool(results[0]["ok"]) and v4.state == "answered", "a one letter slip in a very short word is wrong at once (builder rule)")


## 정규화(소문자·끝 부호·공백)는 LessonBuilder.judge 가 한다: 화면이 문자열을 직접 비교하면 여기서 FAIL 한다(E4a-8).
func _test_normalization() -> void:
	print("[normalization through the judge]")
	var e: Dictionary = _first("recall/ko_en_type")
	var acc0: String = String((e["accept"] as Array)[0])
	var variants: Array = [acc0.to_upper(), "  " + acc0 + "  ", acc0 + ".", acc0.capitalize() + "!", acc0.to_upper() + " ?"]
	for t in variants:
		var v: CourseExerciseView = await _show(e)
		_type_into(v, String(t))
		press(_button_named("ConfirmBtn"), "ConfirmBtn (variant '%s')" % String(t).strip_edges())
		ok(results.size() == 1 and bool(results[0]["ok"]), "normalization: '%s' is right for '%s'" % [t, acc0])
	var e2: Dictionary = _first("listen/type")
	var s: String = String((e2["accept"] as Array)[0])
	var v2: CourseExerciseView = await _show(e2)
	_type_into(v2, s.to_lower().trim_suffix(".") + "  ")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (dictation lower case)")
	ok(results.size() == 1 and bool(results[0]["ok"]), "normalization: a lower case dictation without the full stop is right")


# ---------------------------------------------------------------- 조립

func _press_tile_for(v: CourseExerciseView, token: String, label: String) -> bool:
	for i in v.tile_btns.size():
		var b: Button = v.tile_btns[i]
		if String(b.text) == token and not b.disabled:
			press(b, "Tile%d '%s' (%s)" % [i, token, label])
			return true
	return false


func _in_accepts(e: Dictionary, mine: Array) -> bool:
	if mine == e["answer"]:
		return true
	for a in e["accept"]:
		if a == mine:
			return true
	return false


func _test_build() -> void:
	print("[build: tiles]")
	var builds: Array = _all("build/")
	ok(builds.size() >= 3, "several real build exercises (%d)" % builds.size())
	for bi in mini(builds.size(), 3):
		var e: Dictionary = builds[bi]
		var answer: Array = e["answer"]
		# 정답 순서
		var v: CourseExerciseView = await _show(e)
		var n_tiles: int = answer.size() + (e["extra"] as Array).size()
		ok(v.tile_btns.size() == n_tiles, "build: %d tiles (answer %d + extra %d)" % [n_tiles, answer.size(), (e["extra"] as Array).size()])
		var cb: Button = _button_named("ConfirmBtn")
		ok(cb.disabled, "build: [확인] disabled with no tile chosen")
		var all_found: bool = true
		for t in answer:
			if not _press_tile_for(v, String(t), "right"):
				all_found = false
		ok(all_found and v.chosen.size() == answer.size(), "build: every answer tile could be pressed")
		var row: Array = []
		for c in _node("AnswerRow").get_children():
			if c is Button:
				row.append(String(c.text))
		ok(row == answer, "build: the answer row shows the chosen tiles in order")
		ok(not cb.disabled, "build: [확인] enabled after choosing tiles")
		press(cb, "ConfirmBtn (build right)")
		ok(results.size() == 1 and bool(results[0]["ok"]) and results[0]["answer"] == answer, "build: the right order is right")
		_check_feedback(v, true, "build right")
		press(_button_named("NextBtn"), "NextBtn (build right)")
		# 틀린 조립: 마지막 낱말 빼기
		var v2: CourseExerciseView = await _show(e)
		var short: Array = answer.slice(0, answer.size() - 1)
		for t in short:
			_press_tile_for(v2, String(t), "wrong")
		press(_button_named("ConfirmBtn"), "ConfirmBtn (build wrong)")
		ok(results.size() == 1 and bool(results[0]["ok"]) == _in_accepts(e, short), "build: a sentence missing its last word is judged wrong")
		if not _in_accepts(e, short):
			_check_feedback(v2, false, "build wrong")
			ok(_has_text(_node("Feedback"), " ".join(PackedStringArray(answer))), "build: the wrong answer shows the right sentence")
	# 눌렀다 빼기 / 다시 놓기
	var e1: Dictionary = builds[0]
	var v3: CourseExerciseView = await _show(e1)
	_press_tile_for(v3, String(e1["answer"][0]), "put")
	ok(v3.chosen.size() == 1, "build: one tile chosen")
	var first_chosen: Button = null
	for c in _node("AnswerRow").get_children():
		if c is Button:
			first_chosen = c
	press(first_chosen, "Chosen0 (take back)")
	ok(v3.chosen.is_empty() and (v3.confirm_btn as Button).disabled, "build: pressing a placed tile takes it back and disables [확인] again")
	ok(not (v3.tile_btns[0] as Button).disabled or _any_enabled(v3.tile_btns), "build: the tile is back in the pool")
	# 같은 글자 타일이 두 개 있는 문제(손으로 만든 보조 시험)
	var dup: Dictionary = {"type": "build", "id": "x:1:1:bld:dup", "ko": "저는 저는", "answer": ["I", "like", "I"], "extra": [], "accept": [["I", "like", "I"]], "tts": "I like I."}
	var v4: CourseExerciseView = await _show(dup)
	for t in ["I", "like", "I"]:
		_press_tile_for(v4, t, "duplicate words")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (duplicate tiles)")
	ok(results.size() == 1 and bool(results[0]["ok"]), "build: two tiles with the same word can both be used")


func _any_enabled(btns: Array) -> bool:
	for b in btns:
		if not (b as Button).disabled:
			return true
	return false


# ---------------------------------------------------------------- 소리

func _test_sound() -> void:
	print("[sound: Tts.speak(tts, en, slow)]")
	var e: Dictionary = _first("recognize/hear_en")
	var v: CourseExerciseView = await _show(e)
	tts_calls.clear()
	press(_button_named("PlayBtn"), "PlayBtn (hear_en)")
	await _frames(5)
	ok(tts_calls.size() == 1 and String(tts_calls[0]["text"]) == String(e["tts"]) and tts_calls[0]["lang"] == "en", "play: Tts gets the exercise tts and lang en")
	var normal_speed: float = float(tts_calls[0]["speed"]) if not tts_calls.is_empty() else 0.0
	tts_calls.clear()
	press(_button_named("SlowBtn"), "SlowBtn (hear_en)")
	await _frames(5)
	ok(tts_calls.size() == 1 and String(tts_calls[0]["text"]) == String(e["tts"]) and float(tts_calls[0]["speed"]) < normal_speed, "slow: same text, slower speed (%.2f < %.2f)" % [float(tts_calls[0]["speed"]) if not tts_calls.is_empty() else -1.0, normal_speed])
	# say 가 있어도 tts 필드를 읽는다
	var odd: Dictionary = e.duplicate(true)
	odd["say"] = "SAYFIELDTEXT"
	odd["tts"] = "TTSFIELDTEXT"
	var v2: CourseExerciseView = await _show(odd)
	tts_calls.clear()
	press(_button_named("PlayBtn"), "PlayBtn (say vs tts)")
	await _frames(5)
	var texts: Array = tts_calls.map(func(c): return c["text"])
	ok(texts.has("TTSFIELDTEXT") and not texts.has("SAYFIELDTEXT"), "play reads the tts field, never the say field")
	# 방금 문제의 play() 도 같다
	tts_calls.clear()
	v2.play(false)
	await _frames(5)
	ok(not tts_calls.is_empty() and tts_calls[0]["text"] == "TTSFIELDTEXT", "play() also reads the tts field")
	# 속도 0.75 인 듣기 문제는 기본 재생이 느린 소리
	var slow_ex: Dictionary = _first("listen/choose_ko").duplicate(true)
	slow_ex["speed"] = 0.75
	var v3: CourseExerciseView = await _show(slow_ex)
	tts_calls.clear()
	press(_button_named("PlayBtn"), "PlayBtn (speed 0.75)")
	await _frames(5)
	ok(not tts_calls.is_empty() and float(tts_calls[0]["speed"]) < normal_speed, "an exercise speed below 0.9 plays slowly by default")
	# 자동 재생
	var v4: CourseExerciseView = _make_view()
	tts_calls.clear()
	v4.show_exercise(_first("listen/choose_ko"), {"autoplay": true})
	await _frames(5)
	ok(not tts_calls.is_empty(), "ctx.autoplay plays a listening exercise at once")
	tts_calls.clear()
	v4.show_exercise(_first("listen/choose_ko"))
	await _frames(5)
	ok(tts_calls.is_empty(), "without autoplay nothing plays by itself")
	# en_ko: 단어 보기 + 소리, recall choice: 정답을 흘리지 않으려 소리 버튼이 없다
	var v5: CourseExerciseView = await _show(_first("recall/ko_en_choice"))
	ok(_button_named("PlayBtn") == null, "recall choice has no play button before the answer (it would give the answer away)")
	for b in v5.option_btns:
		pass
	press(v5.option_btns[int(_first("recall/ko_en_choice")["answer"])], "Opt (recall choice)")
	press(_button_named("ConfirmBtn"), "ConfirmBtn (recall choice)")
	ok(_button_named("ReplayBtn") != null, "recall choice offers the sound after the answer")
	press(_button_named("NextBtn"), "NextBtn (recall choice)")


# ---------------------------------------------------------------- 말하기

func _score(transcript: String, score: float) -> Dictionary:
	return {"transcript": transcript, "units": [{"w": "x", "ok": true}], "score": score, "lang": "en"}


func _start_record(v: CourseExerciseView) -> void:
	print("record: recorder.recorded (microphone replaced by FAKE_REC)")
	v.drill.recorder.recorded.emit(FAKE_REC)


func _test_speak_pc() -> void:
	print("[speak on the PC path: /score through api_hook]")
	Route.mode = "pc" if phone else Route.mode
	ok(not SelfRatePanel.needed(), "the score engine is reachable in this test (self rating is not needed)")
	for key in ["speak/repeat", "speak/substitute"]:
		var e: Dictionary = _first(key)
		var target: String = String(e["target"]) if key == "speak/repeat" else String((e["accept"] as Array)[0])
		var v: CourseExerciseView = await _show(e)
		ok(v.state == "asking" and v.drill != null and v.drill.recorder != null and _button_named("SkipBtn") != null, "%s: drill, recorder and the give-up button" % key)
		ok(_has_text(v, String(e["target"])), "%s: the target sentence is shown" % key)
		if key == "speak/substitute":
			ok(_node("CueLabel") is Label and (_node("CueLabel") as Label).text.contains(String(e["cue"]["with"])), "substitute: the cue says which word to put in")
		# 맞음: 전사가 같다
		requests.clear()
		score_reply = _score(target, 91.0)
		_start_record(v)
		await _wait_state(v, "answered")
		ok(not requests.is_empty() and requests[0]["path"] == "/score" and requests[0]["body"]["target"] == target, "%s: /score is asked with the right target" % key)
		ok(v.state == "answered" and results.size() == 1 and bool(results[0]["ok"]) and not bool(results[0]["self_rated"]), "%s: matching transcript -> right" % key)
		_check_feedback(v, true, key + " right")
		press(_button_named("NextBtn"), "NextBtn (%s right)" % key)
		# 틀림: 점수 낮고 전사 다름
		var v2: CourseExerciseView = await _show(e)
		score_reply = _score("something else entirely", 35.0)
		_start_record(v2)
		await _wait_state(v2, "answered")
		ok(results.size() == 1 and not bool(results[0]["ok"]) and not bool(results[0]["gave_up"]), "%s: low score and other words -> wrong" % key)
		_check_feedback(v2, false, key + " wrong")
		press(_button_named("NextBtn"), "NextBtn (%s wrong)" % key)
		# 점수가 통과선 이상이면(전사가 조금 달라도) 맞음
		var v3: CourseExerciseView = await _show(e)
		score_reply = _score("close enough words", 82.0)
		_start_record(v3)
		await _wait_state(v3, "answered")
		ok(results.size() == 1 and bool(results[0]["ok"]), "%s: a score above the pass line is right" % key)
		# 소리 없음: 판정하지 않고 계속 기다린다
		var v4: CourseExerciseView = await _show(e)
		score_reply = {}
		_start_record(v4)
		await _frames(8)
		ok(v4.state == "asking" and results.is_empty(), "%s: a silent recording is not an answer (the view keeps asking)" % key)
		# 말하기 어려워요 -> 틀림 + gave_up
		press(_button_named("SkipBtn"), "SkipBtn (%s)" % key)
		ok(results.size() == 1 and not bool(results[0]["ok"]) and bool(results[0]["gave_up"]) and not bool(results[0]["skipped"]), "%s: give up -> wrong, gave_up, not skipped" % key)
		_check_feedback(v4, false, key + " give up")
		# 이상한 응답(깨진 JSON 모양)
		var v5: CourseExerciseView = await _show(e)
		score_reply = {"transcript": 5, "units": "x", "score": "high"}
		_start_record(v5)
		await _frames(8)
		ok(v5.state == "asking" and results.is_empty(), "%s: a broken /score answer is not an answer" % key)
	_leave_pc_route()


func _leave_pc_route() -> void:
	Route.mode = _saved["route"]


func _test_speak_self_rate() -> void:
	print("[speak on the phone path: self rating]")
	Route.mode = "phone"
	ok(SelfRatePanel.needed(), "phone mode without a score engine needs self rating")
	var e: Dictionary = _first("speak/repeat")
	var v: CourseExerciseView = await _show(e)
	requests.clear()
	_start_record(v)
	await _frames(3)
	ok(requests.is_empty(), "self rating sends no /score request")
	var again: Button = _find_text_button(v, "다시")
	var good: Button = _find_text_button(v, "잘했어요")
	ok(again != null and good != null, "the self rating panel has [잘했어요] and [다시] buttons")
	press(again, "다시 (self rating)")
	ok(results.is_empty() and v.state == "asking", "[다시] records nothing and keeps asking")
	_start_record(v)
	await _frames(3)
	good = _find_text_button(v, "잘했어요")
	press(good, "잘했어요 (self rating)")
	ok(results.size() == 1 and bool(results[0]["ok"]) and bool(results[0]["self_rated"]), "[잘했어요] -> right with self_rated")
	_check_feedback(v, true, "self rated")
	press(_button_named("NextBtn"), "NextBtn (self rated)")
	var v2: CourseExerciseView = await _show(_first("speak/substitute"))
	press(_button_named("SkipBtn"), "SkipBtn (self rating path)")
	ok(results.size() == 1 and not bool(results[0]["ok"]) and bool(results[0]["gave_up"]), "give up works on the phone path too")
	Route.mode = _saved["route"]


func _test_month_speak() -> void:
	print("[month speak: answer / intro / read]")
	Route.mode = "pc" if phone else Route.mode
	for key in ["speak/answer", "speak/intro"]:
		var e: Dictionary = _first(key)
		var expect0: String = String((e["expect_any"] as Array)[0])
		var v: CourseExerciseView = await _show(e)
		ok(_has_text(v, String(e["prompt_en"])), "%s: the prompt is shown" % key)
		ok(not _has_text(_node("QuestionCard"), expect0) or String(e["prompt_en"]).to_lower().contains(expect0.to_lower()), "%s: the expected answer is not revealed before the answer" % key)
		score_reply = _score("well " + expect0 + " thanks", 40.0)
		requests.clear()
		_start_record(v)
		await _wait_state(v, "answered")
		ok(results.size() == 1 and bool(results[0]["ok"]), "%s: a transcript containing an expected word is right (judge on expect_any)" % key)
		ok(requests[0]["body"]["target"] == expect0, "%s: /score target is the first expected answer" % key)
		var v2: CourseExerciseView = await _show(e)
		score_reply = _score("zzz qqq", 95.0)
		_start_record(v2)
		await _wait_state(v2, "answered")
		ok(results.size() == 1 and not bool(results[0]["ok"]), "%s: other words are wrong even with a high pronunciation score" % key)
		ok(_has_text(_node("Feedback"), expect0), "%s: the wrong answer shows an expected answer" % key)
	# 따라 읽기(월말 read): speak/repeat 와 같은 화면
	var rd: Dictionary = {}
	for cand in _all("speak/repeat"):
		if String(cand.get("stage", "")) == "month":
			rd = cand
			break
	if not rd.is_empty():
		var v3: CourseExerciseView = await _show(rd)
		score_reply = _score(String(rd["target"]), 88.0)
		_start_record(v3)
		await _wait_state(v3, "answered")
		ok(results.size() == 1 and bool(results[0]["ok"]), "month read-aloud is judged like repeat")
	_leave_pc_route()


# ---------------------------------------------------------------- 대본 대화

func _test_dialogue() -> void:
	print("[dialogue]")
	Route.mode = "pc" if phone else Route.mode
	# 듣기 대화: 정보 카드
	var l: Dictionary = _first("dialogue_script/listen")
	var v: CourseExerciseView = await _show(l)
	ok(v.state == "info" and CourseExerciseView.is_info_card(l), "listening dialogue is an info card")
	var lines: int = (l["lines"] as Array).size()
	ok(_count_meta(v, "line_card") == lines, "listening dialogue shows all %d lines" % lines)
	press(_button_named("NextBtn"), "NextBtn (dialogue listen)")
	ok(next_n == 1 and results.is_empty(), "listening dialogue: next only, no answered")
	# 역할 대화(빌더 출력)
	var r: Dictionary = _first("dialogue_script/role")
	ok(not r.is_empty(), "the real builder produced a role dialogue")
	var you_n: int = 0
	for ln in r["lines"]:
		if bool(ln["you"]):
			you_n += 1
	var v2: CourseExerciseView = await _show(r)
	ok(v2.state == "asking" and v2.kind == "dialogue", "role dialogue: asking")
	ok(_node("TurnCard") != null and _node("HintKo") != null and _node("HintKo").visible, "role dialogue: the Korean hint is visible by default (hints = show)")
	ok(_node("ModelEn") != null and not _node("ModelEn").visible, "role dialogue: the model answer is hidden at first")
	press(_button_named("ModelBtn"), "ModelBtn (role dialogue)")
	ok(_node("ModelEn").visible and v2.hint_used, "role dialogue: [모범 답 보기] shows the model answer and notes hint use")
	var first_you: Dictionary = {}
	for ln in r["lines"]:
		if bool(ln["you"]):
			first_you = ln
			break
	score_reply = _score(String(first_you["accept"][0]), 90.0)
	_start_record(v2)
	await _frames(10)
	if you_n == 1:
		ok(v2.state == "answered" and results.size() == 1 and bool(results[0]["ok"]) and bool(results[0]["hint_used"]), "role dialogue: the only turn said right -> answered ok, hint used")
		ok(results[0]["lines_total"] == 1 and results[0]["lines_ok"] == 1, "role dialogue result counts the turns")
		_check_feedback(v2, true, "role dialogue")
		ok(_count_meta(v2, "line_card") == (r["lines"] as Array).size() - 1, "role dialogue: the partner lines are all shown at the end")
		press(_button_named("NextBtn"), "NextBtn (role dialogue)")
	# 줄이 여럿인 손으로 만든 역할 대화: 이어서 버튼
	var multi: Dictionary = {"type": "dialogue_script", "id": "x:4:4:dlg:multi", "mode": "role", "dialogue": "dmulti", "lines": [
		{"s": "A", "en": "Hello.", "ko": "안녕하세요.", "tts": "Hello.", "you": false},
		{"s": "B", "en": "Hi there.", "ko": "안녕.", "tts": "Hi there.", "you": true, "hint_ko": "안녕", "accept": ["Hi there."]},
		{"s": "A", "en": "How are you?", "ko": "잘 지내요?", "tts": "How are you?", "you": false},
		{"s": "B", "en": "Good, thanks.", "ko": "좋아요.", "tts": "Good, thanks.", "you": true, "hint_ko": "좋아요", "accept": ["Good, thanks."]},
		{"s": "A", "en": "Great.", "ko": "좋네요.", "tts": "Great.", "you": false}]}
	var v3: CourseExerciseView = await _show(multi, {"hints": "tap"})
	ok(not _node("HintKo").visible and _button_named("HintBtn") != null, "hints=tap: the hint is hidden behind [힌트 보기]")
	press(_button_named("HintBtn"), "HintBtn (tap mode)")
	ok(_node("HintKo").visible and v3.hint_used, "[힌트 보기] shows the hint and notes it")
	score_reply = _score("hi there", 85.0)
	_start_record(v3)
	await _frames(10)
	ok(v3.state == "turn_done" and results.is_empty(), "multi turn: after the first turn we wait for [이어서], no answered yet")
	ok(_node("LineFeedback") != null and (_node("LineFeedback") as Label).text == "맞았어요", "multi turn: the turn says 맞았어요")
	press(_button_named("ContinueBtn"), "ContinueBtn (multi turn)")
	ok(v3.state == "asking" and _count_meta(v3, "turn_card") == 2, "multi turn: [이어서] opens the next turn")
	score_reply = _score("nothing relevant", 20.0)
	_start_record(v3)
	await _frames(10)
	ok(v3.state == "answered" and results.size() == 1 and not bool(results[0]["ok"]) and results[0]["lines_ok"] == 1 and results[0]["lines_total"] == 2, "multi turn: one right, one wrong -> answered not ok (1 of 2)")
	_check_feedback(v3, false, "multi turn")
	press(_button_named("NextBtn"), "NextBtn (multi turn)")
	# 줄 중간에 포기
	var v4: CourseExerciseView = await _show(multi)
	press(_button_named("SkipBtn"), "SkipBtn (multi turn 1)")
	ok(v4.state == "turn_done", "give up on a turn moves on to [이어서]")
	press(_button_named("ContinueBtn"), "ContinueBtn (after give up)")
	press(_button_named("SkipBtn"), "SkipBtn (multi turn 2)")
	ok(v4.state == "answered" and results.size() == 1 and not bool(results[0]["ok"]) and bool(results[0]["gave_up"]) and results[0]["lines_ok"] == 0, "give up on both turns -> answered wrong, gave_up")
	_leave_pc_route()


# ---------------------------------------------------------------- 한 단위를 끝까지 (실제 빌더 단위, 버튼만)

func _solve_any(v: CourseExerciseView, e: Dictionary, right: bool, label: String) -> void:
	var typ: String = String(e["type"])
	match typ:
		"recognize", "listen", "recall":
			if e.has("options"):
				_solve_choice(v, e, right, label)
			else:
				_type_into(v, String((e["accept"] as Array)[0]) if right else "qqxx")
				press(_button_named("ConfirmBtn"), "ConfirmBtn (%s)" % label)
		"build":
			var toks: Array = e["answer"] if right else (e["answer"] as Array).slice(0, (e["answer"] as Array).size() - 1)
			for t in toks:
				_press_tile_for(v, String(t), label)
			press(_button_named("ConfirmBtn"), "ConfirmBtn (%s)" % label)
		"speak":
			if right:
				var tg: String = String(e["target"]) if String(e["mode"]) == "repeat" else String((e["accept"] as Array)[0])
				score_reply = _score(tg, 90.0)
				_start_record(v)
				await _wait_state(v, "answered")
			else:
				press(_button_named("SkipBtn"), "SkipBtn (%s)" % label)


func _test_full_unit() -> void:
	print("[whole real units: new w1 d1 / d2 / d3, w2 d2, buttons only]")
	Route.mode = "pc" if phone else Route.mode
	var kinds_seen: Dictionary = {}
	var right_n: int = 0
	var wrong_n: int = 0
	var all_ok: bool = true
	var total_ex: int = 0
	var c_ok: int = 0
	var n_answers: int = 0
	for wd in [[1, 1], [1, 2], [1, 3], [2, 2]]:
		var r: Dictionary = LessonBuilder.build({"kind": "new", "w": wd[0], "d": wd[1]}, data_raw, 5)
		ok(bool(r["ok"]) and (r["exercises"] as Array).size() >= 8, "unit w%d d%d builds %d exercises" % [wd[0], wd[1], (r["exercises"] as Array).size()])
		var v: CourseExerciseView = _make_view()
		var i: int = 0
		for e in r["exercises"]:
			var key: String = _key_of(e)
			kinds_seen[String(e["type"])] = true
			total_ex += 1
			v.show_exercise(e, {"retry": i % 7 == 6})
			await _frames(2)
			var before_next: int = next_n
			if CourseExerciseView.is_info_card(e):
				press(_button_named("NextBtn"), "NextBtn (w%d d%d #%d %s)" % [wd[0], wd[1], i, key])
			else:
				var right: bool = i % 3 != 2
				var n_before: int = results.size()
				await _solve_any(v, e, right, "w%d d%d #%d %s %s" % [wd[0], wd[1], i, key, "right" if right else "wrong"])
				if results.size() != n_before + 1 or bool(results[n_before]["ok"]) != right:
					all_ok = false
					print("  unit mismatch at ", i, " ", key, " ", results.size(), " ", n_before)
				if right:
					right_n += 1
				else:
					wrong_n += 1
				press(_button_named("NextBtn"), "NextBtn (w%d d%d #%d %s)" % [wd[0], wd[1], i, key])
			if next_n != before_next + 1:
				all_ok = false
			i += 1
		for rr in results:
			n_answers += 1
			if bool(rr["ok"]):
				c_ok += 1
	ok(all_ok, "every exercise of the units got its intended result and one next_requested (%d exercises)" % total_ex)
	ok(right_n >= 20 and wrong_n >= 8, "the units mixed right (%d) and wrong (%d) answers" % [right_n, wrong_n])
	for t in ["teach_word", "teach_pattern", "recognize", "recall", "build", "listen", "speak"]:
		ok(kinds_seen.has(t), "the units contained a %s exercise" % t)
	ok(c_ok == right_n and n_answers == right_n + wrong_n, "answered was emitted once per question (%d answers)" % n_answers)
	_leave_pc_route()


# ---------------------------------------------------------------- 일부러 틀린 입력 (E4a-6)

func _test_invalid() -> void:
	print("[broken exercises are skipped, no errors]")
	var good: Dictionary = _first("recognize/en_ko")
	var broken: Array = []
	var no_options: Dictionary = good.duplicate(true)
	no_options.erase("options")
	broken.append(["no options", no_options])
	var range_hi: Dictionary = good.duplicate(true)
	range_hi["answer"] = 99
	broken.append(["answer out of range (99)", range_hi])
	var range_neg: Dictionary = good.duplicate(true)
	range_neg["answer"] = -1
	broken.append(["answer -1", range_neg])
	var ans_frac: Dictionary = good.duplicate(true)
	ans_frac["answer"] = 1.5
	broken.append(["answer 1.5", ans_frac])
	var ans_str: Dictionary = good.duplicate(true)
	ans_str["answer"] = "0"
	broken.append(["answer as text", ans_str])
	var ans_null: Dictionary = good.duplicate(true)
	ans_null["answer"] = null
	broken.append(["answer null", ans_null])
	var opt_one: Dictionary = good.duplicate(true)
	opt_one["options"] = ["only one"]
	broken.append(["one option", opt_one])
	var opt_bad: Dictionary = good.duplicate(true)
	opt_bad["options"] = [1, 2, 3]
	broken.append(["options are numbers", opt_bad])
	var opt_str: Dictionary = good.duplicate(true)
	opt_str["options"] = "abc"
	broken.append(["options is text", opt_str])
	var no_prompt: Dictionary = good.duplicate(true)
	no_prompt.erase("prompt")
	broken.append(["recognize without prompt", no_prompt])
	broken.append(["unknown type", {"type": "zzz", "id": "x:1:1:zzz:a"}])
	broken.append(["type is a number", {"type": 5}])
	broken.append(["no type", {"id": "x:1:1:a"}])
	broken.append(["unknown mode", {"type": "recognize", "mode": "nope", "options": ["a", "b"], "answer": 0, "prompt": "x", "tts": "x"}])
	broken.append(["null", null])
	broken.append(["a number", 42])
	broken.append(["a text", "recognize"])
	broken.append(["an empty array", []])
	broken.append(["an empty dictionary", {}])
	broken.append(["build with no answer", {"type": "build", "id": "b", "answer": [], "extra": []}])
	broken.append(["build with number tiles", {"type": "build", "id": "b", "answer": [1, 2], "extra": []}])
	broken.append(["recall type without accept", {"type": "recall", "mode": "ko_en_type", "prompt_ko": "x", "id": "r"}])
	broken.append(["listen without tts", {"type": "listen", "mode": "choose_ko", "options": ["a", "b"], "answer": 0, "id": "l"}])
	broken.append(["speak with unknown mode", {"type": "speak", "mode": "zzz", "id": "s", "target": "x"}])
	broken.append(["substitute without cue", {"type": "speak", "mode": "substitute", "id": "s", "target": "x", "accept": ["y"]}])
	broken.append(["answer without expect_any", {"type": "speak", "mode": "answer", "id": "s", "prompt_en": "x"}])
	broken.append(["dialogue without lines", {"type": "dialogue_script", "id": "d", "lines": []}])
	broken.append(["dialogue line without en", {"type": "dialogue_script", "id": "d", "lines": [{"s": "A"}]}])
	broken.append(["dialogue you-line without accept", {"type": "dialogue_script", "id": "d", "lines": [{"s": "B", "en": "x", "you": true}]}])
	broken.append(["teach word without prompt", {"type": "teach_word", "id": "t"}])
	broken.append(["teach pattern without template", {"type": "teach_pattern", "id": "t"}])
	var skipped_ok: int = 0
	for item in broken:
		var label: String = String(item[0])
		var v: CourseExerciseView = _make_view()
		v.show_exercise(item[1])
		await _frames(2)
		var good_skip: bool = results.size() == 1 and bool(results[0]["skipped"]) and not bool(results[0]["ok"]) and v.state == "skipped"
		ok(good_skip, "broken '%s' -> answered(skipped:true), state skipped" % label)
		if good_skip:
			skipped_ok += 1
		var note: Node = v.find_child("SkippedNote", true, false)
		ok(note is Label and (note as Label).text == "이 문제를 건너뛰었어요" and (note as Label).is_visible_in_tree(), "broken '%s' -> the screen says 이 문제를 건너뛰었어요" % label)
		var nb: Button = _button_named("NextBtn")
		ok(nb != null and nb.is_visible_in_tree() and not nb.disabled, "broken '%s' -> [다음] is there" % label)
		if label == "null":
			press(nb, "NextBtn (skipped null)")
			ok(next_n == 1, "skipped exercise: [다음] sends next_requested")
	ok(skipped_ok == broken.size(), "all %d broken exercises were skipped" % broken.size())
	# 깨진 ctx
	for bad_ctx in [null, 5, "x", [], {"hints": 7, "next_text": 3, "retry": "yes", "autoplay": []}]:
		var v2: CourseExerciseView = _make_view()
		v2.show_exercise(good, bad_ctx)
		await _frames(2)
		ok(v2.state == "asking" and v2.option_btns.size() == (good["options"] as Array).size(), "a broken ctx (%s) falls back to defaults" % str(bad_ctx))
	# 깨진 문제 뒤에 좋은 문제가 정상으로 그려진다
	var v3: CourseExerciseView = _make_view()
	v3.show_exercise(null)
	v3.show_exercise(good)
	results.clear()
	await _frames(2)
	ok(v3.state == "asking" and v3.find_child("SkippedBox", true, false) == null, "after a skipped exercise the next good one draws normally")
	# 정답을 두 번 보내도 한 번만 센다
	press(v3.option_btns[0], "Opt0 (double confirm)")
	var cb: Button = _button_named("ConfirmBtn")
	press(cb, "ConfirmBtn (double confirm)")
	var n1: int = results.size()
	v3._on_confirm() # 이미 끝난 문제에 또 확인이 와도 아무 일 없다(방어)
	ok(n1 == 1 and results.size() == 1, "a second confirm on an answered exercise does nothing")
	# 판정 함수에 직접 이상한 값을 넣어도 틀림(에러 없음)
	var j1: Dictionary = LessonBuilder.judge(good, "a text")
	var j2: Dictionary = LessonBuilder.judge(null, 3)
	ok(not bool(j1["ok"]) and not bool(j2["ok"]), "LessonBuilder.judge gives not-ok for odd values (no error)")


# ---------------------------------------------------------------- 배치 (E4a-4)

func _all_states() -> Array:
	## 문제 모음에서 종류마다 하나씩(+ 대화·월말)
	var keys: Array = ["teach_word/", "teach_pattern/", "recognize/en_ko", "recognize/hear_ko", "recognize/hear_en", "recall/ko_en_choice", "recall/ko_en_type",
		"build/", "listen/choose_ko", "listen/type", "speak/repeat", "speak/substitute", "speak/answer", "speak/intro", "dialogue_script/listen", "dialogue_script/role"]
	var out: Array = []
	for k in keys:
		for e in _all(k).slice(0, 2):
			out.append([k, e])
	return out


func _test_layout() -> void:
	print("[layout: screen %dx%d, scale %s, %s]" % [int(_screen.x), int(_screen.y), str(Ds.font_scale), _scheme])
	var bounds := Rect2(Vector2.ZERO, _screen)
	var min_h: float = min_touch()
	var n_checked: int = 0
	var bad_rect: int = 0
	var bad_small: int = 0
	var bad_wide: int = 0
	var h_scroll: int = 0
	for item in _all_states():
		var key: String = String(item[0])
		var e: Dictionary = item[1]
		var v: CourseExerciseView = await _show(e)
		var sc: Dictionary = scan_layout(v, bounds, min_h)
		n_checked += 1
		bad_rect += int(sc["rect"])
		bad_small += int(sc["small"])
		bad_wide += int(sc["wide"])
		if int(sc["rect"]) + int(sc["small"]) + int(sc["wide"]) > 0:
			print("  layout problem in ", key, ": ", sc)
		await _shot("q_" + key.replace("/", "_"))
		var hb: HScrollBar = v.page.get_h_scroll_bar()
		if hb.visible or hb.max_value - hb.page > 1.0:
			h_scroll += 1
			print("  horizontal scroll in ", key)
		# 답한 뒤(피드백 + [다음]) 모습도
		if not CourseExerciseView.is_info_card(e) and not key.begins_with("speak") and not key.begins_with("dialogue"):
			_solve_any(v, e, false, "layout " + key)
			await _frames(3)
			await _shot("a_" + key.replace("/", "_"))
			var sc2: Dictionary = scan_layout(v, bounds, min_h)
			bad_rect += int(sc2["rect"])
			bad_small += int(sc2["small"])
			bad_wide += int(sc2["wide"])
			if int(sc2["rect"]) + int(sc2["small"]) + int(sc2["wide"]) > 0:
				print("  layout problem after answer in ", key, ": ", sc2)
	ok(n_checked >= 20, "layout checked %d exercise screens" % n_checked)
	ok(bad_rect == 0, "no label/button/box sticks out sideways (%d problems)" % bad_rect)
	ok(bad_small == 0, "every pressable button is at least %.0f high (%d too small)" % [min_h, bad_small])
	ok(bad_wide == 0, "no text needs more width than the screen (get_combined_minimum_size().x <= %.0f, %d too wide)" % [_screen.x, bad_wide])
	ok(h_scroll == 0, "no horizontal scrolling on any screen (%d with a scrollbar)" % h_scroll)
	# 폰 해상도에서 가로 스크롤 없음 + 푸터는 화면 아래에 붙어 있다
	var v2: CourseExerciseView = await _show(_first("recognize/en_ko"))
	var foot: Control = v2.find_child("Footer", true, false)
	ok(foot.visible and absf(foot.get_global_rect().end.y - _screen.y) < 1.5, "the bottom bar sits at the bottom of the screen (%.0f vs %.0f)" % [foot.get_global_rect().end.y, _screen.y])
	# 아주 긴 글(한 줄 300자)도 가로로 넘치지 않는다
	var long_ex: Dictionary = _first("recognize/en_ko").duplicate(true)
	long_ex["prompt"] = "word".repeat(75)
	long_ex["options"] = ["가".repeat(150), "나".repeat(150), "다"]
	long_ex["answer"] = 0
	var v3: CourseExerciseView = await _show(long_ex)
	var sc3: Dictionary = scan_layout(v3, bounds, min_h)
	ok(int(sc3["rect"]) == 0, "300 letter prompt and options stay inside the width (%d outside)" % int(sc3["rect"]))


func _test_keyboard() -> void:
	print("[soft keyboard 300 high]")
	if not phone:
		ok(true, "keyboard test is for the phone run (PC has no soft keyboard)")
		return
	var e: Dictionary = _first("recall/ko_en_type")
	var v: CourseExerciseView = await _show(e)
	PhoneLayout.test_keyboard_height = KEYBOARD_H
	_holder.size = Vector2(_screen.x, _screen.y - KEYBOARD_H)
	await _frames(3)
	PhoneLayout.ensure_visible(v.edit)
	await _frames(3)
	var vis: Rect2 = v.page.get_global_rect()
	var eb: Rect2 = v.edit.get_global_rect()
	var cb: Rect2 = (_button_named("ConfirmBtn") as Button).get_global_rect()
	var limit: float = _screen.y - KEYBOARD_H + 1.0
	ok(vis.end.y <= limit, "with a 300 px keyboard the page ends above it (%.0f <= %.0f)" % [vis.end.y, limit])
	ok(eb.position.y >= vis.position.y - 1.0 and eb.end.y <= vis.end.y + 1.0, "with a 300 px keyboard the input box is in the visible page area")
	ok(cb.end.y <= limit and cb.position.y >= 0.0 and cb.size.y >= min_touch() - 0.5, "with a 300 px keyboard the [확인] button is above the keyboard (%.0f..%.0f)" % [cb.position.y, cb.end.y])
	ok(not (cb.intersects(eb)), "the input box and [확인] do not overlap")
	# 조립 문제도: 타일과 [확인] 이 키보드 위에 보인다
	var vb: CourseExerciseView = await _show(_first("build/"))
	_holder.size = Vector2(_screen.x, _screen.y - KEYBOARD_H)
	await _frames(3)
	var cb2: Rect2 = (_button_named("ConfirmBtn") as Button).get_global_rect()
	ok(cb2.end.y <= limit, "build: [확인] stays above a 300 px keyboard")
	PhoneLayout.test_keyboard_height = -1.0
	_holder.size = _screen
	await _frames(2)


# ---------------------------------------------------------------- 보이는 숫자 (E4a-5, C-15)

func _test_numbers() -> void:
	print("[visible numbers (C-15)]")
	var big: int = 0
	var scanned: int = 0
	for item in _all_states():
		var e: Dictionary = item[1]
		var v: CourseExerciseView = await _show(e)
		var texts: Array = []
		_texts(v, texts)
		scanned += 1
		if has_big_number(texts):
			big += 1
			print("  big number on screen for ", item[0])
		if not CourseExerciseView.is_info_card(e) and not String(item[0]).begins_with("speak") and not String(item[0]).begins_with("dialogue"):
			_solve_any(v, e, true, "numbers " + String(item[0]))
			await _frames(2)
			var t2: Array = []
			_texts(v, t2)
			if has_big_number(t2):
				big += 1
				print("  big number after answer for ", item[0])
	ok(scanned >= 20 and big == 0, "no label or button text has 5 or more digits in a row (%d screens, %d bad)" % [scanned, big])
	# 12345 를 넣은 가짜 화면은 같은 검사에서 실패한다
	var fake_ex: Dictionary = _first("recognize/en_ko").duplicate(true)
	fake_ex["prompt"] = "12345"
	var vf: CourseExerciseView = await _show(fake_ex)
	var tf: Array = []
	_texts(vf, tf)
	fails(has_big_number(tf), "a screen that shows 12345 fails the number check")
	# 화면이 만드는 글에 진행 표시가 없다는 것은 소스 검사에서 본다


# ---------------------------------------------------------------- 소스 검사 (E4a-9, C-4, C-11)

func _func_body(src: String, fname: String) -> String:
	var start: int = src.find("\nfunc " + fname + "(")
	if start < 0:
		return ""
	var end: int = src.find("\nfunc ", start + 5)
	return src.substr(start, (end if end > 0 else src.length()) - start)


func _test_source() -> void:
	print("[source rules]")
	var f: FileAccess = FileAccess.open(VIEW_SRC, FileAccess.READ)
	ok(f != null, "the view source can be read")
	if f == null:
		return
	var src: String = f.get_as_text()
	var forbidden: Array = ["HTTP" + "Request", "shell" + "_open", "request" + "_permission", "Color(" + "\"#", "87" + "70", "87" + "75", "87" + "76",
		"%d" + "/%d", "Lesson" + "View", "norm_" + "answer", ".to_" + "lower("]
	for w in forbidden:
		ok(not src.contains(String(w)), "the view source has no '%s'" % w)
	var emoji: int = 0
	for i in src.length():
		var u: int = src.unicode_at(i)
		if u >= 0x1F000 or (u >= 0x2190 and u <= 0x2BFF) or (u >= 0x25A0 and u <= 0x25FF):
			emoji += 1
	ok(emoji == 0, "the view source has no emoji or shape characters (%d found)" % emoji)
	for fname in ["_judge_choice", "_judge_typed", "_judge_tiles", "_evaluate_speak"]:
		ok(_func_body(src, fname).contains("LessonBuilder.judge("), "%s decides through LessonBuilder.judge" % fname)
	var test_src: String = FileAccess.get_file_as_string("res://tests/course_exercise_view_test.gd")
	ok(not test_src.contains("87" + "70") and not test_src.contains("HTTP" + "Request"), "this test has no forbidden words either")
	# 검사기 자체: 금지어가 든 가짜 소스를 같은 방식으로 훑으면 실패해야 한다
	var fake_src: String = "func x():\n\tvar h = HTTP" + "Request.new()\n"
	fails(fake_src.contains("HTTP" + "Request"), "the source scan finds a forbidden word in a fake source")
	fails(not _func_body("func a():\n\treturn 1\n", "a").contains("LessonBuilder.judge("), "the judge-use scan fails for a function that does not call the judge")
