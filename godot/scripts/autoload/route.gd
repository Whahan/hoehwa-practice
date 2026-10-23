extends Node
## Route: decides, per request, where a feature runs — on the paired PC ("pc"), inside the phone ("phone")
## or nowhere ("none"). Design: docs/phone_standalone_design.md §4.2–4.3, §5.2–5.3.
##
## A0 (orchestrator): contract + POLICY table + error texts. The decision logic, `pc_flaky()` bookkeeping and
## `caps()` are implemented by A1 (route_test.gd). Until then every request keeps the old behaviour ("pc").
##
## Modes (prefs.route_mode): "auto" (PC first, phone when the PC is unreachable), "phone" (never talk to the
## PC), "pc" (old behaviour, phone handlers never used). Any other value is treated as "auto".

const MODES := ["auto", "phone", "pc"]
const DEFAULT_MODE := "auto"
const PREF_MODE := "route_mode"

## Seconds during which, after one transport failure in auto mode, requests skip the PC and go to the phone.
const FLAKY_SEC := 60.0
## Minimum seconds between two "PC에 닿지 않아 폰에서 처리했어요" toasts.
const FALLBACK_TOAST_SEC := 300.0

## Capability keys of `caps().items` (fixed set, §5.3).
const CAP_KEYS := ["lesson", "lesson_ai", "practice", "missions", "missions_judge", "reading", "gloss", "examples",
	"stt", "score", "phoneme", "prosody", "tts", "chat", "fix", "feedback"]

## Policy per (method, path without query). Missing entries mean "pc only" (old behaviour: /mic, /llm, /lan, /sync).
##   pc      : the PC backend serves this path (lan.py ALLOW)
##   phone   : LocalApi handler key ("" = no phone processing in stage 1)
##   prefer  : "pc" or "phone" — which side wins in auto mode when both are available
##   cap     : key in caps().items ("" = not shown)
## `POST /lesson` with body.source == "ai" is routed like the "lesson_ai" entry below (see `policy_for`).
const POLICY := {
	"GET /health": {"pc": true, "phone": "health", "prefer": "pc", "cap": ""},
	"GET /curriculum": {"pc": true, "phone": "curriculum", "prefer": "phone", "cap": ""},
	"POST /tts": {"pc": true, "phone": "", "prefer": "pc", "cap": "tts"},          # Tts autoload picks the engine itself
	"GET /tts/voices": {"pc": true, "phone": "", "prefer": "pc", "cap": "tts"},
	"POST /stt": {"pc": true, "phone": "stt", "prefer": "pc", "cap": "stt"},
	"POST /score": {"pc": true, "phone": "stt", "prefer": "pc", "cap": "score"},
	"POST /prosody": {"pc": true, "phone": "", "prefer": "pc", "cap": "prosody"},
	"POST /lesson": {"pc": true, "phone": "lessons", "prefer": "phone", "cap": "lesson"},
	"POST /lesson#ai": {"pc": true, "phone": "ai", "prefer": "pc", "cap": "lesson_ai"},
	"POST /reading/analyze": {"pc": true, "phone": "reading", "prefer": "phone", "cap": "reading"},
	"POST /reading/gloss": {"pc": true, "phone": "reading", "prefer": "pc", "cap": "gloss"},
	"GET /examples": {"pc": true, "phone": "reading", "prefer": "pc", "cap": "examples"},
	"GET /practice/ping": {"pc": true, "phone": "practice", "prefer": "phone", "cap": "practice"},
	"GET /practice/sentences": {"pc": true, "phone": "practice", "prefer": "phone", "cap": "practice"},
	"GET /practice/phonemes": {"pc": true, "phone": "practice", "prefer": "phone", "cap": "practice"},
	"GET /practice/phoneme": {"pc": true, "phone": "practice", "prefer": "phone", "cap": "practice"},
	"GET /missions": {"pc": true, "phone": "missions", "prefer": "phone", "cap": "missions"},
	"POST /missions/check": {"pc": true, "phone": "missions", "prefer": "phone", "cap": "missions"},
	"POST /missions/judge": {"pc": true, "phone": "ai", "prefer": "pc", "cap": "missions_judge"},
	"POST /chat": {"pc": true, "phone": "ai", "prefer": "pc", "cap": "chat"},
	"POST /fix": {"pc": true, "phone": "ai", "prefer": "pc", "cap": "fix"},
	"POST /feedback": {"pc": true, "phone": "ai", "prefer": "pc", "cap": "feedback"},
}

## Capability key -> the request that represents it in `caps()`.
const CAP_PATH := {
	"lesson": "POST /lesson", "lesson_ai": "POST /lesson#ai", "practice": "GET /practice/sentences",
	"missions": "GET /missions", "missions_judge": "POST /missions/judge", "reading": "POST /reading/analyze",
	"gloss": "POST /reading/gloss", "examples": "GET /examples", "stt": "POST /stt", "score": "POST /score",
	"phoneme": "POST /score", "prosody": "POST /prosody", "tts": "POST /tts", "chat": "POST /chat",
	"fix": "POST /fix", "feedback": "POST /feedback",
}

## Error codes of phone processing (§5.2) and their Korean texts. `error` of a failed result is always Korean.
const ERR_TEXT := {
	"not_on_phone": "이 기능은 PC에 연결했을 때만 돼요.",
	"needs_pc": "이 기능은 PC에 연결했을 때만 돼요.",
	"pack_missing": "폰 안에 학습 데이터가 없어요. 앱을 다시 설치해 주세요.",
	"pack_corrupt": "폰 안의 학습 데이터가 손상됐어요. 앱을 다시 설치해 주세요.",
	"model_missing": "음성 인식 모델이 아직 없어요. 설정 > 음성 인식에서 내려받으면(약 60 MB) 폰에서 바로 채점할 수 있어요. 지금은 녹음해서 들어 보고 스스로 평가할 수 있어요.",
	"model_corrupt": "음성 인식 모델 파일이 손상됐어요. 설정 > 음성 인식에서 다시 내려받아 주세요.",
	"engine_missing": "이 앱 빌드에는 폰 음성 인식이 들어 있지 않아요. PC에 연결하면 채점할 수 있어요.",
	"no_ai": "AI 대화는 AI 연결이 필요해요. 지금은 PC에 연결하거나 설정 > AI 연결에 본인 API 키를 넣으면 쓸 수 있어요. 키 없이도 '대본 대화'로 연습할 수 있어요.",
	"ai_auth": "키가 맞지 않아요. 설정 > AI 연결에서 확인해 주세요.",
	"ai_limit": "AI 사용 한도에 걸렸어요. 잠시 뒤 다시 시도해 주세요.",
	"ai_overload": "AI 서버가 응답하지 않아요. 잠시 뒤 다시 시도해 주세요.",
	"bad_format": "AI 답변 형식이 맞지 않아요. 다시 시도해 주세요.",
	"no_voice": "이 휴대폰에 쓸 수 있는 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 음성 데이터를 내려받아 주세요.",
	"no_permission": "마이크 권한이 없어요. 휴대폰 설정에서 이 앱의 마이크 권한을 켜 주세요.",
	"ja_reading_pc": "일본어 글 분석은 아직 PC에서만 돼요.",
	"not_connected": "PC에 연결되지 않았어요.",
}

## HTTP status a phone-side failure carries (§5.2; never 0, never triggers Api.auth_failed).
const ERR_HTTP := {
	"not_on_phone": 503, "needs_pc": 503, "pack_missing": 503, "pack_corrupt": 503, "model_missing": 503,
	"model_corrupt": 503, "engine_missing": 503, "no_ai": 503, "ai_auth": 401, "ai_limit": 429, "ai_overload": 502,
	"bad_format": 502, "no_voice": 503, "no_permission": 403, "ja_reading_pc": 503, "not_connected": 503,
}

## `degraded` values a phone result may carry (§5.2).
const DEGRADED := ["phoneme_off", "prosody_off", "ja_reading_approx", "gloss_partial", "examples_subset", "bank_repeat", "ai_off"]

## Emitted when `mode` changes (settings card, tests).
signal mode_changed(mode: String)
## Emitted once per fallback to the phone (A1; the toast is rate limited separately).
signal fell_back(path: String)

## Current mode (read from prefs at start; `set_mode` saves it).
var mode: String = DEFAULT_MODE
## Tests inject a clock: returns seconds (float). Default = Time.get_ticks_msec() / 1000.0
var clock: Callable = Callable()
## Tests may replace the PC readiness probe (default: Backend.is_ready()).
var pc_ready_hook: Callable = Callable()

var _flaky_until: float = -1.0
var _last_fallback_toast: float = -1.0e9


func _ready() -> void:
	mode = normalize_mode(str(Store.prefs.get(PREF_MODE, DEFAULT_MODE)))


static func normalize_mode(m: String) -> String:
	return m if m in MODES else DEFAULT_MODE


func set_mode(m: String) -> void:
	m = normalize_mode(m)
	if m == mode and str(Store.prefs.get(PREF_MODE, "")) == m:
		return
	mode = m
	Store.set_pref(PREF_MODE, m)
	mode_changed.emit(m)


## "GET"/"POST" + path without query -> policy entry (a copy) or {} when the path is PC-only.
## `body` matters for POST /lesson: {"source": "ai"} selects the "#ai" entry.
static func policy_for(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var p: String = path.split("?")[0]
	var key: String = method.to_upper() + " " + p
	if key == "POST /lesson" and str(body.get("source", "")) == "ai":
		key = "POST /lesson#ai"
	if POLICY.has(key):
		return (POLICY[key] as Dictionary).duplicate()
	return {}


func now_sec() -> float:
	if clock.is_valid():
		return float(clock.call())
	return Time.get_ticks_msec() / 1000.0


func pc_ready() -> bool:
	if pc_ready_hook.is_valid():
		return bool(pc_ready_hook.call())
	return Backend.is_ready()


## True while requests should skip the PC after a transport failure (auto mode, §4.2).
func pc_flaky() -> bool:
	return _flaky_until >= 0.0 and now_sec() < _flaky_until


## Called by Api when a PC request failed with a transport error and the phone took over (A1).
func mark_pc_flaky() -> void:
	_flaky_until = now_sec() + FLAKY_SEC


func clear_flaky() -> void:
	_flaky_until = -1.0


## Where `method path` goes right now: "pc" | "phone" | "none". A0 stub: always the old behaviour.
## A1 implements §4.2 (mode × entry.pc × entry.phone × LocalApi.available(path)).
func decide(method: String, path: String, body: Dictionary = {}) -> String:
	var entry: Dictionary = policy_for(method, path, body)
	if entry.is_empty():
		return "pc"
	return "pc"


## {err_code, text_ko} explaining why `path` is "none" right now (A1).
func why_none(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = policy_for(method, path, body)
	if entry.is_empty() or str(entry.get("phone", "")) == "":
		return {"err_code": "not_on_phone", "text_ko": ERR_TEXT["not_on_phone"]}
	return {"err_code": "needs_pc", "text_ko": ERR_TEXT["needs_pc"]}


## Capability table for the settings card and tests (§5.3). A1 fills `use`/`phone`/`pc`/`why` per key.
func caps() -> Dictionary:
	var items := {}
	for k in CAP_KEYS:
		items[k] = {"use": "pc" if pc_ready() else "none", "phone": false, "pc": pc_ready(), "why": ""}
	return {"mode": mode, "pc": {"connected": pc_ready(), "flaky": pc_flaky()}, "items": items}


static func text_for(err_code: String) -> String:
	return str(ERR_TEXT.get(err_code, ERR_TEXT["needs_pc"]))


static func http_for(err_code: String) -> int:
	return int(ERR_HTTP.get(err_code, 503))
