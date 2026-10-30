extends Node
## 노래 공부 G2: SongModel.normalize (곡 JSON 보정). 서버·파일·마이크를 쓰지 않는다 (순수 함수 시험).
##   godot --headless --path <project> res://tests/song_model_test.tscn
## Exit code 0 = all passed. Last line: "== song_model_test result: N passed, 0 failed =="
## 가사는 시험용으로 직접 쓴 문장뿐이다.

var passed: int = 0
var failed: int = 0
var _reached_end: bool = false


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _line(i: int, t0: float, t1: float, text: String) -> Dictionary:
	return {"i": i, "p": 0, "t0": t0, "t1": t1, "text": text, "reading": "", "pron": "", "ko": "", "conf": 0.8,
		"est": false, "stale": false, "words": [{"w": "blue", "lemma": "blue", "level": "easy", "zipf": 5.1, "s": t0, "e": t1, "est": false, "content": true}]}


func _song() -> Dictionary:
	return {"v": 1, "id": "s_3fa9c1d20b7e", "lang": "en", "title": "Test Song", "artist": "Tester", "created": 1790000000,
		"duration": 60.0,
		"audio": {"file": "audio.mp3", "bytes": 100, "sha256": "a".repeat(64), "orig_name": "x.m4a"},
		"source": {"lyrics": "pasted", "lrclib_id": null, "timing": "line", "attribution": ""},
		"offset": 0.0,
		"lines": [_line(0, 1.0, 3.0, "The sky is blue today"), _line(1, 4.0, 6.0, "I walk to the sea"), _line(2, 7.0, 9.0, "ZZSONGLINEZZ")],
		"glossary": {"blue": {"pos": "형용사", "ko": "파란", "ipa": "bluː", "pron": ""}},
		"marks": {"lines": [1], "words": ["blue"]},
		"stats": {"plays": 2, "last": 1790000500, "best": {"1": 88}},
		"warnings": ["low_match"], "app": "1.4.0"}


func _ready() -> void:
	print("== song_model_test start ==")
	_test_basic()
	_test_times()
	_test_order_and_remap()
	_test_limits()
	_test_strings()
	_test_unknown_and_version()
	_test_bad_types()
	_test_helpers()
	_reached_end = true
	ok(_reached_end, "ran to the end of every section")
	print("== song_model_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _test_basic() -> void:
	print("[valid song passes unchanged]")
	var raw := _song()
	var n: Dictionary = SongModel.normalize(raw)
	ok(not n.is_empty(), "normalize returns a song")
	ok(n["v"] == 1 and n["id"] == "s_3fa9c1d20b7e" and n["lang"] == "en", "v / id / lang kept")
	ok(n["title"] == "Test Song" and n["artist"] == "Tester", "title / artist kept")
	ok((n["lines"] as Array).size() == 3, "3 lines kept")
	ok(n["lines"][0]["text"] == "The sky is blue today" and absf(float(n["lines"][1]["t0"]) - 4.0) < 0.0001, "line text and time kept")
	ok(n["lines"][2]["i"] == 2, "line numbers are 0.. in order")
	ok(n["lines"][0]["words"][0]["level"] == "easy" and n["lines"][0]["words"][0]["lemma"] == "blue", "word kept")
	ok(n["audio"]["bytes"] == 100 and n["audio"]["sha256"] == "a".repeat(64) and n["audio"]["orig_name"] == "x.m4a", "audio meta kept")
	ok(n["glossary"]["blue"]["ko"] == "파란", "glossary kept")
	ok(n["marks"]["lines"] == [1] and n["marks"]["words"] == ["blue"], "marks kept")
	ok(n["stats"]["plays"] == 2 and n["stats"]["best"]["1"] == 88, "stats kept")
	ok(n["warnings"] == ["low_match"] and n["app"] == "1.4.0", "warnings / app kept")
	var again: Dictionary = SongModel.normalize(n)
	ok(JSON.stringify(again) == JSON.stringify(n), "normalize is idempotent")
	ok(raw["lines"][0]["t0"] == 1.0 and raw["title"] == "Test Song", "input is not modified")
	ok(SongModel.normalize("text").is_empty() and SongModel.normalize(null).is_empty() and SongModel.normalize([1]).is_empty(), "non-object input -> {}")
	var e: Dictionary = SongModel.normalize({})
	ok((e["lines"] as Array).is_empty() and e["lang"] == "en" and e["v"] == 1 and e["offset"] == 0.0, "empty object -> blank song")


func _test_times() -> void:
	print("[times]")
	var s := _song()
	s["lines"] = [_line(0, -3.0, 2.0, "a b"), _line(1, 5.0, 4.0, "c d"), _line(2, 8.0, 99.0, "e f"), _line(3, 70.0, 80.0, "g h")]
	var n: Dictionary = SongModel.normalize(s)
	var L: Array = n["lines"]
	ok(L[0]["t0"] == 0.0 and absf(float(L[0]["t1"]) - 2.0) < 0.0001, "negative t0 -> 0")
	ok(float(L[1]["t1"]) > float(L[1]["t0"]), "t1 <= t0 -> t1 > t0")
	ok(float(L[2]["t1"]) == 60.0, "t1 past duration -> duration")
	ok(float(L[3]["t0"]) <= 60.0 and float(L[3]["t1"]) <= 60.0 and float(L[3]["t1"]) > float(L[3]["t0"]), "line after the end is cut into [0, duration] with t1 > t0")
	var all_ok := true
	for ln in L:
		if float(ln["t0"]) < 0.0 or float(ln["t1"]) > float(n["duration"]) or float(ln["t1"]) <= float(ln["t0"]):
			all_ok = false
	ok(all_ok, "every line: 0 <= t0 < t1 <= duration")
	var s2 := _song()
	s2["duration"] = 0.0
	var n2: Dictionary = SongModel.normalize(s2)
	ok(float(n2["duration"]) >= 9.0, "missing duration -> taken from the lines")
	var s3 := _song()
	s3["lines"][0]["words"][0]["s"] = -5.0
	s3["lines"][0]["words"][0]["e"] = 999.0
	var w: Dictionary = SongModel.normalize(s3)["lines"][0]["words"][0]
	ok(float(w["s"]) == 0.0 and float(w["e"]) == 60.0, "word times cut to [0, duration]")


func _test_order_and_remap() -> void:
	print("[order]")
	var s := _song()
	s["lines"] = [_line(0, 9.0, 11.0, "third"), _line(1, 1.0, 3.0, "first"), _line(2, 5.0, 7.0, "second"), _line(3, 5.0, 8.0, "second b")]
	s["marks"] = {"lines": [0, 1, 99, -1], "words": []}
	s["stats"] = {"plays": 0, "last": 0, "best": {"0": 70, "2": 91, "77": 50}}
	var n: Dictionary = SongModel.normalize(s)
	var L: Array = n["lines"]
	ok(L[0]["text"] == "first" and L[1]["text"] == "second" and L[2]["text"] == "second b" and L[3]["text"] == "third", "lines sorted by t0 (ties keep the order)")
	ok(L[0]["i"] == 0 and L[3]["i"] == 3, "line numbers renumbered")
	ok(n["marks"]["lines"] == [0, 3], "marks.lines follow the moved lines, unknown numbers dropped")
	ok(n["stats"]["best"].has("3") and n["stats"]["best"].has("1") and n["stats"]["best"].size() == 2, "stats.best keys follow the moved lines")
	ok(int(n["stats"]["best"]["1"]) == 91, "stats.best values kept")


func _test_limits() -> void:
	print("[limits]")
	var s := _song()
	var many: Array = []
	for i in 401:
		many.append(_line(i, float(i) * 0.1, float(i) * 0.1 + 0.05, "line %d" % i))
	s["lines"] = many
	s["duration"] = 600.0
	s["marks"] = {"lines": [5, 400], "words": []}
	var n: Dictionary = SongModel.normalize(s)
	ok((n["lines"] as Array).size() == 400, "401 lines -> 400")
	ok(n["marks"]["lines"] == [5], "mark on the dropped line is dropped")
	var s2 := _song()
	var words: Array = []
	for i in 81:
		words.append({"w": "w%d" % i, "lemma": "w%d" % i, "level": "mid", "zipf": 3.0, "s": 1.0, "e": 2.0, "est": false, "content": true})
	s2["lines"][0]["words"] = words
	ok((SongModel.normalize(s2)["lines"][0]["words"] as Array).size() == 80, "81 words -> 80")
	var s3 := _song()
	s3["title"] = "x".repeat(500)
	s3["lines"][0]["text"] = "y".repeat(500)
	s3["lines"][0]["ko"] = "k".repeat(500)
	s3["lines"][0]["reading"] = "r".repeat(500)
	s3["glossary"]["blue"]["ko"] = "g".repeat(500)
	var n3: Dictionary = SongModel.normalize(s3)
	ok(n3["title"].length() == SongModel.LEN_TITLE, "500-char title cut")
	ok(n3["lines"][0]["text"].length() == SongModel.LEN_LINE, "500-char line text cut to 200")
	ok(n3["lines"][0]["ko"].length() == SongModel.LEN_KO and n3["lines"][0]["reading"].length() == SongModel.LEN_READING, "500-char ko / reading cut")
	ok(n3["glossary"]["blue"]["ko"].length() == SongModel.LEN_GLOSS, "500-char glossary ko cut")
	var s4 := _song()
	s4["offset"] = 12.3
	ok(SongModel.normalize(s4)["offset"] == 5.0, "offset 12.3 -> 5.0")
	s4["offset"] = -9.0
	ok(SongModel.normalize(s4)["offset"] == -5.0, "offset -9 -> -5.0")
	s4["offset"] = 0.37
	ok(absf(float(SongModel.normalize(s4)["offset"]) - 0.35) < 0.0001, "offset snapped to 0.05")


func _test_strings() -> void:
	print("[strings and enums]")
	var s := _song()
	s["lines"][0]["text"] = "hel\u0002lo\u0001 wor\nld\u007f"
	s["title"] = "tab\there"
	var n: Dictionary = SongModel.normalize(s)
	ok(n["lines"][0]["text"] == "hello world", "control characters removed")
	ok(n["title"] == "tabhere", "tab removed from title")
	var s2 := _song()
	s2["lines"][0]["words"][0]["level"] = "legendary"
	ok(SongModel.normalize(s2)["lines"][0]["words"][0]["level"] == "mid", "unknown level -> mid")
	var s3 := _song()
	s3["lang"] = "fr"
	s3["source"]["lyrics"] = "stolen"
	s3["source"]["timing"] = "magic"
	var n3: Dictionary = SongModel.normalize(s3)
	ok(n3["lang"] == "en" and n3["source"]["lyrics"] == "pasted" and n3["source"]["timing"] == "line", "bad lang / lyrics / timing -> defaults")
	var s4 := _song()
	s4["id"] = "../../x"
	s4["audio"]["file"] = "../../evil.mp3"
	s4["audio"]["sha256"] = "XYZ"
	var n4: Dictionary = SongModel.normalize(s4)
	ok(n4["id"] == "", "bad id -> empty (never used as a path)")
	ok(n4["audio"]["file"] == "evil.mp3" and n4["audio"]["sha256"] == "", "audio file keeps only a file name; bad sha dropped")


func _test_unknown_and_version() -> void:
	print("[unknown keys and version]")
	var s := _song()
	s["future_field"] = {"a": [1, 2, 3]}
	s["lines"][0]["karaoke"] = "yes"
	s["lines"][0]["words"][0]["color"] = "red"
	var n: Dictionary = SongModel.normalize(s)
	ok(n["future_field"]["a"] == [1, 2, 3], "unknown top-level key kept")
	ok(n["lines"][0]["karaoke"] == "yes" and n["lines"][0]["words"][0]["color"] == "red", "unknown line / word keys kept")
	var s2 := _song()
	s2["v"] = 2
	s2["new_thing"] = 7
	var n2: Dictionary = SongModel.normalize(s2)
	ok(n2["v"] == 2 and SongModel.is_read_only(n2), "v:2 -> read only")
	ok(n2["new_thing"] == 7, "v:2 keeps unknown keys")
	ok(not SongModel.is_read_only(SongModel.normalize(_song())), "v:1 is not read only")
	var s3 := _song()
	s3["v"] = "banana"
	ok(SongModel.normalize(s3)["v"] == 1, "bad v -> 1")
	s3["v"] = -4
	ok(SongModel.normalize(s3)["v"] == 1, "v below 1 -> 1")


func _test_bad_types() -> void:
	print("[wrong types]")
	var s := _song()
	s["lines"] = "not an array"
	s["glossary"] = [1, 2]
	s["marks"] = 5
	s["stats"] = "x"
	s["audio"] = null
	s["warnings"] = {"a": 1}
	s["duration"] = "long"
	s["created"] = NAN
	var n: Dictionary = SongModel.normalize(s)
	ok((n["lines"] as Array).is_empty() and (n["glossary"] as Dictionary).is_empty(), "lines / glossary of the wrong type -> empty")
	ok(n["marks"]["lines"] == [] and n["stats"]["plays"] == 0 and n["audio"]["bytes"] == 0 and n["warnings"] == [], "marks / stats / audio / warnings of the wrong type -> blank")
	ok(n["duration"] == 0.0 and n["created"] == 0, "NaN / string numbers -> 0")
	var s2 := _song()
	s2["lines"] = [5, "x", null, _line(0, 1.0, 2.0, "keep"), [1], {"text": 3, "t0": "a", "t1": INF}]
	var n2: Dictionary = SongModel.normalize(s2)
	ok((n2["lines"] as Array).size() == 2 and n2["lines"][1]["text"] == "keep", "non-object lines dropped, the object lines kept")
	ok(n2["lines"][0]["text"] == "" and float(n2["lines"][0]["t1"]) > float(n2["lines"][0]["t0"]), "line with NaN/INF/string fields still gets valid times (sorted first at t0 0)")
	var s3 := _song()
	s3["lines"][0]["conf"] = "high"
	s3["lines"][1]["conf"] = 7.5
	var n3: Dictionary = SongModel.normalize(s3)
	ok(n3["lines"][0]["conf"] == null and n3["lines"][1]["conf"] == 1.0, "conf: non-number -> null, above 1 -> 1")


func _test_helpers() -> void:
	print("[helpers]")
	ok(SongModel.is_valid_id("s_0123456789ab"), "valid id")
	ok(not SongModel.is_valid_id("s_0123456789AB") and not SongModel.is_valid_id("s_0123456789a") and not SongModel.is_valid_id("../etc/passwd") and not SongModel.is_valid_id(5), "invalid ids rejected (upper case, short, path, non-string)")
	ok(SongModel.clean_str("a\u0002b", 10) == "ab" and SongModel.clean_str(5, 10) == "", "clean_str")
	ok(SongModel.hex64("A".repeat(64)) == "a".repeat(64) and SongModel.hex64("g".repeat(64)) == "" and SongModel.hex64("a") == "", "hex64")
