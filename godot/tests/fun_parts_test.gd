extends Node
## 주간 리포트 카드와 홈 "이번 주" 카드(FunParts) 시험 (docs/v160_fun_design.md §6.5 B2-5, B2-6, B2-7, B2-8).
##   PC:   godot --headless --path godot res://tests/fun_parts_test.tscn
##   폰:   godot --headless --path godot --resolution 412x915 res://tests/fun_parts_test.tscn -- --phone [--font-scale=1.5] [--dark]
## 리포트 사전은 실제 WeekReport.build 에 손으로 만든 14일 입력을 넣어 만든다(계약이 어긋나면 이 시험이 먼저 안다).
## StudyLog·Store 를 읽거나 쓰지 않고 파일도 쓰지 않는다. 서버 접속 없음.
## 검사기(글자 찾기·삐져나옴·크기 검사)는 일부러 망가뜨린 입력을 넣어 실제로 FAIL 하는지도 본다 ("selfcheck FAIL-as-expected" 줄).
## 마지막 줄: "== fun_parts: N passed, M failed ==", 실패가 있으면 종료 코드 1.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _opened: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _size_window(want: Vector2i) -> void:
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== fun_parts start (%s, scale %s%s) ==" % ["phone" if _phone else "pc", str(_scale), ", dark" if _dark else ""])
	await _size_window(Vector2i(412, 915) if _phone else Vector2i(1280, 800))
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)

	_selfchecks()
	await _test_report_shapes()
	await _test_report_garbage()
	await _test_home_card()
	await _test_home_garbage()
	await _test_layout()
	_test_file_rules()

	print("== fun_parts: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- fixtures / helpers

## 7일치 항목(오래된 순). 값은 마지막 날에 몰아 넣고 sec 는 매일 같다.
func _week(first_iso_days: int, sec_each: int, n_les: int, les_ok: int, score_n: int, score_sum: int, newcards: int, reviews: int) -> Array:
	var out: Array = []
	for i in 7:
		var last: bool = i == 6
		out.append({
			"iso": Plan.days_to_iso(first_iso_days + i), "sec": sec_each,
			"lessons_ok": les_ok if last else 0, "lessons_n": n_les if last else 0,
			"score_n": score_n if last else 0, "score_sum": score_sum if last else 0,
			"n": {"lessons": 6 if last and n_les > 0 else 0, "newcards": newcards if last else 0, "reviews": reviews if last else 0},
		})
	return out


func _D() -> int:
	return Plan.days_from_civil(2026, 11, 14)


## 기록 많음: 126분(지난주 70분), 레슨 6개 정답률 83%(지난주 80%), 새 카드 18, 복습 52, 발음 78점(지난주 72점, +6).
func _rich() -> Dictionary:
	var cur: Array = _week(_D() - 6, 1080, 6, 5, 4, 312, 18, 52)
	var prev: Array = _week(_D() - 13, 600, 5, 4, 4, 288, 5, 10)
	return WeekReport.build(cur, prev, "en", Plan.days_to_iso(_D()))


## 지난주 기록 없음.
func _no_prev() -> Dictionary:
	return WeekReport.build(_week(_D() - 6, 600, 3, 3, 0, 0, 2, 4), _week(_D() - 13, 0, 0, 0, 0, 0, 0, 0), "ja", Plan.days_to_iso(_D()))


## 전부 0.
func _all_zero() -> Dictionary:
	return WeekReport.build(_week(_D() - 6, 0, 0, 0, 0, 0, 0, 0), _week(_D() - 13, 0, 0, 0, 0, 0, 0, 0), "en", Plan.days_to_iso(_D()))


## 점수 표본이 적음(이번 주 2, 지난주 5): 평균은 있지만 비교는 없다.
func _few_scores() -> Dictionary:
	return WeekReport.build(_week(_D() - 6, 900, 4, 3, 2, 150, 3, 9), _week(_D() - 13, 800, 4, 3, 5, 400, 3, 9), "en", Plan.days_to_iso(_D()))


func _walk(node: Node, out: Array = []) -> Array:
	out.append(node)
	for ch in node.get_children():
		_walk(ch, out)
	return out


func _texts(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is Label:
			out.append((n as Label).text)
		elif n is Button and (n as Button).text != "":
			out.append((n as Button).text)
	return out


func _any_text(node: Node, part: String) -> bool:
	for t in _texts(node):
		if part in str(t):
			return true
	return false


func _all_text(node: Node) -> String:
	return " | ".join(_texts(node))


func _glyph_kinds(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is GlyphIcon:
			out.append((n as GlyphIcon).kind)
	return out


func _buttons(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is Button:
			out.append(n)
	return out


func _sticks_out(root: Node, w: float) -> Array:
	var wide: Array = []
	for n in _walk(root):
		if n is Control and (n as Control).is_visible_in_tree() and (n as Control).get_global_rect().end.x > w + 1.5:
			wide.append("%s %.0f" % [n.get_class(), (n as Control).get_global_rect().end.x])
	return wide


## 카드를 폭 w 칸 안에 넣고 레이아웃이 자리잡을 때까지 기다린다. 반환 [holder, card].
func _place(card: Control, w: float) -> Array:
	var holder := VBoxContainer.new()
	holder.size = Vector2(w, 600)
	add_child(holder)
	holder.add_child(card)
	await _frames(4)
	return [holder, card]


func _on_open(kind: String) -> void:
	_opened.append(kind)


func _tap(c: Control) -> void:
	# UI.on_tap: PC reacts on press; phone on release (same spot). Both are sent, so the test works in either mode.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(5, 5)
	press.global_position = Vector2(5, 5)
	c.gui_input.emit(press)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = Vector2(5, 5)
	rel.global_position = Vector2(5, 5)
	c.gui_input.emit(rel)


# ---------------------------------------------------------------- selfchecks

func _selfchecks() -> void:
	# 글자 찾기: 없는 글자는 못 찾는다
	var l := Label.new()
	l.text = "공부 시간"
	add_child(l)
	fails(not _any_text(l, "레슨"), "text finder does not find a word that is not there")
	l.queue_free()
	# 삐져나옴 검사기
	var holder := Control.new()
	holder.size = Vector2(200, 100)
	add_child(holder)
	var wide := ColorRect.new()
	wide.size = Vector2(300, 20)
	holder.add_child(wide)
	fails(_sticks_out(holder, 200.0).size() > 0, "overflow checker flags a 300 px wide child in a 200 px parent")
	holder.queue_free()
	# 가짜 리포트 자체 점검: 손계산과 같다 (126분 = 7일 x 1080초 / 60, 지난주 70분, 정답률 83 / 80, 점수 78 / 72, 차이 +6)
	var r: Dictionary = _rich()
	ok(r["minutes"] == 126 and r["minutes_prev"] == 70 and r["lesson_acc"] == 83 and r["lesson_acc_prev"] == 80 and r["score_avg"] == 78 and r["score_prev"] == 72 and r["score_delta"] == 6, "fixture: rich report = 126 min (prev 70), 83%% (80%%), 78 (72, +6)")
	ok(r["new_cards"] == 18 and r["reviews"] == 52 and r["lessons"] == 6 and not r["empty"], "fixture: 18 new cards, 52 reviews, 6 lessons, not empty")
	ok(_all_zero()["empty"] == true and _few_scores()["score_delta"] == null and _no_prev()["minutes_prev"] == 0, "fixtures: all-zero is empty, few scores has no delta, no-prev has prev 0")


# ---------------------------------------------------------------- B2-5 리포트 카드 네 모양

func _test_report_shapes() -> void:
	print("[report card shapes]")
	var w: float = 392.0 if _phone else 640.0
	# 1) 기록 많음
	var c1: CardBox = FunParts.report_card(_rich())
	var p1: Array = await _place(c1, w)
	for need in ["공부 시간", "레슨", "새 카드", "발음 점수", "공부한 날"]:
		ok(_any_text(c1, need), "rich: has '%s'" % need)
	var t1: String = _all_text(c1)
	ok("이번 주 리포트 · 11.08 ~ 11.14 (영어)" in t1, "rich: title with the date range and the language")
	ok("126분 (지난주 +56분)" in t1, "rich: study time 126분 with the change +56")
	ok("6개 · 정답률 83% (지난주 80%)" in t1, "rich: lessons 6, accuracy 83% (80% last week)")
	ok("18 · 복습 52번" in t1, "rich: 18 new cards, 52 reviews")
	ok("평균 78점 (지난주 72점, +6)" in t1, "rich: pronunciation 78 (72, +6)")
	ok("7일" in t1 and "7일" in t1, "rich: days studied is shown out of 7")
	ok("지난주보다 56분 더 공부했어요." in t1 and "발음 점수가 6점 올랐어요." in t1, "rich: the rule lines of the report are shown")
	ok("1.6.0" in t1, "rich: the 'new cards count from 1.6.0' note")
	ok(not _any_text(c1, "아직 기록이 없어요"), "rich: no empty-state text")
	ok(c1.get_meta("empty") == false and (c1.get_meta("report") as Dictionary)["minutes"] == 126, "rich: meta report / empty")
	p1[0].queue_free()
	# 2) 지난주 없음
	var c2: CardBox = FunParts.report_card(_no_prev())
	var p2: Array = await _place(c2, w)
	for need in ["공부 시간", "레슨", "새 카드", "발음 점수"]:
		ok(_any_text(c2, need), "no previous week: has '%s'" % need)
	ok(_any_text(c2, "지난주 기록 없음") and _any_text(c2, "(일본어)"), "no previous week: says so, and names the language")
	ok(_any_text(c2, "기록이 적어요"), "no previous week: no scores -> '기록이 적어요'")
	p2[0].queue_free()
	# 3) 전부 0
	var c3: CardBox = FunParts.report_card(_all_zero())
	var p3: Array = await _place(c3, w)
	ok(_any_text(c3, "아직 기록이 없어요"), "all zero: one 'no record yet' line")
	ok(c3.get_meta("empty") == true, "all zero: meta empty")
	for need in ["공부 시간", "레슨", "새 카드", "발음 점수"]:
		ok(_any_text(c3, need), "all zero: the card names '%s' (what will pile up)" % need)
	ok(not _any_text(c3, "126") and not _any_text(c3, "정답률"), "all zero: no numbers rows")
	p3[0].queue_free()
	# 4) 점수 표본이 적음
	var c4: CardBox = FunParts.report_card(_few_scores())
	var p4: Array = await _place(c4, w)
	for need in ["공부 시간", "레슨", "새 카드", "발음 점수"]:
		ok(_any_text(c4, need), "few scores: has '%s'" % need)
	ok(_any_text(c4, "비교하기엔 기록이 적어요") and _any_text(c4, "평균 75점"), "few scores: shows the average 75 but says a comparison needs more records")
	ok(not _any_text(c4, "올랐어요"), "few scores: no 'went up' line")
	p4[0].queue_free()
	# compact
	var cc: CardBox = FunParts.report_card(_rich(), true)
	var pc: Array = await _place(cc, w)
	ok(_any_text(cc, "공부 126분 · 레슨 6개 · 새 카드 18") and cc.get_meta("line") == "공부 126분 · 레슨 6개 · 새 카드 18", "compact: just the 3 numbers in one line")
	ok(not _any_text(cc, "발음") and not _any_text(cc, "정답률"), "compact: nothing else")
	pc[0].queue_free()
	var ce: CardBox = FunParts.report_card(_all_zero(), true)
	var pe: Array = await _place(ce, w)
	ok(_any_text(ce, "쌓여요") and ce.get_meta("line") == "", "compact + empty: a hint instead of numbers")
	pe[0].queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-8 리포트 카드 쓰레기 입력

func _test_report_garbage() -> void:
	print("[report card garbage]")
	var w: float = 392.0 if _phone else 640.0
	var junk: Array = [null, {}, "x", 5, [1, 2], {"empty": "no"}, {"empty": false}, {"empty": false, "minutes": "x", "lessons": NAN, "new_cards": null, "lesson_acc": INF, "score_avg": -50, "score_n": "z", "days_studied": 99, "lines": "oops", "from": 5, "to": []}]
	var i := 0
	for j in junk:
		var c: CardBox = FunParts.report_card(j)
		var p: Array = await _place(c, w)
		var built: bool = is_instance_valid(c) and c.get_child_count() > 0
		ok(built, "report_card(junk #%d) is built without an error" % i)
		if i <= 4 or i == 5:
			ok(_any_text(c, "아직 기록이 없어요") and c.get_meta("empty") == true, "report_card(junk #%d) draws the 'no record' card" % i)
		p[0].queue_free()
		var cc: CardBox = FunParts.report_card(j, true)
		ok(is_instance_valid(cc), "report_card(junk #%d, compact) is built" % i)
		cc.queue_free()
		i += 1
	# 마지막 쓰레기: 숫자 줄들이 정리돼서 나온다
	var last: CardBox = FunParts.report_card(junk[7])
	var pl: Array = await _place(last, w)
	var tl: String = _all_text(last)
	ok("0분" in tl and "7일" in tl and "기록이 적어요" in tl, "dirty numbers become 0 / clamp to 7 days / 'few scores': %s" % tl.substr(0, 120))
	ok(not ("nan" in tl.to_lower()) and not ("inf" in tl.to_lower()) and not ("-50" in tl), "no nan / inf / negative text")
	pl[0].queue_free()
	# 음수·큰 값 문구
	var weird: Dictionary = _rich()
	weird["minutes"] = -5
	weird["lessons"] = 10 ** 12
	weird["score_delta"] = -9
	weird["score_prev"] = 87
	var cw: CardBox = FunParts.report_card(weird)
	var pw: Array = await _place(cw, w)
	var tw: String = _all_text(cw)
	ok("(지난주 87점, -9)" in tw, "negative score change is written with a minus sign")
	ok(is_instance_valid(cw) and not ("-5분" in tw), "a negative minutes value never prints as -5분")
	pw[0].queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-6 홈 카드

func _test_home_card() -> void:
	print("[home card]")
	var w: float = 392.0 if _phone else 340.0
	_opened.clear()
	var counts := {"got": 9, "total": 25, "unseen": 2}
	var cja: CardBox = FunParts.home_card("ja", _rich(), counts, _on_open)
	var pja: Array = await _place(cja, w)
	var bj: Dictionary = cja.get_meta("buttons")
	ok(_buttons(cja).size() == 4, "ja: 4 buttons (%d)" % _buttons(cja).size())
	ok(bj["speed"] != null and bj["kana"] != null and bj["diary"] != null and bj["badges"] != null, "ja: meta buttons speed / kana / diary / badges")
	ok((bj["speed"] as Button).text == "60초 퀴즈" and (bj["kana"] as Button).text == "가나 코스" and (bj["diary"] as Button).text == "일기" and (bj["badges"] as Button).text == "배지 9/25", "ja: button texts 60초 퀴즈 / 가나 코스 / 일기 / 배지 9/25")
	ok(_any_text(cja, "이번 주") and _any_text(cja, "공부 126분 · 레슨 6개 · 새 카드 18"), "ja: title and the 3 numbers")
	for k in ["speed", "kana", "diary", "badges"]:
		(bj[k] as Button).pressed.emit()
	ok(_opened == ["speed", "kana", "diary", "badges"], "ja: the buttons call on_open with speed / kana / diary / badges: %s" % str(_opened))
	_opened.clear()
	var area: Control = cja.get_meta("tap_area")
	_tap(area)
	ok(_opened == ["report"], "ja: tapping the card body calls on_open('report'): %s" % str(_opened))
	_opened.clear()
	var dots := 0
	for n in _walk(bj["badges"]):
		if n is GlyphIcon and bool((n as GlyphIcon).get_meta("new_dot", false)):
			dots += 1
	ok(dots == 1 and cja.has_meta("badge_dot"), "ja: the badges button has a dot (2 unseen)")
	ok(not (bj["speed"] as Button).accessibility_name.contains("새 배지") and (bj["badges"] as Button).accessibility_name.contains("새 배지 2개"), "ja: the badge button's accessible name tells there are 2 new badges")
	pja[0].queue_free()
	# 영어: 가나 코스 없음
	var cen: CardBox = FunParts.home_card("en", _rich(), {"got": 0, "total": 25, "unseen": 0}, _on_open)
	var pen: Array = await _place(cen, w)
	var be: Dictionary = cen.get_meta("buttons")
	ok(_buttons(cen).size() == 3 and be["kana"] == null and not _any_text(cen, "가나 코스"), "en: 3 buttons (60초 퀴즈, 일기, 배지), no 가나 코스")
	ok((be["badges"] as Button).text == "배지 0/25" and not cen.has_meta("badge_dot"), "en: 배지 0/25 and no dot when nothing is unseen")
	(be["badges"] as Button).pressed.emit()
	(be["speed"] as Button).pressed.emit()
	(be["diary"] as Button).pressed.emit()
	ok(_opened == ["badges", "speed", "diary"], "en: badges, speed and diary buttons work")
	_opened.clear()
	pen[0].queue_free()
	# 기록 없음
	var cz: CardBox = FunParts.home_card("ja", _all_zero(), counts, _on_open)
	var pz: Array = await _place(cz, w)
	ok(_any_text(cz, "공부를 시작하면 이번 주 기록이 여기에 쌓여요") and not _any_text(cz, "공부 0분"), "empty report: one hint line instead of numbers")
	ok(_buttons(cz).size() == 4, "empty report: the buttons are still there")
	pz[0].queue_free()
	await _frames(2)


func _test_home_garbage() -> void:
	print("[home card garbage]")
	var w: float = 392.0 if _phone else 340.0
	_opened.clear()
	var bad_counts: Array = [null, {}, "x", {"got": "a", "total": NAN, "unseen": null}, {"got": -3, "total": INF, "unseen": -1}, {"got": 99999999999, "total": 5, "unseen": []}]
	var i := 0
	for bc in bad_counts:
		var c: CardBox = FunParts.home_card("en", null, bc, Callable())
		var p: Array = await _place(c, w)
		ok(is_instance_valid(c) and _buttons(c).size() == 3, "home_card(bad counts #%d, no report, empty callback) is drawn with 3 buttons" % i)
		var txt: String = _all_text(c).to_lower()
		ok(not ("nan" in txt) and not ("inf" in txt) and not ("-3" in txt), "bad counts #%d: no nan / inf / negative text" % i)
		for b in _buttons(c):
			(b as Button).pressed.emit() # an empty on_open must not fail
		_tap(c.get_meta("tap_area"))
		p[0].queue_free()
		i += 1
	var cb: CardBox = FunParts.home_card("zz", {}, {}, _on_open)
	ok(_buttons(cb).size() == 3, "unknown language counts as not-ja (no kana button)")
	cb.queue_free()
	ok(_opened.is_empty(), "nothing was reported to the real callback in the garbage runs")
	await _frames(2)


# ---------------------------------------------------------------- B2-7 레이아웃

func _test_layout() -> void:
	print("[layout]")
	var w: float = 392.0 if _phone else 640.0
	var cards: Array = [
		["report rich", FunParts.report_card(_rich())],
		["report empty", FunParts.report_card(_all_zero())],
		["report few scores", FunParts.report_card(_few_scores())],
		["home ja", FunParts.home_card("ja", _rich(), {"got": 9, "total": 25, "unseen": 3}, _on_open)],
		["home en empty", FunParts.home_card("en", _all_zero(), {"got": 0, "total": 25, "unseen": 0}, _on_open)],
	]
	for pair in cards:
		var nm: String = pair[0]
		var c: Control = pair[1]
		var p: Array = await _place(c, w)
		var holder: Control = p[0]
		var wide: Array = _sticks_out(holder, w)
		ok(wide.is_empty(), "%s: nothing sticks out to the right of %.0f px %s" % [nm, w, str(wide.slice(0, 3))])
		ok(holder.get_combined_minimum_size().x <= w + 0.5, "%s: minimum width %.0f fits %.0f" % [nm, holder.get_combined_minimum_size().x, w])
		var small: Array = []
		var need: float = 48.0 if _phone else 36.0
		for b in _buttons(c):
			if (b as Button).is_visible_in_tree() and (b as Button).size.y < need - 0.5:
				small.append("%s %.1f" % [(b as Button).text, (b as Button).size.y])
		ok(small.is_empty(), "%s: every button is at least %d px tall %s" % [nm, int(need), str(small)])
		var tiny: Array = []
		for n in _walk(c):
			if n is Label and (n as Label).is_visible_in_tree() and (n as Label).get_theme_font_size("font_size") < 12:
				tiny.append((n as Label).text)
		ok(tiny.is_empty(), "%s: no text under 12 px %s" % [nm, str(tiny.slice(0, 2))])
		# 글자가 잘리지 않는다: 줄바꿈하는 글자 칸은 자기 칸 폭 안에서 끝난다
		var clipped: Array = []
		for n in _walk(c):
			if n is Label and (n as Label).is_visible_in_tree() and (n as Label).get_combined_minimum_size().x > (n as Label).size.x + 1.5:
				clipped.append((n as Label).text)
		ok(clipped.is_empty(), "%s: no label is wider than its box %s" % [nm, str(clipped.slice(0, 2))])
		p[0].queue_free()
	# 홈 카드 버튼 높이를 명시한다(설계: 홈 카드 버튼 >= 48)
	var hc: CardBox = FunParts.home_card("ja", _rich(), {"got": 1, "total": 25, "unseen": 0}, _on_open)
	var ph: Array = await _place(hc, w)
	var bh := 9999.0
	for b in _buttons(hc):
		bh = minf(bh, (b as Button).size.y)
	ok(bh >= (48.0 if _phone else 36.0), "home card buttons: min height %.1f" % bh)
	# 검사기 점검: 겹침 검사가 실제로 나쁨을 잡는다 (카드 밖 형제 노드를 일부러 오른쪽으로 밀어 낸다)
	var host := Control.new()
	host.size = Vector2(w, 100)
	add_child(host)
	var off := ColorRect.new()
	off.size = Vector2(50, 10)
	off.position = Vector2(w + 100.0, 0)
	host.add_child(off)
	await _frames(1)
	fails(_sticks_out(host, w).size() > 0, "overflow checker flags a node placed at x=%.0f" % (w + 100.0))
	host.queue_free()
	ph[0].queue_free()
	await _frames(2)


func _test_file_rules() -> void:
	print("[file rules]")
	var raw_ok := true
	var f := FileAccess.open("res://scripts/ui/fun_parts.gd", FileAccess.READ)
	var raw: String = f.get_as_text()
	f.close()
	var code := ""
	for ln in raw.split("\n"):
		code += ln.get_slice("#", 0) + "\n"
	for word in ["StudyLog.", "Store.", "BadgeEngine", "Color(" + "\"" + "#", "HTTP" + "Request"]:
		if word in code:
			raw_ok = false
			print("  (found '%s' in fun_parts.gd)" % word)
	ok(raw_ok, "fun_parts.gd (code, comments cut) has no data-layer call, no hex colour, no network word")
