class_name SongSingTab
extends VBoxContainer
## 따라 부르기 탭 (docs/song_study_design.md §6, U-10): 한 줄씩 듣고(SongPlayer) 따라 부른다 → SongSingDrill 이 녹음 · /score 채점.
## - 녹음이 시작되기 직전(Recorder.started)에 SongPlayer.pause() — 마이크가 음악을 받지 않게.
## - 점수 70 이상이면 줄마다 한 번 StudyLog.add_event(lang, "shadow", 1) (드릴은 기록하지 않는다 — 이중 집계 방지).
## - 폰 단독(점수 낼 곳이 없음)이면 SpeakDrill 이 SelfRatePanel 자가 평가로 바꾼다: /score 는 보내지 않고, "잘했어요"는 70점으로 통과 처리.
## 탭 위젯 계약은 song_study_screen.gd 머리말 참고.

signal line_passed(line_i: int, score: int)

const NOTE := "한 줄씩 듣고 따라 불러 보세요. 녹음하는 동안 노래는 멈춰요. 노래 점수는 참고용이에요."
const SELF_NOTE := "지금은 점수를 낼 수 없어요(점수는 PC 연결 시). 따라 부른 뒤 내 목소리와 원어민 소리를 들어 보고 스스로 평가해요."

var song: Dictionary = {}
var lang: String = "en"
var player: SongPlayer = null
var screen: Node = null
var line: int = 0
var drill: SongSingDrill = null
var recorder: RecorderWidget = null
var passed_lines: Dictionary = {} ## 줄 번호 -> 통과 점수 (이 탭을 연 동안, 줄마다 기록은 한 번)
var shadow_events: int = 0 ## 이 탭이 StudyLog 에 더한 shadow 이벤트 수
var pause_calls: int = 0 ## 녹음 시작 직전에 SongPlayer.pause() 를 부른 횟수

var _line_box: VBoxContainer = null
var _count_label: Label = null
var _prev_btn: Button = null
var _next_btn: Button = null
var _listen_btn: Button = null


func _init() -> void:
	name = "SongSingTab"
	add_theme_constant_override("separation", Ds.S3)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func setup(song_in: Dictionary, ctx: Dictionary = {}) -> void:
	song = song_in
	lang = str(ctx.get("lang", song.get("lang", "en")))
	player = ctx.get("player", null)
	screen = ctx.get("screen", null)
	var n: int = line_count()
	line = clampi(int(ctx.get("line", -1)), 0, maxi(n - 1, 0))
	var acc: Color = Pal.accent(lang)

	var intro := UI.card("Card", 6)
	intro.body.add_child(UI.label("따라 부르기", "Eyebrow", false))
	intro.body.add_child(UI.label(NOTE, "Muted"))
	if SelfRatePanel.needed():
		intro.body.add_child(UI.label(SELF_NOTE, "Small"))
	add_child(intro)
	if n == 0:
		add_child(UI.label("가사 줄이 없어요.", "Muted"))
		return

	# line stepper
	var step := UI.flow(8, 6)
	_prev_btn = SpeakDrill.touch_button("◀ 이전", "soft", acc)
	_prev_btn.pressed.connect(func() -> void: go_line(line - 1))
	step.add_child(_prev_btn)
	_count_label = UI.label("", "Strong", false)
	_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	step.add_child(_count_label)
	_next_btn = SpeakDrill.touch_button("다음 ▶", "soft", acc)
	_next_btn.pressed.connect(func() -> void: go_line(line + 1))
	step.add_child(_next_btn)
	add_child(step)

	_line_box = UI.vbox(8)
	add_child(_line_box)

	_listen_btn = SpeakDrill.touch_button("▶ 이 줄 듣기", "soft", acc)
	_listen_btn.pressed.connect(listen_line)
	add_child(_listen_btn)

	drill = SongSingDrill.new(lang)
	recorder = drill.make_recorder("따라 부르기")
	recorder.wide = Platform.is_phone()
	add_child(recorder)
	add_child(drill)
	drill.scored.connect(_on_scored)
	if not Recorder.started.is_connected(_on_rec_started):
		Recorder.started.connect(_on_rec_started)
	_apply_line()


func _exit_tree() -> void:
	if Recorder.started.is_connected(_on_rec_started):
		Recorder.started.disconnect(_on_rec_started)


func on_show() -> void:
	pass


## 다른 탭으로 가거나 화면을 떠날 때: 녹음 · 채점 중단.
func on_hide() -> void:
	if drill != null and is_instance_valid(drill):
		drill.stop_all()


## 다른 탭에서 고른 줄을 따라간다.
func set_line(i: int) -> void:
	go_line(i)


func line_count() -> int:
	var ls: Variant = song.get("lines", [])
	return (ls as Array).size() if ls is Array else 0


func go_line(i: int) -> void:
	var n: int = line_count()
	if n == 0 or drill == null:
		return
	i = clampi(i, 0, n - 1)
	if i == line:
		return
	line = i
	_apply_line()
	if screen != null and screen.has_method("select_line"):
		screen.call("select_line", i, false)


## 지금 줄을 SongPlayer 로 듣는다 (속도 · 반복은 재생 막대 설정).
func listen_line() -> void:
	if screen != null and screen.has_method("play_line"):
		screen.call("play_line", line)
	elif player != null:
		player.play_line(line, 1)


func current_text() -> String:
	return str(_line_dict().get("text", ""))


func _line_dict() -> Dictionary:
	var ls: Variant = song.get("lines", [])
	if ls is Array and line >= 0 and line < (ls as Array).size() and (ls as Array)[line] is Dictionary:
		return (ls as Array)[line]
	return {}


func _apply_line() -> void:
	var ln: Dictionary = _line_dict()
	var n: int = line_count()
	_count_label.text = "%d / %d줄" % [line + 1, n]
	_prev_btn.disabled = line <= 0
	_next_btn.disabled = line >= n - 1
	UI.clear(_line_box)
	var card := UI.card("BigCard", 8)
	var big := UI.label(str(ln.get("text", "")), "")
	big.add_theme_font_size_override("font_size", Ds.fs(22))
	big.add_theme_font_override("font", UI.bold_font())
	card.body.add_child(big)
	if lang == "ja":
		ReadingLine.add(card.body, str(ln.get("reading", "")), lang, Store.pref_bool("show_reading"), 0.0, str(ln.get("pron", "")))
	var ko: String = str(ln.get("ko", ""))
	if Store.pref_bool("show_ko") and ko != "":
		card.body.add_child(UI.label(ko, "Muted"))
	_line_box.add_child(card)
	if passed_lines.has(line):
		_line_box.add_child(_pass_label(int(passed_lines[line])))
	UI.fix_cjk(_line_box)
	drill.set_target(str(ln.get("text", "")), str(ln.get("reading", "")) if lang == "ja" else "", ko)


# ---------------------------------------------------------------- recording / scoring

## 녹음이 시작되려는 순간: 내 녹음기가 맞으면 노래를 멈춘다.
func _on_rec_started() -> void:
	if recorder == null or not is_instance_valid(recorder):
		return
	if Recorder.owner_id != recorder.get_instance_id():
		return
	pause_calls += 1
	if player != null and is_instance_valid(player):
		player.pause()


func _on_scored(res: Dictionary, _tgt: String) -> void:
	var sc: int = clampi(roundi(float(res.get("score", 0))), 0, 100)
	if sc < SpeakDrill.PASS_SCORE or passed_lines.has(line):
		return
	passed_lines[line] = sc
	if _line_box != null and is_instance_valid(_line_box):
		_line_box.add_child(_pass_label(sc))
	shadow_events += 1
	StudyLog.add_event(lang, "shadow", 1)
	line_passed.emit(line, sc)


func _pass_label(sc: int) -> Label:
	var l := UI.colored("✓ 이 줄은 통과했어요 (%d점)" % sc, Pal.OK_ON, "Strong")
	l.name = "PassMark"
	return l
