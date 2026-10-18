extends Node
## S4 round-trip tests (docs/sync_design.md 10.7, E-RT1..E-RT12 and E-C1). Real hub: the stub server (backend/lan_stub_server.py,
## sync_dir = a scratch folder) behind a counting proxy that run_sync_tests.ps1 starts. Two fake devices in one process:
## "pc" (loopback) and "phone" (same hub, its own sidecar and record files). Every path is under user://test_s4/rt/.
##
## Arguments (after --):  --proxy=<http base of the counting proxy>  --ctl=<same base, /__ctl>  --hub-dir=<abs hub folder>
##                        --stub=<http base of the stub itself>  --lan=<http base of the phone link listener>
## Check line:  "  PASS  [ID] label" / "  FAIL  [ID] label" / "  SKIP  [ID] label". Last line: "== sync_roundtrip result: N passed, M failed =="

const ROOT := "user://test_s4/rt"
const ISO := "2026-10-17"
const LANG := "en"
const FIX_PC := "res://tests/sync_fixtures/pc_local.json"
const FIX_PHONE := "res://tests/sync_fixtures/phone_local.json"
const TIME_TOL := 2 ## seconds allowed between two devices for due / last_review (skew is whole seconds)

var passed: int = 0
var failed: int = 0
var skipped: int = 0
var proxy_base: String = ""
var stub_base: String = ""
var lan_base: String = ""
var hub_dir: String = ""
var only_arg: String = ""
var _uniq: int = 0


class Dev:
	var name: String = ""
	var dir: String = ""
	var base: String = ""      # where this device's sync requests go (proxy, or the LAN listener for the phone-link test)
	var progress: Dictionary = {}
	var studylog: Dictionary = {}
	var prefs: Dictionary = {}
	var clock_off: int = 0
	var gets: int = 0
	var posts: int = 0
	var codes: Array = []      # HTTP code of every push reply, in order
	var inject_stale: bool = false
	var global_api: bool = false ## true: requests go through the global Api (set_remote: base + Bearer token), phone-link test only
	var ports: SyncPorts = null
	var engine: SyncEngine = null


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
	print("== sync_roundtrip test start ==")
	var want: String = OS.get_environment("HOEHWA_SYNC_TEST_ROOT").replace("\\", "/")
	var have: String = OS.get_user_data_dir().replace("\\", "/")
	if want == "" or not have.begins_with(want):
		print("GUARD: HOEHWA_SYNC_TEST_ROOT is not set or the user data folder is outside it; nothing written")
		get_tree().quit(2)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--proxy="):
			proxy_base = a.substr(8).rstrip("/")
		elif a.begins_with("--stub="):
			stub_base = a.substr(7).rstrip("/")
		elif a.begins_with("--lan="):
			lan_base = a.substr(6).rstrip("/")
		elif a.begins_with("--hub-dir="):
			hub_dir = a.substr(10)
		elif a.begins_with("--only="):
			only_arg = a.substr(7)
	if proxy_base == "" or stub_base == "" or lan_base == "" or hub_dir == "":
		print("missing arguments (--proxy --stub --lan --hub-dir)")
		get_tree().quit(2)
		return
	Api.token = ""
	SyncBackup.remove_dir(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	SyncMerge.test_corrupt = Callable()
	await ctl("down=0&pull404=0&pull_body=none")
	# --only=rt1 runs E-RT1 alone (used to repeat it); no argument runs every scenario
	await rt1_first_merge()
	if only_arg == "":
		await rt3_outage()
		await rt4_concurrent()
		await rt5_deletion()
		await rt6_old_pc()
		await rt8_stale_seq()
		await rt9_phone_token()
		await rt11_separate()
		await rt12_switch_off_on()
		await ec1_clock()
	await ctl("down=0&pull404=0&pull_body=none")
	Api.token = ""
	SyncBackup.remove_dir(ROOT)
	if skipped > 0:
		print("UNVERIFIED (SKIP): %d item(s)" % skipped)
	print("== sync_roundtrip result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func ctl(q: String) -> void:
	await Api.get_json_to(proxy_base, "/__ctl?" + q, 5.0, false).wait()


func proxy_count() -> int:
	var r: Dictionary = await Api.get_json_to(proxy_base, "/__ctl", 5.0, false).wait()
	var d: Variant = r.get("data", null)
	if d is Dictionary and (d as Dictionary).get("sync_requests", null) != null:
		return int((d as Dictionary)["sync_requests"])
	return -1


## Empties the hub folder (replicas, hub.json): every scenario starts with an empty hub. The stub reads the folder on each request.
func reset_hub() -> void:
	var rd: String = hub_dir.path_join("replicas")
	if DirAccess.dir_exists_absolute(rd):
		for f in DirAccess.get_files_at(rd):
			DirAccess.remove_absolute(rd.path_join(f))
	for f in ["hub.json", "hub.json.prev"]:
		var p: String = hub_dir.path_join(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func make_dev(tag: String, kind: String, base: String) -> Dev:
	_uniq += 1
	var d := Dev.new()
	d.name = tag
	d.dir = "%s/%s_%d" % [ROOT, tag, _uniq]
	d.base = base
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
		d.progress = Progress.normalize(pg)
		save_progress(d)
		var cand: Dictionary = d.studylog.duplicate(true)
		for k in ["days", "phon", "missions"]:
			cand[k] = (sl[k] as Dictionary).duplicate(true)
		d.studylog = StudyLog._normalize(cand)
		for k in pc.keys():
			d.prefs[k] = pc[k]
		save_progress(d)
		save_studylog(d)
		save_prefs(d)
		return true
	p.local_paths = func() -> Dictionary:
		return {"progress": d.dir + "/progress.json", "studylog": d.dir + "/studylog.json", "prefs": d.dir + "/prefs.json"}
	p.is_read_only = func() -> bool:
		return false
	p.is_busy_ui = func() -> bool:
		return false
	p.http_get = func(path: String, timeout: float) -> Dictionary:
		d.gets += 1
		if d.global_api:
			return await Api.get_json(path, timeout, false).wait()
		return await Api.get_json_to(d.base, path, timeout, false).wait()
	p.http_post = func(path: String, body: Dictionary, timeout: float) -> Dictionary:
		d.posts += 1
		if d.inject_stale:
			# another process of this device pushes a newer seq between our pull and our push: the real hub answers 409 stale_seq
			d.inject_stale = false
			var b2: Dictionary = body.duplicate(true)
			b2["seq"] = int(body["seq"]) + 1
			if d.global_api:
				await Api.post_json(path, b2, timeout, false).wait()
			else:
				await Api.post_json_to(d.base, path, b2, timeout, false).wait()
		var r: Dictionary = {}
		if d.global_api:
			r = await Api.post_json(path, body, timeout, false).wait()
		else:
			r = await Api.post_json_to(d.base, path, body, timeout, false).wait()
		d.codes.append(int(r.get("code", 0)))
		return r
	p.reload_local = func() -> void:
		d.progress = Progress.load_file(d.dir + "/progress.json")
		var js := JSON.new()
		if js.parse(FileAccess.get_file_as_string(d.dir + "/studylog.json")) == OK and js.data is Dictionary:
			d.studylog = StudyLog._normalize(js.data)
	d.ports = p
	d.engine = SyncEngine.new(p)
	d.engine.backup_min_gap = 0
	save_progress(d)
	save_studylog(d)
	save_prefs(d)
	return d


func load_fixture(path: String) -> Dictionary:
	var js := JSON.new()
	if js.parse(FileAccess.get_file_as_string(path)) != OK or not (js.data is Dictionary):
		return {}
	return js.data


func apply_fixture(d: Dev, path: String) -> void:
	var fx: Dictionary = load_fixture(path)
	d.progress = Progress.normalize(fx["progress"])
	d.studylog = StudyLog._normalize(fx["studylog"])
	d.prefs = Store.DEFAULT_PREFS.duplicate(true)
	save_progress(d)
	save_studylog(d)
	save_prefs(d)


func save_progress(d: Dev) -> void:
	Progress.save_file(d.dir + "/progress.json", d.progress)


func save_studylog(d: Dev) -> void:
	Progress.write_text_atomic(d.dir + "/studylog.json", JSON.stringify(d.studylog))


func save_prefs(d: Dev) -> void:
	Progress.write_text_atomic(d.dir + "/prefs.json", JSON.stringify(d.prefs))


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


## The synced view split in two parts. "exact": everything except the card id (a per-device value, sync_design.md 4.3) and the
## epoch-second fields due / last_review of the cards. "times": those two fields per card key. Each device computes its skew as an
## integer number of seconds, so the same card can differ by 1 s between devices (a second boundary): times are compared within TIME_TOL.
func view_parts(d: Dev) -> Dictionary:
	var l: Dictionary = d.ports.load_local.call()
	var v: Dictionary = SyncDoc.extract(l["progress"], l["studylog"], l["prefs"], 0)
	var cards: Array = []
	var times: Dictionary = {}
	for c in v["cards"]:
		var cc: Dictionary = (c as Dictionary).duplicate()
		var key: String = str(cc.get("key", ""))
		times[key] = [int(cc.get("due", 0)), int(cc.get("last_review", 0))]
		cc.erase("id")
		cc.erase("due")
		cc.erase("last_review")
		cards.append(cc)
	v["cards"] = cards
	return {"exact": SyncMerge.canonical(v), "times": times}


## Two devices hold the same record: exact parts equal, same card keys, every epoch field within TIME_TOL seconds.
func views_match(x: Dev, y: Dev) -> bool:
	var px: Dictionary = view_parts(x)
	var py: Dictionary = view_parts(y)
	if px["exact"] != py["exact"]:
		return false
	var tx: Dictionary = px["times"]
	var ty: Dictionary = py["times"]
	if tx.size() != ty.size():
		return false
	for k in tx.keys():
		if not ty.has(k):
			return false
		for i in 2:
			if absi(int(tx[k][i]) - int(ty[k][i])) > TIME_TOL:
				return false
	return true


func fingerprint(d: Dev) -> String:
	return view_parts(d)["exact"].sha256_text()


func sidecar(d: Dev) -> Dictionary:
	var js := JSON.new()
	if not FileAccess.file_exists(d.ports.state_path) or js.parse(FileAccess.get_file_as_string(d.ports.state_path)) != OK or not (js.data is Dictionary):
		return {}
	return js.data


func reasons(d: Dev) -> Array:
	var out: Array = []
	for b in d.engine.list_backups():
		out.append(b["reason"])
	return out


func join(d: Dev) -> Dictionary:
	return await d.engine.set_choice("merge")


func hub_replica(dev_id: String) -> Dictionary:
	var p: String = hub_dir.path_join("replicas").path_join(dev_id + ".json")
	if not FileAccess.file_exists(p):
		return {}
	var js := JSON.new()
	if js.parse(FileAccess.get_file_as_string(p)) != OK or not (js.data is Dictionary):
		return {}
	return js.data


## Every file in the hub folder parses as JSON and no *.tmp is left.
func hub_files_clean() -> bool:
	var good: bool = true
	var rd: String = hub_dir.path_join("replicas")
	if DirAccess.dir_exists_absolute(rd):
		for f in DirAccess.get_files_at(rd):
			if f.ends_with(".tmp"):
				good = false
			elif f.ends_with(".json"):
				var js := JSON.new()
				if js.parse(FileAccess.get_file_as_string(rd.path_join(f))) != OK:
					good = false
	for f in DirAccess.get_files_at(hub_dir):
		if f.ends_with(".tmp"):
			good = false
	return good


func _co(e: SyncEngine, reason: String, out: Array, i: int) -> void:
	out[i] = await e.sync_now(reason)


func _wait_all(out: Array, timeout_ms: int) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		var all_done: bool = true
		for x in out:
			if x == null:
				all_done = false
		if all_done:
			return true
		await get_tree().process_frame
	return false


# ---------------------------------------------------------------- E-RT1 / E-RT2: first merge from fixtures, then two rounds

func rt1_first_merge() -> void:
	print("[E-RT1 first merge, E-RT2 two rounds]")
	reset_hub()
	var pc: Dev = make_dev("rt1_pc", "pc", proxy_base)
	var ph: Dev = make_dev("rt1_ph", "phone", proxy_base)
	apply_fixture(pc, FIX_PC)
	apply_fixture(ph, FIX_PHONE)
	var ph_before: String = md5(ph.dir + "/progress.json")
	var r1: Dictionary = await join(pc)
	ok("E-RT1", r1["ok"] and r1["pushed"], "PC joins first (%s)" % r1["code"])
	var r2: Dictionary = await join(ph)
	ok("E-RT1", r2["ok"] and r2["applied"] and r2["pushed"] and r2["first"], "phone joins: merged and pushed (%s)" % r2["code"])
	var bl: Array = ph.engine.list_backups()
	ok("E-RT1", bl.size() == 1 and str(bl[0]["reason"]) == "first" and str((bl[0]["md5"] as Dictionary).get("progress.json", "")) == ph_before,
		"phone: backup 'first' holds the file as it was before the merge")
	var r3: Dictionary = await pc.engine.sync_now("poll")
	ok("E-RT1", r3["ok"], "PC round after the phone joined (%s)" % r3["code"])
	ok("E-RT1", card_targets(pc) == ["A", "B", "C"] and card_targets(ph) == ["A", "B", "C"], "cards A, B, C on both (%s / %s)" % [str(card_targets(pc)), str(card_targets(ph))])
	ok("E-RT1", int(card_of(pc, "B")["reps"]) == 5 and int(card_of(ph, "B")["reps"]) == 5, "card B keeps the larger reps (5) on both")
	ok("E-RT1", has_check(pc, "en-1-w0") and has_check(pc, "en-1-w1") and has_check(ph, "en-1-w0") and has_check(ph, "en-1-w1"), "checks {en-1-w0, en-1-w1} on both")
	ok("E-RT1", xp_of(pc) == 150 and xp_of(ph) == 150 and sec_of(pc) == 900 and sec_of(ph) == 900, "xp.en 150 and sec 900 on both (%d/%d, %d/%d)" % [xp_of(pc), xp_of(ph), sec_of(pc), sec_of(ph)])
	ok("E-RT1", views_match(pc, ph), "the two records are identical (exact fields; due / last_review within %d s)" % TIME_TOL)
	if not views_match(pc, ph):
		_print_view_diff(pc, ph)

	# E-RT2: PC +60, phone +20 -> PC -> phone -> PC: 980 on both
	add_sec(pc, 60)
	add_sec(ph, 20)
	var a: Dictionary = await pc.engine.sync_now("change")
	var b: Dictionary = await ph.engine.sync_now("change")
	var c: Dictionary = await pc.engine.sync_now("change")
	ok("E-RT2", a["ok"] and b["ok"] and c["ok"], "PC -> phone -> PC rounds ok (%s %s %s)" % [a["code"], b["code"], c["code"]])
	ok("E-RT2", sec_of(pc) == 980 and sec_of(ph) == 980, "sec 980 on both (%d, %d)" % [sec_of(pc), sec_of(ph)])


# ---------------------------------------------------------------- E-RT3: the phone is out of reach, then it comes back

func rt3_outage() -> void:
	print("[E-RT3 outage]")
	var pair3: Array = await _joined_pair("rt3", 100, 40)
	var pc: Dev = pair3[0]
	var ph: Dev = pair3[1]
	var own_before: String = SyncMerge.canonical(sidecar(ph).get("own", {}))
	add_sec(ph, 120)
	add_card(ph, "OFF1", 1)
	set_check(ph, "en-9-w1", true)
	await ctl("down=1")
	var codes: Array = []
	for i in 3:
		var r: Dictionary = await ph.engine.sync_now("poll")
		codes.append(r["code"])
	await ctl("down=0")
	ok("E-RT3", codes == ["unreachable", "unreachable", "unreachable"], "3 rounds while cut off -> unreachable (%s)" % str(codes))
	ok("E-RT3", sec_of(ph) == 100 + 40 + 120 and has_card(ph, "OFF1") and has_check(ph, "en-9-w1"), "phone keeps its record while cut off (no loss)")
	ok("E-RT3", SyncMerge.canonical(sidecar(ph).get("own", {})) == own_before, "sidecar own copy unchanged while cut off")
	var rp: Dictionary = await ph.engine.sync_now("resume")
	ok("E-RT3", rp["ok"] and rp["pushed"], "back in reach: phone round ok and pushed (%s)" % rp["code"])
	var rc: Dictionary = await pc.engine.sync_now("poll")
	ok("E-RT3", rc["ok"] and sec_of(pc) == 260 and has_card(pc, "OFF1") and has_check(pc, "en-9-w1"), "PC receives +120 s, the card and the check (sec %d)" % sec_of(pc))


## Two devices, merged: PC with `pc_sec` seconds and card P0, phone with `ph_sec` seconds and card H0. Returns [pc, phone].
func _joined_pair(tag: String, pc_sec: int, ph_sec: int) -> Array:
	reset_hub()
	var pc: Dev = make_dev(tag + "_pc", "pc", proxy_base)
	var ph: Dev = make_dev(tag + "_ph", "phone", proxy_base)
	add_card(pc, "P0", 1)
	add_sec(pc, pc_sec)
	add_card(ph, "H0", 1)
	add_sec(ph, ph_sec)
	await join(pc)
	await join(ph)
	await pc.engine.sync_now("poll")
	return [pc, ph]


# ---------------------------------------------------------------- E-RT4: both devices sync at the same time, 20 times, random study and deletes

func rt4_concurrent() -> void:
	print("[E-RT4 concurrent rounds]")
	var pair: Array = await _joined_pair("rt4", 100, 100)
	var pc: Dev = pair[0]
	var ph: Dev = pair[1]
	var exp_cards: Array = ["H0", "P0"]
	var exp_sec: int = 200
	var exp_xp: int = 0
	var done_ms: Dictionary = {}     # target -> ticks when the owner's round that pushed it finished
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var n_new: int = 0
	var all_ok: bool = true
	await get_tree().create_timer(1.6).timeout
	for it in 20:
		for d in [pc, ph]:
			var dev: Dev = d
			var acts: int = rng.randi_range(0, 2)
			for a in acts:
				var kind: int = rng.randi_range(0, 3)
				if kind == 0:
					var s: int = rng.randi_range(1, 90)
					add_sec(dev, s)
					exp_sec += s
				elif kind == 1:
					n_new += 1
					var t: String = "%s%d" % [("PC" if dev == pc else "PH"), n_new]
					add_card(dev, t, 1)
					exp_cards.append(t)
				elif kind == 2:
					var cands: Array = []
					for t in exp_cards:
						if done_ms.has(t) and Time.get_ticks_msec() - int(done_ms[t]) >= 1500 and has_card(dev, str(t)):
							cands.append(str(t))
					cands.sort()
					if not cands.is_empty():
						var pick: String = cands[rng.randi_range(0, cands.size() - 1)]
						del_card(dev, pick)
						exp_cards.erase(pick)
				else:
					var x: int = rng.randi_range(1, 20)
					add_xp(dev, x)
					exp_xp += x
		var out: Array = [null, null]
		var first_pc: bool = rng.randi_range(0, 1) == 0
		if first_pc:
			_co(pc.engine, "manual", out, 0)
			_co(ph.engine, "manual", out, 1)
		else:
			_co(ph.engine, "manual", out, 1)
			_co(pc.engine, "manual", out, 0)
		var finished: bool = await _wait_all(out, 90000)
		if not finished:
			all_ok = false
			break
		for r in out:
			if not bool((r as Dictionary)["ok"]):
				all_ok = false
				print("    round failed: %s" % str((r as Dictionary)["code"]))
		var now_ms: int = Time.get_ticks_msec()
		for t in exp_cards:
			if not done_ms.has(t):
				done_ms[t] = now_ms
	for i in 2:
		await pc.engine.sync_now("poll")
		await ph.engine.sync_now("poll")
	var all_hub_ok: bool = hub_files_clean()
	ok("E-RT4", all_ok, "20 concurrent rounds, every round ok")
	ok("E-RT4", card_targets(pc) == _sorted(exp_cards) and card_targets(ph) == _sorted(exp_cards),
		"cards agree on both and equal added minus deleted (%d cards)" % exp_cards.size())
	ok("E-RT4", sec_of(pc) == exp_sec and sec_of(ph) == exp_sec, "sec equals the sum of all study on both (%d, %d, want %d)" % [sec_of(pc), sec_of(ph), exp_sec])
	ok("E-RT4", xp_of(pc) == exp_xp and xp_of(ph) == exp_xp, "xp equals the sum on both (%d, %d, want %d)" % [xp_of(pc), xp_of(ph), exp_xp])
	ok("E-RT4", views_match(pc, ph), "both records identical after two more rounds (exact fields; due / last_review within %d s)" % TIME_TOL)
	ok("E-RT4", all_hub_ok, "every hub file is valid JSON, no *.tmp left")


func _sorted(a: Array) -> Array:
	var b: Array = a.duplicate()
	b.sort()
	return b


# ---------------------------------------------------------------- E-RT5: a deletion travels, a re-add comes back

func rt5_deletion() -> void:
	print("[E-RT5 deletion]")
	reset_hub()
	var pc: Dev = make_dev("rt5_pc", "pc", proxy_base)
	var ph: Dev = make_dev("rt5_ph", "phone", proxy_base)
	add_card(pc, "B", 2)
	add_card(pc, "K", 1)
	await join(pc)
	await join(ph)
	ok("E-RT5", has_card(ph, "B"), "phone has card B after the join")
	await get_tree().create_timer(1.6).timeout
	del_card(ph, "B")
	await ph.engine.sync_now("change")
	var r1: Dictionary = await pc.engine.sync_now("poll")
	ok("E-RT5", r1["ok"] and not has_card(pc, "B") and has_card(pc, "K"), "phone's deletion reaches the PC (card B gone, K stays)")
	await get_tree().create_timer(1.6).timeout
	add_card(pc, "B", 1)
	await pc.engine.sync_now("change")
	var r2: Dictionary = await ph.engine.sync_now("poll")
	ok("E-RT5", r2["ok"] and has_card(ph, "B"), "PC adds B again: it comes back on the phone")


# ---------------------------------------------------------------- E-RT6 / E-RT7: strange answers from the server

func rt6_old_pc() -> void:
	print("[E-RT6 old PC, E-RT7 bad reply]")
	var pair: Array = await _joined_pair("rt6", 50, 50)
	var ph: Dev = pair[1]
	var md5_before: String = files_md5(ph)
	await ctl("pull404=1")
	var r6: Dictionary = await ph.engine.sync_now("poll")
	await ctl("pull404=0")
	ok("E-RT6", r6["code"] == "old_pc" and not r6["ok"], "/sync/pull answers 404 -> old_pc (%s)" % r6["code"])
	ok("E-RT6", files_md5(ph) == md5_before, "old_pc: local records unchanged")
	await ctl("pull_body=bad")
	var r7a: Dictionary = await ph.engine.sync_now("poll")
	await ctl("pull_body=nojson")
	var r7b: Dictionary = await ph.engine.sync_now("poll")
	await ctl("pull_body=none")
	ok("E-RT7", r7a["code"] == "bad_reply" and r7b["code"] == "bad_reply", "{\"replicas\": 7} and a non-JSON reply -> bad_reply (%s, %s)" % [r7a["code"], r7b["code"]])
	ok("E-RT7", files_md5(ph) == md5_before, "bad_reply: local records unchanged")
	var r7c: Dictionary = await ph.engine.sync_now("poll")
	ok("E-RT7", r7c["ok"], "the server is fine again -> ok (%s)" % r7c["code"])


# ---------------------------------------------------------------- E-RT8: the real hub answers 409 stale_seq once, the round retries

func rt8_stale_seq() -> void:
	print("[E-RT8 stale seq]")
	var pair: Array = await _joined_pair("rt8", 10, 10)
	var ph: Dev = pair[1]
	add_sec(ph, 7)
	var before_codes: int = ph.codes.size()
	ph.inject_stale = true
	var r: Dictionary = await ph.engine.sync_now("change")
	var got: Array = ph.codes.slice(before_codes)
	ok("E-RT8", r["ok"] and r["pushed"], "stale seq on the first push, the round still ends ok (%s)" % r["code"])
	ok("E-RT8", got == [409, 200], "push replies were 409 then 200 (%s)" % str(got))
	var rep: Dictionary = hub_replica(str(sidecar(ph)["device_id"]))
	ok("E-RT8", int(rep.get("seq", -1)) == int(sidecar(ph)["seq"]), "hub copy carries the seq the phone now holds (%d)" % int(rep.get("seq", -1)))
	var pc: Dev = pair[0]
	await pc.engine.sync_now("poll")
	ok("E-RT8", sec_of(pc) == 27, "PC receives the 7 s after the retry (sec %d)" % sec_of(pc))


# ---------------------------------------------------------------- E-RT9: phone mode through the phone link (token)

func rt9_phone_token() -> void:
	print("[E-RT9 phone link token]")
	reset_hub()
	Api.clear_remote()
	var rc: Dictionary = await Api.post_json_to(stub_base, "/lan/code", {}, 10.0, false).wait()
	var code: String = ""
	if rc["ok"] and rc["data"] is Dictionary:
		code = str((rc["data"] as Dictionary).get("code", ""))
	ok("E-RT9", code.length() == 6, "a pairing code is shown by the PC side (length 6)")
	var rp: Dictionary = await Api.post_json_to(lan_base, "/pair", {"code": code, "device_name": "rt phone"}, 10.0, false).wait()
	var token: String = ""
	if rp["ok"] and rp["data"] is Dictionary:
		token = str((rp["data"] as Dictionary).get("token", ""))
	ok("E-RT9", token.begins_with("hp1_"), "the phone link pairs with the code")
	# the phone talks through the global Api: base = the phone link listener, Bearer token from set_remote
	var ph: Dev = make_dev("rt9_ph", "phone", lan_base)
	ph.global_api = true
	add_sec(ph, 33)
	add_card(ph, "L1", 1)
	var md5_before: String = files_md5(ph)
	Api.set_remote(lan_base, "")
	var r1: Dictionary = await ph.engine.set_choice("merge")
	ok("E-RT9", r1["code"] == "not_connected" and not r1["ok"], "no token -> not_connected (token_missing) (%s)" % r1["code"])
	ok("E-RT9", files_md5(ph) == md5_before, "no token: local records unchanged")
	Api.set_remote(lan_base, "hp1_not_a_real_token")
	var r2: Dictionary = await ph.engine.sync_now("poll")
	ok("E-RT9", r2["code"] == "not_connected" and not r2["ok"], "wrong token -> not_connected (token_invalid) (%s)" % r2["code"])
	Api.set_remote(lan_base, token)
	var r3: Dictionary = await ph.engine.sync_now("poll")
	ok("E-RT9", r3["ok"] and r3["pushed"], "with the paired token -> ok and pushed (%s)" % r3["code"])
	Api.clear_remote()
	var pc: Dev = make_dev("rt9_pc", "pc", proxy_base)
	await pc.engine.set_choice("merge")
	ok("E-RT9", has_card(pc, "L1") and sec_of(pc) == 33, "PC got the phone's card and seconds through the link (sec %d)" % sec_of(pc))


# ---------------------------------------------------------------- E-RT11: separate sends nothing, switch on merges

func rt11_separate() -> void:
	print("[E-RT11 separate, then switch on]")
	reset_hub()
	var pc: Dev = make_dev("rt11_pc", "pc", proxy_base)
	add_card(pc, "X11", 1)
	add_sec(pc, 100)
	await join(pc)
	var ph: Dev = make_dev("rt11_ph", "phone", proxy_base)
	var rs: Dictionary = await ph.engine.set_choice("separate")
	ok("E-RT11", rs["ok"] and rs["code"] == "ok", "choose separate (%s)" % rs["code"])
	var n0: int = await proxy_count()
	var reqs0: int = ph.gets + ph.posts
	add_sec(ph, 50)
	add_card(ph, "Y11", 1)
	for reason in ["manual", "poll", "change", "pause", "resume"]:
		await ph.engine.sync_now(reason)
	var n1: int = await proxy_count()
	ok("E-RT11", n1 == n0 and ph.gets + ph.posts == reqs0, "separate: 0 requests reach the hub (%d -> %d)" % [n0, n1])
	ph.engine.set_enabled(true)
	var r: Dictionary = await ph.engine.sync_now("manual")
	ok("E-RT11", r["ok"] and r["pushed"], "switch on: first merge (%s)" % r["code"])
	ok("E-RT11", card_targets(ph) == ["X11", "Y11"] and sec_of(ph) == 150, "phone: union of cards, sec 150 (%s, %d)" % [str(card_targets(ph)), sec_of(ph)])
	var rp: Dictionary = await pc.engine.sync_now("poll")
	ok("E-RT11", rp["ok"] and has_card(pc, "Y11") and sec_of(pc) == 150, "PC then receives the phone's record")


# ---------------------------------------------------------------- E-RT12: switch off and on, nothing is lost or counted twice

func rt12_switch_off_on() -> void:
	print("[E-RT12 switch off and on]")
	var pair: Array = await _joined_pair("rt12", 200, 100)
	var pc: Dev = pair[0]
	var ph: Dev = pair[1]
	ok("E-RT12", sec_of(pc) == 300 and sec_of(ph) == 300, "joined: 300 on both")
	ph.engine.set_enabled(false)
	var n0: int = await proxy_count()
	add_sec(ph, 120)
	del_card(ph, "P0")
	for reason in ["manual", "poll", "change"]:
		await ph.engine.sync_now(reason)
	var n1: int = await proxy_count()
	ok("E-RT12", n1 == n0, "switched off: no request reaches the hub (%d -> %d)" % [n0, n1])
	add_sec(pc, 60)
	add_card(pc, "X12", 1)
	await pc.engine.sync_now("change")
	ph.engine.set_enabled(true)
	for i in 2:
		await ph.engine.sync_now("manual")
		await pc.engine.sync_now("manual")
	ok("E-RT12", sec_of(ph) == 480 and sec_of(pc) == 480, "+120 (phone) and +60 (PC) once each: 480 on both (%d, %d)" % [sec_of(ph), sec_of(pc)])
	ok("E-RT12", has_card(ph, "P0") and has_card(pc, "P0") and has_card(ph, "X12") and has_card(pc, "X12"), "the card deleted while off is back, the PC's new card arrived, nothing lost")


# ---------------------------------------------------------------- E-C1: the phone's clock is 2 h ahead, through the real hub

func ec1_clock() -> void:
	print("[E-C1 clock through the hub]")
	reset_hub()
	var pc: Dev = make_dev("ec1_pc", "pc", proxy_base)
	var ph: Dev = make_dev("ec1_ph", "phone", proxy_base)
	ph.clock_off = 7200
	var now_ph: int = int(Time.get_unix_time_from_system()) + 7200
	add_card(ph, "CK", 3, now_ph - 100)
	var orig: int = int(card_of(ph, "CK")["last_review"])
	add_sec(ph, 10)
	var r: Dictionary = await join(ph)
	ok("E-C1", r["ok"] and int(r["clock_off_sec"]) == -7200, "phone 2 h ahead: clock_off_sec == -7200 (%s)" % str(r["clock_off_sec"]))
	var hub_doc: Dictionary = hub_replica(str(sidecar(ph)["device_id"])).get("doc", {})
	var hub_lr: int = int(((hub_doc["progress"] as Dictionary)["cards"] as Dictionary)["data"]["en|CK"]["last_review"])
	ok("E-C1", absi(hub_lr - (orig - 7200)) <= 3, "the hub holds the card in hub time (%d vs %d)" % [hub_lr, orig - 7200])
	await join(pc)
	ok("E-C1", absi(int(card_of(pc, "CK")["last_review"]) - (orig - 7200)) <= 3, "PC reads the card in hub time")
	await ph.engine.sync_now("poll")
	ok("E-C1", absi(int(card_of(ph, "CK")["last_review"]) - orig) <= 3, "round trip: the phone shows its own card time again")

## Diagnostic only: prints the view sections that differ between two devices (keys and short values).
func _print_view_diff(x: Dev, y: Dev) -> void:
	var vx: Dictionary = SyncDoc.extract(x.ports.load_local.call()["progress"], x.ports.load_local.call()["studylog"], x.ports.load_local.call()["prefs"], 0)
	var vy: Dictionary = SyncDoc.extract(y.ports.load_local.call()["progress"], y.ports.load_local.call()["studylog"], y.ports.load_local.call()["prefs"], 0)
	for k in vx.keys():
		if SyncMerge.canonical(vx[k]) != SyncMerge.canonical(vy[k]):
			print("    debug view differs at %s: %s  |  %s" % [str(k), SyncMerge.canonical(vx[k]).left(300), SyncMerge.canonical(vy[k]).left(300)])
