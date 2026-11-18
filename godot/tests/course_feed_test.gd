extends Node
## CourseFeed: CourseData -> LessonBuilder data (v2.0 E3, docs/v200_design.md §10.1, §10.4, §14 E3).
##   PC   : godot --headless --path <project>/godot res://tests/course_feed_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_feed_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== course_feed_test: N passed, M failed ==".
## Data: the E2 fixture tests/fixtures/course_builder/k1_mini (K1 build output, with manifest) read through CourseData.base_dir,
## plus broken copies written under user://test_e3_feed (removed at the end; the user:// listing is compared before / after).
## Every exercise is checked by LexiconGuard AND by a second, separately written token oracle (this file). The checkers are also
## fed planted violations (lines "selfcheck FAIL-as-expected ...").

const K1 := "res://tests/fixtures/course_builder/k1_mini"
const TMP := "user://test_e3_feed"
const KINDS := ["new", "listen", "speak", "check", "month", "recap"]
const FILES := ["en_weeks.json", "en_lexicon.json", "en_patterns.json", "en_sentences.json", "en_dialogues.json", "en_speak_prompts.json"]
const WEEKS_IN_DATA := [1, 2, 4]

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved_base: String = ""


func _ready() -> void:
	print("== course_feed_test start ==")
	_before = _user_listing()
	_saved_base = CourseData.base_dir
	_selfcheck()
	_data_shape()
	_cache()
	_sweep()
	_missing_week()
	_month_prompts()
	_broken_data()
	_source_scan()
	_cleanup()
	CourseData.base_dir = _saved_base
	CourseData.reset()
	CourseFeed.reset()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_feed_test: %d passed, %d failed ==" % [passed, failed])
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


func _use(dir: String) -> void:
	CourseData.base_dir = dir
	CourseData.reset()
	CourseFeed.reset()


func _cleanup() -> void:
	_rm_tree(TMP)


func _rm_tree(p: String) -> void:
	var da := DirAccess.open(p)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in da.get_directories():
		_rm_tree(p.path_join(sub))
	DirAccess.remove_absolute(p)


func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


## Writes {file name: text} plus a matching course_manifest.json into dir (user://).
func _write_course(dir: String, files: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var entries: Array = []
	for name in files.keys():
		var bytes: PackedByteArray = (files[name] as String).to_utf8_buffer()
		var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		entries.append({"path": name, "bytes": bytes.size(), "sha256": _sha(bytes), "records": 0})
	var m := FileAccess.open(dir.path_join("course_manifest.json"), FileAccess.WRITE)
	m.store_string(JSON.stringify({"v": 1, "lang": "en", "files": entries}))
	m.close()


func _copy_k1(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for name in FILES + ["course_manifest.json"]:
		var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		f.store_buffer(FileAccess.get_file_as_bytes(K1.path_join(name)))
		f.close()


# ---------------------------------------------------------------- oracle (written separately from LexiconGuard)

## Lowercase tokens a learner may meet at order `cur_o`: every word (en, forms, say) whose o is <= cur_o.
func _allowed(cur_o: int) -> Dictionary:
	var out: Dictionary = {}
	var data: Dictionary = CourseFeed.plain_data()
	for wd in data["words"]:
		if int(wd.get("o", 0)) > cur_o:
			continue
		for src in [str(wd.get("en", "")), str(wd.get("say", ""))]:
			for t in _tokens(src):
				out[t] = true
		for f in wd.get("forms", []):
			for t in _tokens(str(f.get("f", ""))):
				out[t] = true
	return out


func _tokens(text: String) -> Array:
	var rx := RegEx.new()
	rx.compile("[A-Za-z']+")
	var out: Array = []
	for m in rx.search_all(text):
		out.append(m.get_string().to_lower().lstrip("'").rstrip("'"))
	return out


## Unknown tokens in the spoken texts of an exercise (tts, target, prompt_en, prompt).
func _oracle_bad(ex: Dictionary, cur_o: int) -> Array:
	var allowed: Dictionary = _allowed(cur_o)
	var bad: Array = []
	for key in ["tts", "target", "prompt_en"]:
		if ex.get(key) is String:
			for t in _tokens(ex[key]):
				if t != "" and not allowed.has(t):
					bad.append("%s:%s" % [key, t])
	return bad


## Violations of one built unit: [] = clean. Uses LexiconGuard (with the cards seen so far) and the oracle.
func _violations(res: Dictionary, data: Dictionary, cur_o: int) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var idx: Dictionary = data["_idx"]
	var allowed: Dictionary = _allowed(cur_o)
	for ex in res["exercises"]:
		var g: Dictionary = LexiconGuard.check_exercise_set(ex, cur_o, seen, idx)
		if not bool(g["ok"]):
			out.append("guard:%s" % str(ex.get("id", "?")))
		for key in ["tts", "target", "prompt_en"]:
			if ex.get(key) is String:
				for t in _tokens(ex[key]):
					if t != "" and not allowed.has(t):
						out.append("oracle:%s:%s" % [str(ex.get("id", "?")), t])
		if str(ex.get("type", "")) == "teach_word":
			seen[str(ex.get("item", ""))] = true
	return out


# ---------------------------------------------------------------- checks

func _selfcheck() -> void:
	_use(K1)
	var data: Dictionary = CourseFeed.builder_data()
	# a planted exercise: a word that was never taught ("zebra") and a future word ("colour" is taught in week 4 day 4)
	var poison: Dictionary = {"type": "listen", "id": "x:1:1:lis:poison", "mode": "choose_ko", "tts": "Hello zebra", "options": ["a", "b"], "answer": 0}
	var bad: Array = _oracle_bad(poison, 11)
	print("selfcheck %s oracle flags the planted word zebra (%s)" % ["FAIL-as-expected" if not bad.is_empty() else "UNEXPECTED-PASS", str(bad)])
	ok(not bad.is_empty(), "selfcheck: the token oracle flags a planted unknown word")
	var future: Dictionary = {"type": "listen", "id": "x:1:1:lis:future", "mode": "choose_ko", "tts": "Good colour.", "options": ["a", "b"], "answer": 0}
	var v: Array = _violations({"exercises": [future]}, data, 11)
	print("selfcheck %s the violation counter flags a future word (%s)" % ["FAIL-as-expected" if not v.is_empty() else "UNEXPECTED-PASS", str(v.size())])
	ok(not v.is_empty(), "selfcheck: the violation counter flags a week-4 word on day 1 of week 1")
	var clean: Dictionary = {"type": "listen", "id": "x:1:1:lis:ok", "mode": "choose_ko", "tts": "Hello.", "options": ["a", "b"], "answer": 0}
	ok(_oracle_bad(clean, 11).is_empty(), "the token oracle accepts a clean exercise (no false alarm)")
	var real: Dictionary = CourseFeed.build_unit({"kind": "listen", "w": 1, "d": 1, "seen": []}, 3)
	ok(_violations(real, data, 11).is_empty(), "the violation counter accepts a real built unit (no false alarm)")
	var wrong_count: bool = (data["words"] as Array).size() == 24
	print("selfcheck %s a words count of 24 is not what the fixture gives" % ("FAIL-as-expected" if not wrong_count else "UNEXPECTED-PASS"))
	ok(not wrong_count, "selfcheck: the fixture has 23 words, not 24")


func _data_shape() -> void:
	_use(K1)
	var data: Dictionary = CourseFeed.builder_data()
	ok(not data.is_empty(), "builder_data() is not empty for the K1 fixture")
	for k in ["weeks", "words", "patterns", "sentences", "dialogues", "speak_prompts"]:
		ok(data.has(k) and data[k] is Array, "builder_data()[%s] is an Array" % k)
	eq((data["weeks"] as Array).size(), 3, "3 weeks (1, 2, 4)")
	eq((data["words"] as Array).size(), 23, "23 words")
	eq((data["patterns"] as Array).size(), 5, "5 patterns")
	eq((data["sentences"] as Array).size(), 38, "38 sentences")
	eq((data["dialogues"] as Array).size(), 3, "3 dialogues")
	eq((data["speak_prompts"] as Array).size(), 1, "1 month-end prompt group")
	ok(data.has("_idx") and data["_idx"] is Dictionary, "builder_data() carries the prepared index (_idx)")
	var plain: Dictionary = CourseFeed.plain_data()
	ok(not plain.has("_idx") and plain.size() == 6, "plain_data() has the six arrays and no index")
	var grp: Dictionary = (data["speak_prompts"] as Array)[0]
	ok(grp.has("month") and grp.has("w") and grp["prompts"] is Array, "speak_prompts element is {month, w, prompts:[...]}")
	var p0: Dictionary = (grp["prompts"] as Array)[0]
	for k in ["id", "kind", "en", "ko", "say", "expect_any", "o"]:
		ok(p0.has(k), "prompt has %s" % k)
	ok(p0["o"] is int and grp["w"] is int and grp["month"] is int, "prompt numbers are ints (whole floats converted)")
	ok(["read", "answer", "question", "intro"].has(str(p0["kind"])), "prompt kind is one of read/answer/question/intro")
	eq(CourseFeed.status(), {"ok": true, "err_code": "", "text_ko": ""}, "status() is ok")


func _cache() -> void:
	_use(K1)
	var n0: int = CourseFeed.prepare_count
	var a: Dictionary = CourseFeed.builder_data()
	for i in 50:
		CourseFeed.builder_data()
	var b: Dictionary = CourseFeed.builder_data()
	ok(is_same(a, b), "builder_data() returns the same cached dictionary every time")
	eq(CourseFeed.prepare_count - n0, 1, "LessonBuilder.prepare ran once for 52 calls")
	var t0: int = Time.get_ticks_usec()
	for i in 100:
		CourseFeed.build_unit({"kind": "new", "w": 2, "d": 3, "seen": []}, i)
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	print("timing: 100 build_unit(new w2 d3) calls = %.1f ms (%.2f ms each, with the cached index)" % [ms, ms / 100.0])
	ok(ms / 100.0 < 100.0, "one unit builds in under 100 ms with the cached index")
	eq(CourseFeed.prepare_count - n0, 1, "100 builds did not prepare again")
	CourseData.reset()
	CourseFeed.builder_data()
	eq(CourseFeed.prepare_count - n0, 2, "after CourseData.reset() the data is prepared again exactly once")
	CourseFeed.reset()
	CourseFeed.builder_data()
	eq(CourseFeed.prepare_count - n0, 3, "CourseFeed.reset() prepares once more")


## weeks 1, 2, 4 x days 1..7 x 6 kinds
func _sweep() -> void:
	_use(K1)
	var data: Dictionary = CourseFeed.builder_data()
	var checked := 0
	var units := 0
	var viol := 0
	var not_ok: Array = []
	var empty_ok := true
	var dropped_total := 0
	for w in WEEKS_IN_DATA:
		var week: Dictionary = CourseData.week(w)
		for d in range(1, 8):
			var day: Dictionary = {}
			for e in week["days"]:
				if int(e["d"]) == d:
					day = e
			var has_content: bool = not (day["words"] as Array).is_empty() or not (day["patterns"] as Array).is_empty()
			for kind in KINDS:
				var res: Dictionary = CourseFeed.build_unit({"kind": kind, "w": w, "d": d, "seen": []}, w * 100 + d)
				units += 1
				dropped_total += int(res["dropped"])
				if kind == "new" and not has_content:
					# nothing new is taught that day (speak / check / free day, or a day without words): empty_day, not a crash
					if bool(res["ok"]) or res["errors"] != ["empty_day"]:
						empty_ok = false
						not_ok.append("%s w%d d%d expected empty_day" % [kind, w, d])
					continue
				if not bool(res["ok"]):
					not_ok.append("%s w%d d%d %s" % [kind, w, d, str(res["errors"])])
					continue
				var v: Array = _violations(res, data, w * 10 + d)
				viol += v.size()
				checked += (res["exercises"] as Array).size()
				if not v.is_empty() and viol < 6:
					print("VIOLATION ", kind, " w", w, " d", d, " ", v)
	print("property sweep: checked %d exercises in %d units, violations %d, dropped %d" % [checked, units, viol, dropped_total])
	ok(not_ok.is_empty(), "every unit of weeks 1, 2, 4 x days 1..7 x 6 kinds is ok (new on a day without new words is empty_day) %s" % str(not_ok))
	ok(empty_ok, "new on a day with nothing new gives ok=false + one error line empty_day")
	eq(units, 126, "126 units were built")
	ok(checked > 800, "more than 800 exercises were checked (%d)" % checked)
	eq(viol, 0, "violations 0 (LexiconGuard re-check and the independent token oracle)")
	eq(dropped_total, 0, "no exercise was dropped by the runtime guard")


func _missing_week() -> void:
	_use(K1)
	var res: Dictionary = CourseFeed.build_unit({"kind": "new", "w": 3, "d": 1, "seen": []}, 1)
	ok(not bool(res["ok"]), "week 3 is not in the data: ok == false")
	eq((res["errors"] as Array).size(), 1, "week 3: exactly one error line")
	eq(res["errors"], ["week_missing"], "week 3: error week_missing")
	eq((res["exercises"] as Array).size(), 0, "week 3: no exercises")
	var res2: Dictionary = CourseFeed.build_unit({"kind": "new", "w": 73, "d": 1, "seen": []}, 1)
	ok(not bool(res2["ok"]) and (res2["errors"] as Array).size() >= 1, "week 73: ok == false with an error line")
	var res3: Dictionary = CourseFeed.build_unit("not a dict", 1)
	ok(not bool(res3["ok"]) and (res3["errors"] as Array).size() >= 1, "a spec that is not a dictionary: ok == false, no crash")


func _month_prompts() -> void:
	_use(K1)
	var res: Dictionary = CourseFeed.build_unit({"kind": "month", "w": 4, "d": 6, "seen": []}, 5)
	ok(bool(res["ok"]), "month unit of week 4 is ok")
	var from_prompts := 0
	var modes: Dictionary = {}
	for ex in res["exercises"]:
		if str(ex.get("prompt_id", "")).begins_with("sp"):
			from_prompts += 1
			modes[str(ex.get("mode", ""))] = true
	eq(from_prompts, 3, "month unit of week 4 uses the 3 speak prompts of the data (read, answer, intro)")
	ok(modes.has("repeat") and modes.has("answer") and modes.has("intro"), "month prompts give repeat, answer and intro exercises")
	# the same unit with the prompts taken away (what a feed that drops speak_prompts would give) must be detectably different
	var stripped: Dictionary = CourseFeed.plain_data().duplicate(false)
	stripped["speak_prompts"] = []
	var res2: Dictionary = LessonBuilder.build({"kind": "month", "w": 4, "d": 6, "seen": []}, stripped, 5)
	var n2 := 0
	for ex in res2["exercises"]:
		if str(ex.get("prompt_id", "")).begins_with("sp"):
			n2 += 1
	print("selfcheck %s month assertion fails without speak_prompts (prompt exercises: %d)" % ["FAIL-as-expected" if n2 != 3 else "UNEXPECTED-PASS", n2])
	ok(n2 != 3, "selfcheck: without speak_prompts the month assertion (3 prompt exercises) would fail")
	var no_month: Dictionary = LessonBuilder.build({"kind": "month", "w": 2, "d": 6, "seen": []}, CourseFeed.builder_data(), 5)
	ok(bool(no_month["ok"]), "month unit of a week without prompts still builds (read-aloud fill)")


func _broken_data() -> void:
	# missing directory
	_use("user://test_e3_feed/does_not_exist")
	var d1: Dictionary = CourseFeed.builder_data()
	ok(d1.is_empty(), "missing course data: builder_data() == {}")
	var st: Dictionary = CourseFeed.status()
	ok(not bool(st["ok"]) and st["err_code"] == "course_missing", "missing course data: status err_code course_missing")
	ok(str(st["text_ko"]).length() > 0 and _has_hangul(str(st["text_ko"])), "missing course data: Korean message")
	var r1: Dictionary = CourseFeed.build_unit({"kind": "new", "w": 1, "d": 1}, 1)
	ok(not bool(r1["ok"]) and (r1["errors"] as Array).size() == 1 and r1["errors"][0] == "course_missing", "missing course data: build_unit gives ok=false + one error line")
	ok(CourseFeed.plain_data().is_empty(), "missing course data: plain_data() == {}")
	# one byte changed in a verified file
	_copy_k1("user://test_e3_feed/corrupt")
	var lex_path := "user://test_e3_feed/corrupt/en_lexicon.json"
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(lex_path)
	bytes[bytes.size() / 2] = (bytes[bytes.size() / 2] + 1) % 256
	var f := FileAccess.open(lex_path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	_use("user://test_e3_feed/corrupt")
	ok(CourseFeed.builder_data().is_empty(), "one changed byte: builder_data() == {}")
	eq(CourseFeed.status()["err_code"], "course_corrupt", "one changed byte: err_code course_corrupt")
	# valid but empty
	var empty_files: Dictionary = {}
	empty_files["en_weeks.json"] = '{"v":1,"lang":"en","weeks":[]}'
	empty_files["en_lexicon.json"] = '{"v":1,"lang":"en","words":[]}'
	empty_files["en_patterns.json"] = '{"v":1,"lang":"en","patterns":[]}'
	empty_files["en_sentences.json"] = '{"v":1,"lang":"en","sentences":[]}'
	empty_files["en_dialogues.json"] = '{"v":1,"lang":"en","dialogues":[]}'
	_write_course("user://test_e3_feed/empty", empty_files)
	_use("user://test_e3_feed/empty")
	ok(CourseData.load_all()["ok"], "empty course files verify fine (the data is just empty)")
	ok(CourseFeed.builder_data().is_empty(), "empty course: builder_data() == {}")
	eq(CourseFeed.status()["err_code"], "course_empty", "empty course: err_code course_empty")
	ok(_has_hangul(str(CourseFeed.status()["text_ko"])), "empty course: Korean message")
	# garbage manifest
	_write_course("user://test_e3_feed/garbage", {"en_weeks.json": "{"})
	var gm := FileAccess.open("user://test_e3_feed/garbage/course_manifest.json", FileAccess.WRITE)
	gm.store_string("[1,2")
	gm.close()
	_use("user://test_e3_feed/garbage")
	ok(CourseFeed.builder_data().is_empty() and CourseFeed.status()["err_code"] == "course_corrupt", "broken manifest JSON: {} and course_corrupt")
	# back to good data: the cache recovers
	_use(K1)
	ok(not CourseFeed.builder_data().is_empty() and bool(CourseFeed.status()["ok"]), "good data again after the broken ones: builder_data() works")
	ok(bool(CourseFeed.build_unit({"kind": "listen", "w": 1, "d": 1, "seen": []}, 1)["ok"]), "good data again: a unit builds")


func _has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


func _source_scan() -> void:
	var text: String = FileAccess.get_file_as_string("res://scripts/core/course_feed.gd")
	ok(text.length() > 0, "course_feed.gd is readable")
	for bad in ["FileAccess", "HTTPRequest", "OS.shell_open", "add_path_lesson", "8770", "8775", "8776", "randi()", "randf()"]:
		ok(not text.contains(bad), "course_feed.gd has no %s" % bad)
