extends Node
## LocalApi: serves API.md requests inside the phone, with the SAME result shape as Api (see api.gd header):
##   {ok, code, data, bytes, error, cancelled, err_code, err_body}  and  data.via == "phone", data.degraded == [].
## Design: docs/phone_standalone_design.md §4.4, §5.1–5.3.
##
## A0 (orchestrator): contract, handler registry, `ok`/`fail`, query parsing. A1 implements `dispatch`,
## `available`, `why_none`, the synthetic /health and the Api hook. Handlers (A3a, A3b, A4, later B/C) live in
## res://scripts/local/local_<name>.gd and expose three static functions:
##   static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary
##   static func is_available() -> bool
##   static func unavailable_reason() -> Dictionary   # {err_code, text_ko}
## `handle` returns `LocalApi.ok(data, degraded)` or `LocalApi.fail(err_code[, text_ko])`. `path` is given
## WITHOUT the query; `query` holds the parsed query string (all values are Strings).
## Handlers are loaded by path (`load()`), never by class name, so a missing handler file only means
## `available(path) == false` — A1 is complete and testable without the other workers' files.

## handler key (Route.POLICY "phone") -> script path.
const HANDLERS := {
	"lessons": "res://scripts/local/local_lessons.gd",
	"practice": "res://scripts/local/local_practice.gd",
	"missions": "res://scripts/local/local_missions.gd",
	"reading": "res://scripts/local/local_reading.gd",
	"stt": "res://scripts/local/local_stt.gd",
	"ai": "res://scripts/local/local_ai.gd",
	# "health" and "curriculum" are synthesized by LocalApi itself (A1).
}

## Keys of the synthetic phone /health (same keys as the PC /health so Backend.health readers keep working).
const HEALTH_TEMPLATE := {
	"ok": true, "via": "phone", "stt": false, "score": false, "tts": {"en": false, "ja": false},
	"llm": false, "llm_provider": "none", "phoneme": false, "tatoeba": false, "grammar": false,
	"llm_fallback": {"active": false, "until": null, "reason": ""},
}

## Counts every request served by a phone handler (tests; Api.sent_count must NOT move for these).
var served_count: int = 0
## Tests may override handler scripts: key -> GDScript (e.g. a fake handler).
var handler_override: Dictionary = {}

var _loaded: Dictionary = {}   # key -> GDScript or null (missing)


## Success result. `data` gets via/degraded when it is a Dictionary.
static func ok(data: Variant, degraded: Array = []) -> Dictionary:
	if data is Dictionary:
		var d: Dictionary = (data as Dictionary).duplicate()
		d["via"] = "phone"
		d["degraded"] = degraded.duplicate()
		data = d
	return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false, "err_code": "", "err_body": null}


## Failure result. `text_ko` defaults to Route.ERR_TEXT[err_code]; `code` defaults to Route.ERR_HTTP[err_code].
static func fail(err_code: String, text_ko: String = "", code: int = 0) -> Dictionary:
	if text_ko == "":
		text_ko = Route.text_for(err_code)
	if code == 0:
		code = Route.http_for(err_code)
	return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": text_ko, "cancelled": false,
		"err_code": err_code, "err_body": {"error": text_ko, "code": err_code, "via": "phone"}}


## "/practice/sentences?lang=en&n=5" -> ["/practice/sentences", {"lang": "en", "n": "5"}] (values URL-decoded).
static func split_query(path: String) -> Array:
	var i: int = path.find("?")
	if i < 0:
		return [path, {}]
	var q := {}
	for part in path.substr(i + 1).split("&", false):
		var eq: int = part.find("=")
		if eq < 0:
			q[part.uri_decode()] = ""
		else:
			q[part.substr(0, eq).uri_decode()] = part.substr(eq + 1).uri_decode()
	return [path.substr(0, i), q]


## Handler script for a policy key, or null when the file is missing / fails to load.
func handler_for(key: String) -> GDScript:
	if handler_override.has(key):
		return handler_override[key]
	if _loaded.has(key):
		return _loaded[key]
	var script: GDScript = null
	var p: String = str(HANDLERS.get(key, ""))
	if p != "" and ResourceLoader.exists(p):
		var res: Resource = load(p)
		if res is GDScript:
			script = res
	_loaded[key] = script
	return script


## A0 stub (A1 implements): can a phone handler serve `method path` right now?
func available(method: String, path: String, body: Dictionary = {}) -> bool:
	var entry: Dictionary = Route.policy_for(method, path, body)
	var key: String = str(entry.get("phone", ""))
	if key == "":
		return false
	if key == "health" or key == "curriculum":
		return true
	var script: GDScript = handler_for(key)
	if script == null:
		return false
	return bool(script.call("is_available"))


## A0 stub (A1 implements, incl. threads for slow handlers and the synthetic /health). Must stay a coroutine.
func dispatch(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var sq: Array = split_query(path)
	var entry: Dictionary = Route.policy_for(method, sq[0], body)
	var key: String = str(entry.get("phone", ""))
	if key == "":
		return fail("not_on_phone")
	if key == "health":
		return ok(health())
	if key == "curriculum":
		return fail("needs_pc")   # A1: Store's bundled curriculum
	var script: GDScript = handler_for(key)
	if script == null:
		return fail("pack_missing")
	served_count += 1
	return script.call("handle", method.to_upper(), sq[0], sq[1], body)


## {err_code, text_ko}: why `method path` has no phone processing right now.
func why_none(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = Route.policy_for(method, path, body)
	var key: String = str(entry.get("phone", ""))
	if key == "" or key == "health" or key == "curriculum":
		return {"err_code": "not_on_phone", "text_ko": Route.text_for("not_on_phone")}
	var script: GDScript = handler_for(key)
	if script == null:
		return {"err_code": "pack_missing", "text_ko": Route.text_for("pack_missing")}
	return script.call("unavailable_reason")


## Synthetic phone /health (A1 fills stt/score/tts/llm/tatoeba from the handlers and Tts).
func health() -> Dictionary:
	return HEALTH_TEMPLATE.duplicate(true)
