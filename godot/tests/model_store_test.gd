extends Node
## ModelStore (docs/v201_design.md 2.2, 5.3 PA3-1..PA3-13): manifest, address rules, download / resume / hash / space /
## redirects / cancel / delete, against the local fake server `phone_src/tools/fake_model_server.py`.
##   powershell -File godot\tests\run_model_tests.ps1        (starts the server, runs this test and the card test)
## Direct run needs the server's port and folder: `... model_store_test.tscn -- --port=18791 --srv-root=<dir>`.
## Last line: "== model_store_test result: N passed, M failed ==", exit code 1 = failure.
## This test has no network client of its own: the fake server writes `requests.jsonl` into --srv-root and the test
## reads that file. Nothing but 127.0.0.1:<port> is ever contacted. Files go to user://test_models_pa3/ only.

const DIR := "user://test_models_pa3"
const HOSTS := ["github.com", "githubusercontent.com", "huggingface.co", "hf.co"]
const SIZE := 3000000
const SETTLE_MS := 400
const SETTLE_LIMIT_MS := 8000

var passed: int = 0
var failed: int = 0
var _port: int = 0
var _root: String = ""
var _tok: int = 0
var _fin: Array = []
var _prog: Array = []
var _states: Array = []
var _wf_frames: int = 0
var _wf_sec: float = 0.0
var _payloads: Dictionary = {}
var _old_prefs: String = ""
var _normal_tok: String = ""
var _cap: LogCap = null
var _settle_timeouts: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _args() -> void:
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s.begins_with("--port="):
			_port = int(s.substr(7))
		elif s.begins_with("--srv-root="):
			_root = s.substr(11)


func _ready() -> void:
	print("== model_store_test start ==")
	_cap = LogCap.new()
	OS.add_logger(_cap)
	_args()
	_old_prefs = Store.prefs_path
	DirAccess.make_dir_recursive_absolute(_g(DIR))
	Store.prefs_path = DIR.path_join("prefs.json")
	Store.prefs = {}
	ModelStore.base_dir = DIR + "/store/"
	var ev: Node = ModelStore.events()
	await _frames(2)
	ev.connect("finished", func(id: String, okv: bool, err: String) -> void: _fin.append([id, okv, err]))
	ev.connect("progress", func(id: String, d: int, t: int) -> void: _prog.append([id, d, t]))
	ev.connect("state_changed", func(id: String, s: String) -> void: _states.append([id, s]))
	ModelStore.allow_http_loopback = true ## the fake server is plain http on 127.0.0.1
	ok(Store.test_guard_on, "test guard is on")
	if _port <= 0 or _root == "" or not DirAccess.dir_exists_absolute(_root):
		ok(false, "fake server arguments given (--port, --srv-root)")
		_finish()
		return
	ok(true, "fake server arguments given (--port, --srv-root)")
	_payloads["p3m.bin"] = _make_payload("p3m.bin", SIZE)

	_selfchecks()
	_static_checks()
	_manifest_real()
	_helpers()
	await _prefs_and_picks()
	await _settle_selfcheck()
	await _d_normal()
	await _d_already_ready()
	await _d_frames()
	await _d_cancel_resume()
	await _d_pause()
	await _d_cut()
	await _d_norange()
	await _d_416()
	await _d_part_cases()
	await _d_hash()
	await _d_space()
	await _d_redirects()
	await _d_hosts()
	await _d_bad()
	await _d_manifest_bad()
	await _d_hardening()
	await _d_stall_and_close()
	await _d_remove()
	await _d_misc()
	ok(_settle_timeouts == 0, "every settled wait ended by itself, none by the time limit (%d)" % _settle_timeouts)
	_finish()


func _finish() -> void:
	if _cap != null:
		OS.remove_logger(_cap)
		ok(_cap.count() == 0, "no engine ERROR line during the run (%d)" % _cap.count())
		for l in _cap.snapshot().slice(0, 5):
			print("engine error: ", l)
	ModelStore.free_space_hook = Callable()
	ModelStore.write_error_hook = Callable()
	ModelStore.allow_http_loopback = false
	ModelStore.test_host_map = {}
	ModelStore.manifest_path = "res://data/models.json"
	ModelStore.base_dir = "user://models/"
	Store.prefs_path = _old_prefs
	_rm_rf(DIR)
	print("== model_store_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _rm_rf(path: String) -> void:
	var gp: String = _g(path)
	var d := DirAccess.open(gp)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(gp.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(gp)


# ---------------------------------------------------------------- helpers: payload, manifest, server log

func _make_payload(name: String, size: int) -> Dictionary:
	var crypto := Crypto.new()
	var data := PackedByteArray()
	while data.size() < size:
		data.append_array(crypto.generate_random_bytes(65536))
	data.resize(size)
	var path: String = _root.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	return {"name": name, "bytes": size, "sha": FileAccess.get_sha256(path)}


func _url(tok: String, payload: String, q: String = "") -> String:
	return "http://127.0.0.1:%d/f/%s/%s%s" % [_port, tok, payload, q]


func _new_tok() -> String:
	_tok += 1
	return "t%d" % _tok


## One default model with one url list; writes the manifest and points ModelStore at it. Returns {id, file, tok}.
func _single(tag: String, urls_q: Array, sha: String = "", bytes: int = SIZE, min_free_mb: int = 0, payload: String = "p3m.bin") -> Dictionary:
	var tok: String = _new_tok()
	var id := "m_" + tag
	var urls: Array = []
	for q in urls_q:
		urls.append(_url(tok, payload, String(q)))
	var model := {"id": id, "kind": "stt", "langs": ["en"], "file": id + ".bin", "bytes": bytes,
		"sha256": sha if sha != "" else str((_payloads["p3m.bin"] as Dictionary)["sha"]), "min_free_mb": min_free_mb, "default": true,
		"ram_hint_mb": 100, "label_ko": "시험 모델", "urls": urls, "license": "test"}
	_write_manifest([model])
	return {"id": id, "file": id + ".bin", "tok": tok}


func _write_manifest(models: Array, hosts: Array = HOSTS) -> void:
	var p: String = DIR + "/manifest.json"
	var f := FileAccess.open(_g(p), FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "hosts": hosts, "models": models}))
	f.close()
	ModelStore.manifest_path = p


func _abs(file: String, suffix: String = "") -> String:
	return _g(ModelStore.base_dir).path_join(file + suffix)


func _log(tok: String) -> Array:
	var out: Array = []
	var p: String = _root.path_join("requests.jsonl")
	if not FileAccess.file_exists(p):
		return out
	var f := FileAccess.open(p, FileAccess.READ)
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.strip_edges() == "":
			continue
		var j := JSON.new()
		if j.parse(line) == OK and j.data is Dictionary and str((j.data as Dictionary).get("token", "")) == tok:
			out.append(j.data)
	f.close()
	return out


func _log_wait(tok: String, n: int, sec: float = 5.0) -> Array:
	var t0: int = Time.get_ticks_msec()
	var l: Array = _log(tok)
	while l.size() < n and float(Time.get_ticks_msec() - t0) < sec * 1000.0:
		await get_tree().process_frame
		l = _log(tok)
	return l


## The fake server writes a request's log line when that connection ENDS (the runner may delay it on purpose), so a
## line can arrive well after the client has moved on. The server publishes <srv-root>/inflight.txt (atomic replace) =
## requests still being handled + log lines not yet written, and <srv-root>/inflight.err if publishing failed.
## An absence check ("no new request", "only the first one is logged") therefore waits until that number is 0 and
## the count for its token has not changed for SETTLE_MS, then returns the lines: no guessed number of frames.
## Anything else is NOT settled: no file, a file that cannot be read, not a plain number, a negative number, or
## inflight.err present. Such a wait ends only by the time limit, which counts in _settle_timeouts and fails the run.
func _inflight() -> int:
	if FileAccess.file_exists(_root.path_join("inflight.err")):
		return -1
	var p: String = _root.path_join("inflight.txt")
	if not FileAccess.file_exists(p):
		return -1
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return -1
	var t: String = f.get_as_text().strip_edges()
	f.close()
	if not t.is_valid_int():
		return -1
	return maxi(int(t), -1) # a negative number is a server bug: -1 keeps it "not settled"


func _settled_log(tok: String) -> Array:
	var last: Array = _log(tok)
	var t_change: int = Time.get_ticks_msec()
	var t0: int = t_change
	while true:
		await get_tree().process_frame
		var cur: Array = _log(tok)
		if cur.size() != last.size():
			t_change = Time.get_ticks_msec()
		last = cur
		if _inflight() != 0:
			t_change = Time.get_ticks_msec()
		if Time.get_ticks_msec() - t_change >= SETTLE_MS:
			break
		if Time.get_ticks_msec() - t0 > SETTLE_LIMIT_MS:
			_settle_timeouts += 1
			break
	return last


func _wait_fin(id: String, sec: float = 25.0) -> Dictionary:
	var t0: int = Time.get_ticks_msec()
	_wf_frames = 0
	while float(Time.get_ticks_msec() - t0) < sec * 1000.0:
		for e in _fin:
			if str(e[0]) == id:
				_wf_sec = float(Time.get_ticks_msec() - t0) / 1000.0
				return {"ok": bool(e[1]), "err": str(e[2]), "timeout": false}
		await get_tree().process_frame
		_wf_frames += 1
	_wf_sec = sec
	return {"ok": false, "err": "timeout", "timeout": true}


func _until(cond: Callable, sec: float = 10.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - t0) < sec * 1000.0:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _run(id: String, confirmed: bool = false) -> Dictionary:
	_fin.clear()
	var r: Dictionary = ModelStore.start(id, confirmed)
	if not bool(r.get("ok", false)):
		return {"start": r, "ok": false, "err": str(r.get("err_code", "")), "timeout": false}
	var w: Dictionary = await _wait_fin(id)
	w["start"] = r
	return w


func _read_text(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func _has5(s: String) -> bool:
	return RegEx.create_from_string("\\d{5,}").search(s) != null


func _leaks(s: String) -> bool:
	for m in ["ZZ_MARK_" + "9731", "ZZ_TGT_" + "4417", "ZZSIG"]:
		if s.contains(m):
			return true
	return false


func _hex64(s: String) -> bool:
	return RegEx.create_from_string("^[0-9a-f]{64}\\z").search(s) != null


# ---------------------------------------------------------------- self checks (the checkers can fail)

func _selfchecks() -> void:
	ok(_has5("12345 MB"), "selfcheck: the digit scanner sees 5 digits")
	print("selfcheck FAIL-as-expected digits (12345 is flagged)")
	ok(not _has5("35 / 60 MB"), "selfcheck: the digit scanner passes a progress text")
	var marker: String = "ZZ_MARK_" + "9731"
	ok(_leaks("x " + marker + " y"), "selfcheck: the leak scanner sees a marker in memory")
	print("selfcheck FAIL-as-expected leak (marker text is flagged)")
	ok(not _hex64("4BAF" + "0".repeat(60)), "selfcheck: the sha shape check rejects upper case")
	print("selfcheck FAIL-as-expected sha_shape (upper case is flagged)")
	var good := {"v": 1, "hosts": HOSTS, "models": [{"id": "a", "file": "a.bin", "bytes": 5, "sha256": "0".repeat(64), "urls": ["https://github.com/x"], "default": true}]}
	ok(bool(ModelStore.validate_manifest(good)["ok"]), "selfcheck: a good manifest is accepted")
	var broken: Array = []
	var m1: Dictionary = good.duplicate(true)
	(m1["models"][0] as Dictionary)["sha256"] = "G".repeat(64)
	broken.append(["sha256 not hex", m1])
	var m2: Dictionary = good.duplicate(true)
	(m2["models"][0] as Dictionary)["file"] = "../x.bin"
	broken.append(["file with ..", m2])
	var m3: Dictionary = good.duplicate(true)
	(m3["models"][0] as Dictionary)["default"] = false
	broken.append(["no default", m3])
	var m4: Dictionary = good.duplicate(true)
	(m4["models"][0] as Dictionary)["bytes"] = 0
	broken.append(["zero bytes", m4])
	var m5: Dictionary = good.duplicate(true)
	m5["models"].append((m5["models"][0] as Dictionary).duplicate(true))
	broken.append(["duplicate id", m5])
	var m6: Dictionary = good.duplicate(true)
	(m6["models"][0] as Dictionary)["urls"] = []
	broken.append(["no urls", m6])
	broken.append(["not a dictionary", [1, 2]])
	for b in broken:
		var r: Dictionary = ModelStore.validate_manifest(b[1])
		ok(not bool(r["ok"]) and str(r["err"]) == "bad_manifest", "validate_manifest rejects: " + str(b[0]))
		print("selfcheck FAIL-as-expected manifest (%s)" % str(b[0]))


func _static_checks() -> void:
	var src: String = _read_text("res://scripts/local/model_store.gd")
	ok(src != "", "model_store.gd source readable")
	var rx := RegEx.create_from_string("(print|push_warning|push_error|printerr)\\(")
	ok(rx.search(src) == null, "model_store.gd has no print / push_* line")
	ok(not src.contains("HTTPRe" + "quest"), "model_store.gd uses the polling client, not the request node")
	var card: String = _read_text("res://scripts/ui/stt_model_card.gd")
	ok(card != "" and not card.contains("%d/%d") and not card.contains("%d / %d"), "card has no progress text of its own")


# ---------------------------------------------------------------- pure functions

func _manifest_real() -> void:
	var saved: String = ModelStore.manifest_path
	ModelStore.manifest_path = "res://data/models.json"
	var mf: Dictionary = ModelStore.manifest()
	ok(bool(mf["ok"]) and (mf["models"] as Array).size() == 2, "real models.json is valid and has 2 models")
	var defaults := 0
	var all_https := true
	var all_hosts := true
	var ids := {}
	for m in mf["models"]:
		var md: Dictionary = m
		ids[str(md["id"])] = md
		if bool(md["default"]):
			defaults += 1
		for u in md["urls"]:
			var pu: Dictionary = ModelStore.parse_url(str(u))
			if str(pu.get("scheme", "")) != "https":
				all_https = false
			if not ModelStore.host_allowed(str(pu.get("host", "")), mf["hosts"]):
				all_hosts = false
		ok(_hex64(str(md["sha256"])) and int(md["bytes"]) > 0, "real manifest %s: sha256 shape and bytes > 0" % str(md["id"]))
	ok(defaults == 1, "real manifest: exactly one default model")
	ok(all_https, "real manifest: every url is https")
	ok(all_hosts, "real manifest: every url host is in hosts (suffix rule)")
	var base: Dictionary = ids.get("whisper-base.en-q5_1", {})
	var tiny: Dictionary = ids.get("whisper-tiny.en-q5_1", {})
	ok(int(base.get("bytes", 0)) == 59721011 and str(base.get("sha256", "")) == "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f", "real manifest: base model bytes and sha256")
	ok(int(tiny.get("bytes", 0)) == 32166155 and str(tiny.get("sha256", "")) == "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b", "real manifest: tiny model bytes and sha256")
	ok(ModelStore.default_id() == "whisper-base.en-q5_1", "default_id is the base model")
	ModelStore.manifest_path = saved


func _helpers() -> void:
	var h: Array = HOSTS
	ok(ModelStore.host_allowed("github.com", h), "host github.com allowed")
	ok(ModelStore.host_allowed("release-assets.githubusercontent.com", h), "host release-assets.githubusercontent.com allowed (suffix)")
	ok(ModelStore.host_allowed("CAS-BRIDGE.XETHUB.HF.CO", h), "host cas-bridge.xethub.hf.co allowed (suffix, case)")
	ok(not ModelStore.host_allowed("evilgithub.com", h), "host evilgithub.com refused")
	ok(not ModelStore.host_allowed("github.com.evil.example", h), "host github.com.evil.example refused")
	ok(not ModelStore.host_allowed("xhf.co", h), "host xhf.co refused")
	ok(not ModelStore.host_allowed("", h), "empty host refused")
	var p: Dictionary = ModelStore.parse_url("https://Release-Assets.GitHubUserContent.com:8443/a/b?x=1#frag")
	ok(bool(p["ok"]) and p["host"] == "release-assets.githubusercontent.com" and int(p["port"]) == 8443 and p["path"] == "/a/b?x=1", "parse_url: host lower-case, port, path and query, no fragment")
	ok(int(ModelStore.parse_url("https://github.com")["port"]) == 443 and ModelStore.parse_url("https://github.com")["path"] == "/", "parse_url: default port and path")
	for bad in ["ftp://github.com/x", "https://user@github.com/x", "https:///x", "github.com/x", "https://gi thub.com/x", "https://github.com:99999/x", ""]:
		ok(not bool(ModelStore.parse_url(bad)["ok"]), "parse_url refuses: " + bad)
	var base: Dictionary = ModelStore.parse_url("https://github.com/a/b/file.bin?x=1")
	ok(ModelStore.resolve_location(base, "/x/file") == "https://github.com/x/file", "resolve_location: absolute path")
	ok(ModelStore.resolve_location(base, "other.bin") == "https://github.com/a/b/other.bin", "resolve_location: relative file")
	ok(ModelStore.resolve_location(base, "//cdn.hf.co/z") == "https://cdn.hf.co/z", "resolve_location: scheme-relative")
	ok(ModelStore.resolve_location(base, "https://hf.co/q") == "https://hf.co/q", "resolve_location: absolute url")
	ok(ModelStore.resolve_location(base, "?y=2") == "https://github.com/a/b/file.bin?y=2", "resolve_location: query only")
	ok(ModelStore.progress_label(35000000, 59721011) == "35 / 60 MB", "progress_label 35 / 60 MB")
	ok(ModelStore.progress_label(0, 59721011) == "0 / 60 MB", "progress_label start")
	ok(ModelStore.progress_label(59721011, 59721011) == "60 / 60 MB", "progress_label end")
	ok(ModelStore.progress_label(-5, 0) == "0 / 1 MB", "progress_label negative / zero")
	ok(ModelStore.progress_label(900000000000, 3000000) == "3 / 3 MB", "progress_label done above total is clamped")
	ok(ModelStore.mb_label(59721011) == "약 60 MB" and ModelStore.mb_label(0) == "약 1 MB", "mb_label")
	var texts: Array = [ModelStore.progress_label(3000000000, 3000000000), ModelStore.mb_label(3000000000)]
	for k in ModelStore.ERR_TEXT.keys():
		texts.append(str(ModelStore.ERR_TEXT[k]))
	texts.append(ModelStore.space_unknown_text(250))
	var scan_ok := true
	for t in texts:
		if _has5(str(t)):
			scan_ok = false
	ok(scan_ok, "no text of ModelStore shows 5 or more digits in a row")
	var hangul := RegEx.create_from_string("[가-힣]")
	var all_ko := true
	for c in ["dl_net", "dl_http", "dl_redirect", "dl_host", "no_space", "model_corrupt", "io", "bad_manifest"]:
		if not ModelStore.ERR_TEXT.has(c) or hangul.search(str(ModelStore.ERR_TEXT.get(c, ""))) == null:
			all_ko = false
	ok(all_ko, "ERR_TEXT has a Korean sentence for all 8 codes")
	ok(ModelStore.SPACE_MARGIN_MB == 100 and ModelStore.MAX_REDIRECTS == 5 and ModelStore.MB == 1000000, "constants 100 / 5 / 10^6")


# ---------------------------------------------------------------- prefs and the model choice

func _prefs_and_picks() -> void:
	var mk := func(id: String, d: bool) -> Dictionary:
		return {"id": id, "kind": "stt", "langs": ["en"], "file": id + ".bin", "bytes": 100, "sha256": "a".repeat(64), "min_free_mb": 0,
			"default": d, "ram_hint_mb": 1, "label_ko": id, "urls": ["https://github.com/x/" + id], "license": "t"}
	_write_manifest([mk.call("ma", true), mk.call("mb", false)])
	Store.prefs = {}
	ok(ModelStore.active_id() == "ma" and ModelStore.default_id() == "ma", "active_id falls back to the default model")
	ok(not ModelStore.set_active("nope"), "set_active refuses an unknown id")
	ok(ModelStore.set_active("mb") and ModelStore.active_id() == "mb", "set_active picks another model")
	ok(str(Store.prefs.get("stt_model", "")) == "mb", "pref stt_model holds the choice")
	Store.prefs["stt_model"] = "gone"
	ok(ModelStore.active_id() == "ma", "an unknown pref value falls back to the default")
	Store.prefs["stt_model"] = 5
	ok(ModelStore.active_id() == "ma", "a non-text pref value falls back to the default")
	var common := 0
	for k in SyncDoc.SHARED_PREFS.keys():
		if k == "stt_model":
			common += 1
	ok(common == 0, "stt_model is not a synced setting (SyncDoc.SHARED_PREFS)")
	ok(ModelStore.path_of("ma") == ModelStore.base_dir.path_join("ma.bin") and ModelStore.path_of("zz") == "", "path_of")
	ok(ModelStore.state("zz") == "missing" and ModelStore.info("zz").is_empty() and ModelStore.model("zz").is_empty(), "unknown id: missing / {} / {}")
	Store.prefs = {}


# ---------------------------------------------------------------- settled log selfcheck

## One download, then the OLD way (a few frames, then count) against the NEW way (settled). With a delayed log line
## (MODEL_SRV_LOGDELAY_STORE) the old way sees 0 and the new way must still see exactly 1.
func _settle_selfcheck() -> void:
	var c: Dictionary = _single("settlesc", [""])
	var r: Dictionary = await _run(c["id"])
	ok(bool(r["start"]["ok"]) and bool(r["ok"]), "selfcheck: the settle probe download finished")
	await _frames(5)
	var n_old: int = _log(c["tok"]).size()
	var n_new: int = (await _settled_log(c["tok"])).size()
	ok(n_new == 1, "selfcheck: the settled wait sees the probe request's log line (old way saw %d, settled saw %d)" % [n_old, n_new])
	if n_old == 0:
		print("selfcheck FAIL-as-expected late_line (a few frames missed a log line that the settled wait found)")
	ModelStore.remove(c["id"])


# ---------------------------------------------------------------- downloads

func _d_normal() -> void:
	var c: Dictionary = _single("normal", [""])
	var id: String = c["id"]
	_normal_tok = c["tok"]
	ok(ModelStore.state(id) == "missing", "normal: starts as missing")
	_prog.clear()
	_states.clear()
	var r: Dictionary = await _run(id)
	ok(bool(r["start"]["ok"]), "normal: start ok")
	ok(bool(r["ok"]) and not bool(r["timeout"]), "normal: finished ok")
	ok(ModelStore.state(id) == "ready", "normal: state ready")
	ok(FileAccess.get_sha256(_abs(c["file"])) == (_payloads["p3m.bin"] as Dictionary)["sha"], "normal: final file sha256 matches")
	ok(not FileAccess.file_exists(_abs(c["file"], ".part")) and not FileAccess.file_exists(_abs(c["file"], ".part.json")), "normal: no .part / .part.json left")
	ok(FileAccess.file_exists(_abs(c["file"], ".ok")), "normal: .ok marker written")
	var l: Array = await _log_wait(c["tok"], 1)
	ok(l.size() == 1 and str((l[0] as Dictionary)["range"]) == "", "normal: one request, no Range header")
	var mine: Array = _states.filter(func(e: Array) -> bool: return e[0] == id)
	var names: Array = mine.map(func(e: Array) -> String: return e[1])
	ok(names.has("downloading") and names.has("verifying") and names.back() == "ready" and names.find("downloading") < names.find("verifying"), "normal: state_changed order downloading, verifying, ready")
	var pm: Array = _prog.filter(func(e: Array) -> bool: return e[0] == id)
	ok(pm.size() >= 1 and int((pm.back() as Array)[1]) == SIZE and int((pm.back() as Array)[2]) == SIZE, "normal: last progress is done == total")
	var inf: Dictionary = ModelStore.info(id)
	ok(int(inf["bytes"]) == SIZE and str(inf["state"]) == "ready" and str(inf["file"]) == c["file"] and str(inf["label_ko"]) == "시험 모델", "normal: info()")
	ok(ModelStore.path_of(id) == ModelStore.base_dir.path_join(c["file"]), "normal: path_of")
	var st: Dictionary = ModelStore.stats()
	ok(int(st["requests"]) >= 1 and str(st["last_host"]) == "127.0.0.1", "normal: stats has request count and host name")
	var sj: String = JSON.stringify(st)
	ok(not sj.contains("http") and not sj.contains("/f/") and not sj.contains("?") and not _leaks(sj), "normal: stats carries no address, path or query")


func _d_already_ready() -> void:
	var id := "m_normal"
	var c: Dictionary = {"tok": _normal_tok}
	var before: int = (await _settled_log(c["tok"])).size() # the first download's line must be in before the baseline
	var r: Dictionary = await _run(id)
	ok(bool(r["start"]["ok"]) and bool(r["ok"]), "ready: start again is a quiet success")
	var after_ready: Array = await _settled_log(c["tok"])
	print("absence: settled ready")
	ok(after_ready.size() == before, "ready: no new request")
	ok(ModelStore.state(id) == "ready", "ready: still ready")


func _d_frames() -> void:
	var c: Dictionary = _single("frames", ["?slow=30"])
	var id: String = c["id"]
	var r: Dictionary = await _run(id)
	ok(bool(r["ok"]), "frames: slow download finished ok")
	var fps: float = float(_wf_frames) / maxf(_wf_sec, 0.001)
	print("frames: %d in %.2f s = %.0f per second" % [_wf_frames, _wf_sec, fps])
	ok(_wf_sec >= 0.8, "frames: the download took long enough to measure (>= 0.8 s)")
	ok(fps >= 50.0, "frames: main thread runs >= 50 frames per second during a download")


func _d_cancel_resume() -> void:
	var c: Dictionary = _single("cancel", ["?slow=50"])
	var id: String = c["id"]
	_fin.clear()
	var r: Dictionary = ModelStore.start(id)
	ok(bool(r["ok"]) and ModelStore.state(id) == "downloading", "cancel: started, state downloading")
	var reached: bool = await _until(func() -> bool: return int(ModelStore.info(id)["part_bytes"]) >= 300000)
	ok(reached, "cancel: >= 300 KB arrived")
	var t0: int = Time.get_ticks_msec()
	ModelStore.cancel(id)
	var w: Dictionary = await _wait_fin(id, 5.0)
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	print("cancel: reacted in %.2f s" % took)
	ok(took < 2.0 and not bool(w["timeout"]), "cancel: reacts within 2 s")
	ok(not bool(w["ok"]) and str(w["err"]) == "cancelled", "cancel: finished(false, cancelled)")
	ok(ModelStore.state(id) == "partial", "cancel: state partial")
	var psize: int = FileAccess.open(_abs(c["file"], ".part"), FileAccess.READ).get_length() if FileAccess.file_exists(_abs(c["file"], ".part")) else -1
	ok(psize >= 300000 and psize < SIZE, "cancel: the .part stays")
	var pj: String = _read_text(_abs(c["file"], ".part.json"))
	ok(pj != "" and not pj.contains("?") and not pj.contains("http") and not _leaks(pj), "cancel: .part.json has no address or query")
	ok(int(ModelStore.info(id)["part_bytes"]) == psize, "cancel: info part_bytes == .part size")
	# resume
	var r2: Dictionary = await _run(id)
	ok(bool(r2["ok"]), "resume: finished ok")
	var l: Array = await _log_wait(c["tok"], 2)
	var second: Dictionary = l[1] if l.size() >= 2 else {}
	ok(str(second.get("range", "")) == "bytes=%d-" % psize, "resume: the second request says Range: bytes=N- with N == .part size")
	ok(int(second.get("sent", 1 << 30)) <= SIZE - psize + 1024, "resume: the server sent <= the missing part + 1 KB")
	ok(int(second.get("status", 0)) == 206, "resume: answered 206")
	ok(FileAccess.get_sha256(_abs(c["file"])) == (_payloads["p3m.bin"] as Dictionary)["sha"], "resume: final sha256 matches")
	ok(int(ModelStore.stats()["resumed"]) >= 1 and int(ModelStore.stats()["resume_bytes"]) == psize, "resume: stats count the resumed bytes")


func _d_pause() -> void:
	var c: Dictionary = _single("pause", ["?slow=50"])
	var id: String = c["id"]
	_fin.clear()
	ModelStore.start(id)
	await _until(func() -> bool: return int(ModelStore.info(id)["part_bytes"]) >= 200000)
	var t0: int = Time.get_ticks_msec()
	ModelStore.events().notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var w: Dictionary = await _wait_fin(id, 5.0)
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(took < 2.0 and str(w["err"]) == "cancelled", "pause: app paused stops the download within 2 s")
	ok(ModelStore.state(id) == "partial" and FileAccess.file_exists(_abs(c["file"], ".part")), "pause: .part kept, state partial")
	ModelStore.remove(id)


func _d_cut() -> void:
	var c: Dictionary = _single("cut", ["?cut=40"])
	var id: String = c["id"]
	var r: Dictionary = await _run(id)
	ok(not bool(r["ok"]) and str(r["err"]) == "dl_net", "cut: connection dropped at 40 percent gives dl_net")
	ok(ModelStore.state(id) == "partial", "cut: state partial")
	var psize: int = FileAccess.open(_abs(c["file"], ".part"), FileAccess.READ).get_length() if FileAccess.file_exists(_abs(c["file"], ".part")) else -1
	ok(psize > SIZE * 25 / 100 and psize < SIZE * 55 / 100, "cut: about 40 percent are on disk")
	var r2: Dictionary = await _run(id)
	ok(bool(r2["ok"]), "cut: resume finishes ok")
	var l: Array = await _log_wait(c["tok"], 2)
	var second: Dictionary = l[1] if l.size() >= 2 else {}
	ok(str(second.get("range", "")) == "bytes=%d-" % psize, "cut: resume sends Range: bytes=N-")
	ok(int(second.get("sent", 1 << 30)) <= SIZE - psize + 1024, "cut: the second request carries <= the missing part + 1 KB")
	ok(FileAccess.get_sha256(_abs(c["file"])) == (_payloads["p3m.bin"] as Dictionary)["sha"], "cut: final sha256 matches")


func _d_norange() -> void:
	var c: Dictionary = _single("norange", ["?cut=40&norange=1"])
	var id: String = c["id"]
	var r: Dictionary = await _run(id)
	ok(str(r["err"]) == "dl_net" and ModelStore.state(id) == "partial", "norange: first try cut, partial")
	var resumed_before: int = int(ModelStore.stats()["resumed"])
	var r2: Dictionary = await _run(id)
	ok(bool(r2["ok"]), "norange: server ignored Range (200), the download still succeeds")
	var l: Array = await _log_wait(c["tok"], 2)
	var second: Dictionary = l[1] if l.size() >= 2 else {}
	ok(str(second.get("range", "")) != "" and int(second.get("status", 0)) == 200 and int(second.get("sent", 0)) == SIZE, "norange: Range was sent, the whole file came back with 200")
	ok(int(ModelStore.stats()["resumed"]) == resumed_before, "norange: not counted as a resumed download")
	ok(FileAccess.get_sha256(_abs(c["file"])) == (_payloads["p3m.bin"] as Dictionary)["sha"], "norange: final sha256 matches (no stale bytes kept)")


func _put_part(file: String, size: int, with_json: bool = true) -> void:
	DirAccess.make_dir_recursive_absolute(_g(ModelStore.base_dir))
	var f := FileAccess.open(_abs(file, ".part"), FileAccess.WRITE)
	f.store_buffer(Crypto.new().generate_random_bytes(size))
	f.close()
	if with_json:
		var j := FileAccess.open(_abs(file, ".part.json"), FileAccess.WRITE)
		j.store_string(JSON.stringify({"v": 1, "id": "x", "bytes_done": size, "url_index": 0}))
		j.close()


func _d_416() -> void:
	var c: Dictionary = _single("r416", ["?r416=1"])
	var id: String = c["id"]
	_put_part(c["file"], 1000000)
	ok(ModelStore.state(id) == "partial", "416: a leftover .part shows as partial")
	var r: Dictionary = await _run(id)
	ok(bool(r["ok"]), "416: finished ok")
	var l: Array = await _log_wait(c["tok"], 2)
	ok(l.size() == 2 and int((l[0] as Dictionary)["status"]) == 416 and str((l[0] as Dictionary)["range"]) == "bytes=1000000-", "416: first request had Range and got 416")
	ok(l.size() == 2 and str((l[1] as Dictionary)["range"]) == "" and int((l[1] as Dictionary)["status"]) == 200, "416: second request starts from the first byte")
	ok(FileAccess.get_sha256(_abs(c["file"])) == (_payloads["p3m.bin"] as Dictionary)["sha"], "416: final sha256 matches (the old bytes were dropped)")


func _d_part_cases() -> void:
	# a .part larger than the model is dropped without a Range request
	var c: Dictionary = _single("bigpart", [""])
	_put_part(c["file"], SIZE + 1000000)
	var r: Dictionary = await _run(c["id"])
	var l: Array = await _log_wait(c["tok"], 1)
	ok(bool(r["ok"]) and l.size() == 1 and str((l[0] as Dictionary)["range"]) == "", "bigpart: a too big .part is dropped, the file comes from byte 0")
	# a complete and correct .part needs no request at all
	var c2: Dictionary = _single("fullpart", [""])
	var src := FileAccess.open(_root.path_join("p3m.bin"), FileAccess.READ)
	var data: PackedByteArray = src.get_buffer(SIZE)
	src.close()
	DirAccess.make_dir_recursive_absolute(_g(ModelStore.base_dir))
	var f := FileAccess.open(_abs(c2["file"], ".part"), FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	var r2: Dictionary = await _run(c2["id"])
	var l2: Array = await _settled_log(c2["tok"])
	print("absence: settled fullpart")
	ok(bool(r2["ok"]) and l2.size() == 0 and ModelStore.state(c2["id"]) == "ready", "fullpart: a complete .part is only verified (0 requests), then ready")
	# a complete .part with wrong content is corrupt
	var c3: Dictionary = _single("badpart", [""])
	_put_part(c3["file"], SIZE)
	var r3: Dictionary = await _run(c3["id"])
	var l3: Array = await _settled_log(c3["tok"])
	print("absence: settled badpart")
	ok(not bool(r3["ok"]) and str(r3["err"]) == "model_corrupt" and l3.size() == 0, "badpart: a complete but wrong .part -> model_corrupt, 0 requests")
	ok(ModelStore.state(c3["id"]) == "corrupt" and not FileAccess.file_exists(_abs(c3["file"], ".part")), "badpart: state corrupt, .part removed")


func _d_hash() -> void:
	var c: Dictionary = _single("hash", [""], "b".repeat(64))
	var id: String = c["id"]
	var r: Dictionary = await _run(id)
	ok(not bool(r["ok"]) and str(r["err"]) == "model_corrupt", "hash: wrong sha256 -> model_corrupt")
	ok(ModelStore.state(id) == "corrupt", "hash: state corrupt")
	ok(not FileAccess.file_exists(_abs(c["file"], ".part")) and not FileAccess.file_exists(_abs(c["file"], ".part.json")), "hash: .part and .part.json are gone")
	ok(not FileAccess.file_exists(_abs(c["file"])) and not FileAccess.file_exists(_abs(c["file"], ".ok")), "hash: no model file and no marker")
	# the manifest is fixed; a new start clears the corrupt flag and downloads again
	_single("hash", [""])
	var r2: Dictionary = await _run(id)
	ok(bool(r2["ok"]) and ModelStore.state(id) == "ready", "hash: start again after the fix is ready")


func _d_space() -> void:
	var free: Array = [10 * 1000000]
	ModelStore.free_space_hook = func() -> int: return int(free[0])
	var c: Dictionary = _single("space", [""])
	var id: String = c["id"]
	var r: Dictionary = ModelStore.start(id)
	ok(not bool(r["ok"]) and str(r["err_code"]) == "no_space", "space: 10 MB free -> no_space")
	ok(int(r.get("need_mb", 0)) >= 100, "space: the answer says how many MB are needed")
	var l_sp: Array = await _settled_log(c["tok"])
	print("absence: settled space")
	ok(l_sp.size() == 0, "space: 0 requests were sent")
	ok(ModelStore.state(id) == "missing", "space: state stays missing")
	free[0] = 50 * 1000000
	var r2: Dictionary = ModelStore.start(id)
	ok(not bool(r2["ok"]) and str(r2["err_code"]) == "no_space", "space: 50 MB free is not enough for 3 MB + the 100 MB margin")
	free[0] = 150 * 1000000
	var r3: Dictionary = await _run(id)
	ok(bool(r3["ok"]), "space: 150 MB free is enough")
	ModelStore.remove(id)
	# unknown free space
	free[0] = -1
	var r4: Dictionary = ModelStore.start(id)
	ok(not bool(r4["ok"]) and str(r4["err_code"]) == "space_unknown", "space: unknown free space asks first (space_unknown)")
	var l_su: Array = await _settled_log(c["tok"])
	print("absence: settled space_unknown")
	ok(l_su.size() == 1, "space: space_unknown sent no request (only the earlier success is in the log)")
	var r5: Dictionary = await _run(id, true)
	ok(bool(r5["start"]["ok"]) and bool(r5["ok"]), "space: confirmed with space_unknown goes on and finishes")
	ModelStore.remove(id)
	# a write error removes the .part and says no_space
	ModelStore.free_space_hook = func() -> int: return 500 * 1000000
	ModelStore.write_error_hook = func(done: int) -> bool: return done > 1000000
	var r6: Dictionary = await _run(id)
	ok(not bool(r6["ok"]) and str(r6["err"]) == "no_space", "space: a write error finishes with no_space")
	ok(not FileAccess.file_exists(_abs(c["file"], ".part")) and not FileAccess.file_exists(_abs(c["file"], ".part.json")), "space: a write error removes the .part")
	ok(ModelStore.state(id) == "missing", "space: state missing after a write error")
	ModelStore.write_error_hook = Callable()
	# min_free_mb is a floor
	var c2: Dictionary = _single("space2", [""], "", SIZE, 400)
	ModelStore.free_space_hook = func() -> int: return 300 * 1000000
	var r7: Dictionary = ModelStore.start(c2["id"])
	ok(not bool(r7["ok"]) and str(r7["err_code"]) == "no_space", "space: min_free_mb (400) is a floor")
	ModelStore.free_space_hook = Callable()


func _d_redirects() -> void:
	var c: Dictionary = _single("redir5", ["?redir=5&code=302"])
	var r: Dictionary = await _run(c["id"])
	var l: Array = await _log_wait(c["tok"], 6)
	ok(bool(r["ok"]), "redirects: 5 redirects are followed")
	ok(l.size() == 6 and int((l[4] as Dictionary)["status"]) == 302 and int((l[5] as Dictionary)["status"]) == 200, "redirects: log shows 5 x 302 then 200")
	var c6: Dictionary = _single("redir6", ["?redir=6&code=302"])
	var r6: Dictionary = await _run(c6["id"])
	ok(not bool(r6["ok"]) and str(r6["err"]) == "dl_redirect", "redirects: the 6th redirect -> dl_redirect")
	ok(ModelStore.state(c6["id"]) == "missing", "redirects: state missing after dl_redirect")
	for code in [301, 303, 307, 308]:
		var cc: Dictionary = _single("redir_%d" % code, ["?redir=1&code=%d" % code])
		var rc: Dictionary = await _run(cc["id"])
		ok(bool(rc["ok"]), "redirects: status %d is followed" % code)
	var cr: Dictionary = _single("redirrel", ["?redir=2&kind=rel"])
	var rr: Dictionary = await _run(cr["id"])
	ok(bool(rr["ok"]), "redirects: a relative Location (/f/...) is resolved against the same host")
	# a signed-looking redirect is never stored; a resume starts again from the original address
	var cs: Dictionary = _single("redirx", ["?redir=1&kind=sig&cut=40"])
	var rs: Dictionary = await _run(cs["id"])
	ok(str(rs["err"]) == "dl_net" and ModelStore.state(cs["id"]) == "partial", "redirects: signed redirect then a cut -> partial")
	var pj: String = _read_text(_abs(cs["file"], ".part.json"))
	ok(pj != "" and not pj.contains("?") and not pj.contains("sig") and not pj.contains("http") and not _leaks(pj), "redirects: .part.json has no ?, no signature, no address")
	var rs2: Dictionary = await _run(cs["id"])
	ok(bool(rs2["ok"]), "redirects: the resume finishes ok")
	var ls: Array = await _log_wait(cs["tok"], 4)
	var seq: Array = ls.map(func(e: Dictionary) -> String: return "%s:%d" % [str(e["redir"]), int(e["status"])])
	ok(seq == ["1:302", "0:200", "1:302", "0:206"], "redirects: the resume starts from the original address again (" + ",".join(seq) + ")")
	ok(str((ls[3] as Dictionary)["range"]).begins_with("bytes="), "redirects: the Range header is sent again after the redirect")


func _d_hosts() -> void:
	ModelStore.test_host_map = {
		"evilgithub.com": {"host": "127.0.0.1", "port": _port},
		"github.com": {"host": "127.0.0.1", "port": _port},
		"release-assets.githubusercontent.com": {"host": "127.0.0.1", "port": _port},
	}
	var ce: Dictionary = _single("evil", ["?redir=1&kind=evil"])
	var re: Dictionary = await _run(ce["id"])
	var l_ev: Array = await _settled_log(ce["tok"])
	print("absence: settled hosts evil")
	ok(not bool(re["ok"]) and str(re["err"]) == "dl_host", "hosts: a redirect to evilgithub.com -> dl_host")
	ok(l_ev.size() == 1, "hosts: 0 requests reached the refused host (only the first 302 is logged)")
	ok(ModelStore.state(ce["id"]) == "missing", "hosts: nothing stored")
	var cp: Dictionary = _single("plainhttp", ["?redir=1&kind=plainhttp"])
	var rp: Dictionary = await _run(cp["id"])
	var l_pl: Array = await _settled_log(cp["tok"])
	print("absence: settled hosts plainhttp")
	ok(not bool(rp["ok"]) and str(rp["err"]) == "dl_host" and l_pl.size() == 1, "hosts: a redirect to http://github.com -> dl_host, 0 requests to it")
	var cx: Dictionary = _single("suffix", ["?redir=1&kind=suffix"])
	var rx: Dictionary = await _run(cx["id"])
	ok(bool(rx["ok"]), "hosts: release-assets.githubusercontent.com is allowed by the suffix rule")
	ok(str(ModelStore.stats()["last_host"]) == "release-assets.githubusercontent.com", "hosts: stats name the host, not the address")
	# with the loopback switch off the very same http address is refused before any connection
	ModelStore.allow_http_loopback = false
	var ch: Dictionary = _single("httpoff", [""])
	var rh: Dictionary = await _run(ch["id"])
	var l_of: Array = await _settled_log(ch["tok"])
	print("absence: settled hosts httpoff")
	ok(not bool(rh["ok"]) and str(rh["err"]) == "dl_host", "hosts: http:// with the test switch off -> dl_host")
	ok(l_of.size() == 0, "hosts: http:// with the switch off sent 0 requests")
	ModelStore.allow_http_loopback = true
	ModelStore.test_host_map = {}


func _d_bad() -> void:
	var c0: Dictionary = _single("zero", ["?zero=1"])
	var r0: Dictionary = await _run(c0["id"])
	ok(not bool(r0["ok"]) and str(r0["err"]) == "model_corrupt", "bad: an empty (0 byte) answer -> model_corrupt")
	ok(not FileAccess.file_exists(_abs(c0["file"], ".part")) and ModelStore.state(c0["id"]) == "missing", "bad: nothing is kept after an empty answer")
	var c1: Dictionary = _single("clmis", ["?clmis=-100"])
	var r1: Dictionary = await _run(c1["id"])
	ok(not bool(r1["ok"]) and str(r1["err"]) == "model_corrupt", "bad: Content-Length different from the manifest -> model_corrupt")
	var c2: Dictionary = _single("over", ["?over=500&nocl=1"])
	var r2: Dictionary = await _run(c2["id"])
	ok(not bool(r2["ok"]) and str(r2["err"]) == "model_corrupt", "bad: more bytes than the manifest says (no Content-Length) -> model_corrupt")
	var c2b: Dictionary = _single("overcl", ["?over=500"])
	var r2b: Dictionary = await _run(c2b["id"])
	ok(not bool(r2b["ok"]) and str(r2b["err"]) == "model_corrupt", "bad: Content-Length above the manifest size -> model_corrupt")
	ok(not FileAccess.file_exists(_abs(c2["file"], ".part")) and ModelStore.state(c2["id"]) == "missing", "bad: the oversize .part is removed")
	var c3: Dictionary = _single("s503", ["?status=503", "?status=503"])
	var r3: Dictionary = await _run(c3["id"])
	var l3: Array = await _log_wait(c3["tok"], 2)
	ok(not bool(r3["ok"]) and str(r3["err"]) == "dl_http" and l3.size() == 2, "bad: 503 on both addresses -> dl_http, both were tried once")
	ok(ModelStore.state(c3["id"]) == "missing", "bad: state missing after all addresses failed")
	var c4: Dictionary = _single("mirror", ["?status=404", ""])
	var r4: Dictionary = await _run(c4["id"])
	var l4: Array = await _log_wait(c4["tok"], 2)
	ok(bool(r4["ok"]) and l4.size() == 2, "bad: the first address fails (404), the second one succeeds")
	var c5: Dictionary = _single("nopay", [""], "", SIZE, 0, "absent.bin")
	var r5: Dictionary = await _run(c5["id"])
	ok(not bool(r5["ok"]) and str(r5["err"]) == "dl_http", "bad: a missing file (404) -> dl_http")
	# nothing listens on this port: a connection error, not a crash
	var tok: String = _new_tok()
	_write_manifest([{"id": "m_down", "kind": "stt", "langs": ["en"], "file": "m_down.bin", "bytes": SIZE, "sha256": "a".repeat(64), "min_free_mb": 0,
		"default": true, "ram_hint_mb": 1, "label_ko": "x", "urls": ["http://127.0.0.1:9/f/%s/p3m.bin" % tok], "license": "t"}])
	var r6: Dictionary = await _run("m_down")
	ok(not bool(r6["ok"]) and str(r6["err"]) == "dl_net", "bad: connection refused -> dl_net")
	ok(ModelStore.ERR_TEXT.has(str(r6["err"])), "bad: every error code has a Korean text")


func _d_manifest_bad() -> void:
	var bad_path: String = DIR + "/broken.json"
	var f := FileAccess.open(_g(bad_path), FileAccess.WRITE)
	f.store_string("{\"v\":1,\"hosts\":[\"github.com\"],\"models\":[{\"id\":")
	f.close()
	ModelStore.manifest_path = bad_path
	var mf: Dictionary = ModelStore.manifest()
	ok(not bool(mf["ok"]) and str(mf["err"]) == "bad_manifest", "manifest: broken JSON -> bad_manifest")
	print("selfcheck FAIL-as-expected broken_json (manifest() refuses it)")
	var r: Dictionary = ModelStore.start("anything")
	ok(not bool(r["ok"]) and str(r["err_code"]) == "bad_manifest", "manifest: start() -> bad_manifest")
	ok(ModelStore.state("anything") == "missing" and ModelStore.model("anything").is_empty() and ModelStore.default_id() == "" and ModelStore.active_id() == "", "manifest: other calls stay quiet")
	ModelStore.manifest_path = DIR + "/not_there.json"
	ok(not bool(ModelStore.manifest()["ok"]), "manifest: a missing file -> not ok")
	var f2 := FileAccess.open(_g(bad_path), FileAccess.WRITE)
	f2.store_string("[1,2,3]")
	f2.close()
	ModelStore.manifest_path = bad_path
	ok(not bool(ModelStore.manifest()["ok"]), "manifest: JSON of the wrong shape -> not ok")
	_single("x", [""]) # restore a valid one


func _good_manifest() -> Dictionary:
	return {"v": 1, "hosts": HOSTS.duplicate(), "models": [
		{"id": "ma", "kind": "stt", "langs": ["en"], "file": "ma.bin", "bytes": 100, "sha256": "a".repeat(64), "min_free_mb": 0, "default": true,
			"ram_hint_mb": 1, "label_ko": "a", "urls": ["https://github.com/x/a"], "license": "t"},
		{"id": "mb", "kind": "stt", "langs": ["en"], "file": "mb.bin", "bytes": 100, "sha256": "b".repeat(64), "min_free_mb": 0, "default": false,
			"ram_hint_mb": 1, "label_ko": "b", "urls": ["https://github.com/x/b"], "license": "t"}]}


## Mutates one field of model 0 (or the top level when top is true) and checks validate_manifest refuses it.
func _refuses(label: String, key: String, value: Variant, top: bool = false) -> void:
	var d: Dictionary = _good_manifest()
	if top:
		d[key] = value
	else:
		(d["models"][0] as Dictionary)[key] = value
	var r: Dictionary = ModelStore.validate_manifest(d)
	ok(not bool(r["ok"]) and str(r["err"]) == "bad_manifest" and (r["models"] as Array).is_empty(), "bad_manifest: " + label)


func _d_hardening() -> void:
	ok(bool(ModelStore.validate_manifest(_good_manifest())["ok"]), "hardening: the reference manifest is accepted")
	# 1. wrong types: valid JSON, wrong kinds of value. None may raise a script or engine error (the error log is checked at the end).
	_refuses("v is an object", "v", {"a": 1}, true)
	_refuses("v is a string", "v", "1", true)
	_refuses("v is a float 1.5", "v", 1.5, true)
	_refuses("v is 2", "v", 2, true)
	_refuses("v is a bool", "v", true, true)
	_refuses("hosts is a string", "hosts", "github.com", true)
	_refuses("hosts holds a number", "hosts", [5], true)
	_refuses("models is an object", "models", {}, true)
	_refuses("bytes is a string", "bytes", "100")
	_refuses("bytes is negative", "bytes", -5)
	_refuses("bytes is 0", "bytes", 0)
	_refuses("bytes is a float 1.5", "bytes", 1.5)
	_refuses("bytes is an array", "bytes", [1])
	_refuses("bytes is huge", "bytes", 900000000000000)
	_refuses("urls is a string", "urls", "https://github.com/x")
	_refuses("urls holds a number", "urls", [5])
	_refuses("urls holds an object", "urls", [{}])
	_refuses("urls holds a bad address", "urls", ["not an address"])
	_refuses("sha256 upper case", "sha256", "A".repeat(64))
	_refuses("sha256 short", "sha256", "a".repeat(63))
	_refuses("sha256 is a number", "sha256", 5)
	_refuses("default is a string", "default", "yes")
	_refuses("default is a number", "default", 1)
	_refuses("min_free_mb is a string", "min_free_mb", "250")
	_refuses("min_free_mb is negative", "min_free_mb", -1)
	_refuses("ram_hint_mb is an object", "ram_hint_mb", {})
	_refuses("label_ko is a number", "label_ko", 5)
	_refuses("kind is an array", "kind", [])
	_refuses("langs is a string", "langs", "en")
	_refuses("langs holds a number", "langs", [1])
	_refuses("license is a number", "license", 5)
	_refuses("id is a number", "id", 5)
	_refuses("file is an object", "file", {})
	# whole-string checks: a line break or space at an end must not be forgiven
	for tail in ["\n", "\r\n", "\r", "\t", " "]:
		var tn: String = tail.replace("\r", "CR").replace("\n", "LF").replace("\t", "TAB").replace(" ", "SPACE")
		_refuses("id ends with " + tn, "id", "ma" + tail)
		_refuses("file ends with " + tn, "file", "ma.bin" + tail)
		_refuses("sha256 ends with " + tn, "sha256", "a".repeat(64) + tail)
		_refuses("url ends with " + tn, "urls", ["https://github.com/x" + tail])
		_refuses("id starts with " + tn, "id", tail + "ma")
		_refuses("file starts with " + tn, "file", tail + "ma.bin")
		_refuses("sha256 starts with " + tn, "sha256", tail + "a".repeat(64))
		_refuses("url starts with " + tn, "urls", [tail + "https://github.com/x"])
	_refuses("host ends with LF", "hosts", ["github.com\n"], true)
	_refuses("host has a space", "hosts", [" github.com"], true)
	print("selfcheck FAIL-as-expected manifest_line_breaks (a line break or space at an end of id, file, sha256, url or host is refused)")
	ok(not ModelStore.printable_ascii("a\n") and not ModelStore.printable_ascii("a b") and ModelStore.printable_ascii("a.b-c_1"), "printable_ascii")
	ok(not bool(ModelStore.parse_url("https://github.com/x\n").get("ok", false)) and not bool(ModelStore.parse_url(" https://github.com/x").get("ok", false)) and not bool(ModelStore.parse_url("https://github.com/a b").get("ok", false)), "parse_url takes the text as written (no trimming)")
	for junk in [null, 5, "text", [], [1, 2]]:
		ok(not bool(ModelStore.validate_manifest(junk)["ok"]), "bad_manifest: top level is %s" % str(junk))
	print("selfcheck FAIL-as-expected manifest_types (all of the above end as bad_manifest)")
	# the review probe: a file with a wrong-typed version, through every public function
	var f := FileAccess.open(_g(DIR + "/typed.json"), FileAccess.WRITE)
	f.store_string("{\"v\": {\"x\": 1}, \"hosts\": [\"github.com\"], \"models\": [{\"id\": \"ma\"}]}")
	f.close()
	ModelStore.manifest_path = DIR + "/typed.json"
	ok(not bool(ModelStore.manifest()["ok"]) and str(ModelStore.manifest()["err"]) == "bad_manifest", "hardening: a wrong-typed version in the file -> manifest() bad_manifest")
	var rs: Dictionary = ModelStore.start("ma")
	ok(not bool(rs["ok"]) and str(rs["err_code"]) == "bad_manifest", "hardening: start() -> bad_manifest")
	ok(ModelStore.model("ma").is_empty() and ModelStore.state("ma") == "missing" and ModelStore.info("ma").is_empty() and ModelStore.path_of("ma") == "" and ModelStore.default_id() == "" and ModelStore.active_id() == "", "hardening: every other call stays quiet")
	ok(not ModelStore.remove("ma") and not ModelStore.set_active("ma"), "hardening: remove() and set_active() refuse")
	# 2. names
	for n in ["a:b.bin", "x:", "C:evil", "../x.bin", "a/b.bin", "a\\b.bin", "con.bin", "CON", "con", "nul.txt", "com1", "lpt9.bin", "x.", ".hidden", "-x.bin", "UPPER.bin", "a b.bin", "",
			"x".repeat(65), "한글.bin", "a..b.bin", "a%2fb.bin", "x.part", "x.ok", "x.part.json"]:
		_refuses("file name '%s'" % n, "file", n)
	for n in ["a:b", "a/b", "a\\b", "..", "a..b", "UP", "", "x".repeat(65), " a"]:
		_refuses("id '%s'" % n, "id", n)
	for n in ["ma", "a.b-c_d", "ggml-base.en-q5_1.bin", "x".repeat(64), "0"]:
		var d: Dictionary = _good_manifest()
		(d["models"][0] as Dictionary)["id"] = n
		(d["models"][0] as Dictionary)["file"] = n if n != "ma" else "ma.bin"
		ok(bool(ModelStore.validate_manifest(d)["ok"]), "name '%s' is accepted" % n.left(20))
	# collisions among the four files of every model
	var cases: Array = [["same file", "ma.bin"], [".part of another", "ma.bin.part"], [".ok of another", "ma.bin.ok"], [".part.json of another", "ma.bin.part.json"]]
	for c in cases:
		var d2: Dictionary = _good_manifest()
		(d2["models"][1] as Dictionary)["file"] = str(c[1])
		var r2: Dictionary = ModelStore.validate_manifest(d2)
		ok(not bool(r2["ok"]) and str(r2["err"]) == "bad_manifest", "bad_manifest: file name collision (%s)" % str(c[0]))
	var d5: Dictionary = _good_manifest()
	(d5["models"][1] as Dictionary)["file"] = "mb.bin"
	(d5["models"][0] as Dictionary)["file"] = "mb.bin.x"
	ok(bool(ModelStore.validate_manifest(d5)["ok"]), "names that only look alike are accepted (mb.bin.x and mb.bin)")
	var d3: Dictionary = _good_manifest()
	(d3["models"][1] as Dictionary)["id"] = "ma"
	ok(not bool(ModelStore.validate_manifest(d3)["ok"]), "bad_manifest: duplicate id")
	print("selfcheck FAIL-as-expected manifest_names (colon, device names and collisions are refused)")
	# the model folder boundary
	var dir: String = _g(ModelStore.base_dir)
	ok(ModelStore.in_store(dir.path_join("ma.bin")) and ModelStore.in_store(dir.path_join("ma.bin.part.json")), "in_store: a file directly in the folder")
	ok(not ModelStore.in_store(dir.path_join("sub/ma.bin")) and not ModelStore.in_store(dir.path_join("../ma.bin")) and not ModelStore.in_store(dir.trim_suffix("/").get_base_dir().path_join("ma.bin")), "in_store: sub-folder and parent paths are refused")
	ok(not ModelStore.in_store(dir) and not ModelStore.in_store("") and not ModelStore.in_store(dir.path_join("..") + "/x"), "in_store: the folder itself, empty and '..' are refused")
	var dn: String = dir.trim_suffix("/")
	ok(not ModelStore.in_store("ma.bin") and not ModelStore.in_store("store/ma.bin") and not ModelStore.in_store("./ma.bin"), "in_store: relative paths are refused")
	ok(not ModelStore.in_store(dn + "/ma.bin/") and not ModelStore.in_store(dn + "/sub/../ma.bin") and not ModelStore.in_store(dn + "/./ma.bin"), "in_store: trailing slash, middle '..' and '.' are refused")
	ok(not ModelStore.in_store("/" + dn) and not ModelStore.in_store("/" + dn + "/ma.bin") and not ModelStore.in_store(dn + "/ma\n.bin") and not ModelStore.in_store(dn + "/ma.bin", "relative/dir"), "in_store: UNC-like, control character and relative folder are refused")
	ok(ModelStore.in_store(dn.replace("/", "\\") + "\\ma.bin", dn) and ModelStore.store_path(dn + "//ma.bin") == dn + "/ma.bin", "in_store: back-slashes and doubled slashes are normalised, store_path returns the normalised text")
	ok(ModelStore.store_path(dn + "/ma.bin", dn + "/") == dn + "/ma.bin", "store_path: a folder given with a trailing slash")
	print("selfcheck FAIL-as-expected in_store (a path outside the model folder is refused)")
	var outside: String = _g(DIR).path_join("outside.txt")
	var fo := FileAccess.open(outside, FileAccess.WRITE)
	fo.store_string("keep")
	fo.close()
	ModelStore._rm(outside)
	ok(FileAccess.file_exists(outside), "delete guard: a file outside the model folder is not deleted")
	DirAccess.remove_absolute(outside)
	# 3. Location schemes: other schemes are refused before any request
	for kind in ["ftp", "file", "js", "data", "upperhttp", "plainhttp"]:
		var c: Dictionary = _single("sch_" + kind, ["?redir=1&kind=" + kind])
		ModelStore.test_host_map = {"github.com": {"host": "127.0.0.1", "port": _port}}
		var r: Dictionary = await _run(c["id"])
		var l_sc: Array = await _settled_log(c["tok"])
		print("absence: settled location scheme %s" % kind)
		ModelStore.test_host_map = {}
		ok(not bool(r["ok"]) and str(r["err"]) == "dl_host", "location scheme %s -> dl_host" % kind)
		ok(l_sc.size() == 1, "location scheme %s: 0 requests after the redirect" % kind)
		ok(ModelStore.state(c["id"]) == "missing" and not FileAccess.file_exists(_abs(c["file"], ".part")), "location scheme %s: nothing stored" % kind)
	var csr: Dictionary = _single("schemerel", ["?redir=1&kind=schemerel"])
	var rsr: Dictionary = await _run(csr["id"])
	ok(bool(rsr["ok"]), "location //host keeps working (scheme-relative)")
	var base: Dictionary = ModelStore.parse_url("https://github.com/a/b.bin")
	for loc in ["ftp://x/y", "FILE:///etc/x", "javascript:alert(1)", "data:text/plain,x", "HTTP://github.com/x", "mailto:a@b", "a:b"]:
		ok(ModelStore.resolve_location(base, loc) == loc, "resolve_location keeps an explicit scheme as written (%s)" % loc)
	ok(not bool(ModelStore.parse_url("ftp://x/y").get("ok", false)) and not bool(ModelStore.parse_url("javascript:alert(1)").get("ok", false)), "parse_url refuses other schemes")
	ok(ModelStore.location_clean("/a/b?x=1") and not ModelStore.location_clean("/a b") and not ModelStore.location_clean("/a\r\nX: y") and not ModelStore.location_clean("") and not ModelStore.location_clean("/한글"), "location_clean: printable ASCII only")
	ok(not ModelStore.location_clean("/a/b ") and not ModelStore.location_clean(" /a/b") and not ModelStore.location_clean("/a/b\r\n") and not ModelStore.location_clean("/a/b\n") and not ModelStore.location_clean("/a\tb"), "location_clean: nothing is trimmed first, an end space or end CRLF is refused")
	print("selfcheck FAIL-as-expected location_clean (space, line break and non-ASCII are refused)")
	# 4. an answer without a body leaves nothing behind
	var cn: Dictionary = _single("nobody", ["?nobody=1"])
	var rn: Dictionary = await _run(cn["id"])
	ok(not bool(rn["ok"]) and str(rn["err"]) == "dl_net", "no body: a 200 without length and body -> dl_net")
	ok(not FileAccess.file_exists(_abs(cn["file"], ".part")) and not FileAccess.file_exists(_abs(cn["file"], ".part.json")) and ModelStore.state(cn["id"]) == "missing", "no body: no .part and no .part.json are left")
	var cz: Dictionary = _single("cut0", ["?cut=0"])
	var rz: Dictionary = await _run(cz["id"])
	ok(not bool(rz["ok"]) and str(rz["err"]) == "dl_net", "no body: a connection closed before the first byte -> dl_net")
	ok(not FileAccess.file_exists(_abs(cz["file"], ".part")) and not FileAccess.file_exists(_abs(cz["file"], ".part.json")) and ModelStore.state(cz["id"]) == "missing", "no body: nothing is left after a close before the first byte")
	_single("x", [""])


func _d_stall_and_close() -> void:
	# a connection that goes silent is given up after the stall limit; the .part stays
	ModelStore.stall_timeout_ms = 1200
	var c: Dictionary = _single("stall", ["?stall=300"])
	var t0: int = Time.get_ticks_msec()
	var r: Dictionary = await _run(c["id"])
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ModelStore.stall_timeout_ms = ModelStore.STALL_TIMEOUT_MS
	ok(not bool(r["ok"]) and str(r["err"]) == "dl_net" and took < 6.0, "stall: a silent connection ends as dl_net (%.1f s)" % took)
	ok(ModelStore.state(c["id"]) == "partial" and FileAccess.file_exists(_abs(c["file"], ".part")), "stall: the .part is kept, state partial")
	ModelStore.remove(c["id"])
	# the app closes while a download runs: the worker stops at once, the .part stays
	var c2: Dictionary = _single("close", ["?slow=50"])
	ModelStore.start(c2["id"])
	await _until(func() -> bool: return int(ModelStore.info(c2["id"])["part_bytes"]) >= 200000)
	var t1: int = Time.get_ticks_msec()
	ModelStore.events().notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var took2: float = float(Time.get_ticks_msec() - t1) / 1000.0
	ok(took2 < 2.0, "close: the close request stops the worker within 2 s (%.2f s)" % took2)
	ok(ModelStore.state(c2["id"]) == "partial" and FileAccess.file_exists(_abs(c2["file"], ".part")), "close: .part kept, state partial")
	await _frames(5) # the old worker's last message is delivered first
	var again: Dictionary = await _run(c2["id"])
	ok(bool(again["ok"]), "close: a new start after the close request still works and finishes")
	ModelStore.remove(c2["id"])


func _d_remove() -> void:
	# deleting while a download runs
	var c: Dictionary = _single("rm_live", ["?slow=50"])
	var id: String = c["id"]
	ModelStore.start(id)
	await _until(func() -> bool: return int(ModelStore.info(id)["part_bytes"]) >= 200000)
	var t0: int = Time.get_ticks_msec()
	var removed: bool = ModelStore.remove(id)
	var took: float = float(Time.get_ticks_msec() - t0) / 1000.0
	ok(removed and took < 2.0, "remove: while downloading answers within 2 s (%.2f s)" % took)
	for suf in ["", ".part", ".part.json", ".ok"]:
		ok(not FileAccess.file_exists(_abs(c["file"], suf)), "remove: live download, file '%s' is gone" % suf)
	ok(ModelStore.state(id) == "missing", "remove: state missing")
	# a second download is refused while one runs
	var c2: Dictionary = _single("rm_busy", ["?slow=50"])
	ModelStore.start(c2["id"])
	var again: Dictionary = ModelStore.start(c2["id"])
	ok(not bool(again["ok"]) and str(again["err_code"]) == "busy", "remove: start while downloading -> busy")
	ModelStore.cancel(c2["id"])
	await _wait_fin(c2["id"], 5.0)
	ModelStore.remove(c2["id"])
	# a finished model: all four kinds of file are deleted
	var c3: Dictionary = _single("rm_ready", [""])
	var r3: Dictionary = await _run(c3["id"])
	_put_part(c3["file"], 1000)
	ok(bool(r3["ok"]) and FileAccess.file_exists(_abs(c3["file"], ".part.json")), "remove: setup, all four kinds exist")
	ok(FileAccess.file_exists(_abs(c3["file"])) and FileAccess.file_exists(_abs(c3["file"], ".part")) and FileAccess.file_exists(_abs(c3["file"], ".ok")), "remove: setup, model, .part and .ok exist")
	ok(ModelStore.remove(c3["id"]), "remove: ready model removed")
	for suf in ["", ".part", ".part.json", ".ok"]:
		ok(not FileAccess.file_exists(_abs(c3["file"], suf)), "remove: ready model, file '%s' is gone" % suf)
	ok(ModelStore.state(c3["id"]) == "missing", "remove: ready model, state missing")
	ok(ModelStore.remove(c3["id"]) and not ModelStore.remove("zz_unknown"), "remove: twice is fine, an unknown id is false")


func _d_misc() -> void:
	var c: Dictionary = _single("misc", [""])
	var id: String = c["id"]
	var r: Dictionary = await _run(id)
	ok(bool(r["ok"]) and ModelStore.state(id) == "ready", "misc: ready model")
	ModelStore.mark_corrupt(id)
	ok(ModelStore.state(id) == "corrupt" and not FileAccess.file_exists(_abs(c["file"], ".ok")), "misc: mark_corrupt -> corrupt, the marker is gone")
	var r2: Dictionary = await _run(id)
	ok(bool(r2["ok"]) and ModelStore.state(id) == "ready", "misc: a new start replaces the corrupt model")
	# the state at app start reads the files only (a size and the marker)
	var okp: String = _abs(c["file"], ".ok")
	var good: String = _read_text(okp)
	var f := FileAccess.open(okp, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "sha256": "c".repeat(64), "bytes": SIZE}))
	f.close()
	ok(ModelStore.state(id) == "corrupt", "misc: a marker with another sha256 -> corrupt")
	var f2 := FileAccess.open(okp, FileAccess.WRITE)
	f2.store_string(good)
	f2.close()
	ok(ModelStore.state(id) == "ready", "misc: the right marker -> ready again")
	var mp := FileAccess.open(_abs(c["file"]), FileAccess.READ_WRITE)
	mp.seek_end(0)
	mp.store_8(1)
	mp.close()
	ok(ModelStore.state(id) == "corrupt", "misc: a model file of the wrong size -> corrupt")
	ModelStore.remove(id)
	ok(not _leaks(JSON.stringify(ModelStore.stats())), "misc: stats carry no marker text")


class LogCap:
	extends Logger
	var lines: Array = []
	var mu := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mu.lock()
		lines.append("%s %s:%d %s %s" % [function, file, line, code, rationale])
		mu.unlock()

	func count() -> int:
		mu.lock()
		var n: int = lines.size()
		mu.unlock()
		return n

	func snapshot() -> Array:
		mu.lock()
		var c: Array = lines.duplicate()
		mu.unlock()
		return c
