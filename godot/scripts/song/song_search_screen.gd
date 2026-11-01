class_name SongSearchScreen
extends Control
## 제목으로 가사 찾기 (1.4.1). 계약: 설계 §2 흐름 1~6.
##
## 곡 허브 맨 위의 검색 카드에서 제목을 적고 [찾기]를 누르면 이 화면이 열려 바로 LRCLIB 에서 찾는다.
## 가사는 항상 LRCLIB 에서만 온다. AI 는 사용자가 적은 말을 "원래 제목 + 가수" 후보로 바꿔 주는 데만 쓴다
## (POST /song/identify; 가사는 보내지도 받지도 않는다 — 저작권·틀린 가사 문제).
##
## 흐름:
##   1. [찾기] -> LrclibClient.search(q) (q 2글자 이상). 같은 검색어는 LRCLIB 을 한 번만 부른다 (다시 눌러도 새로 부르지 않는다).
##      결과는 최대 10개: "제목 - 가수 / 앨범 · 길이 · 줄 시간 있음". 가사가 비었거나 연주곡인 후보는 고를 수 없다.
##   2. 후보를 누르면 가사 앞 몇 줄 미리보기 + [이 가사로 외우기] -> SongStore.install_lyrics (SongLyricsAddScreen.build_song 과 같은
##      필드: 출처 LRCLIB, lrclib_id, 출처 표시) -> song_added(id) (허브가 외우기 화면을 연다).
##   3. 결과가 없거나 [AI로 다시 찾기]: PC 연결 + /health 에 "song_identify": true 가 있을 때만 버튼이 있다. 처음 한 번 알림/동의
##      ("곡 제목이 AI로 전송돼요. 가사는 보내지 않아요.") 뒤에 POST /song/identify (검색어당 1번) -> 후보마다 LrclibClient.search("", 제목, 가수)
##      -> 결과를 합친다 (같은 lrclib id 는 한 번만).
##   4. 그래도 없으면 "찾지 못했어요" + [가사 붙여넣기] -> paste_requested(제목, 가수) (허브가 제목을 채운 SongLyricsAddScreen 을 연다).
##   5. 폰 단독(PC 없음): LRCLIB 검색은 폰에서 직접 된다. AI 버튼 대신 "PC에 연결하면 AI로 더 찾을 수 있어요." 이때 PC 로 가는 요청은 0건.
##   6. 화면 수명: 나가거나 닫을 때 날아가는 LRCLIB · AI 요청의 답은 버린다 (세대 번호). 스레드·노드는 기존 규칙대로 정리된다.
##
## 동의: 이미 song_consent(노래 공부 동의, 가사가 AI 로 가는 것까지 알린 동의)를 했으면 다시 묻지 않는다. 아니면 제목만 AI 로 간다는 동의를
##   따로(song_identify_consent) 받는다 — 여기서 song_consent 를 켜면 해석용 가사 전송까지 동의한 것이 되기 때문이다.
##
## 허브 계약:
##   signal closed                          화면을 떠난다.
##   signal song_added(song_id)             곡 저장이 끝났다 (허브가 화면을 바꾼다)
##   signal paste_requested(title, artist)  [가사 붙여넣기] (허브가 SongLyricsAddScreen 을 연다)
##   func open(lang, args)                  args: {"lang": "en"|"ja", "q": 처음 찾을 말 (있으면 곧바로 찾는다), "lrclib_base_url": 시험용}
##   func go_back() / func on_hide()
## 시험용 장치: lrclib_base_url, lrclib_factory.

signal closed
signal song_added(song_id: String)
signal paste_requested(title: String, artist: String)

const MAX_ITEMS := 10
const MAX_CANDS := 3
const PREVIEW_LINES := 4
const CONSENT_PREF := "song_consent"
const IDENTIFY_PREF := "song_identify_consent"
const IDENTIFY_PATH := "/song/identify"
const IDENTIFY_TIMEOUT := 40.0

const MSG_SHORT := "곡 제목을 두 글자 이상 적어 주세요."
const MSG_BUSY := "가사를 찾는 중이에요."
const MSG_AI_BUSY := "AI가 곡을 알아보는 중이에요."
const MSG_SAME := "이 제목은 이미 찾아봤어요. 아래 결과를 보거나, 제목을 고쳐서 다시 찾아 보세요."
const MSG_AI_USED := "이 제목은 이미 AI로 찾아봤어요. 제목을 고치면 다시 찾을 수 있어요."
const MSG_NONE := "찾지 못했어요. 제목을 고쳐서 다시 찾거나, 가사를 직접 붙여넣어 주세요."
const MSG_AI_NONE := "AI로도 찾지 못했어요. 가사를 직접 붙여넣어 주세요."
const MSG_AI_DOWN := "AI가 지금 대답하지 않아요. 가사를 붙여넣거나, 잠시 뒤에 제목을 고쳐서 다시 해 주세요."
const MSG_NEED_PC := "PC에 연결하면 AI로 더 찾을 수 있어요."
const MSG_NEED_PC_PC := "AI 엔진이 준비되면 AI로 더 찾을 수 있어요."
const MSG_OLD_PC := "PC 프로그램을 최신으로 업데이트하면 AI로 더 찾을 수 있어요."
const MSG_SEND_NOTE := "[찾기]를 누르면 곡 제목이 lrclib.net으로 전송돼요. 가사는 앱에 들어 있지 않고, 찾은 가사는 이 기기에만 저장돼요."
const MSG_AI_CONSENT_TITLE := "AI로 찾을까요?"
const MSG_AI_CONSENT := "곡 제목이 AI로 전송돼요. 가사는 보내지 않아요."
const MSG_NO_MEMO_LINES := "외울 수 있는 줄이 없어요. 다른 후보를 골라 주세요."
const MSG_SAVING := "이미 저장하고 있어요."

## 시험에서 바꾸는 값
var lrclib_base_url: String = LrclibClient.DEFAULT_BASE_URL
var lrclib_factory: Callable = Callable() ## () -> LrclibClient (add_child 는 이 화면이 한다)

var lang: String = "en"
var query: String = "" ## 입력칸의 글자
var searched_query: String = "" ## 지금 결과가 속한 검색어
var status: String = "" ## "" | busy | ai_busy | found | none | error
var message: String = ""
var items: Array = [] ## 후보 (LrclibClient 가 정규화한 record), 최대 MAX_ITEMS
var chosen: int = -1 ## 고른 후보의 번호 (-1 = 없음)
var lr_calls: int = 0 ## 이 검색어로 LrclibClient.search(q) 를 부른 횟수 (0 또는 1)
var ai_calls: int = 0 ## 이 검색어로 /song/identify 를 부른 횟수 (0 또는 1)
var ai_cands: Array = [] ## AI 가 알려준 [{title, artist}] (표시·시험용)
var save_error: String = ""
var added_id: String = ""
var consent_sheet: Sheet = null ## 열려 있는 AI 알림/동의 시트 (시험용)

var _shell: Dictionary = {}
var _client: LrclibClient = null
var _ai_call: Api.ApiCall = null
var _dead: bool = false
var _gen: int = 0 ## 요청 세대: 화면을 나가거나 다른 검색어로 바꾸면 올라간다. 늦게 온 답은 세대가 달라서 버린다.
var _key: String = "" ## 지금 결과가 속한 검색어의 열쇠
var _busy: bool = false
var _ai_done: bool = false
var _saving: bool = false
var _query_edit: LineEdit = null
var _find_btn: Button = null
var _use_btn: Button = null
var _err_label: Label = null


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back, "← 곡")
	(_shell["title"] as Label).text = "가사 찾기"


func _exit_tree() -> void:
	_dead = true
	_drop_requests()


# ---------------------------------------------------------------- open / close

func open(l: String = "", args: Dictionary = {}) -> void:
	var want: String = str(args.get("lang", l))
	lang = want if want == "ja" else "en"
	var lb: String = str(args.get("lrclib_base_url", ""))
	if lb != "":
		lrclib_base_url = lb ## 시험용: 가짜 LRCLIB
	_gen += 1
	_drop_requests()
	_reset_results()
	query = SongView.clip(str(args.get("q", "")), SongModel.LEN_TITLE)
	searched_query = ""
	_key = ""
	save_error = ""
	added_id = ""
	_saving = false
	_render()
	if query.strip_edges() != "":
		search_now(query)


## 화면이 가려진다(나간다): 날아가는 LRCLIB · AI 요청의 답을 버린다.
func on_hide() -> void:
	var was_busy: bool = _busy
	_gen += 1 ## 먼저 올린다: 요청을 버리면서 깨어나는 대기 코드가 새 세대를 보고 물러난다
	_close_consent()
	_drop_requests()
	if was_busy:
		_busy = false
		status = ""
		message = ""
		if is_inside_tree() and not _dead:
			_render()


## 안드로이드 뒤로 가기 / 머리줄 버튼. 항상 true(처리함).
func go_back() -> bool:
	_leave()
	return true


func _leave() -> void:
	_gen += 1
	_close_consent()
	_drop_requests()
	closed.emit()


func _close_consent() -> void:
	if consent_sheet != null and is_instance_valid(consent_sheet) and not consent_sheet.is_closed():
		consent_sheet.close("dismiss")
	consent_sheet = null


## 날아가는 요청은 끝나게 두고 결과만 버린다 (LrclibClient.abandon / ApiCall.cancel: 요청을 중간에 끊지 않는다).
func _drop_requests() -> void:
	if _client != null and is_instance_valid(_client):
		_client.abandon()
	_client = null
	if _ai_call != null:
		var c: Api.ApiCall = _ai_call
		_ai_call = null
		c.cancel()


func _get_client() -> LrclibClient:
	if _client != null and is_instance_valid(_client):
		return _client
	var c: LrclibClient = lrclib_factory.call() if lrclib_factory.is_valid() else LrclibClient.new()
	c.base_url = lrclib_base_url
	add_child(c)
	_client = c
	return c


# ---------------------------------------------------------------- pure helpers (static, tested)

## 같은 검색어인지 가르는 열쇠: 공백을 줄이고 소문자로.
static func query_key(q: String) -> String:
	var parts: PackedStringArray = q.strip_edges().to_lower().split(" ", false)
	return " ".join(parts)


## AI 로 찾을 수 없는 이유: "" = 된다 | "no_pc" (PC 없음 / 엔진 안 켜짐 / 폰 단독 모드) | "old_pc" (PC 프로그램이 /song/identify 를 모른다: /health 에 song_identify 가 true 가 아니다).
static func ai_block_reason() -> String:
	if Route.decide("POST", IDENTIFY_PATH) == "none" or not Backend.is_ready() or Api.base_url == "":
		return "no_pc"
	var has_it: Variant = Backend.health.get("song_identify", false)
	if typeof(has_it) != TYPE_BOOL or not bool(has_it): # 진짜 true 만 (없거나 다른 종류의 값이면 이 기능이 없는 PC 프로그램)
		return "old_pc"
	return ""


## 서버 답 -> [{title, artist}] 최대 3개. 서버가 이미 걸렀지만 그대로 믿지 않는다: 글자가 아닌 값·빈 제목·긴 글자·줄바꿈 포함·중복은 버린다.
static func parse_cands(data: Variant) -> Array:
	var out: Array = []
	if not (data is Dictionary):
		return out
	var arr: Variant = (data as Dictionary).get("cands", null)
	if not (arr is Array):
		return out
	var seen := {}
	for c in (arr as Array):
		if not (c is Dictionary):
			continue
		var t: Variant = (c as Dictionary).get("title", null)
		var a: Variant = (c as Dictionary).get("artist", "")
		if not (t is String) or not (a is String):
			continue
		var title: String = (t as String).strip_edges()
		var artist: String = (a as String).strip_edges()
		if title == "" or title.length() > 100 or artist.length() > 80:
			continue
		if title.contains("\n") or title.contains("\r") or title.contains("\t") or artist.contains("\n") or artist.contains("\r") or artist.contains("\t"):
			continue
		var k: String = query_key(title) + "|" + query_key(artist)
		if seen.has(k):
			continue
		seen[k] = true
		out.append({"title": title, "artist": artist})
		if out.size() >= MAX_CANDS:
			break
	return out


## 여러 후보 목록을 앞에서부터 합친다: 같은 lrclib id 는 한 번만 (id 가 없으면 제목+가수가 같은 것), 최대 MAX_ITEMS.
static func merge_items(lists: Array) -> Array:
	var out: Array = []
	var seen := {}
	for l in lists:
		for rec in (l as Array):
			var r: Dictionary = rec
			var id: int = int(r.get("id", 0))
			var k: String = ("id:%d" % id) if id > 0 else ("n:" + query_key(str(r.get("trackName", ""))) + "|" + query_key(str(r.get("artistName", ""))))
			if seen.has(k):
				continue
			seen[k] = true
			out.append(r)
			if out.size() >= MAX_ITEMS:
				return out
	return out


## 저장할 곡의 언어: 제목·가사에 일본어 글자(히라가나·가타카나)가 있으면 "ja", 없으면 "en".
static func guess_lang(rec: Dictionary) -> String:
	var sample: String = str(rec.get("trackName", "")) + "\n" + str(rec.get("plainLyrics", "")).substr(0, 400) + "\n" + str(rec.get("syncedLyrics", "")).substr(0, 400)
	var kana := 0
	for i in sample.length():
		var u: int = sample.unicode_at(i)
		if (u >= 0x3041 and u <= 0x30FF):
			kana += 1
			if kana >= 3:
				return "ja"
	return "en"


## 가사 미리보기: 앞 n 줄 (글자가 있는 줄만) + 전체 줄 수.
static func preview_of(rec: Dictionary, n: int = PREVIEW_LINES) -> Dictionary:
	var prep: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", rec)
	var all: Array = prep.get("lines", [])
	var first: Array = []
	for ln in all:
		var t: String = str((ln as Dictionary).get("text", "")).strip_edges()
		if t != "":
			first.append(SongView.clip(t, 80))
		if first.size() >= n:
			break
	return {"lines": first, "total": all.size()}


# ---------------------------------------------------------------- state (public: used by the screen and by tests)

func set_query(t: String) -> void:
	query = t.substr(0, SongModel.LEN_TITLE)


func is_busy() -> bool:
	return _busy


func _reset_results() -> void:
	status = ""
	message = ""
	items = []
	chosen = -1
	lr_calls = 0
	ai_calls = 0
	ai_cands = []
	_ai_done = false
	_busy = false


## 새 검색어로 바꾼다: 이전 검색어의 후보 · 고른 가사 · 횟수를 모두 비우고, 늦게 오는 이전 답을 버린다.
func _new_query(q: String, k: String) -> void:
	_gen += 1
	_drop_requests()
	_reset_results()
	searched_query = q
	_key = k
	save_error = ""


func ai_possible() -> bool:
	return ai_block_reason() == ""


## AI 로 찾을 수 있는 때: 결과가 나온 뒤(찾는 중이 아닐 때)이고 이 검색어로 아직 AI 를 안 썼고 PC 가 된다.
func ai_available_now() -> bool:
	return not _busy and _key != "" and not _ai_done and ai_calls == 0 and ai_possible() and (status == "found" or status == "none")


func ai_consented() -> bool:
	return Store.pref_bool(CONSENT_PREF) or Store.pref_bool(IDENTIFY_PREF)


# ---------------------------------------------------------------- 1. LRCLIB search (only on the user's tap)

## [찾기]. q 는 2글자 이상. 같은 검색어를 다시 누르면 LRCLIB 을 새로 부르지 않는다.
func search_now(q: String) -> void:
	var t: String = q.strip_edges()
	if _busy:
		Toast.info(MSG_BUSY)
		return
	if t.length() < LrclibClient.MIN_QUERY_CHARS:
		status = "error"
		message = MSG_SHORT
		Toast.info(MSG_SHORT)
		_render()
		return
	var k: String = query_key(t)
	if k == _key and lr_calls >= 1:
		Toast.info(MSG_SAME) ## 같은 검색어: 새로 부르지 않는다
		return
	_new_query(t, k)
	lr_calls += 1
	_busy = true
	status = "busy"
	message = MSG_BUSY
	_render()
	var gen: int = _gen
	var client: LrclibClient = _get_client()
	var res: Dictionary = await client.search(t)
	if _dead or gen != _gen:
		return ## 화면을 나갔거나 다른 검색어로 바꿨다: 늦은 답은 버린다
	_busy = false
	if bool(res.get("ok", false)):
		items = merge_items([res.get("items", [])])
		if items.is_empty():
			status = "none"
			message = MSG_NONE
		else:
			status = "found"
			message = "후보 %d개를 찾았어요. 하나를 골라 주세요." % items.size()
	else:
		status = "error"
		message = _lr_error_text(res)
	_render()


func _lr_error_text(res: Dictionary) -> String:
	var t: String = SongView.clip(str(res.get("message", "")), 200)
	if t == "":
		t = "가사를 찾지 못했어요."
	var ra: float = float(res.get("retry_after", 0.0))
	if str(res.get("err_code", "")) == "rate_limited" and ra > 0.0:
		t += " (약 %d초 뒤)" % int(ceilf(ra))
	return t + " 제목을 고치면 다시 찾을 수 있어요."


# ---------------------------------------------------------------- 3. AI: title -> candidates -> LRCLIB

## [AI로 다시 찾기]. 동의 전에는 PC 로 아무것도 보내지 않는다.
func start_ai() -> void:
	if _busy:
		Toast.info(MSG_BUSY)
		return
	if _key == "":
		return
	if ai_calls >= 1 or _ai_done:
		Toast.info(MSG_AI_USED)
		return
	match ai_block_reason():
		"no_pc":
			Toast.info(MSG_NEED_PC if Platform.is_phone() else MSG_NEED_PC_PC)
			return
		"old_pc":
			Toast.info(MSG_OLD_PC)
			return
	if not ai_consented():
		_ask_consent()
		return
	_run_ai()


func _ask_consent() -> void:
	if consent_sheet != null and is_instance_valid(consent_sheet) and not consent_sheet.is_closed():
		return
	var gen: int = _gen
	var sh: Sheet = Sheet.confirm(self, MSG_AI_CONSENT_TITLE, MSG_AI_CONSENT, "동의하고 찾기", false, "취소")
	consent_sheet = sh
	sh.closed.connect(func(r: Variant) -> void:
		if consent_sheet == sh:
			consent_sheet = null
		if str(r) != "ok" or _dead or gen != _gen:
			return ## 취소 · 닫음 · 그 사이에 화면을 나갔거나 다른 제목으로 바꿨다: 아무것도 보내지 않고 아무것도 저장하지 않는다
		Store.set_pref(IDENTIFY_PREF, true)
		_run_ai())


func _run_ai() -> void:
	if _busy or ai_calls >= 1 or _key == "":
		return
	ai_calls += 1
	_busy = true
	status = "ai_busy"
	message = MSG_AI_BUSY
	_render()
	var gen: int = _gen
	var q: String = searched_query
	var acall: Api.ApiCall = Api.post_json(IDENTIFY_PATH, {"q": q, "lang": lang}, IDENTIFY_TIMEOUT, false)
	_ai_call = acall
	var res: Dictionary = await acall.wait()
	if _dead or gen != _gen or bool(res.get("cancelled", false)):
		return ## 늦게 온 AI 답은 버린다
	_ai_call = null
	if not bool(res.get("ok", false)):
		_busy = false
		_ai_done = true
		status = "error"
		message = MSG_AI_DOWN
		_render()
		return
	var cands: Array = parse_cands(res.get("data", null))
	ai_cands = cands
	var found_lists: Array = []
	var any_ok: bool = false
	var last_err: Dictionary = {}
	for c in cands:
		var client: LrclibClient = _get_client()
		var r: Dictionary = await client.search("", str((c as Dictionary)["title"]), str((c as Dictionary)["artist"]))
		if _dead or gen != _gen:
			return
		if bool(r.get("ok", false)):
			any_ok = true
			found_lists.append(r.get("items", []))
		else:
			last_err = r
	var prior: Array = items.duplicate()
	found_lists.append(prior)
	_busy = false
	_ai_done = true
	items = merge_items(found_lists)
	chosen = -1
	if not items.is_empty():
		status = "found"
		message = "AI가 찾은 곡을 합쳐서 후보 %d개예요. 하나를 골라 주세요." % items.size()
	elif not cands.is_empty() and not any_ok and not last_err.is_empty():
		status = "error"
		message = _lr_error_text(last_err)
	else:
		status = "none"
		message = MSG_AI_NONE
	_render()


# ---------------------------------------------------------------- 2. choose and save

## 후보를 고른다. 쓸 수 없는 후보(연주곡 · 가사 없음)는 false.
func choose(i: int) -> bool:
	if _busy or i < 0 or i >= items.size():
		return false
	if not SongAddScreen.usable_record(items[i]):
		return false
	chosen = i
	save_error = ""
	_render()
	return true


func chosen_record() -> Dictionary:
	if chosen < 0 or chosen >= items.size():
		return {}
	return items[chosen]


## [이 가사로 외우기]. 저장하지 못하면 이유(한국어)를 돌려주고 화면에 보인다. 저장했으면 "".
func save() -> String:
	if _saving:
		return MSG_SAVING
	save_error = ""
	var rec: Dictionary = chosen_record()
	if rec.is_empty() or not SongAddScreen.usable_record(rec):
		return _fail_save("가사를 하나 골라 주세요.")
	var prep: Dictionary = SongAddScreen.prepare_lyrics("lrclib", "", rec)
	var lang_code: String = guess_lang(rec)
	if int(SongLyricsAddScreen.analyze(prep, lang_code)["memo_lines"]) <= 0:
		return _fail_save(MSG_NO_MEMO_LINES)
	var title: String = SongView.clip(str(rec.get("trackName", "")), SongModel.LEN_TITLE)
	if title == "":
		title = SongView.clip(searched_query, SongModel.LEN_TITLE)
	var artist: String = SongView.clip(str(rec.get("artistName", "")), SongModel.LEN_TITLE)
	var song: Dictionary = SongLyricsAddScreen.build_song(lang_code, title, artist, "lrclib", rec, prep)
	_saving = true
	var res: Dictionary = SongStore.install_lyrics(song)
	if not bool(res.get("ok", false)):
		_saving = false
		var code: String = str(res.get("err_code", "disk_write"))
		return _fail_save(str(SongLyricsAddScreen.MSG_SAVE_ERR.get(code, SongLyricsAddScreen.MSG_SAVE_ERR["disk_write"])))
	added_id = str(res.get("id", ""))
	song_added.emit(added_id)
	return ""


func _fail_save(msg: String) -> String:
	save_error = msg
	if _err_label != null and is_instance_valid(_err_label):
		_err_label.text = msg
		_err_label.visible = msg != ""
	Toast.info(msg)
	return msg


## [가사 붙여넣기]: 검색어를 제목으로 채운 붙여넣기 화면을 허브에 부탁한다.
func request_paste() -> void:
	paste_requested.emit(SongView.clip(searched_query if searched_query != "" else query, SongModel.LEN_TITLE), "")


# ---------------------------------------------------------------- build

func _render() -> void:
	if _dead:
		return
	var page: PageScroll = _shell["page"]
	UI.clear(page.content)
	_query_edit = null
	_find_btn = null
	_use_btn = null
	_err_label = null
	var c: VBoxContainer = page.content
	# 검색칸
	var card: CardBox = UI.card("Card", 10)
	_query_edit = LineEdit.new()
	_query_edit.name = "QueryInput"
	_query_edit.text = query
	_query_edit.max_length = SongModel.LEN_TITLE
	_query_edit.placeholder_text = "곡 제목 (가수도 적으면 더 정확해요)"
	_query_edit.custom_minimum_size.y = Ds.field_h()
	_query_edit.text_changed.connect(set_query)
	_query_edit.text_submitted.connect(func(t: String) -> void:
		set_query(t)
		search_now(t))
	card.body.add_child(_query_edit)
	_find_btn = SpeakDrill.touch_button("찾기", "primary", Pal.PRIMARY)
	_find_btn.name = "BtnSearch"
	_find_btn.disabled = _busy
	_find_btn.pressed.connect(func() -> void: search_now(query))
	card.body.add_child(_find_btn)
	var note: Label = UI.label(MSG_SEND_NOTE, "Small")
	note.name = "SendNote"
	card.body.add_child(note)
	c.add_child(card)
	# 상태 글
	if message != "":
		var m := SpeakDrill.notice(message, status == "error")
		m.name = "StatusMessage"
		c.add_child(m)
	# 후보
	if not items.is_empty():
		var g: ListGroup = UI.card("Group") as ListGroup
		g.name = "Candidates"
		for i in items.size():
			var rec: Dictionary = items[i]
			var tx: Dictionary = SongAddScreen.candidate_text(rec, 0.0)
			var usable: bool = SongAddScreen.usable_record(rec)
			var trailing: Control = UI.chip_kind("선택됨", "ok") if i == chosen else null
			var tap: Callable = Callable()
			if usable:
				var idx: int = i
				tap = func() -> void: choose(idx)
			var row: Control = g.add_row(str(tx["main"]), str(tx["sub"]), trailing, tap)
			if row != null:
				row.name = "Cand%d" % i
				if not usable:
					row.modulate = Color(1, 1, 1, 0.55) # 고를 수 없는 후보는 흐리게 (글자에도 "가사 없음"이 있다)
		c.add_child(g)
	# 고른 가사 미리보기
	if chosen >= 0 and chosen < items.size():
		var rec2: Dictionary = items[chosen]
		var pv: Dictionary = preview_of(rec2)
		var pc: CardBox = UI.card("Card", 8)
		pc.name = "ChosenCard"
		pc.body.add_child(UI.label("가사 미리보기", "Eyebrow", false))
		var lines_label: Label = UI.label("\n".join(PackedStringArray(pv["lines"])) + ("\n…" if int(pv["total"]) > (pv["lines"] as Array).size() else ""), "")
		lines_label.name = "PreviewLines"
		pc.body.add_child(lines_label)
		var cnt: Label = UI.label("모두 %d줄" % int(pv["total"]), "Small")
		cnt.name = "PreviewCount"
		pc.body.add_child(cnt)
		var at: Label = UI.label(SongAddScreen.ATTRIBUTION, "Small")
		at.name = "Attribution"
		pc.body.add_child(at)
		c.add_child(pc)
	# AI · 붙여넣기
	if status == "found" or status == "none" or status == "error":
		var row2 := UI.flow(10, 8)
		if ai_available_now():
			var ai := SpeakDrill.touch_button("AI로 다시 찾기", "outline", Pal.PRIMARY)
			ai.name = "BtnAi"
			ai.pressed.connect(func() -> void: start_ai())
			row2.add_child(ai)
		var paste := SpeakDrill.touch_button("가사 붙여넣기", "outline", Pal.INK)
		paste.name = "BtnPaste"
		paste.pressed.connect(func() -> void: request_paste())
		row2.add_child(paste)
		c.add_child(row2)
		if not _ai_done and ai_calls == 0 and status != "error":
			var why: String = ai_block_reason()
			var hint_text: String = ""
			if why == "no_pc":
				hint_text = MSG_NEED_PC if Platform.is_phone() else MSG_NEED_PC_PC
			elif why == "old_pc":
				hint_text = MSG_OLD_PC
			if hint_text != "":
				var hint: Label = UI.label(hint_text, "Small")
				hint.name = "AiHint"
				c.add_child(hint)
	UI.fix_cjk(c)
	_render_footer()


func _render_footer() -> void:
	var fcol: ColumnBox = _shell["footer_col"]
	UI.clear(fcol.content)
	var holder: PanelContainer = _shell["footer_holder"]
	_err_label = null
	_use_btn = null
	if chosen >= 0 and chosen < items.size():
		_err_label = UI.colored(save_error, Pal.BAD_ON)
		_err_label.name = "SaveError"
		_err_label.visible = save_error != ""
		fcol.content.add_child(_err_label)
		_use_btn = SpeakDrill.touch_button("이 가사로 외우기", "primary", Pal.PRIMARY)
		_use_btn.name = "BtnUse"
		_use_btn.pressed.connect(func() -> void: save())
		fcol.content.add_child(_use_btn)
		holder.visible = true
	else:
		holder.visible = false
