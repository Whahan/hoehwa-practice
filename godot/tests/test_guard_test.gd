extends Node
## Test guard (Store.apply_test_guard + Progress.guard_blocks): a test scene never touches the user's real files.
##   godot --headless --path <project> res://tests/test_guard_test.tscn
##   (optional) ... res://tests/test_guard_test.tscn -- --remote-file=user://test_guard_remote_x.json
## Exit code 0 = all checks passed. Last line: "== test guard result: N passed, 0 failed =="
## The write attempts to the real file names use a write_hook that always fails, so even a broken safety net cannot
## overwrite a real file from here (the hook being called = the net let the write through = FAIL).

const REAL := ["prefs.json", "progress.json", "studylog.json", "remote.json", "curriculum.json"]

var passed: int = 0
var failed: int = 0
var _hook_calls: int = 0


func _ready() -> void:
	print("== test guard start ==")
	_test_on_and_paths()
	_test_detection()
	_test_net()
	_test_writers()
	_test_override()
	_test_remote_file_arg()
	print("== test guard result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _test_on_and_paths() -> void:
	print("[guard is on, default paths moved]")
	ok(Store.test_guard_on, "Store.test_guard_on")
	ok(Progress.test_guard, "Progress.test_guard")
	ok(Store.prefs_path == "user://test_guard/prefs.json", "prefs_path -> " + Store.prefs_path)
	ok(Store.progress_path == "user://test_guard/progress.json", "progress_path -> " + Store.progress_path)
	ok(Store.curriculum_cache_path == "user://test_guard/curriculum.json", "curriculum_cache_path -> " + Store.curriculum_cache_path)
	ok(StudyLog.path == "user://test_guard/studylog.json", "StudyLog.path -> " + StudyLog.path)
	var has_arg := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--remote-file="):
			has_arg = true
	if not has_arg:
		ok(Api.remote_path == "user://test_guard/remote.json", "Api.remote_path -> " + Api.remote_path)
	for p in [Store.prefs_path, Store.progress_path, Store.curriculum_cache_path, StudyLog.path]:
		ok(String(p).begins_with("user://test_guard/"), "under test_guard: " + String(p))
	ok(Store.prefs_path != Store.PREFS_PATH and Store.progress_path != Store.PROGRESS_PATH and Store.curriculum_cache_path != Store.CURRICULUM_CACHE, "none of them is the real constant")
	ok(Store.GUARD_DIR == "user://test_guard" and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(Store.GUARD_DIR)), "the guard folder exists")


func _test_detection() -> void:
	print("[what counts as a test run]")
	ok(Store.is_test_run(PackedStringArray(["--headless", "--path", "godot", "res://tests/smoke.tscn"]), false), "res://tests/ scene")
	ok(Store.is_test_run(PackedStringArray(["res://tests/x.tscn"]), false), "res://tests/x.tscn")
	ok(Store.is_test_run(PackedStringArray(["D:\\app\\godot\\tests\\x.tscn"]), false), "file-system path of a tests scene")
	ok(not Store.is_test_run(PackedStringArray(), false), "no arguments = normal run")
	ok(not Store.is_test_run(PackedStringArray(["--path", "godot", "--quit-after", "60"]), false), "main scene run")
	ok(not Store.is_test_run(PackedStringArray(["res://scenes/main.tscn"]), false), "explicit main scene")
	ok(not Store.is_test_run(PackedStringArray(["--editor", "--path", "godot"]), false), "editor")
	ok(not Store.is_test_run(PackedStringArray(["res://tests/x.tscn"]), true), "exported app never")


func _test_net() -> void:
	print("[safety net: real file names are never written]")
	Progress.write_hook = func(_tmp: String, _text: String) -> bool:
		_hook_calls += 1
		return false
	for n in REAL:
		var real: String = "user://" + n
		ok(Progress.guard_blocks(real), "guard_blocks " + real)
		ok(Progress.guard_blocks(ProjectSettings.globalize_path(real)), "guard_blocks (absolute) " + n)
		var before: int = _hook_calls
		var r: bool = Progress.write_text_atomic(real, "{}")
		ok(not r and _hook_calls == before, "write_text_atomic(%s) refused before any write" % real)
		ok(not Progress.save_file(real, {}) and _hook_calls == before, "save_file(%s) refused" % real)
	ok(Progress.guard_blocks("user://sub/prefs.json"), "a real name in another user:// folder is refused too")
	# what stays allowed
	for okp in ["user://test_guard/prefs.json", "user://test_x_progress.json", "user://t5_progress.json", "user://tts_test_progress.json", "user://reading/cache.json"]:
		ok(not Progress.guard_blocks(okp), "allowed: " + okp)
	var before2: int = _hook_calls
	ok(not Progress.write_text_atomic("user://test_guard/prefs.json", "{}") and _hook_calls == before2 + 1, "a guard path reaches the write (hook said no)")
	Progress.write_hook = Callable()
	# a real write to a guard path works and reads back
	var gp: String = Store.GUARD_DIR + "/net_probe.json"
	ok(Progress.write_text_atomic(Store.prefs_path, JSON.stringify({"probe": 1})), "write to Store.prefs_path (guard folder) works")
	ok(int((Progress.read_json_file(Store.prefs_path)["data"] as Dictionary).get("probe", 0)) == 1, "...and reads back")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.prefs_path))
	ok(Progress.write_text_atomic(gp, "{}") and FileAccess.file_exists(gp), "any other guard-folder file works")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gp))


func _test_writers() -> void:
	print("[StudyLog and RemoteLink refuse real file names]")
	# Probe folder: not user://test*, so the real names inside it are refused like the real ones. If a check were
	# missing, only this probe folder gets the file (never the user's real file).
	var dir := "user://guardprobe"
	var gdir: String = ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(gdir)
	var saved_path: String = StudyLog.path
	StudyLog.path = dir + "/studylog.json"
	ok(Progress.guard_blocks(StudyLog.path), "the probe path counts as a real file")
	ok(not StudyLog._write_text("{}"), "StudyLog._write_text refuses a real file name")
	ok(not FileAccess.file_exists(StudyLog.path) and not FileAccess.file_exists(StudyLog.path + ".tmp"), "...and wrote nothing")
	StudyLog.path = Store.GUARD_DIR + "/studylog.json"
	ok(StudyLog._write_text("{}") and FileAccess.file_exists(StudyLog.path), "StudyLog._write_text still works in the guard folder")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(StudyLog.path))
	StudyLog.path = saved_path
	var conn := {"base_url": "http://127.0.0.1:1", "token": "t", "device_id": "d", "server_name": "s"}
	var rp: String = dir + "/remote.json"
	ok(not RemoteLink.save(conn, rp), "RemoteLink.save refuses a real file name")
	ok(not FileAccess.file_exists(rp) and not FileAccess.file_exists(rp + ".tmp"), "...and wrote nothing")
	RemoteLink.clear_token(rp)
	ok(not FileAccess.file_exists(rp), "RemoteLink.clear_token cannot create it either")
	var f := FileAccess.open(rp, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	RemoteLink.delete_file(rp)
	ok(FileAccess.file_exists(rp), "RemoteLink.delete_file refuses a real file name")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rp))
	var gp: String = Store.GUARD_DIR + "/remote.json"
	ok(RemoteLink.save(conn, gp) and FileAccess.file_exists(gp), "RemoteLink.save still works in the guard folder")
	RemoteLink.delete_file(gp)
	ok(not FileAccess.file_exists(gp), "RemoteLink.delete_file still works in the guard folder")
	DirAccess.remove_absolute(gdir)


func _test_override() -> void:
	print("[a path the test sets itself wins]")
	var saved_prefs: String = Store.prefs_path
	var saved_prog: String = Store.progress_path
	var saved_cache: String = Store.curriculum_cache_path
	var saved_log: String = StudyLog.path
	var own_prefs := "user://test_guard_own_prefs.json"
	var own_prog := "user://test_guard_own_progress.json"
	Store.prefs_path = own_prefs
	Store.progress_path = own_prog
	StudyLog.path = "user://test_guard_own_studylog.json"
	ok(Store.prefs_path == own_prefs and Store.progress_path == own_prog and StudyLog.path == "user://test_guard_own_studylog.json", "own paths are kept")
	Store.set_pref("show_ko", true)
	ok(FileAccess.file_exists(own_prefs), "save_prefs wrote the test's own file")
	ok(not FileAccess.file_exists(saved_prefs), "...and not the guard default")
	Store.save_progress()
	ok(FileAccess.file_exists(own_prog), "save_progress wrote the test's own file")
	for p in [own_prefs, own_prog, own_prefs + ".tmp", own_prog + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	Store.prefs_path = saved_prefs
	Store.progress_path = saved_prog
	Store.curriculum_cache_path = saved_cache
	StudyLog.path = saved_log
	Store.prefs["show_ko"] = false
	# the default-path save of this process stays inside the guard folder
	Store.save_prefs()
	ok(FileAccess.file_exists(Store.GUARD_DIR + "/prefs.json"), "default save_prefs lands in the guard folder")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.GUARD_DIR + "/prefs.json"))


func _test_remote_file_arg() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--remote-file="):
			print("[--remote-file= wins over the guard default]")
			ok(Api.remote_path == a.substr(14), "Api.remote_path == " + a.substr(14))
