class_name PracticeView
extends AppView
## 연습 허브: 미션 · 쉐도잉 · 받아쓰기 · 약한 소리 카드 4개. 카드를 누르면 하위 화면을 열고,
## 하위 화면이 `closed` 신호를 보내면 허브로 돌아온다 (계약: 설계 8.3).
##
## 다른 화면에서 특정 항목으로 보내기: PracticeView.pending = {"kind": "phoneme", "p": "θ"}; Store.navigate.emit("practice", lang)

const KINDS := ["mission", "shadow", "dictation", "phoneme"]
const OLD_SERVER_TEXT := "PC 프로그램을 최신 버전으로 업데이트해 주세요. 이 서버에는 아직 연습 기능이 없어요."

## kind ∈ mission|shadow|dictation|phoneme, 쉐도잉·약한 소리는 선택 인자(source, p)를 같이 둘 수 있다.
static var pending: Dictionary = {}

var lang: String = "en"
var old_server: bool = false

var _page: PageScroll
var _screen: Control = null
var _screen_kind: String = ""
var _grid: GridContainer = null
var _cards: Dictionary = {} ## kind -> 시작 버튼
var _weak_buttons: Array = []
var _ping_call = null
var _serial: int = 0


func _ready() -> void:
	_page = PageScroll.new(960.0)
	_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_page)
	lang = Store.lang()
	if not Store.prefs_changed.is_connected(_on_prefs_changed):
		Store.prefs_changed.connect(_on_prefs_changed)
	_build()


func _exit_tree() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_ping_call)
	_ping_call = null
	if Store.prefs_changed.is_connected(_on_prefs_changed):
		Store.prefs_changed.disconnect(_on_prefs_changed)


func refresh() -> void:
	lang = Store.lang()
	if not pending.is_empty():
		_consume_pending() # 하위 화면이 열려 있어도 pending 은 반드시 소비한다 (열린 화면은 닫고 새로 연다)
		return
	if _screen != null:
		return
	_build()
	_ping()


func on_hide() -> void:
	if _screen != null and is_instance_valid(_screen) and _screen.has_method("on_hide"):
		_screen.call("on_hide")


func current_screen() -> Control:
	return _screen


func card_kinds() -> Array:
	return _cards.keys()


## 안드로이드 뒤로 가기: 하위 화면이 열려 있으면 한 단계 뒤로 (처리했으면 true).
func go_back() -> bool:
	if _screen == null:
		return false
	if _screen.has_method("go_back"):
		if bool(_screen.call("go_back")):
			return true
	_close_screen()
	return true


func _on_prefs_changed() -> void:
	var l: String = Store.lang()
	if l == lang:
		return
	lang = l
	if _screen != null:
		_close_screen() # 언어가 바뀌면 열려 있던 화면은 닫는다 (진행 중 요청은 화면이 취소)
	elif is_inside_tree():
		_build()


func _consume_pending() -> void:
	var p: Dictionary = pending
	pending = {}
	var kind: String = str(p.get("kind", ""))
	var args: Dictionary = p.duplicate()
	args.erase("kind")
	if KINDS.has(kind):
		open_screen(kind, args) # 열린 화면이 있으면 open_screen 이 on_hide 를 부르고 닫는다
	elif _screen != null:
		_close_screen() # 알 수 없는 kind: 열린 화면은 닫고 허브로
	else:
		_build()


# ---------------------------------------------------------------- sub screens

func open_screen(kind: String, args: Dictionary = {}) -> void:
	if _screen != null:
		_close_screen()
	var s: Control
	match kind:
		"mission":
			s = MissionScreen.new()
		"shadow":
			s = ShadowScreen.new()
		"dictation":
			s = DictationScreen.new()
		"phoneme":
			s = PhonemeScreen.new()
		_:
			return
	_screen = s
	_screen_kind = kind
	_page.visible = false
	add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.connect("closed", _close_screen)
	s.call("open", lang, args)


func _close_screen() -> void:
	if _screen == null:
		return
	var s: Control = _screen
	_screen = null
	_screen_kind = ""
	if is_instance_valid(s):
		if s.has_method("on_hide"):
			s.call("on_hide")
		if s.get_parent() == self:
			remove_child(s)
		s.queue_free()
	if _page != null:
		_page.visible = true
	_build()


# ---------------------------------------------------------------- hub

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_apply_columns()


func _apply_columns() -> void:
	if _grid != null and is_instance_valid(_grid):
		_grid.columns = 2 if size.x >= 700.0 else 1


func _build() -> void:
	if _page == null:
		return
	var c: VBoxContainer = _page.content
	UI.clear(c)
	_cards = {}
	_weak_buttons = []
	_grid = null
	var acc: Color = Pal.accent(lang)

	var top := UI.hbox(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		_build()))
	top.add_child(UI.spacer())
	SpeakDrill.fit_touch(top)
	c.add_child(top)

	var head := UI.vbox(4)
	head.add_child(UI.label("연습", "H2"))
	head.add_child(UI.label("미션으로 대화하고, 쉐도잉과 받아쓰기로 귀와 입을 훈련하고, 약한 소리를 집중해서 고쳐요.", "Muted"))
	c.add_child(head)

	if old_server:
		c.add_child(SpeakDrill.notice(OLD_SERVER_TEXT))

	_grid = GridContainer.new()
	_grid.columns = 2 if size.x >= 700.0 else 1
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(_grid)

	_grid.add_child(_card("mission", "롤플레이 미션", "카페, 호텔, 길 묻기 같은 상황에서 AI와 대화하며 목표를 하나씩 채워요.", "미션 고르기", true, null))
	_grid.add_child(_card("shadow", "쉐도잉", "원어민 목소리를 듣고 바로 따라 말해요. 점수와 억양 그래프를 보여 줘요.", "쉐도잉 시작", true, null))
	var en_only: bool = lang == "en"
	_grid.add_child(_card("dictation", "받아쓰기", "문장을 듣고 직접 타자로 써요. 단어마다 맞고 틀린 것을 알려 줘요." if en_only else "받아쓰기는 영어만 지원해요.", "받아쓰기 시작", en_only, null))
	_grid.add_child(_card("phoneme", "약한 소리", "자주 틀리는 소리만 모아 집중 연습해요." if en_only else "약한 소리 연습은 영어만 지원해요.", "약한 소리 연습", en_only, _weak_box() if en_only else null))
	UI.fix_cjk(c)
	_apply_columns()


func _card(kind: String, title: String, desc: String, btn_text: String, enabled: bool, extra: Control) -> CardBox:
	var card := UI.card("Card", 10)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.body.add_child(UI.label(title, "H3"))
	card.body.add_child(UI.label(desc, "Muted"))
	if extra != null:
		card.body.add_child(extra)
	var b := UI.button(btn_text, "primary", Pal.accent(lang), 48)
	b.disabled = not enabled
	b.pressed.connect(func() -> void: open_screen(kind))
	card.body.add_child(b)
	_cards[kind] = b
	return card


## 약한 소리 카드의 위쪽 3개 칩: 누르면 그 소리 연습으로 바로 간다.
func _weak_box() -> Control:
	var box := UI.vbox(8)
	var weak: Array = PhonemeScreen.weak_list(lang, 3)
	if weak.is_empty():
		box.add_child(UI.label("아직 약한 소리를 찾지 못했어요. 레슨이나 쉐도잉에서 따라 말하면 찾아 줘요.", "Small"))
		return box
	box.add_child(UI.label("지금 약한 소리 (최근 30회 기준)", "Small"))
	var fl := UI.flow(8, 8)
	for it in weak:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var p: String = str(d.get("p", ""))
		if p == "":
			continue
		var b := UI.button("%s  틀림 %d%%" % [PhonemeScreen.short_label(p), PhonemeScreen.rate_pct(d)], "soft", Pal.BAD, 44)
		b.add_theme_font_override("font", Ipa.font(true))
		b.pressed.connect(func() -> void: open_screen("phoneme", {"p": p}))
		fl.add_child(b)
		_weak_buttons.append(b)
	box.add_child(fl)
	return box


# ---------------------------------------------------------------- server version check

func _ping() -> void:
	SpeakDrill.cancel_call(_ping_call)
	_serial += 1
	var serial: int = _serial
	var req: Object = SpeakDrill.request("/practice/ping", null, 10.0)
	_ping_call = req
	var res: Dictionary = await req.wait()
	if serial != _serial:
		return
	_ping_call = null
	if bool(res.get("cancelled", false)):
		return
	var was_old: bool = old_server
	old_server = int(res.get("code", 0)) == 404 and not bool(res.get("ok", false))
	if bool(res.get("ok", false)):
		old_server = false
	if old_server != was_old and _screen == null:
		_build()
