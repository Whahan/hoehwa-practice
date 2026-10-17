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

const MAX_TOKENS := 2
const MILESTONE := 7
const NONE := -2147483648


## done/frozen: {day_number: true}. Returns {frozen, tokens, used, streak, awarded, gained}.
## The input dictionaries are never modified.
static func settle(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int) -> Dictionary:
	tokens = clampi(tokens, 0, MAX_TOKENS)
	awarded = maxi(awarded, 0)
	var fz: Dictionary = _clean(frozen)
	var dn: Dictionary = _clean(done)

	# clock went backwards (records from "the future"): change nothing
	for k in dn.keys():
		if int(k) > today:
			return _reversed(dn, fz, tokens, awarded, today)
	for k in fz.keys():
		if int(k) > today:
			return _reversed(dn, fz, tokens, awarded, today)

	var used := 0
	# most recent study day before today
	var prev: int = NONE
	for k in dn.keys():
		var d: int = int(k)
		if d < today and d > prev:
			prev = d
	if prev != NONE:
		var gap: int = today - prev - 1
		if gap > 0:
			var in_gap := 0
			for k in fz.keys():
				var d: int = int(k)
				if d > prev and d < today:
					in_gap += 1
			var avail: int = tokens + in_gap
			if gap <= avail:
				for d in range(prev + 1, today):
					fz[d] = true
				tokens = avail - gap
				used = gap - in_gap
			else:
				# cannot bridge: give back what was spent on this gap, streak breaks
				for k in fz.keys():
					var d: int = int(k)
					if d > prev and d < today:
						fz.erase(k)
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
	return {"frozen": fz, "tokens": tokens, "used": used, "streak": streak, "awarded": awarded, "gained": gained}


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


static func _reversed(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int) -> Dictionary:
	var dn := {}
	for k in done.keys():
		if int(k) <= today:
			dn[int(k)] = true
	var fz := {}
	for k in frozen.keys():
		if int(k) <= today:
			fz[int(k)] = true
	return {"frozen": frozen.duplicate(), "tokens": tokens, "used": 0, "streak": _run(dn, fz, today), "awarded": awarded, "gained": 0}


## Keeps only integer-like keys with a truthy value (copy).
static func _clean(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src.keys():
		if (k is int or (k is float and is_finite(k))) and bool(src[k]):
			out[int(k)] = true
	return out
