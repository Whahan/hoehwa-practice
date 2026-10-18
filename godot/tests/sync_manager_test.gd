extends Node
## SyncManager (scripts/sync/sync_manager.gd): 언제 동기화하나. 가짜 엔진 + 가상 시간(advance)으로 규칙을 시험한다.
##   godot --headless --path <project> res://tests/sync_manager_test.tscn
## Exit code 0 = all passed. Last line: "== sync_manager result: N passed, 0 failed =="
## 네트워크·실제 사용자 파일을 쓰지 않는다. 실제 SyncEngine 을 쓰는 사례는 가짜 SyncPorts(http 호출 횟수를 센다)와 user://test_s7/... 만 쓴다.

const DIR := "user://test_s7/mgr"

var passed: int = 0
var failed: int = 0
var _toasts: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- fake engine

class FakeEngine:
	extends RefCounted
	signal released
	var choice: String = "merge"
	var enabled: bool = true
	var lost: bool = false
	var fp: String = "a"
	var calls: Array = [] ## reason of every sync_now
	var times: Array = [] ## manager time of every sync_now
	var caps: Array = [] ## http cap seen by every sync_now
	var results: Array = [] ## queued results (front first); empty = ok
	var hold: bool = false
	var probe_calls: int = 0
	var probe_result: int = 0
	var enabled_calls: Array = []
	var choice_calls: Array = []
	var unlink_calls: int = 0
	var restore_calls: Array = []
	var relink_calls: int = 0
	var mgr = null
	var backups: Array = []
	var peers: Array = []
	var last_ok: int = 0
	var last_error: Dictionary = {"code": "", "error": "", "at": 0}
	var clock_off: int = 0
	var choice_result: Dictionary = {} ## non-empty: set_choice returns this and changes nothing (a failed save)

	func status() -> Dictionary:
		return {"enabled": enabled and not lost, "choice": choice, "linked": true, "busy": false, "last_ok": last_ok,
			"last_error": last_error.duplicate(), "peers": peers.duplicate(true), "backups": backups.size(), "clock_off_sec": clock_off,
			"first_done": true, "lost": lost, "device_id": "0123456789abcdef"}

	func needs_choice() -> bool:
		return not lost and choice == "undecided"

	var fp_calls: int = 0
	var order: Array = [] ## "sync_end" / "unlink" in the order they happened

	func local_fingerprint() -> String:
		fp_calls += 1
		return fp

	func sync_now(reason: String) -> Dictionary:
		calls.append(reason)
		times.append(mgr.elapsed() if mgr != null else 0.0)
		caps.append(float(mgr._http_cap["v"]) if mgr != null else 0.0)
		if hold:
			await released
		order.append("sync_end")
		if not results.is_empty():
			var r: Dictionary = results.pop_front()
			r["reason"] = reason
			return r
		return FakeEngine.ok_res(reason)

	static func ok_res(reason: String = "", extra: Dictionary = {}) -> Dictionary:
		var r := {"ok": true, "code": "ok", "error": "", "applied": false, "pushed": false, "reason": reason, "peers": 1,
			"changes": {"cards_added": 0}, "trimmed": {"cards": 0, "known": 0}, "warnings": [], "first": false}
		for k in extra.keys():
			r[k] = extra[k]
		return r

	static func fail_res(code: String, text: String = "x") -> Dictionary:
		return {"ok": false, "code": code, "error": text, "applied": false, "pushed": false, "reason": "", "peers": 0,
			"changes": {}, "trimmed": {"cards": 0, "known": 0}, "warnings": [], "first": false}

	func probe_peers() -> int:
		probe_calls += 1
		return probe_result

	func set_enabled(on: bool) -> void:
		enabled_calls.append(on)
		if on and choice == "undecided":
			choice = "merge"
		enabled = on

	func set_choice(c: String) -> Dictionary:
		choice_calls.append(c)
		if not choice_result.is_empty():
			return choice_result
		if c == "separate":
			choice = c
			enabled = false
			return FakeEngine.ok_res()
		choice = "merge"
		enabled = true
		return await sync_now("manual")

	func list_backups() -> Array:
		return backups

	func restore_backup(name: String) -> Dictionary:
		restore_calls.append(name)
		enabled = false
		return {"ok": true, "error": ""}

	func unlink_for_reset() -> void:
		unlink_calls += 1
		order.append("unlink")

	func relink_fresh() -> Dictionary:
		relink_calls += 1
		choice = "merge"
		enabled = true
		return await sync_now("manual")


# ---------------------------------------------------------------- harness

func _mk(kind: String, e: FakeEngine) -> Dictionary:
	var h := {"up": false}
	var m := SyncManager.new()
	m.engine = e
	e.mgr = m
	m.kind = kind
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = false
	m.is_backend_ready = func() -> bool: return bool(h["up"])
	add_child(m)
	h["m"] = m
	h["e"] = e
	h["choices"] = []
	m.choice_needed.connect(func(k: String) -> void: (h["choices"] as Array).append(k))
	return h


func _up(h: Dictionary, on: bool = true) -> void:
	h["up"] = on
	(h["m"] as SyncManager).backend_changed()


func _run(h: Dictionary, secs: float, dt: float = 1.0) -> void:
	var n: int = int(round(secs / dt))
	for i in n:
		(h["m"] as SyncManager).advance(dt)


func _end(h: Dictionary) -> void:
	var m: SyncManager = h["m"]
	remove_child(m)
	m.free()


func _count(arr: Array, v: Variant) -> int:
	var n := 0
	for x in arr:
		if x == v:
			n += 1
	return n


func _rm(path: String) -> void:
	var g: String = ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(g):
		return
	for f in DirAccess.get_files_at(g):
		DirAccess.remove_absolute(g.path_join(f))
	for d in DirAccess.get_directories_at(g):
		_rm(path.path_join(d))
	DirAccess.remove_absolute(g)


func _ready() -> void:
	print("== sync_manager start ==")
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	_rm("user://test_s7")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_t_undecided_phone()
	_t_off_and_lost()
	_t_pc_undecided_probe()
	_t_pc_probe_stops()
	_t_switch_off_before_fire()
	_t_start_and_reconnect()
	_t_debounce()
	_t_continuous_changes()
	_t_min_gap()
	_t_change_hint()
	_t_polling()
	_t_backoff()
	_t_reconnect_resets_backoff()
	_t_halt_codes()
	_t_busy()
	await _t_coalesce()
	_t_pause_resume()
	_t_pc_lifecycle()
	_t_close()
	_t_phone_never_probes()
	await _t_backend_signal()
	_t_wrap_ports()
	await _t_choose_and_switch()
	_t_toasts()
	_t_misc_calls()
	await _t_real_engine_undecided()
	await _t_real_engine_before_ready()
	await _t_reset_waits()
	await _t_reset_e2e()
	_t_static_texts()
	_rm("user://test_s7")
	print("== sync_manager result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- tests

func _t_undecided_phone() -> void:
	print("[phone, choice undecided: zero requests, one choice_needed]")
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	ok((h["choices"] as Array) == ["phone"], "first READY: choice_needed('phone') once -> %s" % str(h["choices"]))
	# 1 hour with changing fingerprints, pause / resume and every request path
	for i in 3600:
		if i % 60 == 0:
			e.fp = "f%d" % i
		m.advance(1.0)
		if i % 600 == 300:
			m.on_app_paused()
			m.on_app_resumed()
		if i % 100 == 0:
			for r in ["start", "reconnect", "change", "poll", "pause", "resume", "manual"]:
				m.request_sync(r)
			m.sync_manual()
	ok(e.calls.is_empty(), "undecided: sync_now never called in 1 h (calls=%d)" % e.calls.size())
	ok(e.probe_calls == 0, "phone never probes (probe_calls=%d)" % e.probe_calls)
	ok((h["choices"] as Array).size() == 1, "still exactly one choice_needed after 1 h")
	_up(h, false)
	_up(h, true)
	ok((h["choices"] as Array).size() == 1 and e.calls.is_empty(), "READY again before choosing: no second signal, still zero requests")
	_end(h)


func _t_off_and_lost() -> void:
	print("[switch off / lost: zero requests]")
	var e := FakeEngine.new()
	e.enabled = false
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	for i in 3600:
		if i % 40 == 0:
			e.fp = "g%d" % i
		m.advance(1.0)
		if i % 500 == 250:
			m.on_app_paused()
			m.on_app_resumed()
		if i % 100 == 0:
			for r in ["start", "reconnect", "change", "poll", "pause", "resume", "manual"]:
				m.request_sync(r)
			m.sync_manual()
	ok(e.calls.is_empty(), "switch off (choice merge): sync_now never called in 1 h (calls=%d)" % e.calls.size())
	ok((h["choices"] as Array).is_empty(), "already chose: no choice_needed")
	_end(h)
	var e2 := FakeEngine.new()
	e2.lost = true
	var h2 := _mk("pc", e2)
	_up(h2)
	_run(h2, 600)
	m = h2["m"]
	m.request_sync("poll")
	m.sync_manual()
	ok(e2.calls.is_empty() and e2.probe_calls == 0, "state lost: no sync, no probe")
	_end(h2)


func _t_pc_undecided_probe() -> void:
	print("[PC undecided: probe every 60 s, only then]")
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.probe_result = 0
	var h := _mk("pc", e)
	_run(h, 120)
	ok(e.probe_calls == 0, "before READY: no probe")
	_up(h)
	_run(h, 2.0)
	ok(e.probe_calls == 0, "2 s after READY: no probe yet")
	_run(h, 1.0)
	ok(e.probe_calls == 1, "3 s after READY: first probe (%d)" % e.probe_calls)
	_run(h, 59.0)
	ok(e.probe_calls == 1, "62 s: still one probe")
	_run(h, 1.0)
	ok(e.probe_calls == 2, "63 s: second probe, 60 s after the first (%d)" % e.probe_calls)
	_run(h, 120.0)
	ok(e.probe_calls == 4, "183 s: four probes (%d)" % e.probe_calls)
	ok((h["choices"] as Array).is_empty(), "hub has no other device: choice_needed never fires")
	ok(e.calls.is_empty(), "probing is the only request: sync_now 0 calls")
	e.probe_result = 1
	_run(h, 60.0)
	ok((h["choices"] as Array) == ["pc"], "another device found: choice_needed('pc') once -> %s" % str(h["choices"]))
	var n: int = e.probe_calls
	_run(h, 600.0)
	ok(e.probe_calls == n, "after the signal the probe stops while the dialog is open")
	ok((h["choices"] as Array).size() == 1 and e.calls.is_empty(), "no second signal, no sync")
	_end(h)


func _t_pc_probe_stops() -> void:
	print("[PC: the probe ends with the choice]")
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 70)
	var n: int = e.probe_calls
	ok(n == 2, "two probes in 70 s (%d)" % n)
	e.choice = "separate" # decided somewhere else (e.g. the settings switch of another view)
	_run(h, 600)
	ok(e.probe_calls == n, "choice made: no probe any more (%d)" % e.probe_calls)
	ok(e.calls.is_empty(), "separate: zero sync requests")
	_end(h)


func _t_switch_off_before_fire() -> void:
	print("[a delayed start is re-checked just before it goes out]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	_up(h)
	_run(h, 2)
	e.enabled = false # the switch is turned off inside the 3 s delay
	_run(h, 5)
	ok(e.calls.is_empty(), "switch off during the start delay: nothing is sent")
	_end(h)


func _t_start_and_reconnect() -> void:
	print("[start 3 s after the first READY, reconnect 1 s after it comes back]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	_run(h, 30)
	ok(e.calls.is_empty(), "no request before the first READY (30 s)")
	_up(h)
	_run(h, 2.0)
	ok(e.calls.is_empty(), "2 s after READY: nothing yet")
	_run(h, 1.0)
	ok(e.calls == ["start"], "3 s after READY: one 'start' -> %s" % str(e.calls))
	_up(h, false)
	_run(h, 10)
	ok(e.calls == ["start"], "backend down: nothing is sent")
	_up(h, true)
	_run(h, 0.5, 0.5)
	ok(e.calls == ["start"], "reconnect: not before 1 s")
	_run(h, 0.5, 0.5)
	ok(e.calls == ["start", "reconnect"], "1 s after READY is back: one 'reconnect' -> %s" % str(e.calls))
	_end(h)


func _t_debounce() -> void:
	print("[change: 20 s quiet, checked every 20 s]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 10)
	ok(e.calls == ["start"], "start sync done")
	e.fp = "b"
	_run(h, 29) # t = 39
	ok(e.calls == ["start"], "t=39: change noticed at 20, quiet time not over -> no sync (%s)" % str(e.calls))
	_run(h, 1) # t = 40
	ok(e.calls == ["start", "change"], "t=40: 20 s after the change was noticed -> one 'change' (%s)" % str(e.calls))
	_run(h, 60)
	ok(_count(e.calls, "change") == 1, "the same fingerprint does not trigger again")
	ok(m.failure_count() == 0, "no failures")
	_end(h)


func _t_continuous_changes() -> void:
	print("[change: a fingerprint that keeps moving is never sent]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	for i in 80: # 80 s, every 15 s something changes (less than the 20 s quiet time)
		if i % 15 == 14:
			e.fp = "m%d" % i
		m.advance(1.0)
	ok(_count(e.calls, "change") == 0, "a change every 15 s for 80 s: no 'change' sync (%s)" % str(e.calls))
	_end(h)


func _t_min_gap() -> void:
	print("[change: at least 30 s after the previous automatic round]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 35)
	m.sync_manual()
	ok(e.calls == ["start", "manual"], "manual at 35 s: runs at once (%s)" % str(e.calls))
	e.fp = "b" # noticed at the check at 40
	_run(h, 44) # t = 79
	ok(_count(e.calls, "change") == 0, "t=79: quiet since 40 s but the last round ended at 35 s -> still waiting (%s)" % str(e.calls))
	_run(h, 1) # t = 80
	ok(_count(e.calls, "change") == 1, "t=80: 45 s after the last round -> 'change' (%s)" % str(e.calls))
	_end(h)


func _t_change_hint() -> void:
	print("[change_hint: the heavy fingerprint is skipped while the files did not change]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	var hint := {"v": "files-1"}
	m.change_hint = func() -> String: return str(hint["v"])
	_up(h)
	_run(h, 10)
	var base_calls: int = e.fp_calls
	_run(h, 70) # t = 80: checks at 20, 40, 60, 80 with the same hint (the first poll is at 90)
	ok(e.fp_calls - base_calls <= 1, "same hint for 4 checks: at most 1 fingerprint computation (%d)" % (e.fp_calls - base_calls))
	_run(h, 15) # t = 95: the poll at 90 has run
	e.fp = "changed"
	hint["v"] = "files-2"
	_run(h, 50) # t = 145: check at 100 sees the change, check at 120 confirms
	ok(_count(e.calls, "change") == 1, "hint changed + fingerprint changed: one 'change' sync (%s)" % str(e.calls))
	hint["v"] = ""
	var c2: int = e.fp_calls
	_run(h, 60) # hint "" = unknown: every check computes
	ok(e.fp_calls - c2 >= 3, "empty hint: the fingerprint is computed at every check (%d)" % (e.fp_calls - c2))
	_end(h)
	var e2 := FakeEngine.new()
	var h2 := _mk("phone", e2)
	_up(h2)
	_run(h2, 100)
	ok(e2.fp_calls >= 5, "without a hint function every check computes (%d)" % e2.fp_calls)
	_end(h2)
	ok(SyncManager.live_change_hint() is String, "live_change_hint() works on the real stores")


func _t_polling() -> void:
	print("[polling: PC 60 s, phone 90 s]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	_up(h)
	_run(h, 600)
	ok(_count(e.calls, "poll") == 10, "PC: 10 polls in 600 s (%d)" % _count(e.calls, "poll"))
	_end(h)
	var e2 := FakeEngine.new()
	var h2 := _mk("phone", e2)
	_up(h2)
	_run(h2, 600)
	ok(_count(e2.calls, "poll") == 6, "phone: 6 polls in 600 s (%d)" % _count(e2.calls, "poll"))
	_end(h2)


func _t_backoff() -> void:
	print("[failures: 30, 60, 120, 240, 300 s]")
	ok(SyncManager.backoff_for(1) == 30.0 and SyncManager.backoff_for(2) == 60.0 and SyncManager.backoff_for(3) == 120.0
		and SyncManager.backoff_for(4) == 240.0 and SyncManager.backoff_for(5) == 300.0 and SyncManager.backoff_for(9) == 300.0
		and SyncManager.backoff_for(0) == 0.0, "backoff_for: 30 60 120 240 300 300")
	var e := FakeEngine.new()
	for i in 20:
		e.results.append(FakeEngine.fail_res("unreachable", "PC에 닿지 않아요. 연결되면 자동으로 동기화해요."))
	var h := _mk("pc", e)
	_up(h)
	_toasts.clear()
	_run(h, 800)
	var want: Array = [3.0, 60.0, 120.0, 240.0, 480.0, 780.0]
	ok(e.times == want, "attempt times follow the backoff (want %s, got %s)" % [str(want), str(e.times)])
	ok(_toasts.is_empty(), "automatic failures are silent (no toast)")
	ok((h["m"] as SyncManager).failure_count() == 6, "failure count 6")
	_end(h)


func _t_reconnect_resets_backoff() -> void:
	print("[READY again: the failure wait is cleared]")
	var e := FakeEngine.new()
	for i in 20:
		e.results.append(FakeEngine.fail_res("unreachable"))
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 130) # failures at 3, 60, 120 -> waiting until 240
	ok(e.calls.size() == 3, "three failed attempts by 130 s (%d)" % e.calls.size())
	_up(h, false)
	_run(h, 5)
	_up(h, true) # t = 135
	_run(h, 1)
	ok(e.calls.size() == 4 and e.calls[3] == "reconnect", "back at 135 s: 'reconnect' goes out although the wait ran until 240 s (%s)" % str(e.calls))
	ok(m.failure_count() == 1, "the new attempt counts as failure 1, not 4 (%d)" % m.failure_count())
	_end(h)


func _t_halt_codes() -> void:
	print("[errors that repeat: automatic tries stop, manual still works]")
	var e := FakeEngine.new()
	e.results.append(FakeEngine.fail_res("hub_changed", "다른 PC에 연결돼 있어요."))
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 700)
	ok(e.calls.size() == 1, "hub_changed: one attempt, no automatic retry in 700 s (%d)" % e.calls.size())
	m.sync_manual()
	ok(e.calls.size() == 2 and e.calls[1] == "manual", "manual sync still goes out")
	_run(h, 130)
	ok(_count(e.calls, "poll") >= 1, "after a successful manual round the automatic ones run again")
	_end(h)


func _t_busy() -> void:
	print("[busy: not an error, retried after 5 s]")
	var e := FakeEngine.new()
	e.results.append({"ok": false, "code": "busy", "error": "", "applied": false, "peers": 1, "warnings": [], "changes": {}, "trimmed": {}})
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_toasts.clear()
	_up(h)
	_run(h, 3)
	ok(e.calls == ["start"], "start goes out at 3 s")
	ok(m.failure_count() == 0, "busy is not counted as a failure")
	_run(h, 4) # t = 7
	ok(e.calls.size() == 1, "t=7: not retried yet")
	_run(h, 1) # t = 8
	ok(e.calls == ["start", "start"] and e.times == [3.0, 8.0], "t=8: retried 5 s later (%s %s)" % [str(e.calls), str(e.times)])
	ok(_toasts.is_empty(), "no toast for an automatic busy")
	_end(h)
	var e2 := FakeEngine.new()
	e2.results.append({"ok": false, "code": "busy", "error": "", "applied": false, "peers": 1, "warnings": [], "changes": {}, "trimmed": {}})
	var h2 := _mk("pc", e2)
	_up(h2)
	_toasts.clear()
	(h2["m"] as SyncManager).sync_manual()
	ok(_toasts.size() == 1 and _toasts[0][0] == SyncPanel.TOAST_BUSY and _toasts[0][1] == "info", "manual + busy: info toast '%s'" % SyncPanel.TOAST_BUSY)
	_run(h2, 5)
	ok(_count(e2.calls, "manual") == 2, "the manual request is retried too (%s)" % str(e2.calls))
	_end(h2)


func _t_coalesce() -> void:
	print("[a request during a running round is merged into one more]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	e.hold = true
	_run(h, 3)
	ok(e.calls == ["start"] and m.is_busy(), "start is running (held)")
	for r in ["change", "change", "poll", "resume"]:
		m.request_sync(r)
	m.sync_manual()
	ok(e.calls.size() == 1, "requests while busy start nothing (%d)" % e.calls.size())
	e.hold = false
	e.released.emit()
	ok(e.calls.size() == 2 and not m.is_busy(), "after the round exactly one more runs (calls=%d)" % e.calls.size())
	ok(e.calls[1] == "resume", "the one more carries the latest reason")
	_end(h)


func _t_pause_resume() -> void:
	print("[phone: background / foreground]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 10)
	ok(e.calls == ["start"], "start done, fingerprint synced")
	m.on_app_paused()
	ok(m.is_paused() and e.calls == ["start"], "paused with the same fingerprint: no request")
	_run(h, 400)
	ok(e.calls == ["start"], "no polling, no change check while in the background (%s)" % str(e.calls))
	m.on_app_resumed()
	_run(h, 0.5, 0.5)
	ok(e.calls == ["start"], "resume: not before 1 s")
	_run(h, 0.5, 0.5)
	ok(e.calls == ["start", "resume"] and not m.is_paused(), "resume: one sync 1 s later (%s)" % str(e.calls))
	_run(h, 88)
	ok(_count(e.calls, "poll") == 0, "polling restarts 90 s after the return")
	_run(h, 1)
	ok(_count(e.calls, "poll") == 1, "poll 90 s after the return")
	# leaving with unsynced changes
	e.fp = "zz"
	m.on_app_paused()
	ok(e.calls[e.calls.size() - 1] == "pause", "paused with a different fingerprint: one 'pause' sync at once")
	ok(e.caps[e.caps.size() - 1] == 5.0, "the pause sync runs with the 5 s HTTP cap (%s)" % str(e.caps[e.caps.size() - 1]))
	ok(_count(e.caps, 5.0) == 1, "no other round has the cap")
	ok(float(m._http_cap["v"]) == 0.0, "cap removed after the round")
	var n: int = e.calls.size()
	m.on_app_paused()
	ok(e.calls.size() == n, "already synced + paused: no second one")
	_end(h)


func _t_pc_lifecycle() -> void:
	print("[PC ignores pause notifications]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 10)
	e.fp = "dirty"
	m._notification(NOTIFICATION_APPLICATION_PAUSED)
	m._notification(NOTIFICATION_APPLICATION_RESUMED)
	ok(not m.is_paused() and e.calls == ["start"], "PC: pause / resume change nothing")
	_end(h)


func _t_close() -> void:
	print("[quit]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 10)
	e.fp = "dirty"
	m._notification(NOTIFICATION_WM_CLOSE_REQUEST)
	ok(e.calls == ["start"], "window close: no sync is started (the quit is not delayed)")
	ok(SyncManager.current == m, "current manager registered while in the tree")
	remove_child(m)
	ok(SyncManager.current == null, "leaving the tree clears SyncManager.current")
	m.advance(100.0)
	m.request_sync("change")
	m.sync_manual()
	ok(e.calls == ["start"], "after leaving the tree nothing runs")
	m.free()


func _t_phone_never_probes() -> void:
	print("[the probe belongs to the PC only]")
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	e.probe_result = 3
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	m._choice_emitted = false # white box: even if the phone had not announced its question
	_run(h, 600)
	ok(e.probe_calls == 0, "phone: probe_peers is never called (%d)" % e.probe_calls)
	_end(h)


func _t_backend_signal() -> void:
	print("[the real Backend.status_changed signal drives the manager]")
	var old: int = Backend.status
	Backend.status = Backend.Status.IDLE
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var m := SyncManager.new()
	m.engine = e
	e.mgr = m
	m.kind = "phone"
	m.auto_process = false
	m.auto_dialog = false
	var got: Array = []
	m.choice_needed.connect(func(k: String) -> void: got.append(k))
	add_child(m)
	ok(m.connect_backend, "connect_backend is on by default")
	Backend._set_status(Backend.Status.CHECKING)
	Backend._set_status(Backend.Status.STARTING)
	ok(got.is_empty(), "not READY yet: no question")
	Backend._set_status(Backend.Status.READY)
	ok(got == ["phone"], "first READY: the phone question once")
	Backend._set_status(Backend.Status.FAILED)
	Backend._set_status(Backend.Status.READY)
	Backend._set_status(Backend.Status.READY)
	ok(got == ["phone"] and e.calls.is_empty(), "READY again: no second question, still zero requests")
	remove_child(m)
	m.free()
	# decided: the signal path leads to the start and reconnect rounds
	var e2 := FakeEngine.new()
	var m2 := SyncManager.new()
	m2.engine = e2
	e2.mgr = m2
	m2.kind = "pc"
	m2.auto_process = false
	m2.auto_dialog = false
	Backend.status = Backend.Status.IDLE
	add_child(m2)
	Backend._set_status(Backend.Status.READY)
	for i in 3:
		m2.advance(1.0)
	ok(e2.calls == ["start"], "Backend READY -> start sync after 3 s (%s)" % str(e2.calls))
	Backend._set_status(Backend.Status.FAILED)
	for i in 5:
		m2.advance(1.0)
	Backend._set_status(Backend.Status.READY)
	m2.advance(1.0)
	ok(e2.calls == ["start", "reconnect"], "FAILED -> READY -> reconnect sync after 1 s (%s)" % str(e2.calls))
	Backend._set_status(Backend.Status.READY) # the periodic health refresh emits status_changed while READY
	for i in 5:
		m2.advance(1.0)
	ok(e2.calls == ["start", "reconnect"], "status_changed while already READY starts nothing")
	remove_child(m2)
	m2.free()
	Backend.status = old


func _t_wrap_ports() -> void:
	print("[HTTP cap wrapper]")
	var seen: Array = []
	var p := SyncPorts.new()
	p.http_get = func(path: String, timeout: float) -> Dictionary:
		seen.append(["get", path, timeout])
		return {"ok": true}
	p.http_post = func(path: String, _body: Dictionary, timeout: float) -> Dictionary:
		seen.append(["post", path, timeout])
		return {"ok": true}
	var m := SyncManager.new()
	m.wrap_ports(p)
	p.http_get.call("/sync/pull", 45.0)
	ok(seen[0][2] == 45.0, "no cap: the engine's timeout is kept")
	m._http_cap["v"] = 5.0
	p.http_get.call("/sync/pull", 45.0)
	p.http_post.call("/sync/push", {}, 60.0)
	p.http_get.call("/sync/pull", 3.0)
	ok(seen[1][2] == 5.0 and seen[2][2] == 5.0, "cap 5 s: pull 45 -> 5, push 60 -> 5 (%s)" % str([seen[1][2], seen[2][2]]))
	ok(seen[3][2] == 3.0, "a shorter timeout stays")
	m.free()


func _t_choose_and_switch() -> void:
	print("[choose / switch]")
	var e := FakeEngine.new()
	e.choice = "undecided"
	e.enabled = false
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	_up(h)
	_toasts.clear()
	var r: Dictionary = await m.choose("separate")
	ok(e.choice_calls == ["separate"] and bool(r["ok"]), "choose('separate') -> engine.set_choice('separate')")
	ok(_toasts.size() == 1 and _toasts[0][0] == SyncPanel.TOAST_SEPARATE, "separate: toast with the §6.3 text")
	e.calls.clear()
	_run(h, 700)
	ok(e.calls.is_empty(), "separate: no request afterwards")
	# switch on: set_enabled(true) and a first sync at once
	m.set_enabled(true)
	ok(e.enabled_calls == [true] and e.calls == ["manual"], "switch on: engine.set_enabled(true) + one manual sync (%s)" % str(e.calls))
	# switch off
	e.calls.clear()
	m.set_enabled(false)
	ok(e.enabled_calls == [true, false], "switch off: engine.set_enabled(false)")
	_run(h, 700)
	m.request_sync("poll")
	ok(e.calls.is_empty(), "switch off: no request in 700 s")
	_end(h)
	# merge
	var e2 := FakeEngine.new()
	e2.choice = "undecided"
	e2.enabled = false
	e2.results.append(FakeEngine.ok_res("manual", {"first": true, "peers": 1}))
	var h2 := _mk("phone", e2)
	var m2: SyncManager = h2["m"]
	_up(h2)
	_toasts.clear()
	var r2: Dictionary = await m2.choose("merge")
	ok(e2.choice_calls == ["merge"] and e2.calls == ["manual"] and bool(r2["ok"]), "choose('merge') -> engine.set_choice('merge') -> first sync")
	ok(_toasts.size() == 1 and _toasts[0][0] == SyncPanel.TOAST_FIRST_MERGE and _toasts[0][1] == "ok", "first merge: toast once with the §6.3 text")
	_end(h2)


func _t_toasts() -> void:
	print("[toasts]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	_run(h, 5)
	_toasts.clear()
	m.sync_manual()
	ok(_toasts.size() == 1 and _toasts[0][0] == "동기화했어요." and _toasts[0][1] == "ok", "manual success: '동기화했어요.'")
	_toasts.clear()
	e.results.append(FakeEngine.ok_res("", {"changes": {"cards_added": 3}}))
	m.sync_manual()
	ok(_toasts.size() == 1 and _toasts[0][0] == "동기화했어요. 복습 카드 3장이 새로 들어왔어요.", "manual success with new cards -> %s" % str(_toasts))
	_toasts.clear()
	e.results.append(FakeEngine.fail_res("old_pc", ""))
	m.sync_manual()
	ok(_toasts.size() == 1 and _toasts[0][1] == "error" and _toasts[0][0] == "이 PC의 회화 연습이 기록 동기화를 지원하지 않아요. PC 앱을 1.2 이상으로 업데이트해 주세요.",
		"manual failure: error toast with the §6.3 old_pc text -> %s" % str(_toasts))
	_toasts.clear()
	_run(h, 60)
	ok(_toasts.is_empty(), "automatic polls: no toast")
	e.results.append(FakeEngine.ok_res("", {"first": false, "trimmed": {"cards": 2, "known": 5}}))
	m.request_sync("change")
	ok(_toasts.size() == 1 and _toasts[0][0].find("2장") >= 0 and _toasts[0][0].find("5개") >= 0, "trimmed result: info toast")
	_end(h)


func _t_misc_calls() -> void:
	print("[reset / restore / relink]")
	var e := FakeEngine.new()
	var h := _mk("phone", e)
	var m: SyncManager = h["m"]
	m.before_reset()
	ok(e.unlink_calls == 1, "before_reset -> engine.unlink_for_reset()")
	_toasts.clear()
	var r: Dictionary = m.restore("20260101-000000-first")
	ok(e.restore_calls == ["20260101-000000-first"] and bool(r["ok"]), "restore -> engine.restore_backup(name)")
	ok(_toasts.size() == 1 and _toasts[0][0] == "되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 PC와 다시 합쳐져요.", "restore toast text")
	_end(h)
	var e2 := FakeEngine.new()
	var h2 := _mk("pc", e2)
	_toasts.clear()
	(h2["m"] as SyncManager).restore("x")
	ok(_toasts.size() == 1 and _toasts[0][0] == "되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 폰과 다시 합쳐져요.", "PC restore toast says 폰")
	_end(h2)


func _fake_ports(cnt: Dictionary, state_path: String) -> SyncPorts:
	var p := SyncPorts.new()
	p.state_path = state_path
	p.backup_root = DIR.path_join("backup")
	p.device_kind = "phone"
	p.device_name = "시험 폰"
	p.now_unix = func() -> int: return 1760000000
	p.today_days = func() -> int: return 20000
	p.load_local = func() -> Dictionary:
		return {"progress": Progress.blank(), "studylog": {}, "prefs": {}}
	p.apply_local = func(_a: Dictionary, _b: Dictionary, _c: Dictionary) -> bool: return true
	p.local_paths = func() -> Dictionary: return {}
	p.is_read_only = func() -> bool: return false
	p.http_get = func(path: String, _t: float) -> Dictionary:
		cnt["get"] += 1
		(cnt["paths"] as Array).append(path)
		return {"ok": false, "code": 0, "err_code": "transport", "error": "x"}
	p.http_post = func(path: String, _b: Dictionary, _t: float) -> Dictionary:
		cnt["post"] += 1
		(cnt["paths"] as Array).append(path)
		return {"ok": false, "code": 0, "err_code": "transport", "error": "x"}
	p.is_busy_ui = func() -> bool: return false
	return p


func _t_real_engine_undecided() -> void:
	print("[real SyncEngine, fake ports: undecided = zero /sync requests]")
	var cnt := {"get": 0, "post": 0, "paths": []}
	var sp: String = DIR.path_join("undecided_state.json")
	var eng := SyncEngine.new(_fake_ports(cnt, sp))
	var m := SyncManager.new()
	m.engine = eng
	m.kind = "phone"
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = false
	var up := {"v": false}
	m.is_backend_ready = func() -> bool: return bool(up["v"])
	add_child(m)
	up["v"] = true
	m.backend_changed()
	for i in 3600:
		m.advance(1.0)
		if i % 300 == 0:
			m.on_app_paused()
			m.on_app_resumed()
			m.request_sync("change")
			m.request_sync("poll")
			m.request_sync("pause")
	ok(cnt["get"] == 0 and cnt["post"] == 0, "phone, undecided, 1 h with READY: 0 GET / 0 POST (get=%d post=%d)" % [cnt["get"], cnt["post"]])
	ok(not FileAccess.file_exists(sp), "no sidecar was written before the choice")
	m.sync_manual()
	ok(cnt["get"] == 0, "the manual button path is also silent before the choice")
	# separate: still silent, the file says so, and a second engine/manager never asks again
	var r: Dictionary = await m.choose("separate")
	ok(bool(r["ok"]) and cnt["get"] == 0 and cnt["post"] == 0, "choose('separate') sends nothing")
	remove_child(m)
	m.free()
	var cnt2 := {"get": 0, "post": 0, "paths": []}
	var eng2 := SyncEngine.new(_fake_ports(cnt2, sp))
	var m2 := SyncManager.new()
	m2.engine = eng2
	m2.kind = "phone"
	m2.connect_backend = false
	m2.auto_process = false
	m2.auto_dialog = false
	var asked: Array = []
	m2.choice_needed.connect(func(k: String) -> void: asked.append(k))
	m2.is_backend_ready = func() -> bool: return true
	add_child(m2)
	for i in 1800:
		m2.advance(1.0)
	ok(asked.is_empty() and not eng2.needs_choice(), "after 'separate' a restarted app does not ask again")
	ok(cnt2["get"] == 0 and cnt2["post"] == 0, "separate (restarted): 0 requests in 30 min")
	remove_child(m2)
	m2.free()
	# PC: the probe is the only request that is allowed
	var cnt3 := {"get": 0, "post": 0, "paths": []}
	var pp: SyncPorts = _fake_ports(cnt3, DIR.path_join("pc_state.json"))
	pp.device_kind = "pc"
	var m3 := SyncManager.new()
	m3.engine = SyncEngine.new(pp)
	m3.kind = "pc"
	m3.connect_backend = false
	m3.auto_process = false
	m3.auto_dialog = false
	m3.is_backend_ready = func() -> bool: return true
	add_child(m3)
	for i in 300:
		m3.advance(1.0)
	var only_probe: bool = true
	for pth in (cnt3["paths"] as Array):
		if not str(pth).begins_with("/sync/pull?device_id=0000000000000000"):
			only_probe = false
	ok(cnt3["get"] == 5 and cnt3["post"] == 0 and only_probe, "PC undecided: only read-only probes (5 in 300 s), no POST (get=%d post=%d)" % [cnt3["get"], cnt3["post"]])
	ok(not FileAccess.file_exists(DIR.path_join("pc_state.json")), "the probe wrote no sidecar")
	remove_child(m3)
	m3.free()


func _t_real_engine_before_ready() -> void:
	print("[real SyncEngine: nothing before the first READY, then the start sync after 3 s]")
	var cnt := {"get": 0, "post": 0, "paths": []}
	var sp: String = DIR.path_join("decided_state.json")
	var st: Dictionary = SyncState.blank()
	st["choice"] = "merge"
	st["enabled"] = true
	st["device_id"] = "0123456789abcdef"
	ok(SyncState.save_file(sp, st), "test sidecar written (choice merge, switch on)")
	var m := SyncManager.new()
	m.engine = SyncEngine.new(_fake_ports(cnt, sp))
	m.kind = "phone"
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = false
	var up := {"v": false}
	m.is_backend_ready = func() -> bool: return bool(up["v"])
	add_child(m)
	for i in 600:
		m.advance(1.0)
	ok(cnt["get"] == 0 and cnt["post"] == 0, "switch on but READY never came: 0 requests in 10 min")
	up["v"] = true
	m.backend_changed()
	for i in 29:
		m.advance(0.1)
	ok(cnt["get"] == 0, "READY + 2.9 s: still nothing")
	m.advance(0.2)
	ok(cnt["get"] == 1 and str(cnt["paths"][0]).begins_with("/sync/pull?device_id=0123456789abcdef"), "READY + 3 s: the start round sends its pull (%s)" % str(cnt["paths"]))
	ok(m.failure_count() == 1 and str(m.last_result.get("code", "")) == "unreachable", "the transport failure is reported as 'unreachable' and counted once")
	remove_child(m)
	m.free()


func _t_reset_waits() -> void:
	print("[reset during a running round: unlink waits for the round]")
	var e := FakeEngine.new()
	var h := _mk("pc", e)
	var m: SyncManager = h["m"]
	_up(h)
	e.hold = true
	m.sync_manual()
	ok(m.is_busy() and e.calls == ["manual"], "a manual round is running (held)")
	var done := {"v": false}
	var f := func() -> void:
		await m.before_reset()
		done["v"] = true
	f.call()
	ok(e.unlink_calls == 0 and not done["v"], "before_reset waits: not unlinked while the round runs")
	m.request_sync("poll")
	m.request_sync("change")
	m.sync_manual()
	ok(e.calls.size() == 1, "no new round starts while the reset waits (%d)" % e.calls.size())
	e.hold = false
	e.released.emit()
	ok(done["v"] and e.unlink_calls == 1, "after the round ended: unlinked once, before_reset returned")
	ok(e.order == ["sync_end", "unlink"], "order: the round ended first, then unlink (%s)" % str(e.order))
	ok(e.calls.size() == 1, "no round is started by the end of the wait")
	# idle: no waiting at all
	await m.before_reset()
	ok(e.unlink_calls == 2, "idle: before_reset unlinks at once")
	_end(h)


## The scenario of the review: "지우기" while a round is on its way (pull in flight). The local record must stay empty
## and the hub's copy must not flow back in. Real SyncEngine, in-memory local files, fake HTTP that takes a few frames.
func _t_reset_e2e() -> void:
	print("[reset during a round, real engine: the record stays reset]")
	var store := {"progress": Progress.blank(), "studylog": {}, "prefs": {}}
	(store["progress"] as Dictionary)["checks"] = {"en-1-w0": true}
	var peer_doc: Dictionary = SyncDoc.blank_replica()
	(peer_doc["progress"] as Dictionary)["checks"] = {"add": {"en-2-w0": 1759999900}, "del": {}}
	var cnt := {"get": 0, "post": 0}
	var sp: String = DIR.path_join("reset_state.json")
	var st: Dictionary = SyncState.blank()
	st["choice"] = "merge"
	st["enabled"] = true
	st["device_id"] = "0123456789abcdef"
	SyncState.save_file(sp, st)
	var p := _fake_ports(cnt, sp)
	var paths := {}
	for nm in ["progress", "studylog", "prefs"]:
		var fpath: String = DIR.path_join("reset_%s.json" % nm)
		var fh := FileAccess.open(fpath, FileAccess.WRITE)
		fh.store_string("{}")
		fh.close()
		paths[nm] = fpath
	p.local_paths = func() -> Dictionary: return paths
	p.load_local = func() -> Dictionary: return (store as Dictionary).duplicate(true)
	p.apply_local = func(a: Dictionary, b: Dictionary, _c: Dictionary) -> bool:
		store["progress"] = a
		store["studylog"] = b
		return true
	p.http_get = func(_path: String, _t: float) -> Dictionary:
		cnt["get"] += 1
		for i in 4:
			await get_tree().process_frame
		return {"ok": true, "code": 200, "data": {"v": 1, "hub_id": "9c1e5a7b3d204f68", "hub_time": 1760000000, "rev": 1, "self": {"seq": 0},
			"replicas": [{"device_id": "fedcba9876543210", "name": "PC", "kind": "pc", "seq": 1, "saved_hub": 1759999950, "doc": peer_doc}]}}
	p.http_post = func(_path: String, _b: Dictionary, _t: float) -> Dictionary:
		cnt["post"] += 1
		await get_tree().process_frame
		return {"ok": true, "code": 200, "data": {"ok": true, "rev": 2}}
	var m := SyncManager.new()
	m.engine = SyncEngine.new(p)
	m.kind = "pc"
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = false
	m.is_backend_ready = func() -> bool: return true
	add_child(m)
	m.sync_manual()
	ok(m.is_busy() and cnt["get"] == 1, "the round is on its way (pull in flight)")
	await m.before_reset()
	var checks_after_wait: Dictionary = (store["progress"] as Dictionary)["checks"]
	ok(not m.is_busy(), "before_reset returned after the round ended")
	ok(checks_after_wait.has("en-2-w0"), "the waited round finished and applied its merge (it is wiped by the reset below)")
	# what Store.reset_progress() does, right after before_reset() returned
	store["progress"] = Progress.blank()
	store["studylog"] = {}
	var gets: int = cnt["get"]
	var posts: int = cnt["post"]
	for i in 8:
		m.advance(1.0)
		await get_tree().process_frame
	for i in 600:
		m.advance(1.0)
	await get_tree().process_frame
	ok(((store["progress"] as Dictionary)["checks"] as Dictionary).is_empty(), "4+ s later the record is still empty (nothing flowed back from the hub)")
	ok(cnt["get"] == gets and cnt["post"] == posts, "no request after the reset (get %d->%d, post %d->%d)" % [gets, cnt["get"], posts, cnt["post"]])
	var s2: Dictionary = m.engine.status()
	ok(not bool(s2["enabled"]) and str(s2["device_id"]) == "", "the engine is unlinked (switch off, device id forgotten)")
	remove_child(m)
	m.free()


func _t_static_texts() -> void:
	print("[error texts are the §6.3 sentences]")
	var table := {
		"unreachable": "PC에 닿지 않아요. 연결되면 자동으로 동기화해요.",
		"not_connected": "PC에 연결되지 않았어요.",
		"old_pc": "이 PC의 회화 연습이 기록 동기화를 지원하지 않아요. PC 앱을 1.2 이상으로 업데이트해 주세요.",
		"hub_changed": "다른 PC에 연결돼 있어요. 아래 '이 PC와 새로 합치기'를 눌러 주세요.",
		"state_lost": "동기화 상태 파일이 손상됐어요. '이전 상태로 되돌리기'로 복원하거나 '새로 합치기'를 눌러 주세요. (기록이 겹쳐 셀 수 있어요)",
		"merge_check_failed": "합친 결과를 확인하지 못해서 이 기기의 기록은 그대로 뒀어요. 다시 시도하거나 앱을 업데이트해 주세요.",
		"local_read_only": "이 기기의 기록 파일을 읽지 못해서 동기화를 쉬어요.",
		"disk": "기록을 저장하지 못했어요. 저장 공간을 확인해 주세요.",
		"server_rejected": "PC가 기록 형식을 받아들이지 않았어요. 두 기기의 앱 버전을 확인해 주세요.",
		"too_large": "기록이 너무 커서 보내지 못했어요.",
		"bad_reply": "PC가 보낸 답을 이해하지 못했어요.",
	}
	var bad := 0
	for code in table.keys():
		if SyncPanel.error_text({"code": code, "error": ""}) != table[code]:
			bad += 1
			print("    mismatch for ", code)
	ok(bad == 0, "error_text(code) == §6.3 sentence for all %d codes" % table.size())
	ok(SyncPanel.error_text({"code": "ok"}) == "" and SyncPanel.error_text({"code": "disabled"}) == "" and SyncPanel.error_text({"code": "busy"}) == "",
		"ok / disabled / busy are not errors (empty text)")
	var extra := {
		"in_progress": "동기화 중이에요. 잠시 뒤 다시 해 주세요.",
		"bad_choice": "선택을 확인하지 못했어요. 다시 골라 주세요.",
		"forbidden_replica": "이 기기의 기록은 이 휴대폰에서 바꿀 수 없어요.",
		"seq_jump": "보낸 번호가 저장된 번호보다 너무 많이 앞서 있어요.",
		"sync_off": "이 PC에서는 기록 동기화를 쓸 수 없어요.",
		"hub_store_failed": "PC에 기록을 저장하지 못했어요.",
	}
	var bad_extra := 0
	for code in extra.keys():
		if SyncPanel.error_text({"code": code, "error": ""}) != extra[code]:
			bad_extra += 1
			print("    mismatch for ", code)
	ok(bad_extra == 0, "the extra codes (in_progress, bad_choice, forbidden_replica, seq_jump, sync_off, hub_store_failed) have their Korean sentences")
	ok(SyncPanel.error_text({"code": "never_heard_of_it", "error": ""}) == SyncPanel.GENERIC_ERROR, "an unknown code gets the generic sentence, never an empty line")
	ok(SyncPanel.error_text({"code": "unreachable", "error": "AI 엔진에 연결하지 못했어요. 연결되면 자동으로 동기화해요."}) == "AI 엔진에 연결하지 못했어요. 연결되면 자동으로 동기화해요.",
		"the engine's own text (PC variant) wins when it is given")
