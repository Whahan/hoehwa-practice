class_name DayPlan
extends RefCounted
## v2.0 "today's 45 minutes" (design docs/v200_design.md §6.1, §6.2, §10.5, §14 E3). A PURE function: the result depends only on
## the snapshot passed in. No files, no nodes, no clock, no Store; the input dictionary is never changed. Bad values never raise.
##
##   var plan := DayPlan.today(snapshot)
##
## snapshot keys (all optional; missing / wrong type = the default in brackets; numbers may be int, whole float or integer text):
##   mode            "course" (anything else = "legacy": no blocks, nothing to do)
##   w, d            the cell to do (1, 1)           clamped to 1..72 / 1..7
##   due             due review cards (0)
##   away_days       days since the last study day (0)
##   blocks_done     {"new","review","listen","speak": bool} (all false)
##   check_pending   a passed-over week has no weekly check (false) -- see check_pending_days
##   check_pending_days  days since that week was left (0)
##   rp_prev         the previous plan day was "review first" (false)     CourseStore.review_state().prev
##   rp_streak       days in a row, ending yesterday, that were "review first" (0)   CourseStore.review_state().streak
##   elapsed_days    calendar days since the course was started (0)       CourseStore.elapsed_days()
##   finished        week 72 is done (false)
##   reopen_done     the reopen of the current break was already applied (false)   CourseStore.reopen_applied()
## Rules (U1..U7 of §6.2):
##   recap          away_days >= 7: the first day back is a recap day ("복귀 점검" instead of the new content, review first minutes).
##                  away_days >= 21 also lists `reopen` = the two weeks before w (CourseStore.reopen_weeks) to do again.
##   review first   due >= 40, kept while due > 25 once it was on (rp_prev), but never the 4th day in a row (rp_streak >= 3).
##                  Minutes new 15 (half amount: block.half = true) + review 20 + listen 5 + speak 5. The recap day uses the same minutes.
##   no cards due   the review minutes go to listening (the sum stays 45); the review block is listed with state "skip".
##   late_weeks     expected week by the calendar (7 days a week, one spare week after weeks 16 32 48 60 68 72) minus w, at least 0.
##   ask_check      check_pending for CHECK_ASK_DAYS days or more: the home asks once more.
## Result: {"mode", "kind", "w", "d", "blocks": [{"id","min","title","sub","state","target", new block: "half"}], "total_min",
##   "done_min", "late_weeks", "review_priority", "recap", "reopen", "ask_check", "finished", "start_label", "due"}.
##   block.state: "done" | "current" (first block left) | "todo" | "skip". Numbers in texts come from CourseModel.progress_label only.

const REVIEW_ON := 40 ## due cards from which "review first" starts
const REVIEW_OFF := 25 ## ... and at or below which it ends
const MAX_STREAK := 3 ## 3 days in a row, then the 4th day is normal
const RECAP_AWAY := 7
const REOPEN_AWAY := 21
const CHECK_ASK_DAYS := 2 ## design §14 E3-4 says 2 days ("이틀 뒤"), §6.2 U5 says 3: the table of the acceptance criteria wins
const REVIEW_TARGET_MAX := 15
const LISTEN_QUESTIONS := 8
const SPEAK_SENTENCES := 5
const CHECK_QUESTIONS := 12
const RECAP_QUESTIONS := 6
const HALF_WORDS := 3
const RESERVE_AFTER := [16, 32, 48, 60, 68, 72] ## spare week after each stage end (U7)
const BLOCK_IDS := ["new", "review", "listen", "speak"]
const PRIORITY_MINUTES := {"new": 15, "review": 20, "listen": 5, "speak": 5}
const NEW_TITLES := {"new": "새 내용", "speak": "말하기 날", "check": "주간 점검", "free": "자유 시간", "recap": "복귀 점검"}
const MAX_COUNT := 999999


static func today(s: Variant) -> Dictionary:
	var src: Dictionary = s if s is Dictionary else {}
	var m: Variant = src.get("mode", "")
	if not (m is String) or m != "course":
		return {"mode": "legacy", "kind": "", "w": 0, "d": 0, "blocks": [], "total_min": 0, "done_min": 0, "late_weeks": 0,
			"review_priority": false, "recap": false, "reopen": [], "ask_check": false, "finished": false, "start_label": "", "due": 0}
	var w: int = _int(src.get("w", 1), 1, CourseModel.WEEKS, 1)
	var d: int = _int(src.get("d", 1), 1, CourseModel.DAYS, 1)
	var due: int = _int(src.get("due", 0), 0, MAX_COUNT, 0)
	var away: int = _int(src.get("away_days", 0), 0, MAX_COUNT, 0)
	var streak: int = _int(src.get("rp_streak", 0), 0, 99, 0)
	var rp_prev: bool = _bool(src.get("rp_prev", false))
	var finished: bool = _bool(src.get("finished", false))
	var done: Dictionary = src.get("blocks_done", {}) if src.get("blocks_done", null) is Dictionary else {}

	var recap: bool = away >= RECAP_AWAY and not finished
	var rp := false
	if not recap:
		rp = due >= REVIEW_ON or (rp_prev and due > REVIEW_OFF)
		if rp and streak >= MAX_STREAK:
			rp = false
	var kind: String = CourseModel.day_kind(w, d)
	if finished:
		kind = "free"
	if recap:
		kind = "recap"
	var mins: Dictionary = CourseModel.unit_minutes(w, d)
	if recap or rp:
		mins = PRIORITY_MINUTES.duplicate()
	if due <= 0:
		mins["listen"] = int(mins["listen"]) + int(mins["review"])
		mins["review"] = 0
	var blocks: Array = []
	var total := 0
	var done_min := 0
	var current_set := false
	for id in BLOCK_IDS:
		var b: Dictionary = _block(id, int(mins[id]), kind, w, d, due, recap or rp)
		var is_done: bool = _bool(done.get(id, false))
		if is_done:
			b["state"] = "done"
			done_min += int(b["min"])
		elif id == "review" and due <= 0:
			b["state"] = "skip"
		elif not current_set:
			b["state"] = "current"
			current_set = true
		else:
			b["state"] = "todo"
		total += int(b["min"])
		blocks.append(b)
	var reopen: Array = []
	if away >= REOPEN_AWAY and not finished and not _bool(src.get("reopen_done", false)):
		for x in [w - 2, w - 1]:
			if x >= 1:
				reopen.append(x)
	var late: int = 0 if finished else maxi(expected_week(_int(src.get("elapsed_days", 0), 0, MAX_COUNT, 0)) - w, 0)
	var all_done := not current_set
	return {"mode": "course", "kind": kind, "w": w, "d": d, "blocks": blocks, "total_min": total, "done_min": done_min,
		"late_weeks": late, "review_priority": rp, "recap": recap, "reopen": reopen,
		"ask_check": _bool(src.get("check_pending", false)) and _int(src.get("check_pending_days", 0), 0, MAX_COUNT, 0) >= CHECK_ASK_DAYS,
		"finished": finished, "start_label": "더 연습하기" if all_done else "오늘 %d분 시작" % total, "due": due}


## The course week the calendar expects `elapsed_days` after the start: 7 days per week, and one spare week after each stage
## end (RESERVE_AFTER). 1..72.
static func expected_week(elapsed_days: Variant) -> int:
	var cal: int = _int(elapsed_days, 0, MAX_COUNT, 0) / 7 + 1
	var best := 1
	for wi in range(1, CourseModel.WEEKS + 1):
		var spare := 0
		for r in RESERVE_AFTER:
			if int(r) < wi:
				spare += 1
		if wi + spare <= cal:
			best = wi
	return best


static func _block(id: String, minutes: int, kind: String, w: int, d: int, due: int, shortened: bool) -> Dictionary:
	var b: Dictionary = {"id": id, "min": minutes, "title": "", "sub": "", "state": "todo", "target": 1}
	match id:
		"new":
			b["title"] = str(NEW_TITLES.get(kind, "새 내용"))
			b["target"] = 1
			match kind:
				"check":
					b["sub"] = CourseModel.progress_label("questions", CHECK_QUESTIONS, 0)
				"recap":
					b["sub"] = CourseModel.progress_label("questions", RECAP_QUESTIONS, 0)
				"free":
					b["sub"] = "하고 싶은 것을 골라요"
				"speak":
					b["sub"] = "%d주 %d일 · 말하기" % [w, d]
				_:
					b["sub"] = "%d주 %d일" % [w, d]
			if shortened and kind == "new":
				b["half"] = true
				b["sub"] = "%s · %s까지" % [b["sub"], CourseModel.progress_label("words", HALF_WORDS, 0)]
			elif shortened:
				b["half"] = true
			else:
				b["half"] = false
		"review":
			b["title"] = "복습"
			b["target"] = mini(due, REVIEW_TARGET_MAX)
			b["sub"] = CourseModel.progress_label("cards", int(b["target"]), 0) if due > 0 else "복습할 카드가 없어요"
		"listen":
			b["title"] = "듣기"
			b["target"] = LISTEN_QUESTIONS
			b["sub"] = CourseModel.progress_label("questions", LISTEN_QUESTIONS, 0)
		"speak":
			b["title"] = "말하기"
			b["target"] = SPEAK_SENTENCES
			b["sub"] = CourseModel.progress_label("sentences", SPEAK_SENTENCES, 0)
	return b


static func _bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	return false


## Integer of an int / finite float (truncated) / integer text, clamped to lo..hi; def for anything else.
static func _int(v: Variant, lo: int, hi: int, def: int) -> int:
	var i: int
	if v is int:
		i = v
	elif v is float:
		var f: float = v
		if is_nan(f) or is_inf(f):
			return def
		i = int(clampf(f, -1.0e9, 1.0e9))
	elif v is String and (v as String).is_valid_int():
		i = clampi((v as String).to_int(), -1000000000, 1000000000)
	else:
		return def
	return clampi(i, lo, hi)
