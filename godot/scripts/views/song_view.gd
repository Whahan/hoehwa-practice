class_name SongView
extends AppView
## 노래 (곡 목록 화면): 노래로 영어·일본어 공부 (docs/song_study_design.md §4.3, §5.3, §5.6, §6.1, U1).
##
## 곡 목록(제목·가수·언어·길이·줄 수), 빈 상태, 사용량("곡 3개 · 12 MB / 400 MB"), 곡 삭제(확인 시트), 깨진 곡 정리,
## 첫 곡 추가 때의 동의 시트(L9), PC 에 연결되지 않았을 때의 안내.
##
## 화면 연결(U5, 설계 4.3): 이 화면이 허브다 (PracticeView 와 같은 모양, 한 번에 하위 화면 하나).
##   [+ 곡 추가] -> SongAddScreen (song_added(id)) -> SongCheckScreen (saved -> closed) -> SongStudyScreen (closed)
##   곡 탭 -> SongStudyScreen ; 학습 화면 ⋯ 메뉴: 가사 확인·수정 (SongCheckScreen, 닫으면 학습 화면으로), 곡 삭제, 곡 정보
## 가사 외우기(M7, docs/lyrics_memorize_design.md §4, §8 M7):
##   [가사만 추가] -> (처음이면 동의 시트) -> SongLyricsAddScreen (PC 없어도 됨, song_added(id)) -> SongMemoScreen (closed -> 목록)
##   곡 탭: kind "lyrics" -> SongMemoScreen, 음원 곡 -> SongStudyScreen ; 학습 화면 ⋯ 메뉴 "가사 외우기" (memo_requested(id)) -> SongMemoScreen (closed -> 목록)
##   목록 행의 "외운 줄 N/M" 은 SongStore.memo_summary 를 목록 스레드 안에서 읽는다 (화면 스레드는 파일을 읽지 않는다).
## 화면을 닫을 때는 on_hide() -> remove_child -> queue_free 로 해제한다 (Song 버스·녹음·요청이 그 자리에서 정리된다).
## 안드로이드 뒤로 가기: 시트가 열려 있으면 시트 먼저(main.gd 가 Sheet.handle_back 을 먼저 부르고, go_back 도 같은 순서를 지킨다), 그다음 화면.
## 화면을 여는 것과 같은 신호도 그대로 낸다 (시험 · 다른 연결용):
##   add_requested                      [+ 곡 추가] 를 눌렀고 추가해도 되는 상태(PC 연결, 동의함)
##   lyrics_add_requested               [가사만 추가] 를 눌렀고 동의함 (PC 연결은 필요 없다)
##   song_open_requested(song_id)       곡을 눌렀다 (음원 곡은 학습 화면, 가사만 곡은 외우기 화면. 오디오가 깨진 음원 곡은 제외)
## host_screens == false 이면 화면을 직접 열지 않는다 (신호만). 그때 신호에 연결된 곳이 없으면 "준비 중" 안내만 한다.
##
## SongStore.list() 는 처음 부를 때 오디오 sha256 을 최대 400 MiB 계산하므로 느리다 → 다른 스레드에서 부르고(use_thread),
## 그동안 화면은 "불러오는 중" 을 보이며 계속 움직인다. 스레드를 못 쓰면 두 프레임 뒤에 부른다(화면을 먼저 그린다).
## 시험은 SongStore.root 를 user://test_* 로 바꾸고, `loader` 로 느린 목록을 흉내 낸다.

signal add_requested
signal lyrics_add_requested
signal song_open_requested(song_id: String)

const NAME_KO := {"en": "영어", "ja": "일본어"}
const CONSENT_PREF := "song_consent"
const TITLE_MAX := 60 ## 목록에 보이는 제목·가수 길이 (넘으면 …). LRCLIB 결과는 길이 제한이 없다 (후속 메모 U(화면)).
const ARTIST_MAX := 40
const MSG_NO_PC_PHONE := "곡 추가는 PC 연결 시 가능해요. 휴대폰에 Tailscale을 켜고 PC에 연결해 주세요. 저장된 곡은 지금도 공부할 수 있어요."
const MSG_NO_PC_PC := "곡 추가는 PC 연결 시 가능해요. AI 엔진이 준비될 때까지 기다려 주세요. 저장된 곡은 지금도 공부할 수 있어요."
const MSG_OLD_PC := "PC 프로그램을 최신으로 업데이트해 주세요. 지금 연결된 PC에는 곡 추가 기능이 없어요. 저장된 곡은 지금도 공부할 수 있어요."
const MSG_FULL := "저장 공간이 가득 찼어요 (곡 %d개 · %s). 곡을 지운 뒤에 추가해 주세요."
const MSG_MISSING_AUDIO := "오디오 파일이 없어요 — 삭제 후 다시 추가해 주세요"
const MSG_LYRICS_ONLY := "가사만"
const MSG_SAVED_HERE := "곡과 가사는 이 기기에만 저장돼요. 동기화와 백업에는 들어가지 않아요."

## 시험에서 바꾸는 값
var loader: Callable = Callable() ## () -> {"list","orphans","usage","quarantined","memo"(선택: id -> memo_summary)}; 비어 있으면 SongStore. 스레드에서 불린다.
var use_thread: bool = true

var host_screens: bool = true ## false: 신호만 내고 하위 화면은 열지 않는다 (시험)
var screen: Control = null ## 열려 있는 하위 화면 (SongAddScreen | SongCheckScreen | SongStudyScreen | SongLyricsAddScreen | SongMemoScreen), 없으면 null
var screen_kind: String = "" ## "add" | "check" | "study" | "lyrics_add" | "memo"

var state: String = "idle" ## idle | loading | ready | error
var songs: Array = [] ## SongStore.list() 항목
var orphans: Array = [] ## 복구할 수 없는 곡 id
var memos: Dictionary = {} ## 가사만 곡 id -> SongStore.memo_summary (목록 스레드가 읽은 것)
var usage: Dictionary = {}
var load_count: int = 0 ## 목록 읽기를 끝낸 횟수 (시험용)
var last_sheet: Sheet = null ## 마지막으로 연 시트 (시험용)

var _page: PageScroll
var _header: Control = null
var _add_btn: Button = null
var _lyrics_btn: Button = null
var _notice_box: VBoxContainer
var _body: VBoxContainer
var _thread: Thread = null
var _defer_frames: int = 0
var _reload_pending: bool = false
var _loaded_once: bool = false
var _consent_next: String = "add" ## 동의 시트 뒤에 할 일: "add" | "lyrics"
var _check_from: String = "" ## 가사 확인 화면을 연 곳: "add" (곡 추가 직후) | "study" (⋯ 메뉴)
var _rows: Dictionary = {} ## id -> row Control
var _del_btns: Dictionary = {} ## id -> Button
var _cleanup_btn: Button = null
var _usage_label: Label = null
var _notice_label: Label = null


func _ready() -> void:
	var phone: bool = Platform.is_phone()
	_page = PageScroll.new(720.0)
	_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_page)
	var c: VBoxContainer = _page.content
	var actions: Array = []
	if not phone: # PC: the actions sit in the title row; the phone has full-width buttons under it
		actions = [
			{"id": "add", "text": "+ 곡 추가", "cb": Callable(self, "request_add")},
			{"id": "lyrics", "text": "가사만 추가", "cb": Callable(self, "request_add_lyrics")},
		]
	_header = PageHeader.build("노래", "내 음악과 가사로 영어·일본어를 공부해요", actions)
	c.add_child(_header)
	if phone:
		_add_btn = UI.button("+ 곡 추가", "primary", Pal.PRIMARY, 56.0)
		_add_btn.pressed.connect(request_add)
		c.add_child(_add_btn)
		_lyrics_btn = UI.button("가사만 추가", "soft", Pal.PRIMARY, 56.0)
		_lyrics_btn.pressed.connect(request_add_lyrics)
		c.add_child(_lyrics_btn)
	else:
		var hb: Dictionary = _header.get_meta("action_buttons", {})
		_add_btn = hb.get("add", null)
		_lyrics_btn = hb.get("lyrics", null)
	_notice_box = UI.vbox(0)
	c.add_child(_notice_box)
	_body = UI.vbox(12)
	c.add_child(_body)
	Backend.status_changed.connect(_render_notice)
	Route.mode_changed.connect(_on_route_mode)
	set_process(false)
	_render_notice()
	_render_body()


func refresh() -> void:
	_render_notice()
	if screen != null:
		return # 하위 화면이 SongStore 를 쓰는 동안 목록 스레드를 돌리지 않는다. 화면을 닫을 때 다시 읽는다
	_start_load()


## 탭을 떠날 때: 열려 있는 화면의 소리·녹음을 멈춘다 (화면은 그대로 둔다).
func on_hide() -> void:
	if screen != null and is_instance_valid(screen) and screen.has_method("on_hide"):
		screen.call("on_hide")


func scroll_host() -> ScrollContainer:
	return _page if screen == null else null


func header_block() -> Control:
	return _header if screen == null and _header != null and is_instance_valid(_header) else null


# ---------------------------------------------------------------- app bar contract (AppView): an open sub screen gives its own title

func page_title() -> String:
	if screen != null and is_instance_valid(screen):
		var sh: Variant = screen.get("_shell")
		if sh is Dictionary and (sh as Dictionary).get("title", null) is Label:
			return ((sh as Dictionary)["title"] as Label).text
	return ""


func page_subtitle() -> String:
	if screen != null and is_instance_valid(screen):
		var sh: Variant = screen.get("_shell")
		if sh is Dictionary and (sh as Dictionary).get("count", null) is Label:
			return ((sh as Dictionary)["count"] as Label).text
	return ""


## 안드로이드 뒤로 가기: 열린 시트가 먼저, 그다음 하위 화면 한 단계 (처리했으면 true). 목록이면 false.
func go_back() -> bool:
	if screen == null:
		return false
	if Sheet.handle_back():
		return true
	if screen.has_method("go_back") and bool(screen.call("go_back")):
		return true
	_close_screen()
	return true


func _exit_tree() -> void:
	if screen != null and is_instance_valid(screen):
		_unmount() # on_hide + remove_child: the song player gives its audio (and the Song bus) back right here
	if _thread != null:
		_thread.wait_to_finish() # the list call cannot be stopped; wait for it so the thread is never left running
		_thread = null


func _on_route_mode(_m: String) -> void:
	_render_notice()


# ---------------------------------------------------------------- formatting (static, tested)

## At most `n` characters; a longer text ends with "…". Control characters and line breaks become spaces.
static func clip(s: String, n: int) -> String:
	var t: String = ""
	for i in mini(s.length(), n * 4 + 4): # a 2 million character title never gets walked completely
		var code: int = s.unicode_at(i)
		t += " " if code < 32 or code == 127 else s[i]
	t = t.strip_edges()
	if t.length() > n:
		return t.substr(0, maxi(1, n - 1)).strip_edges() + "…"
	return t


## 231.4 -> "3:51"
static func fmt_dur(sec: float) -> String:
	var s: int = int(roundf(maxf(0.0, sec if is_finite(sec) else 0.0)))
	return "%d:%02d" % [s / 60, s % 60]


## 3.8 MB / 12 MB / 400 MB ; below 1 MB "820 KB"
static func fmt_bytes(n: int) -> String:
	var b: float = float(maxi(0, n))
	if b < 1024.0 * 1024.0:
		return "%d KB" % int(ceilf(b / 1024.0)) if b > 0.0 else "0 KB"
	var mb: float = b / (1024.0 * 1024.0)
	return ("%.1f MB" % mb) if mb < 10.0 else ("%d MB" % int(roundf(mb)))


## "곡 3개 · 12 MB / 400 MB"
static func usage_text(u: Dictionary) -> String:
	return "곡 %d개 · %s / %s" % [int(u.get("songs", 0)), fmt_bytes(int(u.get("bytes", 0))), fmt_bytes(int(u.get("max_bytes", SongStore.MAX_BYTES)))]


## 동의 시트의 본문 (설계 L9 + 12.1a Q3): 문단은 빈 줄로 나뉜다.
static func consent_text() -> String:
	var ready: bool = Backend.is_ready()
	var ai: String = Backend.llm_label() if ready else "PC에서 정한 AI 엔진"
	var t: String = "내가 가진 음악과 가사를 이 기기에서 공부하는 데만 써요. 가사와 음악은 앱에 들어 있지 않고, 다른 곳에 올리거나 공유할 수 없어요."
	t += "\n\n가사 찾기는 lrclib.net에 곡 제목·가수·길이를 보내요. 버튼을 누를 때만 보내요."
	t += "\n\n해석을 만들 때 가사가 AI 서비스(현재: %s)로 전송돼요. 곡마다 해석 만들기를 끌 수 있어요." % ai
	if ready and Backend.llm_provider() == "ollama":
		t += "\n\n지금은 오프라인 로컬 AI(Ollama)를 쓰고 있어서 가사가 밖으로 나가지 않아요."
	return t


# ---------------------------------------------------------------- can the person add a song?

## "" = yes. "no_pc" (no PC / engine, or phone-only mode), "old_pc" (the PC program has no song feature), "full" (40 songs / 400 MiB).
func add_block_reason() -> String:
	if Route.decide("POST", "/song/jobs") == "none" or not Backend.is_ready():
		return "no_pc"
	if not bool(Backend.health.get("song", false)):
		return "old_pc"
	if not usage.is_empty() and (int(usage.get("songs", 0)) >= int(usage.get("max_songs", SongStore.MAX_SONGS)) \
			or int(usage.get("bytes", 0)) >= int(usage.get("max_bytes", SongStore.MAX_BYTES))):
		return "full"
	return ""


func notice_text() -> String:
	match add_block_reason():
		"no_pc":
			return MSG_NO_PC_PHONE if Platform.is_phone() else MSG_NO_PC_PC
		"old_pc":
			return MSG_OLD_PC
		"full":
			return MSG_FULL % [int(usage.get("songs", 0)), fmt_bytes(int(usage.get("bytes", 0)))]
	return ""


## [+ 곡 추가]: 안내(PC 없음) → 동의 시트(처음 한 번) → add_requested.
func request_add() -> void:
	var t: String = notice_text()
	if t != "":
		Toast.info(t)
		return
	if not Store.pref_bool(CONSENT_PREF):
		show_consent()
		return
	_go_add()


## [가사만 추가]: PC 가 없어도 된다. 동의 시트(처음 한 번) -> lyrics_add_requested -> SongLyricsAddScreen.
func request_add_lyrics() -> void:
	if not Store.pref_bool(CONSENT_PREF):
		show_consent("lyrics")
		return
	_go_lyrics()


func show_consent(next: String = "add") -> void:
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	_consent_next = next
	var body := UI.vbox(10)
	for para in consent_text().split("\n\n"):
		body.add_child(UI.label(para))
	last_sheet = Sheet.open(self, "노래 공부를 시작하기 전에", body, [
		{"id": "agree", "text": "동의하고 시작", "kind": "primary"},
		{"id": "cancel", "text": "취소", "kind": "flat"},
	], {"max_h_frac": 0.85})
	last_sheet.closed.connect(_on_consent_closed)


func _on_consent_closed(result: Variant) -> void:
	if str(result) != "agree":
		return # "취소" or a dismissed sheet: nothing is saved, the add screen stays closed
	Store.set_pref(CONSENT_PREF, true)
	if _consent_next == "lyrics":
		_go_lyrics()
	else:
		_go_add()


func _go_add() -> void:
	add_requested.emit()
	if host_screens:
		open_screen("add", {"lang": Store.lang()})


func _go_lyrics() -> void:
	lyrics_add_requested.emit()
	if host_screens:
		open_screen("lyrics_add", {"lang": Store.lang()})


# ---------------------------------------------------------------- loading the list

func _default_load() -> Dictionary:
	if SongStore.blocked(): # a test run must not look into the real songs folder (and must not log an error either)
		return {"list": [], "orphans": [], "usage": {"songs": 0, "bytes": 0, "max_songs": SongStore.max_songs, "max_bytes": SongStore.max_bytes}, "quarantined": [], "memo": {}}
	var l: Array = SongStore.list()
	var q: Array = SongStore.take_quarantined()
	var memo: Dictionary = {}
	var now: int = int(Time.get_unix_time_from_system())
	for s in l: # read-only, never moves a file: safe in this thread
		if str((s as Dictionary).get("kind", "audio")) == "lyrics":
			var sid: String = str((s as Dictionary)["id"])
			memo[sid] = SongStore.memo_summary(sid, now)
	return {"list": l, "orphans": SongStore.orphan_ids(), "usage": SongStore.usage(), "quarantined": q, "memo": memo}


func is_loading() -> bool:
	return _thread != null or _defer_frames > 0


func _start_load() -> void:
	if is_loading():
		_reload_pending = true
		return
	_reload_pending = false
	if not _loaded_once:
		state = "loading"
		_render_body()
	var ld: Callable = loader if loader.is_valid() else Callable(self, "_default_load")
	if use_thread:
		var th := Thread.new()
		if th.start(ld) == OK:
			_thread = th
			set_process(true)
			return
	_defer_frames = 2 # the screen is drawn first, then the list is read
	set_process(true)


func _process(_delta: float) -> void:
	if _thread != null:
		if _thread.is_alive():
			return
		var res: Variant = _thread.wait_to_finish()
		_thread = null
		_finish_load(res)
	elif _defer_frames > 0:
		_defer_frames -= 1
		if _defer_frames == 0:
			var ld: Callable = loader if loader.is_valid() else Callable(self, "_default_load")
			_finish_load(ld.call())
	if _thread == null and _defer_frames == 0:
		set_process(false)


func _finish_load(res: Variant) -> void:
	load_count += 1
	var quarantined: Array = []
	if res is Dictionary and (res as Dictionary).get("list", null) is Array:
		var r: Dictionary = res
		songs = []
		for s in r["list"]:
			if s is Dictionary and SongModel.is_valid_id(str((s as Dictionary).get("id", ""))):
				songs.append(s)
		orphans = []
		if r.get("orphans", null) is Array:
			for o in r["orphans"]:
				if SongModel.is_valid_id(o):
					orphans.append(str(o))
		usage = (r["usage"] as Dictionary).duplicate() if r.get("usage", null) is Dictionary else {"songs": songs.size(), "bytes": 0, "max_songs": SongStore.MAX_SONGS, "max_bytes": SongStore.MAX_BYTES}
		memos = {}
		if r.get("memo", null) is Dictionary:
			for k in (r["memo"] as Dictionary):
				var v: Variant = (r["memo"] as Dictionary)[k]
				if SongModel.is_valid_id(str(k)) and v is Dictionary and not (v as Dictionary).is_empty():
					memos[str(k)] = v
		if r.get("quarantined", null) is Array:
			quarantined = r["quarantined"]
		state = "ready"
		_loaded_once = true
	else:
		state = "error"
	_render_notice()
	_render_body()
	if not quarantined.is_empty():
		Toast.error("곡 %d개의 정보 파일이 깨져 목록에서 뺐어요. 아래 '정리할 곡'에서 지울 수 있어요." % quarantined.size())
	if _reload_pending:
		_start_load()


# ---------------------------------------------------------------- drawing

func _render_notice() -> void:
	if _notice_box == null:
		return
	UI.clear(_notice_box)
	_notice_label = null
	var t: String = notice_text()
	if t == "":
		return
	var p := UI.tinted_panel(Pal.WARN_SOFT, Color(0, 0, 0, 0), 0, Ds.R_S, 14, 12)
	var row := UI.hbox(6)
	var mark := UI.label("! ", "Strong", false) # the bold mark says "warning" without the colour
	mark.add_theme_color_override("font_color", Pal.WARN_ON)
	mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(mark)
	_notice_label = UI.colored(t, Pal.WARN_ON, "")
	_notice_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_notice_label)
	p.add_child(row)
	_notice_box.add_child(p)
	_notice_box.add_child(UI.gap(12))


func _render_body() -> void:
	if _body == null:
		return
	UI.clear(_body)
	_rows.clear()
	_del_btns.clear()
	_cleanup_btn = null
	_usage_label = null
	match state:
		"ready":
			_render_ready()
		"error":
			var card := UI.card("Card", 10)
			card.add(UI.label("곡 목록을 불러오지 못했어요", "H3"))
			card.add(UI.label("잠시 뒤에 다시 시도해 주세요. 곡 파일은 그대로 있어요.", "Muted"))
			var retry := UI.button("다시 시도", "soft", Pal.PRIMARY)
			retry.pressed.connect(_start_load)
			card.add(retry)
			_body.add_child(card)
		_:
			var card2 := UI.card("Card", 10)
			card2.add(UI.label("곡을 불러오는 중…", "H3"))
			card2.add(UI.progress_indeterminate(Pal.PRIMARY))
			_body.add_child(card2)
	UI.fix_cjk(_body)


func _render_ready() -> void:
	if songs.is_empty():
		var card := UI.card("BigCard", 10)
		card.add(UI.label("아직 곡이 없어요", "H2"))
		card.add(UI.label("내 음악 파일과 가사로 영어·일본어를 공부해요. 한 줄씩 듣고, 따라 부르고, 단어와 빈칸 문제로 복습해요.", "Muted"))
		card.add(UI.label("가사와 음악은 앱에 들어 있지 않아요. 내가 가진 파일만 쓰고, 이 기기에만 저장돼요.", "Muted"))
		_body.add_child(card)
	else:
		_body.add_child(UI.section_header("내 곡", Ds.S2))
		var list := UI.card("Group") as ListGroup
		for s in songs:
			_song_row(list, s)
		_body.add_child(list)
	if not orphans.is_empty():
		_body.add_child(UI.section_header("정리할 곡", Ds.S2))
		var g := UI.card("Group") as ListGroup
		_cleanup_btn = UI.button("정리", "soft", Pal.BAD)
		_cleanup_btn.accessibility_name = "복구할 수 없는 곡 정리"
		_cleanup_btn.pressed.connect(request_cleanup)
		g.add_row("복구할 수 없는 곡 %d개" % orphans.size(), "파일이 깨져 열 수 없어요. 정리하면 차지한 공간이 비워져요.", _cleanup_btn)
		_body.add_child(g)
	_usage_label = UI.label(usage_text(usage), "Muted")
	_body.add_child(UI.margin(_usage_label, Ds.S2, 4, Ds.S2, 0))
	_body.add_child(UI.margin(UI.label(MSG_SAVED_HERE, "Small"), Ds.S2, 0, Ds.S2, 0))


## "외운 줄 3/12" (SongStore.memo_summary 의 memorized/total). 읽지 못한 곡은 "".
func memo_text(id: String) -> String:
	var m: Variant = memos.get(id, null)
	if not (m is Dictionary):
		return ""
	return "외운 줄 %d/%d" % [int((m as Dictionary).get("memorized", 0)), int((m as Dictionary).get("total", 0))]


## 곡 목록 항목의 종류: "lyrics" | "audio" ("" = 목록에 없음).
func song_kind(id: String) -> String:
	for s in songs:
		if str((s as Dictionary).get("id", "")) == id:
			return "lyrics" if str((s as Dictionary).get("kind", "audio")) == "lyrics" else "audio"
	return ""


func _song_row(list: ListGroup, s: Dictionary) -> void:
	var id: String = str(s["id"])
	var title: String = clip(str(s.get("title", "")), TITLE_MAX)
	if title == "":
		title = "(제목 없음)"
	var is_ready: bool = bool(s.get("ready", true))
	var lyrics_only: bool = str(s.get("kind", "audio")) == "lyrics"
	var parts: Array = []
	var artist: String = clip(str(s.get("artist", "")), ARTIST_MAX)
	if artist != "":
		parts.append(artist)
	parts.append(str(NAME_KO.get(str(s.get("lang", "")), "")))
	if not lyrics_only: # a lyrics-only song has no length
		parts.append(fmt_dur(float(s.get("duration", 0.0))))
	parts.append("%d줄" % int(s.get("lines", 0)))
	if lyrics_only:
		parts.append(MSG_LYRICS_ONLY)
		parts.append(memo_text(id))
		if bool(s.get("read_only", false)):
			parts.append("읽기 전용")
	elif not is_ready:
		parts.append("오디오 없음")
	elif bool(s.get("read_only", false)):
		parts.append("읽기 전용")
	elif (s.get("warnings", []) as Array).has("low_match"):
		parts.append("시간 확인 필요")
	parts = parts.filter(func(p: Variant) -> bool: return str(p) != "")
	var del := UI.button("삭제", "soft", Pal.BAD)
	del.accessibility_name = "곡 삭제: " + title
	del.pressed.connect(request_delete.bind(id))
	var row: Control = list.add_row(title, " · ".join(parts), del, _on_song_tap.bind(id, is_ready))
	if row != null:
		for l in row.find_children("*", "Label", true, false):
			if (l as Label).theme_type_variation == &"ListSub":
				(l as Label).max_lines_visible = 1 # a long artist / title never makes the row tall
				(l as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_rows[id] = row
	_del_btns[id] = del


# ---------------------------------------------------------------- sub screens (hub)

const MSG_LOADING := "곡 목록을 읽는 중이에요. 잠시 뒤에 다시 눌러 주세요."

## kind: "add" {lang} | "check" {id} | "study" {id, tab} | "lyrics_add" {lang} | "memo" {id}. 하나만 열린다 (열려 있으면 먼저 닫는다). 열었으면 true.
## 목록을 읽는 동안에는 열지 않는다 (SongStore 를 두 곳에서 쓰지 않는다).
func open_screen(kind: String, args: Dictionary = {}) -> bool:
	if not host_screens:
		return false
	if is_loading():
		Toast.info(MSG_LOADING)
		return false
	var s: Control = _make_screen(kind)
	if s == null:
		return false
	if screen != null:
		_unmount()
	screen = s
	screen_kind = kind
	s.connect("closed", _on_screen_closed.bind(s))
	match kind:
		"add":
			s.connect("song_added", _on_song_added)
		"study":
			s.connect("check_requested", _on_check_requested)
			s.connect("memo_requested", _on_memo_requested)
		"lyrics_add":
			s.connect("song_added", _on_lyrics_added)
	_page.visible = false
	add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.call("open", str(args.get("lang", Store.lang())), args)
	bar_changed.emit()
	return true


func _make_screen(kind: String) -> Control:
	match kind:
		"add":
			return SongAddScreen.new()
		"check":
			return SongCheckScreen.new()
		"study":
			return SongStudyScreen.new()
		"lyrics_add":
			return SongLyricsAddScreen.new()
		"memo":
			return SongMemoScreen.new()
	return null


## on_hide, tree 에서 떼고, 해제한다 (queue_free). 곧바로 _exit_tree 가 불려 Song 버스·녹음·요청이 정리된다.
func _unmount() -> void:
	var s: Control = screen
	screen = null
	screen_kind = ""
	if s == null or not is_instance_valid(s):
		return
	if s.has_method("on_hide"):
		s.call("on_hide")
	if s.get_parent() == self:
		remove_child(s)
	s.queue_free()


## 목록으로 돌아간다: 화면을 해제하고 목록을 다시 읽는다 (곡 수·사용량이 바뀌었을 수 있다).
func _close_screen() -> void:
	if screen == null:
		return
	_unmount()
	_check_from = ""
	if _page != null:
		_page.visible = true
	_start_load()
	bar_changed.emit()


func _on_screen_closed(s: Control) -> void:
	if s != screen: # an old screen that was already replaced
		return
	if screen_kind == "check":
		var res: String = str(s.get("result"))
		var sid: String = str(s.get("song_id"))
		var from: String = _check_from
		if SongModel.is_valid_id(sid) and (res == "saved" or from == "study"):
			# saved -> study; a check opened from the study ⋯ menu always returns to the study screen
			_check_from = ""
			if open_screen("study", {"id": sid}):
				return
	_close_screen()


func _on_song_added(id: String) -> void:
	_on_added_deferred.call_deferred(id, screen)


func _on_added_deferred(id: String, from_screen: Control) -> void:
	if from_screen != screen or not is_instance_valid(from_screen): # the person left the add screen first
		return
	var warns: Array = []
	var w: Variant = from_screen.get("added_warnings")
	if w is Array:
		warns = (w as Array).duplicate()
	_check_from = "add"
	if not open_screen("check", {"id": id}):
		_close_screen()
		return
	# the check screen only explains timing doubts: tell the person about the other things the PC could not make
	var notes: Array = []
	for k in ["ko_missing", "gloss_missing", "lyrics_truncated"]:
		if warns.has(k) and SongAddScreen.MSG_WARN.has(k):
			notes.append(str(SongAddScreen.MSG_WARN[k]))
	if not notes.is_empty():
		Toast.info(" ".join(notes))


func _on_check_requested(id: String) -> void:
	_open_check_deferred.call_deferred(id, screen)


func _open_check_deferred(id: String, from_screen: Control) -> void:
	if from_screen != screen or not is_instance_valid(from_screen):
		return
	_check_from = "study"
	if not open_screen("check", {"id": id}):
		_check_from = ""
		_close_screen()


## 가사만 곡을 저장했다 -> 외우기 화면으로 (화면을 바꾸는 일은 신호가 끝난 뒤에).
func _on_lyrics_added(id: String) -> void:
	_open_memo_deferred.call_deferred(id, screen)


## 학습 화면 ⋯ 메뉴 "가사 외우기": 같은 곡을 외우기 화면으로 연다. 닫으면 목록으로 돌아간다.
func _on_memo_requested(id: String) -> void:
	_open_memo_deferred.call_deferred(id, screen)


func _open_memo_deferred(id: String, from_screen: Control) -> void:
	if from_screen != screen or not is_instance_valid(from_screen): # the person left that screen first
		return
	if not open_screen("memo", {"id": id}):
		_close_screen()


# ---------------------------------------------------------------- actions

func _on_song_tap(id: String, is_ready: bool) -> void:
	if not is_ready:
		Toast.error(MSG_MISSING_AUDIO)
		return
	song_open_requested.emit(id)
	if host_screens:
		open_screen("memo" if song_kind(id) == "lyrics" else "study", {"id": id})
	elif song_open_requested.get_connections().is_empty():
		Toast.info("곡 학습 화면은 아직 준비 중이에요")


func song_title(id: String) -> String:
	for s in songs:
		if str((s as Dictionary).get("id", "")) == id:
			var t: String = clip(str((s as Dictionary).get("title", "")), 40)
			return t if t != "" else "(제목 없음)"
	return ""


## 삭제 확인 문구: 가사만 곡은 외우기 기록도 함께 지워진다고 알린다 (음원 곡은 U1 문구 그대로).
func delete_text(id: String) -> String:
	if song_kind(id) == "lyrics":
		return "'%s'의 가사와 외우기 기록이 이 기기에서 지워져요. 되돌릴 수 없어요. 복습 카드는 그대로 남아요." % song_title(id)
	return "'%s'의 음악과 가사, 이 곡의 학습 기록이 이 기기에서 지워져요. 되돌릴 수 없어요. 복습 카드는 그대로 남아요." % song_title(id)


## Delete: a confirm sheet first. The sheet's "ok" removes the folder (SongStore.delete) and reloads the list.
func request_delete(id: String) -> void:
	if not SongModel.is_valid_id(id) or is_loading():
		return
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	last_sheet = Sheet.confirm(self, "곡을 지울까요?", delete_text(id), "삭제", true)
	last_sheet.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			delete_now(id))


func delete_now(id: String) -> void:
	if is_loading(): # the list thread is using SongStore's caches; never touch the store from two threads
		return
	if not SongModel.is_valid_id(id):
		return
	if SongStore.delete(id):
		Toast.ok("곡을 지웠어요")
	else:
		Toast.error("곡을 지우지 못했어요. 파일이 다른 곳에서 열려 있는지 확인해 주세요.")
	_start_load()


## Clean up the folders of songs that cannot be opened any more (broken song.json moved to .bad).
func request_cleanup() -> void:
	if orphans.is_empty() or is_loading():
		return
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	last_sheet = Sheet.confirm(self, "깨진 곡을 정리할까요?",
		"열 수 없는 곡 %d개의 파일을 이 기기에서 지워요. 되돌릴 수 없어요." % orphans.size(), "정리", true)
	last_sheet.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			cleanup_now())


func cleanup_now() -> void:
	if is_loading(): # see delete_now
		return
	var n: int = 0
	var bad: int = 0
	for id in orphans.duplicate():
		if SongStore.delete(str(id)):
			n += 1
		else:
			bad += 1
	if bad == 0:
		Toast.ok("깨진 곡 %d개를 정리했어요" % n)
	else:
		Toast.error("깨진 곡 %d개를 정리했고, %d개는 지우지 못했어요" % [n, bad])
	_start_load()


# ---------------------------------------------------------------- handles for tests

func add_button() -> Button:
	return _add_btn


func lyrics_button() -> Button:
	return _lyrics_btn


func row_for(id: String) -> Control:
	return _rows.get(id, null)


func delete_button(id: String) -> Button:
	return _del_btns.get(id, null)


func cleanup_button() -> Button:
	return _cleanup_btn


func usage_label() -> Label:
	return _usage_label


func notice_label() -> Label:
	return _notice_label
