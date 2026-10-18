extends Node
## 오늘·설정 개편 (docs/ui_redesign_design.md §8.4 W5, W5-1..W5-6): SettingsView sections and mount, the two new display
## settings (saved only when allowed), the "모든 기록 지우기" sheet, one filled button per language card, and no overlap
## with a panel mounted into the sync section.
##   phone: godot --headless --path <project> res://tests/settings_view_test.tscn -- --phone
##   PC:    godot --headless --path <project> res://tests/settings_view_test.tscn
## Files: only user://test_w5/ (prefs, progress, study log); the real files are never opened (test guard + own paths).
## Last line: "== settings_view: N passed, M failed ==", exit code 1 on any failure.

const DIR := "user://test_w5"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _toasts: Array = []
var _old_prefs: String
var _old_progress: String
var _old_log: String


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
	print("== settings_view test start (%s) ==" % ("phone" if _phone else "pc"))
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: the PC run must never reach the user's engine (8770)
	Sheet.animate = false
	await _size_window(Vector2i(412, 915) if _phone else Vector2i(1280, 800))
	UiBoot.apply(get_window(), "light", 1.0)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)

	await _test_mount()
	await _test_standalone()
	await _test_save_values()
	await _test_display_ui()
	await _test_reset_sheet()
	await _test_today_cards()
	await _test_today_settings()
	await _test_overlap()

	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	_cleanup()
	print("== settings_view: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

## Removes the files of this run (user://test_w5/ only).
func _cleanup() -> void:
	var g: String = ProjectSettings.globalize_path(DIR)
	if DirAccess.dir_exists_absolute(g):
		for f in DirAccess.get_files_at(g):
			DirAccess.remove_absolute(g.path_join(f))
		DirAccess.remove_absolute(g)


func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null


func _panel_with(text: String) -> VBoxContainer:
	var p := VBoxContainer.new()
	p.add_child(UI.label(text))
	return p


## The newest open sheet's node (the sheets hang under their host).
func _open_sheet() -> Sheet:
	var best: Sheet = null
	for n in get_tree().root.find_children("*", "Sheet", true, false):
		if not (n as Sheet).is_closed():
			best = n
	return best


func _hash_progress() -> String:
	return JSON.stringify(Store.progress).md5_text()


# ---------------------------------------------------------------- W5-1 mount

func _test_mount() -> void:
	print("[mount]")
	var sv := SettingsView.new()
	sv.auto_panels = false
	_stage(sv)
	await _frames(2)
	ok(sv.section_ids() == ["connection", "engine", "learning", "voice", "display", "sync", "danger"], "seven section ids in order (%s)" % str(sv.section_ids()))
	var panels := {}
	for id in sv.section_ids():
		panels[id] = _panel_with("내용 " + id)
		sv.mount(id, panels[id])
	await _frames(2)
	for id in sv.section_ids():
		ok(sv.section_of(panels[id]) == id and (panels[id] as Control).visible and sv.section_visible(id), "mount('%s'): the panel sits in that section and shows" % id)
	# an empty panel: hidden, with its divider, and a section that has nothing else stays hidden
	var sv2 := SettingsView.new()
	sv2.auto_panels = false
	_stage(sv2)
	var empty := VBoxContainer.new()
	var second := _panel_with("둘째")
	sv2.mount("sync", empty)
	sv2.mount("sync", second)
	await _frames(2)
	ok(not empty.visible, "an empty panel stays hidden")
	var div: Control = second.get_parent().get_parent().get_child(second.get_parent().get_index() - 1)
	ok(second.visible and not div.visible, "its divider is hidden too (nothing visible above the second panel)")
	empty.add_child(Label.new())
	await _frames(1)
	ok(empty.visible and div.visible, "the panel and the divider show as soon as it gets a child")
	var lone := VBoxContainer.new()
	sv2.mount("learning", lone) # 'learning' holds the start-date block, so it always shows
	ok(sv2.section_visible("learning"), "a section with the default rows shows")
	# unknown section id: a warning and the last section, no crash
	var odd := _panel_with("모르는 자리")
	sv.mount("nonsense", odd)
	await _frames(1)
	ok(sv.section_of(odd) == "danger" and odd.visible, "unknown section id goes to the last section ('danger')")
	sv.mount("danger", null) # a null panel is ignored
	ok(true, "mount(null) does not crash")
	# the settings screen takes a panel into the section it is mounted in (TodayView's helper is gone)
	var sv3 := SettingsView.new()
	sv3.auto_panels = false
	_stage(sv3)
	var sp := SyncPanel.new()
	var other := _panel_with("연결")
	sv3.mount("sync", sp)
	sv3.mount("connection", other)
	ok(sv3.section_of(sp) == "sync" and sv3.section_of(other) == "connection", "SettingsView.mount: the SyncPanel goes to 'sync', any other panel to 'connection'")
	sv.queue_free()
	sv2.queue_free()
	sv3.queue_free()
	await _frames(2)


func _test_standalone() -> void:
	print("[standalone]")
	var sv := SettingsView.new()
	_stage(sv)
	await _frames(3)
	ok(sv.page_title() == "설정" and sv.scroll_host() != null and sv.header_block() != null, "standalone: AppView title, scroll host and big title block")
	var first := ""
	for id in sv.section_ids():
		if first == "" and sv.section_visible(id):
			first = id
	ok(first == "connection", "standalone: the first visible section is 'connection' (%s)" % first)
	var link_cls := "RemoteLinkPanel" if _phone else "PhoneLinkPanel"
	ok(sv.find_children("*", link_cls, true, false).size() == 1, "standalone: %s is mounted by the screen" % link_cls)
	ok(sv.find_children("*", "SyncPanel", true, false).size() == 1 and not sv.section_visible("sync"), "standalone: the SyncPanel is mounted and, without a SyncManager, empty and hidden")
	ok(sv.section_visible("danger") and sv.section_visible("display") and sv.section_visible("voice") and sv.section_visible("learning"), "standalone: learning, voice, display and danger show")
	ok(sv.section_visible("engine") == (not _phone), "the engine section shows on the PC only (%s)" % str(sv.section_visible("engine")))
	ok((sv._engine_ob != null) == (not _phone), "the AI engine dropdown exists on the PC only")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- W5-2 saving

func _test_save_values() -> void:
	print("[save scheme / font_scale]")
	Store.prefs.erase("scheme")
	Store.prefs.erase("font_scale")
	var sv := SettingsView.new()
	sv.auto_panels = false
	_stage(sv)
	await _frames(2)
	_toasts.clear()
	ok(sv.save_scheme("dark") and Store.prefs.get("scheme") == "dark", "'dark' is saved")
	ok(_toasts.size() == 1 and _toasts[0][1] == "info", "a valid change says once that it applies after reopening (%s)" % str(_toasts))
	_toasts.clear()
	for good in ["light", "system"]:
		ok(sv.save_scheme(good) and Store.prefs.get("scheme") == good, "'%s' is saved" % good)
	for f in [1.0, 1.15, 1.3, 1.5]:
		_toasts.clear()
		ok(sv.save_font_scale(f) and is_equal_approx(float(Store.prefs.get("font_scale", 0.0)), f), "font_scale %s is saved" % str(f))
	ok(sv.save_font_scale(1) and typeof(Store.prefs.get("font_scale")) == TYPE_FLOAT, "an int 1 is stored as 1.0")
	var before_scheme: Variant = Store.prefs.get("scheme")
	var before_scale: Variant = Store.prefs.get("font_scale")
	for bad in ["neon", "", "Dark", 5, null]:
		_toasts.clear()
		ok(not sv.save_scheme(bad) and Store.prefs.get("scheme") == before_scheme, "scheme %s is refused and not saved" % var_to_str(bad))
		ok(_toasts.size() == 1 and _toasts[0][1] == "error" and _toasts[0][0] == "지원하지 않는 값이에요", "scheme %s: exactly one error toast" % var_to_str(bad))
	for bad in [2.0, "abc", 0.0, -1.0, NAN, INF, 1.2, null]:
		_toasts.clear()
		ok(not sv.save_font_scale(bad) and is_equal_approx(float(Store.prefs.get("font_scale")), float(before_scale)), "font_scale %s is refused and not saved" % var_to_str(bad))
		ok(_toasts.size() == 1 and _toasts[0][1] == "error", "font_scale %s: exactly one error toast" % var_to_str(bad))
	# not a shared (synced) setting
	ok(not SyncDoc.SHARED_PREFS.has("scheme") and not SyncDoc.SHARED_PREFS.has("font_scale"), "scheme and font_scale stay per device (not in SyncDoc.SHARED_PREFS)")
	# what an old or broken prefs file holds reads as the default
	Store.prefs["scheme"] = "purple"
	Store.prefs["font_scale"] = "abc"
	ok(SettingsView.saved_scheme() == "system" and SettingsView.saved_font_scale() == 1.0, "a broken saved value reads as system / 1.0")
	Store.prefs.erase("scheme")
	Store.prefs.erase("font_scale")
	sv.queue_free()
	await _frames(2)


func _test_display_ui() -> void:
	print("[display rows]")
	Store.prefs.erase("scheme")
	Store.prefs.erase("font_scale")
	Store.prefs["show_hangul_ja"] = true
	var sv := SettingsView.new()
	sv.auto_panels = false
	_stage(sv)
	await _frames(3)
	ok(sv._scheme_value.text == "시스템" and sv._font_value.text == "보통", "default values read 시스템 / 보통")
	# tap-free: the rows' handlers open a choice sheet; pick a value through the sheet's own button
	sv._pick_scheme()
	await _frames(2)
	var sh := _open_sheet()
	ok(sh != null and sh.buttons.has("dark") and sh.buttons.size() == 3, "화면 모드 opens a choice sheet with three entries")
	_toasts.clear()
	if sh != null:
		(sh.buttons["dark"] as Button).pressed.emit()
	await _frames(2)
	ok(Store.prefs.get("scheme") == "dark" and sv._scheme_value.text == "다크" and not Sheet.is_open(), "picking 다크 saves it, updates the row and closes the sheet")
	ok(_toasts.size() == 1 and (_toasts[0][0] as String).contains("적용돼요"), "and says it applies after reopening")
	sv._pick_font()
	await _frames(2)
	sh = _open_sheet()
	ok(sh != null and sh.buttons.size() == 5, "글자 크기 opens a choice sheet with five entries (90 / 100 / 115 / 130 / 150 %)")
	if sh != null:
		(sh.buttons["1.5"] as Button).pressed.emit()
	await _frames(2)
	ok(is_equal_approx(float(Store.prefs.get("font_scale", 0.0)), 1.5) and sv._font_value.text == "아주 크게", "picking 150% saves 1.5 and updates the row")
	ok(sv._font_sample.get_theme_font_size("font_size") > Ds.type_size("") , "the sample line grows to the saved size")
	# dismissing the sheet changes nothing
	sv._pick_scheme()
	await _frames(2)
	_toasts.clear()
	Sheet.close_top()
	await _frames(1)
	ok(Store.prefs.get("scheme") == "dark" and _toasts.is_empty(), "closing the sheet without a pick saves nothing and says nothing")
	# the hangul line switch keeps its pref key
	var sw: CheckButton = null
	for n in sv.find_children("*", "CheckButton", true, false):
		if (n as CheckButton).accessibility_name == "한글 발음 표시":
			sw = n
	ok(sw != null and sw.button_pressed, "한글 발음 표시 is a switch row, on")
	if sw != null:
		sw.button_pressed = false
	ok(Store.prefs.get("show_hangul_ja") == false, "turning it off writes show_hangul_ja = false")
	Store.prefs["show_hangul_ja"] = true
	Store.prefs.erase("scheme")
	Store.prefs.erase("font_scale")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- W5-3 reset

func _test_reset_sheet() -> void:
	print("[모든 기록 지우기]")
	Store.progress = Progress.blank()
	Store.progress["checks"]["en-9-w9"] = true
	Store.progress["xp"]["en"] = 77
	var sv := SettingsView.new()
	sv.auto_panels = false
	_stage(sv)
	await _frames(3)
	var resets := {"n": 0}
	sv.records_reset.connect(func() -> void: resets["n"] += 1)
	var btn := _find_button(sv, "모든 기록 지우기")
	ok(btn != null, "the reset button exists")
	var h0 := _hash_progress()
	btn.pressed.emit()
	await _frames(2)
	var sh := _open_sheet()
	ok(Sheet.is_open() and sh != null, "pressing it opens a sheet and wipes nothing yet")
	ok(sh != null and sh.title_label != null and sh.title_label.text == "모든 기록 지우기", "the sheet has the title")
	var yes: Button = sh.buttons.get("ok") if sh != null else null
	ok(yes != null and yes.text == "지우기", "the sheet has the 지우기 button")
	var st: StyleBoxFlat = yes.get_theme_stylebox("normal") as StyleBoxFlat if yes != null else null
	ok(st != null and st.bg_color.is_equal_approx(Pal.BAD), "and it is the danger (BAD fill) button")
	ok(_hash_progress() == h0, "still unchanged while the question is open")
	# cancel
	(sh.buttons["cancel"] as Button).pressed.emit()
	await _frames(2)
	ok(not Sheet.is_open() and _hash_progress() == h0 and resets["n"] == 0, "취소: the sheet closes, the record is byte for byte the same (hash), no reset signal")
	# dismiss (dim / back) also keeps it
	btn.pressed.emit()
	await _frames(2)
	Sheet.handle_back()
	await _frames(2)
	ok(not Sheet.is_open() and _hash_progress() == h0, "back / outside tap: same, nothing wiped")
	# confirm
	btn.pressed.emit()
	await _frames(2)
	sh = _open_sheet()
	(sh.buttons["ok"] as Button).pressed.emit()
	await _frames(3)
	ok(not Store.progress["checks"].has("en-9-w9") and int(Store.progress["xp"].get("en", 0)) == 0, "지우기: the record is wiped")
	ok(resets["n"] == 1, "and the screen is told once")
	ok(not Sheet.is_open(), "the sheet is gone")
	# the sentence of the confirmation is the one SyncPanel gives
	btn.pressed.emit()
	await _frames(2)
	var texts: Array = []
	for l in get_tree().root.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree():
			texts.append((l as Label).text)
	ok(texts.has(SyncPanel.reset_confirm_text()), "the sheet shows SyncPanel.reset_confirm_text()")
	Sheet.close_top()
	await _frames(2)
	# source: the order is "before_reset" first (awaited), the wipe after it
	var src: String = FileAccess.get_file_as_string("res://scripts/views/settings_view.gd")
	var i_before: int = src.find("await SyncPanel.before_reset()")
	var i_reset: int = src.find("Store.reset_progress()")
	ok(i_before > 0 and i_reset > i_before, "settings_view.gd awaits SyncPanel.before_reset() before Store.reset_progress()")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- W5-5 one filled button per card

func _filled_count(card: Node, accent: Color) -> int:
	var n := 0
	for b in card.find_children("*", "Button", true, false):
		if b is CheckBox or b is CheckButton:
			continue
		var sb: StyleBox = (b as Button).get_theme_stylebox("normal")
		if sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.is_equal_approx(accent):
			n += 1
	return n


func _test_today_cards() -> void:
	print("[오늘: primary buttons]")
	Store.progress = Progress.blank()
	Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": ""}])
	var tv := TodayView.new()
	_stage(tv)
	await _frames(4)
	ok(tv._grid != null and tv._grid.get_child_count() == 2, "two language cards")
	for state in ["open", "done"]:
		if state == "done":
			Store.toggle_today("en")
			Store.toggle_today("ja")
			await _frames(4)
		var i := 0
		for l in ["en", "ja"]:
			var card: Node = tv._grid.get_child(i)
			i += 1
			ok(_filled_count(card, Pal.accent(l)) == 1, "%s card (%s day): exactly one accent-filled button" % [l, state])
			ok(_find_button(card, "오늘의 레슨") != null, "%s card: the lesson button is there" % l)
	# the detector can fail: a card with two filled buttons counts 2
	var fake := VBoxContainer.new()
	fake.add_child(UI.button("a", "primary", Pal.EN))
	fake.add_child(UI.button("b", "primary", Pal.EN))
	fake.add_child(UI.button("c", "soft", Pal.EN))
	add_child(fake)
	ok(_filled_count(fake, Pal.EN) == 2, "self-check: two filled buttons are counted as 2")
	fake.queue_free()
	ok(tv._grid.columns == (1 if _phone else 2), "grid columns %d (phone 1, PC 2)" % tv._grid.columns)
	# the big title and the app bar contract
	ok(tv.header_block() != null and tv.scroll_host() == tv._scroll and tv.page_title() == "", "app bar contract: scroll host and big title block, the tab name is the title")
	ok(tv.header_block().find_children("*", "Label", true, false).all(func(l: Node) -> bool: return (l as Label).mouse_filter == Control.MOUSE_FILTER_IGNORE), "the big title's labels are not touch targets")
	Store.progress = Progress.blank()
	tv.queue_free()
	await _frames(2)


func _test_today_settings() -> void:
	print("[설정 screen: panels, start date; 오늘 carries no settings]")
	# 오늘 has no settings of its own any more: no toggle button, no SettingsView under its cards
	var tv := TodayView.new()
	_stage(tv)
	await _frames(3)
	ok(tv.find_children("*", "SettingsView", true, false).is_empty() and _find_button(tv, "설정  ▾") == null and _find_button(tv, "설정  ▴") == null, "오늘: no 설정 toggle button, no SettingsView under the cards")
	ok(not tv.go_back(), "오늘 has no sub screen to step back out of")
	tv.queue_free()
	await _frames(2)
	# the settings screen on its own
	var sv := SettingsView.new()
	_stage(sv)
	await _frames(4)
	ok((sv._engine_ob != null) == (not _phone), "_engine_ob: set on the PC, null on the phone")
	var link_cls := "RemoteLinkPanel" if _phone else "PhoneLinkPanel"
	ok(sv.find_children("*", link_cls, true, false).size() == 1, "the %s is mounted once" % link_cls)
	ok(sv.find_children("*", "SyncPanel", true, false).size() == 1, "the SyncPanel is mounted once (by the settings screen)")
	ok(sv.section_of(sv.find_children("*", "SyncPanel", true, false)[0]) == "sync", "...in the 'sync' section")
	ok(not sv.go_back(), "the settings screen has nothing to step back out of: go_back() is false")
	ok(sv.auto_panels and sv.page_title() == "설정", "the settings screen is a screen of its own (title 설정) and mounts its own panels")
	# a changed start date is announced
	var refreshed := {"n": 0}
	sv.start_changed.connect(func() -> void: refreshed["n"] += 1)
	sv._start_edit.text = "2026-01-05"
	sv._apply_start()
	ok(refreshed["n"] == 1, "a valid start date emits start_changed")
	sv._start_edit.text = "not a date"
	sv._apply_start()
	ok(refreshed["n"] == 1 and sv._start_msg.text != "", "a broken date shows the message and changes nothing")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- W5-6 no overlap

## Visible controls that stick out of the window horizontally (the phone walker's L-02 rule, for this screen only).
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


func _test_overlap() -> void:
	print("[overlap with a mounted dummy panel]")
	var sizes: Array = [Vector2i(412, 915)] if _phone else [Vector2i(1280, 800), Vector2i(900, 600)]
	for sz in sizes:
		await _size_window(sz)
		var sv := SettingsView.new()
		_stage(sv)
		await _frames(2)
		var dummy := VBoxContainer.new()
		dummy.add_theme_constant_override("separation", 8)
		dummy.add_child(UI.label("동기화 더미 패널입니다. 아주 긴 문장이 줄바꿈 되어야 하고 화면 밖으로 삐져나가면 안 돼요. " + "가나다라마바사 ".repeat(12)))
		var row := UI.hbox(8)
		row.add_child(UI.button("지금 동기화", "soft", Pal.PRIMARY))
		row.add_child(UI.button("되돌리기", "soft", Pal.PRIMARY))
		dummy.add_child(row)
		sv.mount("sync", dummy)
		await _frames(4)
		var vp := Vector2(sz)
		var bad := _overflow(sv, vp)
		ok(bad.is_empty(), "%dx%d: nothing sticks out of the window (%d)" % [sz.x, sz.y, bad.size()])
		for b in bad.slice(0, 5):
			print("    overflow ", b)
		ok(sv.section_visible("sync") and dummy.is_visible_in_tree(), "%dx%d: the sync section shows the dummy" % [sz.x, sz.y])
		# the dummy stays inside its group card
		var grp: Control = (sv._secs["sync"] as Dictionary)["group"]
		var gr := grp.get_global_rect()
		var dr := dummy.get_global_rect()
		ok(dr.position.x >= gr.position.x - 0.5 and dr.end.x <= gr.end.x + 0.5, "%dx%d: the dummy lies inside the sync card" % [sz.x, sz.y])
		# the detector can fail: a 3000 px wide control is reported
		var wide := ColorRect.new()
		wide.custom_minimum_size = Vector2(3000, 10)
		sv.add_child(wide)
		await _frames(2)
		ok(_overflow(sv, vp).size() >= 1, "self-check: a 3000 px wide control is reported as overflow")
		sv.queue_free()
		await _frames(2)
	await _size_window(Vector2i(412, 915) if _phone else Vector2i(1280, 800))
