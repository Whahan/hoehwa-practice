class_name SyncChoiceDialog
extends CanvasLayer
## 첫 연결 때 한 번 묻는 대화상자 (설계 docs/sync_design.md §4.8.1, §6.3): "PC와 학습 기록을 합칠까요?" [합치기] [따로 쓰기].
## PC 앱은 제목만 "폰과 …" 로 바뀐다. 문구는 모두 SyncPanel 의 상수다(한 곳에서 관리).
##
## 화면 전체를 덮는 겹침 화면이다(안드로이드에서도 같은 모양: 별도 Window 를 쓰지 않는다). 버튼은 BaseButton 이라 터치 스크롤과 충돌하지 않는다.
## 선택은 SyncManager.choose() 가 엔진의 set_choice() 로 넘긴다. 선택이 저장되면(엔진이 더는 묻지 않으면) 스스로 닫는다.
## 닫기 버튼은 없다: 합치기와 따로 쓰기 중 하나를 골라야 한다. 폰이 PC 에 닿지 않아도 선택은 저장되고 동기화는 나중에 이어진다.

signal closed

var manager: SyncManager = null
var kind: String = "phone" ## "phone" | "pc" — 어느 쪽 앱에서 묻는가(제목이 달라진다)

var title_label: Label
var body_label: Label
var merge_button: Button
var separate_button: Button
var error_label: Label
var _busy: bool = false


func _init() -> void:
	layer = 28 ## 연결 화면(25) 위, 토스트(30) 아래


func _ready() -> void:
	var root := PanelContainer.new()
	root.theme_type_variation = &"Sunk"
	root.self_modulate.a = 0.92
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP ## 뒤 화면이 눌리지 않게
	add_child(root)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(center)
	var card := UI.card("BigCard", 14)
	card.custom_minimum_size.x = clampf(root.get_viewport_rect().size.x - 32.0, 280.0, 460.0)
	center.add_child(card)
	title_label = UI.label(SyncPanel.dialog_title(kind), "H2")
	card.body.add_child(title_label)
	body_label = UI.label(SyncPanel.DIALOG_BODY)
	card.body.add_child(body_label)
	error_label = UI.label("", "Small")
	error_label.visible = false
	card.body.add_child(error_label)
	var row := UI.flow(8, 8)
	merge_button = UI.button(SyncPanel.BTN_MERGE, "primary")
	merge_button.pressed.connect(func() -> void: _pick("merge"))
	row.add_child(merge_button)
	separate_button = UI.button(SyncPanel.BTN_SEPARATE, "default")
	separate_button.pressed.connect(func() -> void: _pick("separate"))
	row.add_child(separate_button)
	card.body.add_child(row)


func _exit_tree() -> void:
	closed.emit()


## 버튼이 부르는 곳(시험도 직접 부른다). 선택을 저장하고, 합치기면 첫 동기화까지 한 뒤 닫는다.
func _pick(choice: String) -> void:
	if _busy or manager == null:
		return
	_busy = true
	merge_button.disabled = true
	separate_button.disabled = true
	error_label.visible = true
	error_label.text = SyncPanel.DIALOG_WORKING if choice == "merge" else ""
	var res: Dictionary = await manager.choose(choice)
	if not is_inside_tree():
		return
	_busy = false
	var still: bool = manager.engine != null and manager.engine.needs_choice()
	if not still:
		queue_free()
		return
	# 저장하지 못했다: 다시 고를 수 있게 둔다
	merge_button.disabled = false
	separate_button.disabled = false
	error_label.visible = true
	error_label.text = SyncPanel.error_text(res)
