extends Node
## 가사 외우기 M2: SongModel(kind) · SongStore(install_lyrics / memo 입출력 / list kind). 서버·마이크를 쓰지 않는다.
##   godot --headless --path <project> res://tests/song_lyrics_store_test.tscn
## Exit code 0 = all passed. Last line: "== song_lyrics_store_test result: N passed, 0 failed =="
## 저장은 user://test_songs_lyrics 에만 한다 (SongStore.root 를 바꿔서). 기본 user://songs 와 prefs / progress 파일은 시험
## 전후 목록(이름·크기)을 비교해서 건드리지 않았음을 확인한다. 오디오는 가짜 바이트이고 가사는 직접 쓴 문장이다.

const ROOT := "user://test_songs_lyrics"
const OUT := "user://test_songs_lyrics_outside"
const BK := "user://test_songs_lyrics_bk"
const MARK := "ZZSONGLINEZZ"
const NOW := 1790000000
const DAY := 86400

## 변경 전 코드(main 7926a70)로 만든 정규화 결과 (tests: M2-2). kind 가 없는 곡은 한 바이트도 달라지면 안 된다.
## RAW 가 입력 JSON, EXP 가 JSON.stringify(SongModel.normalize(parse(RAW))) 의 변경 전 결과이다.
const GOLDEN_RAW := [
	"""{"v":1,"id":"s_3fa9c1d20b7e","lang":"en","title":"Test Song","artist":"Tester","created":1790000000,"duration":60.0,"audio":{"file":"audio.mp3","bytes":100,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","orig_name":"x.m4a"},"source":{"lyrics":"pasted","lrclib_id":null,"timing":"line","attribution":""},"offset":0.0,"lines":[{"i":0,"p":0,"t0":1.0,"t1":3.0,"text":"The sky is blue today","reading":"","pron":"","ko":"","conf":0.8,"est":false,"stale":false,"words":[{"w":"blue","lemma":"blue","level":"easy","zipf":5.1,"s":1.0,"e":3.0,"est":false,"content":true}]},{"i":1,"p":1,"t0":4.0,"t1":6.0,"text":"I walk to the sea","reading":"","pron":"","ko":"x","conf":null,"est":true,"stale":false,"words":[]}],"glossary":{"blue":{"pos":"adj","ko":"b","ipa":"bluː","pron":""}},"marks":{"lines":[1],"words":["blue"]},"stats":{"plays":2,"last":1790000500,"best":{"1":88}},"warnings":["low_match"],"app":"1.4.0"}""",
	"""{"title":"Messy","lang":"fr","created":-5,"duration":0,"future":{"a":[1,2]},"_audio_path":"C:/x","lines":[{"text":"third","t0":9,"t1":9.01,"extra":7,"_z":1},{"text":"first","t0":-3,"t1":2,"words":[{"w":"a","s":5,"e":1,"level":"zzz","reading":"r"},5]},"junk",{"text":"second","t0":2,"t1":1,"conf":7}],"marks":{"lines":[0,1,2,3,9],"words":["a","a",3]},"stats":{"best":{"0":50,"2":99,"x":3},"plays":"no"},"offset":9,"warnings":["w","w"],"audio":{"file":"../evil.mp3","bytes":-4,"sha256":"XYZ","orig_name":"a/b/c.m4a"},"source":{"lyrics":"banana","timing":"x","lrclib_id":12.0}}""",
	"""{"v":1,"id":"s_0123456789ab","lang":"ja","title":"日本の歌","artist":"誰か","created":1790000100,"duration":12.5,"audio":{"file":"audio.mp3","bytes":10,"sha256":"","orig_name":""},"source":{"lyrics":"lrclib","lrclib_id":42,"timing":"est","attribution":"lrclib"},"offset":0.37,"lines":[{"i":0,"p":0,"t0":0.5,"t1":4.0,"text":"朝の光","reading":"あさのひかり","pron":"아사노","ko":"아침 빛","est":true,"words":[]}],"glossary":{},"marks":{"lines":[],"words":[]},"stats":{"plays":0,"last":0,"best":{}},"warnings":[],"app":""}""",
	"""{"lines":[{"text":"a"}]}""",
	"""{"v":3,"lang":"en","duration":5,"lines":[{"text":"x","t0":0,"t1":1}]}""",
]
const GOLDEN_EXP := [
	"""{"app":"1.4.0","artist":"Tester","audio":{"bytes":100,"file":"audio.mp3","orig_name":"x.m4a","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"created":1790000000,"duration":60.0,"glossary":{"blue":{"ipa":"bluː","ko":"b","pos":"adj","pron":""}},"id":"s_3fa9c1d20b7e","lang":"en","lines":[{"conf":0.8,"est":false,"i":0,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":1.0,"t1":3.0,"text":"The sky is blue today","words":[{"content":true,"e":3.0,"est":false,"lemma":"blue","level":"easy","s":1.0,"w":"blue","zipf":5.1}]},{"conf":null,"est":true,"i":1,"ko":"x","p":1,"pron":"","reading":"","stale":false,"t0":4.0,"t1":6.0,"text":"I walk to the sea","words":[]}],"marks":{"lines":[1],"words":["blue"]},"offset":0.0,"source":{"attribution":"","lrclib_id":null,"lyrics":"pasted","timing":"line"},"stats":{"best":{"1":88},"last":1790000500,"plays":2},"title":"Test Song","v":1,"warnings":["low_match"]}""",
	"""{"app":"","artist":"","audio":{"bytes":0,"file":"evil.mp3","orig_name":"c.m4a","sha256":""},"created":0,"duration":9.01,"future":{"a":[1.0,2.0]},"glossary":{},"id":"","lang":"en","lines":[{"conf":null,"est":false,"i":0,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":0.0,"t1":2.0,"text":"first","words":[{"content":true,"e":5.0,"est":false,"lemma":"","level":"mid","reading":"r","s":5.0,"w":"a","zipf":0.0}]},{"conf":1.0,"est":false,"i":1,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":2.0,"t1":2.1,"text":"second","words":[]},{"conf":null,"est":false,"extra":7.0,"i":2,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":8.91,"t1":9.01,"text":"third","words":[]}],"marks":{"lines":[0,1,2],"words":["a"]},"offset":5.0,"source":{"attribution":"","lrclib_id":12,"lyrics":"pasted","timing":"line"},"stats":{"best":{"2":50},"last":0,"plays":0},"title":"Messy","v":1,"warnings":["w"]}""",
	"""{"app":"","artist":"誰か","audio":{"bytes":10,"file":"audio.mp3","orig_name":"","sha256":""},"created":1790000100,"duration":12.5,"glossary":{},"id":"s_0123456789ab","lang":"ja","lines":[{"conf":null,"est":true,"i":0,"ko":"아침 빛","p":0,"pron":"아사노","reading":"あさのひかり","stale":false,"t0":0.5,"t1":4.0,"text":"朝の光","words":[]}],"marks":{"lines":[],"words":[]},"offset":0.35,"source":{"attribution":"lrclib","lrclib_id":42,"lyrics":"lrclib","timing":"est"},"stats":{"best":{},"last":0,"plays":0},"title":"日本の歌","v":1,"warnings":[]}""",
	"""{"app":"","artist":"","audio":{"bytes":0,"file":"audio.mp3","orig_name":"","sha256":""},"created":0,"duration":0.1,"glossary":{},"id":"","lang":"en","lines":[{"conf":null,"est":false,"i":0,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":0.0,"t1":0.1,"text":"a","words":[]}],"marks":{"lines":[],"words":[]},"offset":0.0,"source":{"attribution":"","lrclib_id":null,"lyrics":"pasted","timing":"line"},"stats":{"best":{},"last":0,"plays":0},"title":"","v":1,"warnings":[]}""",
	"""{"app":"","artist":"","audio":{"bytes":0,"file":"audio.mp3","orig_name":"","sha256":""},"created":0,"duration":5.0,"glossary":{},"id":"","lang":"en","lines":[{"conf":null,"est":false,"i":0,"ko":"","p":0,"pron":"","reading":"","stale":false,"t0":0.0,"t1":1.0,"text":"x","words":[]}],"marks":{"lines":[],"words":[]},"offset":0.0,"source":{"attribution":"","lrclib_id":null,"lyrics":"pasted","timing":"line"},"stats":{"best":{},"last":0,"plays":0},"title":"","v":3,"warnings":[]}""",
]

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


func _audio_song(title: String = "Audio Song") -> Dictionary:
	return {"v": 1, "lang": "en", "title": title, "artist": "Tester", "created": 1790000000, "duration": 30.0,
		"audio": {"file": "audio.mp3", "bytes": 0, "sha256": "", "orig_name": "x.m4a"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"lines": [{"i": 0, "p": 0, "t0": 1.0, "t1": 3.0, "text": "The sky is blue today", "words": []},
			{"i": 1, "p": 0, "t0": 4.0, "t1": 6.0, "text": MARK, "words": []}],
		"glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": []}


func _fixture(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	var kept: PackedStringArray = []
	if f != null:
		for ln in f.get_as_text().split("\n"):
			if not ln.strip_edges().begins_with("#"):
				kept.append(ln)
		f.close()
	return LrcParser.split_plain("\n".join(kept))


func _lyrics_song(title: String = "Lyrics Song", lang: String = "en", fixture: String = "lyrics_en.txt") -> Dictionary:
	var lines: Array = []
	for e in _fixture("res://tests/fixtures/song/" + fixture):
		lines.append({"i": lines.size(), "p": e["p"], "t0": 0.0, "t1": 0.0, "text": e["text"], "reading": "", "pron": "", "ko": "",
			"conf": null, "est": true, "stale": false, "words": []})
	return {"v": 1, "kind": "lyrics", "lang": lang, "title": title, "artist": "Tester", "created": 1790000000, "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "none", "attribution": ""}, "offset": 0.0,
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [], "app": "1.4.0"}


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


func _is_link(path: String) -> bool:
	var d := DirAccess.open(_g(path).get_base_dir())
	return d != null and d.is_link(_g(path))


## Test cleanup: never follows a link (a left-over junction must not take a real folder with it).
func _rm_rf(path: String) -> void:
	if _is_link(path):
		DirAccess.remove_absolute(_g(path))
		return
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


func _fresh() -> void:
	SongStore.write_hook = Callable()
	SongStore.rename_fail = false
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = SongStore.MAX_SONGS
	SongStore.max_bytes = SongStore.MAX_BYTES
	SongStore.clear_cache()
	SongStore.take_quarantined()
	_rm_rf(ROOT)


func _card(due: int, state: int = 2) -> Dictionary:
	return {"due": due, "stability": 2.3, "difficulty": 5.1, "state": state, "step": 0, "last_review": NOW - DAY, "reps": 2, "lapses": 0}


func _memo_for(song: Dictionary, n: int) -> Dictionary:
	var m := MemoModel.new_memo()
	var ks: Array = MemoModel.keys_of(song)
	for i in mini(n, ks.size()):
		m["lines"][ks[i]["key"]] = {"stage": 8, "seen": NOW - 100 + i, "tries": 3, "passes": 2, "card": _card(NOW + (i + 1) * DAY, 2)}
	m["stats"] = {"sessions": 2, "last": NOW}
	return m


func _mklink(link: String, target: String) -> bool:
	var out := []
	var gl: String = _g(link)
	var gt: String = _g(target)
	var code: int = -1
	if OS.get_name() == "Windows":
		code = OS.execute("cmd", ["/c", "mklink", "/J", gl.replace("/", "\\"), gt.replace("/", "\\")], out, true)
	else:
		code = OS.execute("ln", ["-s", gt, gl], out, true)
	return code == 0 and _is_link(link)


## Makes sure `lk` is a directory link to OUT again (a save may have replaced it, a quarantine may have moved it).
func _relink(lk: String) -> void:
	if _is_link(lk):
		return
	if FileAccess.file_exists(lk):
		DirAccess.remove_absolute(_g(lk))
	elif DirAccess.dir_exists_absolute(_g(lk)):
		_rm_rf(lk)
	_mklink(lk, OUT)


func _outside_ok(files: Array) -> bool:
	for f in files:
		if not FileAccess.file_exists(f):
			return false
	return true


func _ready() -> void:
	print("== song_lyrics_store_test start ==")
	var old_root: String = SongStore.root
	_before = _user_listing()
	_rm_rf(OUT)
	_rm_rf(BK)
	SongStore.root = ROOT
	_fresh()

	_test_golden_audio()
	_test_lyrics_normalize()
	_test_install_lyrics()
	_test_install_rejects()
	_test_quota()
	_test_write_failures()
	_test_internal_keys()
	_test_memo_io()
	_test_memo_atomic()
	_test_memo_broken()
	_test_memo_summary()
	_test_delete()
	_test_not_synced()
	_test_links()
	_test_guard()

	_fresh()
	SongStore.root = old_root
	_rm_rf(OUT)
	_rm_rf(BK)
	var after: Dictionary = _user_listing()
	ok(JSON.stringify(after) == JSON.stringify(_before), "prefs / progress / studylog / remote / sync_state files and user://songs untouched: before == after")
	ok(after["songs_dir"] == _before["songs_dir"], "default user://songs was not created or removed by this test")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT)) and not DirAccess.dir_exists_absolute(_g(OUT)) and not DirAccess.dir_exists_absolute(_g(BK)), "test folders cleaned up")
	ok(true, "ran to the end of every section")
	print("== song_lyrics_store_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- SongModel

func _test_golden_audio() -> void:
	print("[songs without kind normalize exactly as before]")
	ok(GOLDEN_RAW.size() == GOLDEN_EXP.size() and GOLDEN_RAW.size() >= 5, "golden table: %d inputs" % GOLDEN_RAW.size())
	for i in GOLDEN_RAW.size():
		var js := JSON.new()
		var parsed: bool = js.parse(GOLDEN_RAW[i]) == OK
		var n: Dictionary = SongModel.normalize(js.data) if parsed else {}
		var text: String = JSON.stringify(n)
		ok(parsed and text == GOLDEN_EXP[i], "golden #%d: JSON.stringify(normalize(raw)) is byte for byte the old result" % i)
		ok(not n.has("kind"), "golden #%d: no \"kind\" key in the output" % i)
	# the control: the comparison really fails when one byte differs
	var js0 := JSON.new()
	js0.parse(GOLDEN_RAW[0])
	var doctored: Dictionary = SongModel.normalize(js0.data)
	doctored["title"] = "Test Song!"
	ok(JSON.stringify(doctored) != GOLDEN_EXP[0], "control: a one-character change is caught by the golden comparison")
	# a "none" timing on an audio song is repaired to "line" as before
	var a: Dictionary = SongModel.normalize({"lines": [{"text": "x", "t0": 0, "t1": 1}], "duration": 4, "source": {"timing": "none"}})
	ok(a["source"]["timing"] == "line" and not a.has("kind"), "audio song with source.timing none -> line (as before)")


func _test_lyrics_normalize() -> void:
	print("[kind lyrics]")
	ok(SongModel.KINDS == ["audio", "lyrics"] and SongModel.TIMINGS.has("none"), "KINDS and TIMINGS (with none) exist")
	var raw := {"kind": "lyrics", "v": 1, "id": "s_3fa9c1d20b7e", "lang": "ja", "title": "歌", "duration": 99.0, "offset": 3.0,
		"audio": {"file": "audio.mp3", "bytes": 10, "sha256": "a".repeat(64), "orig_name": "x.m4a"},
		"source": {"lyrics": "lrclib", "lrclib_id": 7, "timing": "line", "attribution": "from somewhere"},
		"lines": [{"text": "third", "t0": 9.0, "t1": 12.0}, {"text": "first", "t0": 1.0, "t1": 2.0, "words": [{"w": "a", "s": 3.0, "e": 4.0}]},
			{"text": "second", "t0": 5.0, "t1": 6.0}],
		"marks": {"lines": [0, 2], "words": []}, "stats": {"best": {"0": 40, "1": 50}}}
	var n: Dictionary = SongModel.normalize(raw)
	ok(n["kind"] == "lyrics" and SongModel.is_lyrics(n) and not SongModel.is_lyrics({}) and not SongModel.is_lyrics({"kind": "audio"}) and not SongModel.is_lyrics({"kind": 5}), "kind lyrics kept; is_lyrics")
	ok(n["duration"] == 0.0 and n["offset"] == 0.0, "duration 0 and offset 0 whatever the input says")
	var all_zero := true
	for ln in n["lines"]:
		if ln["t0"] != 0.0 or ln["t1"] != 0.0:
			all_zero = false
	ok(all_zero and n["lines"].size() == 3, "every line has t0 == t1 == 0")
	ok(n["lines"][0]["text"] == "third" and n["lines"][1]["text"] == "first" and n["lines"][2]["text"] == "second", "line order is the input order (not sorted by time)")
	ok(n["lines"][0]["i"] == 0 and n["lines"][2]["i"] == 2, "line numbers are 0..")
	ok(n["audio"] == {"file": "", "bytes": 0, "sha256": "", "orig_name": ""}, "audio is empty")
	ok(n["source"]["timing"] == "none" and n["source"]["lyrics"] == "lrclib" and n["source"]["lrclib_id"] == 7 and n["source"]["attribution"] == "from somewhere", "source.timing none; the rest kept")
	ok(n["marks"]["lines"] == [0, 2] and n["stats"]["best"] == {"0": 40, "1": 50}, "marks and best follow the (unchanged) line order")
	ok(n["lines"][1]["words"][0]["s"] == 0.0 and n["lines"][1]["words"][0]["e"] == 0.0, "word times are 0 as well")
	ok(JSON.stringify(SongModel.normalize(n)) == JSON.stringify(n), "normalizing again changes nothing")
	var b: Dictionary = SongModel.normalize({"kind": "banana", "lines": [{"text": "x", "t0": 0, "t1": 1}], "duration": 4})
	ok(not b.has("kind") and b["duration"] == 4.0 and b["audio"]["file"] == "audio.mp3" and b["source"]["timing"] == "line", "kind banana -> an audio song (no kind key)")
	var c: Dictionary = SongModel.normalize({"kind": "audio", "lines": [{"text": "x", "t0": 0, "t1": 1}], "duration": 4})
	var c2: Dictionary = SongModel.normalize({"kind": 7, "lines": [{"text": "x", "t0": 0, "t1": 1}], "duration": 4})
	ok(not c.has("kind") and not c2.has("kind"), "kind audio / a non-string kind -> no kind key")
	var v2: Dictionary = SongModel.normalize({"kind": "lyrics", "v": 2, "lines": [{"text": "x"}]})
	ok(v2["v"] == 2 and SongModel.is_read_only(v2) and v2["kind"] == "lyrics", "v:2 lyrics song is read-only")
	var many: Array = []
	for i in 450:
		many.append({"text": "line %d" % i})
	ok(SongModel.normalize({"kind": "lyrics", "lines": many})["lines"].size() == 400, "lyrics songs are cut at 400 lines like the others")
	var bad: Dictionary = SongModel.normalize({"kind": "lyrics", "lines": [{"text": "a", "t0": NAN, "t1": "x"}, 5, null, {"text": "b", "t0": INF}]})
	ok(bad["lines"].size() == 2 and bad["lines"][1]["t0"] == 0.0 and bad["duration"] == 0.0, "junk times / junk lines are handled")
	ok(SongModel.normalize({"kind": "lyrics"})["lines"].is_empty() and SongModel.normalize(5).is_empty(), "no lines -> empty lines; not a dictionary -> {}")
	var src: String = FileAccess.get_file_as_string("res://scripts/core/song_model.gd")
	ok(src.contains("0 <= t0 < t1 <= duration") and src.contains("음원 곡에만"), "the code says the t0 < t1 invariant applies to audio songs only")


# ---------------------------------------------------------------- install_lyrics

func _test_install_lyrics() -> void:
	print("[install_lyrics and list]")
	_fresh()
	var song := _lyrics_song()
	var r: Dictionary = SongStore.install_lyrics(song)
	ok(r["ok"] == true and SongModel.is_valid_id(r["id"]) and r["err_code"] == "", "install_lyrics ok")
	var id: String = r["id"]
	ok(_dirs(ROOT) == [id] and _files(ROOT + "/" + id) == ["song.json"], "the folder holds song.json only (no audio, no .tmp)")
	var l: Array = SongStore.list()
	ok(l.size() == 1 and l[0]["kind"] == "lyrics" and l[0]["ready"] == true and l[0]["duration"] == 0.0 and l[0]["lines"] == 6, "list entry: kind lyrics, ready, duration 0, 6 lines")
	ok(l[0]["id"] == id and l[0]["title"] == "Lyrics Song" and l[0]["read_only"] == false and l[0]["lang"] == "en", "list entry: id / title / lang / read_only")
	ok(SongStore.usage()["bytes"] < 20000 and SongStore.usage()["bytes"] > 100 and SongStore.usage()["songs"] == 1, "usage: under 20000 bytes (%d)" % SongStore.usage()["bytes"])
	ok(l[0]["bytes"] == SongStore.usage()["bytes"], "list bytes == the song.json size")
	var s: Dictionary = SongStore.load_song(id)
	var same := true
	for i in 6:
		if s["lines"][i]["text"] != song["lines"][i]["text"] or s["lines"][i]["p"] != song["lines"][i]["p"]:
			same = false
	ok(same and s["id"] == id and s["kind"] == "lyrics" and s["duration"] == 0.0, "load_song gives the same lines (text and stanza p)")
	ok(s["lines"][2]["p"] == 0 and s["lines"][3]["p"] == 1, "stanzas: the blank line of the file starts p 1")
	ok(SongStore.verify_audio(id) == true and SongStore.audio_path(id) == ROOT + "/" + id + "/audio.mp3" and not FileAccess.file_exists(SongStore.audio_path(id)), "verify_audio of a lyrics song is true; there is no audio file")
	ok(SongStore.orphan_ids().is_empty() and SongStore.take_quarantined().is_empty(), "a lyrics song is not an orphan")
	# the song can be saved again like any other
	s["title"] = "Renamed"
	s["lines"][0]["ko"] = "해석"
	ok(SongStore.save_song(s) and SongStore.load_song(id)["title"] == "Renamed" and SongStore.load_song(id)["kind"] == "lyrics" and SongStore.load_song(id)["lines"][0]["ko"] == "해석", "save_song keeps a lyrics song a lyrics song")
	# ja
	var rj: Dictionary = SongStore.install_lyrics(_lyrics_song("日本の歌", "ja", "lyrics_ja.txt"))
	var lj: Array = SongStore.list()
	var found := false
	for e in lj:
		if e["id"] == rj["id"]:
			found = e["lines"] == 5 and e["lang"] == "ja" and e["kind"] == "lyrics"
	ok(rj["ok"] and found, "a Japanese lyrics song (5 lines) installs and lists")
	# created = 0 -> now ; mixed with an audio song
	var s3 := _lyrics_song("No time")
	s3["created"] = 0
	var r3: Dictionary = SongStore.install_lyrics(s3)
	ok(r3["ok"] and int(SongStore.load_song(r3["id"])["created"]) > 0, "created = 0 -> filled with the current time")
	var ra: Dictionary = SongStore.install(_audio_song("With sound"), _audio(300))
	var la: Array = SongStore.list()
	var by_id := {}
	for e in la:
		by_id[e["id"]] = e
	ok(ra["ok"] and by_id[ra["id"]]["kind"] == "audio" and by_id[ra["id"]]["ready"] == true and by_id[id]["kind"] == "lyrics", "list: audio songs say kind audio (and stay ready), lyrics songs say lyrics")
	ok(la.size() == 4 and not _has_staging(), "four songs listed, no staging folders left")
	var raw_audio: Dictionary = by_id[ra["id"]]
	var keys: Array = raw_audio.keys()
	keys.sort()
	ok(keys == ["artist", "bytes", "created", "duration", "id", "kind", "lang", "last", "lines", "read_only", "ready", "title", "warnings"], "list entry keys: the old ones plus kind %s" % [keys])
	# audio-only checks do not apply: damaged audio of an audio song is still reported
	DirAccess.remove_absolute(_g(SongStore.audio_path(ra["id"])))
	SongStore.clear_cache()
	ok(SongStore.list().size() == 4 and SongStore.verify_audio(ra["id"]) == false and SongStore.verify_audio(id) == true, "a missing audio file still fails verify for an audio song, not for a lyrics song")


func _has_staging() -> bool:
	for d in _dirs(ROOT):
		if not SongModel.is_valid_id(d):
			return true
	return false


func _test_install_rejects() -> void:
	print("[install_lyrics rejects]")
	_fresh()
	var r0: Dictionary = SongStore.install_lyrics(_lyrics_song())
	var dirs0: Array = _dirs(ROOT)
	var nolines := _lyrics_song()
	nolines["lines"] = []
	var r: Dictionary = SongStore.install_lyrics(nolines)
	ok(r["ok"] == false and r["err_code"] == "bad_song" and r["id"] == "" and SongStore.last_error == "bad_song", "no lines -> bad_song")
	var audio_kind := _audio_song()
	ok(SongStore.install_lyrics(audio_kind)["err_code"] == "bad_song", "a song without kind lyrics (an audio song) -> bad_song")
	var banana := _lyrics_song()
	banana["kind"] = "banana"
	ok(SongStore.install_lyrics(banana)["err_code"] == "bad_song", "kind banana -> bad_song")
	var v2 := _lyrics_song()
	v2["v"] = 2
	ok(SongStore.install_lyrics(v2)["err_code"] == "bad_song", "v:2 -> bad_song")
	ok(SongStore.install_lyrics({})["err_code"] == "bad_song", "empty song -> bad_song")
	ok(_dirs(ROOT) == dirs0 and r0["ok"], "rejected installs leave no folder; the earlier song is untouched")
	# audio install of a lyrics song is still refused (no audio)
	ok(SongStore.install(_lyrics_song(), PackedByteArray())["err_code"] == "bad_song", "install() with a lyrics song and no audio -> bad_song (as before)")
	# a path-like id in the song is ignored
	var trav := _lyrics_song()
	trav["id"] = "../../escape"
	var rt: Dictionary = SongStore.install_lyrics(trav)
	ok(rt["ok"] and SongModel.is_valid_id(rt["id"]) and not DirAccess.dir_exists_absolute(_g("user://escape")), "a path-like id in the song is ignored (a new id is made)")
	# the install overwrites nothing when the same song is installed twice: two folders
	ok(SongStore.install_lyrics(_lyrics_song())["ok"] and SongStore.list().size() == 3, "installing the same lyrics again makes a new song")


func _test_quota() -> void:
	print("[quota (shared with audio songs)]")
	_fresh()
	var okc: int = 0
	for i in 39:
		if SongStore.install(_audio_song("Audio %d" % i), _audio(32, i))["ok"]:
			okc += 1
	ok(okc == 39, "39 audio songs installed")
	var rl: Dictionary = SongStore.install_lyrics(_lyrics_song("The 40th"))
	ok(rl["ok"] and SongStore.usage()["songs"] == 40, "a lyrics song as the 40th")
	var before: Array = _dirs(ROOT)
	var r41: Dictionary = SongStore.install_lyrics(_lyrics_song("The 41st"))
	ok(r41["ok"] == false and r41["err_code"] == "quota_songs" and SongStore.last_error == "quota_songs", "41st (39 audio + 1 lyrics + 1 lyrics) -> quota_songs")
	ok(_dirs(ROOT) == before, "41st: no partial folder")
	ok(SongStore.install(_audio_song("Audio 41"), _audio(32))["err_code"] == "quota_songs", "an audio song is refused as well at 40")
	_fresh()
	for i in 40:
		SongStore.install_lyrics(_lyrics_song("L%d" % i))
	ok(SongStore.usage()["songs"] == 40 and SongStore.install(_audio_song(), _audio(32))["err_code"] == "quota_songs", "40 lyrics songs fill the shared limit for audio songs too")
	_fresh()
	SongStore.fake_used_bytes = SongStore.MAX_BYTES - 50
	var r2: Dictionary = SongStore.install_lyrics(_lyrics_song())
	ok(r2["ok"] == false and r2["err_code"] == "quota_bytes", "over 400 MiB -> quota_bytes")
	ok(_dirs(ROOT).is_empty(), "quota_bytes: no partial folder")
	SongStore.fake_used_bytes = 0
	SongStore.max_songs = 2
	ok(SongStore.install_lyrics(_lyrics_song("a"))["ok"] and SongStore.install_lyrics(_lyrics_song("b"))["ok"] and SongStore.install_lyrics(_lyrics_song("c"))["err_code"] == "quota_songs", "max_songs is honoured (test knob)")
	SongStore.max_songs = SongStore.MAX_SONGS


func _test_write_failures() -> void:
	print("[install_lyrics write failures]")
	_fresh()
	SongStore.write_hook = func(path: String) -> bool: return not path.ends_with("song.json")
	var r: Dictionary = SongStore.install_lyrics(_lyrics_song())
	ok(r["ok"] == false and r["err_code"] == "disk_write" and SongStore.last_error == "disk_write", "song.json write fails -> disk_write")
	ok(_dirs(ROOT).is_empty(), "failed install leaves no folder (no staging, no half song)")
	SongStore.write_hook = Callable()
	var good: Dictionary = SongStore.install_lyrics(_lyrics_song("Keep"))
	ok(good["ok"], "after the failure an install works again")
	SongStore.write_hook = func(path: String) -> bool: return false
	var r2: Dictionary = SongStore.install_lyrics(_lyrics_song("Second"))
	ok(r2["ok"] == false and SongStore.list().size() == 1 and SongStore.list()[0]["id"] == good["id"] and _dirs(ROOT) == [good["id"]], "a failing write leaves the earlier song intact and no other folder")
	SongStore.write_hook = Callable()
	# a stale staging folder from a crash is cleaned by the next install_lyrics
	DirAccess.make_dir_recursive_absolute(_g(ROOT + "/_tmp_s_aaaaaaaaaaaa"))
	_write(ROOT + "/_tmp_s_aaaaaaaaaaaa/song.json", "junk")
	ok(SongStore.install_lyrics(_lyrics_song("Next"))["ok"] == true and not _has_staging(), "stale staging folder removed by the next install_lyrics")


func _test_internal_keys() -> void:
	print("[keys starting with _ are dropped (lyrics songs too)]")
	_fresh()
	var s := _lyrics_song()
	s["_audio_path"] = "C:/Windows/win.ini"
	s["_secret"] = 1
	s["note"] = "kept"
	s["lines"][0]["_audio_path"] = "x"
	var id: String = SongStore.install_lyrics(s)["id"]
	var text: String = _read(ROOT + "/" + id + "/song.json")
	ok(not text.contains("_audio_path") and not text.contains("win.ini") and not text.contains("_secret"), "install_lyrics: _* keys never reach song.json")
	ok(text.contains("\"note\"") and text.contains("\"kind\":\"lyrics\""), "  ... other keys are kept, kind is written")
	var raw: Dictionary = JSON.parse_string(text)
	raw["_audio_path"] = "C:/Windows/win.ini"
	raw["lines"][1]["_x"] = 1
	_write(ROOT + "/" + id + "/song.json", JSON.stringify(raw))
	var back: Dictionary = SongStore.load_song(id)
	ok(not JSON.stringify(back).contains("_audio_path") and not back["lines"][1].has("_x"), "load_song drops _* keys read from disk")


# ---------------------------------------------------------------- memo

func _new_lyrics() -> String:
	return SongStore.install_lyrics(_lyrics_song())["id"]


func _test_memo_io() -> void:
	print("[memo.json: save and load]")
	_fresh()
	var id: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	var m0: Dictionary = SongStore.load_memo(id, song)
	ok(m0 == MemoModel.new_memo() and SongStore.last_error == "", "no memo.json yet -> a new memo, no error")
	ok(not FileAccess.file_exists(ROOT + "/" + id + "/memo.json"), "  ... and nothing is written by a load")
	var memo := _memo_for(song, 4)
	ok(SongStore.save_memo(id, memo) == true, "save_memo ok")
	ok(_files(ROOT + "/" + id) == ["memo.json", "song.json"], "the folder now holds song.json + memo.json (no .tmp)")
	ok(JSON.stringify(SongStore.load_memo(id)) == JSON.stringify(MemoModel.normalize(memo, NOW)), "save -> load round trip is the same memo")
	var text: String = _read(ROOT + "/" + id + "/memo.json")
	ok(not text.contains("kettle") and not text.contains("chair") and not text.contains("Nobody"), "memo.json holds no lyrics text (hash keys and numbers only)")
	ok(JSON.parse_string(text)["v"] == 1 and JSON.parse_string(text)["lines"].size() == 4, "memo.json is v 1 with 4 lines")
	var outside: Array = _files(ROOT)
	ok(outside.is_empty() and _dirs(ROOT) == [id] and _files("user://").has("memo.json") == false, "no memo file outside the song folder")
	# normalization on save: junk is cleaned before it reaches the disk
	var dirty := memo.duplicate(true)
	dirty["lines"]["not-a-key"] = {"stage": 1}
	dirty["lines"]["a1b2c3d4e5f6"] = {"stage": 99, "card": {"due": "x", "state": 2, "stability": 1.0, "difficulty": 1.0}}
	dirty["extra"] = 1
	ok(SongStore.save_memo(id, dirty), "save_memo of a dirty memo")
	var cleaned: Dictionary = JSON.parse_string(_read(ROOT + "/" + id + "/memo.json"))
	ok(not cleaned["lines"].has("not-a-key") and not cleaned.has("extra") and cleaned["lines"]["a1b2c3d4e5f6"]["stage"] == 8 and not cleaned["lines"]["a1b2c3d4e5f6"].has("card"), "save normalizes: bad key / unknown key / bad card dropped, stage capped")
	# the folder of another song is not touched
	var id2: String = _new_lyrics()
	ok(SongStore.load_memo(id2) == MemoModel.new_memo() and not FileAccess.file_exists(ROOT + "/" + id2 + "/memo.json"), "another song has its own (empty) memo")
	# audio songs have a memo too
	var ia: String = SongStore.install(_audio_song(), _audio(100))["id"]
	ok(SongStore.save_memo(ia, memo) and SongStore.load_memo(ia)["lines"].size() == 4 and FileAccess.file_exists(ROOT + "/" + ia + "/audio.mp3"), "an audio song can keep a memo next to its audio")
	# errors
	ok(SongStore.save_memo("s_0000000000ff", memo) == false and SongStore.last_error == "not_found", "no song folder -> false / not_found")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT + "/s_0000000000ff")), "  ... and no folder was made")
	ok(SongStore.save_memo("../../x", memo) == false and SongStore.last_error == "bad_id" and SongStore.save_memo("", memo) == false, "bad id -> false / bad_id")
	var lm: Dictionary = SongStore.load_memo("s_0000000000ff")
	ok(lm == MemoModel.new_memo() and SongStore.last_error == "not_found", "load_memo of a missing song -> a new memo / not_found")
	ok(SongStore.load_memo("../x") == MemoModel.new_memo() and SongStore.last_error == "bad_id", "load_memo of a path-like id -> a new memo / bad_id")
	# read-only memo (v 2)
	var ro := memo.duplicate(true)
	ro["v"] = 2
	var before: String = _read(ROOT + "/" + id + "/memo.json")
	ok(SongStore.save_memo(id, ro) == false and SongStore.last_error == "read_only" and _read(ROOT + "/" + id + "/memo.json") == before, "a v:2 memo is not saved (read_only), memo.json untouched")
	_write(ROOT + "/" + id + "/memo.json", JSON.stringify(ro))
	var lro: Dictionary = SongStore.load_memo(id)
	ok(lro["v"] == 2 and MemoModel.is_read_only(lro) and lro["lines"].size() == 4 and SongStore.last_error == "", "a v:2 memo.json loads (read-only flag), it is not quarantined")


func _test_memo_atomic() -> void:
	print("[memo.json: atomic write]")
	_fresh()
	var id: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	var memo := _memo_for(song, 3)
	SongStore.save_memo(id, memo)
	var path: String = ROOT + "/" + id + "/memo.json"
	var keep: String = _read(path)
	_write(path + ".tmp", keep.substr(0, 10))
	ok(JSON.stringify(SongStore.load_memo(id)) == JSON.stringify(MemoModel.normalize(memo, NOW)), "a left-over .tmp next to memo.json is ignored when reading")
	var memo2 := _memo_for(song, 5)
	ok(SongStore.save_memo(id, memo2) and not FileAccess.file_exists(path + ".tmp") and SongStore.load_memo(id)["lines"].size() == 5, "the next save replaces it and leaves no .tmp")
	keep = _read(path)
	SongStore.write_hook = func(tmp: String) -> bool:
		_write(tmp, "{\"v\":1,\"lines\":{\"aaaaaaaaaaaa\":HALF")
		return false
	ok(SongStore.save_memo(id, _memo_for(song, 1)) == false and SongStore.last_error == "disk_write", "a write that dies half way -> false / disk_write")
	ok(_read(path) == keep and not FileAccess.file_exists(path + ".tmp"), "  ... memo.json is byte for byte the old one, no .tmp left")
	SongStore.write_hook = func(tmp: String) -> bool: return false
	ok(SongStore.save_memo(id, _memo_for(song, 1)) == false and _read(path) == keep, "a hook that refuses the write: old memo.json stays")
	SongStore.write_hook = Callable()
	SongStore.rename_fail = true
	ok(SongStore.save_memo(id, _memo_for(song, 1)) == false and SongStore.last_error == "disk_write" and _read(path) == keep and not FileAccess.file_exists(path + ".tmp"), "rename refused -> false; old memo.json intact, no .tmp")
	SongStore.rename_fail = false
	ok(SongStore.save_memo(id, _memo_for(song, 1)) and SongStore.load_memo(id)["lines"].size() == 1, "after the failures a save works again")
	ok(_files(ROOT + "/" + id) == ["memo.json", "song.json"], "folder: song.json + memo.json only")


func _bad_memo_inputs() -> Dictionary:
	var big := "{\"v\":1,\"pad\":\"" + "x".repeat(SongStore.MAX_MEMO_BYTES + 100) + "\"}"
	return {
		"cut JSON": "{\"v\":1,\"lines\":{\"aaaaaaaaaaaa\":{\"stage\":",
		"array JSON": "[1, 2, 3]",
		"a JSON string": "\"just a string\"",
		"empty file": "",
		"null": "null",
		"over 2 MiB": big,
	}


func _test_memo_broken() -> void:
	print("[memo.json: broken files]")
	_fresh()
	var id: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	var path: String = ROOT + "/" + id + "/memo.json"
	var song_before: String = _read(ROOT + "/" + id + "/song.json")
	var bad := _bad_memo_inputs()
	for name in bad.keys():
		_write(path, bad[name])
		var s: Dictionary = SongStore.memo_summary(id, NOW)
		ok(s.is_empty() and FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bad"), "memo_summary of `%s` -> {} and the file is NOT moved" % name)
		var m: Dictionary = SongStore.load_memo(id, song)
		ok(m == MemoModel.new_memo() and SongStore.last_error == "bad_memo", "load_memo of `%s` -> a new memo / bad_memo" % name)
		ok(FileAccess.file_exists(path + ".bad") and not FileAccess.file_exists(path), "  ... moved to memo.json.bad")
		ok(_read(ROOT + "/" + id + "/song.json") == song_before and SongStore.load_song(id)["title"] == "Lyrics Song", "  ... song.json is fine")
		DirAccess.remove_absolute(_g(path + ".bad"))
	# NUL bytes
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0x7b, 0x00, 0x00, 0x7d]))
	f.close()
	ok(SongStore.memo_summary(id, NOW).is_empty() and FileAccess.file_exists(path), "memo_summary of NUL bytes -> {} and not moved")
	ok(SongStore.load_memo(id) == MemoModel.new_memo() and SongStore.last_error == "bad_memo" and FileAccess.file_exists(path + ".bad"), "load_memo of NUL bytes -> new memo / bad_memo / .bad")
	# valid JSON with NUL bytes inside a string is broken too
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_buffer("{\"v\":1,\"app\":\"a".to_utf8_buffer() + PackedByteArray([0]) + "b\"}".to_utf8_buffer())
	f2.close()
	ok(SongStore.load_memo(id) == MemoModel.new_memo() and SongStore.last_error == "bad_memo", "a NUL byte inside otherwise valid JSON -> bad_memo")
	# at most 3 .bad files are kept
	for n in 6:
		_write(path, "{broken %d" % n)
		SongStore.load_memo(id)
	var bads: int = 0
	for fn in _files(ROOT + "/" + id):
		if fn.begins_with("memo.json.bad"):
			bads += 1
	ok(bads == 3, "at most 3 memo .bad files are kept (%d)" % bads)
	# after the quarantine a new memo can be saved and read
	SongStore.last_error = ""
	ok(SongStore.save_memo(id, _memo_for(song, 2)) and SongStore.load_memo(id)["lines"].size() == 2 and SongStore.last_error == "", "after a quarantine a new memo is saved and loaded normally")
	# a memo with junk values inside valid JSON is repaired, not quarantined
	_write(path, JSON.stringify({"v": 1, "lines": {"aaaaaaaaaaaa": {"stage": "x", "card": {"state": 9}}, "zz": 1}, "stats": "no"}))
	var rep: Dictionary = SongStore.load_memo(id)
	ok(SongStore.last_error == "" and rep["lines"].keys() == ["aaaaaaaaaaaa"] and not rep["lines"]["aaaaaaaaaaaa"].has("card") and not FileAccess.file_exists(path + ".bad.5"), "valid JSON with junk values is repaired in memory (no quarantine)")
	# a huge song.json does not stop memo_summary from being safe
	var f3 := FileAccess.open(ROOT + "/" + id + "/song.json", FileAccess.WRITE)
	f3.store_8(0x20)
	f3.seek(SongStore.MAX_JSON_BYTES + 10)
	f3.store_8(0x20)
	f3.close()
	ok(SongStore.memo_summary(id, NOW).is_empty() and FileAccess.file_exists(ROOT + "/" + id + "/song.json") and not FileAccess.file_exists(ROOT + "/" + id + "/song.json.bad"), "memo_summary with an oversized song.json -> {} and song.json is not quarantined by it")


func _test_memo_summary() -> void:
	print("[memo_summary]")
	_fresh()
	var id: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	var s0: Dictionary = SongStore.memo_summary(id, NOW)
	ok(s0 == {"total": 6, "memorized": 0, "learning": 0, "fresh": 6, "due": 0, "next_due": 0}, "no memo.json: 6 lines, all fresh")
	var memo := _memo_for(song, 4)
	var ks: Array = MemoModel.keys_of(song)
	memo["lines"][ks[0]["key"]]["card"]["due"] = NOW - 10
	memo["lines"][ks[1]["key"]]["card"]["state"] = 1
	memo["lines"][ks[1]["key"]]["card"]["due"] = NOW + 600
	SongStore.save_memo(id, memo)
	var files_before: Array = _files(ROOT + "/" + id)
	var s: Dictionary = SongStore.memo_summary(id, NOW)
	ok(s["total"] == 6 and s["memorized"] == 3 and s["learning"] == 1 and s["fresh"] == 2 and s["due"] == 1, "summary: 6 total, 3 memorized, 1 learning, 2 fresh, 1 due")
	ok(s["next_due"] == NOW + 600, "next_due = the earliest upcoming due")
	ok(_files(ROOT + "/" + id) == files_before and SongStore.memo_summary(id, NOW) == s, "memo_summary writes and moves nothing, and repeats the same")
	ok(SongStore.memo_summary("s_0000000000ff", NOW).is_empty() and SongStore.memo_summary("../x", NOW).is_empty() and SongStore.memo_summary("", NOW).is_empty(), "no such song / bad id -> {}")
	# the same line three times counts once
	var lyr := _lyrics_song("Chorus song")
	lyr["lines"].append(lyr["lines"][0].duplicate())
	lyr["lines"].append(lyr["lines"][0].duplicate())
	lyr["lines"].append({"i": 8, "p": 1, "t0": 0.0, "t1": 0.0, "text": "[Chorus]"})
	var ic: String = SongStore.install_lyrics(lyr)["id"]
	ok(SongStore.memo_summary(ic, NOW)["total"] == 6 and SongStore.load_song(ic)["lines"].size() == 9, "a chorus line repeated 3 times (and a [Chorus] mark) counts once in total (9 lines, 6 keys)")


func _test_delete() -> void:
	print("[delete and delete_memo]")
	_fresh()
	var id: String = _new_lyrics()
	var id2: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	SongStore.save_memo(id, _memo_for(song, 3))
	SongStore.save_memo(id2, _memo_for(song, 2))
	_write(ROOT + "/" + id + "/memo.json.bad", "old")
	ok(SongStore.delete_memo(id) == true and not FileAccess.file_exists(ROOT + "/" + id + "/memo.json"), "delete_memo removes memo.json")
	ok(FileAccess.file_exists(ROOT + "/" + id + "/song.json") and SongStore.load_song(id)["title"] == "Lyrics Song" and SongStore.list().size() == 2, "  ... song.json stays and the song is still listed")
	ok(SongStore.load_memo(id) == MemoModel.new_memo() and SongStore.memo_summary(id, NOW)["fresh"] == 6, "  ... progress is reset: 6 fresh")
	ok(SongStore.load_memo(id2)["lines"].size() == 2, "  ... another song's memo is untouched")
	ok(SongStore.delete_memo(id) == true, "deleting it again is harmless")
	_write(ROOT + "/" + id + "/memo.json.tmp", "half")
	ok(SongStore.delete_memo(id) and not FileAccess.file_exists(ROOT + "/" + id + "/memo.json.tmp"), "a leftover memo.json.tmp is removed too")
	ok(SongStore.delete_memo("../x") == false and SongStore.last_error == "bad_id" and SongStore.delete_memo("") == false, "delete_memo of a bad id -> false / bad_id")
	ok(SongStore.delete_memo("s_0000000000ff") == true, "delete_memo of a song that does not exist -> true (nothing to remove), no folder made")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT + "/s_0000000000ff")), "  ... and no folder was made")
	# a folder named memo.json is removed as a tree
	DirAccess.make_dir_recursive_absolute(_g(ROOT + "/" + id + "/memo.json/deep"))
	_write(ROOT + "/" + id + "/memo.json/deep/x.txt", "x")
	ok(SongStore.delete_memo(id) and not DirAccess.dir_exists_absolute(_g(ROOT + "/" + id + "/memo.json")), "a directory named memo.json is removed (inside the root)")
	# delete(id) takes memo.json along
	SongStore.save_memo(id2, _memo_for(song, 2))
	ok(FileAccess.file_exists(ROOT + "/" + id2 + "/memo.json") and SongStore.delete(id2) == true, "delete(id) of a song with a memo")
	ok(not DirAccess.dir_exists_absolute(_g(ROOT + "/" + id2)) and not FileAccess.file_exists(ROOT + "/" + id2 + "/memo.json") and SongStore.list().size() == 1, "  ... the whole folder, memo.json included, is gone")
	ok(SongStore.usage()["songs"] == 1, "usage counts one song")
	# memo.json counts in usage
	var u0: int = SongStore.usage()["bytes"]
	SongStore.save_memo(id, _memo_for(song, 5))
	ok(SongStore.usage()["bytes"] > u0, "memo.json bytes are part of usage()")
	# delete of a lyrics song with a quarantined memo
	_write(ROOT + "/" + id + "/memo.json", "{broken")
	SongStore.load_memo(id)
	ok(FileAccess.file_exists(ROOT + "/" + id + "/memo.json.bad") and SongStore.delete(id) and not DirAccess.dir_exists_absolute(_g(ROOT + "/" + id)), "delete(id) also removes memo.json.bad files")


# ---------------------------------------------------------------- not synced

func _test_not_synced() -> void:
	print("[memo.json and lyrics songs are not synced or backed up]")
	_fresh()
	var id: String = SongStore.install_lyrics(_lyrics_song(MARK))["id"]
	var song: Dictionary = SongStore.load_song(id)
	song["lines"][0]["text"] = MARK
	SongStore.save_song(song)
	song = SongStore.load_song(id)
	SongStore.save_memo(id, _memo_for(song, 3))
	ok(_read(ROOT + "/" + id + "/song.json").contains(MARK) and FileAccess.file_exists(ROOT + "/" + id + "/memo.json"), "control: the marker is in song.json and memo.json exists on disk")
	var shared_bad: Array = []
	for k in SyncDoc.SHARED_PREFS.keys():
		if String(k).begins_with("memo"):
			shared_bad.append(k)
	ok(shared_bad.is_empty() and not SyncDoc.SHARED_PREFS.has("memo_fast") and not SyncDoc.SHARED_PREFS.has("memo_prev_cue") and not SyncDoc.SHARED_PREFS.has("memo_answer"), "SyncDoc.SHARED_PREFS has no memo_* key")
	var l: Dictionary = SyncPorts.live().load_local.call()
	var prefs: Dictionary = (l["prefs"] as Dictionary).duplicate(true)
	prefs["memo_fast"] = true
	prefs["memo_prev_cue"] = false
	prefs["memo_answer"] = "speak"
	prefs["memo"] = {"lines": MARK}
	var prog: Dictionary = (l["progress"] as Dictionary).duplicate(true)
	var review_n: int = (prog["review"] as Array).size()
	var view: Dictionary = SyncDoc.extract(prog, l["studylog"], prefs, 0)
	var vtxt: String = JSON.stringify(view)
	ok(not vtxt.contains(MARK) and not vtxt.to_lower().contains("memo"), "SyncDoc.extract result has no marker and no memo key (%d bytes)" % vtxt.length())
	var back: Dictionary = SyncDoc.to_local(view, 0, prog, l["studylog"], prefs)
	var pc_bad: Array = []
	for k in back["prefs_changes"].keys():
		if not SyncDoc.SHARED_PREFS.has(k):
			pc_bad.append(k)
	ok(pc_bad.is_empty() and not JSON.stringify(back["prefs_changes"]).to_lower().contains("memo"), "to_local prefs_changes only holds shared keys (no memo_*)")
	var saved_path: String = Store.prefs_path
	Store.prefs_path = BK.path_join("prefs.json")
	DirAccess.make_dir_recursive_absolute(_g(BK))
	var res: bool = Store.apply_sync_prefs({"memo_fast": true, "memo_prev_cue": false, "memo_answer": "speak"})
	Store.prefs_path = saved_path
	ok(res and not Store.prefs.has("memo_fast") and not Store.prefs.has("memo_prev_cue") and not Store.prefs.has("memo_answer") and not FileAccess.file_exists(BK.path_join("prefs.json")), "Store.apply_sync_prefs drops memo_* keys from a merge result and writes nothing")
	# a backup of the app files does not contain the songs folder
	_rm_rf(BK)
	DirAccess.make_dir_recursive_absolute(_g(BK + "_files"))
	_write(BK + "_files/progress.json", JSON.stringify(Store.progress))
	_write(BK + "_files/studylog.json", JSON.stringify(StudyLog.snapshot()))
	_write(BK + "_files/prefs.json", JSON.stringify(Store.prefs))
	_write(BK + "_files/sync_state.json", "{}")
	var paths := {"progress": BK + "_files/progress.json", "studylog": BK + "_files/studylog.json", "prefs": BK + "_files/prefs.json"}
	var r: Dictionary = SyncBackup.create(BK, "auto", 1790000000, paths, BK + "_files/sync_state.json")
	var tree: Dictionary = _tree(BK)
	var bad_files: Array = []
	for n in tree.keys():
		var fn: String = String(n).get_file()
		if fn == "memo.json" or fn == "song.json" or String(tree[n]).contains(MARK):
			bad_files.append(n)
	ok(r["ok"] == true and tree.size() >= 5 and bad_files.is_empty(), "SyncBackup result has no memo.json / song.json and no marker (%d entries) %s" % [tree.size(), bad_files])
	_rm_rf(BK + "_files")
	_rm_rf(BK)
	ok((Store.progress["review"] as Array).size() == review_n and (prog["review"] as Array).size() == review_n, "memo work leaves Store.progress[\"review\"] as it was (%d cards)" % review_n)
	# the detector must see a marker that does go through a card note
	var p2: Dictionary = Progress.blank()
	p2["review"] = [{"lang": "en", "target": "hello", "reading": "", "ko": "안녕", "note": MARK, "due": 1, "stability": 1.0,
		"difficulty": 5.0, "state": 1, "step": 0, "last_review": 1, "reps": 1, "lapses": 0}]
	ok(JSON.stringify(SyncDoc.extract(p2, {}, {}, 0)).contains(MARK), "control: a marker inside a review card note IS found by the same check")
	# source scan: the store / model code does not name the sync or app-file classes (comments are ignored)
	var rx := RegEx.new()
	rx.compile("StudyLog|SyncDoc|SyncPorts|SyncBackup|SyncEngine|prefs\\.json|progress\\.json|studylog\\.json|sync_state")
	var rx_store := RegEx.new()
	rx_store.compile("(?<!Song)Store\\.")
	var hits: Array = []
	for fp in ["res://scripts/core/memo_model.gd", "res://scripts/core/song_model.gd", "res://scripts/local/song_store.gd"]:
		var code := PackedStringArray()
		for ln in FileAccess.get_file_as_string(fp).split("\n"):
			if not ln.strip_edges().begins_with("#"):
				code.append(ln)
		var joined := "\n".join(code)
		for m in rx.search_all(joined):
			hits.append(fp.get_file() + ":" + m.get_string())
		for m in rx_store.search_all(joined):
			hits.append(fp.get_file() + ":Store.")
	ok(hits.is_empty(), "memo_model / song_model / song_store code never names Store / StudyLog / Sync* / app files %s" % [hits])
	ok(rx_store.search("var x = Store.progress") != null and rx_store.search("var x = SongStore.root") == null, "control: the Store scan flags Store. and not SongStore.")


# ---------------------------------------------------------------- G2 defences on the new paths

func _test_links() -> void:
	print("[links are never followed (new paths)]")
	_fresh()
	_rm_rf(OUT)
	DirAccess.make_dir_recursive_absolute(_g(OUT + "/deep"))
	_write(OUT + "/keep.txt", "keep")
	_write(OUT + "/deep/deep.txt", "deep")
	var files := [OUT + "/keep.txt", OUT + "/deep/deep.txt"]
	var out_before: Array = _files(OUT)
	var id: String = _new_lyrics()
	var song: Dictionary = SongStore.load_song(id)
	var memo := _memo_for(song, 2)

	# (a) a directory link named memo.json inside a real song folder
	var lk: String = ROOT + "/" + id + "/memo.json"
	var made: bool = _mklink(lk, OUT)
	ok(made, "a directory link named memo.json could be created")
	if made:
		ok(SongStore.memo_summary(id, NOW).is_empty() and _is_link(lk), "memo_summary: a linked memo.json -> {} and the link is not touched")
		SongStore.save_memo(id, memo)
		ok(_outside_ok(files) and _files(OUT) == out_before, "save_memo with a link at memo.json: nothing was written outside (files %s)" % [_files(OUT)])
		ok(not FileAccess.file_exists(lk + ".tmp"), "  ... no .tmp left behind")
		_relink(lk)
		ok(SongStore.load_memo(id) == MemoModel.new_memo() and SongStore.last_error == "bad_memo", "load_memo with a link at memo.json -> a new memo / bad_memo (the link is not read)")
		ok(_outside_ok(files), "  ... outside files are still there")
		_relink(lk)
		ok(SongStore.delete_memo(id) == true and _outside_ok(files), "delete_memo with a link at memo.json: outside files survive")
		ok(not DirAccess.dir_exists_absolute(_g(lk)) and DirAccess.dir_exists_absolute(_g(OUT + "/deep")), "  ... the link itself is gone, the target folder stays")
	# (b) a link renamed to memo.json.bad by a quarantine is not followed when the song is deleted
	var lk2: String = ROOT + "/" + id + "/memo.json"
	var made_b: bool = _mklink(lk2, OUT)
	if made_b:
		SongStore.load_memo(id) ## quarantines the link (renames it to memo.json.bad)
		ok(_outside_ok(files), "quarantine of a linked memo.json does not touch the target")
	ok(SongStore.delete(id) == true and _outside_ok(files) and not DirAccess.dir_exists_absolute(_g(ROOT + "/" + id)), "delete(song) with a link inside (memo.json / .bad): outside files survive, the song folder is gone")

	# (c) the song folder itself is a link (named like a song) to a folder that holds a memo.json
	_write(OUT + "/memo.json", "{\"v\":1,\"lines\":{},\"keep\":\"me\"}")
	_write(OUT + "/song.json", JSON.stringify(_lyrics_song("Outside")))
	var memo_outside: String = _read(OUT + "/memo.json")
	var lid := "s_aaaaaaaaaaaa"
	DirAccess.make_dir_recursive_absolute(_g(ROOT))
	var made_c: bool = _mklink(ROOT + "/" + lid, OUT)
	ok(made_c, "a directory link named like a song folder could be created")
	if made_c:
		ok(SongStore.save_memo(lid, memo) == false and SongStore.last_error == "not_found" and _read(OUT + "/memo.json") == memo_outside, "save_memo into a linked song folder is refused (not_found); the file outside is unchanged")
		ok(SongStore.load_memo(lid) == MemoModel.new_memo() and SongStore.last_error == "not_found" and FileAccess.file_exists(OUT + "/memo.json") and not FileAccess.file_exists(OUT + "/memo.json.bad"), "load_memo from a linked song folder: a new memo; the file outside is not read or moved")
		ok(SongStore.memo_summary(lid, NOW).is_empty(), "memo_summary of a linked song folder -> {}")
		ok(SongStore.delete_memo(lid) == false and _read(OUT + "/memo.json") == memo_outside and _outside_ok(files), "delete_memo of a linked song folder: refused, memo.json outside survives")
		ok(SongStore.list().is_empty() and SongStore.orphan_ids().is_empty(), "a linked folder is not listed")
		ok(SongStore.delete(lid) == true and _outside_ok(files) and _read(OUT + "/memo.json") == memo_outside, "delete(link id): only the link is removed")
		ok(not DirAccess.dir_exists_absolute(_g(ROOT + "/" + lid)) and DirAccess.dir_exists_absolute(_g(OUT + "/deep")), "  ... the target folder stays")

	# (d) a staging-named link: install_lyrics cleans it without following it
	var made_d: bool = _mklink(ROOT + "/_tmp_s_bbbbbbbbbbbb", OUT)
	ok(made_d, "a staging-named link could be created")
	if made_d:
		ok(SongStore.install_lyrics(_lyrics_song("After Link"))["ok"] == true and _outside_ok(files), "install_lyrics's staging cleanup does not follow the link")
		ok(not DirAccess.dir_exists_absolute(_g(ROOT + "/_tmp_s_bbbbbbbbbbbb")), "  ... the staging link itself is removed")

	# (e) _rm_rf refuses folders outside the root; memo paths are inside
	SongStore._rm_rf(OUT)
	ok(_outside_ok(files) and SongStore.last_error == "outside_root", "_rm_rf of a path outside the root: nothing deleted")
	SongStore.last_error = ""
	SongStore._rm_rf(OUT + "/memo.json")
	ok(SongStore.last_error == "outside_root" and FileAccess.file_exists(OUT + "/memo.json"), "_rm_rf of a memo.json outside the root: refused")

	for sub in _dirs(ROOT):
		if _is_link(ROOT + "/" + sub):
			DirAccess.remove_absolute(_g(ROOT + "/" + sub))
	_rm_rf(OUT)
	ok(not DirAccess.dir_exists_absolute(_g(OUT)), "test cleanup of the outside folder")


func _test_guard() -> void:
	print("[test guard on the real folder (new paths)]")
	var saved: String = SongStore.root
	var sid := "s_0123456789ab"
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	var variants := ["user://songs", "user://songs/", "user://songs/../songs", "user://SONGS", "user://Songs/sub", "user://songs.", "user://songs ", "user://songs. ",
		ProjectSettings.globalize_path("user://songs"), ProjectSettings.globalize_path("user://songs").replace("/", "\\").to_upper(),
		ProjectSettings.globalize_path("user://Songs") + "/deep/er", "user://test_x/../SongS", "user://songs/./."]
	for v in variants:
		SongStore.root = v
		var refused: bool = SongStore.blocked() == true
		refused = refused and SongStore.install_lyrics(_lyrics_song())["ok"] == false and SongStore.last_error == "test_guard"
		refused = refused and SongStore.save_memo(sid, MemoModel.new_memo()) == false and SongStore.last_error == "test_guard"
		refused = refused and SongStore.load_memo(sid) == MemoModel.new_memo() and SongStore.last_error == "test_guard"
		refused = refused and SongStore.memo_summary(sid, NOW).is_empty() and SongStore.delete_memo(sid) == false and SongStore.last_error == "test_guard"
		ok(refused, "install_lyrics / save_memo / load_memo / memo_summary / delete_memo refused: `%s`" % v)
		SongStore.last_error = ""
	SongStore.root = "user://songs/x"
	ok(SongStore.save_memo(sid, MemoModel.new_memo()) == false and SongStore.delete_memo(sid) == false and SongStore.install_lyrics(_lyrics_song())["ok"] == false, "a blocked sub folder: the new functions are refused too")
	SongStore.root = ROOT
	ok(SongStore.blocked() == false and SongStore.install_lyrics(_lyrics_song())["ok"] == true, "a user://test_* root is allowed")
	for v in ["user://songsx", "user://test_songs/songs", "user://my_songs", "user://songs_other/songs"]:
		SongStore.root = v
		ok(SongStore.blocked() == false, "not blocked: `%s` (a different folder)" % v)
	SongStore.root = saved
