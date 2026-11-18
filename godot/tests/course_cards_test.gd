extends Node
## CourseCards: review cards of a course day (v2.0 E3, docs/v200_design.md §3.1, §11.1, §14 E3-6, E3-8, E3-10).
##   PC   : godot --headless --path <project>/godot res://tests/course_cards_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_cards_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== course_cards_test: N passed, M failed ==".
## Data: the E2 fixture tests/fixtures/course_builder/k1_mini (K1 build output) and a small course written at run time under
## user://test_e3_cards (passive words, dialogue rules, duplicates). Only user://test_e3_* files are used: Store.progress_path,
## Store.prefs_path, StudyLog.path and CourseStore.path are pointed there and restored; the user:// listing is compared before / after.
## The card checker is also fed deliberately broken cards (lines "selfcheck FAIL-as-expected ...").

const K1 := "res://tests/fixtures/course_builder/k1_mini"
const TMP := "user://test_e3_cards"
const PROG := "user://test_e3_cards_progress.json"
const PREFS := "user://test_e3_cards_prefs.json"
const LOG := "user://test_e3_cards_studylog.json"
const CS := "user://test_e3_cards_course.json"

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved: Dictionary = {}
var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}


func _ready() -> void:
	print("== course_cards_test start ==")
	_before = _user_listing()
	_saved = {"base": CourseData.base_dir, "prog": Store.progress_path, "prefs": Store.prefs_path, "log": StudyLog.path, "cs": CourseStore.path}
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	_selfcheck()
	_k1_cards()
	_k1_bad_days()
	_synthetic_cards()
	_add_unit()
	_add_unit_modes()
	_source_scan()
	_restore()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_cards_test: %d passed, %d failed ==" % [passed, failed])
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


func _rm_tree(p: String) -> void:
	var da := DirAccess.open(p)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in da.get_directories():
		_rm_tree(p.path_join(sub))
	DirAccess.remove_absolute(p)


func _rm_files() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


func _restore() -> void:
	_rm_tree(TMP)
	_rm_files()
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	Store.progress_path = _saved["prog"]
	Store.prefs_path = _saved["prefs"]
	StudyLog.path = _saved["log"]
	CourseStore.path = _saved["cs"]
	CourseStore.reset_memory()
	Store.prefs = _saved_prefs
	Store.progress = _saved_progress


func _use(dir: String) -> void:
	CourseData.base_dir = dir
	CourseData.reset()


func _mode(m: String) -> void:
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	if m != "":
		Store.prefs["course_mode"] = m
	CourseStore.reset_memory()


func _clean_progress() -> void:
	Store.progress = Progress.blank()
	_rm_files()


func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _write_course(dir: String, files: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var entries: Array = []
	for name in files.keys():
		var bytes: PackedByteArray = JSON.stringify(files[name]).to_utf8_buffer()
		var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		entries.append({"path": name, "bytes": bytes.size(), "sha256": _sha(bytes), "records": 0})
	var m := FileAccess.open(dir.path_join("course_manifest.json"), FileAccess.WRITE)
	m.store_string(JSON.stringify({"v": 1, "lang": "en", "files": entries}))
	m.close()


func _has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


func _targets(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(c["target"])
	return out


## [] when the card is a valid Store.add_review input of a course card, else the problems.
func _card_problems(c: Variant) -> Array:
	var bad: Array = []
	if not (c is Dictionary):
		return ["not a dictionary"]
	if c.get("lang") != "en":
		bad.append("lang")
	if not (c.get("target") is String) or String(c["target"]).strip_edges() == "" or String(c["target"]).length() > 300:
		bad.append("target")
	elif _has_hangul(c["target"]):
		bad.append("target has Korean")
	if not (c.get("ko") is String) or not _has_hangul(c["ko"]):
		bad.append("ko")
	if not (c.get("reading") is String):
		bad.append("reading")
	var rx := RegEx.new()
	rx.compile("^코스 \\d{1,2}주 \\d일 · (단어|문형|대화)$")
	if not (c.get("note") is String) or rx.search(c["note"]) == null:
		bad.append("note")
	return bad


# ---------------------------------------------------------------- checks

func _selfcheck() -> void:
	_use(K1)
	var wrong_count: bool = CourseCards.unit_cards(1, 1).size() == 4
	print("selfcheck %s week 1 day 1 does not give 4 cards" % ("FAIL-as-expected" if not wrong_count else "UNEXPECTED-PASS"))
	ok(not wrong_count, "selfcheck: week 1 day 1 has 3 cards, not 4")
	var broken: Array = [
		{"lang": "ja", "target": "hello", "ko": "안녕", "reading": "", "note": "코스 1주 1일 · 단어"},
		{"lang": "en", "target": "", "ko": "안녕", "reading": "", "note": "코스 1주 1일 · 단어"},
		{"lang": "en", "target": "안녕", "ko": "안녕", "reading": "", "note": "코스 1주 1일 · 단어"},
		{"lang": "en", "target": "hello", "ko": "hello", "reading": "", "note": "코스 1주 1일 · 단어"},
		{"lang": "en", "target": "hello", "ko": "안녕", "reading": "", "note": "코스 1주 1일 · 소리"},
		{"lang": "en", "target": "hello", "ko": "안녕", "reading": "", "note": "복습 카드"},
		{"lang": "en", "target": "x".repeat(301), "ko": "안녕", "reading": "", "note": "코스 1주 1일 · 단어"},
		null,
	]
	var all_flagged := true
	for c in broken:
		var probs: Array = _card_problems(c)
		if probs.is_empty():
			all_flagged = false
		print("selfcheck %s card checker flags %s" % ["FAIL-as-expected" if not probs.is_empty() else "UNEXPECTED-PASS", str(probs)])
	ok(all_flagged, "selfcheck: the card checker flags all 8 deliberately broken cards")
	ok(_card_problems(CourseCards.unit_cards(1, 1)[0]).is_empty(), "the card checker accepts a real card (no false alarm)")


func _k1_cards() -> void:
	_use(K1)
	# day 1: three active words
	var c11: Array = CourseCards.unit_cards(1, 1)
	eq(_targets(c11), ["hello", "hi", "thanks"], "week 1 day 1: the three words")
	eq(c11[0]["ko"], CourseData.word("w0001")["ko"], "the card ko is the word's Korean meaning")
	eq(c11[0]["note"], "코스 1주 1일 · 단어", "note of a word card")
	eq([c11[0]["lang"], c11[0]["reading"]], ["en", ""], "lang en, reading empty")
	var all_ok := true
	for w in [1, 2, 4]:
		for d in range(1, 8):
			for c in CourseCards.unit_cards(w, d):
				if not _card_problems(c).is_empty():
					all_ok = false
	ok(all_ok, "every card of weeks 1, 2, 4 passes the card checker (English target, Korean ko, note format)")
	# day 3: four words + the pattern frame sentence
	var c13: Array = CourseCards.unit_cards(1, 3)
	eq(_targets(c13), ["my", "name", "is", "Min", "My name is Min."], "week 1 day 3: four words, then the pattern's first example")
	eq(c13[4]["note"], "코스 1주 3일 · 문형", "note of a pattern card")
	eq(c13[4]["ko"], CourseData.sentence("s0009")["ko"], "the pattern card ko is the example's Korean")
	# day 4: three words + pattern + dialogue (the learner's line B)
	var c14: Array = CourseCards.unit_cards(1, 4)
	eq(_targets(c14), ["your", "good", "morning", "Good morning.", "Hello, Min."], "week 1 day 4: words, pattern frame, dialogue line")
	eq(c14[4]["note"], "코스 1주 4일 · 대화", "note of a dialogue card")
	# a day with no words still gives the dialogue line (day 4 of week 2)
	eq(_targets(CourseCards.unit_cards(2, 4)), ["Is it three?"], "week 2 day 4: no words, only the dialogue line of the learner")
	eq(_targets(CourseCards.unit_cards(2, 2)), ["it", "It is one."], "week 2 day 2: a word and the pattern frame")
	eq(_targets(CourseCards.unit_cards(4, 2)), ["welcome", "bye", "Hello, friend."], "week 4 day 2: two words and the pattern frame")
	eq(_targets(CourseCards.unit_cards(4, 4)), ["colour", "Good morning, Min."], "week 4 day 4: a word and the dialogue line")
	eq(CourseCards.unit_cards(4, 3).size(), 0, "week 4 day 3 (nothing new): no cards")
	# speak / check / free days teach nothing
	for d in [5, 6, 7]:
		eq(CourseCards.unit_cards(1, d).size(), 0, "week 1 day %d (speak / check / free): no cards" % d)
	# no duplicates inside a day, nothing from other days
	var seen: Dictionary = {}
	var dup := false
	for w in [1, 2, 4]:
		for d in range(1, 8):
			var ts: Array = _targets(CourseCards.unit_cards(w, d))
			var local: Dictionary = {}
			for t in ts:
				if local.has(t):
					dup = true
				local[t] = true
				seen[t] = true
	ok(not dup, "no duplicate target inside one day")
	ok(seen.has("Min") and seen.has("friend") and seen.has("colour"), "targets of all three weeks were collected")
	var total := 0
	for w in [1, 2, 4]:
		for d in range(1, 8):
			total += CourseCards.unit_cards(w, d).size()
	eq(total, 16 + 9 + 6, "all days of weeks 1, 2, 4 together give 31 cards (16 + 9 + 6)")
	eq(CourseCards.note_for(5, 2, "단어"), "코스 5주 2일 · 단어", "note_for(5, 2, 단어)")
	eq(CourseCards.note_for(72, 7, "대화"), "코스 72주 7일 · 대화", "note_for(72, 7, 대화)")
	eq(CourseCards.note_for(0, 2, "단어"), "", "note_for with an invalid week is empty")


func _k1_bad_days() -> void:
	_use(K1)
	for wd in [[3, 1], [0, 1], [73, 1], [1, 0], [1, 8], ["x", 1], [null, 1], [1, null], [-1, -1], [NAN, 1], [[], {}]]:
		eq(CourseCards.unit_cards(wd[0], wd[1]).size(), 0, "unit_cards(%s, %s) is [] (no crash)" % [str(wd[0]), str(wd[1])])
	eq(CourseCards.unit_cards(2.0, "3").size(), 3, "whole float week and integer text day are accepted")
	_use("user://test_e3_cards/missing")
	eq(CourseCards.unit_cards(1, 1).size(), 0, "no course data: unit_cards is [] (no crash)")
	_mode("course")
	_clean_progress()
	eq(CourseCards.add_unit(1, 1), 0, "no course data: add_unit is 0")
	eq(Store.progress["review"].size(), 0, "no course data: the review list is untouched")
	_use(K1)


func _synthetic_cards() -> void:
	var weeks: Array = []
	for w in [1, 2, 3]:
		var days: Array = []
		for d in range(1, 8):
			days.append({"d": d, "kind": "new" if d <= 4 else "speak", "words": [], "patterns": []})
		weeks.append({"w": w, "n": 1, "k": w, "stage": 0, "legacy_stage": 1, "dialogue": "d%d" % w, "days": days})
	weeks[0]["days"][0]["words"] = ["w1", "w2", "w3", "w4", "w5", "w6"]
	weeks[0]["days"][0]["patterns"] = ["p1", "p2"]
	weeks[0]["days"][1]["words"] = ["w1"]
	weeks[0]["days"][3]["words"] = ["w7"]
	var words: Array = [
		{"id": "w1", "en": "apple", "ko": "사과", "role": "active", "o": 11},
		{"id": "w2", "en": "grape", "ko": "포도", "role": "passive", "o": 11},
		{"id": "w3", "en": "pear", "ko": "배", "o": 11},
		{"id": "w4", "en": "apple", "ko": "사과", "role": "active", "o": 11},
		{"id": "w5", "en": "  plum  ", "ko": " 자두 ", "role": "active", "o": 11},
		{"id": "w6", "en": "   ", "ko": "빈 글", "role": "active", "o": 11},
		{"id": "w7", "en": "peach", "ko": "복숭아", "role": "active", "o": 14},
	]
	var patterns: Array = [
		{"id": "p1", "tpl": "I like ___.", "examples": ["s_missing", "s1", "s2"], "o": 11},
		{"id": "p2", "tpl": "I eat ___.", "examples": [], "o": 11},
	]
	var sentences: Array = [
		{"id": "s1", "en": "I like apples.", "ko": "저는 사과를 좋아해요.", "o": 11, "scope": "all"},
		{"id": "s2", "en": "I like pears.", "ko": "저는 배를 좋아해요.", "o": 11, "scope": "all"},
	]
	var dialogues: Array = [
		{"id": "d1", "w": 1, "user": "B", "lines": [
			{"s": "A", "en": "Hello!", "ko": "안녕하세요!", "o": 14},
			{"s": "B", "en": "Hi, I am Min.", "ko": "안녕하세요, 저는 민이에요.", "o": 14},
			{"s": "A", "en": "Nice to meet you.", "ko": "만나서 반가워요.", "o": 14},
			{"s": "B", "en": "Nice to meet you, too.", "ko": "저도 만나서 반가워요.", "o": 14},
			{"s": "B", "en": "See you.", "ko": "또 만나요.", "o": 14}]},
		{"id": "d2", "w": 2, "lines": [
			{"s": "A", "en": "First line.", "ko": "첫 줄이에요.", "o": 24},
			{"s": "B", "en": "Second line.", "ko": "둘째 줄이에요.", "o": 24},
			{"s": "A", "en": "Third line.", "ko": "셋째 줄이에요.", "o": 24}]},
		{"id": "d3", "w": 3, "user": "B", "lines": [
			{"s": "A", "en": "Hello?", "ko": "여보세요?", "o": 34},
			{"s": "B", "en": "Future line.", "ko": "미래 줄이에요.", "o": 39},
			{"s": "B", "en": "Ok line.", "ko": "괜찮은 줄이에요.", "o": 31},
			{"s": "B", "en": "", "ko": "빈 줄이에요.", "o": 31}]},
	]
	_write_course(TMP.path_join("syn"), {"en_weeks.json": {"v": 1, "lang": "en", "weeks": weeks}, "en_lexicon.json": {"v": 1, "lang": "en", "words": words},
		"en_patterns.json": {"v": 1, "lang": "en", "patterns": patterns}, "en_sentences.json": {"v": 1, "lang": "en", "sentences": sentences},
		"en_dialogues.json": {"v": 1, "lang": "en", "dialogues": dialogues}})
	_use(TMP.path_join("syn"))
	ok(bool(CourseData.load_all()["ok"]), "the run-time course verifies fine")
	var c: Array = CourseCards.unit_cards(1, 1)
	eq(_targets(c), ["apple", "pear", "plum", "I like apples."], "passive word, same-word duplicate and blank word are left out; the missing example is skipped")
	ok(not _targets(c).has("grape"), "a passive word never becomes a card")
	eq(c[2]["ko"], "자두", "the card text is trimmed (target and ko)")
	eq(c[1]["note"], "코스 1주 1일 · 단어", "a word without a role counts as active")
	eq(_targets(CourseCards.unit_cards(1, 2)), ["apple"], "week 1 day 2: its own word again (cards of another day are separate units)")
	# the pattern without examples gives nothing
	var pattern_notes := 0
	for card in c:
		if String(card["note"]).ends_with("문형"):
			pattern_notes += 1
	eq(pattern_notes, 1, "two patterns but only one has an example: one pattern card")
	# dialogue: day 4 only, the learner's lines, at most 2
	var d4: Array = CourseCards.unit_cards(1, 4)
	eq(_targets(d4), ["peach", "Hi, I am Min.", "Nice to meet you, too."], "day 4: the word and the learner's first two lines (the third B line is left out)")
	eq(d4[1]["note"], "코스 1주 4일 · 대화", "dialogue card note")
	for d in [1, 2, 3, 5, 6, 7]:
		var notes: Array = []
		for card in CourseCards.unit_cards(1, d):
			notes.append(String(card["note"]).ends_with("대화"))
		ok(not notes.has(true), "day %d has no dialogue card (the dialogue belongs to day 4)" % d)
	# a dialogue without a user role: the first two lines
	eq(_targets(CourseCards.unit_cards(2, 4)), ["First line.", "Second line."], "no `user` role: the first two lines")
	# lines taught later than the day (o above 34), and empty lines, are not used
	eq(_targets(CourseCards.unit_cards(3, 4)), ["Ok line."], "lines with a later o or empty text are skipped")
	# nothing mentions passive words anywhere
	var every: Array = []
	for w in [1, 2, 3]:
		for d in range(1, 8):
			every.append_array(_targets(CourseCards.unit_cards(w, d)))
	ok(not every.has("grape"), "scanning all days: the passive word never appears")
	var bad_cards := 0
	for w in [1, 2, 3]:
		for d in range(1, 8):
			for card in CourseCards.unit_cards(w, d):
				if not _card_problems(card).is_empty():
					bad_cards += 1
					print("  card problem: ", card, " ", _card_problems(card))
	eq(bad_cards, 0, "every synthetic card passes the card checker")
	_use(K1)


func _add_unit() -> void:
	_use(K1)
	_mode("course")
	_clean_progress()
	var n1: int = CourseCards.add_unit(1, 1)
	eq(n1, 3, "add_unit(1, 1) adds 3 cards")
	var review: Array = Store.progress["review"]
	eq(review.size(), 3, "the review list has 3 cards")
	eq(review[0]["target"], "hello", "first card: hello")
	eq(review[0]["lang"], "en", "lang en")
	eq(review[0]["note"], "코스 1주 1일 · 단어", "note kept")
	ok(review[0].has("due") and review[0].has("stability") and review[0].has("state"), "the card is an FSRS card (due, stability, state)")
	eq(Store.due_count("en"), 3, "all 3 new cards are due now")
	ok(FileAccess.file_exists(PROG), "progress was saved (to the test file)")
	ok(FileAccess.get_file_as_string(PROG).contains("hello"), "the saved progress holds the card")
	eq(CourseCards.add_unit(1, 1), 0, "asking again adds 0")
	eq(Store.progress["review"].size(), 3, "still 3 cards after asking again")
	eq(CourseCards.add_unit(1, 5), 0, "a speak day adds 0")
	# a card that is already in the list (any source) is skipped
	_clean_progress()
	Store.add_review([{"lang": "en", "target": "hello", "reading": "", "ko": "다른 뜻", "note": "손으로 넣음"}])
	var n2: int = CourseCards.add_unit(1, 1)
	eq(n2, 2, "hello was already there: only 2 are added")
	eq(Store.progress["review"].size(), 3, "3 cards in the list")
	eq(Store.progress["review"][0]["note"], "손으로 넣음", "the old card is not replaced")
	# the return value is the real number added
	_clean_progress()
	var before: int = Store.progress["review"].size()
	var n3: int = CourseCards.add_unit(1, 4)
	eq(n3, Store.progress["review"].size() - before, "add_unit returns what was really added")
	eq(n3, 5, "week 1 day 4: 5 cards")
	var n4: int = CourseCards.add_unit(1, 3)
	eq(n4, 5, "week 1 day 3: 5 cards (the words of another day are other cards)")
	eq(Store.progress["review"].size(), 10, "10 cards in the list")
	# other languages / other cards are never touched
	var langs: Dictionary = {}
	for card in Store.progress["review"]:
		langs[card["lang"]] = true
	eq(langs.keys(), ["en"], "all cards are English")
	# the old path's study log has no course trace
	var snap: Dictionary = StudyLog.snapshot()
	var cells: Dictionary = {}
	if snap.has("path") and snap["path"] is Dictionary and snap["path"].get("cells") is Dictionary:
		cells = snap["path"]["cells"].get("en", {})
	ok(cells.is_empty(), "the old path's study log (path.cells.en) has no record")
	# invalid days add nothing
	for wd in [[3, 1], [0, 1], [73, 1], ["x", 1], [null, null]]:
		eq(CourseCards.add_unit(wd[0], wd[1]), 0, "add_unit(%s, %s) is 0" % [str(wd[0]), str(wd[1])])
	eq(Store.progress["review"].size(), 10, "invalid days left the list as it was")


func _add_unit_modes() -> void:
	_use(K1)
	_mode("legacy")
	_clean_progress()
	eq(CourseCards.add_unit(1, 1), 0, "legacy mode: add_unit adds 0")
	eq(Store.progress["review"].size(), 0, "legacy mode: the review list is untouched")
	ok(not FileAccess.file_exists(PROG), "legacy mode: no progress file was written")
	eq(CourseCards.unit_cards(1, 1).size(), 3, "legacy mode: unit_cards itself is just data (3 cards)")
	_mode("")
	Store.prefs["lang"] = "ja"
	eq(CourseCards.add_unit(1, 1), 0, "Japanese without course mode: add_unit adds 0")
	ok(not FileAccess.file_exists(PROG), "Japanese: no progress file was written")
	ok(not FileAccess.file_exists(CS), "Japanese: no course file was written")
	_mode("course")
	eq(CourseCards.add_unit(1, 1), 3, "course mode again: add_unit adds 3")
	ok(not FileAccess.file_exists(CS), "add_unit does not touch the course file")


func _source_scan() -> void:
	var text: String = FileAccess.get_file_as_string("res://scripts/core/course_cards.gd")
	ok(text.length() > 0, "course_cards.gd is readable")
	for bad in ["add_path" + "_lesson", "HTTP" + "Request", "StudyLog.", "FileAccess", "randi", "OS.shell" + "_open"]:
		var found := false
		for line in text.split("\n"):
			if not String(line).strip_edges().begins_with("##") and String(line).contains(bad):
				found = true
		ok(not found, "course_cards.gd code has no %s" % bad)
