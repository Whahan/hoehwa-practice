extends Node
## A3b: LocalMissions (phone GET /missions, POST /missions/check) against the shipped pack and the PC golden file.
##   godot --headless --path <project> res://tests/local_missions_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/local_missions_test.tscn -- --phone
## Exit code 0 = all checks passed. Last line: "== local_missions_test result: N passed, 0 failed =="
## Golden file: res://tests/fixtures/mission_golden.json (written by backend/tools/make_mission_golden.py): English entries,
## "ja_entries" (Japanese check results of the PC engine) and the "ja_*" normalisation cases of MissionText.norm_ja (v1.7.0 B3).
## Broken-regex case (F15) uses user://test_a3b_pack/ only; PackLoader.base_dir is restored at the end.

const GOLDEN := "res://tests/fixtures/mission_golden.json"
const TMP_DIR := "user://test_a3b_pack"
const BROKEN_ID := "a3b_broken_regex"
const BROKEN_JA_ID := "a3b_broken_regex_ja"

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
	_test_golden_ja()
	_test_norm_cases()
	_test_norm_ja()
	_test_response_shape()
	_test_check_semantics()
	_test_response_shape_ja()
	_test_check_semantics_ja()
	_test_errors_and_paths()
	_test_errors_ja()
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


## The shipped missions of one language (content order).
func _raw_lang(lang: String) -> Array:
	var out: Array = []
	for m in _raw_missions():
		if str((m as Dictionary).get("lang", "en")) == lang:
			out.append(m)
	return out


func _check(mission_id: String, text: Variant, done: Array = []) -> Dictionary:
	return LocalMissions.handle("POST", "/missions/check", {}, {"lang": "en", "mission_id": mission_id, "text": text, "done": done})


func _check_ja(mission_id: String, text: Variant, done: Array = []) -> Dictionary:
	return LocalMissions.handle("POST", "/missions/check", {}, {"lang": "ja", "mission_id": mission_id, "text": text, "done": done})


func _new_ids(r: Dictionary) -> Array:
	var got: Array = []
	if bool(r.get("ok", false)):
		for gid in r["data"]["new"]:
			got.append(str(gid))
	got.sort()
	return got


func _test_pack_and_list() -> void:
	print("[pack, availability, list]")
	ok(LocalMissions.is_available(), "is_available with the shipped pack")
	ok(str(LocalMissions.unavailable_reason()["err_code"]) == "", "unavailable_reason is empty when the pack is fine")
	var raw: Array = _raw_missions()
	ok(raw.size() == 16, "shipped missions.json has 16 missions (%d)" % raw.size())
	ok(_raw_lang("en").size() == 8 and _raw_lang("ja").size() == 8, "8 English and 8 Japanese missions")
	ok(LocalMissions.compiled_missions().size() == raw.size(), "every shipped mission compiles")
	ok(LocalMissions.disabled_missions().is_empty(), "no shipped mission is disabled (B3-3: no regex fails in PCRE2)")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	ok(bool(r["ok"]) and int(r["code"]) == 200, "GET /missions is ok 200")
	ok((r["data"]["missions"] as Array).size() == 8, "GET /missions?lang=en lists the 8 English missions")
	var orders: Array = []
	for m in r["data"]["missions"]:
		orders.append(str(m["id"]))
	ok(orders[0] == "cafe_order", "list is sorted by order (first %s)" % str(orders[0]))
	var rj: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja"}, {})
	ok(bool(rj["ok"]) and int(rj["code"]) == 200 and rj["data"]["lang"] == "ja" and rj["data"]["unsupported"] == false,
		"GET /missions?lang=ja is ok 200, lang ja, unsupported false")
	var jids: Array = []
	for m in rj["data"]["missions"]:
		jids.append(str(m["id"]))
	ok(jids == ["ja_konbini", "ja_ramen", "ja_ask_way", "ja_hotel_checkin", "ja_station_ticket", "ja_clinic", "ja_shopping", "ja_self_intro"],
		"GET /missions?lang=ja lists the 8 Japanese missions in order (%s)" % str(jids))
	var all_en := true
	for id in orders:
		if (id as String).begins_with("ja_"):
			all_en = false
	ok(all_en, "the English list has no Japanese mission")


func _test_pos_neg() -> void:
	print("[every goal: pos sentences match, neg sentences do not (sentences read from missions.json)]")
	var compiled: Dictionary = {}
	for m in LocalMissions.compiled_missions():
		for g in m["goals"]:
			compiled[str(m["id"]) + "/" + str(g["id"])] = g
	var goals_n := 0
	var ja_goals_n := 0
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
			var gl: String = str(rm.get("lang", "en"))
			if gl == "ja":
				ja_goals_n += 1
			for s in rg.get("pos", []):
				raw_pos += 1
				pos_n += 1
				ok(LocalMissions.goal_matches(g, LocalMissions.normalize(str(s), gl)), "pos %s: %s" % [key, str(s)])
			for s in rg.get("neg", []):
				raw_neg += 1
				neg_n += 1
				ok(not LocalMissions.goal_matches(g, LocalMissions.normalize(str(s), gl)), "neg %s: %s" % [key, str(s)])
	print("  goals %d (ja %d), pos %d, neg %d" % [goals_n, ja_goals_n, raw_pos, raw_neg])
	ok(goals_n - ja_goals_n == 34 and raw_pos > 0 and raw_neg > 0, "34 English goals with pos and neg sentences (%d)" % (goals_n - ja_goals_n))
	ok(ja_goals_n == 36, "36 Japanese goals with pos and neg sentences, through normalize(s, ja) (%d)" % ja_goals_n)
	# selfcheck: the same Japanese sentences through the English normaliser must NOT satisfy the goals (the test can fail)
	var ja_en_match := 0
	var ja_en_total := 0
	for rm in _raw_lang("ja"):
		for rg in rm["goals"]:
			var key2: String = str(rm["id"]) + "/" + str(rg["id"])
			if not compiled.has(key2):
				continue
			for s in rg.get("pos", []):
				ja_en_total += 1
				if LocalMissions.goal_matches(compiled[key2], LocalMissions.normalize(str(s), "en")):
					ja_en_match += 1
	print("  selfcheck FAIL-as-expected: ja pos sentences through the English normaliser match %d of %d" % [ja_en_match, ja_en_total])
	ok(ja_en_total > 0 and ja_en_match < ja_en_total / 4,
		"selfcheck FAIL-as-expected: English normaliser does not satisfy the Japanese pos sentences (%d of %d)" % [ja_en_match, ja_en_total])


func _test_golden() -> void:
	print("[golden: PC check_text results for the fixed inputs]")
	var g: Dictionary = _load_golden()
	ok(not g.is_empty(), "golden file parses")
	var entries: Array = g.get("entries", []) as Array
	ok(entries.size() == 30, "30 English golden entries (%d)" % entries.size())
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
	ok(bool(ja["ok"]) and int(ja["code"]) == 200 and ja["data"]["unsupported"] == false, "GET lang=ja is 200, not unsupported (was: unsupported + message)")
	ok((ja["data"]["missions"] as Array).size() == 8 and not ja["data"].has("message"), "GET lang=ja: 8 missions, no message")
	var bad: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "fr"}, {})
	ok(not bool(bad["ok"]) and int(bad["code"]) == 400 and str(bad["err_code"]) == "bad_request", "GET lang=fr is 400")
	ok(str(bad["error"]).contains("lang"), "GET lang=fr error is Korean about lang")
	var empty_lang: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": ""}, {})
	ok(not bool(empty_lang["ok"]) and int(empty_lang["code"]) == 400, "GET lang='' is 400")

	var raw: Array = _raw_lang("en")                      # the stage filter is per language
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
	ok(not bool(cja["ok"]) and int(cja["code"]) == 404 and str(cja["error"]) == LocalMissions.UNKNOWN_MSG, "check lang=ja with an English id is 404 (was: 400 JA_MSG)")
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
	var fake_ja: Dictionary = {}                      # the same for a Japanese mission (B3-6)
	for rm in data["missions"]:
		if str((rm as Dictionary).get("lang", "en")) == "ja":
			fake_ja = (rm as Dictionary).duplicate(true)
			break
	ok(not fake_ja.is_empty(), "a Japanese mission to break is in the shipped pack")
	fake_ja["id"] = BROKEN_JA_ID
	fake_ja["order"] = 998
	(fake_ja["goals"][0]["match"] as Dictionary)["any"] = ["(?:すみません"]
	(data["missions"] as Array).append(fake_ja)

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
	dis_ids.sort()
	ok(dis_ids == [BROKEN_ID, BROKEN_JA_ID], "only the two broken missions (en, ja) are disabled (%s)" % str(dis_ids))
	ok(LocalMissions.compiled_missions().size() == 16, "the other 16 missions compile")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	ok(bool(r["ok"]) and (r["data"]["missions"] as Array).size() == 8, "GET /missions lists 8 English with the broken one left out")
	var rj: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja"}, {})
	ok(bool(rj["ok"]) and (rj["data"]["missions"] as Array).size() == 8, "GET /missions?lang=ja lists 8 Japanese with the broken one left out")
	var listed := false
	for m in (r["data"]["missions"] as Array) + (rj["data"]["missions"] as Array):
		if str(m["id"]) == BROKEN_ID or str(m["id"]) == BROKEN_JA_ID:
			listed = true
	ok(not listed, "broken missions are not listed")
	var cb: Dictionary = _check(BROKEN_ID, "hi")
	ok(not bool(cb["ok"]) and int(cb["code"]) == 404, "check on the broken mission is 404, no crash")
	var cbj: Dictionary = _check_ja(BROKEN_JA_ID, "すみません")
	ok(not bool(cbj["ok"]) and int(cbj["code"]) == 404, "check on the broken Japanese mission is 404, no crash")
	var co: Dictionary = _check("cafe_order", "Hi there", [])
	ok(bool(co["ok"]) and ("greet" in co["data"]["new"]), "other missions still check")
	var coj: Dictionary = _check_ja("ja_konbini", "これをください", [])
	ok(bool(coj["ok"]) and ("buy_item" in coj["data"]["new"]), "Japanese missions still check next to the broken one")

	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	LocalMissions.reset()
	ok(LocalMissions.compiled_missions().size() == 16 and LocalMissions.disabled_missions().is_empty(),
		"restored shipped pack: 16 usable, none disabled")


# ---------------------------------------------------------------- Japanese (v1.7.0 B3)

## True when the phone gives `want` for `text` (MissionText.norm_ja through LocalMissions.normalize).
func _ja_same(text: String, want: String) -> bool:
	return LocalMissions.normalize(text, "ja") == want


func _test_golden_ja() -> void:
	print("[golden ja: PC check_text results and normalised text of the Japanese inputs]")
	var g: Dictionary = _load_golden()
	var entries: Array = g.get("ja_entries", []) as Array
	ok(entries.size() >= 24, "at least 24 Japanese golden entries (%d)" % entries.size())
	var diff := 0
	var with_reached := 0
	var missions_seen: Dictionary = {}
	for i in entries.size():
		var e: Dictionary = entries[i]
		missions_seen[str(e["mission_id"])] = true
		var norm_ok: bool = LocalMissions.normalize(str(e["text"]), "ja") == str(e["norm"])
		var r: Dictionary = _check_ja(str(e["mission_id"]), str(e["text"]), [])
		var got: Array = _new_ids(r)
		var want: Array = []
		for gid in e["reached"]:
			want.append(str(gid))
		want.sort()
		if not e["reached"].is_empty():
			with_reached += 1
		var same: bool = bool(r["ok"]) and got == want
		if not norm_ok or not same:
			diff += 1
		ok(str(e.get("lang", "")) == "ja", "golden ja #%d has lang ja" % i)
		ok(norm_ok, "golden ja #%d normalised text (%s)" % [i, str(e["text"]).substr(0, 20)])
		ok(same, "golden ja #%d %s reached: want %s got %s" % [i, str(e["mission_id"]), str(want), str(got)])
	print("golden ja: %d entries, %d with goals reached, %d differences" % [entries.size(), with_reached, diff])
	ok(diff == 0, "golden ja: 0 differences between the PC engine and the phone")
	ok(missions_seen.size() == 8, "the Japanese golden inputs cover all 8 Japanese missions (%d)" % missions_seen.size())
	ok(with_reached >= 20, "most Japanese golden inputs reach a goal (%d), so the comparison is not empty" % with_reached)
	# selfcheck: a wrong expectation is caught by the same comparison
	var bad: Dictionary = (entries[1] as Dictionary).duplicate()
	bad["norm"] = str(bad["norm"]) + "x"
	print("  selfcheck FAIL-as-expected: a golden entry with a wrong norm is rejected")
	ok(LocalMissions.normalize(str(bad["text"]), "ja") != str(bad["norm"]), "selfcheck FAIL-as-expected: wrong golden norm is detected")


func _test_norm_ja() -> void:
	print("[MissionText.norm_ja against PC normalize_ja]")
	var g: Dictionary = _load_golden()
	var cases: Array = g.get("ja_norm_cases", []) as Array
	ok(cases.size() >= 30, "at least 30 Japanese normalize cases (%d)" % cases.size())
	var diff := 0
	for i in cases.size():
		var c: Dictionary = cases[i]
		var got: String = LocalMissions.normalize(str(c["text"]), "ja")
		if got != str(c["norm"]):
			diff += 1
		ok(got == str(c["norm"]), "ja norm case #%d: want '%s' got '%s'" % [i, str(c["norm"]), got])
	var table: Array = g.get("ja_table_cases", []) as Array
	ok(table.size() >= 500, "at least 500 Japanese table code points (%d)" % table.size())
	for t in table:
		var cp: int = int(t[0])
		var got_c: String = LocalMissions.normalize(String.chr(cp), "ja")
		if got_c != str(t[1]):
			diff += 1
		ok(got_c == str(t[1]), "ja table U+%04X: want '%s' got '%s'" % [cp, str(t[1]), got_c])
	var rnd: Array = g.get("ja_random", []) as Array
	ok(rnd.size() >= 400, "at least 400 seeded random Japanese strings (%d)" % rnd.size())
	for i in rnd.size():
		var rc: Dictionary = rnd[i]
		var got_r: String = LocalMissions.normalize(str(rc["text"]), "ja")
		if got_r != str(rc["norm"]):
			diff += 1
		ok(got_r == str(rc["norm"]), "ja random #%d (%d chars)" % [i, str(rc["text"]).length()])
	print("norm ja: %d cases, %d table code points, %d random strings, %d differences" % [cases.size(), table.size(), rnd.size(), diff])
	ok(diff == 0, "norm ja: 0 differences between normalize_ja and MissionText.norm_ja")

	print("[rules written out (B3-5): NFKC subset, the two rules outside the server docstring]")
	ok(_ja_same("ＡＢＣ　ａｂｃ１２３", "abcabc123"), "full-width letters and digits -> ASCII, U+3000 deleted")
	ok(_ja_same("ｶﾞｷﾞｸﾞ", "がぎぐ") and _ja_same("ﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ", "ぱぴぷぺぽ"), "half-width kana + voicing / semi-voicing marks compose")
	ok(_ja_same("ｳﾞ", "ゔ") and _ja_same("ｱｲｳｴｵ", "あいうえお") and _ja_same("ｰ", "ー"), "half-width ｳﾞ, ｱｲｳｴｵ, ｰ")
	ok(_ja_same("カタカナ", "かたかな") and _ja_same("ヽヾ", "ゝゞ"), "katakana fold to hiragana, ヽヾ -> ゝゞ")
	ok(_ja_same("ヷヸヹヺ", "") and _ja_same("ﾜﾞ", "") and _ja_same("ヷ", ""), "rule 2: U+30F7..30FA (and ワ + voicing mark) are deleted")
	ok(_ja_same("あ".repeat(301), "あ".repeat(300)), "301 characters -> 300 (first cut)")
	ok(LocalMissions.normalize("⑩".repeat(200), "ja").length() == 300, "rule 1: cut to 300 AGAIN after NFKC (200 x ⑩ = 400 digits -> 300)")
	ok(_ja_same("A B、C。！?", "abc") and _ja_same("ー〇々", "ー〇々") and _ja_same("😀", ""), "spaces and punctuation are deleted, ー 〇 々 are kept, emoji deleted")
	# selfcheck: the same comparison fails for a wrong expectation
	print("  selfcheck FAIL-as-expected: wrong expectations of norm_ja are rejected")
	ok(not _ja_same("ヷ", "ゔ"), "selfcheck FAIL-as-expected: ヷ is not kept")
	ok(not _ja_same("あ".repeat(301), "あ".repeat(301)), "selfcheck FAIL-as-expected: 301 characters are not kept")
	ok(not _ja_same("ｶﾞ", "かき"), "selfcheck FAIL-as-expected: wrong composition rejected")
	ok(not _ja_same("カ", "カ"), "selfcheck FAIL-as-expected: katakana is not kept as katakana")

	print("[known gaps (B3-5): NFKC results the phone does not build; the phone result must still DIFFER so the table is up to date]")
	var gaps: Array = g.get("ja_known_gaps", []) as Array
	ok(gaps.size() >= 10, "at least 10 known gaps are listed (%d)" % gaps.size())
	for c in gaps:
		var got_g: String = LocalMissions.normalize(str(c["text"]), "ja")
		var cps: String = ""
		for i in str(c["text"]).length():
			cps += "U+%04X " % str(c["text"]).unicode_at(i)
		print("  known gap: %s=> PC '%s', phone '%s'" % [cps, str(c["norm"]), got_g])
		ok(got_g != str(c["norm"]), "known gap %s still differs (PC '%s', phone '%s')" % [cps, str(c["norm"]), got_g])


func _test_response_shape_ja() -> void:
	print("[ja response shape: optional reading fields pass through, no answer rules, English unchanged]")
	var r: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja"}, {})
	var d: Dictionary = r["data"]
	ok(d.get("via") == "phone" and d.get("degraded") is Array and (d["degraded"] as Array).is_empty(), "GET /missions?lang=ja via phone, degraded []")
	var raw_by_id: Dictionary = {}
	for rm in _raw_lang("ja"):
		raw_by_id[str(rm["id"])] = rm
	var n_open_rd := 0
	var n_hint_rd := 0
	var n_line_rd := 0
	for m in d["missions"]:
		var mid: String = str(m["id"])
		var rm: Dictionary = raw_by_id.get(mid, {})
		ok(not rm.is_empty(), "%s is a shipped Japanese mission" % mid)
		if rm.is_empty():
			continue
		for k in ["id", "title_ko", "situation_ko", "min_stage", "max_turns", "opening", "goals", "scenario", "script"]:
			ok(m.has(k), "ja mission %s has key %s" % [mid, k])
		for gk in ["match", "pos", "neg", "goal_en"]:
			ok(not m.has(gk), "ja mission %s has no %s" % [mid, gk])
		for k in ["opening_rd", "opening_pr"]:
			var want_has: bool = str(rm.get(k, "")) != ""
			ok(m.has(k) == want_has and (not want_has or str(m[k]) == str(rm[k])), "ja mission %s: %s passes through when the content has it" % [mid, k])
			if want_has and m.has(k):
				n_open_rd += 1
		ok((m["goals"] as Array).size() == (rm["goals"] as Array).size(), "ja mission %s keeps all goals" % mid)
		for i in (m["goals"] as Array).size():
			var gg: Dictionary = m["goals"][i]
			var rg: Dictionary = rm["goals"][i]
			for k in ["id", "label_ko", "hint_en"]:
				ok(gg.has(k), "ja goal %s/%s has key %s" % [mid, str(gg["id"]), k])
			for gk in ["match", "pos", "neg", "goal_en"]:
				ok(not gg.has(gk), "ja goal %s/%s has no %s" % [mid, str(gg["id"]), gk])
			var want_hint: bool = str(rg.get("hint_rd", "")) != ""
			ok(gg.has("hint_rd") == want_hint and (not want_hint or str(gg["hint_rd"]) == str(rg["hint_rd"])),
				"ja goal %s/%s: hint_rd passes through when the content has it" % [mid, str(gg["id"])])
			if want_hint and gg.has("hint_rd"):
				n_hint_rd += 1
		ok((m["script"] as Array).size() == (rm["script"] as Array).size(), "ja mission %s keeps all script lines" % mid)
		for i in (m["script"] as Array).size():
			var pl: Dictionary = m["script"][i]
			var rl: Dictionary = rm["script"][i]
			ok(pl.has("ai") and pl.has("goal") and pl.has("model"), "ja script line %s #%d has ai, goal, model" % [mid, i])
			for k in ["ai_rd", "ai_pr", "model_rd", "model_pr"]:
				var wl: bool = str(rl.get(k, "")) != ""
				ok(pl.has(k) == wl and (not wl or str(pl[k]) == str(rl[k])), "ja script line %s #%d: %s passes through when the content has it" % [mid, i, k])
				if wl and pl.has(k):
					n_line_rd += 1
		var sc: Dictionary = m["scenario"]
		ok(sc.get("id") == "mission:" + mid and str(sc.get("scene", "")).contains(str(rm["opening"]).strip_edges()), "ja scenario of %s has its id and the opening in the scene" % mid)
	print("  ja optional fields seen: opening %d, hint_rd %d, script readings %d" % [n_open_rd, n_hint_rd, n_line_rd])
	ok(n_open_rd > 0 and n_hint_rd > 0 and n_line_rd > 0, "the shipped Japanese content has reading fields and they pass through")
	var txt: String = JSON.stringify(d)
	ok(not txt.contains("\"match\"") and not txt.contains("\"pos\"") and not txt.contains("\"neg\"") and not txt.contains("\"goal_en\""),
		"GET /missions?lang=ja JSON has no match/pos/neg/goal_en key")
	# English output has none of the Japanese-only keys
	var en: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "en"}, {})
	var etxt: String = JSON.stringify(en["data"])
	var clean := true
	for k in ["opening_rd", "opening_pr", "hint_rd", "ai_rd", "ai_pr", "model_rd", "model_pr"]:
		if etxt.contains("\"" + k + "\""):
			clean = false
	ok(clean, "the English list has none of the Japanese-only keys (same shape as before)")


func _test_check_semantics_ja() -> void:
	print("[ja check: new, done, all_done, width and kana variants]")
	var r1: Dictionary = _check_ja("ja_konbini", "これをください", [])
	ok(bool(r1["ok"]) and int(r1["code"]) == 200 and r1["data"]["mission_id"] == "ja_konbini", "ja check ok 200")
	ok("buy_item" in r1["data"]["new"], "これをください -> buy_item")
	ok(_new_ids(_check_ja("ja_konbini", "コレヲクダサイ")) == _new_ids(r1), "katakana-only input gives the same goals")
	ok("buy_item" in _new_ids(_check_ja("ja_konbini", "ｺﾚｦｸﾀﾞｻｲ")), "half-width katakana input reaches buy_item")
	ok(_new_ids(_check_ja("ja_konbini", "これをください！　")) == _new_ids(r1), "punctuation and ideographic space do not change the result")
	var r2: Dictionary = _check_ja("ja_konbini", "これをください", ["buy_item"])
	var bi_done := false
	var bi_new := true
	for gg in r2["data"]["goals"]:
		if gg["id"] == "buy_item":
			bi_done = bool(gg["done"])
			bi_new = bool(gg["new"])
	ok(bi_done and not bi_new and (r2["data"]["new"] as Array).is_empty(), "ja: already done goal is done, not new")
	var r3: Dictionary = _check_ja("ja_konbini", "これをください", ["zzz_unknown", 5, "buy_item"])
	var ids3: Array = []
	for gg in r3["data"]["goals"]:
		ids3.append(str(gg["id"]))
	ok(bool(r3["ok"]) and ids3.size() == 5 and not ("zzz_unknown" in ids3), "ja: unknown and non-string done ids are ignored (5 goals)")
	var all_ids: Array = []
	for gg in r1["data"]["goals"]:
		all_ids.append(str(gg["id"]))
	var r4: Dictionary = _check_ja("ja_konbini", "x", all_ids)
	ok(bool(r4["data"]["all_done"]) and (r4["data"]["new"] as Array).is_empty(), "ja: all goals done -> all_done true")
	ok(not bool(r1["data"]["all_done"]), "ja: one goal -> all_done false")
	# every Japanese mission: the model line of each script line reaches its own goal through the phone
	var scripted := 0
	for m in LocalMissions.compiled_missions():
		if str(m["lang"]) != "ja":
			continue
		for line in m["script"]:
			scripted += 1
			var rr: Dictionary = _check_ja(str(m["id"]), str(line["model"]), [])
			ok(str(line["goal"]) in _new_ids(rr), "ja script model reaches its goal: %s / %s" % [str(m["id"]), str(line["goal"])])
	ok(scripted >= 30, "checked the script lines of the Japanese missions (%d)" % scripted)


func _test_errors_ja() -> void:
	print("[ja errors, stage filter, odd inputs (B3-7)]")
	var raw: Array = _raw_lang("ja")
	var n1 := 0
	var n2 := 0
	for m in raw:
		if int(m["min_stage"]) <= 1:
			n1 += 1
		if int(m["min_stage"]) <= 2:
			n2 += 1
	ok(n1 > 0 and n2 > n1 and n2 < raw.size(), "Japanese content has missions at several stages (%d, %d of %d)" % [n1, n2, raw.size()])
	var s1: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja", "stage": "1"}, {})
	ok((s1["data"]["missions"] as Array).size() == n1, "ja stage=1 gives %d missions" % n1)
	var s2: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja", "stage": "2"}, {})
	ok((s2["data"]["missions"] as Array).size() == n2, "ja stage=2 gives %d missions" % n2)
	var s4: Dictionary = LocalMissions.handle("GET", "/missions", {"lang": "ja", "stage": "4"}, {})
	ok((s4["data"]["missions"] as Array).size() == raw.size(), "ja stage=4 gives all %d" % raw.size())
	# ids of the other language are unknown (404), both ways
	var e1: Dictionary = _check_ja("cafe_order", "すみません")
	ok(not bool(e1["ok"]) and int(e1["code"]) == 404 and str(e1["error"]) == LocalMissions.UNKNOWN_MSG, "lang=ja + English id is 404")
	var e2: Dictionary = _check("ja_konbini", "Hi")
	ok(not bool(e2["ok"]) and int(e2["code"]) == 404 and str(e2["error"]) == LocalMissions.UNKNOWN_MSG, "lang=en + Japanese id is 404")
	var e3: Dictionary = _check_ja("nope_mission", "すみません")
	ok(int(e3["code"]) == 404, "lang=ja + unknown id is 404")
	# odd inputs: 400 or no goal reached, never an error
	var odd: Array = [
		["empty", ""],
		["spaces only", "   "],
		["ideographic spaces only", "　　　"],
		["tab and newline only", "\t\n"],
		["10000 characters", "あ".repeat(10000)],
		["English sentence", "Hello, I would like some water, please."],
		["emoji only", "😀👍🎌"],
		["control characters", "\u0001\u0002\u0003\u007f"],
		["punctuation only", "、。！？「」"],
		["Korean only", "안녕하세요"],
	]
	for o in odd:
		var res: Dictionary = _check_ja("ja_konbini", str(o[1]), [])
		var rejected: bool = (not bool(res["ok"])) and int(res["code"]) == 400
		var no_goal: bool = bool(res["ok"]) and (res["data"]["new"] as Array).is_empty()
		print("  selfcheck FAIL-as-expected: %s -> %s" % [str(o[0]), "400" if rejected else "ok, no goal reached"])
		ok(rejected or no_goal, "selfcheck FAIL-as-expected: ja %s is 400 or reaches no goal" % str(o[0]))
	for bad in [5, null, ["すみません"], {"a": 1}, true]:
		var rb: Dictionary = LocalMissions.handle("POST", "/missions/check", {}, {"lang": "ja", "mission_id": "ja_konbini", "text": bad, "done": []})
		print("  selfcheck FAIL-as-expected: ja text of type %d -> %s" % [typeof(bad), str(rb["code"])])
		ok(not bool(rb["ok"]) and int(rb["code"]) == 400, "selfcheck FAIL-as-expected: ja non-string text (type %d) is 400" % typeof(bad))
	var rn: Dictionary = LocalMissions.handle("POST", "/missions/check", {}, {"lang": "ja", "mission_id": "ja_konbini"})
	ok(int(rn["code"]) == 400, "ja missing text is 400")
	var rd: Dictionary = LocalMissions.handle("POST", "/missions/check", {}, {"lang": "ja", "mission_id": "ja_konbini", "text": "これをください", "done": "buy_item"})
	ok(bool(rd["ok"]) and "buy_item" in rd["data"]["new"], "ja: `done` that is not an array is ignored")
	var lt: Dictionary = _check_ja("ja_konbini", "あ".repeat(20001))
	ok(not bool(lt["ok"]) and int(lt["code"]) == 400, "ja: 20,001 characters is 400")
	ok(LocalMissions.is_available(), "still available after the Japanese error cases")
