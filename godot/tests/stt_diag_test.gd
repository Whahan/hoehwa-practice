extends Node
## 진단 시트 (docs/v201_design.md 2.5, 4.3, 5.6 PSA-1·PSA-3·PSA-4·PSA-5): SttDiagSheet.report_text and the sheet's buttons.
##   godot --headless --path godot [--resolution 412x915] res://tests/stt_diag_test.tscn -- [--phone] [--font-scale=1.5] [--dark] --api=http://127.0.0.1:9
## The copied block holds numbers and codes only; a stand-in LocalStt (PA4 is built in parallel) carries text-like fields
## with a marker, and the marker must not reach the copied text or the screen. Files: user://test_psa_diag/ only.
## Last line: "== stt_diag_test result: N passed, M failed (presses: P) ==", exit code 1 on any failure.

const DIR := "user://test_psa_diag"
const MARK := "ZZ_TGT_4417"
const MARK2 := "ZZ_MARK_9731"
const FAKE_STT := """extends RefCounted
static func stats() -> Dictionary:
	return {"runs": 7, "ok": 6, "timeouts": 1, "engine_err": 0, "aborted": 0, "load_count": 1, "unload_count": 0,
		"load_ms_first": 1200, "stt_ms_p50": 1800, "stt_ms_p95": 2600, "stt_ms_max": 3100, "audio_ms_p50": 3200, "rtf_p50": 0.56,
		"rss_mb_before_load": 180, "rss_mb_after_load": 410, "rss_mb_peak": 520, "abort_patch": 1,
		"bridge_version": "bridge 1 / whisper.cpp abc1234 +abort-sched", "model_id": "ZZ_TGT_4417", "params_state": "uncalibrated",
		"beam": 1, "phone_off": 0,
		"recent": [{"score": 81, "n": 8, "ok": 7, "text": "ZZ_TGT_4417"}, {"score": 64, "n": 5, "ok": 3, "text": "ZZ_MARK_9731"}],
		"transcript": "ZZ_TGT_4417", "last_target": "ZZ_TGT_4417", "path": "C:/Users/someone/app_userdata/x.wav"}
static func bench(wav: PackedByteArray, target: String, n: int, on_step: Callable = Callable()) -> Dictionary:
	var calls: Array = Engine.get_meta("diag_calls", [])
	calls.append({"n": n, "wav": wav.size(), "target": target})
	Engine.set_meta("diag_calls", calls)
	if on_step.is_valid():
		on_step.call(1, n)
	var ml = Engine.get_main_loop()
	await ml.process_frame
	return {"n": n, "ok": n - 1, "fail": 1, "ms_p50": 1800, "ms_p95": 2600, "ms_max": 3100, "rss_mb_peak": 520, "seconds": 90.0}
"""
## Every value a hostile stand-in could use to smuggle text: strings where numbers belong, text in the version.
const FAKE_LEAKY := """extends RefCounted
static func stats() -> Dictionary:
	return {"runs": "ZZ_TGT_4417", "ok": true, "timeouts": null, "engine_err": [1], "aborted": {"a": 1}, "load_count": NAN, "unload_count": INF,
		"load_ms_first": "1200", "stt_ms_p50": "ZZ_MARK_9731", "bridge_version": "ZZ_TGT_4417", "params_state": "ZZ_TGT_4417",
		"beam": "ZZ_TGT_4417", "abort_patch": "ZZ_TGT_4417", "recent": ["ZZ_TGT_4417", 5, {"score": "ZZ_TGT_4417", "n": 2, "ok": 1}]}
"""
## A bench that takes many frames and reports progress on every one (the sheet is closed while it runs).
const FAKE_SLOW := """extends RefCounted
static func stats() -> Dictionary:
	return {}
static func bench(wav: PackedByteArray, target: String, n: int, on_step: Callable = Callable()) -> Dictionary:
	var ml = Engine.get_main_loop()
	var calls: Array = Engine.get_meta("diag_calls", [])
	calls.append({"n": n, "wav": wav.size(), "target": target})
	Engine.set_meta("diag_calls", calls)
	for i in 12:
		await ml.process_frame
		if on_step.is_valid():
			on_step.call(i + 1, n)
	Engine.set_meta("slow_done", true)
	return {"n": n, "ok": n, "fail": 0, "ms_p50": 1000, "ms_p95": 1100, "ms_max": 1200, "rss_mb_peak": 300, "seconds": 5.0}
"""
const FAKE_NO_STATS := """extends RefCounted
static func something_else() -> int:
	return 1
"""
const FAKE_STATS_NULL := """extends RefCounted
static func stats():
	return null
"""

var passed: int = 0
var failed: int = 0
var presses: int = 0
var _phone: bool = false
var _scheme: String = "light"
var _font_scale: float = 1.0
var _old_prefs: String = ""
var _old_models_dir: String = ""
var _old_course_path: String = ""
var _clip: String = ""
var _clip_count: int = 0
var _fake: GDScript = null
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


func _script(src: String) -> GDScript:
	var s := GDScript.new()
	s.source_code = src
	return s if s.reload() == OK else null


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
	print("== stt_diag_test start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if _phone else "pc", _scheme, _font_scale])
	_old_prefs = Store.prefs_path
	_old_models_dir = ModelStore.base_dir
	_old_course_path = CourseStore.path
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.prefs = {}
	ModelStore.base_dir = DIR + "/models/"
	CourseStore.path = DIR.path_join("course.json")
	CourseStore.reset_memory()
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
	_fake = _script(FAKE_STT)
	ok(_fake != null and _fake.has_method("stats") and _fake.has_method("bench"), "the stand-in LocalStt compiles and has stats and bench")
	SttDiagSheet.reset_for_tests()
	SttDiagSheet.stt_script_override = _fake
	SttDiagSheet.clipboard_hook = func(t: String) -> void:
		_clip = t
		_clip_count += 1

	_selfchecks()
	_test_report_keys()
	_test_report_values()
	_test_hostile_strings()
	_test_report_clamps()
	_test_no_leak()
	_test_missing_stt()
	await _test_sheet_flow()
	await _test_sheet_failures()
	await _test_battery_boxes()
	await _test_real_recorder()
	await _test_close_while_busy()
	await _test_animated_close()
	await _test_battery_zero()
	await _test_reopen_keeps_numbers()
	if _phone:
		await _test_layout()
	_test_sources()
	_finish()


func _finish() -> void:
	if _cap != null:
		OS.remove_logger(_cap)
		ok(_cap.count() == 0, "no engine ERROR line during the run (%d)" % _cap.count())
		for l in _cap.snapshot().slice(0, 5):
			print("engine error: ", l)
	SttDiagSheet.reset_for_tests()
	Recorder.mode_override = ""
	Recorder.test_audio_source = Callable()
	ModelStore.base_dir = _old_models_dir
	CourseStore.path = _old_course_path
	CourseStore.reset_memory()
	Store.prefs_path = _old_prefs
	_rm_rf(DIR)
	print("== stt_diag_test result: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
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

func _press(b: Button, what: String) -> void:
	if b == null:
		ok(false, "button exists: " + what)
		return
	presses += 1
	print("  press: ", what)
	b.pressed.emit()


func _btn(root: Node, node_name: String) -> Button:
	var n: Node = root.find_child(node_name, true, false)
	return n as Button if n is Button else null


func _open_sheet() -> Sheet:
	var best: Sheet = null
	for n in get_tree().root.find_children("*", "Sheet", true, false):
		if not (n as Sheet).is_closed():
			best = n
	return best


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


## "key=value" tokens of ONE line as a Dictionary (a bare first word is kept under "_head").
func _line_tokens(line: String) -> Dictionary:
	var d := {}
	for tok in line.split(" ", false):
		var t: String = String(tok)
		var i: int = t.find("=")
		if i > 0:
			d[t.substr(0, i)] = t.substr(i + 1)
		elif not d.has("_head"):
			d["_head"] = t
	return d


func _line_of(text: String, head: String) -> String:
	for l in text.split("\n"):
		if String(l).begins_with(head):
			return String(l)
	return ""


## Every key=value token of the whole text, later lines overwrite earlier ones only for keys that are unique anyway.
func _all_tokens(text: String) -> Dictionary:
	var d := {}
	for l in text.split("\n", false):
		var line: String = String(l)
		if line.begins_with("bench20") or line.begins_with("bench60"):
			continue
		var lt: Dictionary = _line_tokens(line)
		for k in lt.keys():
			d[k] = lt[k]
	return d


func _allowed_chars(text: String) -> bool:
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9 =._+,/\\n-]*$")
	return re.search(text) != null


func _leaks(text: String) -> bool:
	var ud: String = OS.get_user_data_dir()
	return text.contains(MARK) or text.contains(MARK2) or text.contains("/data/") or text.contains("C:\\") or text.contains("user://") \
		or text.contains("app_userdata") or text.contains("AppData") or (ud != "" and text.contains(ud)) or text.contains("\\")


func _extra() -> Dictionary:
	return {"bench20": {"n": 20, "ok": 20, "fail": 0, "ms_p50": 1800, "ms_p95": 2600, "ms_max": 3100, "rss_mb_peak": 520, "seconds": 40.0},
		"bench60": {"n": 60, "ok": 59, "fail": 1, "ms_p50": 1900, "ms_p95": 2700, "ms_max": 3300, "rss_mb_peak": 530, "seconds": 90.0},
		"battery_start": 80, "battery_end": 77}


func _selfchecks() -> void:
	var f1: bool = _leaks("x " + MARK + " y")
	if f1:
		print("selfcheck FAIL-as-expected leak")
	ok(f1 and _leaks("a user://x b") and _leaks("p /data/user/0/x") and _leaks("C:\\Users") and not _leaks("stt_runs=7 recent=81/8/7"), "selfcheck: the leak detector fires on a marker and on paths, and passes plain numbers")
	var f2: bool = not _allowed_chars("a=b C:\\x") and not _allowed_chars("a=b é") and _allowed_chars("a=1 b=2.50\nbench20 -\n")
	if f2:
		print("selfcheck FAIL-as-expected charset")
	ok(f2, "selfcheck: the charset check rejects a backslash and a non-ASCII letter")
	var f3: bool = _has_5digits("x 12345") and not _has_5digits("x 1234")
	if f3:
		print("selfcheck FAIL-as-expected five_digits")
	ok(f3, "selfcheck: the five-digit detector fires on 12345 and not on 1234")
	var bad := SttDiagSheet.report_text({"bench20": "not a dict", "bench60": 5, "battery_start": "80", "battery_end": [1]})
	ok(_line_of(bad, "bench20") == "bench20 -" and _line_of(bad, "bench60") == "bench60 -", "selfcheck: wrong extra types read as no data")


# ---------------------------------------------------------------- PSA-4: the block

const KEYS := ["app", "platform", "os", "device", "cores", "ram_mb", "bridge", "abort_patch", "cpu", "user_dir_internal",
	"stt_model", "state", "file_mb", "verified", "params", "beam", "phone_off", "score_where",
	"dl_requests", "dl_resumed", "dl_resume_mb", "dl_last_host", "dl_last_err",
	"stt_runs", "stt_ok", "timeouts", "engine_err", "aborted", "load_count", "unload_count", "load_ms_first",
	"stt_ms_p50", "stt_ms_p95", "stt_ms_max", "audio_ms_p50", "rtf_p50",
	"rss_mb_before_load", "rss_mb_after_load", "rss_mb_peak", "recent", "api_sent_since_start", "phone_served", "course_pos", "review_cards"]
const B20_KEYS := ["n", "ok", "p50_ms", "p95_ms", "max_ms"]
const B60_KEYS := ["n", "ok", "fail", "minutes", "rss_mb_peak", "battery_start", "battery_end"]


func _test_report_keys() -> void:
	print("[report_text keys]")
	var text: String = SttDiagSheet.report_text(_extra())
	ok(text.split("\n")[0] == "hoehwa-diag 1", "the first line is hoehwa-diag 1")
	ok(KEYS.size() >= 40, "the key list holds at least 40 keys (%d)" % KEYS.size())
	var tokens: Dictionary = _all_tokens(text)
	for k in KEYS:
		ok(tokens.has(k) and str(tokens[k]) != "", "key %s is in the text" % k)
	var b20: Dictionary = _line_tokens(_line_of(text, "bench20"))
	for k in B20_KEYS:
		ok(b20.has(k), "bench20 has %s" % k)
	var b60: Dictionary = _line_tokens(_line_of(text, "bench60"))
	for k in B60_KEYS:
		ok(b60.has(k), "bench60 has %s" % k)
	ok(text.ends_with("\n") and not text.contains("\n\n"), "the text is lines ending in a newline, no empty line")
	ok(_allowed_chars(text), "the whole text uses only letters, digits, space and = . _ + , / -")
	ok(not _leaks(text), "no marker, path, backslash or user folder in the text")


func _test_report_values() -> void:
	print("[report_text values]")
	var text: String = SttDiagSheet.report_text(_extra())
	var t: Dictionary = _all_tokens(text)
	ok(t["stt_runs"] == "7" and t["stt_ok"] == "6" and t["timeouts"] == "1" and t["engine_err"] == "0", "stats numbers come through (runs 7, ok 6, timeouts 1, engine_err 0)")
	ok(t["load_ms_first"] == "1200" and t["stt_ms_p50"] == "1800" and t["stt_ms_p95"] == "2600" and t["stt_ms_max"] == "3100" and t["audio_ms_p50"] == "3200", "time numbers come through")
	ok(t["rtf_p50"] == "0.56", "a decimal keeps two places (rtf_p50 0.56)")
	ok(t["rss_mb_before_load"] == "180" and t["rss_mb_after_load"] == "410" and t["rss_mb_peak"] == "520", "memory numbers come through")
	ok(t["abort_patch"] == "1" and t["params"] == "uncalibrated" and t["beam"] == "1", "abort_patch, params and beam come through")
	ok(t["bridge"] == "1-abc1234+abort-sched", "the bridge version becomes one token (%s)" % t["bridge"])
	ok(t["recent"] == "81/8/7,64/5/3", "recent lists score/words/right for each entry")
	ok(t["user_dir_internal"] in ["0", "1"], "user_dir_internal is 0 or 1")
	ok(t["phone_off"] == "0" and t["score_where"] == "phone", "phone_off 0 and score_where phone by default")
	ok(t["stt_model"] == ModelStore.active_id() and t["state"] == "missing" and t["file_mb"] == "0" and t["verified"] == "0", "model line: active id, missing, 0 MB, not verified")
	ok(str(t["dl_requests"]).is_valid_int() and str(t["dl_resumed"]).is_valid_int(), "download counters are integers")
	ok(t["api_sent_since_start"] == str(Api.sent_count) and t["phone_served"] == str(LocalApi.served_count), "Api.sent_count and LocalApi.served_count")
	ok(t["course_pos"].begins_with("w") and t["course_pos"].contains("d"), "course_pos looks like w<n>d<n> (%s)" % t["course_pos"])
	var b20: Dictionary = _line_tokens(_line_of(text, "bench20"))
	ok(b20["n"] == "20" and b20["ok"] == "20" and b20["p50_ms"] == "1800" and b20["p95_ms"] == "2600" and b20["max_ms"] == "3100", "bench20 numbers")
	var b60: Dictionary = _line_tokens(_line_of(text, "bench60"))
	ok(b60["n"] == "60" and b60["ok"] == "59" and b60["fail"] == "1" and b60["minutes"] == "1.50" and b60["rss_mb_peak"] == "530", "bench60 numbers (90 s = 1.50 minutes)")
	ok(b60["battery_start"] == "80" and b60["battery_end"] == "77", "bench60 carries both battery numbers")
	var plain: String = SttDiagSheet.report_text()
	ok(_line_of(plain, "bench20") == "bench20 -" and _line_of(plain, "bench60") == "bench60 -", "no bench data: 'bench20 -' and 'bench60 -'")
	Store.prefs["stt_phone_off"] = true
	Store.prefs["score_where"] = "pc"
	var t2: Dictionary = _all_tokens(SttDiagSheet.report_text())
	ok(t2["phone_off"] == "1" and t2["score_where"] == "pc", "phone_off and score_where follow the prefs")
	Store.prefs["stt_phone_off"] = "yes"
	Store.prefs["score_where"] = 7
	var t3: Dictionary = _all_tokens(SttDiagSheet.report_text())
	ok(t3["phone_off"] == "0" and t3["score_where"] == "phone", "odd pref values read as off / phone")
	Store.prefs = {}


func _test_report_clamps() -> void:
	print("[report_text batteries]")
	var cases := [[150, "100"], [-5, "0"], [100, "100"], [0, "0"], [55.4, "55"], [NAN, "-"], [INF, "-"], ["80", "-"], [null, "-"], [true, "-"]]
	for c in cases:
		var line: String = _line_of(SttDiagSheet.report_text({"battery_start": c[0], "battery_end": c[0]}), "bench60")
		var tk: Dictionary = _line_tokens(line)
		ok(tk.get("battery_start", "x") == c[1] or (line == "bench60 -" and c[1] == "-"), "battery %s is written as %s" % [var_to_str(c[0]), c[1]])


func _test_no_leak() -> void:
	print("[no text leaks]")
	var leaky: GDScript = _script(FAKE_LEAKY)
	ok(leaky != null, "the hostile stand-in compiles")
	SttDiagSheet.stt_script_override = leaky
	var text: String = SttDiagSheet.report_text({"bench20": {"n": MARK, "ok": MARK2, "ms_p50": [1]}, "bench60": {"n": 60, "ok": "x"}})
	ok(not _leaks(text), "strings where numbers belong never reach the text")
	var t: Dictionary = _all_tokens(text)
	ok(t["stt_runs"] == "-" and t["stt_ok"] == "-" and t["timeouts"] == "-" and t["engine_err"] == "-" and t["aborted"] == "-", "text, bool, null, array and dictionary values read as -")
	ok(t["load_count"] == "-" and t["unload_count"] == "-" and t["load_ms_first"] == "-" and t["stt_ms_p50"] == "-", "NaN, INF and numeric strings read as -")
	ok((t["bridge"] == "-" or ClassDB.class_exists("WhisperBridge")) and not str(t["bridge"]).contains("zz") and t["params"] == "-" and t["beam"] == "-" and t["abort_patch"] in ["-", "0", "1"], "a version, params and beam that are not whitelisted read as -")
	ok(t["recent"] == "-/2/1", "a recent entry keeps its numbers and shows - for text (%s)" % t["recent"])
	var b20: Dictionary = _line_tokens(_line_of(text, "bench20"))
	ok(b20["n"] == "-" and b20["ok"] == "-" and b20["p50_ms"] == "-", "bench20 with text values reads -")
	ok(_allowed_chars(text), "the hostile block still uses only the allowed characters")
	var fired: bool = _leaks(text.replace("stt_runs=-", "stt_runs=" + MARK))
	if fired:
		print("selfcheck FAIL-as-expected leak_injected")
	ok(fired, "selfcheck: the same block with the marker injected is reported as a leak")
	# the filters on their own: whole-string forms only, nothing is cleaned up
	var nl: String = String.chr(10)
	ok(SttDiagSheet.version_token("bridge 1 / whisper.cpp abc1234") == "1-abc1234" and SttDiagSheet.version_token("bridge 12 / whisper.cpp unknown +abort-sched") == "12-unknown+abort-sched", "the real bridge version forms are accepted (bridge 1 / whisper.cpp abc1234 [+abort-sched])")
	ok(SttDiagSheet.version_token("bridge 1 / whisper.cpp abc1234" + nl) == "-" and SttDiagSheet.version_token("x bridge 1 / whisper.cpp abc1234") == "-" and SttDiagSheet.version_token("bridge 1 / whisper.cpp abc1234 +abort-sched trailing words") == "-" and SttDiagSheet.version_token("bridge 1 / whisper.cpp ABC1234") == "-", "a bridge version with text before or after it, a newline or upper case is rejected whole")
	ok(SttDiagSheet.app_token("2.0.1") == "2.0.1" and SttDiagSheet.app_token("2.0.1 beta") == "-" and SttDiagSheet.app_token("2.0") == "-", "app version: x.y.z only")
	ok(SttDiagSheet.platform_token("Android") == "Android" and SttDiagSheet.platform_token("Windows") == "Windows" and SttDiagSheet.platform_token("sampleuser") == "-" and SttDiagSheet.platform_token("android") == "-", "platform: a name from the list only")
	ok(SttDiagSheet.os_token("10.0.26300") == "10.0.26300" and SttDiagSheet.os_token("14") == "14" and SttDiagSheet.os_token("14 please read") == "-", "os version: digits and dots only")
	ok(SttDiagSheet.device_token("SM-S921N") == "SM-S921N" and SttDiagSheet.device_token("Pixel 8") == "Pixel_8" and SttDiagSheet.device_token("/data/user/0/x") == "-" and SttDiagSheet.device_token("a b c d e f") == "-", "device: up to four words of letters, digits and . _ -")
	ok(SttDiagSheet.cpu_token("asimd fphp sve2") == "asimd+fphp+sve2" and SttDiagSheet.cpu_token("asimd sampleuser") == "-" and SttDiagSheet.cpu_token("") == "-" and SttDiagSheet.cpu_token(null) == "-", "cpu: only the bridge's own feature names")
	ok(SttDiagSheet.model_id_token("whisper-base.en-q5_1") == "whisper-base.en-q5_1" and SttDiagSheet.model_id_token("sampleuser") == "-" and SttDiagSheet.model_id_token("Please Read") == "-", "model id: only an id of the model manifest")
	ok(SttDiagSheet.host_token("release-assets.githubusercontent.com") == "release-assets.githubusercontent.com" and SttDiagSheet.host_token("huggingface.co") == "huggingface.co" and SttDiagSheet.host_token("evilgithub.com") == "-" and SttDiagSheet.host_token("sampleuser.example.org") == "-" and SttDiagSheet.host_token(MARK) == "-", "download host: only a host the model manifest allows")
	ok(SttDiagSheet.err_token("dl_host") == "dl_host" and SttDiagSheet.err_token("cancelled") == "cancelled" and SttDiagSheet.err_token("sampleuser") == "-" and SttDiagSheet.err_token(5) == "-", "download error: only ModelStore's own codes")
	SttDiagSheet.stt_script_override = _fake


## Strings that do not belong in the block, put into every string field a stand-in LocalStt can fill: all read "-".
const HOSTILE := ["please read this sentence", "/data/user/0/private/model.bin", "/home/sampleuser/cache/model.bin", "sampleuser", "demo-private-key-via-stats", "ZZ_TGT_4417"]


func _test_hostile_strings() -> void:
	print("[hostile strings in string fields]")
	var nl: String = String.chr(10)
	var tab: String = String.chr(9)
	for h in HOSTILE:
		var src: String = "extends RefCounted" + nl + "static func stats() -> Dictionary:" + nl + tab + "return {'bridge_version': " + var_to_str(h) + ", 'params_state': " + var_to_str(h) + ", 'model_id': " + var_to_str(h) + ", 'runs': " + var_to_str(h) + ", 'recent': [" + var_to_str(h) + "]}" + nl
		SttDiagSheet.stt_script_override = _script(src)
		var text: String = SttDiagSheet.report_text()
		var t: Dictionary = _all_tokens(text)
		ok(t["bridge"] == "-" and t["params"] == "-" and t["stt_runs"] == "-" and t["recent"] == "-", "hostile text %s: bridge, params, stt_runs and recent read -" % str(HOSTILE.find(h)))
		ok(not text.contains(str(h)) and _allowed_chars(text), "hostile text %s: it is not in the block" % str(HOSTILE.find(h)))
		# the device name comes from the OS (OS.get_model_name), never from LocalStt, so it is not in this list
		var fns := {"version_token": SttDiagSheet.version_token, "app_token": SttDiagSheet.app_token, "platform_token": SttDiagSheet.platform_token,
			"os_token": SttDiagSheet.os_token, "cpu_token": SttDiagSheet.cpu_token, "model_id_token": SttDiagSheet.model_id_token,
			"host_token": SttDiagSheet.host_token, "err_token": SttDiagSheet.err_token}
		for fn in fns.keys():
			ok((fns[fn] as Callable).call(h) == "-", "hostile text %s through %s reads -" % [str(HOSTILE.find(h)), fn])
	SttDiagSheet.stt_script_override = _fake
	ok(SttDiagSheet.device_token("/home/sampleuser/cache/model.bin") == "-" and SttDiagSheet.device_token("/data/user/0/private/model.bin") == "-", "device (OS model name): a path is rejected")
	ok(not SttDiagSheet.report_text().contains("sampleuser"), "the real block has no user name")


func _test_missing_stt() -> void:
	print("[LocalStt missing or broken]")
	var none: GDScript = _script(FAKE_NO_STATS)
	SttDiagSheet.stt_script_override = none
	var text: String = SttDiagSheet.report_text()
	var tokens: Dictionary = _all_tokens(text)
	ok(text.contains("\nstt=missing\n"), "a script without stats(): the text has an 'stt=missing' line")
	ok(tokens["stt_runs"] == "-" and tokens["rss_mb_peak"] == "-", "... and the speed numbers read -")
	var all_keys := true
	for k in KEYS:
		all_keys = all_keys and tokens.has(k)
	ok(all_keys, "... and every key is still there")
	ok(text.split("\n")[0] == "hoehwa-diag 1" and not _leaks(text), "... and the text still starts right and leaks nothing")
	var nul: GDScript = _script(FAKE_STATS_NULL)
	SttDiagSheet.stt_script_override = nul
	var t2: Dictionary = _all_tokens(SttDiagSheet.report_text())
	ok(t2["stt_runs"] == "-", "stats() that returns null reads as no numbers, no crash")
	SttDiagSheet.stt_script_override = null
	var exists: bool = ResourceLoader.exists(SttDiagSheet.LOCAL_STT_PATH)
	var t3: String = SttDiagSheet.report_text()
	if exists:
		ok(t3.split("\n")[0] == "hoehwa-diag 1" and _allowed_chars(t3) and not _leaks(t3), "override null, LocalStt present: its stats() are used, the text stays clean")
	else:
		ok(t3.contains("\nstt=missing\n"), "override null, no local_stt.gd: 'stt=missing'")
	SttDiagSheet.stt_script_override = _fake


# ---------------------------------------------------------------- the sheet

func _open_diag() -> Sheet:
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.name = "DiagHost"
	add_child(host)
	var sh: Sheet = SttDiagSheet.open(host) as Sheet
	return sh


func _close_diag(sh: Sheet) -> void:
	if sh != null and not sh.is_closed():
		sh.close()
	var host: Node = get_node_or_null("DiagHost")
	if host != null:
		host.queue_free()


func _test_sheet_flow() -> void:
	print("[sheet: record -> 20 -> 60 -> copy]")
	Engine.set_meta("diag_calls", [])
	_clip = ""
	_clip_count = 0
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), "duration": 3.2}
	var sh := _open_diag()
	await _frames(3)
	ok(sh != null and not sh.is_closed(), "SttDiagSheet.open returns an open Sheet")
	var rec: Button = _btn(sh, "DiagRecBtn")
	var b20: Button = _btn(sh, "DiagBench20Btn")
	var b60: Button = _btn(sh, "DiagBench60Btn")
	var cp: Button = _btn(sh, "DiagCopyBtn")
	ok(rec != null and b20 != null and b60 != null and cp != null, "DiagRecBtn, DiagBench20Btn, DiagBench60Btn, DiagCopyBtn exist")
	ok(_btn(sh, "DiagRecBtn").text == "한 문장 녹음" and b20.text == "20회 속도 시험" and b60.text == "60회 연속 시험" and cp.text == "결과 복사", "button texts: 한 문장 녹음, 20회 속도 시험, 60회 연속 시험, 결과 복사")
	ok(_all_text(sh).contains(SttDiagSheet.TARGET), "the fixed sentence is shown for the person to read")
	ok(sh.find_child("DiagBatStart", true, false) is SpinBox and sh.find_child("DiagBatEnd", true, false) is SpinBox, "DiagBatStart and DiagBatEnd are SpinBoxes")
	# a test before any recording
	_press(b20, "20회 속도 시험 (녹음 전)")
	await _frames(3)
	ok((Engine.get_meta("diag_calls", []) as Array).is_empty() and _all_text(sh).contains(SttDiagSheet.TXT_NEED_RECORD), "before a recording the test does not run and says to record first")
	_press(rec, "한 문장 녹음")
	await _frames(3)
	ok(_all_text(sh).contains("녹음했어요 · 3.2초"), "the recording shows its length (3.2초)")
	_press(b20, "20회 속도 시험")
	ok(b20.disabled and rec.disabled and b60.disabled, "while a test runs the three test buttons are off")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 1 and not b20.disabled)
	await _frames(2)
	var calls: Array = Engine.get_meta("diag_calls", [])
	ok(calls.size() == 1 and int((calls[0] as Dictionary)["n"]) == 20, "LocalStt.bench was called with n == 20")
	ok(calls.size() == 1 and int((calls[0] as Dictionary)["wav"]) == 10 and str((calls[0] as Dictionary)["target"]) == SttDiagSheet.TARGET, "... with the recorded wav and the fixed sentence")
	var r20: Label = sh.find_child("DiagResult20", true, false) as Label
	ok(r20 != null and r20.visible and r20.text.contains("중앙값 1.8초") and r20.text.contains("가장 느린 3.1초") and r20.text.contains("실패 1"), "result line: 중앙값 1.8초, 가장 느린 3.1초, 실패 1 (%s)" % (r20.text if r20 != null else ""))
	ok(r20 != null and r20.text.contains("메모리 +230 MB"), "result line: 메모리 +230 MB (410 - 180)")
	_press(b60, "60회 연속 시험")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 2 and not b60.disabled)
	await _frames(2)
	calls = Engine.get_meta("diag_calls", [])
	ok(calls.size() == 2 and int((calls[1] as Dictionary)["n"]) == 60, "LocalStt.bench was called with n == 60")
	var r60: Label = sh.find_child("DiagResult60", true, false) as Label
	ok(r60 != null and r60.visible and r60.text.contains("1.5분") and r60.text.contains("실패 1"), "60-run line: 1.5분, 실패 1 (%s)" % (r60.text if r60 != null else ""))
	var bs: SpinBox = sh.find_child("DiagBatStart", true, false) as SpinBox
	var be: SpinBox = sh.find_child("DiagBatEnd", true, false) as SpinBox
	bs.value = 80
	be.value = 77
	_press(cp, "결과 복사")
	await _frames(2)
	ok(_clip_count == 1 and _clip.split("\n")[0] == "hoehwa-diag 1", "[결과 복사] sends one text whose first line is hoehwa-diag 1 to the clipboard hook")
	var b20t: Dictionary = _line_tokens(_line_of(_clip, "bench20"))
	var b60t: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(b20t.get("n", "") == "20" and b20t.get("ok", "") == "19" and b20t.get("p50_ms", "") == "1800", "the copied bench20 line has the numbers of the run")
	ok(b60t.get("n", "") == "60" and b60t.get("fail", "") == "1" and b60t.get("minutes", "") == "1.50" and b60t.get("battery_start", "") == "80" and b60t.get("battery_end", "") == "77", "the copied bench60 line has the run and both batteries")
	ok(not _leaks(_clip) and _allowed_chars(_clip), "the copied text leaks nothing")
	var screen: String = _all_text(sh)
	ok(not screen.contains("hoehwa-diag") and not screen.contains("stt_runs=") and not screen.contains(MARK), "the raw block is not on the screen")
	ok(not _has_5digits(screen), "no run of five digits on the screen")
	ok(_all_text(sh).contains(SttDiagSheet.TXT_COPIED), "the sheet says it copied")
	# a copy without touching the batteries writes "-"
	_clip = ""
	_close_diag(sh)
	await _frames(3)
	var sh2 := _open_diag()
	await _frames(3)
	_press(_btn(sh2, "DiagCopyBtn"), "결과 복사 (배터리 안 적음)")
	await _frames(2)
	var b60t2: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(b60t2.get("battery_start", "") == "-" and b60t2.get("battery_end", "") == "-", "batteries that were not typed are written as -")
	_close_diag(sh2)
	await _frames(3)


func _test_sheet_failures() -> void:
	print("[sheet: failures]")
	SttDiagSheet._session = {}
	Engine.set_meta("diag_calls", [])
	var fails := [
		[{"ok": false, "wav": PackedByteArray(), "duration": 0.0}, SttDiagSheet.TXT_REC_FAIL, "a failed recording"],
		[{"ok": true, "wav": PackedByteArray(), "duration": 1.0}, SttDiagSheet.TXT_REC_FAIL, "an empty wav"],
		[{"ok": true, "silent": true, "wav": PackedByteArray([1, 2, 3]), "duration": 1.0}, SttDiagSheet.TXT_REC_SILENT, "a silent recording"],
		[{"ok": true, "wav": "not bytes", "duration": 1.0}, SttDiagSheet.TXT_REC_FAIL, "a wav that is not bytes"],
		[null, SttDiagSheet.TXT_REC_FAIL, "a hook that returns null"],
		[7, SttDiagSheet.TXT_REC_FAIL, "a hook that returns a number"],
	]
	for f in fails:
		var res: Variant = f[0]
		SttDiagSheet.record_hook = func() -> Variant: return res
		var sh := _open_diag()
		await _frames(3)
		_press(_btn(sh, "DiagRecBtn"), "한 문장 녹음 (%s)" % f[2])
		await _frames(3)
		ok(_all_text(sh).contains(str(f[1])) and _all_text(sh).contains(SttDiagSheet.TXT_NOT_RECORDED), "%s: the sheet says so and stays 'not recorded'" % f[2])
		_press(_btn(sh, "DiagBench20Btn"), "20회 속도 시험 (%s)" % f[2])
		await _frames(3)
		ok((Engine.get_meta("diag_calls", []) as Array).is_empty(), "%s: the speed test does not start" % f[2])
		_close_diag(sh)
		await _frames(3)
	# the speed test with no LocalStt at all
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4]), "duration": 2.0}
	SttDiagSheet.stt_script_override = _script(FAKE_NO_STATS)
	var sh3 := _open_diag()
	await _frames(3)
	_press(_btn(sh3, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	_press(_btn(sh3, "DiagBench20Btn"), "20회 속도 시험 (LocalStt 없음)")
	await _frames(3)
	ok(_all_text(sh3).contains(SttDiagSheet.TXT_NO_STT), "without LocalStt the speed test says the app has no phone speech recognition")
	_close_diag(sh3)
	await _frames(3)
	SttDiagSheet.stt_script_override = _fake
	# a bench that returns garbage
	var junk: GDScript = _script("""extends RefCounted
static func stats() -> Dictionary:
	return {}
static func bench(_w: PackedByteArray, _t: String, _n: int, _cb: Callable = Callable()):
	return "ZZ_TGT_4417"
""")
	SttDiagSheet.stt_script_override = junk
	var sh4 := _open_diag()
	await _frames(3)
	_press(_btn(sh4, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	_press(_btn(sh4, "DiagBench20Btn"), "20회 속도 시험 (엉뚱한 결과)")
	await _frames(4)
	ok(_all_text(sh4).contains(SttDiagSheet.TXT_BENCH_FAIL) and not _all_text(sh4).contains(MARK) and not _btn(sh4, "DiagBench20Btn").disabled, "a bench that returns text: 'could not finish', nothing shown, buttons usable again")
	_close_diag(sh4)
	await _frames(3)
	SttDiagSheet.stt_script_override = _fake
	SttDiagSheet.record_hook = Callable()


func _test_battery_boxes() -> void:
	print("[battery boxes]")
	var sh := _open_diag()
	await _frames(3)
	var bs: SpinBox = sh.find_child("DiagBatStart", true, false) as SpinBox
	var be: SpinBox = sh.find_child("DiagBatEnd", true, false) as SpinBox
	ok(bs.min_value == 0.0 and bs.max_value == 100.0 and be.min_value == 0.0 and be.max_value == 100.0, "both boxes allow 0 to 100")
	bs.value = 250
	be.value = -40
	ok(bs.value == 100.0 and be.value == 0.0, "values outside 0..100 are cut (250 -> 100, -40 -> 0)")
	bs.get_line_edit().text = "999"
	bs.apply()
	ok(bs.value == 100.0, "typed text 999 is cut to 100")
	bs.get_line_edit().text = "abc"
	bs.apply()
	ok(bs.value >= 0.0 and bs.value <= 100.0, "typed text abc leaves a value inside 0..100 (%s)" % str(bs.value))
	bs.value = 63
	be.value = 55
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2]), "duration": 1.0}
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (배터리 63 / 55)")
	await _frames(2)
	var b60t: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(b60t.get("battery_start", "") == "63" and b60t.get("battery_end", "") == "55", "the copied batteries are 63 and 55")
	_close_diag(sh)
	await _frames(3)
	SttDiagSheet.record_hook = Callable()


## The default recording path (no record_hook): Recorder in its desktop test mode, the second press ends it.
func _test_real_recorder() -> void:
	print("[sheet: the real Recorder path]")
	SttDiagSheet.record_hook = Callable()
	Recorder.mode_override = "phone"
	Recorder.test_audio_source = func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true)
	Engine.set_meta("diag_calls", [])
	var sh := _open_diag()
	await _frames(3)
	var rec: Button = _btn(sh, "DiagRecBtn")
	_press(rec, "한 문장 녹음 (Recorder)")
	var live: bool = await _until(func() -> bool: return Recorder.recording and Recorder.elapsed > 0.05)
	ok(live and rec.text == "녹음 끝내기", "the recorder runs and the button reads 녹음 끝내기")
	_press(rec, "녹음 끝내기")
	var done: bool = await _until(func() -> bool: return rec.text == "한 문장 녹음" and not Recorder.stopping)
	await _frames(2)
	ok(done and not Recorder.recording, "the second press ends the recording")
	ok(_all_text(sh).contains("녹음했어요"), "the sheet shows the recording as taken (%s)" % ("yes" if _all_text(sh).contains("녹음했어요") else _all_text(sh).replace("\n", " | ").substr(0, 160)))
	_press(_btn(sh, "DiagBench20Btn"), "20회 속도 시험 (Recorder 녹음)")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 1)
	await _frames(3)
	var calls: Array = Engine.get_meta("diag_calls", [])
	ok(calls.size() == 1 and int((calls[0] as Dictionary)["wav"]) > 1000, "the recorded WAV from the Recorder reached LocalStt.bench (%d bytes)" % (int((calls[0] as Dictionary)["wav"]) if calls.size() == 1 else -1))
	# closing the sheet while recording stops the recorder
	var rec2: Button = _btn(sh, "DiagRecBtn")
	_press(rec2, "한 문장 녹음 (닫기 시험)")
	await _until(func() -> bool: return Recorder.recording)
	_close_diag(sh)
	await _frames(4)
	ok(not Recorder.recording, "closing the sheet while recording cancels the recorder")
	Recorder.mode_override = ""
	Recorder.test_audio_source = Callable()
	await _frames(2)


## The person closes the sheet while it is busy: nothing may log an engine error ("class instance is gone"), the result is
## dropped, the recording is cancelled, and a sheet opened afterwards works.
func _test_close_while_busy() -> void:
	print("[sheet: closed while busy]")
	var rec_hook := func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4, 5, 6]), "duration": 2.0}
	SttDiagSheet.record_hook = rec_hook
	SttDiagSheet._session = {}
	var slow: GDScript = _script(FAKE_SLOW)
	ok(slow != null and slow.has_method("bench"), "the slow stand-in compiles")
	SttDiagSheet.stt_script_override = slow
	# 1. closed (sheet.close) in the middle of a bench that takes many frames
	Engine.set_meta("diag_calls", [])
	Engine.set_meta("slow_done", false)
	var errs0: int = _cap.count()
	var sh := _open_diag()
	await _frames(3)
	_press(_btn(sh, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	var b20: Button = _btn(sh, "DiagBench20Btn")
	_press(b20, "20회 속도 시험 (곧 닫음)")
	await _frames(3)
	ok(b20.disabled, "the bench is running (button off)")
	var prog: Label = sh.find_child("DiagProgress", true, false) as Label
	var done_n: int = int(prog.text.trim_prefix(SttDiagSheet.TXT_RUNNING).get_slice("/", 0)) if prog != null else -1
	ok(prog != null and prog.visible and prog.text == SttDiagSheet.TXT_RUNNING + CourseModel.progress_label("", done_n, 20), "the progress text is CourseModel.progress_label (%s)" % (prog.text if prog != null else ""))
	_close_diag(sh)
	await _until(func() -> bool: return bool(Engine.get_meta("slow_done", false)))
	await _frames(4)
	ok(bool(Engine.get_meta("slow_done", false)), "the bench kept running to its end after the close")
	ok(_cap.count() == errs0, "closing during a bench logs no engine error (%d new)" % (_cap.count() - errs0))
	ok(not SttDiagSheet._session.has("bench20"), "the result of a bench that was closed on is dropped")
	# 2. a sheet opened afterwards is normal
	var sh2 := _open_diag()
	await _frames(3)
	var r20: Label = sh2.find_child("DiagResult20", true, false) as Label
	ok(r20 != null and not r20.visible and not _btn(sh2, "DiagBench20Btn").disabled and not _btn(sh2, "DiagRecBtn").disabled, "the reopened sheet shows no result and its buttons are usable")
	SttDiagSheet.stt_script_override = _fake
	Engine.set_meta("diag_calls", [])
	_press(_btn(sh2, "DiagRecBtn"), "한 문장 녹음 (다시 열린 시트)")
	await _frames(3)
	var b20b: Button = _btn(sh2, "DiagBench20Btn")
	_press(b20b, "20회 속도 시험 (다시 열린 시트)")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 1 and not b20b.disabled)
	await _frames(2)
	r20 = sh2.find_child("DiagResult20", true, false) as Label
	ok(r20 != null and r20.visible and r20.text.contains("중앙값 1.8초"), "the reopened sheet runs a bench normally")
	_close_diag(sh2)
	await _frames(3)
	# 3. the host is freed (the screen goes away) without closing the sheet first
	SttDiagSheet.stt_script_override = slow
	Engine.set_meta("slow_done", false)
	errs0 = _cap.count()
	var sh3 := _open_diag()
	await _frames(3)
	_press(_btn(sh3, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	_press(_btn(sh3, "DiagBench60Btn"), "60회 연속 시험 (화면째 닫음)")
	await _frames(2)
	get_node("DiagHost").free()
	await _until(func() -> bool: return bool(Engine.get_meta("slow_done", false)))
	await _frames(4)
	ok(_cap.count() == errs0, "freeing the screen during a bench logs no engine error (%d new)" % (_cap.count() - errs0))
	ok(not SttDiagSheet._session.has("bench60"), "... and the result is dropped")
	# 4. closed while the recording hook is still waiting
	var slow_rec := func() -> Dictionary:
		for i in 8:
			await get_tree().process_frame
		return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4]), "duration": 1.0}
	SttDiagSheet.record_hook = slow_rec
	errs0 = _cap.count()
	var sh4 := _open_diag()
	await _frames(3)
	_press(_btn(sh4, "DiagRecBtn"), "한 문장 녹음 (곧 닫음)")
	await _frames(2)
	_close_diag(sh4)
	await _frames(14)
	ok(_cap.count() == errs0, "closing while the recording hook waits logs no engine error (%d new)" % (_cap.count() - errs0))
	# 5. copy and close in the same frame
	SttDiagSheet.stt_script_override = _fake
	SttDiagSheet.record_hook = rec_hook
	_clip = ""
	errs0 = _cap.count()
	var sh5 := _open_diag()
	await _frames(3)
	_press(_btn(sh5, "DiagCopyBtn"), "결과 복사 (바로 닫음)")
	_close_diag(sh5)
	await _frames(4)
	ok(_clip.split("
")[0] == "hoehwa-diag 1" and _cap.count() == errs0, "copy and close in one frame: the text is copied, no engine error")
	# 6. recording through the real Recorder: closed while stopping, then while recording
	SttDiagSheet.record_hook = Callable()
	Recorder.mode_override = "phone"
	Recorder.test_audio_source = func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true)
	errs0 = _cap.count()
	var sh6 := _open_diag()
	await _frames(3)
	var rec6: Button = _btn(sh6, "DiagRecBtn")
	_press(rec6, "한 문장 녹음 (Recorder)")
	await _until(func() -> bool: return Recorder.recording and Recorder.elapsed > 0.05)
	_press(rec6, "녹음 끝내기 (바로 닫음)")
	_close_diag(sh6)
	await _until(func() -> bool: return not Recorder.stopping and not Recorder.recording)
	await _frames(4)
	ok(not Recorder.recording and not Recorder.stopping and _cap.count() == errs0, "closed while the recording is being finished: the recorder ends, no engine error (%d new)" % (_cap.count() - errs0))
	var sh7 := _open_diag()
	await _frames(3)
	_press(_btn(sh7, "DiagRecBtn"), "한 문장 녹음 (Recorder, 닫기)")
	await _until(func() -> bool: return Recorder.recording)
	_close_diag(sh7)
	await _frames(6)
	ok(not Recorder.recording and _cap.count() == errs0, "closed while recording: the recorder is cancelled, no engine error (%d new)" % (_cap.count() - errs0))
	Recorder.mode_override = ""
	Recorder.test_audio_source = Callable()
	# 7. open and close again and again
	for i in 5:
		var shx := _open_diag()
		await _frames(1)
		_close_diag(shx)
		await _frames(1)
	ok(_cap.count() == errs0 and not Sheet.is_open(), "five quick open/close rounds: no engine error, no sheet left")
	SttDiagSheet.record_hook = Callable()
	SttDiagSheet.stt_script_override = _fake


## The production fade-out (Sheet.animate on): `closed` is sent at once and the sheet stays in the tree for 200 ms more.
## From the first moment nothing may land in it: a bench result, a recording result, a live recording.
func _test_animated_close() -> void:
	print("[sheet: closed with the fade-out on]")
	Sheet.animate = true
	SttDiagSheet._session = {}
	SttDiagSheet.stt_script_override = _fake
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4]), "duration": 1.0}
	Engine.set_meta("diag_calls", [])
	var errs0: int = _cap.count()
	# 1. a bench that finishes while the sheet fades out
	var sh := _open_diag()
	await get_tree().create_timer(0.45).timeout
	var body: Node = sh.find_child("SttDiagBody", true, false)
	_press(_btn(sh, "DiagRecBtn"), "한 문장 녹음")
	await _frames(2)
	_press(_btn(sh, "DiagBench20Btn"), "20회 속도 시험 (바로 [닫기])")
	_press(sh.buttons["close"], "닫기 (애니메이션 켠 채)")
	ok(sh.is_closed() and sh.is_inside_tree() and body.is_inside_tree(), "the sheet is closed but still in the tree (fading out)")
	var late: bool = false
	for i in 4:
		await get_tree().process_frame
		if is_instance_valid(body) and body.is_inside_tree() and (SttDiagSheet._session.has("bench20") or not (body.extra as Dictionary).is_empty()):
			late = true
	ok(not late and not SttDiagSheet._session.has("bench20"), "the bench result that arrives during the fade-out is dropped (session and sheet unchanged)")
	await get_tree().create_timer(0.35).timeout
	ok(not SttDiagSheet._session.has("bench20") and _cap.count() == errs0, "... and still nothing after the sheet is gone, no engine error")
	# 2. a recording hook that returns during the fade-out
	var slow_rec := func() -> Dictionary:
		for i in 3:
			await get_tree().process_frame
		return {"ok": true, "wav": PackedByteArray([9, 9, 9, 9]), "duration": 1.0}
	SttDiagSheet.record_hook = slow_rec
	var sh2 := _open_diag()
	await get_tree().create_timer(0.45).timeout
	var body2: Node = sh2.find_child("SttDiagBody", true, false)
	_press(_btn(sh2, "DiagRecBtn"), "한 문장 녹음 (바로 [닫기])")
	_press(sh2.buttons["close"], "닫기 (애니메이션 켠 채)")
	var wav_seen: bool = false
	for i in 8:
		await get_tree().process_frame
		if is_instance_valid(body2) and not (body2.wav as PackedByteArray).is_empty():
			wav_seen = true
	ok(not wav_seen, "a recording that returns during the fade-out is not taken")
	await get_tree().create_timer(0.35).timeout
	# 3. a live recording is cancelled at the moment of closing, not 200 ms later
	SttDiagSheet.record_hook = Callable()
	Recorder.mode_override = "phone"
	Recorder.test_audio_source = func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true)
	var sh3 := _open_diag()
	await get_tree().create_timer(0.45).timeout
	_press(_btn(sh3, "DiagRecBtn"), "한 문장 녹음 (Recorder)")
	await _until(func() -> bool: return Recorder.recording and Recorder.elapsed > 0.05)
	_press(sh3.buttons["close"], "닫기 (녹음 중, 애니메이션 켠 채)")
	ok(not Recorder.recording, "the live recording is cancelled the moment the sheet starts to close")
	await get_tree().create_timer(0.35).timeout
	ok(not Recorder.recording and not Recorder.stopping and _cap.count() == errs0, "... and nothing is left running, no engine error")
	Recorder.mode_override = ""
	Recorder.test_audio_source = Callable()
	Sheet.animate = false
	SttDiagSheet.record_hook = Callable()
	var host: Node = get_node_or_null("DiagHost")
	while host != null:
		host.free()
		host = get_node_or_null("DiagHost")
	await _frames(2)


## A battery value of 0 that the person typed must reach the block; an empty box must not.
func _test_battery_zero() -> void:
	print("[battery: a typed 0]")
	SttDiagSheet._session = {}
	var sh := _open_diag()
	await _frames(3)
	var bs: SpinBox = sh.find_child("DiagBatStart", true, false) as SpinBox
	var be: SpinBox = sh.find_child("DiagBatEnd", true, false) as SpinBox
	ok(bs.get_line_edit().text == "" and be.get_line_edit().text == "", "both boxes start empty (nothing entered)")
	_clip = ""
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (배터리 비움)")
	var t0: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(_line_of(_clip, "bench60") == "bench60 -", "empty boxes copy as 'bench60 -' [%s]" % _line_of(_clip, "bench60"))
	bs.get_line_edit().text = "0"
	bs.apply()
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (시작 0, 입력 후 적용)")
	var t1: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(t1.get("battery_start", "") == "0" and t1.get("battery_end", "x") == "-", "a typed and applied 0 copies as battery_start=0 (end stays -) [%s]" % _line_of(_clip, "bench60"))
	be.get_line_edit().text = "0"
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (끝 0, 입력만 하고 확정 안 함)")
	var t2: Dictionary = _line_tokens(_line_of(_clip, "bench60"))
	ok(t2.get("battery_start", "") == "0" and t2.get("battery_end", "") == "0", "a 0 typed but not confirmed is taken when copying (battery_end=0)")
	be.get_line_edit().text = ""
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (끝을 다시 비움)")
	ok(_line_tokens(_line_of(_clip, "bench60")).get("battery_end", "") == "-", "a box that is emptied again copies as -")
	be.get_line_edit().text = "qwe"
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (끝에 글자)")
	ok(_line_tokens(_line_of(_clip, "bench60")).get("battery_end", "") == "-" and not _clip.contains("qwe"), "typed letters copy as -")
	be.get_line_edit().text = "250"
	_press(_btn(sh, "DiagCopyBtn"), "결과 복사 (끝 250)")
	ok(_line_tokens(_line_of(_clip, "bench60")).get("battery_end", "") == "100", "250 typed copies as 100")
	be.value = 5
	ok(be.get_line_edit().text.replace("%", "").strip_edges() == "5", "stepping a box shows its number")
	_close_diag(sh)
	await _frames(3)


func _test_reopen_keeps_numbers() -> void:
	print("[sheet: reopen]")
	SttDiagSheet._session = {}
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4]), "duration": 2.0}
	Engine.set_meta("diag_calls", [])
	var sh := _open_diag()
	await _frames(3)
	_press(_btn(sh, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	var b20: Button = _btn(sh, "DiagBench20Btn")
	_press(b20, "20회 속도 시험")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 1 and not b20.disabled)
	await _frames(2)
	_close_diag(sh)
	await _frames(3)
	var sh2 := _open_diag()
	await _frames(3)
	var r20: Label = sh2.find_child("DiagResult20", true, false) as Label
	ok(r20 != null and r20.visible and r20.text.contains("중앙값"), "a reopened sheet shows the speed result of this run again")
	_press(_btn(sh2, "DiagCopyBtn"), "결과 복사 (다시 열기)")
	await _frames(2)
	ok(_line_tokens(_line_of(_clip, "bench20")).get("n", "") == "20", "... and copies it")
	_close_diag(sh2)
	await _frames(3)
	SttDiagSheet.record_hook = Callable()


func _test_layout() -> void:
	print("[layout]")
	SttDiagSheet.record_hook = func() -> Dictionary: return {"ok": true, "wav": PackedByteArray([1, 2, 3, 4]), "duration": 2.0}
	Engine.set_meta("diag_calls", [])
	var sh := _open_diag()
	await _frames(3)
	_press(_btn(sh, "DiagRecBtn"), "한 문장 녹음")
	await _frames(3)
	var b20: Button = _btn(sh, "DiagBench20Btn")
	_press(b20, "20회 속도 시험")
	await _until(func() -> bool: return (Engine.get_meta("diag_calls", []) as Array).size() >= 1 and not b20.disabled)
	await _frames(3)
	var over: Array = []
	var small: Array = []
	for n in sh.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r: Rect2 = c.get_global_rect()
		if r.end.x > 412.5 or r.position.x < -0.5:
			over.append("%s %s" % [c.name, str(r)])
		if (c is Button or c is SpinBox) and c.size.y < 47.5:
			small.append("%s %s" % [c.name, str(c.size)])
	ok(over.is_empty(), "no control of the sheet sticks out of the 412 px screen (%s)" % str(over.slice(0, 3)))
	ok(small.is_empty(), "every button and number box of the sheet is a touch target (%s)" % str(small.slice(0, 3)))
	ok(not _has_5digits(_all_text(sh)), "no run of five digits on the screen")
	_close_diag(sh)
	await _frames(3)
	SttDiagSheet.record_hook = Callable()


func _test_sources() -> void:
	print("[sources]")
	var f := FileAccess.open("res://scripts/ui/stt_diag_sheet.gd", FileAccess.READ)
	var src: String = f.get_as_text() if f != null else ""
	ok(src != "" and not src.contains("Color(\"#") and not src.contains("HTTP" + "Request") and not src.contains("HTTP" + "Client") and not src.contains("FileAccess"), "stt_diag_sheet.gd: no Color(\"#, no network client, no file access")
	var re := RegEx.new()
	re.compile("(print|push_warning|push_error|printerr)\\(.*(text|target|transcript|words|url|path)")
	ok(re.search(src) == null, "stt_diag_sheet.gd: no log line that names text, target, transcript, words, url or path (X-7)")
	var bad: PackedStringArray = PackedStringArray()
	for pat in ["%d" + " / " + "%d", "%d" + "/" + "%d", "0 / " + "%d"]:
		if src.contains(pat):
			bad.append(pat)
	ok(bad.is_empty(), "stt_diag_sheet.gd: no hand-made progress text (CourseModel.progress_label only) %s" % str(bad))
	ok(src.contains("CourseModel.progress_label"), "stt_diag_sheet.gd builds its progress text with CourseModel.progress_label")


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
