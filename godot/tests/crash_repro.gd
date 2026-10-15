extends Node
## Reproduces the "record -> stop -> /score -> render" path in a real window with the real mic and backend:
##   godot --path <project> res://tests/crash_repro.tscn
## Clicks the record button the same way a user does (button_down handlers), twice per cycle, several cycles.


func _log(s: String) -> void:
	print("[repro] ", s)


func _ready() -> void:
	var main_node: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_node)
	await get_tree().create_timer(2.0).timeout
	await Backend.start()
	_log("backend status %s" % Backend.status)
	main_node.show_view("lesson")
	var lv: LessonView = main_node.views["lesson"]
	lv.lang = "en"
	var f := FileAccess.open("res://tests/sample_lesson.json", FileAccess.READ)
	var parsed: Array = LessonView._parse_lesson(JSON.parse_string(f.get_as_text()))
	var speak_idx := -1
	for i in parsed.size():
		if parsed[i]["type"] == "speak":
			speak_idx = i
	lv.load_exercises(parsed)
	lv.idx = speak_idx
	lv._reset_answer()
	lv._render()
	for cycle in 3:
		await get_tree().create_timer(1.0).timeout
		var w: RecorderWidget = lv._record_widget
		_log("cycle %d: start (widget %s)" % [cycle, w])
		w._btn.button_down.emit()
		w._btn.button_up.emit()
		await get_tree().create_timer(2.0).timeout
		_log("cycle %d: stop" % cycle)
		w = lv._record_widget
		w._btn.button_down.emit()
		w._btn.button_up.emit()
		_log("cycle %d: stopped, scoring=%s" % [cycle, lv.scoring])
		var t := 0.0
		while lv.scoring and t < 20.0:
			await get_tree().process_frame
			t += get_process_delta_time()
		_log("cycle %d: scored %s" % [cycle, lv.speak_result.get("score", "-")])
		await get_tree().create_timer(1.5).timeout
		_log("cycle %d: rendered fine" % cycle)
	# now with real speech (Kokoro audio of the target), so the per-word chips and tips get drawn
	var target: String = str(lv.cur()["text"])
	for k in 3:
		var tts_req = Api.post_json("/tts", {"text": target, "lang": "en", "speed": 1.0 if k != 1 else 0.8}, 60.0, false)
		var tres: Dictionary = await tts_req.wait()
		_log("speech %d: tts ok=%s bytes=%d" % [k, tres["ok"], (tres["bytes"] as PackedByteArray).size()])
		lv._on_recorded({"b64": Marshalls.raw_to_base64(tres["bytes"])})
		var t2 := 0.0
		while lv.scoring and t2 < 20.0:
			await get_tree().process_frame
			t2 += get_process_delta_time()
		_log("speech %d: scored %s units=%d" % [k, lv.speak_result.get("score", "-"), (lv.speak_result.get("units", []) as Array).size()])
		await get_tree().create_timer(1.5).timeout
		_log("speech %d: rendered fine" % k)
	_log("DONE without crash")
	get_tree().quit()
