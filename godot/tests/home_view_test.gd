extends Node
## 홈 화면(TodayView) 시험 (docs/home_menu_design.md §11.8 T4-1..T4-13, T4-18, T4-19, 시험 부분 C-11).
##   PC:    godot --headless --path <project> res://tests/home_view_test.tscn
##   폰:    godot --headless --path <project> --resolution 412x915 res://tests/home_view_test.tscn -- --phone [--font-scale=1.5] [--dark]
## 파일: user://test_home_view/ 아래(prefs, progress, studylog)와 SongStore.root = user://test_home_view/songs 뿐. 실제 파일은 열지 않는다.
## 마지막 줄: "== home_view: N passed, M failed ==", 실패가 있으면 종료 코드 1.

const DIR := "user://test_home_view"
const FRI := 20763 ## 2026-11-06 (금요일). 이 주 월요일은 FRI - 4. 시작에서 아래 assert 로 확인한다.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _events: Array = [] ## 마지막 navigate / navigate_args: ["navigate", view, lang] 또는 ["navigate_args", view, args]
var _ai_requests: int = 0
var _saved: Dictionary = {}


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


func _size_window(want: Vector2i) -> void:
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== home_view test start (%s, scale %s%s) ==" % ["phone" if _phone else "pc", str(_scale), ", dark" if _dark else ""])
	_save_state()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	SongStore.root = DIR.path_join("songs")
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: this test never reaches a real engine
	Sheet.animate = false
	Store.navigate.connect(func(v: String, l: String) -> void: _events.append(["navigate", v, l]))
	Store.navigate_args.connect(func(v: String, a: Dictionary) -> void: _events.append(["navigate_args", v, a]))
	Store.ai_connect_requested.connect(func() -> void: _ai_requests += 1)
	await _size_window(Vector2i(412, 915) if _phone else Vector2i(1280, 800))
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	ok(Plan.weekday(FRI) == 5 and Plan.days_to_iso(FRI) == "2026-11-06", "fixture: FRI is a Friday (2026-11-06)")

	_selfchecks()
	await _test_structure()
	await _test_goal_ring()
	await _test_cards_order()
	await _test_layout()
	await _test_touch_sizes()
	await _test_streak()
	await _test_day_change()
	await _test_start_button()
	await _test_ai()
	await _test_songs()
	await _test_direct_mark()
	await _test_garbage()
	_test_file_rules()

	_restore_state()
	_cleanup()
	print("== home_view: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- state

func _save_state() -> void:
	_saved = {"prefs_path": Store.prefs_path, "progress_path": Store.progress_path, "log_path": StudyLog.path,
		"song_root": SongStore.root, "status": Backend.status, "health": Backend.health.duplicate(true),
		"starting": Backend._starting, "route": Route.mode, "override": StudyLog.today_override,
		"unix": StudyLog.unix_override, "provider": HomeAi.provider, "force": HomeAi.force_phone,
		"cache": SongDue.cache.duplicate(true), "hour": HomeParts.hour_override, "base_url": Api.base_url}


func _restore_state() -> void:
	Store.prefs_path = _saved["prefs_path"]
	Store.progress_path = _saved["progress_path"]
	StudyLog.path = _saved["log_path"]
	SongStore.root = _saved["song_root"]
	Backend.status = _saved["status"]
	Backend.health = _saved["health"]
	Backend._starting = _saved["starting"]
	Backend.set_process(true)
	Route.mode = _saved["route"]
	StudyLog.today_override = _saved["override"]
	StudyLog.unix_override = _saved["unix"]
	HomeAi.provider = _saved["provider"]
	HomeAi.force_phone = _saved["force"]
	SongDue.cache = _saved["cache"]
	HomeParts.hour_override = _saved["hour"]
	Api.base_url = _saved["base_url"]


func _cleanup() -> void:
	var g: String = ProjectSettings.globalize_path(DIR)
	_rm_tree(g)


func _rm_tree(g: String) -> void:
	if not DirAccess.dir_exists_absolute(g):
		return
	for d in DirAccess.get_directories_at(g):
		_rm_tree(g.path_join(d))
	for f in DirAccess.get_files_at(g):
		DirAccess.remove_absolute(g.path_join(f))
	DirAccess.remove_absolute(g)


## A clean slate: empty progress / log / prefs, a start date ten days ago, no resume, no AI card, no songs.
func _reset(lang: String = "en") -> void:
	Store.progress = Progress.blank()
	Store.progress["start"] = Plan.days_to_iso(Plan.today_days() - 10)
	Store.prefs["lang"] = lang
	Store.prefs["daily_goal_min"] = 10
	Store.prefs.erase("home_ai_dismiss_day")
	StudyLog.today_override = Plan.today_days()
	StudyLog.unix_override = -1
	StudyLog.reset()
	HomeParts.hour_override = 10
	HomeAi.provider = func() -> Dictionary: return {"show": false}
	HomeAi.force_phone = 0
	_set_songs(0)
	_events.clear()


func _set_songs(due: int) -> void:
	SongDue.cache = {"songs": 1 if due > 0 else 0, "lyrics": 1 if due > 0 else 0, "due": due, "fresh": 0, "at": int(Time.get_unix_time_from_system())}


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


# ---------------------------------------------------------------- helpers (each has a self-check below)

func _buttons(root: Node) -> Array:
	var out: Array = []
	for n in root.find_children("*", "BaseButton", true, false):
		if (n as Control).is_visible_in_tree():
			out.append(n)
	return out


func _button_with(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null


func _button_starting(root: Node, prefix: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text.begins_with(prefix):
			return n
	return null


func _label_with(root: Node, text: String) -> Label:
	for n in root.find_children("*", "Label", true, false):
		if (n as Label).text == text:
			return n
	return null


func _rects_overlap(a: Rect2, b: Rect2) -> bool:
	var i: Rect2 = a.intersection(b)
	return i.size.x > 0.5 and i.size.y > 0.5


## Pairs of the visible cards whose rectangles intersect.
func _card_overlaps(tv: TodayView) -> Array:
	var ids: Array = []
	for id in ["tasks", "resume", "streak", "ai", "shortcuts"]:
		if tv.card(id) != null:
			ids.append(id)
	var bad: Array = []
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			if _rects_overlap(tv.card(ids[i]).get_global_rect(), tv.card(ids[j]).get_global_rect()):
				bad.append("%s/%s" % [ids[i], ids[j]])
	return bad


func _overflow(root: Node, vp: Vector2) -> Array:
	var bad: Array = []
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r := c.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		if r.end.x > vp.x + 0.5 or r.position.x < -0.5:
			bad.append("%s %s %s" % [c.get_class(), c.name, str(r)])
	return bad


func _filled_count(root: Node, accent: Color) -> int:
	var n := 0
	for b in root.find_children("*", "Button", true, false):
		if b is CheckBox or b is CheckButton:
			continue
		var sb: StyleBox = (b as Button).get_theme_stylebox("normal")
		if sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.is_equal_approx(accent):
			n += 1
	return n


func _y(c: Control) -> float:
	return c.get_global_rect().position.y


func _bottom(c: Control) -> float:
	return c.get_global_rect().end.y


func _texts(root: Node) -> Array:
	var out: Array = []
	for n in root.find_children("*", "Label", true, false):
		out.append((n as Label).text)
	return out


func _selfchecks() -> void:
	print("[self-checks: the detectors can fail]")
	var a := Rect2(0, 0, 100, 100)
	var flagged: bool = _rects_overlap(a, Rect2(50, 50, 100, 100))
	var clean: bool = not _rects_overlap(a, Rect2(0, 100, 100, 50))
	print("selfcheck %s overlap detector on two overlapping rects" % ("FAIL-as-expected" if flagged else "UNEXPECTED-PASS"))
	ok(flagged and clean, "self-check: overlap detector flags overlapping rects and passes touching ones")
	var fake := VBoxContainer.new()
	fake.add_child(UI.button("a", "primary", Pal.PRIMARY))
	fake.add_child(UI.button("b", "primary", Pal.PRIMARY))
	fake.add_child(UI.button("c", "soft", Pal.PRIMARY))
	add_child(fake)
	var fc: int = _filled_count(fake, Pal.PRIMARY)
	print("selfcheck %s filled-button counter on a fake card with two filled buttons (%d)" % ["FAIL-as-expected" if fc != 1 else "UNEXPECTED-PASS", fc])
	ok(fc == 2, "self-check: two filled buttons are counted as 2")
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(3000, 20)
	fake.add_child(wide)
	var ov: Array = _overflow(fake, Vector2(412, 915))
	print("selfcheck %s overflow detector on a 3000 px control (%d)" % ["FAIL-as-expected" if not ov.is_empty() else "UNEXPECTED-PASS", ov.size()])
	ok(not ov.is_empty(), "self-check: the overflow detector reports a 3000 px wide control")
	var rv := UI.button("복습 끝!", "soft", Pal.PRIMARY)
	fake.add_child(rv)
	ok(_button_starting(fake, "복습 ") != null, "self-check: a button starting with '복습 ' is found (the rule of review_walk_test can fail)")
	fake.queue_free()


# ---------------------------------------------------------------- T4-1 structure

func _test_structure() -> void:
	print("[T4-1 structure]")
	_reset()
	var tv := await _make()
	ok(tv.card("tasks") != null, "card('tasks') exists")
	ok(tv.card("tasks").get_meta("card_id", "") == "tasks", "the card carries meta card_id")
	var hero: Dictionary = HomeModel.hero(HomeModel.snapshot("en"))
	ok(tv.hero_button() != null and tv.hero_button().text == str(hero["text"]) and str(hero["text"]) != "", "hero_button().text == HomeModel.hero().text ('%s')" % str(hero["text"]))
	ok(tv.find_children("*", "GoalRing", true, false).size() == 1, "exactly one GoalRing node")
	ok(tv._voice_row("en") is Control, "_voice_row('en') returns a control")
	ok(tv.lang_switch() != null, "lang_switch() exists")
	ok(tv.page_title() == "" and tv.scroll_host() == tv._scroll, "page_title() is empty, scroll_host() is the page scroll")
	ok((tv.header_block() == null) == _phone, "header_block(): null on the phone, a PageHeader on the PC")
	ok(tv.is_wide() == (not _phone), "is_wide() == %s" % str(not _phone))
	ok(tv._body is HBoxContainer if not _phone else tv._body is VBoxContainer, "body is HBox (PC) / VBox (phone)")
	# the first todo row is the lesson; the optional talk row is last
	var rows: Array = tv.task_buttons()
	ok(rows.size() == 2 and (rows[0] as Button).text == "오늘의 레슨" and (rows[1] as Button).text == "원어민과 말해 보기", "task rows on a fresh start: lesson, talk (%d)" % rows.size())
	ok(_filled_count(tv, Pal.PRIMARY) == 1, "exactly one PRIMARY-filled button on the whole home")
	ok(tv.find_children("*", "SettingsView", true, false).is_empty() and not tv.go_back(), "no settings on the home, go_back() is false")
	# sync panel / settings opener are not part of the home
	ok(tv.find_children("*", "SyncPanel", true, false).is_empty(), "no SyncPanel on the home")
	await _drop(tv)


# ---------------------------------------------------------------- goal ring

func _test_goal_ring() -> void:
	print("[goal ring]")
	_reset()
	var tv := await _make()
	var r: GoalRing = tv.ring()
	ok(r != null and r.show_ring and not r.done and is_equal_approx(r.fraction, 0.0), "no study yet: ring empty")
	await _drop(tv)
	StudyLog.add_seconds("en", "lesson", 300)
	tv = await _make()
	r = tv.ring()
	ok(is_equal_approx(r.fraction, 0.5) and r.center_text == "5/10분" and not r.done, "5 of 10 minutes: half ring, text '5/10분'")
	var rs: float = r.size.x
	ok(rs >= Ds.RING_D_PHONE - 0.5 if _phone else rs >= Ds.RING_D_PC - 0.5, "ring diameter %.0f px" % rs)
	var lab: Label = r.get_child(0)
	var fsz: int = lab.get_theme_font_size("font_size")
	ok(fsz <= int(floorf(r.diameter * 0.34)) and UI.text_width(lab.text, fsz, true) <= r.diameter - Ds.RING_STROKE * 2.0, "ring text fits inside the ring (font %d)" % fsz)
	await _drop(tv)
	StudyLog.add_seconds("en", "lesson", 400)
	tv = await _make()
	r = tv.ring()
	ok(r.done and is_equal_approx(r.fraction, 1.0) and not (r.get_child(0) as Label).visible and (r.get_child(1) as Control).visible, "goal reached: full ring, check mark instead of the text")
	ok(_label_with(tv, "오늘 목표 달성! 잘했어요.") != null or _label_with(tv, "오늘 목표 달성! 연속 1일째예요.") != null or tv.find_children("*", "Label", true, false).any(func(l: Node) -> bool: return (l as Label).text.begins_with("오늘 목표 달성")), "greeting says the goal is reached")
	ok(r.accessibility_name != "", "ring has an accessibility name")
	await _drop(tv)
	Store.prefs["daily_goal_min"] = 0
	tv = await _make()
	r = tv.ring()
	ok(r != null and not r.show_ring and r.center_text == "오늘 11분", "goal off: no ring, text only ('%s')" % (r.center_text if r != null else "-"))
	await _drop(tv)
	Store.prefs["daily_goal_min"] = 10


# ---------------------------------------------------------------- T4-2 card order and conditions

func _test_cards_order() -> void:
	print("[T4-2 card order and conditions]")
	_reset()
	var tv := await _make()
	ok(tv.card("resume") == null, "no recent study: card('resume') == null")
	ok(tv.card("ai") == null, "AI slot hidden: card('ai') == null")
	ok(tv.card("streak") != null and tv.card("tasks") != null, "tasks and streak always there")
	ok((tv.card("shortcuts") != null) == _phone, "shortcuts only on the phone")
	await _drop(tv)

	# resume card: a recent practice session while today's hero is the lesson
	StudyLog.note_resume("practice", "en")
	tv = await _make()
	ok(tv.card("resume") != null, "recent practice: card('resume') exists")
	if tv.card("resume") != null:
		ok(_label_with(tv.card("resume"), "연습 이어하기") != null and _button_with(tv.card("resume"), "시작") != null, "resume card text from HomeModel: '연습 이어하기' + [시작]")
		ok(_y(tv.card("resume")) > _y(tv.card("tasks")), "resume card after the tasks card")
	await _drop(tv)
	# same screen as the start button: no card
	StudyLog.note_resume("lesson", "en")
	tv = await _make()
	ok(tv.card("resume") == null and tv.hero_button().text == "레슨 이어하기", "resume on the lesson = the hero says '레슨 이어하기', no card")
	await _drop(tv)
	StudyLog.reset()

	# AI card below the streak card
	HomeAi.provider = func() -> Dictionary: return {"show": true, "state": "off", "title": "AI 연결 안 됨", "body": "대화와 AI 레슨은 연결 뒤에 쓸 수 있어요", "action": "AI 연결하기", "prominent": false, "dismissible": true}
	tv = await _make()
	ok(tv.card("ai") != null and tv.card("streak") != null and _y(tv.card("ai")) > _y(tv.card("streak")), "FAILED-like slot: card('ai') after card('streak')")
	ok(tv.card("ai") != null and tv.card("ai").has_meta("later_button"), "non-prominent slot offers [나중에]")
	await _drop(tv)
	# prominent: above the tasks card, no [나중에]
	HomeAi.provider = func() -> Dictionary: return {"show": true, "state": "not_installed", "title": "AI 설치가 필요해요", "body": "", "action": "AI 연결하기", "prominent": true, "dismissible": true}
	tv = await _make()
	ok(tv.card("ai") != null and _y(tv.card("ai")) < _y(tv.card("tasks")), "prominent slot: card('ai') before card('tasks')")
	ok(tv.card("ai") != null and not tv.card("ai").has_meta("later_button"), "prominent slot has no [나중에]")
	HomeAi.dismiss_today()
	await _refresh(tv)
	ok(tv.card("ai") != null, "a prominent slot ignores 'dismissed today'")
	await _drop(tv)
	# dismissed today (non-prominent): gone
	HomeAi.provider = func() -> Dictionary: return {"show": true, "state": "off", "title": "AI 연결 안 됨", "body": "", "action": "AI 연결하기", "prominent": false, "dismissible": true}
	tv = await _make()
	ok(tv.card("ai") == null, "HomeAi.dismiss_today() done: card('ai') == null")
	await _drop(tv)
	_reset()


# ---------------------------------------------------------------- T4-3 / T4-4 / T4-5 layout

func _test_layout() -> void:
	print("[T4-3..5 layout]")
	_reset()
	StudyLog.note_resume("practice", "en")
	var tv := await _make()
	var vp := Vector2(get_window().size)
	var hero_end: float = _bottom(tv.hero_button())
	var bad: Array = _overflow(tv, vp)
	ok(bad.is_empty(), "%dx%d: nothing sticks out of the window (%d)" % [int(vp.x), int(vp.y), bad.size()])
	for b in bad.slice(0, 5):
		print("    overflow ", b)
	ok(_card_overlaps(tv).is_empty(), "no two cards overlap %s" % str(_card_overlaps(tv)))
	if _phone:
		if is_equal_approx(_scale, 1.0):
			ok(hero_end <= 480.0, "T4-3: phone hero button ends at y=%.0f (<= 480)" % hero_end)
			ok(tv.card("resume") != null and _y(tv.card("resume")) < 859.0, "T4-3: resume card starts above the bottom tab bar (y=%.0f < 859)" % _y(tv.card("resume")))
		if _scale >= 1.45:
			ok(hero_end <= 700.0, "T4-4: phone 150%%: hero button ends at y=%.0f (<= 700)" % hero_end)
		ok(not tv.is_wide(), "phone: never wide")
	else:
		ok(tv.is_wide(), "T4-5: 1280x800 is wide")
		var t: Control = tv.card("tasks")
		var s: Control = tv.card("streak")
		ok(absf(t.get_global_rect().position.x - s.get_global_rect().position.x) > 100.0, "T4-5: tasks and streak sit in different columns (x %.0f vs %.0f)" % [t.get_global_rect().position.x, s.get_global_rect().position.x])
		if is_equal_approx(_scale, 1.0):
			ok(hero_end <= 420.0, "T4-5: PC hero button ends at y=%.0f (<= 420)" % hero_end)
		ok(is_equal_approx(s.get_global_rect().size.x, Ds.HOME_RIGHT_W) or s.get_global_rect().size.x >= Ds.HOME_RIGHT_W - 0.5, "right column is %.0f px wide (>= %d)" % [s.get_global_rect().size.x, int(Ds.HOME_RIGHT_W)])
		await _size_window(Vector2i(900, 800))
		await _frames(8)
		ok(not tv.is_wide(), "T4-5: window 900 wide -> is_wide() == false")
		ok(_card_overlaps(tv).is_empty(), "T4-5: at 900 no card overlaps %s" % str(_card_overlaps(tv)))
		ok(_overflow(tv, Vector2(900, 800)).is_empty(), "T4-5: at 900 nothing sticks out")
		ok(absf(tv.card("tasks").get_global_rect().position.x - tv.card("streak").get_global_rect().position.x) < 2.0, "T4-5: at 900 one column (same x)")
		await _size_window(Vector2i(1280, 800))
		await _frames(8)
		ok(tv.is_wide(), "T4-5: back at 1280 -> is_wide() == true")
		ok(_card_overlaps(tv).is_empty(), "T4-5: back at 1280 no card overlaps")
	await _drop(tv)


# ---------------------------------------------------------------- T4-6 touch sizes

func _test_touch_sizes() -> void:
	print("[T4-6 touch sizes]")
	_reset()
	StudyLog.note_resume("practice", "en")
	HomeAi.provider = func() -> Dictionary: return {"show": true, "state": "off", "title": "AI 연결 안 됨", "body": "대화와 AI 레슨은 연결 뒤에 쓸 수 있어요", "action": "AI 연결하기", "prominent": false, "dismissible": true}
	var tv := await _make()
	if _phone:
		var small: Array = []
		for b in _buttons(tv):
			if (b as Control).size.y < 47.5:
				small.append("%s '%s' h=%.1f" % [b.get_class(), (b as Button).text if b is Button else "", (b as Control).size.y])
		ok(small.is_empty(), "every button on the home is >= 47.5 px high (%d too small)" % small.size())
		for s in small.slice(0, 5):
			print("    small ", s)
		ok(tv.hero_button().size.y >= Ds.CTA_H - 0.5 and tv.hero_button().size.y >= Ds.HOME_CTA_H_PHONE - 0.5, "start button height %.0f (>= 56, design 60)" % tv.hero_button().size.y)
		var rows_ok := true
		for b in tv.task_buttons():
			if (b as Control).size.y < 55.5:
				rows_ok = false
		ok(rows_ok and not tv.task_buttons().is_empty(), "task rows are >= 56 px high")
		var tiles_ok := true
		var tiles: Array = tv.card("shortcuts").get_meta("buttons")
		for b in tiles:
			if (b as Control).size.y < 63.5:
				tiles_ok = false
		ok(tiles_ok and tiles.size() == 3, "3 shortcut tiles, each >= 64 px high")
		# the detector can fail
		var fake := Button.new()
		fake.custom_minimum_size = Vector2(100, 20)
		add_child(fake)
		await _frames(2)
		ok(fake.size.y < 47.5, "self-check: a 20 px high button would be reported as too small")
		fake.queue_free()
	else:
		ok(tv.hero_button().size.y >= Ds.HOME_CTA_H_PC - 0.5, "PC start button height %.0f (>= 52)" % tv.hero_button().size.y)
		var rows_ok := true
		for b in tv.task_buttons():
			if (b as Control).size.y < 55.5:
				rows_ok = false
		ok(rows_ok, "task rows are >= 56 px high")
		ok(tv.card("shortcuts") == null, "no shortcut tiles on the PC (the left menu does it)")
	await _drop(tv)


# ---------------------------------------------------------------- T4-9 streak card

func _test_streak() -> void:
	print("[T4-9 streak card]")
	_reset()
	StudyLog.today_override = FRI
	for d in [FRI - 3, FRI - 2, FRI - 1]:
		Store.progress["days"][Plan.days_to_iso(d)] = {"en": true}
	StudyLog._freeze("en")["tokens"] = 1
	var tv := await _make()
	var sc: Control = tv.card("streak")
	ok(_label_with(sc, "연속 3일") != null, "pill text '연속 3일'")
	ok(sc.find_children("*", "Label", true, false).any(func(l: Node) -> bool: return (l as Label).text == "보호권 1"), "chip '보호권 1'")
	var row: Control = sc.find_child("Stones", true, false)
	var want: Array = ["missed", "done", "done", "done", "today", "future", "future"]
	ok(row != null and row.get_meta("states") == want, "7 stones: past 3 filled, today ringed, next days dots %s" % (str(row.get_meta("states")) if row != null else "-"))
	var stones: Array = row.find_children("Stone*", "Control", true, false) if row != null else []
	var got: Array = []
	for s in stones:
		got.append(s.state)
	ok(stones.size() == 7 and got == want, "the 7 Stone nodes carry the same states")
	ok(stones.all(func(s: Node) -> bool: return (s as Control).accessibility_name != ""), "every stone has an accessibility name")
	var today_lbl: Label = null
	for l in row.find_children("*", "Label", true, false) if row != null else []:
		if (l as Label).text == "금":
			today_lbl = l
	ok(today_lbl != null and today_lbl.get_theme_font("font") == UI.bold_font(), "today's weekday letter is bold")
	await _drop(tv)
	# a protected day
	_reset()
	StudyLog.today_override = FRI
	for d in [FRI - 3, FRI - 1]:
		Store.progress["days"][Plan.days_to_iso(d)] = {"en": true}
	StudyLog._freeze("en")["tokens"] = 1
	StudyLog._freeze("en")["frozen"] = [Plan.days_to_iso(FRI - 2)]
	tv = await _make()
	row = tv.card("streak").find_child("Stones", true, false)
	ok(row.get_meta("states") == ["missed", "done", "frozen", "done", "today", "future", "future"], "protected day Wed is 'frozen' %s" % str(row.get_meta("states")))
	await _drop(tv)
	# no streak yet: text from the model, not '연속 0일'
	_reset()
	tv = await _make()
	ok(_label_with(tv.card("streak"), "오늘부터 시작") != null and _label_with(tv.card("streak"), "연속 0일") == null, "no streak: pill says '오늘부터 시작'")
	await _drop(tv)


# ---------------------------------------------------------------- T4-10 day change

func _test_day_change() -> void:
	print("[T4-10 the day changes while the home is open]")
	_reset()
	StudyLog.today_override = FRI
	for d in [FRI - 3, FRI - 2, FRI - 1]:
		Store.progress["days"][Plan.days_to_iso(d)] = {"en": true}
	StudyLog._freeze("en")["tokens"] = 0 # no protection token: a missed day breaks the streak
	var tv := await _make()
	var row: Control = tv.card("streak").find_child("Stones", true, false)
	ok(row.get_meta("states")[4] == "today" and _label_with(tv.card("streak"), "연속 3일") != null, "Friday: today stone is #4, streak 3")
	ok(not tv._check_day(), "_check_day() == false while the day is the same")
	StudyLog.today_override = FRI + 1
	ok(tv._check_day(), "_check_day() == true after the date moved")
	await _frames(6)
	row = tv.card("streak").find_child("Stones", true, false)
	ok(row.get_meta("states") == ["missed", "done", "done", "done", "missed", "today", "future"], "Saturday: today stone moved to #5, Friday became 'missed' %s" % str(row.get_meta("states")))
	ok(_label_with(tv.card("streak"), "오늘부터 시작") != null and _label_with(tv.card("streak"), "연속 3일") == null, "Friday missed without protection: the streak text follows the new rule")
	ok(tv._built_day == FRI + 1, "the page remembers the new day")
	await _drop(tv)
	# the 30 s timer calls the same path
	_reset()
	StudyLog.today_override = FRI
	tv = await _make()
	StudyLog.today_override = FRI + 2
	tv._on_tick()
	await _frames(6)
	ok(tv._built_day == FRI + 2, "the tick handler redraws after a date change")
	await _drop(tv)


# ---------------------------------------------------------------- T4-11 start button

func _tap(b: Button) -> void:
	b.pressed.emit()


func _test_start_button() -> void:
	print("[T4-11 start button]")
	_reset()
	var tv := await _make()
	var cell: Dictionary = PathModel.current_cell("en")
	_events.clear()
	_tap(tv.hero_button())
	ok(_events.size() == 1 and _events[0][0] == "navigate_args" and _events[0][1] == "lesson", "lesson hero -> navigate_args('lesson', ...)")
	var args: Dictionary = _events[0][2] if _events.size() == 1 and _events[0][0] == "navigate_args" else {}
	ok(args.get("lang") == "en" and int(args.get("n", 0)) == int(cell["n"]) and int(args.get("w", 0)) == int(cell["w"]) and args.get("start") == true, "args {lang, n, w, start:true} = the current path cell %s" % str(args))
	await _drop(tv)
	# the second language
	_reset("ja")
	tv = await _make()
	_events.clear()
	_tap(tv.hero_button())
	ok(_events.size() == 1 and _events[0][2].get("lang") == "ja", "Japanese home: the lesson args say lang 'ja'")
	await _drop(tv)
	# review hero (lesson done today, cards due): navigate('review', lang)
	_reset()
	StudyLog.add_lesson("en", 4, 5)
	Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": ""}])
	tv = await _make()
	ok(tv.hero_button().text == "복습 1개 시작", "review hero text '%s'" % tv.hero_button().text)
	_events.clear()
	_tap(tv.hero_button())
	ok(_events == [["navigate", "review", "en"]], "review hero -> navigate('review', 'en') %s" % str(_events))
	var rb: Button = _button_with(tv, "복습 1개")
	ok(rb != null, "the review row says '복습 1개'")
	if rb != null:
		_events.clear()
		_tap(rb)
		ok(_events == [["navigate", "review", "en"]], "the review row opens the review screen")
	await _drop(tv)
	# song hero
	Store.progress["review"] = []
	_set_songs(4)
	tv = await _make()
	ok(tv.hero_button().text == "노래 외우기 시작", "song hero text")
	_events.clear()
	_tap(tv.hero_button())
	ok(_events == [["navigate", "song", "en"]], "song hero -> navigate('song', 'en')")
	await _drop(tv)
	# nothing left: practice
	_set_songs(0)
	tv = await _make()
	ok(tv.hero_button().text == "더 연습하기", "all done: hero '더 연습하기'")
	_events.clear()
	_tap(tv.hero_button())
	ok(_events == [["navigate", "practice", "en"]], "practice hero -> navigate('practice', 'en')")
	var talk: Button = _button_with(tv, "원어민과 말해 보기")
	if talk != null:
		_events.clear()
		_tap(talk)
		ok(_events == [["navigate", "talk", "en"]], "the talk row opens the conversation")
	else:
		ok(false, "the talk row exists")
	await _drop(tv)
	# resume card, shortcuts
	_reset()
	StudyLog.note_resume("practice", "en")
	tv = await _make()
	_events.clear()
	_tap(_button_with(tv.card("resume"), "시작"))
	ok(_events == [["navigate", "practice", "en"]], "the resume card button opens the practice screen")
	if _phone:
		var tiles: Array = tv.card("shortcuts").get_meta("buttons")
		_events.clear()
		_tap(tiles[0])
		_tap(tiles[1])
		_tap(tiles[2])
		ok(_events == [["navigate", "talk", "en"], ["navigate", "practice", "en"], ["navigate", "reading", "en"]], "shortcut tiles open 대화, 연습, 읽기")
	# language switch changes the language and the page
	var sw: Control = tv.lang_switch()
	var ja_btn: Button = null
	for b in sw.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("일본어"):
			ja_btn = b
	ok(ja_btn != null, "language switch has a Japanese button")
	if ja_btn != null:
		ja_btn.pressed.emit()
		await _frames(6)
		ok(Store.lang() == "ja" and HomeModel.hero(HomeModel.snapshot("ja"))["target"]["args"]["lang"] == "ja", "switching to 일본어 sets the language")
	await _drop(tv)


# ---------------------------------------------------------------- T4-12 AI slot buttons

func _test_ai() -> void:
	print("[T4-12 AI slot]")
	_reset()
	HomeAi.provider = Callable() # the default implementation, driven by Backend.status
	HomeAi.force_phone = 0
	Backend.status = Backend.Status.FAILED
	Backend.health = {"llm": true}
	var tv := await _make()
	var c: Control = tv.card("ai")
	ok(c != null, "Backend FAILED: the AI card shows")
	if c != null:
		ok(_label_with(c, "AI 연결 안 됨") != null, "title 'AI 연결 안 됨'")
		var all: String = " ".join(_texts(tv))
		for w in ["Ollama", "OpenCode", "GPT", "Claude"]:
			ok(not all.contains(w), "the home text does not name an engine ('%s')" % w)
		var ab: Button = c.get_meta("action_button")
		_ai_requests = 0
		_tap(ab)
		ok(_ai_requests == 1, "[AI 연결하기] -> Store.ai_connect_requested exactly once (%d)" % _ai_requests)
		var lb: Button = c.get_meta("later_button")
		_tap(lb)
		await _frames(5)
		ok(tv.card("ai") == null, "[나중에] hides the card")
		ok(int(Store.prefs.get("home_ai_dismiss_day", -1)) == StudyLog.today(), "prefs.home_ai_dismiss_day == today")
		var saved: String = FileAccess.get_file_as_string(Store.prefs_path)
		ok(saved.contains("home_ai_dismiss_day"), "the pref reached the (test) prefs file")
		ok(_ai_requests == 1, "[나중에] does not ask to connect")
	await _drop(tv)
	# READY with the answers on: nothing to show
	Backend.status = Backend.Status.READY
	Backend.health = {"llm": true}
	Store.prefs.erase("home_ai_dismiss_day")
	tv = await _make()
	ok(tv.card("ai") == null, "Backend READY: no AI card")
	# status change redraws an open home
	Backend.status = Backend.Status.FAILED
	Backend.status_changed.emit()
	await _frames(6)
	ok(tv.card("ai") != null, "an open home shows the card when the status turns FAILED")
	await _drop(tv)
	HomeAi.provider = func() -> Dictionary: return {"show": false}


# ---------------------------------------------------------------- T4-13 song row

func _test_songs() -> void:
	print("[T4-13 song row]")
	_reset()
	_set_songs(4)
	var tv := await _make()
	var b: Button = _button_with(tv, "노래 외우기 4줄")
	ok(b != null, "SongDue.cache due 4 -> row '노래 외우기 4줄'")
	var rows: Array = tv.task_buttons()
	ok(rows.size() == 3 and (rows[1] as Button).text == "노래 외우기 4줄", "song row sits after the lesson row, before the optional talk row")
	await _drop(tv)
	_set_songs(0)
	tv = await _make()
	ok(_button_starting(tv, "노래 외우기") == null, "due 0 -> no song row")
	await _drop(tv)
	# the real scan on a thread: with the guard on and the test folder empty it counts zero and the page does not break
	SongDue.cache = {"songs": 0, "lyrics": 0, "due": 9, "fresh": 0, "at": 0}
	tv = TodayView.new()
	tv.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(tv)
	await _frames(40)
	ok(int(SongDue.cache.get("at", 0)) > 0 and int(SongDue.cache.get("due", -1)) == 0, "the thread scan of an empty song folder filled the cache with zeros")
	ok(_button_starting(tv, "노래 외우기") == null and tv._song_thread == null, "after the scan: no song row, thread joined")
	await _drop(tv)
	# a broken song list counts as zero
	var res: Dictionary = SongDue.scan(func() -> Variant: return "not a dictionary")
	ok(int(res["due"]) == 0 and int(res["songs"]) == 0, "SongDue.scan with a broken lister -> zeros")


# ---------------------------------------------------------------- T4-19 direct mark

func _test_direct_mark() -> void:
	print("[T4-19 direct mark]")
	_reset()
	StudyLog.today_override = -1 # Store.toggle_today uses the system date
	var tv := await _make()
	var cb: CheckBox = tv.card("streak").get_meta("toggle_button")
	var lbl: Label = tv.card("streak").get_meta("toggle_label")
	ok(lbl.text == "오늘 공부한 걸로 표시" and not cb.button_pressed and not Store.did_day(StudyLog.today(), "en"), "not marked: '오늘 공부한 걸로 표시', box empty")
	cb.button_pressed = true # the same path as a tap
	await _frames(6)
	cb = tv.card("streak").get_meta("toggle_button")
	lbl = tv.card("streak").get_meta("toggle_label")
	ok(Store.did_day(StudyLog.today(), "en") and lbl.text == "표시 취소" and cb.button_pressed, "pressed: did_day(today) is true, the label says '표시 취소', box checked")
	var states: Array = tv.card("streak").find_child("Stones", true, false).get_meta("states")
	ok(states.has("done"), "today's stone is filled after marking %s" % str(states))
	cb.button_pressed = false
	await _frames(6)
	cb = tv.card("streak").get_meta("toggle_button")
	lbl = tv.card("streak").get_meta("toggle_label")
	ok(not Store.did_day(StudyLog.today(), "en") and lbl.text == "오늘 공부한 걸로 표시" and not cb.button_pressed, "pressed again: not marked, label back")
	await _drop(tv)
	# a day already marked by something else (lesson, goal) shows the same
	Store.mark_today("en")
	tv = await _make()
	ok(tv.card("streak").get_meta("toggle_label").text == "표시 취소" and tv.card("streak").get_meta("toggle_button").button_pressed, "a day marked elsewhere reads '표시 취소', box checked")
	await _drop(tv)
	_reset()


# ---------------------------------------------------------------- T4-18 wrong input

func _test_garbage() -> void:
	print("[T4-18 wrong input]")
	for case_name in ["empty snapshot", "garbage snapshot", "AI provider garbage", "AI provider weird dict", "negative song cache", "broken song list"]:
		_reset()
		var tv := TodayView.new()
		tv.set_anchors_preset(Control.PRESET_FULL_RECT)
		match case_name:
			"empty snapshot":
				tv.snapshot_hook = func(_l: String) -> Variant: return {}
			"garbage snapshot":
				tv.snapshot_hook = func(_l: String) -> Variant: return "not a dictionary"
			"AI provider garbage":
				HomeAi.provider = func() -> Variant: return 42
			"AI provider weird dict":
				HomeAi.provider = func() -> Variant: return {"show": "yes", "title": 123, "action": ["x"], "prominent": "no"}
			"negative song cache":
				SongDue.cache = {"songs": -3, "lyrics": "x", "due": -5, "fresh": 1.5, "at": int(Time.get_unix_time_from_system())}
			"broken song list":
				SongDue.scan(func() -> Variant: return [1, 2, 3])
				SongDue.cache["at"] = int(Time.get_unix_time_from_system())
		add_child(tv)
		await _frames(6)
		var rows: Array = tv.task_buttons()
		var names: Array = []
		for b in rows:
			names.append((b as Button).text)
		ok(tv.card("tasks") != null and tv.hero_button() != null, "%s: the home is drawn" % case_name)
		ok(names == ["오늘의 레슨", "원어민과 말해 보기"], "%s: default shape, lesson + talk rows %s" % [case_name, str(names)])
		ok(tv.card("ai") == null, "%s: no AI card" % case_name)
		await _drop(tv)
	_reset()
	# the detector can fail: a row list with a song row is not the default shape
	var fake_names: Array = ["오늘의 레슨", "노래 외우기 4줄", "원어민과 말해 보기"]
	print("selfcheck %s default-shape check on a list with a song row" % ("FAIL-as-expected" if fake_names != ["오늘의 레슨", "원어민과 말해 보기"] else "UNEXPECTED-PASS"))
	ok(fake_names != ["오늘의 레슨", "원어민과 말해 보기"], "self-check: the default-shape comparison rejects a list with a song row")


# ---------------------------------------------------------------- T4-17 file rules (source text)

func _test_file_rules() -> void:
	print("[T4-17 file rules]")
	var src: String = FileAccess.get_file_as_string("res://scripts/views/today_view.gd")
	ok(src != "" and not src.contains("Sync" + "Panel") and not src.contains("open_" + "settings"), "today_view.gd has no SyncPanel / open_settings text")
	for p in ["res://scripts/views/today_view.gd", "res://scripts/ui/home_parts.gd", "res://scripts/ui/goal_ring.gd"]:
		var t: String = FileAccess.get_file_as_string(p)
		ok(t != "" and not t.contains("Color(\"#"), "%s: no Color(\"#...\") literal" % p.get_file())
	var fake: String = "var c = Color(\"" + "#FF0000\")"
	print("selfcheck %s literal scan on a fake source" % ("FAIL-as-expected" if fake.contains("Color(\"#") else "UNEXPECTED-PASS"))
	ok(fake.contains("Color(\"#"), "self-check: the literal scan flags a fake source")
