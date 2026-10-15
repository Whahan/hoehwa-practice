class_name FSRS
extends RefCounted
## FSRS-6 spaced-repetition scheduler (GDScript port).
##
## Faithful port of the Scheduler in py-fsrs (https://github.com/open-spaced-repetition/py-fsrs,
## MIT License, (c) Open Spaced Repetition), release 6.3.x: same default 21 parameters, same
## learning / relearning step logic, same interval rounding (half-to-even) and fuzz.
## Verified against py-fsrs by tests/fsrs_test.gd (tests/fsrs_reference.json).
##
## A card is a plain Dictionary so it can live in progress.json:
##   due (unix s), stability (0.0 = none yet), difficulty (0.0 = none yet), state (1/2/3),
##   step (learning/relearning step index, 0 when in Review), last_review (unix s, 0 = never),
##   reps, lapses.
## All functions are static and never modify the dictionary passed in.

enum State { LEARNING = 1, REVIEW = 2, RELEARNING = 3 }
enum Rating { AGAIN = 1, HARD = 2, GOOD = 3, EASY = 4 }

const DAY := 86400
const PARAMETERS: Array[float] = [
	0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666,
	0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
]
const DESIRED_RETENTION := 0.9
const LEARNING_STEPS: Array[int] = [60, 600] ## seconds
const RELEARNING_STEPS: Array[int] = [600]
const MAXIMUM_INTERVAL := 36500 ## days
const STABILITY_MIN := 0.001
const FUZZ_RANGES := [[2.5, 7.0, 0.15], [7.0, 20.0, 0.1], [20.0, INF, 0.05]] ## start, end, factor

## Test hook: replaces randf() when >= 0 (fuzz position in [0, 1)).
static var fuzz_override: float = -1.0


# ---------------------------------------------------------------- cards

static func new_card(now: int) -> Dictionary:
	return {"due": now, "stability": 0.0, "difficulty": 0.0, "state": State.LEARNING,
		"step": 0, "last_review": 0, "reps": 0, "lapses": 0}


## Fill in / repair FSRS fields of an arbitrary dictionary (migration + normalize()).
## Missing or invalid fields become a new card due at `now`; the dictionary's other keys are kept.
static func ensure_fields(d: Dictionary, now: int) -> void:
	var valid: bool = (d.get("state", 0) is float or d.get("state", 0) is int) \
		and int(d.get("state", 0)) >= 1 and int(d.get("state", 0)) <= 3 \
		and (d.get("due", null) is float or d.get("due", null) is int)
	if not valid:
		d.merge(new_card(now), true)
		return
	d["due"] = int(d["due"])
	d["state"] = int(d["state"])
	d["stability"] = maxf(0.0, _f(d.get("stability", 0.0)))
	d["difficulty"] = maxf(0.0, _f(d.get("difficulty", 0.0)))
	d["step"] = maxi(0, int(_f(d.get("step", 0.0))))
	d["last_review"] = maxi(0, int(_f(d.get("last_review", 0.0))))
	d["reps"] = maxi(0, int(_f(d.get("reps", 0.0))))
	d["lapses"] = maxi(0, int(_f(d.get("lapses", 0.0))))
	# A Review/Relearning card without memory state is meaningless: restart it.
	if int(d["state"]) != State.LEARNING and (float(d["stability"]) <= 0.0 or float(d["difficulty"]) <= 0.0):
		d.merge(new_card(now), true)


static func _f(v: Variant) -> float:
	return float(v) if (v is float or v is int) else 0.0


static func is_new(card: Dictionary) -> bool:
	return int(card.get("reps", 0)) == 0 and int(card.get("last_review", 0)) == 0


# ---------------------------------------------------------------- review

## Review `card` with `rating` (1..4) at unix time `now`. Returns the updated copy.
static func review(card: Dictionary, rating: int, now: int, fuzz: bool = true) -> Dictionary:
	var c: Dictionary = card.duplicate()
	var state: int = int(c["state"])
	var stab: float = float(c["stability"])
	var diff: float = float(c["difficulty"])
	var step: int = int(c["step"])
	var last: int = int(c["last_review"])
	var has_last: bool = last > 0
	var days_since: int = floori(float(now - last) / DAY) if has_last else 999999
	var interval_sec: float = 0.0

	if state == State.REVIEW:
		stab = _updated_stability(stab, diff, rating, c, now, has_last, days_since)
		diff = _next_difficulty(diff, rating)
		if rating == Rating.AGAIN:
			c["lapses"] = int(c["lapses"]) + 1 # not part of py-fsrs 6; classic definition
		if rating == Rating.AGAIN and not RELEARNING_STEPS.is_empty():
			state = State.RELEARNING
			step = 0
			interval_sec = RELEARNING_STEPS[0]
		else:
			interval_sec = _next_interval_days(stab) * DAY
	else:
		var steps: Array[int] = LEARNING_STEPS if state == State.LEARNING else RELEARNING_STEPS
		if state == State.LEARNING and (stab <= 0.0 or diff <= 0.0):
			stab = _initial_stability(rating)
			diff = _initial_difficulty(rating, true)
		else:
			stab = _updated_stability(stab, diff, rating, c, now, has_last, days_since)
			diff = _next_difficulty(diff, rating)
		if steps.is_empty() or (step >= steps.size() and rating != Rating.AGAIN):
			state = State.REVIEW
			step = 0
			interval_sec = _next_interval_days(stab) * DAY
		else:
			match rating:
				Rating.AGAIN:
					step = 0
					interval_sec = steps[0]
				Rating.HARD:
					if step == 0 and steps.size() == 1:
						interval_sec = steps[0] * 1.5
					elif step == 0:
						interval_sec = (steps[0] + steps[1]) / 2.0
					else:
						interval_sec = steps[step]
				Rating.GOOD:
					if step + 1 == steps.size():
						state = State.REVIEW
						step = 0
						interval_sec = _next_interval_days(stab) * DAY
					else:
						step += 1
						interval_sec = steps[step]
				_: # EASY
					state = State.REVIEW
					step = 0
					interval_sec = _next_interval_days(stab) * DAY

	if fuzz and state == State.REVIEW:
		interval_sec = _fuzzed_days(floori(interval_sec / DAY)) * DAY
	c["state"] = state
	c["stability"] = stab
	c["difficulty"] = diff
	c["step"] = step
	c["due"] = now + int(round(interval_sec))
	c["last_review"] = now
	c["reps"] = int(c["reps"]) + 1
	return c


## Cards that would result from each rating, keyed 1..4 (fuzz off, so shown intervals are stable).
static func preview(card: Dictionary, now: int) -> Dictionary:
	var out := {}
	for r in [1, 2, 3, 4]:
		out[r] = review(card, r, now, false)
	return out


## Probability of recall at time `now` (0 for cards without memory state).
static func retrievability(card: Dictionary, now: int) -> float:
	var last: int = int(card.get("last_review", 0))
	var stab: float = float(card.get("stability", 0.0))
	if last <= 0 or stab <= 0.0:
		return 0.0
	return _retrievability(stab, maxi(0, floori(float(now - last) / DAY)))


# ---------------------------------------------------------------- formulas

static func _decay() -> float:
	return -PARAMETERS[20]


static func _factor() -> float:
	return pow(0.9, 1.0 / _decay()) - 1.0


static func _retrievability(stab: float, elapsed_days: int) -> float:
	return pow(1.0 + _factor() * elapsed_days / stab, _decay())


static func _updated_stability(stab: float, diff: float, rating: int, c: Dictionary, now: int, has_last: bool, days_since: int) -> float:
	if has_last and days_since < 1:
		return _short_term_stability(stab, rating)
	var elapsed: int = maxi(0, floori(float(now - int(c["last_review"])) / DAY)) if has_last else 0
	return _next_stability(diff, stab, _retrievability(stab, elapsed), rating)


static func _initial_stability(rating: int) -> float:
	return maxf(PARAMETERS[rating - 1], STABILITY_MIN)


static func _initial_difficulty(rating: int, clamp_it: bool) -> float:
	var d: float = PARAMETERS[4] - exp(PARAMETERS[5] * (rating - 1)) + 1.0
	return clampf(d, 1.0, 10.0) if clamp_it else d


## Python's round() is half-to-even; match it so intervals are identical.
static func _round_half_even(x: float) -> int:
	var f: float = floorf(x)
	var frac: float = x - f
	if frac < 0.5:
		return int(f)
	if frac > 0.5:
		return int(f) + 1
	return int(f) if int(f) % 2 == 0 else int(f) + 1


static func _next_interval_days(stab: float) -> int:
	var ivl: float = (stab / _factor()) * (pow(DESIRED_RETENTION, 1.0 / _decay()) - 1.0)
	return mini(maxi(_round_half_even(ivl), 1), MAXIMUM_INTERVAL)


static func _short_term_stability(stab: float, rating: int) -> float:
	var inc: float = exp(PARAMETERS[17] * (rating - 3 + PARAMETERS[18])) * pow(stab, -PARAMETERS[19])
	if rating >= Rating.HARD:
		inc = maxf(inc, 1.0)
	return maxf(stab * inc, STABILITY_MIN)


static func _next_difficulty(diff: float, rating: int) -> float:
	var arg1: float = _initial_difficulty(Rating.EASY, false)
	var delta: float = -(PARAMETERS[6] * (rating - 3))
	var arg2: float = diff + (10.0 - diff) * delta / 9.0
	return clampf(PARAMETERS[7] * arg1 + (1.0 - PARAMETERS[7]) * arg2, 1.0, 10.0)


static func _next_stability(diff: float, stab: float, retr: float, rating: int) -> float:
	var s: float
	if rating == Rating.AGAIN:
		var long_term: float = PARAMETERS[11] * pow(diff, -PARAMETERS[12]) \
			* (pow(stab + 1.0, PARAMETERS[13]) - 1.0) * exp((1.0 - retr) * PARAMETERS[14])
		var short_term: float = stab / exp(PARAMETERS[17] * PARAMETERS[18])
		s = minf(long_term, short_term)
	else:
		var hard_penalty: float = PARAMETERS[15] if rating == Rating.HARD else 1.0
		var easy_bonus: float = PARAMETERS[16] if rating == Rating.EASY else 1.0
		s = stab * (1.0 + exp(PARAMETERS[8]) * (11.0 - diff) * pow(stab, -PARAMETERS[9]) \
			* (exp((1.0 - retr) * PARAMETERS[10]) - 1.0) * hard_penalty * easy_bonus)
	return maxf(s, STABILITY_MIN)


static func _fuzzed_days(days: int) -> int:
	if days < 2.5:
		return days
	var delta := 1.0
	for fr in FUZZ_RANGES:
		delta += float(fr[2]) * maxf(minf(float(days), float(fr[1])) - float(fr[0]), 0.0)
	var max_ivl: int = mini(_round_half_even(days + delta), MAXIMUM_INTERVAL)
	var min_ivl: int = mini(maxi(2, _round_half_even(days - delta)), max_ivl)
	var r: float = fuzz_override if fuzz_override >= 0.0 else randf()
	return mini(_round_half_even(r * (max_ivl - min_ivl + 1) + min_ivl), MAXIMUM_INTERVAL)


# ---------------------------------------------------------------- display

## "10분", "3시간", "1일", "3개월", "1.2년" for an interval in seconds.
static func format_interval(sec: int) -> String:
	if sec < 3600:
		return "%d분" % maxi(1, roundi(sec / 60.0))
	if sec < DAY:
		return "%d시간" % roundi(sec / 3600.0)
	var days: int = roundi(sec / float(DAY))
	if days < 30:
		return "%d일" % days
	if days < 365:
		return "%d개월" % roundi(days / 30.0)
	return "%.1f년" % (days / 365.0)
