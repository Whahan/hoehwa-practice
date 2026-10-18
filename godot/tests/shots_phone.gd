extends Node
## Screenshots of every view in fixed states, for the phone layout (docs/android_remote_design.md §5)
## and for the "PC screens stay pixel-identical" comparison.
##   phone:  godot --path <project> --resolution 412x915 --audio-driver Dummy res://tests/shots_phone.tscn -- <out dir> --phone [--api=http://127.0.0.1:8860]
##   PC:     godot --path <project> --resolution 1280x800 --audio-driver Dummy res://tests/shots_phone.tscn -- <out dir>
## Options (docs/ui_redesign_design.md §8.4 W1b), after `--`:
##   --dark              dark colour scheme (UiBoot.apply "dark"); default light
##   --font-scale=<f>    text scale as Ds.set_font_scale (1.0 default; 9.0 -> 1.5; NaN/0 -> 1.0)
##   --only=<prefix>     write PNGs only for states whose name starts with <prefix>; the walk itself is unchanged
## File names: <platform>_NN_<state>.png with no option given (unchanged). With --dark or --font-scale the tag
## goes after the platform: phone_dark_NN_..., pc_light_f150_NN_... (f150 = scale 1.5, omitted at 1.0).
## Needs a real renderer (no --headless) for the PNGs. The phone_layout_test walk accepts the same options.
## Files are named <prefix>_NN_<state>.png (prefix = "phone" or "pc"). Needs a real renderer (no --headless).
## Fixed fixtures and a fixed random seed make two runs of the same build produce identical PNGs.

## Tests (phone_layout_test.gd) drive the same walk: with `state_hook` set, no PNG is written and
## the hook is called as hook(state_name, main_node) in every state; `finished` fires at the end.
signal finished

var out_dir: String = ""
var prefix: String = "pc"
var main_node: Control
var state_hook: Callable = Callable()
var quit_when_done: bool = true
var _n: int = 0
var _phone: bool = false
var _only: String = "" ## --only=<prefix>: PNG output filter by state name

const READING_DIR := "user://shots_phone_reading"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if out_dir == "":
		out_dir = args[0] if args.size() > 0 and not args[0].begins_with("--") else "user://shots_phone"
	_phone = Platform.is_phone()
	var scheme := "light"
	var scale_given := false
	var scale := 1.0
	for a in args:
		if a == "--dark":
			scheme = "dark"
		elif a.begins_with("--font-scale="):
			scale_given = true
			var raw := a.substr(13)
			if not raw.is_valid_float():
				push_error("shots_phone: bad --font-scale '%s', using 1.0" % raw)
			scale = raw.to_float() if raw.is_valid_float() else 1.0
		elif a.begins_with("--only="):
			_only = a.substr(7)
	# Scheme and scale are applied before the app is built (the code-built UI copies Pal colours at build time).
	UiBoot.apply(get_tree().root, scheme, scale)
	var tag := ""
	if scheme == "dark" or scale_given:
		tag = scheme
		if absf(Ds.font_scale - 1.0) > 0.001:
			tag += "_f%d" % roundi(Ds.font_scale * 100.0)
	prefix = ("phone" if _phone else "pc") + ("_" + tag if tag != "" else "")
	print("shots scheme=%s font_scale=%s prefix=%s only=%s" % [scheme, Ds.font_scale, prefix, _only])
	if not state_hook.is_valid():
		DirAccess.make_dir_recursive_absolute(out_dir)
	seed(7)
	Store.progress_path = "user://shots_phone_progress.json"
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en" # in memory only: the real prefs file stays untouched
	for k in ["reading_font", "hide_prosody", "show_reading", "lesson_source", "auto_speak"]:
		Store.prefs.erase(k)
	Store.prefs["auto_speak"] = false
	Store.add_review([
		{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": "Can I ~?"},
		{"lang": "en", "target": "I'd like a large coffee, please.", "ko": "큰 사이즈 커피 한 잔 주세요.", "note": ""},
		{"lang": "ja", "target": "毎朝七時に起きます。", "reading": "まいあさしちじにおきます。", "ko": "매일 아침 7시에 일어나요.", "note": "시간 + に"},
	])
	Store.progress["xp"]["en"] = 120
	Store.progress["days"][Plan.days_to_iso(Plan.today_days())] = {"en": true}
	Store.progress["days"][Plan.days_to_iso(Plan.today_days() - 1)] = {"en": true}
	Store.progress["checks"]["en-1-w0"] = true
	Store.progress["checks"]["en-1-m0"] = true
	_wipe()
	# never launch or poll the real engine from a screenshot run
	Backend._starting = true
	Backend.set_process(false)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main_node = scene.instantiate()
	add_child(main_node)
	await _frames(20)
	main_node._splash_dismissed = false
	Backend._set_status(Backend.Status.STARTING, "AI 엔진 준비 중… (12초)")
	await _shot("splash_starting")
	Backend._set_status(Backend.Status.FAILED, "파이썬 환경이 아직 없어요. backend 폴더의 setup.ps1을 먼저 실행해 주세요.")
	await _shot("splash_failed")
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": false, "llm_model": "qwen3:8b", "score": true, "phoneme": true}
	Backend._set_status(Backend.Status.READY)
	Toast.error("AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요.")
	await _frames(4)
	await _shot("banner_llm_toast", false)
	Backend.health["llm"] = true
	Backend._set_status(Backend.Status.READY)
	await _frames(6)
	await _run()
	_wipe()
	finished.emit()
	if quit_when_done:
		get_tree().quit()


func _wipe() -> void:
	for d in [READING_DIR.path_join("cache"), READING_DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Indeterminate progress bars animate with the wall clock: freeze them so two runs give the same pixels.
func _freeze_bars(node: Node) -> void:
	for c in node.get_children():
		if c is ProgressBar and (c as ProgressBar).indeterminate:
			(c as ProgressBar).indeterminate = false
			(c as ProgressBar).min_value = 0.0
			(c as ProgressBar).max_value = 100.0
			(c as ProgressBar).value = 35.0
		_freeze_bars(c)


func _shot(state: String, hide_toast: bool = true) -> void:
	await _frames(10)
	if hide_toast:
		main_node._toast_box.visible = false
	_freeze_bars(main_node)
	await _frames(3)
	_n += 1
	if state_hook.is_valid():
		state_hook.call(state, main_node)
		return
	if _only != "" and not state.begins_with(_only):
		return # numbering (_n) still counts every state, so names stay the same with or without --only
	var img: Image = get_viewport().get_texture().get_image()
	var fname := "%s_%02d_%s.png" % [prefix, _n, state]
	img.save_png(out_dir.path_join(fname))
	print("saved ", fname, " ", img.get_size())


static func fixture(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string("res://tests/" + name))


func _tok(rv: ReadingView, surface: String) -> int:
	for i in rv.tokens.size():
		if str((rv.tokens[i] as Dictionary)["t"]) == surface:
			return i
	return -1


func _run() -> void:
	var views: Dictionary = main_node.views
	# ---------------------------------------------------------------- today
	main_node.show_view("today")
	await _shot("today")
	var tdv: TodayView = views["today"]
	tdv._settings_open = true
	tdv.refresh()
	await _shot("today_settings")
	var sb: Variant = tdv.get("_settings_btn") # the settings toggle (only the phone-aware build has it)
	if _phone and sb is Control and is_instance_valid(sb):
		tdv._scroll.scroll_vertical = int(maxf(0.0, (sb as Control).global_position.y - tdv._scroll.content.global_position.y - 8.0))
	else:
		tdv._scroll.scroll_vertical = 650 if not _phone else 1250
	await _shot("today_settings_top")
	tdv._scroll.scroll_vertical = 100000
	await _shot("today_settings_bottom")
	tdv._settings_open = false
	tdv.refresh()
	tdv._scroll.scroll_vertical = 0

	# ---------------------------------------------------------------- lesson
	main_node.show_view("lesson")
	var lv: LessonView = views["lesson"]
	await _shot("lesson_home")
	var data: Variant = fixture("sample_lesson.json")
	lv.title = "카페에서 주문하기"
	lv.load_exercises(LessonView._parse_lesson(data))
	lv._render()
	await _shot("lesson_choice")
	lv.picked = 1
	lv._render()
	lv.check_answer()
	await _shot("lesson_choice_checked")
	lv.next_exercise() # fill
	lv.picked = 0
	lv._render()
	await _shot("lesson_fill")
	lv.next_exercise() # build
	var e: Dictionary = lv.cur()
	lv.built = [e["tiles"][0]["i"], e["tiles"][1]["i"]]
	lv._render()
	await _shot("lesson_build")
	for i in lv.exercises.size():
		if lv.exercises[i]["type"] == "listen":
			lv.idx = i
	lv._reset_answer()
	lv._autoplayed = lv._lesson_serial * 100 + lv.idx # no audio request in screenshots
	lv._render()
	await _shot("lesson_listen")
	for i in lv.exercises.size():
		if lv.exercises[i]["type"] == "speak":
			lv.idx = i
	lv._reset_answer()
	lv._render()
	lv.prosody = fixture("sample_prosody_en_before.json")
	lv.prosody_native = lv.prosody
	lv._prosody_state = "ok"
	lv._apply_prosody()
	await _shot("lesson_speak")
	lv.speak_result = fixture("sample_score_en_ph.json")
	lv.prosody = fixture("sample_prosody_en_after.json")
	lv._render()
	lv._apply_prosody()
	await _shot("lesson_speak_scored")
	lv.status = "loading"
	lv._req_source = "tatoeba"
	lv._loading_start = Time.get_ticks_msec()
	lv._render()
	await _shot("lesson_loading")
	lv.lang = "ja"
	lv.finish_lesson()
	await _shot("lesson_done")
	lv.status = "idle"
	lv.lang = "en"
	lv._render()

	# ---------------------------------------------------------------- talk
	main_node.show_view("talk")
	var tv: TalkView = views["talk"]
	await _shot("talk_setup")
	tv.lang = "en"
	tv.sc = TalkView.SCENES["en"][0]
	tv.stage = 1
	tv.status = "talk"
	tv._update_visibility()
	tv._update_header()
	tv._apply_reply({"reply": "Hi! Welcome to the shop. What can I get started for you today? We have a special on iced lattes this afternoon, if you are interested.", "reading": "", "ko": "안녕하세요! 어서 오세요. 뭘로 시작해 드릴까요? 오늘 오후에는 아이스 라테 특별 할인이 있어요.", "fix": "", "fix_ko": "", "suggest": ["A latte, please.", "Can I see the menu, please? I'd like to look at the options first."]})
	tv.msgs.append({"role": "me", "text": "I want coffee and a muffin please", "fix": "I would like a coffee and a muffin, please.", "fix_ko": "I want 보다 I would like 가 더 정중해요."})
	tv._apply_reply({"reply": "Sure thing. Anything else?", "reading": "", "ko": "네. 더 필요한 건요?", "fix": "", "fix_ko": "", "suggest": ["No, thanks.", "A muffin."]})
	tv.ko_open[2] = true
	tv._render_msgs()
	tv._update_composer()
	await _shot("talk_chat_en")
	tv.lang = "ja"
	tv.sc = TalkView.SCENES["ja"][0]
	tv.msgs = []
	tv._update_header()
	tv._apply_reply({"reply": "いらっしゃいませ。ご注文はお決まりでしょうか。本日のおすすめはサンドイッチとコーヒーのセットです。", "reading": "いらっしゃいませ。ごちゅうもんはおきまりでしょうか。", "ko": "어서 오세요. 주문은 정하셨나요? 오늘의 추천은 샌드위치와 커피 세트예요.", "fix": "", "fix_ko": "", "suggest": ["おにぎりをください。", "お水はありますか？"]})
	tv.msgs.append({"role": "me", "text": "私はおにぎりがほしいです", "fix": "おにぎりをください。", "fix_ko": "주문할 때는 'をください'가 자연스러워요."})
	tv._apply_reply({"reply": "おにぎりですね。温めますか？", "reading": "おにぎりですね。あたためますか？", "ko": "주먹밥이요. 데워 드릴까요?", "fix": "", "fix_ko": "", "suggest": ["はい、お願いします。", "いいえ、大丈夫です。"]})
	tv._render_msgs()
	tv._update_composer()
	await _shot("talk_chat_ja")
	tv.lang = "en"
	tv.sc = TalkView.SCENES["en"][0]
	tv.status = "fb"
	tv.fb = fixture("sample_feedback.json")
	tv._update_visibility()
	tv._render_fb()
	await _shot("talk_feedback")
	tv.status = "setup"
	tv.msgs = []
	tv._reset_selection()
	tv._render_setup()

	# ---------------------------------------------------------------- reading
	main_node.show_view("reading")
	var rv: ReadingView = views["reading"]
	rv.storage_dir = READING_DIR
	rv.auto_fetch = false
	rv.glosses.clear()
	var d1: Dictionary = rv.new_doc("BBC — City foxes", "en", "Urban foxes have adapted remarkably well to city life, scavenging from bins and sleeping under garden sheds.")
	d1["id"] = "shot1"
	d1["opened"] = 1700000000
	rv.save_doc(d1)
	var d2: Dictionary = rv.new_doc("", "en", "The committee postponed its decision until further evidence could be gathered from the regional offices.")
	d2["id"] = "shot2"
	d2["opened"] = 1700100000
	rv.save_doc(d2)
	rv.mode = "library"
	rv.lang = "en"
	var s: Dictionary = ReadingView.SAMPLES["en"]
	rv._draft_title = str(s["title"])
	rv._draft_text = str(s["text"])
	rv._render()
	await _shot("reading_library")
	var rdata: Dictionary = fixture("sample_reading_analyze.json")
	var rtext: String = ""
	for t in rdata["tokens"]:
		rtext += str(t["t"])
	var rd: Dictionary = rv.new_doc("Running in the Rain", "en", rtext)
	rd["id"] = "shot3"
	rv.save_doc(rd)
	rv.open_doc(rd)
	rv.set_analysis(rdata, false)
	rv.apply_glosses(fixture("sample_reading_gloss.json"))
	rv.select_token(_tok(rv, "grey"))
	rv.add_selected_to_review()
	rv.select_token(_tok(rv, "rhythm"))
	rv.mark_selected_known()
	rv.close_panel()
	await _shot("reading_reader_en")
	rv.select_token(_tok(rv, "reckless"))
	rv.set_examples("reckless", {"examples": [
		{"id": 1, "text": "It was reckless of him to drive so fast.", "ko": "그렇게 빨리 운전하다니 그는 무모했다.", "en": "", "ja": "", "url": ""},
		{"id": 2, "text": "Don't be reckless [with money].", "ko": "", "en": "", "ja": "お金に関して無謀なことをするな。", "url": ""},
	], "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"})
	await _shot("reading_word_panel")
	rv._panel_scroll.scroll_vertical = 100000
	await _shot("reading_word_panel_bottom")
	var jd: Dictionary = fixture("sample_reading_analyze_ja.json")
	var jt: String = ""
	for t in jd["tokens"]:
		jt += str(t["t"])
	var dj: Dictionary = rv.new_doc("朝の日記", "ja", jt)
	dj["id"] = "shot4"
	rv.save_doc(dj)
	rv.open_doc(dj)
	rv.set_analysis(jd, false)
	rv.apply_glosses(fixture("sample_reading_gloss_ja.json"))
	rv.select_token(_tok(rv, "傘"))
	rv.add_selected_to_review()
	rv.select_token(_tok(rv, "食べ"))
	rv.set_examples("食べる", {"examples": [
		{"id": 10, "text": "朝ごはんを食べましたか。", "ko": "아침 먹었어요?", "en": "", "ja": "", "url": ""},
	], "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"})
	await _shot("reading_reader_ja")
	rv.back_to_library()
	rv.lang = "en"
	rv._render()

	# ---------------------------------------------------------------- review
	main_node.show_view("review")
	var rev: ReviewView = views["review"]
	await _shot("review_home")
	rev.lang = "en"
	rev._start()
	await _shot("review_run")
	rev.typed_text = "Can I have a menu"
	rev._check_typed()
	await _shot("review_checked")
	rev.status = "idle"
	rev._render()

	# ---------------------------------------------------------------- roadmap
	main_node.show_view("roadmap")
	await _shot("roadmap")
	var rm: RoadmapView = views["roadmap"]
	Store.prefs["open_months"] = {"en1": true, "en2": true} # in memory only
	rm.refresh()
	await _frames(4)
	rm._scroll.scroll_vertical = 700 if not _phone else 1000
	await _shot("roadmap_month_open")
	Store.prefs.erase("open_months")

	if _phone:
		await _run_phone_extras(views)


## States that exist only in the phone layout (keyboard, safe area, connect screen).
func _run_phone_extras(views: Dictionary) -> void:
	var PL: Variant = load("res://scripts/ui/phone_layout.gd")
	var tv: TalkView = views["talk"]
	main_node.show_view("talk")
	tv.lang = "en"
	tv.sc = TalkView.SCENES["en"][0]
	tv.msgs = []
	tv.status = "talk"
	tv._update_visibility()
	tv._update_header()
	tv._apply_reply({"reply": "Hi! What can I get for you?", "reading": "", "ko": "안녕하세요! 뭘 드릴까요?", "fix": "", "fix_ko": "", "suggest": ["A latte, please.", "Can I see the menu?"]})
	tv._render_msgs()
	tv._update_composer()
	await _shot("talk_no_keyboard")
	PL.set("test_keyboard_height", 300.0)
	await _frames(4)
	await _shot("talk_keyboard_300")
	PL.set("test_keyboard_height", -1.0)
	PL.set("test_insets", {"top": 48.0, "bottom": 34.0, "left": 0.0, "right": 0.0})
	main_node.show_view("today")
	await _shot("insets_top48_bottom34")
	PL.set("test_insets", null)
	Backend._set_status(Backend.Status.NEEDS_PAIRING, "연결이 필요해요")
	await _shot("needs_pairing")
	Backend._set_status(Backend.Status.READY)
	# 8 tabs (English v1.1 adds 연습 and 기록): 5 cells + 더보기
	main_node.call("add_tab", "practice", "연습", AppView.new(), "연습")
	main_node.call("add_tab", "log", "기록", AppView.new(), "기록")
	main_node.call("show_view", "today")
	await _shot("tabs8_bar")
	main_node._bottom_tabs.open_more()
	await _shot("tabs8_more_sheet")
	main_node._bottom_tabs.close_more()
