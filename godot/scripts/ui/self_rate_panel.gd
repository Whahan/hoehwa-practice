class_name SelfRatePanel
extends VBoxContainer
## 자가 평가 위젯 (폰 단독 A7, 설계 §3.3 · §4.6): `Route`가 `POST /score`를 "none"으로 줄 때(폰 안 음성 인식 모델이 없고
## PC도 닿지 않을 때) 말하기 문제의 채점 결과 자리에 들어간다.
##   녹음한 내 목소리 듣기 / 원어민 듣기(Tts) 를 번갈아 → "잘했어요" / "다시".
## `rated(true)`  : 잘했어요 -> 쓰는 화면이 기존 "채점 통과"와 같은 길로 기록한다 (good_result 로 만든 결과 사용).
## `rated(false)` : 다시     -> 아무것도 기록하지 않는다. 쓰는 화면은 다시 녹음하게 둔다.
## `/score` 요청은 보내지 않는다 (요청하는 쪽이 needed() 를 먼저 본다).
##
## 쓰는 법: if SelfRatePanel.needed(): var p := SelfRatePanel.new(lang, 문장, 녹음결과(Recorder 의 result), 강조색)
##          p.rated.connect(...); parent.add_child(p)
## 못 하는 기능(억양 · 음소)은 숨기지 않고 disabled_feature() 로 비활성 버튼 + 이유 한 줄을 보인다 (설계 §4.6).

signal rated(good: bool)

## "잘했어요" 한 번이 기록에 남기는 점수: 통과선(70)과 같다. 실제로 잰 점수가 아니므로 결과에 self_rated 표시를 붙인다.
const GOOD_SCORE := 70
const PROSODY_REASON := "억양 비교는 PC 연결 시"
const PHONEME_REASON := "발음기호 분석은 PC 연결 시"
const INTRO_TEXT := "지금은 점수를 낼 수 없어요. 내 목소리와 원어민 소리를 번갈아 들어 보고 직접 평가해 보세요. (점수는 PC에 연결하면 볼 수 있어요)"

## 시험 전용: Callable(who: String) — "mine" | "native" 를 누른 직후 불린다.
static var play_hook: Callable = Callable()

var lang: String = "en"
var text: String = ""
var rec: Dictionary = {}
var accent: Color = Pal.EN
var mine_plays: int = 0
var native_plays: int = 0
var done: bool = false ## 잘했어요/다시 중 하나가 눌렸다 (두 번 기록되지 않게)

var _player: AudioStreamPlayer
var _stream: AudioStreamWAV = null
var _btn_mine: Button
var _btn_native: Button
var _btn_good: Button
var _btn_again: Button


# ---------------------------------------------------------------- when / what

## 지금 /score 가 갈 곳이 없나 (Route 판단: "none"). PC 앱은 늘 "pc" 라서 false.
static func needed() -> bool:
	return Route.decide("POST", "/score", {}) == "none"


## 지금 /prosody 가 갈 곳이 없나.
static func prosody_off() -> bool:
	return Route.decide("POST", "/prosody", {}) == "none"


## 폰에서는 1단계에 음소 분석이 없다: 채점이 PC로 갈 때만 발음기호가 나온다.
static func phoneme_off() -> bool:
	return Route.is_phone() and Route.decide("POST", "/score", {}) != "pc"


## "잘했어요" 가 기록으로 넘기는 결과 (StudyLog.add_score 가 받는 모양 + self_rated).
static func good_result(l: String, target_text: String) -> Dictionary:
	var t: String = target_text.strip_edges()
	return {"transcript": t if t != "" else "(자가 평가)", "units": [], "score": GOOD_SCORE, "self_rated": true, "via": "self", "lang": l}


static func is_self_rated(res: Variant) -> bool:
	return res is Dictionary and bool((res as Dictionary).get("self_rated", false))


## 비활성 기능 칸: 눌리지 않는 버튼 + 이유 한 줄. 노드 이름 "DisabledFeature", meta "reason".
static func disabled_feature(title: String, button_text: String, reason: String) -> Control:
	var card := UI.card("Sunk", 6)
	card.name = "DisabledFeature"
	card.set_meta("reason", reason)
	card.body.add_child(UI.label(title, "Eyebrow", false))
	var b := UI.button(button_text, "soft", Pal.MUTED, maxf(44.0, Ds.touch_min() if Platform.is_phone() else 0.0))
	b.disabled = true
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.focus_mode = Control.FOCUS_NONE
	card.body.add_child(b)
	card.body.add_child(UI.label(reason, "Small"))
	return card


# ---------------------------------------------------------------- widget

func _init(l: String = "en", sentence: String = "", recording: Dictionary = {}, accent_color: Color = Pal.EN) -> void:
	lang = l
	text = sentence
	rec = recording
	accent = accent_color
	name = "SelfRatePanel"
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	add_child(_player)
	var h: float = maxf(44.0, Ds.touch_min() if Platform.is_phone() else 0.0)
	var card := UI.card("Card", 10)
	card.body.add_child(UI.label("스스로 평가", "Eyebrow", false))
	card.body.add_child(UI.label(_intro(), "Muted"))
	var listen := UI.flow(8, 8)
	_btn_mine = UI.button("▶ 내 목소리 듣기", "soft", accent, h)
	_btn_mine.pressed.connect(play_mine)
	listen.add_child(_btn_mine)
	_btn_native = UI.button("▶ 원어민 듣기", "soft", accent, h)
	_btn_native.pressed.connect(play_native)
	listen.add_child(_btn_native)
	card.body.add_child(listen)
	card.body.add_child(UI.label("번갈아 들어 보고, 비슷하게 말했다면 '잘했어요'를 눌러요.", "Small"))
	var row := UI.adaptive(8)
	_btn_good = UI.button("잘했어요", "primary", accent, maxf(48.0, h))
	_btn_good.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_good.pressed.connect(func() -> void: _rate(true))
	row.add_child(_btn_good)
	_btn_again = UI.button("다시", "outline", accent, maxf(48.0, h))
	_btn_again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_again.pressed.connect(func() -> void: _rate(false))
	row.add_child(_btn_again)
	card.body.add_child(row)
	add_child(card)
	if phoneme_off():
		add_child(disabled_feature("발음기호", "발음기호 보기", PHONEME_REASON))
	UI.fix_cjk(self)


func _intro() -> String:
	# "모델 없음" 이면 Route 의 안내(설정 > 음성 인식에서 내려받기)를 그대로 쓴다.
	var why: Dictionary = Route.why_none("POST", "/score", {})
	if str(why.get("err_code", "")) == "model_missing":
		return Route.text_for("model_missing")
	return INTRO_TEXT


func _exit_tree() -> void:
	if _player != null and _player.playing:
		_player.stop()


## 내 목소리 듣기. 원어민 소리는 먼저 멈춘다.
func play_mine() -> void:
	if done:
		return
	Tts.stop()
	mine_plays += 1
	if play_hook.is_valid():
		play_hook.call("mine")
	var s: AudioStreamWAV = mine_stream()
	if s == null:
		Toast.error("녹음을 다시 재생하지 못했어요. 한 번 더 녹음해 보세요.")
		return
	_player.stream = s
	_player.play()


## 원어민 듣기 (Tts). 내 목소리는 먼저 멈춘다.
func play_native() -> void:
	if done:
		return
	if _player != null and _player.playing:
		_player.stop()
	native_plays += 1
	if play_hook.is_valid():
		play_hook.call("native")
	if text.strip_edges() != "":
		Tts.speak(text, lang, false)


## 녹음 결과에서 소리 꾸러미를 만든다 (Android: result.stream, 그 밖: result.wav 또는 b64).
func mine_stream() -> AudioStreamWAV:
	if _stream != null:
		return _stream
	var s: Variant = rec.get("stream", null)
	if s is AudioStreamWAV:
		_stream = s
		return _stream
	var wav: PackedByteArray = PackedByteArray()
	var raw: Variant = rec.get("wav", null)
	if raw is PackedByteArray:
		wav = raw
	if wav.is_empty() and str(rec.get("b64", "")) != "":
		wav = Marshalls.base64_to_raw(str(rec["b64"]))
	_stream = WavUtil.from_wav_bytes(wav)
	return _stream


func is_playing_mine() -> bool:
	return _player != null and _player.playing


func _rate(good: bool) -> void:
	if done:
		return
	done = true
	if _player != null and _player.playing:
		_player.stop()
	Tts.stop()
	for b in [_btn_mine, _btn_native, _btn_good, _btn_again]:
		if b != null:
			(b as Button).disabled = true
	rated.emit(good)
