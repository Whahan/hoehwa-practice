class_name SongStore
extends RefCounted
## 노래 공부: 곡 저장소 (정적 클래스). 설계 docs/song_study_design.md §5.3.
##
##   user://songs/<id>/song.json , audio.mp3      id = "s_" + 12 hex
##   user://songs/_pending.json                    진행 중 작업 기록 (최대 5)
##
## 곡·가사·오디오는 동기화·백업 대상이 아니다: 이 클래스는 progress / prefs / studylog 파일을 읽지도 쓰지도 않고,
## SyncPorts·SyncBackup 은 이 폴더를 읽지 않는다 (시험: tests/song_sync_guard_test.gd).
## 시험은 `SongStore.root = "user://test_songs_<태그>"` 로 바꿔 쓴다. 시험 보호 중(Progress.test_guard)에는 기본
## `user://songs` 를 건드리지 않는다(읽기·쓰기 모두 거절, last_error = "test_guard").
##
## 추가한 것(계약 §5.3 에 더한 부분):
##   verify_audio(id)      오디오 크기·sha256 확인 (list 의 ready 가 쓰며, 크기+수정시간이 같으면 결과를 기억한다)
##   orphan_ids()          song.json 이 없는 폴더(깨져 .bad 로 옮겨진 곡)의 id. delete(id) 로 지운다. usage 에는 바이트가 들어간다.
##   max_songs/max_bytes/fake_used_bytes/write_hook   시험용 조절 장치
##   take_quarantined()    깨져서 .bad 로 옮긴 곡의 id 목록을 돌려주고 비운다 (화면이 토스트로 알린다)

const ROOT := "user://songs"
const MAX_SONGS := 40
const MAX_BYTES := 400 * 1024 * 1024
const MAX_PENDING := 5
const MAX_JSON_BYTES := 8 * 1024 * 1024
const KEEP_BAD := 3 ## song.json.bad, .bad.1, .bad.2
const AUDIO_FILE := "audio.mp3"
const SONG_FILE := "song.json"
const PENDING_FILE := "_pending.json"

static var root: String = ROOT
static var last_error: String = "" ## err_code 마지막 값
static var max_songs: int = MAX_SONGS ## 시험에서만 바꾼다
static var max_bytes: int = MAX_BYTES
static var fake_used_bytes: int = 0 ## 시험: 사용량에 더해지는 가짜 크기
## 시험: (임시 파일 경로) -> bool. 설정돼 있고 false 를 돌려주면 그 파일 쓰기는 실패로 본다 (일부만 써 둔 채 끊긴 상황 흉내).
static var write_hook: Callable = Callable()
static var rename_fail: bool = false ## 시험: 이름 바꾸기가 거절되는 상황
static var _warned: bool = false
static var _quarantined: Array = []
static var _sha_cache: Dictionary = {} ## audio path -> [size, mtime]  (확인이 끝난 것)


# ---------------------------------------------------------------- paths

static func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


## 경로를 비교용으로 정리한다: 절대경로(globalize), `\` -> `/`, `.`·`..` 정리, 각 요소 끝의 점·공백 제거(Windows 가
## 같은 폴더로 보는 `songs.` `songs `), 소문자(대소문자를 가리지 않는 파일 시스템).
static func canon(p: String) -> String:
	var g: String = p
	if g.begins_with("user://") or g.begins_with("res://"):
		g = ProjectSettings.globalize_path(g)
	g = g.replace("\\", "/").simplify_path()
	var parts: PackedStringArray = []
	for part in g.split("/"):
		var c: String = part
		if c != "." and c != "..":
			while c.length() > 1 and (c.ends_with(".") or c.ends_with(" ")):
				c = c.substr(0, c.length() - 1)
		parts.append(c)
	return "/".join(parts).rstrip("/").to_lower()


## 시험 보호: 시험 중에는 실제 폴더 `user://songs` (대소문자·끝 점/공백·절대경로·하위 경로 포함)를 쓰지 않는다.
static func blocked() -> bool:
	if not Progress.test_guard:
		return false
	var r: String = canon(root)
	var real: String = canon(ROOT)
	return r == real or r.begins_with(real + "/")


## 실제 절대경로가 곡 폴더(root) 아래인가 (root 자체는 아님).
static func _inside_root(path: String) -> bool:
	return canon(path).begins_with(canon(root) + "/")


static func _guard() -> bool:
	if blocked():
		last_error = "test_guard"
		if not _warned: ## once per run, so a test that provokes it does not flood the log
			_warned = true
			push_error("TEST_GUARD: SongStore refused to touch the real user://songs")
		return true
	return false


static func song_dir(id: String) -> String:
	return root.path_join(id)


static func _song_file(id: String) -> String:
	return song_dir(id).path_join(SONG_FILE)


static func audio_path(id: String) -> String:
	if not SongModel.is_valid_id(id):
		return ""
	return song_dir(id).path_join(AUDIO_FILE)


static func new_id() -> String:
	var tries: int = 0
	while true:
		var id: String = "s_" + Crypto.new().generate_random_bytes(6).hex_encode()
		tries += 1
		if tries > 20 or not DirAccess.dir_exists_absolute(_g(song_dir(id))):
			return id
	return ""


# ---------------------------------------------------------------- low level files

static func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t: String = f.get_as_text()
	f.close()
	return t


## Writes text (or bytes) to `<path>.tmp` then renames it over `path`. false = failed (the old file stays).
static func _write_atomic(path: String, text: String) -> bool:
	var tmp: String = path + ".tmp"
	var gt: String = _g(tmp)
	if write_hook.is_valid():
		if not bool(write_hook.call(tmp)):
			DirAccess.remove_absolute(gt)
			return false
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	var err: int = f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(gt)
		return false
	if not rename_fail and DirAccess.rename_absolute(gt, _g(path)) == OK:
		return true
	## the rename was refused: the old file is NOT overwritten in place (a cut write would lose it); give up instead
	DirAccess.remove_absolute(gt)
	return false


static func _write_bytes(path: String, data: PackedByteArray) -> bool:
	if write_hook.is_valid() and not bool(write_hook.call(path)):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	var err: int = f.get_error()
	f.close()
	return err == OK


static func _is_link(gp: String) -> bool:
	var d: DirAccess = DirAccess.open(gp.get_base_dir())
	return d != null and d.is_link(gp)


## Removes a folder tree. Never follows a link (junction / symlink): the link itself is removed, what it points to is
## left alone. Refuses anything whose real path is not below `root`.
static func _rm_rf(path: String) -> void:
	var gp: String = _g(path)
	if not _inside_root(gp):
		last_error = "outside_root"
		return
	if _is_link(gp):
		DirAccess.remove_absolute(gp)
		return
	var d: DirAccess = DirAccess.open(gp)
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(gp.path_join(fn))
	DirAccess.remove_absolute(gp)


static func _file_size(path: String) -> int:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n: int = f.get_length()
	f.close()
	return n


## Moves a broken file to `<path>.bad`; older ones shift to .bad.1, .bad.2 (KEEP_BAD files at most).
static func _quarantine_file(path: String) -> void:
	var gp: String = _g(path)
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


static func _song_ids() -> Array:
	var ids: Array = []
	var d: DirAccess = DirAccess.open(_g(root))
	if d == null:
		return ids
	for sub in d.get_directories():
		if SongModel.is_valid_id(sub) and not d.is_link(_g(root).path_join(sub)): ## a link is not a song folder
			ids.append(sub)
	ids.sort()
	return ids


static func take_quarantined() -> Array:
	var q: Array = _quarantined.duplicate()
	_quarantined.clear()
	return q


# ---------------------------------------------------------------- read

## Reads song.json of `id`. -> {"song": Dictionary (normalized, id set) or {}, "status": "ok"|"missing"|"bad"}.
## A broken file (cut JSON, not an object, too big) is moved to `.bad`.
static func _read_song(id: String) -> Dictionary:
	var p: String = _song_file(id)
	if not FileAccess.file_exists(p):
		return {"song": {}, "status": "missing"}
	var size: int = _file_size(p)
	var parsed: Variant = null
	if size >= 0 and size <= MAX_JSON_BYTES:
		var js := JSON.new()
		if js.parse(_read_text(p)) == OK:
			parsed = js.data
	if not (parsed is Dictionary):
		_quarantine_file(p)
		_quarantined.append(id)
		return {"song": {}, "status": "bad"}
	var song: Dictionary = SongModel.normalize(parsed)
	song["id"] = id
	return {"song": song, "status": "ok"}


static func load_song(id: String) -> Dictionary:
	if _guard():
		return {}
	if not SongModel.is_valid_id(id):
		last_error = "bad_id"
		return {}
	var r: Dictionary = _read_song(id)
	if r["status"] == "missing":
		last_error = "not_found"
		return {}
	if r["status"] == "bad":
		last_error = "bad_json"
		return {}
	return r["song"]


## Size and sha256 of the audio file against the song's audio.bytes / audio.sha256.
## Remembers a good result while the file's size and modification time stay the same.
static func verify_audio(id: String) -> bool:
	if _guard() or not SongModel.is_valid_id(id):
		return false
	var r: Dictionary = _read_song(id)
	if r["status"] != "ok":
		return false
	return _audio_ok(id, r["song"])


static func _audio_ok(id: String, song: Dictionary) -> bool:
	var ap: String = audio_path(id)
	if not FileAccess.file_exists(ap):
		return false
	var size: int = _file_size(ap)
	var meta: Dictionary = song.get("audio", {})
	if size <= 0 or size != int(meta.get("bytes", -1)):
		return false
	var want: String = str(meta.get("sha256", ""))
	if want == "":
		return false
	var mt: int = FileAccess.get_modified_time(ap)
	var cached: Variant = _sha_cache.get(ap, null)
	if cached is Array and cached[0] == size and cached[1] == mt:
		return true
	if FileAccess.get_sha256(ap).to_lower() != want:
		_sha_cache.erase(ap)
		return false
	_sha_cache[ap] = [size, mt]
	return true


## sha256 of a byte array as lower-case hex.
static func sha256_hex(data: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(data)
	return h.finish().hex_encode()


static func clear_cache() -> void:
	_sha_cache.clear()


static func list() -> Array:
	var out: Array = []
	if _guard():
		return out
	for id in _song_ids():
		var r: Dictionary = _read_song(id)
		if r["status"] == "bad":
			last_error = "bad_json"
			continue
		if r["status"] != "ok":
			continue
		var s: Dictionary = r["song"]
		var st: Dictionary = s.get("stats", {})
		var created: int = int(s.get("created", 0))
		var last: int = int(st.get("last", 0))
		var ap: String = audio_path(id)
		out.append({
			"id": id,
			"title": s["title"],
			"artist": s["artist"],
			"lang": s["lang"],
			"duration": s["duration"],
			"lines": (s["lines"] as Array).size(),
			"bytes": maxi(0, _file_size(ap)) + maxi(0, _file_size(_song_file(id))),
			"created": created,
			"last": last if last > 0 else created,
			"warnings": s["warnings"],
			"ready": _audio_ok(id, s),
			"read_only": SongModel.is_read_only(s),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["last"] != b["last"]:
			return a["last"] > b["last"]
		if a["created"] != b["created"]:
			return a["created"] > b["created"]
		return str(a["id"]) < str(b["id"]))
	return out


static func orphan_ids() -> Array:
	var out: Array = []
	if _guard():
		return out
	for id in _song_ids():
		if not FileAccess.file_exists(_song_file(id)):
			out.append(id)
	return out


## {songs, bytes, max_songs, max_bytes}. songs counts folders with a song.json; bytes counts every file in the song
## folders (a folder whose song.json was moved to .bad still takes room until delete(id)) plus fake_used_bytes.
static func usage() -> Dictionary:
	var songs: int = 0
	var total: int = fake_used_bytes
	if not _guard():
		for id in _song_ids():
			if FileAccess.file_exists(_song_file(id)):
				songs += 1
			total += _dir_bytes(song_dir(id))
	return {"songs": songs, "bytes": total, "max_songs": max_songs, "max_bytes": max_bytes}


static func _dir_bytes(path: String) -> int:
	var n: int = 0
	var d: DirAccess = DirAccess.open(_g(path))
	if d == null:
		return 0
	for fn in d.get_files():
		n += maxi(0, _file_size(path.path_join(fn)))
	return n


# ---------------------------------------------------------------- write

## Saves an installed song's song.json atomically (temp file, then rename). false: bad id, folder missing, read-only
## song (v > 1), or the write failed (the old song.json stays).
static func save_song(song: Dictionary) -> bool:
	if _guard():
		return false
	var id: String = str(song.get("id", ""))
	if not SongModel.is_valid_id(id):
		last_error = "bad_song"
		return false
	if SongModel.is_read_only(song):
		last_error = "read_only"
		return false
	if not DirAccess.dir_exists_absolute(_g(song_dir(id))):
		last_error = "not_found"
		return false
	var clean: Dictionary = SongModel.normalize(song)
	clean["id"] = id
	if not _write_atomic(_song_file(id), JSON.stringify(clean)):
		last_error = "disk_write"
		return false
	return true


## Installs a processed song. -> {ok, id, err_code}  err_code: bad_song (empty audio, no lines, v > 1) quota_songs quota_bytes sha_mismatch disk_write
## song.audio.sha256 / bytes are checked against `audio` when present (a missing one is filled in).
## The files are written to a staging folder first and renamed, so a failure leaves no partial folder.
static func install(song: Dictionary, audio: PackedByteArray) -> Dictionary:
	if _guard():
		return {"ok": false, "id": "", "err_code": "disk_write"}
	if audio.is_empty():
		return _fail("bad_song")
	var clean: Dictionary = SongModel.normalize(song)
	if clean.is_empty() or SongModel.is_read_only(clean) or (clean["lines"] as Array).is_empty():
		return _fail("bad_song")
	var meta: Dictionary = clean["audio"]
	var sha: String = sha256_hex(audio)
	if str(meta["sha256"]) != "" and str(meta["sha256"]) != sha:
		return _fail("sha_mismatch")
	if int(meta["bytes"]) > 0 and int(meta["bytes"]) != audio.size():
		return _fail("sha_mismatch")
	meta["sha256"] = sha
	meta["bytes"] = audio.size()
	meta["file"] = AUDIO_FILE
	if DirAccess.make_dir_recursive_absolute(_g(root)) != OK:
		return _fail("disk_write")
	var u: Dictionary = usage()
	if int(u["songs"]) >= max_songs:
		return _fail("quota_songs")
	if int(u["bytes"]) + audio.size() > max_bytes:
		return _fail("quota_bytes")
	_clean_staging()
	var id: String = new_id()
	if id == "":
		return _fail("disk_write")
	clean["id"] = id
	if int(clean["created"]) <= 0:
		clean["created"] = int(Time.get_unix_time_from_system())
	var stage: String = root.path_join("_tmp_" + id)
	var ok := false
	if DirAccess.make_dir_recursive_absolute(_g(stage)) == OK:
		ok = _write_bytes(stage.path_join(AUDIO_FILE), audio) and _file_size(stage.path_join(AUDIO_FILE)) == audio.size()
		if ok:
			ok = _write_bytes(stage.path_join(SONG_FILE), JSON.stringify(clean).to_utf8_buffer())
		if ok:
			ok = DirAccess.rename_absolute(_g(stage), _g(song_dir(id))) == OK
	if not ok:
		_rm_rf(stage)
		return _fail("disk_write")
	last_error = ""
	return {"ok": true, "id": id, "err_code": ""}


static func _fail(code: String) -> Dictionary:
	last_error = code
	return {"ok": false, "id": "", "err_code": code}


static func _clean_staging() -> void:
	var d: DirAccess = DirAccess.open(_g(root))
	if d == null:
		return
	for sub in d.get_directories():
		if sub.begins_with("_tmp_"):
			_rm_rf(root.path_join(sub))


## Removes the whole folder of `id` (a broken or orphan one too). true when it is gone.
static func delete(id: String) -> bool:
	if _guard():
		return false
	if not SongModel.is_valid_id(id):
		last_error = "bad_id"
		return false
	_rm_rf(song_dir(id))
	_sha_cache.erase(audio_path(id))
	return not DirAccess.dir_exists_absolute(_g(song_dir(id)))


# ---------------------------------------------------------------- pending jobs

static func _clean_pending_rec(r: Variant) -> Dictionary:
	if not (r is Dictionary):
		return {}
	var job: String = _safe_token(r.get("job", ""))
	if job == "":
		return {}
	var lang: Variant = r.get("lang", "en")
	return {
		"job": job,
		"upload_id": _safe_token(r.get("upload_id", "")),
		"lang": lang if (lang is String and SongModel.LANGS.has(lang)) else "en",
		"title": SongModel.clean_str(r.get("title", ""), SongModel.LEN_TITLE),
		"t": SongModel.int_of(r.get("t", 0), 0, 4102444800, 0),
	}


## [A-Za-z0-9_-]{1,64} or "".
static func _safe_token(v: Variant) -> String:
	if not (v is String):
		return ""
	var s: String = v
	if s.length() < 1 or s.length() > 64:
		return ""
	for i in s.length():
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 45):
			return ""
	return s


static func pending_list() -> Array:
	var out: Array = []
	if _guard():
		return out
	var p: String = root.path_join(PENDING_FILE)
	if not FileAccess.file_exists(p) or _file_size(p) > MAX_JSON_BYTES:
		return out
	var js := JSON.new()
	if js.parse(_read_text(p)) != OK or not (js.data is Array):
		return out ## broken: ignored (the next pending_put writes a fresh file)
	for r in (js.data as Array):
		var c: Dictionary = _clean_pending_rec(r)
		if not c.is_empty():
			out.append(c)
	while out.size() > MAX_PENDING:
		out.remove_at(_oldest(out))
	return out


static func _oldest(arr: Array) -> int:
	var at: int = 0
	for i in arr.size():
		if int(arr[i]["t"]) < int(arr[at]["t"]):
			at = i
	return at


static func _pending_save(arr: Array) -> bool:
	if DirAccess.make_dir_recursive_absolute(_g(root)) != OK:
		return false
	return _write_atomic(root.path_join(PENDING_FILE), JSON.stringify(arr))


static func pending_put(rec: Dictionary) -> bool:
	if _guard():
		return false
	var c: Dictionary = _clean_pending_rec(rec)
	if c.is_empty():
		last_error = "bad_pending"
		return false
	var arr: Array = pending_list()
	var found: int = -1
	for i in arr.size():
		if arr[i]["job"] == c["job"]:
			found = i
	if found >= 0:
		arr[found] = c
	else:
		arr.append(c)
	while arr.size() > MAX_PENDING:
		arr.remove_at(_oldest(arr))
	return _pending_save(arr)


static func pending_remove(job: String) -> bool:
	if _guard():
		return false
	var arr: Array = pending_list()
	var keep: Array = []
	for r in arr:
		if r["job"] != job:
			keep.append(r)
	if keep.size() == arr.size():
		return true
	return _pending_save(keep)


# ---------------------------------------------------------------- lookup

static func _fold(s: String) -> String:
	return " ".join(s.strip_edges().to_lower().split(" ", false))


## 후속(S6)용: 같은 언어의 곡에서 줄 원문이 (공백·대소문자를 무시하고) 같은 첫 줄. {song_id, line_index} 또는 {}.
static func find_line_by_text(lang: String, text: String) -> Dictionary:
	var want: String = _fold(text)
	if _guard() or want == "":
		return {}
	for e in list():
		if e["lang"] != lang:
			continue
		var s: Dictionary = load_song(e["id"])
		var lines: Array = s.get("lines", [])
		for i in lines.size():
			if _fold(str(lines[i]["text"])) == want:
				return {"song_id": e["id"], "line_index": i}
	return {}
