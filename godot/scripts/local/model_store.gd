class_name ModelStore
extends RefCounted
## On-device speech model store (docs/v201_design.md 2.2, docs/v200_phone_design.md 1.3): download (resumable),
## SHA-256 check, state, delete. The model files live in the app's private folder (`base_dir`).
##
## Everything static; the download runs on one worker Thread that polls an HTTPClient, so the main thread never waits
## (cancel / pause / delete answer within a fraction of a second). Results reach the main thread through `events()`,
## a small Node that is added to the scene tree on first use: signals `progress(id, done, total)`,
## `state_changed(id, state)`, `finished(id, ok, err_code)`.
##
## Files per model (`<file>` is the manifest name): `<file>`, `<file>.part`, `<file>.part.json` (`{"v","id","bytes_done",
## "url_index"}`: never a URL or a query, a signed redirect address expires and must not be kept), `<file>.ok`
## (`{"v","sha256","bytes"}`: written after the hash matched).
##
## Safety rules: only https and only hosts of the manifest `hosts` list (a suffix rule: `githubusercontent.com` allows
## `release-assets.githubusercontent.com`, `evilgithub.com` is not allowed by `github.com`), at most MAX_REDIRECTS
## redirects, the address checked again after every hop. A resumed download always starts again from the
## original address `urls[url_index]`. This file writes no log lines (no addresses, paths or texts leave it).

const SPACE_MARGIN_MB := 100
const MAX_REDIRECTS := 5
const MB := 1000000 ## the screen MB is 10^6 bytes, rounded to a whole number
const PREF_KEY := "stt_model"
const ERR_TEXT := {
	"dl_net": "인터넷 연결이 끊겼어요. 연결을 확인하고 다시 눌러 주세요.",
	"dl_http": "모델 서버가 응답하지 않아요. 잠시 뒤 다시 시도해 주세요.",
	"dl_redirect": "받을 주소를 찾지 못했어요. 잠시 뒤 다시 시도해 주세요.",
	"dl_host": "허용되지 않은 주소라서 받지 않았어요. 앱을 최신 버전으로 업데이트해 주세요.",
	"no_space": "저장 공간이 모자라요. 공간을 비운 뒤 다시 시도해 주세요.",
	"model_corrupt": "받은 파일이 올바르지 않았어요. 잠시 뒤 다시 받아 주세요.",
	"io": "파일을 저장하지 못했어요. 저장 공간을 확인해 주세요.",
	"bad_manifest": "모델 목록을 읽지 못했어요. 앱을 다시 설치하거나 업데이트해 주세요.",
}

const CONNECT_TIMEOUT_MS := 20000
const STALL_TIMEOUT_MS := 20000 ## no byte for this long = the connection is dead
const PROGRESS_MS := 100
const HASH_CHUNK := 1048576
const REDIRECT_CODES := [301, 302, 303, 307, 308]

static var manifest_path := "res://data/models.json"
static var base_dir := "user://models/" ## tests: "user://test_models_<name>/"
## () -> int bytes, -1 = unknown. Default: DirAccess.get_space_left() of base_dir (0 counts as unknown).
static var free_space_hook: Callable = Callable()
## Tests only: allows `http://127.0.0.1:<port>` and the host map below.
static var allow_http_loopback := false
## Tests only (needs allow_http_loopback): logical host -> {"host": "127.0.0.1", "port": int}. The address check runs on the
## logical host (https, suffix rule); the connection then goes to the mapped loopback server over plain http.
static var test_host_map: Dictionary = {}
## Tests only: (bytes_done: int) -> bool, true = pretend the disk write failed. Runs on the worker thread.
static var write_error_hook: Callable = Callable()
## Stall limit; tests may shorten it.
static var stall_timeout_ms: int = STALL_TIMEOUT_MS

static var _jobs: Dictionary = {} ## id -> Job
static var _corrupt: Dictionary = {} ## id -> true (file or download judged bad; cleared by start/remove)
static var _queue: Array = []
static var _stats: Dictionary = {"requests": 0, "resumed": 0, "resume_bytes": 0, "last_host": "", "last_err": ""}
static var _mutex: Mutex = Mutex.new()
static var _runner: Node = null
static var _url_rx: RegEx = null


## One download. `cancel` is "" (go on), "cancel" or "pause" (stop, keep the .part), "remove" (stop, the caller deletes).
class Job extends RefCounted:
	var id: String = ""
	var model: Dictionary = {}
	var hosts: Array = []
	var dir_abs: String = ""
	var allow_loop: bool = false
	var host_map: Dictionary = {}
	var write_hook: Callable = Callable()
	var stall_ms: int = 20000
	var thread: Thread = null
	var cancel: String = ""
	var status: String = "downloading" ## downloading | verifying | ended
	var done: int = 0
	var total: int = 0


## The Node behind `events()`: carries the signals and hands the worker's messages to the main thread.
class Runner extends Node:
	signal progress(id: String, done: int, total: int)
	signal state_changed(id: String, state: String)
	signal finished(id: String, ok: bool, err_code: String)

	func _process(_d: float) -> void:
		ModelStore._drain(self)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_APPLICATION_PAUSED:
			ModelStore._stop_all("pause", false)
		elif what == NOTIFICATION_WM_CLOSE_REQUEST:
			ModelStore._stop_all("cancel", true)

	func _exit_tree() -> void:
		ModelStore._stop_all("cancel", true)


# ---------------------------------------------------------------- manifest

## File and id names: a short allow-list, so no name can reach outside the model folder or name a device / special file.
const NAME_RX := "^[a-z0-9][a-z0-9._-]{0,63}$"
const RESERVED_STEMS := ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
	"lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]
const SIDE_SUFFIXES := [".part", ".part.json", ".ok"]
const MAX_BYTES := 8000000000 ## 8 GB: far above any speech model, far below int overflow games


static func valid_name(n: Variant) -> bool:
	if typeof(n) != TYPE_STRING:
		return false
	var s: String = n
	if RegEx.create_from_string(NAME_RX).search(s) == null or s.contains("..") or s.ends_with("."):
		return false
	if RESERVED_STEMS.has(s.split(".")[0]):
		return false
	return true


static func _str_array(v: Variant) -> bool:
	if not (v is Array):
		return false
	for x in v:
		if typeof(x) != TYPE_STRING:
			return false
	return true


## Checks a parsed models.json. Every field is type-checked before it is converted or used; anything wrong ends as
## {ok: false, err: "bad_manifest"}. Returns {ok, models, hosts, err}.
static func validate_manifest(d: Variant) -> Dictionary:
	var bad := {"ok": false, "models": [], "hosts": [], "err": "bad_manifest"}
	if not (d is Dictionary):
		return bad
	var dd: Dictionary = d
	if not _is_whole(dd.get("v")) or int(dd["v"]) != 1:
		return bad
	if not (dd.get("hosts") is Array) or not (dd.get("models") is Array):
		return bad
	var hosts: Array = []
	for h in dd["hosts"]:
		if typeof(h) != TYPE_STRING or String(h).strip_edges() == "" or String(h) != String(h).to_lower() or String(h).contains("/"):
			return bad
		hosts.append(String(h))
	if hosts.is_empty() or (dd["models"] as Array).is_empty():
		return bad
	var models: Array = []
	var ids := {}
	var files := {} ## every file name any model may touch -> true
	var defaults := 0
	var sha_rx := RegEx.create_from_string("^[0-9a-f]{64}$")
	for m in dd["models"]:
		if not (m is Dictionary):
			return bad
		var md: Dictionary = m
		if not valid_name(md.get("id")) or not valid_name(md.get("file")):
			return bad
		var id: String = md["id"]
		var file: String = md["file"]
		if ids.has(id):
			return bad
		for suf in SIDE_SUFFIXES:
			if file.ends_with(suf):
				return bad
		for suf in [""] + SIDE_SUFFIXES:
			if files.has(file + suf):
				return bad
			files[file + suf] = true
		if not _is_whole(md.get("bytes")) or int(md["bytes"]) <= 0 or int(md["bytes"]) > MAX_BYTES:
			return bad
		if typeof(md.get("sha256")) != TYPE_STRING or sha_rx.search(String(md["sha256"])) == null:
			return bad
		if not _str_array(md.get("urls")) or (md["urls"] as Array).is_empty():
			return bad
		for u in md["urls"]:
			if not bool(parse_url(String(u)).get("ok", false)):
				return bad
		var minf: Variant = md.get("min_free_mb", 0)
		if not _is_whole(minf) or int(minf) < 0 or int(minf) > 1000000:
			return bad
		var ram: Variant = md.get("ram_hint_mb", 0)
		if not _is_whole(ram) or int(ram) < 0:
			return bad
		if md.has("default") and typeof(md["default"]) != TYPE_BOOL:
			return bad
		if md.has("kind") and typeof(md["kind"]) != TYPE_STRING:
			return bad
		if md.has("label_ko") and typeof(md["label_ko"]) != TYPE_STRING:
			return bad
		if md.has("license") and typeof(md["license"]) != TYPE_STRING:
			return bad
		if md.has("langs") and not _str_array(md["langs"]):
			return bad
		ids[id] = true
		if bool(md.get("default", false)):
			defaults += 1
		models.append({
			"id": id, "kind": str(md.get("kind", "stt")), "langs": (md["langs"] as Array).duplicate() if md.has("langs") else [],
			"file": file, "bytes": int(md["bytes"]), "sha256": String(md["sha256"]), "min_free_mb": int(minf),
			"default": bool(md.get("default", false)), "ram_hint_mb": int(ram),
			"label_ko": str(md.get("label_ko", id)), "urls": (md["urls"] as Array).duplicate(), "license": str(md.get("license", "")),
		})
	if defaults != 1:
		return bad
	return {"ok": true, "models": models, "hosts": hosts, "err": ""}


static func _is_whole(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) == TYPE_FLOAT:
		var f: float = v
		return not is_nan(f) and not is_inf(f) and f == floorf(f) and absf(f) < 9.0e15
	return false


static func manifest() -> Dictionary:
	var bad := {"ok": false, "models": [], "hosts": [], "err": "bad_manifest"}
	if not FileAccess.file_exists(manifest_path):
		return bad
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	if f == null:
		return bad
	var txt: String = f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK:
		return bad
	return validate_manifest(j.data)


static func model(id: String) -> Dictionary:
	var mf: Dictionary = manifest()
	if not bool(mf["ok"]):
		return {}
	for m in mf["models"]:
		if str((m as Dictionary)["id"]) == id:
			return (m as Dictionary).duplicate(true)
	return {}


static func default_id() -> String:
	var mf: Dictionary = manifest()
	if not bool(mf["ok"]):
		return ""
	for m in mf["models"]:
		if bool((m as Dictionary).get("default", false)):
			return str((m as Dictionary)["id"])
	return str(((mf["models"] as Array)[0] as Dictionary)["id"])


static func active_id() -> String:
	var want: String = str(Store.prefs.get(PREF_KEY, ""))
	if want != "" and not model(want).is_empty():
		return want
	return default_id()


static func set_active(id: String) -> bool:
	if model(id).is_empty():
		return false
	Store.set_pref(PREF_KEY, id)
	return true


# ---------------------------------------------------------------- state and paths

static func _file_abs(m: Dictionary, suffix: String = "") -> String:
	return ProjectSettings.globalize_path(base_dir).path_join(str(m["file"]) + suffix)


## True when `abs_path` sits directly in the model folder (no sub-folder, no `..`, no other drive or parent).
static func in_store(abs_path: String, dir_abs: String = "") -> bool:
	var dir: String = (dir_abs if dir_abs != "" else ProjectSettings.globalize_path(base_dir)).replace("\\", "/").simplify_path()
	var p: String = abs_path.replace("\\", "/").simplify_path()
	return dir != "" and p.get_base_dir().trim_suffix("/") == dir.trim_suffix("/") and p.get_file() != ""


## Deletes one model file, but only when it is directly in the model folder.
static func _rm(abs_path: String, dir_abs: String = "") -> void:
	if in_store(abs_path, dir_abs):
		DirAccess.remove_absolute(abs_path)


static func path_of(id: String) -> String:
	var m: Dictionary = model(id)
	if m.is_empty():
		return ""
	return base_dir.path_join(str(m["file"]))


static func _len(abs_path: String) -> int:
	if not FileAccess.file_exists(abs_path):
		return 0
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return 0
	var n: int = f.get_length()
	f.close()
	return n


static func _read_json(abs_path: String) -> Dictionary:
	if not FileAccess.file_exists(abs_path):
		return {}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {}
	var txt: String = f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(txt) != OK or not (j.data is Dictionary):
		return {}
	return j.data


static func _write_text(abs_path: String, txt: String) -> bool:
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(txt)
	var ok: bool = f.get_error() == OK
	f.close()
	return ok


static func _ok_marker_valid(m: Dictionary) -> bool:
	var d: Dictionary = _read_json(_file_abs(m, ".ok"))
	return str(d.get("sha256", "")) == str(m["sha256"]) and int(d.get("bytes", -1)) == int(m["bytes"])


static func _job_of(id: String) -> Job:
	var j: Variant = _jobs.get(id)
	if j is Job and (j as Job).status != "ended":
		return j
	return null


static func state(id: String) -> String:
	var m: Dictionary = model(id)
	if m.is_empty():
		return "missing"
	var job: Job = _job_of(id)
	if job != null:
		return job.status
	_mutex.lock()
	var bad: bool = _corrupt.has(id)
	_mutex.unlock()
	if bad:
		return "corrupt"
	var fl: int = _len(_file_abs(m))
	if FileAccess.file_exists(_file_abs(m)):
		return "ready" if fl == int(m["bytes"]) and _ok_marker_valid(m) else "corrupt"
	if _len(_file_abs(m, ".part")) > 0:
		return "partial"
	return "missing"


static func info(id: String) -> Dictionary:
	var m: Dictionary = model(id)
	if m.is_empty():
		return {}
	var job: Job = _job_of(id)
	var part: int = _len(_file_abs(m, ".part"))
	if job != null:
		part = job.done
	return {"id": id, "file": str(m["file"]), "bytes": int(m["bytes"]), "state": state(id), "part_bytes": part, "label_ko": str(m["label_ko"])}


# ---------------------------------------------------------------- labels

## "35 / 60 MB": the one place that builds a progress text.
static func progress_label(done: int, total: int) -> String:
	var t: int = maxi(1, int(round(float(maxi(total, 0)) / float(MB))))
	var d: int = clampi(int(round(float(maxi(done, 0)) / float(MB))), 0, t)
	return "%d / %d MB" % [d, t]


static func mb_label(bytes: int) -> String:
	return "약 %d MB" % maxi(1, int(round(float(maxi(bytes, 0)) / float(MB))))


# ---------------------------------------------------------------- control

static func events() -> Node:
	if _runner == null or not is_instance_valid(_runner):
		_runner = Runner.new()
		_runner.name = "ModelStoreEvents"
		var ml: MainLoop = Engine.get_main_loop()
		if ml is SceneTree:
			(ml as SceneTree).root.add_child.call_deferred(_runner)
	return _runner


static func stats() -> Dictionary:
	_mutex.lock()
	var s: Dictionary = _stats.duplicate()
	_mutex.unlock()
	return s


static func mark_corrupt(id: String) -> void:
	var m: Dictionary = model(id)
	if m.is_empty():
		return
	if _job_of(id) != null:
		return
	_rm(_file_abs(m, ".ok")) ## the file stays until the person acts; without the marker it is not "ready"
	_mutex.lock()
	_corrupt[id] = true
	_mutex.unlock()
	_emit_state(id)


## The question shown when the free space cannot be read; `need_mb` is the amount start() asked for.
static func space_unknown_text(need_mb: int) -> String:
	return "남은 공간을 확인하지 못했어요. 약 %d MB 이상 비어 있는지 확인하고 계속할까요?" % maxi(need_mb, 1)


static func _free_bytes() -> int:
	if free_space_hook.is_valid():
		return int(free_space_hook.call())
	var d := DirAccess.open(ProjectSettings.globalize_path(base_dir))
	if d == null:
		return -1
	var f: int = d.get_space_left()
	return -1 if f <= 0 else f


static func _mb_up(bytes: int) -> int:
	return int(ceil(float(maxi(bytes, 0)) / float(MB)))


static func start(id: String, space_confirmed: bool = false) -> Dictionary:
	var mf: Dictionary = manifest()
	var m: Dictionary = model(id)
	if not bool(mf["ok"]) or m.is_empty():
		return {"ok": false, "err_code": "bad_manifest"}
	for k in _jobs.keys():
		var other: Job = _job_of(str(k))
		if other != null:
			return {"ok": false, "err_code": "busy"}
	var old: Variant = _jobs.get(id)
	if old is Job:
		_join(old)
		_jobs.erase(id)
	if state(id) == "ready":
		_finish_later(id, true, "")
		return {"ok": true, "err_code": ""}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base_dir))
	if state(id) == "corrupt": ## a bad file is replaced: it is deleted before anything is fetched
		for suf in ["", ".ok"]:
			_rm(_file_abs(m, suf))
	_mutex.lock()
	_corrupt.erase(id)
	_mutex.unlock()
	var part: int = _len(_file_abs(m, ".part"))
	if part > int(m["bytes"]):
		_rm(_file_abs(m, ".part"))
		_rm(_file_abs(m, ".part.json"))
		part = 0
	var need: int = int(ceil(float(maxi(0, int(m["bytes"]) - part)) * 1.1)) + SPACE_MARGIN_MB * MB
	need = maxi(need, int(m["min_free_mb"]) * MB)
	var free: int = _free_bytes()
	if free < 0:
		if not space_confirmed:
			return {"ok": false, "err_code": "space_unknown", "need_mb": _mb_up(need)}
	elif free < need:
		return {"ok": false, "err_code": "no_space", "need_mb": _mb_up(need), "free_mb": int(free / MB)}
	var job := Job.new()
	job.id = id
	job.model = m
	job.hosts = (mf["hosts"] as Array).duplicate()
	job.dir_abs = ProjectSettings.globalize_path(base_dir)
	job.allow_loop = allow_http_loopback
	job.host_map = test_host_map.duplicate(true)
	job.write_hook = write_error_hook
	job.stall_ms = stall_timeout_ms
	job.done = part
	job.total = int(m["bytes"])
	job.thread = Thread.new()
	_jobs[id] = job
	events() # the node must exist before the first message
	_emit_state(id)
	var err: int = job.thread.start(_worker.bind(job))
	if err != OK:
		_jobs.erase(id)
		return {"ok": false, "err_code": "io"}
	return {"ok": true, "err_code": ""}


## Stops the download; the .part stays. The `finished` signal then says (false, "cancelled").
static func cancel(id: String) -> void:
	var job: Job = _job_of(id)
	if job != null:
		job.cancel = "cancel"


static func remove(id: String) -> bool:
	var m: Dictionary = model(id)
	if m.is_empty():
		return false
	var job: Variant = _jobs.get(id)
	if job is Job:
		(job as Job).cancel = "remove"
		_join(job) ## the worker looks at the flag every few milliseconds
		_jobs.erase(id)
	for suf in ["", ".part", ".part.json", ".ok"]:
		_rm(_file_abs(m, suf))
	_mutex.lock()
	_corrupt.erase(id)
	_mutex.unlock()
	_emit_state(id)
	for suf in ["", ".part", ".part.json", ".ok"]:
		if FileAccess.file_exists(_file_abs(m, suf)):
			return false
	return true


static func _join(job: Job) -> void:
	if job.thread != null and job.thread.is_started():
		job.thread.wait_to_finish()


## Runner: app paused / closing / leaving the tree.
static func _stop_all(reason: String, wait: bool) -> void:
	for k in _jobs.keys():
		var job: Variant = _jobs[k]
		if job is Job and (job as Job).status != "ended":
			(job as Job).cancel = reason
	if wait:
		for k in _jobs.keys():
			var j2: Variant = _jobs[k]
			if j2 is Job:
				_join(j2)
		_jobs.clear()


static func _emit_state(id: String) -> void:
	events()
	var st: String = state(id)
	_mutex.lock()
	_queue.append({"k": "state", "id": id, "s": st})
	_mutex.unlock()


static func _finish_later(id: String, ok: bool, err: String) -> void:
	_mutex.lock()
	_queue.append({"k": "finished", "id": id, "ok": ok, "err": err, "job": null})
	_mutex.unlock()


## Main thread (Runner._process): turns the queued messages into signals.
static func _drain(r: Runner) -> void:
	_mutex.lock()
	var q: Array = _queue
	_queue = []
	_mutex.unlock()
	var last_progress := {}
	for e in q:
		var d: Dictionary = e
		match str(d["k"]):
			"progress":
				last_progress[str(d["id"])] = d
			"state":
				r.state_changed.emit(str(d["id"]), str(d["s"]))
			"finished":
				var jb: Variant = d.get("job")
				if jb is Job:
					_join(jb)
					if _jobs.get(str(d["id"])) == jb:
						_jobs.erase(str(d["id"]))
				r.state_changed.emit(str(d["id"]), state(str(d["id"])))
				r.finished.emit(str(d["id"]), bool(d["ok"]), str(d["err"]))
	for k in last_progress.keys():
		var p: Dictionary = last_progress[k]
		r.progress.emit(str(k), int(p["done"]), int(p["total"]))


# ---------------------------------------------------------------- address rules

static func parse_url(url: String) -> Dictionary:
	if _url_rx == null:
		_url_rx = RegEx.create_from_string("^(?i)(https?)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?([/?#].*)?$")
	var mm: RegExMatch = _url_rx.search(url.strip_edges())
	if mm == null:
		return {"ok": false}
	var scheme: String = mm.get_string(1).to_lower()
	var host: String = mm.get_string(2).to_lower()
	var port: int = int(mm.get_string(3)) if mm.get_string(3) != "" else (443 if scheme == "https" else 80)
	if host == "" or host.begins_with(".") or host.ends_with(".") or host.contains("..") or port < 1 or port > 65535:
		return {"ok": false}
	var path: String = mm.get_string(4)
	if path.contains("#"):
		path = path.substr(0, path.find("#"))
	if path == "" or path.begins_with("?"):
		path = "/" + path
	return {"ok": true, "scheme": scheme, "host": host, "port": port, "path": path}


static func _origin(u: Dictionary) -> String:
	var def: int = 443 if str(u["scheme"]) == "https" else 80
	return "%s://%s%s" % [u["scheme"], u["host"], "" if int(u["port"]) == def else ":%d" % int(u["port"])]


## Resolves a Location header against the address it came from (absolute, //host, /path, ?query, relative).
static func resolve_location(base: Dictionary, loc: String) -> String:
	var l: String = loc.strip_edges()
	# any explicit scheme (https:, http:, ftp:, file:, javascript:, data:, in any letter case) is kept as written: it is
	# never read as a relative path, so the address check that follows sees it and refuses what is not allowed
	if RegEx.create_from_string("^[A-Za-z][A-Za-z0-9+.-]*:").search(l) != null:
		return l
	if l.begins_with("//"):
		return str(base["scheme"]) + ":" + l
	if l.begins_with("/"):
		return _origin(base) + l
	var path: String = str(base["path"])
	var no_q: String = path.split("?")[0]
	if l.begins_with("?"):
		return _origin(base) + no_q + l
	return _origin(base) + no_q.substr(0, no_q.rfind("/") + 1) + l


## Host rule: h == s or h ends with "." + s for some s of the manifest list.
static func host_allowed(host: String, hosts: Array) -> bool:
	var h: String = host.to_lower()
	for s in hosts:
		var sx: String = String(s).to_lower()
		if h == sx or h.ends_with("." + sx):
			return true
	return false


static func _url_allowed(u: Dictionary, job: Job) -> bool:
	if not bool(u.get("ok", false)):
		return false
	if job.allow_loop and str(u["scheme"]) == "http" and str(u["host"]) == "127.0.0.1":
		return true
	return str(u["scheme"]) == "https" and host_allowed(str(u["host"]), job.hosts)


# ---------------------------------------------------------------- worker thread

static func _note(key: String, value: Variant) -> void:
	_mutex.lock()
	_stats[key] = value
	_mutex.unlock()


static func _note_add(key: String, n: int) -> void:
	_mutex.lock()
	_stats[key] = int(_stats.get(key, 0)) + n
	_mutex.unlock()


static func _push(e: Dictionary) -> void:
	_mutex.lock()
	_queue.append(e)
	_mutex.unlock()


static func _worker(job: Job) -> void:
	var res: Dictionary = _download(job)
	var ok: bool = bool(res["ok"])
	var err: String = str(res["err"])
	if not ok:
		_note("last_err", err)
	job.status = "ended"
	_push({"k": "finished", "id": job.id, "ok": ok, "err": err, "job": job})


static func _p(job: Job, suffix: String) -> String:
	return job.dir_abs.path_join(str(job.model["file"]) + suffix)


static func _write_part_json(job: Job, url_index: int) -> void:
	_write_text(_p(job, ".part.json"), JSON.stringify({"v": 1, "id": job.id, "bytes_done": job.done, "url_index": url_index}))


static func _drop_part(job: Job) -> void:
	_rm(_p(job, ".part"), job.dir_abs)
	_rm(_p(job, ".part.json"), job.dir_abs)
	job.done = 0


static func _download(job: Job) -> Dictionary:
	var m: Dictionary = job.model
	var bytes: int = int(m["bytes"])
	var urls: Array = m["urls"]
	var part_len: int = _len(_p(job, ".part"))
	if part_len > bytes:
		_drop_part(job)
		part_len = 0
	job.done = part_len
	var pj: Dictionary = _read_json(_p(job, ".part.json"))
	var url_start: int = clampi(int(pj.get("url_index", 0)), 0, urls.size() - 1) if _is_whole(pj.get("url_index", 0)) else 0
	_rm(_p(job, ".ok"), job.dir_abs) ## a stale marker must never vouch for a new download
	if job.done < bytes:
		var last_err := "dl_net"
		var got := false
		var tried := 0
		while tried < urls.size():
			var idx: int = (url_start + tried) % urls.size()
			tried += 1
			var r: Dictionary = _attempt(job, idx)
			if bool(r["ok"]):
				got = true
				break
			last_err = str(r["err"])
			if bool(r.get("stop", false)):
				break
		if not got:
			return {"ok": false, "err": last_err}
	if job.cancel != "":
		return {"ok": false, "err": "cancelled"}
	return _verify(job)


## One address of the list (with its redirects). Returns {ok, err, stop}: `stop` = do not try the next address
## (cancelled, disk problem, the connection broke while data was flowing, the data itself is wrong).
static func _attempt(job: Job, idx: int) -> Dictionary:
	var m: Dictionary = job.model
	var bytes: int = int(m["bytes"])
	var origin_url: String = str((m["urls"] as Array)[idx])
	var url: String = origin_url
	var redirects := 0
	var restarted := false
	while true:
		if job.cancel != "":
			return {"ok": false, "err": "cancelled", "stop": true}
		var u: Dictionary = parse_url(url)
		if not _url_allowed(u, job):
			return {"ok": false, "err": "dl_host", "stop": false}
		var range_from: int = job.done
		var rq: Dictionary = _request(job, u, range_from)
		if str(rq["err"]) != "":
			var stop: bool = str(rq["err"]) == "cancelled"
			return {"ok": false, "err": rq["err"], "stop": stop}
		var c: HTTPClient = rq["client"]
		var code: int = int(rq["code"])
		var hd: Dictionary = rq["headers"]
		if REDIRECT_CODES.has(code):
			c.close()
			var loc: String = str(hd.get("location", ""))
			redirects += 1
			if redirects > MAX_REDIRECTS or loc == "":
				return {"ok": false, "err": "dl_redirect", "stop": false}
			if not location_clean(loc):
				return {"ok": false, "err": "dl_redirect", "stop": false}
			url = resolve_location(u, loc)
			continue
		if code == 416:
			c.close()
			if range_from > 0 and not restarted:
				restarted = true
				_drop_part(job)
				url = origin_url
				redirects = 0
				continue
			return {"ok": false, "err": "dl_http", "stop": false}
		if code != 200 and code != 206:
			c.close()
			return {"ok": false, "err": "dl_http", "stop": false}
		# the body: check what it says about its size first
		var clen: int = int(hd.get("content-length", "-1")) if str(hd.get("content-length", "")).is_valid_int() else -1
		var append: bool = false
		if code == 206:
			var cr: String = str(hd.get("content-range", ""))
			var rx := RegEx.create_from_string("^bytes (\\d+)-(\\d+)/(\\d+)$")
			var mm: RegExMatch = rx.search(cr.strip_edges())
			if mm == null or int(mm.get_string(1)) != range_from or int(mm.get_string(3)) != bytes or int(mm.get_string(2)) != bytes - 1:
				c.close()
				return {"ok": false, "err": "model_corrupt", "stop": false}
			if clen >= 0 and clen != bytes - range_from:
				c.close()
				return {"ok": false, "err": "model_corrupt", "stop": false}
			append = true
			_note_add("resumed", 1)
			_note_add("resume_bytes", range_from)
		else:
			if clen >= 0 and clen != bytes:
				c.close()
				return {"ok": false, "err": "model_corrupt", "stop": false}
			if range_from > 0:
				job.done = 0 ## the server ignored the Range header: start again from the first byte
		_note("last_host", str(u["host"]))
		return _stream(job, c, append, idx, bytes)
	return {"ok": false, "err": "dl_net", "stop": false}


## Connects, sends the GET (with `Range: bytes=N-` when N > 0) and waits for the status line and headers.
## Returns {err: "" | dl_net | cancelled, client, code, headers(lower-case keys)}.
static func _request(job: Job, u: Dictionary, range_from: int) -> Dictionary:
	var c := HTTPClient.new()
	c.read_chunk_size = 131072
	var host: String = str(u["host"])
	var port: int = int(u["port"])
	var tls: TLSOptions = null
	if str(u["scheme"]) == "https":
		tls = TLSOptions.client()
	if job.allow_loop and job.host_map.has(host):
		var t: Dictionary = job.host_map[host]
		host = str(t.get("host", "127.0.0.1"))
		port = int(t.get("port", port))
		tls = null
	if c.connect_to_host(host, port, tls) != OK:
		return {"err": "dl_net"}
	var t0: int = Time.get_ticks_msec()
	while true:
		c.poll()
		var st: int = c.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			break
		if st != HTTPClient.STATUS_CONNECTING and st != HTTPClient.STATUS_RESOLVING:
			c.close()
			return {"err": "dl_net"}
		if job.cancel != "":
			c.close()
			return {"err": "cancelled"}
		if Time.get_ticks_msec() - t0 > CONNECT_TIMEOUT_MS:
			c.close()
			return {"err": "dl_net"}
		OS.delay_msec(5)
	var hdrs := PackedStringArray(["User-Agent: hoehwa-practice", "Accept: */*", "Accept-Encoding: identity"])
	if range_from > 0:
		hdrs.append("Range: bytes=%d-" % range_from)
	if c.request(HTTPClient.METHOD_GET, str(u["path"]), hdrs) != OK:
		c.close()
		return {"err": "dl_net"}
	_note_add("requests", 1)
	t0 = Time.get_ticks_msec()
	while true:
		c.poll()
		if c.get_status() != HTTPClient.STATUS_REQUESTING:
			break
		if job.cancel != "":
			c.close()
			return {"err": "cancelled"}
		if Time.get_ticks_msec() - t0 > CONNECT_TIMEOUT_MS:
			c.close()
			return {"err": "dl_net"}
		OS.delay_msec(2)
	if not c.has_response():
		c.close()
		return {"err": "dl_net"}
	var headers := {}
	var raw: Dictionary = c.get_response_headers_as_dictionary()
	for k in raw.keys():
		headers[String(k).to_lower()] = str(raw[k])
	return {"err": "", "client": c, "code": c.get_response_code(), "headers": headers}


static func _stream(job: Job, c: HTTPClient, append: bool, idx: int, bytes: int) -> Dictionary:
	if c.get_status() != HTTPClient.STATUS_BODY: ## an answer without a body: nothing to store, nothing to leave behind
		c.close()
		return {"ok": false, "err": "dl_net", "stop": false}
	var path: String = _p(job, ".part")
	var f: FileAccess = null
	if append:
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek(job.done)
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		c.close()
		return {"ok": false, "err": "io", "stop": true}
	_write_part_json(job, idx)
	var last_data: int = Time.get_ticks_msec()
	var last_prog: int = 0
	var write_fail := false
	while c.get_status() == HTTPClient.STATUS_BODY:
		if job.cancel != "":
			break
		c.poll()
		if c.get_status() != HTTPClient.STATUS_BODY: ## poll() saw the connection end: the body API must not be called now
			break
		var chunk: PackedByteArray = c.read_response_body_chunk()
		var now: int = Time.get_ticks_msec()
		if chunk.size() > 0:
			f.store_buffer(chunk)
			job.done += chunk.size()
			last_data = now
			if f.get_error() != OK or (job.write_hook.is_valid() and bool(job.write_hook.call(job.done))):
				write_fail = true
				break
			if job.done > bytes:
				break
			if now - last_prog >= PROGRESS_MS:
				last_prog = now
				_push({"k": "progress", "id": job.id, "done": job.done, "total": bytes})
		else:
			if now - last_data > job.stall_ms:
				break
			OS.delay_msec(1)
	f.close()
	c.close()
	_push({"k": "progress", "id": job.id, "done": job.done, "total": bytes})
	if write_fail:
		_drop_part(job)
		return {"ok": false, "err": "no_space", "stop": true}
	if job.done > bytes:
		_drop_part(job)
		return {"ok": false, "err": "model_corrupt", "stop": true}
	if job.done == 0: ## not one byte arrived: no .part, no .part.json
		_drop_part(job)
		return {"ok": false, "err": "cancelled" if job.cancel != "" else "dl_net", "stop": true}
	_write_part_json(job, idx)
	if job.cancel != "":
		return {"ok": false, "err": "cancelled", "stop": true}
	if job.done < bytes:
		return {"ok": false, "err": "dl_net", "stop": true}
	return {"ok": true, "err": "", "stop": false}


static func _verify(job: Job) -> Dictionary:
	job.status = "verifying"
	_push({"k": "state", "id": job.id, "s": "verifying"})
	var m: Dictionary = job.model
	var f := FileAccess.open(_p(job, ".part"), FileAccess.READ)
	if f == null:
		_drop_part(job)
		return {"ok": false, "err": "io"}
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk: PackedByteArray = f.get_buffer(HASH_CHUNK)
		if chunk.size() == 0:
			break
		ctx.update(chunk)
		if job.cancel != "":
			f.close()
			return {"ok": false, "err": "cancelled"}
	f.close()
	var hex: String = ctx.finish().hex_encode()
	if hex != str(m["sha256"]):
		_drop_part(job)
		_mutex.lock()
		_corrupt[job.id] = true
		_mutex.unlock()
		return {"ok": false, "err": "model_corrupt"}
	if not _write_text(_p(job, ".ok"), JSON.stringify({"v": 1, "sha256": hex, "bytes": int(m["bytes"])})):
		return {"ok": false, "err": "io"}
	_rm(_p(job, ""), job.dir_abs)
	if DirAccess.rename_absolute(_p(job, ".part"), _p(job, "")) != OK:
		_rm(_p(job, ".ok"), job.dir_abs)
		return {"ok": false, "err": "io"}
	_rm(_p(job, ".part.json"), job.dir_abs)
	return {"ok": true, "err": ""}


## A Location value must be plain printable ASCII (no space, control character or non-ASCII), or it is refused.
static func location_clean(loc: String) -> bool:
	if loc.strip_edges() == "":
		return false
	for i in loc.strip_edges().length():
		var c: int = loc.strip_edges().unicode_at(i)
		if c <= 32 or c >= 127:
			return false
	return true
