class_name HomeAi
extends RefCounted
## 홈의 "AI 연결" 자리 한 칸. 홈과 메뉴는 slot() 만 읽고, 버튼은 Store.request_ai_connect() 만 부른다.
## 설치 설계자가 `provider` 를 채우면 기본 구현 대신 그 값을 쓴다(키 이름·길이 상한은 바꾸지 않는다). 설계: §9.6.
## 문구는 특정 AI 엔진 이름을 말하지 않는다(엔진 구성은 바뀔 수 있다).

const STATES := ["ready", "off", "llm_off", "needs_pairing", "not_installed"]
const TITLE_MAX := 24
const BODY_MAX := 60
const ACTION_MAX := 10
const DISMISS_PREF := "home_ai_dismiss_day"

## 설치 설계자가 넣는다. () -> Dictionary. 비어 있거나 무효이면 기본 구현.
static var provider: Callable = Callable()
## 시험 전용: 1 = 폰으로 취급, 0 = PC 로 취급, -1 = Platform.is_phone() 그대로.
static var force_phone: int = -1


static func _safe() -> Dictionary:
	return {"show": false, "state": "off", "title": "", "body": "", "action": "", "prominent": false, "dismissible": false}


## 홈이 그릴 값. provider 결과든 기본 구현이든 sanitize() 를 거친다.
static func slot() -> Dictionary:
	if provider.is_valid():
		return sanitize(provider.call())
	return sanitize(_default_slot())


## 어떤 값이 와도 §9.6 모양의 안전한 사전으로 만든다. 사전이 아니면 show=false.
## 제목·본문·버튼 글자가 길면 24·60·10자로 자른다. show 인데 제목이 비면 show=false.
static func sanitize(raw: Variant) -> Dictionary:
	var out: Dictionary = _safe()
	if not (raw is Dictionary):
		return out
	var d: Dictionary = raw
	var st: Variant = d.get("state", "off")
	out["state"] = st if (st is String and st in STATES) else "off"
	out["title"] = _text(d.get("title", ""), TITLE_MAX)
	out["body"] = _text(d.get("body", ""), BODY_MAX)
	out["action"] = _text(d.get("action", ""), ACTION_MAX)
	out["prominent"] = _flag(d.get("prominent", false))
	out["dismissible"] = _flag(d.get("dismissible", false))
	out["show"] = _flag(d.get("show", false)) and str(out["title"]) != ""
	return out # prominent 일 때 [나중에] 를 숨기는 것은 그리는 쪽 몫(§7.7)


static func _flag(v: Variant) -> bool:
	return v is bool and v


static func _text(v: Variant, max_chars: int) -> String:
	if not (v is String):
		return ""
	var t: String = (v as String).strip_edges()
	return t.substr(0, max_chars)


## 폰 단독 모드(main.gd standalone_badge 와 같은 판정): 폰이고 (PC 없이 시작을 골랐거나 처리 위치가 "이 폰에서만").
static func is_standalone() -> bool:
	var phone: bool = Platform.is_phone() if force_phone < 0 else force_phone == 1
	return phone and (bool(Store.prefs.get("standalone_ok", false)) or Route.normalize_mode(Route.mode) == "phone")


static func _default_slot() -> Dictionary:
	var action := "AI 연결하기"
	match Backend.status:
		Backend.Status.READY:
			if Backend.llm_missing():
				return {"show": true, "state": "llm_off", "title": "AI 답변이 꺼져 있어요", "body": "연결하면 대화와 AI 레슨을 쓸 수 있어요",
					"action": action, "prominent": false, "dismissible": true}
			return {"show": false, "state": "ready"}
		Backend.Status.FAILED:
			if is_standalone():
				return {"show": false, "state": "off"}
			return {"show": true, "state": "off", "title": "AI 연결 안 됨", "body": "대화와 AI 레슨은 연결 뒤에 쓸 수 있어요",
				"action": action, "prominent": false, "dismissible": true}
		Backend.Status.NEEDS_PAIRING:
			if is_standalone():
				return {"show": false, "state": "off"}
			return {"show": true, "state": "needs_pairing", "title": "PC 연결이 필요해요", "body": "대화와 AI 레슨은 연결 뒤에 쓸 수 있어요",
				"action": action, "prominent": false, "dismissible": true}
	return {"show": false, "state": "off"} # IDLE / CHECKING / STARTING: 스플래시가 덮고 있다


# ---------------------------------------------------------------- "나중에" (오늘 하루 숨김)

static func dismissed_today() -> bool:
	var v: Variant = Store.prefs.get(DISMISS_PREF, -1)
	if v is int:
		return v == StudyLog.today()
	if v is float and is_finite(v):
		return int(v) == StudyLog.today()
	return false


static func dismiss_today() -> void:
	Store.set_pref(DISMISS_PREF, StudyLog.today())
