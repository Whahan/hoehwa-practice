class_name SpeakDrill
extends VBoxContainer
## 듣기 -> 녹음 -> /score -> /prosody 공용 부품 (쉐도잉 · 약한 소리가 함께 쓴다).
##
## 쓰는 법: drill = SpeakDrill.new(lang, source); 화면의 본문에 add_child(drill) (채점 결과가 여기에 그려진다),
## 고정 하단 바에 drill.make_recorder() 를 넣는다. 문장이 바뀔 때 drill.set_target(text, reading, ko).
## 채점이 유효하면 `scored(res, target)`, 소리가 없거나 응답을 못 읽으면 `silent_result(target)` 신호.
## 시험에서는 `api_hook` 으로 서버 없이 요청을 가로챌 수 있다 (practice_test.gd).

signal scored(res: Dictionary, target: String)
signal silent_result(target: String)
signal status_changed

const PASS_SCORE := 70
const SILENT_TEXT := "소리가 들리지 않았어요. 마이크에 조금 더 가까이서 다시 말해 보세요."
const ERROR_TEXT := "채점하지 못했어요. 잠시 뒤 다시 시도해 주세요."
const TOUCH_H := 44.0 ## smallest height of a pressable thing here; on the phone UI.button / fit_touch raise it to Ds.touch_min()

## 시험 전용: Callable(method: String, path: String, body: Variant) -> Dictionary (코루틴 가능).
## 돌려주는 값은 {ok, code, data, error} 모양의 결과이거나 ({ok} 없이) 그대로 data 로 쓸 Dictionary.
static var api_hook: Callable = Callable()
## 시험 전용: Callable(lang, res, source, counted) — StudyLog.add_score 를 부른 직후 호출된다.
static var score_hook: Callable = Callable()

var lang: String = "en"
var source: String = "shadow" ## StudyLog.add_score 의 출처
var target: String = ""
var score_target: String = "" ## /score 에 보낼 글자 (구간 연습이면 구간 글자)
var reading: String = ""
var ko: String = ""
var status: String = "idle" ## idle | scoring | ok | silent | error
var result: Dictionary = {}
var prosody: Dictionary = {}
var error_text: String = ""
var show_prosody: bool = true
var auto_record: bool = false ## 듣기가 끝나면 자동으로 녹음 시작 (shadow_auto_rec)
var recorder: RecorderWidget = null

var _serial: int = 0
var _score_call = null
var _pros_call = null
var _last_audio: String = ""
var _prosody_box: VBoxContainer = null
var _listen_pending: bool = false


## Api.ApiCall 과 같은 모양(wait / cancel)의 가짜 호출. api_hook 이 있을 때만 쓴다.
class FakeCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}
	var path: String = ""

	func wait() -> Dictionary:
		if done:
			return result
		return await finished

	func cancel() -> void:
		complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true})

	func complete(res: Dictionary) -> void:
		if done:
			return
		done = true
		result = res
		finished.emit(res)


func _init(l: String = "en", src: String = "shadow") -> void:
	lang = l
	source = src
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	if not Tts.sequence_finished.is_connected(_on_seq_finished):
		Tts.sequence_finished.connect(_on_seq_finished)


func _exit_tree() -> void:
	if Tts.sequence_finished.is_connected(_on_seq_finished):
		Tts.sequence_finished.disconnect(_on_seq_finished)
	_serial += 1
	_cancel_calls()


# ---------------------------------------------------------------- requests (real or test hook)

## GET (body == null) 또는 POST. Api.ApiCall 또는 FakeCall 을 돌려준다 (wait() / cancel()).
static func request(path: String, body: Variant = null, timeout: float = 60.0) -> Object:
	if api_hook.is_valid():
		var fc := FakeCall.new()
		fc.path = path
		_run_hook(fc, path, body)
		return fc
	if body == null:
		return Api.get_json(path, timeout, false)
	return Api.post_json(path, body as Dictionary, timeout, false)


static func _run_hook(fc: FakeCall, path: String, body: Variant) -> void:
	var raw: Variant = await api_hook.call("GET" if body == null else "POST", path, body)
	fc.complete(_norm(raw))


static func _norm(raw: Variant) -> Dictionary:
	var base := {"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": false}
	if raw is Dictionary:
		var d: Dictionary = raw
		if d.has("ok") and (d.has("data") or d.has("error") or d.has("code")):
			base.merge(d, true)
			return base
		base["ok"] = true
		base["code"] = 200
		base["data"] = d
		return base
	if raw is Array:
		base["ok"] = true
		base["code"] = 200
		base["data"] = raw
		return base
	base["error"] = "AI 엔진에 연결하지 못했어요. 엔진이 켜져 있는지 확인하고 다시 시도해 주세요."
	return base


static func cancel_call(c: Variant) -> void:
	if c != null and c is Object and is_instance_valid(c as Object):
		(c as Object).call("cancel")


## 오류 결과를 사용자에게 보여 줄 한국어 문장으로.
static func error_message(res: Dictionary, fallback: String) -> String:
	var e: String = str(res.get("error", ""))
	# 서버가 한국어 error 를 준 404(예: 없는 소리)는 그대로 보이고, 내용 없는 404 만 "서버가 오래된 버전" 으로 본다.
	if int(res.get("code", 0)) == 404 and (e == "" or e.begins_with("서버에서 오류가 났어요")):
		return "PC 프로그램을 최신 버전으로 업데이트해 주세요. (이 서버에는 연습 기능이 없어요)"
	return e if e != "" else fallback


# ---------------------------------------------------------------- shared screen shell

## 하위 화면 공통 틀: 위 머리줄(← 연습 · 제목 · 쪽수) + 가운데 스크롤 본문 + 고정 하단 바.
## 돌려주는 값: {root, back, title, count, head, page, footer_holder, footer_col} (키 8개는 4개 화면이 쓰므로 유지).
## 머리줄은 폰의 앱 바가 뒤로·제목·쪽수를 대신 보여 줄 때(W4)도 `back`·`title`·`count` 노드가 남아 값이 계속 갱신된다.
## 색·간격은 토큰(Pal, Ds)에서 읽는다: 바탕 BG 위에 머리줄, 아래 고정 바는 SURFACE 면 + 위쪽 헤어라인.
static func build_shell(owner: Control, on_back: Callable, back_text: String = "← 연습") -> Dictionary:
	owner.set_anchors_preset(Control.PRESET_FULL_RECT)
	owner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	owner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	owner.clip_contents = true
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	owner.add_child(root)

	var head_holder := MarginContainer.new()
	head_holder.add_theme_constant_override("margin_left", Ds.S3)
	head_holder.add_theme_constant_override("margin_right", Ds.S3)
	head_holder.add_theme_constant_override("margin_top", Ds.S2)
	head_holder.add_theme_constant_override("margin_bottom", Ds.S1)
	root.add_child(head_holder)
	var head := UI.hbox(8)
	head_holder.add_child(head)
	var back := UI.button(back_text, "flat", Pal.INK, TOUCH_H)
	back.pressed.connect(on_back)
	head.add_child(back)
	var title := UI.label("", "H3", false)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.clip_text = true
	head.add_child(title)
	var count := UI.label("", "Muted", false)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(count)

	var page := PageScroll.new(720.0)
	root.add_child(page)

	var holder := PanelContainer.new()
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_top = 1
	holder.add_theme_stylebox_override("panel", st)
	holder.visible = false
	root.add_child(holder)
	var fcol := ColumnBox.new()
	fcol.max_width = 720.0
	fcol.min_pad = Ds.S3
	fcol.set_padding(Ds.S3 if Platform.is_phone() else 10, Ds.S3)
	holder.add_child(fcol)
	return {"root": root, "back": back, "title": title, "count": count, "head": head, "page": page, "footer_holder": holder, "footer_col": fcol}


## 고정 하단 바를 비우고 새 줄(HBox)을 만들어 돌려준다. 보이게 한다.
static func new_footer_row(shell: Dictionary, keep: Control = null) -> HBoxContainer:
	var col: ColumnBox = shell["footer_col"]
	if keep != null and is_instance_valid(keep) and keep.get_parent() != null:
		keep.get_parent().remove_child(keep) # 비울 때 같이 지워지지 않게 먼저 뗀다
	UI.clear(col.content)
	var row := UI.hbox(10)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.content.add_child(row)
	(shell["footer_holder"] as PanelContainer).visible = true
	return row


static func hide_footer(shell: Dictionary, keep: Control = null) -> void:
	var col: ColumnBox = shell["footer_col"]
	if keep != null and is_instance_valid(keep) and keep.get_parent() != null:
		keep.get_parent().remove_child(keep)
	UI.clear(col.content)
	(shell["footer_holder"] as PanelContainer).visible = false


## 눌러서 쓰는 버튼 (높이 44 이상).
static func touch_button(text: String, kind: String = "soft", accent: Color = Pal.EN, min_h: float = TOUCH_H) -> Button:
	return UI.button(text, kind, accent, maxf(min_h, TOUCH_H))


## node 아래의 모든 Button(체크박스 · 구분 버튼 포함)을 눌러 쓰기 좋은 높이로.
## min_h 를 안 주면 폰은 터치 최소(48 dp), PC 는 TOUCH_H.
static func fit_touch(node: Node, min_h: float = -1.0) -> void:
	var h: float = min_h if min_h > 0.0 else maxf(TOUCH_H, Ds.touch_min() if Platform.is_phone() else 0.0)
	for c in node.get_children():
		if c is Button:
			(c as Button).custom_minimum_size.y = maxf((c as Button).custom_minimum_size.y, h)
		fit_touch(c, h)


## 빈 상태 / 오류 안내 상자.
static func notice(msg: String, bad: bool = true) -> PanelContainer:
	var p := UI.tinted_panel(Pal.BAD_SOFT if bad else Pal.SUNK, Color(0, 0, 0, 0), 0, Ds.R_S, 14, 10)
	p.add_child(UI.colored(msg, Pal.BAD_ON if bad else Pal.INK))
	return p


# ---------------------------------------------------------------- state

func make_recorder(idle_text: String = "따라 말하기") -> RecorderWidget:
	if recorder != null and is_instance_valid(recorder):
		return recorder
	recorder = RecorderWidget.new(false, Pal.accent(lang), Platform.is_pc())
	recorder.idle_text = idle_text
	recorder.recorded.connect(_on_recorded)
	return recorder


## 새 문장을 연습한다. 진행 중이던 녹음·채점은 버린다.
func set_target(text: String, reading_text: String = "", ko_text: String = "", score_text: String = "") -> void:
	stop_all()
	target = text
	reading = reading_text
	ko = ko_text
	score_target = score_text if score_text != "" else text
	status = "idle"
	result = {}
	prosody = {}
	error_text = ""
	_last_audio = ""
	_render()
	status_changed.emit()


func set_score_target(text: String) -> void:
	score_target = text if text != "" else target


func is_scoring() -> bool:
	return status == "scoring"


## 듣기. text_override 가 있으면 그 글자만 읽는다 (구간 듣기, 단어 듣기).
func listen(slow: bool = false, text_override: String = "") -> void:
	var t: String = text_override if text_override != "" else target
	if t.strip_edges() == "":
		return
	_listen_pending = auto_record and text_override == ""
	Tts.speak(t, lang, slow)


func _on_seq_finished() -> void:
	if not _listen_pending:
		return
	_listen_pending = false
	if not auto_record or not is_inside_tree() or not is_visible_in_tree():
		return
	if recorder == null or not is_instance_valid(recorder) or not recorder.is_inside_tree():
		return
	if Recorder.recording or Recorder.stopping or status == "scoring":
		return
	Recorder.begin(recorder.get_instance_id())


## 화면을 떠날 때: 녹음 취소, 소리 멈춤, 늦게 오는 응답 버림.
func stop_all() -> void:
	_listen_pending = false
	if recorder != null and is_instance_valid(recorder):
		recorder.stop_if_recording()
	Tts.stop()
	_serial += 1
	_cancel_calls()
	if status == "scoring":
		status = "idle"
		_render()
		status_changed.emit()


func _cancel_calls() -> void:
	var a: Variant = _score_call
	var b: Variant = _pros_call
	_score_call = null
	_pros_call = null
	cancel_call(a)
	cancel_call(b)


# ---------------------------------------------------------------- scoring

func _on_recorded(rec: Dictionary) -> void:
	if status == "scoring":
		return
	var b64: String = str(rec.get("b64", ""))
	if b64 == "":
		_set_silent()
		return
	_last_audio = b64
	_submit(b64)


func retry_score() -> void:
	if _last_audio != "" and status != "scoring":
		_submit(_last_audio)


func _submit(b64: String) -> void:
	_serial += 1
	_cancel_calls()
	var serial: int = _serial
	status = "scoring"
	result = {}
	prosody = {}
	error_text = ""
	_render()
	status_changed.emit()
	var tgt: String = score_target if score_target != "" else target
	var body := {"lang": lang, "target": tgt, "reading": reading if tgt == target else "", "audio_b64": b64}
	var score_req: Object = request("/score", body, Api.TIMEOUT_SHORT)
	_score_call = score_req
	if lang == "en" and show_prosody and not Store.pref_bool("hide_prosody"):
		var pcall: Object = request("/prosody", {"lang": lang, "text": tgt, "reading": "", "audio_b64": b64}, Api.TIMEOUT_SHORT)
		_pros_call = pcall
		_load_prosody(pcall, serial)
	var res: Dictionary = await score_req.wait()
	if serial != _serial:
		return
	_score_call = null
	if bool(res.get("cancelled", false)):
		status = "idle"
		_render()
		status_changed.emit()
		return
	if not bool(res.get("ok", false)):
		status = "error"
		error_text = error_message(res, ERROR_TEXT)
		_render()
		status_changed.emit()
		return
	apply_score(res.get("data", null))


func _load_prosody(pros_req: Object, serial: int) -> void:
	var res: Dictionary = await pros_req.wait()
	if serial != _serial or not is_instance_valid(self):
		return
	_pros_call = null
	if bool(res.get("ok", false)) and res.get("data", null) is Dictionary:
		prosody = res["data"]
	_apply_prosody()


## 소리가 있고 단어 목록(units)이 있는 채점 응답만 쓸 수 있다. 빈 {} · units 없음 · transcript "" 는 무음으로 본다.
static func is_valid_score(d: Variant) -> bool:
	if not (d is Dictionary):
		return false
	var dd: Dictionary = d
	if not (dd.get("units", null) is Array):
		return false
	if not (dd.get("transcript", null) is String) or str(dd["transcript"]).strip_edges() == "":
		return false
	return dd.get("score", null) is float or dd.get("score", null) is int


## /score 응답을 화면에 적용한다. 쓸 수 있으면 true (통계에 집계하고 `scored` 를 보낸다).
func apply_score(data: Variant) -> bool:
	if not is_valid_score(data):
		_set_silent()
		return false
	var d: Dictionary = data
	result = d
	status = "ok"
	var counted: bool = StudyLog.add_score(lang, d, source)
	if score_hook.is_valid():
		score_hook.call(lang, d, source, counted)
	_render()
	status_changed.emit()
	scored.emit(d, score_target if score_target != "" else target)
	return true


func _set_silent() -> void:
	result = {}
	prosody = {}
	status = "silent"
	_render()
	status_changed.emit()
	silent_result.emit(score_target if score_target != "" else target)


## 채점 결과의 음소 중 틀린 것 (p 글자 목록).
static func bad_phonemes(res: Dictionary) -> Array:
	var out: Array = []
	var units: Variant = res.get("units", null)
	if not (units is Array):
		return out
	for u in units:
		if not (u is Dictionary):
			continue
		for p in ScorePanel.phonemes_of(u as Dictionary):
			if not bool((p as Dictionary).get("ok", true)):
				out.append(str((p as Dictionary)["p"]))
	return out


# ---------------------------------------------------------------- drawing

func _render() -> void:
	UI.clear(self)
	_prosody_box = null
	match status:
		"scoring":
			add_child(UI.label("발음을 채점하는 중이에요…", "Muted"))
		"silent":
			add_child(notice(SILENT_TEXT))
		"error":
			add_child(notice(error_text if error_text != "" else ERROR_TEXT))
			if _last_audio != "":
				var rb := touch_button("다시 채점", "soft", Pal.accent(lang))
				rb.pressed.connect(retry_score)
				add_child(rb)
		"ok":
			var card := UI.card("Card", 12)
			card.body.add_child(ScorePanel.build(result, lang))
			add_child(card)
			if lang == "en" and show_prosody and not Store.pref_bool("hide_prosody"):
				_prosody_box = UI.vbox(8)
				add_child(_prosody_box)
				_apply_prosody()
	UI.fix_cjk(self)


func _apply_prosody() -> void:
	if _prosody_box == null or not is_instance_valid(_prosody_box):
		return
	UI.clear(_prosody_box)
	_prosody_box.add_child(UI.label("억양", "Eyebrow", false))
	if prosody.is_empty():
		var msg := "억양을 분석하는 중이에요…" if _pros_call != null else "억양 그래프를 불러오지 못했어요."
		_prosody_box.add_child(UI.label(msg, "Muted"))
		return
	var panel := ProsodyPanel.new(lang)
	panel.set_data(prosody)
	_prosody_box.add_child(panel)
	var tips: Variant = prosody.get("tips_ko", [])
	if prosody.get("mine", null) != null and tips is Array and not (tips as Array).is_empty():
		_prosody_box.add_child(ProsodyPanel.tips_box(tips as Array))
	UI.fix_cjk(_prosody_box)
