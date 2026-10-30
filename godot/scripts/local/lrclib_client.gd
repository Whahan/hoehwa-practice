class_name LrclibClient
extends Node
## LRCLIB lyrics lookup (song study G3). Design: docs/song_study_design.md section 2 (rules L4..L7) and 5.4.
##
## Rules this class keeps (the UI must keep the rest: only on a user tap, one song = at most 1 find + 1 search):
##  - it never calls anything by itself; every request starts from find() / search() (or a caller's tap),
##  - a request is sent at least MIN_INTERVAL_MS (400 ms) after the previous one ended (all calls are queued),
##  - every request carries User-Agent and Lrclib-Client "HoehwaPractice/<version> (<repo url>)",
##  - HTTP 429: wait Retry-After (+ up to 30 % jitter), retry ONCE, then report rate_limited (no more retries),
##  - only GET /api/get and GET /api/search are used (nothing is ever uploaded or reported),
##  - a search query shorter than 2 characters sends nothing,
##  - an HTTPRequest is never aborted midway (Godot 4.6.3 can block the main thread, see api.gd): a caller that
##    gives up calls abandon(); the result is dropped and the node frees itself after the last request ended.
## The node must be inside the scene tree. `base_url` is https://lrclib.net; tests point it at the fake server.
## While a test guard is on (Store.test_guard_on) a request to the real lrclib.net is refused without sending.
##
## find()   -> {ok, kind: "exact"|"none"|"instrumental"|"error", record: {...}, err_code, retry_after,
##              + message (Korean text for the screen), http_code, has_synced, has_plain, duration_diff, duration_match}
## search() -> {ok, items: Array (<= 20, sorted by duration_diff when a duration is known), err_code, message, http_code}
## err_code: "rate_limited" | "network" (no connection, timeout, HTTP 5xx) | "bad_response" (unreadable answer)
##           | "too_short" (query shorter than 2 characters, nothing was sent) | "" (no error).

signal found(result)
signal searched(result)

const DEFAULT_BASE_URL := "https://lrclib.net"
const APP_NAME := "HoehwaPractice"
const REPO_URL := "https://github.com/Whahan/hoehwa-practice" ## same value as packaging/release.json "repo"
const MIN_INTERVAL_MS := 400
const MAX_ITEMS := 20
const MIN_QUERY_CHARS := 2
const DURATION_TOLERANCE := 2.0 ## seconds: a record within this many seconds of the file counts as the same recording
const DEFAULT_TIMEOUT := 10.0
const DEFAULT_RETRY_AFTER := 5.0 ## used when a 429 has no usable Retry-After header
const MAX_AUTO_WAIT := 30.0 ## a Retry-After longer than this is not waited for: the user is told instead
const JITTER_MAX := 0.3
const BODY_LIMIT := 4 * 1024 * 1024

var base_url: String = DEFAULT_BASE_URL
var timeout: float = DEFAULT_TIMEOUT
var default_retry_after: float = DEFAULT_RETRY_AFTER
## Number of HTTP requests that really left through an HTTPRequest (tests).
var sent_count: int = 0

var _busy: bool = false
var _last_end_ms: int = -1000000
var _pending: int = 0
var _abandoned: bool = false

signal _released


## "HoehwaPractice/<application/config/version> (https://github.com/Whahan/hoehwa-practice)"
static func user_agent() -> String:
	var v: String = str(ProjectSettings.get_setting("application/config/version", "0"))
	return "%s/%s (%s)" % [APP_NAME, v, REPO_URL]


## Looks one song up (GET /api/get). Coroutine: `var r = await client.find(...)`; also emits `found`.
## duration <= 0 means "unknown" (the parameter is not sent).
func find(track: String, artist: String, album: String = "", duration: float = 0.0) -> Dictionary:
	var tr: String = track.strip_edges()
	var ar: String = artist.strip_edges()
	if tr.length() < MIN_QUERY_CHARS or ar.length() < MIN_QUERY_CHARS:
		var short := _find_fail("too_short", 0, "곡 제목과 가수를 두 글자 이상 적어 주세요.")
		found.emit(short)
		return short
	var pairs: Array = [["track_name", tr], ["artist_name", ar]]
	if album.strip_edges() != "":
		pairs.append(["album_name", album.strip_edges()])
	if duration > 0.0:
		pairs.append(["duration", str(int(round(duration)))])
	_pending += 1
	var raw: Dictionary = await _fetch("/api/get?" + _query_string(pairs))
	var res: Dictionary
	if raw.get("cancelled", false):
		res = _find_fail("", 0, "")
		res["cancelled"] = true
	else:
		res = classify_get(int(raw["code"]), raw["headers"], String(raw["text"]), duration, bool(raw["transport"]))
		if res["err_code"] == "rate_limited" and float(res["retry_after"]) < 0.0:
			res["retry_after"] = default_retry_after
	_pending -= 1
	var drop: bool = _abandoned
	_maybe_free()
	if drop:
		return res
	found.emit(res)
	return res


## Searches (GET /api/search). `q` is the free text; when it is empty, track / artist are used.
## `duration` (optional, > 0) adds duration_diff to every item and sorts the nearest first.
func search(q: String, track: String = "", artist: String = "", duration: float = -1.0) -> Dictionary:
	var qq: String = q.strip_edges()
	var tr: String = track.strip_edges()
	var ar: String = artist.strip_edges()
	var pairs: Array = []
	if qq.length() >= MIN_QUERY_CHARS:
		pairs.append(["q", qq])
	elif qq == "" and (tr.length() >= MIN_QUERY_CHARS or ar.length() >= MIN_QUERY_CHARS):
		if tr != "":
			pairs.append(["track_name", tr])
		if ar != "":
			pairs.append(["artist_name", ar])
	if pairs.is_empty():
		var short := {"ok": false, "items": [], "err_code": "too_short", "message": "검색어를 두 글자 이상 적어 주세요.", "http_code": 0}
		searched.emit(short)
		return short
	_pending += 1
	var raw: Dictionary = await _fetch("/api/search?" + _query_string(pairs))
	var res: Dictionary
	if raw.get("cancelled", false):
		res = {"ok": false, "items": [], "err_code": "", "message": "", "http_code": 0, "cancelled": true}
	else:
		res = classify_search(int(raw["code"]), raw["headers"], String(raw["text"]), duration, bool(raw["transport"]))
		if res["err_code"] == "rate_limited" and float(res["retry_after"]) < 0.0:
			res["retry_after"] = default_retry_after
	_pending -= 1
	var drop: bool = _abandoned
	_maybe_free()
	if drop:
		return res
	searched.emit(res)
	return res


## The caller gave up: results are dropped (no signal) and the node frees itself when nothing is running.
## Requests already sent are left to end by themselves.
func abandon() -> void:
	_abandoned = true
	_maybe_free()


func _maybe_free() -> void:
	if _abandoned and _pending <= 0 and is_inside_tree() and not is_queued_for_deletion():
		queue_free()


# ---------------------------------------------------------------- answer interpretation (pure, testable)

## code/headers/text of a finished request -> find() result. `transport_ok == false` means no HTTP answer at all.
static func classify_get(code: int, headers: PackedStringArray, text: String, duration: float, transport_ok: bool = true) -> Dictionary:
	if not transport_ok:
		return _find_fail("network", 0, "인터넷에 연결되지 않았거나 가사 서버가 대답하지 않아요.")
	if code == 404:
		var none := _find_base(true, "none")
		none["http_code"] = 404
		none["message"] = "LRCLIB에서 이 곡의 가사를 찾지 못했어요."
		return none
	if code == 429:
		var ra: float = parse_retry_after(header_value(headers, "Retry-After"))
		var rl := _find_fail("rate_limited", 429, "요청이 너무 많아요. 잠시 뒤에 다시 눌러 주세요.")
		rl["retry_after"] = ra if ra >= 0.0 else -1.0
		return rl
	if code >= 500:
		return _find_fail("network", code, "가사 서버에 문제가 있어요. 잠시 뒤에 다시 시도해 주세요.")
	if code != 200:
		return _find_fail("bad_response", code, "가사 서버의 대답을 이해하지 못했어요.")
	var parsed: Variant = _parse_json(text)
	if not (parsed is Dictionary) or not _looks_like_record(parsed):
		return _find_fail("bad_response", code, "가사 서버의 대답을 읽지 못했어요.")
	var rec: Dictionary = normalize_record(parsed)
	var res := _find_base(true, "instrumental" if rec["instrumental"] else "exact")
	res["record"] = rec
	res["http_code"] = code
	res["has_synced"] = String(rec["syncedLyrics"]).strip_edges() != ""
	res["has_plain"] = String(rec["plainLyrics"]).strip_edges() != ""
	if duration > 0.0 and float(rec["duration"]) > 0.0:
		res["duration_diff"] = absf(float(rec["duration"]) - duration)
		res["duration_match"] = float(res["duration_diff"]) <= DURATION_TOLERANCE
	return res


## Same for search().
static func classify_search(code: int, headers: PackedStringArray, text: String, duration: float, transport_ok: bool = true) -> Dictionary:
	var base := {"ok": false, "items": [], "err_code": "", "message": "", "http_code": code}
	if not transport_ok:
		base["err_code"] = "network"
		base["http_code"] = 0
		base["message"] = "인터넷에 연결되지 않았거나 가사 서버가 대답하지 않아요."
		return base
	if code == 429:
		var ra: float = parse_retry_after(header_value(headers, "Retry-After"))
		base["err_code"] = "rate_limited"
		base["retry_after"] = ra if ra >= 0.0 else -1.0
		base["message"] = "요청이 너무 많아요. 잠시 뒤에 다시 눌러 주세요."
		return base
	if code >= 500:
		base["err_code"] = "network"
		base["message"] = "가사 서버에 문제가 있어요. 잠시 뒤에 다시 시도해 주세요."
		return base
	if code == 404:
		base["ok"] = true
		return base
	if code != 200:
		base["err_code"] = "bad_response"
		base["message"] = "가사 서버의 대답을 이해하지 못했어요."
		return base
	var parsed: Variant = _parse_json(text)
	if not (parsed is Array):
		base["err_code"] = "bad_response"
		base["message"] = "가사 서버의 대답을 읽지 못했어요."
		return base
	var items: Array = []
	for v in (parsed as Array):
		if v is Dictionary and _looks_like_record(v):
			var rec: Dictionary = normalize_record(v)
			rec["duration_diff"] = absf(float(rec["duration"]) - duration) if (duration > 0.0 and float(rec["duration"]) > 0.0) else -1.0
			rec["duration_match"] = duration <= 0.0 or (float(rec["duration_diff"]) >= 0.0 and float(rec["duration_diff"]) <= DURATION_TOLERANCE)
			rec["has_synced"] = String(rec["syncedLyrics"]).strip_edges() != ""
			items.append(rec)
	if duration > 0.0:
		var idx: int = 0
		for it in items:
			it["_i"] = idx
			idx += 1
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da: float = float(a["duration_diff"])
			var db: float = float(b["duration_diff"])
			if da < 0.0:
				da = 1.0e9
			if db < 0.0:
				db = 1.0e9
			if da != db:
				return da < db
			return int(a["_i"]) < int(b["_i"]))
		for it in items:
			it.erase("_i")
	if items.size() > MAX_ITEMS:
		items.resize(MAX_ITEMS)
	base["ok"] = true
	base["items"] = items
	return base


## Record from the server -> the fields this app uses, with fixed types (null lyrics become "").
static func normalize_record(d: Dictionary) -> Dictionary:
	var name: String = _s(d.get("trackName", d.get("name", "")))
	return {
		"id": int(d.get("id", 0)) if (d.get("id") is float or d.get("id") is int) else 0,
		"name": _s(d.get("name", name)),
		"trackName": name,
		"artistName": _s(d.get("artistName", "")),
		"albumName": _s(d.get("albumName", "")),
		"duration": float(d.get("duration", 0.0)) if (d.get("duration") is float or d.get("duration") is int) else 0.0,
		"syncedLyrics": _s(d.get("syncedLyrics", "")),
		"plainLyrics": _s(d.get("plainLyrics", "")),
		"instrumental": d.get("instrumental", false) == true,
	}


## "2" -> 2.0, " 7 " -> 7.0; empty, text, a date or a negative number -> -1.0 (unknown).
static func parse_retry_after(v: String) -> float:
	var s: String = v.strip_edges()
	if s == "" or not s.is_valid_float():
		return -1.0
	var f: float = s.to_float()
	if f < 0.0 or is_nan(f) or is_inf(f):
		return -1.0
	return f


static func header_value(headers: PackedStringArray, name: String) -> String:
	var low: String = name.to_lower()
	for h in headers:
		var s: String = String(h)
		var i: int = s.find(":")
		if i > 0 and s.substr(0, i).strip_edges().to_lower() == low:
			return s.substr(i + 1).strip_edges()
	return ""


static func _s(v: Variant) -> String:
	return v if v is String else ""


static func _parse_json(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


static func _looks_like_record(d: Dictionary) -> bool:
	return (d.get("trackName") is String) or (d.get("name") is String)


static func _find_base(ok: bool, kind: String) -> Dictionary:
	return {
		"ok": ok, "kind": kind, "record": {}, "err_code": "", "retry_after": 0.0, "message": "", "http_code": 0,
		"has_synced": false, "has_plain": false, "duration_diff": -1.0, "duration_match": true,
	}


static func _find_fail(err_code: String, http_code: int, message: String) -> Dictionary:
	var r := _find_base(false, "error")
	r["err_code"] = err_code
	r["http_code"] = http_code
	r["message"] = message
	return r


static func _query_string(pairs: Array) -> String:
	var parts: PackedStringArray = []
	for p in pairs:
		parts.append(String(p[0]).uri_encode() + "=" + String(p[1]).uri_encode())
	return "&".join(parts)


# ---------------------------------------------------------------- sending

func _headers() -> PackedStringArray:
	var ua: String = user_agent()
	return PackedStringArray(["User-Agent: " + ua, "Lrclib-Client: " + ua, "Accept: application/json"])


func _real_host_blocked() -> bool:
	return Store.test_guard_on and base_url.to_lower().contains("lrclib.net")


## One logical request: waits for its turn, sends, and on HTTP 429 waits Retry-After (+ jitter) and sends ONE more time.
## -> {transport: bool, code, headers, text, cancelled}
func _fetch(path_query: String) -> Dictionary:
	var attempt: int = 0
	while true:
		var raw: Dictionary = await _request_once(path_query)
		if raw.get("cancelled", false):
			return raw
		if int(raw["code"]) == 429 and attempt == 0:
			var ra: float = parse_retry_after(header_value(raw["headers"], "Retry-After"))
			if ra < 0.0:
				ra = default_retry_after
			if ra <= MAX_AUTO_WAIT:
				attempt += 1
				await get_tree().create_timer(ra * (1.0 + randf() * JITTER_MAX)).timeout
				if _abandoned:
					raw["cancelled"] = true
					return raw
				continue
		return raw
	return {}


func _request_once(path_query: String) -> Dictionary:
	var out := {"transport": false, "code": 0, "headers": PackedStringArray(), "text": "", "cancelled": false}
	if _abandoned or not is_inside_tree():
		out["cancelled"] = true
		return out
	if _real_host_blocked():
		return out
	# one request at a time, each at least MIN_INTERVAL_MS after the previous one ended
	while _busy:
		await _released
		if _abandoned:
			out["cancelled"] = true
			return out
	_busy = true
	var wait_ms: int = MIN_INTERVAL_MS - (Time.get_ticks_msec() - _last_end_ms)
	if wait_ms > 0:
		await get_tree().create_timer(wait_ms / 1000.0).timeout
	if _abandoned:
		_release()
		out["cancelled"] = true
		return out
	var req := HTTPRequest.new()
	req.timeout = timeout
	req.use_threads = false ## unthreaded: the timeout fires on time (threaded Godot 4.6.3 waited for the slow answer)
	req.body_size_limit = BODY_LIMIT
	add_child(req)
	sent_count += 1
	var err: int = req.request(base_url.rstrip("/") + path_query, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		_release()
		return out
	var res: Array = await req.request_completed
	req.queue_free()
	_release()
	if int(res[0]) == HTTPRequest.RESULT_SUCCESS:
		out["transport"] = true
		out["code"] = int(res[1])
		out["headers"] = res[2]
		out["text"] = (res[3] as PackedByteArray).get_string_from_utf8()
	return out


func _release() -> void:
	_busy = false
	_last_end_ms = Time.get_ticks_msec()
	_released.emit()
