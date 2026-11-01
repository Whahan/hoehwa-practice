class_name TodayView
extends AppView
## 홈 (키 "today", 이름만 "홈"): 선택한 언어 하나로 오늘 할 일 카드(링 + 큰 시작 버튼 + 할 일 줄) -> 이어하기 -> 연속 -> AI 자리 -> 바로가기.
## 설계: docs/home_menu_design.md §7.1, §7.2, §7.7, §8.1~§8.5, §9.5, §9.6. 무엇을 보일지는 HomeModel(순수 계산)이 정하고
## 이 화면은 그리기만 한다. 설정은 SettingsView 가 따로 맡는다(이 화면에는 설정이 없다).

const WIDE_MIN := 980.0 ## PC: 본문 폭이 이 이상이면 두 열
const TICK_SEC := 30.0 ## 날짜 바뀜·변한 값 확인 주기
const SONG_GAP_SEC := 60 ## 홈이 보이는 동안 노래 집계를 다시 읽는 간격

var _scroll: PageScroll
var _body: BoxContainer ## 좁으면 VBox, 넓으면(PC, 폭 >= 980) HBox(왼쪽 VBox, 오른쪽 VBox)
var _built: bool = false
var _wide: bool = false
var _header: Control = null ## PC 의 큰 제목 블록(폰은 null)
var _lang_sw: Control = null
var _cards: Dictionary = {}
var _hero_btn: Button = null
var _task_btns: Array = []
var _ring: GoalRing = null
var _snap: Dictionary = {}
var _built_day: int = -1
var _last_frac: float = -1.0
var _song_due_shown: int = -1
var _song_thread: Thread = null
var _refresh_queued: bool = false
var _timer: Timer
## Tests only: (lang: String) -> Dictionary replaces HomeModel.snapshot(); anything that is not a Dictionary counts as {}.
var snapshot_hook: Callable = Callable()


func _ready() -> void:
	_scroll = PageScroll.new(960.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	Store.curriculum_updated.connect(_queue_refresh)
	Backend.status_changed.connect(_queue_refresh)
	_timer = Timer.new()
	_timer.wait_time = TICK_SEC
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	refresh()


func _exit_tree() -> void:
	if _song_thread != null:
		_song_thread.wait_to_finish()
		_song_thread = null


func refresh() -> void:
	if _scroll == null:
		return
	_start_song_scan(SongDue.MIN_GAP_SEC)
	rebuild_keep_scroll(_scroll, _build)


func _queue_refresh() -> void:
	if _refresh_queued or _scroll == null:
		return
	_refresh_queued = true
	_deferred_refresh.call_deferred()


func _deferred_refresh() -> void:
	_refresh_queued = false
	if is_visible_in_tree():
		refresh()


# ---------------------------------------------------------------- app bar contract (AppView)

# page_title() stays "" (the app bar shows the tab name "홈"); the shell adds the 설정 action itself.

func scroll_host() -> ScrollContainer:
	return _scroll


func header_block() -> Control:
	return _header if _header != null and is_instance_valid(_header) else null


# ---------------------------------------------------------------- public composition (design §9.5)

func is_wide() -> bool:
	return (not Platform.is_phone()) and size.x >= WIDE_MIN


## "tasks" | "resume" | "streak" | "ai" | "shortcuts"; null when that card is not shown.
func card(id: String) -> Control:
	var c: Variant = _cards.get(id, null)
	return c if (c != null and is_instance_valid(c)) else null


func hero_button() -> Button:
	return _hero_btn if _hero_btn != null and is_instance_valid(_hero_btn) else null


func task_buttons() -> Array:
	var out: Array = []
	for b in _task_btns:
		if is_instance_valid(b):
			out.append(b)
	return out


func lang_switch() -> Control:
	return _lang_sw if _lang_sw != null and is_instance_valid(_lang_sw) else null


func ring() -> GoalRing:
	return _ring if _ring != null and is_instance_valid(_ring) else null


## One row of the voice settings (kept here for the voice test; the settings screen builds it).
func _voice_row(l: String) -> Control:
	return SettingsView.voice_row(l)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _built and is_wide() != _wide:
		_queue_refresh()
	elif what == NOTIFICATION_APPLICATION_RESUMED and _built:
		_queue_refresh()


# ---------------------------------------------------------------- timer: day change, changed values, song scan

## The local date changed since the page was drawn -> draw it again. Returns true when it did.
func _check_day() -> bool:
	if _built_day >= 0 and StudyLog.today() != _built_day:
		refresh()
		return true
	return false


func _on_tick() -> void:
	if not is_visible_in_tree() or not _built:
		return
	if _check_day():
		return
	_start_song_scan(SONG_GAP_SEC)
	var fresh: Dictionary = _take_snapshot(Store.lang())
	var old: Dictionary = _snap.duplicate(true)
	fresh.erase("now")
	old.erase("now")
	if fresh != old:
		refresh()


## SongDue.scan() on a thread (it only reads); the song row is drawn again when the number of lines changed.
func _start_song_scan(min_gap: int) -> void:
	if _song_thread != null or not is_inside_tree() or not is_visible_in_tree():
		return
	if not SongDue.needs_scan(int(Time.get_unix_time_from_system()), min_gap):
		return
	_song_thread = Thread.new()
	_song_thread.start(_scan_in_thread)


func _scan_in_thread() -> void:
	SongDue.scan()
	_song_scan_done.call_deferred()


func _song_scan_done() -> void:
	if _song_thread != null:
		_song_thread.wait_to_finish()
		_song_thread = null
	if is_inside_tree() and _built and SongDue.due_lines() != _song_due_shown:
		refresh()


# ---------------------------------------------------------------- build

func _build() -> void:
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	_cards.clear()
	_task_btns.clear()
	_hero_btn = null
	_ring = null
	_header = null
	var phone: bool = Platform.is_phone()
	_wide = is_wide()
	var lang: String = Store.lang()
	_snap = _take_snapshot(lang)
	_built_day = StudyLog.today()
	_song_due_shown = int(_snap.get("song_due", 0))
	var pos: Dictionary = Store.position()

	var greet: Control = _greeting()
	_lang_sw = UI.lang_segmented(lang, func(v: String) -> void:
		if v != Store.lang():
			Store.set_lang(v)
			refresh())
	if phone:
		c.add_child(greet)
		c.add_child(_lang_sw)
	else:
		_header = PageHeader.build("홈", _subtitle(pos))
		for k in ["title_label", "subtitle_label"]: # text only: the finger goes through to the page
			if _header.has_meta(k):
				(_header.get_meta(k) as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var top := UI.hbox(Ds.S4)
		top.add_child(_header)
		_lang_sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(_lang_sw)
		c.add_child(top)
		c.add_child(greet)

	var tasks_card: Control = _tasks_card()
	var resume_card: Control = null
	var rs: Dictionary = HomeModel.resume(_snap)
	if not rs.is_empty():
		resume_card = HomeParts.resume_card(rs, func() -> void: _go(rs.get("target", {})))
		_cards["resume"] = resume_card
	var streak_card: Control = HomeParts.streak_card(lang, _snap, func() -> void:
		Store.toggle_today(lang)
		refresh())
	_cards["streak"] = streak_card
	var ai_card: Control = null
	var slot: Dictionary = HomeAi.slot()
	var ai_prominent: bool = bool(slot.get("prominent", false))
	if bool(slot.get("show", false)) and (ai_prominent or not HomeAi.dismissed_today()):
		ai_card = HomeParts.ai_card(slot, func() -> void: Store.request_ai_connect(), func() -> void:
			HomeAi.dismiss_today()
			refresh())
		_cards["ai"] = ai_card
	_cards["tasks"] = tasks_card
	for k in _cards.keys():
		(_cards[k] as Node).set_meta("card_id", k)

	var gap: int = Ds.S3 if phone else Ds.S4
	if _wide:
		_body = HBoxContainer.new()
		_body.add_theme_constant_override("separation", Ds.S4)
		var left := UI.vbox(gap)
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var right := UI.vbox(gap)
		right.custom_minimum_size.x = Ds.HOME_RIGHT_W
		if ai_card != null and ai_prominent:
			left.add_child(ai_card)
		left.add_child(tasks_card)
		if resume_card != null:
			left.add_child(resume_card)
		right.add_child(streak_card)
		if ai_card != null and not ai_prominent:
			right.add_child(ai_card)
		_body.add_child(left)
		_body.add_child(right)
	else:
		_body = VBoxContainer.new()
		_body.add_theme_constant_override("separation", gap)
		if ai_card != null and ai_prominent:
			_body.add_child(ai_card)
		_body.add_child(tasks_card)
		if resume_card != null:
			_body.add_child(resume_card)
		_body.add_child(streak_card)
		if ai_card != null and not ai_prominent:
			_body.add_child(ai_card)
		if phone:
			var sc: Control = HomeParts.shortcut_tiles(func(view: String) -> void: Store.navigate.emit(view, Store.lang()))
			_cards["shortcuts"] = sc
			sc.set_meta("card_id", "shortcuts")
			_body.add_child(sc)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(_body)
	UI.fix_cjk(c)
	_built = true
	bar_changed.emit() # the big title block was rebuilt


func _take_snapshot(lang: String) -> Dictionary:
	var v: Variant = snapshot_hook.call(lang) if snapshot_hook.is_valid() else HomeModel.snapshot(lang)
	return (v as Dictionary).duplicate(true) if v is Dictionary else {}


## One line under the big title (PC): stage and week (nothing before the start day: the greeting says it).
func _subtitle(pos: Dictionary) -> String:
	var phase: String = pos["phase"]
	if phase == "before":
		return ""
	if phase == "after":
		return "1년 완주"
	var n: int = pos["n"]
	return "%d단계 · %d개월차 %d주차" % [Plan.stage_of(n), n, int(pos["w"])]


## The greeting line (HomeModel.message): a drawn mark in front (check / exclamation / dot) so the kind is not colour only.
func _greeting() -> Control:
	var m: Dictionary = HomeModel.message(_snap)
	var kind: String = str(m.get("kind", "info"))
	var row := UI.hbox(Ds.S2)
	row.add_child(HomeParts.kind_mark(kind, 22.0))
	var l := UI.label(str(m.get("text", "")), "Strong")
	l.add_theme_color_override("font_color", {"warn": Pal.WARN_ON, "ok": Pal.OK_ON}.get(kind, Pal.INK))
	row.add_child(l)
	row.set_meta("kind", kind)
	row.set_meta("text", l.text)
	return row


# ---------------------------------------------------------------- tasks card (ring + start button + rows)

func _tasks_card() -> Control:
	var phone: bool = Platform.is_phone()
	var tasks: Array = HomeModel.tasks(_snap)
	var hero: Dictionary = HomeModel.hero(_snap)
	var card := UI.card("Card", Ds.S3)

	var head := UI.hbox(Ds.S4)
	var ttl := UI.vbox(4)
	ttl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ttl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ttl.add_child(UI.label("오늘 할 일", "H2"))
	ttl.add_child(UI.label(HomeParts.summary_text(tasks), "Small"))
	head.add_child(ttl)
	head.add_child(_make_ring())
	card.body.add_child(head)

	var hb := UI.button(str(hero.get("text", "")), "primary", Pal.PRIMARY, Ds.HOME_CTA_H_PHONE if phone else Ds.HOME_CTA_H_PC)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_theme_font_size_override("font_size", Ds.fs(18))
	var play := GlyphIcon.new("play", 22.0, Pal.ON_ACCENT)
	play.anchor_top = 0.5
	play.anchor_bottom = 0.5
	play.offset_top = -11.0
	play.offset_bottom = 11.0
	play.offset_left = 18.0
	play.offset_right = 40.0
	hb.add_child(play)
	var target: Dictionary = hero.get("target", {})
	hb.pressed.connect(func() -> void: _go(target))
	card.body.add_child(hb)
	_hero_btn = hb

	var rows := UI.vbox(0)
	for t in tasks:
		var tt: Dictionary = t
		var row: Control = HomeParts.task_row(tt, func() -> void: _go(tt.get("target", {})))
		rows.add_child(row)
		_task_btns.append(row.get_meta("button"))
	card.body.add_child(rows)
	return card


## The goal ring: hours of today against the daily goal (never the share of rows done). Off (goal 0) = text only.
func _make_ring() -> Control:
	var goal: int = int(_snap.get("goal_min", 0))
	var sec: int = int(_snap.get("sec_today", 0))
	var r := GoalRing.new()
	_ring = r
	if goal <= 0:
		r.setup(0.0, "오늘 %d분" % (sec / 60), false, false, "오늘 공부 %d분" % (sec / 60))
		_last_frac = -1.0
		return r
	var frac: float = clampf(float(sec) / float(goal * 60), 0.0, 1.0)
	var reached: bool = HomeModel.goal_reached(_snap)
	r.setup(frac, "%d/%d분" % [mini(sec / 60, goal), goal], reached, true, "오늘 목표 %d분 중 %d분" % [goal, sec / 60])
	if reached and _last_frac >= 0.0 and _last_frac < 1.0:
		r.animate_from(_last_frac) # the moment the goal was filled: one 400 ms sweep
	_last_frac = frac
	return r


# ---------------------------------------------------------------- navigation

## target = {"view", "args"}. Lesson: navigate_args (lang, n, w, start); the others: navigate(view, lang).
func _go(target: Variant) -> void:
	if not (target is Dictionary):
		return
	var view: String = str((target as Dictionary).get("view", ""))
	var args: Variant = (target as Dictionary).get("args", {})
	if view == "" or not (args is Dictionary):
		return
	var lang: String = str((args as Dictionary).get("lang", Store.lang()))
	if view == "lesson":
		Store.navigate_args.emit(view, (args as Dictionary).duplicate())
	else:
		Store.navigate.emit(view, lang)
