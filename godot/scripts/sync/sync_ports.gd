class_name SyncPorts
extends RefCounted
## SyncEngine 이 바깥(저장소·네트워크·시계·파일 경로)에 닿는 모든 통로 (설계 docs/sync_design.md §9.2).
## 시험은 필드를 바꿔 끼운다. live() 는 Store / StudyLog / Api / 실제 시계를 쓴다.

var state_path: String = "user://sync_state.json"
var backup_root: String = "user://sync_backup"
var device_name: String = ""
var device_kind: String = "pc" ## "pc" | "phone"
var now_unix: Callable ## () -> int
var today_days: Callable ## () -> int  (Plan.days_from_civil 일 번호)
var load_local: Callable ## () -> {"progress", "studylog", "prefs"}  (딥카피)
var apply_local: Callable ## (progress, studylog, prefs_changes) -> bool
var local_paths: Callable ## () -> {"progress": String, "studylog": String, "prefs": String}  (백업 복사 대상)
var is_read_only: Callable ## () -> bool
var http_get: Callable ## (path: String, timeout: float) -> Api 결과 Dictionary (await 가능)
var http_post: Callable ## (path: String, body: Dictionary, timeout: float) -> 〃
var is_busy_ui: Callable ## () -> bool  (녹음 중이면 true -> 적용 연기)
## 설계 §9.2 에 더한 통로: 되돌리기(restore_backup)로 파일을 바꾼 뒤 메모리를 다시 읽는다. () -> void. 비어 있으면 아무것도 안 한다.
var reload_local: Callable


static func _default_name(kind: String) -> String:
	if kind == "phone":
		var m: String = OS.get_model_name().strip_edges()
		if m == "" or m == "GenericDevice":
			return "휴대폰"
		return m.left(40)
	var h: String = OS.get_environment("COMPUTERNAME").strip_edges()
	return h.left(40) if h != "" else "PC"


static func live() -> SyncPorts:
	var p := SyncPorts.new()
	if Store.test_guard_on: ## a test scene run: the sidecar and the backups go under user://test_guard/ too (a test may still set its own paths)
		p.state_path = Store.guard_path(p.state_path)
		p.backup_root = Store.guard_path(p.backup_root)
	p.device_kind = "phone" if Platform.is_phone() else "pc"
	p.device_name = _default_name(p.device_kind)
	p.now_unix = func() -> int:
		return int(Time.get_unix_time_from_system())
	p.today_days = func() -> int:
		return StudyLog.today()
	p.load_local = func() -> Dictionary:
		return {"progress": Store.progress.duplicate(true), "studylog": StudyLog.snapshot(), "prefs": Store.prefs.duplicate(true)}
	p.apply_local = func(progress: Dictionary, studylog: Dictionary, prefs_changes: Dictionary) -> bool:
		if not Store.apply_sync_progress(progress):
			return false
		if not StudyLog.apply_sync(studylog):
			return false
		return Store.apply_sync_prefs(prefs_changes)
	p.local_paths = func() -> Dictionary:
		return {"progress": Store.progress_path, "studylog": StudyLog.path, "prefs": Store.prefs_path}
	p.is_read_only = func() -> bool:
		return Store.progress_read_only or Store.prefs_read_only or StudyLog.is_read_only()
	p.http_get = func(path: String, timeout: float) -> Dictionary:
		return await Api.get_json(path, timeout, false).wait()
	p.http_post = func(path: String, body: Dictionary, timeout: float) -> Dictionary:
		return await Api.post_json(path, body, timeout, false).wait()
	p.is_busy_ui = func() -> bool:
		return Recorder.recording
	p.reload_local = func() -> void:
		Store.load_progress()
		Store.load_prefs()
		StudyLog.load_from_disk()
		Store.changed.emit()
		Store.prefs_changed.emit()
	return p
