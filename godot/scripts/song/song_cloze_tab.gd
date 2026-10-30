class_name SongClozeTab
extends VBoxContainer
## 노래 학습 화면의 "빈칸" 탭 (설계 docs/song_study_design.md 5.4, 6, 8 U-12).
## 줄마다 SongStudy.cloze(song, i, level, seed, Store.known_set(lang)) 로 빈칸을 만들고, 답은 직접 쓰거나 보기를 눌러 넣는다.
## 확인하면 SongStudy.check_blank 로 빈칸마다 맞고 틀림을 보이고, 줄을 끝낼 때 StudyLog "drill" 이벤트를 1번만 센다
## (한 번 확인한 줄은 다시 세지 않는다. SongSingDrill 은 이벤트를 세지 않는다). 모두 끝내거나 "결과 보기"를 누르면 요약.
## 틀린 줄 / 틀린 단어는 [복습에 추가] (SongStudy.add_cards 뒤 Store.save_progress).
##
## 탭 위젯 계약 (4개 탭 공통): setup(song, ctx{player, line}) / on_show() / on_hide() / set_line(i). SongWordsTab 머리말 참고.

const MAX_INPUT := 60
const LIST_MAX := 60 ## 요약에서 줄 목록으로 보이는 최대 개수
const NEXT_LOCK_MSEC := 250

var song: Dictionary = {}
var lang: String = "en"
var player: Object = null
var level: int = 1
var seed_value: int = 1
var stage: String = "run" ## run | summary | empty
var order: Array = [] ## 이번 회차의 줄 번호들 (빈칸을 만들 수 있는 줄)
var pos: int = 0
var cur: Dictionary = {} ## 지금 줄의 SongStudy.cloze 결과
var answers: Array = [] ## 지금 줄의 빈칸별 답
var results: Dictionary = {} ## 줄 번호 -> {ok, blanks: [{ok, said, answer, score}], answers}
var event_n: int = 0 ## 이 탭이 센 drill 이벤트 수 (시험 확인용)
var last_msg: String = ""

var _line_hint: int = -1
var _edits: Array = []
var _check_btn: Button = null
var _clozes: Dictionary = {}
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
	seed_value = randi() % 1000000 + 1
	restart(level, _line_hint)


func on_show() -> void:
	_render()


func on_hide() -> void:
	Tts.stop()


## 틀의 현재 줄이 바뀌었다: 이 회차에 있는 줄이면 그 줄로 이동한다.
func set_line(i: int) -> void:
	_line_hint = i
	if stage == "run":
		var p: int = order.find(i)
		if p >= 0 and p != pos:
			_open(p)


# ---------------------------------------------------------------- 회차

## 새 회차 (난이도 = 빈칸 수 1~3). start_line 이 회차에 있으면 거기서 시작한다.
func restart(new_level: int = -1, start_line: int = -1) -> void:
	if new_level > 0:
		level = clampi(new_level, SongStudy.MIN_LEVEL, SongStudy.MAX_LEVEL)
	results = {}
	_clozes = {}
	last_msg = ""
	var known: Dictionary = Store.known_set(lang)
	order = []
	var ls: Variant = song.get("lines", [])
	if ls is Array:
		for i in (ls as Array).size():
			var cz: Dictionary = SongStudy.cloze(song, i, level, seed_value, known)
			if bool(cz.get("ok", false)):
				_clozes[i] = cz
				order.append(i)
	if order.is_empty():
		stage = "empty"
		cur = {}
		answers = []
		_render()
		return
	stage = "run"
	_open(maxi(0, order.find(start_line)))


func set_level(new_level: int) -> void:
	if new_level == level and stage != "empty":
		return
	restart(new_level, current_line())


func current_line() -> int:
	if pos >= 0 and pos < order.size():
		return int(order[pos])
	return -1


func is_checked() -> bool:
	return results.has(current_line())


func _open(p: int) -> void:
	pos = clampi(p, 0, maxi(0, order.size() - 1))
	var li: int = current_line()
	cur = _clozes.get(li, {})
	var n: int = (cur.get("blanks", []) as Array).size()
	answers = []
	for k in n:
		answers.append("")
	if results.has(li):
		answers = (results[li]["answers"] as Array).duplicate()
	_render()


# ---------------------------------------------------------------- 한 줄

func set_answer(k: int, text: String) -> void:
	if stage != "run" or is_checked() or k < 0 or k >= answers.size():
		return
	answers[k] = text.left(MAX_INPUT)
	if k < _edits.size() and _edits[k] != null and is_instance_valid(_edits[k]):
		var ed: LineEdit = _edits[k]
		if ed.text != str(answers[k]):
			ed.text = str(answers[k])
	_update_check_btn()


## 보기를 눌러 답으로 넣는다.
func pick_option(k: int, option: String) -> void:
	set_answer(k, option)
	if stage == "run" and not is_checked():
		_render() # 고른 보기의 표시를 바꾼다


func answered_all() -> bool:
	if answers.is_empty():
		return false
	for a in answers:
		if str(a).strip_edges() == "":
			return false
	return true


func _update_check_btn() -> void:
	if _check_btn != null and is_instance_valid(_check_btn):
		_check_btn.disabled = not answered_all()


## 확인 (gave_up: "모르겠어요" = 모두 틀림). 한 줄에 한 번만 처리한다. 빈칸이 비었으면 아무 일도 하지 않는다.
func check(gave_up: bool = false) -> bool:
	if stage != "run" or cur.is_empty() or is_checked():
		return false
	if not gave_up and not answered_all():
		return false
	var li: int = current_line()
	var blanks: Array = cur["blanks"]
	var res_b: Array = []
	var all_ok := true
	for k in blanks.size():
		var said: String = "" if gave_up else str(answers[k])
		var r: Dictionary = SongStudy.check_blank(lang, blanks[k], said)
		var good: bool = (not gave_up) and bool(r.get("ok", false))
		all_ok = all_ok and good
		res_b.append({"ok": good, "said": said, "answer": str((blanks[k] as Dictionary)["answer"]), "score": int(r.get("score", 0))})
	results[li] = {"ok": all_ok, "blanks": res_b, "answers": answers.duplicate(), "gave_up": gave_up}
	StudyLog.add_event(lang, "drill", 1)
	event_n += 1
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


func play_current_line() -> bool:
	var li: int = current_line()
	if li < 0 or player == null or not is_instance_valid(player) or not player.has_method("play_line"):
		return false
	player.call("play_line", li, 1)
	return true


# ---------------------------------------------------------------- 요약 · 복습 카드

## {n (푼 줄), ok (맞은 줄), wrong (틀린 줄 번호들)}
func summarize() -> Dictionary:
	var ok_n := 0
	var wrong: Array = []
	for li in order:
		if results.has(li):
			if bool(results[li]["ok"]):
				ok_n += 1
			else:
				wrong.append(li)
	return {"n": ok_n + wrong.size(), "ok": ok_n, "wrong": wrong}


## 틀린 줄(들)을 복습 카드로. line_i < 0 이면 틀린 줄 모두. 새로 들어간 카드 수.
func add_line_cards(line_i: int = -1) -> int:
	var items: Array = []
	var targets: Array = summarize()["wrong"] if line_i < 0 else ([line_i] if (results.has(line_i) and not bool(results[line_i]["ok"])) else [])
	for li in targets:
		var c: Dictionary = SongStudy.line_card(song, int(li))
		if not c.is_empty():
			items.append(c)
	return _add(items)


## 틀린 빈칸의 단어(들)를 복습 카드로. line_i < 0 이면 틀린 줄 모두.
func add_word_cards(line_i: int = -1) -> int:
	var items: Array = []
	var targets: Array = summarize()["wrong"] if line_i < 0 else ([line_i] if (results.has(line_i) and not bool(results[line_i]["ok"])) else [])
	var seen := {}
	for li in targets:
		for b in (results[li]["blanks"] as Array):
			if bool((b as Dictionary)["ok"]):
				continue
			var ans: String = str((b as Dictionary)["answer"])
			if seen.has(ans):
				continue
			seen[ans] = true
			var c: Dictionary = SongStudy.word_card(song, ans)
			if not c.is_empty():
				items.append(c)
	return _add(items)


func _add(items: Array) -> int:
	if items.is_empty():
		last_msg = "복습에 넣을 항목이 없어요."
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

func _render() -> void:
	UI.clear(self)
	_edits = []
	_check_btn = null
	add_child(UI.segmented([["1", "빈칸 1개"], ["2", "빈칸 2개"], ["3", "빈칸 3개"]], str(level), func(v: String) -> void: set_level(int(v))))
	if last_msg != "":
		add_child(UI.colored(last_msg, Pal.OK_ON, "Strong"))
	match stage:
		"empty":
			add_child(SpeakDrill.notice("빈칸을 만들 수 있는 줄이 없어요. 아는 단어를 줄이거나 다른 곡으로 해 보세요.", false))
		"summary":
			_render_summary()
		_:
			_render_run()
	UI.fix_cjk(self)


func _render_run() -> void:
	if cur.is_empty():
		return
	var li: int = current_line()
	var checked: bool = results.has(li)
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.colored("%d / %d" % [pos + 1, order.size()], Pal.MUTED, "Eyebrow", false))
	var line_d: Dictionary = (song["lines"] as Array)[li]
	card.body.add_child(UI.label(str(line_d.get("text", "")) if checked else str(cur["prompt"]), "H3"))
	add_child(card)

	var blanks: Array = cur["blanks"]
	_edits = []
	for k in blanks.size():
		var b: Dictionary = blanks[k]
		var bc := UI.card("Card", 8)
		bc.body.add_child(UI.label("빈칸 %d" % (k + 1), "Eyebrow", false))
		var ed := LineEdit.new()
		ed.max_length = MAX_INPUT
		ed.placeholder_text = "들은 단어를 써 보세요"
		ed.custom_minimum_size.y = Ds.field_h()
		ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ed.text = str(answers[k]) if k < answers.size() else ""
		ed.editable = not checked
		var kk: int = k
		ed.text_changed.connect(func(t: String) -> void: set_answer(kk, t))
		ed.text_submitted.connect(func(_t: String) -> void: check(false))
		bc.body.add_child(ed)
		_edits.append(ed)
		if checked:
			var rb: Dictionary = (results[li]["blanks"] as Array)[k]
			if bool(rb["ok"]):
				bc.body.add_child(UI.chip_kind("✓ 맞았어요: " + str(rb["answer"]), "ok"))
			else:
				bc.body.add_child(UI.chip_kind("✕ 정답: " + str(rb["answer"]), "bad"))
				if str(rb["said"]) != "":
					bc.body.add_child(UI.label("내가 쓴 것:  " + str(rb["said"]), "Muted"))
		else:
			var opts: Array = b.get("options", [])
			if not opts.is_empty():
				var fr := UI.flow(8, 8)
				for o in opts:
					var os: String = str(o)
					fr.add_child(UI.filter_chip(os, str(answers[k]) == os, func() -> void: pick_option(kk, os)))
				bc.body.add_child(fr)
		add_child(bc)

	if checked:
		var r: Dictionary = results[li]
		var rc := UI.card("Card", 8)
		rc.body.add_child(UI.colored("✓ 모두 맞았어요!" if bool(r["ok"]) else "✕ 틀린 빈칸이 있어요.", Pal.OK_ON if bool(r["ok"]) else Pal.WARN_ON, "Strong"))
		ReadingLine.add(rc.body, str(line_d.get("reading", "")), lang, Store.pref_bool("show_reading"), 0.0, str(line_d.get("pron", "")))
		if str(line_d.get("ko", "")) != "":
			rc.body.add_child(UI.label(str(line_d["ko"]), "Muted"))
		var fr2 := UI.flow(8, 8)
		if player != null and is_instance_valid(player) and player.has_method("play_line"):
			var pb := SpeakDrill.touch_button("▶ 이 줄 듣기", "soft", _acc)
			pb.pressed.connect(func() -> void: play_current_line())
			fr2.add_child(pb)
		if not bool(r["ok"]):
			var ab := SpeakDrill.touch_button("이 줄 복습에 추가", "soft", _acc)
			ab.pressed.connect(func() -> void: add_line_cards(li))
			fr2.add_child(ab)
		rc.body.add_child(fr2)
		add_child(rc)
		var nb := SpeakDrill.touch_button("결과 보기" if pos + 1 >= order.size() else "다음 ▶", "primary", _acc)
		nb.pressed.connect(_on_next_pressed)
		add_child(nb)
	else:
		var row := UI.flow(8, 8)
		_check_btn = SpeakDrill.touch_button("확인", "primary", _acc)
		_check_btn.disabled = not answered_all()
		_check_btn.pressed.connect(func() -> void: check(false))
		row.add_child(_check_btn)
		var gb := SpeakDrill.touch_button("모르겠어요", "flat", Pal.MUTED)
		gb.pressed.connect(func() -> void: check(true))
		row.add_child(gb)
		add_child(row)
	if not results.is_empty() and stage == "run":
		var sb := SpeakDrill.touch_button("그만하고 결과 보기", "flat", Pal.MUTED)
		sb.pressed.connect(finish)
		add_child(sb)


func _render_summary() -> void:
	var sm: Dictionary = summarize()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("빈칸 채우기 결과", "Eyebrow", false))
	if int(sm["n"]) == 0:
		card.body.add_child(UI.label("푼 줄이 없어요.", "H2"))
	else:
		card.body.add_child(UI.label("%d줄 중 %d줄 정답" % [int(sm["n"]), int(sm["ok"])], "H2"))
	add_child(card)
	var wrong: Array = sm["wrong"]
	if not wrong.is_empty():
		var wc := UI.card("Card", 8)
		wc.body.add_child(UI.label("틀린 줄 %d개" % wrong.size(), "Strong"))
		for li in wrong.slice(0, LIST_MAX):
			var d: Dictionary = (song["lines"] as Array)[int(li)]
			wc.body.add_child(UI.label("✕ " + str(d.get("text", "")), ""))
		var row := UI.flow(8, 8)
		var lb := SpeakDrill.touch_button("틀린 줄 복습에 추가", "primary", _acc)
		lb.pressed.connect(func() -> void: add_line_cards(-1))
		row.add_child(lb)
		var wb := SpeakDrill.touch_button("틀린 단어 복습에 추가", "soft", _acc)
		wb.pressed.connect(func() -> void: add_word_cards(-1))
		row.add_child(wb)
		wc.body.add_child(row)
		add_child(wc)
	var again := SpeakDrill.touch_button("다시 하기", "primary" if wrong.is_empty() else "outline", _acc)
	again.pressed.connect(func() -> void:
		seed_value = randi() % 1000000 + 1
		restart(level, -1))
	add_child(again)
