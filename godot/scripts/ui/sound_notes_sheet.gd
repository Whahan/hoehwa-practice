class_name SoundNotesSheet
extends RefCounted
## v2.0.1 F1 (docs/v201_design.md §2.9): "알파벳·모음 소리" 시트. 주의 소리 노트마다 한 행(영어 + 설명)과, 읽을 글이 있으면 [듣기] 버튼.
## 버튼 노드 이름은 SoundPlay_<노트 id> (화면에는 id 를 보이지 않는다). 소리는 기본 Tts.speak(글, "en").

const TITLE := "알파벳·모음 소리"
const HINT := "앱 소리는 합성음이에요. 짧은 모음은 예시 낱말로 들려줘요."
const PLAY_MIN_H := 44.0

## 시험: Callable(text, lang) -> void. 비어 있으면 Tts.speak.
static var speak_hook: Callable = Callable()


static func open(host: Node, w: int) -> Node:
	var body := _body(w)
	var sh := Sheet.open(host, TITLE, body, [{"id": "close", "text": "닫기", "kind": "flat"}])
	sh.closed.connect(func(_r: Variant) -> void: Tts.stop())
	return sh


static func _body(w: int) -> Control:
	var col := UI.vbox(10)
	col.name = "SoundNotes"
	col.add_child(UI.label(HINT, "Muted"))
	for note in CourseSoundNotes.notes_for_week(w):
		col.add_child(_row(note))
	UI.fix_cjk(col)
	return col


static func _row(note: Dictionary) -> Control:
	var id: String = str(note.get("id", ""))
	var speak: String = str(note.get("speak", ""))
	var row := UI.hbox(10)
	row.name = "SoundRow_%s" % id
	var txt := UI.vbox(2)
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var en: String = str(note.get("en", ""))
	if en != "":
		var l := UI.label(en)
		l.add_theme_font_override("font", UI.bold_font())
		txt.add_child(l)
	var ko: String = UI.plain(note.get("text_ko", ""))
	if ko != "":
		txt.add_child(UI.label(ko, "Small"))
	row.add_child(txt)
	if speak != "":
		var b := UI.button("듣기", "soft", Pal.PRIMARY, PLAY_MIN_H)
		b.name = "SoundPlay_%s" % id
		b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, PLAY_MIN_H)
		b.size_flags_horizontal = Control.SIZE_SHRINK_END
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.pressed.connect(func() -> void: _speak(speak))
		row.add_child(b)
	return row


static func _speak(text: String) -> void:
	if speak_hook.is_valid():
		speak_hook.call(text, "en")
	else:
		Tts.speak(text, "en")
