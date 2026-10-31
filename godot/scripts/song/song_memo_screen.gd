class_name SongMemoScreen
extends Control
## 가사 외우기 M5: 곡 하나를 외우는 화면 (집 화면 · 세션 진행 · 요약 · 설정 칩 · 줄 목록 · 가사 고치기 · 진도 초기화 · 해석 칸).
## 설계 docs/lyrics_memorize_design.md §4 §5.4 §5.6 §5.7 §8 M5 §12.1b. 허브 계약은 SongStudyScreen 과 같다:
## `closed` 신호, `open(lang, args)`, `on_hide()`, `go_back() -> bool`, `_shell`(앱 바가 제목을 읽는다), `page_title()`.
##
##   var s := SongMemoScreen.new(); parent.add_child(s); s.open("en", {"id": "s_0123456789ab"})   # SongStore 에서 읽는다 (음원 곡·가사만 곡 모두)
##   s.open("en", {"song": song_dict})                                                               # 이미 읽은 곡 (시험용)
##
## 화면 (view): home(집) · session(SongMemoDrill) · summary(요약) · lines(줄 목록) · edit(가사 고치기) · error(곡을 못 열음).
##   집: 외운 줄 N/M · 오늘 복습 K줄 · 오늘 새 줄 J줄 · 다음 복습 · [오늘 외우기] · [5줄 더하기] · 설정 칩 · 줄 목록 · 가사 고치기(음원 없는 곡만)
##       · 진도 초기화 · 해석 칸(SongMeaningTab 재사용).
##   세션: MemoSession.begin(save = SongStore.save_memo, clock 주입) + SongMemoDrill. 드릴의 line_done(counted) 에서만 StudyLog "drill" +1 (줄마다 1번).
##       화면을 떠날 때는 leave_line() 을 먼저 하고(저장이 밀린 줄이 있으면 retry_save) 그 다음에 finish() — 저장이 실패하면 finish 를 부르지 않는다.
##   설정 칩: memo_fast · memo_prev_cue · memo_answer (prefs, 동기화 대상 아님). 다음 세션부터 적용.
##   가사 고치기: 줄 글자를 고치면 그 줄은 새 줄(키가 바뀜), 글자가 같은 줄은 기록 유지. SongStore.save_song 이 실패하면 원본 곡 그대로.
##   진도 초기화: 확인 시트 -> SongStore.delete_memo (가사는 그대로). 복습 탭 카드(Store.progress)는 건드리지 않는다.
##   해석 칸: SongMeaningTab 을 그대로 넣는다 (ai_ok = 동의 AND 곡별 해석 켬, PC 가 있을 때만, 버튼을 눌러야만 요청).
## 이 화면은 SongView 에 연결하지 않는다 (M7 몫). `closed` 만 낸다.

signal closed

const MSG_OPEN_FAIL := "곡을 열 수 없어요. 곡 목록으로 돌아가 다시 열어 보세요."
const MSG_BAD_MEMO := "외우기 기록이 깨져 새로 시작했어요."
const MSG_NEWER_MEMO := "이 기록은 더 새 버전이에요. 연습은 할 수 있지만 기록은 저장하지 않아요."
const MSG_NO_LINES := "외울 줄이 없어요. 가사에 글자가 있는 줄이 있어야 해요."
const MSG_NOTHING := "지금 할 줄이 없어요."
const MSG_LEAVE_FAIL := "저장하지 못해서 아직 나가지 않았어요. 저장 공간을 확인한 뒤 다시 눌러 주세요."
const MSG_LEFT_UNSAVED := "저장하지 못한 채 나왔어요. 끝내지 못한 줄은 다음에 다시 해 주세요."
const MSG_SAVE_STATS := "기록 일부를 저장하지 못했어요. 저장 공간을 확인해 주세요."
const MSG_RESET_OK := "진도를 처음으로 되돌렸어요."
const MSG_RESET_FAIL := "진도를 지우지 못했어요. 파일이 다른 곳에서 열려 있는지 확인해 주세요."
const MSG_EDIT_EMPTY := "가사가 비어 있어요. 글자가 있는 줄을 하나 이상 남겨 주세요."
const MSG_EDIT_LONG := "가사가 너무 길어요. 한 줄 %d자, %d줄, 모두 %d자 안으로 줄여 주세요."
const MSG_EDIT_SAVE_FAIL := "가사를 저장하지 못했어요. 저장 공간을 확인한 뒤 다시 눌러 주세요."
const MSG_EDIT_READONLY := "이 곡은 더 새 버전으로 만들어져서 고칠 수 없어요."
const MSG_EDIT_AUDIO := "음악이 있는 곡은 가사 확인 화면에서 고쳐 주세요."
const BACK_HOME := "← 노래"
const BACK_INNER := "← 집"
const EXTRA_STEP := 5

var lang: String = "en"
var song: Dictionary = {}
var song_id: String = ""
var memo: Dictionary = {}
var view: String = "home" ## home | session | summary | lines | edit | error
var result: String = "back"
var open_error: String = ""
var session: MemoSession = null
var drill: SongMemoDrill = null
var meaning: SongMeaningTab = null
var meaning_open: bool = false
var last_sheet: Sheet = null
var last_summary: Dictionary = {} ## 마지막으로 끝낸 세션의 요약 (시험·화면용)
var drill_events: int = 0 ## 이 화면이 StudyLog 에 낸 "drill" 이벤트 수 (시험 확인용)
var last_edit: Dictionary = {} ## save_edit 의 마지막 결과 {ok, err, notes, changed}

## 시험 전용: Callable() -> int (현재 시각, 초). 없으면 시스템 시계.
var now_fn: Callable = Callable()

var _shell: Dictionary = {}
var _body: VBoxContainer = null
var _notes: Array = []
var _extra: int = 0 ## 집 화면 [5줄 더하기] 로 더한 묶음 수 (세션을 시작하면 0)
var _skip_new: int = 0 ## [이 줄 나중에]로 미룬 새 줄 수 (요약의 [5줄 더]가 건너뛴다)
var _logged: Dictionary = {}
var _leave_fails: int = 0
var _chips: HFlowContainer = null
var _meaning_count: Label = null
var _edit: TextEdit = null
var _edit_orig: String = ""
var _edit_msg_box: VBoxContainer = null
var _gone: bool = false


func _init() -> void:
	name = "SongMemoScreen"
	_shell = SpeakDrill.build_shell(self, go_back, BACK_HOME)
	var page: PageScroll = _shell["page"]
	_body = UI.vbox(12)
	page.content.add_child(_body)


func _exit_tree() -> void:
	_leave_all(true)


# ---------------------------------------------------------------- 허브 계약

## 곡을 열고 집 화면을 그린다. 곡의 언어가 `l` 보다 우선한다.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l if l == "ja" else "en"
	_reset()
	if args.has("song"):
		var raw: Variant = args["song"]
		song = SongModel.normalize(raw) if (raw is Dictionary and not (raw as Dictionary).is_empty()) else {}
	else:
		var sid: String = str(args.get("id", args.get("song_id", "")))
		song = SongStore.load_song(sid) if sid != "" else {}
	if song.is_empty():
		open_error = MSG_OPEN_FAIL
		view = "error"
		_set_header("노래", "")
		_body.add_child(SpeakDrill.notice(open_error))
		return
	song_id = str(song.get("id", ""))
	lang = str(song.get("lang", lang))
	if lang != "ja":
		lang = "en"
	memo = SongStore.load_memo(song_id, song)
	if SongStore.last_error == "bad_memo":
		_notes.append(MSG_BAD_MEMO)
		Toast.info(MSG_BAD_MEMO)
	if MemoModel.is_read_only(memo):
		_notes.append(MSG_NEWER_MEMO)
	_build_footer()
	show_home()


## 다른 곳으로 갈 때: 진행 중인 줄을 저장하고(도달 단계), 녹음·읽어 주기·요청을 멈춘다.
func on_hide() -> void:
	var was: String = view
	_leave_all(false)
	if (was == "session" or was == "summary") and is_inside_tree():
		show_home() # 세션을 끝냈으니 다시 보일 때 낡은 화면이 남지 않게


## 안드로이드 뒤로 가기 / 머리줄 버튼. 세션·요약·줄 목록·고치기에서는 집 화면으로, 집에서는 closed.
func go_back() -> bool:
	match view:
		"session":
			if _end_session(false):
				show_home()
			return true
		"summary", "lines":
			_end_session(true)
			show_home()
			return true
		"edit":
			if _edit_dirty():
				_confirm_discard_edit()
			else:
				show_home()
			return true
	_leave_all(false)
	result = "back"
	closed.emit()
	return true


func page_title() -> String:
	return (_shell["title"] as Label).text


# ---------------------------------------------------------------- 읽기 도우미 (시험도 쓴다)

func attribution_text() -> String:
	var src: Variant = song.get("source", {})
	if not (src is Dictionary):
		return ""
	var a: String = str((src as Dictionary).get("attribution", ""))
	if a != "":
		return a
	return SongStudyScreen.DEFAULT_ATTRIBUTION if str((src as Dictionary).get("lyrics", "")) == "lrclib" else ""


func _now() -> int:
	if now_fn.is_valid():
		var v: Variant = now_fn.call()
		if v is int or v is float:
			return int(v)
	return int(Time.get_unix_time_from_system())


func is_lyrics_song() -> bool:
	return SongModel.is_lyrics(song)


func pref_fast() -> bool:
	var v: Variant = Store.prefs.get("memo_fast", false)
	return v if v is bool else false


func pref_prev_cue() -> bool:
	var v: Variant = Store.prefs.get("memo_prev_cue", true)
	return v if v is bool else true


func pref_answer() -> String:
	var v: Variant = Store.prefs.get("memo_answer", "type")
	return "speak" if (v is String and v == "speak") else "type"


## 집 화면의 숫자. MemoModel.summary + today_new(오늘 새 줄) + today_review(오늘 복습).
func home_stats() -> Dictionary:
	var st: Dictionary = MemoModel.summary(song, memo, _now())
	st["today_new"] = mini(MemoModel.NEW_CAP * (1 + _extra), int(st["fresh"]))
	st["today_review"] = mini(MemoModel.REVIEW_CAP, int(st["due"]))
	return st


## 줄 키의 상태: "new"(새 줄) · "learning"(학습 중) · "memorized"(외움) · "due"(복습 시간).
func line_state(key: String) -> String:
	var c: Dictionary = _card(key)
	if c.is_empty():
		return "new"
	if int(c["due"]) <= _now():
		return "due"
	if int(c["state"]) == FSRS.State.REVIEW:
		return "memorized"
	return "learning"


func _card(key: String) -> Dictionary:
	var ls: Variant = memo.get("lines", {})
	if ls is Dictionary and (ls as Dictionary).get(key, null) is Dictionary:
		var c: Variant = ((ls as Dictionary)[key] as Dictionary).get("card", null)
		if c is Dictionary:
			return c
	return {}


static func state_text(state: String) -> String:
	match state:
		"new":
			return "새 줄"
		"learning":
			return "학습 중"
		"memorized":
			return "외움"
		"due":
			return "복습 시간"
	return ""


static func after_text(secs: int) -> String:
	if secs < 90:
		return "1분"
	if secs < 3600 * 2:
		return "%d분" % roundi(float(secs) / 60.0)
	if secs < 86400 * 2:
		return "%d시간" % roundi(float(secs) / 3600.0)
	return "%d일" % roundi(float(secs) / 86400.0)


# ---------------------------------------------------------------- 설정 칩 (prefs)

func set_fast(on: bool) -> void:
	if Store.prefs.get("memo_fast", null) != on:
		Store.set_pref("memo_fast", on)
	_rebuild_chips()


func set_prev_cue(on: bool) -> void:
	if Store.prefs.get("memo_prev_cue", null) != on:
		Store.set_pref("memo_prev_cue", on)
	_rebuild_chips()


func set_answer(mode: String) -> void:
	var m: String = "speak" if mode == "speak" else "type"
	if Store.prefs.get("memo_answer", null) != m:
		Store.set_pref("memo_answer", m)
	_rebuild_chips()


# ---------------------------------------------------------------- 상태 정리

func _reset() -> void:
	_leave_all(true)
	_gone = false
	song = {}
	song_id = ""
	memo = {}
	view = "home"
	result = "back"
	open_error = ""
	last_summary = {}
	drill_events = 0
	last_edit = {}
	_notes = []
	_extra = 0
	_skip_new = 0
	_logged = {}
	_leave_fails = 0
	meaning_open = false
	_edit = null
	_edit_orig = ""
	_chips = null
	_meaning_count = null
	_close_sheet()
	_clear_body()
	SpeakDrill.hide_footer(_shell)


## 진행 중인 세션을 끝내고(저장), 아래 위젯의 녹음·읽어 주기·요청을 멈춘다. quiet 이면 알림 토스트를 내지 않는다.
func _leave_all(quiet: bool) -> void:
	if session != null:
		_end_session(true, quiet)
	if drill != null and is_instance_valid(drill):
		drill.on_hide()
	if meaning != null and is_instance_valid(meaning):
		meaning.on_hide()
	if not quiet and view == "session":
		view = "home"


func _close_sheet() -> void:
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		last_sheet.close("dismiss")
	last_sheet = null


func _clear_body() -> void:
	if drill != null and is_instance_valid(drill):
		drill.on_hide()
	drill = null
	meaning = null
	_chips = null
	_meaning_count = null
	_edit = null
	_edit_msg_box = null
	if _body != null:
		UI.clear(_body)


func _set_header(title: String, sub: String) -> void:
	(_shell["title"] as Label).text = title
	(_shell["count"] as Label).text = sub


func _set_back(text: String) -> void:
	(_shell["back"] as Button).text = text


func _build_footer() -> void:
	var a: String = attribution_text()
	if a == "":
		return
	var row := SpeakDrill.new_footer_row(_shell)
	var l := UI.colored(a, Pal.MUTED, "Small")
	l.name = "Attribution"
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)


func _acc() -> Color:
	return Pal.accent(lang)


func _song_title() -> String:
	var t: String = str(song.get("title", ""))
	return t if t != "" else "노래"


func _save_memo(id: String, m: Dictionary) -> Variant:
	var ok: bool = SongStore.save_memo(id, m)
	return {"ok": ok, "err_code": "" if ok else SongStore.last_error}


# ---------------------------------------------------------------- 집 화면

func show_home() -> void:
	_clear_body()
	view = "home"
	_set_back(BACK_HOME)
	_skip_new = 0
	var artist: String = str(song.get("artist", ""))
	var st: Dictionary = home_stats()
	_set_header(_song_title(), artist if artist != "" else "%d줄" % int(st["total"]))
	var acc: Color = _acc()
	for n in _notes:
		var nb := SpeakDrill.notice(str(n), false)
		nb.name = "Note"
		_body.add_child(nb)

	var card := UI.card("BigCard", 10)
	card.name = "ProgressCard"
	var total: int = int(st["total"])
	var pl := UI.label("외운 줄 %d/%d" % [int(st["memorized"]), total], "H2")
	pl.name = "ProgressLabel"
	card.body.add_child(pl)
	var bar := UI.progress_bar(float(int(st["memorized"])) / float(maxi(1, total)), acc, 10.0)
	bar.name = "ProgressBar"
	card.body.add_child(bar)
	var det := UI.label("학습 중 %d줄 · 새 줄 %d줄" % [int(st["learning"]), int(st["fresh"])], "Muted")
	det.name = "DetailLabel"
	card.body.add_child(det)
	var dl := UI.label("오늘 복습 %d줄" % int(st["today_review"]), "Strong")
	dl.name = "DueLabel"
	card.body.add_child(dl)
	var nl := UI.label("오늘 새 줄 %d줄" % int(st["today_new"]), "Strong")
	nl.name = "NewLabel"
	card.body.add_child(nl)
	var nd: int = int(st["next_due"])
	var ndl: Label = null
	if nd > 0:
		ndl = UI.label("다음 복습: 약 %s 뒤" % after_text(maxi(0, nd - _now())), "Muted")
	elif int(st["due"]) > 0:
		ndl = UI.label("다음 복습: 지금 복습할 줄이 있어요", "Muted")
	if ndl != null:
		ndl.name = "NextDueLabel"
		card.body.add_child(ndl)
	if total == 0:
		var nn := SpeakDrill.notice(MSG_NO_LINES, false)
		nn.name = "NoLines"
		card.body.add_child(nn)
	var can_start: bool = int(st["today_new"]) + int(st["today_review"]) > 0
	var start := SpeakDrill.touch_button("오늘 외우기", "primary", acc)
	start.name = "StartBtn"
	start.disabled = not can_start
	start.pressed.connect(func() -> void: start_today())
	card.body.add_child(start)
	var more := SpeakDrill.touch_button("5줄 더하기", "soft", acc)
	more.name = "MoreBtn"
	more.disabled = MemoModel.NEW_CAP * (1 + _extra) >= int(st["fresh"])
	more.pressed.connect(func() -> void: add_more())
	card.body.add_child(more)
	_body.add_child(card)

	var sc := UI.card("Card", 8)
	sc.name = "SettingsCard"
	sc.body.add_child(UI.label("설정", "H3"))
	_chips = UI.flow(8, 8)
	_chips.name = "SettingChips"
	sc.body.add_child(_chips)
	_rebuild_chips()
	sc.body.add_child(UI.label("다음에 외울 때부터 적용돼요. 빠르게는 단계가 5개에서 3개가 돼요.", "Small"))
	_body.add_child(sc)

	var ac := UI.card("Card", 8)
	ac.name = "ActionsCard"
	var lb := SpeakDrill.touch_button("줄 목록", "soft", acc)
	lb.name = "ListBtn"
	lb.pressed.connect(func() -> void: show_lines())
	ac.body.add_child(lb)
	if is_lyrics_song():
		var eb := SpeakDrill.touch_button("가사 고치기", "soft", acc)
		eb.name = "EditBtn"
		eb.pressed.connect(func() -> void: show_edit())
		ac.body.add_child(eb)
	var rb := SpeakDrill.touch_button("진도 초기화", "outline", Pal.BAD)
	rb.name = "ResetBtn"
	rb.pressed.connect(func() -> void: request_reset())
	ac.body.add_child(rb)
	_body.add_child(ac)

	_body.add_child(_meaning_card(acc))
	UI.fix_cjk(_body)
	SpeakDrill.fit_touch(_body)


func _rebuild_chips() -> void:
	if _chips == null or not is_instance_valid(_chips):
		return
	UI.clear(_chips)
	var c1 := UI.filter_chip("빠르게 (3단계)", pref_fast(), func() -> void: set_fast(not pref_fast()))
	c1.name = "ChipFast"
	_chips.add_child(c1)
	var c2 := UI.filter_chip("앞 줄 힌트", pref_prev_cue(), func() -> void: set_prev_cue(not pref_prev_cue()))
	c2.name = "ChipCue"
	_chips.add_child(c2)
	var c3 := UI.filter_chip("입력으로 답하기", pref_answer() == "type", func() -> void: set_answer("type"))
	c3.name = "ChipType"
	_chips.add_child(c3)
	var c4 := UI.filter_chip("말하기로 답하기", pref_answer() == "speak", func() -> void: set_answer("speak"))
	c4.name = "ChipSpeak"
	_chips.add_child(c4)
	UI.fix_cjk(_chips)


## 집 화면 [5줄 더하기]: 오늘 새 줄을 5줄 늘린다 (남은 새 줄이 있을 때만).
func add_more() -> bool:
	if view != "home":
		return false
	var fresh: int = int(MemoModel.summary(song, memo, _now())["fresh"])
	if MemoModel.NEW_CAP * (1 + _extra) >= fresh:
		return false
	_extra += 1
	show_home()
	return true


# ---------------------------------------------------------------- 해석 칸

func _meaning_counts() -> Vector2i:
	var have := 0
	var all := 0
	var ls: Variant = song.get("lines", [])
	if ls is Array:
		for d in (ls as Array):
			if d is Dictionary and SongMeaningTab.is_translatable(d):
				all += 1
				if str((d as Dictionary).get("ko", "")).strip_edges() != "" and not bool((d as Dictionary).get("stale", false)):
					have += 1
	return Vector2i(have, all)


func _meaning_card(acc: Color) -> Control:
	var card := UI.card("Card", 8)
	card.name = "MeaningCard"
	card.body.add_child(UI.label("해석 · 단어 뜻", "H3"))
	_meaning_count = UI.label("", "Muted")
	_meaning_count.name = "MeaningCount"
	card.body.add_child(_meaning_count)
	_refresh_meaning_count()
	var b := SpeakDrill.touch_button("접기" if meaning_open else "해석 보기 · 만들기", "soft", acc)
	b.name = "MeaningBtn"
	b.pressed.connect(func() -> void: toggle_meaning())
	card.body.add_child(b)
	if meaning_open:
		meaning = SongMeaningTab.new()
		meaning.name = "MeaningTab"
		card.body.add_child(meaning)
		meaning.song_changed.connect(_on_meaning_changed)
		meaning.setup(song, {"player": null, "line": -1})
		meaning.on_show()
	return card


func _refresh_meaning_count() -> void:
	if _meaning_count == null or not is_instance_valid(_meaning_count):
		return
	var c: Vector2i = _meaning_counts()
	_meaning_count.text = "%d줄 중 %d줄에 해석이 있어요" % [c.y, c.x]


func toggle_meaning() -> void:
	if view != "home":
		return
	meaning_open = not meaning_open
	show_home()


func _on_meaning_changed() -> void:
	_refresh_meaning_count()


# ---------------------------------------------------------------- 세션

## 세션을 만든다. 시작할 줄이 없으면 false (세션 없음).
func _begin(o: Dictionary) -> bool:
	if song.is_empty():
		return false
	if session != null:
		_end_session(true)
	var opts: Dictionary = {"fast": pref_fast(), "prev_cue": pref_prev_cue(), "id": song_id,
		"save": Callable(self, "_save_memo"), "clock": Callable(self, "_now")}
	opts.merge(o, true)
	var s := MemoSession.new()
	s.begin(song, memo, _now(), opts)
	if not bool(s.current().get("ok", false)):
		Toast.info(MSG_NOTHING)
		return false
	session = s
	_logged = {}
	_leave_fails = 0
	_render_session()
	return true


## [오늘 외우기]: 복습 줄(최대 20) + 새 줄(5줄, [5줄 더하기]를 눌렀으면 5줄씩 더).
func start_today() -> bool:
	if view != "home":
		return false
	var cap: int = MemoModel.NEW_CAP * (1 + _extra)
	_extra = 0
	var ok: bool = _begin({"new_cap": cap})
	if not ok:
		show_home()
	return ok


## 요약의 [5줄 더 외우기]: 미뤄 둔 새 줄은 건너뛰고 다음 새 줄 5줄(+ 이미 복습할 때가 된 줄).
func start_more() -> bool:
	if view != "summary":
		return false
	var skip: int = _skip_new
	_end_session(true)
	view = "home"
	var ok: bool = _begin({"new_cap": MemoModel.NEW_CAP, "skip_new": skip})
	if not ok:
		show_home()
	return ok


## 줄 목록에서 한 줄: "연습만" (평가·통계·기록 변경 없음).
func practice_line(i: int) -> bool:
	if view != "lines" and view != "home":
		return false
	return _begin({"only_line": i, "practice_only": true})


func _render_session() -> void:
	_clear_body()
	view = "session"
	_set_back(BACK_INNER)
	_set_header(_song_title(), "")
	drill = SongMemoDrill.new()
	_body.add_child(drill)
	drill.event.connect(_on_drill_event)
	drill.setup(session, lang)


func _on_drill_event(kind: String, data: Dictionary) -> void:
	if session == null:
		return
	if kind == "line_done" or kind == "next_line" or kind == "later" or kind == "submit" or kind == "reveal":
		_leave_fails = 0 # 진행이 있었다: 나가기 실패 횟수를 다시 센다
	match kind:
		"line_done":
			var ev: Variant = data.get("ev", {})
			if ev is Dictionary and bool((ev as Dictionary).get("counted", false)):
				var pos: int = int(session.current().get("pos", 0))
				if not _logged.has(pos):
					_logged[pos] = true
					StudyLog.add_event(lang, "drill", 1)
					drill_events += 1
		"later":
			var res: Variant = data.get("res", {})
			if res is Dictionary and bool((res as Dictionary).get("ok", false)) and not session.practice_only:
				var c: Dictionary = session.current()
				if str(c.get("kind", "")) == "new" and not bool(c.get("done", false)):
					_skip_new += 1
		"answer_mode":
			var m: String = str(data.get("mode", "type"))
			if Store.prefs.get("memo_answer", null) != m:
				Store.set_pref("memo_answer", m)
		"queue_end":
			call_deferred("_show_summary") # 드릴이 신호를 내는 중이라 바로 지우지 않는다


## 세션을 끝낸다: 줄 저장(leave_line, 밀린 저장이 있으면 다시 시도) -> 판 통계(finish). 저장이 실패하면 finish 를 부르지 않고
## 두 번째 시도부터(또는 force) 저장하지 못한 채 버린다 (상태는 그대로라 기록이 깨지지 않는다). 끝냈으면 true.
func _end_session(force: bool, quiet: bool = false) -> bool:
	if session == null:
		return true
	if drill != null and is_instance_valid(drill):
		drill.on_hide()
	var cur: Dictionary = session.current()
	var was_pending: bool = bool(cur.get("pending_save", false))
	var pos: int = int(cur.get("pos", 0))
	var r: Dictionary = session.leave_line()
	if bool(r.get("ok", false)) and was_pending and not _logged.has(pos) and not session.practice_only:
		_logged[pos] = true # 저장이 밀렸던 줄이 이 저장으로 끝났다: 학습 기록도 1번
		StudyLog.add_event(lang, "drill", 1)
		drill_events += 1
	if not bool(r.get("ok", false)):
		_leave_fails += 1
		if not force and _leave_fails < 2:
			if not quiet:
				Toast.error(MSG_LEAVE_FAIL)
			if drill != null and is_instance_valid(drill):
				drill.render()
			return false
		if not quiet:
			Toast.error(MSG_LEFT_UNSAVED)
	else:
		session.finish()
	_leave_fails = 0
	memo = session.memo.duplicate(true)
	last_summary = session.summary()
	session = null
	return true


func _show_summary() -> void:
	if session == null or view != "session":
		return
	var stats_ok: bool = true
	if not session.finished:
		stats_ok = bool(session.finish().get("ok", false)) # 판 통계를 한 번 더 저장해 본다
	memo = session.memo.duplicate(true)
	var sm: Dictionary = session.summary()
	last_summary = sm
	_clear_body()
	view = "summary"
	_set_back(BACK_INNER)
	_set_header(_song_title(), "")
	var acc: Color = _acc()
	var card := UI.card("BigCard", 10)
	card.name = "SummaryCard"
	if bool(sm["practice_only"]):
		var pl := UI.label("연습을 마쳤어요", "H2")
		pl.name = "DoneLabel"
		card.body.add_child(pl)
		card.body.add_child(UI.label("연습만 했어요. 복습 기록은 바꾸지 않았어요.", "Muted"))
	else:
		var dl := UI.label("오늘 %d줄 했어요" % int(sm["lines_done"]), "H2")
		dl.name = "DoneLabel"
		card.body.add_child(dl)
		card.body.add_child(UI.label("새 줄 %d · 복습 %d" % [int(sm["new_done"]), int(sm["review_done"])], "Muted"))
		card.body.add_child(UI.label("잘함 %d · 아슬아슬 %d · 다시 %d" % [int(sm["good"]), int(sm["hard"]), int(sm["again"])], "Muted"))
	var pg := UI.label("외운 줄 %d/%d" % [int(sm["memorized"]), int(sm["total"])], "Strong")
	pg.name = "ProgressLabel"
	card.body.add_child(pg)
	var nd: int = int(sm["next_due"])
	var ndl: Label = null
	if nd > 0:
		ndl = UI.label("다음 복습: 약 %s 뒤" % after_text(int(sm["next_due_in"])), "Strong")
	elif int(sm["due"]) > 0:
		ndl = UI.label("다음 복습: 지금 복습할 줄이 있어요", "Strong")
	else:
		ndl = UI.label("다음 복습: 아직 없어요", "Muted")
	ndl.name = "NextDueLabel"
	card.body.add_child(ndl)
	if not stats_ok:
		var nb := SpeakDrill.notice(MSG_SAVE_STATS, true)
		nb.name = "SaveNote"
		card.body.add_child(nb)
	var more_ok: bool = int(sm["fresh"]) > 0 or int(sm["due"]) > 0
	var mb := SpeakDrill.touch_button("5줄 더 외우기", "primary", acc)
	mb.name = "MoreBtn"
	mb.disabled = not more_ok or bool(sm["practice_only"])
	mb.pressed.connect(func() -> void: start_more())
	card.body.add_child(mb)
	var hb := SpeakDrill.touch_button("집으로", "soft", acc)
	hb.name = "HomeBtn"
	hb.pressed.connect(func() -> void:
		_end_session(true)
		show_home())
	card.body.add_child(hb)
	var lb := SpeakDrill.touch_button("줄 목록", "flat", Pal.MUTED)
	lb.name = "ListBtn"
	lb.pressed.connect(func() -> void:
		_end_session(true)
		show_lines())
	card.body.add_child(lb)
	_body.add_child(card)
	UI.fix_cjk(_body)
	SpeakDrill.fit_touch(_body)


# ---------------------------------------------------------------- 줄 목록

func show_lines() -> void:
	if song.is_empty():
		return
	_clear_body()
	view = "lines"
	_set_back(BACK_INNER)
	var keys: Array = MemoModel.keys_of(song)
	_set_header(_song_title(), "%d줄" % keys.size())
	var acc: Color = _acc()
	var head := UI.card("Card", 6)
	head.name = "LinesHead"
	head.body.add_child(UI.label("줄 목록", "H3"))
	head.body.add_child(UI.label("[이 줄만 연습]을 누르면 그 줄만 연습해요. 연습만 하므로 복습 기록은 바뀌지 않아요.", "Muted"))
	var hb := SpeakDrill.touch_button("집으로", "soft", acc)
	hb.name = "HomeBtn"
	hb.pressed.connect(func() -> void: show_home())
	head.body.add_child(hb)
	_body.add_child(head)
	var ls: Array = song["lines"]
	for e in keys:
		var i: int = int(e["i"])
		var key: String = str(e["key"])
		var state: String = line_state(key)
		var card := UI.card("Card", 6)
		card.name = "LineRow_%d" % i
		var top := UI.flow(8, 6)
		top.add_child(UI.colored("%d" % (i + 1), Pal.MUTED, "Eyebrow", false))
		var chip: PanelContainer = UI.chip_kind(state_text(state), _state_kind(state))
		chip.name = "StateChip"
		top.add_child(chip)
		card.body.add_child(top)
		var tl := UI.label(str((ls[i] as Dictionary).get("text", "")), "Strong")
		tl.name = "LineText"
		card.body.add_child(tl)
		var pb := SpeakDrill.touch_button("이 줄만 연습", "soft", acc)
		pb.name = "PracticeBtn_%d" % i
		pb.pressed.connect(func() -> void: practice_line(i))
		card.body.add_child(pb)
		_body.add_child(card)
	if keys.is_empty():
		_body.add_child(SpeakDrill.notice(MSG_NO_LINES, false))
	UI.fix_cjk(_body)
	SpeakDrill.fit_touch(_body)


static func _state_kind(state: String) -> String:
	match state:
		"memorized":
			return "ok"
		"due":
			return "warn"
		"learning":
			return "info"
	return "neutral"


# ---------------------------------------------------------------- 가사 고치기 (음원 없는 곡)

## 곡 줄을 편집칸 글자로 만든다 (문단 `p` 가 바뀌면 빈 줄).
func lyrics_text() -> String:
	var out: PackedStringArray = PackedStringArray()
	var prev_p: int = -1
	var ls: Variant = song.get("lines", [])
	if ls is Array:
		for d in (ls as Array):
			if not (d is Dictionary):
				continue
			var p: int = int((d as Dictionary).get("p", 0))
			if prev_p >= 0 and p != prev_p:
				out.append("")
			prev_p = p
			out.append(str((d as Dictionary).get("text", "")))
	return "\n".join(out)


func show_edit() -> bool:
	if song.is_empty():
		return false
	if not is_lyrics_song():
		Toast.info(MSG_EDIT_AUDIO)
		return false
	_clear_body()
	view = "edit"
	_set_back(BACK_INNER)
	_set_header(_song_title(), "가사 고치기")
	var acc: Color = _acc()
	var card := UI.card("BigCard", 10)
	card.name = "EditCard"
	card.body.add_child(UI.label("가사 고치기", "H3"))
	card.body.add_child(UI.label("한 줄에 한 문장씩 써요. 빈 줄은 연을 나눠요. 글자를 고친 줄은 새 줄이 되어 처음부터 외워요. 글자가 그대로인 줄은 외운 기록이 남아요.", "Muted"))
	_edit = TextEdit.new()
	_edit.name = "LyricsEdit"
	_edit_orig = lyrics_text()
	_edit.text = _edit_orig
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_edit.custom_minimum_size.y = 260.0
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.body.add_child(_edit)
	_edit_msg_box = UI.vbox(6)
	_edit_msg_box.name = "EditMessages"
	card.body.add_child(_edit_msg_box)
	var sb := SpeakDrill.touch_button("저장", "primary", acc)
	sb.name = "SaveEditBtn"
	sb.pressed.connect(func() -> void: save_edit(_edit.text if _edit != null else ""))
	card.body.add_child(sb)
	var cb := SpeakDrill.touch_button("취소", "flat", Pal.MUTED)
	cb.name = "CancelEditBtn"
	cb.pressed.connect(func() -> void: go_back())
	card.body.add_child(cb)
	_body.add_child(card)
	UI.fix_cjk(_body)
	SpeakDrill.fit_touch(_body)
	return true


func _edit_dirty() -> bool:
	return _edit != null and is_instance_valid(_edit) and _edit.text != _edit_orig


func _confirm_discard_edit() -> void:
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	last_sheet = Sheet.confirm(self, "고친 내용을 버릴까요?", "저장하지 않은 가사 수정이 사라져요.", "버리기", true, "계속 고치기")
	last_sheet.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			show_home())


func _edit_note(msg: String, bad: bool) -> void:
	if _edit_msg_box != null and is_instance_valid(_edit_msg_box):
		UI.clear(_edit_msg_box)
		var n := SpeakDrill.notice(msg, bad)
		n.name = "EditNote"
		_edit_msg_box.add_child(n)
		UI.fix_cjk(_edit_msg_box)


static func _new_line(i: int, p: int, text: String) -> Dictionary:
	return {"i": i, "p": p, "t0": 0.0, "t1": 0.0, "text": text, "reading": "", "pron": "", "ko": "", "conf": null, "est": true,
		"stale": false, "words": []}


## 고친 가사를 저장한다. -> {ok, err, notes, changed}  err: not_lyrics · read_only · empty · too_long · disk_write
## 규칙: 줄 나누기·구간 표시([Chorus]) 제거는 SongAddScreen.prepare_lyrics 그대로. 400줄·200자·20000자를 넘으면 저장하지 않는다
## (잘라서 저장하지 않고 고치게 한다). 글자가 같은 줄은 해석·읽기를 그대로 두고, 고친 줄은 새 줄로 만든다(기록은 키로 따라간다).
## 저장(SongStore.save_song)이 실패하면 곡은 원본 그대로다.
func save_edit(text: String) -> Dictionary:
	var res: Dictionary = {"ok": false, "err": "", "notes": [], "changed": 0}
	last_edit = res
	if song.is_empty() or not is_lyrics_song():
		res["err"] = "not_lyrics"
		_edit_note(MSG_EDIT_AUDIO, true)
		return res
	if SongModel.is_read_only(song):
		res["err"] = "read_only"
		_edit_note(MSG_EDIT_READONLY, true)
		return res
	var prep: Dictionary = SongAddScreen.prepare_lyrics("pasted", text)
	var entries: Array = prep["lines"]
	res["notes"] = prep["notes"]
	if entries.is_empty():
		res["err"] = "empty"
		_edit_note(MSG_EDIT_EMPTY, true)
		return res
	if int(prep["cut_lines"]) > 0 or int(prep["cut_chars"]) > 0 or bool(prep["cut_total"]):
		res["err"] = "too_long"
		_edit_note(MSG_EDIT_LONG % [SongAddScreen.MAX_LINE_CHARS, SongAddScreen.MAX_LINES, SongAddScreen.MAX_LYRIC_CHARS], true)
		return res
	var old_lines: Array = song.get("lines", []) if song.get("lines", null) is Array else []
	var used := {}
	var new_lines: Array = []
	for idx in entries.size():
		var e: Dictionary = entries[idx]
		var tx: String = str(e["text"])
		var found: int = -1
		for j in old_lines.size():
			if not used.has(j) and old_lines[j] is Dictionary and str((old_lines[j] as Dictionary).get("text", "")) == tx:
				found = j
				break
		var ln: Dictionary
		if found >= 0:
			used[found] = true
			ln = (old_lines[found] as Dictionary).duplicate(true)
			ln["i"] = idx
			ln["p"] = int(e["p"])
		else:
			ln = _new_line(idx, int(e["p"]), tx)
		new_lines.append(ln)
	var cand: Dictionary = song.duplicate(true)
	cand["lines"] = new_lines
	var old_keys := {}
	for k in MemoModel.keys_of(song):
		old_keys[str(k["key"])] = true
	var changed := 0
	for k in MemoModel.keys_of(cand):
		if not old_keys.has(str(k["key"])):
			changed += 1
	if not SongStore.save_song(cand):
		res["err"] = "disk_write"
		_edit_note(MSG_EDIT_SAVE_FAIL, true)
		return res
	var fresh: Dictionary = SongStore.load_song(song_id)
	song = fresh if not fresh.is_empty() else SongModel.normalize(cand)
	# 곡에 없는 오래된 키를 정리한다 (30일 지난 것). 읽기 전용 기록은 건드리지 않는다.
	if not MemoModel.is_read_only(memo):
		var before: String = JSON.stringify(memo)
		MemoModel.prune(memo, song, _now())
		if JSON.stringify(memo) != before:
			SongStore.save_memo(song_id, memo)
	res["ok"] = true
	res["changed"] = changed
	last_edit = res
	Toast.ok("가사를 저장했어요" + (" (고친 %d줄은 새 줄이에요)" % changed if changed > 0 else ""))
	show_home()
	return res


# ---------------------------------------------------------------- 진도 초기화

func request_reset() -> void:
	if song.is_empty() or view != "home":
		return
	if last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed():
		return
	last_sheet = Sheet.confirm(self, "진도를 처음부터 할까요?",
		"'%s'의 외운 줄 기록이 이 기기에서 지워져요. 가사와 복습 탭의 카드는 그대로 남아요. 되돌릴 수 없어요." % _song_title(),
		"초기화", true)
	last_sheet.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			reset_progress())


## memo.json 만 지운다 (song.json 은 그대로). 지우지 못하면 기록은 그대로 둔다.
func reset_progress() -> bool:
	if song.is_empty():
		return false
	if not SongStore.delete_memo(song_id):
		Toast.error(MSG_RESET_FAIL)
		return false
	memo = MemoModel.new_memo()
	_notes = []
	_extra = 0
	Toast.ok(MSG_RESET_OK)
	if view == "home":
		show_home()
	return true
