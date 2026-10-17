extends Node
## 1.1.1: progress.json / prefs.json are written through a .tmp file (a failure while writing keeps the old file),
## unreadable-JSON files are kept as .bad, old-format files still load, StudyLog.add_mission keeps the best goal count.
##   godot --headless --path <project> res://tests/persist_test.tscn
## Exit code 0 = all passed. Last line: "== persist result: N passed, 0 failed =="
## Only user://persist_test_* files are used: Store.progress_path / prefs_path / StudyLog.path are pointed there and
## restored at the end, so the real progress.json / prefs.json / studylog.json are never written.

const PROG := "user://persist_test_progress.json"
const PREFS := "user://persist_test_prefs.json"
const LOG := "user://persist_test_studylog.json"

var passed: int = 0
var failed: int = 0
var _old: Array = []
var _toasts: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


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


func rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _cleanup() -> void:
	for base in [PROG, PREFS, LOG]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2", ".bad.3"]:
			rm(base + suffix)


## Imitates a crash while the temp file is being written: half of the text is on disk, then the write "fails".
func _half_write(tmp: String, text: String) -> bool:
	write_text(tmp, text.substr(0, text.length() / 2))
	return false


func _ready() -> void:
	print("== persist start ==")
	_old = [Store.progress_path, Store.prefs_path, StudyLog.path, Store.progress.duplicate(true), Store.prefs.duplicate(true)]
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	Toast.message.connect(func(t: String, k: String) -> void: _toasts.append([t, k]))
	_cleanup()

	_test_progress_write_failure()
	_test_prefs_write_failure()
	_test_broken_files()
	_test_old_formats()
	_test_unreadable()
	_test_mission_done_goals()

	_cleanup()
	Progress.write_hook = Callable()
	Progress.open_hook = Callable()
	Store.progress_path = _old[0]
	Store.prefs_path = _old[1]
	StudyLog.path = _old[2]
	Store.progress = _old[3]
	Store.prefs = _old[4]
	Store.progress_read_only = false
	Store.prefs_read_only = false
	StudyLog.load_from_disk() ## the restored path is only read here, never written
	print("== persist result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- progress.json

func _test_progress_write_failure() -> void:
	print("[progress.json: a failed write keeps the old file]")
	_cleanup()
	Store.progress = Progress.blank()
	Store.add_xp("en", 40)
	Store.save_progress()
	var good: String = read_text(PROG)
	ok(good != "" and int(JSON.parse_string(good)["xp"]["en"]) == 40, "normal save writes the file")
	ok(not FileAccess.file_exists(PROG + ".tmp"), "normal save leaves no .tmp file")
	# crash while writing
	Progress.write_hook = _half_write
	Store.add_xp("en", 999)
	_toasts.clear()
	Store.save_progress()
	Progress.write_hook = Callable()
	ok(read_text(PROG) == good, "write fails half way: the original file is byte-for-byte unchanged")
	ok(not FileAccess.file_exists(PROG + ".tmp"), "write fails half way: the half-written .tmp file is removed")
	ok(_toasts.size() == 1 and _toasts[0][1] == "error", "write fails half way: the user gets one error message")
	# the next save works and includes the newer value
	Store.save_progress()
	ok(int(JSON.parse_string(read_text(PROG))["xp"]["en"]) == 1039, "next save succeeds (xp 40 + 999)")
	ok(Progress.save_file(PROG, Store.progress), "Progress.save_file() returns true on success")
	Progress.write_hook = _half_write
	ok(not Progress.save_file(PROG, Store.progress), "Progress.save_file() returns false when the write fails")
	Progress.write_hook = Callable()


func _test_prefs_write_failure() -> void:
	print("[prefs.json: a failed write keeps the old file]")
	_cleanup()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.set_pref("tts_speed", 1.25)
	var good: String = read_text(PREFS)
	ok(good != "" and float(JSON.parse_string(good)["tts_speed"]) == 1.25, "normal save writes prefs")
	Progress.write_hook = _half_write
	Store.set_pref("tts_speed", 0.5)
	Progress.write_hook = Callable()
	ok(read_text(PREFS) == good, "write fails half way: prefs file unchanged")
	ok(not FileAccess.file_exists(PREFS + ".tmp"), "write fails half way: no .tmp left")
	ok(float(Store.prefs["tts_speed"]) == 0.5, "the in-memory value is kept (the next save writes it)")
	Store.set_pref("auto_speak", false)
	var back: Dictionary = JSON.parse_string(read_text(PREFS))
	ok(float(back["tts_speed"]) == 0.5 and back["auto_speak"] == false, "next save succeeds")


# ---------------------------------------------------------------- broken files -> .bad

func _test_broken_files() -> void:
	print("[broken files are kept as .bad]")
	_cleanup()
	var junk := "{\"xp\": {\"en\": 5, "  # cut off in the middle
	write_text(PROG, junk)
	Store.load_progress()
	ok(Progress.last_load_status == "bad" and not Store.progress_read_only, "progress: cut-off JSON -> status 'bad'")
	ok(read_text(PROG + ".bad") == junk and not FileAccess.file_exists(PROG), "progress: the broken file is kept as .bad, original path is free")
	ok(int(Store.progress["xp"]["en"]) == 0 and (Store.progress["review"] as Array).is_empty(), "progress: starts empty")
	Store.add_xp("ja", 7)
	Store.save_progress()
	ok(int(JSON.parse_string(read_text(PROG))["xp"]["ja"]) == 7 and read_text(PROG + ".bad") == junk, "progress: next save is valid and .bad is still there")
	# a second breakage does not overwrite the first .bad
	write_text(PROG, "[1,2]")
	Store.load_progress()
	ok(read_text(PROG + ".bad") == "[1,2]" and read_text(PROG + ".bad.1") == junk, "progress: a JSON array is broken too; the older .bad shifts to .bad.1 (never overwritten)")
	# prefs
	write_text(PREFS, "not json at all")
	Store.load_prefs()
	ok(read_text(PREFS + ".bad") == "not json at all" and not FileAccess.file_exists(PREFS), "prefs: broken file kept as .bad")
	ok(Store.prefs["lang"] == "en" and Store.prefs["show_fix"] == true, "prefs: defaults are used")
	Store.set_pref("lang", "ja")
	ok(JSON.parse_string(read_text(PREFS))["lang"] == "ja" and read_text(PREFS + ".bad") == "not json at all", "prefs: next save is valid, .bad kept")
	# empty file: nothing worth keeping
	write_text(PROG, "")
	Store.load_progress()
	ok(Progress.last_load_status == "empty" and not FileAccess.file_exists(PROG + ".bad.2"), "progress: an empty file starts empty without a new .bad")
	# missing file
	rm(PROG)
	Store.load_progress()
	ok(Progress.last_load_status == "new" and not Store.progress_read_only, "progress: missing file -> new, saving allowed")


# ---------------------------------------------------------------- files written by earlier versions

func _test_old_formats() -> void:
	print("[files from earlier versions]")
	_cleanup()
	# v1.0: no FSRS fields, no known_words, no updatedAt
	var old_progress := {
		"start": "2026-09-01",
		"checks": {"en-1-w0": true},
		"days": {"2026-10-01": {"en": true}},
		"xp": {"en": 120, "ja": 15},
		"stats": {"en": {"lessons": 4, "talks": 1}, "ja": {"lessons": 0, "talks": 0}},
		"review": [{"id": "r1", "lang": "en", "target": "See you tomorrow.", "reading": "", "ko": "내일 봐요", "note": ""}],
	}
	write_text(PROG, JSON.stringify(old_progress, "\t"))
	Store.load_progress()
	ok(Progress.last_load_status == "ok" and not FileAccess.file_exists(PROG + ".bad"), "old progress.json: read normally, not treated as broken")
	var p: Dictionary = Store.progress
	ok(p["start"] == "2026-09-01" and int(p["xp"]["en"]) == 120 and p["checks"].has("en-1-w0") and bool(p["days"]["2026-10-01"]["en"]), "old progress.json: start / xp / checks / days kept")
	ok((p["review"] as Array).size() == 1 and p["review"][0]["target"] == "See you tomorrow." and int(p["review"][0]["due"]) > 0, "old progress.json: review card migrated to a new FSRS card")
	ok(p["known_words"]["en"] == [] and int(p["updatedAt"]) == 0, "old progress.json: known_words / updatedAt get defaults")
	Store.save_progress()
	var after: Dictionary = JSON.parse_string(read_text(PROG))
	ok(after["review"][0]["target"] == "See you tomorrow." and after["review"][0].has("stability") and int(after["xp"]["ja"]) == 15, "old progress.json: saving it again keeps the data (now with FSRS fields)")
	# the file written by the new code is read back by the same loader, FSRS data intact
	Store.load_progress()
	ok(Store.progress["review"][0]["id"] == "r1" and Store.progress["review"][0]["due"] == after["review"][0]["due"], "round trip through the atomic writer keeps the card")
	# old prefs: only a few keys, an unknown one
	write_text(PREFS, "{\"lang\": \"ja\", \"tts_speed\": 0.8, \"legacy_key\": 3}")
	Store.load_prefs()
	ok(Store.prefs["lang"] == "ja" and float(Store.prefs["tts_speed"]) == 0.8 and int(Store.prefs["legacy_key"]) == 3, "old prefs.json: values kept, unknown keys kept")
	ok(Store.prefs["show_fix"] == true and Store.prefs["tts_voice_en"] == "af_heart", "old prefs.json: missing keys get defaults")


# ---------------------------------------------------------------- unreadable (locked) files

func _test_unreadable() -> void:
	print("[unreadable file: never overwritten]")
	_cleanup()
	var good := "{\"xp\": {\"en\": 55, \"ja\": 0}}"
	write_text(PROG, good)
	write_text(PREFS, "{\"lang\": \"ja\"}")
	Progress.open_hook = func(_p: String) -> Variant: return null
	_toasts.clear()
	Store.load_progress()
	Store.load_prefs()
	Progress.open_hook = Callable()
	ok(Store.progress_read_only and Store.prefs_read_only, "files exist but cannot be opened: read-only for this run")
	ok(not _toasts.is_empty(), "the user is told")
	Store.add_xp("en", 1)
	Store.save_progress()
	Store.set_pref("lang", "en")
	ok(read_text(PROG) == good, "progress.json is not overwritten")
	ok(read_text(PREFS) == "{\"lang\": \"ja\"}", "prefs.json is not overwritten")
	ok(not FileAccess.file_exists(PROG + ".bad") and not FileAccess.file_exists(PREFS + ".bad") and not FileAccess.file_exists(PROG + ".tmp"), "no .bad / .tmp created")
	Store.load_progress()
	Store.load_prefs()
	ok(not Store.progress_read_only and not Store.prefs_read_only and int(Store.progress["xp"]["en"]) == 55 and Store.prefs["lang"] == "ja", "next load: readable again, old data is there")


# ---------------------------------------------------------------- StudyLog.add_mission

func _test_mission_done_goals() -> void:
	print("[StudyLog.add_mission keeps the best goal count]")
	_cleanup()
	StudyLog.load_from_disk()
	StudyLog.add_mission("en", "cafe_order", 3, 4)
	StudyLog.add_mission("en", "cafe_order", 1, 1) # a worse replay
	var m: Dictionary = StudyLog.mission_best("cafe_order")
	ok(int(m["stars"]) == 3 and int(m["done_goals"]) == 4 and int(m["plays"]) == 2, "worse replay: stars 3 and goals 4 are kept, plays counted -> %s" % str(m))
	StudyLog.add_mission("en", "cafe_order", 3, 5)
	ok(int(StudyLog.mission_best("cafe_order")["done_goals"]) == 5, "better replay raises goals")
	StudyLog.update_mission_best("en", "cafe_order", 3, 2)
	ok(int(StudyLog.mission_best("cafe_order")["done_goals"]) == 5, "update_mission_best agrees (never lowers)")
