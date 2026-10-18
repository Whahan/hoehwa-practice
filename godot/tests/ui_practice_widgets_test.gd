extends Node
## Practice widgets test (docs/ui_redesign_design.md §6.8, §7.5, W6-1..W6-6):
##   godot --headless --path <project> res://tests/ui_practice_widgets_test.tscn               (PC)
##   godot --headless --path <project> res://tests/ui_practice_widgets_test.tscn -- --phone    (phone)
## RecorderWidget: three states (idle / recording / busy) differ in text, fill colour and disabled look; sizes (phone:
## full width and >= 56 high; PC: Ds.REC_BIG_PC / Ds.REC_SMALL_PC).
## ScorePanel: number colour OK / WARN / BAD, verdict and labels in the *_ON colours, a missed word chip has a border of
## >= 2 px and a good one none (shape, not colour alone), the dark scheme gives the dark tokens.
## MiniChart: the faded bars mix into the card surface (dark: luminance < 0.5; light: lighter than the bar), every
## text size goes through Ds.fs. ProsodyPanel: no hard-coded colours or sizes. SpeakDrill.build_shell keeps its 8
## keys. PracticeView hub: the cards, the language switch, the way to add an item.
## Reads and writes only a user://test_ui_practice_* file (prefs). Last line: "== ui_practice_widgets: N passed, M failed ==".
##
## Screenshot mode (needs a real renderer, not --headless; the assertions are skipped):
##   godot --path <project> --resolution 412x915 --audio-driver Dummy res://tests/ui_practice_widgets_test.tscn -- --shots=<folder> [--phone] [--dark]
## writes <platform>[_dark]_NN_<state>.png of the practice hub, the recorder in its three states, score panels,
## prosody graphs, charts and the real shadowing / dictation / weak-sound screens fed with local fake answers.

const PREFS := "user://test_ui_practice_prefs.json"
const SHELL_KEYS := ["root", "back", "title", "count", "head", "page", "footer_holder", "footer_col"]
const SRC := ["res://scripts/ui/recorder_widget.gd", "res://scripts/ui/score_panel.gd", "res://scripts/ui/prosody_panel.gd",
	"res://scripts/ui/mini_chart.gd", "res://scripts/practice/speak_drill.gd", "res://scripts/views/practice_view.gd"]

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _old_prefs: String = ""
var _old_hook: Callable = Callable()


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
	print("== ui_practice_widgets start ==")
	_phone = Platform.is_phone()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			await _shots_main(arg.substr(8))
			return
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(2)
	_old_prefs = Store.prefs_path
	Store.prefs_path = PREFS
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	_old_hook = SpeakDrill.api_hook
	SpeakDrill.api_hook = Callable(self, "_hook") # the hub pings the server: answer locally
	Pal.use("light")
	Ds.set_font_scale(1.0)
	print("[mode: %s]" % ("phone" if _phone else "pc"))

	await _recorder_test()
	await _score_test()
	_score_bad_input_test()
	_chart_test()
	await _prosody_test()
	_shell_test()
	await _hub_test()
	_source_test()
	_checker_self_test()

	Pal.use("light")
	Ds.set_font_scale(1.0)
	SpeakDrill.api_hook = _old_hook
	Store.prefs_path = _old_prefs
	if FileAccess.file_exists(PREFS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	print("== ui_practice_widgets: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _hook(_method: String, _path: String, _body: Variant) -> Variant:
	return {"ok": false, "code": 0, "data": null, "error": "test"}


# ---------------------------------------------------------------- helpers

func _stage(w: float = 412.0, h: float = 700.0) -> Control:
	var c := Control.new()
	c.size = Vector2(w, h)
	add_child(c)
	return c


## A column as wide as the phone screen: widgets that fill their parent's width are measured in it.
func _col(w: float = 412.0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.custom_minimum_size.x = w
	v.size = Vector2(w, 10)
	add_child(v)
	return v


func _free(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()
	await get_tree().process_frame


static func _lum(c: Color) -> float:
	var l := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * l.call(c.r) + 0.7152 * l.call(c.g) + 0.0722 * l.call(c.b)


func _bg_of(b: Button, state: String) -> Color:
	var sb: StyleBox = b.get_theme_stylebox(state)
	return (sb as StyleBoxFlat).bg_color if sb is StyleBoxFlat else Color(0, 0, 0, 0)


## The chip PanelContainer whose label says `text` (UI.chip = PanelContainer with one Label).
func _chip(root: Node, text: String) -> PanelContainer:
	for p in root.find_children("*", "PanelContainer", true, false):
		if p.get_child_count() > 0 and p.get_child(0) is Label and (p.get_child(0) as Label).text == text:
			return p
	return null


func _border(p: Control) -> int:
	var sb: StyleBox = p.get_theme_stylebox("panel")
	return (sb as StyleBoxFlat).border_width_left if sb is StyleBoxFlat else -1


func _label_with(root: Node, text: String) -> Label:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return l
	return null


func _score_fixture(score: int) -> Dictionary:
	return {
		"score": score, "accuracy": 90, "clarity": 80, "fluency": 70, "transcript": "I'd like a large coffee",
		"units": [
			{"t": "good", "ok": true},
			{"t": "missed", "ok": false, "heard": "lunch"},
			{"t": "odd", "ok": true, "ph": [{"p": "k", "ok": false, "heard": "g"}, {"p": "o", "ok": true}]},
			{"t": "plain", "ok": true, "ph": [{"p": "a", "ok": true}]},
		],
		"tips_ko": [],
	}


# ---------------------------------------------------------------- RecorderWidget (W6-1)

func _recorder_test() -> void:
	print("[recorder widget]")
	var host := _col()
	var big := RecorderWidget.new(true, Pal.EN, false)
	var small := RecorderWidget.new(false, Pal.EN, false)
	small.idle_text = "말하기"
	host.add_child(big)
	var host2 := _col()
	host2.add_child(small)
	await _frames(3)

	for w in [big, small]:
		var rw: RecorderWidget = w
		var tag: String = "big" if rw.big else "small"
		var idle_text: String = rw._btn.text
		var idle_fill: Color = _bg_of(rw._btn, "normal")
		ok(rw.state_name() == "idle" and not rw._btn.disabled, "%s: idle state is enabled" % tag)
		ok(idle_text.begins_with("●"), "%s: idle text starts with the record dot (%s)" % [tag, idle_text])
		# recording (simulated: the recorder autoload is not opened)
		Recorder.recording = true
		Recorder.owner_id = rw.get_instance_id()
		await _frames(2)
		var rec_text: String = rw._btn.text
		var rec_fill: Color = _bg_of(rw._btn, "normal")
		ok(rw.state_name() == "recording", "%s: widget reports recording" % tag)
		ok(rec_text.begins_with("■"), "%s: recording text starts with the stop square (%s)" % [tag, rec_text])
		ok(rec_fill.is_equal_approx(Pal.BAD) and not rec_fill.is_equal_approx(idle_fill), "%s: recording fill is BAD, idle is not" % tag)
		Recorder.recording = false
		Recorder.owner_id = 0
		await _frames(2)
		# busy
		rw.set_enabled(false)
		await _frames(2)
		var busy_text: String = rw._btn.text
		ok(rw.state_name() == "busy" and rw._btn.disabled, "%s: disabled widget is busy and its button disabled" % tag)
		ok(busy_text == rw.busy_text and busy_text != "", "%s: busy text is busy_text (%s)" % [tag, busy_text])
		ok(idle_text != rec_text and rec_text != busy_text and idle_text != busy_text, "%s: the three button texts differ (%s | %s | %s)" % [tag, idle_text, rec_text, busy_text])
		rw.set_enabled(true)
		await _frames(2)
		ok(rw._btn.text == idle_text and not rw._btn.disabled, "%s: enabling again restores the idle text" % tag)

	# sizes
	var br: Rect2 = big._btn.get_global_rect()
	if _phone:
		ok(br.size.y >= 56.0 and br.size.x > 300.0, "phone: big button %.0f x %.0f (>= 56 high, > 300 wide)" % [br.size.x, br.size.y])
		var sr: Rect2 = small._btn.get_global_rect()
		ok(sr.size.y >= 47.5, "phone: small button %.0f high (>= 47.5)" % sr.size.y)
	else:
		ok(big._btn.custom_minimum_size == Ds.REC_BIG_PC, "PC: big button is Ds.REC_BIG_PC %s" % str(big._btn.custom_minimum_size))
		ok(small._btn.custom_minimum_size == Ds.REC_SMALL_PC, "PC: small button is Ds.REC_SMALL_PC %s" % str(small._btn.custom_minimum_size))
		ok(Ds.REC_BIG_PC == Vector2(190, 58) and Ds.REC_SMALL_PC == Vector2(96, 44), "PC: the tokens still are 190x58 and 96x44")
	# wide small widget (talk chat) on the phone: full width
	var wide := RecorderWidget.new(false, Pal.EN, false)
	wide.wide = true
	var host3 := _col()
	host3.add_child(wide)
	await _frames(3)
	if _phone:
		ok(wide._btn.get_global_rect().size.x > 300.0 and wide._btn.get_global_rect().size.y >= 56.0, "phone: wide small widget is a full-width 56 px button")
	# the level bar: OK fill on a SUNK track
	var fill: StyleBox = big._meter.get_theme_stylebox("fill")
	var track: StyleBox = big._meter.get_theme_stylebox("background")
	ok(fill is StyleBoxFlat and (fill as StyleBoxFlat).bg_color.is_equal_approx(Pal.OK), "level bar fill is OK")
	ok(track is StyleBoxFlat and (track as StyleBoxFlat).bg_color.is_equal_approx(Pal.SUNK), "level bar track is SUNK")
	for h in [host, host2, host3]:
		await _free(h)


# ---------------------------------------------------------------- ScorePanel (W6-2)

func _score_test() -> void:
	print("[score panel]")
	ok(ScorePanel.score_color(85.0).is_equal_approx(Pal.OK), "score 85 -> OK")
	ok(ScorePanel.score_color(65.0).is_equal_approx(Pal.WARN), "score 65 -> WARN")
	ok(ScorePanel.score_color(40.0).is_equal_approx(Pal.BAD), "score 40 -> BAD")
	ok(ScorePanel.score_color(80.0).is_equal_approx(Pal.OK) and ScorePanel.score_color(60.0).is_equal_approx(Pal.WARN), "thresholds 80 / 60 are kept")
	for case in [[85, Pal.OK, Pal.OK_ON], [65, Pal.WARN, Pal.WARN_ON], [40, Pal.BAD, Pal.BAD_ON]]:
		var host := _stage()
		var box := ScorePanel.build(_score_fixture(case[0]), "en")
		host.add_child(box)
		await _frames(2)
		var num := _label_with(box, str(case[0]))
		ok(num != null and num.theme_type_variation == &"Score" and num.get_theme_color("font_color").is_equal_approx(case[1]), "score %d: the big number has the score colour" % case[0])
		var verdict := _label_with(box, ScorePanel.verdict(float(case[0])))
		ok(verdict != null and verdict.get_theme_color("font_color").is_equal_approx(case[2]), "score %d: the verdict sentence uses the *_ON colour" % case[0])
		# three tiles: SUNK, INK number, MUTED caption
		var cap := _label_with(box, "정확도")
		ok(cap != null and cap.get_theme_color("font_color").is_equal_approx(Pal.MUTED), "score %d: tile caption is MUTED" % case[0])
		var tile: Control = cap.get_parent().get_parent() if cap != null else null
		var tsb: StyleBox = tile.get_theme_stylebox("panel") if tile != null else null
		ok(tsb is StyleBoxFlat and (tsb as StyleBoxFlat).bg_color.is_equal_approx(Pal.SUNK), "score %d: tile surface is SUNK, not the language tint" % case[0])
		var tnum := _label_with(box, "90")
		ok(tnum != null and tnum.get_theme_color("font_color").is_equal_approx(Pal.INK), "score %d: tile number is INK" % case[0])
		await _free(host)

	# word chips: shape cues
	var host := _stage()
	var box := ScorePanel.build(_score_fixture(70), "en")
	host.add_child(box)
	await _frames(2)
	var good := _chip(box, "good")
	var missed := _chip(box, "missed")
	var odd := _chip(box, "odd")
	var plain := _chip(box, "plain")
	ok(good != null and missed != null and odd != null and plain != null, "all four word chips exist")
	ok(_border(good) == 0 and _border(plain) == 0, "a word said well has no border (%d, %d)" % [_border(good), _border(plain)])
	ok(_border(missed) >= 2, "a missed word has a border >= 2 px (%d)" % _border(missed))
	ok(_border(odd) >= 1, "a word with one off sound has a 1 px border (%d)" % _border(odd))
	var mlab: Label = missed.get_child(0)
	var glab: Label = good.get_child(0)
	ok(mlab.get_theme_color("font_color").is_equal_approx(Pal.BAD_ON) and glab.get_theme_color("font_color").is_equal_approx(Pal.OK_ON), "chip texts use BAD_ON / OK_ON")
	ok(mlab.has_theme_font_override("font") and not glab.has_theme_font_override("font"), "a missed word is bold, a good one plain")
	var msb: StyleBoxFlat = missed.get_theme_stylebox("panel")
	var gsb: StyleBoxFlat = good.get_theme_stylebox("panel")
	ok(msb.bg_color.is_equal_approx(Pal.BAD_SOFT) and gsb.bg_color.is_equal_approx(Pal.OK_SOFT), "chip surfaces are BAD_SOFT / OK_SOFT")
	ok(msb.border_color.is_equal_approx(Pal.BAD), "the missed chip border is BAD")
	# the chip look function itself
	ok(ScorePanel.unit_look(false, false)["bw"] >= 2 and ScorePanel.unit_look(true, false)["bw"] == 0, "unit_look: missed >= 2, good 0")
	# selecting a chip with phonemes (tap it) outlines it thicker, a second tap restores
	var sel_before: int = _border(plain)
	var pc := plain as Control
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.global_position = pc.get_global_rect().get_center()
	pc.gui_input.emit(ev)
	if _phone:
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.pressed = false
		up.global_position = ev.global_position
		pc.gui_input.emit(up)
	await _frames(2)
	ok(sel_before == 0 and _border(plain) == ScorePanel.SELECTED_BW, "tapping a chip draws the thick selection outline (%d)" % _border(plain))
	await _free(host)

	# dark scheme: tokens follow
	Pal.use("dark")
	var host_d := _stage()
	var box_d := ScorePanel.build(_score_fixture(85), "en")
	host_d.add_child(box_d)
	await _frames(2)
	var vd := _label_with(box_d, ScorePanel.verdict(85.0))
	ok(vd != null and vd.get_theme_color("font_color").is_equal_approx(Pal.OK_ON), "dark: verdict uses the dark OK_ON")
	ok(_border(_chip(box_d, "good")) == 0 and _border(_chip(box_d, "missed")) >= 2, "dark: borders are the same (0 / >= 2)")
	ok((_chip(box_d, "missed").get_theme_stylebox("panel") as StyleBoxFlat).bg_color.is_equal_approx(Pal.BAD_SOFT), "dark: chip surface is the dark BAD_SOFT")
	await _free(host_d)
	Pal.use("light")

	# font scale 1.5: chip and tile text sizes follow
	Ds.set_font_scale(1.5)
	var box_f := ScorePanel.build(_score_fixture(70), "en")
	add_child(box_f)
	await _frames(2)
	var fl := _chip(box_f, "good").get_child(0) as Label
	ok(fl.get_theme_font_size("font_size") == Ds.fs(17) and Ds.fs(17) >= 25, "font scale 1.5: chip text is %d px" % fl.get_theme_font_size("font_size"))
	Ds.set_font_scale(1.0)
	await _free(box_f)


func _score_bad_input_test() -> void:
	print("[score panel, bad input]")
	var box := ScorePanel.build({}, "en")
	ok(box != null and box.get_child_count() >= 1, "empty result builds")
	box.free()
	var b2 := ScorePanel.build({"score": "abc", "units": "x", "tips_ko": 5, "accuracy": null}, "ja")
	ok(b2 != null, "wrong types build")
	b2.free()
	var b3 := ScorePanel.build({"score": 50, "units": [1, null, {"t": 5, "ok": 1, "ph": "no"}, {"ok": false}]}, "en")
	ok(b3 != null, "units with junk entries build")
	b3.free()
	var nan_color: Color = ScorePanel.score_color(NAN) # must not crash
	ok(nan_color.a == 1.0, "NaN score gives a colour")


# ---------------------------------------------------------------- MiniChart (W6-3, W6-4)

func _chart_test() -> void:
	print("[mini chart]")
	Pal.use("light")
	var col := Pal.EN
	var dim_l: Color = MiniChart.dim_color(col)
	ok(_lum(dim_l) > _lum(col), "light: the faded bar is lighter than the bar (%.2f > %.2f)" % [_lum(dim_l), _lum(col)])
	Pal.use("dark")
	col = Pal.EN
	var dim_d: Color = MiniChart.dim_color(col)
	ok(_lum(dim_d) < 0.5, "dark: the faded bar luminance %.2f < 0.5" % _lum(dim_d))
	ok(_lum(dim_d) < _lum(col), "dark: the faded bar is darker than the bar, not flashing to white")
	for c in [Pal.EN, Pal.JA, Pal.OK, Pal.WARN, Pal.BAD]:
		if _lum(MiniChart.dim_color(c)) >= 0.5:
			ok(false, "dark: faded %s stays under 0.5" % c.to_html())
	var chart := MiniChart.bars([1, 2, 3], ["a", "b", "c"], Pal.EN, 2, 2.0)
	ok(chart.highlight == 2, "bars() still takes the highlight index")
	chart.free()
	Pal.use("light")
	var base: int = MiniChart.font_size()
	var h0: float = MiniChart.bars([1], ["a"], Pal.EN).custom_minimum_size.y
	Ds.set_font_scale(1.5)
	var scaled: int = MiniChart.font_size()
	ok(base == 12 and absi(scaled - int(round(base * 1.5))) <= 1, "font scale 1.5: chart text %d -> %d (x1.5 +-1)" % [base, scaled])
	ok(MiniChart.guide_font_size() >= 16, "font scale 1.5: guide numbers %d" % MiniChart.guide_font_size())
	ok(MiniChart.pad_left() > MiniChart.PAD_LEFT, "font scale 1.5: the y-axis margin grows (%.0f)" % MiniChart.pad_left())
	var c2 := MiniChart.bars([1], ["a"], Pal.EN)
	ok(c2.custom_minimum_size.y > h0, "font scale 1.5: the chart is taller (%.0f > %.0f)" % [c2.custom_minimum_size.y, h0])
	c2.free()
	Ds.set_font_scale(0.9)
	ok(MiniChart.font_size() == 12, "font scale 0.9: never below 12")
	Ds.set_font_scale(1.0)


# ---------------------------------------------------------------- ProsodyPanel

func _prosody_test() -> void:
	print("[prosody panel]")
	var res: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_prosody_en_after.json"))
	var host := _stage(600.0, 500.0)
	var pp := ProsodyPanel.new("en")
	host.add_child(pp)
	pp.set_data(res if res is Dictionary else {})
	await _frames(3)
	ok(not pp.native.is_empty() and not pp.mine.is_empty(), "sample prosody loaded")
	ok(ProsodyPanel.native_color() == Pal.LINE_STRONG, "native curve colour is a token (LINE_STRONG)")
	Pal.use("dark")
	ok(ProsodyPanel.native_color() == Pal.LINE_STRONG and ProsodyPanel.native_color() != Color("#7C8596"), "dark: the native colour follows the scheme")
	pp.queue_redraw()
	await _frames(2)
	Pal.use("light")
	Ds.set_font_scale(1.5)
	ok(ProsodyPanel._f(14) == 21, "font scale 1.5: the legend text is 21 px")
	pp.queue_redraw()
	await _frames(2)
	Ds.set_font_scale(1.0)
	var ja: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_prosody_ja_after.json"))
	pp.lang = "ja"
	pp.set_data(ja if ja is Dictionary else {})
	await _frames(3)
	ok(not pp.accent.is_empty(), "japanese accent rows draw without errors (%d moras)" % pp.accent.size())
	await _free(host)


# ---------------------------------------------------------------- SpeakDrill shell (W6-5)

func _same_keys(d: Dictionary, want: Array) -> bool:
	var a: Array = d.keys()
	var b: Array = want.duplicate()
	a.sort()
	b.sort()
	return a == b


func _shell_test() -> void:
	print("[speak drill shell]")
	var owner_node := Control.new()
	add_child(owner_node)
	var shell: Dictionary = SpeakDrill.build_shell(owner_node, func() -> void: pass)
	ok(_same_keys(shell, SHELL_KEYS), "build_shell returns exactly the 8 keys %s" % str(shell.keys()))
	ok((shell["back"] as Button) != null and (shell["title"] as Label) != null and (shell["count"] as Label) != null, "back / title / count are nodes")
	ok((shell["head"] as Node).is_ancestor_of(shell["back"]) and (shell["head"] as Node).is_ancestor_of(shell["title"]), "back and title sit in head")
	var fh: PanelContainer = shell["footer_holder"]
	var sb: StyleBox = fh.get_theme_stylebox("panel")
	ok(sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.is_equal_approx(Pal.SURFACE) and (sb as StyleBoxFlat).border_width_top == 1, "footer bar is a SURFACE face with a top hairline")
	ok(not fh.visible, "footer bar starts hidden")
	var row := SpeakDrill.new_footer_row(shell)
	ok(fh.visible and row != null, "new_footer_row shows the bar")
	SpeakDrill.hide_footer(shell)
	ok(not fh.visible, "hide_footer hides it again")
	# touch sizes
	var b := Button.new()
	var holder := VBoxContainer.new()
	holder.add_child(b)
	SpeakDrill.fit_touch(holder)
	var want_h: float = maxf(SpeakDrill.TOUCH_H, Ds.touch_min() if _phone else 0.0)
	ok(b.custom_minimum_size.y >= want_h, "fit_touch default raises a button to %.0f (%.0f)" % [want_h, b.custom_minimum_size.y])
	SpeakDrill.fit_touch(holder, 60.0)
	ok(b.custom_minimum_size.y >= 60.0, "fit_touch with an explicit height")
	holder.free()
	var tb := SpeakDrill.touch_button("x", "primary", Pal.EN)
	ok(tb.custom_minimum_size.y >= SpeakDrill.TOUCH_H, "touch_button is at least TOUCH_H high")
	tb.free()
	var nt := SpeakDrill.notice("오류 문장")
	var nl := nt.get_child(0) as Label
	ok(nl.get_theme_color("font_color").is_equal_approx(Pal.BAD_ON), "notice text is BAD_ON")
	nt.free()
	owner_node.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- hub (§7.5)

func _hub_test() -> void:
	print("[practice hub]")
	Store.prefs["lang"] = "en"
	var host := _stage(412.0 if _phone else 1100.0, 800.0)
	var v := PracticeView.new()
	host.add_child(v)
	v.size = host.size
	await _frames(4)
	ok(v.card_kinds() == ["mission", "shadow", "dictation", "phoneme", "kana"], "hub cards in order: %s" % str(v.card_kinds()))
	for k in v.card_kinds():
		ok(PracticeView.KINDS.has(k), "card kind %s is in KINDS" % k)
		ok(v._make_screen(k) != null, "_make_screen(%s) builds a screen" % k)
	for k in PracticeView.KINDS:
		ok(v.card_kinds().has(k), "KINDS entry %s has a card" % k)
	ok(v._make_screen("nope") == null, "_make_screen of an unknown kind is null")
	v.open_screen("nope")
	ok(v.current_screen() == null, "open_screen of an unknown kind does nothing")
	var all_on := true
	for k in v.card_kinds():
		if k != "kana" and (v._cards[k] as Button).disabled:
			all_on = false
	ok(all_on, "english: every start button except kana is enabled")
	ok((v._cards["kana"] as Button).disabled, "english: the kana card is off (Japanese only)")
	ok((v._cards["mission"] as Button).get_global_rect().size.y >= (47.5 if _phone else 40.0), "start button height %.0f" % (v._cards["mission"] as Button).get_global_rect().size.y)
	ok(v.header_block() != null and v.scroll_host() != null, "hub gives the app bar its header block and scroll host")
	ok(v.page_title() == "", "hub has no page title of its own (main uses the tab name)")
	var dict_desc_en := _label_with(v, "문장을 듣고 직접 타자로 써요. 단어마다 맞고 틀린 것을 알려 줘요.")
	ok(dict_desc_en != null, "english: dictation description is the normal one")
	# japanese: dictation and weak sounds are off with their own text
	Store.prefs["lang"] = "ja"
	v.refresh()
	await _frames(3)
	ok((v._cards["dictation"] as Button).disabled and (v._cards["phoneme"] as Button).disabled, "japanese: dictation and weak sounds are disabled")
	ok(not (v._cards["mission"] as Button).disabled and not (v._cards["shadow"] as Button).disabled, "japanese: mission and shadowing stay enabled")
	ok(_label_with(v, "받아쓰기는 영어만 지원해요.") != null and _label_with(v, "약한 소리 연습은 영어만 지원해요.") != null, "japanese: the 'english only' texts show")
	ok(not (v._cards["kana"] as Button).disabled, "japanese: the kana card is enabled")
	v.open_screen("kana")
	ok(v.current_screen() is KanaScreen, "japanese: the kana card opens KanaScreen")
	v.go_back()
	ok(v.current_screen() == null, "japanese: back from the kana screen returns to the hub")
	# a sub screen: title / subtitle contract and back
	Store.prefs["lang"] = "en"
	v.refresh()
	await _frames(3)
	v.open_screen("dictation")
	await _frames(3)
	ok(v.current_screen() != null and v.header_block() == null and v.scroll_host() == null, "sub screen open: hub header and scroll host are not offered")
	ok(v.page_title() == "받아쓰기", "sub screen title for the bar (%s)" % v.page_title())
	ok(v.go_back(), "go_back closes the sub screen")
	await _frames(3)
	ok(v.current_screen() == null and v.card_kinds().size() == 5, "back at the hub with its cards")
	# the widget test of the phone: touch targets on the hub
	if _phone:
		var small := 0
		for b in v.find_children("*", "Button", true, false):
			if (b as Button).is_visible_in_tree() and (b as Button).get_global_rect().size.y < 47.5:
				small += 1
		ok(small == 0, "phone: no hub button under 47.5 px (%d)" % small)
	await _free(host)


# ---------------------------------------------------------------- source rules (W6-4)

func _source_test() -> void:
	print("[source rules]")
	var bad_lit := RegEx.new()
	bad_lit.compile("add_theme_font_size_override\\(\"font_size\",\\s*\\d+\\)")
	var bad_draw := RegEx.new() # draw_string(..., <literal size>, colour)
	bad_draw.compile("draw_string\\(.*,\\s*\\d+\\s*,\\s*[A-Za-z_.()]+\\)\\s*$")
	var bad_draw2 := RegEx.new() # draw_string(..., FONT_SIZE or FONT_SIZE - 1 ...)
	bad_draw2.compile("draw_string\\(.*FONT_SIZE")
	var hex := RegEx.new()
	hex.compile("Color\\(\"#")
	for path in SRC:
		var text: String = FileAccess.get_file_as_string(path)
		ok(text != "", "%s is readable" % path.get_file())
		ok(bad_lit.search(text) == null, "%s: no literal add_theme_font_size_override" % path.get_file())
		var draw_bad := 0
		for line in text.split("\n"):
			if bad_draw.search(line) != null or bad_draw2.search(line) != null:
				draw_bad += 1
		ok(draw_bad == 0, "%s: no draw_string with a literal text size (%d)" % [path.get_file(), draw_bad])
		ok(hex.search(text) == null, "%s: no Color(\"#...\") literal" % path.get_file())
	var chart: String = FileAccess.get_file_as_string("res://scripts/ui/mini_chart.gd")
	ok(not chart.contains("Color.WHITE") and not chart.contains("Color(1, 1, 1"), "mini_chart.gd: no white")
	var pros: String = FileAccess.get_file_as_string("res://scripts/ui/prosody_panel.gd")
	ok(not pros.contains("Color(1, 1, 1"), "prosody_panel.gd: no hard-coded white")


# ---------------------------------------------------------------- the checkers must be able to fail

func _checker_self_test() -> void:
	print("[checker self test]")
	var good := {}
	for k in SHELL_KEYS:
		good[k] = 1
	var missing := good.duplicate()
	missing.erase("footer_col")
	var extra := good.duplicate()
	extra["more"] = 1
	ok(_same_keys(good, SHELL_KEYS) and not _same_keys(missing, SHELL_KEYS) and not _same_keys(extra, SHELL_KEYS), "selfcheck FAIL-as-expected: key comparison rejects a missing and an extra key")
	var rx := RegEx.new()
	rx.compile("add_theme_font_size_override\\(\"font_size\",\\s*\\d+\\)")
	ok(rx.search("x.add_theme_font_size_override(\"font_size\", 17)") != null and rx.search("x.add_theme_font_size_override(\"font_size\", UI.fs(17))") == null, "selfcheck FAIL-as-expected: the literal-size scan sees 17 and passes UI.fs(17)")
	var rd := RegEx.new()
	rd.compile("draw_string\\(.*,\\s*\\d+\\s*,\\s*[A-Za-z_.()]+\\)\\s*$")
	ok(rd.search("draw_string(f, Vector2(0, 0), \"a\", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Pal.MUTED)") != null and rd.search("draw_string(f, Vector2(0, 0), \"a\", HORIZONTAL_ALIGNMENT_LEFT, -1, _f(13), Pal.MUTED)") == null, "selfcheck FAIL-as-expected: the draw_string scan sees 13 and passes _f(13)")
	# the old formula (mix towards white) must fail the dark rule
	Pal.use("dark")
	var old_dim: Color = Pal.EN.lerp(Color.WHITE, 0.45)
	ok(_lum(old_dim) >= 0.5 and _lum(MiniChart.dim_color(Pal.EN)) < 0.5, "selfcheck FAIL-as-expected: the old white-mixed bar (%.2f) breaks the 0.5 limit, the new one (%.2f) does not" % [_lum(old_dim), _lum(MiniChart.dim_color(Pal.EN))])
	Pal.use("light")
	# a flat chip must fail the border rule
	var flat := PanelContainer.new()
	flat.add_theme_stylebox_override("panel", UI.style(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 99, 10, 2))
	ok(_border(flat) < 2, "selfcheck FAIL-as-expected: a chip without a border is under 2 px")
	flat.free()


# ---------------------------------------------------------------- screenshot mode

const SENT_EN := "res://tests/sample_practice_sentences_en.json"
const PH_LIST := "res://tests/sample_phoneme_list.json"
const PH_TH := "res://tests/sample_phoneme_th.json"
const PROSODY_AFTER := "res://tests/sample_prosody_en_after.json"
const PROSODY_JA := "res://tests/sample_prosody_ja_after.json"
const SHOT_PROGRESS := "user://test_ui_practice_progress.json"
const SHOT_LOG := "user://test_ui_practice_studylog.json"

var _shot_dir: String = ""
var _shot_prefix: String = "pc"
var _shot_n: int = 0
var _shot_bg: ColorRect = null


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _shot_hook(_method: String, path: String, _body: Variant) -> Variant:
	var data: Variant = {}
	if path.begins_with("/practice/ping"):
		data = {"ok": true, "practice": 1, "missions": 1, "tatoeba": true}
	elif path.begins_with("/practice/sentences"):
		data = _json(SENT_EN)
	elif path.begins_with("/practice/phonemes"):
		data = _json(PH_LIST)
	elif path.begins_with("/practice/phoneme"):
		data = _json(PH_TH)
	elif path.begins_with("/score"):
		data = _score_fixture(72)
	elif path.begins_with("/prosody"):
		data = _json(PROSODY_AFTER)
	else:
		return {"ok": false, "code": 404, "data": null, "error": "no route"}
	return {"ok": true, "code": 200, "data": data, "error": ""}


func _snap(state: String) -> void:
	await _frames(12)
	await _frames(3)
	_shot_n += 1
	var img: Image = get_viewport().get_texture().get_image()
	var fname := "%s_%02d_%s.png" % [_shot_prefix, _shot_n, state]
	img.save_png(_shot_dir.path_join(fname))
	print("saved ", fname, " ", img.get_size())


## A full-screen holder over the background; the caller fills it and frees it.
func _holder() -> Control:
	var h := Control.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(h)
	return h


func _page_holder(max_w: float = 720.0) -> Array:
	var h := _holder()
	var pg := PageScroll.new(max_w)
	pg.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_child(pg)
	return [h, pg]


func _wait_stage(sc: Control, want: String) -> void:
	for i in 120:
		if str(sc.get("stage")) == want:
			return
		await get_tree().process_frame


func _shots_main(dir: String) -> void:
	var dark: bool = OS.get_cmdline_user_args().has("--dark")
	_shot_dir = dir
	DirAccess.make_dir_recursive_absolute(dir if dir.is_absolute_path() else ProjectSettings.globalize_path(dir))
	_phone = Platform.is_phone()
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	UiBoot.apply(get_tree().root, "dark" if dark else "light", 1.0)
	_shot_prefix = ("phone" if _phone else "pc") + ("_dark" if dark else "")
	_old_prefs = Store.prefs_path
	Store.prefs_path = PREFS
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	var old_progress: String = Store.progress_path
	var old_log: String = StudyLog.path
	Store.progress_path = SHOT_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = SHOT_LOG
	StudyLog.reset()
	var old_base: String = Api.base_url
	Api.base_url = "http://127.0.0.1:9" # a closed port: nothing can reach a real server
	SpeakDrill.api_hook = Callable(self, "_shot_hook")
	Tts.fetch_hook = func(_t: String, _l: String, _s: float, _v: String) -> Variant: return null
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	await _frames(3)
	_shot_bg = ColorRect.new()
	_shot_bg.color = Pal.BG
	_shot_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_shot_bg)
	print("shots dir=%s prefix=%s dark=%s size=%s" % [dir, _shot_prefix, str(dark), str(get_window().size)])

	# the real hub (english, then japanese)
	var v := PracticeView.new()
	add_child(v)
	v.refresh()
	await _snap("hub_en")
	Store.prefs["lang"] = "ja"
	v.refresh()
	await _snap("hub_ja")
	Store.prefs["lang"] = "en"
	v.queue_free()
	await _frames(2)

	# the recorder in its three states
	var pgh := _page_holder()
	var card := UI.card("Card", 14)
	(pgh[1] as PageScroll).content.add_child(card)
	card.body.add_child(UI.label("녹음 버튼 · 대기", "Eyebrow", false))
	var r_idle := RecorderWidget.new(true, Pal.EN, false)
	card.body.add_child(r_idle)
	card.body.add_child(UI.label("녹음 버튼 · 녹음 중", "Eyebrow", false))
	var r_rec := RecorderWidget.new(true, Pal.EN, false)
	card.body.add_child(r_rec)
	card.body.add_child(UI.label("녹음 버튼 · 처리 중", "Eyebrow", false))
	var r_busy := RecorderWidget.new(true, Pal.EN, false)
	card.body.add_child(r_busy)
	var small_row := UI.hbox(10)
	for i in 2:
		var sm := RecorderWidget.new(false, Pal.JA, false)
		sm.idle_text = "말하기"
		small_row.add_child(sm)
		if i == 1:
			sm.set_enabled(false)
	card.body.add_child(small_row)
	await _frames(3)
	r_busy.set_enabled(false)
	Recorder.recording = true # simulated: the recorder autoload is not opened
	Recorder.owner_id = r_rec.get_instance_id()
	Recorder.elapsed = 3.0
	Recorder.level = 0.55
	await _snap("recorder_states")
	Recorder.recording = false
	Recorder.owner_id = 0
	Recorder.elapsed = 0.0
	Recorder.level = 0.0
	await _frames(2)
	(pgh[0] as Node).queue_free()
	await _frames(2)

	# score panels
	for sc in [85, 65, 40]:
		var ph := _page_holder()
		var c := UI.card("Card", 12)
		(ph[1] as PageScroll).content.add_child(c)
		c.body.add_child(ScorePanel.build(_score_fixture(sc), "en"))
		await _snap("score_%d" % sc)
		(ph[0] as Node).queue_free()
		await _frames(2)

	# prosody graph (english) and japanese accent rows, two charts
	var pp := _page_holder()
	var cd := UI.card("Card", 12)
	(pp[1] as PageScroll).content.add_child(cd)
	var pe := ProsodyPanel.new("en")
	pe.set_data(_json(PROSODY_AFTER) as Dictionary)
	cd.body.add_child(pe)
	var pj := ProsodyPanel.new("ja")
	pj.set_data(_json(PROSODY_JA) as Dictionary)
	cd.body.add_child(pj)
	var ch := MiniChart.bars([12, 0, 30, 18, 25, 40, 22], ["월", "화", "수", "목", "금", "토", "일"], Pal.EN, 6, 20.0)
	cd.body.add_child(ch)
	var cl := MiniChart.line([60, null, 72, 80, 78, 91, 88], ["", "", "", "", "", "", ""], Pal.OK, 100.0)
	cd.body.add_child(cl)
	await _snap("prosody_chart")
	(pp[0] as Node).queue_free()
	await _frames(2)

	# the real sub screens
	var v2 := PracticeView.new()
	add_child(v2)
	v2.refresh()
	await _frames(3)
	v2.open_screen("shadow", {"source": "week"})
	var sh: Control = v2.current_screen()
	await _wait_stage(sh, "run")
	await _snap("shadow_run")
	var drill: Variant = sh.get("drill")
	if drill != null:
		(drill as SpeakDrill).apply_score(_score_fixture(72))
		await _frames(6)
		await _snap("shadow_scored")
	v2.go_back()
	await _frames(3)
	v2.open_screen("dictation")
	await _wait_stage(v2.current_screen(), "run")
	await _snap("dictation_run")
	v2.go_back()
	await _frames(3)
	v2.open_screen("phoneme", {"p": "θ"})
	var ps: Control = v2.current_screen()
	await _wait_stage(ps, "detail")
	await _snap("phoneme_detail")
	ps.call("start_drill")
	await _frames(6)
	await _snap("phoneme_drill")
	v2.queue_free()
	await _frames(2)

	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	Api.base_url = old_base
	StudyLog.reset()
	StudyLog.path = old_log
	Store.progress_path = old_progress
	for f in [SHOT_PROGRESS, SHOT_LOG, SHOT_LOG + ".bad", PREFS]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.prefs_path = _old_prefs
	print("shots done: %d images" % _shot_n)
	get_tree().quit()
