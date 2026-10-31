class_name SongAddScreen
extends Control
## 노래 공부 U2: 곡 추가 화면 (docs/song_study_design.md §2 L4~L8, §4.2, §4.3, §5.4, §5.6, §12.1a, §12.1b).
##
## 흐름: 파일 고르기(SongImport) -> 언어·제목·가수 -> 가사 출처 3개(받아 적기 / 붙여넣기 / LRCLIB) -> 옵션 -> [곡 만들기]
##   -> 진행 화면(SongTransfer: 올리는 중 · 단계 · 퍼센트 · 남은 시간 · [취소]) -> 완료하면 song_added(song_id).
##   끊기면 [이어 받기] / [이어서 올리기], 앱을 다시 열면 SongStore.pending_list() 의 작업을 [이어 받기] 로 되살린다.
## PC 가 없거나(폰 단독·폰만 모드) PC 프로그램이 옛 버전(/health 에 song 없음)이거나 저장 공간이 가득 차면 안내만 보이고 추가하지 않는다.
##
## LRCLIB 이용 규칙(§2 L4): 사용자가 [가사 찾기] 를 누를 때만 부른다. 곡(고른 파일) 하나당 GET /api/get 1번 + 검색 1번까지만
##   (같은 질의를 다시 눌러도 새로 부르지 않는다. 파일을 다시 고르면 새 곡이다). 입력 중 자동 호출 없음.
##   결과 글자는 길이 제한이 없어서 화면에 올릴 때 말줄임으로 자른다. LRCLIB 에서 받은 곡은 출처 문구를 보인다(L7).
## 보내기 전 가사 자르기(서버 한도 §5.1): 400줄 · 한 줄 200자 · 합계 20000자. 넘으면 자르고 안내한다. [Chorus] 같은 [ ... ] 만 있는 줄은 뺀다.
## 해석: 곡별 해석 켬 = song["translate"] (설치된 곡에 저장). ai_ok = song_consent AND 해석 켬 (§12.1b, SongMeaningTab.ai_ok 재사용).
##   동의 전이면 항상 false -> 가사가 AI 서비스로 나가지 않는다. 단어 뜻도 AI 가 만들므로 해석을 끄면 같이 꺼진다.
##
## 허브 계약(PracticeView 와 같은 모양):
##   signal closed                  화면을 떠난다.
##   signal song_added(song_id)     곡 설치가 끝났다. 가사 확인 화면(U3)이나 학습 화면으로 넘기는 것은 연결하는 쪽이 한다.
##   func open(lang, args)          args: {"lang": "en"|"ja"}
##   func go_back()                 안드로이드 뒤로 가기 / 머리줄 버튼. 항상 true.
## 시험용 장치: importer.dialog_hook, duration_probe, lrclib_base_url, lrclib_factory, transfer(poll_interval 등).

signal closed
signal song_added(song_id: String)

const MAX_LINES := SongTransfer.MAX_LINES
const MAX_LINE_CHARS := SongTransfer.MAX_LINE_CHARS
const MAX_LYRIC_CHARS := SongTransfer.MAX_LYRIC_CHARS
const PREF_TRANSLATE := "song_translate"
const PREF_GLOSS := "song_gloss"
const ATTRIBUTION := "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"
const SOURCES := [["none", "받아 적기"], ["pasted", "붙여넣기"], ["lrclib", "LRCLIB"]]
const SHOW_ITEMS := 20
const TITLE_MAX := 60
const ARTIST_MAX := 40
const ALBUM_MAX := 30

const MSG_NEED_FILE := "곡 파일을 먼저 골라 주세요."
const MSG_NEED_PASTE := "붙여넣은 가사가 없어요. 가사를 붙여넣거나 '받아 적기'를 골라 주세요."
const MSG_NEED_LRCLIB := "가사를 찾아서 목록에서 하나 골라 주세요. 찾지 못하면 '붙여넣기'나 '받아 적기'를 써 보세요."
const MSG_BUSY := "이미 곡을 처리하고 있어요."
const MSG_NO_DIALOG := "이 폰에서는 파일을 고를 수 없어요."
const MSG_TITLE_SHORT := "LRCLIB로 찾으려면 곡 제목과 가수를 두 글자 이상 적어 주세요."
const MSG_LR_USED := "이 곡은 이미 그 방법으로 찾아봤어요. 아래 결과를 쓰거나, 가사를 붙여넣어 주세요. 곡 파일을 다시 고르면 처음부터 다시 찾을 수 있어요."
const MSG_LR_RETRY := "다시 찾으려면 곡 파일을 다시 골라 주세요. 가사를 붙여넣어도 돼요."
const MSG_LR_BUSY := "가사를 찾는 중이에요."
const MSG_WARN := {
	"low_match": "가사와 소리가 잘 맞지 않았어요. 가사 확인 화면에서 줄을 들어 보고 고쳐 주세요.",
	"est_times": "일부 줄의 시간은 추정이에요. 가사 확인 화면에서 맞춰 주세요.",
	"offset_guess": "가사 시간이 소리와 조금 어긋나 있어서 PC가 맞춰 봤어요. 확인 화면에서 한 번 들어 주세요.",
	"duration_mismatch": "가사의 곡 길이와 파일 길이가 달라요. 다른 녹음일 수 있어요.",
	"no_vocals": "노랫소리를 거의 찾지 못했어요.",
	"hallucination_cut": "잘못 받아 적은 부분은 PC가 지웠어요.",
	"ko_missing": "해석은 만들지 못했어요. 곡 화면의 해석 탭에서 다시 만들 수 있어요.",
	"gloss_missing": "단어 뜻은 만들지 못했어요.",
	"lyrics_truncated": "가사가 너무 길어서 일부만 썼어요.",
}

## 시험에서 바꾸는 값
var lrclib_base_url: String = LrclibClient.DEFAULT_BASE_URL
var lrclib_factory: Callable = Callable() ## () -> LrclibClient (add_child 는 이 화면이 한다)
var duration_probe: Callable = Callable() ## (path) -> float 초, 모르면 -1.0

var importer: SongImport = null
var transfer: SongTransfer = null

var lang: String = "en"
var phase: String = "form" ## form | running | failed | done
var file: Dictionary = {} ## {path, name, size, duration}
var pick_error: String = ""
var make_error: String = ""
var title_text: String = ""
var artist_text: String = ""
var source: String = "none" ## none | pasted | lrclib
var pasted_text: String = ""
var opt_translate: bool = true
var opt_gloss: bool = true
var opt_verify: bool = true

## LRCLIB 상태 (곡 하나당)
var lr_get_calls: int = 0 ## GET /api/get 을 부른 횟수 (0 또는 1)
var lr_search_calls: int = 0 ## GET /api/search 를 부른 횟수 (0 또는 1)
var lr_status: String = "" ## "" | busy | found | none | instrumental | error
var lr_message: String = ""
var lr_items: Array = [] ## 후보 (정규화된 record, 말줄임은 표시할 때)
var lr_record: Dictionary = {} ## 고른 후보
var lr_busy: bool = false

var run_notes: Array = [] ## 만들기를 시작할 때의 가사 안내 (잘림 등)
var last_progress: Dictionary = {} ## {stage, pct, text}
var last_result: Dictionary = {} ## 마지막 SongTransfer.finished
var added_id: String = ""
var added_warnings: Array = []

var _shell: Dictionary = {}
var _client: LrclibClient = null
var _lr_gen: int = 0 ## 곡(고른 파일)이 바뀔 때마다 오른다: 날아가던 LRCLIB 요청의 늦은 답은 세대가 다르면 버린다
var _dead: bool = false
var _last_block: String = "?"
var _title_edit: LineEdit = null
var _artist_edit: LineEdit = null
var _paste_edit: TextEdit = null
var _preview_label: Label = null
var _err_label: Label = null
var _stage_label: Label = null
var _pct_label: Label = null
var _bar: ProgressBar = null
var _hint_label: Label = null
var _make_btn: Button = null
var _cancel_btn: Button = null
var _find_btn: Button = null
var _search_btn: Button = null
var _confirm_sheet: Sheet = null
var _translate_by_job: Dictionary = {} ## job -> 이 화면에서 정한 "해석 켬" (앱을 다시 켠 뒤에는 모른다)
var _run_translate: bool = true
var _resumed_job: String = ""


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back, "← 곡")
	(_shell["title"] as Label).text = "곡 추가"
	importer = SongImport.new()
	add_child(importer)
	importer.picked.connect(_on_picked)
	importer.failed.connect(_on_pick_failed)
	transfer = SongTransfer.new()
	add_child(transfer)
	transfer.progress.connect(_on_progress)
	transfer.finished.connect(_on_finished)


func _ready() -> void:
	Backend.status_changed.connect(_on_env_changed)
	Route.mode_changed.connect(_on_route_mode)


func _exit_tree() -> void:
	_dead = true
	if transfer != null and is_instance_valid(transfer):
		transfer.abandon() ## PC 에는 아무것도 보내지 않는다 (pending 은 그대로 남는다)
	_drop_client()


# ---------------------------------------------------------------- open / close

func open(l: String = "", args: Dictionary = {}) -> void:
	var want: String = str(args.get("lang", l))
	lang = want if want == "ja" else "en"
	phase = "form"
	file = {}
	pick_error = ""
	make_error = ""
	title_text = ""
	artist_text = ""
	source = "none"
	pasted_text = ""
	opt_translate = bool(Store.prefs.get(PREF_TRANSLATE, true))
	opt_gloss = bool(Store.prefs.get(PREF_GLOSS, true))
	opt_verify = true
	_reset_lrclib()
	run_notes = []
	last_progress = {}
	last_result = {}
	added_id = ""
	added_warnings = []
	_last_block = block_reason()
	_render()


func on_hide() -> void:
	pass


## 안드로이드 뒤로 가기 / 머리줄 버튼. 만드는 중이면 확인을 묻는다. 항상 true(처리함).
func go_back() -> bool:
	if phase == "running" and transfer != null and transfer.busy:
		var msg: String = "PC에서 곡을 만드는 일은 그대로 이어져요. 작업이 시작된 뒤라면 이 화면을 다시 열어 '이어 받기'로 받을 수 있어요."
		if transfer.job_id == "":
			msg = "아직 곡을 올리는 중이라 지금 나가면 처음부터 다시 올려야 해요."
		_confirm("곡 만들기를 멈추고 나갈까요?", msg, "나가기", "계속 기다리기", _leave)
		return true
	_leave()
	return true


func _leave() -> void:
	if transfer != null and is_instance_valid(transfer):
		transfer.abandon()
	_drop_client()
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


# ---------------------------------------------------------------- can the person add a song? (static)

## "" = 된다. "no_pc" (PC 없음 · 폰만 모드), "old_pc" (PC 프로그램에 노래 기능 없음), "full" (40곡 / 400 MiB).
static func block_reason() -> String:
	if Route.decide("POST", "/song/jobs") == "none" or not Backend.is_ready():
		return "no_pc"
	if not bool(Backend.health.get("song", false)):
		return "old_pc"
	var u: Dictionary = SongStore.usage()
	if int(u.get("songs", 0)) >= int(u.get("max_songs", SongStore.MAX_SONGS)) or int(u.get("bytes", 0)) >= int(u.get("max_bytes", SongStore.MAX_BYTES)):
		return "full"
	return ""


static func block_text(reason: String) -> String:
	match reason:
		"no_pc":
			return SongView.MSG_NO_PC_PHONE if Platform.is_phone() else SongView.MSG_NO_PC_PC
		"old_pc":
			return SongView.MSG_OLD_PC
		"full":
			var u: Dictionary = SongStore.usage()
			return SongView.MSG_FULL % [int(u.get("songs", 0)), SongView.fmt_bytes(int(u.get("bytes", 0)))]
	return ""


## ai_ok = song_consent AND 해석 켬 (§12.1b). 동의 전에는 항상 false.
static func ai_ok_for(translate: bool) -> bool:
	return SongMeaningTab.ai_ok({"translate": translate})


# ---------------------------------------------------------------- lyrics preparation (static, tested)

## 가사 글자 -> 서버로 보낼 줄. source: "pasted" | "lrclib". record: LRCLIB 후보(source == "lrclib").
## 반환: {lines: [{text, t: float|null, p}], timed: bool, notes: Array[String], marks: int, cut_lines: int,
##        cut_chars: int, cut_total: bool, source_count: int}
## - 시간표가 있는 가사(LRC)면 줄마다 t, 아니면 t = null 과 연 번호 p (LrcParser.split_plain). 빈 시간표 줄(gap)은 버리고 그 자리에서 p 를 올린다.
## - [Chorus] 같은 [ ... ] 만 있는 줄은 뺀다.
## - 서버 한도에 맞춰 자른다: 한 줄 200자, 400줄, 합계 20000자 (SongTransfer 가 보낼 때 자르는 규칙과 같다).
static func prepare_lyrics(src: String, text: String, record: Dictionary = {}) -> Dictionary:
	var raw: String = text
	var force_plain: bool = false
	if src == "lrclib":
		var synced: String = str(record.get("syncedLyrics", ""))
		if synced.strip_edges() != "":
			raw = synced
		else:
			raw = str(record.get("plainLyrics", ""))
			force_plain = true
	var entries: Array = [] ## {text, t (float|null), p}
	var timed: bool = false
	if not force_plain:
		var parsed: Dictionary = LrcParser.parse(raw)
		if bool(parsed.get("timed", false)):
			timed = true
			var p := 0
			var gap_pending := false
			for ln in (parsed["lines"] as Array):
				var d: Dictionary = ln
				var tx: String = str(d.get("text", "")).strip_edges()
				if bool(d.get("gap", false)) or tx == "":
					if not entries.is_empty():
						gap_pending = true
					continue
				if gap_pending:
					p += 1
					gap_pending = false
				var tv: float = float(d.get("t", -1.0))
				entries.append({"text": tx, "t": (tv if tv >= 0.0 else null), "p": p})
	if not timed:
		for it in LrcParser.split_plain(raw):
			entries.append({"text": str((it as Dictionary)["text"]), "t": null, "p": int((it as Dictionary)["p"])})
	var res := {"lines": [], "timed": timed, "notes": [], "marks": 0, "cut_lines": 0, "cut_chars": 0, "cut_total": false,
		"source_count": entries.size()}
	var out: Array = []
	var chars := 0
	var idx := 0
	for e in entries:
		idx += 1
		var tx2: String = str((e as Dictionary)["text"])
		if tx2.begins_with("[") and tx2.ends_with("]"):
			res["marks"] = int(res["marks"]) + 1
			continue
		if out.size() >= MAX_LINES:
			res["cut_lines"] = int(res["cut_lines"]) + 1
			continue
		if tx2.length() > MAX_LINE_CHARS:
			tx2 = tx2.substr(0, MAX_LINE_CHARS).strip_edges()
			res["cut_chars"] = int(res["cut_chars"]) + 1
		if bool(res["cut_total"]) or chars + tx2.length() > MAX_LYRIC_CHARS:
			res["cut_total"] = true
			res["cut_lines"] = int(res["cut_lines"]) + 1
			continue
		chars += tx2.length()
		out.append({"text": tx2, "t": (e as Dictionary)["t"], "p": (e as Dictionary)["p"]})
	res["lines"] = out
	var notes: Array = []
	if int(res["marks"]) > 0:
		notes.append("[Chorus] 같은 구간 표시 %d줄은 뺐어요." % int(res["marks"]))
	if int(res["cut_chars"]) > 0:
		notes.append("%d줄은 %d자를 넘어서 %d자까지만 써요." % [int(res["cut_chars"]), MAX_LINE_CHARS, MAX_LINE_CHARS])
	if bool(res["cut_total"]):
		notes.append("가사 글자가 %d자를 넘어서 앞부분까지만 써요. (뒤의 %d줄은 뺐어요)" % [MAX_LYRIC_CHARS, int(res["cut_lines"])])
	elif int(res["cut_lines"]) > 0:
		notes.append("가사가 %d줄을 넘어서 앞의 %d줄까지만 써요. (뒤의 %d줄은 뺐어요)" % [MAX_LINES, MAX_LINES, int(res["cut_lines"])])
	res["notes"] = notes
	return res


## LRCLIB 후보 한 줄의 표시 글자 {main, sub}. 결과 글자는 길이 제한이 없어서 말줄임으로 자른다.
static func candidate_text(rec: Dictionary, file_duration: float) -> Dictionary:
	var name: String = SongView.clip(str(rec.get("trackName", rec.get("name", ""))), TITLE_MAX)
	var artist: String = SongView.clip(str(rec.get("artistName", "")), ARTIST_MAX)
	var main: String = name if name != "" else "(제목 없음)"
	if artist != "":
		main += " - " + artist
	var parts: Array = []
	var album: String = SongView.clip(str(rec.get("albumName", "")), ALBUM_MAX)
	if album != "":
		parts.append(album)
	var dur: float = float(rec.get("duration", 0.0))
	if dur > 0.0:
		parts.append(SongView.fmt_dur(dur))
		if file_duration > 0.0:
			var diff: float = absf(dur - file_duration)
			if diff > LrclibClient.DURATION_TOLERANCE:
				parts.append("파일과 %d초 달라요" % int(roundf(diff)))
	parts.append(lyric_kind(rec))
	return {"main": main, "sub": " · ".join(parts)}


static func lyric_kind(rec: Dictionary) -> String:
	if bool(rec.get("instrumental", false)):
		return "연주곡 (가사 없음)"
	if str(rec.get("syncedLyrics", "")).strip_edges() != "":
		return "줄 시간 있음"
	if str(rec.get("plainLyrics", "")).strip_edges() != "":
		return "글자만 있음"
	return "가사 없음"


static func usable_record(rec: Dictionary) -> bool:
	if bool(rec.get("instrumental", false)):
		return false
	return str(rec.get("syncedLyrics", "")).strip_edges() != "" or str(rec.get("plainLyrics", "")).strip_edges() != ""


## "Artist - Title.mp3" 모양의 파일 이름에서 [제목, 가수]. 모양이 다르면 [이름, ""].
static func guess_from_name(file_name: String) -> Array:
	var base: String = file_name.get_basename().replace("_", " ").strip_edges()
	var i: int = base.find(" - ")
	if i > 0 and i + 3 < base.length():
		return [base.substr(i + 3).strip_edges(), base.substr(0, i).strip_edges()]
	return [base, ""]


# ---------------------------------------------------------------- state (public, used by the form and by tests)

func set_lang(l: String) -> void:
	lang = l if l == "ja" else "en"
	_render()


func set_title(t: String) -> void:
	title_text = t.substr(0, SongModel.LEN_TITLE)


func set_artist(t: String) -> void:
	artist_text = t.substr(0, SongModel.LEN_TITLE)


func set_source(s: String) -> void:
	if not ["none", "pasted", "lrclib"].has(s):
		return
	source = s
	make_error = ""
	_render()


func set_pasted(t: String) -> void:
	pasted_text = t
	_update_preview()


func set_translate(on: bool) -> void:
	opt_translate = on
	_render()


func set_gloss(on: bool) -> void:
	opt_gloss = on


func set_verify(on: bool) -> void:
	opt_verify = on


## 고른 파일을 받아들인다. 못 받으면 이유를 pick_error 에 두고 false (이전에 고른 파일은 그대로).
func set_file(path: String) -> bool:
	pick_error = ""
	var info: Dictionary = SongImport.inspect(path)
	if not bool(info.get("ok", false)):
		pick_error = str(info.get("message", ""))
		_render()
		return false
	var dur: float = float(duration_probe.call(path)) if duration_probe.is_valid() else SongImport.probe_duration(path)
	if dur > SongImport.MAX_SECONDS:
		pick_error = SongTransfer.message_for("too_long")
		_render()
		return false
	file = {"path": path, "name": str(info["name"]), "size": int(info["size"]), "duration": dur}
	_reset_lrclib() ## 새 곡: 가사 찾기 횟수도 새로
	if title_text.strip_edges() == "" and artist_text.strip_edges() == "":
		var g: Array = guess_from_name(str(info["name"]))
		title_text = str(g[0]).substr(0, SongModel.LEN_TITLE)
		artist_text = str(g[1]).substr(0, SongModel.LEN_TITLE)
	_render()
	return true


func current_lyrics() -> Dictionary:
	match source:
		"pasted":
			return prepare_lyrics("pasted", pasted_text)
		"lrclib":
			if lr_record.is_empty():
				return _empty_prep()
			return prepare_lyrics("lrclib", "", lr_record)
	return _empty_prep()


static func _empty_prep() -> Dictionary:
	return {"lines": [], "timed": false, "notes": [], "marks": 0, "cut_lines": 0, "cut_chars": 0, "cut_total": false, "source_count": 0}


func effective_title() -> String:
	var t: String = title_text.strip_edges()
	if t == "" and not file.is_empty():
		t = str(guess_from_name(str(file.get("name", "")))[0])
	return t.substr(0, SongModel.LEN_TITLE)


## SongTransfer.start 에 줄 params. ai_ok = song_consent AND 해석 켬.
func build_params() -> Dictionary:
	var prep: Dictionary = current_lyrics()
	var lyr := {"source": source, "lines": prep["lines"]}
	if source == "lrclib" and not lr_record.is_empty():
		lyr["lrclib_id"] = int(lr_record.get("id", 0))
	if source != "lrclib":
		lyr.erase("lrclib_id")
	if source == "none":
		lyr["lines"] = []
	var nm: String = str(file.get("name", ""))
	if str(file.get("path", "")).begins_with("content://"):
		nm = ""
	return {
		"lang": lang, "title": effective_title(), "artist": artist_text.strip_edges().substr(0, SongModel.LEN_TITLE), "name": nm,
		"lyrics": lyr,
		"options": {"translate": opt_translate, "gloss": opt_gloss and opt_translate, "verify": opt_verify and bool(prep["timed"]),
			"precise": false, "ai_ok": ai_ok_for(opt_translate)},
	}


# ---------------------------------------------------------------- picking a file

func pick_file() -> void:
	pick_error = ""
	importer.pick()


func _on_picked(path: String) -> void:
	set_file(path)


func _on_pick_failed(message: String) -> void:
	pick_error = message
	_render()


# ---------------------------------------------------------------- LRCLIB (only on the user's tap)

func _reset_lrclib() -> void:
	_lr_gen += 1 ## 이전 곡의 요청이 아직 날아가고 있어도 그 답은 새 곡에 붙지 않는다
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


func _file_seconds() -> float:
	return float(file.get("duration", 0.0)) if not file.is_empty() else 0.0


## [가사 찾기]: GET /api/get 1번. 이미 썼으면 부르지 않고 지난 결과를 다시 보인다.
func find_lyrics() -> void:
	if lr_busy:
		return
	var tr: String = title_text.strip_edges()
	var ar: String = artist_text.strip_edges()
	if tr.length() < LrclibClient.MIN_QUERY_CHARS or ar.length() < LrclibClient.MIN_QUERY_CHARS:
		lr_status = "error"
		lr_message = MSG_TITLE_SHORT
		_render()
		return
	if lr_get_calls >= 1:
		Toast.info(MSG_LR_USED) ## 곡 하나당 한 번: 새로 부르지 않는다
		return
	lr_get_calls += 1
	lr_busy = true
	lr_status = "busy"
	lr_message = MSG_LR_BUSY
	_render()
	var gen: int = _lr_gen
	var client: LrclibClient = _get_client()
	var res: Dictionary = await client.find(tr, ar, "", _file_seconds())
	if _dead or gen != _lr_gen:
		return # 화면이 닫혔거나, 그동안 다른 곡 파일을 골랐다: 이 답은 버린다
	lr_busy = false
	match str(res.get("kind", "error")):
		"exact":
			var rec: Dictionary = res["record"]
			lr_items = [rec]
			if usable_record(rec):
				lr_status = "found"
				lr_message = "찾았어요. 맞는 곡이면 이대로 쓰고, 아니면 '비슷한 곡 찾기'를 눌러 보세요."
				lr_record = rec
				_adopt_record_names(rec)
			else:
				lr_status = "none"
				lr_message = "찾았지만 이 곡에는 쓸 수 있는 가사가 없어요."
		"none":
			lr_status = "none"
			lr_message = "LRCLIB에서 이 곡의 가사를 찾지 못했어요. '비슷한 곡 찾기'를 눌러 보거나 가사를 붙여넣어 주세요."
		"instrumental":
			lr_status = "instrumental"
			lr_items = [res["record"]]
			lr_message = "연주곡이라 가사가 없어요."
		_:
			lr_status = "error"
			lr_message = _lr_error_text(res)
	_render()


## [비슷한 곡 찾기]: GET /api/search 1번.
func search_lyrics() -> void:
	if lr_busy:
		return
	var tr: String = title_text.strip_edges()
	var ar: String = artist_text.strip_edges()
	if tr.length() < LrclibClient.MIN_QUERY_CHARS and ar.length() < LrclibClient.MIN_QUERY_CHARS:
		lr_status = "error"
		lr_message = MSG_TITLE_SHORT
		_render()
		return
	if lr_search_calls >= 1:
		Toast.info(MSG_LR_USED)
		return
	lr_search_calls += 1
	lr_busy = true
	lr_status = "busy"
	lr_message = MSG_LR_BUSY
	_render()
	var gen: int = _lr_gen
	var client: LrclibClient = _get_client()
	var res: Dictionary = await client.search((tr + " " + ar).strip_edges(), tr, ar, _file_seconds())
	if _dead or gen != _lr_gen:
		return # see find_lyrics
	lr_busy = false
	if bool(res.get("ok", false)):
		var items: Array = res.get("items", [])
		if items.size() > SHOW_ITEMS:
			items.resize(SHOW_ITEMS)
		lr_items = items
		lr_status = "found" if not items.is_empty() else "none"
		lr_message = "비슷한 곡 %d개를 찾았어요. 하나를 골라 주세요." % items.size() if not items.is_empty() else "비슷한 곡도 찾지 못했어요. 가사를 붙여넣거나 '받아 적기'를 써 보세요."
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
	var t: String = str(res.get("message", ""))
	if t == "":
		t = "가사를 찾지 못했어요."
	var ra: float = float(res.get("retry_after", 0.0))
	if str(res.get("err_code", "")) == "rate_limited" and ra > 0.0:
		t += " (약 %d초 뒤)" % int(ceilf(ra))
	return t + " " + MSG_LR_RETRY


## 후보를 고른다. 쓸 수 없는 후보(연주곡 · 가사 없음)는 false.
func choose_candidate(i: int) -> bool:
	if i < 0 or i >= lr_items.size():
		return false
	var rec: Dictionary = lr_items[i]
	if not usable_record(rec):
		return false
	lr_record = rec
	source = "lrclib"
	_adopt_record_names(rec)
	make_error = ""
	_render()
	return true


## 제목·가수가 비어 있으면 후보의 것으로 채운다 (말줄임 한도 안에서).
func _adopt_record_names(rec: Dictionary) -> void:
	if title_text.strip_edges() == "":
		title_text = SongView.clip(str(rec.get("trackName", "")), TITLE_MAX)
	if artist_text.strip_edges() == "":
		artist_text = SongView.clip(str(rec.get("artistName", "")), ARTIST_MAX)


# ---------------------------------------------------------------- making the song

## [곡 만들기]. 시작하지 못하면 이유(한국어)를 돌려주고 화면에 보인다. 시작했으면 "".
func make() -> String:
	make_error = ""
	if phase == "running" or (transfer != null and transfer.busy):
		return _fail_make(MSG_BUSY)
	var why: String = block_reason()
	if why != "":
		return _fail_make(block_text(why))
	if file.is_empty():
		return _fail_make(MSG_NEED_FILE)
	var info: Dictionary = SongImport.inspect(str(file["path"]))
	if not bool(info.get("ok", false)):
		return _fail_make(str(info.get("message", "")))
	if float(file.get("duration", -1.0)) > SongImport.MAX_SECONDS:
		return _fail_make(SongTransfer.message_for("too_long"))
	if source == "pasted" and current_lyrics()["lines"].is_empty():
		return _fail_make(MSG_NEED_PASTE)
	if source == "lrclib" and current_lyrics()["lines"].is_empty():
		return _fail_make(MSG_NEED_LRCLIB)
	var prep: Dictionary = current_lyrics()
	run_notes = (prep["notes"] as Array).duplicate()
	var params: Dictionary = build_params()
	Store.set_pref(PREF_TRANSLATE, opt_translate)
	Store.set_pref(PREF_GLOSS, opt_gloss)
	_run_translate = opt_translate
	_resumed_job = ""
	phase = "running"
	last_progress = {}
	last_result = {}
	_render()
	transfer.start(str(file["path"]), params)
	return ""


func _fail_make(msg: String) -> String:
	make_error = msg
	if _err_label != null and is_instance_valid(_err_label):
		_err_label.text = msg
		_err_label.visible = msg != ""
	Toast.info(msg)
	return msg


## [취소]: PC 에 cancel + release 를 보내고 폼으로 돌아간다.
func cancel_transfer() -> void:
	if transfer != null and transfer.busy:
		transfer.cancel()


## 앱을 다시 켠 뒤 등: SongStore.pending_list() 의 작업을 이어 받는다.
func resume_pending(rec: Dictionary) -> void:
	if transfer == null or transfer.busy:
		return
	var why: String = block_reason()
	if why != "" and why != "full":
		_fail_make(block_text(why))
		return
	_resumed_job = str(rec.get("job", ""))
	_run_translate = bool(_translate_by_job.get(_resumed_job, Store.prefs.get(PREF_TRANSLATE, true)))
	var l: String = str(rec.get("lang", lang))
	lang = l if l == "ja" else "en"
	run_notes = []
	phase = "running"
	last_progress = {}
	last_result = {}
	_render()
	transfer.resume(rec)


## 끊긴 올리기를 같은 파일·같은 upload_id 로 이어서 올린다.
func continue_upload() -> void:
	if transfer == null or transfer.busy or file.is_empty():
		return
	var uid: String = str(last_result.get("upload_id", ""))
	var params: Dictionary = build_params()
	if uid != "":
		params["upload_id"] = uid
	phase = "running"
	last_progress = {}
	_render()
	transfer.start(str(file["path"]), params)


## 기록만 지우고(PC 쪽 작업은 가능하면 release) 목록에서 뺀다.
func discard_pending(rec: Dictionary) -> void:
	var job: String = str(rec.get("job", ""))
	if job == "":
		return
	SongStore.pending_remove(job)
	if Api.base_url != "" and Route.decide("POST", "/song/jobs/release") != "none":
		Api.post_json("/song/jobs/release", {"job": job}, 15.0, false) ## 답을 기다리지 않는다
	_render()


func back_to_form() -> void:
	if phase == "running":
		return
	phase = "form"
	make_error = ""
	_render()


func _on_progress(stage: String, pct: float, text: String) -> void:
	last_progress = {"stage": stage, "pct": pct, "text": text}
	if phase != "running":
		return
	if _stage_label != null and is_instance_valid(_stage_label):
		_stage_label.text = text
	if _pct_label != null and is_instance_valid(_pct_label):
		_pct_label.text = "전체 %d%%" % int(round(pct))
	if _bar != null and is_instance_valid(_bar):
		_bar.value = clampf(pct / 100.0, 0.0, 1.0)
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.text = _running_hint()


func _running_hint() -> String:
	if transfer != null and transfer.job_id != "":
		return "이 화면을 나가도 PC에서는 계속 만들어요. 다시 열면 '이어 받기'로 받을 수 있어요."
	return "올리는 중에 나가면 처음부터 다시 올려야 해요."


func _on_finished(res: Dictionary) -> void:
	last_result = res
	if bool(res.get("ok", false)):
		_on_success(res)
		return
	if str(res.get("err_code", "")) == "cancelled":
		phase = "form"
		make_error = ""
		Toast.info(SongTransfer.message_for("cancelled"))
		_render()
		return
	phase = "failed"
	_render()


func _on_success(res: Dictionary) -> void:
	var id: String = str(res.get("song_id", ""))
	var job: String = str(res.get("job", ""))
	var tr_on: bool = bool(_translate_by_job.get(job, _run_translate))
	if _resumed_job != "" and not _translate_by_job.has(_resumed_job):
		tr_on = _guess_translate(id)
	if not _save_translate(id, tr_on):
		Toast.info("곡은 만들었지만 해석 설정을 저장하지 못했어요. 곡 화면의 해석 탭에서 다시 정해 주세요.")
	added_id = id
	added_warnings = (res.get("warnings", []) as Array).duplicate() if res.get("warnings", []) is Array else []
	phase = "done"
	_render()
	song_added.emit(id)


## 앱을 다시 켠 뒤 이어 받은 곡: 해석 글자가 하나라도 있으면 켬, 없으면 설정 값.
func _guess_translate(id: String) -> bool:
	var s: Dictionary = SongStore.load_song(id)
	for ln in (s.get("lines", []) as Array):
		if ln is Dictionary and str((ln as Dictionary).get("ko", "")).strip_edges() != "":
			return true
	return bool(Store.prefs.get(PREF_TRANSLATE, true))


## 설치된 곡에 곡별 "해석 켬" 을 쓴다 (song["translate"], U4b 와 같은 키).
func _save_translate(id: String, on: bool) -> bool:
	if id == "":
		return false
	var s: Dictionary = SongStore.load_song(id)
	if s.is_empty():
		return false
	s["translate"] = on
	return SongStore.save_song(s)


func _on_env_changed() -> void:
	if _dead or phase != "form":
		return
	var now: String = block_reason()
	if now != _last_block:
		_last_block = now
		make_error = "" ## an old "no PC" refusal is out of date now
		_render()


func _on_route_mode(_m: String) -> void:
	_on_env_changed()


# ---------------------------------------------------------------- build (page)

func _render() -> void:
	if _dead:
		return
	var page: PageScroll = _shell["page"]
	UI.clear(page.content)
	_title_edit = null
	_artist_edit = null
	_paste_edit = null
	_preview_label = null
	_err_label = null
	_stage_label = null
	_pct_label = null
	_bar = null
	_hint_label = null
	_make_btn = null
	_cancel_btn = null
	_find_btn = null
	_search_btn = null
	var c: VBoxContainer = page.content
	match phase:
		"running":
			_render_running(c)
		"failed":
			_render_failed(c)
		"done":
			_render_done(c)
		_:
			_render_form(c)
	_render_footer()


func _section(title: String) -> CardBox:
	var card: CardBox = UI.card("Card", 10)
	card.body.add_child(UI.label(title, "Eyebrow", false))
	return card


func _render_form(c: VBoxContainer) -> void:
	var why: String = block_reason()
	_last_block = why
	if why != "":
		c.add_child(SpeakDrill.notice(block_text(why)))
	else:
		_render_pending(c)
	# 1. 파일
	var fcard: CardBox = _section("1. 곡 파일")
	if file.is_empty():
		fcard.body.add_child(UI.label("내 기기에 있는 곡 파일을 골라 주세요 (mp3, m4a, ogg, wav, flac, aac, opus · 64MB 이하 · 10분 이하).", "Muted"))
	else:
		fcard.body.add_child(UI.label(SongView.clip(str(file["name"]), 80), "Strong"))
		var dur: float = float(file["duration"])
		var info: String = SongView.fmt_bytes(int(file["size"]))
		if dur > 0.0:
			info += " · " + SongView.fmt_dur(dur)
		fcard.body.add_child(UI.label(info, "Small"))
	var pick := SpeakDrill.touch_button("다른 파일 고르기" if not file.is_empty() else "파일 고르기", "outline" if not file.is_empty() else "primary", Pal.PRIMARY)
	pick.name = "BtnPick"
	pick.pressed.connect(pick_file)
	fcard.body.add_child(pick)
	if pick_error != "":
		var pe := SpeakDrill.notice(pick_error)
		pe.name = "PickError"
		fcard.body.add_child(pe)
	c.add_child(fcard)
	# 2. 곡 정보
	var icard: CardBox = _section("2. 곡 정보")
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
	_artist_edit.placeholder_text = "가수"
	_artist_edit.text_changed.connect(set_artist)
	icard.body.add_child(UI.field("가수", _artist_edit))
	c.add_child(icard)
	# 3. 가사
	c.add_child(_build_lyrics_card())
	# 4. 옵션
	c.add_child(_build_options_card())


func _render_pending(c: VBoxContainer) -> void:
	var recs: Array = SongStore.pending_list()
	if recs.is_empty():
		return
	var card: CardBox = _section("이어 받을 곡")
	card.name = "PendingCard"
	card.body.add_child(UI.label("PC에서 만들던 곡이 남아 있어요. 이어 받으면 곡이 기기에 저장돼요.", "Muted"))
	for r in recs:
		var rec: Dictionary = r
		var job: String = str(rec.get("job", ""))
		card.body.add_child(UI.label(SongView.clip(str(rec.get("title", "")), TITLE_MAX) if str(rec.get("title", "")) != "" else "(제목 없음)", "Strong"))
		var row := UI.flow(10, 8)
		var go := SpeakDrill.touch_button("이어 받기", "primary", Pal.PRIMARY)
		go.name = "BtnResume_" + job
		go.pressed.connect(func() -> void: resume_pending(rec))
		row.add_child(go)
		var drop := SpeakDrill.touch_button("버리기", "flat", Pal.INK)
		drop.name = "BtnDiscard_" + job
		drop.pressed.connect(func() -> void: discard_pending(rec))
		row.add_child(drop)
		card.body.add_child(row)
	c.add_child(card)


func _build_lyrics_card() -> CardBox:
	var card: CardBox = _section("3. 가사")
	var seg: PanelContainer = UI.segmented(SOURCES, source, set_source)
	seg.name = "SourceSeg"
	card.body.add_child(seg)
	match source:
		"none":
			card.body.add_child(UI.label("가사 없이 곡만 PC에 보내요. PC가 노래를 듣고 가사를 받아 적어요. 음악 위에서는 틀리는 곳이 있을 수 있어서, 만든 뒤 가사 확인 화면에서 고쳐야 해요.", "Muted"))
		"pasted":
			_paste_edit = TextEdit.new()
			_paste_edit.name = "PasteInput"
			_paste_edit.text = pasted_text
			_paste_edit.placeholder_text = "가사를 붙여넣어 주세요. [00:12.30] 같은 시간표가 있는 LRC 가사도 돼요."
			_paste_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			_paste_edit.custom_minimum_size.y = 180.0
			_paste_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	card.body.add_child(UI.label("[가사 찾기]를 누르면 곡 제목·가수·길이가 lrclib.net으로 전송돼요. 누를 때만 보내고, 곡 하나당 찾기는 한 번, 비슷한 곡 검색은 한 번만 해요.", "Muted"))
	var row := UI.flow(10, 8)
	_find_btn = SpeakDrill.touch_button("가사 찾기", "primary", Pal.PRIMARY)
	_find_btn.name = "BtnFind"
	_find_btn.disabled = lr_busy
	_find_btn.pressed.connect(func() -> void: find_lyrics())
	row.add_child(_find_btn)
	_search_btn = SpeakDrill.touch_button("비슷한 곡 찾기", "outline", Pal.PRIMARY)
	_search_btn.name = "BtnSearch"
	_search_btn.disabled = lr_busy or lr_get_calls < 1 or lr_search_calls >= 1
	_search_btn.pressed.connect(func() -> void: search_lyrics())
	row.add_child(_search_btn)
	card.body.add_child(row)
	if lr_message != "":
		var m := SpeakDrill.notice(lr_message, lr_status == "error")
		m.name = "LrMessage"
		card.body.add_child(m)
	if not lr_items.is_empty():
		var g: ListGroup = UI.card("Group") as ListGroup
		g.name = "Candidates"
		var n: int = mini(lr_items.size(), SHOW_ITEMS)
		for i in n:
			var rec: Dictionary = lr_items[i]
			var tx: Dictionary = candidate_text(rec, _file_seconds())
			var chosen: bool = not lr_record.is_empty() and int(rec.get("id", -1)) == int(lr_record.get("id", -2))
			var trailing: Control = UI.chip_kind("선택됨", "ok") if chosen else null
			var tap: Callable = Callable()
			if usable_record(rec):
				var idx: int = i
				tap = func() -> void: choose_candidate(idx)
			g.add_row(str(tx["main"]), str(tx["sub"]), trailing, tap)
		card.body.add_child(g)
	if source == "lrclib" and not lr_record.is_empty():
		_preview_label = UI.label("", "Small")
		_preview_label.name = "LyricsPreview"
		card.body.add_child(_preview_label)
		_update_preview()
		var at := UI.label(ATTRIBUTION, "Small")
		at.name = "Attribution"
		card.body.add_child(at)


func _update_preview() -> void:
	if _preview_label == null or not is_instance_valid(_preview_label):
		return
	_preview_label.text = preview_text()


## 가사 칸 아래 한 줄 요약: "12줄 · 시간 있음" + 자른 안내.
func preview_text() -> String:
	var prep: Dictionary = current_lyrics()
	var n: int = (prep["lines"] as Array).size()
	var t: String = ""
	if n == 0:
		t = "아직 쓸 수 있는 가사가 없어요." if source == "pasted" and pasted_text.strip_edges() != "" else ""
	else:
		t = "%d줄 · %s" % [n, "줄마다 시간이 있어요" if bool(prep["timed"]) else "시간 없음 (PC가 소리에 맞춰요)"]
	for note in (prep["notes"] as Array):
		t += ("\n" if t != "" else "") + str(note)
	return t


func _build_options_card() -> CardBox:
	var card: CardBox = _section("4. 옵션")
	var consent: bool = Store.pref_bool("song_consent")
	var sub: String = "끄면 가사를 AI 서비스로 보내지 않아요"
	if opt_translate and not consent:
		sub = "동의하기 전이라 해석은 만들지 않아요 (AI로 보내지 않아요)"
	elif opt_translate and Backend.is_ready():
		sub = "가사가 AI 서비스(현재: %s)로 전송돼요" % Backend.llm_label()
	var r1: HBoxContainer = UI.switch_row("한국어 해석 만들기", opt_translate, set_translate, sub)
	r1.name = "RowTranslate"
	card.body.add_child(r1)
	if opt_translate:
		var r2: HBoxContainer = UI.switch_row("단어 뜻 만들기", opt_gloss, set_gloss, "해석과 같은 AI 서비스를 써요")
		r2.name = "RowGloss"
		card.body.add_child(r2)
	var prep: Dictionary = current_lyrics()
	if bool(prep["timed"]):
		var r3: HBoxContainer = UI.switch_row("가사 시간 확인하기", opt_verify, set_verify, "곡의 일부를 들어 보고 가사 시간이 소리와 맞는지 확인해요")
		r3.name = "RowVerify"
		card.body.add_child(r3)
	return card


func _render_running(c: VBoxContainer) -> void:
	var card: CardBox = _section("곡을 만드는 중")
	card.name = "RunningCard"
	var shown: String = str(last_progress.get("text", "")) if not last_progress.is_empty() else "시작하는 중"
	_stage_label = UI.label(shown, "Strong")
	_stage_label.name = "StageText"
	card.body.add_child(_stage_label)
	var pct: float = float(last_progress.get("pct", 0.0)) if not last_progress.is_empty() else 0.0
	_bar = UI.progress_bar(pct / 100.0, Pal.PRIMARY, 12.0)
	_bar.name = "ProgressBar"
	card.body.add_child(_bar)
	_pct_label = UI.label("전체 %d%%" % int(round(pct)), "Small")
	_pct_label.name = "PctText"
	card.body.add_child(_pct_label)
	_hint_label = UI.label(_running_hint(), "Muted")
	_hint_label.name = "RunHint"
	card.body.add_child(_hint_label)
	for note in run_notes:
		card.body.add_child(UI.label(str(note), "Small"))
	c.add_child(card)


func _render_failed(c: VBoxContainer) -> void:
	var msg: String = str(last_result.get("message", ""))
	if msg == "":
		msg = SongTransfer.message_for(str(last_result.get("err_code", "")))
	var card: CardBox = _section("곡을 만들지 못했어요")
	card.name = "FailedCard"
	var m := SpeakDrill.notice(msg)
	m.name = "FailMessage"
	card.body.add_child(m)
	for w in (last_result.get("warnings", []) as Array):
		if MSG_WARN.has(str(w)):
			card.body.add_child(UI.label(str(MSG_WARN[str(w)]), "Small"))
	var row := UI.flow(10, 8)
	if bool(last_result.get("resumable", false)):
		var rec: Dictionary = _pending_for(str(last_result.get("job", "")))
		if not rec.is_empty():
			var go := SpeakDrill.touch_button("이어 받기", "primary", Pal.PRIMARY)
			go.name = "BtnResume"
			go.pressed.connect(func() -> void: resume_pending(rec))
			row.add_child(go)
	elif str(last_result.get("upload_id", "")) != "" and str(last_result.get("err_code", "")) == "transport" and not file.is_empty():
		var up := SpeakDrill.touch_button("이어서 올리기", "primary", Pal.PRIMARY)
		up.name = "BtnContinue"
		up.pressed.connect(continue_upload)
		row.add_child(up)
	var back := SpeakDrill.touch_button("처음으로", "outline", Pal.INK)
	back.name = "BtnBackToForm"
	back.pressed.connect(back_to_form)
	row.add_child(back)
	card.body.add_child(row)
	c.add_child(card)


func _pending_for(job: String) -> Dictionary:
	for r in SongStore.pending_list():
		if str((r as Dictionary).get("job", "")) == job:
			return r
	return {}


func _render_done(c: VBoxContainer) -> void:
	var card: CardBox = _section("곡을 추가했어요")
	card.name = "DoneCard"
	card.body.add_child(UI.label("곡이 이 기기에 저장됐어요. 가사 확인 화면에서 줄을 들어 보고 고친 뒤 공부를 시작해 보세요.", "Muted"))
	for w in added_warnings:
		if MSG_WARN.has(str(w)):
			card.body.add_child(UI.label(str(MSG_WARN[str(w)]), "Small"))
	c.add_child(card)


func _render_footer() -> void:
	var fcol: ColumnBox = _shell["footer_col"]
	UI.clear(fcol.content)
	var holder: PanelContainer = _shell["footer_holder"]
	if phase == "form":
		_err_label = UI.colored(make_error, Pal.BAD_ON)
		_err_label.name = "MakeError"
		_err_label.visible = make_error != ""
		fcol.content.add_child(_err_label)
		_make_btn = SpeakDrill.touch_button("곡 만들기", "primary", Pal.PRIMARY)
		_make_btn.name = "BtnMake"
		_make_btn.disabled = transfer != null and transfer.busy
		_make_btn.pressed.connect(func() -> void: make())
		fcol.content.add_child(_make_btn)
		holder.visible = true
	elif phase == "running":
		_cancel_btn = SpeakDrill.touch_button("취소", "outline", Pal.INK)
		_cancel_btn.name = "BtnCancel"
		_cancel_btn.pressed.connect(cancel_transfer)
		fcol.content.add_child(_cancel_btn)
		holder.visible = true
	else:
		holder.visible = false
