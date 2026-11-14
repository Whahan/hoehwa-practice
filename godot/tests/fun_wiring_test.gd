extends Node
## W (docs/v160_fun_design.md §6.5 W-1 ... W-11): the v1.6.0 screens are wired into the real app. scenes/main.tscn runs as THE current
## scene (that turns add_v16_tabs() on), like t5_wiring_test. No server, no AI: the engine is never started.
##   PC:    godot --headless --path <project> --resolution 1280x800 res://tests/fun_wiring_test.tscn -- --api=http://127.0.0.1:9
##   phone: godot --headless --path <project> --resolution 412x915 res://tests/fun_wiring_test.tscn -- --phone --api=http://127.0.0.1:9
## Checks: the 배지 tab (right after 기록, in the 기록 group of the phone menu / the PC side nav, never in the bottom bar), the home
## "이번 주" card (place, buttons, jumps), the practice hub (6 cards), the badge watcher through main (a 첫 평가 right after the start
## without any activity, then an activity -> one toast), and wrong inputs (unknown pending kind, empty provider, broken counts).
## Users files are user://test_fun_w_* only. Last line: "== fun_wiring: N passed, M failed ==", exit code 1 on any failure.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _main: Control
var _toasts: Array = [] ## [[text, kind], ...]
var _activity: int = 0
var _fake_ms: int = 0
var _snap: Dictionary = {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## A check that must say "no": the same helper with a wrong input has to be judged false (the check itself can fail).
func selfcheck(judged: bool, name: String) -> void:
	if judged:
		failed += 1
		print("  FAIL  selfcheck: the wrong input passed: ", name)
	else:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)


func _has_arg(prefix: String) -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return true
	return false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _on_toast(text: String, kind: String) -> void:
	_toasts.append([text, kind])


func _on_activity(_kind: String) -> void:
	_activity += 1


## Number of toasts with exactly this text.
func _count_toast(text: String) -> int:
	var n := 0
	for t in _toasts:
		if str((t as Array)[0]) == text:
			n += 1
	return n


## `b` comes right after `a` in the list.
func _right_after(keys: Array, a: String, b: String) -> bool:
	return keys.has(a) and keys.find(b) == keys.find(a) + 1


func _ready() -> void:
	_phone = Platform.is_phone()
	if not _phone and not _has_arg("--api="):
		# the PC practice hub pings its server: without a closed-port address the test could reach the user's engine
		print("refusing to run: pass --api=http://127.0.0.1:9 after the --")
		get_tree().quit(1)
		return
	print("== fun_wiring start (%s) ==" % ("phone" if _phone else "pc"))
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)

	Store.progress_path = "user://test_fun_w_progress.json"
	Store.prefs_path = "user://test_fun_w_prefs.json"
	StudyLog.path = "user://test_fun_w_studylog.json"
	for p in [Store.progress_path, Store.prefs_path, StudyLog.path]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	StudyLog.load_from_disk()
	Store.load_prefs()
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	Backend._starting = true # never launch or poll the real engine
	Backend.set_process(false)
	PracticeView.pending = {}
	# What the badge engine "sees": 12 lessons + 1 talk = first_lesson, lessons_10, first_talk (3 badges, all from the past).
	_snap = {"lessons_total": 12, "talks_total": 1}
	BadgeEngine.provider = func() -> Dictionary: return _snap.duplicate()
	Toast.message.connect(_on_toast)
	Store.activity.connect(_on_activity)
	ok(not StudyLog.has_badge_record(), "start: there is no badge record yet (an upgraded user)")

	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	_main = get_tree().current_scene
	ok(_main != null and _main.has_method("add_v16_tabs"), "main.tscn is the running scene and has add_v16_tabs()")
	if _main == null:
		_finish()
		return
	_main.quit_on_exit = false
	await _frames(4)

	await _test_startup_evaluation()
	await _test_tabs()
	await _test_home_card()
	await _test_jumps()
	await _test_hub()
	await _test_activity_toast()
	await _test_wrong_inputs()
	_selfchecks()
	_finish()


func _finish() -> void:
	Toast.message.disconnect(_on_toast)
	Store.activity.disconnect(_on_activity)
	BadgeEngine.provider = Callable()
	print("== fun_wiring: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _watcher() -> BadgeWatcher:
	for c in _main.get_children():
		if c is BadgeWatcher:
			return c
	return null


# ---------------------------------------------------------------- the first evaluation right after the start

func _test_startup_evaluation() -> void:
	var w: BadgeWatcher = _watcher()
	ok(w != null, "start: a BadgeWatcher hangs under main")
	var n := 0
	for c in _main.get_children():
		if c is BadgeWatcher:
			n += 1
	ok(n == 1, "start: exactly one BadgeWatcher (%d)" % n)
	# nobody did anything (no lesson, no quiz): the toast must come from the start-up request alone
	for i in 12: # at most ~2.4 s (debounce 0.3 s)
		if _count_toast("이미 달성한 배지 3개를 모았어요") > 0:
			break
		await _wait(0.2)
	ok(_activity == 0, "start: no activity signal was emitted by anything (%d)" % _activity)
	ok(_count_toast("이미 달성한 배지 3개를 모았어요") == 1, "start: the retro toast \"이미 달성한 배지 3개를 모았어요\" shows once without any activity (%s)" % str(_toasts))
	ok(w != null and w.eval_count == 1, "start: exactly one evaluation ran (%d)" % (w.eval_count if w != null else -1))
	ok(StudyLog.has_badge_record(), "start: the badge record exists now")
	var got: Dictionary = StudyLog.badges_got()
	var retro_all := got.size() == 3
	for id in got.keys():
		retro_all = retro_all and bool((got[id] as Dictionary).get("retro", false))
	ok(retro_all and got.has("first_lesson") and got.has("lessons_10") and got.has("first_talk"), "start: the 3 past badges are saved as retro (%s)" % str(got.keys()))
	# the home was already drawn when the evaluation ran: its badge button must follow without leaving the screen
	await _frames(3)
	var fun: Control = (_main.views["today"] as TodayView).card("fun") if _main.current == "today" else null
	var btn_text := ""
	if fun != null:
		btn_text = ((fun.get_meta("buttons") as Dictionary)["badges"] as Button).text
	ok(_main.current == "today" and btn_text == "배지 3/25", "start: the home card shows the badges just granted (배지 3/25) without leaving the home (%s)" % btn_text)
	var kinds_ok := true
	for t in _toasts:
		if str((t as Array)[0]) == "이미 달성한 배지 3개를 모았어요" and str((t as Array)[1]) != "info":
			kinds_ok = false
	ok(kinds_ok, "start: the retro toast is an info toast")


# ---------------------------------------------------------------- W-1, W-2: tabs, menu, side nav

func _test_tabs() -> void:
	var keys: Array = _main.tab_keys()
	ok(_right_after(keys, "stats", "badges"), "W-1: tab_keys has badges right after stats (%s)" % str(keys))
	ok(_main.views["badges"] is BadgeView, "W-1: the badges view is a BadgeView")
	var label := ""
	for t in _main._tabs:
		if str(t[0]) == "badges":
			label = str(t[1])
	ok(label == "배지", "W-1: the tab label is 배지 (%s)" % label)
	ok(not (_main.bar_keys() as Array).has("badges"), "W-1: bar_keys() has no badges (%s)" % str(_main.bar_keys()))
	ok(BadgeView.provider.is_valid() and BadgeView.on_seen.is_valid(), "W-1: BadgeView.provider and on_seen are plugged in")
	ok(str(_main.MENU_SUB.get("badges", "")) == "받은 배지와 진행", "W-1: MENU_SUB has the badges line")
	if _phone:
		var bt: BottomTabs = _main._bottom_tabs
		var bar_want: Array = ["today", "lesson", "review", "song", "menu"]
		ok(_main.bar_keys() == bar_want and bt.direct_keys() == bar_want, "W-2: the bar tabs are still 홈, 레슨, 복습, 노래, 메뉴 (%s)" % str(bt.direct_keys()))
		ok(bt.cell_buttons().size() == 5 and bt.overflow_keys().is_empty(), "W-2: 5 cells, no 더보기 cell (%d, %s)" % [bt.cell_buttons().size(), str(bt.overflow_keys())])
		_main.show_view("menu")
		await _frames(3)
		var mv: MenuView = _main.views["menu"]
		var ek: Array = mv.entry_keys()
		ok(_right_after(ek, "roadmap", "badges") and _right_after(ek, "badges", "settings"), "W-1: the phone menu lists 배지 at the end of the 기록 group, before 설정 (%s)" % str(ek))
		ok(mv.row_control("badges") != null, "W-1: the 배지 row exists")
		var picked: Array = []
		var cb := func(k: String) -> void: picked.append(k)
		mv.entry_chosen.connect(cb)
		mv.choose("badges")
		mv.entry_chosen.disconnect(cb)
		await _frames(3)
		ok(picked == ["badges"] and _main.current == "badges", "W-1: choosing the 배지 row opens the badges screen (%s)" % _main.current)
		ok(bt._current == "menu", "W-1: the 메뉴 tab stays lit on the badges screen (%s)" % bt._current)
		_main.handle_back()
		await _frames(2)
		ok(_main.current == "menu", "W-1: back from 배지 (opened from the menu) returns to 메뉴 (%s)" % _main.current)
		_main.show_view("today")
		await _frames(2)
	else:
		ok(_main._bottom_tabs == null, "W-2: PC has no bottom bar")
		var nav: SideNav = _main._side_nav
		var btns: Dictionary = nav.item_buttons()
		ok(btns.has("badges") and (btns["badges"] as Button).text == "배지", "W-1: the side nav has a 배지 item")
		var y := func(k: String) -> float: return (btns[k] as Control).get_global_rect().position.y
		ok(y.call("roadmap") < y.call("badges") and y.call("badges") < y.call("settings"), "W-1: 배지 sits after 로드맵 and before 설정")
		var heads: Array = []
		for l in nav._list.find_children("*", "Label", true, false):
			heads.append((l as Label).text)
		ok(heads == ["공부", "말하기·읽기", "기록"], "W-1: the group headers did not change, so 배지 is inside 기록 (%s)" % str(heads))
		(btns["badges"] as Button).pressed.emit() # a real click on the item
		await _frames(3)
		ok(_main.current == "badges" and (_main.views["badges"] as Control).visible, "W-1: the 배지 item opens the badges screen")
		_main.show_view("today")
		await _frames(2)


# ---------------------------------------------------------------- W-3: the home card

func _test_home_card() -> void:
	_main.show_view("today")
	Store.set_lang("en")
	var tv: TodayView = _main.views["today"]
	tv.refresh()
	await _frames(4)
	var fun: Control = tv.card("fun")
	ok(fun != null and fun.get_meta("card_id", "") == "fun", "W-3: the home has the card \"fun\"")
	if fun == null:
		return
	var streak: Control = tv.card("streak")
	ok(streak != null and streak.get_parent() == fun.get_parent(), "W-3: the fun card shares the column of the streak card")
	if _phone:
		ok(fun.get_index() == streak.get_index() + 1, "W-3: phone: the fun card comes right after the streak card (%d, %d)" % [streak.get_index(), fun.get_index()])
		var sc: Control = tv.card("shortcuts")
		ok(sc != null and sc.get_index() > fun.get_index(), "W-3: phone: the shortcut tiles come after the fun card")
		var r: Rect2 = fun.get_global_rect()
		ok(r.position.x >= -0.5 and r.end.x <= 412.5, "W-3: phone: the fun card is inside the 412 px width (%.0f..%.0f)" % [r.position.x, r.end.x])
	else:
		ok(tv.is_wide() and fun.get_index() == streak.get_index() + 1, "W-3: PC: the fun card is right under the streak card in the right column")
		ok(absf(fun.get_global_rect().position.x - streak.get_global_rect().position.x) < 1.0, "W-3: PC: same left edge as the streak card")
	ok(tv.hero_button() != null and tv.hero_button().get_global_rect().position.y <= 480.0, "W-3: the start button is still at y <= 480 (%.0f)" % (tv.hero_button().get_global_rect().position.y if tv.hero_button() != null else -1.0))
	var rc: Control = tv.card("resume")
	if rc != null:
		ok(rc.get_global_rect().position.y < 859.0, "W-3: the resume card is still above y 859")
	var be: Dictionary = fun.get_meta("buttons")
	ok(be["speed"] != null and be["kana"] == null and be["badges"] != null, "W-3: english: speed and badges buttons, no 가나 코스")
	ok((be["badges"] as Button).text == "배지 3/25", "W-3: the badge button shows the real count 배지 3/25 (%s)" % (be["badges"] as Button).text)
	Store.set_lang("ja")
	tv.refresh()
	await _frames(4)
	fun = tv.card("fun")
	ok(fun != null and (fun.get_meta("buttons") as Dictionary)["kana"] != null, "W-3: japanese: the 가나 코스 button is there")
	Store.set_lang("en")
	tv.refresh()
	await _frames(3)


# ---------------------------------------------------------------- W-4: the jumps from the home card

func _fun_button(kind: String) -> Button:
	var tv: TodayView = _main.views["today"]
	var fun: Control = tv.card("fun")
	if fun == null:
		return null
	return (fun.get_meta("buttons") as Dictionary).get(kind, null)


func _test_jumps() -> void:
	var pv: PracticeView = _main.views["practice"]
	# [60초 퀴즈]
	_main.show_view("today")
	Store.set_lang("en")
	(_main.views["today"] as TodayView).refresh()
	await _frames(3)
	var b: Button = _fun_button("speed")
	ok(b != null, "W-4: the 60초 퀴즈 button exists")
	b.pressed.emit()
	await _frames(5)
	ok(_main.current == "practice" and pv.current_screen() is SpeedScreen, "W-4: [60초 퀴즈] opens the speed screen (%s, %s)" % [_main.current, str(pv.current_screen())])
	ok(PracticeView.pending.is_empty(), "W-4: the pending request was used up")
	_main.handle_back() # the speed screen's start page has no inner step: it closes to the hub
	await _frames(3)
	ok(pv.current_screen() == null and _main.current == "practice", "W-4: back #1 closes the speed screen and stays on 연습")
	_main.handle_back()
	await _frames(3)
	ok(_main.current == "today", "W-4: back #2 goes home (%s)" % _main.current)
	# [가나 코스] (japanese)
	Store.set_lang("ja")
	(_main.views["today"] as TodayView).refresh()
	await _frames(3)
	b = _fun_button("kana")
	ok(b != null, "W-4: the 가나 코스 button exists in japanese")
	b.pressed.emit()
	await _frames(5)
	var ks: Control = pv.current_screen()
	ok(_main.current == "practice" and ks is KanaScreen and (ks as KanaScreen).stage == "course", "W-4: [가나 코스] opens the kana course page (%s, %s)" % [_main.current, str((ks as KanaScreen).stage) if ks is KanaScreen else "-"])
	_main.show_view("today")
	await _frames(2)
	pv.go_back()
	await _frames(2)
	# [배지]
	Store.set_lang("en")
	(_main.views["today"] as TodayView).refresh()
	await _frames(3)
	b = _fun_button("badges")
	b.pressed.emit()
	await _frames(4)
	ok(_main.current == "badges", "W-4: [배지] opens the badges screen (%s)" % _main.current)
	var bv: BadgeView = _main.views["badges"]
	ok(bv.visible_ids().size() == 25, "W-4: the badges screen lists the 25 badges (%d)" % bv.visible_ids().size())
	_main.handle_back()
	await _frames(3)
	ok(_main.current == ("today" if not _phone else "today"), "W-4: back from 배지 (opened from the home) goes home (%s)" % _main.current)
	# the card body -> 기록
	_main.show_view("today")
	await _frames(3)
	var fun: Control = (_main.views["today"] as TodayView).card("fun")
	_tap(fun.get_meta("tap_area"))
	await _frames(4)
	ok(_main.current == "stats", "W-4: the card body opens 기록 (%s)" % _main.current)
	_main.handle_back()
	await _frames(3)
	ok(_main.current == "today", "W-4: back from 기록 goes home (%s)" % _main.current)


## UI.on_tap: the PC reacts on press, the phone on release (same spot); both are sent.
func _tap(c: Control) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = Vector2(5, 5)
		e.global_position = Vector2(5, 5)
		c.gui_input.emit(e)


# ---------------------------------------------------------------- W-5: the practice hub

func _test_hub() -> void:
	var pv: PracticeView = _main.views["practice"]
	Store.set_lang("en")
	_main.show_view("practice")
	pv.refresh()
	await _frames(4)
	var want: Array = ["mission", "shadow", "dictation", "phoneme", "kana", "speed"]
	ok(pv.card_kinds() == want, "W-5: the hub has 6 cards in order (%s)" % str(pv.card_kinds()))
	ok(not (pv._cards["speed"] as Button).disabled and (pv._cards["kana"] as Button).disabled, "W-5: english: speed on, kana off")
	ok(_label_has(pv, "60초 스피드 퀴즈") and _label_has(pv, "가나 기초 코스"), "W-5: the cards read \"60초 스피드 퀴즈\" and \"가나 기초 코스\"")
	ok((pv._cards["speed"] as Button).text == "퀴즈 시작" and (pv._cards["kana"] as Button).text == "코스 시작", "W-5: the buttons read 퀴즈 시작 / 코스 시작")
	Store.set_lang("ja")
	pv.refresh()
	await _frames(4)
	ok(not (pv._cards["speed"] as Button).disabled and not (pv._cards["kana"] as Button).disabled, "W-5: japanese: speed and kana are on")
	(pv._cards["speed"] as Button).pressed.emit()
	await _frames(4)
	ok(pv.current_screen() is SpeedScreen, "W-5: the speed card opens SpeedScreen in japanese")
	pv.go_back()
	await _frames(3)
	(pv._cards["kana"] as Button).pressed.emit()
	await _frames(4)
	var ks: Control = pv.current_screen()
	ok(ks is KanaScreen and (ks as KanaScreen).stage == "course", "W-5: the hub kana card opens the course page, not the table (%s)" % [str((ks as KanaScreen).stage) if ks is KanaScreen else "-"])
	pv.go_back() # opened directly as the course: one back returns to the hub
	await _frames(3)
	ok(pv.current_screen() == null, "W-5: one back from the directly opened course page returns to the hub")
	Store.set_lang("en")
	_main.show_view("today")
	await _frames(2)


func _label_has(root: Node, text: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return true
	return false


# ---------------------------------------------------------------- W-6: the badge watcher through main

func _test_activity_toast() -> void:
	var w: BadgeWatcher = _watcher()
	w.clock = func() -> int: return _fake_ms
	_fake_ms = 100000
	await _frames(2)
	var before: int = _toasts.size()
	var ev_before: int = w.eval_count
	_snap = {"lessons_total": 12, "talks_total": 1, "speed_plays": 1} # a speed quiz was played
	Store.note_activity("speed")
	await _wait(0.5)
	var fresh: Array = []
	for i in range(before, _toasts.size()):
		fresh.append(_toasts[i])
	var name: String = str(BadgeDefs.by_id("speed_first").get("name", ""))
	ok(w.eval_count == ev_before + 1, "W-6: note_activity(\"speed\") -> one evaluation within 0.5 s (%d -> %d)" % [ev_before, w.eval_count])
	ok(fresh.size() == 1 and str(fresh[0][0]) == "배지를 받았어요: %s" % name and str(fresh[0][1]) == "ok", "W-6: exactly one toast with the new badge name (%s)" % str(fresh))
	ok((StudyLog.badges_got().get("speed_first", {}) as Dictionary).get("retro", true) == false, "W-6: the new badge is saved as not retro")
	# nothing new: another activity gives no second toast
	_fake_ms += 10000
	var n2: int = _toasts.size()
	Store.note_activity("speed")
	await _wait(0.5)
	ok(_toasts.size() == n2, "W-6: the same state again gives no toast (%d)" % (_toasts.size() - n2))


# ---------------------------------------------------------------- W-10: wrong inputs

func _test_wrong_inputs() -> void:
	var pv: PracticeView = _main.views["practice"]
	# an unknown pending kind goes to the hub
	_main.show_view("today")
	await _frames(2)
	PracticeView.pending = {"kind": "zz"}
	Store.navigate.emit("practice", "en")
	await _frames(4)
	ok(_main.current == "practice" and pv.current_screen() == null and PracticeView.pending.is_empty(), "W-10: an unknown pending kind shows the hub (%s)" % _main.current)
	# navigate_args to badges with nothing
	Store.navigate_args.emit("badges", {})
	await _frames(4)
	ok(_main.current == "badges", "W-10: navigate_args(\"badges\", {}) opens the screen (%s)" % _main.current)
	# an empty provider: an empty screen, no error
	var saved_provider: Callable = BadgeView.provider
	BadgeView.provider = Callable()
	_main.show_view("today")
	await _frames(2)
	_main.show_view("badges")
	await _frames(4)
	var bv: BadgeView = _main.views["badges"]
	ok(_main.current == "badges" and bv.visible_ids().is_empty(), "W-10: an empty provider gives an empty badge screen (%d ids)" % bv.visible_ids().size())
	BadgeView.provider = saved_provider
	_main.show_view("today")
	await _frames(2)
	# a broken badge count: the card still draws
	var bad_counts: Array = [{"got": "x", "total": NAN, "unseen": -5}, {"got": -3, "total": 1e30, "unseen": null}, null, "text", {}]
	var drawn := 0
	for c in bad_counts:
		var card: Control = FunParts.home_card("ja", {}, c, Callable())
		if card != null and (card.get_meta("buttons") as Dictionary).get("speed", null) != null:
			drawn += 1
		if card != null:
			card.free()
	ok(drawn == bad_counts.size(), "W-10: the home card draws with %d broken badge counts (%d)" % [bad_counts.size(), drawn])
	var bad_reports: Array = [null, "x", {}, {"minutes": "a", "lessons": NAN, "empty": 5}]
	drawn = 0
	for r in bad_reports:
		var card2: Control = FunParts.home_card("en", r, {"got": 1, "total": 23, "unseen": 0}, Callable())
		if card2 != null:
			drawn += 1
			card2.free()
	ok(drawn == bad_reports.size(), "W-10: the home card draws with %d broken reports (%d)" % [bad_reports.size(), drawn])
	# the real home again after all of it
	var tv: TodayView = _main.views["today"]
	tv.refresh()
	await _frames(3)
	ok(tv.card("fun") != null, "W-10: the home still has its fun card")


# ---------------------------------------------------------------- the checks must be able to say no (C-12)

func _selfchecks() -> void:
	selfcheck(_right_after(["stats", "roadmap", "badges"], "stats", "badges"), "badges two places after stats is not \"right after\"")
	selfcheck(_right_after(["badges", "stats"], "stats", "badges"), "badges before stats is not \"right after\"")
	selfcheck(_right_after([], "stats", "badges"), "an empty tab list is not \"right after\"")
	selfcheck(_count_toast("이 문장은 나온 적이 없어요") > 0, "a toast text that never came is not found")
	selfcheck(_count_toast("") > 0, "an empty toast text is not found")
