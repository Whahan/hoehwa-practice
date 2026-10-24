extends Node
## A3b: LocalMissions (phone GET /missions, POST /missions/check) against the shipped pack and the PC golden file.
##   godot --headless --path <project> res://tests/local_missions_test.tscn
## Exit code 0 = all checks passed. Last line: "== local_missions_test result: N passed, 0 failed =="
## Golden file: res://tests/fixtures/mission_golden.json (written by backend/tools/make_mission_golden.py).
## Broken-regex case (F15) uses user://test_a3b_pack/ only; PackLoader.base_dir is restored at the end.

const GOLDEN := "res://tests/fixtures/mission_golden.json"
const TMP_DIR := "user://test_a3b_pack"
const BROKEN_ID := "a3b_broken_regex"

var passed: int = 0
var failed: int = 0
var pos_n: int = 0
var neg_n: int = 0


func _ready() -> void:
	print("== local_missions_test start ==")
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	LocalMissions.reset()
	_test_pack_and_list()
	_test_pos_neg()
	_test_golden()
	_test_norm_cases()
	_test_response_shape()
	_test_check_semantics()
	_test_errors_and_paths()
	_test_broken_regex()
	print("== local_missions_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _load_golden() -> Dictionary:
	var f: FileAccess = FileAccess.open(GOLDEN, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}


func _raw_missions() -> Array:
	var r: Dictionary = PackLoader.load_json("missions.json")
	if not bool(r.get("ok", false)):
		return []
	return (r["data"] as Dictionary).get("missions", []) as Array


func _check(mission_id: String, text: Variant, done: Array = []) -> Dictionary:
	return LocalMissions.handle("POST", "/missions/check", {}, {"lang": "en", "mission_id": mission_id, "text": text, "done": done})


func _test_pack_and_list() -> void:
	print("[pack, availability, list]")
	ok(LocalMissions.is_available(), "is_available with the shipped pack")
	ok(str(LocalMissions.unavailable_reason()["err_code"]) == "", "unavailable_reason is empty when the pack is fine")
	var raw: Array = _raw_missions()
	ok(raw.size() == 8, "shipped missions.json has 8 missions (%d)" % raw.size())
	ok(LocalMissions.compiled_missions().size() == raw.size(), "every shipped mission compiles")
	ok(LocalMissions.disabled_missions().is_empty(), "no shipped mission is disabled")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	ok(bool(r["ok"]) and int(r["code"]) == 200, "GET /missions is ok 200")
	ok((r["data"]["missions"] as Array).size() == raw.size(), "GET /missions lists all 8")
	var orders: Array = []
	for m in r["data"]["missions"]:
		orders.append(str(m["id"]))
	ok(orders[0] == "cafe_order", "list is sorted by order (first %s)" % str(orders[0]))


func _test_pos_neg() -> void:
	print("[every goal: pos sentences match, neg sentences do not (sentences read from missions.json)]")
	var compiled: Dictionary = {}
	for m in LocalMissions.compiled_missions():
		for g in m["goals"]:
			compiled[str(m["id"]) + "/" + str(g["id"])] = g
	var goals_n := 0
	var raw_pos := 0
	var raw_neg := 0
	for rm in _raw_missions():
		for rg in rm["goals"]:
			goals_n += 1
			var key: String = str(rm["id"]) + "/" + str(rg["id"])
			ok(compiled.has(key), "compiled goal " + key)
			if not compiled.has(key):
				continue
			var g: Dictionary = compiled[key]
			for s in rg.get("pos", []):
				raw_pos += 1
				pos_n += 1
				ok(LocalMissions.goal_matches(g, LocalMissions.normalize(str(s))), "pos %s: %s" % [key, str(s)])
			for s in rg.get("neg", []):
				raw_neg += 1
				neg_n += 1
				ok(not LocalMissions.goal_matches(g, LocalMissions.normalize(str(s))), "neg %s: %s" % [key, str(s)])
	print("  goals %d, pos %d, neg %d" % [goals_n, raw_pos, raw_neg])
	ok(goals_n == 34 and raw_pos > 0 and raw_neg > 0, "34 goals with pos and neg sentences (%d)" % goals_n)


func _test_golden() -> void:
	print("[golden: PC check_text results for the fixed inputs]")
	var g: Dictionary = _load_golden()
	ok(not g.is_empty(), "golden file parses")
	var entries: Array = g.get("entries", []) as Array
	ok(entries.size() == 30, "30 golden entries (%d)" % entries.size())
	for i in entries.size():
		var e: Dictionary = entries[i]
		ok(LocalMissions.normalize(str(e["text"])) == str(e["norm"]), "golden #%d normalised text" % i)
		var r: Dictionary = _check(str(e["mission_id"]), str(e["text"]), [])
		var got: Array = []
		if bool(r["ok"]):
			for gid in r["data"]["new"]:
				got.append(str(gid))
		got.sort()
		var want: Array = []
		for gid in e["reached"]:
			want.append(str(gid))
		want.sort()
		ok(bool(r["ok"]) and got == want, "golden #%d %s reached: want %s got %s" % [i, str(e["mission_id"]), str(want), str(got)])


func _test_norm_cases() -> void:
	print("[normalize table against PC normalize]")
	var g: Dictionary = _load_golden()
	var cases: Array = g.get("norm_cases", []) as Array
	ok(cases.size() == 18, "18 normalize cases (%d)" % cases.size())
	for i in cases.size():
		var c: Dictionary = cases[i]
		var got: String = LocalMissions.normalize(str(c["text"]))
		ok(got == str(c["norm"]), "norm case #%d: want '%s' got '%s'" % [i, str(c["norm"]), got])
	var table: Array = g.get("table_cases", []) as Array
	ok(table.size() == 302, "302 table code points (%d)" % table.size())
	for t in table:
		var cp: int = int(t[0])
		var want_c: String = str(t[1])
		var got_c: String = LocalMissions.normalize(String.chr(cp))
		ok(got_c == want_c, "table U+%04X: want '%s' got '%s'" % [cp, want_c, got_c])


func _test_response_shape() -> void:
	print("[response shape (API.md) and no answer rules in responses]")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	var d: Dictionary = r["data"]
	ok(d.get("via") == "phone", "GET /missions via phone")
	ok(d.get("degraded") is Array and (d["degraded"] as Array).is_empty(), "GET /missions degraded []")
	ok(d.get("lang") == "en" and d.get("unsupported") == false, "GET /missions lang en, unsupported false")
	for m in d["missions"]:
		for k in ["id", "title_ko", "situation_ko", "min_stage", "max_turns", "opening", "goals", "scenario", "script"]:
			ok(m.has(k), "mission %s has key %s" % [str(m["id"]), k])
		for gk in ["match", "pos", "neg", "goal_en"]:
			ok(not m.has(gk), "mission %s has no %s" % [str(m["id"]), gk])
		for gg in m["goals"]:
			for k in ["id", "label_ko", "hint_en"]:
				ok(gg.has(k), "goal %s/%s has key %s" % [str(m["id"]), str(gg["id"]), k])
			for gk in ["match", "pos", "neg", "goal_en"]:
				ok(not gg.has(gk), "goal %s/%s has no %s" % [str(m["id"]), str(gg["id"]), gk])
		var sc: Dictionary = m["scenario"]
		ok(sc.get("id") == "mission:" + str(m["id"]), "scenario id of %s" % str(m["id"]))
		for k in ["title", "persona", "scene"]:
			ok(sc.has(k), "scenario of %s has %s" % [str(m["id"]), k])
	var txt: String = JSON.stringify(r["data"])
	ok(not txt.contains("\"match\"") and not txt.contains("\"pos\"") and not txt.contains("\"neg\"") and not txt.contains("\"goal_en\""),
		"GET /missions JSON has no match/pos/neg/goal_en key")

	var c: Dictionary = _check("cafe_order", "Hi there", [])
	ok(bool(c["ok"]) and int(c["code"]) == 200, "POST /missions/check ok 200")
	var cd: Dictionary = c["data"]
	ok(cd.get("via") == "phone" and cd.get("degraded") is Array and (cd["degraded"] as Array).is_empty(), "check via phone, degraded []")
	for k in ["mission_id", "goals", "new", "all_done"]:
		ok(cd.has(k), "check response has " + k)
	for gg in cd["goals"]:
		for k in ["id", "done", "new"]:
			ok(gg.has(k), "check goal entry has " + k)


func _test_check_semantics() -> void:
	print("[check: new, done, all_done]")
	var r1: Dictionary = _check("cafe_order", "Hi there", [])
	ok("greet" in r1["data"]["new"], "greeting gives new greet")
	var r2: Dictionary = _check("cafe_order", "Hi there", ["greet"])
	var greet_done := false
	var greet_new := true
	for gg in r2["data"]["goals"]:
		if gg["id"] == "greet":
			greet_done = bool(gg["done"])
			greet_new = bool(gg["new"])
	ok(greet_done and not greet_new, "already done goal: done true, new false")
	ok((r2["data"]["new"] as Array).is_empty(), "already done goal is not in new")
	var r3: Dictionary = _check("cafe_order", "Hi there", ["zzz_unknown", 5, "greet"])
	var r3_ids: Array = []
	for gg in r3["data"]["goals"]:
		r3_ids.append(str(gg["id"]))
	ok(bool(r3["ok"]) and r3_ids.size() == 5 and not ("zzz_unknown" in r3_ids) and not bool(r3["data"]["all_done"]),
		"unknown and non-string done ids are ignored (5 goals, no extra id)")
	ok(not ("greet" in r3["data"]["new"]), "greet listed as done is not new")
	var r4: Dictionary = _check("cafe_order", "I'd like a latte", ["order_drink"])
	ok(not ("order_drink" in r4["data"]["new"]), "done order_drink is not counted as new again")
	var all_ids: Array = []
	for gg in LocalMissions.compiled_missions()[0]["goals"]:
		all_ids.append(str(gg["id"]))
	var r5: Dictionary = _check("cafe_order", "x", all_ids)
	ok(bool(r5["data"]["all_done"]) and (r5["data"]["new"] as Array).is_empty(), "all goals done -> all_done true")
	var r6: Dictionary = _check("cafe_order", "x", ["greet"])
	ok(not bool(r6["data"]["all_done"]), "partly done -> all_done false")
	var r7: Dictionary = _check("cafe_order", "Hi there", [])
	ok(not bool(r7["data"]["all_done"]), "one goal -> all_done false")


func _test_errors_and_paths() -> void:
	print("[errors, stage filter, unknown paths]")
	var ja: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja"}, {})
	ok(bool(ja["ok"]) and int(ja["code"]) == 200 and ja["data"]["unsupported"] == true, "GET lang=ja is 200 unsupported")
	ok((ja["data"]["missions"] as Array).is_empty() and str(ja["data"]["message"]) == LocalMissions.JA_MSG, "GET lang=ja: empty list and message")
	var bad: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "fr"}, {})
	ok(not bool(bad["ok"]) and int(bad["code"]) == 400 and str(bad["err_code"]) == "bad_request", "GET lang=fr is 400")
	ok(str(bad["error"]).contains("lang"), "GET lang=fr error is Korean about lang")
	var empty_lang: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": ""}, {})
	ok(not bool(empty_lang["ok"]) and int(empty_lang["code"]) == 400, "GET lang='' is 400")

	var raw: Array = _raw_missions()
	var n1 := 0
	var n2 := 0
	for m in raw:
		if int(m["min_stage"]) <= 1:
			n1 += 1
		if int(m["min_stage"]) <= 2:
			n2 += 1
	var s1: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "1"}, {})
	ok((s1["data"]["missions"] as Array).size() == n1, "stage=1 gives %d missions" % n1)
	var s0: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "0"}, {})
	ok((s0["data"]["missions"] as Array).size() == n1, "stage=0 is clamped to 1")
	var s4: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "4"}, {})
	ok((s4["data"]["missions"] as Array).size() == raw.size(), "stage=4 gives all")
	var sp: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "+2"}, {})
	ok((sp["data"]["missions"] as Array).size() == n2, "stage=+2 gives %d missions" % n2)
	var sa: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "abc"}, {})
	ok((sa["data"]["missions"] as Array).size() == raw.size(), "stage=abc is ignored")
	var sbig: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en", "stage": "99999999999999999999"}, {})
	ok((sbig["data"]["missions"] as Array).size() == raw.size(), "stage with 20 digits is ignored")

	var cja: Dictionary = _check_lang("ja", "cafe_order", "Hi")
	ok(not bool(cja["ok"]) and int(cja["code"]) == 400 and str(cja["error"]) == LocalMissions.JA_MSG, "check lang=ja is 400")
	var clang: Dictionary = _check_lang("", "cafe_order", "Hi")
	ok(not bool(clang["ok"]) and int(clang["code"]) == 400, "check lang='' is 400")
	var unknown: Dictionary = _check("nope_mission", "Hi")
	ok(not bool(unknown["ok"]) and int(unknown["code"]) == 404, "unknown mission is 404")
	ok(str(unknown["error"]) == LocalMissions.UNKNOWN_MSG, "unknown mission text is Korean and fixed")
	ok(not bool(_check("cafe_order", "")["ok"]) and int(_check("cafe_order", "")["code"]) == 400, "empty text is 400")
	ok(int(_check("cafe_order", "   ")["code"]) == 400, "blank text is 400")
	ok(int(_check("cafe_order", 5)["code"]) == 400, "non-string text is 400")
	var no_text: Dictionary = LocalMissions.handle("POST", "/missions/check", {}, {"lang": "en", "mission_id": "cafe_order"})
	ok(int(no_text["code"]) == 400, "missing text is 400")
	var long_text: String = "a".repeat(20001)
	var lt: Dictionary = _check("cafe_order", long_text)
	ok(not bool(lt["ok"]) and int(lt["code"]) == 400, "20,001 characters is 400")
	var ok_long: Dictionary = _check("cafe_order", "a".repeat(20000))
	ok(bool(ok_long["ok"]), "20,000 characters is accepted")

	var p1: Dictionary = LocalMissions.handle("GET", "/missions/judge", {}, {})
	ok(not bool(p1["ok"]) and str(p1["err_code"]) == "not_on_phone" and int(p1["code"]) == 503, "GET /missions/judge is not_on_phone")
	var p2: Dictionary = LocalMissions.handle("POST", "/missions", {}, {})
	ok(not bool(p2["ok"]) and str(p2["err_code"]) == "not_on_phone", "POST /missions is not_on_phone")
	ok(LocalMissions.is_available(), "still available after errors")


func _check_lang(lang: String, mission_id: String, text: String) -> Dictionary:
	return LocalMissions.handle("POST", "/missions/check", {}, {"lang": lang, "mission_id": mission_id, "text": text, "done": []})


## F15: a pack whose mission has a regex that does not compile -> only that mission is left out.
func _test_broken_regex() -> void:
	print("[F15: one broken regex disables only its mission]")
	var br: Dictionary = PackLoader.load_bytes("missions.json")
	ok(bool(br["ok"]), "shipped missions.json verifies")
	if not bool(br["ok"]):
		return
	var data: Dictionary = JSON.parse_string((br["data"] as PackedByteArray).get_string_from_utf8())
	var fake: Dictionary = (data["missions"][0] as Dictionary).duplicate(true)
	fake["id"] = BROKEN_ID
	fake["order"] = 999
	var g0: Dictionary = fake["goals"][0]
	var mt: Dictionary = g0["match"]
	mt["any"] = ["(unclosed group"]
	(data["missions"] as Array).append(fake)

	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var mf: FileAccess = FileAccess.open(TMP_DIR + "/missions.json", FileAccess.WRITE)
	ok(mf != null, "write broken pack missions.json")
	if mf == null:
		return
	mf.store_string(JSON.stringify(data))
	mf.close()

	# manifest copy: same files, sizes and hashes for the copies (missions.json changed, so its hash is new)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PackLoader.DEFAULT_DIR + "/manifest.json"))
	for entry in manifest["files"]:
		var name: String = str(entry["path"])
		if name == "missions.json":
			entry["bytes"] = FileAccess.get_file_as_bytes(TMP_DIR + "/missions.json").size()
			entry["sha256"] = FileAccess.get_sha256(TMP_DIR + "/missions.json")
		else:
			var src: PackedByteArray = FileAccess.get_file_as_bytes(PackLoader.DEFAULT_DIR + "/" + name)
			var dst: FileAccess = FileAccess.open(TMP_DIR + "/" + name, FileAccess.WRITE)
			dst.store_buffer(src)
			dst.close()
	var mm: FileAccess = FileAccess.open(TMP_DIR + "/manifest.json", FileAccess.WRITE)
	mm.store_string(JSON.stringify(manifest))
	mm.close()

	PackLoader.base_dir = TMP_DIR
	PackLoader.reset()
	LocalMissions.reset()
	ok(LocalMissions.is_available(), "pack with the broken mission is still available")
	var dis_ids: Array = []
	for x in LocalMissions.disabled_missions():
		dis_ids.append(str(x["id"]))
	ok(dis_ids == [BROKEN_ID], "only the broken mission is disabled (%s)" % str(dis_ids))
	ok(LocalMissions.compiled_missions().size() == 8, "the other 8 missions compile")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	ok(bool(r["ok"]) and (r["data"]["missions"] as Array).size() == 8, "GET /missions lists 8 with the broken one left out")
	var listed := false
	for m in r["data"]["missions"]:
		if str(m["id"]) == BROKEN_ID:
			listed = true
	ok(not listed, "broken mission is not listed")
	var cb: Dictionary = _check(BROKEN_ID, "hi")
	ok(not bool(cb["ok"]) and int(cb["code"]) == 404, "check on the broken mission is 404, no crash")
	var co: Dictionary = _check("cafe_order", "Hi there", [])
	ok(bool(co["ok"]) and ("greet" in co["data"]["new"]), "other missions still check")

	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	LocalMissions.reset()
	ok(LocalMissions.compiled_missions().size() == 8 and LocalMissions.disabled_missions().is_empty(),
		"restored shipped pack: 8 usable, none disabled")
