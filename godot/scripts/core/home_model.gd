class_name HomeModel
extends RefCounted
## 홈 화면이 무엇을 보여 줄지 정하는 순수 계산(노드·파일·시계 없음). 입력은 "스냅샷" 사전 하나.
## 키가 없거나 틀린 값이어도 에러 없이 기본값으로 계산한다. 설계: docs/home_menu_design.md §8.1, §8.2, §8.4, §9.3.
##
## 스냅샷 `s`:
##   lang "en"|"ja", phase "before"|"on"|"after", before_days, lesson_today, due, reviews_today, song_due, song_count,
##   path {n, w, done, goal, finished}, goal_min, sec_today, streak, tokens, studied_today, has_data, first_run,
##   hour(현지 0-23), now(unix 초), resume {view, lang, at} 또는 {}
## target = {"view": String, "args": Dictionary}. 레슨은 args 에 lang/n/w/start, 나머지는 lang 만.
##
## v2.0 코스 모드(영어): 스냅샷에 `course` 키가 있으면(HomeParts.snapshot 이 CourseStore 를 읽어 채운다) 홈의 "오늘 할 일"은
## DayPlan.today() 의 블록 4개(새 내용·복습·듣기·말하기)가 된다. `course` = {mode "course", w, d, blocks_done {new,review,listen,speak},
## away_days, due, check_pending, check_pending_days, rp_prev, rp_streak, elapsed_days, finished, reopen_done, late_weeks, fallback}.
## fallback "data"|"file" = 코스 데이터·진도 파일을 못 읽음 -> 예전 할 일 줄 + 안내 1줄. `course_offer` = [새 코스로 시작] 카드를 보일지.
## 코스 블록 줄의 target = {"view": "course", "args": {lang, kind, w, d, block, half}} (TodayView 가 CoursePlayer 를 연다), 복습 줄은 {"view": "review"}.
## 값이 없거나 이상하면 코스 없음으로 처리한다(에러 0).

const REVIEW_FIRST_DUE := 20 ## 복습이 이만큼 밀리면 복습 줄이 레슨 줄 앞에 온다
const RESUME_DAYS := 7 ## 이어하기는 마지막 활동이 이 안일 때만
const EVENING_HOUR := 18 ## 이 시각부터 "오늘 아직이에요" 문구
const FUTURE_SLACK_SEC := 86400 ## 시계가 이만큼 넘게 앞서 있으면 기록을 믿지 않는다
const RESUME_VIEWS := ["lesson", "review", "talk", "practice", "reading", "song"]
const LANGS := ["en", "ja"]
const MAX_INT := 1000000000
const COURSE_BLOCKS := ["new", "review", "listen", "speak"]
const COURSE_FALLBACKS := ["", "data", "file"]
const COURSE_UNIT_KIND := {"new": "new", "speak": "speak", "check": "check", "free": "listen", "recap": "recap"} ## DayPlan kind -> CoursePlayer kind. D7(자유 날)에는 새 내용 문제가 없다: E5 레슨 탭처럼 kind "listen" + block "new" 로 연다(그 칸과 주를 끝낸다)
const TEXT_FALLBACK := {"data": "코스 데이터를 읽지 못해 예전 할 일을 보여 드려요.", "file": "코스 진도 파일을 읽지 못해 예전 할 일을 보여 드려요."}
const TEXT_DEVICE := "코스 진도는 이 기기에만 저장돼요."


# ---------------------------------------------------------------- input cleaning

static func _int(s: Dictionary, key: String, lo: int, hi: int, dflt: int) -> int:
	var v: Variant = s.get(key, dflt)
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return clampi(int(clampf(v, float(lo), float(hi))), lo, hi)
	return dflt


## 길 한 칸의 목표 레슨 수: 1 미만이거나 숫자가 아니면 기본 5.
static func _goal(p: Dictionary) -> int:
	var g: int = _int(p, "goal", 0, 9999, 5)
	return g if g >= 1 else 5


static func _bool(s: Dictionary, key: String) -> bool:
	var v: Variant = s.get(key, false)
	return v is bool and v


## 스냅샷을 기본값으로 채우고 값을 범위 안으로 자른다. 입력 사전은 바꾸지 않는다.
static func _norm(s: Variant) -> Dictionary:
	var src: Dictionary = s if s is Dictionary else {}
	var lang: String = str(src.get("lang", "en"))
	if not (lang in LANGS):
		lang = "en"
	var phase: String = str(src.get("phase", "on"))
	if not (phase in ["before", "on", "after"]):
		phase = "on"
	var p_raw: Variant = src.get("path", {})
	var p_src: Dictionary = p_raw if p_raw is Dictionary else {}
	var path := {
		"n": _int(p_src, "n", 1, 12, 1),
		"w": _int(p_src, "w", 1, 4, 1),
		"done": _int(p_src, "done", 0, 9999, 0),
		"goal": _goal(p_src),
		"finished": _bool(p_src, "finished"),
	}
	var course: Dictionary = _course_raw(src.get("course", null), lang, _int(src, "due", 0, MAX_INT, 0))
	return {
		"lang": lang, "phase": phase,
		"course": course,
		"course_offer": lang == "en" and course.is_empty() and _bool(src, "course_offer"),
		"before_days": _int(src, "before_days", 0, 99999, 0),
		"lesson_today": _int(src, "lesson_today", 0, MAX_INT, 0),
		"due": _int(src, "due", 0, MAX_INT, 0),
		"reviews_today": _int(src, "reviews_today", 0, MAX_INT, 0),
		"song_due": _int(src, "song_due", 0, MAX_INT, 0),
		"song_count": _int(src, "song_count", 0, MAX_INT, 0),
		"path": path,
		"goal_min": _int(src, "goal_min", 0, 100000, 0),
		"sec_today": _int(src, "sec_today", 0, MAX_INT, 0),
		"streak": _int(src, "streak", 0, 100000, 0),
		"tokens": _int(src, "tokens", 0, 100, 0),
		"studied_today": _bool(src, "studied_today"),
		"has_data": _bool(src, "has_data"),
		"first_run": _bool(src, "first_run"),
		"hour": _int(src, "hour", 0, 23, 12),
		"now": _int(src, "now", 0, 1 << 40, 0),
		"resume": _resume_raw(src.get("resume", {})),
	}


## 코스 스냅샷을 정리한다. 영어이고 mode 가 "course" 인 사전이 아니면 {}(코스 없음). 값은 범위 안으로 자르고 모르면 기본값.
static func _course_raw(c: Variant, lang: String, due_dflt: int) -> Dictionary:
	if lang != "en" or not (c is Dictionary):
		return {}
	var src: Dictionary = c
	var m: Variant = src.get("mode", "")
	if not (m is String) or m != "course":
		return {}
	var bd_raw: Variant = src.get("blocks_done", {})
	var bd_src: Dictionary = bd_raw if bd_raw is Dictionary else {}
	var bd: Dictionary = {}
	for id in COURSE_BLOCKS:
		bd[id] = _bool(bd_src, id)
	var fb: Variant = src.get("fallback", "")
	return {
		"mode": "course",
		"w": _int(src, "w", 1, CourseModel.WEEKS, 1), "d": _int(src, "d", 1, CourseModel.DAYS, 1),
		"blocks_done": bd,
		"away_days": _int(src, "away_days", 0, 99999, 0),
		"due": _int(src, "due", 0, MAX_INT, due_dflt),
		"check_pending": _bool(src, "check_pending"),
		"check_pending_days": _int(src, "check_pending_days", 0, 99999, 0),
		"rp_prev": _bool(src, "rp_prev"), "rp_streak": _int(src, "rp_streak", 0, 99, 0),
		"elapsed_days": _int(src, "elapsed_days", 0, 99999, 0),
		"finished": _bool(src, "finished"), "reopen_done": _bool(src, "reopen_done"),
		"fallback": str(fb) if (fb is String and fb in COURSE_FALLBACKS) else "",
	}


## resume 기록이 모양·값 모두 맞으면 {"view","lang","at"}(at 은 int), 아니면 {}. 시각 범위는 _recent_resume() 이 본다.
static func _resume_raw(r: Variant) -> Dictionary:
	if not (r is Dictionary):
		return {}
	var d: Dictionary = r
	var view: Variant = d.get("view", "")
	var lang: Variant = d.get("lang", "")
	var at: Variant = d.get("at", null)
	if not (view is String) or not (view in RESUME_VIEWS):
		return {}
	if not (lang is String) or not (lang in LANGS):
		return {}
	var at_i: int = 0
	if at is int:
		at_i = at
	elif at is float and is_finite(at) and absf(at) < 1.0e15:
		at_i = int(at)
	else:
		return {}
	if at_i < 0:
		return {}
	return {"view": view, "lang": lang, "at": at_i}


# ---------------------------------------------------------------- shared helpers

static func _target(view: String, lang: String) -> Dictionary:
	return {"view": view, "args": {"lang": lang}}


static func _lesson_target(n: Dictionary) -> Dictionary:
	var p: Dictionary = n["path"]
	return {"view": "lesson", "args": {"lang": n["lang"], "n": p["n"], "w": p["w"], "start": true}}


static func _lesson_sub(n: Dictionary) -> String:
	var p: Dictionary = n["path"]
	if bool(p["finished"]):
		return "1년 과정을 마쳤어요 · 복습 삼아 해 봐요"
	return "%d개월차 %d주 · %d/%d" % [p["n"], p["w"], mini(int(p["done"]), int(p["goal"])), p["goal"]]


## 7일 안에 이 언어로 한 마지막 활동(시각이 믿을 만한 것만). 없으면 {}.
static func _recent_resume(n: Dictionary) -> Dictionary:
	var r: Dictionary = n["resume"]
	if r.is_empty() or str(r["lang"]) != str(n["lang"]):
		return {}
	var now: int = int(n["now"])
	var at: int = int(r["at"])
	if at > now + FUTURE_SLACK_SEC:
		return {}
	if now - at > RESUME_DAYS * 86400:
		return {}
	return r


# ---------------------------------------------------------------- tasks / hero

## 홈 "오늘 할 일" 줄(최대 4개). 순서·글자는 §8.1.
static func tasks(s: Dictionary) -> Array:
	return _tasks(_norm(s))


static func _tasks(n: Dictionary) -> Array:
	var cp: Dictionary = _course_plan(n)
	if not cp.is_empty():
		return _course_tasks(n, cp)
	var lang: String = n["lang"]
	var lesson_done: bool = int(n["lesson_today"]) >= 1
	var lesson := {"id": "lesson", "title": "오늘의 레슨 완료" if lesson_done else "오늘의 레슨", "sub": _lesson_sub(n),
		"state": "done" if lesson_done else "todo", "target": _lesson_target(n)}
	var review: Dictionary = {}
	var due: int = n["due"]
	if due > 0:
		review = {"id": "review", "title": "복습 %d개" % due, "sub": "잊기 전에 짧게 복습해요", "state": "todo", "target": _target("review", lang)}
	elif int(n["reviews_today"]) > 0:
		review = {"id": "review", "title": "오늘 복습 끝!", "sub": "", "state": "done", "target": _target("review", lang)}
	var song: Dictionary = {}
	if int(n["song_due"]) > 0:
		song = {"id": "song", "title": "노래 외우기 %d줄" % int(n["song_due"]), "sub": "", "state": "todo", "target": _target("song", lang)}
	var talk := {"id": "talk", "title": "원어민과 말해 보기", "sub": "선택 · 5분이면 충분해요", "state": "optional", "target": _target("talk", lang)}

	var order: Array = [lesson, review, song, talk]
	if due >= REVIEW_FIRST_DUE and not lesson_done:
		order = [review, lesson, song, talk]
	var todo: Array = []
	var done: Array = []
	var opt: Array = []
	for t in order:
		if (t as Dictionary).is_empty():
			continue
		match str(t["state"]):
			"todo":
				todo.append(t)
			"done":
				done.append(t)
			_:
				opt.append(t)
	return todo + done + opt


## 시작 버튼: 첫 todo 줄의 행동. todo 가 없으면 "더 연습하기".
static func hero(s: Dictionary) -> Dictionary:
	return _hero(_norm(s))


static func _hero(n: Dictionary) -> Dictionary:
	var cp: Dictionary = _course_plan(n)
	if not cp.is_empty():
		return _course_hero(n, cp)
	var first: Dictionary = {}
	for t in _tasks(n):
		if str((t as Dictionary)["state"]) == "todo":
			first = t
			break
	if first.is_empty():
		return {"text": "더 연습하기", "target": _target("practice", n["lang"]), "all_done": true, "kind": "practice"}
	var id: String = str(first["id"])
	var text: String = ""
	match id:
		"lesson":
			var r: Dictionary = _recent_resume(n)
			text = "레슨 이어하기" if (not r.is_empty() and str(r["view"]) == "lesson") else "오늘의 레슨 시작"
		"review":
			text = "복습 %d개 시작" % int(n["due"])
		_:
			text = "노래 외우기 시작"
	return {"text": text, "target": first["target"], "all_done": false, "kind": id}


# ---------------------------------------------------------------- course mode (v2.0 E6)

## 코스 모드(영어)이고 코스 데이터·진도를 읽을 수 있으면 DayPlan.today() 결과, 아니면 {}.
## 입력의 due 는 "오늘 처음의 밀린 수"(지금 밀린 수 + 오늘 복습한 수)다: 하루 안에 복습을 하면서 계획의 분·복습 우선 여부가 바뀌지 않게 한다.
## 복습 블록은 오늘 복습한 카드가 min(처음 밀린 수, 15) 이상이면(밀린 것을 다 비운 경우 포함) 끝난 것으로 본다.
static func course_plan(s: Dictionary) -> Dictionary:
	return _course_plan(_norm(s))


static func _course_plan(n: Dictionary) -> Dictionary:
	var c: Dictionary = n["course"]
	if c.is_empty() or str(c["fallback"]) != "":
		return {}
	var rt: int = n["reviews_today"]
	var due_total: int = mini(int(c["due"]) + rt, MAX_INT)
	var done: Dictionary = (c["blocks_done"] as Dictionary).duplicate()
	if rt > 0 and rt >= mini(due_total, DayPlan.REVIEW_TARGET_MAX):
		done["review"] = true
	return DayPlan.today({"mode": "course", "w": c["w"], "d": c["d"], "due": due_total, "away_days": c["away_days"], "blocks_done": done,
		"check_pending": c["check_pending"], "check_pending_days": c["check_pending_days"], "rp_prev": c["rp_prev"], "rp_streak": c["rp_streak"],
		"elapsed_days": c["elapsed_days"], "finished": c["finished"], "reopen_done": c["reopen_done"]})


## true 이면 [새 코스로 시작] 카드를 보인다(영어, 코스 선택 전, 코스 데이터 있음). 코스가 켜져 있으면 false.
static func course_offer(s: Dictionary) -> bool:
	return bool(_norm(s)["course_offer"])


## 코스 블록 하나를 눌렀을 때 갈 곳.
static func _course_target(plan: Dictionary, b: Dictionary) -> Dictionary:
	var id: String = str(b["id"])
	if id == "review":
		return _target("review", "en")
	var kind: String = "new"
	var block: String = id
	match id:
		"new":
			kind = str(COURSE_UNIT_KIND.get(str(plan["kind"]), "new")) # D5 의 새 내용은 kind "speak" 이지만 block 은 "new" 다
		"listen":
			kind = "listen"
		"speak":
			kind = "speak"
	return {"view": "course", "args": {"lang": "en", "kind": kind, "w": plan["w"], "d": plan["d"], "block": block, "half": bool(b.get("half", false))}}


## 오늘 할 일 줄 4개(블록 순서 그대로). 분은 CourseModel.fmt_minutes, 개수 글은 CourseModel.progress_label 로만 만든다.
static func _course_tasks(n: Dictionary, plan: Dictionary) -> Array:
	var out: Array = []
	var due: int = int((n["course"] as Dictionary)["due"])
	for b in plan["blocks"]:
		var blk: Dictionary = b
		var id: String = str(blk["id"])
		var st: String = str(blk["state"])
		var mins: String = CourseModel.fmt_minutes(int(blk["min"]) * 60)
		var row: Dictionary = {"id": id, "title": "", "sub": "", "state": "done" if st == "done" else ("optional" if st == "skip" else "todo"),
			"target": _course_target(plan, blk)}
		match id:
			"new":
				if str(plan["kind"]) == "free": # 자유 날: 배운 문장 듣기로 복습하며 그 주를 마친다
					row["title"] = "%s · 듣기 복습" % blk["title"]
					row["sub"] = "%d주 %d일 · %s" % [plan["w"], plan["d"], mins]
				else:
					row["title"] = "%s · %d주 %d일" % [blk["title"], plan["w"], plan["d"]]
					row["sub"] = mins + (" · 절반만 해요" if bool(blk.get("half", false)) else "")
			"review":
				if st == "done":
					row["title"] = "오늘 복습 끝!"
				elif st == "skip":
					row["title"] = "복습할 카드가 없어요"
					row["sub"] = "복습 시간은 듣기에 더했어요"
				else:
					row["title"] = "복습 %d개" % mini(due, 9999)
					row["sub"] = mins + (" · 복습부터 해요" if bool(plan["review_priority"]) else "")
			"listen":
				row["title"] = "듣기 " + mins
				row["sub"] = str(blk["sub"])
			"speak":
				row["title"] = "말하기 " + mins
				row["sub"] = str(blk["sub"])
		out.append(row)
	return out


static func _course_hero(n: Dictionary, plan: Dictionary) -> Dictionary:
	for b in plan["blocks"]:
		if str((b as Dictionary)["state"]) == "current":
			return {"text": str(plan["start_label"]), "target": _course_target(plan, b), "all_done": false, "kind": str((b as Dictionary)["id"])}
	return {"text": str(plan["start_label"]), "target": _target("practice", n["lang"]), "all_done": true, "kind": "practice"}


## 코스 모드 인사 한 줄: 다 했다 > 한 블록이라도 했다("오늘 45분 중 20분 했어요.") > 복귀 > 복습 우선 > 저녁 경고 > 시작 안내.
static func _course_message(n: Dictionary, plan: Dictionary) -> Dictionary:
	var total: String = CourseModel.fmt_minutes(int(plan["total_min"]) * 60)
	var done_min: int = int(plan["done_min"])
	var all_done: bool = bool(_course_hero(n, plan)["all_done"])
	if all_done:
		return {"text": "오늘 %s을 다 했어요. 잘했어요!" % total, "kind": "ok"}
	if done_min > 0:
		return {"text": "오늘 %s 중 %s 했어요." % [total, CourseModel.fmt_minutes(done_min * 60)], "kind": "info"}
	if bool(plan["recap"]):
		return {"text": "오랜만이에요! 복귀 점검과 복습부터 가볍게 해요.", "kind": "info"}
	if bool(plan["review_priority"]):
		return {"text": "복습부터 해요. 밀린 카드가 많아요.", "kind": "info"}
	if int(n["streak"]) > 0 and not bool(n["studied_today"]) and int(n["hour"]) >= EVENING_HOUR:
		return {"text": "오늘 아직이에요. 지금 하면 연속 %d일!" % (int(n["streak"]) + 1), "kind": "warn"}
	if bool(plan["finished"]):
		return {"text": "72주 코스를 마쳤어요. 복습 삼아 계속해요.", "kind": "ok"}
	return {"text": "오늘 %s, 한 블록씩 해요." % total, "kind": "info"}


## 홈 카드 아래에 작게 보이는 안내 줄(감점·잠금 없이 알림만, §6.2). [{"text","kind": "info"|"warn"}], 많아야 3줄.
static func course_notes(s: Dictionary) -> Array:
	var n: Dictionary = _norm(s)
	var c: Dictionary = n["course"]
	var out: Array = []
	if c.is_empty():
		return out
	var fb: String = str(c["fallback"])
	if fb != "":
		out.append({"text": str(TEXT_FALLBACK.get(fb, "")), "kind": "warn"})
		return out
	var plan: Dictionary = _course_plan(n)
	if int(plan["late_weeks"]) > 0:
		out.append({"text": "예정보다 %s 늦었어요. 괜찮아요, 한 칸씩 끝내면 돼요." % CourseModel.progress_label("weeks", int(plan["late_weeks"]), 0), "kind": "info"})
	if int(c["away_days"]) >= DayPlan.REOPEN_AWAY and bool(c["reopen_done"]):
		out.append({"text": "오래 쉬어서 직전 두 주를 다시 열었어요.", "kind": "info"})
	if bool(plan["ask_check"]):
		out.append({"text": "지난 주 점검을 아직 안 했어요. 시간 날 때 해 봐요.", "kind": "info"})
	if out.is_empty():
		out.append({"text": TEXT_DEVICE, "kind": "info"})
	return out.slice(0, 3)


# ---------------------------------------------------------------- resume card

## 이어하기 카드. {} 이면 카드 없음. 조건은 §8.2.
static func resume(s: Dictionary) -> Dictionary:
	var n: Dictionary = _norm(s)
	var r: Dictionary = _recent_resume(n)
	if r.is_empty():
		return {}
	var view: String = r["view"]
	if view == "lesson" and not _course_plan(n).is_empty():
		return {} # 코스 모드: 예전 12개월 길 레슨 이어하기 카드는 없다(오늘 할 일 줄이 그 일을 한다)
	var h: Dictionary = _hero(n)
	if str((h["target"] as Dictionary)["view"]) == view:
		return {} # 같은 곳이면 시작 버튼이 "이어하기" 글자를 대신 가진다
	var lang: String = n["lang"]
	match view:
		"lesson":
			return {"title": "레슨 이어하기", "sub": _lesson_sub(n), "button": "시작", "target": _lesson_target(n)}
		"review":
			if int(n["due"]) <= 0:
				return {}
			return {"title": "복습 이어하기", "sub": "남은 %d개" % int(n["due"]), "button": "시작", "target": _target("review", lang)}
		"song":
			return {"title": "노래 이어하기", "sub": "", "button": "시작", "target": _target("song", lang)}
		"practice":
			return {"title": "연습 이어하기", "sub": "", "button": "시작", "target": _target("practice", lang)}
		"reading":
			return {"title": "읽기 이어하기", "sub": "", "button": "시작", "target": _target("reading", lang)}
		"talk":
			return {"title": "대화 이어하기", "sub": "", "button": "시작", "target": _target("talk", lang)}
	return {}


# ---------------------------------------------------------------- greeting

## 홈 인사 한 줄. 위에서부터 첫 일치(§8.4). {"text","kind": "info"|"warn"|"ok"}
static func message(s: Dictionary) -> Dictionary:
	var n: Dictionary = _norm(s)
	var streak: int = n["streak"]
	var cp: Dictionary = _course_plan(n)
	if not cp.is_empty():
		return _course_message(n, cp)
	if n["phase"] == "before":
		return {"text": "시작까지 D-%d · 지금 맛보기 레슨을 해 볼 수 있어요" % int(n["before_days"]), "kind": "info"}
	if bool(n["first_run"]):
		return {"text": "처음이에요! 레슨 하나부터 가볍게 시작해요.", "kind": "info"}
	if goal_reached(n):
		if streak >= 2:
			return {"text": "오늘 목표 달성! 연속 %d일째예요." % streak, "kind": "ok"}
		return {"text": "오늘 목표 달성! 잘했어요.", "kind": "ok"}
	if streak > 0 and not bool(n["studied_today"]) and int(n["hour"]) >= EVENING_HOUR:
		return {"text": "오늘 아직이에요. 지금 하면 연속 %d일!" % (streak + 1), "kind": "warn"}
	if streak == 0 and bool(n["has_data"]):
		return {"text": "다시 시작해요. 오늘 한 번이면 연속 1일이에요.", "kind": "info"}
	var left: int = 0
	for t in _tasks(n):
		if str((t as Dictionary)["state"]) == "todo":
			left += 1
	if left > 0:
		return {"text": "오늘 할 일 %d개 남았어요." % left, "kind": "info"}
	return {"text": "오늘 할 일을 다 했어요.", "kind": "ok"}


## 하루 목표 시간을 채웠나(목표 0 = 꺼짐 -> false). 원본 스냅샷을 받는다.
static func goal_reached(s: Dictionary) -> bool:
	var g: int = _int(s, "goal_min", 0, 100000, 0)
	return g > 0 and _int(s, "sec_today", 0, MAX_INT, 0) >= g * 60


# ---------------------------------------------------------------- real snapshot

## 실제 값으로 스냅샷을 만든다(설계 §9.3). 순수 계산 파일에 Store/StudyLog/시계 접근을 두지 않으려고
## 읽는 코드는 HomeParts.snapshot() 에 있고, 여기서는 그것을 그대로 돌려준다.
static func snapshot(lang: String) -> Dictionary:
	return HomeParts.snapshot(lang)
