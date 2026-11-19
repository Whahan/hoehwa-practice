extends Node
## Route: decides, per request, where a feature runs — on the paired PC ("pc"), inside the phone ("phone")
## or nowhere ("none"). Design: docs/phone_standalone_design.md §4.2–4.3, §5.2–5.3.
##
## A0 (orchestrator): contract + POLICY table + error texts. A1: the decision logic, `pc_flaky()` bookkeeping and
## `caps()` (tests: tests/route_test.gd).
##
## Modes (prefs.route_mode): "auto" (PC first, phone when the PC is unreachable), "phone" (never talk to the
## PC), "pc" (old behaviour, phone handlers never used). Any other value is treated as "auto".
## Exception (v2.0, docs/v200_phone_design.md §1.8): in auto mode /stt and /score prefer the phone (pref `score_where`,
## "phone" by default; "pc" = PC first), a /score request with need_ph:true prefers the PC. AI paths stay PC first and
## never switch to a key on the phone by themselves.
## Standalone mode belongs to the phone: on the PC app (Platform.is_phone() == false) every path is "pc",
## whatever the mode or the policy says.

const MODES := ["auto", "phone", "pc"]
const DEFAULT_MODE := "auto"
const PREF_MODE := "route_mode"

## Pref `score_where` ("phone" | "pc"): which side scores speech first (/stt, /score) in auto mode. Anything else, or a
## missing value, means DEFAULT_SCORE_WHERE. The AI paths (/chat, /fix, /feedback, /missions/judge) ignore it.
const PREF_SCORE_WHERE := "score_where"
const SCORE_WHERES := ["phone", "pc"]
const DEFAULT_SCORE_WHERE := "phone"

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
## `POST /lesson` with body.source == "ai" is routed like the "lesson_ai" entry below, `POST /score` with body.need_ph == true
## like "POST /score#ph" (see `policy_for`).
const POLICY := {
	"GET /health": {"pc": true, "phone": "health", "prefer": "pc", "cap": ""},
	# prefer pc: a connected phone keeps getting the PC's (possibly newer) curriculum; without a ready PC the bundled copy.
	"GET /curriculum": {"pc": true, "phone": "curriculum", "prefer": "pc", "cap": ""},
	"POST /tts": {"pc": true, "phone": "", "prefer": "pc", "cap": "tts"},          # Tts autoload picks the engine itself
	"GET /tts/voices": {"pc": true, "phone": "", "prefer": "pc", "cap": "tts"},
	# v2.0 phone-first scoring (docs/v200_phone_design.md §1.8): prefer is "phone" unless the pref `score_where` is "pc"
	# (`policy_for` applies that). A /score body with need_ph:true (phoneme screens) is the "#ph" entry: the PC first.
	"POST /stt": {"pc": true, "phone": "stt", "prefer": "phone", "cap": "stt"},
	"POST /score": {"pc": true, "phone": "stt", "prefer": "phone", "cap": "score"},
	"POST /score#ph": {"pc": true, "phone": "stt", "prefer": "pc", "cap": ""},
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
	"no_ai": "AI를 쓰려면 설정 > AI 연결에서 본인 AI 키를 한 번 넣어 주세요. PC에 연결해도 돼요. 키 없이도 '대본 대화'로 연습할 수 있어요.",
	# v2.0 phone design §2.7 (AI direct connection) and §1 (phone speech engine); the texts are fixed, never carry a key or a body.
	"engine_error": "폰 음성 인식이 잠깐 멈췄어요. 잠시 뒤 다시 말해 보세요. 계속 안 되면 설정 > 음성 인식에서 'PC에서 채점'을 고를 수 있어요.",
	"stt_timeout": "음성 인식이 너무 오래 걸려서 멈췄어요. 조금 짧게 말하거나 잠시 뒤 다시 시도해 주세요. 계속 안 되면 설정 > 음성 인식에서 'PC에서 채점'을 고를 수 있어요.",
	"ai_offline": "인터넷에 연결돼 있지 않아요. 와이파이나 데이터를 켠 뒤 다시 시도해 주세요. 지금은 '대본 대화'로 연습할 수 있어요.",
	"ai_tls": "보안 연결에 실패했어요. 폰의 날짜와 시간이 맞는지 확인해 주세요.",
	"ai_model": "AI 모델을 찾을 수 없어요. 설정 > AI 연결에서 모델을 다시 골라 주세요.",
	"ai_url": "주소가 안전하지 않아요. https:// 로 시작하는 주소만 쓸 수 있어요.",
	"ai_key_format": "키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요.",
	"ja_ai_pc": "일본어 AI 대화는 아직 PC에서만 돼요.",
	"no_space": "휴대폰 저장 공간이 부족해요. 공간을 확보한 뒤 다시 시도해 주세요.",
	"ai_auth": "키가 맞지 않아요. 설정 > AI 연결에서 확인해 주세요.",
	"ai_limit": "AI 사용 한도에 걸렸어요. 잠시 뒤 다시 시도해 주세요.",
	"ai_overload": "AI 서버가 응답하지 않아요. 잠시 뒤 다시 시도해 주세요.",
	"bad_format": "AI 답변 형식이 맞지 않아요. 다시 시도해 주세요.",
	"no_voice": "이 휴대폰에 쓸 수 있는 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 음성 데이터를 내려받아 주세요.",
	"no_permission": "마이크 권한이 없어요. 휴대폰 설정에서 이 앱의 마이크 권한을 켜 주세요.",
	"ja_reading_pc": "일본어 글 분석은 아직 PC에서만 돼요.",
	"not_connected": "PC에 연결되지 않았어요.",
	"bad_request": "요청이 올바르지 않아요.",
	"not_found": "찾는 항목이 없어요.",
}

## HTTP status a phone-side failure carries (§5.2; never 0, never triggers Api.auth_failed).
const ERR_HTTP := {
	"not_on_phone": 503, "needs_pc": 503, "pack_missing": 503, "pack_corrupt": 503, "model_missing": 503,
	"model_corrupt": 503, "engine_missing": 503, "no_ai": 503, "ai_auth": 401, "ai_limit": 429, "ai_overload": 502,
	"bad_format": 502, "no_voice": 503, "no_permission": 403, "ja_reading_pc": 503, "not_connected": 503,
	"bad_request": 400, "not_found": 404,
	# v2.0 phone design: none of the new codes is 401 (ai_auth, the provider key problem, stays the only phone-side 401)
	"engine_error": 500, "stt_timeout": 504, "ai_offline": 503, "ai_tls": 502, "ai_model": 502, "ai_url": 400,
	"ai_key_format": 400, "ja_ai_pc": 503, "no_space": 507,
}

## `degraded` values a phone result may carry (§5.2; `score_uncalibrated` / `stt_tiny_model`: v2.0 phone design §1.5).
const DEGRADED := ["phoneme_off", "prosody_off", "ja_reading_approx", "gloss_partial", "examples_subset", "bank_repeat", "ai_off",
	"score_uncalibrated", "stt_tiny_model"]

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
## Tests may replace the platform probe: returns true for "this is the phone app" (default: Platform.is_phone()).
var phone_hook: Callable = Callable()

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


## The effective `score_where` pref: "phone" or "pc" (a missing or odd value is DEFAULT_SCORE_WHERE).
static func score_where() -> String:
	var v: Variant = Store.prefs.get(PREF_SCORE_WHERE, DEFAULT_SCORE_WHERE)
	if v is String and (v as String) in SCORE_WHERES:
		return v
	return DEFAULT_SCORE_WHERE


## "GET"/"POST" + path without query -> policy entry (a copy) or {} when the path is PC-only.
## `body` matters for POST /lesson: {"source": "ai"} selects the "#ai" entry, and for POST /score: {"need_ph": true}
## selects the "#ph" entry. The `prefer` of /stt and /score (not "#ph") follows the pref `score_where`.
static func policy_for(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var p: String = path.split("?")[0]
	var key: String = method.to_upper() + " " + p
	if key == "POST /lesson" and str(body.get("source", "")) == "ai":
		key = "POST /lesson#ai"
	elif key == "POST /score":
		var need_ph: Variant = body.get("need_ph", false)
		if typeof(need_ph) == TYPE_BOOL and need_ph:
			key = "POST /score#ph"
	if POLICY.has(key):
		var e: Dictionary = (POLICY[key] as Dictionary).duplicate()
		if key == "POST /stt" or key == "POST /score":
			e["prefer"] = "pc" if score_where() == "pc" else "phone"
		return e
	return {}


func now_sec() -> float:
	if clock.is_valid():
		return float(clock.call())
	return Time.get_ticks_msec() / 1000.0


## True on the phone app (Android or desktop `-- --phone`); the PC app never uses phone handlers.
func is_phone() -> bool:
	if phone_hook.is_valid():
		return bool(phone_hook.call())
	return Platform.is_phone()


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


## Where `method path` goes right now: "pc" | "phone" | "none" (§4.2, as fixed in the A1 task):
##   - PC app (not is_phone()) -> always "pc"
##   - no policy entry (/mic, /llm, /lan, /sync, ...) -> "pc" in auto/pc mode, "none" in phone mode (never the PC)
##   - GET /health probes the PC: auto/pc -> "pc", phone -> "none" (never the synthetic phone /health)
##   - mode pc -> "pc"; mode phone -> "phone" if a handler can serve it else "none"
##   - mode auto -> by `prefer`, a PC that is ready (and not flaky) first, else the phone, else try the PC
func decide(method: String, path: String, body: Dictionary = {}) -> String:
	if not is_phone():
		return "pc"
	var entry: Dictionary = policy_for(method, path, body)
	var md: String = normalize_mode(mode)
	if entry.is_empty():
		return "none" if md == "phone" else "pc"
	if method.to_upper() == "GET" and path.split("?")[0] == "/health":
		return "none" if md == "phone" else "pc"
	var phone_ok: bool = str(entry.get("phone", "")) != "" and LocalApi.available(method, path, body)
	var pc_possible: bool = bool(entry.get("pc", false)) and Api.base_url != "" and not pc_flaky()
	if md == "pc":
		return "pc" if bool(entry.get("pc", false)) else "none"
	if md == "phone":
		return "phone" if phone_ok else "none"
	if str(entry.get("prefer", "pc")) == "phone":
		if phone_ok:
			return "phone"
		return "pc" if pc_possible else "none"
	if pc_possible and pc_ready():
		return "pc"
	if phone_ok:
		return "phone"
	return "pc" if pc_possible else "none"


## {err_code, text_ko} explaining why `method path` is "none" right now.
func why_none(method: String, path: String, body: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = policy_for(method, path, body)
	if normalize_mode(mode) == "pc" and (entry.is_empty() or not bool(entry.get("pc", false)) or Api.base_url == ""):
		return {"err_code": "not_connected", "text_ko": text_for("not_connected")}
	if entry.is_empty() or str(entry.get("phone", "")) == "":
		return {"err_code": "not_on_phone", "text_ko": text_for("not_on_phone")}
	var r: Dictionary = LocalApi.why_none(method, path, body)
	if str(r.get("err_code", "")) == "":
		return {"err_code": "needs_pc", "text_ko": text_for("needs_pc")}
	if str(r.get("text_ko", "")) == "":
		r["text_ko"] = text_for(str(r["err_code"]))
	return r


## True at most once per FALLBACK_TOAST_SEC: the caller may then show "PC에 닿지 않아 폰에서 처리했어요".
func take_fallback_toast() -> bool:
	var t: float = now_sec()
	if t - _last_fallback_toast < FALLBACK_TOAST_SEC:
		return false
	_last_fallback_toast = t
	return true


## Capability table for the settings card and tests (§5.3).
func caps() -> Dictionary:
	var items := {}
	var md: String = normalize_mode(mode)
	var connected: bool = pc_ready()
	for k in CAP_KEYS:
		var spec: PackedStringArray = str(CAP_PATH[k]).split(" ")
		var path: String = spec[1]
		var body := {}
		if path.ends_with("#ai"):
			path = path.trim_suffix("#ai")
			body = {"source": "ai"}
		var method: String = spec[0]
		var entry: Dictionary = policy_for(method, path, body)
		var pc_has: bool = bool(entry.get("pc", false)) and Api.base_url != ""
		var phone_has: bool = LocalApi.available(method, path, body)
		var use: String = decide(method, path, body)
		if k == "phoneme":
			# Stage 1 has no phone phoneme analysis; the PC does it (when PC use is allowed at all).
			phone_has = false
			use = "pc" if (md != "phone" and pc_has and not pc_flaky()) else "none"
		elif k == "tts":
			# system_voices_ok() is {"en": bool, "ja": bool}; caps is not per language, so any voice counts.
			var voices: Dictionary = Tts.call("system_voices_ok") if Tts.has_method("system_voices_ok") else {}
			phone_has = voices.values().has(true)
			if Tts.has_method("engine_now"):
				var e: String = str(Tts.call("engine_now"))
				if e == "system" or e == "phone":
					use = "phone" if phone_has else "none" # system engine without a voice reads nothing aloud
				else:
					use = "pc" if e == "pc" else "none"
			else:
				use = "pc" if (md != "phone" and connected and pc_has) else ("phone" if (md != "pc" and phone_has) else "none")
		var why := ""
		if use == "none":
			why = "not_on_phone" if k == "phoneme" else str(why_none(method, path, body).get("err_code", ""))
		items[k] = {"use": use, "phone": phone_has, "pc": pc_has, "why": why}
	return {"mode": md, "pc": {"connected": connected, "flaky": pc_flaky()}, "items": items}


static func text_for(err_code: String) -> String:
	return str(ERR_TEXT.get(err_code, ERR_TEXT["needs_pc"]))


static func http_for(err_code: String) -> int:
	return int(ERR_HTTP.get(err_code, 503))
