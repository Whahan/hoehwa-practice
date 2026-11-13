class_name BadgeWatcher
extends Node
## 배지 평가를 언제 돌릴지 정하는 노드(main.gd 가 add_child; 새 autoload 는 없다). docs/v160_fun_design.md §3 D7, §6.5 B1.
## - Store.activity(한 단위가 끝남)·Store.changed 를 받으면 DEBOUNCE_SEC 뒤에 평가한다. 여러 신호는 한 번으로 묶는다.
## - 평가와 평가 사이는 최소 MIN_GAP_MS. 더 일찍 요청이 오면 버리지 않고 간격이 찰 때까지 미룬다.
## - TICK_SEC 마다 도는 타이머는 StudyLog.is_dirty() 이거나 마지막 평가 뒤 Store.changed 가 있었을 때만 평가한다.
## 시험은 evaluator / clock / dirty_probe 를 가짜로 바꾼다. 이 노드는 서버·파일에 접속하지 않는다.

const DEBOUNCE_SEC := 0.3
const TICK_SEC := 30.0
const MIN_GAP_MS := 2000

## (source: String) -> Variant. 비면 BadgeEngine.evaluate.
var evaluator: Callable = Callable()
## () -> int (밀리초). 비면 Time.get_ticks_msec.
var clock: Callable = Callable()
## () -> bool. 비면 StudyLog.is_dirty.
var dirty_probe: Callable = Callable()

var eval_count: int = 0 ## 평가를 실제로 돈 횟수(시험·진단용)
var _last_eval_ms: int = -1 ## -1 = 아직 평가한 적 없음
var _changed_since_eval: bool = false
var _debounce: Timer
var _tick: Timer


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = DEBOUNCE_SEC
	_debounce.timeout.connect(_on_debounce)
	add_child(_debounce)
	_tick = Timer.new()
	_tick.one_shot = false
	_tick.wait_time = TICK_SEC
	_tick.timeout.connect(on_tick)
	add_child(_tick)
	_tick.start()
	if not Store.activity.is_connected(_on_activity):
		Store.activity.connect(_on_activity)
	if not Store.changed.is_connected(_on_changed):
		Store.changed.connect(_on_changed)


func _exit_tree() -> void:
	if Store.activity.is_connected(_on_activity):
		Store.activity.disconnect(_on_activity)
	if Store.changed.is_connected(_on_changed):
		Store.changed.disconnect(_on_changed)


func _on_activity(_kind: String) -> void:
	request()


func _on_changed() -> void:
	_changed_since_eval = true
	request()


## 평가를 부탁한다: 이미 기다리는 중이면 그대로 둔다(여러 신호 = 한 번).
func request() -> void:
	if _debounce == null or not _debounce.is_inside_tree():
		return
	if _debounce.is_stopped():
		_debounce.start(DEBOUNCE_SEC)


func _on_debounce() -> void:
	var gap: int = _gap_left_ms()
	if gap > 0:
		_debounce.start(float(gap) / 1000.0 + 0.05) ## 간격이 찰 때까지 미룬다(요청을 버리지 않는다)
		return
	_evaluate("signal")


## 30초 타이머(시험이 직접 부른다). 평가를 돌렸으면 true.
func on_tick() -> bool:
	var dirty: bool = bool(dirty_probe.call()) if dirty_probe.is_valid() else StudyLog.is_dirty()
	if not dirty and not _changed_since_eval:
		return false
	if _gap_left_ms() > 0:
		return false
	_evaluate("tick")
	return true


func _now_ms() -> int:
	return int(clock.call()) if clock.is_valid() else Time.get_ticks_msec()


## 다음 평가까지 남은 밀리초(0 이하 = 지금 돌려도 됨).
func _gap_left_ms() -> int:
	if _last_eval_ms < 0:
		return 0
	var now: int = _now_ms()
	if now < _last_eval_ms: ## 시계가 거꾸로 갔다: 간격이 찬 것으로 본다
		return 0
	return MIN_GAP_MS - (now - _last_eval_ms)


func _evaluate(source: String) -> void:
	_last_eval_ms = _now_ms()
	_changed_since_eval = false
	eval_count += 1
	if evaluator.is_valid():
		evaluator.call(source)
	else:
		BadgeEngine.evaluate(source)
