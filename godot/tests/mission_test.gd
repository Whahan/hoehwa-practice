extends Node
## Headless test: 롤플레이 미션 (MissionLogic 순수 함수 + MissionScreen 흐름·실패 입력·레이아웃).
##   godot --headless --path <project> res://tests/mission_test.tscn
##   godot --headless --path <project> res://tests/mission_test.tscn -- --api=http://127.0.0.1:8814   (라이브 포함)
## Exit code 0 = all checks passed. 서버 없이 고정 JSON 픽스처(sample_mission_*.json)와 가짜 요청 객체로 돈다.
## Store.progress_path / Store.prefs_path / StudyLog.path 는 임시 파일로 바꾸고 끝나면 원래 경로로 돌려 놓는다.
## (실제 prefs.json·studylog.json·progress.json 은 읽지도 쓰지도 않는다.) StudyLog 는 가짜 hook 이 아니라 실제 객체(임시 경로)로 검사한다.

const FIX := "res://tests/sample_mission_%s.json"
const TMP_PROGRESS := "user://test_mission_t4_progress.json"
const TMP_LOG := "user://test_mission_t4_studylog.json"
const TMP_PREFS := "user://test_mission_t4_prefs.json"
const CAFE_GOALS := ["greet", "order_drink", "ask_size", "thank"]

var passed: int = 0
var failed: int = 0

var calls: Array = []        ## 나간 요청 기록: {method, path, body}
var routes: Dictionary = {}  ## path -> Callable(body) -> 결과 Dictionary
var holds: Dictionary = {}   ## path -> true 이면 응답을 붙잡아 두었다가 release() 로 푼다
var held: Dictionary = {}    ## path -> Array[FakeCall]
var hooked: Array = []       ## StudyLog 호출 기록

var holder: Control = null
var ms: MissionScreen = null


class FakeCall:
	extends RefCounted
	signal finished(result: Dictionary)
	var done: bool = false
	var result: Dictionary = {}

	func wait() -> Dictionary:
		if done:
			return result
		return await finished

	func complete(res: Dictionary) -> void:
		if done:
			return
		done = true
		result = res
		finished.emit(res)

	func cancel() -> void:
		complete({"ok": false, "code": 0, "data": null, "bytes": PackedByteArray(), "error": "", "cancelled": true})


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== mission test start ==")
	var old_progress_path: String = Store.progress_path
	var old_prefs_path: String = Store.prefs_path
	var old_log_path: String = StudyLog.path
	for f in [TMP_PROGRESS, TMP_LOG, TMP_LOG + ".tmp", TMP_PREFS]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.progress_path = TMP_PROGRESS
	Store.prefs_path = TMP_PREFS
	Store.progress = Progress.blank()
	Store.time_offset = 0
	StudyLog.path = TMP_LOG
	StudyLog.load_from_disk() ## empty state from the (missing) temp file
	var saved_prefs: Dictionary = Store.prefs.duplicate(true)
	Store.prefs["auto_speak"] = false  # 시험 중 TTS 요청이 나가지 않게 (저장하지 않는다)
	_test_logic()
	await _test_screen_flow()
	await _test_feedback_and_judge()
	await _test_result_recheck_plays()
	await _test_failures()
	await _test_script_mode()
	await _test_checker_itself()
	await _test_layout()
	await _test_lifecycle()
	await _test_live()
	if ms != null and is_instance_valid(holder):
		holder.queue_free()
	Store.prefs = saved_prefs
	for f in [TMP_PROGRESS, TMP_LOG, TMP_LOG + ".tmp", TMP_PREFS]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	StudyLog.load_from_disk() ## drop the test data from memory while the path is still the temp one
	Store.progress_path = old_progress_path
	Store.prefs_path = old_prefs_path
	StudyLog.path = old_log_path
	print("== mission result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 도구

func fx(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(FIX % name))


func _res(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "bytes": PackedByteArray(), "error": "", "cancelled": false}


func _bad(code: int, msg: String) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "bytes": PackedByteArray(), "error": msg, "cancelled": false}


func _fake(method: String, path: String, body: Variant, _timeout: float) -> Variant:
	var p: String = path.split("?")[0]
	calls.append({"method": method, "path": p, "body": body})
	var fc := FakeCall.new()
	if holds.get(p, false):
		if not held.has(p):
			held[p] = []
		(held[p] as Array).append(fc)
		return fc
	var handler: Callable = routes.get(p, Callable())
	var res: Dictionary = handler.call(body) if handler.is_valid() else _bad(404, "없는 경로예요.")
	_complete_later(fc, res)
	return fc


func _complete_later(fc: FakeCall, res: Dictionary) -> void:
	await get_tree().process_frame
	fc.complete(res)


func release(p: String, res: Dictionary) -> void:
	var arr: Array = held.get(p, [])
	if arr.is_empty():
		return
	var fc: FakeCall = arr.pop_front()
	fc.complete(res)


func _hook(kind: String, data: Dictionary) -> void:
	hooked.append({"kind": kind, "data": data})


func count_calls(p: String) -> int:
	var n := 0
	for c in calls:
		if c["path"] == p:
			n += 1
	return n


func paths() -> Array:
	var out: Array = []
	for c in calls:
		if not out.has(c["path"]):
			out.append(c["path"])
	return out


func settle(n: int = 5) -> void:
	for i in n:
		await get_tree().process_frame


## 동작하는 서버처럼 보이는 기본 경로 (규칙은 간단한 단어 매칭)
func default_routes() -> void:
	routes = {
		"/missions": func(_b: Variant) -> Dictionary: return _res(fx("list")),
		"/missions/check": func(b: Variant) -> Dictionary: return _check_route(b),
		"/chat": func(_b: Variant) -> Dictionary: return _res(fx("chat")),
		"/feedback": func(_b: Variant) -> Dictionary: return _res(fx("feedback")),
		"/missions/judge": func(_b: Variant) -> Dictionary: return _res(fx("judge")),
	}
	holds = {}
	held = {}


func _check_route(b: Variant) -> Dictionary:
	var body: Dictionary = b
	var text: String = str(body.get("text", "")).to_lower()
	var done_in: Array = body.get("done", []) if body.get("done", []) is Array else []
	var hits := {"greet": text.begins_with("hi") or text.contains("good morning"), "order_drink": text.contains("latte"),
		"ask_size": text.contains("medium") or text.contains("large"), "thank": text.contains("thank")}
	var goals: Array = []
	var fresh: Array = []
	var all_done := true
	for id in CAFE_GOALS:
		var was: bool = done_in.has(id)
		var now: bool = was or bool(hits[id])
		if now and not was:
			fresh.append(id)
		if not now:
			all_done = false
		goals.append({"id": id, "done": now, "new": now and not was})
	return _res({"mission_id": "cafe_order", "goals": goals, "new": fresh, "all_done": all_done})


func make_screen(w: float, h: float, lang: String = "en") -> void:
	if holder != null and is_instance_valid(holder):
		holder.queue_free()
		await settle(2)
	calls = []
	hooked = []
	holder = Control.new()
	holder.size = Vector2(w, h)
	add_child(holder)
	ms = MissionScreen.new()
	ms.http = Callable(self, "_fake")
	ms.log_hook = Callable(self, "_hook")
	holder.add_child(ms)
	await settle(2)
	ms.open(lang)
	await settle(4)


## 목록에서 카페 미션을 골라 설명 화면까지
func to_brief(id: String = "cafe_order") -> void:
	ms._select(id)
	await settle(2)


func start_ai() -> void:
	var b: Button = find_button(ms, "미션 시작")
	if b != null:
		b.pressed.emit()
	await settle(2)


func send(text: String) -> void:
	ms._input.text = text
	ms._send_message()
	await settle(6)


func texts(node: Node, out: Array = []) -> Array:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	elif node is RichTextLabel:
		out.append((node as RichTextLabel).text)
	for ch in node.get_children():
		texts(ch, out)
	return out


func has_text(node: Node, part: String) -> bool:
	for t in texts(node):
		if str(t).contains(part):
			return true
	return false


func find_button(node: Node, text: String, exact: bool = true) -> Button:
	if node is Button and node.is_visible_in_tree():
		var t: String = (node as Button).text
		if (t == text) if exact else t.contains(text):
			return node as Button
	for ch in node.get_children():
		var f: Button = find_button(ch, text, exact)
		if f != null:
			return f
	return null


func layout_problems(root: Node, width: float) -> Array:
	var out: Array = []
	_walk(root, width, out)
	return out


func _walk(n: Node, width: float, out: Array) -> void:
	if n is Control and (n as Control).is_visible_in_tree():
		var c: Control = n as Control
		if c.get_combined_minimum_size().x > width + 0.5:
			out.append("L1 %s(%s) min x %.0f" % [c.get_class(), c.name, c.get_combined_minimum_size().x])
		if c is Button and not c.has_meta("touch_exempt") and c.size.y < 43.5:
			out.append("L2 button '%s' h %.0f" % [(c as Button).text, c.size.y])
	for ch in n.get_children():
		_walk(ch, width, out)


# ---------------------------------------------------------------- 1. MissionLogic 표 테스트

func _test_logic() -> void:
	print("[MissionLogic: stars / xp]")
	ok(MissionLogic.stars(4, 4, 3, 10) == 3, "전부 달성 + 한도 이내 -> 별 3")
	ok(MissionLogic.stars(4, 4, 10, 10) == 3, "전부 달성 + 턴이 한도와 같음 -> 별 3")
	ok(MissionLogic.stars(4, 4, 11, 10) == 2, "전부 달성이지만 한도 초과 -> 별 2")
	ok(MissionLogic.stars(3, 5, 2, 10) == 2, "r = 0.6 -> 별 2")
	ok(MissionLogic.stars(1, 2, 2, 10) == 1, "r = 0.5 -> 별 1")
	ok(MissionLogic.stars(1, 5, 2, 10) == 1, "r = 0.2 -> 별 1")
	ok(MissionLogic.stars(0, 4, 5, 10) == 0, "r = 0 -> 별 0")
	ok(MissionLogic.stars(0, 0, 0, 10) == 0 and MissionLogic.stars(3, 0, 1, 10) == 0, "목표 0개 미션(방어) -> 별 0, 오류 없음")
	ok(MissionLogic.stars(9, 4, 1, 10) == 3 and MissionLogic.stars(-2, 4, 1, 10) == 0, "범위 밖 값은 보정")
	ok(is_equal_approx(MissionLogic.ratio(1, 4), 0.25) and MissionLogic.ratio(1, 0) == 0.0, "ratio, 0으로 나누지 않음")
	ok(MissionLogic.xp(4, 3) == 90 and MissionLogic.xp(0, 0) == 20 and MissionLogic.xp(2, 1) == 50, "XP = 20 + 10 x 목표 + 10 x 별")
	ok(MissionLogic.xp(-3, 9) == 50, "XP 방어: 음수 목표 0, 별 3 이하")
	ok(MissionLogic.marks_today(1, 0) and MissionLogic.marks_today(0, 3) and not MissionLogic.marks_today(0, 2), "오늘 기록: 달성 1 이상 또는 턴 3 이상")
	ok(MissionLogic.star_text(2) == "★★☆" and MissionLogic.star_text(9) == "★★★" and MissionLogic.star_text(-1) == "☆☆☆", "별 글자")
	ok(MissionLogic.should_end(4, 4, 1, 10) and MissionLogic.should_end(1, 4, 10, 10) and not MissionLogic.should_end(1, 4, 9, 10) and not MissionLogic.should_end(0, 0, 0, 0), "끝낼 때: 전부 달성 또는 턴 한도")
	ok(MissionLogic.clean_text("  hi  ") == "hi" and MissionLogic.clean_text("a".repeat(500)).length() == 300, "문장 정리: 공백 제거, 300자")

	print("[MissionLogic: 수동 체크 포함]")
	var goals: Array = [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}]
	var done := {"a": "rule", "c": "manual", "zzz": "rule"}
	ok(MissionLogic.count_done(goals, done) == 2, "목록에 없는 id 는 세지 않음 (규칙 + 수동 = 2)")
	ok(MissionLogic.pending_ids(goals, done) == ["b", "d"], "못 한 목표 id")
	ok(MissionLogic.stars(MissionLogic.count_done(goals, {"a": "rule", "b": "manual", "c": "manual"}), 4, 3, 10) == 2, "수동 체크를 합쳐 3/4 -> 별 2")

	print("[MissionLogic: 서버 응답 정리]")
	var parsed: Dictionary = MissionLogic.parse_list(fx("list"))
	var ids: Array = []
	for m in parsed["missions"]:
		ids.append(m["id"])
	ok(ids == ["job_interview", "cafe_order", "hotel_checkin"], "이상한 항목(목표 없음/문자열/숫자/id 없음/중복 id) 제외: %s" % str(ids))
	var sorted: Array = MissionLogic.sort_for_stage(parsed["missions"], 2)
	ok(sorted[0]["id"] == "cafe_order" and sorted[1]["id"] == "hotel_checkin" and sorted[2]["id"] == "job_interview", "단계에 맞는 미션이 먼저")
	var nm: Dictionary = MissionLogic.normalize_mission({"id": "x", "title_ko": "t", "max_turns": 0, "min_stage": 99, "goals": [{"id": "g1"}, {"id": "g1"}, {"id": ""}, 5]})
	ok(int(nm["max_turns"]) == 10 and int(nm["min_stage"]) == 4 and (nm["goals"] as Array).size() == 1, "max_turns 0 -> 10, min_stage 보정, 중복·빈 목표 제거")
	ok(MissionLogic.normalize_mission(null).is_empty() and MissionLogic.normalize_mission("x").is_empty() and MissionLogic.normalize_mission({}).is_empty(), "null/문자열/빈 딕셔너리 -> 빈 결과")
	var empty_list: Dictionary = MissionLogic.parse_list(null)
	ok((empty_list["missions"] as Array).is_empty() and not bool(empty_list["unsupported"]), "parse_list(null) 오류 없음")
	var ja: Dictionary = MissionLogic.parse_list({"lang": "ja", "unsupported": true, "missions": [], "message": "다음 버전"})
	ok(bool(ja["unsupported"]) and ja["message"] == "다음 버전", "unsupported 응답")
	var cafe_goals: Array = (parsed["missions"][1] as Dictionary)["goals"]
	var d1 := {}
	var fresh: Array = MissionLogic.apply_check(cafe_goals, d1, fx("check"))
	ok(fresh == ["greet", "order_drink"] and d1.size() == 2 and d1["greet"] == "rule", "체크 응답 반영 (픽스처): %s" % str(fresh))
	ok(MissionLogic.apply_check(cafe_goals, d1, fx("check")).is_empty(), "같은 응답을 또 반영해도 새 목표 없음")
	var d2 := {}
	var junk: Array = [null, [], "x", {"goals": "x"}, {"goals": [null, 5, {"id": "zzz", "done": true}, {"id": "greet", "done": "true"}, {"id": "greet", "done": 1}]}, {"goals": [{"done": true}]}]
	var junk_new := 0
	for j in junk:
		junk_new += MissionLogic.apply_check(cafe_goals, d2, j).size()
	ok(junk_new == 0 and d2.is_empty(), "깨진 응답·모르는 id·문자열 true 는 무시")
	var jd := {"greet": "rule"}
	var jr: Dictionary = fx("judge")
	var j_new: Array = MissionLogic.apply_judge(jd, ["ask_size", "thank"], jr, ["Hi", "Can I get a large one please"])
	ok(j_new == ["ask_size"] and jd.get("ask_size") == "ai" and not jd.has("thank"), "AI 판정: 증거가 내 발화에 있는 것만 인정")
	ok(MissionLogic.apply_judge({}, ["thank"], jr, ["Many thanks and good bye"]).has("thank"), "증거가 내 발화에 들어 있으면 인정 (대소문자 무시)")
	ok(MissionLogic.apply_judge({}, ["ask_size"], jr, []).is_empty() and MissionLogic.apply_judge({}, ["x"], null, ["a"]).is_empty(), "발화 없음/응답 null -> 아무것도 인정 안 함")

	print("[MissionLogic: 대본 모드]")
	var st: Dictionary = MissionLogic.script_new()
	var r1: Dictionary = MissionLogic.script_step(st, 3, true)
	ok(r1["outcome"] == "pass" and r1["state"]["idx"] == 1 and st["idx"] == 0, "통과: 다음 줄로, 원본 상태는 그대로")
	var s: Dictionary = r1["state"]
	var a1: Dictionary = MissionLogic.script_step(s, 3, false)
	var a2: Dictionary = MissionLogic.script_step(a1["state"], 3, false)
	var a3: Dictionary = MissionLogic.script_step(a2["state"], 3, false)
	ok(a1["outcome"] == "retry" and a2["outcome"] == "retry" and a3["outcome"] == "miss", "3번 틀리면 miss (모범 답을 보여 주고 넘어감)")
	ok(a3["state"]["idx"] == 2 and a3["state"]["fails"] == 0 and a3["state"]["results"] == ["pass", "miss"], "miss 뒤에는 다음 줄, 실패 횟수 0")
	var a4: Dictionary = MissionLogic.script_step(a3["state"], 3, true)
	ok(a4["finished"] and a4["state"]["results"] == ["pass", "miss", "pass"], "마지막 줄 통과 -> 끝")
	ok(MissionLogic.script_step(a4["state"], 3, true)["outcome"] == "none", "끝난 뒤에는 아무 일도 안 함")
	ok(MissionLogic.script_step(MissionLogic.script_new(), 0, true)["finished"], "줄이 0개인 대본 방어")
	var line := {"ai": "x", "goal": "order_drink", "model": "I'd like a latte, please."}
	ok(MissionLogic.script_passes("whatever", line, ["order_drink"]), "규칙으로 줄의 목표에 닿으면 통과")
	ok(MissionLogic.script_passes("Id like a latte please", line, []), "모범 답과 비슷하면(60 이상) 통과")
	ok(not MissionLogic.script_passes("banana", line, []) and not MissionLogic.script_passes("   ", line, ["order_drink"]) and not MissionLogic.script_passes("x", {"goal": "g", "model": ""}, []), "엉뚱한 답·빈 답·모범 답 없음은 통과 못 함")
	var summary: String = MissionLogic.rule_summary([], {}, 0, 0)
	ok(summary.contains("0개") and not summary.contains("모든 목표"), "목표 0개 규칙 요약 오류 없음")
	ok(MissionLogic.rule_summary(cafe_goals, {"greet": "rule"}, 1, 2).contains("아직 못 한 목표"), "규칙 요약이 못 한 목표를 알려 줌")


# ---------------------------------------------------------------- 2. 화면 흐름 (픽스처)

func _test_screen_flow() -> void:
	print("[screen: 목록 -> 시작 -> 대화 (T4-2)]")
	default_routes()
	await make_screen(1280, 800)
	ok(ms.status == "list" and ms.missions.size() == 3, "목록 적용: 3개 (이상한 항목 제외)")
	ok(ms.missions[0]["id"] == "cafe_order", "단계에 맞는 미션이 맨 앞")
	ok(has_text(ms, "카페에서 음료 주문하기") and has_text(ms, "☆☆☆"), "카드에 제목과 별점이 보임")
	ok(count_calls("/missions") == 1, "목록은 GET /missions 한 번")
	await to_brief()
	ok(ms.status == "brief" and has_text(ms, "인사하기") and has_text(ms, "힌트 보기"), "설명 화면: 목표와 힌트 버튼")
	var hint_btn: Button = find_button(ms, "힌트 보기")
	hint_btn.pressed.emit()
	await settle(2)
	ok(has_text(ms, "I'd like a latte, please."), "힌트를 누르면 영어 힌트가 보임")
	var chat_before: int = count_calls("/chat")
	await start_ai()
	ok(ms.status == "talk" and ms.msgs.size() == 1 and ms.msgs[0]["reply"] == "Hi there! What can I get started for you today?", "시작하면 첫 마디(opening)가 바로 나옴")
	ok(count_calls("/chat") == chat_before and count_calls("/feedback") == 0, "시작할 때 /chat 호출 없음")
	ok(has_text(ms, "Hi there! What can I get started for you today?"), "첫 마디가 화면에 보임")

	print("[screen: 체크와 /chat 이 둘 다 나가고 체크가 먼저 반영 (T4-2)]")
	holds = {"/chat": true}
	ms._input.text = "Hi, good morning!"
	ms._send_message()
	ms._send_message()  # 연타
	ms._input.text = "Hi again"
	ms._send_message()
	await settle(6)
	ok(count_calls("/missions/check") == 1 and count_calls("/chat") == 1, "연타해도 요청은 한 번씩만 (check 1, chat 1)")
	var chk_body: Dictionary = {}
	var chat_body: Dictionary = {}
	for c in calls:
		if c["path"] == "/missions/check":
			chk_body = c["body"]
		if c["path"] == "/chat":
			chat_body = c["body"]
	ok(chk_body.get("text") == "Hi, good morning!" and chk_body.get("mission_id") == "cafe_order" and chk_body.get("lang") == "en" and chk_body.get("done") == [], "check 본문: text, mission_id, lang, done")
	ok(chat_body.get("skip_fix") == true and (chat_body.get("history") as Array).size() == 2 and (chat_body.get("scenario") as Dictionary).get("id") == "mission:cafe_order" and chat_body.get("lang") == "en", "chat 본문: scenario 객체, history(첫 마디 + 내 말), skip_fix")
	ok(ms.status == "wait" and ms.done.has("greet") and ms.msgs.size() == 2, "AI 답이 오기 전에 이미 목표 '인사하기'가 반영됨")
	ok(ms._input.text == "Hi again" or ms._input.text == "", "대기 중 입력 보내기는 막힘")
	var greet_btn: Button = find_button(ms, "인사하기", false)
	ok(greet_btn != null and greet_btn.text.begins_with("✓"), "목표 패널에 ✓ 표시 (PC 오른쪽 패널)")
	release("/chat", _res(fx("chat")))
	await settle(4)
	ok(ms.status == "talk" and ms.msgs.size() == 3 and ms.msgs[2]["reply"] == "Good morning! What can I get for you?", "답이 오면 대화에 추가")
	ok(has_text(ms, "Good morning! What can I get for you?"), "AI 답이 화면에 보임")

	print("[screen: /chat 이 먼저 끝나도 체크가 먼저 (순서)]")
	holds = {"/missions/check": true}
	ms._input.text = "I'd like a latte, please"
	ms._send_message()
	await settle(6)
	ok(ms.status == "wait" and ms.msgs.size() == 4 and not ms.done.has("order_drink"), "check 가 아직이면 chat 이 와 있어도 반영 보류")
	release("/missions/check", _check_route({"text": "I'd like a latte, please", "done": ["greet"]}))
	await settle(6)
	ok(ms.done.has("order_drink") and ms.status == "talk" and ms.msgs.size() == 5, "check 반영 뒤에 chat 이 반영됨")
	holds = {}

	print("[screen: 끝까지 -> 결과 / 피드백 (T4-3)]")
	var xp0: int = Store.xp("en")
	await send("A medium please")
	ok(ms.status == "talk" and ms.done.size() == 3, "사이즈 달성 (3 / 4)")
	holds = {"/feedback": true}
	await send("Thank you so much")
	ok(ms.status == "result", "모든 목표 달성 -> 종료 화면")
	ok(MissionLogic.count_done(ms._goals(), ms.done) == 4 and ms._calc_award()["stars"] == 3, "별 3개")
	ok(Store.xp("en") == xp0 + 90, "XP = 20 + 40 + 30 = 90 (실제 %d)" % (Store.xp("en") - xp0))
	ok(Store.did_day(Plan.today_days(), "en"), "mark_today 반영")
	var logged_mission := false
	var logged_event := false
	for h in hooked:
		if h["kind"] == "mission" and h["data"]["id"] == "cafe_order" and h["data"]["stars"] == 3 and (h["data"]["done_goals"] as Array).size() == 4:
			logged_mission = true
		if h["kind"] == "event" and h["data"]["kind"] == "missions":
			logged_event = true
	ok(logged_mission and logged_event, "StudyLog.add_mission(별 3, 목표 4) + add_event('missions') 호출")
	var real_best: Dictionary = StudyLog.mission_best("cafe_order")
	ok(real_best.get("plays", 0) == 1 and real_best.get("stars", 0) == 3 and real_best.get("done_goals", 0) == 4, "실제 StudyLog(임시 경로): 한 판 = plays 1, 별 3, 목표 4 -> %s" % str(real_best))
	ok(count_calls("/feedback") == 1 and ms.fb_state == "wait", "/feedback 한 번 요청, 대기 중")
	ok(has_text(ms, "★★★") and has_text(ms, "XP +90"), "별점과 XP 가 먼저 보임 (피드백 전에)")
	ok(find_button(ms, "AI로 다시 판정") == null, "모두 달성하면 'AI로 다시 판정' 버튼 없음")
	release("/feedback", _bad(502, "AI가 응답하지 않았어요."))
	await settle(3)
	ok(ms.fb_state == "fail" and has_text(ms, "피드백을 불러오지 못했어요") and has_text(ms, "★★★") and find_button(ms, "다시 시도") != null, "/feedback 502: 별점·목표 결과는 보이고 [다시 시도]")
	var reviews0: int = Store.review_for("en").size()
	find_button(ms, "다시 시도").pressed.emit()
	await settle(3)
	ok(ms.fb_state == "wait" and count_calls("/feedback") == 2, "다시 시도 -> /feedback 재요청")
	release("/feedback", _res(fx("feedback")))
	await settle(3)
	ok(ms.fb_state == "ok" and has_text(ms, "I'd like a latte, please.") and has_text(ms, "3/5"), "성공하면 점수·고쳐 말하기가 보임")
	ok(Store.review_for("en").size() == reviews0 + 2 and ms.fb_added == 2, "corrections 2개가 복습 카드로 추가")
	var card_ok := false
	for r in Store.review_for("en"):
		if r["target"] == "I'd like a latte, please." and str(r["note"]).contains("공손"):
			card_ok = true
	ok(card_ok, "복습 카드에 better 문장과 why 메모")
	holds = {}
	ms._request_feedback()
	await settle(4)
	ok(Store.review_for("en").size() == reviews0 + 2 and ms.fb_added == 0, "같은 교정을 다시 받아도 중복 카드 없음")
	ok(Store.xp("en") == xp0 + 90, "피드백을 다시 받아도 XP 는 한 번만")
	ok(StudyLog.mission_best("cafe_order").get("plays", 0) == 1, "피드백을 다시 받아도 plays 는 1")

	print("[screen: go_back]")
	ok(ms.go_back() and ms.status == "list", "결과 -> 목록 (true)")
	ok(not ms.go_back(), "목록에서는 false (허브가 닫는다)")
	var closed_flag := [false]
	ms.closed.connect(func() -> void: closed_flag[0] = true)
	ms._back_btn.pressed.emit()
	ok(closed_flag[0], "목록의 뒤로 버튼은 closed 신호")
	await to_brief()
	ok(ms.go_back() and ms.status == "list", "설명 -> 목록")
	await to_brief()
	await start_ai()
	ok(ms.go_back() and ms.status == "list", "대화 중(말한 것 없음) -> 바로 목록")
	await to_brief()
	await start_ai()
	await send("Hi")
	ok(ms.go_back() and ms.status == "talk" and ms.leave_confirm and has_text(ms._aux, "그만하고 목록으로"), "말한 뒤 첫 뒤로: 확인 안내만 (true)")
	ok(ms.go_back() and ms.status == "list" and ms.msgs.is_empty(), "한 번 더: 대화를 버리고 목록으로")


# ---------------------------------------------------------------- 3. 피드백 · 판정

func _test_feedback_and_judge() -> void:
	print("[judge: 규칙으로 못 잡은 목표가 있을 때만 (T4-7)]")
	StudyLog.reset()
	default_routes()
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	await send("Hi, good morning")
	await send("Can I get a large one please")  # 규칙 시험용 check 는 'large' 도 사이즈로 본다 -> 일부러 다른 문장 사용
	ms.done.erase("ask_size")  # 규칙이 못 잡은 상황으로 되돌림
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
	await send("I'd like to say many thanks")
	ms._on_end_pressed()
	await settle(3)
	ok(ms.status == "result" and MissionLogic.pending_ids(ms._goals(), ms.done).size() >= 2, "끝내기 -> 결과 (미달성 목표 있음)")
	var jb: Button = find_button(ms, "AI로 다시 판정")
	ok(jb != null, "미달성 목표가 있으면 'AI로 다시 판정' 버튼")
	var xp_before: int = Store.xp("en")
	var jbest0: Dictionary = StudyLog.mission_best("cafe_order")
	ok(jbest0.get("plays", 0) == 1 and jbest0.get("done_goals", 0) == 1, "(실제 StudyLog) 끝낸 판: plays 1, 목표 1 -> %s" % str(jbest0))
	holds = {"/missions/judge": true}
	jb.pressed.emit()
	await settle(3)
	ok(ms.judge_busy and count_calls("/missions/judge") == 1, "판정 요청 한 번")
	var jbody: Dictionary = {}
	for c in calls:
		if c["path"] == "/missions/judge":
			jbody = c["body"]
	ok((jbody.get("pending") as Array).has("ask_size") and (jbody.get("pending") as Array).has("thank") and (jbody.get("history") as Array).size() >= 4 and jbody.get("mission_id") == "cafe_order", "judge 본문: pending, history, mission_id")
	release("/missions/judge", _res(fx("judge")))
	await settle(3)
	ok(ms.done.get("ask_size") == "ai", "증거가 내 발화에 있는 목표만 'AI 판정'으로 달성")
	ok(not ms.done.has("thank"), "증거가 내 발화에 없는 목표(thank)는 그대로 미달성")
	ok(find_button(ms, "AI 판정", false) != null, "목표 줄에 (AI 판정) 표시")
	ok(Store.xp("en") > xp_before, "AI 판정으로 목표가 늘면 XP 차이만큼 더해짐")
	var jbest1: Dictionary = StudyLog.mission_best("cafe_order")
	ok(jbest1.get("plays", 0) == 1 and jbest1.get("done_goals", 0) == 2, "(실제 StudyLog) AI 판정 뒤: 목표 2로 오르고 plays 는 그대로 1 -> %s" % str(jbest1))
	holds = {}
	routes["/missions/judge"] = func(_b: Variant) -> Dictionary: return _bad(503, "AI를 쓸 수 없어요.")
	var done_before: Dictionary = ms.done.duplicate()
	find_button(ms, "AI로 다시 판정").pressed.emit()
	await settle(4)
	ok(JSON.stringify(ms.done) == JSON.stringify(done_before) and has_text(ms, "규칙 결과를 그대로 뒀어요"), "판정 오류(503): 규칙 결과 유지 + 안내")
	routes["/missions/judge"] = func(_b: Variant) -> Dictionary: return _res({"ai": false, "goals": []})
	find_button(ms, "AI로 다시 판정").pressed.emit()
	await settle(4)
	ok(JSON.stringify(ms.done) == JSON.stringify(done_before) and has_text(ms, "판정하지 못했어요"), "ai:false 응답: 규칙 결과 유지 + 안내")
	routes["/missions/judge"] = func(_b: Variant) -> Dictionary: return _res("엉뚱한 응답")
	find_button(ms, "AI로 다시 판정").pressed.emit()
	await settle(4)
	ok(JSON.stringify(ms.done) == JSON.stringify(done_before), "깨진 judge 응답: 규칙 결과 유지")
	ms.llm_override = 1
	ms._render_result()
	await settle(2)
	ok(find_button(ms, "AI로 다시 판정") == null, "AI 를 못 쓰는 상태에서는 판정 버튼 없음")
	ms.llm_override = -1

	print("[result: 직접 체크]")
	var thank_row: Button = find_button(ms, "감사 인사하기", false)
	ok(thank_row != null and thank_row.text.begins_with("○"), "미달성 목표는 ○")
	thank_row.pressed.emit()
	await settle(2)
	ok(ms.done.get("thank") == "manual" and find_button(ms, "직접", false) != null, "누르면 직접 체크 (수동) 표시")
	var jbest2: Dictionary = StudyLog.mission_best("cafe_order")
	ok(jbest2.get("plays", 0) == 1 and jbest2.get("stars", 0) == 2 and jbest2.get("done_goals", 0) == 3, "(실제 StudyLog) 직접 체크 뒤: 별 2, 목표 3, plays 는 그대로 1 -> %s" % str(jbest2))
	ms._toggle_goal("thank")
	ok(not ms.done.has("thank"), "직접 체크한 것은 다시 누르면 해제")
	ms._toggle_goal("greet")
	ok(ms.done.get("greet") == "rule", "자동 확인된 목표는 눌러도 안 바뀜")


# ---------------------------------------------------------------- 3b. 결과 화면 재계산은 plays 를 늘리지 않는다

func _test_result_recheck_plays() -> void:
	print("[result: 결과 화면에서 체크해도 한 판 = plays 1 (실제 StudyLog, 임시 경로)]")
	StudyLog.reset()
	default_routes()
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	await send("Hi, good morning")
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
	ms._on_end_pressed()
	await settle(3)
	ok(ms.status == "result" and ms.done.size() == 1, "끝내기 -> 결과 (목표 1 / 4)")
	var b0: Dictionary = StudyLog.mission_best("cafe_order")
	ok(b0.get("plays", 0) == 1 and b0.get("stars", 0) == 1 and b0.get("done_goals", 0) == 1, "한 판 = plays 1, 별 1, 목표 1 -> %s" % str(b0))
	var mission_calls := 0
	var best_calls := 0
	for h in hooked:
		if h["kind"] == "mission":
			mission_calls += 1
		if h["kind"] == "mission_best":
			best_calls += 1
	ok(mission_calls == 1 and best_calls == 0, "add_mission 계열 호출은 한 판에 한 번 (mission %d, mission_best %d)" % [mission_calls, best_calls])
	ms._toggle_goal("order_drink")
	ms._toggle_goal("ask_size")
	var b1: Dictionary = StudyLog.mission_best("cafe_order")
	ok(b1.get("plays", 0) == 1 and b1.get("stars", 0) == 2 and b1.get("done_goals", 0) == 3, "직접 체크 2개 뒤: 별 2, 목표 3, plays 는 그대로 1 -> %s" % str(b1))
	ms._toggle_goal("thank")
	var b2: Dictionary = StudyLog.mission_best("cafe_order")
	ok(b2.get("plays", 0) == 1 and b2.get("stars", 0) == 3 and b2.get("done_goals", 0) == 4, "모두 체크: 별 3, 목표 4, plays 는 그대로 1 -> %s" % str(b2))
	ms._toggle_goal("thank")
	var b3: Dictionary = StudyLog.mission_best("cafe_order")
	ok(b3.get("plays", 0) == 1 and b3.get("stars", 0) == 3, "체크를 풀어도 최고 기록은 안 내려감 (별 3), plays 1")
	StudyLog.flush()
	StudyLog.load_from_disk()
	ok(StudyLog.mission_best("cafe_order").get("plays", 0) == 1 and StudyLog.mission_best("cafe_order").get("stars", 0) == 3, "저장 후 다시 읽어도 plays 1, 별 3")
	# 같은 미션을 한 번 더 하면 그때는 plays 2
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	await send("Hi, good morning")
	ms._on_end_pressed()
	await settle(3)
	ok(StudyLog.mission_best("cafe_order").get("plays", 0) == 2 and StudyLog.mission_best("cafe_order").get("stars", 0) == 3, "새 판을 끝내면 plays 2 (최고 별은 3 그대로)")
	# 기록이 없는 미션은 update_mission_best 가 만들지 않는다
	StudyLog.update_mission_best("en", "never_played", 3, 4)
	ok(StudyLog.mission_best("never_played").is_empty(), "update_mission_best 는 없던 미션 기록을 새로 만들지 않음")


# ---------------------------------------------------------------- 4. 틀린 입력

func _test_failures() -> void:
	print("[failures: 목록 (T4-5)]")
	default_routes()
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res({"lang": "en", "unsupported": false, "missions": []})
	await make_screen(1280, 800)
	ok(ms.status == "list" and has_text(ms, "연습할 수 있는 미션이 없어요"), "missions:[] -> 안내 문구")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res({"lang": "ja", "unsupported": true, "missions": [], "message": "일본어 미션은 다음 버전에서 만들 예정이에요."})
	ms.open("en")
	await settle(4)
	ok(has_text(ms, "일본어 미션은 다음 버전에서 만들 예정이에요."), "unsupported:true -> 서버 메시지")
	var n_missions_calls: int = count_calls("/missions")
	ms.open("ja")
	await settle(3)
	ok(ms.status == "list" and has_text(ms, "일본어 미션은 다음 버전") and count_calls("/missions") == n_missions_calls, "lang=ja -> 안내, 요청 없음")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _bad(404, "Not Found")
	ms.open("en")
	await settle(4)
	ok(has_text(ms, "최신 버전으로 업데이트해 주세요") and find_button(ms, "다시 시도") != null, "서버가 오래돼 404 -> 업데이트 안내 + [다시 시도]")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _bad(0, "AI 엔진에 연결하지 못했어요.")
	ms.open("en")
	await settle(4)
	ok(has_text(ms, "연결하지 못했어요") and find_button(ms, "다시 시도") != null, "네트워크 오류 -> 오류 문구 + [다시 시도]")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res("이상한 본문")
	ms.open("en")
	await settle(4)
	ok(has_text(ms, "읽지 못했어요"), "본문이 Dictionary 가 아니면 안내")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res(fx("list"))
	find_button(ms, "다시 시도").pressed.emit()
	await settle(4)
	ok(ms.missions.size() == 3 and not ms.list_error, "[다시 시도] 로 복구")

	print("[failures: 대화 (T4-5)]")
	await to_brief()
	await start_ai()
	var calls_before: int = calls.size()
	ms._input.text = "   "
	ms._send_message()
	await settle(3)
	ok(calls.size() == calls_before and ms.msgs.size() == 1 and ms.status == "talk", "빈 입력 보내기 무시")
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _bad(404, "알 수 없는 미션이에요.")
	await send("Hi there")
	ok(ms.status == "talk" and ms.msgs.size() == 3 and ms.done.is_empty(), "check 404: 체크는 무시하고 대화는 계속")
	var row: Button = find_button(ms, "인사하기", false)
	row.pressed.emit()
	await settle(2)
	ok(ms.done.get("greet") == "manual", "수동 체크는 가능")
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _bad(0, "연결 실패")
	await send("I'd like a latte")
	ok(ms.status == "talk" and ms.msgs.size() == 5, "check 네트워크 오류도 대화는 계속")
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _res({})
	await send("A medium please")
	ok(ms.status == "talk" and ms.chat_failed and has_text(ms._msg_scroll, "AI 답을 읽지 못했어요") and find_button(ms, "다시 보내기") != null, "/chat 이 {} -> 한글 오류 + [다시 보내기]")
	var turns_before: int = ms.turns
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _res({"reply": "   ", "ko": ""})
	find_button(ms, "다시 보내기").pressed.emit()
	await settle(4)
	ok(ms.chat_failed and has_text(ms._msg_scroll, "AI 답을 읽지 못했어요") and ms.turns == turns_before, "reply 가 공백이어도 같은 처리, 다시 보내기로 턴이 늘지 않음")
	var chk_n: int = count_calls("/missions/check")
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _bad(503, "AI를 쓸 수 없어요.")
	find_button(ms, "다시 보내기").pressed.emit()
	await settle(4)
	ok(has_text(ms._msg_scroll, "AI를 쓸 수 없어요.") and find_button(ms, "대본 모드로 연습") != null, "/chat 503 -> 대본 모드 버튼이 나타남")
	ok(count_calls("/missions/check") == chk_n, "다시 보내기는 /chat 만 다시 (check 는 다시 안 함)")
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _res(fx("chat"))
	find_button(ms, "다시 보내기").pressed.emit()
	await settle(4)
	ok(not ms.chat_failed and ms.status == "talk" and ms.msgs[ms.msgs.size() - 1]["role"] == "ai", "복구되면 답이 대화에 추가")

	print("[failures: 취소]")
	holds = {"/chat": true}
	await send("Thank you")
	ok(ms.status == "wait" or ms.status == "result", "취소 시험 준비")
	if ms.status == "wait":
		ms._cancel_chat()
		await settle(4)
		ok(ms.status == "talk" and ms.chat_failed and find_button(ms, "다시 보내기") != null, "대기 중 취소 -> 다시 보내기 가능")
	holds = {}

	print("[failures: 턴 한도]")
	default_routes()
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
	await make_screen(1280, 800)
	await to_brief("hotel_checkin")
	await start_ai()
	for i in 8:
		if ms.status == "talk":
			await send("blah %d" % i)
	ok(ms.status == "result" and ms.turns == 8, "max_turns(8) 에 닿으면 종료 화면")
	ok(ms._calc_award()["stars"] == 0 and ms._calc_award()["xp"] == 20, "아무 목표도 못 채우면 별 0, XP 20 (공식 그대로)")
	ok(Store.did_day(Plan.today_days(), "en"), "턴 3 이상이면 오늘 공부로 기록")

	print("[failures: 말한 것이 없으면 기록하지 않음]")
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	var xp1: int = Store.xp("en")
	ms._on_end_pressed()
	ok(ms.status == "talk" and ms._end_btn.disabled, "말한 것이 없으면 끝내기 불가")
	ms._finish()
	ok(Store.xp("en") == xp1 and has_text(ms, "저장하지 않았어요"), "강제로 끝내도 XP·기록 없음")


# ---------------------------------------------------------------- 5. 대본 모드 (AI 호출 0회)

func _test_script_mode() -> void:
	print("[script: AI 없음 경로 (T4-4)]")
	default_routes()
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _bad(503, "AI를 쓸 수 없어요.")
	await make_screen(1280, 800)
	await to_brief()
	ms.llm_override = 1
	ms._render_brief()
	await settle(2)
	ok(find_button(ms, "대본 모드로 연습") != null and has_text(ms, "AI를 쓸 수 없어요"), "AI 없음 -> [대본 모드로 연습] 버튼과 안내")
	var xp0: int = Store.xp("en")
	find_button(ms, "대본 모드로 연습").pressed.emit()
	await settle(3)
	ok(ms.status == "talk" and ms.mode == "script" and ms.msgs.size() == 1 and ms.msgs[0]["reply"].begins_with("Hi there"), "대본 모드 시작: 첫 줄 바로 표시")
	await send("banana banana")
	ok(ms.status == "talk" and ms.script_state["fails"] == 1 and has_text(ms._msg_scroll, "다시 말해 보세요 (1/3)"), "틀리면 안내 (1/3)")
	await send("Hi, good morning!")
	ok(ms.done.has("greet") and ms.script_state["idx"] == 1 and ms.msgs[ms.msgs.size() - 1]["reply"] == "Good morning! What can I get you?", "맞으면 다음 줄로 (규칙으로 인사 달성)")
	await send("one")
	await send("two")
	await send("three")
	ok(ms.script_state["idx"] == 2 and not ms.done.has("order_drink") and has_text(ms._msg_scroll, "이렇게 말할 수 있어요: I'd like a latte, please."), "3번 틀리면 모범 답을 보여 주고 목표 미달성으로 넘어감")
	await send("A medium, please")
	ok(ms.done.has("ask_size") and ms.script_state["idx"] == 3, "다음 줄도 통과")
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _bad(0, "연결 실패")
	await send("Thank you so much!")
	ok(ms.status == "result", "마지막 줄 통과 -> 종료 (check 서버가 안 돼도 유사도로 통과)")
	ok(ms.done.get("thank") == "rule", "문장 유사도로 줄의 목표 달성")
	ok(count_calls("/chat") == 0 and count_calls("/feedback") == 0 and count_calls("/missions/judge") == 0, "AI 호출 0회 (/chat, /feedback, /judge 없음)")
	ok(paths().size() <= 2 and paths().all(func(p: String) -> bool: return p == "/missions" or p == "/missions/check"), "나간 경로는 /missions, /missions/check 뿐: %s" % str(paths()))
	ok(ms.fb_state == "none" and has_text(ms, "대본 모드 정리") and has_text(ms, "놓친 줄"), "AI 피드백 대신 규칙 요약과 놓친 줄")
	ok(MissionLogic.count_done(ms._goals(), ms.done) == 3 and ms._calc_award()["stars"] == 2, "3 / 4 달성 -> 별 2")
	ok(Store.xp("en") == xp0 + 20 + 30 + 20, "XP = 20 + 30 + 20")
	ok(find_button(ms, "AI로 다시 판정") == null, "대본 모드 결과에는 판정 버튼 없음")
	ms.llm_override = -1

	print("[script: /chat 503 에서 대본 모드로 처음부터]")
	default_routes()
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _bad(503, "AI를 쓸 수 없어요.")
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	await send("Hi there")
	ok(ms.chat_failed and find_button(ms, "대본 모드로 연습") != null, "대화 중 /chat 실패 -> 대본 모드 버튼")
	find_button(ms, "대본 모드로 연습").pressed.emit()
	await settle(3)
	ok(ms.mode == "script" and ms.status == "talk" and ms.msgs.size() == 1 and ms.done.is_empty() and not ms.chat_failed, "대본 모드로 처음부터")


# ---------------------------------------------------------------- 5b. 검사기 자체 시험 (일부러 틀린 화면)

func _test_checker_itself() -> void:
	print("[checker: 일부러 망가뜨린 화면에서 레이아웃 검사기가 실제로 FAIL 을 내는지]")
	var bad := VBoxContainer.new()
	bad.size = Vector2(412, 600)
	add_child(bad)
	var wide_label := Label.new()
	wide_label.text = "x"
	wide_label.custom_minimum_size = Vector2(800, 0)
	bad.add_child(wide_label)
	var tiny := Button.new()
	tiny.text = "작은 버튼"
	tiny.custom_minimum_size = Vector2(0, 20)
	bad.add_child(tiny)
	await settle(2)
	var problems: Array = layout_problems(bad, 412)
	var has_l1 := false
	var has_l2 := false
	for p in problems:
		if str(p).begins_with("L1"):
			has_l1 = true
		if str(p).begins_with("L2"):
			has_l2 = true
	ok(has_l1, "폭 800 짜리 라벨 -> L1 문제 검출")
	ok(has_l2, "높이 20 짜리 버튼 -> L2 문제 검출")
	tiny.custom_minimum_size = Vector2(0, 44)
	tiny.set_meta("touch_exempt", true)
	wide_label.custom_minimum_size = Vector2(100, 0)
	await settle(2)
	ok(layout_problems(bad, 412).is_empty(), "고치면 문제 없음으로 돌아옴")
	bad.queue_free()
	# 가짜 서버가 틀린 응답을 줘도 검사가 통과로 바뀌지 않는지: 규칙 체크가 아무것도 안 잡는 서버
	default_routes()
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _res({"mission_id": "cafe_order", "goals": [], "new": [], "all_done": false})
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	await send("Hi, good morning")
	ok(ms.done.is_empty(), "규칙이 아무것도 못 잡는 서버 -> 목표 달성 0 (자동으로 늘어나지 않음)")


# ---------------------------------------------------------------- 6. 레이아웃 (T4-6)

func _test_layout() -> void:
	print("[layout: 412 x 915 (폰) 와 1280 x 800 (PC)]")
	default_routes()
	await make_screen(412, 915)
	var p_list: Array = layout_problems(ms, 412)
	ok(p_list.is_empty(), "412 목록: L1·L2 문제 없음 %s" % str(p_list))
	await to_brief()
	var p_brief: Array = layout_problems(ms, 412)
	ok(p_brief.is_empty(), "412 설명: L1·L2 문제 없음 %s" % str(p_brief))
	await start_ai()
	await send("Hi, good morning")
	var p_chat: Array = layout_problems(ms, 412)
	ok(p_chat.is_empty(), "412 대화: L1·L2 문제 없음 %s" % str(p_chat))
	ok(ms._goal_bar.visible and not ms._side_wrap.visible, "412: 목표는 위쪽 한 줄, 오른쪽 패널 없음")
	ok(ms._goal_bar_box.get_child_count() == 1 and (ms._goal_bar_box.get_child(0) as Button).text.begins_with("목표 1 / 4"), "412: 접힌 한 줄 '목표 1 / 4'")
	ok(ms._goal_bar.size.y <= 64.0, "412: 접힌 목표 줄 높이 %.0f <= 64" % ms._goal_bar.size.y)
	ok(ms._mic.get_parent() == ms._mic_row, "412: 마이크는 아래 줄 (한 줄에 안 들어감)")
	(ms._goal_bar_box.get_child(0) as Button).pressed.emit()
	await settle(3)
	ok(ms._goal_bar_box.get_child_count() > 1 and layout_problems(ms, 412).is_empty(), "412: 펼치면 목표 목록 (레이아웃 문제 없음)")
	var msg_count: int = ms.msgs.size()
	var first_reply: String = str(ms.msgs[0]["reply"])
	holder.size = Vector2(1280, 800)
	await settle(4)
	ok(ms._side_wrap.visible and not ms._goal_bar.visible and ms._mic.get_parent() == ms._comp_row, "1280: 오른쪽 패널, 마이크는 입력줄")
	ok(ms._side_box.get_child_count() >= 4 and has_text(ms._side_box, "목표  1 / 4"), "1280: 오른쪽 패널에 목표 목록")
	ok(ms.msgs.size() == msg_count and ms.msgs[0]["reply"] == first_reply and has_text(ms._msg_scroll, first_reply), "크기를 바꿔도 대화 내용 유지")
	var p_wide: Array = layout_problems(ms, 1280)
	ok(p_wide.is_empty(), "1280 대화: L1·L2 문제 없음 %s" % str(p_wide))
	holder.size = Vector2(412, 915)
	await settle(4)
	ok(ms._goal_bar.visible and not ms._side_wrap.visible and ms.msgs.size() == msg_count and layout_problems(ms, 412).is_empty(), "다시 412 로: 오류 없고 대화 유지")
	holder.size = Vector2(1280, 800)
	ms.phone_mode = 1
	ms._apply_layout(true)
	await settle(3)
	ok(ms._goal_bar.visible and not ms._side_wrap.visible, "폰(Platform.is_phone 판정)이면 넓은 화면에서도 접힌 한 줄")
	ms.phone_mode = -1
	ms._apply_layout(true)
	await settle(2)
	# 결과 화면
	ms._on_end_pressed()
	await settle(3)
	ok(ms.status == "result" and layout_problems(ms, 1280).is_empty(), "1280 결과: L1·L2 문제 없음 %s" % str(layout_problems(ms, 1280)))
	holder.size = Vector2(412, 915)
	await settle(4)
	var p_res: Array = layout_problems(ms, 412)
	ok(p_res.is_empty(), "412 결과: L1·L2 문제 없음 %s" % str(p_res))
	await make_screen(1280, 800)
	ok(layout_problems(ms, 1280).is_empty(), "1280 목록: L1·L2 문제 없음 %s" % str(layout_problems(ms, 1280)))
	await to_brief()
	ok(layout_problems(ms, 1280).is_empty(), "1280 설명: L1·L2 문제 없음")
	# 긴 일본어/긴 문장이 와도 폭이 늘지 않는다
	await make_screen(412, 915)
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _res({"reply": "This is a very long reply without any natural break so it must wrap inside the bubble even on a narrow phone screen because words are long enough. " + "supercalifragilisticexpialidocious ".repeat(3), "ko": "아주 긴 번역 문장입니다 " + "가나다라마바사 ".repeat(8)})
	await to_brief()
	await start_ai()
	await send("Hi there")
	ok(layout_problems(ms, 412).is_empty(), "412: 긴 AI 답도 폭을 넘지 않음 %s" % str(layout_problems(ms, 412)))


# ---------------------------------------------------------------- 7. 화면 수명 · 녹음

func _test_lifecycle() -> void:
	print("[lifecycle: queue_free / 언어 전환 / on_hide]")
	default_routes()
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	holds = {"/chat": true}
	ms._input.text = "Hi, good morning"
	ms._send_message()
	await settle(4)
	var pending_chat: FakeCall = (held["/chat"] as Array)[0]
	ok(ms.status == "wait" and not pending_chat.done, "응답 대기 중")
	var screen_ref: MissionScreen = ms
	holder.remove_child(ms)  # 트리에서 빼면 _exit_tree 가 요청을 취소한다
	await settle(2)
	ok(pending_chat.done and pending_chat.result.get("cancelled", false), "화면이 트리에서 빠지면 진행 중인 요청을 취소")
	screen_ref.free()
	ms = null
	await settle(3)
	holds = {}
	# queue_free 도중 응답이 늦게 와도 오류 없음
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	holds = {"/chat": true, "/missions/check": true}
	ms._input.text = "Hi, good morning"
	ms._send_message()
	await settle(3)
	var c1: FakeCall = (held["/chat"] as Array)[0]
	var c2: FakeCall = (held["/missions/check"] as Array)[0]
	holder.queue_free()
	await settle(3)
	c1.complete(_res(fx("chat")))
	c2.complete(_check_route({"text": "hi", "done": []}))
	await settle(3)
	ok(c1.done and c2.done, "queue_free 뒤 늦은 응답이 와도 오류 없이 끝남 (콘솔의 SCRIPT ERROR 0건으로 확인)")
	holds = {}
	holder = null
	ms = null
	# 1.1.1: 끝내기를 누르면 녹음 중이던 것도 멈춘다 (마이크는 열지 않고 Recorder 상태만 흉내)
	default_routes()
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	var old_rec_mode: String = Recorder.mode_override
	Recorder.mode_override = "phone"
	Recorder.recording = true
	Recorder.owner_id = ms._mic.get_instance_id()
	ms._finish()
	ok(ms.status == "result" and not Recorder.recording, "1.1.1: _finish() 가 녹음 중이면 멈춘다")
	Recorder.recording = false
	Recorder.owner_id = 0
	Recorder.mode_override = old_rec_mode
	# 1.1.1: 확인 요청을 기다리는 동안 /chat 은 아직 _pending 에 없다 -> 화면을 새로 시작해도 취소돼야 한다
	default_routes()
	await make_screen(1280, 800)
	await to_brief()
	await start_ai()
	holds = {"/chat": true, "/missions/check": true}
	ms._input.text = "Hi, good morning"
	ms._send_message()
	await settle(3)
	var early_chat: FakeCall = (held["/chat"] as Array)[0]
	ok(ms.status == "wait" and not early_chat.done, "1.1.1: 확인 응답을 기다리는 중 /chat 도 나가 있음")
	ms._reset_run()
	ok(early_chat.done and early_chat.result.get("cancelled", false), "1.1.1: _cancel_all() 이 아직 대기 목록에 없던 /chat 요청도 취소")
	holds = {}
	await settle(2)
	# 언어 전환(open 다시 호출) 중 이전 응답 무시
	default_routes()
	holds = {"/missions": true}
	await make_screen(1280, 800)
	ok(ms.status == "loading" and has_text(ms, "불러오는 중"), "목록 로딩 중 표시")
	ms.open("ja")  # 요청 중 언어 전환
	await settle(3)
	release("/missions", _res(fx("list")))
	await settle(3)
	ok(ms.status == "list" and ms.missions.is_empty() and has_text(ms, "일본어 미션은 다음 버전"), "요청 중 언어를 바꾸면 늦게 온 영어 목록은 버려짐")
	holds = {}
	ms.open("en")
	await settle(4)
	ok(ms.missions.size() == 3, "영어로 돌아오면 목록 다시 표시")
	ms.on_hide()
	ok(not Recorder.recording, "on_hide: 녹음 중 아님 (녹음은 열지 않음)")
	# open 이 _ready 보다 먼저 불려도 됨
	var late := MissionScreen.new()
	late.http = Callable(self, "_fake")
	late.open("en")
	holder.add_child(late)
	await settle(5)
	ok(late.status == "list" and late.missions.size() == 3, "add_child 전에 open() 을 불러도 나중에 적용")
	late.queue_free()
	await settle(2)
	# STT: 음성 입력은 /stt 로 가고 글자만 입력창에 들어옴
	await make_screen(1280, 800)
	routes["/stt"] = func(_b: Variant) -> Dictionary: return _res({"text": "Hi, good morning"})
	await to_brief()
	await start_ai()
	Store.prefs["auto_send"] = false
	ms._on_recorded({"b64": "AAAA"})
	await settle(4)
	ok(ms._input.text == "Hi, good morning" and count_calls("/stt") == 1 and count_calls("/chat") == 0, "음성 입력: /stt 후 글자만 입력창에 (자동 보내기 끔)")
	Store.prefs["auto_send"] = true
	routes["/stt"] = func(_b: Variant) -> Dictionary: return _res({"text": ""})
	ms._input.text = ""
	ms._on_recorded({"b64": "AAAA"})
	await settle(4)
	ok(ms.msgs.size() == 1 and ms.status == "talk", "인식 결과가 빈 글자면 아무것도 안 보냄")
	routes["/stt"] = func(_b: Variant) -> Dictionary: return _bad(502, "음성 인식 실패")
	ms._on_recorded({"b64": "AAAA"})
	await settle(4)
	ok(ms.msgs.size() == 1 and not ms.stt_busy, "음성 인식 실패해도 멈추지 않음")
	Store.prefs["auto_send"] = true


# ---------------------------------------------------------------- 8. 라이브 (선택)

func _test_live() -> void:
	if not Api.base_overridden:
		print("[live] 라이브 건너뜀 (-- --api=http://127.0.0.1:8814 로 실행하면 실제 서버를 씀)")
		return
	print("[live] ", Api.base_url)
	if Api.base_url.ends_with(":8770"):
		ok(false, "라이브: 8770 은 쓰지 않는다")
		return
	var lh := Control.new()
	lh.size = Vector2(1280, 800)
	add_child(lh)
	var live := MissionScreen.new()  # http 훅 없음 = 실제 Api
	lh.add_child(live)
	await settle(2)
	live.open("en")
	for i in 80:
		if live.status != "loading":
			break
		await get_tree().create_timer(0.1).timeout
	ok(live.status == "list" and live.missions.size() >= 1 and not live.list_error, "라이브: GET /missions 로 미션 목록 표시 (%d개)" % live.missions.size())
	if live.missions.size() >= 1:
		var m: Dictionary = live.missions[0]
		var goals: Array = m["goals"]
		var req = Api.post_json("/missions/check", {"lang": "en", "mission_id": m["id"], "text": "Hi, good morning! I'd like a latte, please.", "done": []}, Api.TIMEOUT_SHORT, false)
		var res: Dictionary = await req.wait()
		ok(res["ok"] and res["data"] is Dictionary and (res["data"] as Dictionary).has("goals"), "라이브: POST /missions/check 성공")
		var served: Array = MissionLogic.reached_ids(goals, res["data"])
		print("    라이브 check 로 달성된 목표: ", served)
		ok(res["ok"], "라이브: 응답을 MissionLogic 이 읽을 수 있음")
	lh.queue_free()
	await settle(2)
