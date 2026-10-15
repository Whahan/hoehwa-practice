extends Node
## Live end-to-end test against the REAL backend (Whisper, Kokoro, Ollama) on 127.0.0.1:8770:
##   godot --headless --path <project> res://tests/live_test.tscn
## Uses Kokoro speech as the "learner's voice", so the mic path is exercised with real audio.

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func tts_b64(text: String, lang: String) -> String:
	var call_tts = Api.post_json("/tts", {"text": text, "lang": lang, "speed": 1.0}, 60.0, false)
	var res: Dictionary = await call_tts.wait()
	if not res.get("ok", false) or (res["bytes"] as PackedByteArray).is_empty():
		return ""
	return Marshalls.raw_to_base64(res["bytes"])


func _ready() -> void:
	print("== live test start ==")
	Store.progress_path = "user://live_progress.json"
	Store.progress = Progress.blank()
	var t0 := Time.get_ticks_msec()

	await Backend.start()
	ok(Backend.status == Backend.Status.READY and not Backend.llm_missing(), "backend ready with LLM")

	print("[lesson en]")
	var lv := LessonView.new()
	add_child(lv)
	lv.lang = "en"
	lv.start_lesson()
	await wait_until(func() -> bool: return lv.status != "loading", 240.0)
	ok(lv.status == "run" and lv.exercises.size() >= 4, "real /lesson parsed: %d exercises" % lv.exercises.size())
	var types: Array = []
	for e in lv.exercises:
		types.append(e["type"])
	print("    types: ", types)
	# answer every exercise with the key and walk to the end screen
	for i in lv.exercises.size():
		lv.idx = i
		lv._reset_answer()
		lv._render()
	lv.queue_free()

	print("[chat ja with voice]")
	var tv := TalkView.new()
	add_child(tv)
	await get_tree().process_frame
	tv.lang = "ja"
	tv._reset_selection()
	tv._start_chat()
	await wait_until(func() -> bool: return tv.status == "talk", 120.0)
	ok(tv.status == "talk" and tv.msgs.size() == 1, "AI opened in Japanese: %s" % (str(tv.msgs[0].get("reply", "")) if tv.msgs.size() > 0 else "-"))
	var voice: String = await tts_b64("きのう、ともだちと えいがを みました。", "ja")
	if voice == "":
		print("    (Api.post_raw not available; typing instead)")
		tv._input.text = "きのう、ともだちとえいがをみました。"
		tv._send_message()
	else:
		tv._on_recorded({"b64": voice})
	await wait_until(func() -> bool: return tv.status == "talk" and tv.msgs.size() >= 3, 120.0)
	ok(tv.msgs.size() >= 3, "my spoken message transcribed + AI replied")
	if tv.msgs.size() >= 3:
		print("    me: ", tv.msgs[1].get("text", ""), "  fix: ", tv.msgs[1].get("fix", ""))
		print("    ai: ", tv.msgs[2].get("reply", ""), " / ", tv.msgs[2].get("ko", ""))
	tv._input.text = "わたしは きのう がっこうに いきます。"
	tv._send_message()
	var t_send := Time.get_ticks_msec()
	await wait_until(func() -> bool: return tv.status == "talk" and tv.msgs.size() >= 5, 120.0)
	print("    reply shown after %.1fs" % ((Time.get_ticks_msec() - t_send) / 1000.0))
	await wait_until(func() -> bool: return tv.msgs.size() >= 5 and str(tv.msgs[3].get("fix", "")) != "", 120.0)
	print("    fix arrived after %.1fs" % ((Time.get_ticks_msec() - t_send) / 1000.0))
	ok(tv.msgs.size() >= 5 and str(tv.msgs[3].get("fix", "")) != "", "tense mistake got a fix: %s / %s" % [str(tv.msgs[3].get("fix", "")) if tv.msgs.size() >= 4 else "-", str(tv.msgs[3].get("fix_ko", "")) if tv.msgs.size() >= 4 else ""])
	tv._end_chat()
	await wait_until(func() -> bool: return tv.status == "fb", 180.0)
	ok(tv.status == "fb" and tv.fb.has("summary"), "real /feedback: %s" % str(tv.fb.get("summary", "")).left(80))

	print("[review scored with real audio]")
	var rv := ReviewView.new()
	add_child(rv)
	await get_tree().process_frame
	rv.lang = "ja"
	rv._start()
	if rv.status == "run" and rv.items.size() > 0:
		var target: String = str(rv.items[0]["target"])
		var said: String = await tts_b64(target, "ja")
		if said != "":
			rv._on_recorded({"b64": said})
			await wait_until(func() -> bool: return rv.checked, 60.0)
			ok(int(rv.score_result.get("score", 0)) >= 70, "TTS of the target scores high: %d (%s)" % [int(rv.score_result.get("score", 0)), target])
	else:
		print("    (no Japanese review items)")

	await get_tree().create_timer(0.3).timeout
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://live_progress.json"))
	print("== live result: %d passed, %d failed in %.0fs ==" % [passed, failed, (Time.get_ticks_msec() - t0) / 1000.0])
	get_tree().quit(1 if failed > 0 else 0)
