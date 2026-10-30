class_name SongDictationTab
extends VBoxContainer
## 노래 학습 화면의 "받아쓰기" 탭 (설계 docs/song_study_design.md 5.4, 6, 8 U-12).
## 줄 듣기(SongPlayer.play_line, 플레이어가 없으면 Tts) -> 입력 -> SongStudy.dictation_score (영어 DictationDiff, 일본어 TextSim) 로 비교.
## 줄을 확인할 때 StudyLog "dictation" 이벤트를 1번만 센다 (한 번 확인한 줄은 다시 세지 않는다).
## 모두 끝내거나 "결과 보기"를 누르면 요약, PASS_SCORE 미만 줄은 [복습에 추가] (SongStudy.add_cards 뒤 Store.save_progress).
##
## 탭 위젯 계약 (4개 탭 공통): setup(song, ctx{player, line}) / on_show() / on_hide() / set_line(i). SongWordsTab 머리말 참고.

const PASS_SCORE := 85 ## DictationScreen 과 같은 통과 기준
const MAX_INPUT := 300
const REVIEW_MAX := 30
const LIST_MAX := 60
const NEXT_LOCK_MSEC := 250

var song: Dictionary = {}
var lang: String = "en"
var player: Object = null
var stage: String = "run" ## run | summary | empty
var order: Array = [] ## 받아쓰기 할 줄 번호들
var pos: int = 0
var results: Dictionary = {} ## 줄 번호 -> {score, passed, gave_up, said, diff}
var listens: Dictionary = {} ## 줄 번호 -> 들은 횟수
var hints: Dictionary = {} ## 줄 번호 -> 힌트를 켰나
var event_n: int = 0 ## 이 탭이 센 dictation 이벤트 수 (시험 확인용)
var last_msg: String = ""

var _typed: String = ""
var _edit: LineEdit = null
var _check_btn: Button = null
var _line_hint: int = -1
var _acc: Color = Pal.EN
var _last_next_msec: int = -100000


func _init() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _exit_tree() -> void:
	Tts.stop()


# ---------------------------------------------------------------- 계약

func setup(song_in: Dictionary, ctx: Dictionary = {}) -> void:
	song = song_in
	lang = str(song.get("lang", "en"))
	if lang != "ja":
		lang = "en"
	_acc = Pal.accent(lang)
	var pl: Variant = ctx.get("player", null)
	player = pl if (pl is Object) else null
	_line_hint = int(ctx.get("line", -1))
	restart(_line_hint)


func on_show() -> void:
	_render()


func on_hide() -> void:
	Tts.stop()


func set_line(i: int) -> void:
	_line_hint = i
	if stage == "run":
		var p: int = order.find(i)
		if p >= 0 and p != pos:
			_open(p)


# ---------------------------------------------------------------- 회차

## 받아쓰기 할 수 있는 줄인가: 글자가 있고 [Chorus] 같은 구간 표시가 아니다.
static func is_dictable(lang_in: String, line: Dictionary) -> bool:
	var t: String = str(line.get("text", "")).strip_edges()
	if t == "":
		return false
	if t.begins_with("[") and t.ends_with("]"):
		return false
	if lang_in == "ja":
		for i in t.length():
			if TextSim.JA_SKIP.find(t[i]) == -1:
				return true
		return false
	return DictationDiff.word_count(t) > 0


func restart(start_line: int = -1) -> void:
	results = {}
	listens = {}
	hints = {}
	last_msg = ""
	order = []
	var ls: Variant = song.get("lines", [])
	if ls is Array:
		for i in (ls as Array).size():
			if (ls as Array)[i] is Dictionary and is_dictable(lang, (ls as Array)[i]):
				order.append(i)
	if order.is_empty():
		stage = "empty"
		_render()
		return
	stage = "run"
	_open(maxi(0, order.find(start_line)))


func current_line() -> int:
	if pos >= 0 and pos < order.size():
		return int(order[pos])
	return -1


func current() -> Dictionary:
	var li: int = current_line()
	var ls: Variant = song.get("lines", [])
	if li >= 0 and ls is Array and li < (ls as Array).size() and (ls as Array)[li] is Dictionary:
		return (ls as Array)[li]
	return {}


func is_checked() -> bool:
	return results.has(current_line())


func _open(p: int) -> void:
	pos = clampi(p, 0, maxi(0, order.size() - 1))
	_typed = str(results[current_line()]["said"]) if results.has(current_line()) else ""
	_render()


# ---------------------------------------------------------------- 한 줄

## 줄 듣기: 플레이어가 있으면 노래의 그 줄을, 없으면 음성(Tts)으로.
func listen() -> bool:
	if stage != "run" or current().is_empty():
		return false
	var li: int = current_line()
	listens[li] = int(listens.get(li, 0)) + 1
	if player != null and is_instance_valid(player) and player.has_method("play_line"):
		player.call("play_line", li, 1)
	else:
		Tts.speak(str(current().get("text", "")), lang, false)
	_update_listen_label()
	return true


func toggle_hint() -> void:
	if stage != "run" or is_checked():
		return
	var li: int = current_line()
	hints[li] = not bool(hints.get(li, false))
	_render()


func set_typed(t: String) -> void:
	_typed = t.left(MAX_INPUT)
	if _check_btn != null and is_instance_valid(_check_btn):
		_check_btn.disabled = _typed.strip_edges() == ""


## 확인 (또는 "모르겠어요"). 한 줄에 한 번만 처리한다. 입력이 비었으면 아무 일도 하지 않는다.
func check(gave_up: bool = false) -> bool:
	if stage != "run" or current().is_empty() or is_checked():
		return false
	var said: String = "" if gave_up else _typed.left(MAX_INPUT)
	if not gave_up and said.strip_edges() == "":
		return false
	var d: Dictionary = SongStudy.dictation_score(lang, said, current())
	var sc: int = 0 if gave_up else int(d.get("score", 0))
	results[current_line()] = {"score": sc, "passed": (not gave_up) and sc >= PASS_SCORE, "gave_up": gave_up, "said": said, "diff": d}
	StudyLog.add_event(lang, "dictation", 1)
	event_n += 1
	if player != null and is_instance_valid(player) and player.has_method("pause"):
		player.call("pause")
	_render()
	return true


func next_line() -> void:
	if stage != "run":
		return
	if pos + 1 >= order.size():
		finish()
		return
	_open(pos + 1)


func _on_next_pressed() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_next_msec < NEXT_LOCK_MSEC:
		return
	_last_next_msec = now
	next_line()


func finish() -> void:
	if stage == "empty":
		return
	stage = "summary"
	Tts.stop()
	_render()


# ---------------------------------------------------------------- 요약 · 복습 카드

## {n (푼 줄), passed, avg, low (PASS_SCORE 미만으로 푼 줄 번호들)}
func summarize() -> Dictionary:
	var tried := 0
	var passed := 0
	var sum := 0
	var low: Array = []
	for li in order:
		if results.has(li):
			var r: Dictionary = results[li]
			tried += 1
			sum += int(r["score"])
			if bool(r["passed"]):
				passed += 1
			else:
				low.append(li)
	return {"n": tried, "passed": passed, "avg": roundi(float(sum) / float(tried)) if tried > 0 else 0, "low": low}


## PASS_SCORE 미만으로 푼 줄(들)을 복습 카드로. line_i < 0 이면 모두 (최대 REVIEW_MAX). 새로 들어간 카드 수.
func add_line_cards(line_i: int = -1) -> int:
	var items: Array = []
	var targets: Array = []
	if line_i < 0:
		targets = (summarize()["low"] as Array).slice(0, REVIEW_MAX)
	elif results.has(line_i) and not bool(results[line_i]["passed"]):
		targets = [line_i]
	for li in targets:
		var c: Dictionary = SongStudy.line_card(song, int(li))
		if not c.is_empty():
			items.append(c)
	if items.is_empty():
		last_msg = "복습에 넣을 줄이 없어요."
		_render()
		return 0
	var r: Dictionary = SongStudy.add_cards(items)
	var n: int = int(r.get("added", 0))
	if n > 0:
		Store.save_progress()
		Toast.ok("복습 카드 %d개를 넣었어요" % n)
		last_msg = "복습 카드 %d개를 넣었어요." % n
	else:
		last_msg = "이미 복습 카드에 있어요."
	_render()
	return n


# ---------------------------------------------------------------- 그리기

static func score_ink(score: float) -> Color:
	if score >= float(PASS_SCORE):
		return Pal.OK_ON
	return Pal.WARN_ON if score >= 60.0 else Pal.BAD_ON


var _listen_label: Label = null


func _update_listen_label() -> void:
	if _listen_label != null and is_instance_valid(_listen_label):
		_listen_label.text = "들은 횟수 %d" % int(listens.get(current_line(), 0))


func _render() -> void:
	UI.clear(self)
	_edit = null
	_check_btn = null
	_listen_label = null
	if last_msg != "":
		add_child(UI.colored(last_msg, Pal.OK_ON, "Strong"))
	match stage:
		"empty":
			add_child(SpeakDrill.notice("받아쓰기 할 수 있는 줄이 없어요.", false))
		"summary":
			_render_summary()
		_:
			_render_run()
	UI.fix_cjk(self)


func _render_run() -> void:
	var line: Dictionary = current()
	if line.is_empty():
		return
	var li: int = current_line()
	var checked: bool = results.has(li)
	var target: String = str(line.get("text", ""))
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.colored("%d / %d" % [pos + 1, order.size()], Pal.MUTED, "Eyebrow", false))
	card.body.add_child(UI.label("들리는 대로 " + ("일본어" if lang == "ja" else "영어") + "로 써 보세요", "H3"))
	var lr := UI.flow(8, 8)
	var b1 := SpeakDrill.touch_button("▶ 줄 듣기", "soft", _acc)
	b1.pressed.connect(func() -> void: listen())
	lr.add_child(b1)
	_listen_label = UI.label("들은 횟수 %d" % int(listens.get(li, 0)), "Muted", false)
	_listen_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lr.add_child(_listen_label)
	card.body.add_child(lr)
	var size_text: String
	if lang == "ja":
		var n_chars := 0
		for i in target.length():
			if TextSim.JA_SKIP.find(target[i]) == -1:
				n_chars += 1
		size_text = "글자 %d자" % n_chars
	else:
		size_text = "단어 %d개" % DictationDiff.word_count(target)
	card.body.add_child(UI.label(size_text, "Strong"))
	if not checked:
		var hr := UI.flow(8, 8)
		var hb := SpeakDrill.touch_button("첫 글자 힌트", "soft", _acc)
		hb.pressed.connect(toggle_hint)
		hr.add_child(hb)
		var gb := SpeakDrill.touch_button("모르겠어요", "flat", Pal.MUTED)
		gb.pressed.connect(func() -> void: check(true))
		hr.add_child(gb)
		card.body.add_child(hr)
		if bool(hints.get(li, false)):
			var hint: String = DictationDiff.first_letters(target) if lang == "en" else target.left(1) + "…"
			card.body.add_child(UI.label(hint, "Muted"))
		_edit = LineEdit.new()
		_edit.max_length = MAX_INPUT
		_edit.placeholder_text = "들은 문장을 써 보세요"
		_edit.custom_minimum_size.y = Ds.field_h()
		_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_edit.text = _typed
		_edit.text_changed.connect(set_typed)
		_edit.text_submitted.connect(func(_t: String) -> void: check(false))
		card.body.add_child(_edit)
		_check_btn = SpeakDrill.touch_button("확인", "primary", _acc)
		_check_btn.disabled = _typed.strip_edges() == ""
		_check_btn.pressed.connect(func() -> void: check(false))
		card.body.add_child(_check_btn)
	add_child(card)

	if checked:
		add_child(_result_card(line, results[li]))
		var nb := SpeakDrill.touch_button("결과 보기" if pos + 1 >= order.size() else "다음 ▶", "primary", _acc)
		nb.pressed.connect(_on_next_pressed)
		add_child(nb)
	if not results.is_empty():
		var sb := SpeakDrill.touch_button("그만하고 결과 보기", "flat", Pal.MUTED)
		sb.pressed.connect(finish)
		add_child(sb)


func _result_card(line: Dictionary, r: Dictionary) -> Control:
	var d: Dictionary = r["diff"]
	var li: int = current_line()
	var card := UI.card("Card", 10)
	var sc: int = int(r["score"])
	card.body.add_child(UI.colored("%d점" % sc, score_ink(float(sc)), "H1", false))
	if bool(r["gave_up"]):
		card.body.add_child(UI.label("정답을 확인했어요. 다음에 또 해 봐요.", "Muted"))
	else:
		card.body.add_child(UI.colored("✓ 통과!" if bool(r["passed"]) else "✕ 통과 기준은 %d점이에요." % PASS_SCORE, Pal.OK_ON if bool(r["passed"]) else Pal.WARN_ON, "Strong"))
		card.body.add_child(UI.label("내가 쓴 것:  " + str(r["said"]), "Muted"))
	if lang == "en":
		var chips := UI.flow(6, 6)
		for w in d.get("words", []):
			var wd: Dictionary = w
			var kind: String = str(wd.get("kind", "missing"))
			var txt: String = "✓ " + str(wd["w"])
			var ck := "ok"
			if kind == "missing":
				txt = "✕ " + str(wd["w"]) + "  · 빠짐"
				ck = "bad"
			elif kind == "typo":
				txt = "✕ " + str(wd["w"]) + "  · 철자 틀림 (%s)" % str(wd.get("said", ""))
				ck = "bad"
			chips.add_child(UI.chip_kind(txt, ck))
		card.body.add_child(chips)
		var extra: Array = d.get("extra", [])
		if not extra.is_empty():
			card.body.add_child(UI.colored("정답에 없는 단어:  " + ", ".join(PackedStringArray(extra)), Pal.WARN_ON, "Small"))
	else:
		var hit: Array = d.get("hit", [])
		var good := 0
		for h in hit:
			if bool(h):
				good += 1
		if not hit.is_empty():
			card.body.add_child(UI.label("맞춘 글자 %d / %d" % [good, hit.size()], "Muted"))
	card.body.add_child(UI.hline())
	card.body.add_child(UI.label("정답", "Eyebrow", false))
	card.body.add_child(UI.label(str(line.get("text", "")), "Strong"))
	ReadingLine.add(card.body, str(line.get("reading", "")), lang, Store.pref_bool("show_reading"), 0.0, str(line.get("pron", "")))
	if str(line.get("ko", "")) != "":
		card.body.add_child(UI.label(str(line["ko"]), "Muted"))
	if not bool(r["passed"]):
		var ab := SpeakDrill.touch_button("이 줄 복습에 추가", "soft", _acc)
		ab.pressed.connect(func() -> void: add_line_cards(li))
		card.body.add_child(ab)
	return card


func _render_summary() -> void:
	var sm: Dictionary = summarize()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("노래 받아쓰기 결과", "Eyebrow", false))
	if int(sm["n"]) == 0:
		card.body.add_child(UI.label("써 본 줄이 없어요.", "H2"))
	else:
		card.body.add_child(UI.colored("평균 %d점" % int(sm["avg"]), score_ink(float(sm["avg"])), "H1", false))
		card.body.add_child(UI.label("통과 %d줄 / 시도 %d줄 (통과 기준 %d점)" % [int(sm["passed"]), int(sm["n"]), PASS_SCORE], "Strong"))
	add_child(card)
	var lc := UI.card("Card", 8)
	var shown := 0
	for li in order:
		if not results.has(li):
			continue
		if shown >= LIST_MAX:
			break
		shown += 1
		var r: Dictionary = results[li]
		var row := UI.hbox(10)
		var tag: String = "%s %d" % ["✓" if bool(r["passed"]) else "✕", int(r["score"])]
		var sl := UI.colored(tag, score_ink(float(r["score"])), "Strong", false)
		sl.custom_minimum_size.x = Ds.fs(60)
		row.add_child(sl)
		row.add_child(UI.label(str((song["lines"] as Array)[int(li)].get("text", "")), ""))
		lc.body.add_child(row)
	if shown > 0:
		add_child(lc)
	var low: Array = sm["low"]
	if not low.is_empty():
		var lb := SpeakDrill.touch_button("%d점 미만 줄 복습에 추가" % PASS_SCORE, "primary", _acc)
		lb.pressed.connect(func() -> void: add_line_cards(-1))
		add_child(lb)
	var again := SpeakDrill.touch_button("다시 하기", "outline", _acc)
	again.pressed.connect(func() -> void: restart(-1))
	add_child(again)
