extends Node
## Phone remote mode: Api token header, RemoteLink pairing, Backend remote start, Recorder (desktop --phone),
## discovery, retry, ConnectView, PhoneLinkPanel (docs/android_remote_design.md §9.2, R-01..R-15).
##
##   phone:  godot --headless --path <project> res://tests/remote_test.tscn -- --phone
##   pc:     godot --headless --path <project> res://tests/remote_test.tscn          (PC mode must not change)
##
## By default everything runs against an in-process fake PC (two listeners like the real server: an admin
## listener without token = 127.0.0.1:8770's role, and a LAN listener that needs the bearer token).
## To check the real thing, point the pairing tests at the backend stub of W1 instead:
##   -- --phone --stub-admin=http://127.0.0.1:8830 --stub-lan=http://127.0.0.1:8840 --stub-udp=8841
## (tests that need the fake's request log / fault injection are then reported as SKIP, not as PASS.)
## Exit code 0 = all checks passed. Tokens and pairing codes are never printed.

const ADMIN_PORT := 8850
const LAN_PORT := 8851
const UDP_PORT := 8852
const CLOSED_PORT := 8859
const TEST_REMOTE := "user://test_remote.json"

var passed: int = 0
var failed: int = 0
var skipped: int = 0
var fake: FakeLan = null
var admin_url: String = ""
var lan_url: String = ""
var udp_port: int = UDP_PORT
var phone: bool = false
var _saved_remote_path: String = ""
var _orphan_url: String = ""
var _orphan_mode: String = "cancel"   ## cancel | inflight | none


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func skip(name: String) -> void:
	skipped += 1
	print("  SKIP  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_for(cond: Callable, timeout_sec: float = 5.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _ready() -> void:
	phone = Platform.is_phone()
	print("== remote test start (%s) ==" % ("phone" if phone else "pc"))
	_parse_args()
	if _orphan_url != "":
		await _quit_with_request()
		return
	_saved_remote_path = Api.remote_path
	_use_test_curriculum_path()
	Api.remote_path = TEST_REMOTE
	_cleanup_files()
	RemoteLink.test_discovery_port = udp_port
	RemoteLink.test_extra_targets = ["127.0.0.1"]
	if fake == null and admin_url == "":
		fake = FakeLan.new()
		add_child(fake)
		var started: bool = fake.start(ADMIN_PORT, LAN_PORT, UDP_PORT)
		ok(started, "in-process fake PC listening (ports %d/%d/%d)" % [ADMIN_PORT, LAN_PORT, UDP_PORT])
		if not started:
			_finish()
			return
		admin_url = "http://127.0.0.1:%d" % ADMIN_PORT
		lan_url = "http://127.0.0.1:%d" % LAN_PORT
	if phone:
		await _phone_tests()
	else:
		await _pc_tests()
	_finish()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stub-admin="):
			admin_url = a.substr(13).rstrip("/")
		elif a.begins_with("--stub-lan="):
			lan_url = a.substr(11).rstrip("/")
		elif a.begins_with("--stub-udp="):
			udp_port = int(a.substr(11))
		elif a.begins_with("--orphan-quit="):
			_orphan_url = a.substr(14).rstrip("/")
		elif a.begins_with("--orphan-mode="):
			_orphan_mode = a.substr(14)


func _finish() -> void:
	if fake != null:
		fake.stop()
	_cleanup_files()
	_drop_test_curriculum_path()
	Api.remote_path = _saved_remote_path
	print("== remote test: %d passed, %d failed ==" % [passed, failed])
	if skipped > 0:
		print("   (%d skipped)" % skipped)
	get_tree().quit(1 if failed > 0 else 0)


func _cleanup_files() -> void:
	for f in [TEST_REMOTE, TEST_REMOTE + ".tmp"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


# ---------------------------------------------------------------- helpers talking to the (fake or stub) PC

func _admin_post(path: String, body: Dictionary) -> Dictionary:
	return await Api.post_json_to(admin_url, path, body, 5.0, false).wait()


func _admin_get(path: String) -> Dictionary:
	return await Api.get_json_to(admin_url, path, 5.0, false).wait()


## Turns the phone link on and returns the current pairing code ("" if none). Never printed.
func _open_pairing(new_code: bool = true) -> String:
	var r: Dictionary = await _admin_post("/lan", {"enabled": true})
	if not r["ok"]:
		return ""
	if new_code:
		await _admin_post("/lan/code", {})
	var st: Dictionary = await _admin_get("/lan")
	if st["ok"] and st["data"] is Dictionary:
		var p: Variant = (st["data"] as Dictionary).get("pairing", {})
		if p is Dictionary and (p as Dictionary).get("code", null) != null:
			return str((p as Dictionary)["code"])
	return ""


func _revoke_all() -> void:
	await _admin_post("/lan/devices/revoke", {"all": true})


## Pairs a new fake phone; returns the connection dictionary ({} on failure).
func _pair_new(device_name: String = "Test Phone") -> Dictionary:
	var code: String = await _open_pairing(true)
	var pr: Dictionary = await RemoteLink.pair(lan_url, code, device_name)
	if not pr["ok"]:
		return {}
	return {"base_url": lan_url, "token": pr["token"], "device_id": pr["device_id"], "server_name": pr["server_name"]}


func _reset_backend() -> void:
	Backend.status = Backend.Status.IDLE
	Backend.message = ""
	Backend.health = {}
	Backend._starting = false
	Backend._fail_streak = 0


func _write_raw(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- quit with a request that never gets an answer

## Reproducible quit timing (run it against a server that accepts and never answers, see the report):
##   godot --headless --path <project> res://tests/remote_test.tscn -- --phone --orphan-quit=http://127.0.0.1:8853 --orphan-mode=cancel
## Prints QUIT_CALLED <msec> right before quit(); the caller measures how long the process lives after that.
## modes: cancel = the request is cancelled first (orphan), inflight = still running, none = no request at all.
func _quit_with_request() -> void:
	if _orphan_mode != "none":
		Api.set_remote(_orphan_url, "hp1_" + "T".repeat(43))
		var c = Api.post_json("/chat", {"lang": "en"}, Api.TIMEOUT_LLM, false)
		await get_tree().create_timer(0.6).timeout
		if _orphan_mode == "cancel":
			c.cancel()
			print("cancelled; orphans=", Api.orphan_count)
	print("QUIT_CALLED ", Time.get_ticks_msec())
	get_tree().quit()


# ---------------------------------------------------------------- PHONE

func _phone_tests() -> void:
	ok(Platform.is_phone() and not Platform.is_android(), "Platform: desktop --phone")
	ok(Backend.remote_mode, "Backend.remote_mode is true in phone mode")
	_test_parse_address()
	_test_proof_vector()
	await _test_hello_pair_headers()
	await _test_wrong_codes()
	await _test_backend_paths()
	await _test_rediscovery()
	await _test_saved_token_stays_home()
	await _test_not_connected()
	await _test_auth_revoked()
	await _test_discovery()
	await _test_retry()
	await _test_recorder_desktop_phone()
	await _test_pause_resume()
	await _test_connect_view()
	await _test_view_closed_midway()


func _test_parse_address() -> void:
	print("[parse_address]")
	var a: Dictionary = RemoteLink.parse_address("192.168.0.12")
	ok(a["ok"] and int(a["port"]) == 8775 and a["base_url"] == "http://192.168.0.12:8775", "ip only -> port 8775")
	a = RemoteLink.parse_address("192.168.0.12:9000")
	ok(a["ok"] and int(a["port"]) == 9000 and a["host"] == "192.168.0.12", "ip:port")
	a = RemoteLink.parse_address("http://192.168.0.12:8775/")
	ok(a["ok"] and a["base_url"] == "http://192.168.0.12:8775", "http:// prefix and trailing slash are normalized")
	a = RemoteLink.parse_address("  10.0.0.5  ")
	ok(a["ok"] and a["base_url"] == "http://10.0.0.5:8775", "surrounding spaces are ignored")
	var bad: Array = ["", "abc", "999.1.1.1", "192.168.0.12:99999", ":80", "mypc.local", "192.168.0.12:abc", "192.168.0.12:0", "192.168.0.12:", "1.2.3", "1.2.3.4.5", "192.168.0.12/x", "https://192.168.0.12", "192.168.0.12:80:90", "-1.2.3.4", "192.168.0.12 :80", "192.168.0.1234"]
	var all_bad := true
	var all_kr := true
	for b in bad:
		var r: Dictionary = RemoteLink.parse_address(str(b))
		if r["ok"]:
			all_bad = false
			print("    accepted: '%s'" % b)
		if not str(r["error"]).contains("주소를 확인해 주세요"):
			all_kr = false
	ok(all_bad, "wrong addresses are rejected (%d cases)" % bad.size())
	ok(all_kr, "every rejection carries the Korean address help text")


func _test_proof_vector() -> void:
	print("[proof vector]")
	# python: hmac.new(hashlib.sha256(token).digest(), nonce, sha256).hexdigest()
	var tok := "hp1_" + "A".repeat(43)
	var got: String = RemoteLink.expected_proof(tok, "abcd1234")
	ok(got.length() == 64, "HMAC proof has 64 hex chars")
	ok(got == PROOF_VECTOR, "HMAC proof equals the Python reference vector")


const PROOF_VECTOR := "7957500bc3fffcb60058ceb1a888b7f1bcc6e63fcb21d7d7a13252898cbefd12"


func _test_hello_pair_headers() -> void:
	print("[hello / pair / headers]")
	var code: String = await _open_pairing(true)
	ok(code.length() == 6, "PC shows a 6 digit code after turning the link on")
	# Api already holds a token (the re-discovery path asks an unverified address while the saved token is set):
	# the pre-pairing calls must still go out WITHOUT Authorization
	Api.set_remote("http://127.0.0.1:%d" % CLOSED_PORT, "hp1_" + "C".repeat(43))
	var hi: Dictionary = await RemoteLink.hello(lan_url)
	ok(hi["ok"] and str(hi["name"]) != "" and bool(hi["pairing_open"]), "hello: name + pairing_open")
	var hi_bad: Dictionary = await RemoteLink.hello("http://127.0.0.1:%d" % CLOSED_PORT)
	ok(not hi_bad["ok"] and str(hi_bad["error"]).contains("PC에 닿지 않아요"), "hello on a closed port -> Korean unreachable text")
	var pr: Dictionary = await RemoteLink.pair(lan_url, code, "Pixel Test")
	var tok: String = str(pr.get("token", ""))
	ok(pr["ok"] and tok.begins_with("hp1_") and tok.length() == 47 and str(pr["device_id"]) != "", "pair ok -> hp1_ token (47 chars) + device id")
	var conn := {"base_url": lan_url, "token": tok, "device_id": pr["device_id"], "server_name": pr["server_name"]}
	# R-04: file
	ok(RemoteLink.save(conn, TEST_REMOTE), "RemoteLink.save writes the file")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEST_REMOTE))
	ok(raw is Dictionary and (raw as Dictionary).has("base_url") and (raw as Dictionary).has("token") and (raw as Dictionary).has("device_id") and (raw as Dictionary).has("server_name"), "remote.json has base_url, token, device_id, server_name")
	var back: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(back.get("token", "")) == tok and back.get("base_url", "") == lan_url, "load_saved returns what was saved")
	RemoteLink.clear_token(TEST_REMOTE)
	var cleared: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(cleared.get("token", "x")) == "" and cleared.get("base_url", "") == lan_url and cleared.get("server_name", "") == conn["server_name"], "clear_token keeps address and PC name, drops only the token")
	# proof
	ok(await RemoteLink.proof_ok(lan_url, conn), "proof_ok: the PC knows our token")
	var direct: Dictionary = await Api.get_json_to(lan_url, "/hello", 5.0, false).wait()
	var direct2: Dictionary = await Api.post_json_to(lan_url, "/lan/proof", {"device_id": "x", "nonce": "00"}, 5.0, false).wait()
	ok(direct["ok"] and int(direct2["code"]) > 0, "get_json_to / post_json_to work while Api.token is set")
	if fake != null:
		ok(not fake.auth_seen("/hello") and not fake.auth_seen("/pair") and not fake.auth_seen("/lan/proof"), "3a: hello / pair / proof / get_json_to / post_json_to never send Authorization even though Api.token is set")
	else:
		skip("3a Authorization check needs the in-process fake request log")
	Api.clear_remote()
	var wrong := conn.duplicate()
	wrong["token"] = "hp1_" + "B".repeat(43)
	ok(not await RemoteLink.proof_ok(lan_url, wrong), "proof_ok is false for another token")
	var wrong_dev := conn.duplicate()
	wrong_dev["device_id"] = "ffffffff"
	ok(not await RemoteLink.proof_ok(lan_url, wrong_dev), "proof_ok is false for an unknown device id")
	# R-03: Authorization header only on normal requests
	Api.set_remote(lan_url, tok)
	var h: Dictionary = await Api.get_json("/health", 5.0, false).wait()
	ok(h["ok"], "authorized GET /health through the LAN listener")
	var forb: Dictionary = await Api.post_json("/mic/start", {}, 5.0, false).wait()
	ok(not forb["ok"] and int(forb["code"]) == 403 and str(forb["err_code"]) == "lan_forbidden", "/mic/start is forbidden on the LAN (403 lan_forbidden, err_code kept)")
	if fake != null:
		ok(fake.last_entry("/health").get("bearer", false) == true, "R-03 normal request carries 'Authorization: Bearer hp1_...'")
		ok(fake.last_entry("/hello").get("auth", true) == false and fake.last_entry("/pair").get("auth", true) == false and fake.last_entry("/lan/proof").get("auth", true) == false, "R-03 hello / pair / proof carry no Authorization header")
	else:
		skip("R-03 raw header check needs the in-process fake")
	Api.clear_remote()
	ok(Api.token == "" and Api.base_url == "", "clear_remote: phone has no address and no token")


func _test_wrong_codes() -> void:
	print("[wrong codes]")
	await _revoke_all()
	var code: String = await _open_pairing(true)
	var n: int = (int(code) + 1) % 1000000
	var wrong: String = "%06d" % n
	var lefts: Array = []
	var texts_ok := true
	for i in 5:
		var r: Dictionary = await RemoteLink.pair(lan_url, wrong, "Test Phone")
		lefts.append(int(r.get("attempts_left", -9)))
		if r["ok"] or str(r["err_code"]) != "code_invalid" or not str(r["error"]).contains("남은 기회"):
			texts_ok = false
	ok(texts_ok, "R-05: 5 wrong codes -> code_invalid + 'remaining tries' text")
	ok(lefts == [4, 3, 2, 1, 0], "R-05: attempts_left counts down 4,3,2,1,0 (got %s)" % str(lefts))
	var r6: Dictionary = await RemoteLink.pair(lan_url, wrong, "Test Phone")
	ok(not r6["ok"] and str(r6["err_code"]) == "pair_locked" and str(r6["error"]).contains("잠겼어요"), "R-05: 6th try -> pair_locked text")
	var r7: Dictionary = await RemoteLink.pair(lan_url, code, "Test Phone")
	ok(not r7["ok"] and str(r7["err_code"]) == "pair_locked", "R-05: even the right code is refused while locked")
	var short: Dictionary = await RemoteLink.pair(lan_url, "12345", "Test Phone")
	ok(not short["ok"] and str(short["err_code"]) == "code_format" and str(short["error"]).contains("6자리"), "5 digit code -> code_format without asking the PC")
	var letters: Dictionary = await RemoteLink.pair(lan_url, "12a456", "Test Phone")
	ok(not letters["ok"] and str(letters["err_code"]) == "code_format", "code with a letter -> code_format")
	ok(RemoteLink.normalize_code("482 913") == "482913" and RemoteLink.normalize_code("482-913") == "482913" and RemoteLink.normalize_code("48291") == "", "code input: spaces / hyphens removed, length checked")
	var code2: String = await _open_pairing(true)
	var good: Dictionary = await RemoteLink.pair(lan_url, code2, "Test Phone")
	ok(good["ok"], "a new code unlocks pairing")
	var again: Dictionary = await RemoteLink.pair(lan_url, code2, "Test Phone")
	ok(not again["ok"] and (str(again["err_code"]) == "no_active_code") and str(again["error"]).contains("PC에서 새 코드"), "a used code is refused (no_active_code text)")
	var hi_closed: Dictionary = await RemoteLink.hello(lan_url)
	ok(hi_closed["ok"] and not bool(hi_closed["pairing_open"]), "hello shows pairing_open=false when there is no code")


func _test_backend_paths() -> void:
	print("[Backend.start paths]")
	# (a) saved connection, PC reachable
	var conn: Dictionary = await _pair_new("Backend Phone")
	ok(not conn.is_empty(), "paired a fake phone for the Backend test")
	RemoteLink.save(conn, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	var t0: int = Time.get_ticks_msec()
	await Backend.start()
	var dt: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(Backend.status == Backend.Status.READY and dt <= 5.0, "R-07a: saved connection -> READY in %.2f s" % dt)
	ok(Backend.pid == -1 and not Backend.launched_by_us, "R-07a: no process was created (pid -1, launched_by_us false)")
	ok(Api.base_url == lan_url and Api.token == str(conn["token"]), "R-07a: Api points at the paired PC with its token")
	# (b) closed port (the PC does not answer discovery either, so there is nothing to find)
	await _admin_post("/lan", {"discovery": false})
	var dead := conn.duplicate()
	dead["base_url"] = "http://127.0.0.1:%d" % CLOSED_PORT
	RemoteLink.save(dead, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	t0 = Time.get_ticks_msec()
	await Backend.start()
	dt = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(Backend.status == Backend.Status.FAILED and dt <= 10.0 and Backend.message.contains("PC에 닿지 않아요"), "R-07b: closed port -> FAILED in %.2f s with the 'PC에 닿지 않아요' text" % dt)
	ok(Backend.pid == -1 and not Backend.launched_by_us, "R-07b: no process was created")
	await _admin_post("/lan", {"discovery": true})
	# (c) no file
	_cleanup_files()
	Api.clear_remote()
	_reset_backend()
	var sent_before: int = Api.sent_count
	var log_before: int = fake.log.size() if fake != null else 0
	t0 = Time.get_ticks_msec()
	await Backend.start()
	dt = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(Backend.status == Backend.Status.NEEDS_PAIRING and dt < 1.0, "R-07c: no saved connection -> NEEDS_PAIRING at once (%.2f s)" % dt)
	ok(Api.sent_count == sent_before, "R-07c: no HTTP request was created")
	if fake != null:
		ok(fake.log.size() == log_before, "R-07c: the fake PC received 0 requests")
	else:
		skip("R-07c fake PC request count")
	ok(Backend.pid == -1 and not Backend.launched_by_us, "R-07c: no process was created")
	# (d) broken files
	var broken: Array = ["{not json", "[]", "\"x\"", "{\"base_url\": 5, \"token\": \"x\"}", "{\"base_url\": \"javascript:alert(1)\", \"token\": \"hp1_x\"}", "{\"base_url\": \"http://192.168.0.12:8775\", \"token\": 7}", ""]
	var all_pairing := true
	for b in broken:
		_write_raw(TEST_REMOTE, str(b))
		Api.clear_remote()
		_reset_backend()
		await Backend.start()
		if Backend.status != Backend.Status.NEEDS_PAIRING:
			all_pairing = false
			print("    not NEEDS_PAIRING for: ", str(b).left(40))
	ok(all_pairing, "R-07d: %d broken remote.json variants -> NEEDS_PAIRING, no crash" % broken.size())
	ok(RemoteLink.load_saved("user://does_not_exist_remote.json").is_empty(), "missing file -> {}")
	_cleanup_files()


func _test_rediscovery() -> void:
	print("[re-discovery of a moved PC]")
	if fake == null:
		skip("3b needs two in-process fake PCs")
		return
	var lan2_port := 8854
	var impostor := FakeLan.new()
	add_child(impostor)
	ok(impostor.start(0, lan2_port, 0), "second fake PC (same name, other address) listening")
	impostor._set_lan(true)
	var conn: Dictionary = await _pair_new("Moved Phone")
	var dead := conn.duplicate()
	dead["base_url"] = "http://127.0.0.1:%d" % CLOSED_PORT   # the PC moved: the saved address is dead
	fake.udp_reply_port = lan2_port                           # discovery now points at the other PC
	fake.udp_mode = "on"
	# 3b-1: the PC that answers has the same name but does not know our token -> refused, token never sent
	RemoteLink.save(dead, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	await Backend.start()
	ok(Backend.status == Backend.Status.FAILED and Backend.message.contains("PC에 닿지 않아요"), "3b: same-name PC that cannot prove the token -> FAILED, not connected")
	ok(impostor.count("/lan/proof") == 1, "3b: the unverified PC was asked for a proof (/lan/proof)")
	ok(not impostor.auth_seen() and impostor.count("/health") == 0, "3b: the saved token was NEVER sent to the unverified PC (no Authorization, no /health)")
	ok(RemoteLink.load_saved(TEST_REMOTE).get("base_url", "") == dead["base_url"], "3b: the saved address was not replaced")
	# 3b-2: the same PC really moved (it knows the device) -> accepted, address updated
	for d in fake.devices:
		if d["id"] == str(conn["device_id"]):
			impostor.devices.append(d.duplicate())
	impostor.reset_log()
	Api.clear_remote()
	_reset_backend()
	await Backend.start()
	ok(Backend.status == Backend.Status.READY and Api.base_url == "http://127.0.0.1:%d" % lan2_port, "3b: a PC that proves the token is accepted at its new address")
	ok(RemoteLink.load_saved(TEST_REMOTE).get("base_url", "") == "http://127.0.0.1:%d" % lan2_port, "3b: the new address is saved")
	ok(impostor.last_entry("/lan/proof").get("auth", true) == false and impostor.last_entry("/health").get("bearer", false) == true, "3b: proof without a token first, /health with it only afterwards")
	await _wait_for(func() -> bool: return Api.active_count == 0, 5.0)   # (/curriculum after READY) before the server goes away
	impostor.stop()
	impostor.queue_free()
	fake.udp_reply_port = 0
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()
	# 3c: an answer with an extra key from a different socket is not a PC
	fake.udp_mode = "other_garbage"
	var found: Array = await RemoteLink.discover(get_tree(), 1.2)
	ok(found.is_empty(), "3c: extra-key discovery answer from a different ip:port is rejected")
	fake.udp_mode = "on"
	found = await RemoteLink.discover(get_tree())
	ok(found.size() == 1, "3c control: a proper answer is still found")


func _test_saved_token_stays_home() -> void:
	print("[--api= must not receive the saved token]")
	if fake == null:
		skip("needs the in-process fake request log")
		return
	var other := FakeLan.new()
	add_child(other)
	other.start(0, 8854, 0)
	other._set_lan(true)
	var conn: Dictionary = await _pair_new("Home Phone")
	RemoteLink.save(conn, TEST_REMOTE)
	var was_over: String = Api.cli_base_url
	var was_cli: String = Api.cli_token
	Api.cli_base_url = "http://127.0.0.1:8854"   # --api= points somewhere else than the pairing
	Api.cli_token = ""
	_reset_backend()
	await Backend.start()
	ok(Backend.status == Backend.Status.NEEDS_PAIRING, "--api= differs from the saved address and no --token= -> NEEDS_PAIRING")
	ok(other.log.is_empty(), "the saved token (and any request) never reached the --api= address")
	Api.cli_token = "hp1_" + "K".repeat(43)
	_reset_backend()
	await Backend.start()
	ok(other.auth_seen("/health"), "an explicit --token= is sent to the --api= address")
	await _wait_for(func() -> bool: return Api.active_count == 0, 5.0)
	Api.cli_base_url = was_over
	Api.cli_token = was_cli
	other.stop()
	other.queue_free()
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()


func _test_not_connected() -> void:
	print("[not connected]")
	Api.clear_remote()
	await _frames(30)
	if fake != null:
		fake.reset_log()
	var before: int = Api.sent_count
	var t0: int = Time.get_ticks_msec()
	var r: Dictionary = await Api.get_json("/health", 3.0, false).wait()
	var r2: Dictionary = await Api.post_json("/mic/start", {}, 3.0, false).wait()
	var dt: int = Time.get_ticks_msec() - t0
	ok(not r["ok"] and str(r["error"]).contains("연결되지 않았어요") and str(r["err_code"]) == "not_connected", "R-08: request before pairing fails with the Korean 'not connected' text")
	ok(not r2["ok"] and Api.sent_count == before and dt < 500, "R-08: no HTTPRequest created, returned in %d ms" % dt)
	ok(Api.base_url == "" and Api.active_count == 0, "R-08: phone Api has no base_url (never 127.0.0.1:8770), nothing in flight (base '%s', active %d)" % [Api.base_url, Api.active_count])
	if fake != null:
		ok(fake.count("/health") + fake.count("/mic/start") >= 0 and fake.count("/mic/start") == 0, "R-08: the fake saw no /mic/start")


func _test_auth_revoked() -> void:
	print("[revoked pairing]")
	var conn: Dictionary = await _pair_new("Revoked Phone")
	RemoteLink.save(conn, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	await Backend.start()
	ok(Backend.status == Backend.Status.READY, "R-06: connected before the PC revokes this phone")
	var hits: Array = []
	var cb := func(code: String) -> void: hits.append(code)
	Api.auth_failed.connect(cb)
	await _revoke_all()
	var c1 = Api.get_json("/curriculum", 5.0, false)
	var c2 = Api.get_json("/curriculum", 5.0, false)
	var r1: Dictionary = await c1.wait()
	var r2: Dictionary = await c2.wait()
	await _frames(3)
	Api.auth_failed.disconnect(cb)
	ok(not r1["ok"] and int(r1["code"]) == 401 and str(r1["err_code"]) == "token_invalid", "R-06: revoked token -> 401 token_invalid (err_code)")
	ok(hits.size() == 1, "R-06: auth_failed is emitted exactly once for two failing requests (got %d)" % hits.size())
	ok(Backend.status == Backend.Status.NEEDS_PAIRING and Backend.message.contains("해제됐어요"), "R-06: Backend goes to NEEDS_PAIRING with the Korean 'revoked' text")
	var left: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(left.get("token", "x")) == "" and left.get("base_url", "") == lan_url and str(left.get("server_name", "")) != "", "R-06: token removed from the file, base_url and PC name kept")
	ok(Api.token == "" and Api.base_url == "", "R-06: Api forgot the dead token (no more requests with it)")
	_cleanup_files()


func _test_discovery() -> void:
	print("[discovery]")
	await _open_pairing(false)
	var t0: int = Time.get_ticks_msec()
	var found: Array = await RemoteLink.discover(get_tree())
	var dt: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(found.size() == 1 and str(found[0]["name"]) != "" and int(found[0]["port"]) == int(lan_url.get_slice(":", 2)), "R-09: discovery on -> 1 PC with name and port (%.2f s)" % dt)
	if found.size() == 1:
		ok(str(found[0]["base_url"]) == "http://127.0.0.1:%d" % int(found[0]["port"]), "R-09: base_url is built from the packet's sender address")
	if fake != null:
		fake.udp_mode = "garbage"
		found = await RemoteLink.discover(get_tree(), 1.2)
		ok(found.is_empty(), "malformed answers (extra key / wrong op / bad port / not JSON) are ignored")
		fake.udp_mode = "off"
	else:
		skip("malformed discovery answers need the in-process fake")
	# discovery off: ask the PC to stop answering
	var off: Dictionary = await _admin_post("/lan", {"discovery": false})
	ok(off["ok"], "turned discovery off on the PC")
	t0 = Time.get_ticks_msec()
	found = await RemoteLink.discover(get_tree())
	dt = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(found.is_empty() and dt < 3.5, "R-09: discovery off -> [] and the call returned in %.2f s (< 3.5)" % dt)
	await _admin_post("/lan", {"discovery": true})
	if fake != null:
		fake.udp_mode = "on"


func _test_retry() -> void:
	print("[retry]")
	var conn: Dictionary = await _pair_new("Retry Phone")
	Api.set_remote(lan_url, str(conn["token"]))
	if fake == null:
		skip("R-10 automatic retry needs fault injection of the in-process fake")
		Api.clear_remote()
		return
	fake.reset_log()
	fake.drop["/stt"] = 1
	var r: Dictionary = await Api.post_json("/stt", {"lang": "en", "audio_b64": "AAAA"}, 10.0, false).wait()
	ok(r["ok"] and fake.count("/stt") == 2, "R-10: /stt dropped once -> retried once and ok (requests: %d)" % fake.count("/stt"))
	fake.reset_log()
	fake.drop["/chat"] = 1
	r = await Api.post_json("/chat", {"lang": "en"}, 10.0, false).wait()
	ok(not r["ok"] and fake.count("/chat") == 1, "R-10: /chat dropped once -> NOT retried (requests: %d)" % fake.count("/chat"))
	ok(str(r["error"]).contains("PC에 닿지 않아요"), "R-10: transport failure shows the phone text 'PC에 닿지 않아요'")
	fake.reset_log()
	fake.drop["/score"] = 2
	r = await Api.post_json("/score", {"lang": "en"}, 10.0, false).wait()
	ok(not r["ok"] and fake.count("/score") == 2, "R-10: dropped twice -> only one retry (requests: %d)" % fake.count("/score"))
	fake.reset_log()
	fake.drop["/health"] = 1
	r = await Api.get_json("/health", 10.0, false).wait()
	ok(r["ok"] and fake.count("/health") == 2, "R-10: a GET is retried too")
	fake.reset_log()
	fake.drop["/lesson"] = 1
	r = await Api.post_json("/lesson", {"lang": "en"}, 10.0, false).wait()
	ok(not r["ok"] and fake.count("/lesson") == 1, "R-10: /lesson is not retried")
	fake.reset_log()
	fake.drop["/reading/analyze"] = 1
	r = await Api.post_json("/reading/analyze", {"lang": "en", "text": "x"}, 10.0, false).wait()
	ok(r["ok"] and fake.count("/reading/analyze") == 2, "R-10: /reading/analyze is retried")
	# cancel while the retry is waiting must not crash
	fake.reset_log()
	fake.drop["/tts"] = 1
	var c = Api.post_json("/tts", {"text": "x"}, 10.0, false)
	await _frames(5)
	c.cancel()
	var rc: Dictionary = await c.wait()
	await _frames(40)
	ok(bool(rc.get("cancelled", false)) and Api.active_count == 0, "cancelling a request that is waiting for its retry is clean")
	Api.clear_remote()


func _test_recorder_desktop_phone() -> void:
	print("[Recorder on desktop --phone]")
	ok(Recorder.mode() == "phone", "Recorder.mode() == phone")
	var results: Array = []
	var cb := func(r: Dictionary) -> void: results.append(r)
	Recorder.finished.connect(cb)
	if fake != null:
		fake.reset_log()
	var began: bool = Recorder.begin(4242)
	await _frames(10)
	ok(began and results.size() == 1 and not bool(results[0]["ok"]) and bool(results[0].get("reported", false)), "R-12: no hook -> finished(ok:false, reported:true) exactly once")
	ok(not Recorder.recording and not Recorder.stopping, "R-12: recorder is idle again")
	if fake != null:
		ok(fake.count("/mic/start") + fake.count("/mic/stop") + fake.count("/mic/level") + fake.count("/mic/devices") + fake.count("/mic/cancel") == 0, "R-12: 0 requests to /mic/*")
	results.clear()
	Recorder.test_audio_source = func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true)
	began = Recorder.begin(4243)
	await _wait_for(func() -> bool: return Recorder._mic_live, 2.0)
	await get_tree().create_timer(0.3).timeout
	Recorder.end()
	await _wait_for(func() -> bool: return results.size() >= 1, 5.0)
	ok(began and results.size() == 1 and bool(results[0]["ok"]) and str(results[0]["b64"]) != "" and int(results[0]["owner"]) == 4243, "R-12: with a test source -> ok:true and a non-empty b64")
	if results.size() == 1:
		ok(absf(float(results[0]["duration"]) - 1.0) < 0.05 and not bool(results[0]["silent"]), "R-12: duration 1.0 s, not silent")
		var wav: PackedByteArray = results[0]["wav"]
		ok(wav.size() > 44 and wav.decode_u16(22) == 1 and wav.decode_u16(34) == 16, "R-12: result is a mono 16-bit WAV")
	if fake != null:
		ok(fake.count("/mic/start") + fake.count("/mic/stop") + fake.count("/mic/level") + fake.count("/mic/cancel") == 0, "R-12: still 0 requests to /mic/* with the test source")
	Recorder.test_audio_source = Callable()
	Recorder.finished.disconnect(cb)


func _test_pause_resume() -> void:
	print("[pause / resume]")
	# a recording and a speech are running
	Recorder.test_audio_source = func() -> AudioStreamWAV: return WavUtil.sine(2.0, 48000, 440.0, 0.5, false)
	var results: Array = []
	var cb := func(r: Dictionary) -> void: results.append(r)
	Recorder.finished.connect(cb)
	Recorder.begin(77)
	await _wait_for(func() -> bool: return Recorder._mic_live, 2.0)
	ok(Recorder.recording, "recording is running")
	Tts.fetch_hook = func(_t: String, _l: String, _s: float, _v: String) -> AudioStreamWAV: return WavUtil.sine(3.0, 24000, 300.0, 0.2, false)
	Tts.speak("Hello there.", "en")
	await _wait_for(func() -> bool: return Tts.playing, 3.0)
	ok(Tts.playing, "TTS is playing")
	get_tree().root.propagate_notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	await _frames(3)
	ok(not Recorder.recording and not Recorder.stopping and results.is_empty(), "R-15: pause cancels the recording (no result is delivered)")
	ok(not Tts.playing and not Tts.busy, "R-15: pause stops the speech (Tts.stop)")
	Tts.fetch_hook = Callable()
	Recorder.test_audio_source = Callable()
	Recorder.finished.disconnect(cb)
	# resume: one immediate /health when connected
	var conn: Dictionary = await _pair_new("Resume Phone")
	RemoteLink.save(conn, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	await Backend.start()
	ok(Backend.status == Backend.Status.READY, "connected before the resume check")
	# paused: the 15 s poll must not run
	Backend._since_refresh = Backend.HEALTH_REFRESH_SECONDS + 1.0
	if fake != null:
		fake.reset_log()
	await _frames(20)
	if fake != null:
		ok(fake.count("/health") == 0, "R-15: no /health poll while the app is in the background")
	else:
		skip("R-15 background poll count needs the in-process fake")
	Backend._since_refresh = 0.0
	if fake != null:
		fake.reset_log()
	get_tree().root.propagate_notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await get_tree().create_timer(0.8).timeout
	if fake != null:
		ok(fake.count("/health") == 1, "R-15: resume -> exactly one /health right away (got %d)" % fake.count("/health"))
	else:
		skip("R-15 resume /health count needs the in-process fake")
	ok(Backend.status == Backend.Status.READY, "still READY after resume")
	# resume while FAILED reconnects by itself
	Backend.status = Backend.Status.FAILED
	get_tree().root.propagate_notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	get_tree().root.propagate_notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _wait_for(func() -> bool: return Backend.status == Backend.Status.READY, 5.0)
	ok(Backend.status == Backend.Status.READY, "resume while FAILED -> start() again -> READY")
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()


func _test_connect_view() -> void:
	print("[ConnectView]")
	await _revoke_all()
	var code: String = await _open_pairing(true)
	_cleanup_files()
	Api.clear_remote()
	_reset_backend()
	var view := ConnectView.new()
	view.auto_discover = false
	add_child(view)
	await _frames(2)
	ok(view.address_edit != null and view.code_edit != null and view.connect_button != null, "ConnectView builds its widgets")
	ok(view.code_edit.virtual_keyboard_type == LineEdit.KEYBOARD_TYPE_NUMBER and view.code_edit.max_length > 0, "code field: number keypad and max_length")
	# wrong address format
	view.address_edit.text = "mypc.local"
	view.code_edit.text = "123456"
	view.submit()
	ok(view.error_label.visible and view.error_label.text.contains("주소를 확인해 주세요"), "wrong address -> Korean address help")
	# wrong code format
	view.address_edit.text = "127.0.0.1:%d" % int(lan_url.get_slice(":", 2))
	view.code_edit.text = "12"
	view.submit()
	ok(view.error_label.visible and view.error_label.text.contains("6자리"), "short code -> Korean code help")
	await _frames(3)
	# server off: closed port
	view.address_edit.text = "127.0.0.1:%d" % CLOSED_PORT
	view.code_edit.text = "123456"
	await _submit_and_wait(view)
	ok(view.error_label.text.contains("PC에 닿지 않아요") and view.error_label.text.contains("방화벽"), "closed port -> unreachable text with the firewall hint")
	# wrong code
	view.address_edit.text = "127.0.0.1:%d" % int(lan_url.get_slice(":", 2))
	view.code_edit.text = "%06d" % ((int(code) + 1) % 1000000)
	await _submit_and_wait(view)
	ok(view.error_label.text.contains("남은 기회 4번"), "wrong code -> 'remaining tries 4' text on screen")
	# right code, formatted with a space
	var got: Array = []
	view.connected.connect(func() -> void: got.append(true))
	view.code_edit.text = code.substr(0, 3) + " " + code.substr(3)
	view.name_edit.text = "ConnectView Phone"
	view.submit()
	await _wait_for(func() -> bool: return got.size() > 0, 6.0)
	ok(got.size() == 1, "right code -> `connected` emitted once")
	await _wait_for(func() -> bool: return Backend.status == Backend.Status.READY, 5.0)
	ok(Backend.status == Backend.Status.READY and Api.token != "" and Api.base_url != "", "after connecting: Backend READY, Api has address + token")
	var saved: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(saved.get("token", "")) == Api.token and str(saved.get("base_url", "")) != "", "the connection was saved to the remote file")
	await _frames(3)
	ok(not is_instance_valid(view) or view.is_queued_for_deletion(), "ConnectView closes itself after connecting")
	# NEEDS_PAIRING after a revoke: the connect screen is prefilled and explains why
	await _revoke_all()
	await Api.get_json("/curriculum", 5.0, false).wait()
	await _frames(3)
	ok(Backend.status == Backend.Status.NEEDS_PAIRING, "revoked -> NEEDS_PAIRING")
	var view2 := ConnectView.new()
	view2.auto_discover = false
	add_child(view2)
	await _frames(2)
	ok(view2.address_edit.text.begins_with("127.0.0.1:") and view2.notice_label.visible and view2.notice_label.text.contains("해제됐어요"), "connect screen after a revoke: address prefilled + 'revoked' notice")
	view2.queue_free()
	await _frames(2)
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()


func _test_view_closed_midway() -> void:
	print("[screen closed while a request is out]")
	if fake == null:
		skip("closing a screen during a slow request needs the in-process fake")
		return
	await _revoke_all()
	var code: String = await _open_pairing(true)
	_cleanup_files()
	Api.clear_remote()
	_reset_backend()
	fake.delay_sec["/pair"] = 1.0
	var view := ConnectView.new()
	view.auto_discover = false
	add_child(view)
	await _frames(2)
	view.address_edit.text = "127.0.0.1:%d" % LAN_PORT
	view.code_edit.text = code
	view.submit()
	await get_tree().create_timer(0.4).timeout   # hello answered, /pair is being held by the fake
	view.free()
	await get_tree().create_timer(1.8).timeout
	fake.delay_sec.erase("/pair")
	ok(Api.active_count == 0, "closed ConnectView: nothing left in flight (active_count %d)" % Api.active_count)
	var saved: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(saved.get("token", "")) != "", "the token the PC issued is still saved (no orphan device on the PC)")
	await _wait_for(func() -> bool: return Backend.status == Backend.Status.READY, 5.0)
	ok(Backend.status == Backend.Status.READY, "Backend still connects after the screen is gone")
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()
	# RemoteLinkPanel removed while it tells the PC to unpair
	var conn: Dictionary = await _pair_new("Unpair Phone")
	RemoteLink.save(conn, TEST_REMOTE)
	await Backend.start()
	var panel := RemoteLinkPanel.new()
	add_child(panel)
	await _frames(2)
	ok(panel.status_label.text.contains("PC 연결됨"), "RemoteLinkPanel shows 'PC 연결됨' while connected")
	fake.delay_sec["/lan/unpair"] = 1.0
	panel.disconnect_pc()
	await get_tree().create_timer(0.3).timeout
	panel.free()
	await get_tree().create_timer(0.5).timeout
	fake.delay_sec.erase("/lan/unpair")
	var after: Dictionary = RemoteLink.load_saved(TEST_REMOTE)
	ok(str(after.get("token", "x")) == "" and Backend.status == Backend.Status.NEEDS_PAIRING, "panel removed during 'disconnect' -> the token is still forgotten locally")
	# normal 'disconnect' tells the PC
	var conn2: Dictionary = await _pair_new("Unpair Phone 2")
	RemoteLink.save(conn2, TEST_REMOTE)
	Api.clear_remote()
	_reset_backend()
	await Backend.start()
	var panel2 := RemoteLinkPanel.new()
	add_child(panel2)
	await _frames(2)
	fake.reset_log()
	var req_ok := await _disconnect_and_wait(panel2)
	ok(req_ok and fake.count("/lan/unpair") == 1, "R-06b: 'disconnect' calls POST /lan/unpair once")
	var st: Dictionary = await _admin_get("/lan")
	var still := false
	for d in (st["data"] as Dictionary).get("devices", []) as Array:
		if str((d as Dictionary).get("id", "")) == str(conn2["device_id"]):
			still = true
	ok(not still, "the PC no longer lists this phone after 'disconnect'")
	ok(panel2.status_label.text.contains("연결 필요"), "RemoteLinkPanel shows 'connection needed' after disconnecting")
	panel2.queue_free()
	await _frames(2)
	# PhoneLinkPanel (PC card) removed during a slow GET /lan: handled in the PC section
	Api.clear_remote()
	_reset_backend()
	_cleanup_files()


## Presses [연결] and waits (at most 8 s) for the attempt to finish; returns true when it did.
func _submit_and_wait(view: ConnectView) -> bool:
	var done: Array = []
	var cb := func(_ok: bool) -> void: done.append(true)
	view.attempt_finished.connect(cb)
	view.submit()
	var fin: bool = await _wait_for(func() -> bool: return done.size() > 0, 8.0)
	if is_instance_valid(view):
		view.attempt_finished.disconnect(cb)
	return fin


func _disconnect_and_wait(panel: RemoteLinkPanel) -> bool:
	panel.disconnect_pc()
	return await _wait_for(func() -> bool: return Backend.status == Backend.Status.NEEDS_PAIRING, 4.0)


# ---------------------------------------------------------------- PC mode (must not change)

func _pc_tests() -> void:
	ok(not Platform.is_phone() and not Backend.remote_mode, "PC mode: Platform.is_phone() false, Backend.remote_mode false")
	ok(Api.token == "", "PC mode: Api has no token")
	var saved_base: String = Api.base_url
	Api.base_url = admin_url
	var h: Dictionary = await Api.get_json("/health", 5.0, false).wait()
	ok(h["ok"], "PC mode request reaches the fake")
	if fake != null:
		ok(fake.last_entry("/health").get("auth", true) == false, "R-03 PC mode: no Authorization header")
		# no automatic retry on a PC
		fake.reset_log()
		fake.drop["/stt"] = 1
		var r: Dictionary = await Api.post_json("/stt", {"lang": "en", "audio_b64": "AAAA"}, 10.0, false).wait()
		ok(not r["ok"] and fake.count("/stt") == 1, "PC mode: a dropped /stt is NOT retried (requests: %d)" % fake.count("/stt"))
		fake.reset_log()
	ok(Api._transport_error(HTTPRequest.RESULT_CANT_CONNECT) == "AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요.", "PC mode: transport error text is the old 'AI 엔진에 연결하지 못했어요' one")
	ok(Api._transport_error(HTTPRequest.RESULT_TIMEOUT) == "응답이 너무 오래 걸려서 멈췄어요. 잠시 뒤 다시 시도해 주세요.", "PC mode: timeout text unchanged")
	Api.base_url = admin_url
	ok(Recorder.mode() == "pc", "PC mode: Recorder.mode() == pc")
	if fake != null:
		fake.reset_log()
	var began: bool = Recorder.begin(1)
	await _wait_for(func() -> bool: return fake == null or fake.count("/mic/start") >= 1, 3.0)
	ok(began, "R-13: Recorder.begin() works in PC mode")
	if fake != null:
		ok(fake.count("/mic/start") == 1, "R-13: the fake received POST /mic/start")
	else:
		skip("R-13 request count needs the in-process fake")
	Recorder.cancel()
	await _wait_for(func() -> bool: return fake == null or fake.count("/mic/cancel") >= 1, 3.0)
	if fake != null:
		ok(fake.count("/mic/cancel") == 1, "R-13: cancel -> POST /mic/cancel")
	await _test_phone_link_panel()
	Api.base_url = saved_base


func _text_of(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for c in node.get_children():
		out += _text_of(c)
	return out


func _test_phone_link_panel() -> void:
	print("[PhoneLinkPanel]")
	await _revoke_all()
	await _admin_post("/lan", {"enabled": false})
	var panel := PhoneLinkPanel.new()
	add_child(panel)
	await _frames(2)
	await panel.refresh()
	ok(not panel.toggle.button_pressed and panel.state_label.text == "꺼짐" and not panel.details.visible, "R-14: link is off by default (toggle off, details hidden)")
	ok(not PhoneLinkPanel.last_enabled, "last_enabled is false while off")
	await panel.set_enabled_remote(true)
	await _wait_for(func() -> bool: return panel.details.visible, 3.0)
	ok(panel.toggle.button_pressed and panel.details.visible and PhoneLinkPanel.last_enabled, "R-14: turned on -> details visible, last_enabled true")
	var m := RegEx.new()
	m.compile("^연결 코드  \\d{3} \\d{3}$")
	ok(m.search(panel.code_label.text) != null, "R-14: code label shows 'xxx xxx'")
	ok(panel.timer_label.text.contains("안에 입력") and (panel.address_label.text.contains(":") or panel.address_label.text.contains("포트")), "R-14: remaining time and address shown")
	var all_text: String = _text_of(panel)
	ok(all_text.contains("개인 네트워크") and all_text.contains("공용 와이파이"), "R-14: panel text has the firewall ('개인 네트워크') and public wifi ('공용 와이파이') notes")
	ok(all_text.contains("암호화되지 않아서") and all_text.contains("이 프로그램은 방화벽 설정을 직접 바꾸지 않아요"), "R-14: exact warning sentences present")
	ok(panel.devices_title.text == "연결된 휴대폰 (0)", "R-14: no devices yet")
	# a phone pairs
	var code_text: String = panel.code_label.text.replace("연결 코드", "").replace(" ", "")
	var pr: Dictionary = await RemoteLink.pair(lan_url, code_text, "Row Phone")
	ok(pr["ok"], "a phone paired with the code shown by the card")
	await panel.refresh()
	ok(panel.devices_title.text == "연결된 휴대폰 (1)" and _text_of(panel.devices_box).contains("Row Phone"), "R-14: device row 'Row Phone' appears")
	var did: String = str(pr["device_id"])
	panel.revoke_device(did)
	await _wait_for(func() -> bool: return panel.devices_title.text == "연결된 휴대폰 (0)", 3.0)
	ok(panel.devices_title.text == "연결된 휴대폰 (0)" and not panel.devices_box.has_node("dev_" + did), "R-14: [연결 해제] removes the row")
	var st: Dictionary = await _admin_get("/lan")
	ok(((st["data"] as Dictionary).get("devices", []) as Array).is_empty(), "R-14: next GET /lan lists 0 devices")
	# the old token is dead now
	var dead: Dictionary = await Api.get_json_to(lan_url, "/lan/me", 5.0, false).wait()
	ok(not dead["ok"] and int(dead["code"]) == 401, "R-14: a request without a token to /lan/me -> 401")
	# new code button
	await panel.new_code()
	ok(m.search(panel.code_label.text) != null, "new code button keeps a 6 digit code on screen")
	# the static poll used by main.gd
	PhoneLinkPanel.last_enabled = false
	var en: bool = await PhoneLinkPanel.poll_state()
	ok(en and PhoneLinkPanel.last_enabled, "PhoneLinkPanel.poll_state() reads the PC state without the card")
	# off again
	await panel.set_enabled_remote(false)
	await _wait_for(func() -> bool: return not panel.details.visible, 3.0)
	ok(not panel.toggle.button_pressed and not panel.details.visible and not PhoneLinkPanel.last_enabled, "R-14: turned off -> details hidden, last_enabled false")
	# security: no private network -> warning, switch stays off, no public address shown
	if fake != null:
		await panel.set_enabled_remote(false)
		fake.private_network = false
		fake.addresses = ["8.8.8.8"]
		await panel.refresh()
		ok(panel.network_warning != "" and panel.toggle.disabled and panel.error_label.visible and panel.error_label.text.contains("공유기"), "network_safe:false -> warning shown before trying, switch disabled")
		await panel.set_enabled_remote(true)
		ok(not panel.toggle.button_pressed and not panel.details.visible and not fake.lan_enabled, "409 no_private_network -> switch stays off, nothing is listening")
		ok(panel.error_label.text.contains("사설 네트워크 주소"), "the Korean message from the server is shown")
		fake.private_network = true
		fake.addresses = ["8.8.8.8", "192.168.0.12"]
		await panel.refresh()
		ok(panel.network_warning == "" and not panel.toggle.disabled, "network is fine again -> warning gone, switch usable")
		await panel.set_enabled_remote(true)
		await _wait_for(func() -> bool: return panel.details.visible, 3.0)
		ok(not panel.address_label.text.contains("8.8.8.8") and panel.address_label.text.contains("192.168.0.12"), "a public address is never displayed, the private one is")
		fake.addresses = ["8.8.8.8"]
		await panel.refresh()
		ok(not panel.address_label.text.contains("8.8.8.8"), "only a public address from the server -> not shown")
		fake.addresses = ["192.168.0.12"]
		ok(PhoneLinkPanel.is_private_ipv4("10.1.2.3") and PhoneLinkPanel.is_private_ipv4("172.20.0.1") and not PhoneLinkPanel.is_private_ipv4("172.32.0.1") and not PhoneLinkPanel.is_private_ipv4("169.254.1.1") and not PhoneLinkPanel.is_private_ipv4("abc"), "is_private_ipv4 accepts only RFC1918")
		await panel.set_enabled_remote(false)
		await _wait_for(func() -> bool: return not panel.details.visible, 3.0)
	# rejected admin calls (local_only / bad_origin) -> generic error
	if fake != null:
		fake.reject_admin = "bad_origin"
		await panel.set_enabled_remote(true)
		ok(panel.error_label.visible and panel.error_label.text.contains("다시 시작"), "bad_origin / local_only -> generic Korean error")
		fake.reject_admin = ""
		await panel.refresh()
	# card removed while GET /lan is slow
	if fake != null:
		fake.delay_sec["/lan"] = 1.0
		var p2 := PhoneLinkPanel.new()
		add_child(p2)
		await _frames(2)
		p2.refresh()
		await get_tree().create_timer(0.3).timeout
		p2.free()
		await get_tree().create_timer(1.3).timeout
		fake.delay_sec.erase("/lan")
		ok(Api.active_count == 0, "PhoneLinkPanel freed during GET /lan: nothing left in flight")
	# 404 from an old PC engine
	panel.queue_free()
	await _frames(2)


# ================================================================ in-process fake PC

class FakeLan:
	extends Node
	var admin_port: int = 0
	var lan_port: int = 0
	var udp_port: int = 0
	var server_name: String = "TESTPC"
	var _admin := TCPServer.new()
	var _lan := TCPServer.new()
	var _lan_open: bool = false
	var _udp: PacketPeerUDP = null
	var _conns: Array = []
	var log: Array = []                 ## {role, method, path, auth: bool, bearer: bool}
	var devices: Array = []             ## {id, name, token, created}
	var code: String = ""
	var code_active: bool = false
	var attempts_left: int = 5
	var locked: bool = false
	var lan_enabled: bool = false
	var discovery: bool = true
	var private_network: bool = true    ## false: the PC has no private IPv4 address
	var addresses: Array = ["192.168.0.12"]
	var reject_admin: String = ""       ## "" | "local_only" | "bad_origin": refuse POST /lan
	var udp_mode: String = "on"         ## on | off | garbage | other_garbage (extra-key answer from a second socket)
	var udp_reply_port: int = 0         ## answer discovery with this TCP port instead of lan_port (a "moved" PC)
	var _udp2: PacketPeerUDP = null
	var drop: Dictionary = {}           ## path -> how many requests to close without an answer
	var delay_sec: Dictionary = {}      ## path -> seconds to hold the answer
	var _next_id: int = 1
	var _rng := RandomNumberGenerator.new()

	func start(admin: int, lan: int, udp: int) -> bool:
		admin_port = admin
		lan_port = lan
		udp_port = udp
		_rng.randomize()
		if admin > 0 and _admin.listen(admin, "127.0.0.1") != OK:
			return false
		if udp > 0:
			_udp = PacketPeerUDP.new()
			if _udp.bind(udp, "127.0.0.1") != OK:
				return false
			_udp2 = PacketPeerUDP.new()
			if _udp2.bind(0, "127.0.0.1") != OK:
				return false
		return true

	func stop() -> void:
		_admin.stop()
		_lan.stop()
		if _udp != null:
			_udp.close()
		if _udp2 != null:
			_udp2.close()
		for c in _conns:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
		_conns.clear()

	func reset_log() -> void:
		log.clear()

	func count(path: String, role: String = "") -> int:
		var n := 0
		for e in log:
			if e["path"] == path and (role == "" or e["role"] == role):
				n += 1
		return n

	## true if any logged request to `path` (or, with "", to any path) carried an Authorization header
	func auth_seen(path: String = "") -> bool:
		for e in log:
			if (path == "" or e["path"] == path) and bool(e["auth"]):
				return true
		return false

	func last_entry(path: String) -> Dictionary:
		for i in range(log.size() - 1, -1, -1):
			if log[i]["path"] == path:
				return log[i]
		return {}

	func _process(_d: float) -> void:
		while _admin.is_connection_available():
			_conns.append(_new_conn(_admin.take_connection(), "admin"))
		if _lan_open:
			while _lan.is_connection_available():
				_conns.append(_new_conn(_lan.take_connection(), "lan"))
		for c in _conns.duplicate():
			_pump(c)
		_pump_udp()

	func _new_conn(p: StreamPeerTCP, role: String) -> Dictionary:
		return {"peer": p, "role": role, "buf": PackedByteArray(), "release_at": -1, "resp": PackedByteArray()}

	func _pump(c: Dictionary) -> void:
		var p: StreamPeerTCP = c["peer"]
		p.poll()
		var st: int = p.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			_conns.erase(c)
			return
		if int(c["release_at"]) >= 0:
			if Time.get_ticks_msec() >= int(c["release_at"]):
				p.put_data(c["resp"])
				p.disconnect_from_host()
				_conns.erase(c)
			return
		var n: int = p.get_available_bytes()
		if n > 0:
			var r: Array = p.get_data(n)
			var buf: PackedByteArray = c["buf"]   # packed arrays are values: write it back
			buf.append_array(r[1])
			c["buf"] = buf
		var req: Dictionary = _parse(c["buf"])
		if req.is_empty():
			return
		var res: Dictionary = _route(str(c["role"]), req)
		if bool(res.get("drop", false)):
			p.disconnect_from_host()
			_conns.erase(c)
			return
		c["resp"] = _http(res)
		var wait: float = float(delay_sec.get(req["path"], 0.0))
		c["release_at"] = Time.get_ticks_msec() + int(wait * 1000.0)

	func _parse(buf: PackedByteArray) -> Dictionary:
		if buf.size() < 16:
			return {}
		var text: String = buf.get_string_from_utf8()
		var he: int = text.find("\r\n\r\n")
		if he < 0:
			return {}
		var head: String = text.substr(0, he)
		var lines: PackedStringArray = head.split("\r\n")
		var first: PackedStringArray = lines[0].split(" ")
		if first.size() < 2:
			return {}
		var headers := {}
		for i in range(1, lines.size()):
			var k: int = lines[i].find(":")
			if k > 0:
				headers[lines[i].substr(0, k).strip_edges().to_lower()] = lines[i].substr(k + 1).strip_edges()
		var clen: int = int(headers.get("content-length", "0"))
		var body_bytes: int = buf.size() - (he + 4)
		if body_bytes < clen:
			return {}
		var body: String = buf.slice(he + 4, he + 4 + clen).get_string_from_utf8()
		return {"method": first[0], "path": first[1], "headers": headers, "body": body}

	func _http(res: Dictionary) -> PackedByteArray:
		var status: int = int(res.get("status", 200))
		var ctype := "application/json"
		var payload := PackedByteArray()
		if res.has("bytes"):
			payload = res["bytes"]
			ctype = "audio/wav"
		else:
			payload = JSON.stringify(res.get("json", {})).to_utf8_buffer()
		var head := "HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, ctype, payload.size()]
		var out := head.to_utf8_buffer()
		out.append_array(payload)
		return out

	func _err(status: int, msg: String, ecode: String, extra: Dictionary = {}) -> Dictionary:
		var j := {"error": msg, "code": ecode}
		j.merge(extra)
		return {"status": status, "json": j}

	func _token() -> String:
		var b: PackedByteArray = Crypto.new().generate_random_bytes(32)
		return "hp1_" + Marshalls.raw_to_base64(b).replace("+", "-").replace("/", "_").replace("=", "")

	func _new_code() -> void:
		code = "%06d" % _rng.randi_range(0, 999999)
		code_active = true
		attempts_left = 5
		locked = false

	func _find_by_token(tok: String) -> Dictionary:
		for d in devices:
			if d["token"] == tok:
				return d
		return {}

	func _set_lan(on: bool) -> void:
		lan_enabled = on
		if on and not _lan_open:
			_lan_open = _lan.listen(lan_port, "127.0.0.1") == OK
			_new_code()
		elif not on:
			_lan.stop()
			_lan_open = false
			code_active = false

	func _pump_udp() -> void:
		while _udp != null and _udp.get_available_packet_count() > 0:
			var ip: String = _udp.get_packet_ip()
			var port: int = _udp.get_packet_port()
			var pkt: PackedByteArray = _udp.get_packet()
			if ip == "" or ip.contains(":"):
				continue
			var d: Variant = RemoteLink.parse_json(pkt.get_string_from_utf8())
			if not (d is Dictionary) or int((d as Dictionary).get("hoehwa", 0)) != 1 or str((d as Dictionary).get("op", "")) != "discover":
				continue
			if udp_mode == "off" or not lan_enabled or not discovery:
				continue
			if udp_mode == "other_garbage":
				# an answer with an extra key, sent from ANOTHER socket (different source port)
				_udp2.set_dest_address(ip, port)
				_udp2.put_packet(('{"hoehwa":1,"op":"here","name":"%s","port":%d,"extra":"x"}' % [server_name, lan_port]).to_utf8_buffer())
				continue
			_udp.set_dest_address(ip, port)
			if udp_mode == "garbage":
				for bad in ['{"hoehwa":1,"op":"here","name":"X","port":%d,"extra":1}' % lan_port, '{"hoehwa":1,"op":"nope","name":"X","port":%d}' % lan_port, '{"hoehwa":1,"op":"here","name":"X","port":70000}', "not json at all", '{"hoehwa":2,"op":"here","name":"X","port":%d}' % lan_port]:
					_udp.put_packet(bad.to_utf8_buffer())
			else:
				_udp.put_packet(JSON.stringify({"hoehwa": 1, "op": "here", "name": server_name, "port": udp_reply_port if udp_reply_port > 0 else lan_port}).to_utf8_buffer())

	# ---- routing (mirrors docs/android_remote_design.md §3.4 / §3.5)

	const ALLOW := ["GET /health", "GET /curriculum", "POST /tts", "GET /tts/voices", "POST /stt", "POST /score", "POST /prosody", "POST /chat", "POST /feedback", "POST /fix", "POST /lesson", "POST /reading/analyze", "POST /reading/gloss", "GET /examples", "GET /lan/me", "POST /lan/unpair"]

	func _route(role: String, req: Dictionary) -> Dictionary:
		var path: String = str(req["path"]).split("?")[0]
		var method: String = req["method"]
		var auth: String = str((req["headers"] as Dictionary).get("authorization", ""))
		var tok: String = auth.substr(7) if auth.to_lower().begins_with("bearer ") else ""
		log.append({"role": role, "method": method, "path": path, "auth": auth != "", "bearer": auth.begins_with("Bearer hp1_")})
		if int(drop.get(path, 0)) > 0:
			drop[path] = int(drop[path]) - 1
			return {"drop": true}
		var body: Variant = JSON.parse_string(str(req["body"])) if str(req["body"]) != "" else {}
		if not (body is Dictionary):
			body = {}
		var key := "%s %s" % [method, path]
		var dev: Dictionary = {}
		if role == "lan":
			if not (key == "GET /hello" or key == "POST /pair" or key == "POST /lan/proof"):
				if auth == "":
					return _err(401, "이 PC에 연결되지 않았어요. 연결 코드를 입력해 주세요.", "token_missing")
				dev = _find_by_token(tok)
				if dev.is_empty():
					return _err(401, "이 휴대폰의 연결이 해제됐어요. 다시 연결해 주세요.", "token_invalid")
				if path == "/lan" or path == "/lan/code" or path == "/lan/devices/revoke":
					return _err(403, "이 PC에서만 할 수 있어요.", "local_only")
				if not ALLOW.has(key):
					return _err(403, "휴대폰에서는 쓸 수 없는 기능이에요.", "lan_forbidden")
		match key:
			"GET /hello":
				return {"json": {"hoehwa": 1, "name": server_name, "pairing_open": code_active and not locked}}
			"POST /pair":
				return _pair(body)
			"POST /lan/proof":
				var found: Dictionary = {}
				for d in devices:
					if d["id"] == str(body.get("device_id", "")):
						found = d
				if found.is_empty():
					return _err(404, "연결된 기기를 찾지 못했어요.", "device_not_found")
				var mac: PackedByteArray = Crypto.new().hmac_digest(HashingContext.HASH_SHA256, str(found["token"]).sha256_buffer(), str(body.get("nonce", "")).to_utf8_buffer())
				return {"json": {"proof": mac.hex_encode()}}
			"GET /lan/me":
				return {"json": {"device_id": dev["id"], "name": dev["name"], "server_name": server_name}}
			"POST /lan/unpair":
				devices.erase(dev)
				return {"json": {"ok": true}}
			"GET /health":
				return {"json": {"ok": true, "llm": true, "llm_provider": "opencode"}}
			"GET /curriculum":
				return {"json": {"note": "fake"}}
			"POST /tts":
				return {"bytes": WavUtil.to_wav_bytes(WavUtil.sine(0.3, 24000, 440.0, 0.4, false))}
			"POST /stt":
				return {"json": {"text": "hello", "language": "en"}}
			"POST /score":
				return {"json": {"score": 80, "units": []}}
			"POST /chat", "POST /lesson", "POST /reading/analyze", "POST /feedback", "POST /fix", "POST /prosody", "POST /reading/gloss":
				return {"json": {"ok": true}}
			"POST /mic/start", "POST /mic/cancel":
				return {"json": {"ok": true}}
			"GET /mic/level":
				return {"json": {"level": 0.1}}
			"GET /mic/devices":
				return {"json": {"devices": []}}
			"POST /mic/stop":
				return {"json": {"ok": false}}
			"GET /lan":
				return {"json": _lan_state()}
			"POST /lan":
				if reject_admin != "":
					return _err(403, "거절됐어요.", reject_admin)
				if body.has("enabled"):
					if bool(body["enabled"]) and not private_network:
						return _err(409, "이 PC에 사설 네트워크 주소가 없어서 휴대폰 연결을 켤 수 없어요.", "no_private_network")
					_set_lan(bool(body["enabled"]))
				if body.has("discovery"):
					discovery = bool(body["discovery"])
				if body.has("name"):
					pass
				return {"json": _lan_state()}
			"POST /lan/code":
				if bool(body.get("cancel", false)):
					code_active = false
					return {"json": {"ok": true}}
				if not lan_enabled:
					return _err(409, "휴대폰 연결이 꺼져 있어요.", "lan_off")
				_new_code()
				return {"json": {"code": code, "expires_in": 300}}
			"POST /lan/devices/revoke":
				var n := 0
				if bool(body.get("all", false)):
					n = devices.size()
					devices.clear()
				else:
					for d in devices.duplicate():
						if d["id"] == str(body.get("id", "")):
							devices.erase(d)
							n += 1
				return {"json": {"ok": true, "revoked": n}}
		return _err(404, "없는 경로예요.", "not_found")

	func _pair(body: Dictionary) -> Dictionary:
		var c: String = str(body.get("code", ""))
		var is6 := c.length() == 6
		for ch in c:
			if ch < "0" or ch > "9":
				is6 = false
		if not is6 or str(body.get("device_name", "")).strip_edges() == "":
			return _err(400, "연결 코드는 숫자 6자리예요.", "code_format")
		if locked:
			return _err(429, "코드를 너무 많이 틀려서 잠겼어요. PC에서 새 코드를 만들어 주세요.", "pair_locked")
		if not code_active:
			return _err(410, "연결 코드가 없거나 시간이 지났어요. PC에서 새 코드를 만들어 주세요.", "no_active_code")
		if c != code:
			attempts_left -= 1
			if attempts_left <= 0:
				code_active = false
				locked = true
			return _err(401, "코드가 맞지 않아요. 남은 기회 %d번." % attempts_left, "code_invalid", {"attempts_left": attempts_left})
		if devices.size() >= 8:
			return _err(409, "연결할 수 있는 휴대폰이 가득 찼어요(최대 8대).", "device_limit")
		code_active = false
		var d := {"id": "%08x" % (0xa1b2c3d4 + _next_id), "name": str(body.get("device_name", "")), "token": _token(), "created": Time.get_datetime_string_from_system(true) + "Z"}
		_next_id += 1
		devices.append(d)
		return {"json": {"token": d["token"], "device_id": d["id"], "server_name": server_name, "port": lan_port}}

	func _lan_state() -> Dictionary:
		var devs: Array = []
		for d in devices:
			devs.append({"id": d["id"], "name": d["name"], "created": d["created"], "last_seen": d["created"], "last_ip": "192.168.0.23"})
		return {
			"enabled": lan_enabled, "listening": _lan_open, "port": lan_port, "bind": "0.0.0.0",
			"discovery": discovery, "discovery_listening": lan_enabled and discovery, "discovery_port": udp_port,
			"name": server_name, "addresses": addresses, "network_safe": private_network, "network_reason": "" if private_network else "이 PC에는 공유기(사설) 주소가 없어요.",
			"pairing": {"active": code_active, "code": code if code_active else null, "expires_in": 300 if code_active else 0, "locked": locked, "attempts_left": attempts_left},
			"devices": devs, "error": "",
		}


## A connected phone refreshes Store's curriculum cache from the PC. Tests never touch the app's own files
## (curriculum.json, prefs.json, progress.json, studylog.json, remote.json): the cache goes to a throw-away file.
func _use_test_curriculum_path() -> void:
	Store.curriculum_cache_path = "user://test_curriculum_%s.json" % get_scene_file_path().get_file().get_basename()


func _drop_test_curriculum_path() -> void:
	if FileAccess.file_exists(Store.curriculum_cache_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.curriculum_cache_path))
	Store.curriculum_cache_path = Store.CURRICULUM_CACHE
