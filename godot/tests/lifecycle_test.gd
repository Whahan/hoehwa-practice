extends Node
## 1.1.1 regression tests that need no server and no microphone:
##   Api._finish_later (cancel in the same frame), Recorder.end() (PC mode: one `finished`), ConnectView._exit_tree,
##   Backend._start_remote (late result of an old connection), LessonView / ReviewView back button and on_hide,
##   ReadingView._scroll_to_selected, drill nodes freed with PhonemeScreen / ShadowScreen.
##   godot --headless --path <project> res://tests/lifecycle_test.tscn
## Exit code 0 = all passed. The network is never used: Api.base_url is "" (every request fails at once), the recorder is
## driven in its "pc" mode against that empty address, so /mic/start is never sent anywhere.

var passed: int = 0
var failed: int = 0
var _toasts: Array = []


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
	print("== lifecycle start ==")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	await _test_api_cancel_same_frame()
	await _test_recorder_end_once()
	await _test_connect_view_exit()
	await _test_backend_late_result()
	await _test_lesson_review_back()
	await _test_reading_scroll()
	await _test_drill_nodes_freed()
	print("== lifecycle result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- Api._finish_later

func _test_api_cancel_same_frame() -> void:
	print("[Api: a request cancelled in the frame it failed]")
	var old_base: String = Api.base_url
	var old_count: int = Api.active_count
	Api.base_url = ""
	Api.active_count = 5 ## a baseline above 0, so that a second decrement cannot hide behind the clamp at 0
	_toasts.clear()
	var c = Api.get_json("/x", 5.0, true)
	ok(Api.active_count == 6, "a request is counted when it starts")
	c.cancel()
	ok(Api.active_count == 5, "cancel() gives its count back")
	await _frames(3)
	ok(Api.active_count == 5, "the count is not decremented a second time one frame later (5, was %d)" % Api.active_count)
	ok(_toasts.is_empty(), "no error toast for the cancelled request")
	ok(c.done and bool(c.result.get("cancelled", false)), "the call reports 'cancelled'")
	# control: a request nobody cancels still reports its error and gives its count back
	var d = Api.get_json("/x", 5.0, true)
	await _frames(3)
	ok(Api.active_count == 5 and _toasts.size() == 1 and d.done and not bool(d.result["cancelled"]), "an uncancelled failing request: one error toast, count back to 5")
	Api.active_count = old_count
	Api.base_url = old_base


# ---------------------------------------------------------------- Recorder.end() in PC mode

func _test_recorder_end_once() -> void:
	print("[Recorder.end(): one `finished` when /mic/start fails]")
	var old_base: String = Api.base_url
	var old_mode: String = Recorder.mode_override
	Api.base_url = ""
	Recorder.mode_override = "pc"
	var got: Array = []
	var cb := func(r: Dictionary) -> void: got.append(r)
	Recorder.finished.connect(cb)
	_toasts.clear()
	ok(Recorder.begin(77), "begin() accepted")
	Recorder.end() # before /mic/start has answered
	await _frames(6)
	Recorder.finished.disconnect(cb)
	ok(got.size() == 1, "exactly one `finished` (was %d)" % got.size())
	ok(not Recorder.recording and not Recorder.stopping, "recorder is idle afterwards")
	ok(got.size() == 1 and int(got[0]["owner"]) == 77 and not bool(got[0]["ok"]), "the single result belongs to the caller and says not ok")
	Recorder.mode_override = old_mode
	Api.base_url = old_base


# ---------------------------------------------------------------- ConnectView

func _test_connect_view_exit() -> void:
	print("[ConnectView closed while waiting for the PC]")
	var view := ConnectView.new()
	add_child(view)
	await _frames(2)
	ok(view.cancel_button == null, "allow_cancel = false: no cancel button")
	view.address_edit.text = "127.0.0.1:1" # nothing listens there
	view.code_edit.text = "123456"
	view.submit()
	var flow: ConnectView.Flow = view._flow
	ok(flow != null and flow.connect_done.get_connections().size() == 1 and flow.progress.get_connections().size() == 1, "while waiting, the screen listens to the flow")
	remove_child(view) # back button
	ok(flow.connect_done.get_connections().is_empty() and flow.progress.get_connections().is_empty(), "leaving the tree cuts the flow signals")
	await _frames(1)
	view.free()
	await get_tree().create_timer(1.5).timeout # the flow ends on its own, nobody is called back
	ok(true, "the flow finished without calling the freed screen (no SCRIPT ERROR in the output)")
	var view2 := ConnectView.new()
	view2.allow_cancel = true
	add_child(view2)
	await _frames(2)
	ok(view2.cancel_button != null, "allow_cancel = true: cancel button shown")
	view2.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- Backend._start_remote

func _test_backend_late_result() -> void:
	print("[Backend: the late result of the old connection must not replace a new pairing]")
	const TEST_REMOTE := "user://lifecycle_test_remote.json"
	var old_path: String = Api.remote_path
	var old_base: String = Api.base_url
	var old_token: String = Api.token
	var old_mode: bool = Backend.remote_mode
	var old_status: int = Backend.status
	Api.remote_path = TEST_REMOTE
	Backend.remote_mode = true
	RemoteLink.save({"base_url": "http://127.0.0.1:1", "token": "old-token", "device_id": "d", "server_name": "old"}, TEST_REMOTE)
	Backend.start() # checks 127.0.0.1:1 (nothing listens: it fails)
	await _frames(1)
	# the person pairs again while that check is still waiting (ConnectView: save, set_remote, start())
	RemoteLink.save({"base_url": "http://127.0.0.1:2", "token": "new-token", "device_id": "d2", "server_name": "new"}, TEST_REMOTE)
	Api.set_remote("http://127.0.0.1:2", "new-token")
	Backend.start() # ignored: a start is running
	var t0: int = Time.get_ticks_msec()
	while Backend._starting and Time.get_ticks_msec() - t0 < 8000:
		await _frames(1)
	ok(not Backend._starting, "the start finished")
	ok(Api.base_url == "http://127.0.0.1:2" and Api.token == "new-token", "the new pairing is still the one in use (base %s)" % Api.base_url)
	ok(Backend.status == Backend.Status.FAILED, "the new connection was checked too (nothing listens there: FAILED)")
	RemoteLink.delete_file(TEST_REMOTE)
	Api.remote_path = old_path
	Api.base_url = old_base
	Api.token = old_token
	Backend.remote_mode = old_mode
	Backend.status = old_status as Backend.Status
	Backend._fail_streak = 0


# ---------------------------------------------------------------- LessonView / ReviewView

func _test_lesson_review_back() -> void:
	print("[LessonView / ReviewView: Android back button, on_hide]")
	var lv := LessonView.new()
	add_child(lv)
	await _frames(2)
	ok(not lv.go_back(), "lesson home: go_back() is false (main goes to 오늘)")
	lv.exercises = [{"type": "choice", "question": "q", "options": ["a", "b"], "answer": 0, "explain": ""}, {"type": "choice", "question": "q2", "options": ["a", "b"], "answer": 1, "explain": ""}]
	lv.title = "t"
	lv.idx = 0
	lv.results = []
	lv.status = "run"
	lv._render()
	_toasts.clear()
	ok(lv.go_back() and lv.status == "run" and _toasts.size() == 1, "solving: first back only asks (toast), the lesson stays")
	ok(lv.go_back() and lv.status == "idle", "solving: second back goes to the lesson home, not out of the view")
	ok(not lv.go_back(), "...and from the lesson home go_back() is false again")
	lv.status = "run"
	lv._render()
	lv.go_back()
	lv._leave_msec = -100000 # more than 2 s later
	ok(lv.go_back() and lv.status == "run", "a second press after 2 s asks again")
	lv.status = "done"
	ok(lv.go_back() and lv.status == "idle", "result screen: back goes to the lesson home")
	# loading: back cancels the request
	var old_base: String = Api.base_url
	lv.status = "idle"
	Api.base_url = ""
	Api.active_count = 3
	var held_call = Api.get_json("/lesson", 5.0, false)
	lv._call = held_call
	lv.status = "loading"
	ok(lv.go_back() and lv.status == "idle" and held_call.done and lv._call == null, "loading: back cancels the request and shows the lesson home")
	# on_hide while scoring
	var sc = Api.get_json("/score", 5.0, false)
	lv.status = "run"
	lv.idx = 0
	lv._score_call = sc
	lv.scoring = true
	lv.on_hide()
	ok(sc.done and lv._score_call == null and not lv.scoring, "on_hide cancels the scoring request")
	var pc = Api.get_json("/prosody", 5.0, false)
	lv._prosody_call = pc
	lv.on_hide()
	ok(pc.done and lv._prosody_call == null, "on_hide cancels the prosody request")
	# loading + on_hide
	var lc = Api.get_json("/lesson", 5.0, false)
	lv._call = lc
	lv.status = "loading"
	lv.on_hide()
	ok(lc.done and lv.status == "idle", "on_hide while the lesson is being made cancels it")
	await _frames(3)
	Api.active_count = 0
	Api.base_url = old_base
	lv.queue_free()

	var rv := ReviewView.new()
	add_child(rv)
	await _frames(2)
	ok(not rv.go_back(), "review home: go_back() is false")
	rv.items = [{"id": "x", "lang": "en", "target": "Hello.", "reading": "", "ko": "안녕", "note": "", "due": 0, "stability": 0.0, "difficulty": 0.0, "state": 1, "step": 0, "last_review": 0, "reps": 0, "lapses": 0}]
	rv.idx = 0
	rv.status = "run"
	rv._render()
	_toasts.clear()
	ok(rv.go_back() and rv.status == "run" and _toasts.size() == 1, "review session: first back only asks")
	ok(rv.go_back() and rv.status == "idle", "review session: second back goes to the review home")
	rv.status = "done"
	ok(rv.go_back() and rv.status == "idle", "review result: back goes to the review home")
	Api.base_url = ""
	var rs = Api.get_json("/score", 5.0, false)
	rv.status = "run"
	rv._score_call = rs
	rv.scoring = true
	rv.on_hide()
	ok(rs.done and rv._score_call == null and not rv.scoring, "review on_hide cancels the scoring request")
	Api.base_url = old_base
	await _frames(3)
	rv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- ReadingView._scroll_to_selected

func _test_reading_scroll() -> void:
	print("[ReadingView._scroll_to_selected after the text changed]")
	var rv := ReadingView.new()
	add_child(rv)
	await _frames(3)
	rv.tokens = [{"t": "a", "key": "a"}, {"t": "b", "key": "b"}, {"t": "c", "key": "c"}]
	rv.selected = 2
	rv._scroll_to_selected() # waits two frames, then reads tokens[0..selected-1]
	rv.tokens = [{"t": "a", "key": "a"}] # the text was replaced meanwhile
	await _frames(4)
	ok(true, "selected is past the new token list: returns quietly (no SCRIPT ERROR in the output)")
	rv.selected = -1
	rv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- drill nodes

func _test_drill_nodes_freed() -> void:
	print("[PhonemeScreen / ShadowScreen free their drill nodes]")
	var before: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	for kind in ["phoneme", "shadow"]:
		var scr: Control = PhonemeScreen.new() if kind == "phoneme" else ShadowScreen.new()
		add_child(scr)
		await _frames(2)
		var d := SpeakDrill.new("en", "drill" if kind == "phoneme" else "shadow")
		scr.drill = d
		scr.add_child(d)
		await _frames(1)
		# what _render() does: the drill (and its recorder) are taken out of the tree and kept in the screen
		scr.remove_child(d)
		var rec: RecorderWidget = d.make_recorder()
		var rec_valid: bool = rec != null and is_instance_valid(rec)
		remove_child(scr)
		scr.free()
		await _frames(2)
		ok(not is_instance_valid(d) or d.is_queued_for_deletion(), "%s: the detached drill is freed with the screen" % kind)
		if rec_valid:
			ok(not is_instance_valid(rec) or rec.is_queued_for_deletion(), "%s: the detached recorder widget is freed with the screen" % kind)
	await _frames(2)
	var after: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	ok(after <= before, "no orphan nodes left behind (before %d, after %d)" % [before, after])
