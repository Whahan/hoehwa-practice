class_name PackLoader
extends RefCounted
## Loads the phone data pack (res://data/pack/*.json, built by backend/tools/build_phone_pack.py) lazily and
## verifies each file against manifest.json the FIRST time it is read (size + SHA-256). Design §5.5, §11 F1/F2.
##
##   var r := PackLoader.load_json("missions.json")     # {ok, data, err_code, error}
##   if not r.ok: return LocalApi.fail(r.err_code)
##
## err_code: "pack_missing" (no manifest / file not listed / file absent), "pack_corrupt" (size or hash differs,
## or the JSON does not parse). A corrupt file only disables the features that need it (the others keep working).
## Tests: `PackLoader.base_dir = "user://test_pack_x"` points at a copy with a broken file; `PackLoader.reset()`
## empties the caches.

const DEFAULT_DIR := "res://data/pack"
const MANIFEST := "manifest.json"

static var base_dir: String = DEFAULT_DIR
static var _cache: Dictionary = {}     # file name -> result Dictionary (ok or failed; both cached)
static var _manifest: Dictionary = {}  # file name -> {bytes, sha256, records}
static var _manifest_state: String = ""  # "" = not read yet, "ok", "missing", "corrupt"


static func reset() -> void:
	_cache.clear()
	_manifest.clear()
	_manifest_state = ""


static func path_of(name: String) -> String:
	return base_dir.path_join(name)


## True when the manifest lists `name` and the file exists (no hash check yet).
static func has_file(name: String) -> bool:
	_read_manifest()
	return _manifest.has(name) and FileAccess.file_exists(path_of(name))


## Names listed in the manifest.
static func files() -> Array:
	_read_manifest()
	return _manifest.keys()


## Parsed JSON of `name` after verification. Result is cached (also when it failed).
static func load_json(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var r: Dictionary = _load(name)
	_cache[name] = r
	return r


## Raw verified bytes (for non-JSON files or re-parsing). Not cached.
static func load_bytes(name: String) -> Dictionary:
	_read_manifest()
	if _manifest_state != "ok":
		return _failed(_manifest_state_code(), "")
	if not _manifest.has(name):
		return _failed("pack_missing", "not in manifest: " + name)
	var p: String = path_of(name)
	if not FileAccess.file_exists(p):
		return _failed("pack_missing", "file absent: " + name)
	var entry: Dictionary = _manifest[name]
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(p)
	if bytes.size() != int(entry.get("bytes", -1)):
		return _failed("pack_corrupt", "size differs: " + name)
	var want: String = str(entry.get("sha256", "")).to_lower()
	if want == "" or FileAccess.get_sha256(p).to_lower() != want:
		return _failed("pack_corrupt", "sha256 differs: " + name)
	return {"ok": true, "data": bytes, "err_code": "", "error": ""}


static func _load(name: String) -> Dictionary:
	var b: Dictionary = load_bytes(name)
	if not b["ok"]:
		return b
	var parsed: Variant = JSON.parse_string((b["data"] as PackedByteArray).get_string_from_utf8())
	if parsed == null:
		return _failed("pack_corrupt", "json does not parse: " + name)
	return {"ok": true, "data": parsed, "err_code": "", "error": ""}


static func _read_manifest() -> void:
	if _manifest_state != "":
		return
	var p: String = path_of(MANIFEST)
	if not FileAccess.file_exists(p):
		_manifest_state = "missing"
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("files", null) is Array):
		_manifest_state = "corrupt"
		return
	for f in (parsed as Dictionary)["files"]:
		if f is Dictionary and (f as Dictionary).has("path"):
			_manifest[str((f as Dictionary)["path"])] = f
	_manifest_state = "ok"


static func _manifest_state_code() -> String:
	return "pack_corrupt" if _manifest_state == "corrupt" else "pack_missing"


static func _failed(err_code: String, detail: String) -> Dictionary:
	if detail != "":
		push_warning("PackLoader: %s (%s)" % [err_code, detail])
	return {"ok": false, "data": null, "err_code": err_code, "error": Route.text_for(err_code)}
