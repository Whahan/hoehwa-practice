class_name SongMemoDrill
extends VBoxContainer
## 가사 외우기 M4: 줄 하나의 단계 화면 (단계 그림 · 입력 · 말하기 · 자가 평가 · 읽어 주기 · 결과).
## 설계 docs/lyrics_memorize_design.md §3.2~3.7, §4.3, §5.4, §8 M4, §12.1b.
##
## 세션(MemoSession)이 줄·단계·평가를 쥐고, 이 위젯은 그리기와 입력만 한다 (채점은 MemoGrade, 진행은 MemoSession.submit 등).
## 쓰는 법: var d := SongMemoDrill.new(); 화면 본문에 add_child(d); d.setup(session, lang); 신호 event 를 받는다.
## 화면(M5)이 세션을 begin 하고, 줄 끝 통계(StudyLog "drill" +1, counted:true 일 때)와 요약 화면을 맡는다. 이 위젯은 StudyLog 를 부르지 않는다.
##
## 한 줄의 그림 (§3.2):
##   단계 0 (읽기)  : 줄 전부 + 읽기·한글 발음 + 해석. 읽어 주기 가능. [다음 단계]로 넘김.
##   중간 단계      : 가린 단위는 `____`, 해석만 보임. 읽어 주기 막힘.
##   맨 끝 (빈 화면): 줄 글자는 라벨·버튼·툴팁·접근성 이름 어디에도 없다. 줄 번호·(설정 켬이면) 앞 줄·입력칸/녹음 버튼만.
##   결과 뒤        : 정답 줄 전부 + 틀린 단위 표식(굵게·밑줄·✕, 색만으로 구분하지 않음) + 읽기·해석. 읽어 주기 가능.
## 답하기: 입력(AnswerEdit·SubmitBtn) 또는 말하기(RecordBox: 녹음 -> /stt -> MemoGrade speak).
##   /stt 가 갈 곳이 없거나(폰 단독, Route.decide "none") 오류면 SelfRatePanel 자가 평가. /stt 오류 자체는 시도로 세지 않는다.
##   말하기 오채점: [내가 맞게 말했어요](SelfPassBtn) -> MemoSession.self_pass().
##
## 신호 event(kind, data):
##   submit {grade, ev}            답 하나가 세션에 들어갔다 (ev = MemoSession.submit 의 결과, 이어서 ev.event 와 같은 이름의 신호도 나간다)
##   stage_pass / stage_fail / revealed / line_done / save_failed {ev, ...}
##   skip_read {ev}                읽기 단계를 넘겼다        reveal {ev}   [정답 보기]
##   self_pass {ev}                [내가 맞게 말했어요]      later {res}   [이 줄 나중에] (MemoSession.leave_line 결과)
##   next_line {pos}               다음 줄을 열었다          queue_end {summary}   큐가 끝났다 (MemoSession.finish 까지 불렀다)
##   answer_mode {mode}            입력/말하기 전환          stt_error {text}   /stt 오류 -> 자가 평가로 전환
##   silent {via}                  무음 (시도로 세지 않음)   listen {text_len}   읽어 주기를 눌렀다
## 노드 이름 (시험용): LineBox CueBox AnswerEdit SubmitBtn RecordBox RevealBtn LaterBtn ListenBtn ResultBox
##   그 밖: ReadBtn NextBtn NextLineBtn RetryBtn RetrySaveBtn SelfPassBtn ModeBtn CancelBtn ListenNote LineText AnswerLine Verdict

signal event(kind: String, data: Dictionary)

const MAX_INPUT := 600
const LOCK_MSEC := 250 ## 새 줄·새 단계를 연 직후 이 시간 동안 [정답 보기]·[이 줄 나중에]·[다음]을 무시한다 (이전 단추를 두 번 누른 것 방지)
const MSG_BLANK := "빈 화면이에요. 줄을 떠올려서 답해 보세요."
const MSG_LISTEN_LOCK := "정답을 확인한 뒤에 들을 수 있어요."
const MSG_STT_ERROR := "소리를 글자로 바꾸지 못했어요. 대신 스스로 평가해 보세요."
const MSG_SAVE_FAIL := "저장하지 못했어요. 저장 공간을 확인한 뒤 [다시 저장]을 눌러 주세요."
const MSG_LATER_FAIL := "저장하지 못해서 아직 나가지 않았어요. 저장 공간을 확인한 뒤 다시 눌러 주세요."
const MSG_END := "오늘 할 줄을 모두 했어요."
const MSG_NONE := "외울 줄이 없어요."

var session: MemoSession = null
var lang: String = "en"
var answer_mode: String = "type" ## "type" | "speak" (설정 memo_answer 가 처음 값, [ModeBtn]으로 바꿈)
var phase: String = "answer" ## answer | stt | self | result
var last: Dictionary = {} ## 마지막 결과 {ev, grade, prompt}
var stt_requests: int = 0 ## 이 위젯이 보낸 /stt 요청 수 (시험 확인용)
var lock_msec: int = LOCK_MSEC

var _serial: int = 0
var _call: Variant = null
var _typed: String = ""
var _notice: String = ""
var _hidden: bool = false
var _pending_rec: Dictionary = {}
var _lock_until: int = 0
var _edit: LineEdit = null
var _submit_btn: Button = null
var _listen_btn: Button = null
var _listen_note: Label = null
var _recorder: RecorderWidget = null
var _self_panel: SelfRatePanel = null


func _init() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name = "SongMemoDrill"


func _exit_tree() -> void:
	_serial += 1
	_cancel_call()
	if _recorder != null and is_instance_valid(_recorder):
		_recorder.stop_if_recording()
	Tts.stop()


# ---------------------------------------------------------------- 계약

## 세션(이미 begin 한 것)을 받아 첫 줄을 그린다.
func setup(session_in: MemoSession, lang_in: String = "en") -> void:
	session = session_in
	lang = "ja" if lang_in == "ja" else "en"
	var m: Variant = Store.prefs.get("memo_answer", "type")
	answer_mode = "speak" if (m is String and m == "speak") else "type"
	phase = "answer"
	last = {}
	_typed = ""
	_notice = ""
	_pending_rec = {}
	_hidden = false
	_open_lock()
	_render()


## 지금 상태를 다시 그린다 (화면이 다시 보일 때, 설정이 바뀌었을 때).
func render() -> void:
	_hidden = false
	_render()


## 화면을 떠날 때: 녹음 취소, 읽어 주기 멈춤, 늦게 오는 /stt 응답 버림.
func on_hide() -> void:
	_hidden = true
	_serial += 1
	_cancel_call()
	if _recorder != null and is_instance_valid(_recorder):
		_recorder.stop_if_recording()
	Tts.stop()
	if phase == "stt" or phase == "self":
		phase = "answer"
		_pending_rec = {}
		if is_inside_tree():
			_render()


## 시험·화면이 읽는 값: 지금 줄 글자 칸(LineText)의 글자. 빈 화면이면 "".
func line_text() -> String:
	var n: Node = find_child("LineText", true, false)
	if n is Label:
		return (n as Label).text
	return ""


# ---------------------------------------------------------------- 그리기

func _cancel_call() -> void:
	var c: Variant = _call
	_call = null
	SpeakDrill.cancel_call(c)


func _open_lock() -> void:
	_lock_until = Time.get_ticks_msec() + maxi(0, lock_msec)


func _locked() -> bool:
	return lock_msec > 0 and Time.get_ticks_msec() < _lock_until


func _acc() -> Color:
	return Pal.accent(lang)


func _line_field(cur: Dictionary, key: String) -> String:
	var ls: Variant = session.song.get("lines", []) if session != null else []
	var i: int = int(cur.get("line_i", -1))
	if ls is Array and i >= 0 and i < (ls as Array).size() and (ls as Array)[i] is Dictionary:
		var v: Variant = ((ls as Array)[i] as Dictionary).get(key, "")
		return v if v is String else ""
	return ""


## 단계에 맞는 줄 그림: 단계 0 = 전부, 중간 = 가린 줄, 맨 끝 = "" (줄 글자 없음).
func _prompt_for(cur: Dictionary) -> String:
	if bool(cur.get("read_only_stage", false)):
		return str(cur["text"])
	if bool(cur.get("final", false)):
		return ""
	return MemoMask.render(str(cur["text"]), lang, cur["hidden"])


func _answer_visible(cur: Dictionary) -> bool:
	return phase == "result" or phase == "self" or bool(cur.get("read_only_stage", false))


func _stage_name(cur: Dictionary) -> String:
	if bool(cur["read_only_stage"]):
		return "읽기"
	if bool(cur["final"]):
		return "빈 화면"
	var n: int = (cur["units"] as Array).size()
	var pct: int = roundi(100.0 * float(int(cur["hidden_count"])) / float(maxi(1, n)))
	return "%d%% 가림" % pct


func _render() -> void:
	if _recorder != null and is_instance_valid(_recorder):
		_recorder.stop_if_recording()
	UI.clear(self)
	_edit = null
	_submit_btn = null
	_listen_btn = null
	_listen_note = null
	_recorder = null
	_self_panel = null
	if session == null:
		add_child(SpeakDrill.notice(MSG_NONE, false))
		return
	var cur: Dictionary = session.current()
	if not bool(cur.get("ok", false)):
		add_child(SpeakDrill.notice(MSG_END if session.finished else MSG_NONE, false))
		return
	if bool(cur.get("done", false)) and phase != "result":
		# 화면이 줄 끝난 세션을 넘겨받았다: 결과 자리를 만든다
		phase = "result"
		last = {"ev": {"event": "line_done", "counted": not session.practice_only, "rating": int(cur.get("rating", 0))}, "grade": {}, "prompt": ""}
	var acc: Color = _acc()
	var card := UI.card("BigCard", 10)
	card.body.add_child(_header(cur))
	var cue: Control = _cue_box(cur)
	if cue != null:
		card.body.add_child(cue)
	card.body.add_child(_line_box(cur))
	card.body.add_child(_listen_row(cur, acc))
	match phase:
		"stt":
			_add_stt_wait(card.body)
		"self":
			_add_self(card.body, cur, acc)
		"result":
			pass
		_:
			_add_answer(card.body, cur, acc)
	add_child(card)
	if phase == "result":
		add_child(_result_box(cur, acc))
	UI.fix_cjk(self)
	SpeakDrill.fit_touch(self)
	_refresh_listen()


func _header(cur: Dictionary) -> Control:
	var col := UI.vbox(6)
	var head := UI.flow(8, 6)
	head.add_child(UI.colored("%d / %d" % [int(cur["pos"]), int(cur["total"])], Pal.MUTED, "Eyebrow", false))
	head.add_child(UI.chip_kind("새 줄" if str(cur["kind"]) == "new" else "복습", "info" if str(cur["kind"]) == "new" else "warn"))
	if bool(cur["practice_only"]):
		head.add_child(UI.chip_kind("연습만 (기록 안 함)", "neutral"))
	col.add_child(head)
	var sc: int = int(cur["stage_count"])
	var st: int = int(cur["stage"])
	col.add_child(UI.label("단계 %d / %d · %s" % [st + 1, sc, _stage_name(cur)], "Strong", false))
	var dots := UI.label("●".repeat(st + 1) + "○".repeat(maxi(0, sc - st - 1)), "Muted", false)
	dots.name = "StageDots"
	col.add_child(dots)
	return col


func _cue_box(cur: Dictionary) -> Control:
	var pt: String = str(cur.get("prev_text", ""))
	if pt == "":
		return null
	var cb := UI.vbox(4)
	cb.name = "CueBox"
	cb.add_child(UI.label("앞 줄", "Eyebrow", false))
	cb.add_child(UI.label(pt, "Muted"))
	return cb


func _line_box(cur: Dictionary) -> Control:
	var lb := UI.vbox(6)
	lb.name = "LineBox"
	var shown: String
	if phase == "result":
		shown = str(last.get("prompt", ""))
	elif phase == "self":
		shown = str(cur["text"])
	else:
		shown = _prompt_for(cur)
	if shown == "":
		var bh := UI.label(MSG_BLANK, "Muted")
		bh.name = "BlankHint"
		lb.add_child(bh)
	else:
		var lt := UI.label(shown, "H2")
		lt.name = "LineText"
		lb.add_child(lt)
	if _answer_visible(cur) and phase != "result":
		var rd: String = str(cur.get("reading", ""))
		ReadingLine.add(lb, rd, lang, rd != "", 0.0, _line_field(cur, "pron"))
	var ko: String = str(cur.get("ko", ""))
	if ko != "" and (_answer_visible(cur) or not bool(cur["final"])):
		var kl := UI.label(ko, "Muted")
		kl.name = "KoLabel"
		lb.add_child(kl)
	return lb


# ---- 읽어 주기

func _voice_note() -> String:
	if str(Tts.engine_now()) == "system" and not bool(Tts.system_voices_ok().get(lang, false)):
		return SystemTts.no_voice_text(lang)
	return ""


## 지금 줄을 읽어 줘도 정답이 새지 않는 때: 읽기 단계, 또는 답을 낸 뒤(결과·자가 평가). 빈 화면·중간 단계의 답하기 전에는 안 된다.
func _listen_allowed() -> bool:
	if session == null:
		return false
	var cur: Dictionary = session.current()
	if not bool(cur.get("ok", false)):
		return false
	if phase == "result" or phase == "self":
		return true
	if phase == "answer":
		return bool(cur["read_only_stage"])
	return false


func _listen_row(cur: Dictionary, acc: Color) -> Control:
	var col := UI.vbox(4)
	_listen_btn = SpeakDrill.touch_button("▶ 읽어 주기", "soft", acc)
	_listen_btn.name = "ListenBtn"
	_listen_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if not Platform.is_phone() else Control.SIZE_FILL
	_listen_btn.pressed.connect(listen)
	col.add_child(_listen_btn)
	_listen_note = UI.label("", "Small")
	_listen_note.name = "ListenNote"
	col.add_child(_listen_note)
	return col


func _refresh_listen() -> void:
	if _listen_btn == null or not is_instance_valid(_listen_btn):
		return
	var allowed: bool = _listen_allowed()
	var vn: String = _voice_note() if allowed else ""
	var note := ""
	if not allowed:
		note = MSG_LISTEN_LOCK if (phase == "answer" and session != null and not bool(session.current().get("read_only_stage", true))) else ""
	elif vn != "":
		note = vn
	_listen_btn.disabled = (not allowed) or vn != "" or Recorder.recording
	if _listen_note != null and is_instance_valid(_listen_note):
		_listen_note.text = note
		_listen_note.visible = note != ""


## 줄 읽어 주기 (Tts: PC Kokoro, 폰은 시스템 음성). 정답이 새는 단계에서는 아무것도 하지 않는다. 불렀으면 true.
func listen() -> bool:
	if not _listen_allowed() or Recorder.recording or _voice_note() != "":
		return false
	var cur: Dictionary = session.current()
	var t: String = str(cur["text"])
	if t.strip_edges() == "":
		return false
	Tts.speak(t, lang, false)
	event.emit("listen", {"text_len": t.length()})
	return true


func _on_rec_state(is_rec: bool) -> void:
	if is_rec:
		Tts.stop() # 녹음 중에는 소리를 멈춘다 (마이크가 읽어 주는 소리를 받지 않게)
	_refresh_listen()


# ---- 답하기

func _add_answer(body: VBoxContainer, cur: Dictionary, acc: Color) -> void:
	if _notice != "":
		body.add_child(SpeakDrill.notice(_notice, true))
	if bool(cur["read_only_stage"]):
		var rb := SpeakDrill.touch_button("다음 단계 ▶", "primary", acc)
		rb.name = "ReadBtn"
		rb.pressed.connect(_on_read_next)
		body.add_child(rb)
		body.add_child(_later_btn())
		return
	var guide := "떠올려서 " + ("일본어" if lang == "ja" else "영어") + "로 " + ("써 보세요" if answer_mode == "type" else "말해 보세요")
	body.add_child(UI.label(guide, "Muted"))
	if answer_mode == "speak":
		var rec := VBoxContainer.new()
		rec.name = "RecordBox"
		rec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_recorder = RecorderWidget.new(false, acc, Platform.is_pc())
		_recorder.wide = true
		_recorder.idle_text = "말하기"
		_recorder.recorded.connect(_on_recorded)
		_recorder.state_changed.connect(_on_rec_state)
		rec.add_child(_recorder)
		body.add_child(rec)
	else:
		_edit = LineEdit.new()
		_edit.name = "AnswerEdit"
		_edit.max_length = MAX_INPUT
		_edit.placeholder_text = "떠올린 줄을 써 보세요"
		_edit.custom_minimum_size.y = Ds.field_h()
		_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_edit.text = _typed
		_edit.text_changed.connect(_on_typed)
		_edit.text_submitted.connect(func(_t: String) -> void: _on_submit_pressed())
		body.add_child(_edit)
		_submit_btn = SpeakDrill.touch_button("확인", "primary", acc)
		_submit_btn.name = "SubmitBtn"
		_submit_btn.disabled = _typed.strip_edges() == ""
		_submit_btn.pressed.connect(_on_submit_pressed)
		body.add_child(_submit_btn)
		if not Platform.is_phone():
			call_deferred("_focus_edit")
	var row := UI.flow(8, 8)
	var rv := SpeakDrill.touch_button("정답 보기", "soft", acc)
	rv.name = "RevealBtn"
	rv.pressed.connect(_on_reveal)
	row.add_child(rv)
	row.add_child(_later_btn())
	var mb := SpeakDrill.touch_button("입력으로 답하기" if answer_mode == "speak" else "말하기로 답하기", "flat", Pal.MUTED)
	mb.name = "ModeBtn"
	mb.pressed.connect(_on_mode)
	row.add_child(mb)
	body.add_child(row)


func _later_btn() -> Button:
	var b := SpeakDrill.touch_button("이 줄 나중에", "flat", Pal.MUTED)
	b.name = "LaterBtn"
	b.pressed.connect(_on_later)
	return b


func _add_stt_wait(body: VBoxContainer) -> void:
	var w := UI.label("말한 것을 듣고 있어요…", "Muted")
	w.name = "SttWait"
	body.add_child(w)
	var cb := SpeakDrill.touch_button("취소", "flat", Pal.MUTED)
	cb.name = "CancelBtn"
	cb.pressed.connect(_on_cancel_stt)
	body.add_child(cb)


func _add_self(body: VBoxContainer, cur: Dictionary, acc: Color) -> void:
	if _notice != "":
		body.add_child(SpeakDrill.notice(_notice, true))
	_self_panel = SelfRatePanel.new(lang, str(cur["text"]), _pending_rec, acc)
	_self_panel.rated.connect(_on_self_rated)
	body.add_child(_self_panel)
	body.add_child(_later_btn())


func set_typed(t: String) -> void:
	_on_typed(t)


func _on_typed(t: String) -> void:
	_typed = t.left(MAX_INPUT)
	if _submit_btn != null and is_instance_valid(_submit_btn):
		_submit_btn.disabled = _typed.strip_edges() == ""


func _on_mode() -> void:
	if phase != "answer":
		return
	answer_mode = "type" if answer_mode == "speak" else "speak"
	_notice = ""
	_render()
	event.emit("answer_mode", {"mode": answer_mode})


## 입력 확인. 빈 입력은 시도로 세지 않는다. 낸 것이 있으면 true.
func submit_typed() -> bool:
	return _on_submit_pressed()


func _on_submit_pressed() -> bool:
	if phase != "answer" or session == null:
		return false
	var cur: Dictionary = session.current()
	if not bool(cur.get("ok", false)) or bool(cur["read_only_stage"]):
		return false
	var said: String = _typed.left(MAX_INPUT)
	if said.strip_edges() == "":
		return false
	_typed = ""
	_submit_grade(MemoGrade.grade(lang, said, {"text": cur["text"], "reading": cur["reading"]}, "type"), cur)
	return true


func _on_read_next() -> void:
	if phase != "answer" or session == null or _locked():
		return
	var ev: Dictionary = session.skip_read()
	_notice = ""
	_open_lock()
	_render()
	event.emit("skip_read", {"ev": ev})


# ---- 말하기 (/stt) · 자가 평가

func _on_recorded(rec: Dictionary) -> void:
	if _hidden or phase != "answer" or session == null or not is_inside_tree():
		return
	var cur: Dictionary = session.current()
	if not bool(cur.get("ok", false)) or bool(cur["read_only_stage"]):
		return
	if Route.decide("POST", "/stt", {}) == "none":
		_begin_self(rec, "") # 채점할 곳이 없다 (폰 단독): /stt 를 보내지 않는다
		return
	var b64: String = str(rec.get("b64", ""))
	if b64 == "":
		_silent("speak")
		return
	_serial += 1
	var s: int = _serial
	_pending_rec = rec
	_notice = ""
	phase = "stt"
	_render()
	stt_requests += 1
	var req: Object = SpeakDrill.request("/stt", {"lang": lang, "audio_b64": b64}, Api.TIMEOUT_SHORT)
	_call = req
	var res: Dictionary = await req.wait()
	if s != _serial or _hidden:
		return
	_call = null
	if bool(res.get("cancelled", false)):
		phase = "answer"
		_render()
		return
	var data: Variant = res.get("data", null)
	if not bool(res.get("ok", false)) or not (data is Dictionary):
		var why: String = SpeakDrill.error_message(res, "")
		var msg: String = MSG_STT_ERROR if why == "" else why + " " + MSG_STT_ERROR
		event.emit("stt_error", {"text": msg})
		_begin_self(rec, msg) # 시도로 세지 않고 자가 평가로 바꾼다
		return
	var text: String = str((data as Dictionary).get("text", "")).strip_edges()
	if text == "":
		_silent("speak")
		return
	var cur2: Dictionary = session.current()
	if not bool(cur2.get("ok", false)):
		phase = "answer"
		_render()
		return
	_submit_grade(MemoGrade.grade(lang, text, {"text": cur2["text"], "reading": cur2["reading"]}, "speak"), cur2)


func _silent(via: String) -> void:
	phase = "answer"
	_notice = SpeakDrill.SILENT_TEXT
	_pending_rec = {}
	_render()
	event.emit("silent", {"via": via})


func _begin_self(rec: Dictionary, notice_text: String) -> void:
	_serial += 1
	_cancel_call()
	_pending_rec = rec
	_notice = notice_text
	phase = "self"
	_render()


func _on_self_rated(good: bool) -> void:
	if phase != "self" or session == null:
		return
	var cur: Dictionary = session.current()
	_pending_rec = {}
	_notice = ""
	_submit_grade(MemoGrade.self_result(good), cur)


func _on_cancel_stt() -> void:
	if phase != "stt":
		return
	_serial += 1
	_cancel_call()
	phase = "answer"
	_render()


# ---- 세션에 낸다

func _submit_grade(g: Dictionary, cur: Dictionary) -> void:
	var prompt: String = _prompt_for(cur)
	var ev: Dictionary = session.submit(g)
	var kind: String = str(ev.get("event", ""))
	if kind == "ignored":
		if str(ev.get("reason", "")) == "silent":
			_silent(str(g.get("via", "")))
		else:
			phase = "answer"
			_render()
		return
	_notice = ""
	last = {"ev": ev, "grade": g, "prompt": prompt}
	phase = "result"
	_open_lock()
	_render()
	event.emit("submit", {"grade": g, "ev": ev})
	event.emit(kind, {"ev": ev, "grade": g})


func _on_reveal() -> void:
	if (phase != "answer" and not (phase == "result" and str(last.get("ev", {}).get("event", "")) == "stage_fail")) or session == null or _locked():
		return
	var cur: Dictionary = session.current()
	var prompt: String = str(last.get("prompt", "")) if phase == "result" else _prompt_for(cur)
	var ev: Dictionary = session.reveal()
	if str(ev.get("event", "")) == "ignored":
		return
	last = {"ev": ev, "grade": {}, "prompt": prompt}
	_notice = ""
	phase = "result"
	_open_lock()
	_render()
	event.emit("reveal", {"ev": ev})
	event.emit("revealed", {"ev": ev})


func _on_retry() -> void:
	if phase != "result" or _locked():
		return
	phase = "answer"
	last = {}
	_typed = ""
	_notice = ""
	_open_lock()
	_render()


func _on_next_stage() -> void:
	if phase != "result" or _locked():
		return
	phase = "answer"
	last = {}
	_typed = ""
	_notice = ""
	_open_lock()
	_render()


func _on_self_pass() -> void:
	if phase != "result" or session == null:
		return
	var prompt: String = str(last.get("prompt", ""))
	var ev: Dictionary = session.self_pass()
	if str(ev.get("event", "")) == "ignored":
		return
	var g: Dictionary = MemoGrade.self_result(true)
	last = {"ev": ev, "grade": g, "prompt": prompt}
	_open_lock()
	_render()
	event.emit("self_pass", {"ev": ev})
	event.emit(str(ev.get("event", "")), {"ev": ev, "grade": g})


func _on_retry_save() -> void:
	if phase != "result" or session == null:
		return
	var ev: Dictionary = session.retry_save()
	if str(ev.get("event", "")) == "ignored":
		return
	last["ev"] = ev
	_render()
	event.emit(str(ev.get("event", "")), {"ev": ev, "grade": last.get("grade", {})})


func _on_later() -> void:
	if session == null or _locked():
		return
	var res: Dictionary = session.leave_line()
	if not bool(res.get("ok", false)):
		_notice = MSG_LATER_FAIL
		_render()
		event.emit("later", {"res": res})
		return
	event.emit("later", {"res": res})
	_go_next()


func _on_next_line() -> void:
	if phase != "result" or session == null or _locked():
		return
	_go_next()


func _go_next() -> void:
	var more: bool = session.next_line()
	phase = "answer"
	last = {}
	_typed = ""
	_notice = ""
	_pending_rec = {}
	_open_lock()
	_render()
	if more:
		event.emit("next_line", {"pos": int(session.current().get("pos", 0))})
	else:
		event.emit("queue_end", {"summary": session.summary()})


# ---------------------------------------------------------------- 결과

static func _after_text(secs: int) -> String:
	if secs < 90:
		return "1분"
	if secs < 3600 * 2:
		return "%d분" % roundi(float(secs) / 60.0)
	if secs < 86400 * 2:
		return "%d시간" % roundi(float(secs) / 3600.0)
	return "%d일" % roundi(float(secs) / 86400.0)


## 정답 줄 BBCode: 틀린 단위만 굵게·밑줄·✕ (색은 보조). marks 가 없으면(정답 공개·자가 평가) 그냥 글자.
static func marked_bbcode(text: String, lang_in: String, units: Array, aligned: bool, marks: Array) -> String:
	if marks.is_empty() or marks.size() != units.size():
		return UI.bb_escape(text)
	var bad: String = Pal.BAD_ON.to_html(false)
	if not aligned:
		var parts: PackedStringArray = PackedStringArray()
		for k in units.size():
			var w: String = UI.bb_escape(str((units[k] as Dictionary)["w"]))
			parts.append(w if bool(marks[k]) else "[b][u][color=#%s]✕%s[/color][/u][/b]" % [bad, w])
		return " ".join(parts)
	var out: String = ""
	var pos: int = 0
	for k in units.size():
		var d: Dictionary = units[k]
		out += UI.bb_escape(text.substr(pos, int(d["s"]) - pos))
		var w2: String = UI.bb_escape(str(d["w"]))
		out += w2 if bool(marks[k]) else "[b][u][color=#%s]✕%s[/color][/u][/b]" % [bad, w2]
		pos = int(d["e"])
	out += UI.bb_escape(text.substr(pos))
	return out


func _result_box(cur: Dictionary, acc: Color) -> Control:
	var box := UI.card("Card", 8)
	box.name = "ResultBox"
	var ev: Dictionary = last.get("ev", {})
	var g: Dictionary = last.get("grade", {})
	var kind: String = str(ev.get("event", ""))
	var via: String = str(g.get("via", ""))
	var score: int = int(g.get("score", 0))
	var verdict := ""
	var vcolor: Color = Pal.OK_ON
	match kind:
		"stage_pass":
			verdict = "✓ 통과 (스스로 평가: 잘했어요)" if via == "self" else "✓ 통과  %d점" % score
		"line_done":
			verdict = "✓ 이 줄을 끝냈어요"
			if via == "self":
				verdict += " (스스로 평가)"
			elif via != "":
				verdict += "  %d점" % score
		"stage_fail":
			vcolor = Pal.WARN_ON
			verdict = "✕ 아직이에요 (스스로 평가: 다시)" if via == "self" else "✕ %d점 · 통과 기준은 %d점이에요" % [score, int(g.get("threshold", 0))]
		"revealed":
			vcolor = Pal.WARN_ON
			verdict = "정답을 알려 드렸어요"
		"save_failed":
			vcolor = Pal.BAD_ON
			verdict = "줄은 끝났지만 저장하지 못했어요"
		_:
			verdict = ""
	if verdict != "":
		var vl := UI.colored(verdict, vcolor, "Strong")
		vl.name = "Verdict"
		box.body.add_child(vl)
	var said: String = str(g.get("said", ""))
	if said != "" and (via == "type" or via == "speak"):
		box.body.add_child(UI.label(("내가 쓴 것:  " if via == "type" else "인식된 말:  ") + said, "Muted"))
	box.body.add_child(UI.label("정답", "Eyebrow", false))
	var al := UI.rich(marked_bbcode(str(cur["text"]), lang, cur["units"], bool(cur["aligned"]), g.get("marks", [])), 18)
	al.name = "AnswerLine"
	al.add_theme_color_override("default_color", Pal.INK)
	box.body.add_child(al)
	var any_bad := false
	for m in g.get("marks", []):
		if not bool(m):
			any_bad = true
	if any_bad:
		box.body.add_child(UI.label("✕ 와 밑줄이 있는 부분이 틀렸거나 빠진 부분이에요.", "Small"))
	var extra: Variant = g.get("extra", [])
	if extra is Array and not (extra as Array).is_empty():
		box.body.add_child(UI.colored("정답에 없는 단어:  " + ", ".join(PackedStringArray(extra)), Pal.WARN_ON, "Small"))
	var rd: String = str(cur.get("reading", ""))
	ReadingLine.add(box.body, rd, lang, rd != "", 0.0, _line_field(cur, "pron"))
	match kind:
		"stage_pass":
			var nb := SpeakDrill.touch_button("다음 단계 ▶", "primary", acc)
			nb.name = "NextBtn"
			nb.pressed.connect(_on_next_stage)
			box.body.add_child(nb)
		"stage_fail":
			var left: int = maxi(0, MemoSession.FAILS_TO_REVEAL - int(ev.get("fails_stage", 0)))
			box.body.add_child(UI.label("같은 단계에서 %d번 더 틀리면 정답을 알려 드리고 한 단계 쉬운 단계로 내려가요." % left, "Small"))
			var rt := SpeakDrill.touch_button("다시 해 보기", "primary", acc)
			rt.name = "RetryBtn"
			rt.pressed.connect(_on_retry)
			box.body.add_child(rt)
			var rv := SpeakDrill.touch_button("정답 보기 (한 단계 쉽게)", "soft", acc)
			rv.name = "RevealBtn"
			rv.pressed.connect(_on_reveal)
			box.body.add_child(rv)
		"revealed":
			var dropped: bool = bool(ev.get("dropped", false))
			box.body.add_child(UI.label(("단계가 내려갔어요: %d → %d. 한 단계 쉬운 곳에서 다시 해 봐요." % [int(ev.get("stage_from", 0)) + 1, int(ev.get("stage", 0)) + 1]) if dropped else "같은 단계에서 다시 해 봐요.", "Small"))
			var cb := SpeakDrill.touch_button("계속 ▶", "primary", acc)
			cb.name = "NextBtn"
			cb.pressed.connect(_on_next_stage)
			box.body.add_child(cb)
		"line_done":
			box.body.add_child(_rating_note(ev))
			var more: bool = int(cur.get("pos", 0)) < int(cur.get("total", 0))
			var lb := SpeakDrill.touch_button("다음 줄 ▶" if more else "끝내기", "primary", acc)
			lb.name = "NextLineBtn"
			lb.pressed.connect(_on_next_line)
			box.body.add_child(lb)
		"save_failed":
			box.body.add_child(SpeakDrill.notice(MSG_SAVE_FAIL, true))
			var sb := SpeakDrill.touch_button("다시 저장", "primary", acc)
			sb.name = "RetrySaveBtn"
			sb.pressed.connect(_on_retry_save)
			box.body.add_child(sb)
			box.body.add_child(_later_btn())
	# 말하기 오채점: 틀렸다고 나왔어도 스스로 맞다고 할 수 있다 (사용자 결정 Q3)
	if via == "speak" and not bool(g.get("passed", false)) and (kind == "stage_fail" or kind == "revealed"):
		var sp := SpeakDrill.touch_button("내가 맞게 말했어요", "outline", acc)
		sp.name = "SelfPassBtn"
		sp.pressed.connect(_on_self_pass)
		box.body.add_child(sp)
	return box


func _rating_note(ev: Dictionary) -> Control:
	if not bool(ev.get("counted", false)):
		return UI.label("연습만 했어요. 복습 기록은 바꾸지 않았어요.", "Muted")
	var r: int = int(ev.get("rating", 0))
	var txt: String
	match r:
		1:
			txt = "다시 만나요: 곧 한 번 더 물어볼게요."
		2:
			txt = "아슬아슬했어요: 조금 이르게 다시 물어볼게요."
		_:
			txt = "잘했어요!"
	var card: Variant = ev.get("card", null)
	if card is Dictionary and (card as Dictionary).has("due"):
		var secs: int = maxi(0, int((card as Dictionary)["due"]) - session.now)
		txt += " 다음 복습은 약 %s 뒤예요." % _after_text(secs)
	var l := UI.label(txt, "Muted")
	l.name = "RatingNote"
	return l


func _focus_edit() -> void:
	if _edit != null and is_instance_valid(_edit) and _edit.is_inside_tree():
		_edit.grab_focus()
