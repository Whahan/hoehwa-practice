extends Node
## LrclibClient 시험 (가짜 LRCLIB 서버 fake_lrclib.py, 포트 18797, 실제 lrclib.net 접속 없음).
##   godot --headless --path godot res://tests/lrclib_client_test.tscn [-- --lrclib=http://127.0.0.1:18797] [--python=<python.exe>]
## 인자가 없으면 시험이 직접 가짜 서버를 띄우고(자기 PID만 종료) 끝에 /_quit 으로 끈다.
## 가사는 모두 가짜 서버가 가진 직접 쓴 문장이다. 마지막 줄: "== lrclib_client_test result: N passed, M failed =="
## 일부러 틀린 입력(깨진 JSON, HTML, 연결 끊김, 429, 짧은 검색어, 실제 호스트)이 실제로 실패로 처리되는지 본다.

const PORT := 18797
const DEFAULT_PY := "D:/Ai/언어/app/backend/.venv/Scripts/python.exe"
const UA_PREFIX := "HoehwaPractice/1."
const REPO := "https://github.com/Whahan/hoehwa-practice"

var passed: int = 0
var failed: int = 0
var _reached_end: bool = false
var base: String = "http://127.0.0.1:%d" % PORT
var _server_pid: int = -1
var _own_server: bool = false
var c: LrclibClient = null


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func ua_ok(ua: String) -> bool:
	return ua.begins_with(UA_PREFIX) and ua.find("(" + REPO + ")") > 0


func gaps_ok(ts: Array, min_gap: float) -> bool:
	for i in range(1, ts.size()):
		if float(ts[i]) - float(ts[i - 1]) < min_gap - 0.001:
			return false
	return true


func _ready() -> void:
	print("== lrclib_client_test start ==")
	_validator_self_test()
	_test_pure()
	_test_source_rules()
	var up: bool = await _start_server()
	ok(up, "fake LRCLIB server is up on port %d" % PORT)
	if up:
		c = LrclibClient.new()
		add_child(c)
		c.base_url = base
		await _test_guard_and_short()
		await _test_headers()
		await _test_find_kinds()
		await _test_duration()
		await _test_rate_limit()
		await _test_errors()
		await _test_spacing()
		await _test_search()
		await _test_encoding()
		await _test_abandon()
		await _test_no_forbidden_calls()
		await _test_connection_refused()
	_reached_end = true
	ok(_reached_end, "all sections ran to the end (last section flag set)")
	if _own_server:
		await _ctl(HTTPClient.METHOD_POST, "/_quit") ## polite stop first; the launcher process may have a child
		await get_tree().create_timer(0.3).timeout
	_stop_server()
	print("== lrclib_client_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with(prefix):
			return String(a).substr(prefix.length())
	return ""


## Plain HTTP call to the fake server's control endpoints (not logged by the server). -> {code, text}
func _ctl(method: int, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	var err: int = req.request(base + path, PackedStringArray(), method)
	if err != OK:
		req.queue_free()
		return {"code": 0, "text": ""}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"code": 0, "text": ""}
	return {"code": int(res[1]), "text": (res[3] as PackedByteArray).get_string_from_utf8()}


func _reset() -> void:
	await _ctl(HTTPClient.METHOD_POST, "/_reset")


func _log() -> Dictionary:
	var r: Dictionary = await _ctl(HTTPClient.METHOD_GET, "/_log")
	var parsed: Variant = JSON.parse_string(String(r["text"]))
	return parsed if parsed is Dictionary else {"requests": [], "bad_calls": []}


func _reqs() -> Array:
	var l: Dictionary = await _log()
	return l["requests"]


func _times(reqs: Array) -> Array:
	var out: Array = []
	for r in reqs:
		out.append(float(r["t"]))
	return out


func _start_server() -> bool:
	var ext: String = _arg("--lrclib=")
	if ext != "":
		base = ext.rstrip("/")
		var p: Dictionary = await _ctl(HTTPClient.METHOD_GET, "/_ping")
		return int(p["code"]) == 200
	# port must be free before we start our own
	var busy: Dictionary = await _ctl(HTTPClient.METHOD_GET, "/_ping")
	if int(busy["code"]) != 0:
		print("  port %d is already in use, not starting" % PORT)
		return false
	var py: String = _arg("--python=")
	if py == "":
		py = DEFAULT_PY
	var script: String = ProjectSettings.globalize_path("res://tests/fixtures/song/fake_lrclib.py")
	_server_pid = OS.create_process(py, PackedStringArray(["-I", script, "--port", str(PORT)]))
	_own_server = _server_pid > 0
	if not _own_server:
		return false
	for i in 50:
		await get_tree().create_timer(0.2).timeout
		var p2: Dictionary = await _ctl(HTTPClient.METHOD_GET, "/_ping")
		if int(p2["code"]) == 200 and String(p2["text"]) == "ok":
			return true
	return false


func _stop_server() -> void:
	if _own_server and _server_pid > 0:
		OS.kill(_server_pid) ## only the process this test started
		_server_pid = -1


# ---------------------------------------------------------------- sections

func _validator_self_test() -> void:
	ok(ua_ok("HoehwaPractice/1.3.0 (" + REPO + ")"), "ua_ok accepts the right header")
	ok(not ua_ok("GodotEngine/4.6.3 (Windows)"), "ua_ok rejects the Godot default")
	ok(not ua_ok("HoehwaPractice/2.0.0 (" + REPO + ")"), "ua_ok rejects another major version")
	ok(not ua_ok("HoehwaPractice/1.3.0 (https://example.com)"), "ua_ok rejects a wrong link")
	ok(gaps_ok([0.0, 0.5, 1.0], 0.4), "gaps_ok accepts 0.5 s gaps")
	ok(not gaps_ok([0.0, 0.1, 1.0], 0.4), "gaps_ok rejects a 0.1 s gap")


func _test_pure() -> void:
	var ua: String = LrclibClient.user_agent()
	ok(ua_ok(ua), "user_agent() = HoehwaPractice/1.x (repo link): " + ua)
	var rel_path: String = ProjectSettings.globalize_path("res://").path_join("../packaging/release.json")
	if FileAccess.file_exists(rel_path):
		var rel: Variant = JSON.parse_string(FileAccess.get_file_as_string(rel_path))
		ok(rel is Dictionary and "https://github.com/" + String(rel.get("repo", "")) == LrclibClient.REPO_URL, "REPO_URL matches packaging/release.json repo")
	else:
		ok(LrclibClient.REPO_URL == REPO, "REPO_URL constant (release.json not found next to the project)")
	ok(LrclibClient.DEFAULT_BASE_URL == "https://lrclib.net", "default base url is the real service (only a constant)")
	ok(LrclibClient.MIN_INTERVAL_MS >= 400, "MIN_INTERVAL_MS >= 400")
	ok(is_equal_approx(LrclibClient.DEFAULT_TIMEOUT, 10.0), "default timeout is 10 s")
	ok(LrclibClient.parse_retry_after("2") == 2.0, "Retry-After '2' -> 2.0")
	ok(LrclibClient.parse_retry_after(" 7 ") == 7.0, "Retry-After ' 7 ' -> 7.0")
	ok(LrclibClient.parse_retry_after("") == -1.0 and LrclibClient.parse_retry_after("soon") == -1.0 and LrclibClient.parse_retry_after("-3") == -1.0, "Retry-After empty/text/negative -> -1 (unknown)")
	ok(LrclibClient.parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT") == -1.0, "Retry-After as a date -> -1 (unknown)")
	ok(LrclibClient.header_value(PackedStringArray(["Content-Type: x", "retry-after: 2"]), "Retry-After") == "2", "header_value is case-insensitive")
	# 200 / 404 / 429 / 500 / bad answers through the pure classifier (the Retry-After: 2 case the fake server cannot send)
	var rec := '{"id":5,"trackName":"T","artistName":"A","albumName":"X","duration":100,"instrumental":false,"plainLyrics":"p","syncedLyrics":"[00:01.00] s"}'
	var r: Dictionary = LrclibClient.classify_get(200, PackedStringArray(), rec, 101.0)
	ok(r["ok"] and r["kind"] == "exact" and r["has_synced"] and r["duration_match"] and absf(float(r["duration_diff"]) - 1.0) < 0.001, "classify 200 synced -> exact, diff 1.0, match")
	r = LrclibClient.classify_get(200, PackedStringArray(), rec, 110.0)
	ok(r["kind"] == "exact" and not r["duration_match"] and absf(float(r["duration_diff"]) - 10.0) < 0.001 and r["record"]["trackName"] == "T", "classify: 10 s off -> duration_diff 10, not dropped")
	r = LrclibClient.classify_get(200, PackedStringArray(), rec, 102.0)
	ok(r["duration_match"], "classify: exactly 2 s off still matches")
	r = LrclibClient.classify_get(200, PackedStringArray(), '{"id":6,"trackName":"T","artistName":"A","duration":50,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}', 0.0)
	ok(r["ok"] and r["kind"] == "instrumental" and r["record"]["syncedLyrics"] == "", "classify instrumental, null lyrics -> ''")
	r = LrclibClient.classify_get(200, PackedStringArray(), '{"id":7,"trackName":"T","artistName":"A","duration":50,"instrumental":false,"plainLyrics":"p","syncedLyrics":null}', 0.0)
	ok(r["kind"] == "exact" and not r["has_synced"] and r["has_plain"], "classify plain-only -> exact with has_synced false")
	r = LrclibClient.classify_get(404, PackedStringArray(), '{"code":404}', 0.0)
	ok(r["ok"] and r["kind"] == "none" and r["err_code"] == "", "classify 404 -> none")
	r = LrclibClient.classify_get(429, PackedStringArray(["Retry-After: 2"]), "", 0.0)
	ok(not r["ok"] and r["kind"] == "error" and r["err_code"] == "rate_limited" and r["retry_after"] == 2.0, "classify 429 + Retry-After 2 -> rate_limited, retry_after 2")
	r = LrclibClient.classify_get(500, PackedStringArray(), "x", 0.0)
	ok(not r["ok"] and r["kind"] == "error" and r["http_code"] == 500, "classify 500 -> error")
	r = LrclibClient.classify_get(200, PackedStringArray(), '{"id": 1001, "trackName": "Kettle Mor', 0.0)
	ok(r["kind"] == "error" and r["err_code"] == "bad_response", "classify truncated JSON -> bad_response")
	r = LrclibClient.classify_get(200, PackedStringArray(), "[1,2]", 0.0)
	ok(r["err_code"] == "bad_response", "classify a JSON array where a record is expected -> bad_response")
	r = LrclibClient.classify_get(200, PackedStringArray(), "{}", 0.0)
	ok(r["err_code"] == "bad_response", "classify {} (no track name) -> bad_response")
	r = LrclibClient.classify_get(0, PackedStringArray(), "", 0.0, false)
	ok(r["kind"] == "error" and r["err_code"] == "network", "classify no transport -> network")
	var s: Dictionary = LrclibClient.classify_search(200, PackedStringArray(), "{}", -1.0)
	ok(not s["ok"] and s["err_code"] == "bad_response", "classify_search: object instead of array -> bad_response")
	var many: Array = []
	for i in 30:
		many.append({"id": i, "trackName": "S%d" % i, "artistName": "A", "duration": 100 + i})
	s = LrclibClient.classify_search(200, PackedStringArray(), JSON.stringify(many), 129.0)
	ok(s["ok"] and s["items"].size() == 20 and s["items"][0]["trackName"] == "S29" and float(s["items"][0]["duration_diff"]) == 0.0, "classify_search: 30 results -> 20, nearest duration first")


func _test_source_rules() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/local/lrclib_client.gd").to_lower()
	ok(src.length() > 1000, "client source readable")
	ok(src.find("cancel_request") < 0, "source never calls cancel_request")
	ok(src.find("publish") < 0 and src.find("flag") < 0 and src.find("challenge") < 0, "source has no publish / flag / challenge")


func _test_guard_and_short() -> void:
	await _reset()
	# a client that still points at the real service must refuse to send during a test
	var real := LrclibClient.new()
	add_child(real)
	ok(real.base_url == "https://lrclib.net" and Store.test_guard_on, "fresh client points at the real service and the test guard is on")
	var r: Dictionary = await real.find("Kettle Morning", "Test Artist")
	ok(r["kind"] == "error" and r["err_code"] == "network" and real.sent_count == 0, "real lrclib.net base_url during a test: refused, nothing sent")
	var s: Dictionary = await real.search("Kettle")
	ok(not s["ok"] and real.sent_count == 0, "same for search")
	real.queue_free()
	ok(c.base_url.begins_with("http://127.0.0.1:%d" % PORT), "test client base_url is the fake server on 127.0.0.1:%d" % PORT)
	# short input sends nothing
	var s1: Dictionary = await c.search("a")
	ok(not s1["ok"] and s1["err_code"] == "too_short" and s1["items"].is_empty(), "search of 1 character -> too_short")
	var s2: Dictionary = await c.search("")
	var s3: Dictionary = await c.search(" a ", "", "")
	var f1: Dictionary = await c.find("a", "Test Artist")
	var f2: Dictionary = await c.find("Kettle Morning", "")
	ok(s2["err_code"] == "too_short" and s3["err_code"] == "too_short" and f1["err_code"] == "too_short" and f2["err_code"] == "too_short", "empty / 1-char search and find: too_short")
	var reqs: Array = await _reqs()
	ok(reqs.size() == 0 and c.sent_count == 0, "short input: 0 requests reached the server")


func _test_headers() -> void:
	await _reset()
	var r: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 21.0)
	ok(r["ok"] and r["kind"] == "exact", "find Kettle Morning -> exact")
	var reqs: Array = await _reqs()
	ok(reqs.size() == 1, "exactly 1 request for one find")
	if reqs.size() >= 1:
		var h: Dictionary = reqs[0]["headers"]
		var ua: String = String(h["user-agent"])
		print("  observed by server: User-Agent=", ua, " / Lrclib-Client=", String(h["lrclib-client"]), " / X-User-Agent=", String(h["x-user-agent"]))
		ok(ua_ok(ua), "server saw User-Agent from our client: " + ua)
		ok(ua_ok(String(h["lrclib-client"])), "server saw Lrclib-Client: " + String(h["lrclib-client"]))
		ok(not ua.contains("GodotEngine"), "[A-2] Godot HTTPRequest sends our User-Agent instead of its default (no GodotEngine)")
		ok(reqs[0]["path"] == "/api/get" and reqs[0]["query"]["track_name"] == "Kettle Morning" and reqs[0]["query"]["artist_name"] == "Test Artist" and reqs[0]["query"]["duration"] == "21", "request is GET /api/get with track_name, artist_name, duration=21")
		ok(not reqs[0]["query"].has("album_name"), "no album_name when none is given")


func _test_find_kinds() -> void:
	await _reset()
	var r: Dictionary = await c.find("Kettle Morning", "Test Artist", "Fixtures", 21.0)
	ok(r["ok"] and r["kind"] == "exact" and r["record"]["id"] == 1001 and r["has_synced"] and String(r["record"]["syncedLyrics"]).begins_with("["), "exact: record id 1001 with synced lyrics")
	ok(r["err_code"] == "" and float(r["retry_after"]) == 0.0 and r["record"]["duration"] == 21.0, "exact: err_code '' and duration filled")
	var r2: Dictionary = await c.find("Plain Boat", "Test Artist", "", 30.0)
	ok(r2["ok"] and r2["kind"] == "exact" and not r2["has_synced"] and r2["has_plain"], "plain-only song -> exact, has_synced false")
	var r3: Dictionary = await c.find("Quiet Room", "Test Artist", "", 45.0)
	ok(r3["ok"] and r3["kind"] == "instrumental", "instrumental:true -> instrumental")
	var r4: Dictionary = await c.find("No Such Song", "Nobody", "", 100.0)
	ok(r4["ok"] and r4["kind"] == "none" and r4["err_code"] == "", "404 -> none (ok true, no error)")
	var r5: Dictionary = await c.find("やかんの朝", "テスト歌手", "", 0.0)
	ok(r5["ok"] and r5["kind"] == "exact" and r5["record"]["trackName"] == "やかんの朝", "Japanese title/artist round trip")
	var r6: Dictionary = await c.find("__empty__ x", "Test Artist")
	ok(r6["ok"] and r6["kind"] == "none", "__empty__ -> none")


func _test_duration() -> void:
	await _reset()
	var r: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 21.0)
	ok(r["kind"] == "exact" and r["duration_match"] and float(r["duration_diff"]) <= 2.0, "duration within 2 s: match, diff <= 2")
	var r2: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 22.5)
	ok(r2["kind"] == "exact" and r2["duration_match"] and absf(float(r2["duration_diff"])) <= 2.0, "duration 22.5 s (sent as 23, 2 s off) still the same recording")
	var r3: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 0.0)
	var reqs: Array = await _reqs()
	ok(r3["kind"] == "exact" and float(r3["duration_diff"]) == -1.0 and not (reqs[reqs.size() - 1]["query"] as Dictionary).has("duration"), "no duration: parameter not sent, duration_diff -1")
	var r4: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 100.0)
	ok(r4["kind"] == "none", "duration far off: the service says none")
	var s: Dictionary = await c.search("Kettle Morning", "", "", 21.0)
	var items: Array = s["items"]
	var diffs_sorted := true
	var all_filled := true
	for i in items.size():
		if not (float(items[i]["duration_diff"]) >= 0.0):
			all_filled = false
		if i > 0 and float(items[i]["duration_diff"]) < float(items[i - 1]["duration_diff"]):
			diffs_sorted = false
	ok(s["ok"] and items.size() >= 4 and diffs_sorted and all_filled, "search with duration: every item has duration_diff, sorted nearest first (%d items)" % items.size())
	var far_kept := false
	var near_ok := false
	for it in items:
		if it["id"] == 1002:
			far_kept = (not it["duration_match"]) and absf(float(it["duration_diff"]) - 10.0) < 0.01
		if it["id"] == 1001:
			near_ok = it["duration_match"]
	ok(far_kept and near_ok, "search: a version 10 s longer is kept with duration_diff 10 / match false; the same length matches")


func _test_rate_limit() -> void:
	await _reset()
	var t0: int = Time.get_ticks_msec()
	var r: Dictionary = await c.find("__429__ x", "Test Artist")
	var took: float = (Time.get_ticks_msec() - t0) / 1000.0
	ok(not r["ok"] and r["kind"] == "error" and r["err_code"] == "rate_limited" and r["retry_after"] == 1.0, "429 + Retry-After 1 -> rate_limited, retry_after 1.0")
	var reqs: Array = await _reqs()
	ok(reqs.size() == 2, "429: exactly 1 automatic retry (2 requests, got %d)" % reqs.size())
	if reqs.size() == 2:
		var gap: float = float(reqs[1]["t"]) - float(reqs[0]["t"])
		ok(gap >= 1.0 and gap <= 2.5, "429: retry waited Retry-After (+ jitter <= 30%%): %.2f s" % gap)
	ok(took >= 1.0, "429: call took at least Retry-After")
	await _reset()
	var r2: Dictionary = await c.find("__429_once__ x", "Test Artist")
	reqs = await _reqs()
	ok(r2["ok"] and r2["kind"] == "exact" and reqs.size() == 2, "429 once, then fine: the retry succeeds (2 requests)")
	await _reset()
	c.default_retry_after = 0.5
	var r3: Dictionary = await c.find("__429_nohdr__ x", "Test Artist")
	reqs = await _reqs()
	ok(r3["err_code"] == "rate_limited" and r3["retry_after"] == 0.5 and reqs.size() == 2, "429 without Retry-After: default wait used, still only 1 retry")
	c.default_retry_after = LrclibClient.DEFAULT_RETRY_AFTER
	await _reset()
	var s: Dictionary = await c.search("__429__ x")
	reqs = await _reqs()
	ok(not s["ok"] and s["err_code"] == "rate_limited" and s["retry_after"] == 1.0 and reqs.size() == 2, "search 429: rate_limited, retry_after 1, 1 retry")
	var after: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 21.0)
	ok(after["kind"] == "exact", "after a rate limit the client works again")


func _test_errors() -> void:
	await _reset()
	var r: Dictionary = await c.find("__500__ x", "Test Artist")
	var reqs: Array = await _reqs()
	ok(not r["ok"] and r["kind"] == "error" and r["err_code"] == "network" and r["http_code"] == 500, "500 -> error (network), http_code 500")
	ok(reqs.size() == 1, "500: no automatic retry (1 request)")
	var b: Dictionary = await c.find("__badjson__ x", "Test Artist")
	ok(not b["ok"] and b["kind"] == "error" and b["err_code"] == "bad_response", "truncated JSON from the server -> bad_response")
	var h: Dictionary = await c.find("__html__ x", "Test Artist")
	ok(not h["ok"] and h["err_code"] == "bad_response", "HTML page (captive portal) with 200 -> bad_response")
	var d: Dictionary = await c.find("__drop__ x", "Test Artist")
	ok(not d["ok"] and d["kind"] == "error" and d["err_code"] == "network", "connection closed without an answer -> error (network)")
	c.timeout = 1.0
	var t0: int = Time.get_ticks_msec()
	var sl: Dictionary = await c.find("__slow__ x", "Test Artist")
	var took: float = (Time.get_ticks_msec() - t0) / 1000.0
	c.timeout = LrclibClient.DEFAULT_TIMEOUT
	ok(not sl["ok"] and sl["err_code"] == "network" and took < 1.7, "timeout 1 s: error (network) after %.2f s (incl. the 0.4 s turn gap)" % took)
	var sb: Dictionary = await c.search("__badjson__ x")
	var s5: Dictionary = await c.search("__500__ x")
	ok(not sb["ok"] and sb["err_code"] == "bad_response" and not s5["ok"] and s5["err_code"] == "network", "search: bad JSON -> bad_response, 500 -> network")
	var se: Dictionary = await c.search("__empty__ x")
	ok(se["ok"] and se["items"].is_empty(), "search __empty__ -> ok with no items")


func _test_spacing() -> void:
	await _reset()
	await c.find("Kettle Morning", "Test Artist", "", 21.0)
	await c.find("Plain Boat", "Test Artist", "", 30.0)
	await c.search("Kettle")
	var reqs: Array = await _reqs()
	ok(reqs.size() == 3 and gaps_ok(_times(reqs), 0.4), "3 sequential calls: gaps >= 400 ms (server clock) %s" % str(_times(reqs)))
	# calls started at the same moment are queued, not sent together
	await _reset()
	var got: Array = []
	c.found.connect(func(res: Dictionary) -> void: got.append(res))
	c.find("Kettle Morning", "Test Artist", "", 21.0)
	c.find("Plain Boat", "Test Artist", "", 30.0)
	c.find("Quiet Room", "Test Artist", "", 45.0)
	var guard: int = 0
	while got.size() < 3 and guard < 600:
		await get_tree().create_timer(0.05).timeout
		guard += 1
	reqs = await _reqs()
	ok(got.size() == 3 and reqs.size() == 3 and gaps_ok(_times(reqs), 0.4), "3 simultaneous calls are queued: gaps >= 400 ms %s" % str(_times(reqs)))
	ok(got.size() == 3 and got[0]["kind"] == "exact" and got[1]["kind"] == "exact" and got[2]["kind"] == "instrumental", "the `found` signal delivered all 3 results in order")


func _test_search() -> void:
	await _reset()
	var s: Dictionary = await c.search("Kettle Morning")
	ok(s["ok"] and s["items"].size() >= 4 and s["err_code"] == "", "search 'Kettle Morning' -> several items")
	var it: Dictionary = s["items"][0]
	ok(it["id"] is int and it["trackName"] is String and it["syncedLyrics"] is String and it["duration"] is float and it["instrumental"] is bool, "item fields have fixed types")
	ok(float(it["duration_diff"]) == -1.0, "no duration given: duration_diff is -1 and the server order is kept")
	var m: Dictionary = await c.search("many")
	ok(m["ok"] and m["items"].size() == 20, "25 results are cut to 20")
	var z: Dictionary = await c.search("zzzzqq nothing")
	ok(z["ok"] and z["items"].is_empty() and z["err_code"] == "", "no match -> ok, empty list")
	await _reset()
	var by_track: Dictionary = await c.search("", "Kettle Morning", "Test Artist")
	var reqs: Array = await _reqs()
	ok(by_track["ok"] and by_track["items"].size() >= 2 and reqs.size() == 1 and reqs[0]["path"] == "/api/search" and reqs[0]["query"].has("track_name") and not reqs[0]["query"].has("q"), "empty q: track/artist go as track_name/artist_name")
	var ja: Dictionary = await c.search("やかん")
	ok(ja["ok"] and ja["items"].size() == 1 and ja["items"][0]["id"] == 2001, "Japanese query finds the Japanese song")


func _test_encoding() -> void:
	await _reset()
	var r: Dictionary = await c.find("A&B=C?+d", "Zed #1 가나")
	var reqs: Array = await _reqs()
	ok(r["kind"] == "none" and reqs.size() == 1 and reqs[0]["query"]["track_name"] == "A&B=C?+d" and reqs[0]["query"]["artist_name"] == "Zed #1 가나", "special characters arrive intact (& = ? + # space, Korean)")


func _test_abandon() -> void:
	await _reset()
	var ab := LrclibClient.new()
	add_child(ab)
	ab.base_url = base
	var emitted: Array = []
	ab.found.connect(func(res: Dictionary) -> void: emitted.append(res))
	ab.find("__slow__ x", "Test Artist")
	await get_tree().create_timer(0.6).timeout
	ab.abandon()
	ok(is_instance_valid(ab) and not ab.is_queued_for_deletion(), "abandon() while a request is running: the node is not freed yet")
	await get_tree().create_timer(2.2).timeout
	ok(emitted.is_empty(), "abandoned call: the result is dropped (no `found`)")
	ok(not is_instance_valid(ab), "abandoned node freed itself after the request ended")
	var reqs: Array = await _reqs()
	ok(reqs.size() == 1, "abandon sent nothing extra (1 request)")


func _test_no_forbidden_calls() -> void:
	var l: Dictionary = await _log()
	ok((l["bad_calls"] as Array).is_empty(), "server saw no call outside /api/get, /api/get-cached, /api/get/{id}, /api/search (bad_calls empty)")
	await _reset()
	await c.find("Kettle Morning", "Test Artist", "", 21.0)
	await c.search("Kettle")
	var reqs: Array = await _reqs()
	var paths_ok := true
	var methods_ok := true
	for r in reqs:
		if not (r["path"] in ["/api/get", "/api/search"]):
			paths_ok = false
		if r["method"] != "GET":
			methods_ok = false
	ok(reqs.size() == 2 and paths_ok and methods_ok, "only GET /api/get and GET /api/search are used")


func _test_connection_refused() -> void:
	var q: Dictionary = await _ctl(HTTPClient.METHOD_POST, "/_quit")
	ok(int(q["code"]) == 200, "fake server accepted /_quit")
	await get_tree().create_timer(0.8).timeout
	var still: Dictionary = await _ctl(HTTPClient.METHOD_GET, "/_ping")
	if int(still["code"]) == 0:
		_own_server = false ## it ended by itself; do not kill a PID that may be reused
	var d: Dictionary = await c.find("Kettle Morning", "Test Artist", "", 21.0)
	ok(not d["ok"] and d["kind"] == "error" and d["err_code"] == "network", "connection refused (server gone) -> error (network)")
	var s: Dictionary = await c.search("Kettle")
	ok(not s["ok"] and s["err_code"] == "network", "search: connection refused -> network")
