class_name KanaTypeBox
extends VBoxContainer
## 가나 입력 문제 한 칸(보기 없음): 글자 소리를 로마자나 한글로 쓰는 입력창 + [확인] 버튼.
## docs/v160_fun_design.md §4.2. 채점은 KanaTyping(KanaScreen 이 부른다) — 이 상자는 글만 받아서 `submitted` 로 알린다.
##   입력창 높이 >= 56, 확인 버튼 높이 >= 56 (폰). 입력창에서 Enter 도 확인. 빈 칸에서는 아무 일도 하지 않는다.
##   한 번 제출하면 잠겨서(lock) 같은 문제에 두 번 제출되지 않는다. 모를 때는 [모르겠어요]로 넘어간다(틀림으로 센다, `skipped` 신호).

signal submitted(text: String)
signal skipped

const PLACEHOLDER := "로마자 또는 한글로"
const MAX_LEN := 16
const EDIT_MIN_H := 56.0
const BUTTON_MIN_H := 56.0

var edit: LineEdit = null
var confirm: Button = null
var skip: Button = null
var locked: bool = false


func _init(accent: Color = Pal.JA) -> void:
	add_theme_constant_override("separation", 10)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name = "KanaTypeBox"
	edit = LineEdit.new()
	edit.name = "TypeEdit"
	edit.placeholder_text = PLACEHOLDER
	edit.max_length = MAX_LEN
	edit.custom_minimum_size = Vector2(0, EDIT_MIN_H)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.add_theme_font_size_override("font_size", UI.fs(24))
	edit.text_changed.connect(_on_text_changed)
	edit.text_submitted.connect(func(_t: String) -> void: submit())
	add_child(edit)
	confirm = SpeakDrill.touch_button("확인", "primary", accent, BUTTON_MIN_H)
	confirm.name = "TypeConfirm"
	confirm.custom_minimum_size.y = maxf(confirm.custom_minimum_size.y, BUTTON_MIN_H)
	confirm.disabled = true
	confirm.pressed.connect(submit)
	add_child(confirm)
	skip = SpeakDrill.touch_button("모르겠어요", "outline", accent, 48)
	skip.name = "TypeSkip"
	skip.pressed.connect(give_up)
	add_child(skip)


func text() -> String:
	return edit.text if edit != null else ""


## 입력창에 글자를 넣는다(시험용). text_changed 신호는 코드로 바꿀 때 오지 않으므로 버튼 상태를 직접 맞춘다.
func set_text(t: String) -> void:
	edit.text = t
	_on_text_changed(t)


func _on_text_changed(t: String) -> void:
	if confirm != null:
		confirm.disabled = locked or t.strip_edges() == ""


## 입력이 비어 있거나 이미 제출했으면 false. 아니면 잠그고 `submitted` 를 보낸다.
func submit() -> bool:
	if locked or edit == null or edit.text.strip_edges() == "":
		return false
	locked = true
	edit.editable = false
	confirm.disabled = true
	submitted.emit(edit.text)
	return true


## [모르겠어요]: 이미 제출했으면 false. 아니면 잠그고 `skipped` 를 보낸다(화면은 빈 글 제출과 같게 틀림으로 세고 정답을 보여 준다).
func give_up() -> bool:
	if locked:
		return false
	locked = true
	if edit != null:
		edit.editable = false
	if confirm != null:
		confirm.disabled = true
	skipped.emit()
	return true


## 답을 보여 주는 단계: 입력창을 잠그고 확인 버튼을 숨긴다(정답·인정 답은 화면이 따로 보여 준다).
func lock() -> void:
	locked = true
	if edit != null:
		edit.editable = false
	if confirm != null:
		confirm.disabled = true
		confirm.visible = false
	if skip != null:
		skip.visible = false


## 입력창에 커서를 둔다(폰은 키보드가 올라온다). 화면 트리에 들어간 뒤에만.
func focus_edit() -> void:
	if edit != null and is_inside_tree() and not locked:
		edit.grab_focus()
