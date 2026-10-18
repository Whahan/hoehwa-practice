extends Node
## T5: the English v1.1 screens are wired into the real app (scenes/main.tscn as the running scene).
##   PC:    godot --headless --path <project> res://tests/t5_wiring_test.tscn -- --api=http://127.0.0.1:<port>
##   phone: godot --headless --path <project> res://tests/t5_wiring_test.tscn -- --phone --api=http://127.0.0.1:<port>
## Options: --old        start from a v1.0.1 install (progress file only, no studylog.json)
##          --real-paths use the app's real user:// files (ONLY with APPDATA pointed at an empty temp folder!)
##          --wav=<file> text file with a base64 WAV of "Can I have a menu?": also checks the score hooks of lesson and review
## Default: Store / StudyLog use user://t5_* files, never the app's files.
## Last line: "== t5 wiring result: N passed, 0 failed ==", exit code 1 on any failure.
## The engine is never started by this test (Backend is held back); --api only decides where the 연습 screens look.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _main: Control


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	_phone = Platform.is_phone()
	var args := OS.get_cmdline_user_args()
	var old: bool = args.has("--old")
	print("== t5 wiring start (%s%s) ==" % ["phone" if _phone else "pc", ", old install" if old else ""])
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)

	if not args.has("--real-paths"):
		Store.progress_path = "user://t5_progress.json"
		Store.prefs_path = "user://t5_prefs.json"
		StudyLog.path = "user://t5_studylog.json"
		for p in [Store.progress_path, Store.prefs_path, StudyLog.path]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	StudyLog.load_from_disk()
	Store.load_prefs()
	Store.progress = Progress.blank()
	if old:
		# like v1.0.1: progress.json with a few days and cards, no studylog.json
		Store.progress["xp"]["en"] = 120
		Store.progress["days"][Plan.days_to_iso(Plan.today_days())] = {"en": true}
		Store.progress["days"][Plan.days_to_iso(Plan.today_days() - 1)] = {"en": true}
		Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": ""}])
		Store.save_progress()
		Store.load_progress()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	# never launch or poll the real engine
	Backend._starting = true
	Backend.set_process(false)

	# run main.tscn as THE current scene (that is what the app does, and what turns the v1.1 tabs on)
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	_main = get_tree().current_scene
	ok(_main != null and _main.get_script() != null and _main.has_method("add_v11_tabs"), "main.tscn is the running scene")
	if _main == null:
		_finish()
		return
	_main.quit_on_exit = false
	await _frames(8)
	if old:
		ok(Store.xp("en") == 120 and (Store.progress["review"] as Array).size() == 1 and Store.streak("en") >= 2, "old install: progress.json was read (xp 120, 1 card, streak %d)" % Store.streak("en"))
		ok(StudyLog.last_load_status == "new" and StudyLog.streak("en") >= 2, "old install: no studylog.json yet, the streak from progress.json is kept (%d)" % StudyLog.streak("en"))

	_test_first_run(old)
	_test_tabs()
	await _test_navigation()
	await _test_layout()
	await _test_back()
	await _test_hooks(args)
	_finish()


func _finish() -> void:
	print("== t5 wiring result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _test_tabs() -> void:
	var keys: Array = _main.tab_keys()
	print("  tabs: ", keys)
	ok(keys == ["today", "lesson", "talk", "practice", "reading", "review", "stats", "roadmap"], "tab order: 연습 right after 대화, 기록 right after 복습")
	ok(_main.views["practice"] is PracticeView and _main.views["stats"] is StatsView, "views: PracticeView and StatsView")
	var labels := {}
	for t in _main._tabs:
		labels[str(t[0])] = str(t[1])
	ok(labels.get("practice", "") == "연습" and labels.get("stats", "") == "기록", "tab labels are 연습 and 기록")
	var clocks := 0
	for c in _main.get_children():
		if c is StudyClock:
			clocks += 1
	ok(clocks == 1, "exactly one StudyClock under main (%d)" % clocks)
	if _phone:
		var bt: BottomTabs = _main._bottom_tabs
		ok(bt.direct_keys().size() == 5 and bt.overflow_keys().size() == 3, "phone: 5 cells + 더보기 with 3 tabs (%s | %s)" % [bt.direct_keys(), bt.overflow_keys()])
		ok(bt.cell_buttons().size() == 6, "phone: bar has 6 cells (5 tabs + 더보기)")
	else:
		ok(_main.tab_buttons.size() == 8, "PC: 8 top buttons")


func _test_navigation() -> void:
	# every tab can be shown; no script error may appear in the output (the runner counts "SCRIPT ERROR")
	for k in _main.tab_keys():
		if not _phone and (_main.tab_buttons[k] as Button).visible:
			(_main.tab_buttons[k] as Button).pressed.emit() # a real click on the top button
		else:
			_main.show_view(k)
		await _frames(3)
		ok(_main.current == k and (_main.views[k] as Control).visible, "tab '%s' opens and is visible" % k)
	var visible_views := 0
	for k in _main.views.keys():
		if (_main.views[k] as Control).visible:
			visible_views += 1
	ok(visible_views == 1, "only one view is visible at a time (%d)" % visible_views)
	_main.show_view("practice")
	await _frames(4)
	var pv: PracticeView = _main.views["practice"]
	ok(pv.card_kinds().size() >= 3, "연습 hub shows its cards (%s)" % [pv.card_kinds()])
	_main.show_view("stats")
	await _frames(4)
	_main.show_view("today")
	await _frames(3)
	var gc := (_main.views["today"] as Control).find_children("*", "GoalCard", true, false)
	ok(gc.size() == 1, "오늘: one compact GoalCard (%d)" % gc.size())


func _test_layout() -> void:
	if _phone:
		var bt: BottomTabs = _main._bottom_tabs
		var right := 0.0
		var min_w := 1000.0
		for c in bt.cell_buttons():
			var r: Rect2 = (c as Control).get_global_rect()
			right = maxf(right, r.end.x)
			min_w = minf(min_w, r.size.x)
		ok(right <= 412.5 and min_w >= 48.0, "phone: bottom cells inside 412 px and >= 48 px (right %.0f, min %.0f)" % [right, min_w])
		return
	for w in [1280, 900, 640]:
		get_window().min_size = Vector2i.ZERO # main.gd keeps the real window at >= 900; 640 only exercises the overflow menu
		get_window().size = Vector2i(w, 800 if w == 1280 else 600)
		await _frames(6)
		var vis: Array = []
		var right := 0.0
		for k in _main.tab_keys():
			var b: Button = _main.tab_buttons[k]
			if b.visible:
				vis.append(k)
				right = maxf(right, b.get_global_rect().end.x)
		var more_vis: bool = _main._top_more.visible
		if more_vis:
			right = maxf(right, _main._top_more.get_global_rect().end.x)
		var hidden: Array = _main._top_hidden
		print("  width %d: visible %d, hidden %s, 더보기 %s, right edge %.0f, status right %.0f" % [w, vis.size(), hidden, str(more_vis), right, _main._status_text.get_global_rect().end.x])
		ok(vis.size() + hidden.size() == 8 and (hidden.is_empty() or more_vis), "width %d: every tab is a button or in 더보기" % w)
		ok(right <= float(w) + 0.5 and _main._status_text.get_global_rect().end.x <= float(w) + 0.5, "width %d: nothing is cut off at the right edge" % w)
		if w == 1280:
			ok(vis.size() == 8 and not more_vis, "width 1280: all 8 tabs visible, no 더보기")
		elif w == 640:
			ok(more_vis and not hidden.is_empty() and vis.size() < 8, "width 640: the last tabs move into 더보기 (%d hidden)" % hidden.size())
			for i in hidden.size():
				_main._open_top_more()
				_main._top_more_menu.id_pressed.emit(i)
				await _frames(2)
				ok(_main.current == str(hidden[i]), "width 640: 더보기 entry %d opens '%s'" % [i, hidden[i]])
			_main.show_view("today")
		else:
			# the hidden ones are reachable through the menu entries
			for k in hidden:
				_main.show_view(str(k))
				await _frames(2)
				ok(_main.current == str(k), "width 900: hidden tab '%s' opens through 더보기" % k)
			_main.show_view("today")
	get_window().size = Vector2i(1280, 800)
	await _frames(4)


func _test_back() -> void:
	_main.show_view("practice")
	await _frames(3)
	var pv: PracticeView = _main.views["practice"]
	pv.open_screen("shadow")
	await _frames(3)
	ok(pv.current_screen() != null, "back: a practice sub screen is open")
	_main.handle_back()
	await _frames(3)
	ok(pv.current_screen() == null and _main.current == "practice", "back #1 closes the sub screen and stays on 연습")
	_main.handle_back()
	await _frames(2)
	ok(_main.current == "today", "back #2 goes to 오늘")
	# 기록 has no sub screens: back goes to 오늘 at once
	_main.show_view("stats")
	await _frames(2)
	_main.handle_back()
	ok(_main.current == "today", "back from 기록 goes to 오늘")


func _wav_b64(args: PackedStringArray) -> String:
	var p := ""
	for a in args:
		if a.begins_with("--wav="):
			p = a.substr(6)
	if p == "" or not FileAccess.file_exists(p):
		return ""
	return FileAccess.get_file_as_string(p).strip_edges()


func _test_hooks(args: PackedStringArray) -> void:
	StudyLog.reset()
	# C6: finishing a lesson counts once (add_lesson only, no extra add_event("lessons"))
	var lv: LessonView = _main.views["lesson"]
	lv.lang = "en"
	lv.status = "run"
	lv.results = [{"ok": true, "ex": {"type": "choice"}}, {"ok": true, "ex": {"type": "choice"}}, {"ok": false, "ex": {"type": "choice"}}]
	lv.finish_lesson()
	var today: Dictionary = (StudyLog.range_summary("en", 1) as Array)[0]
	ok(int(today["lessons_ok"]) == 2 and int(today["lessons_n"]) == 3, "C6: lesson result 2/3 recorded (%s/%s)" % [today["lessons_ok"], today["lessons_n"]])
	ok(int((today["n"] as Dictionary)["lessons"]) == 1, "C6: the lesson is counted once (%s)" % (today["n"] as Dictionary)["lessons"])

	# C8: a correction from the chat reply becomes one review card; the same sentence twice stays one card
	var before: int = (Store.progress["review"] as Array).size()
	FixCards.reset_counter()
	var tv: TalkView = _main.views["talk"]
	tv.lang = "en"
	tv.conv_id = "t5-conv"
	tv.msgs = [{"role": "me", "text": "I goed to school yesterday"}]
	tv._apply_reply({"reply": "Nice!", "fix": "I went to school yesterday.", "fix_ko": "went 가 맞아요", "suggest": []})
	var after: int = (Store.progress["review"] as Array).size()
	ok(after == before + 1, "C8: the correction became a review card (%d -> %d)" % [before, after])
	tv.msgs = [{"role": "me", "text": "I goed to school yesterday"}]
	tv._apply_reply({"reply": "Nice!", "fix": "I went to school yesterday.", "fix_ko": "went 가 맞아요", "suggest": []})
	ok((Store.progress["review"] as Array).size() == after, "C8: the same correction is not added twice")

	# C5 / C7: the score hooks, with a real recording when a base64 WAV is given
	var b64: String = _wav_b64(args)
	if b64 == "":
		print("  (skip) --wav not given: score hooks C5/C7 not exercised")
	else:
		lv.lang = "en"
		lv.status = "run"
		lv.exercises = [{"type": "speak", "text": "Can I have a menu?", "reading": "", "ko": "메뉴판 좀 주실래요?"}]
		lv.idx = 0
		lv.results = []
		lv.scoring = false
		var n0: int = int((StudyLog.range_summary("en", 1)[0] as Dictionary)["score_n"])
		lv._on_recorded({"b64": b64})
		for i in 600:
			await get_tree().process_frame
			if not lv.scoring:
				break
		var n1: int = int((StudyLog.range_summary("en", 1)[0] as Dictionary)["score_n"])
		ok(not lv.scoring and not lv.speak_result.is_empty(), "C5: /score answered for the lesson recording")
		ok(n1 == n0 + 1, "C5: the lesson score was added to the study log (%d -> %d)" % [n0, n1])
		var rv: ReviewView = _main.views["review"]
		Store.add_review([{"lang": "en", "target": "Can I have a menu?", "reading": "", "ko": "메뉴판", "note": ""}])
		rv.lang = "en"
		rv.items = Store.review_for("en")
		rv.idx = 0
		rv.scoring = false
		rv.checked = false
		var n2: int = int((StudyLog.range_summary("en", 1)[0] as Dictionary)["score_n"])
		rv._on_recorded({"b64": b64})
		for i in 600:
			await get_tree().process_frame
			if not rv.scoring:
				break
		var n3: int = int((StudyLog.range_summary("en", 1)[0] as Dictionary)["score_n"])
		ok(not rv.scoring and not rv.score_result.is_empty(), "C7: /score answered for the review recording")
		ok(n3 == n2 + 1, "C7: the review score was added to the study log (%d -> %d)" % [n2, n3])

	# C9: resetting the progress also clears the study log
	StudyLog.add_seconds("en", "lesson", 120)
	ok(StudyLog.has_data("en"), "C9: study log has data before the reset")
	Store.reset_progress()
	ok(not StudyLog.has_data("en") and StudyLog.today_seconds("en") == 0, "C9: Store.reset_progress() clears the study log")

	# C11: the streak shown on 오늘 comes from StudyLog (a day mark in progress.json counts)
	Store.progress["days"][Plan.days_to_iso(Plan.today_days())] = {"en": true}
	ok(StudyLog.streak("en") >= 1, "C11: StudyLog.streak sees today's mark (%d)" % StudyLog.streak("en"))

	# C12 / ui.gd guard
	ok(Progress.MAX_REVIEW == 3000, "C12: MAX_REVIEW is 3000")
	var sc := ScrollContainer.new()
	add_child(sc)
	UI.scroll_to_bottom(sc)
	sc.queue_free() # freed in the same frame: must not raise "previously freed instance"
	await _frames(4)
	ok(true, "ui.gd: scroll_to_bottom on a node freed meanwhile (the runner checks the output for SCRIPT ERROR)")


func _test_first_run(old: bool) -> void:
	ok(StudyLog.last_load_status == "new", "first run: no studylog.json yet -> blank log, no error (%s)" % StudyLog.last_load_status)
	ok(not StudyLog.is_read_only(), "first run: StudyLog is writable")
	var s := StudyLog.settle("en")
	ok(int(s["tokens"]) == 1, "first run: the streak protection starts with 1 token (%s)" % s["tokens"])
