class_name StudyClock
extends Node
## 공부 시간 측정. 5초 단위로 점검해서, 창에 포커스가 있고 최근 45초 안에 입력이 있었거나
## 녹음·재생·서버 요청 중일 때만 그 5초를 StudyLog 에 더한다. 목표 시간에 처음 닿으면 토스트 + 오늘 공부 표시.
## main.gd 에 add_child(StudyClock.new()) 한 줄이면 된다 (현재 뷰는 부모의 `current`).

const STEP := 5.0 ## seconds added per step
const IDLE_MSEC := 45000 ## no input for longer than this = idle
const FLUSH_EVERY := 30.0 ## seconds between saves
const MAX_ELAPSED := 15.0 ## a longer gap between two checks (sleep, debugger pause) is not counted

## lang -> {"day": day number, "goal": minutes} of the last goal toast, so the same goal is announced once a day.
static var _celebrated: Dictionary = {}

## Tests: replace the real checks.
var lang_override: String = ""
var view_override: String = ""
var focus_override: int = -1 ## -1 = ask the window, 0 = pretend no focus, 1 = pretend focus

var _acc: float = 0.0
var _since_flush: float = 0.0
var _last_input_msec: int = 0
var _last_check_msec: int = 0
var _timer: Timer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_input_msec = Time.get_ticks_msec()
	_last_check_msec = _last_input_msec
	_timer = Timer.new()
	_timer.wait_time = STEP
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)


func _input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventScreenTouch or event is InputEventScreenDrag:
		_last_input_msec = Time.get_ticks_msec()
	elif event is InputEventMouseButton:
		_last_input_msec = Time.get_ticks_msec()
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).relative != Vector2.ZERO:
		_last_input_msec = Time.get_ticks_msec()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_PREDELETE:
		StudyLog.flush()


func _exit_tree() -> void:
	StudyLog.flush()


## True when the last few seconds count as study time.
func is_active() -> bool:
	if focus_override == 0:
		return false
	if focus_override < 0:
		var win: Window = get_window() if is_inside_tree() else null
		if win != null and not win.has_focus():
			return false
	if Recorder.recording or Tts.playing or Api.active_count > 0:
		return true
	return Time.get_ticks_msec() - _last_input_msec <= IDLE_MSEC


func current_lang() -> String:
	return lang_override if lang_override != "" else Store.lang()


func current_view() -> String:
	if view_override != "":
		return view_override
	var p: Node = get_parent()
	if p != null:
		var v: Variant = p.get("current")
		if v is String:
			return v
	return ""


func _on_timer() -> void:
	var now: int = Time.get_ticks_msec()
	var elapsed: float = clampf(float(now - _last_check_msec) / 1000.0, 0.0, MAX_ELAPSED)
	_last_check_msec = now
	tick(elapsed, is_active())


## Adds `delta` seconds of study time when `active`; whole STEP-second chunks are written to StudyLog
## (each into the day it happens on, so a tick after midnight lands on the new date).
## Returns the seconds written. Not active -> nothing counts and the partial step is dropped.
func tick(delta: float, active: bool) -> int:
	_since_flush += maxf(delta, 0.0)
	if _since_flush >= FLUSH_EVERY:
		_since_flush = 0.0
		StudyLog.flush()
	if not active or delta <= 0.0 or is_nan(delta):
		_acc = 0.0
		return 0
	_acc += minf(delta, MAX_ELAPSED)
	var written := 0
	while _acc >= STEP:
		_acc -= STEP
		var lang: String = current_lang()
		var goal_sec: int = StudyLog.goal_minutes() * 60
		var before: int = StudyLog.today_seconds(lang)
		StudyLog.add_seconds(lang, current_view(), int(STEP))
		var after: int = StudyLog.today_seconds(lang)
		written += after - before
		if goal_sec > 0 and before < goal_sec and after >= goal_sec:
			_goal_reached(lang)
	return written


## Call right after the goal was changed: if today's time already reaches the (lowered) goal, announce it and mark
## the day now -- tick() only notices the moment the time crosses the goal, which would never happen again.
## Returns true when it announced.
static func check_goal(lang: String) -> bool:
	var goal: int = StudyLog.goal_minutes()
	if goal <= 0 or StudyLog.today_seconds(lang) < goal * 60:
		return false
	return _goal_reached(lang)


## Toast + "studied today" mark, once per day and goal (a harder goal reached later is announced again).
static func _goal_reached(lang: String) -> bool:
	var goal: int = StudyLog.goal_minutes()
	var today: int = StudyLog.today()
	var last: Variant = _celebrated.get(lang, null)
	if last is Dictionary and int((last as Dictionary)["day"]) == today and int((last as Dictionary)["goal"]) >= goal:
		return false
	_celebrated[lang] = {"day": today, "goal": goal}
	Toast.ok("오늘 목표 %d분을 달성했어요!" % goal)
	Store.mark_today(lang)
	Store.save_progress()
	return true
