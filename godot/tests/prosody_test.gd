extends Node
## Headless test of ProsodyPanel / ScorePanel phoneme rendering from sample JSON:
##   godot --headless --path <project> res://tests/prosody_test.tscn

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _load(name: String) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/" + name))
	return d if d is Dictionary else {}


func _find_all(n: Node, cls: String, out: Array) -> void:
	for c in n.get_children():
		if c.get_class() == cls or (c.get_script() != null and str(c.get_script().get_global_name()) == cls):
			out.append(c)
		_find_all(c, cls, out)


func _ready() -> void:
	print("== prosody test start ==")
	await _test_panel("en", "sample_prosody_en_before.json", "sample_prosody_en_after.json")
	await _test_panel("ja", "sample_prosody_ja_before.json", "sample_prosody_ja_after.json")
	await _test_score("sample_score_en_ph.json", "en")
	await _test_score("sample_score_ja_ph.json", "ja")
	await _test_score_old()
	print("== prosody result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _test_panel(lang: String, before: String, after: String) -> void:
	print("[prosody panel %s]" % lang)
	var b: Dictionary = _load(before)
	var a: Dictionary = _load(after)
	ok(not b.is_empty() and not a.is_empty(), "sample JSON loaded")
	var host := Control.new()
	host.size = Vector2(700, 800)
	add_child(host)
	var pp := ProsodyPanel.new(lang)
	host.add_child(pp)
	pp.set_message("loading")
	await get_tree().process_frame
	ok(pp.native.is_empty(), "message state has no native curve")
	pp.set_data(b)
	await get_tree().process_frame
	ok(not pp.native.is_empty() and pp.mine.is_empty(), "before: native curve only")
	ok(pp.similarity == null, "before: no similarity")
	var h_before: float = pp.get_combined_minimum_size().y
	ok(h_before > 100.0, "before: min height %.0f" % h_before)
	if lang == "ja":
		ok(pp.accent.size() > 5 and pp.mine_accent.is_empty(), "before: accent moras %d, no learner row" % pp.accent.size())
	else:
		ok(pp.accent.is_empty(), "en: no accent rows")
	pp.set_data(a)
	await get_tree().process_frame
	ok(not pp.mine.is_empty() and pp.similarity != null, "after: mine curve + similarity %s" % str(pp.similarity))
	ok((pp.mine["t"] as Array).size() == (pp.native["t"] as Array).size(), "mine is on the native time grid")
	if lang == "ja":
		ok(pp.mine_accent.size() == pp.accent.size(), "after: learner high/low per mora")
		ok(pp.get_combined_minimum_size().y > h_before, "learner row adds height")
	# width robustness 600..900
	for w in [600.0, 760.0, 900.0]:
		host.size.x = w
		pp.size.x = w
		await get_tree().process_frame
		var mh: float = pp.get_combined_minimum_size().y
		ok(mh > 100.0 and mh < 900.0, "width %d -> min height %.0f" % [int(w), mh])
	pp.clear_mine()
	ok(pp.mine.is_empty() and pp.mine_accent.is_empty() and not pp.native.is_empty(), "clear_mine keeps native")
	# bad data must not crash
	pp.set_data({"native": {"t": [0.0], "f0": [1.0]}, "mine": "x", "accent": null})
	pp.set_data({})
	await get_tree().process_frame
	ok(true, "malformed data tolerated")
	host.queue_free()


func _test_score(name: String, lang: String) -> void:
	print("[score panel %s]" % lang)
	var res: Dictionary = _load(name)
	ok(not res.is_empty(), "sample score loaded")
	var box: VBoxContainer = ScorePanel.build(res, lang)
	add_child(box)
	await get_tree().process_frame
	var any_ph := false
	for u in res["units"]:
		if not ScorePanel.phonemes_of(u).is_empty():
			any_ph = true
	ok(any_ph, "units carry ph")
	# a problem unit is opened automatically -> ph chips (PanelContainers with IPA labels) exist
	var labels: Array = []
	_find_all(box, "Label", labels)
	var ipa_labels := 0
	var miss_sym := ""
	for u in res["units"]:
		for p in ScorePanel.phonemes_of(u):
			if not bool(p["ok"]) and miss_sym == "":
				miss_sym = str(p["p"])
	for l in labels:
		if (l as Label).get_theme_font("font") == Ipa.font(true):
			ipa_labels += 1
	ok(ipa_labels >= 1, "first problem unit expanded: %d IPA labels" % ipa_labels)
	ok(miss_sym != "", "has a missed phoneme (%s)" % miss_sym)
	# click another chip -> detail changes
	var chips: Array = []
	_find_all(box, "PanelContainer", chips)
	var clickable: Array = []
	for c in chips:
		if (c as Control).mouse_filter == Control.MOUSE_FILTER_STOP and (c as Control).tooltip_text.contains("발음기호"):
			clickable.append(c)
	ok(clickable.size() >= 3, "clickable unit chips: %d" % clickable.size())
	if clickable.size() >= 2:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		(clickable[1] as Control).gui_input.emit(ev)
		await get_tree().process_frame
		var l2: Array = []
		_find_all(box, "Label", l2)
		var n2 := 0
		for l in l2:
			if (l as Label).get_theme_font("font") == Ipa.font(true):
				n2 += 1
		ok(n2 >= 1, "clicking a chip shows its phonemes (%d IPA labels)" % n2)
		(clickable[1] as Control).gui_input.emit(ev)
		await get_tree().process_frame
		var l3: Array = []
		_find_all(box, "Label", l3)
		var n3 := 0
		for l in l3:
			if (l as Label).get_theme_font("font") == Ipa.font(true):
				n3 += 1
		ok(n3 == 0, "second click collapses the row")
	var tips: Array = res.get("tips_ko", [])
	ok(tips.size() >= 1 and tips.size() <= 3, "tips_ko 1..3 (%d)" % tips.size())
	box.queue_free()


func _test_score_old() -> void:
	print("[score panel without ph (old server)]")
	var res: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_score.json"))
	var box: VBoxContainer = ScorePanel.build(res, "en")
	add_child(box)
	await get_tree().process_frame
	ok(box.get_child_count() >= 4, "builds as before")
	box.queue_free()
