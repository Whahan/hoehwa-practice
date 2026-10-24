extends Node
## A7: self-rating widget instead of scoring (docs/phone_standalone_design.md 3.3, 4.6, 8 A7).
##   godot --headless --path <project> res://tests/self_rate_test.tscn -- --phone
## Exit code 0 = all checks passed. Last line: "== self_rate_test result: N passed, 0 failed ==".
## No backend and no network: `Api` is replaced for the run by a subclass that records every request path
## (spy_log) and answers /score and /prosody from fixtures when Route says "pc". Route is steered with
## Route.mode / Route.phone_hook / LocalApi.handler_override, so "score = none" is the real Route decision.
## Prefs, progress and the study log use user://self_rate_* files; everything is restored at the end.

const SCORE_FIX := "res://tests/sample_score.json"
const PROSODY_FIX := "res://tests/sample_prosody_en_before.json"
const TEST_PROGRESS := "user://self_rate_progress.json"
const TEST_LOG := "user://self_rate_studylog.json"
const TARGET := "Can I have a menu?"
const SECTIONS := ["widget", "lesson_none", "lesson_again", "review_none", "shadow_none", "phoneme_none", "drill_none",
	"pc_mode", "phone_mode", "caps"]


## Spy code appended to a copy of api.gd (see _make_spy_script): `_start` is the one entry of every request.
const SPY_TAIL := """

var spy_log: Array = []
var canned: Dictionary = {} # path -> data of a 200 answer (only when Route.decide says "pc")


func _start(method: int, path: String, body: Variant, timeout: float, report: bool, base_override: String = "", auth: bool = true) -> ApiCall:
	var p: String = path.split("?")[0]
	spy_log.append(p)
	var m: String = "GET" if method == HTTPClient.METHOD_GET else "POST"
	var bd: Dictionary = body if body is Dictionary else {}
	if canned.has(p) and Route.decide(m, p, bd) == "pc":
		var call_obj := ApiCall.new()
		call_obj.path = path
		active_count += 1
		var res: Dictionary = {"ok": true, "code": 200, "data": canned[p], "bytes": PackedByteArray(), "error": "", "cancelled": false, "err_code": "", "err_body": null}
		_finish_later(call_obj, res, false)
		return call_obj
	return _start_orig(method, path, body, timeout, report, base_override, auth)
"""


var passed: int = 0
var failed: int = 0
var reached: Dictionary = {}
var tts_calls: Array = []
var hook_calls: Array = []
var play_calls: Array = []
var score_fix: Dictionary = {}
var prosody_fix: Dictionary = {}
var rec: Dictionary = {}

var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var _saved_progress_path: String = ""
var _saved_log_path: String = ""
var _saved_mode: String = ""
var _saved_phone_hook: Callable = Callable()
var _saved_overrides: Dictionary = {}
var _orig_api_script: Script = null


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== self_rate_test start ==")
	_setup()
	await _run()
	_teardown()
	for s in SECTIONS:
		ok(reached.has(s), "section '%s' ran to its end" % s)
	print("== self_rate_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup / helpers

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	return v if v is Dictionary else {}


func _setup() -> void:
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	_saved_progress_path = Store.progress_path
	_saved_log_path = StudyLog.path
	_saved_mode = Route.mode
	_saved_phone_hook = Route.phone_hook
	_saved_overrides = LocalApi.handler_override.duplicate()
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("hide_prosody")
	score_fix = _load_json(SCORE_FIX)
	prosody_fix = _load_json(PROSODY_FIX)
	var wav: PackedByteArray = WavUtil.to_wav_bytes(WavUtil.sine(0.6, 16000))
	rec = {"ok": true, "silent": false, "duration": 0.6, "b64": Marshalls.raw_to_base64(wav), "wav": wav, "owner": 0}
	_orig_api_script = Api.get_script()
	var spy: GDScript = _make_spy_script()
	ok(spy != null, "spy Api script compiles")
	Api.set_script(spy)
	Api.set("canned", {"/score": score_fix, "/prosody": prosody_fix})
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SelfRatePanel.play_hook = Callable(self, "_play_hook")


## api.gd with `_start` renamed to `_start_orig` plus the spy `_start` of SPY_TAIL (the autoload script itself cannot be extended).
func _make_spy_script() -> GDScript:
	var src: String = FileAccess.get_file_as_string("res://scripts/autoload/api.gd")
	if not src.contains("func _start("):
		return null
	var g := GDScript.new()
	g.source_code = src.replace("func _start(", "func _start_orig(") + SPY_TAIL
	if g.reload() != OK:
		return null
	return g


func _teardown() -> void:
	SelfRatePanel.play_hook = Callable()
	SpeakDrill.api_hook = Callable()
	SpeakDrill.score_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	Api.set_script(_orig_api_script)
	Route.mode = _saved_mode
	Route.phone_hook = _saved_phone_hook
	LocalApi.handler_override = _saved_overrides
	StudyLog.reset()
	StudyLog.path = _saved_log_path
	Store.progress_path = _saved_progress_path
	Store.progress = _saved_progress
	for f in [TEST_PROGRESS, TEST_LOG, TEST_LOG + ".bad"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.prefs = _saved_prefs
	Store.save_prefs()


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _play_hook(who: String) -> void:
	play_calls.append(who)


func _drill_hook(method: String, path: String, body: Variant) -> Variant:
	hook_calls.append({"method": method, "path": path, "body": body})
	if path.begins_with("/score"):
		return {"ok": true, "code": 200, "data": score_fix, "error": ""}
	return {"ok": false, "code": 404, "data": null, "error": "no"}


## Score = none: phone app, mode "phone", no phone handler for /stt and /score.
func _mode_none() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	LocalApi.handler_override = {"stt": null}


## Score = pc: the PC app (Route.is_phone false), whatever the platform of this test run.
func _mode_pc() -> void:
	Route.mode = "auto"
	Route.phone_hook = func() -> bool: return false
	LocalApi.handler_override = {}


## Score = phone: mode "phone" with a fake /score handler that answers the fixture.
func _mode_phone_score() -> void:
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	var g := GDScript.new()
	g.source_code = "extends RefCounted\nstatic func is_available() -> bool:\n\treturn true\nstatic func handle(_m, _p, _q, _b):\n\treturn {\"ok\": true, \"code\": 200, \"data\": JSON.parse_string(\"\"\"%s\"\"\")}\n" % JSON.stringify(score_fix)
	g.reload()
	LocalApi.handler_override = {"stt": g}


func _log() -> Array:
	return Api.get("spy_log") as Array


func _clear_log() -> void:
	Api.set("spy_log", [])
	hook_calls.clear()
	tts_calls.clear()
	play_calls.clear()


func _score_requests() -> int:
	var n := 0
	for p in _log():
		if str(p) == "/score":
			n += 1
	return n


func _count_in_log(path: String) -> int:
	var n := 0
	for p in _log():
		if str(p) == path:
			n += 1
	return n


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func wait_until(cond: Callable, timeout: float = 5.0) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)


func _nodes(root: Node) -> Array:
	var out: Array = []
	_walk(root, out)
	return out


func find_button(root: Node, text: String) -> Button:
	for n in _nodes(root):
		if n is Button and (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func find_label(root: Node, part: String) -> Label:
	for n in _nodes(root):
		if n is Label and (n as Label).text.contains(part):
			return n
	return null


func find_panel(root: Node) -> SelfRatePanel:
	for n in _nodes(root):
		if n is SelfRatePanel and not (n as SelfRatePanel).is_queued_for_deletion():
			return n
	return null


func disabled_cards(root: Node) -> Array:
	var out: Array = []
	for n in _nodes(root):
		if n.name == "DisabledFeature" and n.has_meta("reason") and not n.is_queued_for_deletion():
			out.append(n)
	return out


func card_reasons(root: Node) -> Array:
	var out: Array = []
	for c in disabled_cards(root):
		out.append(str((c as Node).get_meta("reason")))
	return out


func card_is_disabled_with_reason(card: Node) -> bool:
	var reason: String = str(card.get_meta("reason"))
	var btn_off := false
	for n in _nodes(card):
		if n is Button and (n as Button).disabled:
			btn_off = true
	var line := false
	for n in _nodes(card):
		if n is Label and (n as Label).text == reason and reason.strip_edges() != "":
			line = true
	return btn_off and line


## Total of StudyLog score counts (the "말하기" counter) over all days / languages.
func score_count() -> int:
	var n := 0
	var days: Dictionary = StudyLog.snapshot()["days"]
	for d in days.values():
		for l in (d as Dictionary).values():
			n += int(((l as Dictionary)["score"] as Array)[0])
	return n


func event_count(kind: String) -> int:
	var n := 0
	var days: Dictionary = StudyLog.snapshot()["days"]
	for d in days.values():
		for l in (d as Dictionary).values():
			n += int(((l as Dictionary)["n"] as Dictionary).get(kind, 0))
	return n


func _fresh_state() -> void:
	StudyLog.reset()
	Store.progress = Progress.blank()
	_clear_log()


func _mk_lesson() -> LessonView:
	var lv := LessonView.new()
	add_child(lv)
	await _frames(2)
	lv.lang = "en"
	lv.exercises = [LessonView.prep_exercise({"type": "speak", "text": TARGET, "ko": "메뉴를 주세요", "reading": "", "pron": ""})]
	lv.status = "run"
	lv.idx = 0
	lv._reset_answer()
	lv._render()
	await _frames(2)
	return lv


# ---------------------------------------------------------------- the run

func _run() -> void:
	await _test_widget()
	await _test_lesson_none()
	await _test_lesson_again()
	await _test_review_none()
	await _test_shadow_none()
	await _test_phoneme_none()
	await _test_drill_none()
	await _test_pc_mode()
	await _test_phone_mode()
	await _test_caps()


func _test_widget() -> void:
	print("[widget]")
	_mode_none()
	_fresh_state()
	var good: Dictionary = SelfRatePanel.good_result("en", TARGET)
	ok(SelfRatePanel.is_self_rated(good) and not SelfRatePanel.is_self_rated(score_fix) and not SelfRatePanel.is_self_rated(null), "good_result is marked self_rated, a real score and null are not")
	ok(StudyLog.add_score("en", good, "test") and score_count() == 1, "good_result is accepted by StudyLog.add_score (one speaking count)")
	StudyLog.reset()
	ok(SelfRatePanel.needed() and SelfRatePanel.prosody_off() and SelfRatePanel.phoneme_off(), "in mode phone without a handler: score, prosody and phoneme are off")
	var panel := SelfRatePanel.new("en", TARGET, rec, Pal.EN)
	add_child(panel)
	await _frames(2)
	ok(find_button(panel, "▶ 내 목소리 듣기") != null and find_button(panel, "▶ 원어민 듣기") != null, "panel has the two listen buttons")
	ok(find_button(panel, "잘했어요") != null and find_button(panel, "다시") != null, "panel has 잘했어요 and 다시")
	ok(panel.mine_stream() != null and panel.mine_stream().data.size() > 0, "the recording becomes a playable stream")
	var rated: Array = []
	panel.rated.connect(func(g: bool) -> void: rated.append(g))
	find_button(panel, "▶ 내 목소리 듣기").pressed.emit()
	find_button(panel, "▶ 원어민 듣기").pressed.emit()
	await _frames(2)
	ok(panel.mine_plays == 1 and panel.native_plays == 1 and play_calls == ["mine", "native"], "own voice and native voice can be played one after the other")
	ok(tts_calls.size() == 1 and tts_calls[0]["text"] == TARGET and tts_calls[0]["lang"] == "en", "native listen speaks the target sentence through Tts")
	find_button(panel, "잘했어요").pressed.emit()
	find_button(panel, "잘했어요").pressed.emit() # a second tap does nothing
	await _frames(1)
	ok(rated == [true], "잘했어요 emits rated(true) exactly once (double tap ignored)")
	ok(find_button(panel, "다시").disabled and find_button(panel, "잘했어요").disabled, "buttons are disabled after rating")
	panel.queue_free()
	# narrow screen: nothing sticks out of a 412 px column, the buttons are touch targets on the phone
	var host := VBoxContainer.new()
	host.custom_minimum_size = Vector2(412, 0)
	host.size = Vector2(412, 600)
	add_child(host)
	var narrow := SelfRatePanel.new("en", TARGET, rec, Pal.EN)
	host.add_child(narrow)
	await _frames(3)
	var sticks_out := 0
	var small_btn := 0
	var host_rect: Rect2 = host.get_global_rect()
	for n in _nodes(narrow):
		if n is Control and (n as Control).is_visible_in_tree() and (n as Control).get_global_rect().end.x > host_rect.end.x + 1.0:
			sticks_out += 1
		if n is Button and (n as Button).get_global_rect().size.y < 47.5 and Platform.is_phone():
			small_btn += 1
	ok(sticks_out == 0, "no control sticks out of a 412 px column (%d)" % sticks_out)
	ok(small_btn == 0, "every button is at least 47.5 px high on the phone (%d too small)" % small_btn)
	host.queue_free()
	var bare := SelfRatePanel.new("en", TARGET, {}, Pal.EN)
	add_child(bare)
	await _frames(1)
	ok(bare.mine_stream() == null, "a result without audio gives no stream (no crash)")
	bare.queue_free()
	reached["widget"] = true


func _test_lesson_none() -> void:
	print("[lesson, score none]")
	_mode_none()
	_fresh_state()
	var lv: LessonView = await _mk_lesson()
	ok(find_panel(lv) == null, "before recording there is no self-rate panel")
	# disabled cards are there before recording (prosody)
	var pre: Array = card_reasons(lv)
	ok(pre.has(SelfRatePanel.PROSODY_REASON), "prosody card is disabled with the reason before recording: %s" % str(pre))
	lv._on_recorded(rec)
	await _frames(3)
	var panel: SelfRatePanel = find_panel(lv)
	ok(panel != null and not lv.speak_self_rec.is_empty() and not lv.scoring, "recording shows the self-rate panel, no scoring state")
	ok(_score_requests() == 0 and _count_in_log("/prosody") == 0, "no /score and no /prosody request (log: %s)" % str(_log()))
	ok(find_label(lv, "점수") != null and find_label(lv, "발음 점수") == null, "no score panel is drawn")
	var cards: Array = disabled_cards(lv)
	var reasons: Array = card_reasons(lv)
	ok(reasons.has(SelfRatePanel.PROSODY_REASON) and reasons.has(SelfRatePanel.PHONEME_REASON), "prosody and phoneme cards are shown with their reasons: %s" % str(reasons))
	var all_ok := not cards.is_empty()
	for c in cards:
		if not card_is_disabled_with_reason(c):
			all_ok = false
	ok(all_ok, "every unavailable-feature card has a disabled button and a non-empty reason line")
	find_button(lv, "▶ 내 목소리 듣기").pressed.emit()
	find_button(lv, "▶ 원어민 듣기").pressed.emit()
	ok(play_calls == ["mine", "native"] and tts_calls.size() == 1, "both listen buttons work inside the lesson")
	find_button(lv, "잘했어요").pressed.emit()
	await _frames(3)
	ok(SelfRatePanel.is_self_rated(lv.speak_result) and lv.speak_self_rec.is_empty(), "잘했어요 becomes the speak result")
	ok(score_count() == 1, "StudyLog got one speaking count (%d)" % score_count())
	ok(_score_requests() == 0, "still no /score request after rating")
	var rl: Node = null
	for n in _nodes(lv):
		if n.name == "ResultLine":
			rl = n
	ok(rl != null and (rl as Label).text.contains("맞았어요"), "the bottom bar shows the passed result line")
	var next_btn: Button = find_button(lv, "결과 보기")
	ok(next_btn != null, "the 결과 보기 button is there")
	if next_btn != null:
		next_btn.pressed.emit()
	await _frames(3)
	ok(lv.status == "done" and lv.results.size() == 1 and bool(lv.results[0]["ok"]) and lv.ok_count == 1, "lesson result counts the speaking exercise as passed")
	var lesson_pair: Array = []
	for d in (StudyLog.snapshot()["days"] as Dictionary).values():
		for l in (d as Dictionary).values():
			lesson_pair = (l as Dictionary)["lesson"]
	ok(lesson_pair == [1, 1], "StudyLog lesson result is 1 of 1 (%s)" % str(lesson_pair))
	lv.queue_free()
	await _frames(1)
	reached["lesson_none"] = true


func _test_lesson_again() -> void:
	print("[lesson, 다시]")
	_mode_none()
	_fresh_state()
	var lv: LessonView = await _mk_lesson()
	lv._on_recorded(rec)
	await _frames(3)
	ok(find_panel(lv) != null, "panel shown")
	find_button(lv, "다시").pressed.emit()
	await _frames(3)
	ok(find_panel(lv) == null and lv.speak_self_rec.is_empty() and lv.speak_result.is_empty(), "다시 clears the panel and leaves no result")
	ok(score_count() == 0 and lv.results.is_empty(), "다시 records nothing: score count %d, results %d" % [score_count(), lv.results.size()])
	ok(find_button(lv, "지금은 말하기 어려워요") != null, "the skip button is back (nothing was passed)")
	# record again and rate good after a 다시: counts exactly one
	lv._on_recorded(rec)
	await _frames(3)
	find_button(lv, "잘했어요").pressed.emit()
	await _frames(3)
	ok(score_count() == 1, "다시 then 잘했어요 counts one (%d)" % score_count())
	ok(_score_requests() == 0, "no /score request in this flow either")
	lv.queue_free()
	await _frames(1)
	reached["lesson_again"] = true


func _mk_review() -> ReviewView:
	Store.add_review([{"lang": "en", "target": TARGET, "ko": "메뉴를 주세요", "reading": ""}])
	var rv := ReviewView.new()
	add_child(rv)
	await _frames(2)
	rv.lang = "en"
	rv._start()
	await _frames(2)
	return rv


func _test_review_none() -> void:
	print("[review, score none]")
	_mode_none()
	_fresh_state()
	var rv: ReviewView = await _mk_review()
	ok(rv.status == "run" and rv.items.size() == 1, "review session started")
	rv._on_recorded(rec)
	await _frames(3)
	ok(find_panel(rv) != null and not rv.scoring and not rv.checked, "recording shows the self-rate panel in the review card")
	ok(_score_requests() == 0, "no /score request (log: %s)" % str(_log()))
	ok(card_reasons(rv).has(SelfRatePanel.PHONEME_REASON), "phoneme card is disabled with a reason")
	find_button(rv, "다시").pressed.emit()
	await _frames(3)
	ok(find_panel(rv) == null and not rv.checked and score_count() == 0, "다시 records nothing and the card stays open")
	rv._on_recorded(rec)
	await _frames(3)
	find_button(rv, "잘했어요").pressed.emit()
	await _frames(3)
	ok(rv.self_good and rv.checked and score_count() == 1, "잘했어요 reveals the answer and counts one speaking (%d)" % score_count())
	ok(find_label(rv, "스스로 '잘했어요'") != null, "the result card says it was self-rated")
	var good_btn: Button = null
	for n in _nodes(rv):
		if n is Button and (n as Button).text.begins_with("좋음"):
			good_btn = n
	ok(good_btn != null, "the rating bar is there")
	ok(find_label(rv, "'좋음'를 골라 뒀어요") != null, "the hint suggests 좋음")
	if good_btn != null:
		good_btn.pressed.emit()
	await _frames(3)
	ok(rv.done_count == 1, "rating the card moves on (done_count %d)" % rv.done_count)
	ok(_score_requests() == 0, "still no /score request")
	rv.queue_free()
	await _frames(1)
	reached["review_none"] = true


func _test_shadow_none() -> void:
	print("[shadow, score none]")
	_mode_none()
	_fresh_state()
	var sh := ShadowScreen.new()
	add_child(sh)
	await _frames(2)
	sh.lang = "en"
	sh._begin_run([{"id": 1, "text": TARGET, "ko": "메뉴를 주세요", "reading": "", "url": ""}, {"id": 2, "text": "Nice to meet you.", "ko": "", "reading": "", "url": ""}], "")
	await _frames(2)
	sh.drill._on_recorded(rec)
	await _frames(3)
	ok(sh.drill.status == "self" and find_panel(sh) != null, "shadow: recording shows the self-rate panel")
	ok(_score_requests() == 0 and _count_in_log("/prosody") == 0, "shadow: no /score, no /prosody request")
	ok(card_reasons(sh).has(SelfRatePanel.PROSODY_REASON) and card_reasons(sh).has(SelfRatePanel.PHONEME_REASON), "shadow: prosody and phoneme cards disabled with reasons")
	find_button(sh, "다시").pressed.emit()
	await _frames(3)
	ok(int(sh.results[0]["tries"]) == 0 and score_count() == 0 and event_count("shadow") == 0, "shadow: 다시 records nothing")
	sh.drill._on_recorded(rec)
	await _frames(3)
	find_button(sh, "잘했어요").pressed.emit()
	await _frames(3)
	var r0: Dictionary = sh.results[0]
	ok(int(r0["tries"]) == 1 and bool(r0["passed"]) and bool(r0.get("self", false)), "shadow: 잘했어요 passes the sentence (tries 1, self)")
	ok(score_count() == 1 and event_count("shadow") == 1, "shadow: StudyLog got one speaking count and one shadow event (%d, %d)" % [score_count(), event_count("shadow")])
	ok(find_label(sh, "스스로 '잘했어요'") != null, "shadow: the verdict says it was self-rated")
	var sm: Dictionary = ShadowScreen.summarize(sh.results)
	ok(int(sm["tried"]) == 1 and int(sm["passed"]) == 1 and int(sm["self_n"]) == 1 and int(sm["avg"]) == 0, "shadow: summarize counts the self-rated one but not in the average")
	ok(_score_requests() == 0, "shadow: still no /score request")
	sh.finish()
	await _frames(2)
	ok(sh.stage == "summary" and find_label(sh, "잘했어요 1개") != null and find_label(sh, "평균") == null, "shadow summary shows 잘했어요 and no average")
	sh.queue_free()
	await _frames(1)
	reached["shadow_none"] = true


func _test_phoneme_none() -> void:
	print("[weak-sound drill, score none]")
	_mode_none()
	_fresh_state()
	var ps := PhonemeScreen.new()
	add_child(ps)
	await _frames(2)
	ps.lang = "en"
	ps.phonemes = [{"p": "θ", "label": "th (θ)", "hint_ko": ""}]
	ps.cur_p = "θ"
	ps.items = [{"text": "Think about it.", "ko": "", "url": "", "kind": "sentence"}, {"text": "Thank you.", "ko": "", "url": "", "kind": "sentence"}]
	ps.start_drill()
	await _frames(3)
	ps.drill._on_recorded(rec)
	await _frames(3)
	ok(ps.drill.status == "self" and find_panel(ps) != null, "drill: recording shows the self-rate panel")
	ok(_score_requests() == 0, "drill: no /score request")
	var reasons: Array = card_reasons(ps)
	ok(reasons.has(SelfRatePanel.PHONEME_REASON) and not reasons.has(SelfRatePanel.PROSODY_REASON), "drill: phoneme card disabled with a reason, no prosody card in this drill: %s" % str(reasons))
	find_button(ps, "다시").pressed.emit()
	await _frames(3)
	ok(int(ps.results[0]["tries"]) == 0 and ps.attempts == 0, "drill: 다시 records nothing")
	ps.drill._on_recorded(rec)
	await _frames(3)
	find_button(ps, "잘했어요").pressed.emit()
	await _frames(3)
	ok(int(ps.results[0]["tries"]) == 1 and bool(ps.results[0]["success"]) and not bool(ps.results[0]["unavailable"]), "drill: 잘했어요 counts as a success")
	ok(find_label(ps, "스스로 '잘했어요'") != null and find_label(ps, "음소 분석을 쓸 수 없어요") == null, "drill: the verdict says self-rated, not 'analysis unavailable'")
	ok(score_count() == 1, "drill: StudyLog got one speaking count (%d)" % score_count())
	ps.finish()
	await _frames(2)
	ok(ps.stage == "summary" and event_count("drill") == 1 and find_label(ps, "잘했어요 (스스로 평가)") != null, "drill: summary says self-rated and the drill event is logged once")
	ok(_score_requests() == 0, "drill: still no /score request")
	ps.queue_free()
	await _frames(1)
	reached["phoneme_none"] = true


func _test_drill_none() -> void:
	print("[SpeakDrill alone, api_hook records every request]")
	_mode_none()
	_fresh_state()
	SpeakDrill.api_hook = Callable(self, "_drill_hook")
	var d := SpeakDrill.new("en", "drill")
	d.make_recorder("말하기")
	add_child(d)
	await _frames(2)
	d.set_target("Hello there.")
	d._on_recorded(rec)
	await _frames(3)
	ok(d.status == "self" and hook_calls.is_empty(), "SpeakDrill in score none: self state, zero requests through the hook")
	find_button(d, "잘했어요").pressed.emit()
	await _frames(3)
	ok(d.status == "self_ok" and score_count() == 1 and hook_calls.is_empty(), "잘했어요: self_ok, one count, still zero requests")
	d.set_target("Hello again.")
	ok(d.status == "idle", "a new target resets the drill")
	d.queue_free()
	SpeakDrill.api_hook = Callable()
	await _frames(1)
	reached["drill_none"] = true


func _test_pc_mode() -> void:
	print("[score pc: unchanged]")
	_mode_pc()
	_fresh_state()
	ok(not SelfRatePanel.needed() and not SelfRatePanel.phoneme_off(), "pc: needed() and phoneme_off() are false")
	var lv: LessonView = await _mk_lesson()
	lv._on_recorded(rec)
	ok(await wait_until(func() -> bool: return not lv.speak_result.is_empty()), "pc lesson: the score arrives")
	await _frames(2)
	ok(find_panel(lv) == null and disabled_cards(lv).is_empty(), "pc lesson: no self-rate panel and no disabled card")
	ok(_score_requests() == 1 and int(lv.speak_result.get("score", 0)) == int(score_fix["score"]), "pc lesson: exactly one /score request, the real score is shown")
	ok(find_label(lv, "발음 점수") != null, "pc lesson: the normal score panel is drawn")
	ok(score_count() == 1 and not SelfRatePanel.is_self_rated(lv.speak_result), "pc lesson: the scored result is counted once, not self-rated")
	lv.queue_free()
	await _frames(1)
	_fresh_state()
	var rv: ReviewView = await _mk_review()
	rv._on_recorded(rec)
	ok(await wait_until(func() -> bool: return not rv.score_result.is_empty()), "pc review: the score arrives")
	await _frames(2)
	ok(find_panel(rv) == null and not rv.self_good and _score_requests() == 1, "pc review: no panel, one /score request")
	ok(find_label(rv, "발음 점수") != null, "pc review: the normal score panel is drawn")
	rv.queue_free()
	await _frames(1)
	_fresh_state()
	SpeakDrill.api_hook = Callable(self, "_drill_hook")
	var d := SpeakDrill.new("en", "shadow")
	d.make_recorder()
	add_child(d)
	await _frames(2)
	d.set_target(TARGET)
	d._on_recorded(rec)
	ok(await wait_until(func() -> bool: return d.status == "ok"), "pc drill: scored through the hook")
	await _frames(2)
	var scored_reqs := 0
	for h in hook_calls:
		if str(h["path"]) == "/score":
			scored_reqs += 1
	ok(find_panel(d) == null and scored_reqs == 1, "pc drill: no panel, one /score request")
	d.queue_free()
	SpeakDrill.api_hook = Callable()
	await _frames(1)
	reached["pc_mode"] = true


func _test_phone_mode() -> void:
	print("[score phone: unchanged]")
	_mode_phone_score()
	_fresh_state()
	ok(Route.decide("POST", "/score", {}) == "phone" and not SelfRatePanel.needed(), "phone handler present: Route says phone, needed() false")
	var lv: LessonView = await _mk_lesson()
	lv._on_recorded(rec)
	ok(await wait_until(func() -> bool: return not lv.speak_result.is_empty()), "phone lesson: the handler's score arrives")
	await _frames(2)
	ok(find_panel(lv) == null and _score_requests() == 1 and not SelfRatePanel.is_self_rated(lv.speak_result), "phone lesson: no panel, one /score request, a real result")
	ok(find_label(lv, "발음 점수") != null, "phone lesson: the normal score panel is drawn")
	lv.queue_free()
	await _frames(1)
	reached["phone_mode"] = true


func _test_caps() -> void:
	print("[Route.caps]")
	_mode_none()
	var caps: Dictionary = Route.caps()
	ok(str(caps["items"]["score"]["use"]) == "none", "Route.caps score use is none in the self-rate setup")
	ok(SelfRatePanel.needed() == (str(caps["items"]["score"]["use"]) == "none"), "needed() agrees with Route.caps")
	_mode_pc()
	var caps2: Dictionary = Route.caps()
	ok(str(caps2["items"]["score"]["use"]) == "pc" and not SelfRatePanel.needed(), "PC app: score use is pc and needed() is false")
	reached["caps"] = true
