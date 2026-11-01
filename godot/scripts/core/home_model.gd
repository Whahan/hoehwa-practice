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

const REVIEW_FIRST_DUE := 20 ## 복습이 이만큼 밀리면 복습 줄이 레슨 줄 앞에 온다
const RESUME_DAYS := 7 ## 이어하기는 마지막 활동이 이 안일 때만
const EVENING_HOUR := 18 ## 이 시각부터 "오늘 아직이에요" 문구
const FUTURE_SLACK_SEC := 86400 ## 시계가 이만큼 넘게 앞서 있으면 기록을 믿지 않는다
const RESUME_VIEWS := ["lesson", "review", "talk", "practice", "reading", "song"]
const LANGS := ["en", "ja"]
const MAX_INT := 1000000000


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
	return {
		"lang": lang, "phase": phase,
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
	var lang: String = n["lang"]
	var lesson_done: bool = int(n["lesson_today"]) >= 1
	var lesson := {"id": "lesson", "title": "오늘의 레슨 완료" if lesson_done else "오늘의 레슨", "sub": _lesson_sub(n),
		"state": "done" if lesson_done else "todo", "target": _lesson_target(n)}
	var review: Dictionary = {}
	var due: int = n["due"]
	if due > 0:
		review = {"id": "review", "title": "복습 %d개" % due, "sub": "잊기 전에 짧게 복습해요", "state": "todo", "target": _target("review", lang)}
	elif int(n["reviews_today"]) > 0:
		review = {"id": "review", "title": "복습 끝!", "sub": "", "state": "done", "target": _target("review", lang)}
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


# ---------------------------------------------------------------- resume card

## 이어하기 카드. {} 이면 카드 없음. 조건은 §8.2.
static func resume(s: Dictionary) -> Dictionary:
	var n: Dictionary = _norm(s)
	var r: Dictionary = _recent_resume(n)
	if r.is_empty():
		return {}
	var view: String = r["view"]
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

## 실제 값으로 스냅샷을 만든다. T4 가 본문을 채운다(StudyLog, Store, PathModel 을 부르므로 T1b 는 만들지 않는다).
static func snapshot(_lang: String) -> Dictionary:
	# TODO(T4): StudyLog.range_summary(lang,1)[0], Store.due_count, StudyLog.settle, PathModel.current_cell,
	#           Store.position, StudyLog.resume, Time(현지 hour), SongDue.cache(song_due, song_count)
	return {}
