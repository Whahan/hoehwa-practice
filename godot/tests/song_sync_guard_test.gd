extends Node
## 노래 공부 G2: 곡 데이터(가사·음원·song.json)는 동기화·백업에 들어가지 않는다는 것을 확인한다 (설계 §2 L3, D10).
##   godot --headless --path <project> res://tests/song_sync_guard_test.tscn
## Exit code 0 = all passed. Last line: "== song_sync_guard_test result: N passed, 0 failed =="
##
## 근거 두 갈래:
##   (1) 코드 경로: scripts/sync/*.gd 어디에도 song 이 없다. 동기화가 읽는 파일은 SyncPorts.live().local_paths 의
##       progress / studylog / prefs 세 개뿐이고, SyncBackup 은 그 세 파일(+사이드카)만 복사한다. SongStore / SongModel 은
##       Store·StudyLog·SyncDoc·prefs 파일 이름을 코드에서 쓰지 않는다. 내보내기 설정은 폰 자동 백업을 끈다.
##   (2) 실행: 가사 표식(ZZSONGLINEZZ)이 든 곡을 실제로 저장하고, song_* 설정·곡 데이터가 든 로컬 상태에서
##       SyncDoc.extract / to_base / norm_replica 결과와 SyncBackup.create 결과 폴더를 뒤져 표식 0건을 확인한다.
##       검사기가 정말 잡아내는지 일부러 표식을 넣은 입력으로도 확인한다.
## 저장은 user://test_songs_sync* 에만 한다.

const MARK := "ZZSONGLINEZZ"
const ROOT := "user://test_songs_sync"
const FILES := "user://test_songs_sync_files"
const BK := "user://test_songs_sync_bk"

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _g(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(_g(path))
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(_g(path).path_join(fn))
	DirAccess.remove_absolute(_g(path))


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


## True when `text` contains the lyric marker or any song-ish key.
func leaks(text: String) -> bool:
	var low: String = text.to_lower()
	return text.contains(MARK) or low.contains("song") or low.contains("lyric")


## All files under a folder: relative path -> text.
func _tree(path: String, rel: String = "") -> Dictionary:
	var out := {}
	var d := DirAccess.open(_g(path))
	if d == null:
		return out
	for fn in d.get_files():
		out[rel + fn] = _read(path.path_join(fn))
	for sub in d.get_directories():
		out.merge(_tree(path.path_join(sub), rel + sub + "/"))
		out[rel + sub + "/"] = ""
	return out


func _sync_sources() -> Dictionary:
	var out := {}
	var d := DirAccess.open("res://scripts/sync")
	if d == null:
		return out
	for fn in d.get_files():
		if fn.ends_with(".gd"):
			out[fn] = _read("res://scripts/sync/" + fn)
	return out


func _code_only(src: String) -> String:
	var lines: PackedStringArray = []
	for ln in src.split("\n"):
		var t: String = ln.strip_edges()
		if t.begins_with("#"):
			continue
		lines.append(ln)
	return "\n".join(lines)


func _ready() -> void:
	print("== song_sync_guard_test start ==")
	for p in [ROOT, FILES, BK]:
		_rm_rf(p)
	var old_root: String = SongStore.root
	SongStore.root = ROOT
	var old_prefs: Dictionary = Store.prefs.duplicate(true)

	_test_code_paths()
	_test_extract_and_replica()
	_test_backup()
	_test_detector_catches_leaks()

	Store.prefs = old_prefs
	SongStore.root = old_root
	for p in [ROOT, FILES, BK]:
		_rm_rf(p)
	ok(true, "ran to the end of every section")
	print("== song_sync_guard_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- (1) code paths

func _test_code_paths() -> void:
	print("[code paths]")
	var src: Dictionary = _sync_sources()
	ok(src.size() >= 8, "read the sync sources (%d files)" % src.size())
	var bad: Array = []
	for fn in src.keys():
		var low: String = String(src[fn]).to_lower()
		if low.contains("song") or low.contains("lrc") or low.contains("lyric"):
			bad.append(fn)
	ok(bad.is_empty(), "no scripts/sync/*.gd mentions songs / lyrics / lrc %s" % [bad])
	var keys: Array = SyncDoc.SHARED_PREFS.keys()
	var pref_bad: Array = []
	for k in keys:
		if String(k).begins_with("song"):
			pref_bad.append(k)
	ok(pref_bad.is_empty() and not SyncDoc.SHARED_PREFS.has("song_consent"), "SyncDoc.SHARED_PREFS has no song_* key (%d keys)" % keys.size())
	ok(not leaks(JSON.stringify(SyncDoc.blank_view())) and not leaks(JSON.stringify(SyncDoc.blank_replica())), "blank view / replica documents have no song keys")
	ok(SyncDoc._REPLICA_TOP == ["v", "progress", "studylog", "prefs"], "replica document top-level keys: v / progress / studylog / prefs only")
	var ports: SyncPorts = SyncPorts.live()
	var lp: Dictionary = ports.local_paths.call()
	var lk: Array = lp.keys()
	lk.sort()
	ok(lk == ["progress", "prefs", "studylog"].duplicate() or lk == ["prefs", "progress", "studylog"], "SyncPorts.live().local_paths covers progress / prefs / studylog only")
	var ll: Dictionary = ports.load_local.call()
	var llk: Array = ll.keys()
	llk.sort()
	ok(llk == ["prefs", "progress", "studylog"], "SyncPorts.live().load_local returns progress / prefs / studylog only")
	var fnames: Array = SyncBackup.FILE_NAMES.values()
	fnames.sort()
	ok(fnames == ["progress.json", "prefs.json", "studylog.json"].duplicate() or fnames == ["prefs.json", "progress.json", "studylog.json"], "SyncBackup copies only the three app files")
	var under: bool = false
	for p in lp.values():
		if String(p).begins_with("user://songs") or String(p).begins_with(SongStore.ROOT):
			under = true
	ok(not under, "none of the synced / backed-up file paths is inside the songs folder")
	# SongStore / SongModel do not touch the sync-related files or classes
	var mine := {"song_store.gd": _read("res://scripts/local/song_store.gd"), "song_model.gd": _read("res://scripts/core/song_model.gd")}
	var rx := RegEx.new()
	rx.compile("Store\\.|StudyLog|SyncDoc|SyncPorts|SyncBackup|SyncEngine|SyncManager|prefs\\.json|progress\\.json|studylog\\.json|sync_state")
	var hits: Array = []
	for fn in mine.keys():
		ok(String(mine[fn]).length() > 1000, "read %s" % fn)
		for m in rx.search_all(_code_only(String(mine[fn]))):
			var s: String = m.get_string()
			if s != "Store.": ## "SongStore." is the class itself
				hits.append(fn + ":" + s)
			elif not _is_songstore(_code_only(String(mine[fn])), m.get_start()):
				hits.append(fn + ":" + s)
	ok(hits.is_empty(), "song_store.gd / song_model.gd code never names Store / StudyLog / Sync* / prefs / progress files %s" % [hits])
	# export setting: no automatic phone backup
	var cfg: String = _read("res://export_presets.cfg")
	var n_allow_false: int = cfg.count("user_data_backup/allow=false")
	var n_presets: int = cfg.count("[preset.") - cfg.count(".options]")
	ok(cfg != "" and n_allow_false >= 1 and cfg.count("user_data_backup/allow=true") == 0, "export_presets.cfg: user_data_backup/allow=false (%d), never true" % n_allow_false)
	ok(n_presets >= 1, "export presets found (%d)" % n_presets)
	# prefs written by the sync apply path ignore song_* keys
	var saved_path: String = Store.prefs_path
	Store.prefs_path = FILES.path_join("prefs.json")
	DirAccess.make_dir_recursive_absolute(_g(FILES))
	var res: bool = Store.apply_sync_prefs({"song_speed": 0.5, "song_consent": true, "songs": [MARK]})
	Store.prefs_path = saved_path
	ok(res and not Store.prefs.has("song_speed") and not Store.prefs.has("song_consent") and not Store.prefs.has("songs"), "Store.apply_sync_prefs drops song_* keys from a merge result")
	ok(not FileAccess.file_exists(FILES.path_join("prefs.json")), "  ... and writes nothing for them")


func _is_songstore(code: String, at: int) -> bool:
	return at >= 4 and code.substr(at - 4, 4) == "Song"


# ---------------------------------------------------------------- (2) extract / replica

func _local_with_song_data() -> Dictionary:
	var l: Dictionary = SyncPorts.live().load_local.call()
	var prefs: Dictionary = (l["prefs"] as Dictionary).duplicate(true)
	prefs["song_speed"] = 0.5
	prefs["song_consent"] = true
	prefs["song_last_tab"] = MARK
	prefs["songs"] = [{"text": MARK}]
	var prog: Dictionary = (l["progress"] as Dictionary).duplicate(true)
	prog["songs"] = [{"text": MARK}]
	prog["song_marks"] = {"lines": [1], "text": MARK}
	var sl: Dictionary = (l["studylog"] as Dictionary).duplicate(true)
	sl["songs"] = {"lyrics": MARK}
	return {"progress": prog, "studylog": sl, "prefs": prefs}


func _test_extract_and_replica() -> void:
	print("[SyncDoc with song data in the local state]")
	# a real song with the marker is on disk
	var inst: Dictionary = SongStore.install({"v": 1, "lang": "en", "title": "Sync Guard", "duration": 20.0,
		"lines": [{"i": 0, "t0": 1.0, "t1": 3.0, "text": MARK, "words": []}]}, PackedByteArray([1, 2, 3, 4, 5]))
	ok(inst["ok"] == true, "a song with the marker line is installed")
	var sj: String = _read(ROOT + "/" + str(inst["id"]) + "/song.json")
	ok(sj.contains(MARK), "control: the marker really is in song.json on disk")
	var loc: Dictionary = _local_with_song_data()
	ok(JSON.stringify(loc).contains(MARK), "control: the local state handed to the sync code carries the marker (progress / studylog / prefs)")
	var view: Dictionary = SyncDoc.extract(loc["progress"], loc["studylog"], loc["prefs"], 0)
	var vtxt: String = JSON.stringify(view)
	ok(not leaks(vtxt), "SyncDoc.extract result has no marker / song key (%d bytes)" % vtxt.length())
	ok(not leaks(JSON.stringify(SyncDoc.norm_view(view))) and not leaks(JSON.stringify(SyncDoc.to_base(view))), "norm_view / to_base results have none either")
	var back: Dictionary = SyncDoc.to_local(view, 0, loc["progress"], loc["studylog"], loc["prefs"])
	var pc: Dictionary = back["prefs_changes"]
	var pc_bad: Array = []
	for k in pc.keys():
		if not SyncDoc.SHARED_PREFS.has(k):
			pc_bad.append(k)
	ok(pc_bad.is_empty() and not leaks(JSON.stringify(pc)), "to_local prefs_changes only holds shared keys")
	# a replica (what goes to the hub) built from this
	var rep: Dictionary = SyncDoc.blank_replica()
	rep["songs"] = [{"text": MARK}]
	rep["prefs"]["song_speed"] = {"value": 0.5, "t": 1}
	ok(SyncDoc.validate_replica(rep).size() > 0, "validate_replica refuses a document with a songs key")
	var nr: Dictionary = SyncDoc.norm_replica(rep, 4102444800, {})
	ok(not leaks(JSON.stringify(nr)), "norm_replica drops songs / song_* keys")
	var nr2: Dictionary = SyncDoc.norm_replica(rep, 4102444800, {})
	ok(JSON.stringify(nr) == JSON.stringify(nr2), "  ... deterministically")


# ---------------------------------------------------------------- (3) backup

func _test_backup() -> void:
	print("[SyncBackup with song data on disk]")
	var loc: Dictionary = _local_with_song_data()
	DirAccess.make_dir_recursive_absolute(_g(FILES))
	_write(FILES.path_join("progress.json"), JSON.stringify(Store.progress))
	_write(FILES.path_join("studylog.json"), JSON.stringify(StudyLog.snapshot()))
	_write(FILES.path_join("prefs.json"), JSON.stringify(Store.prefs))
	_write(FILES.path_join("sync_state.json"), "{}")
	var paths := {"progress": FILES.path_join("progress.json"), "studylog": FILES.path_join("studylog.json"), "prefs": FILES.path_join("prefs.json")}
	var r: Dictionary = SyncBackup.create(BK, "auto", 1790000000, paths, FILES.path_join("sync_state.json"))
	ok(r["ok"] == true, "SyncBackup.create ok")
	var tree: Dictionary = _tree(BK)
	var names: Array = tree.keys()
	names.sort()
	var allowed := ["prefs.json", "progress.json", "studylog.json", "sync_state.json", "meta.json"]
	var stray: Array = []
	var leaked: Array = []
	for n in names:
		var file: String = String(n).get_file()
		if String(n).ends_with("/"):
			if String(n) != str(r["name"]) + "/": ## the one backup folder itself is expected
				stray.append(n)
			continue
		if not allowed.has(file):
			stray.append(n)
		if leaks(String(tree[n])):
			leaked.append(n)
	ok(stray.is_empty() and names.size() >= 5, "backup folder holds only the app files + meta.json inside the one backup folder (%d entries) %s" % [names.size(), stray])
	ok(leaked.is_empty(), "no backup file mentions songs / lyrics / the marker %s" % [leaked])
	# the song folder really exists next to it and is not part of the backup
	ok(DirAccess.dir_exists_absolute(_g(ROOT)) and not tree.has("songs/"), "the songs folder exists but is not in the backup")
	ok(loc["prefs"]["song_last_tab"] == MARK, "control: song_* prefs were in the local state when the backup ran")


# ---------------------------------------------------------------- (4) the detector itself

func _test_detector_catches_leaks() -> void:
	print("[the checks fail on wrong input]")
	# a review card with the marker in its note goes through sync by design -> the detector must see it
	var prog: Dictionary = Progress.blank()
	prog["review"] = [{"lang": "en", "target": "hello", "reading": "", "ko": "안녕", "note": "♪ " + MARK, "due": 1, "stability": 1.0,
		"difficulty": 5.0, "state": 1, "step": 0, "last_review": 1, "reps": 1, "lapses": 0}]
	var v: Dictionary = SyncDoc.extract(prog, {}, {}, 0)
	ok(leaks(JSON.stringify(v)), "a marker inside a card note IS found by the leak check (so the check can fail)")
	ok(leaks("{\"songs\": []}") and leaks("{\"lyrics\": 1}") and not leaks("{\"cards\": []}"), "leak check: song / lyric keys found, plain keys not")
	# a fake backup folder with a songs dir is flagged
	_rm_rf(BK + "_bad")
	DirAccess.make_dir_recursive_absolute(_g(BK + "_bad/songs/s_aaaaaaaaaaaa"))
	_write(BK + "_bad/songs/s_aaaaaaaaaaaa/song.json", "{\"t\": \"" + MARK + "\"}")
	_write(BK + "_bad/progress.json", "{}")
	var t: Dictionary = _tree(BK + "_bad")
	var flagged: bool = false
	for n in t.keys():
		if not ["prefs.json", "progress.json", "studylog.json", "sync_state.json", "meta.json"].has(String(n).get_file()) or leaks(String(t[n])):
			flagged = true
	ok(flagged, "a backup folder with a songs/ directory is flagged by the folder check")
	_rm_rf(BK + "_bad")
	# the source scan flags a sync script that mentions songs
	var fake := "func f():\n\tSongStore.list()\n"
	ok(fake.to_lower().contains("song"), "the source scan would flag a sync script that calls SongStore")
	# and the code check on song_store flags a Store call
	var rx := RegEx.new()
	rx.compile("StudyLog|SyncDoc|prefs\\.json")
	ok(rx.search(_code_only("var x = StudyLog.snapshot()")) != null and rx.search(_code_only("## StudyLog in a comment")) == null, "the code-only scan sees code, ignores comments")
