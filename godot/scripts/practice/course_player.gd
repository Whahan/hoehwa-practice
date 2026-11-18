class_name CoursePlayer
extends Control
## v2.0 코스 플레이어 (docs/v200_design.md §3.1, §10.4, §10.5, §14.2 E4b): 하루 한 단위를 처음부터 끝까지 진행한다.
##
## 열기:  var p := CoursePlayer.open(host, {"kind":"new","w":5,"d":2})   # host 에 붙는다. 플레이어는 스스로 지우지 않는다(끝나면 host 가 지운다).
## spec:  kind "new|listen|speak|recap|check|month"(필수), w, d(필수), block("new|review|listen|speak": 선택), seen(낱말 id 배열), speed(듣기 속도), half(bool),
##        seed(int: 선택, 시험용).  block 을 빼면 new->"new", recap->"new", listen->"listen", speak->"speak" 다.
##        D5(말하기 날)의 "새 내용" 단위는 kind "speak" 이므로 호출한 쪽이 block:"new" 를 꼭 넣어야 칸이 끝난다(CourseStore 계약).
##        매일 말하기 블록(12분)은 block:"speak".
## 신호:  finished(result)  결과 카드에서 [완료] 를 눌렀다(기록은 결과 카드가 뜨기 전에 이미 끝났다).
##        left()            [그만하기] 로 나갔거나 오류 화면에서 [돌아가기] 를 눌렀다(기록 없음).
## 뒤로:  go_back() -> bool  안드로이드 뒤로 가기. 푸는 중이면 확인 시트를 열고(두 번째는 시트를 닫아 "계속하기"), 결과 카드면 [완료], 오류면 [돌아가기].
##
## 흐름: LessonBuilder(CourseFeed.build_unit)가 만든 문제를 CourseExerciseView 에 한 문제씩 올린다.
##  - 숙달 루프(§3.1): 틀린 문제는 같은 단계 끝에 다시 나온다(최대 MAX_RETRY 번). 다시 나올 때 보기 순서·타일 순서는 첫 번째와 다르다
##    (보기는 다시 섞고 answer 인덱스를 맞춘다, 타일은 문제 id 에 꼬리를 붙여 view 의 섞기 시드를 바꾼다). 판정은 항상 문제 화면(view)이 한다.
##    루프는 new·listen·speak 단위에만 돈다(점검·월말·복귀 점검은 한 번만 낸다). 말하기 "어려워요"는 다시 내지 않는다.
##    역할 대화(내 줄이 있는 dialogue_script)는 틀리면 한 번만(MAX_RETRY_DIALOGUE) 다시 낸다.
##  - 배운 것만: 화면에 올리기 직전마다 LexiconGuard.check_exercise_set 으로 다시 검사한다. 위반 문제는 올리지 않고 dropped 로 센다(사용자에게는 보이지 않는다).
##    `CoursePlayer.guard_hook(ex, verdict, cur_o)` 가 있으면 검사 결과를 알려 준다(시험이 위반 0 을 확인한다).
##  - seen: 소개 카드(teach_word)를 올린 낱말 id. 안 본 낱말을 묻는 문제는 가드가 버린다.
##  - 깨진 문제(CourseExerciseView.validate 실패)는 조용히 건너뛴다(skipped). 데이터가 사라지면 오류 화면으로 안전 종료한다(기록 없음).
## 끝나면(문제 1개 이상 풀었을 때) 기록한 뒤 결과 카드를 보인다:
##    new/listen/speak/recap -> CourseStore.unit_done({unit,w,d,ok,total,first_try,wrong,words_new,completed,seconds,block}),
##    check -> CourseStore.check_done, month -> CourseStore.month_done,
##    기록은 "준비 -> 기록" 순서다: 점수·복습 카드 목록 등을 모두 계산하고 데이터가 아직 있는지 확인한 뒤에만 쓴다(중간에 데이터가 사라지면 아무것도 기록하지 않는다).
##    코스 진도 기록(unit_done/check_done/month_done)을 맨 먼저 하고, saved:false 면(거절 ignored 가 아닌 저장 실패) 아무것도 더 쓰지 않고 오류 화면으로 끝낸다.
##    그 뒤 Store·StudyLog 저장이 실패하면 결과 카드가 "일부 기록을 저장하지 못했어요"라고 말한다(Store.save_progress 는 결과를 돌려주지 않아 같은 파일을 한 번 더 써서 확인한다).
##    저장소가 칸 기록을 거절하면(미리 해 본 칸 ahead, 코스 모드 아님) 레슨·XP 는 남기되 결과 카드가 그렇게 알리고, ahead 면 복습 카드는 넣지 않는다.
##    CourseCards.add_unit(kind new 만), 틀린 문제의 복습 카드, StudyLog.add_lesson, Store.add_xp / inc_stat / mark_today, StudyLog.note_resume.
##    예전 12개월 길의 레슨 기록은 건드리지 않는다. 일부러 그만두면 아무것도 기록하지 않는다.
## 결과 카드: 시간은 CourseModel.fmt_minutes, 진행은 CourseModel.progress_label 로만 만든다(초·5자리 숫자를 직접 보이지 않는다).

signal finished(result: Dictionary)
signal left

const LANG := "en"
const MAX_RETRY := 2 ## 숙달 루프: 틀린 문제를 같은 단계 끝에 다시 내는 최대 횟수(§3.1)
const MAX_RETRY_DIALOGUE := 1 ## 역할 대화는 한 번만 다시 낸다(피드백이 "나중에 한 번 더 나와요"라고 말한다)
const RESHUFFLE := true ## 다시 낼 때 보기를 다시 섞는다(false 면 위치로 맞힐 수 있다: 시험이 잡아야 한다)
const LOOP_KINDS := ["new", "listen", "speak"]
const RETRY_TYPES := ["recognize", "recall", "build", "listen", "speak", "dialogue_script"]
const KINDS := ["new", "listen", "speak", "recap", "check", "month"]
const BLOCK_OF_KIND := {"new": "new", "recap": "new", "listen": "listen", "speak": "speak", "check": "new", "month": "new"}
const MAX_SECONDS := 7200
const TILE_TRIES := 30
const MIN_H := 44.0
const KIND_TITLES := {"new": "새 내용", "listen": "듣기", "speak": "말하기", "recap": "복귀 점검", "check": "주간 점검", "month": "월말 말하기"}
const DONE_TITLES := {"new": "오늘 새 내용을 마쳤어요", "listen": "듣기를 마쳤어요", "speak": "말하기를 마쳤어요", "recap": "복귀 점검을 마쳤어요",
	"check": "주간 점검을 마쳤어요", "month": "월말 말하기를 마쳤어요"}
const TEXT_BUILD := "오늘 할 문제를 만들지 못했어요. 돌아가서 다시 시도해 주세요."
const TEXT_DATA := "코스 데이터를 읽을 수 없어요. 앱을 다시 설치해 주세요."
const TEXT_EMPTY := "풀 수 있는 문제가 없어서 기록하지 않았어요. 돌아가서 다시 시도해 주세요."
const TEXT_SAVE := "진도를 저장하지 못했어요. 저장 공간을 확인한 뒤 다시 해 주세요."
const TEXT_PARTIAL := "일부 기록을 저장하지 못했어요. 저장 공간을 확인해 주세요."
const TEXT_KIND := "이 단위는 아직 열 수 없어요."
const MONTH_PASS := 70
const CARD_NOTE := "틀린 문제"

## 시험 전용 훅. 비어 있으면 실제 값을 쓴다.
static var guard_hook: Callable = Callable() ## (ex: Dictionary, verdict: Dictionary, cur_o: int) 화면에 올리기 전 가드 검사 결과
static var build_hook: Callable = Callable() ## (spec: Dictionary, seed: int) -> LessonBuilder.build 모양의 결과(가짜 빌더)
static var clock_hook: Callable = Callable() ## () -> int 밀리초(걸린 시간 시험용)

## 상태: idle | run | result | error | left
var state: String = "idle"
var spec: Dictionary = {}
var kind: String = ""
var w: int = 1
var d: int = 1
var block: String = "new"
var cur_o: int = 11
var seed_value: int = 0
var queue: Array = [] ## 항목 {ex, stage, attempt, rec}. rec = recs 의 번호(소개 카드는 -1)
var idx: int = 0
var recs: Array = [] ## 문제마다 한 번(처음 낸 것) 기록
var seen: Dictionary = {} ## 소개 카드를 올린 낱말 id -> true
var words_new: Array = []
var dropped: int = 0 ## 가드가 버린 문제 수(시험이 센다. 화면에는 안 보인다)
var skipped: int = 0 ## 깨져서 건너뛴 문제 수
var retries_made: int = 0
var result: Dictionary = {}
var error_text: String = ""
var view: CourseExerciseView = null
var back_btn: Button = null
var done_btn: Button = null
var error_back_btn: Button = null
var title_label: Label = null
var progress_label_node: Label = null
var progress_bar: ProgressBar = null
var retry_label_node: Label = null

var _top_holder: Control = null
var _body: Control = null
var _result_box: Control = null
var _error_box: Control = null
var _leave_sheet: Sheet = null
var _t_start: int = 0
var _paused_total: int = 0
var _pause_since: int = -1
var _recorded: bool = false
var _finished_sent: bool = false


func _init() -> void:
	name = "CoursePlayer"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	var root := VBoxContainer.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_top_holder = _make_top()
	root.add_child(_top_holder)
	_body = Control.new()
	_body.name = "Body"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.clip_contents = true
	root.add_child(_body)


func _exit_tree() -> void:
	if view != null and is_instance_valid(view):
		view.stop_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_pause_begin()
		if view != null and is_instance_valid(view):
			view.stop_all() # 소리·녹음은 멈추지만 문제 화면은 그대로 둔다(돌아오면 같은 문제)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		if _leave_sheet == null:
			_pause_end()


# ================================================================== 공개 함수

## 플레이어를 만들어 host 에 붙이고 시작한다.
static func open(host: Node, spec_in: Variant) -> CoursePlayer:
	var p := CoursePlayer.new()
	if host != null and is_instance_valid(host):
		host.add_child(p)
	p.start(spec_in)
	return p


## 단위를 만들고 첫 문제를 보인다. 만들 수 없으면 한국어 오류 화면(+ [돌아가기]).
func start(spec_in: Variant) -> void:
	_reset_run()
	spec = (spec_in as Dictionary).duplicate(true) if spec_in is Dictionary else {}
	var kv: Variant = spec.get("kind")
	kind = String(kv) if kv is String else ""
	w = _whole(spec.get("w"))
	d = _whole(spec.get("d"))
	if not KINDS.has(kind) or w < 1 or w > CourseModel.WEEKS or d < 1 or d > CourseModel.DAYS:
		_show_error(TEXT_KIND if not KINDS.has(kind) else TEXT_BUILD)
		return
	cur_o = w * 10 + d
	block = _block_of(spec)
	var sv: Variant = spec.get("seed")
	seed_value = int(sv) if (sv is int or (sv is float and is_finite(sv))) else int(Time.get_ticks_usec() % 2147483647)
	var seen_in: Variant = spec.get("seen")
	if seen_in is Array:
		for s in seen_in:
			if s is String:
				seen[s] = true
	var bspec: Dictionary = {"kind": kind, "w": w, "d": d, "seen": seen.keys()}
	if spec.get("speed") is float or spec.get("speed") is int:
		bspec["speed"] = float(spec["speed"])
	if spec.get("half") is bool:
		bspec["half"] = spec["half"]
	var r: Variant = build_hook.call(bspec, seed_value) if build_hook.is_valid() else CourseFeed.build_unit(bspec, seed_value)
	if not (r is Dictionary) or not bool((r as Dictionary).get("ok", false)) or not ((r as Dictionary).get("exercises") is Array) \
			or ((r as Dictionary)["exercises"] as Array).is_empty():
		var st: Dictionary = CourseFeed.status()
		var why: String = String(st.get("text_ko", "")) if not bool(st.get("ok", false)) else ""
		_show_error(why if why != "" else TEXT_BUILD)
		return
	for e in (r as Dictionary)["exercises"]:
		queue.append({"ex": e, "stage": _stage_of(e), "attempt": 0, "rec": -1 if CourseExerciseView.is_info_card(e) else -2})
	_make_view()
	state = "run"
	_t_start = _now()
	_top_holder.visible = true
	back_btn.visible = true
	title_label.text = "%d주 %d일  ·  %s" % [w, d, String(KIND_TITLES.get(kind, ""))]
	_present()


## 안드로이드 뒤로 가기. 처리했으면 true.
func go_back() -> bool:
	match state:
		"run":
			if _leave_sheet != null and is_instance_valid(_leave_sheet):
				_leave_sheet.close("continue")
			else:
				ask_leave()
			return true
		"result":
			press_done()
			return true
		"error":
			_leave_now()
			return true
	return false


## 확인 시트("그만할까요?")를 연다: [계속하기] / [그만하기].
func ask_leave() -> void:
	if state != "run" or (_leave_sheet != null and is_instance_valid(_leave_sheet)):
		return
	if view != null:
		view.stop_all()
	_pause_begin()
	var msg: Label = UI.label("지금까지 푼 것은 기록되지 않아요. 그만할까요?")
	_leave_sheet = Sheet.open(self, "그만할까요?", msg, [
		{"id": "continue", "text": "계속하기", "kind": "primary"},
		{"id": "quit", "text": "그만하기", "kind": "danger"}])
	_leave_sheet.closed.connect(_on_leave_closed)


func leave_sheet() -> Sheet:
	return _leave_sheet if _leave_sheet != null and is_instance_valid(_leave_sheet) else null


## 결과 카드의 [완료]. 한 번만 finished 를 낸다.
func press_done() -> void:
	if state != "result" or _finished_sent:
		return
	_finished_sent = true
	finished.emit(result)


## 지금 화면의 문제 항목(없으면 {}).
func current_entry() -> Dictionary:
	if state == "run" and idx >= 0 and idx < queue.size():
		return queue[idx]
	return {}


## 문제 개수 {total, answered, retry_left}. total 은 처음 낸 문제 수(재출제는 늘리지 않는다, 버려진 문제만 빠진다),
## answered 는 그 중 한 번이라도 푼 수, retry_left 는 아직 안 푼 "다시 풀기" 수다.
func question_counts() -> Dictionary:
	var total := 0
	var retry_left := 0
	for e in queue:
		var r: int = int(e["rec"])
		if int(e["attempt"]) == 0:
			if r >= 0 or r == -2:
				total += 1
		elif r >= 0 and not bool(e.get("done", false)):
			retry_left += 1
	var answered := 0
	for rc in recs:
		if bool(rc["answered"]):
			answered += 1
	return {"total": total, "answered": answered, "retry_left": retry_left}


# ================================================================== 만들기

func _reset_run() -> void:
	state = "idle"
	queue = []
	idx = 0
	recs = []
	seen = {}
	words_new = []
	dropped = 0
	skipped = 0
	retries_made = 0
	result = {}
	error_text = ""
	_recorded = false
	_finished_sent = false
	_paused_total = 0
	_pause_since = -1
	_clear_boxes()


func _clear_boxes() -> void:
	for n in [_result_box, _error_box]:
		if n != null and is_instance_valid(n):
			n.get_parent().remove_child(n)
			n.queue_free()
	_result_box = null
	_error_box = null
	done_btn = null
	error_back_btn = null


func _make_top() -> Control:
	var holder := PanelContainer.new()
	holder.name = "TopBar"
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_bottom = 1
	holder.add_theme_stylebox_override("panel", st)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	holder.add_child(col)
	var row := UI.hbox(8)
	row.name = "TopRow"
	col.add_child(UI.margin(row, Ds.S3, 6, Ds.S3, 0))
	back_btn = UI.button("나가기", "flat", Pal.INK, MIN_H)
	back_btn.name = "BackBtn"
	back_btn.pressed.connect(ask_leave)
	row.add_child(back_btn)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sp)
	progress_label_node = UI.label("", "Small", false)
	progress_label_node.name = "ProgressLabel"
	row.add_child(progress_label_node)
	# 제목은 줄을 바꿔서라도 끝까지 보인다(주·일이 잘리면 안 된다). 주·일을 앞에 둔다.
	title_label = UI.label("", "Strong", true)
	title_label.name = "TitleLabel"
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(UI.margin(title_label, Ds.S3, 0, Ds.S3, 0))
	retry_label_node = UI.label("", "Small", true)
	retry_label_node.name = "RetryLabel"
	retry_label_node.visible = false
	col.add_child(UI.margin(retry_label_node, Ds.S3, 0, Ds.S3, 0))
	progress_bar = UI.progress_bar(0.0, Pal.accent(LANG), 8.0)
	progress_bar.name = "ProgressBar"
	col.add_child(UI.margin(progress_bar, Ds.S3, 0, Ds.S3, 8))
	holder.visible = false
	return holder


func _make_view() -> void:
	if view != null and is_instance_valid(view):
		view.queue_free()
	view = CourseExerciseView.new()
	_body.add_child(view)
	view.answered.connect(_on_answered)
	view.next_requested.connect(_on_next)


func _fit(root: Node) -> void:
	var h: float = maxf(MIN_H, Ds.touch_min() if Platform.is_phone() else 0.0)
	SpeakDrill.fit_touch(root, h)
	UI.fix_cjk(root)


# ================================================================== 한 문제씩

func _present() -> void:
	while idx < queue.size():
		var e: Dictionary = queue[idx]
		var exv: Variant = e["ex"]
		if not (exv is Dictionary) or CourseExerciseView.validate(exv) != "":
			skipped += 1
			e["rec"] = -3
			idx += 1
			continue
		var ex: Dictionary = exv
		var data: Dictionary = CourseFeed.builder_data()
		if data.is_empty() or not (data.get("_idx") is Dictionary):
			_show_error(String(CourseFeed.status().get("text_ko", "")) if String(CourseFeed.status().get("text_ko", "")) != "" else TEXT_DATA)
			return
		var verdict: Dictionary = LexiconGuard.check_exercise_set(ex, cur_o, seen, data["_idx"])
		if guard_hook.is_valid():
			guard_hook.call(ex, verdict, cur_o)
		if not bool(verdict.get("ok", false)):
			dropped += 1
			e["rec"] = -3
			idx += 1
			continue
		_show_entry(e)
		return
	_finish_unit()


func _show_entry(e: Dictionary) -> void:
	var ex: Dictionary = e["ex"]
	if int(e["rec"]) == -2: # 처음 올리는 문제: 기록 칸을 만든다
		recs.append({"id": String(ex.get("id", "")), "type": String(ex.get("type", "")), "mode": String(ex.get("mode", "")),
			"item": _item_of(ex), "ex": ex.duplicate(true), "answered": false, "ok": false, "first_ok": false, "first_try": false,
			"gave_up": false, "self_rated": false, "orders": [], "tries": 0})
		e["rec"] = recs.size() - 1
	if String(ex.get("type", "")) == "teach_word" and ex.get("item") is String:
		var wid: String = String(ex["item"])
		if not seen.has(wid):
			seen[wid] = true
			words_new.append(wid)
	var attempt: int = int(e["attempt"])
	var ctx: Dictionary = {"retry": attempt > 0, "next_text": "다음", "hints": _hints_for_week(), "autoplay": true}
	view.show_exercise(ex, ctx)
	if int(e["rec"]) >= 0:
		var rc: Dictionary = recs[int(e["rec"])]
		if String(ex.get("type", "")) == "build":
			var first: Array = (rc["orders"] as Array)[0] if not (rc["orders"] as Array).is_empty() else []
			var base: String = String(rc["id"])
			var order: Array = _tile_texts()
			var k := 0
			while attempt > 0 and RESHUFFLE and k < TILE_TRIES and order.size() > 1 and (order == first or (k < TILE_TRIES / 2 and (rc["orders"] as Array).has(order))):
				k += 1
				ex["id"] = "%s~r%d.%d" % [base, attempt, k]
				view.show_exercise(ex, ctx)
				order = _tile_texts()
			(rc["orders"] as Array).append(order)
		elif ex.get("options") is Array:
			(rc["orders"] as Array).append(_option_texts(ex))
	_update_progress()
	_fit(_top_holder)


func _on_answered(res: Dictionary) -> void:
	if state != "run" or idx >= queue.size():
		return
	var e: Dictionary = queue[idx]
	if bool(res.get("skipped", false)):
		skipped += 1
		return
	var ri: int = int(e["rec"])
	if ri < 0:
		return
	var rc: Dictionary = recs[ri]
	var attempt: int = int(e["attempt"])
	var good: bool = bool(res.get("ok", false))
	var gave_up: bool = bool(res.get("gave_up", false))
	e["done"] = true
	rc["tries"] = int(rc["tries"]) + 1
	if attempt == 0:
		rc["answered"] = true
		rc["first_ok"] = good
		rc["first_try"] = good and bool(res.get("first_try", false))
		rc["gave_up"] = gave_up
		rc["mode"] = String(res.get("mode", rc["mode"]))
	if bool(res.get("self_rated", false)):
		rc["self_rated"] = true
	if good:
		rc["ok"] = true
	elif LOOP_KINDS.has(kind) and RETRY_TYPES.has(String(rc["type"])):
		var is_dlg: bool = String(rc["type"]) == "dialogue_script"
		if (is_dlg or not gave_up) and attempt < (MAX_RETRY_DIALOGUE if is_dlg else MAX_RETRY):
			_insert_retry(e)
	_update_progress()


func _on_next() -> void:
	if state != "run":
		return
	idx += 1
	_present()


## 틀린 문제의 사본을 같은 단계의 맨 끝에 넣는다.
func _insert_retry(e: Dictionary) -> void:
	var rc: Dictionary = recs[int(e["rec"])]
	var attempt: int = int(e["attempt"]) + 1
	var copy: Dictionary = (rc["ex"] as Dictionary).duplicate(true)
	copy["id"] = "%s~r%d" % [String(rc["id"]), attempt]
	if RESHUFFLE and copy.get("options") is Array:
		_reshuffle_options(copy, rc, attempt)
	var stage: String = String(e["stage"])
	var end: int = idx
	while end + 1 < queue.size() and String((queue[end + 1] as Dictionary)["stage"]) == stage:
		end += 1
	queue.insert(end + 1, {"ex": copy, "stage": stage, "attempt": attempt, "rec": int(e["rec"])})
	retries_made += 1


## 보기를 다시 섞고 answer(와 option_ids)를 맞춰 고친다. 첫 번째 순서와 다르고, 가능하면 직전과 정답 위치도 다르게.
func _reshuffle_options(ex: Dictionary, rc: Dictionary, attempt: int) -> void:
	var opts: Array = ex["options"]
	var n: int = opts.size()
	var ans: Variant = ex.get("answer")
	if n < 2 or not (ans is int or ans is float) or int(ans) < 0 or int(ans) >= n:
		return
	var ids: Variant = ex.get("option_ids")
	var have_ids: bool = ids is Array and (ids as Array).size() == n
	var orders: Array = rc["orders"]
	var first: Array = orders[0] if not orders.is_empty() else []
	var prev: Array = orders[orders.size() - 1] if not orders.is_empty() else []
	var prev_pos: int = -1
	if not prev.is_empty():
		var old_ex: Dictionary = rc["ex"]
		var correct_text: String = String((old_ex["options"] as Array)[int(old_ex["answer"])])
		prev_pos = prev.find(correct_text)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_value, String(rc["id"]), attempt])
	var perm: Array = []
	var good := false
	for t in 60:
		perm = range(n)
		for i in range(n - 1, 0, -1):
			var j: int = rng.randi_range(0, i)
			var tmp: Variant = perm[i]
			perm[i] = perm[j]
			perm[j] = tmp
		var texts: Array = perm.map(func(p: Variant) -> String: return String(opts[int(p)]))
		var new_pos: int = perm.find(int(ans))
		if texts != first and new_pos != prev_pos and (t >= 30 or not orders.has(texts)):
			good = true
			break
	if not good:
		for k in range(1, n):
			perm = range(n).map(func(p: Variant) -> int: return (int(p) + k) % n)
			var texts2: Array = perm.map(func(p: Variant) -> String: return String(opts[int(p)]))
			if texts2 != first:
				break
	var new_opts: Array = []
	var new_ids: Array = []
	for p in perm:
		new_opts.append(opts[int(p)])
		if have_ids:
			new_ids.append((ids as Array)[int(p)])
	ex["options"] = new_opts
	if have_ids:
		ex["option_ids"] = new_ids
	ex["answer"] = perm.find(int(ans))


func _option_texts(ex: Dictionary) -> Array:
	var out: Array = []
	for o in ex["options"]:
		out.append(String(o))
	return out


func _tile_texts() -> Array:
	var out: Array = []
	if view != null:
		for b in view.tile_btns:
			out.append(String((b as Button).text))
	return out


func _stage_of(ex: Variant) -> String:
	if ex is Dictionary:
		var s: Variant = (ex as Dictionary).get("stage")
		if s is String and s != "":
			return s
		var t: Variant = (ex as Dictionary).get("type")
		if t is String:
			if t == "teach_word" or t == "teach_pattern":
				return "intro"
			return t
	return ""


func _item_of(ex: Dictionary) -> String:
	for k in ["item", "sent", "dialogue"]:
		if ex.get(k) is String and String(ex[k]) != "":
			return String(ex[k])
	return String(ex.get("id", ""))


## 힌트 규칙(§4): 8~16주 보임, 17~32주 눌러서, 33주~ 없음.
func _hints_for_week() -> String:
	if w <= 16:
		return "show"
	if w <= 32:
		return "tap"
	return "none"


func _block_of(s: Dictionary) -> String:
	var b: Variant = s.get("block")
	if b is String and CourseStore.BLOCK_IDS.has(b):
		return String(b)
	return String(BLOCK_OF_KIND.get(kind, "new"))


static func _whole(v: Variant) -> int:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < 1.0e6:
		return int(v)
	return -1


func _update_progress() -> void:
	var c: Dictionary = question_counts()
	var total: int = int(c["total"])
	progress_label_node.text = CourseModel.progress_label("questions", int(c["answered"]), total)
	progress_bar.value = float(c["answered"]) / maxf(1.0, float(total))
	var left_n: int = int(c["retry_left"])
	retry_label_node.visible = left_n > 0
	retry_label_node.text = "다시 풀기 %d개" % left_n if left_n > 0 else ""


# ================================================================== 끝내기·기록

func _finish_unit() -> void:
	if view != null:
		view.stop_all()
	# ---- 1. 준비: 기록 없이 값만 계산한다 -------------------------------------------------
	var total := 0
	var good := 0
	var first_n := 0
	var wrong: Array = []
	var wrong_keys: Dictionary = {}
	var auto_total := 0
	var auto_ok := 0
	var speak_n := 0
	var speak_ok := 0
	var speak_skip := 0
	var speak_self := false
	var self_any := false
	for rc in recs:
		if not bool(rc["answered"]):
			continue
		total += 1
		if bool(rc["ok"]):
			good += 1
		if bool(rc["first_try"]):
			first_n += 1
		if bool(rc["self_rated"]):
			self_any = true
		if not bool(rc["first_ok"]):
			var key: String = "%s|%s" % [rc["item"], rc["type"]]
			if not wrong_keys.has(key):
				wrong_keys[key] = true
				wrong.append({"item": String(rc["item"]), "type": String(rc["type"])})
		if String(rc["type"]) == "speak":
			speak_n += 1
			if bool(rc["ok"]):
				speak_ok += 1
			if bool(rc["self_rated"]):
				speak_self = true
			if bool(rc["gave_up"]):
				speak_skip += 1
		else:
			auto_total += 1
			if bool(rc["ok"]):
				auto_ok += 1
	if total <= 0:
		_show_error(TEXT_EMPTY)
		return
	# 코스 데이터가 아직 있어야 한다(복습 카드·낱말 글이 거기서 나온다). 없으면 일부만 기록되지 않게 아무것도 쓰지 않고 끝낸다.
	var data: Dictionary = CourseFeed.builder_data()
	if data.is_empty() or not (data.get("_idx") is Dictionary):
		var why: String = String(CourseFeed.status().get("text_ko", ""))
		_show_error(why if why != "" else TEXT_DATA)
		return
	var wrong_cards: Array = _wrong_cards()
	var pos_before: Dictionary = CourseStore.pos()
	var seconds: int = clampi(int((_now() - _t_start - _paused_total) / 1000), 0, MAX_SECONDS)
	var unit_res: Dictionary = {"unit": kind, "w": w, "d": d, "ok": good, "total": total, "first_try": first_n, "wrong": wrong,
		"words_new": words_new.duplicate() if kind == "new" else [], "completed": true, "seconds": seconds, "block": block}
	var pct: int = clampi(roundi(good * 100.0 / float(total)), 0, 100)
	var speak_state: String = ""
	if kind == "check" and speak_n > 0:
		speak_state = "unverified" if (speak_self or speak_skip == speak_n) else ("pass" if speak_ok == speak_n else "fail")
	# ---- 2. 기록: 위에서 준비한 값만 쓴다 ----------------------------------------------------
	var store_res: Dictionary = {}
	var passed := false
	match kind:
		"check":
			store_res = CourseStore.check_done(w, {"ok": auto_ok, "total": auto_total, "speak": speak_state})
			passed = bool(store_res.get("pass", false))
			pct = int(store_res.get("pct", clampi(roundi(auto_ok * 100.0 / float(auto_total)), 0, 100) if auto_total > 0 else 0))
		"month":
			store_res = CourseStore.month_done(CourseModel.block_of(w), {"score": pct, "mode": "self" if self_any else "stt"})
			passed = pct >= MONTH_PASS
		_:
			store_res = CourseStore.unit_done(unit_res)
	var refused: bool = bool(store_res.get("ignored", false)) ## 미리 해 본 칸·코스 모드 아님 등: 실패가 아니라 "기록 대상이 아님"
	if not refused and not bool(store_res.get("saved", false)):
		# 코스 진도를 저장하지 못했다: 나머지(카드·XP·레슨)는 하나도 기록하지 않고, 메모리를 디스크 쪽으로 되돌린 뒤 오류로 끝낸다.
		CourseStore.load()
		_show_error(TEXT_SAVE)
		return
	var ahead: bool = refused and String(store_res.get("reason", "")) == "ahead"
	StudyLog.add_lesson(LANG, good, total)
	Store.add_xp(LANG, good * 10)
	Store.inc_stat(LANG, "lessons")
	Store.mark_today(LANG)
	var cards_unit := 0
	var cards_wrong := 0
	if not ahead: # 미리 해 본 칸의 복습 카드는 그 칸을 실제로 할 때 넣는다(중복 방지)
		cards_unit = CourseCards.add_unit(w, d) if kind == "new" else 0
		cards_wrong = Store.add_review(wrong_cards)
	StudyLog.note_resume("lesson", LANG)
	Store.save_progress()
	# Store.save_progress 는 성공 여부를 돌려주지 않는다(실패하면 알림만 띄운다): 같은 파일을 한 번 더 써 보고 결과를 확인한다.
	var saved_all: bool = (not Store.progress_read_only) and Progress.save_file(Store.progress_path, Store.progress)
	saved_all = StudyLog.flush() and saved_all
	_recorded = true
	var pos_after: Dictionary = CourseStore.pos()
	result = unit_res.duplicate(true)
	result["kind"] = kind
	result["pct"] = pct
	result["pass"] = passed
	result["auto_ok"] = auto_ok
	result["auto_total"] = auto_total
	result["speak_n"] = speak_n
	result["speak_skip"] = speak_skip
	result["speak_state"] = speak_state
	result["pos_before"] = pos_before
	result["moved"] = pos_after != pos_before
	result["partial"] = not saved_all
	result["cards_added"] = cards_unit + cards_wrong
	result["cards_unit"] = cards_unit
	result["cards_wrong"] = cards_wrong
	result["dropped"] = dropped
	result["skipped"] = skipped
	result["retries"] = retries_made
	result["store"] = store_res
	state = "result"
	_show_result()


## 처음에 틀린 문제의 복습 카드(영어 + 한국어). 낱말은 CourseData 에서, 문장은 문제의 정답에서.
func _wrong_cards() -> Array:
	var out: Array = []
	var note: String = CourseCards.note_for(w, d, CARD_NOTE)
	var seen_t: Dictionary = {}
	for rc in recs:
		if not bool(rc["answered"]) or bool(rc["first_ok"]):
			continue
		var ex: Dictionary = rc["ex"]
		var target: String = ""
		var ko: String = ""
		match String(rc["type"]):
			"recognize", "recall":
				var wd: Dictionary = CourseData.word(String(rc["item"]))
				target = String(wd.get("en", ""))
				ko = String(wd.get("ko", ""))
			"build":
				target = " ".join(PackedStringArray((ex.get("answer", []) as Array).map(func(t: Variant) -> String: return String(t))))
				ko = String(ex.get("ko", ""))
			"listen":
				target = String(ex.get("tts", ""))
				if ex.get("options") is Array and ex.get("answer") is int and int(ex["answer"]) >= 0 and int(ex["answer"]) < (ex["options"] as Array).size():
					ko = String((ex["options"] as Array)[int(ex["answer"])])
			"speak":
				if String(rc["mode"]) == "substitute" and ex.get("accept") is Array and not (ex["accept"] as Array).is_empty():
					target = String((ex["accept"] as Array)[0])
				elif ex.get("target") is String and String(rc["mode"]) != "answer" and String(rc["mode"]) != "intro":
					target = String(ex["target"])
				ko = String(ex.get("ko", ""))
		target = target.strip_edges()
		if target == "" or seen_t.has(target):
			continue
		seen_t[target] = true
		out.append({"lang": LANG, "target": target, "reading": "", "ko": ko.strip_edges(), "note": note})
	return out


# ================================================================== 결과 카드·오류 화면

func _show_result() -> void:
	_hide_view()
	_top_holder.visible = false
	var box := VBoxContainer.new()
	box.name = "ResultBox"
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 0)
	var page := PageScroll.new(720.0)
	page.name = "ResultPage"
	box.add_child(page)
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "ResultCard"
	var title: Label = UI.label(String(DONE_TITLES.get(kind, "마쳤어요")), "H2")
	title.name = "ResultTitle"
	card.body.add_child(title)
	if kind == "check" or kind == "month":
		var verdict: Label = UI.label(_verdict_text(), "Strong", true)
		verdict.name = "VerdictLine"
		card.body.add_child(verdict)
	var good: int = int(result["ok"])
	var total: int = int(result["total"])
	if kind == "check": # 점검은 자동 채점 문제만 센다(분모와 퍼센트가 같은 기준)
		good = int(result["auto_ok"])
		total = int(result["auto_total"])
	card.body.add_child(_line("ScoreLine", "%s 맞혔어요  (%s)" % [CourseModel.progress_label("questions", good, total), CourseModel.progress_label("percent", int(result["pct"]), 100)]))
	if kind == "check" and int(result["speak_n"]) > 0:
		card.body.add_child(_line("SpeakLine", _speak_text()))
	if kind != "check" and kind != "month":
		card.body.add_child(_line("FirstTryLine", "처음에 바로 맞힌 것  %s" % CourseModel.progress_label("questions", int(result["first_try"]), total)))
	card.body.add_child(_line("TimeLine", "걸린 시간  %s" % CourseModel.fmt_minutes(int(result["seconds"]))))
	var wrong_text: String = _wrong_text()
	if wrong_text != "":
		card.body.add_child(_line("WrongLine", wrong_text))
	var cards_n: int = int(result["cards_added"])
	if cards_n > 0:
		card.body.add_child(_line("CardsLine", "복습에 %s 더했어요" % CourseModel.progress_label("cards", cards_n, 0)))
	var nxt: String = _next_text()
	if nxt != "":
		card.body.add_child(_line("NextLine", nxt))
	if bool(result.get("partial", false)):
		card.body.add_child(_line("PartialLine", TEXT_PARTIAL))
	page.content.add_child(card)
	var footer := PanelContainer.new()
	footer.name = "ResultFooter"
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_top = 1
	footer.add_theme_stylebox_override("panel", st)
	var col := ColumnBox.new()
	col.max_width = 720.0
	col.min_pad = Ds.S3
	col.set_padding(Ds.S3 if Platform.is_phone() else 10, Ds.S3)
	footer.add_child(col)
	done_btn = UI.button("완료", "primary", Pal.accent(LANG), MIN_H)
	done_btn.name = "DoneBtn"
	done_btn.pressed.connect(press_done)
	col.content.add_child(done_btn)
	box.add_child(footer)
	_body.add_child(box)
	_result_box = box
	_fit(box)


func _line(node_name: String, text: String) -> Label:
	var l: Label = UI.label(text)
	l.name = node_name
	return l


func _verdict_text() -> String:
	var st: Dictionary = result.get("store", {})
	if kind == "check":
		if bool(result["pass"]):
			return "점검을 통과했어요"
		var moved: bool = bool(result.get("moved", false))
		if bool(st.get("weak", false)):
			if moved:
				return "이번 주는 약함으로 표시하고 다음으로 넘어가요. 틀린 것은 복습 카드로 다시 나와요"
			return "이번 주는 약함으로 표시했어요. 틀린 것은 복습 카드로 다시 나와요"
		var head: String = "아직 통과선(%s)에 못 미쳤어요. 틀린 것은 복습에 담았어요. " % CourseModel.progress_label("percent", CourseStore.CHECK_PASS, 100)
		if not moved and int(st.get("w", 0)) == w and int(st.get("d", 0)) == 6:
			return head + "내일 같은 점검을 다시 해요"
		return head + "다시 해 봐요"
	if bool(result["pass"]):
		return "월말 말하기를 통과했어요"
	return "조금 더 연습하면 돼요. 문장을 소리 내어 따라 말하며 연습해 봐요"


## 점검의 말하기 줄: 통과 판정(자동 채점 문제)에는 넣지 않는다.
func _speak_text() -> String:
	var n: int = int(result["speak_n"])
	if int(result["speak_skip"]) == n:
		return "말하기 %d개는 건너뛰었어요. 통과 판정에는 넣지 않았어요" % n
	match String(result["speak_state"]):
		"unverified":
			return "말하기 %d개는 직접 평가라 통과 판정에는 넣지 않았어요" % n
		"pass":
			return "말하기 %d개도 잘 말했어요" % n
	return "말하기 %d개는 조금 더 연습해요. 통과 판정에는 넣지 않았어요" % n


## 틀렸던 낱말(최대 8개) + 문장 수.
func _wrong_text() -> String:
	var words: Array = []
	var sentences := 0
	for it in result["wrong"]:
		var t: String = String((it as Dictionary)["type"])
		if t == "recognize" or t == "recall":
			var en: String = String(CourseData.word(String((it as Dictionary)["item"])).get("en", ""))
			if en != "" and not words.has(en):
				words.append(en)
		else:
			sentences += 1
	if words.is_empty() and sentences == 0:
		return ""
	var parts: Array = []
	if not words.is_empty():
		var shown: Array = words.slice(0, 8)
		var s: String = ", ".join(PackedStringArray(shown))
		if words.size() > shown.size():
			s += " 외 %d개" % (words.size() - shown.size())
		parts.append("틀렸던 낱말  " + s)
	if sentences > 0:
		parts.append("틀렸던 문장  %s" % CourseModel.progress_label("sentences", sentences, 0))
	return "\n".join(PackedStringArray(parts))


## 결과 카드의 맨 아래 안내: 진도가 어떻게 됐는지 사실대로 말한다.
func _next_text() -> String:
	var st: Dictionary = result.get("store", {})
	if bool(st.get("ignored", false)):
		match String(st.get("reason", "")):
			"ahead":
				return "미리 해 본 칸이라 진도는 그대로예요"
			"mode":
				return "코스 진도에는 기록되지 않아요"
		return "코스 진도에는 기록되지 않았어요"
	if kind == "month":
		return "월말 말하기 점수를 기록했어요"
	if bool(st.get("finished", false)):
		return "72주 코스를 모두 마쳤어요"
	if bool(result.get("moved", false)):
		return "다음은 %d주 %d일이에요" % [int(st.get("w", w)), int(st.get("d", d))]
	if kind == "check":
		if bool(result["pass"]):
			return "점검 결과를 기록했어요"
		return "진도는 지금 칸(%d주 %d일)에 그대로 있어요" % [int(st.get("w", w)), int(st.get("d", d))]
	if block == "new" and kind != "recap":
		return "이미 끝낸 칸이라 진도는 그대로예요"
	return "오늘 계획에 기록했어요"


func _show_error(text: String) -> void:
	state = "error"
	error_text = text
	_hide_view()
	_top_holder.visible = false
	_clear_boxes()
	var box := VBoxContainer.new()
	box.name = "ErrorBox"
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	var page := PageScroll.new(720.0)
	box.add_child(page)
	var card: CardBox = UI.card("BigCard", 10)
	card.name = "ErrorCard"
	var t: Label = UI.label("문제를 열 수 없어요", "H2")
	t.name = "ErrorTitle"
	card.body.add_child(t)
	var m: Label = UI.label(text)
	m.name = "ErrorText"
	card.body.add_child(m)
	page.content.add_child(card)
	var footer := PanelContainer.new()
	footer.name = "ErrorFooter"
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_top = 1
	footer.add_theme_stylebox_override("panel", st)
	var col := ColumnBox.new()
	col.max_width = 720.0
	col.min_pad = Ds.S3
	col.set_padding(Ds.S3 if Platform.is_phone() else 10, Ds.S3)
	footer.add_child(col)
	error_back_btn = UI.button("돌아가기", "primary", Pal.accent(LANG), MIN_H)
	error_back_btn.name = "ErrorBackBtn"
	error_back_btn.pressed.connect(_leave_now)
	col.content.add_child(error_back_btn)
	box.add_child(footer)
	_body.add_child(box)
	_error_box = box
	_fit(box)


func _hide_view() -> void:
	if view != null and is_instance_valid(view):
		view.stop_all()
		view.visible = false


# ================================================================== 나가기·시계

func _on_leave_closed(r: Variant) -> void:
	_leave_sheet = null
	_pause_end()
	if r is String and r == "quit":
		_leave_now()


func _leave_now() -> void:
	if state == "left":
		return
	if view != null and is_instance_valid(view):
		view.stop_all()
	state = "left"
	left.emit()


func _now() -> int:
	if clock_hook.is_valid():
		var v: Variant = clock_hook.call()
		if v is int:
			return v
	return Time.get_ticks_msec()


func _pause_begin() -> void:
	if _pause_since < 0:
		_pause_since = _now()


func _pause_end() -> void:
	if _pause_since >= 0:
		_paused_total += maxi(0, _now() - _pause_since)
		_pause_since = -1
