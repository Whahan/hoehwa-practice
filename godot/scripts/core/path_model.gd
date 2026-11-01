class_name PathModel
extends RefCounted
## 레슨 길(12개월 x 4주 = 48칸)의 순수 계산. 화면·노드 없음 (docs/home_menu_design.md §8.3, §9.2).
##
## 칸 번호 i = (n-1)*4 + (w-1), n = 1..12 (개월차), w = 1..4 (주). 키 문자열 "3-2".
## 한 칸 완료 = 이 기기에서 센 레슨 횟수 >= NODE_GOAL **또는** 그 주 체크(Store.check_key(lang, n, "w", w-1))가 켜짐.
## 상태: done / current / past(건너뜀: current 앞 미완료) / open(current 뒤 LOOKAHEAD 칸까지 미완료) / locked(더 먼 미완료).
## 잠금은 부드럽다: 화면이 locked 노드를 확인 시트 뒤에 연다(여기서는 상태만 계산한다).

const MONTHS := 12
const WEEKS := 4
const CELLS := 48
const NODE_GOAL := 5 ## lessons that finish one cell
const LOOKAHEAD := 2 ## unfinished cells after `current` that stay open

const S_DONE := "done"
const S_CURRENT := "current"
const S_OPEN := "open"
const S_PAST := "past"
const S_LOCKED := "locked"


## Cell index of month n (1..12) week w (1..4); -1 when out of range.
static func index_of(n: int, w: int) -> int:
	if n < 1 or n > MONTHS or w < 1 or w > WEEKS:
		return -1
	return (n - 1) * WEEKS + (w - 1)


## [n, w] of cell index i; [] when i is outside 0..47.
static func cell_of(i: int) -> Array:
	if i < 0 or i >= CELLS:
		return []
	return [i / WEEKS + 1, i % WEEKS + 1]


## "3-2"; "" when n / w are out of range.
static func key_of(n: int, w: int) -> String:
	if index_of(n, w) < 0:
		return ""
	return "%d-%d" % [n, w]


static func _flag(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	return false


## First unfinished cell at or after `from` (cells before `from` are not looked at); -1 when there is none.
static func _first_open(flags: Array, from: int) -> int:
	for i in range(maxi(from, 0), CELLS):
		if not flags[i]:
			return i
	return -1


## States of all 48 cells.
##   done: bool per cell (shorter than 48: missing = false, longer: the rest is ignored).
##   cal_idx: calendar position, clamped to 0..47. last_idx: cell of the last finished lesson; -1 or outside 0..47 = no record.
## current: with a record -> that cell if still unfinished, else the next unfinished one after it, else the first unfinished one;
## without -> the first unfinished cell at or after cal_idx (else the first unfinished one). All 48 done -> finished, current 47.
## Returns {"states": Array[String] (48), "current": int, "finished": bool, "done_count": int}.
static func states(done: Array, cal_idx: int, last_idx: int, lookahead: int = LOOKAHEAD) -> Dictionary:
	var flags: Array = []
	var count := 0
	for i in CELLS:
		var f: bool = _flag(done[i]) if i < done.size() else false
		flags.append(f)
		if f:
			count += 1
	var finished: bool = count == CELLS
	var cur: int = CELLS - 1
	if not finished:
		if last_idx >= 0 and last_idx < CELLS:
			if not flags[last_idx]:
				cur = last_idx
			else:
				cur = _first_open(flags, last_idx + 1)
		else:
			cur = _first_open(flags, clampi(cal_idx, 0, CELLS - 1))
		if cur < 0:
			cur = _first_open(flags, 0)
	var look: int = maxi(lookahead, 0)
	var out: Array = []
	for i in CELLS:
		var s: String
		if flags[i]:
			s = S_DONE
		elif i == cur:
			s = S_CURRENT
		elif i < cur:
			s = S_PAST
		elif i <= cur + look:
			s = S_OPEN
		else:
			s = S_LOCKED
		out.append(s)
	return {"states": out, "current": cur, "finished": finished, "done_count": count}


## 48 done flags of `lang` from the log (lessons counted on this device) and the weekly checks (synced). Reads only.
static func done_flags(lang: String) -> Array:
	var out: Array = []
	for i in CELLS:
		var c: Array = cell_of(i)
		var n: int = c[0]
		var w: int = c[1]
		out.append(StudyLog.path_done(lang, n, w) >= NODE_GOAL or Store.is_checked(Store.check_key(lang, n, "w", w - 1)))
	return out


## Calendar position as a cell index: before the start date -> 0, after the year -> 47, else the current month / week.
static func calendar_index() -> int:
	var pos: Dictionary = Plan.position(Store.start_iso(), StudyLog.today())
	var phase: String = str(pos.get("phase", "on"))
	if phase == "before":
		return 0
	if phase == "after":
		return CELLS - 1
	return maxi(index_of(int(pos.get("n", 1)), int(pos.get("w", 1))), 0)


## The "you are here" cell of `lang`: {"n", "w", "i", "done": lessons counted there, "goal": NODE_GOAL, "finished": bool}.
static func current_cell(lang: String) -> Dictionary:
	var flags: Array = done_flags(lang)
	var last: Array = StudyLog.path_last(lang)
	var last_idx: int = index_of(int(last[0]), int(last[1])) if last.size() == 2 else -1
	var st: Dictionary = states(flags, calendar_index(), last_idx)
	var i: int = int(st["current"])
	var c: Array = cell_of(i)
	return {
		"n": c[0], "w": c[1], "i": i,
		"done": StudyLog.path_done(lang, c[0], c[1]),
		"goal": NODE_GOAL,
		"finished": bool(st["finished"]),
	}
