class_name CourseHome
extends VBoxContainer
## v2.0 코스 홈 (docs/v200_design.md §6, §11.2, §13.3, §14.2 E5): 레슨 탭 안에 들어가는 72주 길.
##
## 구성: [지금 위치 카드] + 블록 18개(0단계 입문, 1~17개월차) x 주 4칸의 길(PathBoard) + 주 상세 시트.
## 상태는 CourseModel.states(CourseStore.path_flags(), pos.w, CourseData.available_weeks()): 완료 done, 지금 current, 앞 2칸 open,
## 그 밖 locked, 내용이 아직 없는 주는 항상 locked + "준비 중"(눌러도 열리지 않는다). 잠긴 칸은 확인 시트 뒤에만 열린다.
## 진행 글은 CourseModel.progress_label 한 곳에서만 만든다. 이 화면은 코스 기록(CourseStore)을 읽기만 한다:
## 기록은 CoursePlayer 가 끝날 때 쓰고, 예전 길 기록(StudyLog 의 길 칸)과 PathModel 은 건드리지 않는다.
##
## 신호 unit_requested(spec): 플레이어를 열어 달라는 요청(레슨 탭이 연다). spec 은 CoursePlayer.open 에 그대로 넘긴다.
##   [점검으로 건너뛰기]는 점검 단위(d = 6)를 spec.skip = true 로 연다: 기록은 플레이어가 CourseStore.check_done(skip: true) 한 번만 한다.
## 레슨 탭이 쓰는 정적 함수: availability() mode_chosen() start_card() mode_selector() ask_start() unit_spec() skip_spec().
## 홈의 [새 코스로 시작] 카드(E6)는 ask_start(host, on_done) 를 부른다.

signal unit_requested(spec: Dictionary)

const GOAL_MIN := 45 ## 코스 시작 때 권하는 하루 목표(분)
const WD := ["일", "월", "화", "수", "목", "금", "토"]
const KIND_WORD := {"new": "새 내용", "speak": "말하기", "check": "점검", "free": "자유"}
const TEXT_START_BODY := "0부터 72주 코스예요. 이미 아는 주는 [점검으로 건너뛰기]로 넘길 수 있어요. 예전 12개월 길은 [레슨] 화면의 [예전 길]에서 계속 쓸 수 있어요."
const TEXT_LOCKED := "앞 단계를 먼저 하면 길이 순서대로 열려요. 그래도 미리 해 볼까요?"
const TEXT_SOON := "아직 준비 중인 주예요. 앱을 업데이트하면 열려요."
const TEXT_NO_DATA := "코스 내용을 읽지 못했어요."
const AHEAD_NOTE := "미리 해 보는 칸이에요. 진도는 지금 칸을 끝내야 넘어가요."
const TEXT_AHEAD := "준비된 주를 모두 마쳤어요. 다음 주는 준비 중이에요. 마친 주는 다시 할 수 있어요."

## 시험용: 마지막 시작 확인 시트(ask_start)와 그 결과.
static var last_start_sheet: Sheet = null

var boards: Array = [] ## PathBoard 18개(블록 순서)
var road: Dictionary = {} ## CourseModel.states 결과
var avail: int = 0
var cur_w: int = 1 ## 길의 "지금" 주(1..72)
var pos_w: int = 1
var pos_d: int = 1
var card_start_button: Button = null ## 카드의 [이어서 하기]
var week_sheet: Sheet = null ## 열려 있는 주 상세·확인 시트
var sheet_host: Node = null ## 시트를 붙일 곳(기본: 이 노드)


func _init() -> void:
	name = "CourseHome"
	add_theme_constant_override("separation", Ds.S3 if Platform.is_phone() else Ds.S4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


# ================================================================== 정적: 레슨 탭이 쓰는 것

## {"ok": bool, "text": String, "weeks": int}. 코스 내용을 쓸 수 있는가(없거나 깨졌거나 비었으면 한국어 안내 글).
static func availability() -> Dictionary:
	var r: Dictionary = CourseData.load_all()
	if not bool(r.get("ok", false)):
		var t: String = str(r.get("text_ko", ""))
		return {"ok": false, "text": t if t != "" else TEXT_NO_DATA, "weeks": 0}
	var n: int = CourseData.available_weeks()
	if n <= 0:
		return {"ok": false, "text": CourseFeed.TEXT_EMPTY, "weeks": 0}
	return {"ok": true, "text": "", "weeks": n}


## 학습자가 코스·예전 길을 한 번이라도 골랐는가(prefs.course_mode 가 "course" 또는 "legacy"). 이상한 값은 고르지 않은 것이다.
static func mode_chosen() -> bool:
	var v: Variant = Store.prefs.get(CourseStore.PREF_KEY, null)
	return v is String and (v == CourseStore.MODE_COURSE or v == CourseStore.MODE_LEGACY)


## "11월 14일 (금)"; 읽을 수 없는 날짜는 "".
static func date_label(iso: Variant) -> String:
	if not (iso is String) or not Plan.is_valid_iso(iso):
		return ""
	var days: int = Plan.iso_to_days(iso)
	var c: Dictionary = Plan.civil_from_days(days)
	return "%d월 %d일 (%s)" % [int(c["month"]), int(c["day"]), WD[Plan.weekday(days)]]


## 주 w 에서 [이 주 시작]이 여는 날: 지금 칸(pos)이 이 주면 그 날, 아니면 아직 안 한 첫 날(다 했으면 1일).
static func start_day(w: int) -> int:
	var p: Dictionary = CourseStore.pos()
	if int(p["w"]) == w:
		return clampi(int(p["d"]), 1, CourseModel.DAYS)
	var done: Array = CourseStore.week_state(w).get("days", [])
	for d in range(1, CourseModel.DAYS + 1):
		if not done.has(d):
			return d
	return 1


## [이 주 시작]이 CoursePlayer.open 에 넘기는 spec. kind 는 그 날의 종류(새 내용 new / 말하기 speak / 점검 check), 자유 날(D7)은
## 플레이어에 "free" 단위가 없어서 듣기(listen)로 연다. block 은 항상 "new"(그 칸을 끝내는 단위, CourseStore 계약).
static func unit_spec(w: int) -> Dictionary:
	var d: int = start_day(w)
	var kind: String = CourseModel.day_kind(w, d)
	if kind == "free" or kind == "":
		kind = "listen"
	return {"kind": kind, "w": w, "d": d, "block": "new"}


## [점검으로 건너뛰기]: 그 주의 주간 점검(D6)을 skip 점검으로 연다(플레이어가 check_done(skip: true) 한 번만 기록한다).
static func skip_spec(w: int) -> Dictionary:
	return {"kind": "check", "w": w, "d": 6, "block": "new", "skip": true}


## "주 5 · 가족·나 소개" 꼴 제목: "5주 · 가족·나 소개". 제목이 없으면 "5주".
static func week_title(w: int) -> String:
	var t: String = UI.plain(CourseData.week(w).get("title_ko", ""))
	return "%d주" % w if t == "" else "%d주 · %s" % [w, t]


## [새 코스로 시작] 카드. on_press 는 카드의 버튼을 눌렀을 때 부른다(확인 시트는 ask_start).
static func start_card(on_press: Callable) -> Control:
	var phone: bool = Platform.is_phone()
	var card := UI.card("BigCard", 12)
	card.name = "CourseStartCard"
	card.body.add_child(UI.label("새로 나온 코스", "Eyebrow", false))
	card.body.add_child(UI.label("0부터 72주 영어 말하기 코스", "H2"))
	card.body.add_child(UI.label("하루 45분씩 새 내용·복습·듣기·말하기를 해요. 예전 길은 그대로 남아요.", "Muted"))
	var b := UI.button("새 코스로 시작", "primary", Pal.PRIMARY, Ds.HOME_CTA_H_PHONE if phone else Ds.HOME_CTA_H_PC)
	b.name = "CourseStartButton"
	b.pressed.connect(func() -> void:
		if on_press.is_valid():
			on_press.call())
	card.body.add_child(b)
	return card


## [새 코스 | 예전 길] 선택 줄. current: "course" | "legacy". on_change(value).
static func mode_selector(current: String, on_change: Callable) -> Control:
	var seg := UI.segmented([[CourseStore.MODE_COURSE, "새 코스"], [CourseStore.MODE_LEGACY, "예전 길"]], current, on_change, func(_v: String) -> Color: return Pal.accent("en"))
	seg.name = "CourseModeSelector"
	return seg


## 시작 확인 시트. [시작]을 누르면 CourseStore.set_mode("course")(코스 파일도 만들어진다)와, 체크해 두었으면 하루 목표 45분 저장 뒤
## on_done(true). [나중에]·바깥을 눌러 닫으면 아무것도 바꾸지 않고 on_done(false). 코스 내용을 읽을 수 없으면 안내만 띄우고 on_done(false).
## on_done: Callable(started: bool) 또는 비어 있는 Callable().
static func ask_start(host: Node, on_done: Callable = Callable()) -> void:
	var info: Dictionary = availability()
	if not bool(info["ok"]):
		var m := UI.label(str(info["text"]))
		var s0 := Sheet.open(host, "코스를 열 수 없어요", m, [{"id": "close", "text": "닫기", "kind": "primary"}])
		last_start_sheet = s0
		s0.closed.connect(func(_r: Variant) -> void:
			if on_done.is_valid():
				on_done.call(false))
		return
	var col := UI.vbox(10)
	col.name = "CourseStartBody"
	col.add_child(UI.label(TEXT_START_BODY))
	var goal_on: Array = [StudyLog.goal_minutes() != GOAL_MIN]
	if bool(goal_on[0]):
		var row := UI.check_row("하루 목표를 %s으로 바꾸기" % CourseModel.progress_label("minutes", GOAL_MIN, 0), true, func(on: bool) -> void: goal_on[0] = on)
		row.name = "CourseGoalRow"
		col.add_child(row)
	var sh := Sheet.open(host, "새 코스로 시작할까요?", col, [
		{"id": "start", "text": "시작", "kind": "primary"},
		{"id": "later", "text": "나중에", "kind": "flat"}])
	last_start_sheet = sh
	sh.closed.connect(func(r: Variant) -> void:
		var started := false
		if str(r) == "start":
			started = CourseStore.set_mode(CourseStore.MODE_COURSE)
			if started and bool(goal_on[0]):
				StudyLog.set_goal_minutes(GOAL_MIN)
		if on_done.is_valid():
			on_done.call(started))


# ================================================================== 만들기

## 카드와 길을 (다시) 만든다. 코스 기록을 읽기만 한다.
func build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	boards = []
	card_start_button = null
	var info: Dictionary = availability()
	avail = int(info["weeks"])
	var p: Dictionary = CourseStore.pos()
	pos_w = int(p["w"])
	pos_d = int(p["d"])
	road = CourseModel.states(CourseStore.path_flags(), pos_w, avail)
	cur_w = int(road["current"]) + 1 if int(road["current"]) >= 0 else 1
	add_child(_card())
	var pending: Dictionary = CourseStore.check_pending()
	var states: Array = road["states"]
	var soon: Array = road["soon"]
	for n in range(1, CourseModel.BLOCKS + 1):
		var first_w: int = CourseModel.week_of(n, 1)
		var sts: Array = states.slice(first_w - 1, first_w + 3)
		var sn: Array = soon.slice(first_w - 1, first_w + 3)
		var names: Array = []
		for k in range(1, CourseModel.WEEKS_PER_BLOCK + 1):
			var w: int = CourseModel.week_of(n, k)
			var t: String = UI.plain(CourseData.week(w).get("title_ko", ""))
			if bool(pending["pending"]) and int(pending["w"]) == w:
				t = "점검 남음" if t == "" else "%s · 점검 남음" % t
			names.append(t)
		var done_k: int = sts.count("done")
		var label: String = CourseModel.block_label(n)
		var stage_t: String = CourseModel.stage_title(CourseModel.stage_of_week(first_w))
		var head: Control = PathBoard.month_header(n, stage_t if n > 1 else "", done_k, CourseModel.WEEKS_PER_BLOCK, label)
		add_child(head)
		var board := PathBoard.new()
		board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		board.build("en", n, sts, names, cur_w - 1, {"first_w": first_w, "soon": sn, "label": label})
		board.node_pressed.connect(_on_node)
		add_child(board)
		boards.append(board)
	UI.fix_cjk(self)


func _card() -> Control:
	var phone: bool = Platform.is_phone()
	var card := UI.card("BigCard", 14)
	card.name = "CourseCard"
	var finished: bool = bool(road.get("finished", false))
	var all_ready_done: bool = bool(road.get("avail_done", false)) and avail < CourseModel.WEEKS
	var eyebrow: String = "72주 코스 완료" if finished else "코스 진행"
	card.body.add_child(UI.label(eyebrow, "Eyebrow", false))
	var w: int = cur_w
	var d: int = start_day(w)
	card.body.add_child(UI.label("%d주 %d일" % [w, d], "H2"))
	var topic: String = UI.plain(CourseData.week(w).get("title_ko", ""))
	var stage_t: String = CourseModel.stage_title(CourseModel.stage_of_week(w))
	card.body.add_child(UI.label(stage_t if topic == "" else "%s · %s" % [stage_t, topic], "Muted"))
	card.body.add_child(UI.label("완료 %s" % CourseModel.progress_label("weeks", int(road["done_count"]), avail), "Strong", false))
	card.body.add_child(UI.progress_bar(float(int(road["done_count"])) / maxf(1.0, float(avail)), Pal.accent("en"), 8.0))
	var st: String = CourseStore.started()
	var sd: String = date_label(st)
	var line2: String = "지금 %d주차 · 전체 %s" % [w, CourseModel.progress_label("weeks", CourseModel.WEEKS, 0)]
	if sd != "":
		line2 += " · %s에 시작" % sd
	card.body.add_child(UI.label(line2, "Small", true))
	if avail < CourseModel.WEEKS:
		var soon_w: int = avail + 1
		card.body.add_child(UI.label("%d주부터는 준비 중이에요." % soon_w, "Small", true))
	if all_ready_done:
		card.body.add_child(UI.label(TEXT_AHEAD, "Muted"))
	var go := UI.button("이어서 하기", "primary", Pal.PRIMARY, Ds.HOME_CTA_H_PHONE if phone else Ds.HOME_CTA_H_PC)
	go.name = "CourseContinueButton"
	go.pressed.connect(func() -> void: unit_requested.emit(unit_spec(w)))
	go.disabled = avail <= 0
	card.body.add_child(go)
	card_start_button = go
	return card


## 주 w(1..72)의 노드 버튼. 없으면 null.
func node_of(w: int) -> Button:
	var n: int = CourseModel.block_of(w)
	var k: int = CourseModel.k_of(w)
	if n < 1 or n > boards.size():
		return null
	return (boards[n - 1] as PathBoard).node_button(k)


func current_node() -> Button:
	return node_of(cur_w)


## 지금 화면에 있는 노드 상태(주 w): "done|current|open|past|locked" 또는 "" (없음).
func state_of(w: int) -> String:
	var nb := node_of(w) as PathNode
	return nb.state if nb != null else ""


# ================================================================== 노드·시트

func _on_node(n: int, k: int, state: String) -> void:
	var w: int = CourseModel.week_of(n, k)
	if w < 1:
		return
	if _sheet_open():
		return
	if w > avail:
		week_sheet = Sheet.open(_host(), week_title(w), UI.label(TEXT_SOON), [{"id": "close", "text": "닫기", "kind": "primary"}])
		return
	if state == "locked":
		var ls := Sheet.open(_host(), week_title(w), UI.label(TEXT_LOCKED), [
			{"id": "preview", "text": "미리 해 보기", "kind": "primary"},
			{"id": "close", "text": "닫기", "kind": "flat"}])
		week_sheet = ls
		ls.closed.connect(func(r: Variant) -> void:
			if str(r) == "preview":
				open_week_sheet(w, "open"))
		return
	open_week_sheet(w, state)


func _sheet_open() -> bool:
	return week_sheet != null and is_instance_valid(week_sheet) and not week_sheet.is_closed()


func _host() -> Node:
	return sheet_host if sheet_host != null and is_instance_valid(sheet_host) else self


## 주 상세 시트: 제목·할 수 있게 되는 말·낱말·문형·장면·요일 칸 7개·[이 주 시작]·[점검으로 건너뛰기].
func open_week_sheet(w: int, state: String) -> Sheet:
	var done: bool = state == "done"
	var btns: Array = [{"id": "start", "text": "이 주 다시 하기" if done else "이 주 시작", "kind": "primary"}]
	if not done:
		btns.append({"id": "skip", "text": "점검으로 건너뛰기", "kind": "soft"})
	btns.append({"id": "close", "text": "닫기", "kind": "flat"})
	var sh := Sheet.open(_host(), week_title(w), week_body(w, state), btns)
	week_sheet = sh
	sh.closed.connect(func(r: Variant) -> void:
		if str(r) == "start":
			unit_requested.emit(unit_spec(w))
		elif str(r) == "skip":
			unit_requested.emit(skip_spec(w)))
	return sh


## 주 상세 시트의 몸통.
func week_body(w: int, state: String) -> Control:
	var col := UI.vbox(10)
	col.name = "WeekDetail"
	var rec: Dictionary = CourseData.week(w)
	var ws: Dictionary = CourseStore.week_state(w)
	var n: int = CourseModel.block_of(w)
	var k: int = CourseModel.k_of(w)
	col.add_child(UI.label("%s · %s %d주" % [CourseModel.stage_title(CourseModel.stage_of_week(w)), CourseModel.block_label(n), k], "Eyebrow"))
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	chips.name = "WeekChips"
	chips.add_child(UI.chip_kind(str(PathNode.STATE_WORD.get(state, "")), "ok" if state == "done" else ("info" if state == "current" else "neutral")))
	if bool(ws.get("weak", false)):
		chips.add_child(UI.chip_kind("점검 약함", "warn"))
	if bool(ws.get("skipped", false)):
		chips.add_child(UI.chip_kind("점검으로 건너뜀", "info"))
	var pending: Dictionary = CourseStore.check_pending()
	if bool(pending["pending"]) and int(pending["w"]) == w:
		chips.add_child(UI.chip_kind("점검 남음", "warn"))
	col.add_child(chips)
	var done_date: String = date_label(ws.get("done_date", ""))
	if bool(ws.get("done", false)) and done_date != "":
		col.add_child(UI.label("%s에 마쳤어요." % done_date, "Muted"))
	# 할 수 있게 되는 말
	var can: Variant = rec.get("can_do", [])
	if can is Array and not (can as Array).is_empty():
		col.add_child(UI.label("할 수 있게 되는 말", "Eyebrow", false))
		for c in can:
			col.add_child(UI.label("· %s" % UI.plain(c)))
	# 공부량
	var words: Variant = rec.get("words", {})
	var n_new: int = ((words as Dictionary).get("new", []) as Array).size() if words is Dictionary and (words as Dictionary).get("new", []) is Array else 0
	var n_pas: int = ((words as Dictionary).get("passive", []) as Array).size() if words is Dictionary and (words as Dictionary).get("passive", []) is Array else 0
	var pats: Array = rec.get("patterns", []) if rec.get("patterns", []) is Array else []
	var amount: String = "%s · %s" % [CourseModel.progress_label("words", n_new, 0), CourseModel.progress_label("patterns", pats.size(), 0)]
	if n_pas > 0:
		amount += " · 알아보는 %s" % CourseModel.progress_label("words", n_pas, 0)
	col.add_child(UI.label("이번 주 공부량", "Eyebrow", false))
	col.add_child(UI.label(amount))
	for pid in pats:
		var pt: String = UI.plain(CourseData.pattern(pid).get("title_ko", ""))
		if pt != "":
			col.add_child(UI.label("· %s" % pt, "Small"))
	# 장면·캐나다 노트
	var scene: Variant = rec.get("scene", {})
	if scene is Dictionary:
		var st: String = UI.plain((scene as Dictionary).get("title_ko", ""))
		if st != "":
			col.add_child(UI.label("이번 주 장면", "Eyebrow", false))
			col.add_child(UI.label(st))
			var ca: Variant = (scene as Dictionary).get("canada", [])
			if ca is Array:
				for line in ca:
					col.add_child(UI.label("· %s" % UI.plain(line), "Small"))
	# 요일 칸 7개
	col.add_child(UI.label("요일 칸", "Eyebrow", false))
	var days := HFlowContainer.new()
	days.name = "WeekDays"
	days.add_theme_constant_override("h_separation", 6)
	days.add_theme_constant_override("v_separation", 6)
	var done_days: Array = ws.get("days", [])
	for d in range(1, CourseModel.DAYS + 1):
		var kind: String = str(KIND_WORD.get(CourseModel.day_kind(w, d), ""))
		var is_done: bool = done_days.has(d)
		var txt: String = "%d일 %s" % [d, kind]
		var ck: String = "neutral"
		if is_done:
			txt += " 완료"
			ck = "ok"
		elif pos_w == w and pos_d == d:
			txt += " 지금"
			ck = "info"
		var chip := UI.chip_kind(txt, ck)
		chip.name = "Day%d" % d
		days.add_child(chip)
	col.add_child(days)
	# 점검 기록
	if bool(ws.get("has_check", false)):
		var chk: String = "점검 최고 %s" % CourseModel.progress_label("percent", int(ws.get("best", 0)), 0)
		var tries: int = int(ws.get("tries", 0))
		if tries > 0:
			chk += " · 시도 %d번" % tries
		var last: String = date_label(ws.get("last", ""))
		if last != "":
			chk += " · %s" % last
		col.add_child(UI.label(chk, "Small"))
	if state == "open":
		var note := UI.label(AHEAD_NOTE, "Muted")
		note.name = "AheadNote"
		col.add_child(note)
	UI.fix_cjk(col)
	return col
