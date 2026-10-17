# T1 이 구현할 뼈대 (지금은 몸체가 기본값만 돌려줌). 공개 함수 시그니처는 설계 8.4 와 같다.
class_name StudyLog
extends RefCounted
## 학습 기록 저장소 (user://studylog.json). 기존 progress.json 은 건드리지 않는다.
## 정적 API 만 쓴다. 파일 깨짐 시 .bad 로 옮기고 빈 상태로 시작한다 (T1 구현).

static var path := "user://studylog.json"


@warning_ignore_start("unused_parameter")
static func reload() -> void:
	pass


static func flush() -> bool:
	return false


static func reset() -> void:
	pass


static func add_seconds(lang: String, view: String, sec: int) -> void:
	pass


static func add_event(lang: String, kind: String, n: int = 1) -> void:
	pass


static func add_lesson(lang: String, ok: int, total: int) -> void:
	pass


static func add_score(lang: String, res: Dictionary, source: String) -> bool:
	return false


static func add_mission(lang: String, id: String, stars: int, done_goals: int) -> void:
	pass


static func mission_best(id: String) -> Dictionary:
	return {}


static func goal_minutes() -> int:
	return 0


static func set_goal_minutes(m: int) -> void:
	pass


static func today_seconds(lang: String) -> int:
	return 0


static func settle(lang: String) -> Dictionary:
	return {}


static func streak(lang: String) -> int:
	return 0


static func tokens(lang: String) -> int:
	return 0


static func range_summary(lang: String, days: int) -> Array:
	return []


static func weak_phonemes(lang: String, limit: int, min_n: int = 5) -> Array:
	return []
@warning_ignore_restore("unused_parameter")
