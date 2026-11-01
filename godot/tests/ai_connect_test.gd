extends Node
## AI 연결 화면 (docs/onetouch_install_design.md §3.2, §3.4, §3.5, §5 C): AiConnectSheet, AiConnectCard, Backend.llm_state,
## Api.ai_not_connected, HomeAi 자리, main.gd 연결.
##   PC:   godot --headless --path godot res://tests/ai_connect_test.tscn
##   폰:   godot --headless --path godot res://tests/ai_connect_test.tscn -- --phone
## 마지막 줄: "== ai_connect_test result: N passed, M failed ==", 종료 코드 1 = 실패.
## 백엔드는 이 파일 안의 GDScript 가짜 서버(FakeBackend, 127.0.0.1:18853)다. 실제 백엔드·OpenCode·AI·8770/8775/8776 접속 없음.
## 비밀값: 표식 키 sk-SENTINEL-<무작위 24자> 만 쓴다. 시험이 모으는 곳 어디에도 키가 없어야 한다:
##   Godot 출력(Logger 로 가로챔), 토스트, prefs, user:// 의 모든 파일, 화면 글자, 가짜 서버가 받은 모든 요청(POST /llm/connect 1번만).
## 파일은 user://test_ai_connect/ 에만 쓴다(설정·진행·기록 경로를 그리로 돌림). 검사기 자체 시험: _selftest().

const PORT := 18853
const FAKE := "http://127.0.0.1:18853"
const DIR := "user://test_ai_connect"
const MAIN_SRC := "res://scripts/main.gd"
const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _fake: FakeBackend = null
var _cap: LogCap = null
var _toasts: Array = []
var _snacks: Array = []
var _sentinel: String = ""
var _opened: Array = []
var _clip: String = ""
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_base: String
var _old_status: Variant
var _old_health: Dictionary


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


func _until(cond: Callable, max_sec: float = 15.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) / 1000.0 < max_sec:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _make_sentinel() -> String:
	var b: PackedByteArray = Crypto.new().generate_random_bytes(24)
	var s := "sk-SENTINEL-"
	for i in 24:
		s += CHARS[int(b[i]) % CHARS.length()]
	return s


func _ready() -> void:
	_phone = Platform.is_phone()
	print("== ai_connect_test start (%s) ==" % ("phone" if _phone else "pc"))
	_cap = LogCap.new()
	OS.add_logger(_cap)
	_sentinel = _make_sentinel()
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_base = Api.base_url
	_old_status = Backend.status
	_old_health = Backend.health.duplicate(true)
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	Store.prefs = {}
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	Toast.snack.connect(func(t: String, a: String, cb: Callable) -> void: _snacks.append([t, a, cb]))
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Sheet.animate = false
	AiConnectSheet.poll_sec = 0.05
	AiConnectSheet.opener = func(url: String) -> void: _opened.append(url)
	AiConnectSheet.clip_get = func() -> String: return _clip
	AiConnectSheet.clip_set = func(t: String) -> void: _clip = t
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "light", 1.0)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	_fake = FakeBackend.new()
	add_child(_fake)
	ok(_fake.setup(PORT), "fake backend listens on 127.0.0.1:%d" % PORT)
	if _phone:
		Api.set_remote(FAKE, "test-token")
	else:
		Api.base_url = FAKE
	await _frames(2)

	_selftest()
	_wording()
	if _phone:
		await _phone_part()
	else:
		await _pc_part()
	await _main_wiring()
	_leak_check("final")
	_finish()


func _finish() -> void:
	OS.remove_logger(_cap)
	AiConnectSheet.opener = Callable()
	AiConnectSheet.clip_get = Callable()
	AiConnectSheet.clip_set = Callable()
	AiConnectSheet.force_phone = -1
	if _fake != null:
		_fake.stop()
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	_rm_rf(DIR)
	print("== ai_connect_test result: %d passed, %d failed ==" % [passed, failed])
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


# ================================================================ the secret-leak detector

## Every place the key must never be. `extra` = more text to look in (the self test feeds it a leaking line).
## Returns the names of the places that hold the sentinel (or its last 12 characters).
func _find_leaks(sentinel: String, extra: Array = []) -> Array:
	var hits: Array = []
	var tail: String = sentinel.substr(sentinel.length() - 12)
	var has := func(text: String) -> bool: return text.contains(sentinel) or text.contains(tail)
	for line in _cap.snapshot():
		if has.call(str(line)):
			hits.append("godot output")
			break
	for t in _toasts:
		if has.call(str(t)):
			hits.append("toast")
			break
	for s in _snacks:
		if has.call(str(s[0]) + str(s[1])):
			hits.append("snack")
			break
	if has.call(JSON.stringify(Store.prefs)) or has.call(JSON.stringify(Backend.health)):
		hits.append("prefs/health")
	for e in extra:
		if has.call(str(e)):
			hits.append("extra")
			break
	for f in _user_files("user://"):
		var data: PackedByteArray = FileAccess.get_file_as_bytes(f)
		if data.size() > 0 and has.call(data.get_string_from_utf8()):
			hits.append("user file " + f)
	for lbl in _screen_texts(get_tree().root):
		if has.call(lbl):
			hits.append("screen text")
			break
	return hits


func _user_files(root: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(root)
	if d == null:
		return out
	for f in d.get_files():
		out.append(root.path_join(f))
	for sub in d.get_directories():
		out.append_array(_user_files(root.path_join(sub)))
	return out


func _screen_texts(n: Node) -> Array:
	var out: Array = []
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append((n as Button).text)
	elif n is LineEdit:
		out.append((n as LineEdit).text + (n as LineEdit).placeholder_text)
	for c in n.get_children():
		out.append_array(_screen_texts(c))
	return out


func _leak_check(where: String) -> void:
	var hits: Array = _find_leaks(_sentinel)
	ok(hits.is_empty(), "no trace of the key anywhere after %s (%s)" % [where, str(hits)])


## Number of requests in `log` whose raw text holds the key.
func _key_requests(log: Array, key: String) -> Array:
	var out: Array = []
	for e in log:
		if str(e["raw"]).contains(key) or str(e["path"]).contains(key):
			out.append(e)
	return out


func _selftest() -> void:
	# the detector must FAIL on a leak: a clean state is clean, a leaking line / file / toast / request is found
	var probe: String = "sk-" + "SENTINEL-selftestselftestzz"   # joined at run time so the release secret scan does not flag this test marker
	ok(_find_leaks(probe).is_empty(), "selftest: nothing leaks for an unused marker")
	ok(not _find_leaks(probe, ["the key is " + probe]).is_empty(), "selftest: a text holding the key is found")
	ok(not _find_leaks(probe, ["only the tail testselftestzz"]).is_empty(), "selftest: the last 12 characters alone are found too")
	_cap.inject("planted " + probe)
	ok(not _find_leaks(probe).is_empty(), "selftest: a Godot output line holding the key is found")
	_cap.clear_injected()
	ok(_find_leaks(probe).is_empty(), "selftest: and gone again after clearing")
	_toasts.append(["error", probe])
	ok(not _find_leaks(probe).is_empty(), "selftest: a toast holding the key is found")
	_toasts.pop_back()
	var canary: String = DIR.path_join("canary.txt")
	var f := FileAccess.open(canary, FileAccess.WRITE)
	f.store_string("x" + probe + "y")
	f.close()
	ok(not _find_leaks(probe).is_empty(), "selftest: a file in user:// holding the key is found")
	DirAccess.remove_absolute(_g(canary))
	ok(_find_leaks(probe).is_empty(), "selftest: and gone again after deleting it")
	var lbl := Label.new()
	lbl.text = "x" + probe
	add_child(lbl)
	ok(not _find_leaks(probe).is_empty(), "selftest: a label holding the key is found")
	lbl.free()
	var log: Array = [{"m": "POST", "path": "/llm/connect", "raw": "{\"key\":\"%s\"}" % probe}, {"m": "POST", "path": "/llm/test", "raw": "{\"k\":\"%s\"}" % probe}]
	ok(_key_requests(log, probe).size() == 2, "selftest: a key sent twice counts 2 (so 'exactly 1' can fail)")
	# the Logger really sees print()
	print("ai_connect_test logger probe 7Q")
	ok(_cap.snapshot().any(func(l: Variant) -> bool: return str(l).contains("logger probe 7Q")), "selftest: the Logger copy sees print() output")


# ================================================================ wording, state, slot

func _set_health(state: String, extra: Dictionary = {}) -> void:
	Backend.status = Backend.Status.READY
	var h := {"ok": true, "llm": state == "ready" or state == "blocked", "llm_state": state, "llm_provider": "opencode", "llm_model": "deepseek-v4.1-flash-free",
		"llm_fallback": {"active": false, "until": null, "reason": ""}}
	h.merge(extra, true)
	Backend.health = h
	_fake.health_state = state


func _wording() -> void:
	_set_health("not_connected")
	ok(Backend.llm_state() == "not_connected" and Backend.llm_missing(), "C8: not_connected -> llm_missing")
	var t1: String = Backend.llm_missing_text()
	_set_health("not_installed")
	var t2: String = Backend.llm_missing_text()
	_set_health("blocked", {"llm_fallback": {"active": true, "until": "23:21", "reason": "무료 DeepSeek 사용 한도에 도달했어요. 23:21 이후 다시 시도해요."}})
	var t3: String = Backend.llm_missing_text()
	_set_health("ready")
	ok(t1.contains("연결되지 않았") and t1.contains("AI 연결하기"), "C8: not_connected text names [AI 연결하기] (%s)" % t1)
	if _phone:
		ok(t1 == Backend.NOT_CONNECTED_PHONE_TEXT and t2 == t1, "C8: on the phone not_connected / not_installed both send the person to the PC")
	else:
		ok(t2.contains("구성 요소") and t2.contains("AI 연결하기"), "C8: not_installed text names the components (%s)" % t2)
		ok(t1 != t2, "C8: not_connected and not_installed texts differ")
	ok(t3.contains("23:21") and t3.contains("한도"), "C8: blocked text is llm_fallback.reason (%s)" % t3)
	ok(t3 != t1 and t3 != t2, "C8: the blocked text differs")
	ok(not Backend.llm_missing(), "ready -> not missing")
	_set_health("blocked")
	ok(not Backend.llm_missing(), "blocked -> calls are still tried: not missing")
	Backend.health = {"ok": true, "llm": true}
	ok(Backend.llm_state() == "ready" and not Backend.llm_missing(), "an old PC program (llm true, no llm_state) counts as ready")
	Backend.health = {"ok": true, "llm": false}
	ok(Backend.llm_state() == "not_connected" and Backend.llm_missing(), "an old PC program (llm false) counts as not_connected")
	Backend.health = {"ok": true, "llm": true, "llm_state": "bogus"}
	ok(Backend.llm_state() == "ready", "an unknown llm_state falls back to llm")
	ok(not Backend.LLM_LABELS.has("ollama"), "no engine label for the removed local engine")
	# error texts
	ok(AiConnectSheet.fail_text({"err_code": "ai_auth"}) == AiConnectSheet.MSG_AUTH, "fail_text: ai_auth")
	ok(AiConnectSheet.fail_text({"err_code": "bad_key_format"}) == AiConnectSheet.MSG_BAD_FORMAT, "fail_text: bad_key_format")
	ok(AiConnectSheet.fail_text({"err_code": "transport"}) == AiConnectSheet.MSG_NET, "fail_text: transport")
	ok(AiConnectSheet.fail_text({"err_code": "lan_forbidden", "code": 403}) == AiConnectSheet.MSG_LOCAL_ONLY, "fail_text: 403 from the phone path")
	ok(AiConnectSheet.fail_text({"err_code": "zzz", "code": 500, "error": "서버 말"}) == "서버 말", "fail_text: unknown code shows the Korean text of the backend")
	# no engine name of the removed engine in the scripts, except the one migration sentence
	var hits: Array = _scripts_with("ollama")
	ok(hits == ["ai_connect_sheet.gd"], "C7: 'ollama' appears only in the migration sentence of ai_connect_sheet.gd (%s)" % str(hits))
	for f in ["backend.gd", "settings_view.gd", "song_view.gd"]:
		ok(not hits.has(f), "C7: no 'ollama' in " + f)
	# main.gd: the three connections exist
	var src: String = FileAccess.get_file_as_string(MAIN_SRC)
	ok(src.contains("Api.ai_not_connected.connect(AiConnectSheet.auto_open.bind(self))"), "main.gd connects Api.ai_not_connected to AiConnectSheet.auto_open")
	ok(src.contains("HomeAi.provider = AiConnectSheet.home_slot"), "main.gd sets HomeAi.provider")
	ok(src.contains("AiConnectSheet.open(self)"), "main.gd _on_ai_connect opens the sheet")


func _scripts_with(word: String) -> Array:
	var out: Array = []
	for f in _files_under("res://scripts"):
		if str(f).ends_with(".gd") and FileAccess.get_file_as_string(f).to_lower().contains(word):
			out.append(str(f).get_file())
	out.sort()
	return out


func _files_under(root: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(root)
	if d == null:
		return out
	for f in d.get_files():
		out.append(root.path_join(f))
	for sub in d.get_directories():
		out.append_array(_files_under(root.path_join(sub)))
	return out


# ================================================================ PC

func _type_key_and_connect(sh: AiConnectSheet, key: String) -> void:
	sh.key_edit.text = key
	sh.connect_btn.pressed.emit()


## Closes every sheet and waits until no request is in flight (a late /health answer must not undo a state set next).
func _close_sheets() -> void:
	while Sheet.close_top():
		pass
	await _frames(2)
	await _until(func() -> bool: return Api.active_count == 0, 5.0)


func _connect_routes(code: int, json: Variant) -> void:
	_fake.routes["POST /llm/connect"] = func(_b: Dictionary) -> Dictionary: return {"code": code, "json": json}


func _pc_part() -> void:
	AiConnectSheet.force_phone = 0
	_set_health("not_connected")
	await _sheet_basics()
	await _sheet_results()
	await _sheet_install()
	await _auto_open()
	await _notice()
	await _card()
	_set_health("ready")


func _sheet_basics() -> void:
	_fake.reset()
	var sent0: int = Api.sent_count
	var sh: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(3)
	ok(sh != null and AiConnectSheet.is_open() and sh.sheet.title_label.text == "AI 연결하기", "sheet opens with the title 'AI 연결하기'")
	ok(Api.sent_count == sent0 and _fake.log.is_empty(), "opening the sheet sends nothing")
	ok(sh.key_edit.secret == true, "C3: the key box is masked (secret == true)")
	ok(AiConnectSheet.open(self) == sh and Sheet.depth() == 1, "opening again returns the same sheet (one sheet)")
	_opened.clear()
	sh.open_btn.pressed.emit()
	ok(_opened == [AiConnectSheet.LOGIN_URL] and _fake.log.is_empty(), "[OpenCode 열기] opens https://opencode.ai/auth in the browser, no backend call")
	ok(sh.term_label.visible == false, "D8: the terminal guidance is folded at first")
	sh.term_btn.pressed.emit()
	ok(sh.term_label.visible == true and sh.term_label.text.contains("opencode auth login"), "D8: the terminal sentence unfolds (words only)")
	ok(sh.status_label.text == "" and _all_text(sh.sheet).contains("키는 이 PC의 OpenCode에만 저장돼요"), "the 'key stays on this PC' note is on the sheet")
	# empty key: nothing is sent
	sh.connect_btn.pressed.emit()
	await _frames(2)
	ok(sh.status_label.text.contains(AiConnectSheet.MSG_EMPTY) and _fake.log.is_empty(), "an empty key box says so and sends nothing")
	# the happy path with a clipboard that still holds the key (C5)
	_connect_routes(200, {"ok": true, "state": "ready", "tested": true, "seconds": 2.4})
	_clip = _sentinel
	_type_key_and_connect(sh, _sentinel)
	ok(sh.key_edit.text == "", "C3: the box is empty at the moment [연결] is pressed")
	ok(sh.busy and sh.connect_btn.disabled, "while connecting the button waits")
	var done: bool = await _until(func() -> bool: return sh.connected_ok)
	ok(done and sh.status_label.text == AiConnectSheet.MSG_OK, "C4: success text (%s)" % sh.status_label.text)
	var kr: Array = _key_requests(_fake.log, _sentinel)
	ok(kr.size() == 1 and kr[0]["m"] == "POST" and kr[0]["path"] == "/llm/connect", "C3: the key went exactly once, in POST /llm/connect (%d)" % kr.size())
	ok(_clip == "", "C5: a clipboard that still holds the key is emptied after success")
	ok((sh.sheet.buttons["later"] as Button).text == "닫기", "after success the flat button says 닫기")
	await _until(func() -> bool: return _fake.count("GET", "/health") >= 1)
	ok(_fake.count("GET", "/health") >= 1, "after success the app re-reads /health")
	_leak_check("a successful connect")
	await _close_sheets()
	ok(not AiConnectSheet.is_open(), "the sheet closes")

	# a clipboard with other text stays
	_fake.reset()
	var sh2: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(2)
	_clip = "something else I copied"
	_type_key_and_connect(sh2, _sentinel)
	await _until(func() -> bool: return sh2.connected_ok)
	ok(_clip == "something else I copied", "C5: a clipboard with other text is left alone")
	await _close_sheets()


func _sheet_results() -> void:
	# connect answered but the test call was skipped (limit / busy)
	await _one_result(200, {"ok": true, "state": "ready", "tested": false, "note": "한도 또는 서버 사정으로 시험은 건너뛰었어요."}, "시험은 건너뛰었어요", "C4: tested=false")
	await _one_result(503, {"error": "OpenCode 로그인이 만료됐거나 키가 맞지 않아요.", "code": "ai_auth"}, AiConnectSheet.MSG_AUTH, "C4: ai_auth")
	await _one_result(400, {"error": "키 형식이 올바르지 않아요.", "code": "bad_key_format"}, AiConnectSheet.MSG_BAD_FORMAT, "C4: bad_key_format")
	await _one_result(403, {"error": "이 요청은 이 PC에서만 보낼 수 있어요.", "code": "local_only"}, AiConnectSheet.MSG_LOCAL_ONLY, "C4: local_only (403)")
	await _one_result(0, null, AiConnectSheet.MSG_NET, "C4: network failure (the connection is dropped)")
	await _one_result(500, {"error": "서버에서 이상한 일이 생겼어요."}, "서버에서 이상한 일이 생겼어요.", "C4: other error shows the backend's Korean text")


func _one_result(code: int, json: Variant, expect: String, label: String) -> void:
	_fake.reset()
	if code == 0:
		_fake.routes["POST /llm/connect"] = func(_b: Dictionary) -> Dictionary: return {"drop": true}
	else:
		_connect_routes(code, json)
	var sh: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(2)
	_type_key_and_connect(sh, _sentinel)
	var txt: Callable = func() -> bool: return not sh.busy and sh.status_label.text != "" and sh.status_label.text != AiConnectSheet.MSG_CONNECTING
	await _until(txt)
	ok(sh.status_label.text.contains(expect), "%s -> shown on the sheet (%s)" % [label, sh.status_label.text])
	ok(sh.key_edit.text == "" and not sh.busy and sh.key_edit.editable, "%s: box empty, editable again" % label)
	ok(_key_requests(_fake.log, _sentinel).size() <= 1, "%s: the key was sent at most once (no retry)" % label)
	_leak_check(label)
	await _close_sheets()


func _sheet_install() -> void:
	# the connect is refused because OpenCode is missing: components first (progress bar), then ask for the key again
	_fake.reset()
	_connect_routes(503, {"error": "AI 구성 요소가 없어요.", "code": "ai_not_installed"})
	_fake.routes["POST /llm/install"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": true, "state": "running"}}
	_fake.installs = [{"state": "running", "pct": 30, "error": ""}, {"state": "running", "pct": 50, "error": ""}, {"state": "running", "pct": 70, "error": ""},
		{"state": "running", "pct": 90, "error": ""}, {"state": "done", "pct": 100, "error": ""}]
	var sh: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(2)
	_type_key_and_connect(sh, _sentinel)
	var saw_bar: bool = await _until(func() -> bool: return sh.bar.visible and sh.status_label.text.contains("%"))
	ok(saw_bar, "C4: ai_not_installed -> a progress bar with a percent shows (%s)" % sh.status_label.text)
	var done: bool = await _until(func() -> bool: return not sh.installing and not sh.busy)
	ok(done and sh.status_label.text == AiConnectSheet.MSG_INSTALLED and not sh.bar.visible, "C4: after the download the sheet asks for the key again (%s)" % sh.status_label.text)
	var order: Array = []
	for e in _fake.log:
		order.append("%s %s" % [e["m"], e["path"]])
	ok(order.find("POST /llm/connect") < order.find("POST /llm/install") and order.find("POST /llm/install") < order.find("GET /llm/install"), "C4: connect, then POST /llm/install, then GET /llm/install polls (%s)" % str(order))
	ok(_key_requests(_fake.log, _sentinel).size() == 1, "the key was sent once; the install calls carry no key")
	_leak_check("an install round")
	await _close_sheets()

	# install ends in an error
	_fake.reset()
	_fake.routes["POST /llm/install"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": false, "state": "error", "error": "설치 구성 요소 정보가 없어요"}}
	_set_health("not_installed")
	var sh2: AiConnectSheet = AiConnectSheet.open(self)
	var fin: bool = await _until(func() -> bool: return not sh2.installing and sh2.status_label.text.contains("받지 못했어요"))
	ok(fin and sh2.status_label.text.contains("설치 구성 요소 정보가 없어요"), "C4: HTTP 200 {ok:false,state:error} shows the error (%s)" % sh2.status_label.text)
	ok(_fake.count("POST", "/llm/install") == 1, "not_installed in /health: the sheet starts the download by itself, once")
	await _close_sheets()

	# already installed: HTTP 200 {ok:true,state:done}
	_fake.reset()
	_fake.routes["POST /llm/install"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": true, "state": "done"}}
	var sh3: AiConnectSheet = AiConnectSheet.open(self)
	var fin3: bool = await _until(func() -> bool: return not sh3.installing and sh3.status_label.text == AiConnectSheet.MSG_INSTALLED)
	ok(fin3 and _fake.count("GET", "/llm/install") == 0, "already installed: {ok:true,state:done} ends at once, no polling (%s | %s | %s)" % [str(fin3), sh3.status_label.text, str(_fake.log.map(func(e: Dictionary) -> String: return e["m"] + e["path"]))])
	await _close_sheets()

	# the download itself fails while running
	_fake.reset()
	_fake.routes["POST /llm/install"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": true, "state": "running"}}
	_fake.installs = [{"state": "running", "pct": 10, "error": ""}, {"state": "error", "pct": 10, "error": "받는 중에 끊겼어요"}]
	var sh4: AiConnectSheet = AiConnectSheet.open(self)
	var fin4: bool = await _until(func() -> bool: return not sh4.installing and sh4.status_label.text.contains("받는 중에 끊겼어요"))
	ok(fin4, "a failure reported while running shows the reason (%s | %s)" % [sh4.status_label.text, str(_fake.log.map(func(e: Dictionary) -> String: return e["m"] + e["path"]))])
	await _close_sheets()
	_fake.routes.erase("POST /llm/install")
	_set_health("not_connected")


func _auto_open() -> void:
	# C2: the sheet opens by itself once per run after a 503 ai_not_connected; "나중에" ends it for the run
	var link: Callable = AiConnectSheet.auto_open.bind(self)
	Api.ai_not_connected.connect(link)
	AiConnectSheet.auto_done = false
	_fake.reset()
	_fake.routes["POST /lesson"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "AI가 아직 연결되지 않았어요.", "code": "ai_not_connected"}}
	_fake.routes["POST /llm/test"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "AI가 아직 연결되지 않았어요.", "code": "ai_not_connected"}}
	await Api.post_json("/llm/test", {}, 10.0, false).wait()
	await _frames(3)
	ok(not AiConnectSheet.is_open(), "C2: an ai_not_connected answer to /llm/* itself does not open the sheet")
	await Api.post_json("/lesson", {}, 10.0, false).wait()
	await _frames(3)
	ok(AiConnectSheet.is_open() and Sheet.depth() == 1, "C2: the first ai_not_connected answer opens the sheet")
	await Api.post_json("/lesson", {}, 10.0, false).wait()
	await _frames(3)
	ok(Sheet.depth() == 1, "C2: a second answer while it is open opens no second sheet")
	Sheet.close_top("later")
	await _frames(3)
	await Api.post_json("/lesson", {}, 10.0, false).wait()
	await _frames(3)
	ok(not AiConnectSheet.is_open(), "C2: after 나중에 a further answer does not open it again")
	var again: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(2)
	ok(again != null and AiConnectSheet.is_open(), "C2: the banner / settings button can always open it")
	await _close_sheets()
	# ai_not_installed counts the same, and a closed-by-tap ("dismiss") sheet does not use up the run
	AiConnectSheet.auto_done = false
	_fake.routes["POST /lesson"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "AI 구성 요소가 없어요.", "code": "ai_not_installed"}}
	_set_health("not_connected")
	await Api.post_json("/lesson", {}, 10.0, false).wait()
	await _frames(3)
	ok(AiConnectSheet.is_open(), "C2: ai_not_installed opens it as well")
	await _close_sheets()
	Api.ai_not_connected.disconnect(link)
	_fake.routes.erase("POST /lesson")
	_fake.routes.erase("POST /llm/test")
	AiConnectSheet.auto_done = false


func _notice() -> void:
	# C9: the migration notice: one toast, [확인] -> POST /llm/notice/ack
	_fake.reset()
	_snacks.clear()
	_set_health("not_connected")
	AiConnectSheet.notice_checked = false
	AiConnectSheet.notice_pending = false
	_fake.routes["GET /llm"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"provider": "opencode", "state": "not_connected", "notice": "ollama_removed"}}
	await AiConnectSheet.check_notice()
	ok(_snacks.size() == 1 and str(_snacks[0][0]).contains("DeepSeek") and str(_snacks[0][1]) == "확인", "C9: one toast with a [확인] button")
	await AiConnectSheet.check_notice()
	ok(_snacks.size() == 1 and _fake.count("GET", "/llm") == 1, "C9: asked and shown once per run")
	ok(_fake.count("POST", "/llm/notice/ack") == 0, "C9: no ack before the person confirms")
	(_snacks[0][2] as Callable).call()
	await _until(func() -> bool: return _fake.count("POST", "/llm/notice/ack") >= 1)
	ok(_fake.count("POST", "/llm/notice/ack") == 1 and not AiConnectSheet.notice_pending, "C9: [확인] sends POST /llm/notice/ack once")
	# no notice -> nothing
	_fake.reset()
	_snacks.clear()
	AiConnectSheet.notice_checked = false
	_fake.routes["GET /llm"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"provider": "opencode", "notice": ""}}
	await AiConnectSheet.check_notice()
	ok(_snacks.is_empty() and _toasts.filter(func(t: Array) -> bool: return str(t[1]) == "info" and str(t[0]).contains("DeepSeek")).is_empty(), "C9: an empty notice shows nothing")
	# an engine that does not answer: quiet
	AiConnectSheet.notice_checked = false
	_fake.routes["GET /llm"] = func(_b: Dictionary) -> Dictionary: return {"code": 500, "json": {"error": "x"}}
	await AiConnectSheet.check_notice()
	ok(_snacks.is_empty(), "C9: a failing GET /llm shows nothing")
	_fake.routes.erase("GET /llm")
	AiConnectSheet.notice_checked = true


func _card() -> void:
	# C7: the settings card: state line + 3 buttons, no engine drop-down, no ollama text
	UiBoot.apply(get_window(), "light", 1.0)
	var sv := SettingsView.new()
	sv.auto_panels = false
	add_child(sv)
	await _frames(3)
	var cards: Array = sv.find_children("*", "AiConnectCard", true, false)
	ok(cards.size() == 1, "C7: the PC settings screen holds exactly one AiConnectCard")
	var card: AiConnectCard = cards[0] if cards.size() > 0 else null
	var eng_group: Control = sv._secs["engine"]["group"]
	ok(card != null and eng_group.is_ancestor_of(card) and sv.section_of(card) == "engine", "C7: the card sits in the AI engine section")
	ok(eng_group.find_children("*", "OptionButton", true, false).is_empty(), "C7: there is no engine drop-down (OptionButton) in that section")
	var all: String = _all_text(sv).to_lower()
	ok(not all.contains("ollama") and not all.contains("오프라인 로컬"), "C7: the settings screen says nothing about the removed local engine")
	if card == null:
		sv.queue_free()
		return
	var states: Array = [
		["not_connected", "AI 연결하기", false, false, "아직 연결되지 않았어요"],
		["not_installed", "AI 연결하기", false, false, "AI 구성 요소가 없어요"],
		["ready", "다시 연결", true, true, "연결됨"],
		["blocked", "다시 연결", true, true, "연결됨"]]
	for st in states:
		_set_health(str(st[0]), {"llm_fallback": {"active": true, "until": "23:21", "reason": "한도에 도달했어요. 23:21 이후 다시 시도해 주세요."}})
		Backend.status_changed.emit()
		ok(card.connect_btn.text == st[1] and not card.connect_btn.disabled and card.test_btn.disabled != bool(st[2]) and card.disconnect_btn.disabled != bool(st[3]) and card.status_label.text.contains(str(st[4])),
			"C7: card state %s -> %s / test %s / disconnect %s / '%s'" % [st[0], st[1], st[2], st[3], card.status_label.text])
	ok(card.note_label.text.contains("23:21"), "C7: blocked shows the reason and the time on the card")
	Backend.status = Backend.Status.FAILED
	Backend.status_changed.emit()
	ok(card.connect_btn.disabled and card.test_btn.disabled and card.disconnect_btn.disabled, "C7: while the engine is down every button waits")
	# buttons
	_set_health("ready")
	Backend.status_changed.emit()
	_fake.reset()
	_fake.routes["POST /llm/test"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": true, "seconds": 2.4}}
	card.test_btn.pressed.emit()
	await _until(func() -> bool: return card.note_label.text.contains("연결 성공"))
	ok(card.note_label.text.contains("연결 성공") and card.note_label.text.contains("2.4"), "C7: [연결 시험] shows the result (%s)" % card.note_label.text)
	_fake.routes["POST /llm/test"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "x", "code": "ai_auth"}}
	card.test_btn.pressed.emit()
	await _until(func() -> bool: return card.note_label.text.contains("만료"))
	ok(card.note_label.text.contains("연결 실패") and card.note_label.text.contains("다시 연결"), "C7: a refused test says to connect again (%s)" % card.note_label.text)
	_fake.reset()
	_fake.routes["POST /llm/disconnect"] = func(_b: Dictionary) -> Dictionary: return {"code": 200, "json": {"ok": true, "state": "not_connected"}}
	_toasts.clear()
	card.disconnect_btn.pressed.emit()
	await _frames(4)
	ok(Sheet.depth() == 1 and _fake.count("POST", "/llm/disconnect") == 0, "C7: [연결 해제] asks first (nothing sent yet)")
	ok(_all_text(get_tree().root).contains("터미널에서 쓰던 OpenCode도 로그아웃돼요"), "C7: the confirm text warns that the terminal OpenCode is logged out too")
	Sheet.close_top("cancel")
	await _frames(3)
	ok(_fake.count("POST", "/llm/disconnect") == 0, "C7: 취소 sends nothing")
	card.disconnect_btn.pressed.emit()
	await _frames(4)
	Sheet.close_top("ok")
	await _until(func() -> bool: return _fake.count("POST", "/llm/disconnect") >= 1)
	ok(_fake.count("POST", "/llm/disconnect") == 1, "C7: confirming sends POST /llm/disconnect")
	await _frames(3)
	_set_health("not_connected")
	Backend.status_changed.emit()
	card.connect_btn.pressed.emit()
	await _frames(3)
	ok(AiConnectSheet.is_open(), "C7: [AI 연결하기] on the card opens the sheet")
	await _close_sheets()
	sv.queue_free()
	await _frames(2)


func _all_text(n: Node) -> String:
	return "\n".join(PackedStringArray(_screen_texts(n)))


# ================================================================ phone

func _phone_part() -> void:
	# C6: the phone never opens the sheet and never sends anything for it; it only says "PC에서 연결해 주세요"
	_set_health("not_connected")
	_fake.reset()
	_toasts.clear()
	var sent0: int = Api.sent_count
	AiConnectSheet.force_phone = -1
	ok(AiConnectSheet.is_phone(), "C6: Platform.is_phone() is true in this run")
	var r: AiConnectSheet = AiConnectSheet.open(self)
	await _frames(3)
	ok(r == null and not AiConnectSheet.is_open() and Sheet.depth() == 0, "C6: the phone does not open the sheet")
	ok(_toasts.any(func(t: Array) -> bool: return str(t[0]) == AiConnectSheet.PHONE_TEXT), "C6: it shows the sentence '%s'" % AiConnectSheet.PHONE_TEXT)
	AiConnectSheet.auto_done = false
	AiConnectSheet.phone_told = false
	_toasts.clear()
	AiConnectSheet.auto_open("ai_not_connected", self)
	AiConnectSheet.auto_open("ai_not_connected", self)
	await _frames(2)
	ok(not AiConnectSheet.is_open() and _toasts.size() == 1, "C6: an ai_not_connected answer on the phone: no sheet, the sentence once (%d toasts)" % _toasts.size())
	ok(Api.sent_count == sent0 and _fake.log.is_empty(), "C6: no request left the phone (sent_count %d -> %d, fake log %d)" % [sent0, Api.sent_count, _fake.log.size()])
	await AiConnectSheet.check_notice()
	ok(_fake.log.is_empty(), "C6: the phone does not ask for the migration notice")
	ok(Backend.llm_missing_text() == Backend.NOT_CONNECTED_PHONE_TEXT and Backend.llm_missing_text().contains("PC"), "C6/C8: the phone's missing text sends the person to the PC (%s)" % Backend.llm_missing_text())
	var slot: Dictionary = HomeAi.sanitize(AiConnectSheet.home_slot())
	ok(bool(slot["show"]) and slot["action"] == "" and str(slot["body"]).contains("PC"), "C6: the phone's home slot has no button and names the PC (%s)" % str(slot))
	Api.clear_remote()


# ================================================================ main.gd wiring (PC and phone)

func _main_wiring() -> void:
	AiConnectSheet.force_phone = -1
	_fake.reset()
	_toasts.clear()
	AiConnectSheet.auto_done = false
	AiConnectSheet.phone_told = false
	AiConnectSheet.notice_checked = true
	if _phone:
		Api.set_remote(FAKE, "test-token")
	else:
		Api.base_url = FAKE
	Backend._starting = true
	Backend.set_process(false)
	_set_health("not_connected")
	Store.prefs["lang"] = "en"
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	var m: Node = get_tree().current_scene
	ok(m != null and m.get_script() != null and m.has_method("_on_ai_connect"), "main.tscn is the running scene")
	if m == null:
		return
	m.quit_on_exit = false
	Backend.status = Backend.Status.READY
	Backend.status_changed.emit()
	await _frames(6)
	ok(HomeAi.provider.is_valid() and HomeAi.provider.get_method() == &"home_slot", "main sets HomeAi.provider to AiConnectSheet.home_slot")
	var slot: Dictionary = HomeAi.slot()
	if _phone:
		ok(m._banner.visible and m._banner_btn.text == "다시 확인" and not bool(m._banner_ai), "C6: phone banner: the text sends to the PC, the button stays [다시 확인]")
		ok(str(m._banner_label.text).contains("PC"), "C6: phone banner text names the PC (%s)" % m._banner_label.text)
		var sent0: int = Api.sent_count
		_fake.reset()
		Store.request_ai_connect()
		await _frames(4)
		ok(not AiConnectSheet.is_open() and Sheet.depth() == 0, "C6: [AI 연결하기] from the home screen on a paired phone opens no sheet")
		ok(Api.sent_count == sent0 and _fake.count("POST", "/llm/connect") == 0, "C6: ... and sends no request (%d -> %d)" % [sent0, Api.sent_count])
		ok(_toasts.any(func(t: Array) -> bool: return str(t[0]) == AiConnectSheet.PHONE_TEXT), "C6: ... it shows the sentence")
		_toasts.clear()
		_fake.routes["POST /mic/start"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "AI가 아직 연결되지 않았어요.", "code": "ai_not_connected"}}
		Api.post_json("/mic/start", {}, 10.0, false)
		await _until(func() -> bool: return _fake.count("POST", "/mic/start") >= 1)
		await _frames(6)
		ok(not AiConnectSheet.is_open() and Sheet.depth() == 0, "C6: an ai_not_connected answer on the phone opens no sheet")
		ok(_fake.count("POST", "/llm/connect") == 0 and _fake.count("POST", "/llm/install") == 0, "C6: and nothing is sent for the connection")
		Api.clear_remote()
		return
	ok(str(slot["action"]) == "AI 연결하기" and slot["state"] == "llm_off" and bool(slot["show"]), "home slot: not_connected -> [AI 연결하기] (%s)" % str(slot))
	_set_health("not_installed")
	ok(HomeAi.slot()["state"] == "not_installed", "home slot: not_installed has its own state")
	_set_health("not_connected")
	Backend.status_changed.emit()
	await _frames(3)
	ok(m._banner.visible and m._banner_btn.text == "AI 연결하기" and bool(m._banner_ai), "banner: [AI 연결하기] instead of [다시 확인] when the AI is not connected (%s)" % m._banner_btn.text)
	ok(m._banner_label.text == Backend.llm_missing_text(), "banner text is Backend.llm_missing_text()")
	m._banner_btn.pressed.emit()
	await _frames(4)
	ok(AiConnectSheet.is_open(), "banner [AI 연결하기] opens the sheet")
	await _close_sheets()
	Store.request_ai_connect()
	await _frames(4)
	ok(AiConnectSheet.is_open(), "home [AI 연결하기] (Store.ai_connect_requested) opens the sheet")
	await _close_sheets()
	# auto open through the real wiring
	_fake.routes["POST /lesson"] = func(_b: Dictionary) -> Dictionary: return {"code": 503, "json": {"error": "AI가 아직 연결되지 않았어요.", "code": "ai_not_connected"}}
	AiConnectSheet.auto_done = false
	await Api.post_json("/lesson", {}, 10.0, false).wait()
	await _frames(4)
	ok(AiConnectSheet.is_open(), "C2: main.gd's wiring opens the sheet on a 503 ai_not_connected")
	await _close_sheets()
	# healthy again: no banner
	_set_health("ready")
	Backend.status_changed.emit()
	await _frames(3)
	ok(not m._banner.visible and m._banner_btn.text == "다시 확인", "AI ready -> no banner, button back to [다시 확인]")
	# the engine is down: the old way (settings) and [다시 확인]
	Backend.status = Backend.Status.FAILED
	Backend.status_changed.emit()
	await _frames(3)
	Store.request_ai_connect()
	await _frames(3)
	ok(not AiConnectSheet.is_open() and m.current == "settings", "engine down: [AI 연결하기] goes to the settings screen, not the sheet")
	Backend.status = Backend.Status.READY


# ================================================================ helpers: Logger copy and the fake backend

## Copy of everything Godot prints / errors (OS.add_logger). `inject` is for the detector self test.
class LogCap:
	extends Logger
	var lines: Array = []
	var injected: Array = []
	var mu := Mutex.new()

	func _log_message(message: String, _error: bool) -> void:
		mu.lock()
		lines.append(message)
		mu.unlock()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		lines.append("%s %s:%d %s %s" % [function, file, line, code, rationale])
		mu.unlock()

	func snapshot() -> Array:
		mu.lock()
		var c: Array = lines.duplicate()
		mu.unlock()
		c.append_array(injected)
		return c

	func inject(t: String) -> void:
		injected.append(t)

	func clear_injected() -> void:
		injected.clear()


## GDScript HTTP server for the AI endpoints. routes["POST /path"] = func(body: Dictionary) -> {code, json | drop}.
class FakeBackend:
	extends Node
	var srv: TCPServer = null
	var log: Array = [] ## {m, path, body, raw}
	var routes: Dictionary = {}
	var conns: Array = []
	var health_state: String = "not_connected"
	var installs: Array = [] ## answers of GET /llm/install, one per poll (the last one repeats)

	func setup(p: int) -> bool:
		srv = TCPServer.new()
		if srv.listen(p, "127.0.0.1") != OK:
			srv = null
			return false
		return true

	func stop() -> void:
		if srv != null:
			srv.stop()
			srv = null
		for c in conns:
			if c is StreamPeerTCP:
				(c as StreamPeerTCP).disconnect_from_host()
		conns.clear()

	func reset() -> void:
		log.clear()
		installs = []

	func count(m: String, path: String) -> int:
		var n: int = 0
		for e in log:
			if e["m"] == m and e["path"] == path:
				n += 1
		return n

	func _process(_d: float) -> void:
		if srv != null and srv.is_listening():
			while srv.is_connection_available():
				var peer: StreamPeerTCP = srv.take_connection()
				conns.append(peer)
				_serve(peer)

	func _serve(peer: StreamPeerTCP) -> void:
		var buf := PackedByteArray()
		var head_end: int = -1
		var clen: int = 0
		var head: String = ""
		var t0: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 20000:
			peer.poll()
			var st: int = peer.get_status()
			if st != StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() == 0:
				break
			var n: int = peer.get_available_bytes()
			if n > 0:
				var got: Array = peer.get_data(n)
				if int(got[0]) == OK:
					buf.append_array(got[1])
			if head_end < 0:
				var s: String = buf.slice(0, mini(buf.size(), 8192)).get_string_from_ascii()
				var i: int = s.find("\r\n\r\n")
				if i >= 0:
					head_end = i + 4
					head = s.substr(0, i)
					for line in head.split("\r\n"):
						if line.to_lower().begins_with("content-length:"):
							clen = int(line.substr(15).strip_edges())
			if head_end >= 0 and buf.size() >= head_end + clen:
				_handle(peer, head, buf.slice(head_end, head_end + clen))
				return
			await get_tree().process_frame
		peer.disconnect_from_host()

	func _handle(peer: StreamPeerTCP, head: String, body_bytes: PackedByteArray) -> void:
		var first: PackedStringArray = head.split("\r\n")[0].split(" ")
		var m: String = first[0]
		var path: String = first[1].split("?")[0]
		var raw: String = body_bytes.get_string_from_utf8()
		var body: Dictionary = {}
		if raw != "":
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Dictionary:
				body = parsed
		log.append({"m": m, "path": path, "body": body, "raw": raw})
		var code: int = 404
		var payload: Variant = {"error": "not_found"}
		var key: String = "%s %s" % [m, path]
		if routes.has(key):
			var r: Dictionary = (routes[key] as Callable).call(body)
			if bool(r.get("drop", false)):
				peer.disconnect_from_host()
				return
			code = int(r.get("code", 200))
			payload = r.get("json")
		elif key == "GET /health":
			code = 200
			payload = {"ok": true, "llm": health_state == "ready" or health_state == "blocked", "llm_state": health_state, "llm_provider": "opencode",
				"llm_fallback": {"active": false, "until": null, "reason": ""}}
		elif key == "GET /llm/install":
			code = 200
			payload = installs[0] if installs.size() == 1 else (installs.pop_front() if installs.size() > 1 else {"state": "idle", "pct": 0, "error": ""})
		var data: PackedByteArray = JSON.stringify(payload).to_utf8_buffer()
		var hd := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, data.size()]
		peer.put_data(hd.to_utf8_buffer())
		peer.put_data(data)
		peer.disconnect_from_host()
