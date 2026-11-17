extends Node
## CourseData (v2.0 course data loader): good data, lookups, broken data. Design docs/v200_design.md §14 E1-2, E1-3, E1-9.
##   PC   : godot --headless --path <project> res://tests/course_data_test.tscn
##   Phone: godot --headless --path <project> --resolution 412x915 res://tests/course_data_test.tscn -- --phone --api=http://127.0.0.1:9
## Exit code 0 = all passed. Last line: "== course_data_test: N passed, M failed ==".
## Reads res://tests/fixtures/course_mini; broken copies are written to user://test_course_* and removed again.
## The checker functions are also fed deliberately wrong input (lines "selfcheck FAIL-as-expected ...").

const FIX := "res://tests/fixtures/course_mini"
const TMP := "user://test_course_data"

var passed: int = 0
var failed: int = 0
var _before: Array = []


func _ready() -> void:
	print("== course_data_test start ==")
	_before = _user_listing()
	_selfcheck()
	_good_data()
	_lookups()
	_caching()
	_broken_data()
	_manifest_problems()
	_record_problems()
	_performance()
	_source_scan()
	_cleanup()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	CourseData.base_dir = CourseData.DEFAULT_DIR
	CourseData.reset()
	print("== course_data_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


# ---------------------------------------------------------------- helpers

## Loads `dir` from scratch; returns the load_all() result.
func load_dir(dir: String) -> Dictionary:
	CourseData.reset()
	CourseData.base_dir = dir
	return CourseData.load_all()


func read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func copy_fixture(dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	for n in ["course_manifest.json", "en_weeks.json", "en_lexicon.json", "en_patterns.json", "en_sentences.json",
			"en_dialogues.json", "en_speak_prompts.json"]:
		write_bytes(dst.path_join(n), FileAccess.get_file_as_bytes(FIX.path_join(n)))


func write_bytes(path: String, b: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


## Same-size text change that keeps the JSON valid: only the hash can tell (manifest left as it was).
func flip_text(dir: String, name: String, from: String, to: String) -> void:
	var p: String = dir.path_join(name)
	var text: String = FileAccess.get_file_as_string(p)
	assert(text.contains(from) and from.length() == to.length())
	write_text(p, text.replace(from, to))


func sha(path: String) -> String:
	return FileAccess.get_sha256(path)


## Writes `text` as file `name` of `dir` and updates the manifest entry (size + hash), so only the content is "wrong".
func put_file(dir: String, name: String, text: String) -> void:
	write_text(dir.path_join(name), text)
	var man: Dictionary = read_json(dir.path_join("course_manifest.json"))
	for e in man["files"]:
		if e["path"] == name:
			e["bytes"] = FileAccess.get_file_as_bytes(dir.path_join(name)).size()
			e["sha256"] = sha(dir.path_join(name))
	write_text(dir.path_join("course_manifest.json"), JSON.stringify(man))


func put_manifest(dir: String, man: Variant) -> void:
	write_text(dir.path_join("course_manifest.json"), JSON.stringify(man))


func fresh(name: String) -> String:
	var d: String = TMP + "_" + name
	remove_dir(d)
	copy_fixture(d)
	return d


func remove_dir(d: String) -> void:
	var da := DirAccess.open(d)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(d.path_join(f))
	DirAccess.remove_absolute(d)


func has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _cleanup() -> void:
	var d := DirAccess.open("user://")
	if d == null:
		return
	for n in d.get_directories():
		if n.begins_with("test_course_"):
			remove_dir("user://" + n)


# ---------------------------------------------------------------- checks

## The checks must be able to fail: wrong expectations about the good fixture and about a broken copy are false.
func _selfcheck() -> void:
	var good: Dictionary = load_dir(FIX)
	var wrongly_corrupt: bool = good["err_code"] == CourseData.ERR_CORRUPT
	print("selfcheck %s good fixture is not reported as corrupt" % ("FAIL-as-expected" if not wrongly_corrupt else "UNEXPECTED-PASS"))
	ok(not wrongly_corrupt, "selfcheck: the good fixture is not corrupt")
	var d: String = fresh("self")
	flip_text(d, "en_weeks.json", "\"kind\":\"new\"", "\"kind\":\"nex\"")
	var bad: Dictionary = load_dir(d)
	var wrongly_ok: bool = bool(bad["ok"])
	print("selfcheck %s a 1-byte change is not reported as ok" % ("FAIL-as-expected" if not wrongly_ok else "UNEXPECTED-PASS"))
	ok(not wrongly_ok, "selfcheck: a 1-byte change is not ok")
	var bad_week: bool = CourseData.week(1).is_empty()
	print("selfcheck %s week(1) of the corrupt weeks file is empty (a check 'week(1) is filled' would fail)" % ("FAIL-as-expected" if bad_week else "UNEXPECTED-PASS"))
	ok(bad_week, "selfcheck: week(1) is empty when en_weeks.json is corrupt")


func _good_data() -> void:
	var r: Dictionary = load_dir(FIX)
	ok(bool(r["ok"]), "fixture loads ok")
	eq(r["err_code"], "", "fixture: err_code empty")
	eq(r["text_ko"], "", "fixture: text_ko empty")
	eq(CourseData.available_weeks(), 3, "available_weeks == 3")
	var st: Dictionary = CourseData.stats()
	eq(int(st["weeks"]), 3, "stats: 3 weeks")
	eq(int(st["words"]), 30, "stats: 30 words")
	eq(int(st["sentences"]), 40, "stats: 40 sentences")
	eq(int(st["dialogues"]), 2, "stats: 2 dialogues")
	eq(int(st["patterns"]), 5, "stats: 5 patterns")
	eq(int(st["skipped"]), 0, "stats: nothing skipped")
	for n in r["files"].keys():
		eq(r["files"][n], "ok", "file status ok: " + str(n))
	# Fields exactly as in the file (compare with a direct parse of the same file).
	var raw: Dictionary = read_json(FIX.path_join("en_weeks.json"))
	for w in [1, 2, 3]:
		var want: Dictionary = raw["weeks"][w - 1]
		var got: Dictionary = CourseData.week(w)
		eq(str(got.get("title_ko")), str(want["title_ko"]), "week(%d).title_ko" % w)
		eq(int(got["k"]), int(want["k"]), "week(%d).k" % w)
		eq(got["words"]["new"].size(), want["words"]["new"].size(), "week(%d) new words count" % w)
		eq(got["days"].size(), 7, "week(%d) has 7 days" % w)
	eq(typeof(CourseData.week(1)["w"]), TYPE_INT, "week.w is an int (not 1.0)")
	eq(typeof(CourseData.week(1)["days"][0]["d"]), TYPE_INT, "week.days[0].d is an int")
	var w11: Dictionary = CourseData.word("w0011")
	eq(w11["en"], "I", "word w0011 en")
	eq(w11["ko"], "나", "word w0011 ko")
	eq(typeof(w11["o"]), TYPE_INT, "word.o is an int")
	eq(int(w11["o"]), 21, "word w0011 o == 21")
	eq(w11["role"], "active", "word role active")
	eq(CourseData.word("w0029")["role"], "passive", "word w0029 passive")
	eq(CourseData.word("w0030")["ca"], true, "word w0030 ca note")
	eq(CourseData.word("w0027")["alt"], ["gray"], "word w0027 alt spelling")
	eq(CourseData.word("w0024")["forms"][0]["f"], "apples", "word w0024 forms")
	var s17: Dictionary = CourseData.sentence("s0017")
	eq(s17["en"], "My name is Min.", "sentence s0017 en")
	eq(s17["ko"], "제 이름은 민이에요.", "sentence s0017 ko")
	eq(int(s17["o"]), 24, "sentence s0017 o == 24")
	eq(CourseData.sentence("s0039")["src"], "tatoeba", "sentence s0039 src")
	eq(int(CourseData.sentence("s0039")["tid"]), 90001, "sentence s0039 tid")
	var p: Dictionary = CourseData.pattern("p_my_name_is")
	eq(p["tpl"], "My name is ___.", "pattern tpl")
	eq(p["grammar_ko"].size(), 2, "pattern grammar_ko lines")
	var d2: Dictionary = CourseData.dialogue("d0002")
	eq(d2["lines"].size(), 3, "dialogue d0002 has 3 lines")
	eq(d2["lines"][1]["s"], "B", "dialogue line speaker")
	eq(typeof(d2["lines"][0]["o"]), TYPE_INT, "dialogue line o is an int")
	eq(CourseData.lexicon().size(), 30, "lexicon() has 30 entries")
	ok(CourseData.lexicon().has("w0030"), "lexicon() keyed by id")
	eq(CourseData.speak_prompts().size(), 1, "speak_prompts() has the month entry")
	# sentences_for: counts agree with a direct count over the file, and are sorted by o then id.
	var all: Array = read_json(FIX.path_join("en_sentences.json"))["sentences"]
	var total := 0
	for w in [1, 2, 3]:
		var want_n := 0
		for s in all:
			if int(s["o"]) / 10 == w:
				want_n += 1
		var got_list: Array = CourseData.sentences_for(w)
		eq(got_list.size(), want_n, "sentences_for(%d) count" % w)
		total += got_list.size()
		var sorted_ok := true
		for i in range(1, got_list.size()):
			var a: Dictionary = got_list[i - 1]
			var b: Dictionary = got_list[i]
			if int(a["o"]) > int(b["o"]) or (int(a["o"]) == int(b["o"]) and str(a["id"]) > str(b["id"])):
				sorted_ok = false
		ok(sorted_ok, "sentences_for(%d) sorted by o then id" % w)
		for s in got_list:
			if int(s["o"]) / 10 != w:
				ok(false, "sentences_for(%d) only holds week %d sentences" % [w, w])
				break
	eq(total, 40, "sentences_for(1..3) cover all 40 sentences")


func _lookups() -> void:
	load_dir(FIX)
	for bad in ["zzz", "", "w9999", null, 5, 1.5, [], {}]:
		eq(CourseData.word(bad), {}, "word(%s) -> {}" % str(bad))
		eq(CourseData.sentence(bad), {}, "sentence(%s) -> {}" % str(bad))
		eq(CourseData.pattern(bad), {}, "pattern(%s) -> {}" % str(bad))
		eq(CourseData.dialogue(bad), {}, "dialogue(%s) -> {}" % str(bad))
	for bad_w in [0, 4, 73, -5, null, "x", "", 2.5e9, [], {}, true]:
		eq(CourseData.week(bad_w), {}, "week(%s) -> {} (outside the 3 weeks)" % str(bad_w))
		eq(CourseData.sentences_for(bad_w), [], "sentences_for(%s) -> []" % str(bad_w))
	ok(not CourseData.week("2").is_empty(), "week(\"2\") accepts an integer string")
	ok(not CourseData.week(2.0).is_empty(), "week(2.0) accepts a whole float")
	eq(CourseData.dialogue("d0001")["w"], 1, "dialogue d0001 w")


func _caching() -> void:
	var r1: Dictionary = load_dir(FIX)
	var r2: Dictionary = CourseData.load_all()
	ok(r1 == r2, "load_all() twice gives the same result")
	CourseData.base_dir = "user://test_course_nothing_here"
	ok(bool(CourseData.load_all()["ok"]), "load_all() is cached until reset() (base_dir change alone does nothing)")
	CourseData.reset()
	eq(CourseData.load_all()["err_code"], CourseData.ERR_MISSING, "after reset() the new base_dir is read: course_missing")
	eq(CourseData.available_weeks(), 0, "missing data: available_weeks == 0")
	eq(CourseData.week(1), {}, "missing data: week(1) == {}")
	eq(CourseData.lexicon(), {}, "missing data: lexicon() empty")
	eq(CourseData.DEFAULT_DIR, "res://data/course", "default directory")


func _broken_data() -> void:
	# 1 byte changed in one data file (hash differs, size same).
	var d: String = fresh("flip")
	flip_text(d, "en_sentences.json", "My name is Min.", "My name is Mix.")
	var r: Dictionary = load_dir(d)
	ok(not bool(r["ok"]), "1-byte change: ok == false")
	eq(r["err_code"], "course_corrupt", "1-byte change: course_corrupt")
	ok(has_hangul(str(r["text_ko"])), "1-byte change: text_ko is Korean")
	eq(r["files"]["en_sentences.json"], "course_corrupt", "1-byte change: that file is course_corrupt")
	eq(r["files"]["en_lexicon.json"], "ok", "1-byte change: other files are ok")
	eq(CourseData.sentence("s0017"), {}, "1-byte change: sentences unavailable")
	eq(CourseData.sentences_for(2), [], "1-byte change: sentences_for empty")
	eq(CourseData.word("w0011")["en"], "I", "1-byte change: words still work")
	eq(CourseData.available_weeks(), 3, "1-byte change: weeks still work")
	# size differs (one byte appended)
	d = fresh("size")
	var b2: PackedByteArray = FileAccess.get_file_as_bytes(d.path_join("en_lexicon.json"))
	b2.append(32)
	write_bytes(d.path_join("en_lexicon.json"), b2)
	r = load_dir(d)
	eq(r["err_code"], "course_corrupt", "size differs: course_corrupt")
	eq(CourseData.word("w0011"), {}, "size differs: words unavailable")
	# no manifest
	d = fresh("noman")
	DirAccess.remove_absolute(d.path_join("course_manifest.json"))
	r = load_dir(d)
	ok(not bool(r["ok"]), "no manifest: ok == false")
	eq(r["err_code"], "course_missing", "no manifest: course_missing")
	ok(has_hangul(str(r["text_ko"])), "no manifest: text_ko is Korean")
	eq(CourseData.available_weeks(), 0, "no manifest: available_weeks == 0")
	eq(CourseData.word("w0011"), {}, "no manifest: no word, no error")
	# file listed but absent
	d = fresh("nofile")
	DirAccess.remove_absolute(d.path_join("en_lexicon.json"))
	r = load_dir(d)
	eq(r["err_code"], "course_missing", "file absent: course_missing")
	eq(r["files"]["en_lexicon.json"], "course_missing", "file absent: that file is course_missing")
	eq(CourseData.week(1)["title_ko"], "인사", "file absent: weeks still work")
	eq(CourseData.sentence("s0017")["en"], "My name is Min.", "file absent: sentences still work")
	# a required file that the manifest does not list
	d = fresh("notlisted")
	var man: Dictionary = read_json(d.path_join("course_manifest.json"))
	var kept: Array = []
	for e in man["files"]:
		if e["path"] != "en_patterns.json":
			kept.append(e)
	man["files"] = kept
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_missing", "required file not in manifest: course_missing")
	# broken JSON with a matching hash (so the parser, not the hash, catches it)
	d = fresh("badjson")
	put_file(d, "en_weeks.json", "{\"v\":1,\"weeks\":[{\"w\":1,")
	r = load_dir(d)
	eq(r["err_code"], "course_corrupt", "broken JSON (hash matches): course_corrupt")
	eq(CourseData.available_weeks(), 0, "broken JSON: available_weeks == 0")
	eq(CourseData.word("w0011")["en"], "I", "broken JSON in weeks: words unaffected")
	d = fresh("empty")
	put_file(d, "en_dialogues.json", "")
	eq(load_dir(d)["err_code"], "course_corrupt", "empty file (hash matches): course_corrupt")
	d = fresh("scalar")
	put_file(d, "en_patterns.json", "42")
	eq(load_dir(d)["err_code"], "course_corrupt", "JSON that is a number: course_corrupt")
	# corrupt wins over missing when both happen
	d = fresh("both")
	DirAccess.remove_absolute(d.path_join("en_lexicon.json"))
	flip_text(d, "en_sentences.json", "My name is Min.", "My name is Mix.")
	eq(load_dir(d)["err_code"], "course_corrupt", "missing + corrupt: reported as course_corrupt")


func _manifest_problems() -> void:
	var d: String = fresh("man1")
	write_text(d.path_join("course_manifest.json"), "not json at all")
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest is not JSON: course_corrupt")
	d = fresh("man2")
	write_text(d.path_join("course_manifest.json"), "[1,2,3]")
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest is an array: course_corrupt")
	d = fresh("man3")
	var man: Dictionary = read_json(d.path_join("course_manifest.json"))
	man["v"] = 2
	put_manifest(d, man)
	var r: Dictionary = load_dir(d)
	eq(r["err_code"], "course_corrupt", "manifest version 2: course_corrupt")
	eq(CourseData.available_weeks(), 0, "manifest version 2: nothing loaded")
	d = fresh("man4")
	man = read_json(d.path_join("course_manifest.json"))
	man.erase("v")
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest without v: course_corrupt")
	d = fresh("man5")
	man = read_json(d.path_join("course_manifest.json"))
	man.erase("files")
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest without files: course_corrupt")
	d = fresh("man6")
	man = read_json(d.path_join("course_manifest.json"))
	man["files"] = "oops"
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest files is not a list: course_corrupt")
	d = fresh("man7")
	man = read_json(d.path_join("course_manifest.json"))
	for e in man["files"]:
		if e["path"] == "en_lexicon.json":
			e.erase("sha256")
	put_manifest(d, man)
	r = load_dir(d)
	eq(r["err_code"], "course_corrupt", "manifest entry without sha256: course_corrupt")
	eq(r["files"]["en_lexicon.json"], "course_corrupt", "manifest entry without sha256: only that file")
	eq(CourseData.week(1)["title_ko"], "인사", "manifest entry without sha256: weeks fine")
	d = fresh("man8")
	man = read_json(d.path_join("course_manifest.json"))
	for e in man["files"]:
		if e["path"] == "en_weeks.json":
			e.erase("bytes")
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_corrupt", "manifest entry without bytes: course_corrupt")
	d = fresh("man9")
	man = read_json(d.path_join("course_manifest.json"))
	for e in man["files"]:
		if e["path"] == "en_weeks.json":
			e["sha256"] = "00" + str(e["sha256"]).substr(2)
	put_manifest(d, man)
	eq(load_dir(d)["err_code"], "course_corrupt", "wrong sha256 in manifest: course_corrupt")
	d = fresh("man10")
	man = read_json(d.path_join("course_manifest.json"))
	man["files"].append(42)
	man["files"].append({"nopath": true})
	put_manifest(d, man)
	ok(bool(load_dir(d)["ok"]), "junk entries in the manifest list are ignored")
	# optional prompts file: not listed -> still ok; listed but broken -> corrupt
	d = fresh("man11")
	man = read_json(d.path_join("course_manifest.json"))
	var kept: Array = []
	for e in man["files"]:
		if e["path"] != "en_speak_prompts.json":
			kept.append(e)
	man["files"] = kept
	put_manifest(d, man)
	r = load_dir(d)
	ok(bool(r["ok"]), "speak prompts not listed: still ok")
	eq(CourseData.speak_prompts(), [], "speak prompts not listed: empty list")
	d = fresh("man12")
	put_file(d, "en_speak_prompts.json", "{broken")
	eq(load_dir(d)["err_code"], "course_corrupt", "speak prompts broken: course_corrupt")
	# data file version / container
	d = fresh("ver1")
	put_file(d, "en_weeks.json", "{\"v\":2,\"weeks\":[]}")
	eq(load_dir(d)["err_code"], "course_corrupt", "weeks file version 2: course_corrupt")
	d = fresh("ver2")
	put_file(d, "en_weeks.json", "{\"v\":\"1\",\"weeks\":[]}")
	eq(load_dir(d)["err_code"], "course_corrupt", "weeks file version \"1\" (text): course_corrupt")
	d = fresh("ver3")
	put_file(d, "en_weeks.json", "{\"v\":1}")
	eq(load_dir(d)["err_code"], "course_corrupt", "weeks file without the weeks key: course_corrupt")
	d = fresh("ver4")
	put_file(d, "en_weeks.json", "{\"v\":1,\"weeks\":{\"a\":1}}")
	eq(load_dir(d)["err_code"], "course_corrupt", "weeks key is not a list: course_corrupt")
	d = fresh("ver5")
	put_file(d, "en_lexicon.json", "[{\"id\":\"w1\",\"en\":\"x\",\"o\":11}]")
	r = load_dir(d)
	ok(bool(r["ok"]), "a bare JSON array is accepted as a record list")
	eq(CourseData.word("w1")["en"], "x", "bare array record found")
	eq(typeof(CourseData.word("w1")["o"]), TYPE_INT, "bare array record: o is an int")
	d = fresh("ver6")
	put_file(d, "en_lexicon.json", "{\"lexicon\":[{\"id\":\"w2\",\"en\":\"y\",\"o\":12}]}")
	ok(bool(load_dir(d)["ok"]) and not CourseData.word("w2").is_empty(), "container key alias `lexicon` and a missing v are accepted")


func _record_problems() -> void:
	var d: String = fresh("rec1")
	put_file(d, "en_weeks.json", JSON.stringify({"v": 1, "weeks": [
		{"w": 1, "title_ko": "a"}, {"w": 3, "title_ko": "c"}, {"title_ko": "no w"}, {"w": 0}, {"w": 73}, {"w": "x"},
		{"w": 1, "title_ko": "dup"}, "text", 7, null, {"w": 2.0, "title_ko": "b"}]}))
	var r: Dictionary = load_dir(d)
	ok(bool(r["ok"]), "week records with problems: file still loads")
	eq(CourseData.stats()["weeks"], 3, "weeks 1, 2, 3 kept, the rest skipped")
	eq(CourseData.stats()["skipped"], 8, "8 week records skipped")
	eq(CourseData.week(1)["title_ko"], "a", "duplicate week: the first one wins")
	eq(CourseData.week(2)["title_ko"], "b", "week with w = 2.0 is week 2")
	eq(CourseData.available_weeks(), 3, "weeks 1,2,3 -> available 3")
	d = fresh("rec2")
	put_file(d, "en_weeks.json", JSON.stringify({"v": 1, "weeks": [{"w": 1}, {"w": 3}, {"w": 4}]}))
	load_dir(d)
	eq(CourseData.available_weeks(), 1, "weeks 1,3,4 (gap at 2) -> available 1")
	d = fresh("rec3")
	put_file(d, "en_lexicon.json", JSON.stringify({"v": 1, "words": [
		{"id": "a", "o": 11}, {"id": "a", "o": 12}, {"en": "no id"}, {"id": ""}, {"id": 5}, "x", {"id": "b", "o": 21.0}]}))
	load_dir(d)
	eq(CourseData.lexicon().size(), 2, "words: only a and b kept")
	eq(int(CourseData.word("a")["o"]), 11, "duplicate word id: the first one wins")
	eq(CourseData.stats()["skipped"], 5, "5 word records skipped")
	d = fresh("rec4")
	put_file(d, "en_sentences.json", JSON.stringify({"v": 1, "sentences": [
		{"id": "s1", "o": 25}, {"id": "s2", "o": 21}, {"id": "s0", "o": 21}, {"id": "s3"}, {"id": "s4", "o": "x"}, {"id": "s5", "o": 5}]}))
	load_dir(d)
	var ids: Array = []
	for s in CourseData.sentences_for(2):
		ids.append(s["id"])
	eq(ids, ["s0", "s2", "s1"], "sentences_for(2) sorted by o then id")
	eq(CourseData.sentences_for(0), [], "sentences without a week (o < 10) are in no week")
	d = fresh("rec5")
	put_file(d, "en_dialogues.json", JSON.stringify({"v": 1, "dialogues": [
		{"id": "d1", "lines": [{"s": "A", "o": 11.0}, "junk", {"s": "B"}]}, {"id": "d2"}]}))
	load_dir(d)
	eq(CourseData.dialogue("d1")["lines"].size(), 3, "dialogue keeps its lines")
	eq(typeof(CourseData.dialogue("d1")["lines"][0]["o"]), TYPE_INT, "dialogue line o 11.0 -> int")
	eq(CourseData.dialogue("d2"), {"id": "d2"}, "dialogue without lines is kept as it is")
	ok(CourseData.dialogue("d3").is_empty(), "unknown dialogue -> {}")


func _performance() -> void:
	var d := TMP + "_big"
	remove_dir(d)
	DirAccess.make_dir_recursive_absolute(d)
	var pad := "가나다라마바사아자차카타파하".repeat(4)
	var words: Array = []
	for i in 3000:
		words.append({"id": "w%04d" % (i + 1), "en": "word%d" % i, "pos": "n", "ko": "뜻%d" % i, "ipa": "wɜːd", "say": "", "tags": ["a", "b"],
			"role": "active" if i % 3 != 0 else "passive", "o": (i / 42 + 1) * 10 + i % 7 + 1, "forms": [], "alt": [], "syn": [], "ca": false,
			"src": "own", "note": pad})
	var sents: Array = []
	for i in 3000:
		sents.append({"id": "s%04d" % (i + 1), "en": "This is sentence number %d, it is long enough." % i, "ko": "문장 번호 %d 입니다. %s" % [i, pad],
			"say": "", "words": ["w%04d" % (i % 3000 + 1), "w%04d" % ((i + 1) % 3000 + 1)], "pat": "p_x", "o": (i / 42 + 1) * 10 + i % 7 + 1, "scope": "all",
			"accept": [], "src": "own", "tid": 0})
	var weeks: Array = []
	for w in 72:
		weeks.append({"w": w + 1, "n": w / 4 + 1, "k": w % 4 + 1, "stage": 1, "legacy_stage": 1, "title_ko": "주 %d" % (w + 1),
			"can_do": ["가", "나"], "words": {"new": ["w0001"], "passive": []}, "patterns": ["p_x"], "days": [{"d": 1, "kind": "new", "words": ["w0001"], "patterns": []}]})
	var big := {
		"en_weeks.json": {"v": 1, "weeks": weeks}, "en_lexicon.json": {"v": 1, "words": words},
		"en_patterns.json": {"v": 1, "patterns": [{"id": "p_x", "tpl": "x", "o": 11}]},
		"en_sentences.json": {"v": 1, "sentences": sents}, "en_dialogues.json": {"v": 1, "dialogues": [{"id": "d0001", "lines": []}]},
		"en_speak_prompts.json": {"v": 1, "prompts": []}}
	var entries: Array = []
	var total := 0
	for n in big.keys():
		write_text(d.path_join(n), JSON.stringify(big[n]))
		var size: int = FileAccess.get_file_as_bytes(d.path_join(n)).size()
		total += size
		entries.append({"path": n, "bytes": size, "sha256": sha(d.path_join(n)), "records": 1})
	write_text(d.path_join("course_manifest.json"), JSON.stringify({"v": 1, "files": entries}))
	ok(total >= 1900000 and total <= 2600000, "virtual data is about 2 MB (%d bytes)" % total)
	var t0: int = Time.get_ticks_msec()
	var r: Dictionary = load_dir(d)
	var ms: int = Time.get_ticks_msec() - t0
	print("perf: load + index of %d bytes took %d ms" % [total, ms])
	ok(bool(r["ok"]), "2 MB virtual data loads ok")
	eq(CourseData.stats()["words"], 3000, "perf data: 3000 words")
	eq(CourseData.stats()["sentences"], 3000, "perf data: 3000 sentences")
	ok(ms <= 300, "load + index <= 300 ms (%d ms)" % ms)
	# The timing check must be able to fail: a 1 ms budget on the same measurement is not met.
	var met_1ms: bool = ms <= 1
	print("selfcheck %s load time vs a 1 ms budget" % ("FAIL-as-expected" if not met_1ms else "UNEXPECTED-PASS"))
	ok(not met_1ms, "selfcheck: the 1 ms budget is not met")
	var by: int = CourseData.sentences_for(5).size()
	ok(by > 0, "perf data: sentences_for(5) has sentences (%d)" % by)


func _source_scan() -> void:
	for f in ["res://scripts/core/course_data.gd", "res://scripts/core/course_model.gd"]:
		var src: String = FileAccess.get_file_as_string(f)
		var bad: Array = []
		for w in ["HTTP" + "Request", "shell" + "_open", "request" + "_permission", "87" + "70", "87" + "75", "87" + "76", "Color(" + "\"#", "push" + "_error", "push" + "_warning"]:
			if src.contains(w):
				bad.append(w)
		ok(bad.is_empty(), "%s has no forbidden word %s" % [f.get_file(), str(bad)])
	var word: String = "HTTP" + "Request"
	var fake: String = "var r := " + word + ".new()"
	print("selfcheck %s forbidden-word scan on a fake source" % ("FAIL-as-expected" if fake.contains(word) else "UNEXPECTED-PASS"))
	ok(fake.contains(word), "selfcheck: the forbidden-word scan flags a fake source")
