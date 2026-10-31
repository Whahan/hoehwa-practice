class_name SongStudyScreen
extends Control
## 노래 공부 학습 화면의 틀 (docs/song_study_design.md §4.3, §5.4, §5.5, U4a):
## 위 머리줄(← 노래 · 곡 제목) + 고정 재생 막대(이전 줄 · 재생/일시정지 · 정지 · 다음 줄, 속도 프리셋, 줄 반복 1/3/계속,
## 음높이 유지) + 탭 칩(듣기 · 따라 부르기 · 단어 · 빈칸 · 받아쓰기 · 해석) + 탭 내용(스크롤) + 아래 고정 줄(가사 출처 문구).
## 소리는 전부 SongPlayer (자식 노드)가 낸다. 하위 화면 계약은 PracticeView 와 같다: `closed` 신호, `open(lang, args)`,
## `on_hide()`, `go_back() -> bool`, `_shell` (폰 앱 바가 제목을 읽는다).
##
##   var s := SongStudyScreen.new(); parent.add_child(s); s.open("en", {"id": "s_0123456789ab"})   # SongStore 에서 읽는다
##   s.open("en", {"song": song_dict})                                                            # 이미 읽은 곡 (SongModel 로 보정)
##   args.tab: 처음 보일 탭 (없으면 pref song_last_tab)
##
## ---- 탭 위젯 계약 (U4b 가 고정한 것에 맞춤. 6개 탭 모두 `extends VBoxContainer`, 인자 없이 `ClassName.new()`) ----
## 화면이 다음 순서로 부른다 (파일 경로는 TAB_SCRIPTS):
##   1. parent.add_child(tab)                 (먼저 트리에 넣는다)
##   2. tab.setup(song: Dictionary, opts: Dictionary)   (필수, 한 번)
##        song = SongStore.load_song 이 준 보정된 곡 — 복사 없이 모든 탭이 같은 객체를 본다.
##        opts = {player: SongPlayer, line: int (지금 고른 줄, 없으면 -1),
##                screen: SongStudyScreen, save: Callable() -> bool (SongStore.save_song(song)), lang: "en"|"ja"}
##        (U4b 탭은 player · line 만 쓴다. screen · save · lang 은 듣기 · 부르기 탭용 덧붙임이라 무시해도 된다.)
##   3. tab.on_show()                         (탭이 보일 때마다)
##   4. tab.set_line(i: int)                  (사용자가 고른 줄이 바뀔 때 — 재생 위치로 바뀌는 건 아님)
##   5. tab.on_hide()                         (다른 탭으로 가거나 화면을 떠날 때: 음성 정지 · 녹음 · 요청 취소)
## 탭이 곡을 고치면(해석 탭) SongStore.save_song 뒤에 `signal song_changed` 를 낸다 -> 화면이 줄 목록(듣기 탭)을 다시 그린다.
## 탭은 고정 하단 바 없이 본문 안에서 처리하고, 스크롤은 이 화면이 맡는다. 받아쓰기 탭이 보이는 동안에는 가사 목록(듣기 탭)이 숨겨진다
## (정답 노출 방지) — 가사 목록은 듣기 탭에만 있다.
## 탭 파일이 없으면(아직 합쳐지지 않았으면) 그 자리에 "준비 중" 안내가 들어간다.
## 탭이 쓸 화면 함수: select_line(i, play=false) · play_line(i) · highlight_line() · signal highlight_changed(i) · scroll_to_control(c) · line_count().

signal closed
signal check_requested(song_id: String) ## ⋯ 메뉴 "가사 확인·수정": 연결하는 쪽이 이 화면을 닫고 SongCheckScreen 을 연다
signal deleted(song_id: String) ## ⋯ 메뉴 "곡 삭제" 가 끝났다 (바로 뒤에 closed)
signal tab_changed(kind: String)
signal highlight_changed(i: int) ## 강조할 줄이 바뀜 (재생 중이면 재생 줄, 아니면 고른 줄)

const TABS := [
	["listen", "듣기"], ["sing", "따라 부르기"], ["words", "단어"],
	["cloze", "빈칸"], ["dictation", "받아쓰기"], ["meaning", "해석"],
]
const TAB_SCRIPTS := {
	"listen": "res://scripts/song/song_listen_tab.gd",
	"sing": "res://scripts/song/song_sing_tab.gd",
	"words": "res://scripts/song/song_words_tab.gd",
	"cloze": "res://scripts/song/song_cloze_tab.gd",
	"dictation": "res://scripts/song/song_dictation_tab.gd",
	"meaning": "res://scripts/song/song_meaning_tab.gd",
}
const REPEATS := [[1, "1회"], [3, "3회"], [0, "계속"]]
const DEFAULT_TAB := "listen"
const DEFAULT_ATTRIBUTION := "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"
const MSG_OPEN_FAIL := "곡을 열 수 없어요. 곡 목록으로 돌아가 다시 열어 보세요."
const MSG_RECORDING := "녹음하는 동안은 노래를 틀지 않아요."
const MSG_DELETE_FAIL := "곡을 지우지 못했어요. 파일이 다른 곳에서 열려 있는지 확인해 주세요."
const SOURCE_KO := {"asr": "소리에서 받아 적음", "pasted": "붙여넣은 가사", "lrclib": "LRCLIB"}
const LANG_KO := {"en": "영어", "ja": "일본어"}
const PLAY_TEXT := "▶ 재생"
const RESUME_TEXT := "▶ 이어서"
const PAUSE_TEXT := "일시정지"

## 시험 전용: Callable(kind: String) -> Control 또는 null. 있으면 이 함수가 탭을 만든다 (null 이면 파일에서).
static var tab_factory: Callable = Callable()

var lang: String = "en"
var song: Dictionary = {}
var song_id: String = ""
var player: SongPlayer = null
var tab: String = DEFAULT_TAB
var tab_nodes: Dictionary = {} ## kind -> Control (한 번 만든 탭은 숨기기만 한다)
var cur_line: int = -1 ## 사용자가 고른 줄
var speed: float = 1.0
var keep_pitch: bool = true
var repeat: int = 1
var audio_ok: bool = false ## 소리 파일을 읽었다
var open_error: String = "" ## 곡을 못 열었을 때의 문구
var result: String = "" ## 나간 이유: "" | "back" | "deleted" | "check"
var last_sheet: Sheet = null ## 마지막으로 연 시트 (시험용)

var _shell: Dictionary = {}
var _menu_btn: Button = null
var _bar: PanelContainer = null
var _btn_prev: Button = null
var _btn_play: Button = null
var _btn_stop: Button = null
var _btn_next: Button = null
var _time_label: Label = null
var _progress: ProgressBar = null
var _speed_row: HFlowContainer = null
var _repeat_row: HFlowContainer = null
var _tab_row: HFlowContainer = null
var _notice_box: VBoxContainer = null
var _tab_host: VBoxContainer = null
var _hl: int = -2
var _last_sec: int = -1
var _serial: int = 0


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back, "← 노래")
	_menu_btn = UI.button("⋯", "flat", Pal.INK, SpeakDrill.TOUCH_H)
	_menu_btn.name = "MenuBtn"
	_menu_btn.accessibility_name = "곡 메뉴"
	_menu_btn.custom_minimum_size.x = maxf(SpeakDrill.TOUCH_H, Ds.touch_min())
	_menu_btn.visible = false
	_menu_btn.pressed.connect(open_menu)
	(_shell["head"] as Control).add_child(_menu_btn)
	player = SongPlayer.new()
	player.name = "SongPlayer"
	add_child(player)
	player.position_changed.connect(_on_position)
	player.line_changed.connect(_on_player_line)
	player.finished_loop.connect(_on_loop_done)
	player.song_ended.connect(_on_song_end)
	_build_bar()
	var page: PageScroll = _shell["page"]
	_notice_box = UI.vbox(8)
	page.content.add_child(_notice_box)
	_tab_host = UI.vbox(0)
	page.content.add_child(_tab_host)


func _exit_tree() -> void:
	_serial += 1
	_leave()


# ---------------------------------------------------------------- hub contract

## 곡을 열고 화면을 만든다. 곡의 언어가 `l` 보다 우선한다.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l if l == "ja" else "en"
	_reset()
	var raw: Variant = args.get("song", null)
	if args.has("song"):
		song = SongModel.normalize(raw) if (raw is Dictionary and not (raw as Dictionary).is_empty()) else {}
	else:
		var sid: String = str(args.get("id", args.get("song_id", "")))
		song = SongStore.load_song(sid) if sid != "" else {}
	if song.is_empty():
		open_error = MSG_OPEN_FAIL
		_set_header("노래", "")
		_notice_box.add_child(SpeakDrill.notice(open_error))
		_update_controls()
		return
	song_id = str(song.get("id", ""))
	lang = str(song.get("lang", lang))
	_menu_btn.visible = true
	SongPlayer.songs_root = SongStore.root
	_read_prefs()
	player.set_speed(speed)
	player.set_keep_pitch(keep_pitch)
	audio_ok = player.load_song(song)
	if not audio_ok:
		_notice_box.add_child(SpeakDrill.notice(player.last_error if player.last_error != "" else SongPlayer.MSG_BAD_AUDIO))
	var artist: String = str(song.get("artist", ""))
	var n: int = line_count()
	_set_header(str(song.get("title", "")) if str(song.get("title", "")) != "" else "노래", artist if artist != "" else "%d줄" % n)
	_build_footer()
	_rebuild_speed()
	_rebuild_repeat()
	_refresh_bar()
	var want: String = str(args.get("tab", Store.prefs.get("song_last_tab", DEFAULT_TAB)))
	show_tab(want if _tab_ids().has(want) else DEFAULT_TAB)
	UI.fix_cjk(self)


## 다른 곳으로 갈 때: 재생 정지, 탭의 녹음·말하기 정지.
func on_hide() -> void:
	_leave()


## 안드로이드 뒤로 가기 / 머리줄 버튼.
func go_back() -> bool:
	_leave()
	if result == "":
		result = "back"
	closed.emit()
	return true


func page_title() -> String:
	return (_shell["title"] as Label).text


# ---------------------------------------------------------------- ⋯ menu (가사 확인·수정 · 곡 정보 · 곡 삭제)

func _sheet_open() -> bool:
	return last_sheet != null and is_instance_valid(last_sheet) and not last_sheet.is_closed()


func open_menu() -> void:
	if song.is_empty() or _sheet_open():
		return
	last_sheet = Sheet.choice(self, "곡 메뉴", [["check", "가사 확인·수정"], ["info", "곡 정보"], ["delete", "곡 삭제"]])
	last_sheet.closed.connect(_on_menu_pick)


func _on_menu_pick(v: Variant) -> void:
	match str(v):
		"check":
			request_check()
		"info":
			show_info()
		"delete":
			request_delete()


## 가사 확인·수정 화면으로 간다. 재생은 멈춘다. 연결된 곳이 없으면 안내만 한다.
func request_check() -> void:
	if song.is_empty():
		return
	if check_requested.get_connections().is_empty():
		Toast.info("가사 확인 화면은 노래 목록에서 열 수 있어요")
		return
	_leave()
	result = "check"
	check_requested.emit(song_id)


## 곡 정보 시트의 줄들: 제목 · 가수 · 언어 · 길이 · 줄 수 · 파일 크기 · 가사 출처.
func info_lines() -> Array:
	var out: Array = []
	var title: String = SongView.clip(str(song.get("title", "")), SongView.TITLE_MAX)
	out.append("제목: " + (title if title != "" else "(제목 없음)"))
	var artist: String = SongView.clip(str(song.get("artist", "")), SongView.ARTIST_MAX)
	if artist != "":
		out.append("가수: " + artist)
	out.append("언어: " + str(LANG_KO.get(str(song.get("lang", "")), "")))
	out.append("길이: " + SongView.fmt_dur(float(song.get("duration", 0.0))))
	out.append("가사: %d줄" % line_count())
	var au: Variant = song.get("audio", {})
	if au is Dictionary and int((au as Dictionary).get("bytes", 0)) > 0:
		out.append("파일 크기: " + SongView.fmt_bytes(int((au as Dictionary).get("bytes", 0))))
	var src: Variant = song.get("source", {})
	if src is Dictionary:
		var k: String = str(SOURCE_KO.get(str((src as Dictionary).get("lyrics", "")), ""))
		if k != "":
			out.append("가사 출처: " + k)
	out.append(SongView.MSG_SAVED_HERE)
	return out


func show_info() -> void:
	if song.is_empty() or _sheet_open():
		return
	var body := UI.vbox(6)
	for t in info_lines():
		body.add_child(UI.label(str(t)))
	last_sheet = Sheet.open(self, "곡 정보", body, [{"id": "ok", "text": "닫기", "kind": "primary"}], {"max_h_frac": 0.85})


## 곡 삭제: 확인 시트 -> delete_now().
func request_delete() -> void:
	if song.is_empty() or _sheet_open():
		return
	var t: String = SongView.clip(str(song.get("title", "")), 40)
	last_sheet = Sheet.confirm(self, "곡을 지울까요?",
		"'%s'의 음악과 가사, 이 곡의 학습 기록이 이 기기에서 지워져요. 되돌릴 수 없어요. 복습 카드는 그대로 남아요." % (t if t != "" else "(제목 없음)"),
		"삭제", true)
	last_sheet.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			delete_now())


## 소리를 놓은 뒤 SongStore.delete. 못 지우면 안내하고 곡을 다시 불러 계속 쓸 수 있게 둔다.
func delete_now() -> bool:
	if song.is_empty() or song_id == "":
		return false
	var id: String = song_id
	_leave()
	player.unload()
	audio_ok = false
	if SongStore.delete(id):
		Toast.ok("곡을 지웠어요")
		result = "deleted"
		deleted.emit(id)
		closed.emit()
		return true
	Toast.error(MSG_DELETE_FAIL)
	audio_ok = player.load_song(song)
	_update_controls()
	return false


# ---------------------------------------------------------------- read helpers

static func _tab_ids() -> Array:
	var out: Array = []
	for t in TABS:
		out.append(t[0])
	return out


func line_count() -> int:
	var ls: Variant = song.get("lines", [])
	return (ls as Array).size() if ls is Array else 0


func line(i: int) -> Dictionary:
	var ls: Variant = song.get("lines", [])
	if ls is Array and i >= 0 and i < (ls as Array).size() and (ls as Array)[i] is Dictionary:
		return (ls as Array)[i]
	return {}


func attribution_text() -> String:
	var src: Variant = song.get("source", {})
	if not (src is Dictionary):
		return ""
	var a: String = str((src as Dictionary).get("attribution", ""))
	if a != "":
		return a
	return DEFAULT_ATTRIBUTION if str((src as Dictionary).get("lyrics", "")) == "lrclib" else ""


func save_song() -> bool:
	return SongStore.save_song(song)


## 강조할 줄: 재생 중(또는 일시정지)이면 재생 줄, 아니면 고른 줄.
func highlight_line() -> int:
	if player != null and (player.is_playing() or player.is_paused()) and player.current_line() >= 0:
		return player.current_line()
	return cur_line


func _read_prefs() -> void:
	var sp: Variant = Store.prefs.get("song_speed", 1.0)
	speed = clampf(float(sp), SongPlayer.SPEED_MIN, SongPlayer.SPEED_MAX) if (sp is float or sp is int) else 1.0
	keep_pitch = bool(Store.prefs.get("song_keep_pitch", true))
	var rp: int = int(Store.prefs.get("song_repeat", 1)) if (Store.prefs.get("song_repeat", 1) is int or Store.prefs.get("song_repeat", 1) is float) else 1
	repeat = rp if rp == 0 or rp == 1 or rp == 3 else 1


func _set_pref(key: String, value: Variant) -> void:
	if Store.prefs.get(key, null) != value:
		Store.set_pref(key, value)


# ---------------------------------------------------------------- selecting / playing

## 줄을 고른다 (탭에 알림). play 가 true 면 그 줄을 반복 설정대로 재생한다.
func select_line(i: int, play: bool = false) -> void:
	if i < 0 or i >= line_count():
		return
	var changed: bool = i != cur_line
	cur_line = i
	if changed:
		for k in tab_nodes.keys():
			var t: Control = tab_nodes[k]
			if is_instance_valid(t) and t.has_method("set_line"):
				t.call("set_line", i)
	if play:
		play_line(i)
	else:
		_emit_highlight()


## 그 줄을 `repeat`(1·3·계속) 번 재생한다. 녹음 중이거나 소리 파일이 없으면 하지 않는다.
func play_line(i: int) -> void:
	if i < 0 or i >= line_count():
		return
	if i != cur_line:
		select_line(i)
	if not audio_ok:
		return
	if Recorder.recording:
		Toast.info(MSG_RECORDING)
		return
	Tts.stop()
	player.play_line(i, repeat)
	_refresh_bar()
	_emit_highlight()


## ▶ : 멈춰 있으면 고른 줄(없으면 처음)부터 이어서 끝까지, 재생 중이면 일시정지, 일시정지면 이어서.
func toggle_play() -> void:
	if not audio_ok:
		return
	if player.is_playing():
		player.pause()
	elif player.is_paused():
		if Recorder.recording:
			Toast.info(MSG_RECORDING)
			return
		player.resume()
	else:
		if Recorder.recording:
			Toast.info(MSG_RECORDING)
			return
		Tts.stop()
		var t := 0.0
		var ln: Dictionary = line(cur_line)
		if not ln.is_empty():
			t = float(ln.get("t0", 0.0))
		player.play_from(t)
	_refresh_bar()
	_emit_highlight()


func stop_play() -> void:
	if player != null:
		player.stop()
	_refresh_bar()
	_emit_highlight()


## 이전(-1) · 다음(+1) 줄로 옮겨 재생한다.
func step_line(d: int) -> void:
	var n: int = line_count()
	if n == 0:
		return
	var base: int = highlight_line()
	if base < 0:
		base = cur_line
	var i: int = clampi((base + d) if base >= 0 else 0, 0, n - 1)
	select_line(i)
	play_line(i)


func set_speed(s: float) -> void:
	speed = clampf(s, SongPlayer.SPEED_MIN, SongPlayer.SPEED_MAX)
	player.set_speed(speed)
	_set_pref("song_speed", speed)
	_rebuild_speed()


func set_keep_pitch(b: bool) -> void:
	keep_pitch = b
	player.set_keep_pitch(b)
	_set_pref("song_keep_pitch", b)
	_rebuild_speed()


func set_repeat(n: int) -> void:
	repeat = n if n == 0 or n == 3 else 1
	_set_pref("song_repeat", repeat)
	_rebuild_repeat()


# ---------------------------------------------------------------- player signals

func _on_position(t: float) -> void:
	var dur: float = maxf(player.duration, 0.001)
	if _progress != null:
		_progress.value = clampf(t / dur, 0.0, 1.0) * 100.0
	var sec: int = int(t)
	if sec != _last_sec:
		_last_sec = sec
		_update_time(t)


func _on_player_line(_i: int) -> void:
	_emit_highlight()


func _on_loop_done(_n: int) -> void:
	_refresh_bar()
	_emit_highlight()


func _on_song_end() -> void:
	_refresh_bar()
	_emit_highlight()


func _emit_highlight() -> void:
	var h: int = highlight_line()
	if h != _hl:
		_hl = h
		highlight_changed.emit(h)


# ---------------------------------------------------------------- tabs

func show_tab(kind: String) -> void:
	if not _tab_ids().has(kind):
		return
	var prev: Control = tab_nodes.get(tab, null)
	if tab != kind and prev != null and is_instance_valid(prev):
		_call_opt(prev, "on_hide")
		prev.visible = false
	tab = kind
	_set_pref("song_last_tab", kind)
	var node: Control = tab_nodes.get(kind, null)
	if node == null or not is_instance_valid(node):
		node = _make_tab(kind)
		tab_nodes[kind] = node
		_tab_host.add_child(node)
		if node.has_signal("song_changed"):
			node.connect("song_changed", _on_tab_song_changed)
		if node.has_method("setup"):
			node.call("setup", song, _opts())
	node.visible = true
	_call_opt(node, "on_show")
	_rebuild_tabs()
	var pg: ScrollContainer = _shell["page"]
	pg.scroll_vertical = 0
	tab_changed.emit(kind)


func current_tab() -> Control:
	return tab_nodes.get(tab, null)


func _opts() -> Dictionary:
	return {"lang": lang, "player": player, "screen": self, "line": cur_line, "save": Callable(self, "save_song")}


## 해석 탭 같은 곳이 곡을 고쳤다: 줄 목록을 다시 그린다.
func _on_tab_song_changed() -> void:
	var lt: Control = tab_nodes.get("listen", null)
	if lt != null and is_instance_valid(lt) and lt.has_method("rebuild"):
		lt.call("rebuild")


## 가사 목록이 눈에 보이나 (받아쓰기 탭에서는 false).
func lyrics_visible() -> bool:
	var lt: Control = tab_nodes.get("listen", null)
	return lt != null and is_instance_valid(lt) and lt.is_visible_in_tree()


func _make_tab(kind: String) -> Control:
	if tab_factory.is_valid():
		var made: Variant = tab_factory.call(kind)
		if made is Control:
			return made
	var path: String = str(TAB_SCRIPTS.get(kind, ""))
	if path != "" and ResourceLoader.exists(path):
		var sc: Variant = load(path)
		if sc is GDScript and (sc as GDScript).can_instantiate():
			var o: Variant = (sc as GDScript).new()
			if o is Control:
				return o
	var box := VBoxContainer.new()
	box.name = "TabPlaceholder"
	box.set_meta("placeholder", true)
	box.add_child(UI.label("이 탭은 아직 준비 중이에요.", "Muted"))
	return box


static func _call_opt(node: Object, method: String) -> void:
	if node != null and is_instance_valid(node) and node.has_method(method):
		node.call(method)


## 탭 안의 컨트롤이 화면 위쪽 가까이 오도록 스크롤한다 (레이아웃이 자리 잡은 뒤에 부른다).
func scroll_to_control(c: Control, ratio: float = 0.3) -> void:
	var pg: ScrollContainer = _shell["page"]
	if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
		return
	var y: float = c.global_position.y - pg.global_position.y + float(pg.scroll_vertical)
	pg.scroll_vertical = maxi(0, int(y - pg.size.y * ratio))


# ---------------------------------------------------------------- leaving

func _leave() -> void:
	if player != null and is_instance_valid(player):
		player.stop()
	for k in tab_nodes.keys():
		var t: Control = tab_nodes[k]
		_call_opt(t, "on_hide")


func _reset() -> void:
	_serial += 1
	_leave()
	for k in tab_nodes.keys():
		var t: Control = tab_nodes[k]
		if is_instance_valid(t):
			if t.get_parent() != null:
				t.get_parent().remove_child(t)
			t.queue_free()
	tab_nodes = {}
	tab = DEFAULT_TAB
	song = {}
	song_id = ""
	result = ""
	if _menu_btn != null:
		_menu_btn.visible = false
	cur_line = -1
	audio_ok = false
	open_error = ""
	_hl = -2
	_last_sec = -1
	if _notice_box != null:
		UI.clear(_notice_box)
	SpeakDrill.hide_footer(_shell)
	if player != null:
		player.unload()


# ---------------------------------------------------------------- drawing

func _set_header(title: String, count: String) -> void:
	(_shell["title"] as Label).text = title
	(_shell["count"] as Label).text = count


func _build_bar() -> void:
	var root: VBoxContainer = _shell["root"]
	_bar = PanelContainer.new()
	_bar.name = "PlayBar"
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_bottom = 1
	_bar.add_theme_stylebox_override("panel", st)
	root.add_child(_bar)
	root.move_child(_bar, 1) # right under the head line
	var col := ColumnBox.new()
	col.max_width = 720.0
	col.min_pad = Ds.S3
	col.set_padding(Ds.S2, Ds.S2)
	_bar.add_child(col)
	var v := col.content
	v.add_theme_constant_override("separation", 6)
	var acc: Color = Pal.accent(lang)
	# transport row (wraps instead of overflowing at a large text size)
	var tr := UI.flow(8, 6)
	_btn_prev = UI.button("◀ 이전 줄", "soft", acc)
	_btn_prev.pressed.connect(func() -> void: step_line(-1))
	tr.add_child(_btn_prev)
	_btn_play = UI.button(PLAY_TEXT, "primary", acc)
	_btn_play.pressed.connect(toggle_play)
	tr.add_child(_btn_play)
	_btn_stop = UI.button("■ 정지", "soft", acc)
	_btn_stop.pressed.connect(stop_play)
	tr.add_child(_btn_stop)
	_btn_next = UI.button("다음 줄 ▶", "soft", acc)
	_btn_next.pressed.connect(func() -> void: step_line(1))
	tr.add_child(_btn_next)
	v.add_child(tr)
	var pr := UI.hbox(10)
	_progress = UI.progress_bar(0.0, acc, 6.0)
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(_progress)
	_time_label = UI.label("0:00 / 0:00", "Muted", false)
	pr.add_child(_time_label)
	v.add_child(pr)
	_speed_row = UI.flow(6, 6)
	v.add_child(_speed_row)
	_repeat_row = UI.flow(6, 6)
	v.add_child(_repeat_row)
	_tab_row = UI.flow(6, 6)
	_tab_row.name = "TabRow"
	v.add_child(_tab_row)
	_rebuild_tabs()
	_update_controls()


func _build_footer() -> void:
	var a: String = attribution_text()
	if a == "":
		return
	var row := SpeakDrill.new_footer_row(_shell)
	var l := UI.colored(a, Pal.MUTED, "Small")
	l.name = "Attribution"
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)


func _rebuild_speed() -> void:
	UI.clear(_speed_row)
	_speed_row.add_child(_row_label("속도"))
	for s in SongPlayer.SPEED_PRESETS:
		var sv: float = s
		var txt: String = ("%s배" % ("%.2f" % sv).rstrip("0").rstrip(".")) if absf(sv - 1.0) > 0.001 else "1배"
		var chip := UI.filter_chip(txt, absf(speed - sv) < 0.001, func() -> void: set_speed(sv))
		chip.name = "Speed%d" % int(roundf(sv * 100.0))
		_speed_row.add_child(chip)
	var kp := UI.filter_chip("음높이 유지", keep_pitch, func() -> void: set_keep_pitch(not keep_pitch))
	kp.name = "KeepPitch"
	_speed_row.add_child(kp)
	_update_controls()


func _rebuild_repeat() -> void:
	UI.clear(_repeat_row)
	_repeat_row.add_child(_row_label("줄 반복"))
	for r in REPEATS:
		var rv: int = r[0]
		var chip := UI.filter_chip(str(r[1]), repeat == rv, func() -> void: set_repeat(rv))
		chip.name = "Repeat%d" % rv
		_repeat_row.add_child(chip)
	_update_controls()


func _rebuild_tabs() -> void:
	if _tab_row == null:
		return
	UI.clear(_tab_row)
	for t in TABS:
		var kind: String = t[0]
		var chip := UI.filter_chip(str(t[1]), kind == tab, func() -> void: show_tab(kind))
		chip.name = "Tab_" + kind
		_tab_row.add_child(chip)
	_update_controls()


func _row_label(text: String) -> Label:
	var l := UI.label(text, "Muted", false)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


## 재생 버튼 글자와 눌림 가능 여부.
func _refresh_bar() -> void:
	if _btn_play == null:
		return
	if player != null and player.is_playing():
		_btn_play.text = PAUSE_TEXT
	elif player != null and player.is_paused():
		_btn_play.text = RESUME_TEXT
	else:
		_btn_play.text = PLAY_TEXT
	_update_time(player.position() if player != null else 0.0)


func _update_time(t: float) -> void:
	if _time_label == null:
		return
	var d: float = player.duration if player != null else 0.0
	_time_label.text = "%s / %s" % [_mmss(t), _mmss(d)]


static func _mmss(t: float) -> String:
	var s: int = maxi(int(t), 0)
	return "%d:%02d" % [s / 60, s % 60]


## 소리 파일을 못 읽었거나 곡이 없으면 재생 단추를 끄고, 그래도 폰에서 누를 만한 크기를 지킨다.
func _update_controls() -> void:
	var on: bool = audio_ok and not song.is_empty()
	for b in [_btn_prev, _btn_play, _btn_stop, _btn_next]:
		if b != null:
			(b as Button).disabled = not on
	if _bar != null:
		SpeakDrill.fit_touch(_bar)
		UI.fix_cjk(_bar)
