extends Node
## Screenshots of the speak exercise with intonation graph / accent / phoneme row, using a REAL backend:
##   godot --path <project> res://tests/shots_feat.tscn -- <out dir> <width> <height> --api=http://127.0.0.1:8781
## (needs a real renderer: do NOT pass --headless)

var out_dir: String = ""
var main_node: Control
var lv: LessonView


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[0] if args.size() > 0 else "user://shots_feat"
	if args.size() >= 3 and not args[1].begins_with("--"):
		get_window().size = Vector2i(int(args[1]), int(args[2]))
	DirAccess.make_dir_recursive_absolute(out_dir)
	Store.progress_path = "user://shots_feat_progress.json"
	Store.progress = Progress.blank()
	Store.set_pref("hide_prosody", false)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main_node = scene.instantiate()
	add_child(main_node)
	await _frames(30)
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "llm_model": "qwen3:8b", "score": true, "phoneme": true}
	Backend._set_status(Backend.Status.READY)
	await get_tree().create_timer(1.0).timeout
	main_node.show_view("lesson")
	lv = main_node.views["lesson"]
	var sfx: String = "_%d" % get_window().size.x
	await _case("en", "Thank you very much.", "", "Thank you very much.", "en_ok" + sfx)
	await _case("en", "Thank you very much.", "", "Sank you very much.", "en_th" + sfx)
	await _case("ja", "おばあさんが来ました。", "おばあさんがきました。", "おばさんが来ました。", "ja_long" + sfx)
	await _case("ja", "毎朝七時に起きます。", "まいあさしちじにおきます。", "毎朝七時に起きます。", "ja_ok" + sfx)
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(8)
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name, " ", img.get_size())


func _wait(cond: Callable, sec: float = 20.0) -> bool:
	var t := 0.0
	while t < sec:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _case(lang: String, text: String, reading: String, say: String, name: String) -> void:
	lv.lang = lang
	Store.set_pref("lang", lang)
	lv.title = "테스트"
	lv.load_exercises([{"type": "speak", "text": text, "reading": reading, "ko": "따라 말해 보세요."}])
	lv._render()
	await _wait(func() -> bool: return not lv.prosody_native.is_empty())
	await _frames(4)
	lv._page.scroll_vertical = 0
	await _shot(name + "_1_before")
	# the "learner": backend TTS of `say`
	var call = Api.post_json("/tts", {"text": say, "lang": lang, "speed": 0.9}, 60.0, false)
	var r: Dictionary = await call.wait()
	var b64: String = Marshalls.raw_to_base64(r["bytes"])
	lv._on_recorded({"b64": b64, "duration": 2.0})
	await _wait(func() -> bool: return not lv.speak_result.is_empty() and lv.prosody.get("mine", null) != null)
	await _frames(10)
	lv._page.scroll_vertical = 0
	await _shot(name + "_2_after_top")
	lv._page.scroll_vertical = 400
	await _shot(name + "_3_after_mid")
	lv._page.scroll_vertical = 5000
	await _shot(name + "_4_after_bottom")
