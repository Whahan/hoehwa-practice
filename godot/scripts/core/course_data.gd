class_name CourseData
extends RefCounted
## v2.0 new English course data (res://data/course/*.json, built by course_src/tools/build_course.py).
## Reads the files lazily, verifies each one against course_manifest.json (size + SHA-256, same idea as PackLoader)
## and builds id indexes. Design docs/v200_design.md §10.1~10.5, §14 E1.
##
##   var r := CourseData.load_all()            # {ok, err_code, text_ko, files, stats}; cached until reset()
##   if r.ok: CourseData.week(5), CourseData.word("w0211"), CourseData.sentences_for(5), CourseData.available_weeks()
##
## err_code: "course_missing" (no manifest / file not listed / file absent), "course_corrupt" (manifest or file does not
## parse, wrong version `v`, a container key missing, size or hash differs). A broken file only disables what needs it:
## every other file keeps loading and its accessors keep working (`r.files[name]` is "ok" or the err_code).
## Lookups never raise: unknown / invalid ids give {} (or [] / 0). Records without a usable id are skipped (stats().skipped).
## Returned dictionaries are shared with the index: callers must treat them as read-only.
## Numbers: JSON gives floats; whole numbers in the known integer fields are turned into int (o, w, d, ...); a record
## with a non-integer value there is skipped (stats().skipped), so order comparisons never see text.
## Tests: `CourseData.base_dir = "res://tests/fixtures/course_mini"` or a copy under user://test_*; `CourseData.reset()`.

const DEFAULT_DIR := "res://data/course"
const MANIFEST := "course_manifest.json"
const FORMAT_VERSION := 1
const MAX_WEEK := 72
const ERR_MISSING := "course_missing"
const ERR_CORRUPT := "course_corrupt"

const F_WEEKS := "en_weeks.json"
const F_LEXICON := "en_lexicon.json"
const F_PATTERNS := "en_patterns.json"
const F_SENTENCES := "en_sentences.json"
const F_DIALOGUES := "en_dialogues.json"
const F_PROMPTS := "en_speak_prompts.json"
## file -> [accepted container keys (first = canonical), required]. A file may also be a bare JSON array.
const FILES := {
	F_WEEKS: [["weeks"], true],
	F_LEXICON: [["words", "lexicon", "items"], true],
	F_PATTERNS: [["patterns", "items"], true],
	F_SENTENCES: [["sentences", "items"], true],
	F_DIALOGUES: [["dialogues", "items"], true],
	F_PROMPTS: [["prompts", "speak_prompts", "items"], false],
}
## Integer fields per container. A record whose value for one of these keys (when the key is present) is not an
## integer or a whole float (text "52", 4.5, null, ...) is skipped; whole floats (52.0) become int.
const INT_WEEK := ["w", "n", "k", "stage", "legacy_stage"]
const INT_WORD := ["o"]
const INT_PATTERN := ["o"]
const INT_SENTENCE := ["o", "tid"]
const INT_DIALOGUE := ["w", "o"]
const INT_LINE := ["o"]
const INT_PROMPT := ["w", "n", "k", "d", "o", "month"]
const TEXT_KO := {
	ERR_MISSING: "새 코스 데이터를 찾을 수 없어요. 앱을 다시 설치해 주세요.",
	ERR_CORRUPT: "새 코스 데이터가 손상됐어요. 앱을 다시 설치해 주세요.",
}

static var base_dir: String = DEFAULT_DIR
static var _loaded: bool = false
static var _result: Dictionary = {}
static var _weeks: Dictionary = {}       # int w -> week
static var _lexicon: Dictionary = {}     # id -> word
static var _patterns: Dictionary = {}
static var _sentences: Dictionary = {}
static var _dialogues: Dictionary = {}
static var _by_week: Dictionary = {}     # int w -> Array of sentences (o in w*10 .. w*10+9), sorted by o then id
static var _prompts: Array = []
static var _skipped: int = 0


static func reset() -> void:
	_loaded = false
	_result = {}
	_weeks = {}
	_lexicon = {}
	_patterns = {}
	_sentences = {}
	_dialogues = {}
	_by_week = {}
	_prompts = []
	_skipped = 0


static func text_for(err_code: String) -> String:
	return str(TEXT_KO.get(err_code, ""))


## Reads + verifies + indexes everything once (cached, also when it failed). {ok, err_code, text_ko, files, stats}.
static func load_all() -> Dictionary:
	if _loaded:
		return _result
	_loaded = true
	_skipped = 0
	var files_status: Dictionary = {}
	var manifest: Dictionary = _read_manifest()  # {ok, code, files: name -> entry}
	var any_corrupt := false
	var any_missing := false
	for name in FILES.keys():
		var spec: Array = FILES[name]
		var required: bool = spec[1]
		var code := ""
		var items: Array = []
		if not manifest["ok"]:
			code = str(manifest["code"])
		elif not (manifest["files"] as Dictionary).has(name):
			code = ERR_MISSING if required else ""
			if not required:
				files_status[name] = "absent"
				continue
		else:
			var r: Dictionary = _read_file(name, manifest["files"][name], spec[0])
			code = str(r["code"])
			items = r["items"]
		if code == "":
			_index(name, items)
			files_status[name] = "ok"
		else:
			files_status[name] = code
			if code == ERR_CORRUPT:
				any_corrupt = true
			else:
				any_missing = true
	var err := ""
	if any_corrupt:
		err = ERR_CORRUPT
	elif any_missing:
		err = ERR_MISSING
	_build_week_index()
	_result = {
		"ok": err == "", "err_code": err, "text_ko": text_for(err), "files": files_status,
		"stats": stats(),
	}
	return _result


## Counts of what was indexed: {weeks, words, patterns, sentences, dialogues, prompts, skipped}.
static func stats() -> Dictionary:
	return {"weeks": _weeks.size(), "words": _lexicon.size(), "patterns": _patterns.size(),
		"sentences": _sentences.size(), "dialogues": _dialogues.size(), "prompts": _prompts.size(), "skipped": _skipped}


## Largest n such that weeks 1..n are all present (0 when the weeks file is unusable). Weeks after a gap do not count.
static func available_weeks() -> int:
	load_all()
	var n := 0
	while n < MAX_WEEK and _weeks.has(n + 1):
		n += 1
	return n


## Week record (en_weeks.json entry) or {}.
static func week(w: Variant) -> Dictionary:
	load_all()
	var i: int = _to_int(w)
	return _weeks.get(i, {})


static func word(id: Variant) -> Dictionary:
	load_all()
	return _lexicon.get(_key(id), {})


static func sentence(id: Variant) -> Dictionary:
	load_all()
	return _sentences.get(_key(id), {})


static func pattern(id: Variant) -> Dictionary:
	load_all()
	return _patterns.get(_key(id), {})


static func dialogue(id: Variant) -> Dictionary:
	load_all()
	return _dialogues.get(_key(id), {})


## id -> word for every word (active and passive). Read-only.
static func lexicon() -> Dictionary:
	load_all()
	return _lexicon


## Sentences introduced in week w (their `o` is in w*10 .. w*10+9), sorted by o then id. [] for an unknown week.
static func sentences_for(w: Variant) -> Array:
	load_all()
	return _by_week.get(_to_int(w), [])


## The month-end speaking prompts exactly as in en_speak_prompts.json (list), [] when the file is absent or broken.
static func speak_prompts() -> Array:
	load_all()
	return _prompts


# ---------------------------------------------------------------- reading

static func _read_manifest() -> Dictionary:
	var p: String = base_dir.path_join(MANIFEST)
	if not FileAccess.file_exists(p):
		return {"ok": false, "code": ERR_MISSING, "files": {}}
	var parsed: Variant = _parse(FileAccess.get_file_as_bytes(p).get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"ok": false, "code": ERR_CORRUPT, "files": {}}
	var d: Dictionary = parsed
	if not _version_ok(d.get("v", null), true) or not (d.get("files", null) is Array):
		return {"ok": false, "code": ERR_CORRUPT, "files": {}}
	var out: Dictionary = {}
	for f in d["files"]:
		if not (f is Dictionary):
			continue
		var e: Dictionary = f
		var path: Variant = e.get("path", null)
		if path is String and (path as String) != "":
			out[path] = e
	return {"ok": true, "code": "", "files": out}


## {code: "" | err_code, items: Array}
static func _read_file(name: String, entry: Dictionary, keys: Array) -> Dictionary:
	var p: String = base_dir.path_join(name)
	if not FileAccess.file_exists(p):
		return {"code": ERR_MISSING, "items": []}
	var want_bytes: Variant = entry.get("bytes", null)
	var want_sha: Variant = entry.get("sha256", null)
	if not (want_bytes is float or want_bytes is int) or not (want_sha is String):
		return {"code": ERR_CORRUPT, "items": []}
	# Size first, from the file length, before the whole file is read (an empty file is never valid either).
	var fa := FileAccess.open(p, FileAccess.READ)
	if fa == null:
		return {"code": ERR_MISSING, "items": []}
	var length: int = fa.get_length()
	if length <= 0 or length != int(want_bytes):
		return {"code": ERR_CORRUPT, "items": []}
	var bytes: PackedByteArray = fa.get_buffer(length)
	fa.close()
	if _sha256(bytes) != (want_sha as String).to_lower():
		return {"code": ERR_CORRUPT, "items": []}
	var parsed: Variant = _parse(bytes.get_string_from_utf8())
	if parsed is Array:
		return {"code": "", "items": parsed}
	if not (parsed is Dictionary):
		return {"code": ERR_CORRUPT, "items": []}
	var d: Dictionary = parsed
	if d.has("v") and not _version_ok(d["v"], false):
		return {"code": ERR_CORRUPT, "items": []}
	for k in keys:
		if d.get(k, null) is Array:
			return {"code": "", "items": d[k]}
	return {"code": ERR_CORRUPT, "items": []}


static func _parse(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


static func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _version_ok(v: Variant, required: bool) -> bool:
	if v == null:
		return not required
	if v is int or v is float:
		return is_equal_approx(float(v), float(FORMAT_VERSION))
	return false


# ---------------------------------------------------------------- indexing

static func _index(name: String, items: Array) -> void:
	match name:
		F_WEEKS:
			for it in items:
				if not (it is Dictionary):
					_skipped += 1
					continue
				var e: Dictionary = _ints_deep(it)
				var w: Variant = e.get("w", null)
				if not _int_fields(e, INT_WEEK) or not (w is int) or w < 1 or w > MAX_WEEK or _weeks.has(w) or not _days_ok(e):
					_skipped += 1
					continue
				_weeks[w] = e
		F_LEXICON:
			_index_by_id(items, _lexicon, INT_WORD, false)
		F_PATTERNS:
			_index_by_id(items, _patterns, INT_PATTERN, false)
		F_SENTENCES:
			_index_by_id(items, _sentences, INT_SENTENCE, false)
		F_DIALOGUES:
			_index_by_id(items, _dialogues, INT_DIALOGUE, true)
		F_PROMPTS:
			_prompts = []
			for it in items:
				if it is Dictionary and _int_fields(it, INT_PROMPT):
					_prompts.append(it)
				else:
					_skipped += 1


static func _index_by_id(items: Array, into: Dictionary, int_keys: Array, lines: bool) -> void:
	for it in items:
		if not (it is Dictionary):
			_skipped += 1
			continue
		var e: Dictionary = it
		var id: Variant = e.get("id", null)
		if not (id is String) or (id as String) == "" or into.has(id):
			_skipped += 1
			continue
		var good: bool = _int_fields(e, int_keys)
		if good and lines and e.get("lines", null) is Array:
			for ln in e["lines"]:
				if ln is Dictionary and not _int_fields(ln, INT_LINE):
					good = false
		if not good:
			_skipped += 1
			continue
		into[id] = e


static func _build_week_index() -> void:
	_by_week = {}
	for id in _sentences.keys():
		var s: Dictionary = _sentences[id]
		var o: int = _to_int(s.get("o", null))
		if o < 10:
			continue
		var w: int = o / 10
		if not _by_week.has(w):
			_by_week[w] = []
		(_by_week[w] as Array).append(s)
	for w in _by_week.keys():
		(_by_week[w] as Array).sort_custom(_sentence_less)


static func _sentence_less(a: Dictionary, b: Dictionary) -> bool:
	var oa: int = _to_int(a.get("o", 0))
	var ob: int = _to_int(b.get("o", 0))
	if oa != ob:
		return oa < ob
	return str(a.get("id", "")) < str(b.get("id", ""))


# ---------------------------------------------------------------- helpers

static func _key(id: Variant) -> String:
	return id if id is String else ""


## int of an int / whole float / integer string; 0 for anything else (null, text, NaN, inf, bool).
static func _to_int(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		var f: float = v
		if is_nan(f) or is_inf(f) or absf(f) > 1.0e9:
			return 0
		return int(f)
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return 0


## true when every present key in `keys` holds an integer; whole floats are replaced by the int. false = skip the record.
static func _int_fields(e: Dictionary, keys: Array) -> bool:
	for k in keys:
		if not e.has(k):
			continue
		var v: Variant = e[k]
		if v is int:
			continue
		if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1.0e9:
			e[k] = int(v)
			continue
		return false
	return true


## Every day record of a week has an integer `d` (when present).
static func _days_ok(week_rec: Dictionary) -> bool:
	var days: Variant = week_rec.get("days", null)
	if not (days is Array):
		return true
	for dd in days:
		if dd is Dictionary and not _int_fields(dd, ["d"]):
			return false
	return true


static func _ints_deep(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			d[k] = _ints_deep(d[k])
		return d
	if v is Array:
		var a: Array = v
		for i in a.size():
			a[i] = _ints_deep(a[i])
		return a
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1.0e9:
		return int(v)
	return v
