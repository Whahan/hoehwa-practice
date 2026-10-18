extends Node
## Regression test for two shared UI parts (ColumnBox, UI.segmented / UI.lang_segmented):
##   godot --headless --path <project> res://tests/ui_regress_test.tscn               (PC: ColumnBox)
##   godot --headless --path <project> res://tests/ui_regress_test.tscn -- --phone    (phone: segmented control)
## PC: a PageScroll(720) with a BigCard that holds a big PC RecorderWidget at text scale 150 % (its hint label used to
## be one unwrappable line wider than the column). ColumnBox must not recurse (RESIZED -> margins -> RESIZED), must not
## apply its margins more than a few times per frame, and must not grow without end.
## Phone 412 px: at 150 % text the language switch fits inside the page (right edge <= 412 - 16) on the bare widget
## and on the lesson / talk / review / roadmap / stats / reading screens. At 100 % the buttons keep their old height and padding.
## At 100 % (both modes): a ColumnBox is exactly max_width wide on the PC (the phone ignores max_width) and the shell's two
## back paths (Main.handle_back asks the SyncManager first; the app bar's back button) do what they say (W13).
## Reads and writes only user://test_ui_regress_* files. Last line: "== ui_regress: N passed, M failed ==".

const PREFS := "user://test_ui_regress_prefs.json"
const PROG := "user://test_ui_regress_progress.json"
const LOG_PATH := "user://test_ui_regress_log.json"
const READING_DIR := "user://test_ui_regress_reading"
const MAX_APPLY_PER_FRAME := 3


## Counts engine errors (SCRIPT ERROR, stack overflow, push_error) while the test runs.
class ErrCounter extends Logger:
	var count: int = 0
	var first: String = ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array) -> void:
		count += 1
		if first == "":
			first = "%s:%d %s %s" % [file.get_file(), line, code, rationale]


## A SyncManager that is not in the tree: it only records that main.handle_back asked it, and answers as told.
class FakeSync extends SyncManager:
	var consume: bool = false
	var calls: int = 0

	func consume_back() -> bool:
		calls += 1
		return consume


var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _exits: int = 0
var _errs := ErrCounter.new()
var _old_paths: Array = []


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


func _ready() -> void:
	print("== ui_regress start ==")
	_phone = Platform.is_phone()
	OS.add_logger(_errs)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.progress_path = PROG
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	print("[mode: %s]" % ("phone" if _phone else "pc"))
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: a PC run never reaches the user's engine (8770)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())

	# the 100 % look first (UiBoot at 1.0), then everything at 150 %
	UiBoot.apply(get_tree().root, "light", 1.0)
	await _unit_look_100()
	await _unit_column_box_100()
	await _main_back_paths()
	UiBoot.apply(get_tree().root, "light", 1.5)
	if _phone:
		await _phone_segmented()
		await _phone_screens()
	else:
		await _pc_column_box()
		await _pc_column_box_bad_input()
	ok(_errs.count == 0, "no engine error (SCRIPT ERROR / stack overflow / push_error) during the run [%d] %s" % [_errs.count, _errs.first])

	OS.remove_logger(_errs)
	Store.prefs_path = _old_paths[0]
	Store.progress_path = _old_paths[1]
	StudyLog.path = _old_paths[2]
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	for p in [PREFS, PROG, LOG_PATH]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	for d in [READING_DIR.path_join("cache"), READING_DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
	print("== ui_regress: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _seg_buttons(seg: Control) -> Array:
	return seg.find_children("*", "Button", true, false)


func _holder(sz: Vector2) -> Control:
	var h := Control.new()
	h.size = sz
	h.clip_contents = true
	add_child(h)
	return h


# ---------------------------------------------------------------- 100 %: the old look

func _unit_look_100() -> void:
	var seg := UI.lang_segmented("en", func(_v: String) -> void: pass)
	var h := _holder(Vector2(900, 200))
	var box := VBoxContainer.new()
	box.size = Vector2(800, 100)
	h.add_child(box)
	box.add_child(seg)
	await _frames(3)
	var bs: Array = _seg_buttons(seg)
	ok(bs.size() == 2, "100%%: the language switch has 2 buttons [%d]" % bs.size())
	var all_ok: bool = bs.size() == 2
	for b in bs:
		var btn := b as Button
		var sb: StyleBox = btn.get_theme_stylebox("normal")
		if btn.custom_minimum_size.y != Ds.touch_min() or sb.content_margin_left != 18.0 or sb.content_margin_right != 18.0 \
				or sb.content_margin_top != 7.0 or sb.content_margin_bottom != 7.0 or btn.autowrap_mode != TextServer.AUTOWRAP_OFF:
			all_ok = false
			print("    button '%s' h=%s pad=%s/%s/%s/%s wrap=%d" % [btn.text, btn.custom_minimum_size.y, sb.content_margin_left, sb.content_margin_right, sb.content_margin_top, sb.content_margin_bottom, btn.autowrap_mode])
	ok(all_ok, "100%%: button height = Ds.touch_min() (%s), padding 18 / 7, no autowrap (as before)" % str(Ds.touch_min()))
	ok(bs.size() == 2 and (bs[0] as Button).text == "영어 English" and (bs[1] as Button).text == "일본어 日本語", "100 %: labels unchanged")
	h.queue_free()
	await _frames(1)


## 100 % text: the column of a ColumnBox is exactly max_width wide on the PC, whatever the page width (as long as the
## page leaves min_pad on both sides). The phone ignores max_width: the column is the page minus the two side paddings.
func _unit_column_box_100() -> void:
	ok(is_equal_approx(Ds.font_scale, 1.0), "100%%: the text scale is 1.0 for the ColumnBox check (%s)" % Ds.font_scale)
	var holder := _holder(Vector2(PhoneLayout.W if _phone else 1280.0, 800))
	var cb := ColumnBox.new()
	cb.max_width = 720.0
	holder.add_child(cb)
	cb.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var l := Label.new()
	l.text = "a column"
	cb.content.add_child(l)
	await _frames(4)
	if _phone:
		var want: float = PhoneLayout.W - 2.0 * PhoneLayout.PAD
		ok(absf(cb.content.size.x - want) < 1.0, "100%% phone: the column is the page minus 2 x %d, max_width is ignored [%.1f, want %.1f]" % [PhoneLayout.PAD, cb.content.size.x, want])
	else:
		for w in [1280.0, 1000.0, 900.0, 760.0]:
			holder.size = Vector2(w, 800)
			await _frames(4)
			ok(absf(cb.content.size.x - 720.0) < 1.0, "100%% PC: ColumnBox content is max_width (720) wide in a %.0f px page [%.1f]" % [w, cb.content.size.x])
		holder.size = Vector2(600, 800)
		await _frames(4)
		ok(absf(cb.content.size.x - (600.0 - 2.0 * cb.min_pad)) < 1.0, "100%% PC: a page narrower than max_width + 2 x min_pad leaves min_pad (%d) at each side [%.1f]" % [cb.min_pad, cb.content.size.x])
		cb.max_width = 500.0
		holder.size = Vector2(1280, 800)
		await _frames(4)
		ok(absf(cb.content.size.x - 500.0) < 1.0, "100%% PC: max_width 500 gives a 500 px column [%.1f]" % cb.content.size.x)
	holder.queue_free()
	await _frames(1)


# ---------------------------------------------------------------- the shell's back paths (Main)

func _new_main() -> Control:
	var m: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	m.set("quit_on_exit", false)
	_exits = 0
	m.connect("exit_requested", func() -> void: _exits += 1)
	add_child(m)
	return m


## The reader of 읽기 is a sub screen whose title and back button the phone's app bar shows.
func _open_reader(m: Control) -> ReadingView:
	m.call("show_view", "reading")
	var rv: ReadingView = m.get("views")["reading"]
	rv.storage_dir = READING_DIR
	rv.auto_fetch = false
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_reading_analyze.json"))
	var text := ""
	for t in data["tokens"]:
		text += str(t["t"])
	var d: Dictionary = rv.new_doc("Back test", "en", text)
	d["id"] = "backtest"
	rv.save_doc(d)
	rv.open_doc(d)
	rv.set_analysis(data, false)
	return rv


func _main_back_paths() -> void:
	var m := _new_main()
	await _frames(6)
	# main.handle_back asks the SyncManager first: while the first-connection question is open it eats the press and the
	# sheet behind stays; when the manager does not eat it, the press goes on to the sheet
	var prev: SyncManager = SyncManager.current
	var fake := FakeSync.new()
	SyncManager.current = fake
	var sh: Sheet = Sheet.confirm(m, "시험", "열려 있는 동안 뒤로 가면 시트만 닫혀요.")
	await _frames(3)
	ok(Sheet.is_open(), "handle_back setup: a sheet is open")
	fake.consume = true
	m.call("handle_back")
	await _frames(2)
	ok(fake.calls == 1, "handle_back asks SyncManager.consume_back [%d call(s)]" % fake.calls)
	ok(Sheet.is_open(), "handle_back: when consume_back answers true the press stops there (the sheet is still open)")
	fake.consume = false
	m.call("handle_back")
	await _frames(3)
	ok(fake.calls == 2, "handle_back asks again on the next press [%d]" % fake.calls)
	ok(not Sheet.is_open(), "handle_back: when consume_back answers false the press reaches the sheet (closed)")
	if is_instance_valid(sh) and Sheet.is_open():
		Sheet.close_top()
	SyncManager.current = prev
	fake.free()
	# the app bar's back button (phone) / the same handler (PC): one step back out of a sub screen, then to 오늘
	var press := func() -> void:
		var bar: Variant = m.get("_app_bar")
		if _phone and bar != null:
			(bar as AppBar).back_button().pressed.emit()
		else:
			m.call("_on_bar_back")
	var rv := _open_reader(m)
	await _frames(3)
	ok(rv.mode == "reader", "bar back setup: the reader is open")
	if _phone:
		ok((m.get("_app_bar") as AppBar).back_button().visible, "bar back setup: the app bar shows its back button in the reader")
	press.call()
	await _frames(2)
	ok(rv.mode == "library" and m.get("current") == "reading", "bar back: one step out of the reader, still on 읽기 [%s / %s]" % [rv.mode, m.get("current")])
	press.call()
	await _frames(2)
	ok(m.get("current") == "today", "bar back: from the top of a tab it goes to 오늘 [%s]" % m.get("current"))
	press.call()
	await _frames(2)
	ok(m.get("current") == "today" and _exits == 0, "bar back: on 오늘 it does nothing (no exit) [%s, exits %d]" % [m.get("current"), _exits])
	m.call("show_view", "review")
	await _frames(2)
	press.call()
	await _frames(2)
	ok(m.get("current") == "today", "bar back: from another tab it goes to 오늘 [%s]" % m.get("current"))
	if _phone:
		# settings -> [연결 변경] opens the connect screen (the settings screen's own connect_requested, wired by main)
		if m.call("is_connect_open"): # a test run has no PC to talk to: the app opened the connect screen itself
			m.call("_close_connect_view")
			await _frames(3)
		m.call("show_view", "settings")
		await _frames(3)
		var change: Button = null
		for b in (m.get("views")["settings"] as Control).find_children("*", "Button", true, false):
			if (b as Button).text == "연결 변경" and (b as Button).is_visible_in_tree():
				change = b
		ok(change != null, "connect: the settings screen shows a '연결 변경' button on the phone")
		if change != null:
			ok(not m.call("is_connect_open"), "connect setup: the connect screen is closed")
			change.pressed.emit()
			await _frames(3)
			ok(m.call("is_connect_open"), "connect: 설정 -> '연결 변경' opens the connect screen")
	m.queue_free()
	await _frames(3)


# ---------------------------------------------------------------- PC: ColumnBox + RecorderWidget

func _pc_column_box() -> void:
	var holder := _holder(Vector2(1280, 800))
	var page := PageScroll.new(720.0)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(page)
	var card := UI.card("BigCard", 14)
	page.content.add_child(card)
	var rec := RecorderWidget.new(true, Pal.EN, true)
	card.body.add_child(rec)
	var col: ColumnBox = page.column
	var worst: int = 0
	var t0: int = Time.get_ticks_msec()
	var widest: float = 0.0
	for i in 60:
		var before: int = col.apply_calls
		await get_tree().process_frame
		worst = maxi(worst, col.apply_calls - before)
		widest = maxf(widest, col.size.x)
	var ms: int = Time.get_ticks_msec() - t0
	print("    60 frames in %d ms, most _apply_margins calls in one frame: %d, column width %.0f, total calls %d" % [ms, worst, widest, col.apply_calls])
	ok(_errs.count == 0, "PC 150%%: 60 frames with RecorderWidget in a BigCard: no engine error [%d] %s" % [_errs.count, _errs.first])
	ok(worst <= MAX_APPLY_PER_FRAME, "PC 150%%: _apply_margins called at most %d times per frame [%d]" % [MAX_APPLY_PER_FRAME, worst])
	ok(ms < 20000, "PC 150%%: 60 frames took %d ms (< 20000)" % ms)
	ok(widest <= 1280.0 + 1.0, "PC 150%%: the column never grows past the page (1280) [%.0f]" % widest)
	var side_l: int = col.get_theme_constant("margin_left")
	var side_r: int = col.get_theme_constant("margin_right")
	ok(side_l >= col.min_pad and side_r >= col.min_pad, "PC 150%%: margins are never negative, at least min_pad [%d / %d]" % [side_l, side_r])
	# the hint label wraps inside the column instead of stretching it
	var wrapped := true
	for l in rec.find_children("*", "Label", true, false):
		if (l as Label).text.length() > 20 and (l as Label).autowrap_mode == TextServer.AUTOWRAP_OFF:
			wrapped = false
	ok(wrapped, "PC 150 %: the PC recorder hint label can wrap")
	ok(col.get_combined_minimum_size().x <= 1280.0, "PC 150%%: the page content minimum width fits the window [%.0f]" % col.get_combined_minimum_size().x)
	ok(rec.state_name() == "idle", "PC 150%%: the recorder is still idle (state_name) [%s]" % rec.state_name())
	# the column follows the window when it changes
	holder.size = Vector2(1000, 800)
	await _frames(4)
	ok(col.size.x <= 1000.0 + 1.0, "PC 150%%: after the window shrinks to 1000 the column fits [%.0f]" % col.size.x)
	holder.queue_free()
	await _frames(1)


## A column whose content is wider than max_width (a fixed 1100 px child), and odd widths: no recursion, no negative margin.
func _pc_column_box_bad_input() -> void:
	var holder := _holder(Vector2(1280, 800))
	var cb := ColumnBox.new()
	cb.max_width = 400.0
	holder.add_child(cb)
	cb.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(1100, 30) # content min width > max_width
	cb.content.add_child(wide)
	var before: int = cb.apply_calls
	await _frames(10)
	var per_frame: float = float(cb.apply_calls - before) / 10.0
	ok(per_frame <= MAX_APPLY_PER_FRAME, "PC: content (1100) wider than max_width (400) does not loop [%.1f calls/frame]" % per_frame)
	ok(cb.size.x <= 1280.0 + 1.0, "PC: such a column does not grow past the window [%.0f]" % cb.size.x)
	for w in [-50.0, 0.0, 100.0, 5000.0]:
		cb._apply_margins(w)
		ok(cb.get_theme_constant("margin_left") >= 0 and cb.get_theme_constant("margin_right") >= 0, "PC: _apply_margins(%s) leaves no negative margin" % str(w))
	await _frames(3)
	var l1: int = cb.get_theme_constant("margin_left")
	var sorts: Array = [0]
	cb.sort_children.connect(func() -> void: sorts[0] += 1)
	var w_now: float = cb.size.x
	cb._apply_margins(w_now)
	cb._apply_margins(w_now)
	await _frames(2)
	ok(cb.get_theme_constant("margin_left") == l1 and sorts[0] == 0, "PC: applying the same width again sets nothing (margin %d, re-layouts %d)" % [l1, sorts[0]])
	holder.queue_free()
	await _frames(1)


# ---------------------------------------------------------------- phone: segmented control

func _phone_segmented() -> void:
	var holder := _holder(Vector2(PhoneLayout.W, 915))
	var box := VBoxContainer.new()
	box.position = Vector2(PhoneLayout.PAD, 0)
	box.size = Vector2(PhoneLayout.W - 2.0 * PhoneLayout.PAD, 100)
	holder.add_child(box)
	var seg := UI.lang_segmented("en", func(_v: String) -> void: pass)
	box.add_child(seg)
	var seg2 := UI.segmented([["tatoeba", "실제 예문 (빠름)"], ["ai", "AI (느림)"]], "ai", func(_v: String) -> void: pass)
	box.add_child(seg2)
	await _frames(4)
	var limit: float = PhoneLayout.W - PhoneLayout.PAD
	for s in [seg, seg2]:
		var c := s as Control
		var right: float = c.get_global_rect().end.x
		ok(right <= limit + 0.5, "phone 150%%: segmented right edge %.1f <= %.0f" % [right, limit])
		ok(c.get_combined_minimum_size().x <= PhoneLayout.W - 2.0 * PhoneLayout.PAD + 0.5, "phone 150%%: segmented minimum width %.1f <= %.0f" % [c.get_combined_minimum_size().x, PhoneLayout.W - 2.0 * PhoneLayout.PAD])
		for b in _seg_buttons(c):
			var btn := b as Button
			ok(btn.autowrap_mode != TextServer.AUTOWRAP_OFF and btn.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, "phone 150%%: '%s' wraps its text, no ellipsis" % btn.text)
			ok(btn.get_global_rect().end.x <= limit + 0.5 and btn.size.x > 40.0, "phone 150%%: button '%s' ends at %.1f and is %.0f wide" % [btn.text, btn.get_global_rect().end.x, btn.size.x])
			# two lines at most: the button is not taller than 2 text lines + padding
			var fs: int = btn.get_theme_font_size("font_size")
			ok(btn.size.y <= 2.0 * fs * 1.5 + 24.0, "phone 150%%: '%s' is at most 2 lines high [%.0f px, font %d]" % [btn.text, btn.size.y, fs])
	holder.queue_free()
	await _frames(1)


# ---------------------------------------------------------------- phone: the five screens

func _lang_segs(node: Node) -> Array:
	var out: Array = []
	for n in node.find_children("*", "PanelContainer", true, false):
		if (n as PanelContainer).theme_type_variation == &"Seg" and (n as Control).is_visible_in_tree():
			out.append(n)
	return out


func _phone_screens() -> void:
	Store.set_lang("en")
	Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": ""}])
	var limit: float = PhoneLayout.W - PhoneLayout.PAD
	var makers := {
		"lesson": func() -> Control: return LessonView.new(),
		"talk": func() -> Control: return TalkView.new(),
		"review": func() -> Control: return ReviewView.new(),
		"roadmap": func() -> Control: return RoadmapView.new(),
		"stats": func() -> Control: return StatsView.new(),
		"reading": func() -> Control:
			var rv := ReadingView.new()
			rv.storage_dir = READING_DIR
			rv.auto_fetch = false
			return rv,
	}
	for key in makers.keys():
		var holder := _holder(Vector2(PhoneLayout.W, 915))
		var v: Control = (makers[key] as Callable).call()
		holder.add_child(v)
		await _frames(6)
		if v.has_method("refresh"):
			v.call("refresh")
		await _frames(6)
		var segs: Array = _lang_segs(v)
		ok(segs.size() >= 1, "phone 150%% %s: finds the language switch [%d segmented controls]" % [key, segs.size()])
		for s in segs:
			var r: Rect2 = (s as Control).get_global_rect()
			ok(r.end.x <= limit + 0.5 and r.position.x >= -0.5, "phone 150%% %s: segmented control x %.1f..%.1f inside 0..%.0f" % [key, r.position.x, r.end.x, limit])
		holder.queue_free()
		await _frames(2)
