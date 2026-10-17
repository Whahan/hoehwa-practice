extends Node
## W0 기준선: 화면 6개(오늘·레슨·대화·읽기·복습·로드맵)의 생성 시간·노드 수·리소스 수를 잰다 (헤드리스, 서버 없이).
##   기준값 만들기:  godot --headless --path <project> res://tests/ui_perf_test.tscn -- --out=<파일>
##   비교하기:      godot --headless --path <project> res://tests/ui_perf_test.tscn -- --baseline=<파일> --max-ratio=1.3
## 출력: 화면마다 5번 "PERF view=<k> nodes=<n> res=<r> build_ms=<t>", 그 뒤 중앙값 줄 "PERF_MEDIAN ...".
##   nodes 는 화면을 붙이기 전·후의 OBJECT_NODE_COUNT 차이, res 는 OBJECT_COUNT 차이(OBJECT_RESOURCE_COUNT 는 StyleBoxFlat 을
##   세지 않아서 쓰지 않음, _check_res_monitor 가 확인). build_ms 는 생성+_ready+refresh 까지, 워밍업 1회 뒤 5회의 중앙값.
## 마지막 줄: "== ui_perf: N passed, M failed ==". 종료 코드 0 = 전부 통과.
## 실제 사용자 파일(progress/prefs/studylog/remote/curriculum)은 건드리지 않는다: 모든 경로를 user://w0_perf_* 로 바꾸고
## Api.base_url 을 "" 로 둬서 네트워크를 쓰지 않는다. 엔진(Backend)은 기동하지 않는다.

const RUNS := 5
const VIEWS := ["today", "lesson", "talk", "reading", "review", "roadmap"]
const REVIEW_FIXTURE := 200
const TMP_PREFIX := "user://w0_perf_"
const READING_DIR := "user://w0_perf_reading"
const PROG := "user://w0_perf_progress.json"
const PREFS := "user://w0_perf_prefs.json"
const LOG := "user://w0_perf_studylog.json"
const CURR := "user://w0_perf_curriculum.json"
const REMOTE := "user://w0_perf_remote.json"

var passed: int = 0
var failed: int = 0
var _out_path: String = ""
var _baseline_path: String = ""
var _max_ratio: float = 1.3
var _saved: Dictionary = {}
var _medians: Dictionary = {} ## view -> {nodes:int, res:int, build_ms:float}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== ui_perf start ==")
	_parse_args()
	_isolate()
	await _run()
	_teardown()
	print("== ui_perf: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out_path = a.substr(6)
		elif a.begins_with("--baseline="):
			_baseline_path = a.substr(11)
		elif a.begins_with("--max-ratio="):
			_max_ratio = float(a.substr(12))


func _isolate() -> void:
	_saved = {
		"prefs": Store.prefs_path,
		"progress": Store.progress_path,
		"log": StudyLog.path,
		"curr": Store.curriculum_cache_path,
		"remote": Api.remote_path,
		"base": Api.base_url,
	}
	Backend._starting = true ## never launch the engine from this test
	Backend.set_process(false)
	Api.base_url = "" ## no address at all: every request fails at once, nothing leaves the machine
	Store.prefs_path = PREFS
	Store.progress_path = PROG
	StudyLog.path = LOG
	Store.curriculum_cache_path = CURR
	Api.remote_path = REMOTE
	for p in [PROG, PREFS, LOG, CURR, REMOTE, PROG + ".tmp", PREFS + ".tmp", LOG + ".tmp", CURR + ".tmp"]:
		_remove_file(p)
	_remove_dir(READING_DIR)
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en" ## in memory only (every save goes to the PREFS test file above)
	ok(Store.prefs_path == PREFS and Store.progress_path == PROG and StudyLog.path == LOG and Store.curriculum_cache_path == CURR and Api.remote_path == REMOTE,
		"isolation: prefs/progress/studylog/curriculum/remote paths point at user://w0_perf_*")
	ok(Api.base_url == "", "isolation: Api has no address (no network)")
	ok(Backend._starting and not Backend.is_processing(), "isolation: engine start is held back")


func _fixture() -> void:
	Store.progress = Progress.blank()
	var items: Array = []
	for i in REVIEW_FIXTURE:
		items.append({"lang": "en", "target": "Perf sentence %03d" % i, "ko": "성능 문장 %03d" % i, "reading": "", "note": ""})
	Store.add_review(items)
	var n: int = Store.review_for("en").size()
	ok(n == REVIEW_FIXTURE, "fixture: %d review cards (got %d)" % [REVIEW_FIXTURE, n])


## 검사기 자기 점검: 'res' 로 쓸 모니터가 새 Resource 를 실제로 세는지.
## OBJECT_RESOURCE_COUNT 는 StyleBoxFlat 10개를 세지 못했다(이 빌드, 2026-10-17 실측) -> res 는 OBJECT_COUNT 차이로 잰다.
func _check_res_monitor() -> void:
	var r0: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var o0: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var keep: Array = []
	for i in 10:
		keep.append(StyleBoxFlat.new())
	var r1: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var o1: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	print("  info  RESOURCE_COUNT delta for 10 StyleBoxFlat = %d, OBJECT_COUNT delta = %d" % [r1 - r0, o1 - o0])
	ok(o1 - o0 >= 10, "self-check: OBJECT_COUNT sees 10 new StyleBoxFlat (+%d) -> res metric valid" % (o1 - o0))
	keep.clear()


func _make(view: String) -> Node:
	match view:
		"today":
			return TodayView.new()
		"lesson":
			return LessonView.new()
		"talk":
			return TalkView.new()
		"reading":
			var r := ReadingView.new()
			r.storage_dir = READING_DIR ## set before add_child: _ready creates <storage_dir>/cache
			return r
		"review":
			return ReviewView.new()
		"roadmap":
			return RoadmapView.new()
	return null


func _sample(view: String) -> Dictionary:
	var n0: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var r0: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) ## 'res' = 새 Object 수 (RESOURCE_COUNT 는 실측상 안 셈)
	var t0: int = Time.get_ticks_usec()
	var v: Node = _make(view)
	add_child(v)
	await get_tree().process_frame
	if v.has_method("refresh"):
		v.call("refresh")
	await get_tree().process_frame
	var t1: int = Time.get_ticks_usec()
	var n1: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var r1: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	remove_child(v)
	v.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	return {"nodes": n1 - n0, "res": r1 - r0, "build_ms": float(t1 - t0) / 1000.0}


func _median_i(samples: Array, key: String) -> int:
	var arr: Array = []
	for s in samples:
		arr.append(int((s as Dictionary)[key]))
	arr.sort()
	return int(arr[int(arr.size() / 2)])


func _median_f(samples: Array, key: String) -> float:
	var arr: Array = []
	for s in samples:
		arr.append(float((s as Dictionary)[key]))
	arr.sort()
	return float(arr[int(arr.size() / 2)])


func _run() -> void:
	_fixture()
	_check_res_monitor()
	for view in VIEWS:
		var samples: Array = []
		await _sample(view) ## warm-up (cold start is discarded, not printed)
		for i in RUNS:
			var s: Dictionary = await _sample(view)
			samples.append(s)
			print("PERF view=%s nodes=%d res=%d build_ms=%.2f" % [view, int(s["nodes"]), int(s["res"]), float(s["build_ms"])])
		var med := {"nodes": _median_i(samples, "nodes"), "res": _median_i(samples, "res"), "build_ms": _median_f(samples, "build_ms")}
		_medians[view] = med
		print("PERF_MEDIAN view=%s nodes=%d res=%d build_ms=%.2f" % [view, int(med["nodes"]), int(med["res"]), float(med["build_ms"])])
		ok(int(med["nodes"]) > 0, "view %s built (nodes +%d)" % [view, int(med["nodes"])])
	if _out_path != "":
		_write_baseline()
	if _baseline_path != "":
		_compare()


func _line_for(view: String, med: Dictionary) -> String:
	return "PERF view=%s nodes=%d res=%d build_ms=%.2f\n" % [view, int(med["nodes"]), int(med["res"]), float(med["build_ms"])]


func _write_baseline() -> void:
	var text := ""
	for view in VIEWS:
		text += _line_for(view, _medians[view])
	var f := FileAccess.open(_out_path, FileAccess.WRITE)
	ok(f != null, "baseline file opened for writing")
	if f != null:
		f.store_string(text)
		f.close()
		print("baseline written: ", _out_path)


func _compare() -> void:
	ok(_max_ratio > 0.0, "--max-ratio is a positive number (%s)" % str(_max_ratio))
	var f := FileAccess.open(_baseline_path, FileAccess.READ)
	ok(f != null, "baseline file readable")
	if f == null:
		return
	var re := RegEx.new()
	re.compile("^PERF view=(\\w+) nodes=(\\d+) res=(\\d+) build_ms=([0-9]+(?:\\.[0-9]+)?)$")
	var seen: Dictionary = {}
	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if not line.begins_with("PERF view="):
			continue
		var m: RegExMatch = re.search(line)
		if m == null:
			ok(false, "baseline line parses: " + line)
			continue
		var view: String = m.get_string(1)
		var base_n: int = int(m.get_string(2))
		var base_r: int = int(m.get_string(3))
		var base_b: float = float(m.get_string(4))
		seen[view] = true
		if not _medians.has(view):
			ok(false, "view %s from baseline was measured" % view)
			continue
		var cur: Dictionary = _medians[view]
		var cur_n: int = int(cur["nodes"])
		var cur_r: int = int(cur["res"])
		var cur_b: float = float(cur["build_ms"])
		ok(cur_b <= base_b * _max_ratio, "view %s build_ms %.2f <= %.2f x %.2f (base %.2f)" % [view, cur_b, base_b, _max_ratio, base_b])
		ok(cur_n <= int(ceil(float(base_n) * _max_ratio)), "view %s nodes %d <= %d x %.2f (base %d)" % [view, cur_n, base_n, _max_ratio, base_n])
		ok(cur_r <= int(ceil(float(base_r) * _max_ratio)), "view %s res %d <= %d x %.2f (base %d)" % [view, cur_r, base_r, _max_ratio, base_r])
	f.close()
	for view in VIEWS:
		ok(seen.has(view), "baseline contains view %s" % view)


func _teardown() -> void:
	for p in [PROG, PREFS, LOG, CURR, REMOTE, PROG + ".tmp", PREFS + ".tmp", LOG + ".tmp", CURR + ".tmp"]:
		_remove_file(p)
	_remove_dir(READING_DIR)
	Store.prefs_path = _saved["prefs"]
	Store.progress_path = _saved["progress"]
	StudyLog.path = _saved["log"]
	Store.curriculum_cache_path = _saved["curr"]
	Api.remote_path = _saved["remote"]
	Api.base_url = _saved["base"]


func _remove_file(p: String) -> void:
	if p.begins_with(TMP_PREFIX) and FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _remove_dir(d: String) -> void:
	if not d.begins_with(TMP_PREFIX) or not DirAccess.dir_exists_absolute(d):
		return
	for sub in DirAccess.get_directories_at(d):
		_remove_dir(d.path_join(sub))
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
