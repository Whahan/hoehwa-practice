class_name KanaScreen
extends Control
## 히라가나 · 가타카나 익히기 (일본어만).
##   표    : 50음도 표. 칸을 누르면 그 글자 소리가 난다. 칸마다 익힘 정도(맞힌/틀린 횟수)를 점으로 보여 준다.
##   설정  : 퀴즈 종류(글자 -> 소리 / 소리 -> 글자), 글자 종류, 행 범위, 헷갈리는 글자 집중 연습.
##   퀴즈  : 10문제, 보기 4개. 결과에서 틀린 글자를 복습 카드로 넣을 수 있다.
## 글자표 · 문제 만들기는 KanaData, 익힘 기록은 StudyLog.add_kana*, 복습 카드는 Store.add_review.
## 소리는 Tts (일본어). PC 엔진이면 서버 연결이 없을 때(Api.base_url == ""), 폰 시스템 음성 엔진이면 일본어 음성이
## 없을 때 Tts 를 부르지 않고 한 줄 안내만 보인다.
## 허브(PracticeView)는 이 화면을 `open("ja")` 로 열고 `closed` 신호로 돌아온다 (다른 연습 화면과 같은 계약).

signal closed

const MARK_TODAY_AT := 5
const NEXT_LOCK_MSEC := 250
const CELL_MIN_W := 48.0
const CELL_MIN_H := 64.0
const GRID_GAP := 6
const NO_SOUND_TEXT := "소리를 들으려면 PC와 연결해 주세요. 지금은 소리 없이 글자만 익힐 수 있어요."
const NO_VOICE_TEXT := "이 폰에 일본어 음성이 없어요. 폰 설정에서 일본어 음성 데이터를 내려받으면 소리를 들을 수 있어요. 지금은 소리 없이 글자만 익힐 수 있어요."
const TABLE_HINT := "글자를 누르면 소리가 나요."

## 허브에서 이 화면을 보여 줄 언어인지 (일본어 탭에서만).
static func available(l: String) -> bool:
	return l == "ja"


## 소리를 낼 수 있는지. 폰 시스템 음성 엔진이면 일본어 음성이 있는지, PC 엔진이면 PC 연결이 있는지
## (폰은 PC와 짝짓기 전에는 주소가 비어 있다).
static func sound_available() -> bool:
	if str(Tts.engine_now()) == "system":
		return bool(Tts.system_voices_ok().get("ja", false))
	return Api.base_url != ""


## 소리를 낼 수 없을 때 보여 줄 한 줄: 폰 음성 엔진이면 "일본어 음성 없음", PC 엔진이면 "PC 연결 필요".
static func no_sound_text() -> String:
	return NO_VOICE_TEXT if str(Tts.engine_now()) == "system" else NO_SOUND_TEXT


var lang: String = "ja"
var stage: String = "table" ## table | setup | quiz | result | unsupported
var table_script: String = "hira" ## 표에 보이는 글자 종류: hira | kata
var cfg: Dictionary = {"kind": "read", "script": "hira", "rows": [], "focus": false, "group": ""}
var rng := RandomNumberGenerator.new()
var questions: Array = []
var answers: Array = [] ## 문제마다 {picked: -1 = 아직, ok}
var idx: int = 0
var finished: bool = false
var added_cards: int = 0
var review_pressed: bool = false
var last_ch: String = "" ## 표에서 마지막으로 누른 글자
var sound_requests: int = 0 ## Tts 에 소리를 부탁한 횟수 (시험용)
var silent_requests: int = 0 ## 연결이 없어서 소리 없이 지나간 횟수 (시험용)

var cells: Dictionary = {} ## 표의 칸: 글자 -> Cell
var grids: Array = [] ## 표의 GridContainer 들
var option_buttons: Array = []

var _shell: Dictionary = {}
var _view_key: String = "" ## "단계:문제번호" -- 바뀌면 본문을 맨 위로 (스크롤이 남아 빈 화면이 되지 않게)
var _last_next_msec: int = -100000
var _feedback_box: VBoxContainer = null
var _marked_today: bool = false


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)
	rng.randomize()


func _exit_tree() -> void:
	StudyLog.flush()


## args: {script: "hira"|"kata"} 처음에 보일 글자 종류.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l
	Tts.stop()
	_reset()
	if not available(lang):
		stage = "unsupported"
		_render()
		return
	var s: String = str(args.get("script", ""))
	if s == "hira" or s == "kata":
		table_script = s
	stage = "table"
	_render()


func on_hide() -> void:
	Tts.stop()
	StudyLog.flush()


## 뒤로: 퀴즈 · 결과 · 설정 -> 표 -> 허브.
func go_back() -> bool:
	match stage:
		"quiz", "result", "setup":
			Tts.stop()
			stage = "table"
			_render()
			return true
	closed.emit()
	return true


func _reset() -> void:
	questions = []
	answers = []
	idx = 0
	finished = false
	added_cards = 0
	review_pressed = false
	last_ch = ""
	_marked_today = false
	cells = {}
	grids = []
	option_buttons = []
	_feedback_box = null


func _acc() -> Color:
	return Pal.JA


# ---------------------------------------------------------------- sound

## 글자 하나를 읽어 준다. 연결이 없으면 소리 없이 지나가고 false.
func play_kana(ch: String) -> bool:
	if ch == "":
		return false
	if not sound_available():
		silent_requests += 1
		return false
	sound_requests += 1
	Tts.speak(ch, "ja", false)
	return true


# ---------------------------------------------------------------- table

## 칸을 눌렀을 때: 소리 + 아래 안내줄 갱신. 표는 다시 그리지 않는다.
func tap_cell(ch: String) -> void:
	if stage != "table" or not KanaData.has(ch):
		return
	last_ch = ch
	for k in cells.keys():
		var c: Variant = cells[k]
		if c is Cell and is_instance_valid(c):
			(c as Cell).set_selected(k == ch)
	play_kana(ch)
	_render_table_footer()


func cell_for(ch: String) -> Control:
	var c: Variant = cells.get(ch, null)
	return c if c is Cell and is_instance_valid(c) else null


func _render_table_footer() -> void:
	var row: HBoxContainer = SpeakDrill.new_footer_row(_shell)
	var col: ColumnBox = _shell["footer_col"]
	if last_ch == "" or not KanaData.has(last_ch):
		var h := UI.label(TABLE_HINT, "Muted")
		row.add_child(h)
	else:
		var e: Dictionary = KanaData.get_entry(last_ch)
		var big := UI.label(last_ch, "H1", false)
		big.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(big)
		var info := UI.vbox(0)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		info.add_child(UI.label("%s   %s" % [str(e["ko"]), str(e["ro"])], "Strong", false))
		info.add_child(UI.label(_status_text(last_ch), "Small", false))
		row.add_child(info)
		if sound_available():
			var pb := SpeakDrill.touch_button("▶ 듣기", "soft", _acc())
			pb.pressed.connect(func() -> void: play_kana(last_ch))
			row.add_child(pb)
	if not sound_available():
		col.content.add_child(UI.colored(no_sound_text(), Pal.WARN_ON, "Small"))
	UI.fix_cjk(col.content)


static func _status_text(ch: String) -> String:
	var st: Dictionary = StudyLog.kana_stat(ch)
	if int(st["ok"]) + int(st["bad"]) == 0:
		return "아직 풀어 보지 않았어요"
	return "맞힌 %d번 · 틀린 %d번" % [int(st["ok"]), int(st["bad"])]


func _build_table(c: VBoxContainer) -> void:
	var top := UI.hbox(8)
	top.add_child(UI.segmented([["hira", "히라가나 あ"], ["kata", "가타카나 ア"]], table_script, _on_table_script, Callable(self, "_script_accent")))
	c.add_child(top)

	var stats: Dictionary = StudyLog.kana_stats()
	var known := 0
	var total := 0
	for e in KanaData.entries(table_script):
		total += 1
		var pr: Variant = stats.get(str((e as Dictionary)["ch"]), null)
		if pr is Array and KanaData.mastery(int((pr as Array)[0]), int((pr as Array)[1])) >= 3:
			known += 1
	c.add_child(UI.label("익힌 글자 %d / %d  ·  점: 칸 아래 ●가 많을수록 잘 알아요 (빨강 약함 · 노랑 익히는 중 · 초록 익힘)" % [known, total], "Small"))

	var quiz := SpeakDrill.touch_button("퀴즈 풀기", "primary", _acc(), 48)
	quiz.pressed.connect(open_setup)
	c.add_child(quiz)

	cells = {}
	grids = []
	for sec in KanaData.SECTIONS:
		c.add_child(UI.section_header(str(KanaData.SECTION_LABELS[sec]), Ds.S2))
		var cols: int = int(KanaData.SECTION_COLS[sec])
		var g := GridContainer.new()
		g.columns = cols
		g.add_theme_constant_override("h_separation", GRID_GAP)
		g.add_theme_constant_override("v_separation", GRID_GAP)
		g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.add_child(g)
		grids.append(g)
		for r in KanaData.section_rows(table_script, sec):
			for e in (r as Array):
				var d: Dictionary = e
				if d.is_empty():
					var gap := Control.new()
					gap.custom_minimum_size = Vector2(CELL_MIN_W, CELL_MIN_H)
					gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
					g.add_child(gap)
					continue
				var cell := Cell.new()
				cell.setup(d, StudyLog.kana_stat(str(d["ch"])), CELL_MIN_W, CELL_MIN_H)
				var ch: String = str(d["ch"])
				cell.pressed.connect(func() -> void: tap_cell(ch))
				if ch == last_ch:
					cell.set_selected(true)
				g.add_child(cell)
				cells[ch] = cell
	c.add_child(UI.label("を 는 お 와 같은 소리, ぢ づ 는 じ ず 와 같은 소리예요. 소리 표기는 읽기 쉽게 한글로 옮긴 거예요.", "Small"))


func _script_accent(_v: String) -> Color:
	return _acc()


func _on_table_script(v: String) -> void:
	table_script = v
	last_ch = ""
	_render()


# ---------------------------------------------------------------- setup

func open_setup() -> void:
	cfg["script"] = table_script
	stage = "setup"
	_render()


func set_cfg(key: String, value: Variant) -> void:
	cfg[key] = value
	if key == "script" or key == "focus":
		cfg["rows"] = []
		cfg["group"] = ""
	_render()


func toggle_row(id: String) -> void:
	var rows: Array = (cfg["rows"] as Array).duplicate()
	if rows.has(id):
		rows.erase(id)
	else:
		rows.append(id)
	if rows.size() >= KanaData.RANGES.size():
		rows = []
	cfg["rows"] = rows
	_render()


## 이번 설정으로 연습할 글자 수 (범위 / 집중 묶음)
func pool_size() -> int:
	if bool(cfg["focus"]):
		var n := 0
		for g in KanaData.groups(str(cfg["script"])):
			if str(cfg["group"]) == "" or g["id"] == cfg["group"]:
				n += (g["chars"] as Array).size()
		return n
	return KanaData.in_ranges(str(cfg["script"]), cfg["rows"]).size()


func _build_setup(c: VBoxContainer) -> void:
	var acc := _acc()
	c.add_child(UI.label("퀴즈 설정", "H2"))
	c.add_child(UI.label("10문제, 보기는 4개예요.", "Muted"))

	c.add_child(UI.section_header("문제 종류", Ds.S2))
	c.add_child(UI.segmented([["read", "글자 → 소리"], ["listen", "소리 → 글자"]], str(cfg["kind"]), func(v: String) -> void: set_cfg("kind", v), Callable(self, "_script_accent")))
	if str(cfg["kind"]) == "listen":
		c.add_child(UI.label(no_sound_text() if not sound_available() else "소리를 듣고 알맞은 글자를 골라요.", "Small"))

	c.add_child(UI.section_header("글자 종류", Ds.S2))
	c.add_child(UI.segmented([["hira", "히라가나"], ["kata", "가타카나"], ["both", "둘 다"]], str(cfg["script"]), func(v: String) -> void: set_cfg("script", v), Callable(self, "_script_accent")))

	var sw := UI.switch_row("헷갈리는 글자 집중 연습", bool(cfg["focus"]), func(on: bool) -> void: set_cfg("focus", on), "シ/ツ, ソ/ン, ぬ/め, わ/ね/れ 같이 닮은 글자만 보기로 나와요.")
	c.add_child(sw)

	var chips := UI.flow(8, 8)
	if bool(cfg["focus"]):
		c.add_child(UI.section_header("묶음", Ds.S2))
		chips.add_child(UI.filter_chip("모든 묶음", str(cfg["group"]) == "", func() -> void: set_cfg_group("")))
		for g in KanaData.groups(str(cfg["script"])):
			var gid: String = str(g["id"])
			chips.add_child(UI.filter_chip(str(g["label"]), str(cfg["group"]) == gid, func() -> void: set_cfg_group(gid)))
	else:
		c.add_child(UI.section_header("범위", Ds.S2))
		chips.add_child(UI.filter_chip("전체", (cfg["rows"] as Array).is_empty(), func() -> void:
			cfg["rows"] = []
			_render()))
		for r in KanaData.RANGES:
			var rid: String = str(r[0])
			chips.add_child(UI.filter_chip(str(r[1]), (cfg["rows"] as Array).has(rid), func() -> void: toggle_row(rid)))
	c.add_child(chips)

	c.add_child(UI.label("연습할 글자 %d개" % pool_size(), "Strong"))
	var go := SpeakDrill.touch_button("시작", "primary", acc, 52)
	go.pressed.connect(func() -> void: start_quiz())
	c.add_child(go)


func set_cfg_group(gid: String) -> void:
	cfg["group"] = gid
	_render()


# ---------------------------------------------------------------- quiz

## 한 판을 시작한다. c 가 있으면 설정을 그걸로 바꾸고, rng_seed >= 0 이면 문제 뽑기를 그 값으로 고정한다 (시험용).
func start_quiz(c: Dictionary = {}, rng_seed: int = -1) -> bool:
	for k in c.keys():
		cfg[k] = c[k]
	if rng_seed >= 0:
		rng.seed = rng_seed
	questions = KanaData.build_session(cfg, rng)
	if questions.is_empty():
		return false
	answers = []
	for q in questions:
		answers.append({"picked": -1, "ok": false})
	idx = 0
	finished = false
	added_cards = 0
	review_pressed = false
	_marked_today = false
	stage = "quiz"
	_render()
	return true


func current() -> Dictionary:
	if idx >= 0 and idx < questions.size():
		return questions[idx]
	return {}


func is_answered() -> bool:
	return idx < answers.size() and int((answers[idx] as Dictionary)["picked"]) >= 0


## 보기 i 를 골랐다. 한 문제에 한 번만 센다. 맞았는지 돌려준다 (이미 풀었거나 범위 밖이면 false).
func answer(i: int) -> bool:
	if stage != "quiz" or current().is_empty() or is_answered():
		return false
	var q: Dictionary = current()
	if i < 0 or i >= (q["options"] as Array).size():
		return false
	var ok: bool = i == int(q["answer"])
	var a: Dictionary = answers[idx]
	a["picked"] = i
	a["ok"] = ok
	StudyLog.add_kana(str(q["ch"]), ok)
	_render_quiz_state()
	return ok


func answered_count() -> int:
	var n := 0
	for a in answers:
		if int((a as Dictionary)["picked"]) >= 0:
			n += 1
	return n


func correct_count() -> int:
	var n := 0
	for a in answers:
		if bool((a as Dictionary)["ok"]):
			n += 1
	return n


## 틀린 글자 (중복 없이, 처음 틀린 순서). entry 목록.
func wrong_entries() -> Array:
	var out: Array = []
	var seen := {}
	for i in questions.size():
		var a: Dictionary = answers[i]
		if int(a["picked"]) >= 0 and not bool(a["ok"]):
			var ch: String = str((questions[i] as Dictionary)["ch"])
			if not seen.has(ch):
				seen[ch] = true
				out.append(KanaData.get_entry(ch))
	return out


func next_question() -> void:
	if stage != "quiz" or not is_answered():
		return
	if idx + 1 >= questions.size():
		finish()
		return
	idx += 1
	_render()


func _on_next_pressed() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_next_msec < NEXT_LOCK_MSEC:
		return
	_last_next_msec = now
	next_question()


## 결과로. 익힘 기록(판 수 · 정답률)은 한 판에 한 번만 저장한다.
func finish() -> void:
	if stage != "quiz" and stage != "result":
		return
	stage = "result"
	Tts.stop()
	if not finished:
		finished = true
		StudyLog.add_kana_run(correct_count(), questions.size())
		if not _marked_today and answered_count() >= MARK_TODAY_AT:
			_marked_today = true
			Store.mark_today("ja")
			Store.save_progress()
		StudyLog.flush()
	_render()


## 틀린 글자를 복습 카드로 (lang ja, target 글자, reading 히라가나, ko 한글 소리). 같은 글자는 한 번만 들어간다.
## 새로 들어간 카드 수를 돌려준다.
func add_wrong_to_review() -> int:
	var items: Array = []
	for e in wrong_entries():
		var d: Dictionary = e
		var kind_name: String = "히라가나" if d["script"] == "hira" else "가타카나"
		items.append({"lang": "ja", "target": str(d["ch"]), "reading": str(d["hira"]), "ko": str(d["ko"]), "note": "가나 %s · %s" % [kind_name, str(d["ro"])]})
	if items.is_empty():
		return 0
	var n: int = Store.add_review(items)
	if n > 0:
		Store.save_progress()
	added_cards += n
	review_pressed = true
	return n


func retry_wrong() -> bool:
	var only: Array = []
	for e in wrong_entries():
		only.append((e as Dictionary)["ch"])
	if only.is_empty():
		return false
	var saved := cfg.duplicate(true)
	var c := cfg.duplicate(true)
	c["only"] = only
	c["focus"] = false
	var started := start_quiz(c)
	cfg = saved ## 다음 판("같은 설정으로 다시")은 원래 설정 그대로
	return started


# ---------------------------------------------------------------- drawing

func _render() -> void:
	var page: PageScroll = _shell["page"]
	var c: VBoxContainer = page.content
	var key := "%s:%d" % [stage, idx if stage == "quiz" else 0]
	if key != _view_key:
		_view_key = key
		page.scroll_vertical = 0
	UI.clear(c)
	cells = {}
	grids = []
	option_buttons = []
	_feedback_box = null
	(_shell["title"] as Label).text = "히라가나 · 가타카나"
	(_shell["count"] as Label).text = ""
	SpeakDrill.hide_footer(_shell)
	match stage:
		"unsupported":
			c.add_child(SpeakDrill.notice("가나 익히기는 일본어 공부용이에요. 위쪽 탭에서 일본어로 바꿔 주세요.", false))
			var ub := SpeakDrill.touch_button("연습으로", "outline", _acc())
			ub.pressed.connect(func() -> void: closed.emit())
			c.add_child(ub)
		"table":
			_build_table(c)
			_render_table_footer()
		"setup":
			_build_setup(c)
		"quiz":
			(_shell["count"] as Label).text = "%d / %d" % [idx + 1, questions.size()]
			_build_quiz(c)
			_render_quiz_state()
			if str(current().get("kind", "")) == "listen":
				play_kana(str(current()["ch"]))
		"result":
			_build_result(c)
	UI.fix_cjk(c)
	UI.fix_cjk(_shell["footer_col"])
	_clamp_scroll.call_deferred()


## 본문이 짧아졌는데 스크롤 값이 그대로면 (예: 설정 칩을 눌러 줄어듦) 끝으로 당긴다.
func _clamp_scroll() -> void:
	if not is_inside_tree():
		return
	var page: PageScroll = _shell["page"]
	var bar := page.get_v_scroll_bar()
	var top: int = maxi(0, int(bar.max_value - bar.page))
	if page.scroll_vertical > top:
		page.scroll_vertical = top


func _build_quiz(c: VBoxContainer) -> void:
	var q: Dictionary = current()
	if q.is_empty():
		return
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	if str(q["kind"]) == "read":
		card.body.add_child(UI.label("이 글자는 어떤 소리일까요?", "H3"))
		var big := UI.label(str(q["ch"]), "Big", false)
		big.add_theme_font_size_override("font_size", UI.fs(72))
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.body.add_child(big)
	else:
		card.body.add_child(UI.label("소리를 듣고 알맞은 글자를 골라요", "H3"))
		if sound_available():
			var lb := SpeakDrill.touch_button("▶ 다시 듣기", "primary", acc, 56)
			lb.pressed.connect(func() -> void: play_kana(str(current()["ch"])))
			card.body.add_child(lb)
		else:
			card.body.add_child(UI.label(no_sound_text(), "Muted"))
			card.body.add_child(UI.colored("소리 대신 로마자 힌트:  %s" % str(q["ro"]), Pal.INK, "H2", false))
	c.add_child(card)

	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 10)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(g)
	var opts: Array = q["options"]
	for i in opts.size():
		var o: Dictionary = opts[i]
		var b := UI.option_row(str(o["ko"]) if str(q["kind"]) == "read" else str(o["ch"]))
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_font_size_override("font_size", UI.fs(30) if str(q["kind"]) == "listen" else UI.fs(24))
		b.custom_minimum_size = Vector2(0, 72)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var n: int = i
		b.pressed.connect(func() -> void: answer(n))
		g.add_child(b)
		option_buttons.append(b)
	_feedback_box = UI.vbox(8)
	c.add_child(_feedback_box)


## 보기 색 · 피드백 상자 · 아래 "다음" 줄을 지금 상태로.
func _render_quiz_state() -> void:
	if stage != "quiz" or current().is_empty():
		return
	var q: Dictionary = current()
	var a: Dictionary = answers[idx]
	var picked: int = int(a["picked"])
	if picked < 0:
		SpeakDrill.hide_footer(_shell)
		return
	var acc := _acc()
	for i in option_buttons.size():
		var b: Button = option_buttons[i]
		if not is_instance_valid(b):
			continue
		b.disabled = true
		if i == int(q["answer"]):
			UI.paint_option(b, "right", acc)
		elif i == picked:
			UI.paint_option(b, "wrong", acc)
	if _feedback_box != null and is_instance_valid(_feedback_box):
		UI.clear(_feedback_box)
		var ok: bool = bool(a["ok"])
		var p := UI.tinted_panel(Pal.OK_SOFT if ok else Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 14, 10)
		var v := UI.vbox(4)
		p.add_child(v)
		v.add_child(UI.colored("정답이에요!" if ok else "아쉬워요", Pal.OK_ON if ok else Pal.BAD_ON, "Strong"))
		v.add_child(UI.label("%s   %s   %s" % [str(q["ch"]), str(q["ko"]), str(q["ro"])], "H3", false))
		if not ok:
			var po: Dictionary = (q["options"] as Array)[picked]
			if str(q["kind"]) == "read":
				v.add_child(UI.label("고른 소리 '%s' 는 %s 의 소리예요." % [str(po["ko"]), str(po["ch"])], "Muted"))
			else:
				v.add_child(UI.label("고른 글자 %s 는 '%s' 소리예요." % [str(po["ch"]), str(po["ko"])], "Muted"))
		_feedback_box.add_child(p)
		if sound_available():
			var pb := SpeakDrill.touch_button("▶ 정답 듣기", "soft", acc)
			pb.pressed.connect(func() -> void: play_kana(str(q["ch"])))
			_feedback_box.add_child(pb)
		else:
			_feedback_box.add_child(UI.colored(no_sound_text(), Pal.WARN_ON, "Small"))
		UI.fix_cjk(_feedback_box)
	var row: HBoxContainer = SpeakDrill.new_footer_row(_shell)
	row.add_child(UI.spacer())
	var nb := SpeakDrill.touch_button("결과 보기" if idx + 1 >= questions.size() else "다음 ▶", "primary", acc, 48)
	nb.pressed.connect(_on_next_pressed)
	row.add_child(nb)


## 정답률 (0~100 정수).
func rate_pct() -> int:
	if questions.is_empty():
		return 0
	return roundi(100.0 * float(correct_count()) / float(questions.size()))


func _build_result(c: VBoxContainer) -> void:
	var acc := _acc()
	var rate: int = rate_pct()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("퀴즈 결과", "Eyebrow", false))
	card.body.add_child(UI.colored("정답률 %d%%" % rate, ScorePanel.score_color(float(rate)), "H1", false))
	card.body.add_child(UI.label("%d문제 중 %d개 맞혔어요." % [questions.size(), correct_count()], "Strong"))
	c.add_child(card)

	var wrong: Array = wrong_entries()
	var wc := UI.card("Card", 8)
	if wrong.is_empty():
		wc.body.add_child(UI.label("틀린 글자가 없어요. 잘했어요!", "Strong"))
	else:
		wc.body.add_child(UI.label("틀린 글자 %d개" % wrong.size(), "Strong"))
		for e in wrong:
			var d: Dictionary = e
			var row := UI.hbox(10)
			var gl := UI.label(str(d["ch"]), "H2", false)
			gl.custom_minimum_size.x = 56
			row.add_child(gl)
			var tl := UI.label("%s   %s" % [str(d["ko"]), str(d["ro"])], "")
			tl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(tl)
			if sound_available():
				var pb := SpeakDrill.touch_button("▶", "soft", acc)
				var ch: String = str(d["ch"])
				pb.pressed.connect(func() -> void: play_kana(ch))
				row.add_child(pb)
			wc.body.add_child(row)
		if not sound_available():
			wc.body.add_child(UI.colored(no_sound_text(), Pal.WARN_ON, "Small"))
	c.add_child(wc)

	if not wrong.is_empty():
		var rb := SpeakDrill.touch_button("틀린 글자 복습 카드로 추가", "primary", acc, 48)
		if review_pressed:
			rb.text = "복습 카드에 넣었어요 (새 카드 %d개)" % added_cards if added_cards > 0 else "이미 복습 카드에 있어요"
			rb.disabled = true
		else:
			rb.pressed.connect(func() -> void:
				add_wrong_to_review()
				_render())
		c.add_child(rb)
		var rw := SpeakDrill.touch_button("틀린 글자만 다시 풀기", "soft", acc, 48)
		rw.pressed.connect(func() -> void: retry_wrong())
		c.add_child(rw)
	var again := SpeakDrill.touch_button("같은 설정으로 다시", "outline", acc, 48)
	again.pressed.connect(func() -> void: start_quiz())
	c.add_child(again)
	var st := SpeakDrill.touch_button("설정 바꾸기", "outline", acc, 48)
	st.pressed.connect(func() -> void:
		stage = "setup"
		_render())
	c.add_child(st)
	var out := SpeakDrill.touch_button("표로 돌아가기", "outline", acc, 48)
	out.pressed.connect(func() -> void:
		stage = "table"
		_render())
	c.add_child(out)


# ---------------------------------------------------------------- table cell

## 표의 칸 하나: 글자 + 한글 소리 + 로마자 + 익힘 점. 칸 전체가 눌리는 Button 이고 안쪽 글자는 마우스를 받지 않는다.
class Cell:
	extends Button
	var ch: String = ""
	var level: int = 0
	var _selected: bool = false

	func setup(e: Dictionary, stat: Dictionary, min_w: float, min_h: float) -> void:
		ch = str(e["ch"])
		level = KanaData.mastery(int(stat["ok"]), int(stat["bad"]))
		text = ""
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = "%s  %s  %s" % [ch, str(e["ko"]), str(e["ro"])]
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var gh: float = UI.fs(26) * 1.3 + UI.fs(13) * 1.4 + 18.0
		custom_minimum_size = Vector2(min_w, maxf(min_h, gh))
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", 0)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(box)
		var gl := Label.new()
		gl.text = ch
		gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gl.add_theme_font_size_override("font_size", UI.fs(26))
		gl.add_theme_color_override("font_color", Pal.INK)
		gl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(gl)
		var line := HBoxContainer.new()
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", 3)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(line)
		var kl := Label.new()
		kl.text = str(e["ko"])
		kl.add_theme_font_size_override("font_size", UI.fs(13))
		kl.add_theme_color_override("font_color", Pal.INK)
		kl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(kl)
		var rl := Label.new()
		rl.text = str(e["ro"])
		rl.add_theme_font_size_override("font_size", maxi(Ds.MIN_FONT, UI.fs(12)))
		rl.add_theme_color_override("font_color", Pal.MUTED)
		rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(rl)
		var dots := Dots.new()
		dots.level = level
		var dh := HBoxContainer.new()
		dh.alignment = BoxContainer.ALIGNMENT_CENTER
		dh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dh.add_child(dots)
		box.add_child(dh)
		_apply_style()

	func set_selected(on: bool) -> void:
		if on == _selected:
			return
		_selected = on
		_apply_style()

	func _apply_style() -> void:
		var n: StyleBoxFlat
		if _selected:
			n = UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 2, 2)
		else:
			n = UI.style(Pal.SURFACE, Pal.LINE_STRONG, 1, Ds.R_S, 2, 2)
		var hv := UI.style(Pal.SUNK, Pal.LINE_STRONG, 1, Ds.R_S, 2, 2)
		var pr := UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 2, 2)
		add_theme_stylebox_override("normal", n)
		add_theme_stylebox_override("hover", n if _selected else hv)
		add_theme_stylebox_override("pressed", pr)
		add_theme_stylebox_override("hover_pressed", pr)
		add_theme_stylebox_override("focus", n)


## 익힘 정도 점 3개: 채워진 개수 = 정도, 색 = 빨강(약함) · 노랑(익히는 중) · 초록(익힘). 빈 점은 테두리만.
class Dots:
	extends Control
	var level: int = 0

	func _init() -> void:
		custom_minimum_size = Vector2(28, 8)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var col: Color = Pal.LINE_STRONG
		if level == 1:
			col = Pal.BAD
		elif level == 2:
			col = Pal.WARN
		elif level >= 3:
			col = Pal.OK
		for i in 3:
			var c := Vector2(4.0 + 10.0 * i, 4.0)
			if i < level:
				draw_circle(c, 3.5, col)
			else:
				draw_arc(c, 3.0, 0.0, TAU, 12, Pal.LINE_STRONG, 1.0)
