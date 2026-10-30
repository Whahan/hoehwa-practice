class_name SongWordsTab
extends VBoxContainer
## 노래 학습 화면의 "단어" 탭 (설계 docs/song_study_design.md 5.4, 6, 8 U-11).
## 모르는 단어(SongStudy.pick_unknown, 아는 단어 제외) 목록 -> 단어를 누르면 뜻 · 발음기호(영어) / 히라가나 + 한글 발음(일본어) ·
## 단어 듣기 · [복습에 추가] (SongStudy.add_cards 뒤 Store.save_progress) · [아는 단어] (Store.set_known).
##
## 탭 위젯 계약 (4개 탭 공통, 화면 틀 = SongStudyScreen 이 부른다):
##   func setup(song: Dictionary, ctx: Dictionary = {})   곡(정규화된 Dictionary, 틀과 같은 객체)과 ctx{player: SongPlayer|null, line: int}
##   func on_show() / on_hide()                            탭이 보일 때(다시 그림) / 가려질 때(음성 · 요청 멈춤)
##   func set_line(i: int)                                 틀의 현재 줄이 바뀌었을 때
## 서버 요청 없음: 뜻 · 발음은 곡에 저장된 words / glossary 만 쓴다.

const LIMIT := 200 ## 목록에 올리는 단어 수 상한
const PAGE := 30 ## 처음 보이는 개수 (더 보기로 늘림)
const MSG_EMPTY_ALL := "모르는 단어가 없어요. 이 곡의 단어는 모두 아는 단어예요."
const MSG_EMPTY_SONG := "이 곡에는 공부할 단어 정보가 없어요."
const MSG_NO_KO := "뜻이 아직 없어요. 해석 탭에서 만들 수 있어요."

var song: Dictionary = {}
var lang: String = "en"
var player: Object = null
var words: Array = [] ## SongStudy.pick_unknown 결과
var open_lemma: String = ""
var only_line: bool = false ## "현재 줄의 단어만" 보기
var shown: int = PAGE
var added: Dictionary = {} ## lemma -> true (이번에 복습에 넣었거나 이미 있던 단어)
var last_msg: String = ""

var _line: int = -1
var _acc: Color = Pal.EN


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
	_line = int(ctx.get("line", -1))
	open_lemma = ""
	only_line = false
	shown = PAGE
	added = {}
	last_msg = ""
	refresh()


func on_show() -> void:
	refresh()


func on_hide() -> void:
	Tts.stop()


func set_line(i: int) -> void:
	_line = i
	if only_line:
		_render()


# ---------------------------------------------------------------- 데이터

## 목록을 곡 · 아는 단어에서 다시 만든다.
func refresh() -> void:
	words = SongStudy.pick_unknown(song, Store.known_set(lang), LIMIT)
	if open_lemma != "" and _find(open_lemma).is_empty():
		open_lemma = ""
	_render()


## 지금 보이는 (필터를 거친) 단어들.
func visible_words() -> Array:
	if not only_line:
		return words
	var keys: Dictionary = _line_keys(_line)
	var out: Array = []
	for w in words:
		var d: Dictionary = w
		if keys.has(str(d["lemma"])) or keys.has(str(d["lemma"]).to_lower()) or keys.has(str(d["w"])) or keys.has(str(d["w"]).to_lower()):
			out.append(d)
	return out


func _line_keys(i: int) -> Dictionary:
	var out := {}
	var ls: Variant = song.get("lines", [])
	if not (ls is Array) or i < 0 or i >= (ls as Array).size() or not ((ls as Array)[i] is Dictionary):
		return out
	var ws: Variant = ((ls as Array)[i] as Dictionary).get("words", [])
	if ws is Array:
		for wd in ws:
			if wd is Dictionary:
				for k in ["lemma", "w"]:
					var s: String = str((wd as Dictionary).get(k, "")).strip_edges()
					if s != "":
						out[s] = true
						out[s.to_lower()] = true
	return out


func _find(lemma: String) -> Dictionary:
	for w in words:
		if str((w as Dictionary)["lemma"]) == lemma:
			return w
	return {}


func line_text(i: int) -> String:
	var ls: Variant = song.get("lines", [])
	if ls is Array and i >= 0 and i < (ls as Array).size() and (ls as Array)[i] is Dictionary:
		return str(((ls as Array)[i] as Dictionary).get("text", ""))
	return ""


# ---------------------------------------------------------------- 동작

func toggle_word(lemma: String) -> void:
	open_lemma = "" if open_lemma == lemma else lemma
	last_msg = ""
	_render()


func set_only_line(on: bool) -> void:
	only_line = on
	shown = PAGE
	_render()


func show_more() -> void:
	shown += PAGE
	_render()


func _pause_player() -> void:
	if player != null and is_instance_valid(player) and player.has_method("pause"):
		player.call("pause")


## 단어를 읽어 준다 (노래는 먼저 멈춘다: 5.5).
func speak_word(lemma: String) -> bool:
	var e: Dictionary = _find(lemma)
	if e.is_empty():
		return false
	_pause_player()
	var text: String = str(e["w"]) if str(e["w"]) != "" else lemma
	Tts.speak(text, lang, false)
	return true


## 단어가 나온 첫 줄을 노래에서 들려준다.
func play_line_of(lemma: String) -> bool:
	var e: Dictionary = _find(lemma)
	if e.is_empty() or player == null or not is_instance_valid(player) or not player.has_method("play_line"):
		return false
	player.call("play_line", int(e["line_i"]), 1)
	return true


## 복습 카드로 넣는다 (SongStudy.add_cards 뒤 Store.save_progress). 새로 들어간 카드 수(0 = 이미 있음 / 못 만듦).
func add_card(lemma: String) -> int:
	var card: Dictionary = SongStudy.word_card(song, lemma)
	if card.is_empty():
		last_msg = "이 단어로는 카드를 만들 수 없어요."
		_render()
		return 0
	var r: Dictionary = SongStudy.add_cards([card])
	var n: int = int(r.get("added", 0))
	if n > 0:
		Store.save_progress()
		Toast.ok("복습 카드에 넣었어요")
		last_msg = "복습 카드에 넣었어요."
	else:
		last_msg = "이미 복습 카드에 있어요."
	added[lemma] = true
	_render()
	return n


## "아는 단어"로 표시한다 (목록에서 빠지고, 빈칸에서도 제외된다).
func mark_known(lemma: String) -> bool:
	if lemma.strip_edges() == "":
		return false
	var n: int = Store.set_known(lang, [lemma], true)
	Store.save_progress()
	if open_lemma == lemma:
		open_lemma = ""
	last_msg = "아는 단어로 표시했어요."
	refresh()
	return n > 0


# ---------------------------------------------------------------- 그리기

func _render() -> void:
	UI.clear(self)
	var vis: Array = visible_words()
	var head := UI.card("Card", 8)
	head.body.add_child(UI.label("모르는 단어 %d개" % words.size(), "H3"))
	head.body.add_child(UI.label("단어를 눌러 뜻을 보고, 복습 카드에 넣거나 아는 단어로 표시해요.", "Muted"))
	var fr := UI.flow(8, 8)
	fr.add_child(UI.filter_chip("전체", not only_line, func() -> void: set_only_line(false)))
	fr.add_child(UI.filter_chip("현재 줄의 단어만", only_line, func() -> void: set_only_line(true)))
	head.body.add_child(fr)
	add_child(head)
	if last_msg != "":
		add_child(UI.colored(last_msg, Pal.OK_ON, "Strong"))

	if vis.is_empty():
		var msg: String = MSG_EMPTY_SONG
		if only_line:
			msg = "현재 줄에는 모르는 단어가 없어요."
		elif not SongStudy.pick_unknown(song, {}, 1).is_empty():
			msg = MSG_EMPTY_ALL # 곡에는 단어가 있는데 모두 아는 단어로 표시돼 있다
		add_child(SpeakDrill.notice(msg, false))
		UI.fix_cjk(self)
		return

	var n_show: int = mini(vis.size(), shown)
	for k in n_show:
		var e: Dictionary = vis[k]
		add_child(_word_row(e))
		if str(e["lemma"]) == open_lemma:
			add_child(_detail(e))
	if n_show < vis.size():
		var more := SpeakDrill.touch_button("더 보기 (%d개 남음)" % (vis.size() - n_show), "soft", _acc)
		more.pressed.connect(show_more)
		add_child(more)
	UI.fix_cjk(self)


func _word_row(e: Dictionary) -> Button:
	var t: String = str(e["w"])
	var ko: String = str(e["ko"])
	if ko != "":
		t += "   " + ko
	if str(e["level"]) == "hard":
		t += "   (어려움)"
	var b := UI.option_row(t)
	b.set_meta("lemma", str(e["lemma"]))
	b.pressed.connect(func() -> void: toggle_word(str(e["lemma"])))
	if str(e["lemma"]) == open_lemma:
		UI.paint_option(b, "picked", _acc)
	return b


func _detail(e: Dictionary) -> Control:
	var lemma: String = str(e["lemma"])
	var card := UI.card("Card", 8)
	card.set_meta("detail_for", lemma)
	card.body.add_child(UI.label(str(e["w"]), "H2"))
	var reading: String = str(e["reading"])
	if lang == "en":
		if reading != "":
			card.body.add_child(UI.label("발음기호  /%s/" % reading.trim_prefix("/").trim_suffix("/"), "Muted"))
	else:
		ReadingLine.add(card.body, reading, "ja", Store.pref_bool("show_reading"), 0.0, "")
	var ko: String = str(e["ko"])
	card.body.add_child(UI.label(ko if ko != "" else MSG_NO_KO, "Strong" if ko != "" else "Muted"))
	if str(e["lemma"]) != str(e["w"]) and str(e["lemma"]) != "":
		card.body.add_child(UI.label("기본형  " + str(e["lemma"]), "Muted"))
	card.body.add_child(UI.label("곡에 %d번 나와요" % int(e["count"]), "Muted"))
	var ex: String = line_text(int(e["line_i"]))
	if ex != "":
		card.body.add_child(UI.label("♪ " + ex.left(80) + ("…" if ex.length() > 80 else ""), "Muted"))
	var row := UI.flow(8, 8)
	var sp := SpeakDrill.touch_button("▶ 단어 듣기", "soft", _acc)
	sp.pressed.connect(func() -> void: speak_word(lemma))
	row.add_child(sp)
	if player != null and is_instance_valid(player) and player.has_method("play_line"):
		var pl := SpeakDrill.touch_button("▶ 노래에서 듣기", "soft", _acc)
		pl.pressed.connect(func() -> void: play_line_of(lemma))
		row.add_child(pl)
	card.body.add_child(row)
	var row2 := UI.flow(8, 8)
	var done: bool = added.has(lemma)
	var ab := SpeakDrill.touch_button("✓ 복습에 있어요" if done else "복습에 추가", "soft" if done else "primary", _acc)
	ab.disabled = done
	ab.pressed.connect(func() -> void: add_card(lemma))
	row2.add_child(ab)
	var kb := SpeakDrill.touch_button("아는 단어", "outline", _acc)
	kb.pressed.connect(func() -> void: mark_known(lemma))
	row2.add_child(kb)
	card.body.add_child(row2)
	return card
