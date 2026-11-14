class_name BadgeRules
extends RefCounted
## 배지 판정 규칙: 스냅샷 사전 하나만 읽는 순수 계산(Store/StudyLog/파일을 읽지 않는다). 시험이 가짜 스냅샷을 넣는다.
## 스냅샷 = {측정 이름: 정수}. 쓰레기 값(문자열·null·음수·NaN·INF·true·배열·키 없음)은 0 으로 본다 -> 배지를 잘못 주지 않는다.

const MAX_VALUE := 1000000000 ## 측정값 상한(깨진 값 방어)

## 스냅샷 키 전부(BadgeEngine.snapshot() 이 모두 만든다. BadgeDefs 의 measure 는 이 중 하나여야 한다)
const MEASURES := ["lessons_total", "talks_total", "streak_best", "study_sec_total", "reviews_total", "cards_count",
	"mission_star3", "mission_all_star3", "pron_day_best", "song_lyrics", "song_done",
	"kana_hira_seion", "kana_kata_seion", "kana_all", "kana_pairs", "speed_plays", "speed_combo", "speed_score",
	"diary_fixed", "diary_days"]

## "미션 8개 모두 별 3개" 가 세는 영어 미션 id(StatsView.MISSION_ORDER 와 같아야 한다: 시험이 대조)
const MISSION_IDS := ["cafe_order", "self_intro", "hotel_checkin", "ask_directions", "restaurant", "pharmacy_doctor", "return_item", "job_interview"]
## 일본어 미션 8개(StatsView.MISSION_ORDER_JA 와 같아야 한다: 시험이 대조). 배지는 "한 언어의 8개 모두"로 센다(영어 8 또는 일본어 8).
const MISSION_IDS_JA := ["ja_konbini", "ja_ramen", "ja_ask_way", "ja_hotel_checkin", "ja_station_ticket", "ja_clinic", "ja_shopping", "ja_self_intro"]


## 어떤 값이든 0..MAX_VALUE 정수로 청소한다. 정수와 유한한 실수만 숫자로 친다(bool·문자열·null·배열·NaN·INF 는 0).
static func clean(v: Variant) -> int:
	if v is bool:
		return 0
	if v is int:
		return clampi(v, 0, MAX_VALUE)
	if v is float and is_finite(v):
		return int(clampf(floorf(v), 0.0, float(MAX_VALUE)))
	return 0


## 스냅샷에서 측정값 하나. snap 이 사전이 아니거나 name 이 없으면 0.
static func measure(name: String, snap: Variant) -> int:
	if not (snap is Dictionary):
		return 0
	return clean((snap as Dictionary).get(name, 0))


## {"value", "target", "earned"}. def 가 사전이 아니거나 target 이 1 미만이면 earned = false(목표가 0 이하인 배지는 없다).
static func progress(def: Variant, snap: Variant) -> Dictionary:
	if not (def is Dictionary):
		return {"value": 0, "target": 0, "earned": false}
	var d: Dictionary = def
	var target: int = clean(d.get("target", 0))
	var value: int = measure(str(d.get("measure", "")), snap)
	return {"value": value, "target": target, "earned": target >= 1 and value >= target}


## 조건을 채운 모든 id (표 순서).
static func earned_ids(snap: Variant) -> Array:
	var out: Array = []
	for d in BadgeDefs.all():
		if bool(progress(d, snap)["earned"]):
			out.append((d as Dictionary)["id"])
	return out
