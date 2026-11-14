class_name BadgeDefs
extends RefCounted
## 업적 배지 25개의 정의(docs/v160_fun_design.md §5.5 의 23개 + v1.7.0 일기 배지 2개, docs/v170_design.md Q6). 이름·설명·조건·목표 숫자는 전부 이 파일 한 곳에 있다.
## 판정은 BadgeRules(스냅샷 사전 하나만 읽는 순수 계산), 저장은 StudyLog.badges(받으면 영구), 평가는 BadgeEngine.
## 항목: {id, name, desc, cat, measure, target, glyph}. measure = 스냅샷 키(BadgeRules.MEASURES), glyph = GlyphIcon 도형 이름.
## 목표 숫자는 출시 뒤 조정할 수 있는 상수다(speed_score_500 · streak_30 · time_10h 등).
## 새 배지를 더하는 것은 괜찮지만 id 를 바꾸거나 지우지 말 것: 이미 받은 기록(studylog.badges.got)이 그 id 를 가리킨다.

const CATEGORIES := [["habit", "습관"], ["learn", "레슨·복습"], ["speak", "말하기"], ["song", "노래"], ["kana", "가나"], ["speed", "스피드"]]

## kana_hira / kana_kata 가 세는 청음 글자 수와 kana_all 의 글자 수(KanaData 표와 같아야 한다: 시험이 대조)
const SEION_COUNT := 46
const KANA_ALL_COUNT := 208

static var _all: Array = []
static var _pair_letters: Array = []


## 25개, 표 순서. 복사본이라 고쳐도 원본은 그대로.
static func all() -> Array:
	_build()
	return _all.duplicate(true)


static func by_id(id: String) -> Dictionary:
	_build()
	for d in _all:
		if (d as Dictionary)["id"] == id:
			return (d as Dictionary).duplicate(true)
	return {}


static func has(id: String) -> bool:
	_build()
	for d in _all:
		if (d as Dictionary)["id"] == id:
			return true
	return false


static func ids() -> Array:
	_build()
	var out: Array = []
	for d in _all:
		out.append((d as Dictionary)["id"])
	return out


static func categories() -> Array:
	return CATEGORIES.duplicate(true)


## KanaCourse.pairs() 에 나오는 서로 다른 글자 수(= kana_pairs 배지의 목표).
static func pair_letter_count() -> int:
	return pair_letters().size()


static func pair_letters() -> Array:
	if _pair_letters.is_empty():
		var seen := {}
		for p in KanaCourse.pairs("both"):
			seen[str((p as Dictionary).get("a", ""))] = true
			seen[str((p as Dictionary).get("b", ""))] = true
		seen.erase("")
		_pair_letters = seen.keys()
	return _pair_letters.duplicate()


static func _d(id: String, name: String, desc: String, cat: String, measure: String, target: int, glyph: String) -> Dictionary:
	return {"id": id, "name": name, "desc": desc, "cat": cat, "measure": measure, "target": target, "glyph": glyph}


static func _build() -> void:
	if not _all.is_empty():
		return
	_all = [
		_d("first_lesson", "첫 레슨", "레슨을 처음으로 끝냈어요.", "learn", "lessons_total", 1, "star"),
		_d("lessons_10", "레슨 10번", "레슨을 10번 끝냈어요.", "learn", "lessons_total", 10, "star"),
		_d("lessons_50", "레슨 50번", "레슨을 50번 끝냈어요.", "learn", "lessons_total", 50, "star"),
		_d("first_talk", "첫 원어민 대화", "원어민과 처음으로 대화를 나눴어요.", "speak", "talks_total", 1, "record"),
		_d("cards_20", "복습 카드 20장", "복습 카드를 20장 모았어요.", "learn", "cards_count", 20, "sparkle"),
		_d("reviews_100", "복습 100번", "복습을 100번 했어요.", "learn", "reviews_total", 100, "check"),
		_d("streak_3", "3일 연속", "3일 연속으로 공부했어요.", "habit", "streak_best", 3, "sparkle"),
		_d("streak_7", "7일 연속", "7일 연속으로 공부했어요.", "habit", "streak_best", 7, "sparkle"),
		_d("streak_30", "30일 연속", "30일 연속으로 공부했어요.", "habit", "streak_best", 30, "sparkle"),
		_d("time_1h", "공부 1시간", "공부한 시간이 모두 합쳐 1시간이 되었어요.", "habit", "study_sec_total", 3600, "check"),
		_d("time_10h", "공부 10시간", "공부한 시간이 모두 합쳐 10시간이 되었어요.", "habit", "study_sec_total", 36000, "check"),
		_d("mission_star3", "미션 별 3개", "미션 하나에서 별 3개를 받았어요.", "speak", "mission_star3", 1, "star"),
		_d("mission_all_star3", "미션 8개 모두 별 3개", "한 언어의 미션 8개 모두에서 별 3개를 받았어요.", "speak", "mission_all_star3", 8, "star"),
		_d("pron_80", "발음 80점", "하루 평균 발음 점수가 80점 이상이었어요. (그날 3번 이상 채점)", "speak", "pron_day_best", 80, "record"),
		_d("song_first", "첫 가사 등록", "가사를 처음으로 등록했어요.", "song", "song_lyrics", 1, "play"),
		_d("song_done", "가사 한 곡 다 외움", "가사 한 곡(4줄 이상)을 줄마다 다 외웠어요.", "song", "song_done", 1, "play"),
		_d("kana_hira", "히라가나 청음 마스터", "히라가나 기본 글자 46개를 모두 익혔어요.", "kana", "kana_hira_seion", SEION_COUNT, "sparkle"),
		_d("kana_kata", "가타카나 청음 마스터", "가타카나 기본 글자 46개를 모두 익혔어요.", "kana", "kana_kata_seion", SEION_COUNT, "sparkle"),
		_d("kana_all", "가나 전부 숙련", "히라가나와 가타카나 208글자를 모두 익혔어요.", "kana", "kana_all", KANA_ALL_COUNT, "star"),
		_d("kana_pairs", "헷갈리는 글자 극복", "헷갈리는 짝에 나오는 글자를 모두 익혔어요.", "kana", "kana_pairs", pair_letter_count(), "check"),
		_d("speed_first", "첫 스피드 퀴즈", "60초 스피드 퀴즈를 처음으로 풀었어요.", "speed", "speed_plays", 1, "play"),
		_d("speed_combo_10", "콤보 10", "스피드 퀴즈에서 10개를 연속으로 맞혔어요.", "speed", "speed_combo", 10, "sparkle"),
		_d("speed_score_500", "스피드 500점", "스피드 퀴즈에서 500점을 넘겼어요.", "speed", "speed_score", 500, "star"),
		_d("diary_first", "첫 일기 고침", "한 줄 일기를 처음으로 고쳐 봤어요.", "learn", "diary_fixed", 1, "check"),
		_d("diary_7", "일기 7일", "서로 다른 7일에 일기를 썼어요.", "learn", "diary_days", 7, "sparkle"),
	]
