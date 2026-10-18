extends Node
## W13 clean-up checks (docs/ui_redesign_design.md §8.4 W13): the small layout / colour fixes found while sweeping the
## screens at 100 / 130 / 150 % text, each checked on the real part:
##   godot --headless --path <project> res://tests/a11y_sweep_test.tscn -- [--phone] [--font-scale=1.5] [--dark]
##   godot --path <project> --resolution 412x915 res://tests/a11y_sweep_test.tscn -- --phone --shots=<dir>   (also saves a PNG per state)
## B-1 ListGroup row titles wrap to two lines (a third is trimmed) and the row grows; short titles keep the 56 px row.
## B-2 Sheet.choice items wrap instead of being cut off; the picked item keeps its text clear of the check mark.
## B-3 MissionScreen, wide layout (PC only): each option switch sits next to its own label.
## B-4 reading library: the title "읽기" is shown once (no second small "읽기" above the paste card).
## B-5 reading "복습 중" highlight: visible against a white card in the light scheme, text contrast >= 4.5 in both.
## Reads and writes only user://test_a11y_* files. Last line: "== a11y_sweep: N passed, M failed ==".

const FIX := "res://tests/sample_mission_%s.json"
const PREFS := "user://test_a11y_prefs.json"
const PROG := "user://test_a11y_progress.json"
const LOG_PATH := "user://test_a11y_log.json"
const READING_DIR := "user://test_a11y_reading"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _scheme: String = "light"
var _shots: String = ""
var _old_paths: Array = []


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
	print("== a11y_sweep start ==")
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--shots="):
			_shots = a.substr(8)
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: a PC run never reaches the user's engine (8770)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)
	_old_paths = [Store.prefs_path, Store.progress_path, StudyLog.path]
	Store.prefs_path = PREFS
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["auto_speak"] = false
	Store.progress_path = PROG
	Store.progress = Progress.blank()
	StudyLog.path = LOG_PATH
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	print("[mode: %s, scheme %s, font scale %s]" % ["phone" if _phone else "pc", _scheme, _scale])
	UiBoot.apply(get_tree().root, _scheme, _scale)

	await _t_list_group_title()
	await _t_sheet_long_item()
	await _t_mission_switches()
	await _t_reading_library_title()
	_t_learn_colours()
	await _t_checker_itself()

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
	print("== a11y_sweep: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _holder(sz: Vector2) -> Control:
	var h := Control.new()
	h.size = sz
	h.clip_contents = true
	add_child(h)
	return h


func _shot(name: String) -> void:
	if _shots == "":
		return
	await _frames(4)
	var img: Image = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(_shots.path_join(("phone" if _phone else "pc") + "_" + name + ".png"))


func _labels(node: Node, variation: String = "") -> Array:
	var out: Array = []
	for n in node.find_children("*", "Label", true, false):
		var l := n as Label
		if variation == "" or l.theme_type_variation == StringName(variation):
			out.append(l)
	return out


static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.03928 else pow((c + 0.055) / 1.055, 2.4)


static func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


static func ratio(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


# ---------------------------------------------------------------- B-1 ListGroup row title

## A row like the roadmap month row: a narrow column is left for the title because of the trailing progress block.
func _list_row(g: ListGroup, title: String) -> Control:
	var trailing := Control.new()
	trailing.custom_minimum_size = Vector2(110, 10)
	return g.add_row(title, "", trailing)


func _t_list_group_title() -> void:
	var holder := _holder(Vector2(360, 700))
	var box := VBoxContainer.new()
	box.size = Vector2(360, 700)
	holder.add_child(box)
	var g := ListGroup.new()
	box.add_child(g)
	var short_row: Control = _list_row(g, "발음 기초")
	var long_title := "발음 기초와 리듬에 익숙해지기 그리고 짧은 자기소개 말하기"
	var long_row: Control = _list_row(g, long_title)
	var huge_row: Control = _list_row(g, long_title + " " + long_title + " " + long_title)
	await _frames(6)
	var sl: Label = _labels(short_row, "ListMain")[0]
	var ll: Label = _labels(long_row, "ListMain")[0]
	var hl: Label = _labels(huge_row, "ListMain")[0]
	ok(sl.get_line_count() == 1 and absf(short_row.size.y - ListGroup.ROW_H) < 0.5, "B-1: a short title stays one line in the %.0f px row [%d line(s), row %.0f]" % [ListGroup.ROW_H, sl.get_line_count(), short_row.size.y])
	ok(ll.get_line_count() >= 2, "B-1: a long title wraps instead of being cut at one line [%d lines, label %.0fx%.0f]" % [ll.get_line_count(), ll.size.x, ll.size.y])
	ok(ll.get_visible_line_count() == mini(ll.get_line_count(), 2), "B-1: at most two lines are shown [%d visible of %d]" % [ll.get_visible_line_count(), ll.get_line_count()])
	ok(long_row.size.y >= ll.size.y + 16.0 - 0.5, "B-1: the row grows with the two lines (row %.0f, label %.0f + 16 padding)" % [long_row.size.y, ll.size.y])
	ok(hl.get_line_count() >= 3 and hl.get_visible_line_count() == 2 and hl.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "B-1: a third line is trimmed with an ellipsis [%d lines, %d visible]" % [hl.get_line_count(), hl.get_visible_line_count()])
	ok(ll.size.y > sl.size.y + 4.0, "B-1: the wrapped label is taller than the one-line label (%.0f > %.0f)" % [ll.size.y, sl.size.y])
	await _shot("b1_list_group_titles")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B-2 Sheet.choice long item

func _t_sheet_long_item() -> void:
	var items: Array = [
		[1, "1개월차 · 발음 기초와 리듬"],
		[6, "6개월차 · 생활 영역 확장: 병원·약국·은행·주민센터 같은 일상 서비스 상황에서 말하기"],
		[7, "7개월차 · 짧은 제목"],
	]
	var sh := Sheet.choice(self, "이번 달 주제 기준", items, "6")
	await get_tree().create_timer(0.6).timeout # the sheet slides in: measure it where it stays
	await _frames(4)
	var row_h: float = 56.0 if _phone else 48.0
	var b1: Button = sh.buttons["1"]
	var b6: Button = sh.buttons["6"]
	var b7: Button = sh.buttons["7"]
	for b in [b1, b6, b7]:
		var bb := b as Button
		ok(bb.autowrap_mode != TextServer.AUTOWRAP_OFF and not bb.clip_text, "B-2: '%s' wraps its text and is not clipped" % bb.text.left(12))
		ok(bb.get_minimum_size().y <= bb.size.y + 0.5, "B-2: '%s' is tall enough for its wrapped text (min %.0f <= %.0f)" % [bb.text.left(12), bb.get_minimum_size().y, bb.size.y])
	ok(b1.size.y < row_h + 4.0 and b7.size.y < row_h + 4.0, "B-2: short items keep the %.0f px row [%.0f / %.0f]" % [row_h, b1.size.y, b7.size.y])
	ok(b6.size.y > row_h + 4.0, "B-2: the long item grows to more than one line [%.0f > %.0f]" % [b6.size.y, row_h])
	ok(b6.get_theme_stylebox("normal").get_margin(SIDE_RIGHT) >= 44.0, "B-2: the picked item keeps 44 px clear at the right for the check mark")
	ok(b6.get_global_rect().end.y <= get_viewport().get_visible_rect().size.y + 0.5, "B-2: the long item is inside the screen [bottom %.0f, screen %.0f]" % [b6.get_global_rect().end.y, get_viewport().get_visible_rect().size.y])
	await _shot("b2_sheet_long_item")
	sh.close("dismiss")
	await _frames(4)


# ---------------------------------------------------------------- B-3 MissionScreen option switches

func _mission_http(_method: String, path: String, _body: Variant, _timeout: float) -> Variant:
	var p: String = path.split("?")[0]
	var fc := FakeCall.new()
	var res: Dictionary
	match p:
		"/missions":
			res = _res(_json("list"))
		"/chat":
			res = _res(_json("chat"))
		"/missions/check":
			res = _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
		_:
			res = {"ok": false, "code": 404, "data": null, "bytes": PackedByteArray(), "error": "no route", "cancelled": false}
	_complete_later(fc, res)
	return fc


func _complete_later(fc: FakeCall, res: Dictionary) -> void:
	await get_tree().process_frame
	fc.complete(res)


func _res(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false}


func _json(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(FIX % name))


func _t_mission_switches() -> void:
	if _phone:
		print("  SKIP  B-3: the wide mission layout is PC only (run without --phone)")
		return
	var holder := _holder(Vector2(1280, 800))
	var ms := MissionScreen.new()
	ms.http = Callable(self, "_mission_http")
	holder.add_child(ms)
	await _frames(3)
	ms.open("en")
	for i in 120:
		if ms.status == "list":
			break
		await get_tree().process_frame
	ms._select("cafe_order")
	await _frames(3)
	for n in ms.find_children("*", "Button", true, false):
		if (n as Button).text == "미션 시작" and (n as Control).is_visible_in_tree():
			(n as Button).pressed.emit()
			break
	for i in 120:
		if ms.status == "talk" or ms.status == "wait":
			break
		await get_tree().process_frame
	await _frames(6)
	ok(ms.status == "talk" or ms.status == "wait", "B-3 setup: the chat started (status %s)" % ms.status)
	ok(ms._is_wide() and ms._opts.get_child_count() == 2 and not ms._opts.vertical, "B-3 setup: wide layout, the two switches side by side")
	for c in ms._opts.get_children():
		var cb := c as CheckButton
		var need: float = cb.get_minimum_size().x
		ok(cb.size.x <= need + 1.0, "B-3: switch '%s' is as wide as its label + switch, no wider [%.0f <= %.0f]" % [cb.text, cb.size.x, need])
	var a: CheckButton = ms._opts.get_child(0)
	var b: CheckButton = ms._opts.get_child(1)
	var gap: float = b.get_global_rect().position.x - a.get_global_rect().end.x
	ok(gap >= 16.0, "B-3: a gap of at least 16 px between the two switches [%.0f]" % gap)
	await _shot("b3_mission_bar_wide")
	# narrow again (the phone-like layout inside a PC window): the label fills the row, the switch is at the right end
	holder.size = Vector2(412, 915)
	await _frames(6)
	ok(not ms._is_wide() and ms._opts.vertical, "B-3: narrow layout stacks the switches")
	for c in ms._opts.get_children():
		var cb2 := c as CheckButton
		ok(cb2.size_flags_horizontal == Control.SIZE_EXPAND_FILL and cb2.autowrap_mode != TextServer.AUTOWRAP_OFF, "B-3: narrow: '%s' fills the row and can wrap" % cb2.text)
	holder.size = Vector2(1280, 800)
	await _frames(6)
	var first: CheckButton = ms._opts.get_child(0)
	ok(ms._is_wide() and first.size.x <= first.get_minimum_size().x + 1.0, "B-3: back to wide: the switch shrinks to its label again")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B-4 reading library title

func _t_reading_library_title() -> void:
	var holder := _holder(Vector2(412, 915) if _phone else Vector2(1280, 800))
	var rv := ReadingView.new()
	rv.storage_dir = READING_DIR
	rv.auto_fetch = false
	holder.add_child(rv)
	await _frames(6)
	rv.refresh()
	await _frames(6)
	var titles := 0
	var eyebrows := 0
	for l in _labels(rv):
		var lb := l as Label
		if lb.text == "읽기" and lb.is_visible_in_tree():
			titles += 1
			if lb.theme_type_variation == &"Eyebrow":
				eyebrows += 1
	ok(titles == 1, "B-4: the library shows the word '읽기' once [%d]" % titles)
	ok(eyebrows == 0, "B-4: no small '읽기' (Eyebrow) above the paste card [%d]" % eyebrows)
	var h2s: Array = _labels(rv, "H2")
	ok(not h2s.is_empty() and (h2s[0] as Label).text.begins_with("읽고 싶은"), "B-4: the paste card starts with its heading '읽고 싶은 ...'")
	await _shot("b4_reading_library")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B-5 "복습 중" highlight colours

func _t_learn_colours() -> void:
	var keep: String = Pal.scheme()
	for sc in ["light", "dark"]:
		Pal.use(sc)
		var bg: Color = ReadingView.learn_bg()
		var fg: Color = ReadingView.learn_fg()
		var alt: Color = ReadingView.learn_bg_alt()
		ok(ratio(fg, bg) >= 4.5, "B-5 %s: highlight text %.2f:1 on the highlight (>= 4.5)" % [sc, ratio(fg, bg)])
		ok(ratio(fg, alt) >= 4.5, "B-5 %s: highlight text %.2f:1 on the second tint (>= 4.5)" % [sc, ratio(fg, alt)])
		ok(ratio(Pal.INK, bg) >= 4.5, "B-5 %s: INK text %.2f:1 on the highlight (>= 4.5)" % [sc, ratio(Pal.INK, bg)])
		if sc == "light":
			ok(ratio(bg, Pal.SURFACE) >= 1.3, "B-5 light: the highlight stands out from a white card (%.2f:1 >= 1.30)" % ratio(bg, Pal.SURFACE))
		else:
			ok(bg == Pal.WARN_SOFT and fg == Pal.WARN_ON, "B-5 dark: tokens unchanged")
	Pal.use(keep)


# ---------------------------------------------------------------- the checks above must be able to fail

func _t_checker_itself() -> void:
	# a one-line 'trimmed' row (what the old code built): the B-1 measurement must see it
	var holder := _holder(Vector2(360, 300))
	var l := Label.new()
	l.theme_type_variation = &"ListMain"
	l.text = "발음 기초와 리듬에 익숙해지기 그리고 짧은 자기소개 말하기"
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size.x = 150
	holder.add_child(l)
	await _frames(4)
	ok(l.get_line_count() == 1, "self-check: a non-wrapping label reports one line (the B-1 test would fail on it) [%d]" % l.get_line_count())
	# a switch that fills the row: its width is more than its minimum, so the B-3 test would fail on it
	var box := HBoxContainer.new()
	box.size = Vector2(600, 60)
	var cb := CheckButton.new()
	cb.text = "AI 말 자동 읽기"
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(cb)
	holder.add_child(box)
	await _frames(4)
	ok(cb.size.x > cb.get_minimum_size().x + 1.0, "self-check: an expanding switch is wider than its minimum (the B-3 test would fail on it) [%.0f > %.0f]" % [cb.size.x, cb.get_minimum_size().x])
	# the old highlight colour is too faint on white: the B-5 test would fail on it
	var old_r: float = ratio(Color("#FFF3D6"), Color("#FFFFFF"))
	ok(old_r < 1.3, "self-check: the old WARN_SOFT highlight is only %.2f:1 on white (the B-5 test would fail on it)" % old_r)
	holder.queue_free()
	await _frames(2)
