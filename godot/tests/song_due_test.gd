extends Node
## SongDue (홈 "노래 외우기 N줄" 집계) 시험. 곡 목록은 가짜 lister 로 넣고, 실제 읽기 경로는 임시 폴더로만 돈다.
##   godot --headless --path <project> res://tests/song_due_test.tscn
## Exit code 0 = all passed. Last line: "== song_due result: N passed, 0 failed =="
## 실제 user://songs 는 열지 않는다(시험 보호가 막고, 막은 채로 scan() 이 0 을 돌려주는지 확인한다).
## 임시 곡 폴더 user://test_home_songs 는 시험 끝에 지운다.

const TMP := "user://test_home_songs"

var passed: int = 0
var failed: int = 0
var _before: Array = []


func _ready() -> void:
	print("== song_due start ==")
	_before = _user_listing()
	_selfcheck()
	_initial_cache()
	_lister_cases()
	_bad_lister_values()
	_blocked_guard()
	_real_read_path()
	_gap()
	var after: Array = _user_listing()
	ok(JSON.stringify(_before) == JSON.stringify(after), "user:// listing unchanged after the test (temp folder removed)")
	print("== song_due result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func counts(r: Dictionary) -> Array:
	return [r.get("songs"), r.get("lyrics"), r.get("due"), r.get("fresh")]


func eqc(r: Dictionary, want: Array, name: String) -> void:
	var got: Array = counts(r)
	var good: bool = JSON.stringify(got) == JSON.stringify(want)
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


func lister_of(v: Variant) -> Callable:
	return func() -> Variant: return v


func _selfcheck() -> void:
	print("[selfcheck]")
	var r: Dictionary = SongDue.scan(lister_of({"list": [{"id": "a", "kind": "lyrics"}], "memo": {"a": {"due": 2, "fresh": 0}}}))
	var wrong: bool = JSON.stringify(counts(r)) == JSON.stringify([1, 1, 3, 0])
	print("selfcheck %s counts vs a wrong due sum" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "eqc() comparison rejects a wrong expectation")
	var ghost: bool = JSON.stringify(counts(SongDue.scan(lister_of(null)))) == JSON.stringify([1, 1, 2, 0])
	print("selfcheck %s null lister vs real-looking counts" % ("FAIL-as-expected" if not ghost else "UNEXPECTED-PASS"))
	ok(not ghost, "a null lister does not produce counts")


func _initial_cache() -> void:
	print("[cache]")
	# 이 시험은 scan() 을 한 번도 부르기 전의 값이 아니라(_selfcheck 가 불렀다) 모양만 본다.
	ok(SongDue.cache.keys().size() == 5 and SongDue.cache.has("songs") and SongDue.cache.has("lyrics") and SongDue.cache.has("due") and SongDue.cache.has("fresh") and SongDue.cache.has("at"), "cache has the 5 keys")
	ok(SongDue.due_lines() == int(SongDue.cache["due"]), "due_lines() reads cache.due")


func _lister_cases() -> void:
	print("[lister]")
	var l := {"list": [{"id": "s_a", "kind": "lyrics"}, {"id": "s_b", "kind": "lyrics"}, {"id": "s_c", "kind": "audio"}],
		"memo": {"s_a": {"total": 9, "due": 2, "fresh": 1}, "s_b": {"total": 9, "due": 3, "fresh": 4}}}
	var r: Dictionary = SongDue.scan(lister_of(l))
	eqc(r, [3, 2, 5, 5], "3 songs (2 lyrics, 1 audio), due 5, fresh 5")
	ok(int(r["at"]) > 0, "at is set (a scan happened)")
	ok(JSON.stringify(SongDue.cache) == JSON.stringify(r), "scan() result equals the cache")
	ok(SongDue.due_lines() == 5, "due_lines() == 5")
	r["due"] = 999
	ok(SongDue.due_lines() == 5, "the returned dictionary is a copy (changing it leaves the cache alone)")
	eqc(SongDue.scan(lister_of({"list": [], "memo": {}})), [0, 0, 0, 0], "no songs -> zeros")
	ok(SongDue.due_lines() == 0, "cache replaced by the empty result")
	var audio_memo := {"list": [{"id": "s_c", "kind": "audio"}], "memo": {"s_c": {"due": 100, "fresh": 100}}}
	eqc(SongDue.scan(lister_of(audio_memo)), [1, 0, 0, 0], "a memo summary on an audio song is ignored")
	var no_kind := {"list": [{"id": "s_x"}], "memo": {"s_x": {"due": 4}}}
	eqc(SongDue.scan(lister_of(no_kind)), [1, 0, 0, 0], "a song without kind counts as audio")
	var missing_memo := {"list": [{"id": "s_a", "kind": "lyrics"}], "memo": {}}
	eqc(SongDue.scan(lister_of(missing_memo)), [1, 1, 0, 0], "a lyrics song without a memo summary: 0 due")
	var lat: bool = false
	var pass_ref := {"n": 0}
	var counting := func() -> Variant:
		pass_ref["n"] = int(pass_ref["n"]) + 1
		return l
	SongDue.scan(counting)
	lat = int(pass_ref["n"]) == 1
	ok(lat, "scan() calls the lister exactly once")


func _bad_lister_values() -> void:
	print("[bad lister values]")
	eqc(SongDue.scan(lister_of(null)), [0, 0, 0, 0], "lister returns null")
	eqc(SongDue.scan(lister_of("oops")), [0, 0, 0, 0], "lister returns a string")
	eqc(SongDue.scan(lister_of(7)), [0, 0, 0, 0], "lister returns an int")
	eqc(SongDue.scan(lister_of({})), [0, 0, 0, 0], "lister returns {}")
	eqc(SongDue.scan(lister_of([1, 2])), [0, 0, 0, 0], "lister returns an array")
	eqc(SongDue.scan(lister_of({"list": "x", "memo": {}})), [0, 0, 0, 0], "list is not an array")
	eqc(SongDue.scan(lister_of({"list": [1, "a", null, [], {"id": "s_a", "kind": "lyrics"}], "memo": {"s_a": {"due": 1}}})), [1, 1, 1, 0], "non-dictionary list items are skipped")
	var bad_memo := {"list": [{"id": "s_a", "kind": "lyrics"}, {"id": "s_b", "kind": "lyrics"}, {"id": "s_c", "kind": "lyrics"}, {"id": "s_d", "kind": "lyrics"}],
		"memo": {"s_a": {}, "s_b": "text", "s_c": {"due": "5", "fresh": null}, "s_d": {"due": -3, "fresh": [1]}}}
	eqc(SongDue.scan(lister_of(bad_memo)), [4, 4, 0, 0], "broken summaries ({}, string, string numbers, negative) count as 0")
	eqc(SongDue.scan(lister_of({"list": [{"id": "s_a", "kind": "lyrics"}], "memo": "x"})), [1, 1, 0, 0], "memo is not a dictionary")
	eqc(SongDue.scan(lister_of({"list": [{"id": "s_a", "kind": "lyrics"}], "memo": {"s_a": {"due": 2.0, "fresh": 1.0}}})), [1, 1, 2, 1], "float counts are accepted")
	eqc(SongDue.scan(lister_of({"list": [{"id": "s_a", "kind": "lyrics"}], "memo": {"s_a": {"due": 1.0e99, "fresh": NAN}}})), [1, 1, SongDue.MAX_COUNT, 0], "huge / NAN counts are capped / zero")
	eqc(SongDue.scan(Callable()), [0, 0, 0, 0], "an empty Callable goes down the default path (blocked here) without error")


func _blocked_guard() -> void:
	print("[test guard]")
	var saved_root: String = SongStore.root
	SongStore.root = SongStore.ROOT
	ok(SongStore.blocked(), "precondition: the real songs folder is blocked in this run")
	var err_before: String = SongStore.last_error
	var warned_before: bool = SongStore._warned
	var r: Dictionary = SongDue.scan()
	eqc(r, [0, 0, 0, 0], "blocked: scan() returns zeros")
	ok(SongStore.last_error == err_before and SongStore._warned == warned_before, "blocked: SongStore was not even asked (no guard warning raised)")
	ok(int(r["at"]) > 0, "blocked: at is set so the 30 s gap logic still works")
	SongStore.root = saved_root


func _real_read_path() -> void:
	print("[real reading path, temp folder]")
	var saved_root: String = SongStore.root
	_rm_rf(TMP)
	SongStore.root = TMP
	ok(not SongStore.blocked(), "temp root is not blocked")
	eqc(SongDue.scan(), [0, 0, 0, 0], "temp folder does not exist yet -> zeros")
	var lines: Array = []
	for t in ["The sky is blue today", "I walk to the sea", "We sing a quiet song"]:
		lines.append({"i": lines.size(), "p": 0, "t0": 0.0, "t1": 0.0, "text": t, "reading": "", "pron": "", "ko": "",
			"conf": null, "est": true, "stale": false, "words": []})
	var song := {"v": 1, "kind": "lyrics", "lang": "en", "title": "Due Test", "artist": "Tester", "created": 1790000000, "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "none", "attribution": ""}, "offset": 0.0,
		"lines": lines, "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [], "app": "1.4.0"}
	var inst: Dictionary = SongStore.install_lyrics(song)
	ok(bool(inst.get("ok", false)), "installed one lyrics song into the temp folder")
	var r: Dictionary = SongDue.scan()
	ok(int(r["songs"]) == 1 and int(r["lyrics"]) == 1, "default path: 1 song, 1 lyrics song")
	ok(int(r["due"]) == 0 and int(r["fresh"]) >= 1, "default path: a never-practiced song has fresh lines but nothing due (fresh=%d)" % int(r["fresh"]))
	SongStore.root = saved_root
	_rm_rf(TMP)
	ok(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TMP)), "temp songs folder removed")


func _gap() -> void:
	print("[needs_scan gap]")
	SongDue.cache = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": 0}
	ok(SongDue.needs_scan(1000), "never scanned -> scan")
	SongDue.cache["at"] = 1000
	ok(not SongDue.needs_scan(1010), "10 s later -> skip")
	ok(not SongDue.needs_scan(1029), "29 s later -> skip")
	ok(SongDue.needs_scan(1030), "30 s later -> scan")
	ok(SongDue.needs_scan(990), "clock went backwards -> scan")
	var wrong: bool = not SongDue.needs_scan(1010)
	var fail_probe: bool = SongDue.needs_scan(1010) # 일부러 반대로 기대: 10초 뒤에 true 라고 믿는 검사는 실패해야 한다
	print("selfcheck %s needs_scan(10 s) expected true" % ("FAIL-as-expected" if not fail_probe else "UNEXPECTED-PASS"))
	ok(wrong and not fail_probe, "a check that expects a rescan after 10 s fails")
	SongDue.cache = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": 0}


func _rm_rf(path: String) -> void:
	var g: String = ProjectSettings.globalize_path(path)
	var d := DirAccess.open(g)
	if d == null:
		return
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(g.path_join(f))
	DirAccess.remove_absolute(g)


func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("dir:" + n)
	out.sort()
	return out
