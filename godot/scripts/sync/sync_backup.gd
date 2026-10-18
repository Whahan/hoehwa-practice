class_name SyncBackup
extends RefCounted
## 동기화 전 백업 user://sync_backup/ (설계 docs/sync_design.md §7.1).
##
## 폴더 `YYYYMMDD-HHMMSS-<reason>` 안에 progress.json / studylog.json / prefs.json / sync_state.json(있는 것만) 사본과
## meta.json {reason, at, md5{파일:md5}} 를 둔다. reason: first | auto | restore | unlink.
## 보관: 가장 오래된 `first` 1개는 영구, 나머지는 최신 KEEP(10)개.
## 만드는 도중에는 `<이름>.tmp` 폴더이고 다 되면 이름을 바꾼다 -> 반쯤 만든 백업은 목록에 나오지 않는다.

const REASONS := ["first", "auto", "restore", "unlink"]
const KEEP := 10
const FILE_NAMES := {"progress": "progress.json", "studylog": "studylog.json", "prefs": "prefs.json"}
const SIDECAR_NAME := "sync_state.json"


static func _g(path: String) -> String:
	return ProjectSettings.globalize_path(path)


static func _stamp(at: int) -> String:
	var bias_sec: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(maxi(0, at + bias_sec))
	return "%04d%02d%02d-%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]


## Removes a folder and everything in it (backup folders are flat). Never throws.
static func remove_dir(path: String) -> void:
	var gp: String = _g(path)
	if not DirAccess.dir_exists_absolute(gp):
		return
	for f in DirAccess.get_files_at(gp):
		DirAccess.remove_absolute(gp.path_join(f))
	for sub in DirAccess.get_directories_at(gp):
		remove_dir(path.path_join(sub))
	DirAccess.remove_absolute(gp)


static func _copy_file(src: String, dst: String) -> String:
	## -> md5 of the copy, "" on any failure
	if not FileAccess.file_exists(src):
		return ""
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
	if FileAccess.get_open_error() != OK:
		return ""
	var f: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	var err: int = f.get_error()
	f.close()
	if err != OK:
		return ""
	var m_src: String = FileAccess.get_md5(src)
	var m_dst: String = FileAccess.get_md5(dst)
	if m_src == "" or m_src != m_dst:
		return ""
	return m_dst


## Makes a backup. paths = {"progress": path, "studylog": path, "prefs": path} (only the existing files are copied),
## sidecar = path of sync_state.json or "". -> {"ok": bool, "name": String, "error": String}
static func create(root: String, reason: String, at: int, paths: Dictionary, sidecar: String) -> Dictionary:
	if not REASONS.has(reason):
		return {"ok": false, "name": "", "error": "bad reason"}
	if DirAccess.make_dir_recursive_absolute(_g(root)) != OK:
		return {"ok": false, "name": "", "error": "cannot create backup folder"}
	var base: String = "%s-%s" % [_stamp(at), reason]
	var name: String = base
	var n: int = 1
	while DirAccess.dir_exists_absolute(_g(root.path_join(name))) or DirAccess.dir_exists_absolute(_g(root.path_join(name + ".tmp"))):
		n += 1
		name = "%s_%03d" % [base, n]
	var tmp: String = root.path_join(name + ".tmp")
	if DirAccess.make_dir_recursive_absolute(_g(tmp)) != OK:
		return {"ok": false, "name": "", "error": "cannot create backup folder"}
	var md5 := {}
	var sources: Array = []
	for k in FILE_NAMES.keys():
		if paths.get(k, "") is String and (paths[k] as String) != "":
			sources.append([paths[k], FILE_NAMES[k]])
	if sidecar != "":
		sources.append([sidecar, SIDECAR_NAME])
	for s in sources:
		if not FileAccess.file_exists(s[0]):
			continue
		var m: String = _copy_file(s[0], tmp.path_join(s[1]))
		if m == "":
			remove_dir(tmp)
			return {"ok": false, "name": "", "error": "copy failed: %s" % s[1]}
		md5[s[1]] = m
	var meta := {"reason": reason, "at": at, "md5": md5}
	var mf: FileAccess = FileAccess.open(tmp.path_join("meta.json"), FileAccess.WRITE)
	if mf == null:
		remove_dir(tmp)
		return {"ok": false, "name": "", "error": "cannot write meta"}
	mf.store_string(JSON.stringify(meta))
	var merr: int = mf.get_error()
	mf.close()
	if merr != OK or DirAccess.rename_absolute(_g(tmp), _g(root.path_join(name))) != OK:
		remove_dir(tmp)
		return {"ok": false, "name": "", "error": "cannot finish backup"}
	return {"ok": true, "name": name, "error": ""}


static func read_meta(root: String, name: String) -> Dictionary:
	## -> meta {reason, at, md5} or {} when missing / broken
	var p: String = root.path_join(name).path_join("meta.json")
	if not FileAccess.file_exists(p):
		return {}
	var js := JSON.new()
	if js.parse(FileAccess.get_file_as_string(p)) != OK or not (js.data is Dictionary):
		return {}
	var d: Dictionary = js.data
	if not (d.get("reason", null) is String) or not (d.get("md5", null) is Dictionary):
		return {}
	var at: int = int(d.get("at", 0)) if (d.get("at", 0) is int or d.get("at", 0) is float) else 0
	return {"reason": d["reason"], "at": at, "md5": d["md5"]}


## Newest first: [{"name", "reason", "at", "md5"}]
static func list(root: String) -> Array:
	var out: Array = []
	var gr: String = _g(root)
	if not DirAccess.dir_exists_absolute(gr):
		return out
	for name in DirAccess.get_directories_at(gr):
		if name.ends_with(".tmp"):
			continue
		var meta: Dictionary = read_meta(root, name)
		if meta.is_empty():
			continue
		out.append({"name": name, "reason": meta["reason"], "at": meta["at"], "md5": meta["md5"]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) > int(b["at"]) or (int(a["at"]) == int(b["at"]) and str(a["name"]) > str(b["name"])))
	return out


## Deletes the old ones: the oldest `first` stays for ever, of the rest the newest KEEP stay. `protect` (a backup name that is
## about to be restored) is never deleted and does not count. -> number deleted
static func prune(root: String, keep: int = KEEP, protect: String = "") -> int:
	var items: Array = list(root)
	var permanent: String = ""
	for i in range(items.size() - 1, -1, -1):
		if items[i]["reason"] == "first":
			permanent = items[i]["name"]
			break
	var kept: int = 0
	var removed: int = 0
	for it in items:
		if it["name"] == permanent or it["name"] == protect:
			continue
		kept += 1
		if kept > keep:
			remove_dir(root.path_join(it["name"]))
			removed += 1
	# stale half-made folders
	for name in DirAccess.get_directories_at(_g(root)):
		if name.ends_with(".tmp"):
			remove_dir(root.path_join(name))
	return removed


## Checks the files of a backup against meta.md5. -> {"ok": bool, "meta": Dictionary, "error": String}
static func verify(root: String, name: String) -> Dictionary:
	if name == "" or name.contains("/") or name.contains("\\") or name.contains(".."):
		return {"ok": false, "meta": {}, "error": "bad name"}
	var meta: Dictionary = read_meta(root, name)
	if meta.is_empty():
		return {"ok": false, "meta": {}, "error": "no such backup"}
	for fn in (meta["md5"] as Dictionary).keys():
		var p: String = root.path_join(name).path_join(str(fn))
		if not FileAccess.file_exists(p) or FileAccess.get_md5(p) != str((meta["md5"] as Dictionary)[fn]):
			return {"ok": false, "meta": meta, "error": "file changed: %s" % fn}
	return {"ok": true, "meta": meta, "error": ""}


static func _write_bytes_atomic(path: String, bytes: PackedByteArray) -> bool:
	var tmp: String = path + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	var err: int = f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(_g(tmp))
		return false
	if DirAccess.rename_absolute(_g(tmp), _g(path)) == OK:
		return true
	var f2: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f2 == null:
		return false
	f2.store_buffer(bytes)
	f2.close()
	DirAccess.remove_absolute(_g(tmp))
	return true


## Copies progress / studylog / prefs of a (verified) backup over `paths`. A file the backup does not have is written as `{}`
## (a blank file reads as an empty record). The sidecar is NOT restored (§4.8). -> {"ok": bool, "error": String}
static func restore_files(root: String, name: String, paths: Dictionary) -> Dictionary:
	var v: Dictionary = verify(root, name)
	if not v["ok"]:
		return {"ok": false, "error": v["error"]}
	for k in FILE_NAMES.keys():
		var dst: String = str(paths.get(k, ""))
		if dst == "":
			continue
		var src: String = root.path_join(name).path_join(FILE_NAMES[k])
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src) if FileAccess.file_exists(src) else "{}".to_utf8_buffer()
		if not _write_bytes_atomic(dst, bytes):
			return {"ok": false, "error": "cannot write %s" % FILE_NAMES[k]}
	return {"ok": true, "error": ""}
