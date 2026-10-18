class_name GoalCard
extends VBoxContainer
## 오늘 목표 카드. full() = 기록 탭의 큰 카드(목표 시간 고르기 포함), compact() = 오늘 화면의 한 줄 요약.
## 내용은 StudyLog 에서 읽는다. 목표를 바꾸면 스스로 다시 그리고 `goal_changed` 를 보낸다.

signal goal_changed

const CHOICES := [5, 10, 15, 20, 30, 0] ## minutes, 0 = off
const TOUCH_H := 48.0

var lang: String = "en"
var is_compact: bool = false


static func full(l: String) -> GoalCard:
	var g := GoalCard.new()
	g.lang = l
	g.is_compact = false
	g._build()
	return g


static func compact(l: String) -> GoalCard:
	var g := GoalCard.new()
	g.lang = l
	g.is_compact = true
	g._build()
	return g


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)


func refresh() -> void:
	UI.clear(self)
	_build()


## "12분" style text for seconds (rounded down; "1분 미만" under a minute is shown as 0분).
static func minutes_text(sec: int) -> String:
	return "%d분" % (maxi(sec, 0) / 60)


func _build() -> void:
	var acc: Color = Pal.accent(lang)
	var info: Dictionary = StudyLog.settle(lang)
	var sec: int = StudyLog.today_seconds(lang)
	var goal: int = StudyLog.goal_minutes()
	var reached: bool = goal > 0 and sec >= goal * 60
	var frac: float = clampf(float(sec) / float(goal * 60), 0.0, 1.0) if goal > 0 else 0.0
	var st: int = int(info["streak"])
	var tk: int = int(info["tokens"])

	if is_compact:
		var panel := UI.tinted_panel(Pal.soft(lang), Color(0, 0, 0, 0), 0, Ds.R_S, Ds.S4, 10)
		var v := UI.vbox(6)
		var goal_txt: String = ("오늘 %s / %d분" % [minutes_text(sec), goal]) if goal > 0 else ("오늘 %s (목표 꺼짐)" % minutes_text(sec))
		var streak_txt: String = ("연속 %d일" % st) if st > 0 else "오늘부터 시작"
		v.add_child(UI.colored("%s · %s · 보호권 %d개" % [goal_txt, streak_txt, tk], Pal.on(lang), "Strong"))
		if goal > 0:
			v.add_child(UI.progress_bar(frac, _bar_color(acc, reached), 8.0))
		panel.add_child(v)
		add_child(panel)
		UI.fix_cjk(self)
		return

	var card := UI.card("Card", 12)
	card.body.add_child(UI.label("오늘 목표", "Eyebrow", false))
	var head := UI.flow(10, 4)
	if goal > 0:
		head.add_child(UI.label("%s / %d분" % [minutes_text(sec), goal], "H2", false))
		if reached:
			head.add_child(UI.chip_kind("달성!", "ok"))
	else:
		head.add_child(UI.label("목표 꺼짐 · 오늘 %s" % minutes_text(sec), "H3", false))
	card.body.add_child(head)
	if goal > 0:
		card.body.add_child(UI.progress_bar(frac, _bar_color(acc, reached), 12.0))
	var chips := UI.flow(8, 6)
	chips.add_child(UI.chip_kind(("연속 %d일" % st) if st > 0 else "연속 기록 없음", "lang_" + lang))
	chips.add_child(UI.chip_kind("보호권 %d개" % tk, "warn"))
	card.body.add_child(chips)
	card.body.add_child(UI.label("하루를 놓쳐도 보호권이 있으면 연속 기록이 이어져요. 7일 연속할 때마다 1개를 받고, 최대 2개까지 모아요. 보호권 개수보다 많은 날을 놓치면(1개일 때 2일 이상) 연속 기록이 이어지지 않고 보호권은 그대로 남아요.", "Small"))
	card.body.add_child(UI.label("하루 목표", "Small", false))
	var row := UI.flow(8, 8)
	for m in CHOICES:
		var is_sel: bool = m == goal
		var b := UI.button("끔" if m == 0 else "%d분" % m, "primary" if is_sel else "outline", acc, TOUCH_H)
		b.custom_minimum_size.x = 64.0
		b.pressed.connect(_choose.bind(m))
		row.add_child(b)
	card.body.add_child(row)
	add_child(card)
	UI.fix_cjk(self)


static func _bar_color(acc: Color, reached: bool) -> Color:
	return Pal.OK if reached else acc


func _choose(m: int) -> void:
	if m == StudyLog.goal_minutes():
		return
	StudyLog.set_goal_minutes(m)
	StudyClock.check_goal(lang) ## today's time may already reach the new, lower goal
	refresh()
	goal_changed.emit()
