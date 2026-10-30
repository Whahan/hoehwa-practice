extends Node
## 노래 공부 G2: SongStore (곡 저장소). 서버·마이크를 쓰지 않는다.
##   godot --headless --path <project> res://tests/song_store_test.tscn
## Exit code 0 = all passed. Last line: "== song_store_test result: N passed, 0 failed =="
## 저장은 user://test_songs_store 에만 한다 (SongStore.root 를 바꿔서). 기본 user://songs 와 prefs / progress 파일은
## 시험 전후 목록(이름·크기)을 비교해서 건드리지 않았음을 확인한다. 오디오는 가짜 바이트이고 가사는 직접 쓴 문장이다.

const ROOT := "user://test_songs_store"
const MARK := "ZZSONGLINEZZ"

var passed: int = 0
var failed: int = 0
var _before: Dictionary = {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _audio(n: int, salt: int = 0) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = (i * 31 + 7 + salt) & 255
	return b


func _song(title: String = "Test Song", created: int = 1790000000, last: int = 0) -> Dictionary:
	return {"v": 1, "lang": "en", "title": title, "artist": "Tester", "created": created, "duration": 30.0,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "x.m4a"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"lines": [
			{"i": 0, "p": 0, "t0": 1.0, "t1": 3.0, "text": "The sky is blue today", "words": []},
			{"i": 1, "p": 0, "t0": 4.0, "t1": 6.0, "text": MARK, "words": []}],
		"glossary": {}, "marks": {"lines": [1], "words": []}, "stats": {"plays": 0, "last": last, "best": {}}, "warnings": []}


func _read(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func _write(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(_g(path))
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(_g(path).path_join(fn))
	DirAccess.remove_absolute(_g(path))


func _dirs(path: String) -> Array:
	var d := DirAccess.open(_g(path))
	if d == null:
		return []
	var out: Array = Array(d.get_directories())
	out.sort()
	return out


func _files(path: String) -> Array:
	var d := DirAccess.open(_g(path))
	if d == null:
		return []
	var out: Array = Array(d.get_files())
	out.sort()
	return out


## State of the user's real files this test must not touch: the app files in user:// (size + modified time) and the
## default songs folder (does it exist, what is in it). Other files are ignored (another test may run at the same time).
func _user_listing() -> Dictionary:
	var out := {}
	for fn in ["prefs.json", "progress.json", "studylog.json", "remote.json", "curriculum.json", "sync_state.json"]:
		var p: String = "user://" + fn
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			out[fn] = [f.get_length() if f != null else -1, FileAccess.get_modified_time(p)]
		else:
			out[fn] = null
	out["songs_dir"] = DirAccess.dir_exists_absolute(_g("user://songs"))
	out["songs_dirs"] = _dirs("user://songs")
	out["songs_files"] = _files("user://songs")
	return out


func _install(title: String = "Test Song", n: int = 1500, created: int = 1790000000, last: int = 0) -> Dictionary:
	return SongStore.install(_song(title, created, last), _audio(n, title.length()))


func _fresh() -> void:
	SongStore.write_hook = Callable()
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.clear_cache()
	SongStore.take_quarantined()
	_rm_rf(ROOT)


func _ready() -> void:
	print("== song_store_test start ==")
	var old_root: String = SongStore.root
	_before = _user_listing()
	SongStore.root = ROOT
	_fresh()

	_test_ids_and_paths()
	_test_install_and_list()
	_test_install_rejects()
	_test_quota()
	_test_write_failures()
	_test_broken_json()
	_test_audio_checks()
	_test_atomic_save()
	_test_read_only()
	_test_pending()
	_test_order_and_lookup()
	_test_delete()
	_test_traversal()
	_test_guard()

	_fresh()
	SongStore.root = old_root
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "prefs / progress / studylog / remote / sync_state files and user://songs untouched: before == after")
	ok(after["songs_dir"] == _before["songs_dir"], "default user://songs was not created or removed by this test")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)), "test folder cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_store_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- sections

func _test_ids_and_paths() -> void:
	print("[ids and paths]")
	var a: String = SongStore.new_id()
	var b: String = SongStore.new_id()
	ok(SongModel.is_valid_id(a) and a != b, "new_id: s_ + 12 hex, different each time")
	ok(SongStore.audio_path(a) == ROOT + "/" + a + "/audio.mp3", "audio_path under the root")
	ok(SongStore.audio_path("../x") == "" and SongStore.audio_path("") == "", "audio_path of a bad id is empty")
	ok(SongStore.list().is_empty() and SongStore.usage()["songs"] == 0 and SongStore.usage()["bytes"] == 0, "no folder yet: empty list, usage 0")
	ok(SongStore.load_song("s_000000000000").is_empty() and SongStore.last_error == "not_found", "load_song of a missing id -> {} / not_found")
	ok(SongStore.load_song("../../x").is_empty() and SongStore.last_error == "bad_id", "load_song of a path-like id -> {} / bad_id")


func _test_install_and_list() -> void:
	print("[install and list]")
	_fresh()
	var r: Dictionary = _install("Alpha", 1500)
	ok(r["ok"] == true and SongModel.is_valid_id(r["id"]) and r["err_code"] == "", "install ok")
	var id: String = r["id"]
	var l: Array = SongStore.list()
	ok(l.size() == 1 and l[0]["id"] == id and l[0]["title"] == "Alpha", "list shows the song")
	ok(l[0]["lines"] == 2 and l[0]["lang"] == "en" and l[0]["ready"] == true and l[0]["read_only"] == false, "list entry: lines / lang / ready")
	var ap: String = SongStore.audio_path(id)
	var f := FileAccess.open(ap, FileAccess.READ)
	var size: int = f.get_length() if f != null else -1
	if f != null:
		f.close()
	var s: Dictionary = SongStore.load_song(id)
	ok(size == 1500 and size == int(s["audio"]["bytes"]), "audio file size == audio.bytes")
	ok(s["audio"]["sha256"] == FileAccess.get_sha256(ap) and s["id"] == id, "audio.sha256 and id filled in")
	ok(s["lines"][1]["text"] == MARK and int(s["created"]) == 1790000000, "song round trip")
	ok(l[0]["bytes"] >= 1500, "list bytes counts the audio")
	var u: Dictionary = SongStore.usage()
	ok(u["songs"] == 1 and u["bytes"] >= 1500 and u["max_songs"] == 40 and u["max_bytes"] == 400 * 1024 * 1024, "usage")
	ok(_dirs(ROOT) == [id] and _files(ROOT + "/" + id) == ["audio.mp3", "song.json"], "folder holds exactly audio.mp3 + song.json")
	# a matching sha / bytes given up front is accepted
	var s2 := _song("Beta")
	var au := _audio(900, 3)
	s2["audio"]["sha256"] = SongStore.sha256_hex(au)
	s2["audio"]["bytes"] = 900
	ok(SongStore.install(s2, au)["ok"] == true, "install with the right sha256 / bytes")
	var s3 := _song("Gamma")
	s3["created"] = 0
	var r3: Dictionary = SongStore.install(s3, _audio(100))
	ok(r3["ok"] and int(SongStore.load_song(r3["id"])["created"]) > 0, "created = 0 -> filled with the current time")
	ok(not _has_staging(), "no staging folders left")


func _has_staging() -> bool:
	for d in _dirs(ROOT):
		if not SongModel.is_valid_id(d):
			return true
	return false


func _test_install_rejects() -> void:
	print("[install rejects]")
	_fresh()
	var dirs0: Array = _dirs(ROOT)
	var bad := _song()
	bad["audio"]["sha256"] = "f".repeat(64)
	var r: Dictionary = SongStore.install(bad, _audio(500))
	ok(r["ok"] == false and r["err_code"] == "sha_mismatch" and r["id"] == "", "sha mismatch -> sha_mismatch")
	ok(_dirs(ROOT) == dirs0, "sha mismatch: no folder created")
	var bad2 := _song()
	bad2["audio"]["bytes"] = 499
	ok(SongStore.install(bad2, _audio(500))["err_code"] == "sha_mismatch", "declared bytes differ -> sha_mismatch")
	ok(SongStore.install(_song(), PackedByteArray())["err_code"] == "bad_song", "empty audio -> bad_song")
	var v2 := _song()
	v2["v"] = 2
	ok(SongStore.install(v2, _audio(100))["err_code"] == "bad_song", "v:2 song -> bad_song")
	var nolines := _song()
	nolines["lines"] = []
	ok(SongStore.install(nolines, _audio(100))["err_code"] == "bad_song", "song without lines -> bad_song")
	ok(SongStore.install({}, _audio(100))["err_code"] == "bad_song", "empty song -> bad_song")
	ok(_dirs(ROOT).is_empty() and SongStore.last_error == "bad_song", "rejected installs leave no folder; last_error set")
	# a real one-byte change of the audio after the manifest was made
	var good := _song()
	var au := _audio(700)
	good["audio"]["sha256"] = SongStore.sha256_hex(au)
	au[10] = au[10] ^ 1
	ok(SongStore.install(good, au)["err_code"] == "sha_mismatch", "one changed byte -> sha_mismatch")


func _test_quota() -> void:
	print("[quota]")
	_fresh()
	var okc: int = 0
	for i in 40:
		if SongStore.install(_song("Song %d" % i), _audio(64, i))["ok"]:
			okc += 1
	ok(okc == 40 and SongStore.usage()["songs"] == 40, "40 songs installed")
	var before: Array = _dirs(ROOT)
	var r: Dictionary = SongStore.install(_song("Song 41"), _audio(64, 99))
	ok(r["ok"] == false and r["err_code"] == "quota_songs", "41st song -> quota_songs")
	ok(_dirs(ROOT) == before, "41st song: no partial folder")
	_fresh()
	SongStore.fake_used_bytes = SongStore.MAX_BYTES - 50
	var r2: Dictionary = SongStore.install(_song(), _audio(100))
	ok(r2["ok"] == false and r2["err_code"] == "quota_bytes", "over 400 MiB -> quota_bytes")
	ok(_dirs(ROOT).is_empty(), "quota_bytes: no partial folder")
	SongStore.fake_used_bytes = SongStore.MAX_BYTES - 100
	ok(SongStore.install(_song(), _audio(100))["ok"] == true, "exactly at the limit is accepted")
	ok(SongStore.usage()["bytes"] > SongStore.MAX_BYTES - 100, "usage includes the fake used bytes")
	SongStore.fake_used_bytes = 0


func _test_write_failures() -> void:
	print("[write failures]")
	_fresh()
	SongStore.write_hook = func(path: String) -> bool: return not path.ends_with("song.json")
	var r: Dictionary = _install("Fail A")
	ok(r["ok"] == false and r["err_code"] == "disk_write", "song.json write fails -> disk_write")
	ok(_dirs(ROOT).is_empty(), "failed install leaves no folder (no staging, no half song)")
	SongStore.write_hook = func(path: String) -> bool: return not path.ends_with("audio.mp3")
	var r2: Dictionary = _install("Fail B")
	ok(r2["ok"] == false and r2["err_code"] == "disk_write" and _dirs(ROOT).is_empty(), "audio write fails -> disk_write, no folder")
	SongStore.write_hook = Callable()
	ok(_install("Fine")["ok"] == true, "after the failures an install works again")
	# a stale staging folder from a crash is cleaned by the next install
	DirAccess.make_dir_recursive_absolute(_g(ROOT + "/_tmp_s_aaaaaaaaaaaa"))
	_write(ROOT + "/_tmp_s_aaaaaaaaaaaa/audio.mp3", "junk")
	ok(_install("Next")["ok"] == true and not _has_staging(), "stale staging folder removed by the next install")
	ok(SongStore.list().size() == 2, "staging folders never show in the list")


func _test_broken_json() -> void:
	print("[broken song.json]")
	_fresh()
	var ida: String = _install("Keep A")["id"]
	var idb: String = _install("Broken B", 800)["id"]
	var idc: String = _install("Keep C")["id"]
	var pb: String = ROOT + "/" + idb + "/song.json"
	var full: String = _read(pb)
	_write(pb, full.substr(0, full.length() / 2))
	var l: Array = SongStore.list()
	ok(l.size() == 2, "cut JSON: song left out of the list")
	var titles: Array = []
	for e in l:
		titles.append(e["title"])
	titles.sort()
	ok(titles == ["Keep A", "Keep C"], "the other songs are fine")
	ok(FileAccess.file_exists(pb + ".bad") and not FileAccess.file_exists(pb), "broken file moved to song.json.bad")
	ok(SongStore.take_quarantined() == [idb] and SongStore.take_quarantined().is_empty(), "take_quarantined reports once")
	ok(SongStore.load_song(idb).is_empty(), "load_song of the broken song -> {}")
	ok(SongStore.orphan_ids() == [idb] and SongStore.usage()["songs"] == 2 and SongStore.usage()["bytes"] >= 800, "orphan folder reported; usage still counts its bytes")
	ok(SongStore.delete(idb) and SongStore.orphan_ids().is_empty() and not DirAccess.dir_exists_absolute(_g(ROOT + "/" + idb)), "delete clears the orphan folder")
	# not an object / empty / NUL bytes
	for bad in ["[1, 2, 3]", "", "\"just a string\"", "{\"v\": 1, \"lines\": [", "null"]:
		_write(ROOT + "/" + ida + "/song.json", bad)
		ok(SongStore.load_song(ida).is_empty() and SongStore.last_error == "bad_json", "load_song of `%s` -> {} / bad_json" % bad.left(12))
		ok(FileAccess.file_exists(ROOT + "/" + ida + "/song.json.bad") and not FileAccess.file_exists(ROOT + "/" + ida + "/song.json"), "  ... moved to .bad")
	var fnul := FileAccess.open(ROOT + "/" + ida + "/song.json", FileAccess.WRITE)
	fnul.store_buffer(PackedByteArray([0x7b, 0x00, 0x00, 0x7d]))
	fnul.close()
	ok(SongStore.list().size() == 1, "NUL bytes in song.json: no crash, song left out")
	# at most 3 .bad files are kept
	for n in 6:
		_write(ROOT + "/" + ida + "/song.json", "{broken %d" % n)
		SongStore.load_song(ida)
	var bads: int = 0
	for fn in _files(ROOT + "/" + ida):
		if fn.begins_with("song.json.bad"):
			bads += 1
	ok(bads == 3, "at most 3 .bad files kept (%d)" % bads)
	ok(SongStore.load_song(idc)["title"] == "Keep C", "other song still loads")
	# a huge song.json is treated as broken without loading it all
	var big := FileAccess.open(ROOT + "/" + idc + "/song.json", FileAccess.WRITE)
	big.store_buffer(PackedByteArray([0x20]).duplicate())
	big.seek(SongStore.MAX_JSON_BYTES + 10)
	big.store_8(0x20)
	big.close()
	ok(SongStore.load_song(idc).is_empty() and SongStore.last_error == "bad_json", "song.json over the size cap is not loaded")


func _test_audio_checks() -> void:
	print("[audio checks]")
	_fresh()
	var id: String = _install("Audio A", 1200)["id"]
	var ap: String = SongStore.audio_path(id)
	ok(SongStore.list()[0]["ready"] == true and SongStore.verify_audio(id), "intact audio: ready / verify")
	# same size, one byte changed
	var data := FileAccess.get_file_as_bytes(ap)
	data[5] = data[5] ^ 0xff
	var f := FileAccess.open(ap, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	SongStore.clear_cache()
	ok(SongStore.list()[0]["ready"] == false and SongStore.verify_audio(id) == false, "changed byte (same size): ready false")
	ok(SongStore.list().size() == 1, "  ... but still listed")
	# truncated
	var f2 := FileAccess.open(ap, FileAccess.WRITE)
	f2.store_buffer(data.slice(0, 600))
	f2.close()
	SongStore.clear_cache()
	ok(SongStore.list()[0]["ready"] == false, "truncated audio: ready false")
	# missing
	DirAccess.remove_absolute(_g(ap))
	var l: Array = SongStore.list()
	ok(l.size() == 1 and l[0]["ready"] == false and SongStore.verify_audio(id) == false, "missing audio file: listed with ready false")
	ok(SongStore.load_song(id)["title"] == "Audio A", "song data of a song without audio still loads")


func _test_atomic_save() -> void:
	print("[atomic save]")
	_fresh()
	var id: String = _install("Atomic")["id"]
	var path: String = ROOT + "/" + id + "/song.json"
	var good: String = _read(path)
	# a leftover half-written temp file does not affect reading
	_write(path + ".tmp", good.substr(0, 20))
	ok(SongStore.load_song(id)["title"] == "Atomic" and _read(path) == good, "temp file next to song.json is ignored when reading")
	var s: Dictionary = SongStore.load_song(id)
	s["title"] = "Renamed"
	ok(SongStore.save_song(s) == true and SongStore.load_song(id)["title"] == "Renamed", "save_song writes the new title")
	ok(not FileAccess.file_exists(path + ".tmp"), "no .tmp left after a save")
	# a write that dies half way keeps the old file
	var keep: String = _read(path)
	SongStore.write_hook = func(tmp: String) -> bool:
		_write(tmp, "{\"v\":1,\"title\":\"HALF")
		return false
	s["title"] = "Never Saved"
	ok(SongStore.save_song(s) == false and SongStore.last_error == "disk_write", "failed write -> false / disk_write")
	ok(_read(path) == keep and SongStore.load_song(id)["title"] == "Renamed", "failed write: the previous song.json is intact")
	ok(not FileAccess.file_exists(path + ".tmp"), "failed write: temp file cleaned")
	SongStore.write_hook = Callable()
	ok(SongStore.save_song({"id": "s_0000000000ff", "title": "x"}) == false, "save_song of a song with no folder -> false")
	ok(SongStore.save_song({"title": "no id"}) == false and SongStore.last_error == "bad_song", "save_song without an id -> false")
	var s2: Dictionary = SongStore.load_song(id)
	s2["lines"][0]["t0"] = -4.0
	s2["offset"] = 99.0
	SongStore.save_song(s2)
	var s3: Dictionary = SongStore.load_song(id)
	ok(float(s3["lines"][0]["t0"]) == 0.0 and float(s3["offset"]) == 5.0, "save_song normalizes before writing")


func _test_read_only() -> void:
	print("[read only (v > 1)]")
	_fresh()
	var id: String = _install("RO")["id"]
	var path: String = ROOT + "/" + id + "/song.json"
	var raw: Dictionary = JSON.parse_string(_read(path))
	raw["v"] = 2
	raw["future"] = {"x": 1}
	_write(path, JSON.stringify(raw))
	var s: Dictionary = SongStore.load_song(id)
	ok(s["v"] == 2 and s["future"]["x"] == 1 and SongModel.is_read_only(s), "v:2 song opens, unknown key kept")
	var before: String = _read(path)
	s["title"] = "Edited"
	ok(SongStore.save_song(s) == false and SongStore.last_error == "read_only", "save_song of a v:2 song -> false")
	ok(_read(path) == before, "v:2 song.json untouched")
	ok(SongStore.list()[0]["read_only"] == true, "list marks it read_only")


func _test_pending() -> void:
	print("[pending]")
	_fresh()
	ok(SongStore.pending_list().is_empty(), "no file: empty pending list")
	for i in 6:
		SongStore.pending_put({"job": "j_%08x" % i, "upload_id": "a".repeat(32), "lang": "en", "title": "T%d" % i, "t": 1000 + i})
	var l: Array = SongStore.pending_list()
	ok(l.size() == 5, "6th record: still 5")
	var jobs: Array = []
	for r in l:
		jobs.append(r["job"])
	ok(not jobs.has("j_00000000") and jobs.has("j_00000005"), "the oldest record was dropped")
	SongStore.pending_put({"job": "j_00000003", "upload_id": "b".repeat(32), "lang": "ja", "title": "again", "t": 5000})
	l = SongStore.pending_list()
	var n3: int = 0
	for r in l:
		if r["job"] == "j_00000003":
			n3 += 1
			ok(r["lang"] == "ja" and r["title"] == "again", "same job replaced, not duplicated")
	ok(n3 == 1 and l.size() == 5, "one record per job")
	ok(SongStore.pending_remove("j_00000003") and SongStore.pending_list().size() == 4, "pending_remove")
	ok(SongStore.pending_remove("j_nothing") and SongStore.pending_list().size() == 4, "removing an unknown job is harmless")
	ok(SongStore.pending_put({"job": "../evil", "t": 1}) == false and SongStore.pending_put({"title": "no job"}) == false, "records with a bad / missing job are refused")
	var c: Array = SongStore.pending_list()
	ok(c[0].keys().size() == 5 and c[0].has("job") and c[0].has("upload_id") and c[0].has("lang") and c[0].has("title") and c[0].has("t"), "records hold job / upload_id / lang / title / t")
	_write(ROOT + "/_pending.json", "{not json")
	ok(SongStore.pending_list().is_empty(), "broken _pending.json is ignored")
	ok(SongStore.pending_put({"job": "j_new", "t": 9}) and SongStore.pending_list().size() == 1, "a put after a broken file writes a fresh one")
	_write(ROOT + "/_pending.json", "{\"a\": 1}")
	ok(SongStore.pending_list().is_empty(), "_pending.json that is not an array is ignored")
	_write(ROOT + "/_pending.json", JSON.stringify([5, "x", {"job": "ok_1", "t": 3}, {"job": "bad job!"}]))
	ok(SongStore.pending_list().size() == 1, "bad entries inside the array are skipped")
	ok(SongStore.list().is_empty() and _dirs(ROOT).is_empty(), "_pending.json is not a song")


func _test_order_and_lookup() -> void:
	print("[order and lookup]")
	_fresh()
	var a: String = _install("Old", 100, 1000, 0)["id"]
	var b: String = _install("Recent play", 100, 900, 5000)["id"]
	var c: String = _install("New", 100, 3000, 0)["id"]
	var l: Array = SongStore.list()
	ok(l[0]["id"] == b and l[1]["id"] == c and l[2]["id"] == a, "list sorted by last played / created, newest first")
	var ja := _song("日本の歌")
	ja["lang"] = "ja"
	ja["lines"] = [{"i": 0, "p": 0, "t0": 1.0, "t1": 3.0, "text": "  Hello   WORLD ", "words": []}]
	SongStore.install(ja, _audio(50, 9))
	var r: Dictionary = SongStore.find_line_by_text("en", MARK.to_lower())
	ok(r.has("song_id") and r["line_index"] == 1, "find_line_by_text finds the line (case ignored)")
	ok(SongStore.find_line_by_text("ja", "hello world").has("song_id"), "  ... spaces collapsed, language matched")
	ok(SongStore.find_line_by_text("en", "hello world").is_empty() and SongStore.find_line_by_text("en", "").is_empty(), "wrong language / empty text -> {}")
	ok(SongStore.find_line_by_text("en", "no such line anywhere").is_empty(), "no match -> {}")


func _test_delete() -> void:
	print("[delete]")
	_fresh()
	var id: String = _install("Del")["id"]
	var id2: String = _install("Stay")["id"]
	ok(SongStore.delete(id) and not DirAccess.dir_exists_absolute(_g(ROOT + "/" + id)), "delete removes the folder")
	ok(SongStore.list().size() == 1 and SongStore.list()[0]["id"] == id2, "the other song stays")
	ok(SongStore.delete(id) == true, "deleting it again is harmless")
	ok(SongStore.delete("../x") == false and SongStore.last_error == "bad_id", "delete of a bad id -> false")
	ok(SongStore.delete("") == false, "delete of an empty id -> false")


func _test_traversal() -> void:
	print("[path safety]")
	_fresh()
	var s := _song("Trav")
	s["id"] = "../../escape"
	s["audio"]["file"] = "../../evil.mp3"
	s["audio"]["orig_name"] = "..\\..\\evil.m4a"
	var r: Dictionary = SongStore.install(s, _audio(80))
	ok(r["ok"] and SongModel.is_valid_id(r["id"]), "a path-like id in the song is ignored (a new id is made)")
	var inst: Dictionary = SongStore.load_song(r["id"])
	ok(inst["audio"]["file"] == "audio.mp3" and inst["audio"]["orig_name"] == "evil.m4a", "audio file name fixed; orig_name keeps no path")
	ok(not FileAccess.file_exists("user://evil.mp3") and not FileAccess.file_exists("user://test_evil.mp3") and not DirAccess.dir_exists_absolute(_g("user://escape")), "nothing written outside the root")
	ok(SongStore.pending_put({"job": "a/b", "t": 1}) == false and SongStore.pending_put({"job": "..", "t": 1}) == false, "pending jobs with path characters refused")


func _test_guard() -> void:
	print("[test guard on the real folder]")
	var saved: String = SongStore.root
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	SongStore.root = SongStore.ROOT
	ok(SongStore.blocked() == true, "default root is blocked while testing")
	ok(SongStore.list().is_empty() and SongStore.last_error == "test_guard", "list on the real root -> empty / test_guard")
	ok(SongStore.install(_song(), _audio(10))["ok"] == false, "install on the real root refused")
	ok(SongStore.pending_put({"job": "j_1", "t": 1}) == false and SongStore.delete("s_0123456789ab") == false, "pending_put / delete on the real root refused")
	ok(SongStore.load_song("s_0123456789ab").is_empty(), "load_song on the real root refused")
	SongStore.root = "user://songs/"
	ok(SongStore.blocked() == true, "trailing slash does not get around it")
	SongStore.root = "user://songs/../songs"
	ok(SongStore.blocked() == true, "../ does not get around it")
	SongStore.root = ROOT
	ok(SongStore.blocked() == false, "a user://test_* root is allowed")
	SongStore.root = "user://songs_other"
	ok(SongStore.blocked() == false, "user://songs_other is a different folder")
	SongStore.root = saved
