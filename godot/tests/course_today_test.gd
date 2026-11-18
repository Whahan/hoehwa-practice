extends Node
## v2.0 E6: 홈 "오늘 할 일" 을 코스 모드의 하루 45분 계획(DayPlan)에 연결한 것을 시험한다. 서버 없이.
##   PC  : godot --headless --path godot res://tests/course_today_test.tscn -- --api=http://127.0.0.1:9
##   폰  : godot --headless --path godot --resolution 412x915 res://tests/course_today_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션: -- [--phone] [--font-scale=1.5] [--dark]
## 마지막 줄: "== course_today: N passed, M failed (presses: P) ==" (실패가 있으면 종료 코드 1).
## 흐름(홈 -> [오늘 45분 시작] -> 플레이어 -> 끝냄 -> 홈 줄 done)은 전부 실제 버튼의 pressed.emit() 으로 간다(출력의 "press: ..." 줄).
## 코스 데이터는 시험용 작은 데이터(k1_mini)다. 시험 전용 경로(user://test_e6_*)만 쓰고 끝에 되돌린다. 주소는 닫힌 포트(9).
## 검사기(큰 숫자·분 단위·소스 검사·버튼 준비 검사)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다("selfcheck FAIL-as-expected ...").

const K1_DIR := "res://tests/fixtures/course_builder/k1_mini"
const GONE_DIR := "res://tests/fixtures/__not_here__"
const PROG := "user://test_e6_progress.json"
const PREFS := "user://test_e6_prefs.json"
const LOG := "user://test_e6_studylog.json"
const CS := "user://test_e6_course.json"
const SRC_FILES := ["res://scripts/core/home_model.gd", "res://scripts/ui/home_parts.gd", "res://scripts/views/today_view.gd", "res://tests/course_today_test.gd"]
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _events: Array = []
var _before: Array = []
var _saved: Dictionary = {}
var _specs: Array = [] ## 플레이어가 만들려고 받은 spec 들(빌더 훅이 적는다)
var _holder: Control = null
var _main: Control = null


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = JSON.stringify(got, "", true) == JSON.stringify(want, "", true)
	ok(good, name if good else "%s  got=%s want=%s" % [name, JSON.stringify(got), JSON.stringify(want)])


func same(got: Variant, want: Variant) -> bool:
	return JSON.stringify(got, "", true) == JSON.stringify(want, "", true)


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
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== course_today start (%s, scale %s%s) ==" % ["phone" if phone else "pc", str(_scale), ", dark" if _dark else ""])
	_before = _user_listing()
	_setup()
	var want := Vector2i(412, 915) if phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(3)
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	_selfcheck()
	_test_plan_rows()
	_test_plan_states()
	_test_day_kinds()
	_test_review_first_and_recap()
	_test_review_block_rule()
	_test_norm_garbage()
	_test_offer_and_fallback_model()
	_test_notes_and_numbers()
	await _test_view_structure()
	await _test_first_screen()
	await _test_flow_buttons()
	await _test_block_specs()
	await _test_reopen_once()
	await _test_rp_once()
	await _test_review_mark()
	await _test_offer_view()
	await _test_fallback_view()
	_test_source()
	await _test_main_wiring()
	_teardown()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_today: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
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
		"api": Api.base_url, "anim": Sheet.animate, "override": StudyLog.today_override, "unix": StudyLog.unix_override,
		"provider": HomeAi.provider, "hour": HomeParts.hour_override, "cache": SongDue.cache.duplicate(true), "starting": Backend._starting,
		"status": Backend.status, "route": Route.mode, "phone_hook": Route.phone_hook, "song_root": SongStore.root}
	Store.progress_path = PROG
	SongStore.root = "user://test_e6_songs"
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	if not phone:
		Api.base_url = "http://127.0.0.1:9"
	Sheet.animate = false
	Store.navigate.connect(func(v: String, l: String) -> void: _events.append(["navigate", v, l]))
	Store.navigate_args.connect(func(v: String, a: Dictionary) -> void: _events.append(["navigate_args", v, a]))
	CoursePlayer.build_hook = Callable(self, "_trim_build")
	CoursePlayer.clock_hook = Callable(self, "_clock_now")
	Tts.fetch_hook = Callable(self, "_tts_hook")


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	CoursePlayer.build_hook = Callable()
	CoursePlayer.clock_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	_rm_all()
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	CourseFeed.reset()
	CourseStore.reset_memory()
	CourseStore.today_override = -1
	HomeParts.reset_course_memory()
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.prefs_path = _saved["prefs_path"]
	CourseStore.path = _saved["cs"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Api.base_url = _saved["api"]
	Sheet.animate = _saved["anim"]
	StudyLog.today_override = _saved["override"]
	StudyLog.unix_override = _saved["unix"]
	HomeAi.provider = _saved["provider"]
	HomeParts.hour_override = _saved["hour"]
	SongDue.cache = _saved["cache"]
	Backend._starting = _saved["starting"]
	Backend.status = _saved["status"]
	Backend.set_process(true)
	Route.mode = _saved["route"]
	Route.phone_hook = _saved["phone_hook"]
	SongStore.root = _saved["song_root"]


func _rm_all() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


var _clock: int = 1000000


func _clock_now() -> int:
	return _clock


func _tts_hook(_text: String, _l: String, _speed: float, _voice: String) -> Variant:
	return null


func _yes() -> bool:
	return true


## 새 세계: 기록 없음. course = true 면 코스 모드(영어). cards = 밀린 복습 카드 수.
func _world(course: bool, cards: int = 12) -> void:
	_rm_all()
	Store.progress = Progress.blank()
	Store.progress["start"] = Plan.days_to_iso(Plan.today_days() - 10)
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	Store.prefs["daily_goal_min"] = 45
	Store.prefs.erase("home_ai_dismiss_day")
	StudyLog.today_override = Plan.today_days()
	StudyLog.unix_override = -1
	StudyLog.reset()
	CourseStore.reset_memory()
	CourseStore.today_override = -1
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()
	HomeParts.reset_course_memory()
	HomeParts.hour_override = 10
	HomeAi.provider = func() -> Dictionary: return {"show": false}
	SongDue.cache = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": int(Time.get_unix_time_from_system())}
	Route.phone_hook = Callable(self, "_yes") # 말하기는 자가 평가 경로(마이크 없음)
	Route.mode = "phone"
	if course:
		CourseStore.set_mode("course")
	_add_cards(cards)
	_events.clear()
	_specs.clear()


var _card_seq: int = 0


func _add_cards(n: int) -> void:
	var items: Array = []
	for i in n:
		_card_seq += 1
		items.append({"lang": "en", "target": "e6 card %d" % _card_seq, "ko": "카드 %d" % _card_seq, "note": ""})
	Store.add_review(items)


## 복습 탭에서 k 장을 복습한 것처럼: 카드 k 장의 다음 복습을 미루고 오늘 복습 수를 센다.
func _review_cards(k: int) -> void:
	var done := 0
	for r in Store.progress["review"]:
		if done >= k:
			break
		if int((r as Dictionary).get("due", 0)) <= Store.now():
			(r as Dictionary)["due"] = Store.now() + 86400
			done += 1
	StudyLog.add_event("en", "reviews", done)


## 앞쪽 칸들을 며칠 전에 끝낸 것으로 만든다(시험 준비라서 CourseStore 를 직접 부른다). 그 칸(w, d)이 오늘 할 칸이 된다.
func _advance_to(w: int, d: int, day: int = -1) -> void:
	CourseStore.today_override = (Plan.today_days() - 3) if day < 0 else day
	for ww in range(1, w + 1):
		var last: int = 8 if ww < w else d
		for k in range(1, last):
			CourseStore.unit_done({"unit": "new", "w": ww, "d": k, "completed": true, "block": "new", "ok": 1, "total": 1})
	CourseStore.today_override = -1


func _make() -> TodayView:
	var tv := TodayView.new()
	tv.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(tv)
	await _frames(5)
	return tv


func _drop(tv: Node) -> void:
	tv.queue_free()
	await _frames(2)


func _refresh(tv: TodayView, frames: int = 5) -> void:
	tv.refresh()
	await _frames(frames)


# ---------------------------------------------------------------- 도우미: 누르기·글 읽기

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
		if c is Label or c is Button or c is RichTextLabel:
			out.append(str(c.text))
		_texts(c, out)


func _all_texts(root: Node) -> Array:
	var out: Array = []
	_texts(root, out)
	return out


func _has_text(root: Node, needle: String) -> bool:
	for t in _all_texts(root):
		if str(t).contains(needle):
			return true
	return false


func has_big_number(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	for t in texts:
		if rx.search(str(t)) != null:
			return true
	return false


func has_seconds_text(texts: Array) -> bool:
	var rx := RegEx.new()
	rx.compile("\\d+\\s*(초|ms|밀리초|바이트)")
	for t in texts:
		if str(t) == "60초 퀴즈":
			continue # 기존 "이번 주" 카드의 퀴즈 이름(고정 글자, 시간 값이 아님)
		if rx.search(str(t)) != null:
			return true
	return false


func _row(tv: TodayView, id: String) -> Control:
	var tc: Control = tv.card("tasks")
	if tc == null:
		return null
	for n in tc.find_children("*", "Control", true, false):
		if (n as Control).has_meta("task_id") and str((n as Control).get_meta("task_id")) == id:
			return n
	return null


func _row_btn(tv: TodayView, id: String) -> Button:
	var r: Control = _row(tv, id)
	return r.get_meta("button") as Button if r != null else null


func _row_state(tv: TodayView, id: String) -> String:
	var b: Button = _row_btn(tv, id)
	if b == null:
		return ""
	for c in b.get_children():
		if c is HomeParts.Mark:
			return (c as HomeParts.Mark).state
	return ""


func _row_ids(tv: TodayView) -> Array:
	var out: Array = []
	var tc: Control = tv.card("tasks")
	if tc == null:
		return out
	for n in tc.find_children("*", "Control", true, false):
		if (n as Control).has_meta("task_id"):
			out.append(str((n as Control).get_meta("task_id")))
	return out


func _greeting_text(tv: TodayView) -> String:
	for n in tv.find_children("*", "Control", true, false):
		if (n as Control).has_meta("kind") and (n as Control).has_meta("text"):
			return str((n as Control).get_meta("text"))
	return ""


func _y(c: Control) -> float:
	return c.get_global_rect().position.y


func _bottom(c: Control) -> float:
	return c.get_global_rect().end.y


func _course_json() -> Dictionary:
	var f := FileAccess.open(CS, FileAccess.READ)
	if f == null:
		return {}
	var j: Variant = JSON.parse_string(f.get_as_text())
	return j if j is Dictionary else {}


func _rp_today() -> int:
	var days: Dictionary = _course_json().get("day", {})
	var rec: Variant = days.get(CourseStore.today_iso(), {})
	return int((rec as Dictionary).get("rp", -1)) if rec is Dictionary else -1


# ---------------------------------------------------------------- 모델 시험용 스냅샷

func CSNAP(over: Dictionary = {}) -> Dictionary:
	var c := {"mode": "course", "w": 5, "d": 2, "blocks_done": {"new": false, "review": false, "listen": false, "speak": false}, "away_days": 0,
		"due": 12, "check_pending": false, "check_pending_days": 0, "rp_prev": false, "rp_streak": 0, "elapsed_days": 30, "finished": false,
		"reopen_done": false, "late_weeks": 0, "fallback": ""}
	for k in over.keys():
		c[k] = over[k]
	return c


func S(course_over: Dictionary = {}, top_over: Dictionary = {}) -> Dictionary:
	var s := {"lang": "en", "phase": "on", "before_days": 0, "lesson_today": 0, "due": 12, "reviews_today": 0, "song_due": 0, "song_count": 0,
		"path": {"n": 3, "w": 2, "done": 3, "goal": 5, "finished": false}, "goal_min": 45, "sec_today": 0, "streak": 0, "tokens": 0,
		"studied_today": false, "has_data": true, "first_run": false, "hour": 10, "now": 1790000000, "resume": {}, "course": CSNAP(course_over)}
	for k in top_over.keys():
		s[k] = top_over[k]
	return s


func titles(ts: Array) -> Array:
	var out: Array = []
	for t in ts:
		out.append(t["title"])
	return out


func states(ts: Array) -> Array:
	var out: Array = []
	for t in ts:
		out.append(t["state"])
	return out


func ids(ts: Array) -> Array:
	var out: Array = []
	for t in ts:
		out.append(t["id"])
	return out


func _task(s: Dictionary, id: String) -> Dictionary:
	for t in HomeModel.tasks(s):
		if str((t as Dictionary)["id"]) == id:
			return t
	return {}


# ---------------------------------------------------------------- 검사기 자체 확인

func _selfcheck() -> void:
	print("[selfcheck: 검사 함수가 틀린 값을 실패로 판정하는가]")
	ok(not has_big_number(["12분 30초", "복습 9999개", "코스 5/72주"]), "selfcheck: has_big_number accepts ordinary numbers (4 digits)")
	fails(has_big_number(["걸린 시간 12345"]), "12345 on screen is found by has_big_number")
	fails(has_seconds_text(["걸린 시간 930초"]), "'930초' is found by has_seconds_text")
	ok(not has_seconds_text(["60초 퀴즈"]), "selfcheck: the fixed quiz name '60초 퀴즈' of the existing fun card is not a time value")
	ok(not has_seconds_text(["오늘 45분 중 15분 했어요."]), "selfcheck: has_seconds_text accepts minutes")
	var fake_btn := Button.new()
	fake_btn.text = "x"
	fake_btn.disabled = true
	add_child(fake_btn)
	fails(not _ready_btn(fake_btn), "press() refuses a disabled button")
	fails(not _ready_btn(null), "press() refuses a missing button")
	fake_btn.queue_free()
	var good_rows: Array = HomeModel.tasks(S())
	fails(not same(titles(good_rows), ["새 내용 · 5주 3일", "복습 12개", "듣기 8분", "말하기 12분"]), "a wrong cell in the expected titles is found")
	fails(not same(titles(good_rows), ["새 내용 · 5주 2일", "복습 12개", "듣기 8분", "말하기 25분"]), "a wrong minute in the expected titles is found")
	ok(same(titles(good_rows), ["새 내용 · 5주 2일", "복습 12개", "듣기 8분", "말하기 12분"]), "selfcheck: the right titles are accepted")
	var fake_src: String = "var c = Col" + "or(\"#ff0000\")\nvar r = HTTP" + "Request.new()\nvar p = \"87" + "70\"\n"
	fails(src_hits(fake_src, ["Col" + "or(\"#", "HTTP" + "Request", "87" + "70"]) == 3, "the source scan finds three forbidden things in a fake source")
	fails(glyph_hits("a %s b" % String.chr(0x2605)) == 1, "the glyph scan finds a star")
	ok(glyph_hits("오늘 45분 · 15분") == 0, "selfcheck: the glyph scan accepts the middle dot")
	fails(not HomeModel.course_plan(S()).is_empty(), "the 'no plan' check flags a real course as a plan")
	ok(HomeModel.course_plan({"lang": "en", "course": "x"}).is_empty(), "selfcheck: the 'no plan' check accepts a garbage course value")


func src_hits(src: String, needles: Array) -> int:
	var n: int = 0
	for line in src.split("\n"):
		for nd in needles:
			if String(line).contains(String(nd)):
				n += 1
				break
	return n


func glyph_hits(src: String) -> int:
	var n: int = 0
	for i in src.length():
		var c: int = src.unicode_at(i)
		if (c >= 0x1F000 and c <= 0x1FAFF) or (c >= 0x2600 and c <= 0x27BF) or (c >= 0x2B00 and c <= 0x2BFF) or c == 0xFE0F:
			n += 1
	return n


# ---------------------------------------------------------------- 모델: 줄 문구 (E6-3)

func _test_plan_rows() -> void:
	print("[E6-3 plan rows: 5주 2일, 밀린 카드 12]")
	var s: Dictionary = S()
	var ts: Array = HomeModel.tasks(s)
	eq(ids(ts), ["new", "review", "listen", "speak"], "four rows in block order")
	eq(titles(ts), ["새 내용 · 5주 2일", "복습 12개", "듣기 8분", "말하기 12분"], "titles: 새 내용 · 5주 2일 / 복습 12개 / 듣기 8분 / 말하기 12분")
	eq((ts[0] as Dictionary)["sub"], "15분", "the new row says its minutes in sub: 15분")
	eq((ts[1] as Dictionary)["sub"], "10분", "the review row says 10분 in sub")
	eq(states(ts), ["todo", "todo", "todo", "todo"], "nothing done: four todo rows")
	var h: Dictionary = HomeModel.hero(s)
	eq(h["text"], "오늘 45분 시작", "hero text: 오늘 45분 시작")
	eq(h["all_done"], false, "hero: not all done")
	eq(h["target"], {"view": "course", "args": {"lang": "en", "kind": "new", "w": 5, "d": 2, "block": "new", "half": false}}, "hero target: the new block of 5주 2일 (kind new, block new)")
	eq(HomeModel.message(s), {"text": "오늘 45분, 한 블록씩 해요.", "kind": "info"}, "greeting before anything: 오늘 45분, 한 블록씩 해요.")
	eq((ts[1] as Dictionary)["target"], {"view": "review", "args": {"lang": "en"}}, "the review row goes to the review tab")
	eq((ts[2] as Dictionary)["target"], {"view": "course", "args": {"lang": "en", "kind": "listen", "w": 5, "d": 2, "block": "listen", "half": false}}, "the listen row opens a listen unit with block listen")
	eq((ts[3] as Dictionary)["target"], {"view": "course", "args": {"lang": "en", "kind": "speak", "w": 5, "d": 2, "block": "speak", "half": false}}, "the speak row opens a speak unit with block speak")
	eq(HomeParts.summary_text(ts), "새 내용 · 복습 12 · 듣기 · 말하기", "summary line of the four todo rows")
	var plan: Dictionary = HomeModel.course_plan(s)
	eq(plan["total_min"], 45, "the plan is 45 minutes")
	# 단계별 분 배분이 줄에 그대로: S0 (1주) 18/5/12/10, S3 (40주) 12/12/8/13
	var t1: Array = HomeModel.tasks(S({"w": 1, "d": 2}))
	eq([(t1[0] as Dictionary)["sub"], titles(t1)[2], titles(t1)[3], (t1[1] as Dictionary)["sub"]], ["18분", "듣기 12분", "말하기 10분", "5분"], "stage 0 minutes 18/5/12/10 are shown as 분")
	var t2: Array = HomeModel.tasks(S({"w": 40, "d": 2}))
	eq([(t2[0] as Dictionary)["sub"], titles(t2)[2], titles(t2)[3], (t2[1] as Dictionary)["sub"]], ["12분", "듣기 8분", "말하기 13분", "12분"], "stage 3 minutes 12/12/8/13 are shown as 분")


func _test_plan_states() -> void:
	print("[E6-2 model: done rows, greeting, start button]")
	var s: Dictionary = S({"blocks_done": {"new": true, "review": false, "listen": false, "speak": false}})
	var ts: Array = HomeModel.tasks(s)
	eq(states(ts), ["done", "todo", "todo", "todo"], "new done -> that row is done")
	eq(HomeModel.message(s), {"text": "오늘 45분 중 15분 했어요.", "kind": "info"}, "greeting after the new block: 오늘 45분 중 15분 했어요.")
	eq(HomeModel.hero(s)["kind"], "review", "the start button now goes to the review block")
	eq(HomeModel.hero(s)["text"], "오늘 45분 시작", "the start button text stays 오늘 45분 시작 while something is left")
	var s2: Dictionary = S({"blocks_done": {"new": true, "review": true, "listen": false, "speak": false}})
	eq(HomeModel.message(s2)["text"], "오늘 45분 중 25분 했어요.", "new + review done: 25분")
	var s3: Dictionary = S({"blocks_done": {"new": true, "review": true, "listen": true, "speak": false}})
	eq(HomeModel.message(s3)["text"], "오늘 45분 중 33분 했어요.", "new + review + listen done: 33분")
	var s4: Dictionary = S({"blocks_done": {"new": true, "review": true, "listen": true, "speak": true}})
	var h4: Dictionary = HomeModel.hero(s4)
	eq([h4["text"], h4["all_done"], h4["target"]["view"]], ["더 연습하기", true, "practice"], "all four done: 더 연습하기 -> practice")
	eq(HomeModel.message(s4), {"text": "오늘 45분을 다 했어요. 잘했어요!", "kind": "ok"}, "all done: the greeting says so")
	eq(states(HomeModel.tasks(s4)), ["done", "done", "done", "done"], "all four rows done")
	eq(HomeParts.summary_text(HomeModel.tasks(s4)), "오늘 할 일을 다 했어요", "summary when everything is done")
	eq(ids(HomeModel.tasks(S({"due": 0}))), ["new", "review", "listen", "speak"], "no cards: still four rows")


func _test_day_kinds() -> void:
	print("[contract 1: block ids in the targets (D5 new block = kind speak, block new)]")
	var t5: Array = HomeModel.tasks(S({"d": 5}))
	eq((t5[0] as Dictionary)["title"], "말하기 날 · 5주 5일", "D5 title")
	eq(((t5[0] as Dictionary)["target"] as Dictionary)["args"], {"lang": "en", "kind": "speak", "w": 5, "d": 5, "block": "new", "half": false}, "D5 new block spec: kind speak, block NEW")
	eq(((t5[3] as Dictionary)["target"] as Dictionary)["args"], {"lang": "en", "kind": "speak", "w": 5, "d": 5, "block": "speak", "half": false}, "D5 speak block spec: kind speak, block speak")
	var t6: Array = HomeModel.tasks(S({"d": 6}))
	eq((t6[0] as Dictionary)["title"], "주간 점검 · 5주 6일", "D6 title")
	eq(((t6[0] as Dictionary)["target"] as Dictionary)["args"]["kind"], "check", "D6 new block opens a check")
	eq(((t6[0] as Dictionary)["target"] as Dictionary)["args"]["block"], "new", "D6 block new")
	var t7: Array = HomeModel.tasks(S({"d": 7}))
	eq((t7[0] as Dictionary)["title"], "자유 시간 · 5주 7일", "D7 title")
	eq(((t7[0] as Dictionary)["target"] as Dictionary)["args"]["kind"], "new", "D7 new block opens kind new (the player has no 'free')")
	for d in range(1, 8):
		var a: Dictionary = (HomeModel.tasks(S({"d": d}))[0] as Dictionary)["target"]["args"]
		ok(str(a["block"]) == "new" and a["w"] == 5 and a["d"] == d, "day %d: the new row spec has block new and its own cell" % d)
	var fin: Array = HomeModel.tasks(S({"finished": true}))
	eq(((fin[0] as Dictionary)["target"] as Dictionary)["args"]["kind"], "new", "a finished course still opens kind new")


func _test_review_first_and_recap() -> void:
	print("[E6-3 review first and recap texts]")
	var rp: Dictionary = S({"due": 45})
	var ts: Array = HomeModel.tasks(rp)
	eq([(ts[0] as Dictionary)["sub"], (ts[1] as Dictionary)["sub"]], ["15분 · 절반만 해요", "20분 · 복습부터 해요"], "review first: half amount and 20분 review")
	eq([titles(ts)[1], titles(ts)[2], titles(ts)[3]], ["복습 45개", "듣기 5분", "말하기 5분"], "review first minutes: 복습 45개 / 듣기 5분 / 말하기 5분")
	eq(HomeModel.message(rp), {"text": "복습부터 해요. 밀린 카드가 많아요.", "kind": "info"}, "review first greeting")
	eq(((ts[0] as Dictionary)["target"] as Dictionary)["args"]["half"], true, "review first: the new block spec says half")
	var rec: Dictionary = S({"away_days": 8})
	var tr: Array = HomeModel.tasks(rec)
	eq((tr[0] as Dictionary)["title"], "복귀 점검 · 5주 2일", "recap day title")
	eq(((tr[0] as Dictionary)["target"] as Dictionary)["args"]["kind"], "recap", "recap day: kind recap")
	eq(((tr[0] as Dictionary)["target"] as Dictionary)["args"]["block"], "new", "recap day: block new")
	eq(HomeModel.message(rec), {"text": "오랜만이에요! 복귀 점검과 복습부터 가볍게 해요.", "kind": "info"}, "recap greeting")
	# 3.: recap 날은 recap 블록을 끝낸 뒤에도 계획이 recap 으로 남는다. 블록 상태는 done
	var rec_done: Dictionary = S({"away_days": 8, "blocks_done": {"new": true, "review": false, "listen": false, "speak": false}})
	var trd: Array = HomeModel.tasks(rec_done)
	eq([(trd[0] as Dictionary)["title"], (trd[0] as Dictionary)["state"]], ["복귀 점검 · 5주 2일", "done"], "contract 3: after the recap block the day stays a recap day, the row is done")
	eq(HomeModel.course_plan(rec_done)["recap"], true, "contract 3: the plan is still recap")
	eq(HomeModel.message(rec_done)["text"], "오늘 45분 중 15분 했어요.", "recap day greeting after the block: minutes done")
	# 4일째는 복습 우선을 풀어 준다
	var third: Dictionary = S({"due": 45, "rp_prev": true, "rp_streak": 3})
	eq(HomeModel.course_plan(third)["review_priority"], false, "the 4th day in a row is a normal day")
	# 복습할 카드가 없으면 복습 줄은 optional, 듣기에 시간이 더해진다
	var nc: Array = HomeModel.tasks(S({"due": 0}))
	eq([(nc[1] as Dictionary)["state"], titles(nc)[1], titles(nc)[2]], ["optional", "복습할 카드가 없어요", "듣기 18분"], "no cards: review row optional, listen 18분")
	eq(HomeModel.hero(S({"due": 0}))["kind"], "new", "no cards: the start button is the new block")
	var nc_done: Dictionary = S({"due": 0, "blocks_done": {"new": true, "review": false, "listen": true, "speak": true}})
	eq(HomeModel.hero(nc_done)["all_done"], true, "no cards + the other three done = all done (the skipped review does not block)")


func _test_review_block_rule() -> void:
	print("[contract 2: the review block counts reviewed cards]")
	var base_done: Dictionary = {"new": false, "review": false, "listen": false, "speak": false}
	# 밀린 12, 오늘 0 -> todo
	eq(_task(S({"due": 12}, {"reviews_today": 0}), "review")["state"], "todo", "12 due, none reviewed: todo")
	# 12장을 다 복습해서 0 이 됨 -> done, 제목 "오늘 복습 끝!", 듣기는 그대로 8분(계획이 하루 안에서 흔들리지 않는다)
	var all12: Array = HomeModel.tasks(S({"due": 0}, {"reviews_today": 12}))
	eq([(all12[1] as Dictionary)["state"], titles(all12)[1], titles(all12)[2]], ["done", "오늘 복습 끝!", "듣기 8분"], "all 12 reviewed: done, and the listen block keeps its 8분")
	# 20 장 중 3 장 복습 -> todo
	eq(_task(S({"due": 17}, {"reviews_today": 3}), "review")["state"], "todo", "17 left after 3: still todo")
	# 20 장 중 15 장 복습 -> done (min(20,15))
	eq(_task(S({"due": 5}, {"reviews_today": 15}), "review")["state"], "done", "15 reviewed of 20: done (min(due, 15))")
	eq(_task(S({"due": 6}, {"reviews_today": 14}), "review")["state"], "todo", "14 reviewed of 20: not yet")
	# 복습 우선은 하루 안에서 풀리지 않는다: 시작 45, 20 복습 -> 지금 25
	var stable: Dictionary = HomeModel.course_plan(S({"due": 25}, {"reviews_today": 20}))
	eq([stable["review_priority"], stable["total_min"]], [true, 45], "45 at the start, 20 reviewed: the day stays review-first and 45분")
	eq(_task(S({"due": 25}, {"reviews_today": 20}), "review")["state"], "done", "20 reviewed of 45: done (>= 15)")
	# 저장소가 이미 review done 이면 카드가 더 생겨도 done
	eq(_task(S({"due": 30, "blocks_done": {"new": false, "review": true, "listen": false, "speak": false}}), "review")["state"], "done", "stored review done stays done")
	ok(base_done.size() == 4, "fixture sanity")


func _test_norm_garbage() -> void:
	print("[E6-5 _norm of the course key]")
	var legacy_ids: Array = ["lesson", "review", "talk"]
	for bad in ["x", "", 5, -3, 1.5, 1.0e30, [], [1, 2], null, true, {"mode": "legacy"}, {"mode": 7}, {}, {"w": 5}]:
		var s: Dictionary = S()
		s["course"] = bad
		var n: Dictionary = HomeModel._norm(s)
		eq(n["course"], {}, "course = %s -> no course" % JSON.stringify(bad))
		eq(ids(HomeModel.tasks(s)), legacy_ids, "course = %s -> the old rows" % JSON.stringify(bad))
		eq(HomeModel.course_plan(s), {}, "course = %s -> no plan" % JSON.stringify(bad))
	eq(HomeModel._norm(null)["course"], {}, "_norm(null): no course, no error")
	eq(HomeModel._norm("x")["course"], {}, "_norm('x'): no course, no error")
	# 모양은 맞는데 값이 이상하다
	var wild: Dictionary = {"mode": "course", "w": "abc", "d": -9, "blocks_done": "x", "away_days": -5, "due": 1.0e20, "check_pending": "yes",
		"check_pending_days": 2.5, "rp_prev": 1, "rp_streak": 500, "elapsed_days": 1.0e12, "finished": "no", "reopen_done": [], "fallback": 7}
	var s2: Dictionary = S()
	s2["course"] = wild
	var c2: Dictionary = HomeModel._norm(s2)["course"]
	eq([c2["w"], c2["d"], c2["away_days"], c2["rp_streak"], c2["fallback"], c2["check_pending"], c2["finished"]], [1, 1, 0, 99, "", false, false], "wild values are clamped to the defaults")
	ok(int(c2["due"]) <= HomeModel.MAX_INT and int(c2["elapsed_days"]) <= 99999, "huge numbers are cut (due %d, elapsed %d)" % [c2["due"], c2["elapsed_days"]])
	eq(c2["blocks_done"], {"new": false, "review": false, "listen": false, "speak": false}, "blocks_done 'x' -> four false")
	ok(not HomeModel.course_plan(s2).is_empty(), "a wild-valued course dictionary still makes a plan (no error)")
	var big: Dictionary = S({"w": 1.0e9, "d": 99, "due": 123456789, "away_days": 99999999})
	var tb: Array = HomeModel.tasks(big)
	eq(ids(tb), ["new", "review", "listen", "speak"], "huge numbers: still four rows")
	ok(not has_big_number(titles(tb)) and not has_big_number([HomeModel.message(big)["text"]]), "huge numbers: no 5-digit number in the texts")
	# 일본어에는 코스가 없다
	var sj: Dictionary = S({}, {"lang": "ja"})
	eq(HomeModel._norm(sj)["course"], {}, "Japanese: the course key is dropped")
	eq(ids(HomeModel.tasks(sj)), legacy_ids, "Japanese: the old rows")
	# 같은 스냅샷에 course 없음 = 예전과 같다
	var plain: Dictionary = S()
	plain.erase("course")
	eq(ids(HomeModel.tasks(plain)), legacy_ids, "no course key: the old rows (legacy mode)")
	eq(HomeModel.hero(plain)["text"], "오늘의 레슨 시작", "no course key: the old start button")
	# 순수: 입력을 바꾸지 않는다
	var before: String = JSON.stringify(s2, "", true)
	HomeModel.tasks(s2)
	HomeModel.message(s2)
	HomeModel.hero(s2)
	HomeModel.course_notes(s2)
	eq(JSON.stringify(s2, "", true), before, "the model never changes the snapshot it was given")


func _test_offer_and_fallback_model() -> void:
	print("[E6-7 / offer: model]")
	var off: Dictionary = S({}, {"course_offer": true})
	off.erase("course")
	ok(HomeModel.course_offer(off), "offer: English, no course, course_offer true -> shown")
	var off_ja: Dictionary = off.duplicate(true)
	off_ja["lang"] = "ja"
	ok(not HomeModel.course_offer(off_ja), "offer: Japanese -> not shown")
	var off_c: Dictionary = S({}, {"course_offer": true})
	ok(not HomeModel.course_offer(off_c), "offer: a running course -> not shown")
	for bad in ["yes", 1, [], null, {}]:
		var o2: Dictionary = off.duplicate(true)
		o2["course_offer"] = bad
		ok(not HomeModel.course_offer(o2), "offer: course_offer = %s -> not shown" % JSON.stringify(bad))
	for fb in ["data", "file"]:
		var sf: Dictionary = S({"fallback": fb})
		eq(ids(HomeModel.tasks(sf)), ["lesson", "review", "talk"], "fallback '%s': the old rows" % fb)
		eq(HomeModel.hero(sf)["kind"], "lesson", "fallback '%s': the old start button" % fb)
		var notes: Array = HomeModel.course_notes(sf)
		ok(notes.size() == 1 and str((notes[0] as Dictionary)["text"]).contains("예전 할 일"), "fallback '%s': one notice line (%s)" % [fb, JSON.stringify(notes)])
		eq(HomeModel.resume(S({"fallback": fb}, {"resume": {"view": "talk", "lang": "en", "at": 1790000000 - 60}}))["title"], "대화 이어하기", "fallback '%s': the old resume card" % fb)
	# 코스 모드의 이어하기: 예전 길 레슨 카드는 없다
	var rs: Dictionary = S({}, {"resume": {"view": "lesson", "lang": "en", "at": 1790000000 - 60}})
	eq(HomeModel.resume(rs), {}, "course mode: no 'old path lesson' resume card")
	var rs2: Dictionary = S({}, {"resume": {"view": "talk", "lang": "en", "at": 1790000000 - 60}})
	eq(HomeModel.resume(rs2)["title"], "대화 이어하기", "course mode: other resume cards stay")


func _test_notes_and_numbers() -> void:
	print("[notes: late weeks, reopen, check, device; numbers are readable]")
	var late: Array = HomeModel.course_notes(S({"w": 5, "elapsed_days": 70}))
	ok(late.size() >= 1 and str((late[0] as Dictionary)["text"]).contains("예정보다 6주 늦었어요"), "late by 6 weeks: %s" % JSON.stringify(late))
	var re: Array = HomeModel.course_notes(S({"away_days": 25, "reopen_done": true}))
	ok(JSON.stringify(re).contains("직전 두 주를 다시 열었어요"), "21+ days away and reopened: a note")
	var ck: Array = HomeModel.course_notes(S({"check_pending": true, "check_pending_days": 3}))
	ok(JSON.stringify(ck).contains("점검을 아직 안 했어요"), "a passed-over check: a note after 3 days")
	var ck1: Array = HomeModel.course_notes(S({"check_pending": true, "check_pending_days": 1}))
	ok(not JSON.stringify(ck1).contains("점검을 아직 안 했어요"), "a passed-over check: no note on day 1")
	var dev: Array = HomeModel.course_notes(S())
	eq(dev, [{"text": "코스 진도는 이 기기에만 저장돼요.", "kind": "info"}], "nothing else to say: the one-line device note")
	ok(HomeModel.course_notes(S({"w": 5, "elapsed_days": 70, "away_days": 30, "reopen_done": true, "check_pending": true, "check_pending_days": 9})).size() <= 3, "at most 3 notes")
	eq(HomeModel.course_notes(S({}, {"lang": "ja"})), [], "Japanese: no notes")
	# 모든 글에 5자리 숫자가 없고 초 단위가 없다
	var all_texts: Array = []
	for over in [{}, {"due": 99999999}, {"away_days": 8}, {"due": 45}, {"elapsed_days": 99999, "w": 1}, {"finished": true}, {"blocks_done": {"new": true, "review": true, "listen": true, "speak": true}}]:
		var s: Dictionary = S(over)
		for t in HomeModel.tasks(s):
			all_texts.append((t as Dictionary)["title"])
			all_texts.append((t as Dictionary)["sub"])
		all_texts.append(HomeModel.message(s)["text"])
		all_texts.append(HomeModel.hero(s)["text"])
		for nt in HomeModel.course_notes(s):
			all_texts.append((nt as Dictionary)["text"])
	ok(all_texts.size() > 40 and not has_big_number(all_texts) and not has_seconds_text(all_texts), "C-15: %d model texts have no 5-digit number and no seconds" % all_texts.size())


# ---------------------------------------------------------------- 화면: 구조·첫 화면 (E6-3, E6-6, E6-8)

func _test_view_structure() -> void:
	print("[E6-3/6 view: course home with the real store]")
	_world(true, 12)
	var tv := await _make()
	eq(_row_ids(tv), ["new", "review", "listen", "speak"], "view: four rows new/review/listen/speak")
	eq(tv.task_buttons().size(), 4, "view: four task buttons")
	eq(tv.hero_button().text, "오늘 45분 시작", "view: the start button says 오늘 45분 시작")
	var texts: Array = _all_texts(tv)
	ok(texts.has("새 내용 · 1주 1일") and texts.has("복습 12개") and texts.has("듣기 12분") and texts.has("말하기 10분"), "view: the row titles (week 1 is stage 0: 듣기 12분, 말하기 10분)")
	ok(texts.has("18분"), "view: the new row says 18분 in its sub")
	ok(_greeting_text(tv) == "오늘 45분, 한 블록씩 해요.", "view: the greeting line (%s)" % _greeting_text(tv))
	var info: String = ""
	for t in texts:
		if str(t).begins_with("XP "):
			info = str(t)
	eq(info, "XP 0 · 코스 0/72주", "E6-6: the streak card shows the course week progress, not 별 n/48")
	ok(not _has_text(tv, "별 "), "E6-6: no 별 anywhere on the course home")
	if not phone:
		var sub: Label = tv.header_block().get_meta("subtitle_label") as Label
		ok(sub.text.begins_with("코스 1주 1일"), "view: the PC subtitle names the course cell (%s)" % sub.text)
	ok(tv.card("course_offer") == null, "view: no [새 코스로 시작] card while the course runs")
	var note_box: Variant = (tv.card("tasks") as Control).get_meta("notes", null)
	ok(note_box is Control and _has_text(note_box as Control, "이 기기에만"), "view: the device note is the last line of the task card")
	ok(not has_big_number(texts) and not has_seconds_text(texts), "C-15: the whole course home has no 5-digit number and no seconds")
	for t in texts:
		if has_big_number([t]) or has_seconds_text([t]):
			print("    offending text: ", t)
	# 밀린 카드 큰 수도 읽을 수 있게
	_add_cards(130)
	await _refresh(tv)
	var texts2: Array = _all_texts(tv)
	ok(not has_big_number(texts2) and texts2.has("복습 142개"), "C-15: 142 due cards: '복습 142개', no 5-digit number")
	ok(texts2.has("복습부터 해요. 밀린 카드가 많아요.") or _greeting_text(tv) == "복습부터 해요. 밀린 카드가 많아요.", "view: review-first greeting with 142 cards")
	await _drop(tv)
	# 일본어: 코스 줄 없음
	_world(true, 12)
	Store.prefs["lang"] = "ja"
	var tj := await _make()
	ok(not _row_ids(tj).has("new") and _row_ids(tj).has("lesson"), "Japanese home keeps the old rows (%s)" % [_row_ids(tj)])
	ok(tj.card("course_offer") == null, "Japanese home: no course card")
	ok(not HomeParts.snapshot("ja").has("course") and not HomeParts.snapshot("ja").has("course_offer"), "Japanese snapshot has no course keys")
	await _drop(tj)
	Store.prefs["lang"] = "en"


func _test_first_screen() -> void:
	print("[E6-8 first screen rules in course mode]")
	_world(true, 12)
	StudyLog.note_resume("practice", "en")
	var tv := await _make()
	var vp := Vector2(get_window().size)
	var hero_end: float = _bottom(tv.hero_button())
	if phone:
		if is_equal_approx(_scale, 1.0):
			ok(hero_end <= 480.0, "E6-8: phone hero button ends at y=%.0f (<= 480)" % hero_end)
			ok(tv.card("resume") != null and _y(tv.card("resume")) < 859.0, "E6-8: resume card starts above the bottom tab bar (y=%.0f < 859)" % _y(tv.card("resume")))
		if _scale >= 1.45:
			ok(hero_end <= 700.0, "E6-8: phone 150%%: hero button ends at y=%.0f (<= 700)" % hero_end)
		var rows_ok := true
		for b in tv.task_buttons():
			if (b as Control).size.y < 55.5:
				rows_ok = false
		ok(rows_ok and tv.task_buttons().size() == 4, "E6-8: the four course rows are >= 56 px high")
		ok(tv.hero_button().size.y >= Ds.HOME_CTA_H_PHONE - 0.5, "E6-8: start button height %.0f" % tv.hero_button().size.y)
	else:
		ok(tv.is_wide(), "E6-8: 1280x800 is wide")
		if is_equal_approx(_scale, 1.0):
			ok(hero_end <= 420.0, "E6-8: PC hero button ends at y=%.0f (<= 420)" % hero_end)
	var bad: Array = []
	for n in tv.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r := c.get_global_rect()
		if r.size.x > 0.0 and r.size.y > 0.0 and (r.end.x > vp.x + 0.5 or r.position.x < -0.5):
			bad.append("%s %s" % [c.get_class(), c.name])
	ok(bad.is_empty(), "E6-8: nothing sticks out of the window (%d)" % bad.size())
	var overlap := false
	var ids_c: Array = []
	for id in ["tasks", "resume", "streak", "course_offer", "shortcuts"]:
		if tv.card(id) != null:
			ids_c.append(id)
	for i in ids_c.size():
		for j in range(i + 1, ids_c.size()):
			var ri: Rect2 = tv.card(ids_c[i]).get_global_rect().intersection(tv.card(ids_c[j]).get_global_rect())
			if ri.size.x > 0.5 and ri.size.y > 0.5:
				overlap = true
	ok(not overlap, "E6-8: no two cards overlap")
	await _drop(tv)


# ---------------------------------------------------------------- 화면: 실제 버튼 흐름 (E6-2, C-14)

## 문제 풀이 시험용 빌더: LessonBuilder 가 만든 단위의 앞부분만 쓴다(안내 카드 + 답할 수 있는 문제 2개). spec 을 적어 둔다.
func _trim_build(spec: Dictionary, seed_value: int) -> Variant:
	_specs.append(spec.duplicate(true))
	var r: Variant = CourseFeed.build_unit(spec, seed_value)
	if not (r is Dictionary) or not bool((r as Dictionary).get("ok", false)):
		return r
	var out: Array = []
	var asked := 0
	for e in (r as Dictionary)["exercises"]:
		var t: String = str((e as Dictionary).get("type", ""))
		if CourseExerciseView.is_info_card(e):
			out.append(e)
		elif t in ["recognize", "listen", "recall", "build", "speak"]:
			out.append(e)
			asked += 1
		if asked >= 2:
			break
	(r as Dictionary)["exercises"] = out
	return r


func _btn(p: CoursePlayer, n: String) -> Button:
	var b: Node = p.find_child(n, true, false)
	return b as Button if b is Button else null


func _type_into(v: CourseExerciseView, txt: String) -> void:
	v.edit.text = txt
	v.edit.text_changed.emit(txt)


func _wait_state(v: CourseExerciseView, want: String, frames: int = 40) -> void:
	for i in frames:
		if v.state == want:
			return
		await get_tree().process_frame


## 플레이어의 한 단위를 끝까지 풀고(전부 맞게) 결과 카드의 [완료] 를 누른다. 전부 실제 버튼. 말하기 문제는 녹음 신호(마이크 대신) + [잘했어요] 자가 평가.
func _play_and_finish(p: CoursePlayer, label: String) -> int:
	var answered := 0
	var guard := 0
	while p.state == "run" and guard < 60:
		guard += 1
		var v: CourseExerciseView = p.view
		var e: Dictionary = v.ex
		if CourseExerciseView.is_info_card(e):
			press(_btn(p, "NextBtn"), "NextBtn (%s card)" % label)
			await _frames(1)
			continue
		match str(e["type"]):
			"recognize", "listen", "recall":
				if e.has("options"):
					press(v.option_btns[int(e["answer"])], "Opt (%s)" % label)
				else:
					_type_into(v, str((e["accept"] as Array)[0]))
				press(_btn(p, "ConfirmBtn"), "ConfirmBtn (%s)" % label)
			"build":
				for tk in e["answer"]:
					for b in v.tile_btns:
						if str((b as Button).text) == str(tk) and not (b as Button).disabled:
							press(b, "Tile '%s' (%s)" % [tk, label])
							break
				press(_btn(p, "ConfirmBtn"), "ConfirmBtn (%s)" % label)
			"speak":
				v.drill.recorder.recorded.emit(FAKE_REC)
				await _frames(3)
				press(_find_text_button(v, "잘했어요"), "잘했어요 self rating (%s)" % label)
			_:
				press(_btn(p, "SkipBtn"), "SkipBtn (%s)" % label)
		await _wait_state(v, "answered")
		ok(v.state == "answered" and v.feedback != null and v.feedback.is_visible_in_tree(), "%s: the feedback is visible after answering" % label)
		answered += 1
		press(_btn(p, "NextBtn"), "NextBtn (%s)" % label)
		await _frames(1)
	ok(p.state == "result", "%s: the player reached the result card (state %s)" % [label, p.state])
	press(_btn(p, "DoneBtn"), "DoneBtn (%s)" % label)
	await _frames(6)
	return answered


func _test_flow_buttons() -> void:
	print("[E6-2 flow: [오늘 45분 시작] -> player -> done -> home row done]")
	_world(true, 12)
	var tv := await _make()
	var p0: int = presses
	eq(_row_state(tv, "new"), "todo", "flow: the new row starts todo")
	eq(_greeting_text(tv), "오늘 45분, 한 블록씩 해요.", "flow: the greeting before the block")
	var pos0: Dictionary = CourseStore.pos()
	eq(pos0, {"w": 1, "d": 1}, "flow: the course is at 1주 1일")
	press(tv.hero_button(), "[오늘 45분 시작] hero")
	await _frames(4)
	var p: CoursePlayer = tv.player()
	ok(p != null and p.state == "run", "flow: the player is open and running")
	ok(p != null and p.is_visible_in_tree(), "flow: the player is visible")
	ok(not tv.is_visible_in_tree() or not (tv.scroll_host() as Control).visible, "flow: the home page is hidden while the player runs")
	eq(_specs.size(), 1, "flow: the player was asked for one unit")
	if _specs.size() == 1:
		var sp: Dictionary = _specs[0]
		eq([sp.get("kind"), sp.get("w"), sp.get("d")], ["new", 1, 1], "flow: the unit is the new block of 1주 1일")
	eq(p.block, "new", "flow: the player's block is new")
	ok(tv.go_back(), "flow: go_back() while the player runs is taken by the player (asks to leave)")
	ok(p.leave_sheet() != null, "flow: the back key opened the leave sheet")
	press(p.leave_sheet().buttons["continue"], "[계속하기] (leave sheet)")
	await _frames(2)
	ok(p.state == "run" and tv.has_player(), "flow: [계속하기] keeps playing")
	var n: int = await _play_and_finish(p, "new")
	ok(n >= 2, "flow: %d questions answered by buttons" % n)
	ok(not tv.has_player(), "flow: after [완료] the player is gone")
	ok((tv.scroll_host() as Control).visible, "flow: the home page is visible again")
	eq(CourseStore.blocks_today(), {"new": true, "review": false, "listen": false, "speak": false}, "flow: the store marked the new block (by the player)")
	eq(CourseStore.pos(), {"w": 1, "d": 2}, "flow: the unit finished the cell: pos moved to 1주 2일")
	eq(_row_state(tv, "new"), "done", "flow: the new row is DONE on the redrawn home")
	eq(_row_state(tv, "review"), "todo", "flow: the review row is still todo")
	eq(_greeting_text(tv), "오늘 45분 중 18분 했어요.", "flow: the greeting changed to 오늘 45분 중 18분 했어요.")
	ok(_has_text(tv, "새 내용 · 1주 1일"), "flow: the done row still names today's cell (1주 1일), not tomorrow's")
	eq(_row_ids(tv), ["new", "review", "listen", "speak"], "flow: still four rows")
	eq(tv.hero_button().text, "오늘 45분 시작", "flow: the start button still says 오늘 45분 시작")
	# 시작 버튼은 이제 복습 블록으로: 복습 탭으로 이동
	_events.clear()
	press(tv.hero_button(), "[오늘 45분 시작] hero (now the review block)")
	await _frames(2)
	eq(_events.size(), 1, "flow: the hero press made one navigation")
	if _events.size() == 1:
		eq(_events[0], ["navigate", "review", "en"], "flow: the review block goes to the review tab")
	ok(not tv.has_player(), "flow: no player for the review block")
	# 듣기 줄: 오늘 칸(1주 1일)의 듣기 단위
	_specs.clear()
	press(_row_btn(tv, "listen"), "listen row")
	await _frames(4)
	var pl: CoursePlayer = tv.player()
	ok(pl != null and pl.state == "run", "flow: the listen row opened the player")
	if _specs.size() == 1:
		var sl: Dictionary = _specs[0]
		eq([sl.get("kind"), sl.get("w"), sl.get("d")], ["listen", 1, 1], "flow: the listen unit is for today's cell (1주 1일), not the next one")
	eq(pl.block, "listen", "flow: block listen")
	var n2: int = await _play_and_finish(pl, "listen")
	ok(n2 >= 2, "flow: the listen unit was answered by buttons (%d)" % n2)
	eq(_row_state(tv, "listen"), "done", "flow: the listen row is DONE")
	eq(CourseStore.pos(), {"w": 1, "d": 2}, "flow: the listen block did not move pos")
	eq(_greeting_text(tv), "오늘 45분 중 30분 했어요.", "flow: the greeting: 30분 after new + listen")
	# 복습: 복습 탭에서 12장을 복습하고 돌아오면 줄이 done 이고 저장소에도 표시된다
	_review_cards(Store.due_count("en")) # (새 내용 단위가 복습 카드를 더했으므로 지금 밀린 것을 전부)
	await _refresh(tv)
	eq(_row_state(tv, "review"), "done", "flow: back from the review tab with all cards done: the review row is DONE")
	ok(CourseStore.blocks_today()["review"], "flow: the store has the review block (the home marked it)")
	eq(_greeting_text(tv), "오늘 45분 중 35분 했어요.", "flow: the greeting: 35분 after the review block")
	# 말하기 줄: 오늘 칸의 말하기 블록
	_specs.clear()
	press(_row_btn(tv, "speak"), "speak row")
	await _frames(4)
	var ps: CoursePlayer = tv.player()
	ok(ps != null, "flow: the speak row opened the player")
	if _specs.size() == 1:
		eq([_specs[0].get("kind"), _specs[0].get("w"), _specs[0].get("d")], ["speak", 1, 1], "flow: the speak unit is kind speak for 1주 1일")
	eq(ps.block, "speak", "flow: block speak")
	# [그만하기]: 기록 없이 홈으로
	var leave_pos: Dictionary = CourseStore.pos()
	press(_btn(ps, "BackBtn"), "BackBtn (speak)")
	ok(ps.leave_sheet() != null, "flow: the back button asks")
	press(ps.leave_sheet().buttons["quit"], "[그만하기] (leave sheet)")
	await _frames(4)
	ok(not tv.has_player() and (tv.scroll_host() as Control).visible, "flow: [그만하기] returns to the home page")
	eq(_row_state(tv, "speak"), "todo", "flow: leaving without finishing records nothing: the speak row is still todo")
	eq(CourseStore.pos(), leave_pos, "flow: leaving did not move pos")
	# 말하기를 이번에는 끝까지(질문 형식이 말하기 단위라 자가 평가 버튼으로)
	press(_row_btn(tv, "speak"), "speak row (again)")
	await _frames(4)
	var ps2: CoursePlayer = tv.player()
	var sp_n: int = await _play_and_finish(ps2, "speak")
	ok(sp_n >= 1, "flow: the speak unit was done by buttons (%d)" % sp_n)
	eq(_row_state(tv, "speak"), "done", "flow: the speak row is DONE")
	var th: Dictionary = {"text": tv.hero_button().text, "kind": ""}
	eq(th["text"], "더 연습하기", "flow: everything done: the start button says 더 연습하기")
	eq(_greeting_text(tv), "오늘 45분을 다 했어요. 잘했어요!", "flow: everything done: the greeting says so")
	_events.clear()
	press(tv.hero_button(), "[더 연습하기] hero")
	await _frames(2)
	eq(_events, [["navigate", "practice", "en"]], "flow: [더 연습하기] goes to practice")
	ok(presses - p0 >= 30, "E6-2: at least 30 button presses in this flow (%d)" % (presses - p0))
	# 하루 안의 기록: 같은 블록을 두 번 표시하지 않는다(복습 블록을 다시 부르면 false)
	ok(not CourseStore.mark_block("review"), "flow: the review block was marked once (a second mark says 'already')")
	ok(not CourseStore.mark_block("new") and not CourseStore.mark_block("listen") and not CourseStore.mark_block("speak"), "flow: no block can be marked twice")
	await _drop(tv)


func _find_text_button(root: Node, t: String) -> Button:
	for c in root.get_children():
		if c is Button and str(c.text) == t:
			return c
		var f: Button = _find_text_button(c, t)
		if f != null:
			return f
	return null


# ---------------------------------------------------------------- 화면: 블록 spec 계약

func _open_and_leave(tv: TodayView, btn: Button, label: String) -> Dictionary:
	_specs.clear()
	press(btn, label)
	await _frames(4)
	var p: CoursePlayer = tv.player()
	var res: Dictionary = {"opened": p != null, "kind": p.kind if p != null else "", "block": p.block if p != null else "", "w": p.w if p != null else 0,
		"d": p.d if p != null else 0, "spec": p.spec.duplicate(true) if p != null else {}, "built": _specs.duplicate(true)}
	if p != null:
		if p.state == "error":
			press(p.error_back_btn, "[돌아가기] (%s)" % label)
		else:
			press(_btn(p, "BackBtn"), "BackBtn (%s)" % label)
			var sh: Sheet = p.leave_sheet()
			if sh != null:
				press(sh.buttons["quit"], "[그만하기] (%s)" % label)
		await _frames(4)
	return res


func _test_block_specs() -> void:
	print("[contract 1: block ids reach the player]")
	# D5: 새 내용 블록 = kind speak, block new
	_world(true, 12)
	_advance_to(1, 5)
	var tv := await _make()
	eq(CourseStore.pos(), {"w": 1, "d": 5}, "specs: the course is at 1주 5일 (a speaking day)")
	var r1: Dictionary = await _open_and_leave(tv, _row_btn(tv, "new"), "D5 new row")
	ok(bool(r1["opened"]), "specs: the D5 new row opened the player")
	eq([r1["kind"], r1["block"], r1["w"], r1["d"]], ["speak", "new", 1, 5], "specs: D5 new row -> player kind speak, block NEW")
	eq(r1["spec"].get("block"), "new", "specs: the spec the player got has block 'new'")
	var r2: Dictionary = await _open_and_leave(tv, _row_btn(tv, "speak"), "D5 speak row")
	eq([r2["kind"], r2["block"]], ["speak", "speak"], "specs: D5 speak row -> kind speak, block speak")
	var r3: Dictionary = await _open_and_leave(tv, _row_btn(tv, "listen"), "D5 listen row")
	eq([r3["kind"], r3["block"]], ["listen", "listen"], "specs: D5 listen row -> kind listen, block listen")
	await _drop(tv)
	# D6: 점검
	_world(true, 12)
	_advance_to(1, 6)
	var tv6 := await _make()
	var r6: Dictionary = await _open_and_leave(tv6, _row_btn(tv6, "new"), "D6 new row")
	eq([r6["kind"], r6["block"], r6["d"]], ["check", "new", 6], "specs: D6 new row -> kind check, block new")
	await _drop(tv6)
	# 복습 우선: half
	_world(true, 45)
	var tvr := await _make()
	var rr: Dictionary = await _open_and_leave(tvr, _row_btn(tvr, "new"), "review-first new row")
	eq(rr["spec"].get("half"), true, "specs: review-first day: the new unit spec has half = true")
	await _drop(tvr)
	# recap: 8일 쉼
	_world(true, 12)
	_advance_to(2, 3, Plan.today_days() - 8)
	var tvc := await _make()
	eq(CourseStore.away_days(), 8, "specs: 8 days away")
	eq(_greeting_text(tvc), "오랜만이에요! 복귀 점검과 복습부터 가볍게 해요.", "specs: recap greeting on the real home")
	ok(_has_text(tvc, "복귀 점검 · 2주 3일"), "specs: the recap row title")
	var rc: Dictionary = await _open_and_leave(tvc, _row_btn(tvc, "new"), "recap row")
	eq([rc["kind"], rc["block"]], ["recap", "new"], "specs: recap row -> kind recap, block new")
	# recap 블록을 끝낸 뒤에도 recap 날이고 줄은 done (contract 3)
	_specs.clear()
	press(_row_btn(tvc, "new"), "recap row (play)")
	await _frames(4)
	var pr: CoursePlayer = tvc.player()
	ok(pr != null and pr.state == "run", "specs: the recap unit runs")
	if pr != null:
		await _play_and_finish(pr, "recap")
	eq(_row_state(tvc, "new"), "done", "contract 3: the recap row is done after the block")
	ok(CourseStore.blocks_today()["new"], "contract 3: blocks_today().new is true")
	ok(HomeModel.course_plan(HomeParts.snapshot("en"))["recap"], "contract 3: the day is still a recap day after the recap block")
	ok(_has_text(tvc, "복귀 점검 · 2주 3일"), "contract 3: the title still says 복귀 점검")
	eq(CourseStore.pos(), {"w": 2, "d": 3}, "contract 3: a recap does not move pos")
	await _drop(tvc)


# ---------------------------------------------------------------- 계약: reopen 한 번, 복습 우선 기록 하루 한 번

func _test_reopen_once() -> void:
	print("[contract 2: reopen_weeks is called when the home is drawn, and moves pos only once]")
	_world(true, 5)
	var t0: int = Plan.today_days() - 30
	_advance_to(2, 3, t0) # 주 1 전부와 주 2 의 1~2일, 마지막 활동 t0
	CourseStore.today_override = Plan.today_days() # 오늘: t0 로부터 30일 쉼
	eq(CourseStore.away_days(), 30, "reopen: 30 days away")
	eq(CourseStore.pos(), {"w": 2, "d": 3}, "reopen: pos is 2주 3일 before the home is drawn")
	ok(not CourseStore.reopen_applied(), "reopen: not applied yet")
	var snap0: Dictionary = HomeParts.snapshot("en")
	eq(HomeModel.course_plan(snap0)["reopen"], [1], "reopen: the plan lists week 1 (week 0 does not exist)")
	var tv := await _make()
	eq(CourseStore.pos(), {"w": 1, "d": 1}, "reopen: the first draw of the day reopened week 1: pos is 1주 1일")
	ok(CourseStore.reopen_applied(), "reopen: applied for this break")
	ok(_has_text(tv, "복귀 점검 · 1주 1일"), "reopen: the home shows the plan for the reopened cell")
	ok(_has_text(tv, "직전 두 주를 다시 열었어요"), "reopen: the note says the weeks were reopened")
	# 오늘 하루 안에서 칸을 끝낸 뒤 여러 번 다시 그려도 pos 가 되돌아가지 않는다
	CourseStore.unit_done({"unit": "new", "w": 1, "d": 1, "completed": true, "block": "new", "ok": 1, "total": 1})
	CourseStore.unit_done({"unit": "new", "w": 1, "d": 2, "completed": true, "block": "new", "ok": 1, "total": 1})
	eq(CourseStore.pos(), {"w": 1, "d": 3}, "reopen: the learner did two cells: pos 1주 3일")
	for i in 4:
		await _refresh(tv, 3)
	eq(CourseStore.pos(), {"w": 1, "d": 3}, "reopen: after 4 more redraws pos is still 1주 3일 (moved back only once)")
	eq(CourseStore.reopen_weeks([1, 2]), 0, "reopen: the store itself answers 0 for the same break")
	eq(CourseStore.pos(), {"w": 1, "d": 3}, "reopen: ... and pos did not move")
	eq(HomeModel.course_plan(HomeParts.snapshot("en"))["reopen"], [], "reopen: the plan lists nothing once applied")
	# 쉬지 않은 날에는 reopen 이 아예 없다
	_world(true, 5)
	_advance_to(2, 3, Plan.today_days() - 2)
	var tv2 := await _make()
	eq(CourseStore.pos(), {"w": 2, "d": 3}, "reopen: a 2-day break reopens nothing")
	await _drop(tv2)
	await _drop(tv)


func _test_rp_once() -> void:
	print("[contract 2: note_review_priority is applied once per day]")
	_world(true, 45)
	var tv := await _make()
	eq(_rp_today(), 1, "rp: the first draw of a review-first day wrote rp = 1")
	CourseStore.note_review_priority(false) # 같은 날 다른 값이 기록됐다고 하자
	eq(_rp_today(), 0, "rp: fixture: today's record was changed to 0")
	for i in 3:
		await _refresh(tv, 3)
	eq(_rp_today(), 0, "rp: three more redraws did NOT write it again (once per day)")
	# 다음 날: 어제 기록이 복습 우선 연속 계산에 쓰인다 -> 새 날의 첫 그림은 새 값을 쓴다
	CourseStore.note_review_priority(true)
	CourseStore.today_override = Plan.today_days() + 1
	StudyLog.today_override = Plan.today_days() + 1
	eq(CourseStore.review_state()["streak"], 1, "rp: tomorrow's plan sees yesterday as 1 day of review-first")
	await _refresh(tv, 5)
	eq(_rp_today(), 1, "rp: the first draw of the next day wrote that day's value (45 cards: 1)")
	CourseStore.today_override = -1
	StudyLog.today_override = Plan.today_days()
	await _drop(tv)
	# 카드가 적은 날은 0
	_world(true, 5)
	var tv2 := await _make()
	eq(_rp_today(), 0, "rp: a normal day wrote rp = 0")
	await _drop(tv2)


func _test_review_mark() -> void:
	print("[contract 1: the home marks the review block itself, once]")
	_world(true, 12)
	var tv := await _make()
	eq(_row_state(tv, "review"), "todo", "review mark: todo at the start")
	ok(not CourseStore.blocks_today()["review"], "review mark: the store has no review block yet")
	_review_cards(5)
	await _refresh(tv)
	eq(_row_state(tv, "review"), "todo", "review mark: 5 of 12 reviewed: still todo")
	ok(not CourseStore.blocks_today()["review"], "review mark: ... and not marked")
	_review_cards(7)
	await _refresh(tv)
	eq(_row_state(tv, "review"), "done", "review mark: all 12 reviewed: done")
	ok(CourseStore.blocks_today()["review"], "review mark: the store has it")
	var day_rec: Variant = (_course_json().get("day", {}) as Dictionary).get(CourseStore.today_iso(), {})
	eq(int((day_rec as Dictionary).get("review", 0)), 1, "review mark: the day record says review = 1 (a flag, not a count)")
	for i in 3:
		await _refresh(tv, 3)
	eq(int(((_course_json().get("day", {}) as Dictionary).get(CourseStore.today_iso(), {}) as Dictionary).get("review", 0)), 1, "review mark: three redraws: still 1")
	await _drop(tv)


# ---------------------------------------------------------------- 화면: [새 코스로 시작] 카드와 안전한 되돌아가기 (E6-7)

func _test_offer_view() -> void:
	print("[the [새 코스로 시작] card]")
	_world(false, 12)
	ok(not Store.prefs.has("course_mode"), "offer: fixture: no course mode chosen yet")
	var tv := await _make()
	var oc: Variant = tv.card("course_offer")
	ok(oc != null, "offer: English home before the choice shows the card")
	if oc != null:
		var b: Button = (oc as Control).get_meta("button")
		eq(b.text, "새 코스로 시작", "offer: the button says 새 코스로 시작")
		ok(_has_text(oc as Control, "72주"), "offer: the card says what it is (72주)")
		_events.clear()
		press(b, "[새 코스로 시작]")
		eq(_events, [["navigate", "lesson", "en"]], "offer: the button only goes to the lesson tab (the start sheet is there)")
		ok(CourseStore.mode() != "course" and not Store.prefs.has("course_mode"), "offer: nothing was started by the home")
	eq(_row_ids(tv), ["lesson", "review", "talk"], "offer: the old rows are unchanged before the choice")
	ok(not tv.card("tasks").has_meta("notes"), "offer: no course notes before the choice")
	await _drop(tv)
	# 예전 길을 골랐다 -> 카드 없음
	Store.prefs["course_mode"] = "legacy"
	var tl := await _make()
	ok(tl.card("course_offer") == null, "offer: after choosing the old path the card is gone")
	eq(_row_ids(tl), ["lesson", "review", "talk"], "offer: old path chosen: the old rows")
	await _drop(tl)
	# 코스를 시작했다 -> 카드 없음
	_world(true, 12)
	var tc := await _make()
	ok(tc.card("course_offer") == null, "offer: a running course: no card")
	await _drop(tc)
	# 일본어 -> 카드 없음
	_world(false, 12)
	Store.prefs["lang"] = "ja"
	var tj := await _make()
	ok(tj.card("course_offer") == null, "offer: Japanese: no card")
	await _drop(tj)
	# 코스 데이터가 없다 -> 카드 없음
	_world(false, 12)
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	CourseFeed.reset()
	var tg := await _make()
	ok(tg.card("course_offer") == null, "offer: no course data: no card")
	await _drop(tg)
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()


func _test_fallback_view() -> void:
	print("[E6-7 a broken course falls back to the old rows, one notice]")
	# 코스 데이터 없음
	_world(true, 12)
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	CourseFeed.reset()
	var tv := await _make()
	eq(_row_ids(tv), ["lesson", "review", "talk"], "fallback: no course data: the old rows")
	eq(tv.hero_button().text, "오늘의 레슨 시작", "fallback: no course data: the old start button")
	var nb: Variant = (tv.card("tasks") as Control).get_meta("notes", null)
	ok(nb is Control and _has_text(nb as Control, "코스 데이터를 읽지 못해"), "fallback: one notice line says the course data is missing")
	eq(((nb as Control).get_child_count()) if nb is Control else -1, 1, "fallback: exactly one notice line")
	ok(_has_text(tv, "별 0/48"), "fallback: the streak card is the old one (별 n/48)")
	ok(tv.card("course_offer") == null, "fallback: no offer card in course mode")
	await _drop(tv)
	CourseData.base_dir = K1_DIR
	CourseData.reset()
	CourseFeed.reset()
	# course.json 이 깨졌다
	_world(true, 12)
	var f := FileAccess.open(CS, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	CourseStore.reset_memory()
	var tb := await _make()
	eq(_row_ids(tb), ["lesson", "review", "talk"], "fallback: a broken course.json: the old rows")
	var nb2: Variant = (tb.card("tasks") as Control).get_meta("notes", null)
	ok(nb2 is Control and _has_text(nb2 as Control, "진도 파일을 읽지 못해"), "fallback: one notice says the progress file could not be read")
	await _drop(tb)
	# 스냅샷 훅이 {} / 이상한 것을 돌려준다
	_world(true, 12)
	var th := await _make()
	for bad in [{}, 5, null, "x", [], {"course": "x"}, {"lang": "en", "course": {"mode": "course", "w": "abc"}}]:
		th.snapshot_hook = func(_l: String) -> Variant: return bad
		await _refresh(th, 3)
		ok(th.card("tasks") != null and th.hero_button() != null, "fallback: snapshot hook returning %s: the home still draws" % JSON.stringify(bad))
	th.snapshot_hook = Callable()
	await _refresh(th, 3)
	eq(_row_ids(th), ["new", "review", "listen", "speak"], "fallback: without the hook the course rows are back")
	await _drop(th)
	# 코스 모드가 아닌 영어(예전 길)는 코스 저장소를 읽지도 않는다
	_world(false, 12)
	var snap: Dictionary = HomeParts.snapshot("en")
	ok(not snap.has("course"), "legacy: the English snapshot has no course key before the choice")
	ok(not FileAccess.file_exists(CS), "legacy: the home never created or read the course file")


# ---------------------------------------------------------------- 소스 규칙

func _test_source() -> void:
	print("[source rules]")
	for p in SRC_FILES:
		var src: String = FileAccess.get_file_as_string(p)
		ok(src != "", "source: %s is readable" % p)
		var needles: Array = ["Col" + "or(\"#", "HTTP" + "Request", "shell_" + "open", "request_" + "permission", "87" + "70", "87" + "75", "87" + "76"]
		ok(src_hits(src, needles) == 0, "source: %s has none of the forbidden calls/numbers (%d)" % [p.get_file(), src_hits(src, needles)])
		ok(glyph_hits(src) == 0, "source: %s has no emoji or shape glyphs" % p.get_file())
	var tv_src: String = FileAccess.get_file_as_string("res://scripts/ui/home_parts.gd") + FileAccess.get_file_as_string("res://scripts/core/home_model.gd")
	ok(not tv_src.contains("add_path_lesson"), "source: the home never calls add_path_lesson")
	var model_src: String = FileAccess.get_file_as_string("res://scripts/core/home_model.gd")
	ok(not model_src.contains("CourseStore.") and not model_src.contains("Store.") and not model_src.contains("StudyLog."), "source: HomeModel stays pure (no Store / CourseStore / StudyLog)")
	# 진행 글은 CourseModel.progress_label 한 곳: 새 코드에 자체 value/target 글이 없다
	var new_code: String = model_src.substr(model_src.find("# ---------------------------------------------------------------- course mode (v2.0 E6)"))
	ok(new_code.length() > 500 and src_hits(new_code, ["%d/%d"]) == 0, "C-15: the new model code has no '%d/%d' text of its own")


# ---------------------------------------------------------------- main.tscn: 요약 줄, 탭 이동

func _test_main_wiring() -> void:
	print("[E6-6/E6-10 main.gd: menu summary and the tab change]")
	var script: GDScript = load("res://scripts/main.gd")
	var m: Control = script.new() # 트리에 붙이지 않는다: _menu_summary 는 저장소만 읽는다
	_world(true, 12)
	var s1: String = m._menu_summary()
	ok(s1.contains("코스 0/72주") and not s1.contains("별"), "E6-6: course mode English summary shows the week progress, no 별 (%s)" % s1)
	ok(s1.begins_with("연속 ") and s1.contains(" · XP "), "E6-6: the summary keeps 연속 and XP (%s)" % s1)
	CourseStore.unit_done({"unit": "new", "w": 1, "d": 1, "completed": true, "block": "new", "ok": 1, "total": 1})
	for d in range(2, 8):
		CourseStore.unit_done({"unit": "new", "w": 1, "d": d, "completed": true, "block": "new", "ok": 1, "total": 1})
	ok(m._menu_summary().contains("코스 1/72주"), "E6-6: after week 1 the summary says 코스 1/72주 (%s)" % m._menu_summary())
	ok(not has_big_number([m._menu_summary()]), "C-15: the summary has no 5-digit number")
	_world(false, 12)
	var s2: String = m._menu_summary()
	ok(s2.contains(" · 별 0/48"), "E6-6: legacy English summary is the old text (%s)" % s2)
	_world(true, 12)
	Store.prefs["lang"] = "ja"
	var s3: String = m._menu_summary()
	ok(s3.contains(" · 별 0/48") and not s3.contains("코스"), "E6-6: Japanese summary is the old text even when the English course runs (%s)" % s3)
	Store.prefs["lang"] = "en"
	m.free()
	# 실제 앱: 홈의 [새 코스로 시작] -> 레슨 탭으로 바뀐다
	_world(false, 12)
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	_main = get_tree().current_scene
	ok(_main != null and _main.has_method("show_view"), "main: main.tscn is running")
	if _main == null:
		return
	_main.quit_on_exit = false
	await _frames(8)
	Store.prefs["lang"] = "en"
	_main.show_view("today")
	await _frames(5)
	var tv: TodayView = _main.views["today"]
	await _refresh(tv, 5)
	eq(str(_main.current), "today", "main: the home tab is shown")
	var oc: Variant = tv.card("course_offer")
	ok(oc != null, "main: the real home shows the [새 코스로 시작] card")
	if oc != null:
		press((oc as Control).get_meta("button"), "[새 코스로 시작] (in main)")
		await _frames(5)
		eq(str(_main.current), "lesson", "main: pressing it changed the tab to 레슨")
	_main.show_view("today")
	await _frames(3)
	# 코스 모드에서 홈의 시작 버튼 -> 플레이어가 앱 안에서 열리고, 뒤로 가기는 플레이어가 먼저 받는다
	Store.prefs["course_mode"] = "course"
	CourseStore.set_mode("course")
	CourseStore.reset_memory()
	HomeParts.reset_course_memory()
	await _refresh(tv, 5)
	ok(_row_ids(tv) == ["new", "review", "listen", "speak"], "main: the real home shows the course rows")
	press(tv.hero_button(), "[오늘 45분 시작] (in main)")
	await _frames(4)
	ok(tv.has_player(), "main: the player opened inside the app")
	_main.handle_back()
	await _frames(3)
	ok(tv.player() != null and tv.player().leave_sheet() != null, "main: the back key was taken by the player (it asked to leave)")
	press(tv.player().leave_sheet().buttons["quit"], "[그만하기] (in main)")
	await _frames(4)
	ok(not tv.has_player() and str(_main.current) == "today", "main: after leaving, the home is back")
	_main.queue_free()
	await _frames(3)
