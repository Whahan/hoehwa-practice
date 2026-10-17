class_name FixCards
extends RefCounted
## F6: 대화에서 붙은 "더 자연스럽게" 문장을 복습 카드로 자동 추가한다.
## TalkView 에서는 `FixCards.add(lang, 메시지)` (가능하면 대화 id 도 같이) 한 줄만 부른다.
##
## - 설정 `auto_fix_cards`(기본 true)가 꺼져 있으면 아무것도 하지 않는다.
## - 고친 문장이 비었거나 원문과 (정규화하면) 같으면 추가하지 않는다.
## - 한 대화당 최대 MAX_PER_CONV 개. conv_id 를 안 주면 마지막 추가 후 CONV_GAP_SEC 초 안은 같은 대화로 본다.
## - 같은 문장은 Store.add_review 가 중복으로 거른다 (이때는 대화당 개수에도 세지 않는다).

const MAX_PER_CONV := 8
const CONV_GAP_SEC := 1800

static var _conv_key: String = ""
static var _conv_count: int = 0
static var _last_add_sec: int = 0


## msg: {text, fix, fix_ko}. Returns the number of cards added (0 or 1).
static func add(lang: String, msg: Dictionary, conv_id: String = "") -> int:
	if lang != "en" and lang != "ja":
		return 0
	if not bool(Store.prefs.get("auto_fix_cards", true)):
		return 0
	var fix: String = str(msg.get("fix", "")).strip_edges()
	if fix == "":
		return 0
	var text: String = str(msg.get("text", "")).strip_edges()
	if text != "" and TextSim.norm_text(fix, lang) == TextSim.norm_text(text, lang):
		return 0
	_roll_conversation(lang, conv_id)
	if _conv_count >= MAX_PER_CONV:
		return 0
	var note: String = str(msg.get("fix_ko", "")).strip_edges()
	if note == "" and text != "":
		note = "내가 말한 문장: " + text
	var added: int = Store.add_review([{"lang": lang, "target": fix, "reading": str(msg.get("fix_reading", "")), "ko": "", "note": note}])
	if added > 0:
		_conv_count += added
		_last_add_sec = int(Time.get_unix_time_from_system())
		Store.save_progress()
	return added


## Forget the per-conversation counter (tests, or when a new conversation starts).
static func reset_counter() -> void:
	_conv_key = ""
	_conv_count = 0
	_last_add_sec = 0


static func _roll_conversation(lang: String, conv_id: String) -> void:
	var now: int = int(Time.get_unix_time_from_system())
	var key: String = "%s|%s" % [lang, conv_id]
	var fresh: bool = key != _conv_key
	if conv_id == "" and not fresh and now - _last_add_sec > CONV_GAP_SEC:
		fresh = true
	if fresh:
		_conv_key = key
		_conv_count = 0
