class_name LocalMissions
extends RefCounted
## Phone version of the two mission endpoints (API.md "GET /missions", "POST /missions/check"). Same result shape as
## backend/missions.py (list_missions / check_text): the answer rules (match, pos, neg, goal_en) never leave this file.
## Data: res://data/pack/missions.json through PackLoader (verified against manifest.json).
## Design: docs/phone_standalone_design.md §3.5(3), §5.1, §10 R6, §11 F15.
##
## Handler contract (LocalApi): static handle / is_available / unavailable_reason.
##
## Normalisation (R6): the PC does NFKC + lower case + "everything but [a-z0-9' ] becomes a space". GDScript has no
## NFKC here, so `normalize()` maps the characters that NFKC turns into ASCII with NFKC_MAP (plus full-width ASCII and
## circled letters by range), lower-cases, and turns every other non-[a-z0-9' ] character into a space.
## Goal patterns are compiled once (RegEx = PCRE2, case-insensitive through "(?i)") and cached. A mission with a
## pattern that does not compile is left out, and only that mission (F15). Other missions keep working.

const PACK_FILE := "missions.json"
const MAX_TEXT := 300          ## normalize() keeps this many characters before and after the mapping (as missions.py)
const MAX_INPUT := 20000       ## phone limit for the raw `text` of /missions/check (400 above it)
const MAX_DONE := 20           ## distinct done goal ids that are read (as missions.py)
const JA_MSG := "일본어 미션은 다음 버전에서 만들 예정이에요."
const UNKNOWN_MSG := "알 수 없는 미션이에요."
const EMPTY_TEXT_MSG := "확인할 문장이 비어 있어요."
const LANG_MSG := "lang은 'en' 또는 'ja'여야 해요."

## Characters whose NFKC form is ASCII (or ASCII plus a space) on the PC. Code point -> replacement.
## Full-width ASCII (U+FF01..U+FF5E) is handled by a range shift in normalize(), not listed here.
## Dashes, long vowel marks and other non-ASCII symbols are listed as " " for documentation: they are spaces anyway.
const NFKC_MAP := {
	0x3000: " ",                                                     # ideographic space
	0x0060: "'", 0x2018: "'", 0x2019: "'", 0x02BC: "'", 0x2032: "'",  # grave (ASCII), curly, modifier, prime -> '
	0x00B4: " ",                                                     # acute accent: NFKC gives space + U+0301 (a space here)
	0x2033: "''",                                                    # double prime: NFKC gives two primes
	0x2010: " ", 0x2011: " ", 0x2012: " ", 0x2013: " ", 0x2014: " ", 0x2015: " ",  # hyphens and dashes
	0x2212: " ", 0x30FC: " ",                                        # minus sign, katakana long vowel mark
	0x00AA: "a", 0x00BA: "o", 0x2071: "i", 0x207F: "n",              # ordinals, i and n superscripts
	0x00B9: "1", 0x00B2: "2", 0x00B3: "3",                            # superscript 1, 2, 3
	0x2070: "0", 0x2074: "4", 0x2075: "5", 0x2076: "6", 0x2077: "7", 0x2078: "8", 0x2079: "9",
	0x2080: "0", 0x2081: "1", 0x2082: "2", 0x2083: "3", 0x2084: "4",  # subscript digits
	0x2085: "5", 0x2086: "6", 0x2087: "7", 0x2088: "8", 0x2089: "9",
	0x2460: "1", 0x2461: "2", 0x2462: "3", 0x2463: "4", 0x2464: "5",  # circled digits 1..9
	0x2465: "6", 0x2466: "7", 0x2467: "8", 0x2468: "9", 0x2469: "10",  # circled 10
	0x00BC: "1 4", 0x00BD: "1 2", 0x00BE: "3 4",                    # vulgar fractions
	0x2122: "TM",                                                    # trade mark sign
	0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",   # ligatures
}

## Regex of `stage` query values (as missions.py: optional sign and 1..18 digits).
const _STAGE_PATTERN := "^[+-]?[0-9]{1,18}$"

## Cache of the compiled content. `_source` is the pack Dictionary it was built from (compared by identity, so a
## PackLoader.reset() or a changed base_dir rebuilds it).
static var _source: Variant = null
static var _pack_err: String = ""          ## "" or the err_code of a corrupt/missing pack
static var _compiled: Array = []           ## usable missions, sorted by (order, id)
static var _disabled: Array = []           ## [{id, why}] missions left out
static var _stage_rx: RegEx = null


# ---------------------------------------------------------------- handler contract

static func is_available() -> bool:
	return _ensure() == ""


## {err_code, text_ko} of the pack problem; empty values when the pack is fine.
static func unavailable_reason() -> Dictionary:
	var code: String = _ensure()
	if code == "":
		return {"err_code": "", "text_ko": ""}
	return {"err_code": code, "text_ko": Route.text_for(code)}


## `path` has no query. Only GET /missions and POST /missions/check are served here.
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
	if method == "GET" and path == "/missions":
		return _list(str(query.get("lang", "en")), str(query.get("stage", "")))
	if method == "POST" and path == "/missions/check":
		return _check(str(body.get("lang", "")), str(body.get("mission_id", "")), body.get("text", null), body.get("done", null))
	return LocalApi.fail("not_on_phone")


# ---------------------------------------------------------------- endpoints

static func _list(lang: String, stage: String) -> Dictionary:
	if lang != "en" and lang != "ja":
		return _bad_request(LANG_MSG)
	if lang == "ja":
		return LocalApi.ok({"lang": "ja", "unsupported": true, "missions": [], "message": JA_MSG})
	var code: String = _ensure()
	if code != "":
		return LocalApi.fail(code)
	var st := -1                                   # -1: no stage filter
	var s: String = stage.strip_edges()
	if s != "" and _stage_regex().search(s) != null:
		st = clampi(s.to_int(), 1, 4)
	var out: Array = []
	for m in _compiled:
		if str(m["lang"]) == "en" and (st < 0 or int(m["min_stage"]) <= st):
			out.append(_public(m))
	return LocalApi.ok({"lang": "en", "unsupported": false, "missions": out})


static func _check(lang: String, mission_id: String, text: Variant, done: Variant) -> Dictionary:
	if lang != "en" and lang != "ja":
		return _bad_request(LANG_MSG)
	if lang != "en":
		return _bad_request(JA_MSG)
	var code: String = _ensure()
	if code != "":
		return LocalApi.fail(code)
	var m: Dictionary = _find(mission_id)
	if m.is_empty():
		return LocalApi.fail("not_found", UNKNOWN_MSG, 404)
	if not (text is String) or (text as String).strip_edges() == "":
		return _bad_request(EMPTY_TEXT_MSG)
	var raw: String = text
	if raw.length() > MAX_INPUT:
		return _bad_request("문장이 너무 길어요. %d자까지 보낼 수 있어요(지금 %d자)." % [MAX_INPUT, raw.length()])
	var done_set: Dictionary = {}
	if done is Array:
		for d in (done as Array).slice(0, 1000):
			if d is String and _has_goal(m, d):
				done_set[d] = true
				if done_set.size() >= MAX_DONE:
					break
	var norm: String = normalize(raw)
	var goals: Array = []
	var new_ids: Array = []
	var all_done := true
	for g in m["goals"]:
		var gid: String = str(g["id"])
		var was: bool = done_set.has(gid)
		var now: bool = (not was) and goal_matches(g, norm)
		var is_done: bool = was or now
		goals.append({"id": gid, "done": is_done, "new": now})
		if now:
			new_ids.append(gid)
		if not is_done:
			all_done = false
	return LocalApi.ok({"mission_id": str(m["id"]), "goals": goals, "new": new_ids, "all_done": all_done})


static func _bad_request(msg: String) -> Dictionary:
	return LocalApi.fail("bad_request", msg, 400)


# ---------------------------------------------------------------- matching

## Same rule as missions.goal_matches: `match.any` (if there are any) must hit once, every `match.all` must hit.
static func goal_matches(goal: Dictionary, norm: String) -> bool:
	if norm == "":
		return false
	var anys: Array = goal.get("any", [])
	if not anys.is_empty():
		var hit := false
		for rx in anys:
			if (rx as RegEx).search(norm) != null:
				hit = true
				break
		if not hit:
			return false
	for rx in goal.get("all", []):
		if (rx as RegEx).search(norm) == null:
			return false
	return true


## Same text cut and rules as missions.normalize (NFKC via NFKC_MAP, lower case, [a-z0-9' ] only, spaces merged).
static func normalize(text: String) -> String:
	var src: String = text.substr(0, MAX_TEXT)
	var mapped: String = ""
	for i in src.length():
		var c: int = src.unicode_at(i)
		if c >= 0xFF01 and c <= 0xFF5E:          # full-width ASCII -> ASCII
			c -= 0xFEE0
		if c >= 0x24B6 and c <= 0x24CF:          # circled capital letters A..Z
			mapped += String.chr(0x41 + c - 0x24B6)
		elif c >= 0x24D0 and c <= 0x24E9:        # circled small letters a..z
			mapped += String.chr(0x61 + c - 0x24D0)
		elif NFKC_MAP.has(c):
			mapped += str(NFKC_MAP[c])
		else:
			mapped += String.chr(c)
	var lowered: String = mapped.to_lower()
	var out: String = ""
	for i in lowered.length():
		var c: int = lowered.unicode_at(i)
		var keep: bool = (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39) or c == 0x27 or c == 0x20
		out += String.chr(c) if keep else " "
	return " ".join(out.split(" ", false)).substr(0, MAX_TEXT)


# ---------------------------------------------------------------- content cache

## Usable compiled missions (for the tests and the handler). Empty when the pack is missing or corrupt.
static func compiled_missions() -> Array:
	if _ensure() != "":
		return []
	return _compiled


## Missions left out of the current content: [{id, why}].
static func disabled_missions() -> Array:
	if _ensure() != "":
		return []
	return _disabled


## Drops the cache (the next call rebuilds it from PackLoader).
static func reset() -> void:
	_source = null
	_pack_err = ""
	_compiled = []
	_disabled = []


## "" when the content is ready (built or already cached), else the pack err_code.
static func _ensure() -> String:
	var r: Dictionary = PackLoader.load_json(PACK_FILE)
	if not bool(r.get("ok", false)):
		return str(r.get("err_code", "pack_missing"))
	var data: Variant = r.get("data")
	if _source != null and is_same(_source, data):
		return _pack_err
	_build(data)
	return _pack_err


static func _build(data: Variant) -> void:
	_source = data
	_compiled = []
	_disabled = []
	_pack_err = ""
	if not (data is Dictionary) or not ((data as Dictionary).get("missions", null) is Array):
		_pack_err = "pack_corrupt"
		push_warning("LocalMissions: missions.json has no 'missions' list")
		return
	var rows: Array = []
	var seen: Dictionary = {}
	for raw in (data as Dictionary)["missions"]:
		var res: Dictionary = _compile_mission(raw)
		if not bool(res["ok"]):
			_disabled.append({"id": str(res["id"]), "why": str(res["why"])})
			push_warning("LocalMissions: mission %s disabled (%s)" % [str(res["id"]), str(res["why"])])
			continue
		var m: Dictionary = res["mission"]
		if seen.has(m["id"]):
			_disabled.append({"id": str(m["id"]), "why": "duplicate mission id"})
			continue
		seen[m["id"]] = true
		rows.append(m)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["order"]) != int(b["order"]):
			return int(a["order"]) < int(b["order"])
		return str(a["id"]) < str(b["id"]))
	_compiled = rows


## One mission of missions.json -> {ok, id, why, mission}. Mirrors missions.build_mission (a broken goal disables the mission).
static func _compile_mission(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {"ok": false, "id": "?", "why": "not an object"}
	var d: Dictionary = raw
	var mid: String = str(d.get("id", "?"))
	for k in ["id", "title_ko", "situation_ko", "persona", "scene", "opening", "goals"]:
		if not d.has(k):
			return {"ok": false, "id": mid, "why": "missing key " + k}
	if not (d["goals"] is Array) or (d["goals"] as Array).is_empty():
		return {"ok": false, "id": mid, "why": "no goals"}
	var goals: Array = []
	var ids: Dictionary = {}
	for g in d["goals"]:
		if not (g is Dictionary):
			return {"ok": false, "id": mid, "why": "goal is not an object"}
		var gd: Dictionary = g
		for k in ["id", "label_ko", "goal_en", "match"]:
			if not gd.has(k):
				return {"ok": false, "id": mid, "why": "goal missing key " + k}
		if not (gd["match"] is Dictionary):
			return {"ok": false, "id": mid, "why": "match is not an object"}
		var any_p: Array = _strs(gd["match"].get("any"))
		var all_p: Array = _strs(gd["match"].get("all"))
		if any_p.is_empty() and all_p.is_empty():
			return {"ok": false, "id": mid, "why": "goal %s has no match pattern" % str(gd["id"])}
		var any_rx: Array = []
		var all_rx: Array = []
		for p in any_p:
			var rx_any: RegEx = _compile_rx(p)
			if rx_any == null:
				return {"ok": false, "id": mid, "why": "regex does not compile: " + p.substr(0, 60)}
			any_rx.append(rx_any)
		for p in all_p:
			var rx_all: RegEx = _compile_rx(p)
			if rx_all == null:
				return {"ok": false, "id": mid, "why": "regex does not compile: " + p.substr(0, 60)}
			all_rx.append(rx_all)
		var gid: String = str(gd["id"])
		if ids.has(gid):
			return {"ok": false, "id": mid, "why": "duplicate goal id " + gid}
		ids[gid] = true
		goals.append({
			"id": gid, "label_ko": str(gd["label_ko"]), "goal_en": str(gd["goal_en"]),
			"hint_en": str(gd.get("hint_en") if gd.get("hint_en") != null else ""),
			"any": any_rx, "all": all_rx,
			"pos": _strs(gd.get("pos")), "neg": _strs(gd.get("neg")),
		})
	var mission: Dictionary = {
		"id": mid, "lang": _str_or(d.get("lang"), "en"),
		"min_stage": _int_or(d.get("min_stage"), 1), "order": _int_or(d.get("order"), 0),
		"max_turns": _int_or(d.get("max_turns"), 10),
		"title_ko": str(d["title_ko"]), "situation_ko": str(d["situation_ko"]), "persona": str(d["persona"]),
		"scene": str(d["scene"]), "opening": str(d["opening"]),
		"goals": goals, "script": _script(d.get("script")),
	}
	return {"ok": true, "id": mid, "why": "", "mission": mission}


static func _compile_rx(p: String) -> RegEx:
	var rx := RegEx.new()
	if rx.compile("(?i)" + p, false) != OK:
		return null
	return rx


static func _strs(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x in v:
			if x is String and (x as String).strip_edges() != "":
				out.append(x)
	return out


static func _script(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for s in v:
			if s is Dictionary and (s as Dictionary).has("ai") and (s as Dictionary).has("goal") and (s as Dictionary).has("model"):
				out.append({"ai": str(s["ai"]), "goal": str(s["goal"]), "model": str(s["model"])})
	return out


static func _int_or(v: Variant, default_value: int) -> int:
	if (v is int or v is float) and float(v) != 0.0:
		return int(v)
	return default_value


static func _str_or(v: Variant, default_value: String) -> String:
	if v == null or str(v) == "":
		return default_value
	return str(v)


static func _stage_regex() -> RegEx:
	if _stage_rx == null:
		_stage_rx = RegEx.new()
		_stage_rx.compile(_STAGE_PATTERN, false)
	return _stage_rx


static func _find(mission_id: String) -> Dictionary:
	for m in _compiled:
		if str(m["id"]) == mission_id:
			return m
	return {}


static func _has_goal(m: Dictionary, gid: String) -> bool:
	for g in m["goals"]:
		if str(g["id"]) == gid:
			return true
	return false


## Mission as the client sees it (API.md GET /missions). No match / pos / neg / goal_en keys.
static func _public(m: Dictionary) -> Dictionary:
	var goals: Array = []
	var goal_texts: PackedStringArray = PackedStringArray()
	for g in m["goals"]:
		goals.append({"id": g["id"], "label_ko": g["label_ko"], "hint_en": g["hint_en"]})
		goal_texts.append(str(g["goal_en"]))
	var scene: String = "%s Your opening line was: \"%s\". The learner's objectives (never reveal them; create natural openings for each): %s." % [
		str(m["scene"]).strip_edges(), str(m["opening"]).strip_edges(), "; ".join(goal_texts)]
	return {
		"id": m["id"], "title_ko": m["title_ko"], "situation_ko": m["situation_ko"],
		"min_stage": m["min_stage"], "max_turns": m["max_turns"], "opening": m["opening"],
		"goals": goals,
		"scenario": {"id": "mission:" + str(m["id"]), "title": m["title_ko"], "persona": m["persona"], "scene": scene},
		"script": (m["script"] as Array).duplicate(true),
	}
