class_name MemoSession
extends RefCounted
## 가사 외우기 M3: 한 번의 외우기 판 (오늘의 큐 · 줄마다의 단계 상태기계 · FSRS 평가 · 요약). 설계 docs/lyrics_memorize_design.md
## §3.5·§3.6·§5.4·§5.5·§12.1b. 화면이 아닌 순수 로직이다: 파일·네트워크·전역 상태·난수를 직접 쓰지 않는다.
##   - 시간은 주입한다: begin 의 now, 또는 opts.clock (Callable -> int). 시험은 now 를 바꿔 날짜 경과를 흉내 낸다.
##   - 저장도 주입한다: opts.save (Callable(id: String, memo: Dictionary) -> bool 또는 {ok, err_code}).
##     화면(M5)은 곡 저장소의 save_memo 를 넘긴다. 저장은 줄이 끝날 때 · leave_line · 판이 끝날 때(finish)에만 한다.
##     저장이 실패하면 session.memo 는 바뀌지 않고(상태 유지) 줄은 끝나지 않은 채 남아 오류를 돌려준다. retry_save() 로 다시 시도한다.
##     opts.save 가 없으면 저장하지 않는다: 호출한 쪽이 session.memo 를 저장한다.
##
## 한 줄의 진행:
##   단계 계획 = MemoMask.stage_plan(단위 수, fast). 새 줄은 0(읽기)에서 시작(memo 에 저장된 도달 단계가 있으면 거기서 이어서),
##   복습 줄(카드 있음)은 맨 끝 단계(빈 화면)에서 시작. 단계를 통과하면 다음 단계, 맨 끝 단계를 통과하면 줄 끝.
##   같은 단계에서 2번 틀리거나 reveal() 하면 정답 공개(revealed) 후 단계를 하나 내린다 (최소 1).
##   평가는 맨 끝 단계의 결과만 본다: 맨 끝에서 정답 공개가 있었으면 Again, 맨 끝에서 틀린 적이 있거나 첫 시도가 good 이 아니면 Hard, 아니면 Good.
##   새 줄(카드 없음)은 줄 끝에 카드를 만든다: Good = GOOD 두 번(5단계 통과를 학습 단계를 마친 것으로 봄), Hard = GOOD 한 번, Again = AGAIN 한 번.
##   카드가 있는 줄은 평가 하나를 한 번 적용한다.
##   practice_only (연습만) 와 읽기 전용 memo(v > 1)는 기록·통계·저장을 하지 않는다.
##
## 이벤트 (submit / skip_read / reveal / retry_save 가 돌려주는 Dictionary 의 "event"):
##   stage_pass  단계 통과 (다음 단계로)            stage_fail  틀림 (같은 단계에 남음, fails_stage 증가)
##   revealed    정답 공개 + 단계 내려감              line_done   줄 끝 (평가 적용·저장 완료)
##   save_failed 줄 끝 평가는 끝났으나 저장 실패 (retry_save 로 다시)    ignored  무시됨 (reason)

const STAGE_FLOOR := 1 ## 정답 공개로 내려가도 이 단계 아래로는 가지 않는다 (0 은 읽기 단계)
const FAILS_TO_REVEAL := 2

var memo: Dictionary = {} ## 고쳐진 기록 (저장에 성공한 상태만 반영된다)
var now: int = 0
var last_error: String = "" ## 마지막 저장 오류 코드 ("" = 없음)
var saves: int = 0 ## 저장 함수를 성공으로 부른 횟수
var finished: bool = false

var song: Dictionary = {}
var lang: String = "en"
var fast: bool = false
var prev_cue: bool = true
var practice_only: bool = false
var read_only_memo: bool = false

var _id: String = ""
var _save: Callable = Callable()
var _clock: Callable = Callable()
var _queue: Array = []
var _pos: int = -1
var _ln: Dictionary = {} ## 지금 줄의 상태
var _counted: int = 0
var _ratings := {"again": 0, "hard": 0, "good": 0}
var _new_done: int = 0
var _review_done: int = 0
var _undo: Dictionary = {} ## 직전 말하기 오답 직전의 줄 상태 (self_pass 용). 다른 동작을 하면 비운다


# ---------------------------------------------------------------- begin / clock

func _t() -> int:
	if _clock.is_valid():
		var v: Variant = _clock.call()
		if v is int or v is float:
			if is_finite(float(v)):
				now = clampi(int(v), 0, MemoModel.MAX_TIME)
	return now


static func _int(v: Variant, lo: int, hi: int, d: int) -> int:
	return SongModel.int_of(v, lo, hi, d)


static func _bool(v: Variant, d: bool) -> bool:
	return v if v is bool else d


## 새 판을 시작한다. 이전 상태는 모두 버린다.
## opts: fast(false), review_cap(20), new_cap(5), only_line(-1: 그 줄 하나), skip_new(0), practice_only(false), prev_cue(true),
##       id(곡 id, 기본 song.id), save(Callable), clock(Callable -> int)
func begin(song_in: Variant, memo_in: Variant, now_in: int, opts: Variant = {}) -> void:
	var o: Dictionary = opts if opts is Dictionary else {}
	song = (song_in as Dictionary).duplicate(true) if song_in is Dictionary else {}
	lang = "ja" if str(song.get("lang", "en")) == "ja" else "en"
	now = clampi(now_in, 0, MemoModel.MAX_TIME)
	_clock = o["clock"] if (o.get("clock", null) is Callable) else Callable()
	_save = o["save"] if (o.get("save", null) is Callable) else Callable()
	_id = str(o.get("id", song.get("id", "")))
	fast = _bool(o.get("fast", false), false)
	prev_cue = _bool(o.get("prev_cue", true), true)
	memo = MemoModel.normalize(memo_in, _t())
	read_only_memo = MemoModel.is_read_only(memo)
	practice_only = _bool(o.get("practice_only", false), false) or read_only_memo
	last_error = ""
	saves = 0
	finished = false
	_counted = 0
	_ratings = {"again": 0, "hard": 0, "good": 0}
	_new_done = 0
	_review_done = 0
	_ln = {}
	_pos = -1
	_queue = _make_queue(o)
	if not _queue.is_empty():
		_pos = 0
		_open_line()


## 오늘의 큐: MemoModel.build_queue 그대로. 가릴 단위가 0개인 줄은 단계를 만들 수 없어 안전하게 뺀다
## (is_memo_line 이 참이면 단위가 1개 이상이라 지금은 닿지 않는 방어선이다).
func _make_queue(o: Dictionary) -> Array:
	var q: Array = MemoModel.build_queue(song, memo, _t(), {
		"review_cap": _int(o.get("review_cap", MemoModel.REVIEW_CAP), 0, 100000, MemoModel.REVIEW_CAP),
		"new_cap": _int(o.get("new_cap", MemoModel.NEW_CAP), 0, 100000, MemoModel.NEW_CAP),
		"only_line": _int(o.get("only_line", -1), -1, 1000000, -1),
		"skip_new": _int(o.get("skip_new", 0), 0, 100000, 0)})
	var out: Array = []
	for e in q:
		if not (MemoMask.units(_text_at(int(e["i"])), lang)["units"] as Array).is_empty():
			out.append(e)
	return out


func _line_dict(i: int) -> Dictionary:
	var ls: Variant = song.get("lines", [])
	if ls is Array and i >= 0 and i < (ls as Array).size() and (ls as Array)[i] is Dictionary:
		return (ls as Array)[i]
	return {}


func _text_at(i: int) -> String:
	var v: Variant = _line_dict(i).get("text", "")
	return v if v is String else ""


func _str_at(i: int, k: String) -> String:
	var v: Variant = _line_dict(i).get(k, "")
	return v if v is String else ""


## 곡 순서에서 i 바로 앞의 외울 줄(구간 표시·기호만 있는 줄은 건너뜀) 글자. 없으면 "".
func _prev_text(i: int) -> String:
	var j: int = i - 1
	while j >= 0:
		var d: Dictionary = _line_dict(j)
		if not d.is_empty() and MemoModel.is_memo_line(d, lang):
			return _text_at(j)
		j -= 1
	return ""


func _entry(key: String) -> Dictionary:
	var ls: Variant = memo.get("lines", {})
	if ls is Dictionary and (ls as Dictionary).get(key, null) is Dictionary:
		return (ls as Dictionary)[key]
	return {}


func _card_of(key: String) -> Dictionary:
	var c: Variant = _entry(key).get("card", null)
	return c if c is Dictionary else {}


## 큐의 _pos 번째 줄을 연다 (단계·카운터 초기화).
func _open_line() -> void:
	var e: Dictionary = _queue[_pos]
	var i: int = int(e["i"])
	var text: String = _text_at(i)
	var u: Dictionary = MemoMask.units(text, lang)
	var n: int = (u["units"] as Array).size()
	var plan: Array = MemoMask.stage_plan(n, fast)
	var final_stage: int = plan.size() - 1
	var stage: int = final_stage
	if str(e["kind"]) == "new":
		stage = clampi(int(_entry(str(e["key"])).get("stage", 0)), 0, final_stage)
	_undo = {}
	_ln = {
		"key": str(e["key"]), "i": i, "kind": str(e["kind"]), "text": text, "plan": plan,
		"units": u["units"], "aligned": bool(u["aligned"]), "n": n,
		"stage": stage, "start_stage": stage, "fails": 0, "revealed": false, "answered": false,
		"tries": 0, "passes": 0, "done": false, "left": false, "pending": {},
		"final_attempts": 0, "final_wrong": 0, "final_revealed": false, "final_first_good": false,
		"rating": 0, "seed": MemoMask.seed_of(str(e["key"])),
	}


# ---------------------------------------------------------------- current

func _active() -> bool:
	return not _ln.is_empty() and not bool(_ln["done"]) and not bool(_ln["left"]) and (_ln["pending"] as Dictionary).is_empty()


## 지금 줄의 화면 정보 (설계 §5.5). 줄이 없으면 {ok: false}. 줄이 끝난 뒤에도 next_line() 전까지 그 줄을 그대로 돌려준다 (done: true).
func current() -> Dictionary:
	if _ln.is_empty():
		return {"ok": false}
	var plan: Array = _ln["plan"]
	var stage: int = int(_ln["stage"])
	var n: int = int(_ln["n"])
	var count: int = int(plan[stage])
	return {
		"ok": true, "line_i": int(_ln["i"]), "key": str(_ln["key"]), "text": str(_ln["text"]),
		"reading": _str_at(int(_ln["i"]), "reading"), "ko": _str_at(int(_ln["i"]), "ko"), "lang": lang,
		"kind": str(_ln["kind"]), "practice_only": practice_only, "pos": _pos + 1, "total": _queue.size(),
		"stage": stage, "stage_count": plan.size(), "hidden": MemoMask.hidden_flags(n, count, int(_ln["seed"])),
		"hidden_count": count, "units": _ln["units"], "aligned": bool(_ln["aligned"]),
		"final": stage == plan.size() - 1, "read_only_stage": stage == 0, "fails_stage": int(_ln["fails"]),
		"revealed": bool(_ln["revealed"]),
		"prev_text": _prev_text(int(_ln["i"])) if prev_cue else "",
		"answered": bool(_ln["answered"]), "done": bool(_ln["done"]), "left": bool(_ln["left"]),
		"pending_save": not (_ln["pending"] as Dictionary).is_empty(),
		"rating": int(_ln["rating"]),
	}


func _ev(kind: String, extra: Dictionary = {}) -> Dictionary:
	var d := {"event": kind}
	if not _ln.is_empty():
		d["line_i"] = int(_ln["i"])
		d["key"] = str(_ln["key"])
		d["stage"] = int(_ln["stage"])
	d.merge(extra, true)
	return d


func _ignored(reason: String) -> Dictionary:
	return _ev("ignored", {"reason": reason})


# ---------------------------------------------------------------- stage machine

## 읽기 단계(0)를 넘긴다. 다른 단계에서는 무시.
func skip_read() -> Dictionary:
	if not _active():
		return _ignored("no_line")
	if int(_ln["stage"]) != 0:
		return _ignored("not_read_stage")
	_undo = {}
	_ln["stage"] = 1
	_ln["fails"] = 0
	_ln["revealed"] = false
	_ln["answered"] = false
	return _ev("stage_pass", {"stage_from": 0})


## 채점 결과 하나를 낸다. grade: MemoGrade.grade / MemoGrade.self_result 의 결과 (passed 가 bool 이어야 한다).
## 무음(silent)·모양이 틀린 입력·읽기 단계·이미 끝난 줄은 무시한다 (시도로 세지 않는다).
func submit(grade: Variant) -> Dictionary:
	if _ln.is_empty():
		return _ignored("no_line")
	if bool(_ln["done"]):
		return _ignored("done")
	if bool(_ln["left"]):
		return _ignored("left")
	if not (_ln["pending"] as Dictionary).is_empty():
		return _ignored("save_pending")
	if not (grade is Dictionary) or not ((grade as Dictionary).get("passed", null) is bool):
		return _ignored("bad_grade")
	var g: Dictionary = grade
	if g.get("silent", false) is bool and bool(g.get("silent", false)):
		return _ignored("silent")
	var stage: int = int(_ln["stage"])
	if stage == 0:
		return _ignored("read_stage")
	var plan: Array = _ln["plan"]
	var is_final: bool = stage == plan.size() - 1
	var passed: bool = bool(g["passed"])
	var good: bool = passed and (g.get("good", false) is bool) and bool(g.get("good", false))
	var snap: Dictionary = _ln.duplicate(true)
	var speak_fail: bool = (not passed) and str(g.get("via", "")) == "speak"
	_undo = {}
	_ln["tries"] = int(_ln["tries"]) + 1
	_ln["revealed"] = false
	_ln["answered"] = true
	if is_final:
		if int(_ln["final_attempts"]) == 0:
			_ln["final_first_good"] = good
		_ln["final_attempts"] = int(_ln["final_attempts"]) + 1
	if passed:
		_ln["passes"] = int(_ln["passes"]) + 1
		_ln["fails"] = 0
		if not is_final:
			_ln["stage"] = stage + 1
			_ln["answered"] = false
			return _ev("stage_pass", {"stage_from": stage})
		return _finish_line()
	_ln["fails"] = int(_ln["fails"]) + 1
	if is_final:
		_ln["final_wrong"] = int(_ln["final_wrong"]) + 1
	if speak_fail:
		_undo = snap
	if int(_ln["fails"]) >= FAILS_TO_REVEAL:
		return _reveal_now(stage, is_final)
	return _ev("stage_fail", {"fails_stage": int(_ln["fails"])})


## 말하기 오채점 정정 ([내가 맞게 말했어요]): 바로 앞 시도가 말하기(via "speak")로 틀린 것일 때만, 그 시도를 없던 일로 하고
## "좋음"으로 통과시킨다 (복습 평가는 Good 후보). 그 밖의 경우(입력 오답·다른 동작 뒤·이미 끝난 줄)는 무시.
## 폰 단독의 자가 평가는 이 함수가 아니라 submit(MemoGrade.self_result(good)) 로 낸다.
func self_pass() -> Dictionary:
	if _undo.is_empty() or _ln.is_empty() or int(_undo.get("i", -1)) != int(_ln["i"]) or not _active():
		return _ignored("no_speak_fail")
	_ln = _undo
	_undo = {}
	var ev: Dictionary = submit(MemoGrade.self_result(true))
	ev["self_pass"] = true
	return ev


## [정답 보기]: 그 단계를 틀린 것으로 치고 정답을 공개한 뒤 단계를 하나 내린다. 읽기 단계·끝난 줄에서는 무시.
func reveal() -> Dictionary:
	if not _active():
		return _ignored("no_line")
	var stage: int = int(_ln["stage"])
	if stage == 0:
		return _ignored("read_stage")
	var plan: Array = _ln["plan"]
	var is_final: bool = stage == plan.size() - 1
	_undo = {}
	if is_final:
		_ln["final_wrong"] = int(_ln["final_wrong"]) + 1
	return _reveal_now(stage, is_final)


func _reveal_now(stage: int, is_final: bool) -> Dictionary:
	if is_final:
		_ln["final_revealed"] = true
	var to: int = maxi(STAGE_FLOOR, stage - 1)
	to = mini(to, (_ln["plan"] as Array).size() - 1)
	_ln["stage"] = to
	_ln["fails"] = 0
	_ln["revealed"] = true
	_ln["answered"] = false
	return _ev("revealed", {"stage_from": stage, "dropped": to != stage, "from_final": is_final})


## 맨 끝 단계 결과 -> 평가 (1 Again, 2 Hard, 3 Good).
func _rating_of() -> int:
	if bool(_ln["final_revealed"]):
		return FSRS.Rating.AGAIN
	if int(_ln["final_wrong"]) > 0 or not bool(_ln["final_first_good"]):
		return FSRS.Rating.HARD
	return FSRS.Rating.GOOD


func _finish_line() -> Dictionary:
	var rating: int = _rating_of()
	_ln["rating"] = rating
	var counted: bool = not practice_only
	if not counted:
		_ln["done"] = true
		return _ev("line_done", {"counted": false, "rating": rating, "saved": false})
	var t: int = _t()
	var cand: Dictionary = memo.duplicate(true)
	var card: Dictionary = _apply_rating(cand, rating, t)
	var r: Dictionary = _commit(cand)
	if not bool(r["ok"]):
		_ln["pending"] = {"cand": cand, "rating": rating, "card": card}
		return _ev("save_failed", {"err": str(r["err"]), "rating": rating, "counted": true, "pending": true})
	return _complete_line(cand, rating, card, bool(r["saved"]))


## 후보 memo 에 줄 끝 평가를 적용한다. 새 줄은 카드를 만든다 (Good = GOOD 2번, Hard = GOOD 1번, Again = AGAIN 1번).
func _apply_rating(cand: Dictionary, rating: int, t: int) -> Dictionary:
	var key: String = str(_ln["key"])
	var lines: Dictionary = cand["lines"]
	var ent: Dictionary = lines[key] if lines.get(key, null) is Dictionary else {"stage": 0, "seen": 0, "tries": 0, "passes": 0}
	var old: Dictionary = ent["card"] if ent.get("card", null) is Dictionary else {}
	var card: Dictionary
	if old.is_empty():
		card = FSRS.new_card(t)
		match rating:
			FSRS.Rating.GOOD:
				card = FSRS.review(card, FSRS.Rating.GOOD, t)
				card = FSRS.review(card, FSRS.Rating.GOOD, t)
			FSRS.Rating.HARD:
				card = FSRS.review(card, FSRS.Rating.GOOD, t)
			_:
				card = FSRS.review(card, FSRS.Rating.AGAIN, t)
	else:
		## 시계가 거꾸로 가도 (now < last_review) 일정이 깨지지 않게 마지막 복습 시각 이전으로는 가지 않는다
		var t2: int = maxi(t, int(old.get("last_review", 0)))
		card = FSRS.review(old, rating, t2)
	ent["card"] = card
	ent["stage"] = 0
	ent["seen"] = t
	ent["tries"] = mini(MemoModel.MAX_COUNT, int(ent.get("tries", 0)) + int(_ln["tries"]))
	ent["passes"] = mini(MemoModel.MAX_COUNT, int(ent.get("passes", 0)) + int(_ln["passes"]))
	lines[key] = ent
	return card


func _complete_line(cand: Dictionary, rating: int, card: Dictionary, saved: bool) -> Dictionary:
	memo = cand
	_ln["done"] = true
	_ln["pending"] = {}
	_counted += 1
	if str(_ln["kind"]) == "new":
		_new_done += 1
	else:
		_review_done += 1
	match rating:
		FSRS.Rating.AGAIN:
			_ratings["again"] += 1
		FSRS.Rating.HARD:
			_ratings["hard"] += 1
		_:
			_ratings["good"] += 1
	return _ev("line_done", {"counted": true, "rating": rating, "saved": saved, "card": card.duplicate(), "pending": false})


## 줄 끝 저장이 실패한 줄을 같은 평가로 다시 저장한다. 성공하면 line_done, 실패하면 save_failed. 저장할 것이 없으면 ignored.
func retry_save() -> Dictionary:
	if _ln.is_empty() or (_ln["pending"] as Dictionary).is_empty():
		return _ignored("nothing_pending")
	var p: Dictionary = _ln["pending"]
	var r: Dictionary = _commit(p["cand"])
	if not bool(r["ok"]):
		return _ev("save_failed", {"err": str(r["err"]), "rating": int(p["rating"]), "counted": true, "pending": true})
	return _complete_line(p["cand"], int(p["rating"]), p["card"], bool(r["saved"]))


# ---------------------------------------------------------------- leaving / next

## [이 줄 나중에] / 화면을 떠남. 카드·통계는 건드리지 않는다. 새 줄이면 도달 단계(1 이상)만 memo 에 남기고 저장한다.
## 연습만·복습 줄·읽기 전용 memo 는 기록 변경 없음. 줄 끝 저장이 실패해 남은 줄이면 같은 저장을 다시 시도한다.
## -> {ok, saved, err}
func leave_line() -> Dictionary:
	if _ln.is_empty():
		return {"ok": true, "saved": false, "err": ""}
	if not (_ln["pending"] as Dictionary).is_empty():
		var rr: Dictionary = retry_save()
		return {"ok": str(rr["event"]) == "line_done", "saved": str(rr["event"]) == "line_done", "err": str(rr.get("err", ""))}
	if bool(_ln["done"]) or bool(_ln["left"]):
		return {"ok": true, "saved": false, "err": ""}
	_undo = {}
	_ln["left"] = true
	if practice_only or str(_ln["kind"]) != "new" or int(_ln["stage"]) < 1:
		return {"ok": true, "saved": false, "err": ""}
	var key: String = str(_ln["key"])
	var cand: Dictionary = memo.duplicate(true)
	var lines: Dictionary = cand["lines"]
	var ent: Dictionary = lines[key] if lines.get(key, null) is Dictionary else {"stage": 0, "seen": 0, "tries": 0, "passes": 0}
	if int(ent.get("stage", 0)) == int(_ln["stage"]) and not (ent.get("card", null) is Dictionary):
		return {"ok": true, "saved": false, "err": ""} ## 이미 그 단계로 저장돼 있다
	ent["stage"] = int(_ln["stage"])
	ent["seen"] = _t()
	lines[key] = ent
	var r: Dictionary = _commit(cand)
	if not bool(r["ok"]):
		_ln["left"] = false ## 상태 유지: 줄은 그대로, 호출한 쪽이 다시 시도할 수 있다
		return {"ok": false, "saved": false, "err": str(r["err"])}
	memo = cand
	return {"ok": true, "saved": bool(r["saved"]), "err": ""}


## 다음 줄로. 지금 줄이 끝났거나(done) 떠난(left) 뒤에만 넘어간다. 큐가 끝나면 finish() 를 부르고 false.
## 줄이 진행 중이거나 저장이 밀려 있으면 false (아무것도 바꾸지 않음).
func next_line() -> bool:
	if _queue.is_empty():
		finish()
		return false
	if _ln.is_empty():
		return false
	if not bool(_ln["done"]) and not bool(_ln["left"]):
		return false
	if _pos + 1 >= _queue.size():
		_ln = {}
		_pos = _queue.size()
		finish()
		return false
	_pos += 1
	_open_line()
	return true


## 판 끝: 한 줄이라도 기록한 판이면 stats(sessions +1, last)를 저장한다. 여러 번 불러도 한 번만 반영된다.
## 저장이 실패하면 finished 는 false 로 남고 오류를 돌려준다 (다시 부르면 재시도). -> {ok, saved, err}
func finish() -> Dictionary:
	if finished:
		return {"ok": true, "saved": false, "err": ""}
	if practice_only or _counted == 0:
		finished = true
		return {"ok": true, "saved": false, "err": ""}
	var cand: Dictionary = memo.duplicate(true)
	var st: Dictionary = cand["stats"]
	st["sessions"] = mini(MemoModel.MAX_COUNT, int(st.get("sessions", 0)) + 1)
	st["last"] = _t()
	cand["stats"] = st
	var r: Dictionary = _commit(cand)
	if not bool(r["ok"]):
		return {"ok": false, "saved": false, "err": str(r["err"])}
	memo = cand
	finished = true
	return {"ok": true, "saved": bool(r["saved"]), "err": ""}


## 저장 함수를 부른다. 저장 함수가 없으면 저장하지 않고 성공으로 친다 (saved:false).
func _commit(cand: Dictionary) -> Dictionary:
	if not _save.is_valid():
		last_error = ""
		return {"ok": true, "saved": false, "err": ""}
	var r: Variant = _save.call(_id, cand)
	var okv: bool = false
	var err: String = "save_failed"
	if r is bool:
		okv = r
	elif r is Dictionary:
		okv = (r as Dictionary).get("ok", false) is bool and bool((r as Dictionary).get("ok", false))
		var e: Variant = (r as Dictionary).get("err_code", (r as Dictionary).get("err", ""))
		if e is String and e != "":
			err = e
	if okv:
		saves += 1
		last_error = ""
		return {"ok": true, "saved": true, "err": ""}
	last_error = err
	return {"ok": false, "saved": false, "err": err}


# ---------------------------------------------------------------- summary

## 판 요약: 이번에 한 줄, 평가 개수, 곡 전체 "외운 줄 N/M", 다음 복습 시각.
## {queue_total, lines_done, new_done, review_done, again, hard, good, left, practice_only, finished,
##  memorized, total, learning, fresh, due, next_due (0 = 없음), next_due_in (초)}
func summary() -> Dictionary:
	var t: int = _t()
	var s: Dictionary = MemoModel.summary(song, memo, t)
	var nd: int = int(s["next_due"])
	var left: int = 0
	if not _queue.is_empty():
		left = maxi(0, _queue.size() - (_pos + 1)) if _pos >= 0 and _pos < _queue.size() else 0
		if not _ln.is_empty() and not bool(_ln["done"]) and not bool(_ln["left"]):
			left += 1
	return {
		"queue_total": _queue.size(), "lines_done": _counted, "new_done": _new_done, "review_done": _review_done,
		"again": int(_ratings["again"]), "hard": int(_ratings["hard"]), "good": int(_ratings["good"]),
		"left": left, "practice_only": practice_only, "finished": finished,
		"memorized": int(s["memorized"]), "total": int(s["total"]), "learning": int(s["learning"]),
		"fresh": int(s["fresh"]), "due": int(s["due"]), "next_due": nd,
		"next_due_in": maxi(0, nd - t) if nd > 0 else 0,
	}
