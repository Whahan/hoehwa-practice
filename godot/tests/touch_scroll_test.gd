extends Node
## Touch-scroll test (phone): a finger drag that starts ANYWHERE on a scrolling page must scroll it.
##   godot --headless --path godot res://tests/touch_scroll_test.tscn -- --phone
## Walks the scrolling screens (오늘, 레슨, 대화, 읽기, 복습, 로드맵, 연습, 기록, 연결) in fixed states, and in every
## visible ScrollContainer drags the finger 300 px up from many start points (blank, card, button, label,
## rich text, line edit, check box / check label, other) and measures how far the page moved.
##
## Input path: the same events a phone produces. Android sends InputEventScreenTouch / InputEventScreenDrag; with the
## default project setting input_devices/pointing/emulate_mouse_from_touch=true the engine turns them into mouse
## button / motion events, and Godot 4.6 ScrollContainer scrolls from those mouse events
## (scene/gui/scroll_container.cpp gui_input), but only when DisplayServer.is_touchscreen_available() is true.
## A desktop (and --headless) reports false, so the test sets Input.emulate_touch_from_mouse = true, which makes
## is_touchscreen_available() return true; this is the ONLY difference from the phone. The events themselves are
## injected as ScreenTouch / ScreenDrag through Input.parse_input_event, like Android does.
##
## Every gesture is also checked for side effects: no BaseButton emitted pressed / toggled and the scroller's
## controls were not rebuilt after a drag (a press-time tap handler would do that); taps must still work.
## Reads and writes only user://test_touch_* files. Last line: "== touch scroll: N passed, M failed ==".

const SCREEN := Vector2(412, 915)
const DRAG_PX := 300.0
const DRAG_STEP := 10.0
const MIN_DELTA := 200.0
const TEST_PROGRESS := "user://test_touch_progress.json"
const TEST_PREFS := "user://test_touch_prefs.json"
const TEST_LOG := "user://test_touch_studylog.json"
const TEST_READING := "user://test_touch_reading"

var passed: int = 0
var failed: int = 0
var main_node: Control
var rows: Array = [] ## [scenario, scroller, kind, hit, delta, final, side, verdict]
var notes: Array[String] = []
var _old_paths: Array = []
var _press_log: Array = []
var _inertia_ok: bool = true


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


# ---------------------------------------------------------------- setup

func _ready() -> void:
	print("== touch scroll test start ==")
	if not Platform.is_phone():
		await _pc_unchanged_test()
		print("== touch scroll (pc): %d passed, %d failed ==" % [passed, failed])
		get_tree().quit(1 if failed > 0 else 0)
		return
	if Vector2i(get_window().size) != Vector2i(SCREEN):
		get_window().min_size = Vector2i.ZERO
		get_window().size = Vector2i(SCREEN)
		await _frames(2)
	Input.emulate_touch_from_mouse = true # makes is_touchscreen_available() true (see header)
	Input.use_accumulated_input = false
	ok(DisplayServer.is_touchscreen_available(), "touchscreen available (emulated)")
	ok(Input.emulate_mouse_from_touch, "emulate_mouse_from_touch is on (project default, as on Android)")
	ok(Api.base_url == "", "phone mode: Api has no address, nothing can leave the machine")
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path, Store.curriculum_cache_path]
	Store.prefs_path = TEST_PREFS
	Store.progress_path = TEST_PROGRESS
	Store.curriculum_cache_path = "user://test_touch_curriculum.json"
	StudyLog.path = TEST_LOG
	_rm(TEST_PREFS)
	_rm(TEST_PROGRESS)
	_rm(TEST_LOG)
	Store.load_prefs()
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	for k in ["reading_font", "hide_prosody", "show_reading", "lesson_source"]:
		Store.prefs.erase(k)
	var D: int = Plan.days_from_civil(2026, 10, 16)
	Store.progress["xp"]["en"] = 120
	for off in [-2, -1, 0]:
		Store.progress["days"][Plan.days_to_iso(D + off)] = {"en": true}
	Store.add_review([
		{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": "Can I ~?"},
		{"lang": "en", "target": "I'd like a large coffee, please.", "ko": "큰 사이즈 커피 한 잔 주세요.", "note": ""},
		{"lang": "ja", "target": "毎朝七時に起きます。", "reading": "まいあさしちじにおきます。", "ko": "매일 아침 7시에 일어나요.", "note": "시간 + に"},
	])
	_write(TEST_LOG, FileAccess.get_file_as_string("res://tests/sample_studylog.json"))
	StudyLog.today_override = D
	StudyLog.load_from_disk()
	Backend._starting = true # never launch or poll the engine
	Backend.set_process(false)
	main_node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main_node)
	await _frames(20)
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "llm_model": "qwen3:8b", "score": true, "phoneme": true}
	Backend._set_status(Backend.Status.READY)
	main_node.call("add_tab", "practice", "연습", PracticeView.new(), "연습", "talk")
	main_node.call("add_tab", "stats", "기록", StatsView.new(), "기록", "review")
	await _frames(6)

	await _nested_test()
	await _gesture_fixture_test()
	for sc in _scenarios():
		await _run_scenario(sc)

	_print_table()
	ok(Api.sent_count == 0, "no request left through Api (sent_count=%d)" % Api.sent_count)
	main_node.queue_free() # free the views first: some flush the study log when they leave the tree
	await _frames(3)
	_cleanup()
	print("== touch scroll: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _cleanup() -> void:
	for p in [TEST_PREFS, TEST_PROGRESS, TEST_LOG, TEST_LOG + ".tmp", TEST_PROGRESS + ".tmp", TEST_PREFS + ".tmp", "user://test_touch_curriculum.json"]:
		_rm(p)
	for d in [TEST_READING.path_join("cache"), TEST_READING]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	Store.curriculum_cache_path = _old_paths[3]
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- scenarios

## Each scenario: {name, setup: Callable (async ok)}.
func _scenarios() -> Array:
	var views: Dictionary = main_node.views
	var fx := func(name: String) -> Variant:
		return JSON.parse_string(FileAccess.get_file_as_string("res://tests/" + name))
	var list: Array = []
	list.append({"name": "today", "setup": func() -> void:
		main_node.show_view("today")
		var v: TodayView = views["today"]
		v._settings_open = false
		v.refresh()})
	list.append({"name": "today_settings", "setup": func() -> void:
		main_node.show_view("today")
		var v: TodayView = views["today"]
		v._settings_open = true
		v.refresh()})
	list.append({"name": "lesson_home", "setup": func() -> void:
		main_node.show_view("lesson")})
	list.append({"name": "lesson_choice", "setup": func() -> void:
		main_node.show_view("lesson")
		var lv: LessonView = views["lesson"]
		lv.title = "카페에서 주문하기"
		lv.load_exercises(LessonView._parse_lesson(fx.call("sample_lesson.json")))
		lv._render()})
	list.append({"name": "lesson_speak_scored", "setup": func() -> void:
		main_node.show_view("lesson")
		var lv: LessonView = views["lesson"]
		lv.title = "카페에서 주문하기"
		lv.load_exercises(LessonView._parse_lesson(fx.call("sample_lesson.json")))
		for i in lv.exercises.size():
			if lv.exercises[i]["type"] == "speak":
				lv.idx = i
		lv._reset_answer()
		lv._render()
		lv.prosody = fx.call("sample_prosody_en_before.json")
		lv.prosody_native = lv.prosody
		lv._prosody_state = "ok"
		lv._apply_prosody()
		lv.speak_result = fx.call("sample_score_en_ph.json")
		lv.prosody = fx.call("sample_prosody_en_after.json")
		lv._render()
		lv._apply_prosody()})
	list.append({"name": "talk_setup", "setup": func() -> void:
		main_node.show_view("talk")
		var tv: TalkView = views["talk"]
		tv.status = "setup"
		tv.msgs = []
		tv._reset_selection()
		tv._update_visibility()
		tv._render_setup()})
	list.append({"name": "talk_chat", "setup": func() -> void:
		main_node.show_view("talk")
		var tv: TalkView = views["talk"]
		tv.lang = "en"
		tv.sc = TalkView.SCENES["en"][0]
		tv.msgs = []
		tv.stage = 1
		tv.status = "talk"
		tv._update_visibility()
		tv._update_header()
		for i in 4:
			tv._apply_reply({"reply": "Hi! Welcome to the shop. What can I get started for you today? We have a special on iced lattes this afternoon, if you are interested. (%d)" % i, "reading": "", "ko": "안녕하세요! 어서 오세요. 뭘로 시작해 드릴까요? 오늘 오후에는 아이스 라테 특별 할인이 있어요.", "fix": "", "fix_ko": "", "suggest": ["A latte, please.", "Can I see the menu, please? I'd like to look at the options first."]})
			tv.msgs.append({"role": "me", "text": "I want coffee and a muffin please", "fix": "I would like a coffee and a muffin, please.", "fix_ko": "I want 보다 I would like 가 더 정중해요."})
		tv._render_msgs()
		tv._update_composer()})
	list.append({"name": "talk_feedback", "setup": func() -> void:
		main_node.show_view("talk")
		var tv: TalkView = views["talk"]
		tv.lang = "en"
		tv.sc = TalkView.SCENES["en"][0]
		tv.status = "fb"
		tv.fb = fx.call("sample_feedback.json")
		tv._update_visibility()
		tv._render_fb()})
	list.append({"name": "reading_library", "setup": func() -> void:
		main_node.show_view("reading")
		var rv: ReadingView = views["reading"]
		rv.storage_dir = TEST_READING
		rv.auto_fetch = false
		rv.glosses.clear()
		for i in 3:
			var d: Dictionary = rv.new_doc("BBC — City foxes %d" % i, "en", "Urban foxes have adapted remarkably well to city life, scavenging from bins and sleeping under garden sheds.")
			d["id"] = "tt%d" % i
			d["opened"] = 1700000000 + i
			rv.save_doc(d)
		rv.mode = "library"
		rv.lang = "en"
		var s: Dictionary = ReadingView.SAMPLES["en"]
		rv._draft_title = str(s["title"])
		rv._draft_text = str(s["text"])
		rv._render()})
	list.append({"name": "reading_reader", "setup": func() -> void:
		main_node.show_view("reading")
		var rv: ReadingView = views["reading"]
		rv.storage_dir = TEST_READING
		rv.auto_fetch = false
		rv.glosses.clear()
		var rdata: Dictionary = fx.call("sample_reading_analyze.json")
		var rtext: String = ""
		for t in rdata["tokens"]:
			rtext += str(t["t"])
		var rd: Dictionary = rv.new_doc("Running in the Rain", "en", rtext)
		rd["id"] = "tt9"
		rv.save_doc(rd)
		rv.open_doc(rd)
		rv.set_analysis(rdata, false)
		rv.apply_glosses(fx.call("sample_reading_gloss.json"))
		for i in rv.tokens.size():
			if str((rv.tokens[i] as Dictionary)["t"]) == "reckless":
				rv.select_token(i)
		rv.set_examples("reckless", {"examples": [
			{"id": 1, "text": "It was reckless of him to drive so fast.", "ko": "그렇게 빨리 운전하다니 그는 무모했다.", "en": "", "ja": "", "url": ""},
			{"id": 2, "text": "Don't be reckless [with money].", "ko": "", "en": "", "ja": "お金に関して無謀なことをするな。", "url": ""},
		], "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"})})
	list.append({"name": "review_home", "setup": func() -> void:
		main_node.show_view("review")
		var rev: ReviewView = views["review"]
		rev.status = "idle"
		rev._render()})
	list.append({"name": "roadmap_open", "setup": func() -> void:
		main_node.show_view("roadmap")
		Store.prefs["open_months"] = {"en1": true, "en2": true}
		(views["roadmap"] as RoadmapView).refresh()})
	list.append({"name": "practice_hub", "setup": func() -> void:
		main_node.show_view("practice")
		(views["practice"] as PracticeView).refresh()})
	list.append({"name": "stats", "setup": func() -> void:
		main_node.show_view("stats")
		(views["stats"] as StatsView).refresh()})
	return list


func _run_scenario(sc: Dictionary) -> void:
	var name: String = sc["name"]
	print("[%s]" % name)
	(sc["setup"] as Callable).call()
	await _frames(12)
	_freeze_bars(main_node)
	await _frames(3)
	var scrollers: Array = _visible_scrollers()
	if scrollers.is_empty():
		ok(false, "%s: no visible ScrollContainer" % name)
		return
	var tap_plan: Array = []
	for sci in scrollers.size():
		var sc_node: ScrollContainer = scrollers[sci]
		var sname: String = "%s/%s%d" % [name, "page" if sc_node is PageScroll else "scroll", sci]
		var max_scroll: int = _max_scroll(sc_node)
		if max_scroll < 60:
			notes.append("%s: range %d px, too short to measure" % [sname, max_scroll])
			continue
		var offsets: Array = [0]
		var o: int = 700
		while o + DRAG_PX + 20 <= max_scroll and offsets.size() < 4:
			offsets.append(o)
			o += 700
		var seen_kinds: Dictionary = {}
		for off in offsets:
			sc_node.scroll_vertical = off
			await _frames(3)
			var picks: Array = _candidates(sc_node)
			for pk in picks:
				var key: String = "%s|%s" % [pk["kind"], pk["cls"]]
				var cnt: int = int(seen_kinds.get(pk["kind"], 0))
				if cnt >= 2 or seen_kinds.has(key):
					continue
				seen_kinds[pk["kind"]] = cnt + 1
				seen_kinds[key] = true
				await _measure_drag(sname, sc_node, off, pk)
				sc_node.scroll_vertical = off
				await _frames(2)
				if ["button", "check", "label", "card", "lineedit"].has(pk["kind"]):
					tap_plan.append({"sname": sname, "sci": sci, "off": off, "pk": pk})
	# taps last, one target per kind, each after a fresh setup (a tap may rebuild the page)
	var tapped: Dictionary = {}
	for tp in tap_plan:
		var kind: String = tp["pk"]["kind"]
		var tkey: String = "%s|%s" % [tp["sname"], kind]
		if tapped.has(tkey):
			continue
		tapped[tkey] = true
		(sc["setup"] as Callable).call()
		await _frames(12)
		_freeze_bars(main_node)
		var scs: Array = _visible_scrollers()
		if int(tp["sci"]) >= scs.size():
			ok(false, "%s: scroller list changed before the tap" % tp["sname"])
			continue
		var scn: ScrollContainer = scs[int(tp["sci"])]
		scn.scroll_vertical = int(tp["off"])
		await _frames(3)
		await _measure_tap(tp["sname"], scn, tp["pk"])


func _freeze_bars(node: Node) -> void:
	for c in node.get_children():
		if c is ProgressBar and (c as ProgressBar).indeterminate:
			(c as ProgressBar).indeterminate = false
			(c as ProgressBar).min_value = 0.0
			(c as ProgressBar).max_value = 100.0
			(c as ProgressBar).value = 35.0
		_freeze_bars(c)


# ---------------------------------------------------------------- geometry / hit test

func _all_scrollers(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Window:
			continue
		if c is CanvasItem and not (c as CanvasItem).is_visible_in_tree():
			continue
		if c is ScrollContainer:
			out.append(c)
		_all_scrollers(c, out)


func _visible_scrollers() -> Array:
	var all: Array = []
	_all_scrollers(main_node, all)
	var out: Array = []
	for s in all:
		var r: Rect2 = (s as Control).get_global_rect()
		if r.size.x > 20.0 and r.size.y > 60.0 and (s as ScrollContainer).vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
			out.append(s)
	return out


func _max_scroll(sc: ScrollContainer) -> int:
	var bar := sc.get_v_scroll_bar()
	return int(maxf(0.0, bar.max_value - bar.page))


## Pre-order list of {c, rect} of the visible controls under `n`, rects already clipped by clipping ancestors.
func _collect(n: Node, clip: Rect2, out: Array) -> void:
	for ch in n.get_children():
		if ch is Window:
			continue
		if ch is CanvasItem and not (ch as CanvasItem).visible:
			continue
		if ch is CanvasLayer and not (ch as CanvasLayer).visible:
			continue
		var child_clip: Rect2 = clip
		if ch is Control:
			var ctl := ch as Control
			var r: Rect2 = ctl.get_global_rect().intersection(clip)
			out.append({"c": ctl, "rect": r})
			if ctl.clip_contents:
				child_clip = r
		_collect(ch, child_clip, out)


## What Godot's Viewport.gui_find_control would pick at `p`: the last (topmost) control in draw order
## whose mouse_filter is not IGNORE and whose clipped rect holds `p`.
func _hit_at(list: Array, p: Vector2) -> Control:
	for i in range(list.size() - 1, -1, -1):
		var e: Dictionary = list[i]
		var c: Control = e["c"]
		if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		var r: Rect2 = e["rect"]
		if r.size.x > 0.0 and r.size.y > 0.0 and r.has_point(p):
			return c
	return null


func _kind(c: Control) -> String:
	if c is ScrollContainer:
		return "blank"
	if c is CheckBox or c is CheckButton:
		return "check"
	if c is BaseButton:
		return "button"
	if c is LineEdit:
		return "lineedit"
	if c is TextEdit:
		return "textedit"
	if c is RichTextLabel:
		return "richtext"
	if c is Label:
		return "label"
	if c is Slider:
		return "slider"
	if c is PanelContainer or c is Panel:
		return "card"
	if c is Container:
		return "blank"
	return "other"


func _is_under(c: Node, anc: Node) -> bool:
	var n: Node = c
	while n != null:
		if n == anc:
			return true
		n = n.get_parent()
	return false


## Start points inside the visible part of `sc`: one per visible control that is hit at its own centre.
func _candidates(sc: ScrollContainer) -> Array:
	var list: Array = []
	_collect(get_tree().root, Rect2(Vector2(-1e5, -1e5), Vector2(2e5, 2e5)), list)
	var vis: Rect2 = sc.get_global_rect().intersection(Rect2(Vector2.ZERO, SCREEN)).grow(-3.0)
	var out: Array = []
	var seen: Dictionary = {}
	for e in list:
		var c: Control = e["c"]
		if c.mouse_filter == Control.MOUSE_FILTER_IGNORE or not _is_under(c, sc) or c == sc:
			continue
		var r: Rect2 = (e["rect"] as Rect2).intersection(vis)
		if r.size.x < 8.0 or r.size.y < 8.0:
			continue
		if c.tooltip_text.begins_with("http"):
			continue # opens a browser on press: never touch
		var p: Vector2 = r.get_center()
		var h: Control = _hit_at(list, p)
		if h != c:
			continue
		var kind: String = _kind(c)
		var key: String = "%s|%s" % [kind, c.get_class()]
		if seen.has(key) and kind != "blank":
			continue
		seen[key] = true
		out.append({"kind": kind, "cls": c.get_class(), "pos": p, "ctl": c, "text": _text_of(c), "name": str(c.name)})
	# plain page: the side padding and the gaps between cards
	for y in range(int(vis.position.y) + 20, int(vis.end.y) - 10, 37):
		var p2 := Vector2(vis.position.x + 6.0, float(y))
		var h2: Control = _hit_at(list, p2)
		if h2 != null and (h2 == sc or (_kind(h2) == "blank" and _is_under(h2, sc))):
			out.append({"kind": "blank", "cls": h2.get_class(), "pos": p2, "ctl": h2, "text": "", "name": "padding"})
			break
	return out


func _text_of(c: Control) -> String:
	var t: String = ""
	if c is Button or c is Label:
		t = c.text
	elif c is RichTextLabel:
		t = (c as RichTextLabel).get_parsed_text()
	elif c is LineEdit:
		t = (c as LineEdit).placeholder_text
	return t.replace("\n", " ").left(18)


# ---------------------------------------------------------------- touch injection

func _touch(pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _drag_ev(pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = pos
	e.relative = rel
	e.velocity = rel * 60.0
	Input.parse_input_event(e)


# ---------------------------------------------------------------- side effect counters

func _watch_buttons(n: Node) -> void:
	for c in n.get_children():
		if c is Window:
			continue
		if c is BaseButton:
			var b := c as BaseButton
			# silence the app handlers (no side effects while we poke the page); keep engine-internal ones
			for sig in ["pressed", "toggled"]:
				for conn in b.get_signal_connection_list(sig):
					var cb: Callable = conn["callable"]
					if cb.get_object() != b and not (cb.get_object() is Window):
						b.disconnect(sig, cb)
			if not b.pressed.is_connected(_on_pressed.bind(b)):
				b.pressed.connect(_on_pressed.bind(b))
			if not (b is OptionButton) and not b.toggled.is_connected(_on_toggled.bind(b)):
				b.toggled.connect(_on_toggled.bind(b))
		_watch_buttons(c)


func _on_pressed(b: BaseButton) -> void:
	_press_log.append("pressed:" + str(b.name))


func _on_toggled(_on: bool, b: BaseButton) -> void:
	_press_log.append("toggled:" + str(b.name))


func _popup_open(n: Node) -> bool:
	for c in n.get_children():
		if c is OptionButton and (c as OptionButton).get_popup().visible:
			return true
		if _popup_open(c):
			return true
	return false


func _sig(root: Node) -> int:
	var h: int = 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		h = (h * 31 + n.get_instance_id()) % 1000000007
		for ch in n.get_children():
			stack.append(ch)
	return h


# ---------------------------------------------------------------- gestures

func _measure_drag(sname: String, sc: ScrollContainer, off: int, pk: Dictionary) -> void:
	_press_log.clear()
	_watch_buttons(main_node)
	var sig0: int = _sig(sc)
	var pos: Vector2 = pk["pos"]
	var start_v: int = sc.scroll_vertical
	var te_inner: TextEdit = null # a TextEdit with text left to scroll owns the drag (inner first)
	var te_from: float = 0.0
	if pk["kind"] == "textedit":
		var te := pk["ctl"] as TextEdit
		var vb := te.get_v_scroll_bar()
		if vb.visible and vb.max_value - vb.page > 0.5:
			te_inner = te
			te_from = te.get_v_scroll()
	_touch(pos, true)
	await get_tree().process_frame
	var steps: int = int(DRAG_PX / DRAG_STEP)
	for i in steps:
		pos.y -= DRAG_STEP
		_drag_ev(pos, Vector2(0, -DRAG_STEP))
		await get_tree().process_frame
	var v_end: int = sc.scroll_vertical
	_touch(pos, false)
	await get_tree().process_frame
	await _settle(sc)
	var final_v: int = sc.scroll_vertical
	var delta: int = v_end - start_v
	var rebuilt: bool = _sig(sc) != sig0
	var side: String = "-"
	if _popup_open(main_node):
		_press_log.append("popup")
	if not _press_log.is_empty():
		side = ",".join(_press_log)
	elif rebuilt:
		side = "rebuilt"
	var need: float = minf(MIN_DELTA, float(_max_scroll(sc) - start_v) - 4.0) # a short page can only move to its end
	var exempt: bool = pk["kind"] == "slider"
	var good: bool = float(delta) >= need and side == "-"
	if te_inner != null and side == "-" and absf(te_inner.get_v_scroll() - te_from) > 0.5:
		good = true # the TextEdit scrolled its own text under the finger
		notes.append("%s: drag on a TextEdit with its own scroll range moved its text (%.1f lines), not the page (inner first; the page only moves once the text is at its end)" % [sname, te_inner.get_v_scroll() - te_from])
	var verdict: String = "OK" if good else ("BLOCKED" if float(delta) < need else "SIDE")
	if exempt:
		verdict = "EXEMPT" if not good else "OK"
	rows.append([sname, off, pk["kind"], "%s %s" % [pk["cls"], pk["text"]], delta, final_v - start_v, side, verdict])
	if exempt and not good:
		print("  INFO  %s +%d drag from slider %s: keeps its own drag (moved %d)" % [sname, off, pk["cls"], delta])
	else:
		ok(good, "%s +%d drag from %s %s '%s': moved %d px (need %d), side=%s" % [sname, off, pk["kind"], pk["cls"], pk["text"], delta, int(need), side])


func _settle(sc: ScrollContainer) -> void:
	var last: int = sc.scroll_vertical
	var still: int = 0
	for i in 180:
		await get_tree().process_frame
		if sc.scroll_vertical == last:
			still += 1
			if still >= 6:
				return
		else:
			still = 0
			last = sc.scroll_vertical


func _tap(pos: Vector2) -> void:
	_touch(pos, true)
	await _frames(3)
	_touch(pos, false)
	await _frames(3)


func _measure_tap(sname: String, sc: ScrollContainer, pk: Dictionary) -> void:
	var list: Array = []
	_collect(get_tree().root, Rect2(Vector2(-1e5, -1e5), Vector2(2e5, 2e5)), list)
	var pos: Vector2 = pk["pos"]
	var h: Control = _hit_at(list, pos)
	var kind: String = pk["kind"]
	if h == null or h.get_class() != pk["cls"] or _kind(h) != kind:
		ok(false, "%s tap: layout not reproducible at %s (%s vs %s)" % [sname, str(pos), str(h), pk["cls"]])
		return
	_press_log.clear()
	_watch_buttons(main_node)
	var sig0: int = _sig(sc)
	var tappable: bool = false
	if kind == "button":
		await _tap(pos)
		var n_press: int = _press_log.count("pressed:" + str(h.name))
		ok(n_press == 1, "%s tap on button '%s' %s: pressed %d time(s)" % [sname, pk["text"], h.name, n_press])
	elif kind == "check":
		await _tap(pos)
		ok(_press_log.has("toggled:" + str(h.name)), "%s tap on check box: toggled (%s)" % [sname, str(_press_log)])
	elif kind == "lineedit":
		await _tap(pos)
		ok(get_viewport().gui_get_focus_owner() == h, "%s tap on line edit: focus acquired" % sname)
		(h as LineEdit).release_focus()
	elif kind == "label" or kind == "card":
		tappable = not h.get_signal_connection_list("gui_input").is_empty()
		if tappable:
			await _tap(pos)
			var changed: bool = _sig(sc) != sig0 or not _press_log.is_empty()
			ok(changed, "%s tap on %s with a tap handler (%s): handler ran (%s)" % [sname, kind, pk["text"], str(_press_log)])


# ---------------------------------------------------------------- PC: nothing changes

func _pc_unchanged_test() -> void:
	print("[pc: touch-scroll changes are phone only]")
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(1280, 800)
	await _frames(2)
	var old_paths: Array = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = TEST_PREFS
	Store.progress_path = TEST_PROGRESS
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	Store.load_prefs()
	Store.progress = Progress.blank()
	Backend._starting = true
	Backend.set_process(false)
	var m: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(m)
	await _frames(20)
	m._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "llm_model": "qwen3:8b", "score": true, "phoneme": true}
	Backend._set_status(Backend.Status.READY)
	m.show_view("today")
	await _frames(12)
	ok(load("res://scripts/ui/phone_layout.gd").get("_touch_scroll_hooked") != true, "pc: the touch-scroll hook is not installed")
	var all: Array = []
	_all_scrollers(m, all)
	var sc: ScrollContainer = null
	for a in all:
		if (a as Control).size.y > 100.0 and sc == null:
			sc = a
	ok(sc != null, "pc: a scroll page is visible")
	if sc == null:
		return
	ok(sc.scroll_deadzone == int(ProjectSettings.get_setting("gui/common/default_scroll_deadzone")), "pc: scroll_deadzone untouched (%d)" % sc.scroll_deadzone)
	var panels := 0
	var stop := 0
	var stack: Array = [sc]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PanelContainer:
			panels += 1
			if (n as PanelContainer).mouse_filter == Control.MOUSE_FILTER_STOP:
				stop += 1
		for ch in n.get_children():
			stack.append(ch)
	ok(panels > 0 and stop > 0, "pc: cards keep their STOP filter (%d of %d)" % [stop, panels])
	# the mouse wheel still scrolls (roadmap with open months is long)
	Store.prefs["open_months"] = {"en1": true, "en2": true}
	m.show_view("roadmap")
	(m.views["roadmap"] as RoadmapView).refresh()
	await _frames(12)
	var rall: Array = []
	_all_scrollers(m, rall)
	var rsc: ScrollContainer = rall[0]
	var before: int = rsc.scroll_vertical
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.factor = 1.0
	wheel.position = rsc.get_global_rect().get_center()
	wheel.global_position = wheel.position
	get_viewport().push_input(wheel)
	await _frames(4)
	ok(_max_scroll(rsc) > 200 and rsc.scroll_vertical > before, "pc: mouse wheel scrolls the page (%d -> %d of %d)" % [before, rsc.scroll_vertical, _max_scroll(rsc)])
	m.show_view("today")
	await _frames(6)
	# a click still presses a button
	var btn: Button = null
	var st2: Array = [sc]
	while not st2.is_empty() and btn == null:
		var n2: Node = st2.pop_back()
		if n2 is Button and not (n2 is OptionButton) and (n2 as Button).is_visible_in_tree():
			var r2: Rect2 = (n2 as Button).get_global_rect()
			if r2.size.x > 20.0 and sc.get_global_rect().encloses(r2):
				btn = n2
		for ch2 in n2.get_children():
			st2.append(ch2)
	if btn != null:
		for conn in btn.get_signal_connection_list("pressed"):
			if (conn["callable"] as Callable).get_object() != btn:
				btn.disconnect("pressed", conn["callable"])
		var count := [0]
		btn.pressed.connect(func() -> void: count[0] += 1)
		var c: Vector2 = btn.get_global_rect().get_center()
		await _tap(c)
		ok(count[0] == 1, "pc: a click presses '%s' once (got %d)" % [btn.text, count[0]])
	else:
		ok(false, "pc: found no button to click")
	# UI.on_tap keeps acting on the press on the PC
	var pc_card := PanelContainer.new()
	pc_card.custom_minimum_size = Vector2(200, 60)
	pc_card.position = Vector2(400, 400)
	var hits := [0]
	UI.on_tap(pc_card, func() -> void: hits[0] += 1)
	m.add_child(pc_card)
	await _frames(3)
	var pe := InputEventMouseButton.new()
	pe.button_index = MOUSE_BUTTON_LEFT
	pe.pressed = true
	pe.position = Vector2(10, 10)
	pe.global_position = Vector2(410, 410)
	pc_card.gui_input.emit(pe)
	ok(hits[0] == 1, "pc: UI.on_tap acts on the button press (%d)" % hits[0])
	m.queue_free()
	await _frames(3)
	for p in [TEST_PREFS, TEST_PROGRESS, TEST_LOG, TEST_PREFS + ".tmp", TEST_PROGRESS + ".tmp", TEST_LOG + ".tmp"]:
		_rm(p)
	StudyLog.load_from_disk() # blank, still on the test path
	Store.prefs_path = old_paths[0]
	Store.progress_path = old_paths[1]
	StudyLog.path = old_paths[2]
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)


# ---------------------------------------------------------------- nested scrolling

func _nested_test() -> void:
	print("[nested scroll]")
	var holder := Control.new()
	holder.size = SCREEN
	holder.position = Vector2.ZERO
	add_child(holder)
	var page := PageScroll.new(960.0)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(page)
	var inner_btn := Button.new()
	inner_btn.text = "inner button"
	inner_btn.custom_minimum_size = Vector2(0, 48)
	var top_btn := Button.new()
	top_btn.text = "top"
	top_btn.custom_minimum_size = Vector2(0, 48)
	page.content.add_child(top_btn)
	var card := CardBox.new()
	page.content.add_child(card)
	var inner := ScrollContainer.new()
	inner.custom_minimum_size = Vector2(0, 200)
	inner.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.body.add_child(inner)
	var iv := VBoxContainer.new()
	iv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(iv)
	for i in 8: # 8 x 48 + gaps = about 380 px: 180 px of inner range
		var b := Button.new()
		b.text = "row %d" % i
		b.custom_minimum_size = Vector2(0, 44)
		iv.add_child(b)
	for i in 24:
		var b := Button.new()
		b.text = "after %d" % i
		b.custom_minimum_size = Vector2(0, 60)
		page.content.add_child(b)
	await _frames(8)
	var imax: int = _max_scroll(inner)
	var pmax: int = _max_scroll(page)
	ok(imax > 100 and pmax > 500, "nested fixture: inner range %d, outer range %d" % [imax, pmax])
	var r: Rect2 = inner.get_global_rect()
	var pos: Vector2 = r.get_center()
	# drag 1: starts on an inner button; inner first, then the rest goes to the outer page (chaining)
	_touch(pos, true)
	await get_tree().process_frame
	var inner_after_first: int = -1
	for i in 30:
		pos.y -= DRAG_STEP
		_drag_ev(pos, Vector2(0, -DRAG_STEP))
		await get_tree().process_frame
		if i == 10:
			inner_after_first = inner.scroll_vertical
	var iv_end: int = inner.scroll_vertical
	var pv_end: int = page.scroll_vertical
	_touch(pos, false)
	await _settle(page)
	await _settle(inner)
	ok(inner_after_first > 0, "nested: the inner list moves first (%d px after 10 steps, outer %d)" % [inner_after_first, 0])
	ok(iv_end == imax, "nested: inner list reaches its end (%d / %d)" % [iv_end, imax])
	ok(pv_end > 40, "nested: the rest of the drag chains to the outer page (outer moved %d px)" % pv_end)
	# drag 2: the inner list is at its end: the outer page takes the whole gesture
	page.scroll_vertical = 0
	await _frames(3)
	var p0: int = page.scroll_vertical
	pos = inner.get_global_rect().get_center()
	_touch(pos, true)
	await get_tree().process_frame
	for i in 30:
		pos.y -= DRAG_STEP
		_drag_ev(pos, Vector2(0, -DRAG_STEP))
		await get_tree().process_frame
	var p1: int = page.scroll_vertical
	_touch(pos, false)
	await _settle(page)
	ok(inner.scroll_vertical == imax and float(p1 - p0) >= MIN_DELTA, "nested: inner at its end -> outer takes the whole drag (%d px)" % (p1 - p0))
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- gestures on a synthetic page

## Drags the finger from `from` by `total` in steps of about DRAG_STEP; returns the end position (still down).
func _swipe(from: Vector2, total: Vector2) -> Vector2:
	var pos: Vector2 = from
	_touch(pos, true)
	await get_tree().process_frame
	var n: int = maxi(1, int(maxf(absf(total.x), absf(total.y)) / DRAG_STEP))
	var step: Vector2 = total / float(n)
	for i in n:
		pos += step
		_drag_ev(pos, step)
		await get_tree().process_frame
	return pos


func _gesture_fixture_test() -> void:
	print("[gestures on a synthetic page]")
	var holder := Control.new()
	holder.size = SCREEN
	add_child(holder)
	var page := PageScroll.new(960.0)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(page)
	var c: VBoxContainer = page.content
	var counts: Dictionary = {}
	var mk := func(text: String) -> Button:
		var b := Button.new()
		b.text = text
		b.custom_minimum_size = Vector2(0, 56)
		b.pressed.connect(func() -> void: counts[text] = int(counts.get(text, 0)) + 1)
		return b
	for i in 3:
		c.add_child(mk.call("pad%d" % i))
	c.add_child(mk.call("B"))
	c.add_child(mk.call("A"))
	var le := LineEdit.new()
	le.text = "hello world hello world hello world"
	le.custom_minimum_size = Vector2(0, 48)
	c.add_child(le)
	var hs := ScrollContainer.new()
	hs.custom_minimum_size = Vector2(0, 80)
	hs.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hs.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	c.add_child(hs)
	var hrow := HBoxContainer.new()
	hs.add_child(hrow)
	for i in 12:
		var hb: Button = mk.call("h%d" % i)
		hb.custom_minimum_size = Vector2(120, 56)
		hrow.add_child(hb)
	var tap_card := PanelContainer.new() # a card that reacts to a tap through UI.on_tap (roadmap header, talk scenario ...)
	tap_card.custom_minimum_size = Vector2(0, 70)
	tap_card.add_child(UI.label("tap card", ""))
	UI.on_tap(tap_card, func() -> void: counts["card"] = int(counts.get("card", 0)) + 1)
	c.add_child(tap_card)
	for i in 30:
		c.add_child(mk.call("f%d" % i))
	await _frames(8)
	var a_btn: Button = null
	for n in c.get_children():
		if n is Button and (n as Button).text == "A":
			a_btn = n
	var a_pos: Vector2 = a_btn.get_global_rect().get_center()
	# a tap with a little wobble (below the dead zone) still presses
	counts.clear()
	var end: Vector2 = await _swipe(a_pos, Vector2(0, -6))
	_touch(end, false)
	await _frames(3)
	ok(int(counts.get("A", 0)) == 1 and counts.size() == 1, "tap with a 6 px wobble presses the button once (%s)" % str(counts))
	# a scrolling drag from A, lifted over B: neither is pressed
	page.scroll_vertical = 0
	await _frames(3)
	counts.clear()
	end = await _swipe(a_pos, Vector2(0, -DRAG_PX))
	var v_end: int = page.scroll_vertical
	_touch(end, false)
	await _frames(3)
	# the page followed the finger: what is under it at lift-off is the button it started on (and its neighbour B)
	ok(a_btn.get_global_rect().grow(20.0).has_point(end), "fixture: the finger lifts over button A again (%s in %s)" % [str(end), str(a_btn.get_global_rect())])
	ok(counts.is_empty(), "drag from A, lifted over A: no button pressed (%s)" % str(counts))
	ok(v_end >= 200, "that drag scrolled the page (%d px)" % v_end)
	await _settle(page)
	# a sideways drag on the horizontal scroller moves it, not the page
	page.scroll_vertical = 0
	await _frames(3)
	var hs_pos: Vector2 = hs.get_global_rect().get_center()
	counts.clear()
	end = await _swipe(hs_pos, Vector2(-200, 0))
	var h_moved: int = hs.scroll_horizontal
	var v_after: int = page.scroll_vertical
	_touch(end, false)
	await _settle(hs)
	ok(h_moved >= 100 and v_after <= 5 and counts.is_empty(), "sideways drag scrolls the row (%d px), page stays (%d), no press (%s)" % [h_moved, v_after, str(counts)])
	# a vertical drag on the same row scrolls the page
	hs.scroll_horizontal = 0
	page.scroll_vertical = 0
	await _frames(3)
	counts.clear()
	end = await _swipe(hs_pos, Vector2(0, -DRAG_PX))
	var v2: int = page.scroll_vertical
	_touch(end, false)
	await _settle(page)
	ok(v2 >= 200 and hs.scroll_horizontal == 0 and counts.is_empty(), "vertical drag on the sideways row scrolls the page (%d px), row stays, no press (%s)" % [v2, str(counts)])
	# a card with a UI.on_tap handler: a tap runs it once, a scrolling drag from it does not
	page.scroll_vertical = 0
	await _frames(3)
	var card_pos: Vector2 = tap_card.get_global_rect().get_center()
	counts.clear()
	await _tap(card_pos)
	ok(int(counts.get("card", 0)) == 1, "UI.on_tap card: a tap runs the handler once (%s)" % str(counts))
	counts.clear()
	end = await _swipe(card_pos, Vector2(0, -DRAG_PX))
	var v4: int = page.scroll_vertical
	_touch(end, false)
	await _settle(page)
	ok(v4 >= 200 and counts.is_empty(), "UI.on_tap card: a scrolling drag from it scrolls (%d px) and does not run the handler (%s)" % [v4, str(counts)])
	# LineEdit: a vertical drag scrolls and selects nothing; a tap focuses; a sideways drag still selects text
	page.scroll_vertical = 0
	await _frames(3)
	var le_pos: Vector2 = le.get_global_rect().get_center()
	end = await _swipe(le_pos, Vector2(0, -DRAG_PX))
	var v3: int = page.scroll_vertical
	_touch(end, false)
	await _frames(3)
	ok(v3 >= 200 and not le.has_selection() and le.text.begins_with("hello"), "LineEdit: vertical drag scrolls the page (%d px) and selects nothing" % v3)
	await _settle(page)
	page.scroll_vertical = 0
	await _frames(3)
	le_pos = le.get_global_rect().get_center()
	await _tap(le_pos)
	ok(get_viewport().gui_get_focus_owner() == le, "LineEdit: a tap focuses it")
	le.release_focus()
	end = await _swipe(Vector2(le.get_global_rect().position.x + 10.0, le_pos.y), Vector2(150, 0))
	_touch(end, false)
	await _frames(3)
	ok(le.has_selection() and page.scroll_vertical <= 3, "LineEdit: a sideways drag still selects text ('%s'), page stays" % le.get_selected_text())
	le.release_focus()
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- report

func _print_table() -> void:
	print("")
	print("---- drag table: scenario/scroller | start offset | kind | start control | moved px (finger up %d px) | after inertia | side effect | verdict" % int(DRAG_PX))
	for r in rows:
		print("%-34s +%-5d %-9s %-34s %5d %6d  %-12s %s" % [r[0], r[1], r[2], str(r[3]).left(34), r[4], r[5], str(r[6]).left(12), r[7]])
	print("---- per start kind: ok / total")
	var agg: Dictionary = {}
	for r in rows:
		var k: String = str(r[2])
		if not agg.has(k):
			agg[k] = [0, 0]
		agg[k][1] += 1
		if r[7] == "OK":
			agg[k][0] += 1
	for k in agg.keys():
		print("  %-10s %d / %d" % [k, agg[k][0], agg[k][1]])
	for n in notes:
		print("note: ", n)
