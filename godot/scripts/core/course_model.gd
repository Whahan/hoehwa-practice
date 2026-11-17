class_name CourseModel
extends RefCounted
## Pure calculation for the v2.0 English course: 72 weeks = 18 blocks x 4 weeks, 7 days per week, 7 stages.
## No nodes, no files. Design docs/v200_design.md §2, §4, §6.1, §10.5, §14 E1.
##
## Address: block n (1..18; n=1 is the "0단계" intro) and week-in-block k (1..4) <-> week w = (n-1)*4 + k (1..72).
## Day d = 1..7 (D1~D4 new content, D5 speaking, D6 check, D7 free). Order number o = w*10 + d (design §3.3).
##
## Bad input never raises: every argument is a Variant. An index that is not an integer in range (null, text, NaN, a
## week 0 or 73, ...) gives the "nothing" value of the return type: -1 / {} / [] / "". Whole floats and integer
## strings are accepted as integers. `states` and `progress_label` clamp counts instead (documented there).

const WEEKS := 72
const BLOCKS := 18
const DAYS := 7
const WEEKS_PER_BLOCK := 4
const LOOKAHEAD := 2 ## unfinished weeks after `current` that stay open (soft lock, like PathModel)
const MAX_SHOWN := 9999 ## no label ever shows a number longer than 4 digits

const S_DONE := "done"
const S_CURRENT := "current"
const S_OPEN := "open"
const S_PAST := "past"
const S_LOCKED := "locked"

const STAGE_TITLES := ["입문", "기초 문장", "생활 말하기", "도착·정착", "일 찾기", "일터 영어", "종합·출발"]
const STAGE_FIRST_WEEK := [1, 5, 17, 33, 49, 61, 69]
## Minutes per day block {new, review, listen, speak} (sum 45) by stage 0..6 (design §6.1).
const MINUTES := [
	{"new": 18, "review": 5, "listen": 12, "speak": 10},
	{"new": 15, "review": 10, "listen": 8, "speak": 12},
	{"new": 15, "review": 10, "listen": 8, "speak": 12},
	{"new": 12, "review": 12, "listen": 8, "speak": 13},
	{"new": 12, "review": 12, "listen": 8, "speak": 13},
	{"new": 10, "review": 10, "listen": 10, "speak": 15},
	{"new": 10, "review": 10, "listen": 10, "speak": 15},
]
const DAY_KINDS := ["new", "new", "new", "new", "speak", "check", "free"]
## Week from which each speaking-ladder rung opens (design §4).
const OPEN_SUBSTITUTE := 2
const OPEN_SCRIPT := 8
const OPEN_MISSION_SCRIPT := 13
const OPEN_MISSION_AI := 25
const OPEN_FREE_GUIDED := 17
const OPEN_FREE_FREE := 33
const OPEN_FREE_OPEN := 57
## Unit of each progress kind: kind -> [label before, label after].
const PROGRESS_KINDS := {
	"words": ["단어 ", "개"], "patterns": ["문형 ", "개"], "sentences": ["문장 ", "개"], "questions": ["문제 ", "개"],
	"cards": ["카드 ", "장"], "days": ["", "일"], "weeks": ["", "주"], "minutes": ["", "분"], "blocks": ["블록 ", "개"],
}

## Test hook: the script that CourseStore (E3) lives in. Looked up at call time, never referenced by name.
static var store_script_path: String = "res://scripts/core/course_store.gd"


# ---------------------------------------------------------------- addresses

static func week_of(n: Variant, k: Variant) -> int:
	var bn: int = _idx(n, BLOCKS)
	var kk: int = _idx(k, WEEKS_PER_BLOCK)
	if bn < 0 or kk < 0:
		return -1
	return (bn - 1) * WEEKS_PER_BLOCK + kk


static func block_of(w: Variant) -> int:
	var i: int = _idx(w, WEEKS)
	return -1 if i < 0 else (i - 1) / WEEKS_PER_BLOCK + 1


static func k_of(w: Variant) -> int:
	var i: int = _idx(w, WEEKS)
	return -1 if i < 0 else (i - 1) % WEEKS_PER_BLOCK + 1


## o = w*10 + d; -1 when w (1..72) or d (1..7) is invalid.
static func order_of(w: Variant, d: Variant) -> int:
	var wi: int = _idx(w, WEEKS)
	var di: int = _idx(d, DAYS)
	if wi < 0 or di < 0:
		return -1
	return wi * 10 + di


# ---------------------------------------------------------------- stages

## 0..6: S0 1~4, S1 5~16, S2 17~32, S3 33~48, S4 49~60, S5 61~68, S6 69~72. -1 for an invalid week.
static func stage_of_week(w: Variant) -> int:
	var wi: int = _idx(w, WEEKS)
	if wi < 0:
		return -1
	var s := 0
	for i in STAGE_FIRST_WEEK.size():
		if wi >= int(STAGE_FIRST_WEEK[i]):
			s = i
	return s


## Stage numbering of the old 12-month path / chat / missions: 1~16 -> 1, 17~36 -> 2, 37~56 -> 3, 57~72 -> 4.
static func legacy_stage(w: Variant) -> int:
	var wi: int = _idx(w, WEEKS)
	if wi < 0:
		return -1
	if wi <= 16:
		return 1
	return mini((wi - 17) / 20 + 2, 4)


## [month 1..12, week 1..4] of the old path that matches the course week: the first cell of its legacy stage
## (1~16 -> [1,1], 17~36 -> [4,1], 37~56 -> [7,1], 57~72 -> [10,1]). [] for an invalid week.
static func legacy_cell(w: Variant) -> Array:
	var s: int = legacy_stage(w)
	if s < 0:
		return []
	return [(s - 1) * 3 + 1, 1]


static func stage_title(s: Variant) -> String:
	var i: int = _int_or_neg(s)
	if i < 0 or i >= STAGE_TITLES.size():
		return ""
	return str(STAGE_TITLES[i])


## "0단계 입문" for block 1, "N개월차" (N = n-1) for blocks 2..18, "" for an invalid block.
static func block_label(n: Variant) -> String:
	var bn: int = _idx(n, BLOCKS)
	if bn < 0:
		return ""
	if bn == 1:
		return "0단계 입문"
	return "%d개월차" % (bn - 1)


# ---------------------------------------------------------------- the day

## Speaking ladder of week w: {repeat, substitute, script: bool, mission: "none"|"script"|"ai", free: "none"|"guided"|"free"|"open"}.
static func ladder(w: Variant) -> Dictionary:
	var wi: int = _idx(w, WEEKS)
	if wi < 0:
		return {}
	var mission := "none"
	if wi >= OPEN_MISSION_AI:
		mission = "ai"
	elif wi >= OPEN_MISSION_SCRIPT:
		mission = "script"
	var free := "none"
	if wi >= OPEN_FREE_OPEN:
		free = "open"
	elif wi >= OPEN_FREE_FREE:
		free = "free"
	elif wi >= OPEN_FREE_GUIDED:
		free = "guided"
	return {"repeat": true, "substitute": wi >= OPEN_SUBSTITUTE, "script": wi >= OPEN_SCRIPT, "mission": mission, "free": free}


## {new, review, listen, speak} minutes of the day; the four always add up to 45. {} for an invalid (w, d).
static func unit_minutes(w: Variant, d: Variant) -> Dictionary:
	var s: int = stage_of_week(w)
	if s < 0 or _idx(d, DAYS) < 0:
		return {}
	return (MINUTES[s] as Dictionary).duplicate()


## "new" (D1~D4), "speak" (D5), "check" (D6), "free" (D7); "" for an invalid (w, d).
static func day_kind(w: Variant, d: Variant) -> String:
	var di: int = _idx(d, DAYS)
	if _idx(w, WEEKS) < 0 or di < 0:
		return ""
	return str(DAY_KINDS[di - 1])


## The speaking block of the day (design §4): Array of {"rung", "min"}; the minutes add up to unit_minutes().speak.
## rung: "L1" repeat, "L2" substitute, "L3" script dialogue, "L4" mission, "L5" free talk, "check" (D6), "choice" (D7).
##   D1~D3: L1 5 + L2 (rest) once L2 is open, else L1.   D4: L3 once open, else as D1~D3.
##   D5: L4 and/or L5 when open (both: L4 gets the larger half), else L3 when open, else as D1~D3.
static func speak_plan(w: Variant, d: Variant) -> Array:
	var wi: int = _idx(w, WEEKS)
	var di: int = _idx(d, DAYS)
	if wi < 0 or di < 0:
		return []
	var total: int = int(unit_minutes(wi, di)["speak"])
	var lad: Dictionary = ladder(wi)
	var basic: Array = [{"rung": "L1", "min": total}]
	if bool(lad["substitute"]):
		basic = [{"rung": "L1", "min": 5}, {"rung": "L2", "min": total - 5}]
	match di:
		1, 2, 3:
			return basic
		4:
			return [{"rung": "L3", "min": total}] if bool(lad["script"]) else basic
		5:
			var open: Array = []
			if str(lad["mission"]) != "none":
				open.append("L4")
			if str(lad["free"]) != "none":
				open.append("L5")
			if open.size() == 2:
				var first: int = (total + 1) / 2
				return [{"rung": "L4", "min": first}, {"rung": "L5", "min": total - first}]
			if open.size() == 1:
				return [{"rung": open[0], "min": total}]
			return [{"rung": "L3", "min": total}] if bool(lad["script"]) else basic
		6:
			return [{"rung": "check", "min": total}]
	return [{"rung": "choice", "min": total}]


# ---------------------------------------------------------------- the road (72 cells)

## States of the 72 weeks (soft lock like PathModel.states).
##   done: flag per week, index w-1 (bool or int; shorter = missing = false, longer: rest ignored, anything else = false).
##   cur_w: the week the learner is at (1..72) or anything else = no record.
##   avail: how many weeks have content (clamped 0..72). Weeks after it are always "locked" and marked in `soon`.
##   look: unfinished weeks after `current` that stay "open" (default 2, negative = 0).
## current (0-based index like PathModel, -1 when avail is 0): cur_w if available and unfinished, else the next unfinished
## available week after it, else the first unfinished available week; when every available week is done: the last available one.
## Returns {"states": Array[String] (72), "current": int, "finished": bool (all 72 done), "done_count": int,
## "soon": Array[bool] (72, true after avail), "avail": int, "avail_done": bool (every available week done)}.
static func states(done: Variant, cur_w: Variant, avail: Variant, look: Variant = LOOKAHEAD) -> Dictionary:
	var arr: Array = done if done is Array else []
	var av: int = clampi(_int_or_neg(avail), 0, WEEKS)
	var lk: int = maxi(_int_or_neg(look) if (look is int or look is float) else LOOKAHEAD, 0)
	var flags: Array = []
	var count := 0
	var all_done := true
	for i in WEEKS:
		var f: bool = _flag(arr[i]) if i < arr.size() else false
		flags.append(f)
		if i < av and f:
			count += 1
		if not f:
			all_done = false
	var avail_done: bool = av > 0 and count == av
	var cur := -1
	if av > 0:
		var cw: int = _idx(cur_w, WEEKS)
		var from := 0
		if cw >= 1 and cw <= av:
			if not flags[cw - 1]:
				cur = cw - 1
			else:
				from = cw ## index of the week after cur_w
		if cur < 0:
			cur = _first_open(flags, from, av)
			if cur < 0:
				cur = _first_open(flags, 0, av)
			if cur < 0:
				cur = av - 1
	var out: Array = []
	var soon: Array = []
	for i in WEEKS:
		var s: String
		if i >= av:
			s = S_LOCKED
		elif flags[i]:
			s = S_DONE
		elif i == cur:
			s = S_CURRENT
		elif i < cur:
			s = S_PAST
		elif i <= cur + lk:
			s = S_OPEN
		else:
			s = S_LOCKED
		out.append(s)
		soon.append(i >= av)
	return {"states": out, "current": cur, "finished": all_done and av == WEEKS, "done_count": count,
		"soon": soon, "avail": av, "avail_done": avail_done}


# ---------------------------------------------------------------- texts the screens show

## THE one place that builds "value/target" progress text (REVIEW.md). kind: words patterns sentences questions cards
## days weeks minutes blocks (e.g. "단어 12/25개", "20/45분"), "percent" ("80%": value only), anything else: plain "12/25".
## Counts are clamped to 0..9999 (never a 5-digit number); a value above a positive target is shown as the target;
## without a positive target only the value is shown ("단어 5개", "5일", "5").
static func progress_label(kind: Variant, value: Variant, target: Variant) -> String:
	var v: int = clampi(_int_or_neg(value), 0, MAX_SHOWN)
	var t: int = clampi(_int_or_neg(target), 0, MAX_SHOWN)
	if t > 0 and v > t:
		v = t
	var k: String = kind if kind is String else ""
	if k == "percent":
		return str(mini(v, 100)) + "%"
	var pair: Array = PROGRESS_KINDS.get(k, ["", ""])
	if t <= 0:  # no target (0 or less, or not a number): the value alone, never "5/0"
		return str(pair[0]) + str(v) + str(pair[1])
	return str(pair[0]) + str(v) + "/" + str(t) + str(pair[1])


## Study time for people: "34시간 17분", "1시간", "12분", "1분 미만" (1..59 s), "0분" (0, negative or not a number).
## Never shows seconds and never more than 4 digits (capped at 9999시간 59분).
static func fmt_minutes(seconds: Variant) -> String:
	var s: int = 0
	if seconds is int:
		s = seconds
	elif seconds is float:
		var f: float = seconds
		s = 0 if (is_nan(f) or is_inf(f)) else int(clampf(f, 0.0, 1.0e9))
	if s <= 0:
		return "0분"
	s = mini(s, MAX_SHOWN * 3600 + 3599)
	if s < 60:
		return "1분 미만"
	var total_min: int = s / 60
	var h: int = total_min / 60
	var m: int = total_min % 60
	if h == 0:
		return "%d분" % m
	if m == 0:
		return "%d시간" % h
	return "%d시간 %d분" % [h, m]


# ---------------------------------------------------------------- where the learner is (course mode or the calendar)

## Stage 1..4 the old features (chat, missions, practice) use. English in course mode -> legacy_stage(course week);
## anything else (and Japanese always) -> Plan.stage_of(Store.position().n). Works while CourseStore does not exist yet.
static func stage_for(lang: Variant) -> int:
	return int(pos_for(lang)["stage"])


## {"n", "w", "stage", "cw", "cd"}. Course mode (English): n,w = legacy_cell(course week), stage = legacy_stage, cw/cd = course
## week/day. Otherwise the calendar: n,w = Store.position(), stage = Plan.stage_of(n), cw = cd = 0.
static func pos_for(lang: Variant) -> Dictionary:
	if lang is String and lang == "en":
		var p: Dictionary = _course_pos()
		if not p.is_empty():
			var cw: int = int(p["w"])
			var cell: Array = legacy_cell(cw)
			return {"n": int(cell[0]), "w": int(cell[1]), "stage": legacy_stage(cw), "cw": cw, "cd": int(p["d"])}
	var cal: Dictionary = Store.position()
	var n: int = clampi(_int_or_neg(cal.get("n", 1)), 1, 12)
	var wk: int = clampi(_int_or_neg(cal.get("w", 1)), 1, 4)
	return {"n": n, "w": wk, "stage": Plan.stage_of(n), "cw": 0, "cd": 0}


## {"w", "d"} when CourseStore exists, is in course mode and gives a sane position; {} otherwise (never raises).
static func _course_pos() -> Dictionary:
	if not ResourceLoader.exists(store_script_path):
		return {}
	var sc: Variant = load(store_script_path)
	if not (sc is GDScript) or not (sc as GDScript).can_instantiate():
		return {}
	var script: GDScript = sc
	if not script.has_method("mode") or not script.has_method("pos"):
		return {}
	if str(script.call("mode")) != "course":
		return {}
	var p: Variant = script.call("pos")
	if not (p is Dictionary):
		return {}
	var w: int = _idx((p as Dictionary).get("w", null), WEEKS)
	var d: int = _idx((p as Dictionary).get("d", null), DAYS)
	if w < 0:
		return {}
	return {"w": w, "d": d if d >= 1 else 1}


# ---------------------------------------------------------------- helpers

## `v` as an integer in 1..max, else -1 (null, text, NaN, out of range).
static func _idx(v: Variant, max_v: int) -> int:
	var i: int = _int_or_neg(v)
	return i if (i >= 1 and i <= max_v) else -1


## Integer value of an int / finite float (truncated) / integer string; -1 for everything else.
## (A value below 0 is also -1, so callers only ever see "valid >= 0" or "invalid".)
static func _int_or_neg(v: Variant) -> int:
	if v is int:
		return maxi(v, -1)
	if v is float:
		var f: float = v
		if is_nan(f) or is_inf(f):
			return -1
		return int(clampf(f, -1.0, 1.0e9))
	if v is String and (v as String).is_valid_int():
		return clampi((v as String).to_int(), -1, 1000000000)
	return -1


static func _flag(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return v != 0.0
	return false


## First unfinished week index in [from, limit); -1 when there is none.
static func _first_open(flags: Array, from: int, limit: int) -> int:
	for i in range(maxi(from, 0), mini(limit, WEEKS)):
		if not flags[i]:
			return i
	return -1
