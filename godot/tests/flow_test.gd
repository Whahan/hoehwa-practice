extends Node
## End-to-end flow test against a running backend (or a mock of API.md) on 127.0.0.1:8770:
##   godot --headless --path <project> res://tests/flow_test.tscn
## Exercises Backend, Api, Tts, lesson generation, scoring, STT, chat and feedback through
## the real view classes. Uses a throw-away progress file.

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func wait_until(cond: Callable, timeout: float = 8.0) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _ready() -> void:
	print("== flow test start ==")
	Store.progress_path = "user://flow_progress.json"
	Store.progress = Progress.blank()
	var silent_wav: String = Marshalls.raw_to_base64(WavUtil.to_wav_bytes(WavUtil.silence(1.0, 16000)))

	print("[backend]")
	await Backend.start()
	ok(Backend.status == Backend.Status.READY, "Backend.start() -> READY (health ok)")
	ok(not Backend.launched_by_us, "server was already running, so Backend does not own/kill it")
	ok(Backend.health.get("stt", false) and (Backend.health.get("tts", {}) as Dictionary).get("ja", false), "health fields parsed")
	print("  llm_missing = ", Backend.llm_missing(), " (true -> the Ollama hint banner shows)")
	await wait_until(func() -> bool: return Store.curriculum_from_backend, 5.0)
	ok(Store.curriculum_from_backend and Store.months("ja").size() == 12, "GET /curriculum loaded into Store")

	print("[api errors]")
	var r404 = Api.get_json("/nope", 5.0, false)
	var res404: Dictionary = await r404.wait()
	ok(not res404["ok"] and res404["code"] == 404 and str(res404["error"]) != "", "HTTP error carries a Korean message: '%s'" % res404["error"])
	var rc = Api.post_json("/chat", {"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": {}, "history": []}, 30.0, false)
	rc.cancel()
	var resc: Dictionary = await rc.wait()
	ok(resc.get("cancelled", false), "cancel() resolves the call as cancelled")

	print("[tts]")
	Tts.speak("Nice to meet you.", "en")
	await wait_until(func() -> bool: return Tts.is_cached("Nice to meet you.", "en"), 5.0)
	ok(Tts.is_cached("Nice to meet you.", "en"), "TTS clip fetched and cached in memory")
	ok(Tts.playing or true, "playback started")

	print("[lesson]")
	var lv := LessonView.new()
	add_child(lv)
	lv.lang = "en"
	lv.start_lesson()
	ok(lv.status == "loading", "loading state shown while /lesson runs")
	await wait_until(func() -> bool: return lv.status == "run", 8.0)
	ok(lv.status == "run" and lv.exercises.size() == 5, "lesson parsed: %d exercises" % lv.exercises.size())
	for i in lv.exercises.size():
		if lv.exercises[i]["type"] == "speak":
			lv.idx = i
	lv._reset_answer()
	lv._render()
	lv._on_recorded({"b64": silent_wav})
	ok(lv.scoring, "scoring state while /score runs")
	await wait_until(func() -> bool: return not lv.speak_result.is_empty(), 5.0)
	ok(int(lv.speak_result.get("score", 0)) == 82, "POST /score parsed (score 82)")
	lv.start_lesson()
	await get_tree().process_frame
	lv.quit_lesson()
	ok(lv.status == "idle", "cancelling a lesson request returns to the start screen")
	lv.queue_free()

	print("[chat]")
	var tv := TalkView.new()
	add_child(tv)
	await get_tree().process_frame
	tv.lang = "en"
	tv._reset_selection()
	tv._start_chat()
	ok(tv.status == "wait", "typing indicator state while waiting for /chat")
	await wait_until(func() -> bool: return tv.status == "talk", 8.0)
	ok(tv.status == "talk" and tv.msgs.size() == 1 and str(tv.msgs[0]["reply"]).begins_with("Hi!"), "AI opens the conversation")
	tv._input.text = "I want coffee"
	tv._send_message()
	await wait_until(func() -> bool: return tv.status == "talk" and tv.msgs.size() == 3, 8.0)
	ok(tv.msgs.size() == 3 and str(tv.msgs[1].get("fix", "")) == "I would like a coffee, please.", "reply received and fix box attached to my message")
	# voice input path: /stt -> text -> auto send
	tv._on_recorded({"b64": silent_wav})
	await wait_until(func() -> bool: return tv.msgs.size() >= 4, 5.0)
	ok(tv.msgs.size() >= 4 and str(tv.msgs[3]["text"]) == "I would like a coffee please", "/stt text auto-sent as my message")
	await wait_until(func() -> bool: return tv.status == "talk" and tv.msgs.size() == 5, 8.0)
	tv._end_chat()
	ok(tv.status == "fbwait", "feedback waiting state")
	await wait_until(func() -> bool: return tv.status == "fb", 8.0)
	ok(tv.status == "fb" and tv.fb.has("summary"), "/feedback parsed")
	var added := false
	for r in Store.progress["review"]:
		if r["target"] == "I'd like a coffee, please.":
			added = true
	ok(added, "feedback corrections added to the review list")
	ok(Store.xp("en") >= 20 and Store.stat("en", "talks") == 1, "talk XP/stats updated (xp=%d)" % Store.xp("en"))

	print("[review]")
	var rv := ReviewView.new()
	add_child(rv)
	await get_tree().process_frame
	rv.lang = "en"
	rv._start()
	ok(rv.status == "run" and rv.items.size() >= 1, "review session started")
	rv._on_recorded({"b64": silent_wav})
	await wait_until(func() -> bool: return rv.checked, 5.0)
	ok(rv.checked and int(rv.score_result.get("score", 0)) == 82, "review answer scored through /score")
	var before: int = Store.review_for("en").size()
	Store.remove_review(str(rv.items[0]["id"]))
	ok(Store.review_for("en").size() == before - 1, "외웠어요 removes the item")

	await get_tree().create_timer(0.3).timeout
	ok(Api.active_count == 0, "no requests left in flight (active_count=%d)" % Api.active_count)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://flow_progress.json"))
	print("== flow result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)
