extends Node
## Visual check: renders the main scene in several states and saves PNGs.
##   godot --path <project> res://tests/shots.tscn -- <output dir> [width height]
## (needs a real renderer, so do NOT pass --headless)

var out_dir: String = ""
var main_node: Control


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[0] if args.size() > 0 else "user://shots"
	if args.size() >= 3:
		get_window().size = Vector2i(int(args[1]), int(args[2]))
	DirAccess.make_dir_recursive_absolute(out_dir)
	Store.progress_path = "user://shots_progress.json"
	Store.progress = Progress.blank()
	Store.add_review([
		{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": "Can I ~?"},
		{"lang": "ja", "target": "毎朝七時に起きます。", "reading": "まいあさしちじにおきます。", "ko": "매일 아침 7시에 일어나요.", "note": "시간 + に"},
	])
	Store.progress["xp"]["en"] = 120
	Store.progress["days"][Plan.days_to_iso(Plan.today_days())] = {"en": true}
	Store.progress["days"][Plan.days_to_iso(Plan.today_days() - 1)] = {"en": true}
	Store.progress["checks"]["en-1-w0"] = true
	Store.progress["checks"]["en-1-m0"] = true
	var scene: PackedScene = load("res://scenes/main.tscn")
	main_node = scene.instantiate()
	add_child(main_node)
	await _frames(40)
	# Splash / failure / banner states, forced (the real backend may or may not be running).
	main_node._splash_dismissed = false
	Backend._set_status(Backend.Status.STARTING, "AI 엔진 준비 중… (12초)")
	await _shot("00a_splash_starting")
	Backend._set_status(Backend.Status.FAILED, "파이썬 환경이 아직 없어요. backend 폴더의 setup.ps1을 먼저 실행해 주세요.")
	await _shot("00b_splash_failed")
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": false, "llm_model": "qwen3:8b", "score": true}
	Backend._set_status(Backend.Status.READY)
	Toast.error("AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요.")
	await _shot("00c_banner_llm_toast")
	# back to a healthy state so the remaining shots show the app as it normally looks
	Backend.health["llm"] = true
	Backend._set_status(Backend.Status.READY)
	await get_tree().create_timer(6.0).timeout
	await _run()
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(6)
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name, " ", img.get_size())


func _run() -> void:
	var views: Dictionary = main_node.views
	main_node.show_view("today")
	await _shot("01_today")
	# the settings are a screen of their own (SettingsView), not a part of 오늘
	main_node.show_view("settings")
	await _frames(6)
	await _shot("02_settings")
	(views["settings"] as SettingsView).scroll_host().scroll_vertical = 5000
	await _shot("02b_settings_bottom")

	main_node.show_view("lesson")
	await _shot("03_lesson_home")
	var lv: LessonView = views["lesson"]
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_lesson.json"))
	lv.title = "카페에서 주문하기"
	lv.load_exercises(LessonView._parse_lesson(data))
	lv._render()
	await _shot("04_lesson_choice")
	lv.picked = 1
	lv._render()
	lv.check_answer()
	await _shot("05_lesson_choice_checked")
	lv.next_exercise()
	lv.next_exercise()  # skip fill -> build
	await _shot("06_lesson_build_empty")
	var e: Dictionary = lv.cur()
	lv.built = [e["tiles"][0]["i"], e["tiles"][1]["i"]]
	lv._render()
	await _shot("07_lesson_build_partial")
	# jump to the speak exercise
	for i in lv.exercises.size():
		if lv.exercises[i]["type"] == "speak":
			lv.idx = i
	lv._reset_answer()
	lv._render()
	await _shot("08_lesson_speak")
	lv.speak_result = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_score.json"))
	lv._render()
	await _shot("09_lesson_speak_scored")
	lv.status = "loading"
	lv._loading_start = Time.get_ticks_msec()
	lv._render()
	await _shot("10_lesson_loading")
	lv.lang = "ja"
	lv.finish_lesson()
	await _shot("11_lesson_done")

	main_node.show_view("talk")
	var tv: TalkView = views["talk"]
	await _shot("12_talk_setup")
	tv.lang = "ja"
	tv.sc = TalkView.SCENES["ja"][0]
	tv.stage = 1
	tv.status = "talk"
	tv._update_visibility()
	tv._update_header()
	tv._apply_reply({"reply": "いらっしゃいませ。何にしますか？", "reading": "いらっしゃいませ。なににしますか？", "ko": "어서 오세요. 뭘로 하시겠어요?", "fix": "", "fix_ko": "", "suggest": ["おにぎりをください。", "お水はありますか？"]})
	tv.msgs.append({"role": "me", "text": "私はおにぎりがほしいです", "fix": "おにぎりをください。", "fix_ko": "주문할 때는 'をください'가 자연스러워요."})
	tv._apply_reply({"reply": "おにぎりですね。温めますか？", "reading": "おにぎりですね。あたためますか？", "ko": "주먹밥이요. 데워 드릴까요?", "fix": "", "fix_ko": "", "suggest": ["はい、お願いします。", "いいえ、大丈夫です。"]})
	tv.ko_open[2] = true
	tv._render_msgs()
	tv._update_composer()
	await _shot("13_talk_chat")
	tv.status = "fb"
	tv.fb = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_feedback.json"))
	tv._update_visibility()
	tv._render_fb()
	await _shot("14_talk_feedback")

	main_node.show_view("review")
	var rv: ReviewView = views["review"]
	await _shot("15_review_home")
	rv.lang = "ja"
	rv._start()
	await _shot("16_review_run")
	rv.typed_text = "毎朝七時におきます"
	rv._check_typed()
	await _shot("17_review_checked")

	main_node.show_view("roadmap")
	await _shot("18_roadmap")
	Store.set_pref("lang", "en")
