class_name SttEngine
extends Node
## The speech engine thread (docs/v201_design.md 2.3, decision 5). ONE Thread owns the WhisperBridge: `load_model`, `unload` and
## `transcribe` are called on that thread only (main_thread_calls of the tests stays 0). The main thread only
##   - puts work in a FIFO queue (request_load / request_unload / submit), which returns at once, and
##   - calls `bridge.abort()` (an atomic flag in the native code) and never waits for the engine.
## Results come back with call_deferred, so a coroutine `await engine.transcribe(...)` keeps the frames running.
##
## Lifetime: get_or_create() adds ONE node named "SttEngine" below the root. The thread is started by the first request and
## ends in shutdown() (called from `_exit_tree`, so every exit path joins it: Thread.wait_to_finish() is called exactly once).
## shutdown() aborts the running transcription, throws the queued jobs away (error "shutdown"), unloads the model on the thread
## and joins it; an abort()-patched bridge (`+abort-sched`) ends within milliseconds.
##
## Unload / pause: request_unload() = abort() + an unload at the END of the queue (the running transcription ends "aborted"
## first, then the model is freed); queued jobs that have not started are failed ("aborted") and removed. A pause
## (NOTIFICATION_APPLICATION_PAUSED) does the same with the error "paused" for the running and the queued jobs. A resume does nothing.
## The model is loaded again by the next request_load() (LocalStt does that for every request, and warm()).
## Idle: when `idle_unload_sec` > 0 and nothing is queued or running, the model is unloaded that many seconds (of `clock`) after the
## last use.
##
## Job results ({ok, error, text, words, duration, ms, model}) are what the bridge returned, or {ok:false, error} with error one of
## "no_engine" (no bridge), "no_model" (nothing loaded), "load_failed" (the last load_model call failed), "aborted", "paused",
## "cancelled" (cancel_job), "shutdown". This file writes no log lines.

## Tests: the fake bridge adds 1 here when one of its load_model / unload / transcribe is called on the main thread.
static var main_thread_calls: int = 0

static var _inst: SttEngine = null

## () -> bridge object. Not valid = ClassDB.instantiate("WhisperBridge"). LocalStt copies its own `bridge_factory` here.
var bridge_factory: Callable = Callable()
## () -> seconds (float). Not valid = Time.get_ticks_msec() / 1000.0. Called on the main thread and on the engine thread.
var clock: Callable = Callable()
## 0 = never unload because of idleness.
var idle_unload_sec: float = 0.0


class Job:
	extends RefCounted
	signal finished(result: Dictionary)
	var wav: PackedByteArray = PackedByteArray()
	var opts: Dictionary = {}
	var epoch: int = 0
	## Main thread only (set by _complete_now / _job_done):
	var done: bool = false
	var result: Dictionary = {}
	## Guarded by the engine mutex:
	var t_run: float = -1.0 ## clock() when the engine thread started this job, -1 while it waits in the queue
	var abandoned: bool = false


var _bridge: Object = null
var _bridge_version: String = ""
var _thread: Thread = null
var _mx: Mutex = Mutex.new()
var _sem: Semaphore = Semaphore.new()
var _queue: Array = [] ## of Dictionary {kind: "load"|"unload"|"transcribe"|"quit", ...}
var _running: Job = null
var _loaded_path: String = ""
var _load_err: int = 0
var _epoch: int = 0
var _stopped: bool = false
var _exiting: bool = false ## the node leaves the tree / is being deleted: shutdown() must not queue_free it again
var _last_use: float = 0.0
var _jobs_open: Array = [] ## main thread only
var _stat: Dictionary = {"load_calls": 0, "unload_calls": 0, "load_ms_first": 0, "rss_before_kb": 0, "rss_after_kb": 0}


## The current engine or null (never creates one: the diagnostics and the tests look without starting a thread).
static func peek() -> SttEngine:
	if _inst != null and is_instance_valid(_inst) and not _inst._stopped:
		return _inst
	return null


## The one engine node (a stopped one is replaced). The node joins the tree one frame later (call_deferred).
static func get_or_create() -> SttEngine:
	if _inst != null and is_instance_valid(_inst) and not _inst._stopped:
		return _inst
	var e := SttEngine.new()
	e.name = "SttEngine"
	_inst = e
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree:
		(ml as SceneTree).root.add_child.call_deferred(e)
	return e


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func _exit_tree() -> void:
	_exiting = true
	shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_on_pause()
	elif what == NOTIFICATION_PREDELETE:
		if _thread != null:
			_exiting = true
			shutdown()
		if _inst == self:
			_inst = null


func _process(_delta: float) -> void:
	if idle_unload_sec <= 0.0 or _stopped:
		return
	_mx.lock()
	var idle: bool = _running == null and _queue.is_empty() and _loaded_path != ""
	_mx.unlock()
	if idle and _now() - _last_use >= idle_unload_sec:
		request_unload()


# ================================================================================================ public API (main thread)
## Queue a model load; returns at once. Nothing happens when the model that the queue will have loaded is this file already.
func request_load(path: String, threads: int = 0) -> void:
	if _stopped or path == "" or not _ensure_bridge():
		return
	_ensure_thread()
	_mx.lock()
	if _effective_path_locked() == path:
		_mx.unlock()
		return
	_queue.append({"kind": "load", "path": path, "threads": threads})
	_mx.unlock()
	_touch()
	_sem.post()


## abort() now, then free the model after the running transcription has ended. Returns at once (never waits).
func request_unload() -> void:
	if _stopped:
		return
	_mx.lock()
	if _effective_path_locked() == "":
		_mx.unlock()
		return
	var purged: Array = _purge_jobs_locked()
	_queue.append({"kind": "unload"})
	_mx.unlock()
	abort()
	for j in purged:
		_complete_now(j, {"ok": false, "error": "aborted"})
	_sem.post()


## Queue a transcription; returns the job (poll `job.done`, read `job.result`, or use transcribe()).
func submit(wav: PackedByteArray, opts: Dictionary) -> Job:
	var job := Job.new()
	job.wav = wav
	job.opts = opts.duplicate(true)
	if _stopped:
		_complete_now(job, {"ok": false, "error": "shutdown"})
		return job
	if not _ensure_bridge():
		_complete_now(job, {"ok": false, "error": "no_engine"})
		return job
	_ensure_thread()
	if _thread == null:
		_complete_now(job, {"ok": false, "error": "no_engine"})
		return job
	_mx.lock()
	job.epoch = _epoch
	_queue.append({"kind": "transcribe", "job": job})
	_mx.unlock()
	_jobs_open.append(job)
	_touch()
	_sem.post()
	return job


## Coroutine: submit + wait for the result. There is no time limit here (LocalStt watches the clock and calls cancel_job).
func transcribe(wav: PackedByteArray, opts: Dictionary) -> Dictionary:
	var job: Job = submit(wav, opts)
	if not job.done:
		await job.finished
	return job.result


## Give up on a job. A job that still waits is removed and ends "cancelled". The running job is aborted (only when it is still
## the running one: a late abort must not hit the next job); its late result is dropped by the caller.
func cancel_job(job: Job) -> void:
	if job == null or job.done:
		return
	var removed: bool = false
	_mx.lock()
	for i in _queue.size():
		var it: Dictionary = _queue[i]
		if it.get("job") == job:
			_queue.remove_at(i)
			removed = true
			break
	if not removed and _running == job:
		job.abandoned = true
		if _bridge != null:
			_bridge.abort()
	_mx.unlock()
	if removed:
		_complete_now(job, {"ok": false, "error": "cancelled"})


## bridge.abort() right now (an atomic flag; never blocks).
func abort() -> void:
	if _bridge != null:
		_bridge.abort()


func loaded_path() -> String:
	_mx.lock()
	var p: String = _loaded_path
	_mx.unlock()
	return p


func busy() -> bool:
	_mx.lock()
	var b: bool = _running != null or not _queue.is_empty()
	_mx.unlock()
	return b


## clock() of the moment the engine thread started `job`; -1 while it waits.
func job_started_at(job: Job) -> float:
	_mx.lock()
	var t: float = job.t_run
	_mx.unlock()
	return t


## Numbers for LocalStt.stats(): {load_calls, unload_calls, load_ms_first, rss_before_kb, rss_after_kb, abort_patch, bridge_version}.
func info() -> Dictionary:
	_mx.lock()
	var s: Dictionary = _stat.duplicate()
	_mx.unlock()
	s["bridge_version"] = _bridge_version
	s["abort_patch"] = 1 if _bridge_version.contains("+abort-sched") else 0
	return s


## {peak_kb, rss_kb} of the process (WhisperBridge.memory_info()), zeros when unknown. Static native call, not a bridge instance call.
func memory_now() -> Dictionary:
	return _memory(_bridge)


## Join the thread and drop the node. Safe to call twice and on every exit path.
func shutdown() -> void:
	if _stopped and _thread == null:
		return
	_stopped = true
	abort()
	var purged: Array = []
	_mx.lock()
	purged = _purge_jobs_locked()
	_queue.clear()
	_queue.append({"kind": "quit"})
	_mx.unlock()
	if _thread != null:
		_sem.post()
		_thread.wait_to_finish()
		_thread = null
	for j in purged:
		_complete_now(j, {"ok": false, "error": "shutdown"})
	for j in _jobs_open.duplicate():
		_complete_now(j, {"ok": false, "error": "shutdown"})
	_jobs_open.clear()
	_bridge = null
	if _inst == self:
		_inst = null
	if not _exiting:
		queue_free() ## a stopped engine is dropped from the tree (the next get_or_create() makes a new one)


# ================================================================================================ main thread helpers
func _now() -> float:
	if clock.is_valid():
		return float(clock.call())
	return float(Time.get_ticks_msec()) / 1000.0


func _touch() -> void:
	_last_use = _now()


func _ensure_bridge() -> bool:
	if _bridge != null:
		return true
	var b: Object = null
	if bridge_factory.is_valid():
		var v: Variant = bridge_factory.call()
		if v is Object:
			b = v
	elif ClassDB.class_exists("WhisperBridge") and ClassDB.can_instantiate("WhisperBridge"):   # class_exists first: no engine ERROR without the bridge
		b = ClassDB.instantiate("WhisperBridge")
	if b == null:
		return false
	_bridge = b
	var ver: Variant = _bridge_static(b, "version")
	_bridge_version = str(ver) if ver != null else ""
	return true


func _ensure_thread() -> void:
	if _thread != null or _stopped:
		return
	_thread = Thread.new()
	var err: int = _thread.start(_thread_main)
	if err != OK:
		_thread = null


## What the queue will have loaded when every queued item has run (mutex held).
func _effective_path_locked() -> String:
	var p: String = _loaded_path
	for it in _queue:
		var d: Dictionary = it
		if d["kind"] == "load":
			p = str(d["path"])
		elif d["kind"] == "unload":
			p = ""
	return p


## Removes every queued transcription and returns their jobs (mutex held); the caller completes them after unlocking.
func _purge_jobs_locked() -> Array:
	var jobs: Array = []
	var keep: Array = []
	for it in _queue:
		var d: Dictionary = it
		if d["kind"] == "transcribe":
			jobs.append(d["job"])
		else:
			keep.append(d)
	_queue = keep
	return jobs


func _on_pause() -> void:
	if _thread == null or _stopped:
		return
	_mx.lock()
	_epoch += 1
	var purged: Array = _purge_jobs_locked()
	_mx.unlock()
	abort()
	for j in purged:
		_complete_now(j, {"ok": false, "error": "paused"})
	request_unload()


func _complete_now(job: Job, res: Dictionary) -> void:
	if job.done:
		return
	job.result = res
	job.done = true
	_jobs_open.erase(job)
	job.finished.emit(res)


## call_deferred target: the engine thread's answer, on the main thread.
func _job_done(job: Job, res: Dictionary) -> void:
	if job.done:
		return
	_touch()
	_complete_now(job, res)


# ================================================================================================ engine thread
func _thread_main() -> void:
	while true:
		_sem.wait()
		_mx.lock()
		if _queue.is_empty():
			_mx.unlock()
			continue
		var item: Dictionary = _queue.pop_front()
		var kind: String = str(item["kind"])
		var job: Job = null
		if kind == "transcribe":
			job = item["job"]
			job.t_run = _now()
			_running = job
		_mx.unlock()
		if kind == "quit":
			_do_unload()
			return
		if kind == "load":
			_do_load(str(item["path"]), int(item["threads"]))
		elif kind == "unload":
			_do_unload()
		elif job != null:
			var res: Dictionary = _do_transcribe(job)
			_mx.lock()
			_running = null
			var late_epoch: bool = job.epoch != _epoch
			_mx.unlock()
			if late_epoch:
				res = {"ok": false, "error": "paused"}
			_job_done.call_deferred(job, res)


func _do_load(path: String, threads: int) -> void:
	var before: Dictionary = _memory(_bridge)
	var t0: int = Time.get_ticks_msec()
	var raw: Variant = _bridge.load_model(path, threads)
	var ms: int = Time.get_ticks_msec() - t0
	var err: int = int(raw) if (typeof(raw) == TYPE_INT) else FAILED
	var after: Dictionary = _memory(_bridge)
	_mx.lock()
	if _stat["load_calls"] == 0:
		_stat["load_ms_first"] = ms
	_stat["load_calls"] = int(_stat["load_calls"]) + 1
	_stat["rss_before_kb"] = int(before.get("rss_kb", 0))
	_stat["rss_after_kb"] = int(after.get("rss_kb", 0))
	if err == OK:
		_loaded_path = path
		_load_err = 0
	else:
		_loaded_path = ""
		_load_err = err
	_mx.unlock()


func _do_unload() -> void:
	_mx.lock()
	var had: bool = _loaded_path != ""
	_loaded_path = ""
	_load_err = 0
	_mx.unlock()
	if had and _bridge != null:
		_bridge.unload()
		_mx.lock()
		_stat["unload_calls"] = int(_stat["unload_calls"]) + 1
		_mx.unlock()


func _do_transcribe(job: Job) -> Dictionary:
	_mx.lock()
	var loaded: bool = _loaded_path != ""
	var lerr: int = _load_err
	_mx.unlock()
	if _bridge == null:
		return {"ok": false, "error": "no_engine"}
	if not loaded:
		return {"ok": false, "error": "load_failed" if lerr != 0 else "no_model"}
	var r: Variant = _bridge.transcribe(job.wav, "en", job.opts)
	if r is Dictionary:
		return r
	return {"ok": false, "error": "engine"}


# ================================================================================================ bridge statics
## `version` and `memory_info` are static in the native class: a fake bridge (a script object) has them as ordinary methods.
static func _bridge_static(b: Object, fn: String) -> Variant:
	if b == null:
		return null
	if b.has_method(fn):
		return b.call(fn)
	if ClassDB.class_exists("WhisperBridge"):
		return ClassDB.class_call_static("WhisperBridge", fn)
	return null


static func _memory(b: Object) -> Dictionary:
	var m: Variant = _bridge_static(b, "memory_info")
	var out: Dictionary = {"peak_kb": 0, "rss_kb": 0}
	if m is Dictionary:
		for k in out.keys():
			var v: Variant = (m as Dictionary).get(k, 0)
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				out[k] = int(v)
	return out
