extends Node
## SyncPanel + SyncChoiceDialog (+ the two lines in today_view.gd): 문구는 설계 §6.3 과 글자 그대로, 스위치·버튼이 엔진을 부른다.
##   godot --headless --path <project> res://tests/sync_panel_test.tscn [-- --phone]
## Exit code 0 = all passed. Last line: "== sync_panel result: N passed, 0 failed =="
## 가짜 엔진(sync_manager_test.gd 의 FakeEngine)과 user://test_s7/... 만 쓴다.

const MT := preload("res://tests/sync_manager_test.gd")
const DIR := "user://test_s7/panel"

var passed: int = 0
var failed: int = 0
var _toasts: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int = 2) -> void:
	for i in n:
		await get_tree().process_frame


func _rm(path: String) -> void:
	var g: String = ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(g):
		return
	for f in DirAccess.get_files_at(g):
		DirAccess.remove_absolute(g.path_join(f))
	for d in DirAccess.get_directories_at(g):
		_rm(path.path_join(d))
	DirAccess.remove_absolute(g)


## manager with a fake engine, added to the tree (no timers, no Backend signal).
func _mk(kind: String, e, dialog: bool = false, up: bool = true) -> SyncManager:
	var holder := {"up": up}
	var m := SyncManager.new()
	m.set_meta("up", holder)
	m.engine = e
	e.mgr = m
	m.kind = kind
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = dialog
	m.is_backend_ready = func() -> bool: return bool(holder["up"])
	add_child(m)
	return m


func _drop(m: SyncManager) -> void:
	remove_child(m)
	m.free()


func _panel(m: SyncManager) -> SyncPanel:
	var p := SyncPanel.new()
	p.manager = m
	add_child(p)
	return p


func _all(node: Node, out: Array = []) -> Array:
	out.append(node)
	for c in node.get_children():
		_all(c, out)
	return out


func _texts(node: Node) -> Array:
	var out: Array = []
	for n in _all(node):
		if n is Label and (n as Label).visible:
			out.append((n as Label).text)
	return out


func _button(node: Node, text: String) -> Button:
	for n in _all(node):
		if n is Button and (n as Button).text == text:
			return n
	return null


func _unix(y: int, mo: int, d: int, h: int, mi: int) -> int:
	return int(Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d, "hour": h, "minute": mi, "second": 0}))


func _ready() -> void:
	print("== sync_panel start (phone=%s) ==" % str(Platform.is_phone()))
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	_rm("user://test_s7/panel")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	# first: in --phone mode a UI.button made before main.tscn is instantiated makes Godot exit (pre-existing, see report)
	await _t_back_with_dialog()
	await _t_no_manager()
	await _t_build_texts()
	await _t_switch()
	await _t_sync_button()
	await _t_status_lines()
	_t_formats()
	await _t_backups()
	await _t_relink()
	await _t_dialog_merge()
	await _t_dialog_separate()
	await _t_dialog_pc()
	await _t_dialog_failure()
	await _t_real_engine_restart()
	await _t_today_view()
	await _t_reset_waits_ui()
	_t_touch_rules()
	_t_source_rules()
	_rm("user://test_s7")
	print("== sync_panel result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- panel

func _t_no_manager() -> void:
	print("[no SyncManager: nothing is built]")
	ok(SyncManager.current == null, "no manager registered")
	var p := SyncPanel.new()
	add_child(p)
	await _frames()
	ok(p.get_child_count() == 0, "the panel stays empty (the settings card hides it and its divider)")
	p.queue_free()


func _t_build_texts() -> void:
	print("[panel texts (phone and PC)]")
	var e = MT.FakeEngine.new()
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	ok(p.switch_box.text == "학습 기록 동기화", "title / switch text")
	ok(p.desc_label.text == "PC에 연결돼 있으면 공부한 기록이 PC와 자동으로 합쳐져요. 연결이 안 될 때 공부한 것도 다음 연결 때 반영돼요.", "phone description")
	ok(p.last_label.text == "아직 동기화하지 않았어요", "last sync line before the first sync")
	ok(p.devices_label.text == "아직 다른 기기가 없어요", "devices line without peers")
	ok(p.switch_box.button_pressed and not p.note_label.visible, "switch shows 'on'; the off-note is hidden")
	ok(p.sync_button.text == "지금 동기화" and not p.sync_button.disabled, "sync button text and enabled")
	ok(not p.status_label.visible, "no status line before any round")
	ok(p.restore_link.text == "이전 상태로 되돌리기", "restore link text")
	ok(not p.relink_button.visible, "no re-link button when all is well")
	p.queue_free()
	_drop(m)
	var e2 = MT.FakeEngine.new()
	var m2 := _mk("pc", e2)
	var p2 := _panel(m2)
	await _frames()
	ok(p2.desc_label.text == "휴대폰 연결을 켜고 폰 앱에서 이 PC에 연결하면, 폰과 PC의 학습 기록이 자동으로 합쳐져요.", "PC description")
	p2.switch_box.button_pressed = false
	ok(p2.note_label.text == "끄면 이 기기의 기록은 폰과 주고받지 않아요. 다시 켜면 폰에 남아 있는 기록과 합쳐져요.", "PC: the switch note reads from the PC side")
	p2.queue_free()
	_drop(m2)


func _t_switch() -> void:
	print("[switch]")
	var e = MT.FakeEngine.new()
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	p.switch_box.button_pressed = false # the same as a tap
	ok(e.enabled_calls == [false], "switch off -> engine.set_enabled(false)")
	ok(p.sync_button.disabled, "sync button disabled while the switch is off")
	ok(p.note_label.visible and p.note_label.text == "끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아 있는 기록과 합쳐져요.", "off-note with the §6.3 text")
	ok(not p.switch_box.button_pressed, "the switch stays off")
	p.sync_button.pressed.emit()
	ok(e.calls.is_empty(), "even a forced press sends nothing while off")
	p.switch_box.button_pressed = true
	ok(e.enabled_calls == [false, true], "switch on -> engine.set_enabled(true)")
	ok(e.calls == ["manual"], "switching on starts one sync (%s)" % str(e.calls))
	ok(not p.sync_button.disabled and not p.note_label.visible, "after switching on: button enabled, note hidden")
	# the engine refuses (state file lost): the switch snaps back
	e.lost = true
	m.state_changed.emit()
	ok(not p.switch_box.button_pressed and p.sync_button.disabled, "state lost: the switch shows off and the button is disabled")
	p.queue_free()
	_drop(m)


func _t_sync_button() -> void:
	print("[sync button and status line]")
	var e = MT.FakeEngine.new()
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	_toasts.clear()
	e.hold = true
	p.sync_button.pressed.emit()
	ok(e.calls == ["manual"], "button -> one manual sync")
	ok(p.sync_button.disabled and p.sync_button.text == "동기화 중…", "while running: disabled, text '동기화 중…'")
	ok(p.status_label.visible and p.status_label.text == "동기화 중…", "status line '동기화 중…'")
	ok(p.switch_box.disabled, "the switch cannot be flipped in the middle of a round")
	e.hold = false
	e.released.emit()
	ok(p.sync_button.text == "지금 동기화" and not p.sync_button.disabled, "after the round the button is back")
	ok(p.status_label.text == "동기화됐어요", "status line '동기화됐어요'")
	ok(not _toasts.is_empty() and _toasts[0][0] == "동기화했어요.", "manual toast '동기화했어요.'")
	p.queue_free()
	_drop(m)


func _t_status_lines() -> void:
	print("[error / warning lines]")
	var e = MT.FakeEngine.new()
	e.last_error = {"code": "unreachable", "error": "PC에 닿지 않아요. 연결되면 자동으로 동기화해요.", "at": 5}
	e.peers = [{"device_id": "0123456789abcdef", "name": "내 폰", "kind": "phone", "saved_hub": 1}, {"device_id": "fedcba9876543210", "name": "PC", "kind": "pc", "saved_hub": 1}]
	e.clock_off = -7200
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	ok(p.status_label.visible and p.status_label.text == "PC에 닿지 않아요. 연결되면 자동으로 동기화해요.", "error line = engine text")
	ok(p.devices_label.text == "함께 쓰는 기기: 내 폰, PC", "devices line with names")
	ok(_texts(p.warn_box).has("이 기기의 시계가 PC와 120분 차이 나요. 시계를 자동으로 맞춰 주세요."), "clock warning with minutes")
	e.last_error = {"code": "merge_check_failed", "error": "", "at": 5}
	m.state_changed.emit()
	ok(p.status_label.text == "합친 결과를 확인하지 못해서 이 기기의 기록은 그대로 뒀어요. 다시 시도하거나 앱을 업데이트해 주세요.", "a code without text maps to the §6.3 sentence")
	m.last_result = {"ok": true, "code": "ok", "warnings": ["다른 기기의 앱이 더 새 버전이에요. 그 기기 기록은 앱을 업데이트한 뒤에 합쳐져요."]}
	e.last_error = {"code": "", "error": "", "at": 0}
	m.state_changed.emit()
	ok(_texts(p.warn_box).has("다른 기기의 앱이 더 새 버전이에요. 그 기기 기록은 앱을 업데이트한 뒤에 합쳐져요."), "peer_newer warning is shown")
	ok(p.status_label.text == "동기화됐어요", "no error: '동기화됐어요'")
	p.queue_free()
	_drop(m)


func _t_formats() -> void:
	print("[time and list formats]")
	var t0: int = _unix(2026, 10, 16, 21, 5)
	ok(SyncPanel.last_line(0, t0, 0) == "아직 동기화하지 않았어요", "never synced")
	ok(SyncPanel.last_line(t0, t0 + 30, 0) == "마지막 동기화: 방금 전", "< 60 s: 방금 전")
	ok(SyncPanel.last_line(t0, t0 + 59, 0) == "마지막 동기화: 방금 전", "59 s: 방금 전")
	ok(SyncPanel.last_line(t0, t0 + 180, 0) == "마지막 동기화: 3분 전", "3 minutes")
	ok(SyncPanel.last_line(t0, t0 + 3599, 0) == "마지막 동기화: 59분 전", "59 minutes")
	ok(SyncPanel.last_line(t0, _unix(2026, 10, 16, 23, 50), 0) == "마지막 동기화: 오늘 21:05", "same day: 오늘 21:05")
	ok(SyncPanel.last_line(t0, _unix(2026, 10, 17, 8, 0), 0) == "마지막 동기화: 10월 16일 21:05", "other day: 10월 16일 21:05")
	ok(SyncPanel.last_line(_unix(2026, 10, 16, 12, 5), _unix(2026, 10, 16, 14, 5), 540) == "마지막 동기화: 오늘 21:05", "time zone bias +9 h applied")
	ok(SyncPanel.last_line(t0 + 500, t0, 0) == "마지막 동기화: 방금 전", "a last_ok slightly in the future is 방금 전")
	ok(SyncPanel.stamp_text(t0, 0) == "10월 16일 21:05", "backup time 10월 16일 21:05")
	ok(SyncPanel.devices_line([]) == "아직 다른 기기가 없어요" and SyncPanel.devices_line([{"name": "Pixel 8"}]) == "함께 쓰는 기기: Pixel 8", "devices_line")
	ok(SyncPanel.reason_label("first") == "첫 동기화 전" and SyncPanel.reason_label("auto") == "동기화 전"
		and SyncPanel.reason_label("restore") == "되돌리기 전" and SyncPanel.reason_label("unlink") == "초기화 전", "backup reason labels")


func _t_backups() -> void:
	print("[restore list]")
	var e = MT.FakeEngine.new()
	var t0: int = _unix(2026, 10, 16, 21, 5)
	e.backups = [{"name": "b-auto", "reason": "auto", "at": t0 + 600, "md5": {}}, {"name": "b-first", "reason": "first", "at": t0, "md5": {}}]
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	ok(not p.backup_box.visible, "the list is closed at first")
	p.restore_link.pressed.emit()
	ok(p.backup_box.visible and p.backup_buttons.size() == 2, "link opens a list of 2 backups")
	var bias: int = SyncPanel._bias_min()
	ok((p.backup_buttons[0] as Button).text == SyncPanel.stamp_text(t0 + 600, bias) + " · 동기화 전", "row 1: date and reason (%s)" % (p.backup_buttons[0] as Button).text)
	ok((p.backup_buttons[1] as Button).text == SyncPanel.stamp_text(t0, bias) + " · 첫 동기화 전", "row 2: date and reason")
	(p.backup_buttons[1] as Button).pressed.emit()
	ok(p.restore_confirm.visible and "이 시점으로 되돌릴까요? 자동 동기화가 꺼져요." in _texts(p.restore_confirm), "confirmation text")
	ok(_button(p.restore_confirm, "되돌리기") != null and _button(p.restore_confirm, "취소") != null, "buttons [되돌리기] [취소]")
	_button(p.restore_confirm, "취소").pressed.emit()
	ok(not p.restore_confirm.visible and e.restore_calls.is_empty(), "cancel: nothing restored")
	(p.backup_buttons[1] as Button).pressed.emit()
	_toasts.clear()
	p.restore_yes.pressed.emit()
	ok(e.restore_calls == ["b-first"], "confirm -> engine.restore_backup('b-first')")
	ok(not _toasts.is_empty() and _toasts[0][0] == "되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 PC와 다시 합쳐져요.", "restore toast")
	ok(not p.switch_box.button_pressed and not p.backup_box.visible, "afterwards: switch off, list closed")
	e.backups = []
	p.restore_link.pressed.emit()
	ok(p.backup_buttons.is_empty() and "되돌릴 백업이 아직 없어요." in _texts(p.backup_box), "no backups: a plain sentence")
	p.queue_free()
	_drop(m)


func _t_relink() -> void:
	print("[re-link buttons]")
	var e = MT.FakeEngine.new()
	e.last_error = {"code": "hub_changed", "error": "", "at": 1}
	var m := _mk("phone", e)
	var p := _panel(m)
	await _frames()
	ok(p.relink_button.visible and p.relink_button.text == "이 PC와 새로 합치기", "hub_changed: '이 PC와 새로 합치기'")
	ok(p.status_label.text == "다른 PC에 연결돼 있어요. 아래 '이 PC와 새로 합치기'를 눌러 주세요.", "hub_changed sentence")
	p.relink_button.pressed.emit()
	ok(p.relink_confirm.visible and e.relink_calls == 0, "the button asks first")
	_button(p.relink_confirm, "새로 합치기").pressed.emit()
	ok(e.relink_calls == 1, "confirm -> engine.relink_fresh()")
	p.queue_free()
	_drop(m)
	var e2 = MT.FakeEngine.new()
	e2.lost = true
	var m2 := _mk("phone", e2)
	var p2 := _panel(m2)
	await _frames()
	ok(p2.relink_button.visible and p2.relink_button.text == "새로 합치기", "state_lost: '새로 합치기'")
	ok(p2.status_label.text == "동기화 상태 파일이 손상됐어요. '이전 상태로 되돌리기'로 복원하거나 '새로 합치기'를 눌러 주세요. (기록이 겹쳐 셀 수 있어요)", "state_lost sentence")
	p2.queue_free()
	_drop(m2)


# ---------------------------------------------------------------- dialog

func _dialog_of(m: SyncManager) -> SyncChoiceDialog:
	for c in m.get_children():
		if c is SyncChoiceDialog:
			return c
	return null


func _t_dialog_merge() -> void:
	print("[first-connection dialog: merge]")
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.results.append(MT.FakeEngine.ok_res("manual", {"first": true, "peers": 1}))
	var m := _mk("phone", e, true, false)
	ok(_dialog_of(m) == null, "no dialog before the first READY")
	(m.get_meta("up") as Dictionary)["up"] = true
	m.backend_changed()
	await _frames()
	var d := _dialog_of(m)
	ok(d != null, "phone: dialog opens at the first READY")
	if d == null:
		_drop(m)
		return
	ok(d.title_label.text == "PC와 학습 기록을 합칠까요?", "phone dialog title")
	ok(d.body_label.text == "이 폰과 PC에 따로 쌓인 학습 기록을 하나로 합쳐요. 어느 쪽 기록도 지워지지 않고, 합치기 전에 백업해 둬요. 설정에서 언제든 끌 수 있어요.", "dialog body")
	ok(d.merge_button.text == "합치기" and d.separate_button.text == "따로 쓰기", "dialog buttons")
	ok(e.calls.is_empty() and e.choice_calls.is_empty(), "opening the dialog sends nothing")
	m.backend_changed()
	ok(m.get_children().filter(func(c: Node) -> bool: return c is SyncChoiceDialog).size() == 1, "never two dialogs")
	_toasts.clear()
	d.merge_button.pressed.emit()
	await _frames()
	ok(e.choice_calls == ["merge"], "[합치기] -> engine.set_choice('merge')")
	ok(e.calls == ["manual"], "the first sync ran")
	ok(_dialog_of(m) == null, "dialog closed after the choice")
	ok(not _toasts.is_empty() and _toasts[0][0] == "PC와 폰의 학습 기록을 합쳤어요. 합치기 전 기록은 백업해 뒀어요.", "first-merge toast")
	_drop(m)


func _t_dialog_separate() -> void:
	print("[first-connection dialog: separate, and it never comes back]")
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var m := _mk("phone", e, true)
	m.backend_changed()
	await _frames()
	var d := _dialog_of(m)
	ok(d != null, "dialog open")
	_toasts.clear()
	d.separate_button.pressed.emit()
	await _frames()
	ok(e.choice_calls == ["separate"], "[따로 쓰기] -> engine.set_choice('separate')")
	ok(_dialog_of(m) == null, "dialog closed")
	ok(not _toasts.is_empty() and _toasts[0][0] == "따로 쓰기로 했어요. 설정의 '학습 기록 동기화'를 켜면 언제든 합칠 수 있어요.", "toast text")
	ok(e.calls.is_empty(), "separate: no sync request")
	for i in 600:
		m.advance(1.0)
	ok(e.calls.is_empty() and _dialog_of(m) == null, "10 minutes later: still silent, no dialog")
	var p := _panel(m)
	await _frames()
	ok(not p.switch_box.button_pressed and p.note_label.visible, "the panel shows the switch off")
	p.queue_free()
	_drop(m)
	# "restart": a new manager with the same engine state never asks again
	var m2 := _mk("phone", e, true)
	m2.backend_changed()
	await _frames()
	ok(_dialog_of(m2) == null, "a new manager (restart) does not ask again")
	var p2 := _panel(m2)
	await _frames()
	ok(_dialog_of(m2) == null, "re-creating the panel does not open a dialog")
	p2.queue_free()
	_drop(m2)


func _t_dialog_pc() -> void:
	print("[first-connection dialog on the PC]")
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.probe_result = 0
	var m := _mk("pc", e, true)
	m.backend_changed()
	for i in 200:
		m.advance(1.0)
	await _frames()
	ok(_dialog_of(m) == null, "PC without a phone on the hub: no question")
	e.probe_result = 1
	for i in 60:
		m.advance(1.0)
	await _frames()
	var d := _dialog_of(m)
	ok(d != null and d.title_label.text == "폰과 학습 기록을 합칠까요?", "PC: dialog with the 폰 title")
	ok(d != null and d.body_label.text == SyncPanel.DIALOG_BODY and d.merge_button.text == "합치기" and d.separate_button.text == "따로 쓰기", "PC: same body and buttons")
	_drop(m)


func _t_dialog_failure() -> void:
	print("[dialog: the choice could not be saved]")
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.choice_result = {"ok": false, "code": "disk", "error": ""}
	var m := _mk("phone", e, true)
	m.backend_changed()
	await _frames()
	var d := _dialog_of(m)
	d.merge_button.pressed.emit()
	await _frames()
	ok(_dialog_of(m) == d, "dialog stays open when the engine still needs a choice")
	ok(not d.merge_button.disabled and not d.separate_button.disabled, "buttons usable again")
	ok(d.error_label.visible and d.error_label.text == "기록을 저장하지 못했어요. 저장 공간을 확인해 주세요.", "disk sentence under the text")
	_drop(m)


func _t_real_engine_restart() -> void:
	print("[real SyncEngine + sidecar: separate survives a restart]")
	var sp: String = DIR.path_join("state.json")
	var cnt := {"n": 0}
	var make := func() -> SyncEngine:
		var p := SyncPorts.new()
		p.state_path = sp
		p.backup_root = DIR.path_join("backup")
		p.device_kind = "phone"
		p.now_unix = func() -> int: return 1760000000
		p.today_days = func() -> int: return 20000
		p.load_local = func() -> Dictionary: return {"progress": Progress.blank(), "studylog": {}, "prefs": {}}
		p.apply_local = func(_a: Dictionary, _b: Dictionary, _c: Dictionary) -> bool: return true
		p.local_paths = func() -> Dictionary: return {}
		p.is_read_only = func() -> bool: return false
		p.http_get = func(_path: String, _t: float) -> Dictionary:
			cnt["n"] += 1
			return {"ok": false, "code": 0, "err_code": "transport", "error": "x"}
		p.http_post = func(_path: String, _b: Dictionary, _t: float) -> Dictionary:
			cnt["n"] += 1
			return {"ok": false, "code": 0, "err_code": "transport", "error": "x"}
		p.is_busy_ui = func() -> bool: return false
		return SyncEngine.new(p)
	var m := _mk_real(make.call())
	m.backend_changed()
	await _frames()
	var d := _dialog_of(m)
	ok(d != null and cnt["n"] == 0, "undecided: the dialog is up and nothing was sent")
	d.separate_button.pressed.emit()
	await _frames()
	ok(_dialog_of(m) == null and cnt["n"] == 0, "[따로 쓰기]: closed, nothing sent")
	var raw: String = FileAccess.get_file_as_string(sp)
	ok(raw.contains("\"choice\":\"separate\"") and raw.contains("\"enabled\":false"), "the sidecar says separate / off")
	remove_child(m)
	m.free()
	var m2 := _mk_real(make.call())
	m2.backend_changed()
	for i in 600:
		m2.advance(1.0)
	await _frames()
	var p2 := _panel(m2)
	await _frames()
	ok(_dialog_of(m2) == null and cnt["n"] == 0, "restart + panel re-created: no dialog, 0 requests")
	ok(not p2.switch_box.button_pressed and p2.sync_button.disabled, "the switch is off, the button disabled")
	# turning the switch on later is a plain first sync (it tries the hub: the fake port fails)
	p2.switch_box.button_pressed = true
	await _frames()
	ok(cnt["n"] >= 1, "switch on after 'separate': the first sync goes out")
	ok(m2.engine.status().enabled == true, "engine says enabled")
	p2.queue_free()
	remove_child(m2)
	m2.free()


func _mk_real(eng: SyncEngine) -> SyncManager:
	var m := SyncManager.new()
	m.engine = eng
	m.kind = "phone"
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = true
	m.is_backend_ready = func() -> bool: return true
	add_child(m)
	return m


# ---------------------------------------------------------------- settings card

func _t_today_view() -> void:
	print("[settings card: mount + reset text]")
	var old_pp: String = Store.progress_path
	var old_sl: String = StudyLog.path
	Store.progress_path = DIR.path_join("progress.json")
	StudyLog.path = DIR.path_join("studylog.json")
	# without a manager: the panel is empty, so the card hides it
	var tv0 := TodayView.new()
	add_child(tv0)
	tv0._settings_open = true
	tv0.refresh()
	await _frames()
	var empty_found := false
	for n in _all(tv0):
		if n is SyncPanel:
			empty_found = true
			ok((n as SyncPanel).get_child_count() == 0 and not (n as SyncPanel).visible, "no manager: SyncPanel is mounted but empty and hidden")
	ok(empty_found, "TodayView mounts a SyncPanel in the settings card")
	tv0.queue_free()
	await _frames()
	# with a manager
	var e = MT.FakeEngine.new()
	var m := _mk("phone", e)
	var tv := TodayView.new()
	add_child(tv)
	tv._settings_open = true
	tv.refresh()
	await _frames()
	var sp: SyncPanel = null
	for n in _all(tv):
		if n is SyncPanel:
			sp = n
	ok(sp != null and sp.get_child_count() > 0 and sp.visible and sp.switch_box != null, "with a manager the panel has content")
	var reset_btn := _button(tv, "모든 기록 지우기")
	ok(reset_btn != null, "reset button found")
	var base_text := "정말 지울까요? 되돌릴 수 없어요."
	var sync_text := "동기화가 켜져 있어요. 지우면 이 기기의 동기화 연결이 끊기고, PC 보관함에 올라간 기록은 그대로 남아요. (PC 보관함까지 지우려면 PC의 backend\\data\\sync 폴더를 지우세요.)"
	reset_btn.pressed.emit()
	var tx: Array = _texts(tv)
	var joined := "\n".join(tx)
	ok(joined.contains(sync_text), "sync on: the §4.8 sentence is in the confirm row")
	ok(joined.contains(base_text), "the plain question stays")
	var yes := _button(tv, "지우기")
	yes.pressed.emit()
	ok(e.unlink_calls == 1, "[지우기] -> engine.unlink_for_reset() before the reset")
	await _frames()
	tv.queue_free()
	await _frames()
	# sync off: the old sentence only
	e.enabled = false
	var tv2 := TodayView.new()
	add_child(tv2)
	tv2._settings_open = true
	tv2.refresh()
	await _frames()
	_button(tv2, "모든 기록 지우기").pressed.emit()
	var j2 := "\n".join(_texts(tv2))
	ok(not j2.contains("동기화가 켜져 있어요") and j2.contains(base_text), "sync off: the usual sentence only")
	tv2.queue_free()
	_drop(m)
	Store.progress_path = old_pp
	StudyLog.path = old_sl
	await _frames()


func _t_back_with_dialog() -> void:
	print("[Android back with the first-connection dialog open]")
	# --headless leaves the window at 64x64, too small for the phone layout (the phone_layout test sizes it the same way)
	var want := Vector2i(412, 915) if Platform.is_phone() else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(2)
	var old_starting: bool = Backend._starting
	Backend._starting = true # main._ready must not start a backend
	Backend.set_process(false)
	var main: Control = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await _frames(3)
	main.set("quit_on_exit", false)
	var exits := {"n": 0}
	main.exit_requested.connect(func() -> void: exits["n"] += 1)
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var m := _mk("phone", e, true, false)
	(m.get_meta("up") as Dictionary)["up"] = true
	m.backend_changed()
	await _frames()
	ok(m.is_choice_dialog_open(), "dialog is open")
	main.show_view("lesson")
	_toasts.clear()
	main.handle_back()
	main.handle_back()
	ok(str(main.get("current")) == "lesson", "two backs with the dialog open: the screen behind does not change (%s)" % str(main.get("current")))
	ok(exits["n"] == 0, "no exit request")
	ok(_toasts.size() == 2 and _toasts[0][0] == "합칠지 따로 쓸지 골라 주세요.", "each back says one line: the question must be answered")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST) # the real Android route (handled on the phone only)
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	ok(str(main.get("current")) == "lesson" and exits["n"] == 0, "WM_GO_BACK_REQUEST twice: still no screen change, no exit")
	main.show_view("today")
	main.handle_back()
	main.handle_back()
	main.handle_back()
	ok(exits["n"] == 0 and str(main.get("current")) == "today", "on the 오늘 screen three backs do not end the app either")
	ok(e.choice_calls.is_empty(), "back never answers the question")
	# answered: back works as usual again
	_dialog_of(m).separate_button.pressed.emit()
	await _frames()
	ok(not m.is_choice_dialog_open(), "dialog closed after the answer")
	main.show_view("lesson")
	main.handle_back()
	ok(str(main.get("current")) == "today", "no dialog: back goes to 오늘 again")
	_drop(m)
	main.queue_free()
	await _frames()
	Backend._starting = old_starting
	Backend.set_process(true)


## "지우기" while a sync round is running: the reset waits for the round (otherwise the round writes the hub's copy back).
func _t_reset_waits_ui() -> void:
	print("[settings card: reset waits for a running round]")
	var old_pp: String = Store.progress_path
	var old_sl: String = StudyLog.path
	Store.progress_path = DIR.path_join("progress2.json")
	StudyLog.path = DIR.path_join("studylog2.json")
	var e = MT.FakeEngine.new()
	var m := _mk("phone", e)
	var tv := TodayView.new()
	add_child(tv)
	tv._settings_open = true
	tv.refresh()
	await _frames()
	Store.progress["checks"]["en-9-w9"] = true
	e.hold = true
	m.sync_manual()
	ok(m.is_busy(), "a round is running (held)")
	_button(tv, "모든 기록 지우기").pressed.emit()
	_button(tv, "지우기").pressed.emit()
	ok(e.unlink_calls == 0 and Store.progress["checks"].has("en-9-w9"), "while the round runs: not unlinked, record not wiped yet")
	e.hold = false
	e.released.emit()
	await _frames()
	ok(e.unlink_calls == 1 and not Store.progress["checks"].has("en-9-w9"), "round ended: unlinked, then the record is wiped")
	ok(e.order == ["sync_end", "unlink"], "order: sync_end then unlink (%s)" % str(e.order))
	tv.queue_free()
	_drop(m)
	Store.progress_path = old_pp
	StudyLog.path = old_sl
	await _frames()


# ---------------------------------------------------------------- rules

func _t_touch_rules() -> void:
	print("[touch rules]")
	var e = MT.FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.backups = [{"name": "b", "reason": "first", "at": 1000, "md5": {}}]
	e.last_error = {"code": "hub_changed", "error": "", "at": 1}
	var m := _mk("phone", e, true)
	m.backend_changed()
	var p := _panel(m)
	p.restore_link.pressed.emit()
	var d := _dialog_of(m)
	var bad_filter := 0
	var raw_taps := 0
	var small := 0
	var nodes: Array = _all(p) + _all(d)
	for n in nodes:
		if n is Control:
			if not (n as Control).gui_input.get_connections().is_empty():
				raw_taps += 1
			if n is BaseButton and Platform.is_phone() and (n as Control).custom_minimum_size.y < 44.0:
				small += 1
		if n is BaseButton and (n as BaseButton).focus_mode != Control.FOCUS_NONE:
			bad_filter += 1
	ok(raw_taps == 0, "no raw gui_input tap handlers (only BaseButtons) in the panel and the dialog")
	ok(bad_filter == 0, "buttons do not take keyboard focus (no soft keyboard / focus ring jumps)")
	ok(small == 0, "on the phone every button is at least 44 px high (%d too small)" % small)
	p.queue_free()
	_drop(m)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _t_source_rules() -> void:
	print("[source rules: texts and UI-redesign conditions]")
	var panel_src: String = _read("res://scripts/sync/sync_panel.gd")
	var dialog_src: String = _read("res://scripts/sync/sync_choice_dialog.gd")
	var mgr_src: String = _read("res://scripts/sync/sync_manager.gd")
	var must: Array = [
		"학습 기록 동기화", "PC와 학습 기록을 합칠까요?", "폰과 학습 기록을 합칠까요?",
		"이 폰과 PC에 따로 쌓인 학습 기록을 하나로 합쳐요. 어느 쪽 기록도 지워지지 않고, 합치기 전에 백업해 둬요. 설정에서 언제든 끌 수 있어요.",
		"합치기", "따로 쓰기", "따로 쓰기로 했어요. 설정의 '학습 기록 동기화'를 켜면 언제든 합칠 수 있어요.",
		"휴대폰 연결을 켜고 폰 앱에서 이 PC에 연결하면, 폰과 PC의 학습 기록이 자동으로 합쳐져요.",
		"PC에 연결돼 있으면 공부한 기록이 PC와 자동으로 합쳐져요. 연결이 안 될 때 공부한 것도 다음 연결 때 반영돼요.",
		"마지막 동기화: ", "방금 전", "%d분 전", "오늘 %02d:%02d", "%d월 %d일 %02d:%02d", "아직 동기화하지 않았어요",
		"함께 쓰는 기기: ", "아직 다른 기기가 없어요", "동기화 중…", "동기화됐어요", "지금 동기화",
		"끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아 있는 기록과 합쳐져요.",
		"이전 상태로 되돌리기", "첫 동기화 전", "동기화 전", "되돌리기 전", "초기화 전",
		"이 시점으로 되돌릴까요? 자동 동기화가 꺼져요.", "되돌리기", "취소",
		"PC와 폰의 학습 기록을 합쳤어요. 합치기 전 기록은 백업해 뒀어요.", "동기화했어요.", " 복습 카드 %d장이 새로 들어왔어요.",
		"이 기기의 시계가 PC와 %d분 차이 나요. 시계를 자동으로 맞춰 주세요.",
		"되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 PC와 다시 합쳐져요.",
		"동기화가 켜져 있어요. 지우면 이 기기의 동기화 연결이 끊기고, PC 보관함에 올라간 기록은 그대로 남아요. (PC 보관함까지 지우려면 PC의 backend\\\\data\\\\sync 폴더를 지우세요.)",
	]
	var missing: Array = _missing(panel_src, must)
	ok(missing.is_empty(), "sync_panel.gd contains all %d §6.3 / §4.8 phrases (missing: %s)" % [must.size(), str(missing)])
	var bad: Array = []
	for pat in ["Color(", "Color(\"", "font_size", "Pal.", "add_theme_color_override", "gui_input"]:
		for pair in [["sync_panel.gd", panel_src], ["sync_choice_dialog.gd", dialog_src], ["sync_manager.gd", mgr_src]]:
			if (pair[1] as String).contains(pat):
				bad.append("%s: %s" % [pair[0], pat])
	ok(bad.is_empty(), "no direct colours / font sizes / raw gui_input in the three sync UI files (%s)" % str(bad))
	var today_src: String = _read("res://scripts/views/today_view.gd")
	ok(today_src.contains("_mount_link_panel(card, SyncPanel.new())"), "today_view.gd mounts the panel with one line")
	var main_src: String = _read("res://scripts/main.gd")
	ok(main_src.contains("func add_sync()") and main_src.contains("\t\tadd_sync()"), "main.gd: add_sync() next to add_v11_tabs()")
	# the checker must be able to fail: a phrase that is not there (or one letter off) is reported
	ok(_missing(panel_src, ["이 문구는 없어요 zzz"]).size() == 1, "self-check: a phrase that is not in the file is reported missing")
	ok(_missing(panel_src, ["끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아 있는 기록과 합쳐져요"]).is_empty()
		and _missing(panel_src, ["끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아있는 기록과 합쳐져요."]).size() == 1,
		"self-check: one missing space makes a phrase 'missing'")


func _missing(src: String, phrases: Array) -> Array:
	var out: Array = []
	for ph in phrases:
		if not src.contains(str(ph)):
			out.append(ph)
	return out
