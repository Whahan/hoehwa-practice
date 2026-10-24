extends Node
## A6 (docs/phone_standalone_design.md §4.6, §5.3, §5.4, §8 A6): the phone-only screens of the standalone mode.
##   phone: godot --headless --path <project> res://tests/standalone_ui_test.tscn -- --phone
##   PC:    godot --headless --path <project> res://tests/standalone_ui_test.tscn      (only checks that the PC shows none of it)
## Covers: [PC 없이 시작] on the connect screen (prefs, home, no request), the "폰 단독 모드" badge, the capability table
## (16 keys), the 처리 위치 card (Route.mode + prefs), the voice engine choice and the per-language system voices
## (tts_sys_voice_<lang>, fake SystemTts adapter), the data credits, and that the PC app has none of these.
## Files: only user://test_a6/ (prefs, progress, study log) and the test guard's folder; the real files are never opened.
## Last line: "== standalone_ui_test: N passed, M failed ==", exit code 1 on any failure. Every part ends with a flag
## that is checked with ok(): a script error that stops a part early cannot end as "0 failed".

const DIR := "user://test_a6"
const SCREEN := Vector2i(412, 915)

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _main: Control = null
var _flags: Dictionary = {}
var _old_prefs: String
var _old_progress: String
var _old_log: String
var _old_adapter: SystemTts.Adapter
var _old_base_url: String


## System voices with fixed ids (the test machine's voices must not matter). One French voice must never be listed.
class VoiceFake:
	extends SystemTts.Adapter
	var voices: Array = []
	func available() -> bool:
		return true
	func get_voices() -> Array:
		return voices
	func speak(_t: String, _v: String, _vol: int, _p: float, _r: float, _id: int, _i: bool) -> void:
		pass
	func stop() -> void:
		pass


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
	_phone = Platform.is_phone()
	print("== standalone_ui_test start (%s) ==" % ("phone" if _phone else "pc"))
	_old_prefs = Store.prefs_path
	_old_progress = Store.progress_path
	_old_log = StudyLog.path
	_old_adapter = SystemTts.adapter
	_old_base_url = Api.base_url
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	_cleanup_files()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	Store.load_prefs()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	Backend._starting = true # nothing may start an engine or look for a PC
	Backend.set_process(false)
	Sheet.animate = false
	get_window().min_size = Vector2i.ZERO
	get_window().size = SCREEN if _phone else Vector2i(1280, 800)
	await _frames(2)
	UiBoot.apply(get_window(), "light", 1.0)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	var fake := VoiceFake.new()
	fake.voices = [
		{"name": "English US", "id": "en-us-x-a", "language": "en-US"},
		{"name": "English UK", "id": "en-gb-x-b", "language": "en_GB"},
		{"name": "Francais", "id": "fr-fr-x-f", "language": "fr-FR"},
		{"name": "Nihongo 1", "id": "ja-jp-x-c", "language": "ja-JP"},
		{"name": "Nihongo 2", "id": "ja-jp-x-d", "language": "jpn"},
	]
	SystemTts.adapter = fake
	await _frames(2)

	if _phone:
		await _test_start_flow()
		await _test_badge()
		await _test_capability_panel()
		await _test_settings_cards(fake)
	await _test_pc_hidden()
	for k in ["start", "badge", "caps", "cards", "pc_hidden"]:
		if (k == "pc_hidden") or _phone:
			ok(bool(_flags.get(k, false)), "part '%s' ran to its end" % k)

	Tts.stop()
	SystemTts.adapter = _old_adapter
	Api.base_url = _old_base_url
	Route.pc_ready_hook = Callable()
	Store.prefs_path = _old_prefs
	Store.progress_path = _old_progress
	StudyLog.path = _old_log
	_cleanup_files()
	print("== standalone_ui_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _cleanup_files() -> void:
	var g: String = ProjectSettings.globalize_path(DIR)
	if DirAccess.dir_exists_absolute(g):
		for f in DirAccess.get_files_at(g):
			DirAccess.remove_absolute(g.path_join(f))
		DirAccess.remove_absolute(g)


func _saved_prefs() -> Dictionary:
	var p: Variant = JSON.parse_string(FileAccess.get_file_as_string(Store.prefs_path))
	return p if p is Dictionary else {}


func _find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func _all_text(root: Node) -> String:
	var parts: Array = []
	for n in root.find_children("*", "Label", true, false):
		parts.append((n as Label).text)
	for n in root.find_children("*", "Button", true, false):
		parts.append((n as Button).text)
	return "\n".join(parts)


static func _has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


## A fresh main.tscn (the app as the phone runs it). The old one is freed first.
func _new_main() -> Control:
	if _main != null and is_instance_valid(_main):
		remove_child(_main)
		_main.queue_free()
		await _frames(2)
	var scene: PackedScene = load("res://scenes/main.tscn")
	_main = scene.instantiate()
	add_child(_main)
	_main.quit_on_exit = false
	await _frames(12)
	return _main


func _chip_text() -> String:
	return str(_main._conn_chip.text)


func _overflow_and_small(root: Node, vp: Vector2) -> Dictionary:
	var over: Array = []
	var small: Array = []
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree():
			continue
		var r := c.get_global_rect()
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		if r.end.x > vp.x + 0.5 or r.position.x < -0.5:
			over.append("%s %s %s" % [c.get_class(), c.name, str(r)])
		if c is BaseButton and (r.size.y < 47.5 or r.size.x < 47.5):
			small.append("%s '%s' %s" % [c.get_class(), (c as BaseButton).text if c is Button else "", str(r.size)])
	return {"over": over, "small": small}


# ---------------------------------------------------------------- [PC 없이 시작]

func _test_start_flow() -> void:
	print("[PC 없이 시작]")
	Route.mode = "pc"
	Store.set_pref("route_mode", "pc")
	Store.prefs.erase("standalone_ok")
	Backend.status = Backend.Status.NEEDS_PAIRING
	Backend.message = ""
	var sent0: int = Api.sent_count

	# control: without the choice the unpaired start asks for a PC (connect screen) and the home screen is covered
	await _new_main()
	Backend._set_status(Backend.Status.NEEDS_PAIRING, "")
	await _frames(4)
	ok(_main.is_connect_open(), "unpaired start without the choice: the connect screen opens (control)")
	ok(_main._splash_layer.visible, "...and the PC splash covers the home screen (control)")
	var cv: ConnectView = _main._connect_view
	ok(cv != null and cv.standalone_button != null and cv.standalone_button.is_visible_in_tree(), "the connect screen has the [PC 없이 시작] button")
	ok(cv.standalone_button.text == "PC 없이 시작", "its text is 'PC 없이 시작'")
	ok(cv.standalone_button.size.y >= 47.5, "it is a touch target (%.0f px high)" % cv.standalone_button.size.y)
	ok(_chip_text() == "연결 필요", "badge before the choice: '연결 필요' (%s)" % _chip_text())
	var r0 := _overflow_and_small(cv, Vector2(SCREEN))
	ok((r0["over"] as Array).is_empty() and (r0["small"] as Array).is_empty(), "connect screen: nothing out of the screen, no small touch target (%s %s)" % [str(r0["over"]), str(r0["small"])])

	cv.standalone_button.pressed.emit()
	await _frames(6)
	ok(bool(Store.prefs.get("standalone_ok", false)), "prefs.standalone_ok == true")
	ok(str(Store.prefs.get("route_mode", "")) == "auto" and Route.mode == "auto", "prefs.route_mode == 'auto' and Route.mode 'auto' (was 'pc')")
	var saved: Dictionary = _saved_prefs()
	ok(bool(saved.get("standalone_ok", false)) and str(saved.get("route_mode", "")) == "auto", "both are written to the prefs file")
	ok(not _main.is_connect_open(), "the connect screen is closed")
	ok(_main.current == "today" and (_main.views["today"] as Control).visible, "the home screen (오늘) is shown")
	ok(not _main._splash_layer.visible, "no splash covers it")
	ok(_chip_text() == "폰 단독 모드", "badge: '폰 단독 모드' (%s)" % _chip_text())
	ok(Api.sent_count == sent0, "no request was sent (Api.sent_count %d -> %d)" % [sent0, Api.sent_count])

	# a later NEEDS_PAIRING (token revoked, ...) does not bring the connect screen back
	Backend._set_status(Backend.Status.CHECKING, "PC에 연결 중…")
	Backend._set_status(Backend.Status.NEEDS_PAIRING, Backend.REVOKED_TEXT)
	await _frames(4)
	ok(not _main.is_connect_open() and not _main._splash_layer.visible, "standalone_ok: NEEDS_PAIRING again does not open the connect screen or the splash")

	# the next start of the app (a fresh main, still unpaired)
	await _new_main()
	ok(Backend.status == Backend.Status.NEEDS_PAIRING and not _main.is_connect_open() and not _main._splash_layer.visible, "next app start, still NEEDS_PAIRING: no connect screen, no splash")
	ok(_main.current == "today" and (_main.views["today"] as Control).visible, "next app start: the home screen is shown")
	ok(_chip_text() == "폰 단독 모드", "next app start: badge '폰 단독 모드'")
	ok(Api.sent_count == sent0, "next app start: still no request (%d)" % Api.sent_count)

	# a PC that connects: the usual badge
	Backend.health = {"ok": true, "stt": true, "tts": {"en": true, "ja": true}, "llm": true, "score": true}
	Backend._set_status(Backend.Status.READY)
	await _frames(3)
	ok(_chip_text() == "PC 연결됨", "PC connected: the usual badge 'PC 연결됨' (%s)" % _chip_text())

	# opened from "연결 변경" while connected (cancel button): no [PC 없이 시작]
	var cv2 := ConnectView.new()
	cv2.allow_cancel = true
	add_child(cv2)
	await _frames(2)
	ok(cv2.standalone_button == null and cv2.cancel_button != null, "opened with allow_cancel: no [PC 없이 시작], the cancel button instead")
	cv2.queue_free()

	# the screen on its own (no main): the button saves and closes the screen, and says so
	Store.prefs.erase("standalone_ok")
	var cv3 := ConnectView.new()
	add_child(cv3)
	await _frames(2)
	var got: Array = []
	cv3.standalone_chosen.connect(func() -> void: got.append(1))
	cv3.standalone_button.pressed.emit()
	await _frames(2)
	ok(got.size() == 1 and bool(Store.prefs.get("standalone_ok", false)) and not is_instance_valid(cv3), "ConnectView alone: standalone_chosen once, prefs saved, screen freed")
	Backend.health = {}
	Backend.status = Backend.Status.IDLE
	_flags["start"] = true


# ---------------------------------------------------------------- badge

func _test_badge() -> void:
	print("[badge]")
	await _new_main()
	Store.prefs.erase("standalone_ok")
	Route.set_mode("auto")
	Backend._set_status(Backend.Status.FAILED, Backend.UNREACHABLE_TEXT)
	await _frames(3)
	ok(_chip_text() == "PC 연결 안 됨", "paired PC unreachable, no standalone choice: 'PC 연결 안 됨' (%s)" % _chip_text())
	Route.set_mode("phone")
	await _frames(3)
	ok(_chip_text() == "폰 단독 모드", "mode '이 폰에서만' and no PC: '폰 단독 모드' (%s)" % _chip_text())
	Route.set_mode("auto")
	await _frames(3)
	ok(_chip_text() == "PC 연결 안 됨", "back to auto: 'PC 연결 안 됨' again (%s)" % _chip_text())
	Store.set_pref("standalone_ok", true)
	Backend._set_status(Backend.Status.FAILED, Backend.UNREACHABLE_TEXT)
	await _frames(3)
	ok(_chip_text() == "폰 단독 모드", "standalone_ok and the PC is unreachable: '폰 단독 모드' (%s)" % _chip_text())
	Backend.health = {"ok": true, "llm": true}
	Backend._set_status(Backend.Status.READY)
	await _frames(3)
	ok(_chip_text() == "PC 연결됨", "connected: 'PC 연결됨' (%s)" % _chip_text())
	Route.set_mode("phone")
	await _frames(3)
	ok(_chip_text() == "PC 연결됨", "connected with mode '이 폰에서만': the connection badge is unchanged (%s)" % _chip_text())
	Route.set_mode("auto")
	Backend.health = {}
	Backend.status = Backend.Status.IDLE
	_flags["badge"] = true


# ---------------------------------------------------------------- capability table

## true when the panel shows every key of Route.caps() with its name, place and (for "none") a Korean reason.
func _panel_complete(panel: CapabilityPanel) -> bool:
	var caps: Dictionary = Route.caps()
	var items: Dictionary = caps["items"]
	var text: String = _all_text(panel)
	for k in Route.CAP_KEYS:
		if not panel.rows.has(k) or not items.has(k):
			return false
		var row: Dictionary = panel.rows[k]
		var nm: String = CapabilityPanel.NAMES.get(k, "")
		if nm == "" or not text.contains(nm) or (row["name_label"] as Label).text != nm:
			return false
		var use: String = str(items[k]["use"])
		if (row["use_label"] as Label).text != str(CapabilityPanel.USE_TEXT[use]):
			return false
		if use == "none":
			var rl: Label = row["reason_label"]
			if rl == null or not rl.visible or rl.text.strip_edges() == "" or not _has_hangul(rl.text):
				return false
	return true


func _test_capability_panel() -> void:
	print("[capability panel]")
	Store.set_pref("standalone_ok", true)
	Route.set_mode("auto")
	Api.base_url = ""
	Backend.status = Backend.Status.IDLE
	var caps: Dictionary = Route.caps()
	var keys: Array = (caps["items"] as Dictionary).keys()
	ok(keys.size() == 16 and Route.CAP_KEYS.size() == 16, "Route.caps() has 16 keys (%d)" % keys.size())
	var panel := CapabilityPanel.new()
	var host := VBoxContainer.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	host.add_child(panel)
	await _frames(3)
	ok(panel.rows.size() == 16, "the panel shows 16 rows (%d)" % panel.rows.size())
	var order_ok := true
	for i in 16:
		if str(panel.rows.keys()[i]) != str(Route.CAP_KEYS[i]):
			order_ok = false
	ok(order_ok and panel.rows.keys().size() == 16, "rows are in the order of Route.CAP_KEYS")
	ok(_panel_complete(panel), "every key: Korean name, place (폰/PC/없음) as Route says, a Korean reason line for 'none'")
	var none_n := 0
	var phone_n := 0
	for k in Route.CAP_KEYS:
		var u: String = str((caps["items"] as Dictionary)[k]["use"])
		if u == "none":
			none_n += 1
		elif u == "phone":
			phone_n += 1
	ok(none_n >= 3 and phone_n >= 1, "the check is exercised: %d rows 'none', %d rows 'phone' with no PC" % [none_n, phone_n])
	ok(panel.summary_label.text.contains("자동") and panel.summary_label.text.contains("연결 안 됨"), "summary line: mode and PC state (%s)" % panel.summary_label.text)

	# the detector can fail: a table that lost a row, one with a blank reason, one with a wrong place
	var broken := panel.rows.duplicate()
	panel.rows.erase("chat")
	ok(not _panel_complete(panel), "self-check: a table without the 'chat' row is reported incomplete")
	panel.rows = broken
	var victim := ""
	for k in Route.CAP_KEYS:
		if str(panel.rows[k]["use"]) == "none":
			victim = str(k)
			break
	var rl: Label = panel.rows[victim]["reason_label"]
	var saved_reason: String = rl.text
	rl.text = "  "
	ok(not _panel_complete(panel), "self-check: a 'none' row with an empty reason is reported")
	rl.text = saved_reason
	var ul: Label = panel.rows[victim]["use_label"]
	ul.text = "폰"
	ok(not _panel_complete(panel), "self-check: a row that names the wrong place is reported")
	ul.text = "없음"
	ok(_panel_complete(panel), "self-check: restored table is complete again")

	# PC connected and allowed, but "이 폰에서만": the PC-only rows say why
	Api.base_url = "http://127.0.0.1:9" # never contacted: caps() does not send anything
	Route.pc_ready_hook = func() -> bool: return true
	Route.set_mode("phone")
	await _frames(2)
	ok(str(panel.rows["chat"]["use"]) == "none" and str(panel.rows["chat"]["reason"]) == CapabilityPanel.PHONE_ONLY_TEXT, "mode 이 폰에서만 + PC reachable: 'chat' is none with the mode's reason (%s)" % str(panel.rows["chat"]["reason"]))
	ok(_panel_complete(panel), "...and the table still matches Route.caps()")
	Route.set_mode("pc")
	await _frames(2)
	ok(str(panel.rows["chat"]["use"]) == "pc" and str(panel.rows["lesson"]["use"]) == "pc", "mode PC에서만: PC rows say PC (%s / %s)" % [str(panel.rows["chat"]["use"]), str(panel.rows["lesson"]["use"])])
	ok(_panel_complete(panel), "...matches Route.caps()")
	Route.set_mode("auto")
	await _frames(2)
	ok(panel.summary_label.text.contains("연결됨") and _panel_complete(panel), "auto with a ready PC: summary says 연결됨 (%s)" % panel.summary_label.text)
	Route.pc_ready_hook = Callable()
	Api.base_url = ""
	host.queue_free()
	await _frames(2)
	_flags["caps"] = true


# ---------------------------------------------------------------- settings cards

func _test_settings_cards(fake: VoiceFake) -> void:
	print("[settings: 처리 위치, 읽어 주는 목소리, 기능 현황, 출처]")
	Store.prefs.erase("tts_engine")
	Store.prefs.erase("tts_sys_voice_en")
	Store.prefs.erase("tts_sys_voice_ja")
	Store.prefs.erase("tts_voice_en")
	Store.prefs.erase("tts_voice_ja")
	Route.set_mode("auto")
	await _new_main()
	var main_sv: SettingsView = _main.views["settings"]
	ok(main_sv.find_children("*", "CapabilityPanel", true, false).size() == 1 and main_sv.section_visible("engine"), "main.tscn on the phone: the settings screen has one CapabilityPanel in a visible section")
	var sv := SettingsView.new()
	sv.standalone_panels = true
	sv.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(sv)
	await _frames(4)
	ok(sv.section_visible("engine") and sv.mode_box != null and sv.cap_panel != null, "the engine section shows the 처리 위치 card and the table")
	ok(sv.section_visible("voice") and sv.tts_engine_box != null and sv.voice_box != null, "the voice section has the engine choice and the voice lists")

	# ---- 처리 위치
	var mode_texts := {"phone": "이 폰에서만", "pc": "PC에서만", "auto": "자동"}
	for m in ["phone", "pc", "auto"]:
		var b: Button = _find_button(sv.mode_box, str(mode_texts[m]))
		ok(b != null, "처리 위치: a button '%s'" % str(mode_texts[m]))
		if b == null:
			continue
		b.pressed.emit()
		await _frames(3)
		ok(Route.mode == m and str(Store.prefs.get("route_mode", "")) == m, "처리 위치 '%s': Route.mode and prefs.route_mode are '%s'" % [str(mode_texts[m]), m])
		ok(str(_saved_prefs().get("route_mode", "")) == m, "...saved in the prefs file")
		ok(sv.cap_panel.summary_label.text.contains(str(mode_texts[m])), "...the table's summary names it (%s)" % sv.cap_panel.summary_label.text)
		ok(_find_button(sv.mode_box, str(mode_texts[m])) != null, "...the card was redrawn")
	var seen_note: String = _all_text(sv.mode_box)
	ok(seen_note.contains(SettingsView.MODE_NOTES["auto"]), "the card explains the chosen mode")

	# ---- 읽어 주는 목소리: this phone
	var eng_buttons := {"system": "이 폰 음성", "pc": "PC 음성", "auto": "자동"}
	var bs: Button = _find_button(sv.tts_engine_box, "이 폰 음성")
	ok(bs != null, "voice engine: a button '이 폰 음성'")
	bs.pressed.emit()
	await _frames(4)
	ok(str(Store.prefs.get("tts_engine", "")) == "system" and Tts.engine_now() == "system", "pick '이 폰 음성': prefs.tts_engine 'system', Tts.engine_now() 'system'")
	ok(str(_saved_prefs().get("tts_engine", "")) == "system", "...saved in the prefs file")
	var obs: Array = sv.voice_box.find_children("*", "OptionButton", true, false)
	ok(obs.size() == 2, "system engine: one voice list per language (%d)" % obs.size())
	var en_ob: OptionButton = obs[0]
	var ja_ob: OptionButton = obs[1]
	ok(en_ob.item_count == 2 and ja_ob.item_count == 2, "the lists hold the phone's voices of that language only (en %d, ja %d; the French voice is not listed)" % [en_ob.item_count, ja_ob.item_count])
	ok(str(en_ob.get_item_metadata(0)) == "en-us-x-a" and str(en_ob.get_item_metadata(1)) == "en-gb-x-b" and str(ja_ob.get_item_metadata(1)) == "ja-jp-x-d", "the list items carry the system voice ids")
	ok(not Store.prefs.has("tts_sys_voice_en"), "nothing is saved before a pick")
	en_ob.select(1)
	en_ob.item_selected.emit(1)
	ja_ob.select(1)
	ja_ob.item_selected.emit(1)
	await _frames(2)
	ok(str(Store.prefs.get("tts_sys_voice_en", "")) == "en-gb-x-b" and str(Store.prefs.get("tts_sys_voice_ja", "")) == "ja-jp-x-d", "picks saved as tts_sys_voice_en / tts_sys_voice_ja (%s / %s)" % [str(Store.prefs.get("tts_sys_voice_en", "")), str(Store.prefs.get("tts_sys_voice_ja", ""))])
	ok(not Store.prefs.has("tts_voice_en") and not Store.prefs.has("tts_voice_ja"), "...and the PC voice prefs (tts_voice_*) stay untouched")
	var sp: Dictionary = _saved_prefs()
	ok(str(sp.get("tts_sys_voice_en", "")) == "en-gb-x-b" and str(sp.get("tts_sys_voice_ja", "")) == "ja-jp-x-d", "...in the prefs file too")
	ok(Tts.voice_for("en") == "en-gb-x-b" and Tts.voice_for("ja") == "ja-jp-x-d", "Tts.voice_for follows the picks")
	ok(str(sv.cap_panel.rows["tts"]["use"]) == "phone", "the table: reading aloud runs on the phone")
	# the lists come back with the saved picks selected after a redraw
	sv._fill_voice_box()
	await _frames(2)
	obs = sv.voice_box.find_children("*", "OptionButton", true, false)
	ok(obs.size() == 2 and (obs[0] as OptionButton).selected == 1 and (obs[1] as OptionButton).selected == 1, "after a redraw the saved voices are selected")
	ok(_all_text(sv.voice_box).contains("이 폰에 설치된 음성만"), "the note says these are the phone's voices")

	# ---- no system voice at all
	var voices_backup: Array = fake.voices.duplicate()
	fake.voices = []
	sv._fill_voice_box()
	sv.cap_panel.refresh()
	await _frames(2)
	var vt: String = _all_text(sv.voice_box)
	ok(vt.contains(SystemTts.no_voice_text("en")) and vt.contains(SystemTts.no_voice_text("ja")), "no voice on the phone: the voice section tells how to install one (both languages)")
	ok(str(sv.cap_panel.rows["tts"]["use"]) == "none" and str(sv.cap_panel.rows["tts"]["reason"]).strip_edges() != "", "...and the table shows reading aloud as 없음 with a reason (%s)" % str(sv.cap_panel.rows["tts"]["reason"]))
	var obs2: Array = sv.voice_box.find_children("*", "OptionButton", true, false)
	(obs2[0] as OptionButton).item_selected.emit(0)
	ok(str(Store.prefs.get("tts_sys_voice_en", "")) == "en-gb-x-b", "the '(음성 없음)' placeholder is never saved as a voice")
	fake.voices = voices_backup
	sv._fill_voice_box()
	sv.cap_panel.refresh()
	await _frames(2)

	# ---- PC voice
	var bp: Button = _find_button(sv.tts_engine_box, "PC 음성")
	bp.pressed.emit()
	await _frames(4)
	ok(str(Store.prefs.get("tts_engine", "")) == "pc" and Tts.engine_now() == "pc", "pick 'PC 음성': tts_engine 'pc', engine_now 'pc'")
	obs = sv.voice_box.find_children("*", "OptionButton", true, false)
	ok(obs.size() == 2 and not _all_text(sv.voice_box).contains("이 폰에 설치된 음성만"), "PC engine: the lists and the note are the PC's")
	(obs[0] as OptionButton).item_selected.emit(0)
	ok(str(Store.prefs.get("tts_voice_en", "")) != "" and str(Store.prefs.get("tts_sys_voice_en", "")) == "en-gb-x-b", "a pick with the PC engine goes to tts_voice_en, the phone voice stays")
	ok(str(sv.cap_panel.rows["tts"]["use"]) == "pc", "the table: reading aloud runs on the PC")
	# ---- auto, and a value that is not offered
	var ba: Button = _find_button(sv.tts_engine_box, "자동")
	ba.pressed.emit()
	await _frames(3)
	ok(str(Store.prefs.get("tts_engine", "")) == "auto", "pick 자동: tts_engine 'auto'")
	sv.set_tts_engine("bogus")
	ok(str(Store.prefs.get("tts_engine", "")) == "auto", "a value that is not offered is not saved")

	# ---- credits
	var all: String = _all_text(sv)
	ok(all.contains("wordfreq") and all.contains("CC BY-SA 4.0"), "credits: wordfreq data CC BY-SA 4.0")
	ok(all.contains("Tatoeba") and all.contains("CC BY 2.0 FR"), "credits: Tatoeba CC BY 2.0 FR")

	# ---- layout of the whole screen at the phone size
	await _frames(3)
	var rr := _overflow_and_small(sv, Vector2(SCREEN))
	ok((rr["over"] as Array).is_empty(), "settings: nothing sticks out of the 412 px screen (%s)" % str((rr["over"] as Array).slice(0, 3)))
	ok((rr["small"] as Array).is_empty(), "settings: every button is a touch target (%s)" % str((rr["small"] as Array).slice(0, 3)))
	sv.queue_free()
	await _frames(2)
	_flags["cards"] = true


# ---------------------------------------------------------------- the PC app shows none of it

func _test_pc_hidden() -> void:
	print("[the PC app shows none of it]")
	var sv := SettingsView.new()
	sv.standalone_panels = true # even when asked: the PC app has no phone cards
	sv.set_anchors_preset(Control.PRESET_FULL_RECT)
	var was_phone: Callable = Route.phone_hook
	add_child(sv)
	await _frames(4)
	if _phone:
		# on the phone run the flag works; the PC check below is done with the hook off for Platform-based code only
		ok(sv.cap_panel != null, "(phone run) standalone_panels=true builds the cards")
	else:
		ok(sv.cap_panel == null and sv.mode_box == null and sv.tts_engine_box == null, "PC: no cards were built, although standalone_panels is true")
		ok(sv.find_children("*", "CapabilityPanel", true, false).is_empty(), "PC: no CapabilityPanel in the settings screen")
		ok(not sv.section_visible("engine") or sv._engine_ob != null, "PC: the engine section is the AI engine one, not 처리 위치")
		var t: String = _all_text(sv)
		ok(not t.contains("처리 위치") and not t.contains("기능 현황") and not t.contains("읽어 주는 목소리") and not t.contains("PC 없이 시작") and not t.contains("데이터 출처"), "PC: none of the new texts appear")
		ok(sv.find_children("*", "RemoteLinkPanel", true, false).is_empty(), "PC: still the PC's own panels (no phone link panel)")
	Route.phone_hook = was_phone
	sv.queue_free()
	await _frames(2)
	if not _phone:
		# the whole PC app
		await _new_main()
		var psv: SettingsView = _main.views["settings"]
		ok(psv.cap_panel == null and psv.find_children("*", "CapabilityPanel", true, false).is_empty(), "PC main.tscn: no CapabilityPanel in the settings")
		ok(not _all_text(psv).contains("처리 위치") and not _all_text(psv).contains("읽어 주는 목소리"), "PC main.tscn: no 처리 위치 / 읽어 주는 목소리 in the settings")
		ok(_main._conn_chip.text != "폰 단독 모드", "PC main.tscn: the badge is the engine one (%s)" % _main._conn_chip.text)
		ok(not _main.is_connect_open(), "PC main.tscn: no connect screen")
	_flags["pc_hidden"] = true
