class_name BadgeEngine
extends RefCounted
## 배지 엔진(docs/v160_fun_design.md §5.3, §5.5, §6.5 B1): 실제 기록에서 스냅샷을 만들고, BadgeRules 로 판정해서
## 새로 받은 배지를 StudyLog.badges 에 영구 저장하고 알림(토스트)을 최대 1개 띄운다.
##
## 읽는 곳은 snapshot() 한 곳뿐이다(Store / StudyLog / KanaData / KanaCourse(짝 글자) / SongDue.cache).
## 쓰는 곳은 StudyLog.init_badge_record / grant_badge / mark_badges_seen / flush 뿐이다. 배지는 한 번 받으면 회수하지 않는다
## (기록이 지워지거나 값이 내려가거나 시계를 되돌려도 got·at 은 그대로).
##
## 첫 평가(StudyLog.has_badge_record() 가 거짓): 조건을 채운 배지를 모두 retro = true 로 한꺼번에 받고 알림은
## "이미 달성한 배지 N개를 모았어요" 한 줄. 그 뒤에 새로 받으면 retro = false + 배지 이름이 든 알림 한 줄.
## 기록 파일을 못 열어 읽기 전용이면(StudyLog.is_read_only()) 평가는 아무것도 하지 않고 조용히 끝난다(알림 0, 저장 0).

## 시험이 스냅샷을 바꿔 끼운다: () -> Dictionary. 비어 있으면 실제 값. 사전이 아닌 값을 돌려주면 빈 스냅샷으로 본다.
static var provider: Callable = Callable()


# ---------------------------------------------------------------- snapshot

## 실제 값으로 만든 스냅샷({측정 이름: 정수}, 이름 = BadgeRules.MEASURES). 값은 BadgeRules.clean 으로 한 번 더 청소된다.
## only 가 비어 있지 않으면 그 이름의 값만 계산한다(비싼 것: 연속 일수·400일 합계를 이미 다 받은 배지는 건너뛰려는 것).
## 계산하지 않은 이름은 사전에 없다(= 0). 평가(evaluate)는 아직 못 받은 배지의 이름만 넘긴다.
static func snapshot(only: Array = []) -> Dictionary:
	if provider.is_valid():
		var r: Variant = provider.call()
		return (r as Dictionary).duplicate(true) if r is Dictionary else {}
	var s := {}
	var want_streak: bool = _want(only, "streak_best")
	var want_days: bool = _want(only, "study_sec_total") or _want(only, "reviews_total") or _want(only, "pron_day_best")
	var lessons: int = 0
	var talks: int = 0
	var streak: int = 0
	var secs: int = 0
	var reviews: int = 0
	var pron: int = 0
	for lang in StudyLog.LANGS:
		lessons += Store.stat(lang, "lessons")
		talks += Store.stat(lang, "talks")
		if want_streak:
			streak = maxi(streak, StudyLog.longest_streak(lang))
		if want_days:
			for r in StudyLog.range_summary(lang, StudyLog.KEEP_DAYS):
				var day: Dictionary = r
				secs += int(day.get("sec", 0))
				reviews += int((day.get("n", {}) as Dictionary).get("reviews", 0))
				var sn: int = int(day.get("score_n", 0))
				if sn >= PRON_MIN_SCORES:
					pron = maxi(pron, int(day.get("score_sum", 0)) / sn) ## 정수 나눗셈 = 내림 -> 평균이 80.0 이상일 때만 80
	s["lessons_total"] = lessons
	s["talks_total"] = talks
	s["streak_best"] = streak
	s["study_sec_total"] = secs
	s["reviews_total"] = reviews
	s["pron_day_best"] = pron
	var rv: Variant = Store.progress.get("review", [])
	s["cards_count"] = (rv as Array).size() if rv is Array else 0
	var star3: int = 0
	for id in StudyLog.mission_ids():
		if int(StudyLog.mission_best(str(id)).get("stars", 0)) == 3:
			star3 += 1
	var all3: int = 0
	for id in BadgeRules.MISSION_IDS:
		if int(StudyLog.mission_best(id).get("stars", 0)) == 3:
			all3 += 1
	s["mission_star3"] = star3
	s["mission_all_star3"] = all3
	s["song_lyrics"] = int(SongDue.cache.get("lyrics", 0))
	s["song_done"] = int(SongDue.cache.get("done", 0))
	var stats: Dictionary = StudyLog.kana_stats()
	var hira: int = 0
	var kata: int = 0
	var every: int = 0
	for e in KanaData.entries("both"):
		var ent: Dictionary = e
		if _mastery(stats, str(ent["ch"])) < 3:
			continue
		every += 1
		if str(ent["sec"]) == "seion":
			if str(ent["script"]) == "hira":
				hira += 1
			else:
				kata += 1
	var pairs_ok: int = 0
	for ch in BadgeDefs.pair_letters():
		if _mastery(stats, str(ch)) >= 3:
			pairs_ok += 1
	s["kana_hira_seion"] = hira
	s["kana_kata_seion"] = kata
	s["kana_all"] = every
	s["kana_pairs"] = pairs_ok
	var plays: int = 0
	var combo: int = 0
	var score: int = 0
	for lang in StudyLog.LANGS:
		plays += int(StudyLog.speed_summary(lang).get("plays", 0))
		var b: Dictionary = StudyLog.speed_best(lang)
		combo = maxi(combo, int(b.get("combo", 0)))
		score = maxi(score, int(b.get("score", 0)))
	s["speed_plays"] = plays
	s["speed_combo"] = combo
	s["speed_score"] = score
	return s


## 하루 점수 평균을 따질 때 그날 채점이 이만큼은 있어야 한다(한두 번 운 좋은 점수로 받지 않게).
const PRON_MIN_SCORES := 3


static func _want(only: Array, measure: String) -> bool:
	return only.is_empty() or only.has(measure)


static func _mastery(stats: Dictionary, ch: String) -> int:
	var v: Variant = stats.get(ch, null)
	if v is Array and (v as Array).size() >= 2:
		return KanaData.mastery(maxi(int((v as Array)[0]), 0), maxi(int((v as Array)[1]), 0))
	return 0


# ---------------------------------------------------------------- evaluate

## 평가 한 번. 새로 받은 id 목록(표 순서)을 돌려준다. 저장(StudyLog.flush)과 알림(토스트 최대 1개)까지 한다.
## 읽기 전용 기록이면 [] (아무것도 하지 않음). 평가 도중 이상한 값이 있어도 에러 없이 끝난다.
static func evaluate(_source: String = "") -> Array:
	if StudyLog.is_read_only():
		return []
	var retro: bool = not StudyLog.has_badge_record()
	var changed: bool = retro
	StudyLog.init_badge_record()
	var got: Dictionary = StudyLog.badges_got()
	var need: Array = []
	for d in BadgeDefs.all():
		if not got.has((d as Dictionary)["id"]) and not need.has((d as Dictionary)["measure"]):
			need.append((d as Dictionary)["measure"])
	var snap: Dictionary = snapshot(need) if not need.is_empty() else {}
	var fresh: Array = []
	for id in BadgeRules.earned_ids(snap):
		if got.has(id):
			continue
		if StudyLog.grant_badge(str(id), retro):
			fresh.append(id)
			changed = true
	if changed:
		StudyLog.flush()
	_notify(fresh, retro)
	return fresh


static func _notify(fresh: Array, retro: bool) -> void:
	if fresh.is_empty():
		return
	if retro:
		Toast.info("이미 달성한 배지 %d개를 모았어요" % fresh.size())
		return
	var first: String = str(BadgeDefs.by_id(str(fresh[0])).get("name", fresh[0]))
	if fresh.size() == 1:
		Toast.ok("배지를 받았어요: %s" % first)
	else:
		Toast.ok("배지 %d개를 받았어요: %s 외 %d개" % [fresh.size(), first, fresh.size() - 1])


# ---------------------------------------------------------------- reading for the badge screen

## 배지 화면용: [{id, name, desc, cat, glyph, got, at, retro, value, target, is_new}] 표 순서. 아무것도 바꾸지 않는다.
## lang 은 지금 쓰지 않는다(배지는 언어와 상관없는 전체 기록).
static func ui_list(_lang: String = "") -> Array:
	var snap: Dictionary = snapshot()
	var got: Dictionary = StudyLog.badges_got()
	var seen: Array = StudyLog.badges_seen()
	var out: Array = []
	for d in BadgeDefs.all():
		var def: Dictionary = d
		var id: String = str(def["id"])
		var p: Dictionary = BadgeRules.progress(def, snap)
		var rec: Variant = got.get(id, null)
		var has_it: bool = rec is Dictionary
		out.append({
			"id": id, "name": def["name"], "desc": def["desc"], "cat": def["cat"], "glyph": def["glyph"],
			"got": has_it,
			"at": str((rec as Dictionary).get("at", "")) if has_it else "",
			"retro": bool((rec as Dictionary).get("retro", false)) if has_it else false,
			"value": int(p["value"]), "target": int(p["target"]),
			"is_new": has_it and not seen.has(id),
		})
	return out


## {got, total, unseen}. 이 버전이 모르는 id 는 세지 않는다.
static func counts() -> Dictionary:
	var got: Dictionary = StudyLog.badges_got()
	var seen: Array = StudyLog.badges_seen()
	var n: int = 0
	var unseen: int = 0
	for id in BadgeDefs.ids():
		if got.has(id):
			n += 1
			if not seen.has(id):
				unseen += 1
	return {"got": n, "total": BadgeDefs.ids().size(), "unseen": unseen}


## 받은 배지를 전부 "봤다"로 표시하고 저장한다(배지 화면이 보일 때 부른다).
static func mark_all_seen() -> void:
	StudyLog.mark_badges_seen(StudyLog.badges_got().keys())
	StudyLog.flush()
