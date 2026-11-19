extends Node
## 설정 > 음성 인식 (docs/v201_design.md 2.5, 5.6 PSA-1..PSA-7): SttSection (model card, 채점 위치 radio, 폰 채점 다시 켜기,
## 진단 보기), the 기능 현황 reasons, and the PC app showing none of it. Every step uses the real nodes (`press:` lines).
##   phone: godot --headless --path godot --resolution 412x915 res://tests/phone_settings_asr_test.tscn -- --phone [--font-scale=1.5] [--dark] --api=http://127.0.0.1:9
##   PC:    godot --headless --path godot res://tests/phone_settings_asr_test.tscn -- --api=http://127.0.0.1:9
## Files: only user://test_psa/ (prefs, progress, study log, models); the real files are never opened (test guard + own paths).
## Last line: "== phone_settings_asr_test result: N passed, M failed (presses: P) ==", exit code 1 on any failure.

const DIR := "user://test_psa"
const MARK := "ZZ_TGT_4417"
const TXT_PHONE_NOTE := "말하기 점수를 이 폰에서 계산해요. 녹음은 폰 밖으로 나가지 않아요. 소리별 분석 화면만 PC를 써요."
const TXT_PC_NOTE := "PC에 연결돼 있으면 PC에서 채점해요(소리별 팁 포함). PC가 없으면 이 폰에서 채점해요."
const TXT_NO_AI := "AI 연결이 필요해요. PC에 연결하거나 AI 키를 넣어 주세요."
## A stand-in for LocalStt (PA4 is built in parallel): the diagnosis sheet only needs stats() and bench().
const FAKE_STT := """extends RefCounted
static func stats() -> Dictionary:
	return {"runs": 7, "ok": 6, "timeouts": 1, "engine_err": 0, "aborted": 0, "load_count": 1, "unload_count": 0,
		"load_ms_first": 1200, "stt_ms_p50": 1800, "stt_ms_p95": 2600, "stt_ms_max": 3100, "audio_ms_p50": 3200, "rtf_p50": 0.56,
		"rss_mb_before_load": 180, "rss_mb_after_load": 410, "rss_mb_peak": 520, "abort_patch": 1,
		"bridge_version": "bridge 1 / whisper.cpp abc1234 +abort-sched", "model_id": "ZZ_TGT_4417", "params_state": "uncalibrated",
		"beam": 1, "phone_off": 0, "recent": [{"score": 81, "n": 8, "ok": 7, "text": "ZZ_TGT_4417"}], "transcript": "ZZ_TGT_4417"}
static func bench(wav: PackedByteArray, target: String, n: int, on_step: Callable = Callable()) -> Dictionary:
	var calls: Array = Engine.get_meta("psa_calls", [])
	calls.append({"n": n, "wav": wav.size(), "target": target})
	Engine.set_meta("psa_calls", calls)
	if on_step.is_valid():
		on_step.call(1, n)
	var ml = Engine.get_main_loop()
	await ml.process_frame
	return {"n": n, "ok": n, "fail": 0, "ms_p50": 1800, "ms_p95": 2600, "ms_max": 3100, "rss_mb_peak": 520, "seconds": 42.0}
"""

var passed: int = 0
var failed: int = 0
var presses: int = 0
var _phone: bool = false
var _scheme: String = "light"
var _font_scale: float = 1.0
var _old_prefs: String = ""
var _old_progress: String = ""
var _old_log: String = ""
var _old_models_dir: String = ""
var _clip: String = ""
var _cap: LogCap = null


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


func _until(cond: Callable, sec: float = 10.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) < sec * 1000.0:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _ready() -> void:
	_cap = LogCap.new()
	OS.add_logger(_cap)
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s == "--dark":
			_scheme = "dark"
		elif s.begins_with("--font-scale="):
			_font_scale = s.substr(13).to_float() if s.substr(13).is_valid_float() else 1.0
	print("== phone_settings_asr_test start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if _phone else "pc", _scheme, _font_scale])
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_models_dir = ModelStore.base_dir
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.prefs = {}
	ModelStore.base_dir = DIR + "/models/"
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	if not _phone:
		Api.base_url = "http://127.0.0.1:9" # a closed port: the PC run must never reach the user's engine (8770)
	Sheet.animate = false
	Toast.message.connect(func(_t: String, _k: String) -> void: pass)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)
	ok(Store.test_guard_on, "test guard is on")
	ok(Pal.is_dark() == (_scheme == "dark") and is_equal_approx(Ds.font_scale, Ds.sanitize_scale(_font_scale)), "the run uses the asked colour scheme and text scale")

	var fake := GDScript.new()
	fake.source_code = FAKE_STT
	ok(fake.reload() == OK and fake.has_method("stats") and fake.has_method("bench"), "the stand-in LocalStt compiles and has stats and bench")
	SttDiagSheet.reset_for_tests()
	SttDiagSheet.stt_script_override = fake
	SttDiagSheet.clipboard_hook = func(t: String) -> void: _clip = t
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]), "duration": 3.2}

	_selfchecks()
	await _test_pc_none()
	if _phone:
		await _test_structure()
		await _test_radio_flow()
		await _test_phone_off_switch()
		await _test_model_card_inside()
		await _test_diag_chain()
		await _test_odd_values()
		await _test_layout()
	_test_capability()
	_test_sources()
	ok(presses >= 10 or not _phone, "at least 10 real button presses on the phone (%d)" % presses)
	_finish()


func _finish() -> void:
	if _cap != null:
		OS.remove_logger(_cap)
		ok(_cap.count() == 0, "no engine ERROR line during the run (%d)" % _cap.count())
		for l in _cap.snapshot().slice(0, 5):
			print("engine error: ", l)
	SttDiagSheet.reset_for_tests()
	ModelStore.base_dir = _old_models_dir
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	_rm_rf(DIR)
	print("== phone_settings_asr_test result: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


func _rm_rf(path: String) -> void:
	var gp: String = _g(path)
	var d := DirAccess.open(gp)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(gp.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(gp)


# ---------------------------------------------------------------- helpers

func _stage(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(c)


func _new_settings(standalone: bool) -> SettingsView:
	var sv := SettingsView.new()
	sv.standalone_panels = standalone
	_stage(sv)
	return sv


func _press(b: Button, what: String) -> void:
	presses += 1
	print("  press: ", what)
	b.pressed.emit()


func _btn(root: Node, node_name: String) -> Button:
	var n: Node = root.find_child(node_name, true, false)
	return n as Button if n is Button else null


func _seg_buttons(seg: Node) -> Array:
	return seg.find_children("*", "Button", true, false) if seg != null else []


func _seg_button(seg: Node, text: String) -> Button:
	for b in _seg_buttons(seg):
		if (b as Button).text == text:
			return b
	return null


## The text of the selected segment (the selected one carries the bold font override); "" when none or several.
func _seg_selected(seg: Node) -> String:
	var found: Array = []
	for b in _seg_buttons(seg):
		if (b as Button).has_theme_font_override("font"):
			found.append((b as Button).text)
	return str(found[0]) if found.size() == 1 else ""


func _all_text(root: Node) -> String:
	var t := ""
	for n in root.find_children("*", "Label", true, false):
		if (n as Control).is_visible_in_tree():
			t += (n as Label).text + "\n"
	for n in root.find_children("*", "Button", true, false):
		if (n as Control).is_visible_in_tree():
			t += (n as Button).text + "\n"
	return t


func _has_5digits(t: String) -> bool:
	var re := RegEx.new()
	re.compile("[0-9]{5,}")
	return re.search(t) != null


func _saved_pref(key: String) -> Variant:
	var f := FileAccess.open(Store.prefs_path, FileAccess.READ)
	if f == null:
		return null
	var j: Variant = JSON.parse_string(f.get_as_text())
	return (j as Dictionary).get(key, null) if j is Dictionary else null


func _open_sheet() -> Sheet:
	var best: Sheet = null
	for n in get_tree().root.find_children("*", "Sheet", true, false):
		if not (n as Sheet).is_closed():
			best = n
	return best


func _selfchecks() -> void:
	var fired: bool = _has_5digits("abc 12345 def")
	if fired:
		print("selfcheck FAIL-as-expected five_digits")
	ok(fired and not _has_5digits("1234 5678"), "selfcheck: the five-digit detector fires on 12345 and not on 1234 5678")
	var probe := SettingsView.new()
	var refused: bool = not probe.set_score_where("아무거나") and not probe.set_score_where(7) and not probe.set_score_where(null)
	if refused:
		print("selfcheck FAIL-as-expected score_where")
	ok(refused, "selfcheck: set_score_where refuses a value that is not offered")
	probe.free()
	var seg := UI.segmented([["a", "가"], ["b", "나"]], "b", func(_v: String) -> void: pass)
	add_child(seg)
	var found: String = _seg_selected(seg)
	var two := UI.segmented([["a", "가"], ["b", "나"]], "zzz", func(_v: String) -> void: pass)
	add_child(two)
	var none: String = _seg_selected(two)
	if none == "":
		print("selfcheck FAIL-as-expected seg_none_selected")
	ok(found == "나" and none == "", "selfcheck: the selected-segment reader finds the current one and says nothing for none")
	seg.queue_free()
	two.queue_free()


# ---------------------------------------------------------------- PC app: none of it

func _test_pc_none() -> void:
	print("[standalone_panels without the phone]")
	var sv := _new_settings(true)
	await _frames(3)
	if _phone:
		ok(sv.stt_section != null, "phone: standalone_panels builds SttSection")
	else:
		ok(sv.stt_section == null and sv.score_where_box == null and sv.phone_on_box == null, "PC: standalone_panels=true builds none of the 음성 인식 group")
		ok(sv.find_child("SttSection", true, false) == null and sv.find_child("ScoreWhereSeg", true, false) == null and sv.find_child("SttDiagBtn", true, false) == null and sv.find_child("SttModelCard", true, false) == null, "PC: no SttSection, ScoreWhereSeg, SttDiagBtn or SttModelCard node")
		var t := _all_text(sv)
		ok(not t.contains("폰에서 채점") and not t.contains("진단 보기") and not t.contains("음성 인식 모델"), "PC: none of the new texts is on the screen")
	sv.queue_free()
	if _phone:
		var plain := _new_settings(false)
		await _frames(3)
		ok(plain.stt_section == null and plain.find_child("SttSection", true, false) == null, "phone without standalone_panels: no SttSection")
		plain.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- PSA-2 structure and texts

func _test_structure() -> void:
	print("[structure and fixed texts]")
	Store.prefs = {}
	var sv := _new_settings(true)
	await _frames(3)
	var sec: Node = sv.find_child("SttSection", true, false)
	ok(sec != null and sec == sv.stt_section, "SttSection exists (once) in the settings screen")
	ok(sv.find_children("SttSection", "", true, false).size() == 1, "exactly one SttSection")
	ok(sv.section_of(sv.stt_section) == "engine" and sv.section_visible("engine"), "SttSection sits in the visible 'engine' section")
	var title: Label = null
	for ch in sv.stt_section.get_children():
		if ch is Label and title == null:
			title = ch
	ok(title != null and title.text == "음성 인식", "SttSection title is exactly 음성 인식")
	ok(SettingsView.TXT_STT_TITLE == "음성 인식", "TXT_STT_TITLE is 음성 인식")
	var cards: Array = sv.stt_section.find_children("*", "SttModelCard", true, false)
	ok(cards.size() == 1 and (cards[0] as Node).name == "SttModelCard", "the PA3 model card (SttModelCard) is inside SttSection")
	var seg: Node = sv.stt_section.find_child("ScoreWhereSeg", true, false)
	ok(seg != null, "ScoreWhereSeg exists in SttSection")
	var texts: Array = []
	for b in _seg_buttons(seg):
		texts.append((b as Button).text)
	ok(texts == ["폰에서 채점", "PC에서 채점"], "ScoreWhereSeg has exactly 폰에서 채점 and PC에서 채점 (%s)" % str(texts))
	ok(SettingsView.SCORE_WHERE_CHOICES == [["phone", "폰에서 채점"], ["pc", "PC에서 채점"]], "SCORE_WHERE_CHOICES is the one-line constant of the design")
	ok(Route.text_for("engine_error").contains("PC에서 채점"), "Route.text_for('engine_error') mentions 'PC에서 채점' (same letters as the radio)")
	ok(Route.text_for("engine_error").contains(str(texts[1])), "... and it is the radio's own text")
	# order: card, then the radio, then the diagnosis button; the section is above 처리 위치 and 기능 현황
	var order_ok: bool = cards[0].get_index() < sv.score_where_box.get_index() and sv.score_where_box.get_index() < _btn(sv.stt_section, "SttDiagBtn").get_index()
	ok(order_ok, "order inside SttSection: model card, radio, diagnosis button")
	var grp: Control = sv._secs["engine"]["group"]
	var idx_stt: int = -1
	var idx_cap: int = -1
	var idx_mode: int = -1
	for i in grp.body.get_child_count():
		var c: Node = grp.body.get_child(i)
		if c.is_ancestor_of(sv.stt_section):
			idx_stt = i
		if c.is_ancestor_of(sv.cap_panel):
			idx_cap = i
		if c.is_ancestor_of(sv.mode_box):
			idx_mode = i
	ok(idx_stt >= 0 and idx_stt < idx_mode and idx_mode < idx_cap, "SttSection comes before 처리 위치 and 기능 현황 (%d < %d < %d)" % [idx_stt, idx_mode, idx_cap])
	ok(sv.score_where_value() == "phone" and _seg_selected(seg) == "폰에서 채점", "default: 폰에서 채점 is selected")
	ok(str(seg.get_meta("current")) == "phone", "default: the radio remembers 'phone'")
	var t := _all_text(sv.stt_section)
	ok(t.contains(TXT_PHONE_NOTE), "phone note text is shown")
	ok(not t.contains(TXT_PC_NOTE), "the PC note text is not shown while 폰에서 채점 is selected")
	ok(not _has_5digits(t), "no run of five digits in the SttSection text")
	ok(_btn(sv.stt_section, "SttDiagBtn") != null and _btn(sv.stt_section, "SttDiagBtn").text == "진단 보기", "SttDiagBtn (진단 보기) exists")
	ok(sv.find_child("SttPhoneOnBtn", true, false) == null and not sv.phone_on_box.visible, "stt_phone_off is false: no 폰 채점 다시 켜기 switch")
	ok(sv.cap_panel != null and sv.cap_panel.rows.size() == 16, "기능 현황 still has its 16 rows")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- PSA-3 radio

func _test_radio_flow() -> void:
	print("[radio buttons]")
	Store.prefs = {}
	var sv := _new_settings(true)
	await _frames(3)
	var seg: Node = sv.stt_section.find_child("ScoreWhereSeg", true, false)
	_press(_seg_button(seg, "PC에서 채점"), "PC에서 채점")
	await _frames(3)
	ok(Store.prefs.get("score_where") == "pc", "[PC에서 채점] saves score_where == pc")
	ok(_saved_pref("score_where") == "pc", "... and it is in the prefs file")
	ok(Route.policy_for("POST", "/score", {})["prefer"] == "pc" and Route.policy_for("POST", "/stt", {})["prefer"] == "pc", "Route.policy_for POST /score and /stt prefer pc")
	seg = sv.stt_section.find_child("ScoreWhereSeg", true, false)
	ok(_seg_selected(seg) == "PC에서 채점" and str(seg.get_meta("current")) == "pc", "the radio now shows PC에서 채점")
	var t := _all_text(sv.stt_section)
	ok(t.contains(TXT_PC_NOTE) and not t.contains(TXT_PHONE_NOTE), "the note changes to the PC text")
	_press(_seg_button(seg, "폰에서 채점"), "폰에서 채점")
	await _frames(3)
	ok(Store.prefs.get("score_where") == "phone", "[폰에서 채점] saves score_where == phone")
	ok(Route.policy_for("POST", "/score", {})["prefer"] == "phone", "Route.policy_for POST /score prefers phone again")
	seg = sv.stt_section.find_child("ScoreWhereSeg", true, false)
	ok(_seg_selected(seg) == "폰에서 채점", "the radio shows 폰에서 채점 again")
	# a change made elsewhere (another screen, a sync) shows after refresh()
	Store.prefs["score_where"] = "pc"
	sv.refresh()
	await _frames(1)
	ok(_seg_selected(sv.stt_section.find_child("ScoreWhereSeg", true, false)) == "PC에서 채점", "refresh() re-reads score_where")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- stt_phone_off

func _test_phone_off_switch() -> void:
	print("[폰 채점 다시 켜기]")
	Store.prefs = {}
	var sv := _new_settings(true)
	await _frames(3)
	Store.set_pref("stt_phone_off", true)
	await _frames(3)
	var sw: CheckButton = sv.find_child("SttPhoneOnBtn", true, false) as CheckButton
	ok(sw != null and sv.phone_on_box.visible, "stt_phone_off == true: the SttPhoneOnBtn switch shows")
	ok(sw != null and not sw.button_pressed, "the switch starts off")
	ok(_all_text(sv.stt_section).contains("폰 채점 다시 켜기"), "its text is 폰 채점 다시 켜기")
	if sw != null:
		presses += 1
		print("  press: SttPhoneOnBtn (switch on)")
		sw.button_pressed = true
	await _frames(3)
	ok(Store.prefs.get("stt_phone_off") == false, "turning it on sets stt_phone_off to false")
	ok(sv.find_child("SttPhoneOnBtn", true, false) == null and not sv.phone_on_box.visible, "the switch goes away afterwards")
	# turned off while the screen is open: the 기능 현황 sees the new pref after refresh() as well
	Store.prefs["stt_phone_off"] = true
	sv.refresh()
	await _frames(2)
	ok(sv.find_child("SttPhoneOnBtn", true, false) != null, "refresh() shows the switch when the pref was set without a signal")
	Store.prefs["stt_phone_off"] = false
	sv.refresh()
	await _frames(2)
	ok(sv.find_child("SttPhoneOnBtn", true, false) == null, "refresh() hides it again")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- 진단 보기 chain (fake LocalStt, fake recorder)

func _test_diag_chain() -> void:
	print("[진단 보기 -> 녹음 -> 속도 시험 -> 복사]")
	Store.prefs = {}
	Engine.set_meta("psa_calls", [])
	_clip = ""
	var sv := _new_settings(true)
	await _frames(3)
	_press(_btn(sv.stt_section, "SttDiagBtn"), "진단 보기")
	await _frames(3)
	var sh: Sheet = _open_sheet()
	ok(sh != null and Sheet.depth() >= 1, "진단 보기 opens a sheet")
	if sh == null:
		sv.queue_free()
		return
	var rec: Button = _btn(sh, "DiagRecBtn")
	var b20: Button = _btn(sh, "DiagBench20Btn")
	var cp: Button = _btn(sh, "DiagCopyBtn")
	ok(rec != null and b20 != null and cp != null and _btn(sh, "DiagBench60Btn") != null, "the sheet has DiagRecBtn, DiagBench20Btn, DiagBench60Btn and DiagCopyBtn")
	_press(rec, "한 문장 녹음")
	await _frames(3)
	_press(b20, "20회 속도 시험")
	await _until(func() -> bool: return (Engine.get_meta("psa_calls", []) as Array).size() >= 1)
	await _frames(4)
	var calls: Array = Engine.get_meta("psa_calls", [])
	ok(calls.size() == 1 and int((calls[0] as Dictionary)["n"]) == 20, "the stand-in LocalStt.bench was called once with n == 20")
	ok(calls.size() == 1 and int((calls[0] as Dictionary)["wav"]) == 8 and str((calls[0] as Dictionary)["target"]) == SttDiagSheet.TARGET, "... with the recorded wav and the fixed sentence")
	_press(_btn(sh, "DiagBench60Btn"), "60회 연속 시험")
	await _until(func() -> bool: return (Engine.get_meta("psa_calls", []) as Array).size() >= 2)
	await _frames(4)
	calls = Engine.get_meta("psa_calls", [])
	ok(calls.size() == 2 and int((calls[1] as Dictionary)["n"]) == 60, "the stand-in LocalStt.bench was called a second time with n == 60")
	_press(cp, "결과 복사")
	await _frames(2)
	ok(_clip.split("\n")[0] == "hoehwa-diag 1", "[결과 복사] puts a text whose first line is hoehwa-diag 1 on the clipboard hook")
	ok(_clip.contains("bench20 n=20 ok=20 p50_ms=1800") and _clip.contains("bench60 n=60 ok=60"), "the copied text carries both speed test numbers")
	ok(not _clip.contains(MARK), "the copied text has none of the stand-in's text fields")
	ok(not _all_text(sh).contains("hoehwa-diag"), "the raw block is not shown on the screen")
	Sheet.close_top()
	await _frames(2)
	sv.queue_free()
	await _frames(2)


## The PA3 card works from inside SttSection: [모델 받기] asks about Wi-Fi first and "나중에" starts nothing.
func _test_model_card_inside() -> void:
	print("[model card inside SttSection]")
	Store.prefs = {}
	var sv := _new_settings(true)
	await _frames(3)
	var get_btn: Button = _btn(sv.stt_section, "ModelGetBtn")
	ok(get_btn != null and get_btn.visible, "the card shows [모델 받기] (no model in the test folder)")
	_press(get_btn, "모델 받기")
	await _frames(3)
	var sh: Sheet = _open_sheet()
	ok(sh != null and sh.buttons.has("ok") and sh.buttons.has("cancel"), "[모델 받기] opens the Wi-Fi question sheet")
	if sh != null and sh.buttons.has("cancel"):
		_press(sh.buttons["cancel"], "나중에")
	await _frames(3)
	ok(ModelStore.state(ModelStore.active_id()) == "missing" and not Sheet.is_open(), "[나중에] starts nothing and closes the sheet")
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- PSA-5 odd values

func _test_odd_values() -> void:
	print("[odd values]")
	for bad in ["아무거나", 7, null, true, ["pc"], {"a": 1}, "PC", ""]:
		Store.prefs = {}
		Store.prefs["score_where"] = bad
		var sv := _new_settings(true)
		await _frames(2)
		var seg: Node = sv.stt_section.find_child("ScoreWhereSeg", true, false)
		ok(sv.score_where_value() == "phone" and _seg_selected(seg) == "폰에서 채점", "score_where %s reads as 폰에서 채점" % var_to_str(bad))
		ok(Route.policy_for("POST", "/score", {})["prefer"] == "phone", "score_where %s: Route prefers the phone" % var_to_str(bad))
		sv.queue_free()
		await _frames(1)
	var sv2 := _new_settings(true)
	await _frames(2)
	Store.prefs = {"score_where": "pc"}
	for bad in ["아무거나", 7, null]:
		ok(not sv2.set_score_where(bad) and Store.prefs.get("score_where") == "pc", "set_score_where(%s) is refused and keeps the saved value" % var_to_str(bad))
	for bad in ["아무거나", 7, null, "PHONE", 1.5]:
		Store.prefs = {}
		Store.prefs["stt_phone_off"] = bad
		sv2.refresh()
		await _frames(1)
	ok(true, "odd stt_phone_off values do not crash the redraw")
	sv2.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- phone layout

func _test_layout() -> void:
	print("[layout]")
	Store.prefs = {}
	Store.prefs["stt_phone_off"] = true
	var sv := _new_settings(true)
	await _frames(4)
	var over: Array = []
	var small: Array = []
	for n in sv.stt_section.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		if r.end.x > 412.5 or r.position.x < -0.5:
			over.append("%s %s" % [c.name, str(r)])
		if (c is Button or c is CheckButton) and c.size.y < 47.5:
			small.append("%s %s" % [c.name, str(c.size)])
	ok(over.is_empty(), "no control of SttSection sticks out of the 412 px screen (%s)" % str(over.slice(0, 3)))
	ok(small.is_empty(), "every button and switch of SttSection is a touch target (%s)" % str(small.slice(0, 3)))
	sv.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- PSA-6 기능 현황

func _test_capability() -> void:
	print("[기능 현황]")
	ok(CapabilityPanel.NAMES.size() == 16 and Route.CAP_KEYS.size() == 16, "16 capability keys (names and Route.CAP_KEYS)")
	var all_named := true
	for k in Route.CAP_KEYS:
		all_named = all_named and CapabilityPanel.NAMES.has(k)
	ok(all_named, "every Route.CAP_KEYS item has a name")
	ok(CapabilityPanel.REASONS["model_missing"] == "설정 > 음성 인식에서 모델을 받으면 폰에서 쓸 수 있어요.", "REASONS.model_missing is the design text")
	ok(CapabilityPanel.REASONS["model_corrupt"] == "음성 인식 모델이 손상됐어요. 설정 > 음성 인식에서 다시 받아 주세요.", "REASONS.model_corrupt is the design text")
	ok(CapabilityPanel.REASONS["engine_error"] == "폰 채점이 꺼져 있어요. 설정 > 음성 인식에서 다시 켤 수 있어요.", "REASONS.engine_error (new) is the design text")
	ok(CapabilityPanel.REASONS["no_ai"] == TXT_NO_AI, "REASONS.no_ai is unchanged")
	ok(str(CapabilityPanel.REASONS["engine_missing"]).begins_with("이 앱에는 폰 음성 인식이 없어요."), "REASONS.engine_missing is unchanged")
	var item := {"use": "none", "phone": false, "pc": false, "why": "engine_error"}
	ok(CapabilityPanel.reason_text(item, "auto") == CapabilityPanel.REASONS["engine_error"], "reason_text for engine_error is the new line")
	item["why"] = "model_missing"
	ok(CapabilityPanel.reason_text(item, "auto").contains("설정 > 음성 인식"), "reason_text for model_missing points to 설정 > 음성 인식")
	item["why"] = "model_corrupt"
	ok(CapabilityPanel.reason_text(item, "auto").contains("설정 > 음성 인식"), "reason_text for model_corrupt points to 설정 > 음성 인식")
	var no_install := true
	for k in CapabilityPanel.REASONS.keys():
		if str(k) in ["model_missing", "model_corrupt", "engine_error"]:
			no_install = no_install and not str(CapabilityPanel.REASONS[k]).contains("다시 설치")
	ok(no_install, "the three speech reasons do not tell the person to reinstall")


# ---------------------------------------------------------------- source rules

func _test_sources() -> void:
	print("[sources]")
	for p in ["res://scripts/views/settings_view.gd", "res://scripts/ui/stt_diag_sheet.gd", "res://scripts/ui/capability_panel.gd"]:
		var f := FileAccess.open(p, FileAccess.READ)
		var src: String = f.get_as_text() if f != null else ""
		ok(src != "" and not src.contains("Color(\"#") and not src.contains("HTTPRequest") and not src.contains("HTTPClient"), "%s: no Color(\"#, no network client" % p.get_file())


class LogCap:
	extends Logger
	var lines: Array = []
	var mu := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		lines.append("%s %s:%d %s %s" % [function, file, line, code, rationale])
		mu.unlock()

	func count() -> int:
		mu.lock()
		var n: int = lines.size()
		mu.unlock()
		return n

	func snapshot() -> Array:
		mu.lock()
		var c: Array = lines.duplicate()
		mu.unlock()
		return c
