extends Node
## Phone flow against a real PC backend or the W1 stub (docs/android_remote_design.md §9.2 R-17):
## turn the link on (loopback admin listener), pair with the shown code, then /health /tts /stt /score /prosody
## through the LAN listener with the bearer token. Uses the audio the server just returned as the "recording"
## and the same Recorder conversion path as the phone (WavUtil.to_mono16).
##
##   godot --headless --path <project> res://tests/phone_live_test.tscn -- --phone \
##       --live-admin=http://127.0.0.1:8857 --live-lan=http://127.0.0.1:8858 [--live-udp=18788]
## --live-lan may be a private IPv4 of this PC (http://192.168.x.y:8775). Without --live-admin the test prints SKIP
## (result "미검증") and exits 0. Tokens and codes are never printed.

const REMOTE_FILE := "user://phone_live_remote.json"

var passed: int = 0
var failed: int = 0
var admin: String = ""
var lan: String = ""
var udp: int = 0
var _saved_path: String = ""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== phone live test start ==")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--live-admin="):
			admin = a.substr(13).rstrip("/")
		elif a.begins_with("--live-lan="):
			lan = a.substr(11).rstrip("/")
		elif a.begins_with("--live-udp="):
			udp = int(a.substr(11))
	if admin == "" or lan == "":
		print("  SKIP  no --live-admin / --live-lan given: not verified")
		print("== phone live result: 0 passed, 0 failed (skipped) ==")
		get_tree().quit(0)
		return
	_saved_path = Api.remote_path
	_backup_curriculum()
	Api.remote_path = REMOTE_FILE
	await _run()
	Api.clear_remote()
	if FileAccess.file_exists(REMOTE_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REMOTE_FILE))
	_restore_curriculum()
	Api.remote_path = _saved_path
	print("== phone live result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _run() -> void:
	var en: Dictionary = await Api.post_json_to(admin, "/lan", {"enabled": true}, 10.0, false).wait()
	ok(en["ok"], "PC link turned on through the admin listener")
	if not en["ok"]:
		return
	await Api.post_json_to(admin, "/lan/code", {}, 10.0, false).wait()
	var st: Dictionary = await Api.get_json_to(admin, "/lan", 10.0, false).wait()
	var code := ""
	if st["ok"] and st["data"] is Dictionary:
		var p: Variant = (st["data"] as Dictionary).get("pairing", {})
		if p is Dictionary and (p as Dictionary).get("code", null) != null:
			code = str((p as Dictionary)["code"])
	ok(code.length() == 6, "a 6 digit pairing code is shown")
	var hi: Dictionary = await RemoteLink.hello(lan)
	ok(hi["ok"] and bool(hi["pairing_open"]), "hello through the LAN listener (no token)")
	if udp > 0:
		RemoteLink.test_discovery_port = udp
		RemoteLink.test_extra_targets = ["127.0.0.1"]
		var found: Array = await RemoteLink.discover(get_tree())
		ok(found.size() >= 1 and str(found[0]["name"]) != "", "discovery finds the PC (%d answer)" % found.size())
	var pr: Dictionary = await RemoteLink.pair(lan, code, "Live Test Phone")
	ok(pr["ok"], "paired with the code")
	if not pr["ok"]:
		return
	var conn := {"base_url": lan, "token": pr["token"], "device_id": pr["device_id"], "server_name": pr["server_name"]}
	ok(RemoteLink.save(conn, REMOTE_FILE), "connection saved")
	ok(await RemoteLink.proof_ok(lan, conn), "the PC proves it knows our token (/lan/proof)")
	Api.set_remote(lan, str(pr["token"]))
	# /health
	var h: Dictionary = await Api.get_json("/health", 10.0, false).wait()
	ok(h["ok"] and h["data"] is Dictionary and (h["data"] as Dictionary).get("ok", false), "GET /health with the token")
	# Backend.start() over the saved connection
	Backend.status = Backend.Status.IDLE
	await Backend.start()
	ok(Backend.status == Backend.Status.READY and Backend.pid == -1 and not Backend.launched_by_us, "Backend.start() -> READY, no process created")
	# /tts
	var t: Dictionary = await Api.post_json("/tts", {"text": "Nice to meet you.", "lang": "en", "speed": 1.0}, 60.0, false).wait()
	var bytes: PackedByteArray = t.get("bytes", PackedByteArray())
	var stream: AudioStreamWAV = WavUtil.from_wav_bytes(bytes)
	ok(t["ok"] and stream != null and WavUtil.duration(stream) > 0.2, "POST /tts returns a WAV (%d bytes)" % bytes.size())
	if stream == null:
		return
	# the phone's recording path: mono 16-bit WAV from the Recorder conversion
	var mono: AudioStreamWAV = WavUtil.to_mono16(stream)
	var b64: String = Marshalls.raw_to_base64(WavUtil.to_wav_bytes(mono))
	var s: Dictionary = await Api.post_json("/stt", {"lang": "en", "audio_b64": b64}, 60.0, false).wait()
	ok(s["ok"] and s["data"] is Dictionary and (s["data"] as Dictionary).has("text"), "POST /stt with the converted WAV")
	var sc: Dictionary = await Api.post_json("/score", {"lang": "en", "target": "Nice to meet you.", "reading": "", "audio_b64": b64}, 60.0, false).wait()
	ok(sc["ok"] and sc["data"] is Dictionary and (sc["data"] as Dictionary).has("score"), "POST /score")
	var pro: Dictionary = await Api.post_json("/prosody", {"lang": "en", "text": "Nice to meet you.", "reading": "", "audio_b64": b64}, 60.0, false).wait()
	ok(pro["ok"], "POST /prosody")
	# the phone must not reach PC-only features
	var mic: Dictionary = await Api.post_json("/mic/start", {}, 10.0, false).wait()
	ok(not mic["ok"] and int(mic["code"]) == 403, "POST /mic/start is refused on the LAN listener (403)")
	# wrong token -> 401 -> auth_failed once
	var hits := [0]
	var cb := func(_c: String) -> void: hits[0] += 1
	Api.auth_failed.connect(cb)
	Api.token = "hp1_" + "Z".repeat(43)
	var bad: Dictionary = await Api.get_json("/curriculum", 10.0, false).wait()
	await get_tree().process_frame
	Api.auth_failed.disconnect(cb)
	ok(not bad["ok"] and int(bad["code"]) == 401 and hits[0] == 1, "a wrong token -> 401 and auth_failed once")
	# unpair for real (clean up the PC's device list)
	Api.set_remote(lan, str(pr["token"]))
	var un: Dictionary = await Api.post_json("/lan/unpair", {}, 10.0, false).wait()
	ok(un["ok"], "POST /lan/unpair removes this test phone")
	var after: Dictionary = await Api.get_json("/health", 10.0, false).wait()
	ok(not after["ok"] and int(after["code"]) == 401, "after unpair the token is dead (401)")
	await Api.post_json_to(admin, "/lan", {"enabled": false}, 10.0, false).wait()
	var closed: Dictionary = await Api.get_json_to(lan, "/hello", 3.0, false).wait()
	ok(not closed["ok"], "after turning the link off the LAN port no longer answers")


# A connected phone refreshes Store's curriculum cache from the PC (user://curriculum.json): a test server must not
# leave its answer in the real app data.
var _cur_existed: bool = false
var _cur_text: String = ""


func _backup_curriculum() -> void:
	_cur_existed = FileAccess.file_exists(Store.CURRICULUM_CACHE)
	if _cur_existed:
		_cur_text = FileAccess.get_file_as_string(Store.CURRICULUM_CACHE)


func _restore_curriculum() -> void:
	if _cur_existed:
		var f := FileAccess.open(Store.CURRICULUM_CACHE, FileAccess.WRITE)
		if f != null:
			f.store_string(_cur_text)
	elif FileAccess.file_exists(Store.CURRICULUM_CACHE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.CURRICULUM_CACHE))
