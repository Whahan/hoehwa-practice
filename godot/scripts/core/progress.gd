class_name Progress
extends RefCounted
## Progress data model (same shape as the web app's blank()/normalize()).

const MAX_REVIEW := 1000
const MAX_KNOWN := 30000 ## per language (reading mode "아는 단어")
const FSRS_KEYS := ["due", "stability", "difficulty", "state", "step", "last_review", "reps", "lapses"]


static func blank() -> Dictionary:
	return {
		"start": Plan.DEFAULT_START,
		"checks": {},
		"days": {},
		"xp": {"en": 0, "ja": 0},
		"stats": {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
		"review": [],
		"known_words": {"en": [], "ja": []},
		"updatedAt": 0,
	}


static func _num(v: Variant) -> int:
	if v is float or v is int:
		return int(v)
	return 0


static func _dict(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v
	return {}


static func normalize(s: Variant) -> Dictionary:
	var out: Dictionary = blank()
	if not (s is Dictionary):
		return out
	var src: Dictionary = s
	var start_v: Variant = src.get("start", "")
	if start_v is String and Plan.is_valid_iso(start_v):
		out["start"] = start_v
	out["checks"] = _dict(src.get("checks", {}))
	out["days"] = _dict(src.get("days", {}))
	var xp: Dictionary = _dict(src.get("xp", {}))
	out["xp"] = {"en": _num(xp.get("en", 0)), "ja": _num(xp.get("ja", 0))}
	var stats: Dictionary = _dict(src.get("stats", {}))
	var st := {}
	for l in ["en", "ja"]:
		var one: Dictionary = _dict(stats.get(l, {}))
		st[l] = {"lessons": _num(one.get("lessons", 0)), "talks": _num(one.get("talks", 0))}
	out["stats"] = st
	var rv: Array = []
	var now: int = int(Time.get_unix_time_from_system())
	var raw: Variant = src.get("review", [])
	if raw is Array:
		for r in raw:
			if r is Dictionary:
				var rd: Dictionary = r
				var lang: String = str(rd.get("lang", ""))
				var target: String = str(rd.get("target", ""))
				if target != "" and (lang == "en" or lang == "ja"):
					var rid: String = str(rd.get("id", ""))
					if rid == "":
						rid = new_id()
					var item := {
						"id": rid,
						"lang": lang,
						"target": target,
						"reading": str(rd.get("reading", "")),
						"ko": str(rd.get("ko", "")),
						"note": str(rd.get("note", "")),
					}
					# FSRS card fields; items saved before FSRS become new cards due now.
					for k in FSRS_KEYS:
						if rd.has(k):
							item[k] = rd[k]
					FSRS.ensure_fields(item, now)
					rv.append(item)
	if rv.size() > MAX_REVIEW:
		rv = rv.slice(rv.size() - MAX_REVIEW)
	out["review"] = rv
	out["known_words"] = _known_words(src.get("known_words", {}))
	out["updatedAt"] = _num(src.get("updatedAt", 0))
	return out


## {en: [lemma...], ja: [...]}: strings only, no blanks or duplicates (files without it load as empty).
static func _known_words(v: Variant) -> Dictionary:
	var src: Dictionary = _dict(v)
	var out := {}
	for l in ["en", "ja"]:
		var seen := {}
		var arr: Array = []
		var raw: Variant = src.get(l, [])
		if raw is Array:
			for w in raw:
				if w is String:
					var t: String = (w as String).strip_edges()
					if t != "" and not seen.has(t):
						seen[t] = true
						arr.append(t)
		if arr.size() > MAX_KNOWN:
			arr = arr.slice(arr.size() - MAX_KNOWN)
		out[l] = arr
	return out


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return blank()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return blank()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return normalize(parsed)


static func save_file(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	return true


static func new_id() -> String:
	return "%x%04x" % [Time.get_ticks_usec(), randi() & 0xFFFF]
