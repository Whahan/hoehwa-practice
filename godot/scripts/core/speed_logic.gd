class_name SpeedLogic
extends RefCounted
## 60초 스피드 퀴즈 한 판의 규칙 (순수 계산: 노드·파일·시계를 직접 쓰지 않는다).
## docs/v160_fun_design.md §5.3 / §5.8. 시계 값(ms)은 호출자가 넣는다(Time.get_ticks_msec()).
##  - 정답 점수 = BASE_POINTS + COMBO_STEP * min(이전 콤보, COMBO_CAP). 오답은 0점·콤보 0·WRONG_LOCK_MS 동안 답 안 받음.
##  - 문제 순서: 한 바퀴(풀 전체)를 돌기 전에 같은 항목이 다시 나오지 않는다. 카드(src "card")가 SpeedPool.CARD_HALF_MIN 장
##    이상이면 한 바퀴 앞쪽에서 카드와 레슨 단어를 번갈아(카드는 마감이 빠른 순) 내서 문제의 약 절반이 카드가 된다.
##  - 나쁜 시계 값: answer 는 NaN·음수·거꾸로 가는 값이면 받지 않는다(accepted=false, 아무것도 안 바뀜).
##    tick / remaining_ms / pause / resume 은 그런 값을 직전 값으로 본다.
##  - 복습 일정(rate_review)·StudyLog 는 건드리지 않는다. 기록은 화면이 한다.

const LIMIT_MS := 60000
const BASE_POINTS := 10
const COMBO_STEP := 2           ## 정답 점수 = BASE_POINTS + COMBO_STEP * min(이전 콤보, COMBO_CAP)
const COMBO_CAP := 10
const WRONG_LOCK_MS := 900      ## 오답 뒤 이만큼은 다음 답을 받지 않는다

var _items: Array = []
var _rng: RandomNumberGenerator = null
var _limit: int = LIMIT_MS
var _started: bool = false
var _start_ms: int = 0
var _last_now: int = -1         ## 지금까지 본 가장 큰 올바른 시계 값(없으면 -1)
var _paused: bool = false
var _pause_at: int = 0
var _paused_total: int = 0
var _finished: bool = false
var _lock_until: int = 0
var _cur: Dictionary = {}
var _answered: bool = false
var _queue: Array = []
var _qpos: int = 0
var _last_id: String = ""
var _score: int = 0
var _correct: int = 0
var _total: int = 0
var _combo: int = 0
var _best_combo: int = 0
var _wrong: Array = []
var _wrong_ids: Dictionary = {}


func _init(items: Array, rng: RandomNumberGenerator, limit_ms: int = LIMIT_MS) -> void:
	_rng = rng if rng != null else RandomNumberGenerator.new()
	_limit = maxi(1, limit_ms)
	for it in items:
		if it is Dictionary and str((it as Dictionary).get("ko", "")).strip_edges() != "" \
				and str((it as Dictionary).get("w", "")) != "":
			_items.append(it)
	_load_next()


## 시계를 시작한다(한 번만. 이미 시작했으면 무시).
func start(now_ms: int) -> void:
	if _started:
		return
	_started = true
	_start_ms = _clock(now_ms)


## 지금 문제(SpeedPool.make_question 결과). 끝났거나 만들 문제가 없으면 {}.
func current() -> Dictionary:
	if _finished:
		return {}
	return _cur.duplicate(true)


## {"accepted","ok","points","combo","correct_index"}.
## 시간이 끝난 뒤·잠금 중·보기 번호 범위 밖·이미 답한 문제·시작 전·정지 중·나쁜 시계 값 -> accepted=false(아무것도 안 바뀜).
func answer(i: int, now_ms: int) -> Dictionary:
	var rej := {"accepted": false, "ok": false, "points": 0, "combo": _combo, "correct_index": -1}
	if not _started or now_ms < 0 or now_ms < _last_now:
		return rej
	var c := _clock(now_ms)
	if _time_over(c):
		return rej
	if _paused or _cur.is_empty() or _answered or c < _lock_until:
		return rej
	var opts: Array = _cur["options"]
	if i < 0 or i >= opts.size():
		return rej
	var ci: int = _cur["answer"]
	var good := i == ci
	var points := 0
	_answered = true
	_total += 1
	if good:
		points = BASE_POINTS + COMBO_STEP * mini(_combo, COMBO_CAP)
		_score += points
		_correct += 1
		_combo += 1
		_best_combo = maxi(_best_combo, _combo)
	else:
		_combo = 0
		_lock_until = c + WRONG_LOCK_MS
		var id: String = _cur.get("id", "")
		if not _wrong_ids.has(id):
			_wrong_ids[id] = true
			_wrong.append({"w": _cur["w"], "rd": _cur.get("rd", ""), "ko": _cur["ko"], "id": id, "src": _cur.get("src", "")})
	return {"accepted": true, "ok": good, "points": points, "combo": _combo, "correct_index": ci}


## 정답/오답 표시가 끝난 뒤 화면이 부른다. 다음 문제로 넘어간다.
func next_question() -> void:
	if _finished:
		_cur = {}
		return
	_answered = false
	_load_next()


## 시간이 끝났으면 true (한 번 끝나면 계속 true).
func tick(now_ms: int) -> bool:
	if not _started:
		return false
	return _time_over(_clock(now_ms))


func remaining_ms(now_ms: int) -> int:
	if not _started:
		return _limit
	if _finished:
		return 0
	return maxi(0, _limit - _elapsed(_clock(now_ms)))


func pause(now_ms: int) -> void:
	if not _started or _paused or _finished:
		return
	var c := _clock(now_ms)
	if _time_over(c):
		return
	_paused = true
	_pause_at = c


func resume(now_ms: int) -> void:
	if not _paused:
		return
	var c := maxi(_clock(now_ms), _pause_at)
	var gap := c - _pause_at
	_paused_total += gap
	_lock_until += gap
	_paused = false


func is_paused() -> bool:
	return _paused


func is_started() -> bool:
	return _started


func result() -> Dictionary:
	return {"score": _score, "correct": _correct, "total": _total, "combo": _best_combo,
		"wrong": _wrong.duplicate(true), "finished": _finished}


# ---------------------------------------------------------------- 안쪽

## 올바른 시계 값이면 기억하고 그 값을, 아니면(음수·거꾸로) 직전 값을 돌려준다.
func _clock(now_ms: int) -> int:
	if now_ms < 0 or now_ms < _last_now:
		return maxi(_last_now, 0)
	_last_now = now_ms
	return now_ms


## 정지 중이면 정지한 순간까지만 센다.
func _elapsed(c: int) -> int:
	if not _started:
		return 0
	var t := _pause_at if _paused else c
	return maxi(0, t - _start_ms - _paused_total)


func _time_over(c: int) -> bool:
	if _finished:
		return true
	if _started and _elapsed(c) >= _limit:
		_finished = true
		_cur = {}
	return _finished


## 큐에서 다음 항목으로 문제를 만든다. 만들 수 없는 항목은 건너뛰고, 한 바퀴 돌아도 없으면 {}.
func _load_next() -> void:
	_cur = {}
	var guard := _items.size() * 2 + 2
	while guard > 0:
		guard -= 1
		if _qpos >= _queue.size():
			_new_round()
			if _queue.is_empty():
				return
		var item: Dictionary = _queue[_qpos]
		_qpos += 1
		var q := SpeedPool.make_question(item, _items, _rng)
		if not q.is_empty():
			_cur = q
			_last_id = str(q["id"])
			return


## 한 바퀴 분량의 순서를 새로 만든다.
func _new_round() -> void:
	_queue = []
	_qpos = 0
	if _items.is_empty():
		return
	var cards: Array = []
	var words: Array = []
	for it in _items:
		(cards if str((it as Dictionary).get("src", "")) == "card" else words).append(it)
	SpeedPool.shuffle_rng(words, _rng)
	if cards.size() >= SpeedPool.CARD_HALF_MIN:
		SpeedPool.shuffle_rng(cards, _rng)
		cards.sort_custom(func(a, b): return int(a.get("due", 0)) < int(b.get("due", 0)))
		var ci := 0
		var wi := 0
		while ci < cards.size() or wi < words.size():
			if ci < cards.size():
				_queue.append(cards[ci])
				ci += 1
			if wi < words.size():
				_queue.append(words[wi])
				wi += 1
	else:
		_queue = cards + words
		SpeedPool.shuffle_rng(_queue, _rng)
	if _queue.size() > 1 and str((_queue[0] as Dictionary).get("id", (_queue[0] as Dictionary).get("w", ""))) == _last_id:
		var t: Variant = _queue[0]
		_queue[0] = _queue[1]
		_queue[1] = t
