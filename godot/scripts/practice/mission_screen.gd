# T4 가 구현할 뼈대 (지금은 신호와 메서드 모양만 있음). 허브(PracticeView)가 add_child 하고 closed 를 받는다.
class_name MissionScreen
extends Control
## 롤플레이 미션 화면. 계약: 설계 8.3 (open(lang, args), 선택 on_hide()). 몸체는 T4 에서 채운다.

signal closed


@warning_ignore_start("unused_parameter")
func open(lang: String, args: Dictionary = {}) -> void:
	pass


func on_hide() -> void:
	pass
@warning_ignore_restore("unused_parameter")
