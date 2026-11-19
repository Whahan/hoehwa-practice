extends Node
## SttModelCard (docs/v201_design.md 2.2, 5.3 PA3-10): the "음성 인식 모델" card, pressed with its real buttons.
##   run_model_tests.ps1 starts the fake server and runs this in 4 modes: pc, phone, phonefont, phonedark.
##   direct: godot --headless --path godot [--resolution 412x915] res://tests/stt_model_card_test.tscn -- --port=N --srv-root=DIR [--phone] [--font-scale=1.5] [--dark]
## Last line: "== stt_model_card_test result: N passed, M failed ==", exit code 1 = failure.
## No network client here: the fake server (127.0.0.1 only) writes requests.jsonl into --srv-root and the test reads it.
## Files go to user://test_models_card/ only. Every step uses the card's real buttons (`press:` lines).

const DIR := "user://test_models_card"
const SIZE := 3000000
const WIFI_FMT := "음성 인식 모델(%s)을 받아요. 와이파이에 연결돼 있나요?"

var passed: int = 0
var failed: int = 0
var presses: int = 0
var _phone: bool = false
var _scheme: String = "light"
var _font_scale: float = 1.0
var _port: int = 0
var _root: String = ""
var _tok: String = ""
var _host: Control = null
var _card: SttModelCard = null
var _old_prefs: String = ""
var _sha: String = ""


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


func _until(cond: Callable, sec: float = 20.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) < sec * 1000.0:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s == "--dark":
			_scheme = "dark"
		elif s.begins_with("--font-scale="):
			_font_scale = s.substr(13).to_float() if s.substr(13).is_valid_float() else 1.0
		elif s.begins_with("--port="):
			_port = int(s.substr(7))
		elif s.begins_with("--srv-root="):
			_root = s.substr(11)
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	print("== stt_model_card_test start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if _phone else "pc", _scheme, Ds.font_scale])
	_old_prefs = Store.prefs_path
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.prefs = {}
	Sheet.animate = false
	ok(Store.test_guard_on, "test guard is on")
	ok(Pal.is_dark() == (_scheme == "dark") and is_equal_approx(Ds.font_scale, Ds.sanitize_scale(_font_scale)), "the run uses the asked colour scheme and text scale")
	if _port <= 0 or _root == "" or not DirAccess.dir_exists_absolute(_root):
		ok(false, "fake server arguments given (--port, --srv-root)")
		_finish()
		return
	ok(true, "fake server arguments given (--port, --srv-root)")
	var ev: Node = ModelStore.events()
	await _frames(2)
	ModelStore.allow_http_loopback = true
	ModelStore.base_dir = DIR + "/store/"
	_make_payloads()
	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	await _frames(2)

	_selfchecks()
	await _real_manifest_wifi_text(ev)
	_write_manifest()
	await _flow_main()
	await _flow_space()
	await _flow_corrupt()
	await _flow_picks_and_ram()
	await _flow_sheet()
	_source_checks()
	ok(presses >= 12, "at least 12 real button presses (%d)" % presses)
	_finish()


func _finish() -> void:
	for id in ["card_base", "card_tiny"]:
		ModelStore.remove(id)
	ModelStore.free_space_hook = Callable()
	ModelStore.allow_http_loopback = false
	ModelStore.manifest_path = "res://data/models.json"
	ModelStore.base_dir = "user://models/"
	SttModelCard.memory_hook = Callable()
	Store.prefs_path = _old_prefs
	_rm_rf(DIR)
	print("== stt_model_card_test result: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
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


# ---------------------------------------------------------------- setup

func _make_payloads() -> void:
	var crypto := Crypto.new()
	var data := PackedByteArray()
	while data.size() < SIZE:
		data.append_array(crypto.generate_random_bytes(65536))
	data.resize(SIZE)
	var p: String = _root.path_join("card3m.bin")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	_sha = FileAccess.get_sha256(p)
	var small := data.slice(0, 1000000)
	var p2: String = _root.path_join("card1m.bin")
	var f2 := FileAccess.open(p2, FileAccess.WRITE)
	f2.store_buffer(small)
	f2.close()


func _url(file: String, q: String) -> String:
	return "http://127.0.0.1:%d/f/%s/%s%s" % [_port, _tok, file, q]


## Two models: the default one (3 MB, slow so that the progress can be seen) and a small one with a WRONG sha256.
func _write_manifest() -> void:
	_tok = "card%d" % int(Time.get_ticks_msec() % 1000000)
	var models: Array = [
		{"id": "card_base", "kind": "stt", "langs": ["en"], "file": "card_base.bin", "bytes": SIZE, "sha256": _sha, "min_free_mb": 0, "default": true,
			"ram_hint_mb": 400, "label_ko": "기본 모델", "urls": [_url("card3m.bin", "?slow=40")], "license": "t"},
		{"id": "card_tiny", "kind": "stt", "langs": ["en"], "file": "card_tiny.bin", "bytes": 1000000, "sha256": "d".repeat(64), "min_free_mb": 0,
			"default": false, "ram_hint_mb": 250, "label_ko": "작은 모델(느린 폰용)", "urls": [_url("card1m.bin", "")], "license": "t"},
	]
	var f := FileAccess.open(_g(DIR + "/manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "hosts": ["github.com"], "models": models}))
	f.close()
	ModelStore.manifest_path = DIR + "/manifest.json"
	Store.prefs = {}


func _new_card() -> void:
	if _card != null and is_instance_valid(_card):
		_card.queue_free()
	_card = SttModelCard.build(_host) as SttModelCard
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_card)
	for ch in _host.get_children():
		ch.queue_free()
	_host.add_child(scroll)


# ---------------------------------------------------------------- helpers

func _press(btn: Button, label: String) -> void:
	ok(btn != null and is_instance_valid(btn) and btn.is_visible_in_tree() and not btn.disabled, "press target '%s' is visible and enabled" % label)
	if btn == null or not is_instance_valid(btn):
		return
	presses += 1
	print("press: ", label)
	btn.pressed.emit()
	await _frames(3)


func _all(n: Node, out: Array) -> void:
	for c in n.get_children():
		out.append(c)
		_all(c, out)


func _sheets() -> Array:
	var all: Array = []
	_all(get_tree().root, all)
	var out: Array = []
	for n in all:
		if n is Sheet and not (n as Sheet).is_closed():
			out.append(n)
	return out


func _top_sheet() -> Sheet:
	var best: Sheet = null
	for s in _sheets():
		if best == null or (s as Sheet).layer_node.layer >= best.layer_node.layer:
			best = s
	return best


func _sheet_text(s: Sheet) -> String:
	if s == null or s.body == null:
		return ""
	return (s.body as Label).text if s.body is Label else ""


func _texts(root: Node) -> Array:
	var all: Array = [root]
	_all(root, all)
	var out: Array = []
	for n in all:
		if n is Label:
			out.append((n as Label).text)
		elif n is Button:
			out.append((n as Button).text)
	return out


func _has5(s: String) -> bool:
	return RegEx.create_from_string("\\d{5,}").search(s) != null


func _no_5digits(root: Node) -> bool:
	for t in _texts(root):
		if _has5(str(t)):
			return false
	return true


func _overflows(root: Control) -> bool:
	return _overflow_name(root) != ""


func _overflow_name(root: Control) -> String:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var all: Array = [root]
	_all(root, all)
	for n in all:
		if n is Control and (n as Control).is_visible_in_tree():
			var r: Rect2 = (n as Control).get_global_rect()
			if r.size.x > 1.0 and (r.end.x > vp.x + 1.0 or r.position.x < -1.0):
				return "%s %s vp=%s" % [n.name, r, vp]
	return ""


func _log_count() -> int:
	var p: String = _root.path_join("requests.jsonl")
	if not FileAccess.file_exists(p):
		return 0
	var n := 0
	var f := FileAccess.open(p, FileAccess.READ)
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.contains("\"token\": \"%s\"" % _tok):
			n += 1
	f.close()
	return n


func _shown(b: Button) -> bool:
	return b != null and b.visible


func _layout_ok(tag: String) -> void:
	await _frames(2)
	ok(not _overflows(_card), "%s: nothing is wider than the window %s" % [tag, _overflow_name(_card)])
	ok(_no_5digits(get_tree().root), "%s: no text shows 5 or more digits in a row" % tag)
	if _phone:
		var tall := true
		for b in [_card.get_btn, _card.resume_btn, _card.cancel_btn, _card.delete_btn]:
			if (b as Button).visible and (b as Button).size.y < 44.0:
				tall = false
		ok(tall, "%s: visible buttons are at least 44 px high on the phone" % tag)


# ---------------------------------------------------------------- self checks

func _selfchecks() -> void:
	var fake := Label.new()
	fake.text = "받는 중 12345 / 60 MB"
	add_child(fake)
	ok(not _no_5digits(fake), "selfcheck: a label with 12345 is flagged")
	print("selfcheck FAIL-as-expected digits (12345 in a label is flagged)")
	fake.queue_free()
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(5000, 20)
	wide.size = Vector2(5000, 20)
	add_child(wide)
	await get_tree().process_frame
	ok(_overflows(wide), "selfcheck: a 5000 px wide control is flagged as overflowing")
	print("selfcheck FAIL-as-expected overflow (5000 px control is flagged)")
	wide.queue_free()


# ---------------------------------------------------------------- flows

func _real_manifest_wifi_text(_ev: Node) -> void:
	ModelStore.manifest_path = "res://data/models.json"
	ModelStore.base_dir = DIR + "/store_real/"
	Store.prefs = {}
	_new_card()
	await _frames(2)
	ok(ModelStore.active_id() == "whisper-base.en-q5_1", "real manifest: the base model is active")
	ok(_shown(_card.get_btn) and not _shown(_card.resume_btn) and not _shown(_card.cancel_btn) and not _shown(_card.delete_btn), "real manifest: only [모델 받기] shows for a missing model")
	ok(_card.status_label.text.contains("약 60 MB"), "real manifest: the status line says about 60 MB")
	await _press(_card.get_btn, "ModelGetBtn")
	var s: Sheet = _top_sheet()
	ok(s != null, "real manifest: the Wi-Fi question sheet opens")
	ok(_sheet_text(s) == "음성 인식 모델(약 60 MB)을 받아요. 와이파이에 연결돼 있나요?", "real manifest: sheet text is the agreed sentence")
	ok(s != null and s.buttons.has("ok") and s.buttons.has("cancel") and (s.buttons["ok"] as Button).text == "받기" and (s.buttons["cancel"] as Button).text == "나중에", "real manifest: sheet buttons are [받기] and [나중에]")
	await _press(s.buttons["cancel"], "나중에")
	ok(ModelStore.state("whisper-base.en-q5_1") == "missing", "real manifest: [나중에] starts nothing")
	ok(_sheets().is_empty(), "real manifest: the sheet is closed")
	ModelStore.base_dir = DIR + "/store/"


func _flow_main() -> void:
	_new_card()
	await _frames(2)
	await _layout_ok("missing")
	ok(_card.name == "SttModelCard", "card node is named SttModelCard")
	ok(_shown(_card.get_btn) and not _shown(_card.resume_btn) and not _shown(_card.cancel_btn) and not _shown(_card.delete_btn), "missing: only [모델 받기] shows")
	ok(_card.get_btn.text == "모델 받기", "missing: the button says 모델 받기")
	ok(not _card.bar.visible, "missing: no progress bar")
	ok(_card.status_label.text.contains("약 3 MB"), "missing: the status line says the size in MB")
	ok(_card.pick_box.visible and _card.get_node("ModelPicks").get_child_count() == 2, "missing: two model rows")
	# [나중에] starts nothing
	await _press(_card.get_btn, "ModelGetBtn")
	var s: Sheet = _top_sheet()
	ok(_sheet_text(s) == WIFI_FMT % "약 3 MB", "wifi sheet text carries the model size")
	await _press(s.buttons["cancel"], "나중에")
	await _frames(15)
	ok(ModelStore.state("card_base") == "missing" and _log_count() == 0, "[나중에]: nothing started, 0 requests")
	# [받기] -> progress
	await _press(_card.get_btn, "ModelGetBtn")
	s = _top_sheet()
	await _press(s.buttons["ok"], "받기")
	ok(ModelStore.state("card_base") == "downloading", "[받기]: the download started")
	var seen: bool = await _until(func() -> bool: return _card.status_label.text.begins_with("받는 중 ") and int(ModelStore.info("card_base")["part_bytes"]) >= 300000)
	ok(seen, "progress: the status line shows 받는 중 with a progress text")
	var inf: Dictionary = ModelStore.info("card_base")
	ok(_card.status_label.text.begins_with("받는 중 ") and _card.status_label.text.ends_with(" / 3 MB"), "progress: the text ends with ' / 3 MB' (%s)" % _card.status_label.text)
	ok(_card.bar.visible and _card.bar.value > 0.0 and _card.bar.value < 1.0, "progress: the bar is visible and between 0 and 1")
	ok(_shown(_card.cancel_btn) and not _shown(_card.get_btn) and not _shown(_card.delete_btn) and not _shown(_card.resume_btn), "progress: only [취소] shows")
	ok(int(inf["part_bytes"]) > 0, "progress: info() reports the bytes so far")
	await _layout_ok("downloading")
	# [취소] keeps the part
	await _press(_card.cancel_btn, "ModelCancelBtn")
	var stopped: bool = await _until(func() -> bool: return ModelStore.state("card_base") == "partial")
	ok(stopped, "[취소]: state partial")
	await _frames(3)
	ok(_card.status_label.text.begins_with("받다가 멈췄어요."), "[취소]: the status line says it stopped")
	ok(_shown(_card.resume_btn) and _shown(_card.delete_btn) and not _shown(_card.get_btn) and not _shown(_card.cancel_btn), "[취소]: [이어받기] and [모델 지우기] show")
	ok(_card.note_label.text == "", "[취소]: no error note for a cancel")
	await _layout_ok("partial")
	# [이어받기] -> ready
	var before: int = _log_count()
	await _press(_card.resume_btn, "ModelResumeBtn")
	s = _top_sheet()
	ok(_sheet_text(s) == WIFI_FMT % "약 3 MB", "resume: the same Wi-Fi question")
	await _press(s.buttons["ok"], "받기")
	var done: bool = await _until(func() -> bool: return ModelStore.state("card_base") == "ready", 30.0)
	ok(done, "resume: state ready")
	await _frames(3)
	ok(_log_count() > before, "resume: a second request was made")
	ok(FileAccess.get_sha256(_g(ModelStore.base_dir).path_join("card_base.bin")) == _sha, "resume: the file matches the sha256")
	ok(_card.status_label.text.begins_with("준비됐어요") and _card.status_label.text.contains("약 3 MB"), "ready: the status line says 준비됐어요")
	ok(_shown(_card.delete_btn) and not _shown(_card.get_btn) and not _shown(_card.resume_btn) and not _shown(_card.cancel_btn) and not _card.bar.visible, "ready: only [모델 지우기] shows, no bar")
	await _layout_ok("ready")
	# [모델 지우기] -> confirm -> missing
	await _press(_card.delete_btn, "ModelDeleteBtn")
	s = _top_sheet()
	ok(_sheet_text(s) == SttModelCard.DELETE_TEXT, "delete: the confirm sheet explains it")
	await _press(s.buttons["cancel"], "취소(지우기)")
	ok(ModelStore.state("card_base") == "ready", "delete: [취소] keeps the model")
	await _press(_card.delete_btn, "ModelDeleteBtn")
	s = _top_sheet()
	await _press(s.buttons["ok"], "지우기")
	ok(ModelStore.state("card_base") == "missing", "delete: [지우기] -> missing")
	ok(not FileAccess.file_exists(_g(ModelStore.base_dir).path_join("card_base.bin")) and not FileAccess.file_exists(_g(ModelStore.base_dir).path_join("card_base.bin.ok")), "delete: files are gone")
	ok(_shown(_card.get_btn) and not _shown(_card.delete_btn), "delete: [모델 받기] is back")


func _flow_space() -> void:
	# unknown free space asks first
	ModelStore.free_space_hook = func() -> int: return -1
	await _press(_card.get_btn, "ModelGetBtn")
	var s: Sheet = _top_sheet()
	await _press(s.buttons["ok"], "받기")
	s = _top_sheet()
	ok(s != null and _sheet_text(s) == ModelStore.SPACE_UNKNOWN_TEXT, "space unknown: the card asks before it goes on")
	await _press(s.buttons["cancel"], "취소(공간)")
	ok(ModelStore.state("card_base") == "missing", "space unknown: [취소] starts nothing")
	await _press(_card.get_btn, "ModelGetBtn")
	s = _top_sheet()
	await _press(s.buttons["ok"], "받기")
	s = _top_sheet()
	await _press(s.buttons["ok"], "계속")
	ok(ModelStore.state("card_base") == "downloading", "space unknown: [계속] starts the download")
	await _press(_card.cancel_btn, "ModelCancelBtn")
	await _until(func() -> bool: return ModelStore.state("card_base") == "partial")
	ModelStore.remove("card_base")
	await _frames(3)
	# not enough space
	ModelStore.free_space_hook = func() -> int: return 10 * 1000000
	await _frames(30) # the server writes its log line when a connection ends
	var n0: int = _log_count()
	await _press(_card.get_btn, "ModelGetBtn")
	s = _top_sheet()
	await _press(s.buttons["ok"], "받기")
	ok(ModelStore.state("card_base") == "missing", "no space: nothing started")
	ok(_card.note_label.visible and _card.note_label.text.begins_with("저장 공간이 모자라요."), "no space: the note says so in Korean (%s)" % _card.note_label.text)
	ok(_log_count() == n0, "no space: 0 new requests")
	await _layout_ok("no_space")
	ModelStore.free_space_hook = Callable()


func _flow_corrupt() -> void:
	# the small model has a wrong sha256: the card shows the failure and offers a new download
	var pick: Button = _card.get_node("ModelPicks/ModelPick_card_tiny")
	await _press(pick, "ModelPick_card_tiny")
	ok(ModelStore.active_id() == "card_tiny" and str(Store.prefs.get("stt_model", "")) == "card_tiny", "pick: the small model is active, pref stt_model saved")
	ok(_card.status_label.text.contains("약 1 MB"), "pick: the status line follows the picked model")
	await _press(_card.get_btn, "ModelGetBtn")
	var s: Sheet = _top_sheet()
	ok(_sheet_text(s) == WIFI_FMT % "약 1 MB", "pick: the sheet names the picked model's size")
	await _press(s.buttons["ok"], "받기")
	var bad: bool = await _until(func() -> bool: return ModelStore.state("card_tiny") == "corrupt", 20.0)
	ok(bad, "corrupt: a wrong sha256 ends as corrupt")
	await _frames(4)
	ok(_card.note_label.visible and _card.note_label.text == str(ModelStore.ERR_TEXT["model_corrupt"]), "corrupt: the note is the Korean model_corrupt sentence")
	ok(_shown(_card.get_btn) and _card.get_btn.text == "다시 받기" and _shown(_card.delete_btn), "corrupt: [다시 받기] and [모델 지우기] show")
	await _layout_ok("corrupt")
	await _press(_card.delete_btn, "ModelDeleteBtn")
	s = _top_sheet()
	await _press(s.buttons["ok"], "지우기")
	ok(ModelStore.state("card_tiny") == "missing" and _card.get_btn.text == "모델 받기", "corrupt: after [지우기] it is missing and the label is back")


func _flow_picks_and_ram() -> void:
	var pick: Button = _card.get_node("ModelPicks/ModelPick_card_base")
	await _press(pick, "ModelPick_card_base")
	ok(ModelStore.active_id() == "card_base", "pick: the base model is active again")
	SttModelCard.memory_hook = func() -> int: return 2 * 1024 * 1024 * 1024
	_card.refresh()
	ok(_card.ram_label.visible and _card.ram_label.text == "이 폰은 메모리가 적어서 작은 모델을 추천해요.", "ram: under 3 GB shows the small-model hint")
	SttModelCard.memory_hook = func() -> int: return 8 * 1024 * 1024 * 1024
	_card.refresh()
	ok(not _card.ram_label.visible, "ram: 8 GB shows no hint")
	SttModelCard.memory_hook = func() -> int: return 0
	_card.refresh()
	ok(not _card.ram_label.visible, "ram: unknown (0) shows no hint")
	SttModelCard.memory_hook = Callable()
	# a broken manifest: the card says so and shows no buttons
	var saved: String = ModelStore.manifest_path
	ModelStore.manifest_path = DIR + "/nothing_here.json"
	_card.refresh()
	ok(_card.status_label.text == str(ModelStore.ERR_TEXT["bad_manifest"]) and not _shown(_card.get_btn) and not _shown(_card.delete_btn), "bad manifest: Korean sentence, no buttons")
	print("selfcheck FAIL-as-expected card_manifest (a missing models.json is shown as an error)")
	ModelStore.manifest_path = saved
	_card.refresh()
	ok(_shown(_card.get_btn), "bad manifest: the card recovers when the file is back")


func _flow_sheet() -> void:
	var sh: Variant = SttModelCard.open_sheet(_host)
	await _frames(4)
	ok(sh is Sheet and not (sh as Sheet).is_closed(), "open_sheet: a sheet opens")
	var found: Array = []
	_all((sh as Sheet), found)
	var cards: Array = found.filter(func(n: Node) -> bool: return n is SttModelCard)
	ok(cards.size() == 1, "open_sheet: the sheet holds one SttModelCard")
	if cards.size() == 1:
		var c: SttModelCard = cards[0]
		ok(c.get_btn != null and c.get_btn.name == "ModelGetBtn" and c.delete_btn.name == "ModelDeleteBtn" and c.resume_btn.name == "ModelResumeBtn" and c.cancel_btn.name == "ModelCancelBtn", "open_sheet: button node names")
		ok(c.get_btn.visible, "open_sheet: [모델 받기] shows in the sheet")
		await _press(c.get_btn, "ModelGetBtn(sheet)")
		var top: Sheet = _top_sheet()
		ok(top != sh and _sheet_text(top) == WIFI_FMT % "약 3 MB", "open_sheet: the Wi-Fi question opens above the sheet")
		await _press(top.buttons["cancel"], "나중에(sheet)")
	ok(_no_5digits(get_tree().root), "open_sheet: no text shows 5 or more digits in a row")
	await _press((sh as Sheet).buttons["close"], "닫기")
	await _frames(3)
	ok(_sheets().is_empty(), "open_sheet: [닫기] closes the sheet")


func _source_checks() -> void:
	var f := FileAccess.open("res://scripts/ui/stt_model_card.gd", FileAccess.READ)
	var src: String = f.get_as_text() if f != null else ""
	ok(src != "" and not src.contains("%d/%d") and not src.contains("%d / %d"), "card source has no progress text of its own")
	ok(src.contains("ModelStore.progress_label"), "card source builds progress texts with ModelStore.progress_label")
	ok(not src.contains("Color(\"#"), "card source has no hard-coded colour")
