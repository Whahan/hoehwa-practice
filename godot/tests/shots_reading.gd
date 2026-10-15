extends Node
## Screenshots of the 읽기 tab from fixture data (no backend needed):
##   godot --path <project> res://tests/shots_reading.tscn -- <out dir> [width height]
## With a real backend (analyze -> background glosses -> examples):
##   ... -- <out dir> 1280 800 --live --api=http://127.0.0.1:8786
## (needs a real renderer: do NOT pass --headless)

const DIR := "user://shots_reading"

var out_dir: String = ""
var main_node: Control
var rv: ReadingView


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[0] if args.size() > 0 else "user://shots_reading_png"
	if args.size() >= 3 and not args[1].begins_with("--"):
		get_window().size = Vector2i(int(args[1]), int(args[2]))
	DirAccess.make_dir_recursive_absolute(out_dir)
	_wipe()
	Store.progress_path = "user://shots_reading_progress.json"
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en" # not saved: keeps the real prefs file untouched
	Store.prefs.erase("reading_font")
	# never launch or poll the real engine from a screenshot run
	Backend._starting = true
	Backend.set_process(false)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main_node = scene.instantiate()
	add_child(main_node)
	await _frames(20)
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "llm_model": "qwen3:8b", "score": true, "phoneme": true, "tatoeba": true}
	Backend._set_status(Backend.Status.READY)
	rv = main_node.views["reading"]
	rv.storage_dir = DIR
	rv.auto_fetch = false
	rv.glosses.clear()
	main_node.show_view("reading")
	var sfx: String = "_%d" % get_window().size.x
	if "--live" in args:
		rv.auto_fetch = true
		await _run_live(sfx)
	else:
		await _run(sfx)
	_wipe()
	get_tree().quit()


func _wipe() -> void:
	for d in [DIR.path_join("cache"), DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
	if FileAccess.file_exists("user://shots_reading_progress.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://shots_reading_progress.json"))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	main_node._toast_box.visible = false
	await _frames(8)
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name, " ", img.get_size())


static func fixture(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string("res://tests/" + name))


func _tok(surface: String) -> int:
	for i in rv.tokens.size():
		if str((rv.tokens[i] as Dictionary)["t"]) == surface:
			return i
	return -1


func _run(sfx: String) -> void:
	# library: two saved texts + the sample draft
	var d1: Dictionary = rv.new_doc("BBC — City foxes", "en", "Urban foxes have adapted remarkably well to city life, scavenging from bins and sleeping under garden sheds.")
	d1["opened"] -= 86400 * 3
	rv.save_doc(d1)
	var d2: Dictionary = rv.new_doc("", "en", "The committee postponed its decision until further evidence could be gathered from the regional offices.")
	d2["opened"] -= 86400
	rv.save_doc(d2)
	rv.mode = "library"
	rv.lang = "en"
	var s: Dictionary = ReadingView.SAMPLES["en"]
	rv._draft_title = str(s["title"])
	rv._draft_text = str(s["text"])
	rv._render()
	await _shot("r1_library" + sfx)

	# English reader with colored words (one word in review, one known)
	var data: Dictionary = fixture("sample_reading_analyze.json")
	var text: String = ""
	for t in data["tokens"]:
		text += str(t["t"])
	var d: Dictionary = rv.new_doc("Running in the Rain", "en", text)
	rv.save_doc(d)
	rv.open_doc(d)
	rv.set_analysis(data)
	rv.apply_glosses(fixture("sample_reading_gloss.json"))
	rv.select_token(_tok("grey"))
	rv.add_selected_to_review()
	rv.select_token(_tok("rhythm"))
	rv.mark_selected_known()
	rv.close_panel()
	rv.gloss_total = 12
	rv.gloss_done = 4
	rv._update_gloss_label()
	await _shot("r2_reader_en" + sfx)
	rv.gloss_total = 0
	rv._update_gloss_label()

	# word panel with examples
	rv.select_token(_tok("reckless"))
	rv.set_examples("reckless", {"examples": [
		{"id": 1, "text": "It was reckless of him to drive so fast.", "ko": "그렇게 빨리 운전하다니 그는 무모했다.", "en": "", "ja": "", "url": ""},
		{"id": 2, "text": "Don't be reckless [with money].", "ko": "", "en": "", "ja": "お金に関して無謀なことをするな。", "url": ""},
		{"id": 3, "text": "The reckless driver was arrested.", "ko": "그 난폭한 운전자는 체포되었다.", "en": "", "ja": "", "url": ""},
	], "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"})
	await _shot("r3_word_panel_en" + sfx)
	rv._panel_scroll.scroll_vertical = 100000
	await _shot("r3b_word_panel_examples" + sfx)
	rv.select_token(_tok("Running"))
	rv.set_examples("run", fixture("sample_examples.json"))
	await _shot("r4_word_panel_easy_no_gloss" + sfx)

	# Japanese reader
	var jd: Dictionary = fixture("sample_reading_analyze_ja.json")
	var jt: String = ""
	for t in jd["tokens"]:
		jt += str(t["t"])
	var dj: Dictionary = rv.new_doc("朝の日記", "ja", jt)
	rv.save_doc(dj)
	rv.open_doc(dj)
	rv.set_analysis(jd)
	rv.apply_glosses(fixture("sample_reading_gloss_ja.json"))
	rv.select_token(_tok("傘"))
	rv.add_selected_to_review()
	rv.select_token(_tok("食べ"))
	rv.set_examples("食べる", {"examples": [
		{"id": 10, "text": "朝ごはんを食べましたか。", "ko": "아침 먹었어요?", "en": "", "ja": "", "url": ""},
		{"id": 11, "text": "私は毎日パンを食べます。", "ko": "", "en": "I eat bread every day.", "ja": "", "url": ""},
	], "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"})
	await _shot("r5_reader_ja" + sfx)
	Store.prefs["reading_font"] = "l"
	rv._render_header()
	rv._render_text()
	await _shot("r6_reader_ja_large" + sfx)
	Store.prefs.erase("reading_font")
	# long Japanese paragraph without spaces: checks that lines wrap inside the text
	var long_toks: Array = []
	for r in 5:
		for t in jd["tokens"]:
			if str(t["t"]) != "
":
				long_toks.append((t as Dictionary).duplicate())
	var lt: String = ""
	for t in long_toks:
		lt += str(t["t"])
	var dl: Dictionary = rv.new_doc("長い段落", "ja", lt)
	rv.save_doc(dl)
	rv.open_doc(dl)
	rv.set_analysis({"tokens": long_toks, "sentences": jd["sentences"], "words": jd["words"]})
	await _shot("r7_reader_ja_wrap" + sfx)


func _wait(cond: Callable, sec: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()


func _run_live(sfx: String) -> void:
	rv.mode = "library"
	rv.lang = "en"
	var s: Dictionary = ReadingView.SAMPLES["en"]
	rv._draft_title = str(s["title"])
	rv._draft_text = str(s["text"])
	rv._render()
	await _frames(2)
	rv.analyze_draft()
	await _shot("L1_analyzing" + sfx)
	var got: bool = await _wait(func() -> bool: return not rv.analyzing, 60.0)
	print("analysis done: ", got, " tokens=", rv.tokens.size(), " error=", rv.analyze_error)
	await _shot("L2_reader_glossing" + sfx)
	got = await _wait(func() -> bool: return rv.gloss_total == 0, 240.0)
	print("glosses done: ", got, " cached=", rv._cur_glosses().size())
	var pick := -1
	for i in rv.tokens.size():
		var w: Dictionary = rv.word_at(i)
		if not w.is_empty() and rv.word_status(w["key"]) == "new" and not rv.gloss_for(w["key"]).is_empty():
			pick = i
			break
	if pick < 0:
		print("no glossed new word to click")
		return
	rv.select_token(pick)
	var key: String = rv.selected_word()["key"]
	got = await _wait(func() -> bool: return rv.examples.has("en|" + key), 30.0)
	print("examples for ", key, ": ", got)
	await _shot("L3_word_live" + sfx)
	rv._panel_scroll.scroll_vertical = 100000
	await _shot("L4_word_live_examples" + sfx)
