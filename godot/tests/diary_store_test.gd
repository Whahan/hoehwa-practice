extends Node
## DiaryStore (user://diary.json 일기 저장소) 시험.
##   godot --headless --path godot res://tests/diary_store_test.tscn          (APPDATA 는 임시 폴더로 바꿔 실행)
## 종료 코드 0 = 전부 통과. 마지막 줄: "== diary_store: N passed, M failed =="
## 실제 user://diary.json 은 읽지도 쓰지도 않는다: DiaryStore.path 를 user://test_diary_c1_*.json 으로 바꿔 쓴다.
## 일기 글 대신 마커(ZZ_MARK_9731)를 쓰고 시험은 글을 출력하지 않는다(이름만).

const MARK := "ZZ_MARK_9731"
const P1 := "user://test_diary_c1_a.json"
const P2 := "user://test_diary_c1_b.json"
const PPROG := "user://test_diary_c1_progress.json"
const PPREFS := "user://test_diary_c1_prefs.json"
const PLOG := "user://test_diary_c1_studylog.json"

var passed: int = 0
var failed: int = 0
var D: int = 0
var _old: Array = []
var _toasts: Array = []


func _ready() -> void:
	print("== diary_store start ==")
	D = Plan.days_from_civil(2026, 11, 14)
	_old = [DiaryStore.path, Store.prefs_path, Store.progress_path, StudyLog.path, Store.progress.duplicate(true)]
	Store.prefs_path = PPREFS
	Store.progress_path = PPROG
	StudyLog.path = PLOG
	Store.progress = Progress.blank()
	DiaryStore.path = P1
	DiaryStore.today_override = D
	DiaryStore.unix_override = 1731571200
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	_cleanup()

	_test_basics()
	_test_dedupe_and_dates()
	_test_fixed_pending_counts()
	_test_remove_clear()
	_test_cards_by_day()
	_test_invalid_adds()
	_test_full()
	_test_broken_files()
	_test_garbage_entries()
	_test_read_only()
	_test_write_failure()
	_test_guard()
	_test_not_in_sync_or_logs()
	_test_card_flow_quoting_why()
	_test_source_never_logs()
	_selfchecks()

	_cleanup()
	Progress.open_hook = Callable()
	Progress.write_hook = Callable()
	DiaryStore.today_override = -1
	DiaryStore.unix_override = -1
	DiaryStore.path = _old[0]
	DiaryStore.forget()
	Store.prefs_path = _old[1]
	Store.progress_path = _old[2]
	StudyLog.path = _old[3]
	Store.progress = _old[4]
	print("== diary_store: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- helpers

func _cleanup() -> void:
	for p in [P1, P2, PPROG, PPREFS, PLOG]:
		for suf in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			var g: String = ProjectSettings.globalize_path(p + suf)
			if FileAccess.file_exists(g):
				DirAccess.remove_absolute(g)
	var gd: String = ProjectSettings.globalize_path("user://test_guard/diary.json")
	if FileAccess.file_exists(gd):
		DirAccess.remove_absolute(gd)


func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_text(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var t: String = f.get_as_text()
	f.close()
	return t


func read_json(p: String) -> Variant:
	var js := JSON.new()
	if js.parse(read_text(p)) != OK:
		return null
	return js.data


func fresh(p: String = P1) -> void:
	_cleanup()
	DiaryStore.path = p
	DiaryStore.forget()


## Drops the memory and reads the file again (as a new run of the app would).
func reopen() -> void:
	DiaryStore.forget()
	DiaryStore.load_from_disk()


func ent(id: String, text: String, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "date": "2026-11-14", "lang": "ja", "created": 1731571200, "text": text, "state": "saved", "items": [], "fixed_at": 0}
	d.merge(extra, true)
	return d


func file_of(entries: Array, extra: Dictionary = {}) -> String:
	var d := {"v": 1, "entries": entries, "cards_by_day": {}}
	d.merge(extra, true)
	return JSON.stringify(d)


func item(fix: String, extra: Dictionary = {}) -> Dictionary:
	var d := {"orig": MARK + " orig", "fix": fix, "why": "이유", "reading": "", "pron": "", "same": false, "card": false}
	d.merge(extra, true)
	return d


# ---------------------------------------------------------------- tests

func _test_basics() -> void:
	fresh()
	ok(DiaryStore.entries().is_empty() and not DiaryStore.is_read_only(), "basics: no file -> empty, writable")
	ok(DiaryStore.last_load_status == "new", "basics: status new")
	ok(DiaryStore.counts() == {"entries": 0, "days": 0, "fixed": 0} and DiaryStore.cards_today() == 0, "basics: counts and cards start at 0")
	ok(not FileAccess.file_exists(P1), "basics: reading does not create the file")
	var r: Dictionary = DiaryStore.add("ja", "きのう ともだちと " + MARK)
	var rx := RegEx.new()
	rx.compile("^d[0-9]{6,20}$")
	ok(bool(r["ok"]) and rx.search(str(r["id"])) != null and r["reason"] == "", "basics: add -> ok and an id like d1731571200123")
	ok(FileAccess.file_exists(P1) and not FileAccess.file_exists(P1 + ".tmp"), "basics: the file exists and no .tmp is left")
	var e: Dictionary = DiaryStore.get_entry(str(r["id"]))
	ok(e["lang"] == "ja" and e["date"] == "2026-11-14" and e["state"] == "saved" and e["items"] == [] and e["created"] == 1731571200 and e["fixed_at"] == 0, "basics: the new entry has date, lang, state saved, no items")
	ok(DiaryStore.get_entry("d999999") == {} and DiaryStore.get_entry("") == {}, "basics: unknown id -> {}")
	var raw: Variant = read_json(P1)
	ok(raw is Dictionary and int(raw["v"]) == 1 and (raw["entries"] as Array).size() == 1 and (raw["cards_by_day"] as Dictionary).is_empty(), "basics: file shape is {v, entries, cards_by_day}")
	reopen()
	var e2: Dictionary = DiaryStore.get_entry(str(r["id"]))
	ok(e2 == e and DiaryStore.last_load_status == "ok", "basics: read back after a restart gives the same entry")
	var multi: Dictionary = DiaryStore.add("en", "line one\r\nline two\u0001  ")
	ok(bool(multi["ok"]) and DiaryStore.get_entry(str(multi["id"]))["text"] == "line one\nline two", "basics: CRLF becomes \\n, control characters and edge blanks are removed")
	var e3: Array = DiaryStore.entries()
	ok(e3.size() == 2 and (e3[0] as Dictionary)["id"] == multi["id"], "basics: entries() is newest first")
	(e3[0] as Dictionary)["text"] = "changed"
	ok(DiaryStore.get_entry(str(multi["id"]))["text"] == "line one\nline two", "basics: entries() returns copies")
	ok(DiaryStore.entries("en").size() == 1 and DiaryStore.entries("ja").size() == 1 and DiaryStore.entries("fr").is_empty(), "basics: language filter")
	var r3: Dictionary = DiaryStore.add("ja", "あ")
	var r4: Dictionary = DiaryStore.add("ja", "い")
	ok(r3["id"] != r4["id"] and r3["id"] != r["id"], "basics: ids are unique even in the same second")
	var jp: Dictionary = DiaryStore.add("ja", "全角　スペース。「かぎ」　")
	ok(bool(jp["ok"]) and DiaryStore.get_entry(str(jp["id"]))["text"] == "全角　スペース。「かぎ」", "basics: Japanese text round-trips")
	var onfile: String = read_text(P1)
	ok(onfile.contains("全角") and not onfile.contains("\\u5168"), "basics: the file keeps Japanese as readable text")


func _test_dedupe_and_dates() -> void:
	fresh()
	var a: Dictionary = DiaryStore.add("ja", "同じ文 " + MARK)
	var b: Dictionary = DiaryStore.add("ja", "  同じ文 " + MARK + "\r\n")
	ok(a["id"] == b["id"] and bool(b["existed"]) and not bool(a["existed"]) and DiaryStore.entries().size() == 1, "dedupe: the same lang + date + text is one entry")
	DiaryStore.unix_override = 1731571300
	DiaryStore.add("ja", "同じ文 " + MARK)
	ok(int(DiaryStore.get_entry(str(a["id"]))["created"]) == 1731571300, "dedupe: saving again refreshes `created`")
	DiaryStore.unix_override = 1731571200
	var c: Dictionary = DiaryStore.add("en", "同じ文 " + MARK)
	ok(c["id"] != a["id"] and DiaryStore.entries().size() == 2, "dedupe: another language is another entry")
	DiaryStore.today_override = D + 1
	var d: Dictionary = DiaryStore.add("ja", "同じ文 " + MARK)
	ok(d["id"] != a["id"] and DiaryStore.get_entry(str(d["id"]))["date"] == "2026-11-15", "dates: the next day is a new entry with that date")
	DiaryStore.today_override = D - 1
	DiaryStore.add("ja", "昨日の文")
	ok(DiaryStore.get_entry(str(DiaryStore.entries()[0]["id"]))["date"] == "2026-11-13", "dates: the day before")
	DiaryStore.today_override = Plan.days_from_civil(2026, 12, 31)
	DiaryStore.add("ja", "年末")
	DiaryStore.today_override = Plan.days_from_civil(2027, 1, 1)
	DiaryStore.add("ja", "年始")
	var top: Array = DiaryStore.entries()
	ok((top[0] as Dictionary)["date"] == "2027-01-01" and (top[1] as Dictionary)["date"] == "2026-12-31", "dates: a year change gives 2026-12-31 then 2027-01-01")
	DiaryStore.today_override = Plan.days_from_civil(2028, 2, 29)
	DiaryStore.add("ja", "うるう日")
	ok(str(DiaryStore.entries()[0]["date"]) == "2028-02-29", "dates: a leap day")
	ok(DiaryStore.counts()["days"] == 6, "dates: counts() counts different days")
	DiaryStore.today_override = D
	reopen()
	ok(DiaryStore.entries().size() == 7, "dedupe: nothing was lost over a restart")


func _test_fixed_pending_counts() -> void:
	fresh()
	var a: String = str(DiaryStore.add("ja", "一つ目 " + MARK)["id"])
	var b: String = str(DiaryStore.add("ja", "二つ目 " + MARK)["id"])
	var c: String = str(DiaryStore.add("en", "third " + MARK)["id"])
	ok(DiaryStore.pending().size() == 3 and DiaryStore.pending("ja").size() == 2 and DiaryStore.pending("en").size() == 1, "fixed: three saved entries are pending")
	ok((DiaryStore.pending()[0] as Dictionary)["id"] == c, "fixed: pending() is newest first")
	ok(DiaryStore.set_fixed(a, [item("直した文です。", {"reading": "なおしたぶんです。", "card": true})]), "fixed: set_fixed -> true")
	var ea: Dictionary = DiaryStore.get_entry(a)
	ok(ea["state"] == "fixed" and (ea["items"] as Array).size() == 1 and int(ea["fixed_at"]) == 1731571200, "fixed: state fixed, one item, fixed_at is now")
	var it0: Dictionary = (ea["items"] as Array)[0]
	ok(it0["fix"] == "直した文です。" and it0["reading"] == "なおしたぶんです。" and it0["card"] == true and it0["same"] == false and it0.keys().size() == 7, "fixed: item keeps orig fix why reading pron same card")
	ok(DiaryStore.pending().size() == 2 and DiaryStore.pending("ja").size() == 1, "fixed: a fixed entry is no longer pending")
	reopen()
	ok(DiaryStore.get_entry(a)["state"] == "fixed" and (DiaryStore.get_entry(a)["items"] as Array).size() == 1, "fixed: survives a restart")
	ok(not DiaryStore.set_fixed("d424242", [item("x")]) and not DiaryStore.set_fixed("", []) and not DiaryStore.set_fixed("zzz", []), "fixed: unknown id -> false")
	var four: Array = [item("一です。"), item("二です。"), item("三です。"), item("四です。")]
	DiaryStore.set_fixed(b, four)
	ok((DiaryStore.get_entry(b)["items"] as Array).size() == 3, "fixed: at most 3 items are kept")
	var with_bad: Array = [item("一です。", {"bad": true}), item("二です。"), "junk", null, 5]
	DiaryStore.set_fixed(c, with_bad)
	ok((DiaryStore.get_entry(c)["items"] as Array).size() == 1, "fixed: bad items and junk are left out")
	DiaryStore.set_fixed(c, [])
	ok(DiaryStore.get_entry(c)["state"] == "fixed" and (DiaryStore.get_entry(c)["items"] as Array).is_empty(), "fixed: an entry with nothing to fix is fixed with no items")
	var long: Dictionary = item("f".repeat(400), {"orig": "o".repeat(300), "why": "w".repeat(300), "reading": "r".repeat(400), "pron": "p".repeat(400)})
	DiaryStore.set_fixed(a, [long])
	var li: Dictionary = (DiaryStore.get_entry(a)["items"] as Array)[0]
	ok(str(li["orig"]).length() == 120 and str(li["fix"]).length() == 300 and str(li["why"]).length() == 200 and str(li["reading"]).length() == 300 and str(li["pron"]).length() == 300, "fixed: long strings are cut (120 / 300 / 200 / 300 / 300)")
	DiaryStore.set_fixed(a, [{"orig": 5, "fix": null, "why": [1], "reading": {}, "pron": true, "same": "yes", "card": 1}])
	var ji: Dictionary = (DiaryStore.get_entry(a)["items"] as Array)[0]
	ok(ji["fix"] == "" and ji["orig"] == "" and ji["same"] == true and ji["card"] == true, "fixed: wrong types become empty strings; an empty fix is `same`")
	ok(DiaryStore.counts() == {"entries": 3, "days": 1, "fixed": 3}, "counts: entries, days, fixed")
	DiaryStore.today_override = D + 3
	DiaryStore.add("ja", "三日後")
	ok(DiaryStore.counts() == {"entries": 4, "days": 2, "fixed": 3} and DiaryStore.counts("en") == {"entries": 1, "days": 1, "fixed": 1} and DiaryStore.counts("ja")["entries"] == 3, "counts: a second day, per language")
	DiaryStore.today_override = D
	ok(not str(DiaryStore.counts()).contains(MARK), "counts: no text in the counts")


func _test_remove_clear() -> void:
	fresh()
	var a: String = str(DiaryStore.add("ja", "あ")["id"])
	var b: String = str(DiaryStore.add("en", "b")["id"])
	var c: String = str(DiaryStore.add("ja", "う")["id"])
	ok(DiaryStore.remove(b) and DiaryStore.entries().size() == 2 and DiaryStore.get_entry(b) == {}, "remove: one entry")
	ok(not DiaryStore.remove(b) and not DiaryStore.remove("") and not DiaryStore.remove("x"), "remove: unknown id or already gone -> false")
	reopen()
	ok(DiaryStore.entries().size() == 2, "remove: stays removed after a restart")
	DiaryStore.add("en", "e1")
	DiaryStore.add("en", "e2")
	ok(DiaryStore.clear("en") == 2 and DiaryStore.entries("en").is_empty() and DiaryStore.entries("ja").size() == 2, "clear: one language only")
	ok(DiaryStore.clear("en") == 0, "clear: nothing to clear -> 0")
	ok(DiaryStore.clear() == 2 and DiaryStore.entries().is_empty(), "clear: everything -> the number deleted")
	reopen()
	ok(DiaryStore.entries().is_empty() and FileAccess.file_exists(P1), "clear: empty after a restart (the file stays, with no entries)")
	ok(not read_text(P1).contains("ZZ") and (read_json(P1)["entries"] as Array).is_empty(), "clear: the file has no entries left")
	ok(bool(DiaryStore.add("ja", "また書く")["ok"]) and a != c, "clear: writing again works")


func _test_cards_by_day() -> void:
	fresh()
	DiaryStore.note_cards(2)
	ok(DiaryStore.cards_today() == 2, "cards: note_cards(2) -> cards_today 2")
	DiaryStore.note_cards(1)
	ok(DiaryStore.cards_today() == 3, "cards: adds up")
	DiaryStore.note_cards(0)
	DiaryStore.note_cards(-4)
	ok(DiaryStore.cards_today() == 3, "cards: 0 and negative do nothing")
	DiaryStore.note_cards(500)
	ok(DiaryStore.cards_today() == 100, "cards: the day count stops at 100")
	reopen()
	ok(DiaryStore.cards_today() == 100, "cards: survive a restart")
	DiaryStore.today_override = D + 1
	ok(DiaryStore.cards_today() == 0, "cards: the next day starts at 0 (date boundary)")
	DiaryStore.note_cards(4)
	ok(DiaryStore.cards_today() == 4, "cards: counted for the new day")
	DiaryStore.today_override = D
	ok(DiaryStore.cards_today() == 100, "cards: the first day still has its count (kept 14 days)")
	DiaryStore.today_override = D + 13
	DiaryStore.note_cards(1)
	var cb: Dictionary = read_json(P1)["cards_by_day"]
	ok(cb.has("2026-11-14") and cb.has("2026-11-27"), "cards: day 14 (D+13) still keeps the first day")
	DiaryStore.today_override = D + 14
	DiaryStore.note_cards(1)
	cb = read_json(P1)["cards_by_day"]
	ok(not cb.has("2026-11-14") and cb.has("2026-11-15") and cb.has("2026-11-28"), "cards: D+14 drops the first day, keeps the last 14 days")
	DiaryStore.today_override = D
	var raw := {"v": 1, "entries": [], "cards_by_day": {"2026-11-14": 3, "2026-11-13": 500, "2026-11-12": -5, "2026-11-11": "x", "nope": 5, "2026-13-40": 1, "2026-11-10": 2.7, "2026-01-01": 4, "2026-11-09": null}}
	write_text(P1, JSON.stringify(raw))
	reopen()
	var snap: Dictionary = read_json(P1)
	ok(DiaryStore.cards_today() == 3, "cards: a good value is read")
	DiaryStore.note_cards(1)
	cb = read_json(P1)["cards_by_day"]
	ok(cb["2026-11-13"] == 100 and cb["2026-11-12"] == 0 and cb["2026-11-10"] == 2 and not cb.has("2026-11-11") and not cb.has("nope") and not cb.has("2026-13-40") and not cb.has("2026-01-01") and not cb.has("2026-11-09"), "cards: junk keys/values are cleaned (clamped 0..100, old/odd keys dropped)")
	ok(snap is Dictionary and DiaryStore.last_dropped == 0 and not FileAccess.file_exists(P1 + ".bad"), "cards: junk in cards_by_day alone does not count as a lost entry")
	write_text(P1, JSON.stringify({"v": 1, "entries": [], "cards_by_day": [1, 2]}))
	reopen()
	ok(DiaryStore.cards_today() == 0, "cards: cards_by_day that is not a dictionary -> 0")
	write_text(P1, "{\"v\": 1, \"entries\": [], \"cards_by_day\": {\"2026-11-14\": 1e999, \"2026-11-13\": 1e300}}")
	reopen()
	DiaryStore.note_cards(0)
	ok(DiaryStore.cards_today() <= 100 and not DiaryStore.is_read_only(), "cards: a huge or infinite value does not crash and is clamped to 100")


func _test_invalid_adds() -> void:
	fresh()
	var r1: Dictionary = DiaryStore.add("ko", "text")
	var r2: Dictionary = DiaryStore.add("", "text")
	var r3: Dictionary = DiaryStore.add("ja", "")
	var r4: Dictionary = DiaryStore.add("ja", "  \n\t　 ")
	var r5: Dictionary = DiaryStore.add("ja", "あ".repeat(301))
	var r6: Dictionary = DiaryStore.add("ja", "\u0001\u0002")
	ok(not bool(r1["ok"]) and r1["reason"] == "invalid" and r2["reason"] == "invalid" and r3["reason"] == "invalid" and r4["reason"] == "invalid" and r5["reason"] == "invalid" and r6["reason"] == "invalid", "invalid: lang ko / empty lang / empty / blank / 301 chars / control characters only")
	ok(DiaryStore.entries().is_empty() and not FileAccess.file_exists(P1), "invalid: nothing was stored and no file was made")
	ok(bool(DiaryStore.add("ja", "あ".repeat(300))["ok"]), "invalid: exactly 300 chars is accepted")
	ok(bool(DiaryStore.add("ja", "あ".repeat(299) + "\u0001\u0001\u0001")["ok"]), "invalid: control characters do not count toward 300")
	ok(not bool(DiaryStore.add("ja", "あ".repeat(10000))["ok"]) and DiaryStore.entries().size() == 2, "invalid: a 10,000 char input is refused")
	var hangul: Dictionary = DiaryStore.add("ja", "한국어로 쓴 글")
	ok(bool(hangul["ok"]), "invalid: language of the text is DiaryLogic's job (the store only keeps what it is given)")


func _test_full() -> void:
	fresh()
	var list: Array = []
	for i in DiaryStore.MAX_ENTRIES:
		list.append(ent("d%06d" % (100000 + i), "x%d" % i, {"date": "2026-11-%02d" % (1 + i % 28)}))
	write_text(P1, file_of(list))
	reopen()
	ok(DiaryStore.entries().size() == 1000 and DiaryStore.last_dropped == 0, "full: 1,000 entries load")
	var r: Dictionary = DiaryStore.add("ja", "1001番目")
	ok(not bool(r["ok"]) and r["reason"] == "full" and DiaryStore.entries().size() == 1000, "full: the 1,001st is refused with reason full")
	ok(not read_text(P1).contains("1001番目"), "full: nothing was written for the refused entry")
	var dup: Dictionary = DiaryStore.add("ja", "x5")
	ok(not bool(dup["ok"]), "full: (x5 was on another date, so it is new -> refused)")
	DiaryStore.today_override = Plan.days_from_civil(2026, 11, 14)
	var again: Dictionary = DiaryStore.add("ja", "x13")
	ok(bool(again["ok"]) and bool(again["existed"]), "full: saving the same lang + date + text again is allowed (no new entry)")
	ok(DiaryStore.remove("d100000") and bool(DiaryStore.add("ja", "空きができた")["ok"]), "full: after removing one, a new entry fits")
	var over: Array = []
	for i in 1005:
		over.append(ent("d%06d" % (200000 + i), "o%d" % i))
	write_text(P1, file_of(over))
	reopen()
	var es: Array = DiaryStore.entries()
	ok(es.size() == 1000 and DiaryStore.last_dropped == 5 and (es[0] as Dictionary)["text"] == "o1004" and (es[999] as Dictionary)["text"] == "o5", "full: a file with 1,005 entries keeps the newest 1,000 (5 dropped)")
	ok(FileAccess.file_exists(P1 + ".bad") and read_text(P1 + ".bad").contains("o0"), "full: the original 1,005 are kept in the .bad file")


func _test_broken_files() -> void:
	# broken JSON
	fresh()
	write_text(P1, "{ this is not json " + MARK)
	reopen()
	ok(DiaryStore.entries().is_empty() and DiaryStore.last_load_status == "bad" and not DiaryStore.is_read_only(), "broken: broken JSON -> empty state")
	ok(FileAccess.file_exists(P1 + ".bad") and not FileAccess.file_exists(P1) and read_text(P1 + ".bad").contains(MARK), "broken: the broken file moved to .bad (text kept)")
	ok(bool(DiaryStore.add("ja", "新しい")["ok"]) and FileAccess.file_exists(P1), "broken: a new entry can be saved afterwards")
	# top-level array
	fresh()
	write_text(P1, "[1, 2, 3]")
	reopen()
	ok(DiaryStore.entries().is_empty() and DiaryStore.last_load_status == "bad" and FileAccess.file_exists(P1 + ".bad"), "broken: a top-level array is broken -> .bad")
	# blank file
	fresh()
	write_text(P1, "   \n")
	reopen()
	ok(DiaryStore.entries().is_empty() and DiaryStore.last_load_status == "empty" and not FileAccess.file_exists(P1 + ".bad"), "broken: a blank file is just empty")
	ok(bool(DiaryStore.add("ja", "空のあと")["ok"]), "broken: blank file then add works")
	# .bad rotation: older ones shift, at most 3
	fresh()
	for i in 5:
		write_text(P1, "{ broken %d" % i)
		reopen()
	ok(FileAccess.file_exists(P1 + ".bad") and FileAccess.file_exists(P1 + ".bad.1") and FileAccess.file_exists(P1 + ".bad.2") and not FileAccess.file_exists(P1 + ".bad.3"), "broken: .bad files rotate and at most 3 are kept")
	ok(read_text(P1 + ".bad").contains("broken 4") and read_text(P1 + ".bad.2").contains("broken 2"), "broken: the newest broken file is .bad")
	# entries is not a list
	fresh()
	write_text(P1, JSON.stringify({"v": 1, "entries": {"a": 1}, "cards_by_day": {}, "future_key": {"k": [1, 2]}}))
	reopen()
	ok(DiaryStore.entries().is_empty() and DiaryStore.last_dropped == 1 and FileAccess.file_exists(P1 + ".bad"), "broken: entries that is not a list -> empty, raw kept in .bad")
	DiaryStore.add("ja", "保存")
	var fk: Variant = read_json(P1)["future_key"]
	ok(fk is Dictionary and (fk["k"] as Array).size() == 2, "broken: an unknown top-level key survives a rewrite")
	# unknown top-level keys and a bigger version
	fresh()
	write_text(P1, JSON.stringify({"v": 3, "entries": [ent("d123456", "残る")], "cards_by_day": {}, "x_extra": 7}))
	reopen()
	DiaryStore.add("ja", "もう一つ")
	var back: Dictionary = read_json(P1)
	ok(int(back["v"]) == 3 and int(back["x_extra"]) == 7 and (back["entries"] as Array).size() == 2, "broken: a newer `v` and unknown keys are kept")
	# bad `v`
	fresh()
	write_text(P1, JSON.stringify({"v": "x", "entries": [ent("d123456", "v悪い")]}))
	reopen()
	DiaryStore.add("ja", "書く")
	ok(int(read_json(P1)["v"]) == 1 and DiaryStore.entries().size() == 2, "broken: a bad `v` becomes 1")


func _test_garbage_entries() -> void:
	fresh()
	var long_items: Array = [item("一です。"), item("二です。"), item("三です。"), item("四です。")]
	var rows: Array = [
		ent("d100001", "良い一つ目"),
		ent("d100002", "あ".repeat(300)),
		5, "text", null, [1],
		ent("d100003", "数字", {"text": 12345}),
		ent("d100004", "401", {"text": "あ".repeat(401)}),
		ent("d100005", "日付", {"date": "2026-13-40"}),
		ent("d100006", "日付2", {"date": "2026-02-30"}),
		ent("d100007", "日付3", {"date": 20261114}),
		ent("d100008", "状態", {"state": "weird"}),
		ent("d100009", "言語", {"lang": "fr"}),
		ent("d100010", "id 重複"),
		ent("d100010", "id 重複 二つ目"),
		ent("xyz", "id 悪い"),
		ent("d12", "id 短い"),
		ent("d123456789012345678901", "id 長い"),
		{"id": "d100011", "lang": "ja", "date": "2026-11-14", "state": "saved", "text": ""},
		{"id": "d100012", "lang": "ja", "date": "2026-11-14", "state": "saved"},
		ent("d100013", "項目4つ", {"state": "fixed", "items": long_items}),
		ent("d100014", "saved に項目", {"state": "saved", "items": [item("残らない")], "fixed_at": 5}),
		ent("d100015", "時刻悪い", {"created": "yesterday", "fixed_at": -9}),
		ent("d100016", "巨大時刻", {"created": 1.0e300}),
		ent("d100017", "制御\u0001文字\r\nあり"),
		ent("d100018", "fixed 項目なし", {"state": "fixed", "items": "nope", "fixed_at": 1731571300}),
	]
	write_text(P1, file_of(rows))
	reopen()
	var by: Dictionary = {}
	for e in DiaryStore.entries():
		by[str((e as Dictionary)["id"])] = e
	var kept: Array = by.keys()
	kept.sort()
	var want: Array = ["d100001", "d100002", "d100010", "d100013", "d100014", "d100015", "d100016", "d100017", "d100018"]
	ok(kept == want, "garbage: only well-formed entries are kept (%d of %d)" % [kept.size(), rows.size()])
	ok(DiaryStore.last_dropped == rows.size() - want.size(), "garbage: last_dropped counts the others (%d)" % DiaryStore.last_dropped)
	ok(by.has("d100010") and by["d100010"]["text"] == "id 重複", "garbage: of two entries with one id the first stays")
	ok((by["d100013"]["items"] as Array).size() == 3, "garbage: 4 items -> the first 3")
	ok((by["d100014"]["items"] as Array).is_empty() and by["d100014"]["fixed_at"] == 0, "garbage: a saved entry has no items")
	ok(by["d100015"]["created"] == 0 and by["d100018"]["fixed_at"] == 1731571300 and (by["d100018"]["items"] as Array).is_empty(), "garbage: bad times become 0, items that is not a list -> []")
	ok(by["d100016"]["created"] >= 0 and by["d100016"]["created"] <= DiaryStore.MAX_TS, "garbage: an infinite time is clamped")
	ok(by["d100017"]["text"] == "制御文字\nあり", "garbage: control characters are cleaned on read")
	ok(FileAccess.file_exists(P1 + ".bad") and read_text(P1 + ".bad").contains("id 悪い"), "garbage: the raw file (with the dropped entries) is kept as .bad")
	var rewritten: Variant = read_json(P1)
	ok(rewritten is Dictionary and (rewritten["entries"] as Array).size() == want.size(), "garbage: the cleaned file was written (valid entries only)")
	reopen()
	ok(DiaryStore.last_dropped == 0 and DiaryStore.entries().size() == want.size(), "garbage: the cleaned file loads with nothing dropped")
	# an unreadable file after a drop: do not write over it
	fresh()
	write_text(P1, file_of([ent("d100001", "良い"), 5]))
	Progress.write_hook = func(_t: String, _x: String) -> bool: return false
	reopen()
	Progress.write_hook = Callable()
	ok(DiaryStore.is_read_only() and FileAccess.file_exists(P1) and read_text(P1).contains("良い"), "garbage: when the cleaned file cannot be written the original is put back and the store is read-only")
	ok(DiaryStore.add("ja", "x")["reason"] == "read_only", "garbage: ... so a new entry is refused")


func _test_read_only() -> void:
	fresh()
	var keep: String = file_of([ent("d100001", "読めない " + MARK)])
	write_text(P1, keep)
	_toasts.clear()
	Progress.open_hook = func(_p: String) -> Variant: return null
	reopen()
	Progress.open_hook = Callable()
	ok(DiaryStore.is_read_only() and DiaryStore.last_load_status == "unreadable" and DiaryStore.entries().is_empty(), "read-only: a file that cannot be opened -> read-only, empty")
	ok(DiaryStore.add("ja", "新しい")["reason"] == "read_only", "read-only: add -> reason read_only")
	ok(not DiaryStore.set_fixed("d100001", []) and not DiaryStore.remove("d100001") and DiaryStore.clear() == 0, "read-only: set_fixed / remove / clear do nothing")
	DiaryStore.note_cards(3)
	ok(DiaryStore.cards_today() == 0, "read-only: note_cards does nothing")
	ok(read_text(P1) == keep and not FileAccess.file_exists(P1 + ".bad"), "read-only: the file is untouched (same bytes, no .bad)")
	ok(_toasts.size() == 1 and not str(_toasts[0]).contains(MARK), "read-only: one notice, and it has no diary text")
	reopen()
	ok(not DiaryStore.is_read_only() and DiaryStore.entries().size() == 1, "read-only: the next load reads the file normally")


func _test_write_failure() -> void:
	fresh()
	var a: String = str(DiaryStore.add("ja", "最初 " + MARK)["id"])
	var before: String = read_text(P1)
	# a write that fails halfway (half the text goes to .tmp, then false)
	Progress.write_hook = func(tmp: String, text: String) -> bool:
		write_text(tmp, text.substr(0, text.length() / 2))
		return false
	var r: Dictionary = DiaryStore.add("ja", "二番目 " + MARK)
	ok(not bool(r["ok"]) and r["reason"] == "write_failed", "write failure: add -> reason write_failed")
	ok(DiaryStore.entries().size() == 1 and read_text(P1) == before, "write failure: memory and file both keep the old state")
	ok(not FileAccess.file_exists(P1 + ".tmp"), "write failure: no half-written .tmp is left")
	ok(not DiaryStore.set_fixed(a, [item("直し")]) and DiaryStore.get_entry(a)["state"] == "saved", "write failure: set_fixed fails and rolls back")
	ok(not DiaryStore.remove(a) and DiaryStore.entries().size() == 1, "write failure: remove fails and rolls back")
	ok(DiaryStore.clear() == 0 and DiaryStore.entries().size() == 1, "write failure: clear fails and rolls back")
	DiaryStore.note_cards(2)
	ok(DiaryStore.cards_today() == 0, "write failure: note_cards rolls back")
	var dup: Dictionary = DiaryStore.add("ja", "最初 " + MARK)
	ok(not bool(dup["ok"]) and int(DiaryStore.get_entry(a)["created"]) == 1731571200, "write failure: refreshing an old entry rolls back too")
	Progress.write_hook = Callable()
	ok(bool(DiaryStore.add("ja", "二番目 " + MARK)["ok"]) and DiaryStore.entries().size() == 2, "write failure: works again once the disk does")
	reopen()
	ok(DiaryStore.entries().size() == 2, "write failure: both entries are on disk")


func _test_guard() -> void:
	ok(Progress.REAL_FILE_NAMES.has("diary.json"), "guard: diary.json is a protected real file name")
	ok(Progress.test_guard, "guard: the test guard is on in this run")
	ok(Progress.guard_blocks("user://diary.json"), "guard: writing the real user://diary.json is blocked")
	ok(not Progress.guard_blocks(P1) and not Progress.guard_blocks("user://test_guard/diary.json"), "guard: test paths are allowed")
	var real_before: bool = FileAccess.file_exists("user://diary.json")
	DiaryStore.path = "user://diary.json"
	DiaryStore.forget()
	ok(DiaryStore.effective_path() == "user://test_guard/diary.json", "guard: the default path is redirected to user://test_guard/diary.json")
	var r: Dictionary = DiaryStore.add("ja", "ガード " + MARK)
	ok(bool(r["ok"]) and FileAccess.file_exists("user://test_guard/diary.json"), "guard: the entry went to the test_guard folder")
	ok(FileAccess.file_exists("user://diary.json") == real_before, "guard: the real user://diary.json was not created or changed")
	ok(read_text("user://test_guard/diary.json").contains("ガード"), "guard: the redirected file has the entry")
	DiaryStore.path = P1
	DiaryStore.forget()
	var gd: String = ProjectSettings.globalize_path("user://test_guard/diary.json")
	DirAccess.remove_absolute(gd)
	ok(not FileAccess.file_exists("user://test_guard/diary.json"), "guard: test cleanup of the redirected file")
	var direct: bool = Progress.write_text_atomic("user://diary.json", "{}")
	ok(not direct and FileAccess.file_exists("user://diary.json") == real_before, "guard: Progress.write_text_atomic refuses the real diary.json")


func _test_not_in_sync_or_logs() -> void:
	fresh()
	var r: Dictionary = DiaryStore.add("ja", "秘密の日記 " + MARK)
	DiaryStore.set_fixed(str(r["id"]), [item("直した " + MARK + " 文です。")])
	# Store.reset_progress() does not delete the diary
	Store.progress = Progress.blank()
	Store.progress_path = PPROG
	StudyLog.path = PLOG
	StudyLog.load_from_disk()
	Store.reset_progress()
	ok(DiaryStore.entries().size() == 1 and (DiaryStore.entries()[0] as Dictionary)["id"] == r["id"], "reset: Store.reset_progress() does not delete the diary")
	reopen()
	ok(DiaryStore.entries().size() == 1 and not DiaryStore.get_entry(str(r["id"])).is_empty(), "reset: the diary is still on disk after a reset and a restart")
	# the diary text is in no progress / studylog / sync document
	Store.add_review([{"lang": "ja", "target": "復習カード", "reading": "", "ko": "", "note": ""}])
	StudyLog.add_event("ja", "talks", 1)
	StudyLog.flush()
	var prog_text: String = JSON.stringify(Store.progress)
	var log_text: String = JSON.stringify(StudyLog.snapshot())
	var doc: Dictionary = SyncDoc.extract(Store.progress, StudyLog.snapshot(), Store.prefs, 0)
	var doc_text: String = JSON.stringify(doc)
	ok(doc_text.length() > 50, "sync: SyncDoc.extract gives a real document (the scan below looks at something)")
	ok(not prog_text.contains(MARK) and not log_text.contains(MARK) and not doc_text.contains(MARK), "sync: no diary text in Store.progress, StudyLog.snapshot() or the SyncDoc")
	ok(not doc_text.contains("diary") and not log_text.contains("diary") and not prog_text.contains("diary"), "sync: no `diary` key in those three")
	ok(not read_text(PPROG).contains(MARK) and not read_text(PLOG).contains(MARK) and not read_text(PPREFS).contains(MARK), "sync: no diary text in the progress / studylog / prefs files")
	var hit := ""
	var da: DirAccess = DirAccess.open("res://scripts/sync")
	for f in da.get_files():
		if f.ends_with(".gd") and FileAccess.get_file_as_string("res://scripts/sync/" + f).to_lower().contains("diary"):
			hit = f
	ok(hit == "", "sync: no file in scripts/sync mentions the diary")
	var st: String = FileAccess.get_file_as_string("res://scripts/core/study_log.gd") + FileAccess.get_file_as_string("res://scripts/autoload/store.gd")
	ok(not st.to_lower().contains("diarystore"), "sync: study_log.gd and store.gd do not call DiaryStore")
	ok(_toasts.filter(func(t: Variant) -> bool: return str(t).contains(MARK)).is_empty(), "log: no toast carried diary text")
	# the diary never added a review card by itself
	ok((Store.progress["review"] as Array).size() == 1, "reset: DiaryStore never touches the review list")


func _test_card_flow_quoting_why() -> void:
	# the reviewer's scenario: the AI reason quotes part of the original; the card goes to the review list, saves and syncs
	fresh()
	Store.progress = Progress.blank()
	var orig := "きのう " + MARK + " えいがをみた。"
	var lk: Dictionary = DiaryStore.add("ja", orig)
	var why := "「きのう " + MARK + "」を直しました。"
	var cl: Dictionary = DiaryLogic.clean_fix(orig, {"fix": "昨日、映画を見ました。", "fix_ko": why, "reading": "きのう、えいがをみました。", "pron": "キノー"}, "ja")
	ok(str(cl["why"]).contains(MARK), "card flow: the screen still has the AI reason (it is shown inside the diary screen)")
	DiaryStore.set_fixed(str(lk["id"]), [{"orig": cl["orig"], "fix": cl["fix"], "why": cl["why"], "reading": cl["reading"], "pron": cl["pron"], "same": cl["same"], "card": false}])
	var cards: Array = DiaryLogic.cards_for(DiaryStore.get_entry(str(lk["id"])), DiaryStore.cards_today())
	ok(cards.size() == 1 and not JSON.stringify(cards).contains(MARK) and (cards[0] as Dictionary)["note"] == DiaryLogic.CARD_NOTE, "card flow: the card has no part of the original and a fixed note")
	var added: int = Store.add_review(cards)
	DiaryStore.note_cards(added)
	Store.save_progress()
	StudyLog.add_event("ja", "talks", 1)
	StudyLog.flush()
	var doc_text: String = JSON.stringify(SyncDoc.extract(Store.progress, StudyLog.snapshot(), Store.prefs, 0))
	var blob: String = JSON.stringify(Store.progress) + JSON.stringify(StudyLog.snapshot()) + doc_text + read_text(PPROG) + read_text(PLOG)
	ok(added == 1 and doc_text.contains("昨日、映画を見ました。") and not blob.contains(MARK), "card flow: the fixed sentence reaches the review list and the SyncDoc, the original does not")
	ok(read_text(P1).contains(MARK), "card flow: the original is only in the diary file")


func _test_source_never_logs() -> void:
	for f in ["diary_store.gd", "diary_logic.gd"]:
		var src: String = FileAccess.get_file_as_string("res://scripts/core/" + f)
		var bad := false
		for token in ["print(", "print_rich(", "printerr(", "push_warning(", "push_error(", "prints(", "printt(", "OS.alert(", "HTTP" + "Request", "OS.shell" + "_open"]:
			if src.contains(token):
				bad = true
		ok(not bad, "source: %s has no print / push_* / network call" % f)
	var toast_lines := 0
	for line in FileAccess.get_file_as_string("res://scripts/core/diary_store.gd").split("\n"):
		if line.contains("Toast."):
			toast_lines += 1
			if line.contains("text") or line.contains("%"):
				toast_lines += 100
	ok(toast_lines == 1, "source: diary_store.gd has exactly one Toast line and it carries no text")
	ok(not FileAccess.get_file_as_string("res://scripts/core/diary_store.gd").contains("Color(\"#"), "source: no Color(\"#...\") literal")


# ---------------------------------------------------------------- 검사기도 실패할 수 있어야 한다

func _selfchecks() -> void:
	# 1) a file with a 401-char entry must lose that entry: the same check, fed a wrong expectation, must say "not equal"
	fresh()
	write_text(P1, file_of([ent("d100001", "x", {"text": "あ".repeat(401)})]))
	reopen()
	var kept_401: bool = DiaryStore.entries().size() == 1
	print("  selfcheck FAIL-as-expected 401-char entry kept (should be dropped): ", "OK" if not kept_401 else "NOT-DETECTED")
	ok(not kept_401, "selfcheck: a 401-char entry is not kept")
	# 2) the marker scan really finds a marker
	var leaked: bool = JSON.stringify({"a": [MARK]}).contains(MARK)
	print("  selfcheck FAIL-as-expected marker scan (marker in a fake document): ", "OK" if leaked else "NOT-DETECTED")
	ok(leaked, "selfcheck: the marker scan finds a marker")
	# 3) the source scan really finds print(
	var fake := "func x():\n\tprint(text)\n"
	var found: bool = fake.contains("print(")
	print("  selfcheck FAIL-as-expected source scan (print( in a fake source): ", "OK" if found else "NOT-DETECTED")
	ok(found, "selfcheck: the print( scan finds print(")
	# 4) a store that is not guarded would hit the real name: the guard check says so for the real path
	var blocked: bool = Progress.guard_blocks("user://diary.json")
	var not_blocked: bool = Progress.guard_blocks("user://test_diary_c1_a.json")
	print("  selfcheck FAIL-as-expected guard (real path blocked, test path not): ", "OK" if blocked and not not_blocked else "NOT-DETECTED")
	ok(blocked and not not_blocked, "selfcheck: guard_blocks separates the real name from a test name")
	# 5) cap check: a 2-day-old card key that should be dropped is dropped
	fresh()
	write_text(P1, JSON.stringify({"v": 1, "entries": [], "cards_by_day": {"2026-01-01": 9}}))
	reopen()
	DiaryStore.note_cards(1)
	var still: bool = (read_json(P1)["cards_by_day"] as Dictionary).has("2026-01-01")
	print("  selfcheck FAIL-as-expected old cards day kept (should be pruned): ", "OK" if not still else "NOT-DETECTED")
	ok(not still, "selfcheck: an old cards_by_day key is pruned")
