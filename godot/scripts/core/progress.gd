class_name Progress
extends RefCounted
## Progress data model (same shape as the web app's blank()/normalize()).

const MAX_REVIEW := 3000
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


## Tests only: (tmp_path: String, text: String) -> bool, replaces writing the `.tmp` file in write_text_atomic()
## (a hook that writes half of the text and returns false imitates a crash while writing).
static var write_hook: Callable = Callable()
## Tests only: (path: String) -> FileAccess or null, replaces FileAccess.open(path, READ) in read_json_file().
static var open_hook: Callable = Callable()
const KEEP_BAD := 3 ## .bad, .bad.1, .bad.2
## "new" | "ok" | "empty" | "bad" | "unreadable" -- how the last load_file() went.
static var last_load_status: String = ""


## Reads a JSON file. Returns {"status": "new"|"ok"|"empty"|"bad"|"unreadable", "data": Variant}.
##   new = no file, empty = blank file, bad = not valid JSON or not an object (the file is moved to `<path>.bad`,
##   older .bad files shift to .bad.1, .bad.2), unreadable = the file exists but cannot be opened (left untouched).
static func read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"status": "new", "data": null}
	var f: FileAccess = open_hook.call(path) if open_hook.is_valid() else FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"status": "unreadable", "data": null}
	var text: String = f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		return {"status": "empty", "data": null}
	var js := JSON.new()
	if js.parse(text) != OK or not (js.data is Dictionary):
		quarantine(path)
		return {"status": "bad", "data": null}
	return {"status": "ok", "data": js.data}


## Moves a broken file to `<path>.bad` (never overwrites one: older ones shift to .bad.1, .bad.2; KEEP_BAD at most).
static func quarantine(path: String) -> void:
	var gp: String = ProjectSettings.globalize_path(path)
	var i: int = KEEP_BAD - 1
	while i >= 0:
		var from: String = gp + (".bad" if i == 0 else ".bad.%d" % i)
		if FileAccess.file_exists(from):
			if i == KEEP_BAD - 1:
				DirAccess.remove_absolute(from)
			else:
				var to: String = gp + ".bad.%d" % (i + 1)
				if FileAccess.file_exists(to):
					DirAccess.remove_absolute(to)
				DirAccess.rename_absolute(from, to)
		i -= 1
	DirAccess.rename_absolute(gp, gp + ".bad")


## Test safety net: Store turns this on for test scenes (TEST_GUARD). While on, the real app files may not be written.
static var test_guard: bool = false
## File names of the user's real app files.
const REAL_FILE_NAMES := ["prefs.json", "progress.json", "studylog.json", "remote.json", "curriculum.json"]


## True when test_guard is on and `path` is one of the real app files (by name) outside user://test*.
static func guard_blocks(path: String) -> bool:
	if not test_guard or not REAL_FILE_NAMES.has(path.get_file()):
		return false
	if path.begins_with("user://test"):
		return false
	if path.begins_with("user://"):
		return true
	# a plain file-system path is only the real file if it is the very same place
	return ProjectSettings.globalize_path(path) == ProjectSettings.globalize_path("user://" + path.get_file())


## Writes `text` to `<path>.tmp` and then renames it over `path`, so a failure while writing leaves the old file.
static func write_text_atomic(path: String, text: String) -> bool:
	if guard_blocks(path):
		push_error("TEST_GUARD: refused to write the real user file " + path)
		return false
	var tmp: String = path + ".tmp"
	var gt: String = ProjectSettings.globalize_path(tmp)
	if write_hook.is_valid():
		if not bool(write_hook.call(tmp, text)):
			DirAccess.remove_absolute(gt)
			return false
	else:
		var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			return false
		f.store_string(text)
		var err: int = f.get_error()
		f.close()
		if err != OK:
			DirAccess.remove_absolute(gt)
			return false
	if DirAccess.rename_absolute(gt, ProjectSettings.globalize_path(path)) == OK:
		return true
	# rename refused (target busy?): the .tmp file is complete, so fall back to a plain overwrite
	var f2: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f2 == null:
		return false
	f2.store_string(text)
	f2.close()
	DirAccess.remove_absolute(gt)
	return true


## Never throws away a file it could not understand: broken -> `.bad` + blank, unreadable -> blank with
## last_load_status == "unreadable" (the caller must then not save over it).
static func load_file(path: String) -> Dictionary:
	var r: Dictionary = read_json_file(path)
	last_load_status = str(r["status"])
	return normalize(r["data"])


static func save_file(path: String, data: Dictionary) -> bool:
	return write_text_atomic(path, JSON.stringify(data, "\t"))


static func new_id() -> String:
	return "%x%04x" % [Time.get_ticks_usec(), randi() & 0xFFFF]
