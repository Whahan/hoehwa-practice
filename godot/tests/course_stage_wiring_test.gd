extends Node
## v2.0 E7: the six practice screens (mission, talk, shadowing, dictation, speed quiz, diary) read the course position when the
## English course is on, and the speaking-ladder lock (docs/v200_design.md §4, §14.2 E7-1 .. E7-9).
##   PC   : godot --headless --path <project>/godot res://tests/course_stage_wiring_test.tscn -- --api=http://127.0.0.1:9
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_stage_wiring_test.tscn -- --phone --api=http://127.0.0.1:9 [--font-scale=1.5] [--dark]
## Exit code 0 = all passed. Last line: "== course_stage_wiring_test: N passed, M failed ==".
## No server: the mission screen gets a fake request object, shadowing / dictation get SpeakDrill.api_hook, the real Api only
## sees the closed port (talk view). Files used: user://test_e7_* only (CourseStore.path, Store.prefs_path, Store.progress_path,
## StudyLog.path, DiaryStore.path are pointed there and restored). Buttons are pressed with `pressed.emit()` (lines "press: ...").
## The checkers are fed wrong input on purpose (lines "selfcheck FAIL-as-expected ...").

const PREFS := "user://test_e7_prefs.json"
const PROG := "user://test_e7_progress.json"
const LOG := "user://test_e7_studylog.json"
const DIARY := "user://test_e7_diary.json"
const COURSE := "user://test_e7_course.json"
const FIX_LIST := "res://tests/sample_mission_list.json"
const FIX_LIST_JA := "res://tests/sample_mission_list_ja.json"
const FIX_CHAT := "res://tests/sample_mission_chat.json"
const FIX_CHECK := "res://tests/sample_mission_check.json"
const FIX_SENT := "res://tests/sample_practice_sentences_en.json"
const NOTICE_PART := "아직 배우지 않은"
const CHAT_KEYS := ["conv_id", "history", "lang", "month", "presynth", "scenario", "skip_fix", "stage", "tts_speed", "tts_voice", "week"]
## week -> [legacy stage, legacy month, legacy week]: written out by hand (not taken from CourseModel) so the table is its own oracle.
const ROWS := [[5, 1, 1, 1], [17, 2, 4, 1], [40, 3, 7, 1], [72, 4, 10, 1]]

var passed: int = 0
var failed: int = 0
var presses: int = 0
var _before: Array = []
var _saved: Dictionary = {}
var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var _all_texts: Array = []

var calls: Array = []
var routes: Dictionary = {}


class FakeCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}

	func wait() -> Dictionary:
		if done:
			return result
		return await finished

	func complete(res: Dictionary) -> void:
		if done:
			return
		done = true
		result = res
		finished.emit(res)

	func cancel() -> void:
		complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true})


func _ready() -> void:
	print("== course_stage_wiring_test start ==")
	_before = _user_listing()
	_saved = {"course": CourseStore.path, "prefs": Store.prefs_path, "prog": Store.progress_path, "log": StudyLog.path,
		"diary": DiaryStore.path, "hook": SpeakDrill.api_hook, "store_script": CourseModel.store_script_path}
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	_clean_files()
	CourseStore.path = COURSE
	Store.prefs_path = PREFS
	Store.progress_path = PROG
	StudyLog.path = LOG
	DiaryStore.path = DIARY
	Store.progress = Progress.blank()
	Store.prefs["auto_speak"] = false
	Store.prefs["lang"] = "en"
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	_set_calendar_days_ago(170)

	_selfcheck()
	_preconditions()
	await _stage_table()
	await _bad_inputs()
	await _notice_lines()
	await _mission_flow()
	await _mission_open_weeks()
	await _talk_flow()
	await _japanese_unchanged()
	_request_shapes()
	_source_scan()
	_digit_scan()

	_restore()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	ok(not FileAccess.file_exists("user://course.json"), "no user://course.json was created")
	ok(presses >= 8, "press: lines >= 8 (%d)" % presses)
	print("== course_stage_wiring_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


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


# ---------------------------------------------------------------- environment

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


func _clean_files() -> void:
	for base in [PREFS, PROG, LOG, DIARY, COURSE]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2", ".bad.3"]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


func _restore() -> void:
	CourseStore.path = _saved["course"]
	CourseStore.reset_memory()
	CourseModel.store_script_path = _saved["store_script"]
	Store.prefs_path = _saved["prefs"]
	Store.progress_path = _saved["prog"]
	StudyLog.path = _saved["log"]
	DiaryStore.path = _saved["diary"]
	SpeakDrill.api_hook = _saved["hook"]
	Store.prefs = _saved_prefs
	Store.progress = _saved_progress
	_clean_files()


## The calendar of the old 12-month path starts `days` days ago (month 6, week 2 for 170): different from every course cell.
func _set_calendar_days_ago(days: int) -> void:
	Store.progress["start"] = Plan.days_to_iso(Plan.today_days() - days)


## Course mode with the position (w, d) written to the test course file.
func _set_course(w: Variant, d: Variant = 1) -> void:
	var f := FileAccess.open(COURSE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "started": "2026-12-01", "pos": {"w": w, "d": d}}))
	f.close()
	CourseStore.reset_memory()
	Store.prefs["course_mode"] = "course"


func _set_legacy() -> void:
	Store.prefs["course_mode"] = "legacy"
	CourseStore.reset_memory()


func _api_hook(_method: String, path: String, _body: Variant) -> Variant:
	if path.begins_with("/practice/sentences"):
		return {"ok": true, "code": 200, "data": JSON.parse_string(FileAccess.get_file_as_string(FIX_SENT))}
	return {"ok": false, "code": 404, "error": "없는 경로예요."}


func frames(n: int = 3) -> void:
	for i in n:
		await get_tree().process_frame


func wait_until(cond: Callable, timeout: float = 8.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not cond.call():
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout:
			return false
		await get_tree().process_frame
	return true


func host(node: Control, sz: Vector2) -> Control:
	var h := Control.new()
	h.custom_minimum_size = sz
	h.size = sz
	add_child(h)
	h.add_child(node)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return h


func free_host(h: Control) -> void:
	h.queue_free()
	await frames(2)


func _size() -> Vector2:
	return Vector2(412, 915) if Platform.is_phone() else Vector2(1280, 800)


# ---------------------------------------------------------------- tree helpers

func texts(node: Node, out: Array = []) -> Array:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	elif node is RichTextLabel:
		out.append((node as RichTextLabel).text)
	for ch in node.get_children():
		texts(ch, out)
	return out


func has_text(node: Node, part: String) -> bool:
	for t in texts(node):
		if str(t).contains(part):
			return true
	return false


func count_text(node: Node, part: String) -> int:
	var n := 0
	for t in texts(node):
		if str(t).contains(part):
			n += 1
	return n


func remember(node: Node) -> void:
	_all_texts.append_array(texts(node))


func find_button(node: Node, text: String) -> Button:
	if node is Button and node.is_visible_in_tree() and (node as Button).text == text:
		return node as Button
	for ch in node.get_children():
		var f: Button = find_button(ch, text)
		if f != null:
			return f
	return null


## The button `btn_text` of the card whose title label is `title` (the smallest ancestor of the title that holds such a button).
func card_button(root: Node, title: String, btn_text: String) -> Button:
	var lab: Label = _find_label(root, title)
	if lab == null:
		return null
	var n: Node = lab.get_parent()
	for i in 8:
		if n == null:
			return null
		var b: Button = find_button(n, btn_text)
		if b != null:
			return b
		n = n.get_parent()
	return null


func _find_label(node: Node, text: String) -> Label:
	if node is Label and (node as Label).text == text and (node as Label).is_visible_in_tree():
		return node as Label
	for ch in node.get_children():
		var f: Label = _find_label(ch, text)
		if f != null:
			return f
	return null


func find_open_sheet(node: Node) -> Sheet:
	if node is Sheet and not (node as Sheet).is_closed():
		return node as Sheet
	for ch in node.get_children():
		var f: Sheet = find_open_sheet(ch)
		if f != null:
			return f
	return null


## Presses a real button (REVIEW.md: never the function behind it) and says so in the log.
func press(b: Button, what: String) -> void:
	var usable: bool = b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled
	ok(usable, "press target usable: " + what)
	if not usable:
		return
	print("press: ", what)
	presses += 1
	b.pressed.emit()


## A tap on a card made of a PanelContainer (UI.on_tap: PC reacts to the press, the phone to the release).
func tap(c: Control, what: String) -> void:
	var usable: bool = c != null and is_instance_valid(c) and c.is_visible_in_tree()
	ok(usable, "tap target usable: " + what)
	if not usable:
		return
	print("press: tap ", what)
	presses += 1
	var pos := Vector2(6, 6)
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.position = pos
		ev.global_position = c.get_global_rect().position + pos
		c.gui_input.emit(ev)


func find_by_name(node: Node, access_name: String) -> Control:
	if node is Control and (node as Control).accessibility_name == access_name and (node as Control).is_visible_in_tree():
		return node as Control
	for ch in node.get_children():
		var f: Control = find_by_name(ch, access_name)
		if f != null:
			return f
	return null


func digit_runs(list: Array) -> Array:
	var re := RegEx.new()
	re.compile("\\d{5,}")
	var out: Array = []
	for t in list:
		if re.search(str(t)) != null:
			out.append(str(t))
	return out


func qp(q: String, key: String) -> int:
	for part in q.split("&"):
		var kv: PackedStringArray = part.split("=")
		if kv.size() == 2 and kv[0] == key:
			return int(kv[1])
	return -999


# ---------------------------------------------------------------- selfcheck / preconditions

func _selfcheck() -> void:
	print("[selfcheck: the checkers must be able to fail]")
	var lab := Label.new()
	lab.text = "남은 시간 12345"
	add_child(lab)
	ok(not digit_runs(texts(lab)).is_empty(), "selfcheck FAIL-as-expected: a label with 12345 is caught by the digit scan")
	ok(digit_runs(["5주차 · 3개"]).is_empty(), "digit scan passes ordinary text")
	lab.queue_free()
	ok(qp("lang=en&stage=1&month=1&week=1", "month") == 1 and qp("lang=en&stage=1", "month") == -999, "query parser reads a key and reports a missing one")
	var bad_lock: Control = Label.new()
	(bad_lock as Label).text = "26주차부터 열려요"
	ok(not has_text(bad_lock, "25주차"), "selfcheck FAIL-as-expected: a lock text with the wrong week is rejected")
	bad_lock.queue_free()
	ok(find_open_sheet(self) == null, "no sheet is open before the screens are used")
	var rig := Control.new()
	add_child(rig)
	ok(card_button(rig, "없는 카드", "선택") == null, "selfcheck FAIL-as-expected: card_button on an empty tree finds nothing")
	rig.queue_free()
	ok(MissionScreen.lock_text("en", "ai") == "", "no lock text while the course is off")


func _preconditions() -> void:
	print("[preconditions]")
	_set_legacy()
	var cal: Dictionary = Store.position()
	ok(int(cal["n"]) >= 5 and int(cal["w"]) >= 1, "the test calendar is at month %d week %d (differs from every course cell)" % [int(cal["n"]), int(cal["w"])])
	_set_course(5, 3)
	var p: Dictionary = CourseModel.pos_for("en")
	eq([p["cw"], p["cd"], p["stage"], p["n"], p["w"]], [5, 3, 1, 1, 1], "course mode week 5 day 3 reads through CourseModel.pos_for")
	var pj: Dictionary = CourseModel.pos_for("ja")
	eq(pj["cw"], 0, "Japanese never uses the course position")
	_set_legacy()


# ---------------------------------------------------------------- E7-3 stage table

func _screens(l: String) -> Dictionary:
	var sh := ShadowScreen.new()
	sh.lang = l
	var di := DictationScreen.new()
	di.lang = l
	var ms := MissionScreen.new()
	ms.lang = l
	ms.mission = {"id": "cafe_order", "min_stage": 2, "scenario": {"id": "mission:cafe_order"}}
	var df := DiaryScreen.new()
	df.lang = l
	var sp := SpeedScreen.new()
	sp.lang = l
	var h := Control.new()
	h.size = Vector2(412, 800)
	add_child(h)
	for n in [sh, di, ms, df, sp]:
		h.add_child(n)
	return {"host": h, "shadow": sh, "dict": di, "mission": ms, "diary": df, "speed": sp}


func _talk_screen(l: String) -> Array:
	Store.prefs["lang"] = l
	var tv := TalkView.new()
	var h := host(tv, _size())
	return [h, tv]


func _expect_row(tag: String, l: String, stage: int, month: int, week: int) -> void:
	var s: Dictionary = _screens(l)
	var sq: String = (s["shadow"] as ShadowScreen).sentences_query()
	var dq: String = (s["dict"] as DictationScreen).sentences_query()
	var ms: MissionScreen = s["mission"]
	var pay: Dictionary = ms._chat_payload()
	eq([qp(sq, "stage"), qp(sq, "month"), qp(sq, "week")], [stage, month, week], "%s: shadow query stage/month/week" % tag)
	eq([qp(dq, "stage"), qp(dq, "month"), qp(dq, "week")], [stage, month, week], "%s: dictation query stage/month/week" % tag)
	eq([int(pay["month"]), int(pay["week"])], [month, week], "%s: mission chat payload month/week" % tag)
	eq(int(pay["stage"]), 2, "%s: mission chat payload stage stays the mission's own min_stage" % tag)
	eq(ms._user_stage(), stage, "%s: mission _user_stage" % tag)
	eq((s["diary"] as DiaryScreen)._fix_stage(), stage, "%s: diary _fix_stage" % tag)
	eq((s["speed"] as SpeedScreen)._pool_month(), month, "%s: speed quiz word month" % tag)
	(s["host"] as Control).queue_free()
	var t: Array = _talk_screen(l)
	var tv: TalkView = t[1]
	await frames(2)
	eq([int(tv.sel["stage"]), int(tv.sel["n"]), int(tv.sel["w"])], [stage, month, week], "%s: talk start selection stage/n/w" % tag)
	await free_host(t[0])


func _stage_table() -> void:
	print("[E7-3: course weeks 5 / 17 / 40 / 72 and the calendar]")
	for r in ROWS:
		var w: int = r[0]
		_set_course(w, 2)
		await _expect_row("course en w%d" % w, "en", r[1], r[2], r[3])
	# the same course position must never reach Japanese: it keeps the calendar
	var cal: Dictionary = Store.position()
	var cal_stage: int = Plan.stage_of(int(cal["n"]))
	_set_course(40, 2)
	await _expect_row("course on, ja w40", "ja", cal_stage, int(cal["n"]), int(cal["w"]))
	_set_legacy()
	await _expect_row("legacy en", "en", cal_stage, int(cal["n"]), int(cal["w"]))
	await _expect_row("legacy ja", "ja", cal_stage, int(cal["n"]), int(cal["w"]))
	# course mode + the course week moves: an open talk view follows (refresh re-reads it)
	_set_course(5, 1)
	var t: Array = _talk_screen("en")
	var tv: TalkView = t[1]
	await frames(2)
	eq(int(tv.sel["n"]), 1, "talk view built in course week 5 starts at month 1")
	_set_course(40, 1)
	tv.refresh()
	await frames(1)
	eq([int(tv.sel["stage"]), int(tv.sel["n"])], [3, 7], "the open talk view follows the course week after refresh (week 40 -> stage 3, month 7)")
	_set_legacy()
	tv.refresh()
	await frames(1)
	eq(int(tv.sel["n"]), int(cal["n"]), "leaving the course puts the calendar month back in the talk view")
	await free_host(t[0])
	var sc: Dictionary = _screens("en")
	_set_course(40, 1)
	var before: String = (sc["shadow"] as ShadowScreen).sentences_query()
	eq(qp(before, "stage"), 3, "shadow query is read at call time (week 40 -> stage 3)")
	(sc["host"] as Control).queue_free()
	await frames(2)


# ---------------------------------------------------------------- E7-6 bad inputs

func _bad_inputs() -> void:
	print("[E7-6: broken course files / values]")
	_set_calendar_days_ago(0)
	var cal: Dictionary = Store.position()
	eq([int(cal["n"]), Plan.stage_of(int(cal["n"]))], [1, 1], "bad-input calendar is month 1 (default stage 1)")
	var cases: Array = [
		["w=0", func() -> void: _set_course(0, 1), 1],
		["w=99", func() -> void: _set_course(99, 1), 4],
		["w=-3", func() -> void: _set_course(-3, 2), 1],
		["w=null", func() -> void: _set_course(null, null), 1],
		["w=text", func() -> void: _set_course("abc", "x"), 1],
		["w=1.9e30", func() -> void: _set_course(1.9e30, 1), 4],
		["pos=null", func() -> void: _write_course_text('{"v":1,"pos":null}'), 1],
		["broken json", func() -> void: _write_course_text('{"v":1,"pos":{"w":5,'), 1],
		["empty file", func() -> void: _write_course_text(""), 1],
		["array file", func() -> void: _write_course_text("[1,2,3]"), 1],
		["no file", func() -> void: _no_course_file(), 1],
		["mode=5 (not a string)", func() -> void: _course_with_mode(5), 1],
		["mode=null", func() -> void: _course_with_mode(null), 1],
	]
	for c in cases:
		var name: String = c[0]
		var literal_stage: int = c[2]
		(c[1] as Callable).call()
		var pos: Dictionary = CourseModel.pos_for("en")
		var want_stage: int = int(pos["stage"])
		eq(want_stage, literal_stage, "%s: the stage is %d (a value the store clamps stays in the course, an unusable one is the default 1)" % [name, literal_stage])
		ok(want_stage >= 1 and want_stage <= 4, "%s: pos_for gives a stage 1..4 (%d)" % [name, want_stage])
		# a value the store cannot use falls back to the calendar (stage 1 here); a value it could clamp is clamped by the store
		var in_course: bool = int(pos["cw"]) > 0
		var s: Dictionary = _screens("en")
		var sq: String = (s["shadow"] as ShadowScreen).sentences_query()
		var dq: String = (s["dict"] as DictationScreen).sentences_query()
		var pay: Dictionary = (s["mission"] as MissionScreen)._chat_payload()
		var stages: Array = [qp(sq, "stage"), qp(dq, "stage"), (s["mission"] as MissionScreen)._user_stage(), (s["diary"] as DiaryScreen)._fix_stage()]
		eq(stages, [want_stage, want_stage, want_stage, want_stage], "%s: shadow / dictation / mission / diary use the same stage %d" % [name, want_stage])
		eq([qp(sq, "month"), qp(dq, "month"), int(pay["month"]), (s["speed"] as SpeedScreen)._pool_month()], [int(pos["n"]), int(pos["n"]), int(pos["n"]), int(pos["n"])], "%s: month agrees on all screens" % name)
		if not in_course:
			eq(want_stage, 1, "%s: not usable as a course position -> default stage 1" % name)
		var t: Array = _talk_screen("en")
		await frames(2)
		eq(int((t[1] as TalkView).sel["stage"]), want_stage, "%s: talk view starts at the same stage" % name)
		await free_host(t[0])
		# Japanese never sees the English course
		var sj: Dictionary = _screens("ja")
		eq(qp((sj["shadow"] as ShadowScreen).sentences_query(), "stage"), 1, "%s: Japanese shadow query keeps the calendar stage 1" % name)
		eq((sj["mission"] as MissionScreen)._user_stage(), 1, "%s: Japanese mission stage keeps the calendar stage 1" % name)
		(sj["host"] as Control).queue_free()
		(s["host"] as Control).queue_free()
		await frames(1)
	# a course script that cannot be loaded (the store class is missing): the calendar, no error
	_set_course(40, 1)
	CourseModel.store_script_path = "res://scripts/core/no_such_store.gd"
	var s2: Dictionary = _screens("en")
	eq(qp((s2["shadow"] as ShadowScreen).sentences_query(), "stage"), 1, "missing course store script -> calendar stage 1")
	(s2["host"] as Control).queue_free()
	CourseModel.store_script_path = _saved["store_script"]
	ok(MissionScreen.course_week("fr") == 0 and MissionScreen.course_week("") == 0, "course_week of an unknown language is 0")
	_set_calendar_days_ago(170)
	_set_legacy()
	await frames(2)


## A good course file (week 40) but a course_mode value that is not the text "course": the course must stay off.
func _course_with_mode(v: Variant) -> void:
	_set_course(40, 1)
	Store.prefs["course_mode"] = v


func _write_course_text(t: String) -> void:
	var f := FileAccess.open(COURSE, FileAccess.WRITE)
	f.store_string(t)
	f.close()
	CourseStore.reset_memory()
	Store.prefs["course_mode"] = "course"


func _no_course_file() -> void:
	for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2", ".bad.3"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(COURSE + suffix))
	CourseStore.reset_memory()
	Store.prefs["course_mode"] = "course"


# ---------------------------------------------------------------- E7-9 the one-line notice

func _notice_lines() -> void:
	print("[E7-9: the notice at the top of shadowing / dictation / talk / mission]")
	for mode in ["course", "legacy"]:
		for l in ["en", "ja"]:
			if mode == "course":
				_set_course(5, 1)
			else:
				_set_legacy()
			var expect: bool = mode == "course" and l == "en"
			var tag := "%s %s" % [mode, l]
			Store.prefs["lang"] = l
			# shadowing: start page, then a week session through the button
			var sh := ShadowScreen.new()
			var hs := host(sh, _size())
			await frames(2)
			sh.open(l, {})
			await frames(3)
			eq(has_text(sh, NOTICE_PART), expect, "%s: shadowing start page notice" % tag)
			if l == "en":
				var start_btn: Button = find_button(sh, "시작하기")
				press(start_btn, "shadowing 시작하기 (%s)" % tag)
				await wait_until(func() -> bool: return sh.stage == "run")
				eq(sh.stage, "run", "%s: shadowing reached the run page" % tag)
				eq(has_text(sh, NOTICE_PART), expect, "%s: shadowing run page notice" % tag)
			remember(sh)
			await free_host(hs)
			# dictation
			var di := DictationScreen.new()
			var hd := host(di, _size())
			await frames(2)
			di.open(l, {})
			await wait_until(func() -> bool: return di.stage != "loading", 3.0)
			eq(has_text(di, NOTICE_PART), expect, "%s: dictation page notice (%s)" % [tag, di.stage])
			remember(di)
			await free_host(hd)
			# talk view
			var t: Array = _talk_screen(l)
			await frames(2)
			eq(has_text(t[1], NOTICE_PART), expect, "%s: talk view setup notice" % tag)
			remember(t[1])
			await free_host(t[0])
	_set_legacy()


# ---------------------------------------------------------------- E7-2 / E7-4: the mission flow through the real buttons

func _mission_list() -> Dictionary:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX_LIST))
	var cafe: Dictionary = {}
	for m in d["missions"]:
		if m is Dictionary and str((m as Dictionary).get("id", "")) == "cafe_order" and cafe.is_empty():
			cafe = m
	var si: Dictionary = cafe.duplicate(true)
	si["id"] = "self_intro"
	si["title_ko"] = "자기소개 하기"
	(si["scenario"] as Dictionary)["id"] = "mission:self_intro"
	(d["missions"] as Array).append(si)
	return d


func _res(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false}


func _fake(method: String, path: String, body: Variant, _timeout: float) -> Variant:
	var p: String = path.split("?")[0]
	calls.append({"method": method, "path": p, "body": body})
	var fc := FakeCall.new()
	var res: Dictionary
	match p:
		"/missions":
			res = _res(JSON.parse_string(FileAccess.get_file_as_string(FIX_LIST_JA)) if path.contains("lang=ja") else _mission_list())
		"/missions/check":
			res = _res(JSON.parse_string(FileAccess.get_file_as_string(FIX_CHECK)))
		"/chat":
			res = _res(JSON.parse_string(FileAccess.get_file_as_string(FIX_CHAT)))
		_:
			res = {"ok": false, "code": 404, "data": null, "bytes": PackedByteArray(), "error": "없는 경로예요.", "cancelled": false}
	_complete_later(fc, res)
	return fc


func _complete_later(fc: FakeCall, res: Dictionary) -> void:
	await get_tree().process_frame
	fc.complete(res)


## Hub -> mission list. The hub opens the screen with the real Api (closed port) and so it shows the retry button;
## the fake request object is put in and [다시 시도] is pressed, a real button of the screen.
func _open_missions_via_hub(v: PracticeView, label: String) -> MissionScreen:
	press(find_button(v, "미션 고르기"), "hub 미션 고르기 (%s)" % label)
	await frames(3)
	var ms: MissionScreen = v.current_screen() as MissionScreen
	ok(ms != null, "%s: the hub opened the mission screen" % label)
	if ms == null:
		return null
	await wait_until(func() -> bool: return ms.status == "list", 8.0)
	ms.http = Callable(self, "_fake")
	ms.llm_override = 0
	var retry: Button = find_button(ms, "다시 시도")
	if retry != null:
		press(retry, "mission list 다시 시도 (%s)" % label)
	else:
		ms.open(ms.lang)
	await wait_until(func() -> bool: return ms.status == "list" and not ms.missions.is_empty(), 8.0)
	return ms


func _mission_flow() -> void:
	print("[E7-2 / E7-4: week 5 mission list -> locked mission -> sheet -> both buttons]")
	_set_course(5, 1)
	Store.prefs["lang"] = "en"
	var v := PracticeView.new()
	var h := host(v, _size())
	v.refresh()
	await frames(3)
	var ms: MissionScreen = await _open_missions_via_hub(v, "w5")
	if ms == null:
		await free_host(h)
		return
	# E7-4: the list
	ok(ms.missions.size() == 4, "the list has 4 playable missions (%d)" % ms.missions.size())
	var first_two: Array = [str(ms.missions[0]["id"]), str(ms.missions[1]["id"])]
	first_two.sort()
	eq(first_two, ["cafe_order", "self_intro"], "week 5: the two stage 1 missions come first")
	eq(ms._user_stage(), 1, "week 5: the mission screen's own stage is 1")
	eq(count_text(ms, "맞는 단계"), 2, "week 5: exactly 2 cards say 맞는 단계")
	eq(count_text(ms, "더 나중에"), 2, "week 5: the other 2 cards say 더 나중에")
	eq(count_text(ms, "조금 어려워요"), 0, "week 5: the old 조금 어려워요 wording is not used in the course")
	ok(has_text(ms, "13주차") and has_text(ms, "25주차"), "week 5: the list says when script (13) and AI (25) missions open")
	ok(has_text(ms, NOTICE_PART), "week 5: the notice is at the top of the mission list")
	remember(ms)
	# E7-2: the locked mission, AI mode
	press(card_button(ms, "카페에서 음료 주문하기", "선택"), "mission card 카페에서 음료 주문하기 선택")
	await frames(3)
	eq(ms.status, "brief", "the card opens the brief page")
	ok(has_text(ms, NOTICE_PART), "week 5: the notice is at the top of the brief page")
	remember(ms)
	press(find_button(ms, "미션 시작"), "brief 미션 시작 (AI mode, closed)")
	await frames(3)
	var sh: Sheet = find_open_sheet(self)
	ok(sh != null, "the locked AI mission opens a sheet")
	if sh != null:
		var body: Array = texts(sh)
		ok(has_text(sh, "25주차"), "the sheet says 25주차")
		ok(has_text(sh, "5주차예요"), "the sheet says the current week (5주차예요)")
		ok(sh.buttons.has("go") and (sh.buttons["go"] as Button).text == "그래도 해 보기", "the sheet has [그래도 해 보기]")
		ok(sh.buttons.has("close") and (sh.buttons["close"] as Button).text == "닫기", "the sheet has [닫기]")
		print("lock sheet (AI): ", " | ".join(PackedStringArray(body.map(func(t: Variant) -> String: return str(t)))))
		remember(sh)
		eq(ms.status, "brief", "while the sheet is open the mission has not started")
		press(sh.buttons.get("close") as Button, "lock sheet 닫기")
		await frames(3)
		eq(ms.status, "brief", "[닫기] keeps the brief page (no chat started)")
		ok(ms.msgs.is_empty(), "[닫기] sent no first message")
		eq(Sheet.depth(), 0, "the sheet is closed")
	press(find_button(ms, "미션 시작"), "brief 미션 시작 again")
	await frames(3)
	sh = find_open_sheet(self)
	ok(sh != null, "pressing again asks again")
	if sh != null:
		press(sh.buttons.get("go") as Button, "lock sheet 그래도 해 보기")
		await frames(4)
		eq(ms.status, "talk", "[그래도 해 보기] starts the mission anyway")
		eq(ms.mode, "ai", "...in AI mode")
		ok(ms.msgs.size() == 1, "...with the opening line")
	# back to the list through the screen's own back button
	press(ms._back_btn, "mission back button (to the list)")
	await frames(3)
	eq(ms.status, "list", "back from the chat is the list")
	# script mode, week 5: closed too (13)
	press(card_button(ms, "카페에서 음료 주문하기", "선택"), "mission card again")
	await frames(3)
	press(find_button(ms, "대본 모드로 연습"), "brief 대본 모드로 연습 (closed at week 5)")
	await frames(3)
	sh = find_open_sheet(self)
	ok(sh != null and has_text(sh, "13주차"), "week 5: the script mode sheet says 13주차")
	if sh != null:
		print("lock sheet (script): ", " | ".join(PackedStringArray(texts(sh).map(func(t: Variant) -> String: return str(t)))))
		press(sh.buttons.get("go") as Button, "script lock sheet 그래도 해 보기")
		await frames(4)
		eq(ms.status, "talk", "week 5: script mode starts after [그래도 해 보기]")
		eq(ms.mode, "script", "...in script mode")
	remember(ms)
	await free_host(h)
	_set_legacy()


## Mission lock at the open weeks 12 / 13 / 24 / 25 (the constants of the ladder), one screen built directly.
func _mission_open_weeks() -> void:
	print("[E7-2: the lock follows the ladder weeks]")
	for row in [[12, true, true], [13, false, true], [24, false, true], [25, false, false]]:
		var w: int = row[0]
		_set_course(w, 1)
		Store.prefs["lang"] = "en"
		var ms := MissionScreen.new()
		ms.http = Callable(self, "_fake")
		ms.llm_override = 0
		var h := host(ms, _size())
		await frames(2)
		ms.open("en", {"mission_id": "cafe_order"})
		await wait_until(func() -> bool: return ms.status == "brief", 8.0)
		eq(ms.status, "brief", "week %d: opened the brief page" % w)
		var script_locked: bool = row[1]
		var ai_locked: bool = row[2]
		press(find_button(ms, "대본 모드로 연습"), "week %d 대본 모드로 연습" % w)
		await frames(3)
		var sh: Sheet = find_open_sheet(self)
		eq(sh != null, script_locked, "week %d: script mode sheet shown = %s" % [w, str(script_locked)])
		if sh != null:
			press(sh.buttons.get("close") as Button, "week %d script lock sheet 닫기" % w)
			await frames(2)
		else:
			eq(ms.mode, "script", "week %d: script mode started without asking" % w)
			ms._abandon()
			await frames(2)
			ms._select("cafe_order")
			await frames(2)
		var ai_btn: Button = find_button(ms, "미션 시작")
		press(ai_btn, "week %d 미션 시작" % w)
		await frames(3)
		sh = find_open_sheet(self)
		eq(sh != null, ai_locked, "week %d: AI mission sheet shown = %s" % [w, str(ai_locked)])
		if sh != null:
			ok(has_text(sh, "25주차"), "week %d: the AI sheet says 25주차" % w)
			press(sh.buttons.get("close") as Button, "week %d AI lock sheet 닫기" % w)
			await frames(2)
			eq(ms.status, "brief", "week %d: closed sheet leaves the brief page" % w)
		else:
			eq(ms.status, "talk", "week %d: AI mission started without asking" % w)
		await free_host(h)
	_set_legacy()


# ---------------------------------------------------------------- E7-2: the talk view

func _talk_flow() -> void:
	print("[E7-2: talk view, free conversation at week 5]")
	_set_course(5, 1)
	Store.prefs["lang"] = "en"
	var t: Array = _talk_screen("en")
	var tv: TalkView = t[1]
	await frames(3)
	tap(find_by_name(tv, "자유 대화"), "talk card 자유 대화")
	await frames(2)
	eq(str(tv.sel["scen"]), "free", "the tap selected the free conversation")
	press(find_button(tv, "대화 시작"), "talk 대화 시작 (free, closed)")
	await frames(3)
	var sh: Sheet = find_open_sheet(self)
	ok(sh != null, "free conversation at week 5 asks first")
	eq(tv.status, "setup", "...and has not started")
	if sh != null:
		ok(has_text(sh, "17주차"), "the sheet says 17주차")
		ok(has_text(sh, "5주차예요"), "the sheet says the current week (5주차예요)")
		print("lock sheet (free talk): ", " | ".join(PackedStringArray(texts(sh).map(func(x: Variant) -> String: return str(x)))))
		remember(sh)
		press(sh.buttons.get("close") as Button, "talk lock sheet 닫기")
		await frames(3)
		eq(tv.status, "setup", "[닫기] stays on the setup page")
		eq(Sheet.depth(), 0, "the talk sheet is closed")
	press(find_button(tv, "대화 시작"), "talk 대화 시작 again")
	await frames(3)
	sh = find_open_sheet(self)
	ok(sh != null, "pressing again asks again")
	if sh != null:
		press(sh.buttons.get("go") as Button, "talk lock sheet 그래도 해 보기")
		await frames(3)
		ok(tv.status == "wait" or tv.status == "talk", "[그래도 해 보기] starts the conversation (%s)" % tv.status)
		eq(str(tv.sc.get("id", "")), "free", "...the free conversation")
	remember(tv)
	tv.go_back()
	await frames(2)
	await free_host(t[0])
	# the topic conversation is not part of the lock
	var t2: Array = _talk_screen("en")
	var tv2: TalkView = t2[1]
	await frames(3)
	press(find_button(tv2, "대화 시작"), "talk 대화 시작 (this month's topic)")
	await frames(3)
	ok(find_open_sheet(self) == null, "this month's topic is not locked at week 5")
	ok(tv2.status == "wait" or tv2.status == "talk", "...it starts at once (%s)" % tv2.status)
	tv2.go_back()
	await frames(2)
	await free_host(t2[0])
	# week 17 and later: open
	_set_course(17, 1)
	var t3: Array = _talk_screen("en")
	var tv3: TalkView = t3[1]
	await frames(3)
	tap(find_by_name(tv3, "자유 대화"), "talk card 자유 대화 (week 17)")
	await frames(2)
	press(find_button(tv3, "대화 시작"), "talk 대화 시작 (free, week 17)")
	await frames(3)
	ok(find_open_sheet(self) == null, "week 17: the free conversation is open")
	ok(tv3.status == "wait" or tv3.status == "talk", "week 17: it starts at once (%s)" % tv3.status)
	tv3.go_back()
	await frames(2)
	await free_host(t3[0])
	_set_legacy()


# ---------------------------------------------------------------- Japanese and non-course English stay as they were

func _japanese_unchanged() -> void:
	print("[Japanese and non-course English: no lock, no notice, same list wording]")
	_set_course(5, 1)
	Store.prefs["lang"] = "ja"
	var ms := MissionScreen.new()
	ms.http = Callable(self, "_fake")
	ms.llm_override = 0
	var h := host(ms, _size())
	await frames(2)
	ms.open("ja", {})
	await wait_until(func() -> bool: return ms.status == "list" and not ms.missions.is_empty(), 8.0)
	ok(not ms.missions.is_empty(), "the Japanese list loads")
	ok(not has_text(ms, NOTICE_PART), "Japanese list: no notice")
	ok(not has_text(ms, "더 나중에") and not has_text(ms, "맞는 단계"), "Japanese list: no course wording")
	ok(not has_text(ms, "주차부터 열려요"), "Japanese list: no ladder note")
	var first_id: String = str(ms.missions[0]["id"])
	ms._select(first_id)
	await frames(2)
	press(find_button(ms, "미션 시작"), "ja brief 미션 시작 (course on, Japanese)")
	await frames(3)
	ok(find_open_sheet(self) == null, "Japanese: no lock sheet even while the English course is on")
	eq(ms.status, "talk", "Japanese: the mission starts at once")
	await free_host(h)
	# English without the course keeps the old wording
	_set_legacy()
	Store.prefs["lang"] = "en"
	var ms2 := MissionScreen.new()
	ms2.http = Callable(self, "_fake")
	ms2.llm_override = 0
	var h2 := host(ms2, _size())
	await frames(2)
	ms2.open("en", {})
	await wait_until(func() -> bool: return ms2.status == "list" and not ms2.missions.is_empty(), 8.0)
	var cal_stage: int = Plan.stage_of(int(Store.position()["n"]))
	var hard: int = 0
	for m in ms2.missions:
		if int((m as Dictionary)["min_stage"]) > cal_stage:
			hard += 1
	eq(count_text(ms2, "조금 어려워요"), hard, "non-course English: 조금 어려워요 on the %d cards above the calendar stage" % hard)
	eq(count_text(ms2, "더 나중에") + count_text(ms2, "맞는 단계"), 0, "non-course English: no course wording")
	ok(not has_text(ms2, NOTICE_PART), "non-course English: no notice on the mission list")
	ok(not has_text(ms2, "주차부터 열려요"), "non-course English: no ladder note")
	ms2._select("cafe_order")
	await frames(2)
	press(find_button(ms2, "미션 시작"), "legacy brief 미션 시작")
	await frames(3)
	ok(find_open_sheet(self) == null and ms2.status == "talk", "non-course English: starts without asking")
	await free_host(h2)
	# talk view: free conversation without the course
	var t: Array = _talk_screen("en")
	await frames(3)
	tap(find_by_name(t[1], "자유 대화"), "legacy talk card 자유 대화")
	await frames(2)
	press(find_button(t[1], "대화 시작"), "legacy talk 대화 시작 (free)")
	await frames(3)
	ok(find_open_sheet(self) == null, "non-course English: the free conversation starts without asking")
	(t[1] as TalkView).go_back()
	await frames(2)
	await free_host(t[0])
	Store.prefs["lang"] = "en"


# ---------------------------------------------------------------- E7-8 request shapes, E7-3 more

func _request_shapes() -> void:
	print("[E7-8: request shapes unchanged]")
	_set_course(17, 1)
	var s: Dictionary = _screens("en")
	var keys: Array = (s["mission"] as MissionScreen)._chat_payload().keys()
	keys.sort()
	eq(keys, CHAT_KEYS, "mission /chat body keeps its keys")
	var q: String = (s["shadow"] as ShadowScreen).sentences_query()
	var names: Array = []
	for part in q.split("&"):
		names.append(part.split("=")[0])
	eq(names.slice(0, 7), ["lang", "mode", "stage", "month", "week", "n", "seed"], "shadow query keeps its fields and order")
	ok(names.size() == 7 or (names.size() == 8 and names[7] == "exclude"), "shadow query has no new field (only the old optional exclude)")
	var q2: String = (s["dict"] as DictationScreen).sentences_query()
	names = []
	for part in q2.split("&"):
		names.append(part.split("=")[0])
	eq(names.slice(0, 7), ["lang", "mode", "stage", "month", "week", "n", "seed"], "dictation query keeps its fields and order")
	ok(names.size() == 7 or (names.size() == 8 and names[7] == "exclude"), "dictation query has no new field (only the old optional exclude)")
	(s["host"] as Control).queue_free()
	_set_legacy()
	var cal: Dictionary = Store.position()
	var s2: Dictionary = _screens("en")
	var pay: Dictionary = (s2["mission"] as MissionScreen)._chat_payload()
	eq([int(pay["month"]), int(pay["week"])], [int(cal["n"]), int(cal["w"])], "non-course English: the payload carries Store.position() as before")
	(s2["host"] as Control).queue_free()
	var store_text: String = FileAccess.get_file_as_string("res://scripts/autoload/store.gd").replace("\r\n", "\n")
	ok(store_text.contains("func position() -> Dictionary:\n\treturn Plan.position(start_iso(), Plan.today_days())"), "Store.position() is the same one-liner")


# ---------------------------------------------------------------- source and text scans (C-4, C-11, C-15)

func _forbidden() -> Array:
	return ["87" + "70", "87" + "75", "87" + "76", "Color(" + "\"#"]


## Only for the new file: the shadowing screen already opens the source link of a Tatoeba sentence before this change.
func _forbidden_new_file() -> Array:
	return ["HTTP" + "Request", "OS.shell" + "_open", "request" + "_permission", "%d" + "/" + "%d"]


func _has_symbol_chars(text: String) -> bool:
	for i in text.length():
		var c: int = text.unicode_at(i)
		if (c >= 0x2190 and c <= 0x2BFF and c != 0x2190 and c != 0x2192) or c >= 0x1F000:
			return true
	return false


func _source_scan() -> void:
	print("[source scan]")
	var files: Array = ["res://scripts/practice/mission_screen.gd", "res://scripts/views/talk_view.gd", "res://scripts/practice/shadow_screen.gd",
		"res://scripts/practice/dictation_screen.gd", "res://scripts/practice/speed_screen.gd", "res://scripts/practice/diary_screen.gd",
		"res://tests/course_stage_wiring_test.gd"]
	for f in files:
		var text: String = FileAccess.get_file_as_string(f)
		ok(text.length() > 0, "%s is readable" % f.get_file())
		for bad in _forbidden():
			ok(not text.contains(bad), "%s has no %s" % [f.get_file(), bad])
		if f.ends_with("course_stage_wiring_test.gd"):
			for bad2 in _forbidden_new_file():
				ok(not text.contains(bad2), "%s has no %s" % [f.get_file(), bad2])
	# a deliberately dirty text must be caught by the same scans
	ok("x Color(\"#fff\") y".contains(_forbidden()[3]), "selfcheck FAIL-as-expected: the scan finds a planted colour literal")
	ok(_has_symbol_chars("a \u2605 b"), "selfcheck FAIL-as-expected: the symbol scan finds a planted star")
	ok(not _has_symbol_chars("한글과 english, 12 - ok"), "the symbol scan passes ordinary text")
	ok(not _has_symbol_chars(FileAccess.get_file_as_string("res://tests/course_stage_wiring_test.gd")), "this test file has no symbol characters")


func _digit_scan() -> void:
	print("[C-15: no number of 5 digits or more in anything the screens showed]")
	ok(_all_texts.size() > 20, "the scan looked at %d texts" % _all_texts.size())
	eq(digit_runs(_all_texts), [], "no 5-digit run in any shown label or button")
