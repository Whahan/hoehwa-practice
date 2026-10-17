class_name StatsView
extends AppView
## 기록 탭: 오늘 목표·연속·보호권, 이번 주 공부 시간, 레슨 정답률, 발음 점수, 약한 소리, 미션 별점.
## 모든 숫자는 StudyLog 에서 읽는다. 폰 세로(412)와 PC(1280) 공용: 폭 700 미만이면 차트를 세로로 쌓는다.

const WD_KO := ["월", "화", "수", "목", "금", "토", "일"]
const MISSION_ORDER := ["cafe_order", "self_intro", "hotel_checkin", "ask_directions", "restaurant", "pharmacy_doctor", "return_item", "job_interview"]
const MISSION_NAME := {
	"cafe_order": "카페 주문",
	"self_intro": "자기소개",
	"hotel_checkin": "호텔 체크인",
	"ask_directions": "길 묻기",
	"restaurant": "식당",
	"pharmacy_doctor": "약국·병원",
	"return_item": "환불·교환",
	"job_interview": "면접",
}
const TOUCH_MIN := 44.0
const WIDE_MIN := 700.0
const LESSON_DAYS := 14
const SCORE_DAYS := 30

var lang: String = "en"
var _scroll: PageScroll
var _grid: GridContainer
var _built: bool = false


func _ready() -> void:
	_scroll = PageScroll.new(960.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	lang = Store.lang()
	_build()


func refresh() -> void:
	if _scroll == null:
		return
	lang = Store.lang()
	StudyLog.flush()
	rebuild_keep_scroll(_scroll, _build)


func on_hide() -> void:
	StudyLog.flush()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _grid != null and is_instance_valid(_grid):
		_grid.columns = _columns()


func _columns() -> int:
	return 2 if size.x >= WIDE_MIN else 1


## Switches the language shown (also what the segmented control does).
func set_lang(l: String) -> void:
	if l != "en" and l != "ja":
		return
	lang = l
	Store.set_lang(l)
	_build()


func _build() -> void:
	if _scroll == null:
		return
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	_grid = null
	var top := UI.flow(12, 8)
	var title := UI.label("기록", "H2", false)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(title)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void: set_lang(v)))
	c.add_child(top)

	c.add_child(GoalCard.full(lang))
	if not StudyLog.has_data(lang):
		c.add_child(UI.label("아직 기록이 없어요. 레슨, 원어민 대화, 복습으로 연습하면 이곳에 공부 시간과 점수가 쌓여요.", "Muted"))

	c.add_child(_week_card())
	_grid = GridContainer.new()
	_grid.columns = _columns()
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(_lesson_card())
	_grid.add_child(_score_card())
	c.add_child(_grid)
	if lang == "en":
		c.add_child(_weak_card())
		c.add_child(_mission_card())
	else:
		c.add_child(UI.label("약한 소리와 미션 기록은 영어에서만 쌓여요.", "Small"))
	_touch(c)
	UI.fix_cjk(c)
	_built = true


# ---------------------------------------------------------------- cards

func _card(title: String, sub: String = "") -> CardBox:
	var card := UI.card("Card", 10)
	card.body.add_child(UI.label(title, "Strong"))
	if sub != "":
		card.body.add_child(UI.label(sub, "Small"))
	return card


func _empty(card: CardBox, text: String = "아직 기록이 없어요") -> void:
	card.body.add_child(UI.label(text, "Muted"))


func _week_card() -> Control:
	var acc: Color = Pal.accent(lang)
	var today: int = StudyLog.today()
	var monday: int = Plan.monday_of(today)
	var n_days: int = clampi(today - monday + 1, 1, 7)
	var rows: Array = StudyLog.range_summary(lang, n_days)
	var vals: Array = []
	var total := 0
	for r in rows:
		total += int(r["sec"])
		vals.append(float(r["sec"]) / 60.0)
	for i in range(n_days, 7):
		vals.append(null)
	var card := _card("이번 주 공부 시간 (분)", "월~일, 점선은 하루 목표")
	if total <= 0:
		_empty(card)
	else:
		var goal: int = StudyLog.goal_minutes()
		var ch := MiniChart.bars(vals, WD_KO, acc, n_days - 1, float(goal) if goal > 0 else -1.0)
		card.body.add_child(ch)
		card.body.add_child(UI.label("이번 주 합계 %d분" % (total / 60), "Small"))
	return card


func _lesson_card() -> Control:
	var rows: Array = StudyLog.range_summary(lang, LESSON_DAYS)
	var vals: Array = []
	var lbls: Array = []
	var any := false
	var ok_sum := 0
	var n_sum := 0
	for i in rows.size():
		var r: Dictionary = rows[i]
		if int(r["lessons_n"]) > 0:
			vals.append(100.0 * float(r["lessons_ok"]) / float(r["lessons_n"]))
			any = true
			ok_sum += int(r["lessons_ok"])
			n_sum += int(r["lessons_n"])
		else:
			vals.append(null)
		lbls.append(_date_label(str(r["iso"])) if (i == 0 or i == rows.size() - 1 or i == rows.size() / 2) else "")
	var card := _card("레슨 정답률 (최근 %d일)" % LESSON_DAYS, "레슨을 한 날의 정답률")
	if not any:
		_empty(card)
	else:
		var ch := MiniChart.line(vals, lbls, Pal.OK, 100.0)
		ch.value_format = "%d%%"
		card.body.add_child(ch)
		card.body.add_child(UI.label("기간 평균 %d%% (%d / %d문제)" % [roundi(100.0 * float(ok_sum) / float(n_sum)), ok_sum, n_sum], "Small"))
	return card


func _score_card() -> Control:
	var rows: Array = StudyLog.range_summary(lang, SCORE_DAYS)
	var vals: Array = []
	var lbls: Array = []
	var any := false
	var cnt := 0
	var sum := 0
	for i in rows.size():
		var r: Dictionary = rows[i]
		if int(r["score_n"]) > 0:
			vals.append(float(r["score_sum"]) / float(r["score_n"]))
			any = true
			cnt += int(r["score_n"])
			sum += int(r["score_sum"])
		else:
			vals.append(null)
		lbls.append(_date_label(str(r["iso"])) if (i == 0 or i == rows.size() - 1 or i == rows.size() / 2) else "")
	var card := _card("발음 점수 평균 (최근 %d일)" % SCORE_DAYS, "하루 평균 점수")
	if not any:
		_empty(card)
	else:
		var ch := MiniChart.line(vals, lbls, Pal.accent(lang), 100.0)
		card.body.add_child(ch)
		card.body.add_child(UI.label("기간 평균 %d점 (%d번 채점)" % [roundi(float(sum) / float(cnt)), cnt], "Small"))
	return card


func _weak_card() -> Control:
	var card := _card("약한 소리 TOP 3", "최근 30번 기준 틀린 비율")
	var weak: Array = StudyLog.weak_phonemes("en", 3)
	if weak.is_empty():
		_empty(card, "표본이 더 쌓이면 약한 소리를 찾아 드려요. 레슨이나 쉐도잉에서 따라 말해 보세요.")
		return card
	var chips := UI.flow(8, 8)
	for w in weak:
		var heard_txt := ""
		var best_c := 0
		for hk in (w["heard"] as Dictionary).keys():
			if int(w["heard"][hk]) > best_c:
				best_c = int(w["heard"][hk])
				heard_txt = " · %s로 들림" % str(hk)
		chips.add_child(UI.chip("/%s/ %d%%%s" % [str(w["p"]), roundi(float(w["rate"]) * 100.0), heard_txt], Pal.BAD, Pal.BAD_SOFT))
	card.body.add_child(chips)
	var first_p: String = str(weak[0]["p"])
	var b := UI.button("집중 연습", "soft", Pal.accent("en"), 48.0)
	b.pressed.connect(func() -> void: go_practice(first_p))
	card.body.add_child(b)
	return card


func _mission_card() -> Control:
	var card := _card("미션 별점")
	var ids: Array = MISSION_ORDER.duplicate()
	for id in StudyLog.mission_ids():
		if not ids.has(id):
			ids.append(id)
	var played := 0
	var chips := UI.flow(8, 8)
	for id in ids:
		var best: Dictionary = StudyLog.mission_best(str(id))
		if best.is_empty():
			continue
		played += 1
		var stars: int = clampi(int(best.get("stars", 0)), 0, 3)
		chips.add_child(UI.chip("%s %s%s" % [MISSION_NAME.get(id, str(id)), "★".repeat(stars), "☆".repeat(3 - stars)], Pal.WARN, Pal.WARN_SOFT, "%d번 도전" % int(best.get("plays", 0))))
	if played == 0:
		_empty(card, "아직 한 미션이 없어요")
	else:
		card.body.add_child(chips)
	return card


# ---------------------------------------------------------------- helpers

func _date_label(iso: String) -> String:
	var p: PackedStringArray = iso.split("-")
	if p.size() != 3:
		return ""
	return "%d/%d" % [int(p[1]), int(p[2])]


## Every button on this page is at least 44 px tall (touch target) unless it has meta "touch_exempt".
func _touch(node: Node) -> void:
	for ch in node.get_children():
		if ch is Button and not bool((ch as Button).get_meta("touch_exempt", false)):
			(ch as Button).custom_minimum_size.y = maxf((ch as Button).custom_minimum_size.y, TOUCH_MIN)
		_touch(ch)


## "집중 연습": open the practice hub on that phoneme (the hub reads PracticeView.pending). Without the practice
## tab the navigation request is simply ignored by main.gd.
func go_practice(p: String) -> void:
	var path := "res://scripts/views/practice_view.gd"
	if ResourceLoader.exists(path):
		var scr: Variant = load(path)
		if scr is GDScript:
			(scr as GDScript).set("pending", {"kind": "phoneme", "p": p})
	Store.navigate.emit("practice", lang)
