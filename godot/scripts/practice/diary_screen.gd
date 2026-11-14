class_name DiaryScreen
extends Control
## 한 줄 일기 화면 (영어 / 일본어). 설계 docs/v170_design.md §1.5, §2.4, §2.5.
##   home   : 쓰기(1~3문장) + [고쳐 보기] / [저장만 하기] + 최근 일기 목록
##   working: "1 / 3 문장 고치는 중…" + [취소]
##   result : 문장마다 쓴 것 / 고침 / 이유 / 읽기, 복습 카드 안내, [다시 쓰기] [일기 목록]
##   view   : 목록의 [보기]
## 개인 정보 (설계 R-C1, 1파 검토에서 넘어온 요구):
##   - /fix 는 언제나 "private": true 로 보낸다 (문장당 1번, 최대 3번, 한 번에 문장 하나, prev_ai "").
##   - 일기 글은 소리로 읽지 않는다: 이 화면은 Tts 를 부르지 않고 /tts 도 요청하지 않는다 (서버가 /tts 문장 앞 30자를 로그에 남기기 때문).
##   - 일기 글은 print / push_warning / Toast 로 내보내지 않는다. 저장은 DiaryStore(user://diary.json) 한 곳뿐이다.
##   - 응답에 reading 키가 없으면 옛 PC 프로그램(private 를 모르고 문장을 로그·캐시에 남김)이다: OLD_SERVER_PRIVACY 를 보이고
##     그 일기는 저장만 해 두며, 앱을 다시 열 때까지(또는 PC 연결이 끊겼다 다시 이어질 때까지) 더는 보내지 않는다.
## 연습 허브 하위 화면 계약: `signal closed`, `open(lang, args)`, `go_back() -> bool`, `on_hide()`.

signal closed

const TITLE := "한 줄 일기"
const CONSENT_PREF := "diary_consent"
const CONSENT_TITLE := "일기를 고치기 전에"
const CONSENT_PARAS := [
	"쓴 문장이 AI 서비스로 전송돼요. (이 PC의 로그·캐시에는 남지 않아요.)",
	"일기 원문은 이 기기에만 저장돼요. 다른 기기로 동기화되지 않아요.",
	"고친 문장은 복습 카드가 되어 PC·폰에 동기화돼요. 원문은 카드에 넣지 않아요.",
]
const OLD_SERVER_PRIVACY := "PC 프로그램을 최신 버전으로 업데이트하면 일기 내용이 PC에 남지 않아요"
const OLD_SERVER_EXTRA := "이 PC 프로그램은 옛 버전이라 방금 보낸 문장이 PC의 기록에 남았을 수 있어요. 업데이트하기 전에는 더 보내지 않아요."
const NOTE_NO_PC := "AI로 고치려면 PC에 연결해야 해요. 지금은 [저장만 하기]로 저장해 두고, 나중에 목록의 [고치기]로 고칠 수 있어요."
const NOTE_AI_OFF := "PC의 AI가 아직 연결되지 않았어요. 연결하기 전에는 [저장만 하기]로 저장해 두고, 나중에 목록의 [고치기]로 고칠 수 있어요."
const NOTE_NO_MIC := "음성 입력은 PC에 연결했을 때만 돼요."
const MSG_SAVED_LATER := "일기는 저장돼 있어요. 아래 목록의 [고치기]로 다시 고칠 수 있어요."
const MSG_NO_CHANGE := "잘 썼어요. 고칠 곳이 없어요."
const LIST_STEP := 20
const BOX_LIMIT := 1000 ## 입력칸에 들어가는 글자 수의 하드 한도 (300자 넘는 글은 안내로 거절한다)

## 시험 전용: Callable() -> "ready" | "no_pc" | "ai_off". 없으면 Route / Backend 로 정한다.
static var ai_hook: Callable = Callable()
## 시험 전용: Callable() -> bool (음성 입력 가능). 없으면 Route.caps() 의 stt 로 정한다.
static var stt_hook: Callable = Callable()
## 옛 서버를 본 적이 있다 (응답에 reading 키가 없었다). 있으면 [고쳐 보기]는 더 보내지 않는다.
static var old_server_seen: bool = false

var lang: String = "en"
var stage: String = "home" ## home | working | result | view
var work_idx: int = 0
var work_total: int = 0
var view_id: String = ""
var consent_asks: int = 0
var last_sheet: Sheet = null
var list_limit: int = LIST_STEP
var requests_sent: int = 0 ## /fix 요청 수 (시험용)

var _shell: Dictionary = {}
var _text: String = ""
var _msg: String = ""
var _msg_bad: bool = false
var _cards_msg: String = ""
var _serial: int = 0
var _call = null
var _busy: bool = false
var _stt_busy: bool = false
var _ai: String = "ready"
var _stt_ok: bool = false
var _scroll_to_list: bool = false
var _edit: TextEdit = null
var _counter: Label = null
var _reason: Label = null
var _fix_btn: Button = null
var _save_btn: Button = null
var _mic: RecorderWidget = null
var _list_anchor: Control = null
var _after_consent: Callable = Callable()


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)


func _enter_tree() -> void:
	if not Backend.status_changed.is_connected(_on_backend_status):
		Backend.status_changed.connect(_on_backend_status)


func _exit_tree() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	if Backend.status_changed.is_connected(_on_backend_status):
		Backend.status_changed.disconnect(_on_backend_status)


func open(l: String, _args: Dictionary = {}) -> void:
	lang = l if (l == "en" or l == "ja") else Store.lang()
	_reset()
	_render()


func on_hide() -> void:
	if _mic != null and is_instance_valid(_mic):
		_mic.stop_if_recording()


## 허브로 돌아왔을 때나 AI·PC 상태가 바뀌었을 때 다시 그린다 (쓰던 글은 그대로).
func refresh() -> void:
	if stage == "home" or stage == "view":
		_render()


## 한 단계씩 뒤로: 고치는 중 -> 쓰기 -> 허브.
func go_back() -> bool:
	if Sheet.handle_back():
		return true
	match stage:
		"working":
			cancel_fix()
			return true
		"result", "view":
			stage = "home"
			_render()
			return true
	closed.emit()
	return true


## PC 연결이 끊겼다 이어지면 PC 프로그램이 다시 켜졌을 수 있으니 옛 서버 표시를 푼다.
func _on_backend_status() -> void:
	if Backend.status != Backend.Status.READY:
		old_server_seen = false
		refresh()


func _reset() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_busy = false
	_stt_busy = false
	stage = "home"
	_text = ""
	_msg = ""
	_msg_bad = false
	_cards_msg = ""
	view_id = ""
	list_limit = LIST_STEP
	_scroll_to_list = false


# ---------------------------------------------------------------- states (pure helpers)

## "ready" | "no_pc" | "ai_off": 일기를 AI 로 고칠 수 있나. PC 만 센다(폰 단독은 저장만).
static func ai_state() -> String:
	if ai_hook.is_valid():
		return str(ai_hook.call())
	var fx: Dictionary = (Route.caps()["items"] as Dictionary).get("fix", {})
	if str(fx.get("use", "none")) != "pc" or not Route.pc_ready():
		return "no_pc"
	if not bool(Backend.health.get("llm", false)):
		return "ai_off"
	return "ready"


static func stt_ok() -> bool:
	if stt_hook.is_valid():
		return bool(stt_hook.call())
	var st: Dictionary = (Route.caps()["items"] as Dictionary).get("stt", {})
	return str(st.get("use", "none")) == "pc" and Route.pc_ready()


## "문장 2/3 · 87/300자". 진행 표시는 이 한 함수에서만 만든다.
static func counter_text(text: String, l: String) -> String:
	var t: String = text.strip_edges()
	var n: int = DiaryLogic.split(t, l).size()
	return "문장 %d/%d · %d/%d자" % [n, DiaryLogic.MAX_SENTENCES, t.length(), DiaryLogic.MAX_CHARS]


## "1 / 3 문장 고치는 중…"
static func progress_text(i: int, n: int) -> String:
	return "%d / %d 문장 고치는 중…" % [i, n]


static func pending_text(n: int) -> String:
	return "고치기 대기 %d개" % n


static func state_text(state: String) -> String:
	return "고침 완료" if state == "fixed" else "고치기 대기"


static func consent_text() -> String:
	return "\n\n".join(PackedStringArray(CONSENT_PARAS))


static func ai_note(state: String) -> String:
	match state:
		"no_pc":
			return NOTE_NO_PC
		"ai_off":
			return NOTE_AI_OFF
	return ""


## AI 로 고칠 수 있나: PC 와 AI 가 준비됐고, 옛 PC 프로그램을 본 적이 없다.
func can_fix() -> bool:
	return _ai == "ready" and not old_server_seen


func consented() -> bool:
	return Store.pref_bool(CONSENT_PREF)


func _fix_stage() -> int:
	var pos: Dictionary = Store.position()
	return clampi(Plan.stage_of(int(pos.get("n", 1))), 1, 4)


func _acc() -> Color:
	return Pal.accent(lang)


func _lang_name() -> String:
	return "일본어" if lang == "ja" else "영어"


# ---------------------------------------------------------------- input

func set_text(t: String) -> void:
	_text = t.left(BOX_LIMIT)
	_msg = ""
	_update_input_state()


## 입력칸 아래 안내와 버튼 켜짐 상태를 (화면을 다시 그리지 않고) 갱신한다.
func _update_input_state() -> void:
	var chk: Dictionary = DiaryLogic.check_input(_text, lang)
	var valid: bool = bool(chk["ok"])
	if _counter != null and is_instance_valid(_counter):
		_counter.text = counter_text(_text, lang)
	if _reason != null and is_instance_valid(_reason):
		var r: String = ""
		if not valid and _text.strip_edges() != "":
			r = DiaryLogic.reason_text(str(chk["reason"]), lang)
		_reason.text = r
		_reason.visible = r != ""
	var writable: bool = not DiaryStore.is_read_only()
	if _fix_btn != null and is_instance_valid(_fix_btn):
		_fix_btn.disabled = not (valid and writable and can_fix() and not _busy)
	if _save_btn != null and is_instance_valid(_save_btn):
		_save_btn.disabled = not (valid and writable and not _busy)


func _on_edit_changed() -> void:
	if _edit == null or not is_instance_valid(_edit):
		return
	var t: String = _edit.text
	if t.length() > BOX_LIMIT:
		_edit.text = t.left(BOX_LIMIT)
		_edit.set_caret_line(_edit.get_line_count() - 1)
		_edit.set_caret_column(_edit.get_line(_edit.get_line_count() - 1).length())
		t = _edit.text
	set_text(t)


# ---------------------------------------------------------------- save only

func save_only() -> void:
	if stage != "home" or _busy:
		return
	var chk: Dictionary = DiaryLogic.check_input(_text, lang)
	if not bool(chk["ok"]):
		_say(DiaryLogic.reason_text(str(chk["reason"]), lang), true)
		return
	var r: Dictionary = DiaryStore.add(lang, _text)
	if not bool(r["ok"]):
		_say(_add_fail_text(str(r["reason"])), true)
		return
	_text = ""
	if bool(r.get("existed", false)):
		_say("같은 일기가 오늘 이미 저장돼 있어요.", false)
	else:
		_say("저장했어요. 나중에 목록의 [고치기]로 고칠 수 있어요.", false)
	_scroll_to_list = true
	_render()


static func _add_fail_text(reason: String) -> String:
	match reason:
		"full":
			return "일기가 %d개예요. 오래된 것을 지워 주세요." % DiaryStore.MAX_ENTRIES
		"read_only":
			return "일기 파일을 읽지 못해서 저장할 수 없어요. 앱을 다시 열어 보세요."
		"write_failed":
			return "일기를 저장하지 못했어요. 저장 공간을 확인해 주세요."
	return "이 글은 저장할 수 없어요."


func _say(msg: String, bad: bool) -> void:
	_msg = msg
	_msg_bad = bad
	if stage == "home":
		_render()


# ---------------------------------------------------------------- fix (button entry points)

## [고쳐 보기]: 입력 검사 -> (처음이면) 동의 시트 -> 저장 -> 문장마다 /fix.
func fix_text() -> void:
	if stage != "home" or _busy:
		return
	var chk: Dictionary = DiaryLogic.check_input(_text, lang)
	if not bool(chk["ok"]):
		_say(DiaryLogic.reason_text(str(chk["reason"]), lang), true)
		return
	_ai = ai_state()
	if not can_fix():
		return
	if not consented():
		_ask_consent(_fix_text_after_consent)
		return
	_fix_text_after_consent()


func _fix_text_after_consent() -> void:
	if stage != "home" or _busy:
		return
	var r: Dictionary = DiaryStore.add(lang, _text)
	if not bool(r["ok"]):
		_say(_add_fail_text(str(r["reason"])), true)
		return
	var id: String = str(r["id"])
	if bool(r.get("existed", false)):
		var e: Dictionary = DiaryStore.get_entry(id)
		if str(e.get("state", "")) == "fixed":
			_text = ""
			_cards_msg = ""
			view_id = id
			stage = "result"
			_render()
			return
	_run_fix(id)


## 목록의 [고치기] (저장만 해 둔 일기).
func fix_entry(id: String) -> void:
	if (stage != "home" and stage != "view") or _busy:
		return
	var e: Dictionary = DiaryStore.get_entry(id)
	if e.is_empty() or str(e.get("state", "")) != "saved":
		return
	_ai = ai_state()
	if not can_fix():
		stage = "home"
		if old_server_seen:
			_say(OLD_SERVER_PRIVACY + ". " + OLD_SERVER_EXTRA, true)
		else:
			_say(ai_note(_ai), true)
		return
	if not consented():
		_ask_consent(func() -> void: _run_fix(id))
		return
	_run_fix(id)


func _ask_consent(then: Callable) -> void:
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	consent_asks += 1
	_after_consent = then
	var body := UI.vbox(10)
	for para in CONSENT_PARAS:
		body.add_child(UI.label(para))
	last_sheet = Sheet.open(self, CONSENT_TITLE, body, [
		{"id": "agree", "text": "동의하고 고치기", "kind": "primary"},
		{"id": "later", "text": "나중에", "kind": "flat"},
	], {"max_h_frac": 0.85})
	last_sheet.closed.connect(_on_consent_closed)


func _on_consent_closed(result: Variant) -> void:
	var then: Callable = _after_consent
	_after_consent = Callable()
	if str(result) != "agree":
		return ## 나중에·닫기: 아무것도 저장하지 않고 아무것도 보내지 않는다 (쓴 글은 입력칸에 그대로)
	Store.set_pref(CONSENT_PREF, true)
	if then.is_valid():
		then.call()


# ---------------------------------------------------------------- fix (requests)

func cancel_fix() -> void:
	if stage != "working":
		return
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_busy = false
	_fail("취소했어요.")


## 일기 하나를 문장마다 /fix(private) 로 고친다. 한 문장이라도 못 고치면 그 일기는 저장만 해 두고 이유를 보인다.
func _run_fix(id: String) -> void:
	var entry: Dictionary = DiaryStore.get_entry(id)
	if entry.is_empty():
		return
	var chk: Dictionary = DiaryLogic.check_input(str(entry["text"]), lang)
	if not bool(chk["ok"]):
		_fail(DiaryLogic.reason_text(str(chk["reason"]), lang))
		return
	var sents: Array = chk["sentences"]
	_serial += 1
	var serial: int = _serial
	_busy = true
	stage = "working"
	work_total = sents.size()
	var items: Array = []
	for i in sents.size():
		work_idx = i + 1
		_render()
		var body := {"lang": lang, "stage": _fix_stage(), "text": str(sents[i]), "prev_ai": "", "private": true}
		requests_sent += 1
		var req: Object = SpeakDrill.request("/fix", body, Api.TIMEOUT_LLM)
		_call = req
		var res: Dictionary = await req.wait()
		if serial != _serial:
			return
		_call = null
		if bool(res.get("cancelled", false)):
			_busy = false
			_fail("취소했어요.")
			return
		if not bool(res.get("ok", false)):
			_busy = false
			_fail(_error_text(res))
			return
		var data: Variant = res.get("data", null)
		if data is Dictionary and not (data as Dictionary).has("reading"):
			old_server_seen = true ## private 를 모르는 PC 프로그램: 더 보내지 않는다
			_busy = false
			_fail(OLD_SERVER_PRIVACY + ". " + OLD_SERVER_EXTRA)
			return
		var fx: Dictionary = DiaryLogic.clean_fix(str(sents[i]), data, lang)
		if bool(fx["bad"]):
			_busy = false
			_fail("AI가 돌려준 문장을 믿을 수 없어서 고치지 못했어요.")
			return
		items.append({"orig": fx["orig"], "fix": fx["fix"], "why": fx["why"], "reading": fx["reading"], "pron": fx["pron"],
			"same": fx["same"], "card": false})
	_busy = false
	_finish_fix(id, items)


func _error_text(res: Dictionary) -> String:
	var ec: String = str(res.get("err_code", ""))
	if ec != "" and Route.ERR_TEXT.has(ec):
		return Route.text_for(ec)
	return SpeakDrill.error_message(res, "고치지 못했어요. 잠시 뒤 다시 시도해 주세요.")


## 부분 저장 없음: 일기는 저장만 된 채로 두고(이미 저장돼 있다) 이유를 보인다. 쓴 글은 입력칸에 남는다.
func _fail(msg: String) -> void:
	stage = "home"
	_cards_msg = ""
	_msg = msg
	if not msg.contains(MSG_SAVED_LATER):
		_msg += " " + MSG_SAVED_LATER
	_msg_bad = true
	_scroll_to_list = true
	_render()


func _finish_fix(id: String, items: Array) -> void:
	if not DiaryStore.set_fixed(id, items):
		_fail("고친 결과를 저장하지 못했어요.")
		return
	_text = ""
	view_id = id
	_cards_msg = _make_cards(id)
	stage = "result"
	_render()


## 고친 문장만 복습 카드로 넣는다 (원문·AI 의 이유는 카드에 넣지 않는다: DiaryLogic.cards_for). 안내 문구를 돌려준다.
func _make_cards(id: String) -> String:
	var entry: Dictionary = DiaryStore.get_entry(id)
	var any_fixed := false
	for it in entry.get("items", []):
		if not DiaryStore.as_bool((it as Dictionary).get("same", false)) and str((it as Dictionary).get("fix", "")) != "":
			any_fixed = true
	if not any_fixed:
		return ""
	if not bool(Store.prefs.get("auto_fix_cards", true)):
		return "복습 카드 자동 추가가 꺼져 있어요. (설정에서 켤 수 있어요)"
	var cards: Array = DiaryLogic.cards_for(entry, DiaryStore.cards_today())
	if cards.is_empty():
		return "오늘 일기에서 만든 복습 카드가 %d개가 되어 더 넣지 않았어요." % DiaryLogic.CARDS_PER_DAY
	var existing := {}
	for r in Store.progress["review"]:
		existing["%s|%s" % [(r as Dictionary)["lang"], (r as Dictionary)["target"]]] = true
	var added: int = Store.add_review(cards)
	if added <= 0:
		return "이미 복습 카드에 있는 문장이에요."
	Store.save_progress()
	DiaryStore.note_cards(added)
	var items: Array = (entry["items"] as Array).duplicate(true)
	for c in cards:
		var key := "%s|%s" % [c["lang"], c["target"]]
		if existing.has(key):
			continue
		for it in items:
			if str((it as Dictionary)["fix"]).strip_edges() == str(c["target"]) and not bool((it as Dictionary)["card"]):
				(it as Dictionary)["card"] = true
				break
	DiaryStore.set_fixed(id, items)
	return "✓ 복습 카드에 넣었어요 (%d개)" % added


# ---------------------------------------------------------------- voice input

func _on_recorded(rec: Dictionary) -> void:
	if stage != "home" or _stt_busy:
		return
	_stt_busy = true
	if _mic != null and is_instance_valid(_mic):
		_mic.set_enabled(false)
	var serial: int = _serial
	var req: Object = SpeakDrill.request("/stt", {"lang": lang, "audio_b64": rec.get("b64", "")}, Api.TIMEOUT_SHORT)
	_call = req
	var res: Dictionary = await req.wait()
	if serial != _serial:
		return
	_call = null
	_stt_busy = false
	if _mic != null and is_instance_valid(_mic):
		_mic.set_enabled(true)
	if bool(res.get("cancelled", false)):
		return
	var data: Variant = res.get("data", null)
	if not bool(res.get("ok", false)) or not (data is Dictionary):
		_say(SpeakDrill.error_message(res, "말한 내용을 글자로 바꾸지 못했어요."), true)
		return
	var said: String = str((data as Dictionary).get("text", "")).strip_edges()
	if said == "":
		_say("잘 알아듣지 못했어요. 조금 더 크게, 또렷하게 다시 말해 주세요.", true)
		return
	var joined: String = said if _text.strip_edges() == "" else _text.strip_edges() + " " + said
	_text = joined.left(BOX_LIMIT)
	_msg = ""
	_render()


# ---------------------------------------------------------------- delete

func ask_remove(id: String) -> void:
	var sh := Sheet.confirm(self, "일기 지우기", "이 일기를 지울까요? 이미 만든 복습 카드는 그대로 남아요.", "지우기", true)
	sh.closed.connect(func(result: Variant) -> void:
		if str(result) == "ok":
			DiaryStore.remove(id)
			if view_id == id:
				view_id = ""
				stage = "home"
			_render())
	last_sheet = sh


func ask_clear_all() -> void:
	var c: Dictionary = DiaryStore.counts()
	var msg := "영어·일본어 일기 %d개를 모두 지울까요? 이미 만든 복습 카드는 그대로 남아요." % int(c["entries"])
	var sh := Sheet.confirm(self, "일기 모두 지우기", msg, "모두 지우기", true)
	sh.closed.connect(func(result: Variant) -> void:
		if str(result) == "ok":
			DiaryStore.clear()
			stage = "home"
			view_id = ""
			_render())
	last_sheet = sh


# ---------------------------------------------------------------- drawing

func _render() -> void:
	var c: VBoxContainer = (_shell["page"] as PageScroll).content
	UI.clear(c)
	_edit = null
	_counter = null
	_reason = null
	_fix_btn = null
	_save_btn = null
	_mic = null
	_list_anchor = null
	_ai = ai_state()
	_stt_ok = stt_ok()
	(_shell["title"] as Label).text = TITLE
	(_shell["count"] as Label).text = ""
	SpeakDrill.hide_footer(_shell)
	match stage:
		"home":
			_render_home(c)
		"working":
			_render_working(c)
		"result", "view":
			_render_entry(c)
	UI.fix_cjk(c)
	SpeakDrill.fit_touch(c)
	if stage == "home":
		_update_input_state()
		if _scroll_to_list:
			_scroll_to_list = false
			_scroll_list_into_view.call_deferred()


func _scroll_list_into_view() -> void:
	await get_tree().process_frame
	if _list_anchor != null and is_instance_valid(_list_anchor):
		var sc: ScrollContainer = _shell["page"]
		sc.scroll_vertical = int(_list_anchor.global_position.y - sc.global_position.y + sc.scroll_vertical) - 8


func _render_home(c: VBoxContainer) -> void:
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	card.name = "WriteCard"
	card.body.add_child(UI.label("오늘 있었던 일을 %s로 1~3문장 써 보세요" % _lang_name(), "H3"))
	_edit = TextEdit.new()
	_edit.name = "DiaryInput"
	_edit.placeholder_text = "예: 오늘 있었던 일을 한두 문장으로" if lang == "en" else "例: きょう あったことを いちにぶんで"
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_edit.custom_minimum_size.y = 140.0
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if lang == "ja":
		_edit.add_theme_font_override("font", UI.ja_font(false))
	_edit.text = _text
	_edit.text_changed.connect(_on_edit_changed)
	card.body.add_child(_edit)
	_counter = UI.label("", "Muted")
	_counter.name = "Counter"
	card.body.add_child(_counter)
	_reason = UI.colored("", Pal.BAD_ON, "Small")
	_reason.name = "Reason"
	_reason.visible = false
	card.body.add_child(_reason)
	if _stt_ok:
		var row := UI.flow(10, 8)
		_mic = RecorderWidget.new(false, acc, false)
		_mic.name = "MicBtn"
		_mic.idle_text = "말해서 쓰기"
		_mic.busy_text = "글자로 바꾸는 중…"
		_mic.recorded.connect(_on_recorded)
		row.add_child(_mic)
		card.body.add_child(row)
	else:
		var nm := UI.label(NOTE_NO_MIC, "Muted")
		nm.name = "NoMicNote"
		card.body.add_child(nm)
	var btns := UI.flow(10, 8)
	_fix_btn = SpeakDrill.touch_button("고쳐 보기", "primary" if can_fix() else "soft", acc, 48)
	_fix_btn.name = "FixBtn"
	_fix_btn.pressed.connect(func() -> void:
		fix_text())
	btns.add_child(_fix_btn)
	_save_btn = SpeakDrill.touch_button("저장만 하기", "soft" if can_fix() else "primary", acc, 48)
	_save_btn.name = "SaveBtn"
	_save_btn.pressed.connect(func() -> void:
		save_only())
	btns.add_child(_save_btn)
	card.body.add_child(btns)
	var note: String = ai_note(_ai)
	if note != "":
		var nl := UI.label(note, "Muted")
		nl.name = "AiNote"
		card.body.add_child(nl)
	if DiaryStore.is_read_only():
		var ro := UI.label("일기 파일을 읽지 못해서 이번에는 저장할 수 없어요.", "Muted")
		ro.name = "ReadOnlyNote"
		card.body.add_child(ro)
	c.add_child(card)
	if old_server_seen:
		var os_p := SpeakDrill.notice(OLD_SERVER_PRIVACY, true)
		os_p.name = "OldServerNote"
		c.add_child(os_p)
	if _msg != "":
		var mp := SpeakDrill.notice(_msg, _msg_bad)
		mp.name = "Message"
		c.add_child(mp)
	_build_list(c)


func _build_list(c: VBoxContainer) -> void:
	var all: Array = DiaryStore.entries(lang)
	var pend: int = DiaryStore.pending(lang).size()
	var head := UI.flow(10, 6)
	_list_anchor = head
	head.name = "ListHead"
	var hl := UI.label("최근 일기", "H3", false)
	hl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(hl)
	if pend > 0:
		var pc := UI.chip_kind(pending_text(pend), "warn")
		pc.name = "PendingChip"
		head.add_child(pc)
	c.add_child(UI.gap(4))
	c.add_child(head)
	if all.is_empty():
		var el := UI.label("아직 쓴 일기가 없어요.", "Muted")
		el.name = "EmptyList"
		c.add_child(el)
	var shown: int = mini(list_limit, all.size())
	for i in shown:
		c.add_child(_entry_row(all[i]))
	if all.size() > shown:
		var more := SpeakDrill.touch_button("더 보기", "soft", Pal.MUTED, 48)
		more.name = "MoreBtn"
		more.pressed.connect(func() -> void:
			list_limit += LIST_STEP
			_render())
		c.add_child(more)
	var total: int = int(DiaryStore.counts()["entries"])
	if total > 0:
		var clr := SpeakDrill.touch_button("일기 모두 지우기", "flat", Pal.BAD_ON, 48)
		clr.name = "ClearAllBtn"
		clr.pressed.connect(func() -> void:
			ask_clear_all())
		c.add_child(clr)


func _entry_row(e: Dictionary) -> Control:
	var id: String = str(e["id"])
	var card := UI.card("Card", 6)
	card.name = "Entry_" + id
	var top := UI.flow(10, 4)
	var dl := UI.label(DiaryLogic.date_label(str(e["date"])), "Strong", false)
	dl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(dl)
	var fixed: bool = str(e["state"]) == "fixed"
	top.add_child(UI.chip_kind(state_text(str(e["state"])), "ok" if fixed else "warn"))
	card.body.add_child(top)
	var pv := UI.label(str(e["text"]).replace("\n", " "), "Muted", false)
	pv.clip_text = true
	pv.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv.custom_minimum_size.x = 40.0
	card.body.add_child(pv)
	var row := UI.flow(8, 8)
	var vb := SpeakDrill.touch_button("보기", "soft", _acc(), 48)
	vb.name = "ViewBtn"
	vb.pressed.connect(func() -> void:
		open_entry(id))
	row.add_child(vb)
	if not fixed:
		var fb := SpeakDrill.touch_button("고치기", "primary" if can_fix() else "soft", _acc(), 48)
		fb.name = "FixEntryBtn"
		fb.disabled = not can_fix()
		fb.pressed.connect(func() -> void:
			fix_entry(id))
		row.add_child(fb)
	var db := SpeakDrill.touch_button("지우기", "flat", Pal.BAD_ON, 48)
	db.name = "DeleteBtn"
	db.pressed.connect(func() -> void:
		ask_remove(id))
	row.add_child(db)
	card.body.add_child(row)
	return card


func open_entry(id: String) -> void:
	if DiaryStore.get_entry(id).is_empty():
		return
	view_id = id
	_cards_msg = ""
	stage = "view"
	_render()


func _render_working(c: VBoxContainer) -> void:
	(_shell["count"] as Label).text = ""
	var card := UI.card("BigCard", 10)
	var pl := UI.label(progress_text(work_idx, work_total), "H3")
	pl.name = "WorkLabel"
	card.body.add_child(pl)
	card.body.add_child(UI.label("한 문장씩 고치고 있어요. 이 일기는 이미 이 기기에 저장돼 있어요.", "Muted"))
	card.body.add_child(UI.progress_indeterminate(_acc()))
	var cb := SpeakDrill.touch_button("취소", "soft", _acc(), 48)
	cb.name = "CancelBtn"
	cb.pressed.connect(func() -> void:
		cancel_fix())
	card.body.add_child(cb)
	c.add_child(card)


func _render_entry(c: VBoxContainer) -> void:
	var e: Dictionary = DiaryStore.get_entry(view_id)
	if e.is_empty():
		stage = "home"
		_render_home(c)
		return
	var fixed: bool = str(e["state"]) == "fixed"
	var top := UI.card("BigCard", 8)
	top.name = "EntryHead"
	var row := UI.flow(10, 4)
	row.add_child(UI.label(DiaryLogic.date_label(str(e["date"])), "Strong", false))
	row.add_child(UI.chip_kind(state_text(str(e["state"])), "ok" if fixed else "warn"))
	top.body.add_child(row)
	top.body.add_child(UI.label("결과" if stage == "result" else "일기", "Eyebrow", false))
	if stage == "result" and _cards_msg != "":
		var cm := UI.colored(_cards_msg, Pal.OK_ON if _cards_msg.begins_with("✓") else Pal.MUTED, "Strong")
		cm.name = "CardsMsg"
		top.body.add_child(cm)
	if not fixed:
		top.body.add_child(UI.label(str(e["text"]), "Strong"))
		top.body.add_child(UI.label("아직 고치지 않은 일기예요.", "Muted"))
	c.add_child(top)
	if fixed:
		_add_fixed_cards(c, e)
	var acts := UI.flow(10, 8)
	if not fixed:
		var fb := SpeakDrill.touch_button("고치기", "primary" if can_fix() else "soft", _acc(), 48)
		fb.name = "FixEntryBtn"
		fb.disabled = not can_fix()
		var id: String = str(e["id"])
		fb.pressed.connect(func() -> void:
			fix_entry(id))
		acts.add_child(fb)
	if stage == "result":
		var again := SpeakDrill.touch_button("다시 쓰기", "primary", _acc(), 48)
		again.name = "AgainBtn"
		again.pressed.connect(func() -> void:
			stage = "home"
			_render())
		acts.add_child(again)
	var lb := SpeakDrill.touch_button("일기 목록", "soft", _acc(), 48)
	lb.name = "ListBtn"
	lb.pressed.connect(func() -> void:
		stage = "home"
		_scroll_to_list = true
		_render())
	acts.add_child(lb)
	if stage == "view":
		var rm := SpeakDrill.touch_button("지우기", "flat", Pal.BAD_ON, 48)
		rm.name = "DeleteBtn"
		var rid: String = str(e["id"])
		rm.pressed.connect(func() -> void:
			ask_remove(rid))
		acts.add_child(rm)
	c.add_child(acts)


## 문장마다 쓴 것 / 고침 / 이유 / 읽기. 고칠 곳이 없으면 한 줄만(카드 없음). 소리 재생 버튼은 일부러 없다.
func _add_fixed_cards(c: VBoxContainer, e: Dictionary) -> void:
	var items: Array = e.get("items", [])
	var any_fix := false
	for it in items:
		if not bool((it as Dictionary).get("same", false)):
			any_fix = true
	if not any_fix:
		var nl := UI.label(MSG_NO_CHANGE, "Strong")
		nl.name = "NoChange"
		c.add_child(nl)
		return
	for i in items.size():
		var d: Dictionary = items[i]
		var card := UI.card("Card", 6)
		card.name = "ResultCard_%d" % i
		card.body.add_child(UI.label("쓴 것", "Eyebrow", false))
		card.body.add_child(UI.label(str(d["orig"]), ""))
		if bool(d.get("same", false)):
			card.body.add_child(UI.colored(MSG_NO_CHANGE, Pal.OK_ON, "Strong"))
		else:
			card.body.add_child(UI.label("고침", "Eyebrow", false))
			card.body.add_child(UI.label(str(d["fix"]), "Strong"))
			card.body.add_child(UI.label("이유", "Eyebrow", false))
			card.body.add_child(UI.label(str(d["why"]), "Muted"))
			ReadingLine.add(card.body, str(d.get("reading", "")), lang, Store.pref_bool("show_reading"), 0.0, str(d.get("pron", "")))
		c.add_child(card)
