extends Node
## Layout scan of the screens that the phone_layout_test walk (shots_phone.gd) does not reach: 기록 (stats), 연습 허브,
## 쉐도잉, 받아쓰기, 약한 소리 (phoneme), 미션 (docs/ui_redesign_design.md §8.4: Wn-2 touch size and Wn-3 text 150%).
## Every state is built from fixtures and fake requests (SpeakDrill.api_hook, MissionScreen.http); nothing leaves the
## machine. Like phone_layout_test it counts, per state, controls that stick out of the screen (LAYOUT_OVERFLOW_COUNT)
## and touch targets below the minimum (TOUCH_SMALL_COUNT).
##   phone: godot --headless --path <project> res://tests/screens_scan_test.tscn -- --phone [--touch-min=47.5] [--font-scale=1.5] [--dark] [--only=<prefix>]
##   PC:    godot --headless --path <project> res://tests/screens_scan_test.tscn
## --only=<prefix> keeps the states whose name starts with it (stats, practice, shadow, dictation, phoneme, mission);
## the run fails when none matches. Files: only user://test_w4_sweep_* (removed at the end).
## Last line: "== screens_scan: N passed, M failed ==", exit code 1 on any failure.

const FIX := "res://tests/"
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const P_PROGRESS := "user://test_w4_sweep_progress.json"
const P_PREFS := "user://test_w4_sweep_prefs.json"
const P_LOG := "user://test_w4_sweep_studylog.json"

class FakeCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}

	func wait() -> Dictionary:
		if done:
			return result
		return await finished

	func cancel() -> void:
		complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true})

	func complete(res: Dictionary) -> void:
		if done:
			return
		done = true
		result = res
		finished.emit(res)

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _w: float = 412.0
var _touch_min: float = 43.5
var _only: String = ""
var _dark: bool = false
var _scale_arg: String = ""
var main_node: Control
var _overflow: Array[String] = []
var _small: Array[String] = []
var _matched: int = 0
var _scanned: int = 0
var _table: Array = []
var _old: Array = []


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


func _wait_until(cond: Callable, max_frames: int = 240) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _json(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(FIX + name))


func _ready() -> void:
	_phone = Platform.is_phone()
	var scheme := "light"
	var scale := 1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--touch-min="):
			_touch_min = a.substr(12).to_float() if a.substr(12).is_valid_float() else 43.5
		elif a.begins_with("--only="):
			_only = a.substr(7)
		elif a == "--dark":
			scheme = "dark"
			_dark = true
		elif a.begins_with("--font-scale="):
			_scale_arg = a.substr(13)
			scale = _scale_arg.to_float() if _scale_arg.is_valid_float() else 1.0
	print("== screens_scan start (%s) touch_min=%s only='%s' dark=%s font_scale='%s' ==" % ["phone" if _phone else "pc", _touch_min, _only, _dark, _scale_arg])
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(2)
	_w = get_viewport().get_visible_rect().size.x
	UiBoot.apply(get_window(), scheme, scale)
	print("applied: scheme=%s font_scale=%s default font size=%d" % [Pal.scheme(), Ds.font_scale, ThemeDB.get_project_theme().default_font_size])
	_old = [Store.prefs_path, Store.progress_path, StudyLog.path, Store.curriculum_cache_path, Api.base_url]
	Store.prefs_path = P_PREFS
	Store.progress_path = P_PROGRESS
	Store.curriculum_cache_path = "user://test_w4_sweep_curriculum.json"
	StudyLog.path = P_LOG
	for f in [P_PREFS, P_PROGRESS, P_LOG]:
		_rm(f)
	Api.base_url = "http://127.0.0.1:9" if not _phone else Api.base_url # a closed port: nothing reaches the user's engine (8770)
	Store.load_prefs()
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	var D: int = Plan.days_from_civil(2026, 10, 16)
	Store.progress["xp"]["en"] = 120
	for off in [-2, -1, 0]:
		Store.progress["days"][Plan.days_to_iso(D + off)] = {"en": true}
	Store.add_review([
		{"lang": "en", "target": "Can I have a menu?", "ko": "메뉴판 좀 주실래요?", "note": "Can I ~?"},
		{"lang": "en", "target": "I'd like a large coffee, please.", "ko": "큰 사이즈 커피 한 잔 주세요.", "note": ""},
	])
	var f := FileAccess.open(P_LOG, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(FIX + "sample_studylog.json"))
	f.close()
	StudyLog.today_override = D
	StudyLog.load_from_disk()
	Backend._starting = true # never launch or poll the engine
	Backend.set_process(false)
	Sheet.animate = false
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")
	main_node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main_node)
	await _frames(20)
	main_node._splash_dismissed = true
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "llm_model": "qwen3:8b", "score": true, "phoneme": true}
	Backend._set_status(Backend.Status.READY)
	main_node.call("add_tab", "practice", "연습", PracticeView.new(), "연습", "review")
	main_node.call("add_tab", "stats", "기록", StatsView.new(), "기록", "reading")
	await _frames(6)

	await _selfcheck()
	await _walk()

	if _only != "":
		ok(_matched >= 1, "--only=%s matched %d states" % [_only, _matched])
	print("")
	print("---- per state: controls scanned | overflow | too small (touch min %s)" % _touch_min)
	for r in _table:
		print("SWEEP %-20s controls=%-4d overflow=%-3d small=%d" % [r[0], r[1], r[2], r[3]])
	for line in _overflow.slice(0, 40):
		print("  overflow  ", line)
	for line in _small.slice(0, 60):
		print("  small     ", line)
	print("LAYOUT_OVERFLOW_COUNT ", _overflow.size())
	print("TOUCH_SMALL_COUNT ", _small.size())
	ok(_scanned > 0, "the scan looked at %d visible controls in %d states" % [_scanned, _matched])
	ok(_overflow.size() == 0, "Wn-3: LAYOUT_OVERFLOW_COUNT 0")
	ok(_small.size() == 0, "Wn-2: TOUCH_SMALL_COUNT 0 (touch min %s)" % _touch_min)

	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	main_node.queue_free()
	await _frames(3)
	for f2 in [P_PREFS, P_PROGRESS, P_LOG, P_LOG + ".tmp", P_PROGRESS + ".tmp", P_PREFS + ".tmp", "user://test_w4_sweep_curriculum.json"]:
		_rm(f2)
	StudyLog.load_from_disk()
	StudyLog.today_override = -1
	Store.prefs_path = _old[0]
	Store.progress_path = _old[1]
	StudyLog.path = _old[2]
	Store.curriculum_cache_path = _old[3]
	Api.base_url = _old[4]
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	print("== screens_scan: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------------------------------------------------------------- fake requests

func _res(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false}


func _bad(code: int, msg: String) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": msg, "cancelled": false}


func _score_fixture(score: int) -> Dictionary:
	var d: Dictionary = (_json("sample_score_en_ph.json") as Dictionary).duplicate(true)
	d["score"] = score
	for u in d["units"]:
		for p in u["ph"]:
			if p["p"] == "θ":
				p["ok"] = false
				p["heard"] = "s"
	return d


## SpeakDrill.api_hook: (method, path, body) -> {ok, code, data, error}
func _hook(_method: String, path: String, _body: Variant) -> Variant:
	if path.begins_with("/practice/ping"):
		return _res({"ok": true, "practice": 1, "missions": 1, "tatoeba": true})
	if path.begins_with("/practice/sentences"):
		return _res(_json("sample_practice_sentences_en.json"))
	if path.begins_with("/practice/phonemes"):
		return _res(_json("sample_phoneme_list.json"))
	if path.begins_with("/practice/phoneme"):
		return _res(_json("sample_phoneme_th.json"))
	if path.begins_with("/score"):
		return _res(_score_fixture(40))
	if path.begins_with("/prosody"):
		return _res(_json("sample_prosody_en_after.json"))
	return _bad(404, "알 수 없는 경로예요.")


func _tts_hook(_text: String, _l: String, _speed: float, _voice: String) -> Variant:
	return null


## MissionScreen.http: (method, path, body, timeout) -> ApiCall-like object
func _mission_http(_method: String, path: String, _body: Variant, _timeout: float) -> Variant:
	var p: String = path.split("?")[0]
	var fc := FakeCall.new()
	var res: Dictionary
	match p:
		"/missions":
			res = _res(_json("sample_mission_list.json"))
		"/chat":
			res = _res(_json("sample_mission_chat.json"))
		"/missions/check":
			res = _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
		"/feedback":
			res = _res(_json("sample_mission_feedback.json"))
		"/missions/judge":
			res = _res(_json("sample_mission_judge.json"))
		_:
			res = _bad(404, "없는 경로예요.")
	_complete_later(fc, res)
	return fc


func _complete_later(fc: FakeCall, res: Dictionary) -> void:
	await get_tree().process_frame
	fc.complete(res)


# ---------------------------------------------------------------- scan

func _controls(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Window:
			continue
		if c is Control and (c as Control).visible:
			out.append(c)
		_controls(c, out)


func _text_of(c: Control) -> String:
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is RichTextLabel:
		return (c as RichTextLabel).get_parsed_text()
	return ""


func _scan(state: String) -> void:
	if _only != "" and not state.begins_with(_only):
		return
	_matched += 1
	var all: Array = []
	_controls(main_node, all)
	var n := 0
	var o := 0
	var s := 0
	for c in all:
		var ctl := c as Control
		if not ctl.is_visible_in_tree():
			continue
		var r: Rect2 = ctl.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		n += 1
		var path: String = str(main_node.get_path_to(ctl))
		if r.end.x > _w + 0.5 or r.position.x < -0.5:
			o += 1
			_overflow.append("%s: %s %s end.x=%.1f" % [state, path, ctl.get_class(), r.end.x])
		if _phone and (ctl is BaseButton or ctl is LineEdit or ctl is Slider):
			var min_h: float = 40.0 if ctl is Slider else _touch_min
			var min_w: float = 0.0 if ctl is Slider else _touch_min
			if r.size.y < min_h or r.size.x < min_w:
				s += 1
				_small.append("%s: %s %s %s (%.0fx%.0f)" % [state, path, ctl.get_class(), _text_of(ctl).left(24), r.size.x, r.size.y])
	_scanned += n
	_table.append([state, n, o, s])


## The scan must fail on a wrong layout: a 600 px wide control and a bare 20 px / 47 px target are reported.
func _selfcheck() -> void:
	var o0: int = _overflow.size()
	var s0: int = _small.size()
	var t0: int = _table.size()
	var m0: int = _matched
	var sc0: int = _scanned
	var only0: String = _only
	_only = ""
	var box := VBoxContainer.new()
	var wide := ColorRect.new()
	wide.custom_minimum_size = Vector2(_w + 200.0, 10)
	box.add_child(wide)
	var tiny := BaseButton.new()
	tiny.custom_minimum_size = Vector2(60, 20)
	box.add_child(tiny)
	var b47 := BaseButton.new()
	b47.custom_minimum_size = Vector2(120, 47)
	box.add_child(b47)
	main_node.add_child(box)
	await _frames(3)
	_scan("selfcheck")
	var got_o: int = _overflow.size() - o0
	var small_lines: Array = _small.slice(s0)
	box.queue_free()
	_overflow.resize(o0)
	_small.resize(s0)
	_table.resize(t0)
	_matched = m0
	_scanned = sc0
	_only = only0
	ok(got_o >= 1, "self-check: a control wider than the screen is reported as overflow (%d)" % got_o)
	if _phone:
		var has20 := false
		var has47 := false
		for l in small_lines:
			has20 = has20 or str(l).contains("x20)")
			has47 = has47 or str(l).contains("x47)")
		ok(has20, "self-check: a 20 px high touch target is reported as small")
		ok(has47 == (_touch_min > 47.0), "self-check: a 47 px high touch target is reported as small exactly when --touch-min is above 47 (%s)" % has47)


# ---------------------------------------------------------------- states

func _state(name: String) -> void:
	await _frames(12)
	for pb in main_node.find_children("*", "ProgressBar", true, false):
		if (pb as ProgressBar).indeterminate:
			(pb as ProgressBar).indeterminate = false
	await _frames(3)
	_scan(name)


func _walk() -> void:
	var views: Dictionary = main_node.views
	# ---------------------------------------------------------------- 기록
	main_node.show_view("stats")
	(views["stats"] as StatsView).refresh()
	await _state("stats")

	# ---------------------------------------------------------------- 연습 허브
	main_node.show_view("practice")
	var pv: PracticeView = views["practice"]
	await _wait_until(func() -> bool: return pv.card_kinds().size() >= 3)
	await _state("practice_hub")

	# ---------------------------------------------------------------- 쉐도잉
	pv.open_screen("shadow", {"source": "week"})
	var sh: ShadowScreen = pv.current_screen() as ShadowScreen
	var got: bool = await _wait_until(func() -> bool: return sh != null and sh.stage == "run")
	ok(got, "shadow: the sentences loaded (stage %s)" % [sh.stage if sh != null else "none"])
	await _state("shadow_run")
	if got:
		sh.drill._on_recorded(FAKE_REC)
		await _wait_until(func() -> bool: return sh.drill.status == "ok")
		await _state("shadow_scored")
		for i in 8:
			if sh.stage == "summary":
				break
			sh.next_sentence()
			await _frames(1)
		await _state("shadow_summary")
	pv.go_back()
	await _frames(4)

	# ---------------------------------------------------------------- 받아쓰기
	pv.open_screen("dictation")
	var dc: DictationScreen = pv.current_screen() as DictationScreen
	got = await _wait_until(func() -> bool: return dc != null and dc.stage == "run")
	ok(got, "dictation: the sentences loaded (stage %s)" % [dc.stage if dc != null else "none"])
	await _state("dictation_run")
	if got:
		dc.set_typed("I would like a large cofee")
		dc.check()
		await _state("dictation_checked")
		dc.finish()
		await _state("dictation_summary")
	pv.go_back()
	await _frames(4)

	# ---------------------------------------------------------------- 약한 소리
	pv.open_screen("phoneme")
	var ps: PhonemeScreen = pv.current_screen() as PhonemeScreen
	got = await _wait_until(func() -> bool: return ps != null and ps.stage == "list")
	ok(got, "phoneme: the sound list loaded (stage %s)" % [ps.stage if ps != null else "none"])
	await _state("phoneme_list")
	if got:
		ps.open("en", {"p": "θ"})
		got = await _wait_until(func() -> bool: return ps.stage == "detail")
		ok(got, "phoneme: the explanation of θ opened (stage %s)" % ps.stage)
		await _state("phoneme_detail")
		if got:
			ps.start_drill()
			got = await _wait_until(func() -> bool: return ps.stage == "drill" and ps.drill != null)
			await _state("phoneme_drill")
			if got:
				ps.drill._on_recorded(FAKE_REC)
				await _wait_until(func() -> bool: return ps.drill.status == "ok")
				await _state("phoneme_scored")
	pv.go_back()
	await _frames(4)
	pv.go_back()
	await _frames(4)

	# ---------------------------------------------------------------- 미션
	pv.open_screen("mission")
	var ms: MissionScreen = pv.current_screen() as MissionScreen
	if ms != null:
		ms.http = Callable(self, "_mission_http")
		ms.open("en")
		got = await _wait_until(func() -> bool: return ms.status == "list")
		ok(got, "mission: the list loaded (status %s)" % ms.status)
		await _state("mission_list")
		if got:
			ms._select("cafe_order")
			await _frames(3)
			ok(ms.status == "brief", "mission: the brief opened (status %s)" % ms.status)
			await _state("mission_brief")
			var start := _button_with(ms, "미션 시작")
			if start != null:
				start.pressed.emit()
				await _frames(6)
				ok(ms.status == "talk" or ms.status == "wait", "mission: the chat started (status %s)" % ms.status)
				await _state("mission_chat")
	pv.go_back()
	await _frames(4)
	main_node.show_view("today")


func _button_with(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text and (node as Control).is_visible_in_tree():
		return node as Button
	for ch in node.get_children():
		var f: Button = _button_with(ch, text)
		if f != null:
			return f
	return null
