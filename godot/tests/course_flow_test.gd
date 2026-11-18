extends Node
## v2.0 E4b: CoursePlayer(코스 플레이어) 시험. 서버 없이. 문제는 LessonBuilder 가 k1_mini(K1 빌드 출력)·course_mini 데이터로 실제로 만든 것이다.
##   PC   : godot --headless --path godot res://tests/course_flow_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/course_flow_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark]
## 마지막 줄: "== course_flow: N passed, M failed (presses: P) ==" (실패가 있으면 종료 코드 1)
## 흐름은 전부 실제 버튼의 pressed.emit() 으로 간다(출력의 "press: ..." 줄). 입력칸은 글을 넣고 text_changed 를 낸 뒤 [확인] 버튼을 누른다.
## 말하기는 녹음 부품의 recorded 신호(마이크 대신)로 시작한다. 폰 경로는 자가 평가 버튼, PC 경로는 SpeakDrill.api_hook 의 가짜 /score.
## 검사기(숫자·배치·순서·소스 검사)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다("selfcheck FAIL-as-expected ..." 줄).
## 시험 전용 파일 경로(user://test_e4b_*)만 쓰고 끝에 되돌린다. 소리는 Tts.fetch_hook 이 가로채고 주소는 닫힌 포트(9)다.

const K1_DIR := "res://tests/fixtures/course_builder/k1_mini"
const MINI_DIR := "res://tests/fixtures/course_mini"
const GONE_DIR := "res://tests/fixtures/__not_here__"
const PLAYER_SRC := "res://scripts/practice/course_player.gd"
const SELF_SRC := "res://tests/course_flow_test.gd"
const PROG := "user://test_e4b_progress.json"
const PREFS := "user://test_e4b_prefs.json"
const LOG := "user://test_e4b_studylog.json"
const CS := "user://test_e4b_course.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const STAGE_ORDER := ["intro", "recognize", "recall", "build", "listen", "speak", "dialogue"]

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var tts_calls: Array = []
var requests: Array = []
var score_reply: Variant = {}
var guard_log: Array = []
var finished_log: Array = []
var left_n: int = 0
var _clock: int = 0
var _fin_clock: int = 0
var _hook_fn: Callable = Callable()
var _before: Array = []
var _saved: Dictionary = {}
var _holder: Control = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _screen: Vector2 = PC_SCREEN
var _layout_bad: Dictionary = {"rect": 0, "small": 0, "wide": 0, "n": 0}


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


func _ready() -> void:
	phone = Platform.is_phone()
	_screen = PHONE_SCREEN if phone else PC_SCREEN
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== course_flow start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_before = _user_listing()
	_setup()
	_selfcheck()
	await _test_main_flow()
	await _test_d5_block_contract()
	await _test_listen_recap_blocks()
	await _test_check_and_month()
	await _test_second_data()
	await _test_resume()
	await _test_speak_pc()
	await _test_invalid()
	await _test_numbers_and_layout()
	_test_source()
	_teardown()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_flow: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _setup() -> void:
	_saved = {"prefs": Store.prefs.duplicate(true), "progress": Store.progress.duplicate(true), "progress_path": Store.progress_path,
		"prefs_path": Store.prefs_path, "log_path": StudyLog.path, "cs": CourseStore.path, "base": CourseData.base_dir,
		"api": Api.base_url, "route": Route.mode, "anim": Sheet.animate, "phone_hook": Route.phone_hook}
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	CoursePlayer.guard_hook = Callable(self, "_guard_hook")
	CoursePlayer.clock_hook = Callable(self, "_clock_now")
	Sheet.animate = false
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(_screen)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	SpeakDrill.api_hook = Callable()
	CoursePlayer.guard_hook = Callable()
	CoursePlayer.build_hook = Callable()
	CoursePlayer.clock_hook = Callable()
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
	Sheet.animate = _saved["anim"]


func _rm_all() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


## 새 세계: 기록 없음, 코스 모드, 주어진 데이터 폴더, 말하기는 자가 평가 경로(Route "phone").
func _world(dir: String) -> void:
	_rm_all()
	Store.progress = Progress.blank()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	StudyLog.reset()
	CourseStore.reset_memory()
	CourseStore.set_mode("course")
	CourseData.base_dir = dir
	CourseData.reset()
	CourseFeed.reset()
	CoursePlayer.build_hook = Callable()
	_route(true)
	finished_log = []
	left_n = 0
	guard_log = []
	score_reply = {}
	requests = []
	tts_calls = []
	_clock = 1000000


func _yes() -> bool:
	return true


## 말하기 경로: true = 폰 단독(자가 평가 버튼), false = PC 연결(가짜 /score). PC 창에서 돌려도 폰처럼 만들 수 있게 Route.phone_hook 을 쓴다.
func _route(phone_alone: bool) -> void:
	Route.phone_hook = Callable(self, "_yes") if phone_alone else Callable()
	Route.mode = "phone" if phone_alone else "pc"


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _api_hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	if path == "/score":
		return score_reply
	return {}


func _guard_hook(ex: Dictionary, verdict: Dictionary, cur_o: int) -> void:
	guard_log.append({"id": String(ex.get("id", "")), "type": String(ex.get("type", "")), "ok": bool(verdict.get("ok", false)), "cur_o": cur_o,
		"bad": verdict.get("bad", [])})


func _clock_now() -> int:
	return _clock


func _fake_build(spec: Dictionary, sd: int) -> Variant:
	return _hook_fn.call(spec, sd)


func _use_hook(fn: Callable) -> void:
	_hook_fn = fn
	CoursePlayer.build_hook = Callable(self, "_fake_build")


# ---------------------------------------------------------------- 도우미: 열기·누르기·훑기

func _open(spec: Variant) -> CoursePlayer:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = _screen
	_holder.clip_contents = true
	add_child(_holder)
	var p: CoursePlayer = CoursePlayer.open(_holder, spec)
	p.finished.connect(func(r: Dictionary) -> void: finished_log.append(r))
	p.left.connect(func() -> void: left_n += 1)
	await _frames(3)
	return p


func _btn(p: CoursePlayer, n: String) -> Button:
	var b: Node = p.find_child(n, true, false)
	return b as Button if b is Button else null


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


func _texts(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label or c is Button:
			out.append(str(c.text))
		elif c is RichTextLabel:
			out.append(str(c.text))
		elif c is LineEdit:
			out.append(str(c.placeholder_text))
		_texts(c, out)


func _has_text(root: Node, needle: String) -> bool:
	var all: Array = []
	_texts(root, all)
	for t in all:
		if str(t).contains(needle):
			return true
	return false


func _label_text(p: CoursePlayer, n: String) -> String:
	var l: Node = p.find_child(n, true, false)
	return String(l.text) if l is Label else ""


func _wait_state(v: CourseExerciseView, want: String, frames: int = 40) -> void:
	for i in frames:
		if v.state == want:
			return
		await get_tree().process_frame


func _wait_player(p: CoursePlayer, want: String, frames: int = 40) -> void:
	for i in frames:
		if p.state == want:
			return
		await get_tree().process_frame


func _lessons() -> int:
	var n: int = 0
	var days: Dictionary = StudyLog.snapshot().get("days", {})
	for k in days.keys():
		var per: Dictionary = days[k]
		if per.has("en"):
			n += int((per["en"] as Dictionary).get("n", {}).get("lessons", 0))
	return n


func _review_n() -> int:
	return (Store.progress["review"] as Array).size()


func _review_has(target: String) -> bool:
	for r in Store.progress["review"]:
		if String((r as Dictionary).get("target", "")) == target:
			return true
	return false


func _path_cells() -> int:
	var n: int = 0
	for m in range(1, 13):
		for wk in range(1, 5):
			n += StudyLog.path_done("en", m, wk)
	return n


func _snap() -> Dictionary:
	return {"pos": CourseStore.pos(), "xp": Store.xp("en"), "lessons": _lessons(), "stat": Store.stat("en", "lessons"), "review": _review_n(),
		"cells": _path_cells(), "last": StudyLog.path_last("en"), "blocks": CourseStore.blocks_today()}


## 첫 칸들을 끝낸 것으로 만든다(시험 준비). 흐름 시험이 아니라서 CourseStore 를 직접 부른다.
func _advance_to(w: int, d: int) -> void:
	CourseStore.today_override = Plan.today_days() - 3 ## 준비는 며칠 전에 한 것으로 한다(오늘의 블록 표시를 건드리지 않게)
	for k in range(1, d):
		CourseStore.unit_done({"unit": "new", "w": w, "d": k, "completed": true, "block": "new", "ok": 1, "total": 1})
	CourseStore.today_override = -1


# ---------------------------------------------------------------- 검사기 (일부러 틀린 입력도 본다)

func has_big_number(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	for t in texts:
		if rx.search(str(t)) != null:
			return true
	return false


func has_seconds_text(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d+\\s*초")
	for t in texts:
		if rx.search(str(t)) != null:
			return true
	return false


## 보기 순서·타일 순서가 첫 번째와 다른가.
func order_differs(a: Array, b: Array) -> bool:
	return a != b


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


## 소스 안에 금지 글이 있는 줄 수.
func src_hits(src: String, needles: Array) -> int:
	var n: int = 0
	for line in src.split("\n"):
		for nd in needles:
			if String(line).contains(String(nd)):
				n += 1
				break
	return n


## 이모지·도형 글자가 든 글자 수.
func glyph_hits(src: String) -> int:
	var n: int = 0
	for i in src.length():
		var c: int = src.unicode_at(i)
		if (c >= 0x1F000 and c <= 0x1FAFF) or (c >= 0x2600 and c <= 0x27BF) or (c >= 0x2B00 and c <= 0x2BFF) or c == 0xFE0F:
			n += 1
	return n


func _selfcheck() -> void:
	ok(not has_big_number(["12분 30초", "문제 3/8개", "1234"]), "selfcheck: has_big_number accepts ordinary numbers (4 digits)")
	fails(has_big_number(["걸린 시간 12345"]), "12345 on screen is found by has_big_number")
	fails(has_seconds_text(["걸린 시간 930초"]), "'930초' on screen is found by has_seconds_text")
	ok(not has_seconds_text(["걸린 시간 15분"]), "selfcheck: has_seconds_text accepts '15분'")
	fails(not order_differs(["a", "b", "c"], ["a", "b", "c"]), "the same option order is found by order_differs")
	ok(order_differs(["a", "b", "c"], ["c", "a", "b"]), "selfcheck: order_differs accepts another order")
	var fake_btn := Button.new()
	fake_btn.text = "x"
	fake_btn.disabled = true
	add_child(fake_btn)
	fails(not _ready_btn(fake_btn), "press() refuses a disabled button")
	fails(not _ready_btn(null), "press() refuses a missing button")
	fake_btn.queue_free()
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
	fails(int(fake_small["small"]) > 0, "layout scan finds a button that is too short")
	fails(int(fake_rect["wide"]) > 0, "layout scan finds a label wider than the screen")
	var fake_src: String = "func x():\n\tStudyLog.add_" + "path_lesson(1)\n\tvar h = HTTP" + "Request.new()\n"
	fails(src_hits(fake_src, ["add_" + "path_lesson"]) == 1, "the source scan finds a forbidden call in a fake source")
	fails(glyph_hits("a %s b" % String.chr(0x2605)) == 1, "the glyph scan finds a star")
	ok(glyph_hits("다음  ·  5주 3일") == 0, "selfcheck: the glyph scan accepts the middle dot and Korean")
	# 가드: 안 배운(미래) 낱말을 묻는 문제는 위반으로 판정돼야 한다
	_world(K1_DIR)
	var data: Dictionary = CourseFeed.builder_data()
	ok(not data.is_empty() and data.get("_idx") is Dictionary, "k1_mini course data feeds the builder")
	var bad_ex: Dictionary = {"type": "recognize", "id": "x:1:2:rec:w0301:en_ko", "mode": "en_ko", "item": "w0301", "prompt": "hello", "tts": "hello",
		"options": ["a", "b"], "answer": 0}
	var verdict: Dictionary = LexiconGuard.check_exercise_set(bad_ex, 12, {}, data["_idx"])
	fails(not bool(verdict.get("ok", false)), "the guard finds a question about a word of week 4 on day 1 of week 1")


# ---------------------------------------------------------------- 문제 풀기(버튼만)

func _type_into(v: CourseExerciseView, txt: String) -> void:
	v.edit.text = txt
	v.edit.text_changed.emit(txt) # 키를 눌렀을 때와 같은 신호


func _tile_texts(v: CourseExerciseView) -> Array:
	var out: Array = []
	for b in v.tile_btns:
		out.append(String((b as Button).text))
	return out


func _press_tile_for(v: CourseExerciseView, token: String, label: String) -> bool:
	for i in v.tile_btns.size():
		var b: Button = v.tile_btns[i]
		if String(b.text) == token and not b.disabled:
			press(b, "Tile%d '%s' (%s)" % [i, token, label])
			return true
	return false


## 지금 문제를 맞게(right) 또는 틀리게 푼다. 돌려주는 값: 실제로 나온 결과(view.result).
func _answer_current(p: CoursePlayer, right: bool, label: String) -> Dictionary:
	var v: CourseExerciseView = p.view
	var e: Dictionary = v.ex
	match String(e["type"]):
		"recognize", "listen", "recall":
			if e.has("options"):
				var n: int = (e["options"] as Array).size()
				var pick: int = int(e["answer"]) if right else (int(e["answer"]) + 1) % n
				press(v.option_btns[pick], "Opt%d (%s)" % [pick, label])
				press(_btn(p, "ConfirmBtn"), "ConfirmBtn (%s)" % label)
			else:
				_type_into(v, String((e["accept"] as Array)[0]) if right else "qqxx")
				press(_btn(p, "ConfirmBtn"), "ConfirmBtn (%s)" % label)
		"build":
			var ans: Array = e["answer"]
			var toks: Array = ans if right else ans.slice(0, maxi(0, ans.size() - 1))
			for t in toks:
				_press_tile_for(v, String(t), label)
			press(_btn(p, "ConfirmBtn"), "ConfirmBtn (%s)" % label)
		"speak":
			if right:
				v.drill.recorder.recorded.emit(FAKE_REC)
				await _frames(3)
				press(_find_text_button(v, "잘했어요"), "잘했어요 self rating (%s)" % label)
			else:
				press(_btn(p, "SkipBtn"), "SkipBtn (%s)" % label)
	await _wait_state(v, "answered")
	return v.result


func _find_text_button(root: Node, t: String) -> Button:
	for c in root.get_children():
		if c is Button and str(c.text) == t:
			return c
		var f: Button = _find_text_button(c, t)
		if f != null:
			return f
	return null


## 문제 종류 열쇠(계획표용).
func _class_of(e: Dictionary) -> String:
	var t: String = String(e["type"])
	var m: String = String(e.get("mode", ""))
	if t == "recall":
		return "rcc" if m == "ko_en_choice" else "rct"
	return {"recognize": "rec", "build": "bld", "listen": "lis", "speak": "spk"}.get(t, "other")


## 한 단위를 끝까지 푼다. plan = {종류: [그 종류 n 번째 문제를 처음 몇 번 틀릴지(99 = 끝까지 틀림)]}. 돌려주는 값: 문제 하나하나의 기록.
func _play_unit(p: CoursePlayer, plan: Dictionary, label: String, step_ms: int = 10000) -> Array:
	var log: Array = []
	var want: Dictionary = {} ## 원래 문제 id -> 틀릴 횟수
	var ordinal: Dictionary = {}
	var guard: int = 0
	var shown: int = 0
	while p.state == "run" and guard < 400:
		guard += 1
		shown += 1
		var ent: Dictionary = p.current_entry()
		var v: CourseExerciseView = p.view
		var e: Dictionary = v.ex
		var sc: Dictionary = scan_layout(p, Rect2(Vector2.ZERO, _screen), min_touch())
		_layout_bad["rect"] += int(sc["rect"])
		_layout_bad["small"] += int(sc["small"])
		_layout_bad["wide"] += int(sc["wide"])
		_layout_bad["n"] += 1
		if CourseExerciseView.is_info_card(e):
			_fin_clock = _clock
			press(_btn(p, "NextBtn"), "NextBtn (%s card %s)" % [label, String(e.get("type", ""))])
			_clock += step_ms
			await _frames(1)
			continue
		var rc: Dictionary = p.recs[int(ent["rec"])]
		var base: String = String(rc["id"])
		var attempt: int = int(ent["attempt"])
		var cls: String = _class_of(e)
		if attempt == 0:
			var k: int = int(ordinal.get(cls, 0))
			ordinal[cls] = k + 1
			var lst: Array = plan.get(cls, [])
			var w_n: int = int(lst[k]) if k < lst.size() else 0
			if cls == "bld" and (e["answer"] as Array).size() < 2:
				w_n = 0
			want[base] = w_n
		var right: bool = attempt >= int(want.get(base, 0))
		var order: Array = _tile_texts(v) if String(e["type"]) == "build" else ((e["options"] as Array).map(func(o: Variant) -> String: return String(o)) if e.has("options") else [])
		var ans_idx: int = int(e["answer"]) if e.has("options") and e["answer"] is int else -1
		var res: Dictionary = await _answer_current(p, right, "%s %s#%d %s" % [label, cls, attempt, "right" if right else "wrong"])
		ok(v.state == "answered" and v.feedback != null and v.feedback.is_visible_in_tree(), "%s %s#%d: the feedback is visible" % [label, cls, attempt])
		ok(_ready_btn(_btn(p, "NextBtn")), "%s %s#%d: [다음] is visible and enabled" % [label, cls, attempt])
		var fb_ok: bool = bool(v.feedback.get_meta("ok", false)) if v.feedback != null else false
		ok(fb_ok == bool(res.get("ok", false)), "%s %s#%d: the feedback mark agrees with the result" % [label, cls, attempt])
		log.append({"base": base, "attempt": attempt, "cls": cls, "type": String(e["type"]), "stage": String(ent["stage"]), "order": order, "ans": ans_idx,
			"ok": bool(res.get("ok", false)), "gave_up": bool(res.get("gave_up", false)), "ex": rc["ex"], "id": String(e.get("id", ""))})
		_fin_clock = _clock
		press(_btn(p, "NextBtn"), "NextBtn (%s %s#%d)" % [label, cls, attempt])
		_clock += step_ms
		await _frames(1)
	ok(guard < 400, "%s: the unit ended (%d screens)" % [label, shown])
	return log


## 풀이 기록으로 숙달 루프를 단언한다. 돌려주는 값: 처음 틀린 원래 문제 수 등.
func _check_loop(log: Array, label: String) -> Dictionary:
	var by_base: Dictionary = {}
	var seq: Array = []
	for r in log:
		if not by_base.has(r["base"]):
			by_base[r["base"]] = []
			seq.append(r["base"])
		(by_base[r["base"]] as Array).append(r)
	var first_wrong: int = 0
	var order_checks: int = 0
	var order_bad: int = 0
	var three: int = 0
	var stages_ok: bool = true
	var last_stage_i: int = -1
	for r in log:
		var si: int = STAGE_ORDER.find(String(r["stage"]))
		if si < last_stage_i:
			stages_ok = false
		last_stage_i = maxi(last_stage_i, si)
	for b in seq:
		var lst: Array = by_base[b]
		var first: Dictionary = lst[0]
		if not bool(first["ok"]):
			first_wrong += 1
		ok(lst.size() <= 3, "%s: %s was shown at most 3 times (1 + 2 retries): %d" % [label, b, lst.size()])
		if lst.size() == 3:
			three += 1
		for i in range(1, lst.size()):
			ok(not bool((lst[i - 1] as Dictionary)["ok"]) and not bool((lst[i - 1] as Dictionary)["gave_up"]), "%s: %s #%d came back only after a wrong, not given-up answer" % [label, b, i])
			var cur: Dictionary = lst[i]
			if String(cur["type"]) == "build" and (cur["order"] as Array).size() < 3:
				continue # 타일이 2개뿐이면 순서가 둘뿐이라 다르게 만들 수 없다
			if (cur["order"] as Array).is_empty():
				continue # 쓰기 문제는 보기도 타일도 없다
			order_checks += 1
			if not order_differs(first["order"], cur["order"]):
				order_bad += 1
				print("  same order on retry ", b, " #", i, " ", cur["order"])
			if cur["ans"] >= 0 and i == 1 and int(cur["ans"]) == int(first["ans"]):
				order_bad += 1
				print("  same answer position on retry ", b)
		if lst.size() < 3 and not bool((lst[lst.size() - 1] as Dictionary)["ok"]) and not bool((lst[lst.size() - 1] as Dictionary)["gave_up"]):
			ok(false, "%s: %s ended wrong before the 3rd show" % [label, b])
	ok(stages_ok, "%s: retries stay inside their stage (stage order never goes back)" % label)
	ok(order_checks >= 1 and order_bad == 0, "%s: every retry shows another option/tile order than the first (%d checked, %d same)" % [label, order_checks, order_bad])
	return {"first_wrong": first_wrong, "three": three, "originals": seq.size(), "by_base": by_base}


# ---------------------------------------------------------------- E4b-2 / 3 / 4 / 8: 하루 한 단위 끝까지

func _test_main_flow() -> void:
	print("[E4b-2: k1_mini new w1 d3, buttons only, with wrong answers and the mastery loop]")
	_world(K1_DIR)
	_advance_to(1, 3)
	eq(CourseStore.pos(), {"w": 1, "d": 3}, "the course is at week 1 day 3")
	var before: Dictionary = _snap()
	var unit_cards: Array = CourseCards.unit_cards(1, 3)
	var presses0: int = presses
	var t0: int = _clock
	var p: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 3, "seed": 7})
	ok(p.state == "run" and p.view != null and p.view.visible, "the player is running and shows the first screen")
	ok(_label_text(p, "TitleLabel").contains("새 내용") and _label_text(p, "TitleLabel").contains("1주 3일"), "the top bar says what is played: %s" % _label_text(p, "TitleLabel"))
	ok(_label_text(p, "ProgressLabel").begins_with("문제 0/"), "progress is made by progress_label: %s" % _label_text(p, "ProgressLabel"))
	ok(_ready_btn(_btn(p, "BackBtn")), "the back button is there")
	var first_card: Dictionary = p.view.ex
	eq(String(first_card.get("type", "")), "teach_word", "the unit starts with a word card (intro)")
	var plan: Dictionary = {"rec": [1, 2, 99], "rcc": [2], "rct": [1], "bld": [1, 2], "lis": [1], "spk": [1]}
	var log: Array = await _play_unit(p, plan, "w1d3")
	var t1: int = _fin_clock
	var loop: Dictionary = _check_loop(log, "w1d3")
	ok(presses - presses0 >= 40, "at least 40 button presses in this unit (%d)" % (presses - presses0))
	var by_base: Dictionary = loop["by_base"]
	var n_orig: int = int(loop["originals"])
	ok(n_orig >= 30, "the unit had %d questions (without the cards)" % n_orig)
	var first_wrong: int = int(loop["first_wrong"])
	ok(first_wrong >= 8, "wrong answers were planned and happened (%d questions wrong the first time)" % first_wrong)
	ok(int(loop["three"]) >= 1, "a question that stays wrong is shown exactly 3 times (1 + 2 retries): %d" % int(loop["three"]))
	ok(p.retries_made >= 10, "the mastery loop made retries (%d)" % p.retries_made)
	# 정확히: 틀리게 풀기로 한 문제는 (1 + min(틀릴 횟수, 2)) 번 나온다(말하기 포기는 다시 내지 않는다)
	var exact_bad: int = 0
	for b in by_base.keys():
		var lst: Array = by_base[b]
		var wrongs: int = 0
		for r in lst:
			if not bool(r["ok"]):
				wrongs += 1
		var expect_n: int = 1 if bool((lst[0] as Dictionary)["gave_up"]) else mini(wrongs, 2) + 1
		if lst.size() != expect_n:
			exact_bad += 1
			print("  off: ", b, " shown ", lst.size(), " wrong ", wrongs)
	ok(exact_bad == 0, "every question was shown 1 + (times wrong, at most 2) times (%d off)" % exact_bad)
	# 결과 카드
	ok(p.state == "result", "after the last answer the player shows the result card")
	var rb: Node = p.find_child("ResultBox", true, false)
	var db: Button = _btn(p, "DoneBtn")
	ok(rb != null and (rb as Control).is_visible_in_tree() and _ready_btn(db), "result card visible: true (ResultBox and [완료] are visible)")
	print("result card visible: ", rb != null and (rb as Control).is_visible_in_tree())
	ok(not p.back_btn.is_visible_in_tree(), "the back button is gone on the result card")
	var res: Dictionary = p.result
	var never_right: int = 0
	var first_try_n: int = 0
	for b in by_base.keys():
		var lst2: Array = by_base[b]
		var last_ok: bool = bool((lst2[lst2.size() - 1] as Dictionary)["ok"])
		if not last_ok:
			never_right += 1
		if bool((lst2[0] as Dictionary)["ok"]):
			first_try_n += 1
	eq(int(res["total"]), n_orig, "result.total = number of questions")
	eq(int(res["ok"]), n_orig - never_right, "result.ok = questions that were right in the end")
	ok(int(res["first_try"]) <= n_orig - first_wrong and int(res["first_try"]) >= n_orig - first_wrong - 6, "result.first_try counts the right-on-first-show questions (%d of %d)" % [int(res["first_try"]), n_orig])
	eq(String(res["unit"]), "new", "result.unit is new")
	eq(String(res["block"]), "new", "result.block is new (CourseStore contract)")
	ok(bool(res["completed"]), "result.completed is true")
	eq(int(res["seconds"]), (t1 - t0) / 1000, "result.seconds follows the clock the test controls")
	var wrong_keys: Dictionary = {}
	for r in res["wrong"]:
		wrong_keys["%s|%s" % [r["item"], r["type"]]] = true
	ok(wrong_keys.size() >= 5, "result.wrong lists the items that were wrong (%d)" % wrong_keys.size())
	eq((res["words_new"] as Array).size(), 4, "result.words_new = the 4 words of the intro cards")
	# E4b-8: 결과 카드 글
	var score_line: String = _label_text(p, "ScoreLine")
	ok(score_line.contains(CourseModel.progress_label("questions", int(res["ok"]), int(res["total"]))), "ScoreLine uses progress_label: %s" % score_line)
	var time_line: String = _label_text(p, "TimeLine")
	ok(time_line.contains(CourseModel.fmt_minutes(int(res["seconds"]))), "TimeLine uses fmt_minutes: %s" % time_line)
	ok(not time_line.contains(str(int(res["seconds"]))) or int(res["seconds"]) < 100, "TimeLine does not show the seconds value")
	var all_text: Array = []
	_texts(p, all_text)
	ok(not has_big_number(all_text), "no screen text has 5 or more digits in a row")
	ok(not has_seconds_text(all_text), "no screen text shows seconds ('N초')")
	ok(not _has_text(p, "버려") and not _has_text(p, "건너뛰"), "the result card does not show dropped questions")
	# E4b-4: 배운 것만
	var shown_n: int = guard_log.size()
	ok(shown_n >= n_orig + 4 + int(res["retries"]), "the guard hook saw every screen (%d calls)" % shown_n)
	var viol: int = 0
	for g in guard_log:
		if not bool(g["ok"]):
			viol += 1
	eq(viol, 0, "the guard hook found 0 violations on real builder output")
	eq(p.dropped, 0, "dropped = 0 on real builder output")
	eq(int(res["dropped"]), 0, "result.dropped = 0")
	ok(p.seen.size() == 4 and p.seen.has("w0007"), "seen = the words whose cards were shown (%s)" % str(p.seen.keys()))
	# E4b-3: 기록
	eq(CourseStore.pos(), {"w": 1, "d": 4}, "CourseStore.pos moved to the next cell (week 1 day 4)")
	var st: Dictionary = res["store"]
	ok(bool(st.get("advanced", false)) and bool(st.get("saved", false)), "unit_done advanced the cell and saved")
	eq(_lessons(), int(before["lessons"]) + 1, "StudyLog lesson count +1")
	eq(Store.stat("en", "lessons"), int(before["stat"]) + 1, "Store lessons stat +1")
	eq(Store.xp("en"), int(before["xp"]) + int(res["ok"]) * 10, "XP = ok x 10")
	ok(Store.did_day(Plan.today_days(), "en"), "mark_today: today counts as a study day")
	ok(not StudyLog.resume().is_empty() and String(StudyLog.resume().get("view", "")) == "lesson", "note_resume remembers the lesson screen")
	eq(_path_cells(), int(before["cells"]), "no old-path lesson was recorded (path cells unchanged)")
	eq(StudyLog.path_last("en"), before["last"], "the old path's last cell is unchanged")
	ok(bool(CourseStore.blocks_today().get("new", false)), "the new block is marked today")
	var wrong_sent: Dictionary = {}
	for r in log:
		if bool(r["attempt"] == 0) and not bool(r["ok"]):
			var ex: Dictionary = r["ex"]
			var tgt: String = ""
			match String(r["type"]):
				"build":
					tgt = " ".join(PackedStringArray((ex["answer"] as Array).map(func(t: Variant) -> String: return String(t))))
				"listen":
					tgt = String(ex.get("tts", ""))
				"speak":
					tgt = String(ex["target"]) if String(ex.get("mode", "")) == "repeat" else String((ex["accept"] as Array)[0])
			if tgt != "":
				wrong_sent[tgt] = true
	var unit_targets: Array = unit_cards.map(func(c: Variant) -> String: return String((c as Dictionary)["target"]))
	var extra_cards: int = 0
	for t in wrong_sent.keys():
		if not unit_targets.has(t):
			extra_cards += 1
	ok(unit_cards.size() >= 5, "the day has %d review cards (4 words + the pattern frame)" % unit_cards.size())
	eq(int(res["cards_unit"]), unit_cards.size(), "new review cards from the day = active words + pattern frames")
	eq(int(res["cards_wrong"]), extra_cards, "wrong sentences became review cards (%d)" % extra_cards)
	eq(_review_n(), int(before["review"]) + unit_cards.size() + extra_cards, "the review list grew by exactly those cards")
	for c in unit_cards:
		ok(_review_has(String((c as Dictionary)["target"])), "review card exists: %s" % String((c as Dictionary)["target"]))
	var some_wrong_build: String = ""
	for t in wrong_sent.keys():
		some_wrong_build = String(t)
		break
	ok(some_wrong_build == "" or _review_has(some_wrong_build), "a wrong sentence is in the review list: %s" % some_wrong_build)
	var cards_line: String = _label_text(p, "CardsLine")
	ok(cards_line.contains(CourseModel.progress_label("cards", int(res["cards_added"]), 0)), "CardsLine uses progress_label: %s" % cards_line)
	ok(_label_text(p, "NextLine").contains("1주 4일"), "NextLine tells the next cell: %s" % _label_text(p, "NextLine"))
	# [완료] 는 한 번만 finished 를 낸다
	press(_btn(p, "DoneBtn"), "DoneBtn (w1d3)")
	eq(finished_log.size(), 1, "finished was emitted once")
	if _ready_btn(_btn(p, "DoneBtn")):
		press(_btn(p, "DoneBtn"), "DoneBtn again")
	eq(finished_log.size(), 1, "a second press of [완료] does not emit finished again")
	eq(int((finished_log[0] as Dictionary)["total"]), n_orig, "finished carries the result")
	# 같은 칸을 다시 해도 카드는 또 늘지 않고 칸은 그대로
	var again: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 3, "seed": 9})
	var log2: Array = await _play_unit(again, {}, "w1d3 again")
	ok(again.state == "result", "playing the same cell again ends with a result card")
	eq(int(again.result["cards_unit"]), 0, "the day's cards are not added twice")
	eq(CourseStore.pos(), {"w": 1, "d": 4}, "an earlier cell played again keeps pos")
	eq(int(again.result["retries"]), 0, "all right -> no retry")
	ok(log2.size() >= 30, "the second run answered %d questions" % log2.size())


func _test_d5_block_contract() -> void:
	print("[D5: block \"new\" finishes the cell, block \"speak\" does not]")
	_world(K1_DIR)
	_advance_to(1, 5)
	eq(CourseStore.pos(), {"w": 1, "d": 5}, "the course is at week 1 day 5")
	var p1: CoursePlayer = await _open({"kind": "speak", "w": 1, "d": 5, "block": "speak", "seed": 3})
	var plan: Dictionary = {}
	await _play_unit(p1, plan, "d5 speak block")
	eq(String(p1.result["block"]), "speak", "the daily speaking block sends block speak")
	eq(CourseStore.pos(), {"w": 1, "d": 5}, "block speak on D5 does not finish the cell (pos stays on D5)")
	ok(bool(CourseStore.blocks_today().get("speak", false)) and not bool(CourseStore.blocks_today().get("new", false)), "only the speak block is marked")
	var p2: CoursePlayer = await _open({"kind": "speak", "w": 1, "d": 5, "block": "new", "seed": 4})
	await _play_unit(p2, {}, "d5 new unit")
	eq(String(p2.result["block"]), "new", "the D5 main unit (unit speak) sends block new")
	eq(String(p2.result["unit"]), "speak", "its unit is still speak")
	eq(CourseStore.pos(), {"w": 1, "d": 6}, "block new on D5 finished the cell: pos is now week 1 day 6")
	ok(bool(CourseStore.blocks_today().get("new", false)), "the new block is marked")
	eq(p2.result["cards_unit"], 0, "a speak unit adds no day cards")
	# block 을 빼면 kind 로 정한다: speak -> speak (칸을 끝내지 않는다)
	var p3: CoursePlayer = await _open({"kind": "speak", "w": 1, "d": 6, "seed": 5})
	eq(p3.block, "speak", "without block a speak unit is the speaking block")
	p3.queue_free()


func _test_listen_recap_blocks() -> void:
	print("[listen unit with the mastery loop, recap unit]")
	_world(K1_DIR)
	var snap: Dictionary = _snap()
	var p: CoursePlayer = await _open({"kind": "listen", "w": 1, "d": 3, "seed": 6})
	ok(p.state == "run" and p.kind == "listen" and p.block == "listen", "a listen unit starts with block listen")
	var log: Array = await _play_unit(p, {"lis": [1, 2]}, "listen")
	var loop: Dictionary = _check_loop(log, "listen")
	ok(p.retries_made >= 3, "the listen unit retried its wrong questions (%d retries)" % p.retries_made)
	eq(String(p.result["block"]), "listen", "result.block is listen")
	ok(bool(CourseStore.blocks_today().get("listen", false)), "the listen block is marked")
	eq(CourseStore.pos(), snap["pos"], "a listen unit never moves pos")
	eq(_lessons(), int(snap["lessons"]) + 1, "the listen unit counts as one lesson")
	eq(int(p.result["cards_unit"]), 0, "a listen unit adds no day cards")
	ok(int(loop["originals"]) == 8, "the listen unit has 8 questions (%d)" % int(loop["originals"]))
	press(_btn(p, "DoneBtn"), "DoneBtn (listen)")
	# 복귀 점검(recap): 한 번만 낸다, 새 내용 블록만 표시하고 칸은 끝내지 않는다
	var r: CoursePlayer = await _open({"kind": "recap", "w": 2, "d": 1, "seed": 8})
	ok(r.state == "run" and r.kind == "recap", "a recap unit runs")
	var rlog: Array = await _play_unit(r, {"rec": [1], "rcc": [1], "lis": [1], "bld": [1], "spk": [1]}, "recap")
	eq(r.retries_made, 0, "a recap unit never repeats a question")
	ok(rlog.size() >= 4, "the recap answered %d questions" % rlog.size())
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "a recap unit never finishes a cell")
	ok(bool(CourseStore.blocks_today().get("new", false)), "the recap marks the new block")
	ok(int(r.result["ok"]) < int(r.result["total"]) or rlog.size() < 5, "the recap result counts the wrong answers")


func _test_check_and_month() -> void:
	print("[check unit (weekly check) and month unit]")
	_world(K1_DIR)
	_advance_to(1, 6)
	var snap: Dictionary = _snap()
	# 첫 점검: 모두 틀림 -> 통과 못 함, 칸 그대로, 다시 내지 않음
	var bad_plan: Dictionary = {"lis": [99, 99, 99, 99, 99], "rct": [99, 99, 99], "bld": [99, 99], "spk": [99, 99]}
	var pf: CoursePlayer = await _open({"kind": "check", "w": 1, "d": 6, "seed": 11})
	ok(pf.state == "run" and pf.kind == "check", "a check unit runs")
	var flog: Array = await _play_unit(pf, bad_plan, "check fail")
	eq(pf.retries_made, 0, "a check never repeats a question")
	eq(flog.size(), (flog.filter(func(r: Variant) -> bool: return int((r as Dictionary)["attempt"]) == 0)).size(), "every check question was shown once")
	ok(not bool(pf.result["pass"]), "the check with wrong answers is not passed")
	eq(CourseStore.pos(), {"w": 1, "d": 6}, "a failed first check keeps the cell open")
	eq(int(CourseStore.week_state(1).get("tries", 0)), 1, "the check try was recorded (tries 1)")
	ok(_has_text(pf, "통과선"), "the failed check card explains the pass line")
	eq(_lessons(), int(snap["lessons"]) + 1, "the check counts as a lesson")
	press(_btn(pf, "DoneBtn"), "DoneBtn (check fail)")
	# 두 번째 점검: 한 문제만 틀림 -> 통과, 칸이 끝남
	var pp: CoursePlayer = await _open({"kind": "check", "w": 1, "d": 6, "seed": 12})
	var plog: Array = await _play_unit(pp, {"lis": [1]}, "check pass")
	ok(bool(pp.result["pass"]), "the check with 1 wrong answer is passed (>= 80%%): %d%%" % int(pp.result["pct"]))
	eq(CourseStore.pos(), {"w": 1, "d": 7}, "a passed check finishes week 1 day 6 (pos is day 7)")
	ok(plog.size() >= 8, "the check had %d questions" % plog.size())
	ok(_has_text(pp, "통과했어요"), "the passed check card says so")
	var spk_state: String = String(CourseStore.week_state(1).get("speak", ""))
	ok(spk_state == "unverified", "self-rated speaking is 'unverified' in the check record: %s" % spk_state)
	press(_btn(pp, "DoneBtn"), "DoneBtn (check pass)")
	# 월말 말하기: month_done 으로 간다, 칸은 안 움직인다
	var pm: CoursePlayer = await _open({"kind": "month", "w": 4, "d": 6, "seed": 13})
	ok(pm.state == "run" and pm.kind == "month", "a month unit runs")
	var mlog: Array = await _play_unit(pm, {}, "month")
	eq(pm.retries_made, 0, "a month unit never repeats a question")
	ok(mlog.size() >= 4, "the month unit had %d questions" % mlog.size())
	var ms: Dictionary = CourseStore.month_state(1)
	eq(int(ms.get("score", -1)), 100, "month_done recorded the score (all right = 100)")
	eq(String(ms.get("mode", "")), "self", "self-rated speaking is recorded as mode self")
	eq(CourseStore.pos(), {"w": 1, "d": 7}, "a month unit never moves pos")
	ok(bool(pm.result["pass"]) and _has_text(pm, "통과"), "the month card says passed")


func _test_second_data() -> void:
	print("[E4b-2 with the second data set: course_mini new w1 d4 (pattern + dialogue)]")
	_world(MINI_DIR)
	_advance_to(1, 4)
	var before: Dictionary = _snap()
	var unit_cards: Array = CourseCards.unit_cards(1, 4)
	var presses0: int = presses
	var p: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 4, "seed": 21})
	ok(p.state == "run", "course_mini builds a unit for week 1 day 4")
	var log: Array = await _play_unit(p, {"rec": [1, 1], "rcc": [1], "bld": [1], "lis": [1]}, "mini")
	var loop: Dictionary = _check_loop(log, "mini")
	ok(presses - presses0 >= 40, "course_mini unit: at least 40 presses (%d)" % (presses - presses0))
	ok(p.state == "result" and _btn(p, "DoneBtn") != null, "course_mini: the result card is shown")
	eq(CourseStore.pos(), {"w": 1, "d": 5}, "course_mini: pos moved to week 1 day 5")
	eq(int(p.result["cards_unit"]), unit_cards.size(), "course_mini: day cards = %d" % unit_cards.size())
	ok(unit_cards.size() >= 4, "course_mini: the day has words and a pattern frame (%d cards)" % unit_cards.size())
	eq(_lessons(), int(before["lessons"]) + 1, "course_mini: lesson +1")
	eq(_path_cells(), int(before["cells"]), "course_mini: no old-path record")
	var viol: int = 0
	for g in guard_log:
		if not bool(g["ok"]):
			viol += 1
	eq(viol, 0, "course_mini: 0 guard violations on what was shown (%d screens)" % guard_log.size())
	ok(int(loop["originals"]) >= 20, "course_mini: %d questions" % int(loop["originals"]))
	press(_btn(p, "DoneBtn"), "DoneBtn (mini)")


# ---------------------------------------------------------------- E4b-5 중단·재개

## 짧은 단위: 소개 카드 전부 + 문제 n_q 개(진짜 빌더 출력의 앞부분).
func _short(spec: Dictionary, sd: int, n_q: int) -> Dictionary:
	var r: Dictionary = CourseFeed.build_unit(spec, sd)
	var out: Array = []
	var q: int = 0
	for e in r["exercises"]:
		if CourseExerciseView.is_info_card(e):
			out.append(e)
		elif q < n_q:
			out.append(e)
			q += 1
	r["exercises"] = out
	return r


func _short_2(spec: Dictionary, sd: int) -> Dictionary:
	return _short(spec, sd, 2)


func _test_resume() -> void:
	print("[E4b-5: leave sheet, continue, quit, android back, app pause]")
	_world(K1_DIR)
	_use_hook(Callable(self, "_short_2"))
	var snap: Dictionary = _snap()
	_clock = 5000000
	var p: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	_clock += 60000
	# 소개 카드를 모두 넘기고 첫 문제로
	var guard: int = 0
	while p.state == "run" and CourseExerciseView.is_info_card(p.view.ex) and guard < 20:
		guard += 1
		press(_btn(p, "NextBtn"), "NextBtn (resume: card)")
		await _frames(1)
	ok(p.state == "run" and not CourseExerciseView.is_info_card(p.view.ex), "now at the first question")
	var ex_id: String = String(p.view.ex.get("id", ""))
	press(p.view.option_btns[1], "Opt1 (resume: pick without confirm)")
	eq(p.view.picked, 1, "an option is picked")
	# 뒤로 -> 확인 시트
	press(_btn(p, "BackBtn"), "BackBtn (resume)")
	await _frames(3)
	var sh: Sheet = p.leave_sheet()
	ok(sh != null and sh.buttons.has("continue") and sh.buttons.has("quit"), "the back button opens a sheet with [계속하기] and [그만하기]")
	ok(Sheet.is_open(), "the sheet is open")
	_clock += 180000
	press(sh.buttons["continue"], "계속하기 (leave sheet)")
	await _frames(3)
	ok(p.leave_sheet() == null and not Sheet.is_open(), "[계속하기] closes the sheet")
	eq(String(p.view.ex.get("id", "")), ex_id, "[계속하기] keeps the same question")
	eq(p.view.picked, 1, "[계속하기] keeps the choice that was picked")
	ok(p.state == "run" and left_n == 0, "the player is still running, left was not emitted")
	_clock += 60000
	# 앱 일시 정지 -> 복귀: 같은 문제
	p.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_clock += 300000
	p.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(2)
	eq(String(p.view.ex.get("id", "")), ex_id, "after pause and resume it is the same question")
	eq(p.view.picked, 1, "after pause and resume the choice is still picked")
	ok(p.state == "run", "after pause and resume the player still runs")
	# 이어서 끝까지: 시계는 멈춘 동안(시트 3분 + 일시 정지 5분)을 뺀다 = 2분
	press(_btn(p, "ConfirmBtn"), "ConfirmBtn (resume: first question)")
	press(_btn(p, "NextBtn"), "NextBtn (resume: first question)")
	await _frames(1)
	await _play_unit(p, {}, "resume rest", 0)
	ok(p.state == "result", "the short unit ended with a result card")
	eq(int(p.result["seconds"]), 120, "paused time (sheet and app pause) is not counted: 120 seconds")
	ok(_label_text(p, "TimeLine").contains("2분"), "TimeLine says 2분: %s" % _label_text(p, "TimeLine"))
	press(_btn(p, "DoneBtn"), "DoneBtn (resume)")
	# 그만하기: 기록이 없다
	_world(K1_DIR)
	_use_hook(Callable(self, "_short_2"))
	snap = _snap()
	var q: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	press(_btn(q, "NextBtn"), "NextBtn (quit test: card)")
	await _frames(1)
	press(_btn(q, "BackBtn"), "BackBtn (quit test)")
	await _frames(3)
	var sh2: Sheet = q.leave_sheet()
	ok(sh2 != null, "the sheet opens again")
	press(sh2.buttons["quit"], "그만하기 (leave sheet)")
	await _frames(3)
	eq(left_n, 1, "[그만하기] emits left once")
	eq(q.state, "left", "the player state is left")
	eq(_snap(), snap, "[그만하기] recorded nothing (pos, XP, lessons, cards, old path, blocks)")
	ok(q.result.is_empty() and finished_log.is_empty(), "[그만하기] made no result and no finished")
	eq(Store.xp("en"), 0, "no XP was given")
	# 안드로이드 뒤로 가기: 첫 번째는 시트, 두 번째는 시트 닫기
	var a: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	ok(a.go_back(), "go_back handles the first press (opens the sheet)")
	await _frames(3)
	ok(a.leave_sheet() != null, "the first back press asks")
	ok(a.go_back(), "go_back handles the second press")
	await _frames(3)
	ok(a.leave_sheet() == null and a.state == "run", "the second back press closes the sheet and keeps playing")
	a.queue_free()
	await _frames(2)
	# 결과 카드에서 뒤로 가기는 [완료]
	var b: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	var blog: Array = await _play_unit(b, {}, "back test")
	ok(b.state == "result" and blog.size() == 2, "a short unit reached the result card")
	finished_log = []
	ok(b.go_back(), "go_back on the result card is handled")
	eq(finished_log.size(), 1, "go_back on the result card finishes the player")
	CoursePlayer.build_hook = Callable()


# ---------------------------------------------------------------- E4b-6 말하기 단계

func _score(transcript: String, score: float) -> Dictionary:
	return {"transcript": transcript, "units": [{"w": "x", "ok": true}], "score": score, "lang": "en"}


func _three_speak(spec: Dictionary, sd: int) -> Dictionary:
	var r: Dictionary = CourseFeed.build_unit(spec, sd)
	var out: Array = []
	for e in r["exercises"]:
		if String(e.get("type", "")) == "speak" and out.size() < 3:
			out.append(e)
	r["exercises"] = out
	return r


func _record_and_wait(p: CoursePlayer, want: String) -> void:
	p.view.drill.recorder.recorded.emit(FAKE_REC)
	await _wait_state(p.view, want)


func _test_speak_pc() -> void:
	print("[E4b-6: speaking on the PC path (fake /score) and the phone path (self rating)]")
	_world(K1_DIR)
	_route(false)
	ok(not SelfRatePanel.needed(), "the score engine is reachable in this test (no self rating)")
	_use_hook(Callable(self, "_three_speak"))
	var p: CoursePlayer = await _open({"kind": "speak", "w": 2, "d": 2, "block": "speak", "seed": 5})
	ok(p.state == "run" and p.queue.size() == 3, "three speaking questions")
	var e1: Dictionary = p.view.ex
	var t1: String = String(e1["target"]) if String(e1["mode"]) == "repeat" else String((e1["accept"] as Array)[0])
	# 1: 합격
	requests = []
	score_reply = _score(t1, 92.0)
	await _record_and_wait(p, "answered")
	ok(not requests.is_empty() and String(requests[0]["path"]) == "/score", "a /score request was sent")
	ok(bool(p.view.result["ok"]) and not bool(p.view.result["self_rated"]), "a matching transcript is right, not self-rated")
	press(_btn(p, "NextBtn"), "NextBtn (speak pc 1)")
	await _frames(1)
	# 2: 불합격(낮은 점수, 다른 말) -> 틀림 -> 같은 단계 끝에 다시 나온다
	var e2: Dictionary = p.view.ex
	var t2: String = String(e2["target"]) if String(e2["mode"]) == "repeat" else String((e2["accept"] as Array)[0])
	score_reply = _score("something else entirely", 30.0)
	await _record_and_wait(p, "answered")
	ok(not bool(p.view.result["ok"]) and not bool(p.view.result["gave_up"]), "a low score with other words is wrong")
	eq(p.retries_made, 1, "a wrong spoken answer is queued again")
	eq(p.queue.size(), 4, "the retry is at the end of the speaking stage")
	press(_btn(p, "NextBtn"), "NextBtn (speak pc 2)")
	await _frames(1)
	# 3: 무음 -> 답이 아니다, 이상한 응답 -> 답이 아니다, 말하기 어려워요 -> 틀림(다시 내지 않음)
	score_reply = {}
	p.view.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(8)
	ok(p.view.state == "asking" and p.recs[2]["answered"] == false, "a silent recording is not an answer")
	score_reply = {"transcript": 5, "units": "x", "score": "high"}
	p.view.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(8)
	ok(p.view.state == "asking" and p.recs[2]["answered"] == false, "a broken /score answer is not an answer")
	press(_btn(p, "SkipBtn"), "SkipBtn (speak pc 3)")
	await _frames(2)
	ok(bool(p.view.result["gave_up"]) and not bool(p.view.result["ok"]), "give up is wrong and gave_up")
	eq(p.retries_made, 1, "a given-up speaking question is not asked again")
	press(_btn(p, "NextBtn"), "NextBtn (speak pc 3)")
	await _frames(2)
	# 다시 나온 2번: 한 번 더 표시가 있고, 이번에는 맞게
	eq(String(p.view.ex.get("id", "")), "%s~r1" % String(e2["id"]), "the retry of question 2 comes back")
	ok(p.view.find_child("RetryChip", true, false) != null, "the retry carries the '한 번 더' chip")
	score_reply = _score(t2, 90.0)
	await _record_and_wait(p, "answered")
	press(_btn(p, "NextBtn"), "NextBtn (speak pc retry)")
	await _frames(2)
	ok(p.state == "result", "the speaking unit ended")
	eq(int(p.result["total"]), 3, "three questions counted (the retry is not a new question)")
	eq(int(p.result["ok"]), 2, "two were right in the end")
	eq(int(p.result["first_try"]), 1, "one was right on the first show")
	ok(not bool(p.recs[0]["self_rated"]), "PC scoring is not marked as self-rated")
	press(_btn(p, "DoneBtn"), "DoneBtn (speak pc)")
	# 폰 단독: 자가 평가 버튼, /score 요청 없음
	_route(true)
	ok(SelfRatePanel.needed(), "phone mode without a score engine needs self rating")
	requests = []
	var s: CoursePlayer = await _open({"kind": "speak", "w": 2, "d": 2, "block": "speak", "seed": 5})
	s.view.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(3)
	var again: Button = _find_text_button(s.view, "다시")
	var good: Button = _find_text_button(s.view, "잘했어요")
	ok(again != null and good != null, "the phone path shows the self rating buttons [잘했어요] and [다시]")
	press(again, "다시 (self rating)")
	ok(s.view.state == "asking" and not bool(s.recs[0]["answered"]), "[다시] records nothing")
	s.view.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(3)
	press(_find_text_button(s.view, "잘했어요"), "잘했어요 (self rating)")
	ok(bool(s.view.result["ok"]) and bool(s.view.result["self_rated"]), "[잘했어요] is right and marked self-rated")
	ok(requests.is_empty(), "self rating sent no /score request")
	ok(bool(s.recs[0]["self_rated"]), "the player remembers the answer was self-rated")
	s.queue_free()
	CoursePlayer.build_hook = Callable()


# ---------------------------------------------------------------- E4b-7 일부러 틀린 입력

func _hook_fail(_spec: Dictionary, _sd: int) -> Dictionary:
	return {"ok": false, "exercises": [], "dropped": 0, "errors": ["data_empty"]}


func _hook_empty(_spec: Dictionary, _sd: int) -> Dictionary:
	return {"ok": true, "exercises": [], "dropped": 0, "errors": []}


func _hook_cards_only(spec: Dictionary, sd: int) -> Dictionary:
	var r: Dictionary = CourseFeed.build_unit(spec, sd)
	var out: Array = []
	for e in r["exercises"]:
		if CourseExerciseView.is_info_card(e):
			out.append(e)
	r["exercises"] = out
	return r


func _hook_broken(spec: Dictionary, sd: int) -> Dictionary:
	var r: Dictionary = _short(spec, sd, 2)
	var out: Array = []
	var q: int = 0
	for e in r["exercises"]:
		out.append(e)
		if CourseExerciseView.is_info_card(e):
			continue
		if q == 0:
			var broken: Dictionary = (e as Dictionary).duplicate(true)
			broken.erase("options")
			out.append(broken)
			out.append(null)
			out.append({"type": "zzz_unknown", "id": "x:1:1:zzz:a"})
		q += 1
	r["exercises"] = out
	return r


func _hook_guard(spec: Dictionary, sd: int) -> Dictionary:
	var r: Dictionary = CourseFeed.build_unit(spec, sd)
	var cards: Array = []
	var qs: Array = []
	var last_word: String = ""
	for e in r["exercises"]:
		if String(e.get("type", "")) == "teach_word":
			last_word = String(e["item"])
	for e in r["exercises"]:
		if String(e.get("type", "")) == "teach_word":
			if String(e["item"]) != last_word:
				cards.append(e)
		elif String(e.get("type", "")) == "recognize" and String(e["item"]) != last_word:
			qs.append(e)
	var out: Array = cards
	var clean: Array = qs.filter(func(q: Variant) -> bool: return (q as Dictionary).get("option_ids") is Array and not ((q as Dictionary)["option_ids"] as Array).has(last_word))
	out.append(clean[0])
	out.append(clean[1])
	# 안 본 낱말(소개 카드를 건너뛴 오늘 낱말)을 묻는 문제들
	for e in r["exercises"]:
		if (String(e.get("type", "")) == "recognize" or String(e.get("type", "")) == "recall") and String(e.get("item", "")) == last_word:
			out.append(e)
	# 미래 낱말(4주) 문제
	var future: Dictionary = (clean[0] as Dictionary).duplicate(true)
	future["item"] = "w0301"
	future["id"] = "x:1:2:rec:w0301:en_ko"
	out.append(future)
	r["exercises"] = out
	return r


func _test_invalid() -> void:
	print("[E4b-7: broken builder, no data, empty unit, broken fields, data vanishes mid-unit, bad specs, guard drops]")
	# 1) 빌더가 ok=false
	_world(K1_DIR)
	var snap: Dictionary = _snap()
	_use_hook(Callable(self, "_hook_fail"))
	var p: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1})
	eq(p.state, "error", "builder ok=false -> error screen")
	var et: String = _label_text(p, "ErrorText")
	var rx := RegEx.new()
	rx.compile("[가-힣]")
	ok(rx.search(et) != null and not et.contains("data_empty"), "the error text is Korean and hides the error code: %s" % et)
	ok(p.find_child("ErrorBox", true, false) != null and (p.find_child("ErrorBox", true, false) as Control).is_visible_in_tree(), "the error box is visible")
	ok(not p.back_btn.is_visible_in_tree(), "the play bar is hidden on the error screen")
	press(_btn(p, "ErrorBackBtn"), "ErrorBackBtn")
	eq(left_n, 1, "[돌아가기] emits left")
	eq(_snap(), snap, "the error path recorded nothing")
	# 2) 문제 0개
	_use_hook(Callable(self, "_hook_empty"))
	var p2: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1})
	eq(p2.state, "error", "a unit with 0 exercises -> error screen")
	ok(p2.go_back() and left_n == 2, "go_back on the error screen leaves (left emitted)")
	# 3) 소개 카드뿐인 단위 -> 풀 문제 0개: 기록하지 않고 오류
	_use_hook(Callable(self, "_hook_cards_only"))
	var p3: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	var guard: int = 0
	while p3.state == "run" and guard < 20:
		guard += 1
		press(_btn(p3, "NextBtn"), "NextBtn (cards only)")
		await _frames(1)
	eq(p3.state, "error", "a unit with cards but no question ends with an error, not a result")
	ok(p3.result.is_empty(), "no result was made for 0 questions")
	eq(_snap(), snap, "0 questions recorded nothing")
	# 4) 깨진 문제들(options 없음, null, 모르는 type)은 그 문제만 건너뜀
	_use_hook(Callable(self, "_hook_broken"))
	var p4: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	var log4: Array = await _play_unit(p4, {}, "broken")
	eq(p4.skipped, 3, "three broken exercises were skipped (no options, null, unknown type)")
	eq(p4.state, "result", "the unit still ended with a result")
	eq(int(p4.result["total"]), 2, "only the two good questions count")
	eq(log4.size(), 2, "the user answered 2 questions and never saw the broken ones")
	eq(int(p4.result["skipped"]), 2 + 1, "result.skipped = 3")
	press(_btn(p4, "DoneBtn"), "DoneBtn (broken)")
	# 5) 가드: 안 본 낱말·미래 낱말 문제는 올리지 않고 센다
	_world(K1_DIR)
	_use_hook(Callable(self, "_hook_guard"))
	var p5: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 2, "seed": 2})
	var log5: Array = await _play_unit(p5, {}, "guard")
	var unseen: Array = guard_log.filter(func(g: Variant) -> bool: return not bool((g as Dictionary)["ok"]))
	ok(unseen.size() >= 3, "the guard hook reported %d violations (unseen word questions and a future word)" % unseen.size())
	eq(p5.dropped, unseen.size(), "dropped counts exactly the guard violations")
	var shown_ids: Array = log5.map(func(r: Variant) -> String: return String((r as Dictionary)["id"]))
	var bad_shown: int = 0
	for g in unseen:
		if shown_ids.has(String((g as Dictionary)["id"])):
			bad_shown += 1
	eq(bad_shown, 0, "no violating question was shown")
	eq(int(p5.result["total"]), 2, "only the 2 good questions were played")
	eq(int(p5.result["dropped"]), unseen.size(), "result.dropped is kept for the test")
	ok(not _has_text(p5, "버려") and not _has_text(p5, "dropped") and not _has_text(p5, "규칙"), "the user is not told about dropped questions")
	press(_btn(p5, "DoneBtn"), "DoneBtn (guard)")
	# 6) 단위 도중 CourseData 가 사라짐 -> 안전 종료(기록 없음)
	_world(K1_DIR)
	snap = _snap()
	_use_hook(Callable(self, "_short_2"))
	var p6: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	ok(p6.state == "run", "the unit is running before the data goes away")
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	press(_btn(p6, "NextBtn"), "NextBtn (data vanished)")
	await _frames(2)
	eq(p6.state, "error", "course data vanished mid-unit -> error screen")
	ok(_label_text(p6, "ErrorText") != "" and rx.search(_label_text(p6, "ErrorText")) != null, "the error text is Korean: %s" % _label_text(p6, "ErrorText"))
	ok(_ready_btn(_btn(p6, "ErrorBackBtn")), "[돌아가기] is there")
	eq(_snap(), snap, "vanished data recorded nothing")
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()
	# 7) 처음부터 데이터 없음(진짜 빌더)
	CoursePlayer.build_hook = Callable()
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	CourseFeed.reset()
	var p7: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1})
	eq(p7.state, "error", "no course data at all -> error screen")
	var feed_text: String = String(CourseFeed.status().get("text_ko", ""))
	ok(feed_text != "" and _label_text(p7, "ErrorText") == feed_text, "the error shows the data loader's Korean text: %s" % feed_text)
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()
	# 8) 이상한 spec
	var bads: Array = [null, 5, {}, {"kind": "bogus", "w": 1, "d": 1}, {"kind": "new", "w": 99, "d": 1}, {"kind": "new", "w": 1, "d": 0}, {"kind": "new", "w": "1", "d": 1},
		{"kind": "free", "w": 1, "d": 7}, {"kind": "new", "w": 1.5, "d": 1}]
	var bad_ok: int = 0
	for b in bads:
		var pb: CoursePlayer = await _open(b)
		if pb.state == "error" and _label_text(pb, "ErrorText") != "":
			bad_ok += 1
		else:
			print("  bad spec did not give an error screen: ", b)
	eq(bad_ok, bads.size(), "every bad spec gives an error screen without a crash (%d)" % bads.size())


# ---------------------------------------------------------------- E4b-8 숫자와 배치

func _hook_slow(spec: Dictionary, sd: int) -> Dictionary:
	return _short(spec, sd, 1)


func _test_numbers_and_layout() -> void:
	print("[E4b-8: readable numbers and layout %dx%d scale %s %s]" % [int(_screen.x), int(_screen.y), str(Ds.font_scale), _scheme])
	_world(K1_DIR)
	_use_hook(Callable(self, "_hook_slow"))
	_clock = 0
	var p: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	_clock += 9999999999 ## 3년 가까이: 한도(2시간)에서 잘린다
	await _play_unit(p, {}, "slow", 0)
	eq(int(p.result["seconds"]), 7200, "an absurd clock is capped to 7200 seconds")
	ok(_label_text(p, "TimeLine").contains("2시간") and not has_big_number([_label_text(p, "TimeLine")]), "TimeLine reads 2시간: %s" % _label_text(p, "TimeLine"))
	var all_text: Array = []
	_texts(p, all_text)
	ok(not has_big_number(all_text) and not has_seconds_text(all_text), "no big number and no seconds on the capped result card")
	# 결과 카드·오류 화면·시트의 배치
	var bounds := Rect2(Vector2.ZERO, _screen)
	var sc: Dictionary = scan_layout(p, bounds, min_touch())
	eq(int(sc["rect"]), 0, "result card: nothing sticks out sideways")
	eq(int(sc["small"]), 0, "result card: every button is at least %.0f high" % min_touch())
	eq(int(sc["wide"]), 0, "result card: no text needs more width than the screen")
	var page: PageScroll = p.find_child("ResultPage", true, false)
	var hb: HScrollBar = page.get_h_scroll_bar()
	ok(not hb.visible and hb.max_value - hb.page <= 1.0, "result card: no horizontal scrolling")
	var foot: Control = p.find_child("ResultFooter", true, false)
	ok(foot != null and absf(foot.get_global_rect().end.y - _screen.y) < 1.5, "the [완료] bar sits at the bottom of the screen (%.0f vs %.0f)" % [foot.get_global_rect().end.y, _screen.y])
	# 풀이 화면(위 막대 포함)
	_use_hook(Callable(self, "_short_2"))
	var q: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1, "seed": 2})
	var sq: Dictionary = scan_layout(q, bounds, min_touch())
	eq(int(sq["rect"]) + int(sq["wide"]), 0, "play screen with the top bar: nothing sticks out, nothing too wide")
	eq(int(sq["small"]), 0, "play screen: every button is at least %.0f high" % min_touch())
	var top: Control = q.find_child("TopBar", true, false)
	ok(top != null and top.get_combined_minimum_size().x <= _screen.x + 0.5, "the top bar fits the width (%.0f <= %.0f)" % [top.get_combined_minimum_size().x, _screen.x])
	# 확인 시트
	press(_btn(q, "BackBtn"), "BackBtn (layout)")
	await _frames(3)
	var shh: Sheet = q.leave_sheet()
	ok(shh != null and shh.panel != null and shh.panel.get_global_rect().end.x <= _screen.x + 0.5, "the leave sheet fits the screen")
	press(shh.buttons["continue"], "계속하기 (layout)")
	await _frames(2)
	# 오류 화면
	_use_hook(Callable(self, "_hook_fail"))
	var er: CoursePlayer = await _open({"kind": "new", "w": 1, "d": 1})
	var se: Dictionary = scan_layout(er, bounds, min_touch())
	eq(int(se["rect"]) + int(se["wide"]) + int(se["small"]), 0, "error screen layout is clean")
	# 풀이 중 모든 화면의 배치 합계
	eq(int(_layout_bad["rect"]), 0, "all play screens: nothing sticks out sideways (%d screens scanned)" % int(_layout_bad["n"]))
	eq(int(_layout_bad["small"]), 0, "all play screens: every button is at least %.0f high" % min_touch())
	eq(int(_layout_bad["wide"]), 0, "all play screens: no text needs more width than the screen")
	ok(int(_layout_bad["n"]) >= 100, "many screens were scanned (%d)" % int(_layout_bad["n"]))
	CoursePlayer.build_hook = Callable()


# ---------------------------------------------------------------- E4b-10 금지

func _test_source() -> void:
	print("[E4b-10: source scan of the player and of this test]")
	var src: String = FileAccess.get_file_as_string(PLAYER_SRC)
	var me: String = FileAccess.get_file_as_string(SELF_SRC)
	ok(src.length() > 5000, "the player source was read (%d characters)" % src.length())
	eq(src_hits(src, ["add_" + "path_lesson"]), 0, "the player never writes an old-path lesson (0 lines)")
	eq(src_hits(src, ["HTTP" + "Request", "shell_" + "open", "request_" + "permission"]), 0, "no network node, shell open or permission request in the player")
	eq(src_hits(src, ["Color(\"" + "#"]), 0, "no Color(\"# literals")
	eq(src_hits(src, ["87" + "70", "87" + "75", "87" + "76"]), 0, "the player never names the forbidden ports")
	eq(src_hits(me, ["87" + "70", "87" + "75", "87" + "76", "HTTP" + "Request", "Color(\"" + "#"]), 0, "this test never names the forbidden ports or calls")
	eq(src_hits(src, ["%d" + "/%d", "%d" + " / %d"]), 0, "no own value/target progress text in the player (progress_label only)")
	eq(glyph_hits(src), 0, "no emoji or glyph characters in the player")
	eq(glyph_hits(me), 0, "no emoji or glyph characters in this test")
	ok(src.contains("CourseModel.fmt_minutes(") and src.contains("CourseModel.progress_label("), "the player uses fmt_minutes and progress_label")
	ok(src.contains("LexiconGuard.check_exercise_set(") and src.contains("CourseFeed.build_unit("), "the player re-checks every screen with the guard and builds through CourseFeed")
	var judge_src: int = src_hits(src, ["LessonBuilder.judge", "norm_answer"])
	eq(judge_src, 0, "the player has no judging code of its own (the exercise view judges)")
