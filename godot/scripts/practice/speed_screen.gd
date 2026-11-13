class_name SpeedScreen
extends Control
## 60초 스피드 퀴즈 화면 (영어 / 일본어). docs/v160_fun_design.md §4.3, §5.8.
##   시작 : 최고 기록 · 준비된 단어 수 · [시작]. 풀이 작으면(SpeedPool.MIN_POOL 미만) 시작을 끄고 안내.
##   진행 : 남은 시간 · 점수 · 시간 바 · 콤보 · 단어 + 보기 4개(2x2). 정답 0.35초 / 오답 0.9초 보여 주고 다음 문제.
##   결과 : 점수 · 새 기록 · 정답률 · 최고 콤보 · 틀린 단어 · [복습 카드로 추가] · [다시 도전] · [나가기].
## 규칙(점수 · 콤보 · 시간)은 SpeedLogic, 문제 재료는 SpeedPool. 이 화면은 시계를 넣어 주고(매 프레임 tick) 그림을 그린다.
##  - 시계는 `clock: Callable -> int(ms)` 훅(없으면 Time.get_ticks_msec()). 시험은 가짜 시계를 넣고 step() 을 직접 부른다.
##  - 폰이 백그라운드로 가거나(NOTIFICATION_APPLICATION_PAUSED) 창이 포커스를 잃거나 화면이 가려지거나 "그만할까요?" 시트가
##    열려 있으면 시간이 멈춘다(이유별로 따로 센다. 모두 풀려야 이어진다).
##  - 복습 일정(카드의 반복 횟수 · 마감)은 바꾸지 않는다. 틀린 단어는 결과에서 [복습 카드로 추가]를 눌러야만 카드가 된다.
## 연습 허브 하위 화면 계약: `signal closed`, `open(lang, args)`, `go_back() -> bool`, `on_hide()`.

signal closed

const TITLE := "60초 스피드 퀴즈"
const OK_SHOW_MS := 350          ## 정답을 보여 주는 시간
const OPTION_MIN_H := 72.0
const LOW_TIME_MS := 10000       ## 남은 시간이 이보다 적으면 시간 바가 경고색
const NOTE_TEXT := "스피드 퀴즈"  ## 복습 카드 note

var lang: String = "en"
var stage: String = "start"      ## start | play | result | unsupported
var rng := RandomNumberGenerator.new()
var logic: SpeedLogic = null
var pool: Dictionary = {}        ## SpeedPool.build 결과
var words_ok: bool = true        ## data/speed_words.json 을 읽었나
var words_err: String = ""
var clock: Callable = Callable()          ## () -> int (ms). 시험용.
var words_hook: Callable = Callable()     ## (lang) -> SpeedPool.load_words 모양. 시험용.

var option_buttons: Array = []
var start_button: Button = null
var unverified_note: Label = null
var quit_sheet: Sheet = null
var new_record_row: Control = null
var added_cards: int = 0
var review_pressed: bool = false
var run_result: Dictionary = {}  ## 끝난 판의 SpeedLogic.result()
var run_record: Dictionary = {}  ## StudyLog.add_speed_run 결과 {recorded, new_best, prev_best}
var finish_count: int = 0        ## 기록을 남긴 횟수 (시험용: 한 판에 한 번)

var _shell: Dictionary = {}
var _finished: bool = false
var _pause_reasons: Dictionary = {}
var _advance_at: int = -1        ## 이 시각이 되면 다음 문제로 (-1 = 없음)
var _advance_left: int = -1      ## 정지 동안 남은 보여 주기 시간
var _picked: int = -1
var _combo_now: int = 0
var _last_answer: Dictionary = {}
var _time_label: Label = null
var _score_label: Label = null
var _combo_label: Label = null
var _pause_label: Label = null
var _feedback_label: Label = null
var _bar: ProgressBar = null
var _bar_low: bool = false
var _shown_sec: int = -1


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)
	rng.randomize()
	set_process(true)


func _exit_tree() -> void:
	StudyLog.flush()


## 허브가 연다. 알 수 없는 언어는 안전한 안내 화면.
func open(l: String, _args: Dictionary = {}) -> void:
	lang = l
	_reset_run()
	if lang != "en" and lang != "ja":
		stage = "unsupported"
		_render()
		return
	_prepare_pool()
	stage = "start"
	_render()


func on_hide() -> void:
	_set_pause("hidden", true)
	StudyLog.flush()


## 뒤로: 진행 중이면 "그만할까요?" 시트, 그 밖에는 허브로.
func go_back() -> bool:
	if stage == "play":
		_ask_quit()
		return true
	closed.emit()
	return true


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_set_pause("app", true)
		NOTIFICATION_APPLICATION_RESUMED:
			_set_pause("app", false)
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_set_pause("focus", true)
		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_set_pause("focus", false)
		NOTIFICATION_VISIBILITY_CHANGED:
			if is_inside_tree():
				_set_pause("hidden", not is_visible_in_tree())


func _unhandled_key_input(event: InputEvent) -> void:
	if stage != "play" or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	var i: int = int(k.keycode) - int(KEY_1)
	if i >= 0 and i < SpeedPool.OPTIONS_N:
		answer(i)


func _process(_delta: float) -> void:
	if stage == "play":
		step()


func _reset_run() -> void:
	logic = null
	_finished = false
	_pause_reasons = {}
	_advance_at = -1
	_advance_left = -1
	_picked = -1
	_combo_now = 0
	_last_answer = {}
	added_cards = 0
	review_pressed = false
	run_result = {}
	run_record = {}
	option_buttons = []
	start_button = null
	unverified_note = null
	new_record_row = null
	_clear_hud()
	if quit_sheet != null and is_instance_valid(quit_sheet):
		quit_sheet.close("dismiss")
	quit_sheet = null


func _clear_hud() -> void:
	_time_label = null
	_score_label = null
	_combo_label = null
	_pause_label = null
	_feedback_label = null
	_bar = null
	_bar_low = false
	_shown_sec = -1


func _now() -> int:
	if clock.is_valid():
		return int(clock.call())
	return Time.get_ticks_msec()


func _acc() -> Color:
	return Pal.accent(lang)


## 풀(카드 + 레슨 단어)을 새로 만든다. 단어 파일을 못 읽어도(카드만으로) 시작할 수 있으면 시작한다.
func _prepare_pool() -> void:
	var w: Dictionary = {}
	if words_hook.is_valid():
		var hv: Variant = words_hook.call(lang)
		if hv is Dictionary:
			w = hv
	else:
		w = SpeedPool.load_words(lang)
	words_ok = bool(w.get("ok", false))
	words_err = str(w.get("err", "")) if not words_ok else ""
	var words: Array = []
	var wv: Variant = w.get("words", [])
	if words_ok and wv is Array:
		words = wv
	var month: int = int(Store.position().get("n", 1))
	pool = SpeedPool.build(lang, Store.review_for(lang), month, words)


func pool_ok() -> bool:
	return bool(pool.get("ok", false))


# ---------------------------------------------------------------- a run

## 한 판을 시작한다. rng_seed >= 0 이면 문제 뽑기를 고정한다(시험용). 풀이 모자라면 false.
func start_run(rng_seed: int = -1) -> bool:
	if stage == "unsupported" or not pool_ok():
		return false
	if rng_seed >= 0:
		rng.seed = rng_seed
	var items: Array = pool["items"]
	var lg := SpeedLogic.new(items, rng)
	if lg.current().is_empty():
		return false
	if quit_sheet != null and is_instance_valid(quit_sheet):
		quit_sheet.close("dismiss")
	quit_sheet = null
	logic = lg
	_finished = false
	_pause_reasons = {}
	_advance_at = -1
	_advance_left = -1
	_picked = -1
	_combo_now = 0
	_last_answer = {}
	added_cards = 0
	review_pressed = false
	run_result = {}
	run_record = {}
	logic.start(_now())
	stage = "play"
	_render()
	return true


func current() -> Dictionary:
	return logic.current() if logic != null else {}


func remaining_ms() -> int:
	return logic.remaining_ms(_now()) if logic != null else SpeedLogic.LIMIT_MS


func is_paused() -> bool:
	return not _pause_reasons.is_empty()


func pause_reasons() -> Array:
	return _pause_reasons.keys()


## 보기 i 를 골랐다. 받아들여졌으면 true. 끝난 뒤 · 결과 화면 · 잠금 중 · 정지 중 · 이미 답함 -> false.
func answer(i: int) -> bool:
	if stage != "play" or logic == null or is_paused():
		return false
	var r: Dictionary = logic.answer(i, _now())
	if not bool(r.get("accepted", false)):
		step() # 시간이 끝난 뒤 눌렀다면 바로 결과로
		return false
	_picked = i
	_last_answer = r
	_advance_at = _now() + (OK_SHOW_MS if bool(r["ok"]) else SpeedLogic.WRONG_LOCK_MS)
	_paint_answer()
	return true


## 한 걸음: 시간이 끝났으면 결과로, 보여 주기가 끝났으면 다음 문제로, 아니면 시간 표시만 갱신. _process 가 매 프레임 부른다.
func step() -> void:
	if stage != "play" or logic == null or is_paused():
		return
	var now := _now()
	if logic.tick(now):
		finish()
		return
	if _advance_at >= 0 and now >= _advance_at:
		_advance()
		if stage != "play":
			return
	_update_time(now)


func _advance() -> void:
	_advance_at = -1
	_picked = -1
	_last_answer = {}
	logic.next_question()
	if logic.current().is_empty():
		finish()
		return
	_render_play()


## 결과로. 기록은 한 판에 한 번만 남긴다 (두 번 불러도 무시).
func finish() -> void:
	if stage != "play" or _finished or logic == null:
		return
	_finished = true
	_pause_reasons = {}
	var r: Dictionary = logic.result()
	run_result = r
	var total: int = int(r["total"])
	run_record = StudyLog.add_speed_run(lang, int(r["score"]), int(r["correct"]), total, int(r["combo"]))
	if total >= StudyLog.SPEED_MIN_ANSWERED:
		StudyLog.add_event(lang, "drill", 1)
		Store.mark_today(lang)
		Store.save_progress()
	StudyLog.flush()
	finish_count += 1
	Store.note_activity("speed")
	stage = "result"
	_render()


# ---------------------------------------------------------------- pause

## 정지 이유 하나를 켜고 끈다. 이유가 하나라도 있으면 시계가 멈추고, 모두 풀리면 이어진다.
func _set_pause(reason: String, on: bool) -> void:
	var before := is_paused()
	if on:
		_pause_reasons[reason] = true
	else:
		_pause_reasons.erase(reason)
	var after := is_paused()
	if before == after or stage != "play" or logic == null:
		return
	var now := _now()
	if after:
		logic.pause(now)
		_advance_left = maxi(0, _advance_at - now) if _advance_at >= 0 else -1
	else:
		logic.resume(now)
		if _advance_left >= 0:
			_advance_at = now + _advance_left
		_advance_left = -1
	_update_pause_note()


func _ask_quit() -> void:
	if quit_sheet != null and is_instance_valid(quit_sheet) and Sheet.is_open():
		return
	_set_pause("sheet", true)
	var sh: Sheet = Sheet.confirm(self, "그만할까요?", "지금까지의 점수는 기록되지 않아요.", "그만두기", true, "계속")
	quit_sheet = sh
	sh.closed.connect(func(res: Variant) -> void:
		if quit_sheet == sh:
			quit_sheet = null
		if str(res) == "ok":
			_quit_run()
		else:
			_set_pause("sheet", false))


## 기록 없이 그만둔다 -> 허브로.
func _quit_run() -> void:
	logic = null
	_finished = false
	_pause_reasons = {}
	_advance_at = -1
	_clear_hud()
	stage = "start"
	_prepare_pool()
	_render()
	closed.emit()


# ---------------------------------------------------------------- drawing

func _render() -> void:
	var page: PageScroll = _shell["page"]
	var c: VBoxContainer = page.content
	page.scroll_vertical = 0
	UI.clear(c)
	option_buttons = []
	start_button = null
	unverified_note = null
	new_record_row = null
	_clear_hud()
	(_shell["title"] as Label).text = TITLE
	(_shell["count"] as Label).text = ""
	SpeakDrill.hide_footer(_shell)
	match stage:
		"unsupported":
			c.add_child(SpeakDrill.notice("스피드 퀴즈는 영어와 일본어에서 할 수 있어요. 위쪽 탭에서 언어를 골라 주세요.", false))
			var ub := SpeakDrill.touch_button("연습으로", "outline", _acc(), 48)
			ub.pressed.connect(func() -> void: closed.emit())
			c.add_child(ub)
		"start":
			_build_start(c)
		"play":
			_build_play(c)
		"result":
			_build_result(c)
	UI.fix_cjk(c)


static func fmt_num(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


func _build_start(c: VBoxContainer) -> void:
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.chip_kind("영어 English" if lang == "en" else "일본어 日本語", "lang_en" if lang == "en" else "lang_ja"))
	card.body.add_child(UI.label("내 복습 카드와 레슨 단어에서 뜻을 빨리 고르세요.", "H3"))
	var best: Dictionary = StudyLog.speed_best(lang)
	if best.is_empty():
		card.body.add_child(UI.label("아직 기록이 없어요. 첫 기록을 남겨 보세요.", "Muted"))
	else:
		card.body.add_child(UI.colored("최고 기록 %s점" % fmt_num(int(best["score"])), Pal.on(lang), "H2", false))
		card.body.add_child(UI.label("정답 %d / %d · 최고 콤보 %d" % [int(best["correct"]), int(best["total"]), int(best["combo"])], "Muted"))
	if pool_ok():
		var n_items: int = (pool["items"] as Array).size()
		card.body.add_child(UI.label("단어 %s개 준비됨 (복습 카드 %d장 · 레슨 단어 %d개)" % [fmt_num(n_items), int(pool["n_cards"]), int(pool["n_words"])], "Strong"))
		if bool(pool.get("mixed_unverified", false)):
			unverified_note = UI.colored("뜻이 가끔 틀릴 수 있어요.", Pal.WARN_ON, "Small")
			card.body.add_child(unverified_note)
	else:
		var have: int = int(pool.get("n_cards", 0)) + int(pool.get("n_words", 0))
		card.body.add_child(UI.label("지금 쓸 수 있는 단어는 %d개예요. %d개 이상 있어야 시작할 수 있어요." % [have, SpeedPool.MIN_POOL], "Strong"))
	c.add_child(card)
	if not pool_ok():
		c.add_child(SpeakDrill.notice("복습 카드를 더 모으거나 레슨을 해 보세요.", false))
		if not words_ok:
			c.add_child(UI.colored("레슨 단어 목록을 읽지 못했어요. 복습 카드만 쓸 수 있어요.", Pal.WARN_ON, "Small"))
	var rules := UI.card("Card", 6)
	rules.body.add_child(UI.label("60초 안에 최대한 많이 맞혀 보세요.", "Strong"))
	rules.body.add_child(UI.label("정답은 10점, 연속으로 맞히면 점수가 더 붙어요. 틀리면 0점이고 잠깐(0.9초) 쉬어요.", "Muted"))
	rules.body.add_child(UI.label("기록은 %d문제부터 남아요. 푼 결과는 복습 일정에 영향을 주지 않아요." % StudyLog.SPEED_MIN_ANSWERED, "Muted"))
	c.add_child(rules)
	start_button = SpeakDrill.touch_button("시작", "primary", acc, 56)
	start_button.disabled = not pool_ok()
	start_button.pressed.connect(func() -> void: start_run())
	c.add_child(start_button)


func _build_play(c: VBoxContainer) -> void:
	var acc := _acc()
	var hud := UI.hbox(8)
	_time_label = UI.label("", "Strong", false)
	_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud.add_child(_time_label)
	_score_label = UI.label("", "Strong", false)
	hud.add_child(_score_label)
	c.add_child(hud)
	_bar = UI.progress_bar(1.0, acc, 12.0)
	c.add_child(_bar)
	var crow := UI.hbox(8)
	var chip := UI.tinted_panel(Pal.REWARD_SOFT, Color(0, 0, 0, 0), 0, Ds.R_PILL, 12, 3)
	_combo_label = UI.colored("", Pal.REWARD_ON, "Strong", false)
	chip.add_child(_combo_label)
	crow.add_child(chip)
	_pause_label = UI.colored("멈췄어요", Pal.WARN_ON, "Small", false)
	_pause_label.visible = false
	_pause_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	crow.add_child(_pause_label)
	c.add_child(crow)
	_render_question_into(c)
	_update_scoreboard()
	_update_time(_now())
	_update_pause_note()


## 문제 카드 · 보기 · 피드백 줄만 다시 그린다(머리 줄은 그대로).
func _render_play() -> void:
	var page: PageScroll = _shell["page"]
	var c: VBoxContainer = page.content
	UI.clear(c)
	option_buttons = []
	_clear_hud()
	_build_play(c)
	UI.fix_cjk(c)


func _render_question_into(c: VBoxContainer) -> void:
	var q: Dictionary = logic.current()
	if q.is_empty():
		return
	var word: String = str(q["w"])
	var card := UI.card("BigCard", 6)
	var wl := UI.label(word, "Big", false)
	wl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var big: int = 44 if word.length() <= 8 else (34 if word.length() <= 14 else 26)
	wl.add_theme_font_size_override("font_size", UI.fs(big))
	card.body.add_child(wl)
	var rd: String = str(q.get("rd", ""))
	if lang == "ja" and rd != "" and rd != word:
		var rl := UI.label(rd, "Muted", false)
		rl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		rl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rl.add_theme_font_size_override("font_size", UI.fs(18))
		card.body.add_child(rl)
	c.add_child(card)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 10)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(g)
	var opts: Array = q["options"]
	for i in opts.size():
		var b := UI.option_row(str(opts[i]))
		b.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		b.add_theme_font_size_override("font_size", UI.fs(19))
		b.custom_minimum_size = Vector2(0, OPTION_MIN_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var n: int = i
		b.pressed.connect(func() -> void: answer(n))
		g.add_child(b)
		option_buttons.append(b)
	_feedback_label = UI.label(" ", "Strong")
	_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(_feedback_label)


func _update_scoreboard() -> void:
	if logic == null:
		return
	var r: Dictionary = logic.result()
	if _score_label != null:
		_score_label.text = "점수 %s" % fmt_num(int(r["score"]))
	if _combo_label != null:
		_combo_label.text = "콤보 x%d" % _combo_now


func _update_time(now: int) -> void:
	if logic == null:
		return
	var rem: int = logic.remaining_ms(now)
	var sec: int = ceili(float(rem) / 1000.0)
	if _time_label != null and sec != _shown_sec:
		_shown_sec = sec
		_time_label.text = "남은 시간 %d초" % sec
	if _bar != null:
		_bar.value = clampf(float(rem) / float(SpeedLogic.LIMIT_MS), 0.0, 1.0)
		var low: bool = rem <= LOW_TIME_MS
		if low != _bar_low:
			_bar_low = low
			_bar.add_theme_stylebox_override("fill", UI.style(Pal.BAD if low else _acc(), Color(0, 0, 0, 0), 0, Ds.R_PILL, 0, 0))


func _update_pause_note() -> void:
	if _pause_label != null and is_instance_valid(_pause_label):
		_pause_label.visible = is_paused()


## 고른 보기 · 정답 보기에 도형(체크 / 가위표)과 색, 피드백 줄, 점수 · 콤보.
func _paint_answer() -> void:
	var q: Dictionary = logic.current()
	if q.is_empty() or _last_answer.is_empty():
		return
	var ci: int = int(_last_answer["correct_index"])
	var ok: bool = bool(_last_answer["ok"])
	_combo_now = int(_last_answer["combo"])
	for i in option_buttons.size():
		var b: Button = option_buttons[i]
		if not is_instance_valid(b):
			continue
		var kind := ""
		if i == ci:
			UI.paint_option(b, "right", _acc())
			kind = "check"
		elif i == _picked:
			UI.paint_option(b, "wrong", _acc())
			kind = "close"
		if kind != "":
			_add_mark(b, kind)
	if _feedback_label != null and is_instance_valid(_feedback_label):
		if ok:
			_feedback_label.text = "정답! +%d점" % int(_last_answer["points"])
			_feedback_label.add_theme_color_override("font_color", Pal.OK_ON)
		else:
			_feedback_label.text = "아쉬워요. 정답은 '%s'" % str(q["ko"])
			_feedback_label.add_theme_color_override("font_color", Pal.BAD_ON)
	_update_scoreboard()


func _add_mark(b: Button, kind: String) -> void:
	var g := GlyphIcon.new(kind, 24.0, Pal.OK if kind == "check" else Pal.BAD)
	g.name = "Mark"
	g.anchor_left = 1.0
	g.anchor_right = 1.0
	g.anchor_top = 0.5
	g.anchor_bottom = 0.5
	g.offset_left = -38.0
	g.offset_right = -14.0
	g.offset_top = -12.0
	g.offset_bottom = 12.0
	b.add_child(g)
	for n in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var sbx: StyleBox = b.get_theme_stylebox(n).duplicate()
		sbx.content_margin_right = 44.0
		b.add_theme_stylebox_override(n, sbx)


## 보기 i 에 붙은 도형 종류("check" | "close" | "").
func option_mark(i: int) -> String:
	if i < 0 or i >= option_buttons.size() or not is_instance_valid(option_buttons[i]):
		return ""
	for ch in (option_buttons[i] as Button).get_children():
		if ch is GlyphIcon:
			return (ch as GlyphIcon).kind
	return ""


# ---------------------------------------------------------------- result

func new_record_shown() -> bool:
	return new_record_row != null and is_instance_valid(new_record_row)


## 틀린 단어를 복습 카드로 (target 단어, reading 읽기, ko 뜻, note "스피드 퀴즈"). 이미 있는 카드는 건너뛴다. 새 카드 수를 돌려준다.
func add_wrong_to_review() -> int:
	var items: Array = []
	for w in (run_result.get("wrong", []) as Array):
		var d: Dictionary = w
		items.append({"lang": lang, "target": str(d["w"]), "reading": str(d.get("rd", "")), "ko": str(d["ko"]), "note": NOTE_TEXT})
	if items.is_empty():
		return 0
	var n: int = Store.add_review(items)
	if n > 0:
		Store.save_progress()
	added_cards += n
	review_pressed = true
	return n


func _build_result(c: VBoxContainer) -> void:
	var acc := _acc()
	var r: Dictionary = run_result
	var score: int = int(r.get("score", 0))
	var total: int = int(r.get("total", 0))
	var correct: int = int(r.get("correct", 0))
	var recorded: bool = bool(run_record.get("recorded", false))
	var new_best: bool = bool(run_record.get("new_best", false)) and score > 0
	var prev_best: int = int(run_record.get("prev_best", 0))
	var card := UI.card("BigCard", 8)
	card.body.add_child(UI.label("결과", "Eyebrow", false))
	card.body.add_child(UI.colored("점수 %s" % fmt_num(score), Pal.on(lang), "H1", false))
	if new_best:
		var nr := UI.hbox(6)
		nr.add_child(GlyphIcon.new("star", 22.0, Pal.REWARD))
		var nl := UI.colored("새 기록!", Pal.REWARD_ON, "Strong", false)
		nl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nr.add_child(nl)
		card.body.add_child(nr)
		new_record_row = nr
		if prev_best > 0:
			card.body.add_child(UI.label("이전 최고 %s점" % fmt_num(prev_best), "Muted"))
	elif recorded and prev_best > 0:
		card.body.add_child(UI.label("최고 기록 %s점" % fmt_num(prev_best), "Muted"))
	var pct: int = roundi(100.0 * float(correct) / float(total)) if total > 0 else 0
	card.body.add_child(UI.label("정답 %d / %d (%d%%)" % [correct, total, pct], "Strong"))
	card.body.add_child(UI.label("최고 콤보 %d" % int(r.get("combo", 0)), "Strong"))
	if not recorded:
		card.body.add_child(UI.colored("기록은 %d문제부터 남아요." % StudyLog.SPEED_MIN_ANSWERED, Pal.WARN_ON, "Small"))
	c.add_child(card)

	var wrong: Array = r.get("wrong", [])
	var wc := UI.card("Card", 8)
	if wrong.is_empty():
		wc.body.add_child(UI.label("틀린 단어가 없어요. 잘했어요!" if total > 0 else "푼 문제가 없어요.", "Strong"))
	else:
		wc.body.add_child(UI.label("틀린 단어 %d개" % wrong.size(), "Strong"))
		for w in wrong:
			var d: Dictionary = w
			var row := UI.hbox(10)
			var wtxt: String = str(d["w"])
			var rd: String = str(d.get("rd", ""))
			if lang == "ja" and rd != "" and rd != wtxt:
				wtxt = "%s (%s)" % [wtxt, rd]
			var wl := UI.label(wtxt, "Strong")
			wl.size_flags_stretch_ratio = 1.0
			row.add_child(wl)
			var kl := UI.label(str(d["ko"]), "")
			kl.size_flags_stretch_ratio = 1.0
			row.add_child(kl)
			wc.body.add_child(row)
	c.add_child(wc)

	if not wrong.is_empty():
		var rb := SpeakDrill.touch_button("오답 %d개 복습 카드로" % wrong.size(), "primary", acc, 48)
		if review_pressed:
			rb.text = "복습 카드에 넣었어요 (새 카드 %d개)" % added_cards if added_cards > 0 else "이미 복습 카드에 있어요"
			rb.disabled = true
		else:
			rb.pressed.connect(func() -> void:
				add_wrong_to_review()
				_render())
		c.add_child(rb)
	var btns := UI.hbox(10)
	var again := SpeakDrill.touch_button("다시 도전", "primary", acc, 52)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.pressed.connect(func() -> void: retry())
	btns.add_child(again)
	var out := SpeakDrill.touch_button("나가기", "outline", acc, 52)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out.pressed.connect(func() -> void: closed.emit())
	btns.add_child(out)
	c.add_child(btns)


## [다시 도전]: 풀을 새로 만들어(복습 카드가 늘었을 수 있다) 바로 한 판 더.
func retry() -> bool:
	if stage != "result":
		return false
	_reset_run()
	_prepare_pool()
	stage = "start"
	if not start_run():
		_render()
		return false
	return true
