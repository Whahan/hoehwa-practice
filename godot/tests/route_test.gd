extends Node
## A1 test: Route.decide / why_none / caps, LocalApi.dispatch / health / curriculum, the Api hook, fallback, cancel.
##   godot --headless --path <project> res://tests/route_test.tscn
## Exit code 0 = all checks passed. Last line: "== route_test result: N passed, 0 failed =="
## No fake PC server: the "PC" is the closed port 9 (connection refused = a transport error). Phone handlers are
## fakes injected through LocalApi.handler_override; their state lives in Engine meta (a1_*).

const DEAD_PC := "http://127.0.0.1:9"
## Connection time limit of the test requests. A connect to the closed port 9 does not fail fast on Windows (the SYN is
## retried for ~2 s), so every dead-PC request used to wait its whole 5 s; 0.5 s ends it as a transport error.
const REQ_TIMEOUT := 0.5

## Expected policy (independent copy of design 4.3): key -> [prefer, phone handler key].
const SPEC := {
	"GET /health": ["pc", "health"],
	"GET /curriculum": ["pc", "curriculum"],
	"POST /tts": ["pc", ""],
	"GET /tts/voices": ["pc", ""],
	"POST /stt": ["phone", "stt"],   # v2.0 phone-first scoring (score_where unset = "phone")
	"POST /score": ["phone", "stt"],
	"POST /score#ph": ["pc", "stt"],   # v2.0: /score with need_ph:true (phoneme screens) prefers the PC
	"POST /prosody": ["pc", ""],
	"POST /lesson": ["phone", "lessons"],
	"POST /lesson#ai": ["pc", "ai"],
	"POST /reading/analyze": ["phone", "reading"],
	"POST /reading/gloss": ["pc", "reading"],
	"GET /examples": ["pc", "reading"],
	"GET /practice/ping": ["phone", "practice"],
	"GET /practice/sentences": ["phone", "practice"],
	"GET /practice/phonemes": ["phone", "practice"],
	"GET /practice/phoneme": ["phone", "practice"],
	"GET /missions": ["phone", "missions"],
	"POST /missions/check": ["phone", "missions"],
	"POST /missions/judge": ["pc", "ai"],
	"POST /chat": ["pc", "ai"],
	"POST /fix": ["pc", "ai"],
	"POST /feedback": ["pc", "ai"],
}

## Paths without a policy entry (PC only in stage 1: lan.py /lan, /sync, /mic, /llm). On the phone they go to the PC in
## auto/pc mode and nowhere ("none") in phone mode.
const NOPOLICY := ["POST /sync/push", "GET /lan/info", "POST /mic/start", "GET /llm/status"]

## Expected decisions, index = ready*4 + phone_ok*2 + pc_possible (hand written, not derived from decide()).
const EXPECT_AUTO_PC := ["none", "pc", "phone", "phone", "none", "pc", "phone", "pc"]
const EXPECT_AUTO_PHONE := ["none", "pc", "phone", "phone", "none", "pc", "phone", "phone"]
const EXPECT_PHONE_MODE := ["none", "none", "phone", "phone", "none", "none", "phone", "phone"]
const EXPECT_PC_MODE := ["pc", "pc", "pc", "pc", "pc", "pc", "pc", "pc"]

var _start_msec: int = Time.get_ticks_msec()
var passed: int = 0
var failed: int = 0
var _t: float = 1000.0
var _fell_back: Array = []
var _auth_failed: int = 0
var _modes_seen: Array = []
## SystemTts adapter with a fixed voice list, so caps' tts row does not depend on the voices of the test machine.
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


var _nohandler_done: bool = false   ## set on the last line of _test_no_handler_files
var _caps_done: bool = false   ## set on the last line of _test_caps
var _is_phone: bool = true   ## what Route.is_phone() answers (the test injects it; the test scene runs on the desktop)


## Fake phone handler (static functions, like Local*.gd). State: Engine meta a1_avail / a1_delay / a1_fail / a1_last.
class Fake:
	static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
		Engine.set_meta("a1_last", {"method": method, "path": path, "query": query, "body": body})
		for i in int(Engine.get_meta("a1_delay", 0)):
			await Engine.get_main_loop().process_frame
		var fc: String = str(Engine.get_meta("a1_fail", ""))
		if fc != "":
			return LocalApi.fail(fc)
		return LocalApi.ok({"x": 1})

	static func is_available() -> bool:
		return bool(Engine.get_meta("a1_avail", true))

	static func unavailable_reason() -> Dictionary:
		return {"err_code": "pack_missing", "text_ko": "시험용 핸들러가 꺼져 있어요."}


class FakeAi:
	static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
		return await Fake.handle(method, path, query, body)

	static func is_available() -> bool:
		return bool(Engine.get_meta("a1_avail_ai", true))

	static func unavailable_reason() -> Dictionary:
		return {"err_code": "no_ai", "text_ko": ""}


## A handler that exists but whose pack is damaged.
class FakeCorrupt:
	static func handle(_m: String, _p: String, _q: Dictionary, _b: Dictionary) -> Dictionary:
		return LocalApi.fail("pack_corrupt")

	static func is_available() -> bool:
		return false

	static func unavailable_reason() -> Dictionary:
		return {"err_code": "pack_corrupt", "text_ko": ""}


## In-process fake PC for the P0 retry tests: one HTTP answer per connection. reply: "ok" (200 JSON with pc_marker),
## "500" (HTTP 500 JSON) or "hang" (no answer, closes after 1.5 s). Listens on a free local port (port 0 = chosen by the OS).
class FakePc:
	extends Node
	var srv: TCPServer = null
	var log: Array = [] ## {path, raw}
	var reply: String = "ok"
	var conns: Array = []

	func start() -> int:
		srv = TCPServer.new()
		if srv.listen(0, "127.0.0.1") != OK:
			srv = null
			return -1
		return srv.get_local_port()

	func stop() -> void:
		if srv != null:
			srv.stop()
			srv = null
		for c in conns:
			if c is StreamPeerTCP:
				(c as StreamPeerTCP).disconnect_from_host()
		conns.clear()

	func _process(_d: float) -> void:
		if srv != null and srv.is_listening():
			while srv.is_connection_available():
				var peer: StreamPeerTCP = srv.take_connection()
				conns.append(peer)
				_serve(peer)

	func _serve(peer: StreamPeerTCP) -> void:
		var buf := PackedByteArray()
		var head_end: int = -1
		var clen: int = 0
		var head: String = ""
		var t0: int = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 20000:
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() == 0:
				break
			var n: int = peer.get_available_bytes()
			if n > 0:
				var got: Array = peer.get_data(n)
				if int(got[0]) == OK:
					buf.append_array(got[1])
			if head_end < 0:
				var s: String = buf.slice(0, mini(buf.size(), 8192)).get_string_from_ascii()
				var i: int = s.find("\r\n\r\n")
				if i >= 0:
					head_end = i + 4
					head = s.substr(0, i)
					for line in head.split("\r\n"):
						if line.to_lower().begins_with("content-length:"):
							clen = int(line.substr(15).strip_edges())
			if head_end >= 0 and buf.size() >= head_end + clen:
				_answer(peer, head, buf.slice(head_end, head_end + clen))
				return
			await get_tree().process_frame
		peer.disconnect_from_host()

	func _answer(peer: StreamPeerTCP, head: String, body: PackedByteArray) -> void:
		var first: PackedStringArray = head.split("\r\n")[0].split(" ")
		log.append({"path": first[1].split("?")[0], "raw": body.get_string_from_utf8()})
		if reply == "hang":
			# Never answers, but closes after 1.5 s: Godot 4.6.3 blocks the main thread when a threaded request times out while the
			# server keeps the connection open (see Api.ApiCall.cancel), so the test must not rely on the request timeout.
			await get_tree().create_timer(1.5).timeout
			peer.disconnect_from_host()
			return
		var code: int = 200 if reply == "ok" else 500
		var payload: Dictionary = {"transcript": "pc answer", "score": 88, "pc_marker": 1} if reply == "ok" else {"error": "pc broke"}
		var data: PackedByteArray = JSON.stringify(payload).to_utf8_buffer()
		var hd := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, data.size()]
		peer.put_data(hd.to_utf8_buffer())
		peer.put_data(data)
		peer.disconnect_from_host()


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


## LocalApi.split_query: an encoded NUL (%00) must not swallow the rest of a value or the following parameters.
func _t_split_query() -> void:
	var r: Array = LocalApi.split_query("/practice/sentences?q=a%00b&lang=ja&n=5")
	ok(r[0] == "/practice/sentences", "split_query path")
	ok(str(r[1].get("lang", "")) == "ja", "split_query keeps lang after %00")
	ok(str(r[1].get("n", "")) == "5", "split_query keeps n after %00")
	ok(str(r[1].get("q", "")) == "ab", "split_query drops only the NUL (got '%s')" % str(r[1].get("q", "")))
	var r2: Array = LocalApi.split_query("/x?a%00z=1&b=%E3%81%82")
	ok(r2[1].has("az") and str(r2[1]["az"]) == "1", "split_query NUL in key")
	ok(str(r2[1].get("b", "")) == "あ", "split_query utf-8 value")
	var r3: Array = LocalApi.split_query("/x?lang=en&lang2=%00")
	ok(str(r3[1].get("lang", "")) == "en" and r3[1].has("lang2") and str(r3[1]["lang2"]) == "", "split_query value only NUL")
	for v in r[1].values() + r2[1].values() + r3[1].values() + r[1].keys() + r2[1].keys():
		ok(str(v).find(char(0)) < 0, "split_query no NUL in output")


func _ready() -> void:
	print("== route_test start ==")
	_t_split_query()
	Store.prefs_path = "user://test_a1_prefs.json"
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Route.clock = func() -> float: return _t
	Route.fell_back.connect(func(p: String) -> void: _fell_back.append(p))
	Route.mode_changed.connect(func(m: String) -> void: _modes_seen.append(m))
	Api.auth_failed.connect(func(_c: String) -> void: _auth_failed += 1)
	_install_fakes()
	Api.base_url = DEAD_PC
	Route.pc_ready_hook = func() -> bool: return true
	Route.phone_hook = func() -> bool: return _is_phone

	_test_policy_constants()
	_test_decide_table()
	_test_checker_self_test()
	_test_pc_platform_table()
	_test_no_policy_paths()
	_test_health_rule()
	_test_why_none()
	_test_caps()
	ok(_caps_done, "caps section ran to its end (no script error cut it short)")
	_test_mode_prefs()
	await _test_dispatch()
	await _test_api_phone_path()
	await _test_no_handler_files()
	ok(_nohandler_done, "no-handler section ran to its end (no script error cut it short)")
	await _test_api_none_and_explicit()
	await _test_cancel()
	await _test_fallback()
	await _test_no_fallback_cases()
	await _test_auth_401()
	await _test_pc_mode_unchanged()
	await _test_pc_platform_requests()
	await _test_phone_curriculum()
	_test_err_texts()
	_test_p0_policy()
	_test_p0_decide_table()
	await _test_p0_err_codes()
	_test_p0_degraded()
	await _test_p0_retry()

	LocalApi.handler_override.clear()
	Route.phone_hook = Callable()
	Route.pc_ready_hook = Callable()
	Route.clock = Callable()
	print("(route_test ran %.1f s)" % ((Time.get_ticks_msec() - _start_msec) / 1000.0))
	print("== route_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _install_fakes() -> void:
	for k in ["lessons", "practice", "missions", "reading", "stt"]:
		LocalApi.handler_override[k] = Fake
	LocalApi.handler_override["ai"] = FakeAi
	Engine.set_meta("a1_avail", true)
	Engine.set_meta("a1_avail_ai", true)
	Engine.set_meta("a1_delay", 0)
	Engine.set_meta("a1_fail", "")


func _avail(v: bool) -> void:
	Engine.set_meta("a1_avail", v)
	Engine.set_meta("a1_avail_ai", v)


func _split_key(key: String) -> Array:
	var sp: PackedStringArray = key.split(" ")
	var path: String = sp[1]
	var body := {}
	if path.ends_with("#ai"):
		path = path.trim_suffix("#ai")
		body = {"source": "ai"}
	elif path.ends_with("#ph"):
		path = path.trim_suffix("#ph")
		body = {"need_ph": true}
	return [sp[0], path, body]


# ------------------------------------------------------------------------------------------------ tests

func _test_policy_constants() -> void:
	print("[policy table]")
	ok(Route.POLICY.size() == SPEC.size(), "POLICY has %d rows (expected %d)" % [Route.POLICY.size(), SPEC.size()])
	var bad := 0
	for key in SPEC.keys():
		var e: Dictionary = Route.POLICY.get(key, {})
		if e.is_empty() or str(e["prefer"]) != SPEC[key][0] or str(e["phone"]) != SPEC[key][1] or not bool(e["pc"]):
			bad += 1
			print("    policy mismatch: ", key)
	ok(bad == 0, "every POLICY row matches the design table (bad=%d)" % bad)
	ok(Route.CAP_KEYS.size() == 16, "16 capability keys")
	var cap_ok := true
	for k in Route.CAP_KEYS:
		cap_ok = cap_ok and Route.CAP_PATH.has(k)
	ok(cap_ok, "every capability key has a CAP_PATH")
	ok(Route.policy_for("POST", "/lesson", {"source": "ai"}).get("phone", "") == "ai", "POST /lesson source=ai -> ai handler")
	ok(Route.policy_for("POST", "/lesson", {}).get("phone", "") == "lessons", "POST /lesson -> lessons handler")
	ok(Route.policy_for("POST", "/sync/push", {}).is_empty(), "/sync/push has no policy entry")


func _expected(mode: String, prefer: String, phone_key: String, key: String, ready: bool, avail: bool, possible: bool, phone_app: bool = true) -> String:
	if not phone_app:
		return "pc"   # the PC app never uses phone handlers, whatever mode / policy / readiness
	if key in NOPOLICY:
		return "none" if mode == "phone" else "pc"
	if key == "GET /health":
		return "none" if mode == "phone" else "pc"
	var phone_ok: bool = phone_key != "" and (phone_key == "health" or phone_key == "curriculum" or avail)
	var idx: int = (4 if ready else 0) + (2 if phone_ok else 0) + (1 if possible else 0)
	if mode == "pc":
		return EXPECT_PC_MODE[idx]
	if mode == "phone":
		return EXPECT_PHONE_MODE[idx]
	return EXPECT_AUTO_PHONE[idx] if prefer == "phone" else EXPECT_AUTO_PC[idx]


## Runs every combination; returns [combos, mismatches]. `sabotage` flips one expected cell (checker self test).
## `phone_app` = what Route.is_phone() answers during the run.
func _run_table(sabotage: bool, phone_app: bool = true) -> Array:
	_is_phone = phone_app
	var combos := 0
	var mismatches: Array = []
	for mode in Route.MODES:
		for ready in [true, false]:
			for avail in [true, false]:
				for variant in ["possible", "no_base_url", "flaky"]:
					Route.mode = mode
					Route.pc_ready_hook = func() -> bool: return ready
					_avail(avail)
					Route.clear_flaky()
					Api.base_url = "" if variant == "no_base_url" else DEAD_PC
					if variant == "flaky":
						Route.mark_pc_flaky()
					var possible: bool = variant == "possible"
					for key in _all_keys():
						var sp: Array = _split_key(key)
						var got: String = Route.decide(sp[0], sp[1], sp[2])
						var spec: Array = SPEC.get(key, ["pc", ""])
						var want: String = _expected(mode, spec[0], spec[1], key, ready, avail, possible, phone_app)
						if sabotage and combos == 0:
							want = "phone" if want != "phone" else "none"
						combos += 1
						if got != want:
							mismatches.append("%s mode=%s ready=%s avail=%s %s: got %s want %s" % [key, mode, ready, avail, variant, got, want])
	Route.mode = "auto"
	Route.clear_flaky()
	Api.base_url = DEAD_PC
	Route.pc_ready_hook = func() -> bool: return true
	_avail(true)
	_is_phone = true
	return [combos, mismatches]


func _all_keys() -> Array:
	# The "#ph" row is covered by its own table (_test_p0_decide_table); this one stays the 26-key table of A1.
	return SPEC.keys().filter(func(k: String) -> bool: return not k.ends_with("#ph")) + NOPOLICY


func _test_decide_table() -> void:
	print("[A1-2 decide() against the expected table]")
	var r: Array = _run_table(false)
	for m in (r[1] as Array).slice(0, 10):
		print("    ", m)
	print("    table: %d combinations (22 policy rows + 4 no-policy paths, x 3 modes x ready 2 x phone 2 x pc 3 variants)" % r[0])
	ok(r[0] == 26 * 3 * 2 * 2 * 3, "phone app table covers 936 combinations (got %d)" % r[0])
	ok((r[1] as Array).is_empty(), "phone app: decide() matches the expected table in all combinations (%d mismatches)" % (r[1] as Array).size())


func _test_checker_self_test() -> void:
	print("[A1-9 the table check really fails on a wrong cell]")
	var r: Array = _run_table(true)
	ok((r[1] as Array).size() == 1, "one deliberately wrong expected cell is reported as exactly 1 mismatch (got %d)" % (r[1] as Array).size())
	var r2: Array = _run_table(true, false)
	ok((r2[1] as Array).size() == 1, "the same for the PC platform table (got %d)" % (r2[1] as Array).size())
	# A decide() that ignored the platform would be caught: the phone expectations are not the PC expectations.
	var differs := 0
	for key in _all_keys():
		var spec: Array = SPEC.get(key, ["pc", ""])
		if _expected("phone", spec[0], spec[1], key, true, true, true, true) != _expected("phone", spec[0], spec[1], key, true, true, true, false):
			differs += 1
	ok(differs > 0, "expectations differ between phone app and PC app in phone mode (%d keys), so the table can tell them apart" % differs)


func _test_pc_platform_table() -> void:
	print("[PC app: every path goes to the PC, whatever the mode or the policy]")
	var r: Array = _run_table(false, false)
	for m in (r[1] as Array).slice(0, 10):
		print("    ", m)
	ok(r[0] == 26 * 3 * 2 * 2 * 3, "PC app table covers 936 combinations (got %d)" % r[0])
	ok((r[1] as Array).is_empty(), "PC app: decide() is 'pc' in every combination (%d mismatches)" % (r[1] as Array).size())
	_is_phone = false
	Route.mode = "phone"
	ok(Route.decide("GET", "/curriculum") == "pc" and Route.decide("POST", "/chat") == "pc" and Route.decide("GET", "/health") == "pc", "PC app + phone mode in prefs: still pc")
	Route.mode = "auto"
	_is_phone = true


func _test_no_policy_paths() -> void:
	print("[no-policy paths on the phone: auto/pc -> pc, phone mode -> none]")
	_is_phone = true
	for key in NOPOLICY:
		var sp: Array = _split_key(key)
		Route.mode = "auto"
		ok(Route.decide(sp[0], sp[1]) == "pc", key + ": auto -> pc")
		Route.mode = "pc"
		ok(Route.decide(sp[0], sp[1]) == "pc", key + ": pc mode -> pc")
		Route.mode = "phone"
		ok(Route.decide(sp[0], sp[1]) == "none", key + ": phone mode -> none")
		var w: Dictionary = Route.why_none(sp[0], sp[1])
		ok(w["err_code"] == "not_on_phone" and w["text_ko"] != "", key + ": why_none -> not_on_phone with Korean text")
	Route.mode = "auto"

func _test_health_rule() -> void:
	print("[A1-7 GET /health probes the PC only]")
	Route.mode = "auto"
	ok(Route.decide("GET", "/health") == "pc", "auto: /health -> pc")
	ok(Route.decide("GET", "/health?x=1") == "pc", "auto: /health?x=1 -> pc")
	Route.mode = "pc"
	ok(Route.decide("GET", "/health") == "pc", "pc: /health -> pc")
	Route.mode = "phone"
	ok(Route.decide("GET", "/health") == "none", "phone: /health -> none (never the synthetic phone /health)")
	Route.mode = "auto"
	Route.pc_ready_hook = func() -> bool: return false
	ok(Route.decide("GET", "/health") == "pc", "auto, PC not ready: /health still -> pc")
	Route.pc_ready_hook = func() -> bool: return true


func _test_why_none() -> void:
	print("[why_none]")
	_avail(true)
	Route.mode = "phone"
	ok(Route.why_none("POST", "/prosody")["err_code"] == "not_on_phone", "phone mode, no handler -> not_on_phone")
	ok(Route.why_none("POST", "/sync/push")["err_code"] == "not_on_phone", "no policy entry -> not_on_phone")
	_avail(false)
	ok(Route.why_none("POST", "/chat")["err_code"] == "no_ai", "handler off -> the handler's reason (no_ai)")
	ok(Route.why_none("POST", "/chat")["text_ko"] != "", "empty handler text falls back to the Korean ERR_TEXT")
	ok(Route.why_none("POST", "/lesson")["err_code"] == "pack_missing", "lessons off -> pack_missing")
	Route.mode = "pc"
	Api.base_url = ""
	ok(Route.why_none("POST", "/chat")["err_code"] == "not_connected", "pc mode without a PC address -> not_connected")
	Api.base_url = DEAD_PC
	Route.mode = "auto"
	_avail(true)


## Stage 1 has no LocalStt / LocalAi file: a phone without a PC must say "needs the PC", never "reinstall the app".
## Handlers that exist keep their own reason (pack_missing / pack_corrupt).
func _test_no_handler_files() -> void:
	print("[handler file missing -> needs_pc, handler present -> its own reason]")
	var saved_ov: Dictionary = LocalApi.handler_override.duplicate()
	var saved_adapter = SystemTts.adapter
	SystemTts.adapter = VoiceFake.new()
	Tts._sys = null
	var saved_hook: Callable = Route.pc_ready_hook
	var saved_base: String = Api.base_url
	Route.pc_ready_hook = func() -> bool: return false
	Api.base_url = ""
	_is_phone = true
	Route.mode = "auto"
	Route.clear_flaky()
	# null override = the handler file is absent (LocalApi.has_handler_file false).
	LocalApi.handler_override["stt"] = null
	LocalApi.handler_override["ai"] = null
	ok(not LocalApi.has_handler_file("stt") and not LocalApi.has_handler_file("ai"), "override null -> has_handler_file false")
	ok(LocalApi.has_handler_file("lessons"), "fake lessons handler -> has_handler_file true")
	var items: Dictionary = Route.caps()["items"]
	var all7 := true
	var no_reinstall := true
	for k in ["stt", "score", "chat", "fix", "feedback", "lesson_ai", "missions_judge"]:
		var it: Dictionary = items[k]
		var good: bool = str(it["use"]) == "none" and str(it["why"]) == "needs_pc"
		if not good:
			print("    caps row ", k, " -> ", it)
		all7 = all7 and good
		no_reinstall = no_reinstall and not CapabilityPanel.reason_text(it, "auto").contains("다시 설치")
	ok(all7, "no PC, no handler file: caps stt/score/chat/fix/feedback/lesson_ai/missions_judge -> none / needs_pc")
	ok(no_reinstall, "capability panel text of those 7 rows has no 'reinstall' sentence")
	ok(Route.why_none("POST", "/chat")["err_code"] == "needs_pc" and Route.why_none("POST", "/score")["err_code"] == "needs_pc", "why_none /chat and /score -> needs_pc")
	var needs_text: String = Route.text_for("needs_pc")
	var rc: Dictionary = await _req("POST", "/chat", {"messages": []})
	ok(not rc["ok"] and str(rc["err_code"]) == "needs_pc" and str(rc["error"]) == needs_text and not str(rc["error"]).contains("다시 설치"), "Api.post_json('/chat') -> needs_pc text")
	var rs: Dictionary = await _req("POST", "/score", {})
	ok(not rs["ok"] and str(rs["err_code"]) == "needs_pc" and str(rs["error"]) == needs_text, "Api.post_json('/score') -> needs_pc text")
	for path in ["/stt", "/fix", "/feedback", "/missions/judge"]:
		var r: Dictionary = await _req("POST", path, {})
		ok(not r["ok"] and str(r["err_code"]) == "needs_pc", "Api.post_json('" + path + "') -> needs_pc")
	var rl: Dictionary = await _req("POST", "/lesson", {"source": "ai", "lang": "en"})
	ok(not rl["ok"] and str(rl["err_code"]) == "needs_pc", "Api.post_json('/lesson' source ai) -> needs_pc")
	var rd: Dictionary = await LocalApi.dispatch("POST", "/chat", {})
	ok(not rd["ok"] and str(rd["err_code"]) == "needs_pc", "LocalApi.dispatch /chat without a handler file -> needs_pc")
	# The real build: when the real handler file does not exist yet, the real LocalApi says needs_pc too.
	LocalApi.handler_override.clear()
	LocalApi._loaded.clear()
	for k in ["stt", "ai"]:
		if not ResourceLoader.exists(str(LocalApi.HANDLERS[k])):
			ok(not LocalApi.has_handler_file(k) and Route.why_none("POST", "/chat" if k == "ai" else "/stt")["err_code"] == "needs_pc", "real build, no " + k + " handler file -> needs_pc")
	# A handler that exists keeps its own reason.
	LocalApi.handler_override["stt"] = FakeCorrupt
	ok(LocalApi.has_handler_file("stt") and Route.why_none("POST", "/stt")["err_code"] == "pack_corrupt", "handler present, pack damaged -> pack_corrupt")
	var rcor: Dictionary = await LocalApi.dispatch("POST", "/stt", {})
	ok(not rcor["ok"] and str(rcor["err_code"]) == "pack_corrupt", "dispatch to a handler with a damaged pack -> pack_corrupt")
	LocalApi.handler_override["stt"] = Fake
	_avail(false)
	ok(Route.why_none("POST", "/stt")["err_code"] == "pack_missing" and Route.caps()["items"]["stt"]["why"] == "pack_missing", "handler present, pack missing -> pack_missing")
	_avail(true)
	LocalApi.handler_override = saved_ov
	SystemTts.adapter = saved_adapter
	Tts._sys = null
	Route.pc_ready_hook = saved_hook
	Api.base_url = saved_base
	Route.mode = "auto"
	_nohandler_done = true


func _test_caps() -> void:
	print("[caps]")
	var saved_adapter = SystemTts.adapter
	SystemTts.adapter = VoiceFake.new() # no system voice
	Tts._sys = null
	Route.mode = "auto"
	_avail(true)
	Route.clear_flaky()
	var c: Dictionary = Route.caps()
	var items: Dictionary = c["items"]
	ok(items.size() == 16, "caps has 16 items")
	var same := true
	for k in Route.CAP_KEYS:
		same = same and items.has(k)
	ok(same, "caps keys == CAP_KEYS")
	var shape := true
	for k in items.keys():
		var it: Dictionary = items[k]
		shape = shape and it.has("use") and it.has("phone") and it.has("pc") and it.has("why") and it["use"] in ["phone", "pc", "none"]
	ok(shape, "every item has use(phone|pc|none)/phone/pc/why")
	ok(c["mode"] == "auto" and bool(c["pc"]["connected"]) and not bool(c["pc"]["flaky"]), "caps header: mode auto, connected, not flaky")
	ok(items["lesson"]["use"] == "phone" and items["lesson"]["phone"] == true and items["lesson"]["pc"] == true, "lesson: phone available, prefer phone -> phone")
	ok(items["chat"]["use"] == "pc" and items["chat"]["phone"] == true, "chat: prefer pc, PC ready -> pc")
	ok(items["prosody"]["use"] == "pc" and items["prosody"]["phone"] == false, "prosody: pc only")
	ok(items["phoneme"]["phone"] == false, "phoneme: never on the phone in stage 1")
	_avail(false)
	Route.pc_ready_hook = func() -> bool: return false
	Api.base_url = ""
	var c2: Dictionary = Route.caps()
	var i2: Dictionary = c2["items"]
	ok(i2["chat"]["use"] == "none" and i2["chat"]["why"] == "no_ai", "no PC, AI off: chat none / no_ai")
	ok(i2["prosody"]["use"] == "none" and i2["prosody"]["why"] == "not_on_phone", "no PC: prosody none / not_on_phone")
	ok(i2["phoneme"]["use"] == "none" and i2["phoneme"]["why"] == "not_on_phone", "no PC: phoneme none / not_on_phone")
	ok(i2["stt"]["use"] == "none" and i2["stt"]["why"] == "pack_missing", "no PC, stt handler present but off: none / the handler's own reason (pack_missing)")
	ok(i2["tts"]["use"] == "none" and i2["tts"]["phone"] == false and i2["tts"]["pc"] == false, "no PC, no system TTS yet: tts none")
	ok(i2["lesson"]["use"] == "none" and i2["lesson"]["why"] == "pack_missing", "no PC, lessons off: lesson none / pack_missing")
	ok(not bool(c2["pc"]["connected"]), "caps header: not connected")
	Api.base_url = DEAD_PC
	Route.pc_ready_hook = func() -> bool: return true
	_avail(true)
	Route.mode = "phone"
	var i3: Dictionary = Route.caps()["items"]
	ok(i3["chat"]["use"] == "phone" and i3["tts"]["use"] == "none", "phone mode: chat on the phone, tts none (no phone TTS yet)")
	ok(i3["phoneme"]["use"] == "none", "phone mode: phoneme none")
	var vf := VoiceFake.new()
	vf.voices = [{"name": "English", "id": "en-a", "language": "en_US"}]
	SystemTts.adapter = vf
	Tts._sys = null
	var i4: Dictionary = Route.caps()["items"]
	ok(i4["tts"]["use"] == "phone" and i4["tts"]["phone"] == true, "phone mode with a system voice: tts on the phone")
	SystemTts.adapter = saved_adapter
	Tts._sys = null
	Route.mode = "auto"
	_caps_done = true


func _test_mode_prefs() -> void:
	print("[F3 route_mode normalisation, set_mode]")
	Store.prefs["route_mode"] = "아무거나"
	Route._ready()
	ok(Route.mode == "auto", "prefs.route_mode='아무거나' -> auto")
	Store.prefs["route_mode"] = "phone"
	Route._ready()
	ok(Route.mode == "phone", "prefs.route_mode='phone' -> phone")
	Route.mode = "garbage"
	ok(Route.decide("POST", "/chat") in ["pc", "phone", "none"], "a garbage Route.mode does not crash decide()")
	ok(Route.normalize_mode("") == "auto" and Route.normalize_mode("PC") == "auto", "normalize_mode: '' and 'PC' -> auto")
	_modes_seen.clear()
	Route.set_mode("pc")
	ok(Route.mode == "pc" and Store.prefs["route_mode"] == "pc" and _modes_seen == ["pc"], "set_mode('pc') saves the pref and emits mode_changed")
	Route.set_mode("bogus")
	ok(Route.mode == "auto" and Store.prefs["route_mode"] == "auto", "set_mode('bogus') -> auto")
	Route.mode = "auto"


func _test_dispatch() -> void:
	print("[LocalApi.dispatch / health / curriculum]")
	_avail(true)
	Route.mode = "auto"
	var n0: int = LocalApi.served_count
	var f0: int = get_tree().get_frame()
	var r: Dictionary = await LocalApi.dispatch("GET", "/practice/sentences?lang=en&n=5", {})
	ok(get_tree().get_frame() > f0, "dispatch yields at least one frame before the result")
	ok(r["ok"] == true and r["code"] == 200 and r["data"]["x"] == 1 and r["data"]["via"] == "phone" and (r["data"]["degraded"] as Array).is_empty(), "handler result: ok, via phone, degraded []")
	for k in ["ok", "code", "data", "bytes", "error", "cancelled", "err_code", "err_body"]:
		if not r.has(k):
			ok(false, "result has key " + k)
	ok(LocalApi.served_count == n0 + 1, "served_count +1")
	var last: Dictionary = Engine.get_meta("a1_last")
	ok(last["method"] == "GET" and last["path"] == "/practice/sentences" and last["query"] == {"lang": "en", "n": "5"}, "handler got method, path without query, parsed query")
	var pr: Dictionary = await LocalApi.dispatch("POST", "/prosody", {})
	ok(not pr["ok"] and pr["err_code"] == "not_on_phone" and pr["code"] == 503 and pr["error"] != "", "no handler -> not_on_phone / 503 / Korean text")
	var h: Dictionary = (await LocalApi.dispatch("GET", "/health", {}))["data"]
	var keys_ok := true
	for k in LocalApi.HEALTH_TEMPLATE.keys():
		keys_ok = keys_ok and h.has(k)
	ok(keys_ok and h["via"] == "phone" and h["ok"] == true, "synthetic /health has every PC key")
	ok(h["stt"] == true and h["score"] == true and h["llm"] == true and h["llm_provider"] == "openai_api", "health: stt/score/llm follow the handlers")
	ok(h["phoneme"] == false and h["grammar"] == false and h["tatoeba"] == PackLoader.has_file("examples_en.json"), "health: phoneme/grammar false, tatoeba from the pack")
	ok(h["tts"] is Dictionary and h["tts"].has("en") and h["tts"].has("ja"), "health.tts is {en, ja}")
	_avail(false)
	var h2: Dictionary = (await LocalApi.dispatch("GET", "/health", {}))["data"]
	ok(h2["stt"] == false and h2["score"] == false and h2["llm"] == false and h2["llm_provider"] == "none", "health: handlers off -> false / none")
	_avail(true)
	var cur: Dictionary = await LocalApi.dispatch("GET", "/curriculum", {})
	ok(cur["ok"] and cur["data"]["via"] == "phone" and Store._valid_curriculum(cur["data"]), "GET /curriculum -> bundled curriculum (en/ja months)")
	ok((cur["data"]["en"]["months"] as Array).size() == (Store.curriculum["en"]["months"] as Array).size(), "curriculum has the same month count as Store's")
	LocalApi.handler_override["practice"] = null
	var miss: Dictionary = await LocalApi.dispatch("GET", "/practice/ping", {})
	ok(not miss["ok"] and miss["err_code"] == "needs_pc" and miss["code"] == 503, "handler override null / missing handler file -> needs_pc (not pack_missing)")
	LocalApi.handler_override["practice"] = Fake


func _req(method: String, path: String, body: Dictionary = {}, report: bool = false) -> Dictionary:
	var c: Object
	if method == "GET":
		c = Api.get_json(path, REQ_TIMEOUT, report)
	else:
		c = Api.post_json(path, body, REQ_TIMEOUT, report)
	return await c.wait()


func _test_api_phone_path() -> void:
	print("[A1-4 phone requests do not touch the network]")
	Route.mode = "phone"
	_avail(true)
	var s0: int = Api.sent_count
	var a0: int = Api.active_count
	var n0: int = LocalApi.served_count
	var c: Object = Api.post_json("/lesson", {"lang": "en"}, 5.0, false)
	ok(Api.active_count == a0 + 1, "active_count +1 while the phone works")
	var res: Dictionary = await c.wait()
	ok(res["ok"] and res["data"]["via"] == "phone" and res["data"]["x"] == 1, "POST /lesson in phone mode -> handler result")
	ok(Api.sent_count == s0, "A1-4: sent_count unchanged (%d -> %d)" % [s0, Api.sent_count])
	ok(Api.active_count == a0, "active_count back to %d" % a0)
	ok(LocalApi.served_count == n0 + 1, "served_count +1")
	var g: Dictionary = await _req("GET", "/practice/sentences?lang=ja&n=3")
	ok(g["ok"] and (Engine.get_meta("a1_last") as Dictionary)["query"] == {"lang": "ja", "n": "3"}, "GET with query reaches the handler parsed")
	ok(Api.sent_count == s0, "still no request sent")
	Route.mode = "auto"
	var a: Dictionary = await _req("POST", "/missions/check", {})
	ok(a["ok"] and a["data"]["via"] == "phone" and Api.sent_count == s0, "auto + prefer phone + handler ready -> phone, nothing sent")
	Engine.set_meta("a1_fail", "pack_corrupt")
	var f: Dictionary = await _req("POST", "/lesson", {}, true)
	ok(not f["ok"] and f["err_code"] == "pack_corrupt" and f["code"] == 503 and f["error"] != "", "handler failure -> err_code, 503, Korean text (report=true toast path ran)")
	Engine.set_meta("a1_fail", "")
	Route.mode = "auto"


func _test_api_none_and_explicit() -> void:
	print("[none -> immediate failure; explicit addresses are not routed]")
	Route.mode = "phone"
	var s0: int = Api.sent_count
	var a0: int = Api.active_count
	var res: Dictionary = await _req("POST", "/prosody", {})
	ok(not res["ok"] and res["err_code"] == "not_on_phone" and res["code"] == 503 and res["error"] != "" and not res["cancelled"], "phone mode, no handler -> not_on_phone 503")
	ok(res["err_body"] is Dictionary and res["err_body"]["via"] == "phone" and res["err_body"]["code"] == "not_on_phone" and res["err_body"]["error"] == res["error"], "err_body {error, code, via:'phone'}")
	ok(Api.sent_count == s0 and Api.active_count == a0, "none: nothing sent, active_count back")
	var sy: Dictionary = await _req("POST", "/sync/push", {})
	ok(not sy["ok"] and sy["err_code"] == "not_on_phone" and sy["code"] == 503 and Api.sent_count == s0, "phone mode: POST /sync/push (no policy) fails at once as not_on_phone, nothing sent")
	var lan: Dictionary = await _req("GET", "/lan/info")
	ok(not lan["ok"] and lan["err_code"] == "not_on_phone" and Api.sent_count == s0, "phone mode: GET /lan/info fails at once, nothing sent")
	var hz: Dictionary = await _req("GET", "/health")
	ok(not hz["ok"] and hz["err_code"] != "" and Api.sent_count == s0, "phone mode: GET /health fails at once, nothing sent")
	_avail(false)
	var r2: Dictionary = await _req("POST", "/chat", {}, true)
	ok(not r2["ok"] and r2["err_code"] == "no_ai" and r2["code"] == 503, "phone mode, AI off -> no_ai")
	_avail(true)
	var s1: int = Api.sent_count
	var n0: int = LocalApi.served_count
	var e: Dictionary = await Api.get_json_to(DEAD_PC, "/lesson", REQ_TIMEOUT, false).wait()
	ok(Api.sent_count == s1 + 1 and not e["ok"] and e["err_code"] == "transport", "A1-7: get_json_to goes to the network (sent +1, transport error), not to the phone")
	var e2: Dictionary = await Api.post_json_to(DEAD_PC, "/lesson", {}, REQ_TIMEOUT, false).wait()
	ok(Api.sent_count == s1 + 2 and e2["err_code"] == "transport", "post_json_to is not routed either")
	ok(LocalApi.served_count == n0, "no phone handler ran for explicit-address requests")
	Route.mode = "auto"


func _test_cancel() -> void:
	print("[A1-5 cancel during phone work]")
	Route.mode = "phone"
	_avail(true)
	Engine.set_meta("a1_delay", 4)
	var s0: int = Api.sent_count
	var a0: int = Api.active_count
	var n0: int = LocalApi.served_count
	var c: Object = Api.post_json("/lesson", {}, 5.0, false)
	await get_tree().process_frame
	await get_tree().process_frame
	ok(not c.done, "request still running after 2 frames")
	c.cancel()
	var res: Dictionary = await c.wait()
	ok(res["cancelled"] == true and res["ok"] == false, "cancel() -> cancelled:true")
	ok(Api.active_count == a0, "active_count back to %d right after cancel" % a0)
	for i in 10:
		await get_tree().process_frame
	ok(c.result["cancelled"] == true and c.result["ok"] == false, "late handler result is ignored")
	ok(Api.active_count == a0 and Api.sent_count == s0, "active_count stays %d, sent_count unchanged" % a0)
	ok(LocalApi.served_count == n0 + 1, "the handler did run (and its result was dropped)")
	var c2: Object = Api.post_json("/lesson", {}, 5.0, false)
	c2.cancel()
	var r2: Dictionary = await c2.wait()
	for i in 8:
		await get_tree().process_frame
	ok(r2["cancelled"] and c2.result["cancelled"] and Api.active_count == a0, "cancel in the same frame: cancelled, active_count %d" % a0)
	Engine.set_meta("a1_delay", 0)
	Route.mode = "auto"


func _test_fallback() -> void:
	print("[A1-6 PC transport error -> phone, then 60 s without the PC]")
	Route.mode = "auto"
	Route.clear_flaky()
	_fell_back.clear()
	_avail(true)
	Api.base_url = DEAD_PC
	Route.pc_ready_hook = func() -> bool: return true
	_t = 5000.0
	var t0: float = _t
	var s0: int = Api.sent_count
	ok(Route.decide("POST", "/reading/gloss") == "pc", "before: POST /reading/gloss (prefer pc, PC ready) -> pc")
	var res: Dictionary = await _req("POST", "/reading/gloss", {"text": "hi"})
	ok(Api.sent_count == s0 + 1, "the PC was tried once (sent_count +1)")
	ok(res["ok"] and res["data"]["via"] == "phone", "A1-6: the same request finished on the phone (data.via == phone)")
	ok(_fell_back == ["/reading/gloss"], "Route.fell_back emitted with the path")
	ok(Route.pc_flaky(), "pc_flaky() after the fallback")
	ok(Api.active_count == 0, "active_count back to 0")
	_t = t0 + 59.0
	var s1: int = Api.sent_count
	var r2: Dictionary = await _req("POST", "/reading/gloss", {"text": "hi"})
	ok(r2["ok"] and r2["data"]["via"] == "phone" and Api.sent_count == s1, "59 s later: phone again, sent_count unchanged")
	var r3: Dictionary = await _req("GET", "/examples?q=a")
	ok(r3["ok"] and Api.sent_count == s1, "59 s later: GET /examples also skips the PC")
	ok(Route.decide("POST", "/chat") == "phone", "59 s later: decide() says phone for prefer-pc paths")
	ok(_fell_back.size() == 1, "no second fallback while flaky")
	_t = t0 + 61.0
	ok(not Route.pc_flaky(), "61 s later: not flaky")
	var s2: int = Api.sent_count
	var r4: Dictionary = await _req("POST", "/reading/gloss", {"text": "hi"})
	ok(Api.sent_count == s2 + 1, "A1-6: 61 s later the PC is tried again (sent_count +1)")
	ok(r4["ok"] and r4["data"]["via"] == "phone" and _fell_back.size() == 2, "and the phone takes over once more")
	Route._last_fallback_toast = -1.0e9
	_t = 9000.0
	ok(Route.take_fallback_toast(), "fallback toast allowed the first time")
	_t = 9010.0
	ok(not Route.take_fallback_toast(), "not again within FALLBACK_TOAST_SEC")
	_t = 9000.0 + Route.FALLBACK_TOAST_SEC + 1.0
	ok(Route.take_fallback_toast(), "allowed again after FALLBACK_TOAST_SEC")
	Route.clear_flaky()
	Engine.set_meta("a1_delay", 4)
	var c: Object = Api.post_json("/reading/gloss", {}, REQ_TIMEOUT, false)
	await _wait_until(func() -> bool: return Route.pc_flaky(), 15.0)
	ok(Route.pc_flaky() and not c.done, "fallback started (flaky) and the call is still running")
	c.cancel()
	var cr: Dictionary = await c.wait()
	for i in 8:
		await get_tree().process_frame
	ok(cr["cancelled"] and c.result["cancelled"] and Api.active_count == 0, "cancel during the fallback: cancelled, late result dropped, active_count 0")
	Engine.set_meta("a1_delay", 0)
	Route.clear_flaky()


## Waits (real time, a connection to the closed port can take a few seconds on Windows) until `cond` is true.
func _wait_until(cond: Callable, max_sec: float) -> void:
	var t0: int = Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t0 < int(max_sec * 1000.0):
		await get_tree().process_frame


func _test_no_fallback_cases() -> void:
	print("[cases that must NOT fall back]")
	Route.mode = "auto"
	Route.clear_flaky()
	Api.base_url = DEAD_PC
	Route.pc_ready_hook = func() -> bool: return true
	_t = 20000.0
	_fell_back.clear()
	Engine.set_meta("a1_avail_ai", false)
	var s0: int = Api.sent_count
	var r: Dictionary = await _req("POST", "/chat", {"message": "hi"})
	ok(Api.sent_count == s0 + 1 and not r["ok"] and r["err_code"] == "transport", "POST /chat, phone AI off: PC tried, transport error stays")
	ok(not Route.pc_flaky() and _fell_back.is_empty(), "no fallback and no flaky mark")
	Engine.set_meta("a1_avail_ai", true)
	var r1: Dictionary = await _req("POST", "/chat", {"message": "hi"})
	ok(r1["ok"] and r1["data"]["via"] == "phone" and Route.pc_flaky(), "POST /chat, phone AI on: falls back to the phone AI")
	Route.clear_flaky()
	_fell_back.clear()
	var s1: int = Api.sent_count
	var h: Dictionary = await _req("GET", "/health")
	ok(Api.sent_count == s1 + 1 and not h["ok"] and h["err_code"] == "transport" and not Route.pc_flaky(), "GET /health failure: no fallback, no flaky mark")
	var u: Dictionary = await _req("POST", "/sync/push", {})
	ok(not u["ok"] and u["err_code"] == "transport" and not Route.pc_flaky(), "POST /sync/push (no policy): transport error stays")
	Route.mode = "pc"
	var s2: int = Api.sent_count
	var p: Dictionary = await _req("POST", "/reading/gloss", {})
	ok(Api.sent_count == s2 + 1 and not p["ok"] and p["err_code"] == "transport" and not Route.pc_flaky(), "mode pc: transport error stays, no fallback")
	Route.mode = "auto"
	_avail(false)
	var q: Dictionary = await _req("POST", "/reading/gloss", {})
	ok(not q["ok"] and q["err_code"] == "transport" and not Route.pc_flaky(), "phone handler off: transport error stays")
	_avail(true)
	ok(Api.is_fallback_safe(HTTPClient.METHOD_GET, "/anything?x=1"), "safe: any GET")
	ok(Api.is_fallback_safe(HTTPClient.METHOD_POST, "/reading/gloss") and Api.is_fallback_safe(HTTPClient.METHOD_POST, "/lesson"), "safe: /reading/*, /lesson")
	ok(Api.is_fallback_safe(HTTPClient.METHOD_POST, "/missions/check") and Api.is_fallback_safe(HTTPClient.METHOD_POST, "/missions/judge"), "safe: /missions/check, /missions/judge")
	ok(not Api.is_fallback_safe(HTTPClient.METHOD_POST, "/sync/pull") and not Api.is_fallback_safe(HTTPClient.METHOD_POST, "/mic/start"), "not safe: /sync/pull, /mic/start")


func _test_auth_401() -> void:
	print("[phone 401 (ai_auth) does not emit auth_failed]")
	Route.mode = "phone"
	_avail(true)
	Engine.set_meta("a1_fail", "ai_auth")
	var a0: int = _auth_failed
	var r: Dictionary = await _req("POST", "/chat", {})
	ok(not r["ok"] and r["code"] == 401 and r["err_code"] == "ai_auth", "phone AI key rejected -> code 401, ai_auth")
	ok(_auth_failed == a0, "auth_failed not emitted")
	Engine.set_meta("a1_fail", "")
	Route.mode = "auto"


func _test_pc_mode_unchanged() -> void:
	print("[mode pc keeps the old behaviour]")
	Route.mode = "pc"
	var n0: int = LocalApi.served_count
	var s0: int = Api.sent_count
	var r: Dictionary = await _req("POST", "/lesson", {})
	ok(Api.sent_count == s0 + 1 and not r["ok"] and r["err_code"] == "transport", "pc mode: /lesson goes to the PC (sent +1), phone handler unused")
	ok(LocalApi.served_count == n0, "pc mode: no phone handler ran")
	Api.base_url = ""
	var nc: Dictionary = await _req("POST", "/lesson", {})
	ok(not nc["ok"] and nc["err_code"] == "not_connected" and Api.sent_count == s0 + 1, "pc mode, no address: old not_connected failure, nothing sent")
	Api.base_url = DEAD_PC
	Route.mode = "auto"


func _test_pc_platform_requests() -> void:
	print("[PC app regression: GET /curriculum goes to the PC; no via/degraded keys reach the curriculum cache]")
	_is_phone = false
	Route.mode = "auto"
	Route.clear_flaky()
	Api.base_url = DEAD_PC
	_avail(true)
	for md in Route.MODES:
		Route.mode = md
		ok(Route.decide("GET", "/curriculum") == "pc", "PC app, mode %s: GET /curriculum -> pc (not the bundled copy)" % md)
	Route.mode = "auto"
	var cache := "user://test_a1_curriculum_cache.json"
	var old_path: String = Store.curriculum_cache_path
	var old_cur: Dictionary = Store.curriculum.duplicate(true)
	var old_flag: bool = Store.curriculum_from_backend
	Store.curriculum_cache_path = cache
	Store.curriculum_from_backend = false
	if FileAccess.file_exists(cache):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cache))
	# Store.refresh_curriculum uses Api's own 60 s timeout, so the PC address is empty here: Api answers "not_connected" at
	# once. The PC branch was taken if no phone handler ran and no bundled curriculum reached the cache.
	Api.base_url = ""
	var s0: int = Api.sent_count
	var n0: int = LocalApi.served_count
	await Store.refresh_curriculum()
	Api.base_url = DEAD_PC
	ok(LocalApi.served_count == n0, "Store.refresh_curriculum on the PC app: no phone handler served the request")
	ok(Api.sent_count == s0, "nothing sent (no PC address), and the failure is the PC one")
	ok(not Store.curriculum_from_backend, "the failed PC request does not mark the curriculum as 'from backend'")
	ok(not FileAccess.file_exists(cache), "no curriculum cache file was written")
	ok(not Store.curriculum.has("via") and not Store.curriculum.has("degraded"), "Store.curriculum has no via/degraded keys")
	ok(Store.curriculum == old_cur, "Store.curriculum unchanged")
	s0 = Api.sent_count
	var g: Dictionary = await _req("GET", "/curriculum")
	ok(not g["ok"] and g["err_code"] == "transport" and Api.sent_count > s0, "GET /curriculum on the PC app: sent to the PC, transport error (not a phone answer)")
	var fb0: int = _fell_back.size()
	var gl: Dictionary = await _req("POST", "/reading/gloss", {"text": "hi"})
	ok(not gl["ok"] and gl["err_code"] == "transport" and not Route.pc_flaky() and _fell_back.size() == fb0, "PC app: a transport error never falls back to the phone, no flaky mark")
	var n1: int = LocalApi.served_count
	ok(n1 == n0, "still no phone handler ran on the PC app")
	Store.curriculum_cache_path = old_path
	Store.curriculum = old_cur
	Store.curriculum_from_backend = old_flag
	_is_phone = true
	Route.mode = "auto"


func _test_err_texts() -> void:
	print("[ERR_TEXT / ERR_HTTP for bad_request and not_found]")
	for ec in ["bad_request", "not_found"]:
		ok(Route.ERR_TEXT.has(ec) and Route.ERR_TEXT[ec] != "" and Route.ERR_TEXT[ec] != Route.ERR_TEXT["needs_pc"], ec + ": own Korean text")
		ok(Route.text_for(ec) == Route.ERR_TEXT[ec], ec + ": text_for")
	ok(Route.http_for("bad_request") == 400 and Route.http_for("not_found") == 404, "bad_request -> 400, not_found -> 404")
	var f: Dictionary = LocalApi.fail("not_found")
	ok(not f["ok"] and f["code"] == 404 and f["err_code"] == "not_found" and f["error"] == Route.text_for("not_found") and f["err_body"]["code"] == "not_found", "LocalApi.fail('not_found') -> 404 with the Korean text")
	var f2: Dictionary = LocalApi.fail("bad_request")
	ok(f2["code"] == 400 and f2["error"] == Route.text_for("bad_request"), "LocalApi.fail('bad_request') -> 400")
	# every Korean text really contains Hangul
	var hangul := true
	for k in Route.ERR_TEXT.keys():
		var has := false
		for ch in str(Route.ERR_TEXT[k]):
			if ch.unicode_at(0) >= 0xAC00 and ch.unicode_at(0) <= 0xD7A3:
				has = true
				break
		hangul = hangul and has
	ok(hangul, "every ERR_TEXT entry is Korean")


## ------------------------------------------------------------------------------------------------ v2.0 P0

const P0_NEW_CODES := ["engine_error", "stt_timeout", "ai_offline", "ai_tls", "ai_model", "ai_url", "ai_key_format", "ja_ai_pc", "no_space"]
## Independent copies of the texts that must NOT change (design §3 #1: model_missing / engine_missing).
const P0_MODEL_MISSING := "음성 인식 모델이 아직 없어요. 설정 > 음성 인식에서 내려받으면(약 60 MB) 폰에서 바로 채점할 수 있어요. 지금은 녹음해서 들어 보고 스스로 평가할 수 있어요."
const P0_ENGINE_MISSING := "이 앱 빌드에는 폰 음성 인식이 들어 있지 않아요. PC에 연결하면 채점할 수 있어요."


func _set_sw(v: Variant) -> void:
	if v == null:
		Store.prefs.erase("score_where")
	else:
		Store.prefs["score_where"] = v


func _test_p0_policy() -> void:
	print("[P0-2 policy: score_where, need_ph]")
	var saved: Variant = Store.prefs.get("score_where", null)
	_set_sw(null)
	ok(Route.score_where() == "phone", "score_where() unset -> phone")
	ok(Route.policy_for("POST", "/score", {}).get("prefer", "") == "phone", "P0-2: /score, score_where unset -> prefer phone")
	ok(Route.policy_for("POST", "/stt", {}).get("prefer", "") == "phone", "P0-2: /stt, score_where unset -> prefer phone")
	var ph: Dictionary = Route.policy_for("POST", "/score", {"need_ph": true})
	ok(ph.get("prefer", "") == "pc" and ph.get("phone", "") == "stt" and bool(ph.get("pc", false)), "P0-2: /score + need_ph:true -> '#ph' entry, prefer pc, phone handler stt")
	ok(Route.POLICY.has("POST /score#ph") and str(Route.POLICY["POST /score#ph"]["prefer"]) == "pc", "POLICY has 'POST /score#ph' (prefer pc)")
	for odd in [false, "true", 1, null, "", []]:
		ok(Route.policy_for("POST", "/score", {"need_ph": odd}).get("prefer", "") == "phone", "need_ph=%s is not '#ph' (only the bool true is)" % str(odd))
	ok(Route.policy_for("POST", "/stt", {"need_ph": true}).get("prefer", "") == "phone", "/stt ignores need_ph")
	_set_sw("phone")
	ok(Route.policy_for("POST", "/score", {}).get("prefer", "") == "phone" and Route.policy_for("POST", "/stt", {}).get("prefer", "") == "phone", "score_where='phone' -> /stt and /score prefer phone")
	_set_sw("pc")
	ok(Route.score_where() == "pc", "score_where() 'pc'")
	ok(Route.policy_for("POST", "/score", {}).get("prefer", "") == "pc" and Route.policy_for("POST", "/stt", {}).get("prefer", "") == "pc", "P0-2: score_where='pc' -> /stt and /score prefer pc")
	ok(Route.policy_for("POST", "/score", {"need_ph": true}).get("prefer", "") == "pc", "score_where='pc': '#ph' still pc")
	for odd in ["아무거나", 5, null, "PC", "Phone", ["pc"], true]:
		_set_sw(odd)
		ok(Route.score_where() == "phone" and Route.policy_for("POST", "/score", {}).get("prefer", "") == "phone", "score_where=%s (odd value) is treated as phone" % str(odd))
	# Nothing else moves with score_where: every other row keeps the SPEC prefer, whatever the pref says.
	var bad := 0
	for sw in [null, "phone", "pc"]:
		_set_sw(sw)
		for key in SPEC.keys():
			if key == "POST /stt" or key == "POST /score":
				continue
			var sp: Array = _split_key(key)
			var e: Dictionary = Route.policy_for(sp[0], sp[1], sp[2])
			if str(e.get("prefer", "")) != SPEC[key][0] or str(e.get("phone", "")) != SPEC[key][1]:
				bad += 1
				print("    policy moved with score_where=", sw, ": ", key)
	ok(bad == 0, "no other POLICY row depends on score_where (AI paths stay pc-first) (bad=%d)" % bad)
	_set_sw(saved)


func _p0_expected(kind: String, mode: String, ready: bool, phone_ok: bool, sw: String) -> String:
	# Hand written (design §1.8), PC address set and not flaky. kind: stt | score | ph.
	var prefer: String = "pc" if (kind == "ph" or sw == "pc") else "phone"
	if mode == "pc":
		return "pc"
	if mode == "phone":
		return "phone" if phone_ok else "none"
	if prefer == "phone":
		return "phone" if phone_ok else "pc"
	if ready:
		return "pc"
	return "phone" if phone_ok else "pc"


func _p0_run_table(sabotage: bool) -> Array:
	var saved: Variant = Store.prefs.get("score_where", null)
	_is_phone = true
	Route.clear_flaky()
	Api.base_url = DEAD_PC
	var rows := 0
	var bad: Array = []
	for kind in ["stt", "score", "ph"]:
		var path: String = "/stt" if kind == "stt" else "/score"
		var body: Dictionary = {"need_ph": true} if kind == "ph" else {}
		for mode in Route.MODES:
			for ready in [true, false]:
				for phone_ok in [true, false]:
					for sw in ["phone", "pc"]:
						Route.mode = mode
						Route.pc_ready_hook = func() -> bool: return ready
						_avail(phone_ok)
						_set_sw(null if sw == "phone" else "pc") # the "phone" column is the DEFAULT (key unset)
						var got: String = Route.decide("POST", path, body)
						var want: String = _p0_expected(kind, mode, ready, phone_ok, sw)
						if sabotage and rows == 0:
							want = "phone" if want != "phone" else "none"
						rows += 1
						if got != want:
							bad.append("%s %s ready=%s phone_ok=%s score_where=%s: got %s want %s" % [kind, mode, ready, phone_ok, sw, got, want])
	Route.mode = "auto"
	Route.pc_ready_hook = func() -> bool: return true
	_avail(true)
	_set_sw(saved)
	return [rows, bad]


func _test_p0_decide_table() -> void:
	print("[P0-3 decide(): /stt, /score, /score+need_ph x mode x PC ready x phone ok x score_where]")
	var r: Array = _p0_run_table(false)
	for m in (r[1] as Array).slice(0, 10):
		print("    ", m)
	print("P0-3 rows: %d" % r[0])
	ok(r[0] == 72, "P0-3: 72 rows (got %d)" % r[0])
	ok((r[1] as Array).is_empty(), "P0-3: all 72 rows match the hand-written table (%d mismatches)" % (r[1] as Array).size())
	var s: Array = _p0_run_table(true)
	print("selfcheck FAIL-as-expected: one wrong expected cell -> %d mismatch (%s)" % [(s[1] as Array).size(), str((s[1] as Array)[0]) if not (s[1] as Array).is_empty() else "none"])
	ok((s[1] as Array).size() == 1, "P0-3 selfcheck: one deliberately wrong expected cell is reported as exactly 1 mismatch")
	# A few named cases, so the intent reads without the table.
	_is_phone = true
	Route.mode = "auto"
	Route.pc_ready_hook = func() -> bool: return true
	Api.base_url = DEAD_PC
	_avail(true)
	_set_sw(null)
	ok(Route.decide("POST", "/score", {}) == "phone", "auto, PC ready, phone ok, default -> /score on the phone")
	ok(Route.decide("POST", "/score", {"need_ph": true}) == "pc", "auto, PC ready, need_ph -> PC")
	_avail(false)
	ok(Route.decide("POST", "/score", {"need_ph": true}) == "pc" and Route.decide("POST", "/score", {}) == "pc", "auto, phone off -> PC (both)")
	Route.pc_ready_hook = func() -> bool: return false
	_avail(true)
	ok(Route.decide("POST", "/score", {"need_ph": true}) == "phone", "auto, PC not ready, need_ph -> phone score (phoneme_off is the handler's note)")
	_set_sw("pc")
	ok(Route.decide("POST", "/stt", {}) == "phone", "score_where=pc but the PC is not ready -> phone")
	_set_sw(null)
	Route.pc_ready_hook = func() -> bool: return true
	_is_phone = false
	ok(Route.decide("POST", "/score", {}) == "pc" and Route.decide("POST", "/stt", {}) == "pc", "PC app: /score and /stt stay pc (score_where is a phone matter)")
	_is_phone = true


func _test_p0_err_codes() -> void:  # coroutine (awaits requests)
	print("[P0-5 new error codes]")
	var hangul_ok := true
	var http_ok := true
	var distinct := true
	for ec in P0_NEW_CODES:
		var t: String = str(Route.ERR_TEXT.get(ec, ""))
		var has := false
		for ch in t:
			if ch.unicode_at(0) >= 0xAC00 and ch.unicode_at(0) <= 0xD7A3:
				has = true
				break
		hangul_ok = hangul_ok and has and Route.text_for(ec) == t
		var h: int = int(Route.ERR_HTTP.get(ec, 0))
		var h_good: bool = h in [400, 401, 403, 429] or (h >= 500 and h < 600)
		http_ok = http_ok and h_good and Route.http_for(ec) == h
		distinct = distinct and t != Route.ERR_TEXT["needs_pc"]
		if not has or not h_good:
			print("    bad code: ", ec, " text='", t, "' http=", h)
	ok(hangul_ok, "P0-5: all 9 new codes have a Korean ERR_TEXT")
	ok(http_ok, "P0-5: all 9 new codes have an ERR_HTTP in 400/401/403/429/5xx (never 0)")
	ok(distinct, "P0-5: no new text is the generic needs_pc text")
	ok(Route.ERR_TEXT.size() == 27 and Route.ERR_HTTP.size() == 27, "ERR_TEXT and ERR_HTTP each have 27 rows (18 old + 9 new): %d / %d" % [Route.ERR_TEXT.size(), Route.ERR_HTTP.size()])
	var same_keys := true
	for k in Route.ERR_TEXT.keys():
		same_keys = same_keys and Route.ERR_HTTP.has(k)
	ok(same_keys, "every ERR_TEXT code has an ERR_HTTP value")
	ok(Route.ERR_TEXT["no_ai"].begins_with("AI를 쓰려면 설정 > AI 연결에서 본인 AI 키를") and not Route.ERR_TEXT["no_ai"].contains("API 키"), "P0-5: no_ai now points at 설정 > AI 연결 (본인 AI 키)")
	ok(Route.ERR_TEXT["model_missing"] == P0_MODEL_MISSING, "P0-5: model_missing text unchanged")
	ok(Route.ERR_TEXT["engine_missing"] == P0_ENGINE_MISSING, "P0-5: engine_missing text unchanged")
	ok(Route.http_for("engine_error") == 500 and Route.http_for("stt_timeout") == 504 and Route.http_for("ai_url") == 400, "spot check: engine_error 500, stt_timeout 504, ai_url 400")
	# A fake phone handler that fails with each new code: the result carries the text/code, and no code is a 401, so
	# Api.auth_failed (a PC pairing problem) never fires. Phone mode: no retry, no PC.
	_is_phone = true
	Route.mode = "phone"
	_avail(true)
	var a0: int = _auth_failed
	var all_good := true
	for ec in P0_NEW_CODES:
		Engine.set_meta("a1_fail", ec)
		var r: Dictionary = await _req("POST", "/chat", {})
		var good: bool = not r["ok"] and r["err_code"] == ec and r["code"] == Route.http_for(ec) and r["error"] == Route.text_for(ec) and r["code"] != 0
		if not good:
			print("    code ", ec, " -> ", r.get("code"), " / ", r.get("err_code"))
		all_good = all_good and good
	Engine.set_meta("a1_fail", "")
	Route.mode = "auto"
	ok(all_good, "P0-5: a phone failure with each new code carries that code, its text and its HTTP value")
	ok(_auth_failed == a0, "P0-5: none of the new codes emits Api.auth_failed (%d -> %d)" % [a0, _auth_failed])


func _test_p0_degraded() -> void:
	print("[P0-6 DEGRADED]")
	ok("score_uncalibrated" in Route.DEGRADED and "stt_tiny_model" in Route.DEGRADED, "P0-6: DEGRADED has score_uncalibrated and stt_tiny_model")
	ok("phoneme_off" in Route.DEGRADED and Route.DEGRADED.size() == 9, "the 7 old values are still there (9 in all, got %d)" % Route.DEGRADED.size())
	var r: Dictionary = LocalApi.ok({"x": 1}, ["score_uncalibrated"])
	ok(r["ok"] and r["data"]["degraded"] == ["score_uncalibrated"] and r["data"]["via"] == "phone", "P0-6: LocalApi.ok(data, ['score_uncalibrated']) passes through")
	var r2: Dictionary = LocalApi.ok({"x": 1}, ["phoneme_off", "stt_tiny_model", "score_uncalibrated"])
	var all_known := true
	for d in r2["data"]["degraded"]:
		all_known = all_known and d in Route.DEGRADED
	ok(all_known and (r2["data"]["degraded"] as Array).size() == 3, "all three degraded values of a phone score result are known ones")
	ok(not ("bogus_flag" in Route.DEGRADED), "selfcheck FAIL-as-expected: an unknown degraded value is not in DEGRADED")
	print("selfcheck FAIL-as-expected: 'bogus_flag' in Route.DEGRADED -> ", "bogus_flag" in Route.DEGRADED)


func _retry_run(pc: FakePc, path: String, body: Dictionary, fail_code: String, report: bool = false) -> Dictionary:
	Engine.set_meta("a1_fail", fail_code)
	var n0: int = LocalApi.served_count
	var s0: int = Api.sent_count
	var p0: int = pc.log.size()
	var r: Dictionary = await _req("POST", path, body, report)
	Engine.set_meta("a1_fail", "")
	return {"res": r, "served": LocalApi.served_count - n0, "sent": Api.sent_count - s0, "pc": pc.log.size() - p0}


func _test_p0_retry() -> void:
	print("[P0-4 a failed phone speech engine -> exactly one PC retry]")
	var pc := FakePc.new()
	add_child(pc)
	var port: int = pc.start()
	ok(port > 1023, "in-process fake PC listens on a port the OS picked (%d)" % port)
	if port <= 0:
		pc.queue_free()
		return
	var pc_url: String = "http://127.0.0.1:%d" % port
	var saved_sw: Variant = Store.prefs.get("score_where", null)
	_set_sw(null)
	_is_phone = true
	Route.mode = "auto"
	Route.clear_flaky()
	Route.pc_ready_hook = func() -> bool: return true
	Api.base_url = pc_url
	_avail(true)
	var a0: int = Api.active_count
	var au0: int = _auth_failed
	var body := {"lang": "en", "target": "Nice to meet you.", "audio_b64": "AAAA"}
	print("  step 1: engine_error / stt_timeout -> PC retry")
	# 1) engine_error / stt_timeout on /score and /stt, PC fine -> the PC's answer, one phone run, one PC request
	for cs in [["/score", "engine_error"], ["/score", "stt_timeout"], ["/stt", "engine_error"], ["/stt", "stt_timeout"]]:
		pc.reply = "ok"
		var c: Dictionary = await _retry_run(pc, cs[0], body, cs[1])
		var r: Dictionary = c["res"]
		var tag: String = "%s %s" % [cs[0], cs[1]]
		ok(r["ok"] and r["data"] is Dictionary and int(r["data"].get("pc_marker", 0)) == 1 and not r["data"].has("via"), "P0-4: %s, PC ok -> final ok:true with the PC's answer" % tag)
		ok(c["served"] == 1 and c["pc"] == 1 and c["sent"] == 1, "P0-4: %s -> phone handler ran once, PC got exactly 1 request (served %d, pc %d, sent %d)" % [tag, c["served"], c["pc"], c["sent"]])
		ok(Api.active_count == a0, "active_count back to %d after the retry (%d)" % [a0, Api.active_count])
	ok(str(pc.log.back()["path"]) == "/stt" and str(pc.log.back()["raw"]).contains("Nice to meet you."), "the PC got the same path and body as the phone")
	print("  step 2: mode phone")
	# 2) mode phone -> never the PC
	Route.mode = "phone"
	var cp: Dictionary = await _retry_run(pc, "/score", body, "engine_error")
	ok(not cp["res"]["ok"] and cp["res"]["err_code"] == "engine_error" and cp["pc"] == 0 and cp["sent"] == 0 and cp["served"] == 1, "P0-4: mode phone -> no retry (PC requests 0), engine_error stays")
	Route.mode = "auto"
	print("  step 3: other paths")
	# 3) AI paths never move to the PC after a phone failure (phone mode: they run on the phone; PC requests stay 0)
	Route.mode = "phone"
	for p in ["/chat", "/fix", "/feedback", "/missions/judge"]:
		var ca: Dictionary = await _retry_run(pc, p, {"lang": "en"}, "engine_error")
		ok(not ca["res"]["ok"] and ca["res"]["err_code"] == "engine_error" and ca["pc"] == 0 and ca["sent"] == 0, "P0-4: %s phone failure is not handed to the PC (PC requests %d)" % [p, ca["pc"]])
	Route.mode = "auto"
	# ... and the decision itself: auto + PC ready + a phone-served non-speech path
	var cl: Dictionary = await _retry_run(pc, "/lesson", {"lang": "en"}, "engine_error")
	ok(cl["served"] == 1 and cl["pc"] == 0 and cl["res"]["err_code"] == "engine_error", "P0-4: /lesson (phone first) failing with engine_error is not retried on the PC")
	var cm: Dictionary = await _retry_run(pc, "/missions/check", {}, "stt_timeout")
	ok(cm["served"] == 1 and cm["pc"] == 0 and cm["res"]["err_code"] == "stt_timeout", "P0-4: /missions/check failing with stt_timeout is not retried on the PC")
	# The decision function, unit-level, for the four AI paths in the most favourable state (auto, PC ready).
	var fails := 0
	for p in ["/chat", "/fix", "/feedback", "/missions/judge", "/lesson", "/tts", "/prosody"]:
		var call_ai := Api.ApiCall.new()
		call_ai.path = p
		call_ai.method = HTTPClient.METHOD_POST
		call_ai.routable = true
		call_ai.base = pc_url
		if Api._phone_retry_wanted(call_ai, LocalApi.fail("engine_error")):
			fails += 1
	ok(fails == 0, "_phone_retry_wanted is false for /chat /fix /feedback /missions/judge /lesson /tts /prosody (%d wrongly true)" % fails)
	var call_sc := Api.ApiCall.new()
	call_sc.path = "/score?x=1"
	call_sc.method = HTTPClient.METHOD_POST
	call_sc.routable = true
	call_sc.base = pc_url
	ok(Api._phone_retry_wanted(call_sc, LocalApi.fail("engine_error")) and Api._phone_retry_wanted(call_sc, LocalApi.fail("stt_timeout")), "selfcheck: _phone_retry_wanted is true for /score with engine_error / stt_timeout")
	ok(not Api._phone_retry_wanted(call_sc, LocalApi.ok({"x": 1})) and not Api._phone_retry_wanted(call_sc, LocalApi.fail("model_missing")) and not Api._phone_retry_wanted(call_sc, LocalApi.fail("no_ai")), "selfcheck: false for an ok result and for other error codes")
	print("  step 4: other phone errors")
	# 4) other phone errors are not retried
	for code in ["model_missing", "model_corrupt", "pack_corrupt", "bad_format", "no_permission"]:
		var co: Dictionary = await _retry_run(pc, "/score", body, code)
		ok(co["pc"] == 0 and co["served"] == 1 and co["res"]["err_code"] == code, "P0-4: phone error %s is not retried (PC requests %d)" % [code, co["pc"]])
	print("  step 5: PC not ready / flaky")
	# 5) PC not ready / flaky -> no retry
	Route.pc_ready_hook = func() -> bool: return false
	var cn: Dictionary = await _retry_run(pc, "/score", body, "engine_error")
	ok(cn["pc"] == 0 and cn["sent"] == 0 and cn["res"]["err_code"] == "engine_error", "P0-4: PC not ready -> no retry")
	Route.pc_ready_hook = func() -> bool: return true
	Route.mark_pc_flaky()
	var cf: Dictionary = await _retry_run(pc, "/score", body, "engine_error")
	ok(cf["pc"] == 0 and cf["res"]["err_code"] == "engine_error", "P0-4: PC marked flaky -> no retry")
	Route.clear_flaky()
	print("  step 6: phone and PC both fail")
	# 6) phone fails AND the PC fails -> an error, no loop, the PC saw exactly one request
	pc.reply = "500"
	var cb: Dictionary = await _retry_run(pc, "/score", body, "engine_error", true)
	ok(not cb["res"]["ok"] and cb["res"]["err_code"] == "engine_error" and cb["res"]["error"] == Route.text_for("engine_error"), "P0-4: phone fail + PC 500 -> the phone's own error is returned")
	ok(cb["pc"] == 1 and cb["sent"] == 1 and cb["served"] == 1, "P0-4: phone fail + PC fail -> PC requests exactly 1, phone runs exactly 1 (pc %d, sent %d, served %d)" % [cb["pc"], cb["sent"], cb["served"]])
	ok(Api.active_count == a0 and not Route.pc_flaky(), "no request left in flight, PC not marked flaky by a refused retry")
	Api.base_url = DEAD_PC
	var cd: Dictionary = await _retry_run(pc, "/stt", body, "stt_timeout")
	ok(not cd["res"]["ok"] and cd["res"]["err_code"] == "stt_timeout" and cd["sent"] == 1 and cd["served"] == 1 and cd["pc"] == 0, "P0-4: phone fail + dead PC (transport) -> one send, one phone run, no phone loop (sent %d, served %d)" % [cd["sent"], cd["served"]])
	ok(Api.active_count == a0 and not Route.pc_flaky(), "dead PC: nothing in flight, no flaky mark")
	Api.base_url = pc_url
	print("  step 7: cancel during the retry")
	# 7) cancel while the PC retry is running
	pc.reply = "hang"
	Engine.set_meta("a1_fail", "engine_error")
	var p0: int = pc.log.size()
	var cc: Object = Api.post_json("/score", body, 5.0, false)
	await _wait_until(func() -> bool: return pc.log.size() > p0, 10.0)
	ok(pc.log.size() == p0 + 1 and not cc.done and Api.active_count == a0 + 2, "retry request is out on the PC and the call is still running (active %d)" % Api.active_count)
	cc.cancel()
	var ccr: Dictionary = await cc.wait()
	Engine.set_meta("a1_fail", "")
	ok(ccr["cancelled"] and not ccr["ok"] and Api.active_count == a0, "P0-4: cancel during the retry -> cancelled:true, active_count back to %d (%d)" % [a0, Api.active_count])
	for i in 6:
		await get_tree().process_frame
	ok(cc.result["cancelled"] and Api.active_count == a0, "the late PC result is dropped, active_count stays %d" % a0)
	await _wait_until(func() -> bool: return Api.orphan_count == 0, 15.0)
	ok(Api.orphan_count == 0, "the cancelled request ended by itself (orphan_count %d)" % Api.orphan_count)
	print("  step 8: auth_failed")
	# 8) phone failures never emit auth_failed
	ok(_auth_failed == au0, "P0-5: auth_failed never emitted by phone failures or retries")
	# restore
	pc.stop()
	pc.queue_free()
	Api.base_url = DEAD_PC
	Route.mode = "auto"
	Route.clear_flaky()
	Route.pc_ready_hook = func() -> bool: return true
	_set_sw(saved_sw)
	_avail(true)
	Engine.set_meta("a1_fail", "")


func _test_phone_curriculum() -> void:
	print("[phone app: a phone-side /curriculum answer is not cached as a PC answer]")
	_is_phone = true
	Route.mode = "auto"
	Route.clear_flaky()
	_avail(true)
	var cache := "user://test_a1_curriculum_cache2.json"
	var old_path: String = Store.curriculum_cache_path
	var old_cur: Dictionary = Store.curriculum.duplicate(true)
	var old_flag: bool = Store.curriculum_from_backend
	Store.curriculum_cache_path = cache
	Store.curriculum_from_backend = false
	if FileAccess.file_exists(cache):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cache))
	# no PC ready -> the bundled copy (phone handler)
	Route.pc_ready_hook = func() -> bool: return false
	Api.base_url = DEAD_PC
	ok(Route.decide("GET", "/curriculum") == "phone", "phone auto, PC not ready: GET /curriculum -> phone")
	var s0: int = Api.sent_count
	var n0: int = LocalApi.served_count
	await Store.refresh_curriculum()
	ok(LocalApi.served_count == n0 + 1 and Api.sent_count == s0, "refresh_curriculum was served by the phone, nothing sent")
	ok(not FileAccess.file_exists(cache), "no curriculum cache file was written for a phone answer")
	ok(not Store.curriculum_from_backend, "curriculum_from_backend stays false")
	ok(not Store.curriculum.has("via") and not Store.curriculum.has("degraded") and Store.curriculum == old_cur, "Store.curriculum has no via/degraded keys and is still valid / unchanged")
	ok(Store._valid_curriculum(Store.curriculum), "Store.curriculum is still a valid curriculum")
	# PC ready -> the PC's curriculum (prefer pc); a dead PC falls back to the phone copy
	Route.pc_ready_hook = func() -> bool: return true
	ok(Route.decide("GET", "/curriculum") == "pc", "phone auto, PC ready: GET /curriculum -> pc")
	var s1: int = Api.sent_count
	var r: Dictionary = await _req("GET", "/curriculum")
	ok(Api.sent_count > s1, "the request was sent to the PC")
	ok(r["ok"] and r["data"]["via"] == "phone" and Route.pc_flaky(), "PC dead -> same request answered by the phone copy, PC marked flaky")
	Route.clear_flaky()
	ok(not FileAccess.file_exists(cache), "still no cache file")
	Store.curriculum_cache_path = old_path
	Store.curriculum = old_cur
	Store.curriculum_from_backend = old_flag
	Route.mode = "auto"

