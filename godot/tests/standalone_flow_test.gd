extends Node
## A8 (docs/phone_standalone_design.md §8 A8-4, A8-5): the phone with NO PC, start to end, through the real screens.
##   godot --headless --path <project> res://tests/standalone_flow_test.tscn -- --phone --api=http://127.0.0.1:9
## `--api=` is a closed port: anything that still tried the PC would count in Api.sent_count. The run needs both
## arguments; without them the first check fails (it would not prove anything).
## Walks: lesson (start -> answers -> result), review (typed answer -> rating), dictation, shadowing (sentences and
## listening through a fake system voice, English and Japanese), speaking (self-rating widget instead of a score),
## mission in script mode, English reading analysis (+ glosses and examples). The last check of every part is a flag
## (ok "part ran to its end"): a script error that stops a part early cannot end as "0 failed".
## Then: Api.sent_count == 0 (printed as `sent_count 0`), and A8-4: none of the new prefs of §5.4 is in SyncDoc.SHARED_PREFS.
## Files: only user://test_a8/ (prefs, progress, study log, reading folder); the real files are never opened.
## Last line: "== standalone_flow_test: N passed, M failed ==", exit code 1 on any failure.

const DIR := "user://test_a8"
const SCREEN := Vector2i(412, 915)
const PARTS := ["lesson", "review", "dictation", "shadow", "speak", "mission", "reading", "prefs"]
## The prefs keys of §5.4 (docs/phone_standalone_design.md): per device, may hold secrets, never synced.
const NEW_PREFS := ["standalone_ok", "route_mode", "tts_engine", "tts_sys_voice_en", "tts_sys_voice_ja", "stt_model_en",
	"stt_model_ja", "ai_local", "ai_preset", "ai_model", "lesson_cursor"]

var passed: int = 0
var failed: int = 0
var _flags: Dictionary = {}
var _sent0: int = 0
var _served0: int = 0
var _holder: Control = null
var _fake: SysFake = null
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_adapter: SystemTts.Adapter
var _old_mode: String
var _old_base_url: String


## A system voice engine that answers at once: every speak() is recorded and "heard" (START then END).
class SysFake:
	extends SystemTts.Adapter
	var voices: Array = []
	var speaks: Array = [] ## {text, voice}
	var cbs: Dictionary = {}
	var last: int = -1
	func available() -> bool:
		return true
	func get_voices() -> Array:
		return voices
	func speak(t: String, v: String, _vol: int, _p: float, _r: float, id: int, _i: bool) -> void:
		speaks.append({"text": t, "voice": v})
		last = id
		var s: Callable = cbs.get(DisplayServer.TTS_UTTERANCE_STARTED, Callable())
		if s.is_valid():
			s.call(id)
		var e: Callable = cbs.get(DisplayServer.TTS_UTTERANCE_ENDED, Callable())
		if e.is_valid():
			e.call(id)
	func stop() -> void:
		pass
	func is_speaking() -> bool:
		return false
	func set_callback(kind: int, cb: Callable) -> void:
		cbs[kind] = cb
	func spoke(text: String, lang_prefix: String = "") -> bool:
		for s in speaks:
			if str(s["text"]) == text and (lang_prefix == "" or str(s["voice"]).begins_with(lang_prefix)):
				return true
		return false


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


func _wait_until(cond: Callable, timeout: float = 8.0) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _ready() -> void:
	print("== standalone_flow_test start ==")
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_adapter = SystemTts.adapter
	_old_mode = Route.mode
	_old_base_url = Api.base_url
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	_cleanup_files()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Store.load_prefs()
	Store.progress = Progress.blank()
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	Store.prefs["standalone_ok"] = true ## what [PC 없이 시작] saves
	Backend._starting = true # nothing may start an engine or look for a PC
	Backend.set_process(false)
	Sheet.animate = false
	Route.mode = "auto" # the mode [PC 없이 시작] leaves
	Route.pc_ready_hook = Callable()
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	get_window().min_size = Vector2i.ZERO
	get_window().size = SCREEN
	await _frames(2)
	UiBoot.apply(get_window(), "light", 1.0)
	PhoneLayout.install_touch_scroll(get_tree())
	_holder = Control.new()
	_holder.size = Vector2(SCREEN)
	add_child(_holder)
	_fake = SysFake.new()
	_fake.voices = [
		{"name": "English US", "id": "en-us-x-a", "language": "en-US"},
		{"name": "Nihongo", "id": "ja-jp-x-c", "language": "ja-JP"},
	]
	SystemTts.adapter = _fake
	await _frames(2)

	_test_setup()
	_sent0 = Api.sent_count
	_served0 = LocalApi.served_count
	await _test_lesson()
	await _test_review()
	await _test_dictation()
	await _test_shadow()
	await _test_speak()
	await _test_mission()
	await _test_reading()
	_test_prefs_not_synced()
	for k in PARTS:
		ok(bool(_flags.get(k, false)), "part '%s' ran to its end" % k)
	print("sent_count %d (at the start %d)" % [Api.sent_count, _sent0])
	ok(Api.sent_count == _sent0 and Api.sent_count == 0, "sent_count %d: not one request left the phone for the PC" % Api.sent_count)
	ok(LocalApi.served_count - _served0 >= 8, "the phone's own handlers served %d requests (lesson, practice, missions, reading, ...)" % (LocalApi.served_count - _served0))
	ok(Api.active_count == 0, "no request left in flight (active_count=%d)" % Api.active_count)

	Tts.stop()
	SystemTts.adapter = _old_adapter
	Api.base_url = _old_base_url
	Route.mode = _old_mode
	Route.pc_ready_hook = Callable()
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	_cleanup_files()
	print("== standalone_flow_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _cleanup_files() -> void:
	_rm_tree(ProjectSettings.globalize_path(DIR))


func _rm_tree(g: String) -> void:
	if not DirAccess.dir_exists_absolute(g):
		return
	for f in DirAccess.get_files_at(g):
		DirAccess.remove_absolute(g.path_join(f))
	for d in DirAccess.get_directories_at(g):
		_rm_tree(g.path_join(d))
	DirAccess.remove_absolute(g)


func _add_view(v: Control) -> Control:
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_holder.add_child(v)
	return v


func _drop_view(v: Node) -> void:
	if v != null and is_instance_valid(v):
		_holder.remove_child(v)
		v.queue_free()


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func _has_self_rate(root: Node) -> SelfRatePanel:
	for n in root.find_children("*", "VBoxContainer", true, false):
		if n is SelfRatePanel:
			return n
	return null


func _fake_rec() -> Dictionary:
	var wav: PackedByteArray = WavUtil.to_wav_bytes(WavUtil.sine(0.6, 16000))
	return {"ok": true, "silent": false, "duration": 0.6, "b64": Marshalls.raw_to_base64(wav), "wav": wav, "owner": 0}


# ---------------------------------------------------------------- the situation of the run

func _test_setup() -> void:
	print("[setup]")
	ok(Platform.is_phone(), "run with --phone: Platform.is_phone()")
	ok(Api.base_url == "http://127.0.0.1:9", "run with --api=http://127.0.0.1:9 (closed port, no PC): '%s'" % Api.base_url)
	ok(not Backend.is_ready(), "no PC is ready")
	ok(bool(Store.prefs.get("standalone_ok", false)) and Route.mode == "auto", "standalone_ok == true, Route.mode 'auto'")
	ok(Tts.engine_now() == "system", "the voice engine is the phone's own (Tts.engine_now() '%s')" % Tts.engine_now())
	for item in [["POST", "/lesson"], ["POST", "/reading/analyze"], ["POST", "/reading/gloss"], ["GET", "/examples"], ["GET", "/practice/sentences"],
			["GET", "/missions"], ["POST", "/missions/check"]]:
		ok(Route.decide(item[0], item[1], {}) == "phone", "Route: %s %s -> phone" % [item[0], item[1]])
	ok(Route.decide("GET", "/curriculum", {}) == "phone", "Route: GET /curriculum -> phone (the PC is not ready)")


# ---------------------------------------------------------------- lesson

func _test_lesson() -> void:
	print("[lesson: start -> answers -> result]")
	var lv := LessonView.new()
	_add_view(lv)
	await _frames(2)
	lv.lang = "en"
	lv.start_lesson()
	ok(lv.status == "loading", "start: loading state while the phone builds the lesson")
	await _wait_until(func() -> bool: return lv.status == "run")
	ok(lv.status == "run" and lv.exercises.size() >= 4, "lesson started: %d exercises, err '%s'" % [lv.exercises.size(), lv.err])
	ok(Api.sent_count == _sent0, "...no request left the phone")
	var n: int = lv.exercises.size()
	# A speak exercise draws an intonation card that asks /prosody. That has no phone handler and, in "auto", is tried at the
	# (closed) PC address once -- by design (§4.2). "이 폰에서만" never asks the PC: the answers run in that mode.
	Route.mode = "phone"
	var answered := 0
	var skipped := 0
	var wrong_once := false
	var guard := 0
	while lv.status == "run" and guard < 30:
		guard += 1
		var e: Dictionary = lv.cur()
		var t: String = str(e["type"])
		if t == "speak":
			lv._skip_speak() # speaking is walked below (self-rating); a skip is a legal answer
			skipped += 1
			continue
		if t == "build":
			var ids: Array = []
			var ans: Array = e["answer"]
			for tok in ans:
				for tile in e["tiles"]:
					if str(tile["t"]) == str(tok) and not ids.has(int(tile["i"])):
						ids.append(int(tile["i"]))
						break
			if not wrong_once:
				wrong_once = true
				ids.reverse() # one wrong answer on purpose (adds a review card)
				ids = ids.slice(0, maxi(1, ids.size() - 1))
			lv.built = ids
		else:
			lv.picked = int(e["answer"])
		lv.check_answer()
		answered += 1
		await _frames(1)
		lv.next_exercise()
		await _frames(1)
	Route.mode = "auto"
	ok(lv.status == "done", "result screen reached (status '%s', %d answered, %d skipped of %d)" % [lv.status, answered, skipped, n])
	ok(lv.results.size() == n and answered >= 1, "every exercise has a result")
	ok(Store.stat("en", "lessons") == 1, "the lesson is counted in the progress (lessons == 1)")
	ok(Store.xp("en") >= lv.ok_count * 10 and lv.ok_count >= 1, "XP given for the right answers (ok %d)" % lv.ok_count)
	ok(StudyLog.is_dirty(), "the study log has the lesson")
	ok(Api.sent_count == _sent0 and lv.err == "", "lesson: no request left the phone, no error")
	_drop_view(lv)
	_flags["lesson"] = true


# ---------------------------------------------------------------- review

func _test_review() -> void:
	print("[review: typed answer -> rating]")
	Store.add_review([{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴 좀 볼 수 있을까요?", "reading": "", "note": ""}])
	ok(Store.review_for("en").size() >= 1 and Store.due_count("en") >= 1, "a review card is due (%d cards)" % Store.review_for("en").size())
	var rv := ReviewView.new()
	_add_view(rv)
	await _frames(2)
	rv.lang = "en"
	rv._start()
	await _frames(2)
	ok(rv.status == "run" and rv.items.size() >= 1, "review session started (%d items)" % rv.items.size())
	var it: Dictionary = rv.items[0]
	var id0: String = str(it["id"])
	var reps0: int = int(it.get("reps", 0))
	rv.typed_text = str(it["target"])
	rv._check_typed()
	await _frames(2)
	ok(rv.checked and int(rv.typed_sim.get("score", 0)) == 100, "the typed answer is judged on the phone (score %d)" % int(rv.typed_sim.get("score", 0)))
	var rating: Button = null
	for b in rv.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("좋음") and (b as Button).is_visible_in_tree():
			rating = b
	ok(rating != null, "the rating buttons are shown")
	if rating != null:
		rating.pressed.emit()
	await _frames(2)
	var done_item: Dictionary = {}
	for c in Store.progress["review"]:
		if str(c["id"]) == id0:
			done_item = c
	ok(rv.done_count == 1 and not done_item.is_empty() and int(done_item["reps"]) == reps0 + 1, "the rating was applied (reps %d)" % int(done_item.get("reps", -1)))
	ok(Api.sent_count == _sent0, "review: no request left the phone")
	_drop_view(rv)
	_flags["review"] = true


# ---------------------------------------------------------------- dictation

func _test_dictation() -> void:
	print("[dictation]")
	var ds := DictationScreen.new()
	_add_view(ds)
	await _frames(2)
	ds.open("en")
	await _wait_until(func() -> bool: return ds.stage != "loading")
	ok(ds.stage == "run" and ds.sentences.size() >= 1, "sentences received from the phone (stage '%s', %d sentences, '%s')" % [ds.stage, ds.sentences.size(), ds.err_text])
	var text: String = str(ds.current().get("text", ""))
	var n0: int = _fake.speaks.size()
	ds.listen()
	await _frames(3)
	ok(_fake.speaks.size() > n0 and _fake.spoke(text, "en"), "listening: the sentence is spoken by the English system voice")
	ds.set_typed(text)
	ok(ds.check(), "the answer is checked")
	var r: Dictionary = ds.results[0]
	ok(int(r["tries"]) == 1 and int(r["score"]) == 100 and bool(r["passed"]), "the exact sentence passes with score 100 (%d)" % int(r["score"]))
	ds.next_sentence()
	ds.set_typed("zzz")
	ds.check()
	ds.finish()
	await _frames(2)
	ok(ds.stage == "summary" and ds.tried_count() == 2, "summary reached (2 tried)")
	ok(Api.sent_count == _sent0, "dictation: no request left the phone")
	_drop_view(ds)
	_flags["dictation"] = true


# ---------------------------------------------------------------- shadowing

func _test_shadow() -> void:
	print("[shadowing: sentences and listening]")
	var sh := ShadowScreen.new()
	_add_view(sh)
	await _frames(2)
	sh.open("en", {"source": "week"})
	await _wait_until(func() -> bool: return sh.stage != "loading")
	ok(sh.stage == "run" and sh.sentences.size() >= 1 and sh.drill != null, "English sentences received (stage '%s', %d, '%s')" % [sh.stage, sh.sentences.size(), sh.err_text])
	var text: String = str(sh.current().get("text", ""))
	var n0: int = _fake.speaks.size()
	sh.drill.listen()
	await _frames(3)
	ok(_fake.speaks.size() > n0 and _fake.spoke(text, "en-us"), "listening (English): spoken with the English system voice")
	sh.change_lang("ja")
	sh.start_session("week")
	await _wait_until(func() -> bool: return sh.stage != "loading")
	ok(sh.stage == "run" and sh.sentences.size() >= 1 and sh.lang == "ja", "Japanese sentences received (stage '%s', %d)" % [sh.stage, sh.sentences.size()])
	var jtext: String = str(sh.current().get("text", ""))
	sh.drill.listen()
	await _frames(3)
	ok(_fake.spoke(jtext, "ja-jp"), "listening (Japanese): spoken with the Japanese system voice")
	ok(Api.sent_count == _sent0, "shadowing: no request left the phone")
	_drop_view(sh)
	_flags["shadow"] = true


# ---------------------------------------------------------------- speaking: self-rating widget

func _test_speak() -> void:
	print("[speaking: the self-rating widget replaces the score]")
	# "이 폰에서만" (never the PC) and an unpaired phone (no address) both give "no place to score"
	Route.mode = "phone"
	ok(SelfRatePanel.needed(), "mode '이 폰에서만': /score has no place (needed)")
	Route.mode = "auto"
	var keep_url: String = Api.base_url
	Api.base_url = ""
	ok(SelfRatePanel.needed(), "an unpaired phone (no PC address): /score has no place (needed)")
	Api.base_url = keep_url
	Route.mode = "phone"

	var lv := LessonView.new()
	_add_view(lv)
	await _frames(2)
	lv.lang = "en"
	lv.load_exercises([{"type": "speak", "text": "Can I have a menu?", "ko": "메뉴 좀 볼 수 있을까요?", "reading": ""}] as Array)
	await _frames(2)
	lv._on_recorded(_fake_rec())
	await _frames(3)
	var sp: SelfRatePanel = _has_self_rate(lv)
	ok(sp != null and not lv.scoring, "lesson: the self-rating widget is shown, no scoring")
	var good: Button = _find_button(lv, "잘했어요")
	ok(good != null, "lesson: [잘했어요] is there")
	if good != null:
		good.pressed.emit()
	await _frames(2)
	ok(SelfRatePanel.is_self_rated(lv.speak_result), "lesson: [잘했어요] records a self-rated result")
	_drop_view(lv)

	var sh := ShadowScreen.new()
	_add_view(sh)
	await _frames(2)
	sh.open("en", {"source": "week"})
	await _wait_until(func() -> bool: return sh.stage != "loading")
	ok(sh.stage == "run" and sh.drill != null, "shadowing: running")
	if sh.drill != null:
		sh.drill._on_recorded(_fake_rec())
		await _frames(3)
		ok(sh.drill.status == "self" and _has_self_rate(sh) != null, "shadowing: status 'self' with the self-rating widget")
		var again: Button = _find_button(sh, "다시")
		ok(again != null, "shadowing: [다시] is there")
	_drop_view(sh)
	ok(Api.sent_count == _sent0, "speaking: no /score or /prosody request left the phone")
	Route.mode = "auto"
	_flags["speak"] = true


# ---------------------------------------------------------------- mission (script mode)

func _test_mission() -> void:
	print("[mission: script mode]")
	var ms := MissionScreen.new()
	_add_view(ms)
	await _frames(3)
	ms.open("en")
	await _wait_until(func() -> bool: return ms.status == "list")
	ok(ms.status == "list" and ms.missions.size() >= 1, "mission list from the phone (%d missions, '%s')" % [ms.missions.size(), ms.list_note])
	ms._select("cafe_order")
	ok(ms.status == "brief" and str(ms.mission.get("id", "")) == "cafe_order", "brief of 'cafe_order'")
	var sb: Button = _find_button(ms, "대본 모드로 연습")
	ok(sb != null and not sb.disabled, "[대본 모드로 연습] is offered")
	if sb != null:
		sb.pressed.emit()
	await _frames(3)
	ok(ms.status == "talk" and ms.mode == "script" and ms.msgs.size() == 1, "script mode started with the first line")
	var lines: Array = ms._script()
	var guard := 0
	while ms.status == "talk" and guard < 12:
		guard += 1
		var idx: int = int(ms.script_state["idx"])
		ms._input.text = str((lines[mini(idx, lines.size() - 1)] as Dictionary)["model"])
		ms._send_message()
		await _wait_until(func() -> bool: return ms.status != "wait")
		await _frames(1)
	ok(ms.status == "result", "result reached by saying the model lines (%d turns)" % ms.turns)
	ok(MissionLogic.count_done(ms._goals(), ms.done) >= 3, "goals reached by the phone's rule check (%d of %d)" % [MissionLogic.count_done(ms._goals(), ms.done), ms._goals().size()])
	ok(ms.fb_state == "none", "no AI feedback was asked for")
	ok(Api.sent_count == _sent0, "mission: no request left the phone")
	_drop_view(ms)
	_flags["mission"] = true


# ---------------------------------------------------------------- reading (English)

func _test_reading() -> void:
	print("[reading: English analysis]")
	var rd := ReadingView.new()
	rd.storage_dir = DIR.path_join("reading")
	_add_view(rd)
	await _frames(2)
	var d: Dictionary = rd.new_doc("A8", "en", "I like coffee. She drinks tea every morning.")
	rd.save_doc(d)
	rd.open_doc(d)
	await _wait_until(func() -> bool: return not rd.analyzing and rd.tokens.size() > 0)
	ok(rd.mode == "reader" and rd.tokens.size() >= 8 and rd.analyze_error == "", "analysis from the phone (%d tokens, error '%s')" % [rd.tokens.size(), rd.analyze_error])
	ok(rd.lemmas.size() >= 4, "words found (%d lemmas)" % rd.lemmas.size())
	await _wait_until(func() -> bool: return rd.gloss_total == 0 and rd.gloss_pending.is_empty(), 6.0)
	var key: String = ""
	for k in rd.lemmas.keys():
		if str(k) == "coffee":
			key = str(k)
	ok(key != "", "the word 'coffee' is in the text")
	if key != "":
		var ti: int = int((rd.lemmas[key] as Dictionary)["tok"])
		rd.select_token(ti)
		await _wait_until(func() -> bool: return rd.examples.has("en|" + key), 4.0)
		ok(rd.selected == ti, "a word can be opened")
	ok(Api.sent_count == _sent0, "reading: no request left the phone")
	_drop_view(rd)
	_flags["reading"] = true


# ---------------------------------------------------------------- A8-4

## true when `keys` and `shared` (a Dictionary whose keys are the synced settings) share a key.
static func overlap(shared: Dictionary, keys: Array) -> Array:
	var hit: Array = []
	for k in keys:
		if shared.has(k):
			hit.append(k)
	return hit


func _test_prefs_not_synced() -> void:
	print("[A8-4: new prefs are not synced]")
	ok(NEW_PREFS.size() == 11, "the list holds the 11 keys of §5.4")
	var shared: Dictionary = SyncDoc.SHARED_PREFS
	ok(shared.size() >= 1, "SyncDoc.SHARED_PREFS is read (%d keys)" % shared.size())
	var hit: Array = overlap(shared, NEW_PREFS)
	ok(hit.is_empty(), "no new pref is in SyncDoc.SHARED_PREFS (overlap %s)" % str(hit))
	ok(overlap({"route_mode": 1}, NEW_PREFS) == ["route_mode"] and overlap({"daily_goal_min": 1}, NEW_PREFS).is_empty(), "the overlap check itself finds a shared key and passes a clean set")
	# the document a sync writes does not carry them either
	var pk: Dictionary = SyncDoc.blank_replica()["prefs"]
	ok(pk.size() == shared.size() and overlap(pk, NEW_PREFS).is_empty(), "a fresh sync document (%d prefs) has none of them" % pk.size())
	_flags["prefs"] = true
