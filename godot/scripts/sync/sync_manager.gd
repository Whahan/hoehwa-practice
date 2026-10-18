class_name SyncManager
extends Node
## 학습 기록 동기화의 "언제"를 맡는다 (설계 docs/sync_design.md §6.1, §6.2, §4.8.1). 병합·저장은 SyncEngine 이 한다.
##
## 지킬 것
##  * 동기화는 choice != "undecided" 이고 스위치(enabled)가 켜져 있을 때만. 아니면 타이머·신호·폴링·백그라운드·복귀 어디서도
##    engine.sync_now 를 부르지 않는다(요청 0). 확인은 요청을 만들 때와 지연된 요청이 실제로 나가기 직전, 두 번 한다.
##    예외는 PC 앱의 첫 연결 probe 하나(읽기 전용, 60초마다, 선택 전에만).
##  * 폰은 선택 전에 /sync/* 를 한 번도 보내지 않는다. 첫 READY 에 `choice_needed("phone")` 신호만 낸다.
##  * 녹음 중이라 적용이 미뤄진 결과("busy")는 오류로 세지 않고 5초 뒤 다시 한다.
##  * PC 창을 닫을 때는 아무것도 하지 않는다(종료를 지연시키지 않는다). 폰은 백그라운드로 갈 때 지문이 다르면 1회(HTTP 5초 상한).
##
## 시간은 `advance(dt)` 로만 흐른다(_process 가 부른다). 시험은 가짜 엔진과 `advance()` 로 몇 시간치를 바로 돌린다.
## 화면(SyncPanel / SyncChoiceDialog)은 이 노드의 공개 함수만 쓴다: set_enabled / choose / sync_manual / restore / relink / before_reset.

signal choice_needed(kind: String) ## "phone" | "pc"
signal state_changed ## 화면이 다시 그릴 때
signal round_finished(result: Dictionary)

const START_DELAY := 3.0
const RECONNECT_DELAY := 1.0
const RESUME_DELAY := 1.0
const CHANGE_CHECK_SEC := 20.0
const CHANGE_DEBOUNCE_SEC := 20.0
const MIN_AUTO_GAP := 30.0
const POLL_PC_SEC := 60.0
const POLL_PHONE_SEC := 90.0
const PROBE_SEC := 60.0
const BUSY_RETRY_SEC := 5.0
const PAUSE_HTTP_TIMEOUT := 5.0
const BACKOFF_BASE := 30.0
const BACKOFF_MAX := 300.0
## 같은 오류가 되풀이될 뿐이라 사용자가 손대기 전에는 자동으로 다시 하지 않는 결과 코드.
const HALT_CODES := ["server_rejected", "hub_changed", "state_lost"]

## 지금 떠 있는 매니저(앱에 하나). SyncPanel 이 찾는다.
static var current: SyncManager = null

## 동기화 엔진(SyncEngine 또는 같은 함수를 가진 가짜). add_child 전에 바꿔 끼울 수 있다.
var engine = null
var kind: String = "phone" if Platform.is_phone() else "pc"
## () -> bool. 기본: Backend.status == READY.
var is_backend_ready: Callable = func() -> bool: return Backend.status == Backend.Status.READY
var connect_backend: bool = true ## 시험은 false
var auto_process: bool = true ## 시험은 false 로 두고 advance() 를 직접 부른다
var auto_dialog: bool = true ## choice_needed 에서 첫 연결 대화상자를 연다. 시험은 false
var last_result: Dictionary = {}
## () -> String. 값이 지난번과 같으면 로컬 기록이 바뀌지 않았다고 보고 무거운 지문 계산을 건너뛴다. ""(알 수 없음)이면 늘 계산한다.
## 실제 앱은 파일 수정 시각·크기(live_change_hint)를 쓴다. 비어 있으면 매번 계산한다(시험).
var change_hint: Callable = Callable()

var _t: float = 0.0
var _closing: bool = false
var _backend_up: bool = false
var _seen_ready: bool = false
var _paused: bool = false
var _busy: bool = false
var _again: String = ""
var _due: Array = [] ## 대기 중인 일회성 요청: [시각, 이유]
var _next_poll: float = -1.0
var _next_check: float = -1.0
var _synced_fp: String = ""
var _hint_sig: String = ""
var _hint_fp: String = ""
var _dirty_fp: String = ""
var _dirty_since: float = 0.0
var _last_end: float = -1.0e9
var _fails: int = 0
var _backoff_until: float = 0.0
var _halt: bool = false
var _resetting: bool = false ## before_reset() 가 진행 중인 라운드가 끝나기를 기다리는 동안: 새 라운드를 시작하지 않는다
var _choice_emitted: bool = false
var _probe_at: float = -1.0
var _probe_busy: bool = false
var _http_cap := {"v": 0.0} ## > 0 이면 엔진의 HTTP 타임아웃을 이 값으로 줄인다(폰 pause 때 5초)
var _dialog: SyncChoiceDialog = null


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	_closing = true
	if current == self:
		current = null


func _ready() -> void:
	if engine == null:
		engine = SyncEngine.new(_live_ports())
		if not change_hint.is_valid():
			change_hint = SyncManager.live_change_hint
	set_process(auto_process)
	_next_check = _t + CHANGE_CHECK_SEC
	if connect_backend:
		Backend.status_changed.connect(backend_changed)
	backend_changed()


func _process(delta: float) -> void:
	advance(delta)


## 로컬 기록 파일 3개의 수정 시각·크기. 스터디 시계가 쓰는 중(StudyLog 가 아직 저장 전)이면 ""(알 수 없음 -> 지문을 다시 계산).
## 기록이 많으면(복습 카드 3000장 + 아는 단어 6만 개) 지문 한 번이 PC 에서 0.3초쯤 걸려서 20초마다 하면 폰에서 끊겨 보인다.
static func live_change_hint() -> String:
	if StudyLog.is_dirty():
		return ""
	var parts: Array[String] = []
	for path in [Store.progress_path, Store.prefs_path, StudyLog.path]:
		var size: int = -1
		var f: FileAccess = FileAccess.open(str(path), FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
		parts.append("%d:%d" % [FileAccess.get_modified_time(str(path)), size])
	return "|".join(parts)


## 로컬 기록의 지문. change_hint 가 "바뀐 게 없다"고 하면 지난 계산을 다시 쓴다.
func _fingerprint_now() -> String:
	var sig: String = ""
	if change_hint.is_valid():
		sig = str(change_hint.call())
	if sig != "" and sig == _hint_sig and _hint_fp != "":
		return _hint_fp
	var fp: String = str(engine.local_fingerprint())
	_hint_sig = sig
	_hint_fp = fp
	return fp


## 실제 앱의 포트(Store / StudyLog / Api). HTTP 타임아웃만 _http_cap 으로 줄일 수 있게 감싼다.
func _live_ports() -> SyncPorts:
	var p: SyncPorts = SyncPorts.live()
	wrap_ports(p)
	return p


## p.http_get / http_post 가 _http_cap["v"] > 0 인 동안 타임아웃을 그 값으로 줄이게 감싼다(시험도 쓴다).
func wrap_ports(p: SyncPorts) -> void:
	var cap: Dictionary = _http_cap
	var g: Callable = p.http_get
	var po: Callable = p.http_post
	if g.is_valid():
		p.http_get = func(path: String, timeout: float) -> Dictionary:
			var c: float = float(cap["v"])
			return await g.call(path, minf(timeout, c) if c > 0.0 else timeout)
	if po.is_valid():
		p.http_post = func(path: String, body: Dictionary, timeout: float) -> Dictionary:
			var c: float = float(cap["v"])
			return await po.call(path, body, minf(timeout, c) if c > 0.0 else timeout)


# ---------------------------------------------------------------- questions

func is_busy() -> bool:
	return _busy


## 시작한 뒤 흐른 (가상) 시간(초). 시험이 쓴다.
func elapsed() -> float:
	return _t


## 이어서 실패한 자동 시도 횟수(성공·연결 회복·"busy" 는 0 으로/세지 않음). 시험이 쓴다.
func failure_count() -> int:
	return _fails


func is_paused() -> bool:
	return _paused


func poll_interval() -> float:
	return POLL_PHONE_SEC if kind == "phone" else POLL_PC_SEC


## 선택을 마쳤고 스위치가 켜져 있고 상태 파일이 멀쩡한가. false 이면 어떤 계기도 요청을 만들지 않는다.
func sync_allowed() -> bool:
	if engine == null:
		return false
	var st: Dictionary = engine.status()
	return str(st.get("choice", "undecided")) != "undecided" and bool(st.get("enabled", false)) and not bool(st.get("lost", false))


func status() -> Dictionary:
	var st: Dictionary = engine.status() if engine != null else {}
	st["manager_busy"] = _busy
	return st


# ---------------------------------------------------------------- time

## 가상 시간을 dt 초 흘리고, 때가 된 일을 한다.
func advance(dt: float) -> void:
	if _closing or engine == null:
		return
	_t += maxf(dt, 0.0)
	if not _paused and not _due.is_empty():
		var now_due: Array = []
		var rest: Array = []
		for d in _due:
			if _t >= float((d as Array)[0]):
				now_due.append(d)
			else:
				rest.append(d)
		if not now_due.is_empty():
			_due = rest
			now_due.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
			for d in now_due:
				_fire(str((d as Array)[1]))
	if not _backend_up or _paused:
		return
	if _next_poll >= 0.0 and _t >= _next_poll:
		_next_poll = _t + poll_interval()
		request_sync("poll")
	if _next_check >= 0.0 and _t >= _next_check:
		_next_check = _t + CHANGE_CHECK_SEC
		_check_changes()
	_probe_tick()


## 일회성 요청 예약. 같은 이유가 이미 대기 중이면 더 이른 쪽만 남긴다.
func _schedule(reason: String, delay: float) -> void:
	var at: float = _t + delay
	for d in _due:
		if str((d as Array)[1]) == reason:
			if at < float((d as Array)[0]):
				(d as Array)[0] = at
			return
	_due.append([at, reason])


func _fire(reason: String) -> void:
	if reason == "manual":
		sync_manual()
	else:
		request_sync(reason)


## 지문이 마지막 동기화와 다르면 20초 묵힌 뒤(마지막 변경 후 20초) 한 번 올린다. 자동 동기화 사이는 30초 이상.
func _check_changes() -> void:
	if _busy or not _auto_ok():
		return
	var fp: String = _fingerprint_now()
	if fp == _synced_fp:
		_dirty_fp = ""
		return
	if fp != _dirty_fp:
		_dirty_fp = fp
		_dirty_since = _t
		return
	if _t - _dirty_since >= CHANGE_DEBOUNCE_SEC and _t - _last_end >= MIN_AUTO_GAP:
		request_sync("change")


## 자동 계기가 지금 요청을 만들어도 되나(앞/뒤, 연결, 실패 대기, 멈춤 상태, 스위치).
func _auto_ok() -> bool:
	if _closing or _paused or _halt or _resetting or not _backend_up:
		return false
	if _t < _backoff_until:
		return false
	return sync_allowed()


# ---------------------------------------------------------------- requests

## 자동 계기가 쓰는 입구. 꺼짐/선택 전이면 아무것도 하지 않는다. 진행 중이면 "한 번 더" 하나로 합친다.
func request_sync(reason: String) -> void:
	if reason == "manual":
		sync_manual()
		return
	if not _auto_ok():
		return
	if _busy:
		_again = reason
		return
	_launch(reason)


## "지금 동기화" 버튼: 최소 간격·실패 대기를 무시하고 즉시. 진행 중이면 무시.
func sync_manual() -> void:
	if _closing or _busy or _resetting or not sync_allowed():
		return
	_halt = false
	_launch("manual")


func _launch(reason: String) -> void:
	_run(reason)


func _run(reason: String) -> void:
	# 지연된 요청이 나가기 직전에 한 번 더 확인한다(그 사이 스위치를 껐을 수 있다).
	if _busy or _resetting or not sync_allowed():
		return
	_busy = true
	state_changed.emit()
	var fp0: String = str(engine.local_fingerprint())
	_hint_sig = ""
	_http_cap["v"] = PAUSE_HTTP_TIMEOUT if reason == "pause" else 0.0
	var res: Dictionary = await engine.sync_now(reason)
	_http_cap["v"] = 0.0
	if _closing:
		return
	_busy = false
	_after_round(res, reason, fp0)
	if _again != "":
		var nxt: String = _again
		_again = ""
		request_sync(nxt)


func _after_round(res: Dictionary, reason: String, fp0: String) -> void:
	last_result = res
	var code: String = str(res.get("code", ""))
	var manual: bool = reason == "manual"
	if bool(res.get("ok", false)):
		_fails = 0
		_backoff_until = 0.0
		_halt = false
		_synced_fp = str(engine.local_fingerprint()) if bool(res.get("applied", false)) else fp0
		_hint_sig = ""
		_dirty_fp = ""
		_last_end = _t
		_announce_ok(res, manual)
	elif code == "disabled" or code == "in_progress":
		if code == "in_progress" and not manual:
			_schedule(reason, BUSY_RETRY_SEC)
	elif code == "busy":
		# 녹음 중이라 적용을 미뤘다. 오류가 아니다. 5초 뒤 다시.
		_schedule(reason, BUSY_RETRY_SEC)
		if manual:
			Toast.info(SyncPanel.TOAST_BUSY)
	else:
		_last_end = _t
		if manual:
			Toast.error(SyncPanel.error_text(res))
		else:
			_fails += 1
			_backoff_until = _t + backoff_for(_fails)
			if HALT_CODES.has(code):
				_halt = true
	state_changed.emit()
	round_finished.emit(res)


## 연속 실패 n 번째 뒤 기다릴 초: 30, 60, 120, 240, 300, 300 ...
static func backoff_for(n: int) -> float:
	if n <= 0:
		return 0.0
	return minf(BACKOFF_MAX, BACKOFF_BASE * pow(2.0, float(n - 1)))


func _announce_ok(res: Dictionary, manual: bool) -> void:
	var trimmed: Dictionary = res.get("trimmed", {}) as Dictionary
	var tc: int = int(trimmed.get("cards", 0))
	var tk: int = int(trimmed.get("known", 0))
	if tc > 0 or tk > 0:
		Toast.info(SyncPanel.TOAST_TRIMMED % [tc, tk])
	if bool(res.get("first", false)) and int(res.get("peers", 0)) > 0:
		Toast.ok(SyncPanel.TOAST_FIRST_MERGE)
	elif manual:
		var added: int = int((res.get("changes", {}) as Dictionary).get("cards_added", 0))
		Toast.ok(SyncPanel.TOAST_SYNCED + ((SyncPanel.TOAST_SYNCED_CARDS % added) if added > 0 else ""))


# ---------------------------------------------------------------- Backend / lifecycle

## Backend.status_changed 때마다. 값이 바뀐 것(READY 로 들어옴 / 나감)만 본다.
func backend_changed() -> void:
	if _closing:
		return
	var up: bool = bool(is_backend_ready.call())
	var was: bool = _backend_up
	_backend_up = up
	if not up:
		state_changed.emit()
		return
	if was:
		return
	if not _seen_ready:
		_seen_ready = true
		_next_poll = _t + poll_interval()
		_next_check = _t + CHANGE_CHECK_SEC
		_schedule("start", START_DELAY)
		_probe_at = _t + START_DELAY
		_maybe_emit_choice_phone()
	else:
		# 연결 회복: 실패 대기를 지우고 1초 뒤 1회
		_fails = 0
		_backoff_until = 0.0
		_halt = false
		_next_poll = _t + poll_interval()
		_schedule("reconnect", RECONNECT_DELAY)
	state_changed.emit()


func _maybe_emit_choice_phone() -> void:
	if kind != "phone" or _choice_emitted or engine == null:
		return
	if engine.needs_choice():
		_emit_choice("phone")


func _emit_choice(k: String) -> void:
	_choice_emitted = true
	choice_needed.emit(k)
	if auto_dialog and is_inside_tree():
		open_choice_dialog(k)


## PC 앱, 아직 고르지 않았을 때: 60초마다 읽기 전용으로 허브를 들여다보고 다른 기기 복제본이 있으면 한 번 묻는다.
func _probe_tick() -> void:
	if kind != "pc" or _probe_busy or _choice_emitted or _probe_at < 0.0 or _t < _probe_at:
		return
	if engine == null or not engine.needs_choice():
		_probe_at = -1.0 # 선택이 끝났다: probe 는 멈춘다
		return
	_probe_at = _t + PROBE_SEC
	_do_probe()


func _do_probe() -> void:
	_probe_busy = true
	var n: int = int(await engine.probe_peers())
	_probe_busy = false
	if _closing:
		return
	if n > 0 and engine.needs_choice() and not _choice_emitted:
		_emit_choice("pc")


## 폰 앱이 백그라운드로 갔다(NOTIFICATION_APPLICATION_PAUSED). 폴링은 멈추고, 지문이 다를 때만 즉시 1회(HTTP 5초 상한).
func on_app_paused() -> void:
	if kind != "phone" or _closing:
		return
	_paused = true
	if _busy:
		return
	if _backend_up and _auto_ok_for_pause() and _fingerprint_now() != _synced_fp:
		_launch("pause")


func _auto_ok_for_pause() -> bool:
	# 이미 멈춘 상태(_paused)에서 부르므로 그 조건만 뺀다
	if _closing or _halt or _resetting or not _backend_up or _t < _backoff_until:
		return false
	return sync_allowed()


## 폰이 앞으로 돌아왔다: 폴링 재개, 1초 뒤 1회.
func on_app_resumed() -> void:
	if kind != "phone" or _closing:
		return
	_paused = false
	_next_poll = _t + poll_interval()
	_schedule("resume", RESUME_DELAY)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		on_app_paused()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		on_app_resumed()
	# NOTIFICATION_WM_CLOSE_REQUEST: 일부러 아무것도 하지 않는다(PC 종료를 지연시키지 않는다. 다음 시작 때 반영).


# ---------------------------------------------------------------- 화면이 쓰는 함수

## 설정 스위치. 켜면 바로 한 번 동기화한다(꺼 둔 동안의 기록 재합류 포함). 끄면 대기 중인 요청도 지운다.
func set_enabled(on: bool) -> void:
	if engine == null:
		return
	engine.set_enabled(on)
	if on:
		_halt = false
		_fails = 0
		_backoff_until = 0.0
		_dirty_fp = ""
		_synced_fp = ""
		sync_manual()
	else:
		_due.clear()
		_again = ""
	state_changed.emit()


## 첫 연결 선택: "merge" | "separate". 엔진 결과(Dictionary)를 돌려준다. await 필요.
func choose(choice: String) -> Dictionary:
	if _busy or _resetting:
		return {"ok": false, "code": "in_progress", "error": SyncPanel.error_text({"code": "in_progress"})}
	_busy = true
	state_changed.emit()
	_http_cap["v"] = 0.0
	var fp0: String = str(engine.local_fingerprint())
	var res: Dictionary = await engine.set_choice(choice)
	_busy = false
	if not engine.needs_choice():
		_choice_emitted = false
		_probe_at = -1.0
	if choice == "separate":
		if bool(res.get("ok", false)):
			Toast.info(SyncPanel.TOAST_SEPARATE)
		last_result = res
		state_changed.emit()
		return res
	if str(res.get("code", "")) == "bad_choice":
		state_changed.emit()
		return res
	_after_round(res, "manual", fp0)
	return res


## 되돌리기. 결과 {"ok", "error"}.
func restore(name: String) -> Dictionary:
	var r: Dictionary = engine.restore_backup(name)
	if bool(r.get("ok", false)):
		_synced_fp = ""
		_dirty_fp = ""
		_due.clear()
		_again = ""
		Toast.ok(SyncPanel.restored_text(kind))
	else:
		Toast.error(str(r.get("error", "")))
	state_changed.emit()
	return r


## "이 PC와 새로 합치기" / "새로 합치기". await 필요.
func relink() -> Dictionary:
	if _busy or _resetting:
		return {"ok": false, "code": "in_progress", "error": SyncPanel.error_text({"code": "in_progress"})}
	_busy = true
	state_changed.emit()
	var fp0: String = str(engine.local_fingerprint())
	var res: Dictionary = await engine.relink_fresh()
	_busy = false
	_halt = false
	_after_round(res, "manual", fp0)
	return res


## "모든 기록 지우기" 직전: 동기화가 켜져 있으면 연결을 끊는다(§4.8). 아무 연결이 없으면 아무것도 안 한다.
## 진행 중인 라운드가 있으면 그것이 끝난 뒤에 끊는다(안 그러면 라운드가 지운 기록 위에 허브 기록을 다시 적용한다).
## 기다리는 동안 새 라운드는 시작하지 않는다. 호출하는 쪽은 `await` 하고, 돌아온 뒤 곧바로 기록을 지운다(그 사이 await 없음).
func before_reset() -> void:
	if engine == null:
		return
	_resetting = true
	_due.clear()
	_again = ""
	while _busy and not _closing:
		await state_changed
	if _closing:
		_resetting = false
		return
	engine.unlink_for_reset()
	_resetting = false
	_synced_fp = ""
	_dirty_fp = ""
	_due.clear()
	_again = ""
	state_changed.emit()


# ---------------------------------------------------------------- 첫 연결 대화상자

func is_choice_dialog_open() -> bool:
	return _dialog != null and is_instance_valid(_dialog)


## 안드로이드 뒤로 가기(main.gd handle_back 가 먼저 묻는다): 첫 연결 대화상자가 떠 있으면 소비하고 한 줄만 알린다.
## 합치기/따로 쓰기 중 하나를 골라야 하므로 뒤 화면은 움직이지 않는다. 소비했으면 true.
func consume_back() -> bool:
	if not is_choice_dialog_open():
		return false
	Toast.info(SyncPanel.TOAST_CHOOSE)
	return true

func open_choice_dialog(k: String) -> SyncChoiceDialog:
	if _dialog != null and is_instance_valid(_dialog):
		return _dialog
	var d := SyncChoiceDialog.new()
	d.manager = self
	d.kind = k
	d.closed.connect(func() -> void: _dialog = null)
	_dialog = d
	add_child(d)
	return d
