extends Node
## LessonBuilder (하루 단위 문제 만들기) + "배운 것만 나온다" 전수·속성 시험. 순수 함수 시험(화면·네트워크·사용자 파일 없음).
##   godot --headless --path <project>/godot res://tests/lesson_builder_test.tscn
##   godot --headless --path <project>/godot --resolution 412x915 res://tests/lesson_builder_test.tscn -- --phone
## 사용자 인자(-- 뒤):  --seeds=N (작은 데이터 시드 수, 기본 120)  --bigseeds=N (큰 가상 데이터, 기본 12)
##   --break=guard  가드를 끈다(검사기가 FAIL 해야 정상: 독이 든 데이터에서 위반이 나와야 한다)
##   --break=order  도입 순서 하나를 바꾼다(깨끗한 데이터에서 버려진 문제가 나와 FAIL 해야 정상)
## 종료 코드 0 = 전부 통과. 마지막 줄: "== lesson_builder: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 핵심 줄: "property <이름>: checked N exercises in M units, violations 0, dropped 0"
##
## 위반 판정은 LexiconGuard 와 **따로 짠 oracle**(이 파일의 Oracle 클래스)이 한다: 토큰화도 규칙도 별도 구현이다.

const FIXTURE := "res://tests/fixtures/course_builder/mini.json"
const KINDS := ["new", "listen", "speak", "check", "month", "recap"]
const INF_O := 1000000000
## 독이 든 문장이 정말로 쓸 수 있게 되는 날(o). INF 는 어느 날에도 쓰면 안 된다(수동 낱말을 scope all 에 넣음).
const POISON_TRUE_O := {"s9001": 32, "s9002": 44, "s9003": 1000000000, "s9004": 44, "s9005": 1000000000}

var passed: int = 0
var failed: int = 0
var mini_raw: Dictionary = {}
var seeds_mini: int = 120
var seeds_big: int = 12
var break_guard: bool = false
var break_order: bool = false
var lcg_state: int = 1
var max_print: int = 12


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== lesson_builder start ==")
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s.begins_with("--seeds="):
			seeds_mini = maxi(int(s.substr(8)), 1)
		elif s.begins_with("--bigseeds="):
			seeds_big = maxi(int(s.substr(11)), 1)
		elif s == "--vall":
			max_print = 400
		elif s == "--break=guard":
			break_guard = true
		elif s == "--break=order":
			break_order = true
	var f: FileAccess = FileAccess.open(FIXTURE, FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			mini_raw = parsed
	ok(not mini_raw.is_empty(), "fixture loaded")
	if break_guard:
		LexiconGuard.enabled = false
		print("BREAK guard off (LexiconGuard.enabled = false)")
	_test_composition()
	_test_determinism()
	_test_shapes()
	_test_options_small_weeks()
	_test_input_defense()
	_test_judge()
	_test_poison_drop()
	_test_sources_pure()
	_test_oracle_selfcheck()
	_test_properties()
	LexiconGuard.enabled = true
	print("== lesson_builder: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ 작은 도우미

func _idx(raw: Dictionary) -> Dictionary:
	return LessonBuilder.prepare(raw)


func _build(kind: String, w: int, d: int, seed_value: int, data: Dictionary, seen: Array = []) -> Dictionary:
	return LessonBuilder.build({"kind": kind, "w": w, "d": d, "seen": seen}, data, seed_value)


func _count_type(ex_list: Array, typ: String) -> int:
	var n: int = 0
	for e in ex_list:
		if e["type"] == typ:
			n += 1
	return n


func _count_stage(ex_list: Array, stage: String) -> int:
	var n: int = 0
	for e in ex_list:
		if e.get("stage", "") == stage:
			n += 1
	return n


func _count_part(ex_list: Array, part: String) -> int:
	var n: int = 0
	for e in ex_list:
		if e.get("part", "") == part:
			n += 1
	return n


func _keys_of(ex_list: Array) -> Array:
	var k: Array = []
	for e in ex_list:
		k.append(String(e["type"]) + ":" + String(e.get("item", e.get("sent", e.get("dialogue", e.get("id", ""))))) + ":" + String(e.get("mode", "")))
	return k


func _sorted(a: Array) -> Array:
	var b: Array = a.duplicate()
	b.sort()
	return b


# ------------------------------------------------------------------ E2-6 구성

func _day_entry(w: int, d: int) -> Dictionary:
	for wk in mini_raw["weeks"]:
		if int(wk["w"]) == w:
			for e in wk["days"]:
				if int(e["d"]) == d:
					return e
	return {}


func _test_composition() -> void:
	var data: Dictionary = _idx(mini_raw)
	var stage_order: Array = ["intro", "recognize", "recall", "build", "listen", "speak", "dialogue"]
	var all_ok: bool = true
	var cases: int = 0
	for w in range(1, 5):
		for d in range(1, 5):
			var day: Dictionary = _day_entry(w, d)
			var nw: int = day["words"].size()
			var np: int = day["patterns"].size()
			var r: Dictionary = _build("new", w, d, 11, data)
			cases += 1
			var ex: Array = r["exercises"]
			var good: bool = r["ok"] and r["dropped"] == 0 and r["errors"].is_empty()
			good = good and _count_type(ex, "teach_word") == nw and _count_type(ex, "teach_pattern") == np
			good = good and _count_stage(ex, "recognize") == 2 * nw and _count_stage(ex, "recall") == 2 * nw
			var nb: int = _count_stage(ex, "build")
			good = good and nb >= 1 and nb <= 5 and _count_stage(ex, "listen") == 4 and _count_stage(ex, "speak") == 5
			if d >= 2:
				good = good and nb >= 4
			# 단계 순서가 소개 -> 알아보기 -> 떠올리기 -> 조립 -> 듣기 -> 말하기 (-> D4 대화)
			var last: int = -1
			for e in ex:
				var si: int = stage_order.find(String(e["stage"]))
				if si < last or si < 0:
					good = false
				last = si
			# 떠올리기는 고르기 -> 쓰기 순서
			var seen_type: bool = false
			for e in ex:
				if e["type"] == "recall":
					if e["mode"] == "ko_en_type":
						seen_type = true
					elif seen_type:
						good = false
			ok(good, "E2-6 w%d d%d new unit: intro %d cards, recognize/recall %d each, build %d, listen 4, speak 5, stage order" % [w, d, _count_stage(ex, "intro"), 2 * nw, nb])
			if not good:
				all_ok = false
				print("    composition mismatch at w=%d d=%d: ok=%s dropped=%d errors=%s counts intro=%d rec=%d rcl=%d bld=%d lis=%d spk=%d" % [w, d, str(r["ok"]), r["dropped"], str(r["errors"]), _count_stage(ex, "intro"), _count_stage(ex, "recognize"), _count_stage(ex, "recall"), nb, _count_stage(ex, "listen"), _count_stage(ex, "speak")])
	ok(all_ok, "E2-6 new unit composition for 16 fixture days (%d cases)" % cases)
	var r41: Dictionary = _build("new", 2, 1, 3, data)
	var intro_n: int = _count_stage(r41["exercises"], "intro")
	ok(intro_n >= 7 and intro_n <= 9, "E2-6 intro cards 7..9 on w2 d1 (%d)" % intro_n)
	# 소개 카드는 소리(tts)·뜻·예문을 가진다
	var tw: Dictionary = r41["exercises"][0]
	ok(tw["type"] == "teach_word" and tw["tts"] != "" and tw["ko"] != "" and tw.has("example"), "teach_word has tts, ko and an example")
	# 점검
	var all_chk: bool = true
	for w in range(1, 5):
		var rc: Dictionary = _build("check", w, 6, 5, data)
		var ex2: Array = rc["exercises"]
		var good2: bool = rc["ok"] and ex2.size() == 12 and rc["dropped"] == 0 and rc["warnings"].is_empty()
		good2 = good2 and _count_part(ex2, "listen") == 4 and _count_part(ex2, "write") == 3 and _count_part(ex2, "build") == 2
		good2 = good2 and _count_part(ex2, "speak") == 2 and _count_part(ex2, "dialogue") == 1
		if not good2:
			all_chk = false
			print("    check mismatch w=%d n=%d warnings=%s" % [w, ex2.size(), str(rc["warnings"])])
	ok(all_chk, "E2-6 check unit = 12 (listen 4, write 3, build 2, speak 2, dialogue 1) for w 1..4")
	# 이번 주 70% + 지난 3주 30% (±1문제)
	var ratio_ok: bool = true
	var prev_total: int = 0
	var units: int = 0
	for seed_value in range(20):
		var rc2: Dictionary = _build("check", 4, 6, seed_value, data)
		var prev: int = 0
		for e in rc2["exercises"]:
			if _o_of_exercise(e, data) < 40:
				prev += 1
		prev_total += prev
		units += 1
		if prev < 3 or prev > 5:
			ratio_ok = false
	ok(ratio_ok, "E2-6 check w4: previous-weeks share is 3..5 of 12 in every one of 20 seeds (avg %.1f)" % (float(prev_total) / units))
	var rc1: Dictionary = _build("check", 1, 6, 5, data)
	ok(rc1["exercises"].size() == 12, "check on week 1 still has 12 exercises (no previous weeks)")
	var rm: Dictionary = _build("month", 4, 6, 5, data)
	ok(rm["ok"] and rm["exercises"].size() == 5 and _count_part(rm["exercises"], "ask") == 2 and _count_part(rm["exercises"], "intro") == 1, "month unit: 2 read + 2 ask + 1 intro")
	var rr: Dictionary = _build("recap", 3, 1, 5, data)
	ok(rr["ok"] and rr["exercises"].size() == 6 and rr["dropped"] == 0, "recap unit = 6 exercises")
	var rl: Dictionary = _build("listen", 3, 6, 5, data)
	ok(rl["ok"] and rl["exercises"].size() == 8 and _count_type(rl["exercises"], "listen") == 8, "listen unit = 8 listening exercises")
	var rs: Dictionary = _build("speak", 3, 2, 5, data)
	ok(rs["ok"] and _count_type(rs["exercises"], "speak") == rs["exercises"].size() and rs["exercises"].size() >= 9, "speak unit d2 = repeat + substitute set")
	var rs4: Dictionary = _build("speak", 3, 4, 5, data)
	ok(rs4["ok"] and _count_type(rs4["exercises"], "dialogue_script") == 1, "speak unit d4 w3 (script open) starts with the dialogue")
	ok(rs4["exercises"][0]["type"] == "dialogue_script" and rs4["exercises"][0]["mode"] == "role", "script dialogue is role mode")
	# 소개 카드를 이미 본 낱말은 카드를 다시 보이지 않고 질문은 그대로
	var day22: Dictionary = _day_entry(2, 2)
	var seen_ids: Array = day22["words"].slice(0, 3)
	var rseen: Dictionary = _build("new", 2, 2, 7, data, seen_ids)
	ok(_count_type(rseen["exercises"], "teach_word") == day22["words"].size() - 3 and _count_stage(rseen["exercises"], "recognize") == 2 * day22["words"].size(), "seen words: no card again, still asked")
	var rhalf: Dictionary = LessonBuilder.build({"kind": "new", "w": 2, "d": 2, "half": true}, data, 7)
	ok(_count_type(rhalf["exercises"], "teach_word") == 3, "half: at most 3 new words")
	# 속도
	var rsp: Dictionary = LessonBuilder.build({"kind": "listen", "w": 2, "d": 3, "speed": 0.75}, data, 7)
	ok(rsp["exercises"][0]["speed"] == 0.75, "speed passes through to listening exercises")
	var rsp2: Dictionary = LessonBuilder.build({"kind": "listen", "w": 2, "d": 3, "speed": 9}, data, 7)
	ok(rsp2["exercises"][0]["speed"] == 1.0, "absurd speed falls back to 1.0")
	# 듣기 4 중 Tatoeba 는 최대 1
	var tat_ok: bool = true
	for seed_value in range(30):
		var rt: Dictionary = _build("new", 3, 4, seed_value, data)
		var tat: int = 0
		for e in rt["exercises"]:
			if e["type"] == "listen" and String(data["_idx"]["sents"].get(e.get("sent", ""), {}).get("src", "own")) == "tatoeba":
				tat += 1
		if tat > 1:
			tat_ok = false
	ok(tat_ok, "tatoeba share in the 4 listening items is <= 25%")


## 문제의 o(문장 o 또는 낱말 o) 대략: 점검 비율 확인용.
func _o_of_exercise(e: Dictionary, data: Dictionary) -> int:
	var idx: Dictionary = data["_idx"]
	if e.has("item") and idx["words"].has(e["item"]):
		return int(idx["words"][e["item"]]["o"])
	if e.has("sent") and idx["sents"].has(e["sent"]):
		return int(idx["sents"][e["sent"]]["o"])
	if e.has("dialogue") and idx["dlgs"].has(e["dialogue"]):
		return int(idx["dlgs"][e["dialogue"]]["w"]) * 10
	return 0


# ------------------------------------------------------------------ 문제 모양 (설계 10.4)

func _test_shapes() -> void:
	var data: Dictionary = _idx(mini_raw)
	var rx: RegEx = RegEx.new()
	rx.compile("^x:\\d+:\\d+:(tw|tp|rec|rcl|bld|lis|spk|dlg|chk):")
	var modes_seen: Dictionary = {}
	var pools: Dictionary = {}
	for kind in KINDS:
		pools[kind] = []
		var wd_list: Array = [[1, 4], [2, 2], [2, 4], [3, 4], [4, 4]] if kind == "new" else [[2, 6], [3, 6], [4, 6]]
		for wd in wd_list:
			for sd in range(4):
				var r: Dictionary = _build(kind, wd[0], wd[1], sd, data)
				pools[kind].append_array(r["exercises"])
	for kind in KINDS:
		var ids_ok: bool = true
		var tts_ok: bool = true
		for e in pools[kind]:
			if rx.search(String(e["id"])) == null:
				ids_ok = false
			if e["type"] != "dialogue_script" and String(e.get("tts", "")).strip_edges() == "" and e["type"] != "teach_pattern" and e.get("mode", "") != "intro":
				tts_ok = false
			modes_seen[String(e["type"]) + "/" + String(e.get("mode", ""))] = true
		ok(ids_ok and pools[kind].size() > 0, "shape: %s ids look like x:<w>:<d>:<abbr>:... (%d exercises)" % [kind, pools[kind].size()])
		ok(tts_ok, "shape: %s exercises all carry a tts text" % kind)
	var all: Array = []
	for kind in KINDS:
		all.append_array(pools[kind])
	for m in ["recognize/en_ko", "recognize/hear_ko", "recognize/hear_en", "recall/ko_en_choice", "recall/ko_en_type", "listen/choose_ko", "listen/type", "speak/repeat", "speak/substitute", "dialogue_script/listen", "dialogue_script/role"]:
		ok(modes_seen.has(m), "shape: mode %s is produced" % m)
	var rec_ok: bool = true
	var rcl_ok: bool = true
	var bld_ok: bool = true
	var sub_ok: bool = true
	var dlg_ok: bool = true
	var pat_ok: bool = true
	var tw_ok: bool = true
	for e in all:
		match String(e["type"]):
			"recognize":
				if not (e["option_ids"].size() == e["options"].size() and e["answer"] >= 0 and e["answer"] < e["options"].size() and e["options"].size() >= 2 and e["item"] == e["option_ids"][e["answer"]]):
					rec_ok = false
			"recall":
				if e["mode"] == "ko_en_type":
					if not (e["accept"].size() >= 1 and String(e["hint"]).length() >= 1 and String(e["hint"])[0] == String(e["accept"][0])[0]):
						rcl_ok = false
				elif not (e["options"].size() >= 2 and e["options"][e["answer"]] == e["accept"][0]):
					rcl_ok = false
			"build":
				if not (e["answer"].size() >= 2 and e["extra"].size() <= 2 and e["accept"].has(e["answer"]) and String(e["ko"]) != ""):
					bld_ok = false
			"speak":
				if e["mode"] == "substitute":
					if not (e["cue"].has("slot") and e["cue"].has("with") and e["accept"].size() == 1 and e["accept"][0] != e["target"] and String(e["cue"]["with"]).to_lower() != String(e["cue"]["slot"]).to_lower()):
						sub_ok = false
						print("    substitute shape problem: ", JSON.stringify(e))
			"dialogue_script":
				var you_n: int = 0
				for ln in e["lines"]:
					if ln["you"]:
						you_n += 1
						if not (ln.has("hint_ko") and ln.has("accept")):
							dlg_ok = false
				if e["mode"] == "role" and you_n == 0:
					dlg_ok = false
				if e["mode"] == "listen" and you_n != 0:
					dlg_ok = false
			"teach_pattern":
				if not (String(e["tpl"]) != "" and e["grammar_ko"] is Array and e["examples"].size() <= 3 and String(e["title_ko"]) != ""):
					pat_ok = false
			"teach_word":
				if not (String(e["prompt"]) != "" and String(e["ko"]) != "" and e["item"] != ""):
					tw_ok = false
	ok(rec_ok, "shape: recognize has aligned option_ids, a valid answer index and its own item as the answer")
	ok(rcl_ok, "shape: recall has hint/accept (type) or options whose answer is the English word (choice)")
	ok(bld_ok, "shape: build has >= 2 tiles, <= 2 extra tiles and the answer among accept")
	ok(sub_ok, "shape: substitute cue has slot/with, one accept different from the target, and the new word is not already in the target")
	ok(dlg_ok, "shape: dialogue_script role lines carry hint_ko/accept; listen mode has no user lines")
	ok(pat_ok, "shape: teach_pattern has tpl, title_ko, grammar_ko and <= 3 examples")
	ok(tw_ok, "shape: teach_word has prompt, ko and item")
	var r0: Dictionary = _build("new", 2, 2, 1, data)
	ok(r0.has("ok") and r0.has("exercises") and r0.has("dropped") and r0.has("errors") and r0["cur_o"] == 22, "result has ok/exercises/dropped/errors and cur_o = w*10+d")
	ok(r0["dropped_info"].is_empty() and r0["skipped"] == 0, "clean data: dropped_info empty, nothing skipped")
	var m0: Dictionary = _build("month", 4, 6, 1, data)
	var asks_ok: bool = true
	for e in m0["exercises"]:
		if e.get("part", "") == "ask" and not (e["accept"].size() >= 1 and String(e["prompt_en"]) != ""):
			asks_ok = false
	ok(asks_ok, "shape: month ask questions carry prompt_en and expected phrases")


# ------------------------------------------------------------------ E2-5 결정성

func _test_determinism() -> void:
	var data: Dictionary = _idx(mini_raw)
	var same: bool = true
	for kind in KINDS:
		for wd in [[2, 3], [3, 4], [4, 6], [4, 4]]:
			var a: Dictionary = _build(kind, wd[0], wd[1], 77, data)
			var b: Dictionary = _build(kind, wd[0], wd[1], 77, data)
			if JSON.stringify(a["exercises"]) != JSON.stringify(b["exercises"]) or a["dropped"] != b["dropped"]:
				same = false
	ok(same, "E2-5 same (spec, data, seed) twice -> identical exercise lists (6 kinds x 4 days)")
	# 데이터를 색인하지 않고 raw 로 넘겨도 같은 결과
	var raw_res: Dictionary = _build("new", 3, 4, 77, mini_raw)
	var idx_res: Dictionary = _build("new", 3, 4, 77, data)
	ok(JSON.stringify(raw_res["exercises"]) == JSON.stringify(idx_res["exercises"]), "raw data and indexed data give the same exercises")
	# new: 다른 시드 -> 다른 순서, 같은 항목 집합
	var base: Dictionary = _build("new", 2, 3, 1, data)
	var base_set: Array = _sorted(_keys_of(base["exercises"]))
	var any_order_diff: bool = false
	var sets_same: bool = true
	var base_answers: Dictionary = {}
	for e in base["exercises"]:
		if e["type"] == "build":
			base_answers[e["sent"]] = e["answer"]
	for seed_value in range(2, 14):
		var o: Dictionary = _build("new", 2, 3, seed_value, data)
		if _sorted(_keys_of(o["exercises"])) != base_set:
			sets_same = false
		if _keys_of(o["exercises"]) != _keys_of(base["exercises"]):
			any_order_diff = true
		for e in o["exercises"]:
			if e["type"] == "build" and base_answers.has(e["sent"]) and base_answers[e["sent"]] != e["answer"]:
				sets_same = false
	ok(sets_same, "E2-5 new unit: every seed asks the same items and answers (12 seeds)")
	ok(any_order_diff, "E2-5 new unit: different seeds give a different order")
	var opt_diff: bool = false
	var first_rec: Dictionary = {}
	for e in base["exercises"]:
		if e["type"] == "recognize":
			first_rec[e["id"]] = e["options"]
	for seed_value in range(2, 8):
		var o2: Dictionary = _build("new", 2, 3, seed_value, data)
		for e in o2["exercises"]:
			if e["type"] == "recognize" and first_rec.has(e["id"]) and first_rec[e["id"]] != e["options"]:
				opt_diff = true
	ok(opt_diff, "E2-5 different seeds give different wrong options")
	# check: 새 문제로 다시 점검(시드가 다르면 항목이 달라진다)
	var c1: Array = _sorted(_keys_of(_build("check", 4, 6, 1, data)["exercises"]))
	var diff_check: bool = false
	for seed_value in range(2, 10):
		if _sorted(_keys_of(_build("check", 4, 6, seed_value, data)["exercises"])) != c1:
			diff_check = true
	ok(diff_check, "check unit: another seed gives other questions (a retake)")


# ------------------------------------------------------------------ E2-7 1~2주 보기 수

func _test_options_small_weeks() -> void:
	var data: Dictionary = _idx(mini_raw)
	var min_opts: int = 99
	var max_opts: int = 0
	var shrunk: bool = false
	var bad_future: int = 0
	for w in range(1, 3):
		for d in range(1, 5):
			for seed_value in range(10):
				var r: Dictionary = _build("new", w, d, seed_value, data)
				for e in r["exercises"]:
					if e.has("options"):
						min_opts = mini(min_opts, e["options"].size())
						max_opts = maxi(max_opts, e["options"].size())
						if e["options"].size() < 4:
							shrunk = true
						for id in e.get("option_ids", []):
							if data["_idx"]["word_o"].has(id) and data["_idx"]["word_o"][id] > w * 10 + d:
								bad_future += 1
	ok(min_opts >= 2, "E2-7 every question on weeks 1-2 has >= 2 options (min %d)" % min_opts)
	ok(max_opts <= 4, "options never exceed 4 (max %d)" % max_opts)
	ok(bad_future == 0, "E2-7 no option is a word of a later day (weeks 1-2, 80 units)")
	# 낱말이 두 개뿐인 하루: 보기 2개로 줄고 안 배운 낱말로 채우지 않는다
	var tiny: Dictionary = {
		"weeks": [{"w": 1, "days": [{"d": 1, "kind": "new", "words": ["a", "b"], "patterns": []}]}],
		"words": [
			{"id": "a", "en": "apple", "pos": "n", "ko": "사과", "o": 11, "role": "active"},
			{"id": "b", "en": "bread", "pos": "n", "ko": "빵", "o": 11, "role": "active"},
			{"id": "z", "en": "zebra", "pos": "n", "ko": "얼룩말", "o": 99, "role": "active"},
		],
		"sentences": [], "patterns": [], "dialogues": [],
	}
	var rt: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, tiny, 4)
	var two_ok: bool = rt["ok"] and rt["dropped"] == 0
	var saw_zebra: bool = false
	for e in rt["exercises"]:
		if e.has("options"):
			if e["options"].size() != 2:
				two_ok = false
			for o in e["options"]:
				if o == "얼룩말" or o == "zebra":
					saw_zebra = true
	ok(two_ok and not saw_zebra, "E2-7 two learned words -> 2 options, the unlearned word is never used as filler")
	var one: Dictionary = {
		"weeks": [{"w": 1, "days": [{"d": 1, "kind": "new", "words": ["a"], "patterns": []}]}],
		"words": [{"id": "a", "en": "apple", "pos": "n", "ko": "사과", "o": 11, "role": "active"}, {"id": "z", "en": "zebra", "pos": "n", "ko": "얼룩말", "o": 99, "role": "active"}],
		"sentences": [], "patterns": [], "dialogues": [],
	}
	var r1: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, one, 4)
	var has_q: bool = false
	for e in r1["exercises"]:
		if e.has("options"):
			has_q = true
	ok(not has_q and r1["skipped"] > 0 and _count_type(r1["exercises"], "teach_word") == 1, "E2-7 a single learned word cannot make a question (skipped, nothing invented)")


# ------------------------------------------------------------------ E2-8 입력 방어

func _test_input_defense() -> void:
	var data: Dictionary = _idx(mini_raw)
	var bad_specs: Array = [null, "x", 5, [], {}, {"kind": "new"}, {"kind": "new", "w": 0, "d": 1}, {"kind": "new", "w": 73, "d": 1}, {"kind": "new", "w": -1, "d": 1}, {"kind": "new", "w": "x", "d": 1},
		{"kind": "new", "w": 1.5, "d": 1}, {"kind": "new", "w": 1, "d": 0}, {"kind": "new", "w": 1, "d": 8}, {"kind": "nope", "w": 1, "d": 1}, {"kind": 5, "w": 1, "d": 1}, {"kind": "new", "w": null, "d": null},
		{"kind": "new", "w": NAN, "d": 1}]
	var all_safe: bool = true
	for sp in bad_specs:
		var r: Dictionary = LessonBuilder.build(sp, data, 1)
		if r["ok"] or r["errors"].is_empty() or not (r["exercises"] is Array) or not r["exercises"].is_empty():
			all_safe = false
			print("    bad spec not rejected: ", var_to_str(sp), " -> ", r["errors"])
	ok(all_safe, "E2-8 %d broken specs -> ok=false, an errors line, no exercises, no script error" % bad_specs.size())
	var bad_data: Array = [null, {}, {"words": []}, {"words": [], "sentences": []}, [], "x", 5, {"words": "x"}, {"words": {"a": 1}}]
	var data_safe: bool = true
	for bd in bad_data:
		var r2: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, bd, 1)
		if r2["ok"] or r2["errors"].is_empty():
			data_safe = false
			print("    bad data not rejected: ", var_to_str(bd))
	ok(data_safe, "E2-8 %d empty/broken data values -> ok=false with an errors line" % bad_data.size())
	# seen 이 이상해도 에러 없이 동작
	var seen_safe: bool = true
	for sv in [null, "x", 5, [1, 2, null], {"a": 1}, ["nope", "w0001"]]:
		var r3: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1, "seen": sv}, data, 1)
		if not r3["ok"]:
			seen_safe = false
	ok(seen_safe, "E2-8 odd `seen` values (null, string, numbers, unknown ids) are ignored")
	# 범위 밖 주(데이터에 없는 주): new 는 week_missing, 나머지는 문제를 만들거나 안전하게 실패
	var r4: Dictionary = _build("new", 40, 2, 1, data)
	ok(not r4["ok"] and r4["errors"].has("week_missing"), "week not in data -> week_missing (new)")
	var r5: Dictionary = _build("listen", 72, 7, 1, data)
	ok(r5["ok"] and r5["exercises"].size() == 8, "week 72 (beyond the data) listening unit uses everything learned so far, no error")
	# 순서가 겹치는 데이터: 같은 o 가 많고 id 가 겹침, o 없음
	var dup: Dictionary = mini_raw.duplicate(true)
	for wd in dup["words"]:
		wd["o"] = 11
	for s in dup["sentences"]:
		s["o"] = 11
	var rd: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, dup, 1)
	ok(rd["ok"] or not rd["errors"].is_empty(), "E2-8 overlapping order numbers (everything o=11) -> no script error")
	var rd2: Dictionary = LessonBuilder.build({"kind": "check", "w": 1, "d": 6}, dup, 1)
	ok(rd2["ok"] or not rd2["errors"].is_empty(), "E2-8 overlapping order numbers, check unit -> no script error")
	var noo: Dictionary = mini_raw.duplicate(true)
	for wd in noo["words"]:
		wd.erase("o")
	var rn: Dictionary = LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, noo, 1)
	ok(rn["ok"] == false, "E2-8 words without o are never learned -> nothing is asked (ok=false)")
	var idless: Dictionary = {"weeks": [{"w": 1, "days": [{"d": 1, "words": ["a"]}]}], "words": [{"en": "x"}, 5, null], "sentences": [1, 2], "patterns": [], "dialogues": []}
	ok(not LessonBuilder.build({"kind": "new", "w": 1, "d": 1}, idless, 1)["ok"], "E2-8 words without ids -> ok=false")
	# 큰 데이터 시간 (한 단위 100 ms 이하: PC, 색인을 한 번 만든 데이터)
	var big: Dictionary = _gen_big(5000, 72, 3000)
	var t0: int = Time.get_ticks_usec()
	var big_idx: Dictionary = LessonBuilder.prepare(big)
	var t_index: float = (Time.get_ticks_usec() - t0) / 1000.0
	var worst: float = 0.0
	for kind in KINDS:
		for wd in [[36, 3], [72, 4], [8, 6]]:
			var t1: int = Time.get_ticks_usec()
			var rb: Dictionary = _build(kind, wd[0], wd[1], 3, big_idx)
			var ms: float = (Time.get_ticks_usec() - t1) / 1000.0
			worst = maxf(worst, ms)
			print("timing: %s w%d d%d %.1f ms (%d exercises)" % [kind, wd[0], wd[1], ms, rb["exercises"].size()])
			if kind == "new" and wd[1] != 6:
				ok(rb["ok"], "5,000-word data: %s unit w%d d%d builds ok (%.1f ms)" % [kind, wd[0], wd[1], ms])
	print("timing: 5000 words/3000 sentences: index %.1f ms, slowest unit %.1f ms" % [t_index, worst])
	ok(worst <= 100.0, "E2-8 5,000-word data: one unit <= 100 ms with an indexed data (worst %.1f ms)" % worst)
	var t2: int = Time.get_ticks_usec()
	var rraw: Dictionary = _build("new", 36, 3, 3, big)
	print("timing: one unit including indexing the raw data: %.1f ms" % ((Time.get_ticks_usec() - t2) / 1000.0))
	ok(rraw["ok"], "raw (not indexed) 5,000-word data builds too")


# ------------------------------------------------------------------ E2-9 정답 판정 표 (>= 25행)

func _test_judge() -> void:
	var rec: Dictionary = {"type": "recognize", "mode": "en_ko", "answer": 2, "options": ["a", "b", "c"]}
	var bld: Dictionary = {"type": "build", "answer": ["I", "like", "apples"], "accept": [["I", "like", "apples"], ["I", "do", "like", "apples"]]}
	var rcl: Dictionary = {"type": "recall", "mode": "ko_en_type", "accept": ["color", "colour"]}
	var lty: Dictionary = {"type": "listen", "mode": "type", "accept": ["I like apples."]}
	var spk: Dictionary = {"type": "speak", "mode": "repeat", "target": "I like apples.", "accept": []}
	var sub: Dictionary = {"type": "speak", "mode": "substitute", "target": "I like apples.", "accept": ["I like tea."]}
	var lch: Dictionary = {"type": "listen", "mode": "choose_ko", "answer": 0, "options": ["a", "b"]}
	var rch: Dictionary = {"type": "recall", "mode": "ko_en_choice", "answer": 1, "options": ["a", "b"]}
	# [ex, answer, 기대 ok, 기대 near, 설명]
	var rows: Array = [
		[rec, 2, true, false, "choice: right index"],
		[rec, 1, false, false, "choice: wrong index"],
		[rec, 2.0, true, false, "choice: float index"],
		[rec, "2", false, false, "choice: string is not an index"],
		[rec, null, false, false, "choice: null"],
		[lch, 0, true, false, "listen choose right"],
		[rch, 1, true, false, "recall choice right"],
		[bld, ["I", "like", "apples"], true, false, "build exact"],
		[bld, ["i", "LIKE", "Apples"], true, false, "build ignores case"],
		[bld, ["I", "like", "apples."], true, false, "build ignores end punctuation on a tile"],
		[bld, "  i like apples.  ", true, false, "build string with spaces and end punctuation"],
		[bld, ["I", "do", "like", "apples"], true, false, "build alternative accepted order"],
		[bld, ["like", "I", "apples"], false, false, "build wrong order"],
		[bld, ["I", "like"], false, false, "build missing tile"],
		[bld, ["I", "like", "apples", "tea"], false, false, "build extra tile"],
		[bld, [], false, false, "build empty answer"],
		[bld, 5, false, false, "build wrong type"],
		[rcl, "color", true, false, "recall exact"],
		[rcl, "Colour", true, false, "recall alt spelling + case"],
		[rcl, "  colour. ", true, false, "recall spaces and end punctuation"],
		[rcl, "colr", false, true, "recall one letter missing is near"],
		[rcl, "colur", false, true, "recall one letter wrong is near"],
		[rcl, "colour", true, false, "recall colour is correct, not just near"],
		[rcl, "clor", false, true, "recall transposition is near"],
		[rcl, "colxxr", false, false, "recall two letters off is wrong"],
		[rcl, "", false, false, "recall empty"],
		[rcl, 5, false, false, "recall wrong type"],
		[{"type": "recall", "mode": "ko_en_type", "accept": ["cat"]}, "cap", false, false, "short word: one letter off is not near"],
		[lty, "i like apples", true, false, "listen type ignores case and the final period"],
		[lty, "I like apple", false, true, "listen type one letter off is near"],
		[spk, "I like apples", true, false, "speak repeat compares to target"],
		[sub, "I like tea.", true, false, "speak substitute accepts the new sentence"],
		[sub, "I like apples.", false, false, "speak substitute does not accept the old sentence"],
		[null, 1, false, false, "ex null"],
		[{}, 1, false, false, "ex empty"],
		[{"type": "speak"}, 5, false, false, "speak without accept and a number answer"],
		[{"type": "teach_word"}, 0, false, false, "teach cards are never judged"],
	]
	var bad: int = 0
	for r in rows:
		var res: Dictionary = LessonBuilder.judge(r[0], r[1])
		if res["ok"] != r[2] or res["near"] != r[3]:
			bad += 1
			print("    judge row mismatch: ", r[4], " got ", res)
	ok(rows.size() >= 25, "E2-9 judge table has >= 25 rows (%d)" % rows.size())
	ok(bad == 0, "E2-9 all judge rows match (%d bad)" % bad)
	ok(LessonBuilder.norm_answer("  Hello,  WORLD!! ") == "hello, world", "norm_answer: case, spaces, end punctuation")
	ok(LessonBuilder.norm_answer("It’s") == "it's" and LessonBuilder.norm_answer(null) == "", "norm_answer: curly apostrophe, null")
	# 만든 문제는 자기 정답을 맞다고 판정한다(만든 쪽과 채점이 어긋나지 않는다)
	var data: Dictionary = _idx(mini_raw)
	var inconsistent: int = 0
	var n: int = 0
	for w in range(1, 5):
		for d in range(1, 5):
			for e in _build("new", w, d, 5, data)["exercises"]:
				n += 1
				if not _self_judges(e):
					inconsistent += 1
					print("    self-judge failed: ", e["id"])
	ok(inconsistent == 0, "every built exercise judges its own correct answer as ok (%d checked)" % n)


func _self_judge_answer(e: Dictionary) -> Variant:
	var typ: String = e["type"]
	match typ:
		"recognize":
			return e["answer"]
		"build":
			return e["answer"]
		"recall":
			return e["answer"] if e["mode"] == "ko_en_choice" else e["accept"][0]
		"listen":
			return e["answer"] if e["mode"] == "choose_ko" else e["accept"][0]
		"speak":
			return e["accept"][0] if e["mode"] != "repeat" else e["target"]
	return null


func _self_judges(e: Dictionary) -> bool:
	if e["type"] in ["teach_word", "teach_pattern", "dialogue_script"]:
		return true
	var a: Variant = _self_judge_answer(e)
	var r: Dictionary = LessonBuilder.judge(e, a)
	if not r["ok"]:
		return false
	# 오답 하나를 넣으면 틀린 것으로 판정되는지(고르기)
	if e["type"] in ["recognize", "listen"] and e.get("mode", "") != "type":
		if e.has("options"):
			var wrong: int = (int(e["answer"]) + 1) % e["options"].size()
			return not LessonBuilder.judge(e, wrong)["ok"]
	return true


# ------------------------------------------------------------------ E2-4 (a) 독이 든 데이터

func _poison(raw: Dictionary) -> Dictionary:
	var p: Dictionary = raw.duplicate(true)
	# P1: 일 11 인 척하지만 31·32 낱말이 든 문장
	p["sentences"].append({"id": "s9001", "en": "I work at the store.", "ko": "독 1", "say": "", "words": [], "pat": "", "o": 11, "scope": "all", "accept": [], "src": "own", "tid": 0})
	# P2: worked 는 44 인데 21 로 선언
	p["sentences"].append({"id": "s9002", "en": "I worked at the store.", "ko": "독 2", "say": "", "words": [], "pat": "", "o": 21, "scope": "all", "accept": [], "src": "own", "tid": 0})
	# P3: 수동 낱말이 든 문장을 scope all 로 선언(o 도 낮게)
	p["sentences"].append({"id": "s9003", "en": "Here is your receipt.", "ko": "독 3", "say": "", "words": [], "pat": "", "o": 11, "scope": "all", "accept": [], "src": "own", "tid": 0})
	p["sentences"].append({"id": "s9004", "en": "Where is the bus.", "ko": "독 4", "say": "", "words": [], "pat": "", "o": 21, "scope": "listen", "accept": [], "src": "own", "tid": 0})
	p["sentences"].append({"id": "s9005", "en": "It is $9.99.", "ko": "독 5", "say": "It is nine ninety-nine and cash.", "words": [], "pat": "", "o": 21, "scope": "all", "accept": [], "src": "own", "tid": 0})
	# P4: 1주 대화에 4주 줄(o 는 11 이라고 적음)
	for dl in p["dialogues"]:
		if dl["id"] == "d0001":
			dl["lines"].append({"s": "B", "en": "Where is the bus?", "ko": "독 6", "say": "", "words": [], "o": 11})
	# P5: 1주 1일 낱말 하나의 o 를 99 로 올림(소개 카드가 나오면 안 된다)
	for wd in p["words"]:
		if wd["en"] == "thanks":
			wd["o"] = 99
	return p


func _test_poison_drop() -> void:
	var p: Dictionary = _idx(_poison(mini_raw))
	var r: Dictionary = _build("new", 1, 1, 3, p)
	var leaked: bool = false
	for e in r["exercises"]:
		if e.get("sent", "") == "s9001" or e.get("sent", "") == "s9003" or e.get("item", "") == "w0005":
			leaked = true
	print("selfcheck FAIL-as-expected poisoned-sentence: dropped=", r["dropped"], " leaked=", leaked)
	ok(not leaked and r["dropped"] >= 1, "E2-4 (a) a sentence with a future word is never asked and is counted in dropped")
	var thanks_card: bool = false
	for e in r["exercises"]:
		if e["type"] == "teach_word" and e["item"] == "w0005":
			thanks_card = true
	ok(not thanks_card, "E2-4 a word whose o was raised to 99 gets no intro card and no question")
	var r2: Dictionary = _build("new", 1, 4, 3, p)
	var dlg_leak: bool = false
	for e in r2["exercises"]:
		if e["type"] == "dialogue_script":
			dlg_leak = true
	print("selfcheck FAIL-as-expected poisoned-dialogue: dropped=", r2["dropped"], " dialogue_shown=", dlg_leak)
	ok(not dlg_leak and r2["dropped"] >= 1, "E2-4 a dialogue with a future line is dropped and counted")
	var r3: Dictionary = _build("check", 3, 6, 3, p)
	var leak3: bool = false
	for e in r3["exercises"]:
		if String(e.get("sent", "")).begins_with("s900"):
			leak3 = true
	ok(not leak3, "E2-4 poisoned sentences never reach a check unit")
	ok(r["dropped_info"].size() >= 1 and r["dropped_info"][0].has("id") and r["dropped_info"][0].has("bad"), "dropped_info says which exercise and why")


# ------------------------------------------------------------------ E2-11 순수성

func _test_sources_pure() -> void:
	for path in ["res://scripts/core/lesson_builder.gd", "res://scripts/core/lexicon_guard.gd"]:
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		var text: String = f.get_as_text() if f != null else "?"
		var bad: Array = []
		for w in ["File" + "Access", "Course" + "Data", "Course" + "Store", "rand" + "i()", "rand" + "f()", "HTTP" + "Request", "shell_" + "open", "877" + "0", "877" + "5", "877" + "6", "Dir" + "Access", "user:" + "//"]:
			if text.contains(w):
				bad.append(w)
		ok(bad.is_empty(), "E2-11 %s has no I/O, loader, global random or server port (%s)" % [path.get_file(), str(bad)])
		ok(not text.contains("Color(\"#"), "%s has no Color(\"#...\")" % path.get_file())


# ------------------------------------------------------------------ oracle (LexiconGuard 와 따로 짠 판정기)

class Oracle:
	extends RefCounted
	var words: Dictionary = {}
	var sents: Dictionary = {}
	var dlgs: Dictionary = {}
	var tok_active: Dictionary = {}
	var tok_passive: Dictionary = {}
	var violations: Array = []

	func _init(raw: Dictionary) -> void:
		var pats: Dictionary = {}
		for p in raw.get("patterns", []):
			pats[p["id"]] = int(p["o"])
		for w in raw.get("words", []):
			if not (w is Dictionary and w.has("id")):
				continue
			words[w["id"]] = w
			var o: int = int(w["o"]) if w.has("o") and (w["o"] is int or w["o"] is float) else INF_O
			var pas: bool = String(w.get("role", "active")) == "passive"
			_reg(String(w["en"]), o, pas)
			for fm in w.get("forms", []):
				var po: int = 0
				if String(fm.get("pat", "")) != "":
					po = pats.get(fm["pat"], INF_O)
				_reg(String(fm["f"]), maxi(o, po), pas)
			for a in w.get("alt", []):
				_reg(String(a), o, pas)
		for s in raw.get("sentences", []):
			sents[s["id"]] = s
		for d in raw.get("dialogues", []):
			dlgs[d["id"]] = d

	func _reg(text: String, o: int, pas: bool) -> void:
		for t in tk(text):
			var dst: Dictionary = tok_passive if pas else tok_active
			dst[t] = mini(int(dst.get(t, INF_O)), o)

	static func tk(s: String) -> Array:
		var t: String = s.to_lower().replace("’", "'")
		var out: Array = []
		var cur: String = ""
		for i in t.length():
			var c: String = t[i]
			var u: int = t.unicode_at(i)
			if (u >= 97 and u <= 122) or (u >= 48 and u <= 57) or c == "'" or u > 127:
				cur += c
			else:
				if cur != "":
					out.append(cur)
				cur = ""
		if cur != "":
			out.append(cur)
		var fin: Array = []
		for x in out:
			var y: String = x.lstrip("'").rstrip("'")
			if y != "":
				fin.append(y)
		return fin

	func v(msg: String) -> void:
		violations.append(msg)

	func txt(text: String, cur: int, allow_passive: bool, where: String) -> void:
		for t in tk(text):
			var a: int = int(tok_active.get(t, INF_O))
			var p: int = int(tok_passive.get(t, INF_O))
			if allow_passive:
				if mini(a, p) > cur:
					v("%s: token '%s' not learned at %d" % [where, t, cur])
			elif a > cur:
				v("%s: token '%s' not learned (or passive) at %d" % [where, t, cur])

	func item(id: String, cur: int, seen: Dictionary, where: String) -> void:
		if not words.has(id):
			v("%s: unknown word %s" % [where, id])
			return
		var w: Dictionary = words[id]
		var o: int = int(w["o"]) if w.has("o") and (w["o"] is int or w["o"] is float) else INF_O
		if o > cur:
			v("%s: word %s (o %d) later than %d" % [where, id, o, cur])
		if String(w.get("role", "active")) != "active":
			v("%s: passive word %s used" % [where, id])
		if o >= cur and not seen.has(id):
			v("%s: word %s asked before its card" % [where, id])

	func sent(id: String, cur: int, general_only: bool, where: String) -> void:
		if id.contains("#"):
			var parts: PackedStringArray = id.split("#")
			var dl: Dictionary = dlgs.get(parts[0], {})
			var lines: Array = dl.get("lines", [])
			var i: int = int(parts[1])
			if i < 0 or i >= lines.size():
				v("%s: unknown dialogue line %s" % [where, id])
				return
			if int(lines[i]["o"]) > cur:
				v("%s: dialogue line %s (o %d) later than %d" % [where, id, int(lines[i]["o"]), cur])
			txt(String(lines[i]["en"]), cur, true, where + "/" + id)
			return
		if not sents.has(id):
			v("%s: unknown sentence %s" % [where, id])
			return
		var s: Dictionary = sents[id]
		var o: int = int(s["o"]) if s.has("o") and (s["o"] is int or s["o"] is float) else INF_O
		if o > cur:
			v("%s: sentence %s (o %d) later than %d" % [where, id, o, cur])
		if general_only and String(s.get("scope", "all")) not in ["all", ""]:
			v("%s: scope listen sentence %s used outside listening" % [where, id])
		txt(String(s.get("en", "")) if String(s.get("say", "")) == "" else String(s["say"]), cur, String(s.get("scope", "all")) == "listen" and not general_only, where + "/" + id)

	func opts(ex: Dictionary, cur: int, seen: Dictionary, lang: String) -> void:
		var o: Variant = ex.get("options")
		var ids: Variant = ex.get("option_ids")
		if not (o is Array) or o.size() < 2:
			v("options fewer than 2 in %s" % ex.get("id", "?"))
			return
		if not (ids is Array) or ids.size() != o.size():
			v("option_ids missing/misaligned in %s" % ex.get("id", "?"))
			return
		var ans: int = int(ex.get("answer", -1))
		if ans < 0 or ans >= o.size():
			v("answer out of range in %s" % ex.get("id", "?"))
			return
		for j in o.size():
			if lang == "sent":
				sent(String(ids[j]), cur, false, "option")
			else:
				item(String(ids[j]), cur, seen, "option")
				if lang == "en":
					txt(String(o[j]), cur, false, "option text")
				if j != ans and words.has(String(ids[j])) and words.has(String(ids[ans])):
					var wa: Dictionary = words[String(ids[ans])]
					var wj: Dictionary = words[String(ids[j])]
					if String(wa["ko"]) == String(wj["ko"]) or wa.get("syn", []).has(wj["id"]) or wj.get("syn", []).has(wa["id"]):
						v("option %s means the same as the answer %s" % [wj["id"], wa["id"]])
			for k in range(j + 1, o.size()):
				if String(o[j]) == String(o[k]):
					v("duplicate option text %s" % String(o[j]))

	## 한 단위의 문제 목록을 검사해 위반 문자열 목록을 돌려준다.
	func unit(exs: Array, cur: int, seen_start: Array) -> Array:
		violations = []
		var seen: Dictionary = {}
		for s in seen_start:
			seen[s] = true
		var ids: Dictionary = {}
		for ex in exs:
			var id: String = String(ex.get("id", ""))
			if ids.has(id):
				v("duplicate id " + id)
			ids[id] = true
			var typ: String = String(ex.get("type", ""))
			var listenish: bool = typ == "listen" or typ == "dialogue_script"
			if ex.has("tts"):
				txt(String(ex["tts"]), cur, listenish, "tts")
			match typ:
				"teach_word":
					var wid: String = String(ex.get("item", ""))
					if words.has(wid):
						var w: Dictionary = words[wid]
						if int(w["o"]) > cur or String(w.get("role", "active")) != "active":
							v("card for word %s not allowed at %d" % [wid, cur])
					else:
						v("card for unknown word")
					txt(String(ex.get("prompt", "")), cur, false, "card prompt")
					if ex.get("example") is Dictionary:
						sent(String(ex["example"].get("sent", "")), cur, true, "card example")
					seen[wid] = true
				"teach_pattern":
					for e in ex.get("examples", []):
						sent(String(e.get("sent", "")), cur, true, "pattern example")
				"recognize":
					item(String(ex.get("item", "")), cur, seen, "recognize item")
					opts(ex, cur, seen, "en" if ex.get("mode", "") == "hear_en" else "ko")
					if ex.get("mode", "") == "en_ko":
						txt(String(ex.get("prompt", "")), cur, false, "prompt")
				"recall":
					item(String(ex.get("item", "")), cur, seen, "recall item")
					for a in ex.get("accept", []):
						txt(String(a), cur, false, "accept")
					if ex.get("mode", "") == "ko_en_choice":
						opts(ex, cur, seen, "en")
				"build":
					var sid: String = String(ex.get("sent", ""))
					sent(sid, cur, true, "build sentence")
					var has_say: bool = sents.has(sid) and String(sents[sid].get("say", "")) != ""
					if not has_say:
						txt(" ".join(PackedStringArray(ex.get("answer", []))), cur, false, "answer tiles")
					var answer_tokens: Dictionary = {}
					for t in tk(" ".join(PackedStringArray(ex.get("answer", [])))):
						answer_tokens[t] = true
					for x in ex.get("extra", []):
						txt(String(x), cur, false, "extra tile")
						for t in tk(String(x)):
							if answer_tokens.has(t):
								v("extra tile %s duplicates an answer tile" % String(x))
					if ex.get("extra", []).size() > 2:
						v("more than 2 extra tiles")
					for acc in ex.get("accept", []):
						if not has_say:
							txt(" ".join(PackedStringArray(acc)), cur, false, "accept")
				"listen":
					var sid2: String = String(ex.get("sent", ""))
					if sid2 != "":
						sent(sid2, cur, false, "listen sentence")
					elif not ex.has("dialogue"):
						v("listen without sent")
					if ex.get("mode", "") == "choose_ko":
						opts(ex, cur, seen, "sent")
					else:
						for a in ex.get("accept", []):
							txt(String(a), cur, true, "accept")
				"speak":
					var sid3: String = String(ex.get("sent", ""))
					if sid3 != "":
						sent(sid3, cur, true, "speak sentence")
					if ex.has("prompt_en"):
						txt(String(ex["prompt_en"]), cur, false, "prompt_en")
					for a in ex.get("accept", []):
						txt(String(a), cur, false, "accept")
					if ex.get("cue") is Dictionary:
						txt(String(ex["cue"].get("with", "")), cur, false, "cue")
				"dialogue_script":
					for ln in ex.get("lines", []):
						txt(String(ln.get("en", "")), cur, true, "dialogue line")
					var dl: Dictionary = dlgs.get(ex.get("dialogue", ""), {})
					for ln2 in dl.get("lines", []):
						if int(ln2["o"]) > cur:
							v("dialogue line with o %d at %d" % [int(ln2["o"]), cur])
				_:
					v("unknown exercise type " + typ)
		return violations


func _test_oracle_selfcheck() -> void:
	var orc: Oracle = Oracle.new(mini_raw)
	var bad_list: Array = [
		["future option", {"type": "recognize", "id": "x", "mode": "en_ko", "item": "w0003", "prompt": "yes", "tts": "yes", "options": ["네", "좋아하다"], "option_ids": ["w0003", "w0036"], "answer": 0}, 11],
		["unseen item", {"type": "recall", "id": "x", "mode": "ko_en_type", "item": "w0003", "accept": ["yes"], "tts": "yes"}, 11],
		["passive tile", {"type": "build", "id": "x", "sent": "s0001", "answer": ["Hello", "cash"], "extra": [], "accept": [], "tts": "Hello"}, 41],
		["future tts", {"type": "listen", "id": "x", "mode": "type", "sent": "s0001", "tts": "I work at the store", "accept": []}, 11],
		["too many extra tiles", {"type": "build", "id": "x", "sent": "s0001", "answer": ["Yes", "please"], "extra": ["hello", "hi", "no"], "accept": [], "tts": "Yes, please."}, 11],
	]
	var all_flagged: bool = true
	for b in bad_list:
		var v: Array = orc.unit([b[1]], b[2], [])
		print("selfcheck FAIL-as-expected oracle(", b[0], "): violations=", v.size())
		if v.is_empty():
			all_flagged = false
	ok(all_flagged, "oracle selfcheck: 5 deliberately wrong exercises are all flagged")
	var good: Dictionary = _build("new", 2, 2, 3, _idx(mini_raw))
	ok(orc.unit(good["exercises"], 22, []).is_empty(), "oracle accepts a real unit (w2 d2)")


# ------------------------------------------------------------------ 큰 가상 데이터

func _rnd(n: int) -> int:
	lcg_state = (lcg_state * 1103515245 + 12345) & 0x7fffffff
	return (lcg_state >> 8) % n


func _syll(i: int) -> String:
	var cons: String = "bdfgklmnprstvz"
	var vow: String = "aeiou"
	var c: int = i % 14
	var v: int = (i / 14) % 5
	return cons[c] + vow[v]


func _word_en(i: int) -> String:
	return "q" + _syll(i % 70) + _syll((i / 70) % 70) + _syll((i / 4900) % 70)


## 가상 데이터: 낱말 n_words(그 중 주당 1개는 수동), 주 n_weeks(1~4일에 새 낱말), 문장 n_sents 개.
func _gen_big(n_words: int, n_weeks: int, n_sents: int) -> Dictionary:
	lcg_state = 4242
	var words: Array = []
	var weeks: Array = []
	var patterns: Array = [{"id": "pp", "tpl": "", "slots": [], "o": 14, "examples": []}]
	var per_day: int = maxi((n_words - n_weeks) / (n_weeks * 4), 1)
	var wid_n: int = 0
	var pass_n: int = 0
	var active_by_o: Array = []
	var passive_all: Array = []
	for w in range(1, n_weeks + 1):
		var days: Array = []
		var pat_w: Dictionary = {"id": "p%d" % w, "tpl": "", "slots": [{"name": "x", "pos": ["n"]}], "title_ko": "문형", "grammar_ko": ["설명"], "o": w * 10 + 1, "examples": []}
		patterns.append(pat_w)
		for d in range(1, 5):
			var ids: Array = []
			for k in range(per_day):
				wid_n += 1
				var id: String = "w%04d" % wid_n
				var pos: String = ["n", "n", "v", "adj", "adv"][wid_n % 5]
				var ko: String = "뜻%d" % wid_n
				var syn: Array = []
				if wid_n % 25 == 0 and words.size() > 0:
					ko = String(words[words.size() - 1]["ko"])
				var rec: Dictionary = {"id": id, "en": _word_en(wid_n), "pos": pos, "ko": ko, "ipa": "", "say": "", "tags": (["t%d" % (wid_n % 3)] if pos == "n" else []), "role": "active",
					"o": w * 10 + d, "forms": [], "alt": [], "syn": syn, "ca": false, "src": "own"}
				if wid_n % 10 == 0:
					rec["forms"].append({"f": String(rec["en"]) + "s", "pat": "pp"})
				words.append(rec)
				ids.append(id)
				active_by_o.append(rec)
				if d == 1 and k == 0:
					pat_w["tpl"] = String(rec["en"]) + " ___."
			days.append({"d": d, "kind": "new", "words": ids, "patterns": (["p%d" % w] if d == 1 else [])})
		days.append({"d": 5, "kind": "speak", "words": [], "patterns": []})
		days.append({"d": 6, "kind": "check", "words": [], "patterns": []})
		days.append({"d": 7, "kind": "free", "words": [], "patterns": []})
		pass_n += 1
		var prec: Dictionary = {"id": "x%04d" % pass_n, "en": _word_en(9000 + pass_n), "pos": "n", "ko": "수동%d" % pass_n, "ipa": "", "say": "", "tags": [], "role": "passive",
			"o": w * 10 + 3, "forms": [], "alt": [], "syn": [], "ca": false, "src": "own"}
		words.append(prec)
		passive_all.append(prec)
		weeks.append({"w": w, "n": 1, "k": w, "stage": 1, "legacy_stage": 1, "title_ko": "주 %d" % w, "words": {"new": [], "passive": [prec["id"]]}, "patterns": ["p%d" % w],
			"dialogue": "d%04d" % w, "ladder": {"repeat": true, "substitute": w >= 2, "script": w >= 3, "mission": "none", "free": "none"}, "days": days,
			"check": {"items": 12, "pass": 80, "month": w % 4 == 0}, "minutes": {"new": 15, "review": 10, "listen": 8, "speak": 12}})
	# 문장
	var sentences: Array = []
	var per_sent_day: int = maxi(n_sents / (n_weeks * 4), 1)
	var sn: int = 0
	var pool: Array = []
	var ptr: int = 0
	for w in range(1, n_weeks + 1):
		for d in range(1, 5):
			var cur: int = w * 10 + d
			var today: Array = []
			while ptr < active_by_o.size() and active_by_o[ptr]["o"] <= cur:
				pool.append(active_by_o[ptr])
				if active_by_o[ptr]["o"] == cur:
					today.append(active_by_o[ptr])
				ptr += 1
			for k in range(per_sent_day):
				var n_tok: int = 2 + _rnd(3)
				var toks: Array = []
				var used: Array = []
				var o: int = 0
				for t in range(n_tok):
					var src: Array = today if (t == 0 and _rnd(3) != 0) else pool
					var pick: Dictionary = src[_rnd(src.size())]
					if used.has(pick["id"]):
						continue
					used.append(pick["id"])
					toks.append(String(pick["en"]))
					o = maxi(o, int(pick["o"]))
				var scope: String = "all"
				if _rnd(10) == 0:
					var cand: Array = passive_all.filter(func(p): return p["o"] <= cur)
					if not cand.is_empty():
						var pp: Dictionary = cand[_rnd(cand.size())]
						toks.append(String(pp["en"]))
						used.append(pp["id"])
						o = maxi(o, int(pp["o"]))
						scope = "listen"
				if toks.size() < 1:
					continue
				sn += 1
				var en: String = String(toks[0]).capitalize() + (" " + " ".join(PackedStringArray(toks.slice(1))) if toks.size() > 1 else "") + "."
				sentences.append({"id": "s%04d" % sn, "en": en, "ko": "문장 %d" % sn, "say": "", "words": used, "pat": ("p%d" % w if _rnd(3) == 0 else ""), "o": o, "scope": scope,
					"accept": [], "src": ("tatoeba" if _rnd(5) == 0 else "own"), "tid": 0})
	# 대화
	var dialogues: Array = []
	for w in range(1, n_weeks + 1):
		var lines: Array = []
		var cur2: int = w * 10 + 4
		var pool2: Array = active_by_o.filter(func(r): return r["o"] <= cur2)
		for k in range(6 + _rnd(3)):
			var a: Dictionary = pool2[_rnd(pool2.size())]
			var b: Dictionary = pool2[_rnd(pool2.size())]
			lines.append({"s": "A" if k % 2 == 0 else "B", "en": String(a["en"]).capitalize() + " " + String(b["en"]) + ".", "ko": "줄 %d-%d" % [w, k], "say": "", "words": [a["id"], b["id"]], "o": maxi(int(a["o"]), int(b["o"]))})
		dialogues.append({"id": "d%04d" % w, "w": w, "title_ko": "대화", "scene": "x", "user": "B", "lines": lines})
	return {"v": 1, "weeks": weeks, "words": words, "patterns": patterns, "sentences": sentences, "dialogues": dialogues}


# ------------------------------------------------------------------ E2-3 속성 시험(전수)

func _break_order(raw: Dictionary) -> void:
	# 도입 순서 하나를 바꾼다: 낱말 하나(소개 날짜는 그대로)의 o 를 뒤로 민다. 그 낱말이 든 문장들은 더 일찍 나오게 선언돼 있다.
	for wd in raw["words"]:
		if wd["role"] == "active" and int(wd["o"]) >= 12:
			wd["o"] = int(wd["o"]) + 30
			print("BREAK order: word %s (%s) o moved to %d" % [wd["id"], wd["en"], int(wd["o"])])
			return


## 모든 (주 x 일 x 종류 x 시드) 단위를 만들어 oracle 로 검사한다.
func _run_matrix(name: String, raw: Dictionary, weeks_max: int, seeds: int, expect_dropped_zero: bool) -> Dictionary:
	var data: Dictionary = LessonBuilder.prepare(raw)
	var orc: Oracle = Oracle.new(raw)
	var checked: int = 0
	var units: int = 0
	var errored_units: int = 0
	var violations: int = 0
	var dropped: int = 0
	var inconsistent: int = 0
	var printed: int = 0
	var by_kind: Dictionary = {}
	var poison_leaks: int = 0
	var printed_drop: int = 0
	var t0: int = Time.get_ticks_msec()
	for w in range(1, weeks_max + 1):
		for d in range(1, 8):
			for kind in KINDS:
				for sd in range(seeds):
					var r: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": d, "seen": []}, data, sd * 7919 + w * 31 + d)
					units += 1
					dropped += int(r["dropped"])
					if r["dropped"] > 0 and printed_drop < 6 and not name == "poison":
						printed_drop += 1
						print("    DROPPED %s %s w%d d%d seed %d: %s" % [name, kind, w, d, sd, JSON.stringify(r["dropped_info"].slice(0, 2))])
					if not r["ok"]:
						errored_units += 1
						continue
					checked += r["exercises"].size()
					var vs: Array = orc.unit(r["exercises"], w * 10 + d, [])
					violations += vs.size()
					by_kind[kind] = int(by_kind.get(kind, 0)) + vs.size()
					for x0 in r["exercises"]:
						var sid0: String = String(x0.get("sent", ""))
						if POISON_TRUE_O.has(sid0) and w * 10 + d < int(POISON_TRUE_O[sid0]):
							poison_leaks += 1
						elif x0["type"] == "dialogue_script" and x0["dialogue"] == "d0001" and w * 10 + d < 44:
							for ln0 in x0["lines"]:
								if String(ln0["en"]).contains("bus"):
									poison_leaks += 1
					for x in r["exercises"]:
						if not _self_judges(x):
							inconsistent += 1
					if not vs.is_empty() and printed < max_print:
						printed += 1
						print("    VIOLATION %s %s w%d d%d seed %d: %s" % [name, kind, w, d, sd, vs[0]])
	print("property %s: checked %d exercises in %d units (%d units had no content), violations %d, dropped %d, self-judge failures %d (%d ms)" % [name, checked, units, errored_units, violations, dropped, inconsistent, Time.get_ticks_msec() - t0])
	return {"checked": checked, "units": units, "violations": violations, "dropped": dropped, "inconsistent": inconsistent, "by_kind": by_kind, "poison_leaks": poison_leaks}


func _test_properties() -> void:
	var raw_mini: Dictionary = mini_raw.duplicate(true)
	var raw_big: Dictionary = _gen_big(400, 16, 640)
	if break_order:
		_break_order(raw_mini)
		_break_order(raw_big)
	var rm: Dictionary = _run_matrix("mini", raw_mini, 4, seeds_mini, true)
	ok(rm["checked"] > 0 and rm["units"] == 4 * 7 * 6 * seeds_mini, "mini: %d units built" % rm["units"])
	ok(rm["violations"] == 0, "E2-3 mini: violations 0 (not-yet-learned words, options, tiles, listening, dialogues)")
	ok(rm["dropped"] == 0, "E2-3 mini: nothing had to be dropped on clean data (dropped %d)" % rm["dropped"])
	ok(rm["inconsistent"] == 0, "mini: every exercise judges its own answer correct (%d bad)" % rm["inconsistent"])
	for kind in KINDS:
		ok(int(rm["by_kind"].get(kind, 0)) == 0, "E2-3 mini kind %s: violations 0" % kind)
	var rb: Dictionary = _run_matrix("big", raw_big, 16, seeds_big, true)
	ok(rb["checked"] > 0 and rb["units"] == 16 * 7 * 6 * seeds_big, "big: %d units built" % rb["units"])
	ok(rb["violations"] == 0, "E2-3 big (400 words, 640 sentences, 16 weeks): violations 0")
	ok(rb["dropped"] == 0, "E2-3 big: nothing had to be dropped on clean data (dropped %d)" % rb["dropped"])
	ok(rb["inconsistent"] == 0, "big: every exercise judges its own answer correct (%d bad)" % rb["inconsistent"])
	for kind in KINDS:
		ok(int(rb["by_kind"].get(kind, 0)) == 0, "E2-3 big kind %s: violations 0" % kind)
	# 독이 든 데이터: 가드가 켜져 있으면 위반 0 이고 버려진 문제가 있어야 한다. 꺼져 있으면 위반이 나온다.
	var raw_p: Dictionary = _poison(mini_raw)
	var rp: Dictionary = _run_matrix("poison", raw_p, 4, maxi(seeds_mini / 4, 8), false)
	ok(rp["violations"] == 0, "E2-3 poisoned data: violations 0 (the guard keeps it out)")
	ok(rp["dropped"] > 0, "E2-3 poisoned data: the guard dropped %d exercises (caught, not silent)" % rp["dropped"])
	ok(rp["poison_leaks"] == 0, "E2-3 poisoned data: none of the 5 poisoned sentences nor the poisoned dialogue line appeared before it was learnable (leaks %d)" % rp["poison_leaks"])
	for kind in KINDS:
		ok(int(rp["by_kind"].get(kind, 0)) == 0, "E2-3 poisoned data kind %s: violations 0" % kind)
	print("property summary: checked %d, violations %d" % [rm["checked"] + rb["checked"] + rp["checked"], rm["violations"] + rb["violations"] + rp["violations"]])
