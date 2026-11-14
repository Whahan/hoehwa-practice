extends Node
## Headless test: 일본어 미션 화면 (MissionScreen lang "ja") + 일본어 쪽 MissionLogic (v1.7.0 작업 B4, 설계 4.2 B4-1..B4-9).
##   PC:   godot --headless --path godot res://tests/mission_ja_flow_test.tscn -- --api=http://127.0.0.1:9
##   폰:   godot --headless --path godot --resolution 412x915 res://tests/mission_ja_flow_test.tscn -- --phone --api=http://127.0.0.1:9
##   (더해서 --font-scale=1.5, --dark 로도 돌린다.)  마지막 줄: "== mission_ja_flow_test: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 서버 없이 고정 JSON(sample_mission_list_ja.json, sample_mission_chat_ja.json)과 가짜 요청 객체로 돈다.
## 흐름 시험은 함수를 직접 부르지 않고 실제 Button 의 pressed 를 낸다(press: 줄). 입력칸 글자만 코드로 넣는다(키보드 대신).
## Store.progress_path / prefs_path / StudyLog.path 는 user://test_* 로 바꾸고 끝나면 돌려 놓는다.

const FIX := "res://tests/sample_mission_%s.json"
const TMP_PROGRESS := "user://test_mission_ja_progress.json"
const TMP_LOG := "user://test_mission_ja_studylog.json"
const TMP_PREFS := "user://test_mission_ja_prefs.json"
## 가짜 /missions/check 규칙: 미션 id -> 목표 id -> 이 글자가 들어 있으면 달성 (일부러 일부 목표는 규칙이 못 잡게 비워 둔다)
const RULES := {
	"ja_konbini": {"find_item": ["どこ"], "buy_item": ["ください"], "pay": ["カード", "現金", "払"], "thank": ["ありがとう"]},
	"ja_ramen": {"seat_party": ["人"], "order_ramen": ["ラーメン", "らーめん"], "customize": [], "ask_bill": [], "thank": []},
	"ja_self_intro": {"say_name": ["です"], "nice_meet": ["よろしく"]},
}

var passed: int = 0
var failed: int = 0
var presses: int = 0

var calls: Array = []        ## {method, path (쿼리 뺀 것), full, body}
var routes: Dictionary = {}  ## path -> Callable(body) -> 결과 Dictionary
var holder: Control = null
var ms: MissionScreen = null
var phone: bool = false


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


## 검사기를 일부러 틀린 입력에 돌려서 "실패로 판정되는지" 확인하는 줄. detected 가 true 여야 통과.
func selfcheck(detected: bool, name: String) -> void:
	if detected:
		passed += 1
		print("  selfcheck FAIL-as-expected  ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck 가 틀린 입력을 못 잡음: ", name)


func _ready() -> void:
	print("== mission_ja_flow_test start ==")
	phone = Platform.is_phone()
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
	StudyLog.load_from_disk()
	var saved_prefs: Dictionary = Store.prefs.duplicate(true)
	Store.prefs["auto_speak"] = false
	Store.prefs["show_reading"] = true
	Store.prefs["show_hangul_ja"] = true
	_test_logic()
	await _test_list()
	await _test_script_flow()
	await _test_ai_flow()
	await _test_reading_prefs()
	await _test_wrong_inputs()
	await _test_checkers_themselves()
	ok(presses >= 20, "실제 버튼 누름 press: 줄 %d 번 (>= 20)" % presses)
	if holder != null and is_instance_valid(holder):
		holder.queue_free()
	Store.prefs = saved_prefs
	for f in [TMP_PROGRESS, TMP_LOG, TMP_LOG + ".tmp", TMP_PREFS]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	StudyLog.load_from_disk()
	Store.progress_path = old_progress_path
	Store.prefs_path = old_prefs_path
	StudyLog.path = old_log_path
	print("== mission_ja_flow_test: %d passed, %d failed ==" % [passed, failed])
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
	calls.append({"method": method, "path": p, "full": path, "body": body})
	var fc := FakeCall.new()
	var handler: Callable = routes.get(p, Callable())
	var res: Dictionary = handler.call(body) if handler.is_valid() else _bad(404, "없는 경로예요.")
	_complete_later(fc, res)
	return fc


func _complete_later(fc: FakeCall, res: Dictionary) -> void:
	await get_tree().process_frame
	fc.complete(res)


func _check_route(b: Variant) -> Dictionary:
	var body: Dictionary = b
	var mid: String = str(body.get("mission_id", ""))
	var text: String = str(body.get("text", ""))
	var done_in: Array = body.get("done", []) if body.get("done", []) is Array else []
	var rules: Dictionary = RULES.get(mid, {})
	var goals: Array = []
	var all_done := true
	for gid in rules.keys():
		var was: bool = done_in.has(gid)
		var hit := false
		for needle in rules[gid]:
			if text.contains(str(needle)):
				hit = true
		var now: bool = was or hit
		if not now:
			all_done = false
		goals.append({"id": gid, "done": now, "new": now and not was})
	return _res({"mission_id": mid, "goals": goals, "new": [], "all_done": all_done})


func default_routes() -> void:
	routes = {
		"/missions": func(_b: Variant) -> Dictionary: return _res(fx("list_ja")),
		"/missions/check": func(b: Variant) -> Dictionary: return _check_route(b),
		"/chat": func(_b: Variant) -> Dictionary: return _res(fx("chat_ja")),
		"/feedback": func(_b: Variant) -> Dictionary: return _res(_feedback_ja()),
		"/missions/judge": func(_b: Variant) -> Dictionary: return _res({"ai": true, "goals": []}),
	}


func _feedback_ja() -> Dictionary:
	return {
		"scores": {"fluency": 3, "accuracy": 4, "vocabulary": 3},
		"summary": "주문과 계산을 자연스럽게 말했어요.",
		"corrections": [{"you": "おかいけいおねがい", "better": "お会計をお願いします。", "reading": "おかいけいをおねがいします。",
			"pron": "オカイケイヲオネガイシマス。", "ko": "계산 부탁드립니다.", "why": "を와 ます를 붙이면 정중해요."}],
		"phrases": [{"phrase": "麺は固めでお願いします。", "reading": "めんはかためでおねがいします。", "pron": "メンワカタメデオネガイシマス。", "ko": "면은 단단하게 해 주세요."}],
	}


func make_screen(lang: String = "ja") -> void:
	if holder != null and is_instance_valid(holder):
		holder.queue_free()
		await settle(2)
	calls = []
	holder = Control.new()
	holder.size = Vector2(412, 915) if phone else Vector2(1280, 800)
	add_child(holder)
	ms = MissionScreen.new()
	ms.http = Callable(self, "_fake")
	ms.llm_override = 0
	holder.add_child(ms)
	await settle(2)
	ms.open(lang)
	await settle(4)


func settle(n: int = 5) -> void:
	for i in n:
		await get_tree().process_frame


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


func buttons_named(node: Node, text: String, out: Array = []) -> Array:
	if node is Button and node.is_visible_in_tree() and (node as Button).text == text:
		out.append(node)
	for ch in node.get_children():
		buttons_named(ch, text, out)
	return out


## 실제로 누른다: 보이고 눌러도 되는 버튼만 누르고 press: 줄을 찍는다. 못 누르는 버튼이면 false (아무 일도 안 한다).
func press(b: Button, label: String) -> bool:
	if b == null or not b.is_visible_in_tree() or b.disabled:
		print("  (누를 수 없음: ", label, ")")
		return false
	presses += 1
	print("press: ", label)
	b.pressed.emit()
	await settle(6)
	return true


## 목록에서 제목이 title 인 카드의 [선택] 버튼
func select_btn(title: String) -> Button:
	for b in buttons_named(ms, "선택"):
		if texts((b as Button).get_parent()).has(title):
			return b as Button
	return null


## 목표 패널의 "n / m" (폰: 위쪽 접힌 한 줄, PC: 오른쪽 패널). 못 찾으면 [-1, -1].
func goal_counter() -> Array:
	var rx := RegEx.new()
	rx.compile("목표\\s+(\\d+) / (\\d+)")
	for box in [ms._goal_bar_box, ms._side_box]:
		for t in texts(box):
			var m: RegExMatch = rx.search(str(t))
			if m != null:
				return [int(m.get_string(1)), int(m.get_string(2))]
	return [-1, -1]


func expect_counter(n: int, m: int) -> bool:
	var c: Array = goal_counter()
	return c[0] == n and c[1] == m


## 화면 전체 글에서 연속 5자리 이상 숫자(unix 시각·ms·바이트가 그대로 보이는 것)를 찾는다 (C-15).
func five_digits(node: Node) -> Array:
	var rx := RegEx.new()
	rx.compile("\\d{5,}")
	var out: Array = []
	for t in texts(node):
		if rx.search(str(t)) != null:
			out.append(str(t))
	return out


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


func screen_width() -> float:
	return 412.0 if phone else 1280.0


## 지금 화면의 보이는 글에 5자리 숫자가 없고 레이아웃 문제도 없는지 (상태 이름을 단언 이름에 붙인다)
func scan_state(name: String) -> void:
	var digits: Array = five_digits(ms)
	ok(digits.is_empty(), "C-15 %s: 5자리 이상 숫자 없음 %s" % [name, str(digits)])
	var lp: Array = layout_problems(ms, screen_width())
	ok(lp.is_empty(), "%s: 레이아웃 L1·L2 문제 없음 %s" % [name, str(lp)])


## 말풍선 영역에서 비어 있지 않은 Label 개수
func msg_label_count() -> int:
	var n := 0
	for l in _labels(ms._msg_scroll):
		if (l as Label).text != "":
			n += 1
	return n


func _labels(node: Node, out: Array = []) -> Array:
	if node is Label:
		out.append(node)
	for ch in node.get_children():
		_labels(ch, out)
	return out


func type_and_send(text: String, step: String) -> bool:
	ms._input.text = text
	return await press(ms._send, "보내기 (%s)" % step)


# ---------------------------------------------------------------- 1. MissionLogic (B4-4)

func _test_logic() -> void:
	print("[MissionLogic: 선택 필드 보존 (설계 2.3.3)]")
	var parsed: Dictionary = MissionLogic.parse_list(fx("list_ja"))
	var ms_list: Array = parsed["missions"]
	var kon: Dictionary = ms_list[0]
	ok(ms_list.size() == 8 and not bool(parsed["unsupported"]), "ja 목록 8개, unsupported false")
	ok(kon["opening_rd"] == "いらっしゃいませ。なにかおさがしですか。" and kon["opening_pr"] == "イラッシャイマセ。ナニカオサガシデスカ。", "opening_rd / opening_pr 보존")
	ok((kon["goals"] as Array)[2]["hint_rd"] == "かーどではらいます。", "goals[].hint_rd 보존")
	var sl: Dictionary = (kon["script"] as Array)[2]
	ok(sl["ai_rd"] == "あたためますか。おしはらいはどうしますか。" and sl["ai_pr"] != "" and sl["model_rd"] == "かーどではらいます。" and sl["model_pr"] == "カードデハライマス。", "script[].ai_rd/ai_pr/model_rd/model_pr 보존")
	var plain: Dictionary = {}
	for m in ms_list:
		if m["id"] == "ja_self_intro":
			plain = m
	ok(plain["opening_rd"] == "" and plain["opening_pr"] == "" and (plain["goals"] as Array)[0]["hint_rd"] == "" and (plain["script"] as Array)[0]["ai_rd"] == "" and (plain["script"] as Array)[0]["model_pr"] == "", "읽기 필드가 없으면 빈 문자열")
	var en: Dictionary = MissionLogic.normalize_mission({"id": "x", "title_ko": "t", "opening": "Hi", "goals": [{"id": "g", "label_ko": "l", "hint_en": "h"}], "script": [{"ai": "Hi", "goal": "g", "model": "Hello"}]})
	ok(en["opening"] == "Hi" and en["opening_rd"] == "" and (en["script"] as Array)[0]["ai"] == "Hi", "영어 항목은 예전 값 그대로 (읽기 필드만 빈 문자열)")

	print("[MissionLogic: norm_ja]")
	ok(MissionLogic.norm_ja("ラーメン") == "らーめん", "가타카나 -> 히라가나, 장음 유지")
	ok(MissionLogic.norm_ja("ＡＢＣ１２３　ｘ") == "abc123x", "전각 영숫자 -> 반각 소문자, 전각 공백은 지움")
	ok(MissionLogic.norm_ja("ｶﾞｷﾞ ﾊﾟﾝ ｳﾞ ｱｲｳ") == "がぎぱんゔあいう", "반각 가타카나 + 탁점·반탁점 결합")
	ok(MissionLogic.norm_ja("、。!? 「 」ーー") == "ーー", "부호·공백은 지우고 ー 는 남김")
	ok(MissionLogic.norm_ja("ヽヾ") == "ゝゞ", "ヽ ヾ -> ゝ ゞ")
	ok(MissionLogic.norm_ja("あ".repeat(500)).length() == 300, "앞 300자만")
	ok(MissionLogic.norm_ja("") == "" and MissionLogic.norm_ja(String.chr(0x1F600) + String.chr(7)) == "", "빈 글·이모지·제어 문자 -> 빈 글")

	print("[MissionLogic.apply_judge ja (증거 확인)]")
	var pend: Array = ["a", "b", "c"]
	var me: Array = ["ごちそうさまでした", "はい、おかいけいをおねがいします"]
	var d1 := {}
	var r1: Array = MissionLogic.apply_judge(d1, pend, {"goals": [{"id": "a", "done": true, "evidence": "ゴチソウサマ"}]}, me, "ja")
	ok(r1 == ["a"] and d1["a"] == "ai", "가타카나만 다른 증거는 인정")
	var d2 := {}
	var r2: Array = MissionLogic.apply_judge(d2, pend, {"goals": [{"id": "a", "done": true, "evidence": "ｺﾞﾁｿｳｻﾏ"}, {"id": "b", "done": true, "evidence": "ＯＫ"}]}, ["ｺﾞﾁｿｳｻﾏでした"], "ja")
	ok(r2 == ["a"], "반각 가타카나 증거도 인정 (norm_ja), 2글자 이하(ok)는 불인정: %s" % str(r2))
	var d3 := {}
	var r3: Array = MissionLogic.apply_judge(d3, pend, {"goals": [{"id": "a", "done": true, "evidence": "いらっしゃいませ"}]}, me, "ja")
	ok(r3.is_empty() and d3.is_empty(), "상대 문장에서 따온 증거(내 문장에 없음)는 불인정")
	var d4 := {}
	var r4: Array = MissionLogic.apply_judge(d4, pend, {"goals": [{"id": "a", "done": true, "evidence": ""}, {"id": "b", "done": true}, {"id": "c", "done": true, "evidence": "   "}]}, me, "ja")
	ok(r4.is_empty(), "빈 증거·증거 없음·공백만 불인정")
	var d5 := {}
	var r5: Array = MissionLogic.apply_judge(d5, pend, {"goals": [{"id": "a", "done": true, "evidence": "はい"}, {"id": "b", "done": true, "evidence": "ーー"}, {"id": "c", "done": true, "evidence": "ーーー"}]}, ["はい、ーーー ーー"], "ja")
	ok(r5.is_empty() and d5.is_empty(), "서버 하한(2글자)을 통과하는 짧은 증거 はい / ーー / ーーー 는 앱이 불인정")
	var d6 := {}
	var r6: Array = MissionLogic.apply_judge(d6, pend, {"goals": [{"id": "a", "done": true, "evidence": "ええ"}, {"id": "b", "done": true, "evidence": "ありがとう"}]}, ["ええ、ありがとうございます"], "ja")
	ok(r6 == ["b"], "정규화 후 2글자(ええ)는 불인정, 5글자는 인정: %s" % str(r6))
	var d7 := {}
	var r7: Array = MissionLogic.apply_judge(d7, ["a"], {"goals": [{"id": "a", "done": "true", "evidence": "ありがとう"}, {"id": "zzz", "done": true, "evidence": "ありがとう"}]}, ["ありがとう"], "ja")
	ok(r7.is_empty(), "done 이 문자열이거나 pending 에 없는 id 는 불인정")
	ok(MissionLogic.apply_judge({}, pend, null, me, "ja").is_empty() and MissionLogic.apply_judge({}, pend, {"goals": "x"}, me, "ja").is_empty(), "깨진 응답(null, goals 가 문자열)은 아무것도 안 함")
	# 영어(lang 생략)는 예전 그대로: 짧은 증거도 인정, 일본어 규칙을 쓰지 않음
	var de := {}
	var re: Array = MissionLogic.apply_judge(de, ["a"], {"goals": [{"id": "a", "done": true, "evidence": "Hi"}]}, ["Hi there"])
	ok(re == ["a"] and de["a"] == "ai", "영어 호출(lang 생략)은 기존 동작: 짧은 증거 Hi 도 인정")
	var de2 := {}
	ok(MissionLogic.apply_judge(de2, ["a"], {"goals": [{"id": "a", "done": true, "evidence": "Bye"}]}, ["Hi there"], "en").is_empty(), "lang en 명시도 같은 동작 (내 문장에 없으면 불인정)")

	print("[MissionLogic.script_passes ja]")
	var line: Dictionary = (kon["script"] as Array)[2]
	ok(MissionLogic.script_passes("かーどではらいました", line, [], "ja"), "모범 답 읽기(model_rd)와 비슷하면(84%) 통과")
	ok(not MissionLogic.script_passes("ぜんぜんちがう", line, [], "ja"), "전혀 다르면 불통과")
	ok(MissionLogic.script_passes("なんでも", line, ["pay"], "ja"), "규칙으로 줄의 목표에 닿으면 통과")
	ok(not MissionLogic.script_passes("", line, ["pay"], "ja") and not MissionLogic.script_passes("   ", line, [], "ja"), "빈 입력·공백은 불통과")
	ok(not MissionLogic.script_passes("かーどではらいました", line, []), "lang 생략(영어 토큰화)이면 일본어 글은 비교되지 않음 = lang 인자가 효과 있음")
	ok(MissionLogic.script_passes("I would like a latte", {"goal": "g", "model": "I would like a latte, please."}, []), "영어 호출(lang 생략)은 기존 동작")


# ---------------------------------------------------------------- 2. 목록 (B4-5)

func _test_list() -> void:
	print("[list: 일본어 탭 목록 (B4-5)]")
	default_routes()
	StudyLog.add_mission("ja", "ja_konbini", 3, 4)
	await make_screen("ja")
	ok(ms.status == "list" and ms.lang == "ja", "ja 로 열면 목록 상태")
	ok(str(calls[0]["full"]) == "/missions?lang=ja" and calls.size() == 1, "요청은 GET /missions?lang=ja 한 번")
	ok(ms.missions.size() == 8, "카드 8개 (영어와 같은 구조)")
	var ids: Array = []
	for m in ms.missions:
		ids.append(m["id"])
	ok(ids.slice(0, 3) == ["ja_konbini", "ja_ramen", "ja_self_intro"] and ids.size() == 8, "내 단계에 맞는 미션(1단계)이 앞: %s" % str(ids))
	ok(buttons_named(ms, "선택").size() == 8, "[선택] 버튼 8개")
	ok(has_text(ms, "편의점에서 계산하기") and has_text(ms, "병원 접수") and has_text(ms, "목표 4개"), "제목·목표 수 표시")
	ok(has_text(ms, "조금 어려워요"), "내 단계보다 높은 미션은 '조금 어려워요'")
	var card_of_konbini: Array = texts(select_btn("편의점에서 계산하기").get_parent())
	ok(card_of_konbini.has(MissionLogic.star_text(3)), "편의점 카드에 별 3개")
	var card_of_ramen: Array = texts(select_btn("라멘집에서 주문하기").get_parent())
	ok(not card_of_ramen.has(MissionLogic.star_text(3)), "라멘 카드에는 별 없음")
	scan_state("목록(ja)")
	# 영어 탭: 영어 미션만
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res(JSON.parse_string(FileAccess.get_file_as_string("res://tests/sample_mission_list.json")))
	ms.open("en")
	await settle(4)
	ok(str(calls[calls.size() - 1]["full"]) == "/missions?lang=en", "영어 탭은 GET /missions?lang=en")
	ok(ms.missions.size() == 3 and not has_text(ms, "편의점"), "영어 탭은 영어 미션만 (일본어 카드 없음)")
	# 옛 서버가 ja 에 unsupported:true
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res({"lang": "ja", "unsupported": true, "missions": [], "message": "일본어 미션은 다음 버전에서 만들 예정이에요."})
	ms.open("ja")
	await settle(4)
	ok(ms.missions.is_empty() and has_text(ms, "다음 버전에서 만들 예정"), "옛 서버의 unsupported:true 는 기존 안내 (호환)")
	# 404 / 서버 오류
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _bad(404, "Not Found")
	ms.open("ja")
	await settle(4)
	ok(has_text(ms, "최신 버전으로 업데이트해 주세요") and find_button(ms, "다시 시도") != null, "옛 서버 404 -> 업데이트 안내 + [다시 시도]")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _bad(0, "AI 엔진에 연결하지 못했어요.")
	ms.open("ja")
	await settle(4)
	ok(has_text(ms, "연결하지 못했어요") and ms.missions.is_empty(), "연결 오류 -> 오류 문구, 카드 없음")
	ms.open("fr")
	await settle(3)
	ok(ms.status == "list" and has_text(ms, MissionScreen.OTHER_LANG_NOTE) and ms.missions.is_empty(), "일본어·영어가 아닌 언어는 안내만")


# ---------------------------------------------------------------- 3. 대본 모드 흐름 (B4-2, 실제 버튼)

func _test_script_flow() -> void:
	print("[script flow: 목록 -> 설명 -> 대본 -> 결과 (실제 버튼)]")
	default_routes()
	StudyLog.load_from_disk()  # 목록 시험이 넣은 가짜 기록을 지운다 (임시 경로라 디스크에 아무것도 없음)
	await make_screen("ja")
	ms.llm_override = 1  # AI 없음: 대본 모드가 기본
	await press(select_btn("편의점에서 계산하기"), "선택: 편의점에서 계산하기")
	ok(ms.status == "brief" and has_text(ms, "찾는 물건이 어디 있는지 묻기"), "설명 화면에 목표 목록")
	ok(has_text(ms, "지금은 AI를 쓸 수 없어요"), "AI 없음 안내")
	scan_state("설명(ja)")
	await press(find_button(ms, "힌트 보기"), "힌트 보기")
	ok(has_text(ms, "カードで払います。") and has_text(ms, "かーどではらいます。"), "힌트: 일본어 예시 문장 + 히라가나 읽기(hint_rd)")
	scan_state("설명 힌트(ja)")
	await press(find_button(ms, "힌트 숨기기"), "힌트 숨기기")
	ok(not has_text(ms, "かーどではらいます。"), "힌트를 숨기면 읽기도 사라짐")
	await press(find_button(ms, "대본 모드로 연습"), "대본 모드로 연습")
	ok(ms.status == "talk" and ms.mode == "script", "대본 모드 대화 시작")
	ok(has_text(ms._msg_scroll, "いらっしゃいませ。何かお探しですか。"), "상대 첫 말풍선 (일본어)")
	ok(has_text(ms._msg_scroll, "いらっしゃいませ。なにかおさがしですか。"), "말풍선 아래 히라가나 읽기 (대본 ai_rd)")
	var hg: String = ReadingLine.hangul_of("いらっしゃいませ。なにかおさがしですか。", "イラッシャイマセ。ナニカオサガシデスカ。")
	ok(hg != "" and has_text(ms._msg_scroll, hg), "말풍선 아래 한글 소리 줄 (ai_pr 로 만듦): %s" % hg)
	ok(ms._input.placeholder_text.begins_with("일본어로"), "입력칸 안내가 일본어")
	ok(not ms._send.disabled, "보내기 켜짐")
	ok(expect_counter(0, 4), "목표 0 / 4")
	scan_state("대화 시작(ja)")
	# 1) 규칙으로 find_item
	await type_and_send("すみません、おにぎりはどこですか", "1줄 통과")
	ok(ms.status == "talk" and expect_counter(1, 4), "한 문장 뒤 목표 1 / 4 (규칙 체크)")
	ok(has_text(ms._msg_scroll, "おにぎりはあちらです。どれにしますか。"), "다음 상대 대사가 나옴")
	ok(has_text(ms._msg_scroll, "オニギリ") == false, "가타카나 발음형(pron)은 그대로 안 보이고 한글 소리 줄로만 보임")
	ok(not ms._send.disabled and ms._send.is_visible_in_tree(), "다음 입력 가능 (보내기 켜짐)")
	await _goal_panel_check()
	# 2) buy_item: 세 번 틀려서 모범 답을 보여 주고 넘어감
	var wrong_in_a_row := 0
	for i in 3:
		await type_and_send("わかりません", "2줄 틀림 %d/3" % (i + 1))
		wrong_in_a_row += 1
		if i < 2:
			ok(ms.status == "talk" and has_text(ms._msg_scroll, "조금 달라요") and has_text(ms._msg_scroll, "(%d/3)" % (i + 1)), "틀림 %d/3 안내" % (i + 1))
	ok(expect_counter(1, 4), "틀려서 넘어가도 목표는 그대로 1 / 4")
	ok(has_text(ms._msg_scroll, "이렇게 말할 수 있어요: このおにぎりをください。"), "3번 틀리면 모범 답을 보여 줌")
	var mhg: String = ReadingLine.hangul_of("このおにぎりをください。", "コノオニギリヲクダサイ。")
	ok(has_text(ms._msg_scroll, "このおにぎりをください。") and mhg != "" and has_text(ms._msg_scroll, mhg), "모범 답 아래에도 읽기·한글 소리 (model_rd/model_pr)")
	ok(has_text(ms._msg_scroll, "温めますか。お支払いはどうしますか。"), "넘어간 뒤 3번째 상대 대사")
	# 3) pay: 규칙은 못 잡지만 모범 답 읽기와 비슷해서(84%) 통과
	await type_and_send("かーどではらいました", "3줄 유사도 통과")
	ok(expect_counter(2, 4), "유사도로 통과하면 그 줄의 목표 달성 2 / 4")
	scan_state("대화 중(ja)")
	# 4) thank
	await type_and_send("ありがとうございます", "4줄 통과")
	ok(ms.status == "result", "마지막 줄 뒤 결과 화면")
	ok(has_text(ms._result_page, "목표 3 / 4 달성") and has_text(ms._result_page, "XP +70"), "결과: 목표 3 / 4 달성, XP +70")
	ok(has_text(ms._result_page, MissionLogic.star_text(2)), "결과: 별 2개")
	ok(has_text(ms._result_page, "대본 모드로 연습했어요"), "대본 모드 표시")
	scan_state("결과(ja)")
	ok(StudyLog.mission_best("ja_konbini").get("stars", 0) == 2 and StudyLog.mission_best("ja_konbini").get("plays", 0) == 1, "StudyLog: 별 2, plays 1 기록")
	# 결과 화면에서 못 한 목표를 눌러 직접 체크 -> 4 / 4, 별 3
	await press(find_button(ms._result_page, "살 물건 말하기", false), "목표 직접 체크: 살 물건 말하기")
	ok(has_text(ms._result_page, "목표 4 / 4 달성") and has_text(ms._result_page, MissionLogic.star_text(3)) and has_text(ms._result_page, "XP +90"), "직접 체크 뒤 4 / 4, 별 3, XP +90")
	ok(StudyLog.mission_best("ja_konbini").get("stars", 0) == 3 and StudyLog.mission_best("ja_konbini").get("plays", 0) == 1, "StudyLog: 직접 체크로 별 3, plays 는 그대로 1")
	await press(find_button(ms._result_page, "미션 목록"), "미션 목록")
	ok(ms.status == "list" and buttons_named(ms, "선택").size() == 8, "[미션 목록] 으로 돌아오면 카드 8개")
	ok(has_text(ms, MissionLogic.star_text(3)), "돌아온 목록에 별 표시")
	var check_calls: int = 0
	for c in calls:
		if c["path"] == "/missions/check":
			check_calls += 1
			ok(str((c["body"] as Dictionary).get("lang", "")) == "ja" and str((c["body"] as Dictionary).get("mission_id", "")) == "ja_konbini", "/missions/check 요청에 lang ja + 미션 id")
			break
	ok(check_calls >= 1 and not _called("/chat") and not _called("/feedback"), "대본 모드는 /chat·/feedback 을 부르지 않음")


func _goal_panel_check() -> void:
	if phone:
		await press(ms._goal_bar_box.get_child(0) as Button, "목표 패널 펼치기")
		ok(has_text(ms._goal_bar_box, "찾는 물건이 어디 있는지 묻기"), "폰: 펼치면 목표 목록")
		await press(find_button(ms._goal_bar_box, "힌트 보기"), "힌트 보기 (패널)")
	else:
		await press(find_button(ms._side_box, "힌트 보기"), "힌트 보기 (패널)")
	ok(has_text(ms._goal_bar_box if phone else ms._side_box, "かーどではらいます。"), "대화 중 힌트에도 읽기(hint_rd)")
	scan_state("대화 중 힌트(ja)")
	if phone:
		await press(find_button(ms._goal_bar_box, "힌트 숨기기"), "힌트 숨기기 (패널)")
		await press(ms._goal_bar_box.get_child(0) as Button, "목표 패널 접기")


func _called(path: String) -> bool:
	for c in calls:
		if c["path"] == path:
			return true
	return false


# ---------------------------------------------------------------- 4. AI 모드 (B4-3)

func _test_ai_flow() -> void:
	print("[AI flow: /chat 읽기 + /missions/judge 증거 확인 (가짜 응답)]")
	default_routes()
	await make_screen("ja")
	ms.llm_override = 0
	await press(select_btn("라멘집에서 주문하기"), "선택: 라멘집에서 주문하기")
	ok(not has_text(ms, "지금은 AI를 쓸 수 없어요"), "AI 있음: 대본 모드 안내 없음")
	await press(find_button(ms, "미션 시작"), "미션 시작")
	ok(ms.status == "talk" and ms.mode == "ai", "AI 모드 대화 시작")
	ok(has_text(ms._msg_scroll, "いらっしゃいませ。何名様ですか。") and has_text(ms._msg_scroll, "いらっしゃいませ。なんめいさまですか。"), "첫 말풍선: 일본어 + opening_rd")
	await type_and_send("二人です", "AI 1: 인원")
	ok(expect_counter(1, 5), "규칙 체크: 목표 1 / 5")
	ok(has_text(ms._msg_scroll, "かしこまりました。ご注文をどうぞ。"), "상대 답이 보임")
	ok(has_text(ms._msg_scroll, "かしこまりました。ごちゅうもんをどうぞ。"), "상대 답 아래 /chat 의 reading")
	var chat_hg: String = ReadingLine.hangul_of("かしこまりました。ごちゅうもんをどうぞ。", "カシコマリマシタ。ゴチュウモンヲドウゾ。")
	ok(chat_hg != "" and has_text(ms._msg_scroll, chat_hg), "상대 답 아래 /chat 의 pron 으로 만든 한글 소리 줄")
	var chat_body: Dictionary = {}
	var chk_body: Dictionary = {}
	for c in calls:
		if c["path"] == "/chat":
			chat_body = c["body"]
		if c["path"] == "/missions/check":
			chk_body = c["body"]
	ok(chat_body.get("lang", "") == "ja" and chk_body.get("lang", "") == "ja" and chk_body.get("mission_id", "") == "ja_ramen", "/chat·/missions/check 에 lang ja (미션 id ja_ramen)")
	ok(ms.status == "talk" and not ms._send.disabled, "답을 받은 뒤 다음 입력 가능")
	await type_and_send("しょうゆラーメンをください", "AI 2: 주문")
	ok(expect_counter(2, 5), "목표 2 / 5")
	await type_and_send("はい、かたいめでおねがいします", "AI 3: 면 굳기(규칙 못 잡음)")
	ok(expect_counter(2, 5), "규칙이 못 잡은 문장은 목표가 그대로 2 / 5")
	await type_and_send("ごちそうさまでした", "AI 4: 감사(규칙 못 잡음)")
	await type_and_send("おかいけいをおねがいします", "AI 5: 계산(규칙 못 잡음)")
	ok(expect_counter(2, 5) and ms.status == "talk", "5문장 뒤에도 2 / 5, 대화 계속")
	scan_state("AI 대화(ja)")
	await press(find_button(ms, "끝내기"), "끝내기")
	ok(ms.status == "result" and has_text(ms._result_page, "목표 2 / 5 달성"), "끝내기 -> 결과 2 / 5")
	ok(has_text(ms._result_page, "お会計をお願いします。") and has_text(ms._result_page, "おかいけいをおねがいします。"), "피드백 고쳐 말하기: 문장 + 히라가나 읽기")
	var ph_hg: String = ReadingLine.hangul_of("めんはかためでおねがいします。", "メンワカタメデオネガイシマス。")
	ok(has_text(ms._result_page, "麺は固めでお願いします。") and has_text(ms._result_page, ph_hg), "쓸 만한 표현: 문장 + 한글 소리")
	scan_state("AI 결과(ja)")
	# 1차 판정: customize 는 짧은 증거(はい), ask_bill 은 상대 문장에서 따온 증거 -> 둘 다 불인정, thank 는 가타카나 증거 -> 인정
	routes["/missions/judge"] = func(_b: Variant) -> Dictionary: return _res({"ai": true, "goals": [
		{"id": "customize", "done": true, "evidence": "はい"},
		{"id": "ask_bill", "done": true, "evidence": "かしこまりました"},
		{"id": "thank", "done": true, "evidence": "ゴチソウサマ"}]})
	await press(find_button(ms._result_page, "AI로 다시 판정"), "AI로 다시 판정 (1차)")
	var jb: Dictionary = {}
	for c in calls:
		if c["path"] == "/missions/judge":
			jb = c["body"]
	ok(jb.get("lang", "") == "ja" and jb.get("mission_id", "") == "ja_ramen" and (jb.get("pending", []) as Array).size() == 3, "/missions/judge 요청: lang ja, 놓친 목표 3개")
	ok(str(ms.done.get("thank", "")) == "ai" and not ms.done.has("customize") and not ms.done.has("ask_bill"), "가타카나 증거 thank 만 AI 인정, 짧은 증거·상대 문장 증거는 불인정: %s" % str(ms.done))
	ok(has_text(ms._result_page, "AI가 목표 1개를 더 인정했어요.") and has_text(ms._result_page, "목표 3 / 5 달성"), "판정 결과 문구 + 3 / 5")
	# 2차 판정: 장음만 있는 증거는 불인정, 내 문장에서 따온 증거는 인정
	routes["/missions/judge"] = func(_b: Variant) -> Dictionary: return _res({"ai": true, "goals": [
		{"id": "customize", "done": true, "evidence": "ーーー"},
		{"id": "ask_bill", "done": true, "evidence": "おかいけいを"}]})
	await press(find_button(ms._result_page, "AI로 다시 판정"), "AI로 다시 판정 (2차)")
	ok(str(ms.done.get("ask_bill", "")) == "ai" and not ms.done.has("customize"), "장음만 있는 증거는 불인정, 내 문장 증거(おかいけいを)는 인정")
	ok(has_text(ms._result_page, "목표 4 / 5 달성"), "4 / 5")
	var again: Button = find_button(ms._result_page, "다시 하기")
	ok(again != null and not again.disabled, "[다시 하기] 버튼 보임")
	await press(find_button(ms._result_page, "미션 목록"), "미션 목록 (AI 결과)")
	ok(ms.status == "list", "목록으로 돌아옴")


# ---------------------------------------------------------------- 5. 읽기 설정 (B4-6)

func _test_reading_prefs() -> void:
	print("[reading prefs: show_reading / show_hangul_ja (B4-6)]")
	default_routes()
	await make_screen("ja")
	ms.llm_override = 1
	await press(select_btn("편의점에서 계산하기"), "선택: 편의점에서 계산하기 (설정 시험)")
	await press(find_button(ms, "대본 모드로 연습"), "대본 모드로 연습 (설정 시험)")
	var rd: String = "いらっしゃいませ。なにかおさがしですか。"
	var hg: String = ReadingLine.hangul_of(rd, "イラッシャイマセ。ナニカオサガシデスカ。")
	ok(has_text(ms._msg_scroll, rd) and has_text(ms._msg_scroll, hg), "둘 다 켬: 히라가나 줄 + 한글 줄")
	Store.prefs["show_reading"] = false
	Store.prefs_changed.emit()
	await settle(3)
	ok(not has_text(ms._msg_scroll, rd) and has_text(ms._msg_scroll, hg) and has_text(ms._msg_scroll, "いらっしゃいませ。何かお探しですか。"), "show_reading 끔: 히라가나 줄만 숨김 (한글 줄·일본어 글은 남음)")
	Store.prefs["show_hangul_ja"] = false
	Store.prefs_changed.emit()
	await settle(3)
	ok(not has_text(ms._msg_scroll, rd) and not has_text(ms._msg_scroll, hg) and has_text(ms._msg_scroll, "いらっしゃいませ。何かお探しですか。"), "둘 다 끔: 읽기 줄 전부 숨김")
	Store.prefs["show_reading"] = true
	Store.prefs_changed.emit()
	await settle(3)
	ok(has_text(ms._msg_scroll, rd) and not has_text(ms._msg_scroll, hg), "show_reading 만 켬: 히라가나만")
	Store.prefs["show_hangul_ja"] = true
	Store.prefs_changed.emit()
	await settle(3)
	ok(has_text(ms._msg_scroll, rd) and has_text(ms._msg_scroll, hg), "둘 다 다시 켬")
	# 힌트의 읽기도 같은 설정을 따른다
	if not phone:
		await press(find_button(ms._side_box, "힌트 보기"), "힌트 보기 (설정 시험, PC 오른쪽 패널)")
		ok(has_text(ms._side_box, "かーどではらいます。"), "show_reading 켬: 힌트 읽기 보임")
		Store.prefs["show_reading"] = false
		Store.prefs_changed.emit()
		ms._render_goals()
		await settle(2)
		ok(not has_text(ms._side_box, "かーどではらいます。") and has_text(ms._side_box, "カードで払います。"), "show_reading 끔: 힌트의 읽기 줄만 숨김")
		Store.prefs["show_reading"] = true


# ---------------------------------------------------------------- 6. 일부러 틀린 입력 (B4-7)

func _test_wrong_inputs() -> void:
	print("[wrong inputs (B4-7)]")
	default_routes()
	await make_screen("ja")
	ms.llm_override = 1
	await press(select_btn("자기소개"), "선택: 자기소개 (읽기 필드 없는 미션)")
	await press(find_button(ms, "대본 모드로 연습"), "대본 모드로 연습 (자기소개)")
	ok(ms.status == "talk" and has_text(ms._msg_scroll, "はじめまして。お名前は?"), "읽기 필드가 없어도 시작하고 일본어 글은 보임")
	ok(msg_label_count() == 2, "읽기 필드가 없으면 읽기 줄 없이 이름표 + 말풍선뿐 (Label %d개)" % msg_label_count())
	# 빈 입력
	var before: int = ms.msgs.size()
	var n_check: int = _count("/missions/check")
	ms._input.text = ""
	var pressed_empty: bool = await press(ms._send, "보내기 (빈 입력)")
	ok(pressed_empty and ms.msgs.size() == before and _count("/missions/check") == n_check and ms.status == "talk", "빈 입력 [보내기] 는 무반응 (메시지·요청 없음)")
	ms._input.text = "  　 "
	await press(ms._send, "보내기 (공백만)")
	ok(ms.msgs.size() == before and _count("/missions/check") == n_check, "공백만 보내도 무반응")
	# 1만 자
	routes["/missions/check"] = func(b: Variant) -> Dictionary: return _check_route(b)
	ms._input.text = "あ".repeat(10000)
	await press(ms._send, "보내기 (1만 자)")
	var last_me: String = ""
	for m in ms.msgs:
		if m["role"] == "me":
			last_me = str(m["text"])
	ok(last_me.length() == MissionLogic.MAX_TEXT, "1만 자는 300자에서 잘려서 보냄 (%d자)" % last_me.length())
	var sent_len: int = 0
	for c in calls:
		if c["path"] == "/missions/check":
			sent_len = str((c["body"] as Dictionary).get("text", "")).length()
	ok(sent_len == MissionLogic.MAX_TEXT, "/missions/check 로 나간 글도 300자")
	# 체크 서버가 오류 (규칙 없이 글자 유사도만으로 진행)
	routes["/missions/check"] = func(_b: Variant) -> Dictionary: return _bad(500, "서버 오류")
	await type_and_send("私は田中です", "체크 서버 오류 + 모범 답과 같음")
	ok(ms.status == "talk" or ms.status == "result", "규칙 체크가 500 이어도 오류 없이 진행")
	ok(ms.done.has("say_name") or ms.script_state.get("idx", 0) >= 1, "체크 서버가 없어도 모범 답과 글자가 같으면 통과 (유사도)")
	# 서버 오류·옛 서버 404 안내
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _bad(404, "Not Found")
	ms.open("ja")
	await settle(4)
	ok(has_text(ms, "최신 버전으로 업데이트해 주세요"), "옛 서버 404 안내")
	# 목표 12개 초과
	var many_goals: Array = []
	for i in 15:
		many_goals.append({"id": "g%d" % i, "label_ko": "목표 %d" % i, "hint_en": "ありがとう%d" % i})
	var mm: Dictionary = MissionLogic.normalize_mission({"id": "ja_many", "title_ko": "많은 목표", "goals": many_goals, "opening": "こんにちは。"})
	ok((mm["goals"] as Array).size() == MissionLogic.MAX_GOALS, "목표 15개 -> 앞 12개만")
	routes["/missions"] = func(_b: Variant) -> Dictionary: return _res({"lang": "ja", "unsupported": false, "missions": [{"id": "ja_many", "title_ko": "많은 목표", "situation_ko": "시험", "min_stage": 1, "max_turns": 10, "opening": "こんにちは。", "goals": many_goals, "scenario": {"persona": "Tester"}, "script": []}]})
	ms.open("ja")
	await settle(4)
	await press(select_btn("많은 목표"), "선택: 많은 목표")
	ok(ms.status == "brief" and ms._goals().size() == 12, "화면도 목표 12개로 열림")
	var sc_btn: Button = find_button(ms, "대본 모드로 연습")
	ok(sc_btn != null and sc_btn.disabled, "대본이 없는 미션은 [대본 모드로 연습] 이 꺼짐")
	ms.llm_override = 0
	ms._render_brief()
	await press(find_button(ms, "미션 시작"), "미션 시작 (목표 12개)")
	ok(ms.status == "talk" and expect_counter(0, 12), "목표 0 / 12")
	scan_state("목표 12개(ja)")
	# 일본어 AI 실패 -> 다시 보내기
	routes["/chat"] = func(_b: Variant) -> Dictionary: return _bad(0, "AI에게 연결하지 못했어요.")
	routes["/missions/check"] = func(b: Variant) -> Dictionary: return _check_route(b)
	await type_and_send("ありがとうございます", "AI 실패")
	ok(ms.chat_failed and find_button(ms, "다시 보내기") != null, "/chat 실패 -> [다시 보내기]")


func _count(path: String) -> int:
	var n := 0
	for c in calls:
		if c["path"] == path:
			n += 1
	return n


# ---------------------------------------------------------------- 7. 검사기도 틀릴 수 있어야 한다 (C-12)

func _test_checkers_themselves() -> void:
	print("[checkers: 일부러 틀린 입력에서 검사기가 실패로 판정하는지]")
	var fake := Control.new()
	add_child(fake)
	var lbl := Label.new()
	lbl.text = "마지막 공부 1700000000000 ms"
	fake.add_child(lbl)
	var b4 := Label.new()
	b4.text = "1234 점"
	fake.add_child(b4)
	selfcheck(five_digits(fake).size() == 1, "five_digits 가 5자리 이상 숫자(1700000000000)만 잡음 (1234 는 통과)")
	# 목표 패널이 없는 화면에서 goal_counter 는 [-1, -1]
	var saved_goal_bar: VBoxContainer = ms._goal_bar_box
	var saved_side: VBoxContainer = ms._side_box
	ms._goal_bar_box = VBoxContainer.new()
	ms._side_box = VBoxContainer.new()
	selfcheck(goal_counter() == [-1, -1] and not expect_counter(0, 4), "goal_counter 는 패널이 없으면 [-1,-1], expect_counter 는 실패")
	ms._goal_bar_box.free()
	ms._side_box.free()
	ms._goal_bar_box = saved_goal_bar
	ms._side_box = saved_side
	# 누를 수 없는 버튼은 press 가 false (흐름 시험이 그냥 통과하지 못한다)
	var dead := Button.new()
	dead.text = "꺼진 버튼"
	dead.disabled = true
	fake.add_child(dead)
	var before: int = presses
	var res_dead: bool = await press(dead, "(selfcheck) 꺼진 버튼")
	selfcheck(not res_dead and presses == before, "press 는 꺼진 버튼을 누른 것으로 세지 않음")
	var res_null: bool = await press(null, "(selfcheck) null")
	selfcheck(not res_null, "press(null) 은 실패")
	# 너무 넓은 컨트롤 -> L1
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(5000, 10)
	fake.add_child(wide)
	selfcheck(not layout_problems(fake, 412).is_empty(), "layout_problems 가 폭 5000 컨트롤을 L1 로 잡음")
	fake.queue_free()
	# 증거 검사: 틀린 입력을 같은 함수에 넣어 실패로 판정
	selfcheck(not MissionLogic.ja_evidence_ok(MissionLogic.norm_ja("はい")), "ja_evidence_ok(はい) = false")
	selfcheck(not MissionLogic.ja_evidence_ok(MissionLogic.norm_ja("ーーー")), "ja_evidence_ok(ーーー) = false")
	selfcheck(not MissionLogic.ja_evidence_ok(MissionLogic.norm_ja("。。。!!!")), "ja_evidence_ok(부호만) = false")
	ok(MissionLogic.ja_evidence_ok(MissionLogic.norm_ja("ありがとう")), "ja_evidence_ok(ありがとう) = true (통과 쪽도 확인)")
	# 읽기 줄 검사기: 일본어가 아니거나 읽기가 없으면 아무것도 만들지 않는다
	selfcheck(ReadingLine.make("", "ja", true, 0.0, "") == null, "ReadingLine.make(읽기 없음) = null")
	selfcheck(ReadingLine.make("こんにちは", "en", true, 0.0, "") == null, "ReadingLine.make(영어) = null")
