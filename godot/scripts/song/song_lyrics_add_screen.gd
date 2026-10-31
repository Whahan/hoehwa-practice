class_name SongLyricsAddScreen
extends Control
## 가사 외우기 M6: "가사만 추가" 화면 (docs/lyrics_memorize_design.md §4.2, §5.1, §5.2, §5.4, §8 M6, §12.1b).
##
## 흐름: 언어·제목·가수 -> 가사 출처 2가지(붙여넣기 / LRCLIB 검색) -> 미리보기(외울 줄 · 묶인 후렴 · 뺀 줄 · 잘린 안내)
##   -> [저장하고 외우기] -> SongStore.install_lyrics(kind "lyrics" 곡) -> song_added(song_id).
## 음악 파일도 PC 도 필요 없다: 이 화면은 서버(PC)에 아무것도 보내지 않는다 (붙여넣기 저장은 요청 0건).
## 해석·단어 뜻 만들기는 여기서 하지 않는다 (외우기 화면에서 사용자가 눌렀을 때만).
## 앱이 가사를 스스로 가져오거나 만들지 않는다: 가사는 사용자가 붙여넣은 것, 또는 사용자가 버튼을 눌러 LRCLIB 에서 받은 것뿐이다.
##
## LRCLIB 이용 규칙(§2 C1, 노래 공부 U2 와 같다): 사용자가 [가사 찾기] 를 누를 때만 부른다. 곡 하나(제목+가수가 같은 동안)당
##   GET /api/get 1번 + 검색 1번까지만(같은 단추를 다시 눌러도 새로 부르지 않는다). 입력 중 자동 호출 없음. 제목이나 가수를 다른 곡으로
##   고치면 새 곡이다. 제목·가수가 둘 다 2글자 이상이어야 부른다. 곡 길이(m:ss, 선택)는 적었을 때만 get 에 보낸다.
##   요청마다 세대 번호를 붙여서, 화면을 나가거나 다른 곡으로 바꾼 뒤 늦게 오는 답은 버린다. 결과 글자는 길이 제한이 없어서 말줄임으로 자른다.
##
## 가사 자르기(서버 한도 §5.1과 같음): 400줄 · 한 줄 200자 · 합계 20000자, [Chorus] 같은 [ ... ] 만 있는 줄 제외 -> SongAddScreen.prepare_lyrics 재사용.
## 시간표(LRC)가 있어도 시간은 버리고 글자만 저장한다 (음원이 없다).
##
## 허브 계약:
##   signal closed                  화면을 떠난다.
##   signal song_added(song_id)     곡 저장이 끝났다. (closed 는 따로 나가지 않는다 — 허브가 화면을 바꾼다)
##   func open(lang, args)          args: {"lang": "en"|"ja"}
##   func go_back()                 안드로이드 뒤로 가기 / 머리줄 버튼. 항상 true.
##   func on_hide()                 날아가는 LRCLIB 요청의 결과를 버린다.
## 시험용 장치: lrclib_base_url, lrclib_factory.

signal closed
signal song_added(song_id: String)

const SOURCES := [["pasted", "붙여넣기"], ["lrclib", "LRCLIB 검색"]]
const SHOW_ITEMS := 20
const MAX_PASTE_CHARS := 100000 ## 붙여넣은 글자 상한 (서버 한도 20000자의 몇 배: 시간표 글자가 섞여도 잘리지 않게)
const MAX_DURATION_SEC := 7200.0

const MSG_NEED_TITLE := "곡 제목을 적어 주세요."
const MSG_NEED_PASTE := "가사를 붙여넣어 주세요."
const MSG_NEED_LRCLIB := "[가사 찾기]를 눌러 가사를 찾은 뒤 하나 골라 주세요. 찾지 못하면 '붙여넣기'를 써 보세요."
const MSG_NO_MEMO_LINES := "외울 수 있는 줄이 없어요. 글자가 있는 줄이 필요해요."
const MSG_SAVING := "이미 저장하고 있어요."
const MSG_TITLE_SHORT := "LRCLIB로 찾으려면 곡 제목과 가수를 두 글자 이상 적어 주세요."
const MSG_LR_USED := "이 곡은 이미 그 방법으로 찾아봤어요. 아래 결과를 쓰거나, 가사를 붙여넣어 주세요. 제목이나 가수를 다른 곡으로 고치면 다시 찾을 수 있어요."
const MSG_LR_BUSY := "가사를 찾는 중이에요."
const MSG_PASTE_HINT := "가사를 붙여넣어도 돼요."
const MSG_DURATION_BAD := "곡 길이는 3:42 처럼 분:초로 적어 주세요. 길이 없이 찾을게요."
const MSG_SAVE_ERR := {
	"bad_song": "외울 수 있는 가사가 없어서 저장하지 못했어요.",
	"quota_songs": "곡이 너무 많아서 더 저장할 수 없어요. 안 쓰는 곡을 지운 뒤 다시 눌러 주세요.",
	"quota_bytes": "저장 공간 한도에 닿아서 저장하지 못했어요. 안 쓰는 곡을 지운 뒤 다시 눌러 주세요.",
	"disk_write": "이 기기에 저장하지 못했어요. 저장 공간을 확인하고 다시 눌러 주세요. 입력한 가사는 그대로 있어요.",
}

## 시험에서 바꾸는 값
var lrclib_base_url: String = LrclibClient.DEFAULT_BASE_URL
var lrclib_factory: Callable = Callable() ## () -> LrclibClient (add_child 는 이 화면이 한다)

var lang: String = "en"
var phase: String = "form" ## form | done
var title_text: String = ""
var artist_text: String = ""
var duration_text: String = ""
var source: String = "pasted" ## pasted | lrclib
var pasted_text: String = ""
var paste_cut: bool = false ## 붙여넣은 글자가 MAX_PASTE_CHARS 를 넘어서 잘렸다
var save_error: String = ""
var added_id: String = ""

## LRCLIB 상태 (곡 하나당)
var lr_get_calls: int = 0 ## GET /api/get 을 부른 횟수 (0 또는 1)
var lr_search_calls: int = 0 ## GET /api/search 를 부른 횟수 (0 또는 1)
var lr_status: String = "" ## "" | busy | found | none | instrumental | error
var lr_message: String = ""
var lr_items: Array = [] ## 후보 (정규화된 record, 말줄임은 표시할 때)
var lr_record: Dictionary = {} ## 고른 후보
var lr_busy: bool = false

var _shell: Dictionary = {}
var _client: LrclibClient = null
var _dead: bool = false
var _lr_gen: int = 0 ## 요청 세대: 화면을 나가거나 다른 곡으로 바꾸면 올라간다. 늦게 온 답은 세대가 달라서 버린다.
var _lr_key: String = "" ## 지금 찾고 있는 곡의 열쇠(제목+가수)
var _confirm_sheet: Sheet = null
var _title_edit: LineEdit = null
var _artist_edit: LineEdit = null
var _duration_edit: LineEdit = null
var _paste_edit: TextEdit = null
var _preview_label: Label = null
var _duration_note: Label = null
var _hint_label: Label = null
var _err_label: Label = null
var _save_btn: Button = null
var _find_btn: Button = null
var _search_btn: Button = null


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back, "← 곡")
	(_shell["title"] as Label).text = "가사만 추가"


func _exit_tree() -> void:
	_dead = true
	_drop_client()


# ---------------------------------------------------------------- open / close

func open(l: String = "", args: Dictionary = {}) -> void:
	var want: String = str(args.get("lang", l))
	lang = want if want == "ja" else "en"
	phase = "form"
	title_text = ""
	artist_text = ""
	duration_text = ""
	source = "pasted"
	pasted_text = ""
	paste_cut = false
	save_error = ""
	added_id = ""
	_drop_client()
	_reset_lrclib()
	_lr_key = _query_key()
	_render()


## 화면이 가려진다(나간다): 날아가는 LRCLIB 요청의 결과를 버린다. 요청 자체는 끊지 않는다.
func on_hide() -> void:
	var was_busy: bool = lr_busy
	_drop_client()
	_lr_gen += 1
	if was_busy:
		lr_busy = false
		lr_status = ""
		lr_message = ""
		if is_inside_tree() and not _dead:
			_render()


## 안드로이드 뒤로 가기 / 머리줄 버튼. 붙여넣은 가사가 있으면 확인을 묻는다. 항상 true(처리함).
func go_back() -> bool:
	if phase == "form" and pasted_text.strip_edges() != "":
		_confirm("나갈까요?", "붙여넣은 가사는 저장하지 않으면 사라져요.", "나가기", "계속 입력하기", _leave)
		return true
	_leave()
	return true


func _leave() -> void:
	_drop_client()
	_lr_gen += 1
	closed.emit()


func _confirm(title: String, msg: String, ok_text: String, cancel_text: String, on_ok: Callable) -> void:
	if _confirm_sheet != null and is_instance_valid(_confirm_sheet) and Sheet.is_open():
		return
	var sh: Sheet = Sheet.confirm(self, title, msg, ok_text, false, cancel_text)
	_confirm_sheet = sh
	sh.closed.connect(func(r: Variant) -> void:
		if _confirm_sheet == sh:
			_confirm_sheet = null
		if str(r) == "ok":
			on_ok.call())


# ---------------------------------------------------------------- pure helpers (static, tested)

## "3:42" -> {ok: true, empty: false, seconds: 222.0}. 비어 있으면 {empty: true, ok: false}. 분:초가 아니거나
## (abc, 99:99, -1:30, 0:00, 121:00 ...) 틀리면 {ok: false, empty: false}. 2시간(120:00)까지.
static func parse_duration(text: String) -> Dictionary:
	var t: String = text.strip_edges()
	if t == "":
		return {"ok": false, "empty": true, "seconds": 0.0}
	var rx := RegEx.new()
	rx.compile("^([0-9]{1,3}):([0-5][0-9])$")
	var m: RegExMatch = rx.search(t)
	if m == null:
		return {"ok": false, "empty": false, "seconds": 0.0}
	var sec: float = float(int(m.get_string(1)) * 60 + int(m.get_string(2)))
	if sec <= 0.0 or sec > MAX_DURATION_SEC:
		return {"ok": false, "empty": false, "seconds": 0.0}
	return {"ok": true, "empty": false, "seconds": sec}


## 같은 곡인지 가르는 열쇠: 공백을 줄이고 소문자로 한 제목+가수.
static func query_key(title: String, artist: String) -> String:
	return _norm_name(title) + "|" + _norm_name(artist)


static func _norm_name(s: String) -> String:
	var parts: PackedStringArray = s.strip_edges().to_lower().split(" ", false)
	return " ".join(parts)


## 곡으로 저장할 가사의 분석. prep = SongAddScreen.prepare_lyrics 결과.
## {memo_lines: 외울 수 있는 줄 수, unique: 서로 다른 줄 수(M), repeats: 후렴으로 묶이는 줄 수, symbols: 글자 없는 줄 수}
static func analyze(prep: Dictionary, lang_code: String) -> Dictionary:
	var lines: Array = prep.get("lines", [])
	var memo_lines := 0
	for ln in lines:
		if MemoModel.is_memo_line(ln, lang_code):
			memo_lines += 1
	var keys: Array = MemoModel.keys_of({"lang": lang_code, "lines": lines})
	var unique: int = keys.size()
	return {"memo_lines": memo_lines, "unique": unique, "repeats": maxi(0, memo_lines - unique), "symbols": maxi(0, lines.size() - memo_lines)}


## 저장할 곡 사전 (kind "lyrics"). 시간은 없다 (SongModel.normalize 가 t0 = t1 = 0 으로 보정한다).
static func build_song(lang_code: String, title: String, artist: String, src: String, record: Dictionary, prep: Dictionary) -> Dictionary:
	var lines: Array = []
	var idx := 0
	for ln in (prep.get("lines", []) as Array):
		var d: Dictionary = ln
		lines.append({"i": idx, "p": int(d.get("p", 0)), "text": str(d.get("text", "")), "reading": "", "pron": "", "ko": ""})
		idx += 1
	var from_lrclib: bool = src == "lrclib" and not record.is_empty()
	var lid: Variant = null
	if from_lrclib and int(record.get("id", 0)) > 0:
		lid = int(record.get("id", 0))
	return {
		"v": SongModel.CURRENT_V, "kind": "lyrics", "id": "", "lang": lang_code,
		"title": title, "artist": artist, "created": int(Time.get_unix_time_from_system()), "duration": 0.0,
		"audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
		"source": {"lyrics": "lrclib" if from_lrclib else "pasted", "lrclib_id": lid, "timing": "none",
			"attribution": SongAddScreen.ATTRIBUTION if from_lrclib else ""},
		"offset": 0.0, "lines": lines, "glossary": {}, "marks": {"lines": [], "words": []},
		"stats": {"plays": 0, "last": 0, "best": {}}, "warnings": [],
		"app": str(ProjectSettings.get_setting("application/config/version", "")),
	}


# ---------------------------------------------------------------- state (public: used by the form and by tests)

func set_lang(l: String) -> void:
	lang = l if l == "ja" else "en"
	_render()


func set_title(t: String) -> void:
	title_text = t.substr(0, SongModel.LEN_TITLE)
	_query_changed()
	_refresh_footer_state()


func set_artist(t: String) -> void:
	artist_text = t.substr(0, SongModel.LEN_TITLE)
	_query_changed()


func set_duration_text(t: String) -> void:
	duration_text = t.substr(0, 12)
	_update_duration_note()


func set_source(s: String) -> void:
	if not ["pasted", "lrclib"].has(s):
		return
	source = s
	save_error = ""
	_render()


func set_pasted(t: String) -> void:
	paste_cut = t.length() > MAX_PASTE_CHARS
	pasted_text = t.substr(0, MAX_PASTE_CHARS) if paste_cut else t
	save_error = ""
	_update_preview()
	_refresh_footer_state()


func current_lyrics() -> Dictionary:
	match source:
		"pasted":
			return SongAddScreen.prepare_lyrics("pasted", pasted_text)
		"lrclib":
			if lr_record.is_empty():
				return SongAddScreen._empty_prep()
			return SongAddScreen.prepare_lyrics("lrclib", "", lr_record)
	return SongAddScreen._empty_prep()


func effective_title() -> String:
	return SongView.clip(title_text, SongModel.LEN_TITLE)


func effective_artist() -> String:
	return SongView.clip(artist_text, SongModel.LEN_TITLE)


## 저장하지 못하는 이유(한국어). "" = 저장할 수 있다.
func save_block_reason() -> String:
	if phase != "form":
		return MSG_SAVING
	if effective_title() == "":
		return MSG_NEED_TITLE
	var prep: Dictionary = current_lyrics()
	if (prep["lines"] as Array).is_empty():
		return MSG_NEED_PASTE if source == "pasted" else MSG_NEED_LRCLIB
	if int(analyze(prep, lang)["memo_lines"]) <= 0:
		return MSG_NO_MEMO_LINES
	return ""


## 가사 칸 아래 요약: "6줄 · 외울 줄 6개" + 묶인 후렴 · 뺀 줄 · 자른 안내.
func preview_text() -> String:
	var prep: Dictionary = current_lyrics()
	var n: int = (prep["lines"] as Array).size()
	var t: String = ""
	if n == 0:
		if source == "pasted" and pasted_text.strip_edges() != "":
			t = "아직 쓸 수 있는 가사가 없어요."
	else:
		var an: Dictionary = analyze(prep, lang)
		t = "%d줄 · 외울 줄 %d개" % [n, int(an["unique"])]
		if int(an["repeats"]) > 0:
			t += "\n같은 줄 %d개는 후렴으로 묶어서 한 번만 외워요." % int(an["repeats"])
		if int(an["symbols"]) > 0:
			t += "\n글자가 없는 줄(♪ 같은 기호) %d줄은 외우지 않아요." % int(an["symbols"])
		if bool(prep["timed"]):
			t += "\n줄 시간표는 쓰지 않고 글자만 저장해요."
	for note in (prep["notes"] as Array):
		t += ("\n" if t != "" else "") + str(note)
	if paste_cut and source == "pasted":
		t += ("\n" if t != "" else "") + "붙여넣은 글자가 너무 길어서 앞의 %d자만 읽었어요." % MAX_PASTE_CHARS
	return t


## 지금 LRCLIB 에 보낼 곡 길이(초). 비었거나 잘못이면 0.0 (보내지 않는다).
func query_duration() -> float:
	var d: Dictionary = parse_duration(duration_text)
	return float(d["seconds"]) if bool(d["ok"]) else 0.0


func duration_note_text() -> String:
	var d: Dictionary = parse_duration(duration_text)
	if bool(d["empty"]) or bool(d["ok"]):
		return ""
	return MSG_DURATION_BAD


# ---------------------------------------------------------------- LRCLIB (only on the user's tap)

func _query_key() -> String:
	return query_key(title_text, artist_text)


## 제목이나 가수가 다른 곡으로 바뀌었다: 이 곡의 찾기 횟수를 새로 센다. 이미 받은 후보는 새 결과가 올 때까지 그대로 둔다.
func _query_changed() -> void:
	var k: String = _query_key()
	if k == _lr_key:
		return
	_lr_key = k
	lr_get_calls = 0
	lr_search_calls = 0
	_lr_gen += 1 ## 이전 곡의 늦은 답은 버린다
	if lr_busy:
		lr_busy = false
		lr_status = ""
		lr_message = ""
		if is_inside_tree() and not _dead:
			_render_keep_focus()


## 입력칸에서 글자를 치는 도중에 화면을 다시 만들어야 할 때: 치던 칸에 커서를 되돌려 준다.
func _render_keep_focus() -> void:
	var which: int = 0
	if _title_edit != null and is_instance_valid(_title_edit) and _title_edit.has_focus():
		which = 1
	elif _artist_edit != null and is_instance_valid(_artist_edit) and _artist_edit.has_focus():
		which = 2
	_render()
	var e: LineEdit = _title_edit if which == 1 else (_artist_edit if which == 2 else null)
	if e != null and is_instance_valid(e):
		e.grab_focus()
		e.caret_column = e.text.length()


func _reset_lrclib() -> void:
	_lr_gen += 1
	lr_get_calls = 0
	lr_search_calls = 0
	lr_status = ""
	lr_message = ""
	lr_items = []
	lr_record = {}
	lr_busy = false


func _get_client() -> LrclibClient:
	if _client != null and is_instance_valid(_client):
		return _client
	var c: LrclibClient = lrclib_factory.call() if lrclib_factory.is_valid() else LrclibClient.new()
	c.base_url = lrclib_base_url
	add_child(c)
	_client = c
	return c


func _drop_client() -> void:
	if _client != null and is_instance_valid(_client):
		_client.abandon() ## 날아가는 요청은 끝나게 두고 결과만 버린다 (요청을 중간에 끊지 않는다)
	_client = null


func _query_ok() -> bool:
	return title_text.strip_edges().length() >= LrclibClient.MIN_QUERY_CHARS and artist_text.strip_edges().length() >= LrclibClient.MIN_QUERY_CHARS


func _short_query() -> void:
	lr_status = "error"
	lr_message = MSG_TITLE_SHORT
	_render()


## [가사 찾기]: GET /api/get 1번. 이미 썼으면 부르지 않는다.
func find_lyrics() -> void:
	if lr_busy:
		return
	if not _query_ok():
		_short_query()
		return
	if lr_get_calls >= 1:
		Toast.info(MSG_LR_USED) ## 곡 하나당 한 번: 새로 부르지 않는다
		return
	var dnote: String = duration_note_text()
	if dnote != "":
		Toast.info(dnote)
	lr_get_calls += 1
	lr_busy = true
	lr_status = "busy"
	lr_message = MSG_LR_BUSY
	_render()
	var gen: int = _lr_gen
	var client: LrclibClient = _get_client()
	var res: Dictionary = await client.find(title_text.strip_edges(), artist_text.strip_edges(), "", query_duration())
	if _dead or gen != _lr_gen:
		return ## 화면을 나갔거나 다른 곡으로 바꿨다: 늦은 답은 버린다
	lr_busy = false
	match str(res.get("kind", "error")):
		"exact":
			var rec: Dictionary = res["record"]
			lr_items = [rec]
			if SongAddScreen.usable_record(rec):
				lr_status = "found"
				lr_message = "찾았어요. 맞는 곡이면 이대로 쓰고, 아니면 '비슷한 곡 찾기'를 눌러 보세요."
				lr_record = rec
				_adopt_record_names(rec)
			else:
				lr_status = "none"
				lr_message = "찾았지만 이 곡에는 쓸 수 있는 가사가 없어요. " + MSG_PASTE_HINT
		"none":
			lr_status = "none"
			lr_message = "LRCLIB에서 이 곡의 가사를 찾지 못했어요. '비슷한 곡 찾기'를 눌러 보거나 가사를 붙여넣어 주세요."
		"instrumental":
			lr_status = "instrumental"
			lr_items = [res["record"]]
			lr_message = "연주곡이라 가사가 없어요. " + MSG_PASTE_HINT
		_:
			lr_status = "error"
			lr_message = _lr_error_text(res)
	_render()


## [비슷한 곡 찾기]: GET /api/search 1번.
func search_lyrics() -> void:
	if lr_busy:
		return
	if not _query_ok():
		_short_query()
		return
	if lr_search_calls >= 1:
		Toast.info(MSG_LR_USED)
		return
	var dnote: String = duration_note_text()
	if dnote != "":
		Toast.info(dnote)
	lr_search_calls += 1
	lr_busy = true
	lr_status = "busy"
	lr_message = MSG_LR_BUSY
	_render()
	var gen: int = _lr_gen
	var tr: String = title_text.strip_edges()
	var ar: String = artist_text.strip_edges()
	var client: LrclibClient = _get_client()
	var res: Dictionary = await client.search((tr + " " + ar).strip_edges(), tr, ar, query_duration())
	if _dead or gen != _lr_gen:
		return
	lr_busy = false
	if bool(res.get("ok", false)):
		var items: Array = res.get("items", [])
		if items.size() > SHOW_ITEMS:
			items.resize(SHOW_ITEMS)
		lr_items = items
		lr_status = "found" if not items.is_empty() else "none"
		if items.is_empty():
			lr_message = "비슷한 곡도 찾지 못했어요. 가사를 붙여넣어 주세요."
		else:
			lr_message = "비슷한 곡 %d개를 찾았어요. 하나를 골라 주세요." % items.size()
		if not lr_record.is_empty() and not _in_items(lr_record):
			lr_record = {}
	else:
		lr_status = "error"
		lr_message = _lr_error_text(res)
	_render()


func _in_items(rec: Dictionary) -> bool:
	for it in lr_items:
		if int((it as Dictionary).get("id", -1)) == int(rec.get("id", -2)):
			return true
	return false


func _lr_error_text(res: Dictionary) -> String:
	var t: String = SongView.clip(str(res.get("message", "")), 200)
	if t == "":
		t = "가사를 찾지 못했어요."
	var ra: float = float(res.get("retry_after", 0.0))
	if str(res.get("err_code", "")) == "rate_limited" and ra > 0.0:
		t += " (약 %d초 뒤)" % int(ceilf(ra))
	return t + " " + MSG_PASTE_HINT + " 제목이나 가수를 고치면 다시 찾을 수 있어요."


## 후보를 고른다. 쓸 수 없는 후보(연주곡 · 가사 없음)는 false.
func choose_candidate(i: int) -> bool:
	if i < 0 or i >= lr_items.size():
		return false
	var rec: Dictionary = lr_items[i]
	if not SongAddScreen.usable_record(rec):
		return false
	lr_record = rec
	source = "lrclib"
	_adopt_record_names(rec)
	save_error = ""
	_render()
	return true


## 제목·가수가 비어 있으면 후보의 것으로 채운다 (말줄임 한도 안에서). 같은 곡이므로 찾기 횟수는 그대로 둔다.
func _adopt_record_names(rec: Dictionary) -> void:
	if title_text.strip_edges() == "":
		title_text = SongView.clip(str(rec.get("trackName", "")), SongAddScreen.TITLE_MAX)
	if artist_text.strip_edges() == "":
		artist_text = SongView.clip(str(rec.get("artistName", "")), SongAddScreen.ARTIST_MAX)
	_lr_key = _query_key()


# ---------------------------------------------------------------- saving

## [저장하고 외우기]. 저장하지 못하면 이유(한국어)를 돌려주고 화면에 보인다 (입력한 가사는 화면에 그대로 남는다). 저장했으면 "".
func save() -> String:
	save_error = ""
	var why: String = save_block_reason()
	if why != "":
		return _fail_save(why)
	var prep: Dictionary = current_lyrics()
	var song: Dictionary = build_song(lang, effective_title(), effective_artist(), source, lr_record, prep)
	var res: Dictionary = SongStore.install_lyrics(song)
	if not bool(res.get("ok", false)):
		var code: String = str(res.get("err_code", "disk_write"))
		return _fail_save(str(MSG_SAVE_ERR.get(code, MSG_SAVE_ERR["disk_write"])))
	added_id = str(res.get("id", ""))
	phase = "done"
	_render()
	song_added.emit(added_id)
	return ""


func _fail_save(msg: String) -> String:
	save_error = msg
	if _err_label != null and is_instance_valid(_err_label):
		_err_label.text = msg
		_err_label.visible = msg != ""
	Toast.info(msg)
	return msg


# ---------------------------------------------------------------- build (page)

func _render() -> void:
	if _dead:
		return
	var page: PageScroll = _shell["page"]
	UI.clear(page.content)
	_title_edit = null
	_artist_edit = null
	_duration_edit = null
	_paste_edit = null
	_preview_label = null
	_duration_note = null
	_hint_label = null
	_err_label = null
	_save_btn = null
	_find_btn = null
	_search_btn = null
	var c: VBoxContainer = page.content
	if phase == "done":
		_render_done(c)
	else:
		_render_form(c)
	_render_footer()


func _section(title: String) -> CardBox:
	var card: CardBox = UI.card("Card", 10)
	card.body.add_child(UI.label(title, "Eyebrow", false))
	return card


func _render_form(c: VBoxContainer) -> void:
	var u: Dictionary = SongStore.usage()
	if int(u.get("songs", 0)) >= int(u.get("max_songs", SongStore.MAX_SONGS)) or int(u.get("bytes", 0)) >= int(u.get("max_bytes", SongStore.MAX_BYTES)):
		var full := SpeakDrill.notice(MSG_SAVE_ERR["quota_songs"])
		full.name = "FullNotice"
		c.add_child(full)
	# 1. 곡 정보
	var icard: CardBox = _section("1. 곡 정보")
	icard.body.add_child(UI.lang_segmented(lang, set_lang))
	_title_edit = LineEdit.new()
	_title_edit.name = "TitleInput"
	_title_edit.text = title_text
	_title_edit.max_length = SongModel.LEN_TITLE
	_title_edit.placeholder_text = "곡 제목"
	_title_edit.text_changed.connect(set_title)
	icard.body.add_child(UI.field("제목", _title_edit))
	_artist_edit = LineEdit.new()
	_artist_edit.name = "ArtistInput"
	_artist_edit.text = artist_text
	_artist_edit.max_length = SongModel.LEN_TITLE
	_artist_edit.placeholder_text = "가수 (LRCLIB로 찾을 때 필요해요)"
	_artist_edit.text_changed.connect(set_artist)
	icard.body.add_child(UI.field("가수", _artist_edit))
	c.add_child(icard)
	# 2. 가사
	c.add_child(_build_lyrics_card())


func _build_lyrics_card() -> CardBox:
	var card: CardBox = _section("2. 가사")
	var seg: PanelContainer = UI.segmented(SOURCES, source, set_source)
	seg.name = "SourceSeg"
	card.body.add_child(seg)
	match source:
		"pasted":
			card.body.add_child(UI.label("가사는 직접 붙여넣어 주세요. 개인 학습용으로 이 기기에만 저장돼요. [00:12.30] 같은 시간표가 있어도 글자만 써요.", "Muted"))
			_paste_edit = TextEdit.new()
			_paste_edit.name = "PasteInput"
			_paste_edit.text = pasted_text
			_paste_edit.placeholder_text = "가사를 붙여넣어 주세요."
			_paste_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			_paste_edit.custom_minimum_size.y = 180.0
			_paste_edit.text_changed.connect(func() -> void: set_pasted(_paste_edit.text))
			card.body.add_child(_paste_edit)
			_preview_label = UI.label("", "Small")
			_preview_label.name = "LyricsPreview"
			card.body.add_child(_preview_label)
			_update_preview()
		"lrclib":
			_build_lrclib(card)
	return card


func _build_lrclib(card: CardBox) -> void:
	card.body.add_child(UI.label("[가사 찾기]를 누르면 곡 제목·가수(와 적었다면 길이)가 lrclib.net으로 전송돼요. 누를 때만 보내고, 곡 하나당 찾기는 한 번, 비슷한 곡 검색은 한 번만 해요.", "Muted"))
	_duration_edit = LineEdit.new()
	_duration_edit.name = "DurationInput"
	_duration_edit.text = duration_text
	_duration_edit.max_length = 12
	_duration_edit.placeholder_text = "예: 3:42"
	_duration_edit.text_changed.connect(set_duration_text)
	card.body.add_child(UI.field("곡 길이 (선택, 분:초)", _duration_edit))
	_duration_note = UI.label(duration_note_text(), "Small")
	_duration_note.name = "DurationNote"
	_duration_note.visible = _duration_note.text != ""
	card.body.add_child(_duration_note)
	var row := UI.flow(10, 8)
	_find_btn = SpeakDrill.touch_button("가사 찾기", "primary", Pal.PRIMARY)
	_find_btn.name = "BtnFind"
	_find_btn.disabled = lr_busy
	_find_btn.pressed.connect(func() -> void: find_lyrics())
	row.add_child(_find_btn)
	_search_btn = SpeakDrill.touch_button("비슷한 곡 찾기", "outline", Pal.PRIMARY)
	_search_btn.name = "BtnSearch"
	_search_btn.disabled = lr_busy or lr_search_calls >= 1
	_search_btn.pressed.connect(func() -> void: search_lyrics())
	row.add_child(_search_btn)
	card.body.add_child(row)
	if lr_message != "":
		var m := SpeakDrill.notice(lr_message, lr_status == "error")
		m.name = "LrMessage"
		card.body.add_child(m)
		if lr_status == "error" or lr_status == "none" or lr_status == "instrumental":
			var to_paste := SpeakDrill.touch_button("가사 붙여넣기", "outline", Pal.INK)
			to_paste.name = "BtnToPaste"
			to_paste.pressed.connect(func() -> void: set_source("pasted"))
			card.body.add_child(to_paste)
	if not lr_items.is_empty():
		var g: ListGroup = UI.card("Group") as ListGroup
		g.name = "Candidates"
		var n: int = mini(lr_items.size(), SHOW_ITEMS)
		for i in n:
			var rec: Dictionary = lr_items[i]
			var tx: Dictionary = SongAddScreen.candidate_text(rec, query_duration())
			var chosen: bool = not lr_record.is_empty() and int(rec.get("id", -1)) == int(lr_record.get("id", -2))
			var trailing: Control = UI.chip_kind("선택됨", "ok") if chosen else null
			var tap: Callable = Callable()
			if SongAddScreen.usable_record(rec):
				var idx: int = i
				tap = func() -> void: choose_candidate(idx)
			g.add_row(str(tx["main"]), str(tx["sub"]), trailing, tap)
		card.body.add_child(g)
	if source == "lrclib" and not lr_record.is_empty():
		_preview_label = UI.label("", "Small")
		_preview_label.name = "LyricsPreview"
		card.body.add_child(_preview_label)
		_update_preview()
		var at := UI.label(SongAddScreen.ATTRIBUTION, "Small")
		at.name = "Attribution"
		card.body.add_child(at)


func _update_preview() -> void:
	if _preview_label == null or not is_instance_valid(_preview_label):
		return
	_preview_label.text = preview_text()


func _update_duration_note() -> void:
	if _duration_note == null or not is_instance_valid(_duration_note):
		return
	_duration_note.text = duration_note_text()
	_duration_note.visible = _duration_note.text != ""


func _render_done(c: VBoxContainer) -> void:
	var card: CardBox = _section("저장했어요")
	card.name = "DoneCard"
	card.body.add_child(UI.label("곡과 가사는 이 기기에만 저장돼요. 동기화와 백업에는 들어가지 않아요.", "Muted"))
	c.add_child(card)


func _render_footer() -> void:
	var fcol: ColumnBox = _shell["footer_col"]
	UI.clear(fcol.content)
	var holder: PanelContainer = _shell["footer_holder"]
	_hint_label = null
	_err_label = null
	_save_btn = null
	if phase == "form":
		_err_label = UI.colored(save_error, Pal.BAD_ON)
		_err_label.name = "SaveError"
		_err_label.visible = save_error != ""
		fcol.content.add_child(_err_label)
		_hint_label = UI.label("", "Small")
		_hint_label.name = "SaveHint"
		fcol.content.add_child(_hint_label)
		_save_btn = SpeakDrill.touch_button("저장하고 외우기", "primary", Pal.PRIMARY)
		_save_btn.name = "BtnSave"
		_save_btn.pressed.connect(func() -> void: save())
		fcol.content.add_child(_save_btn)
		_refresh_footer_state()
		holder.visible = true
	elif phase == "done":
		var close_btn := SpeakDrill.touch_button("닫기", "outline", Pal.INK)
		close_btn.name = "BtnClose"
		close_btn.pressed.connect(func() -> void: closed.emit())
		fcol.content.add_child(close_btn)
		holder.visible = true
	else:
		holder.visible = false


## 저장 단추 · 안내 글자만 다시 맞춘다 (입력하는 동안 화면을 다시 만들지 않는다).
func _refresh_footer_state() -> void:
	if _save_btn == null or not is_instance_valid(_save_btn):
		return
	var why: String = save_block_reason()
	_save_btn.disabled = why != ""
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.text = why
		_hint_label.visible = why != ""
