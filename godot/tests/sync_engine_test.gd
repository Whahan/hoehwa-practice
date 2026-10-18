extends Node
## S4 engine unit tests (docs/sync_design.md 10.7, 엔진 단위 시험). No network: a fake hub (in memory) answers the ports.
## Run:  godot --headless --path <godot> res://tests/sync_engine_test.tscn   (with HOEHWA_SYNC_TEST_ROOT set, see run_sync_tests.ps1)
## Every check prints "PASS  [ID] label" or "FAIL  [ID] label". A check that could not run prints "SKIP  [ID] reason".
## Last line: "== sync_engine result: N passed, M failed ==". Exit 0 = all passed.
## All data lives under user://test_s4/engine/ .

const ROOT := "user://test_s4/engine"
const ISO := "2026-10-17"
const LANG := "en"
const PROBE_ID := "0000000000000000"

var passed: int = 0
var failed: int = 0
var skipped: int = 0


# ---------------------------------------------------------------- fake hub (in memory, same reply shapes as sync_hub.py)

class FakeHub:
	var hub_id: String = "9c1e5a7b3d204f68"
	var rev: int = 0
	var reps: Dictionary = {} # device_id -> {device_id, name, kind, seq, saved_hub, doc}
	var hub_offset: int = 0   # hub clock minus real clock (seconds)
	var down: bool = false    # every request: transport error (phone out of reach)
	var pull_404: bool = false
	var requests: int = 0

	func hub_time() -> int:
		return int(Time.get_unix_time_from_system()) + hub_offset

	func seq_of(dev: String) -> int:
		return int(reps[dev]["seq"]) if reps.has(dev) else 0

	func _query(path: String) -> Dictionary:
		var out: Dictionary = {}
		if not path.contains("?"):
			return out
		for kv in path.split("?")[1].split("&"):
			var parts: PackedStringArray = kv.split("=")
			if parts.size() == 2:
				out[parts[0]] = parts[1]
		return out

	func get_reply(path: String) -> Dictionary:
		requests += 1
		if down:
			return {"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "x", "cancelled": false, "err_code": "transport", "err_body": null}
		if pull_404:
			return {"ok": false, "code": 404, "data": null, "bytes": PackedByteArray(), "error": "x", "cancelled": false, "err_code": "", "err_body": null}
		var q: Dictionary = _query(path)
		var dev: String = str(q.get("device_id", ""))
		if q.has("rev") and int(q["rev"]) == rev:
			return _ok({"v": 1, "unchanged": true, "hub_id": hub_id, "hub_time": hub_time(), "rev": rev, "self": {"seq": seq_of(dev)}})
		var peers: Array = []
		for k in reps.keys():
			if k == dev:
				continue
			var r: Dictionary = reps[k]
			peers.append({"device_id": k, "name": r["name"], "kind": r["kind"], "seq": r["seq"], "saved_hub": r["saved_hub"], "doc": (r["doc"] as Dictionary).duplicate(true)})
		return _ok({"v": 1, "hub_id": hub_id, "hub_time": hub_time(), "rev": rev, "self": {"seq": seq_of(dev)}, "replicas": peers, "warnings": []})

	func post_reply(path: String, body: Dictionary) -> Dictionary:
		requests += 1
		if down:
			return {"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "x", "cancelled": false, "err_code": "transport", "err_body": null}
		var dev: String = str(body["device_id"])
		var seq: int = int(body["seq"])
		if reps.has(dev):
			var stored: int = int(reps[dev]["seq"])
			if seq < stored:
				return _err(409, "stale_seq", {"stored_seq": stored})
			if seq == stored:
				var same: bool = SyncMerge.canonical([reps[dev]["name"], reps[dev]["kind"], reps[dev]["doc"]]) == SyncMerge.canonical([body["name"], body["kind"], body["doc"]])
				if not same:
					return _err(409, "seq_reuse", {"stored_seq": stored})
				return _ok({"ok": true, "dup": true, "rev": rev, "hub_time": hub_time(), "stored_seq": stored, "hub_id": hub_id})
		reps[dev] = {"device_id": dev, "name": body["name"], "kind": body["kind"], "seq": seq, "saved_hub": hub_time(), "doc": (body["doc"] as Dictionary).duplicate(true)}
		rev += 1
		return _ok({"ok": true, "dup": false, "rev": rev, "hub_time": hub_time(), "stored_seq": seq, "hub_id": hub_id})

	func _ok(data: Dictionary) -> Dictionary:
		return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false, "err_code": "", "err_body": null}

	func _err(code: int, ec: String, body: Dictionary) -> Dictionary:
		return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": ec, "cancelled": false, "err_code": ec, "err_body": body}


# ---------------------------------------------------------------- one fake device

class Dev:
	var name: String = ""
	var dir: String = ""
	var progress: Dictionary = {}
	var studylog: Dictionary = {}
	var prefs: Dictionary = {}
	var clock_off: int = 0
	var reqs: int = 0          # requests this device sent through its ports
	var applies: int = 0
	var fail_mode: String = "" # "" | "before" (no write, false) | "after_progress" (progress written, studylog not)
	var ro: bool = false
	var busy: bool = false
	var slow: bool = false     # true: each GET waits 0.1 s before the hub answers (a round is in progress meanwhile)
	var hub: FakeHub = null
	var ports: SyncPorts = null
	var engine: SyncEngine = null


var _uniq: int = 0


func ok(id: String, cond: bool, label: String) -> void:
	if cond:
		passed += 1
		print("  PASS  [%s] %s" % [id, label])
	else:
		failed += 1
		print("  FAIL  [%s] %s" % [id, label])


func skip(id: String, label: String) -> void:
	skipped += 1
	print("  SKIP  [%s] %s" % [id, label])


func _ready() -> void:
	print("== sync_engine test start ==")
	var want: String = OS.get_environment("HOEHWA_SYNC_TEST_ROOT").replace("\\", "/")
	var have: String = OS.get_user_data_dir().replace("\\", "/")
	if want == "" or not have.begins_with(want):
		print("GUARD: HOEHWA_SYNC_TEST_ROOT is not set or the user data folder is outside it; nothing written")
		get_tree().quit(2)
		return
	SyncBackup.remove_dir(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	SyncMerge.test_corrupt = Callable()
	await t_backup()
	await t_cap_base()
	await t_journal()
	await t_read_only_busy()
	await t_clock()
	await t_check_guard()
	await t_hub_identity()
	await t_restore()
	await t_choice_and_switch()
	await t_manager()
	await t_unlink()
	await t_regress()
	SyncMerge.test_corrupt = Callable()
	SyncBackup.remove_dir(ROOT)
	if skipped > 0:
		print("UNVERIFIED (SKIP): %d item(s) need a part that is not in S4 scope yet, see the SKIP lines" % skipped)
	print("== sync_engine result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _dir(tag: String) -> String:
	_uniq += 1
	return "%s/%s_%d" % [ROOT, tag, _uniq]


func make_dev(tag: String, kind: String, hub: FakeHub) -> Dev:
	var d := Dev.new()
	d.name = tag
	d.dir = _dir(tag)
	d.hub = hub
	SyncBackup.remove_dir(d.dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d.dir))
	d.progress = Progress.blank()
	d.studylog = StudyLog._blank()
	d.prefs = Store.DEFAULT_PREFS.duplicate(true)
	var p := SyncPorts.new()
	p.state_path = d.dir + "/sync_state.json"
	p.backup_root = d.dir + "/sync_backup"
	p.device_name = tag
	p.device_kind = kind
	p.now_unix = func() -> int:
		return int(Time.get_unix_time_from_system()) + d.clock_off
	p.today_days = func() -> int:
		return Plan.days_from_civil(2026, 10, 17)
	p.load_local = func() -> Dictionary:
		return {"progress": d.progress.duplicate(true), "studylog": d.studylog.duplicate(true), "prefs": d.prefs.duplicate(true)}
	p.apply_local = func(pg: Dictionary, sl: Dictionary, pc: Dictionary) -> bool:
		d.applies += 1
		if d.fail_mode == "before":
			return false
		d.progress = Progress.normalize(pg)
		save_progress(d)
		if d.fail_mode == "after_progress":
			return false
		var cand: Dictionary = d.studylog.duplicate(true)
		for k in ["days", "phon", "missions"]:
			cand[k] = (sl[k] as Dictionary).duplicate(true)
		d.studylog = StudyLog._normalize(cand)
		for k in pc.keys():
			d.prefs[k] = pc[k]
		save_studylog(d)
		save_prefs(d)
		return true
	p.local_paths = func() -> Dictionary:
		return {"progress": d.dir + "/progress.json", "studylog": d.dir + "/studylog.json", "prefs": d.dir + "/prefs.json"}
	p.is_read_only = func() -> bool:
		return d.ro
	p.is_busy_ui = func() -> bool:
		return d.busy
	p.http_get = func(path: String, _timeout: float) -> Dictionary:
		d.reqs += 1
		if d.slow:
			await get_tree().create_timer(0.1).timeout
		return d.hub.get_reply(path)
	p.http_post = func(path: String, body: Dictionary, _timeout: float) -> Dictionary:
		d.reqs += 1
		return d.hub.post_reply(path, body)
	p.reload_local = func() -> void:
		d.progress = Progress.load_file(d.dir + "/progress.json")
		var js := JSON.new()
		if js.parse(FileAccess.get_file_as_string(d.dir + "/studylog.json")) == OK and js.data is Dictionary:
			d.studylog = StudyLog._normalize(js.data)
	d.ports = p
	d.engine = SyncEngine.new(p)
	d.engine.backup_min_gap = 0
	save_all(d)
	return d


func engine_of(d: Dev) -> SyncEngine:
	## a new engine on the same files = the app restarted
	d.engine = SyncEngine.new(d.ports)
	d.engine.backup_min_gap = 0
	return d.engine


func save_progress(d: Dev) -> void:
	Progress.save_file(d.dir + "/progress.json", d.progress)


func save_studylog(d: Dev) -> void:
	Progress.write_text_atomic(d.dir + "/studylog.json", JSON.stringify(d.studylog))


func save_prefs(d: Dev) -> void:
	Progress.write_text_atomic(d.dir + "/prefs.json", JSON.stringify(d.prefs))


func save_all(d: Dev) -> void:
	save_progress(d)
	save_studylog(d)
	save_prefs(d)


func add_sec(d: Dev, sec: int) -> void:
	var days: Dictionary = d.studylog["days"]
	if not days.has(ISO):
		days[ISO] = {}
	var per: Dictionary = days[ISO]
	if not per.has(LANG):
		per[LANG] = StudyLog._norm_rec({})
	per[LANG]["sec"] = int(per[LANG]["sec"]) + sec
	per[LANG]["by"]["lesson"] = int(per[LANG]["by"].get("lesson", 0)) + sec
	save_studylog(d)


func sec_of(d: Dev) -> int:
	var days: Dictionary = d.studylog["days"]
	if days.has(ISO) and (days[ISO] as Dictionary).has(LANG):
		return int(days[ISO][LANG]["sec"])
	return 0


func add_xp(d: Dev, n: int) -> void:
	d.progress["xp"][LANG] = int(d.progress["xp"][LANG]) + n
	save_progress(d)


func xp_of(d: Dev) -> int:
	return int(d.progress["xp"][LANG])


func add_card(d: Dev, target: String, reps: int = 0, last_review: int = 0) -> void:
	var it := {"id": Progress.new_id(), "lang": LANG, "target": target, "reading": "", "ko": "", "note": ""}
	it.merge(FSRS.new_card(int(Time.get_unix_time_from_system())))
	if reps > 0:
		it["reps"] = reps
		it["state"] = 2
		it["stability"] = 3.0
		it["difficulty"] = 5.0
		it["last_review"] = last_review if last_review > 0 else int(Time.get_unix_time_from_system()) - 100
	(d.progress["review"] as Array).append(it)
	save_progress(d)


func del_card(d: Dev, target: String) -> void:
	var keep: Array = []
	for c in d.progress["review"]:
		if c["target"] != target:
			keep.append(c)
	d.progress["review"] = keep
	save_progress(d)


func has_card(d: Dev, target: String) -> bool:
	for c in d.progress["review"]:
		if c["target"] == target:
			return true
	return false


func card_of(d: Dev, target: String) -> Dictionary:
	for c in d.progress["review"]:
		if c["target"] == target:
			return c
	return {}


func card_targets(d: Dev) -> Array:
	var out: Array = []
	for c in d.progress["review"]:
		out.append(str(c["target"]))
	out.sort()
	return out


func set_check(d: Dev, key: String, on: bool) -> void:
	if on:
		d.progress["checks"][key] = true
	else:
		(d.progress["checks"] as Dictionary).erase(key)
	save_progress(d)


func has_check(d: Dev, key: String) -> bool:
	return bool((d.progress["checks"] as Dictionary).get(key, false))


func md5(path: String) -> String:
	return FileAccess.get_md5(path) if FileAccess.file_exists(path) else ""


func files_md5(d: Dev) -> String:
	return md5(d.dir + "/progress.json") + "|" + md5(d.dir + "/studylog.json") + "|" + md5(d.dir + "/prefs.json")


func sidecar_text(d: Dev) -> String:
	return FileAccess.get_file_as_string(d.ports.state_path) if FileAccess.file_exists(d.ports.state_path) else ""


func sidecar(d: Dev) -> Dictionary:
	var js := JSON.new()
	if js.parse(sidecar_text(d)) != OK or not (js.data is Dictionary):
		return {}
	return js.data


func reasons(d: Dev) -> Array:
	var out: Array = []
	for b in d.engine.list_backups():
		out.append(b["reason"])
	return out


func count_reason(d: Dev, reason: String) -> int:
	var n: int = 0
	for r in reasons(d):
		if r == reason:
			n += 1
	return n


func join(d: Dev) -> Dictionary:
	return await d.engine.set_choice("merge")


# ---------------------------------------------------------------- E-U: backup, retention, copy failure

func t_backup() -> void:
	print("[backup and retention]")
	var hub := FakeHub.new()
	var d: Dev = make_dev("u_a", "pc", hub)
	add_card(d, "A", 2)
	add_sec(d, 100)
	var before_md5: String = md5(d.dir + "/progress.json")
	var r: Dictionary = await join(d)
	ok("E-U1", r["ok"] and count_reason(d, "first") == 1, "first join makes one 'first' backup (%s)" % r["code"])
	var bl: Array = d.engine.list_backups()
	var good: bool = bl.size() == 1
	if good:
		var bk: String = d.dir + "/sync_backup/" + str(bl[0]["name"])
		good = str(bl[0]["md5"].get("progress.json", "")) == before_md5 and FileAccess.get_md5(bk + "/progress.json") == before_md5
		var v: Dictionary = SyncBackup.verify(d.ports.backup_root, str(bl[0]["name"]))
		good = good and bool(v["ok"])
		for fn in (bl[0]["md5"] as Dictionary).keys():
			good = good and FileAccess.get_md5(bk + "/" + str(fn)) == str((bl[0]["md5"] as Dictionary)[fn])
	ok("E-U1", good, "backup holds the pre-merge files; meta md5 == real md5 of every file")

	# E-U2: 12 automatic applications (a peer's change is applied to d each time; backup_min_gap = 0 releases the throttle)
	# -> first + newest 10 = 11 backups. (A device's own change is only pushed, not applied, so it makes no backup.)
	var peer_u: Dev = make_dev("u_pu", "pc", hub)
	await join(peer_u)
	var applied_n: int = 0
	for i in 12:
		add_sec(peer_u, 1)
		await peer_u.engine.sync_now("change")
		var rr: Dictionary = await d.engine.sync_now("change")
		if rr["applied"]:
			applied_n += 1
	ok("E-U2", applied_n == 12, "12 rounds that apply a peer change (applied %d)" % applied_n)
	var total: int = d.engine.list_backups().size()
	ok("E-U2", total == 11 and count_reason(d, "first") == 1 and count_reason(d, "auto") == 10,
		"12 applications keep first + newest 10 = 11 (total %d, first %d, auto %d)" % [total, count_reason(d, "first"), count_reason(d, "auto")])

	# E-U3: backup folder cannot be made -> code disk, local untouched, nothing pushed
	var d3: Dev = make_dev("u_c", "pc", hub)
	add_card(d3, "C1", 1)
	add_sec(d3, 40)
	var blocker: String = d3.dir + "/blocker.txt"
	var fb: FileAccess = FileAccess.open(blocker, FileAccess.WRITE)
	fb.store_string("x")
	fb.close()
	d3.ports.backup_root = blocker + "/backup"
	var md5_before: String = files_md5(d3)
	var rf: Dictionary = await join(d3)
	ok("E-U3", rf["code"] == "disk" and not rf["ok"], "backup copy failure -> code disk (%s)" % rf["code"])
	ok("E-U3", files_md5(d3) == md5_before, "backup copy failure: local files unchanged (md5)")
	ok("E-U3", not _hub_has_name(hub, "u_c"), "backup copy failure: nothing pushed to the hub")
	d3.ports.backup_root = d3.dir + "/sync_backup"
	var rg: Dictionary = await d3.engine.sync_now("manual")
	ok("E-U3", rg["ok"] and count_reason(d3, "first") == 1, "after the folder works again the same device joins (%s)" % rg["code"])


func _hub_has_name(hub: FakeHub, name: String) -> bool:
	for k in hub.reps.keys():
		if str(hub.reps[k]["name"]) == name:
			return true
	return false


# ---------------------------------------------------------------- E-U4: base is taken from the files after the apply (caps)

func t_cap_base() -> void:
	print("[base after a capped apply]")
	var hub := FakeHub.new()
	var a: Dev = make_dev("cap_a", "pc", hub)
	add_sec(a, 50000)
	await join(a)
	var b: Dev = make_dev("cap_b", "phone", hub)
	add_sec(b, 50000)
	await join(b)
	await a.engine.sync_now("poll")
	# the day holds at most 86400 s: the 100000 s merged result is cut when it is written
	ok("E-U4", sec_of(b) == 86400 and sec_of(a) == 86400, "the merged 100000 s is capped to 86400 on both (%d, %d)" % [sec_of(a), sec_of(b)])
	var nb0: int = count_reason(b, "auto")
	var rb: Dictionary = await b.engine.sync_now("poll")
	var ra: Dictionary = await a.engine.sync_now("poll")
	ok("E-U4", rb["ok"] and not rb["applied"] and not rb["pushed"] and ra["ok"] and not ra["applied"],
		"next rounds after the cap change nothing (applied %s / %s, pushed %s)" % [str(rb["applied"]), str(ra["applied"]), str(rb["pushed"])])
	ok("E-U4", count_reason(b, "auto") == nb0 and sec_of(b) == 86400, "no extra backup and no drift after the cap (sec %d)" % sec_of(b))


# ---------------------------------------------------------------- E-J: journal (crash in the middle of an apply)

func t_journal() -> void:
	print("[journal]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("j_pc", "pc", hub)
	var d: Dev = make_dev("j_ph", "phone", hub)
	add_sec(peer, 200)
	add_card(peer, "P1", 1)
	await join(peer)
	add_card(d, "D1", 1)
	add_sec(d, 100)
	await join(d)
	# the peer adds 30 s; the phone's apply then dies before it writes anything
	add_sec(peer, 30)
	await peer.engine.sync_now("change")
	d.fail_mode = "before"
	var r1: Dictionary = await d.engine.sync_now("poll")
	ok("E-J1", r1["code"] == "disk" and sec_of(d) == 300 and not r1["ok"], "apply dies before writing -> disk, local still 300 s (%s, %d)" % [r1["code"], sec_of(d)])
	ok("E-J1", sidecar(d).get("pending", null) != null, "the journal (pending) is kept in the sidecar")
	d.fail_mode = ""
	engine_of(d)
	var r2: Dictionary = await d.engine.sync_now("start")
	ok("E-J1", r2["ok"] and sec_of(d) == 330 and sidecar(d).get("pending", null) == null, "new app instance finishes the journal: 330 s, no pending (%s, %d)" % [r2["code"], sec_of(d)])
	var md5_a: String = files_md5(d)
	var r3: Dictionary = await d.engine.sync_now("poll")
	ok("E-J1", r3["ok"] and not r3["applied"] and files_md5(d) == md5_a and sec_of(d) == 330, "applying the journal again changes nothing")

	# E-J2: progress written, studylog write failed -> disk, pending stays; next round completes
	var hub_j2 := FakeHub.new()
	var peer2: Dev = make_dev("j2_pc", "pc", hub_j2)
	var e: Dev = make_dev("j2_ph", "phone", hub_j2)
	add_xp(e, 10)
	add_sec(e, 50)
	await join(e)
	await join(peer2)
	add_xp(peer2, 7)
	add_sec(peer2, 25)
	await peer2.engine.sync_now("change")
	e.fail_mode = "after_progress"
	var r4: Dictionary = await e.engine.sync_now("change")
	ok("E-J2", r4["code"] == "disk", "progress written, studylog not -> disk (%s)" % r4["code"])
	ok("E-J2", sidecar(e).get("pending", null) != null, "pending stays after the partial write")
	e.fail_mode = ""
	engine_of(e)
	var r5: Dictionary = await e.engine.sync_now("change")
	ok("E-J2", r5["ok"] and xp_of(e) == 17 and sec_of(e) == 75 and sidecar(e).get("pending", null) == null,
		"next round completes both files: xp 17, sec 75 (%s, %d, %d)" % [r5["code"], xp_of(e), sec_of(e)])

	# E-J3: sidecar broken ('{' only) with no .prev -> state_lost, no request, file moved to .bad
	var f: Dev = make_dev("j3_ph", "phone", hub)
	add_sec(f, 90)
	await join(f)
	var sc: String = f.ports.state_path
	var fw: FileAccess = FileAccess.open(sc, FileAccess.WRITE)
	fw.store_string("{")
	fw.close()
	if FileAccess.file_exists(sc + ".prev"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sc + ".prev"))
	engine_of(f)
	var reqs_before: int = f.reqs
	var md5_f: String = files_md5(f)
	var r6: Dictionary = await f.engine.sync_now("start")
	ok("E-J3", r6["code"] == "state_lost" and not r6["ok"], "broken sidecar -> state_lost (%s)" % r6["code"])
	ok("E-J3", f.reqs == reqs_before, "broken sidecar: no request was sent")
	ok("E-J3", FileAccess.file_exists(sc + ".bad") and not FileAccess.file_exists(sc), "broken sidecar is quarantined as .bad")
	ok("E-J3", files_md5(f) == md5_f, "broken sidecar: local records unchanged")


# ---------------------------------------------------------------- E-R: read-only and busy

func t_read_only_busy() -> void:
	print("[read-only and recording]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("r_pc", "pc", hub)
	var d: Dev = make_dev("r_ph", "phone", hub)
	add_sec(d, 60)
	await join(d)
	await join(peer)
	d.ro = true
	add_sec(d, 25)
	var reqs0: int = d.reqs
	var md5_r: String = files_md5(d)
	var rr: Dictionary = await d.engine.sync_now("change")
	ok("E-R1", rr["code"] == "local_read_only" and not rr["ok"], "read-only record -> local_read_only (%s)" % rr["code"])
	ok("E-R1", d.reqs == reqs0 and files_md5(d) == md5_r, "read-only: no request and no file written")
	d.ro = false

	add_sec(peer, 30)
	await peer.engine.sync_now("change")
	d.busy = true
	var rb: Dictionary = await d.engine.sync_now("poll")
	ok("E-R2", rb["code"] == "busy" and not rb["applied"] and sec_of(d) == 85, "recording: merge postponed (code %s, applied %s, sec %d)" % [rb["code"], str(rb["applied"]), sec_of(d)])
	d.busy = false
	var rb2: Dictionary = await d.engine.sync_now("poll")
	ok("E-R2", rb2["ok"] and rb2["applied"] and sec_of(d) == 115, "after the recording the peer's 30 s arrives (sec %d)" % sec_of(d))


# ---------------------------------------------------------------- E-C: clock

func t_clock() -> void:
	print("[clock]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("c_pc", "pc", hub)
	var d: Dev = make_dev("c_ph", "phone", hub)
	d.clock_off = 7200
	add_card(d, "CK", 3, int(Time.get_unix_time_from_system()) + 7200 - 100)
	var orig_lr: int = int(card_of(d, "CK")["last_review"])
	add_sec(d, 10)
	var r: Dictionary = await join(d)
	ok("E-C1", r["ok"] and int(r["clock_off_sec"]) == -7200, "phone 2 h ahead: clock_off_sec == -7200 (%s)" % str(r["clock_off_sec"]))
	var warn: bool = false
	for w in r["warnings"]:
		if str(w).contains("시계"):
			warn = true
	ok("E-C1", warn, "a clock warning is given")
	var hub_card: Dictionary = {}
	var hub_doc: Dictionary = hub.reps[str(sidecar(d)["device_id"])]["doc"]
	for c in ((hub_doc["progress"] as Dictionary)["cards"] as Dictionary)["data"].values():
		if str((c as Dictionary).get("target", "")) == "CK":
			hub_card = c
	var on_hub: int = int(hub_card.get("last_review", -999999))
	ok("E-C1", absi(on_hub - (orig_lr - 7200)) <= 3, "card time is stored in hub time (%d vs %d)" % [on_hub, orig_lr - 7200])
	await join(peer)
	var rp: Dictionary = await peer.engine.sync_now("poll")
	var pc_lr: int = int(card_of(peer, "CK")["last_review"])
	ok("E-C1", rp["ok"] and absi(pc_lr - (orig_lr - 7200)) <= 3, "PC (clock right) reads the card in its own clock (%d)" % pc_lr)
	var back: Dictionary = await d.engine.sync_now("poll")
	var ph_lr: int = int(card_of(d, "CK")["last_review"])
	ok("E-C1", back["ok"] and absi(ph_lr - orig_lr) <= 3, "round trip: phone shows its own card time again (%d vs %d)" % [ph_lr, orig_lr])


# ---------------------------------------------------------------- E-C2: merge check refuses

func t_check_guard() -> void:
	print("[merge check]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("g_pc", "pc", hub)
	var d: Dev = make_dev("g_ph", "phone", hub)
	add_xp(d, 120)
	add_sec(d, 150)
	await join(d)
	await join(peer)
	add_sec(peer, 5)
	await peer.engine.sync_now("change")
	var sc_before: String = sidecar_text(d)
	var md5_before: String = files_md5(d)
	var backups_before: int = d.engine.list_backups().size()
	SyncMerge.test_corrupt = func(v: Dictionary) -> Dictionary:
		v["xp"]["en"] = 0
		return v
	var r: Dictionary = await d.engine.sync_now("change")
	SyncMerge.test_corrupt = Callable()
	ok("E-C2", r["code"] == "merge_check_failed" and not r["ok"], "shrinking result refused -> merge_check_failed (%s)" % r["code"])
	ok("E-C2", files_md5(d) == md5_before, "refused merge: local files unchanged (md5)")
	ok("E-C2", d.engine.list_backups().size() == backups_before, "refused merge: no backup made")
	ok("E-C2", sidecar_text(d) == sc_before, "refused merge: sidecar unchanged")
	var prob: String = FileAccess.get_file_as_string(d.dir + "/sync_last_problem.json") if FileAccess.file_exists(d.dir + "/sync_last_problem.json") else ""
	ok("E-C2", prob.contains("problems") and prob.contains("xp.en"), "problem file names the key only")
	var r2: Dictionary = await d.engine.sync_now("change")
	ok("E-C2", r2["ok"] and sec_of(d) == 155, "without the corruption the same round works (sec %d)" % sec_of(d))


# ---------------------------------------------------------------- E-H: hub identity

func t_hub_identity() -> void:
	print("[hub identity]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("h_pc", "pc", hub)
	var d: Dev = make_dev("h_ph", "phone", hub)
	add_sec(d, 12)
	await join(d)
	await join(peer)
	hub.hub_id = "aaaaaaaaaaaaaaaa"
	var md5_h: String = files_md5(d)
	var r1: Dictionary = await d.engine.sync_now("poll")
	ok("E-H1", r1["code"] == "hub_changed" and not r1["ok"], "new hub id while other copies exist -> hub_changed (%s)" % r1["code"])
	ok("E-H1", files_md5(d) == md5_h, "hub_changed: local unchanged")
	hub.reps.clear()
	hub.hub_id = "bbbbbbbbbbbbbbbb"
	var r2: Dictionary = await d.engine.sync_now("poll")
	ok("E-H2", r2["ok"] and r2["pushed"], "new hub id and an empty hub -> adopted, own copy uploaded (%s)" % r2["code"])
	ok("E-H2", str(sidecar(d).get("hub_id", "")) == "bbbbbbbbbbbbbbbb", "sidecar takes the new hub id")
	ok("E-H2", hub.reps.size() == 1 and _hub_has_name(hub, "h_ph") and sec_of(d) == 12, "the lone device's copy is on the hub again, record unchanged")


# ---------------------------------------------------------------- E-B: restore and re-join

func t_restore() -> void:
	print("[restore]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("b_pc", "pc", hub)
	var d: Dev = make_dev("b_ph", "phone", hub)
	add_sec(d, 300)
	add_card(d, "K1", 1)
	await join(d)
	add_sec(peer, 200)
	add_card(peer, "Q1", 1)
	await join(peer)
	await d.engine.sync_now("poll")
	# the phone adds 50 s, pushes it, and a card that it never deletes
	add_sec(d, 50)
	add_card(d, "NEW", 1)
	await d.engine.sync_now("change")
	var sec_before_restore: int = sec_of(d)
	var pre_own: String = SyncMerge.canonical(sidecar(d).get("own", {}))
	var names: Array = d.engine.list_backups()
	var first_name: String = ""
	for b in names:
		if b["reason"] == "first":
			first_name = str(b["name"])
	var rs: Dictionary = d.engine.restore_backup(first_name)
	ok("E-B1", rs["ok"], "restore_backup(first) ok (%s)" % rs["error"])
	var bk: String = d.dir + "/sync_backup/" + first_name
	var same: bool = true
	for fn in ["progress.json", "studylog.json", "prefs.json"]:
		var want: String = ""
		for b in names:
			if str(b["name"]) == first_name:
				want = str((b["md5"] as Dictionary).get(fn, ""))
		same = same and FileAccess.get_md5(d.dir + "/" + fn) == want and FileAccess.get_md5(bk + "/" + fn) == want
	ok("E-B1", same, "the three record files have the backup's md5")
	var sc: Dictionary = sidecar(d)
	ok("E-B1", not bool(sc.get("enabled", true)) and sc.get("rebase", null) != null, "sync switched off and rebase set in the sidecar")
	ok("E-B1", count_reason(d, "restore") == 1, "a 'restore' backup of the state before was made")
	ok("E-B1", SyncMerge.canonical(sc.get("own", {})) == pre_own, "sidecar own copy untouched by the restore")

	# E-B2: switch on again -> the items are back, counters are not counted twice
	d.engine.set_enabled(true)
	var rr: Dictionary = await d.engine.sync_now("manual")
	ok("E-B2", rr["ok"], "switch on after restore: round ok (%s)" % rr["code"])
	ok("E-B2", sec_of(d) == sec_before_restore, "counters: no double count, sec == before restore (%d vs %d)" % [sec_of(d), sec_before_restore])
	ok("E-B2", has_card(d, "K1") and has_card(d, "NEW") and has_card(d, "Q1"), "cards that were never deleted are back (K1, NEW, Q1)")


# ---------------------------------------------------------------- E-S, E-F: choice, switch, re-join, unlink

func t_choice_and_switch() -> void:
	print("[choice, switch, re-join]")
	var hub := FakeHub.new()

	# E-S1: switched off -> no request at all, local keeps growing, sidecar unchanged by refused rounds
	var pc1: Dev = make_dev("s1_pc", "pc", hub)
	var p1: Dev = make_dev("s1_ph", "phone", hub)
	add_sec(p1, 20)
	await join(p1)
	await join(pc1)
	p1.engine.set_enabled(false)
	var reqs1: int = p1.reqs
	var sc1: String = sidecar_text(p1)
	var all_disabled: bool = true
	for reason in ["manual", "poll", "change", "pause", "resume"]:
		var rr: Dictionary = await p1.engine.sync_now(reason)
		if rr["code"] != "disabled":
			all_disabled = false
	add_sec(p1, 3600)
	var rr2: Dictionary = await p1.engine.sync_now("manual")
	ok("E-S1", p1.reqs == reqs1 and all_disabled and rr2["code"] == "disabled", "switch off: every reason returns disabled, 0 requests (%d)" % (p1.reqs - reqs1))
	ok("E-S1", sidecar_text(p1) == sc1, "switch off: sidecar unchanged by the refused rounds")
	ok("E-S1", hub.reps.size() == 2, "switch off: the copy on the hub stays")

	# E-S2: fresh device -> asked, no request until chosen; choose merge (a) or separate (b); restart does not ask again
	var hub2 := FakeHub.new()
	var a: Dev = make_dev("s2a_ph", "phone", hub2)
	add_sec(a, 40)
	ok("E-S2", a.engine.needs_choice(), "fresh phone needs a choice")
	var ra: Dictionary = await a.engine.sync_now("start")
	ok("E-S2", ra["code"] == "disabled" and a.reqs == 0, "before the choice: disabled, 0 requests")
	var rm: Dictionary = await a.engine.set_choice("merge")
	ok("E-S2", rm["ok"] and rm["first"], "choose merge: first sync (%s)" % rm["code"])
	engine_of(a)
	ok("E-S2", not a.engine.needs_choice(), "(a) after restart: not asked again")
	var b: Dev = make_dev("s2b_ph", "phone", hub2)
	var rs2: Dictionary = await b.engine.set_choice("separate")
	ok("E-S2", rs2["ok"] and not b.engine.status()["enabled"] and b.reqs == 0, "(b) choose separate: switched off, 0 requests")
	engine_of(b)
	ok("E-S2", not b.engine.needs_choice() and b.engine.status()["choice"] == "separate", "(b) after restart: not asked again, still separate")
	var rb2: Dictionary = await b.engine.sync_now("poll")
	ok("E-S2", rb2["code"] == "disabled" and b.reqs == 0, "(b) rounds: 0 requests")

	# E-S3: separate, both sides keep their own records, then switch on -> union, counters exactly once
	var hub3 := FakeHub.new()
	var pc3: Dev = make_dev("s3_pc", "pc", hub3)
	var ph3: Dev = make_dev("s3_ph", "phone", hub3)
	add_card(pc3, "Y", 1)
	add_sec(pc3, 100)
	await join(pc3)
	await ph3.engine.set_choice("separate")
	add_card(ph3, "Z", 1)
	add_sec(ph3, 200)
	add_sec(pc3, 50)
	add_card(pc3, "W", 1)
	await pc3.engine.sync_now("change")
	ph3.engine.set_enabled(true)
	var r3: Dictionary = await ph3.engine.sync_now("manual")
	ok("E-S3", r3["ok"] and r3["applied"], "switch on after separate: plain first merge (%s)" % r3["code"])
	ok("E-S3", card_targets(ph3) == ["W", "Y", "Z"], "phone has the union of cards (%s)" % str(card_targets(ph3)))
	ok("E-S3", sec_of(ph3) == 350, "phone counters: 200 (own) + 150 (PC) once each (%d)" % sec_of(ph3))
	ok("E-S3", count_reason(ph3, "first") == 1, "backup 'first' exists")
	await pc3.engine.sync_now("poll")
	ok("E-S3", card_targets(pc3) == ["W", "Y", "Z"] and sec_of(pc3) == 350, "PC gets the phone's record too (sec %d)" % sec_of(pc3))

	# E-S4: merged, switched off, both sides change, switch on -> phone's +120 once, deleted card comes back, no loss
	var hub4 := FakeHub.new()
	var pc4: Dev = make_dev("s4_pc", "pc", hub4)
	var ph4: Dev = make_dev("s4_ph", "phone", hub4)
	add_sec(ph4, 100)
	add_card(ph4, "D", 1)
	await join(ph4)
	add_sec(pc4, 200)
	add_card(pc4, "E", 1)
	await join(pc4)
	await ph4.engine.sync_now("poll")
	# the hub stamps are whole seconds: a gap keeps the join's add strictly older than the re-join's delete (add >= del means present)
	await get_tree().create_timer(1.1).timeout
	ph4.engine.set_enabled(false)
	add_sec(ph4, 120)
	del_card(ph4, "D")
	set_check(ph4, "en-1-w9", true)
	add_sec(pc4, 60)
	add_card(pc4, "X", 1)
	ph4.engine.set_enabled(true)
	for i in 2:
		await ph4.engine.sync_now("manual")
		await pc4.engine.sync_now("manual")
	ok("E-S4", sec_of(ph4) == 480 and sec_of(pc4) == 480, "+120 (phone) and +60 (PC) counted once: 480 on both (%d, %d)" % [sec_of(ph4), sec_of(pc4)])
	ok("E-S4", card_targets(ph4) == ["D", "E", "X"] and card_targets(pc4) == ["D", "E", "X"],
		"the card deleted while off comes back, PC's new card arrives, nothing lost (%s / %s)" % [str(card_targets(ph4)), str(card_targets(pc4))])
	ok("E-S4", has_check(pc4, "en-1-w9"), "the phone's new check arrives on the PC")
	var sid_before: String = str(sidecar(ph4).get("device_id", ""))
	ph4.engine.set_enabled(false)
	ph4.engine.set_enabled(true)
	ok("E-S4", str(sidecar(ph4).get("device_id", "")) == sid_before and sid_before != "", "switch off and on keeps the same device id (no new id on re-join)")

	# E-S5: PC undecided probe: an empty hub -> 0, a phone copy on the hub -> 1, the probe writes no sidecar
	var hub5 := FakeHub.new()
	var pc5: Dev = make_dev("s5_pc", "pc", hub5)
	var n0: int = await pc5.engine.probe_peers()
	ok("E-S5", n0 == 0 and not FileAccess.file_exists(pc5.ports.state_path), "probe on an empty hub = 0 and no sidecar (%d)" % n0)
	var ph5: Dev = make_dev("s5_ph", "phone", hub5)
	add_sec(ph5, 5)
	await join(ph5)
	var n1: int = await pc5.engine.probe_peers()
	ok("E-S5", n1 == 1 and pc5.engine.needs_choice() and not FileAccess.file_exists(pc5.ports.state_path), "probe with a phone copy = 1, still undecided, no sidecar (%d)" % n1)



func t_unlink() -> void:
	print("[unlink]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("f_pc", "pc", hub)
	var d: Dev = make_dev("f_ph", "phone", hub)
	add_sec(d, 9)
	await join(d)
	await join(peer)
	var dev_id: String = str(sidecar(d).get("device_id", ""))
	d.engine.unlink_for_reset()
	var sc: Dictionary = sidecar(d)
	ok("E-F1", not bool(sc.get("enabled", true)), "unlink: switched off")
	ok("E-F1", (sc.get("own", {}) as Dictionary).is_empty() and (sc.get("base", {}) as Dictionary).is_empty() and str(sc.get("hub_id", "x")) == "" and str(sc.get("device_id", "x")) == "", "unlink: own, base, hub id and device id emptied")
	ok("E-F1", count_reason(d, "unlink") == 1, "unlink backup made")
	ok("E-F1", hub.reps.has(dev_id), "the copy on the hub stays")
	var rr: Dictionary = await d.engine.sync_now("manual")
	ok("E-F1", rr["code"] == "disabled" and d.reqs >= 0, "after unlink: sync is disabled")

# ---------------------------------------------------------------- E-S1 (timers), E-S6: SyncManager in virtual time (S7 API, no UI)

func _mgr(d: Dev, kind: String, ready: Array) -> SyncManager:
	var m := SyncManager.new()
	m.connect_backend = false
	m.auto_process = false
	m.auto_dialog = false
	m.kind = kind
	m.is_backend_ready = func() -> bool: return bool(ready[0])
	m.engine = d.engine
	add_child(m)
	return m


func _drop(m: SyncManager) -> void:
	remove_child(m)
	m.free()


func t_manager() -> void:
	print("[SyncManager timers and the choice signal]")
	# E-S1 timer part: switched off -> an hour of timers sends nothing; switched on again -> the same timers do send
	var hub := FakeHub.new()
	var ph: Dev = make_dev("m_ph", "phone", hub)
	var peer: Dev = make_dev("m_pc", "pc", hub)
	add_sec(ph, 30)
	await join(ph)
	await join(peer)
	var ready := [false]
	var m: SyncManager = _mgr(ph, "phone", ready)
	ready[0] = true
	m.backend_changed()
	m.set_enabled(false)
	var reqs0: int = ph.reqs
	for i in 3600:
		m.advance(1.0)
	ok("E-S1", ph.reqs == reqs0, "switched off: an hour of manager timers sends 0 requests (%d)" % (ph.reqs - reqs0))
	ok("E-S1", not m.status().get("enabled", true), "the manager reports the switch off")
	m.set_enabled(true)
	var reqs1: int = ph.reqs
	for i in 600:
		m.advance(1.0)
	ok("E-S1", ph.reqs > reqs1, "positive control: switched on, the timers do send requests (%d in 10 min)" % (ph.reqs - reqs1))
	_drop(m)

	# E-S6 phone: choice_needed("phone") once, at the first READY; no request until the user chooses
	var hub6 := FakeHub.new()
	var a: Dev = make_dev("s6_ph", "phone", hub6)
	add_sec(a, 5)
	var emits_a: Array = []
	var ready6 := [false]
	var ma: SyncManager = _mgr(a, "phone", ready6)
	ma.choice_needed.connect(func(k: String) -> void: emits_a.append(k))
	ready6[0] = true
	ma.backend_changed()
	var reqs6: int = a.reqs
	for i in 3600:
		ma.advance(1.0)
	ok("E-S6", emits_a == ["phone"], "phone: choice_needed('phone') at the first READY (%s)" % str(emits_a))
	ok("E-S6", a.reqs == reqs6, "phone: no /sync request before the choice (%d)" % (a.reqs - reqs6))
	ready6[0] = false
	ma.backend_changed()
	ready6[0] = true
	ma.backend_changed()
	ok("E-S6", emits_a.size() == 1, "phone: a reconnect does not ask again")
	var rc: Dictionary = await ma.choose("merge")
	ok("E-S6", rc["ok"] and not a.engine.needs_choice(), "phone: choosing merge ends the question (%s)" % rc["code"])
	_drop(ma)

	# E-S6 PC: no question while the hub is empty; one question once a phone copy is there; never again
	var hub7 := FakeHub.new()
	var pcd: Dev = make_dev("s6_pc", "pc", hub7)
	var emits_p: Array = []
	var ready7 := [false]
	var mp: SyncManager = _mgr(pcd, "pc", ready7)
	mp.choice_needed.connect(func(k: String) -> void: emits_p.append(k))
	ready7[0] = true
	mp.backend_changed()
	for i in 180:
		mp.advance(1.0)
	ok("E-S6", emits_p.is_empty(), "PC: empty hub -> no question (questions asked: %d)" % emits_p.size())
	ok("E-S6", not FileAccess.file_exists(pcd.ports.state_path), "PC: the probes write no sidecar")
	var ph7: Dev = make_dev("s6_ph7", "phone", hub7)
	add_sec(ph7, 3)
	await join(ph7)
	for i in 180:
		mp.advance(1.0)
	ok("E-S6", emits_p == ["pc"], "PC: a phone copy on the hub -> one question (%s)" % str(emits_p))
	for i in 600:
		mp.advance(1.0)
	ok("E-S6", emits_p.size() == 1, "PC: the question is not repeated")
	_drop(mp)


# ---------------------------------------------------------------- regression checks for the engine repairs (E-J4, E-B3, E-U5, E-R3)
# Written against the behaviour the sync design requires. Before the repair the first three are expected to FAIL.

func t_regress() -> void:
	await t_regress_journal()
	await t_regress_first_restore()
	await t_regress_oldest_backup()
	await t_regress_switch_during_round()
	await t_regress_journal_no_mix()


## E-J4: learning made after a failed apply (the journal still pending) is not lost when the journal is finished.
func t_regress_journal() -> void:
	print("[regression: learning during a failed apply]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("rg_pc", "pc", hub)
	var d: Dev = make_dev("rg_ph", "phone", hub)
	add_xp(d, 10)
	add_sec(d, 100)
	await join(d)
	await join(peer)
	add_xp(peer, 7)
	add_sec(peer, 30)
	await peer.engine.sync_now("change")
	d.fail_mode = "before"
	var r1: Dictionary = await d.engine.sync_now("poll")
	ok("E-J4", r1["code"] == "disk", "the apply of the peer's change fails (%s)" % r1["code"])
	add_xp(d, 5)
	add_sec(d, 40)
	d.fail_mode = ""
	engine_of(d)
	var r2: Dictionary = await d.engine.sync_now("start")
	ok("E-J4", r2["ok"] and xp_of(d) == 22 and sec_of(d) == 170,
		"learning made during the failed apply is kept: xp 22, sec 170 (%s, %d, %d)" % [r2["code"], xp_of(d), sec_of(d)])
	var r3: Dictionary = await d.engine.sync_now("poll")
	await peer.engine.sync_now("poll")
	ok("E-J4", r3["ok"] and xp_of(d) == 22 and sec_of(d) == 170 and xp_of(peer) == 22 and sec_of(peer) == 170,
		"later rounds: no loss and no double count on either device (%d/%d xp, %d/%d sec)" % [xp_of(d), xp_of(peer), sec_of(d), sec_of(peer)])


## E-B3: the first sync's apply fails, the user restores the backup, joins again: counted once.
func t_regress_first_restore() -> void:
	print("[regression: first sync fails, restore, join again]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("rb_pc", "pc", hub)
	add_xp(peer, 7)
	add_sec(peer, 30)
	await join(peer)
	var d: Dev = make_dev("rb_ph", "phone", hub)
	add_xp(d, 10)
	add_sec(d, 100)
	d.fail_mode = "before"
	var rj: Dictionary = await d.engine.set_choice("merge")
	ok("E-B3", rj["code"] == "disk", "first sync: the apply fails (%s)" % rj["code"])
	var first_name: String = ""
	for b in d.engine.list_backups():
		if b["reason"] == "first":
			first_name = str(b["name"])
	ok("E-B3", first_name != "", "a 'first' backup was made before the failed apply")
	var rs: Dictionary = d.engine.restore_backup(first_name)
	ok("E-B3", rs["ok"], "restore_backup(first) ok (%s)" % str(rs["error"]))
	d.fail_mode = ""
	d.engine.set_enabled(true)
	var rr: Dictionary = await d.engine.sync_now("manual")
	ok("E-B3", rr["ok"] and xp_of(d) == 17 and sec_of(d) == 130,
		"join again after the restore: xp 17, sec 130, no double count (%s, %d, %d)" % [rr["code"], xp_of(d), sec_of(d)])
	var rp: Dictionary = await peer.engine.sync_now("poll")
	ok("E-B3", rp["ok"] and xp_of(peer) == 17 and sec_of(peer) == 130, "the peer agrees: xp 17, sec 130 (%d, %d)" % [xp_of(peer), sec_of(peer)])


## E-U5: the oldest automatic backup (of 11 kept) restores; the files match its meta md5.
func t_regress_oldest_backup() -> void:
	print("[regression: oldest automatic backup restores]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("ro_pc", "pc", hub)
	var d: Dev = make_dev("ro_ph", "phone", hub)
	add_sec(d, 5)
	await join(d)
	await join(peer)
	for i in 12:
		add_sec(peer, 1)
		await peer.engine.sync_now("change")
		await d.engine.sync_now("change")
	var oldest: Dictionary = {}
	for b in d.engine.list_backups():
		if b["reason"] == "auto":
			oldest = b
	ok("E-U5", count_reason(d, "auto") == 10 and not oldest.is_empty(), "10 automatic backups kept, the oldest one found (auto %d)" % count_reason(d, "auto"))
	var rs: Dictionary = d.engine.restore_backup(str(oldest.get("name", "")))
	ok("E-U5", rs["ok"], "restore of the oldest automatic backup is ok (%s)" % str(rs["error"]))
	var same: bool = true
	for fn in ["progress.json", "studylog.json", "prefs.json"]:
		same = same and FileAccess.get_md5(d.dir + "/" + fn) == str((oldest.get("md5", {}) as Dictionary).get(fn, "?"))
	ok("E-U5", same, "the three record files have the md5 of that backup")
	ok("E-U5", not bool(sidecar(d).get("enabled", true)), "after the restore sync is switched off")


## E-R3: sync switched off while a round waits for the hub: that round applies nothing and pushes nothing.
func t_regress_switch_during_round() -> void:
	print("[regression: switch off while a round is in progress]")
	var hub := FakeHub.new()
	var peer: Dev = make_dev("rs_pc", "pc", hub)
	var d: Dev = make_dev("rs_ph", "phone", hub)
	add_sec(d, 50)
	await join(d)
	await join(peer)
	add_sec(peer, 30)
	await peer.engine.sync_now("change")
	var sec0: int = sec_of(d)
	var applies0: int = d.applies
	var rev0: int = hub.rev
	var dev_id: String = str(sidecar(d).get("device_id", ""))
	var seq0: int = hub.seq_of(dev_id)
	d.slow = true
	var out: Array = [null]
	_round_into(d.engine, out)
	d.engine.set_enabled(false)
	var t0: int = Time.get_ticks_msec()
	while out[0] == null and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().process_frame
	d.slow = false
	ok("E-R3", out[0] != null, "the round in progress finishes")
	if out[0] == null:
		return
	var r: Dictionary = out[0]
	ok("E-R3", not r["applied"] and d.applies == applies0 and sec_of(d) == sec0,
		"switched off during the wait: nothing applied (sec %d -> %d, code %s)" % [sec0, sec_of(d), r["code"]])
	ok("E-R3", not r["pushed"] and hub.rev == rev0 and hub.seq_of(dev_id) == seq0,
		"switched off during the wait: nothing pushed (hub rev %d -> %d)" % [rev0, hub.rev])


func _round_into(e: SyncEngine, out: Array) -> void:
	out[0] = await e.sync_now("poll")


## E-J5: the process died during an apply (the journal has no mix_base); after the restart the learning made before the first round
## must neither be lost nor counted twice. Two sizes of the peer's contribution: small and large.
func t_regress_journal_no_mix() -> void:
	print("[regression: journal without mix_base (crash during an apply)]")
	await _no_mix_scenario("small", 7, 25)
	await _no_mix_scenario("large", 27, 500)


func _no_mix_scenario(label: String, peer_xp: int, peer_sec: int) -> void:
	var hub := FakeHub.new()
	var peer: Dev = make_dev("nm_" + label + "_pc", "pc", hub)
	var d: Dev = make_dev("nm_" + label + "_ph", "phone", hub)
	add_xp(d, 10)
	add_sec(d, 50)
	await join(d)
	await join(peer)
	add_xp(peer, peer_xp)
	add_sec(peer, peer_sec)
	await peer.engine.sync_now("change")
	d.fail_mode = "before"
	var r1: Dictionary = await d.engine.sync_now("change")
	ok("E-J5", r1["code"] == "disk" and sidecar(d).get("pending", null) is Dictionary,
		"%s: the apply fails and the journal stays (%s)" % [label, r1["code"]])
	# the process died during the apply: the journal is written without mix_base
	var sc: Dictionary = sidecar(d)
	if sc.get("pending", null) is Dictionary:
		(sc["pending"] as Dictionary).erase("mix_base")
	var f: FileAccess = FileAccess.open(d.ports.state_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(sc))
	f.close()
	d.fail_mode = ""
	engine_of(d)
	add_xp(d, 5)
	add_sec(d, 40)
	var want_xp: int = 10 + peer_xp + 5
	var want_sec: int = 50 + peer_sec + 40
	var r2: Dictionary = await d.engine.sync_now("start")
	ok("E-J5", r2["ok"] and r2["code"] != "merge_check_failed", "%s: first round after the restart is ok (%s)" % [label, r2["code"]])
	ok("E-J5", xp_of(d) == want_xp and sec_of(d) == want_sec,
		"%s: no loss (xp %d want %d, sec %d want %d)" % [label, xp_of(d), want_xp, sec_of(d), want_sec])
	for i in 2:
		await d.engine.sync_now("poll")
	await peer.engine.sync_now("poll")
	ok("E-J5", xp_of(d) == want_xp and sec_of(d) == want_sec and xp_of(peer) == want_xp and sec_of(peer) == want_sec,
		"%s: no double count in later rounds, the peer agrees (phone %d xp / %d s, peer %d xp / %d s)" % [label, xp_of(d), sec_of(d), xp_of(peer), sec_of(peer)])
