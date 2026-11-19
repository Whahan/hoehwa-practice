class_name CourseSoundNotes
extends RefCounted
## v2.0.1 F1 (docs/v201_design.md §2.9): 1주 소리 노트(알파벳 이름·짧은 모음)를 [듣기]로 읽을 글로 바꾼다. 정적 함수만.
##
## 노트에는 `say` 필드가 없다(린터가 막는다). 그래서 읽을 글은 원고의 글에서 규칙으로 뽑는다:
##   알파벳 노트  en = "A (ay)"            -> "ay"  (괄호 안 글자 이름. 발음 샘플의 알파벳 파일과 같은 글)
##   짧은 모음    en = "a", text_ko 끝 (cat, bag, hat) -> "cat, bag, hat" (고립 모음은 읽지 않는다)
##   그 밖(Z 는 zed 설명, 문화 노트, 모양이 다른 글)    -> "" (버튼 없음)
## H4b 에서 이상하게 읽히는 글자가 나오면 데이터 대신 SPEAK_OVERRIDE 에 한 줄 넣는다(지금은 비어 있다).

const SPEAK_OVERRIDE := {} ## id -> 읽을 글(비어 있지 않은 글만 쓴다)
const RE_VOWEL := "^[aeiou]$"
const RE_LETTER := "^[A-Z] \\(([a-z][a-z\\- ]*)\\)$"
const RE_EXAMPLES := "\\(([a-z]+(?:, [a-z]+)*)\\)\\s*$"
const KIND_SOUND := "sound"


## 주 w 의 소리 노트(kind == "sound")를 원래 순서대로: [{id, en, text_ko, speak}]. 읽을 글이 없으면 speak 는 "".
static func notes_for_week(w: int) -> Array:
	var out: Array = []
	var rec: Dictionary = CourseData.week(w)
	var notes: Variant = rec.get("notes", [])
	if not (notes is Array):
		return out
	for n in notes:
		if not (n is Dictionary):
			continue
		var d: Dictionary = n
		if _s(d.get("kind", "")) != KIND_SOUND:
			continue
		out.append({"id": _s(d.get("id", "")), "en": _s(d.get("en", "")), "text_ko": _s(d.get("text_ko", "")), "speak": speak_text(d)})
	return out


## 노트 하나의 읽을 글. 규칙에 맞지 않으면 "".
static func speak_text(note: Dictionary) -> String:
	if _s(note.get("kind", "")) != KIND_SOUND:
		return ""
	var id: String = _s(note.get("id", ""))
	if SPEAK_OVERRIDE.has(id) and str(SPEAK_OVERRIDE[id]).strip_edges() != "":
		return str(SPEAK_OVERRIDE[id]).strip_edges()
	var en: String = _s(note.get("en", ""))
	if en == "" or en.contains("\n"):
		return ""
	var m: String = _group(RE_LETTER, en)
	if m != "":
		return m
	if _matches(RE_VOWEL, en):
		var ko: String = _s(note.get("text_ko", ""))
		if ko.contains("\n"):
			return ""
		return _group(RE_EXAMPLES, ko)
	return ""


## 주 w 에서 [듣기]가 붙는 노트 수.
static func count_speakable(w: int) -> int:
	var n: int = 0
	for note in notes_for_week(w):
		if str((note as Dictionary)["speak"]) != "":
			n += 1
	return n


static func _s(v: Variant) -> String:
	return v if v is String else ""


static func _matches(pattern: String, s: String) -> bool:
	var rx := RegEx.new()
	if rx.compile(pattern) != OK:
		return false
	return rx.search(s) != null


## 정규식의 첫 괄호 묶음(없거나 맞지 않으면 "").
static func _group(pattern: String, s: String) -> String:
	var rx := RegEx.new()
	if rx.compile(pattern) != OK:
		return ""
	var m: RegExMatch = rx.search(s)
	if m == null:
		return ""
	return m.get_string(1).strip_edges()
