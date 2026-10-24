class_name LocalLessons
extends RefCounted
## Phone version of POST /lesson with source "tatoeba" (the default): a lesson picked from the pre-built bank
## res://data/pack/lesson_bank_<lang>.json (design docs/phone_standalone_design.md §3.5(1), §5.1, §5.5).
## Same result shape as backend/server.py lesson() -> lesson_rules.make_lesson(): {title, exercises, source, attribution}
## plus `bank_id` ("en-3-2-07"); LocalApi.ok adds via/degraded.
##
## The bank has one cell per (month, week) with about 20 lessons. The cursor in prefs (`lesson_cursor`, e.g.
## {"en-3-2": 7}) gives the next lesson of the cell. When the cell is used up, it starts again from the first lesson
## and the answer carries degraded ["bank_repeat"]. `source:"ai"` never comes here (Route sends it to LocalAi).
##
## Handler contract (LocalApi): static handle / is_available / unavailable_reason.
## A pack file that is missing or fails its hash gives pack_missing / pack_corrupt (PackLoader); a cell that is empty
## or a lesson without exercises is pack_corrupt too (never shown as a normal lesson).

const CURSOR_KEY := "lesson_cursor"
const LANG_MSG := "lang은 'en' 또는 'ja'여야 해요."
const SOURCE_MSG := "source는 'tatoeba' 또는 'ai'여야 해요."


static func is_available(lang: String = "en") -> bool:
	return bool(PackLoader.load_json(_bank_file(_bank_lang(lang)))["ok"])


## {err_code, text_ko} of the bank problem for `lang` (default English); empty values when the pack is fine.
static func unavailable_reason(lang: String = "en") -> Dictionary:
	var r: Dictionary = PackLoader.load_json(_bank_file(_bank_lang(lang)))
	if bool(r["ok"]):
		return {"err_code": "", "text_ko": ""}
	var code: String = str(r["err_code"])
	return {"err_code": code, "text_ko": Route.text_for(code)}


## Per request: the bank of the REQUESTED language decides (a damaged English bank must not stop a Japanese lesson).
static func is_available_for(_path: String, _query: Dictionary, body: Dictionary) -> bool:
	return is_available(_str_or(body.get("lang"), "en"))


static func unavailable_reason_for(_path: String, _query: Dictionary, body: Dictionary) -> Dictionary:
	return unavailable_reason(_str_or(body.get("lang"), "en"))


## en / ja only; anything else is judged by the English bank (handle() answers bad_request for it).
static func _bank_lang(lang: String) -> String:
	return lang if lang == "ja" else "en"


## Only POST /lesson is served here.
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
	if method != "POST" or path != "/lesson":
		return LocalApi.fail("not_on_phone")
	var src: String = _str_or(body.get("source"), "").strip_edges().to_lower()
	if src == "":
		src = "tatoeba"
	if src == "ai":
		return LocalApi.fail("needs_pc")
	if src != "tatoeba":
		return LocalApi.fail("bad_request", SOURCE_MSG, 400)
	var lang: String = _str_or(body.get("lang"), "en")
	if lang != "en" and lang != "ja":
		return LocalApi.fail("bad_request", LANG_MSG, 400)
	var month: int = _clamp_num(body.get("month"), 1, 12, 1)
	var week: int = _clamp_num(body.get("week"), 1, 4, 1)

	var r: Dictionary = PackLoader.load_json(_bank_file(lang))
	if not bool(r["ok"]):
		return LocalApi.fail(str(r["err_code"]))
	var bank: Variant = r["data"]
	if not (bank is Dictionary) or not ((bank as Dictionary).get("lessons") is Dictionary):
		return LocalApi.fail("pack_corrupt")
	var cell_key: String = "%d-%d" % [month, week]
	var cells: Variant = ((bank as Dictionary)["lessons"] as Dictionary).get(cell_key)
	if not (cells is Array) or (cells as Array).is_empty():
		return LocalApi.fail("pack_corrupt")
	var n: int = (cells as Array).size()

	var cursor_key: String = "%s-%s" % [lang, cell_key]
	var c: int = _cursor_of(cursor_key)
	var idx: int = c % n
	var repeat: bool = c >= n
	var lesson: Variant = (cells as Array)[idx]
	if not _lesson_ok(lesson):
		return LocalApi.fail("pack_corrupt")

	_store_cursor(cursor_key, _next_cursor(c, n))
	var out: Dictionary = (lesson as Dictionary).duplicate(true)
	out["source"] = "tatoeba"
	if _str_or(out.get("attribution"), "") == "":
		out["attribution"] = _str_or((bank as Dictionary).get("attribution"), "")
	var degraded: Array = ["bank_repeat"] if repeat else []
	return LocalApi.ok(out, degraded)


# ---------------------------------------------------------------- helpers

static func _bank_file(lang: String) -> String:
	return "lesson_bank_%s.json" % lang


static func _lesson_ok(lesson: Variant) -> bool:
	if not (lesson is Dictionary):
		return false
	var ex: Variant = (lesson as Dictionary).get("exercises")
	return ex is Array and not (ex as Array).is_empty()


## Next cursor value. Values stay in [0, 2n): c < n is the first round, n <= c < 2n the repeats (idx = c % n).
static func _next_cursor(c: int, n: int) -> int:
	var nxt: int = c + 1
	if nxt >= 2 * n:
		nxt = n
	return nxt


static func _cursor_of(key: String) -> int:
	var cur: Variant = Store.prefs.get(CURSOR_KEY, {})
	if not (cur is Dictionary):
		return 0
	var v: Variant = (cur as Dictionary).get(key, 0)
	if v is int or v is float:
		return maxi(int(v), 0)
	return 0


static func _store_cursor(key: String, value: int) -> void:
	var cur: Dictionary = {}
	var old: Variant = Store.prefs.get(CURSOR_KEY, {})
	if old is Dictionary:
		cur = (old as Dictionary).duplicate()
	cur[key] = value
	Store.prefs[CURSOR_KEY] = cur
	Store.save_prefs()


## Number from a JSON value (float or int) or a numeric string; `default_value` otherwise. Then clamped.
static func _clamp_num(v: Variant, lo: int, hi: int, default_value: int) -> int:
	var n: int = default_value
	if v is int or v is float:
		n = int(v)
	elif v is String and (v as String).strip_edges().is_valid_int():
		n = (v as String).strip_edges().to_int()
	return clampi(n, lo, hi)


static func _str_or(v: Variant, default_value: String) -> String:
	if v is String:
		return v
	return default_value
