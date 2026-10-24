class_name CapabilityPanel
extends VBoxContainer
## 설정(폰)의 "기능 현황": Route.caps()의 기능 16개를 한 줄씩 보여 준다
## (docs/phone_standalone_design.md §4.6, §5.3). 기능 이름(한국어) / 지금 쓰는 곳(폰·PC·없음) / 없음이면 이유 한 줄.
##
## 이 패널은 판단하지 않는다: 어디서 처리하는지는 Route.caps()가 정한다. 모드·PC 연결·음성 엔진이 바뀌면
## (Route.mode_changed, Backend.status_changed, 화면이 다시 보일 때, 호출자의 refresh()) 다시 그린다.

## Capability key -> name shown to the user. One entry per Route.CAP_KEYS item.
const NAMES := {
	"lesson": "레슨",
	"lesson_ai": "AI 레슨 만들기",
	"practice": "받아쓰기·쉐도잉 문장",
	"missions": "미션 대본 대화",
	"missions_judge": "미션 AI 판정",
	"reading": "읽기 분석",
	"gloss": "단어 뜻풀이",
	"examples": "예문 찾기",
	"stt": "음성 인식",
	"score": "발음 채점",
	"phoneme": "음소 분석",
	"prosody": "억양 비교",
	"tts": "소리 내어 읽어 주기",
	"chat": "원어민 대화",
	"fix": "문장 교정",
	"feedback": "말하기 피드백",
}
## `use` value -> the word in the chip, and the chip colour kind (UI.chip_kind).
const USE_TEXT := {"phone": "폰", "pc": "PC", "none": "없음"}
const USE_KIND := {"phone": "ok", "pc": "info", "none": "neutral"}
## Route.mode -> name shown in the settings.
const MODE_NAMES := {"auto": "자동", "phone": "이 폰에서만", "pc": "PC에서만"}
## One short Korean line per reason (`why` of a `none` row); anything else falls back to Route.text_for().
const REASONS := {
	"not_on_phone": "PC에 연결하면 쓸 수 있어요.",
	"needs_pc": "PC에 연결하면 쓸 수 있어요.",
	"not_connected": "PC에 연결되어 있지 않아요. 위의 PC 연결에서 연결해 주세요.",
	"pack_missing": "폰 안의 학습 데이터가 없어요. 앱을 다시 설치해 주세요.",
	"pack_corrupt": "폰 안의 학습 데이터가 손상됐어요. 앱을 다시 설치해 주세요.",
	"model_missing": "음성 인식 모델을 내려받으면 폰에서 쓸 수 있어요. PC에 연결해도 돼요.",
	"model_corrupt": "음성 인식 모델이 손상됐어요. 다시 내려받아 주세요.",
	"engine_missing": "이 앱에는 폰 음성 인식이 없어요. PC에 연결하면 쓸 수 있어요.",
	"no_ai": "AI 연결이 필요해요. PC에 연결하거나 AI 키를 넣어 주세요.",
	"no_voice": "이 폰에 쓸 수 있는 음성이 없어요. 폰 설정에서 음성 데이터를 내려받아 주세요.",
	"no_permission": "마이크 권한이 없어요. 폰 설정에서 마이크를 허용해 주세요.",
	"ja_reading_pc": "일본어 글 분석은 아직 PC에서만 돼요.",
}
const PHONE_ONLY_TEXT := "이 폰에서만 처리하도록 해 두어서 꺼져 있어요. 처리 위치를 바꾸면 PC를 써요."

var summary_label: Label
## key -> {use: String, name: String, reason: String, name_label: Label, use_label: Label, reason_label: Label (or null)}
var rows: Dictionary = {}

var _list: VBoxContainer
var _title: Label


func _init() -> void:
	add_theme_constant_override("separation", 8)


func _ready() -> void:
	_title = UI.label("기능 현황", "ListMain", false)
	add_child(_title)
	summary_label = UI.label("", "Small")
	add_child(summary_label)
	_list = UI.vbox(0)
	add_child(_list)
	Route.mode_changed.connect(_on_route_changed)
	Backend.status_changed.connect(refresh)
	visibility_changed.connect(_on_visibility)
	refresh()


func _on_route_changed(_m: String) -> void:
	refresh()


func _on_visibility() -> void:
	if is_visible_in_tree():
		refresh()


## The sentence under a `none` row: the mode-specific one first (PC would do it, but "이 폰에서만" is on), then the
## reason code's short text, then the long text of Route.
static func reason_text(item: Dictionary, mode: String) -> String:
	if mode == "phone" and bool(item.get("pc", false)) and not bool(item.get("phone", false)):
		return PHONE_ONLY_TEXT
	var why: String = str(item.get("why", ""))
	if REASONS.has(why):
		return str(REASONS[why])
	return Route.text_for(why)


## Redraws the 16 rows from Route.caps().
func refresh() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var caps: Dictionary = Route.caps()
	var items: Dictionary = caps.get("items", {}) as Dictionary
	var mode: String = str(caps.get("mode", "auto"))
	var pcinfo: Dictionary = caps.get("pc", {}) as Dictionary
	var connected: bool = bool(pcinfo.get("connected", false))
	summary_label.text = "처리 위치: %s · PC %s" % [str(MODE_NAMES.get(mode, mode)), "연결됨" if connected else "연결 안 됨"]
	UI.clear(_list)
	rows = {}
	var first := true
	for k in Route.CAP_KEYS:
		var item: Dictionary = items.get(k, {}) as Dictionary
		if not first:
			_list.add_child(UI.hline())
		first = false
		_list.add_child(_row(str(k), item, mode))
	UI.fix_cjk(_list)


func _row(key: String, item: Dictionary, mode: String) -> Control:
	var use: String = str(item.get("use", "none"))
	if not USE_TEXT.has(use):
		use = "none"
	var box := UI.vbox(2)
	var pad := UI.margin(box, 0, 8, 0, 8)
	var line := UI.hbox(8)
	var name_label := UI.label(str(NAMES.get(key, key)), "ListMain")
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(name_label)
	var chip := UI.chip_kind(str(USE_TEXT[use]), str(USE_KIND[use]))
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(chip)
	box.add_child(line)
	var entry := {"use": use, "name": str(NAMES.get(key, key)), "reason": "", "name_label": name_label,
		"use_label": chip.get_child(0) as Label, "reason_label": null}
	if use == "none":
		var reason: String = reason_text(item, mode)
		var rl := UI.label(reason, "ListSub")
		box.add_child(rl)
		entry["reason"] = reason
		entry["reason_label"] = rl
	rows[key] = entry
	return pad
