class_name WeekReport
extends RefCounted
## 주간 리포트 계산(순수 함수). 이번 주(오늘 포함 7일)와 지난 주(그 앞 7일)를 견줘 한 장 카드용 숫자와 규칙 문구를 만든다.
##
## 입력은 StudyLog.range_summary(lang, 14) 항목(오래된 순)을 7개씩 나눈 두 배열이다:
##   {iso, sec, lessons_ok, lessons_n, score_n, score_sum, n{lessons, reviews, newcards, shadow, dictation, drill, ...}}
## build() 는 파일·노드·StudyLog·Store 를 읽거나 쓰지 않고, 입력 배열도 바꾸지 않는다.
## 항목이 모자라거나(7개 미만) 더 많아도(마지막 7개만 씀) 모양이 틀려도(숫자 아님·음수·NaN·INF·문자열·null) 에러 없이 0 으로 센다.
## for_lang() 만 StudyLog 를 읽는다(읽기 전용).
##
## 결과 사전의 숫자는 모두 정수이고, "없음" = -1 (score_delta 는 null 일 수 있다).
##   lang, from, to (iso. 모르면 ""), empty, days_studied (0..7),
##   minutes / minutes_prev / minutes_delta, lessons / lessons_prev, lesson_acc / lesson_acc_prev,
##   new_cards / new_cards_prev, reviews / reviews_prev, practice,
##   score_avg / score_n / score_prev / score_prev_n / score_delta, lines (규칙 문구 최대 2줄)

const DAYS := 7
## 점수 평균을 두 주 사이에 견주려면 두 주 모두 이만큼은 있어야 한다(적은 표본으로 오르내림을 말하지 않는다).
const MIN_SCORE_N := 3
const LANGS := ["en", "ja"]
const MAX_SEC := 86400
const MAX_COUNT := 1000000
const PRACTICE_KINDS := ["shadow", "dictation", "drill"]

const LINE_EMPTY := "이번 주에는 아직 기록이 없어요. 오늘 10분만 해 볼까요?"


## cur / prev: 7개씩(오래된 순). to_iso 가 비었거나 날짜가 아니면 cur 항목의 가장 늦은 날짜를 쓴다.
static func build(cur: Variant, prev: Variant, lang: String = "en", to_iso: String = "") -> Dictionary:
	var c: Dictionary = _sum_week(cur)
	var p: Dictionary = _sum_week(prev)

	var to_s: String = ""
	if to_iso != "" and Plan.is_valid_iso(to_iso):
		to_s = to_iso
	else:
		to_s = str(c["latest"])
	var from_s: String = ""
	if to_s != "":
		from_s = Plan.days_to_iso(Plan.iso_to_days(to_s) - (DAYS - 1))

	var minutes: int = _minutes(int(c["sec"]))
	var minutes_prev: int = _minutes(int(p["sec"]))
	var lessons: int = int(c["lessons"])
	var new_cards: int = int(c["newcards"])
	var reviews: int = int(c["reviews"])
	var practice: int = int(c["practice"])
	var score_n: int = int(c["score_n"])
	var score_prev_n: int = int(p["score_n"])
	var score_avg: int = _ratio(int(c["score_sum"]), score_n)
	var score_prev: int = _ratio(int(p["score_sum"]), score_prev_n)

	var score_delta: Variant = null
	if score_n >= MIN_SCORE_N and score_prev_n >= MIN_SCORE_N:
		score_delta = score_avg - score_prev

	var empty: bool = int(c["sec"]) == 0 and lessons == 0 and new_cards == 0 and reviews == 0 and practice == 0

	var out := {
		"lang": lang if LANGS.has(lang) else "en",
		"from": from_s,
		"to": to_s,
		"empty": empty,
		"days_studied": int(c["days_studied"]),
		"minutes": minutes,
		"minutes_prev": minutes_prev,
		"minutes_delta": minutes - minutes_prev,
		"lessons": lessons,
		"lessons_prev": int(p["lessons"]),
		"lesson_acc": _ratio(100 * int(c["lessons_ok"]), int(c["lessons_n"])),
		"lesson_acc_prev": _ratio(100 * int(p["lessons_ok"]), int(p["lessons_n"])),
		"new_cards": new_cards,
		"new_cards_prev": int(p["newcards"]),
		"reviews": reviews,
		"reviews_prev": int(p["reviews"]),
		"practice": practice,
		"score_avg": score_avg,
		"score_n": score_n,
		"score_prev": score_prev,
		"score_prev_n": score_prev_n,
		"score_delta": score_delta,
	}
	out["lines"] = _lines(out)
	return out


## StudyLog.range_summary(lang, 14) 를 7개씩 나눠 build() 에 넘긴다. StudyLog 를 읽는 유일한 함수(읽기만 한다).
static func for_lang(lang: String) -> Dictionary:
	var all: Array = StudyLog.range_summary(lang, DAYS * 2)
	var n: int = all.size()
	var cur: Array = all.slice(maxi(0, n - DAYS), n)
	var prev: Array = all.slice(maxi(0, n - DAYS * 2), maxi(0, n - DAYS))
	return build(cur, prev, lang, Plan.days_to_iso(StudyLog.today()))


# ---------------------------------------------------------------- 문구 (§5.6)

static func _lines(r: Dictionary) -> Array:
	var lines: Array = []
	if bool(r["empty"]):
		lines.append(LINE_EMPTY)
		return lines
	var minutes: int = int(r["minutes"])
	var prev: int = int(r["minutes_prev"])
	if minutes > prev and prev > 0:
		lines.append("지난주보다 %d분 더 공부했어요." % (minutes - prev))
	elif minutes != 0 and minutes < prev:
		lines.append("지난주보다 %d분 적어요. 하루 10분만 더 해 볼까요?" % (prev - minutes))
	else:
		lines.append("이번 주 %d일 공부했어요." % int(r["days_studied"]))
	var d: Variant = r["score_delta"]
	if d != null and int(d) > 0:
		lines.append("발음 점수가 %d점 올랐어요." % int(d))
	return lines


# ---------------------------------------------------------------- 합산

## 한 주(최대 DAYS 항목, 뒤쪽 것 우선)를 청소해서 더한 값. 배열이 아니면 전부 0.
static func _sum_week(items: Variant) -> Dictionary:
	var t := {
		"sec": 0, "lessons": 0, "lessons_ok": 0, "lessons_n": 0, "newcards": 0, "reviews": 0,
		"practice": 0, "score_n": 0, "score_sum": 0, "days_studied": 0, "latest": "",
	}
	if not (items is Array):
		return t
	var arr: Array = items
	var start: int = maxi(0, arr.size() - DAYS)
	for i in range(start, arr.size()):
		var it: Variant = arr[i]
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var sec: int = _int(d.get("sec", 0), MAX_SEC)
		var les_n: int = _int(d.get("lessons_n", 0), MAX_COUNT)
		var les_ok: int = mini(_int(d.get("lessons_ok", 0), MAX_COUNT), les_n)
		var sc_n: int = _int(d.get("score_n", 0), MAX_COUNT)
		var sc_sum: int = mini(_int(d.get("score_sum", 0), MAX_COUNT * 100), sc_n * 100)
		var n_all: int = 0
		var nd: Variant = d.get("n", null)
		if nd is Dictionary:
			for k in (nd as Dictionary).keys():
				var x: int = _int((nd as Dictionary)[k], MAX_COUNT)
				n_all += x
				if k is String:
					match k:
						"lessons": t["lessons"] += x
						"newcards": t["newcards"] += x
						"reviews": t["reviews"] += x
						_:
							if PRACTICE_KINDS.has(k):
								t["practice"] += x
		t["sec"] += sec
		t["lessons_n"] += les_n
		t["lessons_ok"] += les_ok
		t["score_n"] += sc_n
		t["score_sum"] += sc_sum
		if sec > 0 or n_all > 0:
			t["days_studied"] += 1
		var iso: Variant = d.get("iso", null)
		if iso is String and Plan.is_valid_iso(iso) and (iso as String) > str(t["latest"]):
			t["latest"] = iso
	return t


## 0..hi 정수로 청소. 숫자가 아니거나(문자열·bool·null·배열) NaN·INF·음수면 0.
static func _int(v: Variant, hi: int) -> int:
	if v is int:
		return clampi(v, 0, hi)
	if v is float:
		if is_nan(v) or is_inf(v) or v <= 0.0:
			return 0
		return int(minf(v, float(hi)))
	return 0


static func _minutes(sec: int) -> int:
	return _ratio(sec, 60)


## round(a / b) 를 정수로(0.5 는 올림). b <= 0 이면 -1. 분 환산에서도 쓰므로 b 는 양수일 때만 호출된다.
@warning_ignore("integer_division")
static func _ratio(a: int, b: int) -> int:
	if b <= 0:
		return -1
	return (2 * a + b) / (2 * b)
