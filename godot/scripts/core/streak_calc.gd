class_name StreakCalc
extends RefCounted
## 연속 기록 + 보호권(freeze) 순수 계산. 날짜는 모두 일 번호(Plan.days_from_civil)로 받는다.
##
## 규칙
## - done: 공부한 날(일 번호 -> true). frozen: 보호권으로 이미 이어 준 날(일 번호 -> true).
## - 마지막 공부일(prev, 오늘 이전)과 오늘 사이에 빠진 날이 g 일이면, 보호권이 g 개 이상일 때 그 날들을
##   보호해 연속을 잇는다(보호권 g 개 사용). 부족하면 아무것도 쓰지 않고 연속이 끊긴다(이미 쓴 보호권은 돌려준다).
## - 오늘 아직 공부 안 한 것은 빠진 날이 아니다(어제까지 이어져 있으면 끊기지 않음).
## - 보호된 날은 연속 일수에 더하지 않고 잇기만 한다.
## - 보상: 현재 연속 일수 L 에서 floor(L/7) 이 awarded 보다 크면 그 차이만큼 +1 (보호권 최대 2개).
##   floor(L/7) 이 awarded 보다 작아지면(끊긴 뒤 새 연속) awarded 를 내려 다시 받을 수 있게 한다.
## - 멱등: 결과(frozen, tokens, awarded)를 그대로 다시 넣으면 같은 결과, used/gained 는 0.
## - 시계가 과거로 되돌려져 done/frozen 에 오늘보다 미래 날이 있으면 상태를 바꾸지 않고
##   미래 날을 무시한 연속 일수만 계산한다.
##
## 쉬는 날(rest, v2.0.2)
## - 달력 주(월~일)마다 최대 rest_per_week 일은 보호권 없이 빈 날을 이어 준다. 쉬는 날을 먼저 쓰고 모자라면 보호권을 쓴다.
## - 틈 전체를 잇지 못하면 지금처럼 하나도 잇지 않고(쓴 보호권은 돌려줌) 쉬는 날도 쓰지 않는다.
## - 쉬는 날도 보호된 날처럼 연속 일수에 세지 않는다. rest 는 frozen 의 부분집합으로만 인정한다.
## - rest_per_week 기본 0 이면 쉬는 날 없는 예전 결과와 똑같다. 소급 없음: 마지막 공부일 ~ 오늘 틈만 본다.

const MAX_TOKENS := 2
const MILESTONE := 7
const NONE := -2147483648
const REST_PER_WEEK := 2
const MAX_REST_PER_WEEK := 7


## done/frozen/rest: {day_number: true}. Returns {frozen, tokens, used, streak, awarded, gained, rest, rest_used}.
## rest = the frozen days that were rest days (not paid with a token). rest_per_week 0 = no rest days (the old result).
## The input dictionaries are never modified.
static func settle(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int,
		rest: Dictionary = {}, rest_per_week: int = 0) -> Dictionary:
	tokens = clampi(tokens, 0, MAX_TOKENS)
	awarded = maxi(awarded, 0)
	var rpw: int = clampi(rest_per_week, 0, MAX_REST_PER_WEEK)
	var fz: Dictionary = _clean(frozen)
	var dn: Dictionary = _clean(done)
	var rs := {}
	for k in _clean(rest).keys():
		if fz.has(k):
			rs[k] = true

	# clock went backwards (records from "the future"): change nothing
	for k in dn.keys():
		if int(k) > today:
			return _reversed(dn, fz, rs, tokens, awarded, today)
	for k in fz.keys():
		if int(k) > today:
			return _reversed(dn, fz, rs, tokens, awarded, today)

	var used := 0
	var rest_used := 0
	# most recent study day before today
	var prev: int = NONE
	for k in dn.keys():
		var d: int = int(k)
		if d < today and d > prev:
			prev = d

	# Days that were bridged but are studied now (e.g. a day that came in with a sync) need no bridge any more.
	# A freed rest day gives its week's rest quota back (a later token day of that week becomes a rest day, one token returns),
	# a freed token day returns its token. Only with rest days on: with rest_per_week 0 the old rule is kept as it was.
	if rpw > 0:
		var refund := 0
		var freed := {}
		for k in fz.keys():
			if dn.has(k):
				fz.erase(k)
				if rs.has(k):
					rs.erase(k)
					freed[week_of(int(k))] = true
				else:
					refund += 1
		if not freed.is_empty():
			var in_week := {}
			for k in rs.keys():
				var w1: int = week_of(int(k))
				in_week[w1] = int(in_week.get(w1, 0)) + 1
			var cand: Array = fz.keys()
			cand.sort()
			for k in cand:
				var d2: int = int(k)
				if rs.has(d2):
					continue
				var w2: int = week_of(d2)
				if freed.has(w2) and int(in_week.get(w2, 0)) < rpw:
					rs[d2] = true
					in_week[w2] = int(in_week.get(w2, 0)) + 1
					refund += 1
		tokens = mini(MAX_TOKENS, tokens + refund)

	if prev != NONE:
		var gap: int = today - prev - 1
		if gap > 0:
			# 1) keep what is already marked in this gap, rest days first for the days that are still empty
			var per_week := {} # week (Monday day number) -> rest days in it (kept ones + the ones picked now)
			for k in rs.keys():
				var w0: int = week_of(int(k))
				per_week[w0] = int(per_week.get(w0, 0)) + 1
			var need_tok := 0
			var picked: Array = []
			for d in range(prev + 1, today):
				if fz.has(d):
					continue
				var w: int = week_of(d)
				if int(per_week.get(w, 0)) < rpw:
					per_week[w] = int(per_week.get(w, 0)) + 1
					picked.append(d)
				else:
					need_tok += 1
			if need_tok <= tokens:
				for d in range(prev + 1, today):
					fz[d] = true
				for d in picked:
					rs[d] = true
				tokens -= need_tok
				used = need_tok
				rest_used = picked.size()
			else:
				# 2) start this gap over: tokens already spent on it come back, its rest days are free again, and the
				#    whole gap is given rest days (up to the weekly limit) first. A result of this is the same when settled again.
				var out_week := {}
				var in_gap_tok := 0
				for k in rs.keys():
					var d3: int = int(k)
					if d3 > prev and d3 < today:
						continue
					var w3: int = week_of(d3)
					out_week[w3] = int(out_week.get(w3, 0)) + 1
				for k in fz.keys():
					var d4: int = int(k)
					if d4 > prev and d4 < today and not rs.has(d4):
						in_gap_tok += 1
				var need2 := 0
				var picked2: Array = []
				for d in range(prev + 1, today):
					var w5: int = week_of(d)
					if int(out_week.get(w5, 0)) < rpw:
						out_week[w5] = int(out_week.get(w5, 0)) + 1
						picked2.append(d)
					else:
						need2 += 1
				var avail: int = tokens + in_gap_tok
				if need2 <= avail:
					var fresh := 0
					for d in picked2:
						if not fz.has(d):
							fresh += 1
					for k in rs.keys():
						var d6: int = int(k)
						if d6 > prev and d6 < today:
							rs.erase(k)
					for d in range(prev + 1, today):
						fz[d] = true
					for d in picked2:
						rs[d] = true
					var left: int = mini(MAX_TOKENS, avail - need2)
					used = maxi(tokens - left, 0)
					rest_used = fresh
					tokens = left
				else:
					# cannot bridge: give back what was spent on this gap, streak breaks
					for k in fz.keys():
						var d: int = int(k)
						if d > prev and d < today:
							fz.erase(k)
							rs.erase(k)
					tokens = mini(MAX_TOKENS, avail)
	var streak: int = _run(dn, fz, today)

	var gained := 0
	var level: int = streak / MILESTONE
	if level > awarded:
		gained = clampi(level - awarded, 0, MAX_TOKENS - tokens)
		tokens += gained
		awarded = level
	elif level < awarded:
		awarded = level
	return {"frozen": fz, "tokens": tokens, "used": used, "streak": streak, "awarded": awarded, "gained": gained,
		"rest": rs, "rest_used": rest_used}


## Streak ending today (or yesterday when today is not done yet); frozen days bridge without counting.
static func _run(done: Dictionary, frozen: Dictionary, today: int) -> int:
	var d: int = today if done.has(today) else today - 1
	var count := 0
	while true:
		if done.has(d):
			count += 1
		elif not frozen.has(d):
			break
		d -= 1
	return count


static func _reversed(done: Dictionary, frozen: Dictionary, rest: Dictionary, tokens: int, awarded: int, today: int) -> Dictionary:
	var dn := {}
	for k in done.keys():
		if int(k) <= today:
			dn[int(k)] = true
	var fz := {}
	for k in frozen.keys():
		if int(k) <= today:
			fz[int(k)] = true
	return {"frozen": frozen.duplicate(), "tokens": tokens, "used": 0, "streak": _run(dn, fz, today), "awarded": awarded, "gained": 0,
		"rest": rest.duplicate(), "rest_used": 0}


## Monday (day number) of the calendar week that holds `d`; rest days are counted per this week.
static func week_of(d: int) -> int:
	return Plan.monday_of(d)


## Rest days still free this week: rest_per_week - (rest days in the week of `today`), never below 0.
static func rest_left(rest: Dictionary, today: int, rest_per_week: int) -> int:
	var rpw: int = clampi(rest_per_week, 0, MAX_REST_PER_WEEK)
	var wk: int = week_of(today)
	var n := 0
	for k in _clean(rest).keys():
		if week_of(int(k)) == wk:
			n += 1
	return maxi(rpw - n, 0)


## Keeps only integer-like keys with a truthy value (copy).
static func _clean(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src.keys():
		if (k is int or (k is float and is_finite(k))) and bool(src[k]):
			out[int(k)] = true
	return out
