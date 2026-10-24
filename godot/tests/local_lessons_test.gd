extends Node
## A3a: LocalLessons (POST /lesson, lesson bank + lesson_cursor) and LocalPractice (GET /practice/*), through LocalApi.dispatch.
##   godot --headless --path <project> res://tests/local_lessons_test.tscn
## Exit code 0 = all checks passed. Last line: "== local_lessons_test result: N passed, 0 failed =="
## Store.prefs / Store.prefs_path are swapped to user://test_a3a_prefs.json (cursor writes never touch the real prefs)
## and restored at the end. Broken packs live only in user://test_a3a_pack/ (PackLoader.base_dir is restored).

const TMP_PREFS := "user://test_a3a_prefs.json"
const TMP_PACK := "user://test_a3a_pack"
const TMP_PACK2 := "user://test_r1fix_pack"
const LESSON_CELL := "3-2"
const TATOEBA_URL := "https://tatoeba.org/sentences/show/"

var passed: int = 0
var failed: int = 0
var _onelang_done: bool = false


func _ready() -> void:
	print("== local_lessons_test start ==")
	_run()


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _run() -> void:
	var old_prefs_path: String = Store.prefs_path
	var old_prefs: Dictionary = Store.prefs.duplicate(true)
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	Store.prefs_path = TMP_PREFS
	Store.prefs = {}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PREFS))

	await _test_pack_available()
	await _test_lesson_shape()
	await _test_bank_cycle()
	await _test_cursor_store()
	await _test_lesson_inputs()
	await _test_broken_packs()
	await _test_one_language_broken()
	ok(_onelang_done, "one-language-broken section ran to its end (no script error cut it short)")
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	Store.prefs_path = TMP_PREFS
	await _test_practice_ping_and_sentences()
	await _test_practice_phonemes()
	_test_helpers()

	Store.prefs_path = old_prefs_path
	Store.prefs = old_prefs
	print("== local_lessons_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

func _bank_cell_size(lang: String, cell: String) -> int:
	var r: Dictionary = PackLoader.load_json("lesson_bank_%s.json" % lang)
	if not bool(r["ok"]):
		return -1
	var cells: Variant = (r["data"] as Dictionary)["lessons"].get(cell)
	return (cells as Array).size() if cells is Array else -1


func _lesson(month: int, week: int, lang: String = "en") -> Dictionary:
	return await LocalApi.dispatch("POST", "/lesson", {"lang": lang, "month": month, "week": week})


func _http_get(path: String) -> Dictionary:
	return await LocalApi.dispatch("GET", path, {})


func _ids(sents: Array) -> Array:
	var out: Array = []
	for s in sents:
		out.append(int(s["id"]))
	return out


# ---------------------------------------------------------------- lessons

func _test_pack_available() -> void:
	ok(LocalLessons.is_available(), "lessons: pack available")
	ok(str(LocalLessons.unavailable_reason()["err_code"]) == "", "lessons: no reason when pack fine")
	ok(LocalPractice.is_available(), "practice: pack available")
	ok(str(LocalPractice.unavailable_reason()["err_code"]) == "", "practice: no reason when pack fine")
	ok(_bank_cell_size("en", LESSON_CELL) >= 10, "bank: en 3-2 cell has at least 10 lessons")


func _test_lesson_shape() -> void:
	var r: Dictionary = await _lesson(3, 2)
	ok(bool(r["ok"]), "lesson: POST /lesson en 3-2 ok")
	ok(int(r["code"]) == 200, "lesson: code 200")
	var d: Dictionary = r["data"]
	ok(str(d.get("via", "")) == "phone", "lesson: via == phone")
	ok((d.get("degraded", null) is Array) and (d["degraded"] as Array).is_empty(), "lesson: degraded empty on first round")
	var ex: Variant = d.get("exercises")
	ok(ex is Array and (ex as Array).size() >= 4, "lesson: exercises >= 4")
	ok(str(d.get("source", "")) == "tatoeba", "lesson: source == tatoeba")
	ok(str(d.get("attribution", "")) != "", "lesson: attribution not empty")
	ok(str(d.get("bank_id", "")).begins_with("en-3-2-"), "lesson: bank_id in en-3-2 cell")
	ok(str(d.get("title", "")) != "", "lesson: title not empty")
	ok(int(r["err_code"] == "") == 1, "lesson: err_code empty on success")
	var ex0: Dictionary = (ex as Array)[0]
	ok(str(ex0.get("type", "")) != "", "lesson: first exercise has a type")
	var fr: Dictionary = await _lesson(3, 2, "fr")
	ok(not bool(fr["ok"]) and str(fr["err_code"]) == "bad_request" and int(fr["code"]) == 400, "lesson: lang fr -> 400 bad_request")
	var ai: Dictionary = await LocalApi.dispatch("POST", "/lesson", {"lang": "en", "source": "ai"})
	ok(not bool(ai["ok"]), "lesson: source ai is not served by the bank")
	var bad_src: Dictionary = await LocalApi.dispatch("POST", "/lesson", {"lang": "en", "source": "xx"})
	ok(not bool(bad_src["ok"]) and int(bad_src["code"]) == 400, "lesson: source xx -> 400")
	var get_r: Dictionary = await LocalApi.dispatch("GET", "/lesson", {})
	ok(not bool(get_r["ok"]), "lesson: GET /lesson is not served")


func _test_bank_cycle() -> void:
	var n: int = _bank_cell_size("en", LESSON_CELL)
	Store.prefs.erase("lesson_cursor")  # the cycle starts from an empty cursor (the shape test used the cell once)
	var seen: Dictionary = {}
	var first_id: String = ""
	var any_repeat: bool = false
	var all_ok: bool = true
	for i in range(n):
		var r: Dictionary = await _lesson(3, 2)
		if not bool(r["ok"]):
			all_ok = false
			continue
		var bid: String = str(r["data"]["bank_id"])
		seen[bid] = true
		if i == 0:
			first_id = bid
		if (r["data"]["degraded"] as Array).has("bank_repeat"):
			any_repeat = true
	ok(all_ok, "cycle: first %d requests all ok" % n)
	ok(seen.size() == n, "cycle: first %d requests give %d different bank_ids" % [n, n])
	ok(not any_repeat, "cycle: no bank_repeat inside the first round")
	var r2: Dictionary = await _lesson(3, 2)
	ok(bool(r2["ok"]) and (r2["data"]["degraded"] as Array).has("bank_repeat"), "cycle: request N+1 carries bank_repeat")
	ok(str(r2["data"]["bank_id"]) == first_id, "cycle: request N+1 starts again from the first lesson")
	var r3: Dictionary = await _lesson(3, 2)
	ok(bool(r3["ok"]) and (r3["data"]["degraded"] as Array).has("bank_repeat"), "cycle: request N+2 still bank_repeat")
	ok(str(r3["data"]["bank_id"]) != first_id, "cycle: request N+2 is the second lesson")
	# a full second lap keeps cycling and never leaves the cell
	var in_cell: bool = true
	for i in range(n):
		var r4: Dictionary = await _lesson(3, 2)
		if not str(r4["data"].get("bank_id", "")).begins_with("en-3-2-"):
			in_cell = false
	ok(in_cell, "cycle: a second lap stays in the cell")


func _test_cursor_store() -> void:
	var n: int = _bank_cell_size("en", LESSON_CELL)
	var cur: Variant = Store.prefs.get("lesson_cursor")
	ok(cur is Dictionary and (cur as Dictionary).has("en-3-2"), "cursor: stored under en-3-2 in the test prefs")
	var c: int = int((cur as Dictionary)["en-3-2"]) if cur is Dictionary else -1
	ok(c >= 0 and c < 2 * n, "cursor: value stays inside [0, 2N)")
	ok(not ((cur as Dictionary).has("en-5-1")) if cur is Dictionary else false, "cursor: other cells untouched")
	var f: FileAccess = FileAccess.open(TMP_PREFS, FileAccess.READ)
	var saved: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
	ok(saved is Dictionary and (saved as Dictionary).get("lesson_cursor") is Dictionary, "cursor: written to the test prefs file")
	var r: Dictionary = await _lesson(5, 1)
	ok(bool(r["ok"]) and str(r["data"]["bank_id"]).begins_with("en-5-1-"), "cursor: another cell starts at its first lesson")
	var jr: Dictionary = await _lesson(1, 1, "ja")
	ok(bool(jr["ok"]) and str(jr["data"]["bank_id"]).begins_with("ja-1-1-"), "cursor: ja bank serves ja-1-1")
	ok(((Store.prefs["lesson_cursor"] as Dictionary).get("ja-1-1", -1)) == 1, "cursor: ja cell has its own cursor")


func _test_lesson_inputs() -> void:
	var r: Dictionary = await LocalApi.dispatch("POST", "/lesson", {"lang": "en", "month": 99, "week": 0})
	ok(bool(r["ok"]) and str(r["data"]["bank_id"]).begins_with("en-12-1-"), "inputs: month 99 -> 12, week 0 -> 1")
	var s: Dictionary = await LocalApi.dispatch("POST", "/lesson", {"lang": "en", "month": "4", "week": "3"})
	ok(bool(s["ok"]) and str(s["data"]["bank_id"]).begins_with("en-4-3-"), "inputs: numeric strings accepted")


# ---------------------------------------------------------------- broken packs

func _test_broken_packs() -> void:
	_wipe(TMP_PACK)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_PACK))
	var src: FileAccess = FileAccess.open(PackLoader.DEFAULT_DIR + "/manifest.json", FileAccess.READ)
	var mf: FileAccess = FileAccess.open(TMP_PACK + "/manifest.json", FileAccess.WRITE)
	mf.store_buffer(src.get_buffer(src.get_length()))
	mf.close()
	var full: FileAccess = FileAccess.open(PackLoader.DEFAULT_DIR + "/lesson_bank_en.json", FileAccess.READ)
	var bytes: PackedByteArray = full.get_buffer(full.get_length())
	var half: PackedByteArray = bytes.slice(0, bytes.size() / 2)
	var lb: FileAccess = FileAccess.open(TMP_PACK + "/lesson_bank_en.json", FileAccess.WRITE)
	lb.store_buffer(half)
	lb.close()
	PackLoader.base_dir = TMP_PACK
	PackLoader.reset()
	var r: Dictionary = await _lesson(3, 2)
	ok(not bool(r["ok"]) and str(r["err_code"]) == "pack_corrupt", "broken: truncated lesson bank -> pack_corrupt")
	ok(not LocalLessons.is_available(), "broken: lessons not available when truncated")
	ok(str(LocalLessons.unavailable_reason()["err_code"]) == "pack_corrupt", "broken: reason pack_corrupt")
	var p: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=3&seed=1")
	ok(not bool(p["ok"]) and str(p["err_code"]) == "pack_missing", "broken: practice_en absent from the copy -> pack_missing")
	ok(not LocalPractice.is_available(), "broken: practice not available when its file is absent")
	ok(str(LocalPractice.unavailable_reason()["err_code"]) == "pack_missing", "broken: practice reason pack_missing")
	var ph: Dictionary = await _http_get("/practice/phonemes")
	ok(not bool(ph["ok"]) and str(ph["err_code"]) == "pack_missing", "broken: phonemes without phoneme_drills -> pack_missing")
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()


## English lesson bank + English practice pack damaged, Japanese ones intact: Japanese requests must still be served,
## English ones must be reported unavailable (the requested language decides, not the English files).
## Removes the files of a scratch pack folder and the folder itself (nothing else).
func _wipe(dir: String) -> void:
	var g: String = ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(g):
		return
	for f in DirAccess.get_files_at(g):
		DirAccess.remove_absolute(g.path_join(f))
	DirAccess.remove_absolute(g)


func _test_one_language_broken() -> void:
	print("[one language damaged]")
	_wipe(TMP_PACK2)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_PACK2))
	for f in ["manifest.json", "lesson_bank_ja.json", "practice_ja.json"]:
		var src: FileAccess = FileAccess.open(PackLoader.DEFAULT_DIR + "/" + f, FileAccess.READ)
		var dst: FileAccess = FileAccess.open(TMP_PACK2 + "/" + f, FileAccess.WRITE)
		dst.store_buffer(src.get_buffer(src.get_length()))
		dst.close()
	for f in ["lesson_bank_en.json", "practice_en.json"]:
		var full: FileAccess = FileAccess.open(PackLoader.DEFAULT_DIR + "/" + f, FileAccess.READ)
		var bytes: PackedByteArray = full.get_buffer(full.get_length())
		var bad: FileAccess = FileAccess.open(TMP_PACK2 + "/" + f, FileAccess.WRITE)
		bad.store_buffer(bytes.slice(0, bytes.size() / 2))
		bad.close()
	PackLoader.base_dir = TMP_PACK2
	PackLoader.reset()
	ok(not LocalLessons.is_available() and not LocalLessons.is_available("en"), "en bank damaged -> is_available() / is_available('en') false")
	ok(LocalLessons.is_available("ja"), "...but is_available('ja') true")
	ok(not LocalApi.available("POST", "/lesson", {"lang": "en"}), "LocalApi.available POST /lesson lang=en -> false")
	ok(LocalApi.available("POST", "/lesson", {"lang": "ja"}), "LocalApi.available POST /lesson lang=ja -> true (en bank damaged)")
	var r: Dictionary = await _lesson(2, 1, "ja")
	ok(bool(r["ok"]) and str(r["data"]["bank_id"]).begins_with("ja-2-1-"), "ja lesson is served while the en bank is damaged")
	var why_en: Dictionary = LocalApi.why_none("POST", "/lesson", {"lang": "en"})
	ok(str(why_en["err_code"]) == "pack_corrupt", "why_none for en -> pack_corrupt")
	ok(str(LocalLessons.unavailable_reason("ja")["err_code"]) == "", "unavailable_reason('ja') is empty")
	# practice: Japanese sentences only need practice_ja.json
	ok(not LocalPractice.is_available(), "practice_en damaged -> LocalPractice.is_available() false")
	ok(LocalApi.available("GET", "/practice/sentences?lang=ja&mode=shadow&n=3"), "LocalApi.available practice sentences lang=ja -> true")
	ok(not LocalApi.available("GET", "/practice/sentences?lang=en&mode=shadow&n=3"), "LocalApi.available practice sentences lang=en -> false")
	var pj: Dictionary = await _http_get("/practice/sentences?lang=ja&mode=shadow&n=3&seed=1")
	ok(bool(pj["ok"]) and (pj["data"]["sentences"] as Array).size() == 3, "ja practice sentences served while the en pack is damaged")
	# a damaged ja bank, intact en bank: the mirror image
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	ok(LocalApi.available("POST", "/lesson", {"lang": "en"}) and LocalApi.available("POST", "/lesson", {"lang": "ja"}), "intact pack: both languages available")
	PackLoader.base_dir = TMP_PACK2
	var jf: FileAccess = FileAccess.open(PackLoader.DEFAULT_DIR + "/lesson_bank_ja.json", FileAccess.READ)
	var jb: PackedByteArray = jf.get_buffer(jf.get_length())
	var jw: FileAccess = FileAccess.open(TMP_PACK2 + "/lesson_bank_ja.json", FileAccess.WRITE)
	jw.store_buffer(jb.slice(0, jb.size() / 3))
	jw.close()
	PackLoader.reset()
	ok(not LocalLessons.is_available("ja") and str(LocalLessons.unavailable_reason("ja")["err_code"]) == "pack_corrupt", "ja bank damaged -> is_available('ja') false, pack_corrupt")
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	_wipe(TMP_PACK2)
	_onelang_done = true


# ---------------------------------------------------------------- practice

func _test_practice_ping_and_sentences() -> void:
	var ping: Dictionary = await _http_get("/practice/ping")
	ok(bool(ping["ok"]) and int(ping["data"]["practice"]) == 1, "practice: ping ok, practice 1")
	ok(bool(ping["data"]["tatoeba"]), "practice: ping tatoeba true with the pack")
	var a: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=5&seed=1")
	var b: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=5&seed=1")
	ok(bool(a["ok"]) and bool(b["ok"]), "practice: sentences ok")
	var sa: Array = a["data"]["sentences"]
	var sb: Array = b["data"]["sentences"]
	ok(sa.size() == 5, "practice: n=5 gives 5 sentences")
	ok(_ids(sa) == _ids(sb), "practice: seed=1 twice gives the same ids")
	ok(str(a["data"]["via"]) == "phone" and str(a["data"]["attribution"]) != "", "practice: via phone, attribution filled")
	var s0: Dictionary = sa[0]
	ok(str(s0["url"]).begins_with(TATOEBA_URL) and str(s0["text"]) != "", "practice: item has text and tatoeba url")
	var first: int = int(s0["id"])
	var ex: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=5&seed=1&exclude=%s" % str(first))
	ok(not _ids(ex["data"]["sentences"]).has(first), "practice: exclude=<first id> drops that id")
	ok((ex["data"]["sentences"] as Array).size() == 5, "practice: exclude keeps n")
	var ex2: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=5&seed=1&exclude=a,,x%%2Dy,%s" % str(first))
	ok(not _ids(ex2["data"]["sentences"]).has(first), "practice: exclude with junk tokens still drops the id")
	ok(LocalPractice.parse_exclude("12,34,a,,%00") == {12: true, 34: true}, "practice: parse_exclude keeps numeric ids only")
	var big: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=50&seed=3")
	ok((big["data"]["sentences"] as Array).size() == 20, "practice: n clamps to 20")
	var small: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&n=0&seed=3")
	ok((small["data"]["sentences"] as Array).size() == 1, "practice: n clamps to 1")
	var st7: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&month=7&n=2&seed=4")
	ok(int(st7["data"]["stage"]) == 3, "practice: month 7 -> stage 3")
	var st12: Dictionary = await _http_get("/practice/sentences?lang=en&mode=shadow&month=12&n=2&seed=4")
	ok(int(st12["data"]["stage"]) == 4, "practice: month 12 -> stage 4")
	var dic: Dictionary = await _http_get("/practice/sentences?lang=en&mode=dictation&n=5&seed=2")
	var dsents: Array = dic["data"]["sentences"]
	ok(dsents.size() == 5, "practice: dictation n=5 gives 5")
	var all_dict: bool = true
	for s in dsents:
		if not LocalPractice.dictation_ok(str(s["text"])):
			all_dict = false
	ok(all_dict, "practice: every dictation sentence passes dictation_ok")
	var ja: Dictionary = await _http_get("/practice/sentences?lang=ja&mode=shadow&n=3&seed=5")
	var jsents: Array = ja["data"]["sentences"]
	ok(bool(ja["ok"]) and jsents.size() == 3, "practice: ja shadow n=3")
	var ja_ok: bool = true
	for s in jsents:
		if not LocalPractice.ja_reading_ok(str(s["reading"])):
			ja_ok = false
	ok(ja_ok, "practice: ja readings are hiragana only")
	var jd: Dictionary = await _http_get("/practice/sentences?lang=ja&mode=dictation&n=3")
	ok(not bool(jd["ok"]) and int(jd["code"]) == 400, "practice: ja dictation -> 400")
	var bm: Dictionary = await _http_get("/practice/sentences?lang=en&mode=zzz&n=3")
	ok(not bool(bm["ok"]) and int(bm["code"]) == 400, "practice: bad mode -> 400")
	var bl: Dictionary = await _http_get("/practice/sentences?lang=fr&mode=shadow&n=3")
	ok(not bool(bl["ok"]) and int(bl["code"]) == 400, "practice: bad lang -> 400")


func _test_practice_phonemes() -> void:
	var r: Dictionary = await _http_get("/practice/phonemes")
	ok(bool(r["ok"]) and (r["data"]["phonemes"] as Array).size() >= 1, "phonemes: list not empty")
	var list: Array = r["data"]["phonemes"]
	var first_p: String = str(list[0]["p"])
	ok(list[0].has("label") and list[0].has("hint_ko"), "phonemes: items have label and hint_ko")
	var p0: Dictionary = await _http_get("/practice/phoneme?p=%s&sentences=0" % first_p)
	ok(bool(p0["ok"]) and (p0["data"]["sentences"] as Array).is_empty(), "phoneme: sentences=0 gives none")
	ok((p0["data"]["words"] as Array).size() >= 1 and (p0["data"]["pairs"] is Array), "phoneme: words and pairs present")
	var p3: Dictionary = await _http_get("/practice/phoneme?p=%s" % first_p)
	ok(bool(p3["ok"]) and (p3["data"]["sentences"] as Array).size() <= 3, "phoneme: default at most 3 sentences")
	var none: Dictionary = await _http_get("/practice/phoneme?p=")
	ok(not bool(none["ok"]) and int(none["code"]) == 400, "phoneme: empty p -> 400")
	var miss: Dictionary = await _http_get("/practice/phoneme?p=zz_no_such")
	ok(not bool(miss["ok"]) and int(miss["code"]) == 404, "phoneme: unknown p -> 404")


# ---------------------------------------------------------------- pure helpers

func _test_helpers() -> void:
	ok(LocalPractice.dictation_ok("I think so."), "dict: 'I think so.' ok")
	ok(LocalPractice.dictation_ok("I'm here now."), "dict: I'm form ok")
	ok(not LocalPractice.dictation_ok("Hello There friend"), "dict: mid capital rejected")
	ok(not LocalPractice.dictation_ok("one two"), "dict: 2 words rejected")
	ok(not LocalPractice.dictation_ok("It is 3 days."), "dict: digit rejected")
	ok(not LocalPractice.ja_reading_ok("漢字"), "ja reading: kanji rejected")
	ok(LocalPractice.ja_reading_ok("わたしは、がくせいです。"), "ja reading: hiragana with punctuation ok")
	ok(not LocalPractice.ja_reading_ok("。。"), "ja reading: punctuation only rejected")
	ok(LocalLessons._next_cursor(2, 20) == 3, "cursor math: +1 in the first round")
	ok(LocalLessons._next_cursor(19, 20) == 20, "cursor math: last of the first round -> 20")
	ok(LocalLessons._next_cursor(39, 20) == 20, "cursor math: wraps back to N inside the repeat round")
