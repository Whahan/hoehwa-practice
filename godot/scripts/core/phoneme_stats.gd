# T1 이 구현할 뼈대 (지금은 몸체가 기본값만 돌려줌). 음소 집계 순수 함수.
class_name PhonemeStats
extends RefCounted
## 음소별 틀림 집계 순수 함수. 상태(stats)는 Dictionary 로 받고, 바꾸지 않는 것을 원칙으로 한다 (T1 구현).


@warning_ignore_start("unused_parameter")
static func blank() -> Dictionary:
	return {}


static func observe(stats: Dictionary, res: Dictionary) -> int:
	return 0


static func weakest(stats: Dictionary, limit: int, min_n: int) -> Array:
	return []
@warning_ignore_restore("unused_parameter")
